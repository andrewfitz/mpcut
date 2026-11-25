import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class StoreMaintenanceTests: XCTestCase {
    private var root: URL!
    private let files = FileManager.default

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("mpcut-store-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? files.removeItem(at: root)
    }

    private func write(_ url: URL, bytes: Int = 4_096) throws {
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func allocated(_ url: URL) -> Int64 { (try? StoreMeasurement.allocatedBytes(at: url)) ?? -1 }

    private func lock(_ url: URL, directory: Bool) throws -> Int32 {
        let descriptor = open(url.path, directory ? O_RDONLY | O_DIRECTORY : O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        return descriptor
    }

    // MARK: Measurement

    func testMeasurementCountsRegularFilesSkipsLinksAndExclusions() throws {
        try write(root.appendingPathComponent("a/one"), bytes: 10_000)
        try write(root.appendingPathComponent(".transcript-jobs/two"), bytes: 10_000)
        let outside = files.temporaryDirectory.appendingPathComponent("mpcut-outside-\(UUID().uuidString)")
        try write(outside, bytes: 50_000)
        defer { try? files.removeItem(at: outside) }
        try files.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let one = allocated(root.appendingPathComponent("a/one"))
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(try StoreMeasurement.allocatedBytes(at: root, excluding: [".transcript-jobs"]), one)
        XCTAssertEqual(try StoreMeasurement.allocatedBytes(at: root), 2 * one)
        XCTAssertEqual(try StoreMeasurement.allocatedBytes(at: root.appendingPathComponent("missing")), 0)
        XCTAssertThrowsError(try StoreMeasurement.allocatedBytes(at: root, cancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: Generated stills

    private let digest = String(repeating: "ab", count: 32)

    func testStillsClearRemovesEntriesAndKeepsForeignFilesAndShards() throws {
        let entry = root.appendingPathComponent("3/\(digest)-mov", isDirectory: true)
        try write(entry.appendingPathComponent("picture.mov"), bytes: 20_000)
        try write(entry.appendingPathComponent("sha256"), bytes: 32)
        let other = root.appendingPathComponent("5/\(String(repeating: "cd", count: 32))-mp4", isDirectory: true)
        try write(other.appendingPathComponent("picture.mp4"), bytes: 8_000)
        let staging = root.appendingPathComponent("3/.staging/picture.mov")
        try write(staging)
        let foreign = root.appendingPathComponent("3/notes.txt")
        try write(foreign)
        let unrelated = root.appendingPathComponent("misc/\(digest)-mov/picture.mov")
        try write(unrelated)
        let expected = allocated(entry) + allocated(other)

        let result = GeneratedStillsStore.clear(in: root)
        XCTAssertEqual(result.reclaimedBytes, expected)
        XCTAssertEqual(Set(result.removed.map(\.lastPathComponent)), [entry.lastPathComponent, other.lastPathComponent])
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: entry.path))
        XCTAssertFalse(files.fileExists(atPath: other.path))
        for kept in [staging, foreign, unrelated, root.appendingPathComponent("3"), root.appendingPathComponent("5")] {
            XCTAssertTrue(files.fileExists(atPath: kept.path), kept.path)
        }
    }

    func testStillsClearSkipsAShardInUse() throws {
        let busy = root.appendingPathComponent("1/\(digest)-mov", isDirectory: true)
        try write(busy.appendingPathComponent("picture.mov"))
        let free = root.appendingPathComponent("2/\(digest)-mov", isDirectory: true)
        try write(free.appendingPathComponent("picture.mov"))
        let freeBytes = allocated(free)
        let held = try lock(root.appendingPathComponent("1"), directory: true)
        defer { close(held) }

        let result = GeneratedStillsStore.clear(in: root)
        XCTAssertTrue(files.fileExists(atPath: busy.path))
        XCTAssertFalse(files.fileExists(atPath: free.path))
        XCTAssertEqual(result.skipped.map(\.url.lastPathComponent), ["1"])
        XCTAssertEqual(result.reclaimedBytes, freeBytes)
    }

    func testStillsClearIgnoresSymlinkedShardsAndEntries() throws {
        let target = files.temporaryDirectory.appendingPathComponent("mpcut-target-\(UUID().uuidString)", isDirectory: true)
        let victim = target.appendingPathComponent("\(digest)-mov/picture.mov")
        try write(victim)
        defer { try? files.removeItem(at: target) }
        try files.createSymbolicLink(at: root.appendingPathComponent("4"), withDestinationURL: target)
        try files.createDirectory(at: root.appendingPathComponent("6"), withIntermediateDirectories: false)
        try files.createSymbolicLink(at: root.appendingPathComponent("6/\(digest)-mov"),
                                     withDestinationURL: target.appendingPathComponent("\(digest)-mov"))

        let result = GeneratedStillsStore.clear(in: root)
        XCTAssertEqual(result.reclaimedBytes, 0)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(files.fileExists(atPath: victim.path))
    }

    func testStillsClearOfMissingFolderDoesNothing() {
        let result = GeneratedStillsStore.clear(in: root.appendingPathComponent("missing"))
        XCTAssertEqual(result, StoreClearResult())
    }

    // MARK: Transcript recognition

    private func claim(_ seed: String) -> String { TranscriptStore.digest(Data(seed.utf8)) }

    func testRecognitionClearRemovesFreeClaimsAndArchive() throws {
        let free = claim("free")
        try write(root.appendingPathComponent(free), bytes: 0)
        try write(root.appendingPathComponent(free + ".mpx"), bytes: 10_000)
        try write(root.appendingPathComponent(free + ".json"), bytes: 6_000)
        let orphan = claim("orphan")
        try write(root.appendingPathComponent(orphan + ".mpx"), bytes: 5_000)
        let archived = root.appendingPathComponent("Results/\(claim("key"))/\(claim("generation"))")
        try write(archived, bytes: 12_000)
        let reader = root.appendingPathComponent(TranscriptRecognitionExchange.readerName)
        try write(reader, bytes: 2)
        let foreign = root.appendingPathComponent("notes.mpx")
        try write(foreign)
        let foreignArchive = root.appendingPathComponent("Results/other/file")
        try write(foreignArchive)
        let expected = allocated(root.appendingPathComponent(free + ".mpx")) + allocated(root.appendingPathComponent(free + ".json"))
            + allocated(root.appendingPathComponent(orphan + ".mpx")) + allocated(archived)

        let result = TranscriptRecognitionStore.clear(in: root)
        XCTAssertEqual(result.reclaimedBytes, expected)
        XCTAssertTrue(result.skipped.isEmpty)
        for gone in [free, free + ".mpx", free + ".json", orphan, orphan + ".mpx", "Results/\(claim("key"))"] {
            XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent(gone).path), gone)
        }
        for kept in [reader, foreign, foreignArchive] {
            XCTAssertTrue(files.fileExists(atPath: kept.path), kept.path)
        }
    }

    func testRecognitionClearSkipsLockedClaimsAndKeepsArchive() throws {
        let busy = claim("busy"), free = claim("free")
        for id in [busy, free] {
            try write(root.appendingPathComponent(id), bytes: 0)
            try write(root.appendingPathComponent(id + ".mpx"))
        }
        let archived = root.appendingPathComponent("Results/\(claim("key"))/\(claim("generation"))")
        try write(archived)
        let freeBytes = allocated(root.appendingPathComponent(free + ".mpx"))
        // The same lock a running job takes. flock conflicts between descriptors in one process.
        let claims = TranscriptRecognitionClaims()
        try claims.acquire([busy], in: root, cancelled: { false })

        let result = TranscriptRecognitionStore.clear(in: root)
        withExtendedLifetime(claims) {}
        XCTAssertTrue(files.fileExists(atPath: root.appendingPathComponent(busy).path))
        XCTAssertTrue(files.fileExists(atPath: root.appendingPathComponent(busy + ".mpx").path))
        XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent(free + ".mpx").path))
        XCTAssertTrue(files.fileExists(atPath: archived.path))
        XCTAssertEqual(Set(result.skipped.map(\.url.lastPathComponent)), [busy, "Results"])
        XCTAssertEqual(result.reclaimedBytes, freeBytes)
    }

    func testRecognitionClearLeavesSymlinkedExchangeTargets() throws {
        let id = claim("linked")
        let outside = files.temporaryDirectory.appendingPathComponent("mpcut-outside-\(UUID().uuidString)")
        try write(outside)
        defer { try? files.removeItem(at: outside) }
        try files.createSymbolicLink(at: root.appendingPathComponent(id + ".mpx"), withDestinationURL: outside)

        let result = TranscriptRecognitionStore.clear(in: root)
        XCTAssertTrue(files.fileExists(atPath: outside.path))
        XCTAssertEqual(result.reclaimedBytes, 0)
        XCTAssertEqual(result.skipped.count, 1)
    }
}
