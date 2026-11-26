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
