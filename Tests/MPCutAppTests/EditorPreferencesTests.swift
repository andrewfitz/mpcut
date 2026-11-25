import AppKit
import SwiftUI
import MPCutCore
import XCTest
@testable import MPCutApp

final class EditorPreferencesTests: XCTestCase {
    @MainActor
    func testRecentFilesPersistPromoteAndClear() throws {
        let suite = "mpcut.recents." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = RecentFiles(defaults: defaults)
        let first = URL(fileURLWithPath: "/Movies/First.cut")
        let second = URL(fileURLWithPath: "/Movies/Second.mov")
        files.record([first, second, first])
        files.record([second])
        XCTAssertEqual(RecentFiles(defaults: defaults).urls, [second, first])
        files.clear()
        XCTAssertTrue(RecentFiles(defaults: defaults).urls.isEmpty)
    }

    @MainActor
    func testPaddingIgnoresRetiredTotalAndStoresSecondsPerSide() throws {
        let name = "mpcut.padding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0.6, forKey: "leavePause")
        let preferences = EditorPreferences(defaults: defaults)
        XCTAssertEqual(preferences.padding, 0.2)
        preferences.padding = 0
        XCTAssertEqual(EditorPreferences(defaults: defaults).padding, 0)
    }

    @MainActor
    func testSteppingFromTypedLimitCommitsOnlyTheFinishedCount() async throws {
        _ = NSApplication.shared
        let settings = EditorPreferences()
        let field = HistoryLimitField(limit: Binding(get: { settings.historyLimit }, set: { settings.historyLimit = $0 }))
        let host = NSHostingView(rootView: field)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        let views = descendants(host)
        let entry = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first)
        let stepper = try XCTUnwrap(views.compactMap { $0 as? NSStepper }.first)
        XCTAssertTrue(window.makeFirstResponder(entry))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("200", replacementRange: editor.selectedRange())
        let deadline = ContinuousClock.now + .seconds(2)
        while entry.stringValue != "200", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        XCTAssertEqual(settings.historyLimit, 50)
        XCTAssertEqual(entry.stringValue, "200")
        // AppKit sends a relative step to the SwiftUI stepper while its neighboring field still owns focus.
        stepper.integerValue += 1
        XCTAssertTrue(stepper.sendAction(try XCTUnwrap(stepper.action), to: stepper.target))
        XCTAssertEqual(settings.historyLimit, 201)

