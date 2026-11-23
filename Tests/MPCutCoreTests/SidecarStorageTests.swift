import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MPCutCore

final class SidecarStorageTests: XCTestCase {
    private func makeSidecar() throws -> AnalysisSidecar {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("shot.mov")
        try Data([1, 2, 3]).write(to: source)
        return try AnalysisSidecar(source: source)
    }

    func testReadOnlyLookupAndSelectiveIntegrity() throws {
        let sidecar = try makeSidecar()
        XCTAssertEqual(sidecar.url.lastPathComponent, "shot.mov.cutdb")
        XCTAssertEqual(sidecar.status(), "missing")
        XCTAssertNil(sidecar.read("a"))
        XCTAssertEqual(sidecar.keys(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.url.path))

        try sidecar.save(["a": Data([1, 2]), "b": Data()])
        XCTAssertEqual(sidecar.status(), "current")
        XCTAssertEqual(sidecar.read("b"), Data())
        XCTAssertNil(sidecar.read("a", maxBytes: 1))
        XCTAssertEqual(sidecar.read("a", maxBytes: 2), Data([1, 2]))
        AnalysisSidecar.$readsEnabled.withValue(false) {
            XCTAssertNil(sidecar.read("a"))
            XCTAssertEqual(sidecar.keys(), [])
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(sidecar.url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE sections SET value = X'0304' WHERE name = 'a'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        XCTAssertNil(sidecar.read("a"))
        XCTAssertEqual(sidecar.read("b"), Data())
        try sidecar.save(["a": Data([3, 4])])
        XCTAssertEqual(sidecar.read("a"), Data([3, 4]))
        XCTAssertEqual(sidecar.keys(), ["a", "b"])
    }

    func testPackedActivityPreservesExactProviderBytesAndReadLimit() throws {
        let store = try makeSidecar()
        let key = "transcript_activity.v1.0.track"
        let levels = ["0", "-0", "1.0000000000000001", "4.513611e-05", "3E+00"]
        let rows = (0..<1200).map { index in
            let end = (index + 1) * 320 - (index == 1199 ? 63 : 0)
            return #"{"end_sample":\#(end),"level":\#(levels[index % levels.count]),"start_sample":\#(index * 320)}"#
        }
        let value = Data((#"{"activity":["# + rows.joined(separator: ",") + #"],"extra":"☀"}"#).utf8)
        try store.save([key: value])
        let db = try SidecarDatabase(store.url, writing: false)
        XCTAssertLessThan(try db.integer("SELECT length(value) FROM sections"), Int32(value.count / 10))
        XCTAssertEqual(try db.integer("SELECT hex(substr(value, 1, 1)) = '03' FROM sections"), 1)
        XCTAssertNil(store.read(key, maxBytes: value.count - 1))
        XCTAssertEqual(store.read(key, maxBytes: value.count), value)
        let irregular = Data(String(decoding: value, as: UTF8.self)
            .replacingOccurrences(of: "end_sample\":320,", with: "end_sample\":300,").utf8)
        try store.save([key: irregular])
        XCTAssertEqual(try db.integer("SELECT hex(substr(value, 1, 1)) = '01' FROM sections"), 1)
        XCTAssertEqual(store.read(key), irregular)
        try db.execute("UPDATE sections SET value = X'017F'")
        XCTAssertNil(store.read(key))
        try store.save([:], updating: [key: { previous in
            XCTAssertNil(previous)
            return value
        }])
        XCTAssertEqual(store.read(key), value)
    }

    func testPacketRunsPreserveClockChangesFlagsAndOpaqueTail() throws {
        var value = Data()
        for i in 0..<1700 {
            let timestamp = UInt16(i * 2)  // Zigzag, then unsigned LEB128.
            var row: [UInt8] = [i < 500 ? 1 : 0]
            if timestamp < 128 { row.append(UInt8(timestamp)) }
            else { row += [UInt8(timestamp & 127) | 128, UInt8(timestamp >> 7)] }
            row += [1, 2, 1, 0, 0, i == 800 ? 6 : 8]
            value.append(contentsOf: row)
        }
        value.append(contentsOf: [255, 255, 0, 2])
        let payload = try SidecarPayload.encode(value, key: "media_index_audio.v1", cancelled: { false })
        XCTAssertTrue([4, 5].contains(try XCTUnwrap(payload.bytes.first)))
        XCTAssertLessThan(payload.bytes.count, 256)
        XCTAssertEqual(try payload.decode(cancelled: { false }), value)
    }

    func testCheckpointAndMarkerCompressionPreserveResumption() throws {
        let store = try makeSidecar()
        let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "a"))
        let checkpoint = Data(repeating: 7, count: 8000)
        let markers = Data(repeating: 4, count: 9000)
        try store.commitSceneAttempt(claim, checkpoint: checkpoint, markerBatch: markers, coveredThrough: 1, complete: false)
        XCTAssertEqual(store.sceneAttempt(claim)?.checkpoint, checkpoint)
        XCTAssertEqual(store.sceneAttempt(claim)?.markerBatches, [markers])
        let db = try SidecarDatabase(store.url, writing: false)
        XCTAssertLessThan(try db.integer("SELECT length(checkpoint) FROM scene_attempts"), 500)
        XCTAssertLessThan(try db.integer("SELECT length(value) FROM scene_markers"), 500)
    }

    func testFormatThreeIsReadOnlyUntilAnAtomicWriteCompactsIt() throws {
        let store = try makeSidecar()
        let key = AnalysisSidecar.viewNameSectionKey
        let value = Data(repeating: 65, count: 300_000)
        try store.save(["small": Data([7])])
        let db = try SidecarDatabase(store.url, writing: true)
        for table in ["sections", "archived_sections", "scene_markers", "scene_attempts"] {
            try db.execute("ALTER TABLE \(table) DROP COLUMN logical_size")
        }
        try db.execute("PRAGMA user_version = 3")
        let stamp = try store.storedStamp(db)
        let digest = Data(SHA256.hash(data: Data((stamp + "\0" + key + "\0").utf8) + value))
        try db.updateBlobs("INSERT INTO sections(name, value, digest) VALUES (?, ?, ?)", [key], blobs: [value, digest])
        try db.update("INSERT INTO archived_sections SELECT 1, name, digest, value FROM sections WHERE name = ?", [key])
        let before = try Data(contentsOf: store.url)
        XCTAssertEqual(store.read(key), value)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        // Fail after the migration, before committing the caller's update.
        XCTAssertThrowsError(try store.save([:], updating: ["small": { _ in throw CancellationError() }]))
        XCTAssertEqual(try db.integer("PRAGMA user_version"), 3)
        XCTAssertEqual(store.read(key), value)

        try store.save(["another": Data([8])])
        XCTAssertEqual(try db.integer("PRAGMA user_version"), 4)
        XCTAssertEqual(store.read(key), value)
        XCTAssertEqual(store.read("small"), Data([7]))
        let reader = try XCTUnwrap(store.openReadSnapshot())
        XCTAssertEqual(try store.verifiedSection(key, in: reader, stamp: stamp, maxBytes: nil,
                                                cancelled: { false }, generation: "1"), value)
        XCTAssertLessThan(try Data(contentsOf: store.url).count, before.count / 2)
    }

    func testProjectHistoryExcludesOnlyCollidingCachesEvenWhenNoStepsAreRestored() throws {
        let cache = try makeSidecar()
        let folder = cache.source.deletingLastPathComponent()
        let other = folder.appendingPathComponent("Other.mov")
        try Data([4, 5]).write(to: other)
        let otherCache = try AnalysisSidecar(source: other)
        let document = folder.appendingPathComponent("Edit.cut")
        func clip(_ name: String) -> CutSequenceClip {
            .init(id: name, file: name, from: .zero, to: .init(numerator: 1))
        }
        let current = CutProject.sequence([clip(cache.source.lastPathComponent), clip(other.lastPathComponent)])
        let history = CutHistoryState(action: "Remove Source",
                                      project: .sequence([clip(cache.url.lastPathComponent)]))
        try current.save(to: document, undo: [history], redo: [])
        let opened = try CutProject.loadEditorDocument(from: document, limit: 0)
        XCTAssertTrue(opened.undo.isEmpty)
        let blocked = opened.media.sidecarExclusions(relativeTo: document)
        XCTAssertTrue(AnalysisSidecar.isExcluded(cache.source, in: blocked))
        XCTAssertFalse(AnalysisSidecar.isExcluded(other, in: blocked))
        try AnalysisSidecar.$excludedSources.withValue(blocked) {
            cache.saveAutomatically(["peek": Data([1])])
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.url.path))
            XCTAssertThrowsError(try cache.save(["manual": Data()]))
            otherCache.saveAutomatically(["peek": Data([2])])
            XCTAssertEqual(otherCache.read("peek"), Data([2]))
        }
        try cache.save(["old": Data([1])])
        let before = try Data(contentsOf: cache.url)
        AnalysisSidecar.$excludedSources.withValue(blocked) {
            XCTAssertEqual(cache.keys(), [])
            XCTAssertNil(cache.read("old"))
            XCTAssertEqual(cache.status(), "excluded")
            cache.saveAutomatically(["new": Data([3])])
        }
        XCTAssertEqual(try Data(contentsOf: cache.url), before)
    }

