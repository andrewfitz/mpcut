import Foundation
import XCTest
@testable import MPCutCore

/// The documents and files here are repeated in Transcriberrr's
/// `src/session/shared_cache/exchange.rs`. Each program reads what the other wrote.
final class TranscriptRecognitionExchangeTests: XCTestCase {
    private static let frames = 48
    private static let duration = 47 * 320 + 100

    /// Transcriberrr's levels: header first, each start before its end, a short last frame.
    private static func providerFrames() -> String {
        let spellings = ["0.0", "0.012345679", "1.0", "0.5", "3.0517578e-5", "0.25", "0.0009765625"]
        return (0..<frames).map { index in
            let start = index * 320
            return "{\"start_sample\":\(start),\"end_sample\":\(min(start + 320, duration)),\"level\":\(spellings[index % spellings.count])}"
        }.joined(separator: ",")
    }

    private static let providerLevels = Data(
        "{\"version\":1,\"sample_rate\":16000,\"stream_evidence\":\"fixture\",\"duration_samples\":\(duration),\"activity\":[\(providerFrames())]}".utf8)

    /// MPCut's levels: sorted keys, and no fraction on a whole number.
    private static let ownLevels: Data = {
        let spellings = ["0", "0.012345679", "1", "0.5", "3.0517578e-05", "0.25"]
        let entries = (0..<frames).map { index in
            let start = index * 320
            return "{\"end_sample\":\(min(start + 320, duration)),\"level\":\(spellings[index % spellings.count]),\"start_sample\":\(start)}"
        }.joined(separator: ",")
        return Data("{\"activity\":[\(entries)],\"duration_samples\":\(duration),\"sample_rate\":16000,\"stream_evidence\":\"fixture\",\"version\":1}".utf8)
    }()

    private static func result(activity: String) -> Data {
        Data(("{\"version\":1,\"sample_rate\":16000,\"recognition_key\":\"\(String(repeating: "a", count: 64))\","
            + "\"stream_evidence\":\"fixture\",\"duration_samples\":\(duration),\"words\":[{\"id\":\"w1\",\"utterance_id\":\"u1\","
            + "\"text\":\"hello\",\"start_sample\":320,\"end_sample\":3200,\"speaker_id\":null,\"precision\":\"word\"}],"
            + "\"activity\":[\(activity)],\"warning\":null}").utf8)
    }

    private struct Sample {
        let name: String
        let result: Data
        let activity: Data?
        let digest: String
        /// The method of each stored document, which shows that the file exercises it.
        let methods: [UInt8]
        let fromMPCut: String
        let fromTranscriberrr: String
    }

