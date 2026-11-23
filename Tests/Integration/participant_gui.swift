// Run through participant_gui.py in a logged-in Mac session with Accessibility access.
import AppKit
import ApplicationServices

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func wait<T>(_ description: String, timeout: TimeInterval = 12, _ inspect: () -> T?) throws -> T {
    let end = Date().addingTimeInterval(timeout)
    repeat {
        if let result = inspect() { return result }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < end
    throw Failure("Timed out waiting for " + description)
}

func value<T>(_ node: AXUIElement, _ attribute: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
    return result as? T
}

func descendants(_ node: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 30 else { return [node] }
    let children: [AXUIElement] = value(node, "AXChildren") ?? []
    return [node] + children.flatMap { descendants($0, depth: depth + 1) }
}

func labels(_ node: AXUIElement) -> [String] {
    ["AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXHelp", "AXPlaceholderValue"].compactMap {
        value(node, $0)
    }
}

struct Editor {
    let app: NSRunningApplication
    var pid: pid_t { app.processIdentifier }
    var root: AXUIElement { AXUIElementCreateApplication(pid) }
    var windows: [AXUIElement] { value(root, "AXWindows") ?? [] }

    func nodes(in container: AXUIElement? = nil) -> [AXUIElement] {
        (container.map { [$0] } ?? windows).flatMap { descendants($0) }
    }

    func controls(_ name: String, role: String? = nil, in container: AXUIElement? = nil) -> [AXUIElement] {
        nodes(in: container).filter { node in
            (role == nil || value(node, "AXRole") as String? == role) && labels(node).contains(name)
        }
    }

    func control(_ name: String, role: String? = nil) throws -> AXUIElement {
        try wait(name) { controls(name, role: role).first }
    }

    func press(_ node: AXUIElement, description: String) throws {
        let status = AXUIElementPerformAction(node, kAXPressAction as CFString)
        // SwiftUI can destroy the pressed control during a successful action.
        // Check the resulting control or state before continuing the workflow.
        guard status == .success || status == .failure else {
            throw Failure("Could not press \(description) (\(status.rawValue))")
        }
    }

    func press(_ name: String, role: String? = nil) throws {
        let node = try wait(name + " enabled") {
            controls(name, role: role).first { value($0, "AXEnabled") as Bool? != false }
        }
        try press(node, description: name)
    }

    func choose(_ name: String, from menu: String) throws {
        let button = try control(menu)
        try press(button, description: menu)
        let option = try wait(name) {
            controls(name, role: "AXMenuItem", in: button).first ?? controls(name, role: "AXMenuItem").first
        }
        try press(option, description: name)
    }

    func inspector(_ name: String) throws {
        let picker = try control("Multicam inspector")
        if value(picker, "AXRole") as String? == "AXPopUpButton" {
            try choose(name, from: "Multicam inspector")
        } else {
            let tab = try wait(name) { controls(name, role: "AXRadioButton", in: picker).first }
            try press(tab, description: name)
        }
    }

    func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) throws {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                throw Failure("Could not construct keyboard input")
            }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.postToPid(pid)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    }

    func seek(_ seconds: String, displayed: String) throws {
        try press("Timeline position", role: "AXButton")
        _ = try wait("focused timeline position") {
            controls("Enter playhead time", role: "AXTextField").first {
                value($0, "AXFocused") as Bool? == true
            }
        }
        try key(0, flags: .maskCommand)
        try key(0, text: seconds)
        try key(36)
        _ = try wait("timeline at " + displayed) {
            controls("Timeline position", role: "AXButton").first {
                value($0, "AXValue") as String? == displayed
            }
        }
    }

    func speaker(_ name: String, offscreen: Bool) throws {
        _ = try wait(name + (offscreen ? " speaking offscreen" : " speaking onscreen")) {
            nodes().first { node in
                guard value(node, "AXRole") as String? == "AXButton" else { return false }
                let text = descendants(node).flatMap(labels).joined(separator: " ")
                return text.contains(name) && text.contains("Speaking") && text.contains("Offscreen") == offscreen
            }
        }
    }

    func pin(_ name: String) throws {
        let row = try wait(name + " roster row") {
            nodes().first { node in
                guard value(node, "AXRole") as String? == "AXButton",
                      !labels(node).contains("Select this appearance") else { return false }
                return descendants(node).flatMap(labels).contains(name)
            }
        }
        try press(row, description: name + " roster row")
        _ = try wait(name + " pinned") {
            controls("Participant name", role: "AXTextField").first {
                value($0, "AXValue") as String? == name
            }
        }
    }

    func appearances(_ name: String) -> [AXUIElement] {
        controls(name, role: "AXButton").filter { labels($0).contains("Select this appearance") }
    }

    func width(_ node: AXUIElement) -> CGFloat {
        guard let size: AXValue = value(node, "AXSize") else { return 0 }
        var dimensions = CGSize.zero
        AXValueGetValue(size, .cgSize, &dimensions)
        return dimensions.width
    }

    func save(_ project: URL) throws {
        let data = try Data(contentsOf: project)
        try key(1, flags: .maskCommand)
        _ = try wait("project file to be saved") {
            guard let updated = try? Data(contentsOf: project), updated != data else { return nil as Data? }
            return updated
        }
    }

    func capture(_ name: String, evidence: URL?) throws {
        guard let evidence else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        guard let entry = windows?.first(where: {
            $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0
        }), let id = entry[kCGWindowNumber as String] as? Int else {
            throw Failure("Could not find the test window for " + name)
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(id), evidence.appendingPathComponent(name + ".png").path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw Failure("Could not capture " + name) }
    }

    func dump() {
        for node in nodes() {
            let text = labels(node).filter { !$0.isEmpty }.joined(separator: " · ")
            if !text.isEmpty { fputs("\(value(node, "AXRole") as String? ?? "") \(text)\n", stderr) }
        }
    }
}

