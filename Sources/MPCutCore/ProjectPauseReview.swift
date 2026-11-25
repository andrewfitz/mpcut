import Foundation

/// The exact detector span or manual take boundary selected by the editor.
public struct ProjectPauseReview: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case protect, retain, marker }

    public struct Source: Codable, Equatable, Hashable, Sendable {
        public var file: String
        public let sourceStamp: SceneSourceStamp
        public let evidence: AnalysisSourceEvidence
        public var stream: Int { evidence.stream }
        public var sourceID: String?
        public var offset: RationalTime?
        public var groupRange: MulticamRange?

        enum CodingKeys: String, CodingKey {
            case file, offset, evidence
            case sourceStamp = "source_stamp", sourceID = "source_id", groupRange = "group_range"
        }

        public init?(media: MediaInfo, stream: Int? = nil, sourceID: String? = nil,
                     offset: RationalTime? = nil, groupRange: MulticamRange? = nil) {
            guard let evidence = AnalysisSourceEvidence(media: media, stream: stream ?? media.primaryStream.index) else {
                return nil
            }
            file = media.url.path
            sourceStamp = SceneSourceStamp(media: media)
            self.evidence = evidence
            self.sourceID = sourceID
            self.offset = offset
            self.groupRange = groupRange
        }

        public init(from decoder: Decoder) throws {
            try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_analysis_annotations")
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            file = try fields.decode(String.self, forKey: .file)
            sourceStamp = try fields.decode(SceneSourceStamp.self, forKey: .sourceStamp)
            evidence = try fields.decode(AnalysisSourceEvidence.self, forKey: .evidence)
            sourceID = try fields.contains(.sourceID) ? fields.decode(String.self, forKey: .sourceID) : nil
            offset = try fields.contains(.offset) ? fields.decode(RationalTime.self, forKey: .offset) : nil
            groupRange = try fields.contains(.groupRange) ? fields.decode(MulticamRange.self, forKey: .groupRange) : nil
        }

        public func matches(_ media: MediaInfo) -> Bool {
            media.url.path == file && evidence.matches(media)
        }
    }

    public var occurrenceID: String?
    public let kind: Kind
    public var from: RationalTime
    public var to: RationalTime?
    public var retainedSeconds: Double?
    public var sources: [Source]

    enum CodingKeys: String, CodingKey {
        case occurrenceID = "occurrence_id", retainedSeconds = "retained_seconds"
        case kind, from, to, sources
    }

    public init(occurrenceID: String?, kind: Kind, from: RationalTime, to: RationalTime? = nil,
                retainedSeconds: Double? = nil, sources: [Source]) {
        self.occurrenceID = occurrenceID
        self.kind = kind
        self.from = from
        self.to = to
        self.retainedSeconds = retainedSeconds
        self.sources = sources
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_analysis_annotations")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        kind = try fields.decode(Kind.self, forKey: .kind)
        occurrenceID = try fields.contains(.occurrenceID) ? fields.decode(String.self, forKey: .occurrenceID) : nil
        from = try fields.decode(RationalTime.self, forKey: .from)
        to = try fields.contains(.to) ? fields.decode(RationalTime.self, forKey: .to) : nil
        retainedSeconds = try fields.contains(.retainedSeconds) ? fields.decode(Double.self, forKey: .retainedSeconds) : nil
        sources = try fields.decode([Source].self, forKey: .sources)
        try validate()
    }

    public var span: AudioSpan? { to.map { AudioSpan(from: from, to: $0) } }

    func validate() throws {
        let validTarget = occurrenceID.map { !$0.isEmpty } ?? (kind == .protect)
        guard validTarget, kind == .marker ? to == nil : to.map({ $0 > from }) == true,
              kind == .retain ? retainedSeconds.map({ $0.isFinite && $0 >= 0 }) == true : retainedSeconds == nil,
              sources.allSatisfy({ ProjectFile.validMediaPath($0.file)
                  && $0.groupRange.map({ $0.to > $0.from }) != false }) else {
            throw CutError(code: "invalid_analysis_annotations", message: "The saved pause review has invalid source evidence or timing.")
        }
    }
}

