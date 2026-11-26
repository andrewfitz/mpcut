import Foundation

public enum ParticipantBackendMode: String, Codable, Sendable {
    case automatic
    case cpu
    case gpuRequired = "gpu_required"
}

public enum ParticipantSampling: String, Codable, Sendable {
    case everyFrame = "every_frame"
    case sparse
    /// Decode keyframes first and the frames between two of them only where
    /// the later keyframe differs. An unchanged stretch of up to three seconds
    /// is reported as inferred coverage; decoded stretches are observed frame
    /// by frame. Use every-frame analysis to verify a redaction.
    case adaptive

    // TileTrail records coarse adaptive steps as inferred intervals within its every-frame mode.
    var detectorSampling: Self {
        switch self {
        case .everyFrame, .adaptive: .everyFrame
        case .sparse: .sparse
        }
    }
}

public enum ParticipantFeedLayout: Equatable, Codable, Sendable {
    case meeting
    case automatic
    case gallery(columns: UInt32, rows: UInt32)
    case fixed(columns: UInt32, rows: UInt32)

    public init?(feedLayout: String) {
        if feedLayout == "auto" {
            self = .automatic
            return
        }
        let dimensions = feedLayout.split(separator: "x", omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              dimensions.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let columns = UInt32(dimensions[0]), let rows = UInt32(dimensions[1]) else { return nil }
        self = .fixed(columns: columns, rows: rows)
        guard isValid else { return nil }
    }

    public init?(galleryGrid: String) {
        guard case .fixed(let columns, let rows) = Self(feedLayout: galleryGrid) else { return nil }
        self = .gallery(columns: columns, rows: rows)
    }

    public var isValid: Bool {
        switch self {
        case .meeting, .automatic: true
        case .fixed(let columns, let rows), .gallery(let columns, let rows):
            columns > 0 && rows > 0 && UInt64(columns) * UInt64(rows) <= 64
        }
    }

    public var isMeeting: Bool {
        switch self {
        case .meeting, .gallery: true
        case .automatic, .fixed: false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "meeting" {
            self = .meeting
        } else if value.hasPrefix("gallery:"), let layout = Self(galleryGrid: String(value.dropFirst(8))) {
            self = layout
        } else if let layout = Self(feedLayout: value) {
            self = layout
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid participant feed layout.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                        debugDescription: "Invalid participant feed layout."))
        }
        var container = encoder.singleValueContainer()
        switch self {
        case .meeting: try container.encode("meeting")
        case .automatic: try container.encode("auto")
        case .gallery(let columns, let rows): try container.encode("gallery:\(columns)x\(rows)")
        case .fixed(let columns, let rows): try container.encode("\(columns)x\(rows)")
        }
    }
}

public struct ParticipantScanOptions: Sendable {
    public let backend: ParticipantBackendMode
    public let sampling: ParticipantSampling
    public let includeScenes: Bool
    public let useSidecar: Bool
    public let feedLayout: ParticipantFeedLayout

    /// Private journal for incremental tile-only scans. An interruption can
    /// resume using the same directory and source settings.
    public var checkpointDirectory: URL? = nil

    public init(backend: ParticipantBackendMode = .automatic, sampling: ParticipantSampling = .adaptive,
                includeScenes: Bool = false, useSidecar: Bool = true, feedLayout: ParticipantFeedLayout = .meeting) {
        self.backend = backend
        self.sampling = sampling
        self.includeScenes = includeScenes
        self.useSidecar = useSidecar
        self.feedLayout = feedLayout
    }
}

public struct ParticipantScanConfiguration: Codable, Equatable, Sendable {
    public let backend: ParticipantBackendMode
    public let sampling: ParticipantSampling
    public let includeScenes: Bool
    private let savedFeedLayout: ParticipantFeedLayout?
    public var feedLayout: ParticipantFeedLayout { savedFeedLayout ?? .meeting }

    init(_ options: ParticipantScanOptions) {
        backend = options.backend
        sampling = options.sampling
        includeScenes = options.includeScenes
        savedFeedLayout = options.feedLayout == .meeting ? nil : options.feedLayout
    }

    public func options(useSidecar: Bool = true) -> ParticipantScanOptions {
        ParticipantScanOptions(backend: backend, sampling: sampling, includeScenes: includeScenes,
                               useSidecar: useSidecar, feedLayout: feedLayout)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backend == rhs.backend && lhs.sampling == rhs.sampling
            && lhs.includeScenes == rhs.includeScenes && lhs.feedLayout == rhs.feedLayout
    }

