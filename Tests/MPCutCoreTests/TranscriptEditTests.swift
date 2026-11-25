import Foundation
import MPCutCore
import XCTest

final class TranscriptEditTests: XCTestCase {
    func testPhraseIncludesBothEndpointsWhenTheFirstWordEndsLater() throws {
        let clip = CutSequenceClip(id: "clip", file: "take.mov", from: .zero, to: time(10))
        let (_, index, _) = try fixture(.sequence([clip]), tracks: [binding("mic", file: clip.file)],
                                         words: [word("first", 1, 6, track: "mic"), word("last", 3, 4, track: "mic")])
        let selection = TranscriptWordSelection(firstWordID: "first", lastWordID: "last", trailingPadding: time(1))

        let resolved = try TranscriptEditPlanner.select(selection, in: index)

        XCTAssertEqual(resolved.range, .init(from: time(1), to: time(7)))
    }

    func testReaderExpansionUsesOccurrenceAndRespectsSentenceAndTurnBoundaries() throws {
        let clips = ["a", "b"].map { CutSequenceClip(id: $0, file: "take.mov", from: .zero, to: time(10)) }
        let (_, index, _) = try fixture(.sequence(clips), tracks: [binding("mic", file: "take.mov")], words: [
            word("Before.", 0, 1, track: "mic"), word("What", 1, 2, track: "mic"), word("happened?", 2, 3, track: "mic"),
            word("It", 3, 4, track: "mic"), word("worked.", 4, 5, track: "mic"), word("After.", 5, 6, track: "mic")
        ])
        let hit = try XCTUnwrap(index.locate(wordID: "worked.", space: .currentCut).last)
        let request = TranscriptWordSelection(firstWordID: hit.wordID, firstOccurrenceID: hit.id,
                                              trailingPadding: time(1))
        let sentence = try TranscriptEditPlanner.select(request, expansion: .sentence, in: index)
        XCTAssertEqual(sentence.first.wordID, "It")
        XCTAssertEqual(sentence.first.clipID, "b")
        XCTAssertEqual(sentence.last.id, hit.id)
        XCTAssertEqual(sentence.range, .init(from: time(13), to: time(16)))

        let turn = try TranscriptEditPlanner.select(request, expansion: .speakerTurn, in: index)
        XCTAssertEqual(turn.first.wordID, "Before.")
        XCTAssertEqual(turn.first.clipID, "b")
        XCTAssertEqual(turn.last.wordID, "After.")

        let answer = try TranscriptEditPlanner.select(request, expansion: .precedingQuestion, in: index)
        XCTAssertEqual(answer.first.wordID, "What")
        XCTAssertEqual(answer.first.clipID, "b")
        XCTAssertEqual(answer.last.id, hit.id)
    }

