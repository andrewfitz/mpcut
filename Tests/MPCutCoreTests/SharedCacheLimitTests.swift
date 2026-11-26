import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class SharedCacheLimitTests: XCTestCase {
    private let files = FileManager.default

    private struct Fixture {
        let root: URL
        let disk: URL
        /// Oldest first: B, then A, then C. Creation order and size do not follow age.
        let stores: [AnalysisSidecar]
        /// A media-mode cutcache beside its recording, saved before disk mode was chosen.
        let adjacent: AnalysisSidecar
        var folder: URL { disk.appendingPathComponent("MPCut Cache", isDirectory: true) }
    }

    /// Three disk-mode cutcaches in an isolated sidecar home. `diskName` names the shared folder the user chose.
    private func fixture(diskName: String = "shared", _ body: (Fixture) throws -> Void) throws {
        let root = files.temporaryDirectory.appendingPathComponent("mpcut-limit-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("preferences")) {
            let media = root.appendingPathComponent("D.mov")
            try Data([9, 9, 9]).write(to: media)
            let adjacent = try AnalysisSidecar(source: media)
            try adjacent.save(["waveform_peaks.v1.0": Data(repeating: 4, count: 8_192)])
            try files.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: adjacent.url.path)
            let disk = root.appendingPathComponent(diskName, isDirectory: true)
            try files.createDirectory(at: disk, withIntermediateDirectories: false)
            try SidecarLocations.chooseDisk(disk)
            try SidecarLocations.setMode(.disk)
            var stores: [(age: Double, store: AnalysisSidecar)] = []
            for (index, (name, age)) in [("A.mov", 9.0), ("B.mov", 10), ("C.mov", 8)].enumerated() {
                let source = root.appendingPathComponent(name)
                try Data([UInt8(index), 1, 2]).write(to: source)
                let store = try AnalysisSidecar(source: source)
                let payload = Data((0..<(40_000 * (index + 1))).map { _ in UInt8.random(in: 0...255) })
                try store.save(["waveform_peaks.v1.0": payload])
                try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age * 86_400)],
                                        ofItemAtPath: store.url.path)
                stores.append((age, store))
            }
            let fixture = Fixture(root: root, disk: disk, stores: stores.sorted { $0.age > $1.age }.map(\.store),
                                  adjacent: adjacent)
            XCTAssertEqual(fixture.stores.map(\.source.lastPathComponent), ["B.mov", "A.mov", "C.mov"])
            XCTAssertFalse(adjacent.url.path.contains("MPCut Cache"))
            for store in fixture.stores {
                XCTAssertTrue(store.url.path.hasPrefix(AnalysisSidecar.canonicalSource(fixture.folder).path), store.url.path)
            }
            try body(fixture)
        }
    }

    private func bytes(_ url: URL) -> Int64 { (try? StoreMeasurement.allocatedBytes(at: url)) ?? 0 }
    private func exists(_ store: AnalysisSidecar) -> Bool { files.fileExists(atPath: store.url.path) }

    func testZeroLimitOrMissingRootDoesNothing() throws {
        try fixture { fixture in
            let none = SharedCacheLimit.enforce(limit: 0, protected: [], root: fixture.disk)
            XCTAssertEqual(none.reclaimedBytes, 0)
            XCTAssertEqual(none.bytesBefore, 0)
            XCTAssertTrue(none.removed.isEmpty)
            XCTAssertTrue(SharedCacheLimit.enforce(limit: 1, protected: [], root: nil).removed.isEmpty)
            XCTAssertTrue(fixture.stores.allSatisfy(exists))
        }
    }

    func testUnderTheLimitDoesNothing() throws {
        try fixture { fixture in
            let total = bytes(fixture.folder)
            let outcome = SharedCacheLimit.enforce(limit: total, protected: [], root: fixture.disk)
            XCTAssertEqual(outcome.bytesBefore, total)
            XCTAssertEqual(outcome.bytesAfter, total)
            XCTAssertTrue(outcome.removed.isEmpty)
            XCTAssertTrue(fixture.stores.allSatisfy(exists))
        }
    }

    func testRemovesLeastRecentlyWrittenFirstUntilUnderTheLimit() throws {
        try fixture { fixture in
            let total = bytes(fixture.folder)
            let oldest = bytes(fixture.stores[0].url)
            let outcome = SharedCacheLimit.enforce(limit: total - oldest, protected: [], root: fixture.disk)
            XCTAssertFalse(exists(fixture.stores[0]))
            XCTAssertTrue(exists(fixture.stores[1]))
            XCTAssertTrue(exists(fixture.stores[2]))
            XCTAssertEqual(outcome.reclaimedBytes, oldest)
            XCTAssertEqual(outcome.removed.map(\.lastPathComponent), [fixture.stores[0].url.lastPathComponent])
            XCTAssertEqual(outcome.removedSources.map(\.lastPathComponent), ["B.mov"])
            XCTAssertEqual(outcome.bytesBefore, total)
            XCTAssertLessThanOrEqual(outcome.bytesAfter, total - oldest)
            XCTAssertTrue(outcome.skipped.isEmpty)

            // The next pass continues in age order: C is newest and stays.
            let second = SharedCacheLimit.enforce(limit: 1, protected: [fixture.stores[2].source], root: fixture.disk)
            XCTAssertFalse(exists(fixture.stores[1]))
            XCTAssertTrue(exists(fixture.stores[2]))
            XCTAssertEqual(second.removed.count, 1)
        }
    }

    func testAChosenFolderNamedMPCutCacheIsEnforced() throws {
        // The managed folder is then `<chosen>/MPCut Cache`; the chosen folder's name is not stripped.
        try fixture(diskName: "MPCut Cache") { fixture in
            XCTAssertEqual(fixture.folder.deletingLastPathComponent().lastPathComponent, "MPCut Cache")
            let total = bytes(fixture.folder)
            XCTAssertGreaterThan(total, 0)
            let outcome = SharedCacheLimit.enforce(limit: total - 1, protected: [], root: fixture.disk)
            XCTAssertEqual(outcome.bytesBefore, total)
            XCTAssertEqual(outcome.removed.map(\.lastPathComponent), [fixture.stores[0].url.lastPathComponent])
            XCTAssertFalse(exists(fixture.stores[0]))
        }
    }

    func testARecordingProtectedDuringTheRunKeepsItsCacheAndTheNextOldestGoes() throws {
        try fixture { fixture in
            let total = bytes(fixture.folder)
            let second = bytes(fixture.stores[1].url)
            let asked = Counter()
            // A project that lists B, the oldest, opens after the run started with nothing protected.
            let outcome = SharedCacheLimit.enforce(limit: total - second, protected: [], root: fixture.disk, recheck: {
                asked.increment()
                return [fixture.stores[0].source]
            })
            XCTAssertGreaterThanOrEqual(asked.value, 2, "Asked before each removal")
            XCTAssertTrue(exists(fixture.stores[0]))
            XCTAssertFalse(exists(fixture.stores[1]))
            XCTAssertTrue(exists(fixture.stores[2]))
            XCTAssertEqual(outcome.skipped.first { $0.key.lastPathComponent == fixture.stores[0].url.lastPathComponent }?.value,
                           "An open project uses this cache.")
            XCTAssertFalse(outcome.aborted)
            XCTAssertEqual(outcome.removedSources.map(\.lastPathComponent), ["A.mov"])
        }
    }

    func testARecheckThatAnswersNilStopsBeforeAnyRemoval() throws {
        try fixture { fixture in
            let outcome = SharedCacheLimit.enforce(limit: 1, protected: [], root: fixture.disk, recheck: { nil })
            XCTAssertTrue(outcome.aborted)
            XCTAssertTrue(outcome.removed.isEmpty)
            XCTAssertTrue(fixture.stores.allSatisfy(exists))
            XCTAssertEqual(outcome.bytesAfter, outcome.bytesBefore)
        }
    }

    func testTheFolderItselfIsNotARoot() throws {
        // `root` is always the chosen folder. Passing its managed child reads `<child>/MPCut Cache`, which is empty.
        try fixture { fixture in
            let outcome = SharedCacheLimit.enforce(limit: 1, protected: [], root: fixture.folder)
            XCTAssertTrue(outcome.removed.isEmpty)
            XCTAssertTrue(fixture.stores.allSatisfy(exists))
        }
    }

    func testProtectedRecordingOrCacheSurvivesAndTheNextOldestGoes() throws {
        try fixture { fixture in
            let total = bytes(fixture.folder)
            let oldest = bytes(fixture.stores[0].url)
            let protected: Set<URL> = [fixture.stores[0].source, fixture.stores[1].url]
            let outcome = SharedCacheLimit.enforce(limit: total - oldest, protected: protected, root: fixture.disk)
            XCTAssertTrue(exists(fixture.stores[0]))
            XCTAssertTrue(exists(fixture.stores[1]))
            XCTAssertFalse(exists(fixture.stores[2]))
            XCTAssertEqual(Set(outcome.skipped.keys.map(\.lastPathComponent)),
                           [fixture.stores[0].url.lastPathComponent, fixture.stores[1].url.lastPathComponent])
            XCTAssertEqual(outcome.reclaimedBytes, outcome.bytesBefore - outcome.bytesAfter)
        }
    }

    func testCacheInUseIsSkipped() throws {
        try fixture { fixture in
            let total = bytes(fixture.folder)
            let reader = try SidecarDatabase(fixture.stores[0].url, writing: false)
            try reader.execute("BEGIN")
            _ = try reader.integer("SELECT count(*) FROM sections")
            let outcome = SharedCacheLimit.enforce(limit: total - 1, protected: [], root: fixture.disk)
            try reader.execute("ROLLBACK")
            XCTAssertTrue(exists(fixture.stores[0]))
            XCTAssertFalse(exists(fixture.stores[1]))
            XCTAssertTrue(exists(fixture.stores[2]))
            XCTAssertNotNil(outcome.skipped.keys.first { $0.lastPathComponent == fixture.stores[0].url.lastPathComponent })
        }
    }

    func testOnlyManagedLayoutInsideTheRootIsTouched() throws {
        try fixture { fixture in
            // A same-named file outside the layout, a forged cache and an adjacent cache stay.
            let shard = fixture.stores[0].url.deletingLastPathComponent()
            let forged = shard.appendingPathComponent(shard.lastPathComponent + String(repeating: "0", count: 62) + ".cutcache")
            try Data(repeating: 1, count: 4_096).write(to: forged)
            try files.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: forged.path)
            let loose = fixture.folder.appendingPathComponent("notes.cutcache")
            try Data(repeating: 1, count: 4_096).write(to: loose)
            let other = fixture.root.appendingPathComponent("elsewhere/MPCut Cache/ab", isDirectory: true)
            try files.createDirectory(at: other, withIntermediateDirectories: true)
            let outside = other.appendingPathComponent("ab" + String(repeating: "1", count: 62) + ".cutcache")
            try Data(repeating: 1, count: 4_096).write(to: outside)

            let outcome = SharedCacheLimit.enforce(limit: 1, protected: [], root: fixture.disk)
            for kept in [forged, loose, outside, fixture.adjacent.url] {
                XCTAssertTrue(files.fileExists(atPath: kept.path), kept.path)
            }
            XCTAssertNotNil(outcome.skipped.keys.first { $0.lastPathComponent == forged.lastPathComponent })
            XCTAssertEqual(Set(outcome.removed.map(\.lastPathComponent)), Set(fixture.stores.map(\.url.lastPathComponent)))
            XCTAssertTrue(outcome.removed.allSatisfy { $0.path.hasPrefix(AnalysisSidecar.canonicalSource(fixture.folder).path) })
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
