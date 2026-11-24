import Foundation
import XCTest
@testable import MPCutCore

/// A word's projection is kept out of line. These hold what callers and stored files see of
/// it: the encoded bytes, equality, and that a copy of a word is its own value.
final class TranscriptWordStorageTests: XCTestCase {
    private func time(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private var bare: TranscriptWord {
        .init(id: "w1", text: "Hello", start: time(1, 2), end: time(3, 4))
    }

    private var fullProjection: TranscriptWordProjection {
        .init(clock: .currentCut, wordID: "w/2", attachmentID: "dialogue", originalText: "there",
              originalSpeakerID: "guest", originalSourceStart: time(5, 4), originalSourceEnd: time(7, 4),
              trackID: "lav", sourceID: "camera", streamIndex: 1, routedSourceID: "mixer", routedStreamIndex: 2,
              clipID: "clip", assemblyIndex: 3, partial: true, staleMatches: false)
    }

    private var sparseProjection: TranscriptWordProjection {
        .init(clock: .group, wordID: "w3", originalText: "", partial: false, staleMatches: true)
    }

    private var full: TranscriptWord {
        .init(id: "w/2", text: "There", start: time(1), end: time(3, 2), utteranceID: "u1", speakerID: "host",
              precision: .cue, observations: [
                  .init(trackID: "lav", wordID: "a1", text: "there", start: time(5, 4), end: time(7, 4),
                        evidence: .inferred, basis: "alignment", speakerID: "host", confidence: 0.25)
              ], candidateTrackIDs: ["lav", "room"], confidence: 0.5, projection: fullProjection)
    }

    private func encoded<T: Encodable>(_ value: T, _ formatting: JSONEncoder.OutputFormatting = .sortedKeys) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        return try XCTUnwrap(String(data: encoder.encode(value), encoding: .utf8))
    }

    func testEncodedBytesOfAWordWithAndWithoutAProjection() throws {
        XCTAssertEqual(try encoded(bare), #"{"end":{"denominator":4,"numerator":3},"id":"w1","observations":[],"#
            + #""precision":"word","start":{"denominator":2,"numerator":1},"text":"Hello"}"#)

        let projection = #"{"assembly_index":3,"attachment_id":"dialogue","audio_stream_index":1,"clip_id":"clip","#
            + #""clock":"current_cut","original_source_end":{"denominator":4,"numerator":7},"#
            + #""original_source_start":{"denominator":4,"numerator":5},"original_speaker_id":"guest","#
            + #""original_text":"there","partial":true,"routed_source_id":"mixer","routed_stream_index":2,"#
            + #""source_id":"camera","stale_matches":false,"track_id":"lav","word_id":"w/2"}"#
        let word = #"{"candidate_track_ids":["lav","room"],"confidence":0.5,"end":{"denominator":2,"numerator":3},"#
            + #""id":"w/2","observations":[{"basis":"alignment","confidence":0.25,"#
            + #""end":{"denominator":4,"numerator":7},"evidence":"inferred","speaker_id":"host","#
            + #""start":{"denominator":4,"numerator":5},"text":"there","track_id":"lav","word_id":"a1"}],"#
            + #""precision":"cue","projection":"# + projection
            + #","speaker_id":"host","start":{"denominator":1,"numerator":1},"text":"There","utterance_id":"u1"}"#
        // The stored document is written with both options. Without the second a slash is escaped.
        XCTAssertEqual(try encoded(full, [.sortedKeys, .withoutEscapingSlashes]), word)
        XCTAssertEqual(try encoded(full), word.replacingOccurrences(of: "w/2", with: #"w\/2"#))
        XCTAssertEqual(try encoded(fullProjection, [.sortedKeys, .withoutEscapingSlashes]), projection)

        var sparse = bare
        sparse.projection = sparseProjection
        XCTAssertEqual(try encoded(sparse), #"{"end":{"denominator":4,"numerator":3},"id":"w1","observations":[],"#
            + #""precision":"word","projection":{"clock":"group","original_text":"","partial":false,"#
            + #""stale_matches":true,"word_id":"w3"},"start":{"denominator":2,"numerator":1},"text":"Hello"}"#)
        sparse.projection = nil
        XCTAssertEqual(try encoded(sparse), try encoded(bare))
    }

    func testEveryReaderReturnsTheProjectionThatWasWritten() throws {
        let track = TranscriptTrack(id: "lav", name: "Lav")
        let room = TranscriptTrack(id: "room", name: "Room")
        var imported = bare
        imported.id = "w3"
        imported.projection = sparseProjection
        let document = TranscriptDocument(clock: .currentCut, tracks: [track, room],
                                          speakers: [.init(id: "host", name: "Host")], words: [bare, full, imported])
        let bytes = try TranscriptCodec.encode(document, format: .json)
        let direct = try TranscriptCodec.decode(bytes, format: .json)
        XCTAssertEqual(direct, document)
        XCTAssertEqual(direct.words.map(\.projection), [nil, fullProjection, sparseProjection])
        XCTAssertEqual(try JSONDecoder().decode(TranscriptDocument.self, from: bytes), document)
        XCTAssertEqual(try TranscriptCodec.decode(TranscriptCodec.encodeStored(document), format: .json), document)
        XCTAssertEqual(try TranscriptCodec.encode(direct, format: .json), bytes)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptWord.self, from: Data(encoded(full).utf8)), full)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptWord.self, from: Data(encoded(bare).utf8)), bare)
    }

