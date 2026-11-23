import AVFoundation
import FFPreview
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamProgramAudioTests: XCTestCase {
    func testMixedPlaybackAndScrubUseEveryLaneOnTheProgramClock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = CutEngine(useSidecar: false)
        let a = try engine.inspect(namedSound("a", rate: 48_000, values: [0.25, 0.125], directory: directory))
        let b = try engine.inspect(namedSound("b", rate: 44_100, values: [0.5, 0.5], directory: directory))
        let media = ["a": a, "b": b]
        let fifth = unit(1, 5)
        let tenth = unit(1, 10)
        let end = unit(3, 10)

        // Lane A repeats its second half at the edit. Lane B is silent until
        // the edit, when both lanes play at unity conversion and half gain.
        let timeline = MulticamMixedAudioTimeline(lanes: [
            .init(label: "A", spans: [
                try span("a", input: .zero..<fifth, output: .zero..<fifth, media: media),
                try span("a", input: tenth..<fifth, output: fifth..<end, media: media)
            ]),
            .init(label: "B", spans: [
                try span("b", input: .zero..<tenth, output: fifth..<end, media: media)
            ])
        ])

        let seek = unit(17, 100)
        let reader = try MulticamProgramAudioReader(timeline: timeline, from: seek)
        var samples: [CMSampleBuffer] = []
        for _ in 0..<500 {
            let batch = try reader.read(cancelled: { false })
            XCTAssertNil(batch.issue)
            samples.append(contentsOf: batch.samples)
            if batch.end { break }
        }
        let first = try XCTUnwrap(samples.first)
        XCTAssertEqual(first.presentationTimeStamp.seconds, seek.seconds, accuracy: 1.0 / 48_000)
        let playback = try XCTUnwrap(ScrubGrain(samples: samples, window: seek.seconds..<end.seconds,
                                                 reverse: false, fadeEdges: false))
        XCTAssertEqual(playback.rate, 48_000)
        assertStereo(playback.stereo, at: 400, equals: 0.0625)
        assertStereo(playback.stereo, at: 2_000, equals: 0.3125)

        let scrub = try XCTUnwrap(timeline.grain(window: 0.18..<0.24, reverse: true, fadeEdges: true))
        assertStereo(scrub.stereo, at: 500, equals: 0.3125)
        assertStereo(scrub.stereo, at: 2_500, equals: 0.0625)

        let reversed = await ScrubAudioReader().reverseBlock(.init(mixedAudio: timeline),
                                                              from: 8_640, to: 11_520, speed: 2)
        assertStereo(reversed, at: 200, equals: 0.3125)
        assertStereo(reversed, at: 1_100, equals: 0.0625)
    }

    func testSubsampleSourceEditUsesNearestSampleAtRoundedOutputEdge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = CutEngine(useSidecar: false)
        for rate in [44_100, 96_000] {
            let source = try engine.inspect(namedSound("short-\(rate)", rate: rate, values: [0.5], directory: directory))
            let input = unit(1, 480_000)..<unit(2, 480_000)
            let start = unit(1, 100_000)
            let output = start..<(try start.adding(unit(1, 480_000)))
            let edit = try span("short", input: input, output: output, media: ["short": source])
            let timeline = MulticamMixedAudioTimeline(lanes: [.init(label: "Short", spans: [edit])])

            let grain = try XCTUnwrap(timeline.grain(window: 0..<(1.0 / 48_000), reverse: false, fadeEdges: false))
            XCTAssertEqual(grain.stereo.count, 2)
            assertStereo(grain.stereo, at: 0, equals: 0.5)
        }
    }

    func testCoarseInputTimestampsDoNotRestartResamplingBetweenPackets() throws {
        let fine = try mixPackets(tick: CMTime(value: 1, timescale: 44_100),
                                  starts: (0..<4).map { CMTime(value: Int64($0 * 1_024), timescale: 44_100) })
        let coarse = try mixPackets(tick: CMTime(value: 1, timescale: 1_000),
                                    starts: [Int64(0), 23, 46, 70].map { CMTime(value: $0, timescale: 1_000) })
        XCTAssertGreaterThan(fine.count, 8_000)
        XCTAssertEqual(coarse, fine)
    }

    func testExplicitTwoChannelMatrixLayoutRetainsItsSpeakers() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MatrixStereo))
        let audio = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let names = (0..<2).map { String(cString: mp_program_mix_speaker(audio.formatDescription, Int32($0))) }
        XCTAssertEqual(names, ["DL", "DR"])
        XCTAssertEqual(MulticamProgramMixer.channelWeights(inputChannels: names, outputChannels: 2),
                       [[0.5, 0.5], [0.5, 0.5]])
    }

    private func mixPackets(tick: CMTime, starts: [CMTime]) throws -> [Float] {
        let mixer = try XCTUnwrap(mp_program_mix_create(1))
        defer { mp_program_mix_close(mixer) }
        let outputEnd = CMTime(value: Int64(starts.count * 1_024), timescale: 44_100)
        var packets = try starts.enumerated().map { index, start in
            let values = (0..<1_024).map { sin(Float(index * 1_024 + $0) / 31) }
            return try pcmPacket(values, start: start)
        }
        var frames: Int64 = 0
        var output: [Float] = []
        let matrix: [Double] = [1, 1]
        for _ in 0..<100 {
            var sample: CMSampleBuffer?
            var lane: Int32 = -1
            let result = mp_program_mix_next(mixer, &sample, &lane)
            XCTAssertNotEqual(result, MPPreviewError.rawValue)
            if result == MPPreviewEnd.rawValue { return output }
            if result == MPPreviewAgain.rawValue, lane == 0 {
                let packet = packets.isEmpty ? nil : packets.removeFirst()
                matrix.withUnsafeBufferPointer {
                    mp_program_mix_submit(mixer, lane, packet, $0.baseAddress, packets.count == starts.count - 1,
                                          tick, Int64(starts.count * 1_024), .zero, outputEnd)
                }
            }
            if let sample {
                XCTAssertEqual(sample.presentationTimeStamp, CMTime(value: frames, timescale: 48_000))
                frames += Int64(sample.numSamples)
                let pcm = try XCTUnwrap(sample.dataBuffer)
                var block = [Float](repeating: 0, count: sample.numSamples * 2)
                let status = block.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(pcm, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, noErr)
                output.append(contentsOf: block)
            }
        }
        XCTFail("Mixer did not finish after reading the input packets.")
        return output
    }

    private func pcmPacket(_ values: [Float], start: CMTime) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description), noErr)
        let extent = values.count * MemoryLayout<Float>.size
        var data: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: extent, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: extent, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &data), noErr)
        let storage = try XCTUnwrap(data)
        XCTAssertEqual(values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: storage, offsetIntoDestination: 0,
                                          dataLength: $0.count)
        }, noErr)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: storage, formatDescription: try XCTUnwrap(description), sampleCount: values.count,
            presentationTimeStamp: start, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func unit(_ numerator: Int64, _ denominator: Int64) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private func span(_ id: String, input: Range<RationalTime>, output: Range<RationalTime>,
                      media: [String: MediaInfo]) throws -> MulticamPreviewAudioSpan {
        let stream = try XCTUnwrap(media[id]?.audio.first?.stream.index)
        let span = MulticamSpan(source: id, stream: stream, input: .init(from: input.lowerBound, to: input.upperBound),
                                output: .init(from: output.lowerBound, to: output.upperBound))
        return try XCTUnwrap(MulticamPreviewAudioSpan(span: span, media: media))
    }

    private func assertStereo(_ samples: [Float], at frame: Int, equals expected: Float,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard samples.indices.contains(2 * frame + 1) else {
            XCTFail("Missing mixed audio at frame \(frame).", file: file, line: line)
            return
        }
        XCTAssertEqual(samples[2 * frame], expected, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(samples[2 * frame + 1], expected, accuracy: 0.001, file: file, line: line)
    }

    private func namedSound(_ name: String, rate: Int, values: [Float], directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate / 10)))
        block.frameLength = block.frameCapacity
        let channel = try XCTUnwrap(block.floatChannelData?[0])
        for value in values {
            channel.update(repeating: value, count: Int(block.frameLength))
            try file.write(from: block)
        }
        return url
    }
}
