import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

/// The polish pass's field, window and warning mechanics, each driven through the path the editor uses: a click that
/// goes through the window's mouse-down handling, a key the window delivers, a dialog's own button.
@MainActor
final class SettingsPolishTests: XCTestCase {
    private typealias S = SettingsFix3Support
    private typealias A = SettingsFix4AccessibilityTests

    private func settings(_ preferences: EditorPreferences) throws -> SettingsWindow {
        SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() }, storageLocations: try S.temporaryLocations())
    }

    /// The element's frame in window coordinates, from the frame it reports to accessibility clients.
    private func frame(of element: A.Element, in window: NSWindow) -> NSRect? {
        guard element.object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = element.object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return window.convertFromScreen(value.rectValue)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    /// A click as the application delivers it: the window's mouse-down monitor sees the press first.
    private func click(at point: NSPoint, in window: NSWindow) throws {
        NSApp.postEvent(try mouse(.leftMouseUp, at: point, in: window), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown, at: point, in: window))
        S.spin(0.3)
    }

    private func key(_ characters: String, code: UInt16, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        S.spin(0.2)
    }

    private func sheetButton(_ title: String, of window: NSWindow) throws -> NSButton {
        let sheet = try XCTUnwrap(window.attachedSheet, "The dialog is a sheet on the Settings window")
        let buttons = S.descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
        return try XCTUnwrap(buttons.first { $0.title == title }, "\(buttons.map(\.title))")
    }

    private func waitForElement(_ identifier: String, in host: NSView, timeout: TimeInterval = 5) throws -> A.Element {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = A.elements(host).first(where: { $0.identifier == identifier }) { return element }
            S.spin(0.1)
        }
        return try XCTUnwrap(A.elements(host).first { $0.identifier == identifier }, "\(identifier) never appeared")
    }

    private func openRestoreDialog(_ page: SettingsPage, window: NSWindow, host: NSView) throws {
        let restore = try waitForElement("settings.restore." + page.rawValue, in: host)
        restore.press()
        let deadline = Date().addingTimeInterval(3)
        while window.attachedSheet == nil, Date() < deadline { S.spin(0.1) }
        XCTAssertNotNil(window.attachedSheet, "Restore Defaults… asks first")
    }

    // MARK: A5 D-1. A click on Restore Defaults never commits the typed number

    func testAClickOnRestoreDefaultsDropsTheTypedNumberInsteadOfCommittingIt() throws {
        let preferences = EditorPreferences()
        preferences.recentFilesLimit = 30
        preferences.settingsPage = .general
        let (window, host) = S.window(try settings(preferences), size: NSSize(width: 820, height: 1000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.5)
        let recent = try XCTUnwrap(S.editableFields(host).first { $0.stringValue == "30" })

        // The same click path commits when it lands on blank space, so the path reaches the window's handling.
        try S.type("29", into: recent, in: window)
        try click(at: NSPoint(x: SettingsWindow.sidebarWidth + 30, y: 8), in: window)
        XCTAssertEqual(preferences.recentFilesLimit, 29, "A click on blank space commits")

        try S.type("1", into: recent, in: window)
        let restore = try waitForElement("settings.restore.general", in: host)
        let button = try XCTUnwrap(frame(of: restore, in: window))
        try click(at: NSPoint(x: button.midX, y: button.midY), in: window)
        XCTAssertEqual(preferences.recentFilesLimit, 29, "The click on Restore Defaults… does not commit the typed 1")
        if window.attachedSheet == nil { restore.press() }
        let deadline = Date().addingTimeInterval(3)
        while window.attachedSheet == nil, Date() < deadline { S.spin(0.1) }
        XCTAssertEqual(preferences.recentFilesLimit, 29, "Showing the dialog does not commit it either")

        try sheetButton("Cancel", of: window).performClick(nil)
        S.spin(0.4)
        XCTAssertEqual(preferences.recentFilesLimit, 29, "Cancel changes nothing")
        XCTAssertEqual(recent.stringValue, "1", "Cancel leaves the number as typed")

        try openRestoreDialog(.general, window: window, host: host)
        try sheetButton("Restore Defaults", of: window).performClick(nil)
        S.spin(0.5)
        XCTAssertEqual(preferences.recentFilesLimit, 10, "Restore writes the factory value")
        window.close()
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(preferences.recentFilesLimit, 10, "The dropped 1 is never committed later")
    }

    // MARK: G5 1. Restore runs after its dialog has closed

    /// The restore runs on the next turn of the run loop, outside the dialog's button action. This alone did not stop
    /// the reentrant-layout fault: that came from the switch's AppKit animation, whatever changed its value, and
    /// `SettingsP2Tests.testASwitchChangedFromOutsideTheWindowIsSetWithoutAnimation` covers it.
    func testRestoreDefaultsRestoresASwitchAfterTheDialogCloses() throws {
        let preferences = EditorPreferences()
        preferences.scrubSoundEnabled = false
        preferences.settingsPage = .playback
        let (window, host) = S.window(try settings(preferences), size: NSSize(width: 820, height: 1000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.5)
        try openRestoreDialog(.playback, window: window, host: host)
        try sheetButton("Restore Defaults", of: window).performClick(nil)
        XCTAssertFalse(preferences.scrubSoundEnabled, "Nothing is restored inside the dialog's button action")
        S.spin(0.5)
        XCTAssertTrue(preferences.scrubSoundEnabled)
        XCTAssertNil(window.attachedSheet)
    }

    // MARK: A5 D-2 and D-5. The suppression set follows the switches and the Finder action

    func testAFinderActionChosenInSettingsSurvivesResetAllWarnings() {
        let preferences = EditorPreferences()
        preferences.suppress(.openMultipleRecordings, choosing: .join)
        XCTAssertEqual(preferences.multipleRecordingsAction, .join)
        preferences.multipleRecordingsAction = .multicam
        preferences.resetAllWarnings()
        XCTAssertEqual(preferences.multipleRecordingsAction, .multicam, "The action chosen in Settings stays")

        // Still: an action the alert chose goes back to Ask.
        preferences.suppress(.openMultipleRecordings, choosing: .join)
        preferences.resetAllWarnings()
        XCTAssertEqual(preferences.multipleRecordingsAction, .ask)
    }

    func testTurningAWarningBackOnLeavesNothingToReset() {
        let preferences = EditorPreferences()
        preferences.suppress(.sceneRescan)
        XCTAssertTrue(preferences.hasSuppressedWarnings)
        preferences.confirmsSceneRescan = true
        preferences.suppress(.exportTierDowngrade)
        preferences.warnBeforeLoweringExportTier = true
        preferences.suppress(.openMultipleRecordings, choosing: .join)
        preferences.multipleRecordingsAction = .ask
        XCTAssertFalse(preferences.hasSuppressedWarnings, "Reset All Warnings has nothing to do")
        XCTAssertTrue(preferences.hasFactoryValues(on: .general), "Restore Defaults… has nothing to do")
        XCTAssertTrue(SettingsRestoreSummary.message(for: .general, preferences: preferences).contains("already has its factory value"))
    }

    func testARefusedAgentWriteKeepsTheDontAskAgain() {
        let preferences = EditorPreferences()
        preferences.suppress(.sceneRescan)
        preferences.agentsChangeSettings = false
        AgentOrigin.$request.withValue(AgentSettingsRequest()) { preferences.confirmsSceneRescan = true }
        XCTAssertFalse(preferences.confirmsSceneRescan)
        preferences.resetAllWarnings()
        XCTAssertTrue(preferences.confirmsSceneRescan)
        XCTAssertFalse(preferences.hasSuppressedWarnings)
    }

    func testAStaleDontAskAgainIsDroppedWhenLoaded() throws {
        let name = "com.mpcut.tests.settings-polish." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(["scene_rescan", "open_multiple_recordings"], forKey: "warnings_suppressed")
        defaults.set(true, forKey: "scene_rescan_confirmation_enabled")
        defaults.set("join", forKey: "open_multiple_recordings_default_action")
        let preferences = EditorPreferences(defaults: defaults)
        XCTAssertTrue(preferences.hasSuppressedWarnings, "The Finder action the alert chose is still silenced")
        preferences.resetAllWarnings()
        XCTAssertEqual(preferences.multipleRecordingsAction, .ask)
        defaults.set(["scene_rescan"], forKey: "warnings_suppressed")
        XCTAssertFalse(EditorPreferences(defaults: defaults).hasSuppressedWarnings, "A switch that is on silences nothing")
    }

    // MARK: A5 D-11. Numbers read the same in every locale, and a grouping separator never multiplies a value

    func testNumbersReadTheSameInGermanAndAmericanLocales() {
        let us = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")
        for locale in [us, de] {
            XCTAssertEqual(Double(settingsText: "1.5", locale: locale), 1.5, locale.identifier)
            XCTAssertEqual(Double(settingsText: "1,5", locale: locale), 1.5, "\(locale.identifier): never 15")
            XCTAssertEqual(Double(settingsText: " 2.25 ", locale: locale), 2.25, locale.identifier)
            XCTAssertEqual(Double(settingsText: "-5", locale: locale), -5, locale.identifier)
            XCTAssertNil(Double(settingsText: "1,2,3", locale: locale), locale.identifier)
            XCTAssertNil(Double(settingsText: "abc", locale: locale), locale.identifier)
            XCTAssertNil(Double(settingsText: "", locale: locale), locale.identifier)
            XCTAssertNil(Double(settingsText: "1e3", locale: locale), locale.identifier)
            XCTAssertEqual(Int(settingsText: "1920", locale: locale), 1920, locale.identifier)
            XCTAssertNil(Int(settingsText: "5.5", locale: locale), locale.identifier)
            XCTAssertNil(Int(settingsText: "5,5", locale: locale), locale.identifier)
            XCTAssertEqual(Int(settingsText: "-5", locale: locale), -5, locale.identifier)
        }
        // A lone 0 before the mark is never a group: 0.125 stays below 1 in every locale.
        for locale in [us, de] {
            for (text, value) in [("0.125", 0.125), ("0,125", 0.125), ("0.001", 0.001), ("0,001", 0.001), (",5", 0.5), ("5.", 5)] {
                XCTAssertEqual(Double(settingsText: text, locale: locale), value, "\(locale.identifier) \(text)")
            }
        }
        // A number grouped the locale's way reads as one number, in Int and Double fields alike.
        XCTAssertEqual(Int(settingsText: "8,192", locale: us), 8192)
        XCTAssertEqual(Double(settingsText: "8,192", locale: us), 8192)
        XCTAssertEqual(Int(settingsText: "8.192", locale: de), 8192)
        XCTAssertEqual(Double(settingsText: "1,500.25", locale: us), 1500.25)
        XCTAssertEqual(Double(settingsText: "1.500,25", locale: de), 1500.25)
        XCTAssertEqual(Int(settingsText: "1 920", locale: Locale(identifier: "fr_FR")), 1920)
        XCTAssertEqual(Int(settingsText: "1\u{202F}920", locale: Locale(identifier: "fr_FR")), 1920)
        // The locale's own digits.
        XCTAssertEqual(Int(settingsText: "١٢", locale: Locale(identifier: "ar_EG")), 12)
        XCTAssertEqual(Double(settingsText: "١٫٥", locale: Locale(identifier: "ar_EG")), 1.5)

        // What a field shows reads back as the same value.
        XCTAssertEqual(1.5.settingsText(digits: 2, locale: de), "1,5")
        XCTAssertEqual(1.5.settingsText(digits: 2, locale: us), "1.5")
        XCTAssertEqual(Double(settingsText: 1.5.settingsText(digits: 2, locale: de), locale: de), 1.5)
        XCTAssertTrue(0.0.settingsIsZero)
        XCTAssertTrue(0.settingsIsZero)
        XCTAssertFalse(0.001.settingsIsZero)
    }

    func testRangesGroupTheirDigits() {
        var width = 1920
        let pixels = SettingsNumericField(.stillTimelineWidth, value: Binding(get: { width }, set: { width = $0 }),
                                          in: EditorPreferences.stillTimelinePixelRange, step: 2, unit: "px")
        XCTAssertEqual(pixels.rangeDescription, (16).formatted() + "–" + (8192).formatted() + " px")
        var gigabytes = 0.0
        let cache = SettingsNumericField(.cacheLimit, value: Binding(get: { gigabytes }, set: { gigabytes = $0 }),
                                         in: 0...SettingsStoragePage.cacheLimitMaximumGigabytes, step: 1, unit: "GB",
                                         digits: SettingsStoragePage.cacheLimitDigits)
        XCTAssertEqual(cache.rangeDescription, "0–" + (1_000_000).formatted() + " GB")
    }

    // MARK: G5 3 and 4. Numeric fields show a focus ring, and Esc puts the stored value back

    func testNumericFieldsAreBezeledWithAFocusRing() throws {
        let preferences = EditorPreferences()
        preferences.settingsPage = .transcripts
        let (window, host) = S.window(try settings(preferences), size: NSSize(width: 820, height: 1400))
        defer { window.close() }
        S.spin(0.4)
        let fields = S.editableFields(host)
        XCTAssertGreaterThanOrEqual(fields.count, 5)
        for field in fields {
            XCTAssertTrue(field.isBezeled, "“\(field.stringValue)” draws a field's border, so it reads as editable")
            XCTAssertNotEqual(field.focusRingType, .none, "“\(field.stringValue)” shows a focus ring")
        }
    }

    private struct Captions: View {
        @ObservedObject var preferences: EditorPreferences
        var body: some View {
            SettingsForm(page: .transcripts, preferences: preferences) {
                Section("Captions") {
                    SettingsNumericField(.captionCharacters, value: $preferences.captionLineCharacters,
                                         in: EditorPreferences.captionLineCharacterRange, step: 1)
                    SettingsFillerTermsField(preferences: preferences)
                }
            }
            // The Settings window's own key and mouse handling.
            .background(SettingsWindowHooks())
        }
    }

    func testEscInANumericFieldPutsTheStoredValueBackWithoutCommitting() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(Captions(preferences: preferences), size: NSSize(width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.4)
        let field = try XCTUnwrap(S.editableFields(host).first { $0.stringValue == "42" })
        try S.type("50", into: field, in: window)
        try key("\u{1b}", code: 53, in: window)
        XCTAssertEqual(preferences.captionLineCharacters, 42)
        XCTAssertEqual(field.stringValue, "42", "The field shows the stored value again")
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            XCTAssertEqual(editor.string, "42")
            editor.insertNewline(nil)
            S.spin(0.2)
        }
        XCTAssertEqual(preferences.captionLineCharacters, 42, "Return after Esc commits nothing")
        window.close()
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(preferences.captionLineCharacters, 42, "Closing after Esc commits nothing")
    }

    // MARK: G5 5. Filler terms commits like every other field

    func testFillerTermsCommitsOnReturnClickAndCloseNeverWhileTyping() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(Captions(preferences: preferences), size: NSSize(width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.4)
        let field = try XCTUnwrap(S.editableFields(host).first { $0.placeholderString == "um, uh, you know" })
        XCTAssertTrue(field.isBezeled, "It looks like a field you can type in")
        XCTAssertNotEqual(field.focusRingType, .none)

        try S.type("um, uh", into: field, in: window)
        S.spin(0.2)
        XCTAssertEqual(preferences.fillerTerms, "", "Typing alone never commits")
        try XCTUnwrap(window.firstResponder as? NSTextView).insertNewline(nil)
        S.spin(0.2)
        XCTAssertEqual(preferences.fillerTerms, "um, uh", "Return commits")

        try S.type("like", into: field, in: window)
        XCTAssertTrue(SettingsWindowHooks.handle(try mouse(.leftMouseDown, at: NSPoint(x: 5, y: 5), in: window), in: window).type
                      == .leftMouseDown)
        S.spin(0.2)
        XCTAssertEqual(preferences.fillerTerms, "like", "A click elsewhere commits")

        try S.type("so", into: field, in: window)
        try key("\u{1b}", code: 53, in: window)
        XCTAssertEqual(field.stringValue, "like", "Esc puts the stored text back")
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { editor.insertNewline(nil) }
        S.spin(0.2)
        XCTAssertEqual(preferences.fillerTerms, "like")

        try S.type("you know", into: field, in: window)
        SettingsRestoreDefaults.restore(.transcripts, preferences: preferences)
        S.spin(0.2)
        window.close()
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(preferences.fillerTerms, "", "Restore Defaults drops the typed text")
    }

    func testFillerTermsKeepsAtMostWhatAgentsMayStore() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(Captions(preferences: preferences), size: NSSize(width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.4)
        let field = try XCTUnwrap(S.editableFields(host).first { $0.placeholderString == "um, uh, you know" })
        try S.type(String(repeating: "a", count: 5_000), into: field, in: window)
        try XCTUnwrap(window.firstResponder as? NSTextView).insertNewline(nil)
        S.spin(0.2)
        XCTAssertEqual(preferences.fillerTerms.count, EditorPreferences.fillerTermsMaximumLength)
        XCTAssertEqual(EditorPreferences.fillerTermsMaximumLength, 4_096)
        // Counted as agents' writes are, in Unicode scalars, without splitting a character.
        XCTAssertEqual(SettingsTextField.kept(String(repeating: "é", count: 3), 2), "éé")
        XCTAssertEqual(SettingsTextField.kept("ab\u{1F44D}\u{1F3FD}", 3), "ab", "The two-scalar emoji does not fit in one")
        XCTAssertEqual(SettingsTextField.kept("abc", 3), "abc")
    }

    func testTypedFillerTermsCommitWhenTheWindowCloses() throws {
        let preferences = EditorPreferences()
        let (window, host) = S.window(Captions(preferences: preferences), size: NSSize(width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        S.spin(0.4)
        let field = try XCTUnwrap(S.editableFields(host).first { $0.placeholderString == "um, uh, you know" })
        try S.type("basically", into: field, in: window)
        S.spin(0.1)
        XCTAssertEqual(preferences.fillerTerms, "")
        window.close()
        S.spin(0.1)
        XCTAssertEqual(preferences.fillerTerms, "basically")
    }
}
