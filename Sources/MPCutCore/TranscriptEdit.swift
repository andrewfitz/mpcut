import Foundation

public struct TranscriptEditRevision: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case timelineRevision = "timeline_revision"
        case transcriptRevision = "transcript_revision"
        case resultID = "result_id"
    }
    public let timelineRevision: Int
    public let transcriptRevision: UInt64
    public let resultID: String

    public init(timelineRevision: Int, transcriptRevision: UInt64, resultID: String) {
        self.timelineRevision = timelineRevision
        self.transcriptRevision = transcriptRevision
        self.resultID = resultID
    }
}

public struct TranscriptWordSelection: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case firstWordID = "first_word_id"
        case lastWordID = "last_word_id"
        case space
        case firstOccurrenceID = "first_occurrence_id"
        case lastOccurrenceID = "last_occurrence_id"
        case kind
        case leadingPadding = "leading_padding"
        case trailingPadding = "trailing_padding"
        case attachmentID = "attachment_id"
    }
    public enum Kind: String, Codable, Sendable { case phrase, gap }

    public let firstWordID: String
    public let lastWordID: String?
    public let space: TranscriptSpace
    public let firstOccurrenceID: String?
    public let lastOccurrenceID: String?
    public let kind: Kind
    public let leadingPadding: RationalTime?
    public let trailingPadding: RationalTime?
    public let attachmentID: String?

    public init(firstWordID: String, lastWordID: String? = nil, space: TranscriptSpace = .currentCut,
                firstOccurrenceID: String? = nil, lastOccurrenceID: String? = nil, kind: Kind = .phrase,
                leadingPadding: RationalTime? = nil, trailingPadding: RationalTime? = nil, attachmentID: String? = nil) {
        self.firstWordID = firstWordID
        self.lastWordID = lastWordID
        self.space = space
        self.firstOccurrenceID = firstOccurrenceID
        self.lastOccurrenceID = lastOccurrenceID
        self.kind = kind
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.attachmentID = attachmentID
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_request")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(firstWordID: try fields.decode(String.self, forKey: .firstWordID),
                  lastWordID: try fields.decodeIfPresent(String.self, forKey: .lastWordID),
                  space: try fields.decodeIfPresent(TranscriptSpace.self, forKey: .space) ?? .currentCut,
                  firstOccurrenceID: try fields.decodeIfPresent(String.self, forKey: .firstOccurrenceID),
                  lastOccurrenceID: try fields.decodeIfPresent(String.self, forKey: .lastOccurrenceID),
                  kind: try fields.decodeIfPresent(Kind.self, forKey: .kind) ?? .phrase,
                  leadingPadding: try fields.decodeIfPresent(RationalTime.self, forKey: .leadingPadding),
                  trailingPadding: try fields.decodeIfPresent(RationalTime.self, forKey: .trailingPadding),
                  attachmentID: try fields.decodeIfPresent(String.self, forKey: .attachmentID))
    }
}

public struct TranscriptResolvedSelection: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case space
        case kind
        case range
        case first
        case last
        case overlappingWordIDs = "overlapping_word_ids"
        case attachmentID = "attachment_id"
    }
    public let space: TranscriptSpace
    public let kind: TranscriptWordSelection.Kind
    public let range: MulticamRange
    public let first: TranscriptOccurrence
    public let last: TranscriptOccurrence
    public let overlappingWordIDs: [String]
    public var attachmentID: String? = nil
}

