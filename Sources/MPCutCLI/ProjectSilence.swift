import CryptoKit
import Foundation
import MPCutCore

struct ProjectSilenceReport: Encodable {
    struct Threshold: Encodable {
        let source: String
        let file: String
        let stream: Int
        let thresholdDB: Double
        private enum CodingKeys: String, CodingKey {
            case source = "source_id", file, stream = "audio_stream_index", thresholdDB = "threshold_db"
        }
    }

    struct Interval: Encodable {
        let assemblyIndex: Int
        let group: AudioSpan
        let output: AudioSpan
        let id: String?
        let isProtected: Bool?
        let requestedRetainedSeconds: Double?
        let retainedSeconds: Double?

        init(assemblyIndex: Int, group: AudioSpan, groupStart: RationalTime, outputStart: RationalTime,
             id: String? = nil, isProtected: Bool? = nil, requestedRetainedSeconds: Double? = nil,
             retainedSeconds: Double? = nil) throws {
            self.assemblyIndex = assemblyIndex
            self.group = group
            self.id = id
            self.isProtected = isProtected
            self.requestedRetainedSeconds = requestedRetainedSeconds
            self.retainedSeconds = retainedSeconds
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
    let maxBlip: Double
    let minimumPause: Double
    let padding: Double
    var mode: ExportMode
    let pauses: [Interval]
    let removals: [Interval]
    let clips: [Interval]
    let takeCandidates: [AudioSpan]
    let skippedPauses: Int
    let removedDuration: RationalTime
    let retainedAssembly: [StillAssemblyItem]
    let retainedAnnotations: ProjectAnalysisAnnotations
    let reviewedAnnotations: ProjectAnalysisAnnotations
    let pauseReviewNeedsAttention: Bool
    let retainedDuration: RationalTime
    let cards: [RetainedCard]?
    let indexedSources: [String: MediaInfo]
    var outProject: String?
    var output: String?
    var outputBytes: Int64?
    var dryRun: Bool?
    var preflight: MulticamExportPlan?
    var stillPreflight: StillExportReport?
    /// What the program export gives up, as `mpcut export` lists it under `warnings`: the plan's warnings and what a
    /// copy leaves behind.
    var warnings: [String]?
    /// What writing changed that the plan could not know. Only an export reports it.
    var writtenWarnings: [String]?
    /// The tier of the retained ranges, reported with `--output`.
    var tier: TierSummary?

    private enum CodingKeys: String, CodingKey {
        case ok, project = "project_path", duration, thresholdMode, thresholds, mode
        case maxBlip = "max_blip_seconds", minimumPause = "min_pause_seconds", padding = "padding_per_side_seconds"
        case pauses, removals, clips, skippedPauses, removedDuration, output, outputBytes, dryRun, preflight, stillPreflight, tier
        case outProject = "out_project"
        case cards, retainedDuration, takeCandidates, pauseReviewNeedsAttention, warnings, writtenWarnings
    }

    init(_ document: MulticamProject, at location: URL, options: SilenceOptions, container: String,
         cancelled: @escaping @Sendable () -> Bool) throws {
        let assembly = document.assemblyItems ?? [.group(document.range)]
        let indices = assembly.indices.filter { assembly[$0].group != nil }
        let ranges = assembly.compactMap(\.group)
        let mapping = try document.plan()
        guard mapping.audioLanes.contains(where: { !$0.spans.isEmpty }) else {
            throw CutError(code: "no_audio", message: "The project assembly has no selected soundtrack.")
        }
        let inputs = try MulticamAnalysisInputs(document, at: location, mapping: mapping, cancelled: cancelled)
        let (files, indexed, media, routing) = (inputs.files, inputs.indexed, inputs.media, inputs.routing)
        let routes = routing.keys.sorted().flatMap { routing[$0]?.routes ?? [] }
        guard !routes.isEmpty else {
            throw CutError(code: "no_audio", message: "The selected soundtrack has no coverage in the project assembly.")
        }
        let inputMinimum = MulticamSilencePlanner.inputMinimum(options.minimum, routes: routes)
        var results: [MulticamAudioSelection: SilenceAnalysisResult] = [:]
        var analyses: [URL: [Int: SilenceAnalysisResult]] = [:]
        let annotations = document.analysisAnnotations.mappingPaths { CutProject.mediaURL($0, relativeTo: location).path }
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
                let level = options.thresholdDB ?? annotations.multicamThresholdDB ?? annotations.threshold(for: info, stream: selection.stream)
                detection = try AudioAnalysis.silence(info, stream: selection.stream, thresholdDB: level,
                                                      minimum: inputMinimum, cancelled: cancelled)
                analyses[file, default: [:]][selection.stream] = detection
            }
            results[selection] = detection
            levels.append(.init(source: selection.source, file: file.path, stream: selection.stream,
                                thresholdDB: detection.thresholdDB))
        }
        project = location.path
        duration = mapping.duration
        thresholdMode = results.values.contains { $0.requestedThresholdDB != nil } ? .manual : .auto
        thresholds = levels
        maxBlip = options.maxBlip
        minimumPause = options.minimum
        let padding = options.padding ?? 0.2
        self.padding = padding
        let stills = try CutProject.multicam(document).exportPlacementScope()
        let mode = options.mode ?? ExportRules.defaultStillMode(tracks: .all, placements: stills,
                                                                  otherwise: ExportRules.defaultMode(for: .multicam))
        self.mode = mode
        indexedSources = media

