import Foundation

/// What Restore Defaults changes, named from the same factory table that performs it, so the dialog cannot drift from
/// the restore. Every restorable key has an entry here; a test checks that none is missing. Each name is its row's title,
/// with the section in parentheses where the title alone could mean another row on the page.
enum SettingsRestoreSummary {
    /// When a restored value takes effect.
    enum Reach: CaseIterable {
        /// At once, in open projects and windows too.
        case now
        /// The next time something reads it, in open projects too. Open sheets and panels keep their choices.
        case nextUse
        /// In windows opened afterwards.
        case newWindows
        /// At the next launch.
        case nextLaunch

        var lead: String {
            switch self {
            case .now: "Changes at once, also in open projects:"
            case .nextUse: "Used the next time it is needed, also in open projects:"
            case .newWindows: "Used by windows opened from now on:"
            case .nextLaunch: "Used at the next launch:"
            }
        }
    }

    struct Entry {
        let name: String
        let reach: Reach

        init(_ name: String, _ reach: Reach) {
            self.name = name
            self.reach = reach
        }
    }

    private typealias Key = EditorPreferences.Key
    private typealias LocalKey = EditorPreferences.LocalKey

    static let entries: [String: Entry] = [
        Key.openMultipleRecordingsDefaultAction.rawValue: .init(SettingsRow.multipleRecordings.title, .nextUse),
        Key.recentFilesMaxCount.rawValue: .init(SettingsRow.recentItems.title, .now),
        Key.draftRecoveryPromptEnabled.rawValue: .init(SettingsRow.draftRecovery.title, .nextLaunch),
        Key.exportTierDowngradeWarningEnabled.rawValue: .init(SettingsRow.tierWarning.title, .now),
        Key.sceneRescanConfirmationEnabled.rawValue: .init(SettingsRow.rescanConfirmation.title, .now),
        Key.projectExportCompletionMessageEnabled.rawValue: .init(SettingsRow.exportMessage.title, .now),
        LocalKey.warningsSuppressed.rawValue: .init("Warnings turned off with “Don’t ask again”", .now),

        Key.timelineSnapTarget.rawValue: .init(SettingsRow.snapTarget.title, .now),
        Key.timelineSourceTimeTicksEnabled.rawValue: .init(SettingsRow.sourceTicks.title, .now),
        Key.timelineLargePreviewsEnabled.rawValue: .init(SettingsRow.largePreviews.title, .now),
        Key.timelineCutSectionsDefaultEnabled.rawValue: .init(SettingsRow.cutSections.title, .newWindows),
        Key.workspaceFullHeightSidebarEnabled.rawValue: .init(SettingsRow.panelPosition.title, .now),
        Key.multicamTrackLabelWidthPoints.rawValue: .init(SettingsRow.trackLabelWidth.title, .now),
        Key.stillPlacementDefaultDurationSeconds.rawValue: .init(SettingsRow.stillDuration.title, .nextUse),
        Key.gapDefaultDurationSeconds.rawValue: .init(SettingsRow.gapDuration.title, .nextUse),
        Key.gapDefaultColor.rawValue: .init(SettingsRow.gapColor.title, .nextUse),
        Key.stillTimelineDefaultWidthPixels.rawValue: .init(SettingsRow.stillTimelineWidth.title + " (new stills timeline)", .nextUse),
        Key.stillTimelineDefaultHeightPixels.rawValue: .init(SettingsRow.stillTimelineHeight.title + " (new stills timeline)", .nextUse),
        Key.stillTimelineDefaultFrameRate.rawValue: .init(SettingsRow.stillTimelineFrameRate.title + " (new stills timeline)", .nextUse),
        Key.stillTimelineDefaultCodec.rawValue: .init(SettingsRow.stillTimelineCodec.title + " (new stills timeline)", .nextUse),
        Key.timelineTimeDisplay.rawValue: .init(SettingsRow.timeDisplay.title, .now),

        Key.playbackScrubAudioEnabled.rawValue: .init(SettingsRow.scrubAudio.title, .now),
        Key.playbackPreviewMuted.rawValue: .init(SettingsRow.muted.title, .now),
        Key.playbackPreviewVolumeFraction.rawValue: .init(SettingsRow.volume.title, .now),
        Key.playbackDefaultSpeed.rawValue: .init(SettingsRow.playbackSpeed.title, .newWindows),
        Key.playbackCutPreviewPrerollSeconds.rawValue: .init(SettingsRow.preroll.title + " (play around a cut)", .nextUse),
        Key.playbackCutPreviewPostrollSeconds.rawValue: .init(SettingsRow.postroll.title + " (play around a cut)", .nextUse),
        Key.playbackViewerForceSdrEnabled.rawValue: .init(SettingsRow.viewerSDR.title, .now),
        Key.playbackMonitorForceSdrEnabled.rawValue: .init(SettingsRow.monitorSDR.title, .now),
        Key.playbackMonitorCleanFeedEnabled.rawValue: .init(SettingsRow.cleanFeed.title, .now),
        Key.playbackMonitorPlacement.rawValue: .init(SettingsRow.monitorPlacement.title, .nextUse),

        Key.mediaAutoRefreshEnabled.rawValue: .init(SettingsRow.watchMedia.title, .now),
        Key.analysisSceneAutoScanEnabled.rawValue: .init(SettingsRow.sceneAutoScan.title, .nextUse),
        Key.analysisSilenceAutoScanEnabled.rawValue: .init(SettingsRow.silenceAutoScan.title, .nextUse),
        Key.silenceMinPauseSeconds.rawValue: .init(SettingsRow.minimumPause.title, .now),
        Key.silenceMaxBlipSeconds.rawValue: .init(SettingsRow.maxBlip.title, .now),
        Key.silencePaddingPerSideSeconds.rawValue: .init(SettingsRow.padding.title, .now),
        Key.tilesScanDefaultLayout.rawValue: .init(SettingsRow.tilesLayout.title + " (Find Tiles)", .nextUse),
        Key.tilesScanDefaultGridColumns.rawValue: .init(SettingsRow.tilesColumns.title, .nextUse),
        Key.tilesScanDefaultGridRows.rawValue: .init(SettingsRow.tilesRows.title, .nextUse),
        Key.tilesScanDefaultDetail.rawValue: .init(SettingsRow.tilesDetail.title, .nextUse),
        Key.tilesDialogueDefaultMinHoldSeconds.rawValue: .init(SettingsRow.dialogueHold.title, .nextUse),
        Key.tilesDialogueDefaultOverlapPolicy.rawValue: .init(SettingsRow.dialogueOverlap.title, .nextUse),
        Key.tilesDialogueDefaultOffscreenPolicy.rawValue: .init(SettingsRow.dialogueOffscreen.title, .nextUse),

        LocalKey.transcriptHelperPath.rawValue: .init(SettingsRow.helperLocation.title, .nextUse),
        Key.transcriptDefaultEngine.rawValue: .init(SettingsRow.engine.title, .nextUse),
        Key.transcriptDefaultSpeakerIdentificationEnabled.rawValue: .init(SettingsRow.speakers.title, .nextUse),
        Key.transcriptDefaultModelDownloadEnabled.rawValue: .init(SettingsRow.downloads.title, .nextUse),
        Key.transcriptFollowPlaybackDefaultEnabled.rawValue: .init(SettingsRow.followPlayback.title, .newWindows),
        Key.transcriptReaderTextSizePoints.rawValue: .init(SettingsRow.readerTextSize.title, .newWindows),
        Key.transcriptEditDefaultBoundaryPolicy.rawValue: .init(SettingsRow.boundary.title, .nextUse),
        Key.transcriptTightenDefaultRetainedPauseSeconds.rawValue: .init(SettingsRow.retainedPause.title, .nextUse),
        Key.transcriptDefaultFillerTerms.rawValue: .init(SettingsRow.fillerTerms.title, .nextUse),
        Key.transcriptExportDefaultFormat.rawValue: .init(SettingsRow.exportFormat.title, .nextUse),
        Key.transcriptCaptionMaxLineCharacters.rawValue: .init(SettingsRow.captionCharacters.title, .nextUse),
        Key.transcriptCaptionMaxLines.rawValue: .init(SettingsRow.captionLines.title + " (captions)", .nextUse),
        Key.transcriptCaptionMaxCueSeconds.rawValue: .init(SettingsRow.captionCue.title, .nextUse),
        Key.transcriptCaptionSpeakerLabelsEnabled.rawValue: .init(SettingsRow.captionLabels.title, .nextUse),

        Key.exportMovieDefaultMode.rawValue: .init(SettingsRow.movieMode.title, .now),
        Key.exportJpegDefaultPreset.rawValue: .init(SettingsRow.jpegPreset.title, .nextUse),
        Key.exportReencodeDefaultCodec.rawValue: .init(SettingsRow.reencodeCodec.title, .nextUse),
        Key.exportReencodeDefaultQuality.rawValue: .init(SettingsRow.reencodeQuality.title, .nextUse),
        Key.exportProresDefaultQuality.rawValue: .init(SettingsRow.proresQuality.title, .nextUse),
        Key.exportReencodeDefaultContainer.rawValue: .init(SettingsRow.container.title, .nextUse),
        Key.exportMulticamDefaultAudioLayout.rawValue: .init(SettingsRow.multicamAudio.title, .nextUse),
        Key.exportResultJsonDefaultEnabled.rawValue: .init(SettingsRow.resultJSON.title, .nextUse),
        Key.resolveSendOpenTimelineDefaultEnabled.rawValue: .init(SettingsRow.resolveOpen.title, .nextUse),
        Key.exportStartFolderMode.rawValue: .init(SettingsRow.startFolder.title, .nextUse),
        LocalKey.exportStartFolderPath.rawValue: .init("Chosen folder", .nextUse),
        Key.exportFinishedRevealEnabled.rawValue: .init(SettingsRow.finishedReveal.title + " (when an export finishes)", .nextUse),
        Key.exportFinishedNotificationEnabled.rawValue: .init(SettingsRow.finishedNotify.title + " (when an export finishes)", .nextUse),
        Key.exportFinishedSoundEnabled.rawValue: .init(SettingsRow.finishedSound.title + " (when an export finishes)", .nextUse),

        Key.analysisSidecarReuseEnabled.rawValue: .init(SettingsRow.reuseAnalysis.title, .now),
        Key.analysisSharedCacheMaxBytes.rawValue: .init(SettingsRow.cacheLimit.title, .now),
        Key.draftRetentionDays.rawValue: .init(SettingsRow.draftRetention.title, .nextLaunch)
    ]

