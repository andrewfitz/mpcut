import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// Numbers, units and steppers sit in their own columns; a range notice moves no row and scrolls into view; units read in
/// the singular after 1; help names each control as its row does; the search follows a value set through accessibility;
/// Transcriberrr's last check outlives the page; a Clear result says "nothing removed" once; store paths wrap.
@MainActor
final class SettingsFix4FieldTests: XCTestCase {
    private typealias S = SettingsFix3Support

    // MARK: Item 4. Columns

    func testNumbersUnitsAndSteppersLineUpWithAndWithoutAUnit() throws {
        let preferences = EditorPreferences()
        struct Rows: View {
            @ObservedObject var preferences: EditorPreferences
            var body: some View {
                Form {
                    SettingsNumericField(.tilesColumns, value: $preferences.tilesScanColumns, in: EditorPreferences.tilesGridRange, step: 1)
                    SettingsNumericField(.dialogueHold, value: $preferences.dialogueMinimumHold, in: EditorPreferences.dialogueHoldRange,
                                         step: 0.25, unit: "s")
                    SettingsNumericField(.draftRetention, value: $preferences.draftRetentionDays, in: EditorPreferences.draftRetentionRange,
                                         step: 1, unit: "days")
                    SettingsNumericField(.stillTimelineFrameRate, value: $preferences.stillTimelineFrameRate,
                                         in: EditorPreferences.stillTimelineFrameRateRange, step: 1, unit: "fps", digits: 3)
                }
                .formStyle(.grouped)
            }
        }
        let (window, host) = S.window(Rows(preferences: preferences), size: NSSize(width: 640, height: 400))
        defer { window.close() }
        S.spin(0.3)
        let fields = S.editableFields(host).map { $0.convert($0.bounds, to: host) }
        let steppers = S.descendants(host).compactMap { $0 as? NSStepper }.map { $0.convert($0.bounds, to: host) }
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(steppers.count, 4)
        XCTAssertEqual(Set(fields.map { $0.maxX.rounded() }).count, 1, "The numbers end in one column: \(fields)")
        XCTAssertEqual(Set(steppers.map { $0.minX.rounded() }).count, 1, "The steppers start in one column: \(steppers)")
        for (field, stepper) in zip(fields, steppers) {
            XCTAssertGreaterThanOrEqual(stepper.minX - field.maxX, SettingsNumericField<Int>.unitWidth, "A unit column lies between them")
        }
    }

    // MARK: Item 5. Singular units

    func testUnitsReadInTheSingularAfterOne() {
        XCTAssertEqual(SettingsNumericField<Int>.unit("days", after: "1"), "day")
        XCTAssertEqual(SettingsNumericField<Int>.unit("days", after: "2"), "days")
        XCTAssertEqual(SettingsNumericField<Int>.unit("days", after: "0"), "days")
        XCTAssertEqual(SettingsNumericField<Double>.unit("s", after: "1"), "s")
        XCTAssertEqual(SettingsNumericField<Int>.unit("px", after: "1"), "px")

        var days = 1
        let drafts = SettingsNumericField(.draftRetention, value: Binding(get: { days }, set: { days = $0 }),
                                          in: EditorPreferences.draftRetentionRange, step: 1, unit: "days")
        XCTAssertEqual(drafts.unitText, "day", "The unit beside 1 reads “1 day”")
        XCTAssertEqual(drafts.stepperHelp, "Raise or lower “Remove untitled drafts after” by 1 day. Range: 0–365 days.")
        XCTAssertEqual(drafts.stepperHint, "Steps by 1 day. Range: 0 to 365 days.")
        days = 7
        let week = SettingsNumericField(.draftRetention, value: Binding(get: { days }, set: { days = $0 }),
                                        in: EditorPreferences.draftRetentionRange, step: 1, unit: "days")
        XCTAssertEqual(week.unitText, "days")
    }

    // MARK: Item 6. Wording

