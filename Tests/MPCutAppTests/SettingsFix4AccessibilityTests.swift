import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

/// VoiceOver reads each Settings control's title once. The hosting view's accessibility elements are read the way an
/// accessibility client reaches them, through `accessibilityChildren`, `accessibilityRole` and `accessibilityLabel`;
/// SwiftUI's own element objects answer these only through the Objective-C runtime, so the walk asks by selector.
@MainActor
final class SettingsFix4AccessibilityTests: XCTestCase {
    private typealias S = SettingsFix3Support

    @MainActor struct Element {
        let object: NSObject
        let role: String
        let label: String
        let identifier: String

        var value: String { SettingsFix4AccessibilityTests.ask(object, "accessibilityValue").map { "\($0)" } ?? "" }

        /// Presses the element as an accessibility client does. The call returns a BOOL, so its result is not read as an object.
        func press() {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if object.responds(to: selector) { _ = object.perform(selector) }
        }
    }

    nonisolated static func ask(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    static func elements(_ root: Any, depth: Int = 0) -> [Element] {
        guard depth < 60, let object = root as? NSObject else { return [] }
        let here = Element(object: object, role: ask(object, "accessibilityRole") as? String ?? "",
                           label: ask(object, "accessibilityLabel") as? String ?? "",
                           identifier: ask(object, "accessibilityIdentifier") as? String ?? "")
        let children = ask(object, "accessibilityChildren") as? [Any] ?? []
        return [here] + children.flatMap { elements($0, depth: depth + 1) }
    }

    /// A label made of the same words twice, such as "Width, Width".
    static func isRepeated(_ label: String) -> Bool {
        let parts = label.components(separatedBy: ", ")
        return parts.count > 1 && Set(parts).count < parts.count
    }

    private static let numericRows: [SettingsPage: [SettingsRow]] = [
        .general: [.recentItems, .historyLimit],
        .editing: [.trackLabelWidth, .stillDuration, .gapDuration, .stillTimelineWidth, .stillTimelineHeight, .stillTimelineFrameRate],
        .playback: [.preroll, .postroll],
        .media: [.minimumPause, .maxBlip, .padding, .tilesColumns, .tilesRows, .dialogueHold],
        .transcripts: [.readerTextSize, .retainedPause, .captionCharacters, .captionLines, .captionCue],
        .storage: [.cacheLimit, .draftRetention]
    ]

    func testEveryControlOnEveryPageHasItsTitleOnce() throws {
        let preferences = EditorPreferences()
        let locations = try S.temporaryLocations()
        // A tall window, so the pages build their rows without scrolling them out.
        for page in SettingsPage.allCases {
            preferences.settingsPage = page
            let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                         storageLocations: locations), size: NSSize(width: 900, height: 2400))
            S.spin(0.4)
            let elements = Self.elements(host)
            XCTAssertTrue(elements.contains { $0.role == "AXTextField" || $0.role == "AXPopUpButton" || $0.role == "AXCheckBox" },
                          "\(page.rawValue): the walk reaches the page's controls")
            for element in elements where Self.isRepeated(element.label) {
                XCTFail("\(page.rawValue): \(element.role) \(element.identifier) reads “\(element.label)”")
            }
            // Controls whose second, explicit label was removed still read their row's title.
            for row in [SettingsRow.volume, .localMCP] where row.page == page {
                XCTAssertEqual(elements.first { $0.identifier == row.id }?.label, row.title, row.id)
            }
            for row in Self.numericRows[page] ?? [] {
                let field = elements.first { $0.identifier == row.id }
                XCTAssertEqual(field?.role, "AXTextField", row.id)
                XCTAssertEqual(field?.label, row.title, "\(row.id): the field reads its row's title once")
                let stepper = elements.first { $0.identifier == row.id + ".stepper" }
                XCTAssertEqual(stepper?.role, "AXIncrementor", "\(row.id): the stepper reads as a stepper, not a second field")
                XCTAssertEqual(stepper?.label, row.title, "\(row.id): the stepper reads its row's title once")
            }
            window.close()
        }
    }

    func testTheWalkSeesARepeatedLabel() throws {
        // The construction the fields used before: a control's own title plus the same `.accessibilityLabel`.
        struct Doubled: View {
            @State private var text = "1"
            var body: some View {
                Form { TextField("Probe title", text: $text).labelsHidden().accessibilityLabel("Probe title") }.formStyle(.grouped)
            }
        }
        let (window, host) = S.window(Doubled(), size: NSSize(width: 400, height: 200))
        defer { window.close() }
        S.spin(0.4)
        let field = Self.elements(host).first { $0.role == "AXTextField" }
        XCTAssertEqual(field?.label, "Probe title, Probe title")
        XCTAssertTrue(Self.isRepeated(field?.label ?? ""))
    }
}
