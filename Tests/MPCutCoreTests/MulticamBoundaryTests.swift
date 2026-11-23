import Foundation
import XCTest
@testable import MPCutCore

final class MulticamBoundaryTests: XCTestCase {
    func testRecordingGapDoesNotHideInconsistentPictureDuration() throws {
        let one = RationalTime(numerator: 1)
        let two = RationalTime(numerator: 2)
        let picture = MulticamRange(from: .zero, to: one)
        let gap = MulticamRange(from: one, to: two)
        let spans = [
            MulticamInterval(group: picture, output: picture, angle: "camera", audio: nil, assemblyIndex: 0),
            MulticamInterval(group: gap, output: gap, angle: "camera", pictureSourceID: nil, audio: nil, assemblyIndex: 0)
        ]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        let malformed = MulticamPlan(intervals: spans, picture: [
            .init(source: "camera", stream: nil, input: .init(from: .zero, to: two), output: picture)
        ], audio: [], duration: two)
        XCTAssertThrowsError(try MulticamEngine().resolve(malformed, sources: [:], output: output,
                                                         mode: .encode, tracks: .video)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_range")
        }
    }

    private func grid(step: Int, offset: Int64 = 0) -> MulticamBoundary.Grid {
        let times = stride(from: 0, through: 1_000, by: step)
            .map { RationalTime(numerator: Int64($0), denominator: 1_000) }
        return MulticamBoundary.Grid(times: times, offset: RationalTime(numerator: offset, denominator: 1_000))
    }

    func testBothCamerasAndChangedAudioMustAdmitTheSameInstant() throws {
        let candidates = try MulticamBoundary.candidates(near: RationalTime(parsing: "0.44"),
            among: [grid(step: 40), grid(step: 80)], within: .zero...RationalTime(numerator: 1)) { instant in
                // This soundtrack can only make a join every 160 ms.
                try instant.roundedToSamples(1_000) % 160 == 0
            }
        XCTAssertEqual(candidates, try ["0.32", "0.48"].map(RationalTime.init(parsing:)))
    }

    func testPhaseShiftedCamerasHaveNoCommonFrameAndStayWithinNeighbors() throws {
        let one = RationalTime(numerator: 1)
        let near = try RationalTime(parsing: "0.35")
        XCTAssertTrue(try MulticamBoundary.candidates(near: near, among: [grid(step: 40), grid(step: 40, offset: 10)],
                                                      within: .zero...one).isEmpty)
        let adjacent = try RationalTime(parsing: "0.33")...RationalTime(parsing: "0.37")
        XCTAssertEqual(try MulticamBoundary.candidates(near: near, among: [grid(step: 40)], within: adjacent),
                       [try RationalTime(parsing: "0.36")])
    }

    func testSearchJumpsToInclusiveBoundsWhenRequestedTimeIsOutside() throws {
        let times = stride(from: 100, through: 900, by: 100)
            .map { RationalTime(numerator: Int64($0), denominator: 1_000) }
        let bounds = times[0]...times[8]
        for (requested, expected) in [(RationalTime.zero, bounds.lowerBound),
                                      (RationalTime(numerator: 1), bounds.upperBound)] {
            var checks = 0
            let choices = try MulticamBoundary.candidates(near: requested, among: [grid(step: 1)],
                within: bounds, cancelled: {
                    checks += 1
                    return checks > 2
                })
            XCTAssertEqual(choices, [expected])
        }
    }
}
