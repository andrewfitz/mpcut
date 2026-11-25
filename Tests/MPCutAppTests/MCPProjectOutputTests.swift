import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class MCPProjectOutputTests: XCTestCase {
    func testFileOutputSettingsBuildTheSavedProjectCLIInvocation() throws {
        var fields: [String: Any] = [
            "operation_id": UUID().uuidString, "project_path": "/tmp/editor.cut", "out_project": "/tmp/alternate.cut",
            "width": 1080, "frame_rate": "30000/1001", "audio_mode": "iso", "audio_ids": ["--feed 1"]
        ]
        let request = try MCPFileRequest(tool: "project_file_output_set", fields: fields)
        XCTAssertEqual(request.arguments, ["project", "output", "set", "--json", "/tmp/editor.cut",
                                           "--out-project", "/tmp/alternate.cut", "--width", "1080",
                                           "--frame-rate", "30000/1001", "--audio-mode", "iso", "--audio-id=--feed 1"])
        fields["in_place"] = true
        XCTAssertThrowsError(try MCPFileRequest(tool: "project_file_output_set", fields: fields))
        fields["out_project"] = nil
        fields["audio_mode"] = nil
        XCTAssertThrowsError(try MCPFileRequest(tool: "project_file_output_set", fields: fields))
    }

    func testLiveOutputEditRequiresRevisionAndOperationID() throws {
        let schema = try MCPSchemas.loaded.get()
        var arguments: [String: Any] = ["project_handle": "editor", "width": 720, "operation_id": "output-change"]
        XCTAssertThrowsError(try schema.validate(tool: "project_editor_output_set", arguments: arguments))
        arguments["expected_revision"] = 1
        XCTAssertNoThrow(try schema.validate(tool: "project_editor_output_set", arguments: arguments))
        arguments["operation_id"] = nil
        XCTAssertThrowsError(try schema.validate(tool: "project_editor_output_set", arguments: arguments))
    }

    @MainActor
    func testLiveOutputEditAdvancesRevisionAndCanBeUndone() async throws {
        let suite = "mpcut-output-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        session.editor.importFiles([fixture])
        let deadline = ContinuousClock.now + .seconds(15)
        while session.editor.isBusy {
            guard .now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { sessions.windowClosed(session); window.close() }
        let directory = "/tmp/mpcut-output-" + UUID().uuidString
        let bridge = MCPLocalControl(sessions: sessions, socket: MCPSocket(directory: directory))
        preferences.localMCPEnabled = true
        bridge.observeSetting()
        defer { bridge.stop(); try? FileManager.default.removeItem(atPath: directory) }

        let target: [String: Any] = ["project_handle": session.mcpHandle]
        let read = try await bridge.perform(tool: "project_editor_output_read", arguments: target)
        let revision = try XCTUnwrap(read["revision"] as? Int)
        let initialOutput = try XCTUnwrap(read["output"] as? [String: Any])
        XCTAssertEqual(initialOutput["has_stored_canvas"] as? Bool, false)
        let initial = session.outputSettingsProject
        let cursor = session.editor.historyCursor
        var request = target
        request["operation_id"] = "set-output"
        request["expected_revision"] = revision
        request["width"] = 1080
        request["frame_rate"] = "25"
        request["audio_mode"] = "silence"
        let result = try await bridge.perform(tool: "project_editor_output_set", arguments: request)
        XCTAssertEqual(result["changed"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(result["revision"] as? Int), revision)
        XCTAssertEqual(session.outputSettingsProject.projectOutputSettings.canvas.width, 1080)
        XCTAssertEqual(session.outputSettingsProject.projectOutputSettings.audio.mode, .silence)
        XCTAssertEqual(session.editor.historyCursor, cursor + 1)

        let replay = try await bridge.perform(tool: "project_editor_output_set", arguments: request)
        XCTAssertEqual(replay["revision"] as? Int, result["revision"] as? Int)
        request["operation_id"] = "set-output-stale"
        do {
            _ = try await bridge.perform(tool: "project_editor_output_set", arguments: request)
            XCTFail("A fresh operation must reject a stale revision.")
        } catch let error as MCPFailure {
            XCTAssertEqual(error.code, "stale_revision")
        }
        XCTAssertEqual(session.editor.historyCursor, cursor + 1)
        session.editor.undo()
        XCTAssertEqual(session.outputSettingsProject, initial)
    }

}