extension ProjectPauseReview {
    /// Keep the exact reviewed intervals when a new detector splits, widens or
    /// omits them. Automatic spans can still cover time outside those intervals.
    package static func preserving(_ reviewed: Set<AudioSpan>, in detected: [AudioSpan]) -> [AudioSpan] {
        guard !reviewed.isEmpty else { return detected }
        let fixed = reviewed.sorted { $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from }
        var coverage: [AudioSpan] = []
        var unambiguous: [AudioSpan] = []
        var index = 0
        while index < fixed.count {
            let first = fixed[index]
            var end = first.to
            index += 1
            let next = index
            while index < fixed.count, fixed[index].from < end {
                end = max(end, fixed[index].to)
                index += 1
            }
            coverage.append(.init(from: first.from, to: end))
            // Conflicting decisions retain the entire region until reviewed.
            if index == next { unambiguous.append(first) }
        }
        let uncovered = detected.flatMap { span -> [AudioSpan] in
            let first = coverage.lowerBound { $0.to > span.from }
            let overlaps = coverage[first...].prefix { $0.from < span.to }
            return overlaps.isEmpty ? [span] : AudioAnalysis.retained(in: span, removing: Array(overlaps))
        }
        return (uncovered + unambiguous).sorted { $0.from < $1.from }
    }
}

extension ProjectPauseReview {
    package static func occurrenceID(_ item: StillAssemblyItem) -> String? {
        if let id = item.still?.id { return "still/" + id }
        return item.occurrenceID.map { "group/" + $0 }
    }

    package static func sources(for span: AudioSpan, routes: [MulticamSilenceRoute], media: [String: MediaInfo]) -> [Source]? {
        var evidence: [Source] = []
        for route in routes {
            guard let overlap = MulticamSilencePlanner.intersection(span, MulticamSilencePlanner.span(route.group)) else { continue }
            guard let input = media[route.selection.source],
                  let source = Source(media: input, stream: route.selection.stream, sourceID: route.selection.source,
                                      offset: route.offset, groupRange: MulticamSilencePlanner.range(overlap)) else { return nil }
            evidence.append(source)
        }
        return evidence
    }

    package static func multicamProtection(for span: AudioSpan, routes: [MulticamSilenceRoute],
                                           media: [String: MediaInfo]) -> Self? {
        guard let evidence = sources(for: span, routes: routes, media: media), !evidence.isEmpty else { return nil }
        return .init(occurrenceID: nil, kind: .protect, from: span.from, to: span.to, sources: evidence)
    }

    /// Compare the entire route through the reviewed interval. This detects a
    /// changed sync offset or replacement stream even if its media path survived.
    package func matches(_ routes: [MulticamSilenceRoute], media: [String: MediaInfo], within range: MulticamRange) -> Bool {
        guard let fullSpan = span, let span = MulticamSilencePlanner.intersection(fullSpan, MulticamSilencePlanner.span(range)) else { return false }
        let sources = sources.compactMap { original -> Source? in
            guard let range = original.groupRange, let overlap = MulticamSilencePlanner.intersection(span, MulticamSilencePlanner.span(range)) else { return nil }
            var input = original
            input.groupRange = MulticamSilencePlanner.range(overlap)
            return input
        }
        var index = sources.startIndex
        for route in routes {
            guard let overlap = MulticamSilencePlanner.intersection(span, MulticamSilencePlanner.span(route.group)) else { continue }
            guard index < sources.endIndex else { return false }
            let source = sources[index]
            guard source.sourceID == route.selection.source, source.stream == route.selection.stream,
                  source.offset == route.offset, source.groupRange == MulticamSilencePlanner.range(overlap),
                  let input = media[route.selection.source], source.matches(input) else { return false }
            index += 1
        }
        return index == sources.endIndex
    }
}