    func testRepeatedWordRequiresOccurrenceAndDeleteIsAtomic() throws {
        let clips = ["a", "b"].map { CutSequenceClip(id: $0, file: "take.mov", from: time(0), to: time(10)) }
        let (project, index, revision) = try fixture(.sequence(clips), tracks: [binding("mic", file: "take.mov")],
                                                    words: [word("line", 2, 3, track: "mic")])
        let locations = index.locate(wordID: "line", space: .currentCut)
        XCTAssertEqual(locations.map(\.clipID), ["a", "b"])
        XCTAssertThrowsError(try TranscriptEditPlanner.select(.init(firstWordID: "line"), in: index)) {
            XCTAssertEqual(($0 as? CutError)?.code, "ambiguous_transcript_occurrence")
        }
        let selection = TranscriptWordSelection(firstWordID: "line", firstOccurrenceID: locations[1].id)
        let plan = try TranscriptEditPlanner.plan(.init(action: .delete, selections: [selection], boundaryPolicy: .exact),
                                                  in: index, project: project, revision: revision)
        let commit = try plan.apply(to: project, revision: revision)
        XCTAssertEqual(commit.undo?.project, project)
        XCTAssertEqual(commit.project.sequenceClips?.map(\.from), [time(0), time(0), time(3)])
        XCTAssertEqual(commit.project.sequenceClips?.map(\.to), [time(10), time(2), time(10)])
        XCTAssertEqual(plan.affectedOccurrences, ["b"])
        XCTAssertEqual(plan.duration, time(19))

        var modified = project
        try modified.transcripts.advanceRevision()
        XCTAssertThrowsError(try plan.apply(to: modified, revision: revision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_plan")
        }
    }

    func testAssembleOrderedRangesFromTwoSources() throws {
        let clips = ["a", "b"].map { CutSequenceClip(id: $0, file: "\($0).mov", from: time(0), to: time(10)) }
        let (project, index, revision) = try fixture(.sequence(clips), tracks: [binding("a", file: "a.mov"), binding("b", file: "b.mov")],
                                                    words: [word("first", 2, 3, track: "a"), word("second", 4, 6, track: "b")])
        let selections = [
            TranscriptWordSelection(firstWordID: "second", space: .source),
            TranscriptWordSelection(firstWordID: "first", space: .source)
        ]
        let request = TranscriptEditRequest(action: .assemble, selections: selections, boundaryPolicy: .exact)
        let plan = try TranscriptEditPlanner.plan(request, in: index, project: project, revision: revision)
        let commit = try plan.apply(to: project, revision: revision)
        XCTAssertEqual(commit.project.sequenceClips?.map(\.file), ["b.mov", "a.mov"])
        XCTAssertEqual(commit.project.sequenceClips?.map(\.from), [time(4), time(2)])
        XCTAssertEqual(commit.project.sequenceClips?.map(\.to), [time(6), time(3)])
        XCTAssertEqual(commit.project.transcripts, project.transcripts)
        XCTAssertEqual(plan.duration, time(3))
    }

    func testGapIsProtectedThroughPersistentAnchors() throws {
        let clip = CutSequenceClip(id: "take", file: "take.mov", from: time(0), to: time(10))
        let track = binding("mic", file: "take.mov")
        let (project, index, revision) = try fixture(.sequence([clip]), tracks: [track],
                                                    words: [word("a", 1, 2, track: "mic"), word("b", 6, 7, track: "mic")])
        let gap = TranscriptWordSelection(firstWordID: "a", lastWordID: "b", kind: .gap)
        let request = TranscriptEditRequest(action: .tighten, selections: [gap], retainedDuration: time(2),
                                            boundaryPolicy: .exact)
        let plan = try TranscriptEditPlanner.plan(request, in: index, project: project, revision: revision)
        XCTAssertEqual(plan.duration, time(8))
        XCTAssertEqual(plan.retainedDuration, time(2))

        var protected = project
        let anchors = try ["a", "b"].map { try TranscriptEditorial.anchor(index.locate(wordID: $0, space: .source), binding: track) }
        protected.transcripts.authoring = [.init(attachmentID: "words", change: .pauseProtection(name: "Beat"), anchors: anchors)]
        try protected.transcripts.advanceRevision()
        let currentRevision = TranscriptEditRevision(timelineRevision: revision.timelineRevision,
                                                      transcriptRevision: protected.transcripts.revision, resultID: revision.resultID)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(request, in: index, project: protected, revision: currentRevision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "protected_transcript_gap")
        }
    }

