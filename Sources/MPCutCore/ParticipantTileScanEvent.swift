import Foundation

/// A time and detector finding retained when a scan becomes editable geometry.
public struct ParticipantTileScanEvent: Codable, Hashable, Sendable {
    public struct Candidate: Codable, Hashable, Sendable {
        public let feedID: String
        public let confidence: Double
        public let precedingTileID: String?
        public let precedingTime: RationalTime?

        private enum CodingKeys: String, CodingKey {
            case feedID = "feed_id", confidence
            case precedingTileID = "preceding_tile_id", precedingTime = "preceding_time"
        }
    }

    public let time: RationalTime
    public let kind: ParticipantChangeEvent.Kind
    public let uncertain: Bool
    public let tileID: String?
    public let feedID: String?
    public let candidates: [Candidate]?
    public internal(set) var identityEvidenceOnly: Bool? = nil

    public var changesLayout: Bool {
        identityEvidenceOnly != true && kind != .cameraState
    }

    private enum CodingKeys: String, CodingKey {
        case time, kind, uncertain, candidates
        case tileID = "tile_id", feedID = "feed_id", identityEvidenceOnly = "identity_evidence_only"
    }
}

public struct TilesCountHints: Codable, Equatable, Sendable {
    public let expectedFeeds: Int?
    public let maxVisibleTiles: Int?

    public init(expectedFeeds: Int? = nil, maxVisibleTiles: Int? = nil) {
        self.expectedFeeds = expectedFeeds
        self.maxVisibleTiles = maxVisibleTiles
    }

    private enum CodingKeys: String, CodingKey {
        case expectedFeeds = "expected_feeds"
        case maxVisibleTiles = "max_visible_tiles"
    }
}

extension ParticipantTileScanEvent {
    func remappingTiles(_ map: (String, RationalTime) -> String) -> Self {
        .init(time: time, kind: kind, uncertain: uncertain, tileID: tileID.map { map($0, time) }, feedID: feedID,
              candidates: candidates?.map { candidate in
                  let precedingTile = candidate.precedingTileID.map { id in
                      candidate.precedingTime.map { map(id, $0) } ?? id
                  }
                  return .init(feedID: candidate.feedID, confidence: candidate.confidence,
                               precedingTileID: precedingTile, precedingTime: candidate.precedingTime)
              }, identityEvidenceOnly: identityEvidenceOnly)
    }

    func remapping(tiles: [String: String], feeds: [String: String]) -> Self {
        .init(time: time, kind: kind, uncertain: uncertain,
              tileID: tileID.map { tiles[$0] ?? $0 }, feedID: feedID.map { feeds[$0] ?? $0 },
              candidates: candidates?.map { candidate in
                  .init(feedID: feeds[candidate.feedID] ?? candidate.feedID, confidence: candidate.confidence,
                        precedingTileID: candidate.precedingTileID.map { tiles[$0] ?? $0 },
                        precedingTime: candidate.precedingTime)
              }, identityEvidenceOnly: identityEvidenceOnly)
    }
}

extension ParticipantTileScanEvent {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        time = try values.decode(RationalTime.self, forKey: .time)
        kind = try values.decode(ParticipantChangeEvent.Kind.self, forKey: .kind)
        uncertain = try values.decode(Bool.self, forKey: .uncertain)
        tileID = try values.decodeIfPresent(String.self, forKey: .tileID)
        feedID = try values.decodeIfPresent(String.self, forKey: .feedID)
        candidates = try values.decodeIfPresent([Candidate].self, forKey: .candidates)
        identityEvidenceOnly = try values.decodeIfPresent(Bool.self, forKey: .identityEvidenceOnly)
    }
}

extension ParticipantTileScanEvent.Candidate {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        feedID = try values.decode(String.self, forKey: .feedID)
        confidence = try values.decode(Double.self, forKey: .confidence)
        precedingTileID = try values.decodeIfPresent(String.self, forKey: .precedingTileID)
        precedingTime = try values.decodeIfPresent(RationalTime.self, forKey: .precedingTime)
    }
}

extension TilesCountHints {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        expectedFeeds = try values.decodeIfPresent(Int.self, forKey: .expectedFeeds)
        maxVisibleTiles = try values.decodeIfPresent(Int.self, forKey: .maxVisibleTiles)
    }
}
