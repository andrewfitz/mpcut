import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MPCutCore

/// Builds sidecars as the format 1 and format 2 builds wrote them: the schema, section
/// names and encodings are those of commits 8bdd642 (format 1) and 30b3b28 (format 2).
private enum LegacySidecar {
    struct Scenes: Encodable {
        struct Marker: Encodable {
            let pts: Int64
            let view: Int
        }
        var origin = RationalTime.zero
        var duration = RationalTime(numerator: 10)
        var timeBase = RationalTime(numerator: 1, denominator: 10)
        var markers = [Marker(pts: 0, view: 1), Marker(pts: 40, view: 2), Marker(pts: 70, view: 1)]
    }

    static let thresholds = Data(#"{"1":-35,"3":-42.5}"#.utf8)
    static let names = Data(#"{"2":"Wide"}"#.utf8)
    static var scenes: Data { try! JSONEncoder().encode(Scenes()) }

    /// Everything a real file of either format could hold, including analysis and
    /// the still older scene sections that format 1 builds read as a fallback.
    static var everything: [String: Data] {
        ["thresholdOverrides.v1": thresholds, "scenes.v2": scenes, "viewNames.v2": names,
         "scenes.v1": scenes, "viewNames.v1": Data(#"{"1":"Old name"}"#.utf8),
         "index.v1": Data([1]), "index.frames.v1": Data(repeating: 2, count: 60_000),
         "index.audio.v1": Data(repeating: 3, count: 60_000), "source.evidence.v1": Data([4]),
         "wave.v1.1": Data(repeating: 5, count: 200_000), "envelope.v2.1": Data(repeating: 6, count: 9_000),
         "silence.v1.1.auto.3fe0000000000000": Data([7]), "calibration.v1.1": Data([8]),
         "scene.clock.v1": Data([9]), "filmstrip.v1.0.4020.4040": Data(repeating: 10, count: 100_000)]
    }

    static func stamp(of source: URL) throws -> String {
        var info = stat()
        guard stat(source.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }

    static func write(_ sections: [String: Data], for source: URL, version: Int32, stamp: String? = nil,
                      applicationID: Int32 = AnalysisSidecar.applicationID) throws {
        let url = source.appendingPathExtension("cutdb")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        var schema = """
            PRAGMA auto_vacuum = FULL;
            BEGIN IMMEDIATE;
            PRAGMA application_id = \(applicationID);
            PRAGMA user_version = 1;
            CREATE TABLE source(id INTEGER PRIMARY KEY CHECK(id = 1), stamp TEXT NOT NULL);
            CREATE TABLE sections(name TEXT PRIMARY KEY NOT NULL, digest BLOB NOT NULL, value BLOB NOT NULL);
            """
        if version != 1 {
            schema += """
                CREATE TABLE source_generations(id INTEGER PRIMARY KEY, stamp TEXT NOT NULL, reason TEXT NOT NULL);
                CREATE TABLE archived_sections(
                    generation INTEGER NOT NULL, name TEXT NOT NULL, digest BLOB NOT NULL, value BLOB NOT NULL,
                    PRIMARY KEY(generation, name)
                );
                CREATE TABLE scene_attempts(
                    ordinal INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, generation INTEGER NOT NULL,
                    scope TEXT NOT NULL, operation TEXT, owner TEXT, fence INTEGER NOT NULL,
                    expires REAL NOT NULL, state INTEGER NOT NULL DEFAULT 0,
                    covered REAL NOT NULL DEFAULT 0, marker_count INTEGER NOT NULL DEFAULT 0,
                    checkpoint BLOB, checkpoint_digest BLOB,
                    UNIQUE(generation, scope, operation)
                );
                CREATE INDEX scene_attempt_scope ON scene_attempts(generation, scope, ordinal);
                CREATE TABLE scene_markers(
                    attempt TEXT NOT NULL, ordinal INTEGER NOT NULL, value BLOB NOT NULL, digest BLOB NOT NULL,
                    PRIMARY KEY(attempt, ordinal)
                );
                CREATE TABLE scene_reports(
                    generation INTEGER NOT NULL, scope TEXT NOT NULL, attempt TEXT NOT NULL,
                    PRIMARY KEY(generation, scope)
                );
                CREATE INDEX scene_report_attempt ON scene_reports(attempt);
                PRAGMA user_version = \(version);
                """
        }
        let created = sqlite3_exec(handle, schema + "COMMIT;", nil, nil, nil)
        sqlite3_close(handle)
        guard created == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }

        let saved = try stamp ?? self.stamp(of: source)
        let db = try SidecarDatabase(url, writing: true)
        try db.execute("BEGIN IMMEDIATE")
        try db.update("INSERT INTO source(id, stamp) VALUES(1, ?)", [saved])
        for (name, value) in sections {
            let digest = Data(SHA256.hash(data: Data((saved + "\0" + name + "\0").utf8) + value))
            try db.updateBlobs("INSERT INTO sections(name, digest, value) VALUES(?, ?, ?)", [name], blobs: [digest, value])
        }
        if version != 1 {
            try db.update("INSERT INTO source_generations(id, stamp, reason) VALUES(1, ?, 'initial')", [saved])
            try db.updateBlobs("INSERT INTO archived_sections(generation, name, digest, value) VALUES(1, 'scenes.v2', ?, ?)",
                               [], blobs: [Data(count: 32), Data([1])])
            try db.updateBlobs("""
                INSERT INTO scene_attempts(id, generation, scope, fence, expires, state, checkpoint)
                VALUES('attempt', 1, 'full', 1, 0, 1, ?)
                """, [], blobs: [Data(repeating: 1, count: 20_000)])
        }
        try db.execute("COMMIT")
    }
}

final class SidecarLegacyFormatTests: XCTestCase {
    /// A recording in a temporary folder, with the sidecar catalog and clear markers kept there too.
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("preferences")) {
            let source = root.appendingPathComponent("A.mov")
            try Data([1, 2, 3]).write(to: source)
            try body(root, source)
        }
    }

    /// The recording's folder without the preferences this fixture keeps beside it.
    private func files(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "preferences" }.sorted()
    }

