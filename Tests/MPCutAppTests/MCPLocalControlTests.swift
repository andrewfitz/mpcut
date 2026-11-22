import AppKit
import Darwin
import XCTest
@testable import MPCutApp

final class MCPLocalControlTests: XCTestCase {
    func testRejectsMalformedSchemaArgumentsAtAppBoundary() throws {
        let schemas = try MCPSchemas.loaded.get()
        XCTAssertThrowsError(try schemas.validate(tool: "get_editor_state", arguments: ["project": "a", "limit": true]))
        XCTAssertThrowsError(try schemas.validate(tool: "get_editor_state", arguments: ["project": "a", "offset": -1]))
        XCTAssertThrowsError(try schemas.validate(tool: "seek", arguments: ["project": "a", "space": "group", "time": "1", "occurrence": true]))
        XCTAssertThrowsError(try schemas.validate(tool: "split_at", arguments: ["project": "a", "space": "group", "time": "1"]))
        XCTAssertThrowsError(try schemas.validate(tool: "list_projects", arguments: ["surprise": true]))
        XCTAssertNoThrow(try schemas.validate(tool: "get_editor_state", arguments: ["project": "a", "limit": 1]))
        XCTAssertNoThrow(try schemas.validate(tool: "get_editor_state", arguments: ["project": "a", "offset": Int.max]))
        XCTAssertThrowsError(try schemas.validate(tool: "get_editor_state", arguments: ["project": "a", "offset": UInt64.max]))
        let playback: [String: Any] = ["project": "a", "expectedRevision": 0, "operationID": "playback-rate", "action": "speed"]
        let rate: (Any) -> [String: Any] = { playback.merging(["rate": $0]) { _, new in new } }
        XCTAssertThrowsError(try schemas.validate(tool: "sequence_control", arguments: rate(true)))
        XCTAssertThrowsError(try schemas.validate(tool: "sequence_control", arguments: rate(3.0)))
        XCTAssertNoThrow(try schemas.validate(tool: "sequence_control", arguments: rate(1.25)))
        let inlineArguments: [String: Any] = [
            "operationID": "42970FFD-0FF6-42C1-BF05-0ECFAD579C1E",
            "project_data": ["history": [9_007_199_254_740_992]]
        ]
        let inlinePath = MCPSchemas.projectDataPath + [.key("history"), .index(0)]
        let inline = try schemas.validate(tool: "file_inspect", arguments: inlineArguments,
                                          wireIntegers: [inlinePath: .init(exact: 9_007_199_254_740_993)])
        XCTAssertEqual((inline["project_data"] as? [String: Any])?["history"] as? [Int], [9_007_199_254_740_993])
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
        let listed = try await socketReply(#"{"version":1,"tool":"list_projects","arguments":{}}"#, directory: directory)
        XCTAssertEqual((listed["result"] as? [String: Any])?["projects"] as? [[String: String]], [])
        let duplicate = try await socketReply(#"{"version":1,"tool":"list_projects","arguments":{},"arguments":{}}"#, directory: directory)
        XCTAssertEqual((duplicate["error"] as? [String: String])?["code"], "invalid_arguments")
        for invalidVersion in ["true", "1.0000000000000001"] {
            let wrongVersion = try await socketReply(#"{"version":\#(invalidVersion),"tool":"list_projects","arguments":{}}"#, directory: directory)
            XCTAssertEqual((wrongVersion["error"] as? [String: String])?["code"], "bridge_version")
        }
        let fractionalPreference = try await socketReply(
            #"{"version":1.0,"tool":"set_preference","arguments":{"operationID":"fractional-volume","key":"volume","value":0.375}}"#,
            directory: directory)
        XCTAssertEqual((fractionalPreference["result"] as? [String: Any])?["volume"] as? Double, 0.375)
        let fractionalHistoryLimit = try await socketReply(
            #"{"version":1,"tool":"set_preference","arguments":{"operationID":"fractional-history","key":"historyLimit","value":1.0000000000000001}}"#,
            directory: directory)
        XCTAssertEqual((fractionalHistoryLimit["error"] as? [String: String])?["code"], "invalid_arguments")
        let fractionalOrder = try await socketReply(
            #"{"version":1,"tool":"file_export","arguments":{"operationID":"42970FFD-0FF6-42C1-BF05-0ECFAD579C1E","edit":{"clips":[{"file":"/tmp/example.mov"}],"order":[1,1.0000000000000001],"output":"/tmp/example-out.mov"}}}"#,
            directory: directory)
        let orderError = try XCTUnwrap(fractionalOrder["error"] as? [String: String])
        XCTAssertEqual(orderError["code"], "invalid_arguments")
        XCTAssertTrue(orderError["message"]?.contains("edit.order[1]") == true)
        let fractionalProject = try await socketReply(
            #"{"version":1,"tool":"file_inspect","arguments":{"operationID":"42970FFD-0FF6-42C1-BF05-0ECFAD579C1E","project_data":{"format":"mpcut","schemaVersion":1.0000000000000001,"kind":"sequence","clips":[]}}}"#,
            directory: directory)
        let projectError = try XCTUnwrap(fractionalProject["error"] as? [String: String])
        XCTAssertEqual(projectError["code"], "invalid_arguments")
        XCTAssertTrue(projectError["message"]?.contains("project_data") == true)
        let setVolume: [String: Any] = ["key": "volume", "value": 0.5, "operationID": UUID().uuidString]
        _ = try await bridge.perform(tool: "set_preference", arguments: setVolume)
        preferences.volume = 0.75
        _ = try await bridge.perform(tool: "set_preference", arguments: setVolume)
        XCTAssertEqual(preferences.volume, 0.75, "Replaying a completed call must preserve subsequent GUI settings.")
        var conflict = setVolume
        conflict["value"] = 0.2
        do {
            _ = try await bridge.perform(tool: "set_preference", arguments: conflict)
            XCTFail("Operation ID reuse with different arguments should fail")
        } catch let error as MCPFailure { XCTAssertEqual(error.code, "operation_conflict") }
        let session = sessions.session(for: nil)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { sessions.windowClosed(session); window.close() }
        let sequence = session.mcpHandle
        let result = try await bridge.perform(tool: "get_editor_state", arguments: ["project": sequence])
        XCTAssertEqual(result["total"] as? Int, 0)
        for offset in ["1.0000000000000001", "10000000000000001e-16", "9223372036854775808.0"] {
            let reply = try await socketReply(
                #"{"version":1e0,"tool":"get_editor_state","arguments":{"project":"\#(sequence)","offset":\#(offset)}}"#,
                directory: directory)
            XCTAssertEqual((reply["error"] as? [String: String])?["code"], "invalid_arguments", offset)
        }
        for (offset, expected) in [("1.0", 1), ("1e0", 1), ("10e-1", 1), ("9007199254740993.0", 9007199254740993)] {
            let reply = try await socketReply(
                #"{"version":1,"tool":"get_editor_state","arguments":{"project":"\#(sequence)","offset":\#(offset)}}"#,
                directory: directory)
            XCTAssertEqual((reply["result"] as? [String: Any])?["offset"] as? Int, expected, offset)
        }
        session.isMulticam = true
        do {
            _ = try await bridge.perform(tool: "get_editor_state", arguments: ["project": sequence])
            XCTFail("The former sequence handle should have expired")
        } catch let error as MCPFailure { XCTAssertEqual(error.code, "project_closed") }
        session.isMulticam = false
        XCTAssertNotEqual(session.mcpHandle, sequence)
        preferences.localMCPEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/control.sock"))
        do {
            _ = try await bridge.perform(tool: "list_projects", arguments: [:])
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
        let creation = ["operationID": UUID().uuidString]
        let created = try await bridge.perform(tool: "new_project", arguments: creation)
        let project = try XCTUnwrap(created["project"] as? String)
        let session = try XCTUnwrap(sessions.sessions.values.first { $0.mcpHandle == project })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { if sessions.sessions[session.id] != nil { sessions.windowClosed(session); window.close() } }

        let revision = session.mcpRevision
        let args: [String: Any] = ["project": project, "expectedRevision": revision,
                                   "operationID": UUID().uuidString, "changes": "discard"]
        let noClose = args.merging(["changes": "cancel", "operationID": UUID().uuidString]) { _, new in new }
        _ = try await bridge.perform(tool: "close_project", arguments: noClose)
        let closed = try await bridge.perform(tool: "close_project", arguments: args)
        XCTAssertNil(sessions.sessions[session.id])
        XCTAssertEqual(closed["project"] as? String, project)
        XCTAssertEqual(closed["revision"] as? Int, revision)
        let replay = try await bridge.perform(tool: "close_project", arguments: args)
        XCTAssertEqual(replay["closed"] as? Bool, true)
        XCTAssertEqual(replay["project"] as? String, project)
        XCTAssertEqual(replay["revision"] as? Int, revision)

        let changed = args.merging(["expectedRevision": revision + 1]) { _, new in new }
        for (tool, arguments) in [("new_project", creation), ("close_project", noClose), ("close_project", changed)] {
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
