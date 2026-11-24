import XCTest
@testable import MPCutCore

final class TileFeedAttachmentsTests: XCTestCase {
    private let voice = ParticipantSpeakerBinding(attachmentID: "conversation", speakerID: "voice")
    private let microphone = MulticamAudioSelection(source: "mic", stream: 1)

    private func index(name: String, role: TranscriptRole = .isolatedMic,
                       secondName: String? = nil) throws -> TranscriptIndex {
        var speakers = [TranscriptSpeaker(id: voice.speakerID, name: name)]
        if let secondName { speakers.append(.init(id: "other", name: secondName)) }
        let end = RationalTime(numerator: 2)
        let document = TranscriptDocument(clock: .presentation,
            tracks: [.init(id: "track", name: "Microphone", role: role)], speakers: speakers,
            words: [.init(id: "word", text: "Hello", start: .zero, end: end, speakerID: voice.speakerID,
                          observations: [.init(trackID: "track", start: .zero, end: end, evidence: .recognized)])])
        let attachment = TranscriptAttachment(id: voice.attachmentID,
            asset: .init(file: "call.json", sha256: String(repeating: "0", count: 64)),
            bindings: [.init(trackID: "track", sourceID: microphone.source, streamIndex: microphone.stream)])
        return try TranscriptIndex(document: document, attachment: attachment)
    }

    private func project(_ feeds: [ParticipantPerson]) -> MulticamProject {
        let camera = MulticamSource(id: "cam", file: "/call.mov", offset: .zero, name: "Call")
        let angles = feeds.map { feed in
            MulticamSource(id: "angle-\(feed.id)", file: camera.file, offset: camera.offset, name: feed.name,
                           feedAngle: .init(sourceID: camera.id, feedID: feed.id))
        }
        return .init(referenceAngle: camera.id, range: .init(from: .zero, to: .init(numerator: 10)),
                     angles: [camera] + angles, audioSources: [
                        .init(id: microphone.source, file: "/mic.wav", offset: .zero, name: "María Silva", audioStream: microphone.stream)
                     ], audio: .none, switches: [.init(at: .zero, angle: camera.id)],
                     participants: .init(people: feeds))
    }

    func testNamedMicrophoneRoutesVoiceThroughFeedWithoutMatchingVoiceName() throws {
        let feed = ParticipantPerson(id: "maria", name: "  Maria   Silva ")
        let project = project([feed])
        let transcript = try index(name: "Speaker 1")
        XCTAssertEqual(TileFeedAttachments.microphone(for: feed, in: project), microphone)
        XCTAssertEqual(TileFeedAttachments.voices(in: project, indexes: [transcript]), [voice: feed.id])
        XCTAssertEqual(TileSwitches.links(in: project, indexes: [transcript]), [.init(voice: voice, angleID: "angle-maria")])
    }

    func testSameNameOnTwoFeedsOrTwoVoicesRequiresManualAttachment() throws {
        let first = ParticipantPerson(id: "a", name: "María Silva")
        var second = ParticipantPerson(id: "b", name: "maria silva")
        let transcript = try index(name: "MARIA SILVA", role: .mixedAudio)
        var current = project([first, second])
        XCTAssertNil(TileFeedAttachments.microphone(for: first, in: current))
        XCTAssertTrue(TileSwitches.links(in: current, indexes: [transcript]).isEmpty)

        second.speakers = [voice]
        current = project([first, second])
        XCTAssertEqual(TileSwitches.links(in: current, indexes: [transcript]), [.init(voice: voice, angleID: "angle-b")])

        let duplicateVoice = try index(name: "Maria Silva", role: .mixedAudio, secondName: "María Silva")
        XCTAssertTrue(TileSwitches.links(in: project([first]), indexes: [duplicateVoice]).isEmpty)
    }

    func testManualVoiceBeatsMicrophoneAndManualAngleBeatsFeed() throws {
        let microphoneFeed = ParticipantPerson(id: "maria", name: "Maria Silva")
        let boundFeed = ParticipantPerson(id: "person", name: "Another Name", speakers: [voice])
        let transcript = try index(name: "Maria Silva")
        var group = project([microphoneFeed, boundFeed])
        XCTAssertEqual(TileSwitches.links(in: group, indexes: [transcript]), [.init(voice: voice, angleID: "angle-person")])
        group.speakerAngles = [.init(voice: voice, angleID: "cam")]
        XCTAssertEqual(TileSwitches.links(in: group, indexes: [transcript]), [.init(voice: voice, angleID: "cam")])
    }

