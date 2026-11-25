import AVFoundation
import Foundation
import XCTest
@testable import MPCutCore

final class SidecarPackingTests: XCTestCase {
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 16
        }
        /// A uniform value in 0..<1.
        mutating func unit() -> Double { Double(next() & 0xFF_FFFF) / Double(1 << 24) }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    private struct Row {
        var flags: UInt8
        var time: RationalTime
        var decode: RationalTime?
        var duration: RationalTime
        var size: UInt64
    }

    /// The index writer's row: flags with the timestamp kind, the presentation time, a
    /// decode time only when it differs, the duration and the size.
    private func frameBytes(_ rows: [Row]) -> Data {
        var writer = PackedWriter()
        for row in rows {
            let kind: UInt8 = row.decode == nil ? 0 : row.decode == row.time ? 1 : 2
            writer.bytes.append(row.flags | kind)
            writer.time(row.time)
            if kind == 2, let decode = row.decode { writer.time(decode) }
            writer.time(row.duration)
            writer.unsigned(row.size)
        }
        return Data(writer.bytes)
    }

    private func regularRows(_ count: Int, rate: Int64 = 25, random: inout Random) -> [Row] {
        let duration = RationalTime(numerator: 1, denominator: rate)
        return (0..<count).map { index in
            let time = RationalTime(numerator: Int64(index), denominator: rate)
            let key = index.isMultiple(of: 50)
            // Key frames near 90 kB and the rest spread around 9 kB, as in a long-GOP recording.
            let scale = key ? 90_000.0 : 9_000.0
            let size = UInt64(scale * (0.4 + 1.2 * random.unit() * random.unit()))
            return Row(flags: key ? 28 : 24, time: time, decode: time, duration: duration, size: size)
        }
    }

    private func frameColumns(_ packed: Data) throws -> (rows: Int, kept: Int, leads: Int) {
        try packed.withUnsafeBytes { bytes in
            var reader = PackedReader(bytes)
            return (try reader.count(minimumBytes: 2), try reader.count(), try reader.count())
        }
    }

    private func stored(_ value: Data, key: String = "") throws -> SidecarPayload {
        let payload = try SidecarPayload.encode(value, key: key, cancelled: { false })
        XCTAssertEqual(try payload.decode(cancelled: { false }), value, key)
        if payload.logicalSize != 0 { XCTAssertLessThan(payload.bytes.count, value.count, key) }
        return payload
    }

    func testRegularFrameRowsKeepOnlyFlagsAndSizes() throws {
        // Written out by hand: four frames at 25 a second, the first a 300-byte key frame.
        let rows = Data([0x1D, 0x00, 0x01, 0x02, 0x19, 0xAC, 0x02,
                         0x19, 0x02, 0x19, 0x02, 0x19, 0x05,
                         0x19, 0x04, 0x19, 0x02, 0x19, 0x05,
                         0x19, 0x06, 0x19, 0x02, 0x19, 0x05])
        let packed = Data([4, 4, 0, 0xDD, 0x19, 0x19, 0x19, 0x00, 0x01, 0x02, 0x19, 0x2C, 5, 5, 5, 1, 0, 0, 0])
        XCTAssertEqual(try SidecarFramePacking.pack(rows, cancelled: { false }), packed)
        XCTAssertEqual(try SidecarPayload(bytes: Data([8]) + packed, logicalSize: rows.count).decode(cancelled: { false }), rows)

        // Three hours at 25 frames a second.
        var random = Random(state: 0x9E37_79B9_7F4A_7C15)
        let value = frameBytes(regularRows(270_000, random: &random))
        let whole = try XCTUnwrap(SidecarFramePacking.pack(value, cancelled: { false }))
        let columns = try frameColumns(whole)
        XCTAssertEqual(columns.rows, 270_000)
        // Only the first row keeps its time and duration.
        XCTAssertEqual(columns.kept, 4)
        XCTAssertEqual(columns.leads, 0)
        let payload = try stored(value, key: "media_index_frames.v1")
        let plain = try stored(value)
        XCTAssertEqual(payload.bytes.first, 9)
        XCTAssertEqual(plain.bytes.first, 1)
        // Every read of the index rebuilds its rows before the index decoder parses them.
        let started = Date()
        XCTAssertEqual(try SidecarFramePacking.unpack(whole, logicalSize: value.count, cancelled: { false }), value)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        print("Synthetic 3-hour frame index: logical=\(value.count) plain_lzfse=\(plain.bytes.count) "
            + "packed=\(payload.bytes.count) bytes; rebuilding the rows took \(milliseconds) ms in this build")
        XCTAssertLessThan(payload.bytes.count * 4, plain.bytes.count * 3)

        XCTAssertNil(try SidecarFramePacking.unpack(whole, logicalSize: value.count - 1, cancelled: { false }))
        XCTAssertNil(try SidecarFramePacking.unpack(whole.dropLast(), logicalSize: value.count, cancelled: { false }))
        XCTAssertNil(try SidecarFramePacking.unpack(whole + Data([0]), logicalSize: value.count, cancelled: { false }))
        XCTAssertThrowsError(try SidecarFramePacking.pack(value, cancelled: { true })) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
    }

    func testFrameRowsWrittenByTheIndexPack() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures")
        // Recordings at a constant rate, some with reordered frames, keep the first row's
        // time and duration (four bytes) and one byte for each reordered frame. The last two
        // change their frame rate part of the way through.
        for (name, constant) in [("Pause-Quiet.mov", true), ("Playback-120.mp4", true), ("WebM-Opus-GOP.webm", true),
                                 ("Leading-Picture-Gap.avi", true), ("SmartTrim-GOP.mp4", true), ("HEVC-Open-GOP.mp4", true),
                                 ("Damage-H264.mp4", true), ("VFR-PTS.mp4", false), ("Scene-Cadence-Change.mov", false)] {
            let media = try CutEngine(useSidecar: false).inspect(fixtures.appendingPathComponent(name), keyframes: true)
            let rows = try XCTUnwrap(AnalysisSidecar.indexSections(for: media)["media_index_frames.v1"], name)
            let reordered = media.frames.filter { $0.dts != nil && $0.dts != $0.time }.count
            let packed = try XCTUnwrap(SidecarFramePacking.pack(rows, cancelled: { false }), name)
            XCTAssertEqual(try SidecarFramePacking.unpack(packed, logicalSize: rows.count, cancelled: { false }), rows, name)
            let columns = try frameColumns(packed)
            XCTAssertEqual(columns.rows, media.frames.count, name)
            if constant {
                XCTAssertEqual(columns.kept, 4, name)
                XCTAssertEqual(columns.leads, reordered, name)
            } else {
                XCTAssertGreaterThan(columns.kept, 4, name)
                XCTAssertLessThan(columns.kept, rows.count / 3, name)
            }
            print("Frame index of \(name): frames=\(media.frames.count) reordered=\(reordered) logical=\(rows.count) "
                + "packed=\(packed.count) kept=\(columns.kept) leads=\(columns.leads) bytes")
        }
    }

    func testFrameRowsThatBreakThePatternKeepTheirOwnBytes() throws {
        var random = Random(state: 7)
        var rows = regularRows(6000, rate: 30, random: &random)
        let frame = RationalTime(numerator: 1, denominator: 30)
        for index in rows.indices {
            // Reordered frames: every third is decoded three frames early, the first one frame early.
            if index.isMultiple(of: 3) {
                rows[index].decode = try rows[index].time.subtracting(RationalTime(numerator: index == 0 ? 1 : 3, denominator: 30))
            }
            // A timeline that restarts, and a stretch at another frame rate.
            if index >= 2000 { rows[index].time = try rows[index].time.adding(RationalTime(numerator: 7, denominator: 3)) }
            if (3000..<3500).contains(index) {
                rows[index].duration = RationalTime(numerator: 1001, denominator: Int64(24_000 + index % 7 * 1000))
            }
            if index >= 2000, index.isMultiple(of: 3) { rows[index].decode = try rows[index].time.subtracting(frame) }
        }
        // A decode time off the frame grid, a missing one, a negative start and times too large to add.
        rows[10].decode = try rows[10].time.subtracting(RationalTime(numerator: 1, denominator: 7))
        rows[11].decode = nil
        rows[0].time = RationalTime(numerator: -1, denominator: 30)
        rows[5000].time = RationalTime(numerator: .max - 1)
        rows[5001].time = RationalTime(numerator: .min)
        rows[5002].duration = .zero
        rows[5003].duration = RationalTime(numerator: -1, denominator: 30)
        rows[5004].size = .max
        var value = frameBytes(rows)
        // A time that is not in lowest terms, which the writer never produces: 6/30 for 1/5.
        value.append(contentsOf: [0x18, 0x0C, 0x1E, 0x02, 0x1E, 0x05])
        value.append(frameBytes(regularRows(100, rate: 30, random: &random)))

        let packed = try XCTUnwrap(SidecarFramePacking.pack(value, cancelled: { false }))
        XCTAssertEqual(try SidecarFramePacking.unpack(packed, logicalSize: value.count, cancelled: { false }), value)
        let columns = try frameColumns(packed)
        XCTAssertEqual(columns.rows, rows.count + 101)
        XCTAssertGreaterThan(columns.kept, 500 * 3)
        XCTAssertGreaterThan(columns.leads, 1500)
        let payload = try stored(value, key: "media_index_frames.v1")
        XCTAssertTrue([8, 9].contains(try XCTUnwrap(payload.bytes.first)))
        XCTAssertLessThanOrEqual(payload.bytes.count, try stored(value).bytes.count)

        // Every row off the pattern: nothing is predicted, and plain compression may win.
        var scattered = regularRows(3000, random: &random)
        for index in scattered.indices {
            scattered[index].time = RationalTime(numerator: Int64(index) * 1_000_003 + Int64(random.below(997)), denominator: 90_000)
            scattered[index].duration = RationalTime(numerator: Int64(1 + random.below(9000)), denominator: 90_000)
            scattered[index].decode = RationalTime(numerator: Int64(index) * 1_000_003 - Int64(random.below(99_991)), denominator: 90_000)
        }
        let irregular = frameBytes(scattered)
        XCTAssertLessThanOrEqual(try stored(irregular, key: "media_index_frames.v1").bytes.count, try stored(irregular).bytes.count)
    }

    func testFrameRowsOutsideTheLayoutKeepPlainCompression() throws {
        var random = Random(state: 11)
        let regular = frameBytes(regularRows(2000, random: &random))
        // One more frame, 1/25 s long at 1/25 s, written in ways the index never is.
        func extended(_ row: [UInt8]) -> Data { regular + Data(row) }
        let wide = [UInt8](repeating: 0xFF, count: 10)
        var cases: [(String, Data)] = []
        cases.append(("reserved flag", extended([0x39, 0x02, 0x19, 0x02, 0x19, 0x05])))
        cases.append(("unknown timestamp kind", extended([0x1B, 0x02, 0x19, 0x02, 0x19, 0x05])))
        cases.append(("zero denominator", extended([0x19, 0x02, 0x00, 0x02, 0x19, 0x05])))
        cases.append(("truncated row", extended([0x19, 0x02, 0x19, 0x02, 0x19])))
        cases.append(("truncated integer", extended([0x19, 0x02, 0x19, 0x02, 0x19, 0x80])))
        cases.append(("integer past 64 bits", extended([0x19, 0x02, 0x19, 0x02, 0x19] + wide + [0])))
        // The same size written with a spare continuation byte.
        cases.append(("padded size", extended([0x19, 0x02, 0x19, 0x02, 0x19, 0x85, 0x00])))
        cases.append(("padded time", extended([0x19, 0x82, 0x00, 0x19, 0x02, 0x19, 0x05])))
        cases.append(("text", Data(String(repeating: "not an index ", count: 400).utf8)))
        cases.append(("empty", Data()))
        for (name, value) in cases {
            if name != "padded time" {
                XCTAssertNil(try SidecarFramePacking.pack(value, cancelled: { false }), name)
            }
            let payload = try stored(value, key: "media_index_frames.v1")
            if name == "empty" {
                XCTAssertEqual(payload.logicalSize, 0)
            } else if name != "padded time" {
                XCTAssertEqual(payload.bytes.first, 1, name)
            }
        }
        // A padded time is kept as its own bytes, so that row still packs.
        let padded = cases[7].1
        let packed = try XCTUnwrap(SidecarFramePacking.pack(padded, cancelled: { false }))
        XCTAssertEqual(try SidecarFramePacking.unpack(packed, logicalSize: padded.count, cancelled: { false }), padded)

        // Damaged stored bytes are a miss, never a trap.
        let whole = try XCTUnwrap(SidecarFramePacking.pack(regular, cancelled: { false }))
        for offset in stride(from: 0, to: whole.count, by: 37) {
            for byte in [UInt8(0x00), 0x7F, 0xFF] where whole[offset] != byte {
                var damaged = whole
                damaged[offset] = byte
                if let result = try SidecarFramePacking.unpack(damaged, logicalSize: regular.count, cancelled: { false }) {
                    XCTAssertEqual(result.count, regular.count)
                }
            }
        }
        for garbage in [Data([0]), Data([1, 0, 0, 0xFF, 0]), Data([1, 2, 0, 0xC0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0x00, 0, 0])] {
            XCTAssertNil(try SidecarFramePacking.unpack(garbage, logicalSize: 64, cancelled: { false }))
            XCTAssertNil(try SidecarPayload(bytes: Data([8]) + garbage, logicalSize: 64).decode(cancelled: { false }))
        }
    }

    private func sampleBytes(_ samples: [Float]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    /// The layout of a saved audio analysis: its presentation clock beside its value.
    private func audioSection(_ value: Any) throws -> Data {
        let clock: [String: Any] = ["stream": 1, "duration": ["numerator": 10_800, "denominator": 1],
                                    "origin": ["numerator": 0, "denominator": 1], "indexed": true,
                                    "uses_presentation_edits": false]
        return try PropertyListSerialization.data(fromPropertyList: ["clock": clock, "value": value], format: .binary, options: 0)
    }

    /// Speech-like 20 ms peaks: a level that drifts in decibels with jitter on every bin,
    /// stretches of digital silence, and unobserved bins at the end.
    private func peaks(_ count: Int, random: inout Random) -> [Float] {
        var level = -30.0
        return (0..<count).map { index in
            if index >= count - 40 { return -1 }
            if (index / 3000) % 9 == 4 { return 0 }
            level = min(-3, max(-70, level + (random.unit() - 0.5) * 4))
            return Float(pow(10, (level + (random.unit() - 0.5) * 12) / 20))
        }
    }

    func testSamplePlanesPackSmallerThanPlainCompression() throws {
        var random = Random(state: 3)
        // Three hours of 20 ms peaks.
        let value = try audioSection(sampleBytes(peaks(540_000, random: &random)))
        let payload = try stored(value, key: "waveform_peaks.v1.1")
        let plain = try stored(value)
        XCTAssertEqual(payload.bytes.first, 11)
        XCTAssertEqual(plain.bytes.first, 1)
        print("Synthetic 3-hour waveform peaks: logical=\(value.count) plain_lzfse=\(plain.bytes.count) "
            + "transposed=\(payload.bytes.count) bytes")
        XCTAssertLessThan(payload.bytes.count * 20, plain.bytes.count * 19)

        // An overview has two sample runs, the minima and the maxima.
        let high = peaks(65_536, random: &random)
        let overview = try audioSection(["low": sampleBytes(high.map { -$0 * 0.9 }), "high": sampleBytes(high)])
        let envelope = try stored(overview, key: "waveform_envelope.v1.1")
        let plainEnvelope = try stored(overview)
        XCTAssertEqual(envelope.bytes.first, 11)
        print("Synthetic waveform overview: logical=\(overview.count) plain_lzfse=\(plainEnvelope.bytes.count) "
            + "transposed=\(envelope.bytes.count) bytes")
        XCTAssertLessThan(envelope.bytes.count, plainEnvelope.bytes.count)

        let packed = try XCTUnwrap(SidecarSamplePacking.pack(overview, cancelled: { false }))
        XCTAssertEqual(packed.first, 2)
        XCTAssertEqual(try SidecarSamplePacking.unpack(packed, logicalSize: overview.count, cancelled: { false }), overview)
        XCTAssertNil(try SidecarSamplePacking.unpack(packed, logicalSize: overview.count - 1, cancelled: { false }))
        XCTAssertNil(try SidecarSamplePacking.unpack(packed.dropLast(), logicalSize: overview.count, cancelled: { false }))
        XCTAssertNil(try SidecarSamplePacking.unpack(packed + Data([0]), logicalSize: overview.count, cancelled: { false }))
        // Transposing alone is never stored: it is longer than the section.
        XCTAssertNil(try SidecarPayload(bytes: Data([10]) + packed, logicalSize: overview.count).decode(cancelled: { false }))
    }

    func testSampleRunsOfAnyLengthAndContentRoundTrip() throws {
        var random = Random(state: 5)
        let samples = sampleBytes(peaks(20_000, random: &random))
        // A run that ends inside a sample, runs too short to move, and lengths that the
        // property list states in two and in four bytes.
        for length in [1023, 1024, 1025, 1026, 1027, 4096, 19_999, 20_000, 70_001] {
            let small = Data((0..<200).map { UInt8(truncatingIfNeeded: $0) })
            for value in [try audioSection(samples.prefix(length)),
                          try audioSection(["low": samples.prefix(length), "high": samples.suffix(length), "note": small])] {
                let packed = try SidecarSamplePacking.pack(value, cancelled: { false })
                XCTAssertEqual(packed == nil, length < 1024, "\(length)")
                if let packed {
                    XCTAssertEqual(packed.first, value.count > length * 2 ? 2 : 1)
                    XCTAssertEqual(try SidecarSamplePacking.unpack(packed, logicalSize: value.count, cancelled: { false }), value)
                }
                _ = try stored(value, key: "waveform_peaks.v1.0")
                _ = try stored(value, key: "waveform_envelope.v1.0")
            }
        }

        // Bytes that are not samples compress better as they are, and stay that way.
        let words = ["peaks", "that", "are", "prose", "repeat", "whole", "words", "at", "any", "offset", "in", "a", "sample"]
        let text = try audioSection(Data((0..<16_000).map { _ in words[random.below(words.count)] }.joined(separator: " ").utf8))
        XCTAssertNotNil(try SidecarSamplePacking.pack(text, cancelled: { false }))
        let prose = try stored(text, key: "waveform_peaks.v1.0")
        XCTAssertEqual(prose.bytes.first, 1)
        XCTAssertEqual(prose.bytes, try stored(text).bytes)
        // Noise does not compress either way and is stored verbatim.
        let noise = try audioSection(Data((0..<40_000).map { _ in UInt8(truncatingIfNeeded: random.next()) }))
        XCTAssertEqual(try stored(noise, key: "waveform_peaks.v1.0").logicalSize, 0)
    }

    func testSectionsWithoutSampleRunsKeepPlainCompression() throws {
        var random = Random(state: 9)
        let samples = sampleBytes(peaks(20_000, random: &random))
        let section = try audioSection(samples)
        var cases: [(String, Data)] = [
            ("bare samples", samples),
            ("XML", try PropertyListSerialization.data(fromPropertyList: ["value": samples], format: .xml, options: 0)),
            ("short data", try audioSection(["names": (0..<600).map { "name \($0)" }, "value": samples.prefix(1000)])),
            ("no data", try audioSection((0..<2000).map { Double($0) })),
            ("truncated", section.dropLast(5)),
            ("empty", Data()),
        ]
        // A trailer that points its offset table, or one object, outside the file.
        for (name, offset, byte) in [("table past end", section.count - 2, UInt8(0xFF)), ("no objects", section.count - 17, 0),
                                     ("wide offsets", section.count - 26, 9), ("zero offsets", section.count - 26, 0)] {
            var damaged = section
            damaged[offset] = byte
            cases.append((name, damaged))
        }
        for (name, value) in cases {
            XCTAssertNil(try SidecarSamplePacking.pack(value, cancelled: { false }), name)
            let payload = try stored(value, key: "waveform_peaks.v1.0")
            if name != "empty" { XCTAssertEqual(payload.bytes.first, 1, name) }
        }
        // Any other damage to the framing only changes which bytes are moved.
        let brief = try audioSection(samples.prefix(8000))
        for offset in Array(0..<64) + Array(brief.count - 400..<brief.count) {
            var damaged = brief
            damaged[offset] ^= 0x5A
            _ = try stored(damaged, key: "waveform_peaks.v1.0")
        }

        // Stored region lists that reach outside the section are a miss.
        let body = Data(repeating: 7, count: 64)
        for header in [[0], [17], [1, 0, 0], [1, 0, 17], [1, 61, 1], [1, 65, 0], [2, 0, 8, 0, 9], [1, 0x80]] as [[UInt8]] {
            XCTAssertNil(try SidecarSamplePacking.unpack(Data(header) + body, logicalSize: 64, cancelled: { false }), "\(header)")
        }
        XCTAssertEqual(try SidecarSamplePacking.unpack(Data([2, 0, 8, 0, 8]) + body, logicalSize: 64, cancelled: { false }), body)
    }

    private func silenceRuns(seconds: Int, duration: RationalTime, random: inout Random) -> SilenceRuns {
        let rate = Int64(AudioWaveform.rate)
        let bins = Int64(seconds) * rate
        var quiet: [AudioSpan] = []
        var bin: Int64 = 0
        while bin < bins {
            // Words of 0.1 to 3 seconds between gaps of 0.04 to 2.5 seconds.
            bin += Int64(5 + random.below(145))
            let end = bin + Int64(2 + Int(Double(123) * random.unit() * random.unit()))
            guard bin < bins else { break }
            quiet.append(AudioSpan(from: RationalTime(numerator: bin, denominator: rate),
                                   to: min(duration, RationalTime(numerator: end, denominator: rate))))
            bin = end
        }
        // The recording ends in silence, and has one dropout in the middle.
        if let last = quiet.popLast() { quiet.append(AudioSpan(from: last.from, to: duration)) }
        let half = RationalTime(numerator: bins / 2, denominator: rate)
        let covered = [AudioSpan(from: .zero, to: half),
                       AudioSpan(from: try! half.adding(RationalTime(numerator: 1, denominator: rate)), to: duration)]
        return SilenceRuns(quiet: quiet, covered: covered)
    }

    private struct EarlierSilence: Encodable {
        struct Value: Encodable {
            private enum CodingKeys: String, CodingKey {
                case stream = "audio_stream_index"
                case minimum = "silence_min_pause_seconds"
                case automaticThresholdDB = "silence_automatic_threshold_db"
                case pauses, runs, spans
            }
            let stream = 1
            let minimum: Double
            let automaticThresholdDB = -42.0
            var pauses: [AudioSpan]?
            var runs: SilenceRuns?
            var spans: Data?
        }
        struct Clock: Encodable {
            private enum CodingKeys: String, CodingKey {
                case stream, duration, origin, indexed
                case usesPresentationEdits = "uses_presentation_edits"
            }
            let stream = 1
            let duration: RationalTime
            let origin = RationalTime.zero
            let indexed = true
            let usesPresentationEdits = false
        }
        let clock: Clock
        let value: Value
    }

    func testSilenceSpansPackAsGridDistances() throws {
        // Three hours that end between two bins, as a 48 kHz track does.
        var random = Random(state: 13)
        let duration = RationalTime(numerator: 10_800 * 48_000 + 517, denominator: 48_000)
        let runs = silenceRuns(seconds: 10_800, duration: duration, random: &random)
        XCTAssertEqual(runs.quiet.last?.to, duration)
        let pauses = runs.pauses(minimum: 1.5)
        XCTAssertGreaterThan(pauses.count, 100)
        let packed = try XCTUnwrap(SidecarSilencePacking.pack(pauses: pauses, runs: runs, minimum: 1.5, cancelled: { false }))
        let restored = try XCTUnwrap(SidecarSilencePacking.unpack(packed, minimum: 1.5, cancelled: { false }))
        XCTAssertEqual(restored.pauses, pauses)
        XCTAssertEqual(restored.runs.quiet, runs.quiet)
        XCTAssertEqual(restored.runs.covered, runs.covered)
        // The layout, no listed pauses, 50 bins a second, then the quiet runs.
        XCTAssertEqual(Array(packed.prefix(3)), [1, 0, UInt8(AudioWaveform.rate)])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let clock = EarlierSilence.Clock(duration: duration)
        let earlier = try encoder.encode(EarlierSilence(clock: clock, value: .init(minimum: 1.5, pauses: pauses, runs: runs)))
        let section = try encoder.encode(EarlierSilence(clock: clock, value: .init(minimum: 1.5, spans: packed)))
        let plain = try stored(earlier)
        let compact = try stored(section)
        let spans = runs.quiet.count + runs.covered.count + pauses.count
        print("Synthetic 3-hour silence result (\(spans) spans): logical=\(earlier.count) plain_lzfse=\(plain.bytes.count) "
            + "packed_logical=\(section.count) packed_stored=\(compact.bytes.count) bytes")
        XCTAssertLessThan(compact.bytes.count * 3, plain.bytes.count)
        XCTAssertLessThan(section.count * 15, earlier.count)

        XCTAssertNil(try SidecarSilencePacking.unpack(packed.dropLast(), minimum: 1.5, cancelled: { false }))
        XCTAssertNil(try SidecarSilencePacking.unpack(packed + Data([0]), minimum: 1.5, cancelled: { false }))
        XCTAssertNil(try SidecarSilencePacking.unpack(Data([2]) + packed.dropFirst(), minimum: 1.5, cancelled: { false }))
        XCTAssertNil(try SidecarSilencePacking.unpack(Data([1, 2]) + packed.dropFirst(2), minimum: 1.5, cancelled: { false }))
        XCTAssertNil(try SidecarSilencePacking.unpack(Data([1, 0, 0, 0, 0]), minimum: 1.5, cancelled: { false }))
        XCTAssertNil(try SidecarSilencePacking.unpack(Data([1, 0, 50, 1, 1, 2, 0, 0, 0]), minimum: 1.5, cancelled: { false }))
        XCTAssertNil(try SidecarSilencePacking.unpack(Data(), minimum: 1.5, cancelled: { false }))
        XCTAssertThrowsError(try SidecarSilencePacking.pack(pauses: pauses, runs: runs, minimum: 1.5, cancelled: { true })) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
    }

    func testSilenceSpansOffTheGridKeepTheirExactTimes() throws {
        func time(_ numerator: Int64, _ denominator: Int64) -> RationalTime {
            RationalTime(numerator: numerator, denominator: denominator)
        }
        func span(_ from: RationalTime, _ to: RationalTime) -> AudioSpan { AudioSpan(from: from, to: to) }
        // Endpoints between bins in the middle of a list, on a finer clock, and too large for a bin index.
        let quiet = [span(.zero, time(1, 3)), span(time(1, 2), time(7, 10)), span(time(33, 48_000), time(4, 5)),
                     span(time(1, 1), time(101, 100)), span(time(51, 50), time(.max, 3)), span(time(.max, 2), time(.max, 1))]
        let covered = [span(time(1, 7), time(.max - 1, 1))]
        let runs = SilenceRuns(quiet: quiet, covered: covered)
        // Pauses that the runs would not give, and none where the runs give some.
        for pauses in [runs.pauses(minimum: 0.1), [span(time(1, 50), time(1, 9))], [], quiet] {
            let packed = try XCTUnwrap(SidecarSilencePacking.pack(pauses: pauses, runs: runs, minimum: 0.1, cancelled: { false }))
            XCTAssertEqual(packed[1], pauses == runs.pauses(minimum: 0.1) ? 0 : 1)
            let restored = try XCTUnwrap(SidecarSilencePacking.unpack(packed, minimum: 0.1, cancelled: { false }))
            XCTAssertEqual(restored.pauses, pauses)
            XCTAssertEqual(restored.runs.quiet, quiet)
            XCTAssertEqual(restored.runs.covered, covered)
        }
        let empty = SilenceRuns(quiet: [], covered: [])
        let packed = try XCTUnwrap(SidecarSilencePacking.pack(pauses: [], runs: empty, minimum: 1, cancelled: { false }))
        XCTAssertEqual(packed, Data([1, 0, UInt8(AudioWaveform.rate), 0, 0]))
        XCTAssertEqual(try SidecarSilencePacking.unpack(packed, minimum: 1, cancelled: { false })?.pauses, [])

        // Lists out of order, or before the start, are left to the property list layout.
        for unordered in [[span(time(2, 1), time(3, 1)), span(time(1, 1), time(3, 2))], [span(time(2, 1), time(1, 1))],
                          [span(time(-1, 50), time(1, 1))]] {
            XCTAssertNil(try SidecarSilencePacking.pack(pauses: [], runs: SilenceRuns(quiet: unordered, covered: []),
                                                       minimum: 1, cancelled: { false }))
            XCTAssertNil(try SidecarSilencePacking.pack(pauses: unordered, runs: empty, minimum: 1, cancelled: { false }))
        }
    }

    func testSavedSilenceUsesPackedSectionsAndStillReadsEarlierOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("home")) {
            // Tone and silence in alternation, ending between two 20 ms bins.
            let frames = 16_000 * 6 + 123
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<frames {
                samples[index] = index < 96_000 && (index / 8000).isMultiple(of: 2) ? Float(sin(Double(index) * 0.1)) * 0.5 : 0
            }
            var sources: [URL] = []
            for name in ["packed", "earlier"] {
                let folder = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let source = folder.appendingPathComponent("take.wav")
                do {
                    let file = try AVAudioFile(forWriting: source, settings: format.settings)
                    try file.write(from: buffer)
                }
                sources.append(source)
            }
            let engine = CutEngine(useSidecar: false)
            let media = try engine.inspect(sources[0], keyframes: true)
            let stream = try XCTUnwrap(media.audio.first?.stream.index)
            let wave = try AudioAnalysis.scan(media, stream: stream, useSidecar: false)
            let result = try AudioAnalysis.silence(media, stream: stream, minimum: 0.2, waveform: wave, useSidecar: false)
            XCTAssertGreaterThan(result.pauses.count, 3)
            XCTAssertEqual(result.pauses.last?.to, media.duration)
            XCTAssertFalse(Int64(AudioWaveform.rate).isMultiple(of: media.duration.denominator))

            let sections = try AnalysisSidecar.sections(media: media, silence: [result])
            let keys = sections.keys.filter { $0.hasPrefix("silence_pauses.") }
            XCTAssertEqual(keys.count, 1)
            let key = try XCTUnwrap(keys.first)
            XCTAssertTrue(key.hasPrefix("silence_pauses.v2.\(stream).auto."), key)
            let settings = try XCTUnwrap(AnalysisSidecar.savedSilenceSettings(forKey: key))
            XCTAssertEqual(settings.stream, stream)
            XCTAssertNil(settings.thresholdDB)
            XCTAssertEqual(settings.minimum, 0.2)
            let earlierKey = key.replacingOccurrences(of: "silence_pauses.v2.", with: "silence_pauses.v1.")
            XCTAssertEqual(AnalysisSidecar.savedSilenceSettings(forKey: earlierKey)?.minimum, 0.2)
            XCTAssertNil(AnalysisSidecar.savedSilenceSettings(forKey: key.replacingOccurrences(of: ".v2.", with: ".v3.")))
            XCTAssertNil(AnalysisSidecar.savedSilenceSettings(forKey: key + "0"))

            // The settings stay inspectable beside the packed spans.
            let section = try XCTUnwrap(sections[key])
            let record = try XCTUnwrap(PropertyListSerialization.propertyList(from: section, format: nil) as? [String: Any])
            let value = try XCTUnwrap(record["value"] as? [String: Any])
            XCTAssertEqual(value["silence_min_pause_seconds"] as? Double, 0.2)
            XCTAssertEqual(value["audio_stream_index"] as? Int, stream)
            XCTAssertNotNil(value["spans"] as? Data)
            XCTAssertNil(value["pauses"])
            XCTAssertNil(value["runs"])

            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let expected = try encoder.encode(result)
            let store = AnalysisSidecar(media: media)
            try store.save(sections)
            let restored = try XCTUnwrap(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.2))
            XCTAssertEqual(try encoder.encode(restored), expected)
            XCTAssertEqual(restored.pauses(maxBlip: 0.5), result.pauses(maxBlip: 0.5))
            XCTAssertNil(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.3))
            XCTAssertNil(store.silence(for: media, stream: stream, thresholdDB: -40, minimum: 0.2))
            XCTAssertTrue(try AnalysisSidecar.sections(media: media, silence: [restored]).keys.contains(key))

            // Packed spans that no longer decode are a miss.
            var damaged = record
            var damagedValue = value
            damagedValue["spans"] = Data([9])
            damaged["value"] = damagedValue
            try store.save([key: PropertyListSerialization.data(fromPropertyList: damaged, format: .binary, options: 0)])
            XCTAssertNil(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.2))

            // A section written by an earlier build: the whole result as a property list.
            let other = try engine.inspect(sources[1], keyframes: true)
            var earlier = record
            earlier["value"] = try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(result), format: nil)
            let earlierStore = AnalysisSidecar(media: other)
            try earlierStore.save([earlierKey: PropertyListSerialization.data(fromPropertyList: earlier, format: .binary, options: 0)])
            XCTAssertEqual(earlierStore.keys().filter { $0.hasPrefix("silence_pauses.") }, [earlierKey])
            let fromEarlier = try XCTUnwrap(earlierStore.silence(for: other, stream: stream, thresholdDB: nil, minimum: 0.2))
            XCTAssertEqual(try encoder.encode(fromEarlier), expected)
            // With both saved, the damaged packed section falls back to the earlier one.
            try store.save([earlierKey: PropertyListSerialization.data(fromPropertyList: earlier, format: .binary, options: 0)])
            XCTAssertEqual(try encoder.encode(try XCTUnwrap(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.2))),
                           expected)
        }
    }

    func testCutcachePayloadTagsDecodeToTheirSections() throws {
        var random = Random(state: 17)
        let levels = (0..<2000).map { Float(($0 * 37) % 1009) / 1009 }
        let own = try transcriptActivityDocument(levels: levels, duration: 2000 * 320, evidence: "stream")
        var packets = PackedWriter()
        for index in 0..<2000 {
            packets.bytes.append(1)
            packets.time(RationalTime(numerator: Int64(index) * 1024, denominator: 48_000))
            packets.time(RationalTime(numerator: 1024, denominator: 48_000))
            for _ in 0..<3 { packets.signed(0) }
        }
        let frames = frameBytes(regularRows(2000, random: &random))
        let peaks = try audioSection(sampleBytes(self.peaks(4000, random: &random)))
        let sections: [(key: String, value: Data, tags: [UInt8])] = [
            ("custom", Data(repeating: 42, count: 5000), [1]),
            ("transcript_activity.v1.0.own", own, [2, 3]),
            ("media_index_audio.v1", Data(packets.bytes), [4, 5]),
            ("media_index_frames.v1", frames, [8, 9]),
            ("waveform_peaks.v1.0", peaks, [11]),
            ("waveform_envelope.v1.0", peaks, [11]),
        ]
        for section in sections {
            let payload = try stored(section.value, key: section.key)
            XCTAssertTrue(section.tags.contains(try XCTUnwrap(payload.bytes.first)), section.key)
            XCTAssertEqual(payload.logicalSize, section.value.count)
            // The same bytes under a key without a packer use plain compression.
            XCTAssertEqual(try stored(section.value).bytes.first, 1, section.key)
            // A tag this build does not know is a miss.
            XCTAssertNil(try SidecarPayload(bytes: Data([12]) + payload.bytes.dropFirst(), logicalSize: section.value.count)
                .decode(cancelled: { false }))
        }
        let short = Data(repeating: 1, count: 100)
        XCTAssertEqual(try stored(short, key: "media_index_frames.v1").bytes, short)
        XCTAssertEqual(try SidecarPayload(bytes: short, logicalSize: 0).decode(cancelled: { false }), short)
    }
}
