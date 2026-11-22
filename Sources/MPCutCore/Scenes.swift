import Foundation

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
    package var syntheticLeading: Bool = false

    private enum CodingKeys: String, CodingKey {
        case ok, file, sourceStamp, timeBase, origin, duration, scenes, viewCount, views
    }

    func forSource(_ url: URL) -> SceneReport {
        let path = url.standardizedFileURL.path
        guard file != path else { return self }
        return SceneReport(file: path, sourceStamp: sourceStamp, timeBase: timeBase, origin: origin,
                           duration: duration, scenes: scenes, viewCount: viewCount, views: views,
                           syntheticLeading: syntheticLeading)
    }

    public mutating func setViewName(_ name: String?, for view: Int) {
        guard let index = views.firstIndex(where: { $0.view == view }) else { return }
        let existing = views[index]
        views[index] = SceneView(view: existing.view, label: existing.label,
                                 sceneNumbers: existing.sceneNumbers, name: name)
    }
}

public enum SceneAnalysis {
    public static func scan(_ url: URL, useSidecar: Bool = true,
                            cancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> SceneReport {
        try completedReport(run(url, useSidecar: useSidecar, cancelled: cancelled))
    }

    public static func scan(_ media: MediaInfo, useSidecar: Bool = true,
                            allowAutomaticSave: @escaping () -> Bool = { true },
                            cancelled: @escaping () -> Bool = { Task.isCancelled },
                            progress: ((Double) -> Void)? = nil,
                            onScene: ((RationalTime, Int) -> Void)? = nil,
                            onReset: (() -> Void)? = nil) throws -> SceneReport {
        try completedReport(run(media, useSidecar: useSidecar, allowAutomaticSave: allowAutomaticSave,
                                cancelled: cancelled, progress: { progress?($0.fraction) },
                                onScene: onScene, onReset: onReset))
    }

    private static func completedReport(_ outcome: SceneScanOutcome) throws -> SceneReport {
        guard let report = outcome.report else {
            throw CutError(code: "cancelled", message: "Scene analysis was cancelled.")
        }
        return report
    }
}
