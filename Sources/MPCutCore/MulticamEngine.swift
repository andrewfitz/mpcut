import Darwin
import Foundation

/// The start or end of one assembly range. `range` is one-based and equals the error's `segment`.
public struct MulticamEdge: Codable, Equatable, Sendable {
    public let range: Int
    public let boundary: String
    public let at: RationalTime

    private enum CodingKeys: String, CodingKey {
        case range = "range_number", boundary, at = "group_time"
    }

    package init(range: Int, boundary: String, at: RationalTime) {
        self.range = range
        self.boundary = boundary
        self.at = at
    }
}

public struct MulticamDiagnostic: Codable, Sendable {
    public let source: String
    public let group: MulticamRange
    public let sourceTime: MulticamRange
    public let output: MulticamRange
    /// The switch that the error's `nearest` times can replace. Absent unless the boundary is a switch.
    public let at: RationalTime?
    /// The assembly range edge that the error's `nearest` times can replace. Absent at a switch.
    public let edge: MulticamEdge?
    public var laneID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case source = "source_id", group = "group_range", sourceTime = "source_range"
        case output = "assembly_range", at = "switch_group_time", edge, laneID = "lane_id"
    }
}

extension CutError {
    /// Report an expanded edit-list row against its original input clip.
    package func reportingInputClip(_ number: Int) -> CutError {
        let context = multicam.map { context in
            MulticamDiagnostic(source: context.source, group: context.group, sourceTime: context.sourceTime,
                               output: context.output, at: context.at, edge: context.edge.map {
                                   MulticamEdge(range: number, boundary: $0.boundary, at: $0.at)
                               }, laneID: context.laneID)
        }
        var issue = CutError(code: code, message: message, segment: number, boundary: boundary,
                             nearest: nearest, track: track, multicam: context, placementIDs: placementIDs,
                             laneID: laneID).because(reason)
        issue.alternatives = alternatives
        issue.stillBoundaryAdjustments = stillBoundaryAdjustments
        return issue
    }
}

/// The plan that results from moving one edge of a one-based assembly range to a group time.
public typealias MulticamEdgePlanner = (_ range: Int, _ boundary: String, _ time: RationalTime) throws -> MulticamPlan

public struct MulticamInspectedSource: Encodable, Sendable {
    public let source: MulticamSource
    public let media: MediaInfo
    public let coverage: MulticamRange
    public let audioCoverage: [Int: MulticamRange]

    private enum CodingKeys: String, CodingKey { case source, media, coverage, audioCoverage }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(media.omittingFrames(), forKey: .media)
        try values.encode(coverage, forKey: .coverage)
        try values.encode(audioCoverage, forKey: .audioCoverage)
    }
}

public struct MulticamInspectedAudioBinding: Encodable, Sendable {
    public let id: String
    public let original: MulticamAudioSelection
    public let replacement: MulticamAudioSelection
    public let coverage: MulticamRange?
}

public struct MulticamInspection: Encodable, Sendable {
    public let mapping: MulticamPlan
    public let sources: [MulticamInspectedSource]
    public let issues: [CutError]
    public let audioBindings: [MulticamInspectedAudioBinding]
}

public struct MulticamExportPlan: Encodable, Sendable {
    public let mapping: MulticamPlan
    public let picture: [ResolvedSegment]
    public let audioLanes: [MulticamExportAudioLane]
    public let audioOutput: MulticamAudioOutput
    public let container: String
    public let duration: RationalTime
    public let mode: ExportMode
    public let tracks: ExportTracks
    public let warnings: [String]
    public let encodedVideoDuration: RationalTime
    public let copiedVideoDuration: RationalTime
    public let generatedPictureGaps: [MulticamRange]?

    let pictureCopy: ResolvedEdit?
    let pictureEncode: ReencodePlan?
    let sounds: [MulticamExportSound]
    let recordingGapExport: StillExportPlan?
    let participantExport: ParticipantProjectExport?
    public let participantRender: ParticipantRenderReport?
    /// What the program leaves out of its sources, one sentence each, as `ExportPlan.copyOmissions` does for a copy.
    public internal(set) var copyOmissions: [String] = []
    /// The reference angle's chapters on the program clock (MulticamProgramChapters). The final mux writes them.
    var chapters: [ReencodeChapter] = []
    package var participantRenderTier: TierState? { participantExport?.tier(container: container) }

    enum CodingKeys: String, CodingKey {
        case mapping, picture, audioLanes, audioOutput, container, duration, mode, tracks, warnings
        case encodedVideoDuration, copiedVideoDuration, generatedPictureGaps, participantRender
    }
}

public struct MulticamEngine: Sendable {
    let cancelled: (@Sendable () -> Bool)?

    public init(cancelled: (@Sendable () -> Bool)? = nil) {
        self.cancelled = cancelled
    }

    private var plannedSubfolder: URL?

    package func planning(in subfolder: URL?) -> Self {
        var planner = self
        planner.plannedSubfolder = subfolder
        return planner
    }

