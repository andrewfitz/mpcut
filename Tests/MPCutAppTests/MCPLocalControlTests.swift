import AppKit
import Darwin
import MPCutCore
import XCTest
@testable import MPCutApp

final class MCPLocalControlTests: XCTestCase {
    func testSplitToolsRejectRetiredSelectorsAndCrossFamilyActions() throws {
        let schemas = try MCPSchemas.loaded.get()
        let audioPolicy = MulticamAudioPolicy.fixed(.init(source: "mic", stream: 2))
        let audio = try JSONSerialization.jsonObject(with: MCPSchemas.encodeResult(audioPolicy))
        XCTAssertNoThrow(try schemas.validate(tool: "multicam_setup_confirm", arguments: [
            "project_handle": "window", "operation_id": "setup", "expected_revision": 0, "audio": audio
        ]))
        XCTAssertThrowsError(try schemas.validate(tool: "project_editor_state_read", arguments: ["project": "old"]))
        XCTAssertThrowsError(try schemas.validate(tool: "project_editor_state_read", arguments: ["project_path": "/tmp/demo.cut"]))
        XCTAssertThrowsError(try schemas.validate(tool: "project_open", arguments: ["operation_id": "open", "project_handle": "window"]))
        XCTAssertNoThrow(try schemas.validate(tool: "project_editor_state_read", arguments: ["project_handle": "window"]))
        let edit: [String: Any] = ["project_handle": "window", "expected_revision": 1, "operation_id": "edit"]
        for retired in ["render_project", "configure_silence", "set_playback", "sequence_control"] {
            XCTAssertThrowsError(try schemas.validate(tool: retired, arguments: edit))
        }
        for (tool, fields) in [
            ("export_editor_project_plan", ["output": "/tmp/movie.mov", "dry_run": false]),
            ("silence_editor_scan", ["kind": "scenes"]),
            ("silence_editor_takes_queue", ["mode": "shorten"]),
            ("sequence_clip_edit", ["action": "speed", "rate": 1]),
            ("timeline_gap_insert", ["at": "0", "duration": "1", "space": "sequence", "path": "/tmp/card.png"])
        ] as [(String, [String: Any])] {
            XCTAssertThrowsError(try schemas.validate(tool: tool, arguments: edit.merging(fields) { _, v in v }), tool)
        }
    }

