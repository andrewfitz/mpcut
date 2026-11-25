import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSearchFindsRowsByTheirWordsAndKeywords() {
        XCTAssertEqual(Set(SettingsRow.search("HDR")), [.viewerSDR, .monitorSDR])
        let cache = SettingsRow.search("cache")
        XCTAssertFalse(cache.isEmpty)
        XCTAssertEqual(Set(cache.map(\.page)), [.storage])
        XCTAssertTrue(SettingsRow.search("undo").contains(.historyLimit))
        XCTAssertEqual(SettingsRow.search("export tier"), [.tierWarning])
        XCTAssertEqual(SettingsRow.tierWarning.page, .general)
        XCTAssertTrue(SettingsRow.search("  ").isEmpty)
        XCTAssertEqual(Set(SettingsRow.all.map(\.id)).count, SettingsRow.all.count, "Row identifiers are unique")
        XCTAssertEqual(Set(SettingsRow.all.map(\.page)), Set(SettingsPage.allCases))
    }

    func testDeepLinkStoresThePageAndReopensIt() throws {
        let name = "mpcut.settings-page.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = EditorPreferences(defaults: defaults)
        XCTAssertEqual(preferences.settingsPage, .general)
        SettingsWindow.open(.automation, preferences: preferences)
        XCTAssertEqual(preferences.settingsPage, .automation)
        XCTAssertEqual(defaults.string(forKey: "settings_selected_page"), "automation")
        XCTAssertEqual(EditorPreferences(defaults: defaults).settingsPage, .automation)
    }

    func testNumericFieldCommitsOnlyWhenEditingFinishes() async throws {
        _ = NSApplication.shared
        let preferences = EditorPreferences()
        let field = SettingsNumericField(.stillDuration, value: Binding(get: { preferences.stillDuration },
                                                                      set: { preferences.stillDuration = $0 }),
                                         in: EditorPreferences.stillDurationRange, step: 0.5, unit: "s")
        let host = NSHostingView(rootView: field.frame(width: 320))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        let entry = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertEqual(entry.stringValue, "2")

        func type(_ text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(entry))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        try type("5.25")
        await Task.yield()
        XCTAssertEqual(preferences.stillDuration, 2, "Typing alone never commits")
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertNewline(nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while preferences.stillDuration != 5.25, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(preferences.stillDuration, 5.25)
        // Let SwiftUI deliver the committed value to the field before typing again.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(entry.stringValue, "5.25")

        try type("900")
        await Task.yield()
        XCTAssertEqual(preferences.stillDuration, 5.25)
        window.close()
        XCTAssertEqual(preferences.stillDuration, 600, "Closing the window commits the value, clamped to its range")
    }

    func testShowingAMorePreciseValueNeverRoundsIt() throws {
        _ = NSApplication.shared
        let preferences = EditorPreferences()
        preferences.padding = 0.125
        var changes: [EditorPreferences.Change] = []
        let observer = preferences.observeChanges { changes.append($0) }
        defer { observer.cancel() }
        let field = SettingsNumericField(.padding, value: Binding(get: { preferences.padding }, set: { preferences.padding = $0 }),
                                         in: 0...Double.greatestFiniteMagnitude, step: 0.05, unit: "s")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: field.frame(width: 320))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let entry = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(entry))
        window.makeFirstResponder(nil)
        window.close()
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(preferences.padding, 0.125)
        XCTAssertTrue(changes.isEmpty)
    }

    func testEveryPageOpensWithNoProjectAndNamesItsControls() throws {
        _ = NSApplication.shared
        let preferences = EditorPreferences()
        // Storage reads the shared cutcache configuration, which tests must not touch.
        for page in SettingsPage.allCases where page != .storage {
            preferences.settingsPage = page
            let host = NSHostingView(rootView: SettingsWindow(preferences: preferences) { SidecarClearContext() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(host.fittingSize.width, 640, page.rawValue)
            let rows = SettingsRow.all.filter { $0.page == page }
            XCTAssertFalse(rows.isEmpty, page.rawValue)
            window.close()
        }
        XCTAssertEqual(preferences.settingsPage, .automation)
    }

    func testRestoreDefaultsIsAvailableOnlyWhenThePageDiffers() {
        let preferences = EditorPreferences()
        XCTAssertTrue(preferences.hasFactoryValues(on: .export))
        preferences.reencodeCodec = .hevc
        XCTAssertFalse(preferences.hasFactoryValues(on: .export))
        XCTAssertTrue(preferences.hasFactoryValues(on: .playback))
        preferences.restoreDefaults(on: .export)
        XCTAssertEqual(preferences.reencodeCodec, .h264)
        preferences.localMCPEnabled = true
        XCTAssertTrue(preferences.hasFactoryValues(on: .automation), "Automation has nothing Restore Defaults changes")
        XCTAssertFalse(SettingsPage.automation.restoreMessage.isEmpty)
    }
}