    package func checkCombinedDestination(_ output: URL) throws -> String {
        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        try engine.checkDestination(output)
        let container = try destinationContainer(output)
        try MulticamMux(cancelled: cancelled).check(container: container)
        return container
    }

    private func destinationContainer(_ output: URL) throws -> String {
        let ext = output.pathExtension.lowercased()
        guard !ext.isEmpty, ext.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else {
            throw CutError(code: "unsupported_container", message: "Choose a destination with a media container extension.")
        }
        return ExportRules.multicamMuxContainer(ext)
    }

    public func inspect(_ project: MulticamProject, relativeTo location: URL? = nil) throws -> MulticamInspection {
        let mapping = try project.plan()
        let engine = CutEngine(cancelled: cancelled)
        var indexed: [URL: MediaInfo] = [:]
        let sources = try project.sources.map { source in
            let file = sourceURL(source, project: project, location: location)
            let media = try index(source.id, file: file, using: engine, cached: &indexed)
            let coverage = try groupCoverage(of: media, source: source.id, offset: source.offset)
            return MulticamInspectedSource(source: source, media: media, coverage: coverage.picture,
                                           audioCoverage: coverage.audio)
        }
        let bySource = Dictionary(uniqueKeysWithValues: sources.map { ($0.source.id, $0) })
        var issues: [CutError] = []
        for interval in mapping.intervals {
            let picture = interval.pictureSourceID.flatMap { bySource[$0] }
            // An issue names its assembly range, as an export error does, and locates the interval.
            let number = interval.assemblyIndex + 1
            func context(_ source: String) -> MulticamDiagnostic? {
                guard let offset = bySource[source]?.source.offset,
                      let from = try? interval.group.from.subtracting(offset),
                      let to = try? interval.group.to.subtracting(offset) else { return nil }
                return MulticamDiagnostic(source: source, group: interval.group, sourceTime: .init(from: from, to: to),
                                          output: interval.output, at: nil, edge: nil)
            }
            if picture?.media.hasVideo != true || picture.map({ interval.group.from < $0.coverage.from || interval.group.to > $0.coverage.to }) == true {
                issues.append(CutError(code: "uncovered_picture",
                                       message: "Angle \(interval.angle) has incomplete picture coverage at group \(interval.group.from)–\(interval.group.to).",
                                       segment: number, track: picture?.media.videoStream?.index,
                                       multicam: interval.pictureSourceID.flatMap(context)))
            }
        }
        let indexedSources = bySource.mapValues(\.media)
        var resolved: [MulticamPlannedAudioLane] = []
        for lane in mapping.audioLanes {
            let oneLane = MulticamPlan(intervals: mapping.intervals, picture: mapping.picture, audioLanes: [lane], duration: mapping.duration)
            do {
                let audio = try project.resolveAudioLanes(plan: oneLane, indexedSources: indexedSources)
                for resolvedLane in audio {
                    try CutEngine(cancelled: cancelled).checkCancellation()
                    for gap in resolvedLane.gaps {
                        let issue = CutError(code: lane.gaps.contains(gap) && !mapping.isMix ? "missing_audio" : "uncovered_audio",
                            message: "The selected soundtrack has incomplete coverage at output \(gap.from)–\(gap.to).")
                        let error = try conversionIssue(issue, at: gap, lane: resolvedLane, mapping: mapping, original: lane)
                        issues.append(CutError(code: error.code, message: error.message,
                                               segment: error.multicam.flatMap { rangeNumber($0, boundary: nil, in: mapping) },
                                               track: error.track, multicam: error.multicam, laneID: error.laneID))
                    }
                }
                resolved += audio
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                if let context = issue.multicam, let segment = rangeNumber(context, boundary: issue.boundary, in: mapping) {
                    issues.append(CutError(code: issue.code, message: issue.message, segment: segment,
                                           boundary: issue.boundary, nearest: issue.nearest, track: issue.track,
                                           multicam: context, laneID: issue.laneID).because(issue.reason))
                } else {
                    issues.append(issue)
                }
                resolved.append(lane)
            }
        }
        let bindings = try project.audioReplacements.map { binding -> MulticamInspectedAudioBinding in
            var coverage: MulticamRange?
            if let original = bySource[binding.original.source],
               let media = indexedSources[binding.replacement.source],
               let track = media.audio.first(where: { $0.stream.index == binding.replacement.stream }) {
                let offset = try original.source.offset.adding(binding.relativeOffset)
                coverage = try .init(from: offset.adding(track.start), to: offset.adding(track.end))
            }
            return .init(id: binding.id, original: binding.original, replacement: binding.replacement, coverage: coverage)
        }
        let inspectedMapping = MulticamPlan(intervals: mapping.intervals, picture: mapping.picture,
                                           audioLanes: resolved, duration: mapping.duration)
        return MulticamInspection(mapping: inspectedMapping, sources: sources, issues: issues, audioBindings: bindings)
    }

