import Foundation

public enum TranscriptClock: String, Codable, Sendable {
    /// Coordinates in the source presentation clock or the provider's session sample clock.
    case presentation, session
    /// Projected coordinates after MPCut applies synchronization or routes the retained edit.
    case group, currentCut = "current_cut"
}

public enum TranscriptPrecision: String, Codable, Sendable {
    case word, cue
}

public enum TranscriptEvidence: String, Codable, Sendable {
    case recognized, inferred
}

public enum TranscriptCoverage: String, Codable, Sendable {
    case recognized, skipped, failed
    case coverageOnly = "coverage_only"
}

public enum TranscriptRole: String, Codable, Sendable {
    case isolatedMic = "isolated_mic"
    case mixedAudio = "mixed_audio"
    case unknown
}

public struct TranscriptActivityFrame: Codable, Equatable, Sendable {
    public var start: RationalTime
    public var end: RationalTime
    public var level: Double

    public init(start: RationalTime, end: RationalTime, level: Double) {
        self.start = start
        self.end = end
        self.level = level
    }
}

public struct TranscriptTrack: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourceID = "source_id"
        case streamIndex = "audio_stream_index"
        case channel
        case origin
        case sessionStart = "session_start"
        case coverage
        case role
        case activity
        case words
        case speakers
        case streamEvidence = "stream_evidence"
        case error
        case warning
        case approximateClock = "approximate_clock"
    }
    public var id: String
    public var name: String
    public var sourceID: String?
    public var streamIndex: Int?
    public var channel: Int?
    public var origin: RationalTime
    public var sessionStart: RationalTime
    public var coverage: TranscriptCoverage
    public var role: TranscriptRole
    public var activity: [TranscriptActivityFrame]
    public var words: [TranscriptWord]?
    public var speakers: [TranscriptSpeaker]?
    public var streamEvidence: TranscriptJSONValue?
    public var error: String?
    public var warning: String?
    public var approximateClock: Bool?

    public init(id: String, name: String, sourceID: String? = nil, streamIndex: Int? = nil, channel: Int? = nil,
                origin: RationalTime = .zero, sessionStart: RationalTime = .zero, coverage: TranscriptCoverage = .recognized,
                role: TranscriptRole = .unknown, activity: [TranscriptActivityFrame] = [],
                words: [TranscriptWord]? = nil, speakers: [TranscriptSpeaker]? = nil,
                streamEvidence: TranscriptJSONValue? = nil, error: String? = nil, warning: String? = nil,
                approximateClock: Bool? = nil) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.streamIndex = streamIndex
        self.channel = channel
        self.origin = origin
        self.sessionStart = sessionStart
        self.coverage = coverage
        self.role = role
        self.activity = activity
        self.words = words
        self.speakers = speakers
        self.streamEvidence = streamEvidence
        self.error = error
        self.warning = warning
        self.approximateClock = approximateClock
    }
}

extension TranscriptTrack {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try fields.decode(String.self, forKey: .id)
        self.name = try fields.decode(String.self, forKey: .name)
        self.sourceID = try fields.decodeIfPresent(String.self, forKey: .sourceID)
        self.streamIndex = try fields.decodeIfPresent(Int.self, forKey: .streamIndex)
        self.channel = try fields.decodeIfPresent(Int.self, forKey: .channel)
        self.origin = try fields.decode(RationalTime.self, forKey: .origin)
        self.sessionStart = try fields.decode(RationalTime.self, forKey: .sessionStart)
        self.coverage = try fields.decode(TranscriptCoverage.self, forKey: .coverage)
        self.role = try fields.decode(TranscriptRole.self, forKey: .role)
        self.activity = try fields.decode([TranscriptActivityFrame].self, forKey: .activity)
        self.words = try fields.decodeIfPresent([TranscriptWord].self, forKey: .words)
        self.speakers = try fields.decodeIfPresent([TranscriptSpeaker].self, forKey: .speakers)
        self.streamEvidence = try fields.decodeIfPresent(TranscriptJSONValue.self, forKey: .streamEvidence)
        self.error = try fields.decodeIfPresent(String.self, forKey: .error)
        self.warning = try fields.decodeIfPresent(String.self, forKey: .warning)
        self.approximateClock = try fields.decodeIfPresent(Bool.self, forKey: .approximateClock)
    }
}

