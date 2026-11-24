import Foundation
import NaturalLanguage

public enum TranscriptSpace: String, Codable, CaseIterable, Sendable {
    case source, group, currentCut = "current_cut"
}

public enum TranscriptAudibility: String, Codable, Sendable {
    case source, recognized, inferred
}

public struct TranscriptOccurrence: Codable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
        case wordID = "word_id"
        case attachmentID = "attachment_id"
        case space
        case text
        case speakerID = "speaker_id"
        case speakerName = "speaker_name"
        case textReplacementID = "text_replacement_id"
        case originalText = "original_text"
        case originalSpeakerID = "original_speaker_id"
        case precision
        case utteranceID = "utterance_id"
        case observation
        case observations
        case matchReviews = "match_reviews"
        case trackSources = "track_sources"
        case candidateTrackIDs = "candidate_track_ids"
        case file
        case binding
        case bindingStatus = "binding_status"
        case originalSourceRange = "original_source_range"
        case sequenceSourceRange = "sequence_source_range"
        case angles
        case range
        case sourceRange = "source_range"
        case groupRange = "group_range"
        case assemblyIndex = "assembly_index"
        case clipID = "clip_id"
        case sourceID = "source_id"
        case trackID = "track_id"
        case streamIndex = "audio_stream_index"
        case sequenceStreamOrdinal = "sequence_stream_ordinal"
        case laneID = "lane_id"
        case laneOrder = "lane_order"
        case laneLabel = "lane_label"
        case laneColorSlot = "lane_color_slot"
        case heardOnLaneIDs = "heard_on_lane_ids"
        case routedSourceID = "routed_source_id"
        case routedStreamIndex = "routed_stream_index"
        case audibility
        case partial
        case approximate
        case staleMatches = "stale_matches"
        case timelineRevision = "timeline_revision"
    }
    public let id: String
    public let wordID: String
    public var attachmentID: String? = nil
    public var space: TranscriptSpace? = nil
    public var text: String
    public var speakerID: String?
    public var speakerName: String? = nil
    public var textReplacementID: String? = nil
    public let originalText: String
    public let originalSpeakerID: String?
    public let precision: TranscriptPrecision
    public let utteranceID: String?
    public let observation: TranscriptObservation?
    public var observations: [TranscriptObservation] = []
    public var matchReviews: [TranscriptMatchReview]? = nil
    var trackSources: [String: String] = [:]
    public let candidateTrackIDs: [String]
    public let file: String?
    public let binding: TranscriptBinding?
    public let bindingStatus: TranscriptBindingStatus?
    public let originalSourceRange: MulticamRange?
    public let sequenceSourceRange: MulticamRange?
    public let angles: [TranscriptAngleCoverage]
    public let range: MulticamRange
    public let sourceRange: MulticamRange?
    public let groupRange: MulticamRange?
    public let assemblyIndex: Int?
    public let clipID: String?
    public let sourceID: String?
    public let trackID: String?
    public let streamIndex: Int?
    var sequenceStreamOrdinal: Int? = nil
    public var laneID: String? = nil
    public var laneOrder: Int? = nil
    public var laneLabel: String? = nil
    public var laneColorSlot: Int? = nil
    public var heardOnLaneIDs: [String]? = nil
    var trackLanes: [String: String]? = nil
    var alternateLaneHearings: [TranscriptOccurrence]? = nil
    public let routedSourceID: String?
    public let routedStreamIndex: Int?
    public var audibility: TranscriptAudibility
    public let partial: Bool
    public let approximate: Bool
    public let staleMatches: Bool
    public let timelineRevision: Int
}

public struct TranscriptFilter: Codable, Sendable {
    public var speakerID: String?
    public var sourceID: String?
    public var trackID: String?
    public var assemblyIndex: Int?
    public var clipID: String?
    public var file: String?
    public var laneID: String?
    public var includeInferred: Bool

    public init(speakerID: String? = nil, sourceID: String? = nil, trackID: String? = nil,
                assemblyIndex: Int? = nil, clipID: String? = nil, file: String? = nil, includeInferred: Bool = false, laneID: String? = nil) {
        self.speakerID = speakerID
        self.sourceID = sourceID
        self.trackID = trackID
        self.assemblyIndex = assemblyIndex
        self.clipID = clipID
        self.file = file
        self.laneID = laneID
        self.includeInferred = includeInferred
    }

