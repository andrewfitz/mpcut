import CryptoKit
import Foundation

public enum TranscriptAuthoredChange: Codable, Hashable, Sendable {
    case replaceText(text: String)
    case assignSpeaker(speakerID: String)
    case splitSpeaker(speakerID: String, name: String)
    case renameSpeaker(speakerID: String, name: String)
    case mergeSpeakers(sourceID: String, targetID: String)
    case matchOverride(trackID: String, accepted: Bool, observation: TranscriptObservationAddress? = nil)
    case namedSelect(name: String)
    case pauseProtection(name: String)

    private enum CodingKeys: String, CodingKey {
        case replaceText = "replace_text"
        case assignSpeaker = "assign_speaker"
        case splitSpeaker = "split_speaker"
        case renameSpeaker = "rename_speaker"
        case mergeSpeakers = "merge_speakers"
        case matchOverride = "match_override"
        case namedSelect = "named_select"
        case pauseProtection = "pause_protection"
    }

    private enum ReplaceTextCodingKeys: String, CodingKey { case text }
    private enum NamedSelectCodingKeys: String, CodingKey { case name }
    private enum PauseProtectionCodingKeys: String, CodingKey { case name }

    private enum AssignSpeakerCodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
    }

    private enum SplitSpeakerCodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case name
    }

    private enum RenameSpeakerCodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case name
    }

    private enum MergeSpeakersCodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case targetID = "target_id"
    }

    private enum MatchOverrideCodingKeys: String, CodingKey {
        case trackID = "track_id"
        case accepted
        case observation
    }

    public init(from decoder: Decoder) throws {
        let code = "invalid_transcript_authoring"
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: code)
        let changes = try decoder.container(keyedBy: CodingKeys.self)
        guard changes.allKeys.count == 1, let kind = changes.allKeys.first else {
            throw CutError(code: code, message: "Specify one transcript change.")
        }
        let payload = try changes.superDecoder(forKey: kind)
        func fields<K: CodingKey>(_ type: K.Type) throws -> KeyedDecodingContainer<K> {
            try ProjectField.rejectUnknown(type, in: payload, code: code)
            return try payload.container(keyedBy: type)
        }
        switch kind {
        case .replaceText:
            self = try .replaceText(text: fields(ReplaceTextCodingKeys.self).decode(String.self, forKey: .text))
        case .assignSpeaker:
            self = try .assignSpeaker(speakerID: fields(AssignSpeakerCodingKeys.self).decode(String.self, forKey: .speakerID))
        case .splitSpeaker:
            let values = try fields(SplitSpeakerCodingKeys.self)
            self = try .splitSpeaker(speakerID: values.decode(String.self, forKey: .speakerID),
                                     name: values.decode(String.self, forKey: .name))
        case .renameSpeaker:
            let values = try fields(RenameSpeakerCodingKeys.self)
            self = try .renameSpeaker(speakerID: values.decode(String.self, forKey: .speakerID),
                                      name: values.decode(String.self, forKey: .name))
        case .mergeSpeakers:
            let values = try fields(MergeSpeakersCodingKeys.self)
            self = try .mergeSpeakers(sourceID: values.decode(String.self, forKey: .sourceID),
                                      targetID: values.decode(String.self, forKey: .targetID))
        case .matchOverride:
            let values = try fields(MatchOverrideCodingKeys.self)
            self = try .matchOverride(trackID: values.decode(String.self, forKey: .trackID),
                                      accepted: values.decode(Bool.self, forKey: .accepted),
                                      observation: values.decodeIfPresent(TranscriptObservationAddress.self, forKey: .observation))
        case .namedSelect:
            self = try .namedSelect(name: fields(NamedSelectCodingKeys.self).decode(String.self, forKey: .name))
        case .pauseProtection:
            self = try .pauseProtection(name: fields(PauseProtectionCodingKeys.self).decode(String.self, forKey: .name))
        }
    }
}

extension TranscriptAuthoredChange {
    /// The name the edit history shows for saving this change.
    public var historyAction: String {
        switch self {
        case .namedSelect: "Name Transcript Select"
        case .pauseProtection: "Protect Transcript Pause"
        default: "Correct Transcript"
        }
    }
}

