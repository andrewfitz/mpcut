import Foundation

public struct MulticamSwitchCoverage: Encodable, Sendable {
    public enum Status: String, Encodable, Sendable {
        case covered, gaps, unavailable, unrouted
    }

    public struct Lane: Encodable, Sendable {
        public let status: Status
        public let missing: [MulticamRange]
    }

    public struct Route: Encodable, Sendable {
        public let group: MulticamRange
        public let audio: MulticamAudioSelection
        public var laneID: String? = nil

        private enum CodingKeys: String, CodingKey { case group, audio, laneID = "lane_id" }
    }

    public struct AudioLane: Encodable, Sendable {
        public let id: String
        public let label: String
        public let coverage: Lane
    }

    public let group: MulticamRange
    public let angleID: String
    public let audioRoute: MulticamAudioSelection?
    public let audioRoutes: [Route]
    public let picture: Lane
    public let audio: Lane
    public var audioLanes: [AudioLane]? = nil

    private enum CodingKeys: String, CodingKey {
        case group, angleID = "angle_id", audioRoute = "audio_route", audioRoutes = "audio_routes", picture, audio
        case audioLanes = "audio_lanes"
    }
}

extension MulticamProject {
    package func proposedSwitch(at time: RationalTime, angle: String) throws
        -> (marker: MulticamSwitch, group: MulticamRange, plan: MulticamPlan) {
        var proposed = self
        var marker = MulticamSwitch(at: time, angle: angle)
        if let existing = proposed.switches.firstIndex(where: { $0.at == time }) {
            marker.audio = proposed.switches[existing].audio
            proposed.switches[existing] = marker
        } else {
            let index = proposed.switches.lowerBound { $0.at > time }
            proposed.switches.insert(marker, at: index)
        }
        let group = MulticamRange(from: time, to: switches.first { $0.at > time }?.at ?? range.to)
        return (marker, group, try proposed.plan(ranges: [group]))
    }

