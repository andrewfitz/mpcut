import XCTest
@testable import MPCutCore

/// Smart Trim's encoded AAC frames at joins into Matroska: which tracks qualify, and what the plans report.
final class AACBridgeTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static var helper: String {
        ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
            ?? repository.appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func t(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    func testTheEncodersReproduceOnlyLowComplexityConfigurations() {
        // 48 kHz stereo LC, with and without FFmpeg's extension that states there is no SBR.
        XCTAssertNil(aacConfigurationIssue(Data([0x11, 0x90])))
        XCTAssertNil(aacConfigurationIssue(Data([0x11, 0x90, 0x56, 0xe5, 0x00])))
        // HE-AAC signalled as its own object type, and as LC with an SBR extension that is present.
        XCTAssertEqual(aacConfigurationIssue(Data([0x2b, 0x92, 0x08, 0x00])), "it uses HE-AAC (spectral band replication or parametric stereo)")
        XCTAssertEqual(aacConfigurationIssue(Data([0x13, 0x10, 0x56, 0xe5, 0x98])),
                       "it signals HE-AAC (spectral band replication or parametric stereo)")
        XCTAssertEqual(aacConfigurationIssue(Data([0x11, 0x80])), "its channel layout is described by a program configuration element")
        XCTAssertEqual(aacConfigurationIssue(Data([0x0a, 0x10])), "it is not AAC Low Complexity")
        XCTAssertEqual(aacConfigurationIssue(Data()), "it has no AAC decoder configuration")
    }

    /// Four seconds of intra-coded picture with a 48 kHz stereo AAC tone in Matroska, so any picture can start a range.
    private func movie() throws -> (URL, MediaInfo) {
        guard FileManager.default.isExecutableFile(atPath: Self.helper) else { throw XCTSkip("The FFmpeg helper is needed.") }
        let url = scratch.appendingPathComponent("movie.mkv").standardizedFileURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.helper)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=s=192x96:r=25", "-f", "lavfi",
                             "-i", "aevalsrc=0.4*sin(2*PI*(300*t+40*t*t))|0.3*sin(2*PI*500*t):s=48000", "-t", "4",
                             "-c:v", "mjpeg", "-c:a", "aac", "-b:a", "128k", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (url, try CutEngine(useSidecar: false).inspect(url, keyframes: true))
    }

    func testCopyNamesSmartTrimAndSmartTrimPlansAnEncodedJoin() throws {
        let (url, media) = try movie()
        let clips = [ClipRequest(file: url, from: .zero, to: t(6, 5)), ClipRequest(file: url, from: t(11, 5), to: t(4))]
        let indexed = [url: media]
        guard case .unavailable(let refusal, let offers) = ExportPlanner(useSidecar: false)
            .resolve(ExportRequest(clips: clips, mode: .copy, container: "mkv"), media: indexed) else {
            return XCTFail("A copy joins AAC frames into Matroska without their history.")
        }
        XCTAssertEqual(refusal.reason, .joinAACFrames)
        XCTAssertTrue(refusal.message.contains("Smart Trim makes the join exact"), refusal.message)
        XCTAssertTrue(offers.contains { $0.alternative.rung == .smartTrim })

        guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false)
            .resolve(ExportRequest(clips: clips, mode: .smart, container: "mkv"), media: indexed) else {
            return XCTFail("Smart Trim refuses the AAC join.")
        }
        let edit = plan.edit
        XCTAssertNil(edit.segments[0].encodedAudioEdges)
        let edge = try XCTUnwrap(edit.segments[1].encodedAudioEdges?.first)
        XCTAssertEqual(edit.segments[1].encodedAudioEdges?.count, 1)
        let join = try XCTUnwrap(edit.segments[1].tracks.first { $0.kind == "audio" }).outputStart
        XCTAssertLessThan(edge.from, join)
        XCTAssertGreaterThanOrEqual(edge.to, join)
        // At least one frame of the earlier range, then the later range up to its next frame start.
        XCTAssertGreaterThanOrEqual(try join.subtracting(edge.from), t(1024, 48_000))
        XCTAssertGreaterThanOrEqual(edge.frameCount, 2)
        // The frames cover the bridge, with less than one frame trimmed.
        let samples = try edge.to.subtracting(edge.from).roundedToSamples(48_000)
        XCTAssertEqual(Int64(edge.frameCount), (samples + 1023) / 1024)
        XCTAssertEqual(edge.encoder, "ffmpeg")
        XCTAssertGreaterThanOrEqual(edge.targetBitRate, 128_000)
        XCTAssertEqual(edit.encodedAudioDuration, try edge.to.subtracting(edge.from))
        XCTAssertEqual(try edit.encodedVideoDuration(for: .smart), .zero, "The picture copies on its own boundaries.")

