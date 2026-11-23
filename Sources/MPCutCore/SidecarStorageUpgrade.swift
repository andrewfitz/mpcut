import Foundation
import SQLite3

extension SidecarDatabase {
    /// Called inside the normal BEGIN IMMEDIATE transaction. Updating rows in place
    /// preserves retention order, scene leases, history, and the original checksums.
    func upgradePayloadStorage(cancelled: () -> Bool) throws {
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
