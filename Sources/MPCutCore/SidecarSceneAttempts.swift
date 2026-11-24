import CryptoKit
import Darwin
import Foundation
import SQLite3

struct SceneAttemptClaim: Sendable {
    let database: URL
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
        let candidates = readCandidates(orderedBy: nil)
        if candidates.isEmpty { return localPersistedSceneAttempts() }
        var seen = Set<String>()
        return candidates.flatMap { $0.localPersistedSceneAttempts() }.filter { seen.insert($0.id).inserted }
    }

    private func localPersistedSceneAttempts() -> [PersistedSceneAttempt] {
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
        // Starting or resuming is an explicit write path. If the new destination is
        // unavailable, the scanner can still read checkpoints and continue in memory.
        if locations.destination == nil { _ = try locations.prepareDestination() }
        let operation = restart ? (operationID ?? UUID().uuidString) : nil
        return try withSceneLock(LOCK_EX, cancelled: cancelled) {
            try admitSceneAttempt(scope: scope, operation: operation, resume: resume, owner: owner, cancelled: cancelled)
        }
    }

    private func withSceneLock<T>(_ mode: Int32, cancelled: () -> Bool, _ operation: () throws -> T) throws -> T {
        let fd = open(source.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw sidecarError(String(cString: strerror(errno))) }
        defer { close(fd) }
        let deadline = ContinuousClock.now + .seconds(5)
        while flock(fd, mode | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw sidecarError(String(cString: strerror(errno))) }
            try checkSidecarCancellation(cancelled)
            guard .now < deadline else { throw sidecarError("Another process is acquiring a scene scan lease.") }
            usleep(10_000)
        }
        try checkSource()
        return try operation()
    }

    private func readCandidatesForSceneAdmission(orderedBy key: String) throws -> [AnalysisSidecar] {
        var inspectionError: Error?
        let copies = readSnapshots(orderedBy: key, unresolvedEvidence: { _ in
            inspectionError = sidecarError("The available scene caches disagree about the media generation.")
        }, inspectionFailure: { inspectionError = $0 })
        if let inspectionError { throw inspectionError }
        return copies.map(\.store)
    }

    private func admitSceneAttempt(scope: String, operation: String?, resume: Bool, owner: String,
                                   cancelled: () -> Bool) throws -> SceneAttemptClaim? {
        let pendingKey = Self.sceneRevision(scope: scope, completed: false)
        let registration = SceneLeaseRegistration(store: self, scope: scope)
        let previous = try registration.read()
        if let previous, previous.expires > Date().timeIntervalSince1970,
           !SidecarLocations.validate(previous.entry) {
            throw sidecarError("A scene scan has an outstanding lease on an unavailable cache disk.")
        }
        let stores = try readCandidatesForSceneAdmission(orderedBy: pendingKey)
        var liveGrant: SceneLeaseRegistration.Grant?
        if let previous, previous.expires > Date().timeIntervalSince1970 {
            let store = pinned(to: previous.entry.url)
            let live = try store.strictSceneSnapshot { db, current in
                let row = try store.attemptRow(db, condition: "id = ? AND generation = ?",
                                               bindings: [previous.attempt, String(current)])
                return row?.isOwned == true && row?.owner == previous.owner && row?.fence == previous.fence
            }
            if live == true {
                guard stores.contains(where: { Self.canonicalSource($0.url) == Self.canonicalSource(previous.entry.url) }) else {
                    throw sidecarError("The active scene scan belongs to another cache location.")
                }
                liveGrant = previous
            }
        }
        var pending: (store: AnalysisSidecar, row: AttemptRow)?
        for store in stores {
            func readPending() throws -> AttemptRow? {
                try store.strictSceneSnapshot { db, generation in try store.pendingAttempt(db, generation: generation, scope: scope) }
            }
            var row = try readPending()
            var replaced: String?
            if let old = row, let token = old.owner, token.hasPrefix(SceneHandoff.prefix) {
                if try recoverHandoff(token, old: old, scope: scope, in: store, cancelled: cancelled) {
                    replaced = old.id
                    row = nil
                } else { row = try readPending() }
            }
            if let old = row, previous?.displaced?.contains(old.id) == true {
                // This database was offline when another location took over.
                // Retire its operation in SQLite before dropping the local fence.
                try store.transact(cancelled: cancelled) { db, _ in
                    try db.update("UPDATE scene_attempts SET state = 2, owner = NULL, expires = 0 WHERE id = ? AND generation = ? AND state = 0",
                                  [old.id, String(old.generation)])
                    try store.pruneSceneHistory(db, generation: old.generation)
                }
                try registration.acknowledge(old.id)
                replaced = old.id
                row = nil
            }
            if let old = row, let liveGrant, old.id != liveGrant.attempt {
                // A returned volume may hold the predecessor to a lease already
                // granted elsewhere. Its operation can be replayed as superseded,
                // even by its original owner, without displacing the active scan.
                replaced = old.id
                row = nil
            }
            if let operation, let replay = try store.strictSceneSnapshot({ db, generation in
                try store.attemptRow(db, condition: "generation = ? AND scope = ? AND operation = ?",
                                     bindings: [String(generation), scope, operation])
            }) {
                if replay.state != 0 || replay.id == replaced {
                    var claim = replay.claim(in: store.url, scope: scope, generation: replay.generation, owner: owner)
                    if replay.id == replaced { claim.superseded = true }
                    return claim
                }
                return try store.claimInDatabase(scope: scope, operation: operation, resume: resume,
                                                  owner: owner, cancelled: cancelled)
            }
            if let row, pending == nil || (row.isOwned && pending?.row.isOwned == false) { pending = (store, row) }
        }
        if operation == nil, !stores.isEmpty, !resume || pending == nil {
            let completed = try stores.count == 1 ? stores : readCandidatesForSceneAdmission(orderedBy: Self.sceneRevision(scope: scope, completed: true))
            for store in completed {
                if let claim = try store.strictSceneSnapshot({ db, generation in
                    try store.activeAttempt(db, generation: generation, scope: scope)?
                        .claim(in: store.url, scope: scope, generation: generation, owner: owner)
                }) { return claim }
            }
        }
        if operation == nil, let pending, pending.row.isOwned, pending.row.owner != owner { return nil }
        if let operation, let pending, pending.store.url != url {
            guard let target = locations.candidateEntries.first(where: { $0.url == url }) else {
                throw sidecarError("The destination for the replacement scan is unavailable.")
            }
            let token = try SceneHandoff(destination: target, operation: operation).token()
            // Commit revocation before opening a destination writer. A rollback
            // or cancellation on either database can never leave two live leases.
            let fenced = try pending.store.transact(cancelled: cancelled) { db, _ in
                try db.update("""
                    UPDATE scene_attempts SET owner = ?, fence = fence + 1, expires = 0
                    WHERE id = ? AND generation = ? AND state = 0 AND fence = ?
                    """, [token, pending.row.id, String(pending.row.generation), String(pending.row.fence)])
                return try db.integer("SELECT changes()") == 1
            }
            let replacement: SceneAttemptClaim?
            do {
                replacement = try claimInDatabase(scope: scope, operation: operation, resume: resume,
                                                   owner: owner, cancelled: cancelled, fenced: fenced ? pending.row.id : nil)
            } catch {
                // transact throws before publication. Restore the checkpoint as
                // paused; the previous owner's fence stays revoked.
                if fenced { try? pending.store.finishHandoff(token, old: pending.row, superseded: false) }
                throw error
            }
            if fenced {
                // A crash or a busy reader here leaves the durable intent for
                // the next admission. The successor already owns the only lease.
                _ = try? recoverHandoff(token, old: pending.row, scope: scope, in: pending.store, cancelled: cancelled)
            }
            return replacement
        }
        let store = pending?.store ?? self
        return try store.claimInDatabase(scope: scope, operation: operation, resume: resume,
                                         owner: owner, cancelled: cancelled)
    }

    private static func sceneRevision(scope: String, completed: Bool) -> String {
        (completed ? "scene_completion.v1." : "scene_progress.v1.") + scope
    }

    /// A zero-expiry owner token also records where to look after an interrupted
    /// restart. Existing storage and clearing code treats this retained work as
    /// a paused checkpoint and excludes it when seeding another database.
    private struct SceneHandoff: Codable {
        static let prefix = "mpcut-scene-handoff:"
        let destination: SidecarCatalogEntry
        let operation: String

        func token() throws -> String {
            Self.prefix + String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        }
    }

    private func recoverHandoff(_ token: String, old: AttemptRow, scope: String, in previous: Self,
                                cancelled: () -> Bool) throws -> Bool {
        try checkSidecarCancellation(cancelled)
        let handoff = try JSONDecoder().decode(SceneHandoff.self, from: Data(token.dropFirst(SceneHandoff.prefix.count).utf8))
        guard Self.canonicalSource(handoff.destination.source) == Self.canonicalSource(source),
              SidecarLocations.validate(handoff.destination) else {
            throw sidecarError("Reconnect the original cache location to resolve the pending scene restart.")
        }
        let target = pinned(to: handoff.destination.url)
        var published = false
        if try target.exists() {
            // Only consult a validated cache already known to this resolver. A
            // path embedded in a sidecar cannot grant access to another file.
            guard locations.candidateEntries.contains(handoff.destination),
                  let db = try target.openReadSnapshot() else {
                throw sidecarError("Open the destination project or reconnect its cache to recover the scene restart.")
            }
            if try target.currentStamp(db) != nil {
                published = try target.attemptRow(db, condition: "generation = ? AND scope = ? AND operation = ?",
                                                  bindings: [String(target.generation(db)), scope, handoff.operation]) != nil
            }
        }
        if published {
            // The successor is authoritative even while a read lock delays
            // housekeeping in the previous file. Other processes can follow it.
            let deadline = ContinuousClock.now + .milliseconds(200)
            try? previous.finishHandoff(token, old: old, superseded: true,
                                        cancelled: { cancelled() || .now >= deadline })
        } else { try previous.finishHandoff(token, old: old, superseded: false, cancelled: cancelled) }
        return published
    }

    private func finishHandoff(_ token: String, old: AttemptRow, superseded: Bool, cancelled: () -> Bool = { false }) throws {
        try transact(cancelled: cancelled) { db, _ in
            try db.update("UPDATE scene_attempts SET state = ?, owner = NULL WHERE id = ? AND generation = ? AND state = 0 AND owner = ?",
                          [superseded ? "2" : "0", old.id, String(old.generation), token])
            if superseded, try db.integer("SELECT changes()") == 1 {
                try pruneSceneHistory(db, generation: old.generation)
            }
        }
    }

    private func claimInDatabase(scope: String, operation: String?, resume: Bool,
                                 owner: String, cancelled: () -> Bool, fenced: String? = nil) throws -> SceneAttemptClaim? {
        let registration = SceneLeaseRegistration(store: self, scope: scope)
        let previous = try registration.read()
        var registrationWritten = false
        defer {
            if registrationWritten {
                // SQLite rolled back the claim or staged publication failed.
                if let previous { try? registration.write(previous) } else { registration.remove() }
            }
        }
        let result = try transact(cancelled: cancelled) { db, _ -> SceneAttemptClaim? in
            func publish(_ claim: SceneAttemptClaim, expires: Double) throws {
                try register(claim, expires: expires, previous: previous, fenced: fenced)
                registrationWritten = true
            }
            let generation = try generation(db)
            let context = [String(generation), scope]
            if let operation, let attempt = try attemptRow(db, condition: "generation = ? AND scope = ? AND operation = ?",
                                                           bindings: context + [operation]) {
                return try acquire(attempt, scope: scope, generation: generation, owner: owner, db: db, publish: publish)
            }
            if operation == nil {
                if !resume, let completed = try activeAttempt(db, generation: generation, scope: scope) {
                    return completed.claim(in: url, scope: scope, generation: generation, owner: owner)
                }
                if let attempt = try attemptRow(db, condition: "generation = ? AND scope = ? AND state = 0",
                                                bindings: context) {
                    return try acquire(attempt, scope: scope, generation: generation, owner: owner, db: db, publish: publish)
                }
                if let completed = try activeAttempt(db, generation: generation, scope: scope) {
                    return completed.claim(in: url, scope: scope, generation: generation, owner: owner)
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
            try recordChange(Self.sceneRevision(scope: scope, completed: false), in: db)
            let claim = SceneAttemptClaim(database: url, attemptID: id, scope: scope, generation: generation, owner: owner,
                                          fence: 1, completed: false)
            try publish(claim, expires: expiry)
            return claim
        }
        registrationWritten = false
        return result
    }

    func sceneAttempt(scope: String, completed: Bool, afterCoverage: Double? = nil,
                      followedAttempt: String? = nil, followedFence: Int64? = nil) -> SceneAttemptSnapshot? {
        let candidates = readCandidates(orderedBy: Self.sceneRevision(scope: scope, completed: completed))
        for store in candidates {
            // A match without new coverage must stop the search. Returning an older
            // checkpoint from another copy would rewind a subscriber's progress.
            let observed: (unchanged: Bool, snapshot: SceneAttemptSnapshot?)? = store.readSceneSnapshot { db, generation in
                let attempt = try completed ? store.activeAttempt(db, generation: generation, scope: scope)
                                            : store.pendingAttempt(db, generation: generation, scope: scope)
                guard let attempt else { return nil }
                let sameAttempt = followedAttempt == nil && followedFence == nil ||
                    (followedAttempt == attempt.id && followedFence == attempt.fence)
                if sameAttempt, afterCoverage == attempt.covered { return (true, nil) }
                return (false, try store.snapshot(attempt, db: db))
            }
            if let observed {
                if observed.unchanged { return nil }
                if let snapshot = observed.snapshot { return snapshot }
            }
        }
        return nil
    }

    func sceneAttempt(_ claim: SceneAttemptClaim) -> SceneAttemptSnapshot? {
        let store = pinned(to: claim.database)
        return store.readSceneSnapshot { db, generation in
            guard generation == claim.generation,
                  let attempt = try store.attemptRow(db, condition: "id = ?", bindings: [claim.attemptID]) else { return nil }
            return try store.snapshot(attempt, db: db)
        }
    }

    private func store(for claim: SceneAttemptClaim) throws -> AnalysisSidecar {
        let store = pinned(to: claim.database)
        guard try store.exists() else { throw Self.lostSceneClaim() }
        return store
    }

    /// A medium can be remounted after a successor took over on another disk.
    /// Hold a shared source lock from the coordinator check through SQLite commit.
    /// Admission uses the exclusive lock, so an old writer cannot pass its check
    /// before takeover and then publish a delayed checkpoint afterward.
    private func updateOwned(_ claim: SceneAttemptClaim, sections: [String: Data] = [:], cancelled: () -> Bool,
                             change: (SidecarDatabase, String) throws -> Void) throws {
        try withSceneLock(LOCK_SH, cancelled: cancelled) {
            let store = try store(for: claim)
            let registration = SceneLeaseRegistration(store: store, scope: claim.scope)
            guard let registered = try registration.read(), registered.matches(claim) else { throw Self.lostSceneClaim() }
            let released = try store.transact(sections, cancelled: cancelled) { db, stamp in
                try change(db, stamp)
                guard let row = try store.attemptRow(db, condition: "id = ?", bindings: [claim.attemptID]),
                      row.state == 0, row.owner == claim.owner else { return true }
                if row.expires > registered.expires {
                    var renewed = registered
                    renewed.expires = row.expires
                    try registration.write(renewed)
                }
                return false
            }
            if released { try registration.finish(registered) }
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
        try updateOwned(claim, sections: sections, cancelled: cancelled) { db, _ in
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
            try recordChange(Self.sceneRevision(scope: claim.scope, completed: complete), in: db)
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
        try updateOwned(claim, cancelled: cancelled) { db, _ in
            _ = try requireClaim(claim, db: db)
            try db.update("UPDATE scene_attempts SET expires = ? WHERE id = ?",
                          [String(Date().timeIntervalSince1970 + Self.sceneLeaseDuration), claim.attemptID])
        }
    }

    func resetSceneAttempt(_ claim: SceneAttemptClaim) throws {
        try updateOwned(claim, cancelled: { false }) { db, _ in
            _ = try requireClaim(claim, db: db)
            try recordChange(Self.sceneRevision(scope: claim.scope, completed: false), in: db)
            try db.update("DELETE FROM scene_markers WHERE attempt = ?", [claim.attemptID])
            try db.update("UPDATE scene_attempts SET covered = 0, marker_count = 0, checkpoint = NULL, checkpoint_digest = NULL, logical_size = 0 WHERE id = ?",
                          [claim.attemptID])
        }
    }

    func releaseSceneAttempt(_ claim: SceneAttemptClaim) throws {
        try updateOwned(claim, cancelled: { false }) { db, _ in
            _ = try requireClaim(claim, db: db)
            try db.update("UPDATE scene_attempts SET owner = NULL WHERE id = ?", [claim.attemptID])
        }
    }

    private func acquire(_ attempt: AttemptRow, scope: String, generation: Int64, owner: String,
                         db: SidecarDatabase, publish: (SceneAttemptClaim, Double) throws -> Void) throws -> SceneAttemptClaim? {
        if attempt.state != 0 { return attempt.claim(in: url, scope: scope, generation: generation, owner: owner) }
        guard attempt.owner?.hasPrefix(SceneHandoff.prefix) != true else { return nil }
        let now = Date().timeIntervalSince1970
        guard attempt.owner == nil || attempt.owner == owner || attempt.expires <= now else { return nil }
        let fence = attempt.owner == owner && attempt.expires > now ? attempt.fence : attempt.fence + 1
        let expires = now + Self.sceneLeaseDuration
        try db.update("UPDATE scene_attempts SET owner = ?, fence = ?, expires = ? WHERE id = ?",
                      [owner, String(fence), String(expires), attempt.id])
        let claim = SceneAttemptClaim(database: url, attemptID: attempt.id, scope: scope, generation: generation, owner: owner,
                                     fence: fence, completed: false)
        try publish(claim, expires)
        return claim
    }

    private func register(_ claim: SceneAttemptClaim, expires: Double, previous: SceneLeaseRegistration.Grant?,
                          fenced: String?) throws {
        guard let entry = locations.candidateEntries.first(where: { $0.url == url }) else {
            throw sidecarError("Cannot register the cache location for the scene scan.")
        }
        let registration = SceneLeaseRegistration(store: self, scope: claim.scope)
        var displaced = previous?.displaced ?? []
        // The previous file can reconnect between discovery and publication.
        // Only an already committed revocation can substitute for a local fence.
        if let previous, !previous.owner.isEmpty, previous.attempt != claim.attemptID,
           previous.entry.url != entry.url, previous.attempt != fenced {
            displaced.insert(previous.attempt)
        }
        try registration.write(.init(entry: entry, attempt: claim.attemptID, owner: claim.owner, fence: claim.fence,
                                     expires: expires, displaced: displaced.isEmpty ? nil : displaced))
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
        try? strictSceneSnapshot(read)
    }

    private func strictSceneSnapshot<T>(_ read: (SidecarDatabase, Int64) throws -> T?) throws -> T? {
        guard Self.readsEnabled, let db = try openReadSnapshot(), try currentStamp(db) != nil else { return nil }
        let result = try read(db, generation(db))
        try checkSource()
        return result
    }

    private struct AttemptRow {
        let id: String
        let owner: String?
        let fence: Int64
        let expires: Double
        let state: Int32
        let covered: Double
        let generation: Int64
        let markerCount: Int

        var isOwned: Bool { owner != nil && expires > Date().timeIntervalSince1970 }

        func markerContext(_ ordinal: Int) -> String { "\(id)/marker/\(ordinal)" }

        func checkpointContext(_ count: Int) -> String { "\(id)/checkpoint/\(count)" }

        func claim(in database: URL, scope: String, generation: Int64, owner: String) -> SceneAttemptClaim {
            SceneAttemptClaim(database: database, attemptID: id, scope: scope, generation: generation, owner: owner,
                              fence: fence, completed: state == 1, superseded: state == 2)
        }
    }

    private func pendingAttempt(_ db: SidecarDatabase, generation: Int64, scope: String) throws -> AttemptRow? {
        try attemptRow(db, condition: "generation = ? AND scope = ? AND state = 0", bindings: [String(generation), scope])
    }

    private func activeAttempt(_ db: SidecarDatabase, generation: Int64, scope: String) throws -> AttemptRow? {
        try attemptRow(db, condition: """
            id = (SELECT attempt FROM scene_reports WHERE generation = ? AND scope = ?)
            """, bindings: [String(generation), scope])
    }

    private func attemptRow(_ db: SidecarDatabase, condition: String, bindings: [String]) throws -> AttemptRow? {
        try db.statement("""
            SELECT id, owner, fence, expires, state, covered, marker_count, generation FROM scene_attempts
            WHERE \(condition) ORDER BY ordinal DESC LIMIT 1
            """, bindings) { query in
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW, let id = sqlite3_column_text(query, 0) else { throw db.error() }
            return AttemptRow(id: String(cString: id), owner: sqlite3_column_text(query, 1).map(String.init(cString:)),
                              fence: sqlite3_column_int64(query, 2), expires: sqlite3_column_double(query, 3),
                              state: sqlite3_column_int(query, 4), covered: sqlite3_column_double(query, 5),
                              generation: sqlite3_column_int64(query, 7), markerCount: Int(sqlite3_column_int64(query, 6)))
        }
    }

    private func checkpoint(_ attempt: AttemptRow, db: SidecarDatabase) throws -> Data? {
        try db.statement("SELECT checkpoint, checkpoint_digest, \(db.logicalSizeColumn) FROM scene_attempts WHERE id = ?",
                         [attempt.id]) { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
            return Self.readVerifiedSceneBlob(query, context: attempt.checkpointContext(attempt.markerCount))
        }
    }

    /// Scope reports consist of an attempt plus its ordered marker batches. The
    /// current source generations can have different local IDs in the two databases.
    func mergeCompletedSceneAttempts(from peer: CopySnapshot, into db: SidecarDatabase, cancelled: () -> Bool) throws {
        let theirs = try generation(peer.db), ours = try generation(db)
        try peer.db.statement("SELECT scope, attempt FROM scene_reports WHERE generation = ?", [String(theirs)]) { query in
            var step = sqlite3_step(query)
            while step == SQLITE_ROW {
                try checkSidecarCancellation(cancelled)
                guard let rawScope = sqlite3_column_text(query, 0), let rawID = sqlite3_column_text(query, 1) else {
                    throw peer.db.error()
                }
                let scope = String(cString: rawScope), id = String(cString: rawID)
                let key = Self.sceneRevision(scope: scope, completed: true)
                let local = try activeAttempt(db, generation: ours, scope: scope)
                if local?.id != id {
                    let incoming = try changeTime(key, in: peer.db, at: peer.store.url)
                    let current = try changeTime(key, in: db, at: url)
                    if local == nil || incoming > current {
                        try db.execute("SAVEPOINT import_scene")
                        if try importCompletedAttempt(id, from: peer.db, to: db, generation: ours, cancelled: cancelled) {
                            try db.update("INSERT OR REPLACE INTO scene_reports(generation, scope, attempt) VALUES(?, ?, ?)",
                                          [String(ours), scope, id])
                            try db.update("INSERT OR REPLACE INTO sidecar_changes(name, changed) VALUES(?, ?)",
                                          [key, String(incoming.recorded ? incoming.time : -incoming.time)])
                            try pruneSceneHistory(db, generation: ours)
                        } else { try db.execute("ROLLBACK TO import_scene") }
                        try db.execute("RELEASE import_scene")
                    }
                }
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw peer.db.error() }
        }
    }

    private func importCompletedAttempt(_ id: String, from source: SidecarDatabase, to db: SidecarDatabase,
                                        generation: Int64, cancelled: () -> Bool) throws -> Bool {
        if let existing = try attemptRow(db, condition: "id = ?", bindings: [id]) {
            return existing.state == 1
        }
        guard let attempt = try attemptRow(source, condition: "id = ? AND state = 1", bindings: [id]) else { return false }
        // Transfer original SQLite values while their source statement is live.
        // Only the generation changes. Marker checksums are bound to the immutable
        // attempt ID and ordinal and can be copied with the compressed payload.
        func insert(_ sql: String, prefix: [String], row: OpaquePointer) throws {
            try db.statement(sql, prefix) { write in
                for column in 0..<sqlite3_column_count(row) {
                    guard sqlite3_bind_value(write, Int32(prefix.count) + column + 1,
                                             sqlite3_column_value(row, column)) == SQLITE_OK else { throw db.error() }
                }
                guard sqlite3_step(write) == SQLITE_DONE else { throw db.error() }
            }
        }
        let hasCheckpoint = try source.statement("""
            SELECT checkpoint, checkpoint_digest, \(source.logicalSizeColumn), scope, operation, fence, covered, marker_count
            FROM scene_attempts WHERE id = ?
            """, [id]) { row in
            guard sqlite3_step(row) == SQLITE_ROW,
                  Self.readVerifiedSceneBlob(row, context: attempt.checkpointContext(attempt.markerCount),
                                             cancelled: cancelled) != nil else { return false }
            try insert("""
                INSERT OR IGNORE INTO scene_attempts(id,generation,checkpoint,checkpoint_digest,logical_size,scope,
                    operation,fence,covered,marker_count,expires,state) VALUES(?,?,?,?,?,?,?,?,?,?,0,1)
                """, prefix: [id, String(generation)], row: row)
            return try db.integer("SELECT changes()") != 0
        }
        guard hasCheckpoint else { return false }
        return try source.statement("""
            SELECT value, digest, \(source.logicalSizeColumn), ordinal FROM scene_markers WHERE attempt = ? ORDER BY ordinal
            """, [id]) { row in
            var count = 0
            var step = sqlite3_step(row)
            while step == SQLITE_ROW {
                try checkSidecarCancellation(cancelled)
                count += 1
                guard count <= attempt.markerCount, sqlite3_column_int64(row, 3) == Int64(count),
                      Self.readVerifiedSceneBlob(row, context: attempt.markerContext(count), cancelled: cancelled) != nil
                else { return false }
                try insert("INSERT INTO scene_markers(attempt,value,digest,logical_size,ordinal) VALUES(?,?,?,?,?)",
                           prefix: [id], row: row)
                step = sqlite3_step(row)
            }
            guard step == SQLITE_DONE else { throw source.error() }
            return count == attempt.markerCount
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

    private static func readVerifiedSceneBlob(_ query: OpaquePointer, context: String,
                                              cancelled: () -> Bool = { Task.isCancelled }) -> Data? {
        guard sqlite3_column_type(query, 0) == SQLITE_BLOB,
              sqlite3_column_bytes(query, 1) == SHA256.byteCount,
              let digest = sqlite3_column_blob(query, 1) else { return nil }
        let size = Int(sqlite3_column_bytes(query, 0))
        let bytes: Data
        if size == 0 { bytes = Data() }
        else if let value = sqlite3_column_blob(query, 0) { bytes = Data(bytes: value, count: size) }
        else { return nil }
        let payload = SidecarPayload(bytes: bytes, logicalSize: Int(sqlite3_column_int64(query, 2)))
        guard let decoded = try? payload.decode(cancelled: cancelled) else { return nil }
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
