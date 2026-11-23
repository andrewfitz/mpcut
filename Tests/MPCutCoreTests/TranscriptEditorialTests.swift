import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptEditorialTests: XCTestCase {
    func testScriptReportsTheOmittedQualifierAndMissingBeat() throws {
        let index = try index([
            (0, "We will proceed only after approval."),
            (10, "We will proceed after approval."),
            (20, "We will proceed only after approval.")
        ])
        let words = index.readAll(space: .source)
        let beats = TranscriptEditorial.alignScript(
            "We will proceed only after approval.\nThe weather is sunny.", words: words)
        XCTAssertEqual(beats.map(\.status), [.ambiguous, .missing])
        XCTAssertEqual(beats[0].candidates.map(\.kind), [.exact, .approximate, .exact])
        XCTAssertEqual(beats[0].qualifiers.map(\.text), ["only"])
        XCTAssertEqual(beats[0].qualifiers[0].absentFrom, [words[1].id])
        XCTAssertEqual(TranscriptEditorial.compare("WE WILL PROCEED ONLY after approval", words: words).map(\.kind), [.exact, .approximate, .exact])
    }

    func testFillerAndRestartSuggestionsIncludeReviewableRanges() throws {
        let index = try index(["Um,", "I", "think", "we", "could", "I", "think", "we", "should"].enumerated().map {
            ($0.offset / 2, $0.element)
        })
        let suggestions = TranscriptEditorial.suggest(words: index.readAll(space: .source), fillerTerms: ["UM"])
        XCTAssertEqual(suggestions.first(where: { $0.kind == .filler })?.candidate.words.map(\.text), ["Um,"])
        let restart = try XCTUnwrap(suggestions.first(where: { $0.kind == .restart }))
        XCTAssertEqual(restart.candidate.words.map(\.text), ["I", "think", "we", "could"])
        XCTAssertEqual(restart.continuation?.words.map(\.text), ["I", "think", "we"])
    }

    func testRefreshReanchorsVerbatimWordSpanAndAppliesSparseCorrection() throws {
        let original = try index([(0, "Word"), (1, "Words")]).readAll(space: .source)
        let binding = try XCTUnwrap(original.first?.binding)
        let anchor = try TranscriptEditorial.anchor(original, binding: binding)
        let record = TranscriptAuthoredRecord(attachmentID: "test", change: .replaceText(text: "Corrected"), anchors: [anchor])
        try record.validate()
        XCTAssertEqual(try JSONDecoder().decode(TranscriptAuthoredRecord.self, from: JSONEncoder().encode(record)), record)

        let refreshed = try index([(0, "WORD"), (1, "words.")], prefix: "new").readAll(space: .source)
        let review = TranscriptEditorial.review(records: [record], sourceWords: refreshed)
        XCTAssertEqual(review[0].anchors.map(\.status), [.resolved])
        let corrected = TranscriptEditorial.overlaid(refreshed, records: [record])
        XCTAssertEqual(corrected.map(\.text), ["Corrected", ""])
        XCTAssertEqual(corrected.map(\.originalText), ["WORD", "words."])
        XCTAssertEqual(corrected.map(\.range), refreshed.map(\.range))
        XCTAssertEqual(TranscriptEditorial.compare("corrected", words: corrected).first?.words.map(\.range),
                       refreshed.map(\.range))
        let indexed = try index([(0, "WORD"), (1, "words.")], prefix: "new", records: [record])
        XCTAssertEqual(indexed.search("corrected", space: .source).items.first?.words.map(\.range),
                       refreshed.map(\.range))

        let changed = try index([(0, "Word"), (1, "different")]).readAll(space: .source)
        XCTAssertEqual(TranscriptEditorial.review(records: [record], sourceWords: changed)[0].anchors[0].status, .missing)
        XCTAssertEqual(TranscriptEditorial.overlaid(changed, records: [record]).map(\.text), changed.map(\.text))
    }

    func testRepeatedOriginalWordingAtTheSameSpanIsAmbiguous() throws {
        let original = try index([(0, "Word")]).readAll(space: .source)
        let binding = try XCTUnwrap(original.first?.binding)
        let anchor = try TranscriptEditorial.anchor(original, binding: binding)
        let refreshed = try index([(0, "Word"), (0, "Word")]).readAll(space: .source)
        let resolution = TranscriptEditorial.reanchor(anchor, in: refreshed)
        XCTAssertEqual(resolution.status, .ambiguous)
        XCTAssertEqual(resolution.candidates.count, 2)
        XCTAssertTrue(resolution.words.isEmpty)
    }

    func testSpeakerReferenceFollowsNativeIdentityChanges() throws {
        let original = try index([(0, "Yes"), (1, "Agreed")], prefix: "old", speakers: ["alice", "bob"])
        let first = try XCTUnwrap(original.readAll(space: .source).first)
        let selection = TranscriptWordSelection(firstWordID: first.wordID, space: .source, firstOccurrenceID: first.id)
        let record = try TranscriptEditorial.makeRecord(change: .assignSpeaker(speakerID: "bob"),
                                                        selections: [selection], in: original)
        XCTAssertNotNil(record.speakerReference)

        let refreshed = try index([(0, "YES"), (1, "agreed")], prefix: "new", speakers: ["a2", "b2"], records: [record])
        XCTAssertEqual(refreshed.readAll(space: .source).map(\.speakerID), ["b2", "b2"])
        XCTAssertEqual(refreshed.readAll(space: .source).map(\.originalSpeakerID), ["a2", "b2"])
        XCTAssertEqual(refreshed.authoredReview[0].speakerReference?.status, .resolved)
    }

    func testRejectingAnInferredMatchPreservesRecognizedEvidence() throws {
        let recognized = TranscriptObservation(trackID: "lav", start: .zero, end: .init(numerator: 1), evidence: .recognized)
        let inferred = TranscriptObservation(trackID: "camera", start: .zero, end: .init(numerator: 1),
                                            evidence: .inferred, basis: "matching turn")
        let word = TranscriptWord(id: "word", text: "Hello", start: .zero, end: .init(numerator: 1),
                                  observations: [recognized, inferred])
        let document = TranscriptDocument(clock: .session,
                                           tracks: [.init(id: "lav", name: "Lav"), .init(id: "camera", name: "Camera")],
                                           words: [word])
        let asset = fixtureAsset
        let attachment = TranscriptAttachment(id: "test", asset: asset, bindings: [
            .init(trackID: "lav", file: "lav.wav", streamIndex: 0),
            .init(trackID: "camera", file: "camera.mov", streamIndex: 1)
        ])
        let original = try TranscriptIndex(document: document, attachment: attachment)
        let lav = try XCTUnwrap(original.readAll(space: .source).first(where: { $0.trackID == "lav" }))
        let anchor = try TranscriptEditorial.anchor([lav], binding: XCTUnwrap(lav.binding))
        let record = TranscriptAuthoredRecord(attachmentID: "test", change: .matchOverride(trackID: "camera", accepted: false), anchors: [anchor])
        let corrected = try TranscriptIndex(document: document, attachment: attachment, records: [record])
        XCTAssertEqual(corrected.readAll(space: .source).map(\.trackID), ["lav"])
        XCTAssertEqual(corrected.readAll(space: .group).flatMap(\.observations).map(\.trackID), ["lav"])
        XCTAssertEqual(corrected.document.words.first?.observations, [recognized, inferred])
    }

    func testCorrectionRetainsInterleavedSpeakerOnTheSameStream() throws {
        let attachment = TranscriptAttachment(id: "test", asset: fixtureAsset,
                                              bindings: [.init(trackID: "mic", file: "test.mov", streamIndex: 0)])
        func index(speaker: String, interruption: String, records: [TranscriptAuthoredRecord] = [],
                   attachmentID: String = "test") throws -> TranscriptIndex {
            var scoped = attachment
            scoped.id = attachmentID
            let list: [(String, String, Int, Int, String)] = [
                ("first", "Take", 0, 3, speaker), ("interrupt", "Wait!", 1, 2, interruption), ("last", "one.", 4, 5, speaker)
            ]
            let words = list.map { id, text, start, end, speakerID in
                TranscriptWord(id: id, text: text, start: .init(numerator: Int64(start)),
                               end: .init(numerator: Int64(end)), speakerID: speakerID)
            }
            let document = TranscriptDocument(clock: .presentation, tracks: [.init(id: "mic", name: "Mic")],
                                              speakers: [speaker, interruption].map { .init(id: $0, name: $0) }, words: words)
            return try TranscriptIndex(document: document, attachment: scoped, records: records)
        }
        let original = try index(speaker: "host", interruption: "guest")
        let selection = TranscriptWordSelection(firstWordID: "first", lastWordID: "last", space: .source)
        let record = try TranscriptEditorial.makeRecord(change: .replaceText(text: "Selected take."),
                                                        selections: [selection], in: original)
        XCTAssertEqual(record.anchors[0].wordCount, 2)
        let refreshed = try index(speaker: "host-2", interruption: "guest-2", records: [record])
        XCTAssertEqual(refreshed.readAll(space: .source).map(\.text), ["Selected take.", "Wait!", ""])
        XCTAssertEqual(refreshed.authoredReview[0].anchors[0].words.map(\.wordID), ["first", "last"])
        let other = try index(speaker: "host", interruption: "guest", records: [record], attachmentID: "other")
        XCTAssertTrue(other.authoredReview.isEmpty)
        XCTAssertEqual(other.readAll(space: .source).map(\.text), ["Take", "Wait!", "one."])
    }

    func testQualifierAtUtteranceEdgeDoesNotPullAdjacentSentence() throws {
        let source = try index([(0, "This"), (1, "is"), (2, "safe"), (3, "today."),
                                (4, "Next"), (5, "question."), (10, "This"), (11, "is"), (12, "safe.")],
                               utterances: ["first", "first", "first", "first", "aside", "aside", "second", "second", "second"])
        let beat = try XCTUnwrap(TranscriptEditorial.alignScript("This is safe.", words: source.readAll(space: .source)).first)
        XCTAssertEqual(beat.candidates.map(\.kind), [.approximate, .exact])
        XCTAssertEqual(beat.candidates[0].words.map(\.text), ["This", "is", "safe", "today."])
        XCTAssertEqual(beat.candidates[0].after.first?.text, "Next")
        XCTAssertEqual(beat.qualifiers.map(\.text), ["today"])
    }

    func testGroupTakesCrossPreferredTrackChangesAndReviewEachMatch() throws {
        func observation(_ track: String, _ id: String, _ from: Int, _ type: TranscriptEvidence) -> TranscriptObservation {
            .init(trackID: track, wordID: id, start: .init(numerator: Int64(from)),
                  end: .init(numerator: Int64(from + 1)), evidence: type, basis: type == .inferred ? "co-timed" : nil)
        }
        let cameraReject = observation("camera", "inferred-1", 0, .inferred)
        let cameraConfirm = observation("camera", "inferred-2", 1, .inferred)
        let lav = observation("lav", "recorded", 0, .recognized)
        let first = TranscriptWord(id: "first", text: "Safe", start: .zero, end: .init(numerator: 1),
                                   utteranceID: "line", observations: [lav, cameraReject, cameraConfirm])
        let second = TranscriptWord(id: "second", text: "today.", start: .init(numerator: 1), end: .init(numerator: 2),
                                    utteranceID: "line", observations: [observation("camera", "recorded-2", 1, .recognized)])
        let document = TranscriptDocument(clock: .session, tracks: [.init(id: "camera", name: "Camera"), .init(id: "lav", name: "Lav")],
                                          words: [first, second])
        let attachment = TranscriptAttachment(id: "test", asset: fixtureAsset, bindings: [
            .init(trackID: "lav", file: "lav.wav", streamIndex: 0),
            .init(trackID: "camera", file: "camera.mov", streamIndex: 1)
        ])
        let original = try TranscriptIndex(document: document, attachment: attachment)
        let selected = TranscriptWordSelection(firstWordID: "first", space: .group)
        func review(_ accepted: Bool, _ item: TranscriptObservation) throws -> TranscriptAuthoredRecord {
            try TranscriptEditorial.makeRecord(change: .matchOverride(trackID: item.trackID, accepted: accepted,
                                                                       observation: .init(item)), selections: [selected], in: original)
        }
        let records = try [review(true, cameraReject), review(false, cameraReject), review(true, cameraConfirm)]
        let refreshed = try TranscriptIndex(document: document, attachment: attachment, records: records)
        let group = refreshed.readAll(space: .group)
        XCTAssertEqual(group.map(\.trackID), ["lav", "camera"])
        XCTAssertEqual(TranscriptEditorial.compare("safe today", words: group).first?.words.map(\.wordID), ["first", "second"])
        let firstReview = try XCTUnwrap(group.first?.matchReviews)
        XCTAssertEqual(firstReview.map(\.disposition), [.rejected, .confirmed])
        XCTAssertEqual(firstReview.map(\.observation.evidence), [.inferred, .inferred])
        XCTAssertEqual(group.first?.observations, [lav, cameraConfirm])

        var regenerated = document
        regenerated.words[0].observations[1].wordID = "new-inferred-1"
        regenerated.words[0].observations.removeLast()
        let changed = try TranscriptIndex(document: regenerated, attachment: attachment, records: records)
        XCTAssertEqual(changed.authoredReview.map(\.matchStatus), [.resolved, .resolved, .missing])
        XCTAssertEqual(changed.readAll(space: .group).first?.matchReviews?.first?.observation.wordID, "new-inferred-1")
        XCTAssertEqual(changed.readAll(space: .group).first?.matchReviews?.first?.disposition, .rejected)
    }

    func testScriptPageCountsNonemptyBeatsAndOnlyReturnsRequestedRows() throws {
        let source = try index([(0, "Playback."), (1, "Test."), (2, "Context.")])
        let page = TranscriptEditorial.alignScriptPage("Playback.\n---\nTest.\nContext.",
                                                       words: source.readAll(space: .source),
                                                       offset: 1, limit: 1, contextWords: 0)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.nextOffset, 2)
        XCTAssertEqual(page.items.map(\.text), ["Test."])
        XCTAssertEqual(page.items.first?.candidates.first?.before.count, 0)
        XCTAssertEqual(page.items.first?.candidates.first?.after.count, 0)
    }

    func testLongBeatStillUsesBoundedExactMatching() throws {
        let text = Array(repeating: "steady", count: 1_200).joined(separator: " ")
        let source = try index([(0, text)])
        let beat = try XCTUnwrap(TranscriptEditorial.alignScript(text, words: source.readAll(space: .source)).first)
        XCTAssertFalse(beat.approximateSearch)
        XCTAssertEqual(beat.status, .exact)
        XCTAssertEqual(beat.candidates.count, 1)
    }

    private var fixtureAsset: TranscriptAsset {
        let digest = String(repeating: "a", count: 64)
        return .init(file: "test.cut.transcripts/\(digest).json", sha256: digest)
    }

    private func index(_ lines: [(Int, String)], prefix: String = "original", speakers: [String] = [],
                       records: [TranscriptAuthoredRecord] = [], utterances: [String] = []) throws -> TranscriptIndex {
        let words = lines.enumerated().map { index, line in
            let start = RationalTime(numerator: Int64(line.0))
            return TranscriptWord(id: "\(prefix)-\(index)", text: line.1, start: start,
                                  end: RationalTime(numerator: start.numerator + 1),
                                  utteranceID: utterances.indices.contains(index) ? utterances[index] : nil,
                                  speakerID: speakers.indices.contains(index) ? speakers[index] : nil)
        }
        let document = TranscriptDocument(clock: .presentation, tracks: [.init(id: "mic", name: "Mic")],
                                          speakers: speakers.map { .init(id: $0, name: $0) }, words: words)
        let asset = fixtureAsset
        let attachment = TranscriptAttachment(id: "test", asset: asset,
                                              bindings: [.init(trackID: "mic", file: "test.mov", streamIndex: 0)])
        return try TranscriptIndex(document: document, attachment: attachment, records: records)
    }
}
