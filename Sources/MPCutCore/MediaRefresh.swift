import Foundation

public enum MediaRefreshVerification: Sendable {
    case stamp
    case deep
}

public enum MediaRefreshState: String, Codable, Sendable {
    case unchanged, refreshed, offline
}

public struct MediaRefreshReferenceIssue: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case offline, rangeOutsideMedia = "range_outside_media", trackNeedsReview = "track_needs_review"
        case participantGeometryNeedsReview = "participant_geometry_needs_review"
    }

    public let id: String
    public let reason: Reason
}

public struct MediaRefreshResult: Encodable, Sendable {
    public let source: URL
    public let state: MediaRefreshState
    public let media: MediaInfo?
    public let scenesPreserved: Bool
    public let preservedAudioStreams: Set<Int>
    public let reviewStreams: Set<Int>
    public let displayChanged: Bool
    public let persistenceError: String?
    public var pictureNeedsReview: Bool { referenceEvidence?.pictureNeedsReview ?? false }
    public internal(set) var referenceIssues: [MediaRefreshReferenceIssue] = []
    var referenceEvidence: MediaRefreshEvidence?

    enum CodingKeys: String, CodingKey {
        case source, state, scenesPreserved, preservedAudioStreams, reviewStreams, displayChanged, persistenceError
        case referenceIssues, pictureNeedsReview
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(state, forKey: .state)
        try values.encode(scenesPreserved, forKey: .scenesPreserved)
        try values.encode(preservedAudioStreams.sorted(), forKey: .preservedAudioStreams)
        try values.encode(reviewStreams.sorted(), forKey: .reviewStreams)
        try values.encode(displayChanged, forKey: .displayChanged)
        try values.encodeIfPresent(persistenceError, forKey: .persistenceError)
        try values.encode(referenceIssues, forKey: .referenceIssues)
        try values.encode(pictureNeedsReview, forKey: .pictureNeedsReview)
    }
}