public struct TranscriptSpeaker: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct TranscriptObservation: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case wordID = "word_id"
        case text
        case start
        case end
        case evidence
        case basis
        case speakerID = "speaker_id"
        case confidence
    }
    public var trackID: String
    public var wordID: String?
    public var text: String?
    /// Bounds are on the source presentation clock, regardless of the conversation clock.
    public var start: RationalTime
    public var end: RationalTime
    public var evidence: TranscriptEvidence
    public var basis: String?
    public var speakerID: String?
    public var confidence: Double?

    public init(trackID: String, wordID: String? = nil, text: String? = nil, start: RationalTime, end: RationalTime,
                evidence: TranscriptEvidence, basis: String? = nil, speakerID: String? = nil, confidence: Double? = nil) {
        self.trackID = trackID
        self.wordID = wordID
        self.text = text
        self.start = start
        self.end = end
        self.evidence = evidence
        self.basis = basis
        self.speakerID = speakerID
        self.confidence = confidence
    }
}

extension TranscriptObservation {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.trackID = try fields.decode(String.self, forKey: .trackID)
        self.wordID = try fields.decodeIfPresent(String.self, forKey: .wordID)
        self.text = try fields.decodeIfPresent(String.self, forKey: .text)
        self.start = try fields.decode(RationalTime.self, forKey: .start)
        self.end = try fields.decode(RationalTime.self, forKey: .end)
        self.evidence = try fields.decode(TranscriptEvidence.self, forKey: .evidence)
        self.basis = try fields.decodeIfPresent(String.self, forKey: .basis)
        self.speakerID = try fields.decodeIfPresent(String.self, forKey: .speakerID)
        self.confidence = try fields.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case start
        case end
        case utteranceID = "utterance_id"
        case speakerID = "speaker_id"
        case precision
        case observations
        case candidateTrackIDs = "candidate_track_ids"
        case confidence
        case storedProjection = "projection"
    }
    public var id: String
    public var text: String
    public var start: RationalTime
    public var end: RationalTime
    public var utteranceID: String?
    public var speakerID: String?
    public var precision: TranscriptPrecision
    public var observations: [TranscriptObservation]
    public var candidateTrackIDs: [String]?
    public var confidence: Double?
    public var projection: TranscriptWordProjection? {
        get { storedProjection?.value }
        set { storedProjection = newValue.map(StoredProjection.init) }
    }

    /// Only a word imported from an exported group or cut has a projection, and one is larger
    /// than the rest of the word. Hours of recognized words would each set that room aside,
    /// in the document and in every table built from it, so a word holds a reference instead.
    /// The reference is never written through. A change stores a new one, which leaves a
    /// copy of the word with the projection it was copied with.
    private var storedProjection: StoredProjection?

    private final class StoredProjection: Encodable, Equatable, Sendable {
        let value: TranscriptWordProjection

        init(_ value: TranscriptWordProjection) {
            self.value = value
        }

        static func == (first: StoredProjection, second: StoredProjection) -> Bool {
            first === second || first.value == second.value
        }

        /// Writes the projection itself, so a word encodes as it does with the projection inline.
        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }

    public init(id: String, text: String, start: RationalTime, end: RationalTime, utteranceID: String? = nil,
                speakerID: String? = nil, precision: TranscriptPrecision = .word, observations: [TranscriptObservation] = [],
                candidateTrackIDs: [String]? = nil, confidence: Double? = nil, projection: TranscriptWordProjection? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.utteranceID = utteranceID
        self.speakerID = speakerID
        self.precision = precision
        self.observations = observations
        self.candidateTrackIDs = candidateTrackIDs
        self.confidence = confidence
        self.storedProjection = projection.map(StoredProjection.init)
    }
}

extension TranscriptWord {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try fields.decode(String.self, forKey: .id)
        self.text = try fields.decode(String.self, forKey: .text)
        self.start = try fields.decode(RationalTime.self, forKey: .start)
        self.end = try fields.decode(RationalTime.self, forKey: .end)
        self.utteranceID = try fields.decodeIfPresent(String.self, forKey: .utteranceID)
        self.speakerID = try fields.decodeIfPresent(String.self, forKey: .speakerID)
        self.precision = try fields.decode(TranscriptPrecision.self, forKey: .precision)
        self.observations = try fields.decode([TranscriptObservation].self, forKey: .observations)
        self.candidateTrackIDs = try fields.decodeIfPresent([String].self, forKey: .candidateTrackIDs)
        self.confidence = try fields.decodeIfPresent(Double.self, forKey: .confidence)
        self.storedProjection = try fields.decodeIfPresent(TranscriptWordProjection.self, forKey: .storedProjection)
            .map(StoredProjection.init)
    }
}

