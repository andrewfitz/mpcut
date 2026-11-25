// Run through Backstage on a logged-in Mac with Accessibility permission for the terminal.
// Generate the interview media once with Tests/Integration/transcript_fixture.py.
// Usage: swift Tests/Integration/transcript_gui.swift MPCut.app FIXTURE_DIR
// Benchmark: swift Tests/Integration/transcript_gui.swift MPCut.app --benchmark NEW_OUTPUT_DIR
// Real provider: swift Tests/Integration/transcript_gui.swift MPCut.app --transcribe FIXTURE_DIR HELPER
// Set MPCUT_GUI_TEST_ENGINE to choose an engine and enable speaker identification.
// Multicam sync: swift Tests/Integration/transcript_gui.swift MPCut.app --reconcile FIXTURE_DIR HELPER
import AppKit
import ApplicationServices
import Darwin

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Expand the saved project's references so assertions can inspect its timeline and assets.
func savedProjectObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    // What a project repeats is listed once in a root `refs` table keyed by content: "~KEY" is a
    // text entry, {"~": "KEY"} an object or list entry, and "~~x" the text "~x".
    if let refs = root.removeValue(forKey: "refs") as? [String: Any] {
        var failed = false
        func resolved(_ node: Any, depth: Int) -> Any {
            guard depth < 64 else { failed = true; return node }
            if let text = node as? String {
                guard text.hasPrefix("~") else { return text }
                if text.hasPrefix("~~") { return String(text.dropFirst()) }
                guard let literal = refs[String(text.dropFirst())] as? String else { failed = true; return text }
                return literal
            }
            if let object = node as? [String: Any] {
                if object.count == 1, let key = object["~"] as? String {
                    guard let entry = refs[key], !(entry is String) else { failed = true; return node }
                    return resolved(entry, depth: depth + 1)
                }
                return Dictionary(uniqueKeysWithValues: object.map {
                    ($0.key, ["media_snapshot", "embedded_assets"].contains($0.key) ? $0.value : resolved($0.value, depth: depth + 1))
                })
            }
            return (node as? [Any]).map { $0.map { resolved($0, depth: depth + 1) } } ?? node
        }
        var document = resolved(root, depth: 0) as? [String: Any]
        // `base` marks the edit a history was saved for. Like `refs`, it belongs to the saved layout.
        if var history = document?["history"] as? [String: Any] {
            history["base"] = nil
            document?["history"] = history
        }
        return failed ? nil : document
    }
    return root
}

func wait<T>(_ description: String, timeout: TimeInterval = 20, interval: TimeInterval = 0.1, _ inspect: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let result = inspect() { return result }
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    } while Date() < deadline
    throw Failure("Timed out waiting for " + description)
}

func value<T>(_ node: AXUIElement, _ attribute: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
    return result as? T
}

func descendants(_ node: AXUIElement, depth: Int = 0, skipFileLists: Bool = false) -> [AXUIElement] {
    guard depth < 30 else { return [node] }
    // Controls and result labels live outside the virtualized dialogue rows.
    if value(node, "AXIdentifier") as String? == "transcript.dialogue" { return [node] }
    if skipFileLists, value(node, "AXRole") as String? == "AXOutline" { return [node] }
    let children: [AXUIElement] = value(node, "AXChildren") ?? []
    return [node] + children.flatMap { descendants($0, depth: depth + 1, skipFileLists: skipFileLists) }
}

struct Editor {
    let application: NSRunningApplication
    let session: String
    var pid: pid_t { application.processIdentifier }
    var root: AXUIElement { AXUIElementCreateApplication(pid) }
    var windows: [AXUIElement] { value(root, "AXWindows") ?? [] }

    func controls(_ name: String, role: String? = nil, in container: AXUIElement? = nil) -> [AXUIElement] {
        let roots = container.map { [$0] } ?? windows
        return roots.flatMap { descendants($0) }.filter { node in
            let actualRole: String? = value(node, "AXRole")
            return (role == nil || role == actualRole) &&
                ["AXIdentifier", "AXTitle", "AXDescription", "AXValue"].contains { value(node, $0) as String? == name }
        }
    }

    func control(_ name: String, role: String? = nil, in container: AXUIElement? = nil) throws -> AXUIElement {
        try wait(name) { controls(name, role: role, in: container).first }
    }

    func press(_ name: String, role: String? = nil, in container: AXUIElement? = nil) throws {
        let button = try wait(name + " enabled") {
            controls(name, role: role, in: container).first { value($0, "AXEnabled") as Bool? != false }
        }
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard status == .success else { throw Failure("Could not press \(name) (\(status.rawValue))") }
    }

    func backstage(_ arguments: [String]) throws -> Data {
        try runBackstage(arguments + ["--pid", String(pid)], session: session)
    }

    func textField(_ name: String) throws -> AXUIElement {
        try wait(name) {
            (controls(name, role: "AXTextField") + controls(name, role: "AXTextArea"))
                .first { value($0, "AXEnabled") as Bool? != false }
        }
    }

    func setText(_ text: String, into name: String) throws {
        let field = try textField(name)
        let status = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        guard status == .success else { throw Failure("Could not set " + name) }
    }

    func navigateFilePicker(to path: URL) throws {
        _ = try backstage(["key", "cmd+shift+g"])
        _ = try wait("native Go to Folder path field") {
            windows.flatMap { descendants($0) }.first {
                let role: String? = value($0, "AXRole")
                return (role == "AXTextField" || role == "AXComboBox")
                    && value($0, "AXFocused") as Bool? == true
            }
        }
        _ = try backstage(["key", "cmd+a"])
        _ = try backstage(["type", path.path])
        _ = try backstage(["key", "return"])
    }

    func pickerIsIn(_ folder: URL) -> Bool {
        controls("Where:", role: "AXPopUpButton").contains {
            value($0, "AXValue") as String? == folder.lastPathComponent
        }
    }

    func prepareFileChoice(_ file: URL) throws {
        _ = try control("Choose", role: "AXButton")
        if !pickerIsIn(file.deletingLastPathComponent()) || !selectFileRow(file) {
            try navigateFilePicker(to: file)
        }
    }

