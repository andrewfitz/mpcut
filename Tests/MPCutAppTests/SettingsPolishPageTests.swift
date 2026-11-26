import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// The polish pass's page findings: what Restore Defaults counts and says, the engine list, the storage locations and
/// broadcasts, the draft chooser, search order, and what VoiceOver reads.
@MainActor
final class SettingsPolishPageTests: XCTestCase {
    private typealias S = SettingsFix3Support
    private typealias A = SettingsFix4AccessibilityTests
    private typealias Key = EditorPreferences.Key

    // MARK: A5 D-8 and D-9. A value the page does not show never enables Restore Defaults alone

    func testATilesLayoutThisBuildCannotShowCountsAsTheOneItShows() {
        let preferences = EditorPreferences()
        preferences.tilesScanLayout = .evenGrid
        // Without TileTrail the factory Video Call shows as Even Grid too, so the page looks, and is, unchanged.
        XCTAssertEqual(preferences.hasFactoryValues(on: .media), !SettingsMediaPage.offered(.videoCall))
        XCTAssertEqual(SettingsMediaPage.shown(.videoCall), SettingsMediaPage.offered(.videoCall) ? .videoCall : .evenGrid)
    }

    func testAHiddenChosenFolderNeverEnablesRestoreDefaultsAlone() {
        let preferences = EditorPreferences()
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = "/Volumes/Exports"
        preferences.exportStartFolder = .automatic
        XCTAssertTrue(preferences.hasFactoryValues(on: .export), "Every row the page shows has its factory value")
        // With another row changed, the dialog still says the remembered folder goes, because Restore erases it.
        preferences.savesExportResult = true
        XCTAssertFalse(preferences.hasFactoryValues(on: .export))
        XCTAssertTrue(SettingsRestoreSummary.message(for: .export, preferences: preferences).contains("“Chosen folder”"))
        SettingsRestoreDefaults.restore(.export, preferences: preferences)
        XCTAssertEqual(preferences.exportStartFolderPath, "")
        // Shown, the chosen folder alone enables it.
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = "/Volumes/Exports"
        preferences.exportStartFolder = .chosen
        XCTAssertFalse(preferences.hasFactoryValues(on: .export))
    }

    // MARK: G5 6 and A5 N-w4. The Restore dialog reads in paragraphs and quotes row titles

    func testTheRestoreDialogHasAParagraphForEachTimeAndQuotesTitles() {
        let preferences = EditorPreferences()
        preferences.snapTarget = .silence
        preferences.largeThumbnails = true
        preferences.showsCutSections = false
        preferences.stillDuration = 3
        let editing = SettingsRestoreSummary.message(for: .editing, preferences: preferences)
        let paragraphs = editing.components(separatedBy: "\n\n")
        XCTAssertEqual(paragraphs.count, 3, editing)
        XCTAssertEqual(paragraphs.first, "At once, in open projects too:\n“Snap to” and “Enlarge thumbnails and waveforms”.")
        XCTAssertTrue(paragraphs.contains("The next time each is used, in open projects too:\n“Inserted still duration”.\nSheets and panels that are already open keep their choices."), editing)
        XCTAssertTrue(paragraphs.contains("In windows you open from now on:\n“Show cut sections in new windows”."), editing)
        XCTAssertFalse(editing.contains("launch argument"), "Nothing here came from the command line")
        XCTAssertEqual(SettingsRestoreSummary.listed(["A", "B and C", "D"]), "“A”, “B and C” and “D”")
        XCTAssertEqual(SettingsRestoreSummary.listed(["A"]), "“A”")
        XCTAssertEqual(SettingsRestoreSummary.listed([]), "")
    }

    func testTheRestoreDialogNamesKeptRowsByTheirTitles() {
        let preferences = EditorPreferences()
        preferences.recentFilesLimit = 20
        let general = SettingsRestoreSummary.message(for: .general, preferences: preferences)
        XCTAssertTrue(general.hasSuffix("“Maximum undo and redo steps” keeps its value."), general)
        preferences.draftRetentionDays = 7
        let storage = SettingsRestoreSummary.message(for: .storage, preferences: preferences)
        XCTAssertTrue(storage.contains("“Save new cutcaches” keeps its value."), storage)
        XCTAssertTrue(storage.contains("The next time MPCut opens:\n“Remove untitled drafts after”."), storage)
        XCTAssertNil(SettingsRestoreSummary.kept(on: .automation), "Automation has no Restore Defaults button")
        XCTAssertEqual(SettingsRestoreSummary.entries[Key.transcriptReaderTextSizePoints.rawValue]?.reach, .nextUse,
                       "Each transcript pane reads the size when it opens")
    }

