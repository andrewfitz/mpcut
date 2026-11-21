import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamPreviewTests: XCTestCase {
    @MainActor
    func testDelayedMovieDecodesTheFirstPictureAtTheIndexedPresentationTimestamp() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine().inspectMulticamSource(url)
        let start = RationalTime(numerator: 1001, denominator: 5_000)
        XCTAssertEqual(media.multicamClockOffset, start)
        XCTAssertEqual(media.frames.first?.time, start)
        let project = MulticamProject(referenceAngle: "wide",
                                      range: .init(from: .zero, to: media.duration),
                                      angles: [.init(id: "wide", file: url.path)], audio: .none,
                                      switches: [.init(at: .zero, angle: "wide")])
        let preview = MulticamPreview()
        preview.configure(plan: try project.plan(), media: ["wide": media])
        XCTAssertNil(preview.picture)
        XCTAssertNotNil(preview.pictureIssue)
        preview.seek(to: start)
        try await waitForPicture(preview, source: "wide", frame: start)
        XCTAssertEqual(preview.displayedFrameTime, previewTime(start))
    }

    @MainActor
    func testLiveAudioOverrideKeepsOutputClockAdvancingWhileNewTrackOpens() async throws {
        let camera = try indexed("Shuttle-Chirp", "mov")
        let alternate = try indexed("Multicam-Delayed-AAC", "mov")
        let media = ["camera": camera, "alternate": alternate]
        var project = MulticamProject(referenceAngle: "camera",
                                      range: .init(from: .zero, to: .init(numerator: 1)),
                                      angles: [.init(id: "camera", file: camera.url.path, audioStream: 1)],
                                      audioSources: [.init(id: "alternate", file: alternate.url.path)],
                                      audio: .follow, switches: [.init(at: .zero, angle: "camera")])
        let preview = MulticamPreview()
        preview.configure(plan: try project.plan(), media: media)
        preview.togglePlayback()
        defer { preview.pause() }
        let deadline = ContinuousClock.now + .seconds(3)
        while preview.currentTime().seconds < 0.05, .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let instant = preview.currentTime()
        XCTAssertGreaterThanOrEqual(instant.seconds, 0.05)
        project.switches.append(.init(at: instant, angle: "camera", audio: .init(source: "alternate", stream: 1)))
        preview.configure(plan: try project.plan(), media: media)
        let immediatelyAfterSwitch = preview.currentTime()
        // Keep the main actor occupied so the new audio can't finish preroll.
        let clockDeadline = ContinuousClock.now + .milliseconds(25)
        while preview.currentTime() <= immediatelyAfterSwitch, .now < clockDeadline {}
        XCTAssertGreaterThan(preview.currentTime(), immediatelyAfterSwitch)
    }

    @MainActor
    func testRelinkingReplacedRecordingAtSamePathRefreshesIndexAndDisplayedPicture() async throws {
        let original = try indexed("SmartTrim-GOP", "mp4")
        let replacement = try indexed("VFR-PTS", "mp4")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("camera.mp4").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: original.url, to: file)
        let projectURL = directory.appendingPathComponent("edit.multicam.json")
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 1)),
                                      angles: [.init(id: "wide", file: file.lastPathComponent)],
                                      audio: .none, switches: [.init(at: .zero, angle: "wide")])
        try project.save(to: projectURL)
        let model = MulticamEditorModel()
        model.useAnalysisSidecars = false
        model.openProject(projectURL)
        try await waitForIndex(model)
        XCTAssertNil(model.notice)
        try await waitForPicture(model.preview, source: "wide", frame: original.frames[0].time)
        let oldIdentity = try XCTUnwrap(model.media["wide"]).identity

        let newFile = directory.appendingPathComponent("replacement.mp4")
        try FileManager.default.copyItem(at: replacement.url, to: newFile)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: newFile)
        let output = directory.appendingPathComponent("program.mov")
        model.export(output: output, mode: .copy, tracks: .all, dryRun: false, wholeGroup: true)
        try await waitForIndex(model)
        XCTAssertTrue(model.notice?.message.contains("source changed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        model.notice = nil

        model.relink("wide", to: file)
        try await waitForIndex(model)
        XCTAssertNil(model.notice)
        let refreshed = try XCTUnwrap(model.media["wide"])
        XCTAssertNotEqual(refreshed.identity, oldIdentity)
        XCTAssertEqual(refreshed.frames.map(\.time), replacement.frames.map(\.time))
        XCTAssertEqual(model.project?.range, project.range)
        XCTAssertFalse(model.isChanged)
        try await waitForPicture(model.preview, source: "wide", frame: replacement.frames[0].time)
        XCTAssertEqual(model.preview.picture?.identity, refreshed.identity)
    }

    @MainActor
    func testSeeksUseIndexedPicturesOnBothSidesOfSwitchAndAcrossRepeatedAssembly() async throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("WebM-Opus-GOP", "webm")
        let vfr = try indexed("VFR-PTS", "mp4")
        let media = ["wide": wide, "close": close, "vfr": vfr]
        let playable = min(wide.duration, close.duration, vfr.duration, RationalTime(numerator: 1))
        let middle = RationalTime(numerator: 2, denominator: 5)
        let highlight = MulticamRange(from: middle, to: playable)
        let early = MulticamRange(from: .zero, to: middle)
        let plan = try MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: playable),
                                      angles: [.init(id: "wide", file: wide.url.path),
                                               .init(id: "close", file: close.url.path,
                                                     offset: .init(numerator: 1, denominator: 25)),
                                               .init(id: "vfr", file: vfr.url.path)],
                                      audio: .none,
                                      switches: [.init(at: .zero, angle: "wide"), .init(at: middle, angle: "close")],
                                      assembly: [highlight, early, highlight]).plan()
        let preview = MulticamPreview()
        preview.configure(plan: plan, media: media)
        let highlightDuration = playable - middle
        for (time, source, frame): (RationalTime, String, RationalTime) in [
            (.zero, "close", .init(numerator: 1, denominator: 5)),
            (highlightDuration, "wide", .zero),
            (highlightDuration + middle, "close", .init(numerator: 1, denominator: 5))
        ] {
            preview.seek(to: time)
            try await waitForPicture(preview, source: source, frame: frame)
        }

        let indexedFrame = try XCTUnwrap(vfr.frames.dropFirst(3).first)
        let inFrame = indexedFrame.time + indexedFrame.duration * .init(numerator: 1, denominator: 2)
        preview.audition(url: vfr.url, sourceTime: inFrame, media: vfr)
        try await waitForPicture(preview, source: vfr.url.path, frame: indexedFrame.time)
        preview.endAudition()
        try await waitForPicture(preview, source: "close", frame: .init(numerator: 1, denominator: 5))
        preview.seek(to: plan.duration)
        try await waitForPicture(preview, source: "close", frame: .init(numerator: 4, denominator: 5))
    }

    @MainActor
    func testLivePictureSwitchKeepsMasterClockRunning() async throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("WebM-Opus-GOP", "webm")
        let (wav, _) = try masterRecording()
        defer { try? FileManager.default.removeItem(at: wav.url) }
        let media = ["wide": wide, "close": close, "master": wav]
        var project = program(wide: wide, close: close, wav: wav)
        let preview = MulticamPreview()
        preview.configure(plan: try project.plan(), media: media)
        preview.togglePlayback()
        defer { preview.pause() }
        let deadline = ContinuousClock.now + .seconds(3)
        while preview.currentTime().seconds < 0.15, .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let instant = preview.currentTime()
        XCTAssertGreaterThanOrEqual(instant.seconds, 0.15)
        // Update a live decision without giving the audio loader a chance to
        // run. A clock restart would park it at the published position.
        project.switches.append(.init(at: instant, angle: "close"))
        preview.configure(plan: try project.plan(), media: media)
        let immediatelyAfterSwitch = preview.currentTime()
        let clockDeadline = ContinuousClock.now + .milliseconds(25)
        while preview.currentTime() <= immediatelyAfterSwitch, .now < clockDeadline {}
        XCTAssertGreaterThan(preview.currentTime(), immediatelyAfterSwitch)
        while preview.picture?.source != "close", .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(preview.picture?.source, "close")
        XCTAssertTrue(preview.isPlaying)
        XCTAssertNil(preview.issue)
    }

    func testFixedMasterSamplesStayContinuousAcrossPictureCutsAndFollowAssemblyReorder() throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("WebM-Opus-GOP", "webm")
        let (wav, samples) = try masterRecording()
        defer { try? FileManager.default.removeItem(at: wav.url) }
        let media = ["wide": wide, "close": close, "master": wav]
        var project = program(wide: wide, close: close, wav: wav)
        // Five fractional-rate picture periods equal exactly 8,008 samples.
        // The fixed PCM master also crosses four fractional-sample picture cuts.
        for frame in 1...5 {
            project.switches.append(.init(at: .init(numerator: Int64(frame * 1001), denominator: 30_000),
                                          angle: frame.isMultiple(of: 2) ? "wide" : "close"))
        }
        let whole = try project.plan()
        XCTAssertEqual(whole.audio.count, 1)
        let decoder = MulticamPreviewAudioDecoder()
        XCTAssertEqual(try decode(whole, media: media, decoder: decoder), Array(samples.prefix(48_000 * 2)))

        project.assembly = [
            .init(from: .init(numerator: 5005, denominator: 30_000), to: .init(numerator: 1, denominator: 4)),
            .init(from: .init(numerator: 1, denominator: 20), to: .init(numerator: 1, denominator: 10))
        ]
        let reordered = try project.plan()
        let expected = Array(samples[(8_008 * 2)..<(12_000 * 2)]) + Array(samples[(2_400 * 2)..<(4_800 * 2)])
        XCTAssertEqual(try decode(reordered, media: media, decoder: decoder), expected)
    }

    func testAudioOverrideMonitorsTheSelectedAACTrackOnOneContinuousPicture() async throws {
        let wide = try indexed("Shuttle-Chirp", "mov")
        // The second track has a leading empty edit; it uses the native
        // presentation clock and still overrides the first microphone.
        let external = try indexed("Multicam-Delayed-AAC", "mov")
        let media = ["wide": wide, "external": external]
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 1, denominator: 4)),
                                      angles: [.init(id: "wide", file: wide.url.path, audioStream: 1)],
                                      audioSources: [.init(id: "external", file: external.url.path)], audio: .follow,
                                      switches: [.init(at: .zero, angle: "wide"),
                                                 .init(at: .init(numerator: 1, denominator: 20), angle: "wide",
                                                       audio: .init(source: "external", stream: 1)),
                                                 .init(at: .init(numerator: 3, denominator: 20), angle: "wide")])
        let plan = try project.plan()
        XCTAssertEqual(plan.picture.count, 1)
        XCTAssertEqual(plan.audio.map(\.source), ["wide", "external", "wide"])
        let pcm = try decode(plan, media: media, decoder: MulticamPreviewAudioDecoder())
        XCTAssertEqual(pcm.count, 24_000)
        let override = try XCTUnwrap(MulticamPreviewAudioSpan(span: plan.audio[1], media: media))
        XCTAssertNotNil(override.presentationTrackID)
        let middle = pcm.dropFirst(2_400 * 2).prefix(4_800 * 2)
        XCTAssertEqual(tone(in: Array(middle)), 1_340, accuracy: 20)

        let request = try XCTUnwrap(ScrubAudioRequest(source: external.url, composition: nil, position: 0.05,
                                                      bounds: 0..<0.25, reverse: false, audioOrigin: override.origin,
                                                      audioTrack: override.ordinal,
                                                      presentationTrackID: override.presentationTrackID))
        let grain = await ScrubAudioReader().grain(request)
        let scrub = try XCTUnwrap(grain).stereo.dropFirst(480 * 2).dropLast(480 * 2)
        XCTAssertEqual(tone(in: Array(scrub)), 1_340, accuracy: 30)
    }

    @MainActor
    func testShuttleReversesAssemblyPictureAndKeepsRateAcrossSeek() async throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("WebM-Opus-GOP", "webm")
        let (wav, _) = try masterRecording()
        defer { try? FileManager.default.removeItem(at: wav.url) }
        let media = ["wide": wide, "close": close, "master": wav]
        var project = program(wide: wide, close: close, wav: wav)
        let middle = RationalTime(numerator: 2, denominator: 5)
        project.audio = .none
        project.switches.append(.init(at: middle, angle: "close"))
        project.assembly = [.init(from: middle, to: .init(numerator: 1)), .init(from: .zero, to: middle)]
        let plan = try project.plan()
        let preview = MulticamPreview()
        preview.configure(plan: plan, media: media)
        preview.seek(to: plan.duration)
        preview.shuttle(-1)
        XCTAssertEqual(preview.playbackRate, -1)
        let deadline = ContinuousClock.now + .seconds(2)
        while preview.picture?.source != "close", .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(preview.picture?.source, "close")
        XCTAssertLessThan(preview.currentTime(), .init(numerator: 3, denominator: 5))

        for rate: Float in [-2, -4, -8, -8] {
            preview.shuttle(-1)
            XCTAssertEqual(preview.playbackRate, rate)
        }
        preview.seek(to: .init(numerator: 2, denominator: 5))
        XCTAssertEqual(preview.playbackRate, -8)
        preview.shuttle(1)
        for rate: Float in [1, 2, 4, 8, 8] {
            XCTAssertEqual(preview.playbackRate, rate)
            preview.shuttle(1)
        }
        let forward = preview.currentTime()
        let forwardDeadline = ContinuousClock.now + .seconds(1)
        while preview.currentTime() <= forward, .now < forwardDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(preview.currentTime(), forward)
        preview.pause()
        let parked = preview.currentTime()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(preview.currentTime(), parked)
        XCTAssertEqual(preview.playbackRate, 0)
    }

    func testReverseAudioReordersMappedSamplesAndKeepsSilentGaps() async throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("WebM-Opus-GOP", "webm")
        let (wav, pcm) = try masterRecording()
        defer { try? FileManager.default.removeItem(at: wav.url) }
        let media = ["wide": wide, "close": close, "master": wav]
        var project = program(wide: wide, close: close, wav: wav)
        project.audio = .none
        project.switches = [
            .init(at: .zero, angle: "wide", audio: .init(source: "master", stream: 0)),
            .init(at: .init(numerator: 1, denominator: 4), angle: "close"),
            .init(at: .init(numerator: 1, denominator: 2), angle: "wide", audio: .init(source: "master", stream: 0))
        ]
        project.assembly = [
            .init(from: .init(numerator: 1, denominator: 2), to: .init(numerator: 3, denominator: 4)),
            .init(from: .zero, to: .init(numerator: 1, denominator: 2))
        ]
        let plan = try project.plan()
        let spans = plan.audio.compactMap { MulticamPreviewAudioSpan(span: $0, media: media) }
        XCTAssertEqual(spans.count, 2)
        let timeline = ReverseAudioTimeline(regions: spans.map(\.reverseRegion))
        let output = await ScrubAudioReader().reverseBlock(timeline, from: 11_900, to: 24_100, speed: 1)
        guard output.count == 24_400 else { return XCTFail("Expected 12,200 stereo samples") }
        XCTAssertEqual(Array(output.prefix(200)), Array(repeating: 0, count: 200))
        let expected = (0..<12_100).flatMap { frame -> [Float] in
            let source = frame < 12_000 ? 11_999 - frame : 35_999 - (frame - 12_000)
            return [pcm[source * 2], pcm[source * 2 + 1]]
        }
        XCTAssertTrue(output.dropFirst(200).elementsEqual(expected))
    }

    private func tone(in pcm: [Float]) -> Double {
        let crossings = stride(from: 0, to: pcm.count - 2, by: 2).filter { pcm[$0] <= 0 && pcm[$0 + 2] > 0 }.count
        return Double(crossings) * 96_000 / Double(pcm.count)
    }

    private func indexed(_ name: String, _ ext: String) throws -> MediaInfo {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try CutEngine().inspect(url, keyframes: true)
    }

    private func program(wide: MediaInfo, close: MediaInfo, wav: MediaInfo) -> MulticamProject {
        MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 1)),
                        angles: [.init(id: "wide", file: wide.url.path), .init(id: "close", file: close.url.path)],
                        audioSources: [.init(id: "master", file: wav.url.path)],
                        audio: .fixed(.init(source: "master", stream: 0)),
                        switches: [.init(at: .zero, angle: "wide")])
    }

    private func masterRecording() throws -> (MediaInfo, [Float]) {
        let frames: UInt32 = 48_000
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        var data = Data("RIFF".utf8)
        func write<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        write(UInt32(36) + frames * 4)
        data.append(Data("WAVEfmt ".utf8))
        write(UInt32(16))
        write(UInt16(1))
        write(UInt16(2))
        write(UInt32(48_000))
        write(UInt32(192_000))
        write(UInt16(4))
        write(UInt16(16))
        data.append(Data("data".utf8))
        write(frames * 4)
        var expected: [Float] = []
        for index in 0..<frames {
            let left = Int16(index % 2_031) - 1_015
            let right = Int16(index % 3_093) - 1_546
            write(left)
            write(right)
            expected.append(Float(left) / 32_768)
            expected.append(Float(right) / 32_768)
        }
        try data.write(to: url)
        return (try CutEngine().inspect(url, keyframes: true), expected)
    }

    private func decode(_ plan: MulticamPlan, media: [String: MediaInfo], decoder: MulticamPreviewAudioDecoder) throws -> [Float] {
        var samples: [Float] = []
        var frame = 0
        for plannedSpan in plan.audio {
            let span = try XCTUnwrap(MulticamPreviewAudioSpan(span: plannedSpan, media: media))
            var batch = try decoder.read(span: span, from: span.input.lowerBound, open: true) { false }
            while true {
                for sample in batch.audio {
                    let outputFrame = CMTime(value: Int64(frame), timescale: 48_000)
                    XCTAssertEqual(sample.presentationTimeStamp, outputFrame)
                    let channels = sample.numSamples * 2
                    let buffer = try XCTUnwrap(sample.dataBuffer)
                    var pcm = Array(repeating: Float.zero, count: channels)
                    let status = pcm.withUnsafeMutableBytes {
                        CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                    }
                    XCTAssertEqual(status, noErr)
                    samples.append(contentsOf: pcm)
                    frame += sample.numSamples
                }
                if batch.end { break }
                batch = try decoder.read(span: span, from: span.input.lowerBound, open: false) { false }
            }
        }
        return samples
    }

    @MainActor
    private func waitForIndex(_ model: MulticamEditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while (model.isBusy || !model.sourceIndexProgress.isEmpty), .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.sourceIndexProgress.isEmpty)
    }

    @MainActor
    private func waitForPicture(_ preview: MulticamPreview, source: String, frame: RationalTime) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while (preview.picture?.source != source || preview.picture?.frameTime != frame), .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(preview.pictureIssue)
        XCTAssertEqual(preview.picture?.source, source)
        XCTAssertEqual(preview.picture?.frameTime, frame)
    }
}
