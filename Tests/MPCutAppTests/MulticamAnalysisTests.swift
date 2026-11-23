@testable import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamAnalysisTests: XCTestCase {
    @MainActor
    func testRoutedWaveformAndPausesUseSourceOffsetAndSwitchClipping() async throws {
        let quiet = try fixture("Pause-Quiet")
        let track = try XCTUnwrap(quiet.audio.first?.stream.index)
        let route = MulticamAudioSelection(source: "quiet", stream: track)
        let half = RationalTime(numerator: 1, denominator: 2)
        let switchTime = RationalTime(numerator: 2)
        var project = MulticamProject(referenceAngle: "quiet", range: .init(from: .zero, to: .init(numerator: 4)),
                                      angles: [.init(id: "quiet", file: quiet.url.path, offset: half),
                                               .init(id: "other", file: quiet.url.path)],
                                      audio: .none,
                                      switches: [.init(at: .zero, angle: "quiet", audio: route),
                                                 .init(at: switchTime, angle: "other")])
        let media = ["quiet": quiet, "other": quiet]
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        XCTAssertEqual(analysis.silenceTrackCount, 1)
        XCTAssertTrue(analysis.programMicrophone(at: .zero, project: project).contains("no audio here"))
        XCTAssertEqual(analysis.programMicrophone(at: switchTime, project: project), "None routed here")
        analysis.scan(.silence)
        try await waitUntil { analysis.hasSilenceResults(project: project, media: media) }
        XCTAssertTrue(analysis.programMicrophone(at: half, project: project).contains("dBFS threshold"))
        let first = try XCTUnwrap(analysis.soundtrack(in: project.range).first)
        XCTAssertEqual(first.group, .init(from: half, to: switchTime))
        XCTAssertEqual(first.input, .init(from: .zero, to: .init(numerator: 3, denominator: 2)))
        let pause = try XCTUnwrap(analysis.routedPauses(project: project, media: media).first)
        XCTAssertEqual(pause.from.seconds, 1.52, accuracy: 0.02)
        XCTAssertEqual(pause.to, switchTime)
        XCTAssertNil(analysis.waveform(sourceID: "other", stream: track))

        project.switches.removeLast()
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        XCTAssertTrue(analysis.hasSilenceResults(project: project, media: media))
        let longer = try XCTUnwrap(analysis.routedPauses(project: project, media: media).first)
        XCTAssertEqual(longer.to.seconds, 3.48, accuracy: 0.02)

        let room = MulticamRange(from: .init(numerator: 2), to: .init(numerator: 3))
        XCTAssertTrue(analysis.useRoomTone(in: room))
        try await waitUntil { analysis.hasSilenceResults(project: project, media: media) }
        let snapshot = analysis.snapshot(for: quiet)
        let measured = try XCTUnwrap(first.waveform?.peak(from: 1.5, to: 2.5))
        XCTAssertEqual(snapshot.silence.first?.requestedThresholdDB, AudioAnalysis.roomToneThresholdDB(forPeak: measured))
    }

    @MainActor
    func testRoutedMicrophoneCanOutlastItsOwnPictureAndSaveAnalysis() async throws {
        let source = try fixture("Pause-Quiet")
        let stream = try XCTUnwrap(source.audio.first?.stream.index)
        let videoIndex = try XCTUnwrap(source.streams.firstIndex { $0.index == source.videoStream?.index })
        let pictureEnd = RationalTime(numerator: 1)
        let shortPicture = MediaInfo(url: source.url, format: source.format, duration: pictureEnd,
            origin: source.origin, streams: source.streams, frames: source.frames.filter { $0.time < pictureEnd },
            audio: source.audio, copyIssue: nil, sourceStartSafe: source.sourceStartSafe,
            identity: source.identity, videoIndex: videoIndex)
        let microphone = MulticamAudioSelection(source: "mic", stream: stream)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: source.duration),
            angles: [.init(id: "wide", file: source.url.path), .init(id: "mic", file: source.url.path)],
            audio: .fixed(microphone), switches: [.init(at: .zero, angle: "wide")])
        let media = ["wide": source, "mic": shortPicture]
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        analysis.scan(.silence)
        try await waitUntil { analysis.hasSilenceResults(project: project, media: media) }
        let pause = try XCTUnwrap(analysis.routedPauses(project: project, media: media).first)
        XCTAssertGreaterThan(pause.from, pictureEnd)
        let snapshot = analysis.snapshot(for: shortPicture)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.waveforms[stream]).duration, pictureEnd)
        let span = try XCTUnwrap(analysis.soundtrack(in: project.range).first)
        XCTAssertEqual(span.selection, microphone)
        var detail: DisplayEnvelope?
        try await waitUntil {
            detail = analysis.waveformDetail.envelope(for: span.selection, surface: .multicam(span.group.from),
                                                      from: 1.8, to: 1.9, pixels: 400)
            return detail != nil
        }
        XCTAssertLessThan(try XCTUnwrap(detail).secondsPerBin, 0.001)
        XCTAssertNotNil(try snapshot.sections(for: shortPicture, cancelled: { false })["waveform_peaks.v1.\(stream)"])
    }

    @MainActor
    func testMinimumPauseCanSpanTwoDifferentRoutedMicrophones() async throws {
        let quiet = try fixture("Pause-Quiet")
        let stream = try XCTUnwrap(quiet.audio.first?.stream.index)
        let switchTime = RationalTime(numerator: 11, denominator: 4)
        var project = MulticamProject(referenceAngle: "picture", range: .init(from: .zero, to: .init(numerator: 4)),
            angles: [.init(id: "picture", file: quiet.url.path, audioStream: stream)],
            audioSources: [.init(id: "second", file: quiet.url.path, offset: .init(numerator: 3, denominator: 2))],
            audio: .follow, switches: [
                .init(at: .zero, angle: "picture"),
                .init(at: switchTime, angle: "picture", audio: .init(source: "second", stream: stream))
            ])
        let media = ["picture": quiet, "second": quiet]
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.configureSilence(minimum: 2.5, threshold: -45)
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        analysis.scan(.silence)
        try await waitUntil { analysis.hasSilenceResults(project: project, media: media) }
        let markers = analysis.markers(.silence, project: project, media: media)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(try XCTUnwrap(markers.first).seconds, 1.02, accuracy: 0.02)
        XCTAssertEqual(markers.last, project.range.to)

        project.switches.removeLast()
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        try await waitUntil { analysis.hasSilenceResults(project: project, media: media) }
        XCTAssertTrue(analysis.markers(.silence, project: project, media: media).isEmpty)

        let calibrated = MulticamRange(from: .init(numerator: 3, denominator: 2), to: .init(numerator: 2))
        XCTAssertTrue(analysis.useRoomTone(in: calibrated))
        let pictureThreshold = try XCTUnwrap(analysis.threshold(for: .init(source: "picture", stream: stream)))
        XCTAssertEqual(analysis.threshold(for: .init(source: "second", stream: stream)), pictureThreshold)
    }

    @MainActor
    func testMixScansConcurrentLanesInGroupTime() async throws {
        let quiet = try fixture("Pause-Quiet")
        let stream = try XCTUnwrap(quiet.audio.first?.stream.index)
        let delay = RationalTime(numerator: 1)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 4)),
            angles: [.init(id: "wide", file: quiet.url.path, audioStream: stream),
                     .init(id: "guest", file: quiet.url.path, offset: delay, audioStream: stream)],
            audio: .mix, switches: [.init(at: .zero, angle: "wide")],
            mixLanes: [.init(id: "wide-mic", target: .camera("wide"), label: "Wide", colorSlot: 0),
                       .init(id: "guest-mic", target: .camera("guest"), label: "Guest", colorSlot: 1)])
        let media = ["wide": quiet, "guest": quiet]
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.configureSilence(minimum: 0.5, threshold: -45)
        analysis.maxBlip = 0
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        XCTAssertEqual(analysis.silenceTrackCount, 2)
        XCTAssertEqual(analysis.groupAudioLanes.map(\.id), ["wide-mic", "guest-mic"])
        XCTAssertEqual(analysis.soundtrack(in: project.range).map(\.laneID), ["wide-mic", "guest-mic"])
        analysis.scan(.silence)
        try await waitUntil { analysis.hasSilenceResults(project: project, media: media) }
        let pauses = analysis.routedPauses(project: project, media: media)
        XCTAssertEqual(pauses.count, 1)
        let pause = try XCTUnwrap(pauses.first)
        XCTAssertEqual(pause.from.seconds, 2.02, accuracy: 0.03)
        XCTAssertEqual(pause.to.seconds, 2.98, accuracy: 0.03)
    }

    @MainActor
    func testUnavailableMicrophoneOutsideAssemblyDoesNotBlockPauseEditing() async throws {
        let source = try fixture("Pause-Quiet")
        let stream = try XCTUnwrap(source.audio.first?.stream.index)
        let end = RationalTime(numerator: 3)
        let kept = MulticamRange(from: .zero, to: end)
        let project = MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: source.duration),
            angles: [.init(id: "camera", file: source.url.path, audioStream: stream)],
            audioSources: [.init(id: "missing", file: "missing.mov")],
            audio: .follow, switches: [
                .init(at: .zero, angle: "camera"),
                .init(at: end, angle: "camera", audio: .init(source: "missing", stream: stream))
            ], assembly: [kept])
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        let media = ["camera": source]
        analysis.update(project: project, media: media, ordinary: media, useSidecars: false)
        analysis.scan(.silence)
        try await waitUntil { !analysis.isScanning(.silence) }
        XCTAssertEqual(analysis.unindexedSilenceSources, ["missing"])
        XCTAssertTrue(analysis.hasSilenceResults(in: [kept]))
        XCTAssertFalse(analysis.hasSilenceResults(in: [project.range]))
    }

    @MainActor
    func testSelectedCameraSceneScopeIncludesItsAdditionalRecordings() throws {
        let first = try fixture("Scene-Cadence-Change")
        let next = try fixture("Multicam-Delayed-ProRes")
        let seam = RationalTime(numerator: 1)
        let end = RationalTime(numerator: 2)
        let camera = MulticamSource(id: "camera", file: first.url.path, coverage: .init(from: .zero, to: seam),
                                    additionalRecordings: [.init(id: "second", file: next.url.path, offset: seam,
                                                                 coverage: .init(from: seam, to: end))])
        let project = MulticamProject(referenceAngle: camera.id, range: .init(from: .zero, to: end),
                                      angles: [camera], audio: .none, switches: [.init(at: .zero, angle: camera.id)])
        let sources = [camera.id: first, "second": next]
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: sources, ordinary: sources, useSidecars: false)
        XCTAssertEqual(analysis.sceneInspectionKey(camera: camera.id), analysis.sceneInspectionKey(camera: nil))
        XCTAssertNotEqual(analysis.sceneInspectionKey(camera: camera.id), analysis.sceneInspectionKey(camera: "second"))
        analysis.refreshStaleScenes.insert("second")
        guard case .stale? = analysis.sceneDisposition(camera: camera.id) else {
            return XCTFail("A stale recording should mark the selected camera stale.")
        }
    }

    @MainActor
    func testScenesAndKeyframesFollowOnAirPictureAndRepeatedAssembly() async throws {
        let scene = try fixture("Scene-Cadence-Change")
        let other = try fixture("Multicam-Delayed-ProRes")
        let shifted = try CutEngine(useSidecar: false).inspectMulticamSource(other.url)
        XCTAssertGreaterThan(shifted.multicamClockOffset, .zero)

        let half = RationalTime(numerator: 1, denominator: 2)
        let three = RationalTime(numerator: 3)
        let excursion = MulticamRange(from: .zero, to: half)
        let repeated = MulticamRange(from: .init(numerator: 2), to: three)
        let project = MulticamProject(referenceAngle: "early", range: .init(from: .zero, to: .init(numerator: 5)),
                                      angles: [.init(id: "early", file: other.url.path),
                                               .init(id: "scene", file: scene.url.path, offset: half)],
                                      audio: .none,
                                      switches: [.init(at: .zero, angle: "early"), .init(at: half, angle: "scene")],
                                      assembly: [repeated, excursion, repeated])
        let media = ["early": shifted, "scene": scene]
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: media, ordinary: ["early": other, "scene": scene], useSidecars: false)
        XCTAssertFalse(analysis.canScanScenes(camera: "missing"))
        analysis.scanScenes(camera: "scene")
        try await waitUntil { !analysis.isScanning(.scenes) }
        XCTAssertEqual(Set(analysis.sceneReports.keys), ["scene"])
        XCTAssertEqual(analysis.sceneCoverage["scene"]?.requested, .fullSource)
        analysis.scan(.scenes)
        try await waitUntil { !analysis.isScanning(.scenes) }
        let sourceStarts = analysis.sourceScenes("scene")
        XCTAssertEqual(sourceStarts.count, 3)
        let group = analysis.markers(.scenes, project: project, media: media)
        XCTAssertEqual(group, [shifted.multicamClockOffset] + (try sourceStarts.map { try $0.adding(half) }))
        let onAir = try XCTUnwrap(analysis.currentScene(at: .init(numerator: 43, denominator: 10), project: project))
        analysis.rename(onAir, to: "Stage")
        XCTAssertEqual(analysis.currentScene(at: .init(numerator: 7, denominator: 10), project: project)?.name, "Stage")

        let plan = try project.plan()
        let output = MulticamAnalysisStore.outputMarkers(group, in: plan)
        let kept = try XCTUnwrap(group.first { repeated.contains($0) })
        let first = try kept.subtracting(repeated.from)
        XCTAssertEqual(output, [first, try shifted.multicamClockOffset.adding(.init(numerator: 1)),
                                try first.adding(.init(numerator: 3, denominator: 2))])
        let keys = analysis.markers(.keyframes, project: project, media: media)
        XCTAssertEqual(keys.first, shifted.frames.first?.time)
        XCTAssertTrue(keys.contains(half))
    }

    @MainActor
    func testSavedAnalysisReturnsWithOrdinarySourceClockWithoutRequestingScans() async throws {
        let fixture = try fixture("Pause-Quiet")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture.url, to: url)
        let source = try CutEngine(useSidecar: false).inspect(url, keyframes: true)
        let track = try XCTUnwrap(source.audio.first?.stream.index)
        let report = try SceneAnalysis.scan(source, useSidecar: false)
        let waveform = try AudioAnalysis.scan(source, stream: track, useSidecar: false)
        let pauses = try AudioAnalysis.silence(source, stream: track, waveform: waveform, useSidecar: false)
        let sidecar = AnalysisSidecar(media: source)
        var sections = try AnalysisSidecar.sections(media: source, scenes: report, waveforms: [track: waveform],
                                                   silence: [pauses])
        sections.merge(try AnalysisSidecar.viewNameSections([1: "Room"], for: report)) { _, name in name }
        try sidecar.save(sections)

        let project = MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: source.duration),
                                      angles: [.init(id: "camera", file: url.path, audioStream: track)],
                                      audio: .follow, switches: [.init(at: .zero, angle: "camera")])
        let media = ["camera": source]
        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: media, ordinary: media, useSidecars: true)
        try await waitUntil {
            analysis.hasSilenceResults(project: project, media: media) && !analysis.sourceScenes("camera").isEmpty
        }
        XCTAssertEqual(analysis.currentScene(at: .zero, project: project)?.name, "Room")
        XCTAssertEqual(analysis.routedPauses(project: project, media: media), pauses.pauses)
        XCTAssertFalse(analysis.canScan(.scenes))
        XCTAssertFalse(analysis.canScan(.silence))

        analysis.rescanSilence()
        XCTAssertTrue(analysis.isScanning(.silence))
        analysis.cancel(.silence)
        XCTAssertFalse(analysis.isScanning(.silence))
        XCTAssertEqual(analysis.routedPauses(project: project, media: media), pauses.pauses)

        analysis.configureSilence(minimum: 1, threshold: -60)
        try await waitUntil { analysis.hasSilenceResults(project: project, media: media) }
        let updated = try XCTUnwrap(analysis.snapshot(for: source).silence.first)
        XCTAssertEqual(updated.requestedThresholdDB, -60)
        XCTAssertEqual(updated.minimum, 1)
    }

    private func fixture(_ name: String) throws -> MediaInfo {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures"))
        return try CutEngine(useSidecar: false).inspect(url, keyframes: true)
    }

    @MainActor
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready())
    }
}
