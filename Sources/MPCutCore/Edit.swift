import Foundation
import PacketWriter

public struct CutError: Error, LocalizedError, Codable, Sendable {
    public let code: String
    public let message: String
    public let segment: Int?
    public let boundary: String?
    public let nearest: [RationalTime]?
    public let track: Int?
    public let multicam: MulticamDiagnostic?
    public let placementIDs: [String]?
    public var multicamAt: RationalTime? { multicam?.at }
    /// The exports that work instead, least destructive first. Set by the front end from `ExportPlanner`.
    public var alternatives: [ExportAlternative]? = nil
    public var stillBoundaryAdjustments: [StillBoundaryAdjustment]? = nil
    /// The timeline tier factor this failure stands for, when the throw site names one. `factor` also covers the rest.
    public var reason: TierFactorID? = nil

    /// The same failure, named as a tier factor.
    func because(_ reason: TierFactorID?) -> CutError {
        var named = self
        named.reason = reason ?? self.reason
        return named
    }

    public init(code: String, message: String, segment: Int? = nil, boundary: String? = nil,
                nearest: [RationalTime]? = nil, track: Int? = nil, multicam: MulticamDiagnostic? = nil,
                placementIDs: [String]? = nil) {
        self.code = code
        self.message = message
        self.segment = segment
        self.boundary = boundary
        self.nearest = nearest
        self.track = track
        self.multicam = multicam
        self.placementIDs = placementIDs
    }

    public var errorDescription: String? { message }
}

public enum SnapMode: String, Codable, CaseIterable, Sendable {
    case exact
    case nearest
}

/// Media kinds retained by the packet-copy writer.
public enum ExportTracks: String, Codable, CaseIterable, Sendable {
    case all, video, audio

    var native: Int32 {
        switch self {
        case .all: return Int32(MPCUT_TRACKS_ALL)
        case .audio: return Int32(MPCUT_TRACKS_AUDIO)
        case .video: return Int32(MPCUT_TRACKS_VIDEO)
        }
    }
}

public enum ExportMode: String, Codable, CaseIterable, Sendable {
    case copy, smart, encode
}

public struct ClipRequest: Sendable {
    public let file: URL
    public let from: RationalTime?
    public let to: RationalTime?

    public init(file: URL, from: RationalTime? = nil, to: RationalTime? = nil) {
        self.file = file
        self.from = from
        self.to = to
    }
}

public struct ResolvedTrack: Codable, Sendable {
    public let index: Int
    public let kind: String
    public let sourceStart: RationalTime
    public let sourceEnd: RationalTime
    public let outputStart: RationalTime
    public let outputEnd: RationalTime
    var mp3Anchor: MP3Anchor? = nil
    var opusPreSkip: Int32? = nil

    enum CodingKeys: String, CodingKey {
        case index, kind, sourceStart, sourceEnd, outputStart, outputEnd
    }
}

public struct EncodedEdge: Codable, Sendable {
    public let from: RationalTime
    public let to: RationalTime
    public let frameCount: Int
    public internal(set) var targetBitRate: Int64?
    var decodeFrom: RationalTime = .zero

    enum CodingKeys: String, CodingKey { case from, to, frameCount, targetBitRate }
}

public struct ResolvedSegment: Codable, Sendable {
    public let file: URL
    public let from: RationalTime
    public let to: RationalTime
    public let outputStart: RationalTime
    public let tracks: [ResolvedTrack]
    var sourceOrigin: RationalTime?
    // Whole soundtrack extraction keeps decoder history and normalizes its audible start.
    var wholeAudioOrigin: RationalTime? = nil
    var lastVideoFrame: RationalTime?
    let reachesEnd: Bool
    var multipleDescriptions = false
    var generatedStill = false
    var videoDecodeTimes: [RationalTime] = []
    package var sourceClipIndex: Int? = nil
    public internal(set) var encodedEdges: [EncodedEdge]? = nil

    enum CodingKeys: String, CodingKey {
        case file, from, to, outputStart, tracks, reachesEnd, encodedEdges
    }

    public var duration: RationalTime { to - from }
}

public struct ResolvedEdit: Encodable, Sendable {
    public let segments: [ResolvedSegment]
    public let duration: RationalTime
    public let container: String
    let identities: [URL: SourceIdentity]
    public internal(set) var tracks: ExportTracks = .all
    public internal(set) var audioStream: Int? = nil
    var usesPerSourceAudioStream = false
    var stillMasteringDisplay: [UInt32] = []

    enum CodingKeys: String, CodingKey { case segments, duration, container }

    public func encodedVideoDuration(for mode: ExportMode) throws -> RationalTime {
        switch mode {
        case .copy: return .zero
        case .encode: return duration
        case .smart:
            var total = RationalTime.zero
            for segment in segments {
                for edge in segment.encodedEdges ?? [] {
                    total = try total.adding(edge.to.subtracting(edge.from))
                }
            }
            return total
        }
    }

    public func copiedVideoDuration(for mode: ExportMode) throws -> RationalTime {
        try duration.subtracting(encodedVideoDuration(for: mode))
    }
}
