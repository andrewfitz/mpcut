import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class TranscriptPersistenceTests: XCTestCase {
    @MainActor
    func testParticipantMediaRemainsProtectedThroughSaveAndHistory() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = EditorPreferences()
        preferences.historyLimit = 10
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        let recording = directory.appendingPathComponent("Trimmed.mov")
        let participants = ParticipantProject(sources: [.init(sourceID: recording.path)])
        try editor.replaceParticipantProject(participants, action: "Add Participant Geometry")
        XCTAssertThrowsError(try editor.validateHistoryDestination(recording))
        editor.undo()
        XCTAssertTrue(editor.transcriptProject.participants.isEmpty)
        XCTAssertThrowsError(try editor.validateHistoryDestination(recording))
        editor.redo()

        let destination = directory.appendingPathComponent("Sequence.cut")
        try editor.writeProject(to: destination)
        let saved = try CutProject.load(from: destination)
        XCTAssertEqual(saved.participants.sources.map(\.sourceID), ["Trimmed.mov"])
        let reopened = ProjectSession(id: UUID(), preferences: preferences)
        defer { reopened.editor.endSession() }
        try reopened.editor.openProject([], at: destination)
        XCTAssertEqual(reopened.editor.transcriptProject.participants, participants)
        XCTAssertThrowsError(try reopened.editor.validateHistoryDestination(recording))
        reopened.editor.undo()
        XCTAssertTrue(reopened.editor.transcriptProject.participants.isEmpty)
        XCTAssertTrue(reopened.editor.canRedo)
    }

    func testReplaySelectionSurvivesPictureOverrideAndCannotMoveToSurvivingReplay() throws {
        func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
        let range = MulticamRange(from: .zero, to: t(5))
        let recording = TranscriptTrack(id: "mic", name: "Mic", sourceID: "wide", streamIndex: 1)
        let binding = TranscriptBinding(trackID: recording.id, sourceID: "wide", streamIndex: 1)
        let attachment = TranscriptAttachment(id: "dialogue",
            asset: .init(file: "dialogue.json", sha256: String(repeating: "a", count: 64)), bindings: [binding])
        let transcript = TranscriptDocument(clock: .session, tracks: [recording],
            words: [.init(id: "opening", text: "hello", start: t(1), end: t(2))])
        var project = MulticamProject(referenceAngle: "wide", range: range,
            angles: [.init(id: "wide", file: "wide.mov", audioStream: 1),
                     .init(id: "close", file: "close.mov")],
            audio: .follow, switches: [.init(at: .zero, angle: "wide")],
            assemblyItems: [.group(range), .group(range)])
        func index(_ revision: Int) throws -> TranscriptIndex {
            try TranscriptIndex(document: transcript, attachment: attachment, project: .multicam(project),
                                timelineRevision: revision)
        }
        let before = try index(1)
        let initial = before.locate(wordID: "opening", space: .currentCut)
        XCTAssertEqual(initial.count, 2)
        let firstReplay = try XCTUnwrap(initial.first)
        let lastReplay = try XCTUnwrap(initial.last)
        let endpoint = try TranscriptBasketEndpoint(firstReplay, in: before)
        project.assemblyItems = [.group(range, angle: "close"), .group(range)]
        let changed = try index(2)
        XCTAssertEqual(changed.revalidatedPaneWord(lastReplay, in: .currentCut, after: before)?.range,
                       lastReplay.range)
        XCTAssertEqual(try endpoint.resolve(in: changed, space: .currentCut,
                                            source: changed.readAll(space: .source)).range, firstReplay.range)

        project.assemblyItems = [.group(range)]
        let shortened = try index(3)
        XCTAssertNil(shortened.revalidatedPaneWord(firstReplay, in: .currentCut, after: before))
        XCTAssertThrowsError(try endpoint.resolve(in: shortened, space: .currentCut,
                                                  source: shortened.readAll(space: .source)))
    }

    @MainActor
    func testUntitledAttachmentSurvivesSaveAsAndAuthoringUndoKeepsRedo() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = EditorPreferences()
        preferences.historyLimit = 10
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        let draft = try editor.transcriptAssetContext()
        let draftStore = TranscriptStore.folder(relativeTo: draft, draft: true)
        let data = Data("{\"version\":1}".utf8)
        let asset = try TranscriptStore.put(data, relativeTo: draft, draft: true)
        let timeline = session.transcript.timelineRevision
        let attachment = TranscriptAttachment(id: "dialogue", asset: asset, bindings: [])
        let documentID = UUID()
        try editor.setTranscriptState(.init(attachments: [attachment], documentID: documentID))
        XCTAssertEqual(editor.historyCursor, 0)
        XCTAssertEqual(session.transcript.timelineRevision, timeline)

        var authored = editor.transcriptState
        authored.authoring = [.init(attachmentID: "dialogue", change: .renameSpeaker(speakerID: "a", name: "Host"), anchors: [])]
        try editor.setTranscriptState(authored, action: "Rename Speaker")
        XCTAssertEqual(editor.historyCursor, 1)
        editor.undo()
        XCTAssertEqual(session.transcript.timelineRevision, timeline)
        XCTAssertEqual(editor.transcriptState.authoring, [])
        XCTAssertTrue(editor.canRedo)

        var rebound = editor.transcriptState
        rebound.attachments[0].importOrigin = .init(numerator: 1)
        try editor.setTranscriptState(rebound)
        XCTAssertTrue(editor.canRedo)
        editor.redo()
        XCTAssertEqual(editor.transcriptState.authoring, authored.authoring)
        XCTAssertEqual(editor.transcriptState.attachments.first?.importOrigin, .init(numerator: 1))
        XCTAssertEqual(session.transcript.timelineRevision, timeline)

        let occupied = directory.appendingPathComponent("Occupied.cut")
        let occupiedProject = CutProject.sequence([])
        try occupiedProject.save(to: occupied)
        XCTAssertThrowsError(try editor.writeProject(to: occupied, replacingExisting: false)) { error in
            XCTAssertEqual((error as? CutError)?.code, "destination_exists")
        }
        XCTAssertEqual(try CutProject.load(from: occupied), occupiedProject)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.folder(relativeTo: occupied).path))
        XCTAssertEqual(editor.draft.url, draft)
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: draft), data)

        let saved = directory.appendingPathComponent("Interview.cut")
        try editor.writeProject(to: saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftStore.path))
        let document = try CutProject.loadDocument(from: saved, limit: 10)
        let savedAsset = try XCTUnwrap(document.project.transcripts.attachments.first?.asset)
        XCTAssertEqual(try TranscriptStore.read(savedAsset, relativeTo: saved), data)
        XCTAssertEqual(document.undo.count, 1)

        let reopened = ProjectSession(id: UUID(), preferences: preferences)
        defer { reopened.editor.endSession() }
        try reopened.editor.openProject([], at: saved)
        XCTAssertEqual(reopened.editor.transcriptState, document.project.transcripts)
        XCTAssertEqual(reopened.editor.transcriptState.documentID, documentID)
        reopened.editor.undo()
        XCTAssertEqual(reopened.editor.transcriptState.authoring, [])
        XCTAssertEqual(reopened.editor.transcriptState.attachments, document.project.transcripts.attachments)
    }
}
