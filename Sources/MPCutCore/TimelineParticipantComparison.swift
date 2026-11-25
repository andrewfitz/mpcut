import Foundation

extension TimelineComparison {
    /// A change to authored participant data. All ranges use the recording's source clock.
    public struct ParticipantChange: Codable, Equatable, Sendable {
        public enum Category: String, Codable, Hashable, Sendable {
            case geometry = "privacy_geometry"
            case assignment = "tile_assignments"
        }

        public let category: Category
        public let kind: Change.Kind
        public let sourceID: String
        public let tileID: String?
        public let beforeRange: MulticamRange?
        public let afterRange: MulticamRange?
        public let beforeParticipantID: String?
        public let afterParticipantID: String?
        public let fields: [String]
        public let time: RationalTime?

        init(category: Category, kind: Change.Kind, sourceID: String, tileID: String?,
             beforeRange: MulticamRange?, afterRange: MulticamRange?, beforeParticipantID: String?,
             afterParticipantID: String?, fields: [String], time: RationalTime? = nil) {
            self.category = category
            self.kind = kind
            self.sourceID = sourceID
            self.tileID = tileID
            self.beforeRange = beforeRange
            self.afterRange = afterRange
            self.beforeParticipantID = beforeParticipantID
            self.afterParticipantID = afterParticipantID
            self.fields = fields
            self.time = time
        }

        private enum CodingKeys: String, CodingKey {
            case category, kind, fields, time
            case sourceID = "source_id", tileID = "tile_id"
            case beforeRange = "before_range", afterRange = "after_range"
            case beforeParticipantID = "before_participant_id", afterParticipantID = "after_participant_id"
        }
    }
}

struct TimelineParticipantComparison {
    typealias Row = TimelineComparison.ParticipantChange

    let rows: [Row]
    private let before: [String: [Row.Category: Extent]]
    private let after: [String: [Row.Category: Extent]]

    private struct Extent {
        let wholeSource: Bool
        let ranges: [MulticamRange]
        let times: [RationalTime]

        init(_ rows: [Row], after: Bool) {
            let intervals = rows.compactMap { after ? $0.afterRange : $0.beforeRange }
            times = rows.compactMap(\.time).sorted()
            wholeSource = intervals.count + times.count < rows.count
            ranges = intervals.sorted(by: TimelineParticipantComparison.byRange).reduce(into: []) { joined, range in
                if let last = joined.indices.last, range.from <= joined[last].to {
                    joined[last].to = max(range.to, joined[last].to)
                } else {
                    joined.append(range)
                }
            }
        }

        func overlaps(_ range: MulticamRange) -> Bool {
            if wholeSource { return true }
            let interval = ranges.lowerBound { $0.to > range.from }
            if interval < ranges.count, ranges[interval].from < range.to { return true }
            let point = times.lowerBound { $0 >= range.from }
            return point < times.count && times[point] < range.to
        }
    }

