import MPCutCore
import XCTest
@testable import MPCutApp

/// "Cut at Nearest Keyframe" moves a split. What each piece shows on the timeline has to move with it.
final class TierPromptNearestDisplayTests: XCTestCase {
    /// The badge of a sound-only timeline said that "the video at cut edges" is encoded.
    func testBadgeHelpOfASoundOnlyTimelineDoesNotMentionVideo() {
        let lossless = TierState.known(tier: .lossless, factors: [], container: "wav", warnings: [])
        XCTAssertEqual(TimelineTierBadge.help(lossless, soundOnly: true),
                       ExportRules.summary(tier: .lossless, source: .audio) + " Click for details.")
        XCTAssertFalse(TimelineTierBadge.help(lossless, soundOnly: true).localizedCaseInsensitiveContains("video"))
        XCTAssertEqual(TimelineTierBadge.help(lossless), ExportRules.summary(tier: .lossless, source: .movie) + " Click for details.")
    }

    /// A failed multicam check moves the inspector to the switch or edge it names, which rebuilds the export
    /// controls. They reopened on the preferred mode while the offers of the failed mode stayed on show.
    @MainActor
    func testMulticamOffersRememberTheModeTheyAreAbout() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        // A second camera: the same recording under another name.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("close.mp4")
        try FileManager.default.copyItem(at: url, to: other)
        let otherMedia = try CutEngine(useSidecar: false).inspectMulticamSource(other)
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media),
                                    .init(source: .init(id: "close", file: other.path), media: otherMedia)],
                           opening: "wide", audio: .none)
        func idle() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while model.isBusy || !model.sourceIndexProgress.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(model.isBusy)
        }
        try await idle()
        XCTAssertNil(model.unavailableExportMode)
        // A switch inside a picture group cannot be copied. Smart Trim writes it, so the failure has alternatives.
        XCTAssertTrue(model.edit {
            $0.switches = [.init(at: .zero, angle: "wide"), .init(at: RationalTime(numerator: 7, denominator: 25), angle: "close")]
        })
        let output = folder.appendingPathComponent("out.mp4")
        model.export(output: output, mode: .copy, tracks: .all, dryRun: true, wholeGroup: false)
        try await idle()
        XCTAssertFalse(model.exportAlternatives.isEmpty, model.notice?.message ?? "The export did not fail.")
        XCTAssertEqual(model.unavailableExportMode, .copy)
        // Changing a setting withdraws the offers, and with them the mode to reopen on.
        model.exportAlternatives = []
        XCTAssertNil(model.unavailableExportMode)
        // An export that plans leaves nothing to reopen on.
        XCTAssertTrue(model.edit { $0.switches = [.init(at: .zero, angle: "wide")] })
        model.export(output: output, mode: .copy, tracks: .video, dryRun: true, wholeGroup: true)
        try await idle()
        XCTAssertNil(model.unavailableExportMode, model.notice?.message ?? "")
    }

    @MainActor
    func testASeamlessSplitLeavesNoHandleBetweenThePieces() async throws {
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        var asked = 0
        model.tierPrompt = { _, answer in
            asked += 1
            answer(.init(answer: .nearest))
        }
        model.importFiles([movie])
        let deadline = ContinuousClock.now + .seconds(10)
        func settle() async throws {
            while model.isBusy || !model.tierIsCurrent, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()

        // Inside the first picture group, both pieces remain contiguous at the requested position.
        model.seek(5.0 / 25)
        model.split()
        try await settle()
        XCTAssertEqual(asked, 0)
        let clips = model.timelineClips
        XCTAssertEqual(clips.map(\.sourceStart), [0, 0.2])
        XCTAssertEqual(clips.map(\.sourceEnd), [0.2, 2])
        XCTAssertEqual(clips.map { $0.displayRange?.from.seconds }, [0, 0.2])
        XCTAssertEqual(clips.map { $0.displayRange?.to.seconds }, [0.2, 2])

        // Cutting directly on the keyframe also leaves adjoining ranges.
        model.undo()
        try await settle()
        model.seek(1)
        model.split()
        try await settle()
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(model.timelineClips.map { $0.displayRange?.from.seconds }, [0, 1])
        XCTAssertEqual(model.timelineClips.map { $0.displayRange?.to.seconds }, [1, 2])
    }
}
