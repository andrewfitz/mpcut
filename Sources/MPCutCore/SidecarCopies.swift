import Darwin
import Foundation
import SQLite3

extension AnalysisSidecar {
    struct CopySnapshot {
        let store: AnalysisSidecar
        let db: SidecarDatabase
        let stamp: String
        let current: Bool
        let change: ChangeTime
    }

    /// A legacy mtime can break ties between undated legacy values, but touching
    /// an old database must never supersede a later, explicitly recorded edit.
    struct ChangeTime: Comparable {
        let recorded: Bool
        let time: Double

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.recorded != rhs.recorded { return rhs.recorded }
            return lhs.time < rhs.time
        }
    }

    private func modified(_ url: URL) -> Double {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    func recordChange(_ name: String, in db: SidecarDatabase) throws {
        try db.update("INSERT OR REPLACE INTO sidecar_changes(name, changed) VALUES(?, ?)",
                      [name, String(Date().timeIntervalSince1970)])
    }

    func changeTime(_ key: String?, in db: SidecarDatabase, at path: URL) throws -> ChangeTime {
        guard db.hasChangeTimes else { return ChangeTime(recorded: false, time: modified(path)) }
        // Imported legacy values encode their mtime as a negative number.
        // Recorded edits win. Among inherited values, the most negative is newest.
        let sql = key == nil ? """
            SELECT coalesce((SELECT max(changed) FROM sidecar_changes WHERE changed > 0),
                            (SELECT min(changed) FROM sidecar_changes))
            """ : "SELECT changed FROM sidecar_changes WHERE name = ?"
        if let changed = try db.statement(sql, key.map { [$0] } ?? [], { q -> Double? in
            sqlite3_step(q) == SQLITE_ROW && sqlite3_column_type(q, 0) != SQLITE_NULL ? sqlite3_column_double(q, 0) : nil
        }) {
            return ChangeTime(recorded: changed > 0, time: abs(changed))
        }
        return try db.statement("SELECT legacy_mtime FROM sidecar_location WHERE id = 1") { q in
            guard sqlite3_step(q) == SQLITE_ROW else { throw db.error() }
            return ChangeTime(recorded: false, time: sqlite3_column_double(q, 0))
        }
    }

    func prepareWriteLocation() throws -> URL {
        try locations.checkWriteConfiguration()
        if let physicalURL {
            if locations.destination == physicalURL { return try locations.prepareDestination() }
            guard locations.candidates.contains(physicalURL), try exists() else {
                throw sidecarError("The original cache location is unavailable.")
            }
            return physicalURL
        }
        let prepared = try locations.prepareDestination()
        guard capturedDestination == prepared else { throw sidecarError("The selected storage location changed during this operation.") }
        return prepared
    }

    func checkLocation(in db: SidecarDatabase) throws {
        try Self.checkLocation(url, in: db, locations: locations)
    }

    static func checkLocation(_ url: URL, in db: SidecarDatabase, locations: SidecarLocations) throws {
        if locations.isAdjacent(url) { return }
        guard let expected = locations.lookupKey(for: url) else {
            if locations.candidateEntries.contains(where: { $0.url == url && $0.mode == .media }) { return }
            throw sidecarError("The managed cache directory is unavailable.")
        }
        guard db.hasChangeTimes, try db.statement("SELECT lookup_key FROM sidecar_location WHERE id = 1", [], { q in
            sqlite3_step(q) == SQLITE_ROW && sqlite3_column_text(q, 0).map(String.init(cString:)) == expected
        }) else { throw sidecarError("The cache entry belongs to another recording.") }
    }

    func configureFreshness(in db: SidecarDatabase, isNew: Bool, file: URL) throws {
        if !db.hasChangeTimes {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS sidecar_changes(name TEXT PRIMARY KEY, changed REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS sidecar_field_changes(name TEXT NOT NULL, field TEXT NOT NULL, changed REAL NOT NULL, PRIMARY KEY(name,field));
                CREATE INDEX IF NOT EXISTS sidecar_change_time ON sidecar_changes(changed);
                CREATE TABLE IF NOT EXISTS sidecar_location(id INTEGER PRIMARY KEY CHECK(id = 1), lookup_key TEXT, source_path TEXT, legacy_mtime REAL NOT NULL);
                CREATE TRIGGER IF NOT EXISTS sidecar_delete_change AFTER DELETE ON sections BEGIN
                    DELETE FROM sidecar_changes WHERE name = OLD.name;
                    DELETE FROM sidecar_field_changes WHERE name = OLD.name;
                END;
                """)
            try db.update("INSERT OR IGNORE INTO sidecar_location(id, legacy_mtime) VALUES(1, ?)",
                          [String(isNew ? 0 : modified(file))])
            try db.execute("PRAGMA user_version = \(AnalysisSidecar.schemaVersion)")
            db.hasChangeTimes = true
        }
        if try db.integer("SELECT count(*) FROM pragma_table_info('sidecar_location') WHERE name = 'source_path'") == 0 {
            try db.execute("ALTER TABLE sidecar_location ADD COLUMN source_path TEXT")
        }
        if !locations.isAdjacent(url) {
            let sourcePath = Self.canonicalSource(source).path
            try db.update("UPDATE sidecar_location SET source_path = ? WHERE id = 1 AND source_path IS NOT ?",
                          [sourcePath, sourcePath])
        } else if file != url {
            try db.execute("UPDATE sidecar_location SET source_path = NULL WHERE id = 1")
        }
        if file != url {
            // A private staged seed inherits the previous location's metadata.
            if let key = locations.lookupKey(for: url) { try db.update("UPDATE sidecar_location SET lookup_key = ? WHERE id = 1", [key]) }
            else { try db.execute("UPDATE sidecar_location SET lookup_key = NULL WHERE id = 1") }
        }
        try checkLocation(in: db)
    }

    private struct DatabaseIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    func readSnapshots(orderedBy key: String? = nil, includeStale: Bool = false,
                       unresolvedEvidence: (([URL]) -> Void)? = nil, inspectionFailure: ((Error) -> Void)? = nil) -> [CopySnapshot] {
        guard !isExcluded else { return [] }
        let paths = physicalURL.map { [$0] } ?? locations.candidates
        var copies: [CopySnapshot] = []
        var seen: Set<DatabaseIdentity> = []
        for path in paths {
            guard let fileID = DatabaseIdentity(path) else {
                if errno != ENOENT && errno != ENOTDIR { inspectionFailure?(sidecarError(String(cString: strerror(errno)))) }
                continue
            }
            guard seen.insert(fileID).inserted else { continue }
            let store = pinned(to: path)
            do {
                guard try store.exists() else { continue }
                let db = try SidecarDatabase(path, writing: false)
                try db.execute("BEGIN")
                try store.validate(db)
                let stamp = try store.storedStamp(db)
                let current = try store.currentStamp(db) != nil
                guard current || includeStale else { continue }
                var change = try changeTime(key, in: db, at: path)
                if key == "media_index.v1" {
                    for member in ["media_index_audio.v1", "media_index_frames.v1"] {
                        change = max(change, try changeTime(member, in: db, at: path))
                    }
                }
                if current { locations.observeValidated(path, device: fileID.device, inode: fileID.inode) }
                copies.append(CopySnapshot(store: store, db: db, stamp: stamp, current: current, change: change))
            } catch {
                if let inspectionFailure {
                    // An unsupported format, or a file too small to have a
                    // SQLite header, cannot contain a lease from this app.
                    var info = stat()
                    if (error as? CutError)?.code != "unsupported_sidecar",
                       !(lstat(path.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size < 100) {
                        inspectionFailure(error)
                    }
                }
            }
        }
        if copies.count > 1 { filterDivergentGenerations(&copies, unresolvedEvidence: unresolvedEvidence) }
        return copies.sorted { a, b in
            if a.current != b.current { return a.current }
            if a.change != b.change { return a.change > b.change }
            if a.store.url == locations.destination { return b.store.url != locations.destination }
            if b.store.url == locations.destination { return false }
            return a.store.url.path < b.store.url.path
        }
    }

    func readCandidates(orderedBy key: String?) -> [AnalysisSidecar] {
        readSnapshots(orderedBy: key).map(\.store)
    }

    /// A refresh can certify new content even after the original mtime has
    /// been restored. Generation numbers are local to each physical database.
    private func filterDivergentGenerations(_ copies: inout [CopySnapshot], unresolvedEvidence: (([URL]) -> Void)?) {
        let current = copies.filter(\.current)
        guard current.count >= 2 else { return }
        // Identical checksum + seed means identical evidence. Most replicas
        // share the same evidence and need no decompression during discovery.
        func digest(_ copy: CopySnapshot) -> Data? {
            try? copy.db.statement("SELECT digest FROM sections WHERE name = ?", [Self.evidenceKey]) { q in
                guard sqlite3_step(q) == SQLITE_ROW, sqlite3_column_bytes(q, 0) == 32,
                      let bytes = sqlite3_column_blob(q, 0) else { return nil }
                return Data(bytes: bytes, count: 32)
            }
        }
        let referenceDigest = digest(current[0])
        guard current.dropFirst().contains(where: { $0.stamp != current[0].stamp || digest($0) != referenceDigest }) else { return }
        var evidence: [URL: MediaRefreshEvidence] = [:]
        var refreshed: (value: MediaRefreshEvidence, change: ChangeTime)?
        for copy in current {
            guard let bytes = try? verifiedSection(Self.evidenceKey, in: copy.db, stamp: copy.stamp,
                                                   maxBytes: 16 * 1024 * 1024, cancelled: { Task.isCancelled }),
                  let value = MediaRefreshEvidence.decode(bytes) else { continue }
            evidence[copy.store.url] = value
            let explicitlyRefreshed = (try? copy.db.integer("SELECT EXISTS(SELECT 1 FROM source_generations WHERE reason = 'content_changed')")) == 1
            guard explicitlyRefreshed, let change = try? changeTime(Self.evidenceKey, in: copy.db, at: copy.store.url) else { continue }
            if refreshed.map({ change > $0.change }) ?? true { refreshed = (value, change) }
        }
        let complete = evidence.values.filter(\.hasCompleteProof)
        let conflicting = complete.first.map { first in complete.contains { !$0.hasSameObservedInputs(as: first) } } ?? false
        // A metadata-only legacy sidecar may legitimately have no full index.
        // Require positive proof only when a refresh or divergent streams show
        // that equality of source stamps alone is insufficient.
        guard conflicting || refreshed != nil else { return }
        let verified = sourceEvidence.flatMap { $0.hasCompleteProof ? $0 : nil } ?? refreshed?.value
        copies.removeAll { copy in
            guard copy.current else { return false }
            guard let verified, let observed = evidence[copy.store.url] else { return true }
            return !observed.hasSameObservedInputs(as: verified)
        }
        if let unresolvedEvidence, !copies.contains(where: \.current) {
            unresolvedEvidence(current.map { $0.store.url })
        }
    }

    /// Copy SQLite pages from a single committed snapshot into a private staging
    /// file. A running or released scene lease continues to belong to its origin.
    func seed(_ staging: URL, allowStale: Bool, cancelled: () -> Bool) throws -> Bool {
        guard physicalURL == nil,
              let copy = readSnapshots(includeStale: allowStale).first(where: { $0.store.url != url }) else { return false }
        let target = try SidecarDatabase(staging, writing: true)
        guard let backup = sqlite3_backup_init(target.handle, "main", copy.db.handle, "main") else { throw target.error() }
        let status: Int32
        do {
            var result: Int32
            repeat {
                try checkSidecarCancellation(cancelled)
                result = sqlite3_backup_step(backup, 128)
            } while result == SQLITE_OK
            status = result
        } catch {
            sqlite3_backup_finish(backup)
            throw error
        }
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw target.error() }
        try target.execute("""
            BEGIN IMMEDIATE;
            DELETE FROM scene_markers WHERE attempt IN (SELECT id FROM scene_attempts WHERE state = 0);
            DELETE FROM scene_reports WHERE attempt IN (SELECT id FROM scene_attempts WHERE state = 0);
            DELETE FROM scene_attempts WHERE state = 0;
            COMMIT;
            """)
        if copy.db.hasChangeTimes {
            try target.execute("DELETE FROM sidecar_changes WHERE name GLOB 'scene_progress.v1.*'")
        } else {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified(copy.store.url))],
                                                  ofItemAtPath: staging.path)
        }
        return true
    }

    // When an inspection agrees with every local group, remember the exact pair of
    // snapshots without writing a bookkeeping row that changes the destination cookie.
    private static let comparedSnapshots: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 256
        return cache
    }()

    /// Under the destination writer lock, import newer or absent values from
    /// other committed snapshots. Each source group is copied before commit.
    func reconcile(in db: SidecarDatabase, validatingSeed: Bool, cancelled: () -> Bool) throws {
        guard physicalURL == nil, try currentStamp(db) != nil else { return }
        let destinationIdentity = DatabaseIdentity(url)
        let alternatives = locations.candidates.filter { candidate in
            guard candidate != url, let other = DatabaseIdentity(candidate) else { return false }
            return other != destinationIdentity
        }
        guard !alternatives.isEmpty else { return }
        let snapshots = readSnapshots()
        let peers = snapshots.filter { DatabaseIdentity($0.store.url) != destinationIdentity }
        var saved = try storedStamp(db)
        if !snapshots.contains(where: { DatabaseIdentity($0.store.url) == destinationIdentity }), let peer = peers.first,
           let evidence = try verifiedSection(Self.evidenceKey, in: peer.db, stamp: peer.stamp,
                                              maxBytes: 16 * 1024 * 1024, cancelled: cancelled) {
            // This destination was excluded after a confirmed same-stamp
            // replacement. Invalidate its rows before importing the new source.
            let previous = try verifiedSection(Self.evidenceKey, in: db, stamp: saved,
                                               maxBytes: 16 * 1024 * 1024, cancelled: cancelled)
            if let previous, previous != evidence {
                let refresh = SidecarGenerationRefresh(evidence: evidence, expectedEvidence: previous,
                    preserving: [], force: true, preservingScenes: false, preservingThresholdStreams: [])
                saved = try updateGeneration(db, stamp: saved, refresh: refresh, cancelled: cancelled)
            }
        }
        guard !peers.isEmpty else { return }
        var hasImports = try db.integer("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'sidecar_imports')") != 0
        let targetGeneration = try generation(db)
        let localCookie = try db.replicaCookie(generation: targetGeneration)
        // A page backup also preserves damaged payloads and their newer timestamps.
        // Validate competing groups in a private seed once. A verified older
        // copy can repair them even if the donor previously imported that peer.
        lazy var evidence: MediaRefreshEvidence? = {
            if let sourceEvidence { return sourceEvidence }
            let bytes = try? verifiedSection(Self.evidenceKey, in: db, stamp: saved, maxBytes: 16 * 1024 * 1024, cancelled: cancelled)
            guard let stored = MediaRefreshEvidence.decode(bytes), identity.matches(saved: stored.identity) else { return nil }
            return stored
        }()
        var damaged: Set<String> = []
        var seedHasRecognition = false
        if validatingSeed && peers.count > 1 {
            let keys = Set(try Self.sectionNames(in: db))
            if !keys.isDisjoint(with: Self.indexKeys), try verifiedIndex(in: db, stamp: saved, cancelled: cancelled) == nil {
                damaged.formUnion(Self.indexKeys)
            }
            for key in keys.subtracting(Self.indexKeys) {
                try checkSidecarCancellation(cancelled)
                if TranscriptRecognitionCache.stream(forKey: key) != nil { seedHasRecognition = true }
                guard let bytes = try verifiedSection(key, in: db, stamp: saved, maxBytes: nil, cancelled: cancelled),
                      canImportAnalysis(key, bytes: bytes, replacing: nil, evidence: evidence, cancelled: cancelled) else {
                    damaged.insert(key)
                    continue
                }
            }
        }
        let repairingSeed = seedHasRecognition || !damaged.isEmpty
        for peer in peers {
            try checkSidecarCancellation(cancelled)
            let cookie = try peer.db.replicaCookie(generation: targetGeneration)
            if !repairingSeed, hasImports, let cookie, try db.statement("SELECT 1 FROM sidecar_imports WHERE file = ? AND version = ?",
                [cookie.file, cookie.version], { sqlite3_step($0) == SQLITE_ROW }) { continue }
            var comparison: NSString?
            if !validatingSeed, sqlite3_total_changes64(db.handle) == 0, let localCookie, let cookie {
                comparison = "\(localCookie.file)|\(localCookie.version)|\(cookie.file)|\(cookie.version)" as NSString
                if let comparison, Self.comparedSnapshots.object(forKey: comparison) != nil { continue }
            }
            let keys = try Self.sectionNames(in: peer.db)
            let indexKeys = Self.indexKeys
            if indexKeys.isSubset(of: keys),
               try !damaged.isDisjoint(with: indexKeys) || shouldImport("media_index.v1", from: peer, into: db)
                   || !indexKeys.isSubset(of: try Self.sectionNames(in: db)),
               let index = try verifiedIndex(in: peer.db, stamp: peer.stamp, cancelled: cancelled) {
                for (key, value) in index {
                    try copyVerifiedSection(key, value: value, from: peer, into: db, stamp: saved, cancelled: cancelled)
                }
                damaged.subtract(indexKeys)
            }
            let target = CopySnapshot(store: self, db: db, stamp: saved, current: true, change: peer.change)
            try TranscriptRecognitionCache.merge(from: peer, into: target, peerKeys: keys, cancelled: cancelled)
            let targetHasNames = try db.statement("SELECT 1 FROM sections WHERE name = ?", [Self.viewNameSectionKey]) { sqlite3_step($0) == SQLITE_ROW }
            // Keep locally authored names together with the boundary map that
            // defines their view numbers when two independent scans disagree.
            let incompatibleNames = targetHasNames && !damaged.contains(Self.sceneSectionKey) && !namesCompatible(target, peer)
            for key in keys where !indexKeys.contains(key) && TranscriptRecognitionCache.stream(forKey: key) == nil {
                if incompatibleNames && (key == Self.sceneSectionKey || key == Self.viewNameSectionKey) { continue }
                try checkSidecarCancellation(cancelled)
                if Self.isEditableSection(key), try mergeFields(key, from: peer, into: db, stamp: saved, cancelled: cancelled) {
                    if damaged.contains(key), try verifiedSection(key, in: db, stamp: saved, maxBytes: nil, cancelled: cancelled) != nil {
                        damaged.remove(key)
                    }
                    continue
                }
                if Self.savedEnvelopeStream(forKey: key) != nil,
                   let theirs = try verifiedSection(key, in: peer.db, stamp: peer.stamp, maxBytes: nil, cancelled: cancelled),
                   let ours = try verifiedSection(key, in: db, stamp: saved, maxBytes: nil, cancelled: cancelled) {
                    if Self.preferredEnvelope(ours, theirs) == ours { continue }
                } else if try !damaged.contains(key) && !shouldImport(key, from: peer, into: db) { continue }
                if try importSection(key, from: peer, into: db, stamp: saved, evidence: evidence, cancelled: cancelled) { damaged.remove(key) }
            }
            try mergeCompletedSceneAttempts(from: peer, into: db, cancelled: cancelled)
            if sqlite3_total_changes64(db.handle) > 0, let cookie {
                if !hasImports {
                    try db.execute("CREATE TABLE sidecar_imports(file TEXT PRIMARY KEY, version TEXT NOT NULL)")
                    hasImports = true
                }
                try db.update("INSERT OR REPLACE INTO sidecar_imports(file, version) VALUES(?, ?)", [cookie.file, cookie.version])
            } else if let comparison {
                Self.comparedSnapshots.setObject(1, forKey: comparison)
            }
        }
    }

    private func importSection(_ key: String, from peer: CopySnapshot, into db: SidecarDatabase,
                               stamp: String, evidence: @autoclosure () -> MediaRefreshEvidence?, cancelled: () -> Bool) throws -> Bool {
        guard let value = try verifiedSection(key, in: peer.db, stamp: peer.stamp, maxBytes: nil, cancelled: cancelled) else { return false }
        if key.hasPrefix("transcript_activity.v1."), let suffix = key.split(separator: ".").last,
           let existing = try verifiedSection(key, in: db, stamp: stamp, maxBytes: nil, cancelled: cancelled),
           existing != value, TranscriptStore.digest(existing) == suffix {
            // Recognition records address these bytes by digest. A newer row with
            // different bytes at that key would invalidate every result sharing it.
            return false
        }
        if key == Self.sceneSectionKey || key == Self.sceneClockKey || key.hasPrefix("silence_") || key.hasPrefix("waveform_") {
            let previous = try verifiedSection(key, in: db, stamp: stamp, maxBytes: nil, cancelled: cancelled)
            guard canImportAnalysis(key, bytes: value, replacing: previous, evidence: evidence(), cancelled: cancelled) else { return false }
        }
        try copyVerifiedSection(key, value: value, from: peer, into: db, stamp: stamp, cancelled: cancelled)
        return true
    }

    private func copyVerifiedSection(_ key: String, value: Data, from peer: CopySnapshot, into db: SidecarDatabase,
                                     stamp: String, cancelled: () -> Bool) throws {
        if peer.stamp == stamp && peer.db.hasCompactStorage {
            try peer.db.statement("SELECT digest, value, logical_size FROM sections WHERE name = ?", [key]) { src in
                guard sqlite3_step(src) == SQLITE_ROW else { throw peer.db.error() }
                try db.statement("INSERT OR REPLACE INTO sections(name, digest, value, logical_size) VALUES(?, ?, ?, ?)", [key]) { dst in
                    for column: Int32 in 0...2 {
                        guard sqlite3_bind_value(dst, column + 2, sqlite3_column_value(src, column)) == SQLITE_OK else { throw db.error() }
                    }
                    guard sqlite3_step(dst) == SQLITE_DONE else { throw db.error() }
                }
            }
        } else { try writeSection(key, value: value, db: db, stamp: stamp, cancelled: cancelled) }
        let original = try changeTime(key, in: peer.db, at: peer.store.url)
        try setChangeTime(original, key: key, in: db)
    }

    func setChangeTime(_ time: ChangeTime, key: String, in db: SidecarDatabase) throws {
        try db.update("INSERT OR REPLACE INTO sidecar_changes(name, changed) VALUES(?, ?)",
                      [key, String(time.recorded ? time.time : -time.time)])
    }

    private func shouldImport(_ key: String, from peer: CopySnapshot, into db: SidecarDatabase) throws -> Bool {
        guard try db.statement("SELECT 1 FROM sections WHERE name = ?", [key], { sqlite3_step($0) == SQLITE_ROW }) else { return true }
        let keys = key == "media_index.v1" ? [key, "media_index_frames.v1", "media_index_audio.v1"] : [key]
        let theirs = try keys.map { try changeTime($0, in: peer.db, at: peer.store.url) }.max()!
        let ours = try keys.map { try changeTime($0, in: db, at: url) }.max()!
        return theirs > ours
    }
}