    private enum CodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case sourceID = "source_id"
        case trackID = "track_id"
        case assemblyIndex = "assembly_index"
        case clipID = "clip_id"
        case file
        case laneID = "lane_id"
        case includeInferred = "include_inferred"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_filter")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(speakerID: try values.decodeIfPresent(String.self, forKey: .speakerID),
                  sourceID: try values.decodeIfPresent(String.self, forKey: .sourceID),
                  trackID: try values.decodeIfPresent(String.self, forKey: .trackID),
                  assemblyIndex: try values.decodeIfPresent(Int.self, forKey: .assemblyIndex),
                  clipID: try values.decodeIfPresent(String.self, forKey: .clipID),
                  file: try values.decodeIfPresent(String.self, forKey: .file),
                  includeInferred: try values.decodeIfPresent(Bool.self, forKey: .includeInferred) ?? false,
                  laneID: try values.decodeIfPresent(String.self, forKey: .laneID))
    }

    var isUnrestricted: Bool {
        speakerID == nil && sourceID == nil && trackID == nil
            && assemblyIndex == nil && clipID == nil && file == nil && laneID == nil
    }

    fileprivate func accepts(_ item: borrowing TranscriptOccurrence) -> Bool {
        guard speakerID == nil || speakerID == item.speakerID,
              assemblyIndex == nil || assemblyIndex == item.assemblyIndex,
              clipID == nil || clipID == item.clipID,
              file == nil || file == item.file else { return false }
        let primary = (laneID == nil || laneID == item.laneID) && (trackID == nil || trackID == item.trackID) && (sourceID == nil || sourceID == item.sourceID)
        if primary && (trackID == nil || includeInferred || item.audibility != .inferred) { return true }
        return item.observations.contains {
            (trackID == nil || trackID == $0.trackID)
                && (laneID == nil || laneID == item.trackLanes?[$0.trackID])
                && (sourceID == nil || sourceID == item.trackSources[$0.trackID])
                && (trackID == nil || includeInferred || $0.evidence == .recognized)
        }
    }
}

public struct TranscriptPage<Item: Codable & Sendable>: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case items
        case total
        case nextOffset = "next_offset"
    }
    public let items: [Item]
    public let total: Int
    public let nextOffset: Int?

    init(items: [Item], total: Int, offset: Int) {
        self.items = items
        self.total = total
        let end = offset + items.count
        self.nextOffset = end < total ? end : nil
    }
}

public struct TranscriptMatch: Codable, Sendable {
    public let words: [TranscriptOccurrence]
    public let before: [TranscriptOccurrence]
    public let after: [TranscriptOccurrence]
}

public struct TranscriptIndex: Sendable {
    package final class CacheIdentity: Sendable {}

    package let cacheIdentity = CacheIdentity()
    let indexes: Clocks
    public let document: TranscriptDocument
    public let timelineRevision: Int
    public let attachment: TranscriptAttachment?
    public let transcriptRevision: UInt64?
    public let speakers: [TranscriptSpeaker]
    public let authoredReview: [TranscriptAuthoredReview]
    let inputCoverageProvider: @Sendable (TranscriptSpace, TranscriptFilter) throws -> TranscriptInputCoverageRows
    /// Whether matches across tracks are out of date, as the first Source or Group word
    /// reports it. An index knows this whichever clocks it has built.
    public let staleMatches: Bool

    init(clocks: [TranscriptSpace: WordIndex], gaps: [TranscriptCoverageGap], document: TranscriptDocument,
         timelineRevision: Int, attachment: TranscriptAttachment?, transcriptRevision: UInt64?,
         speakers: [TranscriptSpeaker], authoredReview: [TranscriptAuthoredReview],
         inputCoverageProvider: @escaping @Sendable (TranscriptSpace, TranscriptFilter) throws -> TranscriptInputCoverageRows,
         usesMix: Bool, staleLead: Bool?) {
        self.indexes = Clocks(clocks, gaps: gaps)
        self.document = document
        self.timelineRevision = timelineRevision
        self.attachment = attachment
        self.transcriptRevision = transcriptRevision
        self.speakers = speakers
        self.authoredReview = authoredReview
        self.inputCoverageProvider = inputCoverageProvider
        self.usesMix = usesMix
        self.staleMatches = staleLead ?? [TranscriptSpace.source, .group].contains {
            clocks[$0]?.words.first?.staleMatches == true
        }
    }

    public func inputCoverage(space: TranscriptSpace, filter: TranscriptFilter = .init(),
                              offset: Int = 0, limit: Int = 100,
                              trackOffset: Int? = nil, trackLimit: Int? = nil) throws -> TranscriptInputCoverageReport {
        try .paged(inputCoverageProvider(space, filter), offset: offset, limit: limit,
                   trackOffset: trackOffset, trackLimit: trackLimit)
    }

    /// The stretches of Current Cut that no transcript covers.
    public var gaps: [TranscriptCoverageGap] { indexes.gaps }
    let usesMix: Bool

    public func read(space: TranscriptSpace, filter: TranscriptFilter = .init(),
                     offset: Int = 0, limit: Int = 100) -> TranscriptPage<TranscriptOccurrence> {
        guard let index = indexes[space] else { return .init(items: [], total: 0, offset: 0) }
        return Self.read(index, filter: filter, offset: offset, limit: limit)
    }

    static func read(_ index: WordIndex, filter: TranscriptFilter, offset: Int, limit: Int) -> TranscriptPage<TranscriptOccurrence> {
        let offset = max(0, offset)
        let limit = min(500, max(1, limit))
        if filter.isUnrestricted {
            return .init(items: Array(index.words.dropFirst(offset).prefix(limit)), total: index.words.count, offset: offset)
        }
        let words = index.words
        var items: [TranscriptOccurrence] = []
        var count = 0
        for position in words.indices where filter.accepts(words[position]) {
            if count >= offset, items.count < limit { items.append(words[position]) }
            count += 1
        }
        return .init(items: items, total: count, offset: offset)
    }

    static func matches(_ occurrence: TranscriptOccurrence, filter: TranscriptFilter) -> Bool {
        filter.accepts(occurrence)
    }

