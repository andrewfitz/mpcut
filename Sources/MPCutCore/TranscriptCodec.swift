import Foundation

public enum TranscriptFormat: String, Codable, CaseIterable, Sendable {
    case json, srt, vtt, text
}

public enum TranscriptCodec {
    public static func decode(_ data: Data, format: TranscriptFormat, origin: RationalTime? = nil) throws -> TranscriptDocument {
        let result: TranscriptDocument
        switch format {
        case .json:
            result = try decodeJSON(data, origin: origin)
        case .srt, .vtt:
            let prefix = Array(data.prefix(2))
            let encoding: String.Encoding = prefix == [0xff, 0xfe] || prefix == [0xfe, 0xff] ? .utf16 : .utf8
            guard let text = String(data: data, encoding: encoding) else {
                throw TranscriptDocument.invalid("Transcript is not UTF-8 or BOM-marked UTF-16")
            }
            result = try TranscriptSubtitles.decode(text, format: format, origin: origin)
        case .text:
            throw TranscriptDocument.invalid("Plain text has no transcript timestamps")
        }
        try result.validate()
        return result
    }

    public static func encode(_ document: TranscriptDocument, format: TranscriptFormat) throws -> Data {
        try document.validate()
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(document)
        case .srt, .vtt, .text:
            return try Data(TranscriptSubtitles.encode(document, format: format).utf8)
        }
    }

    private enum JSONDocument: Decodable {
        case session(TranscriptNativeSession)
        case document(TranscriptDocument)
        case recording(TranscriptNativeRecording)

        private enum CodingKeys: String, CodingKey { case schema_version, version, sample_rate }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            switch (keys.contains(.schema_version), keys.contains(.version), keys.contains(.sample_rate)) {
            case (false, true, true):
                self = .session(try TranscriptNativeSession(from: decoder))
            case (true, false, false):
                let version = try keys.decode(Int.self, forKey: .schema_version)
                guard version == TranscriptDocument.currentSchemaVersion else {
                    throw CutError(code: "unsupported_transcript_version", message: "Unsupported transcript schema version \(version)")
                }
                self = .document(try TranscriptDocument(from: decoder))
            case (false, false, false):
                self = .recording(try TranscriptNativeRecording(from: decoder))
            default:
                throw CutError(code: "unsupported_transcript_version", message: "Unrecognized transcript format or version")
            }
        }
    }

    private static func decodeJSON(_ data: Data, origin: RationalTime?) throws -> TranscriptDocument {
        // A stored result is a document this codec wrote. Hours of words cost most of a
        // command's time in the general decoder, so the plain form is read directly. Anything
        // else, including every malformed input, takes the general path and its errors.
        if let document = TranscriptDocumentReader.document(from: data) { return document }
        do {
            switch try JSONDecoder().decode(JSONDocument.self, from: data) {
            case .session(let session):
                return try session.document()
            case .document(let document):
                return document
            case .recording(let recording):
                return try recording.document(origin: origin)
            }
        } catch let error as DecodingError {
            throw TranscriptDocument.invalid("Invalid native transcript JSON (\(error))")
        }
    }
}

private struct TranscriptNativeRecording: Decodable {
    struct Fragment: Decodable {
        let text: String
        let start: Seconds
        let end: Seconds
        let speaker: Int?
    }

    struct Segment: Decodable {
        let text: String?
        let start: Seconds
        let end: Seconds
        let speaker: Int?
        let words: [Fragment]?
    }

    struct Part: Decodable {
        let source: String
        let speaker: Int
        let offset_seconds: Seconds
        let local_origin: RationalTime?
        let duration_seconds: Seconds?
    }

    struct Metadata: Decodable {
        let merged_from: [Part]?
        let original: TranscriptJSONValue