        var protectionCache = TranscriptPauseProtectionCache()
        let authored = protectionCache.resolve(document.transcripts, relativeTo: location)
        let protected = try Set(authored.group(project: document,
                                               sourceFingerprints: media.mapValues { $0.identity.transcriptFingerprint }))
        struct Recording: Encodable {
            let source: String
            let file: String
            let identity: SourceIdentity
            let changeSeconds: Int?
            let changeNanoseconds: Int?
        }
        struct Route: Encodable {
            let selection: MulticamAudioSelection
            let group: MulticamRange
            let input: MulticamRange
            let offset: RationalTime
            let laneID: String?
        }
        struct PauseContext: Encodable {
            let item: StillAssemblyItem
            let timeline: [MulticamInterval]
            let routes: [Route]
            let recordings: [Recording]
            let thresholds: [Threshold]
            let minimum: Double
            let maxBlip: Double
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recordings = media.sorted { $0.key < $1.key }.map { id, info in
            Recording(source: id, file: info.url.path, identity: info.identity,
                      changeSeconds: info.identity.changeTime?.seconds, changeNanoseconds: info.identity.changeTime?.nanoseconds)
        }
        let timeline = Dictionary(grouping: mapping.intervals, by: \.assemblyIndex)
        let revisions = try Dictionary(uniqueKeysWithValues: indices.map { index in
            let routes = (routing[index]?.routes ?? []).map {
                Route(selection: $0.selection, group: $0.group, input: $0.input, offset: $0.offset, laneID: $0.laneID)
            }
            let context = PauseContext(item: assembly[index], timeline: timeline[index] ?? [], routes: routes,
                                       recordings: recordings, thresholds: levels, minimum: options.minimum, maxBlip: options.maxBlip)
            let digest = SHA256.hash(data: try encoder.encode(context))
            return (index, digest.map { String(format: "%02x", $0) }.joined())
        })
        func legacyPauseName(occurrence: Int, span: AudioSpan) -> String {
            "multicam:\(occurrence):\(span.from):\(span.to)"
        }
        func pauseName(occurrence: Int, span: AudioSpan) -> String {
            legacyPauseName(occurrence: occurrence, span: span) + ":" + (revisions[occurrence] ?? "")
        }
        let existing = MulticamPauseReviews(project: document, annotations: annotations, routing: routing,
                                            media: media, silences: results, maxBlip: options.maxBlip)
        var reviewed = document.analysisAnnotations
        var added: [ProjectPauseReview] = []
        if !options.protectedPauses.isEmpty {
            for index in indices {
                guard let routed = routing[index], let group = assembly[index].group else { continue }
                let detected = ProjectPauseReview.preserving(existing.reviewed[index] ?? [],
                    in: routed.pauses(silences: results, maxBlip: options.maxBlip))
                for span in detected where options.protectedPauses.contains(pauseName(occurrence: index, span: span)) {
                    guard let row = ProjectPauseReview.multicamProtection(for: span, routes: routed.routes, media: media) else {
                        throw CutError(code: "analysis_unavailable", message: "Could not verify the audio routing of a selected pause.")
                    }
                    let alreadySaved = annotations.pauseReviews.contains {
                        $0.kind == .protect && $0.occurrenceID == nil && $0.span == span
                            && $0.matches(routed.routes, media: media, within: group)
                    }
                    if !alreadySaved, !added.contains(row) { added.append(row) }
                }
            }
            for row in added {
                var relative = row
                for index in relative.sources.indices {
                    relative.sources[index].file = CutProject.relativeMediaPath(relative.sources[index].file, to: location)
                }
                if !reviewed.pauseReviews.contains(relative) { reviewed.pauseReviews.append(relative) }
            }
        }
        reviewedAnnotations = reviewed
        var planningAnnotations = annotations
        for row in added where !planningAnnotations.pauseReviews.contains(row) { planningAnnotations.pauseReviews.append(row) }
        let saved = added.isEmpty ? existing : MulticamPauseReviews(project: document, annotations: planningAnnotations, routing: routing,
                                        media: media, silences: results, maxBlip: options.maxBlip)
        let edits = MulticamSilencePlanner.plan(
            project: document, media: media, ranges: ranges, silences: results,
            scope: nil, minimum: options.minimum, padding: padding, protected: protected,
            maxBlip: options.maxBlip, keyframesOnly: mode == .copy, container: container,
            assemblyIndices: indices, reviewed: saved.reviewed, protectedByOccurrence: saved.protected,
            mapping: mapping, analysisRouting: routing,
            requireCopySound: (options.audioOutput ?? .separateTracks) == .separateTracks &&
                (options.audio ?? .copyOriginal) == .copyOriginal
        ) { id in
            options.retainedPauseSeconds[pauseName(occurrence: id.occurrence, span: id.span)]
                ?? options.retainedPauseSeconds[legacyPauseName(occurrence: id.occurrence, span: id.span)]
                ?? saved.retained[id]
        }
        let known = Set(edits.map { pauseName(occurrence: indices[$0.id.occurrence], span: $0.id.span) })
        let legacy = Set(edits.map { legacyPauseName(occurrence: indices[$0.id.occurrence], span: $0.id.span) })
        guard options.retainedPauseSeconds.keys.allSatisfy({ known.contains($0) || legacy.contains($0) }),
              options.protectedPauses.isSubset(of: known) else {
            throw CLIError("invalid_arguments", "A pause ID is absent from this scan. Scan again with the same settings.")
        }
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
        var origin: [Int] = []
        var retainedCards: [RetainedCard] = []
        var retainedCursor = RationalTime.zero
        for (index, item) in assembly.enumerated() {
            if let card = item.still {
                let end = try retainedCursor.adding(card.duration)
                retainedCards.append(try .init(assemblyIndex: index, placementID: card.id,
                                               output: .init(from: outputStarts[index], to: outputStarts[index].adding(card.duration)),
                                               retainedOutput: .init(from: retainedCursor, to: end)))
                retainedItems.append(item)
                origin.append(index)
                retainedCursor = end
            } else if let occurrence = groupIndices[index] {
                let pieces = retainedByOccurrence[occurrence] ?? []
                for (position, retained) in pieces.enumerated() {
                    retainedItems.append(item.groupPiece(MulticamSilencePlanner.range(retained.span),
                                                         from: position == 0 ? nil : retained.span.from,
                                                         to: pieces.dropFirst(position + 1).first?.span.from,
                                                         keepingID: position == 0))
                    origin.append(index)
                    retainedCursor = try retainedCursor.adding(retained.span.to.subtracting(retained.span.from))
                }
            }
        }
        var shortened = document
        shortened.analysisAnnotations = reviewed
        shortened.replaceAssembly(retainedItems, carryingPauseReviewsFrom: origin)
        retainedAssembly = shortened.assemblyItems ?? retainedItems
        retainedAnnotations = shortened.analysisAnnotations
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

