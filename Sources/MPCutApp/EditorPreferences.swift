import Combine
import Foundation
import MPCutCore

@MainActor
final class EditorPreferences: ObservableObject {
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
    }

    enum Change {
        case automaticallyRefreshMedia, localMCPEnabled, useAnalysisSidecars, defaultExportMode, snapTarget, largeThumbnails
        case sourceTimeTicks, maxBlip, minimumPause, padding, volume, isMuted, scrubSoundEnabled, jpegPreset, historyLimit
    }

    let recentFiles: RecentFiles
    private var defaults: UserDefaults?
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

    static let historyStepRange = 0...CutProject.maximumHistorySteps
    @Published private var storedHistoryLimit = 50
    var historyLimit: Int {
        get { storedHistoryLimit }
        set {
            let bounded = min(Self.historyStepRange.upperBound, max(Self.historyStepRange.lowerBound, newValue))
            let previous = storedHistoryLimit
            guard previous != bounded else { return }
            storedHistoryLimit = bounded
            save(bounded, replacing: previous, key: .historyMaxSteps, change: .historyLimit)
        }
    }

    @Published var localMCPEnabled = false {
        didSet { save(localMCPEnabled, replacing: oldValue, key: .automationLocalMcpEnabled, change: .localMCPEnabled) }
    }
    @Published var localMCPStatus = "Off"

    @Published var automaticallyRefreshMedia = false {
        didSet { save(automaticallyRefreshMedia, replacing: oldValue, key: .mediaAutoRefreshEnabled, change: .automaticallyRefreshMedia) }
    }

    @Published var useAnalysisSidecars = true {
        didSet { save(useAnalysisSidecars, replacing: oldValue, key: .analysisSidecarReuseEnabled, change: .useAnalysisSidecars) }
    }
    /// The factory default of the movie export mode, from the export rules. The CLI uses the same one.
    static let factoryExportMode = ExportRules.defaultMode(for: .movie)
    @Published var defaultExportMode = EditorPreferences.factoryExportMode {
        didSet {
            save(defaultExportMode, replacing: oldValue, key: .exportMovieDefaultMode,
                 stored: defaultExportMode.rawValue, change: .defaultExportMode)
        }
    }
    /// Ask before an edit made by hand lowers the timeline tier. Nothing recalculates when it changes, so it is only stored.
    @Published var warnBeforeLoweringExportTier = true {
        didSet {
            if warnBeforeLoweringExportTier != oldValue { defaults?.set(warnBeforeLoweringExportTier, forKey: Key.exportTierDowngradeWarningEnabled.rawValue) }
        }
    }
    @Published var snapTarget = TimelineSnapTarget.off {
        didSet {
            save(snapTarget, replacing: oldValue, key: .timelineSnapTarget, stored: snapTarget.rawValue, change: .snapTarget)
        }
    }
    @Published var sourceTimeTicks = false {
        didSet { save(sourceTimeTicks, replacing: oldValue, key: .timelineSourceTimeTicksEnabled, change: .sourceTimeTicks) }
    }
    @Published var largeThumbnails = false {
        didSet { save(largeThumbnails, replacing: oldValue, key: .timelineLargePreviewsEnabled, change: .largeThumbnails) }
    }
    @Published var maxBlip = AudioWaveform.defaultMaxBlip {
        didSet { save(maxBlip, replacing: oldValue, key: .silenceMaxBlipSeconds, change: .maxBlip) }
    }
    @Published var minimumPause = 1.5 {
        didSet { save(minimumPause, replacing: oldValue, key: .silenceMinPauseSeconds, change: .minimumPause) }
    }
    @Published var padding = 0.2 {
        didSet { save(padding, replacing: oldValue, key: .silencePaddingPerSideSeconds, change: .padding) }
    }
    @Published var volume: Float = 1 {
        didSet { save(volume, replacing: oldValue, key: .playbackPreviewVolumeFraction, change: .volume) }
    }
    @Published var isMuted = false {
        didSet { save(isMuted, replacing: oldValue, key: .playbackPreviewMuted, change: .isMuted) }
    }
    @Published var scrubSoundEnabled = true {
        didSet { save(scrubSoundEnabled, replacing: oldValue, key: .playbackScrubAudioEnabled, change: .scrubSoundEnabled) }
    }
    @Published var jpegPreset = JPEGPreset.review {
        didSet {
            save(jpegPreset, replacing: oldValue, key: .exportJpegDefaultPreset, stored: jpegPreset.rawValue, change: .jpegPreset)
        }
    }

    init(defaults: UserDefaults? = nil) {
        recentFiles = RecentFiles(defaults: defaults)
        guard let defaults else { return }
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
        // Published properties invoke their observers during initialization. Enable persistence
        // after loading so argument and registration domains stay temporary.
        self.defaults = defaults
    }

    // `defaults write` stores a string unless it is given a type, and an
    // unreadable value keeps the built-in default instead of becoming zero.
    private static func number(_ stored: Any?) -> Double? {
        let value = (stored as? NSNumber)?.doubleValue ?? (stored as? String).flatMap(Double.init)
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func flag(_ stored: Any?) -> Bool? {
        if let number = stored as? NSNumber { return number.boolValue }
        switch (stored as? String)?.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }

    func observeChanges(_ receiveValue: @escaping (Change) -> Void) -> AnyCancellable {
        changes.sink(receiveValue: receiveValue)
    }

    private func save<Value: Equatable>(_ value: Value, replacing oldValue: Value,
                                        key: Key, stored: Any? = nil, change: Change) {
        guard value != oldValue else { return }
        defaults?.set(stored ?? value, forKey: key.rawValue)
        changes.send(change)
    }
}
