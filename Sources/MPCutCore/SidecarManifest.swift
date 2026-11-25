import Foundation
import SQLite3

struct SidecarGenerationRefresh {
    let evidence: Data
    let expectedEvidence: Data?
    let preserving: Set<String>
    let force: Bool
    let preservingScenes: Bool
}

extension AnalysisSidecar {
    static let evidenceKey = MediaRefreshEvidence.sectionKey
    private static let evidenceLimit = 16 * 1024 * 1024

    func createManifest(_ db: SidecarDatabase) throws {
        try db.execute("""
            CREATE TABLE source_generations(
                id INTEGER PRIMARY KEY, stamp TEXT NOT NULL, reason TEXT NOT NULL
            );
            INSERT INTO source_generations(id, stamp, reason) SELECT 1, stamp, 'initial' FROM source;
            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    func generation(_ db: SidecarDatabase) throws -> Int64 {
        try Self.generation(db)
    }

    static func generation(_ db: SidecarDatabase) throws -> Int64 {
        try db.statement("SELECT max(id) FROM source_generations") { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
            return sqlite3_column_int64(query, 0)
        }
    }

    // An explicit sidecar save can be the first write after an in-memory
    // refresh. Its rebuilt index must not certify old same-stamp analyses.
    func prepareIndexEvidence(_ incoming: Data?, in db: SidecarDatabase,
                              cancelled: () -> Bool) throws -> (refresh: SidecarGenerationRefresh?, evidence: Data?) {
        guard let incoming else { return (nil, nil) }
        guard incoming.count <= Self.evidenceLimit else { throw sidecarError("Media evidence exceeds the size limit.") }
        guard var evidence = MediaRefreshEvidence.decode(incoming) else { return (nil, incoming) }
        guard identity.matches(saved: evidence.identity) else {
            throw CutError(code: "source_changed", message: "The refreshed index belongs to another media generation.")
        }
        let stamp = try storedStamp(db)
        let previous = try verifiedSection(Self.evidenceKey, in: db, stamp: stamp, maxBytes: Self.evidenceLimit,
                                           cancelled: cancelled)
        guard incoming != previous else { return (nil, nil) }
        let previousEvidence = MediaRefreshEvidence.decode(previous)
        let explicitlyRefreshed = evidence.reviewStreams != nil || evidence.pictureNeedsReview != nil
        guard previousEvidence != nil || explicitlyRefreshed else { return (nil, incoming) }
        let current = try currentStamp(db) != nil
        let changed = previousEvidence.map { !evidence.hasSameObservedInputs(as: $0) } ?? true
        if current && !explicitlyRefreshed, let previousEvidence,
           (previousEvidence.hasCompleteProof && !evidence.hasCompleteProof ||
            (previousEvidence.reviewStreams != nil || previousEvidence.pictureNeedsReview == true) && !changed) {
            return (nil, nil)
        }
        let pictureAlreadyNeedsReview = previousEvidence?.pictureNeedsReview == true && evidence.pictureNeedsReview != true
        if pictureAlreadyNeedsReview { evidence.pictureNeedsReview = true }
        let confirmedChange = changed && (explicitlyRefreshed ||
            evidence.hasCompleteProof && previousEvidence?.hasCompleteProof == true)
        guard !current || confirmedChange else {
            return (nil, pictureAlreadyNeedsReview ? try evidence.encoded() : incoming)
        }
        var comparison = previousEvidence.map { evidence.compare(to: $0) } ?? MediaRefreshEvidence.Comparison()
        comparison.review.formUnion(previousEvidence?.reviewStreams ?? [])
        comparison.review.formUnion(evidence.reviewStreams ?? [])
        let keys = try sectionKeys(db)
        evidence.reviewStreams = comparison.review.sorted()
        evidence.pictureNeedsReview = comparison.pictureNeedsReview || evidence.pictureNeedsReview == true
        let encoded = try evidence.encoded()
        let refresh = SidecarGenerationRefresh(evidence: encoded, expectedEvidence: previous,
                                               preserving: comparison.preservedSectionKeys(keys),
                                               force: current && confirmedChange, preservingScenes: comparison.scenes)
        return (refresh, encoded)
    }

    func updateGeneration(_ db: SidecarDatabase, stamp: String, refresh: SidecarGenerationRefresh?,
                          cancelled: () -> Bool) throws -> String {
        let saved = try storedStamp(db)
        let current = try currentStamp(db) != nil
        if let refresh {
            let evidence = try verifiedSection(Self.evidenceKey, in: db, stamp: saved,
                                               maxBytes: Self.evidenceLimit, cancelled: cancelled)
            guard evidence == refresh.expectedEvidence || (current && evidence == refresh.evidence) else {
                throw CutError(code: "source_changed", message: "Another operation refreshed the analysis sidecar.")
            }
            if current, evidence == refresh.evidence { return saved }
        }
        guard !current || refresh?.force == true else { return saved }

        let previous = try generation(db)
        // A file from a build without this limit can hold a pause list for every setting
        // ever tried. Apply the limit before a copy of each goes into the archive.
        // The glob below covers both layouts of the name, `.v1.` and `.v2.`.
        try Self.pruneSilenceResults(in: db)
        try db.execute("DROP TABLE IF EXISTS temp.retained_sections; CREATE TEMP TABLE retained_sections(name TEXT PRIMARY KEY)")
        if let refresh {
            for key in refresh.preserving.sorted() where key != Self.evidenceKey {
                if let bytes = try verifiedSection(key, in: db, stamp: saved, maxBytes: nil, cancelled: cancelled) {
                    // Keep the stored representation and insertion order. Only the checksum
                    // depends on the source stamp, and a forced refresh can keep that too.
                    if saved != stamp {
                        let digest = try bytes.withUnsafeBytes { try checksum(key, stamp: stamp, $0, cancelled: cancelled) }
                        try db.updateBlobs("UPDATE sections SET digest = ? WHERE name = ?", [],
                                           blobs: [Data(digest)], trailing: [key])
                    }
                    try db.update("INSERT INTO retained_sections(name) VALUES(?)", [key])
                }
            }
        }
        // Archive inspectable reports at their original stamp. Preview and index
        // payloads can be rebuilt and are only kept when certified for reuse.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS archived_sections(
                generation INTEGER NOT NULL, name TEXT NOT NULL, digest BLOB NOT NULL, value BLOB NOT NULL,
                logical_size INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(generation, name)
            );
            """)
        try db.update("""
            INSERT INTO archived_sections(generation, name, digest, value, logical_size)
            SELECT ?, name, digest, value, logical_size FROM sections
            WHERE name NOT IN (SELECT name FROM retained_sections)
              AND (name IN (?, ?) OR name GLOB 'silence_pauses.*' OR name GLOB 'silence_automatic_threshold_db.*')
            """, [String(previous), Self.evidenceKey, Self.sceneSectionKey])
        try db.execute("DELETE FROM sections WHERE name NOT IN (SELECT name FROM retained_sections)")
        try db.update("UPDATE source SET stamp = ? WHERE id = 1", [stamp])
        try db.update("INSERT INTO source_generations(stamp, reason) VALUES(?, ?)",
                      [stamp, current ? "content_changed" : "identity_changed"])
        let next = try generation(db)
        let oldestRetainedGeneration = String(next - 3)
        try db.update("DELETE FROM archived_sections WHERE generation < ?", [oldestRetainedGeneration])
        if try db.hasSceneAttempts {
            if refresh?.preservingScenes == true {
                try db.update("""
                    INSERT INTO scene_reports(generation, scope, attempt)
                    SELECT ?, scope, attempt FROM scene_reports WHERE generation = ?
                    """, [String(next), String(previous)])
            }
            try db.update("DELETE FROM scene_reports WHERE generation < ?", [oldestRetainedGeneration])
            try db.update("UPDATE scene_attempts SET state = 2, owner = NULL WHERE generation < ? AND state = 0",
                          [String(next)])
            try pruneSceneHistory(db, generation: next)
        }
        return stamp
    }