    public func locate(wordID: String, space: TranscriptSpace, filter: TranscriptFilter = .init()) -> [TranscriptOccurrence] {
        guard let index = indexes[space] else { return [] }
        let words = (index.byWord[wordID] ?? []).map { index.words[$0] }
        return filter.isUnrestricted ? words : words.filter(filter.accepts)
    }

    public func readAll(space: TranscriptSpace, filter: TranscriptFilter = .init()) -> [TranscriptOccurrence] {
        guard let words = indexes[space]?.words else { return [] }
        return filter.isUnrestricted ? words : words.filter(filter.accepts)
    }

    public func position(at time: RationalTime, space: TranscriptSpace) -> Int? {
        indexes[space]?.positions(at: time).first
    }

    /// Words sounding at the playhead, newest onset first (the reader's scroll target).
    package func activeWords(at time: RationalTime, space: TranscriptSpace) -> [TranscriptOccurrence] {
        guard let index = indexes[space] else { return [] }
        return index.positions(at: time, forPlayback: true).map { index.words[$0] }
    }

    public func position(of occurrenceID: String, space: TranscriptSpace) -> Int? {
        indexes[space]?.byID[occurrenceID]
    }

    package func overlapping(_ range: MulticamRange, space: TranscriptSpace) -> [TranscriptOccurrence] {
        indexes[space]?.overlapping(range) ?? []
    }

    public func occurrence(id: String, space: TranscriptSpace, filter: TranscriptFilter = .init()) -> TranscriptOccurrence? {
        guard let index = indexes[space], let position = index.byID[id] else { return nil }
        let word = index.words[position]
        return filter.isUnrestricted || filter.accepts(word) ? word : nil
    }

    public func search(_ query: String, space: TranscriptSpace, filter: TranscriptFilter = .init(),
                       offset: Int = 0, limit: Int = 100) -> TranscriptPage<TranscriptMatch> {
        guard let index = indexes[space] else { return .init(items: [], total: 0, offset: 0) }
        return index.find(query, language: document.provenance?.language, filter: filter,
                          offset: max(0, offset), limit: min(500, max(1, limit)))
    }

    /// Scans once for a reader that will request several pages of the same search.
    public func prepareSearch(_ query: String, space: TranscriptSpace, filter: TranscriptFilter = .init()) throws -> PreparedSearch {
        try Task.checkCancellation()
        let index = indexes[space]?.searchIndex(for: filter)
        let hits = index?.findHits(query, language: document.provenance?.language, filter: filter,
                                   offset: 0, limit: Int.max, cancellable: true).items ?? []
        try Task.checkCancellation()
        return PreparedSearch(index: index, hits: hits)
    }

    public struct PreparedSearch: Sendable {
        fileprivate let index: WordIndex?
        fileprivate let hits: [SearchHit]

        public func page(offset: Int = 0, limit: Int = 100) -> TranscriptPage<TranscriptMatch> {
            guard let index else { return .init(items: [], total: 0, offset: 0) }
            let offset = max(0, offset)
            let limit = min(500, max(1, limit))
            let items = hits.dropFirst(offset).prefix(limit).map(index.match)
            return .init(items: items, total: hits.count, offset: offset)
        }
    }

    fileprivate struct SearchHit: Sendable {
        let context: (lane: Int, tokens: Range<Int>)?
        let positions: [Int]
    }

    fileprivate struct SearchHitPage {
        let items: [SearchHit]
        let total: Int
    }

    /// The phrase with one adjacent pair joined, then with one word split into two known words.
    static func compoundVariants(_ phrase: [String], known: (String) -> Bool) -> [[String]] {
        var variants: [[String]] = []
        for index in phrase.indices.dropLast() {
            let joined = phrase[index] + phrase[index + 1]
            if known(joined) {
                variants.append(Array(phrase[..<index]) + [joined] + Array(phrase[(index + 2)...]))
            }
        }
        for (index, token) in phrase.enumerated() where token.count >= 4 && token.count <= 32 {
            let characters = Array(token)
            for cut in 2...(characters.count - 2) {
                let (head, tail) = (String(characters[..<cut]), String(characters[cut...]))
                if known(head), known(tail) {
                    variants.append(Array(phrase[..<index]) + [head, tail] + Array(phrase[(index + 1)...]))
                }
            }
        }
        return variants
    }

