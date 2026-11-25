import AppKit
import MPCutCore

struct ParticipantPendingTilePreview {
    let sourceID: String
    let stamp: SceneSourceStamp
    let analysis: ParticipantTrackingResult
    let grids: [TilesReviewChoices.GridCorrection]
    private let appearanceEnds: [UInt64: RationalTime]

    init(sourceID: String, stamp: SceneSourceStamp, analysis: ParticipantTrackingResult,
         grids: [TilesReviewChoices.GridCorrection]) {
        self.sourceID = sourceID
        self.stamp = stamp
        self.analysis = analysis
        self.grids = grids
        appearanceEnds = Dictionary(analysis.appearances.map { ($0.id, $0.end) }, uniquingKeysWith: min)
    }

    func boxes(at time: RationalTime) -> [CGRect] {
        if let grid = grids.last(where: { $0.isValid && $0.range.contains(time) }) {
            let cellWidth = 1 / Double(grid.columns)
            let cellHeight = 1 / Double(grid.rows)
            return (0..<(grid.columns * grid.rows)).map { cell in
                .init(x: Double(cell % grid.columns) * cellWidth, y: Double(cell / grid.columns) * cellHeight,
                      width: cellWidth, height: cellHeight)
            }
        }
        guard analysis.start <= time, time < (analysis.resumeAt ?? analysis.end) else { return [] }
        let observations = analysis.observations
        let after = observations.lowerBound { $0.time > time }
        guard after > 0 else { return [] }
        return observations[after - 1].regions.compactMap { region in
            if let end = appearanceEnds[region.appearanceID], time >= end { return nil }
            return .init(x: region.rect.x, y: region.rect.y, width: region.rect.width, height: region.rect.height)
        }
    }
}

struct TilesReviewCard: Identifiable, Sendable {
    let id: String
    let name: String
    private(set) var ranges: [MulticamRange]
    let representative: ParticipantRegion
    let time: RationalTime
    private(set) var duration: Double = 0

    private mutating func coalesceRanges() {
        var combined: [MulticamRange] = []
        for range in ranges.sorted(by: { $0.from < $1.from }) where range.to > max(.zero, range.from) {
            if let last = combined.last, range.from <= last.to {
                combined[combined.count - 1].to = max(last.to, range.to)
            } else {
                combined.append(.init(from: max(.zero, range.from), to: range.to))
            }
        }
        ranges = combined
        duration = combined.reduce(0) { $0 + ($1.to.seconds - $1.from.seconds) }
    }

    static func applyingMerges(_ merged: [String: String], to cards: [Self]) -> [Self] {
        guard !merged.isEmpty else { return cards }
        var extraRanges: [String: [MulticamRange]] = [:]
        for card in cards {
            if let target = merged[card.id] {
                extraRanges[target, default: []].append(contentsOf: card.ranges)
            }
        }
        return cards.compactMap { card in
            guard merged[card.id] == nil else { return nil }
            guard let additional = extraRanges[card.id] else { return card }
            var updated = card
            updated.ranges.append(contentsOf: additional)
            updated.coalesceRanges()
            return updated
        }
    }

    private enum Key: Hashable {
        case share(UInt64)
        case feed(UInt64)

        var id: String {
            switch self {
            case .share(let id): "share-\(id)"
            case .feed(let id): "feed-\(id)"
            }
        }

        var name: String {
            switch self {
            case .share: "Screen share"
            case .feed(let id): "Feed \(id)"
            }
        }
    }

    static func list(_ scan: ParticipantScanResult) -> (cards: [Self], visible: Int) {
        guard let analysis = scan.analysis else { return ([], 0) }
        var representatives: [Key: (region: ParticipantRegion, time: RationalTime)] = [:]
        var visible = 0
        for observation in analysis.observations {
            visible = max(visible, observation.regions.count)
            for region in observation.regions {
                let key: Key
                if region.kind == .screenShare {
                    key = .share(region.appearanceID)
                } else if let id = region.participantID {
                    key = .feed(id)
                } else {
                    continue
                }
                if let current = representatives[key], current.region.kind == .video || region.kind != .video { continue }
                representatives[key] = (region, observation.time)
            }
        }
        var ranges: [Key: [MulticamRange]] = [:]
        for appearance in analysis.appearances {
            let share = Key.share(appearance.id)
            let key = representatives[share] != nil ? share : appearance.participantID.map(Key.feed)
            if let key, representatives[key] != nil {
                ranges[key, default: []].append(.init(from: appearance.start, to: appearance.end))
            }
        }
        let cards = representatives.map { key, candidate in
            var card = Self(id: key.id, name: key.name, ranges: ranges[key] ?? [],
                            representative: candidate.region, time: candidate.time)
            card.coalesceRanges()
            return card
        }
        return (cards.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }, visible)
    }
}