    func testOnlyAValueFromTheCommandLineGetsTheLaunchSentence() throws {
        let name = "com.mpcut.tests.settings-polish-page." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        var launch = arguments
        launch[Key.recentFilesMaxCount.rawValue] = "20"
        launch[Key.draftRetentionDays.rawValue] = "3"
        defaults.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)
        let preferences = EditorPreferences(defaults: defaults, persistentDomain: name)
        XCTAssertEqual(preferences.recentFilesLimit, 20)
        let general = SettingsRestoreSummary.message(for: .general, preferences: preferences)
        XCTAssertTrue(general.hasSuffix("MPCut was opened from the command line with “Recent items” set, so that setting returns the next time MPCut opens that way."), general)
        // Draft retention never takes a launch argument, so its dialog has no such sentence.
        preferences.draftRetentionDays = 5
        XCTAssertFalse(SettingsRestoreSummary.message(for: .storage, preferences: preferences).contains("command line"))
        XCTAssertFalse(preferences.hasLaunchArgument(Key.draftRetentionDays.rawValue))
    }

    // MARK: A5 D-7. An alias of an offered engine is listed once

    private func catalog() throws -> TranscriptEngineCatalog {
        let data = try JSONSerialization.data(withJSONObject: ["engines": [
            ["name": "qwen3", "included": true, "default_model": "m", "minimum_macos": "14.0", "diarization": true],
            ["name": "parakeet-v3", "aliases": ["parakeet"], "included": true, "default_model": "m", "minimum_macos": "14.0",
             "diarization": false]]])
        return try TranscriptEngineCatalog.read(data)
    }

    func testASavedAliasSelectsItsEngineWithoutListingItTwice() throws {
        let choices = SettingsTranscriptsPage.engineChoices(preferred: "parakeet", catalog: try catalog())
        XCTAssertEqual(choices.map(\.label), ["Automatic", "Qwen3", "Parakeet v3"])
        XCTAssertEqual(choices.map(\.name), ["", "qwen3", "parakeet"], "The engine's entry carries the saved alias, which stays selected")
        let canonical = SettingsTranscriptsPage.engineChoices(preferred: "parakeet-v3", catalog: try catalog())
        XCTAssertEqual(canonical.map(\.name), ["", "qwen3", "parakeet-v3"])
        let unknown = SettingsTranscriptsPage.engineChoices(preferred: "whisper", catalog: try catalog())
        XCTAssertEqual(unknown.last?.label, "whisper (not offered)")
        XCTAssertEqual(SettingsTranscriptsPage.engineChoices(preferred: "", catalog: nil).count, 1, "Unchecked, only Automatic")
    }

    // MARK: A5 D-3. Showing Settings creates no store folder

    func testTheRecognitionStoreLocationIsFoundWithoutCreatingIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-polish-claims-\(UUID().uuidString)")
        let previous = getenv("MPCUT_TRANSCRIPT_CLAIMS_HOME").map { String(cString: $0) }
        setenv("MPCUT_TRANSCRIPT_CLAIMS_HOME", home.path, 1)
        defer {
            if let previous { setenv("MPCUT_TRANSCRIPT_CLAIMS_HOME", previous, 1) } else { unsetenv("MPCUT_TRANSCRIPT_CLAIMS_HOME") }
            try? FileManager.default.removeItem(at: home)
        }
        XCTAssertEqual(try TranscriptRecognitionStore.defaultLocation().path, home.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "Finding the location creates nothing")
        XCTAssertEqual(try TranscriptRecognitionStore.defaultDirectory().path, home.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path), "Using the store creates it")
    }

    // MARK: A5 D-4. Visiting the Storage page tells no editor the location changed

    func testVisitingTheStoragePagePostsNoChange() throws {
        try SidecarLocations.setMode(.project)
        defer { try? SidecarLocations.setMode(.media) }
        XCTAssertEqual(SidecarLocations.settingsSnapshot().mode, .project, "The page reads a location other than its placeholder")
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: .sidecarStorageDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let preferences = EditorPreferences()
        preferences.settingsPage = .storage
        let (window, _) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                  storageLocations: try S.temporaryLocations()), size: NSSize(width: 820, height: 1200))
        defer { window.close() }
        S.spin(1)
        XCTAssertEqual(posts, 0, "The first read of the location is no change")
        // Leaving and coming back builds the page anew; that is no change either.
        preferences.settingsPage = .general
        S.spin(0.3)
        preferences.settingsPage = .storage
        S.spin(1)
        XCTAssertEqual(posts, 0)
    }

    // MARK: G5 2. The draft chooser names drafts by what the editor recognizes

    func testDraftsAreListedByTheirFirstRecordingAndEditTime() {
        let clip = CutSequenceClip(id: "a", file: "Interview.mov", from: .zero, to: .init(numerator: 1))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let labels = ProjectSessions.draftLabels([(CutProject.sequence([clip]), date), (CutProject.sequence([]), date),
                                                  (nil, nil), (CutProject.sequence([clip]), date)])
        let edited = "last edited " + date.formatted(date: .abbreviated, time: .standard)
        XCTAssertEqual(labels, ["Interview.mov, \(edited) (1)", "Untitled project, \(edited)", "Untitled project, edit time unknown",
                                "Interview.mov, \(edited) (2)"])
        XCTAssertEqual(Set(labels).count, labels.count, "Every draft stays distinguishable")
        XCTAssertFalse(labels.joined().contains("…."))
    }

    // MARK: A5 N-s1, N-s2. Search follows page order and finds the words the pages use

    func testSearchListsRowsInPageOrderAndFindsTheirOptions() {
        XCTAssertEqual(SettingsRow.all.filter { $0.page == .general }.prefix(4).map(\.id),
                       [SettingsRow.multipleRecordings, .recentItems, .draftRecovery, .historyLimit].map(\.id))
        XCTAssertEqual(SettingsRow.all.filter { $0.page == .transcripts }.prefix(2).map(\.id),
                       [SettingsRow.transcriberrrStatus, .helperLocation].map(\.id))
        XCTAssertEqual(Set(SettingsRow.all.map(\.id)).count, SettingsRow.all.count)
        XCTAssertTrue(SettingsRow.all.allSatisfy { $0.id.hasPrefix("settings.") }, "One identifier scheme")
        for (query, row) in [("transcript job scratch", SettingsRow.storageUsage), ("gb", .cacheLimit), ("balanced", .reencodeQuality),
                             ("parakeet", .engine), ("grok", .localMCP), ("don’t ask again", .resetWarnings),
                             ("don't ask again", .resetWarnings), ("shared cache folder", .cutcacheLocation)] {
            XCTAssertTrue(SettingsRow.search(query).contains(row), "“\(query)” finds \(row.title)")
        }
    }

    // MARK: Accessibility. One label per control, one element per identifier

    /// Elements a client can act on or read, with their identifiers.
    private func identified(_ host: NSView) -> [A.Element] {
        S.accessibilityElements(of: host).filter { !$0.identifier.isEmpty && $0.role != "AXGroup" && $0.role != "AXScrollArea" }
    }

    func testEveryIdentifierNamesOneElementOnEveryPage() throws {
        let preferences = EditorPreferences()
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = FileManager.default.temporaryDirectory.path
        let locations = try S.temporaryLocations()
        for page in SettingsPage.allCases {
            preferences.settingsPage = page
            let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                         storageLocations: locations), size: NSSize(width: 900, height: 2400))
            S.spin(0.4)
            let elements = identified(host)
            XCTAssertFalse(elements.isEmpty, page.rawValue)
            let counts = Dictionary(grouping: elements, by: \.identifier)
            for (identifier, shared) in counts where shared.count > 1 {
                XCTFail("\(page.rawValue): \(identifier) names \(shared.count) elements: \(shared.map { "\($0.role) “\($0.label)”" })")
            }
            window.close()
        }
    }

    func testTheFiveDoublyTitledControlsKeepOneLabel() throws {
        let preferences = EditorPreferences()
        let locations = try S.temporaryLocations()
        let rows: [SettingsRow] = [.engine, .container, .cutcacheLocation, .reuseAnalysis, .localMCP]
        for row in rows {
            preferences.settingsPage = row.page
            let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                         storageLocations: locations), size: NSSize(width: 900, height: 2400))
            S.spin(0.4)
            let element = try XCTUnwrap(S.accessibilityElements(of: host).first { $0.identifier == row.id }, row.id)
            XCTAssertEqual(A.names(element), [row.title], "\(row.id) reads its title exactly once")
            window.close()
        }
    }

    func testRowButtonsDescribeThemselvesInSentenceCaseWithoutEmptyHints() throws {
        let preferences = EditorPreferences()
        preferences.settingsPage = .storage
        let (window, host) = S.window(SettingsWindow(preferences: preferences, cacheContext: { SidecarClearContext() },
                                                     storageLocations: try S.temporaryLocations()), size: NSSize(width: 900, height: 2400))
        defer { window.close() }
        S.spin(0.6)
        let elements = S.accessibilityElements(of: host)
        let show = try XCTUnwrap(elements.first { $0.identifier == "settings.storage.usage.generatedStills.show" })
        XCTAssertEqual(show.label, "Show generated stills in Finder")
        let clear = try XCTUnwrap(elements.first { $0.identifier == "settings.storage.usage.generatedStills.clear" })
        XCTAssertEqual(clear.label, "Clear generated stills")
        for element in elements {
            let hint = A.ask(element.object, "accessibilityHint") as? String
            XCTAssertNotEqual(hint, "", "\(element.identifier) has an empty hint")
        }
    }
}
