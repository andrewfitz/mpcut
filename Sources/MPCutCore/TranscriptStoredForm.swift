import Compression
import Foundation

/// The form a project keeps an attached transcript in. Nobody reads these files, and a long
/// interview holds tens of thousands of words, so the form spends as little as it can on each:
///
/// - A time is the text `n` or `n/d` in place of an object naming both parts. A word's projection
///   and the provenance are rare and keep their exported shape.
/// - A word and an observation use one-letter field names and leave out a field at its usual
///   value: `word` precision, `recognized` evidence, no observations.
/// - An observation names its track by position in `tracks`. It leaves out the bounds, text
///   and speaker it shares with the track's own word of that ID or, where the track keeps no
///   such word, with the word it belongs to. A written `null` means the field is absent.
/// - A track carries no activity. Audio levels belong to the recording's analysis sidecar.
/// - The JSON is LZFSE-compressed behind a short header.
///
/// The exported JSON is the schema version 2 document. This form converts to and from it
/// exactly, apart from the activity it leaves behind.
enum TranscriptStoredForm {
    static let schemaVersion = 3

    // MARK: Container

    /// A NUL first byte cannot begin JSON or a subtitle file.
    private static let magic: [UInt8] = [0x00, 0x4D, 0x50, 0x43, 0x54, 0x5A, 0x31, 0x0A]
    private static let headerSize = magic.count + 8
    private static let maximumSize = Int(Int32.max)

    static func encode(_ document: TranscriptDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(Document(document))
        return compressed(json) ?? json
    }

