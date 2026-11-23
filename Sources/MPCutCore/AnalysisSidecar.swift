import CryptoKit
import Darwin
import Foundation
import SQLite3

/// A snapshot of the source identity. Reads never create a sidecar. Each producer
/// assigns a version to its section keys so unrelated analyses can evolve independently.
public struct AnalysisSidecar: Sendable {
    @TaskLocal public static var readsEnabled = true
    @TaskLocal public static var excludedSources: Set<URL> = []

    /// The same recording can reach a worker through a symlink or a differently cased path.
    static func canonicalSource(_ source: URL) -> URL {
        let physical = source.standardizedFileURL.resolvingSymlinksInPath()
        if let name = try? physical.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: name)
        }
        return physical
    }

    public static func isExcluded(_ source: URL, in exclusions: Set<URL>) -> Bool {
        !exclusions.isEmpty && (exclusions.contains(source.standardizedFileURL) || exclusions.contains(canonicalSource(source)))
    }

    var isExcluded: Bool { Self.isExcluded(source, in: Self.excludedSources) }


    @TaskLocal public static var automaticWritesEnabled = true

    public func saveAutomatically(_ sections: @autoclosure () throws -> [String: Data],
                                  retainingLatest: [String: Int] = [:], cancelled: () -> Bool = { false }) {
        guard Self.readsEnabled, Self.automaticWritesEnabled, !isExcluded, !cancelled() else { return }
        // Analysis remains usable when the source folder is read-only.
        try? save(sections(), retainingLatest: retainingLatest, cancelled: cancelled)
    }

    public let source: URL
    package let identity: SourceIdentity
    public var url: URL { Self.url(for: source) }

    public static func url(for source: URL) -> URL { source.appendingPathExtension("cutdb") }

    public init(source: URL) throws {
        guard source.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local media file.") }
        self.source = source.standardizedFileURL
        identity = try SourceIdentity(self.source)
    }

    init(source: URL, identity: SourceIdentity) {
        self.source = source.standardizedFileURL
        self.identity = identity
    }

    public init(media: MediaInfo) {
        source = media.url.standardizedFileURL
        identity = media.identity
    }

    private var stamp: String {
        "\(identity.device):\(identity.inode):\(identity.size):\(identity.modifiedSeconds):\(identity.modifiedNanoseconds)"
    }

    private static let applicationID: Int32 = 0x4d504354 // MPCT
    static let schemaVersion: Int32 = 4

    package func checkSource() throws {
        guard identity.isCurrentSnapshot(at: source) else {
            throw CutError(code: "source_changed", message: "The media changed during analysis.")
        }
    }

    func exists() throws -> Bool {
        try Self.exists(url, sourceIdentity: identity)
    }

    static func exists(_ url: URL, sourceIdentity: SourceIdentity?) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw sidecarError(String(cString: strerror(errno)))
        }
        let aliasesSource = sourceIdentity.map { info.st_dev == $0.device && info.st_ino == $0.inode } ?? false
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, !aliasesSource else {
            throw sidecarError("The sidecar path must identify a separate regular file.")
        }
        return true
    }

    func validate(_ db: SidecarDatabase) throws {
        try Self.validate(db, at: url)
    }

    static func validate(_ db: SidecarDatabase, at url: URL) throws {
        // The first SQLite query can replay a journal or open a write-ahead log.
        // Check the database header on SQLite's own descriptor first.
        let unsupported = CutError(code: "unsupported_sidecar", message: "This file is not a supported MPCut analysis sidecar.")
        guard let header = db.headerVersions() else {
            var info = stat()
            if lstat(url.path, &info) == 0 && info.st_size == 0 { throw unsupported }
            throw sidecarError("The sidecar has no readable SQLite header.")
        }
        guard !header.usesWriteAheadLog, header.applicationID == Self.applicationID,
              (3...Self.schemaVersion).contains(header.userVersion) else { throw unsupported }
        let kind = try db.integer("PRAGMA application_id")
        let version = try db.integer("PRAGMA user_version")
        guard kind == Self.applicationID, (3...Self.schemaVersion).contains(version) else {
            throw CutError(code: "unsupported_sidecar", message: "This file is not a supported MPCut analysis sidecar.")
        }
        db.hasCompactStorage = version >= 4
    }

    func storedStamp(_ db: SidecarDatabase) throws -> String {
        try Self.storedStamp(db)
    }

    static func storedStamp(_ db: SidecarDatabase) throws -> String {
        try db.statement("SELECT stamp FROM source WHERE id = 1") { query in
            guard sqlite3_step(query) == SQLITE_ROW, let value = sqlite3_column_text(query, 0) else {
                throw sidecarError("The sidecar has no media identity.")
            }
            return String(cString: value)
        }
    }

    /// SQLite may roll back or remove a neighboring journal on its first query.
    /// A new or replacement database must never inherit a previous journal.
    private func requireClearJournalPath() throws {
        var info = stat()
        if lstat(url.path + "-journal", &info) == 0 {
            throw sidecarError("The sidecar journal path is occupied. The existing files were preserved.")
        }
        guard errno == ENOENT else { throw sidecarError(String(cString: strerror(errno))) }
    }

    /// The saved stamp when it describes this source. A volume's device number
    /// can change on each mount, so only the fields after it must agree. The
    /// saved text also seeds the section checksums and is therefore kept as is.
    func currentStamp(_ db: SidecarDatabase) throws -> String? {
        let saved = try storedStamp(db)
        return saved.drop { $0 != ":" } == stamp.drop { $0 != ":" } ? saved : nil
    }

    // A nonempty container can hold authored metadata even when SQLite cannot read it.
    private func isEmptyPlaceholder() -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG &&
            info.st_nlink == 1 && info.st_size == 0
    }

    /// Inspects the container and media identity without loading any analysis payload.
    public func status() -> String {
        guard !isExcluded else { return "excluded" }
        do {
            guard try exists() else { return "missing" }
            let db = try SidecarDatabase(url, writing: false)
            try validate(db)
            return try currentStamp(db) != nil && identity.isCurrentSnapshot(at: source) ? "current" : "stale"
        } catch let error as CutError where error.code == "unsupported_sidecar" {
            return "unsupported"
        } catch {
            return "unreadable"
        }
    }

    static func sectionNames(in db: SidecarDatabase) throws -> [String] {
        try db.statement("SELECT name FROM sections ORDER BY name") { query in
            var names = [String]()
            var step = sqlite3_step(query)
            while step == SQLITE_ROW, let value = sqlite3_column_text(query, 0) {
                names.append(String(cString: value))
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw db.error() }
            return names
        }
    }

    public func keys() -> [String] {
        guard Self.readsEnabled else { return [] }
        do {
            guard let db = try openReadSnapshot(), try currentStamp(db) != nil else { return [] }
            let result = try Self.sectionNames(in: db)
            try checkSource()
            return result
        } catch { return [] }
    }

    /// Check membership using the section-name index without loading unrelated keys or payloads.
    package func containsSections(_ keys: Set<String>, cancelled: () -> Bool = { Task.isCancelled }) -> Bool {
        if keys.isEmpty { return true }
        guard Self.readsEnabled, !cancelled() else { return false }
        do {
            guard let db = try openReadSnapshot(), try currentStamp(db) != nil else { return false }
            for key in keys {
                guard !cancelled(), Self.validKey(key),
                      try db.statement("SELECT 1 FROM sections WHERE name = ?", [key], {
                          sqlite3_step($0) == SQLITE_ROW
                      }) else { return false }
            }
            try checkSource()
            return !cancelled()
        } catch { return false }
    }

    public func read(_ key: String, maxBytes: Int? = nil, cancelled: () -> Bool = { Task.isCancelled }) -> Data? {
        guard Self.readsEnabled, Self.validKey(key), !cancelled() else { return nil }
        do {
            guard let db = try openReadSnapshot() else { return nil }
            guard let saved = try currentStamp(db) else { return nil }
            let section = try verifiedSection(key, in: db, stamp: saved, maxBytes: maxBytes, cancelled: cancelled)
            try checkSource()
            return cancelled() ? nil : section
        } catch { return nil }
    }

    /// Select related sections from one committed SQLite generation. The
    /// transaction ends when the caller finishes loading its result.
    func withReadSnapshot<Value>(cancelled: () -> Bool,
                                 _ load: ((_ key: String) -> Data?) throws -> Value?) throws -> Value? {
        guard Self.readsEnabled, !cancelled(),
              let db = try? openReadSnapshot(),
              let saved = try? currentStamp(db) else { return nil }
        let value = try withoutActuallyEscaping(cancelled) { check in
            try load { key in
                guard Self.validKey(key), !check() else { return nil }
                return try? verifiedSection(key, in: db, stamp: saved, maxBytes: nil, cancelled: check)
            }
        }
        guard !cancelled(), identity.isCurrentSnapshot(at: source) else { return nil }
        return value
    }

    func openReadSnapshot() throws -> SidecarDatabase? {
        guard !isExcluded, try exists() else { return nil }
        try checkSource()
        let db = try SidecarDatabase(url, writing: false)
        try db.execute("BEGIN")
        try validate(db)
        return db
    }

    func verifiedSection(_ key: String, in db: SidecarDatabase, stamp saved: String, maxBytes: Int?,
                         cancelled: () -> Bool, generation: String? = nil, matchingDigest: SHA256.Digest? = nil) throws -> Data? {
        let table = generation == nil ? "sections" : "archived_sections"
        let predicate = generation == nil ? "name = ?" : "name = ? AND generation = ?"
        let bindings = [key] + (generation.map { [$0] } ?? [])
        return try db.statement("SELECT digest, rowid, \(db.logicalSizeColumn) FROM \(table) WHERE \(predicate) AND typeof(value) = 'blob'", bindings) { query in
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw db.error() }
            guard sqlite3_column_bytes(query, 0) == 32,
                  let expected = sqlite3_column_blob(query, 0) else { return nil }
            let expectedBytes = UnsafeRawBufferPointer(start: expected, count: 32)
            if let matchingDigest, !matchingDigest.elementsEqual(expectedBytes) { return nil }
            // Read into the destination allocation directly. Materializing
            // sqlite3_column_blob would also keep a full SQLite-owned copy.
            let size = Int(sqlite3_column_int64(query, 2))
            guard size >= 0, maxBytes.map({ size <= $0 }) ?? true else { return nil }
            let storedLimit = size == 0 ? maxBytes : size - 1
            var hash = checksumSeed(key, stamp: saved)
            let data = try db.readBlob(table: table, row: sqlite3_column_int64(query, 1), maxBytes: storedLimit, cancelled: cancelled) { chunk in
                if size == 0 { hash.update(bufferPointer: chunk) }
            }
            guard let data else { return nil }
            if size == 0 { return hash.finalize().elementsEqual(expectedBytes) ? data : nil }
            guard let decoded = try SidecarPayload(bytes: data, logicalSize: size).decode(cancelled: cancelled) else { return nil }
            let digest = try decoded.withUnsafeBytes { try checksum(key, stamp: saved, $0, cancelled: cancelled) }
            return digest.elementsEqual(expectedBytes) ? decoded : nil
        }
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 512 && !key.utf8.contains(0)
    }

    private func checksumSeed(_ key: String, stamp: String) -> SHA256 {
        var hash = SHA256()
        hash.update(data: Data((stamp + "\0" + key + "\0").utf8))
        return hash
    }

    func checksum(_ key: String, stamp: String, _ bytes: UnsafeRawBufferPointer,
                          cancelled: () -> Bool) throws -> SHA256.Digest {
        var hash = checksumSeed(key, stamp: stamp)
        for offset in stride(from: 0, to: bytes.count, by: 1 << 20) {
            try checkSidecarCancellation(cancelled)
            let end = min(bytes.count, offset + (1 << 20))
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[offset..<end]))
        }
        return hash.finalize()
    }

    /// Merges sections in a single transaction. A stale sidecar is refreshed using
    /// only the supplied sections. Each update receives the current, verified
    /// value under the write lock. Use side-effect-free transforms because a
    /// concurrent first save may retry against the winning initial database.
    public func save(_ sections: [String: Data], updating: [String: (Data?) throws -> Data] = [:],
                     retainingLatest: [String: Int] = [:],
                     cancelled: () -> Bool = { false }) throws {
        if sections.isEmpty && updating.isEmpty {
            try validateWrite(cancelled: cancelled)
            return
        }
        try transact(sections, updating: updating, retainingLatest: retainingLatest, cancelled: cancelled) { _, _ in }
    }

    /// Save automatic cache entries in arrival order, including repeated keys.
    /// The last write to a key counts as its latest use for retention.
    package func saveOrderedCacheEntries(_ entries: [(key: String, value: Data)], prefix: String,
                                         keepingLatest limit: Int, cancelled: () -> Bool) throws {
        guard Self.readsEnabled, Self.automaticWritesEnabled, !isExcluded, !entries.isEmpty else { return }
        guard Self.validKey(prefix), limit >= 0,
              entries.allSatisfy({ Self.validKey($0.key) && $0.key.hasPrefix(prefix) }) else {
            throw sidecarError("Invalid ordered cache entries or retention limit.")
        }
        try transact(cancelled: cancelled) { db, stamp in
            for (key, value) in entries {
                try writeSection(key, value: value, db: db, stamp: stamp, cancelled: cancelled)
            }
            try Self.pruneSections(in: db, prefix: prefix, keepingLatest: limit)
        }
    }

    @discardableResult
    func transact<T>(_ sections: [String: Data] = [:], updating: [String: (Data?) throws -> Data] = [:],
                     retainingLatest: [String: Int] = [:], cancelled: () -> Bool,
                     refresh: SidecarGenerationRefresh? = nil,
                     _ change: (SidecarDatabase, String) throws -> T) throws -> T {
        try validateWrite(cancelled: cancelled)
        guard sections.keys.allSatisfy(Self.validKey), updating.keys.allSatisfy(Self.validKey),
              sections.keys.allSatisfy({ updating[$0] == nil }) else {
            throw sidecarError("Section names must be valid and unique across writes and updates.")
        }
        guard retainingLatest.allSatisfy({ Self.validKey($0.key) && $0.value >= 0 }) else {
            throw sidecarError("Invalid section retention limit.")
        }

        if try !exists() || isEmptyPlaceholder() {
            // Stage beside the media. Exclusive publication prevents a race with
            // a second writer and leaves no empty database behind on cancellation.
            var template = Array((url.deletingLastPathComponent().appendingPathComponent(".mpcut-XXXXXX").path).utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { throw sidecarError(String(cString: strerror(errno))) }
            close(fd)
            let staging = URL(fileURLWithPath: String(cString: template))
            defer { try? FileManager.default.removeItem(at: staging) }
            let result = try write(sections, updating: updating, to: staging, create: true, retainingLatest: retainingLatest,
                                   cancelled: cancelled, refresh: refresh, change)
            try checkSource()
            try checkSidecarCancellation(cancelled)
            guard chmod(staging.path, try publicationPermissions(0o666)) == 0 else { throw sidecarError(String(cString: strerror(errno))) }
            if try publish(staging, cancelled: cancelled) { return result }
            // Another writer published first. Merge into its committed database.
            guard try exists() else { throw sidecarError("The destination changed while saving.") }
        }
        return try write(sections, updating: updating, to: url, create: false, retainingLatest: retainingLatest,
                         cancelled: cancelled, refresh: refresh, change)
    }

    private func validateWrite(cancelled: () -> Bool) throws {
        guard !isExcluded else {
            throw sidecarError("A recording in this project uses the cache path for \(source.lastPathComponent).")
        }
        try checkSource()
        try checkSidecarCancellation(cancelled)
    }

    /// Empty placeholders have no SQLite write lock that all publishers can use.
    /// Serialize the final destination check and rename across processes without
    /// creating another file beside the recording. Healthy writers use SQLite.
    private func publish(_ staging: URL, cancelled: () -> Bool) throws -> Bool {
        if try !exists() {
            try requireClearJournalPath()
            if renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) == 0 { return true }
            let failure = errno
            guard failure == EEXIST || failure == ENOTSUP || failure == EINVAL else {
                throw sidecarError(String(cString: strerror(failure)))
            }
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw sidecarError(String(cString: strerror(errno))) }
        defer { close(directory) }
        let deadline = ContinuousClock.now + .seconds(5)
        while flock(directory, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw sidecarError(String(cString: strerror(errno))) }
            try checkSidecarCancellation(cancelled)
            guard .now < deadline else { throw sidecarError("Another writer is publishing a sidecar.") }
            usleep(10_000)
        }
        try checkSource()
        try checkSidecarCancellation(cancelled)
        if try exists() {
            guard isEmptyPlaceholder() else { return false }
            try checkSidecarCancellation(cancelled)
            try requireClearJournalPath()
            guard rename(staging.path, url.path) == 0 else { throw sidecarError(String(cString: strerror(errno))) }
            return true
        }
        try requireClearJournalPath()
        let failure = publishExclusively(from: staging, to: url)
        if failure == 0 { return true }
        guard failure == EEXIST else { throw sidecarError(String(cString: strerror(failure))) }
        return false
    }

    private func write<T>(_ sections: [String: Data], updating: [String: (Data?) throws -> Data],
                       to destination: URL, create: Bool, retainingLatest: [String: Int],
                       cancelled: () -> Bool, refresh: SidecarGenerationRefresh?,
                       _ change: (SidecarDatabase, String) throws -> T) throws -> T {
        let db = try SidecarDatabase(destination, writing: true)
        return try db.whileWaitingForLocks(cancelled) {
            if create { try db.execute("PRAGMA auto_vacuum = FULL") }
            else { try validate(db) }
            try db.execute("BEGIN IMMEDIATE")
            try checkSource()
            if create {
                try db.execute("""
                    PRAGMA application_id = \(Self.applicationID);
                    CREATE TABLE source(id INTEGER PRIMARY KEY CHECK(id = 1), stamp TEXT NOT NULL);
                    CREATE TABLE sections(name TEXT PRIMARY KEY NOT NULL, digest BLOB NOT NULL, value BLOB NOT NULL, logical_size INTEGER NOT NULL DEFAULT 0);
                    """)
                try db.update("INSERT INTO source(id, stamp) VALUES(1, ?)", [stamp])
                try createManifest(db)
            } else {
                // Re-read under the writer lock in case another process upgraded first.
                let version = try db.integer("PRAGMA user_version")
                if version == 3 {
                    try db.upgradePayloadStorage(cancelled: cancelled)
                } else if version != Self.schemaVersion {
                    throw CutError(code: "unsupported_sidecar", message: "The sidecar format changed while saving.")
                }
            }
            db.hasCompactStorage = true
            let indexUpdate = try refresh == nil
                ? prepareIndexEvidence(sections[Self.evidenceKey], in: db, cancelled: cancelled)
                : (refresh: nil, evidence: sections[Self.evidenceKey])
            let saved = try updateGeneration(db, stamp: stamp, refresh: refresh ?? indexUpdate.refresh,
                                             cancelled: cancelled)
            let result = try change(db, saved)
            var merged = sections
            merged[Self.evidenceKey] = indexUpdate.evidence
            for (key, update) in updating {
                try checkSidecarCancellation(cancelled)
                let current = try verifiedSection(key, in: db, stamp: saved, maxBytes: nil, cancelled: cancelled)
                let updated = try update(current)
                if !retainingLatest.isEmpty || current != updated { merged[key] = updated }
            }
            for (key, value) in merged {
                try writeSection(key, value: value, db: db, stamp: saved, cancelled: cancelled)
            }
            for (prefix, keep) in retainingLatest {
                try Self.pruneSections(in: db, prefix: prefix, keepingLatest: keep)
            }
            try checkSource()
            try checkSidecarCancellation(cancelled)
            try db.execute("COMMIT")
            return result
        }
    }

    private static func pruneSections(in db: SidecarDatabase, prefix: String, keepingLatest limit: Int) throws {
        // The rowid tracks insertion, including INSERT OR REPLACE. Match the literal prefix.
        try db.update("""
            DELETE FROM sections WHERE rowid IN (
                SELECT rowid FROM sections WHERE substr(name, 1, length(?)) = ?
                ORDER BY rowid DESC LIMIT -1 OFFSET ?)
            """, [prefix, prefix, String(limit)])
    }

    func writeSection(_ key: String, value: Data, db: SidecarDatabase, stamp saved: String,
                      cancelled: () -> Bool) throws {
        guard Self.validKey(key) else { throw sidecarError("Invalid section name.") }
        try checkSidecarCancellation(cancelled)
        let digest = try value.withUnsafeBytes { try checksum(key, stamp: saved, $0, cancelled: cancelled) }
        if value.count >= SidecarPayload.minimumSize,
           (try? verifiedSection(key, in: db, stamp: saved, maxBytes: value.count,
                                 cancelled: cancelled, matchingDigest: digest)) != nil {
            // A repeated save still counts as the newest use. Copy the existing
            // encoding inside SQLite only if another section was written since.
            try db.update("""
                INSERT OR REPLACE INTO sections(name, digest, value, logical_size)
                SELECT name, digest, value, logical_size FROM sections
                WHERE name = ? AND rowid < (SELECT max(rowid) FROM sections)
                """, [key])
            return
        }
        try checkSidecarCancellation(cancelled)
        let payload = try SidecarPayload.encode(value, key: key, cancelled: cancelled)
        try payload.bytes.withUnsafeBytes { bytes in
            try digest.withUnsafeBytes { digestBytes in
                try db.statement("INSERT OR REPLACE INTO sections(name, digest, value, logical_size) VALUES(?, ?, ?, ?)", [key]) { query in
                    guard sqlite3_bind_blob(query, 2, digestBytes.baseAddress, Int32(digestBytes.count), nil) == SQLITE_OK
                    else { throw db.error() }
                    // SQLITE_STATIC is safe until this statement is finalized,
                    // inside both withUnsafeBytes scopes. Avoid another payload copy.
                    let bound = bytes.isEmpty ? sqlite3_bind_zeroblob(query, 3, 0)
                        : sqlite3_bind_blob64(query, 3, bytes.baseAddress, UInt64(bytes.count), nil)
                    guard bound == SQLITE_OK, sqlite3_bind_int64(query, 4, Int64(payload.logicalSize)) == SQLITE_OK,
                          sqlite3_step(query) == SQLITE_DONE else { throw db.error() }
                }
            }
        }
    }
}

