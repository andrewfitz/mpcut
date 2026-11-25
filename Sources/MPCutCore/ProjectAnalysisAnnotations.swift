import Foundation

/// Source-clock evidence retained by an editor's decisions. Rebuildable detector
/// output belongs in the recording cache until a user names one of its views.
public struct ProjectAnalysisAnnotations: Codable, Equatable, Sendable {
    public struct SilenceThreshold: Codable, Equatable, Sendable {
        public var file: String
        public var sourceStamp: SceneSourceStamp
        public var sourceEvidence: AnalysisSourceEvidence
        public var stream: Int
        public var thresholdDB: Double

        enum CodingKeys: String, CodingKey {
            case file, stream
            case sourceEvidence = "source_evidence"
            case sourceStamp = "source_stamp"
            case thresholdDB = "threshold_db"
        }
    }

    private var storedPauseReviews: [ProjectPauseReview]?
    public var pauseReviews: [ProjectPauseReview] {
        get { storedPauseReviews ?? [] }
        set { storedPauseReviews = newValue.isEmpty ? nil : newValue }
    }

    public var scenes: [SceneReport] = []
    public var silence: [SilenceThreshold] = []
    public var multicamThresholdDB: Double?

    enum CodingKeys: String, CodingKey {
        case storedPauseReviews = "pause_reviews"
        case scenes, silence
        case multicamThresholdDB = "multicam_threshold_db"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_analysis_annotations")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        scenes = try fields.decode([SceneReport].self, forKey: .scenes)
        silence = try fields.decode([SilenceThreshold].self, forKey: .silence)
        if fields.contains(.storedPauseReviews) {
            pauseReviews = try fields.decode([ProjectPauseReview].self, forKey: .storedPauseReviews)
        }
        if fields.contains(.multicamThresholdDB) {
            multicamThresholdDB = try fields.decode(Double.self, forKey: .multicamThresholdDB)
        }
    }

    public var isEmpty: Bool {
        scenes.isEmpty && silence.isEmpty && multicamThresholdDB == nil && pauseReviews.isEmpty
    }

    package func evidence(for path: String) -> Set<AnalysisSourceEvidence> {
        var result = Set(scenes.lazy.filter { $0.file == path }.compactMap(\.sourceEvidence))
        result.formUnion(silence.lazy.filter { $0.file == path }.map(\.sourceEvidence))
        for review in pauseReviews {
            result.formUnion(review.sources.lazy.filter { $0.file == path }.map(\.evidence))
        }
        return result
    }

    /// Warm the generation-bound digest cache during background source preparation.
    package func prepareEvidence(for media: MediaInfo) {
        for proof in evidence(for: media.url.path) { _ = proof.matches(media) }
    }

    public func scene(for media: MediaInfo) -> SceneReport? {
        guard let report = scenes.first(where: {
            $0.file == media.url.path && $0.matchesSceneClock(media)
                && $0.sourceEvidence?.stream == media.videoStream?.index && $0.sourceEvidence?.matches(media) == true
        }) else { return nil }
        return report.sourceStamp == SceneSourceStamp(media: media) ? report : report.forRefreshedMedia(media)
    }

    @discardableResult
    public mutating func setScene(_ report: SceneReport, for media: MediaInfo) -> Bool {
        guard report.file == media.url.path, report.matchesSceneClock(media),
              report.scenes.first?.start == .zero, report.scenes.last?.end == report.duration,
              let stream = media.videoStream?.index else { return false }
        let evidence: AnalysisSourceEvidence
        if let existing = report.sourceEvidence {
            guard existing.stream == stream, existing.matches(media) else { return false }
            evidence = existing
        } else {
            guard report.sourceStamp == SceneSourceStamp(media: media),
                  let current = AnalysisSourceEvidence(media: media, stream: stream) else { return false }
            evidence = current
        }
        var reviewed = report
        reviewed.sourceEvidence = evidence
        scenes.removeAll {
            $0.file == media.url.path && $0.sourceEvidence?.stream == stream && $0.sourceEvidence?.matches(media) == true
        }
        if reviewed.views.contains(where: { $0.name != nil }) { scenes.append(reviewed) }
        return true
    }

    public func threshold(for media: MediaInfo, stream: Int) -> Double? {
        silence.first { $0.file == media.url.path && $0.stream == stream && $0.sourceEvidence.matches(media) }?.thresholdDB
    }

    public func needsThresholdReview(for media: MediaInfo, stream: Int) -> Bool {
        silence.contains { $0.file == media.url.path && $0.stream == stream } && threshold(for: media, stream: stream) == nil
    }

    public func needsSceneReview(for media: MediaInfo) -> Bool {
        scenes.contains { $0.file == media.url.path } && scene(for: media) == nil
    }

