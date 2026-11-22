import AVFoundation
import Combine
import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class ReplacementAudioWorkflowTests: XCTestCase {
    func testMultipleTrackReplacementsAndUndoUseTheCorrectWorkingCopy() async throws {
        let source = try fixture("Pause-Noisy")
        let donor = try fixture("Pause-Quiet")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, donor, source])
        try await waitForWork(model)
        let clips = model.timelineClips
        model.seek(1)
        model.setIn()
        model.seek(2)
        model.setOut()
        model.seek(0)
        let marks = try XCTUnwrap(model.markedRange)
        XCTAssertEqual(model.analysisTrack, 0)

        let first = directory.appendingPathComponent("first.mov")
        let second = directory.appendingPathComponent("second.mov")
        let engine = AudioReplacementEngine(useSidecar: false)
        let secondaryTrack = try engine.resolve(source: source, replacement: donor, output: first,
                                                targetStream: 2, replacementStream: 2)
        model.applyReplacement(secondaryTrack, output: first, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.analysisTrack, 1)
        XCTAssertEqual(model.timelineClips.map(\.id), clips.map(\.id))
        XCTAssertEqual(model.timelineClips.map(\.sequenceRange), clips.map(\.sequenceRange))
        XCTAssertEqual(model.markedRange, marks)
        XCTAssertNotEqual(model.timelineClips[0].sourceID, clips[0].sourceID)
        XCTAssertEqual(model.timelineClips[0].sourceID, model.timelineClips[2].sourceID)
        XCTAssertEqual(model.timelineClips[1].sourceID, clips[1].sourceID)
        XCTAssertEqual(model.jpegSourceAtPlayhead?.media.url.path, first.path)
        let firstClip = try XCTUnwrap(model.timelineClips.first)
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.audioStore.finished.contains(firstClip.sourceID) && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let actual = try XCTUnwrap(model.audioStore.waves[firstClip.sourceID])
        let expected = try AudioAnalysis.scan(CutEngine().inspect(donor), stream: 2, useSidecar: false)
        XCTAssertEqual(actual.peak(from: 0.5, to: 1), expected.peak(from: 0.5, to: 1))

        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [1, nil, 1])
        let composition = try await SequencePreview.makeAudioComposition(model.preview.ranges)
        let nativeTrack = try XCTUnwrap(composition.tracks(withMediaType: .audio).first)
        let firstSegment = try XCTUnwrap(nativeTrack.segments.first { !$0.isEmpty })
        XCTAssertEqual(firstSegment.sourceURL?.path, first.path)
        let workingTracks = try await AVURLAsset(url: first).loadTracks(withMediaType: .audio)
        XCTAssertEqual(firstSegment.sourceTrackID, workingTracks[1].trackID)
        let reader = ScrubAudioReader()
        let window = 1.5..<1.55
        let playback = await reader.read(source: first, composition: composition, window: window,
                                         reverse: false, fadeEdges: false)
        let donorTracks = try await AVURLAsset(url: donor).loadTracks(withMediaType: .audio)
        let reference = await reader.read(source: donor, composition: nil, window: window,
                                          reverse: false, fadeEdges: false, presentationTrackID: donorTracks[1].trackID)
        let audible = try XCTUnwrap(playback).stereo
        XCTAssertGreaterThan(audible.map(abs).max() ?? 0, 0)
        XCTAssertEqual(audible, try XCTUnwrap(reference).stereo)
        model.chooseAnalysisTrack(0)
        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [0, 0, 0])
        model.monitorSourceAudio()
        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [1, nil, 1])
        XCTAssertEqual(model.sourceAnalysisTracks[firstClip.sourceID], 1)
        let untouchedID = clips[1].sourceID
        XCTAssertEqual(model.sourceAnalysisTracks[untouchedID], 0)
        let waveformDeadline = ContinuousClock.now + .seconds(5)
        while !model.audioStore.finished.contains(untouchedID) && .now < waveformDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let untouched = try XCTUnwrap(model.audioStore.waves[untouchedID])
        let originalWave = try AudioAnalysis.scan(CutEngine().inspect(donor), stream: 1, useSidecar: false)
        XCTAssertEqual(untouched.peak(from: 0.5, to: 1), originalWave.peak(from: 0.5, to: 1))
        model.seek(try XCTUnwrap(clips[1].sequenceRange).lowerBound)
        XCTAssertEqual(model.jpegSourceAtPlayhead?.audioStream, 1)
        model.seek(0)
        model.chooseAnalysisTrack(1)
        XCTAssertFalse(model.useSavedMonitoringTracks)
        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [1, 1, 1])

        let primaryTrack = try engine.resolve(source: first, replacement: source, output: second,
                                              targetStream: 1, replacementStream: 2)
        model.applyReplacement(primaryTrack, output: second, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.analysisTrack, 0)
        let label = try XCTUnwrap(model.timelineClips.first?.stripLabel)
        XCTAssertTrue(label.contains(source.lastPathComponent))
        XCTAssertTrue(label.contains(donor.lastPathComponent))

        model.undo()
        XCTAssertEqual(model.analysisTrack, 1)
        XCTAssertFalse(model.useSavedMonitoringTracks)
        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [1, 1, 1])
        XCTAssertEqual(model.jpegSourceAtPlayhead?.media.url.path, first.path)
        model.undo()
        XCTAssertEqual(model.analysisTrack, 0)
        XCTAssertTrue(model.useSavedMonitoringTracks)
        XCTAssertEqual(model.timelineClips.map(\.sourceID), clips.map(\.sourceID))
        model.redo()
        XCTAssertEqual(model.analysisTrack, 1)
        XCTAssertFalse(model.useSavedMonitoringTracks)
        model.redo()
        XCTAssertEqual(model.analysisTrack, 0)
        XCTAssertTrue(model.useSavedMonitoringTracks)
        XCTAssertEqual(model.jpegSourceAtPlayhead?.media.url.path, second.path)
    }

    func testAudioOnlyReplacementSelectsDonorStreamAndKeepsBothTracks() async throws {
        let source = try fixture("Standalone-Multitrack")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("working.mov")
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForWork(model)
        XCTAssertTrue(model.canReplaceSourceAudio)
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(
            source: source, replacement: source, output: output, targetStream: 1, replacementStream: 0)
        model.applyReplacement(plan, output: output, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNil(model.alert, model.alert?.message ?? "")
        XCTAssertEqual(model.preview.ranges.first?.url.path, output.path)
        XCTAssertEqual(model.preview.ranges.first?.audioTrack, 1)
        XCTAssertEqual(model.audioTracks.count, 2)
        model.undo()
        XCTAssertEqual(model.preview.ranges.first?.url.path, source.path)
    }

    func testReopeningFollowsEachSavedTrackWithoutChangingOtherSources() async throws {
        let first = try fixture("Standalone-Multitrack")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("second.mov")
        try FileManager.default.copyItem(at: first, to: second)
        let end = RationalTime(numerator: 1, denominator: 10)
        let clips = [CutSequenceClip(id: "secondary", file: first.path, from: .zero, to: end, audioTrack: 1),
                     CutSequenceClip(id: "untouched", file: second.path, from: .zero, to: end)]
        let model = EditorModel()
        defer { model.endSession() }
        try model.openProject(clips, at: directory.appendingPathComponent("edit.cut"))
        try await waitForWork(model)
        XCTAssertNil(model.alert)
        XCTAssertTrue(model.useSavedMonitoringTracks)
        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [1, 0])
        let timeline = model.timelineClips
        let secondClip = try XCTUnwrap(timeline.dropFirst().first)
        let ids = timeline.map(\.sourceID)
        XCTAssertEqual(ids.map { model.sourceAnalysisTracks[$0] }, [1, 0])
        model.chooseAnalysisTrack(1, forClip: UUID())
        model.chooseAnalysisTrack(2, forClip: secondClip.id)
        XCTAssertTrue(model.useSavedMonitoringTracks)
        model.chooseAnalysisTrack(1, forClip: secondClip.id)
        XCTAssertEqual(model.selectedID, secondClip.id)
        XCTAssertEqual(model.playhead, try XCTUnwrap(secondClip.sequenceRange).lowerBound)
        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [1, 1])
        XCTAssertEqual(ids.map { model.sourceAnalysisTracks[$0] }, [1, 1])
        XCTAssertEqual(model.playheadAnalysisTrack, 1)
        model.monitorSourceAudio()
        XCTAssertEqual(model.preview.ranges.map(\.audioTrack), [1, 0])
        XCTAssertEqual(model.playheadAnalysisTrack, 0)
    }

    func testReplacementWithDifferentCodecReopensAndRestoresHistory() async throws {
        let original = try fixture("Pause-Quiet")
        let untouched = try fixture("Pause-Noisy")
        let directory = try workDirectory()
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
        let working = directory.appendingPathComponent("working.mov")
        let document = directory.appendingPathComponent("edit.cut")
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        model.importFiles([original, untouched])
        try await waitForWork(model)
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(
            source: original, replacement: donor, output: working, targetStream: 2, replacementStream: 0)
        model.applyReplacement(plan, output: working, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.sequenceClips.map(\.file), [working.path, untouched.path])
        let engine = CutEngine(useSidecar: false)
        let workingMedia = try engine.inspect(working)
        let untouchedMedia = try engine.inspect(untouched)
        XCTAssertEqual(workingMedia.audio.map { $0.stream.codec }, ["aac", "pcm_s16le"])
        XCTAssertThrowsError(try engine.checkCompatibility(workingMedia, with: untouchedMedia))
        try model.writeProject(to: document)

        let saved = try CutProject.loadDocument(from: document, limit: 100)
        guard case let .sequence(clips) = saved.project else { return XCTFail("Expected a saved sequence") }
        let reopened = EditorModel(preferences: preferences)
        defer { reopened.endSession() }
        try reopened.openProject(clips, at: document)
        try await waitForWork(reopened)
        XCTAssertNil(reopened.alert)
        XCTAssertEqual(reopened.preview.ranges.map(\.audioTrack), [1, nil])
        XCTAssertEqual(reopened.sequenceClips.map(\.file), [working.path, untouched.path])
        reopened.undo()
        try await waitForWork(reopened)
        XCTAssertNil(reopened.alert)
        XCTAssertEqual(reopened.sequenceClips.map(\.file), [original.path, untouched.path])
        reopened.redo()
        try await waitForWork(reopened)
        XCTAssertNil(reopened.alert)
        XCTAssertEqual(reopened.sequenceClips.map(\.file), [working.path, untouched.path])
        XCTAssertEqual(reopened.preview.ranges.map(\.audioTrack), [1, nil])
        let sibling = directory.appendingPathComponent("another.mov")
        try FileManager.default.copyItem(at: untouched, to: sibling)
        reopened.importFiles([sibling], allowCommit: { true })
        try await waitForWork(reopened)
        XCTAssertNil(reopened.alert)
        XCTAssertEqual(reopened.sequenceClips.map(\.file), [working.path, untouched.path, sibling.path])
    }

    func testRejectsAPlanForNewFileContentsOverAnOlderTimelineSource() async throws {
        let source = try fixture("Pause-Noisy")
        let donor = try fixture("Pause-Quiet")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changingFile = directory.appendingPathComponent("source.mov")
        try FileManager.default.copyItem(at: source, to: changingFile)
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([changingFile])
        try await waitForWork(model)
        let timelineSource = try XCTUnwrap(model.timelineClips.first?.sourceID)

        let moved = directory.appendingPathComponent("old.mov")
        try FileManager.default.moveItem(at: changingFile, to: moved)
        try FileManager.default.copyItem(at: source, to: changingFile)
        let output = directory.appendingPathComponent("working.mov")
        let engine = AudioReplacementEngine(useSidecar: false)
        let plan = try engine.resolve(source: changingFile, replacement: donor, output: output)
        model.applyReplacement(plan, output: output, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceID, timelineSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCommitRejectsAWorkingCopySwappedAfterIndexing() async throws {
        let source = try fixture("Pause-Noisy")
        let donor = try fixture("Pause-Quiet")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("working.mov")
        let saved = directory.appendingPathComponent("previous.mov")
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForWork(model)
        let original = model.sequenceClips
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(source: source, replacement: donor, output: output)
        model.applyReplacement(plan, output: output, useSidecar: false, validateCommit: {
            try FileManager.default.moveItem(at: output, to: saved)
            try FileManager.default.copyItem(at: source, to: output)
        })
        try await waitForWork(model)
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(model.sequenceClips, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testCancelLeavesTheTimelineAndDestinationUntouched() async throws {
        let source = try fixture("Pause-Noisy")
        let donor = try fixture("Pause-Quiet")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("working.mov")
        let engine = AudioReplacementEngine(useSidecar: false)
        let plan = try engine.resolve(source: source, replacement: donor, output: output)
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForWork(model)
        model.applyReplacement(plan, output: output, useSidecar: false)
        model.cancelExport()
        try await waitForWork(model)
        XCTAssertNil(model.alert)
        XCTAssertNil(model.timelineClips.first?.replacementAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancellationAfterPublicationKeepsTheSavedWorkingCopy() async throws {
        let source = try fixture("Pause-Noisy")
        let donor = try fixture("Pause-Quiet")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("working.mov")
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(source: source, replacement: donor, output: output)
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForWork(model)
        let cancel = model.$exportProgress.sink { progress in
            if progress == 0.8 { model.cancelExport() }
        }
        defer { cancel.cancel() }
        model.applyReplacement(plan, output: output, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNil(model.alert)
        XCTAssertNil(model.timelineClips.first?.replacementAudio)
        XCTAssertTrue(model.statusMessage.contains(output.lastPathComponent))
        XCTAssertEqual(try CutEngine().inspect(output).audio.count, 2)
    }

    func testIndexingRejectsAFileSwappedInAfterPublication() async throws {
        let source = try fixture("Pause-Noisy")
        let donor = try fixture("Pause-Quiet")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("working.mov")
        let saved = directory.appendingPathComponent("saved.mov")
        let impostor = try Data(contentsOf: source)
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(source: source, replacement: donor, output: output)
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForWork(model)
        let replacePublishedFile = model.$exportProgress.sink { progress in
            guard progress == 0.8 else { return }
            do {
                try FileManager.default.moveItem(at: output, to: saved)
                try impostor.write(to: output, options: .withoutOverwriting)
            } catch {
                XCTFail(error.localizedDescription)
            }
        }
        defer { replacePublishedFile.cancel() }
        model.applyReplacement(plan, output: output, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNotNil(model.alert)
        XCTAssertNil(model.timelineClips.first?.replacementAudio)
        XCTAssertEqual(try Data(contentsOf: output), impostor)
        XCTAssertEqual(try CutEngine().inspect(saved).audio.count, 2)
    }

    func testDestinationCreatedAfterPlanningIsPreserved() async throws {
        let source = try fixture("Pause-Noisy")
        let donor = try fixture("Pause-Quiet")
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("working.mov")
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(source: source, replacement: donor, output: output)
        let existing = Data("Existing file".utf8)
        try existing.write(to: output)
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForWork(model)
        model.applyReplacement(plan, output: output, useSidecar: false)
        try await waitForWork(model)
        XCTAssertNotNil(model.alert)
        XCTAssertNil(model.timelineClips.first?.replacementAudio)
        XCTAssertEqual(try Data(contentsOf: output), existing)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures"))
    }

    private func workDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func waitForWork(_ model: EditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
    }
}
