// Run with: swift scripts/first-cut.swift /path/to/MPCut.app NEW_OUTPUT_DIRECTORY
// Use a logged-in Mac with Accessibility and Screen Recording access for the terminal.
import AppKit
import ApplicationServices

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func wait<T>(_ description: String, for result: () -> T?) throws -> T {
    let end = Date().addingTimeInterval(20)
    repeat {
        if let value = result() { return value }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < end
    throw Failure("Timed out waiting for " + description)
}

func run(_ executable: URL, _ arguments: [String]) throws {
    let task = Process()
    task.executableURL = executable
    task.arguments = arguments
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw Failure(executable.lastPathComponent + " failed") }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func find(_ element: AXUIElement, role: String, label: String? = nil) -> AXUIElement? {
    if attribute(element, "AXRole") as? String == role,
       label == nil || ["AXTitle", "AXDescription"].contains(where: { attribute(element, $0) as? String == label }) {
        return element
    }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
        if let match = find(child, role: role, label: label) { return match }
    }
    return nil
}

struct Editor {
    let pid: pid_t
    var app: AXUIElement { AXUIElementCreateApplication(pid) }

    func control(_ role: String, _ label: String? = nil) throws -> AXUIElement {
        try wait(label ?? role) {
            for window in attribute(app, "AXWindows") as? [AXUIElement] ?? [] {
                if let match = find(window, role: role, label: label) { return match }
            }
            return nil
        }
    }

    func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], text: String? = nil) throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        _ = try wait("editor keyboard focus") { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? true : nil }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            if let text {
                let chars = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            }
            event.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    func goTo(_ path: String) throws {
        try key(5, [.maskCommand, .maskShift]) // Go to Folder
        let parent = try control("AXSheet")
        _ = try wait("Go to Folder path field") {
            let children = attribute(parent, "AXChildren") as? [AXUIElement] ?? []
            for child in children {
                if let nested = find(child, role: "AXSheet"),
                   let field = find(nested, role: "AXTextField") { return field }
            }
            return nil as AXUIElement?
        }
        try key(0, .maskCommand)
        try key(0, text: path)
        // Allow the native file picker to resolve the typed path.
        Thread.sleep(forTimeInterval: 0.5)
        try key(36)
    }

    func press(_ label: String, inSheet: Bool = false) throws {
        let button: AXUIElement
        if inSheet {
            let sheet = try control("AXSheet")
            button = try wait(label) { find(sheet, role: "AXButton", label: label) }
        } else {
            button = try control("AXButton", label)
        }
        _ = try wait(label + " to become available") { attribute(button, "AXEnabled") as? Bool == true ? true : nil }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        else { throw Failure("Could not press " + label) }
    }

    func seek(_ seconds: Double) throws {
        let ruler = try control("AXSlider", "Timeline ruler")
        guard AXUIElementSetAttributeValue(ruler, kAXValueAttribute as CFString, NSNumber(value: seconds)) == .success
        else { throw Failure("Could not seek on the timeline ruler") }
    }

    func snapshot(_ destination: URL) throws {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        guard let window = windows?.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0 }),
              let number = window[kCGWindowNumber as String] as? Int else { throw Failure("No editor window to capture") }
        try run(URL(fileURLWithPath: "/usr/sbin/screencapture"), ["-x", "-o", "-l", String(number), "-t", "jpg", destination.path])
    }
}

