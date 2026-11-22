import XCTest
@testable import MPCutCore

final class BulkBoundaryTests: XCTestCase {
    func testSharedIndexKeepsContainerSpecificSmartTrimBoundaries() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures")).standardizedFileURL
        let engine = CutEngine(smartTrim: true, useSidecar: false)
        let indexed = [file: try engine.inspect(file, keyframes: true)]
        let range = ClipRequest(file: file, from: RationalTime(numerator: 1, denominator: 25),
                                to: RationalTime(numerator: 12, denominator: 25))
        var cache = CutEngine.BoundaryCache()
        let edit = try engine.resolve([range], snap: .exact, media: indexed, container: "mp4", boundaries: &cache)
        XCTAssertEqual(edit.duration, RationalTime(numerator: 11, denominator: 25))
        XCTAssertThrowsError(try engine.resolve([range], snap: .exact, media: indexed, container: "mkv",
                                                boundaries: &cache)) { error in
            XCTAssertEqual((error as? CutError)?.code, "unsafe_boundary")
            XCTAssertEqual((error as? CutError)?.boundary, "from")
        }
    }
}
