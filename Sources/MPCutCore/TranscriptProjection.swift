import Foundation

public enum TranscriptGapReason: String, Codable, Sendable {
    case still, silence, unbound, skipped, failed, unavailable, changed
}

public struct TranscriptCoverageGap: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case range
        case laneID = "lane_id"
        case laneOrder = "lane_order"
        case laneLabel = "lane_label"
        case laneColorSlot = "lane_color_slot"
        case assemblyIndex = "assembly_index"
        case clipID = "clip_id"
        case sourceID = "source_id"
        case streamIndex = "audio_stream_index"
        case reason
        case trackID = "track_id"
        case file
        case attachmentID = "attachment_id"
    }
    public let range: MulticamRange
    public var laneID: String? = nil
    public var laneOrder: Int? = nil
    public var laneLabel: String? = nil
    public var laneColorSlot: Int? = nil
    public let assemblyIndex: Int?
    public let clipID: String?
    public let sourceID: String?
    public let streamIndex: Int?
    public let reason: TranscriptGapReason
    public var trackID: String? = nil
    public var file: String? = nil
    public var attachmentID: String? = nil
}

public struct TranscriptInputCoverageStatus: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case name
        case attachmentID = "attachment_id"
        case sourceID = "source_id"
        case file
        case streamIndex = "audio_stream_index"
        case channel
        case coverage
        case laneID = "lane_id"
        case laneOrder = "lane_order"
        case laneLabel = "lane_label"
        case laneColorSlot = "lane_color_slot"
        case bindingStatus = "binding_status"
        case bounds
        case message
    }
    public let trackID: String
    public let name: String
    public let attachmentID: String?
    public let sourceID: String?
    public let file: String?
    public let streamIndex: Int?
    public let channel: Int?
    public let coverage: TranscriptCoverage
    public let bindingStatus: TranscriptBindingStatus?
    /// Established recording extent in the requested clock, when available.
    public let bounds: MulticamRange?
    public let message: String?
    public var laneID: String? = nil
    public var laneOrder: Int? = nil
    public var laneLabel: String? = nil
    public var laneColorSlot: Int? = nil
}

public struct TranscriptInputCoverageReport: Codable, Sendable {
    public let gaps: TranscriptPage<TranscriptCoverageGap>
    public let tracks: TranscriptPage<TranscriptInputCoverageStatus>

    static func paged(_ rows: TranscriptInputCoverageRows, offset: Int, limit: Int,
                      trackOffset: Int?, trackLimit: Int?) -> Self {
        let gapOffset = max(0, offset)
        let statusOffset = max(0, trackOffset ?? offset)
        let gapLimit = min(500, max(1, limit))
        let statusLimit = min(500, max(1, trackLimit ?? limit))
        return Self(gaps: .init(items: Array(rows.gaps.dropFirst(gapOffset).prefix(gapLimit)),
                                total: rows.gaps.count, offset: gapOffset),
                    tracks: .init(items: Array(rows.tracks.dropFirst(statusOffset).prefix(statusLimit)),
                                  total: rows.tracks.count, offset: statusOffset))
    }
}

struct TranscriptInputCoverageRows: Sendable {
    var gaps: [TranscriptCoverageGap] = []
    var tracks: [TranscriptInputCoverageStatus] = []
}

public struct TranscriptAngleCoverage: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case sourceRange = "source_range"
        case frameTime = "frame_time"
    }
    public let sourceID: String
    public let sourceRange: MulticamRange
    /// Starts on the indexed frame covering sourceRange.from, when an index is available.
    public let frameTime: RationalTime?
}

extension TranscriptBinding {
    /// A changed file may still contain the same audio stream. Only a fresh index
    /// with matching recognition evidence can carry that binding across the change.
    public func sourceStatus(in project: CutProject, relativeTo projectURL: URL,
                             track: TranscriptTrack, indexedMedia: MediaInfo?) -> TranscriptBindingStatus {
        let status = sourceStatus(in: project, relativeTo: projectURL)
        guard status == .changed, track.id == trackID, let indexedMedia,
              case .string(let oldEvidence)? = track.streamEvidence else {
            return status
        }
        let path: String?
        if case .multicam(let multicam) = project {
            path = multicam.sources.first { $0.id == sourceID }?.file
        } else {
            path = file
        }
        guard let path, let url = try? CutProject.checkedMediaURL(path, relativeTo: projectURL),
              indexedMedia.identity.isCurrentSnapshot(at: url) else { return status }
        let presentationMedia = sourceID == nil ? try? CutEngine().multicamClock(indexedMedia) : indexedMedia
        guard let presentationMedia,
              let currentEvidence = try? TranscriptJobPlan.streamEvidence(media: presentationMedia, streamIndex: streamIndex),
              currentEvidence == oldEvidence else { return status }
        return sourceConfirmed == true ? .available : .unverified
    }
}

extension TranscriptIndex {
    package static func sourceOccurrences(document: TranscriptDocument, attachment: TranscriptAttachment) throws -> [TranscriptOccurrence] {
        let projection = try TranscriptProjection(document: document, attachment: attachment, project: nil, projectURL: nil,
                                                  sequenceMedia: [:], multicamMedia: [:], timelineRevision: 0,
                                                  staleMatches: false)
        return try projection.sourceWords()
    }

    public init(document: TranscriptDocument, attachment: TranscriptAttachment? = nil,
                project: CutProject? = nil, projectURL: URL? = nil,
                sequenceMedia: [String: MediaInfo] = [:], multicamMedia: [String: MediaInfo] = [:],
                timelineRevision: Int = 0, staleMatches: Bool = false,
                records: [TranscriptAuthoredRecord] = []) throws {
        try self.init(document: document, attachment: attachment, project: project, projectURL: projectURL,
                      sequenceMedia: sequenceMedia, multicamMedia: multicamMedia, timelineRevision: timelineRevision,
                      staleMatches: staleMatches, records: records, spaces: Set(TranscriptSpace.allCases))
    }

    package init(document: TranscriptDocument, attachment: TranscriptAttachment? = nil,
                 project: CutProject? = nil, projectURL: URL? = nil,
                 sequenceMedia: [String: MediaInfo] = [:], multicamMedia: [String: MediaInfo] = [:],
                 timelineRevision: Int = 0, staleMatches: Bool = false,
                 records: [TranscriptAuthoredRecord] = [], spaces: Set<TranscriptSpace>) throws {
        try document.validate()
        self.document = document
        self.attachment = attachment
        self.transcriptRevision = project?.transcripts.revision
        self.timelineRevision = timelineRevision
        let projection = try TranscriptProjection(document: document, attachment: attachment, project: project,
                                                  projectURL: projectURL, sequenceMedia: sequenceMedia,
                                                  multicamMedia: multicamMedia, timelineRevision: timelineRevision,
                                                  staleMatches: staleMatches, needsWords: !spaces.isEmpty)
        let coverageInputs = try projection.inputCoverageTracks()
        let groupRange = projection.multicam?.range
        self.inputCoverageProvider = { space, filter in
            try TranscriptProjection.inputCoverage(coverageInputs, space: space, filter: filter, group: groupRange)
        }
        var source = spaces.isEmpty ? [] : try projection.sourceWords()
        var group: [TranscriptOccurrence] = []
        var currentCut: [TranscriptOccurrence] = []
        var gaps: [TranscriptCoverageGap] = []
        let needsCut = spaces.contains(.currentCut)
        let needsGroup = spaces.contains(.group)
        switch project {
        case .multicam(let multicam) where needsGroup || needsCut:
            (group, currentCut, gaps) = try projection.multicamWords(source, project: multicam,
                                                                   needsGroup: needsGroup, needsCut: needsCut)
        case .sequence(let clips) where needsCut:
            (currentCut, gaps) = try projection.sequenceWords(source, items: clips.map(StillSequenceItem.source))
        case .stillSequence(let sequence) where needsCut:
            (currentCut, gaps) = try projection.sequenceWords(source, items: sequence.items)
        case nil where needsCut && document.clock == .currentCut:
            currentCut = try projection.sessionWords(source, space: .currentCut)
        default:
            break
        }
        if needsGroup, projection.multicam == nil, document.clock == .session || document.clock == .group {
            group = try projection.sessionWords(source, space: .group)
        }
        self.gaps = gaps
        let usesMix = projection.multicam?.audio == .mix
        self.usesMix = usesMix
        let review = records.isEmpty || spaces.isEmpty ? [] : TranscriptEditorial.review(records: records, sourceWords: source, attachmentID: attachment?.id)
        self.authoredReview = review
        self.speakers = TranscriptEditorial.correctedSpeakers(document.speakers + projection.localSpeakers, review: review)
        // Each list is handed to its index and forgotten here, so the index holds the only
        // reference and orders it in place.
        var indexes: [TranscriptSpace: WordIndex] = [:]
        if spaces.contains(.source) {
            let words = TranscriptEditorial.overlaid(source, review: review, perTrack: true)
            source = []
            indexes[.source] = WordIndex(consume words, space: .source)
        }
        if needsGroup {
            let words = TranscriptEditorial.overlaid(group, review: review)
            group = []
            indexes[.group] = WordIndex(consume words, space: .group)
        }
        if needsCut {
            let words = TranscriptEditorial.overlaid(currentCut, review: review)
            currentCut = []
            indexes[.currentCut] = WordIndex(consume words, space: .currentCut, gaps: gaps, usesMix: usesMix)
        }
        self.indexes = indexes
    }
}

private struct TranscriptProjection {
    /// A transcript track with what its binding resolves to. Every word heard on the track
    /// reads the same values, so they are resolved once and shared by reference: a copy per
    /// word of the track, its binding and its audio index costs more than projecting the word.
    final class LocalTrack {
        let track: TranscriptTrack
        let binding: TranscriptBinding?
        let bindingStatus: TranscriptBindingStatus?
        let bindingChanged: Bool
        let sequenceOffset: RationalTime
        let sequenceOrdinal: Int?
        let sequenceAudio: AudioIndex?
        let sequenceMediaBounds: MulticamRange?
        let sequenceHasVideo: Bool
        let hasSequenceMedia: Bool
        let sequenceMedia: MediaInfo?
        let usesEmbeddedBinding: Bool
        let sourceID: String?
        let streamIndex: Int?
        let file: String?

