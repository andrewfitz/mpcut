import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptFixtureTests: XCTestCase {
    func testExtractedClickAgreesWithIndexedSourceClock() throws {
        let root = try fixtureDirectory()
        let engine = CutEngine(useSidecar: false)
        for (name, sourceSample) in [("priming-click", 20_000), ("delayed-click", 28_000)] {
            let source = root.appendingPathComponent(name + ".mov")
            let wav = root.appendingPathComponent(name + "-extracted.wav")
            for index in [try engine.inspect(source, keyframes: true), try engine.inspectMulticamSource(source)] {
                let track = try XCTUnwrap(index.audio.first { $0.stream.index == 1 })
                XCTAssertEqual(track.hasPriming, name == "priming-click", name)
                XCTAssertEqual(track.start, name == "priming-click" ? .zero : RationalTime(numerator: 1, denominator: 2), name)
                try engine.extractTranscriptAudio(index, stream: 1, to: wav)
                let pcm = try readPCM(wav)
                let peak = try XCTUnwrap(pcm.indices.max { abs(Int(pcm[$0])) < abs(Int(pcm[$1])) })
                XCTAssertGreaterThan(abs(Int(pcm[peak])), 1_000, name)
                XCTAssertLessThanOrEqual(abs(peak - sourceSample), 1, name)
            }
        }
    }

    func testExtractionPreservesDialogueAfterPacketGap() throws {
        let root = try fixtureDirectory()
        let engine = CutEngine(useSidecar: false)
        let reference = try readPCM(root.appendingPathComponent("helper-session/close.wav"))
        for name in ["close.mov", "close-gap.mkv"] {
            let index = try engine.inspectMulticamSource(root.appendingPathComponent(name))
            let track = try XCTUnwrap(index.audio.first { $0.stream.index == 1 })
            XCTAssertEqual(track.pcmContinuity, name == "close.mov", name)
            let wav = root.appendingPathComponent(name + "-extracted.wav")
            try engine.extractTranscriptAudio(index, stream: 1, to: wav)
            let pcm = try readPCM(wav)
            XCTAssertEqual(pcm.count, 17 * 16_000, name)
            XCTAssertTrue(pcm == reference, "PCM shifted or changed where the fixture expects exact samples: \(name)")
        }
    }

    private func fixtureDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MPCUT_SPOKEN_FIXTURE"] else {
            throw XCTSkip("Generate the local fixture and set MPCUT_SPOKEN_FIXTURE to its directory.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func readPCM(_ wave: URL) throws -> [Int16] {
        let bytes = try Data(contentsOf: wave)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
        var chunk = 12
        while chunk + 8 <= bytes.count {
            let name = String(decoding: bytes[chunk..<(chunk + 4)], as: UTF8.self)
            let length = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: chunk + 4, as: UInt32.self) })
            let start = chunk + 8
            guard length <= bytes.count - start else { break }
            if name == "fmt " {
                guard length >= 16 else { break }
                XCTAssertEqual(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start, as: UInt16.self) }, 1)
                XCTAssertEqual(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start + 2, as: UInt16.self) }, 1)
                XCTAssertEqual(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self) }, 16_000)
                XCTAssertEqual(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start + 14, as: UInt16.self) }, 16)
            } else if name == "data" {
                XCTAssertEqual(length % 2, 0)
                return bytes.withUnsafeBytes { buffer in
                    stride(from: start, to: start + length, by: 2).map {
                        Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: Int16.self))
                    }
                }
            }
            chunk = start + length + length % 2
        }
        XCTFail("Missing PCM data chunk in \(wave.path)")
        return []
    }
}