    private static let samples = [
        Sample(name: "provider-levels", result: result(activity: ""), activity: providerLevels,
               digest: "80225a610ac8bd6f95bd9bae9247ef62461d04d779f6faf993382a285cf2bff4", methods: [1, 3],
               fromMPCut: "TVBDWAIBAACAIlphCsi9b5W9m66SR+9iRh0E13n2+vmTOCooXPK/9AFLAQAAtQAAAKWQvQ7CMAyE38Vzh5a/oa+CUGU1BixCWrlOW4R4d46WgZ1M8cW+7+InjWKDdonqqqCB732UxtgF9aEsy4JM2u6S1NHT3ORBNfGfhwByE743MmqQ1AJGZ509m+AtZPA/tDXNgCT7aockU2cB1fFJGjAxVWjO7mIMi2bR8kdzmR33q8TYLSw2/5pRvd3ASVL4FaAMvfBNbHFJOcaCenxc180sZHqdCuLWdVTHFo6oJrak6bJOvN4D7woAAIEAAABTsWYAgyQgrlYqSy0qzszPU7Iy1FEqTswtyEmNL0osSQXyzQwMDIBiJUWpibnxqWWZKal5yUBxpbTMipLSolQlHaWUUqBSoOZ4iMZioCZTQxOgpsTkksyyzJJKJatoLn4uRmXX9PlS/FzxVqzi4b1b/3Op/udi4CwLA1JDQzK2FgA=",
               fromTranscriberrr: "TVBDWAIBAACAIlphCsi9b5W9m66SR+9iRh0E13n2+vmTOCooXPK/9AFLAQAAtQAAAKWQvQ7CMAyE38Vzh5a/oa+CUGU1BixCWrlOC0K8O9eWgZ1M8cW+7+IXjWKDdonqqqCB732UxtgF9aEsy4JM2u6S1NHT3ORJNfGfhwByE743MmqQ1AJGZ314NsFbyODPtDXNgCT7aockU2cB1fFFGjAxVWjO7mIMi2bR8qy5PBz3q8TYLSw2/5pRvd3ASVL4FaAMvfBNbHFJOcaCenxc180sZHqfCuLWdVTHFo6oJrak6bJOvD8D7woAAI0AAADViz0KwkAQhWNh4TYpBctRuxQbUIu19gpaiCxrMsqAibI7WRTxCJ7BU3i+OJhTZGB4vJ9vtk7+d5R/QkQf6FqDyTMIrrpd0HrHKH6ltZaMPbrKYqQS60JyONGdG4+QQdnIVGDbgUGgZb4QyBVMkfgBZq9SNZhuzp9JqqwZjnfvb6vmrUpGcSvSj/Lw+gE="),
        Sample(name: "own-levels", result: Data("{}".utf8), activity: ownLevels,
               digest: "fdbe01857120da5330faaa5eafa91a25f1266e6747bfe9a51f01fe67aea9c57e", methods: [0, 2],
               fromMPCut: "TVBDWAIBAAD9vgGFcSDaUzD6ql6vqRol8SZuZ0e/6aUfAf5nrqnFfgACAAAAAgAAAHt9ArMKAABpAAAAU7FmAAN+LkZl1/T58lzxVqzi4b0b4rlU/w8msVgdpZTSosSSzPy8+OLE3IKc1GIlK0NTQxMDHSUIPx4omwoUMzMwAImVFKUm5sanlmWmpOYlA8WV0jIrSkqLUpV0lMpSi4qB5gDV1gIA",
               fromTranscriberrr: "TVBDWAIBAAD9vgGFcSDaUzD6ql6vqRol8SZuZ0e/6aUfAf5nrqnFfgACAAAAAgAAAHt9ArMKAAB6AAAAzcw9DoJAEAVgLWy2sbQ0GbXbYknUAmvPYGUmGxjIJvxldyE0HIEzcAVuCANcgunmey/v/jmsdxbH2zcdrgLD0+XXjyge057sLyGurfamLNDpvMrIQRi8gqeSsP3IKbG9lVrMW9I5UmNiKiJ2SEzra0sgoSHreIe73Qw="),
        Sample(name: "embedded-levels", result: result(activity: providerFrames()), activity: nil,
               digest: "8ce67567a3e6e9b4441b9a67235774645e97ce711a52ac56397dcb7dd202cfaf", methods: [3],
               fromMPCut: "TVBDWAIAAACM5nVno+bptEQbmmcjV3RkXpfOcRpSrFY5fct90gLPrwPWCwAA7wAAANVQO1LEMAzNFhS42ZIZSgFdioRfYWquAMUO4/HEInjW62QUOVlmZ4/AGTgF51u0DgU9FWpsPUnvPenyocihF0WxgxFp8F0EXZcw2E0f0JBllPy+qqoSCJuujZ6lx6zxHTTYPwaIEBPajcHRO4yNiMGr33IilJpLon9Um90M4uSuvhUnU0dOstUOvJOJqZbmxIxkhcJkLB0xxi3L/w1D6LKWJf4hA31zLUwY3W9AkKFHu0bKLDGFUEIvi/v5MlkZ9i8l2Ib96FmusFJLtbh4bD/Pl8rok7Pnj6+Dujqo4nR8kud/FGWjyVL0sZ233n8D",
               fromTranscriberrr: "TVBDWAIAAACM5nVno+bptEQbmmcjV3RkXpfOcRpSrFY5fct90gLPrwPWCwAA7wAAANVQO1LEMAzNFhS42ZIZSgFdioRfYWquAMUO4/HEInjW62QUOVlmZ4/AGTgF51u0DgU9FWpsPUnv6enyocihF0WxgxFp8F0EXZcw2E0f0JBllPy+qqoSCJuujZ6lx6zxHTTYPwaIEBPajcHRO4yNiMGr33IilJpLon9Um7cZZJO7+lY2mTpykq124J1MTLU0J2YkKxQmY+mIMW5Z/m8YQpe1LPEPGeiba2HC6H4Dggw92jVSZokphBJ6Me7ny2Rl2L+UYBv2o2e5wkot1eLisf08XyqjT86eP74O6uqgitPxSZ7/URRHk6XoYzu73n8D"),
    ]

