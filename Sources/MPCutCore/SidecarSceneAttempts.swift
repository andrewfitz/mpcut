import CryptoKit
import Foundation
import SQLite3

struct SceneAttemptClaim: Sendable {
    let attemptID: String
    let scope: String
    let generation: Int64
    let owner: String
    let fence: Int64
    let completed: Bool
    var superseded = false
}

struct SceneAttemptSnapshot: Sendable {
    let attemptID: String
    let fence: Int64
    let checkpoint: Data
    let markerBatches: [Data]
    let coveredThrough: Double
    let completed: Bool
}

extension AnalysisSidecar {
    private static let sceneLeaseDuration: TimeInterval = 20

    public struct PersistedSceneAttempt: Codable, Sendable {
        public let id: String
        public let scope: String
        public let generation: Int64
        public let state: String
        public let coveredThrough: Double
        public let current: Bool
    }

    public func persistedSceneAttempts() -> [PersistedSceneAttempt] {
        guard !isExcluded else { return [] }
        do {
            guard try exists() else { return [] }
            let db = try SidecarDatabase(url, writing: false)
            try db.execute("BEGIN")
            try validate(db)
            let current = try currentStamp(db) != nil && identity.isCurrentSnapshot(at: source)
            return try Self.persistedSceneAttempts(in: db, current: current)
        } catch { return [] }
    }

    static func persistedSceneAttempts(in db: SidecarDatabase, current: Bool) throws -> [PersistedSceneAttempt] {
        let generation = try self.generation(db)
        return try db.statement("""
            SELECT id, scope, generation, state, covered, owner, expires, EXISTS(
                SELECT 1 FROM scene_reports WHERE generation = ? AND attempt = scene_attempts.id
            ) FROM scene_attempts ORDER BY ordinal DESC
            """, [String(generation)]) { query in
            let now = Date().timeIntervalSince1970
            var attempts: [PersistedSceneAttempt] = []
            var step = sqlite3_step(query)
            while step == SQLITE_ROW {
                guard let id = sqlite3_column_text(query, 0), let scope = sqlite3_column_text(query, 1) else {
                    throw db.error()
                }
                let originatingGeneration = sqlite3_column_int64(query, 2)
                let status = sqlite3_column_int(query, 3)
                let active = sqlite3_column_int(query, 7) != 0
                let covered = sqlite3_column_double(query, 4)
                let owned = sqlite3_column_type(query, 5) != SQLITE_NULL && sqlite3_column_double(query, 6) > now
                let state: String
                switch status {
                case 0: state = owned ? "running" : "paused"
                case 1: state = "completed"
                default: state = "superseded"
                }
                let attemptCurrent = current && (active || (status == 0 && originatingGeneration == generation))
                attempts.append(PersistedSceneAttempt(id: String(cString: id), scope: String(cString: scope),
                                                     generation: originatingGeneration, state: state,
                                                     coveredThrough: covered, current: attemptCurrent))
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw db.error() }
            return attempts
        }
    }

    func claimSceneAttempt(scope: String, operationID: String?, restart: Bool, resume: Bool = false,
                           owner: String, cancelled: () -> Bool = { false }) throws -> SceneAttemptClaim? {
        guard Self.readsEnabled, Self.automaticWritesEnabled else {
            throw sidecarError("Automatic persistence is disabled.")
        }
        try checkSidecarCancellation(cancelled)
        let operation = restart ? (operationID ?? UUID().uuidString) : nil
        if !restart, readSceneSnapshot({ db, current in
            if !resume, try activeAttempt(db, generation: current, scope: scope) != nil { return false }
            guard let attempt = try attemptRow(db, condition: "generation = ? AND scope = ? AND state = 0",
                                               bindings: [String(current), scope]) else { return false }
            return attempt.owner != nil && attempt.owner != owner && attempt.expires > Date().timeIntervalSince1970
        }) == true { return nil }
        return try transact(cancelled: cancelled) { db, _ in
            let generation = try generation(db)
            let context = [String(generation), scope]
            if let operation, let attempt = try attemptRow(db, condition: "generation = ? AND scope = ? AND operation = ?",
                                                           bindings: context + [operation]) {
                return try acquire(attempt, scope: scope, generation: generation, owner: owner, db: db)
            }
            if !restart {
                if !resume, let completed = try activeAttempt(db, generation: generation, scope: scope) {
                    return completed.claim(scope: scope, generation: generation, owner: owner)
                }
                if let attempt = try attemptRow(db, condition: "generation = ? AND scope = ? AND state = 0",
                                                bindings: context) {
                    return try acquire(attempt, scope: scope, generation: generation, owner: owner, db: db)
                }
                if let completed = try activeAttempt(db, generation: generation, scope: scope) {
                    return completed.claim(scope: scope, generation: generation, owner: owner)
                }
            } else {
                try db.update("UPDATE scene_attempts SET state = 2, owner = NULL WHERE generation = ? AND scope = ? AND state = 0",
                              context)
                try pruneSceneHistory(db, generation: generation)
            }

            let id = UUID().uuidString
            let expiry = Date().timeIntervalSince1970 + Self.sceneLeaseDuration
            try db.statement("""
                INSERT INTO scene_attempts(id, generation, scope, operation, owner, fence, expires)
                VALUES(?, ?, ?, ?, ?, 1, ?)
                """, [id] + context + [operation ?? "", owner, String(expiry)]) { query in
                if operation == nil, sqlite3_bind_null(query, 4) != SQLITE_OK { throw db.error() }
                guard sqlite3_step(query) == SQLITE_DONE else { throw db.error() }
            }
            return SceneAttemptClaim(attemptID: id, scope: scope, generation: generation, owner: owner,
                                     fence: 1, completed: false)
        }
    }

