import Combine
import Foundation
import MPCutCore

/// What opening several recordings from Finder does.
enum MultipleRecordingsAction: String, CaseIterable { case ask, join, multicam }
enum VideoMonitorPlacement: String, CaseIterable { case otherDisplay = "other_display", lastPosition = "last_position" }
/// The Find Tiles layout for a recording with no saved layout. A build without TileTrail offers only the even grid.
enum TilesScanLayout: String, CaseIterable { case videoCall = "video_call", cameraMultiview = "camera_multiview", evenGrid = "even_grid" }
/// Automatic keeps each editor's own container: MP4 in the sequence editor, MOV in multicam. ProRes is always MOV.
enum ExportContainerChoice: String, CaseIterable { case automatic, mp4, mov, mkv }
/// An alert that offers “Don't ask again”. Whether it asks follows its Settings value.
enum SuppressibleWarning: String, CaseIterable {
    case openMultipleRecordings = "open_multiple_recordings", sceneRescan = "scene_rescan"
    case exportTierDowngrade = "export_tier_downgrade"
}

/// Who is writing preferences. The MCP dispatcher sets `request` for the whole duration of each agent command,
/// so a click the user makes while that command is suspended is still the user's.
enum AgentOrigin {
    @TaskLocal static var request: AgentSettingsRequest?
}

/// One agent command's refused preference writes. The dispatcher answers `settings_write_disabled` when any were refused.
@MainActor
final class AgentSettingsRequest {
    private(set) var refusedKeys: [String] = []
    private var refusedReadOnlyKey = false

    nonisolated init() {}

    func refuse(_ key: EditorPreferences.Key, readOnly: Bool) {
        if !refusedKeys.contains(key.rawValue) { refusedKeys.append(key.rawValue) }
        if readOnly { refusedReadOnlyKey = true }
    }

    var failure: MCPFailure? {
        guard !refusedKeys.isEmpty else { return nil }
        let names = refusedKeys.joined(separator: ", ")
        if refusedReadOnlyKey {
            return MCPFailure("settings_write_disabled",
                              "Agents cannot change \(names). Local MCP control, the agent permissions and the Storage limits are set in Settings.")
        }
        return MCPFailure("settings_write_disabled",
                          "Agents cannot change settings (\(names)). Turn on Settings → Automation → Let agents change settings.")
    }
}

@MainActor
final class EditorPreferences: ObservableObject {
    /// The key schedule. `preferences_read` lists every case.
    enum Key: String, CaseIterable {
        case automationLocalMcpEnabled = "automation_local_mcp_enabled"
        case mediaAutoRefreshEnabled = "media_auto_refresh_enabled"
        case analysisSidecarReuseEnabled = "analysis_sidecar_reuse_enabled"
        case historyMaxSteps = "history_max_steps"
        case timelineSourceTimeTicksEnabled = "timeline_source_time_ticks_enabled"
        case timelineSnapTarget = "timeline_snap_target"
        case timelineLargePreviewsEnabled = "timeline_large_previews_enabled"
        case playbackPreviewVolumeFraction = "playback_preview_volume_fraction"
        case playbackPreviewMuted = "playback_preview_muted"
        case playbackScrubAudioEnabled = "playback_scrub_audio_enabled"
        case exportMovieDefaultMode = "export_movie_default_mode"
        case exportJpegDefaultPreset = "export_jpeg_default_preset"
        case exportTierDowngradeWarningEnabled = "export_tier_downgrade_warning_enabled"
        case silenceMinPauseSeconds = "silence_min_pause_seconds"
        case silenceMaxBlipSeconds = "silence_max_blip_seconds"
        case silencePaddingPerSideSeconds = "silence_padding_per_side_seconds"

        case openMultipleRecordingsDefaultAction = "open_multiple_recordings_default_action"
        case recentFilesMaxCount = "recent_files_max_count"
        case draftRecoveryPromptEnabled = "draft_recovery_prompt_enabled"
        case sceneRescanConfirmationEnabled = "scene_rescan_confirmation_enabled"
        case projectExportCompletionMessageEnabled = "project_export_completion_message_enabled"
        case timelineCutSectionsDefaultEnabled = "timeline_cut_sections_default_enabled"
        case workspaceFullHeightSidebarEnabled = "workspace_full_height_sidebar_enabled"
        case multicamTrackLabelWidthPoints = "multicam_track_label_width_points"
        case stillPlacementDefaultDurationSeconds = "still_placement_default_duration_seconds"
        case gapDefaultDurationSeconds = "gap_default_duration_seconds"
        case gapDefaultColor = "gap_default_color"
        case stillTimelineDefaultWidthPixels = "still_timeline_default_width_pixels"
        case stillTimelineDefaultHeightPixels = "still_timeline_default_height_pixels"
        case stillTimelineDefaultFrameRate = "still_timeline_default_frame_rate"
        case stillTimelineDefaultCodec = "still_timeline_default_codec"
        case timelineTimeDisplay = "timeline_time_display"
        case playbackDefaultSpeed = "playback_default_speed"
        case playbackCutPreviewPrerollSeconds = "playback_cut_preview_preroll_seconds"
        case playbackCutPreviewPostrollSeconds = "playback_cut_preview_postroll_seconds"
        case playbackViewerForceSdrEnabled = "playback_viewer_force_sdr_enabled"
        case playbackMonitorForceSdrEnabled = "playback_monitor_force_sdr_enabled"
        case playbackMonitorCleanFeedEnabled = "playback_monitor_clean_feed_enabled"
        case playbackMonitorPlacement = "playback_monitor_placement"
        case analysisSceneAutoScanEnabled = "analysis_scene_auto_scan_enabled"
        case analysisSilenceAutoScanEnabled = "analysis_silence_auto_scan_enabled"
        case tilesScanDefaultLayout = "tiles_scan_default_layout"
        case tilesScanDefaultGridColumns = "tiles_scan_default_grid_columns"
        case tilesScanDefaultGridRows = "tiles_scan_default_grid_rows"
        case tilesScanDefaultDetail = "tiles_scan_default_detail"
        case tilesDialogueDefaultMinHoldSeconds = "tiles_dialogue_default_min_hold_seconds"
        case tilesDialogueDefaultOverlapPolicy = "tiles_dialogue_default_overlap_policy"
        case tilesDialogueDefaultOffscreenPolicy = "tiles_dialogue_default_offscreen_policy"
        case transcriptDefaultEngine = "transcript_default_engine"
        case transcriptDefaultSpeakerIdentificationEnabled = "transcript_default_speaker_identification_enabled"
        case transcriptDefaultModelDownloadEnabled = "transcript_default_model_download_enabled"
        case transcriptFollowPlaybackDefaultEnabled = "transcript_follow_playback_default_enabled"
        case transcriptReaderTextSizePoints = "transcript_reader_text_size_points"
        case transcriptEditDefaultBoundaryPolicy = "transcript_edit_default_boundary_policy"
        case transcriptTightenDefaultRetainedPauseSeconds = "transcript_tighten_default_retained_pause_seconds"
        case transcriptDefaultFillerTerms = "transcript_default_filler_terms"
        case transcriptExportDefaultFormat = "transcript_export_default_format"
        case transcriptCaptionMaxLineCharacters = "transcript_caption_max_line_characters"
        case transcriptCaptionMaxLines = "transcript_caption_max_lines"
        case transcriptCaptionMaxCueSeconds = "transcript_caption_max_cue_seconds"
        case transcriptCaptionSpeakerLabelsEnabled = "transcript_caption_speaker_labels_enabled"
        case exportReencodeDefaultCodec = "export_reencode_default_codec"
        case exportReencodeDefaultQuality = "export_reencode_default_quality"
        case exportProresDefaultQuality = "export_prores_default_quality"
        case exportReencodeDefaultContainer = "export_reencode_default_container"
        case exportMulticamDefaultAudioLayout = "export_multicam_default_audio_layout"
        case exportResultJsonDefaultEnabled = "export_result_json_default_enabled"
        case resolveSendOpenTimelineDefaultEnabled = "resolve_send_open_timeline_default_enabled"
        case exportStartFolderMode = "export_start_folder_mode"
        case exportFinishedRevealEnabled = "export_finished_reveal_enabled"
        case exportFinishedNotificationEnabled = "export_finished_notification_enabled"
        case exportFinishedSoundEnabled = "export_finished_sound_enabled"
        case analysisSharedCacheMaxBytes = "analysis_shared_cache_max_bytes"
        case draftRetentionDays = "draft_retention_days"
        case automationPreferencesWriteEnabled = "automation_preferences_write_enabled"
        case automationFileReplaceEnabled = "automation_file_replace_enabled"