    init(_ previous: ParticipantProject, _ current: ParticipantProject) throws {
        var rows: [Row] = []
        let oldSources = Dictionary(previous.sources.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let newSources = Dictionary(current.sources.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let oldOverrides = Dictionary(grouping: previous.appearanceOverrides, by: \.sourceID)
        let newOverrides = Dictionary(grouping: current.appearanceOverrides, by: \.sourceID)
        let sourceIDs = Set(oldSources.keys).union(newSources.keys).union(oldOverrides.keys).union(newOverrides.keys)
        for id in sourceIDs.sorted() {
            try Task.checkCancellation()
            let old = oldSources[id]
            let new = newSources[id]
            guard old != new || oldOverrides[id] != newOverrides[id] else { continue }
            var geometry: [String] = []
            if (old == nil) != (new == nil) { geometry.append("source") }
            if old?.analysisIdentity != new?.analysisIdentity || old?.sourceStamp != new?.sourceStamp
                || old?.sourceInode != new?.sourceInode || old?.sourceContentSHA256 != new?.sourceContentSHA256 {
                geometry.append("source_identity")
            }
            if old?.feedLayout != new?.feedLayout { geometry.append("feed_layout") }
            if old?.countHints != new?.countHints { geometry.append("count_hints") }
            if !geometry.isEmpty {
                rows.append(.init(category: .geometry, kind: Self.kind(old, new), sourceID: id, tileID: nil,
                                  beforeRange: nil, afterRange: nil, beforeParticipantID: nil,
                                  afterParticipantID: nil, fields: geometry))
            }

            let oldTiles = Dictionary(grouping: old?.appearances ?? [], by: \.id)
            let newTiles = Dictionary(grouping: new?.appearances ?? [], by: \.id)
            for tile in Set(oldTiles.keys).union(newTiles.keys).sorted() {
                try Task.checkCancellation()
                rows += Self.compareTiles(source: id, tile: tile, before: oldTiles[tile] ?? [], after: newTiles[tile] ?? [])
            }

            rows += Self.intervalChanges(old?.layoutCapacityRanges ?? [], new?.layoutCapacityRanges ?? [],
                                         category: .geometry, source: id, field: "layout_capacity", range: { $0 })
            rows += Self.intervalChanges(old?.coverage ?? [], new?.coverage ?? [], category: .geometry,
                                         source: id, field: "coverage", range: \.range)
            rows += Self.intervalChanges(old?.confirmations ?? [], new?.confirmations ?? [], category: .geometry,
                                         source: id, field: "privacy_confirmations", range: \.range,
                                         participant: \.participantID)
            rows += Self.intervalChanges(oldOverrides[id] ?? [], newOverrides[id] ?? [], category: .assignment,
                                         source: id, field: "appearance_overrides", range: \.range,
                                         tile: \.appearanceID, participant: \.participantID)
            rows += Self.eventChanges(old?.scanEvents ?? [], new?.scanEvents ?? [], source: id)
            func appendHistory(_ before: [String], _ after: [String], field: String) {
                let oldIDs = Set(before)
                let newIDs = Set(after)
                for participant in oldIDs.symmetricDifference(newIDs).sorted() {
                    rows.append(.init(category: .assignment, kind: oldIDs.contains(participant) ? .removed : .added,
                                      sourceID: id, tileID: nil, beforeRange: nil, afterRange: nil,
                                      beforeParticipantID: oldIDs.contains(participant) ? participant : nil,
                                      afterParticipantID: newIDs.contains(participant) ? participant : nil, fields: [field]))
                }
            }
            appendHistory(old?.historicalParticipantIDs ?? [], new?.historicalParticipantIDs ?? [],
                          field: "historical_participant_ids")
            appendHistory(old?.unresolvedParticipantIDs ?? [], new?.unresolvedParticipantIDs ?? [],
                          field: "unresolved_participant_ids")
        }
        self.rows = rows
        func extents(after: Bool) -> [String: [Row.Category: Extent]] {
            let relevant = rows.filter { $0.kind != (after ? .removed : .added) }
            return Dictionary(grouping: relevant, by: \.sourceID).mapValues { sourceRows in
                Dictionary(grouping: sourceRows, by: \.category).mapValues { Extent($0, after: after) }
            }
        }
        before = extents(after: false)
        after = extents(after: true)
    }

    func categories(in range: MulticamRange, source: String, after isAfter: Bool) -> Set<Row.Category> {
        Set(((isAfter ? after : before)[source] ?? [:]).compactMap { category, extent in
            extent.overlaps(range) ? category : nil
        })
    }

    private static func kind<T>(_ before: T?, _ after: T?) -> TimelineComparison.Change.Kind {
        if before == nil { return .added }
        return after == nil ? .removed : .modified
    }

    private static func compareTiles(source: String, tile: String, before: [ParticipantAppearance],
                                     after: [ParticipantAppearance]) -> [Row] {
        guard before != after else { return [] }
        let old = Dictionary(grouping: before, by: \.range)
        let new = Dictionary(grouping: after, by: \.range)
        var remainingOld: [ParticipantAppearance] = []
        var remainingNew: [ParticipantAppearance] = []
        var pairs: [(ParticipantAppearance?, ParticipantAppearance?)] = []
        for range in Set(old.keys).union(new.keys).sorted(by: byRange) {
            let previous = old[range]?.first
            let current = new[range]?.first
            if let previous, let current { pairs.append((previous, current)) }
            else if let previous { remainingOld.append(previous) }
            else if let current { remainingNew.append(current) }
        }
        if remainingOld.count == 1, remainingNew.count == 1 {
            pairs.append((remainingOld[0], remainingNew[0]))
        } else {
            pairs += remainingOld.map { ($0, nil) } + remainingNew.map { (nil, $0) }
        }
        return pairs.flatMap { previous, current -> [Row] in
            var geometry: [String] = []
            var assignment: [String] = []
            if previous == nil || current == nil { geometry.append("tile") }
            if previous?.range != current?.range { geometry.append("range") }
            if previous?.bounds != current?.bounds { geometry.append("bounds") }
            if previous?.labelBounds != current?.labelBounds { geometry.append("label_bounds") }
            if previous?.detectedBounds != current?.detectedBounds { geometry.append("detected_bounds") }
            if previous?.role != current?.role { geometry.append("role") }
            if previous?.state != current?.state { geometry.append("state") }
            if previous?.slotID != current?.slotID { geometry.append("slot_id") }
            if previous?.reviewedPresentation != current?.reviewedPresentation { geometry.append("reviewed_presentation") }
            if previous?.participantID != current?.participantID { assignment.append("participant_id") }
            if previous?.reviewedIdentity != current?.reviewedIdentity { assignment.append("reviewed_identity") }
            if previous?.range != current?.range, previous?.participantID != nil || current?.participantID != nil {
                assignment.append("range")
            }
            return [(Row.Category.geometry, geometry), (.assignment, assignment)].compactMap { category, fields in
                guard !fields.isEmpty else { return nil }
                return .init(category: category, kind: kind(previous, current), sourceID: source, tileID: tile,
                             beforeRange: previous?.range, afterRange: current?.range,
                             beforeParticipantID: previous?.participantID, afterParticipantID: current?.participantID,
                             fields: fields)
            }
        }
    }

    private static func intervalChanges<T: Hashable>(_ before: [T], _ after: [T], category: Row.Category,
                                                       source: String, field: String, range: (T) -> MulticamRange,
                                                       tile: (T) -> String? = { _ in nil },
                                                       participant: (T) -> String? = { _ in nil }) -> [Row] {
        guard before != after else { return [] }
        // Each range can carry multiple confirmations or override records.
        let old = Dictionary(grouping: before, by: range)
        let new = Dictionary(grouping: after, by: range)
        return Set(old.keys).union(new.keys).sorted(by: byRange).flatMap { interval in
            let previous = old[interval] ?? []
            let current = new[interval] ?? []
            let removed = unmatched(previous, excluding: current).map {
                Row(category: category, kind: .removed, sourceID: source, tileID: tile($0), beforeRange: interval,
                    afterRange: nil, beforeParticipantID: participant($0), afterParticipantID: nil, fields: [field])
            }
            let added = unmatched(current, excluding: previous).map {
                Row(category: category, kind: .added, sourceID: source, tileID: tile($0), beforeRange: nil,
                    afterRange: interval, beforeParticipantID: nil, afterParticipantID: participant($0), fields: [field])
            }
            return removed + added
        }
    }

    private static func eventChanges(_ before: [ParticipantTileScanEvent], _ after: [ParticipantTileScanEvent],
                                     source: String) -> [Row] {
        guard before != after else { return [] }
        let old = Dictionary(grouping: before, by: \.time)
        let new = Dictionary(grouping: after, by: \.time)
        return Set(old.keys).union(new.keys).sorted().flatMap { time in
            let previous = old[time] ?? []
            let current = new[time] ?? []
            let removed = unmatched(previous, excluding: current).map {
                Row(category: .geometry, kind: .removed, sourceID: source, tileID: $0.tileID, beforeRange: nil,
                    afterRange: nil, beforeParticipantID: $0.feedID, afterParticipantID: nil, fields: ["scan_events"], time: time)
            }
            let added = unmatched(current, excluding: previous).map {
                Row(category: .geometry, kind: .added, sourceID: source, tileID: $0.tileID, beforeRange: nil,
                    afterRange: nil, beforeParticipantID: nil, afterParticipantID: $0.feedID, fields: ["scan_events"], time: time)
            }
            return removed + added
        }
    }

    private static func unmatched<T: Hashable>(_ items: [T], excluding others: [T]) -> [T] {
        var counts: [T: Int] = [:]
        for item in others { counts[item, default: 0] += 1 }
        return items.filter { item in
            guard let count = counts[item], count > 0 else { return true }
            counts[item] = count - 1
            return false
        }
    }

    private static func byRange(_ left: MulticamRange, _ right: MulticamRange) -> Bool {
        left.from == right.from ? left.to < right.to : left.from < right.from
    }
}