        pauses = try edits.map { edit in
            let index = edit.id.occurrence
            return try Interval(assemblyIndex: indices[index], group: edit.visible, groupStart: ranges[index].from,
                                outputStart: outputStarts[indices[index]],
                                id: pauseName(occurrence: indices[index], span: edit.id.span),
                                isProtected: edit.isProtected, requestedRetainedSeconds: edit.requestedRetainedSeconds, retainedSeconds: edit.retainedSeconds)
        }
        removals = try edits.compactMap { edit in
            try edit.removal.map { try interval(edit.id.occurrence, $0) }
        }
        let clips = try retained.map { try interval($0.occurrence, $0.span) }
        self.clips = clips
        let candidates = (clips.map(\.output) + retainedCards.map(\.output)).sorted { $0.from < $1.from }
        var points = Set<RationalTime>()
        var needsAttention = saved.needsReview
        let markers = Dictionary(grouping: annotations.pauseReviews.filter { $0.kind == .marker }, by: \.occurrenceID)
        for (index, item) in assembly.enumerated() {
            let owner = document.assemblyItems == nil ? "whole-group" : ProjectPauseReview.occurrenceID(item)
            guard let owner else { continue }
            for row in markers[owner] ?? [] {
                guard row.matchesMarker(in: document, media: media, mapping: mapping, occurrence: index) else { needsAttention = true; continue }
                let local = try row.from.subtracting(item.group?.from ?? .zero)
                let length = try item.group.map { try $0.to.subtracting($0.from) } ?? item.still!.duration
                if local > .zero, local < length { points.insert(try outputStarts[index].adding(local)) }
            }
        }
        pauseReviewNeedsAttention = needsAttention
        takeCandidates = try options.splitTakeCandidates(candidates, saved: points)
        skippedPauses = pauses.count - removals.count
        removedDuration = try removals.reduce(.zero) { try $0.adding($1.group.to.subtracting($1.group.from)) }
    }

