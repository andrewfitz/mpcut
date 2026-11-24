import CFFmpeg
import CryptoKit
import Foundation
import MediaProbe

#if canImport(CTileTrail)
import CTileTrail
#endif

/// Scan percentage measures traversal of the source recording. Successful verification
/// and finalization release the last percent. Callbacks run on the scan's worker thread.
public struct ParticipantScanProgress: Sendable {
    public enum Phase: String, Sendable {
        case preparing, checkingCache = "checking_cache", scanning, finalizing
        case completed, upToDate = "up_to_date", paused, incomplete, failed
    }

    public let phase: Phase
    public let percent: Int
    public let time: RationalTime
}

private final class ParticipantScanReporter {
    let notify: (ParticipantScanProgress) -> Void
    var duration: RationalTime = .zero
    private var last: ParticipantScanProgress?

    init(_ notify: @escaping (ParticipantScanProgress) -> Void) { self.notify = notify }

    func send(_ phase: ParticipantScanProgress.Phase, at position: RationalTime? = nil) {
        let time = max(position ?? .zero, last?.time ?? .zero)
        let percent = phase == .completed || phase == .upToDate ? 100 : min(99, time.wholePercent(of: duration))
        guard phase != last?.phase || percent != last?.percent else { return }
        let update = ParticipantScanProgress(phase: phase, percent: percent, time: time)
        last = update
        notify(update)
    }
}

public enum ParticipantAnalysis {
    public static var isAvailable: Bool {
        #if canImport(CTileTrail)
        tiletrail_abi_version() == TILETRAIL_ABI_VERSION
        #else
        false
        #endif
    }

    public static var supportsFeedLayouts: Bool {
        #if canImport(CTileTrail)
        isAvailable && mpcut_tiletrail_has_feed_layouts() != 0
        #else
        false
        #endif
    }

    public static var supportsGalleryHint: Bool {
        #if canImport(CTileTrail)
        isAvailable && mpcut_tiletrail_has_gallery_hint() != 0
        #else
        false
        #endif
    }

    static var supportsCheckpoints: Bool {
        #if canImport(CTileTrail)
        mpcut_tiletrail_has_checkpoints() != 0
        #else
        false
        #endif
    }

    /// Retire the journal after the caller has committed the scan or review
    /// project. A cancelled write can continue using the same journal.
    package static func discardCheckpoint(for scan: ParticipantScanResult, directory: URL?) {
        #if canImport(CTileTrail)
        guard scan.state != .paused,
              let directory, FileManager.default.fileExists(atPath: directory.path),
              let identity = try? SourceIdentity(URL(fileURLWithPath: scan.source.file)),
              let journal = try? ParticipantScanCheckpoint(directory: directory, fingerprint: scan.analysisIdentity,
                                                           identity: identity, duration: scan.source.duration) else { return }
        journal.removeCommittedChunks()
        #endif
    }

    /// Adaptive scans skip unchanged stretches only when TileTrail can refuse a
    /// keyframe that differs. Without that, they analyze every frame.
    public static var supportsAdaptiveSampling: Bool {
        #if canImport(CTileTrail)
        isAvailable && mpcut_tiletrail_has_coarse_push() != 0
        #else
        false
        #endif
    }

    public static func scan(_ url: URL, options: ParticipantScanOptions = .init(),
                            resuming partial: ParticipantScanResult? = nil,
                            cancelled: @escaping () -> Bool = { Task.isCancelled },
                            progress: ((RationalTime) -> Void)? = nil) throws -> ParticipantScanResult {
        try performScan(url, options: options, resuming: partial, cancelled: cancelled, progress: progress, reporter: nil)
    }

    public static func scanWithStatus(_ url: URL, options: ParticipantScanOptions = .init(),
                                      resuming partial: ParticipantScanResult? = nil,
                                      cancelled: @escaping () -> Bool = { Task.isCancelled },
                                      onStatus: @escaping (ParticipantScanProgress) -> Void) throws -> ParticipantScanResult {
        let reporter = ParticipantScanReporter(onStatus)
        reporter.send(.preparing)
        do {
            let result = try performScan(url, options: options, resuming: partial, cancelled: cancelled,
                                         progress: nil, reporter: reporter)
            switch result.state {
            case .completed: reporter.send(.completed, at: result.source.duration)
            case .upToDate: reporter.send(.upToDate, at: result.source.duration)
            case .paused: reporter.send(.paused, at: result.analysis?.resumeAt)
            case .incomplete: reporter.send(.incomplete)
            }
            return result
        } catch {
            let interrupted = error is CancellationError || (error as? CutError)?.code == "cancelled"
            reporter.send(interrupted ? .paused : .failed)
            throw error
        }
    }

