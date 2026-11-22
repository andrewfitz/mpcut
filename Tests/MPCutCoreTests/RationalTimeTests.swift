import XCTest
@testable import MPCutCore

final class RationalTimeTests: XCTestCase {
    func testMalformedTimestampsReturnStructuredErrors() {
        for input in ["", "+", "-", ".", "1.", "00:00:", "00:60:00", "1:60", "1/0", "9223372036854775808"] {
            XCTAssertThrowsError(try RationalTime(parsing: input), input) { error in
                XCTAssertEqual((error as? CutError)?.code, "invalid_time")
            }
        }
    }

    func testMinuteClockAcceptsElapsedMinutesAndFractionalSeconds() throws {
        XCTAssertEqual(try RationalTime(parsing: "23:01"), RationalTime(numerator: 1381))
        XCTAssertEqual(try RationalTime(parsing: "4:03"), RationalTime(numerator: 243))
        XCTAssertEqual(try RationalTime(parsing: "62:03.25"), RationalTime(numerator: 14893, denominator: 4))
        XCTAssertEqual(try RationalTime(parsing: "62:03.25"), try RationalTime(parsing: "01:02:03.25"))
    }

    func testParserReducesBeforeCheckingNumeratorRange() throws {
        XCTAssertEqual(try RationalTime(parsing: "-9223372036854775808"), RationalTime(numerator: .min))
        XCTAssertEqual(try RationalTime(parsing: "00:00:12.000000000000000002"),
                       RationalTime(numerator: 6_000_000_000_000_000_001, denominator: 500_000_000_000_000_000))
        XCTAssertEqual(try RationalTime(parsing: "12.50000000000000000000000000"),
                       RationalTime(numerator: 25, denominator: 2))
        XCTAssertEqual(try RationalTime(parsing: "0.0000000000000000002"),
                       RationalTime(numerator: 1, denominator: 5_000_000_000_000_000_000))
        XCTAssertEqual(try RationalTime(parsing: "0.00000095367431640625"),
                       RationalTime(numerator: 1, denominator: 1_048_576))
        XCTAssertEqual(try RationalTime(parsing: "2/18446744073709551614"),
                       RationalTime(numerator: 1, denominator: .max))
        XCTAssertThrowsError(try RationalTime(parsing: "0.0000000000000000001"))
    }

    func testNearestBoundaryUsesExactDistanceAndEarlierTie() throws {
        let earlier = try RationalTime(parsing: "1/3")
        let later = try RationalTime(parsing: "2/3")
        XCTAssertTrue(try RationalTime(parsing: "0.499999999999999999").isCloserToEarlier(earlier, than: later))
        XCTAssertTrue(try RationalTime(parsing: "0.5").isCloserToEarlier(earlier, than: later))
        XCTAssertFalse(try RationalTime(parsing: "0.500000000000000001").isCloserToEarlier(earlier, than: later))

        let wideEarlier = RationalTime(numerator: -8_000_000_000_000_000_001, denominator: .max)
        let wideLater = RationalTime(numerator: 8_000_000_000_000_000_001, denominator: .max)
        XCTAssertTrue(RationalTime.zero.isCloserToEarlier(wideEarlier, than: wideLater))
        XCTAssertFalse(try RationalTime(parsing: "0.000000000000000001").isCloserToEarlier(wideEarlier, than: wideLater))
    }

    func testCheckedArithmeticReducesWideIntermediates() throws {
        let first = RationalTime(numerator: 1, denominator: 6_000_000_000_000_000_000)
        let second = RationalTime(numerator: 1, denominator: 9_000_000_000_000_000_000)
        XCTAssertEqual(try first.adding(second), RationalTime(numerator: 1, denominator: 3_600_000_000_000_000_000))
        XCTAssertEqual(try RationalTime(numerator: .min).subtracting(RationalTime(numerator: .min)), .zero)
        let halfMax = RationalTime(numerator: .max, denominator: 2)
        XCTAssertEqual(try halfMax.adding(halfMax), RationalTime(numerator: .max))
        XCTAssertEqual(try halfMax.adding(.zero), halfMax)
        XCTAssertEqual(try RationalTime.zero.multiplied(by: halfMax), .zero)
        XCTAssertThrowsError(try first.subtracting(second)) { error in
            XCTAssertEqual((error as? CutError)?.code, "time_overflow")
        }
        XCTAssertThrowsError(try RationalTime(numerator: .max).adding(RationalTime(numerator: 1)))
        XCTAssertEqual(try first.multiplied(by: RationalTime(numerator: first.denominator)), RationalTime(numerator: 1))
        XCTAssertThrowsError(try RationalTime(numerator: .min).multiplied(by: RationalTime(numerator: -1)))
    }

    func testSampleRoundingUsesWideProduct() throws {
        let nearOne = try RationalTime(parsing: "0.999999999999999999")
        XCTAssertEqual(try nearOne.roundedToSamples(48_000), 48_000)
        XCTAssertEqual(try RationalTime(numerator: -1, denominator: 96_000).roundedToSamples(48_000), -1)
        XCTAssertEqual(try RationalTime(numerator: .min).roundedToSamples(1), .min)
        XCTAssertThrowsError(try RationalTime(numerator: .max).roundedToSamples(48_000))
    }
}
