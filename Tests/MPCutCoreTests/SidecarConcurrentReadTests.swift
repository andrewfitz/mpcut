import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MPCutCore

/// Saves must reach disk while other connections in the same process read the
/// sidecar, as filmstrip and scene lookups do during automatic metadata saves.
final class SidecarConcurrentReadTests: XCTestCase {
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The writer takes its write lock while a reader that locked first still
    /// holds its snapshot, then commits once the snapshot ends.
    func testSaveTakesItsWriteLockWhileAnEarlierReaderHoldsASnapshot() throws {
        let source = try scratchDirectory().appendingPathComponent("shot.mov")
        try Data([1, 2, 3]).write(to: source)
        let sidecar = try AnalysisSidecar(source: source)
        try sidecar.save(["a": Data([1])])

        let locked = DispatchSemaphore(value: 0), finished = DispatchGroup()
        let lock = NSLock()
        var failure: Error?
        let seen = try sidecar.withReadSnapshot(cancelled: { false }) { read -> Data? in
            let before = read("a")
            DispatchQueue.global().async(group: finished) {
                do {
                    try AnalysisSidecar(source: source).save([:], updating: ["b": { _ in
                        locked.signal()
                        return Data([2])
                    }])
                } catch {
                    lock.withLock { failure = error }
                    locked.signal()
                }
            }
            locked.wait()
            XCTAssertNil(read("b"))
            return before
        }
        finished.wait()
        XCTAssertEqual(seen, Data([1]))
        XCTAssertNil(lock.withLock { failure }.map { "\($0)" })
        XCTAssertEqual(sidecar.read("b"), Data([2]))
    }

    func testReadsAReadOnlySidecarWithoutChangingItsDirectory() throws {
        let source = try scratchDirectory().appendingPathComponent("shot.mov")
        try Data([1, 2, 3]).write(to: source)
        let sidecar = try AnalysisSidecar(source: source)
        try sidecar.save(["a": Data([1])])
        let directory = source.deletingLastPathComponent()
        XCTAssertEqual(chmod(sidecar.url.path, 0o444), 0)
        XCTAssertEqual(chmod(directory.path, 0o555), 0)
        defer { chmod(directory.path, 0o755) }
        XCTAssertEqual(sidecar.status(), "current")
        XCTAssertEqual(sidecar.keys(), ["a"])
        XCTAssertEqual(sidecar.read("a"), Data([1]))
        XCTAssertThrowsError(try sidecar.save(["b": Data()]))
        sidecar.saveAutomatically(["b": Data()])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["shot.mov", "shot.mov.cutcache"])
    }

    func testSectionReadObservesCancellationBeforeReturning() throws {
        let source = try scratchDirectory().appendingPathComponent("shot.mov")
        try Data([1, 2, 3]).write(to: source)
        let sidecar = try AnalysisSidecar(source: source)
        try sidecar.save(["empty": Data()])
        XCTAssertEqual(sidecar.read("empty"), Data())
        var checked = false
        XCTAssertNil(sidecar.read("empty", cancelled: {
            defer { checked = true }
            return checked
        }))
    }

    func testReadingAForeignWriteAheadLogDatabaseCreatesNoLogFiles() throws {
        let source = try scratchDirectory().appendingPathComponent("shot.mov")
        try Data([1, 2, 3]).write(to: source)
        let sidecar = try AnalysisSidecar(source: source)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(sidecar.url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL; CREATE TABLE user_data(value)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: sidecar.url.path + suffix) }
        let original = try Data(contentsOf: sidecar.url)
        XCTAssertEqual(sidecar.status(), "unsupported")
        XCTAssertNil(sidecar.read("index"))
        XCTAssertEqual(sidecar.keys(), [])
        XCTAssertNil(sidecar.sceneReport())
        XCTAssertThrowsError(try sidecar.save(["index": Data()])) {
            XCTAssertEqual(($0 as? CutError)?.code, "unsupported_sidecar")
        }
        XCTAssertEqual(try Data(contentsOf: sidecar.url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).sorted(),
                       ["shot.mov", "shot.mov.cutcache"])
    }

    func testMetadataSaveSucceedsWhileSceneReportIsRead() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Scene-Cadence-Change.mov")
        let copy = try scratchDirectory().appendingPathComponent("Scene-Cadence-Change.mov")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let source = try CutEngine().inspect(copy)
        let sidecar = AnalysisSidecar(media: source)
        _ = try SceneAnalysis.run(source, session: SceneScanSession())
        XCTAssertNotNil(sidecar.sceneReport(for: source))

        let group = DispatchGroup()
        let lock = NSLock()
        var failure: Error?
        DispatchQueue.global(qos: .utility).async(group: group) {
            do {
                try AnalysisSidecar(media: source).save([:], updating: ["updated.analysis": { _ in Data("{}".utf8) }])
            } catch { lock.withLock { failure = error } }
        }
        for _ in 0..<3 { _ = sidecar.sceneReport(for: source) }
        group.wait()
        XCTAssertNil(lock.withLock { failure }.map { "\($0)" })
        XCTAssertEqual(sidecar.read("updated.analysis"), Data("{}".utf8))
    }

    func testSceneScanHonorsSwiftTaskCancellationByDefault() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Scene-Cadence-Change.mov")
        let copy = try scratchDirectory().appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: copy)
        let media = try CutEngine().inspect(copy)
        let codes = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let scans = [
                Result { try SceneAnalysis.scan(copy, useSidecar: false) },
                Result { try SceneAnalysis.scan(media, useSidecar: false) }
            ]
            return scans.map { result in
                switch result {
                case .success: return nil as String?
                case let .failure(error): return (error as? CutError)?.code
                }
            }
        }.value
        XCTAssertEqual(codes, ["cancelled", "cancelled"])
    }

    func testSceneScanReportsAFileRemovedAfterInspectionAsChanged() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Scene-Cadence-Change.mov")
        let copy = try scratchDirectory().appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: copy)
        let engine = CutEngine()
        let preview = try engine.inspectForPreview(copy)
        let media = try engine.inspect(copy)
        try FileManager.default.removeItem(at: copy)
        for inspected in [preview, media] {
            XCTAssertThrowsError(try SceneAnalysis.scan(inspected, useSidecar: false)) {
                XCTAssertEqual(($0 as? CutError)?.code, "source_changed")
            }
        }
    }
}