    func matchesCurrentGeneration() -> Bool {
        currentGenerationEvidence().current
    }

    func currentGenerationEvidence() -> (current: Bool, evidence: Data?) {
        guard Self.readsEnabled, !isExcluded else { return (false, nil) }
        let copies = readSnapshots(orderedBy: Self.evidenceKey)
        guard !copies.isEmpty else { return (false, nil) }
        for copy in copies {
            guard let bytes = try? verifiedSection(Self.evidenceKey, in: copy.db, stamp: copy.stamp,
                                                   maxBytes: Self.evidenceLimit, cancelled: { Task.isCancelled }) else { continue }
            if copies.count > 1, MediaRefreshEvidence.decode(bytes) == nil { continue }
            guard (try? checkSource()) != nil else { return (false, nil) }
            return (true, bytes)
        }
        return ((try? checkSource()) != nil, nil)
    }

    public func previousGenerationSnapshot() -> (evidence: Data, keys: Set<String>)? {
        guard Self.readsEnabled, !isExcluded else { return nil }
        if physicalURL == nil {
            for copy in readSnapshots(orderedBy: Self.evidenceKey, includeStale: true) {
                if let snapshot = copy.store.previousGenerationSnapshot() { return snapshot }
            }
            return nil
        }
        do {
            guard try exists() else { return nil }
            try checkSource()
            let db = try SidecarDatabase(url, writing: false)
            try db.execute("BEGIN")
            try validate(db)
            let stamp = try storedStamp(db)
            guard let evidence = try verifiedSection(Self.evidenceKey, in: db, stamp: stamp,
                                                     maxBytes: Self.evidenceLimit, cancelled: { Task.isCancelled })
            else { return nil }
            let keys = try sectionKeys(db)
            try checkSource()
            return (evidence, keys)
        } catch { return nil }
    }

