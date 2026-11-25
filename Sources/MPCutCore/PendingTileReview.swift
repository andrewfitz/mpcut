import Foundation

package struct TilesReviewChoices: Codable, Equatable, Sendable {
    package var analysisIdentity = ""
    package var names: [String: String] = [:]
    package var unchecked: Set<String> = []
    package var merged: [String: String] = [:]
    package var expectedFeeds = ""
    package var expectedTiles = ""
    package var editedHints: Bool?
    package var grids: [GridCorrection] = []

    package init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_pending_tile_scan")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        analysisIdentity = try values.decodeIfPresent(String.self, forKey: .analysisIdentity) ?? ""
        names = try values.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        unchecked = try values.decodeIfPresent(Set<String>.self, forKey: .unchecked) ?? []
        merged = try values.decodeIfPresent([String: String].self, forKey: .merged) ?? [:]
        expectedFeeds = try values.decodeIfPresent(String.self, forKey: .expectedFeeds) ?? ""
        expectedTiles = try values.decodeIfPresent(String.self, forKey: .expectedTiles) ?? ""
        editedHints = try values.decodeIfPresent(Bool.self, forKey: .editedHints)
        grids = try values.decodeIfPresent([GridCorrection].self, forKey: .grids) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case analysisIdentity, names, unchecked, merged, expectedFeeds, expectedTiles, editedHints, grids
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(analysisIdentity, forKey: .analysisIdentity)
        try values.encode(names, forKey: .names)
        try values.encode(unchecked.sorted(), forKey: .unchecked)
        try values.encode(merged, forKey: .merged)
        try values.encode(expectedFeeds, forKey: .expectedFeeds)
        try values.encode(expectedTiles, forKey: .expectedTiles)
        try values.encodeIfPresent(editedHints, forKey: .editedHints)
        try values.encode(grids, forKey: .grids)
    }

    package init() {}

    package init(analysisIdentity: String, expectedFeeds: String = "", expectedTiles: String = "") {
        self.analysisIdentity = analysisIdentity
        self.expectedFeeds = expectedFeeds
        self.expectedTiles = expectedTiles
    }

    package init(scan: ParticipantScanResult) {
        self.init(analysisIdentity: scan.analysisIdentity,
                  expectedFeeds: scan.countHints?.expectedFeeds.map(String.init) ?? "",
                  expectedTiles: scan.countHints?.maxVisibleTiles.map(String.init) ?? "")
    }

    package struct GridCorrection: Codable, Equatable, Sendable {
        package let range: MulticamRange
        package let columns: Int
        package let rows: Int

        package init(range: MulticamRange, columns: Int, rows: Int) {
            self.range = range
            self.columns = columns
            self.rows = rows
        }

        private enum CodingKeys: String, CodingKey { case range, columns, rows }

        package init(from decoder: Decoder) throws {
            try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_pending_tile_scan")
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            range = try fields.decode(MulticamRange.self, forKey: .range)
            columns = try fields.decode(Int.self, forKey: .columns)
            rows = try fields.decode(Int.self, forKey: .rows)
        }

        package var isValid: Bool {
            (1...64).contains(columns) && (1...64).contains(rows) && columns * rows <= 64
        }
    }

    package func maximumVisibleTiles(in scan: ParticipantScanResult, rawMaximum: Int) -> Int {
        guard let analysis = scan.analysis, !grids.isEmpty else { return rawMaximum }
        let valid = grids.filter(\.isValid)
        guard !valid.isEmpty else { return rawMaximum }
        let boundaries = valid.flatMap { [$0.range.from, $0.range.to] }
            .filter { .zero <= $0 && $0 < scan.source.duration }.sorted()
        let appearanceEnds = Dictionary(analysis.appearances.map { ($0.id, $0.end) }, uniquingKeysWith: min)
        let detectedEnd = analysis.resumeAt ?? analysis.end
        let observations = analysis.observations
        var observation = 0
        var boundary = 0
        var maximum = 0
        while observation < observations.count || boundary < boundaries.count {
            let nextObservation = observation < observations.count ? observations[observation].time : nil
            let time: RationalTime
            if boundary < boundaries.count, nextObservation.map({ boundaries[boundary] <= $0 }) ?? true {
                time = boundaries[boundary]
                boundary += 1
            } else if let nextObservation {
                time = nextObservation
            } else {
                break
            }
            while observation < observations.count, observations[observation].time <= time {
                observation += 1
            }
            if let grid = valid.last(where: { $0.range.contains(time) }) {
                maximum = max(grid.columns * grid.rows, maximum)
            } else if observation > 0, time < detectedEnd {
                let count = observations[observation - 1].regions.reduce(into: 0) { count, region in
                    if appearanceEnds[region.appearanceID].map({ time < $0 }) ?? true { count += 1 }
                }
                maximum = max(count, maximum)
            }
        }
        return maximum
    }

    static func validMerges(_ merges: [String: String]) -> Bool {
        Set(merges.keys).isDisjoint(with: merges.values)
    }

    package mutating func merge(_ from: String, into to: String) {
        guard from != to, merged[from] == nil, merged[to] == nil else { return }
        for key in merged.keys.filter({ merged[$0] == from }) { merged[key] = to }
        merged[from] = to
    }
}

