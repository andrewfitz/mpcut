import AppKit
import Combine
import Darwin
import MPCutCore
import XCTest
@testable import MPCutApp

final class LiveTranscriptLifecycleTests: XCTestCase {
    @MainActor
    func testClosingBeforeQueuedDocumentEventDoesNotDiscoverJobs() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Empty.cut").resolvingSymlinksInPath()
        let owner = UUID()
        var project = CutProject.sequence([])
        project.transcripts.documentID = owner
        try project.save(to: document)

        let movie = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let recording = folder.appendingPathComponent("Camera.mov")
        try FileManager.default.copyItem(at: movie, to: recording)
        var store = TranscriptJobStore(directory: LiveTranscriptController.jobsDirectory)
        store.stagesAudioForStandaloneProvider = false
        defer { try? store.discard(documentID: document.path) }
        let input = CutProject.sequence([CutSequenceClip(id: "camera", file: recording.path, from: .zero,
                                                         to: .init(numerator: 1))])
        let record = try store.prepare(project: input, documentID: document.path, relativeTo: document,
                                       documentIdentity: owner)

        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let closing = ProjectSession(id: UUID(), preferences: preferences)
        let controller = closing.transcript
        try closing.editor.openProject([], at: document)
        controller.prepareForWindowEnd(preservingDraft: true)