    /// What Restore Defaults leaves alone on a page, because its reset reaches beyond Settings.
    static func kept(on page: SettingsPage) -> String? {
        switch page {
        case .general: "The undo limit keeps its value."
        case .storage: "The cutcache location keeps its value."
        case .automation: "Local MCP control and the agent permissions keep their values."
        case .editing, .playback, .media, .transcripts, .export: nil
        }
    }

    /// A page with nothing to restore shows no Restore Defaults button.
    @MainActor static func isRestorable(_ page: SettingsPage) -> Bool {
        EditorPreferences.factories.contains { $0.page == page }
    }

    static func title(for page: SettingsPage) -> String { "Restore \(page.title) settings to their defaults?" }

    /// Names every value on the page that differs from its factory value, grouped by when the change takes effect.
    @MainActor static func message(for page: SettingsPage, preferences: EditorPreferences) -> String {
        var names: [Reach: [String]] = [:]
        for factory in EditorPreferences.factories where factory.page == page && !factory.isCurrent(preferences) {
            let entry = entries[factory.key] ?? Entry(factory.key, .now)
            if names[entry.reach]?.contains(entry.name) != true { names[entry.reach, default: []].append(entry.name) }
        }
        var sentences: [String] = []
        if names.isEmpty {
            sentences.append("Every value on this page already has its factory value.")
        }
        for reach in Reach.allCases {
            guard let list = names[reach] else { continue }
            var sentence = reach.lead + " " + listed(list) + "."
            if reach == .nextUse { sentence += " Sheets and panels that are already open keep their choices." }
            sentences.append(sentence)
        }
        if let kept = kept(on: page) { sentences.append(kept) }
        sentences.append("A value supplied as a launch argument applies again at the next launch.")
        return sentences.joined(separator: " ")
    }

    static func listed(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }
}
