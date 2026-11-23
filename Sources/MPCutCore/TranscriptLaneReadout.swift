import Foundation

/// Lane metadata is part of project readouts, separate from stored transcript documents.
package struct TranscriptLaneReadout<Item: Encodable>: Encodable {
    package let item: Item
    package let lanes: [TranscriptLaneMetadata]

    package init(_ item: Item, lanes: [TranscriptLaneMetadata]) {
        self.item = item
        self.lanes = lanes
    }

    package init(_ item: Item, lane: TranscriptLaneMetadata?) {
        self.init(item, lanes: lane.map { [$0] } ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case laneID = "lane_id"
        case laneOrder = "lane_order"
        case laneLabel = "lane_label"
        case laneColorSlot = "lane_color_slot"
        case lanes
    }

    package func encode(to encoder: Encoder) throws {
        try item.encode(to: encoder)
        guard let lane = lanes.first else { return }
        var fields = encoder.container(keyedBy: CodingKeys.self)
        if lanes.count == 1 {
            try fields.encode(lane.id, forKey: .laneID)
            try fields.encode(lane.order, forKey: .laneOrder)
            try fields.encode(lane.label, forKey: .laneLabel)
            try fields.encode(lane.colorSlot, forKey: .laneColorSlot)
        } else {
            try fields.encode(lanes.map { LaneFields(laneID: $0.id, laneOrder: $0.order, laneLabel: $0.label,
                                                   laneColorSlot: $0.colorSlot) }, forKey: .lanes)
        }
    }

    private struct LaneFields: Encodable {
        let laneID: String
        let laneOrder: Int
        let laneLabel: String
        let laneColorSlot: Int

        private enum CodingKeys: String, CodingKey {
            case laneID = "lane_id"
            case laneOrder = "lane_order"
            case laneLabel = "lane_label"
            case laneColorSlot = "lane_color_slot"
        }
    }
}

extension TranscriptLaneReadout: Sendable where Item: Sendable {}

extension CutProject {
    package func transcriptLane(for track: TranscriptTrack, attachment: TranscriptAttachment?) -> TranscriptLaneMetadata? {
        if let attachment {
            guard let binding = attachment.bindings.first(where: { $0.trackID == track.id }) else { return nil }
            return transcriptLane(sourceID: binding.sourceID, streamIndex: binding.streamIndex, trackID: track.id)
        }
        return transcriptLane(sourceID: track.sourceID, streamIndex: track.streamIndex, trackID: track.id)
    }

    package func transcriptLane(for track: TranscriptJobTrack) -> TranscriptLaneMetadata? {
        transcriptLane(sourceID: track.projectSourceID, streamIndex: track.zoomMixStream ?? track.streamIndex, trackID: track.id)
    }
}

extension TranscriptIndex {
    package func transcriptSpeakerReadouts(project: CutProject, laneID: String?) -> [TranscriptLaneReadout<TranscriptSpeaker>] {
        guard case let .multicam(multicam) = project, !multicam.mixLanes.isEmpty else {
            return laneID == nil ? speakers.map { .init($0, lane: nil) } : []
        }
        let trackLanes = Dictionary(uniqueKeysWithValues: document.tracks.compactMap { track in
            project.transcriptLane(for: track, attachment: attachment).map { (track.id, $0) }
        })
        var speakerLanes: [String: [String: TranscriptLaneMetadata]] = [:]
        for word in readAll(space: .source) {
            guard let speaker = word.speakerID else { continue }
            if let id = word.trackID, let lane = trackLanes[id], word.audibility != .inferred {
                speakerLanes[speaker, default: [:]][lane.id] = lane
            }
        }
        return speakers.compactMap { speaker in
            let lanes = (speakerLanes[speaker.id]?.values.sorted { $0.order < $1.order }) ?? []
            guard laneID == nil || lanes.contains(where: { $0.id == laneID }) else { return nil }
            return .init(speaker, lanes: lanes)
        }
    }
}