/// The scan payload shared by the saved edit and its undo and redo states.
/// File paths are bindings on each review, including the path used to display a scene report.
struct EmbeddedTileScan: Codable, Sendable {
    let scan: ParticipantScanResult

    static func allowsFraction(at keys: ArraySlice<String>) -> Bool {
        switch Array(keys) {
        case ["scene_report", "scenes", "start_seconds"],
             ["analysis", "observations", "confidence"],
             ["analysis", "observations", "regions", "confidence"],
             ["analysis", "observations", "regions", "identity_confidence"],
             ["analysis", "observations", "regions", "possible_matches", "confidence"]:
            return true
        default:
            return keys.dropLast().elementsEqual(["analysis", "observations", "regions", "rect"])
                && keys.last.map { ["x", "y", "width", "height"].contains($0) } == true
        }
    }

    init(_ scan: ParticipantScanResult) throws {
        var value = scan
        if scan.source.contentSHA256 == nil {
            let file = URL(fileURLWithPath: scan.source.file)
            let identity = try SourceIdentity(file)
            guard SceneSourceStamp(identity: identity) == scan.source.stamp,
                  scan.source.inode.map({ $0 == identity.inode }) ?? true else {
                throw invalidParticipantProject("The recording changed during the tile scan.")
            }
            var source = scan.source
            source.contentSHA256 = try participantSourceDigest(file, identity: identity)
            value = .init(state: scan.state, source: source, configuration: scan.configuration, analysis: scan.analysis,
                          sceneReport: scan.sceneReport, analysisIdentity: scan.analysisIdentity, countHints: scan.countHints)
        }
        self.scan = value
        try validate()
    }

    typealias Key = ParticipantScanResult.CodingKeys
    typealias SourceKey = ParticipantScanSource.CodingKeys

