import Foundation
import SQLite3

extension AnalysisSidecar {
    static func isEditableSection(_ name: String) -> Bool {
        name == Self.viewNameSectionKey || name == Self.silenceThresholdOverridesKey
    }

    private struct Field {
        let value: NSObject?
        let time: ChangeTime
    }

    private struct MetadataFields {
        var fields: [String: Field]
        let cleared: ChangeTime?
        let group: ChangeTime

        func merging(_ other: Self) -> Self {
            var merged = fields
            for (key, field) in other.fields {
                if merged[key].map({ $0.time < field.time }) ?? true { merged[key] = field }
            }
            let clear = [cleared, other.cleared].compactMap { $0 }.max()
            if let clear {
                for (key, field) in merged where field.time < clear {
                    merged[key] = Field(value: nil, time: clear)
                }
            }
            return Self(fields: merged, cleared: clear, group: max(group, other.group))
        }

        func data() throws -> Data {
            try JSONSerialization.data(withJSONObject: fields.compactMapValues(\.value), options: [.sortedKeys])
        }
    }

    private func dictionary(_ data: Data, key: String) -> [String: NSObject]? {
        if key == Self.viewNameSectionKey {
            guard let names = try? JSONDecoder().decode([Int: String].self, from: data),
                  names.keys.allSatisfy({ $0 > 0 }) else { return nil }
        } else {
            guard let thresholds = try? JSONDecoder().decode([Int: Double].self, from: data),
                  thresholds.allSatisfy({ $0.key >= 0 && (-120...0).contains($0.value) }) else { return nil }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: NSObject]
    }

    /// Pre-v5 metadata had no individual clocks. A recorded edit to a different
    /// field cannot establish when an unclocked value changed.
    private func inheritedFieldTime(in db: SidecarDatabase, group: ChangeTime) throws -> ChangeTime {
        guard db.hasChangeTimes, group.recorded else { return group }
        return try db.statement("SELECT legacy_mtime FROM sidecar_location WHERE id = 1") { row in
            guard sqlite3_step(row) == SQLITE_ROW else { throw db.error() }
            return ChangeTime(recorded: false, time: sqlite3_column_double(row, 0))
        }
    }

    func recordFieldChanges(_ key: String, old: Data?, new: Data, in db: SidecarDatabase) throws {
        guard let next = dictionary(new, key: key) else { return }
        let previous = old.flatMap { dictionary($0, key: key) } ?? [:]
        var inherited = Set(previous.keys.filter { next[$0] == previous[$0] })
        if !inherited.isEmpty {
            try db.statement("SELECT field FROM sidecar_field_changes WHERE name = ?", [key]) { row in
                var step = sqlite3_step(row)
                while step == SQLITE_ROW, let field = sqlite3_column_text(row, 0) {
                    inherited.remove(String(cString: field))
                    if inherited.isEmpty { return }
                    step = sqlite3_step(row)
                }
                guard step == SQLITE_DONE else { throw db.error() }
            }
        }
        if !inherited.isEmpty {
            let baseline = try inheritedFieldTime(in: db, group: changeTime(key, in: db, at: url))
            let timestamp = String(baseline.recorded ? baseline.time : -baseline.time)
            for field in inherited {
                try db.update("INSERT INTO sidecar_field_changes(name, field, changed) VALUES(?, ?, ?)", [key, field, timestamp])
            }
        }
        let changed = String(Date().timeIntervalSince1970)
        for field in Set(next.keys).union(previous.keys) where next[field] != previous[field] {
            try db.update("INSERT OR REPLACE INTO sidecar_field_changes(name, field, changed) VALUES(?, ?, ?)",
                          [key, field, changed])
        }
        if next.isEmpty {
            try db.update("INSERT OR REPLACE INTO sidecar_field_changes(name, field, changed) VALUES(?, '*', ?)", [key, changed])
        }
    }

