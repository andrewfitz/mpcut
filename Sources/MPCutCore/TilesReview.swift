import Foundation

public struct TilesCounts: Encodable, Sendable {
    public let feedCount: Int
    public let maxVisibleTiles: Int
    enum CodingKeys: String, CodingKey { case feedCount = "feed_count", maxVisibleTiles = "max_visible_tiles" }
}

public struct TilesTile: Encodable, Sendable {
    public let tileID: String
    public let feedID: String?
    public let range: MulticamRange
    public let bounds: ParticipantBounds
    public let role: ParticipantAppearance.Role
    public let state: ParticipantAppearance.State
    enum CodingKeys: String, CodingKey { case tileID = "tile_id", feedID = "feed_id", range, bounds, role, state }

    init(_ appearance: ParticipantAppearance) {
        tileID = appearance.id
        feedID = appearance.participantID
        range = appearance.range
        bounds = appearance.bounds
        role = appearance.role
        state = appearance.state
    }
}

public struct TilesFeed: Encodable, Sendable {
    public let feedID: String
    public let name: String
    public let mic: ParticipantAudioBinding?
    public let voices: [ParticipantSpeakerBinding]
    public let treatment: ParticipantFeedTreatment?
    enum CodingKeys: String, CodingKey { case feedID = "feed_id", name, mic, voices, treatment }

    init(_ person: ParticipantPerson) {
        feedID = person.id
        name = person.name
        mic = person.audio
        voices = person.speakers
        treatment = person.treatment
    }
}

public struct TilesIssue: Encodable, Sendable {
    public enum Kind: String, Encodable, Sendable {
        case unassignedTile = "unassigned_tile", uncheckedRange = "unchecked_range"
        case layoutChange = "layout_change", changedSource = "changed_source"
        case ambiguousMatch = "ambiguous_match", countMismatch = "count_mismatch"
    }
    public let id: String
    public let kind: Kind
    public let message: String
    public var range: MulticamRange?
    @ParticipantOptionalSourceTime public var sourceTime: RationalTime? = nil
    @ParticipantOptionalSourceTime public var precedingTime: RationalTime? = nil
    public var tileID: String?
    public var feedID: String?
    public var candidateFeedIDs: [String] = []
    public var changeKind: ParticipantChangeEvent.Kind? = nil
    public var uncertain: Bool? = nil
    /// Feed decisions for one tile share a group: one link of the whole tile
    /// resolves every issue in it. `groupCount` is the number of issues in the group.
    public var groupID: String? = nil
    public var groupCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, message, range
        case sourceTime = "source_time", precedingTime = "preceding_time"
        case tileID = "tile_id", feedID = "feed_id", candidateFeedIDs = "candidate_feed_ids"
        case changeKind = "change_kind", uncertain
        case groupID = "group_id", groupCount = "group_count"
    }

    var decidesFeed: Bool { kind == .ambiguousMatch || kind == .unassignedTile }
}

public struct TilesInspection: Encodable, Sendable {
    public let schemaVersion = 1
    public let sourceID: String
    @ParticipantOptionalSourceTime public var sourceTime: RationalTime?
    public let range: MulticamRange?
    public let counts: TilesCounts
    public let visibleTiles: Int?
    public let tiles: [TilesTile]
    public let coverage: [ParticipantCoverage]
    public let gaps: [MulticamRange]
    public let layouts: [TileLayoutListing]
    public let issues: [TilesIssue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", sourceID = "source_id", sourceTime = "source_time"
        case range, counts, visibleTiles = "visible_tiles", tiles, coverage, gaps, layouts, issues
    }
}

public struct TilesFeedInspection: Encodable, Sendable {
    public let schemaVersion = 1
    public let sourceID: String
    public let feed: TilesFeed
    public let tiles: [TilesTile]
    public let gaps: [MulticamRange]
    public let simultaneous: [MulticamRange]
    public let preferences: [TilesPreference]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", sourceID = "source_id", feed, tiles, gaps, simultaneous, preferences }
}

public struct TilesPreference: Encodable, Sendable {
    public let tileID: String
    public let range: MulticamRange
    enum CodingKeys: String, CodingKey { case tileID = "tile_id", range }
}

