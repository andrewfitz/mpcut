import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// Restore Defaults names what changes from the factory table that performs it, and Automation, which has nothing to
/// restore, shows no button. Also the MCP integer step and the Storage page's Clear result and store paths.
@MainActor
final class SettingsFix3RestoreTests: XCTestCase {
    private typealias S = SettingsFix3Support

    func testEveryRestorableKeyIsNamedAndNothingElse() {
        let keys = Set(EditorPreferences.factories.map(\.key))
        XCTAssertEqual(Set(SettingsRestoreSummary.entries.keys), keys)
        XCTAssertEqual(keys.count, EditorPreferences.factories.count)
        for entry in SettingsRestoreSummary.entries.values {
            XCTAssertFalse(entry.name.contains(","), "A name reads as one item in a comma-separated list: \(entry.name)")
        }
    }

    func testTheDialogNamesWhatChangesAndWhereFromTheFactoryTable() {
        let preferences = EditorPreferences()
        XCTAssertTrue(SettingsRestoreSummary.message(for: .general, preferences: preferences).contains("already has its factory value"))

        preferences.recentFilesLimit = 20
        preferences.offersDraftRecovery = true
        preferences.historyLimit = 10
        let general = SettingsRestoreSummary.message(for: .general, preferences: preferences)
        XCTAssertTrue(general.contains("At once, in open projects too:\n“Recent items”."), general)
        XCTAssertTrue(general.contains("The next time MPCut opens:\n“Offer to recover untitled projects at launch”."), general)
        XCTAssertTrue(general.hasSuffix("“Maximum undo and redo steps” keeps its value."), general)
        XCTAssertFalse(general.contains("Warn when"), "A value already at its factory value is not named")
        XCTAssertFalse(general.contains("launch argument"), "Nothing came from the command line")

        preferences.snapTarget = .silence
        preferences.stillDuration = 3
        preferences.showsCutSections = false
        let editing = SettingsRestoreSummary.message(for: .editing, preferences: preferences)
        XCTAssertTrue(editing.contains("At once, in open projects too:\n“Snap to”."), editing)
        XCTAssertTrue(editing.contains("The next time each is used, in open projects too:\n“Inserted still duration”."), editing)
        XCTAssertTrue(editing.contains("In windows you open from now on:\n“Show cut sections in new windows”."), editing)

        // After restoring, the dialog's names are exactly what changed back.
        SettingsRestoreDefaults.restore(.general, preferences: preferences)
        XCTAssertEqual(preferences.recentFilesLimit, 10)
        XCTAssertEqual(preferences.historyLimit, 10, "The undo limit is kept, as the dialog says")
        XCTAssertTrue(SettingsRestoreSummary.message(for: .general, preferences: preferences).contains("already has its factory value"))
    }

    func testOnlyPagesWithSomethingToRestoreHaveTheButton() {
        // `SettingsForm` adds the button only for a restorable page. SwiftUI's buttons are not AppKit views, so this
        // host checks the rule, not the drawn button.
        XCTAssertFalse(SettingsRestoreSummary.isRestorable(.automation))
        XCTAssertEqual(Set(SettingsPage.allCases.filter(SettingsRestoreSummary.isRestorable)),
                       Set(EditorPreferences.factories.map(\.page)))
        XCTAssertEqual(SettingsRestoreSummary.title(for: .general), "Restore General settings to their defaults?")
    }

    func testTheSchemaRefusesAnOddPixelCountNamingTheStep() throws {
        let schemas = try MCPSchemas.loaded.get()
        XCTAssertNoThrow(try schemas.validate(tool: "preferences_set", arguments: [
            "operation_id": UUID().uuidString, "key": "still_timeline_default_width_pixels", "value": 1920]))
        XCTAssertThrowsError(try schemas.validate(tool: "preferences_set", arguments: [
            "operation_id": UUID().uuidString, "key": "still_timeline_default_height_pixels", "value": 1081])) { error in
            XCTAssertTrue((error as? MCPFailure)?.message.contains("multiple of 2") == true, "\(error)")
        }
    }

    // MARK: Storage

