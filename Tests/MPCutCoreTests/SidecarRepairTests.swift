import AVFoundation
import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MPCutCore

final class SidecarRepairTests: XCTestCase {
    private func makeSidecar() throws -> AnalysisSidecar {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("shot.mov")
        try Data([1, 2, 3]).write(to: source)
        return try AnalysisSidecar(source: source)
    }

    /// Rewrites a sidecar as an earlier mount with another device number would
    /// have saved it: the stamp, the checksums it seeds, and the index identity.
    private func changeStoredDevice(_ sidecar: AnalysisSidecar) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(sidecar.url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        func rows(_ sql: String, _ values: [Data] = [], _ visit: (OpaquePointer) -> Void = { _ in }) {
            var query: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &query, nil), SQLITE_OK)
            defer { sqlite3_finalize(query) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, value) in values.enumerated() {
                _ = value.withUnsafeBytes { sqlite3_bind_blob(query, Int32(i + 1), $0.baseAddress, Int32($0.count), transient) }
            }
            var step = sqlite3_step(query)
            while step == SQLITE_ROW, let query {
                visit(query)
                step = sqlite3_step(query)
            }
            XCTAssertEqual(step, SQLITE_DONE)
        }
        func data(_ query: OpaquePointer, _ column: Int32) -> Data {
            sqlite3_column_blob(query, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(query, column))) } ?? Data()
        }
        var stamp = ""
        rows("SELECT stamp FROM source") { stamp = String(cString: sqlite3_column_text($0, 0)) }
        let fields = stamp.split(separator: ":", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 5)
        let device = try XCTUnwrap(Int32(fields[0])) &+ 7
        stamp = (["\(device)"] + fields.dropFirst().map(String.init)).joined(separator: ":")
        var sections: [(String, Data)] = []
        rows("SELECT name, value, logical_size FROM sections") { query in
            let stored = SidecarPayload(bytes: data(query, 1), logicalSize: Int(sqlite3_column_int64(query, 2)))
            if let value = try? stored.decode(cancelled: { false }) {
                sections.append((String(cString: sqlite3_column_text(query, 0)), value))
            } else { XCTFail("Unreadable fixture section") }
        }
        for (name, saved) in sections {
            var value = saved
            if name == "media_index.v1" {
                var format = PropertyListSerialization.PropertyListFormat.binary
                var header = try XCTUnwrap(PropertyListSerialization.propertyList(from: value, format: &format) as? [String: Any])
                var identity = try XCTUnwrap(header["identity"] as? [String: Any])
                XCTAssertNotNil(identity["device"])
                identity["device"] = Int(device)
                header["identity"] = identity
                value = try PropertyListSerialization.data(fromPropertyList: header, format: .binary, options: 0)
            }
            let digest = Data(SHA256.hash(data: Data((stamp + "\0" + name + "\0").utf8) + value))
            rows("UPDATE sections SET logical_size = 0, digest = ?, value = ? WHERE name = CAST(? AS TEXT)", [digest, value, Data(name.utf8)])
        }
        rows("UPDATE source SET stamp = CAST(? AS TEXT)", [Data(stamp.utf8)])
    }

    func testRemountedVolumeKeepsUserSections() throws {
        let sidecar = try makeSidecar()
        let names = Data(#"{"1":"Wide"}"#.utf8)
        try sidecar.save([AnalysisSidecar.viewNameSectionKey: names, "silence_threshold_overrides_db.v1": Data([4])])
        try changeStoredDevice(sidecar)
        XCTAssertEqual(sidecar.status(), "current")
        XCTAssertEqual(sidecar.keys(), [AnalysisSidecar.viewNameSectionKey, "silence_threshold_overrides_db.v1"])
        XCTAssertEqual(sidecar.read(AnalysisSidecar.viewNameSectionKey), names)
        var seen: Data?
        try sidecar.save(["wave": Data([9])], updating: ["silence_threshold_overrides_db.v1": { seen = $0; return Data([5]) }])
        XCTAssertEqual(seen, Data([4]))
        XCTAssertEqual(sidecar.read(AnalysisSidecar.viewNameSectionKey), names)
        XCTAssertEqual(sidecar.read("wave"), Data([9]))
        XCTAssertEqual(sidecar.read("silence_threshold_overrides_db.v1"), Data([5]))
        // A changed file is still stale.
        try Data([7, 8, 9, 10]).write(to: sidecar.source)
        let changed = try AnalysisSidecar(source: sidecar.source)
        XCTAssertEqual(changed.status(), "stale")
        XCTAssertNil(changed.read(AnalysisSidecar.viewNameSectionKey))
    }

    func testRemountedVolumeKeepsTheEditIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = buffer.frameCapacity
        do { try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer) }
        let engine = CutEngine()
        let media = try engine.inspect(source, keyframes: true)
        let store = AnalysisSidecar(media: media)
        try store.save(try AnalysisSidecar.indexSections(for: media))
        XCTAssertNotNil(try engine.cachedIndex(source))
        try changeStoredDevice(store)
        let cached = try XCTUnwrap(engine.cachedIndex(source))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(cached), try encoder.encode(media))
    }

    func testEmptyFileIsReplaced() throws {
        let sidecar = try makeSidecar()
        try Data().write(to: sidecar.url)
        XCTAssertNil(sidecar.read("a"))
        try sidecar.save(["a": Data([1])])
        XCTAssertEqual(sidecar.status(), "current")
        XCTAssertEqual(sidecar.read("a"), Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sidecar.source.deletingLastPathComponent().path).sorted(),
                       ["shot.mov", "shot.mov.cutdb"])
    }

    func testForeignJournalSurvivesFirstSaveRepairAndUpdates() throws {
        for state in ["missing", "empty", "healthy", "truncated"] {
            let store = try makeSidecar()
            switch state {
            case "empty":
                try Data().write(to: store.url)
            case "healthy", "truncated":
                try store.save(["previous": Data([1])])
                if state == "truncated" {
                    let bytes = try Data(contentsOf: store.url)
                    try bytes.prefix(4096).write(to: store.url)
                }
            default:
                break
            }
            let before = try? Data(contentsOf: store.url)
            let journal = URL(fileURLWithPath: store.url.path + "-journal")
            let foreign = Data("Unrelated application data".utf8)
            try foreign.write(to: journal)
            _ = store.status()
            XCTAssertThrowsError(try store.save(["new": Data([2])]), state)
            XCTAssertEqual(try Data(contentsOf: journal), foreign, state)
            XCTAssertEqual(try? Data(contentsOf: store.url), before, state)
        }
    }

    func testStatusLeavesForeignDatabaseAndHotJournalIntact() throws {
        let store = try makeSidecar()
        let donor = store.url.deletingLastPathComponent().appendingPathComponent("other.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(donor.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TABLE item(value BLOB);
            INSERT INTO item VALUES(zeroblob(200000));
            """, nil, nil, nil), SQLITE_OK)
        try FileManager.default.copyItem(at: donor, to: store.url)
        XCTAssertEqual(sqlite3_exec(connection, """
            PRAGMA cache_size = 2;
            BEGIN;
            UPDATE item SET value = randomblob(200000);
            """, nil, nil, nil), SQLITE_OK)
        let journal = URL(fileURLWithPath: store.url.path + "-journal")
        try FileManager.default.copyItem(atPath: donor.path + "-journal", toPath: journal.path)
        let original = try Data(contentsOf: store.url)
        let rollback = try Data(contentsOf: journal)
        XCTAssertGreaterThan(rollback.count, 512)
        XCTAssertEqual(store.status(), "unsupported")
        XCTAssertThrowsError(try store.save(["key": Data([1])]))
        XCTAssertEqual(try Data(contentsOf: journal), rollback)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }

    func testTruncatedSidecarIsPreserved() throws {
        let sidecar = try makeSidecar()
        try sidecar.save(["a": Data(repeating: 6, count: 64 << 10)])
        let whole = try Data(contentsOf: sidecar.url)
        for length in [100, 1000, 4096, 5000, whole.count / 2, whole.count - 4096] {
            try whole.prefix(length).write(to: sidecar.url)
            XCTAssertNil(sidecar.read("a"), "\(length)")
            XCTAssertThrowsError(try sidecar.save(["b": Data([2])]), "\(length)")
            XCTAssertEqual(try Data(contentsOf: sidecar.url), whole.prefix(length))
        }
    }

    func testOtherDamagedOrForeignFilesAreKept() throws {
        let sidecar = try makeSidecar()
        try sidecar.save(["a": Data([1])])
        let whole = try Data(contentsOf: sidecar.url)
        // Too short to carry MPCut's application ID, a foreign database cut short,
        // and a sidecar from a later version.
        var foreign = whole, newer = whole
        foreign.replaceSubrange(68..<72, with: [0, 0, 0, 9])
        let version = whole[60..<64].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var laterVersion = (version + 1).bigEndian
        withUnsafeBytes(of: &laterVersion) { newer.replaceSubrange(60..<64, with: $0) }
        for original in [whole.prefix(40), foreign.prefix(whole.count / 2), foreign, newer, newer.prefix(whole.count / 2)] {
            try original.write(to: sidecar.url)
            XCTAssertThrowsError(try sidecar.save(["x": Data()]))
            XCTAssertEqual(try Data(contentsOf: sidecar.url), original)
        }
    }

    func testNewSidecarUsesOrdinaryPermissions() throws {
        let sidecar = try makeSidecar()
        try sidecar.save(["a": Data([1])])
        var info = stat()
        XCTAssertEqual(stat(sidecar.url.path, &info), 0)
        let ordinary = sidecar.url.deletingLastPathComponent().appendingPathComponent("ordinary")
        let fd = open(ordinary.path, O_CREAT | O_EXCL | O_WRONLY, 0o666)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        var expected = stat()
        XCTAssertEqual(fstat(fd, &expected), 0)
        XCTAssertEqual(info.st_mode & 0o7777, expected.st_mode & 0o7777)
        // A rebuilt sidecar is also readable by the usual audience.
        try Data().write(to: sidecar.url)
        XCTAssertEqual(chmod(sidecar.url.path, 0o600), 0)
        try sidecar.save(["a": Data([1])])
        XCTAssertEqual(stat(sidecar.url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, expected.st_mode & 0o7777)
    }
}
