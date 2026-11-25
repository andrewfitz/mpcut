import Foundation

extension CutProject {
    package mutating func applyParticipantEdits(_ edits: ParticipantProject, relativeTo document: URL) throws {
        try edits.validate()
        var edits = edits
        let previous = Dictionary(uniqueKeysWithValues: participants.sources.map { ($0.sourceID, $0) })
        let roster = Set(edits.people.map(\.id))
        for index in edits.sources.indices {
            let id = edits.sources[index].sourceID
            if let saved = previous[id] {
                if edits.sources[index].appearances != saved.appearances {
                    edits.sources[index].recordPrivacyHistory(previousAppearances: saved.appearances)
                }
                let combinedHistory = Set(edits.sources[index].historicalParticipantIDs ?? [])
                    .union(saved.historicalParticipantIDs ?? [])
                edits.sources[index].historicalParticipantIDs = combinedHistory.isEmpty ? nil : combinedHistory.sorted()
                edits.sources[index].unresolvedParticipantIDs = edits.sources[index].unresolvedParticipantIDs.filter(roster.contains)
                if edits.sources[index].analysisIdentity != saved.analysisIdentity
                    || edits.sources[index].coverage != saved.coverage
                    || edits.sources[index].appearances != saved.appearances
                    || edits.sources[index].unresolvedParticipantIDs != saved.unresolvedParticipantIDs {
                    edits.sources[index].confirmations = nil
                }
                if edits.sources[index].sourceStamp == nil, let stamp = saved.sourceStamp {
                    // Editing a roster or mask must not bless a replaced recording.
                    edits.sources[index].sourceStamp = stamp
                    edits.sources[index].sourceInode = saved.sourceInode
                    edits.sources[index].sourceContentSHA256 = saved.sourceContentSHA256
                }
            }
            if edits.sources[index].sourceStamp == nil {
                let identity = try SourceIdentity(participantRecording(id, relativeTo: document))
                edits.sources[index].sourceStamp = .init(identity: identity)
                edits.sources[index].sourceInode = identity.inode
            }
        }
        let retainedIDs = Set(edits.sources.map(\.sourceID))
        let treatedIDs = Set(edits.effectiveRedactions.map(\.participantID))
        for var removed in participants.sources where !retainedIDs.contains(removed.sourceID) {
            let unresolved = removed.appearances.contains(where: \.hasUnresolvedIdentity)
            let scoped = Set(removed.appearances.compactMap(\.participantID))
                .union(removed.historicalParticipantIDs ?? []).union(removed.unresolvedParticipantIDs)
                .union(unresolved ? treatedIDs : [])
                .intersection(roster)
            guard !scoped.isEmpty, (try? participantRecording(removed.sourceID, relativeTo: document)) != nil else { continue }
            removed.appearances = []
            removed.coverage = []
            removed.confirmations = nil
            removed.unresolvedParticipantIDs = scoped.sorted()
            edits.sources.append(removed)
        }
        try edits.validate()
        participants = edits
    }

    func participantRecording(_ id: String, relativeTo document: URL) throws -> URL {
        let path: String?
        switch self {
        case .multicam(let project):
            path = project.pictureSources.first { $0.id == id }?.file
        case .sequence, .stillSequence:
            path = sequenceClips?.first { $0.file == id }?.file
        }
        guard let path else { throw invalidParticipantProject("Unknown picture source ‘\(id)’.") }
        return try Self.checkedMediaURL(path, relativeTo: document)
    }

    /// Accept a detector result only when it still describes this project's media.
    public mutating func acceptParticipantAnalysis(_ scan: ParticipantScanResult, sourceID: String,
                                                   relativeTo projectURL: URL, promoteScreenShares: Bool = true,
                                                   cancelled: @escaping () -> Bool = { false }) throws {
        let validated = try validateParticipantScanSource(scan, sourceID: sourceID, relativeTo: projectURL, cancelled: cancelled)
        try participants.acceptAnalysis(validated, sourceID: sourceID, promoteScreenShares: promoteScreenShares)
    }

