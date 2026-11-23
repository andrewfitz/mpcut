import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class SceneScanHandoffTests: XCTestCase {
    @MainActor
    func testSelectedSequenceScanCanResumeInCLIAndBeReadThroughMCP() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("Three shots.mp4")
        let project = folder.appendingPathComponent("Sequence.cut")
        let from = RationalTime(numerator: 5)
        let to = RationalTime(numerator: 67)
        try await renderFixture(to: source)
        let clips = [
            CutSequenceClip(id: "first", file: source.path, from: .zero, to: .init(numerator: 3)),
            CutSequenceClip(id: "selected", file: source.path, from: from, to: to)
        ]
        try CutProject.sequence(clips).save(to: project)
        let projectBytes = try Data(contentsOf: project)

        let cli = productsDirectory.appendingPathComponent("mpcut")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path))
        let preferences = EditorPreferences()
        let sessions = ProjectSessions(preferences: preferences)
        sessions.mcpFileJobs = MCPFileJobs(executable: cli)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer {
            editor.endSession()
            sessions.mcpFileJobs.disable()
        }
        try editor.openProject(clips, at: project)
        try await wait(for: "the sequence to open") { editor.canEdit }
        XCTAssertEqual(editor.timelineClips.count, 2)
        let first = try XCTUnwrap(editor.timelineClips.first)
        let selected = try XCTUnwrap(editor.timelineClips.last)
        editor.select(selected.id)
        XCTAssertEqual(editor.sceneClipID, selected.id)
        XCTAssertTrue(editor.canScanSelectedScenes)
        editor.scanForScenes(clipID: editor.sceneClipID)

        let id = selected.id.uuidString
        try await wait(for: "the selected range to acquire confirmed coverage") {
            editor.sceneProgress == nil || editor.sceneCoverage[id]?.confirmed.map { $0 > from } == true
        }
        XCTAssertNotNil(editor.sceneProgress, "The fixture should still be scanning when coverage appears.")
        editor.cancelSceneAnalysis()
        try await wait(for: "the editor to finish saving its checkpoint") { editor.sceneProgress == nil }
        XCTAssertTrue(editor.scenePaused)
        let progress = try XCTUnwrap(editor.sceneCoverage[id])
        XCTAssertEqual(progress.requested, .range(start: from, end: to))
        let durable = try XCTUnwrap(progress.durable)
        XCTAssertGreaterThan(durable, from)
        XCTAssertLessThan(durable, to)
        XCTAssertNil(editor.sceneReport(clipID: first.id))
        XCTAssertNil(editor.sceneReport(clipID: selected.id))

        func attempts() async throws -> [[String: Any]] {
            let object = try await json(cli, ["analysis", "sidecar", "inspect", "--json", source.path])
            let inventory = try XCTUnwrap(object["inventory"] as? [String: Any])
            return try XCTUnwrap(inventory["scene_attempts"] as? [[String: Any]])
        }
        let before = try await attempts()
        XCTAssertEqual(before.count, 1)
        let checkpoint = try XCTUnwrap(before.first)
        let attempt = try XCTUnwrap(checkpoint["id"] as? String)
        XCTAssertEqual(checkpoint["state"] as? String, "paused")
        XCTAssertEqual(try XCTUnwrap(checkpoint["covered_through"] as? Double), durable.seconds, accuracy: 1e-9)

        let resumed = try await json(cli, ["scenes", "scan", "--json", "--policy", "resume", "--project", project.path, "--clip-id", "selected"])
        let sources = try XCTUnwrap(resumed["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.count, 1)
        let outcome = try XCTUnwrap(sources.first?["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["state"] as? String, "completed")
        let report = try XCTUnwrap(outcome["report"] as? [String: Any])
        let after = try await attempts()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?["id"] as? String, attempt)
        XCTAssertEqual(after.first?["state"] as? String, "completed")
        XCTAssertEqual(after.first?["covered_through"] as? Double, to.seconds)

        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            try await sessions.handleMCPCommand(tool: tool, arguments: arguments, session: session) {}
        }
        let job = try await call("scenes_file_scan", [
            "operation_id": UUID().uuidString, "file": source.path, "source_from": from.description, "source_to": to.description
        ])
        let jobID = try XCTUnwrap(job["job_id"] as? String)
        let deadline = ContinuousClock.now + .seconds(30)
        var received = try await call("file_job_status_read", ["job_id": jobID])
        while received["state"] as? String == "running", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            received = try await call("file_job_status_read", ["job_id": jobID])
        }
        XCTAssertEqual(received["state"] as? String, "succeeded", String(describing: received))
        let mcpReport = try XCTUnwrap(received["result"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: mcpReport), NSDictionary(dictionary: report))

        editor.scanForScenes(clipID: editor.sceneClipID)
        try await wait(for: "the editor to open the CLI's completed report") { editor.sceneProgress == nil }
        XCTAssertEqual(editor.sceneStatus, "Up to date")
        let live = try await call("scenes_editor_boundaries_list", ["clip_id": id])
        XCTAssertEqual(live["clip_id"] as? String, id)
        XCTAssertEqual(live["clock"] as? String, "source")
        let items = try XCTUnwrap(live["items"] as? [[String: Any]])
        let starts = try items.map { try RationalTime(parsing: XCTUnwrap($0["from"] as? String)).seconds }
        XCTAssertEqual(starts, [5, 24, 48])
        XCTAssertEqual(items.compactMap { $0["label"] as? String }, ["A", "B", "A"])
        XCTAssertEqual(try RationalTime(parsing: XCTUnwrap(items.last?["to"] as? String)), to)
        XCTAssertNil(editor.sceneReport(clipID: first.id))
        XCTAssertEqual(editor.sceneClipID, selected.id)
        XCTAssertEqual(try Data(contentsOf: project), projectBytes)
    }

    @MainActor
    private func wait(for description: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else {
            throw CutError(code: "test_timeout", message: "Timed out waiting for \(description).")
        }
    }

    private var productsDirectory: URL {
        var path = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        if path.lastPathComponent == "PlugIns" {
            path = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return path
    }

    private func renderFixture(to file: URL) async throws {
        let environment = ProcessInfo.processInfo.environment
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/ffmpeg" }
        let candidates: [String] = searchPath + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            + [environment["MPCUT_FFMPEG_HELPER"], bundled].compactMap { $0 }
        var ffmpeg: URL?
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let executable = URL(fileURLWithPath: candidate)
            guard let encoders = try? await run(executable, ["-hide_banner", "-encoders"]) else { continue }
            if String(decoding: encoders, as: UTF8.self).contains(" libx264 ") {
                ffmpeg = executable
                break
            }
        }
        guard let ffmpeg else { throw XCTSkip("FFmpeg with libx264 is required to render the scene handoff fixture.") }
        let graph = """
            color=red:s=1280x720:r=25:d=24[a];
            color=blue:s=1280x720:r=25:d=24[b];
            color=red:s=1280x720:r=25:d=24[c];
            [a][b][c]concat=n=3:v=1:a=0
            """.replacingOccurrences(of: "\n", with: "")
        _ = try await run(ffmpeg, [
            "-nostdin", "-v", "error", "-f", "lavfi", "-i", graph, "-c:v", "libx264",
            "-preset", "ultrafast", "-g", "75", "-bf", "2", "-sc_threshold", "0", file.path
        ])
    }

    private func json(_ executable: URL, _ arguments: [String]) async throws -> [String: Any] {
        let data = try await run(executable, arguments)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CutError(code: "test_process_failed",
                               message: "\(executable.lastPathComponent) exited with \(process.terminationStatus): \(String(decoding: data, as: UTF8.self))")
            }
            return data
        }.value
    }
}