    private func version(of url: URL) throws -> Int32 {
        try SidecarDatabase(url, writing: false).integer("PRAGMA user_version")
    }

    private func entry(for source: URL) throws -> SidecarCacheEntry {
        try XCTUnwrap(SidecarCacheCleaner.preview(sources: [source]).first {
            $0.url.lastPathComponent == source.lastPathComponent + ".cutdb"
        })
    }

    func testAWriteReplacesAnOlderFormatAndCarriesWhatTheUserSet() throws {
        for format: Int32 in [1, 2] {
            try fixture { root, source in
                try LegacySidecar.write(LegacySidecar.everything, for: source, version: format)
                let store = try AnalysisSidecar(source: source)
                let old = try Data(contentsOf: store.url)
                // Reads and inspection leave the older file alone.
                XCTAssertEqual(store.status(), "unsupported")
                XCTAssertNil(store.read(AnalysisSidecar.silenceThresholdOverridesKey))
                XCTAssertEqual(store.keys(), [])
                XCTAssertEqual(try Data(contentsOf: store.url), old)

                store.saveAutomatically(["waveform_peaks.v1.1": Data([42])])
                XCTAssertEqual(store.status(), "current")
                XCTAssertEqual(try version(of: store.url), AnalysisSidecar.schemaVersion)
                XCTAssertEqual(store.read("waveform_peaks.v1.1"), Data([42]))
                XCTAssertLessThan(try Data(contentsOf: store.url).count, old.count / 4)
                XCTAssertEqual(try files(in: root), ["A.mov", "A.mov.cutdb"])

                // Carried: manual thresholds, scene boundaries and the names of their views.
                XCTAssertEqual(store.read(AnalysisSidecar.silenceThresholdOverridesKey), LegacySidecar.thresholds)
                XCTAssertEqual(store.read(AnalysisSidecar.viewNameSectionKey), LegacySidecar.names)
                let report = try XCTUnwrap(store.sceneReport())
                XCTAssertEqual(report.scenes.map(\.startPTS), [0, 40, 70])
                XCTAssertEqual(report.scenes.map(\.view), [1, 2, 1])
                XCTAssertEqual(report.timeBase, RationalTime(numerator: 1, denominator: 10))
                XCTAssertEqual(report.duration, RationalTime(numerator: 10))
                XCTAssertEqual(report.views.map(\.name), [nil, "Wide"])

                // Not carried: every analysis, the still older scene sections, history and scene attempts.
                XCTAssertEqual(store.keys(), [AnalysisSidecar.sceneSectionKey, AnalysisSidecar.viewNameSectionKey,
                                              AnalysisSidecar.silenceThresholdOverridesKey, "waveform_peaks.v1.1"].sorted())
                let db = try SidecarDatabase(store.url, writing: false)
                XCTAssertEqual(try db.integer("SELECT count(*) FROM archived_sections"), 0)
                XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_attempts"), 0)
                XCTAssertEqual(try db.integer("SELECT count(*) FROM source_generations"), 1)

                // Later saves are ordinary.
                try store.save(["waveform_peaks.v1.2": Data([43])])
                XCTAssertEqual(store.read("waveform_peaks.v1.2"), Data([43]))
                XCTAssertEqual(store.read(AnalysisSidecar.silenceThresholdOverridesKey), LegacySidecar.thresholds)
            }
        }
    }

