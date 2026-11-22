import ApplicationServices
import Foundation

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
}

func findTierBadge(in element: AXUIElement, depth: Int = 0) -> String? {
    let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        .compactMap { value(element, $0) as? String }
    if let badge = text.first(where: { $0.hasPrefix("Export quality tier: ") }) { return badge }
    guard depth < 40 else { return nil }
    let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return children.lazy.compactMap { findTierBadge(in: $0, depth: depth + 1) }.first
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
guard AXIsProcessTrusted() else { exit(77) }
let expected = "Export quality tier: " + CommandLine.arguments[2]
let application = AXUIElementCreateApplication(pid)
let deadline = Date().addingTimeInterval(10)
var lastBadge: String?
while Date() < deadline {
    if let focused = value(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
        lastBadge = findTierBadge(in: focused as! AXUIElement)
        if lastBadge == expected { exit(0) }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
FileHandle.standardError.write(Data("Expected \(expected), last badge: \(lastBadge ?? "unavailable")\n".utf8))
exit(1)
