import Foundation
import XCTest
@testable import MPCutCore

final class SidecarCodecTests: XCTestCase {
    func testLZFSEStreamMustExactlyFillStoredBlob() throws {
        for size in [65535, 65536, 65537, 2 * 65536] {
            let value = Data(repeating: 42, count: size)
            let stored = try SidecarPayload.encode(value, cancelled: { false })
            XCTAssertEqual(stored.bytes.first, 1)
            XCTAssertEqual(try stored.decode(cancelled: { false }), value)
            for bytes in [stored.bytes.dropLast(), stored.bytes + Data([0]), stored.bytes + stored.bytes.dropFirst()] {
                XCTAssertNil(try SidecarPayload(bytes: bytes, logicalSize: size).decode(cancelled: { false }))
            }
        }
    }

    func testLongActivityLevelChecksCancellationWithinOneWindow() throws {
        let digits = String(repeating: "7", count: 200_000)
        let value = Data(#"{"activity":[{"end_sample":320,"level":0.\#(digits),"start_sample":0}]}"#.utf8)
        let packed = try XCTUnwrap(SidecarActivityPacking.pack(value, cancelled: { false }))
        var checks = 0
        func cancel() -> Bool {
            checks += 1
            return checks >= 2
        }
        XCTAssertThrowsError(try SidecarActivityPacking.pack(value, cancelled: cancel)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
        checks = 0
        XCTAssertThrowsError(try SidecarActivityPacking.unpack(packed, logicalSize: value.count, cancelled: cancel)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
    }

    /// serde_json writes the shortest digits that read back as the same value, keeps a
    /// fraction on an integer, and leaves an exponent unpadded below 0.00001.
    private func providerSpelling(_ level: Float) -> String {
        let text = level.description
        guard let split = text.firstIndex(where: { $0 == "e" }), let exponent = Int(text[text.index(after: split)...]) else {
            return text
        }
        let mantissa = String(text[..<split])
        if exponent == -5 { return "0.0000" + mantissa.filter { $0 != "." } }
        return (mantissa.hasSuffix(".0") ? String(mantissa.dropLast(2)) : mantissa) + "e\(exponent)"
    }

    private func providerLevels(_ levels: [String], duration: Int, evidence: String = #""stream""#) -> Data {
        var text = #"{"version":1,"sample_rate":16000,"stream_evidence":\#(evidence),"duration_samples":\#(duration),"activity":["#
        for (index, level) in levels.enumerated() {
            let start = index * 320
            if index > 0 { text += "," }
            text += #"{"start_sample":\#(start),"end_sample":\#(min(duration, start + 320)),"level":\#(level)}"#
        }
        return Data((text + "]}").utf8)
    }

    func testProviderLayoutLevelsUnpackToTheirExactBytes() throws {
        XCTAssertEqual([0, 1, 0.000056271634, 0.00001, 0.0000001, 0.25].map(providerSpelling),
                       ["0.0", "1.0", "0.000056271634", "0.00001", "1e-7", "0.25"])
        let spellings = ["0.0", "1.0", "0.000056271634", "1e-7", "9.536743e-7", "0.25", "0", "-0.0", "1E+0"]
        let quoted = #""take \"activity\":[{\"start_sample\":0 é\\""#
        let nested = #"{"activity":[1],"sample_digest":"fixture"}"#
        let framed = #"{"activity":[{"start_sample":0,"end_sample":320,"level":0.5}]}"#
        for evidence in [#""stream""#, "null", quoted, nested, framed] {
            for duration in [spellings.count * 320, spellings.count * 320 - 319, spellings.count * 320 - 1] {
                let value = providerLevels(spellings, duration: duration, evidence: evidence)
                let packed = try XCTUnwrap(SidecarActivityPacking.packProviderLayout(value, cancelled: { false }), evidence)
                XCTAssertLessThan(packed.count, value.count)
                XCTAssertEqual(try SidecarActivityPacking.unpackProviderLayout(packed, logicalSize: value.count,
                                                                             cancelled: { false }), value, evidence)
                XCTAssertNil(try SidecarActivityPacking.unpackProviderLayout(packed, logicalSize: value.count - 1,
                                                                           cancelled: { false }))
                XCTAssertNil(try SidecarActivityPacking.unpackProviderLayout(packed.dropLast(), logicalSize: value.count,
                                                                           cancelled: { false }))
            }
        }

        // Packing never writes a header longer than unpacking accepts.
        let opening = Data(#""activity":["#.utf8)
        let shortest = try XCTUnwrap(providerLevels(["0.5"], duration: 320, evidence: #""""#).range(of: opening)).lowerBound
        for (header, packs) in [(65535, true), (65536, false)] {
            let evidence = "\"" + String(repeating: "e", count: header - opening.count - shortest) + "\""
            let value = providerLevels(["0.5"], duration: 320, evidence: evidence)
            XCTAssertEqual(value.range(of: opening)?.upperBound, header)
            let packed = try SidecarActivityPacking.packProviderLayout(value, cancelled: { false })
            XCTAssertEqual(packed != nil, packs)
            if let packed {
                XCTAssertEqual(try SidecarActivityPacking.unpackProviderLayout(packed, logicalSize: value.count,
                                                                             cancelled: { false }), value)
            }
        }

        // The stored form is the final sample, the header's length, the header, two symbols
        // to a byte with a terminator after each level, and the bytes that close the array.
        let header = #"{"version":1,"sample_rate":16000,"stream_evidence":"e","duration_samples":400,"activity":["#
        let value = Data((header + #"{"start_sample":0,"end_sample":320,"level":0.5},"#
            + #"{"start_sample":320,"end_sample":400,"level":1.0}]}"#).utf8)
        var stored = Data([144, 1, 0, 0, 0, 0, 0, 0, UInt8(header.utf8.count), 0, 0, 0]) + Data(header.utf8)
        stored += Data([0x0A, 0x5F, 0x1A, 0x0F]) + Data("]}".utf8)
        XCTAssertEqual(try SidecarActivityPacking.packProviderLayout(value, cancelled: { false }), stored)
        XCTAssertEqual(try SidecarPayload(bytes: Data([6]) + stored, logicalSize: value.count).decode(cancelled: { false }), value)
    }

    func testLevelsOutsideEitherLayoutKeepPlainCompression() throws {
        func frames(_ text: String) -> Data {
            Data((#"{"version":1,"sample_rate":16000,"stream_evidence":"e","duration_samples":640,"activity":["# + text + "]}").utf8)
        }
        let first = #"{"start_sample":0,"end_sample":320,"level":0.5}"#
        for text in ["",
                     first + ",",
                     first + #",{"start_sample":320,"end_sample":641,"level":0.5}"#,
                     first + #",{"start_sample":319,"end_sample":639,"level":0.5}"#,
                     first + #",{"start_sample":0320,"end_sample":640,"level":0.5}"#,
                     first + #",{"start_sample":320,"end_sample":640,"level":}"#,
                     first + #",{"start_sample":320,"end_sample":640,"level":0.5 }"#,
                     first + #",{"start_sample":320,"end_sample":640,"level":null}"#,
                     first + #", {"start_sample":320,"end_sample":640,"level":0.5}"#,
                     #"{"start_sample":0,"end_sample":300,"level":0.5},{"start_sample":300,"end_sample":620,"level":0.5}"#,
                     #"{"end_sample":320,"level":0.5,"start_sample":0}"#] {
            XCTAssertNil(try SidecarActivityPacking.packProviderLayout(frames(text), cancelled: { false }), text)
        }
        XCTAssertNil(try SidecarActivityPacking.packProviderLayout(Data(), cancelled: { false }))
        // Evidence that opens a frame off the clock ends the search for the levels.
        let misleading = #"{"version":1,"sample_rate":16000,"stream_evidence":{"activity":[{"start_sample":7}]},"#
            + #""duration_samples":320,"activity":["# + first + "]}"
        XCTAssertNil(try SidecarActivityPacking.packProviderLayout(Data(misleading.utf8), cancelled: { false }))

        // An irregular clock is still stored losslessly, by the general compressor alone.
        let irregular = (0..<400).map { #"{"start_sample":\#($0 * 300),"end_sample":\#($0 * 300 + 300),"level":0.5}"# }
        let value = frames(irregular.joined(separator: ","))
        let payload = try SidecarPayload.encode(value, key: "transcript_activity.v1.0.irregular", cancelled: { false })
        XCTAssertEqual(payload.bytes.first, 1)
        XCTAssertEqual(try payload.decode(cancelled: { false }), value)
    }

    func testEarlierPayloadTagsStillDecode() throws {
        // Written out by hand, as an earlier build stored MPCut's own layout.
        let suffix = #"],"duration_samples":400,"sample_rate":16000,"stream_evidence":"e","version":1}"#
        let value = Data((#"{"activity":[{"end_sample":320,"level":0.5,"start_sample":0},"#
            + #"{"end_sample":400,"level":1,"start_sample":320}"# + suffix).utf8)
        let stored = Data([2, 144, 1, 0, 0, 0, 0, 0, 0, 0x0A, 0x5F, 0x1F]) + Data(suffix.utf8)
        XCTAssertEqual(try SidecarPayload(bytes: stored, logicalSize: value.count).decode(cancelled: { false }), value)
        XCTAssertEqual(try SidecarPayload(bytes: value, logicalSize: 0).decode(cancelled: { false }), value)
        for unknown in [UInt8(0), 12, 255] {
            XCTAssertNil(try SidecarPayload(bytes: Data([unknown]) + stored.dropFirst(), logicalSize: value.count)
                .decode(cancelled: { false }))
        }

        // MPCut's layout keeps the tags that earlier builds read.
        let levels = (0..<2000).map { Float(($0 * 37) % 1009) / 1009 }
        let own = try transcriptActivityDocument(levels: levels, duration: 2000 * 320, evidence: "stream")
        let compressed = try SidecarPayload.encode(own, key: "transcript_activity.v1.0.own", cancelled: { false })
        XCTAssertEqual(compressed.bytes.first, 3)
        XCTAssertEqual(try compressed.decode(cancelled: { false }), own)
        let packed = try XCTUnwrap(SidecarActivityPacking.pack(own, cancelled: { false }))
        XCTAssertEqual(try SidecarPayload(bytes: Data([2]) + packed, logicalSize: own.count).decode(cancelled: { false }), own)
        let plain = try SidecarPayload.encode(own, cancelled: { false })
        XCTAssertEqual(plain.bytes.first, 1)
        XCTAssertEqual(try plain.decode(cancelled: { false }), own)
    }

    func testDurableProviderArtifactPacksSmallerThanPlainCompression() throws {
        // Ten minutes at 50 frames a second: speech-like levels at full precision, with
        // stretches of digital silence and of a noise floor too quiet for a plain decimal.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        let levels = (0..<30_000).map { index -> Float in
            switch (index / 500) % 6 {
            case 0: return 0
            case 1: return random() * 0.00002
            default: return random() * random() * 0.4
            }
        }
        let duration = levels.count * 320 - 123
        let value = providerLevels(levels.map(providerSpelling), duration: duration)
        let key = "transcript_activity.v1.0." + TranscriptStore.digest(value)
        let packed = try SidecarPayload.encode(value, key: key, providerActivity: true, cancelled: { false })
        let plain = try SidecarPayload.encode(value, cancelled: { false })
        XCTAssertEqual(packed.bytes.first, 7)
        XCTAssertEqual(plain.bytes.first, 1)
        XCTAssertEqual(packed.logicalSize, value.count)
        XCTAssertEqual(try packed.decode(cancelled: { false }), value)

        let own = try transcriptActivityDocument(levels: levels, duration: Int64(duration), evidence: "stream")
        let ownPacked = try SidecarPayload.encode(own, key: key, cancelled: { false })
        XCTAssertEqual(ownPacked.bytes.first, 3)
        print("Synthetic 10-minute Transcriberrr levels: json=\(value.count) plain_lzfse=\(plain.bytes.count) "
            + "packed=\(packed.bytes.count) bytes; the same levels in MPCut's layout: json=\(own.count) "
            + "packed=\(ownPacked.bytes.count) bytes")
        XCTAssertLessThan(packed.bytes.count * 2, plain.bytes.count)
        XCTAssertLessThan(packed.bytes.count, ownPacked.bytes.count * 5 / 4)
    }

    func testRegularPacketsAfterExceptionalTimestampsUseRuns() throws {
        // A packet with distinct PTS/DTS, followed by one with zero duration.
        var bytes = Data([2, 0, 1, 2, 1, 2, 1, 0, 0, 2, 1, 0, 1, 0, 1, 0, 0, 2])
        for i in 0..<2000 {
            let timestamp = i * 2
            bytes.append(1)
            if timestamp < 128 {
                bytes.append(UInt8(timestamp))
            } else {
                bytes.append(UInt8(timestamp & 127) | 128)
                bytes.append(UInt8(timestamp >> 7))
            }
            bytes.append(contentsOf: [1, 2, 1, 0, 0, 2])
        }
        let payload = try SidecarPayload.encode(bytes, key: "media_index_audio.v1", cancelled: { false })
        XCTAssertTrue([4, 5].contains(try XCTUnwrap(payload.bytes.first)))
        XCTAssertLessThan(payload.bytes.count, 64)
        XCTAssertEqual(try payload.decode(cancelled: { false }), bytes)
    }
}
