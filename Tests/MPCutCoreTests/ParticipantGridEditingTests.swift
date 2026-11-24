@testable import MPCutCore
import XCTest

final class ParticipantGridEditingTests: XCTestCase {
    func testGridCorrectionKeepsMatchedPreferencesAndRequiresReviewOfDisplacedFeeds() throws {
        let source = "gallery.mov"
        let first = RationalTime(numerator: 1)
        let end = RationalTime(numerator: 2)
        let full = MulticamRange(from: .zero, to: end)
        let correction = MulticamRange(from: first, to: end)
        let left = ParticipantBounds(x: 0, y: 0, width: 0.45, height: 1)
        let right = ParticipantBounds(x: 0.5, y: 0, width: 0.45, height: 1)
        let fragment = ParticipantBounds(x: 0.55, y: 0.1, width: 0.15, height: 0.2)
        var project = ParticipantProject(
            people: [.init(id: "host", name: "Host"), .init(id: "guest", name: "Guest")],
            sources: [.init(sourceID: source, appearances: [
                .init(id: "host-tile", participantID: "host", range: full, bounds: left),
                .init(id: "guest-tile", participantID: "guest", range: full, bounds: right),
                .init(id: "fragment", range: full, bounds: fragment)
            ])], appearanceOverrides: [
                .init(participantID: "host", sourceID: source, appearanceID: "host-tile", range: full),
                .init(participantID: "guest", sourceID: source, appearanceID: "guest-tile", range: full)
            ])
        project.sources[0].layoutCapacityRanges = [full]
        project.sources[0].coverage = [.init(range: full, state: .unknown)]
        let report = try project.correctGrid(sourceID: source, range: correction, columns: 2, rows: 1)
        XCTAssertEqual(report.retainedAppearanceIDs, ["host-tile"])
        XCTAssertEqual(report.unmatchedAppearanceIDs, ["fragment", "guest-tile"])
        XCTAssertEqual(report.affectedParticipantIDs, ["guest"])
        XCTAssertEqual(report.droppedPreferenceCount, 1)
        XCTAssertEqual(project.resolveAppearance(participantID: "host", sourceID: source, at: first)?.bounds.width, 0.5)
        XCTAssertEqual(project.resolveAppearance(participantID: "guest", sourceID: source, at: .zero)?.id, "guest-tile")
        XCTAssertNil(project.resolveAppearance(participantID: "guest", sourceID: source, at: first))
        XCTAssertEqual(project.sources.first?.unresolvedParticipantIDs, ["guest"])
        let unidentified = project.appearances(sourceID: source, at: first).filter { $0.participantID == nil }
        XCTAssertEqual(unidentified.count, 1)
        XCTAssertEqual(project.sources[0].layoutCapacityRanges, [.init(from: .zero, to: first)])
        let repaired = try XCTUnwrap(unidentified.first)
        try project.linkAppearance(sourceID: source, appearanceID: repaired.id, participantID: "guest", range: correction)
        XCTAssertEqual(project.resolveAppearance(participantID: "guest", sourceID: source, at: first)?.id, repaired.id)
        XCTAssertEqual(project.sources[0].coverage, [.init(range: full, state: .unknown)])
    }
}
