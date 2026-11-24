import Foundation
import MPCutCore

func sourceID(in project: CutProject, request: ParticipantRequest, scannedOnly: Bool = true) throws -> String {
    let ids: Set<String>
    if scannedOnly {
        ids = Set(project.participants.sources.map(\.sourceID))
    } else if case let .multicam(multicam) = project {
        ids = Set(multicam.pictureSources.filter { $0.feedAngle == nil }.map(\.id))
    } else {
        ids = Set(project.sequenceClips?.map(\.file) ?? [])
    }
    if let id = try request.value("source_id", as: String.self) {
        guard ids.contains(id) else { throw CLIError("unknown_source", "Unknown source ID ‘\(id)’.") }
        return id
    }
    if ids.count == 1, let id = ids.first { return id }
    guard !ids.isEmpty else { throw CLIError("unknown_source", "This project contains no matching recording.") }
    throw CLIError("invalid_arguments", "Choose a recording with --source-id. Available IDs: \(ids.sorted().joined(separator: ", ")).")
}

extension TilesCLI {
    func runReview(json: Bool, useSidecar: Bool, interruption: Interruption) throws {
        let request = try request(interruption)
        let cancelled: @Sendable () -> Bool = { !interruption.isActive }
        if operation == .scan {
            let runner = try ParticipantCLI(operation: .scan, arguments: [])
            try runner.run(request: request, json: json, useSidecar: useSidecar, interruption: interruption, tiles: true)
            return
        }
        if operation == .inspect || operation == .preview || operation == .listFeeds || operation == .inspectFeed {
            let scan = request.fields["analysis_file"] != nil
            guard scan != (request.fields["project_path"] != nil) else {
                throw CLIError("invalid_arguments", "Supply one scan or saved project.")
            }
            let review: TilesReview
            if scan {
                guard request.fields["source_id"] == nil else {
                    throw CLIError("invalid_arguments", "Use --source-id only with a project.")
                }
                review = TilesReview(scan: try request.analysis(cancelled: cancelled))
            } else {
                let document = try request.url("project_path")
                let project = try CutProject.load(from: document)
                let requested = try request.value("source_id", as: String.self)
                let scanned = operation != .inspect
                    || project.participants.sources.contains { requested == nil || requested == $0.sourceID }
                let source = try sourceID(in: project, request: request, scannedOnly: scanned)
                review = TilesReview(project: project, sourceID: source, document: document,
                                     useSidecar: useSidecar, cancelled: cancelled)
            }
            if let clock = try request.value("clock", as: String.self), clock != "source" {
                throw CLIError("invalid_arguments", "Tiles queries use --clock source.")
            }
            let time = try request.value("at", as: String.self).map { try RationalTime(parsing: $0) }
            guard time.map({ $0 >= .zero }) != false else {
                throw CLIError("invalid_arguments", "Choose a nonnegative source time.")
            }
            switch operation {
            case .inspect:
                let range = try request.tileRange()
                let issues = try request.value("issues", as: Bool.self) ?? false
                let changes = try request.value("layout_changes", as: Bool.self) ?? false
                guard !(time != nil && range != nil), !(issues && changes) else {
                    throw CLIError("invalid_arguments", "Choose a single time or range and a single report type.")
                }
                if let rule = try request.value("rule", as: ParticipantMarkerRule.self) {
                    guard changes else { throw CLIError("invalid_arguments", "Use a marker rule with --layout-changes.") }
                    try writeJSON(review.layoutMarkers(rule: rule, at: time, range: range), pretty: !json)
                } else {
                    try writeJSON(review.report(at: time, range: range, issuesOnly: issues, changesOnly: changes), pretty: !json)
                }
            case .preview:
                let output = try request.url("output")
                let issueID = try request.value("issue_id", as: String.self)
                if let time, issueID == nil {
                    try review.writePreview(at: time, to: output, cancelled: cancelled)
                } else if let issueID, time == nil, let issue = review.issues.first(where: { $0.id == issueID }) {
                    try review.writePreview(issue: issue, to: output, cancelled: cancelled)
                } else {
                    throw CLIError("invalid_arguments", "Choose --at TIME or an issue ID from inspect --issues.")
                }
                struct Preview: Encodable {
                    let schemaVersion = 1
                    let output: String
                    let sourceID: String
                    let issueID: String?
                    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", output, sourceID = "source_id", issueID = "issue_id" }
                }
                try writeJSON(Preview(output: output.path, sourceID: review.sourceID, issueID: issueID), pretty: !json, checkCancellation: false)
            case .listFeeds:
                struct List: Encodable {
                    let schemaVersion = 1
                    let sourceID: String
                    let counts: TilesCounts
                    let feeds: [TilesFeed]
                    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", sourceID = "source_id", counts, feeds }
                }
                try writeJSON(List(sourceID: review.sourceID, counts: review.counts, feeds: review.feeds), pretty: !json)
            case .inspectFeed:
                try writeJSON(review.feed(id: request.required("feed_id", as: String.self)), pretty: !json)
            default: break
            }
            return
        }

        let document = try request.url("project_path")
        var conflicts: [String] = []
        var resultFeedID: String?
        var reviewIssueCount: Int?
        let acceptingScan = operation == .accept && request.fields["analysis_file"] != nil
        let action: String
        switch operation {
        case .addFeed: action = "Add Feed"
        case .accept where !acceptingScan: action = "Review Tile Counts"
        default: action = "Edit Tiles"
        }
        let receipt = try mutateProject(request, document: document, action: action, interruption: interruption) { project in
            if operation == .addFeed {
                resultFeedID = try project.participants.addFeed(name: request.value("name", as: String.self))
                return
            }
            let source = try sourceID(in: project, request: request, scannedOnly: !acceptingScan)
            if operation == .accept {
                let overrides = try request.tileCountHints()
                let clearHints = try request.value("clear_count_hints", as: Bool.self) ?? false
                guard acceptingScan || overrides != nil || clearHints else {
                    throw CLIError("invalid_arguments", "Supply a scan, a count hint or --clear-count-hints.")
                }
                guard !(clearHints && overrides != nil) else {
                    throw CLIError("invalid_arguments", "Choose count hints or --clear-count-hints.")
                }
                if acceptingScan {
                    let scan = try request.analysis(cancelled: cancelled)
                    try project.acceptParticipantAnalysis(scan, sourceID: source, relativeTo: document, cancelled: cancelled)
                }
                if clearHints {
                    try project.participants.setTileCountHints(sourceID: source, hints: nil)
                } else if let overrides {
                    let existing = project.participants.sources.first { $0.sourceID == source }?.countHints
                    try project.participants.setTileCountHints(sourceID: source, hints: overrides.overriding(existing))
                }
                reviewIssueCount = TilesReview(project: project, sourceID: source, document: document,
                                               useSidecar: useSidecar, cancelled: cancelled).issues.count
                return
            }
            let tile = try request.value("tile_id", as: String.self)
            let feed = try request.value("feed_id", as: String.self)
            let clear = try request.value("clear", as: Bool.self) ?? false
            var model = project.participants
            if operation == .link {
                guard let tile, clear != (feed != nil) else {
                    throw CLIError("invalid_arguments", "Supply --tile-id and either --feed-id or --clear.")
                }
                let range = try request.tileRange() ?? tileExtent(tile, sourceID: source, in: model)
                try model.linkAppearance(sourceID: source, appearanceID: tile, participantID: feed, range: range)
            } else {
                guard let feed, let index = model.people.firstIndex(where: { $0.id == feed }) else {
                    throw CLIError("unknown_feed", "Supply the ID of a feed in this project.")
                }
                switch operation {
                case .renameFeed:
                    try model.renameFeed(feed, name: request.required("name", as: String.self))
                case .micFeed:
                    let binding = try request.value("binding", as: ParticipantAudioBinding.self)
                    let micID = try request.value("mic_id", as: String.self)
                    let stream = try request.value("audio_stream_index", as: Int.self)
                    guard [clear, binding != nil, micID != nil].filter({ $0 }).count == 1,
                          stream == nil || micID != nil else {
                        throw CLIError("invalid_arguments", "Choose --mic-id, a binding object or --clear.")
                    }
                    let selected = micID.map { id in
                        stream.map { ParticipantAudioBinding(selection: .init(source: id, stream: $0)) }
                            ?? ParticipantAudioBinding(laneID: id)
                    } ?? binding
                    try model.setFeedMicrophone(feed, binding: selected)
                case .voiceFeed:
                    let attachment = try request.value("attachment_id", as: String.self)
                    let speaker = try request.value("speaker_id", as: String.self) ?? request.value("track_id", as: String.self)
                    guard clear && speaker == nil || !clear && attachment != nil && speaker != nil else {
                        throw CLIError("invalid_arguments", "Choose --attachment-id and --speaker-id or --clear.")
                    }
                    try model.setFeedVoice(feed, attachmentID: attachment, speakerID: speaker)
                case .preferFeed:
                    guard clear != (tile != nil) else {
                        throw CLIError("invalid_arguments", "Choose either --tile-id or --clear.")
                    }
                    let fallback = try tile.map { try tileExtent($0, sourceID: source, in: model) }
                        ?? MulticamRange(from: .zero, to: model.sources.first { $0.sourceID == source }?.appearances.map(\.range.to).max() ?? .zero)
                    try model.preferTile(sourceID: source, feedID: feed, tileID: tile, range: request.tileRange() ?? fallback)
                case .mergeFeeds:
                    let surviving = try request.required("into_feed_id", as: String.self)
                    conflicts = try project.mergeTileFeeds(feed, into: surviving)
                    resultFeedID = surviving
                    return
                case .splitFeed:
                    let id = try request.value("new_feed_id", as: String.self) ?? UUID().uuidString.lowercased()
                    let tile = try request.required("tile_id", as: String.self)
                    let name = try request.value("name", as: String.self) ?? model.people[index].name + " (split)"
                    try model.splitFeed(feed, sourceID: source, tileID: tile,
                                        range: request.tileRange() ?? tileExtent(tile, sourceID: source, in: model), newFeedID: id, name: name)
                    resultFeedID = id
                default: throw CLIError("invalid_arguments", "Unknown Tiles edit.")
                }
            }
            project.participants = model
        }
        struct Mutation: Encodable {
            let schemaVersion = 1
            let ok = true
            let projectPath: String
            let operationCount: Int
            let feedID: String?
            let conflicts: [String]
            let reviewIssueCount: Int?
            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version", ok, projectPath = "project_path", operationCount = "operation_count"
                case feedID = "feed_id", conflicts
                case reviewIssueCount = "review_issue_count"
            }
        }
        try writeJSON(Mutation(projectPath: receipt.projectPath, operationCount: receipt.operationCount,
                               feedID: resultFeedID, conflicts: conflicts, reviewIssueCount: reviewIssueCount),
                      pretty: !json, checkCancellation: false)
    }
}

