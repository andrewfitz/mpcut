import Foundation
import MediaProbe

public struct DetectedScene: Encodable, Sendable {
    public let number: Int
    public let startPTS: Int64
    public let start: RationalTime
    public let startSeconds: Double
    public let end: RationalTime
    public let view: Int
    public let viewLabel: String
}

public struct SceneView: Encodable, Sendable {
    public let view: Int
    public let label: String
    public let sceneNumbers: [Int]
    public let name: String?

    init(view: Int, label: String, sceneNumbers: [Int], name: String? = nil) {
        self.view = view
        self.label = label
        self.sceneNumbers = sceneNumbers
        self.name = name
    }

    public static func label(for view: Int) -> String {
        var value = view
        var letters: [UInt8] = []
        while value > 0 {
            value -= 1
            letters.append(UInt8(value % 26) + 65)
            value /= 26
        }
        return String(decoding: letters.reversed(), as: UTF8.self)
    }
}

public struct SceneSourceStamp: Codable, Equatable, Sendable {
    public let bytes: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int

    public init(media: MediaInfo) {
        self.init(identity: media.identity)
    }

    init(identity: SourceIdentity) {
        bytes = identity.size
        modifiedSeconds = identity.modifiedSeconds
        modifiedNanoseconds = identity.modifiedNanoseconds
    }
}

public struct SceneReport: Encodable, Sendable {
    public let ok = true
    public let file: String
    public let sourceStamp: SceneSourceStamp
    public let timeBase: RationalTime
    public let origin: RationalTime
    public let duration: RationalTime
    public let scenes: [DetectedScene]
    public let viewCount: Int
    public private(set) var views: [SceneView]

    public mutating func setViewName(_ name: String?, for view: Int) {
        guard let index = views.firstIndex(where: { $0.view == view }) else { return }
        let existing = views[index]
        views[index] = SceneView(view: existing.view, label: existing.label,
                                 sceneNumbers: existing.sceneNumbers, name: name)
    }
}

private final class SceneCollector {
    let media: MediaInfo
    let cancelled: () -> Bool
    let progress: ((Double) -> Void)?
    let onScene: (RationalTime, Int) -> Void
    let onReset: () -> Void
    var starts: [(Int64, RationalTime, Int)] = []
    var layouts: [UInt8] = []
    var failure: Error?

    init(_ media: MediaInfo, cancelled: @escaping () -> Bool, progress: ((Double) -> Void)?,
         onScene: @escaping (RationalTime, Int) -> Void, onReset: @escaping () -> Void) {
        self.media = media
        self.cancelled = cancelled
        self.onScene = onScene
        self.onReset = onReset
        self.progress = progress
    }

    func visit(pts: Int64, feature: UnsafePointer<UInt8>?) throws {
        guard failure == nil, !cancelled() else { return }
        if feature == nil, pts == .min {
            starts.removeAll(keepingCapacity: true)
            layouts.removeAll(keepingCapacity: true)
            onReset()
            return
        }
        if feature == nil, progress == nil { return }
        let absolute = try RationalTime(numerator: pts).multiplied(by: media.video.timeBase)
        let time = try absolute.subtracting(media.origin)
        guard let feature else {
            progress?(min(1, max(0, time.seconds / media.duration.seconds)))
            return
        }
        guard time < media.duration else { return }
        let start = starts.isEmpty ? .zero : time
        guard starts.last.map({ start > $0.1 }) ?? true else { return }
        let count = Int(MP_SCENE_FEATURE_SIZE)
        let viewCount = layouts.count / count
        let view = layouts.withUnsafeBufferPointer { mp_scene_match_view(feature, $0.baseAddress, viewCount) }
        if view == viewCount {
            layouts.append(contentsOf: UnsafeBufferPointer(start: feature, count: count))
        }
        starts.append((pts, start, view + 1))
        onScene(start, view + 1)
    }
}

private enum SceneClockError: Error { case needsIndex }