    init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(Key.self, in: decoder, code: "invalid_pending_tile_scan")
        let fields = try decoder.container(keyedBy: Key.self)
        let source = try fields.nestedContainer(keyedBy: SourceKey.self, forKey: .source)
        let digest = try source.decode(String.self, forKey: .contentSHA256)
        guard validParticipantSourceDigest(digest), !source.contains(.file), !source.contains(.inode) else {
            throw invalidParticipantProject("Invalid embedded tile scan source.")
        }
        let binding = try ParticipantScanSource(file: "", stamp: source.decode(SceneSourceStamp.self, forKey: .stamp),
            producer: source.decodeIfPresent(String.self, forKey: .producer), contentSHA256: digest,
            stream: source.decode(Int.self, forKey: .stream), origin: source.decode(RationalTime.self, forKey: .origin),
            timeBase: source.decode(RationalTime.self, forKey: .timeBase), duration: source.decode(RationalTime.self, forKey: .duration),
            transform: source.decode(ParticipantDisplayTransform.self, forKey: .transform))
        scan = try .init(state: fields.decode(ParticipantScanResult.State.self, forKey: .state), source: binding,
            configuration: fields.decode(ParticipantScanConfiguration.self, forKey: .configuration),
            analysis: fields.decodeIfPresent(ParticipantTrackingResult.self, forKey: .analysis),
            sceneReport: fields.contains(.sceneReport) ? SceneReport(from: fields.superDecoder(forKey: .sceneReport), embedded: true) : nil,
            analysisIdentity: fields.decode(String.self, forKey: .analysisIdentity),
            countHints: fields.decodeIfPresent(TilesCountHints.self, forKey: .countHints))
        try validate()
    }

    private func validate() throws {
        let source = scan.source
        guard let digest = source.contentSHA256, validParticipantSourceDigest(digest),
              source.duration > .zero, source.timeBase > .zero, source.stream >= 0,
              source.transform.pixelAspectNum > 0, source.transform.pixelAspectDen > 0,
              validStillID(scan.analysisIdentity), scan.configuration.feedLayout.isValid else {
            throw invalidParticipantProject("Invalid recording evidence in the embedded tile scan.")
        }
        guard let analysis = scan.analysis else {
            guard scan.state == .paused || scan.state == .incomplete else {
                throw invalidParticipantProject("The completed tile scan has no analysis.")
            }
            return
        }
        guard analysis.schemaVersion == 1, analysis.start >= .zero, analysis.end <= source.duration,
              analysis.end >= analysis.start else { throw invalidParticipantProject("Invalid embedded tile scan range.") }
        var previous: RationalTime?
        for observation in analysis.observations {
            guard previous.map({ $0 < observation.time }) ?? true,
                  observation.time >= analysis.start, observation.time < analysis.end,
                  (0...1).contains(observation.confidence),
                  observation.regions.allSatisfy({ $0.rect.bounds.isValid && (0...1).contains($0.confidence)
                      && ($0.identityConfidence.map { (0...1).contains($0) } ?? true)
                      && $0.possibleMatches.allSatisfy { (0...1).contains($0.confidence) } }) else {
                throw invalidParticipantProject("Invalid observation in the embedded tile scan.")
            }
            previous = observation.time
        }
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        var source = fields.nestedContainer(keyedBy: SourceKey.self, forKey: .source)
        try source.encode(scan.source.stamp, forKey: .stamp)
        try source.encodeIfPresent(scan.source.producer, forKey: .producer)
        try source.encode(scan.source.contentSHA256, forKey: .contentSHA256)
        try source.encode(scan.source.stream, forKey: .stream)
        try source.encode(scan.source.origin, forKey: .origin)
        try source.encode(scan.source.timeBase, forKey: .timeBase)
        try source.encode(scan.source.duration, forKey: .duration)
        try source.encode(scan.source.transform, forKey: .transform)
        try fields.encode(scan.state, forKey: .state)
        try fields.encode(scan.configuration, forKey: .configuration)
        try fields.encodeIfPresent(scan.analysis, forKey: .analysis)
        if let report = scan.sceneReport { try report.encode(to: fields.superEncoder(forKey: .sceneReport), embedded: true) }
        try fields.encode(scan.analysisIdentity, forKey: .analysisIdentity)
        try fields.encodeIfPresent(scan.countHints, forKey: .countHints)
    }

    func digest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return TranscriptStore.digest(try encoder.encode(self))
    }
}