    func testWordsCompareTheirProjectionsByValue() {
        var first = bare
        var second = bare
        XCTAssertEqual(first, second)
        first.projection = fullProjection
        XCTAssertNotEqual(first, second)
        // Two words that were given equal projections separately share no storage.
        second.projection = fullProjection
        XCTAssertEqual(first, second)
        second.projection?.assemblyIndex = 4
        XCTAssertNotEqual(first, second)
        second.projection?.assemblyIndex = 3
        XCTAssertEqual(first, second)
        second.projection = nil
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, bare)
        XCTAssertEqual(TranscriptDocument(clock: .group, words: [first]), TranscriptDocument(clock: .group, words: [first]))
    }

    func testChangingACopyLeavesTheOriginalAlone() {
        let original = full
        var replaced = original
        replaced.projection = sparseProjection
        XCTAssertEqual(original.projection, fullProjection)
        XCTAssertEqual(replaced.projection, sparseProjection)

        var edited = original
        edited.projection?.clipID = "other"
        edited.projection?.partial = false
        XCTAssertEqual(original.projection, fullProjection)
        XCTAssertEqual(edited.projection?.clipID, "other")
        XCTAssertEqual(edited.projection?.partial, false)
        XCTAssertEqual(edited.projection?.wordID, fullProjection.wordID)

        var cleared = original
        cleared.projection = nil
        XCTAssertNil(cleared.projection)
        XCTAssertEqual(original.projection, fullProjection)

        // A copy held inside a collection is as separate as one held in a variable.
        var words = [original, original]
        words[1].projection?.assemblyIndex = 9
        XCTAssertEqual(words[0].projection?.assemblyIndex, 3)
        XCTAssertEqual(words[1].projection?.assemblyIndex, 9)
        XCTAssertEqual(original.projection?.assemblyIndex, 3)

        // Changes to the rest of a word keep the projection it had.
        var renamed = original
        renamed.text = "Here"
        XCTAssertEqual(renamed.projection, fullProjection)
        XCTAssertNotEqual(renamed, original)
    }

    func testWordLayout() {
        print("MEASURE layout TranscriptWord stride=\(MemoryLayout<TranscriptWord>.stride) size=\(MemoryLayout<TranscriptWord>.size) "
              + "TranscriptWordProjection? stride=\(MemoryLayout<TranscriptWordProjection?>.stride) "
              + "TranscriptOccurrence stride=\(MemoryLayout<TranscriptOccurrence>.stride)")
        // A word that held its projection inline would be larger than the projection.
        XCTAssertLessThan(MemoryLayout<TranscriptWord>.stride, MemoryLayout<TranscriptWordProjection>.stride)
    }
}