        /// Agents read these and cannot set them: setting one removes files or widens access.
        static let agentReadOnly: Set<Key> = [.automationLocalMcpEnabled, .automationPreferencesWriteEnabled,
                                              .automationFileReplaceEnabled, .draftRetentionDays, .analysisSharedCacheMaxBytes]
    }

    /// Stored values kept out of the MCP list.
    enum LocalKey: String, CaseIterable {
        case exportStartFolderPath = "export_start_folder_path"
        case transcriptHelperPath = "transcript_helper_path"
        case playbackMonitorLastFrame = "playback_monitor_last_frame"
        case settingsSelectedPage = "settings_selected_page"
        case projectMediaLastLocateFolder = "project_media_last_locate_folder"
        case transcriptSuggestedAngles = "transcript_suggested_angles"
        case warningsSuppressed = "warnings_suppressed"
    }

    enum Change {
        case automaticallyRefreshMedia, localMCPEnabled, useAnalysisSidecars, defaultExportMode, snapTarget, largeThumbnails
        case sourceTimeTicks, maxBlip, minimumPause, padding, volume, isMuted, scrubSoundEnabled, jpegPreset, historyLimit
        case multipleRecordingsAction, recentFilesLimit, offersDraftRecovery, confirmsSceneRescan, showsProjectExportMessage
        case showsCutSections, fullHeightSidebar, trackLabelWidth, stillDuration, gapDuration, gapColor
        case stillTimelineWidth, stillTimelineHeight, stillTimelineFrameRate, stillTimelineCodec, timeDisplay
        case playbackSpeed, cutPreviewPreroll, cutPreviewPostroll, viewerForceSDR, monitorForceSDR, monitorCleanFeed
        case monitorPlacement, monitorLastFrame, autoScanScenes, autoScanSilence
        case tilesScanLayout, tilesScanColumns, tilesScanRows, tilesScanDetail, dialogueMinimumHold, dialogueOverlap, dialogueOffscreen
        case transcriptEngine, identifiesSpeakers, downloadsModels, followsPlayback, readerTextSize, boundaryPolicy
        case retainedPause, fillerTerms, transcriptExportFormat, captionLineCharacters, captionLines, captionCueSeconds
        case captionSpeakerLabels, transcriptHelperPath
        case reencodeCodec, reencodeQuality, proresQuality, reencodeContainer, multicamAudioLayout, savesExportResult
        case opensResolveTimeline, exportStartFolder, exportStartFolderPath, revealsFinishedExport, notifiesFinishedExport
        case playsFinishedExportSound, sharedCacheLimitBytes, draftRetentionDays, agentsChangeSettings, agentsReplaceFiles
        case settingsPage, projectMediaLastLocateFolder, transcriptSuggestedAngles, suppressedWarnings
    }

    let recentFiles: RecentFiles
    private var defaults: UserDefaults?
    /// Set once the stored values are loaded. Writes made while loading are never refused or persisted.
    private var isLoaded = false
    /// Set while a property observer puts back the value an agent was refused.
    private var isRestoringRefusedWrite = false
    /// Set while a property observer replaces an out-of-range or invalid value. The nested observer returns at once,
    /// so the outer one stores and announces the fixed value once, against the true previous value.
    private var isNormalizing = false
    // Subscribers that recalculate project state need to read the new value after it is stored.
    private let changes = PassthroughSubject<Change, Never>()

    static var applicationDefaults: UserDefaults? {
        guard let name = ProcessInfo.processInfo.environment["MPCUT_TEST_SOCKET_DIRECTORY"], !name.isEmpty else {
            return .standard
        }
        // A separate home does not isolate cfprefsd for the same bundle ID.
        guard !MCPSocket.directory.isEmpty else { return nil }
        return UserDefaults(suiteName: "com.mpcut.test-preferences." + name)
    }

    /// The persistent domain `applicationDefaults` writes, so the keys that remove files can be read from it alone.
    static var applicationDefaultsDomain: String? {
        guard let name = ProcessInfo.processInfo.environment["MPCUT_TEST_SOCKET_DIRECTORY"], !name.isEmpty else {
            return Bundle.main.bundleIdentifier
        }
        return MCPSocket.directory.isEmpty ? nil : "com.mpcut.test-preferences." + name
    }

    static let historyStepRange = 0...CutProject.maximumHistorySteps
    static let recentFilesRange = 1...30
    static let trackLabelWidthRange = 106.0...360
    static let stillDurationRange = 0.04...600.0
    static let stillTimelinePixelRange = 16...8192
    static let stillTimelineFrameRateRange = 1.0...240
    static let stillTimelineCodecs: [ReencodeCodec] = [.h264, .hevc, .prores]
    static let cutPreviewRange = 0.25...10.0
    static let tilesGridRange = 1...12
    static let tilesScanDetails: [ParticipantSampling] = [.adaptive, .everyFrame, .sparse]
    static let dialogueHoldRange = 0.04...60.0
    static let boundaryPolicies: [TranscriptEditRequest.BoundaryPolicy] = [.nearestFrame, .copySafe, .exact]
    static let readerTextSizeRange = 11.0...24
    static let retainedPauseRange = 0.0...10
    static let transcriptExportFormats: [TranscriptFormat] = [.json, .text, .srt, .vtt]
    static let captionLineCharacterRange = 20...80
    static let captionLineRange = 1...3
    static let captionCueRange = 1.0...20
    static let reencodeCodecs: [ReencodeCodec] = [.h264, .hevc, .prores]
    static let reencodeQualities = ExportRules.qualities(.h264)
    static let proresQualities = ExportRules.qualities(.prores)
    static let sharedCacheLimitRange = 0...Int.max
    static let draftRetentionRange = 0...365

    @Published private var storedHistoryLimit = 50
    var historyLimit: Int {
        get { storedHistoryLimit }
        set {
            let bounded = min(Self.historyStepRange.upperBound, max(Self.historyStepRange.lowerBound, newValue))
            let previous = storedHistoryLimit
            guard previous != bounded, !refusesAgentWrite(.historyMaxSteps) else { return }
            storedHistoryLimit = bounded
            save(bounded, replacing: previous, key: .historyMaxSteps, change: .historyLimit)
        }
    }

    @Published var localMCPEnabled = false {
        didSet {
            if !save(localMCPEnabled, replacing: oldValue, key: .automationLocalMcpEnabled, change: .localMCPEnabled) { localMCPEnabled = oldValue }
        }
    }
    @Published var localMCPStatus = "Off"

    @Published var automaticallyRefreshMedia = false {
        didSet {
            if !save(automaticallyRefreshMedia, replacing: oldValue, key: .mediaAutoRefreshEnabled, change: .automaticallyRefreshMedia) { automaticallyRefreshMedia = oldValue }
        }
    }

    @Published var useAnalysisSidecars = true {
        didSet {
            if !save(useAnalysisSidecars, replacing: oldValue, key: .analysisSidecarReuseEnabled, change: .useAnalysisSidecars) { useAnalysisSidecars = oldValue }
        }
    }
    /// The factory default of the movie export mode, from the export rules. The CLI uses the same one.
    static let factoryExportMode = ExportRules.defaultMode(for: .movie)
    @Published var defaultExportMode = EditorPreferences.factoryExportMode {
        didSet {
            if !save(defaultExportMode, replacing: oldValue, key: .exportMovieDefaultMode,
                 stored: defaultExportMode.rawValue, change: .defaultExportMode) { defaultExportMode = oldValue }
        }
    }
    /// Ask before an edit made by hand lowers the timeline tier. Nothing recalculates when it changes, so it is only stored.
    @Published var warnBeforeLoweringExportTier = true {
        didSet {
            if !save(warnBeforeLoweringExportTier, replacing: oldValue, key: .exportTierDowngradeWarningEnabled, change: nil) {
                warnBeforeLoweringExportTier = oldValue
            }
        }
    }
    @Published var snapTarget = TimelineSnapTarget.off {
        didSet {
            if !save(snapTarget, replacing: oldValue, key: .timelineSnapTarget, stored: snapTarget.rawValue, change: .snapTarget) { snapTarget = oldValue }
        }
    }
    @Published var sourceTimeTicks = false {
        didSet {
            if !save(sourceTimeTicks, replacing: oldValue, key: .timelineSourceTimeTicksEnabled, change: .sourceTimeTicks) { sourceTimeTicks = oldValue }
        }
    }
    @Published var largeThumbnails = false {
        didSet {
            if !save(largeThumbnails, replacing: oldValue, key: .timelineLargePreviewsEnabled, change: .largeThumbnails) { largeThumbnails = oldValue }
        }
    }
    @Published var maxBlip = AudioWaveform.defaultMaxBlip {
        didSet { if !save(maxBlip, replacing: oldValue, key: .silenceMaxBlipSeconds, change: .maxBlip) { maxBlip = oldValue } }
    }
    @Published var minimumPause = 1.5 {
        didSet {
            if !save(minimumPause, replacing: oldValue, key: .silenceMinPauseSeconds, change: .minimumPause) { minimumPause = oldValue }
        }
    }
    @Published var padding = 0.2 {
        didSet { if !save(padding, replacing: oldValue, key: .silencePaddingPerSideSeconds, change: .padding) { padding = oldValue } }
    }
    @Published var volume: Float = 1 {
        didSet { if !save(volume, replacing: oldValue, key: .playbackPreviewVolumeFraction, change: .volume) { volume = oldValue } }
    }
    @Published var isMuted = false {
        didSet { if !save(isMuted, replacing: oldValue, key: .playbackPreviewMuted, change: .isMuted) { isMuted = oldValue } }
    }
    @Published var scrubSoundEnabled = true {
        didSet {
            if !save(scrubSoundEnabled, replacing: oldValue, key: .playbackScrubAudioEnabled, change: .scrubSoundEnabled) { scrubSoundEnabled = oldValue }
        }
    }
    @Published var jpegPreset = JPEGPreset.review {
        didSet {
            if !save(jpegPreset, replacing: oldValue, key: .exportJpegDefaultPreset, stored: jpegPreset.rawValue, change: .jpegPreset) { jpegPreset = oldValue }
        }
    }

