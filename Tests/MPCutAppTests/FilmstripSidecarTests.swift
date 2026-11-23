import CoreGraphics
import Darwin
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

    @MainActor
    func testFilmstripWriterKeepsRecentTilesAndSkipsCancelledRequests() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["MPCUT_FILMSTRIP_WRITE_BENCHMARK_RUNS"] ?? "") ?? 1
        let size = CGSize(width: 320, height: 180)
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let keys = try (0..<32).map { try XCTUnwrap(FilmstripTileKey(time: Double($0), size: size)) }
        let prefix = FilmstripTileKey.sectionPrefix
        let old = Dictionary(uniqueKeysWithValues: (0..<FilmstripTileBuffer.countLimit).map {
            ("\(prefix)old.\($0)", Data([1]))
        })
        var timings: [Double] = []
        for _ in 0..<max(runs, 1) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("source")
            try Data([1]).write(to: source)
            let sidecar = try AnalysisSidecar(source: source)
            try sidecar.save(old.merging(["unrelated": Data([2])]) { _, new in new })
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(sidecar.url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
            let writer = FilmstripTileWriter()
            for (index, key) in keys.enumerated() {
                writer.submit(image, key: key, sidecar: sidecar, preserveAlpha: false, cancelled: { index == 8 })
            }
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
            let last = try XCTUnwrap(keys.last)
            let deadline = ContinuousClock.now + .seconds(8)
            while sidecar.read(last.section) == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            for (index, key) in keys.enumerated() {
                XCTAssertEqual(sidecar.read(key.section), index == 8 ? nil : key.encoded(image, preserveAlpha: false))
            }
            XCTAssertEqual(sidecar.keys().filter { $0.hasPrefix(prefix) }.count, FilmstripTileBuffer.countLimit)
            XCTAssertEqual(sidecar.read("unrelated"), Data([2]))
            let later = Dictionary(uniqueKeysWithValues: (0..<(FilmstripTileBuffer.countLimit - 30)).map {
                ("\(prefix)later.\($0)", Data([3]))
            })
            try sidecar.save(later, retainingLatest: [prefix: FilmstripTileBuffer.countLimit])
            XCTAssertNil(sidecar.read(keys[0].section))
            XCTAssertEqual(keys.dropFirst().filter { sidecar.read($0.section) != nil }.count, 30)
        }
        if runs > 1 {
            print("MPCUT_FILMSTRIP_WRITE_MILLISECONDS \(timings)")
        }
    }

    @MainActor
    func testFilmstripWriterKeepsCurrentTileAfterSameStampSourceChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data([1]).write(to: source)
        let oldIdentity = try SourceIdentity(source)
        let old = try AnalysisSidecar(source: source)
        var info = stat()
        XCTAssertEqual(stat(source.path, &info), 0)
        try await Task.sleep(for: .milliseconds(20))
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data([2]))
        try handle.close()
        let times = [info.st_atimespec, info.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, source.path, $0.baseAddress, 0) }, 0)
        let current = try AnalysisSidecar(source: source)
        XCTAssertEqual(oldIdentity, try SourceIdentity(source))
        XCTAssertThrowsError(try old.checkSource())
        XCTAssertNoThrow(try current.checkSource())

        let size = CGSize(width: 4, height: 4)
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let keys = try (0..<3).map { try XCTUnwrap(FilmstripTileKey(time: Double($0), size: size)) }
        let writer = FilmstripTileWriter()
        let release = DispatchSemaphore(value: 0)
        writer.submit(image, key: keys[0], sidecar: current, preserveAlpha: true, cancelled: {
            _ = release.wait(timeout: .now() + 2)
            return true
        })
        writer.submit(image, key: keys[1], sidecar: old, preserveAlpha: true, cancelled: { false })
        writer.submit(image, key: keys[2], sidecar: current, preserveAlpha: true, cancelled: { false })
        release.signal()
        try await wait { current.read(keys[2].section) != nil }
        XCTAssertNil(current.read(keys[0].section))
        XCTAssertNil(current.read(keys[1].section))
        XCTAssertEqual(current.read(keys[2].section), keys[2].encoded(image, preserveAlpha: true))
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