public enum MediaRefresh {
    /// Refreshes one source and verifies all dependencies before carrying forward existing analysis.
    public static func check(_ source: URL, previous: MediaInfo? = nil,
                             verification: MediaRefreshVerification = .stamp, persist: Bool = true,
                             exclusions: Set<URL> = [], progress: ((Double) -> Void)? = nil,
                             cancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> MediaRefreshResult {
        try checkCancellation(cancelled)
        guard source.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local media file.") }
        let url = source.standardizedFileURL
        return try check(url, identity: try? SourceIdentity(url), previous: previous, verification: verification,
                         persist: persist, exclusions: exclusions, progress: progress, cancelled: cancelled)
    }

    package static func check(_ source: URL, identity: SourceIdentity?, previous: MediaInfo?,
                              verification: MediaRefreshVerification, persist: Bool, exclusions: Set<URL>,
                              progress: ((Double) -> Void)?, cancelled: @escaping () -> Bool) throws -> MediaRefreshResult {
        try checkCancellation(cancelled)
        guard let identity else {
            progress?(1)
            return MediaRefreshResult(source: source, state: .offline, media: nil, scenesPreserved: false,
                                      preservedAudioStreams: [], reviewStreams: [], displayChanged: true,
                                      persistenceError: nil)
        }
        let sidecar = AnalysisSidecar(source: source, identity: identity)
        let readSidecar = persist && AnalysisSidecar.readsEnabled &&
            !AnalysisSidecar.isExcluded(source, in: exclusions.union(AnalysisSidecar.excludedSources))
        let currentCache = readSidecar && (previous == nil || verification == .deep)
            ? sidecar.currentGenerationEvidence() : (current: false, evidence: nil)
        let cacheEvidence = MediaRefreshEvidence.decode(currentCache.evidence)
        let stampMatches = previous.map { identity.matches(saved: $0.identity) } ?? currentCache.current
        let snapshotMatches = previous.map { $0.identity.matchesSnapshot(identity) } ?? stampMatches
        func unchanged(_ evidence: MediaRefreshEvidence?, rebound: MediaInfo? = nil) -> MediaRefreshResult {
            progress?(1)
            let audio = evidence?.streams.enumerated().compactMap { index, stream in stream.kind == "audio" ? index : nil }
                ?? previous?.streams.filter { $0.kind == "audio" }.map(\.index) ?? []
            return MediaRefreshResult(source: source, state: rebound == nil ? .unchanged : .refreshed, media: rebound,
                                      scenesPreserved: evidence.map { $0.videoIndex >= 0 } ?? previous?.hasVideo ?? false,
                                      preservedAudioStreams: Set(audio), reviewStreams: Set(evidence?.reviewStreams ?? []),
                                      displayChanged: false, persistenceError: nil, referenceEvidence: evidence)
        }
        if verification == .stamp {
            if snapshotMatches, previous != nil || cacheEvidence != nil {
                try checkCancellation(cancelled)
                return unchanged(previous?.refreshEvidence ?? cacheEvidence)
            }
            if let previous, stampMatches, previous.identity.device != identity.device, previous.hasFullEditIndex {
                // A remount can change the device number of the same stamped
                // media. Rebind pinned readers to the new live snapshot.
                return unchanged(previous.refreshEvidence,
                                 rebound: previous.withRefreshEvidence(previous.refreshEvidence, at: source, identity: identity))
            }
        }

        let snapshot = readSidecar ? sidecar.previousGenerationSnapshot() : nil
        let persistedEvidence = MediaRefreshEvidence.decode(snapshot?.evidence)
        let previousEvidence = previous?.refreshEvidence ?? persistedEvidence.flatMap { saved in
            guard let previous else { return saved }
            return previous.identity.matches(saved: saved.identity) ? saved : nil
        }
        let probeProgress = progress.map { report in { (fraction: Double) in report(fraction * 0.95) } }
        let media = try Probe.read(source, forcePayload: true, expectedIdentity: identity,
                                   progress: probeProgress, cancelled: cancelled)
        guard var evidence = media.refreshEvidence else {
            throw CutError(code: "probe_failed", message: "No stream evidence was collected for the refreshed source.")
        }
        if snapshotMatches, let previousEvidence, evidence.verifiesSameFileContents(as: previousEvidence) {
            guard media.identity.isCurrentSnapshot(at: source) else {
                throw CutError(code: "source_changed", message: "The source changed during deep verification.")
            }
            return unchanged(previousEvidence)
        }
        var comparison = previousEvidence.map { evidence.compare(to: $0) }
            ?? MediaRefreshEvidence.Comparison(review: Set(previous?.streams
                .filter { $0.kind == "audio" || $0.index == previous?.videoStream?.index }
                .map(\.index) ?? []))
        if previousEvidence == nil, let oldVideo = previous?.videoStream {
            comparison.pictureNeedsReview = comparison.review.contains(oldVideo.index)
            if let newVideo = media.videoStream, oldVideo.index != newVideo.index {
                comparison.review.insert(newVideo.index)
            }
        }
        evidence.reviewStreams = comparison.review.sorted()
        evidence.pictureNeedsReview = comparison.pictureNeedsReview
        var persistenceError: String?
        if readSidecar && AnalysisSidecar.automaticWritesEnabled {
            do {
                let persistedComparison = persistedEvidence.map { evidence.compare(to: $0) }
                    ?? MediaRefreshEvidence.Comparison()
                var persisted = evidence
                persisted.reviewStreams = comparison.review.union(persistedComparison.review).sorted()
                persisted.pictureNeedsReview = comparison.pictureNeedsReview || persistedComparison.pictureNeedsReview
                let keep = persistedComparison.preservedSectionKeys(snapshot?.keys ?? [])
                let indexingProgress = progress.map { report in { (fraction: Double) in report(0.95 + 0.04 * fraction) } }
                let sections = media.hasFullEditIndex
                    ? try AnalysisSidecar.indexSections(for: media, progress: indexingProgress, cancelled: cancelled)
                    : [:]
                // A new evidence record for a legacy same-stamp file also
                // invalidates unverified analysis from the old generation.
                let changedEvidence = persistedEvidence.map { !evidence.verifiesSameFileContents(as: $0) } ?? true
                let force = changedEvidence && sidecar.matchesCurrentGeneration()
                try sidecar.refreshGeneration(evidence: persisted.encoded(), preserving: keep,
                                              expectedEvidence: snapshot?.evidence, force: force,
                                              preservingScenes: persistedComparison.scenes,
                                              preservingThresholdStreams: persistedComparison.verifiedThresholdStreams,
                                              sections: sections,
                                              cancelled: cancelled)
            } catch let error as CutError where error.code == "cancelled" || error.code == "source_changed" {
                throw error
            } catch {
                persistenceError = (error as? CutError)?.message ?? error.localizedDescription
            }
        }
        try checkCancellation(cancelled)
        guard media.identity.isCurrentSnapshot(at: source) else {
            throw CutError(code: "source_changed", message: "The source changed before the refreshed index could be published.")
        }
        progress?(1)
        return MediaRefreshResult(source: source, state: .refreshed, media: media.withRefreshEvidence(evidence),
                                  scenesPreserved: comparison.scenes, preservedAudioStreams: comparison.audio,
                                  reviewStreams: comparison.review, displayChanged: comparison.displayChanged,
                                  persistenceError: persistenceError, referenceEvidence: evidence)
    }

    static func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CutError(code: "cancelled", message: "Media refresh was cancelled.") }
    }
}

extension SceneReport {
    /// The caller has verified the new generation against the report's picture inputs.
    package func forRefreshedMedia(_ media: MediaInfo) -> SceneReport {
        SceneReport(file: media.url.path, sourceStamp: SceneSourceStamp(media: media), timeBase: timeBase,
                    origin: origin, duration: duration, scenes: scenes, viewCount: viewCount, views: views,
                    syntheticLeading: syntheticLeading)
    }
}