    public func resolve(_ project: MulticamProject, relativeTo location: URL? = nil, output: URL,
                        mode: ExportMode = .smart, tracks: ExportTracks = .all,
                        assembly: [MulticamRange]? = nil,
                        settings: ReencodeSettings = .init(), audioOutput: MulticamAudioOutput = .separateTracks,
                        audioAction: ReencodeAudio? = nil) throws -> MulticamExportPlan {
        try resolve(project, relativeTo: location, output: output, mode: mode, tracks: tracks,
                    assembly: assembly, settings: settings, indexedSources: [:],
                    audioOutput: audioOutput, audioAction: audioAction)
    }

    /// The desktop can supply indexes from inspectMulticamSource to export the
    /// same recordings and source clocks used in its preview.
    package func resolve(_ project: MulticamProject, relativeTo location: URL? = nil, output: URL,
                         mode: ExportMode = .smart, tracks: ExportTracks = .all,
                         assembly: [MulticamRange]? = nil, settings: ReencodeSettings = .init(),
                         indexedSources: [String: MediaInfo], audioOutput: MulticamAudioOutput = .separateTracks,
                         audioAction: ReencodeAudio? = nil) throws -> MulticamExportPlan {
        var media = indexedSources
        return try resolve(project, relativeTo: location, output: output, mode: mode, tracks: tracks,
                           assembly: assembly, settings: settings, media: &media, audioOutput: audioOutput, audioAction: audioAction)
    }

    func resolve(_ project: MulticamProject, relativeTo location: URL?, output: URL,
                 mode: ExportMode, tracks: ExportTracks, assembly: [MulticamRange]?,
                 settings: ReencodeSettings, media: inout [String: MediaInfo],
                 audioOutput: MulticamAudioOutput = .separateTracks, audioAction: ReencodeAudio? = nil) throws -> MulticamExportPlan {
        if CutProject.multicam(project).requiresPictureProcessing {
            let snapshot = try assembly.map { try project.pictureExportSnapshot(ranges: $0) } ?? project
            let export = try ParticipantProjectExport(.multicam(snapshot), relativeTo: location, output: output, mode: mode,
                                                      tracks: tracks, settings: settings, audioOutput: audioOutput,
                                                      audioAction: audioAction, plannedSubfolder: plannedSubfolder, cancelled: cancelled)
            let mapping = try snapshot.plan()
            return MulticamExportPlan(mapping: mapping, picture: [], audioLanes: [], audioOutput: audioOutput,
                                      container: output.pathExtension.lowercased(), duration: export.report.duration,
                                      mode: mode, tracks: tracks, warnings: export.notices,
                                      encodedVideoDuration: tracks == .audio ? .zero : export.report.duration,
                                      copiedVideoDuration: .zero, generatedPictureGaps: nil,
                                      pictureCopy: nil, pictureEncode: nil, sounds: [], recordingGapExport: nil,
                                      participantExport: export, participantRender: export.report)
        }
        let mapping = try project.plan(ranges: assembly)
        let sources = Dictionary(uniqueKeysWithValues: project.sources.map {
            ($0.id, sourceURL($0, project: project, location: location))
        })
        let items = assembly.map { $0.map { StillAssemblyItem.group($0) } } ?? project.assemblyItems ?? [.group(project.range)]
        var plannedProject = project
        plannedProject.assemblyItems = items
        return try resolve(mapping, sources: sources, output: output, mode: mode, tracks: tracks,
                           settings: settings, requireAudio: project.audio != .none || !mapping.audioLanes.isEmpty,
                           media: &media, adjusting: { number, boundary, time in
            let index = number - 1
            var moved = items
            guard moved.indices.contains(index), var range = moved[index].group else {
                throw CutError(code: "invalid_range", message: "The project has no assembly range \(number).")
            }
            if boundary == "from" { range.from = time } else { range.to = time }
            moved[index] = .group(range, angle: moved[index].angleOverride)
            var updated = project
            updated.assemblyItems = moved
            return try updated.plan()
        }, offerBoundaries: true, project: plannedProject, audioOutput: audioOutput, audioAction: audioAction)
    }

    /// `adjusting` replans the request with one range edge moved. With it, an unsafe range
    /// edge reports nearby valid times in `nearest`, as an unsafe switch does.
    public func resolve(_ mapping: MulticamPlan, sources: [String: URL], output: URL,
                        mode: ExportMode = .smart, tracks: ExportTracks = .all,
                        settings: ReencodeSettings = .init(),
                        requireAudio: Bool = true,
                        adjusting: MulticamEdgePlanner? = nil, audioOutput: MulticamAudioOutput = .separateTracks,
                        audioAction: ReencodeAudio? = nil) throws -> MulticamExportPlan {
        var media: [String: MediaInfo] = [:]
        return try resolve(mapping, sources: sources, output: output, mode: mode, tracks: tracks,
                           settings: settings, requireAudio: requireAudio, media: &media,
                           adjusting: adjusting, offerBoundaries: true, audioOutput: audioOutput, audioAction: audioAction)
    }

