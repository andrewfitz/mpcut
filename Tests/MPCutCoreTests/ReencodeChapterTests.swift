import XCTest
@testable import MPCutCore

final class ReencodeChapterTests: XCTestCase {
    func testUnrepresentableChapterClockThrows() {
        let chapter = ReencodeChapter(start: RationalTime(numerator: 1, denominator: 2),
                                      end: RationalTime(numerator: Int64.max),
                                      tags: [], source: 0, index: 0)
        XCTAssertThrowsError(try ReencodeChapter.metadata([chapter])) { error in
            XCTAssertEqual((error as? CutError)?.code, "time_overflow")
        }
    }
}
