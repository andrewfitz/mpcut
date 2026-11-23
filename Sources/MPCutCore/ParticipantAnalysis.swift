import CFFmpeg
import CryptoKit
import Foundation
import MediaProbe

#if canImport(CTileTrail)
import CTileTrail
#endif

public enum ParticipantAnalysis {
    public static var isAvailable: Bool {
        #if canImport(CTileTrail)
        tiletrail_abi_version() == TILETRAIL_ABI_VERSION
        #else
        false
        #endif
    }

    public static func scan(_ url: URL, options: ParticipantScanOptions = .init(),
                            resuming partial: ParticipantScanResult? = nil,
                            cancelled: @escaping () -> Bool = { Task.isCancelled },
                            progress: ((RationalTime) -> Void)? = nil) throws -> ParticipantScanResult {
        #if canImport(CTileTrail)
        guard isAvailable else { throw unavailable }
        guard url.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local video file.") }
        let file = url.standardizedFileURL
        let identity = try SourceIdentity(file)
        let cache: AnalysisSidecar? = options.useSidecar && AnalysisSidecar.readsEnabled
            && !AnalysisSidecar.isExcluded(file, in: AnalysisSidecar.excludedSources)
            ? AnalysisSidecar(source: AnalysisSidecar.canonicalSource(file), identity: identity) : nil
        let media: MediaInfo
        if let indexed = try cache?.loadIndex(detail: .preview, cancelled: cancelled)
            ?? cache?.loadSceneClock(cancelled: cancelled) {
            media = indexed.forRefreshAlias(file)
        } else {
            media = try SceneAnalysis.inspectSceneClock(file, identity: identity, cancelled: cancelled)
        }
        guard let video = media.videoStream, media.duration > .zero else {
            throw CutError(code: "no_video", message: "Participant analysis requires a video track.")
        }
        guard video.rotation.isMultiple(of: 90), video.rotationOnly || !video.hasDisplayMatrix else {
            throw CutError(code: "unsupported_display_transform", message: "Participant analysis requires a quarter-turn display transform.")
        }
        let turns = ((-video.rotation % 360) + 360) % 360
        let rotation: ParticipantDisplayTransform.Rotation
        switch turns {
        case 90: rotation = .r90
        case 180: rotation = .r180
        case 270: rotation = .r270
        default: rotation = .r0
        }
        let transform = ParticipantDisplayTransform(
            rotation: rotation,
            pixelAspectNum: UInt32(exactly: video.sampleAspectRatio.numerator).flatMap { $0 > 0 ? $0 : nil } ?? 1,
            pixelAspectDen: UInt32(exactly: video.sampleAspectRatio.denominator) ?? 1)
        let source = ParticipantScanSource(file: file.path, stamp: SceneSourceStamp(identity: identity),
                                           inode: identity.inode, stream: video.index,
                                           origin: media.origin, timeBase: video.timeBase, duration: media.duration,
                                           transform: transform)
        let configuration = ParticipantScanConfiguration(options)
        let key = ParticipantCacheKey(inode: identity.inode, stamp: source.stamp, stream: source.stream,
                                      origin: source.origin, timeBase: source.timeBase, duration: source.duration,
                                      transform: transform, backend: options.backend, sampling: options.sampling)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        let section = "participant_tracking.v1." + fingerprint + (options.includeScenes ? ".combined" : ".tiles")
        func verifySource() throws {
            guard identity.isCurrentSnapshot(at: file) else {
                throw CutError(code: "source_changed", message: "The source changed during participant analysis.")
            }
        }

        if let partial {
            guard partial.state == .paused || partial.state == .incomplete,
                  partial.analysisIdentity == fingerprint, partial.configuration == configuration,
                  partial.analysis?.resumeAt != nil || partial.analysis == nil else {
                throw CutError(code: "participant_resume_mismatch",
                               message: "The partial participant scan does not match this source and scan configuration.")
            }
        }

        if partial == nil, let data = cache?.read(section, cancelled: cancelled),
           let saved = try? JSONDecoder().decode(ParticipantCachedScan.self, from: data),
           saved.analysis.schemaVersion == 1,
           !options.includeScenes || saved.sceneReport != nil {
            progress?(source.duration)
            try verifySource()
            if cancelled() {
                return ParticipantScanResult(state: .paused, source: source, configuration: configuration, analysis: nil,
                                             sceneReport: nil, analysisIdentity: fingerprint)
            }
            return ParticipantScanResult(state: .upToDate, source: source, configuration: configuration, analysis: saved.analysis,
                                         sceneReport: saved.sceneReport.map {
                                             let report = $0.forSource(file)
                                             return cache?.restoringViewNames(to: report, cancelled: cancelled) ?? report
                                         }, analysisIdentity: fingerprint)
        }

        try verifySource()
        if cancelled() {
            return ParticipantScanResult(state: .paused, source: source, configuration: configuration, analysis: partial?.analysis,
                                         sceneReport: nil, analysisIdentity: fingerprint)
        }
        let scan = try TileTrailScan(media: media, source: source, options: options,
                                     cancelled: cancelled, progress: progress)
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
            let replayPosition = result.analysis.resumeAt ?? source.duration
            if result.analysis.observations.count < old.count || replayPosition < checkpointPosition {
                if result.state == .paused {
                    return ParticipantScanResult(state: .paused, source: source, configuration: configuration,
                                                 analysis: checkpoint, sceneReport: nil, analysisIdentity: fingerprint)
                }
                throw CutError(code: "participant_resume_mismatch",
                               message: "The saved participant scan extends beyond the replayed source.")
            }
        }
        let sceneReport = result.sceneReport.map { cache?.restoringViewNames(to: $0, cancelled: cancelled) ?? $0 }
        if result.state == .completed {
            cache?.saveAutomatically([section: try encoder.encode(ParticipantCachedScan(analysis: result.analysis,
                                                                                         sceneReport: result.sceneReport))],
                                     retainingLatest: ["participant_tracking.v1.": 12], cancelled: cancelled)
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
        var buffer = tiletrail_buffer_t()
        var failure = tiletrail_error_t()
        let status = data.withUnsafeBytes { bytes in
            ruleData.withUnsafeBytes { ruleBytes in
                tiletrail_scene_markers_json(bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count),
                                             ruleBytes.bindMemory(to: UInt8.self).baseAddress, UInt64(ruleBytes.count),
                                             &buffer, &failure)
            }
        }
        defer { tiletrail_buffer_free(&buffer) }
        try checkTileTrail(status, &failure)
        return try ParticipantSourceTime.decodeOriginalClock([ParticipantSceneMarker].self,
                                                               data: buffer.contents, origin: result.source.origin)
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
private struct ParticipantCacheKey: Encodable {
    let detector = "tiletrail-0.1.0"
    let inode: UInt64
    let stamp: SceneSourceStamp
    let stream: Int
    let origin: RationalTime
    let timeBase: RationalTime
    let duration: RationalTime
    let transform: ParticipantDisplayTransform
    let backend: ParticipantBackendMode
    let sampling: ParticipantSampling
}

private struct ParticipantCachedScan: Codable {
    let analysis: ParticipantTrackingResult
    let sceneReport: SceneReport?
}

private func checkTileTrail(_ status: Int32, _ error: inout tiletrail_error_t) throws {
    guard status != TILETRAIL_OK else { return }
    let message = withUnsafeBytes(of: &error.message) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    let code = status == TILETRAIL_GPU_UNAVAILABLE ? "participant_gpu_unavailable" : "participant_analysis_failed"
    throw CutError(code: code, message: message)
}

private extension tiletrail_buffer_t {
    var contents: Data {
        get throws {
            guard let data, let count = Int(exactly: len) else {
                throw CutError(code: "participant_result_invalid", message: "TileTrail returned an invalid result.")
            }
            return Data(bytes: data, count: count)
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
    let handle: OpaquePointer
    let baseNum: UInt32
    let baseDen: UInt32
    let end: tiletrail_timestamp_t
    let sampling: ParticipantSampling

    var failure: Error?
    var deviceLoss: RationalTime?
    private var holes: [Range<RationalTime>] = []
    private var previous: (time: RationalTime, end: RationalTime?, valid: Bool)?
    private var unknownTimestamp = false
    private var progressCount = 0
    private var lastSample: RationalTime?

    init(media: MediaInfo, source: ParticipantScanSource, options: ParticipantScanOptions,
         cancelled: @escaping () -> Bool, progress: ((RationalTime) -> Void)?) throws {
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
        end = try tiletrail_timestamp_t(source.origin.adding(source.duration))
        let mode: Int
        switch options.backend {
        case .automatic: mode = TILETRAIL_MODE_AUTO
        case .cpu: mode = TILETRAIL_MODE_CPU_ONLY
        case .gpuRequired: mode = TILETRAIL_MODE_GPU_REQUIRED
        }
        var config = tiletrail_config_t(mode: UInt32(mode), sampling: UInt32(
            options.sampling == .sparse ? TILETRAIL_SAMPLING_SPARSE : TILETRAIL_SAMPLING_EVERY_FRAME))
        var result: OpaquePointer?
        var error = tiletrail_error_t()
        try checkTileTrail(tiletrail_analyzer_create(&config, try tiletrail_timestamp_t(source.origin), &result, &error), &error)
        guard let result else {
            throw CutError(code: "participant_analysis_failed", message: "TileTrail did not return an analyzer.")
        }
        handle = result
    }

    deinit {
        tiletrail_analyzer_free(handle)
    }

    func run(_ url: URL) throws -> (state: ParticipantScanResult.State, analysis: ParticipantTrackingResult,
                                    sceneReport: SceneReport?) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let frame: MPParticipantFrameVisit = { pointer, pts, duration, rgb, width, height, stride, sarNum, sarDen in
            let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
            do {
                try scan.frame(pts: pts, duration: duration, rgb: rgb, width: width, height: height,
                               stride: stride, sarNum: sarNum, sarDen: sarDen)
                return scan.deviceLoss == nil ? 0 : 1
            } catch {
                scan.failure = error
                return 1
            }
        }
        let scene: MPSceneVisit = { pointer, pts, feature in
            guard let feature else { return }
            let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
            do { try scan.scenes?.marker(pts: pts, feature: feature) }
            catch { scan.failure = error }
        }
        var decoderMessage = [CChar](repeating: 0, count: 256)
        var unplacedDamage: Int32 = 0
        let status = url.withUnsafeFileSystemRepresentation { path in
            mp_participant_scan(path, Int32(source.stream), { pointer in
                let scan = Unmanaged<TileTrailScan>.fromOpaque(pointer!).takeUnretainedValue()
                return scan.failure != nil || scan.cancelled() ? 1 : 0
            }, frame, scenes == nil ? nil : scene, context, &unplacedDamage, &decoderMessage, decoderMessage.count)
        }
        if let failure { throw failure }
        let paused = deviceLoss == nil && (status == MP_SCENE_SCAN_CANCELLED || cancelled())
        if status != 0 && !paused && deviceLoss == nil {
            throw CutError(code: "participant_decode_failed", message: String(cString: decoderMessage))
        }

        if let deviceLoss {
            addHole(from: deviceLoss, to: source.duration)
        } else if let previous {
            let tail = previous.end ?? (paused || !previous.valid ? previous.time : source.duration)
            addHole(from: previous.valid ? tail : previous.time, to: source.duration)
        } else {
            addHole(from: .zero, to: source.duration)
        }
        if unknownTimestamp || unplacedDamage != 0 {
            // Damage without a decoded presentation timestamp cannot be
            // assigned to a narrower source interval.
            holes = [.zero..<source.duration]
        }
        var buffer = tiletrail_buffer_t()
        var error = tiletrail_error_t()
        defer { tiletrail_buffer_free(&buffer) }
        try checkTileTrail(tiletrail_analyzer_result_json(handle, end, &buffer, &error), &error)
        var analysis = try ParticipantSourceTime.decodeOriginalClock(ParticipantTrackingResult.self,
                                                                      data: buffer.contents, origin: source.origin)
        guard analysis.schemaVersion == 1, analysis.start == .zero, analysis.end == source.duration else {
            throw CutError(code: "participant_result_invalid", message: "TileTrail returned an unexpected result clock or schema version.")
        }
        analysis.coverage = coverage(analysis.coverage)
        if paused {
            analysis.resumeAt = unknownTimestamp || unplacedDamage != 0 ? .zero : (previous?.valid == true ? previous?.end : nil)
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

    func frame(pts: Int64, duration: Int64, rgb: UnsafePointer<UInt8>?,
               width: Int32, height: Int32, stride: Int32, sarNum: Int32, sarDen: Int32) throws {
        guard pts != .min else {
            unknownTimestamp = true
            return
        }
        let timestamp = tiletrail_timestamp_t(pts: pts, numerator: baseNum, denominator: baseDen)
        let time = try timestamp.localTime(origin: source.origin)
        guard time >= .zero, time < source.duration else { return }
        if let previous {
            guard time >= previous.time else {
                throw CutError(code: "participant_clock_unsupported", message: "Decoded video frames have out-of-order presentation timestamps.")
            }
            if time == previous.time {
                self.previous = (time, previous.end, false)
                return
            }
            let lastEnd = previous.end ?? time
            if previous.valid { addHole(from: lastEnd, to: time) }
            else { addHole(from: previous.time, to: time) }
        } else {
            addHole(from: .zero, to: time)
        }

        let frameEnd = duration > 0
            ? min(source.duration, try time.adding(RationalTime(numerator: duration).multiplied(by: source.timeBase)))
            : nil
        previous = (time, frameEnd, rgb != nil)
        guard let rgb else { return }
        if sampling == .sparse, let lastSample, let elapsed = try? time.subtracting(lastSample),
           elapsed < RationalTime(numerator: 1, denominator: 5) {
            reportProgress(time)
            return
        }

        var frame = tiletrail_frame_t(data: rgb, len: UInt64(stride) * UInt64(height),
                                      stride: UInt64(stride), width: UInt32(width), height: UInt32(height),
                                      format: UInt32(TILETRAIL_FORMAT_RGB24), rotation: source.transform.rotation.clockwiseDegrees,
                                      pixel_aspect_num: sarNum > 0 && sarDen > 0 ? UInt32(sarNum) : source.transform.pixelAspectNum,
                                      pixel_aspect_den: sarNum > 0 && sarDen > 0 ? UInt32(sarDen) : source.transform.pixelAspectDen,
                                      timestamp: timestamp)
        var error = tiletrail_error_t()
        let status = tiletrail_analyzer_push(handle, &frame, &error)
        if status == TILETRAIL_DEVICE_LOST {
            deviceLoss = error.has_resume != 0 ? try error.resume_at.localTime(origin: source.origin) : time
            return
        }
        try checkTileTrail(status, &error)
        lastSample = time
        reportProgress(time)
    }

    private func reportProgress(_ time: RationalTime) {
        if progressCount % 8 == 0 { progress?(time) }
        progressCount += 1
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

#if canImport(CTileTrail)
private extension StreamInfo {
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
#endif
