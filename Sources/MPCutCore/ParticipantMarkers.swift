import Foundation

public struct ParticipantMarkerRule: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, Sendable {
        case participants, slots
    }

    public enum Threshold: Codable, Sendable {
        case any, atLeast(Int), all

        private enum CodingKeys: String, CodingKey { case atLeast = "at_least" }

        public init(from decoder: Decoder) throws {
            let scalar = try decoder.singleValueContainer()
            if let text = try? scalar.decode(String.self) {
                switch text {
                case "any": self = .any
                case "all": self = .all
                default: throw DecodingError.dataCorruptedError(in: scalar, debugDescription: "Invalid participant marker threshold.")
                }
            } else {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                self = .atLeast(try fields.decode(Int.self, forKey: .atLeast))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .any, .all:
                var value = encoder.singleValueContainer()
                try value.encode(self == .any ? "any" : "all")
            case let .atLeast(count):
                var fields = encoder.container(keyedBy: CodingKeys.self)
                try fields.encode(count, forKey: .atLeast)
            }
        }
    }

    public let unit: Unit
    public let threshold: Threshold
    public let kinds: Set<ParticipantChangeEvent.Kind>
    public let roster: Set<UInt64>?
    public let settlingWindowMS: UInt64

    public init(unit: Unit = .participants, threshold: Threshold = .any,
                kinds: Set<ParticipantChangeEvent.Kind> = Set(ParticipantChangeEvent.Kind.allCases),
                roster: Set<UInt64>? = nil, settlingWindowMS: UInt64 = 200) {
        self.unit = unit
        self.threshold = threshold
        self.kinds = kinds
        self.roster = roster
        self.settlingWindowMS = settlingWindowMS
    }

    enum CodingKeys: String, CodingKey {
        case unit, threshold, kinds, roster
        case settlingWindowMS = "settling_window_ms"
    }
}

extension ParticipantMarkerRule.Threshold: Equatable {}

public struct ParticipantSceneMarker: Codable, Sendable {
    @ParticipantSourceTime public var time: RationalTime
    @ParticipantSourceTime public var end: RationalTime
    public let changedCount: Int
    public let eligibleCount: Int
    public let uncertain: Bool
    public let participantIDs: [UInt64]

    enum CodingKeys: String, CodingKey {
        case uncertain
        case time = "timestamp"
        case end = "end_timestamp"
        case changedCount = "changed_count"
        case eligibleCount = "eligible_count"
        case participantIDs = "participant_ids"
    }
}