    enum CodingKeys: String, CodingKey {
        case backend, sampling
        case includeScenes = "include_scenes"
        case savedFeedLayout = "feed_layout"
    }
}

public struct ParticipantDisplayTransform: Codable, Equatable, Sendable {
    public let rotation: Rotation
    public let pixelAspectNum: UInt32
    public let pixelAspectDen: UInt32

    public enum Rotation: String, Codable, Sendable {
        case r0 = "R0", r90 = "R90", r180 = "R180", r270 = "R270"

        public var clockwiseDegrees: UInt32 {
            switch self {
            case .r0: return 0
            case .r90: return 90
            case .r180: return 180
            case .r270: return 270
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case rotation
        case pixelAspectNum = "pixel_aspect_num"
        case pixelAspectDen = "pixel_aspect_den"
    }
}

public struct ParticipantScanSource: Codable, Sendable {
    public let file: String
    public let stamp: SceneSourceStamp
    public internal(set) var inode: UInt64?
    public internal(set) var producer: String? = nil
    public internal(set) var contentSHA256: String? = nil
    public let stream: Int
    public let origin: RationalTime
    public let timeBase: RationalTime
    public let duration: RationalTime
    public let transform: ParticipantDisplayTransform

    package func matches(_ media: MediaInfo) -> Bool {
        guard stamp == SceneSourceStamp(media: media), stream == media.videoStream?.index else { return false }
        if let inode { return inode == media.identity.inode }
        return AnalysisSidecar.canonicalSource(media.url).path == file
    }

    enum CodingKeys: String, CodingKey {
        case file, stamp, inode, stream, origin, duration, transform, producer
        case contentSHA256 = "content_sha256"
        case timeBase = "time_base"
    }
}

public struct ParticipantScanResult: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case completed, paused, incomplete
        case upToDate = "up_to_date"
    }

    public let state: State
    public let source: ParticipantScanSource
    public let configuration: ParticipantScanConfiguration
    public let analysis: ParticipantTrackingResult?
    public let sceneReport: SceneReport?
    public let analysisIdentity: String
    public package(set) var countHints: TilesCountHints? = nil

    enum CodingKeys: String, CodingKey {
        case state, source, configuration, analysis
        case sceneReport = "scene_report"
        case analysisIdentity = "analysis_identity"
        case countHints = "count_hints"
    }
}

public struct ParticipantTrackingResult: Codable, Sendable {
    public let schemaVersion: UInt32
    @ParticipantSourceTime public var start: RationalTime
    @ParticipantSourceTime public var end: RationalTime
    public let sampling: ParticipantSampling
    public let observations: [ParticipantObservation]
    public let tracks: [ParticipantTrack]
    public let appearances: [ParticipantDetectedAppearance]
    public let events: [ParticipantChangeEvent]
    public internal(set) var coverage: [ParticipantTrackingCoverage]
    public let diagnostics: [ParticipantBackendDiagnostic]
    @ParticipantOptionalSourceTime public var resumeAt: RationalTime?

    enum CodingKeys: String, CodingKey {
        case start, end, sampling, observations, tracks, appearances, events, coverage, diagnostics
        case schemaVersion = "schema_version"
        case resumeAt = "resume_at"
    }
}

extension ParticipantScanResult {
    /// Encode the same Codable document as JSONEncoder, limiting the temporary
    /// Foundation tree to one batch of detector rows. The ordinary encoder
    /// supplies the envelope, keys, number formatting and escaping.
    package func writeJSON(pretty: Bool, write: (Data) throws -> Void) throws {
        try writeJSON(pretty: pretty, escapeSlashes: false, write: write)
    }

    func writeJSON(pretty: Bool, escapeSlashes: Bool, write: (Data) throws -> Void) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if !escapeSlashes { encoder.outputFormatting.insert(.withoutEscapingSlashes) }
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        let batchSize = 32
        guard let a = analysis, [a.appearances.count, a.coverage.count, a.diagnostics.count, a.events.count,
                                 a.observations.count, a.tracks.count].contains(where: { $0 > batchSize }) else {
            try write(encoder.encode(self))
            return
        }

