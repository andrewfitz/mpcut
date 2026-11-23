import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// The tier badge follows the timeline, and an edit made by hand asks before lowering it.
final class TimelineTierGateTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    @MainActor
    private func settle(_ model: EditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isBusy || !model.tierIsCurrent, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
    }

    /// An editor on one fixture whose prompt is answered by `answer` and recorded.
    @MainActor
    private final class Asked {
        var prompts: [TierPrompt] = []
        var answer = TierPrompt.Choice(answer: .proceed)
    }

    @MainActor
    private func editor(_ name: String, _ ext: String) async throws -> (model: EditorModel, asked: Asked) {
        let model = EditorModel()
        let asked = Asked()
        model.tierPrompt = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        model.importFiles([try fixture(name, ext)])
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        return (model, asked)
    }

    private let insideGOP = 7.0 / 25

    func testAudioMovementUsesExactTimeAndReportsKeptMaterial() {
        let movement = TierPrompt.CutMovement(label: "Clip 1 In", requested: .init(numerator: 3, denominator: 48000),
                                              resolved: .init(numerator: 1, denominator: 48000), edge: .start, exactTime: true)
        XCTAssertEqual(movement.text, "Clip 1 In: 1/16000 s → 1/48000 s (1/24000 s earlier, keeps more material)")
    }

    /// Splitting keeps the packets continuous. Deleting the head exposes a real cut.
    @MainActor
    private func splitBeforeExposingCut(_ model: EditorModel) async throws -> UUID {
        model.seek(18.0 / 25)
        model.split()
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        return try XCTUnwrap(model.timelineClips.first?.id)
    }

    @MainActor
    func testBadgeFollowsTheTimelineAndOnlyLoweringByHandAsks() async throws {
        let (model, asked) = try await editor("SmartTrim-GOP", "mp4")
        defer { model.endSession() }
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        XCTAssertEqual(model.tierState?.name, "True Lossless")
        XCTAssertTrue(asked.prompts.isEmpty, "Opening media never asks.")

        // A split on a keyframe keeps the tier and does not ask.
        model.seek(1)
        model.split()
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        XCTAssertTrue(asked.prompts.isEmpty)
        model.undo()
        try await settle(model)

        // Exposing a cut inside a picture group lowers it and asks once.
        let head = try await splitBeforeExposingCut(model)
        model.byHand { model.deleteClip(head) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.from, .trueLossless)
        XCTAssertEqual(prompt.to.tier, .lossless)
        XCTAssertEqual(prompt.buttons.map(\.title), ["Cut at Nearest Keyframe", "Cut Here", "Cancel"])
        XCTAssertEqual(prompt.title, "Keep the cut here?")
        XCTAssertTrue(prompt.message.contains("Smart Trim") && prompt.message.contains("True Lossless"), prompt.message)
        XCTAssertEqual(prompt.movements, [.init(label: "Clip 1 In", requested: .init(numerator: 18, denominator: 25),
                                                resolved: .init(numerator: 1), frameCount: 7, edge: .start)])
        XCTAssertTrue(prompt.message.contains("00:00.720 → 00:01.000 (280 ms later, 7 frames, removes material)"), prompt.message)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.tierState?.tier, .lossless)
        XCTAssertEqual(Set(model.tierState?.factors.map(\.id) ?? []), [.cutVideoStart])

        // Undo raises it and redo lowers it again. Neither asks.
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        model.redo()
        try await settle(model)
        XCTAssertEqual(model.tierState?.tier, .lossless)
        XCTAssertEqual(asked.prompts.count, 1)

        // Removing the cut by hand raises the tier without a question.
        let right = try XCTUnwrap(model.timelineClips.first?.id)
        _ = model.trim(right, edge: .start, sourceTime: 0, commit: true)
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        XCTAssertEqual(asked.prompts.count, 1)

        // The same lowering edit made remotely, without `byHand`, never asks.
        let remoteHead = try await splitBeforeExposingCut(model)
        model.deleteClip(remoteHead)
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.tierState?.tier, .lossless)
        XCTAssertEqual(asked.prompts.count, 1)

        model.endSession()
        XCTAssertNil(model.tierState, "An empty editor has no badge.")
    }

    @MainActor
    func testDecliningLeavesTheTimelineAndHistoryUnchanged() async throws {
        let (model, asked) = try await editor("SmartTrim-GOP", "mp4")
        defer { model.endSession() }
        asked.answer = .init(answer: .cancel)
        let head = try await splitBeforeExposingCut(model)
        let clips = model.sequenceClips, actions = model.historyActions, cursor = model.historyCursor
        model.byHand { model.deleteClip(head) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(model.sequenceClips, clips)
        XCTAssertEqual(model.historyActions, actions)
        XCTAssertEqual(model.historyCursor, cursor)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        XCTAssertNil(model.alert)
        XCTAssertTrue(model.preferences.warnBeforeLoweringExportTier)
    }

    @MainActor
    func testNearestKeyframeAppliesTheSnappedCut() async throws {
        let (model, asked) = try await editor("SmartTrim-GOP", "mp4")
        defer { model.endSession() }
        asked.answer = .init(answer: .nearest)
        let head = try await splitBeforeExposingCut(model)
        model.byHand { model.deleteClip(head) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertNotNil(asked.prompts.first?.nearest)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.timelineClips.map(\.sourceStart), [1])
        XCTAssertEqual(model.timelineClips.map(\.sourceEnd), [2])
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        XCTAssertEqual(model.historyActions.last, "Delete Clip")
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
    }

    @MainActor
    func testThePreferenceTurnsTheQuestionOff() async throws {
        let (model, asked) = try await editor("SmartTrim-GOP", "mp4")
        defer { model.endSession() }
        // "Don't ask again" on an accepted edit stores the preference.
        asked.answer = .init(answer: .proceed, dontAskAgain: true)
        let head = try await splitBeforeExposingCut(model)
        model.byHand { model.deleteClip(head) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertFalse(model.preferences.warnBeforeLoweringExportTier)
        XCTAssertEqual(model.timelineClips.count, 1)
        model.undo()
        try await settle(model)
        // With it off the same edit is applied without a question, and the badge still changes.
        model.byHand { model.deleteClip(head) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.tierState?.tier, .lossless)

        let suite = "mpcut.tier.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(EditorPreferences(defaults: defaults).warnBeforeLoweringExportTier, "The question is on by default.")
        EditorPreferences(defaults: defaults).warnBeforeLoweringExportTier = false
        XCTAssertFalse(EditorPreferences(defaults: defaults).warnBeforeLoweringExportTier)
    }

    @MainActor
    func testOpeningAProjectNeverAsks() async throws {
        let file = try fixture("SmartTrim-GOP", "mp4")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        let model = EditorModel(preferences: EditorPreferences())
        defer { model.endSession() }
        var prompts = 0
        model.tierPrompt = { _, answer in prompts += 1; answer(.init(answer: .cancel)) }
        let clips = [CutSequenceClip(id: "a", file: file.path, from: RationalTime(numerator: 7, denominator: 25), to: RationalTime(numerator: 1)),
                     CutSequenceClip(id: "b", file: file.path, from: RationalTime(numerator: 31, denominator: 25), to: RationalTime(numerator: 2))]
        try model.openProject(clips, at: url)
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.tierState?.tier, .lossless)
        XCTAssertEqual(prompts, 0)
    }

    @MainActor
    func testAddingClipsThatLowerTheTierAsksOnceAndDecliningRestoresTheTimeline() async throws {
        // Opus needs its decoder history, so a second clip leaves only a re-encode.
        let (model, asked) = try await editor("WebM-Opus-GOP", "webm")
        defer { model.endSession() }
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        asked.answer = .init(answer: .cancel)
        let actions = model.historyActions, cursor = model.historyCursor
        model.importFiles([try fixture("WebM-Opus-GOP", "webm"), try fixture("WebM-Opus-GOP", "webm")])
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1, "One question for the whole import.")
        XCTAssertEqual(asked.prompts.first?.buttons.map(\.title), ["Continue", "Cancel"])
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.historyActions, actions)
        XCTAssertEqual(model.historyCursor, cursor)
        XCTAssertEqual(model.tierState?.tier, .trueLossless)

        asked.answer = .init(answer: .proceed)
        model.importFiles([try fixture("WebM-Opus-GOP", "webm")])
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 2)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.tierState?.tier, .reencode)

        // A remote import supplies `allowCommit` and is not asked about.
        model.importFiles([try fixture("WebM-Opus-GOP", "webm")], allowCommit: { true })
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 3)
        XCTAssertEqual(asked.prompts.count, 2)
    }

    /// Moving the cut to its nearest exact point must still be the edit. For a deleted head the nearest exact timeline
    /// is the one before the deletion, so no such button is offered.
    @MainActor
    func testNearestIsNotOfferedWhenItWouldUndoTheEdit() async throws {
        let (model, asked) = try await editor("WebM-Opus-GOP", "webm")
        defer { model.endSession() }
        model.seek(0.2)
        model.split()
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertTrue(asked.prompts.isEmpty, "A split of a WebM is written as one range and stays exact.")
        asked.answer = .init(answer: .cancel)
        let head = try XCTUnwrap(model.timelineClips.first?.id)
        model.byHand { model.deleteClip(head) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertNil(asked.prompts.first?.nearest)
        XCTAssertEqual(asked.prompts.first?.buttons.map(\.title), ["Continue", "Cancel"])
        XCTAssertEqual(asked.prompts.first?.to.tier, .reencode)
        XCTAssertEqual(model.timelineClips.count, 2, "Declined.")
        asked.answer = .init(answer: .proceed)
        model.byHand { model.deleteClip(head) }
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.tierState?.tier, .reencode)
    }

    @MainActor
    func testShortenPausesAsksOnceForTheWholeOperation() async throws {
        let (model, asked) = try await editor("Scrub-Tone", "webm")
        defer { model.endSession() }
        let before = try XCTUnwrap(model.tierState?.tier)
        model.minimumPause = 0.1
        model.manualThresholdDB = 0
        model.scanForSilence()
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertFalse(model.pausePlan.isEmpty)
        let original = model.duration

        // Declined: nothing is shortened.
        asked.answer = .init(answer: .cancel)
        model.byHand { _ = model.applyPauses(queueTakes: false) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(asked.prompts.first?.action, "Shorten Pauses")
        XCTAssertEqual(model.duration, original)
        XCTAssertEqual(model.timelineClips.count, 1)

        // Accepted: one question, however many pauses are cut.
        asked.answer = .init(answer: .proceed)
        model.byHand { _ = model.applyPauses(queueTakes: false) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 2)
        XCTAssertLessThan(model.duration, original)
        XCTAssertLessThan(try XCTUnwrap(model.tierState?.tier ?? .reencode), before)
    }

    @MainActor
    func testExportOpensOnTheModeOfTheTier() async throws {
        // True Lossless: the preference stands.
        let (model, _) = try await editor("SmartTrim-GOP", "mp4")
        defer { model.endSession() }
        for preferred in [ExportMode.smart, .copy, .encode] {
            model.defaultExportMode = preferred
            XCTAssertEqual(model.openingExportMode(), preferred, "\(preferred)")
        }
        // Lossless: exposing the cut needs Smart Trim.
        let head = try await splitBeforeExposingCut(model)
        model.deleteClip(head)
        try await settle(model)
        XCTAssertEqual(model.settledTier, .lossless)
        let expected: [ExportMode: ExportMode] = [.smart: .smart, .copy: .smart, .encode: .encode]
        for (preferred, opened) in expected {
            model.defaultExportMode = preferred
            XCTAssertEqual(model.openingExportMode(), opened, "\(preferred)")
            XCTAssertEqual(model.openingExportMode(selectionOnly: true), preferred, "A selection is not the timeline.")
            XCTAssertEqual(model.openingExportMode(.copy), .copy, "A mode asked for by name is kept.")
        }

        // Re-encode: this picture format has no Smart Trim, so a cut inside a picture group leaves a full encode.
        let (webm, _) = try await editor("WebM-Opus-GOP", "webm")
        defer { webm.endSession() }
        // A split alone keeps a WebM exact, because its joined ranges are written as one. Removing the head leaves the cut.
        webm.seek(0.2)
        webm.split()
        try await settle(webm)
        XCTAssertEqual(webm.settledTier, .trueLossless)
        webm.deleteClip(try XCTUnwrap(webm.timelineClips.first?.id))
        try await settle(webm)
        XCTAssertEqual(webm.settledTier, .reencode)
        XCTAssertEqual(webm.tierState?.name, ExportRules.displayName(mode: .encode))
        for preferred in [ExportMode.smart, .copy, .encode] {
            webm.defaultExportMode = preferred
            XCTAssertEqual(webm.openingExportMode(), .encode, "\(preferred)")
        }
        // The planner agrees with what the sheet would open on.
        let request = try webm.mcpExportInput(selection: false)
        if case .ready = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: request.clips, mode: .smart), media: request.media) {
            XCTFail("Smart Trim plans for a timeline whose tier is Re-encode.")
        }
    }

    /// Replace Source Audio chosen by hand asks before a soundtrack that lowers the tier is saved. The question comes
    /// when the working copy is finished in its staging folder and before it is published, so declining leaves no file.
    @MainActor
    func testReplacingSourceAudioAsksBeforeTheWorkingCopyIsSaved() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let previousHelper = ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
        let helper = previousHelper ?? repository.appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper), "Needs the FFmpeg helper to write a working copy.")
        if previousHelper == nil { setenv("MPCUT_FFMPEG_HELPER", helper, 0) }
        defer { if previousHelper == nil { unsetenv("MPCUT_FFMPEG_HELPER") } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture("Pause-Noisy", "mov")
        // An MP3 soundtrack of the same length. Its packets do not meet the picture's keyframes, and MOV has no
        // edit list for MP3, so a cut the AAC original copies exactly is not a copy any more.
        let donor = directory.appendingPathComponent("donor.mp3")
        let converter = AudioExportEngine(useSidecar: false, tracks: .audio, audioTrackOrdinal: 0)
        try converter.write(converter.resolve([ClipRequest(file: try fixture("Pause-Quiet", "mov"))], output: donor, audio: .mp3), to: donor)
        let engine = AudioReplacementEngine(useSidecar: false)

        func cutEditor() async throws -> (model: EditorModel, asked: Asked) {
            let (model, asked) = try await editor("Pause-Noisy", "mov")
            model.seek(1)
            model.split()
            try await settle(model)
            model.deleteClip(try XCTUnwrap(model.timelineClips.first?.id))
            try await settle(model)
            XCTAssertEqual(model.settledTier, .trueLossless)
            XCTAssertEqual(asked.prompts.count, 0)
            return (model, asked)
        }
        func leftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != donor.lastPathComponent && !$0.hasSuffix(".cutdb") }.sorted()
        }

        // Declined: nothing is saved, nothing changes, and no failure is reported.
        let (model, asked) = try await cutEditor()
        defer { model.endSession() }
        let declined = directory.appendingPathComponent("declined.mov")
        let before = model.timelineClips.map(\.id)
        asked.answer = TierPrompt.Choice(answer: .cancel)
        model.byHand { _ = model.applyReplacement(try! engine.resolve(source: source, replacement: donor, output: declined),
                                                  output: declined, useSidecar: false) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.from, .trueLossless)
        XCTAssertLessThan(prompt.to.tier ?? .reencode, .trueLossless)
        XCTAssertNil(prompt.nearest, "The cuts are not moved for a soundtrack.")
        XCTAssertEqual(prompt.action, "Replace Source Audio")
        XCTAssertEqual(try leftovers(), [], "Declining leaves neither the working copy nor its staging folder.")
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.map(\.id), before)
        XCTAssertNil(model.timelineClips.first?.replacementAudio)
        XCTAssertEqual(model.settledTier, .trueLossless)

        // Accepted: asked once, then saved and applied, and the badge shows the tier the question named.
        let accepted = directory.appendingPathComponent("accepted.mov")
        asked.answer = TierPrompt.Choice(answer: .proceed)
        model.byHand { _ = model.applyReplacement(try! engine.resolve(source: source, replacement: donor, output: accepted),
                                                  output: accepted, useSidecar: false) }
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 2, "One question for the edit, none again when it is applied.")
        XCTAssertNil(model.alert)
        XCTAssertEqual(try leftovers(), [accepted.lastPathComponent])
        XCTAssertNotNil(model.timelineClips.first?.replacementAudio)
        XCTAssertEqual(model.tierState?.tier, asked.prompts[1].to.tier)
        XCTAssertLessThan(model.tierState?.tier ?? .reencode, .trueLossless)

        // An edit that is not made by hand, and one made with the preference off, do not ask.
        for byHand in [false, true] {
            let (other, quiet) = try await cutEditor()
            defer { other.endSession() }
            other.preferences.warnBeforeLoweringExportTier = !byHand
            defer { other.preferences.warnBeforeLoweringExportTier = true }
            let output = directory.appendingPathComponent("quiet-\(byHand).mov")
            let plan = try engine.resolve(source: source, replacement: donor, output: output)
            if byHand { other.byHand { _ = other.applyReplacement(plan, output: output, useSidecar: false) } }
            else { other.applyReplacement(plan, output: output, useSidecar: false) }
            try await settle(other)
            XCTAssertEqual(quiet.prompts.count, 0)
            XCTAssertNotNil(other.timelineClips.first?.replacementAudio)
        }

        // A soundtrack that keeps the tier is saved without a question.
        let (same, silent) = try await cutEditor()
        defer { same.endSession() }
        let kept = directory.appendingPathComponent("kept.mov")
        let plan = try engine.resolve(source: source, replacement: try fixture("Pause-Quiet", "mov"), output: kept)
        same.byHand { _ = same.applyReplacement(plan, output: kept, useSidecar: false) }
        try await settle(same)
        XCTAssertEqual(silent.prompts.count, 0)
        XCTAssertEqual(same.settledTier, .trueLossless)
        XCTAssertNotNil(same.timelineClips.first?.replacementAudio)
    }

    /// The badge and the export sheet name the same container. A preferred container that fails for the cuts while
    /// another verifies used to leave the badge on True Lossless and the sheet open on the failing container.
    @MainActor
    func testBadgeAndSheetOpenOnTheSameContainer() async throws {
        let (model, _) = try await editor("Shuttle-Chirp", "mov")
        defer { model.endSession() }
        // Remove the head: the clip now starts on a keyframe that is not on an AAC packet, which Matroska refuses.
        model.seek(0.6)
        model.split()
        try await settle(model)
        model.deleteClip(try XCTUnwrap(model.timelineClips.first?.id))
        try await settle(model)
        XCTAssertEqual(model.settledTier, .trueLossless)

        func badgeContainer() -> String? {
            if case .known(_, _, let container, _)? = model.tierState { return container }
            return nil
        }
        func sheet() throws -> ExportSheetOptions {
            let input = try model.mcpExportInput(selection: false)
            let source = try XCTUnwrap(input.media[input.clips[0].file])
            let preferred = model.preferredCopyContainer
            let mode = model.openingExportMode()
            let verified = ExportPlanner(useSidecar: false).openingContainer(
                for: ExportRequest(clips: input.clips, mode: mode), preferred: preferred, media: input.media)
            let choices = ExportContainerChoices(source: source, clips: input.clips, preferred: preferred, cancelled: { false })
            let options = EditorModel.openingExportOptions(ExportSheetOptions(), mode: mode, convertingByName: false, source: source,
                                                           choices: choices, preferred: preferred, verified: verified)
            // What the sheet opens on is planned.
            if case .unavailable(let issue, _) = ExportPlanner(useSidecar: false).resolve(options.request(input.clips), media: input.media) {
                XCTFail("The sheet opens on a failing export: \(issue.message)")
            }
            return options
        }

        for mode in [ExportMode.copy, .smart] {
            model.defaultExportMode = mode
            for (preferred, expected) in [("mkv", "mov"), ("mp4", "mp4"), ("mov", "mov")] {
                model.preferCopyContainer(preferred)
                try await settle(model)
                XCTAssertEqual(model.preferredCopyContainer, preferred)
                XCTAssertEqual(model.settledTier, .trueLossless, "The preference names a container. It never changes the tier.")
                XCTAssertEqual(badgeContainer(), expected, "badge, preferred \(preferred)")
                XCTAssertEqual(try sheet().copyContainer, expected, "sheet \(mode.rawValue), preferred \(preferred)")
            }
        }
    }
}
