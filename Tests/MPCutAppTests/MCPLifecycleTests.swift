import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPLifecycleTests: XCTestCase {
    func testLifecycleOpensOnceAndSaveAsPreservesLiveHandle() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Empty.cut"), destination = folder.appendingPathComponent("Copy.cut")
        try CutProject.sequence([]).save(to: source)
        let prefs = EditorPreferences()
        let sessions = ProjectSessions(preferences: prefs, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }

        func call(_ name: String, _ arguments: [String: Any], _ session: ProjectSession? = nil) async throws -> [String: Any] {
            let result = try await sessions.mcpLifecycle(tool: name, arguments: arguments, session: session, checkAccess: {})
            return try XCTUnwrap(result)
        }

        let first = try await call("project_open", ["project_path": source.path])
        let second = try await call("project_open", ["project_path": source.path])
        XCTAssertEqual(first["project_handle"] as? String, second["project_handle"] as? String)
        let live = try XCTUnwrap(sessions.project(at: source))
        let saved = try await call("project_save", ["project_path": destination.path], live)
        XCTAssertEqual(saved["project_handle"] as? String, first["project_handle"] as? String)
        XCTAssertEqual(live.editor.projectURL?.path, destination.path)
        XCTAssertEqual(sessions.sessions.count, 1)

        do {
            _ = try await call("project_save", ["project_path": source.path], live)
            XCTFail("Save As must require explicit replacement")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "destination_exists") }
        let hardLink = folder.appendingPathComponent("Linked.cut")
        try manager.linkItem(at: destination, to: hardLink)
        do {
            _ = try await call("project_save", ["project_path": hardLink.path], live)
            XCTFail("A second directory entry still requires explicit replacement")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "destination_exists") }
        XCTAssertEqual(live.editor.projectURL, destination)
        _ = try await call("preferences_set", ["key": "history_max_steps", "value": 9])
        XCTAssertEqual(prefs.historyLimit, 9)
        let discovery = try MCPSchemas.loaded.get()
        let properties = try XCTUnwrap(discovery.inputs["preferences_set"]?["properties"] as? [String: [String: Any]])
        let editable = try XCTUnwrap(properties["key"]?["enum"] as? [String])
        let current = try await call("preferences_read", [:])
        XCTAssertEqual(Set(current.keys), Set(EditorPreferences.Key.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(current.keys), Set(editable + EditorPreferences.Key.agentReadOnly.map(\.rawValue)))
        XCTAssertTrue(Set(editable).isDisjoint(with: EditorPreferences.Key.agentReadOnly.map(\.rawValue)))
        for key in editable {
            let value = try XCTUnwrap(current[key], key)
            let arguments: [String: Any] = ["key": key, "value": value, "operation_id": UUID().uuidString]
            let validated = try discovery.validate(tool: "preferences_set", arguments: arguments)
            _ = try await call("preferences_set", validated)
        }
        for value in [0.0, 0.30, 1.0] {
            _ = try await call("preferences_set", ["key": "silence_max_blip_seconds", "value": value])
            let values = try await call("preferences_read", [:])
            XCTAssertEqual(values["silence_max_blip_seconds"] as? Double, value)
        }
        do {
            _ = try await call("preferences_set", ["key": "automation_local_mcp_enabled", "value": true])
            XCTFail("The client cannot grant itself access")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "invalid_arguments") }
    }

    func testPublicPreferenceSchemaRejectsInvalidValues() throws {
        let schemas = try MCPSchemas.loaded.get()
        let invalid: [(String, Any)] = [("historyLimit", 9), ("history_max_steps", 1.5), ("history_max_steps", 501), ("playback_preview_volume_fraction", true),
            ("playback_preview_volume_fraction", -0.1), ("silence_max_blip_seconds", -0.01), ("silence_max_blip_seconds", 1.01), ("silence_max_blip_seconds", true), ("silence_min_pause_seconds", 0), ("silence_padding_per_side_seconds", -1), ("timeline_snap_target", "frames"),
            ("export_movie_default_mode", "movie"), ("export_jpeg_default_preset", "jpg"), ("playback_preview_muted", 1), ("automation_local_mcp_enabled", true)]
        for (key, value) in invalid {
            XCTAssertThrowsError(try schemas.validate(tool: "preferences_set", arguments: [
                "operation_id": UUID().uuidString, "key": key, "value": value
            ])) { error in XCTAssertEqual((error as? MCPFailure)?.code, "invalid_arguments") }
        }
        XCTAssertNoThrow(try schemas.validate(tool: "preferences_set", arguments: [
            "operation_id": UUID().uuidString, "key": "silence_min_pause_seconds", "value": 1.0 / Double(AudioWaveform.rate)
        ]))
    }

    func testCloseRequiresDirtyDecisionAndUsesNativeDelegate() async throws {
        _ = NSApplication.shared
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs)
        let session = sessions.session(for: UUID())
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { if sessions.sessions[session.id] != nil { sessions.windowClosed(session); window.close() } }
        let path = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures")).path
        _ = try await sessions.mcpLifecycle(tool: "project_media_add", arguments: ["paths": [path]], session: session, checkAccess: {})
        XCTAssertTrue(session.hasUnsavedDocument)
        do {
            _ = try await sessions.mcpLifecycle(tool: "project_close", arguments: [:], session: session, checkAccess: {})
            XCTFail("An unsaved edit needs a close decision")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "unsaved_changes") }
        let cancelled = try await sessions.mcpLifecycle(tool: "project_close", arguments: ["changes": "cancel"],
                                                       session: session, checkAccess: {})
        XCTAssertEqual(cancelled?["closed"] as? Bool, false)
        let closed = try await sessions.mcpLifecycle(tool: "project_close", arguments: ["changes": "discard"],
                                                    session: session, checkAccess: {})
        XCTAssertEqual(closed?["closed"] as? Bool, true)
        XCTAssertNil(sessions.sessions[session.id])
    }

    func testNativeMulticamSetupKeepsSourceIDsAndChosenAudio() async throws {
        _ = NSApplication.shared
        let media = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        let created = try await sessions.mcpLifecycle(tool: "project_create",
            arguments: ["kind": "multicam", "paths": [media.path]], session: nil, checkAccess: {})
        let handle = try XCTUnwrap(created?["project_handle"] as? String)
        let session = try XCTUnwrap(sessions.sessions.values.first { $0.mcpHandle == handle })
        let setup = try await sessions.mcpLifecycle(tool: "multicam_setup_read", arguments: [:],
                                                   session: session, checkAccess: {})
        let rows = try XCTUnwrap(setup?["sources"] as? [[String: Any]])
        let angle = try XCTUnwrap(rows.first?["id"] as? String)
        XCTAssertEqual(rows.first?["name"] as? String, media.lastPathComponent)
        let confirmed = try await sessions.mcpLifecycle(tool: "multicam_setup_confirm",
            arguments: ["opening": angle, "audio": ["mode": "none"], "names": [angle: "Wide"]],
            session: session, checkAccess: {})
        XCTAssertEqual(confirmed?["previous_project_handle"] as? String, handle)
        XCTAssertEqual(confirmed?["new_project_handle"] as? String, confirmed?["project_handle"] as? String)
        XCTAssertEqual(confirmed?["handle_changed"] as? Bool, true)
        XCTAssertEqual(session.multicam.project?.angles.first?.name, "Wide")
        XCTAssertEqual(session.multicam.project?.audio, MulticamAudioPolicy.none)
        XCTAssertTrue(session.multicam.setup.isEmpty)
    }

    func testNativeConversionCancellationCannotReachAnotherWindowOrSuccessor() throws {
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let owner = sessions.session(for: UUID()), other = sessions.session(for: UUID())
        let first = EditCancellation()
        sessions.conversionOwner = owner.mcpHandle
        sessions.projectConversion = first
        let query = try sessions.mcpNativeOperations(tool: "project_operations_list", arguments: [:], session: owner)
        let row = try XCTUnwrap((query["operations"] as? [[String: Any]])?.first)
        let receipt = ["native_operation_id": try XCTUnwrap(row["native_operation_id"] as? String)]
        XCTAssertThrowsError(try sessions.mcpNativeOperations(tool: "project_operation_cancel", arguments: receipt, session: other))
        XCTAssertFalse(first.isCancelled)
        _ = try sessions.mcpNativeOperations(tool: "project_operation_cancel", arguments: receipt, session: owner)
        XCTAssertTrue(first.isCancelled)
        sessions.finishProjectConversion()
        let next = EditCancellation()
        sessions.conversionOwner = owner.mcpHandle
        sessions.projectConversion = next
        defer { sessions.finishProjectConversion() }
        XCTAssertThrowsError(try sessions.mcpNativeOperations(tool: "project_operation_cancel", arguments: receipt, session: owner))
        XCTAssertFalse(next.isCancelled)
    }

    func testRevokedOrdinaryImportLeavesNoPartialClipOrHistory() async throws {
        _ = NSApplication.shared
        let media = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let session = ProjectSession(id: UUID(), preferences: prefs)
        defer { session.end() }
        session.editor.importFiles([media, media], allowCommit: { false })
        let deadline = ContinuousClock.now + .seconds(20)
        while session.editor.isImporting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(session.editor.isImporting)
        XCTAssertTrue(session.editor.sequenceClips.isEmpty)
        XCTAssertTrue(session.editor.historyActions.isEmpty)
        XCTAssertEqual(session.editor.mcpRevision, 0)
    }

    func testPendingSheetPreventsAnImportCommit() async throws {
        let media = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs, openWindow: { _ in })
        let session = try sessions.createWindow()
        defer { sessions.windowClosed(session) }
        do {
            _ = try await sessions.mcpLifecycle(tool: "project_media_add", arguments: ["paths": [media.path]], session: session,
                checkAccess: { if !session.editor.isImporting { session.isHistoryPresented = true } })
            XCTFail("Media must not commit over a new modal presentation")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "busy") }
        XCTAssertTrue(session.editor.sequenceClips.isEmpty)
        XCTAssertTrue(session.editor.historyActions.isEmpty)
        XCTAssertEqual(session.editor.mcpRevision, 0)
    }

    // MARK: Preference contract

    private func preferenceCall(_ sessions: ProjectSessions, _ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await sessions.mcpLifecycle(tool: name, arguments: arguments, session: nil, checkAccess: {})
        return try XCTUnwrap(result)
    }

    func testPreferencesReadListsTheWholeScheduleWithItsFactoryValues() async throws {
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let values = try await preferenceCall(sessions, "preferences_read")
        let schedule: [String: Any] = [
            "automation_local_mcp_enabled": false, "media_auto_refresh_enabled": false, "analysis_sidecar_reuse_enabled": true,
            "history_max_steps": 50, "timeline_source_time_ticks_enabled": false, "timeline_snap_target": "off",
            "timeline_large_previews_enabled": false, "playback_preview_volume_fraction": 1, "playback_preview_muted": false,
            "playback_scrub_audio_enabled": true, "export_movie_default_mode": "smart", "export_jpeg_default_preset": "review",
            "export_tier_downgrade_warning_enabled": true, "silence_min_pause_seconds": 1.5,
            "silence_max_blip_seconds": AudioWaveform.defaultMaxBlip, "silence_padding_per_side_seconds": 0.2,
            "open_multiple_recordings_default_action": "ask", "recent_files_max_count": 10, "draft_recovery_prompt_enabled": false,
            "scene_rescan_confirmation_enabled": true, "project_export_completion_message_enabled": true,
            "timeline_cut_sections_default_enabled": true, "workspace_full_height_sidebar_enabled": false,
            "multicam_track_label_width_points": 172, "still_placement_default_duration_seconds": 2, "gap_default_duration_seconds": 2,
            "gap_default_color": "#000000", "still_timeline_default_width_pixels": 1920, "still_timeline_default_height_pixels": 1080,
            "still_timeline_default_frame_rate": 30, "still_timeline_default_codec": "h264", "timeline_time_display": "milliseconds",
            "playback_default_speed": 1, "playback_cut_preview_preroll_seconds": 1, "playback_cut_preview_postroll_seconds": 1,
            "playback_viewer_force_sdr_enabled": false, "playback_monitor_force_sdr_enabled": false,
            "playback_monitor_clean_feed_enabled": false, "playback_monitor_placement": "other_display",
            "analysis_scene_auto_scan_enabled": false, "analysis_silence_auto_scan_enabled": false,
            "tiles_scan_default_layout": "video_call", "tiles_scan_default_grid_columns": 2, "tiles_scan_default_grid_rows": 2,
            "tiles_scan_default_detail": "adaptive", "tiles_dialogue_default_min_hold_seconds": 1,
            "tiles_dialogue_default_overlap_policy": "hold", "tiles_dialogue_default_offscreen_policy": "hold",
            "transcript_default_engine": "", "transcript_default_speaker_identification_enabled": false,
            "transcript_default_model_download_enabled": false, "transcript_follow_playback_default_enabled": true,
            "transcript_reader_text_size_points": 14, "transcript_edit_default_boundary_policy": "nearest_frame",
            "transcript_tighten_default_retained_pause_seconds": 0.2, "transcript_default_filler_terms": "",
            "transcript_export_default_format": "json", "transcript_caption_max_line_characters": 42, "transcript_caption_max_lines": 2,
            "transcript_caption_max_cue_seconds": 6, "transcript_caption_speaker_labels_enabled": true,
            "export_reencode_default_codec": "h264", "export_reencode_default_quality": "balanced", "export_prores_default_quality": "422",
            "export_reencode_default_container": "automatic", "export_multicam_default_audio_layout": "separate_tracks",
            "export_result_json_default_enabled": false, "resolve_send_open_timeline_default_enabled": true,
            "export_start_folder_mode": "automatic", "export_finished_reveal_enabled": false,
            "export_finished_notification_enabled": false, "export_finished_sound_enabled": false,
            "analysis_shared_cache_max_bytes": 0, "draft_retention_days": 0, "automation_preferences_write_enabled": true,
            "automation_file_replace_enabled": true
        ]
        XCTAssertEqual(Set(values.keys), Set(schedule.keys))
        XCTAssertEqual(values.count, 76)
        for (key, expected) in schedule {
            let actual = try XCTUnwrap(values[key], key)
            switch expected {
            case let text as String: XCTAssertEqual(actual as? String, text, key)
            case let flag as Bool:
                XCTAssertEqual((actual as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() }, true, key)
                XCTAssertEqual(actual as? Bool, flag, key)
            default:
                let number = try XCTUnwrap(actual as? NSNumber, key)
                XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID(), key)
                XCTAssertEqual(number.doubleValue, (expected as? NSNumber)?.doubleValue ?? .nan, accuracy: 1e-9, key)
            }
        }
    }

    func testPreferencesSetValidatesTypesAndRangesAndRefusesReadOnlyKeys() async throws {
        let prefs = EditorPreferences()
        let sessions = ProjectSessions(preferences: prefs)
        let schemas = try MCPSchemas.loaded.get()
        let accepted: [(String, Any)] = [
            ("recent_files_max_count", 30), ("gap_default_color", "#a0b1c2"), ("still_timeline_default_width_pixels", 3840),
            ("playback_default_speed", 0.125), ("export_reencode_default_codec", "prores"), ("export_prores_default_quality", "422-hq"),
            ("export_reencode_default_quality", "smaller"), ("tiles_dialogue_default_overlap_policy", "visible_speaker"),
            ("transcript_default_filler_terms", "um, uh"), ("transcript_default_engine", ""),
            ("multicam_track_label_width_points", 106), ("workspace_full_height_sidebar_enabled", true),
            ("transcript_edit_default_boundary_policy", "copy_safe"), ("tiles_scan_default_detail", "every_frame")
        ]
        for (key, value) in accepted {
            let arguments: [String: Any] = ["operation_id": UUID().uuidString, "key": key, "value": value]
            _ = try await preferenceCall(sessions, "preferences_set", try schemas.validate(tool: "preferences_set", arguments: arguments))
        }
        XCTAssertEqual(prefs.recentFilesLimit, 30)
        XCTAssertEqual(prefs.gapColor, "#A0B1C2")
        XCTAssertEqual(prefs.playbackSpeed, .eighth)
        XCTAssertEqual(prefs.proresQuality, .proresHQ)
        XCTAssertEqual(prefs.dialogueOverlap, .visibleSpeaker)
        XCTAssertTrue(prefs.fullHeightSidebar)

        let rejected: [(String, Any)] = [
            ("recent_files_max_count", 31), ("recent_files_max_count", 2.5), ("recent_files_max_count", true),
            ("still_timeline_default_height_pixels", 8194),
            ("still_timeline_default_codec", "jpeg"), ("export_reencode_default_codec", "jpeg"),
            ("export_reencode_default_quality", "422"), ("export_prores_default_quality", "balanced"),
            ("playback_default_speed", 3), ("playback_cut_preview_preroll_seconds", 0.2), ("gap_default_color", "black"),
            ("multicam_track_label_width_points", 400), ("tiles_scan_default_layout", "meeting"),
            ("tiles_dialogue_default_overlap_policy", "visibleSpeaker"), ("transcript_reader_text_size_points", "14"),
            ("transcript_caption_max_lines", 4), ("export_start_folder_mode", "desktop"), ("timeline_time_display", "timecode")
        ]
        for (key, value) in rejected {
            XCTAssertThrowsError(try schemas.validate(tool: "preferences_set", arguments: [
                "operation_id": UUID().uuidString, "key": key, "value": value
            ]), "\(key) \(value)") { XCTAssertEqual(($0 as? MCPFailure)?.code, "invalid_arguments") }
            do {
                _ = try await preferenceCall(sessions, "preferences_set", ["key": key, "value": value])
                XCTFail("\(key) accepted \(value)")
            } catch let failure as MCPFailure {
                XCTAssertEqual(failure.code, "invalid_arguments", key)
                XCTAssertFalse(failure.message.isEmpty)
            }
        }
        // The schema says multipleOf 2, which the app's own validator does not check, so the route refuses an odd count itself.
        do {
            _ = try await preferenceCall(sessions, "preferences_set", ["key": "still_timeline_default_width_pixels", "value": 1921])
            XCTFail("An odd width was accepted")
        } catch let failure as MCPFailure { XCTAssertTrue(failure.message.contains("even"), failure.message) }
        let valueSchemas = try preferenceValueSchemas(schemas)
        for key in ["still_timeline_default_width_pixels", "still_timeline_default_height_pixels"] {
            XCTAssertEqual(valueSchemas[key]?["multipleOf"] as? Int, 2, key)
        }
        XCTAssertEqual(prefs.recentFilesLimit, 30)
        XCTAssertEqual(prefs.stillTimelineWidth, 3840)

        for key in EditorPreferences.Key.agentReadOnly.map(\.rawValue) {
            let value: Any = key.hasPrefix("automation_") ? false as Any : 1 as Any
            XCTAssertThrowsError(try schemas.validate(tool: "preferences_set", arguments: [
                "operation_id": UUID().uuidString, "key": key, "value": value
            ]), key)
            do {
                _ = try await preferenceCall(sessions, "preferences_set", ["key": key, "value": value])
                XCTFail("Agents cannot set \(key)")
            } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "invalid_arguments", key) }
        }
        XCTAssertTrue(prefs.agentsChangeSettings)
        XCTAssertEqual(prefs.draftRetentionDays, 0)
        XCTAssertEqual(prefs.sharedCacheLimitBytes, 0)
    }

    /// Each settable key's value schema, from its conditional branch of `preferences_set`.
    private func preferenceValueSchemas(_ schemas: MCPSchemas) throws -> [String: [String: Any]] {
        let input = try XCTUnwrap(schemas.inputs["preferences_set"])
        var result: [String: [String: Any]] = [:]
        for branch in input["allOf"] as? [[String: Any]] ?? [] {
            guard let key = ((branch["if"] as? [String: Any])?["properties"] as? [String: Any])
                    .flatMap({ ($0["key"] as? [String: Any])?["const"] as? String }),
                  let value = ((branch["then"] as? [String: Any])?["properties"] as? [String: Any])?["value"] as? [String: Any]
            else { continue }
            result[key] = value
        }
        return result
    }

    private func same(_ a: Any, _ b: Any) -> Bool { (a as? NSObject)?.isEqual(b) ?? false }

    /// A valid value that differs from `current`, chosen from the key's schema.
    private func differentValue(from current: Any, schema: [String: Any]) -> Any? {
        if let choices = schema["enum"] as? [Any] { return choices.first { !same($0, current) } }
        switch schema["type"] as? String {
        case "boolean":
            return (current as? Bool).map { !$0 }
        case "integer":
            let minimum = schema["minimum"] as? Int ?? 0
            let maximum = schema["maximum"] as? Int ?? minimum + 2
            return same(minimum, current) ? maximum : minimum
        case "number":
            let minimum = schema["minimum"] as? Double ?? 0
            let maximum = schema["maximum"] as? Double ?? minimum + 1
            return same(minimum, current) ? maximum : minimum
        case "string":
            if schema["pattern"] != nil { return same("#FFFFFF", current) ? "#000000" : "#FFFFFF" }
            return same("", current) ? "um, uh" : ""
        default:
            return nil
        }
    }

    func testTurningOffAgentSettingsRefusesEveryWriteAndKeepsReads() async throws {
        let prefs = EditorPreferences()
        let sessions = ProjectSessions(preferences: prefs)
        let schemas = try MCPSchemas.loaded.get()
        let valueSchemas = try preferenceValueSchemas(schemas)
        prefs.agentsChangeSettings = false
        let before = try await preferenceCall(sessions, "preferences_read")
        XCTAssertEqual(before["automation_preferences_write_enabled"] as? Bool, false)
        for key in EditorPreferences.Key.allCases.map(\.rawValue) {
            let current = try XCTUnwrap(before[key], key)
            // A different value, so a refusal is not mistaken for a write that changed nothing.
            let value: Any
            if let schema = valueSchemas[key] {
                value = try XCTUnwrap(differentValue(from: current, schema: schema), key)
                XCTAssertNoThrow(try schemas.validate(tool: "preferences_set", arguments: [
                    "operation_id": UUID().uuidString, "key": key, "value": value
                ]), "\(key) = \(value) is valid")
            } else {
                XCTAssertTrue(EditorPreferences.Key.agentReadOnly.map(\.rawValue).contains(key), "\(key) has no value schema")
                value = (current as? Bool).map { !$0 as Any } ?? 7
            }
            XCTAssertFalse(same(value, current), key)
            do {
                _ = try await preferenceCall(sessions, "preferences_set", ["key": key, "value": value])
                XCTFail("\(key) changed with agent settings off")
            } catch let failure as MCPFailure {
                XCTAssertEqual(failure.code, "settings_write_disabled", key)
                XCTAssertTrue(failure.message.contains("Let agents change settings"), failure.message)
            }
        }
        let after = try await preferenceCall(sessions, "preferences_read")
        for key in EditorPreferences.Key.allCases.map(\.rawValue) {
            XCTAssertTrue(same(try XCTUnwrap(after[key], key), try XCTUnwrap(before[key], key)), "\(key) changed")
        }
        XCTAssertEqual(prefs.historyLimit, 50)
        XCTAssertThrowsError(try prefs.checkAgentWrite())
        prefs.agentsChangeSettings = true
        XCTAssertNoThrow(try prefs.checkAgentWrite())
        _ = try await preferenceCall(sessions, "preferences_set", ["key": "history_max_steps", "value": 9])
        XCTAssertEqual(prefs.historyLimit, 9)
    }

    func testLayoutCommandsWriteTheSharedPreferences() async throws {
        let prefs = EditorPreferences()
        let sessions = ProjectSessions(preferences: prefs)
        let session = sessions.session(for: UUID())
        defer { session.end() }
        let set = try await sessions.mcpPresentation(
            tool: "workspace_layout_set", arguments: ["action": "set_full_height_panel", "enabled": true],
            session: session, checkAccess: {})
        let state = try XCTUnwrap(set)
        XCTAssertTrue(prefs.fullHeightSidebar)
        XCTAssertEqual(state["full_height_panel"] as? Bool, true)
        prefs.fullHeightSidebar = false
        let layout = try await sessions.mcpPresentation(tool: "workspace_layout_read", arguments: [:],
                                                        session: session, checkAccess: {})
        let read = try XCTUnwrap(layout)
        XCTAssertEqual(read["full_height_panel"] as? Bool, false)
    }
}