public struct TranscriptWordProjection: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case clock
        case wordID = "word_id"
        case attachmentID = "attachment_id"
        case originalText = "original_text"
        case originalSpeakerID = "original_speaker_id"
        case originalSourceStart = "original_source_start"
        case originalSourceEnd = "original_source_end"
        case trackID = "track_id"
        case sourceID = "source_id"
        case streamIndex = "audio_stream_index"
        case routedSourceID = "routed_source_id"
        case routedStreamIndex = "routed_stream_index"
        case clipID = "clip_id"
        case assemblyIndex = "assembly_index"
        case partial
        case staleMatches = "stale_matches"
    }
    public var clock: TranscriptClock
    public var wordID: String
    public var attachmentID: String?
    public var originalText: String
    public var originalSpeakerID: String?
    public var originalSourceStart: RationalTime?
    public var originalSourceEnd: RationalTime?
    public var trackID: String?
    public var sourceID: String?
    public var streamIndex: Int?
    public var routedSourceID: String?
    public var routedStreamIndex: Int?
    public var clipID: String?
    public var assemblyIndex: Int?
    public var partial: Bool
    public var staleMatches: Bool
}

extension TranscriptWordProjection {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.clock = try fields.decode(TranscriptClock.self, forKey: .clock)
        self.wordID = try fields.decode(String.self, forKey: .wordID)
        self.attachmentID = try fields.decodeIfPresent(String.self, forKey: .attachmentID)
        self.originalText = try fields.decode(String.self, forKey: .originalText)
        self.originalSpeakerID = try fields.decodeIfPresent(String.self, forKey: .originalSpeakerID)
        self.originalSourceStart = try fields.decodeIfPresent(RationalTime.self, forKey: .originalSourceStart)
        self.originalSourceEnd = try fields.decodeIfPresent(RationalTime.self, forKey: .originalSourceEnd)
        self.trackID = try fields.decodeIfPresent(String.self, forKey: .trackID)
        self.sourceID = try fields.decodeIfPresent(String.self, forKey: .sourceID)
        self.streamIndex = try fields.decodeIfPresent(Int.self, forKey: .streamIndex)
        self.routedSourceID = try fields.decodeIfPresent(String.self, forKey: .routedSourceID)
        self.routedStreamIndex = try fields.decodeIfPresent(Int.self, forKey: .routedStreamIndex)
        self.clipID = try fields.decodeIfPresent(String.self, forKey: .clipID)
        self.assemblyIndex = try fields.decodeIfPresent(Int.self, forKey: .assemblyIndex)
        self.partial = try fields.decode(Bool.self, forKey: .partial)
        self.staleMatches = try fields.decode(Bool.self, forKey: .staleMatches)
    }
}

public struct TranscriptProvenance: Codable, Equatable, Sendable {
    public var source: String
    public var model: String?
    public var device: String?
    public var language: String?
    public var duration: RationalTime
    public var metadata: TranscriptJSONValue
}

