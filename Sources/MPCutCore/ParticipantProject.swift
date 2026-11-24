import Foundation

/// Bounds in oriented display coordinates, measured from the upper-left corner.
public struct ParticipantBounds: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var rect: CGRect { .init(x: x, y: y, width: width, height: height) }

    var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try values.decode(Double.self, forKey: .x), y: try values.decode(Double.self, forKey: .y),
                  width: try values.decode(Double.self, forKey: .width), height: try values.decode(Double.self, forKey: .height))
    }
}

public struct ParticipantAppearance: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case stage, thumbnail, tile, presentation }
    public enum State: String, Codable, Sendable { case video, cameraOff = "camera_off", presentation, unknown }

    public var id: String
    public var participantID: String?
    public var range: MulticamRange
    public var bounds: ParticipantBounds
    public var labelBounds: ParticipantBounds?
    public var role: Role
    public var state: State
    public var slotID: String?

    public init(id: String, participantID: String? = nil, range: MulticamRange, bounds: ParticipantBounds,
                labelBounds: ParticipantBounds? = nil, role: Role? = nil, state: State? = nil, slotID: String? = nil) {
        self.id = id
        self.participantID = participantID
        self.range = range
        self.bounds = bounds
        self.labelBounds = labelBounds
        self.role = role ?? (state == .presentation ? .presentation : .tile)
        self.state = state ?? (role == .presentation ? .presentation : .video)
        self.slotID = slotID
    }

    private enum CodingKeys: String, CodingKey {
        case id, range, bounds, role, state
        case participantID = "participant_id"
        case labelBounds = "label_bounds"
        case slotID = "slot_id"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  participantID: try values.decodeIfPresent(String.self, forKey: .participantID),
                  range: try values.decode(MulticamRange.self, forKey: .range),
                  bounds: try values.decode(ParticipantBounds.self, forKey: .bounds),
                  labelBounds: try values.decodeIfPresent(ParticipantBounds.self, forKey: .labelBounds),
                  role: try values.decodeIfPresent(Role.self, forKey: .role),
                  state: try values.decodeIfPresent(State.self, forKey: .state),
                  slotID: try values.decodeIfPresent(String.self, forKey: .slotID))
    }
}

public enum ParticipantCoverageState: String, Codable, Sendable { case unknown, inferred, verified }

public struct ParticipantCoverage: Codable, Equatable, Sendable {
    public var range: MulticamRange
    public var state: ParticipantCoverageState

    public init(range: MulticamRange, state: ParticipantCoverageState) {
        self.range = range
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case range, state }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(range: try values.decode(MulticamRange.self, forKey: .range),
                  state: try values.decode(ParticipantCoverageState.self, forKey: .state))
    }
}

public struct ParticipantSourceGeometry: Codable, Equatable, Sendable {
    public var sourceID: String
    public var analysisIdentity: String?
    public var sourceStamp: SceneSourceStamp?
    public var sourceInode: UInt64?
    public var sourceContentSHA256: String?
    public var feedLayout: ParticipantFeedLayout?
    public var appearances: [ParticipantAppearance]
    public var coverage: [ParticipantCoverage]
    public internal(set) var unresolvedParticipantIDs: [String]

    public init(sourceID: String, analysisIdentity: String? = nil, sourceStamp: SceneSourceStamp? = nil,
                sourceInode: UInt64? = nil, sourceContentSHA256: String? = nil, feedLayout: ParticipantFeedLayout? = nil,
                appearances: [ParticipantAppearance] = [],
                coverage: [ParticipantCoverage] = [], unresolvedParticipantIDs: [String] = []) {
        self.sourceID = sourceID
        self.analysisIdentity = analysisIdentity
        self.sourceStamp = sourceStamp
        self.sourceInode = sourceInode
        self.sourceContentSHA256 = sourceContentSHA256
        self.feedLayout = feedLayout == .meeting ? nil : feedLayout
        self.appearances = appearances
        self.coverage = coverage
        self.unresolvedParticipantIDs = unresolvedParticipantIDs
    }