public struct TranscriptObservationAddress: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case range
        case wordID = "word_id"
    }
    public let range: MulticamRange
    public let wordID: String?

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_authoring")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        range = try fields.decode(MulticamRange.self, forKey: .range)
        wordID = try fields.decodeIfPresent(String.self, forKey: .wordID)
    }

    public init(range: MulticamRange, wordID: String? = nil) {
        self.range = range
        self.wordID = wordID
    }

    public init(_ observation: TranscriptObservation) {
        self.init(range: .init(from: observation.start, to: observation.end), wordID: observation.wordID)
    }

    func matches(_ observation: TranscriptObservation) -> Bool {
        range.from == observation.start && range.to == observation.end
            && (wordID == nil || wordID == observation.wordID)
    }
}

public struct TranscriptMatchReview: Codable, Sendable {
    public enum Disposition: String, Codable, Sendable { case confirmed, rejected }

    public let observation: TranscriptObservation
    public let disposition: Disposition
}

public struct TranscriptAnchor: Codable, Hashable, Sendable {
    public var binding: TranscriptBinding
    public let range: MulticamRange
    public let wordCount: Int
    public let wordIDHint: String?
    public let wordingHash: String
    public let speakerLane: Bool?

    private enum CodingKeys: String, CodingKey {
        case binding
        case range
        case wordCount = "word_count"
        case wordIDHint = "word_id_hint"
        case wordingHash = "wording_hash"
        case speakerLane = "speaker_lane"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_authoring")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(binding: try fields.decode(TranscriptBinding.self, forKey: .binding),
                  range: try fields.decode(MulticamRange.self, forKey: .range),
                  wordCount: try fields.decode(Int.self, forKey: .wordCount),
                  wordIDHint: try fields.decodeIfPresent(String.self, forKey: .wordIDHint),
                  wordingHash: try fields.decode(String.self, forKey: .wordingHash),
                  speakerLane: try fields.decodeIfPresent(Bool.self, forKey: .speakerLane))
    }

    public init(binding: TranscriptBinding, range: MulticamRange, wordCount: Int,
                wordIDHint: String? = nil, wordingHash: String, speakerLane: Bool? = nil) {
        self.binding = binding
        self.range = range
        self.wordCount = wordCount
        self.wordIDHint = wordIDHint
        self.wordingHash = wordingHash
        self.speakerLane = speakerLane
    }
}