    /// Reports each located fault against its one-based assembly range, which for an edit
    /// request is the caller's clip number, and offers alternatives for an unsafe range edge.
    func resolve(_ mapping: MulticamPlan, sources: [String: URL], output: URL,
                 mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings,
                 requireAudio: Bool, media: inout [String: MediaInfo],
                 adjusting: MulticamEdgePlanner?, offerBoundaries: Bool, project: MulticamProject? = nil,
                 audioOutput: MulticamAudioOutput = .separateTracks, audioAction: ReencodeAudio? = nil) throws -> MulticamExportPlan {
        let requestedAudio = audioAction ?? (settings.audio == .auto
            ? (audioOutput == .separateTracks ? .copyOriginal : .auto) : settings.audio)
        do {
            return try resolveLanes(mapping, sources: sources, output: output, mode: mode, tracks: tracks,
                                    settings: settings, requireAudio: requireAudio,
                                    media: &media, offerBoundaries: offerBoundaries, project: project,
                                    audioOutput: audioOutput, audioAction: requestedAudio)
        } catch let issue as CutError {
            guard let context = issue.multicam else { throw issue }
            var nearest = issue.nearest
            if offerBoundaries, let edge = context.edge, let adjusting,
               issue.code == "unsafe_boundary" || issue.code == "invalid_frame_boundary" {
                var candidateMedia = media
                let lanes = try? (project?.resolveAudioLanes(plan: mapping, indexedSources: media)
                                  ?? mapping.resolveAudioLanes(indexedSources: media))
                nearest = try edgeAlternatives(edge, mapping: mapping, media: media, mode: mode,
                                               container: destinationContainer(output),
                                               picture: tracks != .audio,
                                               sound: tracks != .video && !mapping.audioLanes.isEmpty
                                                   && requestedAudio == .copyOriginal,
                                               soundLaneID: issue.laneID,
                                               strictCandidates: mapping.isMix || !(project?.audioReplacements ?? mapping.joinedAudioReplacements).isEmpty,
                                               resolvedLanes: lanes,
                                               adjusting: adjusting) { candidate in
                    do {
                        _ = try resolveLanes(candidate, sources: sources, output: output, mode: mode, tracks: tracks,
                                             settings: settings, requireAudio: requireAudio,
                                             media: &candidateMedia, offerBoundaries: false, project: project,
                                             audioOutput: audioOutput, audioAction: requestedAudio)
                        return nil
                    } catch let failure as CutError {
                        return failure
                    }
                }
            }
            throw CutError(code: issue.code, message: issue.message,
                           segment: rangeNumber(context, boundary: issue.boundary, in: mapping) ?? issue.segment,
                           boundary: issue.boundary, nearest: nearest, track: issue.track, multicam: context, laneID: issue.laneID).because(issue.reason)
        }
    }

    private func rangeNumber(_ context: MulticamDiagnostic, boundary: String?, in mapping: MulticamPlan) -> Int? {
        if let edge = context.edge { return edge.range }
        let interval = boundary == "to"
            ? mapping.intervals.last { $0.output.from < context.output.to }
            : mapping.intervals.first { $0.output.to > context.output.from }
        return interval.map { $0.assemblyIndex + 1 }
    }

