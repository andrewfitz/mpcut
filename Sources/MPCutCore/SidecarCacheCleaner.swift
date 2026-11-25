import Darwin
import Foundation
import SQLite3

package typealias SidecarCacheLocation = SidecarStorageMode

/// Byte lengths of stored payloads. The difference from the SQLite file length includes
/// table and index records, checksums, and unused page space.
package struct CutcacheUsage: Encodable, Sendable {
    package let databaseBytes: Int64
    package let sectionBytes: [String: Int64]
    package let archivedSectionBytes: [String: Int64]
    package let checkpointBytes: Int64
    package let markerBytes: Int64
    package let sqliteOverheadBytes: Int64

    fileprivate init(db: SidecarDatabase, databaseBytes: Int64) throws {
        func lengths(_ sql: String) throws -> [String: Int64] {
            try db.statement(sql) { query in
                var sizes: [String: Int64] = [:]
                var step = sqlite3_step(query)
                while step == SQLITE_ROW {
                    guard let key = sqlite3_column_text(query, 0) else { throw db.error() }
                    sizes[String(cString: key)] = sqlite3_column_int64(query, 1)
                    step = sqlite3_step(query)
                }
                guard step == SQLITE_DONE else { throw db.error() }
                return sizes
            }
        }
        func bytes(_ sql: String) throws -> Int64 {
            try db.statement(sql) { query in
                guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
                return sqlite3_column_int64(query, 0)
            }
        }
        self.databaseBytes = databaseBytes
        sectionBytes = try lengths("SELECT name, length(value) FROM sections")
        let archived = try db.integer("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='archived_sections')")
        archivedSectionBytes = archived == 0 ? [:] : try lengths(
            "SELECT name, sum(length(value)) FROM archived_sections GROUP BY name")
        if try db.hasSceneAttempts {
            checkpointBytes = try bytes("SELECT coalesce(sum(length(checkpoint)),0) FROM scene_attempts")
            markerBytes = try bytes("SELECT coalesce(sum(length(value)),0) FROM scene_markers")
        } else {
            checkpointBytes = 0
            markerBytes = 0
        }
        var remaining = databaseBytes
        func account(_ bytes: Int64) throws {
            guard bytes >= 0, bytes <= remaining else { throw sidecarError("Invalid cache payload lengths.") }
            remaining -= bytes
        }
        try sectionBytes.values.forEach(account)
        try archivedSectionBytes.values.forEach(account)
        try account(checkpointBytes)
        try account(markerBytes)
        sqliteOverheadBytes = remaining
    }
}

package struct SidecarCacheEntry: Identifiable, Sendable {
    package var id: String { SidecarCacheCleaner.identifier(record) }
    package var url: URL { record.url }
    package var source: URL { record.source }
    package var rootURL: URL { record.rootURL }
    package var rootIdentity: String { record.rootIdentity }
    package var location: SidecarCacheLocation { record.mode }
    package let bytes: Int64
    package let usage: CutcacheUsage?
    package let issue: String?
    package var clearToken: String? {
        guard let snapshot, issue == nil else { return nil }
        let revision = "\(snapshot.device):\(snapshot.inode):\(snapshot.size):\(snapshot.allocated):"
            + "\(snapshot.changedSeconds):\(snapshot.changedNanoseconds)"
        return TranscriptStore.digest(Data((revision + ":" + id).utf8))
    }
    fileprivate let record: SidecarCatalogEntry
    fileprivate let snapshot: CacheFileSnapshot?
    fileprivate var aliases: [SidecarCatalogEntry] = []
}

package struct SidecarSkippedCache: Identifiable, Sendable {
    package let id: String
    package let url: URL
    package let rootIdentity: String
    package let reason: String
}