    package func validateParticipantScanSource(_ scan: ParticipantScanResult, sourceID: String,
                                       relativeTo projectURL: URL, cancelled: @escaping () -> Bool = { false }) throws -> ParticipantScanResult {
        if cancelled() { throw CancellationError() }
        let url = AnalysisSidecar.canonicalSource(try participantRecording(sourceID, relativeTo: projectURL))
        let scanned = AnalysisSidecar.canonicalSource(URL(fileURLWithPath: scan.source.file))
        let identity = try SourceIdentity(url)
        let external = scan.source.producer == "tiletrail"
        guard scan.source.producer == nil || external,
              !external || scan.source.contentSHA256.map(validParticipantSourceDigest) == true,
              external || url == scanned,
              SceneSourceStamp(identity: identity) == scan.source.stamp,
              scan.source.inode.map({ $0 == identity.inode }) ?? true else {
            throw invalidParticipantProject("The scan describes a different source or the recording has changed.")
        }
        if external {
            let media = try SceneAnalysis.inspectSceneClock(url, identity: identity, cancelled: cancelled)
            guard let video = media.videoStream else {
                throw invalidParticipantProject("The recording has no video track matching the scan.")
            }
            let current = try ParticipantScanSource(file: url.path, media: media, video: video)
            guard current.stream == scan.source.stream, current.origin == scan.source.origin,
                  current.timeBase == scan.source.timeBase, current.duration == scan.source.duration,
                  current.transform == scan.source.transform else {
                throw invalidParticipantProject("The recording clock or display transform differs from the supplied scan.")
            }
        }
        if let digest = scan.source.contentSHA256 {
            let cache = AnalysisSidecar.readsEnabled ? AnalysisSidecar(source: url, identity: identity) : nil
            let verified = try cachedParticipantSourceDigest(identity, in: cache, cancelled: cancelled)
                ?? participantSourceDigest(url, identity: identity, cancelled: cancelled)
            guard verified == digest, identity.isCurrentSnapshot(at: url) else {
                throw invalidParticipantProject("The recording content differs from the supplied participant scan.")
            }
        }
        guard identity.isCurrentSnapshot(at: url) else {
            throw invalidParticipantProject("The recording changed while checking the supplied scan.")
        }
        var source = scan.source
        source.inode = identity.inode
        return .init(state: scan.state, source: source, configuration: scan.configuration, analysis: scan.analysis,
                     sceneReport: scan.sceneReport, analysisIdentity: scan.analysisIdentity, countHints: scan.countHints)
    }
}