    func chooseFile(_ file: URL) throws {
        try prepareFileChoice(file)
        try press("Choose", role: "AXButton")
    }

    func selectFileRow(_ file: URL) -> Bool {
        let names = [file.lastPathComponent, file.deletingPathExtension().lastPathComponent]
        guard let list = controls("ListView", role: "AXOutline").first,
              let row = descendants(list).first(where: { node in
                  value(node, "AXRole") as String? == "AXRow" &&
                      descendants(node).contains { candidate in
                          guard let name: String = value(candidate, "AXValue") else { return false }
                          return names.contains(name)
                      }
              }) else { return false }
        let selected = AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
        if selected == .success { return true }
        return AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
    }


    func showTranscript() throws {
        if !controls("transcript.import").isEmpty { return }
        if controls("Multicam inspector").isEmpty {
            try press("Transcript")
        } else {
            try selectInspector("Transcript")
        }
        _ = try control("transcript.import")
    }

    func selectInspector(_ title: String) throws {
        let picker = try control("Multicam inspector")
        if value(picker, "AXRole") as String? == "AXPopUpButton" {
            try chooseValue(title, from: "Multicam inspector")
        } else {
            try press(title, role: "AXRadioButton", in: picker)
        }
    }

    func prepareSearch(_ phrase: String) throws {
        let field = try textField("transcript.search")
        let previous: String = value(field, "AXValue") ?? ""
        var selection = CFRange(location: 0, length: previous.utf16.count)
        guard let selectedRange = AXValueCreate(.cfRange, &selection),
              AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, selectedRange) == .success,
              AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, phrase as CFString) == .success else {
            throw Failure("Could not enter a transcript search query")
        }
    }

    func submitSearch() throws {
        if controls("transcript.search.submit").isEmpty {
            let field = try textField("transcript.search")
            guard AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success else {
                throw Failure("Could not submit the transcript search")
            }
        } else {
            try press("transcript.search.submit", role: "AXButton")
        }
    }

    func search(_ phrase: String) throws {
        try prepareSearch(phrase)
        try submitSearch()
    }

    func fileCommand(_ title: String) -> AXUIElement? {
        guard let bar: AXUIElement = value(root, "AXMenuBar"),
              let file = controls("File", role: "AXMenuBarItem", in: bar).first else { return nil }
        return controls(title, role: "AXMenuItem", in: file).first {
            value($0, "AXEnabled") as Bool? == true
        }
    }

    /// Saves through the toolbar button or File ▸ Save Project when Accessibility reports one
    /// enabled, and confirms that the document was written. When neither is offered, or the
    /// press writes nothing, it sends ⌘S until the document is written.
    func saveProject(_ document: URL) throws {
        func modified() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: document.path))?[.modificationDate] as? Date
        }
        func saved(since before: Date?, within seconds: TimeInterval) -> Bool {
            (try? wait("saved project", timeout: seconds) { modified() != before ? true : nil }) != nil
        }
        let before = modified()
        if let command = controls("Save Project", role: "AXButton").first(where: { value($0, "AXEnabled") as Bool? == true })
            ?? fileCommand("Save Project"),
           AXUIElementPerformAction(command, kAXPressAction as CFString) == .success, saved(since: before, within: 3) {
            return
        }
        fputs("Save Project was not offered through Accessibility. Sending ⌘S.\n", stderr)
        _ = try wait("Save Project command") {
            guard (try? backstage(["key", "cmd+s"])) != nil else { return nil as Bool? }
            return saved(since: before, within: 2) ? true : nil
        }
    }

    func expectTime(_ label: String, equals expected: String, interval: TimeInterval = 0.1) throws {
        _ = try wait(label + " at " + expected, interval: interval) {
            controls(label).first { value($0, "AXValue") as String? == expected }
        }
    }

    func expectSavedRanges(_ document: URL, _ expected: [[String]]) throws {
        try saveProject(document)
        _ = try wait("saved ranges " + String(describing: expected)) {
            guard let project = savedProjectObject(document),
                  let clips = project["clips"] as? [[String: Any]],
                  let transcripts = project["transcripts"] as? [String: Any],
                  let attachments = transcripts["attachments"] as? [[String: Any]],
                  attachments.count == 1 else { return nil as Bool? }
            let ranges = clips.map { clip in
                [clip["from"] as? String ?? "", clip["to"] as? String ?? ""]
            }
            return ranges == expected ? true : nil
        }
    }

    func expectResults(_ expected: String, timeout: TimeInterval = 12, interval: TimeInterval = 0.1) throws {
        let results = try wait("transcript results", timeout: timeout, interval: interval) {
            controls("transcript.results").first
        }
        _ = try wait(expected, timeout: timeout, interval: interval) {
            ["AXValue", "AXTitle", "AXDescription"].contains { value(results, $0) as String? == expected } ? true : nil
        }
    }

    /// The results label once it ends with the given text.
    func results(ending suffix: String, timeout: TimeInterval = 60, interval: TimeInterval = 0.02) throws -> String {
        try wait("results ending in " + suffix, timeout: timeout, interval: interval) {
            guard let results = controls("transcript.results").first else { return nil }
            return ["AXValue", "AXTitle", "AXDescription"].compactMap { value(results, $0) as String? }
                .first { $0.hasSuffix(suffix) }
        }
    }

    func choose(_ title: String, from menuName: String) throws {
        let menu = try control(menuName)
        let status = AXUIElementPerformAction(menu, kAXPressAction as CFString)
        guard status == .success else { throw Failure("Could not open \(menuName) (\(status.rawValue))") }
        let item = try wait(title) {
            controls(title, role: "AXMenuItem", in: menu).first ??
                controls(title, role: "AXMenuItem").first
        }
        let activation = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard activation == .success else { throw Failure("Could not choose " + title) }
    }

    func chooseValue(_ title: String, from menu: String) throws {
        try choose(title, from: menu)
        _ = try wait(title + " selected") {
            controls(menu).first { node in
                ["AXValue", "AXTitle", "AXDescription"].contains { value(node, $0) as String? == title }
            }
        }
    }

    func captureWindow(to destination: URL) throws {
        _ = try backstage(["screenshot", "-o", destination.path])
    }

    func inspectOnFailure() {
        for node in windows.flatMap({ descendants($0, skipFileLists: true) }) {
            let details = ["AXRole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue"].compactMap { attr in
                (value(node, attr) as String?).flatMap { $0.isEmpty ? nil : "\(attr)=\($0)" }
            }
            if !details.isEmpty { fputs(details.joined(separator: " ") + "\n", stderr) }
        }
    }
}

