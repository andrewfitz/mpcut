import MPCutCore
import XCTest
@testable import MPCutApp

final class TileTimelineTests: XCTestCase {
    func testLayoutLabelsKeepSourceClockAndDescribeTheFeed() {
        let projected = TileTimelineContent.fillingGaps([
            .init(range: range(4, 9), layout: .solo, slots: [.init(id: "host")])
        ], in: range(6, 10))
        XCTAssertEqual(projected.map(\.range), [range(6, 9), range(9, 10)])
        XCTAssertEqual(projected.map(\.layout), [.solo, .original])
        let content = TileTimelineContent(layouts: projected, feedNames: ["host": "Host"])
        XCTAssertEqual(projected.map(content.layoutName), ["Solo · Host", "Original"])
    }

    func testFeedVisibilityClipsProjectedCoverageAndResizesInSourceTime() throws {
        let appearance = ParticipantAppearance(id: "tile", participantID: "host", range: range(2, 7),
                                               bounds: .init(x: 0, y: 0, width: 1, height: 1))
        let source = ParticipantSourceGeometry(sourceID: "recording", appearances: [appearance], coverage: [
            .init(range: range(1, 4), state: .verified), .init(range: range(4, 7), state: .inferred)
        ])
        let project = ParticipantProject(people: [.init(id: "host", name: "Host")], sources: [source])
        var content = TileTimelineContent()
        content.addFeeds(project, sourceID: "recording", input: range(3, 9), offset: .init(numerator: 10))
        let feed = try XCTUnwrap(content.feeds.first)
        let span = try XCTUnwrap(feed.spans.first)
        XCTAssertEqual(feed.name, "Host")
        XCTAssertEqual(span.range, range(13, 17))
        XCTAssertEqual(span.coverage.map(\.range), [range(13, 14)])
        XCTAssertFalse(span.hasStart)
        XCTAssertTrue(span.hasEnd)
        let updated = try TileTimelineEdit.resize(project, span: span, edge: .end, to: .init(numerator: 18))
        XCTAssertEqual(updated.sources[0].appearances[0].range, range(2, 8))
    }

    func testResizingLaterSpanOfSameTileStopsAtAdjacentSpan() throws {
        let first = ParticipantAppearance(id: "tile", participantID: "host", range: range(1, 3),
                                          bounds: .init(x: 0, y: 0, width: 1, height: 1))
        var second = first
        second.range = range(4, 7)
        second.bounds.width = 0.5
        let project = ParticipantProject(people: [.init(id: "host", name: "Host")], sources: [
            .init(sourceID: "recording", appearances: [first, second])
        ])
        var content = TileTimelineContent()
        content.addFeeds(project, sourceID: "recording", input: range(0, 9), offset: .zero)
        let span = try XCTUnwrap(content.feeds.first?.spans.last)
        let updated = try TileTimelineEdit.resize(project, span: span, edge: .start, to: .init(numerator: 2))
        XCTAssertEqual(updated.sources[0].appearances[0], first)
        XCTAssertEqual(updated.sources[0].appearances[1].range, range(3, 7))
        XCTAssertEqual(updated.sources[0].appearances[1].bounds, second.bounds)
        XCTAssertNoThrow(try updated.validate())
    }

    func testSwappingPreviouslyArrangedTilesMovesTheirCurrentContents() throws {
        func appearance(_ id: String) -> ParticipantAppearance {
            .init(id: "tile-\(id)", participantID: id, range: range(0, 1),
                  bounds: .init(x: 0, y: 0, width: 1, height: 1))
        }
        let first = appearance("first")
        let second = appearance("second")
        let third = appearance("third")
        var slots = TileArrangement.swapping(first, with: second, in: [])
        slots[0].anchorX = 0.25
        let result = TileArrangement.swapping(first, with: third, in: slots)
        let contents = Dictionary(uniqueKeysWithValues: try result.map { slot in
            (try XCTUnwrap(slot.destinationTileID), slot.id)
        })
        XCTAssertEqual(contents, [first.id: "third", second.id: "first", third.id: "second"])
        XCTAssertEqual(result.first(where: { $0.destinationTileID == second.id })?.anchorX, 0.25)
    }

    private func range(_ from: Int64, _ to: Int64) -> MulticamRange {
        .init(from: .init(numerator: from), to: .init(numerator: to))
    }
}