    private static func performScan(_ url: URL, options: ParticipantScanOptions,
                                    resuming partial: ParticipantScanResult?, cancelled: @escaping () -> Bool,
                                    progress: ((RationalTime) -> Void)?, reporter: ParticipantScanReporter?) throws -> ParticipantScanResult {
        guard options.feedLayout.isValid else {
            throw CutError(code: "invalid_feed_layout", message: "Choose a grid with one to 64 feeds.")
        }
        guard url.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local video file.") }
        if case .fixed(let columns, let rows) = options.feedLayout, !supportsFeedLayouts {
            return try fixedGridScan(url, columns: columns, rows: rows, options: options, partial: partial,
                                     cancelled: cancelled, progress: progress)
        }
        #if canImport(CTileTrail)
        guard isAvailable else { throw unavailable }
        switch options.feedLayout {
        case .gallery where !supportsGalleryHint:
            throw CutError(code: "participant_gallery_hint_unavailable", message: "Gallery hints require a newer TileTrail build.")
        case .automatic where !supportsFeedLayouts:
            throw CutError(code: "participant_feed_layout_unavailable",
                           message: "Scanning generic feeds requires a TileTrail build with feed layouts.")
        default: break
        }
        let file = url.standardizedFileURL
        let identity = try SourceIdentity(file)
        let cache: AnalysisSidecar? = options.useSidecar && AnalysisSidecar.readsEnabled
            && !AnalysisSidecar.isExcluded(file, in: AnalysisSidecar.excludedSources)
            ? AnalysisSidecar(source: AnalysisSidecar.canonicalSource(file), identity: identity) : nil
        let media: MediaInfo
        let verifiedClock: Data?
        if let indexed = cache?.loadSceneClock(cancelled: cancelled) {
            media = indexed.forRefreshAlias(file)
            verifiedClock = nil
        } else {
            // Re-probe after a ctime change. An in-place rewrite can retain its
            // inode, size and mtime while changing the clock or display geometry.
            media = try SceneAnalysis.inspectSceneClock(file, identity: identity, cancelled: cancelled)
            verifiedClock = cache == nil ? nil : try? AnalysisSidecar.encodeSceneClock(media)
        }
        guard let video = media.videoStream, media.duration > .zero else {
            throw CutError(code: "no_video", message: "Participant analysis requires a video track.")
        }
        var source = try ParticipantScanSource(file: file.path, media: media, video: video)
        let transform = source.transform
        reporter?.duration = source.duration
        let configuration = ParticipantScanConfiguration(options)
        let key = ParticipantCacheKey(inode: identity.inode, stamp: source.stamp, stream: source.stream,
                                      origin: source.origin, timeBase: source.timeBase, duration: source.duration,
                                      transform: transform, backend: options.backend, sampling: options.sampling,
                                      feedLayout: options.feedLayout == .meeting ? nil : options.feedLayout,
                                      feedDetectorRevision: options.feedLayout == .meeting ? nil : Int(mpcut_tiletrail_feed_detector_revision()),
                                      galleryDetectorRevision: options.feedLayout.isMeeting && options.feedLayout != .meeting
                                          ? Int(mpcut_tiletrail_meeting_detector_revision()) : nil,
                                      meetingDetectorRevision: options.feedLayout != .meeting
                                          || mpcut_tiletrail_meeting_detector_revision() <= 1
                                          ? nil : Int(mpcut_tiletrail_meeting_detector_revision()),
                                      coverageRevision: media.format.split(separator: ",").contains { $0 == "matroska" || $0 == "mov" } ? 3 : nil,
                                      adaptiveRevision: options.sampling != .adaptive ? nil
                                          : supportsAdaptiveSampling && !options.includeScenes ? 1 : 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        let section = "participant_tracking.v1." + fingerprint + (options.includeScenes ? ".combined" : ".tiles")
        func verifySource() throws {
            guard identity.isCurrentSnapshot(at: file) else {
                throw CutError(code: "source_changed", message: "The source changed during participant analysis.")
            }
        }

        var earlyDigest: ParticipantDigestRun?
        defer { earlyDigest?.stop() }
        func loadSourceDigest() throws {
            guard source.contentSHA256 == nil else { return }
            let digestPrefix = "participant_content_sha256.v1."
            if let saved = cachedParticipantSourceDigest(identity, in: cache, cancelled: cancelled) {
                source.contentSHA256 = saved
            } else {
                let digest = try earlyDigest?.value()
                    ?? participantSourceDigest(file, identity: identity, cancelled: cancelled)
                source.contentSHA256 = digest
                cache?.saveAutomatically([identity.participantDigestSection: Data(digest.utf8)],
                                         retainingLatest: [digestPrefix: 2], cancelled: cancelled)
            }
        }

        func matchesRange(_ analysis: ParticipantTrackingResult) -> Bool {
            analysis.schemaVersion == 1 && analysis.start == .zero && analysis.end == source.duration
                && analysis.sampling == options.sampling.detectorSampling
        }

        func paused(_ analysis: ParticipantTrackingResult?) throws -> ParticipantScanResult {
            try verifySource()
            return ParticipantScanResult(state: .paused, source: source, configuration: configuration, analysis: analysis,
                                         sceneReport: nil, analysisIdentity: fingerprint)
        }

        if let partial {
            guard partial.state == .paused || partial.state == .incomplete,
                  partial.analysisIdentity == fingerprint, partial.configuration == configuration,
                  partial.analysis.map({ analysis in
                      matchesRange(analysis) && analysis.resumeAt.map { (.zero...source.duration).contains($0) } == true
                  }) ?? true else {
                throw CutError(code: "participant_resume_mismatch",
                               message: "The partial participant scan does not match this source and scan configuration.")
            }
        }

        // A previous adapter forced CPU for automatic requests. TileTrail always records
        // a fallback reason when an actual automatic initialization selects CPU.
        func matchesCachedBackend(_ analysis: ParticipantTrackingResult) -> Bool {
            guard options.backend == .automatic else { return true }
            guard let initial = analysis.diagnostics.first else { return false }
            return initial.backend == .gpu || initial.reason != nil
        }

        if partial == nil, cache != nil { reporter?.send(.checkingCache) }
        if partial == nil, let data = cache?.read(section, cancelled: cancelled),
           let saved = try? JSONDecoder().decode(ParticipantCachedScan.self, from: data),
           matchesRange(saved.analysis), saved.analysis.resumeAt == nil, matchesCachedBackend(saved.analysis),
           !options.includeScenes || saved.sceneReport != nil {
            progress?(source.duration)
            try verifySource()
            if cancelled() { return try paused(nil) }
            do { try loadSourceDigest() }
            catch is CancellationError { return try paused(nil) }
            try verifySource()
            if saved.contentSHA256 == source.contentSHA256 {
                if let verifiedClock {
                    cache?.saveAutomatically([AnalysisSidecar.sceneClockKey: verifiedClock], cancelled: cancelled)
                }
                let report = saved.sceneReport.map {
                    let report = $0.forSource(file)
                    return cache?.restoringViewNames(to: report, cancelled: cancelled) ?? report
                }
                if cancelled() { return try paused(nil) }
                try verifySource()
                return ParticipantScanResult(state: .upToDate, source: source, configuration: configuration, analysis: saved.analysis,
                                             sceneReport: report, analysisIdentity: fingerprint)
            }
        }

        try verifySource()
        if cancelled() { return try paused(partial?.analysis) }
        if source.contentSHA256 == nil,
           cachedParticipantSourceDigest(identity, in: cache, cancelled: cancelled) == nil {
            earlyDigest = ParticipantDigestRun(file, identity: identity, cancelled: cancelled)
        }
        let checkpoint: ParticipantScanCheckpoint?
        if let directory = options.checkpointDirectory, !options.includeScenes, mpcut_tiletrail_has_checkpoints() != 0 {
            checkpoint = try ParticipantScanCheckpoint(directory: directory, fingerprint: fingerprint,
                                                        identity: identity, duration: source.duration)
        } else {
            checkpoint = nil
        }
        let scan = try TileTrailScan(media: media, source: source, options: options,
                                     cancelled: cancelled, progress: progress, reporter: reporter,
                                     checkpoint: checkpoint)
        do { try scan.restoreCheckpoint() }
        catch is CancellationError { return try paused(partial?.analysis) }
        reporter?.send(.scanning, at: checkpoint?.anchor?.time ?? .zero)
        let result = try scan.run(file)
        try verifySource()
        if let checkpoint = partial?.analysis {
            let old = checkpoint.observations
            // Replay the decoded prefix to rebuild analyzer state. Only advance
            // a saved scan when both runs assign the same geometry and IDs.
            for (before, after) in zip(old, result.analysis.observations) where before != after {
                throw CutError(code: "participant_resume_mismatch",
                               message: "Participant observations changed while replaying the saved scan.")
            }
            let checkpointPosition = checkpoint.resumeAt ?? .zero
            // After reaching EOF the first gap can precede a previously paused checkpoint.
            // A gap identifies missing coverage even when replay verified the entire prefix.
            let stoppedEarly = result.state == .paused || scan.deviceLoss != nil
            let replayPosition = stoppedEarly ? result.analysis.resumeAt ?? .zero : source.duration
            if result.analysis.observations.count < old.count || replayPosition < checkpointPosition {
                if result.state == .paused {
                    return try paused(checkpoint)
                }
                throw CutError(code: "participant_resume_mismatch",
                               message: "The saved participant scan extends beyond the replayed source.")
            }
        }
        let sceneReport = result.sceneReport.map { cache?.restoringViewNames(to: $0, cancelled: cancelled) ?? $0 }
        if result.state == .completed {
            func pauseAfterDecode() throws -> ParticipantScanResult {
                var checkpoint = result.analysis
                checkpoint.resumeAt = source.duration
                return try paused(checkpoint)
            }
            if cancelled() { return try pauseAfterDecode() }
            do { try loadSourceDigest() }
            catch is CancellationError { return try pauseAfterDecode() }
            let cached = ParticipantCachedScan(analysis: result.analysis, sceneReport: result.sceneReport,
                                              contentSHA256: source.contentSHA256)
            // A dense history can exceed the cache's practical size. Long jobs
            // write their reusable report in batches and skip the whole-report cache.
            if let cache, result.analysis.observations.count <= 100_000,
               result.analysis.observations.reduce(0, { $0 + $1.regions.count }) <= 100_000 {
                cache.saveAutomatically(try [section: encoder.encode(cached), AnalysisSidecar.sceneClockKey: verifiedClock]
                    .compactMapValues { $0 }, retainingLatest: ["participant_tracking.v1.": 12], cancelled: cancelled)
            }
            if cancelled() { return try pauseAfterDecode() }
        }
        try verifySource()
        return ParticipantScanResult(state: result.state, source: source, configuration: configuration, analysis: result.analysis,
                                     sceneReport: sceneReport, analysisIdentity: fingerprint)
        #else
        throw unavailable
        #endif
    }

    public static func markers(_ result: ParticipantScanResult,
                               rule: ParticipantMarkerRule = .init()) throws -> [ParticipantSceneMarker] {
        #if canImport(CTileTrail)
        guard isAvailable else { throw unavailable }
        guard var analysis = result.analysis else { return [] }
        if let resume = analysis.resumeAt, let last = analysis.observations.last, last.time >= resume {
            // The adapter can encounter a missing interval and still receive
            // subsequent frames. TileTrail's resume clock cuts off a whole tail;
            // the per-interval coverage already identifies the unavailable frames.
            analysis.resumeAt = nil
        }
        let data = try ParticipantSourceTime.originalClockJSON(analysis, origin: result.source.origin)
        let ruleData = try JSONEncoder().encode(rule)
        let output = TileTrailOutput()
        var failure = tiletrail_error_t()
        let status = data.withUnsafeBytes { bytes in
            ruleData.withUnsafeBytes { ruleBytes in
                tiletrail_scene_markers_json(bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count),
                                             ruleBytes.bindMemory(to: UInt8.self).baseAddress, UInt64(ruleBytes.count),
                                             &output.buffer, &failure)
            }
        }
        try checkTileTrail(status, &failure)
        return try ParticipantSourceTime.decodeOriginalClock([ParticipantSceneMarker].self,
                                                               data: output.contents, origin: result.source.origin)
        #else
        throw unavailable
        #endif
    }

