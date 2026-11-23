import Foundation
import MPCutCore

struct SceneExportInput: Decodable {
    struct Scene: Decodable {
        let number: Int?
        let view: Int
        let start: RationalTime
        let end: RationalTime

        enum CodingKeys: String, CodingKey, CaseIterable {
            case number, view, start, end
            case startPTS = "start_pts", startSeconds = "start_seconds", viewLabel = "view_label"
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.requestFields(CodingKeys.self, in: "Scene")
            number = try fields.decodeIfPresent(Int.self, forKey: .number)
            view = try fields.decode(Int.self, forKey: .view)
            start = try fields.decode(RationalTime.self, forKey: .start)
            end = try fields.decode(RationalTime.self, forKey: .end)
        }

        init(number: Int?, view: Int, start: RationalTime, end: RationalTime) {
            self.number = number
            self.view = view
            self.start = start
            self.end = end
        }

        init(_ scene: DetectedScene) {
            number = scene.number
            view = scene.view
            start = scene.start
            end = scene.end
        }
    }

    let ok: Bool?
    let file: String
    let sourceStamp: SceneSourceStamp?
    let duration: RationalTime?
    var scenes: [Scene]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, file, duration, scenes, origin, views
        case sourceStamp = "source_stamp", timeBase = "time_base", viewCount = "view_count"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self, in: "Scene report")
        ok = try fields.decodeIfPresent(Bool.self, forKey: .ok)
        file = try fields.decode(String.self, forKey: .file)
        duration = try fields.decodeIfPresent(RationalTime.self, forKey: .duration)
        sourceStamp = try fields.decodeIfPresent(SceneSourceStamp.self, forKey: .sourceStamp)
        scenes = try fields.decode([Scene].self, forKey: .scenes)
    }

    init(file: String, scenes: [Scene]) {
        self.file = file
        self.scenes = scenes
        ok = true
        sourceStamp = nil
        duration = nil
    }

    init(_ report: SceneReport) {
        ok = report.ok
        file = report.file
        sourceStamp = report.sourceStamp
        duration = report.duration
        scenes = report.scenes.map(Scene.init)
    }

    func jobs(for media: MediaInfo, grouping: SceneGrouping) throws -> [SceneExportJob] {
        guard ok != false, !scenes.isEmpty else {
            throw CLIError("invalid_json", "Supply a successful scene report with at least one scene.")
        }
        if let sourceStamp, sourceStamp != SceneSourceStamp(media: media) {
            throw CutError(code: "source_changed", message: "The source changed since the scene report was created.")
        }
        if let duration, duration != media.duration {
            throw CutError(code: "source_changed", message: "The source duration differs from the scene report.")
        }

        var previousEnd = RationalTime.zero
        var previousNumber = 0
        let shots: [SceneExportJob] = try scenes.enumerated().map { offset, shot in
            let number = shot.number ?? offset + 1
            guard number > previousNumber, shot.view > 0,
                  shot.start >= previousEnd, shot.end > shot.start, shot.end <= media.duration else {
                throw CutError(code: "invalid_range",
                               message: "Scene report entry \(offset + 1) must have an increasing number, a positive view ID and a non-overlapping range inside the source.",
                               segment: offset + 1)
            }
            previousEnd = shot.end
            previousNumber = number
            return SceneExportJob(view: shot.view, sceneNumbers: [number],
                                  clips: [ClipRequest(file: media.url, from: shot.start, to: shot.end)],
                                  grouping: .scene)
        }
        guard grouping == .view else { return shots }
        var views: [Int: SceneExportJob] = [:]
        var order: [Int] = []
        for shot in shots {
            if views[shot.view] == nil { order.append(shot.view) }
            views[shot.view, default: SceneExportJob(view: shot.view, sceneNumbers: [], clips: [], grouping: .view)]
                .append(shot)
        }
        return order.compactMap { views[$0] }
    }
}

struct SceneExportJob {
    let view: Int
    var sceneNumbers: [Int]
    var clips: [ClipRequest]
    let grouping: SceneGrouping

    var viewLabel: String { SceneView.label(for: view) }

    var outputSuffix: String {
        let index = grouping == .view ? view : sceneNumbers[0]
        return "\(grouping.rawValue)-\(String(format: "%03ld", index))-\(viewLabel)"
    }

    mutating func append(_ shot: SceneExportJob) {
        sceneNumbers.append(contentsOf: shot.sceneNumbers)
        clips.append(contentsOf: shot.clips)
    }
}