public struct TranscriptAuthoredRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let attachmentID: String
    public let change: TranscriptAuthoredChange
    public let anchors: [TranscriptAnchor]
    public let speakerReference: TranscriptAnchor?

    private enum CodingKeys: String, CodingKey {
        case id
        case attachmentID = "attachment_id"
        case change
        case anchors
        case speakerReference = "speaker_reference"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_authoring")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try fields.decode(String.self, forKey: .id),
                  attachmentID: try fields.decode(String.self, forKey: .attachmentID),
                  change: try fields.decode(TranscriptAuthoredChange.self, forKey: .change),
                  anchors: try fields.decode([TranscriptAnchor].self, forKey: .anchors),
                  speakerReference: try fields.decodeIfPresent(TranscriptAnchor.self, forKey: .speakerReference))
    }

    public init(id: String = UUID().uuidString, attachmentID: String, change: TranscriptAuthoredChange, anchors: [TranscriptAnchor],
                speakerReference: TranscriptAnchor? = nil) {
        self.id = id
        self.attachmentID = attachmentID
        self.change = change
        self.anchors = anchors
        self.speakerReference = speakerReference
    }

    public func mapSourcePaths(_ transform: (String) -> String) -> Self {
        func map(_ value: TranscriptAnchor) -> TranscriptAnchor {
            var anchor = value
            anchor.binding = anchor.binding.mapSourcePaths(transform)
            return anchor
        }
        return Self(id: id, attachmentID: attachmentID, change: change, anchors: anchors.map(map), speakerReference: speakerReference.map(map))
    }

    public func validate() throws {
        func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sourceAnchors = anchors + (speakerReference.map { [$0] } ?? [])
        for anchor in sourceAnchors { try anchor.binding.validate() }
        guard nonempty(id), validStillID(attachmentID), sourceAnchors.allSatisfy({ anchor in
            anchor.range.from <= anchor.range.to && anchor.wordCount > 0
                && anchor.wordingHash.utf8.count == 64
                && anchor.wordingHash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && anchor.wordIDHint != ""
                && anchor.binding.streamIndex >= 0
                && (anchor.binding.channel.map { $0 >= 0 } ?? true)
                && nonempty(anchor.binding.trackID)
                && ((anchor.binding.file != nil) != (anchor.binding.sourceID != nil))
                && (anchor.binding.file.map(nonempty) ?? true)
                && (anchor.binding.sourceID.map(nonempty) ?? true)
        }) else {
            throw CutError(code: "invalid_transcript_authoring", message: "Invalid authored transcript record or anchor")
        }
        let valid: Bool
        switch change {
        case .replaceText:
            valid = anchors.count == 1
        case .assignSpeaker(let speaker):
            valid = nonempty(speaker) && !anchors.isEmpty
        case .splitSpeaker(let speaker, let name):
            valid = nonempty(speaker) && nonempty(name) && !anchors.isEmpty
        case .renameSpeaker(let speaker, let name):
            valid = nonempty(speaker) && nonempty(name) && anchors.count <= 1
        case .mergeSpeakers(let source, let target):
            valid = nonempty(source) && nonempty(target) && source != target && anchors.count <= 2
        case .matchOverride(let track, _, let observation):
            valid = nonempty(track) && !anchors.isEmpty && (observation.map {
                $0.range.from <= $0.range.to && $0.wordID != ""
            } ?? true)
        case .namedSelect(let name):
            valid = nonempty(name) && !anchors.isEmpty
        case .pauseProtection(let name):
            valid = nonempty(name) && anchors.count == 2
        }
        let acceptsSpeakerReference: Bool
        switch change {
        case .assignSpeaker, .mergeSpeakers: acceptsSpeakerReference = true
        default: acceptsSpeakerReference = false
        }
        guard valid, acceptsSpeakerReference || speakerReference == nil else {
            throw CutError(code: "invalid_transcript_authoring", message: "Invalid change or anchor count for record \(id)")
        }
    }
}

public enum TranscriptAnchorStatus: String, Codable, Sendable {
    case resolved, missing, ambiguous
}

public struct TranscriptAnchorResolution: Codable, Sendable {
    public let status: TranscriptAnchorStatus
    public let words: [TranscriptOccurrence]
    public let candidates: [[TranscriptOccurrence]]
}

public struct TranscriptAuthoredReview: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case attachmentID = "attachment_id"
        case change
        case anchors
        case speakerReference = "speaker_reference"
        case matchStatus = "match_status"
        case matchObservation = "match_observation"
    }
    public let id: String
    public let attachmentID: String
    public let change: TranscriptAuthoredChange
    public let anchors: [TranscriptAnchorResolution]
    public let speakerReference: TranscriptAnchorResolution?
    public let matchStatus: TranscriptAnchorStatus?
    let matchObservation: TranscriptObservation?
}

extension TranscriptEditorial {
    private struct Stream: Hashable {
        let file: String?
        let source: String?
        let stream: Int
        let channel: Int?

        init(_ binding: TranscriptBinding) {
            file = binding.file
            source = binding.sourceID
            stream = binding.streamIndex
            channel = binding.channel
        }
    }

    private struct WordLocation: Hashable {
        let stream: Stream
        let range: MulticamRange
        let id: String

        init?(_ word: TranscriptOccurrence) {
            guard let binding = word.binding, let range = word.originalSourceRange else { return nil }
            self.stream = Stream(binding)
            self.range = range
            self.id = word.observation?.wordID ?? word.wordID
        }
    }

    /// Source words by stream and by speaker within a stream, in source order. The lanes hold
    /// positions in `words`: every project with a saved correction builds this for each index,
    /// and regrouping copies of hours of occurrences cost more than resolving the anchors.
    private struct AnchorIndex {
        let words: [TranscriptOccurrence]
        let streams: [Stream: [Int]]
        let speakerLanes: [Stream: [[Int]]]