    private static func compressed(_ json: Data) -> Data? {
        guard !json.isEmpty, json.count <= maximumSize else { return nil }
        // A stream that cannot shrink its input grows it a little.
        let capacity = json.count + json.count / 64 + 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let written = json.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(buffer, capacity, base, source.count, nil, COMPRESSION_LZFSE)
        }
        guard written > 0 else { return nil }
        var result = Data(capacity: headerSize + written)
        result.append(contentsOf: magic)
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { result.append(contentsOf: $0) }
        result.append(buffer, count: written)
        return result
    }

    /// The JSON inside a compressed transcript, or nil for bytes that are not one.
    static func expanded(_ data: Data) throws -> Data? {
        guard data.starts(with: magic) else { return nil }
        let damaged = TranscriptDocument.invalid("The compressed transcript is damaged.")
        guard data.count > headerSize else { throw damaged }
        let size = data.dropFirst(magic.count).prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard size > 0, size <= UInt64(maximumSize) else { throw damaged }
        let capacity = Int(size)
        // One spare byte shows a stream that holds more than it declares.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity + 1)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(buffer, capacity + 1, base + headerSize, source.count - headerSize,
                                             nil, COMPRESSION_LZFSE)
        }
        guard written == capacity else {
            buffer.deallocate()
            throw damaged
        }
        return Data(bytesNoCopy: UnsafeMutableRawPointer(buffer), count: capacity, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
    }

    // MARK: Fields

    struct Time: Codable {
        let value: RationalTime

        init(_ value: RationalTime) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let value = Self.parse(text.utf8) else {
                throw TranscriptDocument.invalid("Invalid transcript time ‘\(text)’")
            }
            self.value = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value.denominator == 1 ? String(value.numerator)
                                                         : "\(value.numerator)/\(value.denominator)")
        }

        /// Digits, with an optional leading minus and an optional `/` before a positive denominator.
        private static func parse(_ text: String.UTF8View) -> RationalTime? {
            var index = text.startIndex
            func integer(signed: Bool) -> Int64? {
                var negative = false
                if signed, index < text.endIndex, text[index] == 0x2D {
                    negative = true
                    text.formIndex(after: &index)
                }
                let first = index
                var magnitude: UInt64 = 0
                while index < text.endIndex, case let byte = text[index], (0x30...0x39).contains(byte) {
                    let (scaled, overflow) = magnitude.multipliedReportingOverflow(by: 10)
                    let (sum, carry) = scaled.addingReportingOverflow(UInt64(byte - 0x30))
                    guard !overflow, !carry else { return nil }
                    magnitude = sum
                    text.formIndex(after: &index)
                }
                guard index > first else { return nil }
                if negative {
                    guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
                    return magnitude == UInt64(Int64.max) + 1 ? .min : -Int64(magnitude)
                }
                return magnitude <= UInt64(Int64.max) ? Int64(magnitude) : nil
            }
            guard let numerator = integer(signed: true) else { return nil }
            if index == text.endIndex { return RationalTime(numerator: numerator) }
            guard text[index] == 0x2F else { return nil }
            text.formIndex(after: &index)
            guard let denominator = integer(signed: false), denominator > 0, index == text.endIndex else { return nil }
            return RationalTime(numerator: numerator, denominator: denominator)
        }
    }

    /// A field an observation may share with the word it stands beside.
    enum Shared<Value: Codable & Equatable> {
        case shared
        case own(Value?)

        init(_ value: Value?, sharing other: Value?) {
            self = value == other ? .shared : .own(value)
        }

        func value(sharing other: Value?) -> Value? {
            switch self {
            case .shared: return other
            case .own(let value): return value
            }
        }

        init<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws {
            guard container.contains(key) else {
                self = .shared
                return
            }
            self = .own(try container.decodeNil(forKey: key) ? nil : container.decode(Value.self, forKey: key))
        }

        func encode<Key: CodingKey>(to container: inout KeyedEncodingContainer<Key>, forKey key: Key) throws {
            switch self {
            case .shared: break
            case .own(nil): try container.encodeNil(forKey: key)
            case .own(let value?): try container.encode(value, forKey: key)
            }
        }
    }

    // MARK: Rows

    struct Observation: Codable {
        private enum CodingKeys: String, CodingKey {
            case track = "r"
            case wordID = "w"
            case text = "x"
            case start = "s"
            case end = "e"
            case evidence = "v"
            case basis = "b"
            case speakerID = "p"
            case confidence = "c"
        }

        var track: Int
        var wordID: String?
        var text: Shared<String>
        var bounds: (start: RationalTime, end: RationalTime)?
        var evidence: TranscriptEvidence
        var basis: String?
        var speakerID: Shared<String>
        var confidence: Double?

        init(_ observation: TranscriptObservation, of word: TranscriptWord, tables: Tables) throws {
            guard let track = tables.positions[observation.trackID] else {
                throw TranscriptDocument.invalid("Unknown observation track \(observation.trackID)")
            }
            let own = observation.wordID.flatMap { tables.words[track][$0] }
            let start = own?.start ?? word.start
            let end = own?.end ?? word.end
            self.track = track
            wordID = observation.wordID
            text = .init(observation.text, sharing: own?.text ?? word.text)
            bounds = observation.start == start && observation.end == end ? nil : (observation.start, observation.end)
            evidence = observation.evidence
            basis = observation.basis
            speakerID = .init(observation.speakerID, sharing: word.speakerID)
            confidence = observation.confidence
        }

        func observation(of word: TranscriptWord, tables: Tables) throws -> TranscriptObservation {
            guard tables.ids.indices.contains(track) else {
                throw TranscriptDocument.invalid("Unknown observation track at position \(track)")
            }
            let own = wordID.flatMap { tables.words[track][$0] }
            return TranscriptObservation(trackID: tables.ids[track], wordID: wordID,
                                         text: text.value(sharing: own?.text ?? word.text),
                                         start: bounds?.start ?? own?.start ?? word.start,
                                         end: bounds?.end ?? own?.end ?? word.end,
                                         evidence: evidence, basis: basis,
                                         speakerID: speakerID.value(sharing: word.speakerID), confidence: confidence)
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            track = try fields.decode(Int.self, forKey: .track)
            wordID = try fields.decodeIfPresent(String.self, forKey: .wordID)
            text = try .init(from: fields, forKey: .text)
            let start = try fields.decodeIfPresent(Time.self, forKey: .start)
            let end = try fields.decodeIfPresent(Time.self, forKey: .end)
            switch (start, end) {
            case (nil, nil): bounds = nil
            case let (start?, end?): bounds = (start.value, end.value)
            default: throw TranscriptDocument.invalid("An observation gives both of its bounds or neither")
            }
            evidence = try fields.decodeIfPresent(TranscriptEvidence.self, forKey: .evidence) ?? .recognized
            basis = try fields.decodeIfPresent(String.self, forKey: .basis)
            speakerID = try .init(from: fields, forKey: .speakerID)
            confidence = try fields.decodeIfPresent(Double.self, forKey: .confidence)
        }

        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(track, forKey: .track)
            try fields.encodeIfPresent(wordID, forKey: .wordID)
            try text.encode(to: &fields, forKey: .text)
            if let bounds {
                try fields.encode(Time(bounds.start), forKey: .start)
                try fields.encode(Time(bounds.end), forKey: .end)
            }
            if evidence != .recognized { try fields.encode(evidence, forKey: .evidence) }
            try fields.encodeIfPresent(basis, forKey: .basis)
            try speakerID.encode(to: &fields, forKey: .speakerID)
            try fields.encodeIfPresent(confidence, forKey: .confidence)
        }
    }

    struct Word: Codable {
        private enum CodingKeys: String, CodingKey {
            case id = "i"
            case text = "t"
            case start = "s"
            case end = "e"
            case utteranceID = "u"
            case speakerID = "p"
            case precision = "q"
            case observations = "o"
            case candidates = "k"
            case confidence = "c"
            case projection = "j"
        }

        var id: String
        var text: String
        var start: Time
        var end: Time
        var utteranceID: String?
        var speakerID: String?
        var precision: TranscriptPrecision?
        var observations: [Observation]?
        /// Positions in `tracks`. An empty list is kept apart from none.
        var candidates: [Int]?
        var confidence: Double?
        var projection: TranscriptWordProjection?

        init(_ word: TranscriptWord, tables: Tables) throws {
            id = word.id
            text = word.text
            start = Time(word.start)
            end = Time(word.end)
            utteranceID = word.utteranceID
            speakerID = word.speakerID
            precision = word.precision == .word ? nil : word.precision
            observations = try word.observations.isEmpty ? nil : word.observations.map {
                try Observation($0, of: word, tables: tables)
            }
            candidates = try word.candidateTrackIDs?.map { id in
                guard let position = tables.positions[id] else {
                    throw TranscriptDocument.invalid("Unknown candidate track \(id)")
                }
                return position
            }
            confidence = word.confidence
            projection = word.projection
        }

        func word(tables: Tables) throws -> TranscriptWord {
            var word = TranscriptWord(id: id, text: text, start: start.value, end: end.value, utteranceID: utteranceID,
                                      speakerID: speakerID, precision: precision ?? .word, observations: [],
                                      candidateTrackIDs: try candidates?.map { position in
                                          guard tables.ids.indices.contains(position) else {
                                              throw TranscriptDocument.invalid("Unknown candidate track at position \(position)")
                                          }
                                          return tables.ids[position]
                                      },
                                      confidence: confidence, projection: projection)
            if let observations {
                word.observations = try observations.map { try $0.observation(of: word, tables: tables) }
            }
            return word
        }

        // Listing a row's fields to refuse an unknown one doubles the time to read a long
        // transcript. The document and its tracks are checked; a row is read for what it names.
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            text = try fields.decode(String.self, forKey: .text)
            start = try fields.decode(Time.self, forKey: .start)
            end = try fields.decode(Time.self, forKey: .end)
            utteranceID = try fields.decodeIfPresent(String.self, forKey: .utteranceID)
            speakerID = try fields.decodeIfPresent(String.self, forKey: .speakerID)
            precision = try fields.decodeIfPresent(TranscriptPrecision.self, forKey: .precision)
            observations = try fields.decodeIfPresent([Observation].self, forKey: .observations)
            candidates = try fields.decodeIfPresent([Int].self, forKey: .candidates)
            confidence = try fields.decodeIfPresent(Double.self, forKey: .confidence)
            projection = try fields.decodeIfPresent(TranscriptWordProjection.self, forKey: .projection)
        }
    }

    /// What an observation needs to know about the tracks: each one's position, and the bounds
    /// and text of the words it keeps.
    struct Tables {
        typealias Entry = (start: RationalTime, end: RationalTime, text: String)

        let ids: [String]
        let positions: [String: Int]
        var words: [[String: Entry]]

        init(ids: [String]) {
            self.ids = ids
            positions = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            words = Array(repeating: [:], count: ids.count)
        }

        mutating func keep(_ local: [TranscriptWord]?, at position: Int) {
            guard let local else { return }
            var entries: [String: Entry] = [:]
            entries.reserveCapacity(local.count)
            for word in local { entries[word.id] = (word.start, word.end, word.text) }
            words[position] = entries
        }
    }

    struct Track: Codable {
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
            case words
            case speakers
            case streamEvidence = "stream_evidence"
            case error
            case warning
            case approximateClock = "approximate_clock"
        }

        var id: String
        var name: String
        var sourceID: String?
        var streamIndex: Int?
        var channel: Int?
        var origin: Time
        var sessionStart: Time
        var coverage: TranscriptCoverage
        var role: TranscriptRole
        var words: [Word]?
        var speakers: [TranscriptSpeaker]?
        var streamEvidence: TranscriptJSONValue?
        var error: String?
        var warning: String?
        var approximateClock: Bool?

        /// A track's own words carry no observations, so they need no tables of their own.
        init(_ track: TranscriptTrack, tables: Tables) throws {
            id = track.id
            name = track.name
            sourceID = track.sourceID
            streamIndex = track.streamIndex
            channel = track.channel
            origin = Time(track.origin)
            sessionStart = Time(track.sessionStart)
            coverage = track.coverage
            role = track.role
            words = try track.words?.map { try Word($0, tables: tables) }
            speakers = track.speakers
            streamEvidence = track.streamEvidence
            error = track.error
            warning = track.warning
            approximateClock = track.approximateClock
        }

        func track(tables: Tables) throws -> TranscriptTrack {
            TranscriptTrack(id: id, name: name, sourceID: sourceID, streamIndex: streamIndex, channel: channel,
                            origin: origin.value, sessionStart: sessionStart.value, coverage: coverage, role: role,
                            words: try words?.map { try $0.word(tables: tables) }, speakers: speakers,
                            streamEvidence: streamEvidence, error: error, warning: warning,
                            approximateClock: approximateClock)
        }

        init(from decoder: Decoder) throws {
            try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript")
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            name = try fields.decode(String.self, forKey: .name)
            sourceID = try fields.decodeIfPresent(String.self, forKey: .sourceID)
            streamIndex = try fields.decodeIfPresent(Int.self, forKey: .streamIndex)
            channel = try fields.decodeIfPresent(Int.self, forKey: .channel)
            origin = try fields.decode(Time.self, forKey: .origin)
            sessionStart = try fields.decode(Time.self, forKey: .sessionStart)
            coverage = try fields.decode(TranscriptCoverage.self, forKey: .coverage)
            role = try fields.decode(TranscriptRole.self, forKey: .role)
            words = try fields.decodeIfPresent([Word].self, forKey: .words)
            speakers = try fields.decodeIfPresent([TranscriptSpeaker].self, forKey: .speakers)
            streamEvidence = try fields.decodeIfPresent(TranscriptJSONValue.self, forKey: .streamEvidence)
            error = try fields.decodeIfPresent(String.self, forKey: .error)
            warning = try fields.decodeIfPresent(String.self, forKey: .warning)
            approximateClock = try fields.decodeIfPresent(Bool.self, forKey: .approximateClock)
        }
    }

    struct Document: Codable {
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

        var schemaVersion: Int
        var clock: TranscriptClock
        var tracks: [Track]
        var speakers: [TranscriptSpeaker]
        var words: [Word]
        var approximateClock: Bool
        var jobID: String?
        var fingerprint: String?
        var provenance: TranscriptProvenance?

        init(_ document: TranscriptDocument) throws {
            // Observations are told apart from a track's own words only once the document holds
            // together: distinct track IDs, and no observations inside a track's words.
            try document.validate()
            var tables = Tables(ids: document.tracks.map(\.id))
            for (position, track) in document.tracks.enumerated() { tables.keep(track.words, at: position) }
            schemaVersion = TranscriptStoredForm.schemaVersion
            clock = document.clock
            tracks = try document.tracks.map { try Track($0, tables: tables) }
            speakers = document.speakers
            words = try document.words.map { try Word($0, tables: tables) }
            approximateClock = document.approximateClock
            jobID = document.jobID
            fingerprint = document.fingerprint
            provenance = document.provenance
        }

        func document() throws -> TranscriptDocument {
            guard schemaVersion == TranscriptStoredForm.schemaVersion else {
                throw CutError(code: "unsupported_transcript_version",
                               message: "Unsupported transcript schema version \(schemaVersion)")
            }
            let ids = tracks.map(\.id)
            guard Set(ids).count == ids.count else { throw TranscriptDocument.invalid("Duplicate or empty track ID") }
            // A track's own words are read first and without tables. An observation among them
            // is refused when the document is validated.
            var tables = Tables(ids: ids)
            let converted = try tracks.map { try $0.track(tables: tables) }
            for (position, track) in converted.enumerated() { tables.keep(track.words, at: position) }
            return TranscriptDocument(clock: clock, tracks: converted, speakers: speakers,
                                      words: try words.map { try $0.word(tables: tables) },
                                      approximateClock: approximateClock, jobID: jobID, fingerprint: fingerprint,
                                      provenance: provenance)
        }

        init(from decoder: Decoder) throws {
            try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript")
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
            clock = try fields.decode(TranscriptClock.self, forKey: .clock)
            tracks = try fields.decode([Track].self, forKey: .tracks)
            speakers = try fields.decode([TranscriptSpeaker].self, forKey: .speakers)
            words = try fields.decode([Word].self, forKey: .words)
            approximateClock = try fields.decode(Bool.self, forKey: .approximateClock)
            jobID = try fields.decodeIfPresent(String.self, forKey: .jobID)
            fingerprint = try fields.decodeIfPresent(String.self, forKey: .fingerprint)
            provenance = try fields.decodeIfPresent(TranscriptProvenance.self, forKey: .provenance)
        }
    }
}
