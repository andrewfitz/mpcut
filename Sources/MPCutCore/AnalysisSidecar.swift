import CryptoKit
import Darwin
import Foundation
import SQLite3

/// A snapshot of the source identity. Reads never create a sidecar. Each producer
/// assigns a version to its section keys so unrelated analyses can evolve independently.
public struct AnalysisSidecar: Sendable {
    @TaskLocal public static var readsEnabled = true

    @TaskLocal public static var automaticWritesEnabled = true

    public func saveAutomatically(_ sections: @autoclosure () throws -> [String: Data],
                                  retainingLatest: [String: Int] = [:], cancelled: () -> Bool = { false }) {
        guard Self.readsEnabled, Self.automaticWritesEnabled, !cancelled() else { return }
        // Analysis remains usable when the source folder is read-only.
        try? save(sections(), retainingLatest: retainingLatest, cancelled: cancelled)
    }

    public let source: URL
    let identity: SourceIdentity
    public var url: URL { Self.url(for: source) }

    public static func url(for source: URL) -> URL { source.appendingPathExtension("mpcut") }

    public init(source: URL) throws {
        guard source.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local media file.") }
        self.source = source.standardizedFileURL
        identity = try SourceIdentity(self.source)
    }

    public init(media: MediaInfo) {
        source = media.url.standardizedFileURL
        identity = media.identity
    }

    private var stamp: String {
        "\(identity.device):\(identity.inode):\(identity.size):\(identity.modifiedSeconds):\(identity.modifiedNanoseconds)"
    }

    private static let applicationID: Int32 = 0x4d504354 // MPCT
    private static let version: Int32 = 1

    package func checkSource() throws {
        guard (try? SourceIdentity(source)) == identity else {
            throw CutError(code: "source_changed", message: "The media changed during analysis.")
        }
    }

    private func exists() throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw sidecarError(String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_dev != identity.device || info.st_ino != identity.inode else {
            throw sidecarError("The sidecar path must identify a separate regular file.")
        }
        return true
    }

    private func validate(_ db: SidecarDatabase) throws {
        // MPCut never uses a write-ahead log. Reject one before the first query,
        // which would create log files beside someone else's database.
        guard !db.usesWriteAheadLog else {
            throw CutError(code: "unsupported_sidecar", message: "This file is not a supported MPCut analysis sidecar.")
        }
        let kind = try db.integer("PRAGMA application_id")
        guard kind == Self.applicationID, try db.integer("PRAGMA user_version") == Self.version else {
            throw CutError(code: "unsupported_sidecar", message: "This file is not a supported MPCut analysis sidecar.")
        }
    }

    private func storedStamp(_ db: SidecarDatabase) throws -> String {
        try db.statement("SELECT stamp FROM source WHERE id = 1") { query in
            guard sqlite3_step(query) == SQLITE_ROW, let value = sqlite3_column_text(query, 0) else {
                throw sidecarError("The sidecar has no media identity.")
            }
            return String(cString: value)
        }
    }

    /// The saved stamp when it describes this source. A volume's device number
    /// can change on each mount, so only the fields after it must agree. The
    /// saved text also seeds the section checksums and is therefore kept as is.
    private func currentStamp(_ db: SidecarDatabase) throws -> String? {
        let saved = try storedStamp(db)
        return saved.drop { $0 != ":" } == stamp.drop { $0 != ":" } ? saved : nil
    }

    /// An empty file, or one of MPCut's databases that SQLite reports as
    /// corrupt, can be rebuilt. Any other file is left for the user to resolve.
    private func damaged(cancelled: () -> Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        if info.st_size == 0 { return true }
        guard let db = try? SidecarDatabase(url, writing: true) else { return false }
        do {
            try db.whileWaitingForLocks(cancelled) {
                try validate(db)
                _ = try storedStamp(db)
            }
            return false
        } catch {
            guard db.isCorrupt, let header = db.headerVersions() else { return false }
            return header.applicationID == Self.applicationID && header.userVersion == Self.version
        }
    }