    /// Faults thrown here carry `segment` as a one-based index into the picture or sound lane.
    private func resolveLanes(_ mapping: MulticamPlan, sources: [String: URL], output: URL,
                              mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings,
                              requireAudio: Bool, media indexedMedia: inout [String: MediaInfo],
                              offerBoundaries: Bool, project: MulticamProject?,
                              audioOutput: MulticamAudioOutput, audioAction: ReencodeAudio) throws -> MulticamExportPlan {
        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        try engine.checkDestination(output, plannedSubfolder: plannedSubfolder)
        let destinationContainer = output.pathExtension.lowercased()
        let container = try self.destinationContainer(output)
        let wantPicture = tracks != .audio
        let wantAudio = tracks != .video && audioAction != .removeAudio
        let pictureGaps = wantPicture ? mapping.recordingGaps : []
        let hasPictureGaps = !pictureGaps.isEmpty
        if wantPicture { try validatePicture(mapping, gaps: pictureGaps) }
        if mode != .encode, let gap = pictureGaps.first {
            throw CutError(code: "recording_gap_requires_encoding",
                           message: "The selected camera has a recording gap at output \(gap.from)–\(gap.to). Re-encode to fill it with black.")
                .because(.placementPicture)
        }
        let cell = ExportRules.cell(source: .multicam, tracks: tracks, mode: mode)
        if let refusal = cell.refusal, !hasPictureGaps { throw refusal }
        if wantAudio && mapping.audioLanes.isEmpty && (requireAudio || tracks == .audio) {
            throw CutError(code: "missing_audio", message: "There is no soundtrack selected for export.")
        }
        let useAudio = wantAudio && !mapping.audioLanes.isEmpty
        guard wantPicture || useAudio else {
            throw CutError(code: "missing_audio", message: "There is no soundtrack selected for export.")
        }
        if wantPicture && useAudio { try MulticamMux(cancelled: cancelled).check(container: container) }
        if MulticamMux.movieContainers.contains(container), 705_600_000 % mapping.duration.denominator != 0 {
            throw CutError(code: "unsupported_container", message: "The MOV movie clock cannot represent the exact program duration.")
        }

        var indexed: [URL: MediaInfo] = [:]
        var bySource: [String: MediaInfo] = [:]
        let pictureSpans = wantPicture ? mapping.picture : []
        let bindings = Dictionary(uniqueKeysWithValues: (project?.audioReplacements ?? mapping.joinedAudioReplacements).map { ($0.original, $0) })
        var indexContexts: [String: (lane: MulticamPlannedAudioLane, span: MulticamSpan)] = [:]
        var fallbacks: [(lane: MulticamPlannedAudioLane, original: MulticamSpan, replacement: MulticamSpan)] = []
        if useAudio {
            for lane in mapping.audioLanes {
                for span in lane.spans {
                    let selection = span.stream.map { MulticamAudioSelection(source: span.source, stream: $0) }
                    if let binding = selection.flatMap({ bindings[$0] }) {
                        let replacement = try MulticamSpan(source: binding.replacement.source, stream: binding.replacement.stream,
                            input: .init(from: span.input.from.subtracting(binding.relativeOffset),
                                         to: span.input.to.subtracting(binding.relativeOffset)),
                            output: span.output, replacementBindingID: binding.id)
                        if indexContexts[replacement.source] == nil { indexContexts[replacement.source] = (lane, replacement) }
                        if binding.uncovered == .keepOriginal { fallbacks.append((lane, span, replacement)) }
                    } else if indexContexts[span.source] == nil {
                        indexContexts[span.source] = (lane, span)
                    }
                }
                if lane.spans.isEmpty, audioOutput == .separateTracks, audioAction != .copyOriginal,
                   let selection = project?.configuredSelection(for: lane) ?? mapping.joinedAudioSelections[lane.id],
                   indexContexts[selection.source] == nil {
                    let output = MulticamRange(from: .zero, to: mapping.duration)
                    indexContexts[selection.source] = (lane, .init(source: selection.source, stream: selection.stream,
                                                                   input: output, output: output))
                }
            }
        }

        func indexSource(_ id: String, lane: MulticamPlannedAudioLane?, span: MulticamSpan?) throws {
            guard bySource[id] == nil else { return }
            let file = sources[id]
            let previous = indexedMedia[id].flatMap { $0.url == file?.standardizedFileURL ? $0 : nil }
            do {
                if let previous, previous.hasFullEditIndex, let file, !file.path.split(separator: "/").contains("..") {
                    try engine.checkCancellation()
                    try engine.verifyIdentity(file, identity: previous.identity)
                    let media = try engine.multicamClock(previous)
                    indexed[media.url] = media
                    bySource[id] = media
                } else {
                    // Queues can snapshot a camera while its editing index is loading.
                    bySource[id] = try index(id, file: file, using: engine, cached: &indexed, expectedIdentity: previous?.identity)
                }
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                guard let lane, let span else { throw issue }
                throw try contextual(issue, span: span, mapping: mapping, index: 1, laneID: lane.id)
            }
        }

        var sourceIDs = Set(pictureSpans.map(\.source)).union(indexContexts.keys)
        if hasPictureGaps, pictureSpans.isEmpty, let referenceID = mapping.intervals.first?.angle {
            sourceIDs.insert(referenceID)
        }
        for id in sourceIDs.sorted() {
            try indexSource(id, lane: indexContexts[id]?.lane, span: indexContexts[id]?.span)
        }
        // Scratch audio is optional unless a selected replacement really needs it.
        for (lane, span, replacement) in fallbacks where bySource[span.source] == nil {
            guard let media = bySource[replacement.source],
                  let audio = media.audio.first(where: { $0.stream.index == replacement.stream }) else { continue }
            let sound = try MulticamPlan.audibleParts(of: replacement, track: audio)
            if let gap = MulticamPlan.uncovered(in: span.output, sound: sound).first {
                let start = try span.input.from.adding(gap.from.subtracting(span.output.from))
                let end = try start.adding(gap.to.subtracting(gap.from))
                try indexSource(span.source, lane: lane, span: .init(source: span.source, stream: span.stream,
                                                                     input: .init(from: start, to: end), output: gap))
            }
        }
        indexedMedia.merge(bySource) { _, current in current }
        let resolvedLanes = try useAudio
            ? (project?.resolveAudioLanes(plan: mapping, indexedSources: bySource)
                ?? mapping.resolveAudioLanes(indexedSources: bySource))
            : mapping.audioLanes
        // A physical track can occur at different group offsets through replacement bindings.
        // Validate the clocks of the resolved routes and of the underlying picture recordings.
        var checkedOffsets: [String: Set<RationalTime>] = [:]
        let usedSpans = pictureSpans + (useAudio ? resolvedLanes.flatMap(\.spans) : [])
        for span in usedSpans {
            try engine.checkCancellation()
            let offset = try groupStart(for: span, in: mapping).subtracting(span.input.from)
            guard checkedOffsets[span.source, default: []].insert(offset).inserted,
                  let media = bySource[span.source] else { continue }
            _ = try groupCoverage(of: media, source: span.source, offset: offset)
        }

        let sounds: [MulticamExportSound]
        if useAudio {
            sounds = try resolveAudioOutput(mapping, resolvedLanes: resolvedLanes, project: project, sources: bySource, container: container,
                                            output: audioOutput, action: audioAction, offerBoundaries: offerBoundaries,
                                            mode: mode, wantPicture: wantPicture, settings: settings)
        } else {
            sounds = []
        }
        let gapPicture = hasPictureGaps
            ? try resolveRecordingGaps(mapping, sources: sources, container: destinationContainer, settings: settings)
            : nil
        if gapPicture != nil {
            for media in bySource.values { try engine.verifyIdentity(media.url, identity: media.identity) }
        }
        var pictureCopy: ResolvedEdit?
        var pictureEncode: ReencodePlan?
        if wantPicture && gapPicture == nil {
            let pictureEngine = CutEngine(multicamSmartPicture: mode == .smart, cancelled: cancelled)
            var media: [URL: MediaInfo] = [:]
            var requests: [ClipRequest] = []
            requests.reserveCapacity(mapping.picture.count)
            for (index, span) in mapping.picture.enumerated() {
                let source = bySource[span.source]!
                let info: MediaInfo
                do {
                    info = try media[source.url] ?? isolatedPicture(source, using: pictureEngine)
                    try checkPictureCoverage(info, span: span, mapping: mapping, container: container)
                } catch let issue as CutError {
                    throw try contextual(issue, span: span, mapping: mapping, index: index + 1,
                                         track: source.videoStream?.index)
                }
                media[info.url] = info
                requests.append(ClipRequest(file: info.url, from: span.input.from, to: span.input.to))
            }

            do {
                if mode == .encode {
                    let pictureSettings = ReencodeSettings(codec: settings.codec, quality: settings.quality, audio: .removeAudio)
                    var encoded = try ReencodeEngine(cancelled: cancelled).resolve(requests, media: media,
                                                                                    container: container, settings: pictureSettings)
                    encoded.movieTimeScale = 705_600_000
                    pictureEncode = encoded
                } else {
                    pictureCopy = try pictureEngine.resolve(requests, media: media, container: container)
                }
            } catch let issue as CutError where issue.code != "cancelled" {
                guard let segment = issue.segment, mapping.picture.indices.contains(segment - 1) else { throw issue }
                let span = mapping.picture[segment - 1]
                var offered: [RationalTime] = []
                if offerBoundaries, issue.code == "unsafe_boundary" || issue.code == "invalid_frame_boundary",
                   let boundary = issue.boundary {
                    offered = try pictureAlternatives(at: boundary == "from" ? span.output.from : span.output.to,
                                                     mapping: mapping, media: bySource, mode: mode, container: container,
                                                     settings: settings,
                                                     replanning: markerPlanner(project),
                                                     validatesCandidate: { candidate in
                                                         try validateCandidateAudio(candidate, project: project, sources: bySource,
                                                                                    container: container, output: audioOutput,
                                                                                    action: audioAction, useAudio: useAudio)
                                                     })
                }
                throw try contextual(issue, span: span, mapping: mapping, index: segment, nearest: offered,
                                     track: bySource[span.source]?.videoStream?.index)
            }
        }
        let picture = pictureCopy?.segments ?? pictureEncode?.edit.segments ?? gapPicture?.segments ?? []
        let encoded = try pictureCopy?.encodedVideoDuration(for: mode) ?? pictureEncode?.edit.duration
            ?? gapPicture?.plan.report.encodedVideoDuration ?? .zero
        let resolvedMapping = MulticamPlan(intervals: mapping.intervals, picture: mapping.picture,
                                          audioLanes: resolvedLanes, duration: mapping.duration)
        let chapterPlan = try programChapters(mapping, project: project, sources: sources, media: bySource,
                                              container: destinationContainer, hasPicture: wantPicture)
        var plan = MulticamExportPlan(mapping: resolvedMapping, picture: picture, audioLanes: sounds.map(\.report),
                                  audioOutput: audioOutput, container: destinationContainer, duration: mapping.duration,
                                  mode: mode, tracks: tracks,
                                  warnings: (pictureEncode?.warnings ?? gapPicture?.plan.report.warnings ?? []) + sounds.flatMap { $0.report.warnings },
                                  encodedVideoDuration: encoded,
                                  copiedVideoDuration: wantPicture ? try mapping.duration.subtracting(encoded) : .zero,
                                  generatedPictureGaps: gapPicture == nil ? nil : pictureGaps,
                                  pictureCopy: pictureCopy, pictureEncode: pictureEncode, sounds: sounds,
                                  recordingGapExport: gapPicture?.plan, participantExport: nil, participantRender: nil)
        plan.chapters = chapterPlan.chapters
        // What the picture's Smart Trim edges lose, such as film grain synthesis, found while planning them, and an
        // HEVC picture whose staged copy has to keep an 'hev1' description, which the final mux carries on.
        plan.copyOmissions = (pictureCopy.map { CutEngine().copyOmissions($0) } ?? []) + chapterPlan.omissions
            // The program is assembled from staged picture and sound, so no source's movie metadata reaches it.
            + ReencodeChapter.droppedMetadata(of: bySource.keys.sorted().compactMap { bySource[$0]?.url }, by: "The program")
        return plan
    }