    func testMixPhraseReportsOtherLaneAndTighteningNeedsEvidenceOnEveryLane() throws {
        let multicam = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: time(10)), angles: [
            .init(id: "a", file: "a.mov", audioStream: 0), .init(id: "b", file: "b.mov", audioStream: 0)
        ], audio: .mix, switches: [.init(at: .zero, angle: "a")], mixLanes: [
            .init(id: "a-lane", target: .camera("a"), label: "Host mic", colorSlot: 0),
            .init(id: "b-lane", target: .camera("b"), label: "Guest mic", colorSlot: 1)
        ])
        let bindings = [
            TranscriptBinding(trackID: "a", sourceID: "a", streamIndex: 0),
            TranscriptBinding(trackID: "b", sourceID: "b", streamIndex: 0)
        ]
        var guest = word("guest", 3, 5, track: "b")
        guest.speakerID = "guest-speaker"
        let host = [word("before", 1, 4, track: "a"), word("after", 7, 8, track: "a")]
        let (project, index, revision) = try fixture(.multicam(multicam), tracks: bindings, words: [host[0], guest, host[1]],
                                                      speakers: [.init(id: "guest-speaker", name: "Guest")])
        let delete = TranscriptEditRequest(action: .delete, selections: [.init(firstWordID: "before")], boundaryPolicy: .exact)
        let plan = try TranscriptEditPlanner.plan(delete, in: index, project: project, revision: revision)
        let affected = try XCTUnwrap(plan.affectedSpeech.first { $0.wordID == "guest" })
        XCTAssertEqual(affected.laneID, "b-lane")
        XCTAssertEqual(affected.laneLabel, "Guest mic")
        XCTAssertEqual(affected.speakerName, "Guest")
        XCTAssertEqual(plan.duration, time(7))

        let gap = TranscriptWordSelection(firstWordID: "before", lastWordID: "after", kind: .gap)
        let tighten = TranscriptEditRequest(action: .tighten, selections: [gap], retainedDuration: time(1),
                                            boundaryPolicy: .exact)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(tighten, in: index, project: project, revision: revision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_gap_contains_speech")
        }
        var bleed = host[0]
        bleed.observations.append(.init(trackID: "b", start: time(3), end: time(5), evidence: .recognized))
        let (bledProject, bledIndex, bledRevision) = try fixture(.multicam(multicam), tracks: bindings, words: [bleed, host[1]])
        XCTAssertEqual(bledIndex.locate(wordID: "before", space: .currentCut).count, 1)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(tighten, in: bledIndex, project: bledProject, revision: bledRevision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_gap_contains_speech")
        }
        let (untranscribed, partial, partialRevision) = try fixture(.multicam(multicam), tracks: [bindings[0]], words: host)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(tighten, in: partial, project: untranscribed,
                                                            revision: partialRevision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_gap_evidence_unavailable")
            XCTAssertTrue(($0 as? CutError)?.message.contains("Guest mic") == true)
        }
        let (recognized, silent, recognizedRevision) = try fixture(.multicam(multicam), tracks: bindings, words: host)
        XCTAssertEqual(try TranscriptEditPlanner.plan(tighten, in: silent, project: recognized,
                                                      revision: recognizedRevision).retainedDuration, time(1))
    }

    func testGroupQueuePreservesSwitchesAndContinuousMaster() throws {
        let scores: [MulticamSource] = [.init(id: "a", file: "a.mov"), .init(id: "b", file: "b.mov")]
        let master = MulticamAudioSelection(source: "mic", stream: 1)
        let multicam = MulticamProject(referenceAngle: "a", range: .init(from: time(0), to: time(10)), angles: scores,
                                      audioSources: [.init(id: "mic", file: "audio.wav")], audio: .fixed(master),
                                      switches: [.init(at: time(0), angle: "a"), .init(at: time(5), angle: "b")])
        let (project, index, revision) = try fixture(.multicam(multicam), tracks: [.init(trackID: "mic", sourceID: "mic", streamIndex: 1)],
                                                    words: [word("a", 3, 4, track: "mic"), word("b", 6, 7, track: "mic")])
        let quote = TranscriptWordSelection(firstWordID: "a", lastWordID: "b", space: .group)
        let plan = try TranscriptEditPlanner.plan(.init(action: .queue, selections: [quote], name: "Quote", boundaryPolicy: .exact),
                                                  in: index, project: project, revision: revision)
        guard case .multicam(let excerpt) = plan.snapshot else { return XCTFail("Expected a multicam excerpt") }
        XCTAssertEqual(excerpt.switches, multicam.switches)
        XCTAssertEqual(excerpt.audio, .fixed(master))
        let routes = try excerpt.plan()
        XCTAssertEqual(routes.picture.map(\.source), ["a", "b"])
        XCTAssertEqual(routes.audio.map(\.source), ["mic"])
        XCTAssertEqual(routes.audio.first?.input, .init(from: time(3), to: time(7)))
        XCTAssertEqual(plan.duration, time(4))
    }

    func testCurrentCutExactBoundaryUsesAssemblyPictureOverride() throws {
        let camera = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let media = try CutEngine().inspectMulticamSource(camera)
        let range = MulticamRange(from: .zero, to: time(1))
        let mic = MulticamAudioSelection(source: "mic", stream: 0)
        let multicam = MulticamProject(referenceAngle: "main", range: range,
                                      angles: [.init(id: "main", file: "main.mov"), .init(id: "other", file: camera.path)],
                                      audioSources: [.init(id: "mic", file: "mic.wav")], audio: .fixed(mic),
                                      switches: [.init(at: .zero, angle: "main")],
                                      assemblyItems: [.group(range, angle: "other")])
        let start = RationalTime(numerator: 1, denominator: 10_000)
        let word = TranscriptWord(id: "line", text: "line", start: start, end: time(1),
                                  observations: [.init(trackID: "mic", start: start, end: time(1), evidence: .recognized)])
        let (project, index, revision) = try fixture(.multicam(multicam), tracks: [.init(trackID: "mic", sourceID: "mic",
                                                                                       streamIndex: 0)], words: [word])
        let request = TranscriptEditRequest(action: .queue, selections: [.init(firstWordID: "line")], boundaryPolicy: .exact)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(request, in: index, project: project, revision: revision,
                                                            multicamMedia: ["other": media])) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_exact_boundary_unavailable")
        }
    }

    func testOrderedEditAcrossSeparateAttachmentsRejectsReboundSecondary() throws {
        let clips = ["a", "b"].map { CutSequenceClip(id: $0, file: "\($0).mov", from: time(0), to: time(10)) }
        var project = CutProject.sequence(clips)
        let bindings = [binding("first-mic", file: "a.mov"), binding("second-mic", file: "b.mov")]
        let attachments = zip(["first", "second"], bindings).map { id, binding in
            let hash = String(repeating: id == "first" ? "a" : "b", count: 64)
            return TranscriptAttachment(id: id, asset: .init(sha256: hash),
                                        bindings: [binding])
        }
        project.transcripts = .init(attachments: attachments)
        let indexes = try zip(attachments, [word("line", 2, 3, track: "first-mic"),
                                           word("line", 6, 8, track: "second-mic")]).map { attachment, word in
            let track = attachment.bindings[0]
            let document = TranscriptDocument(clock: .presentation, tracks: [
                .init(id: track.trackID, name: track.trackID, streamIndex: track.streamIndex)
            ], words: [word])
            return try TranscriptIndex(document: document, attachment: attachment, project: project, timelineRevision: 7)
        }
        let revision = TranscriptEditRevision(timelineRevision: 7, transcriptRevision: 0, resultID: attachments[0].resultID)
        let selections = [
            TranscriptWordSelection(firstWordID: "line", space: .source, attachmentID: "second"),
            TranscriptWordSelection(firstWordID: "line", space: .source, attachmentID: "first")
        ]
        let request = TranscriptEditRequest(action: .assemble, selections: selections, boundaryPolicy: .exact)
        let plan = try TranscriptEditPlanner.plan(request, in: indexes[0], project: project, revision: revision,
                                                  additionalIndexes: [indexes[1]])
        let commit = try plan.apply(to: project, revision: revision)
        XCTAssertEqual(commit.project.sequenceClips?.map(\.file), ["b.mov", "a.mov"])
        XCTAssertEqual(commit.project.sequenceClips?.map(\.from), [time(6), time(2)])
        XCTAssertEqual(commit.project.sequenceClips?.map(\.to), [time(8), time(3)])
        XCTAssertEqual(plan.attachmentResults["second"], attachments[1].resultID)
        var rebound = project
        rebound.transcripts.attachments[1].bindings[0].offset = time(1)
        try rebound.transcripts.advanceRevision()
        let current = TranscriptEditRevision(timelineRevision: 7, transcriptRevision: rebound.transcripts.revision,
                                             resultID: attachments[0].resultID)
        XCTAssertThrowsError(try plan.apply(to: rebound, revision: current)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_plan")
        }
    }

    func testCrossAttachmentSpeechBlocksTightenAndAppearsInExactDeletePreview() throws {
        let clip = CutSequenceClip(id: "clip", file: "audio.wav", from: time(0), to: time(6))
        var project = CutProject.sequence([clip])
        func attachment(_ id: String, file: String) -> TranscriptAttachment {
            let hash = String(repeating: id, count: 64)
            return .init(id: id, asset: .init(sha256: hash),
                         bindings: [binding(id, file: file)])
        }
        let main = attachment("a", file: clip.file)
        let overlap = attachment("b", file: clip.file)
        let duplicate = attachment("c", file: clip.file)
        let unrelated = attachment("d", file: "unrelated.wav")
        project.transcripts = .init(attachments: [main, overlap, duplicate, unrelated])
        func makeIndex(_ attachment: TranscriptAttachment, words: [TranscriptWord]) throws -> TranscriptIndex {
            let track = attachment.bindings[0]
            let document = TranscriptDocument(clock: .presentation, tracks: [
                .init(id: track.trackID, name: track.trackID, streamIndex: track.streamIndex)
            ], words: words)
            return try TranscriptIndex(document: document, attachment: attachment, project: project, timelineRevision: 7)
        }
        func crossingWord(_ id: String) -> TranscriptWord {
            let start = RationalTime(numerator: 5, denominator: 2)
            let end = RationalTime(numerator: 7, denominator: 2)
            return .init(id: "overlap-\(id)", text: "interjection", start: start, end: end,
                         observations: [.init(trackID: id, start: start, end: end, evidence: .recognized)])
        }
        let primary = try makeIndex(main, words: [word("start", 1, 2, track: "a"), word("end", 4, 5, track: "a")])
        let second = try makeIndex(overlap, words: [crossingWord("b")])
        let third = try makeIndex(duplicate, words: [crossingWord("c")])
        let revision = TranscriptEditRevision(timelineRevision: 7, transcriptRevision: 0, resultID: main.resultID)
        let selection = TranscriptWordSelection(firstWordID: "start", lastWordID: "end", kind: .gap)
        let tighten = TranscriptEditRequest(action: .tighten, selections: [selection], retainedDuration: .zero,
                                            boundaryPolicy: .exact)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(tighten, in: primary, project: project, revision: revision,
                                                            additionalIndexes: [second])) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_gap_contains_speech")
        }
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(tighten, in: primary, project: project, revision: revision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_gap_evidence_unavailable")
        }
        XCTAssertEqual(project.sequenceClips, [clip])

        let delete = TranscriptEditRequest(action: .delete, selections: [selection], boundaryPolicy: .exact)
        let reviewed = try TranscriptEditPlanner.plan(delete, in: primary, project: project, revision: revision,
                                                      additionalIndexes: [second, third])
        XCTAssertEqual(reviewed.boundaries.map(\.resolved), [time(2), time(4)])
        XCTAssertEqual(reviewed.affectedSpeech.map(\.text), ["interjection"])
        XCTAssertEqual(reviewed.affectedSpeech.map(\.attachmentID), ["b"])
        XCTAssertEqual(reviewed.unavailableEvidenceAttachmentIDs, [])
        let commit = try reviewed.apply(to: project, revision: revision)
        XCTAssertEqual(commit.undo?.project, project)
        XCTAssertEqual(commit.project.sequenceClips?.map(\.from), [.zero, time(4)])
        XCTAssertEqual(commit.project.sequenceClips?.map(\.to), [time(2), time(6)])

        let missing = try TranscriptEditPlanner.plan(delete, in: primary, project: project, revision: revision)
        XCTAssertEqual(missing.unavailableEvidenceAttachmentIDs, ["b", "c"])
    }

    func testAudioNudgeUsesIndexedSamplesAndShowsDurationChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("take.wav")
        try pcmWave().write(to: media)
        let clip = CutSequenceClip(id: "a", file: media.lastPathComponent, from: time(0), to: time(1))
        let track = binding("mic", file: clip.file)
        let phrase = TranscriptWord(id: "phrase", text: "phrase",
                                    start: .init(numerator: 1, denominator: 4), end: .init(numerator: 1, denominator: 2),
                                    candidateTrackIDs: [track.trackID])
        let (project, index, revision) = try fixture(.sequence([clip]), tracks: [track], words: [phrase])
        let request = TranscriptEditRequest(action: .queue, selections: [.init(firstWordID: "phrase")],
                                            startFrameNudge: 2, endFrameNudge: -1)
        let plan = try TranscriptEditPlanner.plan(request, in: index, project: project, revision: revision,
                                                  relativeTo: directory.appendingPathComponent("edit.cut"))
        XCTAssertEqual(plan.boundaries.map(\.resolved), [
            RationalTime(numerator: 4_002, denominator: 16_000), RationalTime(numerator: 7_999, denominator: 16_000)
        ])
        XCTAssertEqual(plan.duration, .init(numerator: 3_997, denominator: 16_000))
    }

    func testOffFrameExactFailsAndCollapsedCopyPairExports() throws {
        let tools = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .compactMap { $0 }
        guard let ffmpeg = tools.first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("FFmpeg is required to build the fixed-GOP fixture.")
        }
        let setDevelopmentHelper = ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil
        if setDevelopmentHelper { setenv("MPCUT_FFMPEG_HELPER", ffmpeg, 0) }
        defer { if setDevelopmentHelper { unsetenv("MPCUT_FFMPEG_HELPER") } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=black:s=64x64:r=25:d=2",
                             "-c:v", "libx264", "-g", "10", "-keyint_min", "10", "-sc_threshold", "0",
                             "-bf", "0", "-pix_fmt", "yuv420p", source.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let clip = CutSequenceClip(id: "a", file: source.lastPathComponent, from: .zero, to: time(2))
        let track = binding("mic", file: clip.file)
        func word(_ id: String, _ from: Int64, _ to: Int64) -> TranscriptWord {
            .init(id: id, text: id, start: .init(numerator: from, denominator: 100),
                  end: .init(numerator: to, denominator: 100), candidateTrackIDs: [track.trackID])
        }
        let (project, index, revision) = try fixture(.sequence([clip]), tracks: [track],
                                                    words: [word("gop", 39, 41), word("offFrame", 45, 51)])
        let projectURL = directory.appendingPathComponent("edit.cut")
        let exact = TranscriptEditRequest(action: .queue, selections: [.init(firstWordID: "offFrame")], boundaryPolicy: .exact)
        XCTAssertThrowsError(try TranscriptEditPlanner.plan(exact, in: index, project: project, revision: revision,
                                                            relativeTo: projectURL)) {
            let issue = $0 as? CutError
            XCTAssertEqual(issue?.code, "transcript_exact_boundary_unavailable")
            XCTAssertTrue(issue?.nearest?.contains(.init(numerator: 11, denominator: 25)) ?? false)
        }
        let copy = TranscriptEditRequest(action: .queue, selections: [.init(firstWordID: "gop")], boundaryPolicy: .copySafe)
        let plan = try TranscriptEditPlanner.plan(copy, in: index, project: project, revision: revision, relativeTo: projectURL)
        XCTAssertEqual(plan.tier?.mode, .copy)
        XCTAssertTrue(plan.duration > .zero)
        let engine = CutEngine()
        let output = directory.appendingPathComponent("excerpt.mov")
        let rendered = try engine.resolve(plan.snapshot.requests(relativeTo: projectURL), output: output)
        try engine.export(rendered, to: output)
        let actual = try engine.inspect(output, keyframes: true)
        XCTAssertEqual(actual.duration, plan.duration)

        let nearest = TranscriptEditRequest(action: .queue, selections: [.init(firstWordID: "offFrame")])
        let repaired = try TranscriptEditPlanner.plan(nearest, in: index, project: project, revision: revision, relativeTo: projectURL)
        XCTAssertEqual(repaired.boundaries.map(\.resolved), [.init(numerator: 11, denominator: 25), .init(numerator: 13, denominator: 25)])
        let tier = try XCTUnwrap(repaired.tier)
        let mode = try XCTUnwrap(tier.mode)
        XCTAssertNotEqual(mode, .copy)
        let extensionName = try XCTUnwrap(tier.container)
        let repairedOutput = directory.appendingPathComponent("nearest.\(extensionName)")
        let export = ExportPlanner()
        let request = try ExportRequest(clips: repaired.snapshot.requests(relativeTo: projectURL), mode: mode)
        guard case .ready(let render, _, _) = export.resolve(request, output: repairedOutput) else {
            return XCTFail("The suggested native export mode could not plan the frame-aligned excerpt.")
        }
        try export.write(render, to: repairedOutput)
        let repairedMedia = try engine.inspect(repairedOutput, keyframes: true)
        XCTAssertEqual(repairedMedia.duration, repaired.duration)
    }

    func testAWordDeletedBetweenTouchingNeighboursLeavesNoListedRemainder() throws {
        let tools = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .compactMap { $0 }
        guard let ffmpeg = tools.first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("FFmpeg is required to build the 25 fps fixture.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=black:s=64x64:r=25:d=2",
                             "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-shortest",
                             "-c:v", "libx264", "-g", "10", "-bf", "0", "-pix_fmt", "yuv420p",
                             "-c:a", "pcm_s16le", source.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let projectURL = directory.appendingPathComponent("edit.cut")
        let engine = CutEngine()
        let hash = String(repeating: "a", count: 64)
        // Each word starts where the last one ends, and no boundary is on a 40 ms frame.
        let spoken: [(String, Int64, Int64)] = [("the", 40, 54), ("garage", 54, 78), ("when", 78, 100)]

        func check(_ timeline: CutProject, _ binding: TranscriptBinding, sequence: [String: MediaInfo] = [:],
                   multicam: [String: MediaInfo] = [:], line: UInt = #line) throws {
            var project = timeline
            let attachment = TranscriptAttachment(id: "words", asset: .init(sha256: hash),
                                                  bindings: [binding])
            project.transcripts = ProjectTranscripts(attachments: [attachment])
            let document = TranscriptDocument(clock: .presentation, tracks: [
                .init(id: binding.trackID, name: binding.trackID, sourceID: binding.sourceID, streamIndex: binding.streamIndex)
            ], words: spoken.map { id, from, to in
                let start = RationalTime(numerator: from, denominator: 100), end = RationalTime(numerator: to, denominator: 100)
                return .init(id: id, text: id, start: start, end: end, observations: [
                    .init(trackID: binding.trackID, start: start, end: end, evidence: .recognized)
                ])
            })
            func index(_ project: CutProject) throws -> TranscriptIndex {
                try TranscriptIndex(document: document, attachment: attachment, project: project, projectURL: projectURL,
                                    sequenceMedia: sequence, multicamMedia: multicam, timelineRevision: 7)
            }
            func plan(_ request: TranscriptEditRequest) throws -> TranscriptEditPlan {
                try TranscriptEditPlanner.plan(request, in: index(project), project: project,
                                               revision: .init(timelineRevision: 7, transcriptRevision: 0, resultID: hash),
                                               relativeTo: projectURL, sequenceMedia: sequence, multicamMedia: multicam)
            }
            let before = try index(project)
            XCTAssertEqual(before.read(space: .currentCut).items.map(\.text), ["the", "garage", "when"], line: line)

            let delete = try plan(.init(action: .delete, selections: [.init(firstWordID: "garage")]))
            // Nearest Frame takes 0.52 to 0.76 for the requested 0.54 to 0.78.
            XCTAssertEqual(delete.boundaries.map(\.resolved),
                           [.init(numerator: 13, denominator: 25), .init(numerator: 19, denominator: 25)], line: line)
            let after = try index(delete.snapshot)
            let listed = after.read(space: .currentCut).items
            XCTAssertEqual(listed.map(\.text), ["the", "when"], line: line)
            // The neighbour that lost its last 20 ms is still a word, marked as cut into.
            XCTAssertEqual(listed.map(\.partial), [true, false], line: line)
            XCTAssertEqual(after.search("garage", space: .currentCut).total, 0, line: line)
            XCTAssertTrue(after.locate(wordID: "garage", space: .currentCut).isEmpty, line: line)
            XCTAssertEqual(after.search("the when", space: .currentCut).total, 1, line: line)
            XCTAssertEqual(after.search("garage", space: .source).total, 1, line: line)

            // A blade lands on the same frame and leaves the last 20 ms of "the" in the next clip.
            // That piece continues the word, so the phrase still reads once across the cut.
            let split = try plan(.init(action: .split, selections: [.init(firstWordID: "garage")]))
            XCTAssertEqual(split.boundaries.map(\.resolved), [.init(numerator: 13, denominator: 25)], line: line)
            let bladed = try index(split.snapshot)
            XCTAssertEqual(bladed.locate(wordID: "the", space: .currentCut).count, 2, line: line)
            XCTAssertEqual(bladed.search("the garage when", space: .currentCut).total, 1, line: line)
        }

        let clip = CutSequenceClip(id: "a", file: source.lastPathComponent, from: .zero, to: time(2))
        try check(.sequence([clip]),
                  .init(trackID: "mic", file: clip.file, streamIndex: 1, sequenceClockOrigin: .zero),
                  sequence: [clip.file: engine.inspect(source, keyframes: true)])
        let group = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: time(2)),
                                    angles: [.init(id: "a", file: clip.file)],
                                    audio: .fixed(.init(source: "a", stream: 1)),
                                    switches: [.init(at: .zero, angle: "a")])
        try check(.multicam(group), .init(trackID: "mic", sourceID: "a", streamIndex: 1),
                  multicam: ["a": engine.inspectMulticamSource(source)])
    }

    private func pcmWave() -> Data {
        var data = Data()
        func text(_ string: String) { data.append(contentsOf: string.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        text("RIFF")
        number(UInt32(32_036))
        text("WAVEfmt ")
        number(UInt32(16))
        number(UInt16(1))
        number(UInt16(1))
        number(UInt32(16_000))
        number(UInt32(32_000))
        number(UInt16(2))
        number(UInt16(16))
        text("data")
        number(UInt32(32_000))
        data.append(Data(count: 32_000))
        return data
    }

    private func fixture(_ timeline: CutProject, tracks: [TranscriptBinding], words: [TranscriptWord],
                         speakers: [TranscriptSpeaker] = [])
        throws -> (CutProject, TranscriptIndex, TranscriptEditRevision) {
        var project = timeline
        let hash = String(repeating: "a", count: 64)
        let attachment = TranscriptAttachment(id: "words", asset: .init(sha256: hash),
                                              bindings: tracks)
        project.transcripts = ProjectTranscripts(attachments: [attachment])
        let document = TranscriptDocument(clock: .presentation, tracks: tracks.map {
            .init(id: $0.trackID, name: $0.trackID, sourceID: $0.sourceID, streamIndex: $0.streamIndex)
        }, speakers: speakers, words: words)
        let index = try TranscriptIndex(document: document, attachment: attachment, project: project, timelineRevision: 7)
        return (project, index, .init(timelineRevision: 7, transcriptRevision: 0, resultID: hash))
    }

    private func binding(_ id: String, file: String) -> TranscriptBinding {
        .init(trackID: id, file: file, streamIndex: 0, sequenceClockOrigin: .zero)
    }

    private func word(_ id: String, _ from: Int64, _ to: Int64, track: String) -> TranscriptWord {
        .init(id: id, text: id, start: time(from), end: time(to), observations: [
            .init(trackID: track, start: time(from), end: time(to), evidence: .recognized)
        ])
    }

    private func time(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
}
