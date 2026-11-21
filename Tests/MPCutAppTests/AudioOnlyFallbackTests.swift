import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class AudioOnlyFallbackTests: XCTestCase {
    private func recording() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Chirp", withExtension: "opus",
                                       subdirectory: "Fixtures"))
    }

    func testStandaloneFallbackMonitorsTheSelectedAudioTrack() async throws {
        // The first track is 440 Hz and the second is 1340 Hz, with default
        // disposition set on the second.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka",
                                                    subdirectory: "Fixtures"))
        let media = try CutEngine().inspect(url)
        XCTAssertEqual(media.primaryStream.index, 0)
        let window = 0.05..<0.15
        let reader = FFPreviewReader(audioOnly: true)
        let forward = FFPreviewReader()
        for (track, expected): (Int?, Double) in [(nil, 440), (1, 1340), (0, 440)] {
            let samples = try reader.scrubSamples(url: url, range: window, audioOrigin: media.origin, audioTrack: track)
            let grain = try XCTUnwrap(ScrubGrain(samples: samples, window: window, reverse: false, fadeEdges: false))
            XCTAssertEqual(tone(in: grain.stereo, channels: 2), expected, accuracy: 20)

            try forward.seek(url: url, to: window.lowerBound, withAudio: true, soundOnlySource: true,
                             audioOrigin: media.origin, audioTrack: track)
            let batch = try forward.batch(from: window.lowerBound, end: window.upperBound,
                                          timelineOffset: 0, first: false, cancelled: { false })
            let playing = try XCTUnwrap(ScrubGrain(samples: batch.audio, window: window, reverse: false, fadeEdges: false))
            XCTAssertEqual(tone(in: playing.stereo, channels: 2), expected, accuracy: 20)

            var range = PreviewRange(url: url, exactStart: .init(numerator: 5, denominator: 100),
                                     exactEnd: .init(numerator: 15, denominator: 100),
                                     isAudioOnly: true, audioOrigin: media.origin)
            range.audioTrack = track
            let timeline = ReverseAudioTimeline(ranges: [range], offsets: [0], composition: nil)
            let reverse = await ScrubAudioReader().reverseBlock(timeline, from: 0, to: 4_800, speed: 1)
            XCTAssertEqual(tone(in: reverse, channels: 2), expected, accuracy: 20)
        }
        XCTAssertTrue(try reader.scrubSamples(url: url, range: window, audioOrigin: media.origin, audioTrack: 2).isEmpty)
    }

    @MainActor
    func testNativeStandaloneScrubChangesWithSelectedTrack() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mov",
                                                    subdirectory: "Fixtures"))
        let media = try CutEngine().inspect(url)
        let engine = AVAudioEngine()
        let preview = SequencePreview(scrubAudioEngine: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        defer { preview.pause() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        for (track, expected) in [(0, 440.0), (1, 1340.0)] {
            var range = PreviewRange(media: media, from: .zero, to: media.duration)
            range.audioTrack = track
            preview.update([range], at: 0.05)
            XCTAssertFalse(engine.isRunning)
            let deadline = ContinuousClock.now + .seconds(3)
            while !engine.isRunning, .now < deadline {
                preview.scrub(to: 0.05, rangeIndex: 0, sourceFrame: 0.05)
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(engine.isRunning)
            var output: [Float] = []
            for _ in 0..<5 {
                XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
                output.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            XCTAssertEqual(tone(in: Array(output.dropFirst(512))), expected, accuracy: 50)
        }
    }

    private func tone(in samples: [Float], channels: Int = 1) -> Double {
        let crossings = stride(from: 0, to: samples.count - channels, by: channels).filter { frame in
            samples[frame] <= 0 && samples[frame + channels] > 0
        }.count
        return Double(crossings * channels) * 48_000 / Double(samples.count)
    }

    @MainActor
    func testSeekingCancelsAStandaloneTrimAudition() async throws {
        let source = try recording()
        let range = PreviewRange(url: source, exactStart: .zero, exactEnd: .init(numerator: 2),
                                 isAudioOnly: true, audioOrigin: .zero)
        let engine = AVAudioEngine()
        let preview = SequencePreview(scrubAudioEngine: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        defer { preview.pause() }
        preview.update([range], at: 0)
        let requested = ContinuousClock.now
        preview.audition(range, at: 1.5, sourceDuration: 2)
        let deadline = requested + .seconds(3)
        while !engine.isRunning, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(engine.isRunning, "The trim audition did not start within 3 s")
        let startup = ContinuousClock.now - requested
        preview.seek(to: 0.4)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(preview.time, 0.4)

        preview.audition(range, at: 1.6, sourceDuration: 2)
        preview.seek(to: 0.6)
        // The cancelled request has no completion to await. Watch for several
        // times as long as the uncancelled audition above needed to be heard,
        // so a late grain from the cancelled read cannot slip past this check.
        let quiet = max(.seconds(1), min(startup * 4, .seconds(3)))
        let watchUntil = ContinuousClock.now + quiet
        while .now < watchUntil {
            XCTAssertFalse(engine.isRunning, "A cancelled audition started sound after the seek")
            if engine.isRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(preview.time, 0.6)
    }

    @MainActor
    func testScrubbingAcrossAReorderedJoinStopsThePreviousGrain() async throws {
        let source = try recording()
        let ranges = [
            PreviewRange(url: source, exactStart: .init(numerator: 1), exactEnd: .init(numerator: 2),
                         isAudioOnly: true, audioOrigin: .zero),
            PreviewRange(url: source, exactStart: .zero, exactEnd: .init(numerator: 1),
                         isAudioOnly: true, audioOrigin: .zero)
        ]
        let engine = AVAudioEngine()
        let preview = SequencePreview(scrubAudioEngine: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        defer { preview.pause() }
        preview.update(ranges, at: 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while !engine.isRunning, .now < deadline {
            preview.scrub(to: 0.5, rangeIndex: 0, sourceFrame: 1.5)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(engine.isRunning)
        preview.scrub(to: 1.5, rangeIndex: 1, sourceFrame: 0.5)
        XCTAssertFalse(engine.isRunning)

        let joinDeadline = ContinuousClock.now + .seconds(3)
        while !engine.isRunning, .now < joinDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(engine.isRunning)
        preview.endScrub()
        XCTAssertFalse(engine.isRunning)
    }

    func testMP3GaplessClockSurvivesAnAliasAndSeeksToExactSourceSamples() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Gapless-Crop", withExtension: "mp3", subdirectory: "Fixtures"))
        let artwork = try XCTUnwrap(Bundle.module.url(forResource: "Covered-Audio", withExtension: "mp3", subdirectory: "Fixtures"))
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dat")
        try FileManager.default.copyItem(at: fixture, to: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        for file in [alias, artwork] {
            let media = try CutEngine().inspect(file)
            XCTAssertTrue(PreviewRange(media: media, from: .zero, to: media.duration).usesMP3GaplessClock)
        }

        // This MPEG-2 clip retains the MP3 packets covering samples 6629..<23897
        // of a 22050 Hz stereo source. Reference values are from decoding that
        // entire source before cutting; the crop includes hidden reservoir frames.
        let media = try CutEngine().inspect(alias)
        let rate = 22_050.0
        let reader = FFPreviewReader(audioOnly: true)
        let checks: [(Int, Float, Float)] = [
            (14599, -0.11389257, 0.08451541), (0, 0.01012108, -0.09577872),
            (133, -0.00348042, -0.0141388), (1999, 0.12723245, 0.12698497),
            (7999, -0.12199502, -0.12216274), (4511, -0.35215002, 0.01685897)
        ]
        for (sample, left, right) in checks {
            let window = Double(sample) / rate..<Double(sample + 128) / rate
            let buffers = try reader.scrubSamples(url: alias, range: window, audioOrigin: media.origin)
            let grain = try XCTUnwrap(ScrubGrain(samples: buffers, window: window, reverse: false, fadeEdges: false))
            XCTAssertEqual(grain.stereo[0], left, accuracy: 0.00001, "Left channel at sample \(sample)")
            XCTAssertEqual(grain.stereo[1], right, accuracy: 0.00001, "Right channel at sample \(sample)")
        }
    }

    // The standalone Ogg fixture contains the two independent frequency sweeps
    // from Shuttle-Chirp.webm, remuxed without changing its Opus packets.
    func testScrubAndReverseUseStandaloneAudioClockAfterSeeking() async throws {
        let url = try recording()
        let reader = FFPreviewReader(audioOnly: true)
        let rate = 48_000
        let window = 1.5..<1.55
        let samples = try reader.perform(cancelled: { false }) {
            try reader.scrubSamples(url: url, range: window, audioOrigin: .zero)
        }
        let pcm = try XCTUnwrap(ScrubGrain(samples: samples, window: window, reverse: false, fadeEdges: false))
        XCTAssertEqual(pcm.stereo.count, 4800)
        func frequency(channel: Int) -> Double {
            let indices = stride(from: channel, to: pcm.stereo.count - 2, by: 2)
            let crossings = indices.filter { pcm.stereo[$0] <= 0 && pcm.stereo[$0 + 2] > 0 }.count
            return Double(crossings) * 20
        }
        XCTAssertEqual(frequency(channel: 0), 250 + 360 * 1.525, accuracy: 40)
        XCTAssertEqual(frequency(channel: 1), 2000 - 280 * 1.525, accuracy: 40)

        let range = PreviewRange(url: url, exactStart: .init(numerator: 3, denominator: 2),
                                 exactEnd: .init(numerator: 2), isAudioOnly: true, audioOrigin: .zero)
        let reversed = await ScrubAudioReader().reverseBlock(
            ReverseAudioTimeline(ranges: [range], offsets: [0], composition: nil),
            from: 0, to: Int64(rate / 20), speed: 1)
        XCTAssertEqual(reversed.count, pcm.stereo.count)
        for frame in stride(from: 0, to: pcm.stereo.count / 2, by: 113) {
            let other = pcm.stereo.count - 2 - frame * 2
            XCTAssertEqual(reversed[frame * 2], pcm.stereo[other], accuracy: 0.0001)
            XCTAssertEqual(reversed[frame * 2 + 1], pcm.stereo[other + 1], accuracy: 0.0001)
        }

        // Cancellation discards the current decoder. A subsequent read reopens it.
        XCTAssertThrowsError(try reader.perform(cancelled: { true }) {
            try reader.scrubSamples(url: url, range: window)
        })
        let reopened = try reader.scrubSamples(url: url, range: window, audioOrigin: .zero)
        let restored = try XCTUnwrap(ScrubGrain(samples: reopened, window: window, reverse: false, fadeEdges: false))
        XCTAssertEqual(restored.stereo, pcm.stereo)
    }

    func testForwardBatchClipsSoundAtTheRequestedSamplesAndRebasesEachJoin() throws {
        let reader = FFPreviewReader()
        let url = try recording()
        var dest = 0.0
        for source in [1.5..<1.55, 0.4..<0.45] {
            try reader.seek(url: url, to: source.lowerBound, withAudio: true, soundOnlySource: true, audioOrigin: .zero)
            var buffers: [CMSampleBuffer] = []
            var ended = false
            for _ in 0..<20 {
                let batch = try reader.batch(from: source.lowerBound, end: source.upperBound,
                                             timelineOffset: dest - source.lowerBound, first: false, cancelled: { false })
                XCTAssertTrue(batch.video.isEmpty)
                buffers += batch.audio
                if batch.end { ended = true; break }
            }
            XCTAssertTrue(ended)
            XCTAssertEqual(buffers.reduce(0) { $0 + $1.numSamples }, 2400)
            for buffer in buffers {
                XCTAssertEqual(buffer.presentationTimeStamp.seconds, dest, accuracy: 0.000001)
                dest += Double(buffer.numSamples) / 48_000
            }
        }
        XCTAssertEqual(dest, 0.1, accuracy: 0.000001)
    }

    @MainActor
    func testAudioOnlyPlaybackCrossesReorderedJoinAndStopsAtEnd() async throws {
        let url = try recording()
        let ranges = [
            PreviewRange(url: url, exactStart: .init(numerator: 1), exactEnd: .init(numerator: 13, denominator: 10),
                         isAudioOnly: true, audioOrigin: .zero),
            PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 1, denominator: 5),
                         isAudioOnly: true, audioOrigin: .zero)
        ]
        let completed = expectation(description: "Played the two retained excerpts")
        var times: [Double] = []
        let player = WebSequencePlayback(ranges: ranges, onFrame: { _ in
            XCTFail("Audio-only playback attempted to display a picture")
        }, onTime: { time in
            times.append(time)
            if time >= 0.5 { completed.fulfill() }
        }, onIssue: { issue in
            XCTFail(issue)
            completed.fulfill()
        }, onAudioWarning: { warning in
            XCTAssertNil(warning)
        })
        player.setGain(0)
        player.seek(to: 0.15)
        player.play()
        await fulfillment(of: [completed], timeout: 4)
        player.pause()
        XCTAssertEqual(times.first, 0.15)
        XCTAssertTrue(times.contains { $0 > 0.3 && $0 < 0.5 })
        XCTAssertEqual(times.last, 0.5)
    }
}