    public func write(_ plan: MulticamExportPlan, to output: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        try engine.checkDestination(output)
        guard output.pathExtension.lowercased() == plan.container else {
            throw CutError(code: "invalid_output", message: "The destination must match the resolved multicam container.")
        }
        if let export = plan.participantExport {
            try export.write(to: output, cancelled: cancelled) { fraction in
                progress?(fraction)
                return cancelled?() != true
            }
            return
        }
        let destination = output.standardizedFileURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-multicam-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let picture = staging.appendingPathComponent("picture")
            .appendingPathExtension(plan.pictureCopy?.container ?? plan.pictureEncode?.edit.container ?? plan.container)
        let hasPicture = plan.pictureCopy != nil || plan.pictureEncode != nil || plan.recordingGapExport != nil
        // The final mux also writes the program's chapters, so a chaptered picture-only program goes through it.
        let chapters = hasPicture ? plan.chapters : []
        let needsMux = plan.sounds.count > 1 || (hasPicture && (!plan.sounds.isEmpty || !chapters.isEmpty))
        let pictureFraction = plan.sounds.isEmpty && !needsMux ? 0.98 : 0.45
        func verifySources() throws {
            for edit in [plan.pictureCopy, plan.pictureEncode?.edit].compactMap({ $0 }) {
                for (file, identity) in edit.identities { try engine.verifyIdentity(file, identity: identity) }
            }
            for sound in plan.sounds { try sound.verifySources(using: engine) }
            if let still = plan.recordingGapExport {
                try still.verifySources(using: engine)
            }
            try engine.checkCancellation()
        }
        try verifySources()
        if let copy = plan.pictureCopy {
            try engine.export(copy, to: picture) { fraction in progress?(fraction * pictureFraction); return true }
        } else if let encoded = plan.pictureEncode {
            try ReencodeEngine(cancelled: cancelled).write(encoded, to: picture) { fraction in
                progress?(fraction * pictureFraction)
            }
        } else if let still = plan.recordingGapExport {
            try StillExportPlanner(cancelled: cancelled).write(still, to: picture) { fraction in
                progress?(fraction * pictureFraction)
                return true
            }
        }
        let audioStart = hasPicture ? pictureFraction : 0
        let audioEnd = needsMux ? 0.8 : 0.98
        let sounds = try plan.sounds.enumerated().map { index, sound in
            let staged = staging.appendingPathComponent("sound-\(index)").appendingPathExtension(sound.container)
            do {
                try writeSound(sound, to: staged) { fraction in
                    progress?(audioStart + (Double(index) + fraction) / Double(plan.sounds.count) * (audioEnd - audioStart))
                }
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" && issue.laneID == nil {
                let lane = sound.report
                throw CutError(code: issue.code, message: "Audio lane \(lane.label) (\(lane.id)): \(issue.message)",
                               segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest,
                               track: issue.track, multicam: issue.multicam, laneID: lane.id).because(issue.reason)
            }
            return staged
        }
        if needsMux {
            try MulticamMux(cancelled: cancelled).export(picture: hasPicture ? picture : nil, sounds: sounds, to: destination,
                                                         container: plan.container, duration: plan.duration, audio: plan.audioLanes,
                                                         chapters: chapters,
                                                         progress: { fraction in progress?(0.8 + fraction * 0.19); return true },
                                                         verifySources: verifySources)
        } else {
            try verifySources()
            let failure = publishExclusively(from: hasPicture ? picture : sounds[0], to: destination)
            if failure == EEXIST { throw CutError(code: "output_exists", message: "A file already exists at the destination.") }
            if failure != 0 { throw CutError(code: "write_failed", message: String(cString: strerror(failure))) }
        }
        progress?(1)
    }