package struct PendingTileReview: Codable, Equatable, Sendable {
    package let id: String
    package var sourceID: String
    package var file: String
    package let scanSHA256: String
    package var choices: TilesReviewChoices
    let asset: EmbeddedTileScan

    enum CodingKeys: String, CodingKey {
        case id, file, choices
        case sourceID = "source_id"
        case scanSHA256 = "scan_sha256"
    }

    package init(scan: ParticipantScanResult, sourceID: String, file: String, previous: Self? = nil) throws {
        asset = try .init(scan)
        scanSHA256 = try asset.digest()
        id = previous?.id ?? UUID().uuidString.lowercased()
        self.file = file
        self.sourceID = sourceID
        if let previous, previous.choices.analysisIdentity == scan.analysisIdentity {
            choices = previous.choices
        } else {
            choices = .init(scan: scan)
        }
    }

    package func load(recording: URL, cancelled: @escaping () -> Bool = { false }) throws -> ParticipantScanResult {
        try asset.scan.rebindingPendingReview(to: recording, cancelled: cancelled)
    }

    private var choiceFeedIDs: Set<String> {
        var ids = Set<String>()
        for observation in asset.scan.analysis?.observations ?? [] {
            for region in observation.regions {
                if region.kind == .screenShare {
                    ids.insert("share-\(region.appearanceID)")
                } else if let id = region.participantID {
                    ids.insert("feed-\(id)")
                }
            }
        }
        return ids
    }

    private func reviewToken() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data((id + "/" + scanSHA256 + "/").utf8)
        data.append(try encoder.encode(choices))
        return TranscriptStore.digest(data)
    }

    fileprivate func checkReviewToken(_ token: String) throws {
        guard try reviewToken() == token else {
            throw CutError(code: "stale_tile_review", message: "The pending scan or choices changed. Read the pending review again.")
        }
    }

    package func report() throws -> TilesPendingReviewReport {
        try .init(sourceID: sourceID, reviewID: id, scanSHA256: scanSHA256, scanState: asset.scan.state,
                  feedIDs: choiceFeedIDs.sorted(), choices: .init(choices), reviewToken: reviewToken())
    }

    fileprivate func replacingChoices(_ proposed: TilesReviewChoices) throws -> Self {
        var replacement = self
        replacement.choices = proposed
        let analysisIdentity = asset.scan.analysisIdentity
        if proposed.analysisIdentity.isEmpty { replacement.choices.analysisIdentity = analysisIdentity }
        let referenced = Set(proposed.names.keys).union(proposed.unchecked).union(proposed.merged.keys).union(proposed.merged.values)
        guard replacement.choices.analysisIdentity == analysisIdentity, referenced.isSubset(of: choiceFeedIDs),
              proposed.names.values.allSatisfy({ !$0.contains("\0") }),
              [proposed.expectedFeeds, proposed.expectedTiles].allSatisfy({ $0.isEmpty || (Int($0) ?? 0) > 0 }) else {
            throw invalidParticipantProject("Use the pending scan identity, its feed IDs, valid names and positive or blank count hints.")
        }
        return replacement
    }

    package func reconciliationToken(for review: ParticipantReconciliation, scan: ParticipantScanResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let token = try review.reviewToken(for: scan)
        guard !review.retainedCopiedGeometry else { return token }
        var data = Data(token.utf8)
        data.append(try encoder.encode(choices))
        return TranscriptStore.digest(data)
    }

    package init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_pending_tile_scan")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        sourceID = try fields.decode(String.self, forKey: .sourceID)
        file = try fields.decode(String.self, forKey: .file)
        scanSHA256 = try fields.decode(String.self, forKey: .scanSHA256)
        choices = try fields.decode(TilesReviewChoices.self, forKey: .choices)
        asset = try ProjectEmbeddedAssets.scan(digest: scanSHA256, decoder: decoder)
        if choices.analysisIdentity.isEmpty { choices.analysisIdentity = asset.scan.analysisIdentity }
    }

    package func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(sourceID, forKey: .sourceID)
        try fields.encode(file, forKey: .file)
        try fields.encode(scanSHA256, forKey: .scanSHA256)
        try fields.encode(choices, forKey: .choices)
        try ProjectEmbeddedAssets.register(asset, digest: scanSHA256, encoder: encoder)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.sourceID == rhs.sourceID && lhs.file == rhs.file &&
            lhs.scanSHA256 == rhs.scanSHA256 && lhs.choices == rhs.choices
    }
}

/// The automation representation uses snake case independently of the project document encoding.
package struct TilesPendingReviewChoices: Codable, Sendable {
    package let value: TilesReviewChoices

    init(_ value: TilesReviewChoices) { self.value = value }

    private enum CodingKeys: String, CodingKey {
        case analysisIdentity = "analysis_identity", names, unchecked, merged
        case expectedFeeds = "expected_feeds", expectedTiles = "expected_tiles", editedHints = "edited_hints", grids
    }

    package init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_pending_tile_scan")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        var choices = TilesReviewChoices(analysisIdentity: try fields.decodeIfPresent(String.self, forKey: .analysisIdentity) ?? "",
            expectedFeeds: try fields.decodeIfPresent(String.self, forKey: .expectedFeeds) ?? "",
            expectedTiles: try fields.decodeIfPresent(String.self, forKey: .expectedTiles) ?? "")
        choices.names = try fields.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        choices.unchecked = try fields.decodeIfPresent(Set<String>.self, forKey: .unchecked) ?? []
        choices.merged = try fields.decodeIfPresent([String: String].self, forKey: .merged) ?? [:]
        choices.editedHints = try fields.decodeIfPresent(Bool.self, forKey: .editedHints)
        choices.grids = try fields.decodeIfPresent([TilesReviewChoices.GridCorrection].self, forKey: .grids) ?? []
        value = choices
    }

    package func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(value.analysisIdentity, forKey: .analysisIdentity)
        try fields.encode(value.names, forKey: .names)
        try fields.encode(value.unchecked.sorted(), forKey: .unchecked)
        try fields.encode(value.merged, forKey: .merged)
        try fields.encode(value.expectedFeeds, forKey: .expectedFeeds)
        try fields.encode(value.expectedTiles, forKey: .expectedTiles)
        try fields.encodeIfPresent(value.editedHints, forKey: .editedHints)
        try fields.encode(value.grids, forKey: .grids)
    }
}

