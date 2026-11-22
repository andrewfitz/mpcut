import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPOutputTests: XCTestCase {
    private func finished(_ job: [String: Any], owner: String, in jobs: MCPLiveOutputJobs) async throws -> [String: Any] {
        let id = try XCTUnwrap(job["job"] as? String)
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
        _ = try await session.editor.mcpCommand(tool: "split_at", arguments: ["space": "source", "time": "1001/30000",
                                                                               "occurrence": clip.uuidString], validateCommit: {})
        let cut = directory.appendingPathComponent("Snapshot.cut")
        let args: [String: Any] = ["project": session.mcpHandle, "output": cut.path]
        let result = try await sessions.mcpOutputs(tool: "convert_live_project", arguments: args, session: session, checkAccess: {})
        let ticket = try XCTUnwrap(result)
        session.editor.undo()
        let done = try await finished(ticket, owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(done["state"] as? String, "succeeded", String(describing: done))
        guard case .sequence(let clips) = try CutProject.load(from: cut) else { return XCTFail("Expected sequence") }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(session.editor.sequenceClips.count, 1)
        XCTAssertNil(session.editor.projectURL)
        let movie = directory.appendingPathComponent("Movie.mov")
        let check = try await sessions.mcpOutputs(tool: "render_project",
            arguments: ["project": session.mcpHandle, "output": movie.path, "mode": "copy"], session: session, checkAccess: {})
        let checked = try await finished(XCTUnwrap(check), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(checked["state"] as? String, "succeeded", String(describing: checked))
        XCTAssertEqual((checked["result"] as? [String: Any])?["eligible"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        let render = try await sessions.mcpOutputs(tool: "render_project", arguments: [
            "project": session.mcpHandle, "output": movie.path, "mode": "copy", "dryRun": false
        ], session: session, checkAccess: {})
        let rendered = try await finished(XCTUnwrap(render), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(rendered["state"] as? String, "succeeded", String(describing: rendered))
        XCTAssertEqual(rendered["outputs"] as? [String], [movie.path])
        XCTAssertGreaterThan(try CutEngine(useSidecar: false).inspect(movie).duration, .zero)
        let refusedOutput = directory.appendingPathComponent("Unsupported.invalid")
        let refused = try await sessions.mcpOutputs(tool: "render_project", arguments: [
            "project": session.mcpHandle, "output": refusedOutput.path, "mode": "copy"
        ], session: session, checkAccess: {})
        let preflight = try await finished(XCTUnwrap(refused), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        let issue = try XCTUnwrap(preflight["result"] as? [String: Any])
        XCTAssertEqual(issue["eligible"] as? Bool, false)
        XCTAssertEqual(issue["dryRun"] as? Bool, true)
        XCTAssertEqual((issue["issue"] as? [String: Any])?["code"] as? String, "unsupported_container")
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusedOutput.path))
        do {
            _ = try await sessions.mcpOutputs(tool: "render_project", arguments: [
                "project": session.mcpHandle, "output": directory.appendingPathComponent("PCM.mp4").path,
                "mode": "encode", "audio": "pcm"
            ], session: session, checkAccess: {})
            XCTFail("PCM in MP4 should be refused.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "unsupported_audio")
        }
        let frames = directory.appendingPathComponent("frames")
        let frameJob = try await sessions.mcpOutputs(tool: "export_review_frames", arguments: [
            "project": session.mcpHandle, "output": frames.path, "selection": "times", "times": ["0", "1001/30000"]
        ], session: session, checkAccess: {})
        let generated = try await finished(XCTUnwrap(frameJob), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(generated["state"] as? String, "succeeded", String(describing: generated))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: frames.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual((manifest?["frames"] as? [[String: Any]])?.count, 2)

        let editor = session.editor
        editor.selectRange(0, editor.duration)
        _ = try await sessions.mcpOutputs(tool: "add_export_range", arguments: ["project": session.mcpHandle],
                                          session: session, checkAccess: {})
        editor.deleteClip(try XCTUnwrap(editor.mcpClipIDs.first))
        XCTAssertTrue(editor.isEmpty)
        let queued = try await sessions.mcpOutputs(tool: "export_queue", arguments: [
            "project": session.mcpHandle, "output": directory.path, "mode": "copy", "dryRun": false
        ], session: session, checkAccess: {})
        let exported = try await finished(XCTUnwrap(queued), owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        XCTAssertEqual(exported["state"] as? String, "succeeded", String(describing: exported))
        XCTAssertEqual(exported["outputs"] as? [String], [directory.appendingPathComponent("ProRes-2997-001.mov").path])
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
        let id = try XCTUnwrap(started["job"] as? String)
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
        let id = try XCTUnwrap(ticket["job"] as? String)
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
        let ticket = try await sessions.mcpOutputs(tool: "export_review_frames", arguments: [
            "project": session.mcpHandle, "output": frames.path, "selection": "times", "times": ["0"]
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
            _ = try await sessions.mcpOutputs(tool: "replace_live_audio", arguments: [
                "project": session.mcpHandle, "clip": occurrence.uuidString, "replacement": donor.path,
                "output": output.path, "targetStream": 2, "replacementStream": 2
            ], session: session) {
                checks += 1
                if checks == 3 { throw MCPCommandError("control_disabled", "Local control was disabled.") }
            }
            XCTFail("The native replacement commit must check access again.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "control_disabled")
            XCTAssertTrue(error.message.contains(output.path))
        }
        XCTAssertEqual(session.editor.sequenceClips, clips)
        XCTAssertEqual(session.mcpRevision, revision)
        XCTAssertEqual(try CutEngine(useSidecar: false).inspect(output).audio.count, 2)
    }
}
