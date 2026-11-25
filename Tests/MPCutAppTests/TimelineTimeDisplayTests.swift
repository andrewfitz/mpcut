import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class TimelineTimeDisplayTests: XCTestCase {
    private let thirty = RationalTime(numerator: 1, denominator: 30)
    private let ntsc = RationalTime(numerator: 1001, denominator: 30_000)
    private let film = RationalTime(numerator: 1001, denominator: 24_000)
    private let pal = RationalTime(numerator: 1, denominator: 25)

    func testMillisecondsMatchesTheExistingReadOut() {
        let samples: [Double] = [0, 0.0004, 0.0005, 0.999_5, 1.25, 59.999, 61.5, 3_599.999_6, 3_600, 7_384.123,
                                 -3, .nan, .infinity, 1e300]
        for seconds in samples {
            for cadence in [nil, thirty] {
                XCTAssertEqual(TimelineTimeDisplay.milliseconds.string(seconds, cadence: cadence),
                               timelineTime(seconds, milliseconds: true), "\(seconds)")
            }
        }
    }

    func testFramesFallsBackToMillisecondsWithoutACadence() {
        for seconds in [0.0, 1.25, 3_700.5] {
            XCTAssertEqual(TimelineTimeDisplay.frames.string(seconds, cadence: nil), timelineTime(seconds, milliseconds: true))
            XCTAssertEqual(TimelineTimeDisplay.frames.string(seconds, cadence: .zero), timelineTime(seconds, milliseconds: true))
        }
    }

    func testFramesAtWholeRates() {
        XCTAssertEqual(TimelineTimeDisplay.frames.string(0, cadence: thirty), "00:00:00")
        XCTAssertEqual(TimelineTimeDisplay.frames.string(1.5, cadence: thirty), "00:01:15")
        XCTAssertEqual(TimelineTimeDisplay.frames.string(1.5, cadence: pal), "00:01:12")
        XCTAssertEqual(TimelineTimeDisplay.frames.string(61 + 29.0 / 30, cadence: thirty), "01:01:29")
        XCTAssertEqual(TimelineTimeDisplay.frames.string(3_600 + 62 + 0.5, cadence: thirty), "1:01:02:15")
        // A time inside a frame shows that frame.
        XCTAssertEqual(TimelineTimeDisplay.frames.string(1.0 / 30 * 0.9, cadence: thirty), "00:00:00")
        XCTAssertEqual(TimelineTimeDisplay.frames.string(-1, cadence: thirty), "00:00:00")
    }

    func testFramesAtFractionalRatesCountNonDrop() throws {
        // Frame 45 at 29.97 starts at 1.5015 s: second 1, frame 15.
        let start = try ntsc.multiplied(by: RationalTime(numerator: 45)).seconds
        XCTAssertEqual(TimelineTimeDisplay.frames.string(start, cadence: ntsc), "00:01:15")
        // Every frame boundary lands on its own frame, never one before.
        for frame in Int64(0)..<2_000 {
            let seconds = try film.multiplied(by: RationalTime(numerator: frame)).seconds
            XCTAssertEqual(TimelineTimeDisplay.frameIndex(seconds, cadence: film), Int(frame))
        }
        // One hour of 29.97 is 107,892 frames, shown as 59:56:12.
        XCTAssertEqual(TimelineTimeDisplay.frames.string(3_600, cadence: ntsc), "59:56:12")
        XCTAssertEqual(TimelineTimeDisplay.nominalRate(film), 24)
        XCTAssertEqual(TimelineTimeDisplay.nominalRate(ntsc), 30)
    }

    func testHighRatesUseThreeDigits() {
        let fast = RationalTime(numerator: 1, denominator: 120)
        XCTAssertEqual(TimelineTimeDisplay.frames.string(1.5, cadence: fast), "00:01:060")
        XCTAssertEqual(TimelineTimeDisplay.frames.string(1.5, cadence: RationalTime(numerator: 1, denominator: 240)), "00:01:120")
    }

    func testParseFramesRoundTrips() throws {
        for cadence in [thirty, ntsc, film, pal] {
            for frame in Int64(0)..<400 where frame % 7 == 0 {
                let seconds = try cadence.multiplied(by: RationalTime(numerator: frame * 37)).seconds
                let text = TimelineTimeDisplay.frames.string(seconds, cadence: cadence)
                let parsed = try XCTUnwrap(TimelineTimeDisplay.parseFrames(text, cadence: cadence), text)
                XCTAssertEqual(TimelineTimeDisplay.frames.string(parsed, cadence: cadence), text)
            }
        }
        XCTAssertEqual(try XCTUnwrap(TimelineTimeDisplay.parseFrames("1:00:00:00", cadence: thirty)), 3_600, accuracy: 1e-9)
        XCTAssertNil(TimelineTimeDisplay.parseFrames("00:01:30", cadence: thirty))
        XCTAssertNil(TimelineTimeDisplay.parseFrames("00:61:00", cadence: thirty))
        XCTAssertNil(TimelineTimeDisplay.parseFrames("01:02.500", cadence: thirty))
        XCTAssertNil(TimelineTimeDisplay.parseFrames("00::00", cadence: thirty))
        XCTAssertNil(TimelineTimeDisplay.parseFrames("00:00:-1", cadence: thirty))
    }
}