func runBackstage(_ arguments: [String], session: String) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["backstage"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["BACKSTAGE_SESSION"] = session
    process.environment = environment
    process.standardOutput = output
    try process.run()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure("Backstage \(arguments[0]) failed: \(String(decoding: data, as: UTF8.self))")
    }
    return data
}

func openTestProject(_ document: URL, pid: pid_t, endpoint: URL) throws {
    let path = endpoint.appendingPathComponent("control.sock").path
    let request: [String: Any] = ["version": 2, "tool": "project_open", "arguments": [
        "project_path": document.path, "operation_id": UUID().uuidString,
    ]]
    let frame = try JSONSerialization.data(withJSONObject: request) + Data([10])
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure("Could not create the test socket") }
    let connection = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? connection.close() }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw Failure("The test socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    _ = try wait("the Backstage desktop listener") {
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0 ? true : nil
    }
    var peer: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer == pid else {
        throw Failure("A different process acquired the test socket")
    }
    var timeout = timeval(tv_sec: 20, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var enabled: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    try connection.write(contentsOf: frame)
    let data = try connection.readToEnd() ?? Data()
    let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard (reply?["result"] as? [String: Any])?["project_handle"] is String else {
        throw Failure("Opening the test project failed: \(String(decoding: data, as: UTF8.self))")
    }
}

func withEditor(_ bundle: URL, opening document: URL, home: URL, helper: URL? = nil,
                _ exercise: (Editor) throws -> Void) throws {
    let testInstance = "mpcut-test-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let endpoint = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(testInstance)
    defer {
        try? FileManager.default.removeItem(at: endpoint)
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        cleanup.arguments = ["delete", "com.mpcut.test-preferences." + testInstance]
        cleanup.standardError = FileHandle.nullDevice
        if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
    }
    var launch = ["launch", bundle.path, "--timeout", "45", "--env", "CFFIXED_USER_HOME=\(home.path)",
                  "--env", "MPCUT_TEST_SOCKET_DIRECTORY=\(testInstance)", "--env", "MPCUT_MUTED=1"]
    if let helper { launch += ["--env", "MPCUT_TRANSCRIBERRR_HELPER=\(helper.path)"] }
    launch += ["--", "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
               "-AppleLanguages", "(en)", "-automation_local_mcp_enabled", "YES", "-analysis_sidecar_reuse_enabled", "NO",
               "-timeline_snap_target", "off", "-export_movie_default_mode", "copy"]
    let data = try runBackstage(launch, session: testInstance)
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pid = response["pid"] as? pid_t else { throw Failure("Backstage returned no editor PID") }
    defer {
        do { _ = try runBackstage(["quit", "--pid", String(pid), "--force"], session: testInstance) }
        catch { fputs(error.localizedDescription + "\n", stderr) }
    }
    guard let app = NSRunningApplication(processIdentifier: pid),
          app.bundleURL?.resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath() else {
        throw Failure("Backstage did not launch the requested test bundle")
    }
    let editor = Editor(application: app, session: testInstance)
    AXUIElementSetMessagingTimeout(editor.root, 3)
    try openTestProject(document, pid: pid, endpoint: endpoint)
    do {
        let title = document.deletingPathExtension().lastPathComponent
        _ = try wait("document window " + title, timeout: 45) {
            editor.windows.first { (value($0, "AXTitle") as String?)?.hasPrefix(title) == true }
        }
        try exercise(editor)
    } catch {
        editor.inspectOnFailure()
        throw error
    }
}

func stageFixtures(_ source: URL, in scratch: URL) throws -> URL {
    let fm = FileManager.default
    let staged = scratch.appendingPathComponent("fixture", isDirectory: true)
    try fm.createDirectory(at: staged, withIntermediateDirectories: false)
    for name in ["parity.cut", "parity.wav", "parity-words.json", "interview.cut", "wide.mov", "close.mov", "lav.wav", "close.srt",
                 "queue.cut", "queue-words.json"] {
        try fm.copyItem(at: source.appendingPathComponent(name), to: staged.appendingPathComponent(name))
    }
    return staged
}

func exerciseSequence(_ editor: Editor, project: URL, transcript: URL) throws {
    try editor.showTranscript()
    try editor.press("transcript.import", role: "AXButton")
    try editor.chooseFile(transcript)
    try editor.press("transcript.binding.apply", role: "AXButton")
    try editor.search("REMOVE!")
    try editor.expectResults("Match 1 of 1")
    try editor.press("transcript.nextMatch", role: "AXButton")
    try editor.expectTime("Timeline position", equals: "00:01.000")
    try editor.choose("Correct Text…", from: "transcript.actions")
    try editor.setText("rewritten", into: "transcript.correction.text")
    try editor.press("transcript.correction.save", role: "AXButton")
    try editor.search("rewritten")
    try editor.expectResults("Match 1 of 1")
    try editor.press("editor.history.undo", role: "AXButton")
    try editor.search("rewritten")
    try editor.expectResults("0 matches")
    try editor.search("remove")
    try editor.expectResults("Match 1 of 1")
    try editor.choose("Queue Excerpt…", from: "transcript.actions")
    try editor.setText("Verified Word Excerpt", into: "transcript.queue.name")
    try editor.press("transcript.reviewEdit", role: "AXButton")
    try editor.press("transcript.apply", role: "AXButton")
    try editor.press("Queue (1)", role: "AXButton")
    _ = try editor.control("Verified Word Excerpt", role: "AXStaticText")
    _ = try editor.control("00:01.000 – 00:02.000", role: "AXStaticText")
    try editor.press("Close", role: "AXButton")
    try editor.choose("Delete Selected Time…", from: "transcript.actions")
    try editor.chooseValue("Exact requested time", from: "transcript.boundaryPolicy")
    try editor.press("transcript.reviewEdit", role: "AXButton")
    try editor.press("transcript.apply", role: "AXButton")
    try editor.expectSavedRanges(project, [["0", "1"], ["2", "4"]])
    try editor.press("editor.history.undo", role: "AXButton")
    try editor.expectSavedRanges(project, [["0", "4"]])
    print("Verified native JSON import, normalized search, word seek, correction undo, named queue, and saved deletion undo")
}

