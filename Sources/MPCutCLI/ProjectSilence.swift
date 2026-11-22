import Foundation
import MPCutCore

struct ProjectSilenceReport: Encodable {
    struct Threshold: Encodable {
        let source: String
        let file: String
        let stream: Int
        let thresholdDB: Double
    }

    struct Interval: Encodable {
        let assemblyIndex: Int
        let group: AudioSpan
        let output: AudioSpan

        init(assemblyIndex: Int, group: AudioSpan, groupStart: RationalTime, outputStart: RationalTime) throws {
            self.assemblyIndex = assemblyIndex
            self.group = group
            output = try AudioSpan(from: outputStart.adding(group.from.subtracting(groupStart)),
                                   to: outputStart.adding(group.to.subtracting(groupStart)))
        }
    }

    struct RetainedCard: Encodable {
        let assemblyIndex: Int
        let placementID: String
        let output: AudioSpan
        let retainedOutput: AudioSpan
    }

    let ok = true
    var project: String
    let duration: RationalTime
    let thresholdMode: SilenceThresholdMode
    let thresholds: [Threshold]
    let minimumPause: Double
    let leave: Double
    var mode: ExportMode
    let pauses: [Interval]
    let removals: [Interval]
    let clips: [Interval]
    let skippedPauses: Int
    let removedDuration: RationalTime
    let retainedAssembly: [StillAssemblyItem]
    let retainedDuration: RationalTime
    let cards: [RetainedCard]?
    let indexedSources: [String: MediaInfo]
    var output: String?
    var dryRun: Bool?
    var preflight: MulticamExportPlan?
    var stillPreflight: StillExportReport?
    /// The tier of the retained ranges, reported with `--output`.
    var tier: TierSummary?

    private enum CodingKeys: String, CodingKey {
        case ok, project, duration, thresholdMode, thresholds, minimumPause, leave, mode
        case pauses, removals, clips, skippedPauses, removedDuration, output, dryRun, preflight, stillPreflight, tier
        case cards, retainedDuration
    }

