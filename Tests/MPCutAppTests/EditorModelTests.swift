import AppKit
import Darwin
import MPCutCore
import XCTest
@testable import MPCutApp

final class EditorModelTests: XCTestCase {
    private enum TestError: Error {
        case editTimedOut
    }

    @MainActor
    func testJPEGPlayheadUsesHeldSourceFrameAfterReordering() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([url])
        try await waitForEdit(model)
        func frame(_ n: Int64) -> RationalTime { RationalTime(numerator: n * 1001, denominator: 30000) }
        model.seek(frame(4).seconds)
        model.split()
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.move(try XCTUnwrap(model.timelineClips.last?.id), to: 0)
        try await waitForEdit(model)
        model.seek(frame(1).seconds * 1.7)
        let source = try XCTUnwrap(model.jpegSourceAtPlayhead)
        XCTAssertEqual(source.media.url, url)
        XCTAssertEqual(source.frame, frame(5))
        model.seek(frame(8).seconds)
        XCTAssertEqual(model.jpegSourceAtPlayhead?.frame, .zero)
        model.seek(model.duration)
        XCTAssertEqual(model.jpegSourceAtPlayhead?.frame, frame(3))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        model.exportJPEGFrames(source, to: output, options: JPEGExportOptions())
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.lastExportedURL, output)
        struct Manifest: Decodable {
            struct Frame: Decodable { let frameTime: RationalTime; let file: String }
            let frames: [Frame]
        }
        let data = try Data(contentsOf: output.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.frames.map(\.frameTime), [frame(5)])
        let image = try XCTUnwrap(manifest.frames.first)
        XCTAssertNotNil(NSImage(contentsOf: output.appendingPathComponent(image.file)))
    }

    func testFilmstripSamplingRespectsTileBoundsAndHeldPictures() {
        let frames = [0, 4, 10, 14, 19, 20, 26, 30, 34, 40].map {
            RationalTime(numerator: $0, denominator: 10)
        }
        let clip = TimelineClip(id: UUID(), sourceID: UUID(), name: "VFR clip", sourceStart: 1,
                                sourceEnd: 4, sourceDuration: 5, keyframes: [0, 1, 2, 3, 4],
                                thumbnailSyncTimes: [0, 1, 2, 3, 4], frames: frames)
        XCTAssertEqual(clip.thumbnailTime(from: 1, to: 2.9), 2)
        XCTAssertEqual(clip.thumbnailTime(from: 1.1, to: 2), 1.4)
        XCTAssertEqual(clip.thumbnailTime(from: 1.5, to: 1.6), 1.4)
        XCTAssertEqual(clip.thumbnailTime(from: 1.6, to: 1.7), 1.4)
        XCTAssertEqual(clip.thumbnailTime(from: 3.8, to: 4), 3.4)
    }

    @MainActor
    func testSceneSteppingAcrossClipSeamsAndSessionReset() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        model.useAnalysisSidecars = false
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertTrue(model.canScanScenes)
        XCTAssertFalse(model.canScanSilence)
        model.scanForSilence()
        XCTAssertNil(model.silenceProgress)
        XCTAssertFalse(model.canStepScenes)
        model.stepScene(1)
        XCTAssertNil(model.sceneProgress)
        XCTAssertTrue(model.scenesBySource.isEmpty)
        XCTAssertEqual(model.playhead, 0)
        model.scanForScenes()
        XCTAssertNotNil(model.sceneProgress)
        XCTAssertFalse(model.canStepScenes)
        model.cancelSceneAnalysis()
        XCTAssertTrue(model.canScanScenes)
        XCTAssertFalse(model.canStepScenes)
        model.scanForScenes()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.sceneProgress != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.sceneProgress)
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.canScanScenes)
        XCTAssertTrue(model.canStepScenes)
        XCTAssertEqual(model.playhead, 0)
        model.stepScene(1)
        XCTAssertEqual(model.playhead, model.duration / 2, accuracy: 1e-8)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · View A · 1 view")
        let sourceID = try XCTUnwrap(model.timelineClips.first?.sourceID)
        XCTAssertEqual(model.scenesBySource[sourceID], [TimelineScene(start: 0, view: 1)])
        model.setViewName(" Wide ", source: sourceID, view: 1)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · Wide · 1 view")
        model.stepScene(-1)
        XCTAssertEqual(model.playhead, 0)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · Wide · 1 view")
        model.setViewName("", source: sourceID, view: 1)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · View A · 1 view")
        model.endSession()
        XCTAssertTrue(model.scenesBySource.isEmpty)
        XCTAssertTrue(model.viewNamesBySource.isEmpty)
    }

    @MainActor
    func testSilenceScanCanBeCancelledAndRepeatedWithoutDecodingTheWaveformAgain() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.importFiles([file])
        try await waitForEdit(model)
        let waveDeadline = ContinuousClock.now + .seconds(5)
        while model.effectiveThresholdDB == nil, ContinuousClock.now < waveDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.effectiveThresholdDB)
        XCTAssertTrue(model.canScanSilence)
        XCTAssertFalse(model.pauseAnalysisReady)
        XCTAssertTrue(model.sourcePauses.isEmpty)
        model.scanForSilence()
        XCTAssertNotNil(model.silenceProgress)
        model.cancelSilenceScan()
        XCTAssertNil(model.silenceProgress)
        XCTAssertTrue(model.canScanSilence)
        XCTAssertFalse(model.pauseAnalysisReady)
        XCTAssertEqual(model.audioStore.finished.count, 1)

        model.minimumPause = model.duration + 1
        model.scanForSilence()
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertNil(model.silenceProgress)
        XCTAssertTrue(model.pausePlan.isEmpty)
        XCTAssertEqual(model.sourcePauses.count, 1)
        let id = try XCTUnwrap(model.timelineClips.first?.sourceID)
        XCTAssertEqual(model.completedSilences(for: id).count, 1)
        model.scanForSilence()
        XCTAssertNotNil(model.silenceProgress)
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertEqual(model.sourcePauses[id], [])
        model.cancelSilenceScan()
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertEqual(model.completedSilences(for: id).count, 1)
    }

    @MainActor
    func testAutomaticThresholdFollowsRecordingAndTrack() async throws {
        let quiet = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let noisy = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        func waitForAnalysis() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !model.pauseAnalysisReady, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(model.pauseAnalysisReady)
        }

        model.importFiles([quiet, noisy])
        try await waitForEdit(model)
        model.scanForSilence()
        try await waitForAnalysis()
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.audioTracks.count, 2)
        XCTAssertNil(model.manualThresholdDB)
        let quietLevel = try XCTUnwrap(model.effectiveThresholdDB)
        model.seek(4.2)
        XCTAssertNil(model.manualThresholdDB)
        let noisyLevel = try XCTUnwrap(model.effectiveThresholdDB)
        XCTAssertGreaterThan(noisyLevel, quietLevel + 10)
        XCTAssertEqual(model.pausePlan.count, 2)

        model.seek(1.2)
        model.setIn()
        model.seek(2.8)
        model.setOut()
        let waveformDeadline = ContinuousClock.now + .seconds(5)
        while !model.canUseRoomTone, ContinuousClock.now < waveformDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canUseRoomTone)
        model.useRoomTone()
        try await waitForAnalysis()
        let manualLevel = try XCTUnwrap(model.manualThresholdDB)
        model.seek(4.2)
        XCTAssertNil(model.manualThresholdDB)
        XCTAssertEqual(model.effectiveThresholdDB, noisyLevel)

        // The second audio stream in each fixture has the other room floor.
        model.analysisTrack = 1
        try await waitForAnalysis()
        XCTAssertNil(model.manualThresholdDB)
        XCTAssertEqual(model.effectiveThresholdDB, quietLevel)
        model.seek(0.2)
        XCTAssertNil(model.manualThresholdDB)
        XCTAssertEqual(model.effectiveThresholdDB, noisyLevel)

        model.analysisTrack = 0
        try await waitForAnalysis()
        XCTAssertEqual(model.manualThresholdDB, manualLevel)
        model.manualThresholdDB = nil
        try await waitForAnalysis()
        XCTAssertEqual(model.effectiveThresholdDB, quietLevel)

        // A pause report can be ready while its waveform is still loading.
        model.seek(1.2)
        model.setIn()
        model.seek(2.8)
        model.setOut()
        XCTAssertNotNil(model.markedRange)
        model.audioStore.clear()
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertFalse(model.canUseRoomTone)
        model.useRoomTone()
        XCTAssertNotNil(model.markedRange)
        XCTAssertNil(model.manualThresholdDB)
    }

    @MainActor
    func testPauseWorkflowOnRepeatedSource() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Scrub-Tone", withExtension: "webm", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.minimumPause = 0.1
        model.importFiles([file, file])
        try await waitForEdit(model)
        model.manualThresholdDB = 0
        model.scanForSilence()
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertEqual(model.audioStore.waves.count, 1)
        XCTAssertEqual(model.pausePlan.count, 2)
        let original = model.duration
        model.stepPause(1)
        XCTAssertEqual(model.playhead, original / 2, accuracy: 1e-8)
        model.previewCurrentCut()
        let sheetID = try XCTUnwrap(model.cutPreview?.id)
        model.advanceCutPreview(keepingCurrent: false)
        XCTAssertEqual(model.playhead, 0, accuracy: 1e-8)
        model.advanceCutPreview(keepingCurrent: false)
        XCTAssertEqual(model.playhead, original / 2, accuracy: 1e-8)
        model.advanceCutPreview(keepingCurrent: true)
        XCTAssertEqual(model.pausePlan.compactMap(\.removal).count, 1)
        XCTAssertEqual(model.playhead, 0, accuracy: 1e-8)
        let preview = try XCTUnwrap(model.cutPreview)
        XCTAssertEqual(preview.id, sheetID)
        XCTAssertEqual(preview.ranges.count, 3)
        XCTAssertEqual(preview.ranges[0].exactEnd, model.currentPause?.removal?.from)
        XCTAssertEqual(preview.ranges[1].exactStart, model.currentPause?.removal?.to)
        let player = SequencePreview()
        defer { player.update([], at: 0) }
        player.isMuted = true
        player.update(preview.ranges, at: 0)
        let previewDeadline = ContinuousClock.now + .seconds(5)
        let join = preview.ranges[0].exactEnd - preview.ranges[0].exactStart
        while player.time <= join.seconds, player.issue == nil, ContinuousClock.now < previewDeadline {
            if !player.isPlaying { player.togglePlayback() }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(player.issue)
        XCTAssertGreaterThan(player.time, join.seconds)
        player.pause()
        model.cutPreview = nil
        model.applyPauses(queueTakes: true)
        XCTAssertEqual(model.queuedRanges.count, 2)
        XCTAssertEqual(model.duration, original)
        model.applyPauses(queueTakes: false)
        XCTAssertEqual(model.timelineClips.count, 3)
        XCTAssertNotNil(model.timelineClips.first?.displayRange)
        XCTAssertEqual(model.duration, original - 0.2, accuracy: 1e-8)
        model.undo()
        XCTAssertEqual(model.duration, original)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.minimumPause = 0.5
        let detectionDeadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < detectionDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.pauseAnalysisReady, "Pause detection did not finish within 5 s of changing the minimum pause")
        model.seek(original / 2 + 0.2)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 3)
        XCTAssertEqual(model.pausePlan.count, 2)
        XCTAssertEqual(model.pausePlan.filter(\.isProtected).count, 1)
        // The first few bins of the fixture are slightly louder. Moving the
        // detector edge must preserve the review decision for this occurrence.
        let oldStart = model.pausePlan.last?.sequence.from
        model.manualThresholdDB = -9
        let settingsDeadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < settingsDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.pauseAnalysisReady, "Pause detection did not finish within 5 s of changing the threshold")
        XCTAssertNotEqual(model.pausePlan.last?.sequence.from, oldStart)
        XCTAssertEqual(model.pausePlan.map(\.isProtected), [false, true])
        model.endSession()
        XCTAssertTrue(model.audioStore.waves.isEmpty)
        XCTAssertTrue(model.pausePlan.isEmpty)
    }

    @MainActor
    func testSkipInPlaybackSeeksOverTheRemovableInterior() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Scrub-Tone", withExtension: "webm", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.minimumPause = 0.1
        model.leavePause = 0.2
        model.importFiles([file])
        try await waitForEdit(model)
        model.manualThresholdDB = 0
        model.scanForSilence()
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.pauseAnalysisReady, "The silence scan did not finish within 5 s")
        let cut = try XCTUnwrap(model.pausePlan.first?.removal)
        let before = model.duration
        var times: [Double] = []
        let observer = model.preview.$time.sink { times.append($0) }
        defer { observer.cancel() }
        model.preview.isMuted = true
        model.skipPauses = true
        while !model.preview.isPlaying, model.preview.issue == nil, ContinuousClock.now < deadline {
            model.preview.togglePlayback()
            if !model.preview.isPlaying { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(model.preview.isPlaying, "Playback did not start before the deadline: \(model.preview.issue ?? "no issue reported")")
        while !times.contains(cut.to.seconds), model.preview.isPlaying, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertNil(model.preview.issue)
        XCTAssertTrue(times.contains(cut.to.seconds), "Playback must explicitly seek to the proposed end of the cut.")
        XCTAssertEqual(model.duration, before)
        XCTAssertEqual(model.timelineClips.count, 1)
    }

    @MainActor
    func testCopyPauseTrimAtMarkedWebMHead() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.minimumPause = 0.1
        model.leavePause = 0
        model.importFiles([file])
        try await waitForEdit(model)
        model.manualThresholdDB = 0
        model.scanForSilence()
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.setIn()
        model.seek(1.8)
        model.setOut()
        model.snapTarget = .keyframes
        let cut = try XCTUnwrap(model.currentPause?.removal ?? model.pausePlan.first?.removal)
        XCTAssertEqual(cut, AudioSpan(from: .zero, to: .init(numerator: 1)))
        model.applyPauses(queueTakes: false)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 1)
        XCTAssertEqual(model.duration, 3)
    }

    @MainActor
    func testEmptyPauseScopeAndNoRetainedFootageDisableEditsOrPreview() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Scrub-Tone", withExtension: "webm", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.minimumPause = 0.1
        model.leavePause = 0
        model.importFiles([file, file])
        try await waitForEdit(model)
        model.manualThresholdDB = 0
        model.scanForSilence()
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.pauseAnalysisReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.shortenedPauseCount, 2)
        XCTAssertFalse(model.canPreviewCurrentCut)
        model.previewCurrentCut()
        XCTAssertNil(model.cutPreview)
        model.seek(0.2)
        model.setIn()
        model.setOut()
        XCTAssertTrue(model.hasPauseMarks)
        XCTAssertTrue(model.pausePlan.isEmpty)
        let original = model.duration
        model.applyPauses(queueTakes: true)
        model.applyPauses(queueTakes: false)
        XCTAssertTrue(model.queuedRanges.isEmpty)
        XCTAssertEqual(model.duration, original)
        XCTAssertNil(model.alert)
        model.clearMarks()
        XCTAssertEqual(model.shortenedPauseCount, 2)
    }

    func testLiveSceneMarkersSurviveACadenceChange() throws {
        // The MOV header averages exactly 30 fps. Frame 65 changes cadence
        // after two markers, forcing a retry on Macs using the pipelined reader.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine().inspect(url)
        var markers: [TimelineScene] = []
        var lastProgress = 0.0
        let report = try SceneAnalysis.scan(media, progress: { progress in
            XCTAssertGreaterThanOrEqual(progress, lastProgress)
            lastProgress = progress
        }, onScene: { time, view in
            markers.append(TimelineScene(start: time.seconds, view: view))
        }, onReset: {
            markers.removeAll()
            lastProgress = 0
        })
        XCTAssertEqual(report.scenes.map(\.startPTS), [0, 58_000, 110_000])
        XCTAssertEqual(report.scenes.map(\.view), [1, 2, 1])
        XCTAssertEqual(markers, report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) })
    }

    func testSceneReportHonorsExactDurationAndCancellation() throws {
        XCTAssertEqual([1, 26, 27, 52, 53, 703].map(SceneView.label(for:)), ["A", "Z", "AA", "AZ", "BA", "AAA"])
        let url = try XCTUnwrap(Bundle.module.url(forResource: "VFR-PTS", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine().inspect(url, keyframes: true)
        let report = try SceneAnalysis.scan(media)
        XCTAssertEqual(report.scenes.first?.start, .zero)
        XCTAssertEqual(report.scenes.last?.end, media.duration)
        for scene in report.scenes {
            XCTAssertTrue(media.frames.contains { $0.time == scene.start })
            XCTAssertEqual(try RationalTime(numerator: scene.startPTS).multiplied(by: report.timeBase),
                           report.origin + scene.start)
        }
        XCTAssertThrowsError(try SceneAnalysis.scan(media, cancelled: { true })) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
    }

    @MainActor
    func testRangeToolSplitPreservesTrimmedOuterHandles() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        let frame = 1001.0 / 30000
        model.trim(id, edge: .start, sourceTime: frame * 2, commit: true)
        model.trim(id, edge: .end, sourceTime: frame * 10, commit: true)
        model.selectRange(frame * 2, frame * 5)
        model.splitSelectedRange()
        let clips = model.timelineClips
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips.first?.id, id)
        XCTAssertEqual(clips.map { Int(($0.sourceStart / frame).rounded()) }, [2, 4, 7])
        XCTAssertEqual(clips.map { Int(($0.sourceEnd / frame).rounded()) }, [4, 7, 10])
        XCTAssertEqual(clips.compactMap { $0.displayRange }.map { Int(($0.from.seconds / frame).rounded()) }, [0, 4, 7])
        XCTAssertEqual(clips.compactMap { $0.displayRange }.map { Int(($0.to.seconds / frame).rounded()) }, [4, 7, 12])
    }

    @MainActor
    func testRangeToolSplitsAcrossOccurrencesAndKeepsMarksForDeleteAndExport() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        model.rangeTool = true
        let original = model.sequenceClips
        let frame = 1001.0 / 30000
        model.deleteSelection()
        XCTAssertEqual(model.sequenceClips, original)
        model.selectRange(3 * frame, 3 * frame)
        XCTAssertFalse(model.canDelete)
        XCTAssertFalse(model.canSplitSelectedRange)
        model.selectRange(15.1 * frame, 4.2 * frame)
        XCTAssertEqual(model.markIn ?? -1, 4 * frame, accuracy: 1e-9)
        XCTAssertEqual(model.markOut ?? -1, 15 * frame, accuracy: 1e-9)
        XCTAssertTrue(model.canSplitSelectedRange)
        model.splitSelectedRange()
        XCTAssertEqual(model.timelineClips.count, 4)
        XCTAssertEqual(model.selectedID, model.timelineClips[1].id)
        XCTAssertFalse(model.canSplitSelectedRange)
        XCTAssertTrue(model.canDelete)
        let split = model.sequenceClips
        model.splitSelectedRange()
        model.undo()
        XCTAssertEqual(model.sequenceClips, original)
        model.redo()
        XCTAssertEqual(model.sequenceClips, split)
        model.deleteSelection()
        XCTAssertEqual(model.duration, 13 * frame, accuracy: 1e-9)
        model.undo()
        model.addMarkedRange()
        let range = try XCTUnwrap(model.queuedRanges.first)
        XCTAssertEqual(range.clips.count, 2)
        XCTAssertEqual(range.clips.first?.from?.seconds ?? -1, 4 * frame, accuracy: 1e-9)
        XCTAssertEqual(range.clips.last?.to?.seconds ?? -1, 3 * frame, accuracy: 1e-9)

        model.selectRange(-1, 2 * model.duration)
        XCTAssertEqual(model.markIn, 0)
        XCTAssertEqual(model.markOut, model.duration)
        XCTAssertFalse(model.canSplitSelectedRange)
        XCTAssertTrue(model.canDelete)
        model.selectRange(.nan, 0)
        XCTAssertEqual(model.markedRange, 0...model.duration)
        model.deleteSelection()
        XCTAssertTrue(model.timelineClips.isEmpty)
        model.undo()
        XCTAssertEqual(model.sequenceClips, split)
    }

    @MainActor
    func testQueueCapturesIndependentTimelineRangesAcrossSourceSeams() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        let frame = RationalTime(numerator: 1001, denominator: 30000)
        model.seek(10 * frame.seconds)
        model.setIn()
        model.seek(14 * frame.seconds)
        model.setOut()
        model.addMarkedRange()
        let first = try XCTUnwrap(model.queuedRanges.first)
        XCTAssertEqual(first.clips.count, 2)
        XCTAssertEqual(first.clips[0].from?.seconds ?? -1, 10 * frame.seconds, accuracy: 1e-8)
        XCTAssertEqual(first.clips[1].to?.seconds ?? -1, 2 * frame.seconds, accuracy: 1e-8)
        XCTAssertFalse(model.canAddMarkedRange)
        model.seek(0)
        model.setIn()
        model.seek(frame.seconds)
        model.setOut()
        model.addMarkedRange()
        XCTAssertEqual(model.queuedRanges.count, 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.showBulkQueue()
        var options = ExportSheetOptions()
        options.copyContainer = "mov"
        model.exportQueuedRanges(to: directory, options: options)
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.lastExportedURL, directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["ProRes-2997-001.mov", "ProRes-2997-002.mov"])
        model.removeQueuedRange(first.id)
        XCTAssertEqual(model.queuedRanges.first?.start, .zero)
        XCTAssertEqual(model.queuedRanges.first?.end, frame)
        model.endSession()
        XCTAssertTrue(model.queuedRanges.isEmpty)
    }

    @MainActor
    func testDragHandlesBackIntoExcludedFootageAfterCommit() async throws {
        _ = NSApplication.shared
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)

        // Two twelve-frame sources, 40 points per frame and a 16-point margin.
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 992, height: 119))
        surface.viewportWidth = 992
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        func refresh() {
            surface.timeline = SequenceTimeline(clips: model.timelineClips, playhead: model.playhead,
                                               selection: model.selectedID, onSelect: model.select,
                                               onSeek: model.seek, onTrim: model.trim, onMove: model.move,
                                               onDrop: { _, _ in }, onCancelTrim: model.cancelTrim)
        }
        func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 60) throws -> NSEvent {
            let location = surface.convert(NSPoint(x: x, y: y), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1))
        }
        func drag(_ from: CGFloat, _ to: CGFloat) async throws {
            surface.mouseDown(with: try mouse(.leftMouseDown, x: from))
            surface.mouseDragged(with: try mouse(.leftMouseDragged, x: to))
            surface.mouseUp(with: try mouse(.leftMouseUp, x: to))
            try await waitForEdit(model)
            XCTAssertNil(model.alert)
            refresh()
        }
        let frame = 1001.0 / 30_000
        refresh()
        try await drag(18, 138)
        try await drag(494, 414)
        XCTAssertEqual(model.timelineClips[0].sourceStart, 3 * frame, accuracy: 1e-9)
        XCTAssertEqual(model.timelineClips[0].sourceEnd, 10 * frame, accuracy: 1e-9)

        // Frame two of the second source now plays at frame nine of the sequence.
        surface.mouseDown(with: try mouse(.leftMouseDown, x: 576, y: 10))
        surface.mouseUp(with: try mouse(.leftMouseUp, x: 576, y: 10))
        XCTAssertEqual(model.playhead, 9 * frame, accuracy: 1e-9)

        // Both restore drags start just outside the kept range, on the faded side.
        try await drag(134, 14)
        try await drag(418, 498)
        XCTAssertEqual(model.timelineClips[0].sourceStart, 0)
        XCTAssertEqual(model.timelineClips[0].sourceEnd, 12 * frame, accuracy: 1e-9)
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)

        try await drag(498, 658)
        XCTAssertEqual(model.timelineClips[1].sourceStart, 4 * frame, accuracy: 1e-9)
        try await drag(654, 494)
        XCTAssertEqual(model.timelineClips[1].sourceStart, 0)
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)
    }

    @MainActor
    func testSceneSnapUsesDetectedSourceFramesForTrimSplitAndMarkedDelete() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([file])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        model.snapTarget = .scenes
        model.scanForScenes()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.sceneProgress != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.canStepScenes)
        let first = 58.0 / 30.0, second = 110.0 / 30.0

        XCTAssertEqual(model.pointerTarget(first + 0.005, tolerance: 0.01), first, accuracy: 1e-9)
        let free = model.pointerTarget(1.0, tolerance: 0.01)
        XCTAssertEqual(free, 1.0)
        model.seekFromPointer(free)
        model.split()
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.displayRange?.to.seconds, free)
        XCTAssertEqual(model.timelineClips.last?.displayRange?.from.seconds, free)
        model.undo()
        // Two free pointer positions within one scene retain their exact marks,
        // including reversed I/O order. Deleting must remove just this interval.
        model.seekFromPointer(model.pointerTarget(1.5, tolerance: 0.01))
        model.setIn()
        model.seekFromPointer(model.pointerTarget(1.0, tolerance: 0.01))
        model.setOut()
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1.0)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 1.5)
        XCTAssertEqual(model.timelineClips.first?.displayRange?.to.seconds, 1.0)
        XCTAssertEqual(model.timelineClips.last?.displayRange?.from.seconds, 1.5)
        model.undo()
        model.clearMarks()
        model.seekFromPointer(model.pointerTarget(1.0, tolerance: 0.01))
        model.trimSelected(.start)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 1.0)
        model.undo()
        // Returning through time entry to the same numeric position restores the
        // ordinary scene-target command behavior.
        model.seek(1.0)
        model.split()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, first)
        model.undo()
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 1.75, commit: false), first)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 1.75, commit: true), first)
        model.seek(1.2)
        model.split()
        XCTAssertEqual(model.timelineClips.map(\.sourceStart), [first, second])
        model.undo()
        model.undo()
        model.seek(1.65)
        model.setIn()
        model.seek(3.4)
        model.setOut()
        XCTAssertEqual(model.markIn, first)
        XCTAssertEqual(model.markOut, second)
        model.deleteSelection()
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, first)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, second)
    }

    @MainActor
    func testSilenceSnapQuantizesBothUnpaddedEdgesAndRejectsAnEmptyAnalysis() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([file])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        model.leavePause = 1.0
        model.snapTarget = .silence
        func waitForSilence() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !model.pauseAnalysisReady && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(model.pauseAnalysisReady)
        }
        try await waitForSilence()
        // This 10 fps fixture has quiet edges at 1.02 s and 2.98 s.
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 2.7, commit: false), 3)
        model.cancelTrim()
        model.seek(1.3)
        model.split()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1)
        model.undo()
        model.seek(1.2)
        model.setIn()
        model.seek(2.7)
        model.setOut()
        XCTAssertEqual(model.markIn, 1)
        XCTAssertEqual(model.markOut, 3)
        model.addMarkedRange()
        XCTAssertEqual(model.queuedRanges.first?.end.seconds, 3)

        model.minimumPause = 5
        try await waitForSilence()
        model.seek(1.3)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertTrue(model.alert?.message.contains("no detected pause edge") == true)
        model.dismissNotice()
        XCTAssertEqual(model.snapTarget, .silence)
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: model.duration, commit: true), model.duration)
    }

    @MainActor
    func testFrameEditingAndOptInCopySnappingAcrossUndo() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([file])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        let fullDuration = model.duration

        XCTAssertEqual(model.snapTarget, .off)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.285, commit: false), 0.28)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.285, commit: true), 0.28)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0.28)
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 1.285, commit: true), 1.28)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1.28)
        XCTAssertEqual(model.playhead, 0.96, accuracy: 1e-9)

        model.snapTarget = .keyframes
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0.28)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1.28)
        XCTAssertNil(model.trim(id, edge: .end, sourceTime: 1.0, commit: true))
        XCTAssertTrue(model.alert?.message.contains("Review Cuts") == true)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1.28)
        model.dismissNotice()
        XCTAssertEqual(model.undoTitle, "Undo Trim Clip")
        model.undo()
        XCTAssertEqual(model.redoTitle, "Redo Trim Clip")
        model.undo()
        XCTAssertEqual(model.snapTarget, .keyframes)
        XCTAssertEqual(model.duration, fullDuration)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.6, commit: false), 1)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.6, commit: true), 1)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 1)
        model.undo()

        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 0.6, commit: false), 1)
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 0.6, commit: true), 1)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1)
        XCTAssertEqual(model.playhead, 0.96, accuracy: 1e-9)
        model.undo()

        model.seek(0.6)
        model.split()
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1)
        model.undo()
        model.snapTarget = .off
        model.seek(0.605)
        model.split()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.6)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 0.6)
        model.undo()

        model.seek(0.285)
        model.setIn()
        model.seek(0.605)
        model.setOut()
        XCTAssertEqual(model.deleteTitle, "Delete Marked Range")
        XCTAssertEqual(model.markIn, 0.28)
        XCTAssertEqual(model.markOut, 0.6)
        model.deleteSelection()
        XCTAssertEqual(model.undoTitle, "Undo Delete Marked Range")
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.28)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 0.6)
        model.undo()
        XCTAssertEqual(model.duration, fullDuration)
        XCTAssertEqual(model.markIn, 0.28)
        XCTAssertEqual(model.markOut, 0.6)
    }

    @MainActor
    func testVariableFrameRateUsesPresentationBoundariesForBothHandlesAndMarks() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "VFR-PTS", withExtension: "mp4",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 0.34, commit: true), 0.4)
        XCTAssertEqual(model.playhead, 0.2)
        model.undo()
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.34, commit: true), 0.4)
        model.undo()
        model.seek(0.34)
        model.setIn()
        XCTAssertEqual(model.markIn, 0.4)
        model.split()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.4)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 0.4)
    }

    @MainActor
    func testSingleMarkPersistsWhileSeekingAndProtectsSelectedClip() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        model.setIn()
        model.step(1)
        XCTAssertEqual(model.markIn, 0)
        XCTAssertNil(model.markOut)
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertNotNil(model.alert)
        model.dismissNotice()
        model.clearMarks()
        model.setOut()
        let out = model.playhead
        model.seek(0)
        XCTAssertEqual(model.markOut, out)
        XCTAssertNil(model.markIn)
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertNotNil(model.alert)
        model.dismissNotice()
        model.setIn()
        XCTAssertEqual(model.markedRange, 0...out)
        model.clearMarks()
        XCTAssertNil(model.markIn)
        XCTAssertNil(model.markOut)
    }

    @MainActor
    func testFrameStepAndMarkedDeletionAcrossClipJoin() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let frame = 1001.0 / 30_000
        let model = EditorModel()
        defer { model.endSession() }

        model.importFiles([source, source])
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.sourceID, model.timelineClips.last?.sourceID)
        XCTAssertNotEqual(model.timelineClips.first?.id, model.timelineClips.last?.id)
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)

        model.seek(12 * frame)
        model.step(-1)
        XCTAssertEqual(model.playhead, 11 * frame, accuracy: 1e-9)
        model.step(1)
        XCTAssertEqual(model.playhead, 12 * frame, accuracy: 1e-9)
        model.seek(model.duration)
        model.split()
        XCTAssertEqual(model.alert?.title, "Can’t Split Clip")
        XCTAssertEqual(model.timelineClips.count, 2)
        model.dismissNotice()
        model.step(-1)
        XCTAssertEqual(model.playhead, 23 * frame, accuracy: 1e-9)

        model.seek(4 * frame)
        model.setIn()
        model.setOut()
        model.deleteSelection()
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.dismissNotice()

        model.seek(15 * frame)
        model.setIn()
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        let left = try XCTUnwrap(model.timelineClips.first)
        let right = try XCTUnwrap(model.timelineClips.last)
        XCTAssertEqual(left.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(left.sourceEnd, 4 * frame, accuracy: 1e-9)
        XCTAssertEqual(right.sourceStart, 3 * frame, accuracy: 1e-9)
        XCTAssertEqual(right.sourceEnd, 12 * frame, accuracy: 1e-9)

        model.undo()
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.markIn), 15 * frame, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.markOut), 4 * frame, accuracy: 1e-9)
        model.redo()
        XCTAssertEqual(model.duration, 13 * frame, accuracy: 1e-9)
        XCTAssertNil(model.markIn)
        XCTAssertNil(model.markOut)
    }

    @MainActor
    func testSplitContinuousWebMWithOpus() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        let originalDuration = model.duration
        let cuts = model.timelineClips.first?.keyframes ?? []
        let cut = try XCTUnwrap(cuts.first(where: { $0 >= 2 }))
        model.seek(cut)
        model.split()
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, cut)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, cut)
        XCTAssertEqual(model.duration, originalDuration)
        let first = try XCTUnwrap(model.timelineClips.first)
        let last = try XCTUnwrap(model.timelineClips.last)
        XCTAssertEqual(model.trim(first.id, edge: .start, sourceTime: 1, commit: true), 1)
        try await waitForEdit(model)
        XCTAssertEqual(model.trim(last.id, edge: .end, sourceTime: 3, commit: true), 3)
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.duration, 2)
        model.move(last.id, to: 0)
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.map(\.id), [last.id, first.id])
    }

    @MainActor
    func testSnapCanRestoreContinuityAcrossAnOffKeyframeWebMSeam() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([file])
        try await waitForEdit(model)
        let originalDuration = model.duration
        model.seek(1.2)
        model.split()
        let left = try XCTUnwrap(model.timelineClips.first)
        XCTAssertEqual(left.sourceEnd, 1.2)
        XCTAssertFalse(left.keyframes.contains(1.2))
        XCTAssertEqual(model.trim(left.id, edge: .end, sourceTime: 0.8, commit: true), 0.8)
        model.snapTarget = .keyframes
        XCTAssertEqual(model.trim(left.id, edge: .end, sourceTime: 1.2, commit: true), 1.2)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.duration, originalDuration)
        model.undo()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.8)
    }

    @MainActor
    func testWebMOpusImportAndDeletionCanCreateACopyUnsafeJoin() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.undo()

        model.importFiles([source])
        try await waitForEdit(model)
        model.snapTarget = .keyframes
        model.seek(1)
        model.setIn()
        model.seek(2)
        model.setOut()
        model.deleteSelection()
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertTrue(model.alert?.message.contains("Opus track 1") == true)
        model.dismissNotice()

        model.snapTarget = .off
        model.deleteSelection()
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 2)
    }

    @MainActor
    func testSelectingSeventhNTSCClipLandsExactlyAtJoin() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles(Array(repeating: source, count: 8))
        try await waitForEdit(model)

        let surface = TimelineSurface(frame: .zero)
        surface.timeline = SequenceTimeline(clips: model.timelineClips, playhead: model.playhead,
                                             selection: model.selectedID, onSelect: model.select, onSeek: model.seek,
                                             onTrim: model.trim, onMove: model.move, onDrop: { _, _ in })
        // The first accessibility child is the ruler.
        let button = try XCTUnwrap(surface.accessibilityChildren()?[7] as? NSAccessibilityElement)
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(model.playhead, RationalTime(numerator: 6 * 12 * 1001, denominator: 30_000).seconds)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 8)
        XCTAssertEqual(model.selectedID, model.timelineClips[6].id)
    }

    @MainActor
    func testSingleClipPublishesPreviewBeforeItCanBeEdited() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        model.useAnalysisSidecars = false
        defer { model.endSession() }
        var progress: [Double] = []
        let progressObservation = model.$importProgress.sink { progress.append($0) }
        defer { progressObservation.cancel() }
        var provisionalID: UUID?
        let observation = model.$playhead.sink { _ in
            guard model.isImporting, let clip = model.timelineClips.first else { return }
            provisionalID = clip.id
            XCTAssertTrue(clip.frames.isEmpty)
            XCTAssertGreaterThan(model.duration, 0)
            XCTAssertTrue(model.canNavigate)
            XCTAssertFalse(model.canEdit)
            XCTAssertFalse(model.hasHistory)
        }
        defer { observation.cancel() }
        model.importFiles([file])
        try await waitForEdit(model)
        XCTAssertTrue(progress.contains { $0 > 0 && $0 < 1 })
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(try XCTUnwrap(provisionalID), model.selectedID)
        XCTAssertFalse(try XCTUnwrap(model.timelineClips.first).frames.isEmpty)
        XCTAssertTrue(model.canEdit)
        XCTAssertNil(model.alert)
        model.undo()
        XCTAssertTrue(model.isEmpty)
    }

    func testPreviewIdentityIgnoresMetadataAndDetectsMediaChanges() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                      subdirectory: "Fixtures"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: fixture, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = CutEngine()
        let provisional = try engine.inspectForPreview(file)
        XCTAssertTrue(provisional.frames.isEmpty)
        XCTAssertEqual(file.path.withCString { chmod($0, 0o600) }, 0)
        let indexed = try engine.inspect(file, keyframes: true, matchingPreview: provisional)
        XCTAssertEqual(provisional.duration, indexed.duration)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertThrowsError(try engine.inspect(file, keyframes: true, matchingPreview: provisional)) {
            XCTAssertEqual(($0 as? CutError)?.code, "source_changed")
        }
    }

    @MainActor
    func testCancellingAnImportDiscardsItsProvisionalClip() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        model.useAnalysisSidecars = false
        defer { model.endSession() }
        let observation = model.$playhead.sink { _ in
            if model.isImporting, !model.isEmpty { model.cancelImport() }
        }
        defer { observation.cancel() }
        model.importFiles([file])
        try await waitForEdit(model)
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.hasHistory)
        XCTAssertFalse(model.isCancelling)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testRestoredSceneSnappingAcrossReorderedOccurrencesOfATrimmedSource() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let suite = "MPCut.SnapAudit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("scenes", forKey: "timelineSnapTarget")
        let model = EditorModel(defaults: defaults)
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.importFiles([file, file])
        try await waitForEdit(model)
        XCTAssertNil(model.sceneProgress)
        XCTAssertTrue(model.canScanScenes)
        model.scanForScenes()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.canScanScenes || model.sceneProgress != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.snapTarget, .scenes)
        XCTAssertEqual(model.scenesBySource.count, 1)
        let clips = model.timelineClips
        let first = try XCTUnwrap(clips.first), second = try XCTUnwrap(clips.last)
        let firstCut = 58.0 / 30, secondCut = 110.0 / 30
        XCTAssertEqual(try XCTUnwrap(model.trim(first.id, edge: .start, sourceTime: 1.85, commit: true)),
                       firstCut, accuracy: 1e-9)
        model.move(second.id, to: 0)
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.first?.id, second.id)
        let offset = second.sourceDuration
        model.seek(offset + 3.5 - firstCut)
        model.split()
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 3)
        let right = try XCTUnwrap(model.timelineClips.last)
        XCTAssertEqual(right.sourceStart, secondCut, accuracy: 1e-9)
        XCTAssertEqual(model.playhead, offset + secondCut - firstCut, accuracy: 1e-9)
        model.undo()
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(try XCTUnwrap(model.timelineClips.last).sourceStart, firstCut, accuracy: 1e-9)
        XCTAssertEqual(model.snapTarget, .scenes)

        // The next kept scene must win over an excluded marker just before a manual trim.
        model.snapTarget = .off
        let trimmed = try XCTUnwrap(model.trim(first.id, edge: .start, sourceTime: 2.2, commit: true))
        model.snapTarget = .scenes
        model.seek(offset + 0.05)
        model.setOut()
        XCTAssertEqual(try XCTUnwrap(model.markOut), offset + secondCut - trimmed, accuracy: 1e-9)
        model.seek(offset)
        model.setIn()
        XCTAssertEqual(model.markIn, offset)
    }

    @MainActor
    func testSilenceSnappingDropsPreviousTracksBoundaries() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.snapTarget = .silence
        model.importFiles([file])
        try await waitForEdit(model)
        func waitForPauses() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !model.pauseAnalysisReady, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(model.pauseAnalysisReady)
        }
        try await waitForPauses()
        model.deleteSelection()
        XCTAssertTrue(model.timelineClips.isEmpty)
        model.undo()
        try await waitForPauses()
        model.manualThresholdDB = -120
        try await waitForPauses()
        XCTAssertTrue(model.pausePlan.isEmpty)
        model.analysisTrack = 1
        try await waitForPauses()
        model.seek(1.26)
        model.split()
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.undo()
        model.analysisTrack = 0
        try await waitForPauses()
        model.seek(1.26)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertNotNil(model.alert)
    }

    @MainActor
    func testSceneSnapHonorsCancellationAndDeferredTargetSelection() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.importFiles([file])
        try await waitForEdit(model)
        model.scanForScenes()
        model.snapTarget = .scenes
        model.cancelSceneAnalysis()
        model.seek(1.0)
        model.split()
        model.dismissNotice()
        XCTAssertNil(model.sceneProgress)
        XCTAssertTrue(model.canScanScenes)

        model.snapTarget = .off
        XCTAssertTrue(model.canCloseVideo)
        model.isBulkQueuePresented = true
        XCTAssertFalse(model.canCloseVideo)
        model.snapTarget = .scenes
        XCTAssertNil(model.sceneProgress)
        model.isBulkQueuePresented = false
        model.bulkQueueDismissed()
        XCTAssertTrue(model.canCloseVideo)
        XCTAssertNil(model.sceneProgress)
        XCTAssertTrue(model.canScanScenes)
    }

    @MainActor
    func testImportManyMatchingClips() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let files = Array(repeating: source, count: 96)
        let model = EditorModel()
        defer { model.endSession() }
        var sawFirstDuringImport = false
        let observation = model.$playhead.sink { _ in
            if model.isImporting && model.timelineClips.count == 1 { sawFirstDuringImport = true }
        }
        defer { observation.cancel() }
        model.importFiles(files)
        try await waitForEdit(model)
        XCTAssertTrue(sawFirstDuringImport)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, files.count)
    }

    @MainActor
    func testMixedBatchKeepsCompatibleClipsAndReportsFailuresInDropOrder() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let incompatible = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                           subdirectory: "Fixtures"))
        let missing = source.deletingLastPathComponent().appendingPathComponent("missing.mov")
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        let original = try XCTUnwrap(model.selectedID)
        model.importFiles([incompatible, source, missing, source], at: 0)
        try await waitForEdit(model)
        let errors = try XCTUnwrap(model.alert).message.components(separatedBy: "\n\n")
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.first?.hasPrefix(incompatible.lastPathComponent) == true)
        XCTAssertTrue(errors.last?.hasPrefix(missing.lastPathComponent) == true)
        XCTAssertEqual(model.timelineClips.count, 3)
        XCTAssertEqual(model.timelineClips.last?.id, original)
        model.dismissNotice()
        model.undo()
        XCTAssertEqual(model.timelineClips.map(\.id), [original])
    }

    @MainActor
    func testOpenAlertBlocksPlainKeyEditsAndUndo() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        model.select(model.timelineClips[0].id)
        model.alert = EditorNotice(title: "Can’t Split Clip", message: "Test")
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.canDelete)
        XCTAssertFalse(model.canUndo)
        model.deleteSelection()
        model.setIn()
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertNil(model.markIn)
        model.dismissNotice()
        XCTAssertTrue(model.canDelete)
        model.deleteSelection()
        XCTAssertEqual(model.timelineClips.count, 1)
    }

    @MainActor
    func testSplitAtAJoinExplainsWhyNothingChanged() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        model.seek(model.duration / 2)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.alert?.title, "Can’t Split Clip")
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testEmptyingTheTimelineForgetsTheChosenCopyContainerButKeepsHistoryVisible() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        model.preferCopyContainer("mkv")
        XCTAssertEqual(model.preferredCopyContainer, "mkv")
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNotEqual(model.preferredCopyContainer, "mkv")
        XCTAssertTrue(model.hasHistory)
        model.undo()
        XCTAssertEqual(model.timelineClips.count, 1)
    }

    @MainActor
    func testUndoingToAnEmptyTimelineForgetsTheChosenCopyContainer() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        model.preferCopyContainer("mkv")
        model.undo()
        XCTAssertTrue(model.isEmpty)
        XCTAssertNotEqual(model.preferredCopyContainer, "mkv")
        model.redo()
        XCTAssertEqual(model.timelineClips.count, 1)
        model.preferCopyContainer("mkv")
        model.deleteSelection()
        try await waitForEdit(model)
        model.undo()
        model.preferCopyContainer("mkv")
        model.redo()
        XCTAssertTrue(model.isEmpty)
        XCTAssertNotEqual(model.preferredCopyContainer, "mkv")
    }

    @MainActor
    func testBackgroundHandleValidationCommitsOnlyLatestDragAndPreservesUndo() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                   subdirectory: "Fixtures"))
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        editor.importFiles([file])
        try await waitForEdit(editor)
        editor.snapTarget = .keyframes
        try await waitForEdit(editor)
        let clip = try XCTUnwrap(editor.timelineClips.first)
        let cut = clip.frames[3].seconds
        editor.validateHandle(clip.id, edge: .start, target: clip.frames[1].seconds, commit: false) { _ in
            XCTFail("A superseded drag published a handle")
        }
        var committed: Double?
        editor.validateHandle(clip.id, edge: .start, target: cut, commit: true) { committed = $0 }
        XCTAssertTrue(editor.isCheckingEdit)
        try await waitForEdit(editor)
        XCTAssertEqual(committed, cut)
        XCTAssertEqual(editor.timelineClips.first?.sourceStart, cut)
        XCTAssertEqual(editor.undoTitle, "Undo Trim Clip")
        editor.undo()
        XCTAssertEqual(editor.timelineClips.first?.sourceStart, clip.sourceStart)
    }

    @MainActor
    private func waitForEdit(_ model: EditorModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while model.isBusy, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if model.isBusy {
            throw TestError.editTimedOut
        }
    }
}
