import Darwin
import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class MCPFileJobTests: XCTestCase {
    func testProjectMediaRoutingRequiresConfirmationAndDistinctMappingModes() throws {
        func request(_ command: String, _ fields: [String: Any]) throws -> MCPFileRequest {
            let base: [String: Any] = ["operation_id": UUID().uuidString, "project_path": "/tmp/project.cut"]
            return try MCPFileRequest(tool: "project_file_media_" + command,
                                      fields: base.merging(fields) { _, new in new })
        }
        let list = try request("list", [:])
        XCTAssertEqual(list.arguments, ["project", "media", "list", "--json", "/tmp/project.cut"])
        let locate = try request("locate", ["folder": "/tmp/moved"])
        XCTAssertEqual(locate.arguments.suffix(2), ["--folder", "/tmp/moved"])

        let mapping = ["from": "old.wav", "to": "/tmp/moved/copy.wav"]
        let relink = try request("relink", ["mappings": [mapping], "in_place": true])
        XCTAssertEqual(relink.arguments.suffix(5), ["--from", "old.wav", "--to", "/tmp/moved/copy.wav", "--in-place"])
        let prefix = try request("relink", ["from_prefix": "/old", "to_prefix": "/new", "in_place": true])
        XCTAssertEqual(prefix.arguments.suffix(3), ["--map-prefix", "/old=/new", "--in-place"])
        XCTAssertThrowsError(try request("relink", ["mappings": [mapping], "from": "old.wav", "in_place": true]))
        XCTAssertThrowsError(try request("relink", ["mappings": [mapping]]))

        let source: [String: Any] = ["source": "old.wav", "with": "/tmp/different.wav"]
        let preview = try request("replace", source)
        XCTAssertFalse(preview.arguments.contains("--in-place"))
        XCTAssertThrowsError(try request("replace", source.merging(["in_place": true]) { _, new in new }))
        XCTAssertThrowsError(try request("replace", source.merging(["confirm": true]) { _, new in new }))
        let apply = try request("replace", source.merging(["confirm": true, "in_place": true]) { _, new in new })
        XCTAssertTrue(apply.arguments.contains("--in-place"))
    }

    func testFileSilenceForwardsBlipDurationOnlyForNewScans() throws {
        let schema = try MCPSchemas.loaded.get()
        func request(_ fields: [String: Any]) throws -> MCPFileRequest {
            var args = fields
            args["operation_id"] = UUID().uuidString
            return try MCPFileRequest(tool: "silence_file_scan", fields: schema.validate(tool: "silence_file_scan", arguments: args))
        }
        let scan = try request(["file": "/tmp/interview.wav", "silence_max_blip_seconds": 0.3, "silence_padding_per_side_seconds": 0.25])
        XCTAssertEqual(scan.arguments, ["silence", "scan", "--json", "--padding-per-side-seconds", "0.25", "--max-blip-seconds", "0.3", "--", "/tmp/interview.wav"])
        for value: Any in [-0.01, 1.01, true, "0.3"] {
            XCTAssertThrowsError(try request(["file": "/tmp/interview.wav", "silence_max_blip_seconds": value]))
        }
        XCTAssertThrowsError(try request(["report": [:], "silence_max_blip_seconds": 0.3]))
        XCTAssertThrowsError(try request(["file": "/tmp/interview.wav", "protect_pauses": ["pause-1"]]))
        XCTAssertThrowsError(try request(["project_path": "/tmp/timeline.cut", "waveform": 64]))
    }

    func testFileRoutesKeepScanningPlanningAndPublicationDistinct() throws {
        let schemas = try MCPSchemas.loaded.get()
        let id = UUID().uuidString
        let source = ["operation_id": id, "file": "/tmp/source.mov"]
        let output = source.merging(["output": "/tmp/output.mov"]) { _, new in new }
        XCTAssertThrowsError(try schemas.validate(tool: "file_silence", arguments: source))
        XCTAssertThrowsError(try schemas.validate(tool: "silence_file_scan", arguments: output))
        XCTAssertThrowsError(try schemas.validate(tool: "silence_file_export", arguments: source))
        XCTAssertThrowsError(try schemas.validate(tool: "project_file_resolve_export",
                                                arguments: ["operation_id": id, "open": true,
                                                            "project_path": "/tmp/source.cut", "output": "/tmp/out.fcpxml"]))
        for (tool, path) in [("silence_file_plan", ["silence", "plan"]), ("silence_file_export", ["silence", "export"])] {
            let result = try MCPFileRequest(tool: tool, fields: output)
            XCTAssertEqual(Array(result.arguments.prefix(path.count)), path)
            XCTAssertTrue(MCPFileRequest.isFileTool(tool))
        }
        let frames = try MCPFileRequest(tool: "review_file_frames_export",
                                        fields: ["operation_id": id, "file": "/tmp/source.mov", "output": "/tmp/pictures",
                                                 "select": "non_silent", "silence_audio_stream_index": 2])
        XCTAssertEqual(frames.arguments, ["review", "frames", "export", "--json", "--stream", "2", "--select",
                                          "non-silent", "--output", "/tmp/pictures", "--", "/tmp/source.mov"])
        let inspect = try MCPFileRequest(tool: "media_file_inspect",
                                         fields: ["operation_id": id, "file": "/tmp/source.mov", "detail": "audio_packets",
                                                  "source_from": "1/2", "source_to": "2", "packet_audio_stream_index": 1])
        XCTAssertEqual(inspect.arguments, ["media", "inspect", "--json", "--stream", "1", "--from", "1/2", "--to", "2",
                                           "--audio-packets", "--", "/tmp/source.mov"])
        let help = try MCPFileRequest(tool: "cli_help_read", fields: ["operation_id": id, "topic": "silence plan"])
        XCTAssertEqual(help.arguments, ["help", "--json", "silence", "plan"])
    }

    func testSavedAssemblyFrameRequestsRequireExactTimes() throws {
        let fields = ["operation_id": UUID().uuidString, "project_path": "/tmp/Assembly.cut",
                      "clock": "assembly", "output": "/tmp/AssemblyFrames"]
        let tool = "review_file_frames_export"
        XCTAssertThrowsError(try MCPFileRequest(tool: tool, fields: fields))
        var timed: [String: Any] = fields
        timed["at"] = ["2/3"]
        let request = try MCPFileRequest(tool: tool, fields: timed)
        XCTAssertEqual(request.arguments, ["review", "frames", "export", "--json", "--clock", "assembly",
                                           "--output", "/tmp/AssemblyFrames", "--at", "2/3", "--project", "/tmp/Assembly.cut"])
        timed["select"] = "scenes"
        XCTAssertThrowsError(try MCPFileRequest(tool: tool, fields: timed))
    }

    func testSavedAuthoringForwardsMulticamRecordingOperations() throws {
        let tool = "project_file_edit"
        var operation = ["action": "add_recording", "angle_id": "wide",
                         "path": "/tmp/Recording 2.mov", "group_start": "1001/300"]
        func request(_ mutation: [String: String]) throws -> MCPFileRequest {
            try MCPFileRequest(tool: tool, fields: [
                "operation_id": UUID().uuidString,
                "request": ["project_path": "/tmp/Assembly.cut", "out_project": "/tmp/Updated.cut", "operations": [mutation]]
            ])
        }
        let encoded = try XCTUnwrap(request(operation).input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(body["operations"] as? [[String: String]], [operation])
        operation["group_start"] = nil
        XCTAssertThrowsError(try request(operation))
    }

    func testSavedMulticamAudioDeliveryAndSyncReachCLI() throws {
        let export = try MCPFileRequest(tool: "export_file_project_render", fields: [
            "operation_id": UUID().uuidString, "project_path": "/tmp/Mix.cut", "output": "/tmp/Mix.mov",
            "mode": "copy", "audio": "pcm", "audio_output": "downmix_stereo", "dry_run": true
        ])
        XCTAssertEqual(export.arguments, ["export", "project", "render", "--json", "--dry-run", "--audio", "pcm",
                                          "--audio-output", "downmix_stereo", "--mode", "copy",
                                          "--output", "/tmp/Mix.mov", "--project", "/tmp/Mix.cut"])
        let silenceFields: [String: Any] = [
            "operation_id": UUID().uuidString, "project_path": "/tmp/Mix.cut", "output": "/tmp/ShortMix.mov",
            "mode": "copy", "audio": "pcm", "audio_output": "downmix_mono"
        ]
        let silenceTool = "silence_file_plan"
        let silence = try MCPFileRequest(tool: silenceTool, fields: silenceFields)
        XCTAssertEqual(silence.arguments, ["silence", "plan", "--json", "--audio", "pcm", "--audio-output",
                                           "downmix_mono", "--mode", "copy", "--output", "/tmp/ShortMix.mov",
                                           "--project", "/tmp/Mix.cut"])
        XCTAssertThrowsError(try MCPFileRequest(tool: silenceTool,
                                                fields: silenceFields.filter { $0.key != "output" }))
        let fields: [String: Any] = [
            "operation_id": UUID().uuidString, "project_path": "/tmp/Mix.cut", "reference_source_id": "camera-b",
            "reference_stream": 1, "replacement": "/tmp/Replacement.wav", "replacement_stream": 0, "seed": "3/2"
        ]
        let tool = "multicam_file_sync_suggest"
        let sync = try MCPFileRequest(tool: tool, fields: fields)
        XCTAssertEqual(sync.arguments, ["multicam", "sync", "suggest", "--json", "--project", "/tmp/Mix.cut",
                                        "--reference-source-id", "camera-b", "--replacement", "/tmp/Replacement.wav",
                                        "--reference-stream", "1", "--replacement-stream", "0", "--seed", "3/2"])
        XCTAssertThrowsError(try MCPFileRequest(tool: tool, fields: fields.filter { $0.key != "replacement_stream" }))
        var program = fields
        program["reference_stream"] = nil
        XCTAssertThrowsError(try MCPFileRequest(tool: tool, fields: program))
        program["program"] = true
        let aligned = try MCPFileRequest(tool: tool, fields: program)
        XCTAssertEqual(aligned.arguments, ["multicam", "sync", "suggest", "--json", "--project", "/tmp/Mix.cut",
                                           "--reference-source-id", "camera-b", "--replacement", "/tmp/Replacement.wav",
                                           "--replacement-stream", "0", "--program", "--seed", "3/2"])
    }

    func testMulticamProgramReplacementSchemaKeepsLegacyRequests() throws {
        let schemas = try MCPSchemas.loaded.get()
        let base: [String: Any] = ["project_handle": "test", "expected_revision": 0, "operation_id": "replace"]
        let tool = "multicam_program_audio_set"
        var arguments = base
        arguments["mode"] = "follow"
        XCTAssertNoThrow(try schemas.validate(tool: tool, arguments: arguments))
        arguments["mode"] = "replace"
        arguments["replacement"] = "/tmp/Replacement.wav"
        XCTAssertNoThrow(try schemas.validate(tool: tool, arguments: arguments))
        arguments["reference_source_id"] = "camera-b"
        arguments["relative_offset"] = "-1/20"
        XCTAssertThrowsError(try schemas.validate(tool: tool, arguments: arguments))
        arguments["replacement_audio_stream_index"] = 0
        XCTAssertNoThrow(try schemas.validate(tool: tool, arguments: arguments))

        let sync = "multicam_track_audio_sync_suggest"
        var suggestion = base
        suggestion["original"] = ["source_id": "camera-b"]
        suggestion["path"] = "/tmp/Replacement.wav"
        suggestion["replacement_stream_index"] = 0
        XCTAssertThrowsError(try schemas.validate(tool: sync, arguments: suggestion))
        suggestion["program"] = true
        XCTAssertNoThrow(try schemas.validate(tool: sync, arguments: suggestion))
    }

    func testSavedTranscriptCorrectionKeepsCallerRecordID() throws {
        let request = try MCPFileRequest(tool: "transcript_file_words_correct", fields: [
            "operation_id": UUID().uuidString,
            "request": ["project_path": "/tmp/Assembly.cut", "in_place": true,
                        "record_id": "review-pass-7", "change": ["kind": "correction"]]
        ])
        XCTAssertEqual(request.arguments, ["transcript", "words", "correct", "--stdin", "--json"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.input)) as? [String: Any])
        XCTAssertEqual(body["record_id"] as? String, "review-pass-7")
    }

    func testFileExportRejectsDirectoryPathsAsNames() throws {
        XCTAssertThrowsError(try MCPFileRequest(tool: "export_file_ranges_separate", fields: [
            "operation_id": UUID().uuidString,
            "file": "/tmp/Interview.mov", "output_directory": "/tmp",
            "ranges": [["from": "0", "to": "1"]], "subfolder": "../other"
        ])) { error in
            XCTAssertEqual((error as? CutError)?.code, "invalid_output")
        }
    }

    func testRenderRequestsPreserveNativeStructuredInputsAndLiteralPaths() throws {
        let path = "/tmp/interview $1;cut.mp4"
        let fields: [String: Any] = [
            "operation_id": UUID().uuidString,
            "edit": ["output": "/tmp/final.mp4", "clips": [["file": path, "from": "1001/30000"], ["project_path": "/tmp/assembly.cut"]]],
            "dry_run": true, "no_sidecar": true, "mode": "smart"
        ]
        let request = try MCPFileRequest(tool: "export_file_clips_join", fields: fields)
        XCTAssertEqual(request.arguments, ["export", "clips", "join", "--json", "--dry-run", "--no-sidecar", "--mode", "smart", "--stdin"])
        let edit = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.input)) as? [String: Any])
        XCTAssertEqual((edit["clips"] as? [[String: String]])?.first?["file"], path)

        let csv = try MCPFileRequest(tool: "export_file_clips_join", fields: [
            "operation_id": UUID().uuidString,
            "edit": ["output": "/tmp/final.mp4", "clips": [
                ["file": path, "ranges_file": "/tmp/list.csv"], ["project_path": "/tmp/assembly.cut"]
            ]]
        ])
        XCTAssertEqual(csv.arguments, ["export", "clips", "join", "--json", "--stdin"])
        let csvEdit = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(csv.input)) as? [String: Any])
        XCTAssertEqual(csvEdit["clips"] as? [[String: String]], [
            ["file": path, "ranges_file": "/tmp/list.csv"], ["project_path": "/tmp/assembly.cut"]
        ])
        XCTAssertThrowsError(try MCPFileRequest(tool: "media_file_inspect", fields: ["file": path, "project_path": path]))
        XCTAssertThrowsError(try MCPFileRequest(tool: "export_file_clips_join", fields: ["file": path, "argv": ["--help"]]))
    }

    func testFileRequestAndSchemaKeepExactNumbersAndNativeInputChoices() throws {
        let schema = try MCPSchemas.loaded.get()
        let path = "/tmp/Interview.mov"
        let output = "/tmp/Selects.mov"
        let id = UUID().uuidString
        let start = ["numerator": 9_007_199_254_740_993, "denominator": Int.max]
        let ranges: [[String: Any]] = [["from": start, "to": "1"]]
        let args: [String: Any] = ["operation_id": id, "file": path, "output": output, "ranges": ranges,
                                    "tracks": "audio", "audio_stream_index": Int.max]
        _ = try schema.validate(tool: "export_file_ranges_join", arguments: args)
        let request = try MCPFileRequest(tool: "export_file_ranges_join", fields: args)
        XCTAssertEqual(request.arguments.suffix(3), ["--", path, "9007199254740993/9223372036854775807-1"])
        XCTAssertTrue(request.arguments.contains("9223372036854775807"))
        XCTAssertThrowsError(try schema.validate(tool: "export_file_ranges_join", arguments: args.merging(["ranges_file": "/tmp/list.csv"]) { _, new in new }))
        XCTAssertThrowsError(try schema.validate(tool: "export_file_ranges_join", arguments: args.merging(["audio_stream_index": true]) { _, new in new }))
        XCTAssertThrowsError(try MCPFileRequest(tool: "review_file_frames_export", fields: ["file": path, "output": "/tmp/stills", "at": ["/tmp/list.csv"]]))

        let resolve = try MCPFileRequest(tool: "project_file_resolve_export", fields: [
            "operation_id": UUID().uuidString,
            "project_path": "/tmp/Edit.cut", "output": "/tmp/Timeline.fcpxml", "no_sidecar": true
        ])
        XCTAssertEqual(resolve.arguments, ["project", "resolve", "export", "--json", "--no-sidecar", "--output", "/tmp/Timeline.fcpxml", "--project", "/tmp/Edit.cut"])
        XCTAssertThrowsError(try schema.validate(tool: "project_file_resolve_export", arguments: ["operation_id": id, "project_path": "/tmp/Edit.cut"]))
    }

    func testFileExportSpacingForwardsProjectsAndOrderedClips() throws {
        let schema = try MCPSchemas.loaded.get()
        let base: [String: Any] = ["operation_id": UUID().uuidString, "output": "/tmp/Spaced.mp4"]
        func request(_ fields: [String: Any]) throws -> MCPFileRequest {
            let args = base.merging(fields) { _, new in new }
            let tool = fields["clips_file"] == nil ? "export_file_project_render" : "export_file_clips_join"
            return try MCPFileRequest(tool: tool, fields: schema.validate(tool: tool, arguments: args))
        }
        let saved = try request(["project_path": "/tmp/Selects.cut", "space_clips": "source"])
        XCTAssertEqual(saved.arguments, ["export", "project", "render", "--json", "--output", "/tmp/Spaced.mp4",
                                         "--space-clips", "source", "--project", "/tmp/Selects.cut"])
        XCTAssertNil(saved.input)
        let inline = try request(["project_data": ["kind": "sequence"], "space_clips": "1001/15000"])
        XCTAssertEqual(inline.arguments, ["export", "project", "render", "--json", "--output", "/tmp/Spaced.mp4", "--space-clips", "1001/15000", "--project", "-"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(inline.input)) as? [String: String], ["kind": "sequence"])
        let rawFields: [String: Any] = ["operation_id": UUID().uuidString, "space_clips": "source",
            "edit": ["output": "/tmp/Spaced.mp4", "clips": [["file": "/tmp/Source.mp4", "from": "0", "to": "1"]]]]
        let raw = try MCPFileRequest(tool: "export_file_clips_join", fields: schema.validate(tool: "export_file_clips_join", arguments: rawFields))
        XCTAssertEqual(raw.arguments, ["export", "clips", "join", "--json", "--space-clips", "source", "--stdin"])
        let list = try request(["clips_file": "/tmp/Clips.csv", "space_clips": "source"])
        XCTAssertEqual(list.arguments, ["export", "clips", "join", "--json", "--output", "/tmp/Spaced.mp4",
                                        "--space-clips", "source", "--clips", "/tmp/Clips.csv"])
        XCTAssertThrowsError(try request(["project_path": "/tmp/Selects.cut", "space_clips": "-1"]))
    }

    func testSidecarToolsForwardBothProjectAndRecording() throws {
        let schemas = try MCPSchemas.loaded.get()
        for action in ["build", "inspect"] {
            let tool = "analysis_file_sidecar_" + action
            let fields: [String: Any] = ["operation_id": UUID().uuidString, "project_path": "/tmp/A.cut", "file": "/tmp/B.mov"]
            let request = try MCPFileRequest(tool: tool, fields: schemas.validate(tool: tool, arguments: fields))
            XCTAssertEqual(request.arguments, ["analysis", "sidecar", action, "--json", "--project", "/tmp/A.cut", "--", "/tmp/B.mov"])
        }
    }

    func testSceneAndRefreshRequestsForwardNativeScopeAndPolicy() throws {
        let schemas = try MCPSchemas.loaded.get()
        let id = UUID()
        let file = "/tmp/Interview.mov"
        let project = "/tmp/Assembly.cut"
        let clip = ProjectIdentifier.make()
        func request(_ tool: String, _ args: [String: Any]) throws -> [String] {
            var input = args
            input["operation_id"] = id.uuidString.lowercased()
            return try MCPFileRequest(tool: tool, fields: schemas.validate(tool: tool, arguments: input)).arguments
        }
        XCTAssertEqual(try request("scenes_file_scan", ["file": file, "source_from": "1/3", "source_to": "2/3", "policy": "restart"]),
                       ["scenes", "scan", "--json", "--from", "1/3", "--to", "2/3", "--policy", "restart", "--operation-id",
                        id.uuidString, "--progress", "jsonl", "--", file])
        XCTAssertEqual(try request("scenes_file_scan", ["project_path": project, "clip_id": clip, "policy": "resume"]),
                       ["scenes", "scan", "--json", "--clip-id", clip, "--policy", "resume", "--progress", "jsonl", "--project", project])
        XCTAssertEqual(try request("project_file_media_refresh", ["project_path": project, "deep": true, "no_sidecar": true]),
                       ["project", "media", "refresh", "--json", "--no-sidecar", "--deep", "--progress", "jsonl", "--project", project])
        XCTAssertThrowsError(try request("scenes_file_scan", ["file": file, "source_from": "1"]))
        XCTAssertThrowsError(try request("scenes_file_scan", ["project_path": project, "clip_id": clip, "all_sources": true]))
        XCTAssertThrowsError(try request("scenes_file_scan", ["file": file, "project_path": project]))
        XCTAssertThrowsError(try request("project_file_media_refresh", ["file": file]))
    }

    func testSavedSyncForwardsExplicitReferenceRecording() throws {
        let schema = try MCPSchemas.loaded.get()
        let tool = "multicam_file_sync_suggest"
        let fields: [String: Any] = ["operation_id": UUID().uuidString, "project_path": "/tmp/Assembly.cut",
                                     "source_id": "target", "reference_source_id": "restart", "metadata_only": true]
        let command = try MCPFileRequest(tool: tool, fields: schema.validate(tool: tool, arguments: fields))
        XCTAssertEqual(command.arguments, [
            "multicam", "sync", "suggest", "--json", "--project", "/tmp/Assembly.cut",
            "--source-id", "target", "--reference-source-id", "restart", "--metadata-only"
        ])
    }

    @MainActor
    func testFileJobReplayResultAndCleanup() async throws {
        let cli = productsDirectory.appendingPathComponent("mpcut")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path))
        let jobs = MCPFileJobs(executable: cli)
        let id = UUID()
        let args = ["operation_id": id.uuidString]
        _ = try jobs.start(tool: "cli_version_read", arguments: args)
        let replay = try jobs.start(tool: "cli_version_read", arguments: ["operation_id": id.uuidString.lowercased()])
        XCTAssertEqual(replay["job_id"] as? String, id.uuidString)
        XCTAssertThrowsError(try jobs.start(tool: "cli_help_read", arguments: args))
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
        _ = try jobs.start(tool: "media_file_inspect", arguments: [
            "operation_id": id.uuidString, "file": "/tmp/missing-" + UUID().uuidString, "no_sidecar": true
        ])
        let status = try await wait(jobs, id: id)
        XCTAssertEqual(status["state"] as? String, "failed")
        let report = try XCTUnwrap(status["result"] as? [String: Any])
        XCTAssertNotNil((report["error"] as? [String: Any])?["code"])
    }

    @MainActor
    func testParticipantScanFileJobPreservesIntegerProgressAndReservesCompletionForSuccess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mock = folder.appendingPathComponent("scan-cli")
        try """
        #!/bin/sh
        cd "$(dirname "$0")" || exit 2
        echo '{"event":"progress","phase":"scanning","fraction":0.29,"percent":29}' >&2
        while [ ! -f release ]; do sleep 0.02; done
        if [ -f fail ]; then
            echo '{"event":"progress","fraction":1}' >&2
            exit 1
        fi
        """.write(to: mock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
        let jobs = MCPFileJobs(executable: mock)
        defer { jobs.disable() }
        let file = folder.appendingPathComponent("grid.mov").path
        let id = UUID()
        _ = try jobs.start(tool: "participants_file_scan", arguments: ["operation_id": id.uuidString, "file": file])
        let deadline = ContinuousClock.now + .seconds(10)
        var live = try jobs.status(id: id)
        while live["progress_event"] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            live = try jobs.status(id: id)
        }
        XCTAssertEqual(live["progress_percent"] as? Int, 29)
        try Data().write(to: folder.appendingPathComponent("release"))
        let succeeded = try await wait(jobs, id: id)
        XCTAssertEqual(succeeded["state"] as? String, "succeeded")
        XCTAssertEqual(succeeded["progress_percent"] as? Int, 100)
        try Data().write(to: folder.appendingPathComponent("fail"))
        let failedID = UUID()
        _ = try jobs.start(tool: "participants_file_scan", arguments: ["operation_id": failedID.uuidString, "file": file])
        let failed = try await wait(jobs, id: failedID)
        XCTAssertEqual(failed["state"] as? String, "failed")
        XCTAssertEqual(failed["progress_percent"] as? Int, 99)
    }

    @MainActor
    func testSceneFileJobReportsCoverageSeparatelyFromSceneJSON() async throws {
        let cli = productsDirectory.appendingPathComponent("mpcut")
        let jobs = MCPFileJobs(executable: cli)
        defer { jobs.disable() }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let id = UUID()
        _ = try jobs.start(tool: "scenes_file_scan", arguments: [
            "file": file.path, "operation_id": id.uuidString, "no_sidecar": true, "source_from": "0", "source_to": "1"
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
        _ = try jobs.start(tool: "cli_version_read",
                           arguments: ["operation_id": id.uuidString, "working_directory": folder.path]) {
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
        let args = ["operation_id": id.uuidString, "working_directory": folder.path]
        var removed = 0
        _ = try jobs.start(tool: "cli_version_read", arguments: args) { removed += 1 }
        let marker = folder.appendingPathComponent("worker")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        jobs.disable()
        XCTAssertTrue(jobs.hasRunningJobs)
        XCTAssertThrowsError(try jobs.start(tool: "cli_version_read", arguments: args) { removed += 1 })
        XCTAssertEqual(removed, 1)
        await jobs.cancelAndWaitForJobs()
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(jobs.hasRunningJobs)
    }

    @MainActor
    func testFileEditKeepsUserHistoryAndRecordsAgent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let project = directory.appendingPathComponent("Original.cut")
        let destination = directory.appendingPathComponent("Edited.cut")
        let clip = CutSequenceClip(id: "first", file: source.path, from: .zero, to: .init(numerator: 1))
        try CutProject.sequence([clip]).save(to: project, undo: [.init(action: "Add Clip", project: .sequence([]))], redo: [])
        let jobs = MCPFileJobs(executable: productsDirectory.appendingPathComponent("mpcut"))
        defer { jobs.disable() }
        let id = UUID()
        _ = try jobs.start(tool: "project_file_edit", arguments: [
            "operation_id": id.uuidString,
            "request": ["project_path": project.path, "out_project": destination.path,
                        "operations": [["action": "remove", "id": "first"]]]
        ])
        let result = try await wait(jobs, id: id)
        XCTAssertEqual(result["state"] as? String, "succeeded", result.description)
        let history = try CutProject.loadHistory(from: destination, limit: 10)
        XCTAssertEqual(history.undo.map(\.origin), [.user, .agent])
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
            _ = try jobs.start(tool: tool, arguments: fields.merging(["operation_id": id.uuidString]) { _, new in new })
            let completed = try await wait(jobs, id: id)
            XCTAssertEqual(completed["state"] as? String, expected, String(describing: completed))
            return try XCTUnwrap(completed["result"] as? [String: Any])
        }

        let to = ["numerator": 1001, "denominator": 3000]
        let ranges: [[String: Any]] = [["from": "0", "to": to]]
        let movie = folder.appendingPathComponent("Select.mov")
        let bulk = try await run("export_file_ranges_separate", ["file": source.path, "output_directory": folder.path,
                                              "ranges": ranges, "base_name": "Select", "subfolder": "Review",
                                              "dry_run": true, "no_sidecar": true])
        let outputs = try XCTUnwrap(bulk["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        let output = try XCTUnwrap(outputs.first?["output"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: output).deletingLastPathComponent().lastPathComponent, "Review")
        XCTAssertTrue(URL(fileURLWithPath: output).lastPathComponent.hasPrefix("Select-"))
        let rearrange = try await run("export_file_ranges_join", ["file": source.path, "output": movie.path, "ranges": ranges,
                                                        "dry_run": true, "no_sidecar": true])
        XCTAssertEqual(rearrange["output"] as? String, movie.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        let original = Data("Existing output".utf8)
        try original.write(to: movie)
        _ = try await run("export_file_ranges_join", ["file": source.path, "output": movie.path, "ranges": ranges,
                                             "no_sidecar": true], expected: "failed")
        XCTAssertEqual(try Data(contentsOf: movie), original)

        let camera = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let unsupported = folder.appendingPathComponent("Remux.webm")
        let refused = try await run("export_file_clips_join", ["mode": "copy", "dry_run": true, "no_sidecar": true,
                                                    "edit": ["output": unsupported.path, "clips": [["file": camera.path]]]],
                                    expected: "failed")
        let issue = try XCTUnwrap(refused["error"] as? [String: Any])
        XCTAssertEqual(issue["code"] as? String, "unsupported_container")
        let alternatives = try XCTUnwrap(issue["alternatives"] as? [[String: Any]])
        let offer = try XCTUnwrap(alternatives.first { $0["id"] as? String == "copy_other_container:mov" })
        XCTAssertEqual(offer["lossless"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsupported.path))

        let remux = folder.appendingPathComponent("Remux.mov")
        let copied = try await run("export_file_clips_join", ["mode": XCTUnwrap(offer["mode"] as? String), "no_sidecar": true,
                                                   "edit": ["output": remux.path, "clips": [["file": camera.path]]]])
        XCTAssertEqual(copied["mode"] as? String, "copy")
        XCTAssertEqual((copied["encoded_duration"] as? [String: Int])?["numerator"], 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remux.path))

        let xml = folder.appendingPathComponent("Resolve.fcpxml")
        let resolve = try await run("project_file_resolve_export", ["edit": ["output": xml.path,
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
        _ = try jobs.start(tool: "waveform_file_envelope_read", arguments: ["operation_id": id.uuidString, "file": source.path,
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