    func testHelpNamesEachControlAsItsRowDoes() {
        var gigabytes = 0.0
        // Built as the Storage page builds it.
        let cache = SettingsStoragePage.cacheLimitField(Binding(get: { gigabytes }, set: { gigabytes = $0 }))
        XCTAssertEqual(cache.stepperHelp, "Raise or lower “Limit the shared cache folder” by 1 GB. Range: 0–\((1_000_000).formatted()) GB.")
        XCTAssertTrue(cache.tooltip.hasPrefix("Type the most space the shared cache folder may use"), cache.tooltip)
        XCTAssertTrue(cache.tooltip.hasSuffix("0: no limit."), cache.tooltip)
        XCTAssertFalse(cache.stepperHelp.contains("Adjust"))

        // The Restore dialog names rows by their titles.
        typealias Key = EditorPreferences.Key
        XCTAssertEqual(SettingsRestoreSummary.entries[Key.exportReencodeDefaultQuality.rawValue]?.name, SettingsRow.reencodeQuality.title)
        for page in SettingsPage.allCases {
            for factory in EditorPreferences.factories where factory.page == page {
                let name = SettingsRestoreSummary.entries[factory.key]?.name ?? ""
                let titles = SettingsRow.all.filter { $0.page == page }.map(\.title) + ["Chosen folder"]
                XCTAssertTrue(titles.contains { name.hasPrefix($0) } || name.hasPrefix("Warnings"),
                              "\(factory.key): “\(name)” starts with a row title on \(page.title)")
            }
        }
    }

    // MARK: Item 7. Range notices

    private struct Column: View {
        @ObservedObject var preferences: EditorPreferences
        var body: some View {
            SettingsForm(page: .editing, preferences: preferences) {
                Section("Top") {
                    SettingsNumericField(.trackLabelWidth, value: $preferences.trackLabelWidth,
                                         in: EditorPreferences.trackLabelWidthRange, step: 1, unit: "pt", digits: 0)
                    SettingsNumericField(.stillDuration, value: $preferences.stillDuration, in: EditorPreferences.stillDurationRange,
                                         step: 0.5, unit: "s")
                    SettingsNumericField(.gapDuration, value: $preferences.gapDuration, in: EditorPreferences.stillDurationRange,
                                         step: 0.5, unit: "s")
                }
                Section("Stills") {
                    SettingsNumericField(.stillTimelineWidth, value: $preferences.stillTimelineWidth,
                                         in: EditorPreferences.stillTimelinePixelRange, step: 2, unit: "px")
                }
                Section("More") {
                    ForEach(0..<6, id: \.self) { index in
                        Toggle("Row \(index)", isOn: .constant(false))
                    }
                }
            }
        }
    }

    private func commit(_ text: String, into field: NSTextField, in window: NSWindow) throws {
        try S.type(text, into: field, in: window)
        try XCTUnwrap(window.firstResponder as? NSTextView).insertNewline(nil)
        S.spin(0.4)
    }

    private func reveals(_ host: NSView) -> [SettingsRevealInScroll.RevealView] {
        S.descendants(host).compactMap { $0 as? SettingsRevealInScroll.RevealView }
    }

    private func notices(_ host: NSView) -> [NSRect] {
        S.descendants(host).compactMap { $0 as? SettingsNoticeMarker.MarkerView }.map { $0.convert($0.bounds, to: host) }
    }