    func testRejectsMalformedSchemaArgumentsAtAppBoundary() throws {
        let schemas = try MCPSchemas.loaded.get()
        XCTAssertThrowsError(try schemas.validate(tool: "project_editor_state_read", arguments: ["project_handle": "a", "limit": true]))
        XCTAssertThrowsError(try schemas.validate(tool: "project_editor_state_read", arguments: ["project_handle": "a", "offset": -1]))
        XCTAssertThrowsError(try schemas.validate(tool: "timeline_playhead_seek", arguments: ["project_handle": "a", "space": "group", "time": "1", "occurrence": true]))
        XCTAssertThrowsError(try schemas.validate(tool: "timeline_item_split", arguments: ["project_handle": "a", "space": "group", "time": "1"]))
        XCTAssertThrowsError(try schemas.validate(tool: "project_windows_list", arguments: ["surprise": true]))
        XCTAssertNoThrow(try schemas.validate(tool: "project_editor_state_read", arguments: ["project_handle": "a", "limit": 1]))
        XCTAssertNoThrow(try schemas.validate(tool: "project_editor_state_read", arguments: ["project_handle": "a", "offset": Int.max]))
        XCTAssertThrowsError(try schemas.validate(tool: "project_editor_state_read", arguments: ["project_handle": "a", "offset": UInt64.max]))
        let threshold: (Any) -> [String: Any] = { ["project_handle": "a", "expected_revision": 0,
                                                   "operation_id": "threshold", "silence_threshold_db": $0] }
        for value: Any in [NSNull(), -36.5] as [Any] {
            XCTAssertNoThrow(try schemas.validate(tool: "silence_editor_threshold_set", arguments: threshold(value)))
        }
        for value: Any in [true, "auto", -121] as [Any] {
            XCTAssertThrowsError(try schemas.validate(tool: "silence_editor_threshold_set", arguments: threshold(value)))
        }
        let playback: [String: Any] = ["project_handle": "a", "expected_revision": 0, "operation_id": "playback-rate", "action": "speed"]
        let rate: (Any) -> [String: Any] = { playback.merging(["rate": $0]) { _, new in new } }
        XCTAssertThrowsError(try schemas.validate(tool: "playback_transport_control", arguments: rate(true)))
        XCTAssertThrowsError(try schemas.validate(tool: "playback_transport_control", arguments: rate(3.0)))
        XCTAssertNoThrow(try schemas.validate(tool: "playback_transport_control", arguments: rate(1.25)))
        let still: [String: Any] = ["project_handle": "a", "expected_revision": 0, "operation_id": "image-edit",
                                    "path": "/tmp/card.png"]
        let insert = still.merging(["space": "assembly", "at": "0", "duration": "1"]) { _, new in new }
        let replacement = still.merging(["space": "group", "from": "0", "to": "1"]) { _, new in new }
        XCTAssertNoThrow(try schemas.validate(tool: "still_editor_placement_insert", arguments: insert))
        XCTAssertNoThrow(try schemas.validate(tool: "still_editor_picture_replace", arguments: replacement))
        for (arguments, excluded) in [(insert, ["from", "to"]), (replacement, ["at", "duration", "cadence"])] {
            for key in excluded {
                var mixed = arguments
                mixed[key] = "1"
                XCTAssertThrowsError(try schemas.validate(tool: arguments["at"] == nil ? "still_editor_picture_replace" : "still_editor_placement_insert", arguments: mixed), key)
            }
        }
        let spacing: [String: Any] = ["project_handle": "a", "expected_revision": 0, "operation_id": "spacing"]
        XCTAssertNoThrow(try schemas.validate(tool: "timeline_clips_space", arguments: spacing.merging(["duration": "0"]) { _, new in new }))
        XCTAssertNoThrow(try schemas.validate(tool: "timeline_clips_space", arguments: spacing.merging(["source_timing": true]) { _, new in new }))
        XCTAssertThrowsError(try schemas.validate(tool: "timeline_clips_space", arguments: spacing))
        XCTAssertThrowsError(try schemas.validate(tool: "timeline_clips_space",
                                                  arguments: spacing.merging(["duration": "1", "source_timing": true]) { _, new in new }))
        XCTAssertThrowsError(try schemas.validate(tool: "timeline_clips_space", arguments: spacing.merging(["source_timing": false]) { _, new in new }))
        XCTAssertThrowsError(try schemas.validate(tool: "review_editor_frame_read", arguments: ["project_handle": "a", "space": "sequence"]))
        XCTAssertThrowsError(try schemas.validate(tool: "review_editor_frame_read", arguments: ["project_handle": "a", "time": "0"]))
        XCTAssertNoThrow(try schemas.validate(tool: "review_editor_frame_read", arguments: ["project_handle": "a", "space": "sequence", "time": "0"]))
        let output: [String: Any] = ["project_handle": "a", "expected_revision": 0, "operation_id": "frame-export", "output": "/tmp/review"]
        XCTAssertThrowsError(try schemas.validate(tool: "review_editor_frames_export",
                                                   arguments: output.merging(["selection": "times"]) { _, new in new }))
        XCTAssertNoThrow(try schemas.validate(tool: "review_editor_frames_export",
                                              arguments: output.merging(["selection": "times", "times": ["0"]]) { _, new in new }))
        let inlineArguments: [String: Any] = [
            "operation_id": "42970FFD-0FF6-42C1-BF05-0ECFAD579C1E",
            "project_data": ["history": [9_007_199_254_740_992]]
        ]
        let inlinePath = MCPSchemas.projectDataPath + [.key("history"), .index(0)]
        let inline = try schemas.validate(tool: "project_file_inspect", arguments: inlineArguments,
                                          wireIntegers: [inlinePath: .init(exact: 9_007_199_254_740_993)])
        XCTAssertEqual((inline["project_data"] as? [String: Any])?["history"] as? [Int], [9_007_199_254_740_993])
    }