    private func groupCoverage(of media: MediaInfo, source: String,
                               offset: RationalTime) throws -> (picture: MulticamRange, audio: [Int: MulticamRange]) {
        do {
            let picture = try MulticamRange(from: offset.adding(media.frames.first?.time ?? .zero),
                                            to: offset.adding(media.duration))
            let audio = try media.audio.map { sound in
                (sound.stream.index, try MulticamRange(from: offset.adding(sound.start), to: offset.adding(sound.end)))
            }
            return (picture, Dictionary(uniqueKeysWithValues: audio))
        } catch let issue as CutError where issue.code == "time_overflow" {
            throw CutError(code: issue.code,
                           message: "Source \(source) (\(media.url.path)): offset \(offset) places the recording outside the supported time range.")
        }
    }

    func validateLane(_ spans: [MulticamSpan], duration: RationalTime, kind: String) throws {
        var end = RationalTime.zero
        for span in spans {
            guard span.output.from == end, span.output.from < span.output.to,
                  try span.output.to.subtracting(span.output.from) == span.input.to.subtracting(span.input.from) else {
                throw CutError(code: "invalid_range", message: "The selected \(kind) does not continuously cover the program at output \(end).")
            }
            end = span.output.to
        }
        guard end == duration, duration > .zero else {
            throw CutError(code: "invalid_range", message: "The selected \(kind) does not cover output \(end)–\(duration).")
        }
    }

