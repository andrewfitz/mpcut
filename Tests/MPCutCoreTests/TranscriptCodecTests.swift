import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptCodecTests: XCTestCase {
    func testNativeDocumentFieldNamesAndVersion() throws {
        let track = TranscriptTrack(id: "mic", name: "Mic", sourceID: "recording", streamIndex: 3)
        let data = try TranscriptCodec.encode(TranscriptDocument(clock: .presentation, tracks: [track]), format: .json)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["schema_version"] as? Int, 2)
        let row = try XCTUnwrap((root["tracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["source_id"] as? String, "recording")
        XCTAssertEqual(row["audio_stream_index"] as? Int, 3)

        var mixed = row
        mixed["streamIndex"] = 4
        root["tracks"] = [mixed]
        XCTAssertThrowsError(try TranscriptCodec.decode(JSONSerialization.data(withJSONObject: root), format: .json)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_transcript")
        }
        root.removeValue(forKey: "schema_version")
        root["version"] = 1
        XCTAssertThrowsError(try TranscriptCodec.decode(JSONSerialization.data(withJSONObject: root), format: .json)) {
            XCTAssertEqual(($0 as? CutError)?.code, "unsupported_transcript_version")
        }
    }

    func testNativeRecordingKeepsWordFragmentsAndSegmentPrecision() throws {
        let json = #"""
        {
          "source":"interview.wav", "duration_seconds":9, "speaker_names":["Host"], "metadata":{},
          "segments":[
            {"start":0.001, "end":1, "speaker":0, "words":[
              {"text":"“Well,","start":0.001,"end":0.123456789123,"speaker":0},
              {"text":" yes.”","start":0.2,"end":1,"speaker":0}
            ]},
            {"start":1,"end":1.1,"text":"Another turn."}
          ]
        }
        """#
        let origin = RationalTime(numerator: 1, denominator: 3000)
        let document = try TranscriptCodec.decode(Data(json.utf8), format: .json, origin: origin)
        XCTAssertEqual(document.words.map(\.text), ["“Well,", " yes.”", "Another turn."])
        XCTAssertEqual(document.words.map(\.precision), [.word, .word, .cue])
        XCTAssertEqual(document.words[0].end, try RationalTime(parsing: "0.123456789123").adding(origin))
        XCTAssertEqual(document.words[0].observations.first?.start, document.words[0].start)
        XCTAssertEqual(document.speakers.first?.name, "Host")
        XCTAssertFalse(document.approximateClock)
        XCTAssertEqual(try TranscriptCodec.decode(TranscriptCodec.encode(document, format: .json), format: .json), document)
    }

    func testMergedSessionPartLookupSubtractsOffsetOnceAndPreservesAmbiguity() throws {
        let json = #"""
        {
          "source":"Session", "duration_seconds":80, "metadata":{"merged_from":[
            {"source":"Part 1.wav","speaker":0,"offset_seconds":0,"duration_seconds":60,"local_origin":{"numerator":0,"denominator":1}},
            {"source":"Part 2.wav","speaker":0,"offset_seconds":60,"duration_seconds":20,"local_origin":{"numerator":0,"denominator":1}},
            {"source":"Guest A.wav","speaker":1,"offset_seconds":60},
            {"source":"Guest B.wav","speaker":1,"offset_seconds":60}
          ]},
          "segments":[
            {"text":"Host text.","start":65,"end":66,"speaker":0},
            {"start":65,"end":66,"speaker":1,"words":[{"text":"Guest text.","start":65,"end":66,"speaker":1}]}
          ]
        }
        """#
        let document = try TranscriptCodec.decode(Data(json.utf8), format: .json)
        XCTAssertEqual(document.clock, .session)
        XCTAssertEqual(document.words[0].start, RationalTime(numerator: 65))
        XCTAssertEqual(document.words[0].observations.first?.trackID, "part-1")
        XCTAssertEqual(document.words[0].observations.first?.start, RationalTime(numerator: 5))
        XCTAssertEqual(document.words[1].start, RationalTime(numerator: 65))
        XCTAssertEqual(document.words[1].candidateTrackIDs, ["part-2", "part-3"])
        XCTAssertTrue(document.words[1].observations.isEmpty)

        let undeclared = json.replacingOccurrences(of: #""duration_seconds":60,"#, with: "")
            .replacingOccurrences(of: #""duration_seconds":20,"#, with: "")
        let ambiguous = try TranscriptCodec.decode(Data(undeclared.utf8), format: .json)
        let index = try TranscriptIndex(document: ambiguous)
        for word in index.readAll(space: .source) {
            XCTAssertNil(word.sourceRange)
            XCTAssertEqual(word.range.from, RationalTime(numerator: 65))
        }
        XCTAssertEqual(ambiguous.words[0].candidateTrackIDs, ["part-0", "part-1"])
        let exported = try TranscriptCodec.decode(TranscriptCodec.encode(index, space: .source, format: .json), format: .json)
        XCTAssertEqual(exported.words.map(\.projection?.clock), [.session, .session])
        XCTAssertEqual(Set(exported.words.map(\.precision)), [.cue, .word])
        XCTAssertTrue(exported.words.allSatisfy { $0.start == RationalTime(numerator: 65) && $0.observations.isEmpty })
        let reopened = try TranscriptIndex(document: exported)
        XCTAssertEqual(reopened.readAll(space: .source).map(\.range), index.readAll(space: .source).map(\.range))
    }

    func testSampleSessionPreservesSignedWordsAndExactSourceOrigin() throws {
        let data = Data(try Self.sampleSession().utf8)
        let document = try TranscriptCodec.decode(data, format: .json)
        let origin = RationalTime(numerator: 1, denominator: 48000)
        XCTAssertEqual(document.jobID, "job-1")
        XCTAssertEqual(document.fingerprint, "fingerprint-1")
        XCTAssertEqual(document.clock, .session)
        XCTAssertEqual(document.words[0].start, RationalTime(numerator: -17, denominator: 16000))
        XCTAssertEqual(document.words[0].observations.first?.start, try origin.adding(RationalTime(numerator: 1, denominator: 16000)))
        XCTAssertEqual(document.tracks[0].words?.first?.speakerID, "local-0")
        XCTAssertEqual(document.tracks[1].coverage, .skipped)
        // The provider's levels stay with the recording's analysis sidecar.
        XCTAssertTrue(try Self.sampleSession().contains(#""activity""#))
        XCTAssertTrue(document.tracks.allSatisfy(\.activity.isEmpty))
        XCTAssertEqual(document.words[0].observations.map(\.trackID), ["mic"])
        XCTAssertEqual(try TranscriptCodec.decode(TranscriptCodec.encode(document, format: .json), format: .json), document)
    }

    func testRejectsInvalidEvidenceAndUnknownNativeVersion() throws {
        var document = try TranscriptCodec.decode(Data(try Self.sampleSession().utf8), format: .json)
        let observation = document.words[0].observations[0]
        document.words[0].observations.append(
            TranscriptObservation(trackID: "room", start: observation.start, end: observation.end, evidence: .recognized)
        )
        XCTAssertThrowsError(try document.validate())
        document.words[0].observations[1].evidence = .inferred
        XCTAssertThrowsError(try document.validate())
        document.words[0].observations[1].basis = "aligned text"
        try document.validate()
        let unsupported = try Self.sampleSession().replacingOccurrences(of: #""version": 1"#, with: #""version": 2"#)
        XCTAssertThrowsError(try TranscriptCodec.decode(Data(unsupported.utf8), format: .json)) { error in
            XCTAssertEqual((error as? CutError)?.code, "unsupported_transcript_version")
        }
    }

    func testWebVTTCueIdentifiersCanMatchBlockKeywords() throws {
        let vtt = """
        WEBVTT

        STYLE
        ::cue { color: lime }

        REGION
        id:example

        STYLE
        00:00.000 --> 00:01.000
        First line.

        REGION
        00:01.000 --> 00:02.000
        Second line.
        """
        let document = try TranscriptCodec.decode(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(document.words.map(\.text), ["First line.", "Second line."])
    }

    func testSubtitleMarkupWithoutDialogueDoesNotCreateWordsOrSpeakers() throws {
        let vtt = """
        WEBVTT

        00:00.000 --> 00:01.000
        <v Alice><i> </i></v><v Bob>Hello.</v>

        00:01.000 --> 00:02.000
        <i>&nbsp;</i>
        """
        let document = try TranscriptCodec.decode(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(document.words.map(\.text), ["Hello."])
        XCTAssertEqual(document.speakers.map(\.name), ["Bob"])
    }

    func testSubtitleSpeakerOverlapsCueClockAndRepeatedCues() throws {
        let vtt = """
        WEBVTT

        NOTE Example

        greeting
        00:00.123 --> 00:01.234 align:start
        <v Alice &amp; Co><i>Hello</i></v>
        <v Bob>Well, &lt;maybe&gt;</v>

        00:02.123 --> 00:03.234
        <v Alice &amp; Co>Hello</v>
        """
        let document = try TranscriptCodec.decode(Data(vtt.utf8), format: .vtt)
        XCTAssertTrue(document.approximateClock)
        XCTAssertEqual(document.tracks.map(\.id), ["source"])
        XCTAssertTrue(document.words.allSatisfy { $0.precision == .cue && $0.observations.isEmpty })
        XCTAssertEqual(document.speakers.map(\.name), ["Alice & Co", "Bob"])
        XCTAssertEqual(document.words.map(\.text), ["Hello", "Well, <maybe>", "Hello"])
        XCTAssertEqual(document.words.map(\.start), [try RationalTime(parsing: "0.123"), try RationalTime(parsing: "0.123"),
                                                      try RationalTime(parsing: "2.123")])
        let srt = try TranscriptCodec.encode(document, format: .srt)
        let offset = RationalTime(numerator: 1, denominator: 2)
        let imported = try TranscriptCodec.decode(srt, format: .srt, origin: offset)
        XCTAssertFalse(imported.approximateClock)
        XCTAssertEqual(imported.words.map(\.start), try document.words.map { try $0.start.adding(offset) })
        XCTAssertEqual(imported.words.map(\.text), document.words.map(\.text))
        XCTAssertEqual(imported.speakers, document.speakers)
        XCTAssertEqual(try TranscriptCodec.decode(TranscriptCodec.encode(document, format: .vtt), format: .vtt).words.map(\.text),
                       document.words.map(\.text))
        let overlappingSRT = """
        1
        00:00:01,000 --> 00:00:02,000
        [Alice] First line.
        Continuation.
        [Bob] Interruption.
        """
        let labeled = try TranscriptCodec.decode(try XCTUnwrap(overlappingSRT.data(using: .utf16)), format: .srt)
        XCTAssertEqual(labeled.speakers.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(labeled.words.map(\.text), ["First line.\nContinuation.", "Interruption."])
    }

    func testCurrentCutExportKeepsAdjacentRepeatedUtterancesDistinct() throws {
        let track = TranscriptTrack(id: "source", name: "Mic")
        let document = TranscriptDocument(clock: .presentation, tracks: [track], words: [
            TranscriptWord(id: "one", text: "Hello", start: .zero, end: .init(numerator: 1), utteranceID: "u0"),
            TranscriptWord(id: "two", text: " again.", start: .init(numerator: 1), end: .init(numerator: 2), utteranceID: "u0")
        ])
        let asset = TranscriptAsset(file: "words.json", sha256: String(repeating: "a", count: 64))
        let binding = TranscriptBinding(trackID: track.id, file: "media.mov", streamIndex: 1)
        let attachment = TranscriptAttachment(id: "attachment", asset: asset, bindings: [binding])
        let project = CutProject.sequence([
            .init(id: "first", file: "media.mov", from: .zero, to: .init(numerator: 2)),
            .init(id: "repeat", file: "media.mov", from: .zero, to: .init(numerator: 2))
        ])
        let index = try TranscriptIndex(document: document, attachment: attachment, project: project)
        let json = try TranscriptCodec.encode(index, space: .currentCut, format: .json)
        let exported = try TranscriptCodec.decode(json, format: .json)
        XCTAssertEqual(exported.clock, .currentCut)
        XCTAssertEqual(exported.words.map(\.projection?.wordID), ["one", "two", "one", "two"])
        let srt = try TranscriptCodec.encode(index, space: .currentCut, format: .srt)
        let cues = try TranscriptCodec.decode(srt, format: .srt, origin: .zero).words
        XCTAssertEqual(cues.map(\.text), ["Hello again.", "Hello again."])
        XCTAssertEqual(cues.map(\.start), [.zero, .init(numerator: 2)])
        XCTAssertEqual(cues.map(\.end), [.init(numerator: 2), .init(numerator: 4)])
    }

    func testCurrentCutExportCombinesIndependentAttachmentsInOutputOrder() throws {
        let asset = TranscriptAsset(file: "words.json", sha256: String(repeating: "a", count: 64))
        let project = CutProject.sequence([
            .init(id: "first", file: "a.mov", from: .zero, to: .init(numerator: 2)),
            .init(id: "second", file: "b.mov", from: .zero, to: .init(numerator: 2))
        ])
        let indexes = try [("b", "Guest", "Later."), ("a", "Host", "Earlier.")].map { part, name, text in
            let end = RationalTime(numerator: 1)
            let binding = TranscriptBinding(trackID: "source", file: part + ".mov", streamIndex: 1)
            let attachment = TranscriptAttachment(id: part, asset: asset, bindings: [binding])
            let observation = TranscriptObservation(trackID: "source", wordID: "w0", text: text,
                                                    start: .zero, end: end, evidence: .recognized, speakerID: "speaker")
            let word = TranscriptWord(id: "word", text: text, start: .zero, end: end, utteranceID: "u0",
                                      speakerID: "speaker", observations: [observation])
            let document = TranscriptDocument(clock: .presentation, tracks: [.init(id: "source", name: name)],
                                              speakers: [.init(id: "speaker", name: name)], words: [word])
            return try TranscriptIndex(document: document, attachment: attachment, project: project)
        }
        let bytes = try TranscriptCodec.encode(indexes, space: .currentCut, format: .json)
        let exported = try TranscriptCodec.decode(bytes, format: .json)
        XCTAssertEqual(exported.words.map(\.text), ["Earlier.", "Later."])
        XCTAssertEqual(exported.words.map(\.start), [.zero, .init(numerator: 2)])
        XCTAssertEqual(exported.words.map(\.projection?.attachmentID), ["a", "b"])
        XCTAssertEqual(exported.words.map(\.projection?.wordID), ["word", "word"])
        XCTAssertEqual(exported.words.map(\.speakerID), ["1:speaker", "0:speaker"])
        XCTAssertEqual(exported.words.flatMap(\.observations).map(\.trackID), ["1:source", "0:source"])
        let captions = try TranscriptCodec.encode(indexes, space: .currentCut, format: .vtt)
        XCTAssertEqual(try TranscriptCodec.decode(captions, format: .vtt).words.map(\.text), ["Earlier.", "Later."])
    }

    private static func sampleSession() throws -> String {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/fixtures/transcripts/session-result-v1.json")
        return try String(contentsOf: fixtures, encoding: .utf8)
    }
}