package struct TilesPendingReviewReport: Encodable, Sendable {
    package let schemaVersion = 1
    package let sourceID: String
    package let reviewID: String
    package let scanSHA256: String
    package let scanState: ParticipantScanResult.State
    package let feedIDs: [String]
    package let choices: TilesPendingReviewChoices
    package let reviewToken: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", sourceID = "source_id", reviewID = "review_id"
        case scanSHA256 = "scan_sha256", scanState = "scan_state", feedIDs = "feed_ids", choices, reviewToken = "review_token"
    }
}

package struct TilesPendingReviewEdit: Encodable, Sendable {
    package let schemaVersion = 1
    package let sourceID: String
    package let operationCount: Int
    package let pendingReview: TilesPendingReviewReport?
    package let projectPath: String?

    package init(sourceID: String, operationCount: Int, pendingReview: TilesPendingReviewReport?, projectPath: String? = nil) {
        self.sourceID = sourceID
        self.operationCount = operationCount
        self.pendingReview = pendingReview
        self.projectPath = projectPath
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", sourceID = "source_id", operationCount = "operation_count"
        case pendingReview = "pending_review", projectPath = "project_path"
    }
}

extension TilesReviewChoices {
    static func feedIDs(in appearances: [ParticipantAppearance]) -> [String: String] {
        var ids: [String: String] = [:]
        for appearance in appearances {
            guard let id = appearance.participantID else { continue }
            if appearance.state == .presentation, let rawID = appearance.id.components(separatedBy: "-appearance-").last {
                ids["share-\(rawID)"] = id
            } else if let rawID = id.components(separatedBy: "-participant-").last, UInt64(rawID) != nil {
                ids["feed-\(rawID)"] = id
            }
        }
        return ids
    }

    package func apply(to project: inout ParticipantProject, sourceID: String, analysisIdentity: String) throws {
        try apply(to: &project, sourceID: sourceID, analysisIdentity: analysisIdentity, reconciledFeedIDs: nil)
    }

    func apply(to project: inout ParticipantProject, sourceID: String, analysisIdentity: String,
               reconciledFeedIDs: [String: String]?) throws {
        guard self.analysisIdentity == analysisIdentity,
              let index = project.sources.firstIndex(where: { $0.sourceID == sourceID }) else { return }
        let source = project.sources[index]
        let feeds = Int(expectedFeeds).flatMap { $0 > 0 ? $0 : nil }
        let tiles = Int(expectedTiles).flatMap { $0 > 0 ? $0 : nil }
        if editedHints == true || feeds != nil || tiles != nil {
            try project.setTileCountHints(sourceID: sourceID, hints: .init(expectedFeeds: feeds, maxVisibleTiles: tiles))
        }
        let ids = reconciledFeedIDs ?? Self.feedIDs(in: source.appearances)
        for grid in grids {
            _ = try project.correctGrid(sourceID: sourceID, range: grid.range, columns: grid.columns, rows: grid.rows)
        }
        for (from, to) in merged.sorted(by: { $0.key < $1.key }) {
            if let removed = ids[from], let surviving = ids[to] {
                _ = try project.mergeFeeds(removed, into: surviving)
            }
        }
        let removed = Set(ids.compactMap { key, id in unchecked.contains(key) ? id : nil })
        // Preserve the detected box when its assignment is unconfirmed.
        for offset in project.sources[index].appearances.indices {
            if let id = project.sources[index].appearances[offset].participantID, removed.contains(id) {
                project.sources[index].appearances[offset].participantID = nil
            }
        }
        let referenced = Set(project.sources.flatMap { $0.appearances.compactMap(\.participantID) + $0.unresolvedParticipantIDs })
        project.people.removeAll { removed.contains($0.id) && !referenced.contains($0.id) }
        let keys = Dictionary(ids.sorted(by: { $0.key < $1.key }).map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for person in project.people.indices {
            if let key = keys[project.people[person].id], let name = names[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                project.people[person].name = name
            }
        }
        try project.validate()
    }
}

extension CutProject {
    package func pendingTileReview(_ selected: String?) throws -> PendingTileReview {
        let source = try pendingTileSourceID(selected)
        guard let review = participants.pendingReviews.first(where: { $0.sourceID == source }) else {
            throw invalidParticipantProject("No pending tile review for this picture source.")
        }
        return review
    }