        init(track: TranscriptTrack, binding: TranscriptBinding?, bindingStatus: TranscriptBindingStatus?,
             sequenceOffset: RationalTime, sequenceOrdinal: Int?, sequenceAudio: AudioIndex?,
             sequenceMediaBounds: MulticamRange?, sequenceHasVideo: Bool, hasSequenceMedia: Bool,
             sequenceMedia: MediaInfo?, usesEmbeddedBinding: Bool) {
            self.track = track
            self.binding = binding
            self.bindingStatus = bindingStatus
            self.bindingChanged = bindingStatus == .changed || bindingStatus == .bindingMissing
            self.sequenceOffset = sequenceOffset
            self.sequenceOrdinal = sequenceOrdinal
            self.sequenceAudio = sequenceAudio
            self.sequenceMediaBounds = sequenceMediaBounds
            self.sequenceHasVideo = sequenceHasVideo
            self.hasSequenceMedia = hasSequenceMedia
            self.sequenceMedia = sequenceMedia
            self.usesEmbeddedBinding = usesEmbeddedBinding
            self.sourceID = binding == nil && usesEmbeddedBinding ? track.sourceID : binding?.sourceID
            self.streamIndex = binding?.streamIndex ?? track.streamIndex
            self.file = binding?.file
        }
    }

    /// Picture coverage depends on the group range alone, and the tracks that heard one word
    /// usually place it at the same range. The latest answer serves the word's other tracks.
    private final class AngleCoverageCache {
        struct Picture {
            let id: String
            let offset: RationalTime
            let extent: MulticamRange
            let frames: [FrameInfo]
        }

        var pictures: [Picture]?
        var latest: (group: MulticamRange, angles: [TranscriptAngleCoverage])?
    }

    let document: TranscriptDocument
    let projectURL: URL?
    let multicamMedia: [String: MediaInfo]
    let pictureFrames: [String: [FrameInfo]]
    let timelineRevision: Int
    let attachmentID: String?
    let occurrencePrefix: String
    let staleMatches: Bool
    let tracks: [String: LocalTrack]
    let words: [String: TranscriptWord]
    let localWords: [String: [TranscriptWord]]
    let trackWordText: [String: [String: String]]
    let localSpeakers: [TranscriptSpeaker]
    let importOrigin: RationalTime
    let approximate: Bool
    let multicam: MulticamProject?
    let sources: [String: MulticamSource]
    let sourceOffsets: [String: RationalTime]
    let replacementOffsets: [String: RationalTime]
    let sourceFiles: [String: String]
    let lanesByTrack: [String: TranscriptLaneMetadata]
    private let angleCoverageCache = AngleCoverageCache()