        let stepDeadline = ContinuousClock.now + .seconds(2)
        while entry.stringValue != "201", ContinuousClock.now < stepDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(entry.stringValue, "201")
        XCTAssertTrue(window.makeFirstResponder(entry))
        let currentEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        currentEditor.selectAll(nil)
        currentEditor.insertText("250", replacementRange: currentEditor.selectedRange())
        XCTAssertEqual(currentEditor.string, "250")
        XCTAssertEqual(settings.historyLimit, 201)
        window.isReleasedWhenClosed = false
        window.close()
        XCTAssertEqual(settings.historyLimit, 250)
    }

    @MainActor
    func testHistoryLimitPersistsZeroAndClampsBeforeNotifyingEditors() throws {
        let name = "mpcut.history-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorPreferences(defaults: defaults)
        XCTAssertEqual(settings.historyLimit, 50)
        var observed: [Int] = []
        let observer = settings.observeChanges {
            if $0 == .historyLimit { observed.append(settings.historyLimit) }
        }
        defer { observer.cancel() }

        settings.historyLimit = Int.max
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 500)
        settings.historyLimit = Int.min
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 0)
        settings.historyLimit = -1
        XCTAssertEqual(observed, [500, 0])
        defaults.set(1500, forKey: "history_max_steps")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 500)
        XCTAssertEqual(defaults.integer(forKey: "history_max_steps"), 500)
        defaults.set("not a count", forKey: "history_max_steps")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 50)
        defaults.set(2.5, forKey: "history_max_steps")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 50)
        defaults.set(false, forKey: "history_max_steps")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 50)
    }

    @MainActor
    func testLoadingTemporaryDefaultsLeavesStoredPreferencesIntact() throws {
        let name = "mpcut.preferences-overrides.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            // The argument domain is shared by all defaults instances in this process.
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: name)
        }
        defaults.set(true, forKey: "analysis_sidecar_reuse_enabled")
        defaults.setVolatileDomain(["analysis_sidecar_reuse_enabled": "NO", "automation_local_mcp_enabled": "YES",
                                    "history_max_steps": "1500"], forName: UserDefaults.argumentDomain)

        let settings = EditorPreferences(defaults: defaults)
        XCTAssertFalse(settings.useAnalysisSidecars)
        XCTAssertTrue(settings.localMCPEnabled)
        XCTAssertEqual(settings.historyLimit, 500)
        XCTAssertEqual(defaults.persistentDomain(forName: name) as? [String: Bool],
                       ["analysis_sidecar_reuse_enabled": true])

        settings.localMCPEnabled = false
        settings.historyLimit = 30
        XCTAssertEqual(defaults.persistentDomain(forName: name)?["automation_local_mcp_enabled"] as? Bool, false)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?["history_max_steps"] as? Int, 30)
    }

    @MainActor
    func testPreferencesPersistWithoutAnyEditor() throws {
        let name = "mpcut.preferences-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorPreferences(defaults: defaults)
        XCTAssertTrue(settings.useAnalysisSidecars)
        XCTAssertEqual(settings.snapTarget, .off)
        XCTAssertEqual(settings.volume, 1)
        settings.useAnalysisSidecars = false
        settings.defaultExportMode = .copy
        settings.jpegPreset = .full
        settings.isMuted = true
        XCTAssertFalse(settings.sourceTimeTicks)
        settings.sourceTimeTicks = true
        settings.volume = 0.35

        let reopened = EditorPreferences(defaults: defaults)
        XCTAssertFalse(reopened.useAnalysisSidecars)
        XCTAssertEqual(reopened.defaultExportMode, .copy)
        XCTAssertEqual(reopened.jpegPreset, .full)
        XCTAssertTrue(reopened.isMuted)
        XCTAssertTrue(reopened.sourceTimeTicks)
        XCTAssertEqual(reopened.volume, 0.35)
    }

    @MainActor
    func testMultipleEditorsUseSharedPreferencesAndKeepSessionState() {
        let settings = EditorPreferences()
        let first = EditorModel(preferences: settings)
        let second = EditorModel(preferences: settings)
        let multicam = MulticamEditorModel(preferences: settings)
        let independent = EditorModel()
        first.timelineZoom = 0.5
        second.skipPauses = true
        multicam.markIn = .init(numerator: 2)

        first.snapTarget = .scenes
        first.largeThumbnails = true
        second.minimumPause = 2
        second.padding = 0.125
        multicam.useAnalysisSidecars = false
        settings.defaultExportMode = .copy
        first.preview.isMuted = true
        second.preview.scrubSoundEnabled = false
        multicam.preview.volume = 0.4

        XCTAssertEqual(second.snapTarget, .scenes)
        XCTAssertTrue(second.largeThumbnails)
        XCTAssertTrue(multicam.preferences.largeThumbnails)
        XCTAssertEqual(first.minimumPause, 2)
        XCTAssertEqual(first.padding, 0.125)
        XCTAssertFalse(first.useAnalysisSidecars)
        XCTAssertFalse(second.useAnalysisSidecars)
        XCTAssertEqual(second.defaultExportMode, .copy)
        XCTAssertEqual(multicam.preferences.defaultExportMode, .copy)
        XCTAssertTrue(second.preview.isMuted)
        XCTAssertTrue(multicam.preview.isMuted)
        XCTAssertFalse(first.preview.scrubSoundEnabled)
        XCTAssertFalse(multicam.preview.scrubSoundEnabled)
        XCTAssertEqual(first.preview.volume, 0.4)
        XCTAssertEqual(second.preview.volume, 0.4)
        XCTAssertEqual(settings.volume, 0.4)
        XCTAssertEqual(first.timelineZoom, 0.5)
        XCTAssertEqual(second.timelineZoom, 0)
        XCTAssertFalse(first.skipPauses)
        XCTAssertTrue(second.skipPauses)
        XCTAssertEqual(multicam.markIn, .init(numerator: 2))
        XCTAssertTrue(independent.useAnalysisSidecars)
        XCTAssertFalse(independent.preview.isMuted)
    }

    @MainActor
    func testChangingSnapTargetInAnotherWindowPreservesTrimAudition() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Chirp", withExtension: "opus",
                                                     subdirectory: "Fixtures"))
        let settings = EditorPreferences()
        settings.useAnalysisSidecars = false
        let first = EditorModel(preferences: settings)
        let second = EditorModel(preferences: settings)
        defer { first.endSession() }
        first.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(5)
        while first.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(first.isAudioOnly)
        let clip = try XCTUnwrap(first.timelineClips.first)
        let boundary = try XCTUnwrap(first.trim(clip.id, edge: .start, sourceTime: clip.sourceEnd / 2, commit: false))
        XCTAssertEqual(first.audioPreviewSourceTime, boundary)
        XCTAssertEqual(first.playhead, 0)

        second.snapTarget = .keyframes

        XCTAssertEqual(first.snapTarget, .keyframes)
        XCTAssertEqual(first.effectiveSnapTarget, .off)
        XCTAssertEqual(first.audioPreviewSourceTime, boundary)
        XCTAssertEqual(first.playhead, 0)
        XCTAssertEqual(first.timelineClips.first?.sourceStart, 0)
    }

    // MARK: Key schedule

    @MainActor
    private func suite(_ name: String) throws -> (UserDefaults, String) {
        let suite = "mpcut.\(name).\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    @MainActor
    func testEveryScheduleKeyRoundTripsThroughAnIsolatedSuite() throws {
        let (defaults, name) = try suite("schedule-round-trip")
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorPreferences(defaults: defaults)
        var covered = Set<String>()
        func check<Value: Equatable>(_ path: ReferenceWritableKeyPath<EditorPreferences, Value>, _ value: Value, _ key: String,
                                     line: UInt = #line) {
            XCTAssertNotEqual(settings[keyPath: path], value, "\(key) needs a value other than its factory value", line: line)
            settings[keyPath: path] = value
            XCTAssertNotNil(defaults.persistentDomain(forName: name)?[key], key, line: line)
            XCTAssertEqual(EditorPreferences(defaults: defaults)[keyPath: path], value, key, line: line)
            covered.insert(key)
        }
        check(\.localMCPEnabled, true, "automation_local_mcp_enabled")
        check(\.automaticallyRefreshMedia, true, "media_auto_refresh_enabled")
        check(\.useAnalysisSidecars, false, "analysis_sidecar_reuse_enabled")
        check(\.historyLimit, 12, "history_max_steps")
        check(\.sourceTimeTicks, true, "timeline_source_time_ticks_enabled")
        check(\.snapTarget, .scenes, "timeline_snap_target")
        check(\.largeThumbnails, true, "timeline_large_previews_enabled")
        check(\.volume, 0.5, "playback_preview_volume_fraction")
        check(\.isMuted, true, "playback_preview_muted")
        check(\.scrubSoundEnabled, false, "playback_scrub_audio_enabled")
        check(\.defaultExportMode, .encode, "export_movie_default_mode")
        check(\.jpegPreset, .full, "export_jpeg_default_preset")
        check(\.warnBeforeLoweringExportTier, false, "export_tier_downgrade_warning_enabled")
        check(\.minimumPause, 2.5, "silence_min_pause_seconds")
        check(\.maxBlip, 0.3, "silence_max_blip_seconds")
        check(\.padding, 0.5, "silence_padding_per_side_seconds")
        check(\.multipleRecordingsAction, .multicam, "open_multiple_recordings_default_action")
        check(\.recentFilesLimit, 30, "recent_files_max_count")
        check(\.offersDraftRecovery, true, "draft_recovery_prompt_enabled")
        check(\.confirmsSceneRescan, false, "scene_rescan_confirmation_enabled")
        check(\.showsProjectExportMessage, false, "project_export_completion_message_enabled")
        check(\.showsCutSections, false, "timeline_cut_sections_default_enabled")
        check(\.fullHeightSidebar, true, "workspace_full_height_sidebar_enabled")
        check(\.trackLabelWidth, 106, "multicam_track_label_width_points")
        check(\.stillDuration, 0.04, "still_placement_default_duration_seconds")
        check(\.gapDuration, 600, "gap_default_duration_seconds")
        check(\.gapColor, "#1A2B3C", "gap_default_color")
        check(\.stillTimelineWidth, 3840, "still_timeline_default_width_pixels")
        check(\.stillTimelineHeight, 16, "still_timeline_default_height_pixels")
        check(\.stillTimelineFrameRate, 23.976, "still_timeline_default_frame_rate")
        check(\.stillTimelineCodec, .prores, "still_timeline_default_codec")
        check(\.timeDisplay, .frames, "timeline_time_display")
        check(\.playbackSpeed, .eighth, "playback_default_speed")
        check(\.cutPreviewPreroll, 0.25, "playback_cut_preview_preroll_seconds")
        check(\.cutPreviewPostroll, 10, "playback_cut_preview_postroll_seconds")
        check(\.viewerForceSDR, true, "playback_viewer_force_sdr_enabled")
        check(\.monitorForceSDR, true, "playback_monitor_force_sdr_enabled")
        check(\.monitorCleanFeed, true, "playback_monitor_clean_feed_enabled")
        check(\.monitorPlacement, .lastPosition, "playback_monitor_placement")
        check(\.autoScanScenes, true, "analysis_scene_auto_scan_enabled")
        check(\.autoScanSilence, true, "analysis_silence_auto_scan_enabled")
        check(\.tilesScanLayout, .evenGrid, "tiles_scan_default_layout")
        check(\.tilesScanColumns, 12, "tiles_scan_default_grid_columns")
        check(\.tilesScanRows, 1, "tiles_scan_default_grid_rows")
        check(\.tilesScanDetail, .everyFrame, "tiles_scan_default_detail")
        check(\.dialogueMinimumHold, 0.04, "tiles_dialogue_default_min_hold_seconds")
        check(\.dialogueOverlap, .visibleSpeaker, "tiles_dialogue_default_overlap_policy")
        check(\.dialogueOffscreen, .reaction, "tiles_dialogue_default_offscreen_policy")
        check(\.transcriptEngine, "parakeet", "transcript_default_engine")
        check(\.identifiesSpeakers, true, "transcript_default_speaker_identification_enabled")
        check(\.downloadsModels, true, "transcript_default_model_download_enabled")
        check(\.followsPlayback, false, "transcript_follow_playback_default_enabled")
        check(\.readerTextSize, 24, "transcript_reader_text_size_points")
        check(\.boundaryPolicy, .copySafe, "transcript_edit_default_boundary_policy")
        check(\.retainedPause, 0, "transcript_tighten_default_retained_pause_seconds")
        check(\.fillerTerms, "um, uh, you know", "transcript_default_filler_terms")
        check(\.transcriptExportFormat, .vtt, "transcript_export_default_format")
        check(\.captionLineCharacters, 20, "transcript_caption_max_line_characters")
        check(\.captionLines, 3, "transcript_caption_max_lines")
        check(\.captionCueSeconds, 1, "transcript_caption_max_cue_seconds")
        check(\.captionSpeakerLabels, false, "transcript_caption_speaker_labels_enabled")
        check(\.reencodeCodec, .hevc, "export_reencode_default_codec")
        check(\.reencodeQuality, .highQuality, "export_reencode_default_quality")
        check(\.proresQuality, .proresHQ, "export_prores_default_quality")
        check(\.reencodeContainer, .mkv, "export_reencode_default_container")
        check(\.multicamAudioLayout, .downmixStereo, "export_multicam_default_audio_layout")
        check(\.savesExportResult, true, "export_result_json_default_enabled")
        check(\.opensResolveTimeline, false, "resolve_send_open_timeline_default_enabled")
        check(\.exportStartFolder, .chosen, "export_start_folder_mode")
        check(\.revealsFinishedExport, true, "export_finished_reveal_enabled")
        check(\.notifiesFinishedExport, true, "export_finished_notification_enabled")
        check(\.playsFinishedExportSound, true, "export_finished_sound_enabled")
        check(\.sharedCacheLimitBytes, 50_000_000_000, "analysis_shared_cache_max_bytes")
        check(\.draftRetentionDays, 365, "draft_retention_days")
        check(\.agentsChangeSettings, false, "automation_preferences_write_enabled")
        check(\.agentsReplaceFiles, false, "automation_file_replace_enabled")
        XCTAssertEqual(covered, Set(EditorPreferences.Key.allCases.map(\.rawValue)))
        XCTAssertEqual(covered.count, 76)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true).path
        check(\.exportStartFolderPath, temporary, "export_start_folder_path")
        check(\.transcriptHelperPath, "/opt/transcriberrr/bin/transcriberrr", "transcript_helper_path")
        check(\.monitorLastFrame, CGRect(x: 10, y: 20, width: 800, height: 450), "playback_monitor_last_frame")
        check(\.settingsPage, .automation, "settings_selected_page")
        check(\.projectMediaLastLocateFolder, temporary, "project_media_last_locate_folder")
        check(\.transcriptSuggestedAngles, Data("{}".utf8), "transcript_suggested_angles")
        settings.suppress(.sceneRescan)
        XCTAssertEqual(defaults.stringArray(forKey: "warnings_suppressed"), ["scene_rescan"])
        XCTAssertEqual(EditorPreferences(defaults: defaults).suppressedWarnings, [.sceneRescan])
        covered.insert("warnings_suppressed")
        XCTAssertEqual(covered.subtracting(EditorPreferences.Key.allCases.map(\.rawValue)),
                       Set(EditorPreferences.LocalKey.allCases.map(\.rawValue)))
    }

    @MainActor
    func testFactoryValuesMatchTheScheduleAndTheRestoreTable() {
        let settings = EditorPreferences()
        for page in SettingsPage.allCases { XCTAssertTrue(settings.hasFactoryValues(on: page), page.rawValue) }
        XCTAssertEqual(settings.multipleRecordingsAction, .ask)
        XCTAssertEqual(settings.recentFilesLimit, 10)
        XCTAssertEqual(settings.trackLabelWidth, 172)
        XCTAssertEqual(settings.gapColor, "#000000")
        XCTAssertEqual([settings.stillTimelineWidth, settings.stillTimelineHeight], [1920, 1080])
        XCTAssertEqual(settings.stillTimelineFrameRate, 30)
        XCTAssertEqual(settings.playbackSpeed, .normal)
        XCTAssertEqual(settings.tilesScanLayout, .videoCall)
        XCTAssertEqual(settings.tilesScanDetail, .adaptive)
        XCTAssertEqual(settings.boundaryPolicy, .nearestFrame)
        XCTAssertEqual(settings.transcriptExportFormat, .json)
        XCTAssertEqual(settings.reencodeCodec, ExportRules.defaultCodec)
        XCTAssertEqual(settings.reencodeQuality, .balanced)
        XCTAssertEqual(settings.proresQuality, .prores422)
        XCTAssertEqual(settings.multicamAudioLayout, .separateTracks)
        XCTAssertTrue(settings.agentsChangeSettings)
        XCTAssertTrue(settings.agentsReplaceFiles)
        XCTAssertEqual(settings.settingsPage, .general)
        XCTAssertNil(settings.monitorLastFrame)
        let restorable = Set(EditorPreferences.factories.map(\.key))
        let protected: Set = ["history_max_steps", "automation_local_mcp_enabled", "automation_preferences_write_enabled",
                              "automation_file_replace_enabled"]
        XCTAssertEqual(Set(EditorPreferences.Key.allCases.map(\.rawValue)).subtracting(restorable), protected)
        XCTAssertEqual(restorable.count, EditorPreferences.factories.count, "A key is restored twice")
    }

    @MainActor
    func testUnreadableAndOutOfRangeStoredValuesKeepTheirFactoryValues() throws {
        let (defaults, name) = try suite("schedule-invalid")
        defer { defaults.removePersistentDomain(forName: name) }
        let invalid: [String: Any] = [
            "open_multiple_recordings_default_action": "always", "recent_files_max_count": 31, "draft_recovery_prompt_enabled": "maybe",
            "scene_rescan_confirmation_enabled": ["x"], "timeline_cut_sections_default_enabled": "sometimes",
            "workspace_full_height_sidebar_enabled": "tall", "multicam_track_label_width_points": 400.0,
            "still_placement_default_duration_seconds": 0.01, "gap_default_duration_seconds": "long", "gap_default_color": "black",
            "still_timeline_default_width_pixels": 1921, "still_timeline_default_height_pixels": 9000,
            "still_timeline_default_frame_rate": 0, "still_timeline_default_codec": "jpeg", "timeline_time_display": "timecode",
            "playback_default_speed": 3, "playback_cut_preview_preroll_seconds": 0.1, "playback_cut_preview_postroll_seconds": 11,
            "playback_viewer_force_sdr_enabled": "perhaps", "playback_monitor_placement": "left",
            "tiles_scan_default_layout": "meeting", "tiles_scan_default_grid_columns": 13, "tiles_scan_default_grid_rows": 0,
            "tiles_scan_default_detail": "sparse-ish", "tiles_dialogue_default_min_hold_seconds": 0,
            "tiles_dialogue_default_overlap_policy": "visibleSpeaker", "tiles_dialogue_default_offscreen_policy": 2,
            "transcript_default_engine": 7, "transcript_reader_text_size_points": 30, "transcript_edit_default_boundary_policy": "nearest",
            "transcript_tighten_default_retained_pause_seconds": Double.infinity, "transcript_default_filler_terms": ["um"],
            "transcript_export_default_format": "docx", "transcript_caption_max_line_characters": 19.5,
            "transcript_caption_max_lines": 4, "transcript_caption_max_cue_seconds": 25,
            "export_reencode_default_codec": "jpeg", "export_reencode_default_quality": "422",
            "export_prores_default_quality": "balanced", "export_reencode_default_container": "avi",
            "export_multicam_default_audio_layout": "mono", "export_start_folder_mode": "desktop",
            "analysis_shared_cache_max_bytes": -1, "draft_retention_days": 366, "automation_preferences_write_enabled": "off-ish",
            "export_start_folder_path": 12, "settings_selected_page": "advanced", "playback_monitor_last_frame": "nonsense",
            "warnings_suppressed": ["scene_rescan", "every_alert"]
        ]
        for (key, value) in invalid { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "recent_files_max_count")
        let settings = EditorPreferences(defaults: defaults)
        for page in SettingsPage.allCases { XCTAssertTrue(settings.hasFactoryValues(on: page), page.rawValue) }
        XCTAssertTrue(settings.agentsChangeSettings)
        XCTAssertEqual(settings.settingsPage, .general)
        XCTAssertNil(settings.monitorLastFrame)
        XCTAssertEqual(settings.exportStartFolderPath, "")
        XCTAssertTrue(settings.suppressedWarnings.isEmpty)
        // Loading never rewrites what it could not read.
        XCTAssertEqual(defaults.string(forKey: "gap_default_color"), "black")

        settings.recentFilesLimit = 99
        settings.stillTimelineWidth = 1921
        settings.stillDuration = .nan
        settings.reencodeQuality = .proresHQ
        settings.gapColor = "#abcdef"
        XCTAssertEqual(settings.recentFilesLimit, 30)
        XCTAssertEqual(settings.stillTimelineWidth, 1920)
        XCTAssertEqual(settings.stillDuration, 2)
        XCTAssertEqual(settings.reencodeQuality, .balanced)
        XCTAssertEqual(settings.gapColor, "#ABCDEF")
        XCTAssertEqual(EditorPreferences(defaults: defaults).recentFilesLimit, 30)
    }

    @MainActor
    func testLaunchArgumentValuesApplyWithoutBeingStored() throws {
        let (defaults, name) = try suite("schedule-arguments")
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            // The argument domain is shared by all defaults instances in this process.
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: name)
        }
        defaults.set(5, forKey: "recent_files_max_count")
        defaults.setVolatileDomain(["recent_files_max_count": "20", "playback_viewer_force_sdr_enabled": "YES",
                                    "export_reencode_default_codec": "prores", "playback_default_speed": "0.5",
                                    "automation_preferences_write_enabled": "NO"], forName: UserDefaults.argumentDomain)
        let settings = EditorPreferences(defaults: defaults)
        XCTAssertEqual(settings.recentFilesLimit, 20)
        XCTAssertTrue(settings.viewerForceSDR)
        XCTAssertEqual(settings.reencodeCodec, .prores)
        XCTAssertEqual(settings.playbackSpeed, .half)
        XCTAssertFalse(settings.agentsChangeSettings)
        XCTAssertEqual(defaults.persistentDomain(forName: name) as? [String: Int], ["recent_files_max_count": 5])
    }

    @MainActor
    func testExistingValuesOfTheMirroredKeysAreRead() throws {
        let (defaults, name) = try suite("mirrored-keys")
        defer { defaults.removePersistentDomain(forName: name) }
        // How the context menu, the dock button and the divider stored them before Settings had a control.
        defaults.set(true, forKey: "workspace_full_height_sidebar_enabled")
        defaults.set(230.0, forKey: "multicam_track_label_width_points")
        defaults.set(true, forKey: "playback_viewer_force_sdr_enabled")
        defaults.set(true, forKey: "playback_monitor_force_sdr_enabled")
        defaults.set(true, forKey: "playback_monitor_clean_feed_enabled")
        let settings = EditorPreferences(defaults: defaults)
        XCTAssertTrue(settings.fullHeightSidebar)
        XCTAssertEqual(settings.trackLabelWidth, 230)
        XCTAssertTrue(settings.viewerForceSDR)
        XCTAssertTrue(settings.monitorForceSDR)
        XCTAssertTrue(settings.monitorCleanFeed)
    }

    @MainActor
    func testRestoreDefaultsResetsAPageThroughItsSettersAndSkipsTheProtectedRows() throws {
        let (defaults, name) = try suite("restore-defaults")
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorPreferences(defaults: defaults)
        settings.historyLimit = 9
        settings.localMCPEnabled = true
        settings.agentsChangeSettings = false
        settings.agentsReplaceFiles = false
        settings.recentFilesLimit = 3
        settings.warnBeforeLoweringExportTier = false
        settings.snapTarget = .silence
        settings.trackLabelWidth = 300
        settings.viewerForceSDR = true
        settings.minimumPause = 3
        settings.fillerTerms = "um"
        settings.reencodeCodec = .prores
        settings.exportStartFolderPath = "/Volumes/Exports"
        settings.useAnalysisSidecars = false
        settings.draftRetentionDays = 30
        var changes: [EditorPreferences.Change] = []
        let observer = settings.observeChanges { changes.append($0) }
        defer { observer.cancel() }

        settings.restoreDefaults(on: .editing)
        XCTAssertEqual(settings.snapTarget, .off)
        XCTAssertEqual(settings.trackLabelWidth, 172)
        XCTAssertTrue(settings.viewerForceSDR, "Another page keeps its values")
        XCTAssertTrue(changes.contains(.snapTarget) && changes.contains(.trackLabelWidth))
        for page in SettingsPage.allCases { settings.restoreDefaults(on: page) }
        for page in SettingsPage.allCases { XCTAssertTrue(settings.hasFactoryValues(on: page), page.rawValue) }
        XCTAssertTrue(changes.contains(.minimumPause), "Open projects recalculate pauses")
        XCTAssertEqual(settings.historyLimit, 9)
        XCTAssertTrue(settings.localMCPEnabled)
        XCTAssertFalse(settings.agentsChangeSettings)
        XCTAssertFalse(settings.agentsReplaceFiles)
        let reopened = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reopened.recentFilesLimit, 10)
        XCTAssertTrue(reopened.warnBeforeLoweringExportTier)
        XCTAssertEqual(reopened.exportStartFolderPath, "")
        XCTAssertTrue(reopened.useAnalysisSidecars)
        XCTAssertEqual(reopened.historyLimit, 9)
    }

    @MainActor
    func testResetAllWarningsAsksAgain() {
        let settings = EditorPreferences()
        XCTAssertFalse(settings.hasSuppressedWarnings)
        settings.multipleRecordingsAction = .multicam
        XCTAssertFalse(settings.hasSuppressedWarnings, "A Finder default chosen in Settings is not a silenced warning")
        settings.resetAllWarnings()
        XCTAssertEqual(settings.multipleRecordingsAction, .multicam)

        settings.multipleRecordingsAction = .ask
        settings.suppress(.sceneRescan)
        settings.suppress(.exportTierDowngrade)
        settings.suppress(.openMultipleRecordings, choosing: .join)
        settings.showsProjectExportMessage = false
        XCTAssertEqual(settings.multipleRecordingsAction, .join)
        XCTAssertEqual(settings.suppressedWarnings, Set(SuppressibleWarning.allCases))
        XCTAssertFalse(SuppressibleWarning.allCases.contains(where: settings.asks))
        settings.resetAllWarnings()
        XCTAssertTrue(SuppressibleWarning.allCases.allSatisfy(settings.asks))
        XCTAssertTrue(settings.showsProjectExportMessage)
        XCTAssertTrue(settings.suppressedWarnings.isEmpty)
        XCTAssertFalse(settings.hasSuppressedWarnings)
    }

    @MainActor
    func testForceSDRAndCleanFeedReachEveryOpenSurface() throws {
        _ = NSApplication.shared
        let settings = EditorPreferences()
        let viewer = PreviewSurface(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        let other = PreviewSurface(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        let monitor = PreviewSurface(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        viewer.setMonitor(false, preferences: settings)
        other.setMonitor(false, preferences: settings)
        monitor.setMonitor(true, preferences: settings)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        func item(_ title: String, in surface: PreviewSurface) throws -> NSMenuItem {
            try XCTUnwrap(surface.menu(for: click)?.items.first { $0.title == title }, title)
        }
        let sdr = try item("Force SDR Preview", in: viewer)
        XCTAssertEqual(sdr.state, .off)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(sdr.action), to: sdr.target, from: sdr))
        XCTAssertTrue(settings.viewerForceSDR)
        XCTAssertEqual(try item("Force SDR Preview", in: other).state, .on)
        XCTAssertEqual(try item("Force SDR Preview", in: monitor).state, .off, "The Video Monitor has its own choice")
        settings.monitorCleanFeed = true
        XCTAssertEqual(try item("Clean Feed", in: monitor).state, .on)
        settings.viewerForceSDR = false
        XCTAssertEqual(try item("Force SDR Preview", in: viewer).state, .off)
    }
}

