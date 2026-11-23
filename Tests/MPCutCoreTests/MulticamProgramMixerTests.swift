import Foundation
import XCTest
@testable import MPCutCore

final class MulticamProgramMixerTests: XCTestCase {
    func testChannelWeightsPreserveMonoAndStereoAndBoundSurround() {
        XCTAssertEqual(MulticamProgramMixer.channelWeights(inputChannels: ["FC"], outputChannels: 2), [[1], [1]])
        XCTAssertEqual(MulticamProgramMixer.channelWeights(inputChannels: ["FL", "FR"], outputChannels: 1), [[0.5, 0.5]])
        let speakers = ["FL", "FR", "FC", "LFE", "BL", "BR"]
        for channels in 1...2 {
            let matrix = MulticamProgramMixer.channelWeights(inputChannels: speakers, outputChannels: channels)
            XCTAssertEqual(matrix.count, channels)
            for weights in matrix {
                XCTAssertEqual(weights[3], 0)
                XCTAssertLessThanOrEqual(weights.reduce(0, +), 1)
            }
            XCTAssertGreaterThan(matrix[0][4], 0)
            XCTAssertGreaterThan(matrix[channels - 1][5], 0)
        }
    }

    func testIdenticalFullScaleLanesStayAtFullScale() {
        let input: [Float] = [1, -1]
        var output: [Double] = [0, 0]
        for _ in 0..<10 {
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    MulticamProgramMixer.accumulate(source, into: destination, channels: 2, laneCount: 10)
                }
            }
        }
        XCTAssertEqual(output.map { Float($0) }, input)
    }

    func testRenderedDownmixUsesFixedWeightsAcrossGapsAndSampleRates() throws {
        guard let helper = try? ReencodeEngine.findHelper(override: nil) else {
            throw XCTSkip("The FFmpeg helper is needed for the rendered downmix fixture.")
        }
        let runner = ReencodeEngine()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        func recording(_ name: String, values: [Float], rate: Int) throws -> MediaInfo {
            let input = directory.appendingPathComponent(name + ".raw")
            let output = directory.appendingPathComponent(name + ".wav")
            try (0..<rate / 10).flatMap { _ in values }.withUnsafeBytes { try Data($0).write(to: input) }
            try runner.runHelper(helper, arguments: [
                "-f", "f32le", "-ar", String(rate), "-ac", String(values.count), "-i", input.path,
                "-c:a", "pcm_f32le", output.path
            ], in: directory)
            return try Probe.read(output)
        }

        let mono = try recording("mono", values: [0.6], rate: 44_100)
        let stereo = try recording("stereo", values: [0.3, -0.3], rate: 48_000)
        let zero = RationalTime.zero
        let middle = RationalTime(numerator: 1, denominator: 20)
        let duration = RationalTime(numerator: 1, denominator: 10)
        let firstHalf = MulticamRange(from: zero, to: middle)
        let secondHalf = MulticamRange(from: middle, to: duration)
        let whole = MulticamRange(from: zero, to: duration)
        let lanes: [[ConvertedSoundSpan]] = [
            [.init(media: nil, stream: nil, input: firstHalf, output: firstHalf),
             .init(media: mono, stream: 0, input: firstHalf, output: secondHalf)],
            [.init(media: stereo, stream: 0, input: whole, output: whole)],
            [.init(media: nil, stream: nil, input: whole, output: whole)]
        ]

        let engine = MulticamEngine()
        for channels in 1...2 {
            let output = directory.appendingPathComponent("mix-\(channels).mov")
            let raw = directory.appendingPathComponent("mix-\(channels).raw")
            let plan = try engine.resolveDownmixedSound(lanes, duration: duration, container: "mov", action: .pcm,
                                                       channels: channels) { issue, _, _ in issue }
            XCTAssertEqual(plan.sampleRate, 48_000)
            XCTAssertEqual(plan.edit.identities.count, 2)
            try engine.writeConvertedSound(plan, to: output)
            try runner.runHelper(helper, arguments: ["-i", output.path, "-c:a", "pcm_f32le", "-f", "f32le", raw.path],
                                 in: directory)
            let data = try Data(contentsOf: raw)
            XCTAssertEqual(data.count, 4_800 * channels * 4)
            func sample(_ frame: Int, _ channel: Int = 0) -> Float {
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (frame * channels + channel) * 4, as: Float.self) }
            }
            if channels == 1 {
                XCTAssertEqual(sample(2_399), 0, accuracy: 0.0001)
                XCTAssertEqual(sample(2_400), 0.2, accuracy: 0.0001)
                XCTAssertEqual(sample(3_000), 0.2, accuracy: 0.0001)
            } else {
                XCTAssertEqual(sample(2_399), 0.1, accuracy: 0.0001)
                XCTAssertEqual(sample(2_399, 1), -0.1, accuracy: 0.0001)
                XCTAssertEqual(sample(2_400), 0.3, accuracy: 0.0001)
                XCTAssertEqual(sample(2_400, 1), 0.1, accuracy: 0.0001)
            }
        }
        let repeated = Array(repeating: lanes[1], count: 12)
        let result = directory.appendingPathComponent("many-lanes.mov")
        let plan = try engine.resolveDownmixedSound(repeated, duration: duration, container: "mov", action: .pcm,
                                                    channels: 2) { issue, _, _ in issue }
        try engine.writeConvertedSound(plan, to: result) { _ in
            let paths = FileManager.default.subpaths(atPath: directory.path) ?? []
            let staged = paths.filter { $0.hasPrefix("downmix-") && $0.hasSuffix("/lane.raw") }
            XCTAssertLessThanOrEqual(staged.count, 1, "Only one lane may occupy staging at any time")
        }
        let resultRaw = directory.appendingPathComponent("many-lanes.raw")
        try runner.runHelper(helper, arguments: ["-i", result.path, "-c:a", "pcm_f32le", "-f", "f32le", resultRaw.path],
                             in: directory)
        let original = directory.appendingPathComponent("stereo.raw")
        XCTAssertEqual(try Data(contentsOf: resultRaw), try Data(contentsOf: original))
    }
}