package struct SidecarClearResult: Sendable {
    package fileprivate(set) var clearedEntries: [SidecarCacheEntry] = []
    package var cleared: [URL] { clearedEntries.map(\.url) }
    package var clearedSources: Set<URL> {
        Set(clearedEntries.flatMap { entry in [entry.source] + entry.aliases.map(\.source) })
    }
    package fileprivate(set) var skippedEntries: [SidecarSkippedCache] = []
    package var skipped: [URL: String] {
        Dictionary(skippedEntries.map { ($0.url, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }
    package fileprivate(set) var reclaimedBytes: Int64 = 0
}

private struct CacheFileSnapshot: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let allocated: Int64
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw sidecarError(String(cString: strerror(errno))) }
        try self.init(info)
    }

    init(directory: Int32, name: String) throws {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw sidecarError(String(cString: strerror(errno)))
        }
        try self.init(info)
    }

    private init(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw sidecarError("The cache must be a separate regular file.")
        }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        allocated = info.st_blocks * 512
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// A store holding an old epoch cannot recreate data removed in another process.
/// Ordinary opens perform a stat. Only a successful clear needs to create the marker directory.
package struct SidecarClearEpoch: Hashable, Sendable {
    private let sidecar: URL
    private let directory: URL
    private let marker: URL?
    private let version: Version?

    private struct Version: Hashable, Sendable {
        let inode: UInt64
        let changed: Int
        let nanos: Int

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            inode = info.st_ino
            changed = info.st_ctimespec.tv_sec
            nanos = info.st_ctimespec.tv_nsec
        }
    }

    package static func capture(sidecar: URL) -> Self {
        let directory = SidecarLocations.home.appendingPathComponent("clear-epochs", isDirectory: true)
        // Most installations have never cleared a cache. Avoid realpath, volume
        // lookups and hashing on the ordinary read path in that case.
        let marker = access(directory.path, F_OK) == 0 ? markerURL(for: sidecar, in: directory) : nil
        return Self(sidecar: sidecar, directory: directory, marker: marker, version: marker.flatMap(Version.init))
    }

    private static func markerURL(for sidecar: URL, in directory: URL) -> URL {
        // Canonicalizing a missing file leaves macOS /var unresolved. Anchor to
        // the nearest existing directory so publication cannot change this key.
        var anchor = sidecar.standardizedFileURL.deletingLastPathComponent()
        var tail = [sidecar.lastPathComponent]
        while anchor.path != "/" && !FileManager.default.fileExists(atPath: anchor.path) {
            tail.append(anchor.lastPathComponent)
            anchor.deleteLastPathComponent()
        }
        let directoryURL = AnalysisSidecar.canonicalSource(anchor)
        let suffix = tail.reversed().joined(separator: "/")
        var path = (directoryURL.path as NSString).appendingPathComponent(suffix).precomposedStringWithCanonicalMapping
        if (try? directoryURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false {
            path = path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        return directory.appendingPathComponent(TranscriptStore.digest(Data(path.utf8)))
    }

    package func check() throws {
        if marker == nil && access(directory.path, F_OK) != 0 && errno == ENOENT { return }
        let current = marker ?? Self.markerURL(for: sidecar, in: directory)
        guard version == Version(current) else {
            throw sidecarError("The cache was cleared after this operation started.")
        }
    }

    fileprivate func advance() throws {
        let marker = marker ?? Self.markerURL(for: sidecar, in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(UUID().uuidString.utf8).write(to: marker, options: .atomic)
    }
}

package enum SidecarCacheCleaner {
    fileprivate static func identifier(_ entry: SidecarCatalogEntry) -> String {
        entry.rootIdentity + "\0" + entry.catalogPath
    }

    /// Explicit folder scans can be limited to their scope without registering discoveries.
    package static func preview(scanning folders: [URL] = [], protected: Set<URL> = [],
                                sources: [URL] = [], projects: [URL] = [],
                                scannedOnly: Bool = false) -> [SidecarCacheEntry] {
        var known = [String: SidecarCatalogEntry]()
        for entry in SidecarLocations.knownEntries() where entry.url.pathExtension == "cutcache" {
            known[identifier(entry)] = entry
        }
        var forbidden = Set(protected.union(sources).union(projects).map(AnalysisSidecar.canonicalSource))
        let explicitRoots = folders.map { AnalysisSidecar.canonicalSource($0).pathComponents }
        func inScannedFolder(_ url: URL) -> Bool {
            guard !explicitRoots.isEmpty else { return false }
            let components = AnalysisSidecar.canonicalSource(url).pathComponents
            return explicitRoots.contains { components.starts(with: $0) }
        }
        var scanned = Set<String>()
        for source in sources {
            for entry in SidecarLocations(source: source).candidateEntries where FileManager.default.fileExists(atPath: entry.url.path) {
                known[identifier(entry)] = entry
            }
        }
        var managedFolders = folders + projects.map(ProjectFile.directory(of:))
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                if url.lastPathComponent == "MPCut Cache" {
                    managedFolders.append(url)
                    files.skipDescendants()
                    continue
                }
                guard url.pathExtension == "cutcache", (try? CacheFileSnapshot(url)) != nil else { continue }
                let source = url.deletingPathExtension()
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                guard let entry = SidecarCatalogEntry.adjacent(source: source) else { continue }
                let key = identifier(entry)
                if known[key] == nil {
                    known[key] = entry
                    scanned.insert(key)
                }
            }
        }
        for record in SidecarLocations.managedEntries(scanning: managedFolders, sources: sources,
                                                      restrictedTo: scannedOnly ? explicitRoots : [], sourceForCache: { url in
            guard (!scannedOnly || inScannedFolder(url)), !pathIsProtected(url, protected: forbidden) else { return nil }
            return managedSource(at: url)
        }) where known[identifier(record)] == nil {
            known[identifier(record)] = record
        }
        if scannedOnly {
            for record in known.values where inScannedFolder(record.url) {
                forbidden.insert(AnalysisSidecar.canonicalSource(record.source))
            }
        }
        var entries: [SidecarCacheEntry] = []
        var inspected: [CacheFileSnapshot: Int] = [:]
        for (key, record) in known.sorted(by: { ($0.value.url.path, $0.key) < ($1.value.url.path, $1.key) }) {
            // A read-only session can already know a cache when its folder is explicitly scanned.
            // Only a validated entry under a selected folder becomes a durable registration.
            let inScope = inScannedFolder(record.url)
            if scannedOnly && !inScope { continue }
            let entry = inspect(record, protected: forbidden, register: inScope && !scannedOnly)
            if scanned.contains(key) && entry.snapshot == nil { continue }
            if let snapshot = entry.snapshot {
                // Different spellings can address the same file on a case-insensitive volume.
                if let first = inspected[snapshot] {
                    entries[first].aliases.append(record)
                    continue
                }
                inspected[snapshot] = entries.count
            }
            entries.append(entry)
        }
        return entries
    }

    package static func clear(_ entries: [SidecarCacheEntry],
                              protected: Set<URL> = []) -> SidecarClearResult {
        let forbidden = Set(protected.union(entries.map(\.source)).map(AnalysisSidecar.canonicalSource))
        var result = SidecarClearResult()
        var visited = Set<String>()
        for entry in entries where visited.insert(entry.id).inserted {
            do {
                if let issue = entry.issue { throw sidecarError(issue) }
                let recovered = try clearEntry(entry, protected: forbidden)
                result.reclaimedBytes += recovered
                result.clearedEntries.append(entry)
            } catch {
                result.skippedEntries.append(SidecarSkippedCache(id: entry.id, url: entry.url,
                                                               rootIdentity: entry.rootIdentity,
                                                               reason: entry.issue ?? error.localizedDescription))
            }
        }
        return result
    }

    /// Direct lookup for CLI inspection. Do not walk other projects or register discoveries.
    package static func copies(for source: URL) -> [SidecarCacheEntry] {
        let locations = SidecarLocations(source: source)
        guard !AnalysisSidecar.isExcluded(source, in: AnalysisSidecar.excludedSources) else { return [] }
        var seen = Set<URL>()
        let protected = Set([source, SidecarLocations.projectURL].compactMap { $0 }.map(AnalysisSidecar.canonicalSource))
        return locations.candidateEntries.compactMap { record in
            guard seen.insert(record.url).inserted, FileManager.default.fileExists(atPath: record.url.path) else { return nil }
            return inspect(record, protected: protected, register: false)
        }
    }

    private static func inspect(_ record: SidecarCatalogEntry, protected: Set<URL>, register: Bool) -> SidecarCacheEntry {
        do {
            let snapshot = try checkPath(record, protected: protected)
            let db = try SidecarDatabase(record.url, writing: false)
            try AnalysisSidecar.validate(db, at: record.url)
            try db.execute("BEGIN")
            try checkOwner(record, db: db)
            let usage = try CutcacheUsage(db: db, databaseBytes: snapshot.size)
            let issue = try hasLiveClaim(db) ? "An active scene scan is using this cache." : nil
            guard try CacheFileSnapshot(record.url) == snapshot else {
                throw sidecarError("The cache changed while reading its inventory.")
            }
            if register { try SidecarLocations.registerDiscovered(record, in: db) }
            return SidecarCacheEntry(bytes: snapshot.allocated, usage: usage, issue: issue,
                                     record: record, snapshot: snapshot)
        } catch {
            return SidecarCacheEntry(bytes: 0, usage: nil, issue: error.localizedDescription,
                                     record: record, snapshot: nil)
        }
    }

    /// The source path is a display hint. The independently validated owning directory
    /// and lookup key decide whether a managed cache is eligible for cleanup.
    private static func managedSource(at url: URL) -> URL? {
        do {
            guard try AnalysisSidecar.exists(url, sourceIdentity: nil) else { return nil }
            let db = try SidecarDatabase(url, writing: false)
            try AnalysisSidecar.validate(db, at: url)
            return try db.statement("SELECT source_path FROM sidecar_location WHERE id = 1 AND lookup_key = ?",
                                    [url.deletingPathExtension().lastPathComponent]) { query in
                guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_type(query, 0) == SQLITE_TEXT,
                      sqlite3_column_bytes(query, 0) <= PATH_MAX, let raw = sqlite3_column_text(query, 0) else { return nil }
                let path = String(cString: raw)
                guard path.hasPrefix("/"), path.utf8.count == sqlite3_column_bytes(query, 0) else { return nil }
                return URL(fileURLWithPath: path)
            }
        } catch { return nil }
    }

    private static func pathIsProtected(_ url: URL, protected: Set<URL>) -> Bool {
        [url, URL(fileURLWithPath: url.path + "-journal"), URL(fileURLWithPath: url.path + "-wal"),
         URL(fileURLWithPath: url.path + "-shm")].contains { protected.contains(AnalysisSidecar.canonicalSource($0)) }
    }

    private static func checkPath(_ record: SidecarCatalogEntry, protected: Set<URL>) throws -> CacheFileSnapshot {
        guard record.url.pathExtension == "cutcache", SidecarLocations.validate(record) else {
            throw sidecarError("The original cache folder or disk is unavailable or has changed.")
        }
        guard !pathIsProtected(record.url, protected: protected),
              try AnalysisSidecar.exists(record.url, sourceIdentity: try? SourceIdentity(record.source)) else {
            throw sidecarError("The cache is missing or its path belongs to protected media.")
        }
        return try CacheFileSnapshot(record.url)
    }

    private static func checkOwner(_ entry: SidecarCatalogEntry, db: SidecarDatabase) throws {
        if entry.mode == .media {
            guard let store = try? AnalysisSidecar(source: entry.source), try store.currentStamp(db) != nil,
                  store.identity.isCurrentSnapshot(at: entry.source) else {
                throw sidecarError("The cache does not match the adjacent recording, or the recording is unavailable.")
            }
        } else {
            _ = try AnalysisSidecar.storedStamp(db)
        }
        let key = try db.statement("SELECT lookup_key FROM sidecar_location WHERE id = 1") { query -> String? in
            guard sqlite3_step(query) == SQLITE_ROW else { throw sidecarError("The cache location metadata is missing.") }
            return sqlite3_column_text(query, 0).map { String(cString: $0) }
        }
        guard key == entry.lookupKey else { throw sidecarError("The cache belongs to a different location.") }
    }

    private static func hasLiveClaim(_ db: SidecarDatabase) throws -> Bool {
        guard try db.hasSceneAttempts else { return false }
        return try db.statement("SELECT 1 FROM scene_attempts WHERE state = 0 AND owner IS NOT NULL AND expires > ? LIMIT 1",
                         [String(Date().timeIntervalSince1970)]) { query in
            switch sqlite3_step(query) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw db.error()
            }
        }
    }

    private static func clearEntry(_ entry: SidecarCacheEntry, protected: Set<URL>) throws -> Int64 {
        guard let original = entry.snapshot, try checkPath(entry.record, protected: protected) == original else {
            throw sidecarError("The cache changed since the preview. Refresh the list before clearing it.")
        }
        let parent = entry.url.deletingLastPathComponent()
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw sidecarError(String(cString: strerror(errno))) }
        defer { close(directory) }
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw sidecarError("The cache is in use.") }
        defer { flock(directory, LOCK_UN) }
        let db = try SidecarDatabase(entry.url, writing: true)
        try db.execute("PRAGMA busy_timeout = 0")
        try AnalysisSidecar.validate(db, at: entry.url)
        try db.execute("BEGIN EXCLUSIVE")
        try checkOwner(entry.record, db: db)
        guard try !hasLiveClaim(db) else { throw sidecarError("An active scene scan is using this cache.") }
        guard try checkPath(entry.record, protected: protected) == original else {
            throw sidecarError("The cache changed since the preview.")
        }
        let epoch = SidecarClearEpoch.capture(sidecar: entry.url)
        // Keep the publication and SQLite locks through unlink. A worker which has
        // already opened this generation must see the new epoch before it publishes.
        try epoch.advance()
        guard try checkPath(entry.record, protected: protected) == original else {
            throw sidecarError("The cache changed during removal.")
        }
        try checkOwner(entry.record, db: db)
        let name = entry.url.lastPathComponent
        guard try CacheFileSnapshot(directory: directory, name: name) == original else {
            throw sidecarError("The cache directory changed during removal.")
        }
        guard unlinkat(directory, name, 0) == 0 else {
            throw sidecarError(String(cString: strerror(errno)))
        }
        SidecarLocations.forgetEntries([entry.record] + entry.aliases)
        return original.allocated
    }
}
