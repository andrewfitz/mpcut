import AppKit
import MPCutCore
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
        // Storage measures temporary stores here, and the cutcache configuration it reads is a temporary one.
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mpcut-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let locations = StorageLocations(generatedStills: root.appendingPathComponent("Stills"),
                                         transcriptRecognition: root.appendingPathComponent("Claims"),
                                         transcriptJobs: [root.appendingPathComponent("Drafts/.transcript-jobs")],
                                         untitledDrafts: root.appendingPathComponent("Drafts"),
                                         agentReceipts: root.appendingPathComponent("Receipts"))
        let home = root.appendingPathComponent("Sidecars", isDirectory: true)
        let disk = root.appendingPathComponent("Shared", isDirectory: true)
        try files.createDirectory(at: disk, withIntermediateDirectories: true)
        try SidecarLocations.$storageDirectory.withValue(home) {
            try SidecarLocations.chooseDisk(disk, selecting: true)
            XCTAssertTrue(SidecarLocations.home.path.hasPrefix(root.path))
        }
        // The page reads the location again from a task, which uses the test process's own temporary home.
        XCTAssertTrue(SidecarLocations.home.path.hasPrefix(files.temporaryDirectory.path), SidecarLocations.home.path)

        preferences.sharedCacheLimitBytes = 2_500_000_000
        preferences.draftRetentionDays = 7
        for page in SettingsPage.allCases {
            preferences.settingsPage = page
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                              storageLocations: locations))
            window.contentView = host
            window.orderBack(nil)
            SidecarLocations.$storageDirectory.withValue(home) { host.layoutSubtreeIfNeeded() }
            XCTAssertGreaterThanOrEqual(host.fittingSize.width, 640, page.rawValue)
            let rows = SettingsRow.all.filter { $0.page == page }
            XCTAssertFalse(rows.isEmpty, page.rawValue)
            if page == .storage {
                // Its two limits render from the preferences. The usage list's rows are SwiftUI text, which this host
                // cannot read; StorageUsageModel's measurement of injected stores is tested in SettingsShellTests.
                let fields = descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable).map(\.stringValue)
                XCTAssertTrue(fields.contains("2.5") && fields.contains("7"), fields.description)
            }
            window.close()
        }
        XCTAssertEqual(preferences.settingsPage, .automation)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

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
        XCTAssertFalse(SettingsRestoreSummary.isRestorable(.automation), "So Automation shows no Restore Defaults button")
        for page in SettingsPage.allCases where page != .automation {
            XCTAssertTrue(SettingsRestoreSummary.isRestorable(page), page.rawValue)
        }
    }
}