extension ParticipantProject {
    public mutating func acceptAnalysis(_ scan: ParticipantScanResult, sourceID: String,
                                        promoteScreenShares: Bool = true) throws {
        guard scan.state == .completed || scan.state == .upToDate else {
            throw invalidParticipantProject("Complete or resume the participant scan before accepting its geometry.")
        }
        guard let analysis = scan.analysis, analysis.schemaVersion == 1,
              analysis.start == .zero, analysis.end == scan.source.duration, analysis.start < analysis.end,
              analysis.resumeAt == nil,
              analysis.sampling == scan.configuration.sampling.detectorSampling, !analysis.observations.isEmpty else {
            throw invalidParticipantProject("The scan has no supported participant observations.")
        }
        if let accepted = sources.first(where: { $0.sourceID == sourceID }) {
            guard accepted.analysisIdentity == scan.analysisIdentity,
                  (accepted.feedLayout ?? .meeting) == scan.configuration.feedLayout,
                  accepted.sourceContentSHA256 == nil || scan.source.contentSHA256 == nil
                    || accepted.sourceContentSHA256 == scan.source.contentSHA256 else {
                throw invalidParticipantProject("Reconcile the new scan with this source's accepted geometry before replacing it.")
            }
            return
        }
        var knownTracks: [UInt64: String] = [:]
        var acceptedPeople: [ParticipantPerson] = []
        let sourcePrefix = UUID().uuidString.lowercased()
        let namePrefix = scan.configuration.feedLayout.isMeeting ? "Participant" : "Feed"
        for track in analysis.tracks {
            let participantID = "\(sourcePrefix)-participant-\(track.id)"
            guard knownTracks.updateValue(participantID, forKey: track.id) == nil else {
                throw invalidParticipantProject("The scan repeats a participant track ID.")
            }
            acceptedPeople.append(.init(id: participantID, name: "\(namePrefix) \(track.id)"))
        }
        var detectedEnds: [UInt64: RationalTime] = [:]
        for appearance in analysis.appearances {
            guard detectedEnds.updateValue(appearance.end, forKey: appearance.id) == nil else {
                throw invalidParticipantProject("The scan repeats an appearance ID.")
            }
        }
        var tracks: [UInt64: [ParticipantAppearance]] = [:]
        var screenShares: [UInt64: String] = [:]
        var previousRegionByTrack: [UInt64: (tileID: String, time: RationalTime)] = [:]
        var reviewEvents: [ParticipantTileScanEvent] = []
        var uncertainTilesWithCandidates = Set<UInt64>()
        let eventTimes = Dictionary(grouping: analysis.events.filter {
            analysis.start <= $0.time && $0.time < analysis.end
        }, by: \.time)
        func tileID(_ id: UInt64) -> String? {
            detectedEnds[id].map { _ in "\(sourcePrefix)-appearance-\(id)" }
        }
        let nextTimes = analysis.observations.dropFirst().map(\.time) + [analysis.end]
        for (observation, next) in zip(analysis.observations, nextTimes) {
            guard analysis.start <= observation.time, observation.time < next, next <= analysis.end else {
                throw invalidParticipantProject("The scan has unordered participant observations.")
            }
            if scan.source.producer == "tiletrail", observation.display != scan.source.transform {
                throw invalidParticipantProject("A scan observation uses a different display transform from its recording.")
            }
            let events = eventTimes[observation.time] ?? []
            let ambiguous = observation.regions.filter(observation.needsIdentityReview)
            func candidates(for region: ParticipantRegion) -> [ParticipantTileScanEvent.Candidate] {
                let competing = Set(observation.competingMatches(for: region).map(\.participantID))
                return region.possibleMatches.compactMap { match in
                    guard match.participantID == region.participantID || competing.contains(match.participantID),
                          let id = knownTracks[match.participantID], match.confidence.isFinite else { return nil }
                    let previous = previousRegionByTrack[match.participantID]
                    return .init(feedID: id, confidence: match.confidence,
                                 precedingTileID: previous?.tileID, precedingTime: previous?.time)
                }
            }
            for event in events {
                let region = ambiguous.first { $0.appearanceID == event.appearanceID }
                let matches = region.map(candidates(for:)) ?? []
                reviewEvents.append(.init(time: event.time, kind: event.kind, uncertain: event.uncertain || region != nil,
                    tileID: tileID(event.appearanceID), feedID: knownTracks[event.participantID],
                    candidates: matches.isEmpty ? nil : matches))
            }
            let withCandidates = ambiguous.filter { !$0.possibleMatches.isEmpty }
            let eventTiles = Set(events.map(\.appearanceID))
            for region in withCandidates where !uncertainTilesWithCandidates.contains(region.appearanceID)
                && !eventTiles.contains(region.appearanceID) {
                let matches = candidates(for: region)
                if !matches.isEmpty {
                    reviewEvents.append(.init(time: observation.time, kind: .enter, uncertain: true,
                        tileID: tileID(region.appearanceID), feedID: region.participantID.flatMap { knownTracks[$0] },
                        candidates: matches, identityEvidenceOnly: true))
                }
            }
            uncertainTilesWithCandidates = Set(withCandidates.map(\.appearanceID))
            let hasThumbnails = observation.regions.contains { $0.role == .thumbnail }
            for region in observation.regions {
                guard let detectedEnd = detectedEnds[region.appearanceID] else {
                    throw invalidParticipantProject("The scan refers to an unknown appearance.")
                }
                let end = min(next, detectedEnd)
                guard observation.time < end else { continue }
                let state: ParticipantAppearance.State
                switch region.kind {
                case .video: state = .video
                case .cameraOff: state = .cameraOff
                case .screenShare: state = .presentation
                case .unknown: state = .unknown
                }
                let role: ParticipantAppearance.Role = state == .presentation ? .presentation
                    : region.role == .thumbnail ? .thumbnail
                    : hasThumbnails ? .stage : .tile
                let bounds = region.rect.bounds
                let competingMatch = !observation.competingMatches(for: region).isEmpty
                let participantID: String?
                if state == .presentation, promoteScreenShares {
                    if let existing = screenShares[region.appearanceID] {
                        participantID = existing
                    } else {
                        let feedID = "\(sourcePrefix)-screen-share-\(region.appearanceID)"
                        let name = screenShares.isEmpty ? "Screen Share" : "Screen Share \(screenShares.count + 1)"
                        screenShares[region.appearanceID] = feedID
                        acceptedPeople.append(.init(id: feedID, name: name))
                        participantID = feedID
                    }
                } else {
                    participantID = state == .presentation || competingMatch || region.identityUncertain ? nil
                        : region.participantID.flatMap { knownTracks[$0] }
                }
                let id = "\(sourcePrefix)-appearance-\(region.appearanceID)"
                let appearance = ParticipantAppearance(id: id, participantID: participantID,
                    range: .init(from: observation.time, to: end), bounds: bounds, role: role, state: state)
                if let track = region.participantID, participantID != nil {
                    previousRegionByTrack[track] = (id, observation.time)
                }
                let index = tracks[region.appearanceID, default: []].count - 1
                if let last = tracks[region.appearanceID]?.last, last.range.to == appearance.range.from,
                   last.bounds == appearance.bounds, last.participantID == appearance.participantID,
                   last.role == appearance.role, last.state == appearance.state {
                    tracks[region.appearanceID]![index].range.to = end
                } else {
                    tracks[region.appearanceID, default: []].append(appearance)
                }
            }
        }
        let observedTimes = Set(reviewEvents.map(\.time))
        for (time, events) in eventTimes where !observedTimes.contains(time) {
            reviewEvents += events.map { event in
                .init(time: time, kind: event.kind, uncertain: event.uncertain, tileID: tileID(event.appearanceID),
                      feedID: knownTracks[event.participantID], candidates: nil)
            }
        }
        reviewEvents.sort { $0.time < $1.time }
        var coverage: [ParticipantCoverage] = []
        for item in analysis.coverage {
            guard analysis.start <= item.start, item.start < item.end, item.end <= analysis.end else {
                throw invalidParticipantProject("The scan has a coverage interval outside its source extent.")
            }
            let state: ParticipantCoverageState
            switch item.status {
            case .observed: state = analysis.sampling == .everyFrame ? .verified : .inferred
            case .inferred: state = .inferred
            case .unknown, .incomplete: state = .unknown
            }
            if let last = coverage.last, last.state == state, last.range.to == item.start {
                coverage[coverage.count - 1].range.to = item.end
            } else {
                coverage.append(.init(range: .init(from: item.start, to: item.end), state: state))
            }
        }
        var revised = self
        revised.people.append(contentsOf: acceptedPeople)
        var geometry = ParticipantSourceGeometry(sourceID: sourceID, analysisIdentity: scan.analysisIdentity,
            sourceStamp: scan.source.stamp, sourceInode: scan.source.inode,
            sourceContentSHA256: scan.source.contentSHA256,
            feedLayout: scan.configuration.feedLayout,
            appearances: tracks.keys.sorted().flatMap { tracks[$0] ?? [] }, coverage: coverage,
            scanEvents: reviewEvents, countHints: promoteScreenShares ? scan.countHints : nil)
        let capacityRanges = analysis.layoutCapacityRanges
        if !capacityRanges.isEmpty { geometry.layoutCapacityRanges = capacityRanges }
        revised.sources.append(geometry)
        try revised.validate()
        self = revised
    }

