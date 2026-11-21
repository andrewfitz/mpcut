import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamQueueAndAudioTests: XCTestCase {
    @MainActor
    func testQueueSnapshotsMarkedRangesAndChecksEntireBatch() async throws {
        let camera = try fixture("ProRes-2997", extension: "mov")
        let info = try CutEngine(useSidecar: false).inspectMulticamSource(camera)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: camera.path), media: info)],
                           opening: "wide", audio: .none)
        let end = info.frames[3].time
        model.markIn = end
        model.markOut = .zero
        XCTAssertTrue(model.canEnqueueMarkedRange)
        model.enqueueMarkedRange()
        XCTAssertNil(model.markIn)
        XCTAssertNil(model.markOut)
        XCTAssertNil(model.project?.assembly)
        XCTAssertTrue(model.enqueueRanges([.init(from: .zero, to: end)]))
        model.updateSource("wide") { $0.name = "Renamed camera" }
        XCTAssertNil(model.queuedRanges.first?.project.angles.first?.name)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = MulticamEngine()
        let batch = try MulticamBulkExport(ranges: model.queuedRanges, directory: directory, container: "mov",
                                           mode: .copy, tracks: .video, settings: .init(), engine: engine)
        XCTAssertEqual(batch.items.map(\.output.lastPathComponent), ["Multicam-001.mov", "Multicam-002.mov"])
        XCTAssertEqual(batch.items.map(\.plan.duration), [end, end])

        let sentinel = Data("keep".utf8)
        try sentinel.write(to: batch.items[1].output)
        XCTAssertThrowsError(try MulticamBulkExport(ranges: model.queuedRanges, directory: directory, container: "mov",
                                                      mode: .copy, tracks: .video, settings: .init(), engine: engine)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Range 2"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.items[0].output.path))
        XCTAssertEqual(try Data(contentsOf: batch.items[1].output), sentinel)
        try FileManager.default.removeItem(at: batch.items[1].output)
        model.exportQueuedRanges(to: directory, container: "mov", mode: .copy, tracks: .video)
        try await waitForOperation(model)
        XCTAssertTrue(batch.items.allSatisfy { FileManager.default.fileExists(atPath: $0.output.path) })
        XCTAssertEqual(model.queuedRanges.count, 2)
        model.removeQueuedRange(model.queuedRanges[0].id)
        XCTAssertEqual(model.queuedRanges.count, 1)
        model.reset()
        XCTAssertTrue(model.queuedRanges.isEmpty)
    }

    @MainActor
    func testRangeQueuedDuringIndexingKeepsItsRecordingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try fixture("ProRes-2997", extension: "mov")
        let camera = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: original, to: camera)
        let reader = CutEngine(useSidecar: false)
        let header = try reader.multicamClock(reader.inspectForPreview(camera))
        XCTAssertFalse(header.hasFullEditIndex)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: camera.path), media: header)],
                           opening: "wide", audio: .none)
        let end = RationalTime(numerator: 1001, denominator: 30000)
        XCTAssertTrue(model.enqueueRanges([.init(from: .zero, to: end)]))

        func preflight() throws -> MulticamBulkExport {
            try MulticamBulkExport(ranges: model.queuedRanges, directory: directory, container: "mov",
                                   mode: .copy, tracks: .video, settings: .init(), engine: MulticamEngine())
        }
        XCTAssertEqual(try preflight().items.first?.plan.duration, end)
        let replacement = directory.appendingPathComponent("replacement.mov")
        try FileManager.default.copyItem(at: original, to: replacement)
        _ = try FileManager.default.replaceItemAt(camera, withItemAt: replacement)
        XCTAssertNotEqual(try SourceIdentity(camera), header.identity)
        XCTAssertThrowsError(try preflight()) { error in
            XCTAssertEqual((error as? CutError)?.code, "source_changed")
        }
    }

    @MainActor
    func testReplaceSoundtrackUsesExplicitStreamAndUndoesOverrides() async throws {
        let camera = try fixture("Pause-Noisy", extension: "mov")
        let sound = try fixture("Standalone-Chirp", extension: "opus")
        let engine = CutEngine(useSidecar: false)
        let cameraInfo = try engine.inspectMulticamSource(camera)
        let cameraStreams = cameraInfo.audio.map(\.stream.index)
        XCTAssertGreaterThanOrEqual(cameraStreams.count, 2)
        let initial = MulticamAudioSelection(source: "wide", stream: try XCTUnwrap(cameraStreams.first))
        let next = MulticamAudioSelection(source: "wide", stream: try XCTUnwrap(cameraStreams.last))
        let model = MulticamEditorModel()
        model.useAnalysisSidecars = false
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: camera.path, audioStream: initial.stream),
                                          media: cameraInfo)], opening: "wide", audio: .follow)
        model.changeSwitch(.zero, audio: initial)
        XCTAssertFalse(model.replaceProgramAudio(with: .init(source: "wide", stream: -1)))
        XCTAssertTrue(model.replaceProgramAudio(with: next))
        XCTAssertEqual(model.project?.audio, .fixed(next))
        XCTAssertNil(model.project?.switches[0].audio)
        model.undo()
        XCTAssertEqual(model.project?.audio, .follow)
        XCTAssertEqual(model.project?.switches[0].audio, initial)

        model.addExternalSoundtrack(sound)
        try await waitForOperation(model)
        let external = try XCTUnwrap(model.project?.audioSources.first)
        XCTAssertEqual(external.file, sound.standardizedFileURL.path)
        XCTAssertEqual(model.project?.audio, .fixed(.init(source: external.id, stream: try XCTUnwrap(external.audioStream))))
        XCTAssertNil(model.project?.switches[0].audio)
        model.undo()
        XCTAssertTrue(model.project?.audioSources.isEmpty == true)
        XCTAssertEqual(model.project?.switches[0].audio, initial)
    }

    @MainActor
    func testExternalMovieStreamPersistsAndMatchesPreviewAndExport() async throws {
        let camera = try fixture("ProRes-2997", extension: "mov")
        let movie = try fixture("Pause-Noisy", extension: "mov")
        let engine = CutEngine(useSidecar: false)
        let cameraInfo = try engine.inspectMulticamSource(camera)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let donor = directory.appendingPathComponent("donor.mov")
        try FileManager.default.copyItem(at: movie, to: donor)

        let model = MulticamEditorModel()
        let reopened = MulticamEditorModel()
        defer { model.reset(); reopened.reset() }
        model.useAnalysisSidecars = false
        reopened.useAnalysisSidecars = false
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: camera.path), media: cameraInfo)],
                           opening: "wide", audio: .none)
        var indexed: MulticamEditorModel.SourceDraft?
        model.indexExternalSoundtrack(donor) { indexed = $0 }
        try await waitForOperation(model)
        let draft = try XCTUnwrap(indexed)
        XCTAssertTrue(draft.media.hasVideo)
        XCTAssertEqual(model.project?.audioSources, [])
        let selection = MulticamAudioSelection(source: draft.id, stream: 2)
        XCTAssertTrue(model.replaceProgramAudio(with: selection, external: draft))
        model.moveOffset(selection.source, by: 1)
        XCTAssertEqual(model.project?.audioSources.first?.offset, .init(numerator: 1, denominator: 16_000))
        model.undo()
        let interval = MulticamRange(from: .zero, to: .init(numerator: 32, denominator: 125))
        model.edit { $0.assembly = [interval] }
        let projectURL = directory.appendingPathComponent("edit.multicam.json")
        XCTAssertTrue(model.saveProject(to: projectURL))
        XCTAssertEqual(try MulticamProject.load(from: projectURL).audioSources.first?.file, "donor.mov")

        reopened.openProject(projectURL)
        try await waitForOperation(reopened)
        let deadline = ContinuousClock.now + .seconds(5)
        while reopened.media[selection.source]?.hasFullEditIndex != true && .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let project = try XCTUnwrap(reopened.project)
        XCTAssertEqual(project.angles.map(\.id), ["wide"])
        XCTAssertEqual(project.audio, .fixed(selection))
        let audio = try XCTUnwrap(project.plan().audio.first)
        let preview = try XCTUnwrap(MulticamPreviewAudioSpan(span: audio, media: reopened.media))
        XCTAssertEqual(preview.url, donor.standardizedFileURL)
        XCTAssertEqual(preview.ordinal, 1)
        XCTAssertEqual(preview.output, interval.from..<interval.to)
        let output = directory.appendingPathComponent("sound.mov")
        let exporter = MulticamEngine()
        let resolved = try exporter.resolve(project, output: output, mode: .copy, tracks: .audio)
        XCTAssertEqual(resolved.mapping.audio, [audio])
        XCTAssertEqual(resolved.audio.first?.tracks.map(\.index), [selection.stream])
        try exporter.write(resolved, to: output)
        XCTAssertEqual(try engine.inspect(output).audio.count, 1)

        let wrong = try fixture("Standalone-Multitrack", extension: "mov")
        reopened.relink(selection.source, to: wrong)
        let relinkDeadline = ContinuousClock.now + .seconds(5)
        while reopened.isBusy && .now < relinkDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(reopened.notice?.message.contains("missing selected audio stream") == true)
        XCTAssertEqual(reopened.project?.audioSources.first?.file, donor.path)
        reopened.notice = nil
        reopened.relink(selection.source, to: movie)
        try await waitForOperation(reopened)
        XCTAssertEqual(reopened.project?.audioSources.first?.file, movie.path)
        XCTAssertEqual(reopened.project?.audio, .fixed(selection))
        let first = MulticamAudioSelection(source: selection.source, stream: 1)
        XCTAssertTrue(reopened.replaceProgramAudio(with: first))
        XCTAssertEqual(reopened.project?.audio, .fixed(first))
    }

    @MainActor
    private func waitForOperation(_ model: MulticamEditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.notice)
    }

    private func fixture(_ name: String, extension ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }
}
