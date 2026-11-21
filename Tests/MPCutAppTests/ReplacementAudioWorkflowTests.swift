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
        XCTAssertEqual(model.jpegSourceAtPlayhead?.media.url.path, first.path)
        model.undo()
        XCTAssertEqual(model.analysisTrack, 0)
        XCTAssertEqual(model.timelineClips.map(\.sourceID), clips.map(\.sourceID))
        model.redo()
        XCTAssertEqual(model.analysisTrack, 1)
        model.redo()
        XCTAssertEqual(model.analysisTrack, 0)
        XCTAssertEqual(model.jpegSourceAtPlayhead?.media.url.path, second.path)
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
