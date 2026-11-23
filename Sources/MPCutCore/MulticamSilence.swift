import Foundation

package struct MulticamPauseEdit: Identifiable, Equatable {
    package struct ID: Hashable {
        package let occurrence: Int
        package let span: AudioSpan

        package init(occurrence: Int, span: AudioSpan) {
            self.occurrence = occurrence
            self.span = span
        }
    }
    package let id: ID
    package let visible: AudioSpan
    package let removal: AudioSpan?
    package let isProtected: Bool
    package let requestedRetainedSeconds: Double?

    package var retainedSeconds: Double {
        (visible.to.seconds - visible.from.seconds) -
            (removal.map { $0.to.seconds - $0.from.seconds } ?? 0)
    }

    package init(id: ID, visible: AudioSpan, removal: AudioSpan?, isProtected: Bool,
                 requestedRetainedSeconds: Double? = nil) {
        self.id = id
        self.visible = visible
        self.removal = removal
        self.isProtected = isProtected
        self.requestedRetainedSeconds = requestedRetainedSeconds
    }
}

/// Contiguous output-to-group mappings within one assembly occurrence.
struct MulticamAudioMapping {
    let assemblyIndex: Int
    var group: MulticamRange
    var output: MulticamRange

    static func coalescing(_ intervals: [MulticamInterval]) -> [Self] {
        var mappings: [Self] = []
        for interval in intervals {
            if let index = mappings.indices.last, let last = mappings.last,
               last.assemblyIndex == interval.assemblyIndex,
               last.group.to == interval.group.from, last.output.to == interval.output.from {
                mappings[index].group.to = interval.group.to
                mappings[index].output.to = interval.output.to
            } else {
                mappings.append(.init(assemblyIndex: interval.assemblyIndex, group: interval.group,
                                      output: interval.output))
            }
        }
        return mappings
    }
}

package struct MulticamSilenceRoute {
    package let selection: MulticamAudioSelection
    package var group: MulticamRange
    package var input: MulticamRange
    package let offset: RationalTime
    package let laneID: String?

    package init(selection: MulticamAudioSelection, group: MulticamRange, input: MulticamRange,
                 offset: RationalTime, laneID: String? = nil) {
        self.selection = selection
        self.group = group
        self.input = input
        self.offset = offset
        self.laneID = laneID
    }

    package func project(_ time: RationalTime) -> RationalTime? { try? time.adding(offset) }
}

package struct MulticamSilenceRouting {
    package let lanes: [MulticamPlannedAudioLane]
    package var routes: [MulticamSilenceRoute] = []
    package var selections: Set<MulticamAudioSelection> = []
    package var unindexed: [MulticamRange] = []
    let laneIDs: [String]
    var knownGaps: [String: [AudioSpan]] = [:]

    package init(lanes: [MulticamPlannedAudioLane] = [], laneIDs: [String] = []) {
        self.lanes = lanes
        self.laneIDs = laneIDs
    }

    mutating func append(_ route: MulticamSilenceRoute) {
        if let index = routes.indices.last, let last = routes.last,
           last.laneID == route.laneID, last.selection == route.selection,
           last.group.to == route.group.from, last.input.to == route.input.from {
            routes[index].group.to = route.group.to
            routes[index].input.to = route.input.to
        } else {
            routes.append(route)
        }
    }

    package func pauses(silences: [MulticamAudioSelection: SilenceAnalysisResult], maxBlip: Double) -> [AudioSpan] {
        if laneIDs.isEmpty {
            return MulticamSilencePlanner.routedPauses(routes, silences: silences, maxBlip: maxBlip)
        }
        return MulticamSilencePlanner.mixedPauses(routes, laneIDs: laneIDs, knownGaps: knownGaps,
                                                 silences: silences, maxBlip: maxBlip)
    }
}