public enum SceneAnalysis {
    /// A data-only scan can use a container clock once its packet timestamps verify it.
    public static func scan(_ url: URL, useSidecar: Bool = true,
                            cancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> SceneReport {
        guard url.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local video file.") }
        let file = url.standardizedFileURL
        let identity = try SourceIdentity(file)
        if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
        let cache = (useSidecar && AnalysisSidecar.readsEnabled ? try? AnalysisSidecar(source: file) : nil)
            .flatMap { $0.identity == identity ? $0 : nil }
        if let cache {
            if let report = cache.sceneReport(cancelled: cancelled) {
                if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
                guard (try? SourceIdentity(file)) == identity else {
                    throw CutError(code: "source_changed", message: "The source changed while loading scene analysis.")
                }
                return report
            }
            // The saved index header has an exact video clock, even when its
            // large frame and audio packet arrays are left on disk.
            if let indexed = try cache.loadIndex(detail: .preview, cancelled: cancelled) {
                return try scan(indexed, verifyClock: false, cancelled: cancelled,
                                progress: nil, onScene: nil, onReset: nil, cache: cache)
            }
        }
        do {
            let preview = try Probe.read(file, keyframes: false, previewOnly: true,
                                         expectedIdentity: identity, cancelled: cancelled)
            return try scan(preview, verifyClock: true, cancelled: cancelled,
                            progress: nil, onScene: nil, onReset: nil, cache: cache)
        } catch is SceneClockError {
            // Some header estimates exclude video, or use an unverified origin.
        } catch let error as CutError where error.code == "probe_failed" {
            // Some containers only reveal a usable clock after stream inspection.
        }
        let media = try Probe.read(file, keyframes: false, expectedIdentity: identity, cancelled: cancelled)
        return try scan(media, verifyClock: false, cancelled: cancelled,
                        progress: nil, onScene: nil, onReset: nil, cache: cache)
    }

    public static func scan(_ media: MediaInfo, useSidecar: Bool = true, cancelled: @escaping () -> Bool = { Task.isCancelled },
                            progress: ((Double) -> Void)? = nil,
                            onScene: ((RationalTime, Int) -> Void)? = nil,
                            onReset: (() -> Void)? = nil) throws -> SceneReport {
        if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
        if media.hasProvisionalClock {
            // Early playback can use a container estimate that excludes later pictures
            // or includes a longer soundtrack. Never publish that clock as verified analysis.
            guard (try? SourceIdentity(media.url)) == media.identity else {
                throw CutError(code: "source_changed", message: "The source changed since inspection.")
            }
            let exact = try Probe.read(media.url, keyframes: false, expectedIdentity: media.identity, cancelled: cancelled)
            return try scan(exact, useSidecar: useSidecar, cancelled: cancelled, progress: progress, onScene: onScene, onReset: onReset)
        }
        let cache = useSidecar && AnalysisSidecar.readsEnabled ? AnalysisSidecar(media: media) : nil
        if let report = cache?.sceneReport(for: media, cancelled: cancelled) {
            if let onScene {
                for scene in report.scenes {
                    if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
                    onScene(scene.start, scene.view)
                }
            }
            if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
            guard (try? SourceIdentity(media.url)) == media.identity else {
                throw CutError(code: "source_changed", message: "The source changed while loading scene analysis.")
            }
            progress?(1)
            return report
        }
        return try scan(media, verifyClock: false, cancelled: cancelled, progress: progress,
                        onScene: onScene, onReset: onReset, cache: cache)
    }

    private static func scan(_ media: MediaInfo, verifyClock: Bool, cancelled: @escaping () -> Bool,
                             progress: ((Double) -> Void)?,
                             onScene: ((RationalTime, Int) -> Void)?,
                             onReset: (() -> Void)?, cache: AnalysisSidecar?) throws -> SceneReport {
        guard media.hasVideo else { throw CutError(code: "no_video", message: "Scene detection requires a video track.") }
        func checkSource() throws {
            guard (try? SourceIdentity(media.url)) == media.identity else {
                throw CutError(code: "source_changed", message: "The source changed since inspection.")
            }
        }
        try checkSource()
        let collector = SceneCollector(media, cancelled: cancelled, progress: progress,
                                       onScene: onScene ?? { _, _ in }, onReset: onReset ?? {})
        // A decoder can restart after publishing provisional markers. Existing
        // live observers without a reset handler keep the single-pass callback contract.
        let allowAssetReader = onScene == nil || onReset != nil
        let context = Unmanaged.passUnretained(collector).toOpaque()
        var error = [CChar](repeating: 0, count: 256)
        var timing = MPSceneTiming()
        let status = withUnsafeMutablePointer(to: &timing) { timing in
            mp_scene_scan(media.url.path, Int32(media.video.index), allowAssetReader ? 1 : 0, { pointer in
                let collector = Unmanaged<SceneCollector>.fromOpaque(pointer!).takeUnretainedValue()
                return collector.failure != nil || collector.cancelled() ? 1 : 0
            }, { pointer, pts, feature in
                let collector = Unmanaged<SceneCollector>.fromOpaque(pointer!).takeUnretainedValue()
                do { try collector.visit(pts: pts, feature: feature) }
                catch { collector.failure = error }
            }, context, verifyClock ? timing : nil, &error, error.count)
        }
        if let failure = collector.failure { throw failure }
        if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
        try checkSource()
        var duration = media.duration
        if verifyClock, status >= 0 {
            // A full index uses the first packet by presentation time when the
            // stream header has no start. Stream analysis can infer a different start.
            guard timing.valid != 0, timing.tb_den > 0, timing.tb_num > 0,
                  media.video.hasDeclaredStart || timing.first_pts == timing.origin else {
                throw SceneClockError.needsIndex
            }
            let base = RationalTime(numerator: Int64(timing.tb_num), denominator: Int64(timing.tb_den))
            let origin = try RationalTime(numerator: timing.origin).multiplied(by: base)
            let end = try RationalTime(numerator: timing.end).multiplied(by: base)
            let videoDuration = try end.subtracting(origin)
            guard media.video.timeBase == base, media.origin == origin, videoDuration > .zero,
                  videoDuration <= duration else { throw SceneClockError.needsIndex }
            if videoDuration < duration {
                // A longer audio track can inflate the header-only estimate.
                // All candidates were collected through the verified video end.
                guard collector.starts.allSatisfy({ $0.0 < timing.end }) else { throw SceneClockError.needsIndex }
                duration = videoDuration
            }
        }
        guard status >= 0, !collector.starts.isEmpty else {
            throw CutError(code: "scene_analysis_failed", message: "Could not analyze this video. " + String(cString: error))
        }
        let viewCount = collector.layouts.count / Int(MP_SCENE_FEATURE_SIZE)
        let labels = (0..<viewCount).map { SceneView.label(for: $0 + 1) }
        var sceneNumbers = Array(repeating: [Int](), count: viewCount)
        let scenes = try collector.starts.enumerated().map { i, item in
            if i.isMultiple(of: 256), cancelled() {
                throw CutError(code: "cancelled", message: "Scene analysis was cancelled.")
            }
            let end = i + 1 < collector.starts.count ? collector.starts[i+1].1 : duration
            sceneNumbers[item.2 - 1].append(i + 1)
            return DetectedScene(number: i + 1, startPTS: item.0, start: item.1, startSeconds: item.1.seconds,
                                 end: end, view: item.2, viewLabel: labels[item.2 - 1])
        }
        let views = sceneNumbers.indices.map { i in
            SceneView(view: i + 1, label: labels[i], sceneNumbers: sceneNumbers[i])
        }
        let report = SceneReport(file: media.url.path, sourceStamp: SceneSourceStamp(media: media),
                                 timeBase: media.video.timeBase, origin: media.origin,
                                 duration: duration, scenes: scenes, viewCount: views.count, views: views)
        guard let cache else {
            if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
            try checkSource()
            progress?(1)
            return report
        }
        let restored = cache.restoringViewNames(to: report, cancelled: cancelled)
        if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
        try checkSource()
        cache.saveAutomatically(try AnalysisSidecar.sceneSections(for: restored), cancelled: cancelled)
        if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
        try checkSource()
        progress?(1)
        return restored
    }
}