    package mutating func stagePendingTileChoices(sourceID: String, token: String, choices: TilesReviewChoices) throws -> PendingTileReview {
        let pending = try pendingTileReview(sourceID)
        try pending.checkReviewToken(token)
        let replacement = try pending.replacingChoices(choices)
        var updated = participants
        updated.setPendingReview(replacement)
        try updated.validate()
        participants = updated
        return replacement
    }

    package mutating func discardPendingTileReview(sourceID: String, token: String) throws {
        let review = try pendingTileReview(sourceID)
        try review.checkReviewToken(token)
        participants.pendingReviews.removeAll { $0.id == review.id }
    }

    package func pendingTileSourceID(_ selected: String?) throws -> String {
        let reviews = participants.pendingReviews
        if let selected, reviews.contains(where: { $0.sourceID == selected }) { return selected }
        if selected == nil, reviews.count == 1 { return reviews[0].sourceID }
        guard selected == nil, !reviews.isEmpty else { throw invalidParticipantProject("No pending tile review for this picture source.") }
        throw invalidParticipantProject("Choose a source with a pending tile review: " + reviews.map(\.sourceID).sorted().joined(separator: ", ") + ".")
    }

    package func pendingTileScan(sourceID: String, relativeTo document: URL, cancelled: @escaping () -> Bool = { false }) throws -> (PendingTileReview, ParticipantScanResult) {
        guard let review = participants.pendingReviews.first(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("No pending tile review for this picture source.")
        }
        let recording = try participantRecording(sourceID, relativeTo: document)
        return (review, try review.load(recording: recording, cancelled: cancelled))
    }

    /// Accept the exact scan and the choices bound to this project source in one edit.
    package mutating func acceptPendingTileReview(sourceID: String, relativeTo document: URL, token: String? = nil,
                                                  cancelled: @escaping () -> Bool = { false }) throws {
        let review = try pendingTileReview(sourceID)
        if let token { try review.checkReviewToken(token) }
        let recording = try participantRecording(sourceID, relativeTo: document)
        let scan = try review.load(recording: recording, cancelled: cancelled)
        var updated = self
        try updated.acceptParticipantAnalysis(scan, sourceID: sourceID, relativeTo: document, cancelled: cancelled)
        try review.choices.apply(to: &updated.participants, sourceID: sourceID, analysisIdentity: scan.analysisIdentity)
        updated.participants.pendingReviews.removeAll { $0.id == review.id }
        self = updated
    }

    package mutating func reconcilePendingTileReview(sourceID: String, relativeTo document: URL, token: String,
                                                     cancelled: @escaping () -> Bool = { false }) throws {
        let (pending, scan) = try pendingTileScan(sourceID: sourceID, relativeTo: document, cancelled: cancelled)
        let review = try participantReconciliation(scan, sourceID: sourceID, relativeTo: document, cancelled: cancelled)
        guard try pending.reconciliationToken(for: review, scan: scan) == token else {
            throw invalidParticipantProject("The scan, review choices, or accepted tiles changed. Review the replacement again.")
        }
        var updated = self
        try updated.participants.reconcileAnalysis(scan, sourceID: sourceID, reviewed: review, applying: pending.choices)
        updated.participants.pendingReviews.removeAll { $0.id == pending.id }
        self = updated
    }
}