    func sceneAttempt(scope: String, completed: Bool, afterCoverage: Double? = nil,
                      followedAttempt: String? = nil, followedFence: Int64? = nil) -> SceneAttemptSnapshot? {
        readSceneSnapshot { db, generation in
            let attempt: AttemptRow?
            if completed {
                attempt = try activeAttempt(db, generation: generation, scope: scope)
            } else {
                attempt = try attemptRow(db, condition: "generation = ? AND scope = ? AND state = 0",
                                         bindings: [String(generation), scope])
            }
            guard let attempt else { return nil }
            let sameAttempt = followedAttempt == nil && followedFence == nil ||
                (followedAttempt == attempt.id && followedFence == attempt.fence)
            if sameAttempt, afterCoverage == attempt.covered { return nil }
            return try snapshot(attempt, db: db)
        }
    }

    func sceneAttempt(_ claim: SceneAttemptClaim) -> SceneAttemptSnapshot? {
        readSceneSnapshot { db, generation in
            guard generation == claim.generation,
                  let attempt = try attemptRow(db, condition: "id = ?", bindings: [claim.attemptID]) else { return nil }
            return try snapshot(attempt, db: db)
        }
    }

    func repairCanonicalSceneReport(scope: String, expectedCheckpoint: Data, sections: [String: Data]) throws {
        guard let replacement = sections[Self.sceneSectionKey] else { throw Self.lostSceneClaim() }
        try transact(sections, cancelled: { Task.isCancelled }) { db, stamp in
            guard let active = try activeAttempt(db, generation: generation(db), scope: scope),
                  try checkpoint(active, db: db) == expectedCheckpoint else {
                throw Self.lostSceneClaim()
            }
            if let current = try verifiedSection(Self.sceneSectionKey, in: db, stamp: stamp, maxBytes: nil,
                                                 cancelled: { Task.isCancelled }),
               sceneSectionMatches(current, replacement: replacement, cancelled: { Task.isCancelled }) {
                throw Self.lostSceneClaim()
            }
        }
    }

    func commitSceneAttempt(_ claim: SceneAttemptClaim, checkpoint: Data, markerBatch: Data?,
                            coveredThrough: Double, complete: Bool, sections: [String: Data] = [:],
                            release: Bool = false, cancelled: () -> Bool = { false }) throws {
        guard coveredThrough.isFinite, coveredThrough >= 0,
              complete || sections.keys.allSatisfy({ $0 == Self.sceneClockKey }) else {
            throw sidecarError("Invalid scene checkpoint.")
        }
        try transact(sections, cancelled: cancelled) { db, _ in
            let attempt = try requireClaim(claim, db: db)
            guard coveredThrough >= attempt.covered else { throw sidecarError("Scene coverage went backwards.") }
            var count = attempt.markerCount
            if let markerBatch {
                count += 1
                let payload = try SidecarPayload.encode(markerBatch, cancelled: cancelled)
                try db.updateBlobs("INSERT INTO scene_markers(attempt, ordinal, value, digest, logical_size) VALUES(?, ?, ?, ?, ?)",
                                   [claim.attemptID, String(count)],
                                   blobs: [payload.bytes, Self.sceneDigest(markerBatch, context: attempt.markerContext(count))],
                                   trailing: [String(payload.logicalSize)])
            }
            let expires = Date().timeIntervalSince1970 + Self.sceneLeaseDuration
            let payload = try SidecarPayload.encode(checkpoint, cancelled: cancelled)
            try db.updateBlobs("""
                UPDATE scene_attempts SET state = ?, covered = ?, owner = NULLIF(?, ''), expires = ?,
                    marker_count = ?, checkpoint = ?, checkpoint_digest = ?, logical_size = ? WHERE id = ?
                """, [complete ? "1" : "0", String(coveredThrough), release || complete ? "" : claim.owner,
                      String(expires), String(count)],
                blobs: [payload.bytes, Self.sceneDigest(checkpoint, context: attempt.checkpointContext(count))],
                trailing: [String(payload.logicalSize), claim.attemptID])
            if complete {
                try db.update("INSERT OR REPLACE INTO scene_reports(generation, scope, attempt) VALUES(?, ?, ?)",
                              [String(claim.generation), claim.scope, claim.attemptID])
                try pruneSceneHistory(db, generation: claim.generation)
            }
        }
    }