    private static var unavailable: CutError {
        CutError(code: "participant_analysis_unavailable",
                 message: "Participant analysis requires an MPCut build linked against the TileTrail C ABI v1 artifact.")
    }
}

#if canImport(CTileTrail)
/// Hashes the recording while its pictures decode. Both read the same file,
/// so a completed scan does not wait for a second pass over it.
private final class ParticipantDigestRun {
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var outcome: Result<String, Error>?

    init(_ file: URL, identity: SourceIdentity, cancelled: @escaping () -> Bool) {
        let thread = Thread { [self] in
            let result = Result {
                try participantSourceDigest(file, identity: identity, cancelled: { self.isStopped || cancelled() })
            }
            lock.lock()
            outcome = result
            lock.unlock()
            finished.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Abandon the hash. A scan that did not complete has no use for it.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func value() throws -> String {
        finished.wait()
        finished.signal()
        lock.lock()
        defer { lock.unlock() }
        return try outcome!.get()
    }
}

private struct ParticipantCacheKey: Encodable {
    let detector = "tiletrail-0.1.0"
    // The release candidate changed layout and identity decisions after the
    // initial 0.1.0 scans. Cached machine results must use the final model.
    let detectorRevision = 2
    let displayGeometry = 3
    let inode: UInt64
    let stamp: SceneSourceStamp
    let stream: Int
    let origin: RationalTime
    let timeBase: RationalTime
    let duration: RationalTime
    let transform: ParticipantDisplayTransform
    let backend: ParticipantBackendMode
    let sampling: ParticipantSampling
    let feedLayout: ParticipantFeedLayout?
    let feedDetectorRevision: Int?
    let galleryDetectorRevision: Int?
    // Absent for libraries that predate the revision, which keeps their saved scans.
    let meetingDetectorRevision: Int?
    let coverageRevision: Int?
    // Zero records an adaptive request that analyzed every frame.
    let adaptiveRevision: Int?
}

private struct ParticipantCachedScan: Codable {
    let analysis: ParticipantTrackingResult
    let sceneReport: SceneReport?
    let contentSHA256: String?
}

func checkTileTrail(_ status: Int32, _ error: inout tiletrail_error_t) throws {
    guard status != TILETRAIL_OK else { return }
    let message = withUnsafeBytes(of: &error.message) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    let code = status == TILETRAIL_GPU_UNAVAILABLE ? "participant_gpu_unavailable" : "participant_analysis_failed"
    throw CutError(code: code, message: message)
}

// The ABI owns this allocation independently of the analyzer. Keep its original
// descriptor alive for as long as Foundation might reference the JSON bytes.
private final class TileTrailOutput {
    var buffer = tiletrail_buffer_t()

    deinit { tiletrail_buffer_free(&buffer) }

    var contents: Data {
        get throws {
            guard let data = buffer.data, let count = Int(exactly: buffer.len) else {
                throw CutError(code: "participant_result_invalid", message: "TileTrail returned an invalid result.")
            }
            return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: data), count: count,
                        deallocator: .custom { [self] _, _ in withExtendedLifetime(self) {} })
        }
    }
}

