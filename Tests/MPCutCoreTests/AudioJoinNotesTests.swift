import XCTest
@testable import MPCutCore

/// The notes a packet copy gives where a copied AAC track meets the next range inside the output.
final class AudioJoinNotesTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static var helper: String {
        ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
            ?? repository.appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.helper) else {
            throw XCTSkip("The FFmpeg helper is needed for AAC fixtures.")
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

    /// Six seconds of a 48 kHz stereo AAC tone in an M4A.
    private func tone() throws -> (URL, MediaInfo) {
        let url = scratch.appendingPathComponent("tone.m4a").standardizedFileURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.helper)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=6", "-ac", "2", "-c:a", "aac", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (url, try CutEngine(useSidecar: false).inspect(url, keyframes: true))
    }

    /// The source's AAC frames start this many samples after a multiple of 1024.
    private func phase(_ sound: AudioIndex) throws -> Int64 {
        let start = try XCTUnwrap(sound.packets.dropFirst().first).time
        let sample = try start.roundedToSamples(48_000)
        return ((sample % 1024) + 1024) % 1024
    }

    private func plan(_ clips: [ClipRequest], _ media: [URL: MediaInfo], mode: ExportMode = .copy,
                      container: String = "m4a") -> ExportResolution {
        ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: clips, mode: mode, tracks: .audio, container: container),
                                                 media: media)
    }

    func testWholeFrameOffsetsFollowTheSourceFrames() throws {
        let (_, media) = try tone()
        let sound = try XCTUnwrap(media.audio.first)
        let phase = try phase(sound)
        func rest(_ sample: Int64) -> Int64 { (1024 - ((sample - phase) % 1024 + 1024) % 1024) % 1024 }
        for (end, start) in [(Int64(115_541), Int64(153_611)), (192_007, 19_201), (phase + 1024 * 40, phase + 1024 * 90), (60_000, 2 * 1024 + phase)] {
            let offset = try XCTUnwrap(AudioJoinNotes.wholeFrameOffset(before: sound, end: t(end, 48_000),
                                                                      after: sound, start: t(start, 48_000)))
            XCTAssertEqual(offset, AudioJoinNotes.WholeFrameOffset(pastCut: rest(end), skipped: rest(start)), "\(end) → \(start)")
        }
    }

    func testCopyAndSmartTrimNoteEachAACJoinThePlayersCannotPlaceTheSameWay() throws {
        let (url, media) = try tone()
        let sound = try XCTUnwrap(media.audio.first)
        let phase = try phase(sound)
        let indexed = [url: media]
        let clips = [ClipRequest(file: url, from: t(48_623, 48_000), to: t(115_541, 48_000)),
                     ClipRequest(file: url, from: t(153_611, 48_000), to: t(192_007, 48_000)),
                     ClipRequest(file: url, from: t(19_201, 48_000), to: t(48_000, 48_000))]
        func rest(_ sample: Int64) -> Int64 { (1024 - ((sample - phase) % 1024 + 1024) % 1024) % 1024 }
        let first = "at 1.394125 s, \(AudioJoinNotes.milliseconds(rest(115_541), rate: 48_000)) past the cut and the first "
            + "\(AudioJoinNotes.milliseconds(rest(153_611), rate: 48_000)) of the next range left out"
        var sentences: [[String]] = []
        for mode in [ExportMode.copy, .smart] {
            guard case .ready(let plan, _, _) = plan(clips, indexed, mode: mode) else { return XCTFail("\(mode) refuses the AAC joins.") }
            let notes = plan.copyOmissions.filter { $0.hasPrefix("AAC track") }
            XCTAssertEqual(notes.count, 1, "\(plan.copyOmissions)")
            let note = try XCTUnwrap(notes.first)
            XCTAssertTrue(note.hasPrefix("AAC track \(sound.stream.index) is joined at 2 points by edit-list entries."), note)
            XCTAssertTrue(note.contains("such as Apple's, play each join exactly"), note)
            XCTAssertTrue(note.contains(first), note)
            XCTAssertTrue(note.contains("at 2.194042 s, "), note)
            XCTAssertTrue(note.hasSuffix("Converting the audio writes one continuous track that every player places exactly."), note)
            sentences.append(notes)
        }
        XCTAssertEqual(sentences[0], sentences[1], "Copy and Smart Trim write the same AAC track.")

        // Cuts on the source's frame boundaries are placed the same way by every player.
        let aligned = [ClipRequest(file: url, from: t(phase + 1024 * 20, 48_000), to: t(phase + 1024 * 60, 48_000)),
                       ClipRequest(file: url, from: t(phase + 1024 * 100, 48_000), to: t(phase + 1024 * 150, 48_000))]
        guard case .ready(let alignedPlan, _, _) = plan(aligned, indexed) else { return XCTFail("The aligned joins are refused.") }
        XCTAssertFalse(alignedPlan.copyOmissions.contains { $0.hasPrefix("AAC track") }, "\(alignedPlan.copyOmissions)")

        // One range has no join to report.
        guard case .ready(let single, _, _) = plan([clips[0]], indexed) else { return XCTFail("One range is refused.") }
        XCTAssertFalse(single.copyOmissions.contains { $0.hasPrefix("AAC track") })

        // Matroska has no edit list, so a copy refuses the interior AAC start rather than moving it.
        guard case .unavailable(let refusal, _) = plan(clips, indexed, container: "mka") else { return XCTFail("MKA copies the joins.") }
        XCTAssertEqual(refusal.code, "unsafe_boundary")
        XCTAssertEqual(refusal.reason, .joinDecoderHistory)
    }

    func testALongEditNamesTwelveJoinsAndSumsUpTheRest() throws {
        let (url, media) = try tone()
        let phase = try phase(try XCTUnwrap(media.audio.first))
        // Fifteen short ranges, each starting and ending 300 samples after a frame boundary.
        let clips = (0..<16).map { index in
            ClipRequest(file: url, from: t(phase + 300 + Int64(index) * 16 * 1024, 48_000),
                        to: t(phase + 300 + Int64(index) * 16 * 1024 + 8 * 1024, 48_000))
        }
        guard case .ready(let plan, _, _) = plan(clips, [url: media]) else { return XCTFail("The ranges are refused.") }
        let note = try XCTUnwrap(plan.copyOmissions.first { $0.hasPrefix("AAC track") })
        XCTAssertTrue(note.contains("is joined at 15 points by edit-list entries."), note)
        XCTAssertEqual(note.components(separatedBy: " past the cut and the first ").count - 1, 12, note)
        XCTAssertTrue(note.contains("; at 3 more joins, by up to \(AudioJoinNotes.milliseconds(724, rate: 48_000)) each; and up to "), note)
    }
}
