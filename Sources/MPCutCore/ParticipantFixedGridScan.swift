import Foundation

extension ParticipantAnalysis {
    static func fixedGridScan(_ url: URL, columns: UInt32, rows: UInt32, options: ParticipantScanOptions,
                              partial: ParticipantScanResult?, cancelled: @escaping () -> Bool,
                              progress: ((RationalTime) -> Void)?) throws -> ParticipantScanResult {
        if cancelled() { throw CancellationError() }
        guard options.backend != .gpuRequired else {
            throw CutError(code: "participant_gpu_unavailable",
                           message: "GPU-required grid analysis needs a TileTrail build with native feed layouts.")
        }
        let file = AnalysisSidecar.canonicalSource(url)
        let identity = try SourceIdentity(file)
        let media = try SceneAnalysis.inspectSceneClock(file, identity: identity, cancelled: cancelled)
        guard let video = media.videoStream, media.duration > .zero else {
            throw CutError(code: "no_video", message: "An even grid requires a video track.")
        }
        var source = try ParticipantScanSource(file: file.path, media: media, video: video)
        let configuration = ParticipantScanConfiguration(options)
        let section = "participant_content_sha256.v1."
        let cache = options.useSidecar && AnalysisSidecar.readsEnabled
            && !AnalysisSidecar.isExcluded(file, in: AnalysisSidecar.excludedSources)
            ? AnalysisSidecar(source: file, identity: identity) : nil
        let digest = try cachedParticipantSourceDigest(identity, in: cache, cancelled: cancelled)
            ?? participantSourceDigest(file, identity: identity, cancelled: cancelled)
        source.contentSHA256 = digest
        let fingerprint = "fixed-grid-v1-\(columns)x\(rows)-\(digest)"
        if let partial {
            guard partial.analysisIdentity == fingerprint, partial.configuration == configuration,
                  partial.state == .paused || partial.state == .incomplete else {
                throw CutError(code: "participant_resume_mismatch",
                               message: "The partial participant scan does not match this source and scan configuration.")
            }
        }

        let regions = (0..<(columns * rows)).map { cell in
            let x = Double(cell % columns) / Double(columns)
            let y = Double(cell / columns) / Double(rows)
            let width = Double(cell % columns + 1) / Double(columns) - x
            let height = Double(cell / columns + 1) / Double(rows) - y
            let id = UInt64(cell + 1)
            return ParticipantRegion(appearanceID: id, participantID: id,
                rect: .init(x: x, y: y, width: width, height: height),
                kind: .video, role: .primary, confidence: 1, identityConfidence: 1,
                identityUncertain: false, possibleMatches: [])
        }
        let ids = regions.map(\.appearanceID)
        let analysis = ParticipantTrackingResult(schemaVersion: 1, start: .zero, end: source.duration,
            sampling: options.sampling.detectorSampling,
            observations: [.init(time: .zero, display: source.transform, confidence: 1, regions: regions)],
            tracks: ids.map { .init(id: $0, appearanceIDs: [$0]) },
            appearances: ids.map { .init(id: $0, participantID: $0, start: .zero, end: source.duration) },
            events: [], coverage: [.init(start: .zero, end: source.duration, status: .inferred)],
            diagnostics: [], resumeAt: nil)
        if cancelled() { throw CancellationError() }
        guard identity.isCurrentSnapshot(at: file) else {
            throw CutError(code: "source_changed", message: "The source changed while creating the even grid.")
        }
        cache?.saveAutomatically([identity.participantDigestSection: Data(digest.utf8)],
                                 retainingLatest: [section: 2], cancelled: cancelled)
        let sceneReport = options.includeScenes ? try SceneAnalysis.scan(media, useSidecar: options.useSidecar, cancelled: cancelled) : nil
        guard identity.isCurrentSnapshot(at: file) else {
            throw CutError(code: "source_changed", message: "The source changed while creating the even grid.")
        }
        progress?(source.duration)
        return ParticipantScanResult(state: .completed, source: source, configuration: configuration, analysis: analysis,
                                     sceneReport: sceneReport, analysisIdentity: fingerprint)
    }
}