private extension tiletrail_timestamp_t {
    init(_ time: RationalTime) throws {
        guard let denominator = UInt32(exactly: time.denominator) else {
            throw CutError(code: "participant_clock_unsupported", message: "TileTrail cannot represent this source clock.")
        }
        self.init(pts: time.numerator, numerator: 1, denominator: denominator)
    }

    func localTime(origin: RationalTime) throws -> RationalTime {
        guard numerator > 0, denominator > 0 else {
            throw CutError(code: "participant_result_invalid", message: "TileTrail returned an invalid resume clock.")
        }
        return try RationalTime(numerator: pts)
            .multiplied(by: RationalTime(numerator: Int64(numerator), denominator: Int64(denominator)))
            .subtracting(origin)
    }
}

private final class TileTrailScan {
    let source: ParticipantScanSource
    let scenes: CombinedSceneCollector?
    let cancelled: () -> Bool
    let progress: ((RationalTime) -> Void)?
    private var handle: OpaquePointer?
    let baseNum: UInt32
    let baseDen: UInt32
    let sampling: ParticipantSampling
    private let adaptive: Bool
    private let matroskaCadenceInTicks: RationalTime?
    private let frameRate: RationalTime
    private var cadenceOffset: Int64 = 0
    /// Worker threads measure and detect pictures ahead of the pushes.
    private let preparesAhead: Bool

    var failure: Error?
    var deviceLoss: RationalTime?
    private var holes: [Range<RationalTime>] = []
    private var previous: (time: RationalTime, end: RationalTime?, valid: Bool)?
    private var unknownTimestamp = false
    private let reporter: ParticipantScanReporter?
    private var progressCount = 0
    private var lastSample: RationalTime?
    private let checkpoint: ParticipantScanCheckpoint?
    private var decoderDamage: UnsafeMutablePointer<Int32>?
    private var lastCheckpointAnchor: ParticipantScanCheckpoint.Anchor?

