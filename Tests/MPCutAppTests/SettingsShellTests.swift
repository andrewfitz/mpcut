import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// The app shell, General, Storage and Automation wiring of the Settings redesign.
@MainActor
final class SettingsShellTests: XCTestCase {
    private let files = FileManager.default
    private var suiteNames: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        for folder in folders { try? files.removeItem(at: folder) }
        super.tearDown()
    }

    private func suite() throws -> UserDefaults {
        let name = "com.mpcut.tests.settings-shell." + UUID().uuidString
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func folder() throws -> URL {
        let url = files.temporaryDirectory.appendingPathComponent("mpcut-shell-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    // MARK: Let agents change settings

    /// Writes a valid value that differs from the factory value. Exhaustive, so a new key must be added here.
    private func writeDifferentValue(_ key: EditorPreferences.Key, to p: EditorPreferences) {
        switch key {
        case .automationLocalMcpEnabled: p.localMCPEnabled = !p.localMCPEnabled
        case .mediaAutoRefreshEnabled: p.automaticallyRefreshMedia = !p.automaticallyRefreshMedia
        case .analysisSidecarReuseEnabled: p.useAnalysisSidecars = !p.useAnalysisSidecars
        case .historyMaxSteps: p.historyLimit = 9
        case .timelineSourceTimeTicksEnabled: p.sourceTimeTicks = !p.sourceTimeTicks
        case .timelineSnapTarget: p.snapTarget = .keyframes
        case .timelineLargePreviewsEnabled: p.largeThumbnails = !p.largeThumbnails
        case .playbackPreviewVolumeFraction: p.volume = 0.5
        case .playbackPreviewMuted: p.isMuted = !p.isMuted
        case .playbackScrubAudioEnabled: p.scrubSoundEnabled = !p.scrubSoundEnabled
        case .exportMovieDefaultMode: p.defaultExportMode = .encode
        case .exportJpegDefaultPreset: p.jpegPreset = .full
        case .exportTierDowngradeWarningEnabled: p.warnBeforeLoweringExportTier = !p.warnBeforeLoweringExportTier
        case .silenceMinPauseSeconds: p.minimumPause = 2.5
        case .silenceMaxBlipSeconds: p.maxBlip = 0.1
        case .silencePaddingPerSideSeconds: p.padding = 0.3
        case .openMultipleRecordingsDefaultAction: p.multipleRecordingsAction = .join
        case .recentFilesMaxCount: p.recentFilesLimit = 5
        case .draftRecoveryPromptEnabled: p.offersDraftRecovery = !p.offersDraftRecovery
        case .sceneRescanConfirmationEnabled: p.confirmsSceneRescan = !p.confirmsSceneRescan
        case .projectExportCompletionMessageEnabled: p.showsProjectExportMessage = !p.showsProjectExportMessage
        case .timelineCutSectionsDefaultEnabled: p.showsCutSections = !p.showsCutSections
        case .workspaceFullHeightSidebarEnabled: p.fullHeightSidebar = !p.fullHeightSidebar
        case .multicamTrackLabelWidthPoints: p.trackLabelWidth = 200
        case .stillPlacementDefaultDurationSeconds: p.stillDuration = 3
        case .gapDefaultDurationSeconds: p.gapDuration = 3
        case .gapDefaultColor: p.gapColor = "#FF0000"
        case .stillTimelineDefaultWidthPixels: p.stillTimelineWidth = 1280
        case .stillTimelineDefaultHeightPixels: p.stillTimelineHeight = 720
        case .stillTimelineDefaultFrameRate: p.stillTimelineFrameRate = 25
        case .stillTimelineDefaultCodec: p.stillTimelineCodec = .hevc
        case .timelineTimeDisplay: p.timeDisplay = .frames
        case .playbackDefaultSpeed: p.playbackSpeed = .eighth
        case .playbackCutPreviewPrerollSeconds: p.cutPreviewPreroll = 2
        case .playbackCutPreviewPostrollSeconds: p.cutPreviewPostroll = 2
        case .playbackViewerForceSdrEnabled: p.viewerForceSDR = !p.viewerForceSDR
        case .playbackMonitorForceSdrEnabled: p.monitorForceSDR = !p.monitorForceSDR
        case .playbackMonitorCleanFeedEnabled: p.monitorCleanFeed = !p.monitorCleanFeed
        case .playbackMonitorPlacement: p.monitorPlacement = .lastPosition
        case .analysisSceneAutoScanEnabled: p.autoScanScenes = !p.autoScanScenes
        case .analysisSilenceAutoScanEnabled: p.autoScanSilence = !p.autoScanSilence
        case .tilesScanDefaultLayout: p.tilesScanLayout = .evenGrid
        case .tilesScanDefaultGridColumns: p.tilesScanColumns = 3
        case .tilesScanDefaultGridRows: p.tilesScanRows = 3
        case .tilesScanDefaultDetail: p.tilesScanDetail = .sparse
        case .tilesDialogueDefaultMinHoldSeconds: p.dialogueMinimumHold = 2
        case .tilesDialogueDefaultOverlapPolicy: p.dialogueOverlap = .visibleSpeaker
        case .tilesDialogueDefaultOffscreenPolicy: p.dialogueOffscreen = .reaction
        case .transcriptDefaultEngine: p.transcriptEngine = "qwen3"
        case .transcriptDefaultSpeakerIdentificationEnabled: p.identifiesSpeakers = !p.identifiesSpeakers
        case .transcriptDefaultModelDownloadEnabled: p.downloadsModels = !p.downloadsModels
        case .transcriptFollowPlaybackDefaultEnabled: p.followsPlayback = !p.followsPlayback
        case .transcriptReaderTextSizePoints: p.readerTextSize = 16
        case .transcriptEditDefaultBoundaryPolicy: p.boundaryPolicy = .exact
        case .transcriptTightenDefaultRetainedPauseSeconds: p.retainedPause = 0.5
        case .transcriptDefaultFillerTerms: p.fillerTerms = "um, uh"
        case .transcriptExportDefaultFormat: p.transcriptExportFormat = .srt
        case .transcriptCaptionMaxLineCharacters: p.captionLineCharacters = 30
        case .transcriptCaptionMaxLines: p.captionLines = 1
        case .transcriptCaptionMaxCueSeconds: p.captionCueSeconds = 4
        case .transcriptCaptionSpeakerLabelsEnabled: p.captionSpeakerLabels = !p.captionSpeakerLabels
        case .exportReencodeDefaultCodec: p.reencodeCodec = .hevc
        case .exportReencodeDefaultQuality: p.reencodeQuality = .highQuality
        case .exportProresDefaultQuality: p.proresQuality = .proresHQ
        case .exportReencodeDefaultContainer: p.reencodeContainer = .mkv
        case .exportMulticamDefaultAudioLayout: p.multicamAudioLayout = .downmixMono
        case .exportResultJsonDefaultEnabled: p.savesExportResult = !p.savesExportResult
        case .resolveSendOpenTimelineDefaultEnabled: p.opensResolveTimeline = !p.opensResolveTimeline
        case .exportStartFolderMode: p.exportStartFolder = .project
        case .exportFinishedRevealEnabled: p.revealsFinishedExport = !p.revealsFinishedExport
        case .exportFinishedNotificationEnabled: p.notifiesFinishedExport = !p.notifiesFinishedExport
        case .exportFinishedSoundEnabled: p.playsFinishedExportSound = !p.playsFinishedExportSound
        case .analysisSharedCacheMaxBytes: p.sharedCacheLimitBytes = 1_000_000_000
        case .draftRetentionDays: p.draftRetentionDays = 7
        case .automationPreferencesWriteEnabled: p.agentsChangeSettings = !p.agentsChangeSettings
        case .automationFileReplaceEnabled: p.agentsReplaceFiles = !p.agentsReplaceFiles
        }
    }

    private func value(_ key: EditorPreferences.Key, _ p: EditorPreferences) -> String { String(describing: p.mcpValue(key)) }

    func testAgentOriginCannotWriteAnyKeyWhileSettingsChangesAreOff() throws {
        let defaults = try suite()
        let p = EditorPreferences(defaults: defaults)
        p.agentsChangeSettings = false
        defaults.removeObject(forKey: EditorPreferences.Key.automationPreferencesWriteEnabled.rawValue)
        var changes: [EditorPreferences.Change] = []
        let token = p.observeChanges { changes.append($0) }
        defer { token.cancel() }
        for key in EditorPreferences.Key.allCases {
            let before = value(key, p)
            let request = AgentSettingsRequest()
            AgentOrigin.$request.withValue(request) { writeDifferentValue(key, to: p) }
            XCTAssertEqual(value(key, p), before, "\(key.rawValue) changed in memory")
            XCTAssertNil(defaults.object(forKey: key.rawValue), "\(key.rawValue) was stored")
            XCTAssertEqual(request.refusedKeys, [key.rawValue])
            XCTAssertEqual(request.failure?.code, "settings_write_disabled")
            XCTAssertFalse(p.mcpValues.isEmpty, "Reads still work")
        }
        XCTAssertTrue(changes.isEmpty, "A refused write sends no change: \(changes)")
        XCTAssertFalse(p.agentsChangeSettings)

        // The same writes from the user succeed.
        for key in EditorPreferences.Key.allCases {
            let before = value(key, p)
            writeDifferentValue(key, to: p)
            XCTAssertNotEqual(value(key, p), before, key.rawValue)
            XCTAssertNotNil(defaults.object(forKey: key.rawValue), key.rawValue)
        }
    }

    func testReadOnlyKeysStayAgentProofWithSettingsChangesOn() throws {
        let p = EditorPreferences(defaults: try suite())
        XCTAssertTrue(p.agentsChangeSettings)
        for key in EditorPreferences.Key.allCases {
            let before = value(key, p)
            let request = AgentSettingsRequest()
            AgentOrigin.$request.withValue(request) { writeDifferentValue(key, to: p) }
            if EditorPreferences.Key.agentReadOnly.contains(key) {
                XCTAssertEqual(value(key, p), before, key.rawValue)
                XCTAssertEqual(request.refusedKeys, [key.rawValue])
            } else {
                XCTAssertNotEqual(value(key, p), before, key.rawValue)
                XCTAssertNil(request.failure, key.rawValue)
            }
        }
    }

    func testAUserWriteDuringASuspendedAgentCommandIsTheUsers() async throws {
        let p = EditorPreferences()
        p.agentsChangeSettings = false
        let request = AgentSettingsRequest()
        let agent = Task { @MainActor in
            await AgentOrigin.$request.withValue(request) {
                try? await Task.sleep(for: .milliseconds(150))
                p.largeThumbnails = true
            }
        }
        await Task.yield()
        p.isMuted = true
        await agent.value
        XCTAssertTrue(p.isMuted)
        XCTAssertFalse(p.largeThumbnails)
        XCTAssertEqual(request.refusedKeys, ["timeline_large_previews_enabled"])
    }

    func testTheDispatcherMarksEveryCommandAsAnAgentsAndAnswersARefusedWrite() async throws {
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p)
        p.agentsChangeSettings = false
        // checkAccess runs inside the command, so a write it makes is the agent's.
        do {
            _ = try await sessions.handleMCPCommand(tool: "preferences_read", arguments: [:], session: nil,
                                                    checkAccess: { p.isMuted = true })
            XCTFail("A refused write was answered as a success")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "settings_write_disabled")
            XCTAssertTrue(failure.message.contains("playback_preview_muted"), failure.message)
        }
        XCTAssertFalse(p.isMuted)
        p.agentsChangeSettings = true
        _ = try await sessions.handleMCPCommand(tool: "preferences_read", arguments: [:], session: nil,
                                                checkAccess: { p.isMuted = true })
        XCTAssertTrue(p.isMuted)
        do {
            _ = try await sessions.handleMCPCommand(tool: "preferences_read", arguments: [:], session: nil,
                                                    checkAccess: { p.draftRetentionDays = 3 })
            XCTFail("An agent changed a read-only key")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "settings_write_disabled") }
        XCTAssertEqual(p.draftRetentionDays, 0)
        p.isMuted = false
        XCTAssertFalse(p.isMuted, "Outside a command the user writes as before")
    }

    func testVideoMonitorRemembersItsFrameAndReopensThere() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let p = EditorPreferences()
        let session = ProjectSession(id: UUID(), preferences: p)
        defer { session.end() }
        session.showMonitor()
        let opened = try XCTUnwrap(session.monitor).frame
        session.monitor?.close()
        XCTAssertNil(session.monitor)
        XCTAssertEqual(p.monitorLastFrame, opened, "Closing remembers the frame")
        let visible = screen.visibleFrame
        let target = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 640, height: 360)
        p.monitorLastFrame = target
        p.monitorPlacement = .lastPosition
        session.showMonitor()
        XCTAssertEqual(session.monitor?.frame, target)
    }

    func testLayoutRoutesRefuseCleanlyAndReadsStillWork() async throws {
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p)
        let session = sessions.session(for: UUID())
        defer { session.end() }
        p.agentsChangeSettings = false
        for arguments: [String: Any] in [["action": "set_full_height_panel", "enabled": true],
                                         ["action": "set_large_thumbnails", "enabled": true],
                                         ["action": "set_track_label_width", "points": 200]] {
            do {
                _ = try await sessions.handleMCPCommand(tool: "workspace_layout_set", arguments: arguments, session: session,
                                                        checkAccess: {})
                XCTFail("\(arguments) changed a setting")
            } catch let failure as MCPFailure {
                XCTAssertEqual(failure.code, "settings_write_disabled")
                XCTAssertTrue(failure.message.contains("Let agents change settings"), failure.message)
            }
        }
        XCTAssertFalse(p.fullHeightSidebar)
        XCTAssertFalse(p.largeThumbnails)
        XCTAssertEqual(p.trackLabelWidth, 172)
        let read = try await sessions.handleMCPCommand(tool: "workspace_layout_read", arguments: [:], session: session, checkAccess: {})
        XCTAssertEqual(read["full_height_panel"] as? Bool, false)
        let values = try await sessions.handleMCPCommand(tool: "preferences_read", arguments: [:], session: nil, checkAccess: {})
        XCTAssertEqual(values.count, EditorPreferences.Key.allCases.count)

        p.agentsChangeSettings = true
        _ = try await sessions.handleMCPCommand(tool: "workspace_layout_set", arguments: ["action": "set_full_height_panel", "enabled": true],
                                                session: session, checkAccess: {})
        XCTAssertTrue(p.fullHeightSidebar)
    }

    func testCutcacheLocationAndInPlaceFileJobsAskTheirSwitches() async throws {
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p)
        p.agentsChangeSettings = false
        do {
            _ = try await sessions.mcpFile(tool: "analysis_file_cache_settings_set", arguments: ["mode": "media"], session: nil,
                                           checkAccess: {})
            XCTFail("The cutcache location changed with agent settings off")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "settings_write_disabled") }
        p.agentsReplaceFiles = false
        do {
            _ = try await sessions.mcpFile(tool: "tiles_file_link", arguments: ["in_place": true, "project_path": "/tmp/none.cut"],
                                           session: nil, checkAccess: {})
            XCTFail("An in-place project update ran with replacing off")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "file_replace_disabled")
            XCTAssertTrue(failure.message.contains("Let agents replace existing project files"), failure.message)
        }
    }

    func testReplaceExistingFollowsItsSwitchAndSavingInPlaceStaysAllowed() async throws {
        let directory = try folder()
        let source = directory.appendingPathComponent("Source.cut"), other = directory.appendingPathComponent("Other.cut")
        try CutProject.sequence([]).save(to: source)
        try CutProject.sequence([]).save(to: other)
        let kept = try Data(contentsOf: other)
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        func call(_ name: String, _ arguments: [String: Any], _ session: ProjectSession? = nil) async throws -> [String: Any] {
            let result = try await sessions.mcpLifecycle(tool: name, arguments: arguments, session: session, checkAccess: {})
            return try XCTUnwrap(result)
        }
        _ = try await call("project_open", ["project_path": source.path])
        let live = try XCTUnwrap(sessions.project(at: source))
        p.agentsReplaceFiles = false
        do {
            _ = try await call("project_save", ["project_path": other.path, "replace_existing": true], live)
            XCTFail("Replaced another project with the switch off")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "file_replace_disabled") }
        XCTAssertEqual(try Data(contentsOf: other), kept)
        XCTAssertEqual(live.editor.projectURL?.lastPathComponent, "Source.cut")
        _ = try await call("project_save", ["project_path": source.path, "replace_existing": true], live)
        _ = try await call("project_save", [:], live)
        p.agentsReplaceFiles = true
        _ = try await call("project_save", ["project_path": other.path, "replace_existing": true], live)
        XCTAssertEqual(live.editor.projectURL?.lastPathComponent, "Other.cut")
    }

    // MARK: General

    func testRecentItemsTrimAtTheLimit() throws {
        let defaults = try suite()
        let p = EditorPreferences(defaults: defaults)
        let urls = (0..<35).map { URL(fileURLWithPath: "/tmp/recent-\($0).cut") }
        p.recentFiles.record(urls)
        XCTAssertEqual(p.recentFiles.urls.count, 10)
        p.recentFilesLimit = 3
        XCTAssertEqual(p.recentFiles.urls, Array(urls.prefix(3)))
        XCTAssertEqual(defaults.stringArray(forKey: "recent_file_paths")?.count, 3)
        p.recentFilesLimit = 30
        p.recentFiles.record(urls)
        XCTAssertEqual(p.recentFiles.urls.count, 30)
        let reopened = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reopened.recentFiles.urls.count, 30, "A stored limit above 10 is read before the list")
        reopened.recentFiles.clear()
        XCTAssertTrue(reopened.recentFiles.urls.isEmpty)
    }

    func testFinderBatchFollowsTheDefaultAndDontAskAgainIsUndoneByReset() async throws {
        _ = NSApplication.shared
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = try folder()
        let first = directory.appendingPathComponent("Camera B.mov"), second = directory.appendingPathComponent("Camera A.mov")
        try files.copyItem(at: fixture, to: first)
        try files.copyItem(at: fixture, to: second)
        let p = EditorPreferences()
        p.useAnalysisSidecars = false
        var opened: [UUID] = []
        let sessions = ProjectSessions(preferences: p, openWindow: { opened.append($0) })
        let session = sessions.session(for: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertThirdButtonReturn) }
            for active in Array(sessions.sessions.values) { sessions.windowClosed(active) }
            window.close()
        }

        // Ask, then “Don't ask again” with Join Clips.
        sessions.openFiles([first, second], in: session, fromFinder: true)
        try await waitUntil { window.attachedSheet != nil }
        let alert = try XCTUnwrap(sessions.finderChoiceAlert)
        XCTAssertTrue(alert.showsSuppressionButton)
        alert.suppressionButton?.state = .on
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await waitUntil { session.editor.timelineClips.count == 2 }
        XCTAssertEqual(p.multipleRecordingsAction, .join)
        XCTAssertFalse(p.asks(.openMultipleRecordings))

        // Join without asking.
        sessions.openFiles([second, first], in: session, fromFinder: true)
        try await waitUntil { session.editor.timelineClips.count == 4 }
        XCTAssertNil(window.attachedSheet)

        // Reset All Warnings asks again; Cancel with the box ticked changes nothing.
        p.resetAllWarnings()
        XCTAssertEqual(p.multipleRecordingsAction, .ask)
        sessions.openFiles([first, second], in: session, fromFinder: true)
        try await waitUntil { window.attachedSheet != nil }
        sessions.finderChoiceAlert?.suppressionButton?.state = .on
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertThirdButtonReturn)
        try await waitUntil { sessions.finderChoiceAlert == nil }
        XCTAssertEqual(p.multipleRecordingsAction, .ask)
        XCTAssertEqual(session.editor.timelineClips.count, 4)

        // A Settings choice of multicam opens a multicam window without asking.
        p.multipleRecordingsAction = .multicam
        sessions.openFiles([first, second], in: session, fromFinder: true)
        try await waitUntil { !opened.isEmpty }
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(try XCTUnwrap(opened.first.map { sessions.session(for: $0) }).isMulticam)
    }

    func testLaunchRecoveryOfferFollowsItsSettingAndRetentionRunsFirst() async throws {
        _ = NSApplication.shared
        let drafts = try folder().appendingPathComponent("Drafts", isDirectory: true)
        let trash = drafts.deletingLastPathComponent().appendingPathComponent("Trash", isDirectory: true)
        try files.createDirectory(at: trash, withIntermediateDirectories: true)
        func draft(ageDays: Double) throws -> URL {
            let folder = drafts.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Untitled.cut")
            try CutProject.sequence([]).save(to: file)
            try files.setAttributes([.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: file.path)
            return file
        }
        let old = try draft(ageDays: 30), recent = try draft(ageDays: 1)
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p, openWindow: { _ in })
        var offered: [[URL]] = []
        sessions.presentLaunchDraftRecovery = { files, _ in offered.append(files) }
        let session = sessions.session(for: nil)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { sessions.windowClosed(session); window.close() }
        let moveToTrash: @Sendable (URL) throws -> Void = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }

        // Factory values: nothing is removed and nothing is offered.
        await sessions.runLaunchMaintenance(drafts: drafts, trash: moveToTrash)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(offered.isEmpty)
        XCTAssertTrue(files.fileExists(atPath: old.path))

        p.offersDraftRecovery = true
        p.draftRetentionDays = 7
        await sessions.runLaunchMaintenance(drafts: drafts, trash: moveToTrash)
        try await waitUntil { offered.count == 1 }
        XCTAssertFalse(files.fileExists(atPath: old.path), "Expired drafts go before the offer")
        XCTAssertEqual(offered.first?.map { $0.resolvingSymlinksInPath().path }, [recent.resolvingSymlinksInPath().path])
    }

    // MARK: New-window defaults

    func testNewWindowsStartFromTheirDefaultsAndOpenWindowsKeepTheirState() {
        XCTAssertFalse(EditorPresentation().cutSectionsHidden)
        XCTAssertTrue(EditorPresentation().transcriptReader.followsPlayback)
        let p = EditorPreferences()
        let factory = ProjectSession(id: UUID(), preferences: p)
        XCTAssertFalse(factory.presentation.cutSectionsHidden)
        XCTAssertTrue(factory.presentation.transcriptReader.followsPlayback)
        p.showsCutSections = false
        p.followsPlayback = false
        XCTAssertFalse(factory.presentation.cutSectionsHidden, "An open window keeps its cut sections")
        XCTAssertTrue(factory.presentation.transcriptReader.followsPlayback, "An open window keeps following")
        let fresh = ProjectSession(id: UUID(), preferences: p)
        XCTAssertTrue(fresh.presentation.cutSectionsHidden)
        XCTAssertFalse(fresh.presentation.transcriptReader.followsPlayback)
        factory.end()
        fresh.end()
    }

    func testVideoMonitorLastPositionFallsBackOffScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1280, height: 800)]
        let saved = CGRect(x: 2000, y: 100, width: 800, height: 450)
        XCTAssertNil(ProjectSession.lastMonitorFrame(saved, placement: .otherDisplay, screens: screens))
        XCTAssertEqual(ProjectSession.lastMonitorFrame(saved, placement: .lastPosition, screens: screens), saved)
        XCTAssertNil(ProjectSession.lastMonitorFrame(saved, placement: .lastPosition, screens: [screens[0]]),
                     "A frame on a detached display uses the other-display rule")
        XCTAssertNil(ProjectSession.lastMonitorFrame(nil, placement: .lastPosition, screens: screens))
    }

    // MARK: show_settings

    func testShowSettingsOpensANamedPage() async throws {
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p)
        let session = sessions.session(for: UUID())
        defer { session.end() }
        var shown = 0
        session.presentation.showSettings = { shown += 1 }
        _ = try await sessions.mcpPresentation(tool: "workspace_panel_show", arguments: ["action": "show_settings"], session: session,
                                               checkAccess: {})
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(p.settingsPage, .general)
        let schemas = try MCPSchemas.loaded.get()
        let arguments = try schemas.validate(tool: "workspace_panel_show", arguments: [
            "project_handle": session.mcpHandle, "action": "show_settings", "page": "automation"])
        _ = try await sessions.mcpPresentation(tool: "workspace_panel_show", arguments: arguments, session: session, checkAccess: {})
        XCTAssertEqual(p.settingsPage, .automation)
        XCTAssertThrowsError(try schemas.validate(tool: "workspace_panel_show", arguments: [
            "project_handle": session.mcpHandle, "action": "show_settings", "page": "sidecars"]))
        do {
            _ = try await sessions.mcpPresentation(tool: "workspace_panel_show", arguments: ["action": "show_settings", "page": "sidecars"],
                                                   session: session, checkAccess: {})
            XCTFail("An unknown page opened")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "invalid_arguments") }
    }

    // MARK: Storage

    private func temporaryLocations() throws -> (StorageLocations, URL) {
        let root = try folder()
        let locations = StorageLocations(generatedStills: root.appendingPathComponent("Stills"),
                                         transcriptRecognition: root.appendingPathComponent("Claims"),
                                         transcriptJobs: [root.appendingPathComponent("Drafts/.transcript-jobs")],
                                         untitledDrafts: root.appendingPathComponent("Drafts"),
                                         agentReceipts: root.appendingPathComponent("Receipts"))
        return (locations, root)
    }

    func testUsageListMeasuresAndClearsSuggestedCamerasThroughThePreferences() async throws {
        let (locations, root) = try temporaryLocations()
        let draft = root.appendingPathComponent("Drafts/\(UUID().uuidString)/Untitled.cut")
        try files.createDirectory(at: draft.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8_192).write(to: draft)
        let defaults = try suite()
        let p = EditorPreferences(defaults: defaults)
        p.transcriptSuggestedAngles = Data(repeating: 7, count: 40)
        let model = StorageUsageModel(preferences: p, locations: locations)
        await model.refresh()
        XCTAssertEqual(model.sizes[.suggestedCameras], 40)
        XCTAssertGreaterThan(model.sizes[.untitledDrafts] ?? 0, 0)
        XCTAssertEqual(model.sizes[.generatedStills], 0)
        XCTAssertEqual(model.folder(for: .untitledDrafts)?.lastPathComponent, "Drafts")
        XCTAssertNil(model.folder(for: .suggestedCameras))

        let cleared = await model.clear(.suggestedCameras)
        XCTAssertEqual(cleared?.reclaimedBytes, 40)
        XCTAssertTrue(p.transcriptSuggestedAngles.isEmpty, "The value in memory is cleared too")
        XCTAssertEqual((defaults.data(forKey: StorageInventory.suggestedCamerasKey) ?? Data()).count, 0)
        XCTAssertEqual(model.report?.kind, .suggestedCameras)
        XCTAssertEqual(model.sizes[.suggestedCameras], 0)
        XCTAssertTrue(StorageUsageSection.summary(cleared ?? .init()).contains("Reclaimed"))

        let refused = await model.clear(.untitledDrafts)
        XCTAssertNil(refused, "Drafts have no Clear")
        XCTAssertTrue(files.fileExists(atPath: draft.path))
    }

    func testCacheLimitDoesNothingAtZeroAndProtectsOpenProjects() async throws {
        let root = try folder()
        let p = EditorPreferences()
        var calls: [(Int64, Set<URL>, URL)] = []
        let recorded = Recorder()
        let recording = URL(fileURLWithPath: "/tmp/protected.mov")
        var context = SidecarClearContext()
        context.protected = [recording]
        let enforcer = SharedCacheLimitEnforcer(preferences: p, context: { context }, root: {
            recorded.rootReads += 1
            return root
        }, retryDelay: .milliseconds(20)) { limit, protected, folder in
            recorded.append(limit, protected, folder)
            var outcome = SharedCacheLimit.Outcome()
            outcome.removedSources = [URL(fileURLWithPath: "/tmp/evicted.mov")]
            return outcome
        }
        XCTAssertNil(enforcer.schedule())
        enforcer.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorded.rootReads, 0, "At 0 nothing reads the cutcache configuration")
        XCTAssertTrue(recorded.calls.isEmpty)

        let posted = expectation(forNotification: .sidecarCachesDidClear, object: nil) { note in
            (note.object as? Set<URL>) == [URL(fileURLWithPath: "/tmp/evicted.mov")] && note.userInfo?["wholeSidecars"] as? Bool == true
        }
        p.sharedCacheLimitBytes = 5_000_000_000
        await fulfillment(of: [posted], timeout: 5)
        calls = recorded.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, 5_000_000_000)
        XCTAssertEqual(calls.first?.1, [recording])
        XCTAssertEqual(calls.first?.2, root)

        // A cutcache the app saves runs it again; a window still opening a project postpones it.
        context.isSettling = true
        NotificationCenter.default.post(name: .analysisCutcacheDidSave, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorded.calls.count, 1)
        context.isSettling = false
        try await waitUntil { recorded.calls.count == 2 }
    }

    func testClearContextProtectsRecordingsOnlyTheHistoryReferences() throws {
        let directory = try folder()
        let missing = directory.appendingPathComponent("history-only.mov")
        let sequence = directory.appendingPathComponent("Sequence.cut")
        let previous = CutProject.sequence([CutSequenceClip(id: "a", file: missing.lastPathComponent, from: .zero, to: .init(numerator: 1))])
        try CutProject.sequence([]).save(to: sequence, undo: [.init(action: "Delete Clip", project: previous)], redo: [])
        let p = EditorPreferences()
        p.historyLimit = 0
        let sessions = ProjectSessions(preferences: p, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(SidecarClearContext(sessions: sessions).protected.isEmpty)
        XCTAssertTrue(SidecarClearContext(sessions: ProjectSessions(preferences: p, launching: true)).isSettling,
                      "Nothing is evicted before launch has opened its files")
        sessions.openFiles([sequence])
        _ = try XCTUnwrap(sessions.project(at: sequence))
        let context = SidecarClearContext(sessions: sessions)
        XCTAssertFalse(context.isSettling)
        let protected = Set(context.protected.map { $0.resolvingSymlinksInPath().path })
        XCTAssertTrue(protected.contains(missing.resolvingSymlinksInPath().path), "\(protected)")
    }

    // MARK: Settings window

    func testEveryPageOpensWithZeroOneAndTwoProjects() throws {
        _ = NSApplication.shared
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p, openWindow: { _ in })
        var windows: [NSWindow] = []
        defer {
            for session in Array(sessions.sessions.values) { sessions.windowClosed(session) }
            windows.forEach { $0.close() }
        }
        for count in 0...2 {
            if count > 0 {
                let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                windows.append(window)
                sessions.register(sessions.session(for: nil), window: window)
            }
            XCTAssertEqual(sessions.sessions.count, count)
            // Storage reads the shared cutcache configuration and the real stores; its usage list is tested on its own.
            for page in SettingsPage.allCases where page != .storage {
                p.settingsPage = page
                let host = NSHostingView(rootView: SettingsWindow(preferences: p) { SidecarClearContext(sessions: sessions) })
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .resizable],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThanOrEqual(host.fittingSize.width, 640, "\(page.rawValue) with \(count) projects")
                window.close()
            }
        }
        let (locations, _) = try temporaryLocations()
        let host = NSHostingView(rootView: Form { StorageUsageSection(preferences: p, locations: locations) }.formStyle(.grouped))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
        host.layoutSubtreeIfNeeded()
        let automation = NSHostingView(rootView: SettingsAutomationPage(preferences: p, bundleURL: URL(fileURLWithPath: "/tmp/None.app"),
                                                                        executableURL: nil))
        automation.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
        automation.layoutSubtreeIfNeeded()
    }

    func testSearchFindsTheNewShellRows() {
        XCTAssertTrue(SettingsRow.search("copy agent configuration").contains(.agentConfiguration))
        XCTAssertTrue(SettingsRow.search("cli").contains(.cliPath))
        XCTAssertTrue(SettingsRow.search("disk space").contains(.storageUsage))
        XCTAssertEqual(Set(SettingsRow.search("cache").map(\.page)), [.storage])
        XCTAssertEqual(Set(SettingsRow.search("HDR")), [.viewerSDR, .monitorSDR])
        XCTAssertEqual(SettingsRow.search("export tier"), [.tierWarning])
    }
}

/// Collects enforcement calls made off the main actor.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [(Int64, Set<URL>, URL)] = []
    private var storedReads = 0
    var calls: [(Int64, Set<URL>, URL)] { lock.withLock { storedCalls } }
    var rootReads: Int {
        get { lock.withLock { storedReads } }
        set { lock.withLock { storedReads = newValue } }
    }
    func append(_ limit: Int64, _ protected: Set<URL>, _ root: URL) { lock.withLock { storedCalls.append((limit, protected, root)) } }
}