    private func metadataFields(_ key: String, in copy: CopySnapshot, cancelled: () -> Bool) throws -> MetadataFields? {
        guard let bytes = try verifiedSection(key, in: copy.db, stamp: copy.stamp, maxBytes: nil, cancelled: cancelled),
              let values = dictionary(bytes, key: key) else { return nil }
        let group = try changeTime(key, in: copy.db, at: copy.store.url)
        var fields: [String: Field] = [:]
        var cleared: ChangeTime?
        if copy.db.hasChangeTimes {
            try copy.db.statement("SELECT field, changed FROM sidecar_field_changes WHERE name = ?", [key]) { q in
                var step = sqlite3_step(q)
                while step == SQLITE_ROW {
                    guard let name = sqlite3_column_text(q, 0) else { throw copy.db.error() }
                    let field = String(cString: name), time = sqlite3_column_double(q, 1)
                    let clock = ChangeTime(recorded: time > 0, time: abs(time))
                    if field == "*" { cleared = clock }
                    else { fields[field] = Field(value: values[field], time: clock) }
                    step = sqlite3_step(q)
                }
                guard step == SQLITE_DONE else { throw copy.db.error() }
            }
        }
        let missing = values.keys.filter { fields[$0] == nil }
        if !missing.isEmpty {
            let baseline = try inheritedFieldTime(in: copy.db, group: group)
            for field in missing { fields[field] = Field(value: values[field], time: baseline) }
        }
        return MetadataFields(fields: fields, cleared: cleared, group: group)
    }

    /// Different scene detection results can assign different meanings to view 1.
    /// Apply a peer's view names only when its scene map also applies here.
    func namesCompatible(_ lhs: CopySnapshot, _ rhs: CopySnapshot) -> Bool {
        let read: (CopySnapshot) -> Data? = { copy in
            try? verifiedSection(Self.sceneSectionKey, in: copy.db, stamp: copy.stamp, maxBytes: nil, cancelled: { Task.isCancelled })
        }
        return read(lhs) == read(rhs)
    }

    func resolvedFields(_ key: String, copies: [CopySnapshot], matching: CopySnapshot? = nil,
                        cancelled: () -> Bool) throws -> Data? {
        var accumulated: MetadataFields?
        let anchor = matching ?? copies.first
        for copy in copies {
            try checkSidecarCancellation(cancelled)
            if key == Self.viewNameSectionKey, let anchor, anchor.store.url != copy.store.url,
               !namesCompatible(anchor, copy) { continue }
            guard let values = try metadataFields(key, in: copy, cancelled: cancelled) else { continue }
            accumulated = accumulated.map { $0.merging(values) } ?? values
        }
        return try accumulated?.data()
    }

    func mergeFields(_ key: String, from peer: CopySnapshot, into db: SidecarDatabase, stamp: String,
                     cancelled: () -> Bool) throws -> Bool {
        let target = CopySnapshot(store: self, db: db, stamp: stamp, current: true, change: peer.change)
        guard let other = try metadataFields(key, in: peer, cancelled: cancelled) else {
            return try metadataFields(key, in: target, cancelled: cancelled) != nil
        }
        if key == Self.viewNameSectionKey && !namesCompatible(target, peer) { return true }
        let old = try metadataFields(key, in: target, cancelled: cancelled)
        let merged = old.map { $0.merging(other) } ?? other
        let bytes = try merged.data()
        if let old, old.group == merged.group, try old.data() == bytes,
           old.fields.mapValues(\.time) == merged.fields.mapValues(\.time), old.cleared == merged.cleared { return true }

        try writeSection(key, value: bytes, db: db, stamp: stamp, cancelled: cancelled)
        try setChangeTime(merged.group, key: key, in: db)
        try db.update("DELETE FROM sidecar_field_changes WHERE name = ?", [key])
        var times = merged.fields.mapValues(\.time)
        times["*"] = merged.cleared
        for (field, time) in times {
            try db.update("INSERT OR REPLACE INTO sidecar_field_changes(name, field, changed) VALUES(?, ?, ?)",
                          [key, field, String(time.recorded ? time.time : -time.time)])
        }
        return true
    }
}