    /// Inspects the container and media identity without loading any analysis payload.
    public func status() -> String {
        do {
            guard try exists() else { return "missing" }
            let db = try SidecarDatabase(url, writing: false)
            try validate(db)
            return try currentStamp(db) != nil && (try? SourceIdentity(source)) == identity ? "current" : "stale"
        } catch let error as CutError where error.code == "unsupported_sidecar" {
            return "unsupported"
        } catch {
            return "unreadable"
        }
    }

    public func keys() -> [String] {
        guard Self.readsEnabled else { return [] }
        do {
            guard let db = try openReadSnapshot(), try currentStamp(db) != nil else { return [] }
            let result = try db.statement("SELECT name FROM sections ORDER BY name") { query in
                var names = [String]()
                var step = sqlite3_step(query)
                while step == SQLITE_ROW, let value = sqlite3_column_text(query, 0) {
                    names.append(String(cString: value))
                    step = sqlite3_step(query)
                }
                guard step == SQLITE_DONE else { throw db.error() }
                return names
            }
            try checkSource()
            return result
        } catch { return [] }
    }

    public func read(_ key: String, maxBytes: Int? = nil, cancelled: () -> Bool = { Task.isCancelled }) -> Data? {
        guard Self.readsEnabled, Self.validKey(key), !cancelled() else { return nil }
        do {
            guard let db = try openReadSnapshot() else { return nil }
            let section = try verifiedSection(key, in: db, maxBytes: maxBytes, cancelled: cancelled)
            try checkSource()
            return cancelled() ? nil : section
        } catch { return nil }
    }

    /// Select related sections from one committed SQLite generation. The
    /// transaction ends when the caller finishes loading its result.
    func withReadSnapshot<Value>(cancelled: () -> Bool,
                                 _ load: ((_ key: String) -> Data?) throws -> Value?) throws -> Value? {
        guard Self.readsEnabled, !cancelled(),
              let db = try? openReadSnapshot() else { return nil }
        let value = try withoutActuallyEscaping(cancelled) { check in
            try load { key in
                guard Self.validKey(key), !check() else { return nil }
                return try? verifiedSection(key, in: db, maxBytes: nil, cancelled: check)
            }
        }
        guard !cancelled(), (try? SourceIdentity(source)) == identity else { return nil }
        return value
    }

    private func openReadSnapshot() throws -> SidecarDatabase? {
        guard try exists() else { return nil }
        try checkSource()
        let db = try SidecarDatabase(url, writing: false)
        try db.execute("BEGIN")
        try validate(db)
        return db
    }

