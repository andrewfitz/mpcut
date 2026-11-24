// Run through participant_gui.py in a logged-in Mac session with Accessibility access.
import AppKit
import ApplicationServices

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func wait<T>(_ description: String, timeout: TimeInterval = 12, _ inspect: () throws -> T?) throws -> T {
    let end = Date().addingTimeInterval(timeout)
    repeat {
        if let result = try inspect() { return result }
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
        func menuButton() -> AXUIElement? {
            controls(menu).first { node in
                ["AXMenuButton", "AXPopUpButton"].contains(value(node, "AXRole") as String? ?? "")
                    && value(node, "AXEnabled") as Bool? != false
            }
        }
        for _ in 0..<3 {
            let button = try wait(menu + " menu", menuButton)
            try press(button, description: menu)
            if let item = try? wait(name, timeout: 3, {
                controls(name, role: "AXMenuItem", in: menuButton()).first
                    ?? controls(name, role: "AXMenuItem").first
            }) {
                try press(item, description: name)
                return
            }
        }
        throw Failure("Could not find \(name) in \(menu)")
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

    func seek(_ seconds: String, displayed: String) throws {
        try press("Timeline position", role: "AXButton")
        let field = try wait("focused timeline position") {
            controls("Enter playhead time", role: "AXTextField").first {
                value($0, "AXFocused") as Bool? == true
            }
        }
        let previous: String = value(field, "AXValue") ?? ""
        var range = CFRange(location: 0, length: previous.utf16.count)
        guard let selected = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, selected) == .success,
              AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, seconds as CFString) == .success else {
            throw Failure("Could not enter timeline position " + seconds)
        }
        guard AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success else {
            throw Failure("Could not submit timeline position " + seconds)
        }
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
            controls(name, role: "AXTextField").first {
                value($0, "AXValue") as String? == name
            }
        }
    }

    func bindSpeaker(_ name: String) throws {
        try choose(name, from: "Bind Transcript Speakers")
        _ = try wait(name + " binding to enable Filter Transcript") {
            controls("Filter Transcript", role: "AXButton").first { value($0, "AXEnabled") as Bool? != false }
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
        try press("Save Project", role: "AXButton")
        _ = try wait("project file to be saved") {
            guard let updated = try? Data(contentsOf: project), updated != data else { return nil as Data? }
            return updated
        }
    }

    func verifySpeakerBindings(in project: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any]
        let participants = json?["participants"] as? [String: Any]
        let people = participants?["people"] as? [[String: Any]] ?? []
        for (personID, speakerID) in [("host", "speaker-0"), ("guest", "speaker-1")] {
            let person = people.first { $0["id"] as? String == personID }
            let speakers = person?["speakers"] as? [[String: String]] ?? []
            guard speakers == [["attachment_id": "overlap", "speaker_id": speakerID]] else {
                throw Failure("Saved \(personID) speaker bindings differ: \(speakers)")
            }
        }
    }

    func reviewScan(evidence: URL?) throws {
        try press("Scan Participants", role: "AXButton")
        _ = try wait("participant scan review", timeout: 60) {
            nodes().first {
                labels($0).contains { $0.hasSuffix(" detected appearances") && !$0.hasPrefix("0 ") }
            }
        }
        try capture("participant-scan-review", evidence: evidence)
        print("Verified native participant scan review")

        try press("Layout Change Markers", role: "AXDisclosureTriangle")
        try press("Review Marker Candidates", role: "AXButton")
        let candidate = try wait("layout change marker candidates") {
            nodes().first { node in
                value(node, "AXRole") as String? == "AXButton"
                    && labels(node).contains { $0.hasPrefix("1 s · ") && $0.contains("participants changed") }
            }
        }
        try press(candidate, description: "one-second layout change marker")
        _ = try wait("marker jump to one second") {
            controls("Timeline position", role: "AXButton").first {
                value($0, "AXValue") as String? == "00:01.000"
            }
        }
        try capture("participant-layout-markers", evidence: evidence)
        print("Verified layout change marker review and timeline jump")

        try press("Review Reconciliation…", role: "AXButton")
        _ = try control("Reconcile Participant Geometry")
        _ = try control("Replace Geometry", role: "AXButton")
        try capture("participant-reconciliation-review", evidence: evidence)
        try press("Cancel", role: "AXButton")
        print("Verified reconciliation review and cancel")

    }

    func acceptAutomaticFeeds(in project: URL, evidence: URL?) throws {
        for (current, layout) in [("Meeting", "Fixed Feed Grid"), ("Fixed Feed Grid", "Automatic Feeds")] {
            try choose(layout, from: controls("Scan Layout", role: "AXPopUpButton").isEmpty ? current : "Scan Layout")
            let button = try wait(layout + " selection") {
                guard !controls(layout, role: "AXPopUpButton").isEmpty,
                      controls("Accept Geometry", role: "AXButton").isEmpty else { return nil as AXUIElement? }
                return controls("Scan Feeds", role: "AXButton").first { value($0, "AXEnabled") as Bool? == true }
            }
            try press(button, description: "scan with " + layout)
            if layout == "Automatic Feeds" {
                let percent = try wait("live feed scan percentage") { () -> Int? in
                    for node in nodes() where value(node, "AXRole") as String? == "AXProgressIndicator" {
                        guard labels(node).contains("Scanning feeds") else { continue }
                        if let fraction: Double = value(node, "AXValue"), fraction > 0 && fraction < 1 {
                            return Int((100 * fraction).rounded())
                        }
                        for label in labels(node) where label.hasSuffix("%") {
                            if let percent = Int(label.dropLast()), (1..<100).contains(percent) { return percent }
                        }
                    }
                    return nil
                }
                print("Observed live scan bar at \(percent)%")
                try capture("feed-scan-progress", evidence: evidence)
            }
            _ = try wait(layout + " review", timeout: 90) {
                controls("Accept Geometry", role: "AXButton").first { value($0, "AXEnabled") as Bool? == true }
            }
            _ = try wait(layout + " scan progress at 100%") {
                nodes().first { node in
                    value(node, "AXRole") as String? == "AXProgressIndicator"
                        && (labels(node).contains("100%") || value(node, "AXValue") as Double? == 1)
                }
            }
            _ = try control("100%", role: "AXStaticText")
            if layout == "Fixed Feed Grid" {
                try seek("2.25", displayed: "00:02.250")
                _ = try control("Four-second grid.mov", role: "AXStaticText")
                _ = try wait("alternate source ready for its first scan") {
                    guard controls("100%", role: "AXStaticText").isEmpty,
                          controls("Accept Geometry", role: "AXButton").isEmpty else { return nil as AXUIElement? }
                    return controls("Scan Participants", role: "AXButton").first { value($0, "AXEnabled") as Bool? == true }
                }
                try seek("0", displayed: "00:00.000")
                _ = try control("Camera feeds.mov", role: "AXStaticText")
                _ = try control("100%", role: "AXStaticText")
                _ = try control("Accept Geometry", role: "AXButton")
                print("Verified the scan review follows the selected recording across camera switches")
            }
        }
        try capture("automatic-feed-scan", evidence: evidence)
        try press("Accept Geometry", role: "AXButton")
        _ = try wait("accepted feed geometry") {
            controls("Accept Geometry", role: "AXButton").isEmpty ? true : nil
        }
        try save(project)
    }

    func capture(_ name: String, evidence: URL?) throws {
        guard let evidence else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        capture.arguments = ["backstage", "screenshot", "--pid", String(pid), "-o",
                             evidence.appendingPathComponent(name + ".png").path]
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
    guard AXIsProcessTrusted() else {
        throw Failure("The terminal needs Accessibility access")
    }
    let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let project = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let evidence = CommandLine.arguments.dropFirst(3).first.map { URL(fileURLWithPath: $0) }
    guard let rawPID = ProcessInfo.processInfo.environment["MPCUT_TEST_EDITOR_PID"],
          let pid = Int32(rawPID), let app = NSRunningApplication(processIdentifier: pid),
          app.bundleURL?.resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath() else {
        throw Failure("Run participant_gui.py to launch the test editor on Backstage")
    }
    let editor = Editor(app: app)
    AXUIElementSetMessagingTimeout(editor.root, 3)

    do {
        _ = try wait("synthetic project window", timeout: 35) {
            if app.isTerminated { throw Failure("Test editor exited before opening the synthetic project (PID \(editor.pid))") }
            return editor.windows.first {
                (value($0, "AXTitle") as String?)?.hasPrefix(project.deletingPathExtension().lastPathComponent) == true
            }
        }
        try editor.inspector("Feeds")
        if ProcessInfo.processInfo.environment["MPCUT_GUI_FEEDS_ONLY"] == "1" {
            try editor.acceptAutomaticFeeds(in: project, evidence: evidence)
            return
        }
        try editor.pin("Host")
        try editor.bindSpeaker("Host Voice · overlap")
        try editor.pin("Guest")
        try editor.choose("recorder.mov · Stream 1", from: "Bind Audio")
        _ = try editor.control("Audio · recorder.mov, stream 1", role: "AXMenuButton")
        try editor.bindSpeaker("Guest Voice · overlap")
        try editor.save(project)
        try editor.verifySpeakerBindings(in: project)
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
        _ = try wait("guest stage source range") {
            let start = editor.controls("Source start time", role: "AXTextField").first
            let end = editor.controls("Source end time", role: "AXTextField").first
            guard let start, let end else { return nil as Bool? }
            return value(start, "AXValue") as String? == "2" && value(end, "AXValue") as String? == "3" ? true : nil
        }
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
        let dialogue = try editor.control("transcript.dialogue")
        func showsWord(_ word: String) -> Bool {
            editor.nodes(in: dialogue).contains { node in
                labels(node).contains { $0.split(whereSeparator: { $0.isWhitespace }).contains(Substring(word)) }
            }
        }
        _ = try wait("filtered guest dialogue") { showsWord("guestword") ? true : nil }
        guard !showsWord("hostword") else {
            throw Failure("Transcript filter still shows the other participant")
        }
        try editor.inspector("Feeds")
        try editor.press("Composition and Export…", role: "AXButton")
        _ = try editor.control("Participant Composition")
        let layoutID = "participant.composition.layout"
        try editor.choose("Pair", from: editor.controls(layoutID).isEmpty ? "Original" : layoutID)
        _ = try editor.control("Pair", role: "AXPopUpButton")
        try editor.choose("Host", from: "Add Slot")
        _ = try editor.control("Host", role: "AXDisclosureTriangle")
        try editor.choose("Guest", from: "Add Slot")
        _ = try editor.control("Guest", role: "AXDisclosureTriangle")
        try editor.press("Preview", role: "AXButton")
        let previewID = "participant.composition.preview"
        if !editor.controls(previewID).isEmpty {
            _ = try wait("rendered pair preview") {
                editor.controls(previewID).first { value($0, "AXValue") as String? == "Rendered" }
                    ?? editor.controls("Source", role: "AXImage").first
            }
        }
        _ = try wait("preview to finish") {
            editor.controls("Preview", role: "AXButton").first { value($0, "AXEnabled") as Bool? != false }
        }
        try editor.capture("pair-layout-offscreen", evidence: evidence)
        try editor.press("Check Export", role: "AXButton")
        _ = try wait("export preflight for a five-second pair layout") {
            editor.nodes().first {
                labels($0).contains {
                    $0.contains("1920 × 1080 at 30 fps") && $0.contains("5 s · 150 frames")
                        && $0.contains("Audio · Silence") && !$0.contains("Export blocked")
                }
            }
        }
        try editor.press("Save Composition", role: "AXButton")
        _ = try editor.control("Composition saved to the project.")
        try editor.press("Done", role: "AXButton")
        try editor.save(project)
        print("Verified overlapping speakers, appearance selection and override, offscreen roster, and participant transcript filter")
        print("Verified pair composition preview, preflight action and project save")
        let scan = editor.controls("Scan Participants", role: "AXButton").first
        let requireScan = ProcessInfo.processInfo.environment["MPCUT_GUI_REQUIRE_SCAN"] == "1"
        if requireScan || scan.map({ value($0, "AXEnabled") as Bool? == true }) == true {
            try editor.reviewScan(evidence: evidence)
        }
    } catch {
        editor.dump()
        throw error
    }
}

do { try run() }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
