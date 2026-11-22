import Foundation
import XCTest
@testable import MPCutCore

final class StillTimelineFormatTests: XCTestCase {
    func testExactFractionalCadenceRoundTrip() throws {
        let format = StillTimelineFormat(width: 1920, height: 1080,
                                         cadence: .init(numerator: 1001, denominator: 30000),
                                         codec: .h264, container: "mp4")
        let json = try JSONEncoder().encode(format)
        XCTAssertEqual(try JSONDecoder().decode(StillTimelineFormat.self, from: json), format)
        XCTAssertEqual(try format.frameCount(for: .init(numerator: 1001, denominator: 6000)), 5)
        XCTAssertThrowsError(try format.frameCount(for: .init(numerator: 1))) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_still_time")
        }
    }

    func testRejectsInvalidCanvasAndContainer() throws {
        let cadence = RationalTime(numerator: 1, denominator: 25)
        for format in [
            StillTimelineFormat(width: 1921, height: 1080, cadence: cadence, codec: .h264, container: "mp4"),
            StillTimelineFormat(width: 1920, height: 1080, cadence: cadence, codec: .prores, container: "mp4"),
            StillTimelineFormat(width: 1920, height: 1080, cadence: .zero, codec: .h264, container: "mov")
        ] {
            XCTAssertThrowsError(try format.validate()) {
                XCTAssertEqual(($0 as? CutError)?.code, "invalid_still_format")
            }
        }
        let avc = StillTimelineFormat(width: 1920, height: 1080, cadence: cadence, codec: .h264, container: "mp4")
        XCTAssertThrowsError(try avc.validate(color: StillTimelineFormat.Color.pq.policy)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_still_format")
        }
    }

    func testStandaloneProjectRoundTripPreservesFormatAndColor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("stills.cut")
        let format = StillTimelineFormat(width: 640, height: 480, cadence: .init(numerator: 1, denominator: 24),
                                         codec: .hevc, container: "mov")
        let asset = StillAsset(id: "first-photo", file: "offline.png", displayName: "First photo", fingerprint: "example")
        let policy = StillTimelineFormat.Color.hlg.policy
        let original = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "first-still",
                                                       duration: .init(numerator: 3), colorPolicy: policy)
        try original.save(to: location, undo: [], redo: [], replacingExisting: false)
        let reopened = try CutProject.load(from: location)
        XCTAssertEqual(reopened, original)
        XCTAssertEqual(reopened.stillFormat, format)
        XCTAssertEqual(reopened.programColorPolicy, policy)
        XCTAssertEqual(try reopened.resolveStills().duration, .init(numerator: 3))

        let target = try format.targetStream(color: policy, duration: .init(numerator: 3))
        XCTAssertEqual(target.frameRate, .init(numerator: 24))
        XCTAssertEqual(target.timeBase, .init(numerator: 1, denominator: 24))
        XCTAssertEqual(target.colorTransfer, "arib-std-b67")
        XCTAssertEqual(target.bitDepth, 10)
    }
}