    public func needsReconciliation(sourceID: String, mediaURL: URL) -> Bool {
        guard sources.contains(where: { $0.sourceID == sourceID && $0.sourceStamp != nil }) else { return false }
        guard let current = try? SourceIdentity(AnalysisSidecar.canonicalSource(mediaURL)) else { return true }
        return needsReconciliation(sourceID: sourceID, identity: current)
    }

    package func needsReconciliation(sourceID: String, identity: SourceIdentity) -> Bool {
        guard let accepted = sources.first(where: { $0.sourceID == sourceID }),
              let stamp = accepted.sourceStamp else { return false }
        return stamp != SceneSourceStamp(identity: identity)
            || accepted.sourceInode.map { $0 != identity.inode } == true
    }
}


extension ParticipantScanResult {
    /// A saved review may move with its recording. Verify the current
    /// recording identity and clock before letting its saved boxes be reviewed again.
    package func rebindingPendingReview(to recording: URL, cancelled: @escaping () -> Bool = { false }) throws -> Self {
        if cancelled() { throw CancellationError() }
        let url = AnalysisSidecar.canonicalSource(recording)
        let identity = try SourceIdentity(url)
        let sameFile = source.inode == identity.inode && source.stamp == SceneSourceStamp(identity: identity)
        let invalid = CutError(code: "stale_scan", message: "The recording no longer matches the pending tile scan. Find tiles again.")
        if let digest = source.contentSHA256 {
            let cache = AnalysisSidecar.readsEnabled ? AnalysisSidecar(source: url, identity: identity) : nil
            guard validParticipantSourceDigest(digest) else { throw invalid }
            let currentDigest = try cachedParticipantSourceDigest(identity, in: cache, cancelled: cancelled)
                ?? participantSourceDigest(url, identity: identity, cancelled: cancelled)
            guard currentDigest == digest, identity.isCurrentSnapshot(at: url) else { throw invalid }
        } else if !sameFile {
            throw invalid
        }
        if sameFile, url.path == source.file, identity.isCurrentSnapshot(at: url) { return self }
        let media = try SceneAnalysis.inspectSceneClock(url, identity: identity, cancelled: cancelled)
        guard let video = media.videoStream else { throw invalid }
        var current = try ParticipantScanSource(file: url.path, media: media, video: video)
        guard current.stream == source.stream, current.origin == source.origin, current.timeBase == source.timeBase,
              current.duration == source.duration, current.transform == source.transform,
              identity.isCurrentSnapshot(at: url) else { throw invalid }
        current.producer = source.producer
        current.contentSHA256 = source.contentSHA256
        return .init(state: state, source: current, configuration: configuration, analysis: analysis,
                     sceneReport: sceneReport?.forSource(url), analysisIdentity: analysisIdentity, countHints: countHints)
    }
}
