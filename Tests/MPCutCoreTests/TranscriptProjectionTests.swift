import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptProjectionTests: XCTestCase {
    private func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }

    private func r(_ start: Int64, _ end: Int64) -> MulticamRange {
        .init(from: t(start), to: t(end))
    }

    private var still: StillInsert {
        .init(id: "insert", assetID: "card", duration: t(2), cadence: t(1))
    }

    private var stillAsset: StillAsset {
        .init(id: "card", file: "card.png", displayName: "Card",
              fingerprint: String(repeating: "a", count: 64))
    }

    private func attachment(_ bindings: [TranscriptBinding]) -> TranscriptAttachment {
        let digest = String(repeating: "a", count: 64)
        return .init(id: "interview", asset: .init(file: "project.cut.transcripts/\(digest).json", sha256: digest),
                     bindings: bindings)
    }

    func testSequenceRetainsTrimmedRepeatsOnPresentationClockWithAnInsertedCard() throws {
        let recording = TranscriptTrack(id: "mic", name: "Mic", streamIndex: 2)
        let document = TranscriptDocument(clock: .presentation, tracks: [recording], words: [
            .init(id: "one", text: "Look,", start: t(8), end: t(10)),
            .init(id: "two", text: "HERE!", start: t(10), end: t(11))
        ], approximateClock: true)
        let binding = TranscriptBinding(trackID: recording.id, file: "interview.mov", streamIndex: 2,
                                        sequenceClockOrigin: t(5), sequenceStreamOrdinal: 0)
        let cut = CutProject.stillSequence(.init(items: [
            .source(.init(id: "first", file: "interview.mov", from: t(4), to: t(6))),
            .still(still),
            .source(.init(id: "repeat", file: "interview.mov", from: t(3), to: t(6)))
        ], stillAssets: [stillAsset]))

        let index = try TranscriptIndex(document: document, attachment: attachment([binding]),
                                        project: cut, timelineRevision: 14)
        let words = index.locate(wordID: "one", space: .currentCut)
        XCTAssertEqual(words.map(\.range), [r(0, 1), r(4, 6)])
        XCTAssertEqual(words.map(\.sourceRange), [r(9, 10), r(8, 10)])
        XCTAssertEqual(words.map(\.sequenceSourceRange), [r(4, 5), r(3, 5)])
        XCTAssertEqual(words.map(\.partial), [true, false])
        XCTAssertEqual(words.map(\.assemblyIndex), [0, 2])
        XCTAssertEqual(words.map(\.timelineRevision), [14, 14])
        XCTAssertEqual(index.position(at: t(3), space: .currentCut), nil)
        XCTAssertEqual(index.position(at: t(5), space: .currentCut), 2)
        XCTAssertEqual(index.gaps.map(\.range), [r(2, 4)])
        XCTAssertEqual(index.gaps.map(\.reason), [.still])

        let first = index.search("LOOK here", space: .currentCut, limit: 1)
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(first.nextOffset, 1)
        XCTAssertEqual(first.items.first?.words.map(\.text), ["Look,", "HERE!"])
        let second = index.search("look here", space: .currentCut, offset: 1)
        XCTAssertEqual(second.items.first?.words.first?.clipID, "repeat")
        XCTAssertNil(second.nextOffset)
    }

    func testSequenceProjectsZoomBleedOncePerRetainedClipAndKeepsTrackEvidence() throws {
        let mix = TranscriptTrack(id: "mix", name: "Zoom", streamIndex: 1, coverage: .skipped)
        let alice = TranscriptTrack(id: "alice", name: "Alice", streamIndex: 0, role: .isolatedMic)
        let bob = TranscriptTrack(id: "bob", name: "Bob", streamIndex: 0, role: .isolatedMic)
        let tracks = [mix, alice, bob]
        let word = TranscriptWord(id: "one", text: "Hello", start: t(1), end: t(2), observations: [
            .init(trackID: bob.id, start: t(1), end: t(2), evidence: .inferred, basis: "alignment"),
            .init(trackID: alice.id, start: t(1), end: t(2), evidence: .recognized)
        ])
        let document = TranscriptDocument(clock: .session, tracks: tracks, words: [word])
        let bindings = tracks.map { TranscriptBinding(trackID: $0.id, file: "Zoom.mp4", streamIndex: 1) }
        let project = CutProject.sequence(["first", "repeat"].map {
            CutSequenceClip(id: $0, file: "Zoom.mp4", from: .zero, to: t(3))
        })
        let index = try TranscriptIndex(document: document, attachment: attachment(bindings), project: project)
        let words = index.readAll(space: .currentCut)
        XCTAssertEqual(words.map(\.range), [r(1, 2), r(4, 5)])
        XCTAssertEqual(words.map(\.trackID), [alice.id, alice.id])
        XCTAssertEqual(Set(try XCTUnwrap(words.first).observations.map(\.trackID)), [alice.id, bob.id])
        XCTAssertTrue(index.gaps.isEmpty)
    }

    /// A camera's different reading of a wearer's word is attached to that word. In Source the
    /// camera shows its own reading once, under the wearer's name, and adds no speaker of its own.
    func testAnotherRecordingsReadingIsNotListedBesideTheWordItBelongsTo() throws {
        let lav = TranscriptTrack(id: "lav.track", name: "Host lav", role: .isolatedMic,
                                  words: [.init(id: "l0", text: "40", start: t(1), end: t(2))],
                                  speakers: [.init(id: "s0", name: "Host")])
        let camera = TranscriptTrack(id: "camera.track", name: "Camera", role: .mixedAudio, words: [
            .init(id: "c0", text: "forty", start: t(1), end: t(2), speakerID: "s0"),
            .init(id: "c1", text: "aside", start: t(4), end: t(5), speakerID: "s0"),
        ], speakers: [.init(id: "s0", name: "Speaker 0")])
        let spoken = TranscriptWord(id: "w0", text: "40", start: t(1), end: t(2), speakerID: "s1", observations: [
            .init(trackID: lav.id, wordID: "l0", start: t(1), end: t(2), evidence: .recognized),
            .init(trackID: camera.id, wordID: "c0", text: "forty", start: t(1), end: t(2), evidence: .inferred,
                  basis: "alternative_reading_of_spill"),
        ])
        let document = TranscriptDocument(clock: .session, tracks: [lav, camera],
                                          speakers: [.init(id: "s1", name: "Host")], words: [spoken], jobID: "test-job")
        let index = try TranscriptIndex(document: document)
        let source = index.read(space: .source, filter: .init(trackID: camera.id)).items
        XCTAssertEqual(source.map(\.text), ["forty", "aside"])
        XCTAssertEqual(source.first?.wordID, "w0")
        XCTAssertEqual(source.first?.speakerID, "s1")
        XCTAssertEqual(index.read(space: .source, filter: .init(trackID: lav.id)).items.map(\.text), ["40"])
        // A camera word no conversation word cites keeps the camera's own diarized label.
        XCTAssertNotEqual(source.last?.speakerID, "s1")
        XCTAssertEqual(index.speakers.map(\.name), ["Host", "Speaker 0"])
        // The camera lists its reading once. The lav wrote the same number in digits.
        XCTAssertEqual(index.search("forty", space: .source, filter: .init(trackID: camera.id)).total, 1)
        XCTAssertEqual(index.search("forty", space: .source).items.map { $0.words.map(\.text) }.sorted { $0[0] < $1[0] },
                       [["40"], ["forty"]])
    }

    func testMulticamCurrentCutFollowsActualAudioAndRetainsOriginalSpeech() throws {
        let lav = TranscriptTrack(id: "lav.track", name: "Host", sourceID: "lav", streamIndex: 0,
                                  sessionStart: t(-2))
        let camera = TranscriptTrack(id: "camera.track", name: "Camera", sourceID: "close", streamIndex: 4,
                                     sessionStart: t(1))
        let cameraTwo = TranscriptTrack(id: "wide.track", name: "Off-air", sourceID: "wide", streamIndex: 1,
                                        coverage: .skipped,
                                        activity: [.init(start: t(2), end: t(3), level: 1)])
        let document = TranscriptDocument(clock: .session, tracks: [lav, camera, cameraTwo], words: [
            .init(id: "lavword", text: "hello", start: t(1), end: t(4), observations: [
                .init(trackID: lav.id, start: t(3), end: t(6), evidence: .recognized),
                .init(trackID: camera.id, start: t(0), end: t(3), evidence: .inferred, basis: "alignment")
            ]),
            .init(id: "aside", text: "aside", start: t(5), end: t(6), observations: [
                .init(trackID: camera.id, start: t(4), end: t(5), evidence: .recognized)
            ]),
            .init(id: "off", text: "off air", start: t(8), end: t(9), observations: [
                .init(trackID: camera.id, start: t(7), end: t(8), evidence: .recognized)
            ])
        ], jobID: "test-job")

        var project = MulticamProject(referenceAngle: "wide", range: r(0, 10),
            angles: [.init(id: "wide", file: "wide.mov"), .init(id: "close", file: "close.mov", offset: t(1))],
            audioSources: [.init(id: "lav", file: "lav.wav", offset: t(-2))],
            audio: .fixed(.init(source: "lav", stream: 0)),
            switches: [.init(at: .zero, angle: "wide"), .init(at: t(2), angle: "close"),
                       .init(at: t(3), angle: "close", audio: .init(source: "close", stream: 4)),
                       .init(at: t(7), angle: "wide")],
            assemblyItems: [.group(r(1, 7)), .still(still), .group(r(2, 4))], stillAssets: [stillAsset])
        let index = try TranscriptIndex(document: document, project: .multicam(project))
        let cut = index.locate(wordID: "lavword", space: .currentCut)
        XCTAssertEqual(cut.map(\.range), [r(0, 2), r(2, 3), r(8, 9), r(9, 10)])
        XCTAssertEqual(cut.map(\.assemblyIndex), [0, 0, 2, 2])
        XCTAssertEqual(cut.map(\.audibility), [.recognized, .inferred, .recognized, .inferred])
        XCTAssertEqual(cut.map(\.partial), [true, true, true, true])
        XCTAssertEqual(index.locate(wordID: "aside", space: .currentCut).map(\.range), [r(4, 5)])
        XCTAssertTrue(index.locate(wordID: "off", space: .currentCut).isEmpty)
        XCTAssertEqual(index.search("Hello aside", space: .currentCut).items.first?.words.map(\.range),
                       [r(0, 2), r(2, 3), r(4, 5)])
        XCTAssertEqual(index.search("Hello aside", space: .currentCut,
                                    filter: .init(trackID: camera.id, includeInferred: true)).items.first?.words.map(\.range),
                       [r(2, 3), r(4, 5)])
        XCTAssertEqual(index.locate(wordID: "off", space: .group).map(\.range), [r(8, 9)])
        XCTAssertEqual(index.search("hello", space: .group, filter: .init(trackID: camera.id)).total, 0)
        XCTAssertEqual(index.search("hello", space: .group, filter: .init(trackID: camera.id, includeInferred: true)).total, 1)
        XCTAssertEqual(index.search("hello", space: .group, filter: .init(trackID: cameraTwo.id, includeInferred: true)).total, 0)
        XCTAssertEqual(index.gaps.map(\.range), [r(6, 8)])

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for space in TranscriptSpace.allCases {
            let focused = try TranscriptIndex(document: document, project: .multicam(project), spaces: [space])
            XCTAssertEqual(try encoder.encode(focused.read(space: space)), try encoder.encode(index.read(space: space)))
            XCTAssertEqual(try encoder.encode(focused.search("hello", space: space)),
                           try encoder.encode(index.search("hello", space: space)))
            XCTAssertEqual(focused.gaps.map(\.range), space == .currentCut ? index.gaps.map(\.range) : [])
            for other in TranscriptSpace.allCases where other != space {
                XCTAssertTrue(focused.readAll(space: other).isEmpty)
            }
        }

        project.audioSources[0].offset = t(-1)
        let stale = try TranscriptIndex(document: document, project: .multicam(project))
        XCTAssertEqual(stale.locate(wordID: "lavword", space: .group).map(\.range), [r(2, 5)])
        XCTAssertEqual(stale.locate(wordID: "lavword", space: .source).map(\.range), [r(3, 6)])
        XCTAssertTrue(stale.locate(wordID: "lavword", space: .group).first?.staleMatches == true)
        XCTAssertFalse(stale.locate(wordID: "lavword", space: .currentCut).contains { $0.audibility == .inferred })
    }

    func testAttachedUnboundTrackKeepsSourceWordsWithoutAssumingMatchingSourceIDs() throws {
        let project = MulticamProject(referenceAngle: "cam", range: r(0, 5),
            angles: [.init(id: "cam", file: "camera.mov", audioStream: 2)],
            audio: .follow, switches: [.init(at: .zero, angle: "cam")])
        let document = TranscriptDocument(clock: .session,
            tracks: [.init(id: "mic", name: "Mic", sourceID: "cam", streamIndex: 2)],
            words: [.init(id: "word", text: "Unbound", start: t(1), end: t(2))])
        let index = try TranscriptIndex(document: document, attachment: attachment([]), project: .multicam(project))
        XCTAssertEqual(index.locate(wordID: "word", space: .source).first?.bindingStatus, .unbound)
        XCTAssertTrue(index.locate(wordID: "word", space: .currentCut).isEmpty)
        XCTAssertEqual(index.gaps.map(\.reason), [.unbound])
    }

    func testMultifileAngleProjectsPhysicalAudioRoutesThroughReplayAndGap() throws {
        let first = TranscriptTrack(id: "part-1-mic", name: "First mic", sourceID: "cam", streamIndex: 1)
        let next = TranscriptTrack(id: "part-2-mic", name: "Second mic", sourceID: "part-2", streamIndex: 2,
                                   sessionStart: t(3))
        let document = TranscriptDocument(clock: .session, tracks: [first, next], words: [
            .init(id: "before", text: "before", start: t(1), end: t(2), observations: [
                .init(trackID: first.id, start: t(1), end: t(2), evidence: .recognized)
            ]),
            .init(id: "after", text: "after", start: t(3), end: t(4), observations: [
                .init(trackID: next.id, start: .zero, end: t(1), evidence: .recognized)
            ])
        ], jobID: "test-job")
        let project = MulticamProject(referenceAngle: "cam", range: r(0, 5), angles: [
            .init(id: "cam", file: "cam-1.mov", audioStream: 1, coverage: r(0, 2), additionalRecordings: [
                .init(id: "part-2", file: "cam-2.mov", offset: t(3), audioStream: 2, coverage: r(3, 5))
            ]),
            .init(id: "wide", file: "wide.mov")
        ], audio: .follow, switches: [.init(at: .zero, angle: "cam")],
            assemblyItems: [.group(r(0, 5), angle: "wide"), .group(r(3, 5))])
        let index = try TranscriptIndex(document: document, project: .multicam(project))

        XCTAssertEqual(index.read(space: .currentCut).items.map(\.wordID), ["before", "after", "after"])
        XCTAssertEqual(index.locate(wordID: "after", space: .source).map(\.range), [r(0, 1)])
        XCTAssertEqual(index.locate(wordID: "after", space: .group).map(\.range), [r(3, 4)])
        let repeats = index.locate(wordID: "after", space: .currentCut)
        XCTAssertEqual(repeats.map(\.range), [r(3, 4), r(5, 6)])
        XCTAssertEqual(repeats.map(\.routedSourceID), ["part-2", "part-2"])
        XCTAssertEqual(repeats.map(\.routedStreamIndex), [2, 2])
        XCTAssertEqual(index.gaps.map(\.range), [r(2, 3)])
        XCTAssertEqual(index.gaps.map(\.reason), [.silence])
        XCTAssertEqual(index.search("before after", space: .currentCut).total, 0)
        XCTAssertEqual(index.search("after", space: .currentCut, filter: .init(sourceID: "part-2")).total, 2)
    }

    func testMixProjectsRolloverAndMergesBleedAcrossLaneFilters() throws {
        let tracks = [
            TranscriptTrack(id: "wide-mic", name: "Wide mic", sourceID: "wide", streamIndex: 0),
            TranscriptTrack(id: "close-mic", name: "Close mic", sourceID: "close", streamIndex: 1),
            TranscriptTrack(id: "close-second-channel", name: "Close second channel", sourceID: "close", streamIndex: 1, channel: 1),
            TranscriptTrack(id: "rollover-mic", name: "Rollover mic", sourceID: "rollover", streamIndex: 2)
        ]
        let document = TranscriptDocument(clock: .session, tracks: tracks, words: [
            .init(id: "bled", text: "bled", start: t(1), end: t(2), observations: [
                .init(trackID: "close-mic", start: t(1), end: t(2), evidence: .recognized),
                .init(trackID: "close-second-channel", start: t(1), end: t(2), evidence: .recognized),
                .init(trackID: "wide-mic", start: t(1), end: t(3), evidence: .recognized)
            ]),
            .init(id: "wide-word", text: "wide", start: t(2), end: t(4), observations: [
                .init(trackID: "wide-mic", start: t(2), end: t(4), evidence: .recognized)
            ]),
            .init(id: "close-word", text: "close", start: t(3), end: t(4), observations: [
                .init(trackID: "rollover-mic", start: .zero, end: t(1), evidence: .recognized)
            ])
        ])
        var project = MulticamProject(referenceAngle: "wide", range: r(0, 5), angles: [
            .init(id: "wide", file: "wide.mov", audioStream: 0),
            .init(id: "close", file: "close.mov", audioStream: 1, coverage: r(0, 2), additionalRecordings: [
                .init(id: "rollover", file: "rollover.mov", offset: t(3), audioStream: 2, coverage: r(3, 5))
            ])
        ], audio: .mix, switches: [.init(at: .zero, angle: "wide")], mixLanes: [
            .init(id: "wide-lane", target: .camera("wide"), label: "Wide", colorSlot: 4),
            .init(id: "close-lane", target: .camera("close"), label: "Close", colorSlot: 1)
        ])
        let index = try TranscriptIndex(document: document, project: .multicam(project))
        let projected = index.read(space: .currentCut).items
        var switched = project
        switched.switches += [
            .init(at: RationalTime(numerator: 3, denominator: 2), angle: "close"),
            .init(at: RationalTime(numerator: 5, denominator: 2), angle: "wide"),
            .init(at: RationalTime(numerator: 7, denominator: 2), angle: "close"),
        ]
        let switchedIndex = try TranscriptIndex(document: document, project: .multicam(switched))
        let switchedWords = switchedIndex.read(space: .currentCut).items
        XCTAssertEqual(switchedWords.map(\.id), projected.map(\.id))
        XCTAssertEqual(switchedWords.map(\.range), projected.map(\.range))
        XCTAssertEqual(projected.map(\.wordID), ["bled", "wide-word", "close-word"])
        XCTAssertEqual(projected.map(\.laneID), ["close-lane", "wide-lane", "close-lane"])
        XCTAssertEqual(projected.map(\.laneColorSlot), [1, 4, 1])
        XCTAssertEqual(projected.first?.heardOnLaneIDs, ["wide-lane"])
        XCTAssertEqual(projected.first?.observations.map(\.trackID), ["close-mic", "close-second-channel", "wide-mic"])
        let bleedTail = index.overlapping(r(2, 3), space: .currentCut).first { $0.wordID == "bled" }
        XCTAssertEqual(bleedTail?.laneID, "wide-lane")
        XCTAssertEqual(bleedTail?.range, r(1, 3))
        XCTAssertEqual(index.read(space: .currentCut, filter: .init(laneID: "wide-lane")).items.map(\.wordID),
                       ["bled", "wide-word"])
        XCTAssertEqual(index.search("bled wide", space: .currentCut, filter: .init(laneID: "wide-lane")).total, 1)
        var interruptedDocument = document
        let interruption = RationalTime(numerator: 3, denominator: 2)
        interruptedDocument.words.insert(.init(id: "interruption", text: "interrupt", start: interruption, end: t(2),
                                               observations: [.init(trackID: "close-mic", start: interruption, end: t(2),
                                                                    evidence: .recognized)]), at: 1)
        let interrupted = try TranscriptIndex(document: interruptedDocument, project: .multicam(project))
        let wideLane = TranscriptFilter(laneID: "wide-lane")
        let matches = interrupted.search("bled wide", space: .currentCut, filter: wideLane)
        XCTAssertEqual(matches.items.first?.words.map(\.wordID), ["bled", "wide-word"])
        XCTAssertEqual(matches.items.first?.words.first?.laneID, "close-lane")
        let prepared = try interrupted.prepareSearch("bled wide", space: .currentCut, filter: wideLane)
        XCTAssertEqual(prepared.page().items.first?.words.map(\.wordID), ["bled", "wide-word"])
        let projectIndex = TranscriptProjectIndex(indexes: [interrupted], space: .currentCut)
        XCTAssertEqual(projectIndex.search("bled wide", filter: wideLane).items.first?.words.map(\.wordID),
                       ["bled", "wide-word"])
        XCTAssertEqual(interrupted.search("bled interrupt", space: .currentCut, filter: wideLane).total, 0)
        XCTAssertEqual(projected.last?.routedSourceID, "rollover")
        XCTAssertEqual(projected.last?.range, r(3, 4))
        XCTAssertEqual(index.gaps.count, 1)
        XCTAssertEqual(index.gaps.first?.laneID, "close-lane")
        XCTAssertEqual(index.gaps.first?.range, r(2, 3))
        let exported = try TranscriptCodec.encode(index, space: .currentCut, format: .json)
        let json = try XCTUnwrap(String(data: exported, encoding: .utf8))
        XCTAssertFalse(json.contains("lane_id"))

        var simultaneousGap = project
        simultaneousGap.angles[0].coverage = r(0, 2)
        let silent = try TranscriptIndex(document: document, project: .multicam(simultaneousGap))
        XCTAssertEqual(silent.gaps.filter { $0.laneID == nil && $0.reason == .silence }.map(\.range), [r(2, 3)])

        project.audio = .follow
        let follow = try TranscriptIndex(document: document, project: .multicam(project))
        project.mixLanes = []
        let original = try TranscriptIndex(document: document, project: .multicam(project))
        XCTAssertEqual(follow.readAll(space: .currentCut).map(\.id), original.readAll(space: .currentCut).map(\.id))
    }

    func testReplacementTrackIsPlacedIndependentlyForEachBindingAndAlignmentInvalidatesMatches() throws {
        let first = MulticamAudioReplacement(id: "left-dub", original: .init(source: "left", stream: 0),
                                             replacement: .init(source: "dub", stream: 1), relativeOffset: t(1),
                                             uncovered: .leaveUncovered)
        let second = MulticamAudioReplacement(id: "right-dub", original: .init(source: "right", stream: 0),
                                              replacement: first.replacement, relativeOffset: t(2),
                                              uncovered: .leaveUncovered)
        var project = MulticamProject(referenceAngle: "left", range: r(0, 8), angles: [
            .init(id: "left", file: "left.mov", audioStream: 0),
            .init(id: "right", file: "right.mov", offset: t(2), audioStream: 0)
        ], audioSources: [.init(id: "dub", file: "dub.wav", offset: t(7))], audio: .mix,
            switches: [.init(at: .zero, angle: "left")], mixLanes: [
                .init(id: "left-lane", target: .camera("left"), label: "Left", colorSlot: 0),
                .init(id: "right-lane", target: .camera("right"), label: "Right", colorSlot: 1)
            ], audioReplacements: [first, second])
        let tracks = [
            TranscriptTrack(id: TranscriptJobPlan.replacementTrackID(first), name: "Left",
                            sourceID: "dub", streamIndex: 1, sessionStart: t(1)),
            TranscriptTrack(id: TranscriptJobPlan.replacementTrackID(second), name: "Right",
                            sourceID: "dub", streamIndex: 1, sessionStart: t(4))
        ]
        let document = TranscriptDocument(clock: .session, tracks: tracks, words: tracks.map { track in
            .init(id: track.name, text: "clap", start: t(1), end: t(2), observations: [
                .init(trackID: track.id, start: t(1), end: t(2), evidence: .recognized)
            ])
        }, jobID: "test-job")
        let index = try TranscriptIndex(document: document, project: .multicam(project))
        let cutWords = index.readAll(space: .currentCut)
        XCTAssertEqual(cutWords.map(\.range), [r(2, 3), r(5, 6)])
        XCTAssertEqual(cutWords.map(\.sourceRange), [r(1, 2), r(1, 2)])
        XCTAssertEqual(cutWords.map(\.laneID), ["left-lane", "right-lane"])
        XCTAssertEqual(cutWords.map(\.routedSourceID), ["dub", "dub"])
        XCTAssertTrue(cutWords.allSatisfy { !$0.staleMatches })
        XCTAssertEqual(project.transcriptLane(sourceID: "dub", streamIndex: 1, trackID: "0:\(tracks[1].id)")?.id,
                       "right-lane")

        project.audioReplacements[1].relativeOffset = t(3)
        let adjusted = try TranscriptIndex(document: document, project: .multicam(project))
        XCTAssertEqual(adjusted.readAll(space: .currentCut).map(\.range), [r(2, 3), r(6, 7)])
        XCTAssertTrue(adjusted.readAll(space: .currentCut).allSatisfy(\.staleMatches))

        var approximate = document
        approximate.approximateClock = true
        project.audioReplacements[1].relativeOffset = try t(2).adding(.init(numerator: 1, denominator: 48_000))
        let sampleAdjustment = try TranscriptIndex(document: approximate, project: .multicam(project))
        XCTAssertTrue(sampleAdjustment.readAll(space: .currentCut).allSatisfy(\.staleMatches))
    }

    func testReplacementAudioSelectsTheIndexedOrdinalAndPreservesOtherStreams() throws {
        let tracks = [
            TranscriptTrack(id: "removed", name: "Old dialogue", streamIndex: 5),
            TranscriptTrack(id: "kept", name: "Room", streamIndex: 7),
            TranscriptTrack(id: "dub", name: "New dialogue", streamIndex: 3)
        ]
        let words = tracks.map { track in
            TranscriptWord(id: track.id, text: track.name, start: t(1), end: t(2), observations: [
                .init(trackID: track.id, start: t(1), end: t(2), evidence: .recognized)
            ])
        }
        let document = TranscriptDocument(clock: .presentation, tracks: tracks, words: words)
        let bindings = [
            TranscriptBinding(trackID: "removed", file: "original.mov", streamIndex: 5, sequenceStreamOrdinal: 0),
            TranscriptBinding(trackID: "kept", file: "original.mov", streamIndex: 7, sequenceStreamOrdinal: 1),
            TranscriptBinding(trackID: "dub", file: "replacement.mov", streamIndex: 3, sequenceStreamOrdinal: 0)
        ]
        let project = CutProject.sequence([
            .init(id: "clip", file: "replacement.mov", from: .zero, to: t(4),
                  audioTrack: 0, originalFile: "original.mov")
        ])
        let index = try TranscriptIndex(document: document, attachment: attachment(bindings), project: project)
        XCTAssertEqual(index.locate(wordID: "removed", space: .source).count, 1)
        XCTAssertTrue(index.locate(wordID: "removed", space: .currentCut).isEmpty)
        XCTAssertEqual(index.locate(wordID: "kept", space: .currentCut).map(\.range), [r(1, 2)])
        XCTAssertEqual(index.locate(wordID: "dub", space: .currentCut).map(\.range), [r(1, 2)])
    }

    func testSessionPartClockSubtractsItsStartOnceAndKeepsAmbiguity() throws {
        let document = TranscriptDocument(clock: .session, tracks: [
            .init(id: "part1", name: "Part 1", sessionStart: .zero),
            .init(id: "part2", name: "Part 2", sessionStart: t(60))
        ], words: [
            .init(id: "unique", text: "hello", start: t(65), end: t(66), candidateTrackIDs: ["part2"]),
            .init(id: "ambiguous", text: "overlap", start: t(67), end: t(68), candidateTrackIDs: ["part1", "part2"])
        ])
        let index = try TranscriptIndex(document: document)
        XCTAssertEqual(index.locate(wordID: "unique", space: .source).first?.range, r(5, 6))
        XCTAssertEqual(index.locate(wordID: "unique", space: .group).first?.range, r(65, 66))
        let ambiguous = try XCTUnwrap(index.locate(wordID: "ambiguous", space: .source).first)
        XCTAssertEqual(ambiguous.range, r(67, 68))
        XCTAssertEqual(ambiguous.candidateTrackIDs, ["part1", "part2"])
        XCTAssertNil(ambiguous.sourceRange)
    }

    func testChangedMediaKeepsOriginalWordsButClearsCutProjection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("camera.mov")
        let projectURL = folder.appendingPathComponent("project.cut")
        try Data([1]).write(to: media)
        let project = CutProject.sequence([.init(id: "clip", file: "camera.mov", from: .zero, to: t(4))])
        let binding = TranscriptBinding(trackID: "mic", file: "camera.mov", streamIndex: 1)
            .stamped(in: project, relativeTo: projectURL, confirmed: true)
        try Data([2, 3]).write(to: media)
        let document = TranscriptDocument(clock: .presentation,
            tracks: [.init(id: "mic", name: "Mic", streamIndex: 1)],
            words: [.init(id: "word", text: "Original", start: t(1), end: t(2))])
        let index = try TranscriptIndex(document: document, attachment: attachment([binding]),
                                        project: project, projectURL: projectURL)
        XCTAssertEqual(index.locate(wordID: "word", space: .source).first?.bindingStatus, .changed)
        XCTAssertTrue(index.locate(wordID: "word", space: .currentCut).isEmpty)
        XCTAssertEqual(index.gaps.map(\.reason), [.changed])
    }

    func testRefreshedMediaWithTheSameIndexedAudioKeepsTheBinding() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("mic.wav")
        let projectURL = folder.appendingPathComponent("project.cut")
        let wav = silentWAV()
        try wav.write(to: media)
        let engine = CutEngine(useSidecar: false)
        let original = try engine.inspect(media, keyframes: true)
        let stream = try XCTUnwrap(original.audio.first?.stream.index)
        let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: original, streamIndex: stream))
        let project = CutProject.sequence([.init(id: "clip", file: "mic.wav", from: .zero, to: t(1))])
        let binding = TranscriptBinding(trackID: "mic", file: "mic.wav", streamIndex: stream)
            .stamped(in: project, relativeTo: projectURL, confirmed: true)
        try wav.write(to: media, options: .atomic)
        let track = TranscriptTrack(id: "mic", name: "Mic", streamIndex: stream, streamEvidence: .string(evidence))
        let refreshed = try engine.inspect(media, keyframes: true)

        XCTAssertEqual(binding.sourceStatus(in: project, relativeTo: projectURL), .changed)
        XCTAssertEqual(binding.sourceStatus(in: project, relativeTo: projectURL, track: track,
                                            indexedMedia: original), .changed)
        XCTAssertEqual(binding.sourceStatus(in: project, relativeTo: projectURL, track: track,
                                            indexedMedia: refreshed), .available)
        let transcript = TranscriptDocument(clock: .presentation, tracks: [track],
            words: [.init(id: "word", text: "Identical", start: .zero, end: RationalTime(numerator: 1, denominator: 2))])
        let index = try TranscriptIndex(document: transcript, attachment: attachment([binding]), project: project,
                                        projectURL: projectURL, sequenceMedia: ["mic.wav": refreshed])
        XCTAssertEqual(index.locate(wordID: "word", space: .currentCut).first?.bindingStatus, .available)
    }

    func testSourceTextUsesReferencedLocalRecognitionWhenObservationHasNoText() throws {
        let track = TranscriptTrack(id: "mic", name: "Mic", words: [
            .init(id: "local", text: "Actual microphone wording", start: t(1), end: t(2), speakerID: "s"),
            .init(id: "other", text: "Unmerged aside", start: t(3), end: t(4), speakerID: "s", confidence: 0.8)
        ], speakers: [.init(id: "s", name: "Local speaker")])
        let document = TranscriptDocument(clock: .session, tracks: [track], speakers: [
            .init(id: "s", name: "Session speaker")
        ], words: [
            .init(id: "canonical", text: "Conversation wording", start: t(1), end: t(2), speakerID: "s",
                  observations: [.init(trackID: "mic", wordID: "local", start: t(1), end: t(2), evidence: .recognized)])
        ])
        let index = try TranscriptIndex(document: document)
        let source = index.read(space: .source).items
        XCTAssertEqual(source.map(\.text), ["Actual microphone wording", "Unmerged aside"])
        XCTAssertEqual(source.last?.observation?.wordID, "other")
        XCTAssertNotEqual(source.last?.speakerID, "s")
        XCTAssertEqual(index.speakers.first { $0.id == source.last?.speakerID }?.name, "Local speaker")
        XCTAssertEqual(index.read(space: .group).items.map(\.text), ["Conversation wording"])
        let exported = try TranscriptCodec.encode(index, space: .source, format: .json)
        let projected = try TranscriptCodec.decode(exported, format: .json)
        XCTAssertEqual(projected.words.first { $0.text == "Unmerged aside" }?.confidence, 0.8)
    }

    private func silentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let payload = Data(repeating: 0, count: Int(sampleRate) * 2)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            data.append(withUnsafeBytes(of: &littleEndian) { Data($0) })
        }
        append(UInt32(payload.count + 36))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(payload.count))
        data.append(payload)
        return data
    }

    func testExactSessionAlignmentBecomesStaleAfterQuarterSampleOffset() throws {
        let track = TranscriptTrack(id: "mic", name: "Mic", sourceID: "cam", streamIndex: 1)
        let word = TranscriptWord(id: "word", text: "Hello", start: t(1), end: t(2), observations: [
            .init(trackID: track.id, start: t(1), end: t(2), evidence: .recognized)
        ])
        var document = TranscriptDocument(clock: .session, tracks: [track], words: [word], jobID: "native")
        let offset = RationalTime(numerator: 1, denominator: 64_000)
        let project = MulticamProject(referenceAngle: "cam", range: r(0, 5),
            angles: [.init(id: "cam", file: "camera.mov", offset: offset, audioStream: 1)],
            audio: .follow, switches: [.init(at: .zero, angle: "cam")])
        let exact = try TranscriptIndex(document: document, project: .multicam(project))
        XCTAssertEqual(exact.locate(wordID: "word", space: .group).first?.staleMatches, true)
        document.approximateClock = true
        let approximate = try TranscriptIndex(document: document, project: .multicam(project))
        XCTAssertEqual(approximate.locate(wordID: "word", space: .group).first?.staleMatches, false)
    }

    func testIndexedFLACPacketHoleClipsWordsAndSeparatesPhrase() throws {
        try checkPacketHole(codec: "flac")
    }

    func testIndexedPCMPacketHoleSurvivesSidecarAndSeparatesPhrase() throws {
        try checkPacketHole(codec: "pcm_s16le")
    }

    func testSourceAndGroupLocateOffAirCoverageWithoutIndexingWords() throws {
        try checkPacketHole(codec: "pcm_s16le", verifyInputCoverage: true)
    }

    private func checkPacketHole(codec: String, verifyInputCoverage: Bool = false) throws {
        let paths = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("The packet timing fixture requires ffmpeg.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("gap.mka")
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                             "sine=frequency=440:sample_rate=48000:duration=3",
                             "-af", "aselect='not(between(t,0.4,1.6))'", "-c:a", codec, media.path]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        let fresh = try CutEngine(useSidecar: false).inspect(media, keyframes: true)
        let sidecar = AnalysisSidecar(media: fresh)
        try sidecar.save(AnalysisSidecar.indexSections(for: fresh))
        let indexed = try XCTUnwrap(sidecar.loadIndex(detail: .full, cancelled: { false }))
        if codec == "pcm_s16le" {
            XCTAssertTrue(indexed.audio.first?.packets.isEmpty == true)
            XCTAssertEqual(indexed.audio.first?.pcmGaps.count, 1)
        }
        let stream = try XCTUnwrap(indexed.audio.first?.stream.index)
        if verifyInputCoverage {
            let silentURL = folder.appendingPathComponent("silent.mov")
            let silentCamera = Process()
            silentCamera.executableURL = command.executableURL
            silentCamera.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                                      "color=size=64x64:rate=25:duration=2", "-c:v", "mpeg4", silentURL.path]
            try silentCamera.run()
            silentCamera.waitUntilExit()
            XCTAssertEqual(silentCamera.terminationStatus, 0)
            let silent = try CutEngine(useSidecar: false).inspectMulticamSource(silentURL)
            try checkInputCoverage(indexed, stream: stream, silent: silent)
            return
        }
        let track = TranscriptTrack(id: "mic", name: "Mic", streamIndex: stream)
        let document = TranscriptDocument(clock: .presentation, tracks: [track], words: [
            .init(id: "before", text: "red", start: .init(numerator: 1, denominator: 10), end: .init(numerator: 2, denominator: 10)),
            .init(id: "inside", text: "hole", start: .init(numerator: 9, denominator: 10), end: .init(numerator: 11, denominator: 10)),
            .init(id: "after", text: "apple", start: t(2), end: .init(numerator: 21, denominator: 10))
        ])
        let project = CutProject.sequence([.init(id: "clip", file: media.path, from: .zero, to: indexed.duration)])
        let binding = TranscriptBinding(trackID: track.id, file: media.path, streamIndex: stream)
        let index = try TranscriptIndex(document: document, attachment: attachment([binding]), project: project,
                                        sequenceMedia: [media.path: indexed])
        XCTAssertTrue(index.locate(wordID: "inside", space: .currentCut).isEmpty)
        XCTAssertEqual(index.locate(wordID: "inside", space: .source).count, 1)
        XCTAssertEqual(index.read(space: .currentCut).items.map(\.wordID), ["before", "after"])
        XCTAssertEqual(index.search("red apple", space: .currentCut).total, 0)
        XCTAssertEqual(index.gaps.filter { $0.reason == .unavailable }.count, 1)
        XCTAssertTrue(index.gaps.contains { $0.reason == .unavailable && $0.range.contains(t(1)) })
    }

    private func checkInputCoverage(_ indexed: MediaInfo, stream: Int, silent: MediaInfo) throws {
        let file = indexed.url.path
        let gap = try XCTUnwrap(indexed.audio.first?.pcmGaps.first)
        let project = MulticamProject(referenceAngle: "main", range: r(0, 8),
            angles: [.init(id: "main", file: file, audioStream: stream),
                     .init(id: "off", file: file, offset: t(3), audioStream: stream),
                     .init(id: "mute", file: silent.url.path, offset: t(1))],
            audioSources: [.init(id: "bad", file: file), .init(id: "missing", file: "unknown.wav")],
            audio: .follow, switches: [.init(at: .zero, angle: "main")])
        let document = TranscriptDocument(clock: .session, tracks: [
            .init(id: "main-mic", name: "Main", sourceID: "main", streamIndex: stream),
            .init(id: "off-mic", name: "Late off-air mic", sourceID: "off", streamIndex: stream, coverage: .skipped),
            .init(id: "bad-mic", name: "Failed mic", sourceID: "bad", streamIndex: stream, coverage: .failed),
            .init(id: "missing-mic", name: "Missing", sourceID: "missing", streamIndex: stream,
                  coverage: .failed, activity: [.init(start: .zero, end: t(1), level: 0)], error: "Missing audio"),
            .init(id: "silent", name: "Silent camera", sourceID: "mute", coverage: .coverageOnly)
        ], words: [.init(id: "word", text: "Hello", start: .zero, end: t(1))])
        let bindings = document.tracks.filter { $0.coverage != .coverageOnly }.map {
            TranscriptBinding(trackID: $0.id, sourceID: $0.sourceID, streamIndex: stream)
        }
        let index = try TranscriptIndex(document: document, attachment: attachment(bindings), project: .multicam(project),
                                        multicamMedia: ["main": indexed, "off": indexed, "bad": indexed, "mute": silent],
                                        spaces: [])
        XCTAssertTrue(index.read(space: .source).items.isEmpty)
        XCTAssertTrue(index.read(space: .currentCut).items.isEmpty)
        let source = try index.inputCoverage(space: .source, filter: .init(sourceID: "off"), limit: 1)
        XCTAssertEqual(source.tracks.items.first?.coverage, .skipped)
        XCTAssertEqual(source.tracks.items.first?.bounds?.from, .zero)
        XCTAssertEqual(source.gaps.total, 3)
        XCTAssertEqual(source.gaps.nextOffset, 1)
        let sourceHole = try index.inputCoverage(space: .source, filter: .init(trackID: "off-mic"), offset: 1, limit: 1)
        XCTAssertEqual(sourceHole.gaps.items.first?.range, gap)
        XCTAssertEqual(sourceHole.gaps.items.first?.trackID, "off-mic")
        XCTAssertEqual(sourceHole.gaps.items.first?.reason, .unavailable)
        let grouped = TranscriptProjectIndex(indexes: [index], space: .group)
        let group = try grouped.inputCoverage(filter: .init(trackID: "off-mic"), limit: 4)
        XCTAssertEqual(group.tracks.items.first?.bounds?.from, t(3))
        XCTAssertEqual(group.gaps.items.first?.range, r(0, 3))
        XCTAssertTrue(group.gaps.items.contains { $0.reason == .unavailable && $0.range.contains(t(4)) })
        let failed = try grouped.inputCoverage(filter: .init(trackID: "bad-mic"), limit: 3)
        XCTAssertTrue(failed.gaps.items.contains { $0.reason == .failed })
        let unknown = try grouped.inputCoverage(filter: .init(trackID: "missing-mic"))
        XCTAssertNil(unknown.tracks.items.first?.bounds)
        XCTAssertEqual(unknown.tracks.items.first?.message, "Missing audio")
        XCTAssertTrue(unknown.gaps.items.isEmpty)
        let silentCamera = try grouped.inputCoverage(filter: .init(trackID: "silent"))
        XCTAssertEqual(silentCamera.tracks.items.first?.coverage, .coverageOnly)
        XCTAssertEqual(silentCamera.gaps.items.first { $0.reason == .silence }?.range, r(1, 3))
        let independentPage = try grouped.inputCoverage(offset: 1, limit: 1, trackOffset: 2, trackLimit: 1)
        XCTAssertEqual(independentPage.gaps.items.count, 1)
        XCTAssertEqual(independentPage.tracks.items.first?.trackID, "bad-mic")
        XCTAssertEqual(independentPage.tracks.nextOffset, 3)
    }

    func testRepeatedReplacementRoutesAllReplacedOrdinalsToWorkingCopy() throws {
        let tracks: [(String, String, Int, Int)] = [
            ("old0", "original.mov", 1, 0), ("old1", "original.mov", 3, 1),
            ("kept", "original.mov", 5, 2), ("dub0", "copy.mov", 2, 0),
            ("dub1", "copy.mov", 4, 1), ("copied", "copy.mov", 6, 2),
            ("workingOnly", "copy.mov", 7, 3)
        ]
        let bindings = tracks.map { TranscriptBinding(trackID: $0.0, file: $0.1, streamIndex: $0.2, sequenceStreamOrdinal: $0.3) }
        let document = TranscriptDocument(clock: .presentation, tracks: tracks.map {
            .init(id: $0.0, name: $0.0, streamIndex: $0.2)
        }, words: tracks.map {
            .init(id: $0.0, text: $0.0, start: t(1), end: t(2), observations: [
                .init(trackID: $0.0, start: t(1), end: t(2), evidence: .recognized)
            ])
        })
        let project = CutProject.sequence([
            .init(id: "clip", file: "copy.mov", from: .zero, to: t(5), audioTrack: 1,
                  originalFile: "original.mov", replacementNames: [0: "earlier.m4a", 1: "latest.m4a"])
        ])
        let index = try TranscriptIndex(document: document, attachment: attachment(bindings), project: project)
        XCTAssertEqual(Set(index.read(space: .currentCut).items.map(\.wordID)), ["dub0", "dub1", "kept", "workingOnly"])
    }

    func testPhraseSearchBreaksAtRecordingGapButContinuesAcrossAdjacentEdits() throws {
        let track = TranscriptTrack(id: "mic", name: "Mic")
        let document = TranscriptDocument(clock: .presentation, tracks: [track], words: [
            .init(id: "red", text: "red", start: t(1), end: t(2), utteranceID: "first"),
            .init(id: "apple", text: "apple", start: t(3_601), end: t(3_602), utteranceID: "second")
        ])
        let binding = TranscriptBinding(trackID: track.id, file: "mic.wav", streamIndex: 1, sequenceStreamOrdinal: 0)
        let project = CutProject.sequence([
            .init(id: "clip-1", file: "mic.wav", from: t(1), to: t(2)),
            .init(id: "clip-2", file: "mic.wav", from: t(3_601), to: t(3_602))
        ])
        let index = try TranscriptIndex(document: document, attachment: attachment([binding]), project: project)
        XCTAssertEqual(index.search("red apple", space: .source).total, 0)
        XCTAssertEqual(index.search("red apple", space: .currentCut).items.first?.words.map(\.clipID), ["clip-1", "clip-2"])
    }

    func testMultiHourLookupAndPaging() throws {
        let count = 36_000
        let terms = ["the", "long", "interview", "runs", "for", "hours"]
        let document = TranscriptDocument(clock: .presentation,
            tracks: [.init(id: "mic", name: "Mic", streamIndex: 1),
                     .init(id: "backup", name: "Backup", streamIndex: 2)],
            words: (0..<count).map { index in
                let start = RationalTime(numerator: Int64(index), denominator: 3)
                let end = RationalTime(numerator: Int64(index + 1), denominator: 3)
                let track = index < count / 2 ? "mic" : "backup"
                return .init(id: String(index), text: terms[index % terms.count], start: start, end: end,
                             observations: [.init(trackID: track, start: start, end: end, evidence: .recognized)])
            })
        let bindings = [
            TranscriptBinding(trackID: "mic", file: "movie.mov", streamIndex: 1),
            TranscriptBinding(trackID: "backup", file: "movie.mov", streamIndex: 2)
        ]
        let project = CutProject.sequence([.init(id: "one", file: "movie.mov", from: .zero, to: t(12_000))])
        let start = ContinuousClock.now
        let index = try TranscriptIndex(document: document, attachment: attachment(bindings), project: project)
        let indexed = ContinuousClock.now
        let hits = index.search("Long interview", space: .currentCut, offset: 5_999, limit: 1)
        let found = ContinuousClock.now
        XCTAssertEqual(hits.total, 6_000)
        XCTAssertEqual(hits.items.first?.words.map(\.wordID), ["35995", "35996"])
        XCTAssertEqual(index.read(space: .currentCut, offset: 35_995, limit: 5).items.count, 5)
        XCTAssertEqual(index.locate(wordID: "35999", space: .currentCut).count, 1)
        XCTAssertEqual(index.position(at: t(11_999), space: .currentCut), 35_997)
        let paged = ContinuousClock.now
        print("Transcript index (36,000 words): build \(start.duration(to: indexed)), phrase search \(indexed.duration(to: found)), page and locate \(found.duration(to: paged))")
    }
}
