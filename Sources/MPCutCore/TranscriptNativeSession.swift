import Foundation

public enum TranscriptJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Decimal)
    case string(String)
    case array([Self])
    case object([String: Self])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .boolean(decoded) }
        else if let decoded = try? value.decode(Decimal.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([Self].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .boolean(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }
}

struct TranscriptNativeSession: Decodable {
    struct Bounds {
        let start: RationalTime
        let end: RationalTime

        init(start: Int64, end: Int64, rate: Int64, origin: RationalTime, signed: Bool = false) throws {
            guard start <= end, signed || start >= 0 else {
                throw TranscriptDocument.invalid("Invalid sample bounds \(start)..<\(end)")
            }
            self.start = try origin.adding(RationalTime(numerator: start, denominator: rate))
            self.end = try origin.adding(RationalTime(numerator: end, denominator: rate))
        }
    }

    struct Activity: Decodable {
        let start_sample: Int64
        let end_sample: Int64
        let level: Double
    }

    struct Track: Decodable {
        let id: String
        let name: String
        let source_id: String?
        let stream_index: Int?
        let channel: Int?
        let origin: RationalTime
        let session_start: RationalTime
        let coverage: TranscriptCoverage
        let role: TranscriptRole
        let activity: [Activity]?
        let words: [Word]?
        let speakers: [TranscriptSpeaker]?
        let stream_evidence: TranscriptJSONValue?
        let error: String?
        let warning: String?

        func value(rate: Int64) throws -> TranscriptTrack {
            let frames = try (activity ?? []).map { item in
                guard item.start_sample >= 0, item.start_sample < item.end_sample,
                      item.level.isFinite, item.level >= 0 else {
                    throw TranscriptDocument.invalid("Invalid activity on track \(id)")
                }
                let bounds = try Bounds(start: item.start_sample, end: item.end_sample, rate: rate, origin: origin)
                return TranscriptActivityFrame(start: bounds.start, end: bounds.end, level: item.level)
            }
            let localWords = try words?.map { item in
                guard item.observations?.isEmpty != false else {
                    throw TranscriptDocument.invalid("Track-local word cannot contain cross-track observations")
                }
                let bounds = try Bounds(start: item.start_sample, end: item.end_sample, rate: rate, origin: origin)
                return item.value(bounds: bounds, observations: [])
            }
            return TranscriptTrack(id: id, name: name, sourceID: source_id, streamIndex: stream_index, channel: channel,
                                   origin: origin, sessionStart: session_start, coverage: coverage, role: role,
                                   activity: frames, words: localWords, speakers: speakers, streamEvidence: stream_evidence,
                                   error: error, warning: warning)
        }
    }

    struct Observation: Decodable {
        let track_id: String
        let word_id: String?
        let text: String?
        let start_sample: Int64
        let end_sample: Int64
        let evidence: TranscriptEvidence
        let basis: String?
        let speaker_id: String?
        let confidence: Double?

        func value(rate: Int64, origin: RationalTime) throws -> TranscriptObservation {
            let bounds = try Bounds(start: start_sample, end: end_sample, rate: rate, origin: origin)
            return TranscriptObservation(trackID: track_id, wordID: word_id, text: text, start: bounds.start, end: bounds.end,
                                         evidence: evidence, basis: basis, speakerID: speaker_id, confidence: confidence)
        }
    }

    struct Word: Decodable {
        let id: String
        let text: String
        let start_sample: Int64
        let end_sample: Int64
        let utterance_id: String?
        let speaker_id: String?
        let precision: TranscriptPrecision
        let observations: [Observation]?
        let confidence: Double?

        func value(bounds: Bounds, observations: [TranscriptObservation]) -> TranscriptWord {
            TranscriptWord(id: id, text: text, start: bounds.start, end: bounds.end, utteranceID: utterance_id,
                           speakerID: speaker_id, precision: precision, observations: observations, confidence: confidence)
        }
    }

    let version: Int
    let clock: TranscriptClock
    let sample_rate: Int64
    let job_id: String?
    let fingerprint: String?
    let tracks: [Track]
    let speakers: [TranscriptSpeaker]
    let words: [Word]

    func document() throws -> TranscriptDocument {
        guard version == 1 else {
            throw CutError(code: "unsupported_transcript_version", message: "Unsupported transcript version \(version)")
        }
        guard sample_rate == 16_000 else {
            throw TranscriptDocument.invalid("Expected a 16,000 Hz native sample clock")
        }
        guard clock == .session || (clock == .presentation && tracks.count == 1) else {
            throw TranscriptDocument.invalid("Expected a native session clock or a presentation clock with one source track")
        }
        let trackOrigins = Dictionary(tracks.map { ($0.id, $0.origin) }, uniquingKeysWith: { first, _ in first })
        let clockOrigin = clock == .presentation ? tracks[0].origin : .zero
        let convertedWords = try words.map { word in
            let bounds = try Bounds(start: word.start_sample, end: word.end_sample, rate: sample_rate,
                                    origin: clockOrigin, signed: clock == .session)
            let observations = try (word.observations ?? []).map { observation in
                guard let origin = trackOrigins[observation.track_id] else {
                    throw TranscriptDocument.invalid("Unknown observation track \(observation.track_id)")
                }
                return try observation.value(rate: sample_rate, origin: origin)
            }
            return word.value(bounds: bounds, observations: observations)
        }
        return TranscriptDocument(clock: clock, tracks: try tracks.map { try $0.value(rate: sample_rate) },
                                  speakers: speakers, words: convertedWords, jobID: job_id, fingerprint: fingerprint)
    }
}