func checkSidecarCancellation(_ cancelled: () -> Bool) throws {
    if cancelled() { throw CutError(code: "cancelled", message: "Saving the analysis sidecar was cancelled.") }
}

func sidecarError(_ message: String) -> CutError {
    CutError(code: "sidecar_error", message: "Analysis sidecar: " + message)
}

final class SidecarDatabase {
    private let handle: OpaquePointer
    var hasCompactStorage = false
    var logicalSizeColumn: String { hasCompactStorage ? "logical_size" : "0" }

    init(_ url: URL, writing: Bool) throws {
        var connection: OpaquePointer?
        // Readers also open read-write, and never create the file. Connections
        // in one process share the file's locks, which SQLite takes through the
        // descriptor of whichever connection locked first. Were that a
        // read-only descriptor, a concurrent writer's RESERVED lock would fail
        // with EBADF and surface as a disk I/O error. SQLite itself falls back
        // to a read-only descriptor when the file cannot be opened for writing.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW
        // NOFOLLOW also rejects symlinked ancestors, including macOS /var.
        // Resolve the directory while retaining protection on the actual file.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw sidecarError(String(cString: strerror(errno)))
        }
        defer { free(parent) }
        let path = String(cString: parent) + "/" + url.lastPathComponent
        try Self.checkJournal(at: path + "-journal", writing: writing)
        let status = sqlite3_open_v2(path, &connection, flags, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open file."
            sqlite3_close(connection)
            throw sidecarError(message)
        }
        handle = connection
        sqlite3_busy_timeout(handle, writing ? 5_000 : 100)
        try execute("PRAGMA trusted_schema = OFF")
    }

    /// DELETE-mode writers initially leave the magic and record count zeroed
    /// until the journal has been synced. Other header fields are already valid.
    private static func checkJournal(at path: String, writing: Bool) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw sidecarError(String(cString: strerror(errno))) }
            return
        }
        let occupied = sidecarError("The sidecar journal path is occupied by an unrecognized file.")
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw occupied }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return }
            throw sidecarError(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 28)
        // A concurrent writer can be between creating and populating the journal.
        let deadline = ContinuousClock.now + .milliseconds(writing ? 100 : 25)
        while true {
            let count = pread(fd, &header, header.count, 0)
            if count == header.count {
                let magic: [UInt8] = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]
                let sector = header[20..<24].reduce(0) { $0 << 8 | Int($1) }
                let page = header[24..<28].reduce(0) { $0 << 8 | Int($1) }
                guard header.starts(with: magic) || header.prefix(12).allSatisfy({ $0 == 0 }),
                      (32...65536).contains(sector), sector.nonzeroBitCount == 1,
                      (512...65536).contains(page), page.nonzeroBitCount == 1 else { throw occupied }
                return
            }
            if fstat(fd, &info) == 0 && info.st_nlink == 0 { return }
            guard count == 0, .now < deadline else { throw occupied }
            usleep(1_000)
        }
    }

    // Closing the connection rolls back a transaction interrupted before COMMIT.
    deinit { sqlite3_close(handle) }

    func error() -> CutError { sidecarError(String(cString: sqlite3_errmsg(handle))) }


    /// Reads the file header through SQLite's own descriptor. Closing a second
    /// descriptor would release every lock this process holds on the database.
    private func header() -> [UInt8]? {
        var file: UnsafeMutablePointer<sqlite3_file>?
        guard sqlite3_file_control(handle, "main", SQLITE_FCNTL_FILE_POINTER, &file) == SQLITE_OK, let file,
              let read = file.pointee.pMethods?.pointee.xRead else { return nil }
        var header = [UInt8](repeating: 0, count: 72)
        guard read(file, &header, Int32(header.count), 0) == SQLITE_OK,
              header.starts(with: Array("SQLite format 3\0".utf8)) else { return nil }
        return header
    }

    func headerVersions() -> (applicationID: Int32, userVersion: Int32, usesWriteAheadLog: Bool)? {
        guard let header = header() else { return nil }
        func field(at offset: Int) -> Int32 {
            header[offset..<(offset + 4)].reduce(Int32(0)) { $0 << 8 | Int32($1) }
        }
        return (field(at: 68), field(at: 60), header[18] == 2 || header[19] == 2)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func whileWaitingForLocks<T>(_ cancelled: () -> Bool, _ body: () throws -> T) throws -> T {
        try withoutActuallyEscaping(cancelled) { check in
            try withUnsafePointer(to: check) { predicate in
                sqlite3_busy_handler(handle, { context, attempt in
                    guard let context, attempt < 100,
                          !context.assumingMemoryBound(to: (() -> Bool).self).pointee() else { return 0 }
                    sqlite3_sleep(50)
                    return 1
                }, UnsafeMutableRawPointer(mutating: predicate))
                defer { sqlite3_busy_handler(handle, nil, nil) }
                do { return try body() }
                catch {
                    try checkSidecarCancellation(check)
                    throw error
                }
            }
        }
    }

    func readBlob(table: String = "sections", column: String = "value", row: Int64, maxBytes: Int?, cancelled: () -> Bool,
                  visit: (UnsafeRawBufferPointer) -> Void) throws -> Data? {
        try checkSidecarCancellation(cancelled)
        var blob: OpaquePointer?
        guard sqlite3_blob_open(handle, "main", table, column, row, 0, &blob) == SQLITE_OK,
              let blob else { throw error() }
        defer { sqlite3_blob_close(blob) }
        let size = Int(sqlite3_blob_bytes(blob))
        if let maxBytes, size > maxBytes { return nil }
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { buffer in
            for offset in stride(from: 0, to: size, by: 1 << 20) {
                try checkSidecarCancellation(cancelled)
                let length = min(size - offset, 1 << 20)
                let part = UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<offset + length])
                guard sqlite3_blob_read(blob, part.baseAddress, Int32(length), Int32(offset)) == SQLITE_OK else { throw error() }
                visit(UnsafeRawBufferPointer(part))
            }
        }
        return data
    }

    func update(_ sql: String, _ bindings: [String]) throws {
        try statement(sql, bindings) { query in
            guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
        }
    }

    func updateBlobs(_ sql: String, _ leading: [String], blobs: [Data], trailing: [String] = []) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindings = leading + Array(repeating: "", count: blobs.count) + trailing
        try statement(sql, bindings) { query in
            for (offset, blob) in blobs.enumerated() {
                let index = Int32(leading.count + offset + 1)
                let result = blob.withUnsafeBytes { bytes in
                    bytes.isEmpty ? sqlite3_bind_zeroblob(query, index, 0)
                        : sqlite3_bind_blob64(query, index, bytes.baseAddress, UInt64(bytes.count), transient)
                }
                guard result == SQLITE_OK else { throw error() }
            }
            guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
        }
    }

    func integer(_ sql: String) throws -> Int32 {
        try statement(sql) { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw error() }
            return sqlite3_column_int(query, 0)
        }
    }

    func statement<T>(_ sql: String, _ bindings: [String] = [],
                      _ body: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query else { throw error() }
        defer { sqlite3_finalize(query) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            guard sqlite3_bind_text(query, Int32(i + 1), value, -1, transient) == SQLITE_OK else { throw error() }
        }
        return try body(query)
    }
}