    func pruneSceneHistory(_ db: SidecarDatabase, generation: Int64) throws {
        // Keep three recent completions per scope in the current generation for
        // operation replays. Live and archived pointers take precedence. Rows
        // without payloads still reserve their original operation ID.
        try db.update("""
            UPDATE scene_attempts AS candidate SET state = 2
            WHERE state = 1 AND NOT EXISTS (
                SELECT 1 FROM scene_reports WHERE attempt = candidate.id
            ) AND (
                generation < ? OR operation IS NULL OR (
                    SELECT count(*) FROM scene_attempts AS newer
                    WHERE newer.generation = candidate.generation AND newer.scope = candidate.scope
                      AND newer.ordinal > candidate.ordinal AND newer.state = 1
                ) >= 3
            )
            """, [String(generation)])
        try db.execute("""
            DELETE FROM scene_markers WHERE attempt IN (
                SELECT id FROM scene_attempts WHERE state = 2 AND checkpoint IS NOT NULL
            );
            UPDATE scene_attempts SET checkpoint = NULL, checkpoint_digest = NULL, logical_size = 0, marker_count = 0
            WHERE state = 2 AND checkpoint IS NOT NULL;
            """)
    }

    func renewSceneAttempt(_ claim: SceneAttemptClaim, cancelled: () -> Bool = { false }) throws {
        try transact(cancelled: cancelled) { db, _ in
            _ = try requireClaim(claim, db: db)
            try db.update("UPDATE scene_attempts SET expires = ? WHERE id = ?",
                          [String(Date().timeIntervalSince1970 + Self.sceneLeaseDuration), claim.attemptID])
        }
    }

    func resetSceneAttempt(_ claim: SceneAttemptClaim) throws {
        try transact(cancelled: { false }) { db, _ in
            _ = try requireClaim(claim, db: db)
            try db.update("DELETE FROM scene_markers WHERE attempt = ?", [claim.attemptID])
            try db.update("UPDATE scene_attempts SET covered = 0, marker_count = 0, checkpoint = NULL, checkpoint_digest = NULL, logical_size = 0 WHERE id = ?",
                          [claim.attemptID])
        }
    }

    func releaseSceneAttempt(_ claim: SceneAttemptClaim) throws {
        try transact(cancelled: { false }) { db, _ in
            _ = try requireClaim(claim, db: db)
            try db.update("UPDATE scene_attempts SET owner = NULL WHERE id = ?", [claim.attemptID])
        }
    }

    private func acquire(_ attempt: AttemptRow, scope: String, generation: Int64, owner: String,
                         db: SidecarDatabase) throws -> SceneAttemptClaim? {
        if attempt.state != 0 { return attempt.claim(scope: scope, generation: generation, owner: owner) }
        let now = Date().timeIntervalSince1970
        guard attempt.owner == nil || attempt.owner == owner || attempt.expires <= now else { return nil }
        let fence = attempt.owner == owner && attempt.expires > now ? attempt.fence : attempt.fence + 1
        try db.update("UPDATE scene_attempts SET owner = ?, fence = ?, expires = ? WHERE id = ?",
                      [owner, String(fence), String(now + Self.sceneLeaseDuration), attempt.id])
        return SceneAttemptClaim(attemptID: attempt.id, scope: scope, generation: generation, owner: owner,
                                 fence: fence, completed: false)
    }

    private func requireClaim(_ claim: SceneAttemptClaim, db: SidecarDatabase) throws -> AttemptRow {
        guard try generation(db) == claim.generation,
              let attempt = try attemptRow(db, condition: "id = ?", bindings: [claim.attemptID]),
              attempt.state == 0, attempt.owner == claim.owner, attempt.fence == claim.fence,
              attempt.expires > Date().timeIntervalSince1970 else { throw Self.lostSceneClaim() }
        return attempt
    }

    private static func lostSceneClaim() -> CutError {
        CutError(code: "scene_claim_lost", message: "The scene attempt was superseded or its lease expired.")
    }

