import Foundation

extension CutProject {
    package mutating func applyParticipantEdits(_ edits: ParticipantProject, relativeTo document: URL) throws {
        try edits.validate()
        var edits = edits
        let previous = Dictionary(uniqueKeysWithValues: participants.sources.map { ($0.sourceID, $0) })
        for index in edits.sources.indices where edits.sources[index].sourceStamp == nil {
            let id = edits.sources[index].sourceID
            if let saved = previous[id], let stamp = saved.sourceStamp {
                // Editing a roster or mask must not bless a replaced recording.
                edits.sources[index].sourceStamp = stamp
                edits.sources[index].sourceInode = saved.sourceInode
                edits.sources[index].sourceContentSHA256 = saved.sourceContentSHA256
            } else {
                let identity = try SourceIdentity(participantRecording(id, relativeTo: document))
                edits.sources[index].sourceStamp = .init(identity: identity)
                edits.sources[index].sourceInode = identity.inode
            }
        }
        participants = edits
    }

    private func participantRecording(_ id: String, relativeTo document: URL) throws -> URL {
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
                                                   relativeTo projectURL: URL, cancelled: () -> Bool = { false }) throws {
        try validateParticipantScanSource(scan, sourceID: sourceID, relativeTo: projectURL, cancelled: cancelled)
        try participants.acceptAnalysis(scan, sourceID: sourceID)
    }

    func validateParticipantScanSource(_ scan: ParticipantScanResult, sourceID: String,
                                       relativeTo projectURL: URL, cancelled: () -> Bool = { false }) throws {
        if cancelled() { throw CancellationError() }
        let url = AnalysisSidecar.canonicalSource(try participantRecording(sourceID, relativeTo: projectURL))
        let scanned = AnalysisSidecar.canonicalSource(URL(fileURLWithPath: scan.source.file))
        let identity = try SourceIdentity(url)
        guard url == scanned, SceneSourceStamp(identity: identity) == scan.source.stamp,
              scan.source.inode.map({ $0 == identity.inode }) ?? true else {
            throw invalidParticipantProject("The scan describes a different source or the recording has changed.")
        }
        if let digest = scan.source.contentSHA256 {
            let cache = AnalysisSidecar.readsEnabled ? AnalysisSidecar(source: url, identity: identity) : nil
            let verified = try cachedParticipantSourceDigest(identity, in: cache, cancelled: cancelled)
                ?? participantSourceDigest(url, identity: identity, cancelled: cancelled)
            guard verified == digest, identity.isCurrentSnapshot(at: url) else {
                throw invalidParticipantProject("The recording content differs from the supplied participant scan.")
            }
        }
    }
}

extension ParticipantProject {
    public mutating func acceptAnalysis(_ scan: ParticipantScanResult, sourceID: String) throws {
        guard scan.state == .completed || scan.state == .upToDate else {
            throw invalidParticipantProject("Complete or resume the participant scan before accepting its geometry.")
        }
        guard let analysis = scan.analysis, analysis.schemaVersion == 1, analysis.start < analysis.end,
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
        let namePrefix = scan.configuration.feedLayout == .meeting ? "Participant" : "Feed"
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
        let nextTimes = analysis.observations.dropFirst().map(\.time) + [analysis.end]
        for (observation, next) in zip(analysis.observations, nextTimes) {
            guard analysis.start <= observation.time, observation.time < next, next <= analysis.end else {
                throw invalidParticipantProject("The scan has unordered participant observations.")
            }
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
                let rect = region.rect
                // TileTrail reports f32 edges. Accept small rounding at the right and bottom edges.
                let width = rect.x + rect.width <= 1.0000001 ? min(rect.width, 1 - rect.x) : rect.width
                let height = rect.y + rect.height <= 1.0000001 ? min(rect.height, 1 - rect.y) : rect.height
                let bounds = ParticipantBounds(x: rect.x, y: rect.y, width: width, height: height)
                let competingMatch = region.possibleMatches.contains { $0.participantID != region.participantID }
                let participantID = state == .presentation || competingMatch || region.identityUncertain ? nil
                    : region.participantID.flatMap { knownTracks[$0] }
                let id = "\(sourcePrefix)-appearance-\(region.appearanceID)"
                let appearance = ParticipantAppearance(id: id, participantID: participantID,
                    range: .init(from: observation.time, to: end), bounds: bounds, role: role, state: state)
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
        revised.sources.append(.init(sourceID: sourceID, analysisIdentity: scan.analysisIdentity,
            sourceStamp: scan.source.stamp, sourceInode: scan.source.inode,
            sourceContentSHA256: scan.source.contentSHA256,
            feedLayout: scan.configuration.feedLayout,
            appearances: tracks.keys.sorted().flatMap { tracks[$0] ?? [] }, coverage: coverage))
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
