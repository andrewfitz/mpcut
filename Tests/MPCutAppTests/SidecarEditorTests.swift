import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class SidecarEditorTests: XCTestCase {
    func testManualSaveRetainsFinerWaveformOverview() throws {
        let source = try scratchRecording("Pause-Quiet")
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let coarse = try AudioAnalysis.envelope(media, stream: stream, from: 0, to: media.duration.seconds,
                                                columns: 16, useSidecar: false)
        let snapshot = DesktopAnalysisSnapshot(sourceID: UUID(), media: media, scenes: nil, viewNames: [:],
                                               thresholdOverrides: [:], edits: EditorMetadataEdits(), waveforms: [:],
                                               envelopeOverviews: [stream: coarse], silence: [], filmstrip: [])
        let fine = try AudioAnalysis.envelope(media, stream: stream, from: 0, to: media.duration.seconds, columns: 64)
        try snapshot.save(cancelled: { false })
        let saved = try XCTUnwrap(AnalysisSidecar(media: media).envelopeOverview(for: media, stream: stream))
        XCTAssertEqual(saved.low, fine.low)
        XCTAssertEqual(saved.high, fine.high)
        XCTAssertNotNil(try CutEngine().cachedIndex(source))
    }

    @MainActor
    func testJPEGRangeExportRetainsAnalysisForSidecarSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("Interview.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.importFiles([source])
        try await wait { !editor.isBusy && editor.canEdit }
        XCTAssertTrue(editor.canScanScenes)
        XCTAssertFalse(editor.pauseAnalysisReady)
        for (mode, folder) in [(JPEGExportMode.scenes, "scenes"), (.nonSilent, "speech")] {
            let options = JPEGExportOptions()
            options.mode = mode
            options.limitText = "1"
            let output = directory.appendingPathComponent(folder, isDirectory: true)
            editor.exportJPEGFrames(try XCTUnwrap(editor.jpegSourceAtPlayhead), to: output, options: options)
            try await wait { !editor.isBusy }
            XCTAssertNil(editor.alert)
            XCTAssertEqual(editor.lastExportedURL, output)
        }
        XCTAssertFalse(editor.canScanScenes)
        XCTAssertTrue(editor.pauseAnalysisReady)
        editor.saveAnalysisSidecars()
        try await wait { !editor.isSavingSidecars }
        let sidecar = try AnalysisSidecar(source: source)
        let media = try XCTUnwrap(CutEngine().cachedIndex(source))
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        XCTAssertNotNil(sidecar.sceneReport(for: media))
        XCTAssertNotNil(sidecar.silence(for: media, stream: stream, thresholdDB: nil, minimum: editor.minimumPause))
    }

    @MainActor
    func testSaveAndRestoreCompletedSourceAnalyses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("Interview.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let editor = EditorModel()
        defer { editor.endSession() }

        editor.importFiles([source, source])
        try await wait { !editor.isBusy && editor.canEdit }
        let sidecar = try AnalysisSidecar(source: source)
        XCTAssertEqual(sidecar.status(), "current")
        editor.scanForScenes()
        editor.scanForSilence()
        try await wait { editor.sceneProgress == nil && editor.pauseAnalysisReady }
        let firstIndex = try XCTUnwrap(CutEngine().cachedIndex(source))
        let firstStream = try XCTUnwrap(firstIndex.audio.first?.stream.index)
        XCTAssertNotNil(sidecar.sceneReport(for: firstIndex))
        XCTAssertNotNil(sidecar.silence(for: firstIndex, stream: firstStream, thresholdDB: nil,
                                        minimum: editor.minimumPause))
        let id = try XCTUnwrap(editor.timelineClips.first?.sourceID)
        editor.setViewName("Interview", source: id, view: 1)
        XCTAssertEqual(editor.jpegSourceAtPlayhead?.scenes?.views.first?.name, "Interview")
        editor.manualThresholdDB = -45
        try await wait { editor.pauseAnalysisReady }
        let expected = try XCTUnwrap(editor.sourcePauses[id])
        editor.saveAnalysisSidecars()
        try await wait { !editor.isSavingSidecars }
        XCTAssertNil(editor.alert)
        XCTAssertEqual(editor.statusMessage, "Saved 1 analysis sidecar")

        let media = try XCTUnwrap(CutEngine().cachedIndex(source))
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        XCTAssertNotNil(sidecar.waveform(for: media, stream: stream))
        XCTAssertEqual(sidecar.silence(for: media, stream: stream, thresholdDB: -45,
                                      minimum: editor.minimumPause)?.pauses, expected)

        editor.endSession()
        editor.importFiles([source])
        try await wait { !editor.isBusy && editor.pauseAnalysisReady }
        let restored = try XCTUnwrap(editor.timelineClips.first?.sourceID)
        XCTAssertFalse(editor.canScanScenes)
        XCTAssertEqual(editor.viewNamesBySource[restored]?[1], "Interview")
        editor.setViewName("", source: restored, view: 1)
        // Unwrap each level: a missing report must not read as a cleared name.
        let restoredReport = try XCTUnwrap(XCTUnwrap(editor.jpegSourceAtPlayhead).scenes)
        XCTAssertNil(try XCTUnwrap(restoredReport.views.first).name)
        XCTAssertEqual(editor.manualThresholdDB, -45)
        XCTAssertEqual(editor.sourcePauses[restored], expected)

        editor.endSession()
        editor.useAnalysisSidecars = false
        editor.importFiles([source])
        try await wait { !editor.isBusy && editor.canEdit }
        XCTAssertTrue(editor.canScanScenes)
        XCTAssertNil(editor.manualThresholdDB)
        XCTAssertTrue(editor.sourcePauses.isEmpty)
    }

    @MainActor
    func testBlindSavesIndependentEditorsAndExplicitMetadataResets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("Interview.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let first = EditorModel(), blind = EditorModel(), second = EditorModel()
        defer { first.endSession(); blind.endSession(); second.endSession() }
        let sidecar = try AnalysisSidecar(source: source)
        func save(_ editor: EditorModel) async throws {
            XCTAssertTrue(editor.canSaveAnalysisSidecars)
            editor.saveAnalysisSidecars()
            try await wait { !editor.isSavingSidecars }
            XCTAssertNil(editor.alert)
        }
        first.importFiles([source])
        try await wait { !first.isBusy && first.canEdit }
        first.scanForScenes()
        try await wait { first.currentSceneLabel != nil && first.sceneProgress == nil }
        let id = try XCTUnwrap(first.timelineClips.first?.sourceID)
        first.setViewName("Camera", source: id, view: 1)
        first.manualThresholdDB = -43
        try await save(first)

        blind.useAnalysisSidecars = false
        blind.importFiles([source])
        try await wait { !blind.isBusy && blind.canEdit }
        XCTAssertNil(blind.manualThresholdDB)
        blind.scanForScenes()
        try await wait { blind.currentSceneLabel != nil && blind.sceneProgress == nil }
        try await save(blind)

        second.importFiles([source])
        try await wait { !second.isBusy && second.canEdit }
        XCTAssertEqual(second.manualThresholdDB, -43)
        XCTAssertEqual(second.jpegSourceAtPlayhead?.scenes?.views.first?.name, "Camera")
        second.analysisTrack = 1
        second.manualThresholdDB = -35
        try await save(second)
        first.manualThresholdDB = -52
        first.setViewName("", source: id, view: 1)
        try await save(first)
        let media = try XCTUnwrap(CutEngine().cachedIndex(source))
        let stream = media.audio.map(\.stream.index)
        XCTAssertEqual(stream.count, 2)
        func savedThresholds() throws -> [Int: Double] {
            try JSONDecoder().decode([Int: Double].self, from: XCTUnwrap(sidecar.read("silence_threshold_overrides_db.v1")))
        }
        XCTAssertEqual(try savedThresholds(), [stream[0]: -52, stream[1]: -35])
        let savedReport = try XCTUnwrap(sidecar.sceneReport(for: media))
        XCTAssertNil(try XCTUnwrap(savedReport.views.first).name)
        first.manualThresholdDB = nil
        first.saveAnalysisSidecars()
        var quitCanProceed = false
        XCTAssertTrue(first.cancelAndWaitForExport { quitCanProceed = true })
        try await wait { quitCanProceed }
        XCTAssertEqual(try savedThresholds(), [stream[1]: -35])
    }

    @MainActor
    func testAutomaticMetadataSurvivesImmediateReopenAndPreservesLaterExternalEdits() async throws {
        let source = try scratchRecording("Pause-Quiet")
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.importFiles([source])
        try await wait { editor.canEdit }
        editor.manualThresholdDB = -42
        editor.endSession()
        editor.importFiles([source])
        try await wait { editor.canEdit }
        XCTAssertEqual(editor.manualThresholdDB, -42)

        editor.manualThresholdDB = -45
        var drained = false
        XCTAssertTrue(editor.cancelAndWaitForExport { drained = true })
        try await wait { drained }
        let media = try XCTUnwrap(CutEngine().cachedIndex(source))
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let sidecar = AnalysisSidecar(media: media)
        let section = "silence_threshold_overrides_db.v1"
        func thresholds() throws -> [Int: Double] {
            try JSONDecoder().decode([Int: Double].self, from: XCTUnwrap(sidecar.read(section)))
        }
        XCTAssertEqual(try thresholds(), [stream: -45])
        try sidecar.save([section: JSONEncoder().encode([stream: -51.0])])
        editor.saveAnalysisSidecars()
        try await wait { !editor.isSavingSidecars }
        XCTAssertEqual(try thresholds(), [stream: -51])
    }

    @MainActor
    func testReimportChecksSourceIdentityBeforeReusingAnOpenIndex() async throws {
        let source = try scratchRecording("ProRes-2997")
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.importFiles([source])
        try await wait { editor.canEdit }
        try FileManager.default.removeItem(at: source)
        editor.importFiles([source])
        try await wait { !editor.isImporting }
        XCTAssertEqual(editor.timelineClips.count, 1)
        XCTAssertNotNil(editor.alert)
    }

    @MainActor
    func testEnablingSidecarsDuringWaveformScanPersistsTheResult() async throws {
        let source = try scratchRecording("Pause-Quiet")
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let store = WaveformStore(), id = UUID()
        defer { store.clear() }
        store.update(sources: [id: media], track: 0, useSidecar: false)
        store.update(sources: [id: media], track: 0, useSidecar: true)
        try await wait { store.finished.contains(id) }
        XCTAssertNotNil(AnalysisSidecar(media: media).waveform(for: media, stream: stream))
    }

    @MainActor
    func testDisablingSidecarsDuringProvisionalImportKeepsTheBatchOpenWithoutSaving() async throws {
        let files = try [scratchRecording("Pause-Quiet"), scratchRecording("Pause-Quiet")]
        let editor = EditorModel()
        defer { editor.endSession() }
        let watch = editor.$playhead.sink { _ in
            if editor.isImporting, editor.timelineClips.first?.isIndexed == false { editor.useAnalysisSidecars = false }
        }
        defer { watch.cancel() }
        editor.importFiles(files)
        try await wait { editor.canEdit }
        XCTAssertFalse(editor.useAnalysisSidecars)
        XCTAssertEqual(editor.timelineClips.count, files.count)
        for url in files { XCTAssertEqual(try AnalysisSidecar(source: url).status(), "missing") }
    }

    @MainActor
    func testGuiContinuesPartialIndexRestoreProgressLikeCoreInspection() async throws {
        let url = try scratchRecording("Pause-Quiet")
        let engine = CutEngine()
        let media = try engine.inspect(url, keyframes: true)
        let sidecar = AnalysisSidecar(media: media)
        let malformed = try XCTUnwrap(sidecar.read("media_index_audio.v1")) + Data([0xff])
        func corruptAudioSection() throws { try sidecar.save(["media_index_audio.v1": malformed]) }
        try corruptAudioSection()
        var restored = 0.0
        XCTAssertNil(try engine.cachedIndex(url) { restored = max(restored, $0) })
        XCTAssertGreaterThan(restored, 0)
        var expected: [Double] = []
        let gate = EditCancellation()
        _ = try engine.inspect(url, keyframes: true) { if gate.shouldReport($0) { expected.append($0) } }
        XCTAssertTrue(expected.contains { $0 > restored && $0 < 1 })

        try corruptAudioSection()
        let editor = EditorModel()
        defer { editor.endSession() }
        var shown: [Double] = []
        let observation = editor.$importProgress.sink { if $0 > 0 { shown.append($0) } }
        defer { observation.cancel() }
        editor.importFiles([url])
        try await wait { editor.canEdit }
        XCTAssertEqual(shown.filter { $0 < 1 }, expected.filter { $0 < 1 })
    }

    private func scratchRecording(_ fixtureName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: fixtureName, withExtension: "mov", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("Interview.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        return source
    }

    @MainActor
    func testSettingsSurviveANewEditor() throws {
        let name = "mpcut.settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = EditorModel(defaults: defaults)
        XCTAssertTrue(first.useAnalysisSidecars)
        first.useAnalysisSidecars = false
        first.largeThumbnails = true
        XCTAssertEqual(first.snapTarget, .off)
        first.snapTarget = .silence
        first.minimumPause = 2
        first.padding = 0.125
        first.preview.isMuted = true
        first.preview.volume = 0.4
        first.preview.scrubSoundEnabled = false
        first.defaultExportMode = .copy
        first.endSession()

        let second = EditorModel(defaults: defaults)
        defer { second.endSession() }
        XCTAssertFalse(second.useAnalysisSidecars)
        XCTAssertTrue(second.largeThumbnails)
        XCTAssertEqual(second.snapTarget, .silence)
        XCTAssertEqual(second.minimumPause, 2)
        XCTAssertEqual(second.padding, 0.125)
        XCTAssertTrue(second.preview.isMuted)
        XCTAssertEqual(second.preview.volume, 0.4)
        XCTAssertFalse(second.preview.scrubSoundEnabled)
        XCTAssertEqual(second.defaultExportMode, .copy)
    }

    @MainActor
    func testRetiredKeyframePreferenceIsIgnored() throws {
        let name = "mpcut.snap-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "snapToKeyframes")
        let editor = EditorModel(defaults: defaults)
        XCTAssertEqual(editor.snapTarget, .off)
        for target in [TimelineSnapTarget.scenes, .silence, .keyframes, .off] {
            editor.snapTarget = target
            let reopened = EditorModel(defaults: defaults)
            XCTAssertEqual(reopened.snapTarget, target)
            reopened.endSession()
        }
        editor.endSession()
    }

    @MainActor
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw NSError(domain: "SidecarEditorTests", code: 1) }
    }
}