private func tileExtent(_ id: String, sourceID: String, in model: ParticipantProject) throws -> MulticamRange {
    let ranges = model.sources.first { $0.sourceID == sourceID }?.appearances.filter { $0.id == id }.map(\.range) ?? []
    guard let from = ranges.map(\.from).min(), let to = ranges.map(\.to).max() else {
        throw CLIError("unknown_tile", "Unknown tile ‘\(id)’ on this recording.")
    }
    return .init(from: from, to: to)
}

extension ParticipantRequest {
    func tileRange() throws -> MulticamRange? {
        let from = try value("from", as: String.self)
        let to = try value("to", as: String.self)
        if from == nil, to == nil { return nil }
        guard let from, let to else { throw CLIError("invalid_arguments", "Supply both --from and --to.") }
        let start = try RationalTime(parsing: from)
        let end = try RationalTime(parsing: to)
        guard start >= .zero, start < end else {
            throw CLIError("invalid_arguments", "Choose a nonempty, nonnegative source range.")
        }
        return .init(from: start, to: end)
    }

    func tileCountHints() throws -> TilesCountHints? {
        let feeds = try value("expected_feeds", as: Int.self)
        let tiles = try value("max_visible_tiles", as: Int.self)
        guard feeds.map({ $0 > 0 }) != false, tiles.map({ $0 > 0 }) != false else {
            throw CLIError("invalid_arguments", "Count hints must be positive.")
        }
        return feeds == nil && tiles == nil ? nil : .init(expectedFeeds: feeds, maxVisibleTiles: tiles)
    }
}