    func testTheClearResultSaysWhenNothingWasRemovedAndWhatWasLeft() async throws {
        let locations = try S.temporaryLocations()
        let stills = try XCTUnwrap(locations.generatedStills)
        let shard = stills.appendingPathComponent("7", isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        // A file MPCut did not write, the case the tester saw.
        try Data(repeating: 1, count: 5_000).write(to: shard.appendingPathComponent("notes.txt"))
        let model = StorageUsageModel(preferences: EditorPreferences(), locations: locations)
        await model.refresh()
        XCTAssertGreaterThan(model.sizes[.generatedStills] ?? 0, 0, "The size counts everything in the folder")

        let cleared = await model.clear(.generatedStills)
        let result = try XCTUnwrap(cleared)
        XCTAssertEqual(result.reclaimedBytes, 0)
        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.left.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shard.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(StorageUsageSection.title(report), "Nothing removed from generated stills")
        let summary = StorageUsageSection.summary(report.result, left: report.left)
        XCTAssertFalse(summary.contains("Nothing"), "The title says nothing was removed; the message does not repeat it: \(summary)")
        XCTAssertTrue(summary.hasPrefix("Left 1 item ("), summary)
        XCTAssertTrue(summary.contains("Left 1 item ("), summary)
        XCTAssertTrue(summary.contains("that MPCut does not recognize as its own"), summary)
        XCTAssertFalse(summary.contains("Zero"), summary)

        // An MPCut entry is removed and reported; entries in use are counted with their reason.
        let entry = shard.appendingPathComponent(String(repeating: "a", count: 64) + "-mov", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 9_000).write(to: entry.appendingPathComponent("segment.mov"))
        let clearedAgain = await model.clear(.generatedStills)
        let second = try XCTUnwrap(clearedAgain)
        XCTAssertEqual(second.removed.count, 1)
        let report2 = try XCTUnwrap(model.report)
        XCTAssertEqual(StorageUsageSection.title(report2), "Cleared generated stills")
        XCTAssertTrue(StorageUsageSection.summary(report2.result, left: report2.left).hasPrefix("Reclaimed "))

        // A shard a render holds is skipped whole and named as in use.
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let held = open(shard.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        let busy = await StorageInventory.clear(.generatedStills, locations: locations, defaults: nil)
        XCTAssertEqual(busy.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
        let left = StoreLeftovers.find(in: [stills], after: busy)
        XCTAssertEqual(left.count, 0, "Files in a skipped shard count as in use, not as foreign")
        let skipped = StorageUsageSection.summary(busy, left: left)
        XCTAssertTrue(skipped.hasPrefix("Left 1 item in use or still needed:"), skipped)
        XCTAssertEqual(StorageUsageSection.size(0), "0 KB")
    }

    func testClearingTheRecognitionStoreLeavesNothingItCallsForeign() async throws {
        let locations = try S.temporaryLocations()
        let claims = try XCTUnwrap(locations.transcriptRecognition)
        let files = FileManager.default
        try files.createDirectory(at: claims, withIntermediateDirectories: true)
        let digest = String(repeating: "ab", count: 32)
        try Data().write(to: claims.appendingPathComponent(digest))
        try Data(repeating: 3, count: 4_000).write(to: claims.appendingPathComponent(digest + ".mpx"))
        let archive = claims.appendingPathComponent("Results/" + String(repeating: "cd", count: 32), isDirectory: true)
        try files.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 4_000).write(to: archive.appendingPathComponent("result.json"))

        let model = StorageUsageModel(preferences: EditorPreferences(), locations: locations)
        await model.refresh()
        let cleared = await model.clear(.transcriptRecognition)
        let result = try XCTUnwrap(cleared)
        XCTAssertGreaterThan(result.reclaimedBytes, 0)
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.left, StoreLeftovers(), "MPCut's own files are never reported as foreign")
        XCTAssertEqual(StorageUsageSection.title(report), "Cleared transcript recognition results")
        XCTAssertFalse(StorageUsageSection.summary(report.result, left: report.left).contains("does not recognize"))
    }

    func testStorePathsAreAbbreviatedWithATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Caches/MPCut/GeneratedStills-v1")
        XCTAssertEqual(SettingsPath.display(url.path), "~/Library/Caches/MPCut/GeneratedStills-v1")
        XCTAssertEqual(SettingsPath.display("/Volumes/Cache"), "/Volumes/Cache")
    }

    func testTheHelperPanelStartsSomewhereSensible() {
        XCTAssertEqual(SettingsTranscriptsPage.helperPanelFolder(chosen: "/opt/tools/transcriberrr", installedApp: nil).path, "/opt/tools")
        XCTAssertEqual(SettingsTranscriptsPage.helperPanelFolder(chosen: "", installedApp: nil).path, "/Applications")
        XCTAssertEqual(SettingsTranscriptsPage.helperPanelFolder(chosen: "", installedApp: URL(fileURLWithPath: "/Applications/T.app")).path,
                       "/Applications/T.app/Contents/Helpers")
    }
}
