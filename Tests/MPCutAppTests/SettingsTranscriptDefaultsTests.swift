import AppKit
import Combine
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// Transcript, caption and Tiles starting values read from an isolated `EditorPreferences`.
@MainActor
final class SettingsTranscriptDefaultsTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "com.mpcut.tests.settings-transcript.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Factory values

    func testFactoryValuesReproduceTodaysSheets() {
        let preferences = EditorPreferences(defaults: nil)
        let defaults = TranscriptSheetDefaults(preferences: preferences)
        XCTAssertEqual(defaults, .factory)
        XCTAssertEqual(defaults.engine, "")
        XCTAssertFalse(defaults.identifiesSpeakers)
        XCTAssertFalse(defaults.downloadsModels)
        XCTAssertEqual(defaults.boundary, .nearestFrame)
        XCTAssertEqual(defaults.retainedPause, "0.20", "The tighten field always started at 0.20")
        XCTAssertEqual(defaults.fillerTerms, "")
        XCTAssertEqual(defaults.exportFormat, .json)
        XCTAssertEqual(defaults.captionLimits, .standard)
        XCTAssertEqual(defaults.captionLimits, TranscriptCaptionLimits(lineCharacters: 42, lines: 2,
                                                                       longestCue: .init(numerator: 6), speakerLabels: true))

        XCTAssertEqual(TranscriptEditorialForm.startingText(.takes, selected: "hello there", defaults: defaults), "hello there")
        XCTAssertEqual(TranscriptEditorialForm.startingText(.script, selected: "hello there", defaults: defaults), "")
        XCTAssertEqual(TranscriptEditorialForm.startingText(.suggestions, selected: "hello there", defaults: defaults), "")

        // Find Tiles started on Video Call, or a 2 × 2 grid without TileTrail, at Adaptive detail.
        XCTAssertEqual(TilesScanDefaults(preferences: preferences, isAvailable: true, supportsFeedLayouts: true).layout, .meeting)
        XCTAssertEqual(TilesScanDefaults(preferences: preferences, isAvailable: false, supportsFeedLayouts: false).layout,
                       .fixed(columns: 2, rows: 2))
        let scan = TilesScanDefaults(preferences: preferences)
        XCTAssertEqual([scan.columns, scan.rows], [2, 2])
        XCTAssertEqual(scan.detail, .adaptive)

        XCTAssertEqual(TilesDialogueDefaults(preferences: preferences), .factory)
        XCTAssertEqual(TilesDialogueDefaults.factory.minimumHold, "1")
        XCTAssertEqual(TilesDialogueDefaults.switchLaneHold(preferences), RationalTime(numerator: 1))
    }

    func testFactoryCaptionOutputIsUnchangedByteForByte() throws {
        let index = try Self.captionIndex()
        let limits = TranscriptSheetDefaults(preferences: EditorPreferences(defaults: nil)).captionLimits
        let desktop = try TranscriptCodec.encodeCaptions([index], space: .source, limits: limits)
        XCTAssertEqual(desktop, try TranscriptCodec.encodeCaptions([index], space: .source))
        XCTAssertEqual(String(decoding: desktop, as: UTF8.self), """
        1
        00:00:00,000 --> 00:00:05,000
        [Ada] word word word word word word word
        word word word


        """)
    }

    // MARK: Settings seed a fresh sheet

    func testSettingsSeedAFreshSheetAndChangeDesktopCaptions() throws {
        let preferences = EditorPreferences(defaults: try isolatedDefaults())
        preferences.fillerTerms = "um, uh, you know"
        preferences.boundaryPolicy = .copySafe
        preferences.retainedPause = 0.35
        preferences.transcriptExportFormat = .vtt
        preferences.downloadsModels = true
        preferences.identifiesSpeakers = true
        preferences.captionLineCharacters = 20
        preferences.captionLines = 3
        preferences.captionCueSeconds = 3
        preferences.captionSpeakerLabels = false
        preferences.tilesScanLayout = .evenGrid
        preferences.tilesScanColumns = 3
        preferences.tilesScanRows = 4
        preferences.tilesScanDetail = .sparse
        preferences.dialogueMinimumHold = 2.5
        preferences.dialogueOverlap = .visibleSpeaker
        preferences.dialogueOffscreen = .reaction

        let defaults = TranscriptSheetDefaults(preferences: preferences)
        XCTAssertEqual(defaults.fillerTerms, "um, uh, you know")
        XCTAssertEqual(TranscriptEditorialForm.startingText(.suggestions, selected: "", defaults: defaults), "um, uh, you know")
        XCTAssertEqual(defaults.boundary, .copySafe)
        XCTAssertEqual(defaults.retainedPause, "0.35")
        XCTAssertEqual(try RationalTime(parsing: defaults.retainedPause), RationalTime(numerator: 7, denominator: 20))
        XCTAssertEqual(defaults.exportFormat, .vtt)
        XCTAssertTrue(defaults.downloadsModels)
        XCTAssertEqual(defaults.captionLimits, TranscriptCaptionLimits(lineCharacters: 20, lines: 3,
                                                                       longestCue: .init(numerator: 3), speakerLabels: false))

        let output = try TranscriptCodec.encodeCaptions([Self.captionIndex()], space: .source, limits: defaults.captionLimits)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), """
        1
        00:00:00,000 --> 00:00:03,000
        word word word word
        word word

        2
        00:00:03,000 --> 00:00:05,000
        word word word word


        """)

        XCTAssertEqual(TilesScanDefaults(preferences: preferences, isAvailable: true, supportsFeedLayouts: true),
                       TilesScanDefaults(layout: .evenGrid, columns: 3, rows: 4, detail: .sparse))
        XCTAssertEqual(TilesScanDefaults(preferences: preferences).layout, .fixed(columns: 3, rows: 4))
        XCTAssertEqual(TilesScanDefaults(layout: .cameraMultiview, isAvailable: true, supportsFeedLayouts: false).layout, .meeting)
        XCTAssertEqual(TilesScanDefaults(layout: .cameraMultiview, isAvailable: false, supportsFeedLayouts: false).layout,
                       .fixed(columns: 2, rows: 2))
        let dialogue = TilesDialogueDefaults(preferences: preferences)
        XCTAssertEqual(dialogue.minimumHold, "2.5")
        XCTAssertEqual(dialogue.overlap, .visibleSpeaker)
        XCTAssertEqual(dialogue.offscreen, .reaction)
        XCTAssertEqual(TilesDialogueDefaults.switchLaneHold(preferences), RationalTime(numerator: 5, denominator: 2))
        preferences.dialogueMinimumHold = 0
        XCTAssertEqual(TilesDialogueDefaults.switchLaneHold(preferences), RationalTime(numerator: 1),
                       "The lane needs a positive hold, so zero keeps core's second")
    }

    func testOpeningSheetsReadsSettingsAndWritesNothing() throws {
        _ = NSApplication.shared
        let store = try isolatedDefaults()
        let preferences = EditorPreferences(defaults: store)
        preferences.fillerTerms = "like"
        preferences.boundaryPolicy = .exact
        preferences.downloadsModels = true
        let before = store.dictionaryRepresentation().filter { $0.key.hasPrefix("transcript_") }.mapValues { "\($0)" }
        var changes: [EditorPreferences.Change] = []
        let observation = preferences.observeChanges { changes.append($0) }
        defer { observation.cancel() }

        let defaults = TranscriptSheetDefaults(preferences: preferences)
        let views: [AnyView] = [
            AnyView(TranscriptEditOptionsForm(action: .tighten, queueName: "", defaults: defaults) { _, _, _, _, _, _, _, _, _, _ in }),
            AnyView(TranscriptExportForm(space: .currentCut, isMulticam: false, captions: false, tracks: [], privacyWarning: nil,
                                         defaultFormat: defaults.exportFormat) { _, _, _ in }),
            AnyView(TranscriptRetryForm(message: nil, downloadsModels: defaults.downloadsModels) { _ in }),
            AnyView(TranscriptAuthoredForm(records: [], attachmentLabels: [:], defaults: defaults) { _, _, _ in })
        ]
        for view in views {
            let host = NSHostingView(rootView: view.frame(width: 400, height: 300))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.close()
        }
        // A sheet's override is its own copy.
        var override = defaults
        override.fillerTerms = "so"
        override.boundary = .nearestFrame
        XCTAssertEqual(preferences.fillerTerms, "like")
        XCTAssertEqual(preferences.boundaryPolicy, .exact)
        XCTAssertTrue(changes.isEmpty, "Opening a sheet never writes a default: \(changes)")
        XCTAssertEqual(store.dictionaryRepresentation().filter { $0.key.hasPrefix("transcript_") }.mapValues { "\($0)" }, before)
    }

    // MARK: Engines

    private static func catalog(_ engines: [[String: Any]]) throws -> TranscriptEngineCatalog {
        let full = engines.map { engine in
            ["included": true, "default_model": "m", "minimum_macos": "14.0", "diarization": false].merging(engine) { $1 }
        }
        return try TranscriptEngineCatalog.read(JSONSerialization.data(withJSONObject: ["version": "9", "engines": full]))
    }

    func testAutomaticAlwaysResolvesToANamedEngine() throws {
        let both = try Self.catalog([["name": "parakeet-v3"], ["name": "qwen3", "diarization": true]])
        XCTAssertEqual(both.resolve(preferred: ""), .init(engine: "qwen3", issue: nil), "Qwen3 first")
        XCTAssertEqual(both.resolve(preferred: "parakeet-v3"), .init(engine: "parakeet-v3", issue: nil))

        let noQwen = try Self.catalog([["name": "qwen3", "included": false], ["name": "apple-native"], ["name": "parakeet-v3"]])
        XCTAssertEqual(noQwen.resolve(preferred: "").engine, "apple-native", "Then the first available engine")

        let aliased = try Self.catalog([["name": "parakeet-v3", "aliases": ["parakeet"]]])
        XCTAssertEqual(aliased.resolve(preferred: "parakeet").engine, "parakeet-v3")

        let none = try Self.catalog([["name": "qwen3", "helper_present": false]])
        XCTAssertNil(none.resolve(preferred: "").engine)
        XCTAssertNil(none.automatic)
    }

    func testAMissingEngineShowsItsReasonAndKeepsThePreference() throws {
        let preferences = EditorPreferences(defaults: try isolatedDefaults())
        preferences.transcriptEngine = "whisper-x"
        let catalog = try Self.catalog([
            ["name": "qwen3", "diarization": true], ["name": "future", "minimum_macos": "99.0"],
            ["name": "parakeet-v3", "helper_present": false], ["name": "apple-native", "included": false]
        ])
        let missing = catalog.resolve(preferred: preferences.transcriptEngine)
        XCTAssertEqual(missing.engine, "qwen3")
        XCTAssertEqual(missing.issue, "The installed Transcriberrr does not offer ‘whisper-x’.")
        XCTAssertEqual(preferences.transcriptEngine, "whisper-x")
        XCTAssertEqual(TranscriptSheetDefaults(preferences: preferences).engine, "whisper-x")

        XCTAssertEqual(catalog.unavailableReason(forPreferred: "future"), "future requires macOS 99.0 or later.")
        XCTAssertEqual(catalog.unavailableReason(forPreferred: "parakeet-v3"), "Parakeet v3 is not installed in Transcriberrr.")
        XCTAssertEqual(catalog.unavailableReason(forPreferred: "apple-native"), "This Transcriberrr does not include Apple Speech.")
        XCTAssertNil(catalog.unavailableReason(forPreferred: ""))
        XCTAssertEqual(catalog.resolve(preferred: "future").engine, "qwen3")

        let choices = SettingsTranscriptsPage.engineChoices(preferred: "whisper-x", catalog: catalog)
        XCTAssertEqual(choices.first, .init(name: "", label: "Automatic", selectable: true))
        XCTAssertEqual(choices.last, .init(name: "whisper-x", label: "whisper-x (not offered)", selectable: true))
        XCTAssertEqual(choices.first { $0.name == "future" }?.selectable, false)
        XCTAssertEqual(SettingsTranscriptsPage.engineChoices(preferred: "future", catalog: catalog)
            .first { $0.name == "future" }?.selectable, true, "The saved engine stays selected")
        XCTAssertEqual(SettingsTranscriptsPage.engineChoices(preferred: "whisper-x", catalog: nil).map(\.name), ["", "whisper-x"])
    }

    func testIdentifySpeakersFollowsSettingsWhereTheEngineSupportsIt() throws {
        let catalog = try Self.catalog([["name": "qwen3", "diarization": true], ["name": "parakeet-v3"]])
        var defaults = TranscriptSheetDefaults.factory
        XCTAssertFalse(TranscriptJobSetup.seededSpeakers(defaults, engine: catalog.engine(named: "qwen3")))
        defaults.identifiesSpeakers = true
        XCTAssertTrue(TranscriptJobSetup.seededSpeakers(defaults, engine: catalog.engine(named: "qwen3")))
        XCTAssertFalse(TranscriptJobSetup.seededSpeakers(defaults, engine: catalog.engine(named: "parakeet-v3")))
        XCTAssertFalse(TranscriptJobSetup.seededSpeakers(defaults, engine: nil))
    }

    func testTranscriberrrStatusAsksOnlyWhenToldAndReportsEngines() async throws {
        XCTAssertFalse(TranscriberrrStatus.checksAutomatically, "The test host never queries a helper on its own")
        let data = try JSONSerialization.data(withJSONObject: ["version": "2.1", "engines": [
            ["name": "qwen3", "included": true, "default_model": "m", "minimum_macos": "14.0", "diarization": true],
            ["name": "future", "included": true, "default_model": "m", "minimum_macos": "99.0", "diarization": false]
        ]])
        var located: [String] = []
        let status = TranscriberrrStatus(locate: { path in
            located.append(path)
            return URL(fileURLWithPath: "/nonexistent/Transcriberrr.app/Contents/Helpers/transcriberrr")
        }, probe: { _ in data })
        XCTAssertEqual(status.state, .unchecked)
        XCTAssertEqual(SettingsTranscriptsPage.statusText(status.state), "Not checked")
        status.check(helperPath: "/chosen/helper")
        await status.waitForCheck()
        XCTAssertEqual(located, ["/chosen/helper"])
        XCTAssertEqual(status.catalog?.engines.map(\.name), ["qwen3", "future"])
        XCTAssertEqual(SettingsTranscriptsPage.statusText(status.state), "Version 2.1. Engines: Qwen3, future (unavailable).")

        let failing = TranscriberrrStatus(locate: { _ in throw CutError(code: "transcript_helper_unavailable", message: "Install it.") },
                                          probe: { _ in XCTFail("No helper to ask"); return Data() })
        failing.check(helperPath: "")
        XCTAssertEqual(failing.state, .failed("Install it."))
        XCTAssertNil(failing.catalog)
    }

    // MARK: Helper location

    func testChosenHelperReachesDesktopLookupAndTheEnvironmentStillWins() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsTranscriptHelper-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func executable(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let chosen = try executable("chosen-helper")
        let environment = try executable("environment-helper")
        let previous = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIBERRR_HELPER"]
        unsetenv("MPCUT_TRANSCRIBERRR_HELPER")
        defer {
            if let previous { setenv("MPCUT_TRANSCRIBERRR_HELPER", previous, 1) } else { unsetenv("MPCUT_TRANSCRIBERRR_HELPER") }
        }
        XCTAssertEqual(try TranscriptJobStore.helperURL(chosen: chosen.path), chosen)
        XCTAssertThrowsError(try TranscriptJobStore.helperURL(chosen: folder.appendingPathComponent("missing").path)) { error in
            XCTAssertEqual((error as? CutError)?.code, "transcript_helper_unavailable")
            XCTAssertTrue((error as? CutError)?.message.contains("Settings") == true)
        }
        setenv("MPCUT_TRANSCRIBERRR_HELPER", environment.path, 1)
        XCTAssertEqual(try TranscriptJobStore.helperURL(chosen: chosen.path), environment)
        XCTAssertEqual(try TranscriptJobStore.helperURL(), environment)
    }

    // MARK: Starting folder

    func testExcerptSavePanelFollowsTheStartingFolderRule() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsTranscriptFolder-\(UUID())")
        let chosen = folder.appendingPathComponent("Chosen", isDirectory: true)
        let media = folder.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let location = folder.appendingPathComponent("Interview.cut")
        let project = CutProject.sequence([.init(id: "quote", file: media.appendingPathComponent("take.mov").path,
                                                 from: .zero, to: .init(numerator: 1))])
        let excerpt = TranscriptQueueExcerpt(name: "Quote", project: project, location: location)
        let preferences = EditorPreferences(defaults: nil)
        let automatic = location.resolvingSymlinksInPath().deletingLastPathComponent()
        XCTAssertEqual(excerpt.startDirectory(preferences: nil), automatic)
        XCTAssertEqual(excerpt.startDirectory(preferences: preferences), automatic)
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = chosen.path
        XCTAssertEqual(excerpt.startDirectory(preferences: preferences)?.standardizedFileURL.path, chosen.standardizedFileURL.path)
        preferences.exportStartFolderPath = folder.appendingPathComponent("Offline").path
        XCTAssertEqual(excerpt.startDirectory(preferences: preferences), automatic, "An offline folder falls back to Automatic")
        preferences.exportStartFolder = .source
        XCTAssertEqual(excerpt.startDirectory(preferences: preferences)?.standardizedFileURL.path, media.standardizedFileURL.path)
    }

    // MARK: Fixtures

    static func captionIndex() throws -> TranscriptIndex {
        let words = (0..<10).map { i in
            TranscriptWord(id: "w\(i)", text: " word", start: .init(numerator: Int64(i), denominator: 2),
                           end: .init(numerator: Int64(i + 1), denominator: 2), utteranceID: "u", speakerID: "ada")
        }
        return try TranscriptIndex(document: .init(clock: .presentation, speakers: [.init(id: "ada", name: "Ada")], words: words))
    }
}
