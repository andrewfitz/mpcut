import AVFoundation
import XCTest
@testable import MPCutApp

final class LinkedAudioPreviewTests: XCTestCase {
    // The movie has a mono 400 Hz track, plus a right-only 1200 Hz track starting at 0.4 s.
    private func level(_ grain: ScrubGrain, _ frequency: Double, channel: Int) -> Double {
        var x = 0.0, y = 0.0
        for frame in 0..<(grain.stereo.count / 2) {
            let phase = 2 * Double.pi * frequency * Double(frame) / grain.rate
            let value = Double(grain.stereo[frame * 2 + channel])
            x += value * cos(phase)
            y += value * sin(phase)
        }
        return 4 * hypot(x, y) / Double(grain.stereo.count)
    }

    func testUnavailableLinkedTrackLeavesHealthyTrackAudible() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Linked-Opus", withExtension: "webm",
                                                      subdirectory: "Fixtures"))
        var bytes = try Data(contentsOf: fixture)
        let codec = try XCTUnwrap(bytes.range(of: Data("A_OPUS".utf8), options: .backwards))
        bytes.replaceSubrange(codec, with: Data("A_BAD!".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webm")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)

        let reader = FFPreviewReader(audioOnly: true)
        try reader.seek(url: url, to: 0.65, withAudio: true)
        let batch = try reader.batch(from: 0.65, end: 0.70, timelineOffset: Double(0), first: false,
                                     cancelled: { false })
        XCTAssertTrue(batch.partialAudio)
        XCTAssertFalse(batch.noAudio)
        let grain = try XCTUnwrap(ScrubGrain(samples: batch.audio, window: 0.65..<0.70,
                                             reverse: false, fadeEdges: false))
        XCTAssertEqual(level(grain, 400, channel: 1), 0.125, accuracy: 0.012)
        XCTAssertLessThan(level(grain, 1200, channel: 1), 0.004)
    }

    func testLinkedOpusForwardAndGrainsAfterSeeks() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Linked-Opus", withExtension: "webm",
                                                  subdirectory: "Fixtures"))
        let reader = FFPreviewReader()
        let grains = ScrubAudioReader()
        for start in [0.65, 0.12, 0.50] {
            let window = start..<(start + 0.05)
            try reader.seek(url: url, to: start, withAudio: true)
            var samples: [CMSampleBuffer] = []
            var done = false
            for batchIndex in 0..<100 where !done {
                let batch = try reader.batch(from: start, end: window.upperBound, timelineOffset: Double(0),
                                             first: batchIndex == 0, cancelled: { false })
                samples += batch.audio
                done = batch.end
            }
            XCTAssertTrue(done)
            let forward = try XCTUnwrap(ScrubGrain(samples: samples, window: window, reverse: false, fadeEdges: false))
            let reversed = await grains.read(source: url, composition: nil, window: window,
                                             reverse: true, fadeEdges: false)
            for grain in [forward, try XCTUnwrap(reversed)] {
                XCTAssertEqual(level(grain, 400, channel: 0), 0.125, accuracy: 0.012)
                XCTAssertEqual(level(grain, 400, channel: 1), 0.125, accuracy: 0.012)
                XCTAssertLessThan(level(grain, 1200, channel: 0), 0.004)
                XCTAssertEqual(level(grain, 1200, channel: 1), start < 0.4 ? 0 : 0.125, accuracy: 0.012)
            }
        }
        let selected = await grains.read(source: url, composition: nil, window: 0.65..<0.70,
                                         reverse: false, fadeEdges: false, audioTrack: 1)
        let grain = try XCTUnwrap(selected)
        XCTAssertLessThan(level(grain, 400, channel: 1), 0.004)
        XCTAssertEqual(level(grain, 1200, channel: 1), 0.125, accuracy: 0.012)
    }
}