package enum MulticamSilencePlanner {
    package static func span(_ range: MulticamRange) -> AudioSpan { .init(from: range.from, to: range.to) }
    package static func range(_ span: AudioSpan) -> MulticamRange { .init(from: span.from, to: span.to) }

    package static func intersection(_ a: AudioSpan, _ b: AudioSpan) -> AudioSpan? {
        let from = max(a.from, b.from)
        let to = min(a.to, b.to)
        return from < to ? .init(from: from, to: to) : nil
    }

    package static func retained(_ ranges: [MulticamRange], pauses: [MulticamPauseEdit],
                                 scope: AudioSpan? = nil) -> [MulticamRange] {
        retainedOccurrences(ranges, pauses: pauses, scope: scope).map { range($0.span) }
    }

    package static func retainedOccurrences(_ ranges: [MulticamRange], pauses: [MulticamPauseEdit],
                                            scope: AudioSpan? = nil,
                                            occurrenceScopes: [AudioSpan?]? = nil) -> [(occurrence: Int, span: AudioSpan)] {
        let cuts = Dictionary(grouping: pauses, by: { $0.id.occurrence })
        return ranges.enumerated().flatMap { index, range -> [(Int, AudioSpan)] in
            guard let domain = scoped(span(range), at: index, group: scope, occurrences: occurrenceScopes) else { return [] }
            return AudioAnalysis.retained(in: domain,
                removing: (cuts[index] ?? []).compactMap(\.removal).sorted { $0.from < $1.from }).map { (index, $0) }
        }
    }

    package static func plan(project: MulticamProject, media: [String: MediaInfo],
                             ranges: [MulticamRange], pauses: [AudioSpan], scope: AudioSpan?,
                             minimum: Double, padding: Double, protected: Set<AudioSpan>,
                             keyframesOnly: Bool = false, container: String = "mov") -> [MulticamPauseEdit] {
        guard !pauses.isEmpty, let mapping = try? project.plan(ranges: ranges),
              let routing = try? routing(plan: mapping, project: project, media: media) else { return [] }
        return plan(project: project, media: media, ranges: ranges, scope: scope, minimum: minimum,
                    padding: padding, protected: protected, keyframesOnly: keyframesOnly, container: container,
                    mapping: mapping, audioRouting: routing) { _ in
            pauses
        }
    }

    package static func plan(project: MulticamProject, media: [String: MediaInfo],
                             ranges: [MulticamRange], silences: [MulticamAudioSelection: SilenceAnalysisResult],
                             scope: AudioSpan?, minimum: Double, padding: Double, protected: Set<AudioSpan>,
                             maxBlip: Double = AudioWaveform.defaultMaxBlip, keyframesOnly: Bool = false, container: String = "mov",
                             occurrenceScopes: [AudioSpan?]? = nil,
                             assemblyIndices: [Int]? = nil,
                             retainedSeconds: [MulticamPauseEdit.ID: Double] = [:],
                             mapping: MulticamPlan? = nil,
                             analysisRouting: [Int: MulticamSilenceRouting]? = nil,
                             requireCopySound: Bool = true,
                             requestedRetainedSeconds: ((MulticamPauseEdit.ID) -> Double?)? = nil) -> [MulticamPauseEdit] {
        guard !silences.isEmpty,
              let mapping = mapping ?? (try? project.plan(ranges: assemblyIndices == nil ? ranges : nil)),
              let routing = analysisRouting ?? (try? routing(plan: mapping, project: project, media: media,
                                                             assumeUnindexedCoverage: true)) else { return [] }
        return plan(project: project, media: media, ranges: ranges, scope: scope, minimum: minimum,
                    padding: padding, protected: protected, keyframesOnly: keyframesOnly, container: container,
                    occurrenceScopes: occurrenceScopes, assemblyIndices: assemblyIndices, mapping: mapping,
                    audioRouting: routing, requireCopySound: requireCopySound,
                    requestedRetainedSeconds: requestedRetainedSeconds ?? { retainedSeconds[$0] }) { occurrence in
            routing[occurrence]?.pauses(silences: silences, maxBlip: maxBlip) ?? []
        }
    }

    private static func plan(project: MulticamProject, media: [String: MediaInfo], ranges: [MulticamRange],
                             scope: AudioSpan?, minimum: Double, padding: Double, protected: Set<AudioSpan>,
                             keyframesOnly: Bool, container: String,
                             occurrenceScopes: [AudioSpan?]? = nil, assemblyIndices: [Int]? = nil,
                             mapping: MulticamPlan,
                             audioRouting: [Int: MulticamSilenceRouting],
                             requireCopySound: Bool = true,
                             requestedRetainedSeconds: (MulticamPauseEdit.ID) -> Double? = { _ in nil },
                             pausesForOccurrence: (Int) -> [AudioSpan])
        -> [MulticamPauseEdit] {
        guard assemblyIndices.map({ $0.count == ranges.count }) ?? true else { return [] }
        let intervalGroups = Dictionary(grouping: mapping.intervals, by: \.assemblyIndex)
        let offsets = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0.offset) })
        let pictureEngine = CutEngine(multicamSmartPicture: !keyframesOnly, cancelled: nil)
        let smartAngles: Set<String> = keyframesOnly ? [] : Set(media.compactMap { id, info in
            info.hasVideo && pictureEngine.smartTrimEligible(in: info, container: container) ? id : nil
        })
        let routesByOccurrence = requireCopySound
            ? audioRouting.mapValues { Dictionary(grouping: $0.routes, by: \.laneID) } : [:]
        let selections = requireCopySound ? Set(audioRouting.values.flatMap { $0.routes.map(\.selection) }) : []
        let sound = soundIndexes(selections, media: media)
        return ranges.enumerated().flatMap { index, range -> [MulticamPauseEdit] in
            let clip = span(range)
            guard let scoped = scoped(clip, at: index, group: scope, occurrences: occurrenceScopes) else { return [] }
            let occurrence = assemblyIndices?[index] ?? index
            let intervals = intervalGroups[occurrence] ?? []
            let pauses = pausesForOccurrence(occurrence)
            let first = pauses.lowerBound { $0.to > scoped.from }
            return pauses[first...].prefix { $0.from < scoped.to }.compactMap { pause in
                guard let visible = intersection(pause, scoped),
                      let duration = try? visible.to.subtracting(visible.from),
                      duration.seconds >= minimum else { return nil }
                let requested = requestedRetainedSeconds(.init(occurrence: occurrence, span: pause))
                let keep = protected.contains { intersection($0, pause) != nil }
                var removal: AudioSpan?
                if !keep {
                    let edges = pictureEdges(in: visible, intervals: intervals,
                                             offsets: offsets, media: media, smartAngles: smartAngles,
                                             sound: sound, lanes: routesByOccurrence[occurrence] ?? [:], container: container)
                    removal = AudioAnalysis.removal(in: visible, padding: requested.map { $0 / 2 } ?? padding, ends: edges.ends,
                                                    starts: edges.starts, clip: clip)
                }
                return MulticamPauseEdit(id: .init(occurrence: index, span: pause), visible: visible,
                                         removal: removal, isProtected: keep, requestedRetainedSeconds: requested)
            }
        }
    }

    private static func scoped(_ clip: AudioSpan, at index: Int, group: AudioSpan?,
                               occurrences: [AudioSpan?]?) -> AudioSpan? {
        if let occurrences {
            guard occurrences.indices.contains(index), let selected = occurrences[index] else { return nil }
            return intersection(clip, selected)
        }
        return intersection(clip, group ?? clip)
    }

    private static func pictureEdges(in window: AudioSpan, intervals: [MulticamInterval],
                                     offsets: [String: RationalTime], media: [String: MediaInfo],
                                     smartAngles: Set<String>, sound: [MulticamAudioSelection: MediaInfo],
                                     lanes: [String?: [MulticamSilenceRoute]], container: String)
        -> (ends: [RationalTime], starts: [RationalTime]) {
        let relevantRoutes = lanes.values.flatMap { routes -> ArraySlice<MulticamSilenceRoute> in
            let first = routes.lowerBound { $0.group.to >= window.from }
            let end = routes.lowerBound { $0.group.from > window.to }
            return routes[first..<end]
        }
        var starts: [RationalTime] = []
        var ends: [RationalTime] = []
        let first = intervals.lowerBound { $0.group.to >= window.from }
        for interval in intervals[first...] {
            if interval.group.from > window.to { break }
            guard let id = interval.pictureSourceID, let offset = offsets[id], let info = media[id],
                  let sourceStart = try? max(window.from, interval.group.from).subtracting(offset),
                  let sourceEnd = try? min(window.to, interval.group.to).subtracting(offset) else { continue }
            let frameAccurate = smartAngles.contains(id)
            let frames = info.frames
            let index = frames.lowerBound { $0.time >= sourceStart }
            for frame in frames[index...] {
                if frame.time > sourceEnd { break }
                guard let time = try? frame.time.adding(offset) else { continue }
                let initialStart = frame.time == frames.first?.time && info.sourceStartSafe
                if time < interval.group.to, initialStart || frameAccurate || frame.canStart,
                   soundAllows(time, in: interval, start: true, sound: sound, audioRoutes: relevantRoutes, container: container) {
                    starts.append(time)
                }
                if time > interval.group.from, frameAccurate || frame.canEnd,
                   soundAllows(time, in: interval, start: false, sound: sound, audioRoutes: relevantRoutes, container: container) {
                    ends.append(time)
                }
            }
            if info.duration >= sourceStart, info.duration <= sourceEnd,
               let end = try? info.duration.adding(offset), end > interval.group.from,
               soundAllows(end, in: interval, start: false, sound: sound, audioRoutes: relevantRoutes, container: container) {
                ends.append(end)
            }
        }
        return (ends.sorted(), starts.sorted())
    }

    private static func soundIndexes(_ routes: Set<MulticamAudioSelection>, media: [String: MediaInfo])
        -> [MulticamAudioSelection: MediaInfo] {
        var indexes: [MulticamAudioSelection: MediaInfo] = [:]
        for route in routes {
            guard let info = media[route.source],
                  let track = info.audio.first(where: { $0.stream.index == route.stream }) else { continue }
            indexes[route] = MediaInfo(url: info.url, format: info.format, duration: track.end,
                                       origin: info.origin, streams: [track.stream], frames: [], audio: [track],
                                       copyIssue: nil, sourceStartSafe: info.sourceStartSafe,
                                       identity: info.identity, videoIndex: -1, multicamClockOffset: info.multicamClockOffset)
        }
        return indexes
    }

    private static func soundAllows(_ time: RationalTime, in interval: MulticamInterval, start: Bool,
                                    sound: [MulticamAudioSelection: MediaInfo], audioRoutes: [MulticamSilenceRoute],
                                    container: String) -> Bool {
        guard let output = try? interval.output.from.adding(time.subtracting(interval.group.from)) else { return false }
        return audioRoutes.allSatisfy { route in
            let group = route.group
            guard start ? group.from <= time && time < group.to : group.from < time && time <= group.to else { return true }
            guard let media = sound[route.selection],
                  let input = try? time.subtracting(route.offset).adding(media.multicamClockOffset) else { return false }
            return soundAllows(input: input, output: output, media: media, start: start, container: container)
        }
    }

    private static func soundAllows(input: RationalTime, output: RationalTime, media: MediaInfo, start: Bool,
                                    container: String) -> Bool {
        let track = media.audio[0]
        let lower = max(.zero, track.start)
        guard start ? (input >= lower && input < track.end) : (input > lower && input <= track.end) else {
            return false
        }
        // An internal removal introduces a discontinuity on either side. The
        // exporter handles the remaining outer edges (e.g. a complete file).
        return (try? MulticamEngine().checkSoundBoundary(input: input, output: output, media: media, start: start,
                                                        first: false, last: false, container: container, segment: 1)) != nil
    }

    package static func savedThreshold(for media: MediaInfo, stream: Int,
                                       cancelled: () -> Bool) -> Double? {
        AnalysisSidecar(media: media).read(AnalysisSidecar.silenceThresholdOverridesKey, cancelled: cancelled)
            .flatMap { try? JSONDecoder().decode([Int: Double].self, from: $0)[stream] }
            .flatMap { (-120...0).contains($0) ? $0 : nil }
    }

    package static func routing(plan: MulticamPlan?, project: MulticamProject, media: [String: MediaInfo],
                                assumeUnindexedCoverage: Bool = false) throws -> [Int: MulticamSilenceRouting] {
        guard let plan else { return [:] }
        // A provisional extent cannot establish a known-silent gap.
        let indexed = assumeUnindexedCoverage ? media.filter { $0.value.hasFullEditIndex } : media
        let lanes = try project.resolveAudioLanes(plan: plan, indexedSources: indexed,
                                                  assumeUnindexedCoverage: assumeUnindexedCoverage)
        let laneIDs = project.audio == .mix ? lanes.map(\.id) : []
        let mappings = MulticamAudioMapping.coalescing(plan.intervals)
        var result: [Int: MulticamSilenceRouting] = [:]
        for mapping in mappings where result[mapping.assemblyIndex] == nil {
            result[mapping.assemblyIndex] = .init(lanes: lanes, laneIDs: laneIDs)
        }

        // Output time is ordered even when group ranges repeat or play out of order.
        func forEachGroupPiece(_ output: MulticamRange,
                               _ body: (Int, MulticamRange, MulticamRange) throws -> Void) throws {
            let first = mappings.lowerBound { $0.output.to > output.from }
            for mapping in mappings[first...] {
                if mapping.output.from >= output.to { break }
                let from = max(output.from, mapping.output.from)
                let to = min(output.to, mapping.output.to)
                let offset = try mapping.group.from.subtracting(mapping.output.from)
                try body(mapping.assemblyIndex, .init(from: from, to: to),
                         .init(from: from.adding(offset), to: to.adding(offset)))
            }
        }

        for lane in lanes {
            let laneID = project.audio == .mix ? lane.id : nil
            for sound in lane.spans {
                guard let stream = sound.stream else { continue }
                let selection = MulticamAudioSelection(source: sound.source, stream: stream)
                try forEachGroupPiece(sound.output) { occurrence, output, group in
                    let input = try MulticamRange(from: sound.input.from.adding(output.from.subtracting(sound.output.from)),
                                                  to: sound.input.from.adding(output.to.subtracting(sound.output.from)))
                    let offset = try group.from.subtracting(input.from)
                    result[occurrence]?.selections.insert(selection)
                    if let route = route(selection, input: input, offset: offset, media: media, laneID: laneID) {
                        result[occurrence]?.append(route)
                    } else if indexed[selection.source] == nil {
                        result[occurrence]?.unindexed.append(group)
                    }
                }
            }
            if let laneID {
                for gap in lane.gaps {
                    try forEachGroupPiece(gap) { occurrence, _, group in
                        result[occurrence]?.knownGaps[laneID, default: []].append(span(group))
                    }
                }
            }
        }
        for occurrence in Array(result.keys) {
            result[occurrence]?.routes.sort { $0.group.from < $1.group.from }
        }
        return result
    }

    private static func route(_ selection: MulticamAudioSelection, input: MulticamRange, offset: RationalTime,
                              media: [String: MediaInfo], laneID: String? = nil) -> MulticamSilenceRoute? {
        guard let info = media[selection.source],
              let audio = info.audio.first(where: { $0.stream.index == selection.stream }),
              let analysisOffset = try? offset.adding(info.multicamClockOffset) else { return nil }
        let start = max(input.from, audio.start, info.multicamClockOffset)
        let end = min(input.to, audio.end)
        guard start < end,
              let groupFrom = try? start.adding(offset), let groupTo = try? end.adding(offset),
              let inputFrom = try? start.subtracting(info.multicamClockOffset),
              let inputTo = try? end.subtracting(info.multicamClockOffset) else { return nil }
        return .init(selection: selection, group: .init(from: groupFrom, to: groupTo),
                     input: .init(from: inputFrom, to: inputTo), offset: analysisOffset, laneID: laneID)
    }

    package static func inputMinimum(_ minimum: Double, routes: [MulticamSilenceRoute]) -> Double {
        // A continuous program pause can be made up of short runs on different microphones.
        Set(routes.map(\.selection)).count > 1 ? min(minimum, 1 / Double(AudioWaveform.rate)) : minimum
    }

    package static func routedPauses(_ routes: [MulticamSilenceRoute],
                                     silences: [MulticamAudioSelection: SilenceAnalysisResult],
                                     minimum: Double = 0, maxBlip: Double = AudioWaveform.defaultMaxBlip) -> [AudioSpan] {
        let runs = projectedRuns(routes, silences: silences)
        return runs.pauses(minimum: minimum, maxBlip: maxBlip)
    }

    package static func mixedPauses(_ routes: [MulticamSilenceRoute], laneIDs: [String],
                                    knownGaps: [String: [AudioSpan]] = [:],
                                    silences: [MulticamAudioSelection: SilenceAnalysisResult],
                                    minimum: Double = 0,
                                    maxBlip: Double = AudioWaveform.defaultMaxBlip) -> [AudioSpan] {
        let perLane = Dictionary(grouping: routes, by: \.laneID)
        let evidence = laneIDs.map { lane in
            projectedRuns(perLane[lane] ?? [], silences: silences, knownGaps: knownGaps[lane] ?? [])
        }
        guard let first = evidence.first else { return [] }
        let combined = evidence.dropFirst().reduce(first) { common, lane in
            SilenceRuns(quiet: intersect(common.quiet, lane.quiet),
                        covered: intersect(common.covered, lane.covered))
        }
        return combined.pauses(minimum: minimum, maxBlip: maxBlip)
    }

    private static func intersect(_ lhs: [AudioSpan], _ rhs: [AudioSpan]) -> [AudioSpan] {
        var left = 0
        var right = 0
        var result: [AudioSpan] = []
        while left < lhs.count, right < rhs.count {
            if let overlap = intersection(lhs[left], rhs[right]) { result.append(overlap) }
            if lhs[left].to < rhs[right].to { left += 1 } else { right += 1 }
        }
        return result
    }

    private static func projectedRuns(_ routes: [MulticamSilenceRoute],
                                      silences: [MulticamAudioSelection: SilenceAnalysisResult],
                                      knownGaps: [AudioSpan] = []) -> SilenceRuns {
        var quiet = knownGaps
        var covered = knownGaps
        for route in routes {
            guard let runs = silences[route.selection]?.runs else { continue }
            func project(_ spans: [AudioSpan], into visible: inout [AudioSpan]) {
                let lower = spans.lowerBound { $0.to > route.input.from }
                let upper = spans.lowerBound { $0.from >= route.input.to }
                for span in spans[lower..<upper] {
                    guard let from = route.project(max(route.input.from, span.from)),
                          let to = route.project(min(route.input.to, span.to)), from < to else { continue }
                    visible.append(AudioSpan(from: from, to: to))
                }
            }
            project(runs.quiet, into: &quiet)
            project(runs.covered, into: &covered)
        }

        // Assembly order is independent of group time, and occurrences can overlap.
        func merged(_ spans: [AudioSpan]) -> [AudioSpan] {
            var result: [AudioSpan] = []
            for span in spans.sorted(by: { $0.from < $1.from }) {
                if let last = result.last, last.to >= span.from {
                    result[result.count - 1] = AudioSpan(from: last.from, to: max(last.to, span.to))
                } else {
                    result.append(span)
                }
            }
            return result
        }
        return SilenceRuns(quiet: merged(quiet), covered: merged(covered))
    }
}
