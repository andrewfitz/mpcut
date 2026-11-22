import Foundation

extension MulticamEngine {
    func pictureAlternatives(at seam: RationalTime, mapping: MulticamPlan,
                             media: [String: MediaInfo], mode: ExportMode, container: String,
                             validateAudio: Bool, convertedAudio: ReencodeAudio?,
                             settings: ReencodeSettings = .init()) throws -> [RationalTime] {
        try switchAlternatives(at: seam, mapping: mapping, media: media, mode: mode, container: container,
                               validateAudio: validateAudio, convertedAudio: convertedAudio, soundOnly: false, settings: settings)
    }

    func soundOnlyAlternatives(at seam: RationalTime, mapping: MulticamPlan, media: [String: MediaInfo],
                               container: String) throws -> [RationalTime] {
        try switchAlternatives(at: seam, mapping: mapping, media: media, mode: .copy, container: container,
                               validateAudio: true, convertedAudio: nil, soundOnly: true, settings: .init())
    }

    private func switchAlternatives(at seam: RationalTime, mapping: MulticamPlan, media: [String: MediaInfo],
                                    mode: ExportMode, container: String, validateAudio: Bool,
                                    convertedAudio: ReencodeAudio?, soundOnly: Bool,
                                    settings: ReencodeSettings) throws -> [RationalTime] {
        let spans = soundOnly ? mapping.audio : mapping.picture
        guard let leftIndex = spans.firstIndex(where: { $0.output.to == seam }),
              spans.indices.contains(leftIndex + 1) else { return [] }
        let left = spans[leftIndex]
        let right = spans[leftIndex + 1]
        let leftGroup = try groupRange(left, in: mapping)
        let rightGroup = try groupRange(right, in: mapping)
        guard leftGroup.to == rightGroup.from,
              let opening = mapping.intervals.first(where: { $0.output.to == seam }),
              let closing = mapping.intervals.first(where: { $0.output.from == seam }),
              opening.assemblyIndex == closing.assemblyIndex,
              let outgoing = media[left.source], let incoming = media[right.source] else { return [] }
        let leftOffset = try leftGroup.from.subtracting(left.input.from)
        let rightOffset = try rightGroup.from.subtracting(right.input.from)
        let grids: [MulticamBoundary.Grid]
        if soundOnly {
            let groupOrigin = try rightGroup.from.subtracting(seam)
            grids = try [
                audioGrid(left, media: outgoing, starting: false, sourceOffset: leftOffset, seam: seam,
                          groupOrigin: groupOrigin, container: container),
                audioGrid(right, media: incoming, starting: true, sourceOffset: rightOffset, seam: seam,
                          groupOrigin: groupOrigin, container: container)
            ]
        } else {
            grids = [
                .init(media: outgoing, offset: leftOffset, edge: .end, mode: mode, container: container),
                .init(media: incoming, offset: rightOffset, edge: .start, mode: mode, container: container)
            ]
        }

        // Match the marker's decisions as well as its time. An assembly can
        // contain several unrelated projects on overlapping group clocks.
        let occurrences = zip(mapping.intervals, mapping.intervals.dropFirst()).filter { earlier, later in
            earlier.assemblyIndex == later.assemblyIndex && earlier.group.to == opening.group.to
                && later.group.from == closing.group.from
                && sameDecision(earlier, opening) && sameDecision(later, closing)
        }
        let lower = occurrences.map { $0.0.group.from }.max() ?? opening.group.from
        let upper = occurrences.map { $0.1.group.to }.min() ?? closing.group.to
        return try MulticamBoundary.candidates(near: rightGroup.from, among: grids,
                                               within: lower...upper,
                                               cancelled: cancelled ?? { false }) { candidate in
            guard candidate > lower, candidate < upper else { return false }
            do {
                let candidateMapping = try movingMarker(from: opening, to: closing, at: candidate, in: mapping)
                if validateAudio && candidateMapping.audio != mapping.audio {
                    if let convertedAudio {
                        _ = try resolveConvertedSound(candidateMapping, sources: media, container: container, action: convertedAudio)
                    } else {
                        _ = try resolveSound(candidateMapping, sources: media, container: container)
                    }
                }
                if !soundOnly {
                    let engine = CutEngine(multicamSmartPicture: mode == .smart, cancelled: cancelled)
                    var cached: [URL: MediaInfo] = [:]
                    let requests = try candidateMapping.picture.map { span in
                        guard let source = media[span.source] else {
                            throw CutError(code: "missing_source", message: "A selected angle has no indexed source.")
                        }
                        let info = try cached[source.url] ?? isolatedPicture(source, using: engine)
                        cached[source.url] = info
                        try checkPictureCoverage(info, span: span, mapping: candidateMapping, container: container)
                        return ClipRequest(file: source.url, from: span.input.from, to: span.input.to)
                    }
                    if mode == .encode {
                        let pictureSettings = ReencodeSettings(codec: settings.codec, quality: settings.quality,
                                                               audio: .removeAudio)
                        _ = try ReencodeEngine(cancelled: cancelled).resolve(requests, media: cached,
                                                                            container: container, settings: pictureSettings)
                    } else {
                        _ = try engine.resolve(requests, media: cached, container: container)
                    }
                }
                return true
            } catch let error as CutError where error.code != "cancelled" && error.code != "source_changed" {
                return false
            }
        }
    }

