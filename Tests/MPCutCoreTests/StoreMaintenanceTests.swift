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

        let result = TranscriptRecognitionStore.clear(in: root, jobs: [])
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

        let result = TranscriptRecognitionStore.clear(in: root, jobs: [])
        withExtendedLifetime(claims) {}
        XCTAssertTrue(files.fileExists(atPath: root.appendingPathComponent(busy).path))
        XCTAssertTrue(files.fileExists(atPath: root.appendingPathComponent(busy + ".mpx").path))
        XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent(free + ".mpx").path))
        XCTAssertTrue(files.fileExists(atPath: archived.path))
        XCTAssertEqual(Set(result.skipped.map(\.url.lastPathComponent)), [busy, "Results"])
        XCTAssertEqual(result.reclaimedBytes, freeBytes)
    }

    /// A silent 16 kHz mono recording, enough for a job record's track.
    private func silentWave(_ url: URL) throws {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let samples: UInt32 = 16_000
        append(samples * 2 + 36)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8))
        append(samples * 2)
        data.append(Data(repeating: 0, count: Int(samples * 2)))
        try data.write(to: url)
    }

    /// Writes a job record whose one track was recognized under `key`, as a paused or failed job leaves it.
    private func writeJob(in directory: URL, key: String, state: TranscriptJobState) throws -> TranscriptJobTrack {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("media-\(UUID().uuidString).wav")
        try silentWave(media)
        var sessions = try TranscriptJobPlan.inventory(media: media)
        var track = try XCTUnwrap(sessions.first?.tracks.first)
        track.recognitionKey = key
        track.hasReusableEvidence = true
        track.state = .recognized
        sessions[0].tracks[0] = track
        let id = UUID()
        let record = TranscriptJobRecord(id: id, documentID: media.path, options: .init(), policy: .reuse, state: state,
                                         sessions: sessions,
                                         workingDirectory: directory.appendingPathComponent(id.uuidString, isDirectory: true))
        try JSONEncoder().encode(record).write(to: TranscriptJobStore(directory: directory).recordURL(id))
        return track
    }

    func testRecognitionClearKeepsWhatAJobRecordCanStillReuse() throws {
        // Desktop and CLI job folders, as the Storage page passes them.
        let desktopJobs = root.appendingPathComponent("Drafts/.transcript-jobs", isDirectory: true)
        let cliJobs = root.appendingPathComponent("TranscriptJobs", isDirectory: true)
        let claims = root.appendingPathComponent("Claims", isDirectory: true)
        let pausedKey = claim("paused-key"), finishedKey = claim("finished-key"), freeKey = claim("free-key")
        let paused = try writeJob(in: desktopJobs, key: pausedKey, state: .cancelled)
        let finished = try writeJob(in: cliJobs, key: finishedKey, state: .completed)
        let pausedClaim = TranscriptExternalCacheDescriptor.claimID(scope: paused.evidence, key: pausedKey)
        let finishedClaim = TranscriptExternalCacheDescriptor.claimID(scope: finished.evidence, key: finishedKey)
        let freeClaim = claim("free-claim")
        for id in [pausedClaim, finishedClaim, freeClaim] {
            try write(claims.appendingPathComponent(id + ".mpx"))
        }
        for key in [pausedKey, finishedKey, freeKey] {
            try write(claims.appendingPathComponent("Results/\(key)/\(claim(key + "-generation"))"))
        }

        let result = TranscriptRecognitionStore.clear(in: claims, jobs: [desktopJobs, cliJobs])
        // A retry or reconcile of either job reads its finished track back from the exchange or the archive.
        for kept in [pausedClaim + ".mpx", finishedClaim + ".mpx", "Results/\(pausedKey)", "Results/\(finishedKey)"] {
            XCTAssertTrue(files.fileExists(atPath: claims.appendingPathComponent(kept).path), kept)
        }
        for gone in [freeClaim + ".mpx", "Results/\(freeKey)"] {
            XCTAssertFalse(files.fileExists(atPath: claims.appendingPathComponent(gone).path), gone)
        }
        let reasons = Dictionary(result.skipped.map { ($0.url.lastPathComponent, $0.reason) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(Set(reasons.keys), [pausedClaim, finishedClaim, pausedKey, finishedKey])
        XCTAssertTrue(reasons.values.allSatisfy { $0.contains("can still reuse") }, "\(reasons)")
        XCTAssertGreaterThan(result.reclaimedBytes, 0)

        // Without the job folders, Clear removes everything, as before.
        let unguarded = TranscriptRecognitionStore.clear(in: claims, jobs: [])
        XCTAssertTrue(unguarded.skipped.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: claims.appendingPathComponent("Results/\(pausedKey)").path))
    }

    func testRecognitionClearKeepsTheArchiveWhenAJobRecordCannotBeRead() throws {
        let jobs = root.appendingPathComponent("TranscriptJobs", isDirectory: true)
        try write(jobs.appendingPathComponent(UUID().uuidString + ".json"), bytes: 16)
        let claims = root.appendingPathComponent("Claims", isDirectory: true)
        let free = claim("free")
        try write(claims.appendingPathComponent(free + ".mpx"))
        let archived = claims.appendingPathComponent("Results/\(claim("key"))/\(claim("generation"))")
        try write(archived)

        let result = TranscriptRecognitionStore.clear(in: claims, jobs: [jobs])
        XCTAssertTrue(files.fileExists(atPath: archived.path))
        XCTAssertFalse(files.fileExists(atPath: claims.appendingPathComponent(free + ".mpx").path))
        XCTAssertEqual(result.skipped.map(\.url.lastPathComponent), ["Results"])
        XCTAssertTrue(result.skipped[0].reason.contains("could not be read"))

        // Pruning never removes an unreadable record, so one older than the prune age no longer keeps the archive.
        let record = try XCTUnwrap(files.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil).first)
        try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -31 * 86_400)], ofItemAtPath: record.path)
        let later = TranscriptRecognitionStore.clear(in: claims, jobs: [jobs])
        XCTAssertTrue(later.skipped.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: archived.path))
    }

    func testRecognitionClearLeavesSymlinkedExchangeTargets() throws {
        let id = claim("linked")
        let outside = files.temporaryDirectory.appendingPathComponent("mpcut-outside-\(UUID().uuidString)")
        try write(outside)
        defer { try? files.removeItem(at: outside) }
        try files.createSymbolicLink(at: root.appendingPathComponent(id + ".mpx"), withDestinationURL: outside)

        let result = TranscriptRecognitionStore.clear(in: root, jobs: [])
        XCTAssertTrue(files.fileExists(atPath: outside.path))
        XCTAssertEqual(result.reclaimedBytes, 0)
        XCTAssertEqual(result.skipped.count, 1)
    }
}
