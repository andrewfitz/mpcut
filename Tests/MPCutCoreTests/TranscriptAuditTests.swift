import Foundation
@testable import MPCutCore
import XCTest

final class TranscriptAuditTests: XCTestCase {
    func testPauseProtectionHoldsWhenTheSelectionResolvesOnAnotherMicrophone() throws {
        let master = MulticamAudioSelection(source: "mic", stream: 1)
        let multicam = MulticamProject(referenceAngle: "a", range: .init(from: time(0), to: time(10)),
                                      angles: [.init(id: "a", file: "a.mov")],
                                      audioSources: [.init(id: "mic", file: "audio.wav")], audio: .fixed(master),
                                      switches: [.init(at: time(0), angle: "a")])
        let camera = TranscriptBinding(trackID: "cam", sourceID: "a", streamIndex: 1)
        let lav = TranscriptBinding(trackID: "mic", sourceID: "mic", streamIndex: 1)
        func word(_ id: String, _ from: Int64, _ to: Int64) -> TranscriptWord {
            .init(id: id, text: id, start: time(from), end: time(to), observations: ["cam", "mic"].map {
                .init(trackID: $0, start: time(from), end: time(to), evidence: .recognized)
            })
        }
        var project = CutProject.multicam(multicam)
        let hash = String(repeating: "a", count: 64)
        let attachment = TranscriptAttachment(id: "words", asset: .init(file: "edit.cut.transcripts/\(hash).json", sha256: hash),
                                              bindings: [camera, lav])
        project.transcripts = ProjectTranscripts(attachments: [attachment])
        let document = TranscriptDocument(clock: .presentation, tracks: [camera, lav].map {
            .init(id: $0.trackID, name: $0.trackID, sourceID: $0.sourceID, streamIndex: $0.streamIndex)
        }, words: [word("a", 1, 2), word("b", 6, 7)])
        let index = try TranscriptIndex(document: document, attachment: attachment, project: project, timelineRevision: 7)

        // The pause was protected from the camera's copy of the words.
        let anchors = try ["a", "b"].map { id in
            try TranscriptEditorial.anchor(index.locate(wordID: id, space: .source).filter { $0.trackID == "cam" },
                                           binding: camera)
        }
        project.transcripts.authoring = [.init(attachmentID: "words", change: .pauseProtection(name: "Beat"), anchors: anchors)]
        try project.transcripts.advanceRevision()
        let revision = TranscriptEditRevision(timelineRevision: 7, transcriptRevision: project.transcripts.revision,
                                              resultID: hash)
        // Current Cut resolves the same words on the routed lav.
        let gap = TranscriptWordSelection(firstWordID: "a", lastWordID: "b", kind: .gap)
        let resolved = try TranscriptEditPlanner.select(gap, in: index)
        XCTAssertEqual(resolved.first.trackID, "mic")
        let request = TranscriptEditRequest(action: .tighten, selections: [gap], retainedDuration: time(2),
                                            boundaryPolicy: .exact)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(request, in: index, project: project, revision: revision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "protected_transcript_gap")
        }
    }

    func testCorrectionAcrossAJoinLeavesTheRemovedTakeAlone() throws {
        let clips = [CutSequenceClip(id: "a", file: "take.mov", from: time(0), to: time(10)),
                     CutSequenceClip(id: "b", file: "take.mov", from: time(500), to: time(510))]
        let binding = TranscriptBinding(trackID: "mic", file: "take.mov", streamIndex: 0, sequenceClockOrigin: .zero)
        func word(_ id: String, _ from: Int64) -> TranscriptWord {
            .init(id: id, text: id, start: time(from), end: time(from + 1), observations: [
                .init(trackID: "mic", start: time(from), end: time(from + 1), evidence: .recognized)
            ])
        }
        var project = CutProject.sequence(clips)
        let hash = String(repeating: "c", count: 64)
        let attachment = TranscriptAttachment(id: "words", asset: .init(file: "edit.cut.transcripts/\(hash).json", sha256: hash),
                                              bindings: [binding])
        project.transcripts = ProjectTranscripts(attachments: [attachment])
        let document = TranscriptDocument(clock: .presentation, tracks: [.init(id: "mic", name: "mic", streamIndex: 0)],
                                          words: [word("alpha", 9), word("mid", 100), word("omega", 500)])
        let index = try TranscriptIndex(document: document, attachment: attachment, project: project, timelineRevision: 3)
        XCTAssertEqual(index.readAll(space: .currentCut).map(\.wordID), ["alpha", "omega"])
        // The cut removed "mid". A correction over the join must not reach it.
        let acrossJoin = TranscriptWordSelection(firstWordID: "alpha", lastWordID: "omega")
        XCTAssertThrowsError(try TranscriptEditorial.makeRecord(change: .replaceText(text: "x"), selections: [acrossJoin], in: index)) {
            XCTAssertEqual(($0 as? CutError)?.code, "unanchored_transcript_selection")
        }
        // Each retained passage can still be corrected, and Source can address the whole take.
        XCTAssertNoThrow(try TranscriptEditorial.makeRecord(change: .replaceText(text: "x"),
                                                            selections: [.init(firstWordID: "alpha")], in: index))
        let wholeTake = TranscriptWordSelection(firstWordID: "alpha", lastWordID: "omega", space: .source)
        let record = try TranscriptEditorial.makeRecord(change: .replaceText(text: "x"), selections: [wholeTake], in: index)
        XCTAssertEqual(record.anchors.first?.wordCount, 3)
    }

    func testTextCorrectionShowsOnEveryMicrophoneInSource() throws {
        let multicam = MulticamProject(referenceAngle: "a", range: .init(from: time(0), to: time(10)),
                                      angles: [.init(id: "a", file: "a.mov")],
                                      audioSources: [.init(id: "mic", file: "audio.wav")],
                                      audio: .fixed(.init(source: "mic", stream: 1)),
                                      switches: [.init(at: time(0), angle: "a")])
        let camera = TranscriptBinding(trackID: "cam", sourceID: "a", streamIndex: 1)
        let lav = TranscriptBinding(trackID: "mic", sourceID: "mic", streamIndex: 1)
        var project = CutProject.multicam(multicam)
        let hash = String(repeating: "d", count: 64)
        let attachment = TranscriptAttachment(id: "words", asset: .init(file: "edit.cut.transcripts/\(hash).json", sha256: hash),
                                              bindings: [camera, lav])
        project.transcripts = ProjectTranscripts(attachments: [attachment])
        let heard = TranscriptWord(id: "w", text: "teh", start: time(1), end: time(2), observations: ["cam", "mic"].map {
            .init(trackID: $0, start: time(1), end: time(2), evidence: .recognized)
        })
        let document = TranscriptDocument(clock: .presentation, tracks: [camera, lav].map {
            .init(id: $0.trackID, name: $0.trackID, sourceID: $0.sourceID, streamIndex: $0.streamIndex)
        }, words: [heard])
        let plain = try TranscriptIndex(document: document, attachment: attachment, project: project, timelineRevision: 1)
        let onLav = try XCTUnwrap(plain.readAll(space: .source).first { $0.trackID == "mic" })
        let selection = TranscriptWordSelection(firstWordID: "w", space: .source, firstOccurrenceID: onLav.id)
        let record = try TranscriptEditorial.makeRecord(change: .replaceText(text: "the"), selections: [selection], in: plain)
        let corrected = try TranscriptIndex(document: document, attachment: attachment, project: project,
                                            timelineRevision: 1, records: [record])
        for track in ["mic", "cam"] {
            XCTAssertEqual(corrected.readAll(space: .source, filter: .init(trackID: track)).map(\.text), ["the"], track)
            XCTAssertEqual(corrected.search("the", space: .source, filter: .init(trackID: track)).total, 1, track)
        }
        // The conversation still shows the word once.
        XCTAssertEqual(corrected.readAll(space: .group).map(\.text), ["the"])
    }

    func testSubRipImportDropsStylingAndAcceptsCommonTimestamps() throws {
        let captions = """
        1
        0:00:01.000 --> 0:00:02.500
        <i>Hello</i> <font color="#ffffff">world</font>

        2
        00:00:03,000 --> 00:00:03,000
        {\\an8}Instant

        3
        00:00:04,000 --> 00:00:05,000

        4
        00:00:06,000 --> 00:00:07,000
        Last line
        """
        let document = try TranscriptCodec.decode(Data(captions.utf8), format: .srt)
        XCTAssertEqual(document.words.map(\.text), ["Hello world", "Instant", "Last line"])
        XCTAssertEqual(document.words[0].start, .init(numerator: 1))
        XCTAssertEqual(document.words[0].end, .init(numerator: 5, denominator: 2))
        XCTAssertEqual(try document.words[1].end.subtracting(document.words[1].start), .init(numerator: 1, denominator: 1000))
        let index = try TranscriptIndex(document: document)
        XCTAssertEqual(index.search("hello world", space: .source).total, 1)
        // A cue that ends before it starts is still a damaged file.
        XCTAssertThrowsError(try TranscriptCodec.decode(Data("1\n00:00:02,000 --> 00:00:01,000\nBack\n".utf8), format: .srt))
    }

    func testSearchFindsACompoundWrittenAsOneWordOrTwo() throws {
        let track = TranscriptTrack(id: "mic", name: "mic")
        func words(_ texts: [String]) -> [TranscriptWord] {
            texts.enumerated().map { offset, text in
                .init(id: "w\(offset)", text: text, start: time(Int64(offset)), end: time(Int64(offset) + 1),
                      candidateTrackIDs: ["mic"])
            }
        }
        let spoken = try TranscriptIndex(document: .init(clock: .presentation, tracks: [track],
                                                         words: words(["I", "brought", "a", "range", "finder", "today"])))
        XCTAssertEqual(spoken.search("a rangefinder today", space: .source).items.first?.words.map(\.wordID),
                       ["w2", "w3", "w4", "w5"])
        let written = try TranscriptIndex(document: .init(clock: .presentation, tracks: [track],
                                                          words: words(["three", "weekends", "mostly", "waiting"])))
        XCTAssertEqual(written.search("week ends mostly", space: .source).items.first?.words.map(\.wordID), ["w1", "w2"])
        // An exact match is never widened, and unrelated words stay unmatched.
        XCTAssertEqual(spoken.search("range finder", space: .source).total, 1)
        XCTAssertEqual(spoken.search("rangefinders", space: .source).total, 0)
        XCTAssertEqual(written.search("week day", space: .source).total, 0)
        XCTAssertEqual(TranscriptIndex.compoundVariants(["a", "rangefinder"], known: { ["range", "finder"].contains($0) }),
                       [["a", "range", "finder"]])
    }

    func testGroupSearchFollowsAPhraseThroughCrosstalkUnderOneSpeakerLabel() throws {
        let multicam = MulticamProject(referenceAngle: "a", range: .init(from: time(0), to: time(10)),
                                      angles: [.init(id: "a", file: "a.mov")],
                                      audioSources: [.init(id: "mic", file: "audio.wav")],
                                      audio: .fixed(.init(source: "mic", stream: 1)),
                                      switches: [.init(at: time(0), angle: "a")])
        let camera = TranscriptBinding(trackID: "cam", sourceID: "a", streamIndex: 1)
        let lav = TranscriptBinding(trackID: "mic", sourceID: "mic", streamIndex: 1)
        // A diarizer gave the guest and an interjection from behind the camera one label.
        let spoken: [(String, String, Int64)] = [("the", "mic", 0), ("shutter", "mic", 2), ("sorry", "cam", 3),
                                                 ("you", "mic", 4), ("one", "cam", 5), ("know", "mic", 6),
                                                 ("moment", "cam", 7), ("because", "mic", 8), ("please", "cam", 9)]
        let words = spoken.enumerated().map { number, item in
            let (start, end) = (RationalTime(numerator: item.2, denominator: 2), RationalTime(numerator: item.2 + 1, denominator: 2))
            return TranscriptWord(id: "w\(number)", text: item.0, start: start, end: end, speakerID: "s1", observations: [
                .init(trackID: item.1, start: start, end: end, evidence: .recognized)
            ])
        }
        var project = CutProject.multicam(multicam)
        let hash = String(repeating: "b", count: 64)
        let attachment = TranscriptAttachment(id: "words", asset: .init(file: "edit.cut.transcripts/\(hash).json", sha256: hash),
                                              bindings: [camera, lav])
        project.transcripts = ProjectTranscripts(attachments: [attachment])
        let document = TranscriptDocument(clock: .presentation, tracks: [camera, lav].map {
            .init(id: $0.trackID, name: $0.trackID, sourceID: $0.sourceID, streamIndex: $0.streamIndex)
        }, speakers: [.init(id: "s1", name: "Guest")], words: words)
        let index = try TranscriptIndex(document: document, attachment: attachment, project: project, timelineRevision: 1)
        XCTAssertEqual(index.search("sorry one moment please", space: .group).items.first?.words.map(\.wordID),
                       ["w2", "w4", "w6", "w8"])
        XCTAssertEqual(index.search("you know because", space: .group).items.first?.words.map(\.wordID), ["w3", "w5", "w7"])
        let prepared = try index.prepareSearch("you know because", space: .group)
        let match = try XCTUnwrap(prepared.page().items.first)
        XCTAssertEqual(match.words.map(\.wordID), ["w3", "w5", "w7"])
        XCTAssertTrue(match.before.isEmpty && match.after.isEmpty)
        // Words in spoken order still match as before, and a phrase nobody said does not.
        XCTAssertEqual(index.search("the shutter", space: .group).total, 1)
        XCTAssertEqual(index.search("sorry you one", space: .group).total, 1)
        XCTAssertEqual(index.search("sorry know please", space: .group).total, 0)
        XCTAssertEqual(index.search("moment one", space: .group).total, 0)
    }

    func testRequestJSONAcceptsTimeStringsAndCurrentCutInNestedEdits() throws {
        let selection: [String: Any] = ["first_word_id": "word-0", "leading_padding": "1/4", "space": "current_cut"]
        let normalized = try TranscriptRequestJSON.normalize(selection, key: "selection")
        let decoded = try JSONDecoder().decode(TranscriptWordSelection.self,
                                               from: JSONSerialization.data(withJSONObject: normalized))
        XCTAssertEqual(decoded.leadingPadding, .init(numerator: 1, denominator: 4))
        XCTAssertEqual(decoded.space, .currentCut)

        let bindings: [[String: Any]] = [["track_id": "t", "file": "a.mov", "audio_stream_index": 0]]
        let bound = try JSONDecoder().decode([TranscriptBinding].self, from: JSONSerialization.data(
            withJSONObject: TranscriptRequestJSON.normalize(bindings, key: "bindings")))
        XCTAssertEqual(bound.first?.offset, .zero)

        let request: [String: Any] = ["action": "tighten", "retained_duration": "0.5",
                                      "selections": [["first_word_id": "a", "last_word_id": "b", "kind": "gap", "space": "current_cut"]]]
        let edit = try JSONDecoder().decode(TranscriptEditRequest.self, from: JSONSerialization.data(
            withJSONObject: TranscriptRequestJSON.normalize(request, key: "request")))
        XCTAssertEqual(edit.retainedDuration, .init(numerator: 1, denominator: 2))
        XCTAssertEqual(edit.selections.first?.space, .currentCut)
        XCTAssertThrowsError(try TranscriptRequestJSON.normalize(["leading_padding": "soon"], key: "selection"))

        // A match override names the observation it reviews by its range, written as time strings.
        let override: [String: Any] = ["match_override": ["track_id": "cam", "accepted": false,
                                                         "observation": ["range": ["from": "684/25", "to": "686/25"], "word_id": "w9"]]]
        let change = try JSONDecoder().decode(TranscriptAuthoredChange.self, from: JSONSerialization.data(
            withJSONObject: TranscriptRequestJSON.normalize(override, key: "change")))
        guard case .matchOverride(let track, let accepted, let observation) = change else { return XCTFail("Expected a match override") }
        XCTAssertEqual(track, "cam")
        XCTAssertFalse(accepted)
        let mixed = Data(#"{"assign_speaker":{"speaker_id":"a","speakerID":"b"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptAuthoredChange.self, from: mixed)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_transcript_authoring")
        }
        XCTAssertEqual(observation?.range, .init(from: .init(numerator: 684, denominator: 25), to: .init(numerator: 686, denominator: 25)))
    }

    func testDecodedStoreEntryIsReusedUntilTheFileChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-decoded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("talk.cut")
        let track = TranscriptTrack(id: "mic", name: "mic")
        let document = TranscriptDocument(clock: .presentation, tracks: [track], words: [
            .init(id: "w0", text: "hello", start: time(0), end: time(1), candidateTrackIDs: ["mic"])
        ])
        let asset = try TranscriptStore.put(TranscriptCodec.encode(document, format: .json), relativeTo: project)
        let first = try TranscriptStore.decoded(asset, relativeTo: project)
        XCTAssertEqual(first.words.map(\.text), ["hello"])
        XCTAssertEqual(try TranscriptStore.decoded(asset, relativeTo: project).words.map(\.id), ["w0"])

        // Different bytes under the same name fail the digest exactly as an uncached read does.
        let file = try XCTUnwrap(TranscriptStore.assetLocation(asset, relativeTo: project))
        try FileManager.default.removeItem(at: file)
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try TranscriptStore.decoded(asset, relativeTo: project)) {
            XCTAssertEqual(($0 as? CutError)?.code, "damaged_transcript")
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try TranscriptStore.decoded(asset, relativeTo: project)) {
            XCTAssertEqual(($0 as? CutError)?.code, "missing_transcript")
        }
    }

    func testSavingARenamedProjectLeavesTheStoreACopyStillReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original.cut")
        let copy = root.appendingPathComponent("Copy.cut")
        let renamed = root.appendingPathComponent("Renamed.cut")
        let data = Data("dialogue".utf8)
        let asset = try TranscriptStore.put(data, relativeTo: original)
        var project = CutProject.sequence([])
        project.transcripts.attachments = [.init(id: "dialogue", asset: asset, bindings: [])]
        try project.save(to: original)
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.moveItem(at: original, to: renamed)
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: copy), data)

        project.transcripts = try TranscriptStore.copy(in: project.transcripts, from: renamed, to: renamed)
        try project.save(to: renamed)
        let saved = try XCTUnwrap(CutProject.load(from: renamed).transcripts.attachments.first?.asset)
        XCTAssertEqual(try TranscriptStore.read(saved, relativeTo: renamed), data)
        // The duplicate still names the former store, and nothing else holds its transcript.
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: copy), data)
    }

    func testProjectRenamedOnlyInLetterCaseKeepsItsTranscripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = root.appendingPathComponent("Probe")
        try Data().write(to: probe)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("probe").path) else {
            throw XCTSkip("This volume distinguishes letter case.")
        }
        let original = root.appendingPathComponent("Talk.cut")
        let data = Data("dialogue".utf8)
        let asset = try TranscriptStore.put(data, relativeTo: original)
        var project = CutProject.sequence([])
        project.transcripts.attachments = [.init(id: "dialogue", asset: asset, bindings: [])]
        try project.save(to: original)
        XCTAssertEqual(rename(original.path, root.path + "/talk.cut"), 0)
        let renamed = root.appendingPathComponent("talk.cut")
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: renamed), data)
        XCTAssertNoThrow(try TranscriptStore.put(Data("new result".utf8), relativeTo: renamed))
        project.transcripts = try TranscriptStore.copy(in: project.transcripts, from: renamed, to: renamed)
        XCTAssertNil(project.transcripts.attachments.first?.asset.unavailable)
        try project.save(to: renamed)
        let saved = try XCTUnwrap(CutProject.load(from: renamed).transcripts.attachments.first?.asset)
        XCTAssertEqual(try TranscriptStore.read(saved, relativeTo: renamed), data)
    }

    func testListFileErrorCodesAreSingleTokens() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/mpcut-\(UUID().uuidString).json")
        XCTAssertThrowsError(try ClipEditCSV.readListData(missing, kind: "Transcript plan")) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_plan_read_failed")
        }
    }

    func testPhraseSearchReadsThroughAWordABladeCutSplit() throws {
        let track = TranscriptTrack(id: "mic", name: "Mic")
        func half(_ seconds: Int64) -> RationalTime { .init(numerator: seconds, denominator: 2) }
        let document = TranscriptDocument(clock: .presentation, tracks: [track], words: [
            .init(id: "say", text: "Say", start: time(1), end: time(2)),
            .init(id: "hello", text: "hello", start: time(2), end: time(3)),
            .init(id: "world", text: "world", start: time(3), end: time(4))
        ])
        let hash = String(repeating: "a", count: 64)
        let binding = TranscriptBinding(trackID: track.id, file: "mic.wav", streamIndex: 1, sequenceStreamOrdinal: 0)
        let attachment = TranscriptAttachment(id: "words", asset: .init(file: "edit.cut.transcripts/\(hash).json", sha256: hash),
                                              bindings: [binding])
        // The blade lands inside "hello" and removes nothing.
        let bladed = CutProject.sequence([
            .init(id: "clip-1", file: "mic.wav", from: time(0), to: half(5)),
            .init(id: "clip-2", file: "mic.wav", from: half(5), to: time(5))
        ])
        let index = try TranscriptIndex(document: document, attachment: attachment, project: bladed)
        XCTAssertEqual(index.read(space: .currentCut).items.map(\.wordID), ["say", "hello", "hello", "world"])
        let found = index.search("say hello world", space: .currentCut)
        XCTAssertEqual(found.total, 1)
        XCTAssertEqual(found.items.first?.words.map(\.clipID), ["clip-1", "clip-1", "clip-2", "clip-2"])
        XCTAssertEqual(index.search("hello", space: .currentCut).total, 1)
        XCTAssertEqual(index.search("hello hello", space: .currentCut).total, 0)

        // A trim that drops the middle of the word leaves two fragments, not one reading of it.
        let trimmed = CutProject.sequence([
            .init(id: "clip-1", file: "mic.wav", from: time(0), to: half(5)),
            .init(id: "clip-2", file: "mic.wav", from: .init(numerator: 11, denominator: 4), to: time(5))
        ])
        let gapped = try TranscriptIndex(document: document, attachment: attachment, project: trimmed)
        XCTAssertEqual(gapped.search("say hello world", space: .currentCut).total, 0)
        XCTAssertEqual(gapped.search("hello hello", space: .currentCut).total, 1)
    }

    func testHistoryNamesASavedSelectAndAProtectedPause() {
        XCTAssertEqual(TranscriptAuthoredChange.namedSelect(name: "Greeting").historyAction, "Name Transcript Select")
        XCTAssertEqual(TranscriptAuthoredChange.pauseProtection(name: "Beat").historyAction, "Protect Transcript Pause")
        XCTAssertEqual(TranscriptAuthoredChange.replaceText(text: "howdy").historyAction, "Correct Transcript")
        XCTAssertEqual(TranscriptAuthoredChange.renameSpeaker(speakerID: "a", name: "Guest").historyAction, "Correct Transcript")
    }

    /// A caller that lost the reply to a correction sends it again. Naming the record makes the
    /// second request find what the first one saved.
    func testCommandLineCorrectionNamedByRecordIDCanBeSentAgain() throws {
        var products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        if products.lastPathComponent == "PlugIns" {
            products = products.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        let cli = products.appendingPathComponent("mpcut")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw XCTSkip("The mpcut command is not built beside the tests.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("talk.cut")
        try Data().write(to: folder.appendingPathComponent("mic.wav"))
        let document = TranscriptDocument(clock: .presentation, tracks: [.init(id: "mic", name: "Mic")], words: [
            .init(id: "say", text: "Say", start: time(1), end: time(2)),
            .init(id: "hello", text: "hello", start: time(2), end: time(3)),
            .init(id: "world", text: "world", start: time(3), end: time(4))
        ])
        let asset = try TranscriptStore.put(TranscriptCodec.encode(document, format: .json), relativeTo: project)
        var saved = CutProject.sequence([.init(id: "clip", file: "mic.wav", from: time(0), to: time(5))])
        saved.transcripts.attachments = [.init(id: "words", asset: asset, bindings: [
            .init(trackID: "mic", file: "mic.wav", streamIndex: 0, sequenceStreamOrdinal: 0)
        ])]
        try saved.save(to: project)

        func correct(_ fields: [String: Any]) throws -> [String: Any] {
            let request = fields.merging(["project_path": project.path, "in_place": true]) { first, _ in first }
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = cli
            process.arguments = ["transcript", "words", "correct", "--json", "--stdin", "--no-sidecar"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request))
            try input.fileHandleForWriting.close()
            let reply = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: reply, as: UTF8.self))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        }
        func undoSteps() throws -> [String] {
            try CutProject.loadEditorDocument(from: project, limit: CutProject.maximumHistorySteps).undo.map(\.action)
        }

        let wording: [String: Any] = ["record_id": "fix-1", "first_word_id": "hello",
                                      "change": ["replace_text": ["text": "howdy"]]]
        XCTAssertEqual(try correct(wording)["history_action"] as? String, "Correct Transcript")
        let once = try Data(contentsOf: project)
        XCTAssertNil(try correct(wording)["history_action"])
        XCTAssertEqual(try Data(contentsOf: project), once)
        XCTAssertEqual(try CutProject.load(from: project).transcripts.authoring.map(\.id), ["fix-1"])
        XCTAssertEqual(try undoSteps(), ["Correct Transcript"])

        let select: [String: Any] = ["record_id": "select-1", "first_word_id": "say", "last_word_id": "world",
                                     "change": ["named_select": ["name": "Greeting"]]]
        XCTAssertEqual(try correct(select)["history_action"] as? String, "Name Transcript Select")
        XCTAssertEqual(try undoSteps(), ["Correct Transcript", "Name Transcript Select"])
    }

    private func spoken(_ lines: [(speaker: String, utterance: String, text: String, from: Int64, to: Int64)]) -> TranscriptDocument {
        let words = lines.enumerated().map { number, line in
            TranscriptWord(id: "w\(number)", text: " " + line.text, start: .init(numerator: line.from, denominator: 100),
                           end: .init(numerator: line.to, denominator: 100), utteranceID: line.utterance, speakerID: line.speaker)
        }.sorted { $0.start < $1.start }
        return TranscriptDocument(clock: .presentation, speakers: [.init(id: "guest", name: "Guest"), .init(id: "crew", name: "Crew")],
                                  words: words)
    }

    func testSpeakersTalkingOverEachOtherExportAsWholeLines() throws {
        // Each speaker's utterance keeps its ID while the other talks across it.
        let document = spoken([
            ("guest", "g1", "You", 0, 40), ("guest", "g1", "know,", 50, 90), ("guest", "g1", "because", 100, 140),
            ("guest", "g1", "dust", 150, 190), ("guest", "g1", "collects.", 200, 240),
            ("crew", "c1", "Sorry,", 30, 60), ("crew", "c1", "one", 70, 110), ("crew", "c1", "moment.", 120, 160)
        ])
        let text = String(decoding: try TranscriptCodec.encode(document, format: .text), as: UTF8.self)
        XCTAssertEqual(text, "Transcript (Source presentation)\n[Guest] You know, because dust collects.\n[Crew] Sorry, one moment.\n")
        let subtitles = String(decoding: try TranscriptCodec.encode(document, format: .srt), as: UTF8.self)
        XCTAssertEqual(subtitles, """
        1
        00:00:00,000 --> 00:00:02,400
        [Guest] You know, because dust collects.

        2
        00:00:00,300 --> 00:00:01,600
        [Crew] Sorry, one moment.


        """)
    }

    func testSourceExportKeepsEachRecordingsCopyOfAnUtteranceTogether() throws {
        // Two microphones hear the same sentence, so Source lists every word twice.
        let tracks = ["lav", "boom"].map { TranscriptTrack(id: $0, name: $0) }
        let words = ["Mind", "the", "gap."].enumerated().map { number, text in
            let start = RationalTime(numerator: Int64(number), denominator: 2)
            let end = RationalTime(numerator: Int64(number) + 1, denominator: 2)
            return TranscriptWord(id: "w\(number)", text: " " + text, start: start, end: end, utteranceID: "u1", speakerID: "guest",
                                  observations: tracks.map { .init(trackID: $0.id, start: start, end: end, evidence: .recognized) })
        }
        let document = TranscriptDocument(clock: .presentation, tracks: tracks, speakers: [.init(id: "guest", name: "Guest")],
                                          words: words)
        let index = try TranscriptIndex(document: document)
        let text = String(decoding: try TranscriptCodec.encode(index, space: .source, format: .text), as: UTF8.self)
        XCTAssertEqual(text.split(separator: "\n").dropFirst().map(String.init), ["[Guest] Mind the gap.", "[Guest] Mind the gap."])
    }

    func testFragmentsOfATalkedOverSentenceExportAsOneLine() throws {
        // A recognizer that starts a new utterance at every change of speaker.
        let document = spoken([
            ("guest", "u1", "Always", 0, 20), ("guest", "u1", "the", 20, 30), ("guest", "u1", "shutter.", 30, 50),
            ("crew", "u2", "Sorry,", 55, 90), ("guest", "u3", "You", 80, 100), ("crew", "u4", "one", 95, 130),
            ("guest", "u5", "know,", 125, 160), ("crew", "u6", "moment.", 150, 190),
            ("guest", "u7", "because", 185, 220), ("guest", "u7", "it", 220, 230), ("guest", "u7", "sticks.", 230, 260)
        ])
        let text = String(decoding: try TranscriptCodec.encode(document, format: .text), as: UTF8.self)
        XCTAssertEqual(text.split(separator: "\n").dropFirst().map(String.init),
                       ["[Guest] Always the shutter.", "[Crew] Sorry, one moment.", "[Guest] You know, because it sticks."])
    }

    func testAQuickExchangeWithoutOverlapKeepsEachUtteranceOnItsOwnLine() throws {
        let document = spoken([
            ("guest", "u1", "so", 0, 20), ("guest", "u1", "it", 20, 30), ("guest", "u1", "works", 30, 60),
            ("crew", "u2", "yes", 70, 90), ("guest", "u3", "great", 100, 130), ("guest", "u4", "thanks", 135, 160)
        ])
        let text = String(decoding: try TranscriptCodec.encode(document, format: .text), as: UTF8.self)
        XCTAssertEqual(text.split(separator: "\n").dropFirst().map(String.init),
                       ["[Guest] so it works", "[Crew] yes", "[Guest] great", "[Guest] thanks"])
    }

    /// Set MPCUT_TRANSCRIPT_BENCH=1 to print what an open editor pays to show a stored
    /// result again after an edit: a verified read and decode before, a stat after.
    func testReopeningAStoredResultBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_BENCH"] == "1" else {
            throw XCTSkip("Set MPCUT_TRANSCRIPT_BENCH=1 to measure.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("talk.cut")
        // Two hours at four words a second, each heard on three tracks.
        let tracks = ["lav", "wide", "close"].map { TranscriptTrack(id: $0, name: $0) }
        let vocabulary = ["the", "lantern", "glows", "only", "when", "moon", "rises", "over", "harbour", "tonight"]
        let words: [TranscriptWord] = (0..<28_800).map { number in
            let start = RationalTime(numerator: Int64(number), denominator: 4)
            let end = RationalTime(numerator: Int64(number) + 1, denominator: 4)
            return .init(id: "w\(number)", text: " " + vocabulary[number % vocabulary.count], start: start, end: end,
                         utteranceID: "u\(number / 12)", observations: tracks.map {
                             .init(trackID: $0.id, start: start, end: end, evidence: .recognized)
                         })
        }
        let document = TranscriptDocument(clock: .presentation, tracks: tracks, words: words)
        let asset = try TranscriptStore.put(TranscriptCodec.encode(document, format: .json), relativeTo: project)
        func median(_ work: () throws -> Void) rethrows -> Double {
            var samples: [Double] = []
            for _ in 0..<7 {
                let start = DispatchTime.now().uptimeNanoseconds
                try work()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return samples.sorted()[3]
        }
        let uncached = try median {
            _ = try TranscriptCodec.decode(TranscriptStore.read(asset, relativeTo: project), format: .json)
        }
        _ = try TranscriptStore.decoded(asset, relativeTo: project)
        let cached = try median { _ = try TranscriptStore.decoded(asset, relativeTo: project) }
        let decoded = try TranscriptStore.decoded(asset, relativeTo: project)
        let indexing = try median { _ = try TranscriptIndex(document: decoded) }
        let bytes = try TranscriptStore.read(asset, relativeTo: project).count
        print(String(format: "TRANSCRIPT_BENCH words=28800 observations=86400 bytes=%d readAndDecodeMs=%.1f cachedMs=%.3f indexMs=%.1f",
                     bytes, uncached, cached, indexing))
        XCTAssertLessThan(cached, uncached)
    }

    private func time(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
}
