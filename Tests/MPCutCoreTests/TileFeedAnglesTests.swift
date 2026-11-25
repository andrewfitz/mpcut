import Foundation
import MPCutCore
import XCTest

final class TileFeedAnglesTests: XCTestCase {
    func testFeedAngleRetainsParentAndConvertsSoloToSwitch() throws {
        let one = RationalTime(numerator: 1)
        let two = RationalTime(numerator: 2)
        let three = RationalTime(numerator: 3)
        let range = MulticamRange(from: .zero, to: three)
        let solo = TileLayoutSpan(range: .init(from: one, to: two), layout: .solo, slots: [.init(id: "alice")])
        let physical = MulticamSource(id: "gallery", file: "call.mov", name: "Gallery", audioStream: 1, coverage: range)
        let members = ParticipantProject(
            people: [.init(id: "alice", name: "Alice")],
            sources: [.init(sourceID: "gallery", appearances: [
                .init(id: "tile", participantID: "alice", range: range,
                      bounds: .init(x: 0, y: 0, width: 0.5, height: 0.5))
            ])]
        )
        let project = MulticamProject(referenceAngle: "gallery", range: range, angles: [physical], audio: .follow,
                                      switches: [.init(at: .zero, angle: "gallery")], participants: members,
                                      groupTileLayouts: [solo])
        let updated = try TileFeedAngles.usingFeeds(in: .multicam(project),
                                                  document: URL(fileURLWithPath: "/tmp/example.cut"), sourceID: "gallery")
        XCTAssertEqual(updated.angles[1].feedAngle, TileFeedAngle(sourceID: "gallery", feedID: "alice"))
        XCTAssertEqual(updated.switches.map(\.angle), ["gallery", "feed-alice", "gallery"])
        XCTAssertTrue(updated.groupTileLayouts.isEmpty)
        XCTAssertEqual(try updated.plan().audio.map(\.source), ["gallery"])

        let data = try JSONEncoder().encode(updated)
        let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let angles = try XCTUnwrap(dictionary?["angles"] as? [[String: Any]])
        XCTAssertNil(angles[1]["file"])
        XCTAssertEqual(try JSONDecoder().decode(MulticamProject.self, from: data), updated)
    }

