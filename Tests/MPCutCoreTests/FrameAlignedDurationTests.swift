import Foundation
import XCTest
@testable import MPCutCore

final class FrameAlignedDurationTests: XCTestCase {
    private let ntsc = RationalTime(numerator: 1001, denominator: 30_000)
    private let film = RationalTime(numerator: 1001, denominator: 24_000)
    private let thirty = RationalTime(numerator: 1, denominator: 30)
    private let pal = RationalTime(numerator: 1, denominator: 25)

    /// `EditorModel.chooseStillDuration` as written.
    private func insertStill(_ cadence: RationalTime?) -> RationalTime {
        let interval = cadence ?? RationalTime(numerator: 1, denominator: 30)
        let frames = Int64(max(1, min(1_000, (2 / interval.seconds).rounded())))
        return (try? interval.multiplied(by: RationalTime(numerator: frames))) ?? RationalTime(numerator: 2)
    }

    /// `StillAuthoringControls.defaultGapTiming` as written.
    private func gap(_ cadence: RationalTime?) -> RationalTime {
        let interval = cadence ?? RationalTime(numerator: 1, denominator: 30)
        let frames = Int64(max(1, min(1_000, (2 / interval.seconds).rounded())))
        return (try? interval.multiplied(by: .init(numerator: frames))) ?? interval
    }

    /// `insertMulticamStills` with `stillFrameBoundary(_:cadence:nearest: true)` as written.
    private func multicam(_ cadence: RationalTime?) -> RationalTime {
        let cadence = cadence ?? .init(numerator: 1, denominator: 30)
        func boundary(_ time: RationalTime) -> RationalTime? {
            guard cadence > .zero,
                  let count = try? time.multiplied(by: .init(numerator: cadence.denominator, denominator: cadence.numerator)) else {
                return nil
            }
            let whole = count.numerator / count.denominator
            let fraction = count.numerator % count.denominator
            let half = count.denominator / 2 + count.denominator % 2
            let frames = fraction >= half ? whole + 1 : whole
            return try? cadence.multiplied(by: .init(numerator: frames))
        }
        return max(cadence, boundary(.init(numerator: 2)) ?? cadence)
    }

    func testFactoryValueMatchesAllThreeInsertionPaths() {
        for cadence in [thirty, ntsc, film, pal, RationalTime(numerator: 1, denominator: 60), nil] {
            let helper = FrameAlignedDuration.duration(seconds: 2, cadence: cadence)
            XCTAssertEqual(helper.duration, insertStill(cadence), "\(String(describing: cadence))")
            XCTAssertEqual(helper.duration, gap(cadence), "\(String(describing: cadence))")
            XCTAssertEqual(helper.duration, multicam(cadence), "\(String(describing: cadence))")
            XCTAssertEqual(helper.cadence, cadence ?? thirty)
        }
    }

    func testTwoSecondsAtCommonRates() {
        XCTAssertEqual(FrameAlignedDuration.duration(seconds: 2, cadence: thirty).duration, RationalTime(numerator: 2))
        XCTAssertEqual(FrameAlignedDuration.duration(seconds: 2, cadence: pal).duration, RationalTime(numerator: 2))
        XCTAssertEqual(FrameAlignedDuration.duration(seconds: 2, cadence: ntsc).duration, RationalTime(numerator: 1001, denominator: 500))
        XCTAssertEqual(FrameAlignedDuration.duration(seconds: 2, cadence: film).duration, RationalTime(numerator: 1001, denominator: 500))
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 2, cadence: ntsc), 60)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 2, cadence: film), 48)
    }

    func testRoundsToNearestFrameAndClamps() {
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 3, cadence: film), 72)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 0.05, cadence: thirty), 2)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 0.04, cadence: thirty), 1)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 0, cadence: thirty), 1)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: -5, cadence: thirty), 1)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: .nan, cadence: thirty), 1)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: .infinity, cadence: thirty), 1)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 600, cadence: thirty), 1_000)
        XCTAssertEqual(FrameAlignedDuration.frameCount(seconds: 600, cadence: thirty, frames: 1...1_000_000), 18_000)
    }

    func testNonpositiveCadenceUsesFallback() {
        let result = FrameAlignedDuration.duration(seconds: 2, cadence: .zero)
        XCTAssertEqual(result.cadence, thirty)
        XCTAssertEqual(result.duration, RationalTime(numerator: 2))
    }
}
