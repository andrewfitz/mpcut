import AppKit
import AVFoundation
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

final class AudioEditorTests: XCTestCase {
    private func recording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 144_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) {
            samples[i] = (48_000..<96_000).contains(i) ? 0 : 0.5 * sin(2 * .pi * Float(i % 96) / 96)
        }
        try file.write(from: buffer)
        return url
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(7)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { throw NSError(domain: "AudioEditor timeout", code: 1) }
    }

    @MainActor
    func testStandaloneAudioUsesSampleBoundariesForEditsAndExistingTransport() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        model.preview.isMuted = true
        model.snapTarget = .keyframes
        defer { model.endSession() }
        model.importFiles([url])
        try await wait { !model.isImporting }
        XCTAssertNil(model.alert, model.alert?.message ?? "")
        XCTAssertTrue(model.isAudioOnly)
        XCTAssertFalse(model.hasPicture)
        XCTAssertTrue(try XCTUnwrap(model.timelineClips.first).isAudioOnly)
        XCTAssertEqual(model.effectiveSnapTarget, .off)
        XCTAssertFalse(model.canScanScenes)
        XCTAssertNil(model.jpegSourceAtPlayhead)
        XCTAssertEqual(model.duration, 3, accuracy: 1.0 / 48_000)

        model.seek(1)
        model.step(1)
        XCTAssertEqual(model.playhead, 48_001.0 / 48_000, accuracy: 1e-12)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 2)
        let last = try XCTUnwrap(model.timelineClips.last)
        model.move(last.id, to: 0)
        XCTAssertEqual(try XCTUnwrap(model.audioPreviewSourceTime), last.sourceStart, accuracy: 1e-12)
        model.undo()
        model.undo()
        XCTAssertEqual(model.timelineClips.count, 1)

        model.seek(0.650003)
        model.setIn()
        model.seek(0.85)
        model.setOut()
        model.deleteSelection()
        XCTAssertEqual(model.duration, 2.8, accuracy: 1e-9)
        model.undo()
        model.seek(1.1)
        try await wait {
            if model.preview.playbackRate == 0 { model.preview.shuttle(1) }
            return model.playhead > 1.14
        }
        model.preview.shuttle(-1)
        let after = model.playhead
        try await wait { model.playhead < after - 0.03 }
        model.preview.pause()
        XCTAssertNil(model.preview.issue)
    }

    @MainActor
    func testMP3ClockDrivesForwardAndReverseAcrossNativeAudioJoin() async throws {
        let wav = try recording()
        defer { try? FileManager.default.removeItem(at: wav) }
        let mp3 = try XCTUnwrap(Bundle.module.url(forResource: "Gapless-Crop", withExtension: "mp3", subdirectory: "Fixtures"))
        let media = try [wav, mp3].map { try CutEngine().inspect($0) }
        let ranges = media.map { PreviewRange(media: $0, from: .zero, to: .init(numerator: 1, denominator: 5)) }
        let preview = SequencePreview()
        preview.isMuted = true
        defer { preview.pause() }
        preview.update(ranges, at: 0.11)
        // The whole sequence must immediately use the indexed packet clock.
        // A pending asynchronous AVAsset composition would consume MPEG-2
        // decoder delay in the audible timeline when it reaches the MP3.
        preview.shuttle(1)
        XCTAssertEqual(preview.playbackRate, 1)
        try await wait { preview.time > 0.24 || preview.issue != nil }
        XCTAssertNil(preview.issue)
        preview.shuttle(-1)
        XCTAssertEqual(preview.playbackRate, -1)
        try await wait { preview.time < 0.16 || preview.issue != nil }
        XCTAssertNil(preview.issue)
        XCTAssertNil(preview.audioWarning)
    }

    @MainActor
    func testAudioOnlySilenceSnappingAndShortening() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([url])
        try await wait { !model.isImporting }
        XCTAssertNil(model.alert, model.alert?.message ?? "")
        model.minimumPause = 0.5
        model.padding = 0.1
        model.snapTarget = .silence
        try await wait { model.pauseAnalysisReady }
        XCTAssertEqual(model.shortenedPauseCount, 1)
        XCTAssertEqual(model.timelinePadding.count, 2)
        for edge in model.timelinePadding {
            XCTAssertEqual(edge.to.seconds - edge.from.seconds, 0.1, accuracy: 0.001)
        }
        model.padding = 0
        XCTAssertTrue(model.timelinePadding.isEmpty)
        model.padding = 0.1
        model.seek(1.12)
        model.setIn()
        XCTAssertEqual(try XCTUnwrap(model.markIn), 1, accuracy: 0.021)
        model.clearMarks()
        let originalID = try XCTUnwrap(model.sequenceClips.first?.id)
        XCTAssertTrue(model.applyPauses(queueTakes: false))
        XCTAssertEqual(model.duration, 2.2, accuracy: 0.041)
        XCTAssertNil(model.alert, model.alert?.message ?? "")
        XCTAssertEqual(model.sequenceClips.first?.id, originalID)
        XCTAssertEqual(Set(model.sequenceClips.map(\.id)).count, 2)
        XCTAssertEqual(model.sequenceClips.map(\.id.count), [ProjectIdentifier.length, ProjectIdentifier.length])
        let pieces = model.timelineClips
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].sourceEnd * 48_000, (pieces[0].sourceEnd * 48_000).rounded(), accuracy: 1e-8)
        model.undo()
        XCTAssertEqual(model.duration, 3, accuracy: 1e-9)
    }

    @MainActor
    func testShortenedAudioRecoveryAndSavedHistoryReopenWithUniqueClipIDs() async throws {
        let source = try recording()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = directory.appendingPathComponent("Shortened.cut")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let draft = ProjectDraft(directory: directory.appendingPathComponent("Recovery"))
        let model = EditorModel(preferences: EditorPreferences(), draft: draft)
        let reopened = EditorModel()
        defer {
            model.endSession()
            reopened.endSession()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: source)
        }
        model.useAnalysisSidecars = false
        reopened.useAnalysisSidecars = false
        model.minimumPause = 0.5
        model.padding = 0.1
        model.importFiles([source])
        try await wait { model.canEdit }
        let original = try XCTUnwrap(model.sequenceClips.first)
        model.scanForSilence()
        try await wait { model.pauseAnalysisReady }
        XCTAssertTrue(model.applyPauses(queueTakes: false))
        try await wait { !draft.hasScheduledWrites }
        XCTAssertNil(model.alert)
        let expected = model.sequenceClips
        XCTAssertEqual(expected.count, 2)
        XCTAssertEqual(expected.first?.id, original.id)
        XCTAssertEqual(Set(expected.map(\.id)).count, 2)
        let left = try XCTUnwrap(expected.first)
        let right = try XCTUnwrap(expected.last)
        XCTAssertEqual(left.from, original.from)
        XCTAssertLessThan(left.to, right.from)
        XCTAssertEqual(right.to, original.to)
        let recovery = try CutProject.loadDocument(from: XCTUnwrap(draft.url), limit: 10)
        XCTAssertEqual(recovery.project.sequenceClips?.map(\.id), expected.map(\.id))
        XCTAssertEqual(recovery.undo.last?.project.sequenceClips?.map(\.id), [original.id])

        try model.writeProject(to: saved)
        try reopened.openProject(try XCTUnwrap(CutProject.load(from: saved).sequenceClips), at: saved)
        try await wait { reopened.canEdit }
        XCTAssertEqual(reopened.sequenceClips, expected)
        reopened.undo()
        try await wait { reopened.sequenceClips == [original] || reopened.alert != nil }
        XCTAssertEqual(reopened.sequenceClips, [original])
        XCTAssertNil(reopened.alert)
        reopened.redo()
        try await wait { reopened.sequenceClips == expected || reopened.alert != nil }
        XCTAssertEqual(reopened.sequenceClips, expected)
        XCTAssertNil(reopened.alert)
    }

    @MainActor
    func testUndoRestoresCompletedPausesAfterDeletingLastOccurrence() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.minimumPause = 0.5
        model.importFiles([url])
        try await wait { model.canEdit }
        model.scanForSilence()
        try await wait { model.pauseAnalysisReady }
        let detected = model.pausePlan.map(\.sequence)
        XCTAssertEqual(detected.count, 1)
        model.seek(1.5)
        model.protectCurrentPause()
        model.deleteSelection()
        XCTAssertTrue(model.isEmpty)
        model.undo()
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertEqual(model.pausePlan.map(\.sequence), detected)
        XCTAssertEqual(model.currentPause?.isProtected, true)
    }

    @MainActor
    func testCSVRepeatInheritsPauseProtectionAndCanChangeIndependently() async throws {
        let url = try recording()
        let csv = url.appendingPathExtension("csv")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: csv)
        }
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.minimumPause = 0.5
        model.importFiles([url])
        try await wait { model.canEdit }
        model.scanForSilence()
        try await wait { model.pauseAnalysisReady }
        model.seek(1.5)
        model.protectCurrentPause()
        try "0,3\n0,3".write(to: csv, atomically: true, encoding: .utf8)
        model.dropOnViewer([csv])
        try await wait { model.canEdit }
        XCTAssertEqual(model.pausePlan.map(\.isProtected), [true, true])
        model.seek(4.5)
        model.protectCurrentPause()
        XCTAssertEqual(model.pausePlan.map(\.isProtected), [true, false])
    }

    @MainActor
    func testKeepFromCutPreviewTargetsTheReviewedPause() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.minimumPause = 0.5
        model.importFiles([url, url])
        try await wait { model.canEdit }
        model.scanForSilence()
        try await wait { model.pauseAnalysisReady }
        XCTAssertEqual(model.pausePlan.count, 2)
        model.seek(1.5)
        model.previewCurrentCut()
        let reviewed = try XCTUnwrap(model.cutPreview?.position)
        // An in-flight main preview update can move the reported playhead while
        // the audition still shows the original cut.
        model.preview.seek(to: 4.5)
        XCTAssertGreaterThan(try XCTUnwrap(model.currentPause?.sequence.from), reviewed)
        model.advanceCutPreview(keepingCurrent: true)
        XCTAssertEqual(model.pausePlan.map(\.isProtected), [true, false])
        XCTAssertGreaterThan(try XCTUnwrap(model.cutPreview?.position), reviewed)
        XCTAssertEqual(model.shortenedPauseCount, 1)
        model.endSession()
        XCTAssertEqual(model.shortenedPauseCount, 0)
        XCTAssertEqual(model.removedPauseSeconds, 0)
    }

    @MainActor
    func testPauseDurationOverrideFollowsOnlyTheSelectedOccurrence() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.minimumPause = 0.5
        model.padding = 0.1
        model.importFiles([url, url])
        try await wait { model.canEdit }
        model.scanForSilence()
        try await wait { model.pauseAnalysisReady }
        XCTAssertEqual(model.pausePlan.count, 2)
        let first = try XCTUnwrap(model.pausePlan.first)
        XCTAssertTrue(model.setPauseRetainedDuration(0.6, for: first.key))
        XCTAssertFalse(model.setPauseRetainedDuration(-0.1, for: first.key))
        XCTAssertEqual(model.pausePlan[0].retainedSeconds, 0.6, accuracy: 0.001)
        XCTAssertEqual(model.pausePlan[1].retainedSeconds, 0.2, accuracy: 0.001)

        let repeated = try XCTUnwrap(model.timelineClips.last)
        model.move(repeated.id, to: 0)
        XCTAssertNil(model.pausePlan[0].requestedRetainedSeconds)
        XCTAssertEqual(model.pausePlan[1].requestedRetainedSeconds, 0.6)
        model.seek(4.5)
        model.protectCurrentPause()
        XCTAssertNil(model.pausePlan[1].removal)
        model.protectCurrentPause()

        model.minimumPause = 1.5
        try await wait { model.pauseAnalysisReady }
        XCTAssertTrue(model.pausePlan.isEmpty)
        model.minimumPause = 0.5
        try await wait { model.pauseAnalysisReady }
        XCTAssertEqual(model.pausePlan[1].requestedRetainedSeconds, 0.6)

        XCTAssertTrue(model.applyPauses(queueTakes: false))
        XCTAssertEqual(model.duration, 4.8, accuracy: 0.05)
    }

    @MainActor
    func testManualTakeBoundaryDoesNotCutTheSequenceAndQueuesExactPieces() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.minimumPause = 0.5
        model.padding = 0
        model.importFiles([url])
        try await wait { model.canEdit }
        model.scanForSilence()
        try await wait { model.pauseAnalysisReady }
        XCTAssertEqual(model.takeCandidates.count, 2)
        XCTAssertFalse(model.addTakeBoundary(at: 1.5))
        XCTAssertTrue(model.addTakeBoundary(at: 0.5))
        XCTAssertFalse(model.addTakeBoundary(at: 0.5))
        let manual = try XCTUnwrap(model.takeCandidates.first(where: \.hasManualStart))
        XCTAssertEqual(manual.range.from, RationalTime(numerator: 1, denominator: 2))
        XCTAssertTrue(model.removeTakeBoundary(at: manual.range.from))
        XCTAssertEqual(model.takeCandidates.count, 2)
        XCTAssertTrue(model.addTakeBoundary(at: 0.5))
        model.seek(1.5)
        model.protectCurrentPause()
        XCTAssertEqual(model.shortenedPauseCount, 0)
        XCTAssertTrue(model.applyPauses(queueTakes: true))
        XCTAssertEqual(model.queuedRanges.count, 2)
        XCTAssertEqual(model.queuedRanges.map(\.start), [.zero, manual.range.from])
        XCTAssertEqual(model.queuedRanges.map(\.end), [manual.range.from, .init(numerator: 3)])
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.duration, 3)
    }

    @MainActor
    func testExistingJoinPreviewNeedsNoSilenceScanAndPreservesEdit() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        model.importFiles([url])
        try await wait { model.canEdit }
        model.seek(0.5)
        model.split()
        let clips = model.timelineClips.map(\.id)
        XCTAssertEqual(clips.count, 2)
        XCTAssertFalse(model.previewExistingJoin(before: clips[0]))
        XCTAssertTrue(model.previewExistingJoin(before: clips[1]))
        let cut = try XCTUnwrap(model.cutPreview)
        XCTAssertNil(cut.pauseKey)
        XCTAssertEqual(cut.position, RationalTime(numerator: 1, denominator: 2))
        XCTAssertEqual(cut.ranges.map(\.start), [0, 0.5])
        XCTAssertEqual(cut.ranges.map(\.end), [0.5, 1.5])
        model.advanceCutPreview(keepingCurrent: true)
        XCTAssertEqual(model.cutPreview?.id, cut.id)
        model.cutPreview = nil
        XCTAssertEqual(model.timelineClips.map(\.id), clips)
        XCTAssertEqual(model.duration, 3)
    }

    @MainActor
    func testJoinPreviewAcceptsSavedSequenceItemID() async throws {
        let url = try recording()
        let project = url.deletingPathExtension().appendingPathExtension("cut")
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: url)
        }
        let half = RationalTime(numerator: 1, denominator: 2)
        let clips = [
            CutSequenceClip(id: "left", file: url.path, from: .zero, to: half),
            CutSequenceClip(id: "right", file: url.path, from: half, to: .init(numerator: 3))
        ]
        try CutProject.sequence(clips).save(to: project)
        let model = EditorModel()
        model.useAnalysisSidecars = false
        defer { model.endSession() }
        try model.openProject(clips, at: project)
        try await wait { model.canEdit }
        XCTAssertTrue(model.previewExistingJoin(beforeTimelineItem: "right"))
        XCTAssertEqual(model.cutPreview?.position, half)
        model.cutPreview = nil
        XCTAssertTrue(model.previewExistingJoin(beforeTimelineItem: try XCTUnwrap(model.mcpClipIDs.last).uuidString))
        XCTAssertEqual(model.cutPreview?.position, half)
    }

    @MainActor
    func testRangeInsertionPreservesPauseOverrideOnRetainedFragmentOnly() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel()
        model.useAnalysisSidecars = false
        model.minimumPause = 0.5
        defer { model.endSession() }
        model.importFiles([url])
        try await wait { model.canEdit }
        model.scanForSilence()
        try await wait { model.pauseAnalysisReady }
        XCTAssertTrue(model.setPauseRetainedDuration(0.6, for: try XCTUnwrap(model.pausePlan.first).key))
        let half = RationalTime(numerator: 1, denominator: 2)
        let range = try SequenceSourceRange(file: url.path, from: .zero, to: .init(numerator: 3))
        try await model.applySourceRanges([range], destination: .init(from: half, to: half), expectedRevision: model.mcpRevision)
        try await wait { model.pauseAnalysisReady && model.pausePlan.count == 2 }
        XCTAssertNil(model.pausePlan.first?.requestedRetainedSeconds)
        XCTAssertEqual(model.pausePlan.last?.requestedRetainedSeconds, 0.6)
    }

    @MainActor
    func testAudioPreviewNoticeUpdatesWithoutPlayheadMovement() async throws {
        _ = NSApplication.shared
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let media = try CutEngine().inspect(url)
        let preview = SequencePreview()
        let host = NSHostingView(rootView: AudioPreviewNotice(preview: preview))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 450, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer { window.close(); preview.update([], at: 0) }
        XCTAssertEqual(host.fittingSize.height, 0)

        try FileManager.default.removeItem(at: url)
        preview.update([PreviewRange(media: media, from: .zero, to: media.duration)], at: 0)
        try await wait {
            if preview.issue != nil || preview.audioWarning != nil { return true }
            if !preview.isPlaying { preview.shuttle(1) }
            return false
        }
        try await wait { host.fittingSize.height > 0 }
        XCTAssertEqual(preview.time, 0)
    }
}