func exerciseMulticam(_ editor: Editor, transcript: URL) throws {
    try editor.showTranscript()
    try editor.press("transcript.import", role: "AXButton")
    try editor.chooseFile(transcript)
    try editor.chooseValue("close.mov [close] · Stream 1", from: "transcript.binding.stream.source")
    try editor.setText("0", into: "transcript.binding.origin")
    try editor.press("transcript.binding.apply", role: "AXButton")
    try editor.search("compass is upside down")
    _ = try editor.control("No Matches", role: "AXStaticText")
    try editor.expectResults("0 matches")
    try editor.press("Group", in: editor.control("transcript.space"))
    try editor.expectResults("Match 1 of 1")
    try editor.search("The lantern glows ONLY when the moon rises")
    try editor.expectResults("Match 1 of 2")
    try editor.press("transcript.nextMatch", role: "AXButton")
    try editor.expectTime("Group time ruler", equals: "00:11.000")
    try editor.press("transcript.previousMatch", role: "AXButton")
    try editor.expectTime("Group time ruler", equals: "00:03.000")
    try editor.search("compass is upside down")
    try editor.expectResults("Match 1 of 1")
    try editor.press("transcript.nextMatch", role: "AXButton")
    try editor.expectTime("Group time ruler", equals: "00:15.000")
    // Another inspector tab removes the pane. It returns on the same clock, search and match.
    try editor.selectInspector("Sources")
    _ = try wait("the transcript pane to leave") { editor.controls("transcript.results").isEmpty ? true : nil }
    try editor.selectInspector("Transcript")
    try editor.expectResults("Match 1 of 1")
    print("Verified multicam binding, fixed-route exclusion, group search, clock-offset seek, and the pane's place across inspector tabs")
}

func projectJSON(_ url: URL) -> [String: Any]? {
    savedProjectObject(url)
}

func exerciseMulticamQueue(_ editor: Editor, project: URL, transcript: URL, snapshot: URL) throws {
    try editor.showTranscript()
    try editor.press("transcript.import", role: "AXButton")
    try editor.chooseFile(transcript)
    try editor.chooseValue("lav.wav [lav] · Stream 0", from: "transcript.binding.stream.source")
    try editor.press("transcript.binding.apply", role: "AXButton")
    try editor.search("queuing excerpts")
    try editor.expectResults("Match 1 of 1")
    try editor.choose("Queue Excerpt…", from: "transcript.actions")
    try editor.setText("Camera quote", into: "transcript.queue.name")
    try editor.chooseValue("Exact requested time", from: "transcript.boundaryPolicy")
    try editor.press("transcript.reviewEdit", role: "AXButton")
    try editor.press("transcript.apply", role: "AXButton")

    // Replace the original switch. The queued excerpt must still retain its captured camera cut.
    try editor.press("close.mov switch at 00:02.000", role: "AXButton")
    try editor.expectTime("Group time ruler", equals: "00:02.000")
    try editor.press("Take camera wide.mov at group time", role: "AXButton")
    try editor.saveProject(project)
    _ = try wait("modified original camera switches on disk") {
        guard let switches = projectJSON(project)?["switches"] as? [[String: String]],
              !switches.contains(where: { $0["group_time"] == "2" && $0["angle_id"] == "close" }) else { return nil as Bool? }
        return true
    }

    try editor.press("Queue (1)", role: "AXButton")
    _ = try editor.control("Camera quote", role: "AXStaticText")
    try editor.press("Save Excerpt Project", role: "AXButton")
    _ = try editor.control("Save", role: "AXButton")
    let destination = snapshot.deletingLastPathComponent()
    if !editor.pickerIsIn(destination) { try editor.navigateFilePicker(to: destination) }
    _ = try wait("Save Excerpt Project destination") { editor.pickerIsIn(destination) ? true : nil }
    try editor.press("Save", role: "AXButton")
    let saved = try wait("saved Camera quote.cut") { projectJSON(snapshot) }
    guard let items = saved["assembly"] as? [[String: Any]], items.count == 1,
          items[0] as? [String: String] == ["from": "1", "to": "3"],
          let audio = saved["audio"] as? [String: Any], audio["mode"] as? String == "fixed",
          audio["source_id"] as? String == "lav", audio["audio_stream_index"] as? Int == 0,
          let switches = saved["switches"] as? [[String: String]],
          switches.contains(where: { $0["group_time"] == "2" && $0["angle_id"] == "close" }) else {
        throw Failure("Saved multicam excerpt did not preserve the captured two-second camera cut and fixed lav")
    }
    try editor.press("Export File…", role: "AXButton")
    _ = try editor.control("Export Here", role: "AXButton")
    if !editor.pickerIsIn(destination) { try editor.navigateFilePicker(to: destination) }
    guard editor.pickerIsIn(destination) else {
        throw Failure("The native queue export destination was outside the disposable fixture folder")
    }
    try editor.press("Export Here", role: "AXButton")
    _ = try editor.control("Exported 1 file to \(destination.lastPathComponent).", role: "AXStaticText")
    guard FileManager.default.fileExists(atPath: destination.appendingPathComponent("Camera quote-001.mov").path) else {
        throw Failure("The native queue did not publish Camera quote-001.mov")
    }
}

func capture(_ executable: URL, _ arguments: [String]) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure(executable.lastPathComponent + " exited during excerpt verification") }
    return data
}