    func sourceURL(_ source: MulticamSource, project: MulticamProject, location: URL?) -> URL {
        if let location { return project.sourceURL(for: source, relativeTo: location) }
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return project.sourceURL(for: source, in: workingDirectory)
    }

    private func index(_ source: String, file: URL?, using engine: CutEngine,
                       cached: inout [URL: MediaInfo], expectedIdentity: SourceIdentity? = nil) throws -> MediaInfo {
        guard let file else { throw CutError(code: "missing_source", message: "Source \(source) has no file.") }
        guard !file.path.split(separator: "/").contains("..") else {
            throw CutError(code: "missing_source", message: "Source \(source) has an unavailable parent directory: \(file.path).")
        }
        let fileURL = file.standardizedFileURL
        if let current = cached[fileURL] {
            if let expectedIdentity, !expectedIdentity.matchesSnapshot(current.identity) {
                throw CutError(code: "source_changed", message: "Source \(source) changed after it was added to the project.")
            }
            return current
        }
        do {
            let media = try engine.multicamClock(engine.inspect(fileURL, keyframes: true, expectedIdentity: expectedIdentity))
            cached[fileURL] = media
            return media
        } catch let issue as CutError where issue.code != "cancelled" {
            throw CutError(code: issue.code, message: "Source \(source) (\(fileURL.path)): \(issue.message)")
                .because(issue.reason)
        }
    }

    func groupRange(_ span: MulticamSpan, in mapping: MulticamPlan) throws -> MulticamRange {
        let from = try groupStart(for: span, in: mapping)
        return try MulticamRange(from: from, to: from.adding(span.input.to.subtracting(span.input.from)))
    }

    private func groupStart(for span: MulticamSpan, in mapping: MulticamPlan) throws -> RationalTime {
        let time = span.output.from
        let intervals = mapping.intervals
        let index = intervals.lowerBound { $0.output.to > time }
        guard index < intervals.count, intervals[index].output.contains(time) else {
            throw CutError(code: "invalid_range", message: "A media span has no group-time mapping.")
        }
        let interval = intervals[index]
        return try interval.group.from.adding(time.subtracting(interval.output.from))
    }

    func contextual(_ issue: CutError, span: MulticamSpan, mapping: MulticamPlan,
                    index: Int, nearest: [RationalTime]? = nil, track: Int? = nil,
                    laneID: String? = nil) throws -> CutError {
        guard issue.code != "cancelled" && issue.code != "source_changed" else { return issue }
        let group = try groupRange(span, in: mapping)
        let stream = span.stream ?? issue.track ?? track
        let sourceDescription = stream.map { "stream \($0)" } ?? "picture"
        let description = laneID.flatMap { id in mapping.audioLanes.first { $0.id == id } }
            .map { "lane \($0.label) (\($0.id)), \(sourceDescription)" } ?? sourceDescription
        let alternatives = try nearest ?? issue.nearest?.map { try group.from.adding($0.subtracting(span.input.from)) }
        // A boundary is a switch when one assembly range continues across it. Any other
        // boundary is a range edge, where a suggested time moves the range and no switch.
        var anchor: RationalTime?
        var edge: MulticamEdge?
        if let boundary = issue.boundary, boundary == "from" || boundary == "to" {
            let starting = boundary == "from"
            let time = starting ? group.from : group.to
            let seam = starting ? span.output.from : span.output.to
            let before = mapping.intervals.last { $0.output.to == seam }
            let after = mapping.intervals.first { $0.output.from == seam }
            if let before, let after, before.assemblyIndex == after.assemblyIndex, before.group.to == after.group.from {
                if after.startsAtSwitch != false { anchor = time }
            } else if let interval = starting ? after : before {
                edge = MulticamEdge(range: interval.assemblyIndex + 1, boundary: boundary, at: time)
            }
        }
        let context = MulticamDiagnostic(source: span.source, group: group, sourceTime: span.input,
                                         output: span.output, at: anchor, edge: edge, laneID: laneID)
        return CutError(code: issue.code,
                        message: "Source \(span.source) \(description), group \(group.from)–\(group.to), source \(span.input.from)–\(span.input.to), output \(span.output.from)–\(span.output.to): \(issue.message)",
                        segment: index, boundary: issue.boundary, nearest: anchor == nil && edge == nil ? nil : alternatives, track: stream, multicam: context)
            .because(issue.reason)
    }
}