    private func sectionKeys(_ db: SidecarDatabase) throws -> Set<String> {
        try db.statement("SELECT name FROM sections") { query in
            var keys = Set<String>()
            var step = sqlite3_step(query)
            while step == SQLITE_ROW {
                if let key = sqlite3_column_text(query, 0) { keys.insert(String(cString: key)) }
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw db.error() }
            return keys
        }
    }

    public func refreshGeneration(evidence: Data, preserving: Set<String>, expectedEvidence: Data? = nil,
                                  force: Bool = false, preservingScenes: Bool = false,
                                  sections: [String: Data] = [:],
                                  cancelled: () -> Bool = { false }) throws {
        guard evidence.count <= Self.evidenceLimit else { throw sidecarError("Media evidence exceeds the size limit.") }
        let refresh = SidecarGenerationRefresh(evidence: evidence, expectedEvidence: expectedEvidence,
                                               preserving: preserving, force: force, preservingScenes: preservingScenes)
        var writes = sections
        writes[Self.evidenceKey] = evidence
        try transact(writes, cancelled: cancelled, refresh: refresh) { _, _ in }
    }

    public struct PersistedGeneration: Codable, Sendable {
        public let id: Int64
        public let reason: String
        public let current: Bool
    }

    public func persistedGenerations() -> [PersistedGeneration] {
        if physicalURL == nil { return readSnapshots(includeStale: true).first?.store.persistedGenerations() ?? [] }
        guard !isExcluded else { return [] }
        do {
            guard try exists() else { return [] }
            let db = try SidecarDatabase(url, writing: false)
            try db.execute("BEGIN")
            try validate(db)
            let current = try currentStamp(db) != nil && identity.isCurrentSnapshot(at: source)
            return try Self.persistedGenerations(in: db, current: current)
        } catch { return [] }
    }

    static func persistedGenerations(in db: SidecarDatabase, current: Bool) throws -> [PersistedGeneration] {
        return try db.statement("SELECT id, reason FROM source_generations ORDER BY id DESC") { query in
            var result: [PersistedGeneration] = []
            var step = sqlite3_step(query)
            while step == SQLITE_ROW {
                guard let reason = sqlite3_column_text(query, 1) else { throw db.error() }
                result.append(PersistedGeneration(id: sqlite3_column_int64(query, 0),
                                                  reason: String(cString: reason),
                                                  current: current && result.isEmpty))
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw db.error() }
            return result
        }
    }

    package struct InventorySnapshot {
        package let status: String
        package var locations: [URL] = []
        package var location: URL? { locations.first }
        package var sections: [String] = []
        package var hasCompleteIndex = false
        package var staleReason: String?
        package var generations: [PersistedGeneration] = []
        package var attempts: [PersistedSceneAttempt] = []
    }

    /// A refresh can archive keys and publish a new scene generation in one commit.
    /// Inspect all three inventories in that same SQLite snapshot.
    package static func inventorySnapshot(source: URL) -> InventorySnapshot {
        inventorySnapshot(source: source, store: try? AnalysisSidecar(source: source))
    }