    func testRepeatedSequenceFootageRetainsItsOwnSoloAndMixedAudio() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures")
        let gallery = "Multicam-Delayed-PCM.mov"
        let insert = "ProRes-2997.mov"
        let excerpt = MulticamRange(from: .init(numerator: 3, denominator: 25), to: .init(numerator: 1, denominator: 5))
        let silent = RationalTime(numerator: 1001, denominator: 15_000)
        let style = TileLayoutSpan(range: excerpt, layout: .solo, slots: [.init(id: "alice")])
        let galleryPath = fixtures.appendingPathComponent(gallery).path
        let voice = ParticipantSpeakerBinding(attachmentID: "call", speakerID: "voice")
        let microphone = ParticipantAudioBinding(selection: .init(source: galleryPath, stream: 1))
        var sequence = CutProject.sequence([
            .init(id: "solo", file: gallery, from: excerpt.from, to: excerpt.to, tileLayouts: [style]),
            .init(id: "insert", file: insert, from: .zero, to: silent),
            .init(id: "repeat", file: gallery, from: excerpt.from, to: excerpt.to)
        ])
        sequence.participants = .init(people: [.init(id: "alice", name: "Alice", audio: microphone, speakers: [voice])], sources: [
            .init(sourceID: gallery, appearances: [.init(id: "tile", participantID: "alice", range: excerpt,
                                                       bounds: .init(x: 0, y: 0, width: 0.5, height: 0.5))])
        ])
        let digest = String(repeating: "0", count: 64)
        sequence.transcripts.attachments = [.init(id: voice.attachmentID,
            asset: .init(sha256: digest),
            bindings: [.init(trackID: "lav", file: galleryPath, streamIndex: 1)])]
        let converted = try TileFeedAngles.usingFeeds(in: sequence, document: fixtures.appendingPathComponent("review.cut"),
                                                      sourceID: gallery, useSidecar: false)
        XCTAssertEqual(converted.assemblyItems?.compactMap(\.occurrenceID), ["solo", "insert", "repeat"])
        XCTAssertEqual(converted.assemblyItems?.map(\.angleOverride), ["feed-alice", nil, nil])
        XCTAssertEqual(converted.audio, .mix)
        let performer = try XCTUnwrap(converted.participants.people.first)
        XCTAssertEqual(performer.speakers, [voice])
        XCTAssertEqual(TileFeedAttachments.microphone(for: performer, in: converted), .init(source: "recording-1", stream: 1))
        XCTAssertEqual(converted.transcripts.attachments.first?.bindings,
                       [.init(trackID: "lav", sourceID: "recording-1", streamIndex: 1)])
        let retained = try converted.plan()
        XCTAssertEqual(retained.intervals.map(\.angle), ["feed-alice", "recording-2", "recording-1"])
        let mono = try XCTUnwrap(retained.audioLanes.first)
        let length = try excerpt.to.subtracting(excerpt.from)
        XCTAssertEqual(mono.spans.map(\.input), [excerpt, excerpt])
        XCTAssertEqual(mono.spans.map(\.stream), [1, 1])
        XCTAssertEqual(mono.gaps, [.init(from: length, to: try length.adding(silent))])
    }

    func testConversionRefusesToSplitContinuousSequenceAudioTracksAcrossRecordings() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        var sequence = CutProject.sequence(["Pause-Quiet.mov", "Pause-Noisy.mov"].map {
            .init(id: $0, file: $0, from: range.from, to: range.to)
        })
        sequence.participants = .init(people: [.init(id: "alice", name: "Alice")], sources: [
            .init(sourceID: "Pause-Quiet.mov", appearances: [.init(id: "tile", participantID: "alice", range: range,
                                                                  bounds: .init(x: 0, y: 0, width: 1, height: 1))])
        ])
        XCTAssertThrowsError(try TileFeedAngles.usingFeeds(in: sequence, document: fixtures.appendingPathComponent("edit.cut"),
                                                          sourceID: "Pause-Quiet.mov", useSidecar: false)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_tile_feed_angle")
            XCTAssertTrue($0.localizedDescription.contains("multiple audio tracks"))
        }
    }

    func testConvertingSoloPreservesLayoutPrecedenceAndFollowingMicrophone() throws {
        let end = RationalTime(numerator: 3)
        let layoutRange = MulticamRange(from: .init(numerator: 1), to: .init(numerator: 2))
        let range = MulticamRange(from: .zero, to: end)
        let physical = MulticamSource(id: "gallery", file: "call.mov", name: "Gallery", audioStream: 1)
        let mic = MulticamAudioSelection(source: "mic", stream: 0)
        let alice = ParticipantPerson(id: "alice", name: "Alice", audio: .init(selection: mic))
        let bob = ParticipantPerson(id: "bob", name: "Bob")
        let appearances: [ParticipantAppearance] = [
            .init(id: "left", participantID: alice.id, range: range, bounds: .init(x: 0, y: 0, width: 0.5, height: 1)),
            .init(id: "right", participantID: bob.id, range: range, bounds: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        let members = ParticipantProject(people: [alice, bob], sources: [.init(sourceID: physical.id, appearances: appearances)])
        let solo = TileLayoutSpan(range: layoutRange, layout: .solo, slots: [.init(id: bob.id)])
        let original = TileLayoutSpan(range: layoutRange, layout: .original)
        let pair = TileLayoutSpan(range: layoutRange, layout: .pair, slots: [.init(id: alice.id), .init(id: bob.id)])
        let aliceAngle = MulticamSource(id: "feed-alice", file: physical.file, name: alice.name,
                                       feedAngle: .init(sourceID: physical.id, feedID: alice.id))
        let document = URL(fileURLWithPath: "/tmp/edit.cut")
        var group = MulticamProject(referenceAngle: physical.id, range: range, angles: [physical, aliceAngle],
                                    audioSources: [.init(id: mic.source, file: "mic.wav", audioStream: mic.stream)],
                                    audio: .follow, switches: [.init(at: .zero, angle: aliceAngle.id)],
                                    participants: members, groupTileLayouts: [solo])
        let global = try TileFeedAngles.usingFeeds(in: .multicam(group), document: document, sourceID: physical.id)
        XCTAssertEqual(global.switches.map(\.angle), [aliceAngle.id, "feed-bob", aliceAngle.id])
        XCTAssertEqual(try global.plan().audio, try group.plan().audio)

        var synced = group
        let scratch = MulticamAudioSelection(source: physical.id, stream: 1)
        let delay = RationalTime(numerator: 1, denominator: 2)
        synced.audioReplacements = [.init(id: "sync", original: scratch, replacement: mic,
                                          relativeOffset: delay, uncovered: .leaveUncovered)]
        let rerouted = try TileFeedAngles.usingFeeds(in: .multicam(synced), document: document, sourceID: physical.id)
        for version in [synced, rerouted] {
            let plan = try version.plan()
            let lanes = try version.resolveAudioLanes(plan: plan, indexedSources: [:], assumeUnindexedCoverage: true)
            let span = try XCTUnwrap(lanes.first?.spans.first)
            XCTAssertEqual(span.source, mic.source)
            XCTAssertEqual(span.input.from, try RationalTime.zero.subtracting(delay))
            XCTAssertEqual(span.replacementBindingID, "sync")
        }

        var oneOccurrence = group
        oneOccurrence.groupTileLayouts = []
        oneOccurrence.assemblyItems = [.group(range, id: "single", layouts: [solo])]
        let switched = try TileFeedAngles.usingFeeds(in: .multicam(oneOccurrence), document: document, sourceID: physical.id)
        XCTAssertEqual(switched.assemblyItems, [.group(range, id: "single")])
        XCTAssertEqual(switched.switches, global.switches)

        let later = MulticamRange(from: layoutRange.to, to: end)
        let laterLayout = TileLayoutSpan(range: later, layout: .pair, slots: pair.slots)
        oneOccurrence.assemblyItems = [.group(range, id: "single", layouts: [solo, laterLayout]),
                                      .group(layoutRange, id: "repeat")]
        let split = try TileFeedAngles.usingFeeds(in: .multicam(oneOccurrence), document: document, sourceID: physical.id)
        XCTAssertEqual(split.assemblyItems?.map(\.angleOverride), [nil, "feed-bob", nil, nil])
        XCTAssertEqual(split.assemblyItems?.map(\.tileLayouts), [[], [], [laterLayout], []])

        group.assemblyItems = [.group(range, id: "unmodified", layouts: [original])]
        let conflicting = try TileFeedAngles.usingFeeds(in: .multicam(group), document: document, sourceID: physical.id)
        XCTAssertEqual(conflicting.groupTileLayouts, [solo])
        XCTAssertEqual(conflicting.switches, group.switches)
        XCTAssertEqual(conflicting.assemblyItems?.first?.tileLayouts, [original])

        group.groupTileLayouts = [pair]
        group.assemblyItems = [.group(layoutRange, id: "styled", layouts: [solo]), .group(layoutRange, id: "replay")]
        let occurrence = try TileFeedAngles.usingFeeds(in: .multicam(group), document: document, sourceID: physical.id)
        XCTAssertEqual(occurrence.groupTileLayouts, [pair])
        XCTAssertEqual(occurrence.assemblyItems?.map(\.angleOverride), ["feed-bob", nil])
        XCTAssertEqual(occurrence.assemblyItems?.map(\.tileLayouts), [[original], []])

        var silent = group
        silent.angles = [MulticamSource(id: physical.id, file: physical.file)]
        silent.switches = [.init(at: .zero, angle: physical.id)]
        let soloWithMic = TileLayoutSpan(range: layoutRange, layout: .solo, slots: [.init(id: alice.id)])
        silent.groupTileLayouts = [soloWithMic]
        silent.assemblyItems = nil
        let quietGroup = try TileFeedAngles.usingFeeds(in: .multicam(silent), document: document, sourceID: physical.id)
        XCTAssertEqual(quietGroup.groupTileLayouts, [soloWithMic])
        XCTAssertTrue(try quietGroup.plan().audio.isEmpty)
        silent.groupTileLayouts = []
        silent.assemblyItems = [.group(layoutRange, id: "quiet", layouts: [soloWithMic])]
        let quietOccurrence = try TileFeedAngles.usingFeeds(in: .multicam(silent), document: document, sourceID: physical.id)
        XCTAssertEqual(quietOccurrence.assemblyItems?.first?.angleOverride, "feed-alice")
        XCTAssertTrue(try quietOccurrence.plan().audio.isEmpty)
    }
}