        let empty = ParticipantTrackingResult(schemaVersion: a.schemaVersion, start: a.start, end: a.end,
            sampling: a.sampling, observations: [], tracks: [], appearances: [], events: [],
            coverage: [], diagnostics: [], resumeAt: a.resumeAt)
        let envelope = try encoder.encode(ParticipantScanResult(state: state, source: source, configuration: configuration,
            analysis: empty, sceneReport: sceneReport, analysisIdentity: analysisIdentity, countHints: countHints))
        var position = envelope.startIndex

        func rows<T: Encodable>(_ key: ParticipantTrackingResult.CodingKeys, _ values: [T]) throws {
            guard !values.isEmpty else { return }
            let field = Data(("\"" + key.rawValue + (pretty ? "\" : [" : "\":[")).utf8)
            guard let start = envelope.range(of: field, in: position..<envelope.endIndex)?.upperBound,
                  let end = envelope[start...].firstIndex(of: 0x5d) else {
                throw CutError(code: "participant_result_invalid", message: "The scan report has an invalid array field.")
            }
            try write(envelope[position..<start])
            let lineStart = envelope[..<start].lastIndex(of: 10).map { $0 + 1 } ?? 0
            let indent = pretty ? Data(envelope[lineStart...].prefix(while: { $0 == 32 })) : Data()
            for first in stride(from: 0, to: values.count, by: batchSize) {
                let batch = Array(values[first..<min(values.count, first + batchSize)])
                let bytes = try encoder.encode(batch)
                if first > 0 { try write(Data([44])) }
                if pretty {
                    // The root array's rows already have one indentation level.
                    // Add the envelope's margin to nonempty lines, retaining the
                    // blank line Foundation emits inside an empty array.
                    var nested = Data()
                    for line in bytes.dropFirst(2).dropLast(2).split(separator: 10, omittingEmptySubsequences: false) {
                        nested.append(10)
                        if !line.isEmpty {
                            nested.append(indent)
                            nested.append(contentsOf: line)
                        }
                    }
                    try write(nested)
                } else {
                    try write(bytes.dropFirst().dropLast())
                }
            }
            if pretty { try write(Data([10]) + indent) }
            position = end
        }

        // Walk the same sorted keys as the envelope. Empty fields already
        // have their final bytes in the encoded document.
        try rows(.appearances, a.appearances)
        try rows(.coverage, a.coverage)
        try rows(.diagnostics, a.diagnostics)
        try rows(.events, a.events)
        try rows(.observations, a.observations)
        try rows(.tracks, a.tracks)
        try write(envelope[position...])
    }
}

public struct ParticipantObservation: Codable, Equatable, Sendable {
    @ParticipantSourceTime public var time: RationalTime
    public let display: ParticipantDisplayTransform
    public let confidence: Double
    public let regions: [ParticipantRegion]
    public internal(set) var layoutCapacityExceeded: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case display, confidence, regions
        case time = "timestamp"
        case layoutCapacityExceeded = "layout_capacity_exceeded"
    }
}

extension ParticipantObservation {
    /// The other identities a reviewer should weigh for this region. A feed
    /// that is plainly shown in another tile of the same role at this moment
    /// cannot be this tile's feed, so it is left out. Plainly means certain
    /// and with no rival of its own, so two tiles that each name the other's
    /// feed both stay in question. A stage and a thumbnail can show the same
    /// feed, so tiles of another role still count.
    func competingMatches(for region: ParticipantRegion) -> [ParticipantIdentityMatch] {
        region.possibleMatches.filter { match in
            match.participantID != region.participantID && !regions.contains { other in
                other.appearanceID != region.appearanceID && other.role == region.role
                    && !other.identityUncertain && other.participantID == match.participantID
                    && !other.possibleMatches.contains { $0.participantID != other.participantID }
            }
        }
    }

    /// This region's identity needs review: TileTrail marked it uncertain or
    /// listed a competing feed that could still be this tile's.
    func needsIdentityReview(_ region: ParticipantRegion) -> Bool {
        region.identityUncertain || !competingMatches(for: region).isEmpty
    }
}

extension ParticipantTrackingResult {
    var layoutCapacityRanges: [MulticamRange] {
        var ranges: [MulticamRange] = []
        for index in observations.indices where observations[index].layoutCapacityExceeded == true {
            let start = observations[index].time
            let next = index + 1
            let stop = next < observations.count ? observations[next].time : end
            guard start < stop else { continue }
            if ranges.last?.to == start { ranges[ranges.count - 1].to = stop }
            else { ranges.append(.init(from: start, to: stop)) }
        }
        return ranges
    }
}

