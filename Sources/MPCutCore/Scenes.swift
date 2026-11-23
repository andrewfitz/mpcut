import Foundation

public struct DetectedScene: Codable, Sendable {
    public let number: Int
    public let startPTS: Int64
    public let start: RationalTime
    public let startSeconds: Double
    public let end: RationalTime
    public let view: Int
    public let viewLabel: String

    private enum CodingKeys: String, CodingKey {
        case number, start, end, view
        case startPTS = "start_pts"
        case startSeconds = "start_seconds"
        case viewLabel = "view_label"
    }
}

public struct SceneView: Codable, Sendable {
    public let view: Int
    public let label: String
    public let sceneNumbers: [Int]
    public let name: String?

    private enum CodingKeys: String, CodingKey {
        case view, label, name
        case sceneNumbers = "scene_numbers"
    }

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

public struct SceneSourceStamp: Codable, Hashable, Sendable {
    public let bytes: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int

    private enum CodingKeys: String, CodingKey {
        case bytes
        case modifiedSeconds = "modified_seconds"
        case modifiedNanoseconds = "modified_nanoseconds"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_source_stamp")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try fields.decode(Int64.self, forKey: .bytes)
        modifiedSeconds = try fields.decode(Int.self, forKey: .modifiedSeconds)
        modifiedNanoseconds = try fields.decode(Int.self, forKey: .modifiedNanoseconds)
    }

    public init(media: MediaInfo) {
        self.init(identity: media.identity)
    }

    init(identity: SourceIdentity) {
        bytes = identity.size
        modifiedSeconds = identity.modifiedSeconds
        modifiedNanoseconds = identity.modifiedNanoseconds
    }
}

public struct SceneReport: Codable, Sendable {
    public var ok: Bool { true }
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
        case ok, file, origin, duration, scenes, views
        case sourceStamp = "source_stamp"
        case timeBase = "time_base"
        case viewCount = "view_count"
    }

    func forSource(_ url: URL) -> SceneReport {
        let path = url.standardizedFileURL.path
        guard file != path else { return self }
        return SceneReport(file: path, sourceStamp: sourceStamp, timeBase: timeBase, origin: origin,
                           duration: duration, scenes: scenes, viewCount: viewCount, views: views,
                           syntheticLeading: syntheticLeading)
    }

    mutating func restoreViewNames(_ names: [Int: String]) {
        for index in views.indices {
            let view = views[index]
            guard view.name != names[view.view] else { continue }
            views[index] = SceneView(view: view.view, label: view.label, sceneNumbers: view.sceneNumbers,
                                     name: names[view.view])
        }
    }

    public mutating func setViewName(_ name: String?, for view: Int) {
        guard let index = views.firstIndex(where: { $0.view == view }) else { return }
        let existing = views[index]
        views[index] = SceneView(view: existing.view, label: existing.label,
                                 sceneNumbers: existing.sceneNumbers, name: name)
    }
}

extension SceneReport {
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(file: try fields.decode(String.self, forKey: .file),
                  sourceStamp: try fields.decode(SceneSourceStamp.self, forKey: .sourceStamp),
                  timeBase: try fields.decode(RationalTime.self, forKey: .timeBase),
                  origin: try fields.decode(RationalTime.self, forKey: .origin),
                  duration: try fields.decode(RationalTime.self, forKey: .duration),
                  scenes: try fields.decode([DetectedScene].self, forKey: .scenes),
                  viewCount: try fields.decode(Int.self, forKey: .viewCount),
                  views: try fields.decode([SceneView].self, forKey: .views))
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(file, forKey: .file)
        try fields.encode(sourceStamp, forKey: .sourceStamp)
        try fields.encode(timeBase, forKey: .timeBase)
        try fields.encode(origin, forKey: .origin)
        try fields.encode(duration, forKey: .duration)
        try fields.encode(scenes, forKey: .scenes)
        try fields.encode(viewCount, forKey: .viewCount)
        try fields.encode(views, forKey: .views)
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