    // MARK: General

    @Published var multipleRecordingsAction = MultipleRecordingsAction.ask {
        didSet {
            if !save(multipleRecordingsAction, replacing: oldValue, key: .openMultipleRecordingsDefaultAction,
                 stored: multipleRecordingsAction.rawValue, change: .multipleRecordingsAction) { multipleRecordingsAction = oldValue }
        }
    }
    @Published var recentFilesLimit = 10 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(recentFilesLimit, Self.recentFilesRange) { normalize { recentFilesLimit = fixed } }
            if !save(recentFilesLimit, replacing: oldValue, key: .recentFilesMaxCount, change: .recentFilesLimit) {
                recentFilesLimit = oldValue
            } else if recentFilesLimit != oldValue {
                // Lowering the limit trims File → Open Recent. While loading, only the shown list is trimmed.
                recentFiles.applyLimit(recentFilesLimit, persisting: isLoaded)
            }
        }
    }
    @Published var offersDraftRecovery = false {
        didSet {
            if !save(offersDraftRecovery, replacing: oldValue, key: .draftRecoveryPromptEnabled, change: .offersDraftRecovery) { offersDraftRecovery = oldValue }
        }
    }
    @Published var confirmsSceneRescan = true {
        didSet {
            if !save(confirmsSceneRescan, replacing: oldValue, key: .sceneRescanConfirmationEnabled, change: .confirmsSceneRescan) { confirmsSceneRescan = oldValue }
        }
    }
    @Published var showsProjectExportMessage = true {
        didSet {
            if !save(showsProjectExportMessage, replacing: oldValue, key: .projectExportCompletionMessageEnabled, change: .showsProjectExportMessage) { showsProjectExportMessage = oldValue }
        }
    }

    // MARK: Editing

    @Published var showsCutSections = true {
        didSet {
            if !save(showsCutSections, replacing: oldValue, key: .timelineCutSectionsDefaultEnabled, change: .showsCutSections) { showsCutSections = oldValue }
        }
    }
    /// Live: every open window docks its panel beside the timeline.
    @Published var fullHeightSidebar = false {
        didSet {
            if !save(fullHeightSidebar, replacing: oldValue, key: .workspaceFullHeightSidebarEnabled, change: .fullHeightSidebar) { fullHeightSidebar = oldValue }
        }
    }
    /// Live. Each window clamps it to its own space with `MulticamTimeline.trackWidth`.
    @Published var trackLabelWidth = 172.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(trackLabelWidth, Self.trackLabelWidthRange, oldValue) { normalize { trackLabelWidth = fixed } }
            if !save(trackLabelWidth, replacing: oldValue, key: .multicamTrackLabelWidthPoints, change: .trackLabelWidth) { trackLabelWidth = oldValue }
        }
    }
    @Published var stillDuration = 2.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(stillDuration, Self.stillDurationRange, oldValue) { normalize { stillDuration = fixed } }
            if !save(stillDuration, replacing: oldValue, key: .stillPlacementDefaultDurationSeconds, change: .stillDuration) { stillDuration = oldValue }
        }
    }
    @Published var gapDuration = 2.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(gapDuration, Self.stillDurationRange, oldValue) { normalize { gapDuration = fixed } }
            if !save(gapDuration, replacing: oldValue, key: .gapDefaultDurationSeconds, change: .gapDuration) { gapDuration = oldValue }
        }
    }
    /// `#RRGGBB`, upper case. Anything else keeps the previous color.
    @Published var gapColor = "#000000" {
        didSet {
            guard !isNormalizing else { return }
            let normalized = Self.hexColor(gapColor) ?? oldValue
            if normalized != gapColor { normalize { gapColor = normalized } }
            if !save(gapColor, replacing: oldValue, key: .gapDefaultColor, change: .gapColor) { gapColor = oldValue }
        }
    }
    /// Even pixel counts, rounded down.
    @Published var stillTimelineWidth = 1920 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixedPixels(stillTimelineWidth) { normalize { stillTimelineWidth = fixed } }
            if !save(stillTimelineWidth, replacing: oldValue, key: .stillTimelineDefaultWidthPixels, change: .stillTimelineWidth) { stillTimelineWidth = oldValue }
        }
    }
    @Published var stillTimelineHeight = 1080 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixedPixels(stillTimelineHeight) { normalize { stillTimelineHeight = fixed } }
            if !save(stillTimelineHeight, replacing: oldValue, key: .stillTimelineDefaultHeightPixels, change: .stillTimelineHeight) { stillTimelineHeight = oldValue }
        }
    }
    @Published var stillTimelineFrameRate = 30.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(stillTimelineFrameRate, Self.stillTimelineFrameRateRange, oldValue) { normalize { stillTimelineFrameRate = fixed } }
            if !save(stillTimelineFrameRate, replacing: oldValue, key: .stillTimelineDefaultFrameRate, change: .stillTimelineFrameRate) { stillTimelineFrameRate = oldValue }
        }
    }
    /// H.264, HEVC or ProRes. JPEG keeps the previous codec.
    @Published var stillTimelineCodec = ReencodeCodec.h264 {
        didSet {
            guard !isNormalizing else { return }
            if !Self.stillTimelineCodecs.contains(stillTimelineCodec) { normalize { stillTimelineCodec = oldValue } }
            if !save(stillTimelineCodec, replacing: oldValue, key: .stillTimelineDefaultCodec, stored: stillTimelineCodec.rawValue,
                 change: .stillTimelineCodec) { stillTimelineCodec = oldValue }
        }
    }
    @Published var timeDisplay = TimelineTimeDisplay.milliseconds {
        didSet {
            if !save(timeDisplay, replacing: oldValue, key: .timelineTimeDisplay, stored: timeDisplay.rawValue, change: .timeDisplay) { timeDisplay = oldValue }
        }
    }

    // MARK: Playback & Monitors

    @Published var playbackSpeed = PlaybackSpeed.normal {
        didSet {
            if !save(playbackSpeed, replacing: oldValue, key: .playbackDefaultSpeed, stored: playbackSpeed.rawValue, change: .playbackSpeed) { playbackSpeed = oldValue }
        }
    }
    @Published var cutPreviewPreroll = 1.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(cutPreviewPreroll, Self.cutPreviewRange, oldValue) { normalize { cutPreviewPreroll = fixed } }
            if !save(cutPreviewPreroll, replacing: oldValue, key: .playbackCutPreviewPrerollSeconds, change: .cutPreviewPreroll) { cutPreviewPreroll = oldValue }
        }
    }
    @Published var cutPreviewPostroll = 1.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(cutPreviewPostroll, Self.cutPreviewRange, oldValue) { normalize { cutPreviewPostroll = fixed } }
            if !save(cutPreviewPostroll, replacing: oldValue, key: .playbackCutPreviewPostrollSeconds, change: .cutPreviewPostroll) { cutPreviewPostroll = oldValue }
        }
    }
    /// Live, on every picture surface except the Video Monitor, sheet previews included.
    @Published var viewerForceSDR = false {
        didSet {
            if !save(viewerForceSDR, replacing: oldValue, key: .playbackViewerForceSdrEnabled, change: .viewerForceSDR) { viewerForceSDR = oldValue }
        }
    }
    @Published var monitorForceSDR = false {
        didSet {
            if !save(monitorForceSDR, replacing: oldValue, key: .playbackMonitorForceSdrEnabled, change: .monitorForceSDR) { monitorForceSDR = oldValue }
        }
    }
    @Published var monitorCleanFeed = false {
        didSet {
            if !save(monitorCleanFeed, replacing: oldValue, key: .playbackMonitorCleanFeedEnabled, change: .monitorCleanFeed) { monitorCleanFeed = oldValue }
        }
    }
    @Published var monitorPlacement = VideoMonitorPlacement.otherDisplay {
        didSet {
            if !save(monitorPlacement, replacing: oldValue, key: .playbackMonitorPlacement, stored: monitorPlacement.rawValue, change: .monitorPlacement) { monitorPlacement = oldValue }
        }
    }
    /// The Video Monitor's last window frame in screen coordinates, for the Last position placement.
    @Published var monitorLastFrame: CGRect? {
        didSet {
            guard !isNormalizing else { return }
            if let frame = monitorLastFrame, !Self.usableFrame(frame) { normalize { monitorLastFrame = oldValue } }
            guard monitorLastFrame != oldValue else { return }
            if let frame = monitorLastFrame {
                defaults?.set(NSStringFromRect(frame), forKey: LocalKey.playbackMonitorLastFrame.rawValue)
            } else {
                defaults?.removeObject(forKey: LocalKey.playbackMonitorLastFrame.rawValue)
            }
            changes.send(.monitorLastFrame)
        }
    }

    // MARK: Media & Analysis

    @Published var autoScanScenes = false {
        didSet {
            if !save(autoScanScenes, replacing: oldValue, key: .analysisSceneAutoScanEnabled, change: .autoScanScenes) { autoScanScenes = oldValue }
        }
    }
    @Published var autoScanSilence = false {
        didSet {
            if !save(autoScanSilence, replacing: oldValue, key: .analysisSilenceAutoScanEnabled, change: .autoScanSilence) { autoScanSilence = oldValue }
        }
    }
    @Published var tilesScanLayout = TilesScanLayout.videoCall {
        didSet {
            if !save(tilesScanLayout, replacing: oldValue, key: .tilesScanDefaultLayout, stored: tilesScanLayout.rawValue, change: .tilesScanLayout) { tilesScanLayout = oldValue }
        }
    }
    @Published var tilesScanColumns = 2 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(tilesScanColumns, Self.tilesGridRange) { normalize { tilesScanColumns = fixed } }
            if !save(tilesScanColumns, replacing: oldValue, key: .tilesScanDefaultGridColumns, change: .tilesScanColumns) { tilesScanColumns = oldValue }
        }
    }
    @Published var tilesScanRows = 2 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(tilesScanRows, Self.tilesGridRange) { normalize { tilesScanRows = fixed } }
            if !save(tilesScanRows, replacing: oldValue, key: .tilesScanDefaultGridRows, change: .tilesScanRows) { tilesScanRows = oldValue }
        }
    }
    @Published var tilesScanDetail = ParticipantSampling.adaptive {
        didSet {
            if !save(tilesScanDetail, replacing: oldValue, key: .tilesScanDefaultDetail, stored: tilesScanDetail.rawValue, change: .tilesScanDetail) { tilesScanDetail = oldValue }
        }
    }
    @Published var dialogueMinimumHold = 1.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(dialogueMinimumHold, Self.dialogueHoldRange, oldValue) { normalize { dialogueMinimumHold = fixed } }
            if !save(dialogueMinimumHold, replacing: oldValue, key: .tilesDialogueDefaultMinHoldSeconds, change: .dialogueMinimumHold) { dialogueMinimumHold = oldValue }
        }
    }
    @Published var dialogueOverlap = ParticipantDialogueOptions.Overlap.hold {
        didSet {
            if !save(dialogueOverlap, replacing: oldValue, key: .tilesDialogueDefaultOverlapPolicy, stored: dialogueOverlap.rawValue, change: .dialogueOverlap) { dialogueOverlap = oldValue }
        }
    }
    @Published var dialogueOffscreen = ParticipantDialogueOptions.Offscreen.hold {
        didSet {
            if !save(dialogueOffscreen, replacing: oldValue, key: .tilesDialogueDefaultOffscreenPolicy, stored: dialogueOffscreen.rawValue,
                 change: .dialogueOffscreen) { dialogueOffscreen = oldValue }
        }
    }

    // MARK: Transcripts

    /// An engine name. Empty is Automatic: Qwen3, then the first available engine.
    @Published var transcriptEngine = "" {
        didSet {
            if !save(transcriptEngine, replacing: oldValue, key: .transcriptDefaultEngine, change: .transcriptEngine) { transcriptEngine = oldValue }
        }
    }
    @Published var identifiesSpeakers = false {
        didSet {
            if !save(identifiesSpeakers, replacing: oldValue, key: .transcriptDefaultSpeakerIdentificationEnabled, change: .identifiesSpeakers) { identifiesSpeakers = oldValue }
        }
    }
    @Published var downloadsModels = false {
        didSet {
            if !save(downloadsModels, replacing: oldValue, key: .transcriptDefaultModelDownloadEnabled, change: .downloadsModels) { downloadsModels = oldValue }
        }
    }
    @Published var followsPlayback = true {
        didSet {
            if !save(followsPlayback, replacing: oldValue, key: .transcriptFollowPlaybackDefaultEnabled, change: .followsPlayback) { followsPlayback = oldValue }
        }
    }
    @Published var readerTextSize = 14.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(readerTextSize, Self.readerTextSizeRange, oldValue) { normalize { readerTextSize = fixed } }
            if !save(readerTextSize, replacing: oldValue, key: .transcriptReaderTextSizePoints, change: .readerTextSize) { readerTextSize = oldValue }
        }
    }
    @Published var boundaryPolicy = TranscriptEditRequest.BoundaryPolicy.nearestFrame {
        didSet {
            if !save(boundaryPolicy, replacing: oldValue, key: .transcriptEditDefaultBoundaryPolicy, stored: boundaryPolicy.rawValue, change: .boundaryPolicy) { boundaryPolicy = oldValue }
        }
    }
    @Published var retainedPause = 0.2 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(retainedPause, Self.retainedPauseRange, oldValue) { normalize { retainedPause = fixed } }
            if !save(retainedPause, replacing: oldValue, key: .transcriptTightenDefaultRetainedPauseSeconds, change: .retainedPause) { retainedPause = oldValue }
        }
    }
    /// One string, terms separated by commas.
    @Published var fillerTerms = "" {
        didSet {
            if !save(fillerTerms, replacing: oldValue, key: .transcriptDefaultFillerTerms, change: .fillerTerms) { fillerTerms = oldValue }
        }
    }
    @Published var transcriptExportFormat = TranscriptFormat.json {
        didSet {
            if !save(transcriptExportFormat, replacing: oldValue, key: .transcriptExportDefaultFormat, stored: transcriptExportFormat.rawValue,
                 change: .transcriptExportFormat) { transcriptExportFormat = oldValue }
        }
    }
    @Published var captionLineCharacters = 42 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(captionLineCharacters, Self.captionLineCharacterRange) { normalize { captionLineCharacters = fixed } }
            if !save(captionLineCharacters, replacing: oldValue, key: .transcriptCaptionMaxLineCharacters, change: .captionLineCharacters) { captionLineCharacters = oldValue }
        }
    }
    @Published var captionLines = 2 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(captionLines, Self.captionLineRange) { normalize { captionLines = fixed } }
            if !save(captionLines, replacing: oldValue, key: .transcriptCaptionMaxLines, change: .captionLines) { captionLines = oldValue }
        }
    }
    @Published var captionCueSeconds = 6.0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(captionCueSeconds, Self.captionCueRange, oldValue) { normalize { captionCueSeconds = fixed } }
            if !save(captionCueSeconds, replacing: oldValue, key: .transcriptCaptionMaxCueSeconds, change: .captionCueSeconds) { captionCueSeconds = oldValue }
        }
    }
    @Published var captionSpeakerLabels = true {
        didSet {
            if !save(captionSpeakerLabels, replacing: oldValue, key: .transcriptCaptionSpeakerLabelsEnabled, change: .captionSpeakerLabels) { captionSpeakerLabels = oldValue }
        }
    }
    /// The Transcriberrr helper chosen in Settings. Empty is Automatic. Desktop jobs only; the CLI keeps its environment variable.
    @Published var transcriptHelperPath = "" {
        didSet { save(transcriptHelperPath, replacing: oldValue, key: LocalKey.transcriptHelperPath.rawValue, change: .transcriptHelperPath) }
    }

    // MARK: Export

    @Published var reencodeCodec = ExportRules.defaultCodec {
        didSet {
            guard !isNormalizing else { return }
            if !Self.reencodeCodecs.contains(reencodeCodec) { normalize { reencodeCodec = oldValue } }
            if !save(reencodeCodec, replacing: oldValue, key: .exportReencodeDefaultCodec, stored: reencodeCodec.rawValue, change: .reencodeCodec) { reencodeCodec = oldValue }
        }
    }
    /// The H.264 and HEVC quality. A ProRes quality keeps the previous value.
    @Published var reencodeQuality = ExportRules.defaultQuality(.h264) {
        didSet {
            guard !isNormalizing else { return }
            if !Self.reencodeQualities.contains(reencodeQuality) { normalize { reencodeQuality = oldValue } }
            if !save(reencodeQuality, replacing: oldValue, key: .exportReencodeDefaultQuality, stored: reencodeQuality.rawValue, change: .reencodeQuality) { reencodeQuality = oldValue }
        }
    }
    @Published var proresQuality = ExportRules.defaultQuality(.prores) {
        didSet {
            guard !isNormalizing else { return }
            if !Self.proresQualities.contains(proresQuality) { normalize { proresQuality = oldValue } }
            if !save(proresQuality, replacing: oldValue, key: .exportProresDefaultQuality, stored: proresQuality.rawValue, change: .proresQuality) { proresQuality = oldValue }
        }
    }
    @Published var reencodeContainer = ExportContainerChoice.automatic {
        didSet {
            if !save(reencodeContainer, replacing: oldValue, key: .exportReencodeDefaultContainer, stored: reencodeContainer.rawValue,
                 change: .reencodeContainer) { reencodeContainer = oldValue }
        }
    }
    @Published var multicamAudioLayout = MulticamAudioOutput.separateTracks {
        didSet {
            if !save(multicamAudioLayout, replacing: oldValue, key: .exportMulticamDefaultAudioLayout, stored: multicamAudioLayout.rawValue,
                 change: .multicamAudioLayout) { multicamAudioLayout = oldValue }
        }
    }
    @Published var savesExportResult = false {
        didSet {
            if !save(savesExportResult, replacing: oldValue, key: .exportResultJsonDefaultEnabled, change: .savesExportResult) { savesExportResult = oldValue }
        }
    }
    @Published var opensResolveTimeline = true {
        didSet {
            if !save(opensResolveTimeline, replacing: oldValue, key: .resolveSendOpenTimelineDefaultEnabled, change: .opensResolveTimeline) { opensResolveTimeline = oldValue }
        }
    }
    @Published var exportStartFolder = ExportStartFolderMode.automatic {
        didSet {
            if !save(exportStartFolder, replacing: oldValue, key: .exportStartFolderMode, stored: exportStartFolder.rawValue, change: .exportStartFolder) { exportStartFolder = oldValue }
        }
    }
    /// The folder for the Chosen folder mode. Empty until one is chosen.
    @Published var exportStartFolderPath = "" {
        didSet { save(exportStartFolderPath, replacing: oldValue, key: LocalKey.exportStartFolderPath.rawValue, change: .exportStartFolderPath) }
    }
    @Published var revealsFinishedExport = false {
        didSet {
            if !save(revealsFinishedExport, replacing: oldValue, key: .exportFinishedRevealEnabled, change: .revealsFinishedExport) { revealsFinishedExport = oldValue }
        }
    }
    /// Only the value. Asking for notification permission belongs to the Settings control, never to an agent or a launch argument.
    @Published var notifiesFinishedExport = false {
        didSet {
            if !save(notifiesFinishedExport, replacing: oldValue, key: .exportFinishedNotificationEnabled, change: .notifiesFinishedExport) { notifiesFinishedExport = oldValue }
        }
    }
    @Published var playsFinishedExportSound = false {
        didSet {
            if !save(playsFinishedExportSound, replacing: oldValue, key: .exportFinishedSoundEnabled, change: .playsFinishedExportSound) { playsFinishedExportSound = oldValue }
        }
    }

    // MARK: Storage

    /// The managed shared cache folder's limit in bytes. 0 is no limit.
    @Published var sharedCacheLimitBytes = 0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(sharedCacheLimitBytes, Self.sharedCacheLimitRange) { normalize { sharedCacheLimitBytes = fixed } }
            if !save(sharedCacheLimitBytes, replacing: oldValue, key: .analysisSharedCacheMaxBytes, change: .sharedCacheLimitBytes) { sharedCacheLimitBytes = oldValue }
        }
    }
    /// Days before an untitled draft moves to the Trash. 0 is never.
    @Published var draftRetentionDays = 0 {
        didSet {
            guard !isNormalizing else { return }
            if let fixed = Self.fixed(draftRetentionDays, Self.draftRetentionRange) { normalize { draftRetentionDays = fixed } }
            if !save(draftRetentionDays, replacing: oldValue, key: .draftRetentionDays, change: .draftRetentionDays) { draftRetentionDays = oldValue }
        }
    }

    // MARK: Automation

    /// Let agents change settings. Agent routes ask `checkAgentWrite()`; reads always work.
    @Published var agentsChangeSettings = true {
        didSet {
            if !save(agentsChangeSettings, replacing: oldValue, key: .automationPreferencesWriteEnabled, change: .agentsChangeSettings) { agentsChangeSettings = oldValue }
        }
    }
    /// Let agents replace existing project files when a call passes `replace_existing`.
    @Published var agentsReplaceFiles = true {
        didSet {
            if !save(agentsReplaceFiles, replacing: oldValue, key: .automationFileReplaceEnabled, change: .agentsReplaceFiles) { agentsReplaceFiles = oldValue }
        }
    }

    // MARK: Other stored values

    @Published var settingsPage = SettingsPage.general {
        didSet { save(settingsPage, replacing: oldValue, key: LocalKey.settingsSelectedPage.rawValue, stored: settingsPage.rawValue, change: .settingsPage) }
    }
    @Published var projectMediaLastLocateFolder = "" {
        didSet {
            save(projectMediaLastLocateFolder, replacing: oldValue, key: LocalKey.projectMediaLastLocateFolder.rawValue,
                 change: .projectMediaLastLocateFolder)
        }
    }
    /// Encoded suggested cameras, keyed by transcript attachment. Owned by `TranscriptSuggestedCameras`.
    @Published var transcriptSuggestedAngles = Data() {
        didSet {
            save(transcriptSuggestedAngles, replacing: oldValue, key: LocalKey.transcriptSuggestedAngles.rawValue,
                 change: .transcriptSuggestedAngles)
        }
    }

    /// The warnings an alert's “Don't ask again” silenced, so Reset All Warnings undoes only what an alert changed.
    @Published private(set) var suppressedWarnings: Set<SuppressibleWarning> = [] {
        didSet {
            save(suppressedWarnings, replacing: oldValue, key: LocalKey.warningsSuppressed.rawValue,
                 stored: suppressedWarnings.map(\.rawValue).sorted(), change: .suppressedWarnings)
        }
    }

    /// `persistentDomain` names the domain `defaults` saves to. Draft retention and the cache limit remove files, so they
    /// are read from that domain alone, never from a launch argument. Without a name, `.standard` uses the bundle
    /// identifier; for any other store, either key that a launch argument supplies keeps its factory value.
    init(defaults: UserDefaults? = nil, persistentDomain: String? = nil) {
        let storedRecentLimit = defaults.flatMap { Self.integer($0.object(forKey: Key.recentFilesMaxCount.rawValue)) }
            .flatMap { Self.recentFilesRange.contains($0) ? $0 : nil }
        recentFiles = RecentFiles(defaults: defaults, limit: storedRecentLimit ?? 10)
        guard let defaults else {
            isLoaded = true
            return
        }
        if let storedLimit = defaults.object(forKey: Key.historyMaxSteps.rawValue),
           CFGetTypeID(storedLimit as CFTypeRef) != CFBooleanGetTypeID(),
           let steps = Self.number(storedLimit), steps.rounded() == steps {
            storedHistoryLimit = Int(min(Double(Self.historyStepRange.upperBound), max(0, steps)))
            let argumentLimit = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[Key.historyMaxSteps.rawValue]
            let registeredLimit = defaults.volatileDomain(forName: UserDefaults.registrationDomain)[Key.historyMaxSteps.rawValue]
            if steps != Double(historyLimit), argumentLimit == nil,
               registeredLimit.flatMap(Self.number) != steps {
                defaults.set(historyLimit, forKey: Key.historyMaxSteps.rawValue)
            }
        }
        localMCPEnabled = Self.flag(defaults.object(forKey: Key.automationLocalMcpEnabled.rawValue)) ?? false
        automaticallyRefreshMedia = Self.flag(defaults.object(forKey: Key.mediaAutoRefreshEnabled.rawValue)) ?? false
        useAnalysisSidecars = Self.flag(defaults.object(forKey: Key.analysisSidecarReuseEnabled.rawValue)) ?? true
        warnBeforeLoweringExportTier = Self.flag(defaults.object(forKey: Key.exportTierDowngradeWarningEnabled.rawValue)) ?? true
        sourceTimeTicks = Self.flag(defaults.object(forKey: Key.timelineSourceTimeTicksEnabled.rawValue)) ?? false
        largeThumbnails = Self.flag(defaults.object(forKey: Key.timelineLargePreviewsEnabled.rawValue)) ?? false
        snapTarget = defaults.string(forKey: Key.timelineSnapTarget.rawValue).flatMap(TimelineSnapTarget.init(rawValue:))
            ?? .off
        defaultExportMode = defaults.string(forKey: Key.exportMovieDefaultMode.rawValue).flatMap(ExportMode.init(rawValue:)) ?? Self.factoryExportMode
        jpegPreset = defaults.string(forKey: Key.exportJpegDefaultPreset.rawValue).flatMap(JPEGPreset.init(rawValue:)) ?? .review
        if let blip = Self.number(defaults.object(forKey: Key.silenceMaxBlipSeconds.rawValue)), (0...1).contains(blip) { maxBlip = blip }
        if let minimum = Self.number(defaults.object(forKey: Key.silenceMinPauseSeconds.rawValue)),
           minimum >= 1.0 / Double(AudioWaveform.rate) {
            minimumPause = minimum
        }
        if let value = Self.number(defaults.object(forKey: Key.silencePaddingPerSideSeconds.rawValue)), value >= 0 {
            padding = value
        }
        if let gain = Self.number(defaults.object(forKey: Key.playbackPreviewVolumeFraction.rawValue)) {
            volume = Float(min(1, max(0, gain)))
        }
        isMuted = Self.flag(defaults.object(forKey: Key.playbackPreviewMuted.rawValue)) ?? false
        scrubSoundEnabled = Self.flag(defaults.object(forKey: Key.playbackScrubAudioEnabled.rawValue)) ?? true

        // Every later key keeps its factory value when the stored one is unreadable or out of range.
        func flag(_ key: Key) -> Bool? { Self.flag(defaults.object(forKey: key.rawValue)) }
        func number(_ key: Key, _ range: ClosedRange<Double>) -> Double? {
            Self.number(defaults.object(forKey: key.rawValue)).flatMap { range.contains($0) ? $0 : nil }
        }
        func integer(_ key: Key, _ range: ClosedRange<Int>) -> Int? {
            Self.integer(defaults.object(forKey: key.rawValue)).flatMap { range.contains($0) ? $0 : nil }
        }
        func choice<Value: RawRepresentable & Equatable>(_ key: String, _ allowed: [Value]) -> Value? where Value.RawValue == String {
            (defaults.object(forKey: key) as? String).flatMap(Value.init(rawValue:)).flatMap { allowed.contains($0) ? $0 : nil }
        }
        func option<Value: RawRepresentable & CaseIterable & Equatable>(_ key: Key, _: Value.Type) -> Value? where Value.RawValue == String {
            choice(key.rawValue, Array(Value.allCases))
        }
        func text(_ key: String) -> String? { defaults.object(forKey: key) as? String }
        // A launch argument such as `-draft_retention_days 1` would trash drafts or evict cutcaches at launch.
        // These keys come from the saved store only; registered defaults never name them.
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let domain = persistentDomain ?? (defaults === UserDefaults.standard ? Bundle.main.bundleIdentifier : nil)
        let persisted = domain.flatMap { defaults.persistentDomain(forName: $0) }
        func saved(_ key: Key, _ range: ClosedRange<Int>) -> Int? {
            let stored = arguments[key.rawValue] == nil ? defaults.object(forKey: key.rawValue) : persisted?[key.rawValue]
            return Self.integer(stored).flatMap { range.contains($0) ? $0 : nil }
        }

        multipleRecordingsAction = option(.openMultipleRecordingsDefaultAction, MultipleRecordingsAction.self) ?? .ask
        recentFilesLimit = integer(.recentFilesMaxCount, Self.recentFilesRange) ?? 10
        offersDraftRecovery = flag(.draftRecoveryPromptEnabled) ?? false
        confirmsSceneRescan = flag(.sceneRescanConfirmationEnabled) ?? true
        showsProjectExportMessage = flag(.projectExportCompletionMessageEnabled) ?? true
        showsCutSections = flag(.timelineCutSectionsDefaultEnabled) ?? true
        fullHeightSidebar = flag(.workspaceFullHeightSidebarEnabled) ?? false
        trackLabelWidth = number(.multicamTrackLabelWidthPoints, Self.trackLabelWidthRange) ?? 172
        stillDuration = number(.stillPlacementDefaultDurationSeconds, Self.stillDurationRange) ?? 2
        gapDuration = number(.gapDefaultDurationSeconds, Self.stillDurationRange) ?? 2
        gapColor = text(Key.gapDefaultColor.rawValue).flatMap(Self.hexColor) ?? "#000000"
        stillTimelineWidth = integer(.stillTimelineDefaultWidthPixels, Self.stillTimelinePixelRange).flatMap { $0 % 2 == 0 ? $0 : nil } ?? 1920
        stillTimelineHeight = integer(.stillTimelineDefaultHeightPixels, Self.stillTimelinePixelRange).flatMap { $0 % 2 == 0 ? $0 : nil } ?? 1080
        stillTimelineFrameRate = number(.stillTimelineDefaultFrameRate, Self.stillTimelineFrameRateRange) ?? 30
        stillTimelineCodec = choice(Key.stillTimelineDefaultCodec.rawValue, Self.stillTimelineCodecs) ?? .h264
        timeDisplay = option(.timelineTimeDisplay, TimelineTimeDisplay.self) ?? .milliseconds
        playbackSpeed = Self.number(defaults.object(forKey: Key.playbackDefaultSpeed.rawValue))
            .flatMap { PlaybackSpeed(rawValue: Float($0)) } ?? .normal
        cutPreviewPreroll = number(.playbackCutPreviewPrerollSeconds, Self.cutPreviewRange) ?? 1
        cutPreviewPostroll = number(.playbackCutPreviewPostrollSeconds, Self.cutPreviewRange) ?? 1
        viewerForceSDR = flag(.playbackViewerForceSdrEnabled) ?? false
        monitorForceSDR = flag(.playbackMonitorForceSdrEnabled) ?? false
        monitorCleanFeed = flag(.playbackMonitorCleanFeedEnabled) ?? false
        monitorPlacement = option(.playbackMonitorPlacement, VideoMonitorPlacement.self) ?? .otherDisplay
        monitorLastFrame = text(LocalKey.playbackMonitorLastFrame.rawValue).map(NSRectFromString).flatMap { Self.usableFrame($0) ? $0 : nil }
        autoScanScenes = flag(.analysisSceneAutoScanEnabled) ?? false
        autoScanSilence = flag(.analysisSilenceAutoScanEnabled) ?? false
        tilesScanLayout = option(.tilesScanDefaultLayout, TilesScanLayout.self) ?? .videoCall
        tilesScanColumns = integer(.tilesScanDefaultGridColumns, Self.tilesGridRange) ?? 2
        tilesScanRows = integer(.tilesScanDefaultGridRows, Self.tilesGridRange) ?? 2
        tilesScanDetail = choice(Key.tilesScanDefaultDetail.rawValue, Self.tilesScanDetails) ?? .adaptive
        dialogueMinimumHold = number(.tilesDialogueDefaultMinHoldSeconds, Self.dialogueHoldRange) ?? 1
        dialogueOverlap = option(.tilesDialogueDefaultOverlapPolicy, ParticipantDialogueOptions.Overlap.self) ?? .hold
        dialogueOffscreen = option(.tilesDialogueDefaultOffscreenPolicy, ParticipantDialogueOptions.Offscreen.self) ?? .hold
        transcriptEngine = text(Key.transcriptDefaultEngine.rawValue) ?? ""
        identifiesSpeakers = flag(.transcriptDefaultSpeakerIdentificationEnabled) ?? false
        downloadsModels = flag(.transcriptDefaultModelDownloadEnabled) ?? false
        followsPlayback = flag(.transcriptFollowPlaybackDefaultEnabled) ?? true
        readerTextSize = number(.transcriptReaderTextSizePoints, Self.readerTextSizeRange) ?? 14
        boundaryPolicy = choice(Key.transcriptEditDefaultBoundaryPolicy.rawValue, Self.boundaryPolicies) ?? .nearestFrame
        retainedPause = number(.transcriptTightenDefaultRetainedPauseSeconds, Self.retainedPauseRange) ?? 0.2
        fillerTerms = text(Key.transcriptDefaultFillerTerms.rawValue) ?? ""
        transcriptExportFormat = choice(Key.transcriptExportDefaultFormat.rawValue, Self.transcriptExportFormats) ?? .json
        captionLineCharacters = integer(.transcriptCaptionMaxLineCharacters, Self.captionLineCharacterRange) ?? 42
        captionLines = integer(.transcriptCaptionMaxLines, Self.captionLineRange) ?? 2
        captionCueSeconds = number(.transcriptCaptionMaxCueSeconds, Self.captionCueRange) ?? 6
        captionSpeakerLabels = flag(.transcriptCaptionSpeakerLabelsEnabled) ?? true
        transcriptHelperPath = text(LocalKey.transcriptHelperPath.rawValue) ?? ""
        reencodeCodec = choice(Key.exportReencodeDefaultCodec.rawValue, Self.reencodeCodecs) ?? ExportRules.defaultCodec
        reencodeQuality = choice(Key.exportReencodeDefaultQuality.rawValue, Self.reencodeQualities) ?? ExportRules.defaultQuality(.h264)
        proresQuality = choice(Key.exportProresDefaultQuality.rawValue, Self.proresQualities) ?? ExportRules.defaultQuality(.prores)
        reencodeContainer = option(.exportReencodeDefaultContainer, ExportContainerChoice.self) ?? .automatic
        multicamAudioLayout = option(.exportMulticamDefaultAudioLayout, MulticamAudioOutput.self) ?? .separateTracks
        savesExportResult = flag(.exportResultJsonDefaultEnabled) ?? false
        opensResolveTimeline = flag(.resolveSendOpenTimelineDefaultEnabled) ?? true
        exportStartFolder = option(.exportStartFolderMode, ExportStartFolderMode.self) ?? .automatic
        exportStartFolderPath = text(LocalKey.exportStartFolderPath.rawValue) ?? ""
        revealsFinishedExport = flag(.exportFinishedRevealEnabled) ?? false
        notifiesFinishedExport = flag(.exportFinishedNotificationEnabled) ?? false
        playsFinishedExportSound = flag(.exportFinishedSoundEnabled) ?? false
        sharedCacheLimitBytes = saved(.analysisSharedCacheMaxBytes, Self.sharedCacheLimitRange) ?? 0
        draftRetentionDays = saved(.draftRetentionDays, Self.draftRetentionRange) ?? 0
        agentsChangeSettings = flag(.automationPreferencesWriteEnabled) ?? true
        agentsReplaceFiles = flag(.automationFileReplaceEnabled) ?? true
        settingsPage = choice(LocalKey.settingsSelectedPage.rawValue, SettingsPage.allCases) ?? .general
        projectMediaLastLocateFolder = text(LocalKey.projectMediaLastLocateFolder.rawValue) ?? ""
        transcriptSuggestedAngles = defaults.object(forKey: LocalKey.transcriptSuggestedAngles.rawValue) as? Data ?? Data()
        let suppressed = (defaults.object(forKey: LocalKey.warningsSuppressed.rawValue) as? [String])?.map(SuppressibleWarning.init(rawValue:))
        suppressedWarnings = suppressed.flatMap { $0.contains(nil) ? nil : Set($0.compactMap { $0 }) } ?? []
        // Published properties invoke their observers during initialization. Enable persistence
        // after loading so argument and registration domains stay temporary.
        self.defaults = defaults
        isLoaded = true
    }

    // `defaults write` stores a string unless it is given a type, and an
    // unreadable value keeps the built-in default instead of becoming zero.
    private static func number(_ stored: Any?) -> Double? {
        let value = (stored as? NSNumber)?.doubleValue ?? (stored as? String).flatMap(Double.init)
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func integer(_ stored: Any?) -> Int? {
        guard let stored, CFGetTypeID(stored as CFTypeRef) != CFBooleanGetTypeID(), let value = number(stored),
              value.rounded() == value, abs(value) < 0x1p53 else { return nil }
        return Int(value)
    }

    private static func flag(_ stored: Any?) -> Bool? {
        if let number = stored as? NSNumber { return number.boolValue }
        switch (stored as? String)?.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }

    nonisolated static func hexColor(_ text: String) -> String? {
        text.wholeMatch(of: #/#[0-9A-Fa-f]{6}/#) == nil ? nil : text.uppercased()
    }

    private static func usableFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width >= 1 && frame.height >= 1
    }

    /// The bounded replacement for a value outside its range, or nil when it already fits.
    private static func fixed(_ value: Int, _ range: ClosedRange<Int>) -> Int? {
        range.contains(value) ? nil : min(range.upperBound, max(range.lowerBound, value))
    }

    private static func fixed(_ value: Double, _ range: ClosedRange<Double>, _ previous: Double) -> Double? {
        guard value.isFinite else { return previous }
        return range.contains(value) ? nil : min(range.upperBound, max(range.lowerBound, value))
    }

    private static func fixedPixels(_ value: Int) -> Int? {
        let bounded = min(stillTimelinePixelRange.upperBound, max(stillTimelinePixelRange.lowerBound, value))
        let even = bounded - bounded % 2
        return even == value ? nil : even
    }

    /// Assigns a normalized value from inside a property observer without running that observer again.
    private func normalize(_ assign: () -> Void) {
        isNormalizing = true
        defer { isNormalizing = false }
        assign()
    }

    func observeChanges(_ receiveValue: @escaping (Change) -> Void) -> AnyCancellable {
        changes.sink(receiveValue: receiveValue)
    }

    /// Ask before an agent changes a preference. Every MCP route that writes a setting calls this before it reads its arguments.
    func checkAgentWrite() throws {
        guard agentsChangeSettings else {
            throw MCPFailure("settings_write_disabled",
                             "Agents cannot change settings. Turn on Settings → Automation → Let agents change settings.")
        }
    }

    // MARK: Warnings

    /// Whether a warning still asks. The Finder alert asks only while its default action is Ask.
    func asks(_ warning: SuppressibleWarning) -> Bool {
        switch warning {
        case .openMultipleRecordings: multipleRecordingsAction == .ask
        case .sceneRescan: confirmsSceneRescan
        case .exportTierDowngrade: warnBeforeLoweringExportTier
        }
    }

    /// “Don't ask again”: turns the warning's Settings value off and records that an alert did it.
    /// The Finder alert remembers the choice it was answered with.
    func suppress(_ warning: SuppressibleWarning, choosing action: MultipleRecordingsAction = .ask) {
        switch warning {
        case .openMultipleRecordings:
            guard action != .ask else { return }
            multipleRecordingsAction = action
        case .sceneRescan: confirmsSceneRescan = false
        case .exportTierDowngrade: warnBeforeLoweringExportTier = false
        }
        suppressedWarnings.insert(warning)
    }

    var hasSuppressedWarnings: Bool {
        !suppressedWarnings.isEmpty || !confirmsSceneRescan || !warnBeforeLoweringExportTier || !showsProjectExportMessage
    }

    /// Reset All Warnings: the warning switches turn on again. A Finder default chosen in Settings stays;
    /// one chosen through the alert's “Don't ask again” goes back to Ask.
    func resetAllWarnings() {
        if suppressedWarnings.contains(.openMultipleRecordings) { multipleRecordingsAction = .ask }
        confirmsSceneRescan = true
        warnBeforeLoweringExportTier = true
        showsProjectExportMessage = true
        suppressedWarnings = []
    }

    // MARK: Restore Defaults

    /// A restorable row's factory value. Writes go through the property setter, so every observer runs.
    struct Factory {
        let key: String
        let page: SettingsPage
        let isCurrent: @MainActor (EditorPreferences) -> Bool
        let restore: @MainActor (EditorPreferences) -> Void

        init<Value: Equatable>(_ key: Key, _ page: SettingsPage, _ path: ReferenceWritableKeyPath<EditorPreferences, Value>, _ value: Value) {
            self.init(key.rawValue, page, path, value)
        }

        init<Value: Equatable>(_ key: String, _ page: SettingsPage, _ path: ReferenceWritableKeyPath<EditorPreferences, Value>, _ value: Value) {
            self.key = key
            self.page = page
            isCurrent = { $0[keyPath: path] == value }
            restore = { if $0[keyPath: path] != value { $0[keyPath: path] = value } }
        }
    }

    /// Every restorable value. The undo limit, the cutcache location, local MCP control and the
    /// two agent permission switches reach beyond Settings, so Restore Defaults leaves them alone.
    static let factories: [Factory] = [
        .init(.openMultipleRecordingsDefaultAction, .general, \.multipleRecordingsAction, .ask),
        .init(.recentFilesMaxCount, .general, \.recentFilesLimit, 10),
        .init(.draftRecoveryPromptEnabled, .general, \.offersDraftRecovery, false),
        .init(.exportTierDowngradeWarningEnabled, .general, \.warnBeforeLoweringExportTier, true),
        .init(.sceneRescanConfirmationEnabled, .general, \.confirmsSceneRescan, true),
        .init(.projectExportCompletionMessageEnabled, .general, \.showsProjectExportMessage, true),
        .init(LocalKey.warningsSuppressed.rawValue, .general, \.suppressedWarnings, []),

        .init(.timelineSnapTarget, .editing, \.snapTarget, .off),
        .init(.timelineSourceTimeTicksEnabled, .editing, \.sourceTimeTicks, false),
        .init(.timelineLargePreviewsEnabled, .editing, \.largeThumbnails, false),
        .init(.timelineCutSectionsDefaultEnabled, .editing, \.showsCutSections, true),
        .init(.workspaceFullHeightSidebarEnabled, .editing, \.fullHeightSidebar, false),
        .init(.multicamTrackLabelWidthPoints, .editing, \.trackLabelWidth, 172),
        .init(.stillPlacementDefaultDurationSeconds, .editing, \.stillDuration, 2),
        .init(.gapDefaultDurationSeconds, .editing, \.gapDuration, 2),
        .init(.gapDefaultColor, .editing, \.gapColor, "#000000"),
        .init(.stillTimelineDefaultWidthPixels, .editing, \.stillTimelineWidth, 1920),
        .init(.stillTimelineDefaultHeightPixels, .editing, \.stillTimelineHeight, 1080),
        .init(.stillTimelineDefaultFrameRate, .editing, \.stillTimelineFrameRate, 30),
        .init(.stillTimelineDefaultCodec, .editing, \.stillTimelineCodec, .h264),
        .init(.timelineTimeDisplay, .editing, \.timeDisplay, .milliseconds),

        .init(.playbackScrubAudioEnabled, .playback, \.scrubSoundEnabled, true),
        .init(.playbackPreviewMuted, .playback, \.isMuted, false),
        .init(.playbackPreviewVolumeFraction, .playback, \.volume, 1),
        .init(.playbackDefaultSpeed, .playback, \.playbackSpeed, .normal),
        .init(.playbackCutPreviewPrerollSeconds, .playback, \.cutPreviewPreroll, 1),
        .init(.playbackCutPreviewPostrollSeconds, .playback, \.cutPreviewPostroll, 1),
        .init(.playbackViewerForceSdrEnabled, .playback, \.viewerForceSDR, false),
        .init(.playbackMonitorForceSdrEnabled, .playback, \.monitorForceSDR, false),
        .init(.playbackMonitorCleanFeedEnabled, .playback, \.monitorCleanFeed, false),
        .init(.playbackMonitorPlacement, .playback, \.monitorPlacement, .otherDisplay),

        .init(.mediaAutoRefreshEnabled, .media, \.automaticallyRefreshMedia, false),
        .init(.analysisSceneAutoScanEnabled, .media, \.autoScanScenes, false),
        .init(.analysisSilenceAutoScanEnabled, .media, \.autoScanSilence, false),
        .init(.silenceMinPauseSeconds, .media, \.minimumPause, 1.5),
        .init(.silenceMaxBlipSeconds, .media, \.maxBlip, AudioWaveform.defaultMaxBlip),
        .init(.silencePaddingPerSideSeconds, .media, \.padding, 0.2),
        .init(.tilesScanDefaultLayout, .media, \.tilesScanLayout, .videoCall),
        .init(.tilesScanDefaultGridColumns, .media, \.tilesScanColumns, 2),
        .init(.tilesScanDefaultGridRows, .media, \.tilesScanRows, 2),
        .init(.tilesScanDefaultDetail, .media, \.tilesScanDetail, .adaptive),
        .init(.tilesDialogueDefaultMinHoldSeconds, .media, \.dialogueMinimumHold, 1),
        .init(.tilesDialogueDefaultOverlapPolicy, .media, \.dialogueOverlap, .hold),
        .init(.tilesDialogueDefaultOffscreenPolicy, .media, \.dialogueOffscreen, .hold),

        .init(LocalKey.transcriptHelperPath.rawValue, .transcripts, \.transcriptHelperPath, ""),
        .init(.transcriptDefaultEngine, .transcripts, \.transcriptEngine, ""),
        .init(.transcriptDefaultSpeakerIdentificationEnabled, .transcripts, \.identifiesSpeakers, false),
        .init(.transcriptDefaultModelDownloadEnabled, .transcripts, \.downloadsModels, false),
        .init(.transcriptFollowPlaybackDefaultEnabled, .transcripts, \.followsPlayback, true),
        .init(.transcriptReaderTextSizePoints, .transcripts, \.readerTextSize, 14),
        .init(.transcriptEditDefaultBoundaryPolicy, .transcripts, \.boundaryPolicy, .nearestFrame),
        .init(.transcriptTightenDefaultRetainedPauseSeconds, .transcripts, \.retainedPause, 0.2),
        .init(.transcriptDefaultFillerTerms, .transcripts, \.fillerTerms, ""),
        .init(.transcriptExportDefaultFormat, .transcripts, \.transcriptExportFormat, .json),
        .init(.transcriptCaptionMaxLineCharacters, .transcripts, \.captionLineCharacters, 42),
        .init(.transcriptCaptionMaxLines, .transcripts, \.captionLines, 2),
        .init(.transcriptCaptionMaxCueSeconds, .transcripts, \.captionCueSeconds, 6),
        .init(.transcriptCaptionSpeakerLabelsEnabled, .transcripts, \.captionSpeakerLabels, true),

        .init(.exportMovieDefaultMode, .export, \.defaultExportMode, factoryExportMode),
        .init(.exportJpegDefaultPreset, .export, \.jpegPreset, .review),
        .init(.exportReencodeDefaultCodec, .export, \.reencodeCodec, ExportRules.defaultCodec),
        .init(.exportReencodeDefaultQuality, .export, \.reencodeQuality, ExportRules.defaultQuality(.h264)),
        .init(.exportProresDefaultQuality, .export, \.proresQuality, ExportRules.defaultQuality(.prores)),
        .init(.exportReencodeDefaultContainer, .export, \.reencodeContainer, .automatic),
        .init(.exportMulticamDefaultAudioLayout, .export, \.multicamAudioLayout, .separateTracks),
        .init(.exportResultJsonDefaultEnabled, .export, \.savesExportResult, false),
        .init(.resolveSendOpenTimelineDefaultEnabled, .export, \.opensResolveTimeline, true),
        .init(.exportStartFolderMode, .export, \.exportStartFolder, .automatic),
        .init(LocalKey.exportStartFolderPath.rawValue, .export, \.exportStartFolderPath, ""),
        .init(.exportFinishedRevealEnabled, .export, \.revealsFinishedExport, false),
        .init(.exportFinishedNotificationEnabled, .export, \.notifiesFinishedExport, false),
        .init(.exportFinishedSoundEnabled, .export, \.playsFinishedExportSound, false),

        .init(.analysisSidecarReuseEnabled, .storage, \.useAnalysisSidecars, true),
        .init(.analysisSharedCacheMaxBytes, .storage, \.sharedCacheLimitBytes, 0),
        .init(.draftRetentionDays, .storage, \.draftRetentionDays, 0)
    ]

    /// Whether every restorable value on a page already has its factory value.
    func hasFactoryValues(on page: SettingsPage) -> Bool {
        Self.factories.allSatisfy { $0.page != page || $0.isCurrent(self) }
    }

    /// Restore Defaults for one page. A value supplied as a launch argument applies again at the next launch.
    func restoreDefaults(on page: SettingsPage) {
        for factory in Self.factories where factory.page == page { factory.restore(self) }
    }

    /// The one write path for a schedule key. An agent's write is refused here when Let agents change settings is off,
    /// and a read-only key is never agent-writable: nothing is stored, no change is sent and the caller restores the old value.
    @discardableResult
    private func save<Value: Equatable>(_ value: Value, replacing oldValue: Value,
                                        key: Key, stored: Any? = nil, change: Change?) -> Bool {
        guard value != oldValue else { return true }
        // `@Published` runs the observer again for the caller's restoring assignment; that write stores nothing.
        if isRestoringRefusedWrite {
            isRestoringRefusedWrite = false
            return true
        }
        guard !refusesAgentWrite(key) else {
            isRestoringRefusedWrite = true
            return false
        }
        save(value, replacing: oldValue, key: key.rawValue, stored: stored, change: change)
        return true
    }

    private func save<Value: Equatable>(_ value: Value, replacing oldValue: Value,
                                        key: String, stored: Any? = nil, change: Change?) {
        guard value != oldValue else { return }
        defaults?.set(stored ?? value, forKey: key)
        if let change { changes.send(change) }
    }

    /// Whether a write to `key` comes from an agent request that may not make it. Records the refusal on the request.
    /// User writes, and writes while loading, are never refused.
    private func refusesAgentWrite(_ key: Key) -> Bool {
        guard isLoaded, let request = AgentOrigin.request else { return false }
        guard Key.agentReadOnly.contains(key) || !agentsChangeSettings else { return false }
        request.refuse(key, readOnly: Key.agentReadOnly.contains(key) && agentsChangeSettings)
        return true
    }
}