func verifyQueueRender(_ bundle: URL, snapshot: URL, sourceAudio: URL) throws {
    let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
    let destination = snapshot.deletingLastPathComponent()
    let cliMovie = destination.appendingPathComponent("CLI Camera quote.mov")
    let nativeMovie = destination.appendingPathComponent("Camera quote-001.mov")
    let cli = helpers.appendingPathComponent("mpcut")
    let ffmpeg = helpers.appendingPathComponent("ffmpeg")
    _ = try capture(cli, ["export", "project", "render", "--project", snapshot.path, "--output", cliMovie.path,
                          "--mode", "encode", "--video", "prores", "--audio", "pcm", "--json"])
    func decode(_ file: URL, _ options: [String]) throws -> Data {
        try capture(ffmpeg, ["-v", "error", "-nostdin", "-i", file.path] + options)
    }
    let audioOptions = ["-map", "0:a:0", "-ac", "1", "-ar", "16000", "-f", "s16le", "-"]
    let original = try decode(sourceAudio, audioOptions)
    guard original.count >= 96_000 else { throw Failure("The fixed lav fixture is shorter than the excerpt") }
    let expectedAudio = original.subdata(in: 32_000..<96_000)
    for movie in [nativeMovie, cliMovie] {
        guard try decode(movie, audioOptions) == expectedAudio else {
            throw Failure(movie.lastPathComponent + " differs from the original fixed lav")
        }
        func frame(_ seconds: String) throws -> Data {
            try decode(movie, ["-ss", seconds, "-map", "0:v:0", "-frames:v", "1",
                               "-vf", "crop=16:8:8:0,format=rgb24", "-f", "rawvideo", "-"])
        }
        let before = try frame("0.96")
        let after = try frame("1")
        guard before.count >= 3, after.count >= 3, before[2] > before[0], after[0] > after[2] else {
            throw Failure(movie.lastPathComponent + " did not cut from the blue camera to the red camera at one second")
        }
    }
}