    /// Nearby group times for the start or end of an assembly range. Each is a valid cut for
    /// every selected stream at that edge. `failure` resolves a replanned program and returns
    /// its fault. A fault at a later boundary is reported in turn once this edge has moved.
    func edgeAlternatives(_ edge: MulticamEdge, mapping: MulticamPlan, media: [String: MediaInfo],
                          mode: ExportMode, container: String, picture: Bool, sound: Bool,
                          adjusting: MulticamEdgePlanner,
                          failure: (MulticamPlan) throws -> CutError?) throws -> [RationalTime] {
        let starting = edge.boundary == "from"
        func output(of time: RationalTime, in plan: MulticamPlan) -> RationalTime? {
            plan.intervals.first { $0.assemblyIndex == edge.range - 1 && (starting ? $0.group.from : $0.group.to) == time }
                .map { starting ? $0.output.from : $0.output.to }
        }
        guard let seam = output(of: edge.at, in: mapping) else { return [] }
        // The lane span at the edge, with the offset from its source clock to the group clock.
        func lane(_ spans: [MulticamSpan]) throws -> (span: MulticamSpan, offset: RationalTime)? {
            guard let span = spans.first(where: {
                starting ? $0.output.from <= seam && seam < $0.output.to : $0.output.from < seam && seam <= $0.output.to
            }) else { return nil }
            let local = try span.input.from.adding(seam.subtracting(span.output.from))
            return (span, try edge.at.subtracting(local))
        }
        func continuousInput(_ spans: [MulticamSpan], with selected: MulticamSpan) throws -> RationalTime? {
            // Moving this edge may reconnect it to the other side of the assembly seam.
            let neighbor = spans.first {
                starting ? $0.output.from < seam && seam <= $0.output.to : $0.output.from <= seam && seam < $0.output.to
            }
            guard let neighbor, neighbor.source == selected.source, neighbor.stream == selected.stream else { return nil }
            return try neighbor.input.from.adding(seam.subtracting(neighbor.output.from))
        }
        var grids: [MulticamBoundary.Grid] = []
        if picture, let (span, offset) = try lane(mapping.picture), let source = media[span.source] {
            let engine = CutEngine(multicamSmartPicture: mode == .smart, cancelled: cancelled)
            let grid = MulticamBoundary.Grid(media: try isolatedPicture(source, using: engine), offset: offset,
                                             edge: starting ? .start : .end, mode: mode, container: container,
                                             first: starting && seam == .zero, last: !starting && seam == mapping.duration)
            grids.append(grid.including(try continuousInput(mapping.picture, with: span)))
        }
        var checksSamples = false
        if sound, let (span, offset) = try lane(mapping.audio), let source = media[span.source],
           let index = span.stream, let track = source.audio.first(where: { $0.stream.index == index }) {
            let selector = CutEngine(cancelled: cancelled, tracks: .audio, audioStream: index)
            let selected = try selector.selectedMedia(source)
            let join = try continuousInput(mapping.audio, with: span)
            let first = starting ? seam == .zero : span.output.from == .zero
            let last = starting ? span.output.to == mapping.duration : seam == mapping.duration
            let sampleCopy = track.stream.isPCM || selector.supportsAACEdits(track.stream, container: container)
            let wholeCrop = first && last && (supportsOpusTrim(track, media: selected, container: container)
                || selector.supportsMP3Crop(track.stream, media: selected, container: container))
            if sampleCopy || wholeCrop {
                let rate = track.stream.sampleRate
                guard rate > 0 else { return [] }
                let origin = sampleCopy ? selected.origin : .zero
                checksSamples = true
                if grids.isEmpty {
                    let sample = try origin.adding(edge.at.subtracting(offset)).roundedToSamples(rate)
                    let times = try [-1, 0, 1].compactMap { delta -> RationalTime? in
                        let (moved, overflow) = sample.addingReportingOverflow(Int64(delta))
                        return overflow ? nil : try RationalTime(numerator: moved, denominator: Int64(rate)).subtracting(origin)
                    }
                    grids.append(MulticamBoundary.Grid(times: times, offset: offset).including(join))
                }
            } else {
                let needsHistory = ["aac", "mp3", "opus", "vorbis"].contains(track.stream.codec)
                let times: [RationalTime]
                if needsHistory, starting || !last || !track.presentationEdits.isEmpty {
                    // A discontinuous internal edge cannot restore decoder history.
                    // Only a continuous join or an original outer edge can work.
                    times = starting ? (first ? [.zero] : []) : (last ? [track.end] : [])
                } else {
                    var packets = track.packets.compactMap { packet in
                        packet.time >= .zero && packet.time <= track.end ? packet.time : nil
                    }
                    if starting, first, packets.first != .zero { packets.insert(.zero, at: 0) }
                    if !starting, packets.last != track.end, let tail = track.packets.last,
                       last || (tail.discardSamples == 0 && (try? tail.time.adding(tail.duration)) == track.end) {
                        packets.append(track.end)
                    }
                    times = packets
                }
                grids.append(MulticamBoundary.Grid(times: times, offset: offset).including(join))
            }
        }
        let extents = try grids.compactMap { try $0.extent() }
        guard !grids.isEmpty, extents.count == grids.count,
              let lower = extents.map(\.lowerBound).max(), let upper = extents.map(\.upperBound).min(),
              lower <= upper else { return [] }

        // The active microphone can change when a range crosses a switch. Inspect
        // the widest feasible occurrence once, then reject off-clock candidates
        // without rebuilding the assembly for each picture or packet.
        let clockPlan: MulticamPlan
        if checksSamples, let grid = grids.first {
            clockPlan = try grid.expandedPlan(from: edge.at, toward: starting ? max(.zero, lower) : upper,
                                              original: mapping) { candidate in
                do { return try adjusting(edge.range, edge.boundary, candidate) }
                catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                    return nil
                }
            }
        } else { clockPlan = mapping }
        var decisions: [MulticamInterval] = []
        if checksSamples {
            for interval in clockPlan.intervals where interval.assemblyIndex == edge.range - 1 {
                if let previous = decisions.last, previous.group.to != interval.group.from { break }
                decisions.append(interval)
            }
        }
        let neighbor = mapping.audio.first {
            starting ? $0.output.from < seam && seam <= $0.output.to : $0.output.from <= seam && seam < $0.output.to
        }
        let neighborTime = try neighbor.map { try $0.input.from.adding(seam.subtracting($0.output.from)) }
        let audioEngine = CutEngine(cancelled: cancelled)
        func admitsSample(_ candidate: RationalTime) throws -> Bool {
            let index = decisions.lowerBound { starting ? $0.group.to > candidate : $0.group.to >= candidate }
            guard decisions.indices.contains(index) else { return true }
            let decision = decisions[index]
            guard decision.group.from <= candidate, let selected = decision.audio, let source = media[selected.source],
                  let track = source.audio.first(where: { $0.stream.index == selected.stream }) else { return true }
            let spanIndex = clockPlan.audio.lowerBound { $0.output.to > decision.output.from }
            guard clockPlan.audio.indices.contains(spanIndex) else { return true }
            let span = clockPlan.audio[spanIndex]
            let local = try span.input.from.adding(decision.output.from.subtracting(span.output.from))
                .adding(candidate.subtracting(decision.group.from))
            if neighbor?.source == selected.source, neighbor?.stream == selected.stream, local == neighborTime { return true }
            let rate = Int64(track.stream.sampleRate)
            guard rate > 0 else { return false }
            let sampleCopy = track.stream.isPCM || audioEngine.supportsAACEdits(track.stream, container: container)
            if !sampleCopy { return true } // Packet grids or a replan validate other codecs.
            let output = starting ? seam : try seam.adding(candidate.subtracting(edge.at))
            return try rate.isMultiple(of: source.origin.adding(local).denominator) && rate.isMultiple(of: output.denominator)
        }