    func testMixedTrackCannotIdentifyFeedThroughMicrophone() throws {
        let project = project([.init(id: "maria", name: "Maria Silva")])
        let transcript = try index(name: "Speaker 1", role: .mixedAudio)
        XCTAssertTrue(TileSwitches.links(in: project, indexes: [transcript]).isEmpty)
    }

    func testProposalsUseDelayedPictureClockAndRespectAssemblyCoverage() throws {
        func t(_ frames: Int64) -> RationalTime { .init(numerator: frames * 1001, denominator: 30_000) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures")
        let documentURL = fixtures.appendingPathComponent("conversation.cut")
        let file = "Multicam-Delayed-ProRes.mov"
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixtures.appendingPathComponent(file))
        XCTAssertEqual(media.multicamClockOffset, t(6))
        let second = ParticipantSpeakerBinding(attachmentID: voice.attachmentID, speakerID: "alias")
        let feed = ParticipantPerson(id: "maria", name: "Maria Silva", speakers: [voice, second])
        var group = project([feed])
        group.range.to = t(20)
        group.angles[0].file = file
        group.angles[0].offset = t(2)
        group.syncFeedAngleRecordings()
        group.participants.sources = [.init(sourceID: "cam", appearances: [
            .init(id: "visible", participantID: feed.id, range: .init(from: t(4), to: t(6)),
                  bounds: .init(x: 0, y: 0, width: 1, height: 1))
        ])]
        group.assemblyItems = [
            .group(.init(from: .zero, to: t(19)), angle: "cam", id: "pinned"),
            .group(.init(from: t(9), to: t(16)), id: "switchable")
        ]
        let document = TranscriptDocument(clock: .session, tracks: [.init(id: "track", name: "Audio")],
            speakers: [.init(id: voice.speakerID, name: "Original"), .init(id: second.speakerID, name: "Alias")],
            words: [voice, second].map { speaker in
                .init(id: speaker.speakerID, text: "Speech", start: t(5), end: t(15), speakerID: speaker.speakerID,
                      observations: [.init(trackID: "track", start: t(5), end: t(15), evidence: .recognized)])
            })
        let attachment = TranscriptAttachment(id: voice.attachmentID,
            asset: .init(file: "call.json", sha256: String(repeating: "0", count: 64)), bindings: [])
        let index = try TranscriptIndex(document: document, attachment: attachment)
        let proposals = try TileSwitches.propose(in: group, document: documentURL, indexes: [index], minimumHold: t(1), useSidecar: false)
        XCTAssertEqual(proposals.map(\.at), [t(12)])
        XCTAssertEqual(proposals.map(\.angleID), ["angle-maria"])
        let coverage = try group.switchCoverage(at: t(12), angle: "angle-maria", media: ["cam": media])
        XCTAssertEqual(coverage.picture.status, .gaps)
        XCTAssertEqual(coverage.picture.missing, [.init(from: t(14), to: t(20))])
        let indexed = try TranscriptIndex(document: document, attachment: attachment, project: .multicam(group),
                                          projectURL: documentURL, multicamMedia: ["cam": media])
        XCTAssertEqual(try TileSwitches.propose(in: group, document: documentURL, indexes: [indexed], minimumHold: t(1),
                                               useSidecar: false), proposals)
        let cameraOff = MulticamRange(from: t(4), to: t(5))
        group.participants.sources[0].appearances.append(.init(id: "camera-off", participantID: feed.id, range: cameraOff,
            bounds: .init(x: 0, y: 0, width: 1, height: 1), state: .cameraOff))
        group.participants.appearanceOverrides = [.init(participantID: feed.id, sourceID: "cam", appearanceID: "camera-off",
                                                       range: cameraOff)]
        XCTAssertEqual(try TileSwitches.propose(in: group, document: documentURL, indexes: [index], minimumHold: t(1),
                                               useSidecar: false).map(\.at), [t(13)])
        group.assemblyItems?.removeLast()
        XCTAssertTrue(try TileSwitches.propose(in: group, document: documentURL, indexes: [index], minimumHold: t(1),
                                              useSidecar: false).isEmpty)
    }
}
