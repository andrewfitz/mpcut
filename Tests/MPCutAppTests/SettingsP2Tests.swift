import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import MPCutApp

/// What the on-screen check of the polish pass found: switches that Restore Defaults or an agent changes, toggles that
/// drew as checkboxes, range notices over a border, repeated identifiers, a flag broken across lines, and paths.
@MainActor
final class SettingsP2Tests: XCTestCase {
    private typealias S = SettingsFix3Support
    private typealias A = SettingsFix4AccessibilityTests

    private func settings(_ preferences: EditorPreferences, locations: StorageLocations? = nil) throws -> SettingsWindow {
        SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                       storageLocations: try locations ?? S.temporaryLocations())
    }

    // MARK: Item 1. A switch changed by Restore Defaults or an agent is set without AppKit's animation

    /// Counts `-[_NSViewAnimator_NSSwitch setState:]`, the animated state change SwiftUI asks for unless the update's
    /// transaction disables animations. That animation draws the switch at once, which lays the window out from inside
    /// SwiftUI's update: the app then logs “NSHostingView is being laid out reentrantly while rendering its SwiftUI
    /// content”. This host does not log the fault itself, so the test counts the call that leads to it.
    enum SwitchAnimation {
        nonisolated(unsafe) static var calls = 0
        nonisolated(unsafe) private static var installed = false

        static func install() throws {
            guard !installed else { return }
            let selector = NSSelectorFromString("setState:")
            guard let animator = NSClassFromString("_NSViewAnimator_NSSwitch"),
                  let method = class_getInstanceMethod(animator, selector) else {
                throw XCTSkip("This AppKit has no switch animator to watch")
            }
            typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
            let replacement: @convention(block) (AnyObject, Int) -> Void = { object, state in
                calls += 1
                original(object, selector, state)
            }
            // Only the animator's own method: an inherited one would be replaced for every class that shares it.
            if !class_addMethod(animator, selector, imp_implementationWithBlock(replacement), method_getTypeEncoding(method)) {
                method_setImplementation(method, imp_implementationWithBlock(replacement))
            }
            installed = true
        }
    }

    private func switches(_ host: NSView) -> [NSSwitch] { S.descendants(host).compactMap { $0 as? NSSwitch } }

    func testASwitchChangedFromOutsideTheWindowIsSetWithoutAnimation() throws {
        try SwitchAnimation.install()
        let cases: [(SettingsPage, ReferenceWritableKeyPath<EditorPreferences, Bool>)] = [
            (.general, \.warnBeforeLoweringExportTier), (.editing, \.sourceTimeTicks), (.playback, \.scrubSoundEnabled),
            (.export, \.savesExportResult), (.export, \.revealsFinishedExport), (.storage, \.useAnalysisSidecars),
            (.automation, \.agentsChangeSettings)
        ]
        for (page, key) in cases {
            let preferences = EditorPreferences()
            preferences.settingsPage = page
            let (window, host) = S.window(try settings(preferences), size: NSSize(width: 900, height: 2400))
            window.makeKeyAndOrderFront(nil)
            S.spin(0.5)
            let before = switches(host).map(\.state)
            XCTAssertFalse(before.isEmpty, "\(page.rawValue) shows its switches")

            // As an agent's `preferences_set` does.
            SwitchAnimation.calls = 0
            preferences[keyPath: key].toggle()
            S.spin(0.4)
            XCTAssertEqual(SwitchAnimation.calls, 0, "\(page.rawValue) \(key): the switch follows without AppKit's animation")
            XCTAssertNotEqual(switches(host).map(\.state), before, "\(page.rawValue): the switch shows the new value")

            // As Restore Defaults does, after its dialog. Automation's restore keeps the agent switches, so the test puts
            // that one back itself.
            SwitchAnimation.calls = 0
            if page == .automation { preferences[keyPath: key].toggle() } else { SettingsRestoreDefaults.restore(page, preferences: preferences) }
            S.spin(0.4)
            XCTAssertEqual(SwitchAnimation.calls, 0, "\(page.rawValue): Restore Defaults sets the switch without animation")
            XCTAssertEqual(switches(host).map(\.state), before, "\(page.rawValue): the switch shows the factory value again")
            window.close()
        }
    }

    func testTheWatchSeesAnAnimatedSwitch() throws {
        // The construction the pages used before: a switch in a grouped form, updated from outside the view.
        final class Model: ObservableObject { @Published var on = false }
        struct Probe: View {
            @ObservedObject var model: Model
            var body: some View { Form { Toggle("Probe", isOn: $model.on) }.formStyle(.grouped) }
        }
        try SwitchAnimation.install()
        let model = Model()
        let (window, _) = S.window(Probe(model: model), size: NSSize(width: 400, height: 200))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.4)
        SwitchAnimation.calls = 0
        model.on = true
        S.spin(0.4)
        XCTAssertGreaterThan(SwitchAnimation.calls, 0, "Without the fix SwiftUI animates the switch, so the watch can fail")
    }

    // MARK: Item 2. Every toggle draws as a switch, with its title once

    func testEveryToggleOnEveryPageIsASwitch() throws {
        let preferences = EditorPreferences()
        let locations = try S.temporaryLocations()
        for page in SettingsPage.allCases {
            preferences.settingsPage = page
            let (window, host) = S.window(try settings(preferences, locations: locations), size: NSSize(width: 900, height: 2400))
            S.spin(0.4)
            let toggles = S.accessibilityElements(of: host).filter { $0.role == "AXCheckBox" }
            XCTAssertFalse(toggles.isEmpty, page.rawValue)
            for toggle in toggles {
                XCTAssertEqual(A.ask(toggle.object, "accessibilitySubrole") as? String, "AXSwitch",
                               "\(page.rawValue): \(toggle.identifier) “\(toggle.label)” draws as a switch")
                XCTAssertEqual(A.names(toggle).count, 1, "\(page.rawValue): \(toggle.identifier) reads its title once: \(A.names(toggle))")
            }
            // The switches the rows draw, all one size.
            let sizes = Set(switches(host).map { "\($0.frame.width)x\($0.frame.height)" })
            XCTAssertEqual(sizes.count, 1, "\(page.rawValue): every switch is the same size, \(sizes)")
            window.close()
        }
    }

    // MARK: Item 4. No identifier repeats on a page

    func testNoAccessibilityIdentifierRepeatsOnAnyPage() throws {
        let preferences = EditorPreferences()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-p2-\(UUID().uuidString)", isDirectory: true)
        // Two transcript job folders, as the real store has, so their two path texts are both on the page.
        let locations = StorageLocations(generatedStills: root.appendingPathComponent("Stills"),
                                         transcriptRecognition: root.appendingPathComponent("Claims"),
                                         transcriptJobs: [root.appendingPathComponent("Drafts/.transcript-jobs"),
                                                          root.appendingPathComponent("TranscriptJobs")],
                                         untitledDrafts: root.appendingPathComponent("Drafts"),
                                         agentReceipts: root.appendingPathComponent("Receipts"))
        for page in SettingsPage.allCases {
            preferences.settingsPage = page
            let (window, host) = S.window(try settings(preferences, locations: locations), size: NSSize(width: 900, height: 2400))
            S.spin(page == .storage ? 1.0 : 0.4)
            var seen = Set<ObjectIdentifier>()
            var counts: [String: Int] = [:]
            for element in S.accessibilityElements(of: host) where seen.insert(ObjectIdentifier(element.object)).inserted {
                guard !element.identifier.isEmpty, !element.identifier.hasPrefix("_NS") else { continue }
                counts[element.identifier, default: 0] += 1
            }
            let repeated = counts.filter { $0.value > 1 }.keys.sorted()
            XCTAssertEqual(repeated, [], "\(page.rawValue): identifiers on more than one element")
            if page == .storage {
                XCTAssertNotNil(counts["settings.storage.usage.transcriptJobs.path.1"])
                XCTAssertNotNil(counts["settings.storage.usage.transcriptJobs.path.2"])
            }
            window.close()
        }
    }

    // MARK: Item 5. A flag in a footnote stays on one line

    /// Every width at which TextKit would break the text inside `word`, from 120 to 700 points.
    private func widthsBreaking(_ word: String, in attributed: AttributedString) -> [Int] {
        let text = NSMutableAttributedString(attributed)
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: NSRange(location: 0, length: text.length))
        let plain = text.string as NSString
        // The word as laid out: its characters with anything invisible between them.
        let pattern = word.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\u{2060}?")
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: plain as String, range: NSRange(location: 0, length: plain.length)) else {
            XCTFail("\(word) is not in the text")
            return []
        }
        var breaking: [Int] = []
        for width in stride(from: 120, through: 700, by: 1) {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: CGFloat(width), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
            let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            if first.minY != last.minY { breaking.append(width) }
        }
        return breaking
    }

    func testCodeInAFootnoteNeverBreaksAcrossLines() {
        let footnote = SettingsFootnote.attributed("When this is on, programs can read. A client set up with `--files-only` works on files through the bundled command-line tool and does not need this switch.")
        XCTAssertEqual(widthsBreaking("--files-only", in: footnote), [], "The flag breaks at these widths")
        // It still reads, and is announced, as the flag: the joiners between its characters are invisible.
        let code = footnote.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        let flag = code.map { String(footnote[$0.range].characters) }
        XCTAssertEqual(flag?.replacingOccurrences(of: "\u{2060}", with: ""), "--files-only")
        XCTAssertFalse(String(footnote.characters).replacingOccurrences(of: "\u{2060}", with: "").contains("`"))
        // Text outside code is left as written, so it wraps as usual.
        let prose = footnote.runs.filter { $0.inlinePresentationIntent?.contains(.code) != true }
        XCTAssertFalse(prose.contains { String(footnote[$0.range].characters).contains("\u{2060}") })
        XCTAssertTrue(String(footnote.characters).hasSuffix("through the bundled command-line tool and does not need this switch."))
    }

    // MARK: Item 6. A path's status is its own text, and the full path is exposed once

    func testAPathIsExposedOnceAndItsStatusIsSeparate() throws {
        let preferences = EditorPreferences()
        preferences.settingsPage = .storage
        let locations = try S.temporaryLocations()
        let (window, host) = S.window(try settings(preferences, locations: locations), size: NSSize(width: 900, height: 2400))
        defer { window.close() }
        let stills = try XCTUnwrap(locations.generatedStills).path
        let deadline = Date().addingTimeInterval(10)
        var elements = S.accessibilityElements(of: host)
        while !elements.contains(where: { $0.identifier == "settings.storage.usage.generatedStills.path.status" }), Date() < deadline {
            S.spin(0.2)
            elements = S.accessibilityElements(of: host)
        }
        let path = try XCTUnwrap(elements.first { $0.identifier == "settings.storage.usage.generatedStills.path" })
        // The temporary folder is outside the home folder, so the path shows in full: the text, and nothing else, says it.
        XCTAssertEqual(path.value.replacingOccurrences(of: "\n", with: ""), SettingsPath.display(stills), "The selectable text is the path alone")
        let help = A.ask(path.object, "accessibilityHelp") as? String ?? ""
        XCTAssertNotEqual(help, path.value, "The full path is not repeated as help")
        let status = try XCTUnwrap(elements.first { $0.identifier == "settings.storage.usage.generatedStills.path.status" })
        XCTAssertEqual(status.value.isEmpty ? status.label : status.value, "Not created yet")
    }

    func testAPathTextAddsHelpOnlyWhenItShortensThePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Project").path
        XCTAssertEqual(SettingsPathText.help(for: home), home, "A path shown with ~ has the full path as help")
        XCTAssertNil(SettingsPathText.help(for: "/Volumes/Cache/MPCut"), "A path shown in full has no help repeating it")
    }

    // MARK: Item 3. A range notice sits beside its field when it fits, else below

    func testANoticeSitsLeftOfItsFieldWhenItFitsBesideTheTitle() {
        let field = CGRect(x: 400, y: 100, width: 130, height: 22)
        let title = CGRect(x: 30, y: 103, width: 90, height: 16)
        let notice = CGSize(width: 140, height: 20)
        let beside = SettingsNoticePlacement.frame(field: field, title: title, notice: notice)
        XCTAssertEqual(beside.maxX, field.minX - SettingsNoticePlacement.gap)
        XCTAssertEqual(beside.midY, field.midY, "On the field's line")
        XCTAssertFalse(beside.intersects(title.insetBy(dx: -SettingsNoticePlacement.gap, dy: 0)), "Clear of the title")
        // No room beside a long title: below the field, its trailing edge on the field's.
        let long = CGRect(x: 30, y: 103, width: 300, height: 16)
        let below = SettingsNoticePlacement.frame(field: field, title: long, notice: notice)
        XCTAssertEqual(below.minY, field.maxY + SettingsNoticePlacement.below)
        XCTAssertEqual(below.maxX, field.maxX)
        // With no title to keep clear of, below as well.
        XCTAssertEqual(SettingsNoticePlacement.frame(field: field, title: nil, notice: notice), below)
        // A field with a caption under it (what 0 means): below the field but left of the caption, under the title.
        let medium = CGRect(x: 30, y: 103, width: 250, height: 16)
        let column = CGRect(x: 395, y: 100, width: 135, height: 40)
        let left = SettingsNoticePlacement.frame(field: field, title: medium, column: column, notice: notice)
        XCTAssertEqual(left.maxX, column.minX - SettingsNoticePlacement.gap, "Left of the caption under the field")
        XCTAssertEqual(left.minY, field.maxY + SettingsNoticePlacement.below)
        XCTAssertFalse(left.intersects(medium), "Under the title, not over it")
        // No room under the title either: below the field, as before.
        let narrow = CGRect(x: 150, y: 100, width: 380, height: 40)
        XCTAssertEqual(SettingsNoticePlacement.frame(field: field, title: medium, column: narrow, notice: notice).maxX, field.maxX)
    }

    private struct ZeroCaption: View {
        @ObservedObject var preferences: EditorPreferences
        var body: some View {
            SettingsForm(page: .storage, preferences: preferences) {
                Section("Limits") {
                    SettingsNumericField(.draftRetention, value: $preferences.draftRetentionDays, in: EditorPreferences.draftRetentionRange,
                                         step: 1, unit: "days", zeroMeaning: "Drafts are never removed")
                }
            }
        }
    }

    func testANoticeNeverCoversTheCaptionUnderItsField() throws {
        let preferences = EditorPreferences()
        preferences.draftRetentionDays = 0
        // As narrow as the window's minimum page: no room beside the field for “Limited to 0–365 days.”.
        let (window, host) = S.window(ZeroCaption(preferences: preferences), size: NSSize(width: 430, height: 300))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        S.spin(0.3)
        let field = try XCTUnwrap(S.editableFields(host).first)
        try S.type("-1", into: field, in: window)
        try XCTUnwrap(window.firstResponder as? NSTextView).insertNewline(nil)
        S.spin(0.4)
        XCTAssertEqual(preferences.draftRetentionDays, 0)
        let notice = try XCTUnwrap(S.descendants(host).compactMap { $0 as? SettingsNoticeMarker.MarkerView }.first, "The notice shows")
        let noticeFrame = notice.convert(notice.bounds, to: nil)
        let caption = try XCTUnwrap(S.accessibilityElements(of: host).first { $0.identifier == SettingsRow.draftRetention.id + ".zero" })
        let screen = try XCTUnwrap(caption.object.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let captionFrame = window.convertFromScreen(screen)
        XCTAssertFalse(noticeFrame.insetBy(dx: 1, dy: 1).intersects(captionFrame), "The notice \(noticeFrame) covers the caption \(captionFrame)")
        let fieldFrame = field.convert(field.bounds, to: nil)
        XCTAssertFalse(noticeFrame.intersects(fieldFrame), "The notice covers the field")
    }
}