public struct TilesReview: Sendable {
    public let sourceID: String
    public let mediaURL: URL?
    public let feeds: [TilesFeed]
    public let counts: TilesCounts
    public let issues: [TilesIssue]
    public let extent: MulticamRange?
    let appearances: [ParticipantAppearance]
    private let coverage: [ParticipantCoverage]
    private let preferences: [ParticipantAppearanceOverride]
    private let layouts: [TileLayoutListing]
    private let layoutSource: (coverage: MulticamRange?, offset: RationalTime)?

    public init(project: CutProject, sourceID: String, document: URL, countHints: TilesCountHints? = nil,
                sourceClockOrigin: RationalTime? = nil, useSidecar: Bool = true,
                cancelled: (@Sendable () -> Bool)? = nil) {
        let model = project.participants
        let geometry = model.sources.first { $0.sourceID == sourceID }
        let mediaURL: URL?
        let usedEnd: RationalTime?
        let layoutSource: (coverage: MulticamRange?, offset: RationalTime)?
        if case let .multicam(multicam) = project {
            let source = multicam.pictureSources.first { $0.id == sourceID }
            mediaURL = source.flatMap { try? CutProject.checkedMediaURL($0.file, relativeTo: document) }
            let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: .video)
            let origin = sourceClockOrigin ?? mediaURL.flatMap { try? engine.inspectSummary($0).multicamSourceOffset } ?? .zero
            layoutSource = source.flatMap { source in
                (try? source.offset.adding(origin)).map { (source.coverage, $0) }
            }
            usedEnd = layoutSource.flatMap { try? ($0.coverage?.to ?? multicam.range.to).subtracting($0.offset) }
        } else {
            layoutSource = nil
            let clips = project.sequenceClips?.lazy.filter { $0.file == sourceID }
            mediaURL = clips?.first.flatMap { try? CutProject.checkedMediaURL($0.file, relativeTo: document) }
            usedEnd = clips?.map(\.to).max()
        }
        let appearances = geometry?.appearances ?? []
        let ids = Set(appearances.lazy.compactMap(\.participantID)).union(geometry?.unresolvedParticipantIDs ?? [])
        let treatments = Dictionary(model.effectiveRedactions.map { ($0.participantID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let linkedFeeds = model.people.filter { ids.contains($0.id) }.map { person in
            var feed = person
            feed.treatment = treatments[person.id].map(ParticipantFeedTreatment.init)
            return feed
        }
        let coverage = geometry?.coverage ?? []
        let end = max(geometry == nil ? .zero : usedEnd ?? .zero, coverage.lazy.map(\.range.to).max() ?? .zero,
                      appearances.lazy.map(\.range.to).max() ?? .zero)
        let extent = end > .zero ? MulticamRange(from: .zero, to: end) : nil
        var events = Self.capacityIssues(geometry?.layoutCapacityRanges ?? [])
        var unresolvedTiles: [String: [MulticamRange]] = [:]
        for appearance in appearances where appearance.participantID == nil {
            unresolvedTiles[appearance.id, default: []].append(appearance.range)
        }
        unresolvedTiles = unresolvedTiles.mapValues(Self.coalesced)
        for (index, event) in (geometry?.scanEvents ?? []).enumerated() {
            let candidates = event.candidates ?? []
            if event.changesLayout {
                events.append(.init(id: "layout-\(index)", kind: .layoutChange, message: "Layout change: \(event.kind.rawValue).",
                                    sourceTime: event.time, tileID: event.tileID, feedID: event.feedID,
                                    changeKind: event.kind, uncertain: event.uncertain))
            }
            guard event.uncertain || !candidates.isEmpty, let tileID = event.tileID else { continue }
            guard let spans = unresolvedTiles[tileID] else { continue }
            // Coalescing sorts disjoint half-open spans by both start and end.
            let position = spans.lowerBound { $0.to > event.time }
            guard position < spans.count, spans[position].contains(event.time) else { continue }
            let span = spans[position]
            events.append(.init(id: "return-\(index)", kind: .ambiguousMatch, message: "Review the returning tile's feed.",
                                range: span, sourceTime: event.time, precedingTime: candidates.first?.precedingTime,
                                tileID: event.tileID, feedID: event.feedID, candidateFeedIDs: candidates.map(\.feedID)))
        }
        if geometry?.sourceStamp != nil, mediaURL.map({ model.needsReconciliation(sourceID: sourceID, mediaURL: $0) }) != false {
            events.append(.init(id: "changed-source", kind: .changedSource, message: "The recording changed after tiles were accepted."))
        }
        if let extent, let geometry, !geometry.unresolvedParticipantIDs.isEmpty {
            let current = (try? model.currentPrivacyConfirmations(for: geometry, treatments: treatments)) ?? []
            for id in geometry.unresolvedParticipantIDs {
                let ranges = geometry.privacyUnconfirmedRanges(participantID: id, range: extent, confirmations: current)
                for (index, range) in ranges.enumerated() {
                    events.append(.init(id: "unresolved-\(id)-\(index)", kind: .ambiguousMatch,
                                        message: "Review feed assignments after source reconciliation.",
                                        range: range, sourceTime: range.from, feedID: id))
                }
            }
        }
        let layoutProject = model.render == nil ? project : (try? project.migratingLegacyTiles()) ?? project
        self.init(sourceID: sourceID, mediaURL: mediaURL, appearances: appearances, people: linkedFeeds,
                  preferences: model.appearanceOverrides.filter { $0.sourceID == sourceID }, coverage: coverage,
                  extent: extent, countHints: countHints ?? geometry?.countHints, events: events,
                  layouts: layoutProject.tileLayoutListings,
                  layoutSource: layoutSource)
    }

    public init(scan: ParticipantScanResult, countHints: TilesCountHints? = nil) {
        let analysis = scan.analysis
        let observations = analysis?.observations ?? []
        let ends = Dictionary(analysis?.appearances.map { ($0.id, $0.end) } ?? [], uniquingKeysWith: min)
        let analysisEnd = analysis?.end ?? scan.source.duration
        var tilesByID: [String: [ParticipantAppearance]] = [:]
        var returnIssues: [String: [TilesIssue]] = [:]
        var lastSeen: [UInt64: RationalTime] = [:]
        var events = Self.capacityIssues(analysis?.layoutCapacityRanges ?? [])
        var presentationIDs = Set<String>()
        for (index, observation) in observations.enumerated() {
            let nextTime = index + 1 < observations.count ? observations[index + 1].time : analysisEnd
            let thumbnails = observation.regions.contains { $0.role == .thumbnail }
            for region in observation.regions {
                let end = min(nextTime, ends[region.appearanceID] ?? nextTime)
                guard observation.time < end else { continue }
                let range = MulticamRange(from: observation.time, to: end)
                let tileID = String(region.appearanceID)
                let state: ParticipantAppearance.State
                switch region.kind {
                case .video: state = .video
                case .cameraOff: state = .cameraOff
                case .unknown: state = .unknown
                case .screenShare: state = .presentation
                }
                let competing = observation.competingMatches(for: region)
                let ambiguous = region.identityUncertain || !competing.isEmpty
                let feedID: String?
                if state == .presentation {
                    feedID = "screen-\(tileID)"
                    if let feedID { presentationIDs.insert(feedID) }
                } else {
                    feedID = ambiguous ? nil : region.participantID.map(String.init)
                }
                let bounds = ParticipantBounds(x: region.rect.x, y: region.rect.y,
                                               width: min(region.rect.width, 1 - region.rect.x),
                                               height: min(region.rect.height, 1 - region.rect.y))
                let tile = ParticipantAppearance(id: tileID, participantID: feedID, range: range, bounds: bounds,
                    role: state == .presentation ? .presentation : region.role == .thumbnail ? .thumbnail : thumbnails ? .stage : .tile,
                    state: state)
                if let index = tilesByID[tileID]?.indices.last, var last = tilesByID[tileID]?[index],
                   last.range.to == range.from {
                    last.range = range
                    if last == tile {
                        tilesByID[tileID]?[index].range.to = range.to
                    } else {
                        tilesByID[tileID, default: []].append(tile)
                    }
                } else {
                    tilesByID[tileID, default: []].append(tile)
                }
                let reviewed = region.possibleMatches.filter { match in
                    match.participantID == region.participantID || competing.contains(match)
                }
                if ambiguous, state != .presentation, !reviewed.isEmpty {
                    let candidates = reviewed.map { String($0.participantID) }
                    if let index = returnIssues[tileID]?.indices.last,
                       returnIssues[tileID]?[index].range?.to == range.from {
                        returnIssues[tileID]?[index].range?.to = range.to
                        let old = returnIssues[tileID]?[index].candidateFeedIDs ?? []
                        returnIssues[tileID]?[index].candidateFeedIDs = Array(Set(old).union(candidates)).sorted()
                    } else {
                        let before = reviewed.compactMap { lastSeen[$0.participantID] }.max()
                        returnIssues[tileID, default: []].append(.init(id: "match-\(tileID)-\(range.from)", kind: .ambiguousMatch,
                            message: "Review the returning tile's feed.", range: range, sourceTime: range.from, precedingTime: before,
                            tileID: tileID, feedID: nil, candidateFeedIDs: candidates))
                    }
                }
            }
            for region in observation.regions where !observation.needsIdentityReview(region) {
                if let identity = region.participantID { lastSeen[identity] = observation.time }
            }
        }
        let appearances = tilesByID.keys.sorted().flatMap { tilesByID[$0] ?? [] }
        events.append(contentsOf: returnIssues.values.joined())
        for (index, event) in (analysis?.events ?? []).enumerated() where event.kind != .cameraState {
            events.append(.init(id: "layout-\(index)", kind: .layoutChange, message: "Layout change: \(event.kind.rawValue).",
                                sourceTime: event.time, tileID: String(event.appearanceID), feedID: String(event.participantID),
                                changeKind: event.kind, uncertain: event.uncertain))
        }
        let people = Set(analysis?.tracks.map { String($0.id) } ?? []).union(presentationIDs).sorted()
            .map { ParticipantPerson(id: $0, name: presentationIDs.contains($0) ? "Screen share \($0)" : "Feed \($0)") }
        let coverage = (analysis?.coverage ?? []).map { item in
            let state: ParticipantCoverageState
            switch item.status {
            case .observed: state = analysis?.sampling == .everyFrame ? .verified : .inferred
            case .inferred: state = .inferred
            case .unknown, .incomplete: state = .unknown
            }
            return ParticipantCoverage(range: .init(from: item.start, to: item.end), state: state)
        }
        self.init(sourceID: scan.source.file, mediaURL: URL(fileURLWithPath: scan.source.file), appearances: appearances,
                  people: people, preferences: [], coverage: coverage,
                  extent: scan.source.duration > .zero ? .init(from: .zero, to: scan.source.duration) : nil,
                  countHints: countHints ?? scan.countHints, events: events)
    }

    private static func capacityIssues(_ ranges: [MulticamRange]) -> [TilesIssue] {
        ranges.enumerated().map { index, range in
            .init(id: "layout-capacity-\(index)", kind: .countMismatch,
                  message: "The automatic detector found more than 64 tiles.",
                  range: range, sourceTime: range.from)
        }
    }

    private init(sourceID: String, mediaURL: URL?, appearances: [ParticipantAppearance], people: [ParticipantPerson],
                 preferences: [ParticipantAppearanceOverride], coverage: [ParticipantCoverage], extent: MulticamRange?,
                 countHints: TilesCountHints?, events: [TilesIssue], layouts: [TileLayoutListing] = [],
                 layoutSource: (coverage: MulticamRange?, offset: RationalTime)? = nil) {
        self.sourceID = sourceID
        self.mediaURL = mediaURL
        self.extent = extent
        self.coverage = coverage
        self.preferences = preferences
        self.layouts = layouts
        self.layoutSource = layoutSource
        self.appearances = appearances
        feeds = people.map(TilesFeed.init)
        let overlap = Self.overlaps(appearances.lazy.map(\.range), limit: countHints?.maxVisibleTiles)
        let maximum = overlap.maximum
        counts = .init(feedCount: people.count, maxVisibleTiles: maximum)
        var issues = events
        var unassigned: [String: [MulticamRange]] = [:]
        for appearance in appearances where appearance.participantID == nil {
            unassigned[appearance.id, default: []].append(appearance.range)
        }
        for tile in unassigned.keys.sorted() {
            for (index, range) in Self.coalesced(unassigned[tile, default: []]).enumerated() {
                issues.append(.init(id: "unassigned-\(tile)-\(index)", kind: .unassignedTile,
                                    message: "Assign this tile to a feed.", range: range, sourceTime: range.from, tileID: tile))
            }
        }
        if let extent {
            let checked = coverage.lazy.filter { $0.state == .verified }.map(\.range)
            for (index, range) in Self.gaps(in: extent, among: checked).enumerated() {
                issues.append(.init(id: "unchecked-\(index)", kind: .uncheckedRange,
                                    message: "This source range was not verified frame by frame.", range: range, sourceTime: range.from))
            }
        }
        if let expected = countHints?.expectedFeeds, expected != people.count {
            issues.append(.init(id: "count-feeds", kind: .countMismatch,
                                message: "Expected \(expected) feeds, found \(people.count)."))
        }
        if let limit = countHints?.maxVisibleTiles, maximum > limit {
            for (index, span) in overlap.spans.enumerated() {
                let id = index == 0 ? "count-tiles" : "count-tiles-\(index)"
                issues.append(.init(id: id, kind: .countMismatch,
                                    message: "Expected at most \(limit) visible tiles, found up to \(maximum).",
                                    range: span, sourceTime: span.from))
            }
        }
        var groupSizes: [String: Int] = [:]
        for issue in issues where issue.decidesFeed {
            if let tile = issue.tileID { groupSizes[tile, default: 0] += 1 }
        }
        for index in issues.indices where issues[index].decidesFeed {
            guard let tile = issues[index].tileID else { continue }
            issues[index].groupID = "tile-\(tile)"
            issues[index].groupCount = groupSizes[tile]
        }
        self.issues = issues.sorted {
            let a = $0.sourceTime ?? .zero
            let b = $1.sourceTime ?? .zero
            return a == b ? $0.id < $1.id : a < b
        }
    }

    public func report(at time: RationalTime? = nil, range: MulticamRange? = nil, issuesOnly: Bool = false,
                       changesOnly: Bool = false) -> TilesInspection {
        func matches(_ interval: MulticamRange) -> Bool {
            if let time { return interval.contains(time) }
            if let range { return interval.from < range.to && range.from < interval.to }
            return true
        }
        let visible = issuesOnly || changesOnly ? [] : Array(appearances.lazy.filter { matches($0.range) }.map(TilesTile.init))
        let issues = time == nil && range == nil && !changesOnly ? issues : issues.filter { issue in
            if changesOnly && issue.kind != .layoutChange { return false }
            if let interval = issue.range { return matches(interval) }
            if let instant = issue.sourceTime {
                return time.map { $0 == instant } ?? range.map { $0.contains(instant) } ?? true
            }
            return true
        }
        let gaps: [MulticamRange]
        if let extent, !issuesOnly, !changesOnly {
            let ranges = appearances.lazy.map(\.range)
            if let time, range == nil {
                gaps = visible.isEmpty ? Self.gap(at: time, in: extent, among: ranges) : []
            } else {
                gaps = Self.gaps(in: extent, among: ranges).compactMap { gap in
                    guard matches(gap) else { return nil }
                    if let range { return .init(from: max(range.from, gap.from), to: min(range.to, gap.to)) }
                    return gap
                }
            }
        } else {
            gaps = []
        }
        return .init(sourceID: sourceID, sourceTime: time, range: range, counts: counts,
                     visibleTiles: time == nil || issuesOnly || changesOnly ? nil : visible.count,
                     tiles: visible, coverage: time == nil && range == nil ? coverage : coverage.filter { matches($0.range) }, gaps: gaps,
                     layouts: issuesOnly || changesOnly ? [] : layoutReport(at: time, range: range), issues: issues)
    }

    private func layoutReport(at time: RationalTime?, range: MulticamRange?) -> [TileLayoutListing] {
        guard time != nil || range != nil else { return layouts }
        return layouts.compactMap { listing -> TileLayoutListing? in
            let scope: MulticamRange
            let offset: RationalTime
            if listing.clock == "group" {
                guard let source = layoutSource else { return nil }
                offset = source.offset
                guard let covered = listing.range.participantIntersection(source.coverage ?? listing.range) else { return nil }
                scope = covered
            } else {
                guard listing.sourceID == sourceID else { return nil }
                offset = .zero
                scope = listing.range
            }
            func matches(_ candidate: MulticamRange) -> Bool {
                guard let active = candidate.participantIntersection(scope),
                      let start = try? active.from.subtracting(offset),
                      let end = try? active.to.subtracting(offset) else { return false }
                let input = MulticamRange(from: start, to: end)
                if let time { return input.contains(time) }
                return range.flatMap { input.participantIntersection($0) } != nil
            }
            guard matches(scope) else { return nil }
            var result = listing
            result.layouts = listing.layouts.filter { matches($0.range) }
            return result
        }
    }

    public func feed(id: String) throws -> TilesFeedInspection {
        guard let feed = feeds.first(where: { $0.feedID == id }) else {
            throw CutError(code: "unknown_feed", message: "Unknown feed ‘\(id)’ on this recording.")
        }
        let tiles = Array(appearances.lazy.filter { $0.participantID == id }.map(TilesTile.init))
        let ranges = tiles.lazy.map(\.range)
        let preferences = Array(preferences.lazy.filter { $0.participantID == id }.map {
            TilesPreference(tileID: $0.appearanceID, range: $0.range)
        })
        return .init(sourceID: sourceID, feed: feed, tiles: tiles, gaps: extent.map { Self.gaps(in: $0, among: ranges) } ?? [],
                     simultaneous: Self.overlaps(ranges, limit: 1).spans, preferences: preferences)
    }

    private static func coalesced(_ ranges: [MulticamRange]) -> [MulticamRange] {
        var result: [MulticamRange] = []
        for range in ranges.sorted(by: { $0.from < $1.from }) where range.from < range.to {
            if let last = result.last, range.from <= last.to {
                result[result.count - 1].to = max(last.to, range.to)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func gap(at time: RationalTime, in extent: MulticamRange,
                            among ranges: some Sequence<MulticamRange>) -> [MulticamRange] {
        guard extent.contains(time) else { return [] }
        var from = extent.from
        var to = extent.to
        for range in ranges where range.from < range.to {
            if range.to <= time { from = max(from, range.to) }
            if range.from > time { to = min(to, range.from) }
        }
        return [.init(from: from, to: to)]
    }

    private static func gaps(in extent: MulticamRange, among ranges: some Sequence<MulticamRange>) -> [MulticamRange] {
        var remaining = extent.from
        var gaps: [MulticamRange] = []
        let visible = ranges.lazy.filter { $0.from < $0.to && $0.to > extent.from && $0.from < extent.to }
        for range in visible.sorted(by: { $0.from < $1.from }) {
            if remaining < range.from { gaps.append(.init(from: remaining, to: range.from)) }
            remaining = max(remaining, range.to)
        }
        if remaining < extent.to { gaps.append(.init(from: remaining, to: extent.to)) }
        return gaps
    }

    private static func overlaps(_ ranges: some Sequence<MulticamRange>, limit: Int?)
        -> (maximum: Int, spans: [MulticamRange]) {
        var edges: [RationalTime: Int] = [:]
        for range in ranges where range.from < range.to {
            edges[range.from, default: 0] += 1
            edges[range.to, default: 0] -= 1
        }
        var count = 0
        var maximum = 0
        var spans: [MulticamRange] = []
        var start: RationalTime?
        for time in edges.keys.sorted() {
            count += edges[time, default: 0]
            maximum = max(maximum, count)
            if let limit, count > limit {
                if start == nil { start = time }
            } else if let from = start {
                spans.append(.init(from: from, to: time))
                start = nil
            }
        }
        return (maximum, spans)
    }
}