        init(_ words: [TranscriptOccurrence]) {
            self.words = words
            var grouped: [Stream: [Int]] = [:]
            var seen: Set<WordLocation> = []
            for position in words.indices {
                guard let location = WordLocation(words[position]), seen.insert(location).inserted else { continue }
                grouped[location.stream, default: []].append(position)
            }
            let streams = grouped.mapValues { positions in
                positions.sorted {
                    let left = words[$0].originalSourceRange?.from ?? words[$0].range.from
                    let right = words[$1].originalSourceRange?.from ?? words[$1].range.from
                    return left != right ? left < right : TranscriptEditorial.occurrenceOrder(words[$0], words[$1])
                }
            }
            self.streams = streams
            self.speakerLanes = streams.mapValues { positions in
                Array(Dictionary(grouping: positions, by: { words[$0].originalSpeakerID }).values)
            }
        }

        func resolve(_ anchor: TranscriptAnchor) -> TranscriptAnchorResolution {
            let stream = Stream(anchor.binding)
            let lanes = anchor.speakerLane == true ? speakerLanes[stream, default: []] : [streams[stream, default: []]]
            let found = lanes.map { candidates(anchor, lane: $0) }
            let exact = found.flatMap(\.exact)
            let nearby = found.flatMap(\.nearby)
            let matches = (exact.isEmpty ? nearby : exact).sorted { left, right in
                let leftHint = left.first?.wordID == anchor.wordIDHint && left.count == anchor.wordCount
                let rightHint = right.first?.wordID == anchor.wordIDHint && right.count == anchor.wordCount
                if leftHint != rightHint { return leftHint }
                return TranscriptEditorial.occurrenceOrder(left[0], right[0])
            }
            switch matches.count {
            case 0: return .init(status: .missing, words: [], candidates: [])
            case 1: return .init(status: .resolved, words: matches[0], candidates: [])
            default: return .init(status: .ambiguous, words: [], candidates: matches)
            }
        }