    static func inventorySnapshot(source: URL, store: AnalysisSidecar?) -> InventorySnapshot {
        if let store {
            var unresolved: [URL] = []
            let copies = store.readSnapshots(includeStale: true) { unresolved = $0 }
            if !unresolved.isEmpty {
                return .init(status: "stale", locations: unresolved,
                             staleReason: "Cached stream evidence differs across sidecars. Refresh the source to verify its current contents.")
            }
            let previews = copies.map { snapshot(db: $0.db, location: $0.store.url, store: store, includeHistory: true) }
            if var result = previews.first(where: { $0.status == "current" }) {
                var names = Set(result.sections), seen = Set(result.attempts.map(\.id))
                for other in previews where other.status == "current" && other.location != result.location {
                    result.locations.append(contentsOf: other.locations)
                    names.formUnion(other.sections)
                    result.hasCompleteIndex = result.hasCompleteIndex || other.hasCompleteIndex
                    result.attempts += other.attempts.filter { seen.insert($0.id).inserted }
                }
                result.sections = names.sorted()
                return result
            }
            if let stale = previews.first(where: { $0.status == "stale" }) { return stale }
            if let failure = previews.first { return failure }
        }
        let paths = store?.locations.candidates ?? SidecarLocations(source: source).candidates
        var firstFailure: InventorySnapshot?
        for path in paths {
            let result = inspectInventory(source: source, url: path, store: store, includeHistory: true)
            if ["current", "stale", "offline", "excluded"].contains(result.status) { return result }
            if result.status != "missing" && firstFailure == nil { firstFailure = result }
        }
        return firstFailure ?? .init(status: "missing")
    }

    package func savedSectionInventory() -> InventorySnapshot {
        Self.inspectInventory(source: source, url: url, store: self, includeHistory: false)
    }

    private static func inspectInventory(source: URL, url: URL, store: AnalysisSidecar?, includeHistory: Bool) -> InventorySnapshot {
        guard source.isFileURL else { return .init(status: "unreadable") }
        let source = source.standardizedFileURL
        if isExcluded(source, in: excludedSources) { return .init(status: "excluded") }
        do {
            guard try exists(url, sourceIdentity: store?.identity) else { return .init(status: "missing") }
            let db = try SidecarDatabase(url, writing: false)
            try db.execute("BEGIN")
            try validate(db, at: url)
            try checkLocation(url, in: db, locations: store?.locations ?? SidecarLocations(source: source))
            return snapshot(db: db, location: url, store: store, includeHistory: includeHistory)
        } catch let error as CutError where error.code == "unsupported_sidecar" {
            return .init(status: "unsupported", locations: [url])
        } catch {
            return .init(status: "unreadable", locations: [url])
        }
    }

    private static func snapshot(db: SidecarDatabase, location: URL, store: AnalysisSidecar?, includeHistory: Bool) -> InventorySnapshot {
        do {
            let matching: Bool
            if let store {
                matching = try store.currentStamp(db) != nil
            } else {
                _ = try storedStamp(db)
                matching = false
            }
            let names = try matching && readsEnabled ? sectionNames(in: db) : []
            let current = matching && (store.map { $0.identity.isCurrentSnapshot(at: $0.source) } ?? false)
            let status = store == nil ? "offline" : (current ? "current" : "stale")
            var result = InventorySnapshot(status: status, locations: [location], sections: current ? names : [],
                                           hasCompleteIndex: current && indexKeys.isSubset(of: names))
            if includeHistory {
                result.generations = try persistedGenerations(in: db, current: current)
                result.attempts = try persistedSceneAttempts(in: db, current: current)
            }
            return result
        } catch let error as CutError where error.code == "unsupported_sidecar" {
            return .init(status: "unsupported")
        } catch {
            return .init(status: "unreadable")
        }
    }

    public static func offlineInventory(source: URL) -> (status: String, generations: [PersistedGeneration],
                                                         attempts: [PersistedSceneAttempt]) {
        let snapshot = inventorySnapshot(source: source)
        return (snapshot.status, snapshot.generations, snapshot.attempts)
    }

    public func readArchived(_ key: String, generation: Int64, maxBytes: Int? = nil,
                             cancelled: () -> Bool = { Task.isCancelled }) -> Data? {
        if physicalURL == nil {
            return readSnapshots(includeStale: true).first?.store.readArchived(key, generation: generation, maxBytes: maxBytes,
                                                                              cancelled: cancelled)
        }
        guard !isExcluded, Self.validKey(key), !cancelled() else { return nil }
        do {
            guard try exists() else { return nil }
            let db = try SidecarDatabase(url, writing: false)
            try db.execute("BEGIN")
            try validate(db)
            let stamp = try db.statement("SELECT stamp FROM source_generations WHERE id = ?", [String(generation)]) { query in
                sqlite3_step(query) == SQLITE_ROW ? sqlite3_column_text(query, 0).map(String.init(cString:)) : nil
            }
            guard let stamp else { return nil }
            return try verifiedSection(key, in: db, stamp: stamp, maxBytes: maxBytes,
                                       cancelled: cancelled, generation: String(generation))
        } catch { return nil }
    }
}