    private static let searchLocale = Locale(identifier: "en_US_POSIX")

    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: searchLocale)
        // Apostrophes inside words are part of the same searchable token.
        let canonical = folded.filter { $0 != "'" && $0 != "’" }
        return canonical.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    struct WordIndex: Sendable {
        private struct Lane: Hashable {
            let attachment: String?
            let source: String?
            let track: String?
            let speaker: String?
            let ordinal: Int?
        }

        private struct GapLane: Hashable {
            let clip: String?
            let stream: Int?
        }

        private struct GapIndex {
            let ranges: [MulticamRange]
            let latestEnd: [RationalTime]

            init(_ ranges: [MulticamRange]) {
                self.ranges = ranges
                var end = ranges.first?.to ?? .zero
                self.latestEnd = ranges.map { range in
                    end = max(end, range.to)
                    return end
                }
            }

            func separates(_ left: RationalTime, _ right: RationalTime) -> Bool {
                guard left < right else { return false }
                let first = latestEnd.lowerBound { $0 > left }
                return first < ranges.count && ranges[first].from < right
            }
        }

        private struct Token: Sendable {
            let text: String
            let word: Int
        }

        private struct Posting: Sendable {
            let lane: Int
            let token: Int
        }

        let words: [TranscriptOccurrence]
        let byWord: [String: [Int]]
        let byID: [String: Int]
        private let latestEnd: [RationalTime]
        private let alternateHearings: TranscriptRangeIndex?
        private let lanes: [[Token]]
        private let postings: [String: [Posting]]
        private let continuations: [Int: [Int]]
        private let laneSearchCache: LaneSearchCache?
        private let searchLane: String?

        /// A lane filter changes adjacency. Keep the most recently searched lane's
        /// token index without adding a second set of postings to every transcript.
        private final class LaneSearchCache: @unchecked Sendable {
            let gaps: [TranscriptCoverageGap]
            private let lock = NSLock()
            private var latest: (lane: String, index: WordIndex)?

            init(gaps: [TranscriptCoverageGap]) {
                self.gaps = gaps
            }

            func index(for lane: String, in words: [TranscriptOccurrence]) -> WordIndex {
                let cached = lock.withLock { latest }
                if let cached, cached.lane == lane { return cached.index }
                let filter = TranscriptFilter(laneID: lane)
                let index = WordIndex(words.filter { filter.accepts($0) }, space: .currentCut,
                                      gaps: gaps, usesMix: true, searchLane: lane)
                lock.withLock { latest = (lane, index) }
                return index
            }
        }

        fileprivate func searchIndex(for filter: TranscriptFilter) -> WordIndex {
            guard let lane = filter.laneID, let laneSearchCache else { return self }
            return laneSearchCache.index(for: lane, in: words)
        }

        private static func alternateHearing(in word: borrowing TranscriptOccurrence, on lane: String?) -> TranscriptOccurrence? {
            guard let lane, word.laneID != lane else { return nil }
            return word.alternateLaneHearings?.first { $0.laneID == lane }
        }

        private static func searchRange(_ word: borrowing TranscriptOccurrence, on lane: String?) -> MulticamRange {
            alternateHearing(in: word, on: lane)?.range ?? word.range
        }

        private func searchTrack(at position: Int) -> String? {
            Self.alternateHearing(in: words[position], on: searchLane)?.trackID ?? words[position].trackID
        }

        /// Takes over `occurrences`. A caller that keeps no other reference to the list lets
        /// it be ordered and labelled in place; each occurrence is several hundred bytes with
        /// dozens of references, and a shared list is copied whole before its first change.
        init(_ occurrences: consuming [TranscriptOccurrence], space: TranscriptSpace, gaps: [TranscriptCoverageGap] = [],
             usesMix: Bool = false, searchLane: String? = nil) {
            self.searchLane = searchLane
            laneSearchCache = usesMix && space == .currentCut && searchLane == nil ? LaneSearchCache(gaps: gaps) : nil
            let allGaps = gaps.filter { $0.clipID == nil && (!usesMix || $0.laneID == nil) &&
                ($0.reason == .still || $0.reason == .silence || $0.reason == .unavailable ||
                 $0.reason == .unbound || $0.reason == .skipped || $0.reason == .failed || $0.reason == .changed) }
            let barriers = GapIndex(allGaps.map(\.range))
            let streamBarriers = Dictionary(grouping: gaps.filter { $0.clipID != nil && $0.reason == .unavailable }) {
                GapLane(clip: $0.clipID, stream: $0.streamIndex)
            }.mapValues { GapIndex($0.map(\.range)) }
            let laneBarriers = Dictionary(grouping: gaps.compactMap { gap in
                gap.laneID.map { ($0, gap.range) }
            }, by: \.0).mapValues { GapIndex($0.map(\.1)) }
            var ordered = consume occurrences
            ordered.sort {
                let first = Self.searchRange($0, on: searchLane)
                let second = Self.searchRange($1, on: searchLane)
                if first.from != second.from { return first.from < second.from }
                if first.to != second.to { return first.to < second.to }
                return $0.id < $1.id
            }
            for position in ordered.indices where ordered[position].space != space { ordered[position].space = space }
            let words = ordered
            self.words = words
            if usesMix && space == .currentCut && searchLane == nil {
                let positions = words.indices.filter { words[$0].alternateLaneHearings != nil }
                alternateHearings = positions.isEmpty ? nil : TranscriptRangeIndex(positions, range: { position in
                    let word = words[position]
                    return (word.alternateLaneHearings ?? []).reduce(word.range) { range, hearing in
                        .init(from: min(range.from, hearing.range.from), to: max(range.to, hearing.range.to))
                    }
                }, id: { words[$0].id })
            } else {
                alternateHearings = nil
            }
            var latest = words.first?.range.to ?? .zero
            self.latestEnd = words.map {
                latest = max(latest, $0.range.to)
                return latest
            }
            var byWord: [String: [Int]] = [:]
            var byID: [String: Int] = [:]
            var laneByKey: [Lane: Int] = [:]
            var lanes: [[Token]] = []
            var postings: [String: [Posting]] = [:]
            var continuations: [Int: [Int]] = [:]
            // Reuse Unicode tokenization across repeated words without keeping
            // a second vocabulary alive after the index has been built.
            var tokenCache: [String: [String]] = [:]
            let tokenCacheLimit = 4_096
            var replacementStartByLane: [Int: Int] = [:]
            var adjacentByLane: [Int: (start: Int, end: Int)] = [:]
            // Keep normal pauses and overlap. A distinct utterance can make a
            // shorter gap a genuine break, but utterance IDs alone are not seams.
            let pauseLimit = RationalTime(numerator: 2)
            let utterancePauseLimit = RationalTime(numerator: 1)

            // The loop reads fields of the stored words in place. Binding a whole occurrence
            // to a name copies it, which costs more than everything else done per word.
            func continues(_ previous: Int, _ next: Int) -> Bool {
                let from = Self.searchRange(words[previous], on: searchLane).to
                let to = Self.searchRange(words[next], on: searchLane).from
                guard from < to else { return true }
                let sameEditInterval = words[previous].clipID == words[next].clipID
                    && words[previous].assemblyIndex == words[next].assemblyIndex
                let changedUtterance = words[previous].utteranceID != nil && words[next].utteranceID != nil
                    && words[previous].utteranceID != words[next].utteranceID
                let limit = sameEditInterval && changedUtterance ? utterancePauseLimit : pauseLimit
                guard let pause = try? to.subtracting(from), pause <= limit else { return false }
                if barriers.separates(from, to) { return false }
                let sharedLane = searchLane ?? (words[previous].laneID == words[next].laneID ? words[previous].laneID : nil)
                if let lane = sharedLane,
                   laneBarriers[lane]?.separates(from, to) == true { return false }
                let previousStream = GapLane(clip: words[previous].clipID, stream: words[previous].streamIndex)
                let nextStream = GapLane(clip: words[next].clipID, stream: words[next].streamIndex)
                return streamBarriers[previousStream]?.separates(from, to) != true
                    && streamBarriers[nextStream]?.separates(from, to) != true
            }
            /// Whether two touching pieces of one word read as a single word. They do inside one
            /// edit interval, and across a cut that removed nothing: a blade through a word leaves
            /// its two halves in adjacent clips, and the phrase around it is still spoken once.
            func joins(_ previous: Int, _ next: Int) -> Bool {
                if words[previous].clipID == words[next].clipID,
                   words[previous].assemblyIndex == words[next].assemblyIndex { return true }
                let left = Self.alternateHearing(in: words[previous], on: searchLane) ?? words[previous]
                let right = Self.alternateHearing(in: words[next], on: searchLane) ?? words[next]
                guard let leftRange = left.sourceRange, let rightRange = right.sourceRange else { return false }
                return leftRange.to == rightRange.from && left.trackID == right.trackID
                    && left.file == right.file && left.sourceID == right.sourceID
            }
            byID.reserveCapacity(words.count)
            for position in words.indices {
                byWord[words[position].wordID, default: []].append(position)
                byID[words[position].id] = position
                let ordinal = space == .currentCut ? words[position].sequenceStreamOrdinal : nil
                let needsTrack = space == .source || (words[position].clipID != nil && ordinal == nil)
                let key = Lane(attachment: words[position].attachmentID,
                               source: space == .source ? words[position].sourceID : nil,
                               track: needsTrack ? words[position].trackID : nil,
                               speaker: words[position].speakerID, ordinal: ordinal)
                let lane: Int
                if let existing = laneByKey[key], let tail = adjacentByLane[existing]?.end,
                   continues(tail, position) {
                    lane = existing
                } else {
                    lane = lanes.count
                    laneByKey[key] = lane
                    lanes.append([])
                }
                let text = words[position].text
                if let adjacent = adjacentByLane[lane], words[adjacent.start].wordID == words[position].wordID,
                   words[adjacent.start].text == text,
                   Self.searchRange(words[adjacent.end], on: searchLane).to == Self.searchRange(words[position], on: searchLane).from,
                   joins(adjacent.end, position) {
                    continuations[adjacent.start, default: []].append(position)
                    adjacentByLane[lane] = (adjacent.start, position)
                    continue
                }
                adjacentByLane[lane] = (position, position)

                if let replacement = words[position].textReplacementID, text.isEmpty {
                    if let start = replacementStartByLane[lane], words[start].textReplacementID == replacement {
                        continuations[start, default: []].append(position)
                    }
                } else if words[position].textReplacementID != nil {
                    replacementStartByLane[lane] = position
                } else {
                    replacementStartByLane[lane] = nil
                }
                let tokens: [String]
                if let cached = tokenCache[text] {
                    tokens = cached
                } else {
                    tokens = TranscriptIndex.tokens(text)
                    if tokenCache.count < tokenCacheLimit { tokenCache[text] = tokens }
                }
                for text in tokens {
                    postings[text, default: []].append(.init(lane: lane, token: lanes[lane].count))
                    lanes[lane].append(.init(text: text, word: position))
                }
            }
            self.byWord = byWord
            self.byID = byID
            self.lanes = lanes
            self.postings = postings
            self.continuations = continuations
        }

        /// Phrase search. A number in the query also finds every other way this transcript writes
        /// the same number, so "200 hours" finds "two hundred hours". With nothing found, the
        /// phrase is retried with one compound closed or opened: a recognizer writes "range finder"
        /// where a script has "rangefinder", and the reverse.
        func find(_ query: String, language: String?, filter: TranscriptFilter, offset: Int,
                  limit: Int) -> TranscriptPage<TranscriptMatch> {
            let index = searchIndex(for: filter)
            let page = index.findHits(query, language: language, filter: filter, offset: offset, limit: limit, cancellable: false)
            return .init(items: page.items.map(index.match), total: page.total, offset: offset)
        }

        fileprivate func findHits(_ query: String, language: String?, filter: TranscriptFilter, offset: Int,
                                  limit: Int, cancellable: Bool) -> SearchHitPage {
            let phrase = TranscriptIndex.tokens(query)
            guard !phrase.isEmpty else { return .init(items: [], total: 0) }
            let numbered = numberVariants(of: query, language: language)
            let exact = numbered.isEmpty
                ? search(phrase, filter: filter, offset: offset, limit: limit, cancellable: cancellable)
                : search(anyOf: [phrase] + numbered, filter: filter, offset: offset, limit: limit, cancellable: cancellable)
            guard exact.total == 0 else { return exact }
            for variant in TranscriptIndex.compoundVariants(phrase, known: { postings[$0] != nil }) {
                let found = search(variant, filter: filter, offset: offset, limit: limit, cancellable: cancellable)
                if found.total > 0 { return found }
            }
            let crosstalk = searchThroughCrosstalk(phrase, filter: filter, offset: offset, limit: limit, cancellable: cancellable)
            return crosstalk.total > 0 ? crosstalk : exact
        }

        /// Two people talking over each other share a lane when one speaker label covers both,
        /// and their words alternate in time order. Follow the phrase on the microphone that
        /// heard its first word, stepping over the words another microphone supplied.
        private func searchThroughCrosstalk(_ phrase: [String], filter: TranscriptFilter, offset: Int,
                                            limit: Int, cancellable: Bool) -> SearchHitPage {
            let interruptionLimit = 12
            var items: [SearchHit] = []
            var previous: [Int] = []
            var count = 0
            let unrestricted = filter.isUnrestricted
            candidates: for posting in postings[phrase[0]] ?? [] {
                if cancellable && Task.isCancelled { break }
                let lane = lanes[posting.lane]
                guard let track = searchTrack(at: lane[posting.token].word) else { continue }
                var positions: [Int] = []
                var matched = 0
                var stepped = 0
                var cursor = posting.token
                while matched < phrase.count {
                    guard cursor < lane.count else { continue candidates }
                    let token = lane[cursor]
                    cursor += 1
                    guard searchTrack(at: token.word) == track else {
                        stepped += 1
                        if stepped > interruptionLimit { continue candidates }
                        continue
                    }
                    guard token.text == phrase[matched] else { continue candidates }
                    matched += 1
                    if positions.last != token.word { positions.append(token.word) }
                }
                guard stepped > 0, unrestricted || positions.allSatisfy({ filter.accepts(words[$0]) }),
                      previous != positions else { continue }
                if count >= offset, items.count < limit { items.append(.init(context: nil, positions: positions)) }
                count += 1
                previous = positions
            }
            return .init(items: items, total: count)
        }

        func overlapping(_ range: MulticamRange) -> [TranscriptOccurrence] {
            var lower = 0
            var upper = words.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if latestEnd[middle] <= range.from { lower = middle + 1 } else { upper = middle }
            }
            var positions: [Int] = []
            while lower < words.count, words[lower].range.from < range.to {
                if words[lower].range.to > range.from { positions.append(lower) }
                lower += 1
            }
            if let alternateHearings {
                positions = Set(positions).union(alternateHearings.overlapping(range)).sorted()
            }
            return positions.flatMap { position -> [TranscriptOccurrence] in
                let word = words[position]
                if word.range.from < range.to && range.from < word.range.to { return [word] }
                return (word.alternateLaneHearings ?? []).filter {
                    $0.range.from < range.to && range.from < $0.range.to
                }
            }
        }

        func positions(at time: RationalTime, forPlayback: Bool = false) -> [Int] {
            var lower = 0
            var upper = words.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if words[middle].range.from <= time { lower = middle + 1 } else { upper = middle }
            }
            var result: [Int] = []
            var index = lower
            while index > 0, latestEnd[index - 1] > time {
                index -= 1
                if words[index].range.contains(time) {
                    let position = forPlayback ? playbackPosition(index, at: time) : index
                    if result.last != position { result.append(position) }
                }
            }
            return result
        }

        /// An aligner can give a short word a single 16 kHz sample at the onset of
        /// the next word. Share the known interval for display only. A cut, seek or
        /// export still uses the original word bounds.
        private func playbackPosition(_ index: Int, at time: RationalTime) -> Int {
            guard index > 0 else { return index }
            let word = words[index]
            let first = words[index - 1]
            let start = word.range.from
            guard first.range.from == start,
                  index < 2 || words[index - 2].range.from != start,
                  index + 1 == words.count || words[index + 1].range.from != start,
                  word.precision == .word, first.precision == .word, !word.partial, !first.partial,
                  word.trackID != nil, word.trackID == first.trackID, word.speakerID == first.speakerID,
                  word.utteranceID == first.utteranceID, word.clipID == first.clipID,
                  word.assemblyIndex == first.assemblyIndex,
                  let length = try? first.range.to.subtracting(start),
                  length == RationalTime(numerator: 1, denominator: 16_000),
                  word.range.to > first.range.to,
                  let elapsed = try? time.subtracting(start),
                  let remaining = try? word.range.to.subtracting(time) else { return index }
            // Cap the estimate at 80 ms and leave at least half the span for the second word.
            return elapsed < RationalTime(numerator: 2, denominator: 25) && elapsed < remaining ? index - 1 : index
        }

        /// Calls `body` with the words at each place the phrase is spoken, in transcript order.
        private func eachHit(_ phrase: [String], filter: TranscriptFilter, cancellable: Bool,
                             _ body: (_ lane: Int, _ tokens: Range<Int>, _ positions: [Int]) -> Void) {
            guard let first = phrase.first else { return }
            var previous: [Int] = []
            var positions: [Int] = []
            let unrestricted = filter.isUnrestricted
            matches: for posting in postings[first] ?? [] {
                if cancellable && Task.isCancelled { break }
                let lane = lanes[posting.lane]
                let end = posting.token + phrase.count
                guard end <= lane.count, zip(lane[posting.token..<end], phrase).allSatisfy({ $0.text == $1 }) else {
                    continue
                }
                positions.removeAll(keepingCapacity: true)
                var lastWord: Int?
                for token in lane[posting.token..<end] where token.word != lastWord {
                    let position = token.word
                    lastWord = position
                    let start = positions.count
                    if unrestricted || filter.accepts(words[position]) { positions.append(position) }
                    if let additional = continuations[position] {
                        for continuation in additional where unrestricted || filter.accepts(words[continuation]) {
                            positions.append(continuation)
                        }
                    }
                    guard positions.count > start else { continue matches }
                }
                guard positions != previous else { continue }
                body(posting.lane, posting.token..<end, positions)
                swap(&previous, &positions)
            }
        }

        fileprivate func match(_ hit: SearchHit) -> TranscriptMatch {
            let positions = hit.positions
            guard let context = hit.context else {
                return .init(words: positions.map { words[$0] }, before: [], after: [])
            }
            let lane = lanes[context.lane]
            let tokens = context.tokens
            let before = uniqueWords(in: lane[max(0, tokens.lowerBound - 5)..<tokens.lowerBound])
                .filter { $0 != positions.first }.map { words[$0] }
            let after = uniqueWords(in: lane[tokens.upperBound..<min(lane.count, tokens.upperBound + 5)])
                .filter { $0 != positions.last }.map { words[$0] }
            return .init(words: positions.map { words[$0] }, before: before, after: after)
        }

        private func search(_ phrase: [String], filter: TranscriptFilter, offset: Int, limit: Int,
                            cancellable: Bool) -> SearchHitPage {
            var count = 0
            var items: [SearchHit] = []
            eachHit(phrase, filter: filter, cancellable: cancellable) { lane, tokens, positions in
                if count >= offset, items.count < limit { items.append(.init(context: (lane, tokens), positions: positions)) }
                count += 1
            }
            return .init(items: items, total: count)
        }

        /// The places any of the phrases is spoken, in transcript order.
        private func search(anyOf phrases: [[String]], filter: TranscriptFilter, offset: Int,
                            limit: Int, cancellable: Bool) -> SearchHitPage {
            var hits: [SearchHit] = []
            for phrase in phrases {
                eachHit(phrase, filter: filter, cancellable: cancellable) { lane, tokens, positions in
                    hits.append(.init(context: (lane, tokens), positions: positions))
                }
            }
            if cancellable && Task.isCancelled { return .init(items: [], total: 0) }
            hits.sort { $0.positions.lexicographicallyPrecedes($1.positions) }
            var items: [SearchHit] = []
            var previous: [Int] = []
            var count = 0
            for hit in hits where previous != hit.positions {
                if count >= offset, items.count < limit { items.append(hit) }
                count += 1
                previous = hit.positions
            }
            return .init(items: items, total: count)
        }

        private struct NumberForm: Hashable {
            let tokens: [String]
            let symbol: Character?
        }

        /// What one index knows about its numbers, read on the first search that needs it. An
        /// index is never changed after it is built, so the answers hold for as long as it does.
        private final class NumberForms: @unchecked Sendable {
            private let lock = NSLock()
            private var known: [ObjectIdentifier: [String: Set<NumberForm>]] = [:]
            private var written: String??

            func callAsFunction(_ reader: TranscriptNumberReader,
                                read: () -> [String: Set<NumberForm>]) -> [String: Set<NumberForm>] {
                lock.lock()
                defer { lock.unlock() }
                if let forms = known[ObjectIdentifier(reader)] { return forms }
                let forms = read()
                known[ObjectIdentifier(reader)] = forms
                return forms
            }

            func language(detect: () -> String?) -> String? {
                lock.lock()
                defer { lock.unlock() }
                if let written { return written }
                let detected = detect()
                written = .some(detected)
                return detected
            }
        }

        private let numberForms = NumberForms()

        /// The language whose number words this transcript uses: the one it declares, else the
        /// one its words are written in, else the language of the person searching.
        private func numberLanguage(declared: String?) -> String {
            if let declared, Locale(identifier: declared).language.languageCode?.isISOLanguage == true { return declared }
            let written = numberForms.language {
                var sample = ""
                for position in words.indices.prefix(600) {
                    sample += words[position].text
                    sample += " "
                }
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(sample)
                guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
                      confidence >= 0.6 else { return nil }
                return language.rawValue
            }
            return written ?? Locale.current.language.languageCode?.identifier ?? "en"
        }

        /// Every way this transcript writes each number it contains, by the number's value.
        private func readNumberForms(_ reader: TranscriptNumberReader) -> [String: Set<NumberForm>] {
            var forms: [String: Set<NumberForm>] = [:]
            var spoken: [TranscriptNumberReader.Word] = []
            var starts: [Int] = []
            for lane in lanes {
                spoken.removeAll(keepingCapacity: true)
                starts.removeAll(keepingCapacity: true)
                var cursor = 0
                while cursor < lane.count {
                    var end = cursor + 1
                    while end < lane.count, lane[end].word == lane[cursor].word { end += 1 }
                    let position = lane[cursor].word
                    var text = words[position].text
                    // "5 %" and "5 €" put the sign in a word of its own, which has nothing to search.
                    if position + 1 < words.count, text.contains(where: \.isNumber) {
                        let next = words[position + 1].text
                        if !next.isEmpty, next.allSatisfy({ $0.isWhitespace || $0.isCurrencySymbol || $0 == "%" || $0 == "٪" || $0 == "‰" }) {
                            text += next
                        }
                    }
                    spoken.append(.init(text: text, tokens: lane[cursor..<end].map(\.text)))
                    starts.append(cursor)
                    cursor = end
                }
                starts.append(lane.count)
                for run in reader.runs(in: spoken) {
                    let tokens = lane[starts[run.words.lowerBound]..<starts[run.words.upperBound]].map(\.text)
                    forms[run.key, default: []].insert(.init(tokens: tokens, symbol: run.symbol))
                    for part in run.parts {
                        let tokens = lane[starts[part.words.lowerBound]..<starts[part.words.upperBound]].map(\.text)
                        forms[part.key, default: []].insert(.init(tokens: tokens, symbol: nil))
                    }
                }
            }
            return forms
        }

        /// The query with each of its numbers written the other ways this transcript writes it.
        /// Empty when the query names no number, or the transcript writes it only as asked.
        private func numberVariants(of query: String, language: String?) -> [[String]] {
            guard let reader = TranscriptNumberReader.shared(language: numberLanguage(declared: language)) else { return [] }
            let asked = query.split(whereSeparator: \.isWhitespace).map { word in
                TranscriptNumberReader.Word(text: String(word), tokens: TranscriptIndex.tokens(String(word)))
            }.filter { !$0.tokens.isEmpty }
            let runs = reader.runs(in: asked)
            guard !runs.isEmpty else { return [] }
            let forms = numberForms(reader) { readNumberForms(reader) }
            let limit = 64
            var partial: [(tokens: [String], next: Int)] = [([], 0)]
            for run in runs {
                let own = asked[run.words].flatMap(\.tokens)
                let written = (forms[run.key] ?? []).sorted {
                    $0.tokens == $1.tokens ? $0.symbol != nil && $1.symbol == nil : $0.tokens.lexicographicallyPrecedes($1.tokens)
                }
                // "$5" already says the "dollars" a person types after "five", and "5 %" the "pour cent".
                func named(_ symbol: Character) -> Int {
                    reader.said(symbol, by: asked[run.words.upperBound...])
                }
                var grown: [(tokens: [String], next: Int)] = []
                for item in partial {
                    guard item.next <= run.words.lowerBound else {
                        grown.append(item)
                        continue
                    }
                    let lead = item.tokens + asked[item.next..<run.words.lowerBound].flatMap(\.tokens)
                    grown.append((lead + own, run.words.upperBound))
                    for form in written {
                        if form.tokens != own { grown.append((lead + form.tokens, run.words.upperBound)) }
                        if let symbol = form.symbol {
                            let said = named(symbol)
                            if said > 0 { grown.append((lead + form.tokens, run.words.upperBound + said)) }
                        }
                    }
                    // "thirty second clip" is also "30 second clip", and a German "21." is also 21:
                    // the other number the run opens with.
                    for part in run.parts where part.words.lowerBound == run.words.lowerBound {
                        let head = asked[part.words].flatMap(\.tokens)
                        let rest = asked[part.words.upperBound..<run.words.upperBound].flatMap(\.tokens)
                        for form in forms[part.key] ?? [] where form.tokens != head {
                            grown.append((lead + form.tokens + rest, run.words.upperBound))
                        }
                    }
                }
                partial = Array(grown.prefix(limit))
            }
            var seen: Set<[String]> = [asked.flatMap(\.tokens)]
            return partial.compactMap { item in
                let tokens = item.tokens + asked[min(item.next, asked.count)...].flatMap(\.tokens)
                return !tokens.isEmpty && seen.insert(tokens).inserted ? tokens : nil
            }
        }

        private func uniqueWords(in tokens: ArraySlice<Token>) -> [Int] {
            var result: [Int] = []
            for token in tokens where result.last != token.word { result.append(token.word) }
            return result
        }
    }
}
