import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

/// Hosting and inspection helpers shared by the SettingsFix3 tests.
@MainActor
enum SettingsFix3Support {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func spin(_ seconds: Double = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A window hosting `view`, ordered in behind other windows.
    static func window<Content: View>(_ view: Content, size: NSSize = NSSize(width: 760, height: 560),
                                      style: NSWindow.StyleMask = [.titled, .closable, .resizable]) -> (NSWindow, NSHostingView<Content>) {
        _ = WindowTestHost.application
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    static func type(_ text: String, into field: NSTextField, in window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    static func editableFields(_ view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }.filter { $0.isEditable && !($0 is NSSearchField) }
    }

    /// The hosting view's accessibility elements, read the way a client reads them. SwiftUI makes its elements after
    /// layout, and later on a busy host, so this reads again until the walk reaches a control, and fails the test, saying
    /// what it found, if it never does: a walk that reaches nothing must not pass or fail later assertions by accident.
    static func accessibilityElements(of host: NSView, timeout: TimeInterval = 10,
                                      file: StaticString = #filePath, line: UInt = #line) -> [SettingsFix4AccessibilityTests.Element] {
        let controls: Set<String> = ["AXTextField", "AXPopUpButton", "AXCheckBox", "AXButton", "AXSlider"]
        let deadline = Date().addingTimeInterval(timeout)
        var elements = SettingsFix4AccessibilityTests.elements(host)
        while !elements.contains(where: { controls.contains($0.role) }), Date() < deadline {
            host.layoutSubtreeIfNeeded()
            spin(0.1)
            elements = SettingsFix4AccessibilityTests.elements(host)
        }
        if !elements.contains(where: { controls.contains($0.role) }) {
            let window = host.window
            XCTFail("The accessibility walk reached no control in \(timeout) s: \(elements.count) elements, "
                    + "\(host.accessibilityChildren()?.count ?? -1) children of the hosting view, window visible \(window?.isVisible == true), "
                    + "on screen \(window?.occlusionState.contains(.visible) == true), app active \(NSApp.isActive), "
                    + "hidden \(NSApp.isHidden), VoiceOver \(NSWorkspace.shared.isVoiceOverEnabled)", file: file, line: line)
        }
        return elements
    }

    static func temporaryLocations() throws -> StorageLocations {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-fix3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StorageLocations(generatedStills: root.appendingPathComponent("Stills"),
                                transcriptRecognition: root.appendingPathComponent("Claims"),
                                transcriptJobs: [root.appendingPathComponent("Drafts/.transcript-jobs")],
                                untitledDrafts: root.appendingPathComponent("Drafts"),
                                agentReceipts: root.appendingPathComponent("Receipts"))
    }
}