    package init(sourceID: String, media: MediaInfo, appearances: [ParticipantAppearance] = []) {
        self.init(sourceID: sourceID, sourceStamp: SceneSourceStamp(media: media), sourceInode: media.identity.inode,
                  appearances: appearances)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case analysisIdentity = "analysis_identity"
        case sourceStamp = "source_stamp"
        case sourceInode = "source_inode"
        case sourceContentSHA256 = "source_content_sha256"
        case feedLayout = "feed_layout"
        case appearances, coverage
        case unresolvedParticipantIDs = "unresolved_participant_ids"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourceID: try values.decode(String.self, forKey: .sourceID),
                  analysisIdentity: try values.decodeIfPresent(String.self, forKey: .analysisIdentity),
                  sourceStamp: try values.decodeIfPresent(SceneSourceStamp.self, forKey: .sourceStamp),
                  sourceInode: try values.decodeIfPresent(UInt64.self, forKey: .sourceInode),
                  sourceContentSHA256: try values.decodeIfPresent(String.self, forKey: .sourceContentSHA256),
                  feedLayout: try values.decodeIfPresent(ParticipantFeedLayout.self, forKey: .feedLayout),
                  appearances: try values.decodeIfPresent([ParticipantAppearance].self, forKey: .appearances) ?? [],
                  coverage: try values.decodeIfPresent([ParticipantCoverage].self, forKey: .coverage) ?? [],
                  unresolvedParticipantIDs: try values.decodeIfPresent([String].self, forKey: .unresolvedParticipantIDs) ?? [])
    }
}

public struct ParticipantSpeakerBinding: Codable, Hashable, Sendable {
    public var attachmentID: String
    public var speakerID: String

    public init(attachmentID: String, speakerID: String) {
        self.attachmentID = attachmentID
        self.speakerID = speakerID
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case speakerID = "speaker_id"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(attachmentID: try values.decode(String.self, forKey: .attachmentID),
                  speakerID: try values.decode(String.self, forKey: .speakerID))
    }
}

public struct ParticipantAudioBinding: Codable, Equatable, Sendable {
    public var laneID: String?
    public var selection: MulticamAudioSelection?

    public init(laneID: String) {
        self.laneID = laneID
    }

    public init(selection: MulticamAudioSelection) {
        self.selection = selection
    }

    private enum CodingKeys: String, CodingKey {
        case laneID = "lane_id"
        case selection
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        laneID = try values.decodeIfPresent(String.self, forKey: .laneID)
        selection = try values.decodeIfPresent(MulticamAudioSelection.self, forKey: .selection)
    }
}

public struct ParticipantPerson: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var audio: ParticipantAudioBinding?
    public var speakers: [ParticipantSpeakerBinding]

    public init(id: String, name: String, audio: ParticipantAudioBinding? = nil, speakers: [ParticipantSpeakerBinding] = []) {
        self.id = id
        self.name = name
        self.audio = audio
        self.speakers = speakers
    }

    private enum CodingKeys: String, CodingKey { case id, name, audio, speakers }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
                  audio: try values.decodeIfPresent(ParticipantAudioBinding.self, forKey: .audio),
                  speakers: try values.decodeIfPresent([ParticipantSpeakerBinding].self, forKey: .speakers) ?? [])
    }
}

public struct ParticipantAppearanceOverride: Codable, Equatable, Sendable {
    public var participantID: String
    public var sourceID: String
    public var appearanceID: String
    public var range: MulticamRange

    public init(participantID: String, sourceID: String, appearanceID: String, range: MulticamRange) {
        self.participantID = participantID
        self.sourceID = sourceID
        self.appearanceID = appearanceID
        self.range = range
    }

