import Darwin
import Foundation
import XCTest
@testable import MPCutApp

final class MCPFileJobTests: XCTestCase {
    func testRenderRequestsPreserveNativeStructuredInputsAndLiteralPaths() throws {
        let path = "/tmp/interview $1;cut.mp4"
        let fields: [String: Any] = [
            "edit": ["output": "/tmp/final.mp4", "clips": [["file": path, "from": "1001/30000"], ["project": "/tmp/assembly.cut"]]],
            "dry_run": true, "no_sidecar": true, "mode": "smart"
        ]
        let request = try MCPFileRequest(tool: "file_export", fields: fields)
        XCTAssertEqual(request.arguments, ["export", "--json", "--dry-run", "--no-sidecar", "--mode", "smart", "--stdin"])
        let edit = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.input)) as? [String: Any])
        XCTAssertEqual((edit["clips"] as? [[String: String]])?.first?["file"], path)

        let csv = try MCPFileRequest(tool: "file_export", fields: [
            "edit": ["output": "/tmp/final.mp4", "clips": [["file": path, "csv": "/tmp/list.csv"]]]
        ])
        XCTAssertEqual(csv.arguments, ["export", "--json", "--output", "/tmp/final.mp4", "--clip", path, "--csv", "/tmp/list.csv"])
        XCTAssertNil(csv.input)
        XCTAssertThrowsError(try MCPFileRequest(tool: "file_inspect", fields: ["file": path, "project": path]))
        XCTAssertThrowsError(try MCPFileRequest(tool: "file_export", fields: ["file": path, "argv": ["--help"]]))
    }

    func testFileRequestAndSchemaKeepExactNumbersAndNativeInputChoices() throws {
        let schema = try MCPSchemas.loaded.get()
        let path = "/tmp/Interview.mov"
        let output = "/tmp/Selects.mov"
        let id = UUID().uuidString
        let start = ["numerator": 9_007_199_254_740_993, "denominator": Int.max]
        let ranges: [[String: Any]] = [["from": start, "to": "1"]]
        let args: [String: Any] = ["operationID": id, "file": path, "output": output, "ranges": ranges,
                                    "tracks": "audio", "audio_stream": Int.max]
        _ = try schema.validate(tool: "file_rearrange", arguments: args)
        let request = try MCPFileRequest(tool: "file_rearrange", fields: args)
        XCTAssertEqual(request.arguments.suffix(3), ["--", path, "9007199254740993/9223372036854775807-1"])
        XCTAssertTrue(request.arguments.contains("9223372036854775807"))
        XCTAssertThrowsError(try schema.validate(tool: "file_rearrange", arguments: args.merging(["ranges_file": "/tmp/list.csv"]) { _, new in new }))
        XCTAssertThrowsError(try schema.validate(tool: "file_rearrange", arguments: args.merging(["audio_stream": true]) { _, new in new }))
        XCTAssertThrowsError(try MCPFileRequest(tool: "file_frames", fields: ["file": path, "output": "/tmp/stills", "at": ["/tmp/list.csv"]]))

        let resolve = try MCPFileRequest(tool: "file_resolve", fields: [
            "project": "/tmp/Edit.cut", "output": "/tmp/Timeline.fcpxml", "no_sidecar": true
        ])
        XCTAssertEqual(resolve.arguments, ["resolve", "--json", "--no-sidecar", "--output", "/tmp/Timeline.fcpxml", "--project", "/tmp/Edit.cut"])
        XCTAssertThrowsError(try schema.validate(tool: "file_resolve", arguments: ["operationID": id, "project": "/tmp/Edit.cut"]))
    }

    func testSceneAndRefreshRequestsForwardNativeScopeAndPolicy() throws {
        let schemas = try MCPSchemas.loaded.get()
        let id = UUID()
        let file = "/tmp/Interview.mov"
        let project = "/tmp/Assembly.cut"
        let clip = UUID().uuidString
        func request(_ tool: String, _ args: [String: Any]) throws -> [String] {
            var input = args
            input["operationID"] = id.uuidString.lowercased()
            return try MCPFileRequest(tool: tool, fields: schemas.validate(tool: tool, arguments: input)).arguments
        }
        XCTAssertEqual(try request("file_scenes", ["file": file, "from": "1/3", "to": "2/3", "policy": "restart"]),
                       ["scenes", "--json", "--from", "1/3", "--to", "2/3", "--policy", "restart", "--operation-id",
                        id.uuidString, "--progress", "jsonl", "--", file])
        XCTAssertEqual(try request("file_scenes", ["project": project, "clip_id": clip, "policy": "resume"]),
                       ["scenes", "--json", "--clip-id", clip, "--policy", "resume", "--progress", "jsonl", "--project", project])
        XCTAssertEqual(try request("file_refresh", ["project": project, "deep": true, "no_sidecar": true]),
                       ["refresh", "--json", "--no-sidecar", "--deep", "--progress", "jsonl", "--project", project])
        XCTAssertThrowsError(try request("file_scenes", ["file": file, "from": "1"]))
        XCTAssertThrowsError(try request("file_scenes", ["project": project, "clip_id": clip, "all_sources": true]))
        XCTAssertThrowsError(try request("file_scenes", ["file": file, "project": project]))
        XCTAssertThrowsError(try request("file_refresh", ["file": file]))
    }

    @MainActor
    func testFileJobReplayResultAndCleanup() async throws {
        let cli = productsDirectory.appendingPathComponent("mpcut")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path))
        let jobs = MCPFileJobs(executable: cli)
        let id = UUID()
        let args = ["operationID": id.uuidString]
        _ = try jobs.start(tool: "file_version", arguments: args)
        let replay = try jobs.start(tool: "file_version", arguments: ["operationID": id.uuidString.lowercased()])
        XCTAssertEqual(replay["job_id"] as? String, id.uuidString)
        XCTAssertThrowsError(try jobs.start(tool: "file_help", arguments: args))
        let completed = try await wait(jobs, id: id)
        XCTAssertEqual(completed["state"] as? String, "succeeded")
        let report = try XCTUnwrap(completed["result"] as? [String: String])
        XCTAssertFalse(try XCTUnwrap(report["version"]).isEmpty)
        let page = try jobs.read(id: id, offset: 0, limit: 4)
        let decoded = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(page["base64"] as? String)))
        XCTAssertEqual(decoded.count, 4)
        XCTAssertThrowsError(try jobs.read(id: id, offset: -1, limit: 4))
        XCTAssertThrowsError(try jobs.read(id: id, offset: false, limit: 4))
        jobs.disable()
        XCTAssertThrowsError(try jobs.status(id: id))
    }

    @MainActor
    func testCLIFailureIsTerminalAndPreservesNativeError() async throws {
        let jobs = MCPFileJobs(executable: productsDirectory.appendingPathComponent("mpcut"))
        defer { jobs.disable() }
        let id = UUID()
        _ = try jobs.start(tool: "file_inspect", arguments: [
            "operationID": id.uuidString, "file": "/tmp/missing-" + UUID().uuidString, "no_sidecar": true
        ])
        let status = try await wait(jobs, id: id)
        XCTAssertEqual(status["state"] as? String, "failed")
        let report = try XCTUnwrap(status["result"] as? [String: Any])
        XCTAssertNotNil((report["error"] as? [String: Any])?["code"])
    }

    @MainActor
    func testSceneFileJobReportsCoverageSeparatelyFromSceneJSON() async throws {
        let cli = productsDirectory.appendingPathComponent("mpcut")
        let jobs = MCPFileJobs(executable: cli)
        defer { jobs.disable() }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let id = UUID()
        _ = try jobs.start(tool: "file_scenes", arguments: [
            "file": file.path, "operationID": id.uuidString, "no_sidecar": true, "from": "0", "to": "1"
        ])
        let completed = try await wait(jobs, id: id)
        XCTAssertEqual(completed["state"] as? String, "succeeded", String(describing: completed))
        let report = try XCTUnwrap(completed["result"] as? [String: Any])
        XCTAssertNotNil(report["scenes"])
        let event = try XCTUnwrap(completed["progress_event"] as? [String: Any])
        XCTAssertEqual(event["file"] as? String, file.path)
        let progress = try XCTUnwrap(event["progress"] as? [String: Any])
        XCTAssertNotNil(progress["requested"])
        XCTAssertNotNil(progress["confirmed"])
        XCTAssertNil(progress["durable"])
    }

    @MainActor
    func testDisableCancelsOutstandingWorkAndCleansItsSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mock = folder.appendingPathComponent("slow-cli")
        let ready = folder.appendingPathComponent("ready")
        try """
        #!/bin/sh
        trap 'exit 130' INT
        touch ready
        while true; do sleep 0.05; done
        """.write(to: mock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
        let jobs = MCPFileJobs(executable: mock)
        let id = UUID()
        var cleaned = false
        _ = try jobs.start(tool: "file_version",
                           arguments: ["operationID": id.uuidString, "working_directory": folder.path]) {
            cleaned = true
        }
        defer { jobs.disable() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        jobs.disable()
        XCTAssertThrowsError(try jobs.status(id: id))
        await jobs.cancelAndWaitForJobs()
        XCTAssertFalse(jobs.hasRunningJobs)
        XCTAssertTrue(cleaned)
    }

    @MainActor
    func testStopWaitsForUncooperativeWorkerAndPreventsDuplicateWhileDraining() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mock = folder.appendingPathComponent("stalled-cli")
        try """
        #!/bin/sh
        trap '' INT TERM
        echo $$ > worker
        exec /bin/sleep 30
        """.write(to: mock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
        let jobs = MCPFileJobs(executable: mock)
        let id = UUID()
        let args = ["operationID": id.uuidString, "working_directory": folder.path]
        var removed = 0
        _ = try jobs.start(tool: "file_version", arguments: args) { removed += 1 }
        let marker = folder.appendingPathComponent("worker")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        jobs.disable()
        XCTAssertTrue(jobs.hasRunningJobs)
        XCTAssertThrowsError(try jobs.start(tool: "file_version", arguments: args) { removed += 1 })
        XCTAssertEqual(removed, 1)
        await jobs.cancelAndWaitForJobs()
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(jobs.hasRunningJobs)
    }

    @MainActor
    func testRealCLIFilePlansResolveAndPreserveExistingOutput() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file jobs $;" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jobs = MCPFileJobs(executable: productsDirectory.appendingPathComponent("mpcut"))
        defer { jobs.disable() }

        func run(_ tool: String, _ fields: [String: Any], expected: String = "succeeded") async throws -> [String: Any] {
            let id = UUID()
            _ = try jobs.start(tool: tool, arguments: fields.merging(["operationID": id.uuidString]) { _, new in new })
            let completed = try await wait(jobs, id: id)
            XCTAssertEqual(completed["state"] as? String, expected, String(describing: completed))
            return try XCTUnwrap(completed["result"] as? [String: Any])
        }

        let to = ["numerator": 1001, "denominator": 3000]
        let ranges: [[String: Any]] = [["from": "0", "to": to]]
        let movie = folder.appendingPathComponent("Select.mov")
        let bulk = try await run("file_bulk", ["file": source.path, "output_directory": folder.path,
                                              "ranges": ranges, "dry_run": true, "no_sidecar": true])
        XCTAssertEqual((bulk["outputs"] as? [Any])?.count, 1)
        let rearrange = try await run("file_rearrange", ["file": source.path, "output": movie.path, "ranges": ranges,
                                                        "dry_run": true, "no_sidecar": true])
        XCTAssertEqual(rearrange["output"] as? String, movie.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        let original = Data("Existing output".utf8)
        try original.write(to: movie)
        _ = try await run("file_rearrange", ["file": source.path, "output": movie.path, "ranges": ranges,
                                             "no_sidecar": true], expected: "failed")
        XCTAssertEqual(try Data(contentsOf: movie), original)

        let camera = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let unsupported = folder.appendingPathComponent("Remux.webm")
        let refused = try await run("file_export", ["mode": "copy", "dry_run": true, "no_sidecar": true,
                                                    "edit": ["output": unsupported.path, "clips": [["file": camera.path]]]],
                                    expected: "failed")
        let issue = try XCTUnwrap(refused["error"] as? [String: Any])
        XCTAssertEqual(issue["code"] as? String, "unsupported_container")
        let alternatives = try XCTUnwrap(issue["alternatives"] as? [[String: Any]])
        let offer = try XCTUnwrap(alternatives.first { $0["id"] as? String == "copyOtherContainer:mov" })
        XCTAssertEqual(offer["lossless"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsupported.path))

        let remux = folder.appendingPathComponent("Remux.mov")
        let copied = try await run("file_export", ["mode": XCTUnwrap(offer["mode"] as? String), "no_sidecar": true,
                                                   "edit": ["output": remux.path, "clips": [["file": camera.path]]]])
        XCTAssertEqual(copied["mode"] as? String, "copy")
        XCTAssertEqual((copied["encodedDuration"] as? [String: Int])?["numerator"], 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remux.path))

        let xml = folder.appendingPathComponent("Resolve.fcpxml")
        let resolve = try await run("file_resolve", ["edit": ["output": xml.path,
                                                              "clips": [["file": source.path, "from": "0", "to": to]]],
                                                     "no_sidecar": true])
        XCTAssertEqual(resolve["output"] as? String, xml.path)
        XCTAssertTrue(try String(contentsOf: xml, encoding: .utf8).contains("<fcpxml"))
    }

    @MainActor
    func testLargeNativeWaveformUsesExactBytePages() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let jobs = MCPFileJobs(executable: productsDirectory.appendingPathComponent("mpcut"))
        defer { jobs.disable() }
        let id = UUID()
        _ = try jobs.start(tool: "file_waveform", arguments: ["operationID": id.uuidString, "file": source.path,
                                                             "columns": 65_536, "no_sidecar": true])
        let status = try await wait(jobs, id: id)
        XCTAssertEqual(status["state"] as? String, "succeeded")
        let total = try XCTUnwrap(status["result_bytes"] as? Int)
        XCTAssertGreaterThan(total, MCPFileJobs.chunkSize)
        XCTAssertNil(status["result"])
        var output = Data()
        while output.count < total {
            let page = try jobs.read(id: id, offset: output.count, limit: MCPFileJobs.chunkSize)
            let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(page["base64"] as? String)))
            XCTAssertFalse(data.isEmpty)
            if data.isEmpty { break }
            output.append(data)
            XCTAssertEqual(page["next_offset"] as? Int, output.count)
            XCTAssertEqual(page["done"] as? Bool, output.count == total)
        }
        XCTAssertEqual(output.count, total)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(result["columns"] as? Int, 65_536)
        XCTAssertEqual(((result["envelope"] as? [String: Any])?["low"] as? [Any])?.count, 65_536)
    }

    private var productsDirectory: URL {
        var path = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        if path.lastPathComponent == "PlugIns" {
            path = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return path
    }

    @MainActor
    private func wait(_ jobs: MCPFileJobs, id: UUID) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let status = try jobs.status(id: id)
            if let state = status["state"] as? String, ["succeeded", "failed", "cancelled"].contains(state) { return status }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for CLI job")
        return [:]
    }
}
