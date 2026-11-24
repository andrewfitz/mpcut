import XCTest
@testable import MPCutApp

final class ParticipantMarkerInspectorTests: XCTestCase {
    func testCandidatePagesCanReachAndReturnFromCandidatesPastFirstHundred() {
        var pages = ParticipantMarkerPages()
        let count = 107
        var visited: [Int] = []
        for _ in 0..<5 {
            visited.append(contentsOf: pages.indices(count: count))
            pages.move(by: 1, count: count)
        }
        XCTAssertEqual(visited, Array(0..<count))
        XCTAssertEqual(pages.indices(count: count), 100..<107)
        pages.move(by: -1, count: count)
        XCTAssertEqual(pages.indices(count: count), 75..<100)
        pages = ParticipantMarkerPages()
        XCTAssertEqual(pages.indices(count: 2), 0..<2)
    }
}
