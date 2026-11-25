import MPCutCore
import SwiftUI

/// One Settings control. The same definition labels the control, names it for accessibility and answers search.
struct SettingsRow: Identifiable, Hashable {
    let id: String
    let page: SettingsPage
    let title: String
    let keywords: [String]

    init(_ id: String, _ page: SettingsPage, _ title: String, keywords: [String] = []) {
        self.id = id
        self.page = page
        self.title = title
        self.keywords = keywords
    }

    /// Every word of the query appears in the title, the page or a keyword.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return false }
        let text = ([title, page.title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    static func search(_ query: String) -> [SettingsRow] { all.filter { $0.matches(query) } }
}

extension SettingsRow {
    // General
    static let multipleRecordings = SettingsRow("settings.general.multiple-recordings", .general,
        "Opening several recordings from Finder", keywords: ["join", "multicam", "ask", "open", "files"])
    static let historyLimit = SettingsRow("settings.general.history-limit", .general,
        "Maximum undo and redo steps", keywords: ["undo", "redo", "history", "limit"])
    static let recentItems = SettingsRow("settings.general.recent-items", .general, "Recent items",
        keywords: ["open recent", "files", "menu"])
    static let draftRecovery = SettingsRow("settings.general.draft-recovery", .general,
        "Offer to recover untitled projects at launch", keywords: ["drafts", "autosave", "unsaved"])
    static let tierWarning = SettingsRow("settings.general.tier-warning", .general, TierPrompt.settingTitle,
        keywords: ["warnings", "export tier", "lossless", "alert"])
    static let rescanConfirmation = SettingsRow("settings.general.rescan-confirmation", .general,
        "Confirm before scanning scenes again", keywords: ["warnings", "scene", "rescan", "alert"])
    static let exportMessage = SettingsRow("settings.general.export-message", .general,
        "Show “Exported …” after a project export with no warnings", keywords: ["warnings", "interchange", "message"])
    static let resetWarnings = SettingsRow("settings.general.reset-warnings", .general, "Reset All Warnings",
        keywords: ["don't ask again", "alerts", "suppressed"])

    // Editing
    static let snapTarget = SettingsRow("settings.editing.snap-target", .editing, "Snap to",
        keywords: ["timeline", "keyframes", "scenes", "silence", "snapping"])
    static let sourceTicks = SettingsRow("settings.editing.source-ticks", .editing, "Show source time ticks inside clips",
        keywords: ["timeline", "ruler", "source time"])
    static let largePreviews = SettingsRow("settings.editing.large-previews", .editing, "Enlarge thumbnails and waveforms",
        keywords: ["timeline", "filmstrip"])
    static let cutSections = SettingsRow("settings.editing.cut-sections", .editing, "Show cut sections in new windows",
        keywords: ["timeline", "removed"])
    static let timeDisplay = SettingsRow("settings.editing.time-display", .editing, "Time display",
        keywords: ["timecode", "frames", "milliseconds", "clock"])
    static let panelPosition = SettingsRow("settings.editing.panel-position", .editing, "Panel position",
        keywords: ["full height", "sidebar", "transcript", "tiles", "dock", "layout"])
    static let trackLabelWidth = SettingsRow("settings.editing.track-label-width", .editing, "Multicam track label width",
        keywords: ["multicam", "names", "column", "points"])
    static let stillDuration = SettingsRow("settings.editing.still-duration", .editing, "Inserted still duration",
        keywords: ["stills", "picture", "seconds"])
    static let gapDuration = SettingsRow("settings.editing.gap-duration", .editing, "Color gap and Space Clips duration",
        keywords: ["gap", "space clips", "seconds"])
    static let gapColor = SettingsRow("settings.editing.gap-color", .editing, "Gap color", keywords: ["gap", "black", "color well"])
    static let stillTimelineWidth = SettingsRow("settings.editing.still-timeline-width", .editing, "Width",
        keywords: ["new stills timeline", "size", "resolution", "pixels"])
    static let stillTimelineHeight = SettingsRow("settings.editing.still-timeline-height", .editing, "Height",
        keywords: ["new stills timeline", "size", "resolution", "pixels"])
    static let stillTimelineFrameRate = SettingsRow("settings.editing.still-timeline-frame-rate", .editing, "Frame rate",
        keywords: ["new stills timeline", "fps", "cadence"])
    static let stillTimelineCodec = SettingsRow("settings.editing.still-timeline-codec", .editing, "Codec",
        keywords: ["new stills timeline", "h.264", "hevc", "prores"])

    // Playback & Monitors
    static let scrubAudio = SettingsRow("settings.playback.scrub-audio", .playback, "Play audio while scrubbing", keywords: ["sound"])
    static let muted = SettingsRow("settings.playback.muted", .playback, "Mute preview audio", keywords: ["sound", "silent"])
    static let volume = SettingsRow("settings.playback.volume", .playback, "Preview volume", keywords: ["sound", "loudness"])
    static let playbackSpeed = SettingsRow("settings.playback.speed", .playback, "Starting playback speed",
        keywords: ["rate", "fast", "slow"])
    static let preroll = SettingsRow("settings.playback.preroll", .playback, "Seconds before a cut",
        keywords: ["play around a cut", "pre-roll", "audition", "join"])
    static let postroll = SettingsRow("settings.playback.postroll", .playback, "Seconds after a cut",
        keywords: ["play around a cut", "post-roll", "audition", "join"])
    static let viewerSDR = SettingsRow("settings.playback.viewer-sdr", .playback, "Editor viewer",
        keywords: ["hdr", "force sdr", "tone map", "display", "preview"])
    static let monitorSDR = SettingsRow("settings.playback.monitor-sdr", .playback, "Video Monitor",
        keywords: ["hdr", "force sdr", "tone map", "display", "external"])
    static let cleanFeed = SettingsRow("settings.playback.clean-feed", .playback, "Clean feed on the Video Monitor",
        keywords: ["overlay", "badge", "title bar"])
    static let monitorPlacement = SettingsRow("settings.playback.monitor-placement", .playback, "Open the Video Monitor on",
        keywords: ["display", "screen", "position", "window"])

    // Media & Analysis
    static let watchMedia = SettingsRow("settings.media.watch", .media, "Watch recordings for changes while editing",
        keywords: ["refresh", "relink", "files"])
    static let sceneAutoScan = SettingsRow("settings.media.scene-auto-scan", .media, "Scan for scenes when a recording is added",
        keywords: ["automatic", "analysis"])
    static let silenceAutoScan = SettingsRow("settings.media.silence-auto-scan", .media, "Scan for pauses when a recording is added",
        keywords: ["automatic", "analysis", "silence"])
    static let minimumPause = SettingsRow("settings.media.minimum-pause", .media, "Minimum pause",
        keywords: ["silence", "seconds"])
    static let maxBlip = SettingsRow("settings.media.max-blip", .media, "Ignore sounds up to",
        keywords: ["silence", "blip", "seconds"])
    static let padding = SettingsRow("settings.media.padding", .media, "Padding per side", keywords: ["silence", "seconds"])
    static let tilesLayout = SettingsRow("settings.media.tiles-layout", .media, "Layout",
        keywords: ["find tiles", "video call", "camera multiview", "even grid", "participants"])
    static let tilesColumns = SettingsRow("settings.media.tiles-columns", .media, "Grid columns", keywords: ["find tiles", "grid"])
    static let tilesRows = SettingsRow("settings.media.tiles-rows", .media, "Grid rows", keywords: ["find tiles", "grid"])
    static let tilesDetail = SettingsRow("settings.media.tiles-detail", .media, "Scan detail",
        keywords: ["find tiles", "adaptive", "every frame", "sampled"])
    static let dialogueHold = SettingsRow("settings.media.dialogue-hold", .media, "Minimum hold",
        keywords: ["dialogue switches", "seconds", "tiles"])
    static let dialogueOverlap = SettingsRow("settings.media.dialogue-overlap", .media, "Overlapping speech",
        keywords: ["dialogue switches", "tiles"])
    static let dialogueOffscreen = SettingsRow("settings.media.dialogue-offscreen", .media, "Offscreen speaker",
        keywords: ["dialogue switches", "tiles", "reaction"])

    // Transcripts
    static let helperLocation = SettingsRow("settings.transcripts.helper", .transcripts, "Helper location",
        keywords: ["transcriberrr", "path", "automatic"])
    static let engine = SettingsRow("settings.transcripts.engine", .transcripts, "Preferred engine",
        keywords: ["transcription", "qwen3", "model"])
    static let speakers = SettingsRow("settings.transcripts.speakers", .transcripts, "Identify speakers in mixed audio",
        keywords: ["diarization", "transcription"])
    static let downloads = SettingsRow("settings.transcripts.downloads", .transcripts, "Download missing models",
        keywords: ["transcription", "network"])
    static let followPlayback = SettingsRow("settings.transcripts.follow", .transcripts, "Follow playback in new windows",
        keywords: ["reader", "scroll"])
    static let readerTextSize = SettingsRow("settings.transcripts.text-size", .transcripts, "Reader text size",
        keywords: ["font", "points"])
    static let boundary = SettingsRow("settings.transcripts.boundary", .transcripts, "Boundary",
        keywords: ["nearest media frame", "copy-safe", "exact", "edit"])
    static let retainedPause = SettingsRow("settings.transcripts.retained-pause", .transcripts, "Pause to keep when tightening",
        keywords: ["tighten", "seconds"])
    static let fillerTerms = SettingsRow("settings.transcripts.filler", .transcripts, "Filler terms",
        keywords: ["um", "uh", "review"])
    static let exportFormat = SettingsRow("settings.transcripts.export-format", .transcripts, "Export Transcript format",
        keywords: ["json", "text", "subrip", "webvtt"])
    static let captionCharacters = SettingsRow("settings.transcripts.caption-characters", .transcripts, "Characters per line",
        keywords: ["captions", "subtitles"])
    static let captionLines = SettingsRow("settings.transcripts.caption-lines", .transcripts, "Lines",
        keywords: ["captions", "subtitles"])
    static let captionCue = SettingsRow("settings.transcripts.caption-cue", .transcripts, "Longest cue",
        keywords: ["captions", "subtitles", "seconds"])
    static let captionLabels = SettingsRow("settings.transcripts.caption-labels", .transcripts, "Speaker labels",
        keywords: ["captions", "subtitles", "names"])

    // Export
    static let movieMode = SettingsRow("settings.export.movie-mode", .export, "Default movie export mode",
        keywords: ["smart trim", "copy", "encode"])
    static let jpegPreset = SettingsRow("settings.export.jpeg-preset", .export, "Default JPEG preset", keywords: ["frames", "stills"])
    static let reencodeCodec = SettingsRow("settings.export.codec", .export, "Re-encode video",
        keywords: ["codec", "h.264", "hevc", "prores"])
    static let reencodeQuality = SettingsRow("settings.export.quality", .export, "Quality", keywords: ["re-encode", "bitrate"])
    static let proresQuality = SettingsRow("settings.export.prores-quality", .export, "ProRes quality", keywords: ["422", "hq", "lt"])
    static let container = SettingsRow("settings.export.container", .export, "H.264 and HEVC container",
        keywords: ["file type"] + ExportRules.reencodeContainers(.h264))
    static let multicamAudio = SettingsRow("settings.export.multicam-audio", .export, "Multicam audio",
        keywords: ["separate tracks", "mono", "stereo", "downmix"])
    static let resultJSON = SettingsRow("settings.export.result-json", .export, "Save Export Result JSON", keywords: ["report"])
    static let resolveOpen = SettingsRow("settings.export.resolve-open", .export, "Open the timeline in Resolve after sending",
        keywords: ["davinci"])
    static let startFolder = SettingsRow("settings.export.start-folder", .export, "Start export panels in",
        keywords: ["folder", "save panel", "destination"])
    static let finishedReveal = SettingsRow("settings.export.finished-reveal", .export, "Show in Finder",
        keywords: ["when an export finishes", "completion"])
    static let finishedNotify = SettingsRow("settings.export.finished-notify", .export, "Notify",
        keywords: ["when an export finishes", "notification", "completion"])
    static let finishedSound = SettingsRow("settings.export.finished-sound", .export, "Play a sound",
        keywords: ["when an export finishes", "completion"])

    // Storage
    static let reuseAnalysis = SettingsRow("settings.storage.reuse-analysis", .storage, "Save and reuse analysis",
        keywords: ["cutcache", "sidecar", "cache"])
    static let cutcacheLocation = SettingsRow("sidecars.storage-location", .storage, "Save new cutcaches",
        keywords: ["cutcache", "cache", "folder", "disk", "sidecar"])
    static let clearCutcaches = SettingsRow("settings.storage.clear-cutcaches", .storage, "Clear cutcaches…",
        keywords: ["cache", "remove", "disk space"])
    static let cacheLimit = SettingsRow("settings.storage.cache-limit", .storage, "Limit the shared cache folder",
        keywords: ["cache", "cutcache", "bytes", "size"])
    static let draftRetention = SettingsRow("settings.storage.draft-retention", .storage, "Remove untitled drafts after",
        keywords: ["drafts", "trash", "days"])
    static let storageUsage = SettingsRow("settings.storage.usage", .storage, "Usage",
        keywords: ["disk space", "size", "show in finder", "clear", "generated stills", "transcript recognition results",
                   "suggested transcript cameras", "agent job receipts", "untitled drafts"])

    // Automation
    static let localMCP = SettingsRow("settings.automation.local-mcp", .automation, "Enable local MCP control",
        keywords: ["agent", "mcp", "socket", "claude", "codex"])
    static let agentSettings = SettingsRow("settings.automation.agent-settings", .automation, "Let agents change settings",
        keywords: ["agent", "mcp", "permission", "preferences"])
    static let agentReplace = SettingsRow("settings.automation.agent-replace", .automation, "Let agents replace existing project files",
        keywords: ["agent", "mcp", "permission", "overwrite", "replace_existing"])
    static let cliPath = SettingsRow("settings.automation.cli-path", .automation, "Command-line tool",
        keywords: ["cli", "mpcut", "path", "copy", "terminal"])
    static let helperPath = SettingsRow("settings.automation.helper-path", .automation, "MCP helper",
        keywords: ["agent", "mcp", "mpcut-mcp", "path", "copy"])
    static let agentGuide = SettingsRow("settings.automation.agent-guide", .automation, "Open Agent Guide",
        keywords: ["agent", "mcp", "help", "documentation"])
    static let agentConfiguration = SettingsRow("settings.automation.agent-configuration", .automation, "Copy Agent Configuration",
        keywords: ["agent", "mcp", "mcpServers", "claude", "codex", "json"])

    static let all: [SettingsRow] = [
        multipleRecordings, historyLimit, recentItems, draftRecovery, tierWarning, rescanConfirmation, exportMessage, resetWarnings,
        snapTarget, sourceTicks, largePreviews, cutSections, timeDisplay, panelPosition, trackLabelWidth, stillDuration, gapDuration,
        gapColor, stillTimelineWidth, stillTimelineHeight, stillTimelineFrameRate, stillTimelineCodec,
        scrubAudio, muted, volume, playbackSpeed, preroll, postroll, viewerSDR, monitorSDR, cleanFeed, monitorPlacement,
        watchMedia, sceneAutoScan, silenceAutoScan, minimumPause, maxBlip, padding, tilesLayout, tilesColumns, tilesRows, tilesDetail,
        dialogueHold, dialogueOverlap, dialogueOffscreen,
        helperLocation, transcriberrrStatus, engine, speakers, downloads, followPlayback, readerTextSize, boundary, retainedPause, fillerTerms,
        exportFormat, captionCharacters, captionLines, captionCue, captionLabels,
        movieMode, jpegPreset, reencodeCodec, reencodeQuality, proresQuality, container, multicamAudio, resultJSON, resolveOpen,
        startFolder, finishedReveal, finishedNotify, finishedSound,
        reuseAnalysis, cutcacheLocation, clearCutcaches, cacheLimit, draftRetention, storageUsage,
        localMCP, cliPath, helperPath, agentGuide, agentConfiguration, agentSettings, agentReplace
    ]
}

/// The row a search result asked for. Each control reads it to scroll into view, take focus and show a brief highlight.
private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

extension View {
    /// Names a control after its row and lets a search result focus it.
    func settingsRow(_ row: SettingsRow) -> some View {
        modifier(SettingsRowModifier(row: row))
    }
}

private struct SettingsRowModifier: ViewModifier {
    let row: SettingsRow
    @Environment(\.settingsHighlight) private var highlight
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(row.id)
            .focused($focused)
            .id(row.id)
            .listRowBackground(highlight == row.id ? Color.accentColor.opacity(0.15) : nil)
            .onChange(of: highlight, initial: true) { _, target in
                if target == row.id { focused = true }
            }
    }
}

/// The search field above the sidebar.
struct SettingsSearchField: View {
    @Binding var query: String
    let submit: () -> Void

    var body: some View {
        TextField("Search", text: $query, prompt: Text("Search"))
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)
            .accessibilityLabel("Search settings")
            .accessibilityIdentifier("settings.search")
            .help("Find a setting by name or keyword")
    }
}