        // Planning again finds the same frames: the export rebuilds what the dry run reported.
        guard case .ready(let again, _, _) = ExportPlanner(useSidecar: false)
            .resolve(ExportRequest(clips: clips, mode: .smart, container: "mkv"), media: indexed) else { return XCTFail("No plan.") }
        XCTAssertEqual(again.edit.segments[1].encodedAudioEdges, edit.segments[1].encodedAudioEdges)
    }

    func testCopyAndSmartTrimTrimAnAACStartAndEndInsideFrames() throws {
        let (url, media) = try movie()
        // 26/25 s and 77/25 s fall inside AAC frames.
        let clips = [ClipRequest(file: url, from: t(26, 25), to: t(77, 25))]
        var trims: [[Int64]] = []
        for mode in [ExportMode.copy, .smart] {
            guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false)
                .resolve(ExportRequest(clips: clips, mode: mode, container: "mkv"), media: [url: media]) else {
                return XCTFail("\(mode) refuses a start and an end inside AAC frames.")
            }
            let segment = try XCTUnwrap(plan.edit.segments.first)
            let head = try XCTUnwrap(segment.aacHeads?.first), tail = try XCTUnwrap(segment.aacTails?.first)
            XCTAssertEqual(head.cut, 49_920)
            // The copy starts a whole frame before the frame that holds the cut, which the codec delay hides with it.
            XCTAssertEqual((head.cut - head.copy) / 1024, 1)
            XCTAssertEqual(head.padding, head.cut - head.copy)
            XCTAssertEqual((head.copy - head.grid) % 1024, 0)
            XCTAssertEqual(tail.cut, 147_840)
            XCTAssertEqual((tail.copy - tail.grid) % 1024, 0)
            XCTAssertTrue(tail.copy > tail.cut && tail.copy - tail.cut < 1024)
            XCTAssertNil(segment.encodedAudioEdges, "A trim encodes nothing.")
            trims.append([head.copy, head.padding, tail.copy])
        }
        XCTAssertEqual(trims[0], trims[1], "Lossless Copy and Smart Trim trim the same frames.")
    }

    func testARangeTooShortForTheEncodedFramesIsRefusedWithItsReason() throws {
        let (url, media) = try movie()
        // The middle range lasts one picture, 40 ms: too short to copy a frame between its two joins.
        let clips = [ClipRequest(file: url, from: .zero, to: t(1)), ClipRequest(file: url, from: t(2), to: t(51, 25)),
                     ClipRequest(file: url, from: t(3), to: t(4))]
        guard case .unavailable(let refusal, _) = ExportPlanner(useSidecar: false)
            .resolve(ExportRequest(clips: clips, mode: .smart, container: "mkv"), media: [url: media]) else {
            return XCTFail("Smart Trim plans overlapping AAC bridges.")
        }
        XCTAssertEqual(refusal.reason, .joinDecoderHistory)
        XCTAssertTrue(refusal.message.contains("too short"), refusal.message)
    }
}
