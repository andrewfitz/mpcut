import Darwin
import Foundation
import SQLite3

/// Format 3 stores every payload raw and only a write packs them. A sidecar that is
/// read but never written again would otherwise keep that size indefinitely.
private final class RawStorageRepacks: @unchecked Sendable {
    struct File: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    static let shared = RawStorageRepacks()
    let queue = DispatchQueue(label: "mpcut.sidecar.repack", qos: .utility)
    private let lock = NSLock()
    private var attempted: Set<File> = []
    private var stopping = false

    private init() {
        // Packing can take seconds, and a command-line run often ends sooner. A process that
        // exits inside the transaction leaves its rollback journal beside the media, where it
        // would block a new sidecar once this one is removed. Roll back before the exit completes.
        atexit { RawStorageRepacks.shared.stop() }
    }

    /// One attempt per file in a process. A failure, such as a folder that turns
    /// out to be read-only, must not repeat the work on every later read.
    func claim(_ file: File) -> Bool {
        lock.withLock { attempted.insert(file).inserted }
    }

    var isStopping: Bool {
        lock.withLock { stopping }
    }

    private func stop() {
        lock.withLock { stopping = true }
        queue.sync {}
    }
}

extension AnalysisSidecar {
    private static var rawStorageRepacks: RawStorageRepacks { .shared }

    /// Packs a format 3 file once a read has shown that it is current and in use. The
    /// read returns first. The work is an ordinary write that saves nothing, so the
    /// writer lock arbitrates between processes and the loser finds the storage packed.
    /// Inspection never calls this, and neither does a session that must not write.
    static func repackRawStorage(_ copy: CopySnapshot) {
        guard !copy.db.hasCompactStorage, copy.current, automaticWritesEnabled, readsEnabled else { return }
        let store = copy.store
        var info = stat()
        guard !store.isExcluded, lstat(store.url.path, &info) == 0, access(store.url.path, W_OK) == 0,
              // The rollback journal is created beside the database.
              access(store.url.deletingLastPathComponent().path, W_OK) == 0,
              rawStorageRepacks.claim(.init(device: info.st_dev, inode: info.st_ino)) else { return }
        // A dispatch queue does not inherit the caller's task-local configuration.
        let excluded = excludedSources, home = SidecarLocations.storageDirectory
        let project = SidecarLocations.projectURL, projects = SidecarLocations.projectsBySource
        let repacks = rawStorageRepacks
        repacks.queue.async {
            $excludedSources.withValue(excluded) {
                SidecarLocations.$storageDirectory.withValue(home) {
                    SidecarLocations.$projectURL.withValue(project) {
                        SidecarLocations.$projectsBySource.withValue(projects) {
                            // Best effort. The next write would pack the file in any case.
                            _ = try? store.transact(cancelled: { repacks.isStopping }) { _, _ in }
                        }
                    }
                }
            }
        }
    }

    /// Returns once the repacks that earlier reads started have finished.
    static func waitForRawStorageRepacks() {
        rawStorageRepacks.queue.sync {}
    }
}

extension SidecarDatabase {
    /// Called inside the normal BEGIN IMMEDIATE transaction. Updating rows in place
    /// preserves retention order, scene leases, history, and the original checksums.
    func upgradePayloadStorage(cancelled: () -> Bool) throws {
        // Rewriting every payload dirties most of the file. Once the default cache fills,
        // SQLite spills pages and holds its exclusive lock until the commit, and readers
        // would then miss their cached analysis for as long as the packing takes.
        try execute("PRAGMA cache_size = -131072")
        for (table, column) in [("sections", "value"), ("archived_sections", "value"),
                                ("scene_markers", "value"), ("scene_attempts", "checkpoint")] {
            try execute("ALTER TABLE \(table) ADD COLUMN logical_size INTEGER NOT NULL DEFAULT 0")
            let name = table == "sections" || table == "archived_sections" ? "name" : "''"
            let rows = try statement("""
                SELECT rowid, \(name) FROM \(table) WHERE length(\(column)) >= \(SidecarPayload.minimumSize)
                """) { query in
                var rows: [(Int64, String)] = []
                var step = sqlite3_step(query)
                while step == SQLITE_ROW {
                    try checkSidecarCancellation(cancelled)
                    guard let key = sqlite3_column_text(query, 1) else { throw sidecarError("Missing section name.") }
                    rows.append((sqlite3_column_int64(query, 0), String(cString: key)))
                    step = sqlite3_step(query)
                }
                guard step == SQLITE_DONE else { throw error() }
                return rows
            }
            for (row, key) in rows {
                guard let value = try readBlob(table: table, column: column, row: row, maxBytes: nil,
                                               cancelled: cancelled, visit: { _ in }) else { throw error() }
                let payload = try SidecarPayload.encode(value, key: key, cancelled: cancelled)
                if payload.logicalSize > 0 {
                    try updateBlobs("UPDATE \(table) SET \(column) = ?, logical_size = ? WHERE rowid = ?",
                                    [], blobs: [payload.bytes], trailing: [String(payload.logicalSize), String(row)])
                }
            }
        }
        try execute("PRAGMA user_version = \(AnalysisSidecar.schemaVersion)")
    }
}
