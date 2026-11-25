import AppKit
import ApplicationServices
import Foundation

struct ProbeError: Error, CustomStringConvertible {
    var description: String
}

func read<T>(_ node: AXUIElement, _ key: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, key as CFString, &result) == .success else { return nil }
    return result as? T
}

func find(_ name: String, under root: AXUIElement, role: String? = nil, depth: Int = 0) -> AXUIElement? {
    guard depth < 30 else { return nil }
    let actualRole: String? = read(root, "AXRole")
    if (role == nil || role == actualRole),
       ["AXIdentifier", "AXTitle", "AXDescription", "AXValue"].contains(where: { read(root, $0) as String? == name }) {
        return root
    }
    let children: [AXUIElement] = read(root, "AXChildren") ?? []
    for child in children {
        if let match = find(name, under: child, role: role, depth: depth + 1) { return match }
    }
    return nil
}

func waitFor<T>(_ label: String, _ match: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(8)
    repeat {
        if let result = match() { return result }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    throw ProbeError(description: "Could not find \(label)")
}

func press(_ control: AXUIElement, _ label: String) throws {
    let status = AXUIElementPerformAction(control, kAXPressAction as CFString)
    guard status == .success else { throw ProbeError(description: "Could not press \(label) (\(status.rawValue))") }
}

guard AXIsProcessTrusted() else { exit(77) }
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, let pid = pid_t(arguments[0]), NSRunningApplication(processIdentifier: pid) != nil else {
    fputs("Usage: rebind_transcript.swift PID OFFSET\n", stderr)
    exit(2)
}
let root = AXUIElementCreateApplication(pid)
do {
    let window: AXUIElement = try waitFor("focused MPCut project") { read(root, "AXFocusedWindow") }
    if find("transcript.import", under: window) == nil && find("Import Transcript…", under: window) == nil {
        try press(try waitFor("Transcript toolbar button") { find("Transcript", under: window, role: "AXButton") }, "Transcript")
    }
    let options = try waitFor("Transcript Options") { find("Transcript Options", under: window) }
    try press(options, "Transcript Options")
    let rebind = try waitFor("Rebind Transcript…") {
        find("Rebind Transcript…", under: options, role: "AXMenuItem")
            ?? find("Rebind Transcript…", under: root, role: "AXMenuItem")
    }
    try press(rebind, "Rebind Transcript…")
    let field = try waitFor("track offset") {
        find("transcript.binding.offset.source", under: window, role: "AXTextField")
            ?? find("Track offset (seconds)", under: window, role: "AXTextField")
    }
    let status = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, arguments[1] as CFString)
    guard status == .success else {
        throw ProbeError(description: "Could not set the offset in the isolated MPCut application (\(status.rawValue))")
    }
    let apply = try waitFor("enabled Rebind Transcript button") {
        guard let button = find("Rebind Transcript", under: window, role: "AXButton"),
              read(button, "AXEnabled") as Bool? != false else { return nil as AXUIElement? }
        return button
    }
    try press(apply, "Rebind Transcript")
    _ = try waitFor("rebind sheet to close") {
        find("Rebind Transcript", under: window, role: "AXButton") == nil ? true : nil
    }
} catch {
    fputs("GUI transcript rebind: \(error)\n", stderr)
    exit(1)
}
