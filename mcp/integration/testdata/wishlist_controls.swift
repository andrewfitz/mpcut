// Exercise native queue, cut movement, and join review controls in the packaged application.
import ApplicationServices
import AppKit
import Foundation

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 40 else { return [element] }
    let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}

func labels(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        .compactMap { attribute(element, $0) as? String }
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
guard AXIsProcessTrusted() else { exit(77) }
let arguments = CommandLine.arguments[2].components(separatedBy: "\n")
let app = AXUIElementCreateApplication(pid)
_ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])

func waitFor(_ description: String, diagnostic: () -> String = { "" }, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if condition() { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    FileHandle.standardError.write(Data("Could not inspect \(description)\n\(diagnostic())\n".utf8))
    exit(1)
}

func windows() -> [AXUIElement] {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap { descendants($0) }
}

func press(_ buttonName: String) -> Bool {
    guard let button = windows().first(where: {
        attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
        attribute($0, kAXSubroleAttribute) as? String != kAXCloseButtonSubrole &&
        labels($0).contains(buttonName)
    }) else { return false }
    return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
}

func menuItem(_ menuName: String, _ itemName: String) -> AXUIElement? {
    guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
          let menu = descendants(bar as! AXUIElement).first(where: {
              attribute($0, kAXRoleAttribute) as? String == kAXMenuBarItemRole && labels($0).contains(menuName)
          }),
          let item = descendants(menu).first(where: { labels($0).contains(itemName) })
    else { return nil }
    return item
}

func pressMenu(_ menuName: String, _ itemName: String) -> Bool {
    guard let item = menuItem(menuName, itemName), attribute(item, kAXEnabledAttribute) as? Bool == true else { return false }
    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
}

switch arguments[0] {
case "queue":
    waitFor("open queue", diagnostic: {
        windows().flatMap(labels).filter { $0.localizedCaseInsensitiveContains("queue") }.joined(separator: "\n")
    }) {
        press("Queue (1)") || pressMenu("File", "Export Queue…")
    }
    waitFor("open captured contents") { press("Inspect queued range 1") }
    waitFor("captured source paths and trims in order") {
        let text = windows().flatMap(labels)
        guard let heading = text.firstIndex(of: "Captured contents") else { return false }
        var nextIndex = heading + 1
        for label in arguments.dropFirst() {
            guard let match = text[nextIndex...].firstIndex(of: label) else { return false }
            nextIndex = match + 1
        }
        return true
    }
    waitFor("close queue") { press("Close") }
case "tier":
    waitFor("Delete Clip menu item") { pressMenu("Sequence", "Delete Clip") }
    waitFor("nearest keyframe prompt") {
        windows().flatMap(labels).contains("Keep the cut here?")
    }
    waitFor("signed movement in nearest keyframe prompt", diagnostic: {
        windows().flatMap(labels).filter { $0.contains("Smart Trim") || $0.contains("280 ms later") }.joined(separator: "\n")
    }) {
        windows().flatMap(labels).contains(where: { $0.contains("00:00.720 → 00:01.000 (280 ms later, 7 frames, removes material)") })
    }
    waitFor("choose nearest keyframe") { press("Cut at Nearest Keyframe") }
case "join":
    waitFor("Preview Selected Join menu item", diagnostic: {
        let enabled = menuItem("Sequence", "Preview Selected Join").flatMap { attribute($0, kAXEnabledAttribute) as? Bool }
        let focused = (attribute(app, kAXFocusedWindowAttribute).flatMap { resource -> AXUIElement? in
            guard CFGetTypeID(resource) == AXUIElementGetTypeID() else { return nil }
            return (resource as! AXUIElement)
        }).map(labels) ?? []
        return "Menu enabled: \(String(describing: enabled)), focused window: \(focused)"
    }) { pressMenu("Sequence", "Preview Selected Join") }
    waitFor("join review sheet") { windows().flatMap(labels).contains("Preview Join") }
    waitFor("replay the join") { press("Replay") }
    waitFor("close the join review") { press("Done") }
    waitFor("join review dismissal") { !windows().flatMap(labels).contains("Preview Join") }
default:
    exit(2)
}
