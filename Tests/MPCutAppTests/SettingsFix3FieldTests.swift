import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

/// A click elsewhere commits a typed number without eating the click; limited, rounded and adjusted entries say so; the
/// range is stated; and VoiceOver reads one label per control.
@MainActor
final class SettingsFix3FieldTests: XCTestCase {
    private typealias S = SettingsFix3Support

    private struct Form: View {
        @ObservedObject var preferences: EditorPreferences

        var body: some View {
            VStack {
                SettingsNumericField(.minimumPause, value: $preferences.minimumPause,
                                     in: 0.02...Double.greatestFiniteMagnitude, step: 0.1, unit: "s")
                Toggle(SettingsRow.silenceAutoScan.title, isOn: $preferences.autoScanSilence)
                Spacer()
            }
            .padding()
        }
    }

    private func mouseDown(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                         pressure: 1))
    }

    func testAClickOutsideTheFieldCommitsAndStillReachesTheControl() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(Form(preferences: preferences), size: NSSize(width: 420, height: 200))
        defer { window.close() }
        let entry = try XCTUnwrap(S.editableFields(host).first)
        XCTAssertEqual(entry.stringValue, "1.5")

        try S.type("2.25", into: entry, in: window)
        S.spin(0.05)
        XCTAssertEqual(preferences.minimumPause, 1.5, "Typing alone never commits")

        // A click inside the field being edited keeps editing.
        let inside = entry.convert(NSPoint(x: entry.bounds.midX, y: entry.bounds.midY), to: nil)
        let insideClick = try mouseDown(at: inside, in: window)
        XCTAssertTrue(SettingsWindowHooks.handle(insideClick, in: window) === insideClick)
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertEqual(preferences.minimumPause, 1.5)

        // A click on blank space ends editing and commits; the event is returned unchanged, so the click still acts.
        let blank = try mouseDown(at: NSPoint(x: 10, y: 10), in: window)
        XCTAssertTrue(SettingsWindowHooks.handle(blank, in: window) === blank, "The click is not consumed")
        XCTAssertEqual(preferences.minimumPause, 2.25)
        XCTAssertFalse(window.firstResponder is NSTextView, "The field no longer edits")
        S.spin(0.1)
        XCTAssertEqual(entry.stringValue, "2.25")

        // With no field editing, a click does nothing.
        XCTAssertFalse(SettingsWindowHooks.finishEditing(in: window, clickedView: host))
    }

    func testAClickAwayFromALimitedOrRoundedEntryStoresWhatTheFieldThenShows() throws {
        let preferences = EditorPreferences()
        struct Fields: View {
            @ObservedObject var preferences: EditorPreferences
            var body: some View {
                VStack {
                    SettingsNumericField(.historyLimit, value: $preferences.historyLimit, in: EditorPreferences.historyStepRange, step: 1)
                    SettingsNumericField(.minimumPause, value: $preferences.minimumPause,
                                         in: 0.02...Double.greatestFiniteMagnitude, step: 0.1, unit: "s")
                    Spacer()
                }
                .padding()
            }
        }
        let (window, host) = S.window(Fields(preferences: preferences), size: NSSize(width: 420, height: 220))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let fields = S.editableFields(host)
        guard fields.count == 2 else { return XCTFail("Two fields, found \(fields.count)") }
        let top = EditorPreferences.historyStepRange.upperBound

        for (index, text) in [(0, "\(top + 4_500)"), (1, "1.234"), (0, "-5")] {
            try S.type(text, into: fields[index], in: window)
            let blank = try mouseDown(at: NSPoint(x: 5, y: 5), in: window)
            XCTAssertTrue(SettingsWindowHooks.handle(blank, in: window) === blank)
            S.spin(0.3)
            XCTAssertFalse(window.firstResponder is NSTextView, text)
            let shown = fields[index].stringValue
            switch index {
            case 0: XCTAssertEqual(shown, "\(preferences.historyLimit)", text)
            default: XCTAssertEqual(shown, preferences.minimumPause.settingsText(digits: 2), text)
            }
        }
        XCTAssertEqual(preferences.minimumPause, 1.23)
        XCTAssertEqual(preferences.historyLimit, 0, "A negative entry is limited to 0")
        XCTAssertEqual(fields[0].stringValue, "0")
    }

    func testAClickOnASwitchCommitsTheTypedNumber() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(Form(preferences: preferences), size: NSSize(width: 420, height: 200))
        defer { window.close() }
        let entry = try XCTUnwrap(S.editableFields(host).first)
        try S.type("3", into: entry, in: window)
        // The switch's own view is what a click on it hits.
        let toggle = S.descendants(host).first { $0 is NSButton || String(describing: type(of: $0)).contains("Switch") }
        XCTAssertTrue(SettingsWindowHooks.finishEditing(in: window, clickedView: toggle ?? host))
        XCTAssertEqual(preferences.minimumPause, 3)
        XCTAssertFalse(preferences.autoScanSilence, "Ending editing does not act on the switch itself")
    }

    func testLimitedRoundedAndUnreadableEntriesSaySo() {
        var stored = 0
        let binding = Binding(get: { stored }, set: { stored = $0 })
        let history = SettingsNumericField(.historyLimit, value: binding, in: EditorPreferences.historyStepRange, step: 1)
        let top = EditorPreferences.historyStepRange.upperBound
        XCTAssertEqual(history.entry("5000").value, top)
        XCTAssertEqual(history.entry("5000").notice, "Limited to 0–\(top).")
        XCTAssertEqual(history.entry("-5").value, 0, "A negative entry is limited the same way")
        XCTAssertEqual(history.entry("-5").notice, "Limited to 0–\(top).")
        XCTAssertNil(history.entry("40").notice)
        XCTAssertNil(history.entry("5.5").value)
        XCTAssertEqual(history.entry("5.5").notice, "Enter a whole number, 0–\(top).")

        var width = 172.0
        let label = SettingsNumericField(.trackLabelWidth, value: Binding(get: { width }, set: { width = $0 }),
                                         in: EditorPreferences.trackLabelWidthRange, step: 1, unit: "pt", digits: 0)
        XCTAssertEqual(label.entry("50").value, 106)
        XCTAssertEqual(label.entry("50").notice, "Limited to 106–360 pt.")
        XCTAssertEqual(label.entry("200.4").value, 200)
        XCTAssertEqual(label.entry("200.4").notice, "Rounded to 200 pt.")

        var pause = 1.5
        let minimum = SettingsNumericField(.minimumPause, value: Binding(get: { pause }, set: { pause = $0 }),
                                           in: 0.02...Double.greatestFiniteMagnitude, step: 0.1, unit: "s")
        XCTAssertEqual(minimum.rangeDescription, "0.02 s or more")
        XCTAssertEqual(minimum.entry("1.234").value, 1.23)
        XCTAssertEqual(minimum.entry("1.234").notice, "Rounded to 1.23 s.")
        XCTAssertEqual(minimum.entry("0").notice, "Limited to 0.02 s or more.")
        XCTAssertNil(minimum.entry("abc").value)
        XCTAssertEqual(minimum.entry("abc").notice, "Enter a number, 0.02 s or more.")

        var gigabytes = 0.0
        // Built as the Storage page builds it.
        let cache = SettingsStoragePage.cacheLimitField(Binding(get: { gigabytes }, set: { gigabytes = $0 }))
        XCTAssertEqual(cache.entry("2.5").value, 2.5)
        XCTAssertNil(cache.entry("2.5").notice)
        XCTAssertEqual(cache.entry("1.2345").notice, "Rounded to 1.235 GB.")
        XCTAssertEqual(cache.entry("-1").notice, "Limited to 0–" + (1_000_000).formatted() + " GB.")
    }

    func testACommittedEntryStoresWhatTheFieldThenShows() async throws {
        let preferences = EditorPreferences()
        struct Fields: View {
            @ObservedObject var preferences: EditorPreferences
            var body: some View {
                VStack {
                    SettingsNumericField(.trackLabelWidth, value: $preferences.trackLabelWidth,
                                         in: EditorPreferences.trackLabelWidthRange, step: 1, unit: "pt", digits: 0)
                    SettingsNumericField(.stillTimelineWidth, value: $preferences.stillTimelineWidth,
                                         in: EditorPreferences.stillTimelinePixelRange, step: 2, unit: "px")
                    SettingsNumericField(.stillDuration, value: $preferences.stillDuration, in: EditorPreferences.stillDurationRange,
                                         step: 0.5, unit: "s")
                }
                .padding()
            }
        }
        let (window, host) = S.window(Fields(preferences: preferences), size: NSSize(width: 420, height: 260))
        defer { window.close() }
        let fields = S.editableFields(host)
        XCTAssertEqual(fields.map(\.stringValue), ["172", "1920", "2"])
        guard fields.count == 3 else { return }

        func commit(_ text: String, into field: NSTextField) throws {
            try S.type(text, into: field, in: window)
            try XCTUnwrap(window.firstResponder as? NSTextView).insertNewline(nil)
            S.spin(0.2)
        }
        try commit("50", into: fields[0])
        XCTAssertEqual(preferences.trackLabelWidth, 106)
        XCTAssertEqual(fields[0].stringValue, "106")
        try commit("1921", into: fields[1])
        XCTAssertEqual(preferences.stillTimelineWidth, 1920, "The setting keeps widths even")
        XCTAssertEqual(fields[1].stringValue, "1920")
        try commit("1.517", into: fields[2])
        XCTAssertEqual(preferences.stillDuration, 1.52)
        XCTAssertEqual(fields[2].stringValue, "1.52", "The stored value is the shown one")

    }

    func testEachNumericFieldStatesItsRangeAndWhatZeroMeans() {
        var recent = 10
        let items = SettingsNumericField(.recentItems, value: Binding(get: { recent }, set: { recent = $0 }),
                                         in: EditorPreferences.recentFilesRange, step: 1, help: "Type how many recent items File → Open Recent lists")
        XCTAssertEqual(items.tooltip, "Type how many recent items File → Open Recent lists. Range: 1–30.")
        XCTAssertEqual(items.spokenHint, "Range: 1 to 30.")

        var width = 1920
        let pixels = SettingsNumericField(.stillTimelineWidth, value: Binding(get: { width }, set: { width = $0 }),
                                          in: EditorPreferences.stillTimelinePixelRange, step: 2, unit: "px")
        let top = (8192).formatted()
        XCTAssertEqual(pixels.tooltip, "Type a value for “Width”. Range: 16–\(top) px.", "Without help of its own, the tooltip names the row")
        XCTAssertEqual(pixels.spokenHint, "Range: 16 to \(top) px.")

        var days = 0
        let drafts = SettingsNumericField(.draftRetention, value: Binding(get: { days }, set: { days = $0 }),
                                          in: EditorPreferences.draftRetentionRange, step: 1, unit: "days",
                                          zeroMeaning: "Drafts are never removed")
        XCTAssertEqual(drafts.spokenHint, "Range: 0 to 365 days. 0: drafts are never removed.")
        XCTAssertTrue(drafts.tooltip.hasSuffix("Range: 0–365 days. 0: drafts are never removed."), drafts.tooltip)
    }
}