    func testCarriedSettingsReachTheFirstUpdateAndKeepTheOldFilesAge() throws {
        try fixture { _, source in
            try LegacySidecar.write(["thresholdOverrides.v1": LegacySidecar.thresholds], for: source, version: 1)
            let store = try AnalysisSidecar(source: source)
            let written = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: store.url.path)
            // The write that replaces the file can be an edit, which starts from the older values.
            var seen: Data?
            let edited = Data(#"{"1":-30,"3":-42.5}"#.utf8)
            try store.save([:], updating: [AnalysisSidecar.silenceThresholdOverridesKey: { current in
                seen = current
                return edited
            }])
            XCTAssertEqual(seen, LegacySidecar.thresholds)
            XCTAssertEqual(store.read(AnalysisSidecar.silenceThresholdOverridesKey), edited)

            // A carried value is dated by the older file, not by the moment it was converted.
            try LegacySidecar.remove(source)
            try LegacySidecar.write(["thresholdOverrides.v1": LegacySidecar.thresholds], for: source, version: 2)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: store.url.path)
            let second = try AnalysisSidecar(source: source)
            try second.save(["waveform_peaks.v1.1": Data([1])])
            let db = try SidecarDatabase(second.url, writing: false)
            try AnalysisSidecar.validate(db, at: second.url)
            let age = try second.changeTime(AnalysisSidecar.silenceThresholdOverridesKey, in: db, at: second.url)
            XCTAssertFalse(age.recorded)
            XCTAssertEqual(age.time, 1_600_000_000, accuracy: 1)
            XCTAssertEqual(try db.integer("SELECT count(*) FROM sidecar_field_changes"), 0)
        }
    }

    func testOnlyVerifiedSectionsThatDescribeThisMediaAreCarried() throws {
        try fixture { _, source in
            let store = try AnalysisSidecar(source: source)
            // Names without boundaries, boundaries that no longer form a report, and
            // thresholds outside the valid range mean nothing to this build.
            var broken = LegacySidecar.Scenes()
            broken.markers = [.init(pts: 0, view: 2)]
            try LegacySidecar.write(["viewNames.v2": LegacySidecar.names, "scenes.v2": try JSONEncoder().encode(broken),
                                     "thresholdOverrides.v1": Data(#"{"1":12}"#.utf8)], for: source, version: 2)
            try store.save(["a": Data([1])])
            XCTAssertEqual(store.keys(), ["a"])

            // A name for a view the boundaries do not have is dropped. The boundaries stay.
            try LegacySidecar.remove(source)
            try LegacySidecar.write(["viewNames.v2": Data(#"{"5":"Lost"}"#.utf8), "scenes.v2": LegacySidecar.scenes],
                                    for: source, version: 2)
            try AnalysisSidecar(source: source).save(["a": Data([1])])
            XCTAssertEqual(store.keys(), ["a", AnalysisSidecar.sceneSectionKey])

            // A section whose checksum fails was unreadable to the build that wrote it.
            try LegacySidecar.remove(source)
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 1)
            try SidecarDatabase(store.url, writing: true)
                .execute("UPDATE sections SET digest = zeroblob(32) WHERE name = 'thresholdOverrides.v1'")
            try AnalysisSidecar(source: source).save(["a": Data([1])])
            XCTAssertEqual(store.keys(), ["a", AnalysisSidecar.sceneSectionKey, AnalysisSidecar.viewNameSectionKey])

            // A file saved for other contents of this recording is replaced with nothing carried.
            try LegacySidecar.remove(source)
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 2, stamp: "1:2:3:4:5")
            let stale = try AnalysisSidecar(source: source)
            XCTAssertEqual(stale.status(), "unsupported")
            try stale.save(["a": Data([1])])
            XCTAssertEqual(stale.status(), "current")
            XCTAssertEqual(stale.keys(), ["a"])
            XCTAssertNil(stale.readArchived(AnalysisSidecar.silenceThresholdOverridesKey, generation: 1))
        }
    }

    func testNewerForeignAndDamagedFilesStayByteIdentical() throws {
        try fixture { _, source in
            let store = try AnalysisSidecar(source: source)
            func expectUntouched(_ label: String, line: UInt = #line) throws {
                let before = try Data(contentsOf: store.url)
                store.saveAutomatically(["waveform_peaks.v1.1": Data([1])])
                XCTAssertThrowsError(try AnalysisSidecar(source: source).save(["waveform_peaks.v1.1": Data([1])]), label, line: line)
                XCTAssertNil(store.read("waveform_peaks.v1.1"), label, line: line)
                let listed = try entry(for: source)
                XCTAssertNotNil(listed.issue, label, line: line)
                XCTAssertFalse(listed.olderFormat, label, line: line)
                for whole in [false, true] {
                    XCTAssertTrue(SidecarCacheCleaner.clear([listed], wholeSidecars: whole).cleared.isEmpty, label, line: line)
                }
                XCTAssertEqual(try Data(contentsOf: store.url), before, label, line: line)
                try LegacySidecar.remove(source)
            }
            // The same container as an older sidecar, from another application.
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 1, applicationID: 0x4d504355)
            try expectUntouched("foreign application")
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 2, applicationID: 0)
            try expectUntouched("no application")
            // MPCut's application ID with a version this build does not know yet, or none.
            for version in [AnalysisSidecar.schemaVersion + 1, 100, 0, -1] {
                try LegacySidecar.write(LegacySidecar.everything, for: source, version: version)
                try expectUntouched("version \(version)")
            }
            // A current sidecar relabelled as a later format.
            try store.save([AnalysisSidecar.silenceThresholdOverridesKey: LegacySidecar.thresholds])
            try SidecarDatabase(store.url, writing: true).execute("PRAGMA user_version = \(AnalysisSidecar.schemaVersion + 1)")
            try expectUntouched("newer")
            // An older sidecar that is cut short cannot show what it holds.
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 1)
            let whole = try Data(contentsOf: store.url)
            try whole.prefix(whole.count / 2).write(to: store.url)
            try expectUntouched("truncated")
            // No build of this application used a write-ahead log.
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 1)
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(store.url.path, &handle), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil), SQLITE_OK)
            sqlite3_close(handle)
            try expectUntouched("write-ahead log")
        }
    }

    func testAnUnrecognizedJournalBesideAnOlderFilePreventsItsReplacement() throws {
        try fixture { _, source in
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 2)
            let store = try AnalysisSidecar(source: source)
            let before = try Data(contentsOf: store.url)
            let journal = URL(fileURLWithPath: store.url.path + "-journal")
            let foreign = Data("Unrelated application data".utf8)
            try foreign.write(to: journal)
            XCTAssertThrowsError(try store.save(["a": Data([1])]))
            XCTAssertEqual(try Data(contentsOf: store.url), before)
            XCTAssertEqual(try Data(contentsOf: journal), foreign)
        }
    }

    func testConcurrentWritersReplaceAnOlderFileOnceAndMergeTheirSections() throws {
        try fixture { root, source in
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 2)
            let lock = NSLock()
            var failures: [Error] = []
            let home = SidecarLocations.storageDirectory
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                SidecarLocations.$storageDirectory.withValue(home) {
                    do { try AnalysisSidecar(source: source).save(["writer.\(index)": Data([UInt8(index)])]) }
                    catch { lock.withLock { failures.append(error) } }
                }
            }
            XCTAssertTrue(failures.isEmpty, "\(failures)")
            let store = try AnalysisSidecar(source: source)
            for index in 0..<8 { XCTAssertEqual(store.read("writer.\(index)"), Data([UInt8(index)])) }
            XCTAssertEqual(store.read(AnalysisSidecar.silenceThresholdOverridesKey), LegacySidecar.thresholds)
            XCTAssertEqual(store.sceneReport()?.views.map(\.name), [nil, "Wide"])
            XCTAssertEqual(try files(in: root), ["A.mov", "A.mov.cutdb"])
        }
    }

    func testClearCachesListsOlderFilesWithTheirSizeAndRemovesThem() throws {
        try fixture { root, source in
            // Analysis only: nothing a current build could keep.
            var analysis = LegacySidecar.everything
            for key in ["thresholdOverrides.v1", "viewNames.v2"] { analysis.removeValue(forKey: key) }
            for (format, whole) in [(Int32(1), false), (2, false), (1, true)] {
                try LegacySidecar.write(analysis, for: source, version: format)
                let url = source.appendingPathExtension("cutdb")
                var info = stat()
                XCTAssertEqual(stat(url.path, &info), 0)
                let listed = try entry(for: source)
                XCTAssertNil(listed.issue)
                XCTAssertTrue(listed.olderFormat)
                XCTAssertEqual(listed.bytes, Int64(info.st_blocks) * 512)
                XCTAssertGreaterThan(listed.bytes, 300_000)
                XCTAssertEqual(listed.rebuildableBytes, listed.bytes)
                XCTAssertEqual(listed.retained, [])
                let result = SidecarCacheCleaner.clear([listed], wholeSidecars: whole)
                XCTAssertEqual(result.cleared, [url], String(describing: result.skipped))
                XCTAssertEqual(result.reclaimedBytes, listed.bytes)
                XCTAssertEqual(try files(in: root), ["A.mov"])
            }
            // A folder scan finds an older file that no session has opened.
            try LegacySidecar.write(analysis, for: source, version: 2)
            let scanned = SidecarCacheCleaner.preview(scanning: [root])
            XCTAssertEqual(scanned.map(\.olderFormat), [true])
            XCTAssertEqual(SidecarCacheCleaner.clear(scanned).cleared.count, 1)
            XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        }
    }

    func testClearingAnalysisRewritesAnOlderFileThatHoldsSettings() throws {
        try fixture { _, source in
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 2)
            let url = source.appendingPathExtension("cutdb")
            let listed = try entry(for: source)
            XCTAssertNil(listed.issue)
            XCTAssertEqual(listed.retained, ["Manual silence thresholds", "Scene names and their reports"])
            XCTAssertLessThan(listed.rebuildableBytes, listed.bytes)
            XCTAssertGreaterThan(listed.rebuildableBytes, 300_000)
            // A store opened before the clear cannot bring the removed analysis back.
            let earlier = try AnalysisSidecar(source: source)

            let result = SidecarCacheCleaner.clear([listed])
            XCTAssertEqual(result.cleared, [url], String(describing: result.skipped))
            XCTAssertGreaterThan(result.reclaimedBytes, 300_000)
            XCTAssertThrowsError(try earlier.save(["wave": Data([1])]))
            let store = try AnalysisSidecar(source: source)
            XCTAssertEqual(store.status(), "current")
            XCTAssertEqual(store.keys(), [AnalysisSidecar.sceneSectionKey, AnalysisSidecar.viewNameSectionKey,
                                          AnalysisSidecar.silenceThresholdOverridesKey].sorted())
            XCTAssertEqual(store.read(AnalysisSidecar.silenceThresholdOverridesKey), LegacySidecar.thresholds)
            XCTAssertEqual(store.sceneReport()?.views.map(\.name), [nil, "Wide"])
            let after = try entry(for: source)
            XCTAssertFalse(after.olderFormat)
            XCTAssertEqual(after.rebuildableBytes, 0)

            // Removing whole sidecars takes the settings as well, as it does for a current file.
            try LegacySidecar.remove(source)
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 1)
            let whole = SidecarCacheCleaner.clear([try entry(for: source)], wholeSidecars: true)
            XCTAssertEqual(whole.cleared, [url], String(describing: whole.skipped))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testClearCachesSkipsAnOlderFileOfAnotherRecordingOrOneChangedAfterThePreview() throws {
        try fixture { _, source in
            let url = source.appendingPathExtension("cutdb")
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 2, stamp: "1:2:3:4:5")
            let foreign = try entry(for: source)
            XCTAssertNotNil(foreign.issue)
            XCTAssertEqual(foreign.bytes, 0)
            let before = try Data(contentsOf: url)
            for whole in [false, true] {
                XCTAssertTrue(SidecarCacheCleaner.clear([foreign], wholeSidecars: whole).cleared.isEmpty)
            }
            XCTAssertEqual(try Data(contentsOf: url), before)

            try LegacySidecar.remove(source)
            try LegacySidecar.write(LegacySidecar.everything, for: source, version: 2)
            let listed = try entry(for: source)
            try LegacySidecar.remove(source)
            try LegacySidecar.write(["thresholdOverrides.v1": LegacySidecar.thresholds], for: source, version: 2)
            let changed = try Data(contentsOf: url)
            for whole in [false, true] {
                XCTAssertNotNil(SidecarCacheCleaner.clear([listed], wholeSidecars: whole).skipped[url])
            }
            XCTAssertEqual(try Data(contentsOf: url), changed)
            XCTAssertFalse(SidecarCacheCleaner.clear([listed], wholeSidecars: true, protected: [url]).skipped.isEmpty)
        }
    }
}

extension LegacySidecar {
    fileprivate static func remove(_ source: URL) throws {
        let url = source.appendingPathExtension("cutdb")
        for suffix in ["", "-wal", "-shm", "-journal"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
