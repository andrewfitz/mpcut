import AVFoundation
import MPCutCore
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

    func testForwardPlaybackRetainsSixDiscreteSurroundChannels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800))
            buffer.frameLength = buffer.frameCapacity
            let planes = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<6 {
                planes[channel].initialize(repeating: Float(channel + 1) / 16, count: Int(buffer.frameLength))
            }
            try file.write(from: buffer)
        }

        let reader = FFPreviewReader(audioOnly: true, preservesSurround: true)
        try reader.seek(url: url, to: 0, withAudio: true, audioTrack: 0)
        let batch = try reader.batch(from: 0, end: 0.1, timelineOffset: Double(0), first: false, cancelled: { false })
        let sample = try XCTUnwrap(batch.audio.first)
        let description = try XCTUnwrap(sample.formatDescription)
        XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame, 6)
        let block = try XCTUnwrap(sample.dataBuffer)
        var actual = [Float](repeating: 0, count: 6)
        let status = actual.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(actual, (1...6).map { Float($0) / 16 })
    }

    func testLinkedForwardMixAddsStereoOnlyToTheFrontSpeakers() throws {
        // Six distinct constant 48 kHz channels and a separate 32 kHz stereo track.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Linked-Surround", withExtension: "mkv",
                                                     subdirectory: "Fixtures"))
        let reader = FFPreviewReader(audioOnly: true, preservesSurround: true)
        for start in [0.04, 0.09, 0.02] {
            try reader.seek(url: url, to: start, withAudio: true)
            let batch = try reader.batch(from: start, end: start + 0.01,
                                         timelineOffset: Double(0), first: false, cancelled: { false })
            XCTAssertFalse(batch.noAudio)
            XCTAssertFalse(batch.partialAudio)
            let sample = try XCTUnwrap(batch.audio.first)
            let description = try XCTUnwrap(sample.formatDescription)
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mSampleRate, 48_000)
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame, 6)
            let layout = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil))
            XCTAssertEqual(layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelDescriptions)
            guard layout.pointee.mNumberChannelDescriptions == 6 else {
                return XCTFail("The linked mix must label all six speakers.")
            }
            let labelsOffset = try XCTUnwrap(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions))
            let speakers = UnsafeRawPointer(layout).advanced(by: labelsOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            XCTAssertEqual((0..<6).map { speakers[$0].mChannelLabel },
                           [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft,
                            kAudioChannelLabel_RearSurroundRight])
            let block = try XCTUnwrap(sample.dataBuffer)
            var actual = [Float](repeating: 0, count: 6)
            let status = actual.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            let expected: [Float] = [0.3125, 0.25, 0.1875, 0.25, 0.3125, 0.375]
            for (value, reference) in zip(actual, expected) {
                XCTAssertEqual(value, reference, accuracy: 0.0001)
            }
        }
    }

    @MainActor
    func testSelectionMatchesMovieTrackIDWhenNativeOrdinalsShift() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Audio-Ordinal-Subtitle-First", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspect(url)
        var range = PreviewRange(media: media, from: .zero, to: media.duration)
        let sourceIDs = try XCTUnwrap(range.audioTrackIDs)
        XCTAssertEqual(sourceIDs.count, 2)
        let selectedID = try XCTUnwrap(sourceIDs.first)
        // Simulate the native reader omitting a leading indexed audio track.
        range.audioTrackIDs = [kCMPersistentTrackID_Invalid] + sourceIDs
        range.audioTrack = 1
        let composition = try await SequencePreview.makeAudioComposition([range])
        let track = try XCTUnwrap(composition.tracks(withMediaType: .audio).first)
        let segment = try XCTUnwrap(track.segments.first { !$0.isEmpty })
        XCTAssertEqual(segment.sourceTrackID, selectedID)
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
