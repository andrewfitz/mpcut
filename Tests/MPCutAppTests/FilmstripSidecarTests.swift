import CoreGraphics
import Foundation
import MPCutCore
import SQLite3
import XCTest
@testable import MPCutApp

final class FilmstripSidecarTests: XCTestCase {
    func testLargeTilesRespectTheByteBudgetAcrossAllSources() throws {
        let size = CGSize(width: 1024, height: 1024)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                              bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let sources = [UUID(), UUID()]
        var buffer = FilmstripTileBuffer()
        for i in 0..<5 {
            let key = try XCTUnwrap(FilmstripTileKey(time: Double(i), size: size))
            buffer.remember(FilmstripTile(key: key, image: image), source: sources[i % 2])
        }
        XCTAssertEqual(buffer.snapshot(for: sources[0]).map { $0.key.time }, [2, 4])
        XCTAssertEqual(buffer.snapshot(for: sources[1]).map { $0.key.time }, [1, 3])
    }

    func testFilmstripBufferEvictsTilesAndReleasesClosedSources() throws {
        let source = UUID()
        let other = UUID()
        let size = CGSize(width: 1, height: 1)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var buffer = FilmstripTileBuffer()
        for i in 0...FilmstripTileBuffer.countLimit {
            let key = try XCTUnwrap(FilmstripTileKey(time: Double(i), size: size))
            buffer.remember(FilmstripTile(key: key, image: image), source: i == 1 ? other : source)
        }
        XCTAssertEqual(buffer.snapshot(for: source).count, FilmstripTileBuffer.countLimit - 1)
        XCTAssertEqual(buffer.snapshot(for: source).first?.key.time, 2)
        buffer.keepSources([other])
        XCTAssertTrue(buffer.snapshot(for: source).isEmpty)
        XCTAssertEqual(buffer.snapshot(for: other).first?.key.time, 1)
    }

    @MainActor
    func testSaveReloadAndDisableFilmstripTiles() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                      subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.importFiles([source])
        try await wait { editor.canEdit }
        let id = try XCTUnwrap(editor.timelineClips.first?.sourceID)
        let size = CGSize(width: 92, height: 48)
        let key = try XCTUnwrap(FilmstripTileKey(time: 0, size: size))
        let image = await editor.thumbnail(for: id, at: 0, size: size)
        let original = try XCTUnwrap(image)
        XCTAssertGreaterThan(original.width, 1)
        let sidecar = try AnalysisSidecar(source: source)
        XCTAssertEqual(sidecar.status(), "current")
        try await wait { key.image(in: sidecar)?.width == original.width }
        editor.saveAnalysisSidecars()
        try await wait { !editor.isSavingSidecars }
        XCTAssertNil(editor.alert)
        XCTAssertEqual(key.image(in: sidecar)?.width, original.width)

        // A distinct color at the same dimensions makes a disk hit observable.
        let context = try XCTUnwrap(CGContext(data: nil, width: original.width, height: original.height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: original.width, height: original.height))
        let marker = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(key.encoded(marker, preserveAlpha: true))
        try sidecar.save([key.section: data])
        editor.endSession()
        editor.importFiles([source])
        try await wait { editor.canEdit }
        let newID = try XCTUnwrap(editor.timelineClips.first?.sourceID)
        let restored = await editor.thumbnail(for: newID, at: 0, size: size)
        let markerPixel = try centerPixel(marker)
        XCTAssertNotEqual(try centerPixel(original), markerPixel)
        XCTAssertEqual(try centerPixel(XCTUnwrap(restored)), markerPixel)
        editor.useAnalysisSidecars = false
        let fresh = await editor.thumbnail(for: newID, at: 0, size: size)
        XCTAssertEqual(try centerPixel(XCTUnwrap(fresh)), try centerPixel(original))

        let other = try XCTUnwrap(FilmstripTileKey(time: 0.1, size: size))
        try sidecar.save([other.section: data])
        XCTAssertNil(other.image(in: sidecar))
        // A damaged tile must yield to the media decoder and leave the other analyses available.
        try sidecar.save([key.section: Data(repeating: 0, count: 300 * 1024)])
        editor.useAnalysisSidecars = true
        let recovered = await editor.thumbnail(for: newID, at: 0, size: size)
        XCTAssertEqual(try centerPixel(XCTUnwrap(recovered)), try centerPixel(original))
        XCTAssertNotNil(try CutEngine().cachedIndex(source))
    }

    @MainActor
    func testFilmstripRendersWhileSidecarWriterHoldsLock() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                       subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let sidecar = try AnalysisSidecar(source: source)
        try sidecar.save(["marker": Data([1])])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(sidecar.url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let size = CGSize(width: 92, height: 48)
        let keys = try [0.0, 0.1].map { try XCTUnwrap(FilmstripTileKey(time: $0, size: size)) }
        let preview = SequencePreview(), sourceID = UUID()
        let start = ContinuousClock.now
        for key in keys {
            let image = await preview.thumbnail(source: sourceID, url: source, at: key.time, size: size,
                                                saved: (sidecar, key))
            XCTAssertNotNil(image)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
        try await wait { keys.allSatisfy { $0.image(in: sidecar) != nil } }
    }

    private func centerPixel(_ image: CGImage) throws -> UInt32 {
        var pixel: UInt32 = 0
        try withUnsafeMutableBytes(of: &pixel) { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        }
        return pixel
    }

    @MainActor
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard predicate() else { throw NSError(domain: "FilmstripSidecarTests", code: 1) }
    }
}