func walkthrough() throws {
    guard CommandLine.arguments.count == 3 else { throw Failure("Usage: swift scripts/first-cut.swift MPCut.app NEW_OUTPUT_DIRECTORY") }
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw Failure("Allow Accessibility and Screen Recording for this terminal") }
    let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let folder = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    guard mkdir(folder.path, 0o700) == 0 else {
        throw Failure("Choose a new output directory under an existing folder: " + String(cString: strerror(errno)))
    }
    let media = folder.appendingPathComponent("Practice.mov")
    let project = folder.appendingPathComponent("First Cut.cut")
    let ffmpeg = app.appendingPathComponent("Contents/Helpers/ffmpeg")
    try run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=6",
                     "-c:v", "prores_videotoolbox", "-pix_fmt", "yuv422p10le", media.path])
    // A named empty project keeps the edit and autosaves separate from the user's windows.
    try Data(#"{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[]}"#.utf8).write(to: project)
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.arguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)",
                        "-export_movie_default_mode", "copy", "-timeline_snap_target", "off", "-automation_local_mcp_enabled", "NO"]
    var launched: Result<NSRunningApplication, Error>?
    NSWorkspace.shared.open([project], withApplicationAt: app, configuration: config) { application, error in
        if let application { launched = .success(application) } else { launched = .failure(error ?? Failure("Launch failed")) }
    }
    let application = try wait("MPCut to launch") { launched }.get()
    var completed = false
    defer {
        if completed { application.terminate() } else { application.forceTerminate() }
    }
    let editor = Editor(pid: application.processIdentifier)
    application.activate(options: [.activateAllWindows])
    _ = try editor.control("AXWindow", "First Cut")
    _ = try wait("editor focus") { NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.pid ? true : nil }
    try editor.key(31, .maskCommand) // Add Clips
    _ = try editor.control("AXButton", "Add")
    try editor.goTo(media.path)
    try editor.press("Add", inSheet: true)
    try editor.seek(2)
    try editor.press("Mark In")
    try editor.seek(4)
    try editor.press("Mark Out")
    Thread.sleep(forTimeInterval: 0.3)
    try editor.snapshot(folder.appendingPathComponent("first-cut-marks.jpg"))
    try editor.key(51) // Delete
    try editor.key(1, .maskCommand) // Save Project
    _ = try wait("saved source ranges 0–2 and 4–6") {
        guard let data = try? Data(contentsOf: project), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clips = object["clips"] as? [[String: Any]], clips.compactMap({ $0["from"] as? String }) == ["0", "4"],
              clips.compactMap({ $0["to"] as? String }) == ["2", "6"] else { return nil as Bool? }
        return true
    }
    try editor.snapshot(folder.appendingPathComponent("first-cut-result.jpg"))
    try editor.seek(1.75)
    try editor.key(49) // Space to preview across the join
    let position = try editor.control("AXButton", "Timeline position")
    _ = try wait("playback to cross the join") {
        guard let time = attribute(position, "AXValue") as? String,
              let seconds = Double(time.split(separator: ":").last ?? "") else { return nil as Bool? }
        return seconds > 2 ? true : nil
    }
    try editor.key(49)
    try editor.key(14, .maskCommand) // Export Media
    _ = try editor.control("AXSheet")
    // The native picker remembers the directory used to add Practice.mov.
    let wherePicker = try editor.control("AXPopUpButton", "Where:")
    if attribute(wherePicker, "AXValue") as? String != folder.lastPathComponent {
        try editor.goTo(folder.path)
    }
    guard attribute(wherePicker, "AXValue") as? String == folder.lastPathComponent else {
        throw Failure("The export sheet did not select the walkthrough output directory")
    }
    try editor.press("Export", inSheet: true)
    let movie = try wait("exported Practice Edit movie") {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first {
            $0.deletingPathExtension().lastPathComponent == "Practice Edit"
        }
    }
    try run(ffmpeg, ["-v", "error", "-xerror", "-i", movie.path, "-f", "framemd5", folder.appendingPathComponent("export.md5").path])
    try run(ffmpeg, ["-v", "error", "-i", media.path, "-f", "framemd5", folder.appendingPathComponent("source.md5").path])
    func frames(_ name: String) throws -> [Substring] {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: ",").last }
    }
    let source = try frames("source.md5")
    let output = try frames("export.md5")
    guard source.count == 144, output == Array(source[..<48]) + Array(source[96...]) else {
        throw Failure("The export did not match the 96 retained source frames")
    }
    completed = true
    print("Verified the saved edit and all 96 exported frames in " + folder.path)
}

do { try walkthrough() } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
