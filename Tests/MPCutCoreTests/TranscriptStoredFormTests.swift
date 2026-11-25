import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptStoredFormTests: XCTestCase {
    private func time(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private func stored(_ document: TranscriptDocument) throws -> TranscriptDocument {
        try TranscriptCodec.decode(TranscriptCodec.encodeStored(document), format: .json)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every way an observation can agree with or differ from the words beside it.
    private func mixed() -> TranscriptDocument {
        let local = TranscriptWord(id: "a1", text: "Hello", start: time(1, 2), end: time(9, 10), speakerID: "local",
                                   precision: .word, observations: [], confidence: 0.5)
        let lav = TranscriptTrack(id: "lav", name: "Lav", sourceID: "a", streamIndex: 1, channel: 0,
                                  origin: time(-1, 3000), sessionStart: time(5, 4), coverage: .recognized,
                                  role: .isolatedMic, words: [local], speakers: [.init(id: "local", name: "Local")],
                                  streamEvidence: .string("evidence"), warning: "quiet")
        let room = TranscriptTrack(id: "room", name: "Room", coverage: .recognized, role: .mixedAudio)
        let camera = TranscriptTrack(id: "camera", name: "Camera", coverage: .coverageOnly, error: "no audio",
                                     approximateClock: true)
        func observation(_ track: String, word: String? = nil, text: String? = nil, start: RationalTime,
                         end: RationalTime, evidence: TranscriptEvidence = .recognized, basis: String? = nil,
                         speaker: String? = nil, confidence: Double? = nil) -> TranscriptObservation {
            .init(trackID: track, wordID: word, text: text, start: start, end: end, evidence: evidence, basis: basis,
                  speakerID: speaker, confidence: confidence)
        }
        let words = [
            // Shares everything with the track's own word.
            TranscriptWord(id: "w1", text: "Hello", start: time(7, 4), end: time(43, 20), utteranceID: "u1",
                           speakerID: "s1", precision: .word, observations: [
                               observation("lav", word: "a1", text: "Hello", start: time(1, 2), end: time(9, 10),
                                           speaker: "s1", confidence: 0.25),
                               // No text, another speaker, and bounds of its own on a track without words.
                               observation("room", word: "elsewhere", start: time(2), end: time(3), evidence: .inferred,
                                           basis: "aligned text", speaker: "s2")
                           ], candidateTrackIDs: [], confidence: 1),
            // A word whose text and speaker differ from the track's own word of that ID.
            TranscriptWord(id: "w2", text: "there", start: time(3), end: time(4), precision: .cue, observations: [
                observation("lav", word: "a1", start: time(1, 2), end: time(9, 10)),
                observation("room", text: "there", start: time(3), end: time(4)),
                observation("room", text: "their", start: time(3), end: time(4), speaker: "s1")
            ], candidateTrackIDs: ["camera", "lav"]),
            TranscriptWord(id: "w3", text: "", start: time(.min, .max), end: time(.max), speakerID: "s2",
                           precision: .word, observations: [],
                           projection: .init(clock: .currentCut, wordID: "w1", attachmentID: "attachment",
                                             originalText: "Hello", originalSpeakerID: "s1",
                                             originalSourceStart: time(1, 2), originalSourceEnd: time(9, 10),
                                             trackID: "lav", sourceID: "a", streamIndex: 1, routedSourceID: "b",
                                             routedStreamIndex: 2, clipID: "clip", assemblyIndex: 3, partial: true,
                                             staleMatches: false))
        ]
        return TranscriptDocument(clock: .session, tracks: [lav, room, camera],
                                  speakers: [.init(id: "s1", name: "Host"), .init(id: "s2", name: "Guest")],
                                  words: words, approximateClock: true, jobID: "job", fingerprint: "fingerprint",
                                  provenance: .init(source: "import", model: "model", device: nil, language: "en",
                                                    duration: time(1001, 30), metadata: .object(["k": .number(1)])))
    }

    func testStoredFormReadsBackAsTheSameDocument() throws {
        let document = mixed()
        try document.validate()
        XCTAssertEqual(try stored(document), document)
        let session = try TranscriptCodec.decode(Data(contentsOf: Self.fixture("session-result-v1.json")), format: .json)
        XCTAssertFalse(session.words.isEmpty)
        XCTAssertEqual(try stored(session), session)
        XCTAssertEqual(try stored(TranscriptDocument(clock: .presentation)), TranscriptDocument(clock: .presentation))
    }

    func testCanonicalProviderActivityFixture() throws {
        let bytes = try Data(contentsOf: Self.fixture("stored-v4.json"))
        let transcript = try TranscriptCodec.decode(bytes, format: .json)
        XCTAssertEqual(transcript.tracks.first?.activity, [.init(start: time(-1, 16_000),
                                                                  end: time(319, 16_000), level: 0.0625)])
        XCTAssertEqual(try TranscriptCodec.encodeStored(transcript), bytes)
        XCTAssertEqual(TranscriptStore.digest(bytes), "764425695167689881c7de216c9506ddec58bba0c16484394fd99ed09153b352")
    }

    func testStoredFormSharesWhatAnObservationRepeats() throws {
        let root = try json(TranscriptCodec.encodeStored(mixed()))
        XCTAssertEqual(root["schema_version"] as? Int, 4)
        let tracks = try XCTUnwrap(root["tracks"] as? [[String: Any]])
        XCTAssertNil(tracks[0]["provider_activity"])
        XCTAssertEqual(tracks[0]["origin"] as? String, "-1/3000")
        XCTAssertEqual(tracks[1]["origin"] as? String, "0")
        let own = try XCTUnwrap((tracks[0]["words"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(own.keys), ["i", "t", "s", "e", "p", "c"])
        let words = try XCTUnwrap(root["words"] as? [[String: Any]])
        XCTAssertEqual(words[0]["s"] as? String, "7/4")
        XCTAssertNil(words[0]["q"])
        XCTAssertEqual(words[0]["k"] as? [Int], [])
        let first = try XCTUnwrap(words[0]["o"] as? [[String: Any]])
        XCTAssertEqual(Set(first[0].keys), ["r", "w", "c"])
        XCTAssertEqual(first[0]["r"] as? Int, 0)
        XCTAssertEqual(Set(first[1].keys), ["r", "w", "x", "s", "e", "v", "b", "p"])
        XCTAssertTrue(first[1]["x"] is NSNull)
        XCTAssertEqual(words[1]["q"] as? String, "cue")
        XCTAssertEqual(words[1]["k"] as? [Int], [2, 0])
        let second = try XCTUnwrap(words[1]["o"] as? [[String: Any]])
        // The track's own word says "Hello" where this observation says nothing.
        XCTAssertEqual(Set(second[0].keys), ["r", "w", "x"])
        XCTAssertEqual(Set(second[1].keys), ["r"])
        XCTAssertEqual(Set(second[2].keys), ["r", "x", "p"])
        XCTAssertNil(words[2]["o"])
        XCTAssertNil(words[2]["k"])
    }

    func testWritersPreserveProviderActivity() throws {
        var document = mixed()
        document.tracks[0].activity = [.init(start: time(0), end: time(1, 50), level: 0.25),
                                       .init(start: time(1, 50), end: time(1, 25), level: 0)]
        try document.validate()
        XCTAssertEqual(try stored(document), document)
        let exported = try TranscriptCodec.encode(document, format: .json)
        XCTAssertEqual(try TranscriptCodec.decode(exported, format: .json), document)
        let root = try json(exported)
        XCTAssertEqual(root["schema_version"] as? Int, 2)
        XCTAssertEqual(((root["tracks"] as? [[String: Any]])?.first?["activity"] as? [Any])?.count, 2)
        // A document written before still reads with its levels.
        let encoder = JSONEncoder()
        XCTAssertEqual(try TranscriptCodec.decode(encoder.encode(document), format: .json), document)
    }

    func testNativeProviderLevelsUseTheSourceClockAndSurviveStorage() throws {
        let session = try String(contentsOf: Self.fixture("session-result-v1.json"), encoding: .utf8)
        var root = try json(Data(session.utf8))
        var tracks = try XCTUnwrap(root["tracks"] as? [[String: Any]])
        tracks[0]["activity"] = [["start_sample": 0, "end_sample": 320, "level": 0.5]]
        root["tracks"] = tracks
        let document = try TranscriptCodec.decode(JSONSerialization.data(withJSONObject: root), format: .json)
        let origin = time(1, 48_000)
        XCTAssertEqual(document.tracks[0].activity, [.init(start: origin, end: try origin.adding(time(1, 50)), level: 0.5)])
        XCTAssertEqual(try stored(document), document)
        for frame in [["start_sample": 320, "end_sample": 320, "level": 0.5],
                      ["start_sample": -1, "end_sample": 320, "level": 0.5],
                      ["start_sample": 0, "end_sample": 320, "level": -0.5]] {
            tracks[0]["activity"] = [frame]
            root["tracks"] = tracks
            XCTAssertThrowsError(try TranscriptCodec.decode(JSONSerialization.data(withJSONObject: root), format: .json)) {
                XCTAssertEqual(($0 as? CutError)?.code, "invalid_transcript")
            }
        }
    }

    func testLongTranscriptUsesCanonicalCompactJSONAndReadsBack() throws {
        let track = "t-" + String(repeating: "0123456789abcdef", count: 4)
        var own: [TranscriptWord] = []
        var words: [TranscriptWord] = []
        for index in 0..<4000 {
            let start = time(Int64(index) * 5120, 16_000)
            let end = time(Int64(index) * 5120 + 3200, 16_000)
            own.append(.init(id: "w\(index)", text: "word\(index % 97)", start: start, end: end, precision: .word,
                             observations: []))
            words.append(.init(id: "w\(index)", text: "word\(index % 97)", start: start, end: end,
                               utteranceID: "u\(index / 12)", speakerID: "s1", precision: .word, observations: [
                                   .init(trackID: track, wordID: "w\(index)", text: "word\(index % 97)", start: start,
                                         end: end, evidence: .recognized, speakerID: "s1")
                               ]))
        }
        let document = TranscriptDocument(clock: .session,
                                          tracks: [.init(id: track, name: "Mic", words: own)],
                                          speakers: [.init(id: "s1", name: "Host")], words: words)
        let exported = try TranscriptCodec.encode(document, format: .json)
        let kept = try TranscriptCodec.encodeStored(document)
        XCTAssertEqual(kept.first, Character("{").asciiValue)
        XCTAssertLessThan(kept.count * 3, exported.count)
        XCTAssertEqual(try TranscriptCodec.decode(kept, format: .json), document)
        XCTAssertEqual(try TranscriptCodec.encodeStored(TranscriptCodec.decode(kept, format: .json)), kept)
    }

    func testStandaloneV3ImportReadsPlainAndCompressedDocuments() throws {
        let source = Data(#"{"schema_version":3,"clock":"session","tracks":[],"speakers":[],"words":[],"approximate_clock":false}"#.utf8)
        var wrapped = Data([0, 0x4d, 0x50, 0x43, 0x54, 0x5a, 0x31, 0x0a])
        withUnsafeBytes(of: UInt64(source.count).littleEndian) { wrapped.append(contentsOf: $0) }
        wrapped.append(try (source as NSData).compressed(using: .lzfse) as Data)
        for input in [source, wrapped] {
            XCTAssertEqual(try TranscriptCodec.decode(input, format: .json), TranscriptDocument(clock: .session))
        }
        wrapped[8] ^= 1
        XCTAssertThrowsError(try TranscriptCodec.decode(wrapped, format: .json)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_transcript")
        }
    }

    func testStoredFormRefusesWhatItDoesNotWrite() throws {
        let word = #"{"i":"w","t":"t","s":"0","e":"1/2"}"#
        func document(words: String = "", tracks: String = "", version: Int = 4) -> Data {
            Data(#"{"schema_version":\#(version),"clock":"presentation","approximate_clock":false,"speakers":[],"tracks":[\#(tracks)],"words":[\#(words)]}"#.utf8)
        }
        let track = #"{"id":"a","name":"A","origin":"0","session_start":"0","coverage":"recognized","role":"unknown"}"#
        XCTAssertEqual(try TranscriptCodec.decode(document(words: word), format: .json).words.first?.end, time(1, 2))
        XCTAssertEqual(try TranscriptCodec.decode(document(words: #"{"i":"w","t":"t","s":"0","e":"1","o":[{"r":0}]}"#,
                                                           tracks: track), format: .json).words[0].observations[0].end,
                       time(1))
        let refused = [
            document(words: word, version: 5),
            document(words: #"{"i":"w","t":"t","s":"0","e":"1/0"}"#),
            document(words: #"{"i":"w","t":"t","s":"0","e":"0.5"}"#),
            document(words: #"{"i":"w","t":"t","s":"0","e":" 1"}"#),
            document(words: #"{"i":"w","t":"t","s":"","e":"1"}"#),
            document(words: #"{"i":"w","t":"t","s":"0","e":"1/-2"}"#),
            document(words: #"{"i":"w","t":"t","s":"0","e":"9223372036854775808"}"#),
            document(words: #"{"i":"w","t":"t","s":"0","e":{"numerator":1,"denominator":2}}"#),
            document(words: #"{"i":"w","t":"t","s":"0","e":"1","o":[{"r":1}]}"#, tracks: track),
            document(words: #"{"i":"w","t":"t","s":"0","e":"1","o":[{"r":0,"s":"0"}]}"#, tracks: track),
            document(words: #"{"i":"w","t":"t","s":"0","e":"1","k":[3]}"#, tracks: track),
            document(words: word, tracks: track + "," + track),
            Data(String(decoding: document(words: word), as: UTF8.self).replacingOccurrences(of: #""words""#, with: #""extra":1,"words""#).utf8),
            document(tracks: #"{"id":"a","name":"A","origin":"0","session_start":"0","coverage":"recognized","role":"unknown","activity":[]}"#),
            document(tracks: #"{"id":"a","name":"A","origin":"0","session_start":"0","coverage":"recognized","role":"unknown","words":[{"i":"w","t":"t","s":"0","e":"1","o":[{"r":0}]}]}"#)
        ]
        for (index, data) in refused.enumerated() {
            XCTAssertThrowsError(try TranscriptCodec.decode(data, format: .json), "case \(index)") {
                let code = ($0 as? CutError)?.code
                XCTAssertEqual(code, index == 0 ? "unsupported_transcript_version" : "invalid_transcript", "case \(index)")
            }
        }
        XCTAssertEqual(try TranscriptCodec.decode(document(words: #"{"i":"w","t":"t","s":"-9223372036854775808/9223372036854775807","e":"0"}"#),
                                                  format: .json).words[0].start, time(.min, .max))
    }

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/fixtures/transcripts/\(name)")
    }
}
