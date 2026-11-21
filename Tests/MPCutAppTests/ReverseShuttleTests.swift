import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ReverseShuttleTests: XCTestCase {
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
        let preview = SequencePreview(reverseAudioEngine: engine)
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

        let rendered = try await render(seconds: 1.42 / Double(speed), engine: engine, format: format)
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
        let afterSeek = try await render(seconds: 0.12 / Double(speed), engine: engine, format: format)
        let seekIndex = try XCTUnwrap(afterSeek[0].firstIndex { abs($0) > 0.035 }, label)
        let activeSamples = afterSeek[0].dropFirst(seekIndex + 12)
        let crossings = zip(activeSamples, activeSamples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        let hz = Double(crossings) * 48_000 / Double(activeSamples.count)
        XCTAssertEqual(hz, (250 + 360 * 0.89) * Double(speed), accuracy: 60 * Double(speed), "seek \(label)")

        preview.isMuted = true
        let muted = try await render(seconds: 0.045, engine: engine, format: format)
        XCTAssertLessThan(muted[0].suffix(512).map(abs).max() ?? 1, 0.001, label)
        preview.shuttle(1)
        XCTAssertEqual(preview.playbackRate, 1, label)
        XCTAssertFalse(engine.isRunning, "Reverse output continued after L: \(label)")
        preview.pause()
    }

    @MainActor
    private func render(seconds: Double, engine: AVAudioEngine, format: AVAudioFormat) async throws -> [[Float]] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let count = Int((seconds * format.sampleRate).rounded())
        var channels: [[Float]] = [[], []]
        while channels[0].count < count {
            guard engine.isRunning else { XCTFail("Reverse output stopped early"); break }
            let frames = AVAudioFrameCount(min(512, count - channels[0].count))
            let status = try engine.renderOffline(frames, to: buffer)
            XCTAssertEqual(status, .success)
            guard status == .success, buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for ch in 0..<2 {
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: Int(buffer.frameLength)))
            }
            // Give the asynchronous decoder and the preview display clock time
            // to replenish the player, as a live audio device would.
            try await Task.sleep(for: .milliseconds(6))
        }
        return channels
    }
}
