import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

/// Search and the sidebar never write the page from inside a view or table update, Esc and the clear button clear the
/// search, and the sidebar rows share one height.
@MainActor
final class SettingsFix3SearchTests: XCTestCase {
    private typealias S = SettingsFix3Support

    private func host(_ preferences: EditorPreferences) throws -> (NSWindow, NSView) {
        let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                     storageLocations: try S.temporaryLocations()))
        window.makeKeyAndOrderFront(nil)
        S.spin(0.3)
        return (window, host)
    }

    private func searchField(_ host: NSView) throws -> NSSearchField {
        try XCTUnwrap(S.descendants(host).compactMap { $0 as? NSSearchField }.first)
    }

    private func tables(_ host: NSView) -> [NSTableView] { S.descendants(host).compactMap { $0 as? NSTableView } }

    /// Types into the search field the way the field editor does, then lets SwiftUI update.
    private func search(_ text: String, in field: NSSearchField, window: NSWindow) throws {
        try S.type(text, into: field, in: window)
        S.spin(0.3)
    }

    func testChoosingResultsWhileTheQueryChangesNeverWritesThePageDuringAnUpdate() throws {
        let preferences = EditorPreferences()
        let (window, host) = try host(preferences)
        defer { window.close() }
        let field = try searchField(host)
        XCTAssertEqual(field.accessibilityIdentifier(), "settings.search")
        XCTAssertEqual(tables(host).count, 1, "The sidebar list shows while the search is empty")

        var pages: [SettingsPage] = []
        let observer = preferences.observeChanges { if $0 == .settingsPage { pages.append(preferences.settingsPage) } }
        defer { observer.cancel() }

        for (query, page) in [("cache", SettingsPage.storage), ("undo", .general), ("hdr", .playback), ("cache", .storage)] {
            try search(query, in: field, window: window)
            XCTAssertTrue(tables(host).isEmpty, "Results for \(query) are buttons, not a second table")
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            let before = preferences.settingsPage
            // Return, as the key reaches the field: through the field editor's command.
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(preferences.settingsPage, before, "Choosing a result changes the page on the next turn, not during the call")
            S.spin(0.3)
            XCTAssertEqual(preferences.settingsPage, page, query)
        }
        XCTAssertEqual(pages, [.storage, .general, .playback, .storage])
        XCTAssertEqual(field.stringValue, "cache", "The query stays after choosing")
    }

    func testEscAndTheClearButtonClearTheSearch() throws {
        let preferences = EditorPreferences()
        let (window, host) = try host(preferences)
        defer { window.close() }
        let field = try searchField(host)
        XCTAssertNotNil((field.cell as? NSSearchFieldCell)?.cancelButtonCell, "The field has a clear button")
        try search("undo", in: field, window: window)
        XCTAssertTrue(tables(host).isEmpty)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        S.spin(0.3)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(tables(host).count, 1, "Esc brings the sidebar back")

        // The clear button empties the field and sends the field's action.
        try search("hdr", in: field, window: window)
        XCTAssertTrue(tables(host).isEmpty)
        field.stringValue = ""
        field.sendAction(field.action, to: field.target)
        S.spin(0.3)
        XCTAssertEqual(tables(host).count, 1)
        XCTAssertEqual(preferences.settingsPage, .general, "Clearing the search changes no page")
    }

    func testTheSidebarFollowsThePageAndItsRowsShareOneHeight() throws {
        let preferences = EditorPreferences()
        let (window, host) = try host(preferences)
        defer { window.close() }
        let table = try XCTUnwrap(tables(host).first)
        XCTAssertEqual(table.numberOfRows, SettingsPage.allCases.count)
        let heights = Set((0..<table.numberOfRows).map { table.rect(ofRow: $0).height })
        XCTAssertEqual(heights.count, 1, "Every sidebar row, Export included, has the same height: \(heights)")
        XCTAssertEqual(table.selectedRow, 0)

        // A click selects a row: the page follows on the next turn of the run loop.
        let export = try XCTUnwrap(SettingsPage.allCases.firstIndex(of: .export))
        table.selectRowIndexes([export], byExtendingSelection: false)
        XCTAssertEqual(preferences.settingsPage, .general, "The table's callback writes no page")
        S.spin(0.3)
        XCTAssertEqual(preferences.settingsPage, .export)
        XCTAssertEqual(table.selectedRowIndexes, [export])

        // A deep link moves the sidebar.
        SettingsWindow.open(.storage, preferences: preferences, using: nil as OpenSettingsAction?)
        S.spin(0.3)
        let storage = try XCTUnwrap(SettingsPage.allCases.firstIndex(of: .storage))
        XCTAssertEqual(table.selectedRowIndexes, [storage], "Exactly one row is selected")
    }
}
