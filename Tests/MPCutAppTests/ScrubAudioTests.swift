import AVFoundation
import XCTest
@testable import MPCutApp

final class ScrubAudioTests: XCTestCase {
    @MainActor
    func testScrubOutputHonorsVolumeMuteAndStop() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Scrub-Tone", withExtension: "webm", subdirectory: "Fixtures"))
        let request = try XCTUnwrap(ScrubAudioRequest(source: url, composition: nil, position: 0.25,
                                                      bounds: 0..<0.6, reverse: false))
        let decoded = await ScrubAudioReader().grain(request)
        let grain = try XCTUnwrap(decoded)
        let engine = AVAudioEngine()
        let player = ScrubAudioPlayer(engine: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: grain.rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        defer { player.stop() }

        func peak(_ gain: Float) throws -> Float {
            player.stop()
            player.gain = gain
            player.play(grain)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            var maxSample: Float = 0
            for _ in 0..<6 {
                let status = try engine.renderOffline(512, to: buffer)
                XCTAssertEqual(status, .success)
                for i in 0..<Int(buffer.frameLength) {
                    maxSample = max(maxSample, abs(buffer.floatChannelData![0][i]))
                }
            }
            return maxSample
        }

        let loud = try peak(1)
        XCTAssertGreaterThan(loud, 0.05)
        XCTAssertEqual(try peak(0.25), loud * 0.25, accuracy: 0.01)
        XCTAssertEqual(try peak(0), 0, accuracy: 0.0001)
        player.stop()
        XCTAssertFalse(engine.isRunning)
    }

    func testReverseBlocksRetainEveryStereoSampleAcrossBufferBoundariesAtAllShuttleSpeeds() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<24_000 {
            buffer.floatChannelData![0][i] = sinf(Float(i) * 0.041)
            buffer.floatChannelData![1][i] = 0.4 * cosf(Float(i) * 0.017)
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let output = try AVAudioFile(forWriting: file, settings: settings)
            try output.write(from: buffer)
        }
        let range = PreviewRange(url: file, exactStart: .zero, exactEnd: .init(numerator: 1, denominator: 2))
        let timeline = ReverseAudioTimeline(ranges: [range], offsets: [0], composition: AVURLAsset(url: file))
        let reader = ScrubAudioReader()
        for speed in [1, 2, 4, 8] {
            let upper = 21_603
            let boundary = upper - speed * 941
            let first = await reader.reverseBlock(timeline, from: Int64(boundary), to: Int64(upper), speed: speed)
            let second = await reader.reverseBlock(timeline, from: 0, to: Int64(boundary), speed: speed)
            let samples = first + second
            XCTAssertEqual(samples.count, ((upper + speed - 1) / speed) * 2)
            let offsets = [0, 939, 940, 941, 942, samples.count / 2 - 1]
            for offset in offsets {
                let end = upper - offset * speed
                let start = max(0, end - speed)
                for ch in 0..<2 {
                    let source = buffer.floatChannelData![ch]
                    let mean = (start..<end).reduce(Float(0)) { $0 + source[$1] } / Float(end - start)
                    XCTAssertEqual(samples[2 * offset + ch], mean, accuracy: 0.0001, "speed \(speed), offset \(offset)")
                }
            }
        }
    }

    func testNativeAndWebMGrainsPlaySelectedStereoSamplesInEitherDirection() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temp) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<48000 {
            let value = Float(sin(Double(i) * 0.05)) * 0.5
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = -value
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: temp, settings: settings)
            try file.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: temp)
        let audio = try await source.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)),
                                  of: try XCTUnwrap(audio.first), at: .zero)
        let webm = try XCTUnwrap(Bundle.module.url(forResource: "Scrub-Tone", withExtension: "webm",
                                                   subdirectory: "Fixtures"))
        let reader = ScrubAudioReader()
        for (url, asset) in [(temp, composition as AVAsset?), (webm, nil)] {
            let forward = try XCTUnwrap(ScrubAudioRequest(source: url, composition: asset, position: 0.4,
                                                         bounds: 0.4..<0.44, reverse: false))
            let backward = try XCTUnwrap(ScrubAudioRequest(source: url, composition: asset, position: 0.44,
                                                          bounds: 0.4..<0.44, reverse: true))
            XCTAssertEqual(forward.window, backward.window)
            let first = await reader.grain(forward)
            let second = await reader.grain(backward)
            let a = try XCTUnwrap(first)
            let b = try XCTUnwrap(second)
            XCTAssertEqual(a.stereo.count, 3840)
            XCTAssertEqual(b.stereo.count, a.stereo.count)
            XCTAssertGreaterThan(a.stereo.map(abs).max() ?? 0, 0.0001)
            for i in stride(from: 0, to: a.stereo.count, by: 118) {
                XCTAssertEqual(a.stereo[i], b.stereo[b.stereo.count - 2 - i], accuracy: 0.0001)
                XCTAssertEqual(a.stereo[i + 1], b.stereo[b.stereo.count - 1 - i], accuracy: 0.0001)
            }
        }
    }
}