    private func readSceneSnapshot<T>(_ read: (SidecarDatabase, Int64) throws -> T?) -> T? {
        guard Self.readsEnabled else { return nil }
        do {
            guard let db = try openReadSnapshot(), try currentStamp(db) != nil else { return nil }
            let result = try read(db, generation(db))
            try checkSource()
            return result
        } catch { return nil }
    }

    private struct AttemptRow {
        let id: String
        let owner: String?
        let fence: Int64
        let expires: Double
        let state: Int32
        let covered: Double
        let markerCount: Int

        func markerContext(_ ordinal: Int) -> String { "\(id)/marker/\(ordinal)" }

        func checkpointContext(_ count: Int) -> String { "\(id)/checkpoint/\(count)" }

        func claim(scope: String, generation: Int64, owner: String) -> SceneAttemptClaim {
            SceneAttemptClaim(attemptID: id, scope: scope, generation: generation, owner: owner,
                              fence: fence, completed: state == 1, superseded: state == 2)
        }
    }

    private func activeAttempt(_ db: SidecarDatabase, generation: Int64, scope: String) throws -> AttemptRow? {
        try attemptRow(db, condition: """
            id = (SELECT attempt FROM scene_reports WHERE generation = ? AND scope = ?)
            """, bindings: [String(generation), scope])
    }

    private func attemptRow(_ db: SidecarDatabase, condition: String, bindings: [String]) throws -> AttemptRow? {
        try db.statement("""
            SELECT id, owner, fence, expires, state, covered, marker_count FROM scene_attempts
            WHERE \(condition) ORDER BY ordinal DESC LIMIT 1
            """, bindings) { query in
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW, let id = sqlite3_column_text(query, 0) else { throw db.error() }
            return AttemptRow(id: String(cString: id), owner: sqlite3_column_text(query, 1).map(String.init(cString:)),
                              fence: sqlite3_column_int64(query, 2), expires: sqlite3_column_double(query, 3),
                              state: sqlite3_column_int(query, 4), covered: sqlite3_column_double(query, 5),
                              markerCount: Int(sqlite3_column_int64(query, 6)))
        }
    }

    private func checkpoint(_ attempt: AttemptRow, db: SidecarDatabase) throws -> Data? {
        try db.statement("SELECT checkpoint, checkpoint_digest, \(db.logicalSizeColumn) FROM scene_attempts WHERE id = ?",
                         [attempt.id]) { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
            return Self.readVerifiedSceneBlob(query, context: attempt.checkpointContext(attempt.markerCount))
        }
    }

    private func snapshot(_ attempt: AttemptRow, db: SidecarDatabase) throws -> SceneAttemptSnapshot? {
        guard let checkpoint = try checkpoint(attempt, db: db) else { return nil }
        return try db.statement("SELECT value, digest, \(db.logicalSizeColumn) FROM scene_markers WHERE attempt = ? ORDER BY ordinal", [attempt.id]) { query in
            var markers: [Data] = []
            var step = sqlite3_step(query)
            while step == SQLITE_ROW {
                guard !Task.isCancelled, markers.count < attempt.markerCount,
                      let marker = Self.readVerifiedSceneBlob(query, context: attempt.markerContext(markers.count + 1))
                else { return nil }
                markers.append(marker)
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw db.error() }
            guard markers.count == attempt.markerCount else { return nil }
            return SceneAttemptSnapshot(attemptID: attempt.id, fence: attempt.fence,
                                        checkpoint: checkpoint, markerBatches: markers,
                                        coveredThrough: attempt.covered, completed: attempt.state == 1)
        }
    }

    private static func readVerifiedSceneBlob(_ query: OpaquePointer, context: String) -> Data? {
        guard sqlite3_column_type(query, 0) == SQLITE_BLOB,
              sqlite3_column_bytes(query, 1) == SHA256.byteCount,
              let digest = sqlite3_column_blob(query, 1) else { return nil }
        let size = Int(sqlite3_column_bytes(query, 0))
        let bytes: Data
        if size == 0 { bytes = Data() }
        else if let value = sqlite3_column_blob(query, 0) { bytes = Data(bytes: value, count: size) }
        else { return nil }
        let payload = SidecarPayload(bytes: bytes, logicalSize: Int(sqlite3_column_int64(query, 2)))
        guard let decoded = try? payload.decode(cancelled: { Task.isCancelled }) else { return nil }
        return sceneDigest(decoded, context: context).elementsEqual(
            UnsafeRawBufferPointer(start: digest, count: SHA256.byteCount)) ? decoded : nil
    }

    private static func sceneDigest(_ bytes: Data, context: String) -> Data {
        var hash = SHA256()
        hash.update(data: Data(context.utf8))
        hash.update(data: bytes)
        return Data(hash.finalize())
    }
}