        private enum CodingKeys: String, CodingKey { case merged_from }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            merged_from = try values.decodeIfPresent([Part].self, forKey: .merged_from)
            original = try TranscriptJSONValue(from: decoder)
        }
    }

    struct Seconds: Decodable {
        let time: RationalTime

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let decimal = try container.decode(Decimal.self)
            time = try RationalTime(parsing: NSDecimalNumber(decimal: decimal).stringValue)
        }
    }

    let source: String
    let duration_seconds: Seconds
    let segments: [Segment]
    let speaker_names: [String]?
    let metadata: Metadata
    let sample_zero: RationalTime?
    let model: String?
    let device: String?
    let language: String?

    func document(origin: RationalTime?) throws -> TranscriptDocument {
        let parts = metadata.merged_from ?? []
        let merged = !parts.isEmpty
        let localOrigin = origin ?? sample_zero ?? .zero
        guard duration_seconds.time >= .zero,
              parts.allSatisfy({ $0.duration_seconds.map { $0.time >= .zero } ?? true }) else {
            throw TranscriptDocument.invalid("Invalid native recording duration")
        }
        let tracks = merged ? parts.enumerated().map { index, part in
            TranscriptTrack(id: "part-\(index)", name: part.source, origin: part.local_origin ?? .zero,
                            sessionStart: part.offset_seconds.time, approximateClock: part.local_origin == nil)
        } : [TranscriptTrack(id: "source", name: source, origin: localOrigin,
                             approximateClock: sample_zero == nil && origin == nil)]
        var speakerIndices = Set((speaker_names ?? []).indices)
        speakerIndices.formUnion(parts.map(\.speaker))
        let partIndicesBySpeaker = Dictionary(grouping: parts.indices, by: { parts[$0].speaker })
        let allPartIndices = Array(parts.indices)
        let partEnds = try parts.map { part in
            try part.duration_seconds.map { try part.offset_seconds.time.adding($0.time) }
        }
        var output: [TranscriptWord] = []
        for (segmentIndex, segment) in segments.enumerated() {
            let fragments: [Fragment]
            let precision: TranscriptPrecision
            let segmentWords = segment.words ?? []
            switch (segment.text, segmentWords.isEmpty) {
            case let (.some(text), true):
                fragments = [Fragment(text: text, start: segment.start, end: segment.end, speaker: segment.speaker)]
                precision = .cue
            case (.none, false):
                fragments = segmentWords
                precision = .word
            default:
                throw TranscriptDocument.invalid("Native segment must contain text or words")
            }
            guard segment.start.time >= .zero, segment.start.time <= segment.end.time else {
                throw TranscriptDocument.invalid("Invalid native segment timing")
            }
            if let speaker = segment.speaker { speakerIndices.insert(speaker) }
            var previousStart = segment.start.time
            for (wordIndex, word) in fragments.enumerated() {
                let start = word.start.time
                let end = word.end.time
                let speaker = word.speaker ?? segment.speaker
                guard start >= previousStart, end >= start, end <= segment.end.time else {
                    throw TranscriptDocument.invalid("Invalid native word timing")
                }
                previousStart = start
                if let speaker { speakerIndices.insert(speaker) }
                let id = "s\(segmentIndex)-w\(wordIndex)"
                let speakerID = speaker.map { "speaker-\($0)" }
                var observations: [TranscriptObservation] = []
                var candidates: [String]?
                if merged {
                    let associatedParts = speaker.map { partIndicesBySpeaker[$0] ?? [] } ?? allPartIndices
                    let matches = associatedParts.filter { index in
                        let part = parts[index]
                        let partStart = part.offset_seconds.time
                        guard start >= partStart else { return false }
                        guard let partEnd = partEnds[index] else { return true }
                        return start < partEnd && end <= partEnd
                    }
                    if matches.count == 1, let index = matches.first {
                        let track = tracks[index]
                        let observedStart = try start.subtracting(track.sessionStart).adding(track.origin)
                        let observedEnd = try end.subtracting(track.sessionStart).adding(track.origin)
                        observations = [TranscriptObservation(trackID: track.id, wordID: id, text: word.text,
                                                              start: observedStart, end: observedEnd,
                                                              evidence: .recognized, speakerID: speakerID)]
                    } else {
                        candidates = matches.map { tracks[$0].id }
                    }
                } else {
                    observations = [TranscriptObservation(trackID: "source", wordID: id, text: word.text,
                                                          start: try start.adding(localOrigin), end: try end.adding(localOrigin),
                                                          evidence: .recognized, speakerID: speakerID)]
                }
                output.append(TranscriptWord(id: id, text: word.text, start: merged ? start : try start.adding(localOrigin),
                                             end: merged ? end : try end.adding(localOrigin), utteranceID: "s\(segmentIndex)",
                                             speakerID: speakerID, precision: precision, observations: observations,
                                             candidateTrackIDs: candidates))
            }
        }
        guard speakerIndices.allSatisfy({ $0 >= 0 }) else {
            throw TranscriptDocument.invalid("Invalid native speaker index")
        }
        let names = speaker_names ?? []
        let speakers = speakerIndices.sorted().map { index in
            let name = names.indices.contains(index) && !names[index].isEmpty ? names[index] : "Speaker \(index)"
            return TranscriptSpeaker(id: "speaker-\(index)", name: name)
        }
        let provenance = TranscriptProvenance(source: source, model: model, device: device, language: language,
                                              duration: duration_seconds.time, metadata: metadata.original)
        return TranscriptDocument(clock: merged ? .session : .presentation, tracks: tracks, speakers: speakers,
                                  words: output, approximateClock: merged ? parts.contains { $0.local_origin == nil } :
                                    (sample_zero == nil && origin == nil), provenance: provenance)
    }
}

