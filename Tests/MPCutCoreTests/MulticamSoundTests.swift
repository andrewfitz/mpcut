import XCTest
@testable import MPCutCore

final class MulticamSoundTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpcut-multicam-sound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// One second of 16-bit mono PCM at the selected rate.
    private func microphone(_ name: String = "mic", sampleRate: Int = 48_000) throws -> MediaInfo {
        let samples = sampleRate
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples * 2))
        for sample in 0..<samples { append(Int16(truncatingIfNeeded: sample * 37)) }
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        try data.write(to: url)
        return try CutEngine(useSidecar: false).inspectMulticamSource(url)
    }

    private func resolve(_ media: MediaInfo, issue: String?) throws -> ResolvedEdit {
        let flagged = MediaInfo(url: media.url, format: media.format, duration: media.duration, origin: media.origin,
                                streams: media.streams, frames: media.frames, audio: media.audio, copyIssue: issue,
                                sourceStartSafe: media.sourceStartSafe, identity: media.identity, videoIndex: -1)
        let second = MulticamRange(from: .zero, to: RationalTime(numerator: 1))
        let selection = MulticamAudioSelection(source: "mic", stream: 0)
        let mapping = MulticamPlan(
            intervals: [.init(group: second, output: second, angle: "mic", audio: selection, assemblyIndex: 0)],
            picture: [], audio: [.init(source: "mic", stream: 0, input: second, output: second)], duration: second.to)
        return try MulticamEngine().resolveSound(mapping, sources: ["mic": flagged], container: "wav")
    }

    func testAudioEditClockFallsBackWhenSampleTimestampOverflows() throws {
        let media = try microphone()
        let original = try XCTUnwrap(media.audio.first)
        let track = AudioIndex(stream: original.stream, packets: [],
                               start: RationalTime(numerator: 1, denominator: .max),
                               end: media.duration, hasPriming: false, pcmContinuity: true,
                               presentationEdits: [])
        let phased = MediaInfo(url: media.url, format: media.format, duration: media.duration, origin: .zero,
                               streams: media.streams, frames: [], audio: [track], copyIssue: nil,
                               sourceStartSafe: true, identity: media.identity, videoIndex: -1)

        XCTAssertEqual(phased.audioEditBoundary(near: 0.25), .zero)
        XCTAssertEqual(phased.steppingAudioBoundary(from: 0.25, direction: 1), media.duration)
        XCTAssertEqual(media.audioEditBoundary(near: 0.25), RationalTime(numerator: 1, denominator: 4))
        XCTAssertEqual(media.steppingAudioBoundary(from: 0.25, direction: 1),
                       RationalTime(numerator: 12_001, denominator: 48_000))
    }

    func testTwoHoursOfIncompatiblePictureAndSamplePhasesSkipFullResolution() throws {
        let mic = try microphone()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Multicam-Delayed-ProRes.mov")
        let movie = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let video = try XCTUnwrap(movie.videoStream)
        let duration = RationalTime(numerator: 7200)
        let tick = RationalTime(numerator: 1, denominator: 30)
        let frames = (0..<216_000).map { index in
            FrameInfo(dts: nil, time: RationalTime(numerator: Int64(index), denominator: 30),
                      duration: tick, keyframe: true, canStart: true, canEnd: true, byteCount: 1)
        }
        let camera = MediaInfo(url: movie.url, format: movie.format, duration: duration, origin: .zero,
                               streams: [video], frames: frames, audio: [], copyIssue: nil,
                               sourceStartSafe: true, identity: movie.identity, videoIndex: 0)
        let start = RationalTime(numerator: 3600)
        let retained = MulticamRange(from: start, to: duration)
        let original = try XCTUnwrap(mic.audio.first)
        let end = RationalTime(numerator: 7201)
        let track = AudioIndex(stream: original.stream, packets: [], start: .zero, end: end,
                               hasPriming: false, pcmContinuity: true, presentationEdits: [])
        let recorder = MediaInfo(url: mic.url, format: mic.format, duration: end, origin: .zero,
                                 streams: mic.streams, frames: [], audio: [track], copyIssue: nil,
                                 sourceStartSafe: true, identity: mic.identity, videoIndex: -1)
        let project = MulticamProject(referenceAngle: "cam", range: .init(from: .zero, to: duration),
            angles: [.init(id: "cam", file: fixture.path)],
            audioSources: [.init(id: "mic", file: mic.url.path, offset: .init(numerator: -1, denominator: 96000))],
            audio: .fixed(.init(source: "mic", stream: 0)), switches: [.init(at: .zero, angle: "cam")],
            assembly: [retained])
        var replans = 0, resolutions = 0
        let alternatives = try MulticamEngine().edgeAlternatives(.init(range: 1, boundary: "from", at: start),
            mapping: project.plan(), media: ["cam": camera, "mic": recorder], mode: .encode, container: "mov",
            picture: true, sound: true, adjusting: { _, _, time in
                replans += 1
                return try project.plan(ranges: [.init(from: time, to: duration)])
            }, failure: { _ in resolutions += 1; return nil })
        XCTAssertTrue(alternatives.isEmpty)
        XCTAssertEqual(replans, 1)
        XCTAssertEqual(resolutions, 0)
    }

    func testAnIndexedIssueOnTheSelectedSoundtrackBlocksItsCopy() throws {
        let media = try microphone()
        XCTAssertEqual(try resolve(media, issue: nil).segments.count, 1)
        // An unused microphone on the same recording does not affect the selected one.
        XCTAssertEqual(try resolve(media, issue: "Audio track 3 has no usable presentation clock.").segments.count, 1)
        XCTAssertEqual(try resolve(media, issue: "AAC track 10 has a packet with missing duration.").segments.count, 1)
        for issue in ["Audio track 0 has no usable presentation clock.", "AAC track 0 has a packet with missing duration."] {
            XCTAssertThrowsError(try resolve(media, issue: issue)) { error in
                XCTAssertEqual((error as? CutError)?.code, "unsupported_tracks")
                XCTAssertEqual((error as? CutError)?.track, 0)
            }
        }
    }

    func testRenderedWAVLimitUsesFinalSampleWidth() throws {
        let media = try microphone()
        let audible = MulticamRange(from: .zero, to: media.duration)
        let program = MulticamRange(from: .zero, to: .init(numerator: 43_200))
        let lane = MulticamPlannedAudioLane(id: "mic", label: "Microphone", colorSlot: 0,
            spans: [.init(source: "mic", stream: 0, input: audible, output: audible)],
            gaps: [.init(from: audible.to, to: program.to)])
        let mapping = MulticamPlan(
            intervals: [.init(group: program, output: program, angle: "mic", audio: nil, assemblyIndex: 0)],
            picture: [], audioLanes: [lane], duration: program.to)
        let engine = MulticamEngine()
        func resolve(_ action: ReencodeAudio) throws -> [MulticamExportSound] {
            try engine.resolveAudioOutput(mapping, resolvedLanes: [lane], project: nil, sources: ["mic": media],
                container: "wav", output: .separateTracks, action: action, offerBoundaries: false, mode: .smart,
                wantPicture: false, settings: .init())
        }
        guard (try? ReencodeEngine.findHelper(override: nil)) != nil else {
            throw XCTSkip("The FFmpeg helper is needed to plan rendered audio.")
        }
        XCTAssertEqual(try resolve(.auto).first?.report.codec, "pcm_s16le")
        XCTAssertThrowsError(try resolve(.pcm)) { error in
            XCTAssertEqual((error as? CutError)?.code, "unsupported_container")
            XCTAssertEqual((error as? CutError)?.laneID, lane.id)
        }
    }

    func testSeparateSoundTracksKeepTheirOwnRatesAndSelectionOrder() throws {
        let primary = try microphone("primary")
        let alternate = try microphone("alternate", sampleRate: 44_100)
        let second = MulticamRange(from: .zero, to: .init(numerator: 1))
        let mapping = MulticamPlan(
            intervals: [.init(group: second, output: second, angle: "picture", audio: nil, assemblyIndex: 0)],
            picture: [], audioLanes: [
                .init(id: "alternate", label: "Alternate", colorSlot: 4,
                      spans: [.init(source: "b", stream: 0, input: second, output: second)]),
                .init(id: "primary", label: "Primary", colorSlot: 0,
                      spans: [.init(source: "a", stream: 0, input: second, output: second)])
            ], duration: second.to)
        let sources = ["a": primary.url, "b": alternate.url]
        let output = directory.appendingPathComponent("separate.mov")
        let engine = MulticamEngine()
        let plan = try engine.resolve(mapping, sources: sources, output: output, mode: .copy, tracks: .audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(plan.audioLanes.map(\.id), ["alternate", "primary"])
        XCTAssertEqual(plan.audioLanes.map(\.sampleRate), [44_100, 48_000])
        XCTAssertEqual(plan.audioLanes.map(\.action), [.copyOriginal, .copyOriginal])
        try engine.write(plan, to: output)
        let written = try CutEngine(useSidecar: false).inspectMulticamSource(output)
        XCTAssertEqual(written.audio.map { $0.stream.sampleRate }, [44_100, 48_000])
        XCTAssertEqual(written.audio.map(\.end), [second.to, second.to])
        XCTAssertEqual(written.audio.map { $0.stream.disposition & 1 }, [1, 0])
    }

    func testCopyReportsLaneAndExactOutputGapBeforeWriting() throws {
        let source = try microphone()
        let whole = MulticamRange(from: .zero, to: .init(numerator: 2))
        let span = MulticamRange(from: .zero, to: .init(numerator: 1))
        let uncovered = MulticamRange(from: span.to, to: whole.to)
        let mapping = MulticamPlan(
            intervals: [.init(group: whole, output: whole, angle: "picture", audio: nil, assemblyIndex: 0)],
            picture: [], audioLanes: [.init(id: "boom", label: "Boom", colorSlot: 2,
                spans: [.init(source: "mic", stream: 0, input: whole, output: whole)])], duration: whole.to)
        let output = directory.appendingPathComponent("gap.mov")
        XCTAssertThrowsError(try MulticamEngine().resolve(mapping, sources: ["mic": source.url],
                                                          output: output, mode: .copy, tracks: .audio)) { failure in
            let issue = failure as? CutError
            XCTAssertEqual(issue?.code, "uncovered_audio")
            XCTAssertEqual(issue?.laneID, "boom")
            XCTAssertEqual(issue?.multicam?.laneID, "boom")
            XCTAssertEqual(issue?.multicam?.output, uncovered)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testReplacementExportDoesNotOpenOfflineScratch() throws {
        let replacement = try microphone("replacement")
        let scratch = directory.appendingPathComponent("scratch.mov")
        let original = MulticamAudioSelection(source: "camera", stream: 1)
        let selected = MulticamAudioSelection(source: "replacement", stream: 0)
        let duration = RationalTime(numerator: 1)
        var project = MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: duration),
            angles: [.init(id: "camera", file: scratch.path, audioStream: 1)],
            audioSources: [.init(id: selected.source, file: replacement.url.path)], audio: .fixed(original),
            switches: [.init(at: .zero, angle: "camera")],
            audioReplacements: [.init(id: "binding", original: original, replacement: selected, relativeOffset: .zero,
                                      uncovered: .leaveUncovered)])
        for uncovered in [MulticamAudioReplacement.Uncovered.leaveUncovered, .keepOriginal] {
            project.audioReplacements[0].uncovered = uncovered
            let result = try MulticamEngine().resolve(project, output: directory.appendingPathComponent("out.mov"),
                                                       mode: .copy, tracks: .audio)
            XCTAssertEqual(result.mapping.audioLanes.first?.spans.first?.source, selected.source)
            XCTAssertEqual(result.audioLanes.first?.segments.first?.file, replacement.url)
        }
        project.audioReplacements[0].relativeOffset = .init(numerator: 1, denominator: 2)
        XCTAssertThrowsError(try MulticamEngine().resolve(project, output: directory.appendingPathComponent("out.mov"),
                                                          mode: .copy, tracks: .audio)) { failure in
            let issue = failure as? CutError
            XCTAssertEqual(issue?.laneID, MulticamPlan.programAudioLaneID)
            XCTAssertEqual(issue?.multicam?.source, original.source)
            XCTAssertEqual(issue?.multicam?.output, .init(from: .zero, to: .init(numerator: 1, denominator: 2)))
        }
    }

}