package struct MulticamPauseReviews {
    package var protected: [Int: Set<AudioSpan>] = [:]
    package var reviewed: [Int: Set<AudioSpan>] = [:]
    package var retained: [MulticamPauseEdit.ID: Double] = [:]
    package var needsReview = false

    package init(project: MulticamProject, annotations: ProjectAnalysisAnnotations,
                 routing: [Int: MulticamSilenceRouting], media: [String: MediaInfo],
                 silences: [MulticamAudioSelection: SilenceAnalysisResult], maxBlip: Double,
                 groupPlayback: Bool = false) {
        let rows = annotations.pauseReviews.filter { $0.kind != .marker }
        guard !rows.isEmpty else { return }
        let items = project.assemblyItems
        for (index, route) in routing {
            let range = groupPlayback || items == nil ? project.range : items.flatMap { $0.indices.contains(index) ? $0[index].group : nil }
            guard let range else { continue }
            let id = items == nil ? "whole-group" : items.flatMap { !groupPlayback && $0.indices.contains(index) ? ProjectPauseReview.occurrenceID($0[index]) : nil }
            let detected = Set(route.pauses(silences: silences, maxBlip: maxBlip))
            for row in rows where row.occurrenceID == nil || row.occurrenceID == id {
                guard let span = row.span, span.from < range.to, span.to > range.from else { continue }
                guard row.matches(route.routes, media: media, within: range) else { needsReview = true; continue }
                if !detected.contains(span) { needsReview = true }
                reviewed[index, default: []].insert(span)
                if row.kind == .protect { protected[index, default: []].insert(span) }
                else { retained[.init(occurrence: index, span: span)] = row.retainedSeconds }
            }
        }
    }
}

extension ProjectPauseReview {
    package func matchesMarker(in project: MulticamProject, media: [String: MediaInfo],
                               mapping: MulticamPlan?, occurrence: Int) -> Bool {
        guard kind == .marker else { return false }
        guard !sources.isEmpty else { return true }
        guard let input = sources.first, let id = input.sourceID, let info = media[id],
              project.sources.first(where: { $0.id == id })?.offset == input.offset,
              mapping?.intervals.first(where: { $0.assemblyIndex == occurrence && $0.group.contains(from) })?.pictureSourceID == id else { return false }
        return input.matches(info)
    }

    func intersects(_ range: MulticamRange) -> Bool {
        if let to { return from < range.to && range.from < to }
        return range.contains(from)
    }
}

extension MulticamProject {
    package mutating func materializeAssembly() {
        guard assemblyItems == nil else { return }
        replaceAssembly([.group(range)], carryingPauseReviewsFrom: [0])
    }

    /// Carry source-clock decisions through splits. An implicit whole-group
    /// occurrence acquires real IDs the first time it is materialized.
    package mutating func replaceAssembly(_ replacement: [StillAssemblyItem], carryingPauseReviewsFrom origin: [Int]) {
        precondition(replacement.count == origin.count)
        let original = assemblyItems
        var items = replacement
        let rows = analysisAnnotations.pauseReviews
        if !rows.isEmpty {
            let grouped = Dictionary(grouping: rows, by: \.occurrenceID)
            var updated = rows.filter { $0.occurrenceID == nil }
            for index in items.indices {
                let priorID = original.flatMap { ProjectPauseReview.occurrenceID($0[origin[index]]) }
                    ?? (original == nil ? "whole-group" : nil)
                guard let priorID, let owned = grouped[priorID] else { continue }
                let applicable = owned.filter { row in items[index].group.map(row.intersects) ?? true }
                guard !applicable.isEmpty else { continue }
                if let range = items[index].group, items[index].occurrenceID == nil {
                    items[index] = .group(range, angle: items[index].angleOverride,
                                          id: ProjectIdentifier.make(), layouts: items[index].tileLayouts)
                }
                for var row in applicable {
                    row.occurrenceID = ProjectPauseReview.occurrenceID(items[index])
                    updated.append(row)
                }
            }
            analysisAnnotations.pauseReviews = updated
        }
        assemblyItems = items
    }
}

extension ProjectPauseReview {
    /// Source and group times stay absolute, whereas card markers start at
    /// zero in each retained fragment.
    package func retained(by owner: String, within range: MulticamRange, onCard: Bool = false) throws -> Self? {
        guard intersects(range) else { return nil }
        var row = self
        row.occurrenceID = owner
        if onCard { row.from = try from.subtracting(range.from) }
        return row
    }
}