    init(document: TranscriptDocument, attachment: TranscriptAttachment?, project: CutProject?,
         projectURL: URL?, sequenceMedia: [String: MediaInfo], multicamMedia: [String: MediaInfo],
         timelineRevision: Int, staleMatches: Bool, needsWords: Bool = true) throws {
        self.document = document
        self.projectURL = projectURL
        self.multicamMedia = multicamMedia
        // An index lists pictures in presentation order. Sorting hours of frames again
        // for every timeline revision cost more than the projection that reads them.
        self.pictureFrames = needsWords ? multicamMedia.mapValues { media in
            let ordered = zip(media.frames, media.frames.dropFirst()).allSatisfy { !($1.time < $0.time) }
            return ordered ? media.frames : media.frames.sorted { $0.time < $1.time }
        } : [:]
        self.timelineRevision = timelineRevision
        self.attachmentID = attachment?.id
        self.occurrencePrefix = (attachment.map { "\($0.id.count):\($0.id):" } ?? "") + "\(timelineRevision):"
        let bindings = Dictionary(attachment?.bindings.map { ($0.trackID, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        self.tracks = Dictionary(uniqueKeysWithValues: try document.tracks.map { track in
            let binding = bindings[track.id]
            let media = binding?.file.flatMap { file -> MediaInfo? in
                if let media = sequenceMedia[file] { return media }
                guard let projectURL else { return nil }
                let url = CutProject.mediaURL(file, relativeTo: projectURL)
                return sequenceMedia[url.standardizedFileURL.resolvingSymlinksInPath().path]
            }
            let isRemovedReplacement: Bool
            if case .multicam(let multicam) = project, let identity = TranscriptJobPlan.replacementTrackIdentity(track.id) {
                isRemovedReplacement = !multicam.audioReplacements.contains {
                    TranscriptJobPlan.replacementTrackID($0) == identity
                        && $0.replacement.source == (binding?.sourceID ?? track.sourceID)
                        && $0.replacement.stream == (binding?.streamIndex ?? track.streamIndex)
                }
            } else {
                isRemovedReplacement = false
            }
            let status = if isRemovedReplacement {
                TranscriptBindingStatus.bindingMissing
            } else if let binding, let project, let projectURL {
                binding.sourceStatus(in: project, relativeTo: projectURL, track: track,
                                     indexedMedia: binding.sourceID.flatMap { multicamMedia[$0] } ?? media)
            } else if attachment != nil, binding == nil {
                TranscriptBindingStatus.unbound
            } else {
                nil as TranscriptBindingStatus?
            }
            let ordinal = media?.streams.filter { $0.kind == "audio" }.firstIndex {
                $0.index == (binding?.streamIndex ?? track.streamIndex)
            }
            let audio = media?.audio.first { $0.stream.index == (binding?.streamIndex ?? track.streamIndex) }
            let mediaOffset = (status == .changed ? nil : media?.multicamSourceOffset)
                ?? binding?.sequenceClockOrigin ?? .zero
            let bounds = try media.flatMap { try Self.mediaBounds($0, audio: audio)?.projectionShifted(by: mediaOffset) }
            return (track.id, LocalTrack(track: track, binding: binding, bindingStatus: status,
                                         sequenceOffset: mediaOffset,
                                         sequenceOrdinal: ordinal ?? binding?.sequenceStreamOrdinal,
                                         sequenceAudio: audio, sequenceMediaBounds: bounds,
                                         sequenceHasVideo: media?.hasVideo ?? false,
                                         hasSequenceMedia: media.map { !$0.audio.isEmpty } ?? false,
                                         sequenceMedia: media, usesEmbeddedBinding: attachment == nil))
        })
        var words = Dictionary(uniqueKeysWithValues: (needsWords ? document.words : []).map { ($0.id, $0) })
        var referenced: [String: Set<String>] = [:]
        // A recording's different reading of a spoken word is attached to that word as an
        // inferred observation that names the recording's own word. The spoken word stands for
        // it on every clock, so the recording's copy is not listed a second time.
        for word in needsWords ? document.words : [] {
            for observation in word.observations {
                if let id = observation.wordID { referenced[observation.trackID, default: []].insert(id) }
            }
        }
        var localWords: [String: [TranscriptWord]] = [:]
        var localSpeakers: [TranscriptSpeaker] = []
        var speakerIDs = Set(document.speakers.map(\.id))
        for track in document.tracks where needsWords && track.coverage == .recognized {
            let known = referenced[track.id] ?? []
            let local = track.words ?? []
            let speakerNames = Dictionary((track.speakers ?? []).map { ($0.id, $0.name) },
                                          uniquingKeysWith: { first, _ in first })
            var trackSpeakerIDs: [String: String] = [:]
            for (position, rawWord) in local.enumerated() where !known.contains(rawWord.id) {
                var word = rawWord
                word.id = "\(track.id.count):\(track.id):\(position):\(rawWord.id)"
                while words[word.id] != nil { word.id = "local:" + word.id }
                if let speakerID = rawWord.speakerID {
                    if let mapped = trackSpeakerIDs[speakerID] {
                        word.speakerID = mapped
                    } else {
                        var mapped = "\(track.id.count):\(track.id):\(speakerID)"
                        while !speakerIDs.insert(mapped).inserted { mapped = "local:" + mapped }
                        localSpeakers.append(.init(id: mapped, name: speakerNames[speakerID] ?? speakerID))
                        trackSpeakerIDs[speakerID] = mapped
                        word.speakerID = mapped
                    }
                }
                word.observations = [.init(trackID: track.id, wordID: rawWord.id, text: rawWord.text,
                                           start: rawWord.start, end: rawWord.end, evidence: .recognized,
                                           speakerID: word.speakerID, confidence: rawWord.confidence)]
                localWords[track.id, default: []].append(word)
                words[word.id] = word
            }
        }
        self.localWords = localWords
        self.trackWordText = Dictionary(uniqueKeysWithValues: document.tracks.compactMap { track in
            guard let words = track.words, let known = referenced[track.id] else { return nil }
            return (track.id, Dictionary(uniqueKeysWithValues: words.filter { known.contains($0.id) }.map { ($0.id, $0.text) }))
        })
        self.localSpeakers = localSpeakers
        self.words = words
        self.importOrigin = attachment?.importOrigin ?? .zero
        self.approximate = document.approximateClock && attachment?.importOrigin == nil
        if case .multicam(let multicam) = project {
            try multicam.validate()
            self.multicam = multicam
            let sources = Dictionary(uniqueKeysWithValues: multicam.sources.map { ($0.id, $0) })
            self.sources = sources
            let sourceOffsets = sources.mapValues(\.offset)
            self.sourceOffsets = sourceOffsets
            let placements = try multicam.transcriptReplacementPlacements()
            let placementsByID = Dictionary(uniqueKeysWithValues: placements.map { ($0.trackID, $0.offset) })
            let replacementOffsets = Dictionary(uniqueKeysWithValues: self.tracks.keys.compactMap { trackID -> (String, RationalTime)? in
                guard let identity = TranscriptJobPlan.replacementTrackIdentity(trackID), let offset = placementsByID[identity] else {
                    return nil
                }
                return (trackID, offset)
            })
            self.replacementOffsets = replacementOffsets
            self.sourceFiles = sources.mapValues(\.file)
            self.lanesByTrack = self.tracks.compactMapValues { track in
                multicam.transcriptLane(sourceID: track.sourceID, streamIndex: track.streamIndex, trackID: track.track.id)
            }
            // Native bindings include the exact session origin separately from
            // the helper's rounded 16 kHz frame offset.
            let approximateOrigin = document.approximateClock && attachment?.importOrigin == nil
            let changedOffsets = try document.jobID != nil && document.tracks.contains { track in
                guard track.streamIndex != nil || bindings[track.id] != nil,
                      let id = bindings[track.id]?.sourceID ?? (attachment == nil ? track.sourceID : nil),
                      let source = sources[id] else {
                    return false
                }
                if TranscriptJobPlan.replacementTrackIdentity(track.id) != nil {
                    guard let offset = replacementOffsets[track.id] else { return true }
                    return try track.origin.adding(offset) != track.sessionStart
                }
                let current = try track.origin.adding(source.offset)
                if approximateOrigin, track.approximateClock != false {
                    let delta = try current.subtracting(track.sessionStart)
                    return delta < RationalTime(numerator: -1, denominator: 32_000)
                        || delta > RationalTime(numerator: 1, denominator: 32_000)
                }
                return current != track.sessionStart
            }
            self.staleMatches = staleMatches || changedOffsets
        } else {
            self.multicam = nil
            self.sources = [:]
            self.sourceOffsets = [:]
            self.replacementOffsets = [:]
            self.sourceFiles = [:]
            self.lanesByTrack = [:]
            self.staleMatches = staleMatches
        }
    }

    func sourceWords() throws -> [TranscriptOccurrence] {
        var result: [TranscriptOccurrence] = []
        // An occurrence is several hundred bytes. Growing the list by doubling moves hours of
        // them again and again.
        result.reserveCapacity(document.words.reduce(0) { $0 + max(1, $1.observations.count) }
                               + localWords.values.reduce(0) { $0 + $1.count })
        let recognizedTracks = document.tracks.filter { $0.coverage == .recognized }.map(\.id).sorted()
        for word in document.words {
            if !word.observations.isEmpty {
                // Inferred-only stale associations retain no usable source observation.
                for (index, observation) in word.observations.enumerated()
                where !staleMatches || observation.evidence == .recognized {
                    guard let track = tracks[observation.trackID] else { continue }
                    let original = MulticamRange(from: observation.start, to: observation.end)
                    let source = try original.projectionShifted(by: importOrigin.adding(track.binding?.offset ?? .zero))
                    // A recording that read the word differently still recognized a word there.
                    let heard = observation.evidence == .recognized
                        || observation.wordID.map { trackWordText[observation.trackID]?[$0] != nil } ?? false
                    try result.append(occurrence(word, id: "source-\(index)", range: source, source: source,
                                                 original: original, group: groupRange(for: track, source: source),
                                                 track: track, observation: observation,
                                                 audibility: heard ? .recognized : .inferred))
                }
                continue
            }
            let candidates = word.candidateTrackIDs ?? recognizedTracks
            let range = MulticamRange(from: word.start, to: word.end)
            if let exported = word.projection, let id = exported.trackID, let track = tracks[id],
               let from = exported.originalSourceStart, let to = exported.originalSourceEnd, from <= to {
                let original = MulticamRange(from: from, to: to)
                let source = try original.projectionShifted(by: importOrigin.adding(track.binding?.offset ?? .zero))
                try result.append(occurrence(word, id: "source", range: source, source: source, original: original,
                                             group: groupRange(for: track, source: source), track: track, audibility: .source))
                continue
            }
            let wordClock = word.projection?.clock ?? document.clock
            guard wordClock == .presentation || wordClock == .session,
                  candidates.count == 1, let track = tracks[candidates[0]] else {
                try result.append(occurrence(word, id: "source", range: range, candidates: candidates,
                                             audibility: .source))
                continue
            }
            var original = range
            if wordClock == .session {
                original = try range.projectionShifted(by: track.track.origin.subtracting(track.track.sessionStart))
            }
            let source = try original.projectionShifted(by: importOrigin.adding(track.binding?.offset ?? .zero))
            try result.append(occurrence(word, id: "source", range: source, source: source, original: original,
                                         group: groupRange(for: track, source: source),
                                         track: track, audibility: .source))
        }
        for track in document.tracks {
            guard let local = tracks[track.id] else { continue }
            let adjustment = try importOrigin.adding(local.binding?.offset ?? .zero)
            for word in localWords[track.id] ?? [] {
                let original = MulticamRange(from: word.start, to: word.end)
                let source = try original.projectionShifted(by: adjustment)
                try result.append(occurrence(word, id: "source-local", range: source, source: source, original: original,
                                             group: groupRange(for: local, source: source), track: local,
                                             observation: word.observations.first, audibility: .recognized))
            }
        }
        return result
    }

    func sessionWords(_ sourceWords: [TranscriptOccurrence], space: TranscriptSpace) throws -> [TranscriptOccurrence] {
        let local = Dictionary(grouping: sourceWords, by: \.wordID)
        return try document.words.map { word in
            let range = MulticamRange(from: word.start, to: word.end)
            let matches = local[word.id] ?? []
            let preferred = matches.first { $0.audibility == .recognized } ?? matches.first
            let track = preferred?.trackID.flatMap { tracks[$0] }
            let metadata = word.projection
            let route = metadata?.routedSourceID.flatMap { source in
                metadata?.routedStreamIndex.map { MulticamAudioSelection(source: source, stream: $0) }
            }
            var item = try occurrence(word, id: space.rawValue, range: range, source: preferred?.sourceRange,
                                      original: preferred?.originalSourceRange, group: space == .group ? range : nil,
                                      assembly: metadata?.assemblyIndex, clip: metadata?.clipID, track: track,
                                      observation: preferred?.observation,
                                      candidates: preferred?.candidateTrackIDs ?? word.candidateTrackIDs ?? [],
                                      route: route, audibility: preferred?.audibility ?? .source,
                                      partial: metadata?.partial ?? false, useLocalText: false)
            item.observations = word.observations
            item.trackSources = trackSources(matches)
            return item
        }
    }

    func trackSources(_ occurrences: [TranscriptOccurrence]) -> [String: String] {
        Dictionary(occurrences.compactMap { item in
            guard let track = item.trackID, let source = item.sourceID else { return nil }
            return (track, source)
        }, uniquingKeysWith: { first, _ in first })
    }

    func occurrence(_ word: TranscriptWord, id: String, range: MulticamRange,
                    source: MulticamRange? = nil, original: MulticamRange? = nil, group: MulticamRange? = nil,
                    assembly: Int? = nil, clip: String? = nil, track: LocalTrack? = nil,
                    observation: TranscriptObservation? = nil, candidates: [String] = [],
                    route: MulticamAudioSelection? = nil, lane: TranscriptLaneMetadata? = nil, audibility: TranscriptAudibility,
                    partial: Bool = false, useLocalText: Bool = true,
                    knownAngles: [TranscriptAngleCoverage]? = nil) throws -> TranscriptOccurrence {
        let file = track?.file ?? track?.sourceID.flatMap { sourceFiles[$0] }
        let observedText = observation.flatMap { observed in
            observed.text ?? observed.wordID.flatMap { trackWordText[observed.trackID]?[$0] }
        }
        let text = (useLocalText ? observedText : nil) ?? word.text
        let speaker = (useLocalText ? observation?.speakerID : nil) ?? word.speakerID
        let sequenceSourceRange: MulticamRange?
        if let source, let track, track.sourceID == nil {
            sequenceSourceRange = try source.unshifted(by: track.sequenceOffset)
        } else {
            sequenceSourceRange = nil
        }
        let originalSpeaker = word.projection.map(\.originalSpeakerID) ?? word.speakerID
        let lane = lane ?? track.flatMap { lanesByTrack[$0.track.id] }
        return try .init(id: "\(occurrencePrefix)\(id):\(word.id)", wordID: word.id,
                         attachmentID: attachmentID, text: text, speakerID: speaker,
                         originalText: observedText ?? word.projection?.originalText ?? word.text,
                         originalSpeakerID: observation?.speakerID ?? originalSpeaker, precision: word.precision,
                         utteranceID: word.utteranceID,
                         observation: observation, candidateTrackIDs: candidates, file: file, binding: track?.binding, bindingStatus: track?.bindingStatus,
                         originalSourceRange: original, sequenceSourceRange: sequenceSourceRange,
                         angles: knownAngles ?? group.map(angleCoverage) ?? [], range: range, sourceRange: source,
                         groupRange: group, assemblyIndex: assembly, clipID: clip, sourceID: track?.sourceID,
                         trackID: track?.track.id, streamIndex: track?.streamIndex, sequenceStreamOrdinal: track?.sequenceOrdinal,
                         laneID: lane?.id, laneOrder: lane?.order, laneLabel: lane?.label, laneColorSlot: lane?.colorSlot,
                         routedSourceID: route?.source, routedStreamIndex: route?.stream,
                         audibility: audibility, partial: partial, approximate: approximate && (track?.track.approximateClock ?? true),
                         staleMatches: staleMatches || word.projection?.staleMatches == true,
                         timelineRevision: timelineRevision)
    }

    private func groupRange(for track: LocalTrack, source: MulticamRange) throws -> MulticamRange? {
        guard !track.bindingChanged, let sourceID = track.sourceID, let offset = sourceOffsets[sourceID] else { return nil }
        return try source.projectionShifted(by: replacementOffsets[track.track.id] ?? offset)
    }

    func angleCoverage(_ group: MulticamRange) throws -> [TranscriptAngleCoverage] {
        guard let multicam else { return [] }
        if let latest = angleCoverageCache.latest, latest.group == group { return latest.angles }
        let pictures: [AngleCoverageCache.Picture]
        if let known = angleCoverageCache.pictures {
            pictures = known
        } else {
            pictures = try multicam.pictureSources.compactMap { source in
                guard let media = multicamMedia[source.id], let video = media.videoStream else { return nil }
                let end = video.duration > .zero ? try video.start.adding(video.duration) : media.duration
                let natural = MulticamRange(from: video.start, to: end)
                let declared = try source.coverage?.unshifted(by: source.offset) ?? natural
                guard let extent = natural.intersection(declared) else { return nil }
                return .init(id: source.id, offset: source.offset, extent: extent, frames: pictureFrames[source.id] ?? [])
            }
            angleCoverageCache.pictures = pictures
        }
        let angles = try pictures.compactMap { angle -> TranscriptAngleCoverage? in
            let local = try group.unshifted(by: angle.offset)
            guard let intersection = local.intersection(angle.extent) else { return nil }
            let frames = angle.frames
            var lower = 0
            var upper = frames.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if frames[middle].time <= intersection.from { lower = middle + 1 } else { upper = middle }
            }
            if lower > 0 {
                let frame = frames[lower - 1]
                if try frame.time.adding(frame.duration) > intersection.from {
                    return .init(sourceID: angle.id, sourceRange: intersection, frameTime: frame.time)
                }
            }
            if lower < frames.count, frames[lower].time < intersection.to {
                let frameTime = frames[lower].time
                return .init(sourceID: angle.id, sourceRange: .init(from: frameTime, to: intersection.to), frameTime: frameTime)
            }
            guard frames.isEmpty else { return nil }
            return .init(sourceID: angle.id, sourceRange: intersection, frameTime: nil)
        }
        angleCoverageCache.latest = (group, angles)
        return angles
    }

    /// Whether a piece of a word is only what frame snapping left behind. Nearest Frame moves a
    /// requested boundary by up to half a frame, so removing a word that touches its neighbour
    /// leaves up to that much of it in the cut. Nobody can hear or select it as a word, so the
    /// cut does not list it. A word a blade went through continues in the next clip and stays.
    func isSnapRemnant(_ piece: MulticamRange, of heard: MulticamRange, continuesBefore: Bool, continuesAfter: Bool,
                       headLimit: () -> RationalTime?, tailLimit: () -> RationalTime?) throws -> Bool {
        let headCut = heard.from < piece.from
        let tailCut = piece.to < heard.to
        if (headCut && continuesBefore) || (tailCut && continuesAfter) { return false }
        guard let limit = [headCut ? headLimit() : nil, tailCut ? tailLimit() : nil].compactMap({ $0 }).max() else {
            return false
        }
        return try piece.to.subtracting(piece.from) <= limit
    }

    func canonical(_ file: String) -> String {
        if let projectURL {
            return CutProject.mediaURL(file, relativeTo: projectURL).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return file
    }
}

private extension MediaInfo {
    /// Half a step of the grid Nearest Frame lands on beside `time`: a picture frame, or the
    /// audio edit grid of a recording without picture. `frames` are in presentation order.
    func snapTolerance(at time: RationalTime, frames: [FrameInfo]) -> RationalTime? {
        let half = RationalTime(numerator: 1, denominator: 2)
        if hasVideo {
            let next = frames.lowerBound { $0.time >= time }
            let beside = [next - 1, next].compactMap { frames.indices.contains($0) ? frames[$0].duration : nil }
            guard let frame = beside.max(), frame > .zero else { return nil }
            return try? frame.multiplied(by: half)
        }
        guard !audio.isEmpty else { return nil }
        let before = steppingAudioBoundary(from: time.seconds, direction: -1)
        let after = steppingAudioBoundary(from: time.seconds, direction: 1)
        guard before < after, let span = try? after.subtracting(before) else { return nil }
        // On the grid the two neighbours are two steps apart.
        let onGrid = audioEditBoundary(near: time.seconds) == time
        return try? span.multiplied(by: onGrid ? RationalTime(numerator: 1, denominator: 4) : half)
    }
}

private extension MulticamRange {
    func intersection(_ other: Self) -> Self? {
        let start = max(from, other.from)
        let end = min(to, other.to)
        if start < end || (from == to && other.contains(from)) { return Self(from: start, to: end) }
        return nil
    }

    func projectionShifted(by offset: RationalTime) throws -> Self {
        offset == .zero ? self : try Self(from: from.adding(offset), to: to.adding(offset))
    }

    func unshifted(by offset: RationalTime) throws -> Self {
        offset == .zero ? self : try Self(from: from.subtracting(offset), to: to.subtracting(offset))
    }
}

private extension TranscriptProjection {
    struct Route {
        let group: MulticamRange
        let output: MulticamRange
        let assembly: Int
        let audio: MulticamAudioSelection?
        var offset: RationalTime? = nil
        var replacementBindingID: String? = nil
        /// The picture source at each end, whose frames an edit there landed on.
        let headPicture: String?
        let tailPicture: String?
    }

    struct StreamKey: Hashable {
        let source: String
        let stream: Int
        let replacementBindingID: String?
    }

    func multicamWords(_ sourceWords: [TranscriptOccurrence], project: MulticamProject,
                       needsGroup: Bool, needsCut: Bool) throws
        -> ([TranscriptOccurrence], [TranscriptOccurrence], [TranscriptCoverageGap]) {
        let occurrencesByWord = Dictionary(grouping: sourceWords.indices) { sourceWords[$0].wordID }
        var group: [TranscriptOccurrence] = []
        if needsGroup { group.reserveCapacity(staleMatches ? sourceWords.count : occurrencesByWord.count) }
        // The edit needs only where each stream heard a word and which source occurrence that
        // was. A whole group occurrence per track of every word is built only where Group shows it.
        var routedWords: [StreamKey: [Int]] = [:]
        let placements = try project.transcriptReplacementPlacements()
        let replacementByTrack = Dictionary(uniqueKeysWithValues: placements.map { ($0.trackID, $0.bindingID) })
        let streamKeys: [String: StreamKey] = tracks.compactMapValues { track in
            guard let source = track.sourceID, let stream = track.streamIndex else { return nil }
            let binding = TranscriptJobPlan.replacementTrackIdentity(track.track.id).flatMap { replacementByTrack[$0] }
            return .init(source: source, stream: stream, replacementBindingID: binding)
        }
        func groupID(_ position: Int) -> String {
            "group-\(sourceWords[position].id)"
        }
        func groupOccurrence(_ word: TranscriptWord, _ position: Int, _ track: LocalTrack,
                             _ range: MulticamRange, _ groupRange: MulticamRange) throws -> TranscriptOccurrence {
            try occurrence(word, id: groupID(position), range: groupRange, source: range,
                           original: sourceWords[position].originalSourceRange, group: groupRange, track: track,
                           observation: sourceWords[position].observation, audibility: sourceWords[position].audibility,
                           useLocalText: staleMatches, knownAngles: sourceWords[position].angles)
        }
        let supplemental = document.tracks.flatMap { localWords[$0.id] ?? [] }
        var mapped: [(position: Int, track: LocalTrack, source: MulticamRange, group: MulticamRange)] = []
        for word in document.words + supplemental {
            let local = occurrencesByWord[word.id] ?? []
            mapped.removeAll(keepingCapacity: true)
            for position in local {
                guard let trackID = sourceWords[position].trackID, let track = tracks[trackID], !track.bindingChanged,
                      let range = sourceWords[position].sourceRange,
                      let groupRange = sourceWords[position].groupRange else { continue }
                mapped.append((position, track, range, groupRange))
            }
            if needsCut {
                for item in mapped {
                    guard let key = streamKeys[item.track.track.id] else { continue }
                    routedWords[key, default: []].append(item.position)
                }
            }
            guard needsGroup else { continue }
            if staleMatches {
                for item in mapped {
                    try group.append(groupOccurrence(word, item.position, item.track, item.source, item.group))
                }
            } else if let preferred = mapped.first(where: { sourceWords[$0.position].audibility == .recognized }) ?? mapped.first {
                var representative = try groupOccurrence(word, preferred.position, preferred.track,
                                                         preferred.source, preferred.group)
                representative.observations = word.observations
                representative.trackSources = Dictionary(mapped.compactMap { item in
                    item.track.sourceID.map { (item.track.track.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
                representative.trackLanes = Dictionary(mapped.compactMap { item in
                    sourceWords[item.position].laneID.map { (item.track.track.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
                group.append(representative)
            } else if document.clock == .session || document.clock == .group {
                let range = MulticamRange(from: word.start, to: word.end)
                try group.append(occurrence(word, id: "group", range: range, group: range,
                                            candidates: word.candidateTrackIDs ?? [], audibility: .source))
            }
        }
        guard needsCut else { return (group, [], []) }
        let intervals = routedWords.mapValues { positions in
            TranscriptRangeIndex(positions, range: { sourceWords[$0].groupRange ?? sourceWords[$0].range },
                                 id: { "\(occurrencePrefix)\(groupID($0)):\(sourceWords[$0].wordID)" })
        }
        let tracksByStream = Dictionary(grouping: tracks.values.compactMap { track -> (StreamKey, LocalTrack)? in
            streamKeys[track.track.id].map { ($0, track) }
        }, by: \.0)
        let plan = try project.plan()
        let mix = project.audio == .mix
        let originalSelections = Set(project.audioReplacements.map(\.original))
        let hasRoutedReplacement = plan.audioLanes.flatMap(\.spans).contains { span in
            span.stream.map { originalSelections.contains(.init(source: span.source, stream: $0)) } ?? false
        }
        let legacy = !mix && !hasRoutedReplacement
        let laneRoutes: [(TranscriptLaneMetadata?, [Route], [MulticamRange], [Route])]
        if legacy {
            laneRoutes = [(nil, legacyTranscriptRoutes(plan), [], [])]
        } else {
            let routedLanes = try project.resolveAudioLanes(plan: plan, indexedSources: multicamMedia,
                                                           assumeUnindexedCoverage: true, unavailableAsGap: true)
            let mappings = MulticamAudioMapping.coalescing(plan.intervals)
            laneRoutes = try routedLanes.enumerated().map { order, lane in
                let info = lane.colorSlot.map { TranscriptLaneMetadata(id: lane.id, order: order, label: lane.label, colorSlot: $0) }
                let unavailable = try transcriptRoutes(lane.unavailableSpans ?? [], intervals: plan.intervals, mappings: mappings)
                return (info, try transcriptRoutes(lane.spans, intervals: plan.intervals, mappings: mappings), lane.gaps, unavailable)
            }
        }
        var audioRanges: [StreamKey: [MulticamRange]] = [:]
        var current: [TranscriptOccurrence] = []
        var gaps = try stillGaps(project.assemblyItems ?? [.group(project.range)])
        var programSilence = mix ? plan.intervals.map { (assembly: $0.assemblyIndex, range: $0.output) } : []
        for (lane, routes, coverageGaps, unavailable) in laneRoutes {
            for route in unavailable {
                gaps += clippedRanges(coverageGaps, to: route.output).map {
                    gap($0, reason: .unavailable, lane: lane, route: route)
                }
            }
            let unavailableRanges = unavailable.map(\.output).sorted { $0.from < $1.from }
            let laneSilence = coverageGaps.flatMap { envelope in
                Self.complement(unavailableRanges.compactMap { $0.intersection(envelope) }, in: envelope)
            }
            if mix {
                programSilence = programSilence.flatMap { span in
                    clippedRanges(laneSilence, to: span.range).map { (span.assembly, $0) }
                }
            }
            for silence in laneSilence {
                let first = plan.intervals.lowerBound { $0.output.to > silence.from }
                for interval in plan.intervals[first...] {
                    if interval.output.from >= silence.to { break }
                    guard let clipped = silence.intersection(interval.output) else { continue }
                    gaps.append(gap(clipped, reason: .silence, lane: lane, assembly: interval.assemblyIndex))
                }
            }
            for (index, route) in routes.enumerated() {
                guard let audio = route.audio, let source = sources[audio.source] else {
                    gaps.append(.init(range: route.output, assemblyIndex: route.assembly, clipID: nil,
                                      sourceID: nil, streamIndex: nil, reason: .silence))
                    continue
                }
                let offset = route.offset ?? source.offset
                let key = StreamKey(source: audio.source, stream: audio.stream, replacementBindingID: route.replacementBindingID)
                let delta = try route.output.from.subtracting(route.group.from)
                let availability: [MulticamRange]
                if legacy, let media = multicamMedia[audio.source] {
                    if audioRanges[key] == nil {
                        let track = media.audio.first { $0.stream.index == key.stream }
                        audioRanges[key] = try track.map { try Self.audibleRanges($0, shiftedBy: offset, hasVideo: media.hasVideo) } ?? []
                    }
                    availability = clippedRanges(audioRanges[key] ?? [], to: route.group)
                } else {
                    availability = [route.group]
                }
                // The same audio plays on from the same moment where a blade split the assembly.
                func joins(_ other: Int, _ edge: (Route, Route) -> Bool) -> Bool {
                    routes.indices.contains(other) && routes[other].audio == route.audio
                        && routes[other].replacementBindingID == route.replacementBindingID && edge(routes[other], route)
                }
                let continuesBefore = joins(index - 1) { $0.group.to == $1.group.from && $0.output.to == $1.output.from }
                let continuesAfter = joins(index + 1) { $1.group.to == $0.group.from && $1.output.to == $0.output.from }
                func snapLimit(_ picture: String?, _ time: RationalTime) -> RationalTime? {
                    guard let picture, let media = multicamMedia[picture], let offset = sourceOffsets[picture],
                          let local = try? time.subtracting(offset) else { return nil }
                    return media.snapTolerance(at: local, frames: pictureFrames[picture] ?? media.frames)
                }
                let covered = tracksByStream[key]?.map(\.1) ?? []
                let placementTrack = placements.first { $0.bindingID == route.replacementBindingID }?.trackID
                let routeLane = lane ?? project.transcriptLane(sourceID: audio.source, streamIndex: audio.stream,
                                                               trackID: placementTrack)

                let valid = covered.filter { !$0.bindingChanged && (!mix || $0.bindingStatus != .offline) }.map(\.track.coverage)
                let reason: TranscriptGapReason? = valid.isEmpty && covered.contains(where: \.bindingChanged)
                    ? .changed : gapReason(valid)
                if let reason {
                    gaps.append(gap(route.output, reason: reason, lane: routeLane, route: route))
                } else {
                    try gaps.append(contentsOf: Self.complement(availability, in: route.group).map {
                        try gap($0.projectionShifted(by: delta), reason: .unavailable, lane: routeLane, route: route)
                    })
                }
                for (segment, available) in availability.enumerated() {
                    for position in intervals[key]?.overlapping(available) ?? [] {
                        guard let heard = sourceWords[position].groupRange, let clipped = heard.intersection(available),
                              let word = words[sourceWords[position].wordID],
                              let trackID = sourceWords[position].trackID, let track = tracks[trackID] else { continue }
                        if clipped != heard, try isSnapRemnant(
                            clipped, of: heard,
                            continuesBefore: continuesBefore && clipped.from == route.group.from,
                            continuesAfter: continuesAfter && clipped.to == route.group.to,
                            headLimit: { snapLimit(route.headPicture, clipped.from) },
                            tailLimit: { snapLimit(route.tailPicture, clipped.to) }) { continue }
                        let lanePrefix = mix ? lane.map { "\($0.id.count):\($0.id):" } ?? "" : ""
                        let id = "cut-\(lanePrefix)\(index)-\(segment)-\(occurrencePrefix)\(groupID(position)):\(word.id)"
                        try current.append(occurrence(word, id: id,
                                                      range: clipped.projectionShifted(by: delta), source: clipped.unshifted(by: offset),
                                                      original: sourceWords[position].originalSourceRange, group: clipped,
                                                      assembly: route.assembly, track: track,
                                                      observation: sourceWords[position].observation, route: audio, lane: routeLane,
                                                      audibility: sourceWords[position].audibility, partial: clipped != heard,
                                                      useLocalText: staleMatches,
                                                      knownAngles: clipped == heard ? sourceWords[position].angles : nil))
                    }
                }
            }
        }
        if mix {
            gaps += programSilence.map { gap($0.range, reason: .silence, assembly: $0.assembly) }
            current = mergeBleed(current)
        } else if !staleMatches && tracksByStream.values.contains(where: { $0.count > 1 }) {
            current = mergeBleed(current, separateStreams: true)
        }
        return (group, current, sortedGaps(gaps))
    }

    func gap(_ range: MulticamRange, reason: TranscriptGapReason, lane: TranscriptLaneMetadata? = nil,
             assembly: Int? = nil, route: Route? = nil) -> TranscriptCoverageGap {
        .init(range: range, laneID: lane?.id, laneOrder: lane?.order, laneLabel: lane?.label,
              laneColorSlot: lane?.colorSlot, assemblyIndex: route?.assembly ?? assembly, clipID: nil,
              sourceID: route?.audio?.source, streamIndex: route?.audio?.stream, reason: reason)
    }

    /// Preserve the route ordinal component of single-program occurrence IDs.
    func legacyTranscriptRoutes(_ plan: MulticamPlan) -> [Route] {
        let sound = plan.audioLanes.first?.spans ?? []
        var routes: [Route] = []
        var next = sound.startIndex
        for interval in plan.intervals {
            while next < sound.endIndex, sound[next].output.to <= interval.output.from { next += 1 }
            let audio: MulticamAudioSelection?
            if next < sound.endIndex, sound[next].output.from <= interval.output.from, let stream = sound[next].stream {
                audio = .init(source: sound[next].source, stream: stream)
            } else {
                audio = nil
            }
            let picture = interval.pictureSourceID ?? interval.angle
            if let last = routes.last, last.assembly == interval.assemblyIndex,
               last.audio == audio, last.group.to == interval.group.from,
               last.output.to == interval.output.from {
                routes[routes.count - 1] = .init(group: .init(from: last.group.from, to: interval.group.to),
                                                output: .init(from: last.output.from, to: interval.output.to),
                                                assembly: last.assembly, audio: last.audio,
                                                headPicture: last.headPicture, tailPicture: picture)
            } else {
                routes.append(.init(group: interval.group, output: interval.output,
                                    assembly: interval.assemblyIndex, audio: audio,
                                    headPicture: picture, tailPicture: picture))
            }
        }
        return routes
    }

    func transcriptRoutes(_ spans: [MulticamSpan], intervals: [MulticamInterval],
                          mappings: [MulticamAudioMapping]) throws -> [Route] {
        var routes: [Route] = []
        for span in spans {
            guard let stream = span.stream else { continue }
            let audio = MulticamAudioSelection(source: span.source, stream: stream)
            let start = mappings.lowerBound { $0.output.to > span.output.from }
            for mapping in mappings[start...].prefix(while: { $0.output.from < span.output.to }) {
                guard let output = mapping.output.intersection(span.output) else { continue }
                let group = try output.projectionShifted(by: mapping.group.from.subtracting(mapping.output.from))
                let offset = try group.from.subtracting(span.input.from.adding(output.from.subtracting(span.output.from)))
                let head = intervals[intervals.lowerBound { $0.output.to > output.from }]
                let tail = intervals[intervals.lowerBound { $0.output.from >= output.to } - 1]
                let headPicture = head.pictureSourceID ?? head.angle
                let tailPicture = tail.pictureSourceID ?? tail.angle
                if let last = routes.last, last.assembly == mapping.assemblyIndex,
                   last.audio == audio, last.offset == offset, last.replacementBindingID == span.replacementBindingID,
                   last.group.to == group.from, last.output.to == output.from {
                    routes[routes.count - 1] = .init(group: .init(from: last.group.from, to: group.to),
                                                    output: .init(from: last.output.from, to: output.to),
                                                    assembly: last.assembly, audio: audio, offset: offset,
                                                    replacementBindingID: span.replacementBindingID,
                                                    headPicture: last.headPicture, tailPicture: tailPicture)
                } else {
                    routes.append(.init(group: group, output: output, assembly: mapping.assemblyIndex,
                                        audio: audio, offset: offset, replacementBindingID: span.replacementBindingID,
                                        headPicture: headPicture, tailPicture: tailPicture))
                }
            }
        }
        return routes
    }

    /// Only observations of the same recognized word in the same output occurrence
    /// can be merged. A repeated take or a separate attachment stays independent.
    func mergeBleed(_ occurrences: [TranscriptOccurrence], separateStreams: Bool = false) -> [TranscriptOccurrence] {
        struct Key: Hashable {
            let word: String
            let assembly: Int?
            let stream: Int?
            let recording: String?
            let channel: Int?
        }
        let byWord = Dictionary(grouping: occurrences) {
            Key(word: $0.wordID, assembly: $0.assemblyIndex, stream: separateStreams ? $0.streamIndex : nil,
                recording: separateStreams ? ($0.sourceID ?? $0.file) : nil,
                channel: separateStreams ? $0.binding?.channel : nil)
        }
        return byWord.values.flatMap { group -> [TranscriptOccurrence] in
            guard group.count > 1, let wordID = group.first?.wordID else { return group }
            let observationOrder = Dictionary((words[wordID]?.observations ?? []).enumerated().map {
                ($0.element.trackID, $0.offset)
            }, uniquingKeysWith: { first, _ in first })
            func preferred(_ first: TranscriptOccurrence, _ second: TranscriptOccurrence) -> Bool {
                if separateStreams && first.observation?.evidence != second.observation?.evidence {
                    if first.observation?.evidence == .recognized { return true }
                    if second.observation?.evidence == .recognized { return false }
                }
                let firstRecognized = first.audibility == .recognized
                let secondRecognized = second.audibility == .recognized
                if firstRecognized != secondRecognized { return firstRecognized }
                let firstOrder = first.trackID.flatMap { observationOrder[$0] } ?? Int.max
                let secondOrder = second.trackID.flatMap { observationOrder[$0] } ?? Int.max
                if firstOrder != secondOrder { return firstOrder < secondOrder }
                return first.id < second.id
            }
            let sorted = group.sorted {
                $0.range.from == $1.range.from ? preferred($0, $1) : $0.range.from < $1.range.from
            }
            var overlaps: [[TranscriptOccurrence]] = []
            var end: RationalTime?
            for hearing in sorted {
                if let last = overlaps.indices.last, let end, hearing.range.from < end {
                    overlaps[last].append(hearing)
                } else {
                    overlaps.append([hearing])
                }
                end = max(end ?? hearing.range.to, hearing.range.to)
            }
            return overlaps.compactMap { cluster in
                let hearings = cluster.sorted(by: preferred)
                guard var representative = hearings.first else { return nil }
                guard hearings.count > 1 else { return representative }
                let alternate = hearings.dropFirst()
                var laneIDs = Set([representative.laneID].compactMap { $0 })
                let otherLanes = alternate.compactMap { hearing -> String? in
                    guard let lane = hearing.laneID, laneIDs.insert(lane).inserted else { return nil }
                    return lane
                }
                representative.heardOnLaneIDs = otherLanes.isEmpty ? nil : otherLanes
                representative.observations = hearings.compactMap(\.observation)
                let extended = alternate.filter {
                    $0.range.from < representative.range.from || representative.range.to < $0.range.to
                }
                if !extended.isEmpty {
                    representative.alternateLaneHearings = extended.map { hearing in
                        var hearing = hearing
                        hearing.space = .currentCut
                        return hearing
                    }
                }
                representative.trackLanes = Dictionary(hearings.compactMap { word in
                    guard let track = word.trackID, let lane = word.laneID else { return nil }
                    return (track, lane)
                }, uniquingKeysWith: { first, _ in first })
                representative.trackSources = trackSources(hearings)
                return representative
            }
        }
    }

    static func audibleRanges(_ track: AudioIndex, shiftedBy offset: RationalTime, hasVideo: Bool) throws -> [MulticamRange] {
        let envelope = try MulticamRange(from: track.start, to: track.end).projectionShifted(by: offset)
        let rate = Int64(max(1, track.stream.sampleRate))
        let samplePeriod = RationalTime(numerator: 1, denominator: rate)
        var result: [MulticamRange] = []

        func append(_ range: MulticamRange, tolerance: RationalTime = .zero) throws {
            guard range.from < range.to, let clipped = range.intersection(envelope) else { return }
            if let previous = result.last {
                let distance = try clipped.from.subtracting(previous.to)
                if distance <= tolerance {
                    result[result.count - 1].to = max(previous.to, clipped.to)
                    return
                }
            }
            result.append(clipped)
        }

        if let first = track.presentationEdits.first, track.stream.sampleRate > 0 {
            let clock = try envelope.from.subtracting(RationalTime(numerator: first.samples.lowerBound, denominator: rate))
            for edit in track.presentationEdits where edit.isAudible {
                try append(MulticamRange(
                    from: RationalTime(numerator: edit.samples.lowerBound, denominator: rate).adding(clock),
                    to: RationalTime(numerator: edit.samples.upperBound, denominator: rate).adding(clock)
                ))
            }
            return result
        }

        guard !track.packets.isEmpty else {
            let gaps = try track.pcmGaps.map { try $0.projectionShifted(by: offset) }
            return complement(gaps, in: envelope)
        }
        let packetClock = track.stream.timeBase
        let coarseClock = packetClock > samplePeriod
        let sampleClock = !hasVideo && track.stream.codec == "flac" && coarseClock
        // Match the probe's tolerance for a rounded packet timestamp on a coarse
        // container clock. Sample-aligned clocks keep even a one-sample hole.
        let tolerance = coarseClock
            ? try packetClock.adding(RationalTime(numerator: 1, denominator: rate * 2)) : .zero
        let packets = track.packets
        let ordered = zip(packets, packets.dropFirst()).allSatisfy { $0.time <= $1.time }
            ? packets : packets.sorted { $0.time < $1.time }
        return try TranscriptPacketRanges.ranges(ordered, skipsFirst: track.stream.codec == "vorbis", sampleClock: sampleClock,
                                                 rate: rate, tolerance: tolerance, packetClock: packetClock,
                                                 offset: offset, envelope: envelope)
    }

    func clippedRanges(_ ranges: [MulticamRange], to envelope: MulticamRange) -> [MulticamRange] {
        let start = ranges.lowerBound { $0.to > envelope.from }
        return ranges[start...].prefix { $0.from < envelope.to }.compactMap { $0.intersection(envelope) }
    }

    func stillGaps(_ items: [StillAssemblyItem]) throws -> [TranscriptCoverageGap] {
        var start = RationalTime.zero
        var gaps: [TranscriptCoverageGap] = []
        for (index, item) in items.enumerated() {
            if let still = item.still {
                let end = try start.adding(still.duration)
                gaps.append(.init(range: .init(from: start, to: end), assemblyIndex: index, clipID: nil,
                                  sourceID: nil, streamIndex: nil, reason: .still))
                start = end
            }
            if let group = item.group { start = try start.adding(group.to.subtracting(group.from)) }
        }
        return gaps
    }

    func sortedGaps(_ gaps: [TranscriptCoverageGap]) -> [TranscriptCoverageGap] {
        gaps.sorted { lhs, rhs in
            if lhs.range.from != rhs.range.from { return lhs.range.from < rhs.range.from }
            if lhs.range.to != rhs.range.to { return lhs.range.to < rhs.range.to }
            if lhs.laneOrder != rhs.laneOrder { return (lhs.laneOrder ?? -1) < (rhs.laneOrder ?? -1) }
            if lhs.streamIndex != rhs.streamIndex { return (lhs.streamIndex ?? -1) < (rhs.streamIndex ?? -1) }
            return lhs.reason.rawValue < rhs.reason.rawValue
        }
    }

    func gapReason(_ coverages: [TranscriptCoverage]) -> TranscriptGapReason? {
        if coverages.contains(.recognized) { return nil }
        if coverages.contains(.failed) { return .failed }
        if coverages.contains(.skipped) { return .skipped }
        return .unbound
    }

    static func complement(_ ranges: [MulticamRange], in envelope: MulticamRange) -> [MulticamRange] {
        var cursor = envelope.from
        var gaps: [MulticamRange] = []
        for range in ranges {
            if cursor < range.from { gaps.append(.init(from: cursor, to: range.from)) }
            cursor = max(cursor, range.to)
        }
        if cursor < envelope.to { gaps.append(.init(from: cursor, to: envelope.to)) }
        return gaps
    }
}

private extension TranscriptProjection {
    func sequenceWords(_ sourceWords: [TranscriptOccurrence], items: [StillSequenceItem]) throws
        -> ([TranscriptOccurrence], [TranscriptCoverageGap]) {
        // Every word of a recording names the same file. Resolving the path asks the file
        // system, so each distinct spelling is resolved once.
        var canonicalFiles: [String: String] = [:]
        var positionsByFile: [String: [Int]] = [:]
        for position in sourceWords.indices {
            guard let file = sourceWords[position].file, sourceWords[position].sourceRange != nil else { continue }
            let resolved: String
            if let known = canonicalFiles[file] {
                resolved = known
            } else {
                resolved = canonical(file)
                canonicalFiles[file] = resolved
            }
            positionsByFile[resolved, default: []].append(position)
        }
        let byFile = positionsByFile.mapValues { positions in
            TranscriptRangeIndex(positions, range: { sourceWords[$0].range }, id: { sourceWords[$0].id })
        }
        let tracksByFile = Dictionary(grouping: tracks.values.compactMap { track -> (String, LocalTrack)? in
            track.file.map { (canonical($0), track) }
        }, by: \.0)
        struct SequenceStream: Hashable {
            let file: String?
            let index: Int?
            let channel: Int?

            init(_ track: LocalTrack) {
                file = track.file
                index = track.streamIndex
                channel = track.binding?.channel
            }
        }
        let sharesStreams = Dictionary(grouping: tracks.values, by: SequenceStream.init).values.contains { $0.count > 1 }
        var audioRanges: [String: [MulticamRange]] = [:]
        var current: [TranscriptOccurrence] = []
        var gaps: [TranscriptCoverageGap] = []
        var start = RationalTime.zero
        for (index, item) in items.enumerated() {
            if let still = item.still {
                let end = try start.adding(still.duration)
                gaps.append(.init(range: .init(from: start, to: end), assemblyIndex: index, clipID: nil,
                                  sourceID: nil, streamIndex: nil, reason: .still))
                start = end
                continue
            }
            guard let clip = item.source else { continue }
            let outputEnd = try start.adding(clip.to.subtracting(clip.from))
            let file = canonical(clip.file)
            let original = clip.originalFile.map(canonical)
            let hasWorkingCopy = original != nil && original != file
            let files = [file] + (original.map { $0 == file ? [] : [$0] } ?? [])
            let replacedOrdinals = Set(clip.replacementNames.keys).union(clip.audioTrack.map { [$0] } ?? [])
            let originalTracks = (original.flatMap { tracksByFile[$0] } ?? []).map(\.1).filter { !$0.bindingChanged }
            let recognizedOriginal = Set(originalTracks.filter { $0.track.coverage == .recognized }.compactMap(\.sequenceOrdinal))
            let originalOrdinals = Set(originalTracks.compactMap(\.sequenceOrdinal))
            let recognizedCopy = Set((tracksByFile[file] ?? []).map(\.1)
                .filter { !$0.bindingChanged && $0.track.coverage == .recognized }.compactMap(\.sequenceOrdinal))
            let useOriginal = originalOrdinals.subtracting(recognizedCopy).union(recognizedOriginal).subtracting(replacedOrdinals)
            let output = MulticamRange(from: start, to: outputEnd)
            // A blade leaves the two halves of a word in touching clips of one recording.
            func joins(_ other: Int, _ edge: (CutSequenceClip) -> Bool) -> Bool {
                // Resolving a path asks the file system, so the times are compared first.
                guard items.indices.contains(other), let neighbour = items[other].source, edge(neighbour) else { return false }
                return canonical(neighbour.file) == file
            }
            let continuesBefore = joins(index - 1) { $0.to == clip.from }
            let continuesAfter = joins(index + 1) { $0.from == clip.to }
            var coverages: [LocalTrack] = []
            for candidate in files {
                let available = (tracksByFile[candidate] ?? []).map(\.1)
                let matching = available.filter { track in
                    guard hasWorkingCopy, !replacedOrdinals.isEmpty else { return candidate == file }
                    guard let ordinal = track.sequenceOrdinal else { return false }
                    if candidate == file {
                        return !useOriginal.contains(ordinal)
                    }
                    return useOriginal.contains(ordinal)
                }
                coverages.append(contentsOf: matching)
                let offsets = Dictionary(grouping: matching.filter { !$0.bindingChanged }, by: \.sequenceOffset)
                for (origin, members) in offsets {
                    let retained = try MulticamRange(from: clip.from, to: clip.to).projectionShifted(by: origin)
                    let delta = try start.subtracting(retained.from)
                    var ranges: [String: [MulticamRange]] = [:]
                    var reportedHoles = Set<SequenceStream>()
                    for track in members {
                        let available: [MulticamRange]
                        if let audio = track.sequenceAudio {
                            if audioRanges[track.track.id] == nil {
                                audioRanges[track.track.id] = try Self.audibleRanges(audio, shiftedBy: origin,
                                                                                hasVideo: track.sequenceHasVideo)
                            }
                            available = clippedRanges(audioRanges[track.track.id] ?? [], to: retained)
                        } else {
                            available = track.hasSequenceMedia ? [] : [retained]
                        }
                        ranges[track.track.id] = available
                        if track.track.coverage == .recognized && reportedHoles.insert(SequenceStream(track)).inserted {
                            try gaps.append(contentsOf: Self.complement(available, in: retained).map {
                                try .init(range: $0.projectionShifted(by: delta), assemblyIndex: index, clipID: clip.id,
                                          sourceID: nil, streamIndex: track.streamIndex, reason: .unavailable)
                            })
                        }
                    }
                    for position in byFile[candidate]?.overlapping(retained) ?? [] {
                        guard let word = words[sourceWords[position].wordID], let id = sourceWords[position].trackID,
                              let track = tracks[id], let availability = ranges[id] else { continue }
                        let heard = sourceWords[position].range
                        let first = availability.lowerBound { $0.to > heard.from }
                        for segment in first..<availability.count {
                            let available = availability[segment]
                            if available.from > heard.to { break }
                            guard let overlap = heard.intersection(available) else { continue }
                            if overlap != heard, try isSnapRemnant(
                                overlap, of: heard,
                                continuesBefore: continuesBefore && overlap.from == retained.from,
                                continuesAfter: continuesAfter && overlap.to == retained.to,
                                headLimit: { track.sequenceMedia.flatMap { $0.snapTolerance(at: clip.from, frames: $0.frames) } },
                                tailLimit: { track.sequenceMedia.flatMap { $0.snapTolerance(at: clip.to, frames: $0.frames) } }) {
                                continue
                            }
                            try current.append(occurrence(word, id: "cut-\(index)-\(segment)-\(sourceWords[position].id)",
                                                          range: overlap.projectionShifted(by: delta), source: overlap,
                                                          original: sourceWords[position].originalSourceRange,
                                                          assembly: index, clip: clip.id, track: track,
                                                          observation: sourceWords[position].observation,
                                                          audibility: sourceWords[position].audibility, partial: overlap != heard))
                        }
                    }
                }
            }
            func reason(for tracks: [LocalTrack]) -> TranscriptGapReason? {
                let valid = tracks.filter { !$0.bindingChanged }.map(\.track.coverage)
                return valid.isEmpty && tracks.contains(where: \.bindingChanged) ? .changed : gapReason(valid)
            }
            if let reason = reason(for: coverages) {
                gaps.append(.init(range: output, assemblyIndex: index, clipID: clip.id, sourceID: nil,
                                  streamIndex: nil, reason: reason))
            } else {
                // Multiple ISO microphones can all describe the same program stream.
                for (stream, members) in Dictionary(grouping: coverages, by: SequenceStream.init) {
                    if let reason = reason(for: members) {
                        gaps.append(.init(range: output, assemblyIndex: index, clipID: clip.id, sourceID: nil,
                                          streamIndex: stream.index, reason: reason))
                    }
                }
            }
            start = outputEnd
        }
        if sharesStreams && !staleMatches { current = mergeBleed(current, separateStreams: true) }
        return (current, sortedGaps(gaps))
    }

}

/// The stretches of a recording its audio packets make audible.
enum TranscriptPacketRanges {
    static func ranges(_ packets: [AudioPacket], skipsFirst: Bool, sampleClock: Bool, rate: Int64,
                       tolerance: RationalTime, packetClock: RationalTime, offset: RationalTime,
                       envelope: MulticamRange) throws -> [MulticamRange] {
        if !sampleClock, let shared = onSharedClock(packets, skipsFirst: skipsFirst, rate: rate, tolerance: tolerance,
                                                    packetClock: packetClock, offset: offset, envelope: envelope) {
            return shared
        }
        return try exactly(packets, skipsFirst: skipsFirst, sampleClock: sampleClock, rate: rate, tolerance: tolerance,
                           offset: offset, envelope: envelope)
    }

    /// Each packet placed with rational arithmetic.
    static func exactly(_ packets: [AudioPacket], skipsFirst: Bool, sampleClock: Bool, rate: Int64,
                        tolerance: RationalTime, offset: RationalTime, envelope: MulticamRange) throws -> [MulticamRange] {
        var result: [MulticamRange] = []

        func append(_ range: MulticamRange, tolerance: RationalTime) throws {
            guard range.from < range.to, let clipped = range.intersection(envelope) else { return }
            if let previous = result.last {
                let distance = try clipped.from.subtracting(previous.to)
                if distance <= tolerance {
                    result[result.count - 1].to = max(previous.to, clipped.to)
                    return
                }
            }
            result.append(clipped)
        }

        var priorSampleEnd: RationalTime?
        var priorDiscard = 0
        for (index, packet) in packets.enumerated() {
            if index == 0, skipsFirst { continue }
            let start: RationalTime
            if sampleClock, packet.decodedSamples > 0, let priorSampleEnd {
                let delta = try packet.time.subtracting(priorSampleEnd)
                if abs(delta.seconds) <= tolerance.seconds {
                    start = priorSampleEnd
                } else {
                    start = packet.time
                }
            } else {
                start = packet.time
            }
            let rawEnd = try packet.time.adding(packet.duration)
            let decodedEnd = packet.decodedSamples > 0
                ? try start.adding(RationalTime(numerator: Int64(packet.decodedSamples), denominator: rate)) : rawEnd
            priorSampleEnd = sampleClock && packet.decodedSamples > 0 ? decodedEnd : nil
            let audibleStart = try start.adding(RationalTime(numerator: Int64(packet.skipSamples), denominator: rate))
            let trimmedEnd = try decodedEnd.subtracting(
                RationalTime(numerator: Int64(packet.discardSamples), denominator: rate))
            let end = sampleClock && packet.decodedSamples > 0 ? trimmedEnd : min(rawEnd, trimmedEnd)
            // Skip/discard metadata describes deliberate missing samples, not timestamp rounding.
            let joinTolerance = packet.skipSamples == 0 && priorDiscard == 0 ? tolerance : .zero
            try append(MulticamRange(from: audibleStart, to: end).projectionShifted(by: offset), tolerance: joinTolerance)
            priorDiscard = packet.discardSamples
        }
        return result
    }

    /// The same ranges for packets whose times all fall on one integer clock, or nil when they
    /// do not or a count would not fit. Hours of audio are hundreds of thousands of packets and
    /// several rational sums each. On a shared clock those sums are integer additions, and the
    /// few merged ranges convert back to the identical times.
    static func onSharedClock(_ packets: [AudioPacket], skipsFirst: Bool, rate: Int64, tolerance: RationalTime,
                              packetClock: RationalTime, offset: RationalTime, envelope: MulticamRange) -> [MulticamRange]? {
        func divisor(_ left: Int64, _ right: Int64) -> Int64 {
            var (left, right) = (left, right)
            while right != 0 { (left, right) = (right, left % right) }
            return left
        }
        var clock = rate
        for denominator in [packetClock.denominator, tolerance.denominator, offset.denominator,
                            envelope.from.denominator, envelope.to.denominator] {
            let (shared, overflow) = (clock / divisor(clock, denominator)).multipliedReportingOverflow(by: denominator)
            guard !overflow else { return nil }
            clock = shared
        }
        func ticks(_ time: RationalTime) -> Int64? {
            guard clock % time.denominator == 0 else { return nil }
            let (count, overflow) = time.numerator.multipliedReportingOverflow(by: clock / time.denominator)
            return overflow ? nil : count
        }
        guard let tolerance = ticks(tolerance), let shift = ticks(offset),
              let lower = ticks(envelope.from), let upper = ticks(envelope.to) else { return nil }
        let sample = clock / rate
        var result: [(from: Int64, to: Int64)] = []
        var priorDiscard = 0
        for (index, packet) in packets.enumerated() {
            if index == 0, skipsFirst { continue }
            guard let start = ticks(packet.time), let duration = ticks(packet.duration) else { return nil }
            let (rawEnd, rawOverflow) = start.addingReportingOverflow(duration)
            let (decoded, decodedOverflow) = Int64(packet.decodedSamples).multipliedReportingOverflow(by: sample)
            let (decodedSum, decodedEndOverflow) = start.addingReportingOverflow(decoded)
            let decodedEnd = packet.decodedSamples > 0 ? decodedSum : rawEnd
            let (skipped, skippedOverflow) = Int64(packet.skipSamples).multipliedReportingOverflow(by: sample)
            let (audibleStart, startOverflow) = start.addingReportingOverflow(skipped)
            let (discarded, discardedOverflow) = Int64(packet.discardSamples).multipliedReportingOverflow(by: sample)
            let (trimmedEnd, trimmedOverflow) = decodedEnd.subtractingReportingOverflow(discarded)
            let (from, fromOverflow) = audibleStart.addingReportingOverflow(shift)
            let (to, toOverflow) = min(rawEnd, trimmedEnd).addingReportingOverflow(shift)
            guard !rawOverflow, !decodedOverflow, !decodedEndOverflow, !skippedOverflow, !startOverflow,
                  !discardedOverflow, !trimmedOverflow, !fromOverflow, !toOverflow else { return nil }
            // Skip/discard metadata describes deliberate missing samples, not timestamp rounding.
            let joinTolerance = packet.skipSamples == 0 && priorDiscard == 0 ? tolerance : 0
            priorDiscard = packet.discardSamples
            let clipped = (from: max(from, lower), to: min(to, upper))
            guard from < to, clipped.from < clipped.to else { continue }
            if let previous = result.last {
                let (distance, overflow) = clipped.from.subtractingReportingOverflow(previous.to)
                guard !overflow else { return nil }
                if distance <= joinTolerance {
                    result[result.count - 1].to = max(previous.to, clipped.to)
                    continue
                }
            }
            result.append(clipped)
        }
        return result.map {
            MulticamRange(from: RationalTime(numerator: $0.from, denominator: clock),
                          to: RationalTime(numerator: $0.to, denominator: clock))
        }
    }
}

/// Positions in a list of occurrences, ordered by where each begins, for finding the ones
/// that overlap a range without copying occurrences to look.
struct TranscriptRangeIndex: Sendable {
    private let positions: [Int]
    private let ranges: [MulticamRange]
    private let latestEnd: [RationalTime]

    /// `id` breaks a tie between occurrences that begin together and is only asked then.
    init(_ positions: [Int], range: (Int) -> MulticamRange, id: (Int) -> String) {
        let ordered = positions.map { (position: $0, range: range($0)) }.sorted {
            if $0.range.from != $1.range.from { return $0.range.from < $1.range.from }
            return id($0.position) < id($1.position)
        }
        self.positions = ordered.map(\.position)
        self.ranges = ordered.map(\.range)
        var end: RationalTime?
        self.latestEnd = ranges.map {
            let next = max(end ?? $0.to, $0.to)
            end = next
            return next
        }
    }

    func overlapping(_ range: MulticamRange) -> [Int] {
        var lower = 0
        var upper = latestEnd.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if latestEnd[middle] < range.from { lower = middle + 1 } else { upper = middle }
        }
        var result: [Int] = []
        while lower < ranges.count, ranges[lower].from < range.to {
            if ranges[lower].intersection(range) != nil { result.append(positions[lower]) }
            lower += 1
        }
        return result
    }
}

private extension TranscriptProjection {
    struct InputCoverageTrack: Sendable {
        let status: TranscriptInputCoverageStatus
        let audio: AudioIndex?
        let audioShift: RationalTime
        let hasVideo: Bool
        let groupOffset: RationalTime?
    }

    static func mediaBounds(_ media: MediaInfo, audio: AudioIndex?) -> MulticamRange? {
        let firstAudio = media.audio.map(\.start).min() ?? audio?.start
        let firstVideo = media.videoStream?.start
        guard let start = firstVideo.map({ min($0, firstAudio ?? $0) }) ?? firstAudio else { return nil }
        let end = max(media.duration, audio?.end ?? media.duration)
        return start < end ? MulticamRange(from: start, to: end) : nil
    }

    func inputCoverageTracks() throws -> [InputCoverageTrack] {
        try document.tracks.compactMap { track in
            guard let local = tracks[track.id] else { return nil }
            let sourceID = local.sourceID ?? (track.coverage == .coverageOnly ? track.sourceID : nil)
            let source = sourceID.flatMap { sources[$0] }
            let media = sourceID.flatMap { multicamMedia[$0] }
            let audio = if let media {
                media.audio.first { $0.stream.index == local.streamIndex }
            } else {
                local.sequenceAudio
            }
            let hasVideo = media?.hasVideo ?? local.sequenceHasVideo
            let trusted = !local.bindingChanged && local.bindingStatus != .offline
            let bounds: MulticamRange?
            if !trusted { bounds = nil }
            else if let media { bounds = Self.mediaBounds(media, audio: audio) }
            else { bounds = local.sequenceMediaBounds }
            let groupOffset: RationalTime?
            if let source {
                groupOffset = replacementOffsets[track.id] ?? source.offset
            } else if multicam == nil, document.clock == .session {
                groupOffset = try track.sessionStart.subtracting(track.origin)
            } else {
                groupOffset = nil
            }
            let lane = lanesByTrack[track.id]
            let status = TranscriptInputCoverageStatus(
                trackID: track.id, name: track.name, attachmentID: attachmentID, sourceID: sourceID,
                file: local.file ?? source?.file, streamIndex: local.streamIndex,
                channel: local.binding?.channel ?? track.channel, coverage: track.coverage,
                bindingStatus: track.coverage == .coverageOnly ? nil : local.bindingStatus,
                bounds: bounds, message: track.error ?? track.warning,
                laneID: lane?.id, laneOrder: lane?.order, laneLabel: lane?.label, laneColorSlot: lane?.colorSlot
            )
            return InputCoverageTrack(status: status, audio: audio, audioShift: media == nil ? local.sequenceOffset : .zero,
                                      hasVideo: hasVideo, groupOffset: groupOffset)
        }
    }

    static func inputCoverage(_ inputs: [InputCoverageTrack], space: TranscriptSpace,
                              filter: TranscriptFilter, group: MulticamRange?) throws -> TranscriptInputCoverageRows {
        guard space == .source || space == .group, filter.assemblyIndex == nil, filter.clipID == nil else { return .init() }
        // Coverage describes stream timing; speaker and inferred-word filters
        // cannot change the physical recording or its recognition status.
        var rows = TranscriptInputCoverageRows()
        for input in inputs {
            try Task.checkCancellation()
            let status = input.status
            guard filter.laneID == nil || filter.laneID == status.laneID,
                  filter.trackID == nil || filter.trackID == status.trackID,
                  filter.sourceID == nil || filter.sourceID == status.sourceID,
                  filter.file == nil || filter.file == status.file else { continue }
            let offset = space == .source ? RationalTime.zero : input.groupOffset
            let trackBounds = try offset.flatMap { offset in try status.bounds?.projectionShifted(by: offset) }
            let displayBounds: MulticamRange?
            if space == .group, let group { displayBounds = trackBounds?.intersection(group) }
            else { displayBounds = trackBounds }
            rows.tracks.append(.init(trackID: status.trackID, name: status.name, attachmentID: status.attachmentID,
                                     sourceID: status.sourceID, file: status.file, streamIndex: status.streamIndex,
                                     channel: status.channel, coverage: status.coverage, bindingStatus: status.bindingStatus,
                                     bounds: displayBounds, message: status.message,
                                     laneID: status.laneID, laneOrder: status.laneOrder,
                                     laneLabel: status.laneLabel, laneColorSlot: status.laneColorSlot))
            guard let offset, trackBounds != nil else { continue }
            func gap(_ range: MulticamRange, reason: TranscriptGapReason) -> TranscriptCoverageGap {
                .init(range: range, laneID: status.laneID, laneOrder: status.laneOrder,
                      laneLabel: status.laneLabel, laneColorSlot: status.laneColorSlot,
                      assemblyIndex: nil, clipID: nil, sourceID: status.sourceID,
                      streamIndex: status.streamIndex, reason: reason, trackID: status.trackID,
                      file: status.file, attachmentID: status.attachmentID)
            }
            if space == .group, let group, status.sourceID != nil {
                rows.gaps += complement(displayBounds.map { [$0] } ?? [], in: group).map { gap($0, reason: .unavailable) }
            }
            guard let envelope = displayBounds else { continue }
            if status.coverage == .coverageOnly {
                rows.gaps.append(gap(envelope, reason: .silence))
                continue
            }
            guard let audio = input.audio else {
                rows.gaps.append(gap(envelope, reason: .unavailable))
                continue
            }
            let audioOffset = try input.audioShift.adding(offset)
            let audible = try audibleRanges(audio, shiftedBy: audioOffset, hasVideo: input.hasVideo)
                .compactMap { $0.intersection(envelope) }
            rows.gaps += complement(audible, in: envelope).map { gap($0, reason: .unavailable) }
            switch status.coverage {
            case .failed: rows.gaps += audible.map { gap($0, reason: .failed) }
            case .skipped: rows.gaps += audible.map { gap($0, reason: .skipped) }
            case .recognized, .coverageOnly: break
            }
            // Activity and speech observations are separate evidence. A silent
            // level frame does not establish a presentation-clock discontinuity.
        }
        rows.gaps.sort {
            if $0.range.from != $1.range.from { return $0.range.from < $1.range.from }
            if $0.range.to != $1.range.to { return $0.range.to < $1.range.to }
            return ($0.trackID ?? "") < ($1.trackID ?? "")
        }
        return rows
    }
}
