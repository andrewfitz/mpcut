import Foundation
import MPCutCore

extension TilesCLI {
    func runAnglesAndSwitches(json: Bool, useSidecar: Bool, interruption: Interruption) throws {
        let input = try request(interruption)
        let document = try input.url("project_path")
        if operation == .useAngles {
            let feeds = try input.value("feed_id", as: [String].self) ?? []
            let all = try input.value("all", as: Bool.self) ?? false
            guard all == feeds.isEmpty else {
                throw CLIError("invalid_arguments", "Choose --all or one or more --feed-id values.")
            }
            let clipID = try input.value("clip_id", as: String.self)
            let selectedSource = try input.value("source_id", as: String.self)
            var made: [MulticamSource] = []
            let receipt = try mutateProject(input, document: document, action: "Use Feeds as Multicam Angles", interruption: interruption) { project in
                let sources = project.participants.sources.map(\.sourceID)
                let clipSource = clipID.flatMap { id in project.sequenceClips?.first { $0.id == id }?.file }
                guard let source = selectedSource ?? clipSource ?? (sources.count == 1 ? sources.first : nil) else {
                    throw CLIError("invalid_arguments", "Choose a recording with --source-id.")
                }
                let updated = try TileFeedAngles.usingFeeds(in: project, document: document, sourceID: source,
                    feedIDs: feeds, clipID: clipID, useSidecar: useSidecar, cancelled: { !interruption.isActive })
                made = updated.angles.filter { $0.feedAngle != nil }
                project = .multicam(updated)
            }
            try writeJSON(TileAngleUseReceipt(projectPath: receipt.projectPath, operationCount: receipt.operationCount,
                                              angles: made), pretty: !json, checkCancellation: false)
            return
        }

        let hold = try RationalTime(parsing: input.value("minimum_hold", as: String.self) ?? "1")
        let (base, indexes) = try loadTileSwitchTranscripts(document: document,
            attachmentID: input.value("attachment_id", as: String.self), useSidecar: useSidecar, interruption: interruption)
        let revision = try TileSwitches.revision(of: base)
        let overrides = try input.value("voice_angle", as: [String].self) ?? []
        let project = try TileSwitches.applyingVoiceOverrides(overrides, in: base, indexes: indexes)
        let proposals = try TileSwitches.propose(in: project, document: document, indexes: indexes, minimumHold: hold,
                                                revision: revision, useSidecar: useSidecar, cancelled: { !interruption.isActive })
        try writeJSON(TileSwitchProposalReceipt(projectRevision: revision, links: TileSwitches.links(in: project, indexes: indexes),
                                                proposals: proposals), pretty: !json)
    }
}

private struct TileAngleUseReceipt: Encodable {
    let projectPath: String
    let operationCount: Int
    let angles: [MulticamSource]

    private enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case operationCount = "operation_count"
        case angles
    }
}

private struct TileSwitchProposalReceipt: Encodable {
    let projectRevision: String
    let links: [TileSpeakerAngle]
    let proposals: [TileSwitchProposal]

    private enum CodingKeys: String, CodingKey {
        case projectRevision = "project_revision"
        case links, proposals
    }
}
