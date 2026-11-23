import Foundation
@testable import MPCutCore
import XCTest

/// The direct reader for stored results must give exactly the value the general decoder
/// gives, or step aside.
final class TranscriptDocumentReaderTests: XCTestCase {
    private struct Generator {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }

        mutating func chance(_ outOf: Int) -> Bool { next(outOf) == 0 }
    }

    private func general(_ data: Data) throws -> TranscriptDocument {
        try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    private func time(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        .init(numerator: numerator, denominator: denominator)
    }

    private var everyField: TranscriptDocument {
        let texts = ["plain", "", " leading space", "quote \" and \\ backslash", "line\nbreak\ttab\r", "é ü ñ — “curly”",
                     "emoji 🎬👩🏽‍🚀", "control \u{01}\u{1F} and \u{7F}", "slash / and \u{2028} separator", "日本語のテキスト"]
        let confidences: [Double] = [0, 1, 0.1, 1.0 / 3, 0.30000000000000004, 1e-7, 5e-324, 1.7976931348623157e308,
                                     123_456_789.123_456_789, 2.5e-10, 1e21]
        let observations = texts.enumerated().map { number, text in
            TranscriptObservation(trackID: number.isMultiple(of: 2) ? "lav" : "a-rather-long-track-identifier-0001",
                                  wordID: number.isMultiple(of: 3) ? nil : "t\(number)", text: number.isMultiple(of: 4) ? nil : text,
                                  start: time(Int64(number) - 3, 7), end: time(Int64(number) * 1_000_003, 48_000),
                                  evidence: number.isMultiple(of: 2) ? .recognized : .inferred,
                                  basis: number.isMultiple(of: 2) ? nil : "same wording \(text)",
                                  speakerID: number.isMultiple(of: 5) ? nil : "speaker-\(number % 2)",
                                  confidence: number < confidences.count ? confidences[number] : nil)
        }
        let projection = TranscriptWordProjection(
            clock: .currentCut, wordID: "original", attachmentID: "interview", originalText: texts[3],
            originalSpeakerID: "speaker-1", originalSourceStart: time(-1, 3), originalSourceEnd: time(Int64.max),
            trackID: "lav", sourceID: "camera", streamIndex: 2, routedSourceID: "mixer", routedStreamIndex: 0,
            clipID: "clip-9", assemblyIndex: 4, partial: true, staleMatches: false)
        let bare = TranscriptWordProjection(
            clock: .group, wordID: "w", attachmentID: nil, originalText: "", originalSpeakerID: nil,
            originalSourceStart: nil, originalSourceEnd: nil, trackID: nil, sourceID: nil, streamIndex: nil,
            routedSourceID: nil, routedStreamIndex: nil, clipID: nil, assemblyIndex: nil, partial: false, staleMatches: true)
        var words = texts.enumerated().map { number, text in
            TranscriptWord(id: "w\(number)", text: text, start: time(Int64(number), 4), end: time(Int64(number) + 1, 4),
                           utteranceID: number < 2 ? nil : "utterance-\(number / 3)", speakerID: number.isMultiple(of: 2) ? "speaker-0" : nil,
                           precision: number.isMultiple(of: 3) ? .cue : .word, observations: Array(observations.prefix(number % 4)),
                           candidateTrackIDs: number.isMultiple(of: 3) ? ["lav", "a-rather-long-track-identifier-0001"] : nil,
                           confidence: confidences[number % confidences.count],
                           projection: number == 4 ? projection : number == 5 ? bare : nil)
        }
        words.append(.init(id: "edge", text: "edge", start: time(Int64.min), end: time(Int64.max, Int64.max)))
        let tracks = [
            TranscriptTrack(id: "lav", name: "Lavalier \"A\"", sourceID: "camera", streamIndex: 1, channel: 0,
                            origin: time(1, 3), sessionStart: time(-5, 2), coverage: .recognized, role: .isolatedMic,
                            activity: (0..<5).map { .init(start: time($0), end: time($0 + 1), level: Double($0) / 7) },
                            words: Array(words.prefix(4)), speakers: [.init(id: "local", name: "Local \\ speaker")],
                            streamEvidence: .string("aac 48000 \"stereo\""), error: nil, warning: "clipped\nlevels",
                            approximateClock: true),
            TranscriptTrack(id: "a-rather-long-track-identifier-0001", name: "Camera", coverage: .coverageOnly, role: .mixedAudio,
                            streamEvidence: .object(["codec": .string("pcm"), "rate": .number(48_000), "tags": .array([.null, .boolean(true), .number(Decimal(string: "0.1")!)])]),
                            error: "No speech"),
            TranscriptTrack(id: "skipped", name: "Skipped", coverage: .skipped, streamEvidence: .number(3))
        ]
        let provenance = TranscriptProvenance(source: "helper", model: "large", device: nil, language: "en", duration: time(7_201, 2),
                                              metadata: .object(["nested": .object(["list": .array([.number(1), .string("two")])]),
                                                                 "nothing": .null]))
        return TranscriptDocument(clock: .session, tracks: tracks,
                                  speakers: [.init(id: "speaker-0", name: "Host"), .init(id: "speaker-1", name: "Guest 🎙")],
                                  words: words, approximateClock: true, jobID: "0B5E", fingerprint: String(repeating: "f", count: 64),
                                  provenance: provenance)
    }

    func testReaderGivesTheGeneralDecodersValueForEveryFieldAndLayout() throws {
        let document = everyField
        let layouts: [JSONEncoder.OutputFormatting] = [[.sortedKeys, .withoutEscapingSlashes], [], [.prettyPrinted],
                                                       [.prettyPrinted, .sortedKeys]]
        for layout in layouts {
            let encoder = JSONEncoder()
            encoder.outputFormatting = layout
            let data = try encoder.encode(document)
            let read = try XCTUnwrap(TranscriptDocumentReader.document(from: data), "layout \(layout.rawValue)")
            XCTAssertEqual(read, try general(data))
            XCTAssertEqual(read, document)
            for (left, right) in zip(read.words, document.words) {
                XCTAssertEqual(left.confidence?.bitPattern, right.confidence?.bitPattern)
            }
        }
    }

    func testReaderAcceptsEscapesAndNumbersTheGeneralDecoderReadsTheSame() throws {
        let json = #"""
         { "schema_version" : 2 , "clock":"presentation","approximate_clock":false,
           "speakers":[ ] ,"job_id":null,"tracks":[{"id":"a\/b","name":"caf\u00e9 \ud83c\udfac \"q\" \b\f\n\r\t","origin":{"numerator":-9223372036854775808,"denominator":9223372036854775807},
           "session_start":{"denominator":4,"numerator":6},"coverage":"coverage_only","role":"isolated_mic",
           "activity":[{"start":{"numerator":0,"denominator":1},"end":{"numerator":1,"denominator":1},"level":1E+2},
                       {"start":{"numerator":1,"denominator":1},"end":{"numerator":2,"denominator":1},"level":-0.0},
                       {"start":{"numerator":2,"denominator":1},"end":{"numerator":3,"denominator":1},"level":12345678901234567890}],
           "stream_evidence":null,"audio_stream_index":3,"words":null}],
           "words":[{"id":"w","text":"t","start":{"numerator":0,"denominator":1},"end":{"numerator":1,"denominator":2},
                     "precision":"word","observations":[],"confidence":2.5e-1}] }
        """#
        let data = Data(json.utf8)
        let read = try XCTUnwrap(TranscriptDocumentReader.document(from: data))
        XCTAssertEqual(read, try general(data))
        XCTAssertEqual(read.tracks[0].id, "a/b")
        XCTAssertEqual(read.tracks[0].name, "café 🎬 \"q\" \u{08}\u{0C}\n\r\t")
        XCTAssertEqual(read.tracks[0].sessionStart, time(3, 2))
        XCTAssertEqual(read.tracks[0].streamIndex, 3)
        XCTAssertEqual(read.tracks[0].activity.map(\.level), [100, 0, 12_345_678_901_234_567_890])
        XCTAssertEqual(read.words[0].confidence, 0.25)
    }

    func testReaderPreservesLeadingByteOrderMarkInsideStringValues() throws {
        let original = #"{"schema_version":2,"clock":"presentation","approximate_clock":false,"speakers":[],"tracks":[],"words":[{"id":"w","text":"VALUE","start":{"numerator":0,"denominator":1},"end":{"numerator":1,"denominator":1},"precision":"word","observations":[]}]}"#
        for value in ["\u{FEFF}dialogue", #"\uFEFFdialogue"#, "\u{FEFF}dialogue" + #"\n"#] {
            let data = Data(original.replacingOccurrences(of: "VALUE", with: value).utf8)
            let direct = try XCTUnwrap(TranscriptDocumentReader.document(from: data))
            XCTAssertEqual(direct, try general(data))
            XCTAssertEqual(direct.words.first?.text.unicodeScalars.first?.value, 0xFEFF)
        }
    }

    func testReaderStepsAsideForAnythingElseAndTheCodecStillAnswersAsBefore() throws {
        let word = #"{"id":"w","text":"t","start":{"numerator":0,"denominator":1},"end":{"numerator":1,"denominator":1},"precision":"word","observations":[]}"#
        func document(_ words: String = "", top: String = "", version: String = "2") -> String {
            #"{"schema_version":"# + version + #","clock":"presentation","approximate_clock":false,"speakers":[],"tracks":[],"words":["#
                + words + "]" + top + "}"
        }
        XCTAssertNotNil(TranscriptDocumentReader.document(from: Data(document(word).utf8)))
        let declined: [(String, String)] = [
            ("unknown field", document(word, top: #","extra":1"#)),
            ("repeated field", document(word, top: #","job_id":"a","job_id":"b""#)),
            ("escaped field name", document(word).replacingOccurrences(of: #""id""#, with: #""\u0069d""#)),
            ("integer with a fraction", document(word, version: "2.0")),
            ("integer with an exponent", document(word, version: "2e0")),
            ("integer with a leading zero", document(word, version: "02")),
            ("another schema version", document(word, version: "1")),
            ("a later schema version", document(word, version: "3")),
            ("field names of the first schema", #"{"version":1,"clock":"presentation","approximateClock":false,"speakers":[],"tracks":[],"words":[]}"#),
            ("field name of the first schema in a word", document(word.replacingOccurrences(of: #""precision":"word""#, with: #""precision":"word","speakerID":"a""#))),
            ("negative zero", document(word).replacingOccurrences(of: #""numerator":0"#, with: #""numerator":-0"#)),
            ("zero denominator", document(word).replacingOccurrences(of: #""denominator":1}"#, with: #""denominator":0}"#)),
            ("integer past 64 bits", document(word).replacingOccurrences(of: #""numerator":1"#, with: #""numerator":9223372036854775808"#)),
            ("null where a value is required", document(word).replacingOccurrences(of: #""text":"t""#, with: #""text":null"#)),
            ("missing field", document(word).replacingOccurrences(of: #""precision":"word","#, with: "")),
            ("unknown case", document(word).replacingOccurrences(of: #""precision":"word""#, with: #""precision":"syllable""#)),
            ("number for a string", document(word).replacingOccurrences(of: #""id":"w""#, with: #""id":7"#)),
            ("lone surrogate", document(word).replacingOccurrences(of: #""text":"t""#, with: #""text":"\ud83c""#)),
            ("unknown escape", document(word).replacingOccurrences(of: #""text":"t""#, with: #""text":"\x""#)),
            ("raw control character", document(word).replacingOccurrences(of: #""text":"t""#, with: "\"text\":\"a\u{01}b\"")),
            ("trailing comma", document(word + ",")),
            ("missing comma", document(word + word)),
            ("text after the document", document(word) + " x"),
            ("byte order mark", "\u{FEFF}" + document(word)),
            ("sample-timed session", document(word, top: #","sample_rate":16000"#)),
            ("truncated", String(document(word).dropLast(3))),
            ("array at the top", "[" + document(word) + "]"),
            ("empty", "")
        ]
        var inputs = declined.map { ($0.0, Data($0.1.utf8)) }
        var malformed = Array(document(word).replacingOccurrences(of: #""text":"t""#, with: #""text":"Z""#).utf8)
        malformed[try XCTUnwrap(malformed.firstIndex(of: UInt8(ascii: "Z")))] = 0xFF
        inputs.append(("invalid UTF-8", Data(malformed)))
        for (label, data) in inputs {
            XCTAssertNil(TranscriptDocumentReader.document(from: data), label)
            let expected = Result { () -> TranscriptDocument in
                let document = try general(data)
                try document.validate()
                return document
            }
            let actual = Result { try TranscriptCodec.decode(data, format: .json) }
            switch (expected, actual) {
            case let (.success(left), .success(right)): XCTAssertEqual(left, right, label)
            case (.failure, .failure): break
            default: XCTFail("\(label): the codec and the general decoder disagree")
            }
        }
    }

    func testReaderAgreesWithTheGeneralDecoderOnGeneratedDocuments() throws {
        var generator = Generator(state: 9)
        let alphabet: [String] = ["a", "B", "7", " ", "\"", "\\", "/", "\n", "\t", "\u{0}", "\u{1B}", "é", "ß", "中", "🎞", "\u{2029}",
                                  "{", "}", "[", "]", ",", ":", "\u{FFFD}", "e\u{301}"]
        func text(_ limit: Int) -> String {
            (0..<generator.next(limit)).map { _ in alphabet[generator.next(alphabet.count)] }.joined()
        }
        func moment() -> RationalTime {
            time(Int64(generator.next(2_000_000)) - 1_000_000, Int64(1 + generator.next(96_000)))
        }
        func number() -> Double {
            switch generator.next(5) {
            case 0: return Double(generator.next(1_000)) / 1_000
            case 1: return Double(generator.next(1 << 30)) * 1e-12
            case 2:
                let fraction = (UInt64(generator.next(1 << 20)) << 32 | UInt64(generator.next(1 << 31)) << 1) & 0x000F_FFFF_FFFF_FFFF
                return Double(bitPattern: fraction | 0x3FE0_0000_0000_0000)
            case 3: return Double(generator.next(1 << 31)) * 1e15
            default: return Double(generator.next(10))
            }
        }
        for round in 0..<120 {
            let trackIDs = (0..<(1 + generator.next(3))).map { "track-\($0)-" + text(20) }
            func observation() -> TranscriptObservation {
                .init(trackID: trackIDs[generator.next(trackIDs.count)], wordID: generator.chance(2) ? nil : text(8),
                      text: generator.chance(2) ? nil : text(12), start: moment(), end: moment(),
                      evidence: generator.chance(2) ? .recognized : .inferred, basis: generator.chance(2) ? nil : text(10),
                      speakerID: generator.chance(2) ? nil : "s" + text(3), confidence: generator.chance(2) ? nil : number())
            }
            func word(_ id: Int) -> TranscriptWord {
                .init(id: "w\(id)" + text(4), text: text(16), start: moment(), end: moment(),
                      utteranceID: generator.chance(3) ? nil : "u\(id / 3)", speakerID: generator.chance(3) ? nil : "s" + text(2),
                      precision: generator.chance(4) ? .cue : .word, observations: (0..<generator.next(4)).map { _ in observation() },
                      candidateTrackIDs: generator.chance(3) ? trackIDs : nil, confidence: generator.chance(2) ? nil : number())
            }
            let tracks = trackIDs.map { id in
                TranscriptTrack(id: id, name: text(10), sourceID: generator.chance(2) ? nil : text(6),
                                streamIndex: generator.chance(2) ? nil : generator.next(9), channel: generator.chance(2) ? nil : generator.next(3),
                                origin: moment(), sessionStart: moment(),
                                coverage: [.recognized, .skipped, .failed, .coverageOnly][generator.next(4)],
                                role: [.isolatedMic, .mixedAudio, .unknown][generator.next(3)],
                                activity: (0..<generator.next(4)).map { _ in .init(start: moment(), end: moment(), level: number()) },
                                words: generator.chance(2) ? nil : (0..<generator.next(4)).map(word),
                                speakers: generator.chance(2) ? nil : [.init(id: text(4), name: text(9))],
                                streamEvidence: generator.chance(2) ? nil : .string(text(14)),
                                error: generator.chance(3) ? text(9) : nil, warning: generator.chance(3) ? text(9) : nil,
                                approximateClock: generator.chance(3) ? nil : generator.chance(2))
            }
            let document = TranscriptDocument(clock: [.presentation, .session, .group, .currentCut][generator.next(4)], tracks: tracks,
                                              speakers: (0..<generator.next(3)).map { .init(id: "s\($0)", name: text(8)) },
                                              words: (0..<generator.next(12)).map(word), approximateClock: generator.chance(2),
                                              jobID: generator.chance(2) ? nil : text(12), fingerprint: generator.chance(2) ? nil : text(12))
            let encoder = JSONEncoder()
            encoder.outputFormatting = round.isMultiple(of: 3) ? [.prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            let read = try XCTUnwrap(TranscriptDocumentReader.document(from: data), "round \(round)")
            XCTAssertEqual(read, try general(data), "round \(round)")
        }
    }
}
