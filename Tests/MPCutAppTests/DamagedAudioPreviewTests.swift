import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class DamagedAudioPreviewTests: XCTestCase {
    /// Shuttle-Chirp.mov stores three seconds of AAC. Its packets from 0.384 s
    /// begin at byte 2853, the three up to 0.448 s end at byte 3174, and the
    /// last one ends before byte 14606.
    private func damagedChirp(_ bytes: Range<Int>, extension ext: String) throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        var data = try Data(contentsOf: source)
        for i in bytes { data[i] = UInt8(truncatingIfNeeded: i &* 197 &+ 91) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    func testFallbackAudioContinuesPastDamagedPackets() throws {
        let url = try damagedChirp(2853..<3174, extension: "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = FFPreviewReader()
        try reader.seek(url: url, to: 0, withAudio: true, soundOnlySource: true, audioOrigin: .zero)
        var times: [Double] = []
        for _ in 0..<64 {
            let batch = try reader.batch(from: 0, end: 3, timelineOffset: 0, first: false, cancelled: { false })
            XCTAssertFalse(batch.noAudio)
            times += batch.audio.map(\.presentationTimeStamp.seconds)
            if batch.end { break }
        }
        XCTAssertGreaterThan(try XCTUnwrap(times.last), 2.9)
        XCTAssertLessThan(try XCTUnwrap(times.first), 0.1)
        // The damaged interval is a dropout rather than the end of the pass.
        XCTAssertFalse(times.contains { $0 > 0.39 && $0 < 0.44 })
    }

    @MainActor
    func testUndecodableAudioCanBeRetriedAfterSeekingOrPlaying() async throws {
        // macOS does not open Matroska, which selects the fallback transport.
        let url = try damagedChirp(2853..<14606, extension: "mka")
        defer { try? FileManager.default.removeItem(at: url) }
        let range = PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 3),
                                 isAudioOnly: true, audioOrigin: .zero)
        let preview = SequencePreview()
        defer { preview.pause() }
        preview.update([range], at: 0)

        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        func failed() -> Bool { preview.issue?.hasPrefix(WebSequencePlayback.undecodableAudio) == true }

        try await wait {
            if !preview.isPlaying && preview.issue == nil { preview.togglePlayback() }
            return preview.isPlaying || preview.issue != nil
        }
        try await wait(failed)
        XCTAssertTrue(failed(), preview.issue ?? "no issue")
        XCTAssertFalse(preview.isPlaying)
        XCTAssertFalse(preview.hasBlockingIssue, "The Play button and Playback menu must remain available for a retry.")

        preview.togglePlayback()
        XCTAssertNil(preview.issue)
        XCTAssertTrue(preview.isPlaying)
        try await wait(failed)
        XCTAssertTrue(failed())
        XCTAssertFalse(preview.isPlaying)

        preview.seek(to: 0.1)
        XCTAssertNil(preview.issue)
        preview.shuttle(1)
        XCTAssertEqual(preview.playbackRate, 1)
    }
}