        return try MulticamBoundary.search(near: edge.at, among: grids, within: lower...upper,
                                           cancelled: cancelled ?? { false }) { candidate in
            if checksSamples, try !admitsSample(candidate) { return .skip }
            let plan: MulticamPlan
            do {
                plan = try adjusting(edge.range, edge.boundary, candidate)
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                // The requested edge is inside the group. Once it passes the
                // opposite range edge or the group extent, farther times are outside too.
                if issue.code == "invalid_range" || issue.code == "invalid_multicam_project" { return .stopDirection }
                return .skip
            }
            guard output(of: candidate, in: plan) != nil else { return .skip }
            guard let issue = try failure(plan) else { return .accept }
            if issue.code == "cancelled" || issue.code == "source_changed" { throw issue }
            // A located fault at another boundary leaves this edge acceptable.
            guard let context = issue.multicam, issue.boundary != nil else { return .skip }
            if let other = context.edge, other.range == edge.range, other.boundary == edge.boundary { return .skip }
            return .accept
        }
    }

    private func sameDecision(_ lhs: MulticamInterval, _ rhs: MulticamInterval) -> Bool {
        lhs.angle == rhs.angle && lhs.audio == rhs.audio
    }

    private func movingMarker(from before: MulticamInterval, to after: MulticamInterval,
                              at candidate: RationalTime, in mapping: MulticamPlan) throws -> MulticamPlan {
        let marker = before.group.to
        let advancing = candidate < marker
        let previous = advancing ? before : after
        let replacement = advancing ? after : before
        let affected = MulticamRange(from: min(marker, candidate), to: max(marker, candidate))
        var intervals: [MulticamInterval] = []
        var picture: [MulticamSpan] = []
        var audio: [MulticamSpan] = []

        func span(_ lane: [MulticamSpan], for interval: MulticamInterval) -> MulticamSpan? {
            let index = lane.lowerBound { $0.output.to > interval.output.from }
            guard lane.indices.contains(index), lane[index].output.from <= interval.output.from else { return nil }
            return lane[index]
        }

        func append(_ group: MulticamRange, in original: MulticamInterval, using decision: MulticamInterval) throws {
            let outputOffset = try original.output.from.subtracting(original.group.from)
            let output = try MulticamRange(from: group.from.adding(outputOffset), to: group.to.adding(outputOffset))
            intervals.append(.init(group: group, output: output, angle: decision.angle,
                                   audio: decision.audio, assemblyIndex: original.assemblyIndex))

            func appendSpan(_ originalLane: [MulticamSpan], to lane: inout [MulticamSpan]) throws {
                guard let selected = span(originalLane, for: decision) else { return }
                let sourceOffset = try selected.input.from.subtracting(selected.output.from)
                    .adding(decision.output.from).subtracting(decision.group.from)
                let input = try MulticamRange(from: group.from.adding(sourceOffset), to: group.to.adding(sourceOffset))
                MulticamSpan(source: selected.source, stream: selected.stream, input: input, output: output)
                    .appendCoalescing(to: &lane)
            }
            try appendSpan(mapping.picture, to: &picture)
            try appendSpan(mapping.audio, to: &audio)
        }

        for interval in mapping.intervals {
            let from = max(interval.group.from, affected.from)
            let to = min(interval.group.to, affected.to)
            guard sameDecision(interval, previous), from < to else {
                try append(interval.group, in: interval, using: interval)
                continue
            }
            // A retained range can begin or end inside the moved decision,
            // even when the old switch itself never appeared in that range.
            if interval.group.from < from {
                try append(.init(from: interval.group.from, to: from), in: interval, using: interval)
            }
            try append(.init(from: from, to: to), in: interval, using: replacement)
            if to < interval.group.to {
                try append(.init(from: to, to: interval.group.to), in: interval, using: interval)
            }
        }
        return MulticamPlan(intervals: intervals, picture: picture, audio: audio, duration: mapping.duration)
    }

    private func audioGrid(_ span: MulticamSpan, media: MediaInfo, starting: Bool,
                           sourceOffset: RationalTime, seam: RationalTime, groupOrigin: RationalTime,
                           container: String) throws -> MulticamBoundary.Grid {
        guard let index = span.stream, let sound = media.audio.first(where: { $0.stream.index == index }) else {
            throw CutError(code: "missing_audio", message: "The selected soundtrack has no indexed audio clock.")
        }
        let selector = CutEngine(cancelled: cancelled, tracks: .audio, audioStream: index)
        if sound.stream.isPCM || selector.supportsAACEdits(sound.stream, container: container) {
            // Both source and output clocks must land on a sample. Translating the
            // switch cannot fix incompatible phases, so do this check before searching.
            let rate = sound.stream.sampleRate
            let input = starting ? span.input.from : span.input.to
            let phase = try media.origin.adding(input).subtracting(seam)
            guard rate > 0, Int64(rate).isMultiple(of: phase.denominator) else {
                return .init(times: [], offset: groupOrigin)
            }
            let nearest = try seam.roundedToSamples(rate)
            let times = [-1, 0, 1].compactMap { delta -> RationalTime? in
                let (sample, overflow) = nearest.addingReportingOverflow(Int64(delta))
                return overflow ? nil : RationalTime(numerator: sample, denominator: Int64(rate))
            }
            return .init(times: times, offset: groupOrigin)
        }
        let selected = try selector.selectedMedia(media)
        return .init(times: selector.audioPacketBoundaries(selected, starting: starting), offset: sourceOffset)
    }

}