    package func switchCoverage(at time: RationalTime, angle: String,
                                media: [String: MediaInfo],
                                isAvailable: (MulticamSpan) -> Bool = { _ in true }) throws -> MulticamSwitchCoverage {
        let proposal = try proposedSwitch(at: time, angle: angle)
        let routes: [MulticamSwitchCoverage.Route] = proposal.plan.intervals.compactMap { interval in
            interval.audio.map { .init(group: interval.group, audio: $0) }
        }
        let feed = angles.first { $0.id == angle }?.feedAngle
        let feedGeometry = try feed.map {
            try ParticipantGeometryIndex(participants, sourceID: $0.sourceID, slots: [$0.feedID], checkCancellation: {})
        }
        let feedOmitted = feed.map { feed in
            participants.effectiveRedactions.contains { $0.participantID == feed.feedID && $0.treatment == .omit }
        } ?? false
        let audioExpected = audio != .none || !routes.isEmpty
        var current: [String: Bool] = [:]
        func verified(_ id: String, _ info: MediaInfo) -> Bool {
            guard info.hasFullEditIndex else { return false }
            if let known = current[id] { return known }
            let isCurrent = info.identity.isCurrentSnapshot(at: info.url)
            current[id] = isCurrent
            return isCurrent
        }
        func lane(_ spans: [MulticamSpan], picture: Bool) throws -> MulticamSwitchCoverage.Lane {
            if !picture, !audioExpected { return .init(status: .unrouted, missing: []) }
            var covered: [AudioSpan] = []
            var unverified = false
            for span in spans {
                guard let info = media[span.source] ?? (picture ? feed.flatMap { media[$0.sourceID] } : nil),
                      isAvailable(span), verified(span.source, info) else {
                    unverified = true
                    continue
                }
                let start = try time.adding(span.output.from)
                let offset = try start.subtracting(span.input.from)
                func append(_ from: RationalTime, _ to: RationalTime) throws {
                    let lower = max(.zero, span.input.from, from), upper = min(span.input.to, to)
                    guard lower < upper else { return }
                    let part = try AudioSpan(from: lower.adding(offset), to: upper.adding(offset))
                    if let previous = covered.last, previous.from <= part.from, part.from <= previous.to {
                        covered[covered.count - 1] = .init(from: previous.from, to: max(previous.to, part.to))
                    } else {
                        covered.append(part)
                    }
                }
                if picture {
                    if feedOmitted { continue }
                    if let feed, participants.needsReconciliation(sourceID: feed.sourceID, identity: info.identity) {
                        unverified = true
                        continue
                    }
                    let frames = info.frames
                    let start = max(0, frames.lowerBound { $0.time >= span.input.from } - 1)
                    for frame in frames[start...] {
                        if frame.time >= span.input.to { break }
                        if let feed, let feedGeometry {
                            let sourceTime = try frame.time.subtracting(info.multicamClockOffset)
                            guard feedGeometry.appearance(.init(id: feed.feedID), at: sourceTime) != nil else { continue }
                        }
                        try append(frame.time, min(info.duration, frame.time.adding(frame.duration)))
                    }
                } else {
                    guard let stream = span.stream, let audio = info.audio.first(where: { $0.stream.index == stream }),
                          info.audioIssues[stream] == nil, audio.stream.sampleRate > 0,
                          audio.stream.isPCM || !audio.packets.isEmpty || !audio.presentationEdits.isEmpty else {
                        unverified = true
                        continue
                    }
                    if audio.stream.isPCM {
                        for part in AudioAnalysis.retained(in: .init(from: audio.start, to: audio.end),
                                                          removing: audio.pcmGaps.map(MulticamSilencePlanner.span)) {
                            try append(part.from, part.to)
                        }
                    } else if !audio.presentationEdits.isEmpty {
                        for edit in audio.presentationEdits where edit.isAudible {
                            let rate = Int64(audio.stream.sampleRate)
                            guard rate > 0 else { break }
                            try append(RationalTime(numerator: edit.samples.lowerBound, denominator: rate).subtracting(info.origin),
                                       RationalTime(numerator: edit.samples.upperBound, denominator: rate).subtracting(info.origin))
                        }
                    } else {
                        let packets = audio.packets
                        let start = max(0, packets.lowerBound { $0.time >= span.input.from } - 1)
                        for packet in packets[start...] {
                            if packet.time >= span.input.to { break }
                            try append(max(audio.start, packet.time), min(audio.end, packet.time.adding(packet.duration)))
                        }
                    }
                }
            }
            let missing = AudioAnalysis.retained(in: MulticamSilencePlanner.span(proposal.group), removing: covered.sorted { $0.from < $1.from })
                .map(MulticamSilencePlanner.range)
            return .init(status: missing.isEmpty ? .covered : (unverified ? .unavailable : .gaps), missing: missing)
        }
        let picture = try lane(proposal.plan.picture, picture: true)
        if audio != .mix, audioReplacements.isEmpty {
            return try .init(group: proposal.group, angleID: angle, audioRoute: routes.first?.audio, audioRoutes: routes,
                             picture: picture, audio: lane(proposal.plan.audio, picture: false))
        }
        var audioRoutes: [MulticamSwitchCoverage.Route] = []
        var reports: [MulticamSwitchCoverage.AudioLane] = []
        // Clipping before verifying the clock can erase an offline route and
        // make its unverified window appear to be a known gap.
        let routedSources = requiredAudioSelections(for: proposal.plan).map(\.source)
        var verifiedMedia: [String: MediaInfo] = [:]
        for id in Set(routedSources) {
            if let info = media[id], verified(id, info) { verifiedMedia[id] = info }
        }
        for sound in try resolveAudioLanes(plan: proposal.plan, indexedSources: verifiedMedia, unavailableAsGap: true) {
            let unavailable = sound.unavailableSpans ?? []
            var coverage = try lane(sound.spans, picture: false)
            if !unavailable.isEmpty { coverage = .init(status: .unavailable, missing: coverage.missing) }
            reports.append(.init(id: sound.id, label: sound.label, coverage: coverage))
            let routed = (sound.spans + unavailable).sorted { $0.output.from < $1.output.from }
            audioRoutes += try routed.compactMap { span in
                guard let stream = span.stream else { return nil }
                let group = try MulticamRange(from: time.adding(span.output.from), to: time.adding(span.output.to))
                return .init(group: group, audio: .init(source: span.source, stream: stream), laneID: sound.id)
            }
        }
        let shortages = reports.flatMap(\.coverage.missing).sorted { $0.from < $1.from }
        var missing: [MulticamRange] = []
        for range in shortages {
            if let index = missing.indices.last, missing[index].to >= range.from {
                missing[index].to = max(missing[index].to, range.to)
            } else {
                missing.append(range)
            }
        }
        let status: MulticamSwitchCoverage.Status
        if reports.contains(where: { $0.coverage.status == .unavailable }) { status = .unavailable }
        else if !missing.isEmpty { status = .gaps }
        else { status = audioExpected ? .covered : .unrouted }
        return .init(group: proposal.group, angleID: angle, audioRoute: reports.count == 1 ? audioRoutes.first?.audio : nil,
                     audioRoutes: audioRoutes, picture: picture, audio: .init(status: status, missing: missing),
                     audioLanes: reports)
    }
}
