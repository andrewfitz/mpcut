import Foundation

public enum ParticipantBackendMode: String, Codable, Sendable {
    case automatic
    case cpu
    case gpuRequired = "gpu_required"
}

public enum ParticipantSampling: String, Codable, Sendable {
    case everyFrame = "every_frame"
    case sparse
}

public struct ParticipantScanOptions: Sendable {
    public let backend: ParticipantBackendMode
    public let sampling: ParticipantSampling
    public let includeScenes: Bool
    public let useSidecar: Bool

    public init(backend: ParticipantBackendMode = .automatic, sampling: ParticipantSampling = .everyFrame,
                includeScenes: Bool = false, useSidecar: Bool = true) {
        self.backend = backend
        self.sampling = sampling
        self.includeScenes = includeScenes
        self.useSidecar = useSidecar
    }
}

public struct ParticipantScanConfiguration: Codable, Equatable, Sendable {
    public let backend: ParticipantBackendMode
    public let sampling: ParticipantSampling
    public let includeScenes: Bool

    init(_ options: ParticipantScanOptions) {
        backend = options.backend
        sampling = options.sampling
        includeScenes = options.includeScenes
    }

    public func options(useSidecar: Bool = true) -> ParticipantScanOptions {
        ParticipantScanOptions(backend: backend, sampling: sampling, includeScenes: includeScenes, useSidecar: useSidecar)
    }

    enum CodingKeys: String, CodingKey {
        case backend, sampling
        case includeScenes = "include_scenes"
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
    public let inode: UInt64?
    public let stream: Int
    public let origin: RationalTime
    public let timeBase: RationalTime
    public let duration: RationalTime
    public let transform: ParticipantDisplayTransform

    enum CodingKeys: String, CodingKey {
        case file, stamp, inode, stream, origin, duration, transform
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

    enum CodingKeys: String, CodingKey {
        case state, source, configuration, analysis
        case sceneReport = "scene_report"
        case analysisIdentity = "analysis_identity"
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

public struct ParticipantObservation: Codable, Equatable, Sendable {
    @ParticipantSourceTime public var time: RationalTime
    public let display: ParticipantDisplayTransform
    public let confidence: Double
    public let regions: [ParticipantRegion]

    enum CodingKeys: String, CodingKey {
        case display, confidence, regions
        case time = "timestamp"
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

public struct ParticipantObservationRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
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
        if let origin = decoder.userInfo[participantOriginKey] as? RationalTime {
            let timestamp = try RawTimestamp(from: decoder)
            guard timestamp.timeBase.numerator > 0 else {
                throw CutError(code: "participant_result_invalid", message: "TileTrail returned an invalid time base.")
            }
            wrappedValue = try RationalTime(numerator: timestamp.pts).multiplied(by: timestamp.timeBase).subtracting(origin)
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
