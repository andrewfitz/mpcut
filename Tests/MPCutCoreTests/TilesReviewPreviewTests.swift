import CoreGraphics
import Foundation
import XCTest
@testable import MPCutCore

final class TilesReviewPreviewTests: XCTestCase {
    func testReviewBoxesUseOrientedTopLeftCoordinates() throws {
        let image = try blackImage()
        let tile = TilesTile(ParticipantAppearance(
            id: "tile", participantID: "feed", range: .init(from: .zero, to: RationalTime(numerator: 1)),
            bounds: .init(x: 0.125, y: 0.125, width: 0.5, height: 0.5)))
        let annotated = try TilesPreviewPicture.annotated(image, tiles: [tile])
        let bytes = try XCTUnwrap(annotated.dataProvider?.data as Data?)
        let upperEdge = 27 * annotated.bytesPerRow + 40 * 4
        let lowerHalf = 48 * annotated.bytesPerRow + 40 * 4
        XCTAssertGreaterThan(bytes[upperEdge + 1], 180)
        XCTAssertEqual(bytes[lowerHalf + 1], 0)
    }

    func testReturnPairKeepsBothImagesAtTheirReviewSize() throws {
        let before = try blackImage()
        let after = try blackImage()
        let paired = try TilesPreviewPicture.pair(before, after, titles: ("Before departure", "After return"))
        XCTAssertEqual(paired.width, before.width + after.width + 8)
        XCTAssertEqual(paired.height, before.height + 26)
    }

    func testReviewOutputCannotBeInsideISODelivery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let delivery = directory.appendingPathComponent("delivery")
        let workspace = delivery.appendingPathComponent(".mpcut-isos")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrow(try TilesISODelivery.validateReviewDestination(directory))
        XCTAssertThrowsError(try TilesISODelivery.validateReviewDestination(delivery)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_output")
        }
    }

    private func blackImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return try XCTUnwrap(context.makeImage())
    }
}