func run() throws {
    guard (3...4).contains(CommandLine.arguments.count) else {
        throw Failure("Usage: participant_gui.swift APP PROJECT [EVIDENCE_DIRECTORY]")
    }
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        throw Failure("The terminal needs Accessibility access")
    }
    let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let project = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let evidence = CommandLine.arguments.dropFirst(3).first.map { URL(fileURLWithPath: $0) }
    let home = project.deletingLastPathComponent().appendingPathComponent("home/Library/Preferences")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let instance = "mpcut-test-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    defer {
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        cleanup.arguments = ["delete", "com.mpcut.test-preferences." + instance]
        cleanup.standardError = FileHandle.nullDevice
        if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
    }
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.activates = true
    config.addsToRecentItems = false
    config.arguments = [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
        "-AppleLanguages", "(en)", "-automation_local_mcp_enabled", "NO",
        "-analysis_sidecar_reuse_enabled", "NO",
    ]
    config.environment = [
        "MPCUT_TEST_SOCKET_DIRECTORY": instance,
        "CFFIXED_USER_HOME": home.deletingLastPathComponent().deletingLastPathComponent().path,
    ]
    let existing = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
    let previousFrontmost = NSWorkspace.shared.frontmostApplication
    var launched: Result<NSRunningApplication, Error>?
    NSWorkspace.shared.open([project], withApplicationAt: bundle, configuration: config) { app, error in
        if let app { launched = .success(app) }
        else { launched = .failure(error ?? Failure("Could not launch test editor")) }
    }
    let app = try wait("isolated test launch", timeout: 30) { launched }.get()
    guard !existing.contains(app.processIdentifier),
          app.bundleURL?.resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath() else {
        throw Failure("Launch Services did not open a new instance of the test bundle")
    }
    defer {
        let restoreFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        if !app.isTerminated { app.forceTerminate() }
        _ = try? wait("isolated editor to exit") { app.isTerminated ? true : nil }
        if restoreFocus { previousFrontmost?.activate(options: []) }
    }
    let editor = Editor(app: app)
    AXUIElementSetMessagingTimeout(editor.root, 3)

    do {
        _ = try wait("synthetic project window", timeout: 35) {
            editor.windows.first {
                (value($0, "AXTitle") as String?)?.hasPrefix(project.deletingPathExtension().lastPathComponent) == true
            }
        }
        try editor.inspector("Participants")
        try editor.pin("Host")
        try editor.choose("Host Voice · overlap", from: "Bind Transcript Speakers")
        try editor.pin("Guest")
        try editor.choose("recorder.mov · Stream 1", from: "Bind Audio")
        try editor.choose("Guest Voice · overlap", from: "Bind Transcript Speakers")
        try editor.seek("2.25", displayed: "00:02.250")
        try editor.speaker("Host", offscreen: false)
        try editor.speaker("Guest", offscreen: false)
        _ = try wait("both guest appearances") {
            editor.appearances("Guest").count == 2 ? true : nil
        }
        let tiles = editor.appearances("Guest").sorted { editor.width($0) > editor.width($1) }
        guard let stage = tiles.first, let thumbnail = tiles.last, editor.width(stage) > editor.width(thumbnail) else {
            throw Failure("Could not distinguish the stage from the guest thumbnail")
        }
        try editor.press(stage, description: "guest stage appearance")
        try editor.press("Use This Appearance", role: "AXButton")
        try editor.capture("overlapping-speakers", evidence: evidence)
        try editor.seek("3.25", displayed: "00:03.250")
        try editor.speaker("Host", offscreen: false)
        try editor.speaker("Guest", offscreen: true)
        guard editor.appearances("Guest").isEmpty else {
            throw Failure("An offscreen speaker still has a visible box")
        }
        try editor.capture("offscreen-speaker", evidence: evidence)
        try editor.press("Filter Transcript", role: "AXButton")
        _ = try editor.control("transcript.import")
        _ = try editor.control("guestword")
        guard editor.controls("hostword").isEmpty else {
            throw Failure("Transcript filter still shows the other participant")
        }
        try editor.inspector("Participants")
        try editor.press("Composition and Export…", role: "AXButton")
        _ = try editor.control("Participant Composition")
        try editor.choose("Pair", from: "Layout")
        try editor.choose("Host", from: "Add Slot")
        try editor.choose("Guest", from: "Add Slot")
        try editor.press("Preview", role: "AXButton")
        _ = try editor.control("Rendered composition")
        try editor.capture("pair-layout-offscreen", evidence: evidence)
        try editor.press("Check Export", role: "AXButton")
        _ = try wait("publishable export report") {
            editor.nodes().first {
                labels($0).contains { $0.contains("\"publishable\" : true") }
            }
        }
        try editor.press("Save Composition", role: "AXButton")
        _ = try editor.control("Composition saved to the project.")
        try editor.press("Done", role: "AXButton")
        try editor.save(project)
        print("Verified overlapping speakers, appearance selection and override, offscreen roster, and participant transcript filter")
        print("Verified pair composition preview, preflight action and project save")
    } catch {
        editor.dump()
        throw error
    }
}

do { try run() }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