public struct ParticipantRegion: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video, unknown
        case cameraOff = "camera_off"
        case screenShare = "screen_share"
    }

    public enum Role: String, Codable, Sendable {
        case primary, thumbnail
    }

    public let appearanceID: UInt64
    public let participantID: UInt64?
    public let rect: ParticipantObservationRect
    public let kind: Kind
    public let role: Role
    public let confidence: Double
    public let identityConfidence: Double?
    public let identityUncertain: Bool
    public let possibleMatches: [ParticipantIdentityMatch]

    enum CodingKeys: String, CodingKey {
        case rect, kind, role, confidence
        case appearanceID = "appearance_id"
        case participantID = "participant_id"
        case identityConfidence = "identity_confidence"
        case identityUncertain = "identity_uncertain"
        case possibleMatches = "possible_matches"
    }
}

extension ParticipantRegion {
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        appearanceID = try fields.decode(UInt64.self, forKey: .appearanceID)
        let participant = try fields.decodeIfPresent(UInt64.self, forKey: .participantID)
        participantID = participant
        rect = try fields.decode(ParticipantObservationRect.self, forKey: .rect)
        kind = try fields.decode(Kind.self, forKey: .kind)
        role = try fields.decode(Role.self, forKey: .role)
        confidence = try fields.decode(Double.self, forKey: .confidence)
        identityConfidence = try fields.decodeIfPresent(Double.self, forKey: .identityConfidence)
        possibleMatches = try fields.decode([ParticipantIdentityMatch].self, forKey: .possibleMatches)
        if fields.contains(.identityUncertain) {
            identityUncertain = try fields.decode(Bool.self, forKey: .identityUncertain)
        } else {
            // Early v1 reports represented unresolved assignments by a missing
            // identity or an alternative participant in possible_matches.
            identityUncertain = (participant == nil && kind != .screenShare)
                || possibleMatches.contains { $0.participantID != participant }
        }
    }
}

public struct ParticipantObservationRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

extension ParticipantObservationRect {
    /// TileTrail reports f32 edges, which may round just beyond the display.
    var bounds: ParticipantBounds {
        let w = x + width <= 1.0000001 ? min(width, 1 - x) : width
        let h = y + height <= 1.0000001 ? min(height, 1 - y) : height
        return .init(x: x, y: y, width: w, height: h)
    }
}

public struct ParticipantIdentityMatch: Codable, Equatable, Sendable {
    public let participantID: UInt64
    public let confidence: Double

    enum CodingKeys: String, CodingKey {
        case confidence
        case participantID = "participant_id"
    }
}

public struct ParticipantTrack: Codable, Sendable {
    public let id: UInt64
    public let appearanceIDs: [UInt64]

    enum CodingKeys: String, CodingKey {
        case id
        case appearanceIDs = "appearance_ids"
    }
}

public struct ParticipantDetectedAppearance: Codable, Sendable {
    public let id: UInt64
    public let participantID: UInt64?
    @ParticipantSourceTime public var start: RationalTime
    @ParticipantSourceTime public var end: RationalTime

    enum CodingKeys: String, CodingKey {
        case id, start, end
        case participantID = "participant_id"
    }
}

public struct ParticipantChangeEvent: Codable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case enter, leave, move, resize
        case cameraState = "camera_state"
        case pictureCut = "hard_cut"
    }

    @ParticipantSourceTime public var time: RationalTime
    public let participantID: UInt64
    public let appearanceID: UInt64
    public let kind: Kind
    public let uncertain: Bool

    enum CodingKeys: String, CodingKey {
        case kind, uncertain
        case time = "timestamp"
        case participantID = "participant_id"
        case appearanceID = "appearance_id"
    }
}

public struct ParticipantTrackingCoverage: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case observed, inferred, unknown, incomplete
    }

    @ParticipantSourceTime public var start: RationalTime
    @ParticipantSourceTime public var end: RationalTime
    public let status: Status
}

public struct ParticipantBackendDiagnostic: Codable, Sendable {
    public enum Backend: String, Codable, Sendable {
        case cpu, gpu
    }

