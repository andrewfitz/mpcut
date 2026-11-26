import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// Settings → Media & Analysis → Scan for pauses when a recording is added. The automatic scan reads only the
/// recordings just added, never one whose scan the editor cancelled, and it stops when the switch is off. The menu
/// command and Snap to Silence keep scanning every recording. Every preference store here is unpersisted.
@MainActor
final class SettingsFix2ScanTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        try await super.tearDown()
    }

    /// Two distinct recordings with the same content, so each is its own source.
    private func recordings(_ names: [String]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsFix2Scan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        return try names.map { name in
            let url = folder.appendingPathComponent(name + ".mov")
            try FileManager.default.copyItem(at: fixture, to: url)
            return url
        }
    }

    private func waitUntil(_ seconds: Int = 15, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func sourceID(_ model: EditorModel, _ url: URL) throws -> UUID {
        let wanted = url.resolvingSymlinksInPath().standardizedFileURL.path
        return try XCTUnwrap(model.analysisSourceMedia.first {
            $0.value.url.resolvingSymlinksInPath().standardizedFileURL.path == wanted
        }?.key, "No source for \(url.lastPathComponent)")
    }

    // MARK: Sequence editor

    func testSequenceAutomaticPauseScanReadsOnlyTheAddedRecording() async throws {
        let preferences = EditorPreferences(defaults: nil)
        preferences.useAnalysisSidecars = false
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        let urls = try recordings(["A", "B"])
        model.importFiles([urls[0]])
        try await waitUntil { !model.isBusy }
        let a = try sourceID(model, urls[0])
        // The editor starts a pause scan on A and cancels it before anything is detected.
        XCTAssertTrue(model.canScanSilence)
        model.scanForSilence()
        model.cancelSilenceScan()
        XCTAssertNil(model.silenceProgress)

        preferences.autoScanSilence = true
        model.importFiles([urls[1]])
        try await waitUntil { !model.isBusy }
        let b = try sourceID(model, urls[1])
        try await waitUntil { !model.completedSilences(for: b).isEmpty && model.silenceProgress == nil }
        XCTAssertFalse(model.completedSilences(for: b).isEmpty, "The added recording is scanned without a menu command.")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.completedSilences(for: a).isEmpty, "A recording whose scan was cancelled stays unscanned.")
        XCTAssertNil(model.silenceProgress, "The automatic scan finishes with A still unscanned.")
        XCTAssertFalse(model.pauseAnalysisReady)
        XCTAssertFalse(model.pausePlan.isEmpty, "B's pauses reach the pause plan while A stays unscanned.")

        // A later edit does not scan A either.
        model.seek(model.duration / 4)
        model.split()
        try await waitUntil { !model.isBusy }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.completedSilences(for: a).isEmpty)
        XCTAssertNil(model.silenceProgress)

        // The menu command still scans every recording.
        XCTAssertTrue(model.canScanSilence)
        model.scanForSilence()
        try await waitUntil { model.pauseAnalysisReady }
        XCTAssertTrue(model.pauseAnalysisReady)
        XCTAssertFalse(model.completedSilences(for: a).isEmpty)
    }

    // MARK: Multicam

    private func multicamProject(_ urls: [URL], ids: [String]) throws -> (MulticamProject, [String: MediaInfo], [MulticamRange]) {
        var media: [String: MediaInfo] = [:]
        var angles: [MulticamSource] = []
        var switches: [MulticamSwitch] = []
        var ranges: [MulticamRange] = []
        let first = try CutEngine(useSidecar: false).inspect(urls[0], keyframes: true)
        let frames = first.frames.map(\.time)
        // Each recording takes an equal share of the group, at a frame boundary, with its own sound.
        let starts = ids.indices.map { frames[frames.count * $0 / ids.count] }
        for (index, (url, id)) in zip(urls, ids).enumerated() {
            let info = try CutEngine(useSidecar: false).inspect(url, keyframes: true)
            media[id] = info
            let track = try XCTUnwrap(info.audio.first?.stream.index)
            angles.append(.init(id: id, file: url.path, audioStream: track))
            switches.append(.init(at: starts[index], angle: id, audio: .init(source: id, stream: track)))
            ranges.append(.init(from: starts[index], to: index + 1 < starts.count ? starts[index + 1] : first.duration))
        }
        let project = MulticamProject(referenceAngle: ids[0], range: .init(from: .zero, to: first.duration),
                                      angles: angles, audio: .none, switches: switches)
        return (project, media, ranges)
    }

    func testMulticamAutomaticPauseScanReadsOnlyTheAddedRecordingAndThenStops() async throws {
        let urls = try recordings(["A", "B", "C"])
        let (project, media, ranges) = try multicamProject(Array(urls.prefix(2)), ids: ["a", "b"])
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        // The editor starts a pause scan and cancels it before anything is detected.
        analysis.scan(.silence)
        analysis.cancel(.silence)
        XCTAssertFalse(analysis.isScanning(.silence))

        // B was just added with the switch on.
        analysis.requestAutomaticScans(of: ["b"], scenes: false, pauses: true)
        XCTAssertTrue(analysis.isScanning(.silence))
        try await waitUntil { !analysis.isScanning(.silence) }
        XCTAssertFalse(analysis.isScanning(.silence), "The automatic scan finishes.")
        XCTAssertTrue(analysis.hasSilenceResults(in: [ranges[1]]), "The added recording is scanned.")
        XCTAssertFalse(analysis.hasSilenceResults(in: [ranges[0]]), "A recording whose scan was cancelled stays unscanned.")

        // A later routing change does not start a scan of what it routes.
        let (routed, routedMedia, routedRanges) = try multicamProject(urls, ids: ["a", "b", "c"])
        analysis.update(project: routed, media: routedMedia, ordinary: routedMedia, useSidecars: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(analysis.isScanning(.silence))
        XCTAssertFalse(analysis.hasSilenceResults(in: [routedRanges[2]]))
        XCTAssertFalse(analysis.hasSilenceResults(in: [routedRanges[0]]))

        // The menu command still scans every routed recording.
        analysis.scan(.silence)
        try await waitUntil { !analysis.isScanning(.silence) }
        XCTAssertTrue(analysis.hasSilenceResults(in: routedRanges))
    }

    func testTurningTheSwitchOffDropsMulticamScansThatHaveNotStarted() throws {
        let folder = try XCTUnwrap(recordings(["A"]).first?.deletingLastPathComponent())
        let preferences = EditorPreferences(defaults: nil)
        preferences.useAnalysisSidecars = false
        preferences.autoScanScenes = true
        preferences.autoScanSilence = true
        let model = MulticamEditorModel(preferences: preferences, draft: ProjectDraft(directory: folder))
        defer { model.reset() }
        // A recording whose media has not arrived waits for both scans.
        model.analysis.requestAutomaticScans(of: ["later"], scenes: true, pauses: true)
        XCTAssertTrue(model.analysis.hasAutomaticScansWaiting)
        preferences.autoScanSilence = false
        preferences.autoScanScenes = false
        XCTAssertFalse(model.analysis.hasAutomaticScansWaiting, "Turning the switches off drops scans that have not started.")
    }
}
