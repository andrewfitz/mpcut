// Run through participant_gui.py in a logged-in Mac session with Accessibility and Screen Recording access.
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

    func controls(_ id: String, role: String? = nil, in container: AXUIElement? = nil) -> [AXUIElement] {
        nodes(in: container).filter { node in
            (role == nil || value(node, "AXRole") as String? == role)
                && value(node, "AXIdentifier") as String? == id
        }
    }

    func control(_ id: String, role: String? = nil) throws -> AXUIElement {
        try wait(id) { controls(id, role: role).first }
    }

    func press(_ node: AXUIElement, description: String) throws {
        let status = AXUIElementPerformAction(node, kAXPressAction as CFString)
        // A successful SwiftUI action can replace its control or attach a popover
        // before the reply arrives. Callers check the resulting control or state.
        guard status == .success || status == .failure || status == .cannotComplete else {
            throw Failure("Could not press \(description) (\(status.rawValue))")
        }
    }

    func press(_ id: String, role: String? = nil) throws {
        let node = try wait(id + " enabled") {
            controls(id, role: role).first { value($0, "AXEnabled") as Bool? != false }
        }
        try press(node, description: id)
    }

    func menuButton(_ id: String) -> AXUIElement? {
        nodes().first { node in
            guard let identifier: String = value(node, "AXIdentifier"),
                  let role: String = value(node, "AXRole"),
                  value(node, "AXEnabled") as Bool? != false else { return false }
            if role == "AXMenuButton" { return identifier == id }
            // A menu-style Picker can inherit the selected item's identifier.
            return role == "AXPopUpButton" && (identifier == id || identifier.hasPrefix(id + "."))
        }
    }

    func choose(_ itemID: String, from menu: String) throws {
        for _ in 0..<3 {
            let button = try wait(menu + " menu") { menuButton(menu) }
            try press(button, description: menu)
            if let item = try? wait(itemID, timeout: 5, { () -> AXUIElement? in
                controls(itemID, role: "AXMenuItem", in: button).first
                    ?? controls(itemID, role: "AXMenuItem").first
            }) {
                try press(item, description: itemID)
                return
            }
        }
        throw Failure("Could not find \(itemID) in \(menu)")
    }

    func openFeeds() throws {
        let id = "multicam.inspector"
        let picker = try wait(id) { controls(id, role: "AXRadioGroup").first ?? menuButton(id) }
        if value(picker, "AXRole") as String? == "AXPopUpButton" {
            try choose("multicam.inspector.participants", from: id)
        } else {
            let tab = try wait("participant inspector tab") {
                controls("multicam.inspector.participants", role: "AXRadioButton", in: picker).first
            }
            try press(tab, description: "participant inspector tab")
        }
    }

    func seek(_ seconds: String, displayed: String) throws {
        try press("timeline.position", role: "AXButton")
        let field = try wait("focused timeline position") {
            controls("timeline.position.input", role: "AXTextField").first {
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
            controls("timeline.position", role: "AXButton").first {
                value($0, "AXValue") as String? == displayed
            }
        }
    }

    func speaker(_ id: String, offscreen: Bool) throws {
        _ = try wait(id + (offscreen ? " speaking offscreen" : " speaking onscreen")) {
            controls("participant.roster.\(id)", role: "AXButton").first { node in
                let text = descendants(node).flatMap(labels).joined(separator: " ")
                return text.contains("Speaking") && text.contains("Offscreen") == offscreen
            }
        }
    }

    func pin(_ id: String, name: String) throws {
        try press("participant.roster.\(id)", role: "AXButton")
        _ = try wait(name + " pinned") {
            controls("participant.roster.name", role: "AXTextField").first {
                value($0, "AXValue") as String? == name
            }
        }
    }

    func bindSpeaker(_ id: String, to feed: String) throws {
        try choose("participant.bind.speaker.overlap.\(id)", from: "participant.bind.speakers.\(feed)")
        _ = try wait(id + " binding to enable transcript filtering") {
            controls("participant.transcript.filter", role: "AXButton").first { value($0, "AXEnabled") as Bool? != false }
        }
    }

    func save(_ project: URL) throws {
        let data = try Data(contentsOf: project)
        try press("multicam.project.save", role: "AXButton")
        _ = try wait("project file to be saved") {
            guard let updated = try? Data(contentsOf: project), updated != data else { return nil as Data? }
            return updated
        }
    }

    func reviewScan(evidence: URL?) throws {
        try choose("participant.scan.find", from: "tiles.actions")
        try choose("participant.scan.layout.meeting", from: "participant.scan.layout")
        try press("participant.scan.start", role: "AXButton")
        _ = try wait("participant scan review", timeout: 60) {
            controls("participant.scan.appearances", role: "AXStaticText").first {
                labels($0).contains { label in Int(label.split(separator: " ").first ?? "").map { $0 > 0 } == true }
            }
        }
        try capture("participant-scan-review", evidence: evidence)
        print("Verified native participant scan review")

        try press("participant.markers", role: "AXDisclosureTriangle")
        try press("participant.markers.review", role: "AXButton")
        try press("participant.markers.candidate.1", role: "AXButton")
        _ = try wait("marker jump to one second") {
            controls("timeline.position", role: "AXButton").first {
                value($0, "AXValue") as String? == "00:01.000"
            }
        }
        try capture("participant-layout-markers", evidence: evidence)
        print("Verified layout change marker review and timeline jump")

        try press("participant.reconcile.open", role: "AXButton")
        _ = try control("participant.reconcile.title", role: "AXStaticText")
        _ = try control("participant.reconcile.apply", role: "AXButton")
        try capture("participant-reconciliation-review", evidence: evidence)
        try press("participant.reconcile.cancel", role: "AXButton")
        print("Verified reconciliation review and cancel")
    }

    func acceptAutomaticFeeds(in project: URL, evidence: URL?) throws {
        for id in ["fixed", "automatic"] {
            try choose("participant.scan.layout.\(id)", from: "participant.scan.layout")
            _ = try wait(id + " grid selection") {
                let hasGridFields = !controls("participant.scan.columns", role: "AXTextField").isEmpty
                return hasGridFields == (id == "fixed") ? true : nil
            }
            try press("participant.scan.start", role: "AXButton")
            if id == "automatic" {
                let percent = try wait("live feed scan percentage") { () -> Int? in
                    for node in controls("participant.scan.progress", role: "AXProgressIndicator") {
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
            _ = try wait(id + " review", timeout: 90) {
                controls("participant.scan.accept", role: "AXButton").first { value($0, "AXEnabled") as Bool? == true }
            }
            _ = try wait(id + " scan progress at 100%") {
                controls("participant.scan.progress", role: "AXProgressIndicator").first {
                    labels($0).contains("100%") || value($0, "AXValue") as Double? == 1
                }
            }
            try expectText("participant.scan.percent", equals: "100%")
            if id == "fixed" {
                try choose("tiles.recording.follow", from: "tiles.recording")
                try seek("2.25", displayed: "00:02.250")
                try expectText("participant.scan.source", equals: "Four-second grid.mov")
                _ = try wait("alternate source ready for its first scan") {
                    guard controls("participant.scan.percent", role: "AXStaticText").isEmpty,
                          controls("participant.scan.accept", role: "AXButton").isEmpty else { return nil as AXUIElement? }
                    return controls("participant.scan.start", role: "AXButton").first { value($0, "AXEnabled") as Bool? == true }
                }
                try seek("0", displayed: "00:00.000")
                try expectText("participant.scan.source", equals: "Camera feeds.mov")
                try expectText("participant.scan.percent", equals: "100%")
                _ = try control("participant.scan.accept", role: "AXButton")
                print("Verified the scan review follows the selected recording across camera switches")
                try press("participant.scan.discard", role: "AXButton")
            }
        }
        try capture("automatic-feed-scan", evidence: evidence)
        try press("participant.scan.accept", role: "AXButton")
        _ = try wait("accepted feed geometry") {
            controls("participant.scan.accept", role: "AXButton").isEmpty ? true : nil
        }
        try save(project)
    }

    func expectText(_ id: String, equals text: String) throws {
        _ = try wait(text) {
            controls(id, role: "AXStaticText").first { labels($0).contains(text) }
        }
    }

    enum MonitorMode: String { case source, output }

    func showMonitor(_ mode: MonitorMode) throws {
        let id = "tiles.monitor." + mode.rawValue
        let node = try control(id, role: "AXRadioButton")
        guard labels(node).contains(mode.rawValue.capitalized) else {
            throw Failure("Monitor toggle has no " + mode.rawValue.capitalized + " label")
        }
        try press(node, description: id)
    }

    func guestTileBounds() throws -> CGRect {
        let tile = try control("participant.appearance.gallery.guest-stage-16", role: "AXButton")
        guard let positionValue: AXValue = value(tile, "AXPosition"), let sizeValue: AXValue = value(tile, "AXSize") else {
            throw Failure("Guest stage tile has no accessibility bounds")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size), size.width > 10, size.height > 10 else {
            throw Failure("Guest stage tile has invalid accessibility bounds")
        }
        let status = try backstage(["status"])
        let result = try JSONSerialization.jsonObject(with: status) as? [String: Any]
        let daemon = result?["daemon"] as? [String: Any]
        let origin = daemon?["globalOrigin"] as? [String: CGFloat]
        guard let x = origin?["x"], let y = origin?["y"] else {
            throw Failure("Backstage did not report the display origin")
        }
        return CGRect(x: position.x - x, y: position.y - y, width: size.width, height: size.height)
    }

    func monitorPoint() throws -> CGPoint {
        try showMonitor(.source)
        let tile = try guestTileBounds()
        return CGPoint(x: tile.midX, y: tile.minY + tile.height * 0.55)
    }

    func drawingButton(_ titles: String...) throws -> AXUIElement {
        try wait(titles.joined(separator: " or ")) {
            nodes().first {
                value($0, "AXRole") as String? == "AXButton"
                    && value($0, "AXEnabled") as Bool? != false
                    && labels($0).contains(where: titles.contains)
            }
        }
    }

    func verifyDrawingOverTile() throws {
        try showMonitor(.source)
        let tile = try guestTileBounds()
        let draw = try drawingButton("Draw Tile", "Redraw Tile")
        try press(draw, description: "Draw Tile")
        _ = try drawingButton("Cancel Drawing")
        let points = [tile.midX, tile.midY, tile.maxX - tile.width * 0.1, tile.maxY - tile.height * 0.1]
        _ = try backstage(["drag"] + points.map { String(Int($0.rounded())) } + ["--pid", String(pid)])
        _ = try drawingButton("Add Tile", "Apply Box")
        let discard = try drawingButton("Discard Box")
        try press(discard, description: "Discard Box")
        _ = try wait("drawn box discarded") {
            nodes().contains { labels($0).contains("Discard Box") } ? nil : true
        }
        print("Verified drawing over an existing tile and discarding the resulting box")
    }

    enum FixtureColor: String { case red, green }

    func expectMonitorColor(_ expected: FixtureColor, at point: CGPoint, in directory: URL) throws {
        let imageURL = directory.appendingPathComponent("monitor-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        var observed = [CGFloat]()
        do {
            _ = try wait(expected.rawValue + " monitor pixels") {
                try screenshot(to: imageURL)
                let bitmap = try NSBitmapImageRep(data: Data(contentsOf: imageURL))
                guard let bitmap, x >= 2, y >= 2, x < bitmap.pixelsWide - 2, y < bitmap.pixelsHigh - 2 else {
                    throw Failure("Monitor sample lies outside the Backstage screenshot")
                }
                let pixels = [-2, 0, 2].flatMap { dx in
                    [-2, 0, 2].compactMap { dy in
                        bitmap.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.deviceRGB)
                    }
                }
                guard pixels.count == 9 else { throw Failure("Could not sample monitor pixels") }
                let color = pixels.reduce(into: (red: CGFloat.zero, green: CGFloat.zero, blue: CGFloat.zero)) {
                    $0.red += $1.redComponent / 9
                    $0.green += $1.greenComponent / 9
                    $0.blue += $1.blueComponent / 9
                }
                observed = [color.red, color.green, color.blue]
                let (primary, other) = expected == .red ? (color.red, color.green) : (color.green, color.red)
                return primary > 0.35 && primary > max(other, color.blue) * 1.4 ? true : nil
            }
        } catch {
            throw Failure("\(error.localizedDescription), sampled RGB \(observed) at \(point)")
        }
    }

    func verifyLiveSolo(in project: URL, evidence: URL?) throws {
        let point = try monitorPoint()
        let directory = project.deletingLastPathComponent()
        try expectMonitorColor(.green, at: point, in: directory)
        try showMonitor(.output)
        try expectMonitorColor(.green, at: point, in: directory)
        try pin("host", name: "Host")
        try press("tiles.feed.solo", role: "AXButton")
        try expectText("timeline.tile-layout.0", equals: "Solo · Host")
        try expectMonitorColor(.red, at: point, in: directory)
        try capture("solo-output", evidence: evidence)
        try showMonitor(.source)
        try expectMonitorColor(.green, at: point, in: directory)
        try capture("solo-source", evidence: evidence)
        try showMonitor(.output)
        try expectMonitorColor(.red, at: point, in: directory)
        try press("editor.history.undo", role: "AXButton")
        try expectMonitorColor(.green, at: point, in: directory)
        try press("editor.history.redo", role: "AXButton")
        try expectMonitorColor(.red, at: point, in: directory)
        print("Verified live Solo monitor pixels, Source/Output, undo, and redo")
    }

    func verifyReopenedSolo(in project: URL) throws {
        try seek("2.25", displayed: "00:02.250")
        let point = try monitorPoint()
        let directory = project.deletingLastPathComponent()
        try expectMonitorColor(.green, at: point, in: directory)
        try showMonitor(.output)
        try expectMonitorColor(.red, at: point, in: directory)
        print("Verified saved Solo layout in the reopened project")
    }

    func backstage(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["backstage"] + arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("Backstage \(arguments.first ?? "") failed: \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    func screenshot(to url: URL) throws {
        _ = try backstage(["screenshot", "--pid", String(pid), "-o", url.path])
    }

    func capture(_ name: String, evidence: URL?) throws {
        guard let evidence else { return }
        try screenshot(to: evidence.appendingPathComponent(name + ".png"))
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
        try editor.openFeeds()
        if ProcessInfo.processInfo.environment["MPCUT_GUI_REOPEN_ONLY"] == "1" {
            if ProcessInfo.processInfo.environment["MPCUT_GUI_REQUIRE_SCAN"] == "1" {
                _ = try editor.control("participant.scan.appearances", role: "AXStaticText")
                _ = try editor.control("participant.reconcile.open", role: "AXButton")
                try editor.press("participant.scan.discard", role: "AXButton")
                _ = try wait("pending review discarded") {
                    editor.controls("participant.scan.discard", role: "AXButton").isEmpty ? true : nil
                }
                print("Verified pending scan review was restored on reopen and could be discarded")
            }
            try editor.verifyReopenedSolo(in: project)
            return
        }
        if ProcessInfo.processInfo.environment["MPCUT_GUI_FEEDS_ONLY"] == "1" {
            try editor.acceptAutomaticFeeds(in: project, evidence: evidence)
            return
        }
        try editor.pin("host", name: "Host")
        try editor.bindSpeaker("speaker-0", to: "host")
        try editor.pin("guest", name: "Guest")
        try editor.choose("participant.bind.audio.recorder.1", from: "participant.bind.audio.guest")
        try editor.bindSpeaker("speaker-1", to: "guest")
        try editor.save(project)
        try editor.seek("2.25", displayed: "00:02.250")
        try editor.showMonitor(.source)
        try editor.speaker("host", offscreen: false)
        try editor.speaker("guest", offscreen: false)
        _ = try editor.control("participant.appearance.gallery.guest-thumb-16", role: "AXButton")
        try editor.press("participant.appearance.gallery.guest-stage-16", role: "AXButton")
        _ = try editor.control("tiles.tile.prefer", role: "AXButton")
        _ = try editor.backstage(["key", "esc", "--pid", String(editor.pid)])
        try editor.press("participant.appearance.use", role: "AXButton")
        try editor.capture("overlapping-speakers", evidence: evidence)
        try editor.verifyDrawingOverTile()
        try editor.verifyLiveSolo(in: project, evidence: evidence)
        try editor.showMonitor(.source)
        try editor.seek("3.25", displayed: "00:03.250")
        try editor.pin("guest", name: "Guest")
        try editor.speaker("host", offscreen: false)
        try editor.speaker("guest", offscreen: true)
        let guestBoxVisible = editor.nodes().contains {
            value($0, "AXRole") as String? == "AXButton"
                && (value($0, "AXIdentifier") as String?)?.hasPrefix("participant.appearance.gallery.guest-") == true
        }
        guard !guestBoxVisible else { throw Failure("An offscreen speaker still has a visible box") }
        try editor.capture("offscreen-speaker", evidence: evidence)
        try editor.press("participant.transcript.filter", role: "AXButton")
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
        try editor.openFeeds()
        try editor.save(project)
        print("Verified overlapping speakers, appearance selection and override, offscreen roster, and participant transcript filter")
        if ProcessInfo.processInfo.environment["MPCUT_GUI_REQUIRE_SCAN"] == "1" {
            try editor.reviewScan(evidence: evidence)
        }
    } catch {
        editor.dump()
        throw error
    }
}

do { try run() }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