    @ParticipantSourceTime public var time: RationalTime
    public let backend: Backend
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case backend, reason
        case time = "timestamp"
    }
}

// The C ABI JSON uses source ticks. MPCut results and sidecars encode the
// translated zero-based rational clocks, so importing a result needs no media.
private let participantOriginKey = CodingUserInfoKey(rawValue: "mpcut.participant.origin")!

@propertyWrapper
public struct ParticipantSourceTime: Codable, Equatable, Sendable {
    public package(set) var wrappedValue: RationalTime

    public init(wrappedValue: RationalTime) {
        self.wrappedValue = wrappedValue
    }

    private struct RawTimestamp: Codable {
        let pts: Int64
        let timeBase: RationalTime

        enum CodingKeys: String, CodingKey {
            case pts
            case timeBase = "time_base"
        }
    }

    public init(from decoder: Decoder) throws {
        let origin = decoder.userInfo[participantOriginKey] as? RationalTime
        let hasSourceTicks = origin == nil ? try decoder.container(keyedBy: RawTimestamp.CodingKeys.self).contains(.pts) : false
        if origin != nil || hasSourceTicks {
            // Standalone reports use the same tick shape as the C ABI, with
            // their timestamps already relative to the recording origin.
            let timestamp = try RawTimestamp(from: decoder)
            guard timestamp.timeBase.numerator > 0 else {
                throw CutError(code: "participant_result_invalid", message: "Participant analysis returned an invalid time base.")
            }
            wrappedValue = try RationalTime(numerator: timestamp.pts).multiplied(by: timestamp.timeBase)
                .subtracting(origin ?? .zero)
        } else {
            wrappedValue = try RationalTime(from: decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let origin = encoder.userInfo[participantOriginKey] as? RationalTime {
            let timestamp = try wrappedValue.adding(origin)
            try RawTimestamp(pts: timestamp.numerator,
                             timeBase: RationalTime(numerator: 1, denominator: timestamp.denominator)).encode(to: encoder)
        } else {
            try wrappedValue.encode(to: encoder)
        }
    }

    static func originalClockJSON(_ result: ParticipantTrackingResult, origin: RationalTime) throws -> Data {
        let encoder = JSONEncoder()
        encoder.userInfo[participantOriginKey] = origin
        return try encoder.encode(result)
    }

    static func decodeOriginalClock<T: Decodable>(_ type: T.Type, data: Data, origin: RationalTime) throws -> T {
        let decoder = JSONDecoder()
        decoder.userInfo[participantOriginKey] = origin
        return try decoder.decode(type, from: data)
    }
}

@propertyWrapper
public struct ParticipantOptionalSourceTime: Codable, Sendable {
    public package(set) var wrappedValue: RationalTime?

    public init(wrappedValue: RationalTime?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        wrappedValue = value.decodeNil() ? nil : try ParticipantSourceTime(from: decoder).wrappedValue
    }

    public func encode(to encoder: Encoder) throws {
        if let wrappedValue {
            try ParticipantSourceTime(wrappedValue: wrappedValue).encode(to: encoder)
        } else {
            var value = encoder.singleValueContainer()
            try value.encodeNil()
        }
    }
}

extension ParticipantScanSource {
    init(file: String, media: MediaInfo, video: StreamInfo) throws {
        guard video.rotation.isMultiple(of: 90), video.rotationOnly || !video.hasDisplayMatrix else {
            throw CutError(code: "unsupported_display_transform",
                           message: "Participant analysis requires a quarter-turn display transform.")
        }
        let turns = ((-video.rotation % 360) + 360) % 360
        let rotation: ParticipantDisplayTransform.Rotation
        switch turns {
        case 90: rotation = .r90
        case 180: rotation = .r180
        case 270: rotation = .r270
        default: rotation = .r0
        }
        let transform = ParticipantDisplayTransform(rotation: rotation,
            pixelAspectNum: UInt32(exactly: video.sampleAspectRatio.numerator).flatMap { $0 > 0 ? $0 : nil } ?? 1,
            pixelAspectDen: UInt32(exactly: video.sampleAspectRatio.denominator) ?? 1)
        self.init(file: file, stamp: SceneSourceStamp(media: media), inode: media.identity.inode,
                  stream: video.index, origin: media.origin, timeBase: video.timeBase, duration: media.duration,
                  transform: transform)
    }
}
