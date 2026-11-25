import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class MCPEditorControlsTests: XCTestCase {
    @MainActor
    func testFirstGapAndWorkspaceControls() async throws {
        _ = NSApplication.shared
        let preferences = EditorPreferences()
        let sessions = ProjectSessions(preferences: preferences)
        let session = sessions.session(for: UUID())
        let other = sessions.session(for: UUID())
        defer { session.end(); other.end() }

        func call(_ tool: String, _ fields: [String: Any]) async throws -> [String: Any] {
            try await sessions.handleMCPCommand(tool: tool, arguments: fields, session: session, checkAccess: {})
        }
        XCTAssertTrue(session.mcpCanStartStillTimeline)
        let fields: [String: Any] = ["space": "sequence", "at": "0", "duration": "1", "background": "#FF0000"]
        do {
            _ = try await call("timeline_gap_insert", fields)
            XCTFail("The first gap requires an initial format")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_arguments")
        }
        XCTAssertTrue(session.editor.isEmpty)
        let initial = fields.merging(["initial_format": ["width": 64, "height": 36, "cadence": "1001/30000",
                                                         "codec": "h264", "container": "mp4"],
                                      "duration": "1001/1000"]) { _, new in new }
        let gap = try await call("timeline_gap_insert", initial)
        XCTAssertEqual(gap["changed"] as? Bool, true)
        XCTAssertEqual(session.editor.stillProject.stillFormat?.cadence.description, "1001/30000")
        XCTAssertEqual(session.editor.stillProject.stillInserts.first?.framing.background, "#FF0000")
        XCTAssertFalse(session.mcpCanStartStillTimeline)

        let revision = session.mcpRevision
        let history = session.editor.historyActions
        _ = try await call("workspace_layout_set", ["action": "set_monitor_picture", "picture": "source"])
        _ = try await call("workspace_layout_set", ["action": "set_cut_sections", "visible": false])
        _ = try await call("workspace_layout_set", ["action": "set_transcript_follow_playback", "enabled": false])
        let layout = try await call("workspace_layout_read", [:])
        XCTAssertEqual(layout["monitor_picture"] as? String, "source")
        XCTAssertEqual(layout["cut_sections_visible"] as? Bool, false)
        XCTAssertEqual(layout["transcript_follow_playback"] as? Bool, false)
        XCTAssertFalse(other.presentation.participantMonitorSource)
        XCTAssertFalse(other.presentation.cutSectionsHidden)
        XCTAssertTrue(other.presentation.transcriptReader.followsPlayback)
        XCTAssertEqual(session.mcpRevision, revision)
        XCTAssertEqual(session.editor.historyActions, history)
    }

    @MainActor
    func testHistoryCloseAllowsImmediateSave() async throws {
        _ = NSApplication.shared
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let session = sessions.session(for: UUID())
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 280),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.orderFront(nil)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        defer {
            if window.attachedSheet === sheet { window.endSheet(sheet) }
            sessions.windowClosed(session)
            window.close()
            try? FileManager.default.removeItem(at: destination)
        }

        func call(_ tool: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
            try await sessions.handleMCPCommand(tool: tool, arguments: fields, session: session, checkAccess: {})
        }
        _ = try await call("timeline_gap_insert", ["space": "sequence", "at": "0", "duration": "1",
                                                   "initial_format": ["width": 64, "height": 36, "cadence": "1/30",
                                                                      "codec": "h264", "container": "mp4"]])
        let opened = try await call("history_panel_show")
        XCTAssertEqual(opened["history_visible"] as? Bool, true)
        window.beginSheet(sheet, completionHandler: nil)
        XCTAssertTrue(window.attachedSheet === sheet)
        // The real SwiftUI binding detaches its native sheet on a later run-loop pass.
        let detach = Task {
            while session.isHistoryPresented { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(100))
            window.endSheet(sheet)
        }
        defer { detach.cancel() }
        let closed = try await call("history_panel_close")
        XCTAssertEqual(closed["history_visible"] as? Bool, false)
        XCTAssertNil(window.attachedSheet)
        try await detach.value
        _ = try await call("history_panel_close")
        _ = try await call("project_save", ["project_path": destination.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testRecentPathsShareTheMenuStoreAndClearIt() async throws {
        let preferenceDomain = "MPCut-recent-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferenceDomain))
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let preferences = EditorPreferences(defaults: defaults)
        let sessions = ProjectSessions(preferences: preferences)
        let first = URL(fileURLWithPath: "/tmp/older.cut")
        let second = URL(fileURLWithPath: "/tmp/newer.mov")
        preferences.recentFiles.record([first])
        preferences.recentFiles.record([second])
        let listed = try await sessions.handleMCPCommand(tool: "recent_files_list", arguments: [:],
                                                        session: nil, checkAccess: {})
        XCTAssertEqual(listed["paths"] as? [String], [second.path, first.path])
        let cleared = try await sessions.handleMCPCommand(tool: "recent_files_clear", arguments: [:],
                                                         session: nil, checkAccess: {})
        XCTAssertEqual(cleared["paths"] as? [String], [])
        XCTAssertTrue(preferences.recentFiles.urls.isEmpty)
        XCTAssertTrue(RecentFiles(defaults: defaults).urls.isEmpty)
    }

    @MainActor
    func testSuggestedCameraUsesTheReaderPreference() async throws {
        _ = NSApplication.shared
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = sessions.session(for: UUID())
        session.isMulticam = true
        defer { session.end() }
        let recording = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                        subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(recording)
        session.multicam.confirmSetup(drafts: [.init(source: .init(id: "wide", file: recording.path), media: media)],
                                      opening: "wide", audio: .none)
        let document = TranscriptDocument(clock: .presentation, speakers: [.init(id: "host", name: "Host")])
        let attachment = TranscriptAttachment(id: ProjectIdentifier.make(), asset: try TranscriptStore.put(document), bindings: [])
        try session.multicam.setTranscriptState(.init(attachments: [attachment]))
        defer { TranscriptSuggestedCameras.set(nil, attachment: attachment.id, speaker: "host", in: preferences) }
        let revision = session.mcpRevision

        func set(_ angle: Any, speaker: String = "host") async throws -> [String: [String: String]] {
            let result = try await sessions.handleMCPCommand(
                tool: "workspace_layout_set",
                arguments: ["action": "set_transcript_suggested_camera",
                            "attachment": attachment.id, "speaker": speaker, "camera": angle],
                session: session, checkAccess: {}
            )
            return try XCTUnwrap(result["transcript_suggested_cameras"] as? [String: [String: String]])
        }
        do {
            _ = try await set("wide", speaker: "missing")
            XCTFail("Accepted an unknown transcript speaker")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_arguments")
        }
        let remembered = try await set("wide")
        XCTAssertEqual(remembered[attachment.id]?["host"], "wide")
        let cleared = try await set(NSNull())
        XCTAssertNil(cleared[attachment.id])
        XCTAssertEqual(session.mcpRevision, revision)
    }

    func testEditorControlsSchemas() throws {
        let schemas = try MCPSchemas.loaded.get()
        let project = ["project_handle": "window"]
        XCTAssertNoThrow(try schemas.validate(tool: "history_panel_close", arguments: project))
        XCTAssertNoThrow(try schemas.validate(tool: "recent_files_list", arguments: [:]))
        XCTAssertNoThrow(try schemas.validate(tool: "recent_files_clear", arguments: [:]))
        let format: [String: Any] = ["width": 64, "height": 36, "cadence": "1/30", "codec": "h264", "container": "mp4"]
        var insert: [String: Any] = ["project_handle": "window", "expected_revision": 0, "operation_id": "first-gap",
                                     "space": "sequence", "at": "0", "duration": "1", "initial_format": format]
        XCTAssertNoThrow(try schemas.validate(tool: "timeline_gap_insert", arguments: insert))
        insert["initial_format"] = format.merging(["width": true]) { _, new in new }
        XCTAssertThrowsError(try schemas.validate(tool: "timeline_gap_insert", arguments: insert))
        let suggested: [String: Any] = ["project_handle": "window", "action": "set_transcript_suggested_camera",
                                         "attachment": "dialogue", "speaker": "speaker", "camera": NSNull()]
        XCTAssertNoThrow(try schemas.validate(tool: "workspace_layout_set", arguments: suggested))
        var wrongCamera = suggested
        wrongCamera["camera"] = false
        XCTAssertThrowsError(try schemas.validate(tool: "workspace_layout_set", arguments: wrongCamera))
        var missingCamera = suggested
        missingCamera["camera"] = nil
        XCTAssertThrowsError(try schemas.validate(tool: "workspace_layout_set", arguments: missingCamera))
    }
}