    init(media: MediaInfo, source: ParticipantScanSource, options: ParticipantScanOptions,
         cancelled: @escaping () -> Bool, progress: ((RationalTime) -> Void)?, reporter: ParticipantScanReporter?,
         checkpoint: ParticipantScanCheckpoint?) throws {
        self.checkpoint = checkpoint
        self.reporter = reporter
        self.source = source
        self.sampling = options.sampling
        self.cancelled = cancelled
        self.progress = progress
        self.scenes = options.includeScenes ? try CombinedSceneCollector(media: media) : nil
        guard source.timeBase.numerator > 0,
              let numerator = UInt32(exactly: source.timeBase.numerator),
              let denominator = UInt32(exactly: source.timeBase.denominator) else {
            throw CutError(code: "participant_clock_unsupported", message: "TileTrail cannot represent this source clock.")
        }
        baseNum = numerator
        baseDen = denominator
        // Matroska demuxers may round a fractional default block duration down.
        // Corroborate a one-tick discrepancy against the declared frame cadence.
        let rate = media.videoStream?.frameRate ?? .zero
        frameRate = rate
        if media.format.split(separator: ",").contains("matroska"), rate > .zero,
           source.timeBase >= RationalTime(numerator: 1, denominator: 1_000_000),
           let ticks = try? RationalTime(numerator: rate.denominator, denominator: rate.numerator)
            .multiplied(by: RationalTime(numerator: source.timeBase.denominator, denominator: source.timeBase.numerator)),
           ticks.denominator > 1, ticks.numerator >= ticks.denominator {
            matroskaCadenceInTicks = ticks
        } else {
            matroskaCadenceInTicks = nil
        }
        let mode: Int
        switch options.backend {
        case .automatic: mode = TILETRAIL_MODE_AUTO
        case .cpu: mode = TILETRAIL_MODE_CPU_ONLY
        case .gpuRequired: mode = TILETRAIL_MODE_GPU_REQUIRED
        }
        var config = tiletrail_config_t(mode: UInt32(mode), sampling: UInt32(
            options.sampling.detectorSampling == .sparse ? TILETRAIL_SAMPLING_SPARSE : TILETRAIL_SAMPLING_EVERY_FRAME))
        // The scene collector compares consecutive pictures and needs them all.
        adaptive = options.sampling == .adaptive && !options.includeScenes
            && ParticipantAnalysis.supportsAdaptiveSampling
        // Sparse sampling analyzes one frame in several; preparing all would waste the rest.
        preparesAhead = mpcut_tiletrail_has_prepared_frames(options.backend == .gpuRequired ? 1 : 0) != 0
            && options.sampling != .sparse
        var result: OpaquePointer?
        var error = tiletrail_error_t()
        let start = try tiletrail_timestamp_t(source.origin)
        let status: Int32
        switch options.feedLayout {
        case .meeting:
            status = tiletrail_analyzer_create(&config, start, &result, &error)
        case .gallery(let columns, let rows):
            status = mpcut_tiletrail_analyzer_create_gallery(&config, start, columns, rows, &result, &error)
        case .automatic:
            status = mpcut_tiletrail_analyzer_create_feeds(&config, start, 0, 0, &result, &error)
        case .fixed(let columns, let rows):
            status = mpcut_tiletrail_analyzer_create_feeds(&config, start, columns, rows, &result, &error)
        }
        try checkTileTrail(status, &error)
        guard let result else {
            throw CutError(code: "participant_analysis_failed", message: "TileTrail did not return an analyzer.")
        }
        handle = result
    }

    deinit {
        tiletrail_analyzer_free(handle)
    }

    func restoreCheckpoint() throws {
        guard let checkpoint, let anchor = checkpoint.anchor else { return }
        let timestamp = tiletrail_timestamp_t(pts: anchor.pts, numerator: baseNum, denominator: baseDen)
        guard try timestamp.localTime(origin: source.origin) == anchor.time else {
            throw CutError(code: "participant_resume_mismatch", message: "The checkpoint frame uses a different source clock.")
        }
        try checkpoint.restore(handle, cancelled: cancelled)
        var state = tiletrail_progress_t()
        var error = tiletrail_error_t()
        try checkTileTrail(tiletrail_analyzer_progress(handle, nil, &state, &error), &error)
        guard state.frames_processed > 0,
              try state.last_timestamp.localTime(origin: source.origin) == anchor.time else {
            throw CutError(code: "participant_resume_mismatch", message: "The checkpoint anchor differs from the saved observations.")
        }
        previous = (anchor.time, anchor.end, true)
        lastSample = anchor.time
        lastCheckpointAnchor = anchor
        progress?(anchor.time)
    }

    private func saveCheckpoint(force: Bool = false) throws {
        guard let checkpoint, let anchor = lastCheckpointAnchor, deviceLoss == nil, previous?.valid == true,
              holes.isEmpty, !unknownTimestamp, decoderDamage?.pointee == 0 else { return }
        let since = checkpoint.anchor?.time ?? .zero
        let interval = try anchor.time.subtracting(since)
        guard force || interval >= RationalTime(numerator: 30) else { return }
        try checkpoint.save(handle, after: anchor)
    }