    @discardableResult
    public mutating func setThreshold(_ level: Double?, for media: MediaInfo, stream: Int) -> Bool {
        guard level.map({ (-120...0).contains($0) }) ?? true, media.audio.contains(where: { $0.stream.index == stream }),
              let evidence = AnalysisSourceEvidence(media: media, stream: stream) else { return false }
        silence.removeAll { $0.file == media.url.path && $0.stream == stream && $0.sourceEvidence.matches(media) }
        if let level {
            silence.append(.init(file: media.url.path, sourceStamp: SceneSourceStamp(media: media),
                                 sourceEvidence: evidence, stream: stream, thresholdDB: level))
        }
        return true
    }

    package var protectedPaths: [(String, String)] {
        scenes.map { ("scene review", $0.file) } + silence.map { ("silence threshold", $0.file) }
            + pauseReviews.flatMap { $0.sources.map { ("pause review", $0.file) } }
    }

    package func mappingPaths(_ transform: (String) -> String) -> Self {
        var copy = self
        for index in copy.scenes.indices { copy.scenes[index].file = transform(copy.scenes[index].file) }
        for index in copy.silence.indices { copy.silence[index].file = transform(copy.silence[index].file) }
        copy.pauseReviews = pauseReviews.map { review in
            var next = review
            for index in next.sources.indices { next.sources[index].file = transform(next.sources[index].file) }
            return next
        }
        return copy
    }

    func validate() throws {
        struct Source: Hashable {
            let file: String
            let evidence: AnalysisSourceEvidence
            let stream: Int?
        }
        for review in pauseReviews { try review.validate() }
        var seen = Set<Source>()
        let invalid = CutError(code: "invalid_analysis_annotations", message: "The saved analysis choices contain invalid source evidence or values.")
        guard multicamThresholdDB.map({ (-120...0).contains($0) }) ?? true else { throw invalid }
        for item in silence {
            guard ProjectFile.validMediaPath(item.file), item.stream == item.sourceEvidence.stream, (-120...0).contains(item.thresholdDB),
                  seen.insert(.init(file: item.file, evidence: item.sourceEvidence, stream: item.stream)).inserted else { throw invalid }
        }
        for report in scenes {
            guard let evidence = report.sourceEvidence, ProjectFile.validMediaPath(report.file), report.viewCount == report.views.count,
                  report.timeBase > .zero, report.duration > .zero,
                  report.scenes.first?.start == .zero, report.scenes.last?.end == report.duration,
                  seen.insert(.init(file: report.file, evidence: evidence, stream: nil)).inserted else { throw invalid }
            let ids = Set(report.views.map(\.view))
            guard ids.count == report.views.count, ids.allSatisfy({ $0 > 0 }) else { throw invalid }
            var members: [Int: [Int]] = [:]
            var numbers = Set<Int>()
            var previousEnd = RationalTime.zero
            for scene in report.scenes {
                guard scene.number > 0, numbers.insert(scene.number).inserted, ids.contains(scene.view),
                      scene.start >= previousEnd, scene.start < scene.end,
                      scene.end <= report.duration, scene.start.seconds == scene.startSeconds else { throw invalid }
                members[scene.view, default: []].append(scene.number)
                previousEnd = scene.end
            }
            guard report.views.allSatisfy({ members[$0.view] == $0.sceneNumbers }) else { throw invalid }
        }
    }
}

private extension SceneReport {
    func matchesSceneClock(_ media: MediaInfo) -> Bool {
        timeBase == media.videoStream?.timeBase
            && (media.hasProvisionalClock || (origin == media.origin && duration == media.duration))
    }
}

extension ProjectAnalysisAnnotations.SilenceThreshold {
    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_analysis_annotations")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        file = try fields.decode(String.self, forKey: .file)
        sourceStamp = try fields.decode(SceneSourceStamp.self, forKey: .sourceStamp)
        sourceEvidence = try fields.decode(AnalysisSourceEvidence.self, forKey: .sourceEvidence)
        stream = try fields.decode(Int.self, forKey: .stream)
        thresholdDB = try fields.decode(Double.self, forKey: .thresholdDB)
    }
}

extension CutProject {
    public var analysisAnnotations: ProjectAnalysisAnnotations {
        get {
            switch self {
            case .sequence: return .init()
            case .stillSequence(let value): return value.analysisAnnotations
            case .multicam(let value): return value.analysisAnnotations
            }
        }
        set {
            switch self {
            case .multicam(var value):
                value.analysisAnnotations = newValue
                self = .multicam(value)
            case .sequence, .stillSequence:
                guard newValue != analysisAnnotations, var value = stillSequenceValue else { return }
                value.analysisAnnotations = newValue
                if newValue.isEmpty && !value.hasStillContent && value.stillAudioReference == nil
                    && value.sourceSelects.isEmpty && value.transcripts.isEmpty && value.participants.isEmpty {
                    self = .sequence(value.items.compactMap(\.source))
                } else {
                    self = .stillSequence(value)
                }
            }
        }
    }
}