        private func candidates(_ anchor: TranscriptAnchor, lane: [Int])
            -> (exact: [[TranscriptOccurrence]], nearby: [[TranscriptOccurrence]]) {
            guard anchor.wordCount > 0, !lane.isEmpty else { return ([], []) }
            let tolerance = 0.25
            let start = anchor.range.from.seconds
            let end = anchor.range.to.seconds
            // Locate the small window holding possible starts before inspecting their wording.
            var lower = 0
            var upper = lane.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let time = words[lane[middle]].originalSourceRange?.from ?? words[lane[middle]].range.from
                if time.seconds < start - tolerance { lower = middle + 1 } else { upper = middle }
            }
            var exact: [[TranscriptOccurrence]] = []
            var nearby: [[TranscriptOccurrence]] = []
            for index in lower..<lane.count {
                guard let first = words[lane[index]].originalSourceRange,
                      first.from.seconds <= start + tolerance else { break }
                var lastEnd = first.to
                for last in index..<lane.count {
                    guard let range = words[lane[last]].originalSourceRange, range.from.seconds <= end + tolerance else { break }
                    lastEnd = max(lastEnd, range.to)
                    if lastEnd.seconds > end + tolerance { break }
                    if lastEnd.seconds < end - tolerance { continue }
                    let selected = lane[index...last].map { words[$0] }
                    guard TranscriptEditorial.wordingHash(selected) == anchor.wordingHash else { continue }
                    if first.from == anchor.range.from && lastEnd == anchor.range.to {
                        exact.append(selected)
                    } else {
                        nearby.append(selected)
                    }
                }
            }
            return (exact, nearby)
        }
    }

    public static func anchor(_ selected: [TranscriptOccurrence], binding: TranscriptBinding) throws -> TranscriptAnchor {
        let stream = Stream(binding)
        let words = AnchorIndex(selected).streams[stream, default: []].map { selected[$0] }
        guard !words.isEmpty, selected.allSatisfy({ $0.binding.map(Stream.init) == stream }),
              let range = span(words) else {
            throw CutError(code: "unanchored_transcript_selection",
                           message: "Select words with a shared stream and source timing")
        }
        return .init(binding: binding, range: range, wordCount: words.count, wordIDHint: words.first?.wordID,
                     wordingHash: wordingHash(words),
                     speakerLane: Set(words.map(\.originalSpeakerID)).count == 1 ? true : nil)
    }

    public static func makeRecord(change: TranscriptAuthoredChange, selections: [TranscriptWordSelection],
                                  in index: TranscriptIndex, id: String = UUID().uuidString) throws -> TranscriptAuthoredRecord {
        guard let attachmentID = index.attachment?.id else {
            throw CutError(code: "missing_transcript_attachment", message: "Attach this transcript before saving corrections.")
        }
        let source = index.readAll(space: .source)
        // Only a change that names a speaker looks one up, and the check of the finished
        // record below needs the same index.
        var builtIndex: AnchorIndex?
        func sourceIndex() -> AnchorIndex {
            if let builtIndex { return builtIndex }
            let built = AnchorIndex(source)
            builtIndex = built
            return built
        }
        func sourceAnchor(for speakerID: String) throws -> TranscriptAnchor? {
            let candidates = source.filter { $0.originalSpeakerID == speakerID }
            if candidates.isEmpty {
                guard index.speakers.contains(where: { $0.id == speakerID }) else {
                    throw CutError(code: "unknown_transcript_speaker", message: "Transcript speaker ‘\(speakerID)’ does not exist.")
                }
                return nil
            }
            for word in candidates {
                if let binding = word.binding, word.originalSourceRange != nil {
                    let candidate = try anchor([word], binding: binding)
                    if sourceIndex().resolve(candidate).status == .resolved { return candidate }
                }
            }
            throw CutError(code: "unanchored_transcript_speaker", message: "Speaker ‘\(speakerID)’ needs a uniquely bound source word.")
        }

        var anchors: [TranscriptAnchor] = []
        var speakerReference: TranscriptAnchor?
        switch change {
        case .renameSpeaker(let speakerID, _):
            if let source = try sourceAnchor(for: speakerID) { anchors = [source] }
        case .mergeSpeakers(let sourceID, let targetID):
            if let source = try sourceAnchor(for: sourceID) { anchors = [source] }
            speakerReference = try sourceAnchor(for: targetID)
        default:
            for selection in selections {
                let selected = try TranscriptEditPlanner.select(selection, in: index)
                if case .matchOverride(let trackID, _, let address) = change {
                    let evidence = selected.first.observations + (selected.first.matchReviews ?? []).map(\.observation)
                        + [selected.first.observation].compactMap { $0 }
                    guard selected.first.wordID == selected.last.wordID, evidence.contains(where: {
                        $0.evidence == .inferred && $0.trackID == trackID && (address?.matches($0) ?? true)
                    }) else {
                        throw CutError(code: "unknown_transcript_match", message: "Choose an inferred observation of this word to review.")
                    }
                }
                if case .pauseProtection = change {
                    guard selected.kind == .gap, let first = selected.first.binding, let last = selected.last.binding else {
                        throw CutError(code: "unanchored_transcript_selection", message: "Select a gap with two bound endpoints.")
                    }
                    try anchors.append(anchor([selected.first], binding: first))
                    try anchors.append(anchor([selected.last], binding: last))
                    continue
                }
                guard let binding = selected.first.binding, let other = selected.last.binding,
                      Stream(binding) == Stream(other),
                      let first = selected.first.originalSourceRange, let last = selected.last.originalSourceRange,
                      first.from <= last.from else {
                    throw CutError(code: "unanchored_transcript_selection",
                                   message: "Split the selection into source-contiguous ranges on individual tracks.")
                }
                let sameLane = selected.first.originalSpeakerID == selected.last.originalSpeakerID
                let firstLocation = WordLocation(selected.first)
                let lastLocation = WordLocation(selected.last)
                let stream = Stream(binding)
                let selectedWords = source.filter { word in
                    guard let location = WordLocation(word), location.stream == stream else { return false }
                    if location == firstLocation || location == lastLocation { return true }
                    guard firstLocation != lastLocation, !sameLane || word.originalSpeakerID == selected.first.originalSpeakerID else {
                        return false
                    }
                    return first.from <= location.range.from && location.range.to <= max(first.to, last.to)
                }
                if selected.space != .source {
                    // A selection made in the edit can span a join. The source words between its
                    // ends that the cut removed were never selected, and must not be corrected,
                    // renamed or saved along with it.
                    let shown = Set(index.overlapping(selected.range, space: selected.space).map(\.wordID))
                    guard selectedWords.allSatisfy({ shown.contains($0.wordID) }) else {
                        throw CutError(code: "unanchored_transcript_selection",
                                       message: "This selection crosses an edit that removed dialogue. Select each retained passage separately.")
                    }
                }
                try anchors.append(anchor(selectedWords, binding: binding))
            }
        }
        if case .assignSpeaker(let speakerID) = change, source.contains(where: { $0.originalSpeakerID == speakerID }) {
            speakerReference = try sourceAnchor(for: speakerID)
        }
        if case .splitSpeaker(let speakerID, _) = change, index.speakers.contains(where: { $0.id == speakerID }) {
            throw CutError(code: "duplicate_transcript_speaker", message: "Transcript speaker ‘\(speakerID)’ already exists.")
        }
        let record = TranscriptAuthoredRecord(id: id, attachmentID: attachmentID, change: change,
                                              anchors: anchors, speakerReference: speakerReference)
        try record.validate()
        let resolutions = review(records: [record], in: sourceIndex())
        guard resolutions[0].anchors.allSatisfy({ $0.status == .resolved }),
              resolutions[0].speakerReference.map({ $0.status == .resolved }) ?? true else {
            throw CutError(code: "unanchored_transcript_selection", message: "The original wording and source span are not unique.")
        }
        return record
    }

    public static func reanchor(_ anchor: TranscriptAnchor, in words: [TranscriptOccurrence]) -> TranscriptAnchorResolution {
        AnchorIndex(words).resolve(anchor)
    }

    public static func review(records: [TranscriptAuthoredRecord], sourceWords: [TranscriptOccurrence],
                              attachmentID: String? = nil) -> [TranscriptAuthoredReview] {
        let scope = attachmentID ?? sourceWords.first?.attachmentID
        let records = records.filter { $0.attachmentID == scope }
        guard !records.isEmpty else { return [] }
        // One attachment's index holds only its own words, and is used as it is.
        let scopedWords = sourceWords.allSatisfy { $0.attachmentID == scope }
            ? sourceWords : sourceWords.filter { $0.attachmentID == scope }
        return review(records: records, in: AnchorIndex(scopedWords))
    }

    /// Resolves records against the source words of the attachment they all belong to.
    private static func review(records: [TranscriptAuthoredRecord], in index: AnchorIndex) -> [TranscriptAuthoredReview] {
        let scopedWords = index.words
        let observations = records.contains { if case .matchOverride = $0.change { true } else { false } }
            ? Dictionary(grouping: scopedWords, by: \.wordID) : [:]
        return records.map { record in
            let anchors = record.anchors.map(index.resolve)
            var matchStatus: TranscriptAnchorStatus?
            var matchObservation: TranscriptObservation?
            if case .matchOverride(let trackID, _, let address) = record.change,
               anchors.allSatisfy({ $0.status == .resolved }) {
                let ids = Set(anchors.flatMap(\.words).map(\.wordID))
                let candidates = ids.flatMap { observations[$0, default: []] }
                    .compactMap(\.observation).filter { item in
                        item.trackID == trackID && item.evidence == .inferred
                    }
                if let address {
                    let exact = candidates.filter(address.matches)
                    let sameSpan = candidates.filter { address.range.from == $0.start && address.range.to == $0.end }
                    let matches = exact.isEmpty ? sameSpan : exact
                    switch matches.count {
                    case 0: matchStatus = .missing
                    case 1:
                        matchStatus = .resolved
                        matchObservation = matches[0]
                    default: matchStatus = .ambiguous
                    }
                } else {
                    matchStatus = candidates.isEmpty ? .missing : .resolved
                }
            }
            return TranscriptAuthoredReview(id: record.id, attachmentID: record.attachmentID, change: record.change,
                                            anchors: anchors, speakerReference: record.speakerReference.map(index.resolve),
                                            matchStatus: matchStatus, matchObservation: matchObservation)
        }
    }

    public static func overlaid(_ words: [TranscriptOccurrence], records: [TranscriptAuthoredRecord],
                                sourceWords: [TranscriptOccurrence]? = nil) -> [TranscriptOccurrence] {
        overlaid(words, review: review(records: records, sourceWords: sourceWords ?? words))
    }

    private struct Replacement {
        let id: String
        let text: String
    }

    private struct ReplacementOccurrence: Hashable {
        let id: String
        let track: String?
        let clip: String?
        let assembly: Int?

        init(_ replacement: Replacement, _ word: TranscriptOccurrence, perTrack: Bool) {
            self.id = replacement.id
            self.clip = word.clipID
            self.assembly = word.assemblyIndex
            // Source lists each recording's own copy of a word. Every copy shows the correction.
            self.track = perTrack || (word.groupRange == nil && word.clipID == nil) ? word.trackID : nil
        }
    }

    public static func overlaid(_ words: [TranscriptOccurrence], review: [TranscriptAuthoredReview],
                                perTrack: Bool = false) -> [TranscriptOccurrence] {
        guard !review.isEmpty else { return words }
        var replacements: [WordLocation: Replacement] = [:]
        var replacementsByID: [String: Replacement] = [:]
        var assignments: [WordLocation: String] = [:]
        var assignmentsByID: [String: String] = [:]
        var mergedSpeakers: [String: String] = [:]
        struct MatchDecision {
            let trackID: String
            let observation: TranscriptObservationAddress?
            let accepted: Bool
        }
        var matches: [String: [MatchDecision]] = [:]
        for record in review {
            let resolutions = record.anchors
            let speakerReference = record.speakerReference
            guard resolutions.allSatisfy({ $0.status == .resolved }),
                  speakerReference.map({ $0.status == .resolved && $0.words.first?.originalSpeakerID != nil }) ?? true else { continue }
            let selected = resolutions.flatMap(\.words)
            switch record.change {
            case .replaceText(let text):
                let replacement = Replacement(id: record.id, text: text)
                for word in selected {
                    guard let location = WordLocation(word) else { continue }
                    replacements[location] = replacement
                    replacementsByID[word.wordID] = replacement
                }
            case .assignSpeaker(let speakerID), .splitSpeaker(let speakerID, _):
                let speaker = speakerReference?.words.first?.originalSpeakerID ?? speakerID
                for word in selected {
                    guard let location = WordLocation(word) else { continue }
                    assignments[location] = speaker
                    assignmentsByID[word.wordID] = speaker
                }
            case .mergeSpeakers(let sourceID, let targetID):
                let source = resolutions.first?.words.first?.originalSpeakerID ?? sourceID
                let target = speakerReference?.words.first?.originalSpeakerID
                    ?? (resolutions.count == 2 ? resolutions[1].words.first?.originalSpeakerID : nil)
                    ?? targetID
                if source != target { mergedSpeakers[source] = target }
            case .matchOverride(let trackID, let accepted, let observation):
                guard record.matchStatus == .resolved else { continue }
                let address = record.matchObservation.map(TranscriptObservationAddress.init) ?? observation
                for id in Set(selected.map(\.wordID)) {
                    matches[id, default: []].append(.init(trackID: trackID, observation: address, accepted: accepted))
                }
            case .renameSpeaker, .namedSelect, .pauseProtection:
                break
            }
        }
        func replacement(for word: TranscriptOccurrence) -> Replacement? {
            WordLocation(word).flatMap { replacements[$0] } ?? replacementsByID[word.wordID]
        }
        func decision(_ wordID: String, trackID: String, observation: TranscriptObservation?) -> Bool? {
            matches[wordID]?.last {
                guard $0.trackID == trackID else { return false }
                guard let target = $0.observation else { return true }
                return observation.map(target.matches) ?? false
            }?.accepted
        }
        func rejected(_ word: TranscriptOccurrence) -> Bool {
            guard word.audibility == .inferred, let track = word.trackID else { return false }
            return decision(word.wordID, trackID: track, observation: word.observation) == false
        }
        var firstVisible: [ReplacementOccurrence: TranscriptOccurrence] = [:]
        if !replacements.isEmpty {
            for word in words where !rejected(word) {
                guard let replacement = replacement(for: word) else { continue }
                let location = ReplacementOccurrence(replacement, word, perTrack: perTrack)
                if let first = firstVisible[location], !occurrenceOrder(word, first) { continue }
                firstVisible[location] = word
            }
        }
        return words.compactMap { raw in
            var word = raw
            if rejected(word) { return nil }
            if matches[word.wordID] != nil {
                var evidence = word.observations
                if let primary = word.observation, !evidence.contains(primary) { evidence.append(primary) }
                let reviews: [TranscriptMatchReview] = evidence.compactMap { item in
                    guard item.evidence == .inferred,
                          let accepted = decision(word.wordID, trackID: item.trackID, observation: item) else { return nil }
                    return TranscriptMatchReview(observation: item, disposition: accepted ? .confirmed : .rejected)
                }
                word.matchReviews = reviews.isEmpty ? nil : reviews
                word.observations.removeAll {
                    $0.evidence == .inferred && decision(word.wordID, trackID: $0.trackID, observation: $0) == false
                }
            }
            let location = WordLocation(word)
            if let replacement = replacement(for: word) {
                word.textReplacementID = replacement.id
                word.text = firstVisible[ReplacementOccurrence(replacement, word, perTrack: perTrack)]?.id == word.id
                    ? replacement.text : ""
            }
            var speaker = location.flatMap { assignments[$0] } ?? assignmentsByID[word.wordID] ?? word.speakerID
            var visited: Set<String> = []
            while let id = speaker, let merged = mergedSpeakers[id], visited.insert(id).inserted {
                speaker = merged
            }
            if let speaker, visited.contains(speaker) { return word }
            word.speakerID = speaker
            return word
        }
    }

    public static func correctedSpeakers(_ speakers: [TranscriptSpeaker], records: [TranscriptAuthoredRecord],
                                         sourceWords: [TranscriptOccurrence]) -> [TranscriptSpeaker] {
        correctedSpeakers(speakers, review: review(records: records, sourceWords: sourceWords))
    }

    public static func correctedSpeakers(_ speakers: [TranscriptSpeaker],
                                         review: [TranscriptAuthoredReview]) -> [TranscriptSpeaker] {
        var result = speakers
        for record in review {
            switch record.change {
            case .renameSpeaker(let id, let name):
                let resolved = record.anchors.first
                if let resolved, resolved.status != .resolved { continue }
                let speakerID = resolved?.words.first?.originalSpeakerID ?? id
                if let position = result.firstIndex(where: { $0.id == speakerID }) {
                    result[position].name = name
                }
            case .assignSpeaker(let id):
                guard record.speakerReference == nil, record.anchors.allSatisfy({ $0.status == .resolved }),
                      !result.contains(where: { $0.id == id }) else { continue }
                result.append(.init(id: id, name: id))
            case .splitSpeaker(let id, let name):
                guard record.anchors.allSatisfy({ $0.status == .resolved }),
                      !result.contains(where: { $0.id == id }) else { continue }
                result.append(.init(id: id, name: name))
            case .mergeSpeakers(let sourceID, let targetID):
                guard record.anchors.allSatisfy({ $0.status == .resolved }),
                      record.speakerReference.map({ $0.status == .resolved && $0.words.first?.originalSpeakerID != nil }) ?? true else { continue }
                let source = record.anchors.first?.words.first?.originalSpeakerID ?? sourceID
                let target = record.speakerReference?.words.first?.originalSpeakerID
                    ?? (record.anchors.count == 2 ? record.anchors[1].words.first?.originalSpeakerID : nil)
                    ?? targetID
                if source != target, result.contains(where: { $0.id == target }) {
                    result.removeAll(where: { $0.id == source })
                }
            default:
                break
            }
        }
        return result
    }

    private static func span(_ words: some Collection<TranscriptOccurrence>) -> MulticamRange? {
        let ranges = words.compactMap(\.originalSourceRange)
        guard let from = ranges.map(\.from).min(), let to = ranges.map(\.to).max() else { return nil }
        return .init(from: from, to: to)
    }

    private static func wordingHash(_ words: some Collection<TranscriptOccurrence>) -> String {
        let tokens = words.flatMap { terms($0.originalText) }
        let text = tokens.isEmpty ? words.map(\.originalText).joined(separator: " ") : tokens.joined(separator: " ")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