public struct TranscriptEditRequest: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case action
        case selections
        case target
        case position
        case retainedDuration = "retained_duration"
        case angleID = "angle_id"
        case name
        case boundaryPolicy = "boundary_policy"
        case edge
        case startFrameNudge = "start_frame_nudge"
        case endFrameNudge = "end_frame_nudge"
    }
    public enum Action: String, Codable, Sendable {
        case split, trimStart = "trim_start", trimEnd = "trim_end", delete, tighten, assemble, insert, replace, switchAngle = "switch_angle", queue

        public var reviewsRemovedSpeech: Bool {
            switch self {
            case .trimStart, .trimEnd, .delete, .tighten, .replace: true
            default: false
            }
        }
    }
    public enum BoundaryPolicy: String, Codable, Sendable {
        case exact, nearestFrame = "nearest_frame", copySafe = "copy_safe"
    }
    public enum Edge: String, Codable, Sendable { case start, end }

    public let action: Action
    public let selections: [TranscriptWordSelection]
    public let target: TranscriptWordSelection?
    public let position: RationalTime?
    public let retainedDuration: RationalTime?
    public let angleID: String?
    public let name: String?
    public let boundaryPolicy: BoundaryPolicy
    public let edge: Edge
    public let startFrameNudge: Int?
    public let endFrameNudge: Int?

    public init(action: Action, selections: [TranscriptWordSelection], target: TranscriptWordSelection? = nil,
                position: RationalTime? = nil, retainedDuration: RationalTime? = nil, angleID: String? = nil,
                name: String? = nil, boundaryPolicy: BoundaryPolicy = .nearestFrame, edge: Edge? = nil,
                startFrameNudge: Int? = nil, endFrameNudge: Int? = nil) {
        self.action = action
        self.selections = selections
        self.target = target
        self.position = position
        self.retainedDuration = retainedDuration
        self.angleID = angleID
        self.name = name
        self.boundaryPolicy = boundaryPolicy
        self.edge = edge ?? (action == .trimEnd ? .end : .start)
        self.startFrameNudge = startFrameNudge
        self.endFrameNudge = endFrameNudge
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_request")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(action: try fields.decode(Action.self, forKey: .action),
                  selections: try fields.decode([TranscriptWordSelection].self, forKey: .selections),
                  target: try fields.decodeIfPresent(TranscriptWordSelection.self, forKey: .target),
                  position: try fields.decodeIfPresent(RationalTime.self, forKey: .position),
                  retainedDuration: try fields.decodeIfPresent(RationalTime.self, forKey: .retainedDuration),
                  angleID: try fields.decodeIfPresent(String.self, forKey: .angleID),
                  name: try fields.decodeIfPresent(String.self, forKey: .name),
                  boundaryPolicy: try fields.decodeIfPresent(BoundaryPolicy.self, forKey: .boundaryPolicy) ?? .nearestFrame,
                  edge: try fields.decodeIfPresent(Edge.self, forKey: .edge),
                  startFrameNudge: try fields.decodeIfPresent(Int.self, forKey: .startFrameNudge),
                  endFrameNudge: try fields.decodeIfPresent(Int.self, forKey: .endFrameNudge))
    }
}

public struct TranscriptEditBoundary: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case space
        case requested
        case resolved
        case copySafeAlternatives = "copy_safe_alternatives"
        case affectedWordIDs = "affected_word_ids"
        case attachmentID = "attachment_id"
    }
    public let space: TranscriptSpace
    public let requested: RationalTime
    public internal(set) var resolved: RationalTime
    public let copySafeAlternatives: [RationalTime]
    public var affectedWordIDs: [String] = []
    public var attachmentID: String? = nil
}

public struct TranscriptEditCommit: Sendable {
    public let project: CutProject
    public let undo: CutHistoryState?
}

/// A plan contains the exact reviewed timeline. It must be applied under the
/// same mutation guard that reads the current revision and publishes its undo.
public struct TranscriptEditPlan: Sendable {
    public let revision: TranscriptEditRevision
    public let attachmentResults: [String: String]
    public let action: TranscriptEditRequest.Action
    public let historyAction: String
    public let name: String?
    public let selections: [TranscriptResolvedSelection]
    public let boundaries: [TranscriptEditBoundary]
    public let affectedOccurrences: [String]
    public let affectedSpeech: [TranscriptOccurrence]
    public let unavailableEvidenceAttachmentIDs: [String]
    public let previousDuration: RationalTime
    public let duration: RationalTime
    public let requestedRetainedDuration: RationalTime?
    public let retainedDuration: RationalTime?
    public let previousTier: TierSummary?
    public let tier: TierSummary?
    public let snapshot: CutProject

    let original: CutProject

    public func validate(to project: CutProject, revision: TranscriptEditRevision) throws {
        guard self.revision == revision, project == original,
              project.transcripts.revision == revision.transcriptRevision,
              attachmentResults.values.contains(revision.resultID),
              attachmentResults.allSatisfy({ id, resultID in
                  project.transcripts.attachments.contains { $0.id == id && $0.resultID == resultID }
              }) else {
            throw transcriptEditError("The project or transcript changed after the edit was reviewed.", code: "stale_transcript_plan")
        }
    }

    public func apply(to project: CutProject, revision: TranscriptEditRevision) throws -> TranscriptEditCommit {
        try validate(to: project, revision: revision)
        guard action != .queue else {
            throw transcriptEditError("A queue plan is an excerpt snapshot.")
        }
        let undo = snapshot == project ? nil : CutHistoryState(action: historyAction, project: project)
        return TranscriptEditCommit(project: snapshot, undo: undo)
    }
}

func transcriptEditError(_ message: String, code: String = "invalid_transcript_edit") -> CutError {
    CutError(code: code, message: message)
}
