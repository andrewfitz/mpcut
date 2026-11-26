import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// The multicam editor reads its Settings defaults. Every preference store here is isolated: nil `UserDefaults`.
final class SettingsMulticamWiringTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsMulticam-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures"))
    }

    @MainActor
    private func model(_ supplied: EditorPreferences? = nil, fixture name: String = "ProRes-2997",
                       audio: Bool = false) throws -> MulticamEditorModel {
        let preferences = supplied ?? EditorPreferences()
        preferences.useAnalysisSidecars = false
        let model = MulticamEditorModel(preferences: preferences, draft: ProjectDraft(directory: try temporaryFolder()))
        let url = try fixture(name)
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let stream = audio ? media.audio.first?.stream.index : nil
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path, audioStream: stream), media: media)],
                           opening: "wide", audio: stream.map { .fixed(.init(source: "wide", stream: $0)) } ?? .none)
        return model
    }

    @MainActor
    private func waitUntil(_ seconds: Int = 5, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready())
    }

    // MARK: Export choices

    @MainActor
    func testFactoryPreferencesSeedTodaysExportChoices() {
        let preferences = EditorPreferences()
        for entry in [ExportEntryPoint.multicamSheet, .multicamQueue] {
            for mode in ExportMode.allCases {
                let today = MulticamExportChoices(entry: entry, preferred: mode)
                var seeded = today
                seeded.seed(from: preferences)
                XCTAssertEqual(seeded, today, "\(entry) \(mode)")
            }
            var choices = MulticamExportChoices(entry: entry, preferred: preferences.defaultExportMode)
            choices.seed(from: preferences)
            XCTAssertEqual(choices.container, "mov")
            XCTAssertEqual(choices.audioOutput, .separateTracks)
            XCTAssertEqual(choices.codec, .h264)
            XCTAssertEqual(choices.quality, .balanced)
            choices.mode = .encode
            choices.settle()
            XCTAssertEqual(choices.container, "mov", "Automatic keeps MOV in multicam.")
        }
    }

    @MainActor
    func testChangedPreferencesSeedFreshChoicesAndAnOverrideStaysLocal() {
        let preferences = EditorPreferences()
        preferences.reencodeCodec = .prores
        preferences.proresQuality = .proresHQ
        preferences.reencodeQuality = .highQuality
        preferences.reencodeContainer = .mp4
        preferences.multicamAudioLayout = .downmixStereo

        var choices = MulticamExportChoices(entry: .multicamSheet, preferred: .encode)
        choices.seed(from: preferences)
        XCTAssertEqual(choices.codec, .prores)
        XCTAssertEqual(choices.quality, .proresHQ)
        XCTAssertEqual(choices.audioOutput, .downmixStereo)
        XCTAssertNotEqual(choices.audio, .copyOriginal, "A downmix renders the program sound.")
        XCTAssertEqual(choices.container, "mov", "ProRes stays MOV.")

        // Switching to H.264 starts a standard re-encode, which takes the container preference.
        choices.codec = .h264
        choices.settle()
        XCTAssertEqual(choices.quality, .highQuality)
        XCTAssertEqual(choices.container, "mp4")
        // A container chosen afterwards is kept.
        choices.container = "mov"
        choices.settle()
        XCTAssertEqual(choices.container, "mov")

        // Smart Trim does not take the re-encode container; switching to Re-encode does.
        var smart = MulticamExportChoices(entry: .multicamQueue, preferred: .smart)
        preferences.reencodeCodec = .h264
        smart.seed(from: preferences)
        XCTAssertEqual(smart.container, "mov")
        smart.mode = .encode
        smart.settle()
        XCTAssertEqual(smart.container, "mp4")
    }

    @MainActor
    func testAnIneligibleContainerFallsBackToWhatTheRulesList() {
        let preferences = EditorPreferences()
        preferences.reencodeContainer = .mkv
        var choices = MulticamExportChoices(entry: .multicamSheet, preferred: .encode)
        choices.tracks = .audio
        choices.seed(from: preferences)
        choices.settle()
        XCTAssertTrue(choices.containers().contains(choices.container))
        XCTAssertFalse(choices.encodesStandardVideo())
    }

    // MARK: Editing and playback

    @MainActor
    func testInsertedStillDurationMatchesTodayAndFollowsTheSetting() {
        let preferences = EditorPreferences()
        let model = MulticamEditorModel(preferences: preferences)
        let cadences = [RationalTime(numerator: 1, denominator: 30), .init(numerator: 1, denominator: 25),
                        .init(numerator: 1001, denominator: 30000), .init(numerator: 1001, denominator: 24000)]
        for cadence in cadences {
            // Today's computation, before Settings.
            let today = max(cadence, model.stillFrameBoundary(.init(numerator: 2), cadence: cadence, nearest: true) ?? cadence)
            let timing = model.defaultStillTiming(cadence: cadence)
            XCTAssertEqual(timing.duration, today, "\(cadence)")
            XCTAssertEqual(timing.cadence, cadence)
        }
        XCTAssertEqual(model.defaultStillTiming(cadence: nil).duration, .init(numerator: 2))
        XCTAssertEqual(model.defaultStillTiming(cadence: nil).cadence, .init(numerator: 1, denominator: 30))

        preferences.stillDuration = 3
        XCTAssertEqual(model.defaultStillTiming(cadence: cadences[3]).duration, .init(numerator: 72 * 1001, denominator: 24000))
        // The longest preference is not cut at a thousand frames.
        preferences.stillDuration = EditorPreferences.stillDurationRange.upperBound
        let long = model.defaultStillTiming(cadence: .init(numerator: 1001, denominator: 60000))
        XCTAssertEqual(long.duration.seconds, 600, accuracy: 0.02)
    }

    @MainActor
    func testStartingPlaybackSpeedSeedsANewWindowOnly() {
        let preferences = EditorPreferences()
        XCTAssertEqual(MulticamEditorModel(preferences: preferences).preview.forwardSpeed, .normal)
        preferences.playbackSpeed = .oneAndHalf
        let first = MulticamEditorModel(preferences: preferences)
        XCTAssertEqual(first.preview.forwardSpeed, .oneAndHalf)
        first.preview.selectPlaybackSpeed(.double)
        preferences.playbackSpeed = .half
        XCTAssertEqual(first.preview.forwardSpeed, .double, "An open window keeps its speed.")
        XCTAssertEqual(MulticamEditorModel(preferences: preferences).preview.forwardSpeed, .half)
        XCTAssertEqual(preferences.playbackSpeed, .half, "Choosing a speed in a window never writes the default.")
    }

    @MainActor
    func testJoinPreviewPlaysTheSettingsSecondsAroundTheCut() throws {
        let preferences = EditorPreferences()
        let model = try model(preferences, fixture: "Pause-Quiet", audio: true)
        defer { model.reset() }
        let media = try XCTUnwrap(model.media["wide"])
        let range = try XCTUnwrap(model.project?.range)
        let cut = media.frames[media.frames.count / 2].time
        XCTAssertTrue(model.edit { $0.switches.append(.init(at: cut, angle: "wide")) })

        // Factory: one second each side, as before.
        XCTAssertTrue(model.previewMulticamSwitch(at: cut))
        var review = try XCTUnwrap(model.pauseEdits.review)
        guard case .multicam(var reviewed)? = review.project else { return XCTFail("Missing preview project") }
        XCTAssertEqual(reviewed.assemblyItems?.first?.group,
                       .init(from: max(range.from, try cut.subtracting(.init(numerator: 1))), to: min(range.to, try cut.adding(.init(numerator: 1)))))
        XCTAssertEqual(review.joinMessage, "Review up to one second on each side of the join.")
        model.pauseEdits.review = nil

        preferences.cutPreviewPreroll = 0.25
        preferences.cutPreviewPostroll = 0.5
        XCTAssertTrue(model.previewMulticamSwitch(at: cut))
        review = try XCTUnwrap(model.pauseEdits.review)
        guard case .multicam(let shorter)? = review.project else { return XCTFail("Missing preview project") }
        reviewed = shorter
        XCTAssertEqual(reviewed.assemblyItems?.first?.group,
                       .init(from: try cut.subtracting(.init(numerator: 1, denominator: 4)), to: try cut.adding(.init(numerator: 1, denominator: 2))))
        XCTAssertEqual(review.joinMessage, "Review up to 0.25 seconds before and 0.5 seconds after the join.")
        model.pauseEdits.review = nil
    }

    @MainActor
    func testPauseReviewPlaysThePrerollAndPostroll() async throws {
        let preferences = EditorPreferences()
        let model = try model(preferences, fixture: "Pause-Quiet", audio: true)
        defer { model.reset() }
        model.scanAnalysis(.silence)
        try await waitUntil { model.canApplyPauses }
        let original = try XCTUnwrap(model.assemblyRange(at: 0))
        let pause = try XCTUnwrap(model.multicamPausePlan.first)
        let cut = try XCTUnwrap(pause.removal)

        func reviewedRanges() throws -> [MulticamRange] {
            model.reviewMulticamPause(pause)
            defer { model.pauseEdits.review = nil }
            guard case .multicam(let reviewed)? = model.pauseEdits.review?.project else {
                XCTFail("Missing pause review")
                return []
            }
            return reviewed.assemblyItems?.compactMap(\.group) ?? []
        }

        // Values below the old 0.75 s show that the review follows Settings, before and after separately.
        preferences.cutPreviewPreroll = 0.25
        preferences.cutPreviewPostroll = 0.5
        var ranges = try reviewedRanges()
        XCTAssertEqual(ranges.first?.from, max(original.from, try cut.from.subtracting(.init(numerator: 1, denominator: 4))))
        XCTAssertEqual(ranges.first?.to, cut.from)
        XCTAssertEqual(ranges.last?.from, cut.to)
        XCTAssertEqual(ranges.last?.to, min(original.to, try cut.to.adding(.init(numerator: 1, denominator: 2))))

        // Factory: one second, the planned change from 0.75 s.
        preferences.cutPreviewPreroll = 1
        preferences.cutPreviewPostroll = 1
        ranges = try reviewedRanges()
        XCTAssertEqual(ranges.first?.from, max(original.from, try cut.from.subtracting(.init(numerator: 1))))
        XCTAssertEqual(ranges.last?.to, min(original.to, try cut.to.adding(.init(numerator: 1))))
    }

    // MARK: Export panels

    @MainActor
    func testSavePanelNameFollowsTheProject() throws {
        let empty = MulticamEditorModel(preferences: EditorPreferences())
        XCTAssertEqual(empty.suggestedExportName(container: "mov"), "Multicam.mov")
        let model = try model()
        defer { model.reset() }
        let camera = try XCTUnwrap(model.project?.angles.first)
        XCTAssertEqual(model.suggestedExportName(container: "mp4"), "\(camera.displayName) Multicam.mp4")
        let folder = try temporaryFolder()
        XCTAssertTrue(model.saveProject(to: folder.appendingPathComponent("Interview.cut")))
        XCTAssertEqual(model.suggestedExportName(container: "mov"), "Interview.mov")
    }

    @MainActor
    func testStartFolderKeepsEachRuleOnAutomaticAndFollowsOtherModes() throws {
        let preferences = EditorPreferences()
        let model = try model(preferences)
        defer { model.reset() }
        let automatic = try temporaryFolder(), remembered = try temporaryFolder(), session = try temporaryFolder()
        let chosen = try temporaryFolder()

        // Automatic: the entry point's own rule, and only the folder it already remembers.
        XCTAssertEqual(model.exportStartFolder(automatic: automatic), automatic)
        XCTAssertNil(model.exportStartFolder(automatic: nil))
        XCTAssertEqual(model.exportStartFolder(automatic: nil, remembered: remembered), remembered)
        model.noteExportFolder(session)
        XCTAssertEqual(model.exportStartFolder(automatic: automatic), automatic)

        // Chosen folder starts the session; a folder chosen in a panel wins after that.
        model.exportSessionFolder = nil
        preferences.exportStartFolder = .chosen
        preferences.exportStartFolderPath = chosen.path
        XCTAssertEqual(model.exportStartFolder(automatic: automatic)?.standardizedFileURL, chosen.standardizedFileURL)
        model.noteExportFolder(session)
        XCTAssertEqual(model.exportStartFolder(automatic: automatic), session.standardizedFileURL)
        // An offline chosen folder opens at the automatic location.
        model.exportSessionFolder = nil
        preferences.exportStartFolderPath = chosen.appendingPathComponent("Offline").path
        XCTAssertEqual(model.exportStartFolder(automatic: automatic), automatic)

        // Source folder: the opening camera's recording.
        preferences.exportStartFolder = .source
        let recording = try fixture("ProRes-2997")
        XCTAssertEqual(model.exportStartFolder(automatic: automatic)?.standardizedFileURL,
                       recording.deletingLastPathComponent().standardizedFileURL)
        // Project folder: none for an untitled project, then the saved project's folder.
        preferences.exportStartFolder = .project
        XCTAssertEqual(model.exportStartFolder(automatic: automatic), automatic)
        let projectFolder = try temporaryFolder()
        XCTAssertTrue(model.saveProject(to: projectFolder.appendingPathComponent("Interview.cut")))
        XCTAssertEqual(model.exportStartFolder(automatic: automatic)?.resolvingSymlinksInPath(),
                       projectFolder.resolvingSymlinksInPath())
        // Opening another project starts another session.
        model.noteExportFolder(session)
        model.resetExportQueue()
        XCTAssertNil(model.exportSessionFolder)
    }

    @MainActor
    func testFinishedExportOffersShowInFinderAndRunsTheCompletionActions() async throws {
        let preferences = EditorPreferences()
        let model = MulticamEditorModel(preferences: preferences)
        var revealed: [[URL]] = [], sounds = 0
        model.exportCompletion = ExportCompletion(useSystemNotifications: false, bundleIdentifier: nil, isFrontmost: { true },
                                                  reveal: { revealed.append($0) }, muted: false, playSound: { sounds += 1 },
                                                  openURL: { _ in false })
        let output = try temporaryFolder().appendingPathComponent("Program.mov")
        try Data().write(to: output)

        model.exportFinished(output, title: "Multicam export finished")
        XCTAssertEqual(model.lastExportedURL, output)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(revealed.isEmpty, "Every completion action is off by default.")
        XCTAssertEqual(sounds, 0)

        preferences.revealsFinishedExport = true
        preferences.playsFinishedExportSound = true
        model.exportFinished(output, title: "Multicam export finished")
        try await waitUntil { revealed == [[output]] && sounds == 1 }
    }

    @MainActor
    func testEveryExportKeepsTheMacAwakeUntilItFinishesFailsOrIsCancelled() async throws {
        final class Activities: ActivityProviding, @unchecked Sendable {
            var begun = 0, ended = 0
            func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
                begun += 1
                return NSObject()
            }
            func endActivity(_ activity: NSObjectProtocol) { ended += 1 }
        }
        let model = MulticamEditorModel(preferences: EditorPreferences())
        let activities = Activities()
        model.sleepActivities = activities

        // Work that is not an export does not hold it.
        model.run("Reading…") { _, _ in 1 } onSuccess: { _ in }
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(activities.begun, 0)

        model.run("Exporting…", exporting: true) { _, _ in 1 } onSuccess: { _ in }
        XCTAssertEqual(activities.begun, 1)
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(activities.ended, 1)

        struct Failure: Error {}
        model.run("Exporting…", exporting: true) { _, _ -> Int in throw Failure() } onFailure: { _ in } onSuccess: { _ in }
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(activities.begun, 2)
        XCTAssertEqual(activities.ended, 2)

        model.run("Exporting…", exporting: true) { token, _ -> Int in
            while !token.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            throw CancellationError()
        } onSuccess: { _ in }
        XCTAssertEqual(activities.begun, 3)
        model.cancel()
        try await waitUntil { !model.isBusy && activities.ended == 3 }
    }

    // MARK: Warnings

    @MainActor
    func testScanningScenesAgainAsksOnlyWhileTheWarningIsOn() async throws {
        let preferences = EditorPreferences()
        let model = try model(preferences)
        defer { model.reset() }
        try await waitUntil { model.analysis.canScanScenes(camera: nil) }
        // With no window there is no one to ask, so nothing starts while the question is on.
        model.confirmSceneRestart(paused: false)
        XCTAssertFalse(model.analysis.isScanning(.scenes))
        preferences.suppress(.sceneRescan)
        // Restarting a paused scan discards progress, so it always asks.
        model.confirmSceneRestart(paused: true)
        XCTAssertFalse(model.analysis.isScanning(.scenes))
        model.confirmSceneRestart(paused: false)
        XCTAssertTrue(model.analysis.isScanning(.scenes))
        model.cancelAnalysis(.scenes)
        try await waitUntil { !model.analysis.isScanning(.scenes) }
        preferences.resetAllWarnings()
        XCTAssertTrue(preferences.asks(.sceneRescan))
    }

    // MARK: Agent write guard

    @MainActor
    func testAgentSnapIsRefusedWhileAgentsCannotChangeSettings() async throws {
        let preferences = EditorPreferences()
        let model = try model(preferences)
        defer { model.reset() }
        preferences.agentsChangeSettings = false
        do {
            _ = try await model.mcpCommand(tool: "multicam_preview_control", arguments: ["action": "snap", "target": "scenes"]) {}
            XCTFail("The agent route should refuse.")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "settings_write_disabled")
        }
        XCTAssertEqual(preferences.snapTarget, .off)
        XCTAssertEqual(model.analysis.snapTarget, .off)
        // Reads and transport still work for the agent.
        _ = try await model.mcpCommand(tool: "multicam_preview_control", arguments: ["action": "start"]) {}

        // The editor's own controls keep working with the switch off.
        model.setAnalysisSnap(.scenes)
        XCTAssertEqual(preferences.snapTarget, .scenes)
        model.preview.volume = 0.5
        model.preview.isMuted = true
        model.preview.scrubSoundEnabled = false
        XCTAssertEqual(preferences.volume, 0.5)
        XCTAssertTrue(preferences.isMuted)
        XCTAssertFalse(preferences.scrubSoundEnabled)

        preferences.agentsChangeSettings = true
        _ = try await model.mcpCommand(tool: "multicam_preview_control", arguments: ["action": "snap", "target": "keyframes"]) {}
        XCTAssertEqual(preferences.snapTarget, .keyframes)
    }

    // MARK: Automatic scans

    @MainActor
    func testAddedRecordingsScanOnlyWhenSettingsAskAndACancelledScanStaysCancelled() async throws {
        // Off: adding a recording starts nothing, as before.
        let off = try model(fixture: "Pause-Quiet", audio: true)
        defer { off.reset() }
        XCTAssertFalse(off.analysis.isScanning(.silence))
        XCTAssertFalse(off.analysis.isScanning(.scenes))
        XCTAssertFalse(off.analysis.hasAutomaticScansWaiting)

        let preferences = EditorPreferences()
        preferences.autoScanScenes = true
        preferences.autoScanSilence = true
        let model = try model(preferences, fixture: "Pause-Quiet", audio: true)
        defer { model.reset() }
        // Both scans start without a menu command. The fixture is short, so either may already have finished.
        try await waitUntil {
            (model.analysis.isScanning(.scenes) || !model.analysis.sceneReports.isEmpty)
                && (model.analysis.isScanning(.silence) || model.analysis.hasResults(model))
        }
        XCTAssertFalse(model.analysis.hasAutomaticScansWaiting)
        model.cancelAnalysis(.silence)
        model.cancelAnalysis(.scenes)
        try await waitUntil { !model.analysis.isScanning(.scenes) && !model.analysis.isScanning(.silence) }

        // A later edit does not start them again.
        let range = try XCTUnwrap(model.project?.range)
        let end = try range.to.subtracting(.init(numerator: 1))
        XCTAssertTrue(model.edit("Trim") { $0.assembly = [.init(from: range.from, to: end)] })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.analysis.isScanning(.silence))
        XCTAssertFalse(model.analysis.isScanning(.scenes))
    }

    @MainActor
    func testAnAutomaticScanWaitsForTheRecordingsMedia() throws {
        let url = try fixture("Pause-Quiet")
        let media = try CutEngine(useSidecar: false).inspect(url, keyframes: true)
        let track = try XCTUnwrap(media.audio.first?.stream.index)
        let route = MulticamAudioSelection(source: "wide", stream: track)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: media.duration),
                                      angles: [.init(id: "wide", file: url.path, audioStream: track)], audio: .none,
                                      switches: [.init(at: .zero, angle: "wide", audio: route)])
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: [:], ordinary: [:], useSidecars: false)
        analysis.requestAutomaticScans(of: ["wide"], scenes: true, pauses: true)
        XCTAssertTrue(analysis.hasAutomaticScansWaiting)
        XCTAssertFalse(analysis.isScanning(.silence))
        analysis.update(project: project, media: ["wide": media], ordinary: ["wide": media], useSidecars: false)
        XCTAssertFalse(analysis.hasAutomaticScansWaiting)
        XCTAssertTrue(analysis.isScanning(.silence))
        XCTAssertTrue(analysis.isScanning(.scenes))

        // Stopping a scan drops what still waits for it.
        analysis.requestAutomaticScans(of: ["later"], scenes: true, pauses: true)
        analysis.dropAutomaticScans(.scenes)
        analysis.dropAutomaticScans(.silence)
        XCTAssertFalse(analysis.hasAutomaticScansWaiting)
    }
}

private extension MulticamAnalysisStore {
    func hasResults(_ model: MulticamEditorModel) -> Bool {
        guard let project = model.project else { return false }
        return hasSilenceResults(project: project, media: model.media)
    }
}