    func testSidecarExclusionsFollowCameraAliasesJournalTargetsAndHardLinks() throws {
        let cache = try makeSidecar()
        let folder = cache.source.deletingLastPathComponent()
        let sourceAlias = folder.appendingPathComponent("selected.mov")
        try FileManager.default.createSymbolicLink(at: sourceAlias, withDestinationURL: cache.source)
        let protected = folder.appendingPathComponent("offline.wav")
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let destination = URL(fileURLWithPath: cache.url.path + suffix)
            try FileManager.default.createSymbolicLink(at: protected, withDestinationURL: destination)
            let blocked = CutProject.sidecarExclusions(absoluteSources: [protected.path: "mic"], candidates: [sourceAlias])
            XCTAssertTrue(AnalysisSidecar.isExcluded(cache.source, in: blocked), suffix)
            XCTAssertTrue(AnalysisSidecar.isExcluded(sourceAlias, in: blocked), suffix)
            try FileManager.default.removeItem(at: protected)
        }
        try Data([1]).write(to: cache.url)
        try FileManager.default.linkItem(at: cache.url, to: protected)
        XCTAssertTrue(AnalysisSidecar.isExcluded(cache.source, in: CutProject.sidecarExclusions(
            absoluteSources: [protected.path: "mic"], candidates: [cache.source])))
        if try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
            let caseVariant = folder.appendingPathComponent(cache.url.lastPathComponent.uppercased())
            XCTAssertTrue(AnalysisSidecar.isExcluded(sourceAlias, in: CutProject.sidecarExclusions(
                absoluteSources: [caseVariant.path: "mic"], candidates: [sourceAlias])))
        }
    }

    func testStaleSourceCannotPublishAndRefreshDropsOldSections() throws {
        let old = try makeSidecar()
        try old.save(["index": Data([1]), "scenes": Data([2])])
        try Data([7, 8, 9, 10]).write(to: old.source)
        XCTAssertNil(old.read("index"))
        XCTAssertThrowsError(try old.save(["other": Data()]))
        let fresh = try AnalysisSidecar(source: old.source)
        XCTAssertEqual(fresh.status(), "stale")
        XCTAssertEqual(fresh.keys(), [])
        try fresh.save(["wave": Data([3])])
        XCTAssertEqual(fresh.keys(), ["wave"])
        XCTAssertNil(old.read("wave"))
        XCTAssertEqual(fresh.read("wave"), Data([3]))
    }

    func testCancellationLeavesExistingGenerationIntact() throws {
        let sidecar = try makeSidecar()
        let data = Data(repeating: 5, count: 2 << 20)
        var checks = 0
        func cancelDuringWrite() -> Bool {
            checks += 1
            return checks >= 4
        }
        XCTAssertThrowsError(try sidecar.save(["new": data], cancelled: cancelDuringWrite))
        XCTAssertEqual(sidecar.status(), "missing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sidecar.source.deletingLastPathComponent().path), ["shot.mov"])
        try sidecar.save(["old": Data([1])])
        checks = 0
        XCTAssertThrowsError(try sidecar.save(["old": data, "new": data], cancelled: cancelDuringWrite))
        XCTAssertEqual(sidecar.keys(), ["old"])
        XCTAssertEqual(sidecar.read("old"), Data([1]))
    }

    func testConcurrentSaveMergesIndependentSections() throws {
        let sidecar = try makeSidecar()
        let lock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do { try sidecar.save(["stream.\(index)": Data([UInt8(index)])]) }
            catch { lock.withLock { failures.append(error) } }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        for index in 0..<8 { XCTAssertEqual(sidecar.read("stream.\(index)"), Data([UInt8(index)])) }
    }

    func testRelatedSectionsStayInOneGenerationDuringAReplacement() throws {
        let source = try makeSidecar().source
        let old = Data([1]), new = Data([2])
        // Publish a second complete database with the same source identity.
        let alias = source.deletingLastPathComponent().appendingPathComponent("alias.mov")
        XCTAssertEqual(link(source.path, alias.path), 0)
        // Creating the alias changes ctime. Pin both snapshots after linking.
        let sidecar = try AnalysisSidecar(source: source)
        try sidecar.save(["header": old, "rows": old])
        let replacement = try AnalysisSidecar(source: alias)
        try replacement.save(["header": new, "rows": new])

        let rows = try sidecar.withReadSnapshot(cancelled: { false }) { read in
            XCTAssertEqual(read("header"), old)
            XCTAssertEqual(rename(replacement.url.path, sidecar.url.path), 0)
            XCTAssertEqual(sidecar.read("rows"), new)
            return read("rows")
        }
        XCTAssertEqual(rows, old)
        XCTAssertEqual(sidecar.read("header"), new)
    }

    func testRetentionOnlyPrunesOldRowsWithTheLiteralPrefix() throws {
        let sidecar = try makeSidecar()
        try sidecar.save(["tile%.1": Data(), "tile2": Data(), "scenes": Data()])
        try sidecar.save(["tile%.2": Data()])
        try sidecar.save(["tile%.1": Data([1])])
        try sidecar.save(["tile%.3": Data()], retainingLatest: ["tile%.": 2])
        XCTAssertEqual(sidecar.keys(), ["scenes", "tile%.1", "tile%.3", "tile2"])
        XCTAssertEqual(sidecar.read("tile%.1"), Data([1]))
    }

    func testConcurrentMetadataEditsMergeWhenAutomaticReadsAreDisabled() throws {
        let sidecar = try makeSidecar()
        let lock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                try AnalysisSidecar.$readsEnabled.withValue(false) {
                    try sidecar.save([:], updating: ["metadata": { current in
                        var bytes = current ?? Data()
                        bytes.append(UInt8(index))
                        return bytes
                    }])
                }
            } catch { lock.withLock { failures.append(error) } }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(try XCTUnwrap(sidecar.read("metadata")).sorted(), (0..<8).map(UInt8.init))
        XCTAssertThrowsError(try sidecar.save(["metadata": Data()], updating: ["metadata": { _ in Data() }]))
    }

    func testCancelsPromptlyWhileAnotherWriterHoldsALock() throws {
        let sidecar = try makeSidecar()
        try sidecar.save(["a": Data()])
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(sidecar.url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        for begin in ["BEGIN IMMEDIATE", "BEGIN EXCLUSIVE"] {
            XCTAssertEqual(sqlite3_exec(handle, begin, nil, nil, nil), SQLITE_OK)
            let start = ContinuousClock.now
            XCTAssertThrowsError(try sidecar.save(["b": Data()], cancelled: { .now >= start + .milliseconds(100) })) {
                XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
            }
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            XCTAssertEqual(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sidecar.keys(), ["a"])
    }

    func testSavePreservesForeignFilesAndLinks() throws {
        let sidecar = try makeSidecar()
        let original = Data([8, 7, 6])
        try original.write(to: sidecar.url)
        XCTAssertThrowsError(try sidecar.save(["x": Data()]))
        XCTAssertEqual(try Data(contentsOf: sidecar.url), original)
        try FileManager.default.removeItem(at: sidecar.url)
        try FileManager.default.createSymbolicLink(at: sidecar.url, withDestinationURL: sidecar.source)
        XCTAssertThrowsError(try sidecar.save(["x": Data()]))
        try FileManager.default.removeItem(at: sidecar.url)
        XCTAssertEqual(link(sidecar.source.path, sidecar.url.path), 0)
        XCTAssertThrowsError(try sidecar.save(["x": Data()]))
        XCTAssertEqual(try Data(contentsOf: sidecar.source), Data([1, 2, 3]))
    }

    func testInspectingForeignDatabaseLeavesItsDirectoryUntouched() throws {
        let sidecar = try makeSidecar()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(sidecar.url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL; CREATE TABLE user_data(value)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let directory = sidecar.source.deletingLastPathComponent()
        let original = try Data(contentsOf: sidecar.url)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(sidecar.status(), "unsupported")
        XCTAssertNil(sidecar.read("index"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), files)
        XCTAssertThrowsError(try sidecar.save(["index": Data()]))
        XCTAssertEqual(try Data(contentsOf: sidecar.url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), files)
    }
}