    private func verifiedSection(_ key: String, in db: SidecarDatabase, maxBytes: Int?,
                                 cancelled: () -> Bool) throws -> Data? {
        guard let saved = try currentStamp(db) else { return nil }
        return try db.statement("SELECT digest, rowid FROM sections WHERE name = ?", [key]) { query in
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw db.error() }
            guard sqlite3_column_bytes(query, 0) == 32,
                  let expected = sqlite3_column_blob(query, 0) else { return nil }
            // Read into the destination allocation directly. Materializing
            // sqlite3_column_blob would also keep a full SQLite-owned copy.
            var hash = checksumSeed(key, stamp: saved)
            let data = try db.readBlob(row: sqlite3_column_int64(query, 1), maxBytes: maxBytes, cancelled: cancelled) { chunk in
                hash.update(bufferPointer: chunk)
            }
            guard let data else { return nil }
            return hash.finalize().elementsEqual(UnsafeRawBufferPointer(start: expected, count: 32)) ? data : nil
        }
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 512 && !key.utf8.contains(0)
    }

    private func checksumSeed(_ key: String, stamp: String) -> SHA256 {
        var hash = SHA256()
        hash.update(data: Data((stamp + "\0" + key + "\0").utf8))
        return hash
    }

    private func checksum(_ key: String, stamp: String, _ bytes: UnsafeRawBufferPointer,
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
        try checkSource()
        try checkSidecarCancellation(cancelled)
        guard !sections.isEmpty || !updating.isEmpty else { return }
        guard sections.keys.allSatisfy(Self.validKey), updating.keys.allSatisfy(Self.validKey),
              sections.keys.allSatisfy({ updating[$0] == nil }) else {
            throw sidecarError("Section names must be valid and unique across writes and updates.")
        }
        guard retainingLatest.allSatisfy({ Self.validKey($0.key) && $0.value >= 0 }) else {
            throw sidecarError("Invalid section retention limit.")
        }

        if try !exists() || damaged(cancelled: cancelled) {
            // Stage beside the media. Exclusive publication prevents a race with
            // a second writer and leaves no empty database behind on cancellation.
            var template = Array((url.deletingLastPathComponent().appendingPathComponent(".mpcut-XXXXXX").path).utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { throw sidecarError(String(cString: strerror(errno))) }
            close(fd)
            let staging = URL(fileURLWithPath: String(cString: template))
            defer { try? FileManager.default.removeItem(at: staging) }
            try write(sections, updating: updating, to: staging, create: true, retainingLatest: retainingLatest, cancelled: cancelled)
            try checkSource()
            try checkSidecarCancellation(cancelled)
            guard chmod(staging.path, 0o666 & ~creationMask) == 0 else { throw sidecarError(String(cString: strerror(errno))) }
            if try publish(staging, cancelled: cancelled) { return }
            // Another writer published first. Merge into its committed database.
            guard try exists() else { throw sidecarError("The destination changed while saving.") }
        }
        try write(sections, updating: updating, to: url, create: false, retainingLatest: retainingLatest, cancelled: cancelled)
    }

    /// A damaged database has no SQLite write lock that all repairers can use.
    /// Serialize the final destination check and rename across processes without
    /// creating another file beside the recording. Healthy writers use SQLite.
    private func publish(_ staging: URL, cancelled: () -> Bool) throws -> Bool {
        if try !exists() {
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
            guard damaged(cancelled: cancelled) else { return false }
            try checkSidecarCancellation(cancelled)
            // The old journal must never be replayed into the replacement.
            unlink(url.path + "-journal")
            guard rename(staging.path, url.path) == 0 else { throw sidecarError(String(cString: strerror(errno))) }
            return true
        }
        let failure = publishExclusively(from: staging, to: url)
        if failure == 0 { return true }
        guard failure == EEXIST else { throw sidecarError(String(cString: strerror(failure))) }
        return false
    }

    private func write(_ sections: [String: Data], updating: [String: (Data?) throws -> Data],
                       to destination: URL, create: Bool, retainingLatest: [String: Int],
                       cancelled: () -> Bool) throws {
        let db = try SidecarDatabase(destination, writing: true)
        try db.whileWaitingForLocks(cancelled) {
            if create { try db.execute("PRAGMA auto_vacuum = FULL") }
            else { try validate(db) }
            try db.execute("BEGIN IMMEDIATE")
            try checkSource()
            var saved = stamp
            if create {
                try db.execute("""
                    PRAGMA application_id = \(Self.applicationID);
                    PRAGMA user_version = \(Self.version);
                    CREATE TABLE source(id INTEGER PRIMARY KEY CHECK(id = 1), stamp TEXT NOT NULL);
                    CREATE TABLE sections(name TEXT PRIMARY KEY NOT NULL, digest BLOB NOT NULL, value BLOB NOT NULL);
                    """)
                try db.update("INSERT INTO source(id, stamp) VALUES(1, ?)", [stamp])
            } else if let current = try currentStamp(db) {
                saved = current
            } else {
                try db.execute("DELETE FROM sections")
                try db.update("UPDATE source SET stamp = ? WHERE id = 1", [stamp])
            }
            var merged = sections
            for (key, update) in updating {
                try checkSidecarCancellation(cancelled)
                let current = try verifiedSection(key, in: db, maxBytes: nil, cancelled: cancelled)
                let updated = try update(current)
                if !retainingLatest.isEmpty || current != updated { merged[key] = updated }
            }
            for (key, value) in merged {
                try checkSidecarCancellation(cancelled)
                try value.withUnsafeBytes { bytes in
                    let digest = try checksum(key, stamp: saved, bytes, cancelled: cancelled)
                    try digest.withUnsafeBytes { digestBytes in
                        try db.statement("INSERT OR REPLACE INTO sections(name, digest, value) VALUES(?, ?, ?)", [key]) { query in
                            guard sqlite3_bind_blob(query, 2, digestBytes.baseAddress, Int32(digestBytes.count), nil) == SQLITE_OK
                            else { throw db.error() }
                            // SQLITE_STATIC is safe until this statement is finalized,
                            // inside both withUnsafeBytes scopes. Avoid another payload copy.
                            let bound = bytes.isEmpty ? sqlite3_bind_zeroblob(query, 3, 0)
                                : sqlite3_bind_blob64(query, 3, bytes.baseAddress, UInt64(bytes.count), nil)
                            guard bound == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw db.error() }
                        }
                    }
                }
            }
            for (prefix, keep) in retainingLatest {
                // The rowid tracks insertion, including INSERT OR REPLACE above.
                // Match the literal prefix; section names may contain wildcards.
                try db.update("""
                    DELETE FROM sections WHERE rowid IN (
                        SELECT rowid FROM sections WHERE substr(name, 1, length(?)) = ?
                        ORDER BY rowid DESC LIMIT -1 OFFSET ?)
                    """, [prefix, prefix, String(keep)])
            }
            try checkSource()
            try checkSidecarCancellation(cancelled)
            try db.execute("COMMIT")
        }
    }
}

