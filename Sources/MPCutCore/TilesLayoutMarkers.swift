import Foundation

public struct TilesLayoutMarker: Encodable, Sendable {
    @ParticipantSourceTime public var sourceTime: RationalTime
    @ParticipantSourceTime public var endSourceTime: RationalTime
    public let kind: [ParticipantChangeEvent.Kind]
    public let changedCount: Int
    public let eligibleCount: Int
    public let uncertain: Bool
    public let feedIDs: [String]
    public let tileIDs: [String]

    enum CodingKeys: String, CodingKey {
        case sourceTime = "source_time", endSourceTime = "end_source_time", kind, uncertain
        case changedCount = "changed_count", eligibleCount = "eligible_count"
        case feedIDs = "feed_ids", tileIDs = "tile_ids"
    }
}

public struct TilesLayoutMarkers: Encodable, Sendable {
    public let schemaVersion = 1
    public let sourceID: String
    public let markers: [TilesLayoutMarker]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", sourceID = "source_id", markers }
}

extension TilesReview {
    public func layoutMarkers(rule: ParticipantMarkerRule, at time: RationalTime? = nil,
                              range: MulticamRange? = nil) -> TilesLayoutMarkers {
        func selected(_ feed: String?) -> Bool {
            guard let roster = rule.roster else { return true }
            guard let feed else { return false }
            let detectorID = UInt64(feed) ?? feed.components(separatedBy: "-participant-").last.flatMap(UInt64.init)
            return detectorID.map(roster.contains) ?? false
        }
        let matching = issues.filter { issue in
            issue.kind == .layoutChange && selected(issue.feedID) &&
                issue.changeKind.map(rule.kinds.contains) == true && issue.sourceTime != nil
        }
        let settling = Double(rule.settlingWindowMS) / 1_000
        var markers: [TilesLayoutMarker] = []
        var index = matching.startIndex
        while index < matching.endIndex {
            guard let start = matching[index].sourceTime else { break }
            var end = start
            var next = index
            while next < matching.endIndex, let eventTime = matching[next].sourceTime,
                  eventTime.seconds - start.seconds <= settling {
                end = eventTime
                next += 1
            }
            let group = matching[index..<next]
            index = next
            guard time.map({ $0 == start }) ?? true, range.map({ $0.contains(start) }) ?? true else { continue }
            let feedIDs = Set(group.compactMap(\.feedID))
            let tileIDs = Set(group.compactMap(\.tileID))
            let context = appearances.lazy.filter { tile in
                let before = tile.range.from < start && start <= tile.range.to
                return (before || tile.range.contains(end)) && selected(tile.participantID)
            }
            let changed = rule.unit == .participants ? feedIDs : tileIDs
            let eligible = Set(context.compactMap { rule.unit == .participants ? $0.participantID : $0.id })
            let matches: Bool
            switch rule.threshold {
            case .any: matches = !changed.isEmpty
            case .atLeast(let required): matches = !changed.isEmpty && changed.count >= required
            case .all: matches = !eligible.isEmpty && eligible.isSubset(of: changed)
            }
            guard matches else { continue }
            let uncertain = group.contains { $0.uncertain == true } || issues.contains { issue in
                guard issue.kind == .uncheckedRange || issue.kind == .unassignedTile || issue.kind == .ambiguousMatch,
                      let range = issue.range else { return false }
                return range.from <= end && start < range.to
            }
            markers.append(.init(sourceTime: start, endSourceTime: end,
                                 kind: Set(group.compactMap(\.changeKind)).sorted { $0.rawValue < $1.rawValue },
                                 changedCount: changed.count, eligibleCount: eligible.count, uncertain: uncertain,
                                 feedIDs: feedIDs.sorted(), tileIDs: tileIDs.sorted()))
        }
        return .init(sourceID: sourceID, markers: markers)
    }
}