    private func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    private func methods(in file: Data) -> [UInt8] {
        var found = [UInt8](), position = 40
        while position + 9 <= file.count {
            found.append(file[position])
            position += 9 + (0..<4).reduce(0) { $0 | Int(file[position + 5 + $1]) << (8 * $1) }
        }
        return found
    }

    func testEachProgramReadsTheFilesTheOtherWrote() throws {
        for sample in Self.samples {
            XCTAssertEqual(hex(TranscriptRecognitionExchange.digest(result: sample.result, activity: sample.activity)),
                           sample.digest, sample.name)
            for (writer, text) in [("MPCut", sample.fromMPCut), ("Transcriberrr", sample.fromTranscriberrr)] {
                let file = try XCTUnwrap(Data(base64Encoded: text), "\(sample.name) from \(writer)")
                XCTAssertEqual(hex(file[8..<40]), sample.digest, "\(sample.name) from \(writer)")
                XCTAssertEqual(methods(in: file), sample.methods, "\(sample.name) from \(writer)")
                let read = try XCTUnwrap(TranscriptRecognitionExchange.decode(file, cancelled: { false }),
                                         "\(sample.name) from \(writer)")
                XCTAssertEqual(read.result, sample.result, "\(sample.name) from \(writer)")
                XCTAssertEqual(read.activity, sample.activity, "\(sample.name) from \(writer)")
            }
            // This build still writes what the checked-in file holds.
            let written = try XCTUnwrap(TranscriptRecognitionExchange.encode(result: sample.result, activity: sample.activity,
                                                                             cancelled: { false }))
            XCTAssertEqual(methods(in: written), sample.methods, sample.name)
            let read = try XCTUnwrap(TranscriptRecognitionExchange.decode(written, cancelled: { false }))
            XCTAssertEqual(read.result, sample.result, sample.name)
            XCTAssertEqual(read.activity, sample.activity, sample.name)
        }
    }

