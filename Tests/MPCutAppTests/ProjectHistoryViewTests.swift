import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

final class ProjectHistoryViewTests: XCTestCase {
    @MainActor
    func testFieldEditorUndoAvailabilityAndActionsFollowTheActiveWindow() throws {
        _ = NSApplication.shared
        let field = NSTextField(string: "")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = field
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(field))
        let responder = try XCTUnwrap(window.firstResponder as? NSTextView)
        responder.allowsUndo = true
        let manager = try XCTUnwrap(responder.undoManager)
        var activeWindow: NSWindow? = window
        let focus = TextFocus { activeWindow }
        XCTAssertTrue(focus.isEditing)
        XCTAssertFalse(focus.canUndo)
        XCTAssertFalse(focus.canRedo)
        focus.performUndo { XCTFail("A field without an undo action owns its keyboard shortcut") }

        responder.insertText("42", replacementRange: NSRange(location: 0, length: 0))
        responder.breakUndoCoalescing()
        focus.refresh()
        XCTAssertTrue(focus.canUndo)
        XCTAssertFalse(focus.canRedo)
        XCTAssertEqual(focus.undoTitle, manager.undoMenuItemTitle)
        focus.performUndo { XCTFail("Typing belongs to the field editor") }
        XCTAssertEqual(responder.string, "")
        XCTAssertTrue(focus.canRedo)
        XCTAssertEqual(focus.redoTitle, manager.redoMenuItemTitle)
        focus.performRedo { XCTFail("Redo belongs to the field editor") }
        XCTAssertEqual(responder.string, "42")

        activeWindow = nil
        var timelineUndo = false
        focus.performUndo { timelineUndo = true }
        XCTAssertTrue(timelineUndo)
        XCTAssertFalse(focus.isEditing)
    }

    @MainActor
    func testHistoryOpensAtCurrentStateAndReturnRestoresSelectedRow() async throws {
        _ = NSApplication.shared
        var restored: Int?
        let history = ProjectHistoryView(actions: ["Add Clip", "Split Clip", "Move Clip"], cursor: 2,
                                         disabled: false) { restored = $0 }
        let host = NSHostingView(rootView: history)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 390),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func list(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { list(in: $0) }.first
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while list(in: host)?.selectedRow != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rows = try XCTUnwrap(list(in: host))
        XCTAssertEqual(rows.numberOfRows, 4)
        XCTAssertEqual(rows.selectedRow, 2)
        rows.selectRowIndexes([1], byExtendingSelection: false)
        await Task.yield()
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                   isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        let restoreDeadline = ContinuousClock.now + .seconds(2)
        while restored == nil, ContinuousClock.now < restoreDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(restored, 1)
    }
}
