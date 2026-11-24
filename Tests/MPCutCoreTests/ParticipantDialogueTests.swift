import XCTest
@testable import MPCutCore

final class ParticipantDialogueTests: XCTestCase {
    func testOverlapOffscreenAndRepeatedOccurrencesAreReviewable() throws {
        let (project, angles) = try fixture()
        let source = URL(fileURLWithPath: "/tmp/dialogue-fixture.cut")
        let repeated: [ParticipantDialogueLine] = [
            line("a", 0, 3), line("b", 1, 7), line("a", 8, 11), line("b", 9, 15),
        ]
        let unchanged = project.participants.render
        let held = try ParticipantDialogue.suggest(repeated, angles: angles, in: project, document: source)
        XCTAssertEqual(held.map(\.at), [time(0), time(5), time(8), time(13)])
        XCTAssertEqual(held.map(\.occurrence), [0, 0, 1, 1])
        XCTAssertEqual(held.map { $0.angle.id }, ["a", "b", "a", "b"])
        XCTAssertEqual(project.participants.render, unchanged)

        let gallery = try ParticipantDialogue.suggest(repeated, angles: angles, in: project, document: source,
                                                       options: .init(offscreen: .original))
        XCTAssertEqual(gallery.map(\.at), [time(0), time(3), time(5), time(8), time(11), time(13)])
        XCTAssertEqual(gallery.filter { $0.angle.kind == .original }.map(\.reason), [.offscreen, .offscreen])
        let reaction = try ParticipantDialogue.suggest([line("b", 3, 5)], angles: angles, in: project, document: source,
                                                        options: .init(offscreen: .reaction))
        XCTAssertEqual(reaction.map { $0.angle.id }, ["a"])
        XCTAssertEqual(reaction.map(\.reason), [.reaction])

        let accepted = try ParticipantDialogue.accepting(held[3], in: project, document: source)
        XCTAssertEqual(accepted.participants.render?.shots.last?.occurrence, 1)
        XCTAssertEqual(accepted.participants.render?.shots.last?.range, .init(from: time(13), to: time(16)))
        XCTAssertEqual(accepted.participants.render?.shots.last?.slots.first?.id, "b")
        XCTAssertEqual(accepted.participants.render?.audio.mode, .silence)
        XCTAssertEqual(project.participants.render, unchanged)
    }

    func testVisibleOverlapChoiceAndMinimumHold() throws {
        let (project, angles) = try fixture()
        let source = URL(fileURLWithPath: "/tmp/dialogue-fixture.cut")
        let simultaneous = [line("a", 1, 3), line("b", 1, 3)]
        XCTAssertTrue(try ParticipantDialogue.suggest(simultaneous, angles: angles, in: project, document: source).isEmpty)
        let proposals = try ParticipantDialogue.suggest(simultaneous.reversed(), angles: angles.reversed(),
                                                         in: project, document: source, options: .init(overlap: .visibleSpeaker))
        XCTAssertEqual(proposals.map { $0.angle.id }, ["b"])
        XCTAssertEqual(proposals.map(\.reason), [.overlap])
        XCTAssertTrue(try ParticipantDialogue.suggest([line("a", 0, 1)], angles: angles, in: project, document: source,
                                                       options: .init(minimumHold: time(2))).isEmpty)
    }

    private func fixture() throws -> (CutProject, [ParticipantVirtualAngle]) {
        let range = MulticamRange(from: .zero, to: time(8))
        var project = CutProject.sequence([
            .init(id: "first", file: "gallery.mov", from: .zero, to: time(8)),
            .init(id: "repeat", file: "gallery.mov", from: .zero, to: time(8)),
        ])
        let bounds = ParticipantBounds(x: 0, y: 0, width: 1, height: 1)
        project.participants = .init(
            people: ["a", "b"].map { .init(id: $0, name: $0.uppercased(), speakers: [.init(attachmentID: "recording", speakerID: $0)]) },
            sources: [.init(sourceID: "gallery.mov", appearances: [
                .init(id: "host", participantID: "a", range: range, bounds: bounds),
                .init(id: "guest", participantID: "b", range: .init(from: .zero, to: time(3)), bounds: bounds),
                .init(id: "guest", participantID: "b", range: .init(from: time(5), to: time(8)), bounds: bounds),
            ])],
            render: .init(shots: [.init(layout: .original)]))
        return (project, try ParticipantMulticam.virtualAngles(project, sourceID: "gallery.mov", participantIDs: ["a", "b"],
                                                               range: range, includeOriginal: true))
    }

    private func line(_ speaker: String, _ from: Int64, _ to: Int64) -> ParticipantDialogueLine {
        .init(speaker: .init(attachmentID: "recording", speakerID: speaker), range: .init(from: time(from), to: time(to)))
    }

    private func time(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
}