private func checkSidecarCancellation(_ cancelled: () -> Bool) throws {
    if cancelled() { throw CutError(code: "cancelled", message: "Saving the analysis sidecar was cancelled.") }
}

private func sidecarError(_ message: String) -> CutError {
    CutError(code: "sidecar_error", message: "Analysis sidecar: " + message)
}

private final class SidecarDatabase {
    private let handle: OpaquePointer

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

    // Closing the connection rolls back a transaction interrupted before COMMIT.
    deinit { sqlite3_close(handle) }

    func error() -> CutError { sidecarError(String(cString: sqlite3_errmsg(handle))) }

    var isCorrupt: Bool { [SQLITE_CORRUPT, SQLITE_NOTADB].contains(sqlite3_errcode(handle)) }

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

    /// The header's write and read format versions are 2 for a write-ahead log.
    var usesWriteAheadLog: Bool { header().map { $0[18] == 2 || $0[19] == 2 } ?? false }

    func headerVersions() -> (applicationID: Int32, userVersion: Int32)? {
        guard let header = header() else { return nil }
        func field(at offset: Int) -> Int32 {
            header[offset..<(offset + 4)].reduce(Int32(0)) { $0 << 8 | Int32($1) }
        }
        return (field(at: 68), field(at: 60))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func whileWaitingForLocks(_ cancelled: () -> Bool, _ body: () throws -> Void) throws {
        try withoutActuallyEscaping(cancelled) { check in
            try withUnsafePointer(to: check) { predicate in
                sqlite3_busy_handler(handle, { context, attempt in
                    guard let context, attempt < 100,
                          !context.assumingMemoryBound(to: (() -> Bool).self).pointee() else { return 0 }
                    sqlite3_sleep(50)
                    return 1
                }, UnsafeMutableRawPointer(mutating: predicate))
                defer { sqlite3_busy_handler(handle, nil, nil) }
                do { try body() }
                catch {
                    try checkSidecarCancellation(check)
                    throw error
                }
            }
        }
    }

    func readBlob(row: Int64, maxBytes: Int?, cancelled: () -> Bool,
                  visit: (UnsafeRawBufferPointer) -> Void) throws -> Data? {
        try checkSidecarCancellation(cancelled)
        var blob: OpaquePointer?
        guard sqlite3_blob_open(handle, "main", "sections", "value", row, 0, &blob) == SQLITE_OK,
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