    func run(_ url: URL) throws -> (state: ParticipantScanResult.State, analysis: ParticipantTrackingResult,
                                    sceneReport: SceneReport?) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let scene: MPSceneVisit = { pointer, pts, feature in
            guard let feature else { return }
            let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
            do { try scan.scenes?.marker(pts: pts, feature: feature) }
            catch { scan.failure = error }
        }
        // The adaptive reader's visits own the analysis prepared for their picture.
        let sample: MPParticipantSampleVisit = { pointer, pts, duration, rgb, width, height, stride, sarNum, sarDen, prepared in
            let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
            var prepared = prepared
            defer { mpcut_tiletrail_prepared_free(prepared) }
            do {
                if try !scan.shouldSample(pts: pts, duration: duration, valid: rgb != nil) { return 0 }
                try scan.push(pts: pts, rgb: rgb, width: width, height: height,
                              stride: stride, sarNum: sarNum, sarDen: sarDen, prepared: &prepared)
                return scan.deviceLoss == nil ? 0 : 1
            } catch {
                scan.failure = error
                return 1
            }
        }
        let coarse: MPParticipantSampleVisit = { pointer, pts, duration, rgb, width, height, stride, sarNum, sarDen, prepared in
            let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
            var prepared = prepared
            defer { mpcut_tiletrail_prepared_free(prepared) }
            do {
                return try scan.pushCoarse(pts: pts, duration: duration, rgb: rgb, width: width, height: height,
                                           stride: stride, sarNum: sarNum, sarDen: sarDen, prepared: &prepared)
            } catch {
                scan.failure = error
                return -1
            }
        }
        // Runs on several threads at once. It reads only constants of the scan.
        let prepare: MPParticipantPrepare = { pointer, pts, rgb, width, height, stride, sarNum, sarDen in
            let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
            guard let rgb else { return nil }
            var frame = scan.picture(pts: pts, rgb: rgb, width: width, height: height, stride: stride,
                                     sarNum: sarNum, sarDen: sarDen)
            return mpcut_tiletrail_analyzer_prepare(scan.handle, &frame)
        }
        let discard: MPParticipantDiscard = { _, prepared in mpcut_tiletrail_prepared_free(prepared) }
        let stopped: MPProbeCancelled = { pointer in
            let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
            return scan.failure != nil || scan.deviceLoss != nil || scan.cancelled() ? 1 : 0
        }
        var decoderMessage = [CChar](repeating: 0, count: 256)
        let unplacedDamage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        unplacedDamage.initialize(to: 0)
        decoderDamage = unplacedDamage
        defer {
            decoderDamage = nil
            unplacedDamage.deinitialize(count: 1)
            unplacedDamage.deallocate()
        }
        var editTail = MPParticipantEditTail()
        let status = url.withUnsafeFileSystemRepresentation { path in
            // One reader serves every mode. It decodes every frame in order
            // unless it has a coarse visit; sparse sampling selects from those
            // frames in the visit, and scene detection sees them all.
            if matroskaCadenceInTicks != nil, source.origin != .zero,
               let rateNum = Int32(exactly: frameRate.numerator), let rateDen = Int32(exactly: frameRate.denominator),
               let origin = try? source.origin.multiplied(by: RationalTime(numerator: Int64(baseDen), denominator: Int64(baseNum))),
               origin.denominator == 1,
               mp_scene_uses_segment_cadence(path, Int32(source.stream), origin.numerator, rateNum, rateDen, stopped, context) != 0 {
                cadenceOffset = origin.numerator
            }
            return mp_participant_scan_from(path, Int32(source.stream), mpcut_tiletrail_sample_limit(),
                                     checkpoint?.anchor?.pts ?? Int64.min, stopped,
                                     adaptive ? coarse : nil, sample, preparesAhead ? prepare : nil, discard,
                                     scenes == nil ? nil : scene, context,
                                     unplacedDamage, &editTail, &decoderMessage, decoderMessage.count)
        }
        if let failure { throw failure }
        if status == MP_PARTICIPANT_UNSUPPORTED_DISPLAY_TRANSFORM {
            throw CutError(code: "unsupported_display_transform",
                           message: "Participant analysis requires decoded pictures to use the recording’s declared display rotation.")
        }
        if status == MP_PARTICIPANT_RESUME_ANCHOR_MISSING {
            throw CutError(code: "participant_resume_mismatch",
                           message: "The decoder could not locate the saved checkpoint frame.")
        }
        let paused = deviceLoss == nil && (status == MP_SCENE_SCAN_CANCELLED || cancelled())
        if status != 0 && !paused && deviceLoss == nil {
            throw CutError(code: "participant_decode_failed", message: String(cString: decoderMessage))
        }

