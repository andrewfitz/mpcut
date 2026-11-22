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

    /// One second of 16-bit mono PCM at 48 kHz.
    private func microphone() throws -> MediaInfo {
        let samples = 48_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(48_000))
        append(UInt32(96_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples * 2))
        for sample in 0..<samples { append(Int16(truncatingIfNeeded: sample * 37)) }
        let url = directory.appendingPathComponent("mic.wav")
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
}
