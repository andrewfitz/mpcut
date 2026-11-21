import Foundation
@testable import MPCutCore
import XCTest

final class AudioSourceTests: XCTestCase {
    func testGaplessMP3WithCoverArtUsesAudibleClockAndSampleEdits() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Covered-Audio", withExtension: "mp3",
                                                     subdirectory: "Fixtures"))
        let engine = CutEngine()
        let media = try engine.inspect(fixture, keyframes: true)
        XCTAssertFalse(media.hasVideo)
        XCTAssertNil(media.videoStream)
        XCTAssertEqual(media.streams.map(\.kind), ["audio", "attachment"])
        XCTAssertTrue(media.frames.isEmpty)
        XCTAssertNil(media.copyIssue)
        XCTAssertEqual(media.origin, RationalTime(numerator: 1105, denominator: 44_100))
        XCTAssertEqual(media.duration, RationalTime(numerator: 173, denominator: 100))
        let track = try XCTUnwrap(media.audio.first)
        XCTAssertEqual(track.start, .zero)
        XCTAssertEqual(track.end, media.duration)
        XCTAssertEqual(media.audioEditBoundary(near: 0), .zero)
        XCTAssertEqual(track.packets[1].time, RationalTime(numerator: 47, denominator: 44_100))
        let first = RationalTime(numerator: 1, denominator: 44_100)
        XCTAssertEqual(media.steppingAudioBoundary(from: 0, direction: 1), first)
        XCTAssertEqual(media.steppingAudioBoundary(from: first.seconds, direction: -1), .zero)
        XCTAssertEqual(media.audioEditBoundary(near: 0.02, rounding: .down), RationalTime(numerator: 1, denominator: 50))
        XCTAssertEqual(media.audioEditBoundary(near: media.duration.seconds), media.duration)
        let wave = try AudioAnalysis.scan(media, stream: track.stream.index)
        XCTAssertGreaterThan(wave.peak(from: 0.1, to: 0.2) ?? 0, 0.02)
        XCTAssertLessThan(wave.peak(from: 0.6, to: 0.8) ?? 1, 0.001)
    }

    func testPCMSampleGridScalesWithoutPerSampleIndex() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleCount = 48_001
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) {
            withUnsafeBytes(of: number.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + sampleCount * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(48_000))
        append(UInt32(96_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(sampleCount * 2))
        data.append(Data(count: sampleCount * 2))
        try data.write(to: url)
        let engine = CutEngine()
        let preview = try engine.inspectForPreview(url)
        let media = try engine.inspect(url, keyframes: true, matchingPreview: preview)
        XCTAssertEqual(media.duration, RationalTime(numerator: Int64(sampleCount), denominator: 48_000))
        XCTAssertEqual(media.duration, preview.duration)
        XCTAssertTrue(media.frames.isEmpty)
        XCTAssertTrue(try XCTUnwrap(media.audio.first).packets.isEmpty)
        let one = RationalTime(numerator: 1, denominator: 48_000)
        XCTAssertEqual(media.audioEditBoundary(near: 0.6 * one.seconds), one)
        let half = RationalTime(numerator: 1, denominator: 96_000)
        XCTAssertEqual(media.audioEditBoundary(near: half.seconds), one)
        XCTAssertEqual(media.audioEditBoundary(near: half.seconds, rounding: .toNearestOrEven), .zero)
        XCTAssertEqual(media.audioEditBoundary(near: (one + half).seconds, rounding: .toNearestOrEven), one + one)
        XCTAssertEqual(media.steppingAudioBoundary(from: one.seconds, direction: 1), one + one)
        XCTAssertEqual(media.steppingAudioBoundary(from: media.duration.seconds, direction: -1), .init(numerator: 1))
    }
}
