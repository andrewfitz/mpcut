import Foundation

/// The ordered view of one project clock. Word, speaker and track IDs belong to
/// their attachment. Occurrence IDs already carry that attachment's namespace.
public struct TranscriptProjectIndex: Sendable {
    public let attachmentResults: [String: String]
    private let index: TranscriptIndex.WordIndex
    private let space: TranscriptSpace
    private let language: String?
    private let inputCoverageProviders: [@Sendable (TranscriptSpace, TranscriptFilter) throws -> TranscriptInputCoverageRows]

    public init(indexes: [TranscriptIndex], space: TranscriptSpace) {
        attachmentResults = Dictionary(indexes.compactMap { item in
            item.attachment.map { ($0.id, $0.resultID) }
        }, uniquingKeysWith: { first, _ in first })
        self.space = space
        language = indexes.first?.document.provenance?.language
        inputCoverageProviders = indexes.map(\.inputCoverageProvider)
        gaps = Self.mergeCoverage(indexes.map(\.gaps))
        if indexes.count == 1, let only = indexes.first?.indexes[space] {
            index = only
        } else {
            // A still card or silence separates phrases however many transcripts are attached.
            index = .init(indexes.flatMap { $0.indexes[space]?.words ?? [] }, space: space,
                          gaps: space == .currentCut ? gaps : [], usesMix: indexes.first?.usesMix == true)
        }
    }

    public func inputCoverage(filter: TranscriptFilter = .init(), offset: Int = 0, limit: Int = 100,
                              trackOffset: Int? = nil, trackLimit: Int? = nil) throws -> TranscriptInputCoverageReport {
        if inputCoverageProviders.count == 1, let provider = inputCoverageProviders.first {
            return try .paged(provider(space, filter), offset: offset, limit: limit,
                              trackOffset: trackOffset, trackLimit: trackLimit)
        }
        var rows = TranscriptInputCoverageRows()
        for provider in inputCoverageProviders {
            let part = try provider(space, filter)
            rows.gaps.append(contentsOf: part.gaps)
            rows.tracks.append(contentsOf: part.tracks)
        }
        rows.gaps.sort {
            if $0.range.from != $1.range.from { return $0.range.from < $1.range.from }
            if $0.range.to != $1.range.to { return $0.range.to < $1.range.to }
            if $0.attachmentID != $1.attachmentID { return ($0.attachmentID ?? "") < ($1.attachmentID ?? "") }
            return ($0.trackID ?? "") < ($1.trackID ?? "")
        }
        return .paged(rows, offset: offset, limit: limit, trackOffset: trackOffset, trackLimit: trackLimit)
    }

    /// Gaps no attached transcript covers, merged once for reading and for phrase search.
    public let gaps: [TranscriptCoverageGap]

    static func mergeCoverage(_ coverage: [[TranscriptCoverageGap]]) -> [TranscriptCoverageGap] {
        guard coverage.count > 1 else { return coverage.first ?? [] }
        struct Route: Hashable {
            let assembly: Int?
            let clip: String?
            let source: String?
            let lane: String?

            init(_ gap: TranscriptCoverageGap) {
                assembly = gap.assemblyIndex
                clip = gap.clipID
                source = gap.sourceID
                lane = gap.laneID
            }
        }
        struct Event {
            let time: RationalTime
            let attachment: Int
            let exactReason: TranscriptGapReason?
            let delta: Int
        }
        var routes: [Route: [(Int, TranscriptCoverageGap)]] = [:]
        for (attachment, gaps) in coverage.enumerated() {
            for gap in gaps where gap.range.from < gap.range.to {
                routes[Route(gap), default: []].append((attachment, gap))
            }
        }
        var result: [TranscriptCoverageGap] = []
        let reasons: [TranscriptGapReason] = [.failed, .changed, .unavailable, .skipped, .silence, .still, .unbound]
        for (route, rows) in routes {
            let streams = Set(rows.map { $0.1.streamIndex })
            for stream in streams {
                var events: [Event] = []
                for (attachment, gap) in rows where gap.streamIndex == stream || gap.streamIndex == nil {
                    let reason = gap.streamIndex == stream ? gap.reason : nil
                    events.append(Event(time: gap.range.from, attachment: attachment, exactReason: reason, delta: 1))
                    events.append(Event(time: gap.range.to, attachment: attachment, exactReason: reason, delta: -1))
                }
                events.sort { $0.time < $1.time }
                var active: [Int: Int] = [:]
                var reasonCounts: [TranscriptGapReason: Int] = [:]
                var previous: RationalTime?
                for event in events {
                    if let previous, previous < event.time, active.count == coverage.count,
                       let reason = reasons.first(where: { reasonCounts[$0, default: 0] > 0 }) {
                        let metadata = rows.first?.1
                        result.append(.init(range: .init(from: previous, to: event.time), laneID: route.lane,
                                            laneOrder: metadata?.laneOrder, laneLabel: metadata?.laneLabel,
                                            laneColorSlot: metadata?.laneColorSlot, assemblyIndex: route.assembly,
                                            clipID: route.clip, sourceID: route.source, streamIndex: stream, reason: reason))
                    }
                    active[event.attachment, default: 0] += event.delta
                    if active[event.attachment] == 0 { active.removeValue(forKey: event.attachment) }
                    if let reason = event.exactReason { reasonCounts[reason, default: 0] += event.delta }
                    previous = event.time
                }
            }
        }
        return result.sorted {
            if $0.range.from != $1.range.from { return $0.range.from < $1.range.from }
            if $0.range.to != $1.range.to { return $0.range.to < $1.range.to }
            if $0.assemblyIndex != $1.assemblyIndex { return ($0.assemblyIndex ?? -1) < ($1.assemblyIndex ?? -1) }
            if $0.clipID != $1.clipID { return ($0.clipID ?? "") < ($1.clipID ?? "") }
            if $0.sourceID != $1.sourceID { return ($0.sourceID ?? "") < ($1.sourceID ?? "") }
            if $0.laneOrder != $1.laneOrder { return ($0.laneOrder ?? -1) < ($1.laneOrder ?? -1) }
            if $0.laneID != $1.laneID { return ($0.laneID ?? "") < ($1.laneID ?? "") }
            return ($0.streamIndex ?? -1) < ($1.streamIndex ?? -1)
        }
    }

    public func read(filter: TranscriptFilter = .init(), offset: Int = 0,
                     limit: Int = 100) -> TranscriptPage<TranscriptOccurrence> {
        TranscriptIndex.read(index, filter: filter, offset: offset, limit: limit)
    }

    public func readAll(filter: TranscriptFilter = .init()) -> [TranscriptOccurrence] {
        filter.isUnrestricted ? index.words : index.words.filter { TranscriptIndex.matches($0, filter: filter) }
    }

    public func locate(wordID: String, filter: TranscriptFilter = .init()) -> [TranscriptOccurrence] {
        (index.byWord[wordID] ?? []).map { index.words[$0] }.filter { TranscriptIndex.matches($0, filter: filter) }
    }

    public func occurrence(id: String, filter: TranscriptFilter = .init()) -> TranscriptOccurrence? {
        guard let position = index.byID[id] else { return nil }
        let word = index.words[position]
        return TranscriptIndex.matches(word, filter: filter) ? word : nil
    }

    public func search(_ query: String, filter: TranscriptFilter = .init(), offset: Int = 0,
                       limit: Int = 100) -> TranscriptPage<TranscriptMatch> {
        index.find(query, language: language, filter: filter,
                   offset: max(0, offset), limit: min(500, max(1, limit)))
    }
}
