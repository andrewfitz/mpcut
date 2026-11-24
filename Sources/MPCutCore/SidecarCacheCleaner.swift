import Darwin
import Foundation
import SQLite3

package typealias SidecarCacheLocation = SidecarStorageMode

package struct SidecarCacheEntry: Identifiable, Sendable {
    package var id: String { SidecarCacheCleaner.identifier(record) }
    package var url: URL { record.url }
    package var source: URL { record.source }
    package var rootURL: URL { record.rootURL }
    package var rootIdentity: String { record.rootIdentity }
    package var location: SidecarCacheLocation { record.mode }
    package let bytes: Int64
    /// Compressed payload bytes. Actual space recovered depends on SQLite page boundaries.
    package let rebuildableBytes: Int64
    package let retained: [String]
    package let issue: String?
    /// Written by a build whose format is no longer read. None of its analysis can be
    /// reused, so clearing removes the file, or rewrites it when `retained` is not empty.
    package let olderFormat: Bool
    fileprivate let record: SidecarCatalogEntry
    fileprivate let snapshot: CacheFileSnapshot?
}

package struct SidecarSkippedCache: Identifiable, Sendable {
    package let id: String
    package let url: URL
    package let rootIdentity: String
    package let reason: String
}

package struct SidecarClearResult: Sendable {
    package fileprivate(set) var cleared: [URL] = []
    package fileprivate(set) var skippedEntries: [SidecarSkippedCache] = []
    package var skipped: [URL: String] {
        Dictionary(skippedEntries.map { ($0.url, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }
    package fileprivate(set) var reclaimedBytes: Int64 = 0
}

private struct CacheFileSnapshot: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let allocated: Int64
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw sidecarError(String(cString: strerror(errno))) }
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
        entry.rootIdentity + "\0" + entry.url.lastPathComponent
    }

    /// Folder enumeration occurs only when explicitly requested in the clear dialog.
    package static func preview(scanning folders: [URL] = [], protected: Set<URL> = [],
                                sources: [URL] = [], projects: [URL] = []) -> [SidecarCacheEntry] {
        var known = [String: SidecarCatalogEntry]()
        for entry in SidecarLocations.knownEntries() {
            known[identifier(entry)] = entry
        }
        let forbidden = Set(protected.union(sources).union(projects).map(AnalysisSidecar.canonicalSource))
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
                guard url.pathExtension == "cutdb", (try? CacheFileSnapshot(url)) != nil else { continue }
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
        for record in SidecarLocations.managedEntries(scanning: managedFolders, sources: sources, sourceForCache: { url in
            guard !pathIsProtected(url, protected: forbidden) else { return nil }
            return managedSource(at: url)
        }) where known[identifier(record)] == nil {
            known[identifier(record)] = record
        }
        let explicitRoots = folders.map { AnalysisSidecar.canonicalSource($0).pathComponents }
        var entries: [SidecarCacheEntry] = []
        for (key, record) in known {
            // A read-only session can already know a cache when its folder is explicitly scanned.
            // Only a validated entry under a selected folder becomes a durable registration.
            let components = explicitRoots.isEmpty ? [] : AnalysisSidecar.canonicalSource(record.url).pathComponents
            let register = explicitRoots.contains { components.starts(with: $0) }
            let entry = inspect(record, protected: forbidden, register: register)
            if scanned.contains(key) && entry.snapshot == nil { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.url.path < $1.url.path }
    }

    package static func clear(_ entries: [SidecarCacheEntry], wholeSidecars: Bool = false,
                              protected: Set<URL> = []) -> SidecarClearResult {
        let forbidden = Set(protected.union(entries.map(\.source)).map(AnalysisSidecar.canonicalSource))
        var result = SidecarClearResult()
        var visited = Set<String>()
        for entry in entries where visited.insert(entry.id).inserted {
            do {
                if let issue = entry.issue { throw sidecarError(issue) }
                let recovered = try clearEntry(entry, whole: wholeSidecars, protected: forbidden)
                result.reclaimedBytes += recovered
                result.cleared.append(entry.url)
            } catch {
                result.skippedEntries.append(SidecarSkippedCache(id: entry.id, url: entry.url,
                                                               rootIdentity: entry.rootIdentity,
                                                               reason: entry.issue ?? error.localizedDescription))
            }
        }
        return result
    }

    private static func inspect(_ record: SidecarCatalogEntry, protected: Set<URL>, register: Bool) -> SidecarCacheEntry {
        do {
            let snapshot = try checkPath(record, protected: protected)
            let db = try SidecarDatabase(record.url, writing: false)
            // Managed locations were introduced with format 5 and never held an older file.
            if record.mode == .media, AnalysisSidecar.supersededVersion(of: db) != nil {
                return try inspectOlderFormat(record, db: db, snapshot: snapshot)
            }
            try AnalysisSidecar.validate(db, at: record.url)
            try db.execute("BEGIN")
            try checkOwner(record, db: db)
            let plan = try clearPlan(db)
            guard try CacheFileSnapshot(record.url) == snapshot else {
                throw sidecarError("The cache changed while reading its inventory.")
            }
            let issue = try hasLiveClaim(db) ? "An active scene scan is using this cache." : nil
            if register { try SidecarLocations.registerDiscovered(record, in: db) }
            return SidecarCacheEntry(bytes: snapshot.allocated, rebuildableBytes: min(snapshot.allocated, plan.bytes),
                                     retained: plan.retained.sorted(), issue: issue, olderFormat: false,
                                     record: record, snapshot: snapshot)
        } catch {
            return SidecarCacheEntry(bytes: 0, rebuildableBytes: 0, retained: [], issue: error.localizedDescription,
                                     olderFormat: false, record: record, snapshot: nil)
        }
    }

    /// The whole file is dead weight except for the settings a save would carry into a
    /// current sidecar. Report its real size, so that the dialog offers to reclaim it.
    private static func inspectOlderFormat(_ record: SidecarCatalogEntry, db: SidecarDatabase,
                                           snapshot: CacheFileSnapshot) throws -> SidecarCacheEntry {
        try db.execute("BEGIN")
        try checkOwner(record, db: db)
        let kept = try AnalysisSidecar(source: record.source).legacySections(in: db, cancelled: { false })
        guard try CacheFileSnapshot(record.url) == snapshot else {
            throw sidecarError("The cache changed while reading its inventory.")
        }
        var retained: [String] = []
        if kept[AnalysisSidecar.viewNameSectionKey] != nil { retained.append("Scene names and their reports") }
        if kept[AnalysisSidecar.silenceThresholdOverridesKey] != nil { retained.append("Manual silence thresholds") }
        // Unnamed scene boundaries can be detected again, as in a current sidecar.
        let keptBytes = retained.isEmpty ? 0 : kept.values.reduce(Int64.zero) { $0 + Int64($1.count) }
        return SidecarCacheEntry(bytes: snapshot.allocated, rebuildableBytes: max(0, snapshot.allocated - keptBytes),
                                 retained: retained.sorted(), issue: nil, olderFormat: true, record: record, snapshot: snapshot)
    }

    /// The source path is a display hint. The independently validated owning directory
    /// and lookup key decide whether a managed cache is eligible for cleanup.
    private static func managedSource(at url: URL) -> URL? {
        do {
            guard try AnalysisSidecar.exists(url, sourceIdentity: nil) else { return nil }
            let db = try SidecarDatabase(url, writing: false)
            try AnalysisSidecar.validate(db, at: url)
            guard db.hasChangeTimes else { return nil }
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
        guard SidecarLocations.validate(record) else {
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
        if db.headerVersions()?.userVersion ?? 0 < 5 {
            guard entry.mode == .media else { throw sidecarError("This managed cache has no source lookup identity.") }
            return
        }
        let key = try db.statement("SELECT lookup_key FROM sidecar_location WHERE id = 1") { query -> String? in
            guard sqlite3_step(query) == SQLITE_ROW else { throw sidecarError("The cache location metadata is missing.") }
            return sqlite3_column_text(query, 0).map { String(cString: $0) }
        }
        guard key == entry.lookupKey else { throw sidecarError("The cache belongs to a different location.") }
    }

    private static func hasLiveClaim(_ db: SidecarDatabase) throws -> Bool {
        try db.statement("SELECT 1 FROM scene_attempts WHERE state = 0 AND owner IS NOT NULL AND expires > ? LIMIT 1",
                         [String(Date().timeIntervalSince1970)]) { query in
            switch sqlite3_step(query) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw db.error()
            }
        }
    }

    private struct ClearPlan {
        var keys: [String] = []
        var bytes: Int64 = 0
        var removeCompletedScenes = false
        var retained: Set<String> = []
    }

    private static func clearPlan(_ db: SidecarDatabase) throws -> ClearPlan {
        var plan = ClearPlan()
        let hasNames = try db.integer("SELECT EXISTS(SELECT 1 FROM sections WHERE name = 'scenes_view_names.v1')") != 0
        let keepScenes = try hasNames || db.integer("""
            SELECT EXISTS(SELECT 1 FROM scene_attempts WHERE state = 0)
                OR EXISTS(SELECT 1 FROM archived_sections WHERE name IN ('scenes_view_names.v1','scenes_boundaries.v1'))
                OR EXISTS(SELECT 1 FROM scene_reports WHERE generation != (SELECT max(id) FROM source_generations))
            """) != 0
        if keepScenes {
            if try db.integer("SELECT EXISTS(SELECT 1 FROM scene_attempts WHERE checkpoint IS NOT NULL)") != 0 {
                plan.retained.insert("Scene checkpoints and marker batches")
            }
        } else {
            plan.removeCompletedScenes = try db.integer("SELECT EXISTS(SELECT 1 FROM scene_attempts WHERE state = 1)") != 0
            if plan.removeCompletedScenes {
                plan.bytes += try db.statement("""
                    SELECT coalesce((SELECT sum(length(checkpoint)) FROM scene_attempts WHERE state = 1), 0)
                         + coalesce((SELECT sum(length(value)) FROM scene_markers
                               WHERE attempt IN (SELECT id FROM scene_attempts WHERE state = 1)), 0)
                    """) { query in
                    guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
                    return sqlite3_column_int64(query, 0)
                }
            }
        }
        if try db.integer("SELECT EXISTS(SELECT 1 FROM archived_sections)") != 0 {
            plan.retained.insert("Archived analysis and edits")
        }
        try db.statement("SELECT name, length(value) FROM sections") { query in
            var step = sqlite3_step(query)
            while step == SQLITE_ROW {
                guard let name = sqlite3_column_text(query, 0) else { throw db.error() }
                let key = String(cString: name)
                if removable(key, preserveScenes: keepScenes) {
                    plan.keys.append(key)
                    plan.bytes += sqlite3_column_int64(query, 1)
                } else if key == AnalysisSidecar.viewNameSectionKey {
                    plan.retained.insert("Scene names and their reports")
                } else if key == AnalysisSidecar.silenceThresholdOverridesKey {
                    plan.retained.insert("Manual silence thresholds")
                } else if key.hasPrefix("transcript_") {
                    plan.retained.insert("Transcript results and activity")
                } else if key != AnalysisSidecar.evidenceKey && key != AnalysisSidecar.sceneClockKey
                            && key != AnalysisSidecar.sceneSectionKey {
                    plan.retained.insert("Other saved analysis")
                }
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw db.error() }
        }
        return plan
    }

    private static func removable(_ key: String, preserveScenes: Bool) -> Bool {
        if AnalysisSidecar.indexKeys.contains(key) || AnalysisSidecar.savedEnvelopeStream(forKey: key) != nil
            || AnalysisSidecar.savedWaveformStream(forKey: key) != nil
            || AnalysisSidecar.savedSilenceSettings(forKey: key) != nil { return true }
        if key == AnalysisSidecar.sceneClockKey || key == AnalysisSidecar.sceneSectionKey { return !preserveScenes }
        let auto = "silence_automatic_threshold_db.v1."
        if key.hasPrefix(auto), let stream = Int(key.dropFirst(auto.count)), stream >= 0, key == auto + String(stream) {
            return true
        }
        let filmstrip = AnalysisSidecar.filmstripSectionPrefix
        if key.hasPrefix(filmstrip) {
            let parts = key.dropFirst(filmstrip.count).split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 3 && parts.allSatisfy { UInt64($0, radix: 16) != nil }
        }
        return false
    }

    /// Reject a custom trigger that would mutate retained rows while deleting a rebuildable section.
    /// SQLite authorizes the compiled statement and its triggers before it changes any rows.
    private static func delete(_ plan: ClearPlan, from db: SidecarDatabase) throws {
        let handle = db.handle
        let authorize = sqlite3_set_authorizer(handle, { _, action, name, _, _, trigger in
            switch action {
            case SQLITE_READ, SQLITE_SELECT: return SQLITE_OK
            case SQLITE_FUNCTION: return trigger == nil ? SQLITE_OK : SQLITE_DENY
            case SQLITE_DELETE:
                guard let name else { return SQLITE_DENY }
                if trigger == nil {
                    let allowed = ["sections", "scene_reports", "scene_markers", "scene_attempts", "sidecar_changes"]
                    return allowed.contains(String(cString: name)) ? SQLITE_OK : SQLITE_DENY
                }
                if let trigger, strcmp(trigger, "sidecar_delete_change") == 0,
                   strcmp(name, "sidecar_changes") == 0 || strcmp(name, "sidecar_field_changes") == 0 { return SQLITE_OK }
                return SQLITE_DENY
            default: return SQLITE_DENY
            }
        }, nil)
        guard authorize == SQLITE_OK else { throw db.error() }
        defer { sqlite3_set_authorizer(handle, nil, nil) }
        try db.statement("DELETE FROM sections WHERE name = ?", []) { query in
            for key in plan.keys {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(query, 1, key, -1, transient) == SQLITE_OK,
                      sqlite3_step(query) == SQLITE_DONE, sqlite3_reset(query) == SQLITE_OK else { throw db.error() }
            }
        }
        if plan.removeCompletedScenes {
            try db.execute("""
                DELETE FROM scene_reports WHERE attempt IN (SELECT id FROM scene_attempts WHERE state = 1);
                DELETE FROM scene_markers WHERE attempt IN (SELECT id FROM scene_attempts WHERE state = 1);
                DELETE FROM scene_attempts WHERE state = 1;
                """)
            if db.hasChangeTimes {
                try db.execute("DELETE FROM sidecar_changes WHERE substr(name, 1, 20) = 'scene_completion.v1.'")
            }
        }
    }

    /// Clearing analysis promises to keep what the user set by hand. Saving nothing through
    /// the ordinary write path stages a current sidecar holding those settings and swaps it
    /// in under that path's own locks, which this function must therefore not hold.
    private static func replaceOlderFormat(_ entry: SidecarCacheEntry, original: CacheFileSnapshot) throws -> Int64 {
        do {
            let db = try SidecarDatabase(entry.url, writing: false)
            guard AnalysisSidecar.supersededVersion(of: db) != nil else {
                throw sidecarError("The cache changed since the preview.")
            }
            try db.execute("BEGIN")
            try checkOwner(entry.record, db: db)
        }
        // A store captures the epoch when it is created. Advance it first, so that only
        // this replacement, and no save already under way, can write the new file.
        try SidecarClearEpoch.capture(sidecar: entry.url).advance()
        let store = try AnalysisSidecar(source: entry.source).pinned(to: entry.url)
        try store.transact(cancelled: { false }) { _, _ in }
        let remaining = try? CacheFileSnapshot(entry.url)
        return max(0, original.allocated - (remaining?.allocated ?? original.allocated))
    }

    private static func clearEntry(_ entry: SidecarCacheEntry, whole: Bool, protected: Set<URL>) throws -> Int64 {
        guard let original = entry.snapshot, try checkPath(entry.record, protected: protected) == original else {
            throw sidecarError("The cache changed since the preview. Refresh the list before clearing it.")
        }
        if entry.olderFormat && !whole && !entry.retained.isEmpty {
            return try replaceOlderFormat(entry, original: original)
        }
        let parent = entry.url.deletingLastPathComponent()
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw sidecarError(String(cString: strerror(errno))) }
        defer { close(directory) }
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw sidecarError("The cache is in use.") }
        defer { flock(directory, LOCK_UN) }
        let db = try SidecarDatabase(entry.url, writing: true)
        if entry.olderFormat {
            guard AnalysisSidecar.supersededVersion(of: db) != nil else {
                throw sidecarError("The cache changed since the preview.")
            }
        } else {
            try AnalysisSidecar.validate(db, at: entry.url)
        }
        try db.execute("PRAGMA busy_timeout = 0")
        try db.execute("BEGIN EXCLUSIVE")
        try checkOwner(entry.record, db: db)
        // Format 1 has no scene leases, and no running build still honours those of format 2.
        guard try entry.olderFormat || !hasLiveClaim(db) else { throw sidecarError("An active scene scan is using this cache.") }
        guard try checkPath(entry.record, protected: protected) == original else {
            throw sidecarError("The cache changed since the preview.")
        }
        let epoch = SidecarClearEpoch.capture(sidecar: entry.url)
        // An older format has no section this build could keep in place. With nothing
        // to carry into a current sidecar, clearing its analysis leaves nothing behind.
        if whole || entry.olderFormat {
            // No SQLite writes in this transaction. Retain the SQLite and publication locks through unlink.
            try epoch.advance()
            guard try checkPath(entry.record, protected: protected) == original else {
                throw sidecarError("The cache changed during removal.")
            }
            try checkOwner(entry.record, db: db)
            guard unlinkat(directory, entry.url.lastPathComponent, 0) == 0 else {
                throw sidecarError(String(cString: strerror(errno)))
            }
            SidecarLocations.forgetEntry(entry.record)
            return original.allocated
        }
        let plan = try clearPlan(db)
        guard !plan.keys.isEmpty || plan.removeCompletedScenes else { return 0 }
        try delete(plan, from: db)
        try epoch.advance()
        try checkOwner(entry.record, db: db)
        try db.execute("COMMIT")
        if (try? db.integer("PRAGMA freelist_count")) ?? 0 > 0 {
            try? db.execute("VACUUM")
        }
        let remaining = try? CacheFileSnapshot(entry.url)
        return max(0, original.allocated - (remaining?.allocated ?? original.allocated))
    }
}