    func checkSources(cancelled: () -> Bool) throws {
        var checked = Set<URL>()
        for (source, media) in indexedSources.sorted(by: { $0.key < $1.key }) where checked.insert(media.url).inserted {
            if cancelled() { throw CutError(code: "cancelled", message: "Operation cancelled.") }
            guard media.identity.isCurrentSnapshot(at: media.url) else {
                throw CutError(code: "source_changed", message: "Source \(source) (\(media.url.path)) changed during analysis.")
            }
        }
    }
}

/// Media and routes resolved on the same clocks used for multicam pause planning.
struct MulticamAnalysisInputs {
    let files: [String: URL]
    let indexed: [URL: (ordinary: MediaInfo, multicam: MediaInfo)]
    let media: [String: MediaInfo]
    let routing: [Int: MulticamSilenceRouting]

    init(_ document: MulticamProject, at location: URL, mapping: MulticamPlan,
         cancelled: @escaping @Sendable () -> Bool) throws {
        let files = Dictionary(uniqueKeysWithValues: document.sources.map {
            ($0.id, document.sourceURL(for: $0, relativeTo: location))
        })
        let engine = CutEngine(cancelled: cancelled)
        var indexed: [URL: (ordinary: MediaInfo, multicam: MediaInfo)] = [:]
        var media: [String: MediaInfo] = [:]
        for source in Set(mapping.picture.map(\.source)).union(document.requiredAudioSelections(for: mapping).map(\.source)).sorted() {
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
        let routing = try MulticamSilencePlanner.routing(plan: mapping, project: document, media: media)

        self.files = files
        self.indexed = indexed
        self.media = media
        self.routing = routing
    }
}
