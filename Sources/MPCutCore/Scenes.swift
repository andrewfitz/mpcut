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
        bytes = media.identity.size
        modifiedSeconds = media.identity.modifiedSeconds
        modifiedNanoseconds = media.identity.modifiedNanoseconds
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
    public let views: [SceneView]
}

private final class SceneCollector {
    let media: MediaInfo
    let cancelled: () -> Bool
    let progress: (Double) -> Void
    let onScene: (RationalTime, Int) -> Void
    var starts: [(Int64, RationalTime, Int)] = []
    var layouts: [[UInt8]] = []
    var failure: Error?

    init(_ media: MediaInfo, cancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void,
         onScene: @escaping (RationalTime, Int) -> Void) {
        self.media = media
        self.cancelled = cancelled
        self.onScene = onScene
        self.progress = progress
    }

    func visit(pts: Int64, feature: UnsafePointer<UInt8>?) throws {
        let absolute = try RationalTime(numerator: pts).multiplied(by: media.video.timeBase)
        let time = try absolute.subtracting(media.origin)
        guard let feature else {
            progress(min(1, max(0, time.seconds / media.duration.seconds)))
            return
        }
        guard time < media.duration else { return }
        let start = starts.isEmpty ? .zero : time
        guard starts.last.map({ start > $0.1 }) ?? true else { return }
        let count = Int(MP_SCENE_FEATURE_SIZE)
        let current = UnsafeBufferPointer(start: feature, count: count)
        // Compare tile colors in their original positions so composition changes
        // (including a punch-in) can separate similar camera angles.
        var best: Int?
        // A four-percent mean channel deviation tolerates mild lighting and codec noise.
        var minimum = 255 * count / 25
        for (index, layout) in layouts.enumerated() {
            var difference = 0
            for i in current.indices {
                difference += abs(Int(current[i]) - Int(layout[i]))
                if difference >= minimum { break }
            }
            if difference < minimum {
                best = index
                minimum = difference
            }
        }
        let view = best ?? layouts.count
        if best == nil { layouts.append(Array(current)) }
        starts.append((pts, start, view + 1))
        onScene(start, view + 1)
    }
}

public enum SceneAnalysis {
    public static func scan(_ media: MediaInfo, cancelled: @escaping () -> Bool = { false },
                            progress: @escaping (Double) -> Void = { _ in },
                            onScene: @escaping (RationalTime, Int) -> Void = { _, _ in }) throws -> SceneReport {
        func checkSource() throws {
            guard try SourceIdentity(media.url) == media.identity else {
                throw CutError(code: "source_changed", message: "The source changed since inspection.")
            }
        }
        try checkSource()
        let collector = SceneCollector(media, cancelled: cancelled, progress: progress, onScene: onScene)
        let context = Unmanaged.passUnretained(collector).toOpaque()
        var error = [CChar](repeating: 0, count: 256)
        let status = mp_scene_scan(media.url.path, Int32(media.video.index), { pointer in
            let collector = Unmanaged<SceneCollector>.fromOpaque(pointer!).takeUnretainedValue()
            return collector.failure != nil || collector.cancelled() ? 1 : 0
        }, { pointer, pts, feature in
            let collector = Unmanaged<SceneCollector>.fromOpaque(pointer!).takeUnretainedValue()
            do { try collector.visit(pts: pts, feature: feature) }
            catch { collector.failure = error }
        }, context, &error, error.count)
        if let failure = collector.failure { throw failure }
        if cancelled() { throw CutError(code: "cancelled", message: "Scene analysis was cancelled.") }
        guard status >= 0, !collector.starts.isEmpty else {
            throw CutError(code: "scene_analysis_failed", message: "Could not analyze this video. " + String(cString: error))
        }
        try checkSource()
        let scenes = collector.starts.enumerated().map { i, item in
            let end = i + 1 < collector.starts.count ? collector.starts[i+1].1 : media.duration
            return DetectedScene(number: i + 1, startPTS: item.0, start: item.1, startSeconds: item.1.seconds,
                                 end: end, view: item.2, viewLabel: SceneView.label(for: item.2))
        }
        let views = Dictionary(grouping: scenes, by: \.view).sorted { $0.key < $1.key }.map { view, shots in
            SceneView(view: view, label: SceneView.label(for: view), sceneNumbers: shots.map(\.number))
        }
        return SceneReport(file: media.url.path, sourceStamp: SceneSourceStamp(media: media),
                           timeBase: media.video.timeBase, origin: media.origin,
                           duration: media.duration, scenes: scenes, viewCount: views.count, views: views)
    }
}