    func testEveryDocumentReadsBackAsItsOwnBytes() throws {
        func roundTrip(_ result: Data, _ activity: Data?, methods expected: [UInt8], line: UInt = #line) throws {
            let file = try XCTUnwrap(TranscriptRecognitionExchange.encode(result: result, activity: activity,
                                                                          cancelled: { false }), line: line)
            XCTAssertEqual(methods(in: file), expected, line: line)
            let read = try XCTUnwrap(TranscriptRecognitionExchange.decode(file, cancelled: { false }), line: line)
            XCTAssertEqual(read.result, result, line: line)
            XCTAssertEqual(read.activity, activity, line: line)
            // A slice of a larger buffer reads the same.
            let padded = Data([1, 2, 3]) + file
            XCTAssertEqual(try TranscriptRecognitionExchange.decode(padded.dropFirst(3), cancelled: { false })?.result,
                           result, line: line)
        }
        let result = Self.result(activity: "")
        try roundTrip(result, Self.providerLevels, methods: [1, 3])
        try roundTrip(result, Self.ownLevels, methods: [1, 2])
        // Levels that are present but empty differ from no levels, under the same digest.
        try roundTrip(result, Data(), methods: [1, 0])
        try roundTrip(result, nil, methods: [1])
        // A layout that neither packing describes is compressed as it is.
        let spaced = Data(String(decoding: Self.providerLevels, as: UTF8.self)
            .replacingOccurrences(of: "\"start_sample\":0,", with: "\"start_sample\": 0,").utf8)
        try roundTrip(result, spaced, methods: [1, 1])
        // Evidence may quote the array's key before the levels begin.
        let quoting = Data(String(decoding: Self.providerLevels, as: UTF8.self)
            .replacingOccurrences(of: "\"fixture\"", with: "{\"note\":\"\\\"activity\\\":[\",\"activity\":[1]}").utf8)
        try roundTrip(result, quoting, methods: [1, 3])
        // One frame packs to less than DEFLATE can shorten, so its document is compressed whole.
        let single = Data("{\"version\":1,\"sample_rate\":16000,\"stream_evidence\":\"fixture\",\"duration_samples\":7,\"activity\":[{\"start_sample\":0,\"end_sample\":7,\"level\":0.5}]}".utf8)
        let file = try XCTUnwrap(TranscriptRecognitionExchange.encode(result: result, activity: single, cancelled: { false }))
        let read = try XCTUnwrap(TranscriptRecognitionExchange.decode(file, cancelled: { false }))
        XCTAssertEqual(read.activity, single)
        var random = SystemRandomNumberGenerator()
        let noise = Data((0..<5000).map { _ in UInt8.random(in: 0...255, using: &random) })
        try roundTrip(noise, noise, methods: [0, 0])
    }

    func testDamagedOrUnknownFilesReadAsAbsent() throws {
        let file = try XCTUnwrap(TranscriptRecognitionExchange.encode(result: Self.result(activity: ""),
                                                                      activity: Self.providerLevels, cancelled: { false }))
        func read(_ change: (inout Data) -> Void) throws -> Bool {
            var copy = file
            change(&copy)
            return try TranscriptRecognitionExchange.decode(copy, cancelled: { false }) != nil
        }
        XCTAssertTrue(try read { _ in })
        XCTAssertFalse(try read { $0[0] = 0x4E })
        XCTAssertFalse(try read { $0[4] = 3 })
        XCTAssertFalse(try read { $0[5] = 3 })
        XCTAssertFalse(try read { $0[5] = 0 })
        XCTAssertFalse(try read { $0[6] = 1 })
        XCTAssertFalse(try read { $0[8] ^= 1 })
        XCTAssertFalse(try read { $0[40] = 9 })
        XCTAssertFalse(try read { $0[41] ^= 1 })
        XCTAssertFalse(try read { $0[44] = 0x7F })
        XCTAssertFalse(try read { $0[$0.count - 20] ^= 0x10 })
        XCTAssertFalse(try read { $0.append(0) })
        XCTAssertFalse(try read { $0.removeLast() })
        for length in [0, 3, 39, 40, 48] {
            XCTAssertNil(try TranscriptRecognitionExchange.decode(file.prefix(length), cancelled: { false }))
        }
        XCTAssertNil(try TranscriptRecognitionExchange.decode(Data("{\"result\":\"\",\"digest\":\"\"}".utf8), cancelled: { false }))
    }

