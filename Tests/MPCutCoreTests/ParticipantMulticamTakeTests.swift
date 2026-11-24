import XCTest
@testable import MPCutCore

final class ParticipantMulticamTakeTests: XCTestCase {
    func testVirtualTakesPersistAndStayInOneOccurrence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("take.cut")
        var project = CutProject.sequence([
            .init(id: "first", file: "gallery.mov", from: .zero, to: time(4)),
            .init(id: "repeat", file: "gallery.mov", from: .zero, to: time(4)),
        ])
        let sourceRange = MulticamRange(from: .zero, to: time(4))
        project.participants = .init(
            people: [.init(id: "a", name: "A"), .init(id: "b", name: "B")],
            sources: [.init(sourceID: "gallery.mov")],
            render: .init(shots: [.init(layout: .original), .init(range: sourceRange, layout: .pair,
                                                                slots: [.init(id: "a"), .init(id: "b")])],
                          audio: .init(mode: .program)))
        let angles = try ParticipantMulticam.virtualAngles(project, sourceID: "gallery.mov", participantIDs: ["a", "b"],
                                                          range: sourceRange, includeOriginal: true)
        project = try ParticipantMulticam.taking(angles[0], at: time(1), in: project, document: document)
        project = try ParticipantMulticam.taking(angles[1], at: time(2), in: project, document: document)
        project = try ParticipantMulticam.taking(angles[2], at: time(3), in: project, document: document)
        try project.save(to: document)
        let reopened = try CutProject.load(from: document)
        let plan = try XCTUnwrap(reopened.participants.render)
        let scoped = plan.shots.filter { $0.occurrence == 0 }
        XCTAssertEqual(scoped.map(\.range), [
            .init(from: time(1), to: time(2)), .init(from: time(2), to: time(3)), .init(from: time(3), to: time(4))
        ])
        XCTAssertEqual(scoped.map(\.layout), [.solo, .solo, .original])
        XCTAssertEqual(scoped.map { $0.slots.first?.id }, ["a", "b", nil])
        XCTAssertEqual(plan.shots.filter { $0.occurrence == nil }.map(\.layout), [.original, .pair])
        XCTAssertEqual(plan.audio.mode, .program)

        let next = try ParticipantMulticam.taking(angles[1], at: time(5), in: reopened, document: document)
        XCTAssertEqual(next.participants.render?.shots.last?.occurrence, 1)
        XCTAssertEqual(next.participants.render?.shots.last?.range, .init(from: time(5), to: time(8)))
        XCTAssertEqual(next.participants.render?.shots.filter { $0.occurrence == 0 }, scoped)
        XCTAssertThrowsError(try ParticipantMulticam.taking(angles[1], at: time(8), in: next, document: document))
    }

    private func time(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
}