    func testANoticeMovesNoRow() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(Column(preferences: preferences), size: NSSize(width: 640, height: 500))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.3)
        let fields = S.editableFields(host)
        guard fields.count == 4 else { return XCTFail("Four fields, found \(fields.count)") }
        let before = fields.map { $0.convert($0.bounds, to: host) }
        try commit("50", into: fields[0], in: window)
        XCTAssertEqual(preferences.trackLabelWidth, 106)
        XCTAssertEqual(reveals(host).count, 1, "The notice shows")
        let after = fields.map { $0.convert($0.bounds, to: host) }
        XCTAssertEqual(after, before, "No field moves while the notice shows")
        // The page draws the notice, so the grouped section around the last row of a section cannot clip it. With room
        // between the title and the field it sits on the field's line, just left of the field, over nothing.
        let notice = try XCTUnwrap(notices(host).first, "The page draws the notice")
        XCTAssertEqual(notice.midY, after[0].midY, accuracy: 1, "\(notice) is on the line of the field \(after[0])")
        XCTAssertLessThanOrEqual(notice.maxX, after[0].minX - SettingsNoticePlacement.gap + 0.5, "Left of the field")
        let title = (SettingsRow.trackLabelWidth.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        XCTAssertGreaterThan(notice.minX, title.width + 20, "Clear of the title “\(SettingsRow.trackLabelWidth.title)”")

        // Scrolling the page carries the notice with its field.
        let scroll = try XCTUnwrap(S.descendants(host).compactMap { $0 as? NSScrollView }.first { $0.documentView != nil })
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 30))
        scroll.reflectScrolledClipView(clip)
        S.spin(0.3)
        let field = fields[0].convert(fields[0].bounds, to: host)
        let moved = try XCTUnwrap(notices(host).first)
        XCTAssertEqual(moved.minY - field.maxY, notice.minY - after[0].maxY, accuracy: 1, "The notice follows its field")
    }

    func testANoticeWithNoRoomBesideItsFieldSitsBelowIt() throws {
        let preferences = EditorPreferences()
        // Too narrow for “Limited to 106–360 pt.” between “Multicam track label width” and its field.
        let (window, host) = S.window(Column(preferences: preferences), size: NSSize(width: 400, height: 500))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.3)
        let field = try XCTUnwrap(S.editableFields(host).first)
        try commit("50", into: field, in: window)
        let frame = field.convert(field.bounds, to: host)
        let notice = try XCTUnwrap(notices(host).first, "The page draws the notice")
        XCTAssertGreaterThanOrEqual(notice.minY, frame.maxY, "\(notice) is below the field \(frame)")
        XCTAssertLessThan(notice.minY - frame.maxY, 12)
        XCTAssertGreaterThan(notice.maxX, frame.maxX, "Its trailing edge is the stepper's, right of the number")
    }

    func testANoticeNearTheBottomScrollsJustEnoughToShow() throws {
        let preferences = EditorPreferences()
        // Short enough that the last field sits at the bottom of the visible area, as stills Width did.
        let (window, host) = S.window(Column(preferences: preferences), size: NSSize(width: 640, height: 220))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.3)
        let scroll = try XCTUnwrap(S.descendants(host).compactMap { $0 as? NSScrollView }.first { $0.documentView != nil })
        let width = try XCTUnwrap(S.editableFields(host).last)
        // Bring the Width field to the very bottom edge of the visible area.
        width.scrollToVisible(width.bounds)
        S.spin(0.2)
        let start = scroll.contentView.bounds.origin.y
        try commit("1921", into: width, in: window)
        XCTAssertEqual(preferences.stillTimelineWidth, 1920)
        S.spin(0.3)
        let reveal = try XCTUnwrap(reveals(host).first, "The notice “Saved as 1920 px.” shows")
        XCTAssertEqual(reveal.scrollNeeded, 0, "The notice lies inside the visible area")
        let notice = try XCTUnwrap(notices(host).first)
        let document = try XCTUnwrap(scroll.documentView)
        let visible = document.convert(scroll.documentVisibleRect, to: host)
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(notice), "The whole notice \(notice) shows inside \(visible)")
        let moved = abs(scroll.contentView.bounds.origin.y - start)
        XCTAssertGreaterThan(moved, 0, "The notice below the bottom field was out of view, so the page scrolled")
        XCTAssertLessThan(moved, 80, "The page moves only as far as the notice needs, \(moved) pt")
    }

    // MARK: Item 3. Transcriberrr

    func testAFinishedCheckIsKeptUntilTheHelperLocationChanges() async throws {
        let probes = ProbeCount()
        let data = try JSONSerialization.data(withJSONObject: ["version": "0.4.0", "engines": [
            ["name": "qwen3", "included": true, "default_model": "m", "minimum_macos": "14.0", "diarization": true]]])
        let status = TranscriberrrStatus(locate: { URL(fileURLWithPath: $0.isEmpty ? "/x/transcriberrr" : $0) },
                                         probe: { _ in data })
        status.follow(helperPath: "", automatically: false)
        XCTAssertEqual(status.state, .unchecked, "Without its own checks the page waits for Check")
        status.check(helperPath: "")
        await status.waitForCheck()
        XCTAssertEqual(SettingsTranscriptsPage.statusText(status.state), "Version 0.4.0. Engines: Qwen3.")
        status.follow(helperPath: "", automatically: false)
        status.follow(helperPath: "", automatically: true)
        XCTAssertEqual(SettingsTranscriptsPage.statusText(status.state), "Version 0.4.0. Engines: Qwen3.", "Coming back keeps the result")
        status.follow(helperPath: "/other/transcriberrr", automatically: false)
        XCTAssertEqual(status.state, .unchecked, "A result for another helper is dropped")

        let counting = TranscriberrrStatus(locate: { URL(fileURLWithPath: $0) }, probe: { _ in probes.add(); return data })
        counting.follow(helperPath: "/a/transcriberrr", automatically: true)
        await counting.waitForCheck()
        counting.follow(helperPath: "/a/transcriberrr", automatically: true)
        await counting.waitForCheck()
        XCTAssertEqual(probes.value, 1, "A real app checks again only when the location changes")
        counting.follow(helperPath: "/b/transcriberrr", automatically: true)
        await counting.waitForCheck()
        XCTAssertEqual(probes.value, 2)
    }

    func testTheWindowKeepsTheLastCheckAcrossPageChanges() throws {
        let preferences = EditorPreferences()
        preferences.settingsPage = .transcripts
        preferences.transcriptHelperPath = "/nonexistent-\(UUID().uuidString)/transcriberrr"
        let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                     storageLocations: try S.temporaryLocations()), size: NSSize(width: 900, height: 1600))
        defer { window.close() }
        S.spin(0.4)
        func statusText() -> String {
            let element = S.accessibilityElements(of: host).first { $0.identifier == "settings.transcripts.transcriberrr.status" }
            return [element?.label, element?.value].compactMap { $0 }.filter { !$0.isEmpty }.first ?? ""
        }
        XCTAssertEqual(statusText(), "Not checked", "The test host never checks on its own")
        let check = try XCTUnwrap(S.accessibilityElements(of: host).first { $0.identifier == SettingsRow.transcriberrrStatus.id })
        check.press()
        S.spin(0.5)
        // The helper is missing, so Check finishes at once with that answer. Leave the page and come back: the page is
        // rebuilt, and the answer is still there.
        preferences.settingsPage = .general
        S.spin(0.3)
        preferences.settingsPage = .transcripts
        S.spin(0.4)
        let result = statusText()
        XCTAssertNotEqual(result, "Not checked", "Coming back to the page shows the last result")
        XCTAssertTrue(result.contains("Transcriberrr"), result)
    }

    // MARK: Item 10a. Search through accessibility

    func testSettingTheSearchFieldThroughAccessibilityRunsTheSearch() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                     storageLocations: try S.temporaryLocations()))
        defer { window.close() }
        S.spin(0.3)
        let field = try XCTUnwrap(S.descendants(host).compactMap { $0 as? NSSearchField }.first)
        func tables() -> Int { S.descendants(host).compactMap { $0 as? NSTableView }.count }
        XCTAssertEqual(tables(), 1)
        // As an accessibility client sets AXValue: on the field's element, which is its cell.
        field.cell?.setAccessibilityValue("cache")
        S.spin(0.3)
        XCTAssertEqual(field.stringValue, "cache")
        XCTAssertEqual(tables(), 0, "The results replace the sidebar")
        XCTAssertNotNil(S.accessibilityElements(of: host).first { $0.identifier == "settings.result." + SettingsRow.cacheLimit.id })
        field.setAccessibilityValue("")
        S.spin(0.3)
        XCTAssertEqual(tables(), 1, "Clearing the value brings the sidebar back")
        XCTAssertEqual(preferences.settingsPage, .general, "Searching changes no page")
    }

    func testTypingInTheSearchFieldNeverReportsInALoop() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                     storageLocations: try S.temporaryLocations()))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.3)
        let field = try XCTUnwrap(S.descendants(host).compactMap { $0 as? ValueReportingSearchField }.first)
        var reports: [String] = []
        let report = field.valueChanged
        field.valueChanged = { reports.append($0); report?($0) }
        try S.type("cache", into: field, in: window)
        for _ in 0..<5 {
            // Reading the value while the field edits writes the typed text back into its cell.
            _ = field.stringValue
            S.spin(0.1)
        }
        // The field writing the typed text back into its cell reports at most that same text, a few times, never in a loop.
        XCTAssertTrue(reports.allSatisfy { $0 == "cache" }, "\(reports)")
        XCTAssertLessThan(reports.count, 6, "\(reports.count) reports")
        XCTAssertEqual(S.descendants(host).compactMap { $0 as? NSTableView }.count, 0, "The search ran")
    }

    /// Keys arriving faster than the view updates: a report of an earlier value must never replace the text typed since.
    func testFastTypingInTheSearchFieldKeepsEveryLetterAndSettles() throws {
        for pause in [0.0, 0.002, 0.02] {
            let preferences = EditorPreferences()
            let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                         storageLocations: try S.temporaryLocations()))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            S.spin(0.3)
            let field = try XCTUnwrap(S.descendants(host).compactMap { $0 as? ValueReportingSearchField }.first)
            var reports: [String] = []
            let report = field.valueChanged
            field.valueChanged = { reports.append($0); report?($0) }
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            for letter in "characters" {
                editor.insertText(String(letter), replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
                if pause > 0 { S.spin(pause) }
            }
            S.spin(0.5)
            XCTAssertEqual(editor.string, "characters", "pause \(pause)")
            XCTAssertEqual(field.query, "characters", "pause \(pause)")
            XCTAssertTrue(reports.allSatisfy { "characters".hasPrefix($0) }, "pause \(pause): \(reports)")
            let settled = reports.count
            S.spin(0.5)
            XCTAssertEqual(reports.count, settled, "pause \(pause): reports continue after typing stopped")
            XCTAssertLessThan(settled, 12, "pause \(pause): \(settled) reports for ten letters")
            XCTAssertNotNil(S.accessibilityElements(of: host).first { $0.identifier == "settings.result." + SettingsRow.captionCharacters.id },
                            "pause \(pause): the search ran")
        }
    }

    /// A value the cell held for a moment is not reported once the field has moved on: the report gives the text the
    /// field shows when it is delivered.
    func testAReportNeverDeliversAValueTheFieldNoLongerShows() {
        let field = ValueReportingSearchField()
        var reports: [String] = []
        field.valueChanged = { reports.append($0) }
        field.cell?.objectValue = "c"
        field.cell?.objectValue = "ca"
        field.query = "ca"
        S.spin(0.1)
        XCTAssertEqual(reports, [], "The field shows the query; there is nothing to report")
        field.cell?.objectValue = "c"
        field.cell?.objectValue = "cache"
        S.spin(0.1)
        XCTAssertEqual(reports, ["cache"], "One report, of the value the field shows")
    }

    /// The field and the query can disagree for a moment while keys arrive quickly. They must settle on one value: an
    /// out-of-date value reaching the query may not start the two replacing each other without end.
    func testAnOutOfDateValueCannotStartAnEndlessExchange() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                     storageLocations: try S.temporaryLocations()))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.3)
        let field = try XCTUnwrap(S.descendants(host).compactMap { $0 as? ValueReportingSearchField }.first)
        var reports: [String] = []
        let report = field.valueChanged
        field.valueChanged = { reports.append($0); report?($0) }
        try S.type("cach", into: field, in: window)
        S.spin(0.3)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        // An earlier value reaches the query while the field shows a later one.
        field.valueChanged?("cac")
        S.spin(0.5)
        var settled = reports.count
        S.spin(0.5)
        XCTAssertEqual(reports.count, settled, "Reports continue: \(reports.suffix(6))")
        XCTAssertLessThan(settled, 6, "\(reports.prefix(8))")
        XCTAssertEqual(editor.string, field.query, "The field and the query agree")
        // The same, with a key right behind it.
        reports = []
        field.valueChanged?("ca")
        editor.insertText("e", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        S.spin(0.5)
        settled = reports.count
        S.spin(0.5)
        XCTAssertEqual(reports.count, settled, "Reports continue: \(reports.suffix(6))")
        XCTAssertLessThan(settled, 6, "\(reports.prefix(8))")
        XCTAssertEqual(editor.string, field.query, "The field and the query agree")
        XCTAssertTrue(editor.string.hasSuffix("e"), "The key typed last is kept: \(editor.string)")
    }

    // MARK: Items 8 and 10e. Storage

    /// A selected path copies exactly the path: the text shown holds no invisible break characters.
    func testAShownPathHoldsOnlyThePathsCharacters() {
        let url = URL(fileURLWithPath: "/Volumes/Cache/Autosave Information/com.example.desktop/.transcript-jobs")
        let shown = SettingsPath.display(url.path)
        XCTAssertEqual(shown, url.path)
        XCTAssertFalse(shown.unicodeScalars.contains { $0.properties.generalCategory == .format }, shown)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MPCut").path
        XCTAssertEqual(SettingsPath.display(home), "~/Library/Caches/MPCut")
    }

    func testAClearThatRemovedNothingSaysSoOnce() {
        let empty = StorageUsageModel.Report(kind: .generatedStills, result: StoreClearResult())
        XCTAssertEqual(StorageUsageSection.title(empty), "Nothing removed from generated stills")
        XCTAssertEqual(StorageUsageSection.summary(empty.result, left: empty.left), "")
    }
}

/// A count the helper probe, which runs off the main actor, adds to.
private final class ProbeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