public struct TranscriptDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case clock
        case tracks
        case speakers
        case words
        case approximateClock = "approximate_clock"
        case jobID = "job_id"
        case fingerprint
        case provenance
    }
    public var schemaVersion: Int
    public var clock: TranscriptClock
    public var tracks: [TranscriptTrack]
    public var speakers: [TranscriptSpeaker]
    public var words: [TranscriptWord]
    public var approximateClock: Bool
    public var jobID: String?
    public var fingerprint: String?
    public var provenance: TranscriptProvenance?

    public init(schemaVersion: Int = Self.currentSchemaVersion, clock: TranscriptClock, tracks: [TranscriptTrack] = [], speakers: [TranscriptSpeaker] = [],
                words: [TranscriptWord] = [], approximateClock: Bool = false, jobID: String? = nil, fingerprint: String? = nil,
                provenance: TranscriptProvenance? = nil) {
        self.schemaVersion = schemaVersion
        self.clock = clock
        self.tracks = tracks
        self.speakers = speakers
        self.words = words
        self.approximateClock = approximateClock
        self.jobID = jobID
        self.fingerprint = fingerprint
        self.provenance = provenance
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CutError(code: "unsupported_transcript_version", message: "Unsupported transcript version \(schemaVersion)")
        }
        let trackIDs = try Self.identifiers(tracks.map(\.id), kind: "track")
        let speakerIDs = try Self.identifiers(speakers.map(\.id), kind: "speaker")
        _ = try Self.identifiers(words.map(\.id), kind: "word")
        let observedTracks = Set(tracks.lazy.filter { $0.coverage == .recognized }.map(\.id))
        // One table per track both proves its word IDs distinct and finds the word an
        // observation names. It holds positions, so hours of words are hashed once and not copied.
        var localWordsByTrack: [String: (words: [TranscriptWord], positions: [String: Int])] = [:]
        for track in tracks {
            guard track.streamIndex.map({ $0 >= 0 }) ?? true, track.channel.map({ $0 >= 0 }) ?? true,
                  !track.name.isEmpty else {
                throw Self.invalid("Invalid track \(track.id)")
            }
            let localSpeakerIDs = try Self.identifiers((track.speakers ?? []).map(\.id), kind: "local speaker")
            if let localWords = track.words {
                var positions: [String: Int] = [:]
                positions.reserveCapacity(localWords.count)
                for (position, word) in localWords.enumerated() {
                    guard !word.id.isEmpty, positions.updateValue(position, forKey: word.id) == nil else {
                        throw Self.invalid("Duplicate or empty local word ID")
                    }
                }
                localWordsByTrack[track.id] = (localWords, positions)
            }
            for word in track.words ?? [] {
                guard track.coverage == .recognized, word.start <= word.end, !word.text.isEmpty,
                      word.observations.isEmpty, word.speakerID.map(localSpeakerIDs.contains) ?? true,
                      word.confidence.map({ (0...1).contains($0) }) ?? true else {
                    throw Self.invalid("Invalid local word \(word.id) on track \(track.id)")
                }
            }
            for frame in track.activity {
                guard frame.start < frame.end, frame.level.isFinite, frame.level >= 0 else {
                    throw Self.invalid("Invalid activity on track \(track.id)")
                }
            }
        }
        func validSpeaker(_ id: String?) -> Bool {
            id.map(speakerIDs.contains) ?? true
        }
        func validConfidence(_ confidence: Double?) -> Bool {
            confidence.map { (0...1).contains($0) } ?? true
        }
        for word in words {
            guard word.start <= word.end, !word.text.isEmpty || word.projection != nil, validSpeaker(word.speakerID),
                  validConfidence(word.confidence), word.utteranceID != "",
                  word.candidateTrackIDs?.allSatisfy(trackIDs.contains) ?? true else {
                throw Self.invalid("Invalid word or cue \(word.id)")
            }
            for observation in word.observations {
                guard trackIDs.contains(observation.trackID), observation.start <= observation.end,
                      validSpeaker(observation.speakerID), validConfidence(observation.confidence) else {
                    throw Self.invalid("Invalid track observation for \(word.id)")
                }
                switch observation.evidence {
                case .recognized:
                    guard observedTracks.contains(observation.trackID) else {
                        throw Self.invalid("Recognized observation on a track without recognition")
                    }
                    if let localWords = localWordsByTrack[observation.trackID] {
                        guard let wordID = observation.wordID, let position = localWords.positions[wordID],
                              case let local = localWords.words[position],
                              local.start == observation.start, local.end == observation.end,
                              observation.text.map({ $0 == local.text }) ?? true else {
                            throw Self.invalid("Recognized observation does not match a stored track word")
                        }
                    }
                case .inferred:
                    guard let basis = observation.basis, !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw Self.invalid("Inferred observation requires a basis")
                    }
                }
            }
        }
    }

    private static func identifiers(_ values: [String], kind: String) throws -> Set<String> {
        let ids = Set(values)
        guard ids.count == values.count, !ids.contains("") else {
            throw invalid("Duplicate or empty \(kind) ID")
        }
        return ids
    }

    static func invalid(_ message: String) -> CutError {
        CutError(code: "invalid_transcript", message: message)
    }

    /// The document as MPCut writes it. Audio levels are measured into the recording's analysis
    /// sidecar. A transcript made before that carried a level frame for every 20 ms of every
    /// track, which came to most of its size.
    func withoutActivity() -> TranscriptDocument {
        guard tracks.contains(where: { !$0.activity.isEmpty }) else { return self }
        var document = self
        for index in document.tracks.indices { document.tracks[index].activity = [] }
        return document
    }
}

extension TranscriptDocument {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        self.clock = try fields.decode(TranscriptClock.self, forKey: .clock)
        self.tracks = try fields.decode([TranscriptTrack].self, forKey: .tracks)
        self.speakers = try fields.decode([TranscriptSpeaker].self, forKey: .speakers)
        self.words = try fields.decode([TranscriptWord].self, forKey: .words)
        self.approximateClock = try fields.decode(Bool.self, forKey: .approximateClock)
        self.jobID = try fields.decodeIfPresent(String.self, forKey: .jobID)
        self.fingerprint = try fields.decodeIfPresent(String.self, forKey: .fingerprint)
        self.provenance = try fields.decodeIfPresent(TranscriptProvenance.self, forKey: .provenance)
    }
}