    func testFolderDeclaresTheVersionThisBuildReads() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPCut-exchange-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("exchange-version")
        TranscriptRecognitionExchange.declareReader(in: folder)
        XCTAssertEqual(try Data(contentsOf: marker), Data("2\n".utf8))
        try Data("1\n".utf8).write(to: marker)
        TranscriptRecognitionExchange.declareReader(in: folder)
        XCTAssertEqual(try Data(contentsOf: marker), Data("2\n".utf8))
        // Pruning leaves the declaration, whatever its age.
        let later = Date().addingTimeInterval(400 * 86_400)
        XCTAssertEqual(TranscriptRecognitionClaims.prune(in: folder, olderThan: 86_400, now: later), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["exchange-version"])
    }

    /// With `MPCUT_TEST_EXCHANGE_FOLDER` set, writes each sample for Transcriberrr's tests
    /// to read. For every `<name>.result.json` there (with `<name>.activity.json`), reports
    /// both versions' sizes, writes `<name>.mpcut.mpx`, and reads `<name>.transcriberrr.mpx`.
    func testExchangesFilesWithTranscriberrrInAFolder() throws {
        guard let path = ProcessInfo.processInfo.environment["MPCUT_TEST_EXCHANGE_FOLDER"] else {
            throw XCTSkip("Set MPCUT_TEST_EXCHANGE_FOLDER to a folder that Transcriberrr's exchange test also uses.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        for sample in Self.samples {
            let file = try XCTUnwrap(TranscriptRecognitionExchange.encode(result: sample.result, activity: sample.activity,
                                                                          cancelled: { false }))
            print("sample \(sample.name) digest=\(hex(file[8..<40])) methods=\(methods(in: file)) mpcut=\(file.base64EncodedString())")
        }
        struct Legacy: Encodable {
            let result: Data
            let activity: Data?
            let digest: String
        }
        // Ten minutes and three hours of MPCut's own levels, from one fixed sequence.
        for (name, count) in [("own-10min", 30_000), ("own-3h", 540_000)] {
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            var speech = false, remaining = 0
            let levels: [Float] = (0..<count).map { index in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float(state >> 40) / Float(1 << 24)
                if remaining == 0 {
                    speech.toggle()
                    remaining = 25 + Int(state >> 33) % (speech ? 200 : 100)
                }
                remaining -= 1
                return speech ? 0.02 + 0.28 * unit * abs(sin(Float(index) * 0.21)) : 0.0002 + 0.0008 * unit
            }
            let duration = Int64(count * 320 - 60)
            let activity = try transcriptActivityDocument(levels: levels, duration: duration, evidence: "measured",
                                                          cancelled: { false })
            let result = Data("{\"version\":1,\"sample_rate\":16000,\"recognition_key\":\"\(String(repeating: "b", count: 64))\",\"stream_evidence\":\"measured\",\"duration_samples\":\(duration),\"words\":[],\"activity\":[],\"warning\":null}".utf8)
            try result.write(to: folder.appendingPathComponent(name + ".result.json"))
            try activity.write(to: folder.appendingPathComponent(name + ".activity.json"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".result.json") }.map { String($0.dropLast(".result.json".count)) }.sorted()
        for name in names {
            func url(_ suffix: String) -> URL { folder.appendingPathComponent(name + suffix) }
            let result = try Data(contentsOf: url(".result.json"))
            let activity = try? Data(contentsOf: url(".activity.json"))
            let digest = hex(TranscriptRecognitionExchange.digest(result: result, activity: activity))
            let legacy = try JSONEncoder().encode(Legacy(result: result, activity: activity, digest: digest))
            let started = Date()
            let file = try XCTUnwrap(TranscriptRecognitionExchange.encode(result: result, activity: activity,
                                                                          cancelled: { false }))
            let encoded = Date()
            let read = try XCTUnwrap(TranscriptRecognitionExchange.decode(file, cancelled: { false }))
            let decoded = Date()
            XCTAssertEqual(read.result, result, name)
            XCTAssertEqual(read.activity, activity, name)
            try file.write(to: url(".mpcut.mpx"))
            var line = "exchange \(name): documents=\(result.count + (activity?.count ?? 0)) v1=\(legacy.count) v2=\(file.count) "
                + "methods=\(methods(in: file)) digest=\(digest) "
                + String(format: "encode=%.2fs decode=%.2fs", encoded.timeIntervalSince(started), decoded.timeIntervalSince(encoded))
            if let other = try? Data(contentsOf: url(".transcriberrr.mpx")) {
                let theirs = try XCTUnwrap(TranscriptRecognitionExchange.decode(other, cancelled: { false }), name)
                XCTAssertEqual(theirs.result, result, name)
                XCTAssertEqual(theirs.activity, activity, name)
                XCTAssertEqual(hex(other[8..<40]), digest, name)
                line += " transcriberrr_v2=\(other.count) read_identically=true"
            }
            print(line)
        }
    }
}
