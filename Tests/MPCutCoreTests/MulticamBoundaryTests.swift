import XCTest
@testable import MPCutCore

final class MulticamBoundaryTests: XCTestCase {
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
}