/// Reads the JSON form of a `TranscriptDocument` straight from its bytes. It accepts the
/// fields `JSONDecoder` would read into the same value and nothing else: an unknown or
/// repeated field, an escaped field name, a number written with a fraction where an integer
/// belongs, or any syntax error makes it decline, and the caller decodes generally instead.
struct TranscriptDocumentReader {
    private struct Declined: Error {}

    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    /// Track and speaker IDs repeat on every word. Reusing one string for each keeps a long
    /// ID from being allocated once per observation.
    private var repeated: [(range: Range<Int>, text: String)] = []
    private var lastUtterance: (range: Range<Int>, text: String)?

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    static func document(from data: Data) -> TranscriptDocument? {
        data.withUnsafeBytes { raw -> TranscriptDocument? in
            var reader = Self(bytes: raw.bindMemory(to: UInt8.self))
            return try? reader.document()
        }
    }

    // MARK: Syntax

    private mutating func skipSpace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x0A, 0x0D, 0x09: index += 1
            default: return
            }
        }
    }

    private mutating func next() throws -> UInt8 {
        skipSpace()
        guard index < bytes.count else { throw Declined() }
        return bytes[index]
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard try next() == byte else { throw Declined() }
        index += 1
    }

    private mutating func literal(_ text: StaticString) -> Bool {
        skipSpace()
        let count = text.utf8CodeUnitCount
        guard index + count <= bytes.count, bytes[index] == text.utf8Start.pointee, let base = bytes.baseAddress,
              memcmp(base + index, text.utf8Start, count) == 0 else { return false }
        index += count
        return true
    }

    /// The bytes between the quotes of a string that has no escapes.
    private mutating func plainString() throws -> (range: Range<Int>, ascii: Bool)? {
        try expect(0x22)
        let start = index
        var ascii = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return (start..<index - 1, ascii)
            }
            if byte == 0x5C {
                index = start
                return nil
            }
            guard byte >= 0x20 else { throw Declined() }
            if byte >= 0x80 { ascii = false }
            index += 1
        }
        throw Declined()
    }

    private func text(_ range: Range<Int>, ascii: Bool) throws -> String {
        let slice = UnsafeBufferPointer(rebasing: bytes[range])
        if ascii { return String(decoding: slice, as: UTF8.self) }
        return try Self.utf8Text(slice)
    }

    private static func utf8Text(_ bytes: some Collection<UInt8>) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw Declined() }
        // The leading U+FEFF inside a JSON string is content. Foundation's UTF-8
        // initializer strips it as a byte order mark.
        return bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? String(decoding: bytes, as: UTF8.self) : text
    }

    private mutating func string() throws -> String {
        if let plain = try plainString() { return try text(plain.range, ascii: plain.ascii) }
        return try escapedString()
    }

    /// Continues after the opening quote of a string that contains a backslash.
    private mutating func escapedString() throws -> String {
        var buffer: [UInt8] = []
        func hex() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw Declined() }
            var value: UInt32 = 0
            for offset in 0..<4 {
                let byte = bytes[index + offset]
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte) - 0x30
                case 0x41...0x46: digit = UInt32(byte) - 0x41 + 10
                case 0x61...0x66: digit = UInt32(byte) - 0x61 + 10
                default: throw Declined()
                }
                value = value << 4 | digit
            }
            return value
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 {
                return try Self.utf8Text(buffer)
            }
            guard byte >= 0x20 else { throw Declined() }
            guard byte == 0x5C else {
                buffer.append(byte)
                continue
            }
            guard index < bytes.count else { throw Declined() }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 0x22, 0x5C, 0x2F: buffer.append(escape)
            case 0x62: buffer.append(0x08)
            case 0x66: buffer.append(0x0C)
            case 0x6E: buffer.append(0x0A)
            case 0x72: buffer.append(0x0D)
            case 0x74: buffer.append(0x09)
            case 0x75:
                var scalar = try hex()
                index += 4
                if (0xD800...0xDBFF).contains(scalar) {
                    guard index + 2 <= bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else { throw Declined() }
                    index += 2
                    let low = try hex()
                    index += 4
                    guard (0xDC00...0xDFFF).contains(low) else { throw Declined() }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let character = Unicode.Scalar(scalar) else { throw Declined() }
                buffer.append(contentsOf: Array(String(Character(character)).utf8))
            default: throw Declined()
            }
        }
        throw Declined()
    }

    /// A string that many words share, such as a track or speaker ID.
    private mutating func repeatedString() throws -> String {
        guard let plain = try plainString() else { return try escapedString() }
        if let known = repeated.first(where: { same($0.range, plain.range) }) { return known.text }
        let value = try text(plain.range, ascii: plain.ascii)
        if repeated.count < 24 { repeated.append((plain.range, value)) }
        return value
    }

    private mutating func utterance() throws -> String {
        guard let plain = try plainString() else { return try escapedString() }
        if let lastUtterance, same(lastUtterance.range, plain.range) { return lastUtterance.text }
        let value = try text(plain.range, ascii: plain.ascii)
        lastUtterance = (plain.range, value)
        return value
    }

    private func same(_ left: Range<Int>, _ right: Range<Int>) -> Bool {
        guard left.count == right.count, let base = bytes.baseAddress else { return false }
        return memcmp(base + left.lowerBound, base + right.lowerBound, left.count) == 0
    }

    private mutating func integer() throws -> Int64 {
        var negative = false
        if try next() == 0x2D {
            negative = true
            index += 1
        }
        let first = index
        var magnitude: UInt64 = 0
        while index < bytes.count, case let byte = bytes[index], (0x30...0x39).contains(byte) {
            let (scaled, overflow) = magnitude.multipliedReportingOverflow(by: 10)
            let (sum, carry) = scaled.addingReportingOverflow(UInt64(byte - 0x30))
            guard !overflow, !carry else { throw Declined() }
            magnitude = sum
            index += 1
        }
        // Only a plain run of digits is certain to mean the same integer to every reader.
        guard index > first, index - first == 1 || bytes[first] != 0x30, !(negative && magnitude == 0) else { throw Declined() }
        if index < bytes.count, bytes[index] == 0x2E || bytes[index] == 0x65 || bytes[index] == 0x45 { throw Declined() }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { throw Declined() }
            return magnitude == UInt64(Int64.max) + 1 ? .min : -Int64(magnitude)
        }
        guard magnitude <= UInt64(Int64.max) else { throw Declined() }
        return Int64(magnitude)
    }

    private mutating func int() throws -> Int { Int(try integer()) }

    /// Advances over one JSON number and returns its bytes.
    private mutating func numberToken() throws -> Range<Int> {
        let start = index
        func digits() throws {
            let first = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            guard index > first else { throw Declined() }
        }
        if try next() == 0x2D { index += 1 }
        let whole = index
        try digits()
        guard index - whole == 1 || bytes[whole] != 0x30 else { throw Declined() }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            try digits()
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            try digits()
        }
        return start..<index
    }

    private mutating func double() throws -> Double {
        skipSpace()
        let token = try numberToken()
        guard let value = Double(String(decoding: UnsafeBufferPointer(rebasing: bytes[token]), as: UTF8.self)),
              value.isFinite else { throw Declined() }
        return value
    }

    private mutating func bool() throws -> Bool {
        if literal("true") { return true }
        if literal("false") { return false }
        throw Declined()
    }

    /// A field that may be absent is also absent when it is written as null.
    private mutating func optional<Value>(_ read: (inout Self) throws -> Value) throws -> Value? {
        if literal("null") { return nil }
        return try read(&self)
    }

    private mutating func array<Element>(_ read: (inout Self) throws -> Element) throws -> [Element] {
        try expect(0x5B)
        var result: [Element] = []
        if try next() == 0x5D {
            index += 1
            return result
        }
        while true {
            result.append(try read(&self))
            switch try next() {
            case 0x2C: index += 1
            case 0x5D:
                index += 1
                return result
            default: throw Declined()
            }
        }
    }

    /// Reads an object whose fields are all among `names`, each at most once. `field` receives
    /// the position of each name it meets.
    private mutating func object(_ names: [StaticString], _ field: (inout Self, Int) throws -> Void) throws {
        try expect(0x7B)
        var seen: UInt64 = 0
        var first = true
        // The codec writes fields in the order of `names`, so the search for each one starts
        // after the last and usually ends at once.
        var expected = 0
        while true {
            if try next() == 0x7D {
                index += 1
                return
            }
            if !first { try expect(0x2C) }
            first = false
            guard let key = try plainString(), let base = bytes.baseAddress, !key.range.isEmpty else { throw Declined() }
            let count = key.range.count
            var position = expected
            var found = false
            for _ in names.indices {
                if position == names.count { position = 0 }
                let name = names[position]
                if name.utf8CodeUnitCount == count, name.utf8Start.pointee == bytes[key.range.lowerBound],
                   memcmp(name.utf8Start, base + key.range.lowerBound, count) == 0 {
                    found = true
                    break
                }
                position += 1
            }
            guard found, seen & (1 << UInt64(position)) == 0 else { throw Declined() }
            seen |= 1 << UInt64(position)
            expected = position + 1
            try expect(0x3A)
            try field(&self, position)
        }
    }

    /// Advances over any one well-formed value.
    private mutating func skipValue(depth: Int = 0) throws {
        guard depth < 64 else { throw Declined() }
        switch try next() {
        case 0x22: _ = try string()
        case 0x7B:
            index += 1
            var first = true
            while try next() != 0x7D {
                if !first { try expect(0x2C) }
                first = false
                guard try next() == 0x22 else { throw Declined() }
                _ = try string()
                try expect(0x3A)
                try skipValue(depth: depth + 1)
            }
            index += 1
        case 0x5B:
            index += 1
            var first = true
            while try next() != 0x5D {
                if !first { try expect(0x2C) }
                first = false
                try skipValue(depth: depth + 1)
            }
            index += 1
        case 0x74: guard literal("true") else { throw Declined() }
        case 0x66: guard literal("false") else { throw Declined() }
        case 0x6E: guard literal("null") else { throw Declined() }
        default: _ = try numberToken()
        }
    }

    /// Free-form evidence keeps the general decoder's reading of numbers and nesting.
    private mutating func jsonValue() throws -> TranscriptJSONValue {
        if try next() == 0x22 { return .string(try string()) }
        let start = index
        try skipValue()
        guard !(index - start == 4 && bytes[start] == 0x6E) else { throw Declined() }
        return try JSONDecoder().decode(TranscriptJSONValue.self, from: Data(UnsafeBufferPointer(rebasing: bytes[start..<index])))
    }

    private func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw Declined() }
        return value
    }

    // MARK: Document

    private static let timeFields: [StaticString] = ["denominator", "numerator"]
    private static let speakerFields: [StaticString] = ["id", "name"]
    private static let activityFields: [StaticString] = ["end", "level", "start"]
    private static let observationFields: [StaticString] = [
        "basis", "confidence", "end", "evidence", "speaker_id", "start", "text", "track_id", "word_id"
    ]
    private static let wordFields: [StaticString] = [
        "candidate_track_ids", "confidence", "end", "id", "observations", "precision", "projection",
        "speaker_id", "start", "text", "utterance_id"
    ]
    private static let projectionFields: [StaticString] = [
        "assembly_index", "attachment_id", "audio_stream_index", "clip_id", "clock", "original_source_end",
        "original_source_start", "original_speaker_id", "original_text", "partial", "routed_source_id",
        "routed_stream_index", "source_id", "stale_matches", "track_id", "word_id"
    ]
    private static let trackFields: [StaticString] = [
        "activity", "approximate_clock", "audio_stream_index", "channel", "coverage", "error", "id", "name",
        "origin", "role", "session_start", "source_id", "speakers", "stream_evidence", "warning", "words"
    ]
    private static let provenanceFields: [StaticString] = ["device", "duration", "language", "metadata", "model", "source"]
    private static let documentFields: [StaticString] = [
        "approximate_clock", "clock", "fingerprint", "job_id", "provenance", "schema_version", "speakers", "tracks",
        "words"
    ]

    private mutating func named<Value: RawRepresentable>(_ type: Value.Type) throws -> Value where Value.RawValue == String {
        guard let plain = try plainString(), plain.ascii,
              let value = Value(rawValue: try text(plain.range, ascii: true)) else { throw Declined() }
        return value
    }

    /// A time exactly as the codec writes it. Most of a stored result is times, and reading
    /// the two numbers in place skips the search for each field name.
    private mutating func compactTime() throws -> RationalTime? {
        skipSpace()
        let lead: StaticString = "{\"denominator\":"
        let middle: StaticString = ",\"numerator\":"
        guard let base = bytes.baseAddress, index + lead.utf8CodeUnitCount <= bytes.count,
              memcmp(base + index, lead.utf8Start, lead.utf8CodeUnitCount) == 0 else { return nil }
        let start = index
        index += lead.utf8CodeUnitCount
        let denominator = try integer()
        guard index + middle.utf8CodeUnitCount < bytes.count,
              memcmp(base + index, middle.utf8Start, middle.utf8CodeUnitCount) == 0 else {
            index = start
            return nil
        }
        index += middle.utf8CodeUnitCount
        let numerator = try integer()
        guard index < bytes.count, bytes[index] == 0x7D else {
            index = start
            return nil
        }
        index += 1
        guard denominator > 0 else { throw Declined() }
        return RationalTime(numerator: numerator, denominator: denominator)
    }

    private mutating func time() throws -> RationalTime {
        if let time = try compactTime() { return time }
        var numerator: Int64?
        var denominator: Int64?
        try object(Self.timeFields) { reader, field in
            if field == 0 { denominator = try reader.integer() } else { numerator = try reader.integer() }
        }
        guard let numerator, let denominator, denominator > 0 else { throw Declined() }
        return RationalTime(numerator: numerator, denominator: denominator)
    }

    private mutating func speaker() throws -> TranscriptSpeaker {
        var id: String?
        var name: String?
        try object(Self.speakerFields) { reader, field in
            if field == 0 { id = try reader.string() } else { name = try reader.string() }
        }
        return .init(id: try required(id), name: try required(name))
    }

    private mutating func activityFrame() throws -> TranscriptActivityFrame {
        var start: RationalTime?
        var end: RationalTime?
        var level: Double?
        try object(Self.activityFields) { reader, field in
            switch field {
            case 0: end = try reader.time()
            case 1: level = try reader.double()
            default: start = try reader.time()
            }
        }
        return .init(start: try required(start), end: try required(end), level: try required(level))
    }

    private mutating func observation() throws -> TranscriptObservation {
        var trackID: String?
        var wordID: String?
        var text: String?
        var start: RationalTime?
        var end: RationalTime?
        var evidence: TranscriptEvidence?
        var basis: String?
        var speakerID: String?
        var confidence: Double?
        try object(Self.observationFields) { reader, field in
            switch field {
            case 0: basis = try reader.optional { try $0.repeatedString() }
            case 1: confidence = try reader.optional { try $0.double() }
            case 2: end = try reader.time()
            case 3: evidence = try reader.named(TranscriptEvidence.self)
            case 4: speakerID = try reader.optional { try $0.repeatedString() }
            case 5: start = try reader.time()
            case 6: text = try reader.optional { try $0.string() }
            case 7: trackID = try reader.repeatedString()
            default: wordID = try reader.optional { try $0.string() }
            }
        }
        return .init(trackID: try required(trackID), wordID: wordID, text: text, start: try required(start),
                     end: try required(end), evidence: try required(evidence), basis: basis, speakerID: speakerID,
                     confidence: confidence)
    }

    private mutating func projection() throws -> TranscriptWordProjection {
        var clock: TranscriptClock?
        var wordID: String?
        var attachmentID: String?
        var originalText: String?
        var originalSpeakerID: String?
        var originalSourceStart: RationalTime?
        var originalSourceEnd: RationalTime?
        var trackID: String?
        var sourceID: String?
        var streamIndex: Int?
        var routedSourceID: String?
        var routedStreamIndex: Int?
        var clipID: String?
        var assemblyIndex: Int?
        var partial: Bool?
        var staleMatches: Bool?
        try object(Self.projectionFields) { reader, field in
            switch field {
            case 0: assemblyIndex = try reader.optional { try $0.int() }
            case 1: attachmentID = try reader.optional { try $0.repeatedString() }
            case 2: streamIndex = try reader.optional { try $0.int() }
            case 3: clipID = try reader.optional { try $0.repeatedString() }
            case 4: clock = try reader.named(TranscriptClock.self)
            case 5: originalSourceEnd = try reader.optional { try $0.time() }
            case 6: originalSourceStart = try reader.optional { try $0.time() }
            case 7: originalSpeakerID = try reader.optional { try $0.repeatedString() }
            case 8: originalText = try reader.string()
            case 9: partial = try reader.bool()
            case 10: routedSourceID = try reader.optional { try $0.repeatedString() }
            case 11: routedStreamIndex = try reader.optional { try $0.int() }
            case 12: sourceID = try reader.optional { try $0.repeatedString() }
            case 13: staleMatches = try reader.bool()
            case 14: trackID = try reader.optional { try $0.repeatedString() }
            default: wordID = try reader.string()
            }
        }
        return .init(clock: try required(clock), wordID: try required(wordID), attachmentID: attachmentID,
                     originalText: try required(originalText), originalSpeakerID: originalSpeakerID,
                     originalSourceStart: originalSourceStart, originalSourceEnd: originalSourceEnd, trackID: trackID,
                     sourceID: sourceID, streamIndex: streamIndex, routedSourceID: routedSourceID,
                     routedStreamIndex: routedStreamIndex, clipID: clipID, assemblyIndex: assemblyIndex,
                     partial: try required(partial), staleMatches: try required(staleMatches))
    }

    private mutating func word() throws -> TranscriptWord {
        var id: String?
        var text: String?
        var start: RationalTime?
        var end: RationalTime?
        var utteranceID: String?
        var speakerID: String?
        var precision: TranscriptPrecision?
        var observations: [TranscriptObservation]?
        var candidateTrackIDs: [String]?
        var confidence: Double?
        var projection: TranscriptWordProjection?
        try object(Self.wordFields) { reader, field in
            switch field {
            case 0: candidateTrackIDs = try reader.optional { try $0.array { try $0.repeatedString() } }
            case 1: confidence = try reader.optional { try $0.double() }
            case 2: end = try reader.time()
            case 3: id = try reader.string()
            case 4: observations = try reader.array { try $0.observation() }
            case 5: precision = try reader.named(TranscriptPrecision.self)
            case 6: projection = try reader.optional { try $0.projection() }
            case 7: speakerID = try reader.optional { try $0.repeatedString() }
            case 8: start = try reader.time()
            case 9: text = try reader.string()
            default: utteranceID = try reader.optional { try $0.utterance() }
            }
        }
        return .init(id: try required(id), text: try required(text), start: try required(start), end: try required(end),
                     utteranceID: utteranceID, speakerID: speakerID, precision: try required(precision),
                     observations: try required(observations), candidateTrackIDs: candidateTrackIDs,
                     confidence: confidence, projection: projection)
    }

    private mutating func track() throws -> TranscriptTrack {
        var id: String?
        var name: String?
        var sourceID: String?
        var streamIndex: Int?
        var channel: Int?
        var origin: RationalTime?
        var sessionStart: RationalTime?
        var coverage: TranscriptCoverage?
        var role: TranscriptRole?
        var activity: [TranscriptActivityFrame]?
        var words: [TranscriptWord]?
        var speakers: [TranscriptSpeaker]?
        var streamEvidence: TranscriptJSONValue?
        var error: String?
        var warning: String?
        var approximateClock: Bool?
        try object(Self.trackFields) { reader, field in
            switch field {
            case 0: activity = try reader.array { try $0.activityFrame() }
            case 1: approximateClock = try reader.optional { try $0.bool() }
            case 2: streamIndex = try reader.optional { try $0.int() }
            case 3: channel = try reader.optional { try $0.int() }
            case 4: coverage = try reader.named(TranscriptCoverage.self)
            case 5: error = try reader.optional { try $0.string() }
            case 6: id = try reader.string()
            case 7: name = try reader.string()
            case 8: origin = try reader.time()
            case 9: role = try reader.named(TranscriptRole.self)
            case 10: sessionStart = try reader.time()
            case 11: sourceID = try reader.optional { try $0.string() }
            case 12: speakers = try reader.optional { try $0.array { try $0.speaker() } }
            case 13: streamEvidence = try reader.optional { try $0.jsonValue() }
            case 14: warning = try reader.optional { try $0.string() }
            default: words = try reader.optional { try $0.array { try $0.word() } }
            }
        }
        return .init(id: try required(id), name: try required(name), sourceID: sourceID, streamIndex: streamIndex,
                     channel: channel, origin: try required(origin), sessionStart: try required(sessionStart),
                     coverage: try required(coverage), role: try required(role), activity: try required(activity),
                     words: words, speakers: speakers, streamEvidence: streamEvidence, error: error, warning: warning,
                     approximateClock: approximateClock)
    }

    private mutating func provenance() throws -> TranscriptProvenance {
        var source: String?
        var model: String?
        var device: String?
        var language: String?
        var duration: RationalTime?
        var metadata: TranscriptJSONValue?
        try object(Self.provenanceFields) { reader, field in
            switch field {
            case 0: device = try reader.optional { try $0.string() }
            case 1: duration = try reader.time()
            case 2: language = try reader.optional { try $0.string() }
            case 3: metadata = try reader.jsonValue()
            case 4: model = try reader.optional { try $0.string() }
            default: source = try reader.string()
            }
        }
        return .init(source: try required(source), model: model, device: device, language: language,
                     duration: try required(duration), metadata: try required(metadata))
    }

    private mutating func document() throws -> TranscriptDocument {
        var schemaVersion: Int?
        var clock: TranscriptClock?
        var tracks: [TranscriptTrack]?
        var speakers: [TranscriptSpeaker]?
        var words: [TranscriptWord]?
        var approximateClock: Bool?
        var jobID: String?
        var fingerprint: String?
        var provenance: TranscriptProvenance?
        try object(Self.documentFields) { reader, field in
            switch field {
            case 0: approximateClock = try reader.bool()
            case 1: clock = try reader.named(TranscriptClock.self)
            case 2: fingerprint = try reader.optional { try $0.string() }
            case 3: jobID = try reader.optional { try $0.string() }
            case 4: provenance = try reader.optional { try $0.provenance() }
            case 5:
                // Another schema version is the general decoder's to refuse.
                let version = try reader.int()
                guard version == TranscriptDocument.currentSchemaVersion else { throw Declined() }
                schemaVersion = version
            case 6: speakers = try reader.array { try $0.speaker() }
            case 7: tracks = try reader.array { try $0.track() }
            default: words = try reader.array { try $0.word() }
            }
        }
        skipSpace()
        guard index == bytes.count else { throw Declined() }
        return .init(schemaVersion: try required(schemaVersion), clock: try required(clock), tracks: try required(tracks),
                     speakers: try required(speakers), words: try required(words),
                     approximateClock: try required(approximateClock), jobID: jobID, fingerprint: fingerprint,
                     provenance: provenance)
    }
}
