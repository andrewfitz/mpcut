import XCTest
@testable import MPCutCore

/// Tier factors exercised with small prerecorded and helper-generated sources.
/// `TimelineTierTests.testEveryFactorGivesItsTierAndIsReported` counts `covered` as exercised.
final class TimelineTierFactorFixtureTests: XCTestCase {
    /// The factors this file has a scenario for.
    static let covered: Set<TierFactorID> = [.cutAudioPacket, .cutAACCoverage, .cutPCMSampleClock, .cutMP3Crop, .cutOpusWindow, .joinSmartOpenGOP, .joinTimecode,
                                             .sourceUnsupportedTracks, .sourceEncodeUnsupported]

    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static var helper: String {
        ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
            ?? repository.appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
    }

    private var scratch: URL!
    private var exercised: Set<TierFactorID> = []

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.helper), "Needs the FFmpeg helper to make the sources.")
        if ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil {
            setenv("MPCUT_FFMPEG_HELPER", Self.helper, 0)
            addTeardownBlock { _ = unsetenv("MPCUT_FFMPEG_HELPER") }
        }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func t(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    /// Runs the helper. A machine without the hardware encoders skips the scenario that needs them.
    private func make(_ name: String, _ arguments: [String]) throws -> URL {
        let output = scratch.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.helper)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [output.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "The helper could not make \(name): \(text.suffix(200))")
        return output.standardizedFileURL
    }

    private func picture(rate: Int, seconds: Int = 3) -> [String] {
        ["-f", "lavfi", "-i", "testsrc2=s=160x96:r=\(rate):d=\(seconds)"]
    }
    private func tone(seconds: Int = 3) -> [String] {
        ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)"]
    }

    /// The tier of `clips` and the factor that explains it.
    private func assertTier(_ clips: [ClipRequest], _ tier: FidelityTier?, because factor: TierFactorID,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        var media: [URL: MediaInfo] = [:]
        for clip in clips where media[clip.file] == nil { media[clip.file] = try CutEngine(useSidecar: false).inspect(clip.file, keyframes: true) }
        let state = TimelineTierEvaluator(useSidecar: false).evaluate(clips, media: media)
        XCTAssertEqual(state.tier, tier, "\(factor.rawValue): \(state.factors.map(\.message))", file: file, line: line)
        let found = state.factors.first { $0.id == factor }
        XCTAssertNotNil(found, "\(factor.rawValue) is not among \(state.factors.map(\.id.rawValue))", file: file, line: line)
        if let tier, let found {
            XCTAssertGreaterThanOrEqual(found.forces ?? .trueLossless, tier, "A factor leaves at best the tier it names.", file: file, line: line)
        }
        // The whole source has no cut, so the factor belongs to the cut or the source, not to the test's encoding.
        exercised.insert(factor)
    }

    func testGeneratedSourcesReachTheirFactors() throws {
        // cut_audio_packet: MP3 sound in a movie. MP3 has no edit list in MOV, and its packets do not end on the picture.
        let mp3 = try make("mp3.mov", picture(rate: 25) + tone() + ["-c:v", "h264_videotoolbox", "-g", "1", "-c:a", "libmp3lame"])
        XCTAssertEqual(TimelineTierEvaluator(useSidecar: false).evaluate([ClipRequest(file: mp3)]).tier, .trueLossless)
        try assertTier([ClipRequest(file: mp3, from: t(1), to: nil)], .reencode, because: .cutAudioPacket)

        // The AAC ends before the picture. Use independently decodable pictures so
        // the encoder's choice of keyframes cannot mask the audio coverage error.
        let late = try make("late.mov", picture(rate: 25) + ["-itsoffset", "0.5"] + tone(seconds: 2)
            + ["-map", "0:v", "-map", "1:a", "-c:v", "h264_videotoolbox", "-g", "1", "-bf", "0", "-c:a", "aac"])
        XCTAssertEqual(TimelineTierEvaluator(useSidecar: false).evaluate([ClipRequest(file: late)]).tier, .trueLossless)
        try assertTier([ClipRequest(file: late, from: t(1), to: nil)], .reencode, because: .cutAACCoverage)

        // x265 open-GOP, two B-frames, and one-second GOPs give CRA and
        // leading RASL pictures at the interior boundaries.
        let open = Self.repository.appendingPathComponent("Tests/MPCutAppTests/Fixtures/HEVC-Open-GOP.mp4").standardizedFileURL
        XCTAssertEqual(TimelineTierEvaluator(useSidecar: false).evaluate([ClipRequest(file: open)]).tier, .trueLossless)
        try assertTier([ClipRequest(file: open, from: t(7, 25), to: t(2))], .reencode, because: .joinSmartOpenGOP)

        // source_unsupported_tracks: two video tracks. No mode writes such a source.
        let gop = Self.repository.appendingPathComponent("Tests/MPCutAppTests/Fixtures/SmartTrim-GOP.mp4").path
        let two = try make("two.mov", ["-i", gop, "-i", gop, "-map", "0:v", "-map", "1:v", "-c", "copy"])
        try assertTier([ClipRequest(file: two)], nil, because: .sourceUnsupportedTracks)

        // source_encode_unsupported: a picture rotated by 45 degrees. Its cut needs an encode, and the encoder keeps
        // rotations in quarter turns only, so nothing writes the timeline.
        let straight = try make("straight.mp4", picture(rate: 30) + ["-c:v", "h264_videotoolbox", "-g", "30", "-bf", "2"])
        let turned = try make("turned.mp4", ["-display_rotation", "45", "-i", straight.path, "-c", "copy"])
        XCTAssertEqual(TimelineTierEvaluator(useSidecar: false).evaluate([ClipRequest(file: turned)]).tier, .trueLossless)
        try assertTier([ClipRequest(file: turned, from: t(7, 30), to: nil)], nil, because: .sourceEncodeUnsupported)

        // cut_pcm_sample_clock: PCM sound keeps its sample clock in MOV. The tier never names a container, so the cut
        // is True Lossless there, and the factor is what a copy named for MP4 reports.
        let pcm = try make("pcm.mov", picture(rate: 30) + tone() + ["-c:v", "h264_videotoolbox", "-g", "1", "-c:a", "pcm_s16le"])
        let cut = [ClipRequest(file: pcm, from: t(1), to: nil)]
        XCTAssertEqual(TimelineTierEvaluator(useSidecar: false).evaluate(cut).tier, .trueLossless)
        if case .unavailable(let issue, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: cut, mode: .copy, container: "mp4")) {
            XCTAssertEqual(issue.factor, .cutPCMSampleClock, issue.message)
            exercised.insert(.cutPCMSampleClock)
        } else {
            XCTFail("A PCM movie cut is copied into MP4, which has no sample-accurate PCM clock for it.")
        }

        // cut_mp3_crop: a tonal VBR MP3 whose bit reservoir reaches further back than its Xing delay can hide. The
        // native crop check refuses these ranges, and a PCM rewrite still writes them without loss.
        let vbr = try make("vbr.mp3", ["-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*(227*t+201*t*t)):s=44100:d=3.33",
                                       "-c:a", "libmp3lame", "-q:a", "2"])
        try assertTier([ClipRequest(file: vbr, from: t(44_223, 44_100), to: t(47_556, 44_100))], .lossless, because: .cutMP3Crop)

        // cut_opus_window: a single range of an Ogg Opus recording is trimmed inside its packets. An end one
        // millisecond in is before the trim window can close.
        let opus = Self.repository.appendingPathComponent("Tests/MPCutAppTests/Fixtures/Standalone-Chirp.opus").standardizedFileURL
        try assertTier([ClipRequest(file: opus, from: nil, to: t(1, 1000))], .lossless, because: .cutOpusWindow)

        // join_timecode: a MOV timecode track whose frame count is outside what the writer can represent, as some
        // cameras write it. 01:23:45:07 at 25 pictures a second is frame 125 632, stored once as four bytes.
        let timecoded = try make("timecode.mov", ["-i", gop, "-c", "copy", "-timecode", "01:23:45:07"])
        var bytes = try Data(contentsOf: timecoded)
        let stored = Data([0x00, 0x01, 0xEA, 0xC0])
        let first = try XCTUnwrap(bytes.range(of: stored), "The timecode sample was not found.")
        XCTAssertNil(bytes.range(of: stored, in: first.upperBound..<bytes.count), "The timecode sample must be the only match.")
        XCTAssertEqual(TimelineTierEvaluator(useSidecar: false).evaluate([ClipRequest(file: timecoded)]).tier, .trueLossless)
        bytes.replaceSubrange(first, with: Data([0x7F, 0xFF, 0xFF, 0xFF]))
        let broken = scratch.appendingPathComponent("timecode-outside.mov").standardizedFileURL
        try bytes.write(to: broken)
        try assertTier([ClipRequest(file: broken)], .reencode, because: .joinTimecode)

        XCTAssertEqual(exercised, Self.covered, "`covered` lists exactly the factors with a scenario here.")
    }
}
