import CryptoKit
import Foundation
@testable import MPCutCore
import XCTest

final class WishlistBenchmarkTests: XCTestCase {
    private func requireBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MPCUT_WISHLIST_BENCH"] == "1" else {
            throw XCTSkip("Set MPCUT_WISHLIST_BENCH=1 to measure.")
        }
    }

    private func time(_ numerator: Int, _ denominator: Int = 1) -> RationalTime {
        RationalTime(numerator: Int64(numerator), denominator: Int64(denominator))
    }

    private func range(_ from: Int, _ to: Int) -> MulticamRange {
        MulticamRange(from: time(from), to: time(to))
    }

    private func cpuMilliseconds() -> Double {
        var time = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
    }

    private func measureValue<Value: Encodable>(_ name: String, runs: Int = 15,
                                                 _ work: () throws -> Value) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let result = try work()
        let expected = try encoder.encode(result)
        var samples: [Double] = []
        samples.reserveCapacity(runs)
        for _ in 0..<runs {
            let start = cpuMilliseconds()
            let actual = try work()
            samples.append(cpuMilliseconds() - start)
            XCTAssertTrue(try encoder.encode(actual) == expected, "\(name) changed between runs")
        }
        let median = samples.sorted()[runs / 2]
        let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        print(String(format: "WISHLIST_BENCH %@ cpuMedianMs=%.3f sha256=%@", name, median, digest))
        return result
    }

    func testCameraLookup() throws {
        try requireBenchmark()
        for recordings in [64, 512] {
            let angles: [MulticamSource] = (0..<4).map { angle in
                let prefix = "cam\(angle)"
                let additional: [MulticamSource] = (1..<recordings).reversed().map { index in
                    let id = "\(prefix)-\(index)"
                    let start = index * 20
                    return MulticamSource(id: id, file: "\(id).mov", offset: time(start), audioStream: 0,
                                          coverage: range(start, start + 18))
                }
                return MulticamSource(id: prefix, file: "\(prefix).mov", audioStream: 0,
                                      coverage: range(0, 18), additionalRecordings: additional)
            }
            let project = MulticamProject(referenceAngle: "cam0", range: range(0, recordings * 20),
                                          angles: angles, audio: .follow, switches: [.init(at: .zero, angle: "cam0")])
            try project.validate()
            XCTAssertEqual(project.pictureSource(for: "cam0", at: time(0))?.additionalRecordings.count, 0)
            XCTAssertEqual(project.pictureSource(for: "cam0", at: time(18), exclusiveEnd: true)?.id, "cam0")
            XCTAssertNil(project.pictureSource(for: "cam0", at: time(18)))
            XCTAssertEqual(project.pictureSource(for: "cam0", at: time(20))?.id, "cam0-1")
            XCTAssertNil(project.pictureSource(for: "missing", at: time(20)))
            _ = try measureValue("picture-\(recordings)") { () -> [String?] in
                (0..<4_096).map { index in
                    project.pictureSource(for: "cam\(index % 4)", at: time((index * 53) % (recordings * 20)),
                                          exclusiveEnd: index.isMultiple(of: 3))?.id
                }
            }
        }
    }

    func testOccurrenceMapping() throws {
        try requireBenchmark()
        let clips = (0..<30_000).map { index in
            let start = (index % 2_000) * 12
            return CutSequenceClip(id: "clip\(index)", file: "file\(index % 8).mov", from: time(start), to: time(start + 10))
        }
        let project = CutProject.sequence(clips)
        let targeted = try measureValue("occurrence-targeted") { () throws -> [TimelineMapping] in
            try (0..<40).map { query in
                let index = (query * 1_481) % clips.count
                let clip = clips[index]
                return try project.mapTimelineRange(.init(from: clip.from, to: clip.to), clock: .source,
                                                    file: clip.file, occurrenceIndex: index)
            }
        }
        for (query, mapping) in targeted.enumerated() {
            XCTAssertEqual(mapping.pieces.map(\.index), [(query * 1_481) % clips.count])
        }
        let fileOnly = try measureValue("occurrence-file") { () throws -> [TimelineMapping] in
            try (0..<40).map { query in
                let start = query * 157
                return try project.mapTimelineRange(range(start, start + 33), clock: .source, file: "file\(query % 8).mov")
            }
        }
        XCTAssertEqual(fileOnly.flatMap(\.pieces).count, 255)
    }

    func testWaveformCorrelation() throws {
        try requireBenchmark()
        var random: UInt64 = 42
        let waveform: [Float] = (0..<AudioWaveform.rate * 420).map { _ in
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float((random >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        let contiguous = Array(waveform[373..<(waveform.count - 300)])
        var gapped = contiguous
        for index in stride(from: 29, to: gapped.count, by: 89) { gapped[index] = -1 }
        for (name, target) in [("dense", contiguous), ("gapped", gapped)] {
            let matches = try measureValue("sync-\(name)", runs: 21) { () throws -> [MulticamSync.Match] in
                try MulticamSync.match(waveform, target, referenceOffset: time(2),
                                       baselines: [time(-7), .zero, time(13), time(75)])
            }
            XCTAssertFalse(matches.isEmpty)
            XCTAssertTrue(matches.allSatisfy { $0.offset == time(473, 50) })
        }
    }
}
