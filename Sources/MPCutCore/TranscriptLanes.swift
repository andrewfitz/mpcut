import Foundation

public struct TranscriptLaneMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let order: Int
    public let label: String
    public let colorSlot: Int

    public init(id: String, order: Int, label: String, colorSlot: Int) {
        self.id = id
        self.order = order
        self.label = label
        self.colorSlot = colorSlot
    }
}

extension CutProject {
    public func transcriptLane(sourceID: String?, streamIndex: Int?, trackID: String? = nil) -> TranscriptLaneMetadata? {
        guard case .multicam(let group) = self else { return nil }
        return group.transcriptLane(sourceID: sourceID, streamIndex: streamIndex, trackID: trackID)
    }
}

extension MulticamProject {
    struct TranscriptReplacementPlacement {
        let bindingID: String
        let original: MulticamAudioSelection
        let selection: MulticamAudioSelection
        let trackID: String
        let offset: RationalTime
    }

    func transcriptReplacementPlacements() throws -> [TranscriptReplacementPlacement] {
        let offsets = Dictionary(sources.map { ($0.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return try audioReplacements.compactMap { binding in
            guard let offset = offsets[binding.original.source] else { return nil }
            return try .init(bindingID: binding.id, original: binding.original, selection: binding.replacement,
                             trackID: TranscriptJobPlan.replacementTrackID(binding),
                             offset: offset.adding(binding.relativeOffset))
        }
    }

    public func transcriptLane(sourceID: String?, streamIndex: Int?, trackID: String? = nil) -> TranscriptLaneMetadata? {
        guard let sourceID, let streamIndex else { return nil }
        let recorded = MulticamAudioSelection(source: sourceID, stream: streamIndex)
        let identity = trackID.flatMap(TranscriptJobPlan.replacementTrackIdentity)
        let binding = audioReplacements.first {
            $0.replacement == recorded && TranscriptJobPlan.replacementTrackID($0) == identity
        }
        if identity != nil && binding == nil { return nil }
        let routed = binding?.original ?? recorded
        if binding == nil,
           audioReplacements.contains(where: { $0.original == routed && $0.uncovered == .leaveUncovered }) {
            return nil
        }
        for (order, lane) in mixLanes.enumerated() {
            let matches = switch lane.target {
            case .recording(let pinned): pinned == routed
            case .camera(let angle):
                recordings(for: angle).contains { $0.id == routed.source && $0.audioStream == routed.stream }
            }
            if matches { return .init(id: lane.id, order: order, label: lane.label, colorSlot: lane.colorSlot) }
        }
        return nil
    }
}
