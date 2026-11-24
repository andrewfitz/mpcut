import Darwin
import Foundation
import SQLite3

/// An older sidecar found at the write destination, with the read transaction that
/// keeps it unchanged until a current database has taken its place.
struct SupersededSidecar {
    let db: SidecarDatabase
    let device: dev_t
    let inode: ino_t
    /// The file's modification time, the only clock formats 1 and 2 had.
    let modified: Double
    /// Current section names and encodings.
    let sections: [String: Data]

    /// Whether the path still names the file this snapshot locks. Other processes
    /// can replace the file, but none can commit to it while the snapshot is open.
    func isInPlace(at url: URL) -> Bool {
        var info = stat()
        var moved: Int32 = 0
        return lstat(url.path, &info) == 0 && info.st_dev == device && info.st_ino == inode
            && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
            && sqlite3_get_autocommit(db.handle) == 0
            && sqlite3_file_control(db.handle, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK && moved == 0
    }
}

/// Format 2 and earlier encoded the time base under its Swift property name.
private struct LegacySceneBoundaries: Decodable {
    struct Marker: Codable {
        let pts: Int64
        let view: Int
    }

    let origin: RationalTime
    let duration: RationalTime
    let timeBase: RationalTime
    let markers: [Marker]

    private enum CurrentKeys: String, CodingKey {
        case origin, duration, markers
        case timeBase = "time_base"
    }

    func current() throws -> Data {
        struct Current: Encodable {
            let legacy: LegacySceneBoundaries
            func encode(to encoder: Encoder) throws {
                var fields = encoder.container(keyedBy: CurrentKeys.self)
                try fields.encode(legacy.origin, forKey: .origin)
                try fields.encode(legacy.duration, forKey: .duration)
                try fields.encode(legacy.timeBase, forKey: .timeBase)
                try fields.encode(legacy.markers, forKey: .markers)
            }
        }
        return try JSONEncoder().encode(Current(legacy: self))
    }
}

extension AnalysisSidecar {
    // Section names written by formats 1 and 2 for what the user set by hand, and
    // for the scene boundaries that give the view names their meaning.
    private static let legacyThresholdOverridesKey = "thresholdOverrides.v1"
    private static let legacySceneBoundariesKey = "scenes.v2"
    private static let legacyViewNamesKey = "viewNames.v2"
    private static let legacySectionLimit = 16 * 1024 * 1024

    /// The format of an MPCut sidecar that predates every version this build reads.
    /// Read from the file header alone, so a foreign or newer database is never queried.
    static func supersededVersion(of db: SidecarDatabase) -> Int32? {
        guard let header = db.headerVersions(), !header.usesWriteAheadLog, header.applicationID == applicationID,
              (1..<oldestReadableVersion).contains(header.userVersion) else { return nil }
        return header.userVersion
    }

    /// Nil unless the write destination is an older MPCut sidecar. An error means the
    /// file is one but could not be read cleanly, and it must then be left as it is.
    func supersededSidecar(cancelled: () -> Bool) throws -> SupersededSidecar? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_size > 0,
              let db = try? SidecarDatabase(url, writing: false), Self.supersededVersion(of: db) != nil else { return nil }
        // The header was read without a lock. Confirm it in the snapshot that stays open.
        try db.execute("BEGIN")
        guard try db.integer("PRAGMA application_id") == Self.applicationID,
              (1..<Self.oldestReadableVersion).contains(try db.integer("PRAGMA user_version")) else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        let sections = try legacySections(in: db, cancelled: cancelled)
        let old = SupersededSidecar(db: db, device: info.st_dev, inode: info.st_ino, modified: modified, sections: sections)
        // Another writer may have replaced the file since. Its database then takes this write.
        return old.isInPlace(at: url) ? old : nil
    }

    /// What a format 1 or 2 file holds that this build can still use, under current names:
    /// manual silence thresholds, scene boundaries, and view names when their boundaries
    /// came too. Empty when the file describes other media. Every other section is analysis
    /// in an encoding no longer read, which the media can rebuild.
    func legacySections(in db: SidecarDatabase, cancelled: () -> Bool) throws -> [String: Data] {
        guard let saved = try currentStamp(db), identity.isCurrentSnapshot(at: source) else { return [:] }
        func read(_ key: String) throws -> Data? {
            try verifiedSection(key, in: db, stamp: saved, maxBytes: Self.legacySectionLimit, cancelled: cancelled)
        }
        var sections: [String: Data] = [:]
        let decoder = JSONDecoder()
        if let bytes = try read(Self.legacyThresholdOverridesKey),
           let thresholds = try? decoder.decode([Int: Double].self, from: bytes), !thresholds.isEmpty,
           thresholds.allSatisfy({ $0.key >= 0 && (-120...0).contains($0.value) }) {
            sections[Self.silenceThresholdOverridesKey] = bytes
        }
        if let bytes = try read(Self.legacySceneBoundariesKey),
           let legacy = try? decoder.decode(LegacySceneBoundaries.self, from: bytes),
           let boundaries = try? legacy.current(),
           canImportAnalysis(Self.sceneSectionKey, bytes: boundaries, replacing: nil, evidence: sourceEvidence,
                             cancelled: cancelled) {
            sections[Self.sceneSectionKey] = boundaries
            // A valid report numbers its views consecutively from 1.
            let views = legacy.markers.reduce(0) { max($0, $1.view) }
            if let bytes = try read(Self.legacyViewNamesKey),
               let names = try? decoder.decode([Int: String].self, from: bytes), !names.isEmpty,
               names.keys.allSatisfy({ $0 > 0 && $0 <= views }) {
                sections[Self.viewNameSectionKey] = bytes
            }
        }
        try checkSidecarCancellation(cancelled)
        return sections
    }

    /// Carried values keep the age of the file they came from, so that they
    /// cannot outrank an edit saved later in another copy of this sidecar.
    func adopt(_ old: SupersededSidecar, into db: SidecarDatabase, stamp: String, cancelled: () -> Bool) throws {
        let age = ChangeTime(recorded: false, time: old.modified)
        for (key, value) in old.sections {
            try writeSection(key, value: value, db: db, stamp: stamp, cancelled: cancelled)
            try db.update("DELETE FROM sidecar_field_changes WHERE name = ?", [key])
            try setChangeTime(age, key: key, in: db)
        }
    }
}