func benchmarkFiles(in folder: URL, duration: Int) throws -> (project: URL, transcript: URL) {
    let media = folder.appendingPathComponent("benchmark.wav")
    let project = folder.appendingPathComponent("Two-Hour Interview.cut")
    let transcript = folder.appendingPathComponent("benchmark.json")
    let rate = 8_000
    let pcmSize = UInt32(duration * rate * 2)
    func bytes<T: FixedWidthInteger>(_ number: T) -> Data {
        var value = number.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    var header = Data("RIFF".utf8)
    header += bytes(pcmSize + 36)
    header += Data("WAVEfmt ".utf8)
    header += bytes(UInt32(16))
    header += bytes(UInt16(1))
    header += bytes(UInt16(1))
    header += bytes(UInt32(rate))
    header += bytes(UInt32(rate * 2))
    header += bytes(UInt16(2))
    header += bytes(UInt16(16))
    header += Data("data".utf8)
    header += bytes(pcmSize)
    try header.write(to: media)
    let audio = try FileHandle(forWritingTo: media)
    try audio.truncate(atOffset: UInt64(header.count) + UInt64(pcmSize))
    try audio.close()
    try Data(#"{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[{"id":"benchmark","file":"benchmark.wav","from":"0","to":"\#(duration)"}]}"#.utf8)
        .write(to: project)
    let script = ["We", "stayed", "for", "a", "while", "and", "talked", "about", "what", "we", "had", "seen."]
    var json = #"{"source":"benchmark.wav","duration_seconds":\#(duration),"metadata":{},"speaker_names":["Host","Guest"],"segments":["#
    // Alternate speakers every three seconds. Put one searchable phrase in each minute.
    for segment in 0..<(duration / 3) {
        if segment > 0 { json += "," }
        let start = segment * 3
        json += #"{"start":\#(start),"end":\#(start + 3),"speaker":\#(segment % 2),"words":["#
        for index in script.indices {
            if index > 0 { json += "," }
            let time = Double(start) + Double(index) / 4
            let word = start % 60 == 3 && index == 8 ? "lantern" : script[index]
            json += #"{"text":"\#(word)","start":\#(time),"end":\#(time + 0.25)}"#
        }
        json += "]}"
    }
    json += "]}"
    try Data(json.utf8).write(to: transcript)
    return (project, transcript)
}

func measure(_ action: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try action()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func runBenchmark(_ bundle: URL, scratch: URL, home: URL, output: URL) throws {
    let duration = 7_200
    guard mkdir(output.path, 0o700) == 0 else {
        throw Failure("Choose an unused benchmark output directory under an existing folder")
    }
    let files = try benchmarkFiles(in: scratch, duration: duration)
    try withEditor(bundle, opening: files.project, home: home) { editor in
        AXUIElementSetMessagingTimeout(editor.root, 120)
        try editor.showTranscript()
        try editor.press("transcript.import", role: "AXButton")
        try editor.prepareFileChoice(files.transcript)
        let binding = try measure {
            try editor.press("Choose", role: "AXButton")
            _ = try editor.control("transcript.binding.apply", role: "AXButton")
        }
        let attach = try measure {
            try editor.press("transcript.binding.apply", role: "AXButton")
            try editor.expectResults("28800 words", timeout: 120, interval: 0.02)
        }
        var metrics: [String: Any] = [
            "durationSeconds": duration, "word_count": duration * 4,
            "bindingFormMilliseconds": binding, "importMilliseconds": attach,
        ]
        func publishMetrics() throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("transcript-latency.json"), options: .atomic)
            return data
        }
        _ = try publishMetrics()
        try editor.captureWindow(to: output.appendingPathComponent("transcript-window.png"))
        try editor.prepareSearch("lantern")
        let search = try measure {
            try editor.submitSearch()
            try editor.expectResults("Match 1 of 120", interval: 0.02)
        }
        metrics["searchMilliseconds"] = search
        metrics["matchCount"] = 120
        _ = try publishMetrics()
        try editor.captureWindow(to: output.appendingPathComponent("transcript-search.png"))
        func timeMatchChange(_ control: AXUIElement, action: String, expecting match: Int) throws -> Double {
            // Finding controls traverses the AX tree. Resolve them before starting the timer.
            let results = try editor.control("transcript.results")
            let expected = "Match \(match) of 4800"
            return try measure {
                let status = AXUIElementPerformAction(control, action as CFString)
                guard status == .success else { throw Failure("Could not activate transcript search control (\(status.rawValue))") }
                _ = try wait(expected, interval: 0.005) {
                    ["AXValue", "AXTitle", "AXDescription"].contains { value(results, $0) as String? == expected } ? true : nil
                }
            }
        }
        var frequentSearch: [Double] = []
        var crossPageSearch: [Double] = []
        for _ in 0..<5 {
            try editor.prepareSearch("we")
            if let submit = editor.controls("transcript.search.submit", role: "AXButton").first {
                frequentSearch.append(try timeMatchChange(submit, action: kAXPressAction, expecting: 1))
            } else {
                let field = try editor.textField("transcript.search")
                frequentSearch.append(try timeMatchChange(field, action: kAXConfirmAction, expecting: 1))
            }
            for (control, match, time) in [("transcript.previousMatch", 4_800, "1:59:59.250"),
                                           ("transcript.nextMatch", 1, "00:00.000")] {
                let button = try editor.control(control, role: "AXButton")
                crossPageSearch.append(try timeMatchChange(button, action: kAXPressAction, expecting: match))
                try editor.expectTime("Timeline position", equals: time, interval: 0.005)
            }
            // Switch queries between samples so the next submission starts a fresh search.
            try editor.prepareSearch("lantern")
            try editor.submitSearch()
            try editor.expectResults("Match 1 of 120", interval: 0.005)
        }
        metrics["frequentSearchMilliseconds"] = frequentSearch
        metrics["crossPageSearchMilliseconds"] = crossPageSearch
        _ = try publishMetrics()
        metrics["nextMatchMilliseconds"] = try (1...5).map { minute in
            try measure {
                try editor.press("transcript.nextMatch", role: "AXButton")
                try editor.expectTime("Timeline position", equals: String(format: "%02d:05.000", minute), interval: 0.02)
            }
        }
        _ = try publishMetrics()
        // An edit and its undo while the reader is on the sixth match. Each time is from the
        // click to the reader showing the new revision, and each label is where it was left.
        do {
            try editor.choose("Delete Selected Time…", from: "transcript.actions")
            try editor.chooseValue("Exact requested time", from: "transcript.boundaryPolicy")
            try editor.press("transcript.reviewEdit", role: "AXButton")
            _ = try editor.control("transcript.apply", role: "AXButton")
            metrics["editMilliseconds"] = try measure {
                try editor.press("transcript.apply", role: "AXButton")
                metrics["labelAfterEdit"] = try editor.results(ending: " of 119")
            }
            try editor.captureWindow(to: output.appendingPathComponent("transcript-edit.png"))
            // The search field is unavailable for as long as the reader is disabled.
            let field = try editor.textField("transcript.search")
            let label = try wait("transcript results") { editor.controls("transcript.results").first }
            var disabled = 0.0
            metrics["undoMilliseconds"] = try measure {
                try editor.press("editor.history.undo", role: "AXButton")
                var last = DispatchTime.now().uptimeNanoseconds
                metrics["labelAfterUndo"] = try wait("results ending in of 120", timeout: 60, interval: 0.005) {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if value(field, "AXEnabled") as Bool? == false { disabled += Double(now - last) / 1_000_000 }
                    last = now
                    return (value(label, "AXValue") as String?).flatMap { $0.hasSuffix(" of 120") ? $0 : nil }
                }
            }
            metrics["undoDisabledMilliseconds"] = disabled
            try editor.captureWindow(to: output.appendingPathComponent("transcript-undo.png"))
        } catch {
            metrics["editError"] = error.localizedDescription
        }
        let data = try publishMetrics()
        print(String(decoding: data, as: UTF8.self))
    }
}

func exerciseTranscription(_ editor: Editor, project: URL) throws {
    try editor.showTranscript()
    try editor.press("transcript.transcribe", role: "AXButton")
    try editor.press("Recognition options", role: "AXDisclosureTriangle")
    let download = try editor.control("transcript.setup.download")
    guard value(download, "AXValue") as Int? == 0 else {
        throw Failure("The default setup unexpectedly enabled model downloads")
    }
    if let engine = ProcessInfo.processInfo.environment["MPCUT_GUI_TEST_ENGINE"] {
        let title = ["apple-native": "Apple Speech", "parakeet-v3": "Parakeet v3", "qwen3": "Qwen3"][engine] ?? engine
        try editor.chooseValue(title, from: "transcript.setup.engine")
        let identify = try editor.control("Identify speakers in mixed audio", role: "AXCheckBox")
        guard value(identify, "AXEnabled") as Bool? == true else {
            throw Failure("Mixed-audio speaker identification is unavailable for " + engine)
        }
        if value(identify, "AXValue") as Int? != 1 {
            try editor.press("Identify speakers in mixed audio", role: "AXCheckBox")
        }
    }
    try editor.press("transcript.start", role: "AXButton")
    let complete = "Transcription Complete"
    let terminalStates = [complete, "Transcription Partially Complete", "Transcription Failed",
                          "Transcription Cancelled", "Transcription Interrupted", "Alignment Out of Date"]
    let state = try wait("real GUI transcription to complete", timeout: 300, interval: 0.25) {
        editor.controls("transcript.job.status").lazy.compactMap { node in
            ["AXValue", "AXTitle", "AXDescription"].compactMap { value(node, $0) as String? }
                .first(where: terminalStates.contains)
        }.first
    }
    guard state == complete else { throw Failure("The GUI transcription ended with " + state) }
    _ = try editor.control("transcript.search")
    try editor.saveProject(project)
    let attachments: [[String: Any]] = try wait("one saved recognition attachment") {
        guard let transcripts = projectJSON(project)?["transcripts"] as? [String: Any],
              let attachments = transcripts["attachments"] as? [[String: Any]], attachments.count == 1 else { return nil }
        return attachments
    }
    guard let asset = attachments[0]["asset"] as? [String: Any], let digest = asset["sha256"] as? String,
          let assets = projectJSON(project)?["embedded_assets"] as? [String: Any],
          let transcripts = assets["transcripts"] as? [String: [String: Any]],
          let transcript = transcripts[digest],
          let words = transcript["words"] as? [[String: Any]], !words.isEmpty else {
        throw Failure("Transcription finished without a saved result containing words")
    }
    print("Native Transcribe with Transcriberrr completed, attached, and saved \(words.count) words with model downloading off")
}

func exerciseReconciliation(_ editor: Editor, project: URL) throws {
    func attachments() -> [[String: Any]] {
        (projectJSON(project)?["transcripts"] as? [String: Any])?["attachments"] as? [[String: Any]] ?? []
    }
    let original = attachments()
    guard original.count == 1, let oldFingerprint = original[0]["fingerprint"] as? String,
          let attachmentID = original[0]["id"] as? String else {
        throw Failure("Expected a completed multicam session with a synchronization fingerprint")
    }
    try editor.selectInspector("Sources")
    try editor.press("+1 frame", role: "AXButton")
    try editor.saveProject(project)
    _ = try wait("changed camera source offset") {
        guard let angles = projectJSON(project)?["angles"] as? [[String: Any]],
              angles.first?["offset"] as? String != "-1/2" else { return nil as Bool? }
        return true
    }
    try editor.showTranscript()
    try editor.press("transcript.reconcile", role: "AXButton")
    _ = try wait("updated native reconciliation", timeout: 180, interval: 0.25) {
        guard editor.controls("transcript.reconcile").isEmpty,
              editor.controls("Transcription Complete").count > 0 else { return nil as Bool? }
        return true
    }
    try editor.saveProject(project)
    _ = try wait("same attachment with a new synchronization fingerprint") {
        let updated = attachments()
        guard updated.count == 1, updated[0]["id"] as? String == attachmentID,
              let fingerprint = updated[0]["fingerprint"] as? String,
              fingerprint != oldFingerprint else { return nil as Bool? }
        return true
    }
    print("Native source offset change exposed Reconcile Transcript and saved a fresh alignment in the original attachment")
}

func exerciseCameraSwitch(_ bundle: URL, fixture: URL, scratch: URL, home: URL) throws {
    let fm = FileManager.default
    for name in ["wide.mov", "close.mov", "lav.wav", "queue-words.json"] {
        try fm.copyItem(at: fixture.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
    }
    let project = scratch.appendingPathComponent("Transcript camera switch.cut")
    let initialProject = """
    {"format":"mpcut","schema_version":9,"kind":"multicam","reference_angle_id":"wide",
     "group_range":{"from":"0","to":"4"},"angles":[{"id":"wide","file":"wide.mov"},
                                           {"id":"close","file":"close.mov","offset":"2"}],
     "audio_sources":[{"id":"lav","file":"lav.wav"}],"audio":{"mode":"fixed","source_id":"lav","audio_stream_index":0},
     "switches":[{"group_time":"0","angle_id":"wide"}],"assembly":[{"from":"0","to":"4"},
                                                      {"from":"0","to":"4"}]}
    """
    try Data(initialProject.utf8).write(to: project)
    _ = try capture(bundle.appendingPathComponent("Contents/Helpers/mpcut"),
                    ["transcript", "attachment", "import", "--project", project.path, "--in-place",
                     "--transcript", scratch.appendingPathComponent("queue-words.json").path,
                     "--source-id", "lav", "--audio-stream-index", "0", "--json"])

    try withEditor(bundle, opening: project, home: home) { editor in
        try editor.showTranscript()
        try editor.search("queuing excerpts")
        try editor.expectResults("Match 1 of 2")
        func readerSize() -> CGSize? {
            guard let reader = editor.controls("transcript.dialogue").first,
                  let size: AXValue = value(reader, "AXSize") else { return nil }
            var result = CGSize.zero
            return AXValueGetValue(size, .cgSize, &result) ? result : nil
        }
        let docked = try wait("docked transcript size", readerSize)
        try editor.press("editor.fullHeightPanel")
        let expanded = try wait("full-height transcript") {
            readerSize().flatMap { $0.height > docked.height + 40 ? $0 : nil }
        }
        guard abs(expanded.width - docked.width) <= 2 else { throw Failure("Docking changed the transcript width") }
        try editor.expectResults("Match 1 of 2")
        try editor.press("editor.fullHeightPanel")
        _ = try wait("transcript tucked above timeline") {
            guard let reader = editor.controls("transcript.dialogue").first,
                  let ruler = editor.controls("Group time ruler").first,
                  let readerPosition: AXValue = value(reader, "AXPosition"),
                  let rulerPosition: AXValue = value(ruler, "AXPosition"),
                  let size = readerSize() else { return nil as Bool? }
            var readerOrigin = CGPoint.zero, rulerOrigin = CGPoint.zero
            guard AXValueGetValue(readerPosition, .cgPoint, &readerOrigin),
                  AXValueGetValue(rulerPosition, .cgPoint, &rulerOrigin) else { return nil }
            return size.height < expanded.height - 40 && readerOrigin.y + size.height <= rulerOrigin.y ? true : nil
        }
        try editor.expectResults("Match 1 of 2")


        func settleMenu() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }

        func startReview(checkStartCoverage: Bool) throws -> (review: AXUIElement, done: AXUIElement) {
            try editor.choose("Switch Angle at Dialogue…", from: "transcript.actions")
            if checkStartCoverage {
                let camera = try editor.control("transcript.switchAngle.camera")
                try editor.press("transcript.switchAngle.camera", role: "AXPopUpButton")
                let wide = "wide.mov · 00:01.000"
                let option = try wait(wide) {
                    editor.controls(wide, role: "AXMenuItem", in: camera).first
                }
                guard !descendants(camera).contains(where: {
                    (value($0, "AXTitle") as String?)?.hasPrefix("close.mov") == true
                }) else {
                    throw Failure("The close camera was available before its synchronized start")
                }
                guard AXUIElementPerformAction(option, kAXPressAction as CFString) == .success else {
                    throw Failure("Could not select the wide camera at the start edge")
                }
                _ = try editor.control(wide, role: "AXPopUpButton")
                settleMenu()
            }
            try editor.choose("End of selection", from: "Start of selection")
            _ = try editor.control("End of selection", role: "AXPopUpButton")
            settleMenu()
            try editor.chooseValue("close.mov · 00:01.000", from: "transcript.switchAngle.camera")
            settleMenu()
            try editor.chooseValue("Exact requested time", from: "transcript.boundaryPolicy")
            settleMenu()
            return (try editor.control("transcript.reviewEdit", role: "AXButton"),
                    try editor.control("Done", role: "AXButton"))
        }

        let cancelled = try startReview(checkStartCoverage: true)
        guard AXUIElementPerformAction(cancelled.review, kAXPressAction as CFString) == .success,
              AXUIElementPerformAction(cancelled.done, kAXPressAction as CFString) == .success else {
            throw Failure("Could not start and immediately dismiss the edit review")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        guard editor.controls("transcript.apply", role: "AXButton").isEmpty,
              editor.controls("transcript.reviewEdit", role: "AXButton").isEmpty else {
            throw Failure("A dismissed transcript edit review reopened")
        }

        _ = try startReview(checkStartCoverage: false)
        try editor.press("transcript.reviewEdit", role: "AXButton")
        _ = try editor.control("Occurrence 1 · Cut 00:03.000–00:04.000 · Group 00:03.000–00:04.000", role: "AXStaticText")
        _ = try editor.control("Occurrence 2 · Cut 00:07.000–00:08.000 · Group 00:03.000–00:04.000", role: "AXStaticText")
        try editor.press("transcript.apply", role: "AXButton")
        _ = try editor.control("close.mov switch at 00:03.000", role: "AXButton")
        try editor.press("Save Project", role: "AXButton")
        _ = try wait("saved close camera marker at Group 3") {
            let switches = projectJSON(project)?["switches"] as? [[String: String]]
            return switches == [["angle_id": "wide", "group_time": "0"], ["angle_id": "close", "group_time": "3"]] ? true : nil
        }
    }
    print("Verified native word-edge camera coverage, review dismissal, both repeated occurrence times, and the exact saved switch")
}

func main() throws {
    let arguments = CommandLine.arguments
    let benchmark = arguments.count == 4 && arguments[2] == "--benchmark"
    let switchCameras = arguments.count == 4 && arguments[2] == "--switch-cameras"
    let transcribe = arguments.count == 5 && ["--transcribe", "--reconcile"].contains(arguments[2])
    let reconcile = transcribe && arguments[2] == "--reconcile"
    guard arguments.count == 3 || benchmark || switchCameras || transcribe else {
        throw Failure("Usage: swift Tests/Integration/transcript_gui.swift MPCut.app FIXTURE_DIR | --benchmark OUTPUT_DIR | --switch-cameras FIXTURE_DIR | --transcribe or --reconcile FIXTURE_DIR HELPER")
    }
    guard AXIsProcessTrusted() else { throw Failure("Allow Accessibility access for the test terminal") }
    let fm = FileManager.default
    let bundle = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let fixtures = URL(fileURLWithPath: arguments[transcribe || switchCameras ? 3 : 2]).standardizedFileURL
    let cache = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let scratch = cache.appendingPathComponent("mpcut-transcript-gui-" + UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: scratch) }
    let preferences = scratch.appendingPathComponent("home/Library/Preferences", isDirectory: true)
    try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
    let home = scratch.appendingPathComponent("home", isDirectory: true)
    if switchCameras {
        try exerciseCameraSwitch(bundle, fixture: fixtures, scratch: scratch, home: home)
        return
    }
    if benchmark {
        try runBenchmark(bundle, scratch: scratch, home: home, output: URL(fileURLWithPath: arguments[3]))
        return
    }
    if transcribe {
        let helper = URL(fileURLWithPath: arguments[4]).standardizedFileURL
        guard fm.isExecutableFile(atPath: helper.path) else { throw Failure("The specified Transcriberrr helper is unavailable") }
        let projectName = reconcile ? "interview.cut" : "sequence.cut"
        let inputs = reconcile ? [projectName, "wide.mov", "close.mov", "lav.wav"] : [projectName, "lav.wav"]
        for name in inputs {
            try fm.copyItem(at: fixtures.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
        }
        let project = scratch.appendingPathComponent(projectName)
        try withEditor(bundle, opening: project, home: home, helper: helper) { editor in
            try exerciseTranscription(editor, project: project)
            if reconcile { try exerciseReconciliation(editor, project: project) }
        }
        return
    }
    let staged = try stageFixtures(fixtures, in: scratch)
    let sequence = staged.appendingPathComponent("parity.cut")
    try withEditor(bundle, opening: sequence, home: home) {
        try exerciseSequence($0, project: sequence, transcript: staged.appendingPathComponent("parity-words.json"))
    }
    try withEditor(bundle, opening: sequence, home: home) {
        try $0.showTranscript()
        try $0.search("remove")
        try $0.expectResults("Match 1 of 1")
        print("Verified the attached transcript after reopening the saved sequence")
    }
    let interview = staged.appendingPathComponent("interview.cut")
    try withEditor(bundle, opening: interview, home: home) {
        try exerciseMulticam($0, transcript: staged.appendingPathComponent("close.srt"))
    }
    let queue = staged.appendingPathComponent("queue.cut")
    let snapshot = staged.appendingPathComponent("Camera quote.cut")
    try withEditor(bundle, opening: queue, home: home) {
        try exerciseMulticamQueue($0, project: queue, transcript: staged.appendingPathComponent("queue-words.json"), snapshot: snapshot)
    }
    try withEditor(bundle, opening: snapshot, home: home) {
        try $0.showTranscript()
        try $0.search("queuing excerpts")
        try $0.expectResults("Match 1 of 1")
    }
    try verifyQueueRender(bundle, snapshot: snapshot, sourceAudio: staged.appendingPathComponent("lav.wav"))
    print("Verified the native multicam excerpt snapshot, queue export, camera cut, and sample-exact fixed lav after modifying the original")
}

do { try main() }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