    private enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
        case sourceID = "source_id"
        case appearanceID = "appearance_id"
        case range
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(participantID: try values.decode(String.self, forKey: .participantID),
                  sourceID: try values.decode(String.self, forKey: .sourceID),
                  appearanceID: try values.decode(String.self, forKey: .appearanceID),
                  range: try values.decode(MulticamRange.self, forKey: .range))
    }
}

/// The portable, editor-approved subset of the source analysis.
public struct ParticipantProject: Codable, Equatable, Sendable {
    public var people: [ParticipantPerson]
    public var sources: [ParticipantSourceGeometry]
    public var appearanceOverrides: [ParticipantAppearanceOverride]
    public var render: ParticipantRenderPlan?

    public init(people: [ParticipantPerson] = [], sources: [ParticipantSourceGeometry] = [],
                appearanceOverrides: [ParticipantAppearanceOverride] = [], render: ParticipantRenderPlan? = nil) {
        self.people = people
        self.sources = sources
        self.appearanceOverrides = appearanceOverrides
        self.render = render
    }

    private enum CodingKeys: String, CodingKey {
        case people, sources, render
        case appearanceOverrides = "appearance_overrides"
    }

    public var isEmpty: Bool { people.isEmpty && sources.isEmpty && appearanceOverrides.isEmpty && render == nil }

    public func appearances(sourceID: String, at time: RationalTime) -> [ParticipantAppearance] {
        sources.first { $0.sourceID == sourceID }?.appearances.filter { $0.range.contains(time) } ?? []
    }

    public func coverage(sourceID: String, at time: RationalTime) -> ParticipantCoverageState {
        sources.first { $0.sourceID == sourceID }?.coverage.first { $0.range.contains(time) }?.state ?? .unknown
    }

    public func needsReconciliation(sourceID: String, analysisIdentity: String) -> Bool {
        guard let source = sources.first(where: { $0.sourceID == sourceID }) else { return false }
        return source.analysisIdentity != analysisIdentity
    }

    public func resolveAppearance(participantID: String, sourceID: String, at time: RationalTime,
                                  holding: String? = nil, includeCameraOff: Bool = true) -> ParticipantAppearance? {
        let candidates = appearances(sourceID: sourceID, at: time).filter { $0.participantID == participantID }
        let override = appearanceOverrides.first {
            $0.sourceID == sourceID && $0.participantID == participantID && $0.range.contains(time)
        }
        return Self.chooseAppearance(candidates, override: override?.appearanceID,
                                     holding: holding, includeCameraOff: includeCameraOff)
    }

    /// Match the speaker within this transcript attachment after projection.
    public func participantID(for word: TranscriptWord) -> String? {
        guard let attachmentID = word.projection?.attachmentID,
              let speakerID = word.speakerID ?? word.projection?.originalSpeakerID else { return nil }
        return people.first { $0.speakers.contains(.init(attachmentID: attachmentID, speakerID: speakerID)) }?.id
    }

    public func speakingParticipantIDs(at time: RationalTime, in projectedWords: [TranscriptWord]) -> Set<String> {
        Set(projectedWords.lazy.filter { $0.start <= time && time < $0.end }.compactMap { participantID(for: $0) })
    }

    public func audioBinding(for participantID: String) -> ParticipantAudioBinding? {
        people.first { $0.id == participantID }?.audio
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(people: try values.decodeIfPresent([ParticipantPerson].self, forKey: .people) ?? [],
                  sources: try values.decodeIfPresent([ParticipantSourceGeometry].self, forKey: .sources) ?? [],
                  appearanceOverrides: try values.decodeIfPresent([ParticipantAppearanceOverride].self, forKey: .appearanceOverrides) ?? [],
                  render: try values.decodeIfPresent(ParticipantRenderPlan.self, forKey: .render))
    }
}

func invalidParticipantProject(_ message: String) -> CutError {
    CutError(code: "invalid_participant_project", message: message)
}

func validParticipantSourceDigest(_ digest: String) -> Bool {
    digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
