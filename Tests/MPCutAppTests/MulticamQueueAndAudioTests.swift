import AVFoundation
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
        XCTAssertEqual(batch.items.map(\.duration), [end, end])

        let sentinel = Data("keep".utf8)
        try sentinel.write(to: batch.items[1].output)
        XCTAssertThrowsError(try MulticamBulkExport(ranges: model.queuedRanges, directory: directory, container: "mov",
                                                      mode: .copy, tracks: .video, settings: .init(), engine: engine)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Range 2"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.items[0].output.path))
        XCTAssertEqual(try Data(contentsOf: batch.items[1].output), sentinel)
        try FileManager.default.removeItem(at: batch.items[1].output)
        model.exportQueuedRanges(to: directory, container: "mov", mode: .copy, tracks: .video,
                                 organization: .init(subfolder: "Review", baseName: "Concert"))
        try await waitForOperation(model)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Review").path)
        XCTAssertEqual(files.sorted(), ["Concert-001.mov", "Concert-002.mov"])
        XCTAssertEqual(model.queuedRanges.count, 2)
        model.removeQueuedRange(model.queuedRanges[0].id)
        XCTAssertEqual(model.queuedRanges.count, 1)
        model.reset()
        XCTAssertTrue(model.queuedRanges.isEmpty)
    }

    @MainActor
    func testPauseTakeKeepsEveryOverlappingAssemblyRange() throws {
        let camera = try fixture("ProRes-2997", extension: "mov")
        let info = try CutEngine(useSidecar: false).inspectMulticamSource(camera)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: camera.path), media: info)],
                           opening: "wide", audio: .none)
        let ranges = [MulticamRange(from: .zero, to: info.frames[2].time),
                      MulticamRange(from: info.frames[4].time, to: info.frames[6].time)]
        XCTAssertTrue(model.edit { $0.assembly = ranges })
        let duration = try XCTUnwrap(model.project).plan().duration
        XCTAssertTrue(model.enqueuePauseTakes([.init(from: .zero, to: duration)]))
        let queued = try XCTUnwrap(model.queuedRanges.first)
        XCTAssertEqual(queued.snapshot.assembly, ranges)
        XCTAssertEqual(try queued.snapshot.plan().duration, duration)
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

        let organization = ExportOrganization(subfolder: "Review")
        func preflight() throws -> MulticamBulkExport {
            try MulticamBulkExport(ranges: model.queuedRanges, directory: directory, container: "mov",
                                   mode: .copy, tracks: .video, settings: .init(), organization: organization, engine: MulticamEngine())
        }
        XCTAssertEqual(try preflight().items.first?.duration, end)
        let folder = directory.appendingPathComponent("Review", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertThrowsError(try organization.validateSubfolder(in: directory, protectedMedia: [folder.path: "offline"]))
        if try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
            let offline = directory.appendingPathComponent("review/multicam-001.mov")
            let output = try XCTUnwrap(preflight().items.first?.output)
            XCTAssertThrowsError(try CutProject.validateMediaDestination(output, absoluteSources: [offline.path: "offline"]))
        }
        let replacement = directory.appendingPathComponent("replacement.mov")
        try FileManager.default.copyItem(at: original, to: replacement)
        _ = try FileManager.default.replaceItemAt(camera, withItemAt: replacement)
        XCTAssertNotEqual(try SourceIdentity(camera), header.identity)
        XCTAssertThrowsError(try preflight()) { error in
            XCTAssertEqual((error as? CutError)?.code, "source_changed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
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
    func testChangedDonorCannotReplaceOrRebindTheProgramSoundtrack() async throws {
        let camera = try fixture("Pause-Noisy", extension: "mov")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let donor = directory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: camera, to: donor)
        let info = try CutEngine(useSidecar: false).inspectMulticamSource(donor)
        let source = MulticamSource(id: "camera", file: donor.path)
        let draft = MulticamEditorModel.SourceDraft(source: source, media: info)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [draft], opening: source.id, audio: .none)
        let generation = model.mcpRevision
        let selection = MulticamAudioSelection(source: source.id, stream: try XCTUnwrap(info.audio.last?.stream.index))
        try FileManager.default.moveItem(at: donor, to: directory.appendingPathComponent("previous.mov"))
        try FileManager.default.copyItem(at: camera, to: donor)
        XCTAssertFalse(model.replaceProgramAudio(with: selection))
        XCTAssertFalse(model.replaceProgramAudio(with: selection, external: draft))
        let newer = try CutEngine(useSidecar: false).inspectMulticamSource(donor)
        XCTAssertFalse(model.replaceProgramAudio(with: selection, external: .init(source: source, media: newer)))
        XCTAssertEqual(model.media[source.id]?.identity, info.identity)
        XCTAssertEqual(model.mcpRevision, generation)
        XCTAssertEqual(model.project?.audio, MulticamAudioPolicy.none)
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
        let projectURL = directory.appendingPathComponent("edit.cut")
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
        let audio = try XCTUnwrap(project.plan().audioLanes.first?.spans.first)
        let preview = try XCTUnwrap(MulticamPreviewAudioSpan(span: audio, media: reopened.media))
        XCTAssertEqual(preview.url, donor.standardizedFileURL)
        XCTAssertEqual(preview.ordinal, 1)
        XCTAssertEqual(preview.output, interval.from..<interval.to)
        let output = directory.appendingPathComponent("sound.mov")
        let exporter = MulticamEngine()
        let resolved = try exporter.resolve(project, output: output, mode: .copy, tracks: .audio)
        XCTAssertEqual(resolved.mapping.audioLanes.first?.spans, [audio])
        XCTAssertEqual(resolved.audioLanes.first?.segments.first?.tracks.map(\.index), [selection.stream])
        try exporter.write(resolved, to: output)
        XCTAssertEqual(try engine.inspect(output).audio.count, 1)

        let wrong = try fixture("Standalone-Multitrack", extension: "mov")
        do {
            _ = try await reopened.relink(selection.source, to: wrong, validateCommit: {})
            XCTFail("A recording with a different layout cannot be relinked.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "media_relink_different")
        }
        XCTAssertEqual(reopened.project?.audioSources.first?.file, donor.path)
        let donorCopy = directory.appendingPathComponent("relocated.mov")
        try FileManager.default.moveItem(at: donor, to: donorCopy)
        let relink = try await reopened.relink(selection.source, to: donorCopy, validateCommit: {})
        XCTAssertTrue(relink.changed)
        try await waitForOperation(reopened)
        XCTAssertEqual(reopened.project?.audioSources.first?.file, donorCopy.path)
        XCTAssertEqual(reopened.project?.audio, .fixed(selection))
        let relocatedDeadline = ContinuousClock.now + .seconds(5)
        while reopened.media[selection.source]?.hasFullEditIndex != true && .now < relocatedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reopened.media[selection.source]?.url, donorCopy.standardizedFileURL)
        XCTAssertTrue(reopened.media[selection.source]?.hasFullEditIndex == true)
        let first = MulticamAudioSelection(source: selection.source, stream: 1)
        XCTAssertTrue(reopened.replaceProgramAudio(with: first))
        XCTAssertEqual(reopened.project?.audio, .fixed(first))
    }

    @MainActor
    func testAlignedAuditionUsesSelectedStreamAndExactRelativeOffset() async throws {
        let url = try fixture("Pause-Noisy", extension: "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let selected = try XCTUnwrap(media.audio.dropFirst().first)
        let offset = RationalTime(numerator: 48_001, denominator: 48_000)
        let point = try RationalTime(numerator: 2).adding(offset)
        let preview = try replacementAuditionClip(media: media, stream: selected.stream.index,
                                                   point: point, relativeOffset: offset)
        XCTAssertEqual(preview.audioTrack, 1)
        XCTAssertEqual(preview.audioTrackIDs?[1], selected.stream.trackID)
        XCTAssertEqual(preview.exactStart, .init(numerator: 3, denominator: 2))
        XCTAssertEqual(preview.exactEnd, .init(numerator: 7, denominator: 2))
        XCTAssertEqual(preview.audioOrigin, media.origin)
        XCTAssertTrue(preview.isAudioOnly)
        XCTAssertThrowsError(try replacementAuditionClip(media: media, stream: -1, point: point, relativeOffset: offset))
        let composition = try await SequencePreview.makeAudioComposition([preview])
        let audio = try await composition.loadTracks(withMediaType: .audio)
        let segment = try XCTUnwrap(audio.first?.segments.first { !$0.isEmpty })
        XCTAssertEqual(segment.sourceTrackID, selected.stream.trackID)
        XCTAssertEqual(segment.timeMapping.source.start.seconds, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(segment.timeMapping.source.duration.seconds, 2, accuracy: 0.000_001)
    }

    @MainActor
    func testExistingProgramSoundtrackMustCoverEntireCut() throws {
        let url = try fixture("Multicam-Delayed-PCM", extension: "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let audio = try XCTUnwrap(media.audio.first)
        let source = MulticamSource(id: "camera", file: url.path, audioStream: audio.stream.index)
        let selection = MulticamAudioSelection(source: source.id, stream: audio.stream.index)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: source, media: media)], opening: source.id, audio: .none)
        XCTAssertNotNil(model.programAudioCoverageIssue(with: selection))
        XCTAssertThrowsError(try replacementAuditionClip(media: media, stream: audio.stream.index, point: .zero))
        XCTAssertTrue(model.edit { $0.assembly = [.init(from: audio.start, to: audio.end)] })
        XCTAssertNil(model.programAudioCoverageIssue(with: selection))
    }

    @MainActor
    func testApplyingTrackReplacementCommitsDraftAndAlignmentAsOneEdit() throws {
        let camera = try fixture("Pause-Noisy", extension: "mov")
        let donor = try fixture("Multicam-Delayed-PCM", extension: "mov")
        let engine = CutEngine(useSidecar: false)
        let cameraInfo = try engine.inspectMulticamSource(camera)
        let donorInfo = try engine.inspectMulticamSource(donor)
        let original = MulticamAudioSelection(source: "close", stream: 2)
        let external = MulticamEditorModel.SourceDraft(source: .init(id: "incoming", file: donor.path), media: donorInfo)
        let incoming = MulticamAudioSelection(source: external.id, stream: try XCTUnwrap(donorInfo.audio.first?.stream.index))
        let relative = RationalTime(numerator: 113, denominator: 48_000)

        let preferences = EditorPreferences()
        let historyLimit = preferences.historyLimit
        preferences.historyLimit = 10
        let model = MulticamEditorModel(preferences: preferences)
        defer { model.reset(); preferences.historyLimit = historyLimit }
        model.useAnalysisSidecars = false
        model.confirmSetup(drafts: [
            .init(source: .init(id: "wide", file: camera.path), media: cameraInfo),
            .init(source: .init(id: "close", file: camera.path, audioStream: 2), media: cameraInfo)
        ], opening: "wide", audio: .fixed(original))
        model.chooseTrackReplacementAudio(original)
        XCTAssertEqual(model.trackReplacementTarget, original)
        XCTAssertTrue(model.project?.audioSources.isEmpty == true)

        XCTAssertTrue(model.byHand {
            model.replaceTrackAudio(original, with: incoming, external: external,
                                    relativeOffset: relative, uncovered: .keepOriginal)
        })
        let applied = try XCTUnwrap(model.project)
        let binding = try XCTUnwrap(applied.audioReplacements.first)
        XCTAssertEqual(applied.audio, .fixed(original))
        XCTAssertEqual(applied.switches.map(\.angle), ["wide"])
        XCTAssertEqual(applied.audioSources.map(\.id), [incoming.source])
        XCTAssertEqual(binding.original, original)
        XCTAssertEqual(binding.replacement, incoming)
        XCTAssertEqual(binding.relativeOffset, relative)
        XCTAssertEqual(binding.uncovered, .keepOriginal)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("edit.cut")
        XCTAssertTrue(model.saveProject(to: document))
        XCTAssertEqual(try MulticamProject.load(from: document).audioReplacements, [binding])
        model.undo()
        XCTAssertTrue(model.project?.audioSources.isEmpty == true)
        XCTAssertTrue(model.project?.audioReplacements.isEmpty == true)
        model.redo()
        XCTAssertEqual(model.project?.audioReplacements, [binding])
        let adjusted = try relative.adding(.init(numerator: 1, denominator: Int64(donorInfo.audio[0].stream.sampleRate)))
        XCTAssertTrue(model.byHand {
            model.replaceTrackAudio(original, with: incoming, external: external,
                                    relativeOffset: adjusted, uncovered: .keepOriginal)
        })
        XCTAssertEqual(model.project?.audioReplacements.first?.id, binding.id)
        XCTAssertEqual(model.project?.audioReplacements.first?.relativeOffset, adjusted)
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
