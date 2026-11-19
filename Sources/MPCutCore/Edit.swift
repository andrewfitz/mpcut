import Foundation

public struct CutError: Error, LocalizedError, Codable, Sendable {
    public let code: String
    public let message: String
    public let segment: Int?
    public let boundary: String?
    public let nearest: [RationalTime]?
    public let track: Int?

    public init(code: String, message: String, segment: Int? = nil, boundary: String? = nil,
                nearest: [RationalTime]? = nil, track: Int? = nil) {
        self.code = code
        self.message = message
        self.segment = segment
        self.boundary = boundary
        self.nearest = nearest
        self.track = track
    }

    public var errorDescription: String? { message }
}

public enum SnapMode: String, Codable, Sendable {
    case exact
    case nearest
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
}

public struct ResolvedSegment: Codable, Sendable {
    public let file: URL
    public let from: RationalTime
    public let to: RationalTime
    public let outputStart: RationalTime
    public let tracks: [ResolvedTrack]
    var lastVideoFrame: RationalTime?
    let reachesEnd: Bool

    enum CodingKeys: String, CodingKey {
        case file, from, to, outputStart, tracks, reachesEnd
    }

    public var duration: RationalTime { to - from }
}

public struct ResolvedEdit: Encodable, Sendable {
    public let segments: [ResolvedSegment]
    public let duration: RationalTime
    public let container: String
    let identities: [URL: SourceIdentity]

    enum CodingKeys: String, CodingKey { case segments, duration, container }
}
