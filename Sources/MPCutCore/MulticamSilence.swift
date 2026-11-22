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

    package init(id: ID, visible: AudioSpan, removal: AudioSpan?, isProtected: Bool) {
        self.id = id
        self.visible = visible
        self.removal = removal
        self.isProtected = isProtected
    }
}

package struct MulticamSilenceRoute {
    package let selection: MulticamAudioSelection
    package let group: MulticamRange
    package let input: MulticamRange
    package let offset: RationalTime

    package func project(_ time: RationalTime) -> RationalTime? { try? time.adding(offset) }
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
                removing: (cuts[index] ?? []).compactMap(\.removal)).map { (index, $0) }
        }
    }

    package static func plan(project: MulticamProject, media: [String: MediaInfo],
                             ranges: [MulticamRange], pauses: [AudioSpan], scope: AudioSpan?,
                             minimum: Double, leave: Double, protected: Set<AudioSpan>,
                             keyframesOnly: Bool = false, container: String = "mov") -> [MulticamPauseEdit] {
        guard !pauses.isEmpty else { return [] }
        return plan(project: project, media: media, ranges: ranges, scope: scope, minimum: minimum,
                    leave: leave, protected: protected, keyframesOnly: keyframesOnly, container: container) { _, _ in
            pauses
        }
    }

    package static func plan(project: MulticamProject, media: [String: MediaInfo],
                             ranges: [MulticamRange], silences: [MulticamAudioSelection: SilenceAnalysisResult],
                             scope: AudioSpan?, minimum: Double, leave: Double, protected: Set<AudioSpan>,
                             keyframesOnly: Bool = false, container: String = "mov",
                             occurrenceScopes: [AudioSpan?]? = nil,
                             assemblyIndices: [Int]? = nil) -> [MulticamPauseEdit] {
        guard !silences.isEmpty else { return [] }
        return plan(project: project, media: media, ranges: ranges, scope: scope, minimum: minimum,
                    leave: leave, protected: protected, keyframesOnly: keyframesOnly, container: container,
                    occurrenceScopes: occurrenceScopes, assemblyIndices: assemblyIndices) {
            intervals, offsets in
            let routes = intervals.compactMap { interval -> MulticamSilenceRoute? in
                guard let selection = interval.audio, let offset = offsets[selection.source],
                      let from = try? interval.group.from.subtracting(offset),
                      let to = try? interval.group.to.subtracting(offset) else { return nil }
                return route(selection, input: .init(from: from, to: to), offset: offset, media: media)
            }
            return routedPauses(routes, silences: silences)
        }
    }

    private static func plan(project: MulticamProject, media: [String: MediaInfo], ranges: [MulticamRange],
                             scope: AudioSpan?, minimum: Double, leave: Double, protected: Set<AudioSpan>,
                             keyframesOnly: Bool, container: String,
                             occurrenceScopes: [AudioSpan?]? = nil, assemblyIndices: [Int]? = nil,
                             pausesForOccurrence: ([MulticamInterval], [String: RationalTime]) -> [AudioSpan])
        -> [MulticamPauseEdit] {
        guard let plan = try? project.plan(ranges: assemblyIndices == nil ? ranges : nil) else { return [] }
        let intervalGroups = Dictionary(grouping: plan.intervals, by: \.assemblyIndex)
        let offsets = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0.offset) })
        let pictureEngine = CutEngine(multicamSmartPicture: !keyframesOnly, cancelled: nil)
        let smartAngles: Set<String> = keyframesOnly ? [] : Set(media.compactMap { id, info in
            info.hasVideo && pictureEngine.smartTrimEligible(in: info, container: container) ? id : nil
        })
        let sound = soundIndexes(plan, media: media)
        return ranges.enumerated().flatMap { index, range -> [MulticamPauseEdit] in
            let clip = span(range)
            guard let scoped = scoped(clip, at: index, group: scope, occurrences: occurrenceScopes) else { return [] }
            let intervals = intervalGroups[assemblyIndices?[index] ?? index] ?? []
            let pauses = pausesForOccurrence(intervals, offsets)
            let first = pauses.lowerBound { $0.to > scoped.from }
            return pauses[first...].prefix { $0.from < scoped.to }.compactMap { pause in
                guard let visible = intersection(pause, scoped),
                      let duration = try? visible.to.subtracting(visible.from),
                      duration.seconds >= minimum else { return nil }
                let keep = protected.contains { intersection($0, pause) != nil }
                var removal: AudioSpan?
                if !keep {
                    let edges = pictureEdges(in: visible, intervals: intervals,
                                             offsets: offsets, media: media, smartAngles: smartAngles,
                                             sound: sound, container: container)
                    removal = AudioAnalysis.removal(in: visible, leave: leave, ends: edges.ends,
                                                    starts: edges.starts, clip: clip)
                }
                return MulticamPauseEdit(id: .init(occurrence: index, span: pause), visible: visible,
                                         removal: removal, isProtected: keep)
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
                                     container: String)
        -> (ends: [RationalTime], starts: [RationalTime]) {
        var starts: [RationalTime] = []
        var ends: [RationalTime] = []
        let first = intervals.lowerBound { $0.group.to >= window.from }
        for interval in intervals[first...] {
            if interval.group.from > window.to { break }
            guard let offset = offsets[interval.angle], let info = media[interval.angle],
                  let sourceStart = try? max(window.from, interval.group.from).subtracting(offset),
                  let sourceEnd = try? min(window.to, interval.group.to).subtracting(offset) else { continue }
            let frameAccurate = smartAngles.contains(interval.angle)
            let frames = info.frames
            let index = frames.lowerBound { $0.time >= sourceStart }
            for frame in frames[index...] {
                if frame.time > sourceEnd { break }
                guard let time = try? frame.time.adding(offset) else { continue }
                let initialStart = frame.time == frames.first?.time && info.sourceStartSafe
                if time < interval.group.to, initialStart || frameAccurate || frame.canStart,
                   soundAllows(time, in: interval, start: true, offsets: offsets, sound: sound, container: container) {
                    starts.append(time)
                }
                if time > interval.group.from, frameAccurate || frame.canEnd,
                   soundAllows(time, in: interval, start: false, offsets: offsets, sound: sound, container: container) {
                    ends.append(time)
                }
            }
            if info.duration >= sourceStart, info.duration <= sourceEnd,
               let end = try? info.duration.adding(offset), end > interval.group.from,
               soundAllows(end, in: interval, start: false, offsets: offsets, sound: sound, container: container) {
                ends.append(end)
            }
        }
        return (ends.sorted(), starts.sorted())
    }

    private static func soundIndexes(_ plan: MulticamPlan, media: [String: MediaInfo])
        -> [MulticamAudioSelection: MediaInfo] {
        let routes = Set(plan.intervals.compactMap(\.audio))
        var indexes: [MulticamAudioSelection: MediaInfo] = [:]
        for route in routes {
            guard let info = media[route.source],
                  let track = info.audio.first(where: { $0.stream.index == route.stream }) else { continue }
            indexes[route] = MediaInfo(url: info.url, format: info.format, duration: track.end,
                                       origin: info.origin, streams: [track.stream], frames: [], audio: [track],
                                       copyIssue: nil, sourceStartSafe: info.sourceStartSafe,
                                       identity: info.identity, videoIndex: -1)
        }
        return indexes
    }

    private static func soundAllows(_ time: RationalTime, in interval: MulticamInterval, start: Bool,
                                    offsets: [String: RationalTime], sound: [MulticamAudioSelection: MediaInfo],
                                    container: String) -> Bool {
        guard let selection = interval.audio else { return true }
        guard let media = sound[selection], let offset = offsets[selection.source],
              let input = try? time.subtracting(offset),
              let output = try? interval.output.from.adding(time.subtracting(interval.group.from)) else { return false }
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
        AnalysisSidecar(media: media).read("thresholdOverrides.v1", cancelled: cancelled)
            .flatMap { try? JSONDecoder().decode([Int: Double].self, from: $0)[stream] }
            .flatMap { (-120...0).contains($0) ? $0 : nil }
    }

    package static func routes(plan: MulticamPlan?, project: MulticamProject,
                               media: [String: MediaInfo]) -> [MulticamSilenceRoute] {
        let offsets = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0.offset) })
        return (plan?.audio ?? []).compactMap { span in
            guard let stream = span.stream, let offset = offsets[span.source] else { return nil }
            return route(.init(source: span.source, stream: stream), input: span.input, offset: offset, media: media)
        }
    }

    private static func route(_ selection: MulticamAudioSelection, input: MulticamRange, offset: RationalTime,
                              media: [String: MediaInfo]) -> MulticamSilenceRoute? {
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
                     input: .init(from: inputFrom, to: inputTo), offset: analysisOffset)
    }

    package static func inputMinimum(_ minimum: Double, routes: [MulticamSilenceRoute]) -> Double {
        // A continuous program pause can be made up of short runs on different microphones.
        Set(routes.map(\.selection)).count > 1 ? min(minimum, 1 / Double(AudioWaveform.rate)) : minimum
    }

    package static func routedPauses(_ routes: [MulticamSilenceRoute],
                                     silences: [MulticamAudioSelection: SilenceAnalysisResult],
                                     minimum: Double = 0) -> [AudioSpan] {
        var quiet: [AudioSpan] = []
        var covered: [AudioSpan] = []
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
        return SilenceRuns(quiet: merged(quiet), covered: merged(covered)).pauses(minimum: minimum)
    }
}
