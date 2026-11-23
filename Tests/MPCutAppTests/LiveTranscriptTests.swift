import AppKit
import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class LiveTranscriptTests: XCTestCase {
    func testMulticamTranscriptFollowUsesTheVisiblePlaybackClock() {
        func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
        func range(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: t(from), to: t(to)) }
        let groupPreview = MulticamInterval(group: range(2, 10), output: range(0, 8),
                                            angle: "wide", audio: nil, assemblyIndex: 0)
        let assemblyPreview = MulticamInterval(group: range(5, 8), output: range(4, 7),
                                               angle: "wide", audio: nil, assemblyIndex: 2)
        let still = StillAssemblyItem.still(.init(id: "insert", assetID: "card", duration: t(2), cadence: t(1)))
        func resolve(_ output: Int64, space: TranscriptSpace, assembly: Bool,
                     interval: MulticamInterval?, items: [StillAssemblyItem] = [.group(range(8, 10)), still, .group(range(5, 8))])
            -> MulticamTranscriptPlaybackPosition? {
            MulticamTranscriptPlaybackPosition.resolve(output: t(output), readerSpace: space, assemblyPreview: assembly,
                interval: interval, assemblyItems: items,
                assemblyStart: { [t(0), t(2), t(4)][$0] })
        }
        XCTAssertEqual(resolve(5, space: .currentCut, assembly: false, interval: groupPreview),
                       .init(time: t(6), space: .currentCut))
        XCTAssertEqual(resolve(5, space: .group, assembly: true, interval: assemblyPreview),
                       .init(time: t(6), space: .group))
        XCTAssertEqual(resolve(5, space: .source, assembly: true, interval: assemblyPreview),
                       .init(time: t(5), space: .currentCut))
        XCTAssertNil(resolve(3, space: .group, assembly: true, interval: nil))
        XCTAssertNil(resolve(7, space: .group, assembly: true, interval: assemblyPreview))
        XCTAssertNil(resolve(0, space: .currentCut, assembly: false, interval: groupPreview))
        XCTAssertNil(resolve(5, space: .currentCut, assembly: false, interval: groupPreview,
                             items: [.group(range(6, 8)), still, .group(range(5, 8))]))
    }

    func testTranscriptSourceFollowFindsOverlappingWordWithinTheReaderFilter() throws {
        func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
        let track = TranscriptTrack(id: "mic", name: "Mic", streamIndex: 1)
        let document = TranscriptDocument(clock: .presentation, tracks: [track],
                                          speakers: [.init(id: "first", name: "First"), .init(id: "second", name: "Second")],
                                          words: [
            .init(id: "long", text: "Long", start: t(1), end: t(4), speakerID: "first",
                  observations: [.init(trackID: track.id, start: t(1), end: t(4), evidence: .recognized)]),
            .init(id: "short", text: "Short", start: t(2), end: t(3), speakerID: "second",
                  observations: [.init(trackID: track.id, start: t(2), end: t(3), evidence: .recognized)])
        ])
        let digest = String(repeating: "a", count: 64)
        let attachment = TranscriptAttachment(id: "dialogue",
            asset: .init(file: "project.cut.transcripts/\(digest).json", sha256: digest),
            bindings: [.init(trackID: track.id, file: "recording.mov", streamIndex: 1)])
        let project = CutProject.sequence([.init(id: "clip", file: "recording.mov", from: .zero, to: t(5))])
        let index = try TranscriptIndex(document: document, attachment: attachment, project: project)
        let scoped = TranscriptPaneWordList(index.readAll(space: .source).filter { $0.wordID == "long" })
        XCTAssertEqual(scoped.words.count, 1)
        XCTAssertEqual(index.sourcePanePosition(at: t(2), playbackSpace: .currentCut, scoped: scoped), 0)
        XCTAssertNil(index.sourcePanePosition(at: t(4), playbackSpace: .currentCut, scoped: scoped))
    }

    func testReaderRestoresOnlyUnambiguousOccurrencesAfterAssemblyEdit() throws {
        func range(_ from: Int64, _ to: Int64) -> MulticamRange {
            .init(from: .init(numerator: from), to: .init(numerator: to))
        }
        let track = TranscriptTrack(id: "lav", name: "Lav", sourceID: "lav", streamIndex: 0)
        let document = TranscriptDocument(clock: .session, tracks: [track], words: [
            .init(id: "word", text: "hello", start: .init(numerator: 2), end: .init(numerator: 3),
                  observations: [.init(trackID: track.id, start: .init(numerator: 2),
                                       end: .init(numerator: 3), evidence: .recognized)])
        ])
        func index(_ assembly: [MulticamRange], revision: Int) throws -> TranscriptIndex {
            let project = MulticamProject(referenceAngle: "wide", range: range(0, 8),
                                          angles: [.init(id: "wide", file: "camera.mov")],
                                          audioSources: [.init(id: "lav", file: "lav.wav")],
                                          audio: .fixed(.init(source: "lav", stream: 0)),
                                          switches: [.init(at: .zero, angle: "wide")], assembly: assembly)
            return try TranscriptIndex(document: document, project: .multicam(project), timelineRevision: revision)
        }
        let initial = try index([range(0, 8)], revision: 1)
        let word = try XCTUnwrap(initial.locate(wordID: "word", space: .currentCut).first)
        let moved = try index([range(4, 8), range(0, 4)], revision: 2)
        let restored = try XCTUnwrap(moved.revalidatedPaneWord(word, in: .currentCut, after: initial))
        XCTAssertEqual(restored.timelineRevision, 2)
        XCTAssertEqual(restored.range, range(6, 7))
        let repeated = try index([range(0, 4), range(0, 4)], revision: 3)
        XCTAssertEqual(repeated.locate(wordID: "word", space: .currentCut).count, 2)
        XCTAssertNil(repeated.revalidatedPaneWord(word, in: .currentCut, after: initial))
        let removed = try index([range(4, 8)], revision: 4)
        XCTAssertNil(removed.revalidatedPaneWord(word, in: .currentCut, after: initial))
    }

    @MainActor
    func testMulticamMediaIndexUpgradeChangesTranscriptRevisionWithoutTimelineEdit() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CutEngine(useSidecar: false)
        let camera = try engine.inspectMulticamSource(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recording = directory.appendingPathComponent("Alt.mov")
        try FileManager.default.copyItem(at: fixture, to: recording)
        let partial = try engine.inspectForPreview(recording)
        let full = try engine.inspectMulticamSource(recording)
        let model = MulticamEditorModel(preferences: EditorPreferences(),
                                       draft: ProjectDraft(directory: directory.appendingPathComponent("Drafts")))
        defer { model.reset() }
        model.useAnalysisSidecars = false
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: fixture.path), media: camera),
                                    .init(source: .init(id: "alt", file: recording.path), media: partial)],
                           opening: "wide", audio: .none)
        XCTAssertEqual(model.media["alt"]?.hasFullEditIndex, false)
        let mediaRevision = model.transcriptMediaRevision
        let timelineRevision = model.mcpRevision
        model.cacheIndexedSource(full)
        model.reconcileSourceLoads()
        XCTAssertEqual(model.media["alt"]?.hasFullEditIndex, true)
        XCTAssertEqual(model.transcriptMediaRevision, mediaRevision + 1)
        XCTAssertEqual(model.mcpRevision, timelineRevision)
    }

    @MainActor
    func testImportNamingAnAttachmentReplacesItsResultAndKeepsItsBinding() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Audio.wav")
        try writeSourceAudio(to: source)
        let captions = directory.appendingPathComponent("Dialogue.srt")
        try Data("1\n00:00:00,030 --> 00:00:00,060\nA sample line\n".utf8).write(to: captions)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(10)
        while !editor.canEdit, editor.alert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(editor.canEdit, editor.alert?.message ?? editor.statusMessage)

        let controller = session.transcript
        let first = try controller.importTranscript(captions, format: .srt)
        let path = try XCTUnwrap(editor.sequenceClips.first?.file)
        let stream = try XCTUnwrap(editor.transcriptMedia[path]?.streams.first(where: { $0.kind == "audio" }))
        let binding = TranscriptBinding(trackID: "source", file: path, streamIndex: stream.index)
        try controller.bind(attachmentID: first.id, bindings: [binding], origin: .init(numerator: 1, denominator: 100))
        let bound = try XCTUnwrap(controller.state.attachments.first)

        // A corrected caption file supersedes the result under the same attachment.
        try Data("1\n00:00:00,030 --> 00:00:00,060\nA corrected line\n".utf8).write(to: captions, options: .atomic)
        let replaced = try controller.importTranscript(captions, format: .srt, replacing: first.id)
        XCTAssertEqual(controller.state.attachments.count, 1)
        XCTAssertEqual(replaced.id, first.id)
        XCTAssertNotEqual(replaced.resultID, first.resultID)
        XCTAssertEqual(replaced.bindings, bound.bindings)
        XCTAssertEqual(replaced.importOrigin, .init(numerator: 1, denominator: 100))
        XCTAssertEqual(try controller.index().search("a corrected line", space: .currentCut).total, 1)
        XCTAssertEqual(try controller.index().search("a sample line", space: .currentCut).total, 0)

        // Without a named attachment an import still adds one, and an unknown name is refused.
        let second = try controller.importTranscript(captions, format: .srt)
        XCTAssertEqual(controller.state.attachments.count, 2)
        try controller.bind(attachmentID: second.id, bindings: [binding], origin: .zero)
        let word = try XCTUnwrap(controller.index(attachmentID: second.id).search("a corrected line", space: .currentCut).items.first?.words.first)
        let registry = ProjectSessions(preferences: preferences)
        let request: [String: Any] = ["selection": ["first_word_id": word.wordID, "first_occurrence_id": word.id]]
        let resolved = try await registry.mcpTranscript(tool: "transcript_editor_selection_resolve", arguments: request,
                                                        session: session, checkAccess: {})
        let selection = resolved?["selection"] as? [String: Any]
        XCTAssertEqual(selection?["attachment_id"] as? String, second.id)
        var pinned = request
        pinned["attachment_id"] = first.id
        do {
            _ = try await registry.mcpTranscript(tool: "transcript_editor_selection_mark", arguments: pinned,
                                                 session: session, checkAccess: {})
            XCTFail("An occurrence from a different attachment must not set timeline marks.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "stale_transcript_plan")
        }
        XCTAssertThrowsError(try controller.importTranscript(captions, format: .srt, replacing: "missing"))
        // A directory or device is refused before anything reads it.
        XCTAssertThrowsError(try controller.importTranscript(directory, format: .srt)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_transcript")
        }
    }

    @MainActor
    func testImportedCueEditsUseNativeUndoAndRejectReboundPlan() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Audio.wav")
        try writeSourceAudio(to: source)
        let captions = directory.appendingPathComponent("Dialogue.srt")
        try Data("1\n00:00:00,030 --> 00:00:00,060\nA sample line\n".utf8).write(to: captions)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.historyLimit = 10
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(10)
        while !editor.canEdit, editor.alert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(editor.canEdit, editor.alert?.message ?? editor.statusMessage)

        let controller = session.transcript
        let timeline = controller.timelineRevision
        let history = editor.historyCursor
        let originalClips = editor.sequenceClips
        let attachment = try controller.importTranscript(captions, format: .srt)
        let path = try XCTUnwrap(editor.sequenceClips.first?.file)
        let media = try XCTUnwrap(editor.transcriptMedia[path])
        let stream = try XCTUnwrap(media.streams.first(where: { $0.kind == "audio" }))
        let binding = TranscriptBinding(trackID: "source", file: path, streamIndex: stream.index)
        try controller.bind(attachmentID: attachment.id, bindings: [binding], origin: .zero)
        XCTAssertEqual(controller.timelineRevision, timeline)
        XCTAssertEqual(editor.historyCursor, history)

        let word = try XCTUnwrap(controller.index().search("a sample line", space: .currentCut).items.first?.words.first)
        let selection = TranscriptWordSelection(firstWordID: word.wordID, firstOccurrenceID: word.id)
        let marked = try controller.mark(selection)
        XCTAssertEqual(editor.markIn, marked.range.from.seconds)
        XCTAssertEqual(editor.markOut, marked.range.to.seconds)
        let old = try controller.plan(.init(action: .delete, selections: [selection], boundaryPolicy: .exact))
        try controller.bind(attachmentID: attachment.id, bindings: [binding], origin: .init(numerator: 1, denominator: 1000))
        XCTAssertThrowsError(try controller.apply(old)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_plan")
        }
        XCTAssertEqual(editor.historyCursor, history)
        let queue = try controller.plan(.init(action: .queue, selections: [selection], boundaryPolicy: .exact))
        let queueID = try controller.queue(queue, name: "Quote")
        let queued = try XCTUnwrap(editor.queuedRanges.first)
        XCTAssertEqual(queued.name, "Quote")
        XCTAssertEqual(queued.stillProject?.sequenceClips, queue.snapshot.sequenceClips)

        let reviewed = try controller.plan(.init(action: .delete, selections: [selection], boundaryPolicy: .exact))
        let applied = try controller.apply(reviewed)
        XCTAssertEqual(editor.historyCursor, history + 1)
        XCTAssertEqual(editor.sequenceClips, applied.project.sequenceClips)
        XCTAssertEqual(editor.queuedRanges.first?.stillProject?.sequenceClips, queue.snapshot.sequenceClips)
        editor.undo()
        XCTAssertEqual(editor.historyCursor, history)
        XCTAssertEqual(editor.sequenceClips, originalClips)
        XCTAssertEqual(controller.state.attachments.first?.importOrigin, .init(numerator: 1, denominator: 1000))

        try controller.detach(attachmentID: attachment.id)
        let projectURL = directory.appendingPathComponent("Reopened.cut")
        try editor.writeProject(to: projectURL)
        let excerptURL = directory.appendingPathComponent("Quote.cut")
        let save = try controller.prepareExcerptSave(queueID, to: excerptURL)
        try save()
        let reopened = try CutProject.load(from: excerptURL)
        XCTAssertEqual(reopened.sequenceClips?.map { MulticamRange(from: $0.from, to: $0.to) },
                       queue.snapshot.sequenceClips?.map { MulticamRange(from: $0.from, to: $0.to) })
        let transcript = try XCTUnwrap(reopened.transcripts.attachments.first)
        XCTAssertNoThrow(try TranscriptStore.read(transcript.asset, relativeTo: excerptURL))
    }

    @MainActor
    func testStagedImportPreservesReviewedDocumentAndRejectsModifiedAsset() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Audio.wav")
        try writeSourceAudio(to: source)
        let clips = [CutSequenceClip(id: UUID().uuidString, file: source.path, from: .zero, to: .init(numerator: 1, denominator: 5))]
        let projectURL = directory.appendingPathComponent("Review.cut")
        try CutProject.sequence(clips).save(to: projectURL)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        try editor.openProject(clips, at: projectURL)
        let deadline = ContinuousClock.now + .seconds(10)
        while !editor.canEdit, editor.alert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(editor.canEdit, editor.alert?.message ?? editor.statusMessage)
        XCTAssertEqual(editor.projectURL, projectURL)

        let controller = session.transcript
        let path = try XCTUnwrap(editor.sequenceClips.first?.file)
        let media = try XCTUnwrap(editor.transcriptMedia[path])
        let stream = try XCTUnwrap(media.streams.first(where: { $0.kind == "audio" }))
        let binding = TranscriptBinding(trackID: "source", file: path, streamIndex: stream.index)
        let captions = directory.appendingPathComponent("Dialogue.srt")
        try Data("1\n00:00:00,030 --> 00:00:00,060\nA sample line\n".utf8).write(to: captions)

        // The binding sheet reviews the one decoded value even if the input file is replaced.
        let reviewedDocument = try TranscriptCodec.decode(Data(contentsOf: captions), format: .srt)
        try Data("1\n00:00:00,030 --> 00:00:00,060\nReplacement file\n".utf8).write(to: captions, options: .atomic)
        let reviewedAttachment = try await controller.attachImportedTranscript(reviewedDocument, bindings: [binding], origin: .zero)
        let reviewedIndex = try await controller.indexedTranscript(attachmentID: reviewedAttachment.id)
        XCTAssertEqual(reviewedIndex.search("a sample line", space: .currentCut).total, 1)
        XCTAssertEqual(reviewedIndex.search("replacement file", space: .currentCut).total, 0)
        XCTAssertEqual(try controller.document(attachmentID: reviewedAttachment.id), reviewedDocument)
        let assetURL = try XCTUnwrap(TranscriptStore.assetLocation(reviewedAttachment.asset, relativeTo: controller.assetContext()))
        try Data("changed".utf8).write(to: assetURL, options: .atomic)
        do {
            _ = try await controller.indexedTranscript(attachmentID: reviewedAttachment.id)
            XCTFail("A warm index must not hide a modified asset.")
        } catch {
            XCTAssertEqual((error as? CutError)?.code, "damaged_transcript")
        }
    }

    private func writeSourceAudio(to url: URL) throws {
        let audio = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ], commonFormat: .pcmFormatInt16, interleaved: false)
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 12_000))
        samples.frameLength = samples.frameCapacity
        let channel = try XCTUnwrap(samples.int16ChannelData?[0])
        for index in 0..<Int(samples.frameLength) {
            channel[index] = Int16(index % 400 - 200)
        }
        try audio.write(from: samples)
    }
}