    func testInlineProjectsAllowFractionalAssetAndAnnotationFields() async throws {
        func request(_ fields: String) -> Data {
            Data(#"{"version":2,"tool":"project_file_inspect","arguments":{"project_data":{"schema_version":9,"format":"mpcut","kind":"sequence","clips":[],\#(fields)}}}"#.utf8)
        }
        let fields = #""embedded_assets":{"transcripts":{"asset":{"words":[{"c":0.93}]}}},"analysis_annotations":{"silence":[{"threshold_db":-37.5}]}"#
        let (_, arguments, _) = try await MCPLocalControl.decode(request(fields))
        let project = try XCTUnwrap(arguments["project_data"] as? [String: Any])
        let annotations = try XCTUnwrap(project["analysis_annotations"] as? [String: Any])
        XCTAssertEqual((annotations["silence"] as? [[String: Double]])?.first?["threshold_db"], -37.5)

        let history = #""history":{"undo":[{"analysis_annotations":{"silence":[{"~":"value"}]}}]}"#
        _ = try await MCPLocalControl.decode(request(history + #","refs":{"value":{"threshold_db":-42.25}}"#))
        let bad = #""history":{"undo":[{"clips":[{"~":"value"}]}]},"refs":{"value":{"track_ordinal":1.000000000000000001}}"#
        do {
            _ = try await MCPLocalControl.decode(request(bad))
            XCTFail("Accepted a fractional track ordinal in retained history")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "invalid_arguments")
        }
    }

    @MainActor
    func testToggleAndDocumentGenerations() async throws {
        _ = NSApplication.shared
        let directory = "/tmp/mpcut-test-" + UUID().uuidString
        let suite = "mpcut-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(atPath: directory) }
        let preferences = EditorPreferences(defaults: defaults)
        let sessions = ProjectSessions(preferences: preferences)
        let bridge = MCPLocalControl(sessions: sessions, socket: MCPSocket(directory: directory))
        bridge.observeSetting()
        defer { bridge.stop() }
        XCTAssertFalse(bridge.running)
        preferences.localMCPEnabled = true
        XCTAssertTrue(bridge.running)
        XCTAssertTrue(EditorPreferences(defaults: defaults).localMCPEnabled)
        let listed = try await socketReply(#"{"version":2,"tool":"project_windows_list","arguments":{}}"#, directory: directory)
        XCTAssertEqual((listed["result"] as? [String: Any])?["projects"] as? [[String: String]], [])
        let duplicate = try await socketReply(#"{"version":2,"tool":"project_windows_list","arguments":{},"arguments":{}}"#, directory: directory)
        XCTAssertEqual((duplicate["error"] as? [String: String])?["code"], "invalid_arguments")
        for invalidVersion in ["true", "1", "2.0000000000000001"] {
            let wrongVersion = try await socketReply(#"{"version":\#(invalidVersion),"tool":"project_windows_list","arguments":{}}"#, directory: directory)
            XCTAssertEqual((wrongVersion["error"] as? [String: String])?["code"], "bridge_version")
        }
        let fractionalPreference = try await socketReply(
            #"{"version":2.0,"tool":"preferences_set","arguments":{"operation_id":"fractional-volume","key":"playback_preview_volume_fraction","value":0.375}}"#,
            directory: directory)
        XCTAssertEqual((fractionalPreference["result"] as? [String: Any])?["playback_preview_volume_fraction"] as? Double, 0.375)
        let fractionalHistoryLimit = try await socketReply(
            #"{"version":2,"tool":"preferences_set","arguments":{"operation_id":"fractional-history","key":"history_max_steps","value":1.0000000000000001}}"#,
            directory: directory)
        XCTAssertEqual((fractionalHistoryLimit["error"] as? [String: String])?["code"], "invalid_arguments")
        let fractionalOrder = try await socketReply(
            #"{"version":2,"tool":"export_file_clips_join","arguments":{"operation_id":"42970FFD-0FF6-42C1-BF05-0ECFAD579C1E","edit":{"clips":[{"file":"/tmp/example.mov"}],"order":[1,1.0000000000000001],"output":"/tmp/example-out.mov"}}}"#,
            directory: directory)
        let orderError = try XCTUnwrap(fractionalOrder["error"] as? [String: String])
        XCTAssertEqual(orderError["code"], "invalid_arguments")
        XCTAssertTrue(orderError["message"]?.contains("edit.order[1]") == true)
        let fractionalProject = try await socketReply(
            #"{"version":2,"tool":"project_file_inspect","arguments":{"operation_id":"42970FFD-0FF6-42C1-BF05-0ECFAD579C1E","project_data":{"format":"mpcut","schema_version":9.0000000000000001,"kind":"sequence","clips":[]}}}"#,
            directory: directory)
        let projectError = try XCTUnwrap(fractionalProject["error"] as? [String: String])
        XCTAssertEqual(projectError["code"], "invalid_arguments")
        XCTAssertTrue(projectError["message"]?.contains("project_data") == true)
        let setVolume: [String: Any] = ["key": "playback_preview_volume_fraction", "value": 0.5, "operation_id": UUID().uuidString]
        _ = try await bridge.perform(tool: "preferences_set", arguments: setVolume)
        preferences.volume = 0.75
        _ = try await bridge.perform(tool: "preferences_set", arguments: setVolume)
        XCTAssertEqual(preferences.volume, 0.75, "Replaying a completed call must preserve subsequent GUI settings.")
        var conflict = setVolume
        conflict["value"] = 0.2
        do {
            _ = try await bridge.perform(tool: "preferences_set", arguments: conflict)
            XCTFail("Operation ID reuse with different arguments should fail")
        } catch let error as MCPFailure { XCTAssertEqual(error.code, "operation_conflict") }
        let session = sessions.session(for: nil)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { sessions.windowClosed(session); window.close() }
        let sequence = session.mcpHandle
        let result = try await bridge.perform(tool: "project_editor_state_read", arguments: ["project_handle": sequence])
        XCTAssertEqual(result["total"] as? Int, 0)
        for offset in ["1.0000000000000001", "10000000000000001e-16", "9223372036854775808.0"] {
            let reply = try await socketReply(
                #"{"version":2e0,"tool":"project_editor_state_read","arguments":{"project_handle":"\#(sequence)","offset":\#(offset)}}"#,
                directory: directory)
            XCTAssertEqual((reply["error"] as? [String: String])?["code"], "invalid_arguments", offset)
        }
        for (offset, expected) in [("1.0", 1), ("1e0", 1), ("10e-1", 1), ("9007199254740993.0", 9007199254740993)] {
            let reply = try await socketReply(
                #"{"version":2,"tool":"project_editor_state_read","arguments":{"project_handle":"\#(sequence)","offset":\#(offset)}}"#,
                directory: directory)
            XCTAssertEqual((reply["result"] as? [String: Any])?["offset"] as? Int, expected, offset)
        }
        session.isMulticam = true
        do {
            _ = try await bridge.perform(tool: "project_editor_state_read", arguments: ["project_handle": sequence])
            XCTFail("The former sequence handle should have expired")
        } catch let error as MCPFailure { XCTAssertEqual(error.code, "project_closed") }
        session.isMulticam = false
        XCTAssertNotEqual(session.mcpHandle, sequence)
        preferences.localMCPEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/control.sock"))
        do {
            _ = try await bridge.perform(tool: "project_windows_list", arguments: [:])
            XCTFail("The listener was disabled")
        } catch let error as MCPFailure { XCTAssertEqual(error.code, "control_disabled") }
    }

    @MainActor
    func testClosedProjectReplaysOnlyItsExactSuccessfulClose() async throws {
        _ = NSApplication.shared
        let directory = "/tmp/mpcut-test-" + UUID().uuidString
        let suite = "mpcut-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = EditorPreferences(defaults: defaults)
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        let bridge = MCPLocalControl(sessions: sessions, socket: MCPSocket(directory: directory))
        preferences.localMCPEnabled = true
        bridge.observeSetting()
        defer {
            bridge.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let creation = ["operation_id": UUID().uuidString]
        let created = try await bridge.perform(tool: "project_create", arguments: creation)
        let project = try XCTUnwrap(created["project_handle"] as? String)
        let session = try XCTUnwrap(sessions.sessions.values.first { $0.mcpHandle == project })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { if sessions.sessions[session.id] != nil { sessions.windowClosed(session); window.close() } }

        let revision = session.mcpRevision
        let args: [String: Any] = ["project_handle": project, "expected_revision": revision,
                                   "operation_id": UUID().uuidString, "changes": "discard"]
        let noClose = args.merging(["changes": "cancel", "operation_id": UUID().uuidString]) { _, new in new }
        _ = try await bridge.perform(tool: "project_close", arguments: noClose)
        let closed = try await bridge.perform(tool: "project_close", arguments: args)
        XCTAssertNil(sessions.sessions[session.id])
        XCTAssertEqual(closed["project_handle"] as? String, project)
        XCTAssertEqual(closed["revision"] as? Int, revision)
        let replay = try await bridge.perform(tool: "project_close", arguments: args)
        XCTAssertEqual(replay["closed"] as? Bool, true)
        XCTAssertEqual(replay["project_handle"] as? String, project)
        XCTAssertEqual(replay["revision"] as? Int, revision)

        let changed = args.merging(["expected_revision": revision + 1]) { _, new in new }
        for (tool, arguments) in [("project_create", creation), ("project_close", noClose), ("project_close", changed)] {
            do {
                _ = try await bridge.perform(tool: tool, arguments: arguments)
                XCTFail("Only the successful close receipt remains accessible after the document closes")
            } catch let error as MCPFailure { XCTAssertEqual(error.code, "project_closed") }
        }
    }

    func testSecondListenerCannotStealEndpoint() throws {
        let directory = "/tmp/mpcut-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = MCPSocket(directory: directory), second = MCPSocket(directory: directory)
        try first.start { _ in Data() }
        defer { second.stop(); first.stop() }
        XCTAssertThrowsError(try second.start { _ in Data() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/control.sock"))
        first.stop()
        XCTAssertNoThrow(try second.start { _ in Data() })
    }

    @MainActor
    func testSocketOwnerReleaseCancelsHandlingBeforeNativeWorkFinishes() async throws {
        let directory = "/tmp/mpcut-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var socket: MCPSocket? = MCPSocket(directory: directory)
        let started = expectation(description: "Socket delivered a request")
        let cancelled = expectation(description: "Socket owner cancelled the request")
        var nativeWork: CheckedContinuation<Void, Never>?
        try socket?.start { _ in
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    nativeWork = $0
                    started.fulfill()
                }
            } onCancel: { cancelled.fulfill() }
            return Data()
        }
        defer { nativeWork?.resume() }

        let fd = try connectSocket(directory: directory)
        defer { Darwin.close(fd) }
        send("{}", to: fd)
        await fulfillment(of: [started], timeout: 2)
        socket = nil
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/control.sock"))
    }

    private func connectSocket(directory: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: (directory + "/control.sock").utf8CString.map { UInt8(bitPattern: $0) })
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private func send(_ text: String, to fd: Int32) {
        let request = Data((text + "\n").utf8)
        let sent = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        XCTAssertEqual(sent, request.count)
    }

    private func socketReply(_ text: String, directory: String) async throws -> [String: Any] {
        let fd = try connectSocket(directory: directory)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        send(text, to: fd)
        let data = try await Task.detached {
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        }.value
        XCTAssertEqual(data.last, 10)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
