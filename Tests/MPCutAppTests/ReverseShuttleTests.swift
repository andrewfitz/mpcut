import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ReverseShuttleTests: XCTestCase {
    @MainActor
    func testReverseClockHoldsWhenRefillCompletesBetweenDisplayTicks() async throws {
        let engine = AVAudioEngine()
        let player = ReverseAudioPlayer(engine: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        defer { player.stop() }
        player.start(ReverseAudioTimeline(regions: []), at: 1, speed: 1)

        let primeDeadline = ContinuousClock.now + .seconds(3)
        while player.bufferedFrames < 19_200, .now < primeDeadline { try await Task.sleep(for: .milliseconds(5)) }
        guard engine.isRunning, player.bufferedFrames == 19_200 else { return XCTFail("Reverse audio did not prime") }
        var frames = 19_200 - 256
        while frames > 0 {
            let count = min(512, frames)
            XCTAssertEqual(try engine.renderOffline(AVAudioFrameCount(count), to: buffer), .success)
            frames -= count
        }
        player.tick()
        // Cross the end of the queue before the pending decode can resume.
        XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)

        let refillDeadline = ContinuousClock.now + .seconds(3)
        while player.bufferedFrames < 9_600, .now < refillDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(player.bufferedFrames, 9_600)
        XCTAssertEqual(try XCTUnwrap(player.position), 0.6, accuracy: 1 / 48_000)
        XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
        XCTAssertEqual(try XCTUnwrap(player.position), 0.6 - 512.0 / 48_000, accuracy: 1 / 48_000)
    }

    // The left channel rises from 250 Hz at 360 Hz/s, and the right falls from
    // 2000 Hz at 280 Hz/s. Their instantaneous frequencies identify source time
    // even after AAC or Opus compression.
    @MainActor
    func testJDeliversContinuousReversedStereoAcrossAnEdit() async throws {
        for ext in ["mov", "webm"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: ext,
                                                      subdirectory: "Fixtures"))
            for speed in [1, 2, 4, 8] {
                try await verifyShuttle(url, speed: speed)
            }
        }
    }

    @MainActor
    private func verifyShuttle(_ url: URL, speed: Int) async throws {
        let engine = AVAudioEngine()
        let player = ReverseAudioPlayer(engine: engine)
        let preview = SequencePreview(reverseAudio: player)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        defer { preview.pause() }
        preview.scrubSoundEnabled = false
        let ranges = [
            PreviewRange(url: url, exactStart: .init(numerator: 15, denominator: 10),
                         exactEnd: .init(numerator: 23, denominator: 10)),
            PreviewRange(url: url, exactStart: .init(numerator: 1, denominator: 10),
                         exactEnd: .init(numerator: 11, denominator: 10))
        ]
        preview.update(ranges, at: 1.8)
        let deadline = ContinuousClock.now + .seconds(5)
        while preview.playbackRate == 0, preview.issue == nil, .now < deadline {
            preview.shuttle(-1)
            if preview.playbackRate == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        let label = "\(url.pathExtension) at \(speed)×"
        guard preview.playbackRate < 0 else {
            return XCTFail("\(label): reverse shuttle did not start within 5 s: \(preview.issue ?? "no issue reported")")
        }
        // Each press doubles the rate; a press without effect must end the loop.
        var presses = 0
        while preview.playbackRate < 0, -preview.playbackRate < Float(speed), presses < 8 {
            preview.shuttle(-1)
            presses += 1
        }
        XCTAssertEqual(preview.playbackRate, -Float(speed), label)
        while !engine.isRunning, preview.issue == nil, .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard engine.isRunning else { return XCTFail("\(label): \(preview.issue ?? "no reverse audio")") }

        let rendered = try await render(seconds: 1.42 / Double(speed), engine: engine, player: player, format: format)
        // The picture clock settles on the rendered audio position and then
        // holds it. Poll for that instead of trusting one fixed short delay.
        let settled = ContinuousClock.now + .seconds(2)
        while abs(preview.time - 0.38) > 0.08, .now < settled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(preview.time, 0.38, accuracy: 0.08, "Picture and audio diverged in \(label)")
        let first = try XCTUnwrap(rendered[0].firstIndex { abs($0) > 0.035 }, label)
        for position in [0.1, 0.42, 0.82, 1.12, 1.33] {
            let start = first + Int(position * 48_000 / Double(speed))
            let count = Int(0.054 * 48_000 / Double(speed))
            guard start + count <= rendered[0].count else { XCTFail("Missing audio in \(label)"); return }
            let midpoint = position + 0.027
            let sourceTime = midpoint < 1 ? 1.1 - midpoint : 2.3 - (midpoint - 1)
            let frequencies = [250 + 360 * sourceTime, 2000 - 280 * sourceTime]
            for ch in 0..<2 {
                let samples = rendered[ch][start..<(start + count)]
                let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
                let hz = Double(crossings) * 48_000 / Double(count)
                XCTAssertEqual(hz, frequencies[ch] * Double(speed), accuracy: 55 * Double(speed),
                               "\(label) channel \(ch) at source \(sourceTime)")
            }
        }
        // Check the interior of the stream every 4 ms, including the reordering
        // join and decode-window seams. Replaying independent scrub grains leaves gaps.
        let left = rendered[0]
        let minLevel = stride(from: first + 240, to: left.count - 192, by: 192).map { index in
            left[index..<(index + 192)].reduce(Float(0)) { $0 + $1 * $1 } / 192
        }.min() ?? 0
        XCTAssertGreaterThan(minLevel, 0.001, label)
        if speed == 1 {
            let join = first + 48_000
            let maximumStep = (first + 240..<left.count).lazy
                .filter { abs($0 - join) > 120 }.map { abs(left[$0] - left[$0 - 1]) }.max() ?? 0
            XCTAssertLessThan(maximumStep, 0.16, "Discontinuity away from the edit in \(label)")
        }
        // Reposition while J is held. The queued old take must be flushed before
        // any of its samples can reach the restarted stream.
        preview.seek(to: 1.65)
        let seekDeadline = ContinuousClock.now + .seconds(3)
        while !engine.isRunning, .now < seekDeadline { try await Task.sleep(for: .milliseconds(3)) }
        guard engine.isRunning else { return XCTFail("Audio did not resume after seeking at \(label)") }
        let afterSeek = try await render(seconds: 0.12 / Double(speed), engine: engine, player: player, format: format)
        let seekIndex = try XCTUnwrap(afterSeek[0].firstIndex { abs($0) > 0.035 }, label)
        let activeSamples = afterSeek[0].dropFirst(seekIndex + 12)
        let crossings = zip(activeSamples, activeSamples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        let hz = Double(crossings) * 48_000 / Double(activeSamples.count)
        XCTAssertEqual(hz, (250 + 360 * 0.89) * Double(speed), accuracy: 60 * Double(speed), "seek \(label)")

        preview.isMuted = true
        let muted = try await render(seconds: 0.045, engine: engine, player: player, format: format)
        XCTAssertLessThan(muted[0].suffix(512).map(abs).max() ?? 1, 0.001, label)
        preview.shuttle(1)
        XCTAssertEqual(preview.playbackRate, 1, label)
        XCTAssertFalse(engine.isRunning, "Reverse output continued after L: \(label)")
        preview.pause()
    }

    @MainActor
    private func render(seconds: Double, engine: AVAudioEngine, player: ReverseAudioPlayer, format: AVAudioFormat) async throws -> [[Float]] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let count = Int((seconds * format.sampleRate).rounded())
        var channels: [[Float]] = [[], []]
        while channels[0].count < count {
            guard engine.isRunning else { XCTFail("Reverse output stopped early"); break }
            let remaining = count - channels[0].count
            let frames = AVAudioFrameCount(min(512, remaining))
            // Advance the manual device clock only when the decoded queue has enough
            // runway. A render quantum can consume ahead of the clock it reports.
            let runway = Int64(min(remaining, 9_600))
            let ready = ContinuousClock.now + .seconds(5)
            while player.bufferedFrames < runway, engine.isRunning, .now < ready {
                player.tick()
                try await Task.sleep(for: .milliseconds(5))
            }
            guard player.bufferedFrames >= runway else {
                XCTFail("Reverse decoder did not supply the next \(runway) frames")
                break
            }
            let status = try engine.renderOffline(frames, to: buffer)
            XCTAssertEqual(status, .success)
            guard status == .success else { break }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else {
                XCTFail("Offline render returned no usable audio frames")
                break
            }
            for ch in 0..<2 {
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: Int(buffer.frameLength)))
            }
            player.tick()
        }
        XCTAssertEqual(channels[0].count, count, "Offline render returned fewer frames than requested")
        return channels
    }
}
