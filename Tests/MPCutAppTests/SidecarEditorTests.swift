import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class SidecarEditorTests: XCTestCase {
    @MainActor
    func testTwoEditorsSaveTheSameRecordingIntoTheirOwnProjectFoldersAfterSaveAs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("Interview.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        try await SidecarLocations.$storageDirectory.withValue(directory.appendingPathComponent("settings")) {
            try SidecarLocations.setMode(.project)
            let editors = [EditorModel(), EditorModel()]
            defer { editors.forEach { $0.endSession() } }
            let adjacent = source.appendingPathExtension("cutcache")
            for (number, editor) in editors.enumerated() {
                // An untitled import stays in memory. Explicit save works even with auto-save disabled.
                editor.useAnalysisSidecars = false
                editor.importFiles([source])
                try await wait { !editor.isBusy && editor.canEdit }
                XCTAssertFalse(FileManager.default.fileExists(atPath: adjacent.path))
                let receipt = MCPAnalysisReceipt(owner: "test", revision: 0, kind: "sidecars")
                editor.mcpSidecarReceipt = receipt
                editor.saveAnalysisSidecars()
                XCTAssertEqual(receipt.state, "failed")
                XCTAssertNil(editor.mcpSidecarReceipt)
                let folder = directory.appendingPathComponent("edit-\(number)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let document = folder.appendingPathComponent("Sequence.cut")
                try editor.writeProject(to: document)
                let output = try XCTUnwrap(SidecarLocations(source: source, project: document).destination)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
            for editor in editors { editor.saveAnalysisSidecars() }
            try await wait { editors.allSatisfy { !$0.isSavingSidecars } }
            let paths = try editors.map { editor -> URL in
                XCTAssertNil(editor.alert)
                let project = try XCTUnwrap(editor.projectURL)
                let path = try XCTUnwrap(SidecarLocations(source: source, project: project).destination)
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
                XCTAssertNotNil(try SidecarLocations.$projectURL.withValue(project) { try CutEngine().cachedIndex(source) })
                return path
            }
            XCTAssertNotEqual(paths[0], paths[1])
            XCTAssertFalse(FileManager.default.fileExists(atPath: adjacent.path))
        }
    }

    @MainActor
    func testFirstProjectSaveFlushesDraftAnalysisEvenWhenTheWindowImmediatelyCloses() async throws {
        let source = try scratchRecording("Pause-Quiet")
        let directory = source.deletingLastPathComponent()
        try await SidecarLocations.$storageDirectory.withValue(directory.appendingPathComponent("settings")) {
            try SidecarLocations.setMode(.project)
            let editor = EditorModel()
            editor.importFiles([source])
            try await wait { editor.canEdit }
            editor.manualThresholdDB = -47
            let single = directory.appendingPathComponent("Single.cut")
            try editor.writeProject(to: single)
            let singleURL = try XCTUnwrap(SidecarLocations(source: source, project: single).destination)
            editor.endSession()
            var completed = false
            if editor.cancelAndWaitForExport({ completed = true }) { try await wait { completed } }
            XCTAssertTrue(FileManager.default.fileExists(atPath: singleURL.path))
            try SidecarLocations.$projectURL.withValue(single) {
                let media = try XCTUnwrap(CutEngine().cachedIndex(source))
                XCTAssertNil(AnalysisSidecar(media: media).read("silence_threshold_overrides_db.v1"))
                XCTAssertEqual(try CutProject.load(from: single).analysisAnnotations.silence.first?.thresholdDB, -47)
            }

            let other = directory.appendingPathComponent("Camera.mov")
            try FileManager.default.copyItem(at: source, to: other)
            let model = MulticamEditorModel()
            let media = try CutEngine(useSidecar: false).inspectMulticamSource(other)
            model.confirmSetup(drafts: [.init(source: .init(id: "camera", file: other.path), media: media)],
                               opening: "camera", audio: .none)
            let multi = directory.appendingPathComponent("Multicam.cut")
            try model.writeProject(to: multi)
            let multiURL = try XCTUnwrap(SidecarLocations(source: other, project: multi).destination)
            completed = false
            let draining = model.cancelAndWait { completed = true }
            model.reset()
            if draining { try await wait { completed } }
            XCTAssertTrue(FileManager.default.fileExists(atPath: multiURL.path))
            XCTAssertNotNil(try SidecarLocations.$projectURL.withValue(multi) { try CutEngine().cachedIndex(other) })
            for recording in [source, other] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: recording.appendingPathExtension("cutcache").path))
            }
        }
    }

    @MainActor
    func testClearingAnOpenEditorPreservesNamedScenesAndThreshold() async throws {
        let source = try scratchRecording("Pause-Quiet")
        let settings = source.deletingLastPathComponent().appendingPathComponent("settings")
        try await SidecarLocations.$storageDirectory.withValue(settings) {
            let editor = EditorModel()
            defer { editor.endSession() }
            editor.importFiles([source])
            try await wait { editor.canEdit }
            editor.scanForScenes()
            try await wait { editor.sceneProgress == nil && !editor.canScanScenes }
            let id = try XCTUnwrap(editor.timelineClips.first?.sourceID)
            editor.setViewName("Interview", source: id, view: 1)
            editor.manualThresholdDB = -45
            editor.saveAnalysisSidecars()
            try await wait { !editor.isSavingSidecars }
            let entry = try XCTUnwrap(SidecarCacheCleaner.preview(sources: [source]).first {
                $0.source.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() && $0.issue == nil
            })
            let result = SidecarCacheCleaner.clear([entry])
            XCTAssertEqual(result.cleared, [entry.url])
            NotificationCenter.default.post(name: .sidecarCachesDidClear, object: Set([source]),
                                            userInfo: ["wholeSidecars": true])
            XCTAssertEqual(editor.viewNamesBySource[id]?[1], "Interview")
            XCTAssertFalse(editor.scenesBySource[id]?.isEmpty ?? true)
            XCTAssertEqual(editor.manualThresholdDB, -45)
            editor.saveAnalysisSidecars()
            try await wait { !editor.isSavingSidecars }
            let sidecar = try AnalysisSidecar(source: source)
            XCTAssertNil(sidecar.read("silence_threshold_overrides_db.v1"))
            XCTAssertNil(sidecar.read("scenes_view_names.v1"))
        }
    }

    func testManualSaveRetainsFinerWaveformOverview() throws {
        let source = try scratchRecording("Pause-Quiet")
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let coarse = try AudioAnalysis.envelope(media, stream: stream, from: 0, to: media.duration.seconds,
                                                columns: 16, useSidecar: false)
        let snapshot = DesktopAnalysisSnapshot(sourceID: UUID(), media: media, scenes: nil, waveforms: [:],
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

        let document = directory.appendingPathComponent("Interview.cut")
        try editor.writeProject(to: document)
        editor.endSession()
        try editor.openProject([], at: document)
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
    func testEditorsSharingARecordingSaveIndependentNamesAndThresholds() async throws {
        let source = try scratchRecording("Pause-Quiet")
        let folder = source.deletingLastPathComponent()
        let first = EditorModel(), second = EditorModel()
        defer { first.endSession(); second.endSession() }
        let firstFile = folder.appendingPathComponent("First.cut")
        let secondFile = folder.appendingPathComponent("Second.cut")

        first.importFiles([source])
        try await wait { first.canEdit }
        first.scanForScenes()
        try await wait { first.currentSceneLabel != nil && first.sceneProgress == nil }
        let id = try XCTUnwrap(first.timelineClips.first?.sourceID)
        first.setViewName("Interview", source: id, view: 1)
        first.manualThresholdDB = -37.5
        try first.writeProject(to: firstFile)
        first.saveAnalysisSidecars()
        try await wait { !first.isSavingSidecars }

        second.importFiles([source])
        try await wait { second.canEdit }
        XCTAssertNil(second.manualThresholdDB)
        XCTAssertNil(second.jpegSourceAtPlayhead?.scenes?.views.first?.name)
        second.manualThresholdDB = -52
        try second.writeProject(to: secondFile)

        let savedFirst = try CutProject.load(from: firstFile).analysisAnnotations
        let savedSecond = try CutProject.load(from: secondFile).analysisAnnotations
        XCTAssertEqual(savedFirst.silence.first?.thresholdDB, -37.5)
        XCTAssertEqual(savedFirst.scenes.first?.views.first?.name, "Interview")
        XCTAssertEqual(savedSecond.silence.first?.thresholdDB, -52)
        XCTAssertTrue(savedSecond.scenes.isEmpty)
    }

    @MainActor
    func testSavingCutcacheAfterResetDoesNotRecreateAProjectThreshold() async throws {
        let source = try scratchRecording("Pause-Quiet")
        let project = source.deletingLastPathComponent().appendingPathComponent("Edit.cut")
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.importFiles([source])
        try await wait { editor.canEdit }
        editor.manualThresholdDB = -42
        try editor.writeProject(to: project)
        editor.endSession()
        try editor.openProject([], at: project)
        try await wait { editor.canEdit }
        XCTAssertEqual(editor.manualThresholdDB, -42)

        editor.manualThresholdDB = nil
        editor.saveAnalysisSidecars()
        try await wait { !editor.isSavingSidecars }
        try editor.writeProject(to: project)
        let persisted = try CutProject.load(from: project)
        XCTAssertTrue(persisted.analysisAnnotations.silence.isEmpty)
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