        let open = ProjectSession(id: UUID(), preferences: preferences)
        let openController = open.transcript
        try open.editor.openProject([], at: document)
        defer { closing.end(); open.end() }
        try await until("the open window discovers the job") { openController.job?.id == record.id }
        XCTAssertNil(controller.job)
    }

    @MainActor
    func testInterruptRestoreReconfigureAndReplayActiveJob() async throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("MPCut-lifecycle-\(UUID())", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        let firstSave = folder.appendingPathComponent("First.cut")
        let savedAs = folder.appendingPathComponent("Save As.cut")
        let store = TranscriptJobStore(directory: LiveTranscriptController.jobsDirectory)

        let helper = try FixtureHelper(folder: folder)
        let previousHelper = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIBERRR_HELPER"]
        setenv("MPCUT_TRANSCRIBERRR_HELPER", helper.executable.path, 1)
        defer {
            if let previousHelper { setenv("MPCUT_TRANSCRIBERRR_HELPER", previousHelper, 1) }
            else { unsetenv("MPCUT_TRANSCRIBERRR_HELPER") }
        }

        let source = folder.appendingPathComponent("Camera.mov")
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        try files.copyItem(at: movie, to: source)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.historyLimit = 10
        let original = ProjectSession(id: UUID(), preferences: preferences)
        original.isMulticam = true
        let editor = original.multicam
        let controller = original.transcript
        defer { editor.reset() }
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        editor.confirmSetup(drafts: [.init(source: .init(id: "camera", file: source.path), media: media)],
                            opening: "camera", audio: .none)
        let draft = try XCTUnwrap(editor.draft.url)
        XCTAssertNil(editor.projectURL)

        let options = TranscriptJobOptions(engine: "lifecycle-fixture")
        let id = try controller.start(options: options)
        defer {
            if let record = try? store.status(id) {
                if record.ownerToken != nil { _ = try? store.interrupt(id) }
                try? store.discard(documentID: record.documentID)
            }
        }
        try await until("the untitled job enters the helper") {
            guard helper.started(1) else { return false }
            return try controller.status(id).helperPID != nil
        }
        let started = try controller.status(id)
        XCTAssertTrue(try controller.jobs().contains { $0.id == id })
        XCTAssertEqual(started.state, .running)
        let firstPID = try XCTUnwrap(started.helperPID)
        let identity = try XCTUnwrap(started.documentIdentity)
        XCTAssertTrue(editor.updateSource("camera") { $0.name = "Interview Camera" })

        try editor.writeProject(to: firstSave)
        try await until("the job follows the first save") {
            try editor.projectURL == firstSave && controller.jobs().contains { $0.id == id }
        }
        XCTAssertFalse(files.fileExists(atPath: draft.path))
        try editor.writeProject(to: savedAs)
        try await until("the same running job follows Save As") {
            try editor.projectURL == savedAs && controller.jobs().contains { $0.id == id }
        }
        XCTAssertEqual(try store.status(id).helperPID, firstPID)
        XCTAssertEqual(try store.status(id).documentIdentity, identity)
        XCTAssertEqual(try CutProject.load(from: savedAs).transcripts.documentID, identity)

        // Exercise the quit-side controller hook, then open the disk document in a new editor session.
        await LiveTranscriptController.interruptActiveJobs()
        XCTAssertEqual(try store.status(id).state, .interrupted)
        XCTAssertNil(try store.status(id).ownerToken)
        XCTAssertEqual(kill(firstPID, 0), -1)
        XCTAssertNil(controller.activeJobID)
        editor.reset()

        let reopened = ProjectSession(id: UUID(), preferences: preferences)
        reopened.isMulticam = true
        let restored = reopened.multicam
        let transcript = reopened.transcript
        defer { restored.reset() }
        restored.openProject(savedAs)
        try await until("the saved editor and interrupted job reopen") {
            restored.projectURL == savedAs && !restored.isBusy && transcript.job?.id == id
        }
        XCTAssertEqual(transcript.job?.state, .interrupted)
        XCTAssertEqual(restored.project?.angles.first?.name, "Interview Camera")

        try transcript.retry(id)
        try await until("the interrupted job resumes in the helper") { helper.started(2) }
        let oldFingerprint = try XCTUnwrap(transcript.status(id).sessions.first?.fingerprint)
        let newOffset = RationalTime(numerator: 1, denominator: 10)
        XCTAssertTrue(restored.updateSource("camera") { $0.offset = newOffset })
        try helper.release(2, as: "partial")
        try await until("the stale completion triggers reconciliation with the changed offset") { helper.started(3) }
        XCTAssertTrue(transcript.state.attachments.isEmpty)
        let changed = try transcript.status(id)
        XCTAssertNotEqual(changed.sessions.first?.fingerprint, oldFingerprint)
        XCTAssertEqual(changed.sessions.first?.tracks.first?.sessionStart, newOffset)

        try helper.release(3, as: "partial")
        try await until("the partial result attaches") { transcript.activeJobID == nil }
        let partial = try transcript.status(id)
        XCTAssertEqual(partial.state, .partial, transcript.jobError ?? partial.message ?? "")
        XCTAssertEqual(partial.sessions.first?.tracks.map(\.state), [.recognized, .failed])
        XCTAssertEqual(partial.sessions.first?.tracks.last?.message, "Fixture recognition failed")
        XCTAssertEqual(transcript.state.attachments.count, 1)
        let attachment = try transcript.attachment()
        let acceptedResult = try XCTUnwrap(partial.sessions.first?.tracks.first?.result)
        let acceptedStamp = try SourceIdentity(acceptedResult)
        let index = try transcript.index()
        let word = try XCTUnwrap(index.search("Ready", space: .group).items.first?.words.first)
        XCTAssertEqual(word.range.from, .init(numerator: 7, denominator: 20))
        let selection = TranscriptWordSelection(firstWordID: word.wordID, space: .group, firstOccurrenceID: word.id)
        let authored = try transcript.correct(.renameSpeaker(speakerID: "person", name: "Interviewer"),
                                              attachmentID: attachment.id)
        let correction = try transcript.correct(.replaceText(text: "Reviewed"), selection: selection,
                                                attachmentID: attachment.id)
        XCTAssertEqual(try transcript.index().speakers.first(where: { $0.id == "person" })?.name, "Interviewer")
        try restored.writeProject(to: savedAs)

        try transcript.retry(id)
        try await until("the failed stream reaches the helper on retry") { helper.started(4) }
        XCTAssertEqual(try transcript.cancel(id).state, .cancelled)
        try await until("the cancelled worker exits") { transcript.activeJobID == nil }
        XCTAssertEqual(try transcript.status(id).state, .cancelled)
        XCTAssertEqual(transcript.state.attachments, [attachment])

        try transcript.retry(id)
        try await until("the cancelled retry can start again") { helper.started(5) }
        try helper.release(5, as: "completed")
        try await until("successful retry finishes") { transcript.activeJobID == nil }
        let complete = try transcript.status(id)
        XCTAssertEqual(complete.state, .completed, transcript.jobError ?? complete.message ?? "")
        XCTAssertEqual(complete.sessions.first?.tracks.last?.state, .recognized)
        XCTAssertEqual(try SourceIdentity(acceptedResult), acceptedStamp)
        XCTAssertEqual(transcript.state.attachments.map(\.id), [attachment.id])
        XCTAssertEqual(transcript.state.authoring, [authored, correction])
        XCTAssertEqual(try transcript.index().search("Reviewed", space: .group).items.flatMap(\.words).count, 1)

        // Leave the successful retry unsaved; the disk document still contains the partial asset.
        let state = transcript.state
        XCTAssertEqual(try CutProject.load(from: savedAs).transcripts.attachments.map(\.asset), [attachment.asset])
        restored.reset()
        let replaySession = ProjectSession(id: UUID(), preferences: preferences)
        replaySession.isMulticam = true
        let replayEditor = replaySession.multicam
        let replayTranscript = replaySession.transcript
        defer { replayEditor.reset() }
        replayEditor.openProject(savedAs)
        try await until("the newer completion replaces the saved partial result on reopen") {
            guard !replayEditor.isBusy, replayEditor.projectURL == savedAs else { return false }
            return try replayTranscript.document().tracks.last?.coverage == .recognized
        }
        XCTAssertEqual(replayTranscript.state, state)

        // Reuse the operation ID, then force a fresh delivery of the same completion.
        XCTAssertEqual(try replayTranscript.start(options: options, operationID: id), id)
        XCTAssertNil(replayTranscript.activeJobID)
        XCTAssertEqual(replayTranscript.state, state)
        try replayTranscript.retry(id)
        try await until("the same completion is delivered again") { helper.started(6) }
        try helper.release(6, as: "completed")
        try await until("completion replay finishes") { replayTranscript.activeJobID == nil }
        XCTAssertEqual(try replayTranscript.status(id).state, .completed, replayTranscript.jobError ?? "")
        XCTAssertEqual(replayTranscript.state, state)
        XCTAssertEqual(try replayTranscript.document().words.map(\.text), ["Ready"])
        try replayEditor.writeProject(to: savedAs)
        XCTAssertEqual(try CutProject.load(from: savedAs).transcripts, state)

        replayEditor.reset()
        let savedSession = ProjectSession(id: UUID(), preferences: preferences)
        savedSession.isMulticam = true
        let savedEditor = savedSession.multicam
        let savedTranscript = savedSession.transcript
        defer { savedEditor.reset() }
        savedEditor.openProject(savedAs)
        try await until("the saved attachment is recognized on reopen") {
            guard !savedEditor.isBusy, savedEditor.projectURL == savedAs else { return false }
            return try savedTranscript.status(id).attached
        }
        XCTAssertEqual(savedTranscript.state, state)
        XCTAssertEqual(try savedTranscript.index().search("Reviewed", space: .group).items.flatMap(\.words).count, 1)

        let completedBeforeOffset = try savedTranscript.status(id)
        let currentTrackResults = completedBeforeOffset.sessions.flatMap(\.tracks).compactMap(\.result)
        let resultStamps = try Dictionary(uniqueKeysWithValues: currentTrackResults.map { ($0, try SourceIdentity($0)) })
        XCTAssertFalse(resultStamps.isEmpty)
        let oldGroupWord = try XCTUnwrap(savedTranscript.index().search("Reviewed", space: .group).items.first?.words.first)
        let shift = RationalTime(numerator: 1, denominator: 8)
        let movedOffset = try newOffset.adding(shift)
        XCTAssertTrue(savedEditor.updateSource("camera") { $0.offset = movedOffset })
        let staleWord = try XCTUnwrap(savedTranscript.index().search("Reviewed", space: .group).items.first?.words.first)
        XCTAssertTrue(staleWord.staleMatches)
        XCTAssertEqual(staleWord.range.from, try oldGroupWord.range.from.adding(shift))

        XCTAssertEqual(try savedTranscript.reconcile(attachmentID: attachment.id), id)
        try await until("the completed attachment is submitted for reconciliation") { helper.started(7) }
        try helper.release(7, as: "completed")
        try await until("offset reconciliation attaches") { savedTranscript.activeJobID == nil }
        let reconciled = try savedTranscript.status(id)
        XCTAssertEqual(reconciled.state, .completed, savedTranscript.jobError ?? reconciled.message ?? "")
        XCTAssertNotEqual(reconciled.sessions.first?.fingerprint, completedBeforeOffset.sessions.first?.fingerprint)
        for (output, stamp) in resultStamps { XCTAssertEqual(try SourceIdentity(output), stamp) }
        XCTAssertEqual(savedTranscript.state.attachments.map(\.id), [attachment.id])
        XCTAssertEqual(savedTranscript.state.authoring, state.authoring)
        let reconciledWord = try XCTUnwrap(savedTranscript.index().search("Reviewed", space: .group).items.first?.words.first)
        XCTAssertFalse(reconciledWord.staleMatches)
        XCTAssertEqual(reconciledWord.range.from, staleWord.range.from)
        let stateAfterAlignment = savedTranscript.state

        var replacementStatus: String?
        let observed = savedTranscript.$job.sink { record in
            guard record?.state == .stale else { return }
            replacementStatus = record?.message
        }
        defer { observed.cancel() }
        try savedTranscript.retry(id)
        try await until("recognition begins before media replacement") { helper.started(8) }
        let replacement = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov",
                                                           subdirectory: "Fixtures"))
        try Data(contentsOf: replacement).write(to: source, options: .atomic)
        try helper.release(8, as: "completed")
        try await until("replacement requires a different session") { helper.started(9) }
        XCTAssertEqual(savedTranscript.state, stateAfterAlignment)
        XCTAssertTrue(replacementStatus?.contains("Media changed for Interview Camera") == true,
                      replacementStatus ?? "No stale media status was published.")
        XCTAssertNotEqual(try savedTranscript.status(id).sessions.first?.fingerprint, complete.sessions.first?.fingerprint)

        try files.removeItem(at: source)
        try helper.release(9, as: "completed")
        try await until("missing media prevents retry") { savedTranscript.activeJobID == nil }
        let missing = try savedTranscript.status(id)
        XCTAssertTrue([.failed, .stale].contains(missing.state))
        let diagnostic = (missing.message ?? "") + " " + (savedTranscript.jobError ?? "")
        XCTAssertTrue(diagnostic.contains("Camera.mov"), diagnostic)
        XCTAssertEqual(savedTranscript.state, stateAfterAlignment)
    }

    @MainActor
    private func until(_ description: String, _ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CutError(code: "test_timeout", message: "Timed out waiting for \(description)")
    }

    private struct FixtureHelper {
        let executable: URL
        let folder: URL

        init(folder: URL) throws {
            self.folder = folder
            executable = folder.appendingPathComponent("fixture-helper")
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: "TranscriptLifecycleProvider",
                                                            withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: fixture, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func started(_ attempt: Int) -> Bool {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("started-\(attempt)").path)
        }

        func release(_ attempt: Int, as state: String) throws {
            try Data(state.utf8).write(to: folder.appendingPathComponent("release-\(attempt)"), options: .atomic)
        }

    }
}
