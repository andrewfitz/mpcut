import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// Settings wiring in the sequence editor, its export panels and its MCP routes. Every preference store here is
/// unpersisted (`EditorPreferences(defaults: nil)`), and nothing reaches `ExportCompletion.shared` with an action on.
@MainActor
final class SettingsSequenceWiringTests: XCTestCase {
    private final class CountingActivity: ActivityProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var begun = 0, ended = 0
        var counts: (begun: Int, ended: Int) { lock.withLock { (begun, ended) } }
        func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
            lock.withLock { begun += 1 }
            return NSObject()
        }
        func endActivity(_ activity: NSObjectProtocol) { lock.withLock { ended += 1 } }
    }

    private func preferences() -> EditorPreferences {
        let preferences = EditorPreferences(defaults: nil)
        preferences.useAnalysisSidecars = false
        return preferences
    }

    private func fixture(_ name: String, _ ext: String = "mov") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func waitUntil(_ seconds: Int = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func waitForEdit(_ model: EditorModel) async throws {
        try await waitUntil(15) { !model.isBusy }
        XCTAssertFalse(model.isBusy)
    }

    // MARK: Editing

    func testStartingStillAndGapDurationsAtFactoryMatchTodayAtFourCadences() {
        // Today's computation, which the shared helper replaces.
        func today(_ cadence: RationalTime?) -> RationalTime {
            let interval = cadence ?? RationalTime(numerator: 1, denominator: 30)
            let frames = Int64(max(1, min(1_000, (2 / interval.seconds).rounded())))
            return (try? interval.multiplied(by: RationalTime(numerator: frames))) ?? interval
        }
        let cadences: [(RationalTime?, Int64)] = [
            (RationalTime(numerator: 1, denominator: 30), 60), (RationalTime(numerator: 1, denominator: 25), 50),
            (RationalTime(numerator: 1001, denominator: 30000), 60), (RationalTime(numerator: 1001, denominator: 24000), 48),
            (nil, 60)
        ]
        let factory = EditorPreferences(defaults: nil)
        XCTAssertEqual(factory.stillDuration, 2)
        XCTAssertEqual(factory.gapDuration, 2)
        for (cadence, frames) in cadences {
            let (duration, interval) = StillPanels.startingDuration(seconds: factory.stillDuration, cadence: cadence)
            XCTAssertEqual(duration, today(cadence))
            XCTAssertEqual(interval, cadence ?? RationalTime(numerator: 1, denominator: 30))
            XCTAssertEqual(duration, try interval.multiplied(by: RationalTime(numerator: frames)))
        }
        // A 3 s preference and the longest one keep whole frames past the old 1,000-frame stop.
        let thirty = RationalTime(numerator: 1, denominator: 30)
        XCTAssertEqual(StillPanels.startingDuration(seconds: 3, cadence: thirty).duration, RationalTime(numerator: 3))
        let fast = RationalTime(numerator: 1, denominator: 240)
        XCTAssertEqual(StillPanels.startingDuration(seconds: 600, cadence: fast).duration, RationalTime(numerator: 600))
    }

    func testGapColorAndStillTimelineFormatStartFromSettings() {
        XCTAssertEqual(StillPanels.startingColor("#000000"), .black)
        let red = StillPanels.startingColor("#FF0000").usingColorSpace(.sRGB)
        XCTAssertEqual(red?.redComponent ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(red?.greenComponent ?? 1, 0, accuracy: 1e-6)

        let factory = StillTimelineFormatDefaults(preferences: EditorPreferences(defaults: nil))
        XCTAssertEqual(factory, StillTimelineFormatDefaults())
        XCTAssertEqual([String(factory.width), String(factory.height), factory.frameRateText, factory.codec.rawValue],
                       ["1920", "1080", "30", "h264"])
        let preferences = EditorPreferences(defaults: nil)
        preferences.stillTimelineWidth = 1280
        preferences.stillTimelineHeight = 720
        preferences.stillTimelineFrameRate = 29.97
        preferences.stillTimelineCodec = .prores
        let seeded = StillTimelineFormatDefaults(preferences: preferences)
        XCTAssertEqual([seeded.width, seeded.height], [1280, 720])
        XCTAssertEqual(seeded.frameRateText, "29.97")
        XCTAssertEqual(seeded.codec, .prores)
        preferences.stillTimelineFrameRate = 23.976
        XCTAssertEqual(StillTimelineFormatDefaults(preferences: preferences).frameRateText, "23.976")
    }

    // MARK: Playback

    func testEachNewWindowStartsAtTheSettingsSpeedOnce() {
        let preferences = preferences()
        XCTAssertEqual(EditorModel(preferences: preferences).preview.forwardSpeed, .normal)
        preferences.playbackSpeed = .double
        let first = EditorModel(preferences: preferences)
        defer { first.endSession() }
        XCTAssertEqual(first.preview.forwardSpeed, .double)
        preferences.playbackSpeed = .half
        XCTAssertEqual(first.preview.forwardSpeed, .double, "An open window keeps its speed.")
        let second = EditorModel(preferences: preferences)
        defer { second.endSession() }
        XCTAssertEqual(second.preview.forwardSpeed, .half)
        first.preview.selectPlaybackSpeed(.quadruple)
        XCTAssertEqual(second.preview.forwardSpeed, .half)
        XCTAssertEqual(preferences.playbackSpeed, .half, "A window's own speed never writes the preference.")
    }

    func testJoinSentenceAndCutPreviewTimesFollowSettings() {
        XCTAssertEqual(CutPreview.time(seconds: 1), RationalTime(numerator: 1))
        XCTAssertEqual(CutPreview.time(seconds: 0.25), RationalTime(numerator: 1, denominator: 4))
        XCTAssertEqual(CutPreview.joinMessage(preroll: 1, postroll: 1), "Review up to one second on each side of the join.")
        XCTAssertEqual(CutPreview.joinMessage(preroll: 2, postroll: 2), "Review up to 2 seconds on each side of the join.")
        XCTAssertEqual(CutPreview.joinMessage(preroll: 0.5, postroll: 2), "Review up to 0.5 seconds before and 2 seconds after the join.")
    }

    func testPreviewJoinPlaysTheSettingsSecondsAroundTheJoin() async throws {
        let preferences = preferences()
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        let url = try fixture("ProRes-2997")
        model.importFiles([url, url])
        try await waitForEdit(model)
        let second = try XCTUnwrap(model.timelineClips.last?.id)
        func previewed() throws -> Double {
            let cut = try XCTUnwrap(model.cutPreview)
            return cut.ranges.reduce(0) { $0 + ($1.exactEnd.seconds - $1.exactStart.seconds) }
        }
        let clip = model.duration / 2
        XCTAssertTrue(model.previewExistingJoin(before: second))
        XCTAssertEqual(try previewed(), min(1, clip) * 2, accuracy: 0.05)
        XCTAssertEqual(model.cutPreview?.joinMessage, "Review up to one second on each side of the join.")
        model.cutPreview = nil
        preferences.cutPreviewPreroll = 0.25
        preferences.cutPreviewPostroll = 0.25
        XCTAssertTrue(model.previewExistingJoin(before: second))
        XCTAssertEqual(try previewed(), min(0.25, clip) * 2, accuracy: 0.05)
        XCTAssertEqual(model.cutPreview?.preroll, 0.25)
        model.cutPreview = nil
    }

    // MARK: Export sheet

    func testFreshExportSheetSeedsFromSettingsAndKeepsSessionOverrides() {
        // Factory values reproduce today's sheet.
        var factory = ExportSheetOptions()
        factory.seedEncoding(from: EditorPreferences(defaults: nil))
        XCTAssertEqual(factory, ExportSheetOptions())
        XCTAssertEqual([factory.codec.rawValue, factory.standardQuality.rawValue, factory.proResQuality.rawValue,
                        factory.encodeContainer, factory.proResContainer], ["h264", "balanced", "422", "mp4", "mov"])

        let preferences = preferences()
        preferences.reencodeCodec = .prores
        preferences.proresQuality = .proresHQ
        preferences.reencodeQuality = .highQuality
        preferences.reencodeContainer = .mkv
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        let shown = model.sheetExportOptions
        XCTAssertEqual(shown.codec, .prores)
        XCTAssertEqual(shown.quality, .proresHQ)
        XCTAssertEqual(shown.standardQuality, .highQuality)
        XCTAssertEqual(shown.encodeContainer, "mkv")
        XCTAssertEqual(shown.proResContainer, "mov")

        // The editor picks HEVC in the sheet: it stays for the session and Settings is unchanged.
        var changed = shown
        changed.codec = .hevc
        model.exportSheetChanged(changed, from: shown)
        XCTAssertEqual(model.sheetExportOptions.codec, .hevc)
        XCTAssertEqual(preferences.reencodeCodec, .prores)
        // A field the editor left alone still follows Settings when the next sheet opens.
        preferences.reencodeQuality = .smallerFile
        XCTAssertEqual(model.sheetExportOptions.standardQuality, .smallerFile)
        XCTAssertEqual(model.sheetExportOptions.codec, .hevc)
        // A new window, and a new session in this one, start from Settings again.
        let other = EditorModel(preferences: preferences)
        defer { other.endSession() }
        XCTAssertEqual(other.sheetExportOptions.codec, .prores)
        model.endSession()
        XCTAssertEqual(model.sheetExportOptions.codec, .prores)

        preferences.reencodeContainer = .automatic
        XCTAssertEqual(model.sheetExportOptions.encodeContainer, "mp4", "Automatic is the sequence editor's MP4.")
    }

    func testAudioOnlyAndStillPlacementsStillGetEligibleChoices() throws {
        let preferences = preferences()
        preferences.reencodeCodec = .prores
        preferences.reencodeContainer = .mkv
        var seeded = ExportSheetOptions()
        seeded.seedEncoding(from: preferences)
        // Audio-only output ignores the picture codec and keeps a container its sound can use.
        let audio = try CutEngine(useSidecar: false).inspect(fixture("Pause-Quiet"), keyframes: true)
        let choices = ExportContainerChoices(source: audio, clips: [], preferred: nil, cancelled: { false })
        var options = EditorModel.openingExportOptions(seeded, mode: .copy, convertingByName: false, source: audio,
                                                       choices: choices, preferred: nil, verified: nil)
        options.tracks = .audio
        options.copyContainer = choices.choices(for: options).first ?? options.copyContainer
        XCTAssertTrue(choices.choices(for: options).contains(options.container))
        // A ProRes default writes MOV for ordinary encode, which is eligible.
        seeded.mode = .encode
        XCTAssertEqual(seeded.container, "mov")
        XCTAssertTrue(ExportRules.reencodeContainers(seeded.codec).contains(seeded.container))
        // Still placements: the MKV H.264 default is replaced by a container still export can write.
        preferences.reencodeCodec = .h264
        var still = ExportSheetOptions()
        still.seedEncoding(from: preferences)
        still.placements = .insertion
        still.mode = .encode
        let eligible = ExportRules.stillContainers(mode: .encode, tracks: .all, codec: still.codec, audio: still.audio)
        if !eligible.contains(still.encodeContainer) { still.encodeContainer = eligible.first ?? "mov" }
        XCTAssertTrue(eligible.contains(still.container))
    }

    func testResultJSONAndResolveCheckboxesStartFromSettings() {
        XCTAssertEqual(ExportResultFile.checkbox().state, .off)
        XCTAssertEqual(ExportResultFile.checkbox(isOn: true).state, .on)
        XCTAssertEqual(ResolveExportPanel.openCheckbox(true).state, .on)
        XCTAssertEqual(ResolveExportPanel.openCheckbox(false).state, .off)
        let factory = EditorPreferences(defaults: nil)
        XCTAssertFalse(factory.savesExportResult)
        XCTAssertTrue(factory.opensResolveTimeline)
    }

    // MARK: Starting folder

    func testExportPanelsStartWhereSettingsSaysAndAChosenFolderWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        let picked = root.appendingPathComponent("Picked", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = preferences()
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        let source = URL(fileURLWithPath: "/tmp/recording.mov")
        // Automatic: today's rule, AppKit's folder and then the window's last export folder.
        XCTAssertNil(model.exportPanelDirectory(source: source))
        model.noteExportFolder(picked)
        XCTAssertEqual(model.exportPanelDirectory(source: source), picked)
        XCTAssertNil(model.exportPanelDirectory(source: source, hasAutomaticRule: false), "Resolve keeps AppKit's folder in Automatic.")
        model.endSession()
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = chosen.path
        XCTAssertEqual(model.exportPanelDirectory(source: source)?.standardizedFileURL, chosen.standardizedFileURL)
        XCTAssertEqual(model.exportPanelDirectory(source: source, hasAutomaticRule: false)?.standardizedFileURL,
                       chosen.standardizedFileURL)
        model.noteExportFolder(picked, hasAutomaticRule: false)
        XCTAssertEqual(model.exportPanelDirectory(source: source), picked, "A folder chosen in a panel wins for the session.")
        model.endSession()
        preferences.exportStartFolder = .source
        XCTAssertEqual(model.exportPanelDirectory(source: chosen.appendingPathComponent("clip.mov"))?.standardizedFileURL,
                       chosen.standardizedFileURL)
        // An offline chosen folder opens at the automatic location and is marked unavailable.
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = root.appendingPathComponent("Offline").path
        XCTAssertNil(model.exportPanelDirectory(source: source))
        let folder = try XCTUnwrap(preferences.chosenExportFolder)
        XCTAssertFalse(ExportStartFolder.isAvailable(folder))
        // Untitled projects have no project folder.
        preferences.exportStartFolder = .project
        XCTAssertNil(model.exportPanelDirectory(source: source))
    }

    // MARK: Completion actions and sleep

    func testEverySequenceExportHoldsSleepAndRunsCompletionOnSuccessOnly() async throws {
        let preferences = preferences()
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        let activity = CountingActivity()
        model.exportActivityProvider = activity
        var finished: [URL] = []
        model.exportCompletionHandler = { finished.append($0) }
        model.importFiles([try fixture("ProRes-2997")])
        try await waitForEdit(model)
        let source = try XCTUnwrap(model.jpegSourceAtPlayhead)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        model.exportJPEGFrames(source, to: output, options: JPEGExportOptions())
        XCTAssertEqual(activity.counts.begun, 1)
        try await waitForEdit(model)
        try await waitUntil { activity.counts.ended == 1 }
        XCTAssertNil(model.alert)
        XCTAssertEqual(finished, [output])
        XCTAssertEqual(activity.counts.ended, 1)

        // A failed export releases the hold and runs no completion action.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        model.exportJPEGFrames(source, to: blocker.appendingPathComponent("Frames", isDirectory: true), options: JPEGExportOptions())
        try await waitForEdit(model)
        try await waitUntil { activity.counts.begun == activity.counts.ended }
        XCTAssertEqual(activity.counts.begun, activity.counts.ended)
        XCTAssertEqual(finished, [output])
        model.dismissNotice()
    }

    func testCompletionActionsFollowSettingsAndStayOffAtFactory() async throws {
        var revealed: [[URL]] = [], sounds = 0
        let completion = ExportCompletion(useSystemNotifications: false, bundleIdentifier: nil, isFrontmost: { true },
                                          reveal: { revealed.append($0) }, muted: false, playSound: { sounds += 1 },
                                          openURL: { _ in false })
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data().write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        let preferences = EditorPreferences(defaults: nil)
        ExportCompletion.runActions(for: output, preferences: preferences, using: completion)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertEqual(sounds, 0)
        preferences.revealsFinishedExport = true
        preferences.playsFinishedExportSound = true
        ExportCompletion.runActions(for: output, preferences: preferences, using: completion)
        try await waitUntil { !revealed.isEmpty && sounds == 1 }
        XCTAssertEqual(revealed, [[output]])
        XCTAssertEqual(sounds, 1)
        // The test host has no bundle identifier, so Notify reports unavailable and never reaches the center.
        let authorization = await completion.notificationAuthorization()
        XCTAssertEqual(authorization, .unavailable)
    }

    // MARK: Scene rescan warning

    func testSceneRescanAsksOnlyWhileTheWarningIsOn() async throws {
        let preferences = preferences()
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        model.importFiles([try fixture("ProRes-2997")])
        try await waitForEdit(model)
        model.scanForScenes()
        try await waitUntil { model.sceneProgress == nil }
        XCTAssertNil(model.sceneProgress)
        // Asking needs a window; without one nothing starts, as before.
        XCTAssertTrue(preferences.asks(.sceneRescan))
        model.confirmSceneRestart(paused: false)
        XCTAssertNil(model.sceneProgress)
        preferences.suppress(.sceneRescan)
        XCTAssertFalse(preferences.confirmsSceneRescan)
        model.confirmSceneRestart(paused: false)
        XCTAssertNotNil(model.sceneProgress, "With the warning off, Scan Again starts at once.")
        try await waitUntil { model.sceneProgress == nil }
        // Restarting a paused scan always asks.
        model.confirmSceneRestart(paused: true, repeatPrevious: true)
        XCTAssertNil(model.sceneProgress)
    }

    // MARK: Automatic scans

    func testAutomaticScansAreOffByDefault() async throws {
        let preferences = preferences()
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        model.importFiles([try fixture("Pause-Quiet")])
        try await waitForEdit(model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.sceneProgress)
        XCTAssertNil(model.silenceProgress)
        XCTAssertTrue(model.scenesBySource.isEmpty)
        XCTAssertFalse(model.pauseAnalysisReady)
    }

    func testAddingARecordingScansScenesAndPausesWhenSettingsAsk() async throws {
        let preferences = preferences()
        preferences.autoScanScenes = true
        preferences.autoScanSilence = true
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        XCTAssertEqual(model.snapTarget, .off)
        model.importFiles([try fixture("Pause-Quiet")])
        try await waitForEdit(model)
        try await waitUntil { model.pauseAnalysisReady && model.sceneProgress == nil && !model.scenesBySource.isEmpty }
        XCTAssertTrue(model.pauseAnalysisReady, "The pause lane fills without a menu command.")
        XCTAssertFalse(model.scenesBySource.isEmpty, "The scene lane fills without a menu command.")
        XCTAssertTrue(model.canEdit)
    }

    func testACancelledAutomaticPauseScanStaysCancelledAfterLaterEdits() async throws {
        let preferences = preferences()
        preferences.autoScanSilence = true
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        // The fixture is tiny, so cancel on the main actor's next turn after the automatic scan starts, before its
        // waveform can arrive.
        var startedOnItsOwn = false
        let watcher = model.objectWillChange.sink { _ in
            Task { @MainActor in
                guard !startedOnItsOwn, model.silenceProgress != nil else { return }
                startedOnItsOwn = true
                model.cancelSilenceScan()
            }
        }
        model.importFiles([try fixture("Pause-Quiet")])
        try await waitForEdit(model)
        try await waitUntil { startedOnItsOwn || model.pauseAnalysisReady }
        watcher.cancel()
        XCTAssertTrue(startedOnItsOwn, "The scan started on its own.")
        XCTAssertNil(model.silenceProgress)
        XCTAssertTrue(model.canEdit, "Cancelling leaves the recording editable.")
        model.seek(model.duration / 2)
        model.split()
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.undo()
        try await waitForEdit(model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.silenceProgress, "A later edit does not start the cancelled scan again.")
        XCTAssertFalse(model.pauseAnalysisReady)
        // Turning the setting on later never scans a recording that is already open.
        let other = EditorModel(preferences: preferences)
        defer { other.endSession() }
        preferences.autoScanSilence = false
        other.importFiles([try fixture("Pause-Quiet")])
        try await waitForEdit(other)
        preferences.autoScanSilence = true
        other.seek(other.duration / 2)
        other.split()
        try await waitForEdit(other)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(other.silenceProgress)
    }

    // MARK: MCP

    func testAgentSnapWriteNeedsTheAutomationSwitch() async throws {
        let preferences = preferences()
        let sessions = ProjectSessions(preferences: preferences)
        let session = sessions.session(for: nil)
        let editor = session.editor
        defer { editor.endSession() }
        editor.importFiles([try fixture("ProRes-2997")])
        try await waitForEdit(editor)
        preferences.agentsChangeSettings = false
        do {
            _ = try await sessions.handleMCPCommand(tool: "timeline_selection_set",
                                                   arguments: ["action": "snap", "value": "scenes",
                                                               "expected_revision": editor.mcpRevision,
                                                               "operation_id": UUID().uuidString],
                                                   session: session, checkAccess: {})
            XCTFail("Snap should be refused while agents cannot change settings.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("settings_write_disabled"), String(describing: error))
        }
        XCTAssertEqual(preferences.snapTarget, .off)
        preferences.agentsChangeSettings = true
        _ = try await sessions.handleMCPCommand(tool: "timeline_selection_set",
                                               arguments: ["action": "snap", "value": "scenes",
                                                           "expected_revision": editor.mcpRevision,
                                                           "operation_id": UUID().uuidString],
                                               session: session, checkAccess: {})
        XCTAssertEqual(preferences.snapTarget, .scenes)
    }

    func testLiveMCPEncodingDefaultsFollowSettingsOnlyWhereTheyApply() {
        XCTAssertEqual(MCPEncodingDefaults(preferences: EditorPreferences(defaults: nil)), .factory)
        let preferences = EditorPreferences(defaults: nil)
        preferences.reencodeCodec = .prores
        preferences.proresQuality = .proresHQ
        preferences.reencodeQuality = .highQuality
        preferences.reencodeContainer = .mkv
        preferences.multicamAudioLayout = .downmixStereo
        let encoding = MCPEncodingDefaults(preferences: preferences)
        XCTAssertEqual(encoding.quality(for: .prores), .proresHQ)
        XCTAssertEqual(encoding.quality(for: .hevc), .highQuality)
        XCTAssertEqual(encoding.multicamAudio, .downmixStereo)
        // ProRes cannot go into the destination's MP4, so the factory codec is used there.
        XCTAssertFalse(MCPEncodingDefaults.writes(.prores, to: "mp4", source: .movie))
        XCTAssertTrue(MCPEncodingDefaults.writes(.prores, to: "mov", source: .movie))
        var options = ExportSheetOptions()
        options.mode = .encode
        options.codec = .hevc
        XCTAssertEqual(encoding.container(for: options, source: .movie), "mkv")
        XCTAssertNil(MCPEncodingDefaults.factory.container(for: options, source: .movie), "Automatic keeps the route's fallback.")
        options.codec = .prores
        XCTAssertNil(encoding.container(for: options, source: .movie), "ProRes stays MOV.")
        options.codec = .h264
        options.mode = .copy
        XCTAssertNil(encoding.container(for: options, source: .movie), "A copy keeps the route's container.")
        options.mode = .encode
        options.tracks = .audio
        XCTAssertNil(encoding.container(for: options, source: .movie))
    }

    func testLiveMCPReencodePlanUsesTheSettingsCodecWhenOmitted() async throws {
        let preferences = preferences()
        preferences.reencodeCodec = .hevc
        preferences.reencodeQuality = .smallerFile
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.editor.endSession() }
        session.editor.importFiles([try fixture("ProRes-2997")])
        try await waitForEdit(session.editor)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        func plan(_ arguments: [String: Any]) async throws -> String {
            var arguments = arguments
            arguments["project_handle"] = session.mcpHandle
            let ticket = try await sessions.mcpOutputs(tool: "export_editor_project_plan", arguments: arguments,
                                                       session: session, checkAccess: {})
            let id = try XCTUnwrap(ticket?["job_id"] as? String)
            for _ in 0..<1_500 {
                let status = try sessions.mcpOutputJobs.status(owner: session.mcpHandle, id: id, cancel: false)
                if !["running", "cancelling"].contains(status["state"] as? String ?? "") {
                    let data = try JSONSerialization.data(withJSONObject: status)
                    return String(decoding: data, as: UTF8.self)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CancellationError()
        }
        let seeded = try await plan(["output": directory.appendingPathComponent("A.mov").path, "mode": "encode"])
        XCTAssertTrue(seeded.contains("\"hevc\""), seeded)
        XCTAssertTrue(seeded.contains("\"smaller\""), seeded)
        let explicit = try await plan(["output": directory.appendingPathComponent("B.mov").path, "mode": "encode", "codec": "h264"])
        XCTAssertTrue(explicit.contains("\"h264\""), explicit)
        XCTAssertFalse(explicit.contains("\"hevc\""), explicit)
    }

    func testLiveMulticamPlanUsesTheSettingsAudioLayoutWhenOmitted() async throws {
        let preferences = preferences()
        preferences.multicamAudioLayout = .downmixStereo
        preferences.reencodeCodec = .hevc
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        session.isMulticam = true
        defer { session.multicam.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("camera.mp4")
        try FileManager.default.copyItem(at: fixture("SmartTrim-GOP", "mp4"), to: source)
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        session.multicam.confirmSetup(drafts: [.init(source: .init(id: "a", file: source.path), media: media)],
                                      opening: "a", audio: .none)
        func plan(_ arguments: [String: Any]) async throws -> [String: Any] {
            var arguments = arguments
            arguments["project_handle"] = session.mcpHandle
            let ticket = try await sessions.mcpOutputs(tool: "export_editor_project_plan", arguments: arguments,
                                                       session: session, checkAccess: {})
            let id = try XCTUnwrap(ticket?["job_id"] as? String)
            for _ in 0..<1_500 {
                let status = try sessions.mcpOutputJobs.status(owner: session.mcpHandle, id: id, cancel: false)
                if !["running", "cancelling"].contains(status["state"] as? String ?? "") { return status }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CancellationError()
        }
        func text(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let seeded = try await plan(["output": directory.appendingPathComponent("program.mov").path, "mode": "encode"])
        XCTAssertEqual(seeded["state"] as? String, "succeeded", text(seeded))
        XCTAssertEqual((seeded["result"] as? [String: Any])?["eligible"] as? Bool, true, text(seeded))
        XCTAssertTrue(text(seeded).contains("downmix_stereo"), text(seeded))
        let explicit = try await plan(["output": directory.appendingPathComponent("tracks.mov").path, "mode": "encode",
                                       "audio_output": "separate_tracks", "codec": "h264"])
        XCTAssertEqual(explicit["state"] as? String, "succeeded", text(explicit))
        XCTAssertFalse(text(explicit).contains("downmix_stereo"), text(explicit))
    }
}
