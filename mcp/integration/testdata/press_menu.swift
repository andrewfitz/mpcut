// Press a named enabled menu item in the specific test application's process.
import ApplicationServices
import AppKit
import Foundation

func get(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success ? value : nil
}

func children(_ item: AXUIElement) -> [AXUIElement] {
    get(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
guard AXIsProcessTrusted() else { exit(77) }

_ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
let title = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
func control(_ item: AXUIElement, named name: String) -> AXUIElement? {
    let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { get(item, $0) as? String }
    if get(item, kAXRoleAttribute) as? String == kAXCheckBoxRole, label.contains(name) { return item }
    let rows = children(item)
    for (caption, toggle) in zip(rows, rows.dropFirst()) {
        if get(caption, kAXRoleAttribute) as? String == kAXStaticTextRole,
           get(caption, kAXValueAttribute) as? String == name,
           get(toggle, kAXRoleAttribute) as? String == kAXCheckBoxRole { return toggle }
    }
    return rows.lazy.compactMap { control($0, named: name) }.first
}

var nextSettingsRequest = Date.distantPast
let deadline = Date().addingTimeInterval(15)
while Date() < deadline {
    if let raw = get(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
        let bar = raw as! AXUIElement
        if title == "toggle-control" {
            let windows = get(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let toggle = windows.lazy.compactMap({ control($0, named: "Enable local MCP control") }).first {
                if AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success { exit(0) }
            } else if Date() >= nextSettingsRequest,
                      let entry = children(bar).flatMap(children).flatMap(children).first(where: {
                          (get($0, kAXTitleAttribute) as? String)?.hasPrefix("Settings") == true &&
                          get($0, kAXEnabledAttribute) as? Bool == true
                      }) {
                _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                _ = AXUIElementPerformAction(entry, kAXPressAction as CFString)
                nextSettingsRequest = Date().addingTimeInterval(1)
            }
        }
        let menu = children(bar).first { get($0, kAXTitleAttribute) as? String == "Edit" }
        if let menu, let item = children(menu).flatMap(children).first(where: {
            get($0, kAXTitleAttribute) as? String == title && get($0, kAXEnabledAttribute) as? Bool == true
        }), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            exit(0)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
let windows = (get(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap {
    get($0, kAXTitleAttribute) as? String
}
FileHandle.standardError.write(Data("Could not invoke test control: \(title); windows: \(windows)\n".utf8))
exit(1)
