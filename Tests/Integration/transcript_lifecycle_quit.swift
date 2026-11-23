// Sends native Quit and confirms only this background test process's stop-work dialog.
import AppKit
import ApplicationServices

func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value as? T
}

func quitButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 20 else { return nil }
    if attribute(element, kAXRoleAttribute as CFString) as String? == kAXButtonRole,
       attribute(element, kAXTitleAttribute as CFString) as String? == "Stop and Quit" {
        return element
    }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
    return children.lazy.compactMap { quitButton(in: $0, depth: depth + 1) }.first
}

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: pid),
      application.terminate() else {
    FileHandle.standardError.write(Data("Could not send native Quit to the test process.\n".utf8))
    exit(1)
}

let root = AXUIElementCreateApplication(pid)
let deadline = ContinuousClock.now + .seconds(18)
while ContinuousClock.now < deadline, !application.isTerminated {
    let windows: [AXUIElement] = attribute(root, kAXWindowsAttribute as CFString) ?? []
    if let button = windows.lazy.compactMap({ quitButton(in: $0) }).first {
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result == .success || result == .cannotComplete { exit(0) }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.10))
}

if !application.isTerminated {
    let detail = AXIsProcessTrusted() ? "The test process did not exit." : "Allow Accessibility access for the test terminal."
    FileHandle.standardError.write(Data((detail + "\n").utf8))
    exit(1)
}
