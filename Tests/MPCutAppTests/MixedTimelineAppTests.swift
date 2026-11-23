import AppKit
import AVFoundation
import SwiftUI
import MPCutCore
import XCTest
@testable import MPCutApp

/// A clip in another format may join a timeline: the editor asks first, and then everything that assumed one
/// format follows the mixed timeline, which only Re-encode writes.
final class MixedTimelineAppTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    @MainActor
    private func settle(_ model: EditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while model.isBusy || !model.tierIsCurrent, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    private final class Asked {
        var prompts: [TierPrompt] = []
        var answer = TierPrompt.Choice(answer: .proceed)
    }

    /// An editor with its own preferences, snapping to keyframes, whose tier question is answered by `asked`.
    @MainActor
    private func editor(_ files: [URL]) async throws -> (model: EditorModel, asked: Asked, cleanUp: () -> Void) {
        let suite = "MPCut.Mixed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("keyframes", forKey: "timeline_snap_target")
        let model = EditorModel(defaults: defaults)
        model.useAnalysisSidecars = false
        let asked = Asked()
        model.tierPrompt = { prompt, answer in
            asked.prompts.append(prompt)
            answer(asked.answer)
        }
        if !files.isEmpty {
            model.importFiles(files)
            try await settle(model)
        }
        return (model, asked, {
            model.endSession()
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @MainActor
    func testAddingAClipInAnotherFormatAsksOnceAndCanBeDeclinedOrAccepted() async throws {
        let h264 = try fixture("Damage-H264", "mp4"), hevc = try fixture("Damage-HEVC", "mov")
        let (model, asked, cleanUp) = try await editor([h264])
        defer { cleanUp() }
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.snapTarget, .keyframes)
        XCTAssertEqual(model.effectiveSnapTarget, .keyframes)
        XCTAssertFalse(model.isMixedTimeline)
        let before = try XCTUnwrap(model.tierState?.tier)
        XCTAssertGreaterThan(before, .reencode)
        let summary = model.formatSummary

        // Declined: one question, and the timeline, its history and its tier are as they were.
        asked.answer = .init(answer: .cancel)
        let actions = model.historyActions, cursor = model.historyCursor
        model.importFiles([hevc])
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        let prompt = try XCTUnwrap(asked.prompts.first)
        XCTAssertEqual(prompt.buttons.map(\.title), ["Add Anyway", "Cancel"])
        XCTAssertTrue(prompt.title.contains("to Re-encode"), prompt.title)
        XCTAssertTrue(prompt.message.contains("Clips 1 and 2 differ in video codec"), prompt.message)
        XCTAssertTrue(prompt.message.contains("Exporting these clips together requires Re-encode."), prompt.message)
        XCTAssertNil(model.alert, "A clip in another format is a question, not a failure.")
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.historyActions, actions)
        XCTAssertEqual(model.historyCursor, cursor)
        XCTAssertEqual(model.tierState?.tier, before)
        XCTAssertFalse(model.isMixedTimeline)

        // Accepted: the badge is Re-encode with the mismatch, and what assumed one format follows.
        asked.answer = .init(answer: .proceed)
        model.importFiles([hevc])
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 2)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertTrue(model.isMixedTimeline)
        XCTAssertEqual(model.tierState?.tier, .reencode)
        XCTAssertEqual(model.tierState?.name, "Re-encode")
        let factor = try XCTUnwrap(model.tierState?.factors.first { $0.id == .joinStreamMismatch })
        XCTAssertEqual(factor.forces, .reencode)
        XCTAssertTrue(factor.message.hasPrefix("Clips 1 and 2 differ in video codec"), factor.message)
        XCTAssertEqual(model.formatSummary, "192 × 96 · Mixed formats")
        XCTAssertNotEqual(model.formatSummary, summary)
        XCTAssertEqual(model.openingExportMode(), .encode, "The export sheet opens on Re-encode.")
        XCTAssertEqual(model.mcpCopyContainers, [], "No container carries a packet copy of a mixed timeline.")

        // Keyframe snapping held cuts to copy boundaries, which every edit of a mixed timeline would fail.
        XCTAssertEqual(model.snapTarget, .keyframes, "The shared preference is kept.")
        XCTAssertEqual(model.effectiveSnapTarget, .off)
        model.chooseSnapTarget(.keyframes)
        XCTAssertEqual(model.effectiveSnapTarget, .off)
        XCTAssertEqual(model.alert?.title, "Keyframe Snapping Is Unavailable")
        model.dismissNotice()
        model.seek(0.32)
        model.split()
        try await settle(model)
        XCTAssertNil(model.alert, "A cut inside a picture group is an ordinary edit here.")
        XCTAssertEqual(model.timelineClips.count, 3)
        XCTAssertEqual(asked.prompts.count, 2, "The timeline is already Re-encode, so the cut asks nothing.")

        // Undo returns to one format, with its tier and its snapping. Redo makes it mixed again.
        model.undo()
        try await settle(model)
        model.undo()
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertFalse(model.isMixedTimeline)
        XCTAssertEqual(model.tierState?.tier, before)
        XCTAssertEqual(model.effectiveSnapTarget, .keyframes)
        XCTAssertEqual(model.formatSummary, summary)
        model.redo()
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertTrue(model.isMixedTimeline)
        XCTAssertEqual(model.tierState?.tier, .reencode)
    }

    @MainActor
    func testClipsInDifferentFormatsDroppedIntoAnEmptyEditorAskToo() async throws {
        let gop = try fixture("SmartTrim-GOP", "mp4"), vfr = try fixture("VFR-PTS", "mp4")
        let (model, asked, cleanUp) = try await editor([])
        defer { cleanUp() }
        asked.answer = .init(answer: .cancel)
        model.importFiles([gop, vfr])
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(asked.prompts.first?.buttons.map(\.title), ["Add Anyway", "Cancel"])
        XCTAssertTrue(model.isEmpty)

        asked.answer = .init(answer: .proceed)
        model.importFiles([gop, vfr])
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.tierState?.tier, .reencode)
        XCTAssertEqual(model.tierState?.factors.map(\.id), [.joinStreamMismatch])

        // Clips in one format are not asked about.
        let (same, sameAsked, cleanSame) = try await editor([])
        defer { cleanSame() }
        same.importFiles([gop, gop])
        try await settle(same)
        XCTAssertEqual(same.timelineClips.count, 2)
        XCTAssertEqual(sameAsked.prompts.count, 0)
        XCTAssertFalse(same.isMixedTimeline)
    }

    /// Opening a project checks its clips again. A saved mixed timeline opens as one, without a question.
    @MainActor
    func testAMixedProjectSavesAndReopens() async throws {
        let (model, _, cleanUp) = try await editor([try fixture("Damage-H264", "mp4")])
        defer { cleanUp() }
        model.importFiles([try fixture("Shuttle-Chirp", "mov"), try fixture("SmartTrim-GOP", "mp4")])
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mixed.cut")
        XCTAssertTrue(model.saveProject(to: url))

        let (reopened, asked, cleanReopened) = try await editor([])
        defer { cleanReopened() }
        guard case .sequence(let clips) = try CutProject.load(from: url) else { return XCTFail("Expected a sequence") }
        try reopened.openProject(clips, at: url)
        try await settle(reopened)
        XCTAssertNil(reopened.alert)
        XCTAssertEqual(reopened.timelineClips.count, 3)
        XCTAssertEqual(asked.prompts.count, 0)
        XCTAssertTrue(reopened.isMixedTimeline)
        XCTAssertEqual(reopened.tierState?.tier, .reencode)
        // History restores through the same import.
        reopened.undo()
        try await settle(reopened)
        XCTAssertEqual(reopened.timelineClips.count, 1)
        XCTAssertFalse(reopened.isMixedTimeline)
        reopened.redo()
        try await settle(reopened)
        XCTAssertEqual(reopened.timelineClips.count, 3)
        XCTAssertNil(reopened.alert)
    }

    @MainActor
    func testDontAskAgainAddsWithoutAQuestionAndARemoteImportIsNotAsked() async throws {
        let h264 = try fixture("Damage-H264", "mp4"), hevc = try fixture("Damage-HEVC", "mov")
        let (model, asked, cleanUp) = try await editor([h264])
        defer { cleanUp() }
        model.importFiles([hevc], allowCommit: { true })
        try await settle(model)
        XCTAssertEqual(asked.prompts.count, 0)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.tierState?.tier, .reencode)

        let (quiet, quietAsked, cleanQuiet) = try await editor([h264])
        defer { cleanQuiet() }
        quietAsked.answer = .init(answer: .proceed, dontAskAgain: true)
        quiet.importFiles([hevc])
        try await settle(quiet)
        XCTAssertEqual(quietAsked.prompts.count, 1)
        quiet.undo()
        try await settle(quiet)
        quiet.importFiles([hevc])
        try await settle(quiet)
        XCTAssertEqual(quietAsked.prompts.count, 1, "The preference is honoured.")
        XCTAssertEqual(quiet.timelineClips.count, 2)
        XCTAssertTrue(quiet.isMixedTimeline)
    }

    /// Clips with other track counts and sample rates: the analysis track is chosen per source, a clip without the
    /// chosen track analyses its first one, and silence detection and Shorten Pauses run on every clip.
    @MainActor
    func testAnalysisTrackAndPausesFollowEachSourceWhenTrackLayoutsDiffer() async throws {
        // One 48 kHz track, then two 16 kHz tracks.
        let (model, _, cleanUp) = try await editor([try fixture("Damage-H264", "mp4")])
        defer { cleanUp() }
        model.importFiles([try fixture("Pause-Quiet", "mov")])
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertTrue(model.isMixedTimeline)
        XCTAssertEqual(model.tierState?.tier, .reencode)
        XCTAssertEqual(model.audioTracks.count, 2, "The picker offers the tracks of the clip with the most.")
        let second = model.timelineClips[1].id

        model.chooseAnalysisTrack(1)
        XCTAssertEqual(model.sourceAnalysisTracks.values.sorted(), [0, 1], "The one-track clip keeps its only track.")
        model.seek(0.2)
        XCTAssertEqual(model.playheadAudioTracks.count, 1)
        XCTAssertEqual(model.playheadAnalysisTrack, 0)
        model.select(second)
        model.seek(model.duration - 0.5)
        XCTAssertEqual(model.playheadAudioTracks.count, 2)
        XCTAssertEqual(model.playheadAnalysisTrack, 1)
        // A track the clip does not have is not chosen for it.
        model.chooseAnalysisTrack(0)
        model.chooseAnalysisTrack(1, forClip: model.timelineClips[0].id)
        XCTAssertEqual(model.sourceAnalysisTracks.values.sorted(), [0, 0])

        model.minimumPause = 0.1
        model.scanForSilence()
        let deadline = ContinuousClock.now + .seconds(8)
        while !model.pauseAnalysisReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.pausePlan.isEmpty, "Pause-Quiet has pauses.")
        let original = model.duration
        model.byHand { _ = model.applyPauses(queueTakes: false) }
        try await settle(model)
        XCTAssertNil(model.alert, "Keyframe snapping is off on a mixed timeline, so the joins are not held to copy boundaries.")
        XCTAssertLessThan(model.duration, original)
        XCTAssertTrue(model.isMixedTimeline)
        XCTAssertEqual(model.tierState?.tier, .reencode)
    }

    /// Replace Source Audio works on the selected clip's own tracks. On a mixed timeline the working copy is one more
    /// format: the timeline stays mixed, and the project reopens.
    @MainActor
    func testReplaceSourceAudioOnAClipOfAMixedTimelineSavesAndReopens() async throws {
        let first = try fixture("Damage-H264", "mp4"), target = try fixture("Pause-Quiet", "mov")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let donor = directory.appendingPathComponent("processed.wav")
        do {
            let file = try AVAudioFile(forWriting: donor, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
            ], commonFormat: .pcmFormatInt16, interleaved: false)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64_000))
            pcm.frameLength = pcm.frameCapacity
            let samples = try XCTUnwrap(pcm.int16ChannelData?[0])
            for index in 0..<Int(pcm.frameLength) { samples[index] = Int16(index % 200 - 100) }
            try file.write(from: pcm)
        }
        let (model, _, cleanUp) = try await editor([first])
        defer { cleanUp() }
        model.importFiles([target])
        try await settle(model)
        XCTAssertTrue(model.isMixedTimeline)

        let working = directory.appendingPathComponent("working.mov")
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(
            source: target, replacement: donor, output: working, targetStream: 2, replacementStream: 0)
        model.applyReplacement(plan, output: working, useSidecar: false)
        try await settle(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.sequenceClips.map(\.file), [first.path, working.path])
        XCTAssertTrue(model.isMixedTimeline, "A replaced soundtrack does not hide that the pictures differ.")
        XCTAssertEqual(model.effectiveSnapTarget, .off)
        XCTAssertEqual(model.tierState?.tier, .reencode)

        let document = directory.appendingPathComponent("edit.cut")
        try model.writeProject(to: document)
        guard case .sequence(let clips) = try CutProject.load(from: document) else { return XCTFail("Expected a sequence") }
        let (reopened, asked, cleanReopened) = try await editor([])
        defer { cleanReopened() }
        try reopened.openProject(clips, at: document)
        try await settle(reopened)
        XCTAssertNil(reopened.alert)
        XCTAssertEqual(reopened.sequenceClips.map(\.file), [first.path, working.path])
        XCTAssertEqual(asked.prompts.count, 0)
        XCTAssertTrue(reopened.isMixedTimeline)
        XCTAssertEqual(reopened.tierState?.tier, .reencode)
    }

    @MainActor
    func testAMovieAndASoundOnlyRecordingStillCannotShareATimeline() async throws {
        let (model, asked, cleanUp) = try await editor([try fixture("Damage-H264", "mp4")])
        defer { cleanUp() }
        model.importFiles([try fixture("Gapless-Crop", "mp3")])
        try await settle(model)
        XCTAssertEqual(model.alert?.title, "Couldn’t Add Clip")
        XCTAssertTrue(model.alert?.message.contains("sound-only") == true, model.alert?.message ?? "")
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(asked.prompts.count, 0)
        model.dismissNotice()

        // Sound-only recordings in different formats have no canvas, so they are refused as before.
        let (sound, _, cleanSound) = try await editor([try fixture("Gapless-Crop", "mp3")])
        defer { cleanSound() }
        sound.importFiles([try fixture("Standalone-Chirp", "opus")])
        try await settle(sound)
        XCTAssertEqual(sound.alert?.title, "Couldn’t Add Clip")
        XCTAssertEqual(sound.timelineClips.count, 1)
    }

    @MainActor
    private func surface(in view: NSView?) -> PreviewSurface? {
        guard let view else { return nil }
        if let surface = view as? PreviewSurface { return surface }
        return view.subviews.lazy.compactMap { self.surface(in: $0) }.first
    }

    @MainActor
    private func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !ready(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard ready() else {
            XCTFail("Timed out waiting for \(what).", file: file, line: line)
            throw CancellationError()
        }
    }

    /// The preview decodes per source and fits each picture, so clips of other sizes, codecs, containers,
    /// sample rates and channel counts scrub and play through their joins.
    @MainActor
    func testPreviewScrubsAndPlaysAcrossClipsInDifferentFormats() async throws {
        _ = NSApplication.shared
        let session = ProjectSession(id: UUID(), preferences: EditorPreferences())
        defer { session.end() }
        let preview = session.editor.preview
        preview.isMuted = true
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreviewView(preview: preview))
        window.orderFront(nil)
        defer { window.close() }
        session.window = window
        // H.264 192×96 with mono AAC, H.264 320×96 with stereo AAC, VP9 in WebM with Opus, H.264 64×64 with FLAC 5.1 and 32 kHz stereo.
        let ranges = [("Damage-H264", "mp4"), ("Shuttle-Chirp", "mov"), ("Shuttle-Chirp", "webm"), ("Linked-Surround", "mkv")].map {
            PreviewRange(url: try! fixture($0.0, $0.1), exactStart: .zero, exactEnd: .init(numerator: 1))
        }
        preview.update(ranges, at: 0.4)
        try await wait("the first picture") { self.surface(in: window.contentView)?.displayedFrameTime != nil }
        let surface = try XCTUnwrap(surface(in: window.contentView))
        var shown = surface.displayedFrameTime
        for time in [1.5, 2.3, 3.7, 0.2, 2.6] {
            preview.seek(to: time)
            try await wait("a picture at \(time)") { surface.displayedFrameTime != nil && surface.displayedFrameTime != shown }
            shown = surface.displayedFrameTime
        }
        // Play from the first clip through every join.
        preview.seek(to: 0.6)
        try await wait("playback") {
            if !preview.isPlaying { preview.togglePlayback() }
            return preview.isPlaying
        }
        for join in [1.0, 2.0, 3.0] {
            try await wait("playback past \(join)") { preview.time > join + 0.1 }
        }
    }

    /// The export sheet's question to the shared rules, for the clips of a mixed timeline.
    func testExportSheetOffersTheReencodeAndPlansItWithWarnings() throws {
        let clips = [ClipRequest(file: try fixture("Damage-H264", "mp4")), ClipRequest(file: try fixture("SmartTrim-GOP", "mp4"))]
        for mode in [ExportMode.copy, .smart] {
            var options = ExportSheetOptions()
            options.mode = mode
            let refused = ExportAvailability.resolve(options, clips: clips, media: [:], useSidecar: false)
            guard case .unavailable = refused.availability else { return XCTFail("\(mode) joins packets and must refuse a mixed timeline.") }
            XCTAssertEqual(refused.failure?.code, "incompatible_clip")
            XCTAssertEqual(refused.failure?.factor, .joinStreamMismatch)
            XCTAssertEqual(refused.offers.map(\.alternative.id), ["reencode"], "\(mode)")
            XCTAssertEqual(refused.offers.first?.options.mode, .encode)
            XCTAssertTrue(refused.offers.first?.alternative.warnings.first?.contains("the whole timeline is re-encoded to 192×96") == true)
        }
        var options = ExportSheetOptions()
        options.mode = .encode
        let planned = ExportAvailability.resolve(options, clips: clips, media: [:], useSidecar: false)
        if planned.failure?.code == "helper_unavailable" { throw XCTSkip("The FFmpeg helper is not built.") }
        guard case .ready = planned.availability else { return XCTFail(planned.failure?.message ?? "Re-encode must plan.") }
    }

    /// The copy check is unchanged, and the import gate accepts exactly what Re-encode can write on one canvas.
    func testEncodeCombinableAcceptsWhatTheCopyCheckRefusesExceptOtherKinds() throws {
        let engine = CutEngine(useSidecar: false)
        let h264 = try engine.inspect(try fixture("Damage-H264", "mp4"), keyframes: true)
        let hevc = try engine.inspect(try fixture("Damage-HEVC", "mov"), keyframes: true)
        let mp3 = try engine.inspect(try fixture("Gapless-Crop", "mp3"), keyframes: true)
        let opus = try engine.inspect(try fixture("Standalone-Chirp", "opus"), keyframes: true)
        XCTAssertThrowsError(try engine.checkCompatibility(hevc, with: h264))
        XCTAssertNoThrow(try engine.checkEncodeCombinable(hevc, with: h264))
        XCTAssertNoThrow(try engine.checkEncodeCombinable(h264, with: h264))
        XCTAssertTrue(engine.isMixed([h264, hevc]))
        XCTAssertFalse(engine.isMixed([h264, h264]))
        XCTAssertThrowsError(try engine.checkEncodeCombinable(mp3, with: h264)) { XCTAssertEqual(($0 as? CutError)?.factor, .joinMediaType) }
        XCTAssertThrowsError(try engine.checkEncodeCombinable(opus, with: mp3)) { XCTAssertEqual(($0 as? CutError)?.factor, .joinStreamMismatch) }
    }
}
