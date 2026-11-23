import Foundation
import SQLite3

struct SidecarGenerationRefresh {
    let evidence: Data
    let expectedEvidence: Data?
    let preserving: Set<String>
    let force: Bool
    let preservingScenes: Bool
    let preservingThresholdStreams: Set<Int>
}

extension AnalysisSidecar {
    static let evidenceKey = MediaRefreshEvidence.sectionKey
    package static let silenceThresholdOverridesKey = "silence_threshold_overrides_db.v1"
    private static let evidenceLimit = 16 * 1024 * 1024

    func createManifest(_ db: SidecarDatabase) throws {
        try db.execute("""
            CREATE TABLE source_generations(
                id INTEGER PRIMARY KEY, stamp TEXT NOT NULL, reason TEXT NOT NULL
            );
            INSERT INTO source_generations(id, stamp, reason) SELECT 1, stamp, 'initial' FROM source;
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
                                               force: current && confirmedChange, preservingScenes: comparison.scenes,
                                               preservingThresholdStreams: comparison.verifiedThresholdStreams)
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
        try db.execute("CREATE TEMP TABLE retained_sections(name TEXT PRIMARY KEY)")
        if let refresh {
            for key in refresh.preserving.sorted() where key != Self.evidenceKey && key != Self.silenceThresholdOverridesKey {
                if let bytes = try verifiedSection(key, in: db, stamp: saved, maxBytes: nil, cancelled: cancelled) {
                    try writeSection(key, value: bytes, db: db, stamp: stamp, cancelled: cancelled)
                    try db.update("INSERT INTO retained_sections(name) VALUES(?)", [key])
                }
            }
        }
        // Archive inspectable reports at their original stamp. Preview and index
        // payloads can be rebuilt and are only kept when certified for reuse.
        try db.update("""
            INSERT INTO archived_sections(generation, name, digest, value)
            SELECT ?, name, digest, value FROM sections
            WHERE name NOT IN (SELECT name FROM retained_sections)
              AND (name IN (?, ?, ?, ?) OR name GLOB 'silence_pauses.*' OR name GLOB 'silence_automatic_threshold_db.*')
            """, [String(previous), Self.evidenceKey, Self.sceneSectionKey, Self.viewNameSectionKey,
                  Self.silenceThresholdOverridesKey])
        try db.execute("DELETE FROM sections WHERE name NOT IN (SELECT name FROM retained_sections)")
        if let refresh, !refresh.preservingThresholdStreams.isEmpty,
           let data = try verifiedSection(Self.silenceThresholdOverridesKey, in: db, stamp: saved, maxBytes: nil,
                                          cancelled: cancelled, generation: String(previous)),
           let overrides = try? JSONDecoder().decode([Int: Double].self, from: data) {
            let retained = overrides.filter { refresh.preservingThresholdStreams.contains($0.key) }
            if !retained.isEmpty {
                try writeSection(Self.silenceThresholdOverridesKey, value: JSONEncoder().encode(retained), db: db, stamp: stamp,
                                 cancelled: cancelled)
            }
        }
        try db.update("UPDATE source SET stamp = ? WHERE id = 1", [stamp])
        try db.update("INSERT INTO source_generations(stamp, reason) VALUES(?, ?)",
                      [stamp, current ? "content_changed" : "identity_changed"])
        let next = try generation(db)
        if refresh?.preservingScenes == true {
            try db.update("""
                INSERT INTO scene_reports(generation, scope, attempt)
                SELECT ?, scope, attempt FROM scene_reports WHERE generation = ?
                """, [String(next), String(previous)])
        }
        let oldestRetainedGeneration = String(next - 3)
        try db.update("DELETE FROM archived_sections WHERE generation < ?", [oldestRetainedGeneration])
        try db.update("DELETE FROM scene_reports WHERE generation < ?", [oldestRetainedGeneration])
        try db.update("UPDATE scene_attempts SET state = 2, owner = NULL WHERE generation < ? AND state = 0",
                      [String(next)])
        try pruneSceneHistory(db, generation: next)
        return stamp
    }

    func matchesCurrentGeneration() -> Bool {
        currentGenerationEvidence().current
    }

    func currentGenerationEvidence() -> (current: Bool, evidence: Data?) {
        guard Self.readsEnabled, !isExcluded else { return (false, nil) }
        do {
            guard try exists() else { return (false, nil) }
            let db = try SidecarDatabase(url, writing: false)
            try db.execute("BEGIN")
            try validate(db)
            guard let stamp = try currentStamp(db) else { return (false, nil) }
            let evidence = try? verifiedSection(Self.evidenceKey, in: db, stamp: stamp,
                                                maxBytes: Self.evidenceLimit, cancelled: { Task.isCancelled })
            try checkSource()
            return (true, evidence)
        } catch { return (false, nil) }
    }

    public func previousGenerationSnapshot() -> (evidence: Data, keys: Set<String>)? {
        guard Self.readsEnabled, !isExcluded else { return nil }
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
                                  preservingThresholdStreams: Set<Int> = [], sections: [String: Data] = [:],
                                  cancelled: () -> Bool = { false }) throws {
        guard evidence.count <= Self.evidenceLimit else { throw sidecarError("Media evidence exceeds the size limit.") }
        let refresh = SidecarGenerationRefresh(evidence: evidence, expectedEvidence: expectedEvidence,
                                               preserving: preserving, force: force, preservingScenes: preservingScenes,
                                               preservingThresholdStreams: preservingThresholdStreams)
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

    public static func offlineInventory(source: URL) -> (status: String, generations: [PersistedGeneration],
                                                         attempts: [PersistedSceneAttempt]) {
        if let store = try? AnalysisSidecar(source: source) {
            return (store.status(), store.persistedGenerations(), store.persistedSceneAttempts())
        }
        guard source.isFileURL else { return ("unreadable", [], []) }
        let source = source.standardizedFileURL
        if isExcluded(source, in: excludedSources) { return ("excluded", [], []) }
        let url = url(for: source)
        do {
            guard try exists(url, sourceIdentity: nil) else { return ("missing", [], []) }
            let db = try SidecarDatabase(url, writing: false)
            try db.execute("BEGIN")
            try validate(db, at: url)
            _ = try storedStamp(db)
            return ("offline", try persistedGenerations(in: db, current: false),
                    try persistedSceneAttempts(in: db, current: false))
        } catch let error as CutError where error.code == "unsupported_sidecar" {
            return ("unsupported", [], [])
        } catch {
            return ("unreadable", [], [])
        }
    }

    public func readArchived(_ key: String, generation: Int64, maxBytes: Int? = nil,
                             cancelled: () -> Bool = { Task.isCancelled }) -> Data? {
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
