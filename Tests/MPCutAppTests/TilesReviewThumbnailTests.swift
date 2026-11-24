import CoreGraphics
import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class TilesReviewThumbnailTests: XCTestCase {
    func testCacheEvictsLeastRecentlyUsedFramesByBytesAndCount() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(bitmap.makeImage())
        let cost = image.bytesPerRow * image.height
        var byBytes = TilesThumbnailCache<Int>(limit: 2 * cost)
        byBytes.insert(image, for: 1)
        byBytes.insert(image, for: 2)
        XCTAssertNotNil(byBytes.image(for: 1))
        byBytes.insert(image, for: 3)
        XCTAssertNil(byBytes.image(for: 2))
        XCTAssertNotNil(byBytes.image(for: 1))
        XCTAssertEqual(byBytes.bytes, 2 * cost)
        byBytes.insert(image, for: 3)
        XCTAssertEqual(byBytes.bytes, 2 * cost)
        byBytes.remove { $0 == 3 }
        XCTAssertNil(byBytes.image(for: 3))
        XCTAssertEqual(byBytes.bytes, cost)

        var byCount = TilesThumbnailCache<Int>(limit: 10 * cost, countLimit: 1)
        byCount.insert(image, for: 1)
        byCount.insert(image, for: 2)
        XCTAssertNil(byCount.image(for: 1))
        XCTAssertNotNil(byCount.image(for: 2))
        XCTAssertEqual(byCount.bytes, cost)

        var tooSmall = TilesThumbnailCache<Int>(limit: cost - 1)
        tooSmall.insert(image, for: 1)
        XCTAssertNil(tooSmall.image(for: 1))
        XCTAssertEqual(tooSmall.bytes, 0)
    }

    func testCachedFrameIsRejectedAfterSourceReplacement() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.mov")
        try FileManager.default.copyItem(at: fixture, to: url)

        let engine = CutEngine(useSidecar: false)
        let media = try engine.inspect(url, keyframes: true)
        let renderer = TilesThumbnailRenderer()
        let time = try XCTUnwrap(media.frames.first(where: { $0.time >= .zero })).time
        let bounds = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let original = try await renderer.image(media: media, time: time, bounds: bounds)
        let image = try XCTUnwrap(original)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 160)
        let cached = try await renderer.image(media: media, time: time, bounds: bounds)
        XCTAssertNotNil(cached)

        let replacementURL = directory.appendingPathComponent("replacement.mov")
        try FileManager.default.copyItem(at: fixture, to: replacementURL)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacementURL, to: url)
        let stale = try await renderer.image(media: media, time: time, bounds: bounds)
        XCTAssertNil(stale)
        let replacement = try engine.inspect(url, keyframes: true)
        XCTAssertNotEqual(replacement.identity, media.identity)
        let fresh = try await renderer.image(media: replacement, time: time, bounds: bounds)
        XCTAssertNotNil(fresh)
    }

    func testProvisionalMulticamThumbnailUsesTheSameSourceFrameAsTheFullIndex() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes", withExtension: "mov",
                                                      subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delayed.mov")
        try FileManager.default.copyItem(at: fixture, to: url)

        let engine = CutEngine(useSidecar: false)
        let ordinary = try engine.inspect(url, keyframes: true)
        let indexed = try engine.multicamClock(ordinary)
        let provisional = try engine.multicamClock(engine.inspectForPreview(url))
        XCTAssertFalse(provisional.hasFullEditIndex)
        XCTAssertGreaterThan(provisional.multicamClockOffset, .zero)
        let time = try XCTUnwrap(ordinary.frames.last).time
        XCTAssertGreaterThanOrEqual(try time.adding(provisional.multicamClockOffset), ordinary.duration)

        let renderer = TilesThumbnailRenderer()
        let bounds = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        func pixels(_ media: MediaInfo) async throws -> Data {
            let thumbnail = try await renderer.image(media: media, time: time, bounds: bounds)
            let image = try XCTUnwrap(thumbnail)
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let previewFrame = try await pixels(provisional)
        let indexedFrame = try await pixels(indexed)
        let sourceFrame = try await pixels(ordinary)
        XCTAssertEqual(previewFrame, indexedFrame)
        XCTAssertEqual(previewFrame, sourceFrame)
    }
}