        if paused || status == 0 { try saveCheckpoint(force: true) }
        var analyzedEnd = source.duration
        if let deviceLoss {
            addHole(from: deviceLoss, to: source.duration)
        } else if let previous {
            let tail = previous.end ?? (paused || !previous.valid ? previous.time : source.duration)
            let lastIndexed = tiletrail_timestamp_t(pts: editTail.last_pts, numerator: baseNum, denominator: baseDen)
            if !paused, previous.valid, !unknownTimestamp, unplacedDamage.pointee == 0,
               editTail.preroll_ticks > 0, tail < source.duration,
               try lastIndexed.localTime(origin: source.origin) == previous.time,
               try source.duration.subtracting(tail) < tail.subtracting(previous.time),
               try source.duration.subtracting(tail) < source.timeBase.multiplied(by: .init(numerator: editTail.preroll_ticks)) {
                // All presented samples were read. Keep the fractional edit tail
                // in the report without extending the last box beyond its picture.
                analyzedEnd = tail
            } else if !paused, previous.valid, !unknownTimestamp, unplacedDamage.pointee == 0,
                      editTail.trailing_ticks > 0, tail < source.duration,
                      try lastIndexed.localTime(origin: source.origin) == previous.time,
                      try source.duration.subtracting(tail)
                        == source.timeBase.multiplied(by: .init(numerator: editTail.trailing_ticks)) {
                // The edit ends on the last stored sample, which is never
                // presented. Every presented sample was read; the report keeps
                // that sample's width as unknown coverage with no tile boxes.
                analyzedEnd = tail
            } else if !previous.valid || paused || !isRoundedMatroskaFrame(from: previous.time, end: tail, next: source.duration) {
                addHole(from: previous.valid ? tail : previous.time, to: source.duration)
            }
        } else {
            addHole(from: .zero, to: source.duration)
        }
        if unknownTimestamp || unplacedDamage.pointee != 0 {
            // Damage without a decoded presentation timestamp cannot be
            // assigned to a narrower source interval.
            holes = [.zero..<source.duration]
        }
        reporter?.send(.finalizing, at: paused || deviceLoss != nil ? previous?.time : source.duration)
        let end = try tiletrail_timestamp_t(source.origin.adding(analyzedEnd))
        var analysis: ParticipantTrackingResult
        if mpcut_tiletrail_has_result_chunks() != 0 {
            analysis = try ParticipantScanChunks(origin: source.origin).result(handle, end: end)
        } else {
            let output = TileTrailOutput()
            var error = tiletrail_error_t()
            try checkTileTrail(tiletrail_analyzer_result_json(handle, end, &output.buffer, &error), &error)
            tiletrail_analyzer_free(handle)
            handle = nil
            analysis = try ParticipantSourceTime.decodeOriginalClock(ParticipantTrackingResult.self,
                                                                     data: output.contents, origin: source.origin)
        }
        tiletrail_analyzer_free(handle)
        handle = nil
        guard analysis.schemaVersion == 1, analysis.start == .zero, analysis.end == analyzedEnd else {
            throw CutError(code: "participant_result_invalid", message: "TileTrail returned an unexpected result clock or schema version.")
        }
        if analyzedEnd < source.duration {
            analysis.end = source.duration
            analysis.coverage.append(.init(start: analyzedEnd, end: source.duration, status: .unknown))
        }
        analysis.coverage = coverage(analysis.coverage)
        if paused {
            analysis.resumeAt = unknownTimestamp || unplacedDamage.pointee != 0 ? .zero : (previous?.valid == true ? previous?.end : nil)
                ?? previous?.time ?? .zero
        } else if let deviceLoss {
            analysis.resumeAt = deviceLoss
        } else if let first = holes.first {
            analysis.resumeAt = first.lowerBound
        }
        let state: ParticipantScanResult.State = paused ? .paused : deviceLoss != nil || !holes.isEmpty ? .incomplete : .completed
        if state == .completed { progress?(source.duration) }
        return (state, analysis, status == 0 && !paused ? scenes?.report : nil)
    }

    private func shouldSample(pts: Int64, duration: Int64, valid: Bool) throws -> Bool {
        guard pts != .min else {
            unknownTimestamp = true
            return false
        }
        let timestamp = tiletrail_timestamp_t(pts: pts, numerator: baseNum, denominator: baseDen)
        let time = try timestamp.localTime(origin: source.origin)
        guard time >= .zero, time < source.duration else { return false }
        if let previous {
            guard time >= previous.time else {
                throw CutError(code: "participant_clock_unsupported", message: "Decoded video frames have out-of-order presentation timestamps.")
            }
            if time == previous.time {
                self.previous = (time, previous.end, false)
                return false
            }
            let lastEnd = previous.end ?? time
            if previous.valid {
                if !isRoundedMatroskaFrame(from: previous.time, end: lastEnd, next: time) {
                    addHole(from: lastEnd, to: time)
                }
            } else {
                addHole(from: previous.time, to: time)
            }
        } else {
            addHole(from: .zero, to: time)
        }

        let frameEnd = duration > 0
            ? min(source.duration, try time.adding(RationalTime(numerator: duration).multiplied(by: source.timeBase)))
            : nil
        previous = (time, frameEnd, valid)
        reporter?.send(.scanning, at: time)
        guard valid else { return false }
        if sampling == .sparse, let lastSample, let elapsed = try? time.subtracting(lastSample),
           elapsed < RationalTime(numerator: 1, denominator: 5) {
            reportProgress(time)
            return false
        }
        return true
    }

    private func picture(pts: Int64, rgb: UnsafePointer<UInt8>, width: Int32, height: Int32, stride: Int32,
                         sarNum: Int32, sarDen: Int32) -> tiletrail_frame_t {
        tiletrail_frame_t(data: rgb, len: UInt64(stride) * UInt64(height),
                          stride: UInt64(stride), width: UInt32(width), height: UInt32(height),
                          format: UInt32(TILETRAIL_FORMAT_RGB24), rotation: source.transform.rotation.clockwiseDegrees,
                          pixel_aspect_num: sarNum > 0 && sarDen > 0 ? UInt32(sarNum) : source.transform.pixelAspectNum,
                          pixel_aspect_den: sarNum > 0 && sarDen > 0 ? UInt32(sarDen) : source.transform.pixelAspectDen,
                          timestamp: tiletrail_timestamp_t(pts: pts, numerator: baseNum, denominator: baseDen))
    }

    private func submit(_ frame: inout tiletrail_frame_t, prepared: inout UnsafeMutableRawPointer?,
                        coarseOutcome: UnsafeMutablePointer<UInt32>?, error: inout tiletrail_error_t) -> Int32 {
        if let ahead = prepared {
            prepared = nil
            let status = mpcut_tiletrail_analyzer_push_prepared(handle, ahead, coarseOutcome == nil ? 0 : 1,
                                                                 coarseOutcome, &error)
            if status != TILETRAIL_INVALID_FRAME { return status }
            // An earlier ordered push can switch the backend after these workers
            // prepared their batch. Replay the original pixels on the new backend.
        }
        if let coarseOutcome {
            return mpcut_tiletrail_analyzer_push_coarse(handle, &frame, coarseOutcome, &error)
        }
        return tiletrail_analyzer_push(handle, &frame, &error)
    }

    /// Offer a keyframe in place of the frames since the last analyzed one.
    /// The decoder has checked that their packets cover that interval, so an
    /// accepted keyframe leaves no hole. Returns 1 to skip them and 0 to
    /// analyze them.
    private func pushCoarse(pts: Int64, duration: Int64, rgb: UnsafePointer<UInt8>?,
                            width: Int32, height: Int32, stride: Int32, sarNum: Int32, sarDen: Int32,
                            prepared: inout UnsafeMutableRawPointer?) throws -> Int32 {
        guard let rgb, pts != .min, duration > 0, let previous, previous.valid, let covered = previous.end else { return 0 }
        let time = try tiletrail_timestamp_t(pts: pts, numerator: baseNum, denominator: baseDen)
            .localTime(origin: source.origin)
        guard time >= covered, time < source.duration else { return 0 }
        var frame = picture(pts: pts, rgb: rgb, width: width, height: height, stride: stride, sarNum: sarNum, sarDen: sarDen)
        var error = tiletrail_error_t()
        var outcome: UInt32 = 1
        let status = submit(&frame, prepared: &prepared, coarseOutcome: &outcome, error: &error)
        if status == TILETRAIL_DEVICE_LOST {
            // Nothing confirmed the skipped frames. Resume from the last analyzed one.
            deviceLoss = covered
            return -1
        }
        try checkTileTrail(status, &error)
        guard mpcut_tiletrail_coarse_committed(outcome) != 0 else { return 0 }
        let end = min(source.duration, try time.adding(RationalTime(numerator: duration).multiplied(by: source.timeBase)))
        self.previous = (time, end, true)
        lastSample = time
        lastCheckpointAnchor = .init(pts: pts, time: time, end: end)
        try saveCheckpoint()
        reporter?.send(.scanning, at: time)
        reportProgress(time)
        return 1
    }

    /// Commit a frame, from the analysis prepared for it when there is one.
    private func push(pts: Int64, rgb: UnsafePointer<UInt8>?,
                      width: Int32, height: Int32, stride: Int32, sarNum: Int32, sarDen: Int32,
                      prepared: inout UnsafeMutableRawPointer?) throws {
        guard let rgb, let time = previous?.time else {
            throw CutError(code: "participant_decode_failed", message: "The decoder returned no pixels for a selected frame.")
        }
        var frame = picture(pts: pts, rgb: rgb, width: width, height: height, stride: stride, sarNum: sarNum, sarDen: sarDen)
        var error = tiletrail_error_t()
        let status = submit(&frame, prepared: &prepared, coarseOutcome: nil, error: &error)
        if status == TILETRAIL_DEVICE_LOST {
            deviceLoss = error.has_resume != 0 ? try error.resume_at.localTime(origin: source.origin) : time
            return
        }
        try checkTileTrail(status, &error)
        lastSample = time
        lastCheckpointAnchor = .init(pts: pts, time: time, end: previous?.end)
        try saveCheckpoint()
        reportProgress(time)
    }

    private func reportProgress(_ time: RationalTime) {
        if progressCount % 8 == 0 { progress?(time) }
        progressCount += 1
    }

    private func isRoundedMatroskaFrame(from start: RationalTime, end: RationalTime, next: RationalTime) -> Bool {
        guard let cadence = matroskaCadenceInTicks, end < next,
              (try? next.subtracting(end)) == source.timeBase else { return false }
        let ticksPerSecond = RationalTime(numerator: source.timeBase.denominator, denominator: source.timeBase.numerator)
        let framesPerTick = RationalTime(numerator: cadence.denominator, denominator: cadence.numerator)
        func roundedTick(_ frame: Int64) throws -> Int64 {
            try cadence.roundedToSamples(Int(frame))
        }
        return (try? {
            let startTick = try start.multiplied(by: ticksPerSecond).roundedToSamples(1)
            let endTick = try end.multiplied(by: ticksPerSecond).roundedToSamples(1)
            let nextTick = try next.multiplied(by: ticksPerSecond).roundedToSamples(1)
            guard endTick - startTick == cadence.numerator / cadence.denominator else { return false }
            let (startPTS, startOverflow) = startTick.addingReportingOverflow(cadenceOffset)
            let (nextPTS, nextOverflow) = nextTick.addingReportingOverflow(cadenceOffset)
            guard !startOverflow, !nextOverflow else { return false }
            let frame = try framesPerTick.roundedToSamples(Int(startPTS))
            guard frame < .max else { return false }
            return try roundedTick(frame) == startPTS && roundedTick(frame + 1) == nextPTS
        }()) == true
    }

    private func addHole(from start: RationalTime, to end: RationalTime) {
        guard start < end else { return }
        if let last = holes.last, last.upperBound >= start {
            holes[holes.count - 1] = min(last.lowerBound, start)..<max(last.upperBound, end)
        } else {
            holes.append(start..<end)
        }
    }

    private func coverage(_ intervals: [ParticipantTrackingCoverage]) -> [ParticipantTrackingCoverage] {
        guard !holes.isEmpty else { return intervals }
        var result: [ParticipantTrackingCoverage] = []
        var remaining = holes[...]
        func append(_ start: RationalTime, _ end: RationalTime, _ status: ParticipantTrackingCoverage.Status) {
            guard start < end else { return }
            if let last = result.last, last.end == start, last.status == status {
                result[result.count - 1].end = end
            } else {
                result.append(ParticipantTrackingCoverage(start: start, end: end, status: status))
            }
        }
        for interval in intervals {
            var start = interval.start
            while let hole = remaining.first, hole.lowerBound < interval.end {
                if hole.upperBound <= start {
                    remaining.removeFirst()
                    continue
                }
                append(start, hole.lowerBound, interval.status)
                append(max(start, hole.lowerBound), min(hole.upperBound, interval.end), .incomplete)
                start = min(interval.end, hole.upperBound)
                if hole.upperBound > interval.end { break }
                remaining.removeFirst()
            }
            append(start, interval.end, interval.status)
        }
        return result
    }
}
#endif

extension StreamInfo {
    var hasDisplayMatrix: Bool {
        codecMetadata.withUnsafeBytes { buffer in
            var offset = 0
            while buffer.count - offset >= 8 {
                let type = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let size = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                guard size <= buffer.count - offset - 8 else { break }
                if type == UInt32(AV_PKT_DATA_DISPLAYMATRIX.rawValue) { return true }
                offset += 8 + Int(size)
            }
            return false
        }
    }
}
