import Foundation

final class TranscriptBoundaryResolver {
    let project: CutProject
    let timeline: TranscriptEditTimeline
    let projectURL: URL?
    let engine = CutEngine()
    let tierEvaluator = TimelineTierEvaluator()
    var sequenceMedia: [String: MediaInfo]
    var multicamMedia: [String: MediaInfo]
    private struct CopyGridKey: Hashable {
        let url: URL
        let clockOffset: RationalTime
        let starting: Bool
    }
    private var copyGrids: [CopyGridKey: [RationalTime]] = [:]
    private var unavailable = Set<URL>()
    private(set) var boundaries: [TranscriptEditBoundary] = []

    init(project: CutProject, timeline: TranscriptEditTimeline, projectURL: URL?,
         sequenceMedia: [String: MediaInfo], multicamMedia: [String: MediaInfo]) {
        self.project = project
        self.timeline = timeline
        self.projectURL = projectURL
        self.sequenceMedia = sequenceMedia
        self.multicamMedia = multicamMedia
    }

    private func url(_ file: String) -> URL {
        let directory = projectURL.map(ProjectFile.directory(of:))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return ProjectFile.sourceURL(file: file, in: directory)
    }

    private func sequenceIndex(_ file: String) -> MediaInfo? {
        if let info = sequenceMedia[file], info.hasFullEditIndex { return info }
        let location = url(file)
        if let info = sequenceMedia[location.path], info.hasFullEditIndex { return info }
        guard projectURL != nil, !unavailable.contains(location) else { return nil }
        let indexed = AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
            try? engine.inspect(location, keyframes: true)
        }
        if let info = indexed {
            sequenceMedia[file] = info
            return info
        }
        unavailable.insert(location)
        return nil
    }

    private func multicamIndex(_ source: MulticamSource) -> MediaInfo? {
        if let info = multicamMedia[source.id], info.hasFullEditIndex { return info }
        let location = url(source.file)
        guard projectURL != nil, !unavailable.contains(location) else { return nil }
        let indexed = AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
            try? engine.inspectMulticamSource(location)
        }
        if let info = indexed {
            multicamMedia[source.id] = info
            return info
        }
        unavailable.insert(location)
        return nil
    }

    func item(at time: RationalTime, starting: Bool, clipID: String? = nil,
              assemblyIndex: Int? = nil) throws -> TranscriptEditTimeline.Item {
        if let assemblyIndex, timeline.items.indices.contains(assemblyIndex) {
            let item = timeline.items[assemblyIndex]
            if time >= item.output.from, time <= item.output.to { return item }
        }
        if let clipID, let item = timeline.items.first(where: {
            $0.sequence?.source?.id == clipID && time >= $0.output.from && time <= $0.output.to
        }) { return item }
        let position = timeline.items.lowerBound { item in
            starting ? item.output.to > time : item.output.to >= time
        }
        if timeline.items.indices.contains(position), time >= timeline.items[position].output.from {
            return timeline.items[position]
        }
        if let item = timeline.items.last, time == item.output.to { return item }
        throw transcriptEditError("The selected boundary lies outside the timeline.")
    }

    func resolve(_ time: RationalTime, starting: Bool, policy: TranscriptEditRequest.BoundaryPolicy,
                 preferredClip: String? = nil, nudge: Int = 0, within safe: MulticamRange? = nil) throws -> RationalTime {
        let item = try item(at: time, starting: starting, clipID: preferredClip)
        if nudge == 0, time == item.output.from || time == item.output.to {
            boundaries.append(.init(space: .currentCut, requested: time, resolved: time, copySafeAlternatives: []))
            return time
        }
        let input = try item.inputTime(time)
        let delta = try item.output.from.subtracting(item.input.from)
        let bounds: MulticamRange
        if let safe {
            bounds = try .init(from: item.inputTime(max(safe.from, item.output.from)),
                               to: item.inputTime(min(safe.to, item.output.to)))
        } else {
            bounds = item.input
        }
        if let clip = item.sequence?.source {
            return try resolve(input, with: sequenceIndex(clip.file), bounds: bounds,
                               starting: starting, shift: delta, space: .currentCut, policy: policy, nudge: nudge)
        }
        if let still = item.still {
            let rate = RationalTime(numerator: still.cadence.denominator, denominator: still.cadence.numerator)
            let frames = try input.multiplied(by: rate).roundedToSamples(1)
            let (moved, overflow) = frames.addingReportingOverflow(Int64(nudge))
            guard !overflow else { throw transcriptEditError("The frame nudge crosses the card boundary.") }
            let snapped = try still.cadence.multiplied(by: RationalTime(numerator: moved, denominator: 1))
            guard snapped >= bounds.from, snapped <= bounds.to else {
                throw transcriptEditError("The frame nudge crosses the card boundary.")
            }
            let result = try (policy == .exact && nudge == 0 ? input : snapped).adding(delta)
            boundaries.append(.init(space: .currentCut, requested: time, resolved: result, copySafeAlternatives: []))
            return result
        }
        guard case .multicam(let multicam) = project else { throw transcriptEditError("Unknown transcript edit boundary.") }
        return try resolveGroup(input, in: multicam, bounds: bounds, starting: starting,
                                shift: delta, space: .currentCut, policy: policy, angleOverride: item.multicam?.angleOverride, nudge: nudge)
    }

    func sequenceExcerpt(_ selection: TranscriptResolvedSelection,
                         policy: TranscriptEditRequest.BoundaryPolicy, startNudge: Int, endNudge: Int) throws -> CutSequenceClip {
        guard let file = selection.first.file, let wordSource = selection.first.sequenceSourceRange else {
            throw transcriptEditError("This passage requires an unambiguous source recording binding.")
        }
        let clock = try selection.first.range.from.subtracting(wordSource.from)
        let source = try selection.range.editShifted(by: .zero.subtracting(clock))
        let info = sequenceIndex(file)
        let bounds = MulticamRange(from: .zero, to: info?.duration ?? source.to)
        let boundaryStart = boundaries.count
        _ = try resolve(source.from, with: info, bounds: bounds, starting: true,
                        shift: clock, space: .source, policy: policy, nudge: startNudge)
        _ = try resolve(source.to, with: info, bounds: bounds, starting: false,
                        shift: clock, space: .source, policy: policy, nudge: endNudge)
        for index in boundaryStart..<boundaries.count { boundaries[index].attachmentID = selection.attachmentID }
        let paired = try latestRange(policy: policy)
        let from = try paired.from.subtracting(clock)
        let to = try paired.to.subtracting(clock)
        let namespace = selection.attachmentID ?? ""
        let word = "\(namespace.utf8.count):\(namespace)\(selection.first.wordID)"
        let identifier = TranscriptStore.digest(Data(word.utf8)).prefix(16)
        return .init(id: "transcript-\(identifier)", file: file, from: from, to: to)
    }

    func groupExcerpt(_ selection: TranscriptResolvedSelection,
                      policy: TranscriptEditRequest.BoundaryPolicy, startNudge: Int, endNudge: Int) throws -> MulticamRange {
        guard case .multicam(let multicam) = project else {
            throw transcriptEditError("A group excerpt requires a multicam project.")
        }
        let range = try groupRange(selection)
        let boundaryStart = boundaries.count
        _ = try resolveGroup(range.from, in: multicam, bounds: multicam.range,
                             starting: true, space: .group, policy: policy, nudge: startNudge)
        _ = try resolveGroup(range.to, in: multicam, bounds: multicam.range,
                             starting: false, space: .group, policy: policy, nudge: endNudge)
        for index in boundaryStart..<boundaries.count { boundaries[index].attachmentID = selection.attachmentID }
        return try latestRange(policy: policy)
    }

    /// Resolve a whole interval when the independently nearest copy points land
    /// on the same GOP edge. Both adjusted coordinates are part of the review.
    func latestRange(policy: TranscriptEditRequest.BoundaryPolicy) throws -> MulticamRange {
        let upper = boundaries.count - 1
        let lower = upper - 1
        let left = boundaries[lower]
        let right = boundaries[upper]
        if left.resolved < right.resolved { return .init(from: left.resolved, to: right.resolved) }
        if policy == .copySafe {
            let starts = Array(Set([left.resolved] + left.copySafeAlternatives)).sorted()
            let ends = Array(Set([right.resolved] + right.copySafeAlternatives)).sorted()
            let candidates = starts.flatMap { from in
                ends.filter { from < $0 }.map { MulticamRange(from: from, to: $0) }
            }
            func score(_ range: MulticamRange) -> Double {
                abs(range.from.seconds - left.requested.seconds) + abs(range.to.seconds - right.requested.seconds)
            }
            if let candidate = candidates.min(by: { score($0) < score($1) }) {
                boundaries[lower].resolved = candidate.from
                boundaries[upper].resolved = candidate.to
                return candidate
            }
        }
        throw transcriptEditError("These boundaries leave no complete media. Select a longer passage or choose a different boundary policy.",
                                  code: "transcript_empty_edit_range")
    }

    private func groupRange(_ selection: TranscriptResolvedSelection) throws -> MulticamRange {
        if selection.space == .group { return selection.range }
        guard let group = selection.first.groupRange else {
            throw transcriptEditError("The selected word has no synchronized group location.")
        }
        return try selection.range.editShifted(by: group.from.subtracting(selection.first.range.from))
    }

    func switchAngle(_ angle: String, selection: TranscriptResolvedSelection, edge: TranscriptEditRequest.Edge,
                     policy: TranscriptEditRequest.BoundaryPolicy, nudge: Int) throws -> CutProject {
        guard case .multicam(var multicam) = project, multicam.angles.contains(where: { $0.id == angle }) else {
            throw transcriptEditError("Choose an angle in this multicam group.")
        }
        let endpoint = edge == .start ? selection.first : selection.last
        let requested = edge == .start ? selection.range.from : selection.range.to
        let from: RationalTime
        if selection.space == .currentCut {
            guard let group = endpoint.groupRange else { throw transcriptEditError("The word has no synchronized camera location.") }
            from = try (edge == .start ? group.from : group.to)
                .adding(requested.subtracting(edge == .start ? endpoint.range.from : endpoint.range.to))
        } else {
            let range = try groupRange(selection)
            from = edge == .start ? range.from : range.to
        }
        guard let camera = multicam.pictureSource(for: angle, at: from) else {
            throw transcriptEditError("The selected camera has a recording gap at this point.")
        }
        let at = try resolveGroup(from, in: multicam, bounds: multicam.range, starting: true, space: .group,
                                  policy: policy, preferredCamera: camera, nudge: nudge)
        guard multicam.range.contains(at), let current = multicam.selection(at: at) else {
            throw transcriptEditError("The camera switch lies outside the group.")
        }
        if let info = multicamIndex(camera) {
            let local = try at.subtracting(camera.offset)
            guard info.hasVideo, let firstFrame = info.frames.first, firstFrame.time <= local, local < info.duration else {
                throw transcriptEditError("The selected camera has no picture at this point.")
            }
        }
        if current.angle == angle { return project }
        let marker = MulticamSwitch(at: at, angle: angle, audio: current.audio)
        let position = multicam.switches.lowerBound { $0.at >= at }
        if position < multicam.switches.count, multicam.switches[position].at == at {
            multicam.switches[position] = marker
        } else {
            multicam.switches.insert(marker, at: position)
        }
        let updated = CutProject.multicam(multicam)
        try updated.validate()
        return updated
    }

    private func resolveGroup(_ time: RationalTime, in multicam: MulticamProject, bounds: MulticamRange,
                              starting: Bool, shift: RationalTime = .zero, space: TranscriptSpace,
                              policy: TranscriptEditRequest.BoundaryPolicy,
                              preferredCamera: MulticamSource? = nil, angleOverride: String? = nil, nudge: Int = 0) throws -> RationalTime {
        let marker = starting ? multicam.selection(at: time) : multicam.switches.last { $0.at < time }
        let source = preferredCamera ?? (angleOverride ?? marker?.angle).flatMap {
            multicam.pictureSource(for: $0, at: time, exclusiveEnd: !starting)
        }
        let offset = source?.offset ?? .zero
        let extent = source?.coverage.map { MulticamRange(from: max(bounds.from, $0.from), to: min(bounds.to, $0.to)) } ?? bounds
        let localBounds = try extent.editShifted(by: .zero.subtracting(offset))
        return try resolve(time.subtracting(offset), with: source.flatMap(multicamIndex), bounds: localBounds,
                           starting: starting, shift: shift.adding(offset), space: space, policy: policy, nudge: nudge)
    }

    private func resolve(_ requested: RationalTime, with media: MediaInfo?, bounds: MulticamRange,
                         starting: Bool, shift: RationalTime = .zero, space: TranscriptSpace,
                         policy: TranscriptEditRequest.BoundaryPolicy, nudge: Int = 0) throws -> RationalTime {
        let time = nudge == 0 ? requested : try nudging(requested, by: nudge, in: media)
        guard time >= bounds.from, time <= bounds.to else {
            throw transcriptEditError("The boundary at \(time.description) lies outside the valid range \(bounds.from.description)–\(bounds.to.description).")
        }
        func nearby(_ points: [RationalTime]) -> [RationalTime] {
            let position = points.lowerBound { $0 >= time }
            return [position - 1, position, position + 1].compactMap { index in
                guard points.indices.contains(index), points[index] >= bounds.from, points[index] <= bounds.to else { return nil }
                return points[index]
            }.sorted { lhs, rhs in
                let left = abs(lhs.seconds - time.seconds), right = abs(rhs.seconds - time.seconds)
                return left == right ? lhs < rhs : left < right
            }
        }

        let copy: [RationalTime]
        let frame: RationalTime?
        let frameAlternatives: [RationalTime]
        if let media {
            let key = CopyGridKey(url: media.url, clockOffset: media.multicamClockOffset, starting: starting)
            if copyGrids[key] == nil {
                copyGrids[key] = engine.validBoundaries(in: media, start: starting, first: false, last: false)
            }
            copy = nearby(copyGrids[key] ?? [])
            if media.hasVideo {
                let position = media.frames.lowerBound { $0.time >= time }
                var neighbors = [position - 1, position].compactMap { index in
                    media.frames.indices.contains(index) ? media.frames[index].time : nil
                }
                if !starting { neighbors.append(media.duration) }
                frameAlternatives = nearby(neighbors.sorted())
                frame = frameAlternatives.first
            } else if media.audio.isEmpty {
                frameAlternatives = []
                frame = nil
            } else {
                let nearest = media.audioEditBoundary(near: time.seconds)
                let before = media.audioEditBoundary(near: time.seconds, rounding: .down)
                let after = media.audioEditBoundary(near: time.seconds, rounding: .up)
                frameAlternatives = nearby(Array(Set([before, after])).sorted())
                frame = nearest >= bounds.from && nearest <= bounds.to ? nearest : frameAlternatives.first
            }
        } else {
            frame = nil
            frameAlternatives = []
            copy = []
        }

        let resolved: RationalTime
        switch policy {
        case .exact:
            if media != nil, frame != time {
                let alternatives = try frameAlternatives.map { try $0.adding(shift) }
                throw CutError(code: "transcript_exact_boundary_unavailable",
                               message: "This exact time does not lie on an indexed frame or audio boundary. Use a listed time or plan again with Nearest Frame.",
                               boundary: starting ? "from" : "to", nearest: alternatives)
            }
            resolved = time
        case .nearestFrame:
            if media != nil, frame == nil {
                throw transcriptEditError("No indexed frame or audio boundary is available inside this occurrence.",
                                          code: "transcript_boundary_unavailable")
            }
            resolved = frame ?? time
        case .copySafe:
            guard let candidate = copy.first else {
                throw transcriptEditError("No copy-safe boundary is available here.", code: "transcript_copy_boundary_unavailable")
            }
            resolved = candidate
        }
        let output = try resolved.adding(shift)
        var boundary = try TranscriptEditBoundary(space: space, requested: requested.adding(shift), resolved: output,
                                                  copySafeAlternatives: copy.map { try $0.adding(shift) })
        // Without an index the time cannot be checked or snapped. The plan says so instead of passing it as a frame.
        if media == nil { boundary.unindexed = true }
        boundaries.append(boundary)
        return output
    }

    private func nudging(_ time: RationalTime, by frames: Int, in media: MediaInfo?) throws -> RationalTime {
        guard let media else {
            throw transcriptEditError("Index the recording before nudging a frame boundary.",
                                      code: "transcript_boundary_unavailable")
        }
        if media.hasVideo {
            let next = media.frames.lowerBound { $0.time >= time }
            let previous = next - 1
            let lower = media.frames.indices.contains(previous) ? media.frames[previous].time : nil
            let upper = media.frames.indices.contains(next) ? media.frames[next].time : media.duration
            let nearest = lower.map { abs(time.seconds - $0.seconds) <= abs(upper.seconds - time.seconds) }
                == true ? previous : next
            let moved = nearest + frames
            if moved == media.frames.count { return media.duration }
            guard media.frames.indices.contains(moved) else {
                throw transcriptEditError("The frame nudge extends outside its recording.")
            }
            return media.frames[moved].time
        }
        guard !media.audio.isEmpty else { throw transcriptEditError("This recording has no indexed audio clock.") }
        var moved = media.audioEditBoundary(near: time.seconds)
        for _ in 0..<abs(frames) {
            let next = media.steppingAudioBoundary(from: moved.seconds, direction: frames > 0 ? 1 : -1)
            guard moved != next else { throw transcriptEditError("The audio nudge extends outside its recording.") }
            moved = next
        }
        return moved
    }

    func tier(of project: CutProject) -> TierSummary? {
        AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
            self.evaluateTier(of: project)
        }
    }

    private func evaluateTier(of project: CutProject) -> TierSummary? {
        guard projectURL != nil || !sequenceMedia.isEmpty || !multicamMedia.isEmpty else { return nil }
        if case .multicam(let multicam) = project {
            return MulticamEngine().tier(multicam, relativeTo: projectURL, indexedSources: multicamMedia).summary(source: .multicam)
        }
        if project.requiresPictureProcessing {
            return ParticipantProjectExport.tier(project, relativeTo: projectURL).summary(source: .movie)
        }
        if !project.stillInserts.isEmpty || !project.stillReplacements.isEmpty {
            return StillExportPlanner().tier(project, relativeTo: projectURL).summary(source: .movie)
        }
        let clips = project.sequenceClips ?? []
        let requests = clips.map { ClipRequest(file: url($0.file), from: $0.from, to: $0.to) }
        var media: [URL: MediaInfo] = [:]
        for clip in clips { media[url(clip.file)] = sequenceIndex(clip.file) }
        return tierEvaluator.summary(requests, media: media)
    }

    func affectedOccurrences(_ selections: [TranscriptResolvedSelection], updated: CutProject,
                             action: TranscriptEditRequest.Action) throws -> [String] {
        if action == .switchAngle, case .multicam(let original) = project, case .multicam(let changed) = updated {
            guard let marker = changed.switches.first(where: { !original.switches.contains($0) }) else { return [] }
            let end = changed.switches.first(where: { $0.at > marker.at })?.at ?? changed.range.to
            return timeline.items.enumerated().compactMap { index, item in
                guard let group = item.multicam?.group, group.from < end, marker.at < group.to else { return nil }
                return "assembly:\(index)"
            }
        }
        var seen = Set<String>()
        var affected: [String] = []
        for selection in selections {
            for range in try timeline.outputRanges(for: selection) {
                for index in timeline.outputItemIndices(overlapping: range) {
                    let item = timeline.items[index]
                    let id = item.sequence?.source?.id ?? item.still?.id ?? "assembly:\(index)"
                    if seen.insert(id).inserted { affected.append(id) }
                }
            }
        }
        return affected
    }
}
