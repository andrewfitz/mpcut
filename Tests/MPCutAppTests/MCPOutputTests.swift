import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPOutputTests: XCTestCase {
    private func finished(_ job: [String: Any], owner: String, in jobs: MCPLiveOutputJobs) async throws -> [String: Any] {
        let id = try XCTUnwrap(job["job_id"] as? String)
        let limit = ContinuousClock.now + .seconds(30)
        while .now < limit {
            let state = try jobs.status(owner: owner, id: id, cancel: false)
            if !["running", "cancelling"].contains(state["state"] as? String ?? "") { return state }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MCPCommandError("timeout", "Timed out waiting for the output job.")
    }

    func testInterchangeCapturesUnsavedSplitAndDryRunDoesNotWrite() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.editor.endSession() }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.editor.importFiles([url])
        let deadline = ContinuousClock.now + .seconds(30)
        while session.editor.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let clip = try XCTUnwrap(session.editor.mcpClipIDs.first)
        _ = try await session.editor.mcpCommand(tool: "timeline_item_split", arguments: ["space": "source", "time": "1001/30000",
                                                                               "occurrence": clip.uuidString], validateCommit: {})
        let cut = directory.appendingPathComponent("Snapshot.cut")
        let args: [String: Any] = ["project_handle": session.mcpHandle, "output": cut.path]
        let result = try await sessions.mcpOutputs(tool: "project_editor_convert", arguments: args, session: session, checkAccess: {})
        let ticket = try XCTUnwrap(result)
        session.editor.undo()
        let done = try await finished(ticket, owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(done["state"] as? String, "succeeded", String(describing: done))
        guard case .sequence(let clips) = try CutProject.load(from: cut) else { return XCTFail("Expected sequence") }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(session.editor.sequenceClips.count, 1)
        XCTAssertNil(session.editor.projectURL)
        session.editor.selectRange(0, session.editor.mcpDuration.seconds)
        session.editor.addMarkedRange()
        let queuedOutput = directory.appendingPathComponent("Review/Select-001.mov")
        for tool in ["export_queue_plan", "export_queue_render"] {
            let receipt = try await sessions.mcpOutputs(tool: tool, arguments: [
                "project_handle": session.mcpHandle, "output": directory.path, "container": "mov",
                "mode": "copy", "subfolder": "Review", "base_name": "Select"
            ], session: session, checkAccess: {})
            let status = try await finished(XCTUnwrap(receipt), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
            XCTAssertEqual(status["state"] as? String, "succeeded", String(describing: status))
            XCTAssertEqual((status["result"] as? [String: Any])?["destinations"] as? [String], [queuedOutput.path])
            XCTAssertEqual(FileManager.default.fileExists(atPath: queuedOutput.path), tool == "export_queue_render")
        }
        let movie = directory.appendingPathComponent("Movie.mov")
        let check = try await sessions.mcpOutputs(tool: "export_editor_project_plan",
            arguments: ["project_handle": session.mcpHandle, "output": movie.path, "mode": "copy"], session: session, checkAccess: {})
        let checked = try await finished(XCTUnwrap(check), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(checked["state"] as? String, "succeeded", String(describing: checked))
        XCTAssertEqual((checked["result"] as? [String: Any])?["eligible"] as? Bool, true)
        let checkedMap = try XCTUnwrap((checked["result"] as? [String: Any])?["cut_map"] as? [String: Any])
        let checkedOccurrences = try XCTUnwrap(checkedMap["occurrences"] as? [[String: Any]])
        XCTAssertEqual(checkedOccurrences.count, 1)
        XCTAssertEqual(checkedOccurrences.first?["occurrence_id"] as? String, session.editor.sequenceClips.first?.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        let render = try await sessions.mcpOutputs(tool: "export_editor_project_render", arguments: [
            "project_handle": session.mcpHandle, "output": movie.path, "mode": "copy"
        ], session: session, checkAccess: {})
        let rendered = try await finished(XCTUnwrap(render), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(rendered["state"] as? String, "succeeded", String(describing: rendered))
        XCTAssertEqual(rendered["outputs"] as? [String], [movie.path])
        XCTAssertGreaterThan(try CutEngine(useSidecar: false).inspect(movie).duration, .zero)
        let refusedOutput = directory.appendingPathComponent("Unsupported.invalid")
        let refused = try await sessions.mcpOutputs(tool: "export_editor_project_plan", arguments: [
            "project_handle": session.mcpHandle, "output": refusedOutput.path, "mode": "copy"
        ], session: session, checkAccess: {})
        let preflight = try await finished(XCTUnwrap(refused), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        let issue = try XCTUnwrap(preflight["result"] as? [String: Any])
        XCTAssertEqual(issue["eligible"] as? Bool, false)
        XCTAssertEqual(issue["dry_run"] as? Bool, true)
        XCTAssertEqual((issue["issue"] as? [String: Any])?["code"] as? String, "unsupported_container")
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusedOutput.path))
        do {
            _ = try await sessions.mcpOutputs(tool: "export_editor_project_plan", arguments: [
                "project_handle": session.mcpHandle, "output": directory.appendingPathComponent("PCM.mp4").path,
                "mode": "encode", "audio": "pcm"
            ], session: session, checkAccess: {})
            XCTFail("PCM in MP4 should be refused.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "unsupported_audio")
        }
        let frames = directory.appendingPathComponent("frames")
        let frameJob = try await sessions.mcpOutputs(tool: "review_editor_frames_export", arguments: [
            "project_handle": session.mcpHandle, "output": frames.path, "selection": "times", "times": ["0", "1001/30000"]
        ], session: session, checkAccess: {})
        let generated = try await finished(XCTUnwrap(frameJob), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(generated["state"] as? String, "succeeded", String(describing: generated))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: frames.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual((manifest?["frames"] as? [[String: Any]])?.count, 2)

        let editor = session.editor
        let entry = try XCTUnwrap(editor.queuedRanges.first)
        try editor.renameQueuedRange(entry.id, to: "Opening")
        let unusedDefault = directory.appendingPathComponent("ProRes-2997-001.mov")
        try Data("Keep this file".utf8).write(to: unusedDefault)
        editor.selectRange(0, editor.duration)
        _ = try await sessions.mcpOutputs(tool: "export_queue_range_add", arguments: ["project_handle": session.mcpHandle],
                                          session: session, checkAccess: {})
        editor.deleteClip(try XCTUnwrap(editor.mcpClipIDs.first))
        XCTAssertTrue(editor.isEmpty)
        let queued = try await sessions.mcpOutputs(tool: "export_queue_render", arguments: [
            "project_handle": session.mcpHandle, "output": directory.path, "mode": "copy"
        ], session: session, checkAccess: {})
        let exported = try await finished(XCTUnwrap(queued), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(exported["state"] as? String, "succeeded", String(describing: exported))
        let expected = ["Opening-001.mov", "ProRes-2997-002.mov"].map { directory.appendingPathComponent($0).path }
        XCTAssertEqual(exported["outputs"] as? [String], expected)
        XCTAssertTrue(expected.allSatisfy(FileManager.default.fileExists(atPath:)))
        XCTAssertEqual(try String(contentsOf: unusedDefault, encoding: .utf8), "Keep this file")
    }

    func testLiveMulticamRemuxFromPreflightAlternative() async throws {
        let preferences = EditorPreferences()
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        session.isMulticam = true
        defer { session.multicam.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("camera.mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        session.multicam.confirmSetup(drafts: [.init(source: .init(id: "a", file: source.path), media: media)],
                                      opening: "a", audio: .none)
        func render(_ output: URL, mode: String, dryRun: Bool) async throws -> [String: Any] {
            let ticket = try await sessions.mcpOutputs(tool: dryRun ? "export_editor_project_plan" : "export_editor_project_render", arguments: [
                "project_handle": session.mcpHandle, "output": output.path, "mode": mode
            ], session: session, checkAccess: {})
            return try await finished(XCTUnwrap(ticket), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        }
        let rejected = directory.appendingPathComponent("program.webm")
        let job = try await render(rejected, mode: "smart", dryRun: true)
        let check = try XCTUnwrap(job["result"] as? [String: Any])
        XCTAssertEqual(check["eligible"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        let offers = try XCTUnwrap(check["alternatives"] as? [[String: Any]])
        let mov = try XCTUnwrap(offers.first { $0["id"] as? String == "copy_other_container:mov" })
        let mode = try XCTUnwrap(mov["mode"] as? String)
        XCTAssertEqual(mode, "copy")
        let output = directory.appendingPathComponent("program.mov")
        let written = try await render(output, mode: mode, dryRun: false)
        XCTAssertEqual(written["outputs"] as? [String], [output.path])
        XCTAssertEqual(try CutEngine(useSidecar: false).inspect(output).duration, media.duration)

        let firstFrame = RationalTime(numerator: 7, denominator: 25)
        session.multicam.changeOccurrence(0, from: firstFrame)
        let cutJob = try await render(rejected, mode: "copy", dryRun: true)
        let cutCheck = try XCTUnwrap(cutJob["result"] as? [String: Any])
        XCTAssertEqual(cutCheck["eligible"] as? Bool, false)
        let cutOffers = try XCTUnwrap(cutCheck["alternatives"] as? [[String: Any]])
        XCTAssertFalse(cutOffers.contains { $0["rung"] as? String == "copy_other_container" })
        let trim = try XCTUnwrap(cutOffers.first { $0["id"] as? String == "smart_trim:mov" })
        XCTAssertEqual(trim["lossless"] as? Bool, false)
        let cutOutput = directory.appendingPathComponent("program-trimmed.mov")
        let cutWritten = try await render(cutOutput, mode: XCTUnwrap(trim["mode"] as? String), dryRun: false)
        XCTAssertEqual(cutWritten["outputs"] as? [String], [cutOutput.path])
        XCTAssertEqual(try CutEngine(useSidecar: false).inspect(cutOutput).duration, try media.duration.subtracting(firstFrame))
    }

    func testLiveMulticamSelectionExportPreservesOccurrencePictureOverride() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        session.isMulticam = true
        let model = session.multicam
        defer { model.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let drafts = try ["wide", "close"].map { id in
            let source = directory.appendingPathComponent(id).appendingPathExtension("mov")
            try FileManager.default.copyItem(at: fixture, to: source)
            let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
            return MulticamEditorModel.SourceDraft(source: .init(id: id, file: source.path), media: media)
        }
        model.confirmSetup(drafts: drafts, opening: "wide", audio: .none)
        XCTAssertTrue(model.setOccurrenceAngle(0, angle: "close"))
        let end = try XCTUnwrap(model.assemblyRangeEnds.last)
        model.selectAssemblyRange(.zero, end)
        XCTAssertEqual(model.exportProgram, .assembly)

        let output = directory.appendingPathComponent("Selected.mov")
        let ticket = try await sessions.mcpOutputs(tool: "export_editor_project_plan", arguments: [
            "project_handle": session.mcpHandle, "output": output.path, "mode": "copy", "tracks": "video", "scope": "selection"
        ], session: session, checkAccess: {})
        let done = try await finished(XCTUnwrap(ticket), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        let result = try XCTUnwrap(done["result"] as? [String: Any], String(describing: done))
        XCTAssertEqual(result["eligible"] as? Bool, true, String(describing: done))
        let plan = try XCTUnwrap(result["plan"] as? [String: Any])
        let mapping = try XCTUnwrap(plan["mapping"] as? [String: Any])
        let picture = try XCTUnwrap(mapping["picture"] as? [[String: Any]])
        XCTAssertEqual(picture.compactMap { $0["source"] as? String }, ["close"])
        let cutMap = try XCTUnwrap(result["cut_map"] as? [String: Any])
        let occurrences = try XCTUnwrap(cutMap["occurrences"] as? [[String: Any]])
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences.first?["output"] as? [String: String], ["from": "0", "to": end.description])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelledJobRetainsPartialOutputsAndTargetIsolation() async throws {
        let jobs = MCPLiveOutputJobs()
        let first = URL(fileURLWithPath: "/example/first.mov")
        let started = try jobs.start(owner: "A/1", revision: 8) { progress in
            progress.published(first)
            progress.update(0.5)
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.002) }
            throw CancellationError()
        }
        let id = try XCTUnwrap(started["job_id"] as? String)
        XCTAssertThrowsError(try jobs.status(owner: "B/1", id: id, cancel: true))
        let limit = ContinuousClock.now + .seconds(5)
        while .now < limit {
            if try jobs.status(owner: "A/1", id: id, cancel: false)["progress"] as? Double == 0.5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try jobs.status(owner: "A/1", id: id, cancel: true)
        let done = try await finished(started, owner: "A/1", in: jobs)
        XCTAssertEqual(done["outputs"] as? [String], [first.path])
        XCTAssertEqual(done["state"] as? String, "cancelled")
        jobs.disable()
        XCTAssertThrowsError(try jobs.status(owner: "A/1", id: id, cancel: false))
    }

    func testRevokedJobRemainsTrackedUntilWorkerCleanup() async throws {
        let jobs = MCPLiveOutputJobs()
        let release = DispatchSemaphore(value: 0)
        var cleaned = false
        let ticket = try jobs.start(owner: "A/1", revision: 1, finished: { cleaned = true }) { progress in
            progress.update(0.5)
            _ = release.wait(timeout: .now() + 5)
            try Task.checkCancellation()
            return [:]
        }
        defer { release.signal() }
        let id = try XCTUnwrap(ticket["job_id"] as? String)
        let limit = ContinuousClock.now + .seconds(3)
        while try jobs.status(owner: "A/1", id: id, cancel: false)["progress"] as? Double != 0.5 {
            guard .now < limit else { throw MCPCommandError("timeout", "Wait for the output worker to begin.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        jobs.close(owner: "A/2")
        jobs.disable()
        XCTAssertTrue(jobs.hasRunningJobs)
        XCTAssertFalse(cleaned)
        XCTAssertThrowsError(try jobs.status(owner: "A/1", id: id, cancel: false))
        let shutdown = Task { await jobs.cancelAndWaitForJobs() }
        await Task.yield()
        release.signal()
        await shutdown.value
        XCTAssertTrue(cleaned)
        XCTAssertFalse(jobs.hasRunningJobs)
    }

    func testMulticamFrameExportCountsJPEGsAndUnavailableAngles() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delayed = directory.appendingPathComponent("Delayed.mov")
        try FileManager.default.copyItem(at: source, to: delayed)
        let engine = CutEngine(useSidecar: false)
        session.multicam.confirmSetup(drafts: [
            .init(source: .init(id: "main", file: source.path), media: try engine.inspectMulticamSource(source)),
            .init(source: .init(id: "delayed", file: delayed.path, offset: .init(numerator: 1)), media: try engine.inspectMulticamSource(delayed))
        ], opening: "main", audio: .none)
        let frames = directory.appendingPathComponent("Frames")
        let ticket = try await sessions.mcpOutputs(tool: "review_editor_frames_export", arguments: [
            "project_handle": session.mcpHandle, "output": frames.path, "selection": "times", "times": ["0"]
        ], session: session, checkAccess: {})
        let done = try await finished(XCTUnwrap(ticket), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(done["state"] as? String, "succeeded", String(describing: done))
        let result = try XCTUnwrap(done["result"] as? [String: Any])
        XCTAssertEqual(result["frames"] as? Int, 1)
        XCTAssertEqual(result["unavailable"] as? Int, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: frames.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") }.count, 1)
    }

    func testRevokedReplacementPreservesThePublishedCopyAndTheOriginalTimeline() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov", subdirectory: "Fixtures"))
        let donor = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.editor.importFiles([source, source])
        let deadline = ContinuousClock.now + .seconds(15)
        while session.editor.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(15)) }
        let clips = session.editor.sequenceClips
        let occurrence = try XCTUnwrap(session.editor.mcpClipIDs.last)
        let revision = session.mcpRevision
        let output = directory.appendingPathComponent("Working.mov")
        var checks = 0
        do {
            _ = try await sessions.mcpOutputs(tool: "sequence_source_soundtrack_replace", arguments: [
                "project_handle": session.mcpHandle, "clip_id": occurrence.uuidString, "replacement": donor.path,
                "output": output.path, "target_audio_stream_index": 2, "replacement_audio_stream_index": 2
            ], session: session) {
                checks += 1
                if checks == 3 { throw MCPCommandError("control_disabled", "Local control was disabled.") }
            }
            XCTFail("The native replacement commit must check access again.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "control_disabled")
            XCTAssertTrue(error.message.contains(output.path))
        } catch {
            XCTFail("Audio replacement raised an unexpected error: \(error)")
            return
        }
        XCTAssertEqual(session.editor.sequenceClips, clips)
        XCTAssertEqual(session.mcpRevision, revision)
        XCTAssertEqual(try CutEngine(useSidecar: false).inspect(output).audio.count, 2)
    }
}