    init(_ document: MulticamProject, at location: URL, options: SilenceOptions, container: String,
         cancelled: @escaping @Sendable () -> Bool) throws {
        let assembly = document.assemblyItems ?? [.group(document.range)]
        let indices = assembly.indices.filter { assembly[$0].group != nil }
        let ranges = assembly.compactMap(\.group)
        let mapping = try document.plan()
        guard !mapping.audio.isEmpty else {
            throw CutError(code: "no_audio", message: "The project assembly has no selected soundtrack.")
        }
        let files = Dictionary(uniqueKeysWithValues: document.sources.map {
            ($0.id, document.sourceURL(for: $0, relativeTo: location))
        })
        let engine = CutEngine(cancelled: cancelled)
        var indexed: [URL: (ordinary: MediaInfo, multicam: MediaInfo)] = [:]
        var media: [String: MediaInfo] = [:]
        for source in Set((mapping.picture + mapping.audio).map(\.source)).sorted() {
            guard let file = files[source], !file.path.split(separator: "/").contains("..") else {
                throw CutError(code: "missing_source", message: "Source \(source) has an unavailable parent directory.")
            }
            let info: (ordinary: MediaInfo, multicam: MediaInfo)
            if let cached = indexed[file] {
                info = cached
            } else {
                let ordinary: MediaInfo
                do {
                    ordinary = try engine.inspect(file, keyframes: true)
                } catch let issue as CutError where issue.code != "cancelled" {
                    throw CutError(code: issue.code, message: "Source \(source) (\(file.path)): \(issue.message)")
                }
                info = (ordinary, try engine.multicamClock(ordinary))
                indexed[file] = info
            }
            media[source] = info.multicam
        }
        for span in mapping.audio {
            guard media[span.source]?.audio.contains(where: { $0.stream.index == span.stream }) == true else {
                throw CutError(code: "missing_audio",
                               message: "Source \(span.source) has no audio stream \(span.stream.map(String.init) ?? "selected").",
                               track: span.stream)
            }
        }
        let routes = MulticamSilencePlanner.routes(plan: mapping, project: document, media: media)
        guard !routes.isEmpty else {
            throw CutError(code: "no_audio", message: "The selected soundtrack has no coverage in the project assembly.")
        }
        let inputMinimum = MulticamSilencePlanner.inputMinimum(options.minimum, routes: routes)
        var results: [MulticamAudioSelection: SilenceAnalysisResult] = [:]
        var analyses: [URL: [Int: SilenceAnalysisResult]] = [:]
        var levels: [Threshold] = []
        for route in routes where results[route.selection] == nil {
            let selection = route.selection
            let file = files[selection.source]!
            let ordinary = indexed[file]!.ordinary
            let detection: SilenceAnalysisResult
            if let cached = analyses[file]?[selection.stream] {
                detection = cached
            } else {
                let info = try ordinary.extendingToAudioEnd(stream: selection.stream)
                let level = options.thresholdDB ?? MulticamSilencePlanner.savedThreshold(
                    for: info, stream: selection.stream, cancelled: cancelled)
                detection = try AudioAnalysis.silence(info, stream: selection.stream, thresholdDB: level,
                                                      minimum: inputMinimum, requireRouting: true, cancelled: cancelled)
                analyses[file, default: [:]][selection.stream] = detection
            }
            results[selection] = detection
            levels.append(.init(source: selection.source, file: file.path, stream: selection.stream,
                                thresholdDB: detection.thresholdDB))
        }
        project = location.path
        duration = mapping.duration
        thresholdMode = options.thresholdDB == nil ? .auto : .manual
        thresholds = levels
        minimumPause = options.minimum
        let leave = options.leave ?? 0.4
        self.leave = leave
        let stills = try CutProject.multicam(document).exportPlacementScope()
        let mode = options.mode ?? ExportRules.defaultStillMode(tracks: .all, placements: stills,
                                                                  otherwise: ExportRules.defaultMode(for: .multicam))
        self.mode = mode
        indexedSources = media

        let edits = MulticamSilencePlanner.plan(project: document, media: media, ranges: ranges, silences: results,
                                                scope: nil, minimum: options.minimum, leave: leave, protected: [],
                                                keyframesOnly: mode == .copy, container: container, assemblyIndices: indices)
        let retained = MulticamSilencePlanner.retainedOccurrences(ranges, pauses: edits)
        var cursor = RationalTime.zero
        var outputStarts: [RationalTime] = []
        for item in assembly {
            outputStarts.append(cursor)
            if let range = item.group { cursor = try cursor.adding(range.to.subtracting(range.from)) }
            if let card = item.still { cursor = try cursor.adding(card.duration) }
        }
        let retainedByOccurrence = Dictionary(grouping: retained, by: \.occurrence)
        let groupIndices = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($1, $0) })
        var retainedItems: [StillAssemblyItem] = []
        var retainedCards: [RetainedCard] = []
        var retainedCursor = RationalTime.zero
        for (index, item) in assembly.enumerated() {
            if let card = item.still {
                let end = try retainedCursor.adding(card.duration)
                retainedCards.append(try .init(assemblyIndex: index, placementID: card.id,
                                               output: .init(from: outputStarts[index], to: outputStarts[index].adding(card.duration)),
                                               retainedOutput: .init(from: retainedCursor, to: end)))
                retainedItems.append(item)
                retainedCursor = end
            } else if let occurrence = groupIndices[index] {
                for retained in retainedByOccurrence[occurrence] ?? [] {
                    retainedItems.append(.group(MulticamSilencePlanner.range(retained.span)))
                    retainedCursor = try retainedCursor.adding(retained.span.to.subtracting(retained.span.from))
                }
            }
        }
        retainedAssembly = retainedItems
        if !retainedItems.isEmpty && options.mode == nil {
            var retained = document
            retained.assemblyItems = retainedItems
            self.mode = try ExportRules.defaultStillMode(tracks: .all, placements: CutProject.multicam(retained).exportPlacementScope(),
                                                         otherwise: ExportRules.defaultMode(for: .multicam))
        }
        retainedDuration = retainedCursor
        cards = retainedCards.isEmpty ? nil : retainedCards
        func interval(_ index: Int, _ span: AudioSpan) throws -> Interval {
            try Interval(assemblyIndex: indices[index], group: span, groupStart: ranges[index].from,
                         outputStart: outputStarts[indices[index]])
        }

        pauses = try edits.map { try interval($0.id.occurrence, $0.visible) }
        removals = try edits.compactMap { edit in
            try edit.removal.map { try interval(edit.id.occurrence, $0) }
        }
        clips = try retained.map { try interval($0.occurrence, $0.span) }
        skippedPauses = pauses.count - removals.count
        removedDuration = try removals.reduce(.zero) { try $0.adding($1.group.to.subtracting($1.group.from)) }
    }

    func checkSources(cancelled: () -> Bool) throws {
        var checked = Set<URL>()
        for (source, media) in indexedSources.sorted(by: { $0.key < $1.key }) where checked.insert(media.url).inserted {
            if cancelled() { throw CutError(code: "cancelled", message: "Operation cancelled.") }
            guard (try? SourceIdentity(media.url)) == media.identity else {
                throw CutError(code: "source_changed", message: "Source \(source) (\(media.url.path)) changed during analysis.")
            }
        }
    }
}
