import XCTest
@testable import MPCutCore

final class AudioAnalysisTests: XCTestCase {
    private func span(_ from: Int64, _ to: Int64) -> AudioSpan {
        AudioSpan(from: RationalTime(numerator: from), to: RationalTime(numerator: to))
    }

    func testRetainedRangesStayInsideTheSpan() {
        XCTAssertEqual(AudioAnalysis.retained(in: span(2, 10), removing: [span(3, 4)]), [span(2, 3), span(4, 10)])
        XCTAssertEqual(AudioAnalysis.retained(in: span(2, 10), removing: [span(0, 1)]), [span(2, 10)])
        XCTAssertEqual(AudioAnalysis.retained(in: span(2, 10), removing: [span(4, 8), span(5, 6)]),
                       [span(2, 4), span(8, 10)])
        XCTAssertEqual(AudioAnalysis.retained(in: span(2, 10), removing: [span(8, 12), span(14, 15)]), [span(2, 8)])
    }
}
