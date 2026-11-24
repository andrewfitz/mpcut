import Foundation

public struct ParticipantPrivacyIssue: Codable, Equatable, Sendable {
    public let sourceID: String
    public var source: MulticamRange
    public var output: MulticamRange

    private enum CodingKeys: String, CodingKey { case sourceID = "source_id", source, output }

    var unresolvedError: CutError {
        .init(code: "unresolved_participant_privacy",
              message: "Review source ‘\(sourceID)’ from \(source.from) to \(source.to) "
                + "(output \(output.from) to \(output.to)) before publishing.")
    }
}

public struct ParticipantRenderReport: Codable, Sendable {
    public let canvas: ParticipantCanvas
    public let duration: RationalTime
    public let frameCount: Int64
    public let audio: ParticipantRenderAudio
    public let audioActions: [StillSoundAction]
    public let privacyIssues: [ParticipantPrivacyIssue]
    public let publishable: Bool
    public let staleSourceIDs: [String]
    public var unscannedSourceIDs: [String]? = nil
    public let output: String?
    public var audioPrivacyNotice: String? = nil

    private enum CodingKeys: String, CodingKey {
        case canvas, duration, audio, publishable, output
        case audioPrivacyNotice = "audio_privacy_notice"
        case staleSourceIDs = "stale_source_ids"
        case unscannedSourceIDs = "unscanned_source_ids"
        case frameCount = "frame_count", audioActions = "audio_actions", privacyIssues = "privacy_issues"
    }
}

struct ParticipantRenderRoute: Hashable {
    let id: String
    let file: URL
    /// Add this to output time to recover relative source presentation time.
    let displacement: RationalTime
    let usesMulticamClock: Bool
    var feedID: String? = nil
}

struct ParticipantRenderWindow {
    let range: MulticamRange
    let shot: ParticipantShot
    let base: ParticipantRenderRoute?
    let cameras: [String: ParticipantRenderRoute]
    let routes: [ParticipantRenderRoute]

    init(range: MulticamRange, shot: ParticipantShot, base: ParticipantRenderRoute?, cameras: [String: ParticipantRenderRoute]) {
        self.range = range
        self.shot = shot
        self.base = base
        self.cameras = cameras
        var seen: Set<String> = []
        routes = ([base].compactMap { $0 } + cameras.values.sorted { $0.id < $1.id }).filter { seen.insert($0.id).inserted }
    }

    func route(for slot: ParticipantSlot) -> ParticipantRenderRoute? {
        switch slot.target {
        case .camera: cameras[slot.id]
        case .participant, .presentation: base
        case .empty: nil
        }
    }
}

struct ParticipantRenderTimeline {
    let timeline: StillTimelinePlan
    let windows: [ParticipantRenderWindow]

    init(project: CutProject, document: URL, timeline: StillTimelinePlan, plan: ParticipantRenderPlan,
         range: MulticamRange? = nil, checkCancellation: () throws -> Void) throws {
        self.timeline = try range.map { try timeline.participantScoped(to: $0) } ?? timeline
        let clips = Dictionary(uniqueKeysWithValues: (project.sequenceClips ?? []).map { ($0.id, $0) })
        let cameraIDs = Set(plan.shots.flatMap(\.slots).filter { $0.target == .camera }.map(\.id))
        let participantIDs = Set(project.participants.people.map(\.id))
        let presentationIDs = Set(project.participants.sources.flatMap(\.appearances).filter { $0.role == .presentation }.map(\.id))
        for slot in plan.shots.flatMap(\.slots) {
            if slot.target == .participant && !participantIDs.contains(slot.id) {
                throw Self.invalid("Unknown participant ‘\(slot.id)’.")
            }
            if slot.target == .presentation && !presentationIDs.contains(slot.id) {
                throw Self.invalid("Unknown presentation appearance ‘\(slot.id)’.")
            }
        }
        for redaction in plan.redactions where !participantIDs.contains(redaction.participantID) {
            throw Self.invalid("Unknown redacted participant ‘\(redaction.participantID)’.")
        }
        var paths: [String: URL] = [:]
        func path(_ file: String) throws -> URL {
            if let url = paths[file] { return url }
            let url = try CutProject.checkedMediaURL(file, relativeTo: document)
            paths[file] = url
            return url
        }
        let omitted = Set(plan.redactions.filter { $0.treatment == .omit }.map(\.participantID))
        let defaultShot = plan.shots.first { $0.range == nil }!
        let shotIndex = ParticipantTimedShot.index(plan.shots)
        let outputShots = shotIndex[.init(clock: .output)] ?? []
        let groupShots = shotIndex[.init(clock: .group)] ?? []
        // Only participating layers are opened or evaluated for privacy.
        func emit(_ output: MulticamRange, group: MulticamRange?, occurrence: Int,
                  base: () throws -> ParticipantRenderRoute?,
                  camera: (String, RationalTime) throws -> ParticipantRenderRoute?,
                  cameraBoundaries: [RationalTime] = [], into windows: inout [ParticipantRenderWindow]) throws {
            if let range, output.participantIntersection(range) == nil { return }
            var controlPoints = Set([output.from, output.to])
            let occurrenceShots = shotIndex[.init(clock: .output, occurrence: occurrence)] ?? []
            for candidates in [occurrenceShots.overlapping(output), outputShots.overlapping(output)] {
                for shot in candidates {
                    for point in [shot.range.from, shot.range.to] where output.contains(point) { controlPoints.insert(point) }
                }
            }
            if let group {
                let shotBoundaries = groupShots.overlapping(group).flatMap { [$0.range.from, $0.range.to] }
                for point in shotBoundaries + cameraBoundaries where group.contains(point) {
                    controlPoints.insert(try output.from.adding(point.subtracting(group.from)))
                }
            }
            let points = controlPoints.sorted()
            for (from, to) in zip(points, points.dropFirst()) {
                try checkCancellation()
                let window = MulticamRange(from: from, to: to)
                if let range, window.participantIntersection(range) == nil { continue }
                let groupTime = try group.map { try $0.from.adding(from.subtracting(output.from)) }
                let shot = occurrenceShots.shot(at: from)
                    ?? outputShots.shot(at: from)
                    ?? groupTime.flatMap { groupShots.shot(at: $0) }
                    ?? defaultShot
                let slots = shot.slots.filter { $0.target != .participant || !omitted.contains($0.id) }
                let base = shot.layout == .original || shot.layout == .arranged || slots.contains(where: { $0.target == .participant || $0.target == .presentation }) ? try base() : nil
                var cameras: [String: ParticipantRenderRoute] = [:]
                for id in Set(slots.filter { $0.target == .camera }.map(\.id)) {
                    cameras[id] = try camera(id, groupTime ?? from)
                }
                windows.append(.init(range: window, shot: shot, base: base, cameras: cameras))
            }
        }
        var windows: [ParticipantRenderWindow] = []
        switch project {
        case .multicam(let multicam):
            let byID = Dictionary(uniqueKeysWithValues: multicam.pictureSources.map { ($0.id, $0) })
            let byCamera = Dictionary(uniqueKeysWithValues: multicam.angles.map { ($0.id, multicam.recordings(for: $0.id)) })
            guard cameraIDs.isSubset(of: Set(byCamera.keys)) else { throw Self.invalid("A shot references an unknown camera angle.") }
            let coverageBoundaries = Set(cameraIDs.flatMap { id in
                (byCamera[id] ?? []).compactMap(\.coverage).flatMap { [$0.from, $0.to] }
            }).sorted()
            for interval in try multicam.plan().intervals {
                let displacement = try interval.group.from.subtracting(interval.output.from)
                func route(_ recording: MulticamSource) throws -> ParticipantRenderRoute {
                    let physical = recording.feedAngle.flatMap { byID[$0.sourceID] } ?? recording
                    return try .init(id: physical.id, file: path(physical.file),
                                     displacement: displacement.subtracting(physical.offset), usesMulticamClock: true,
                                     feedID: recording.feedAngle?.feedID)
                }
                let first = coverageBoundaries.lowerBound { $0 >= interval.group.from }
                let end = coverageBoundaries.lowerBound { $0 >= interval.group.to }
                let start = timeline.spans.lowerBound { $0.output.to > interval.output.from }
                for span in timeline.spans[start...] {
                    if span.output.from >= interval.output.to { break }
                    guard span.placementID == nil else { continue }
                    let output = MulticamRange(from: max(interval.output.from, span.output.from),
                                               to: min(interval.output.to, span.output.to))
                    let group = try MulticamRange(from: output.from.adding(displacement), to: output.to.adding(displacement))
                    try emit(output, group: group, occurrence: interval.assemblyIndex,
                             base: { try interval.pictureSourceID.flatMap { byID[$0] }.map(route) },
                             camera: { angle, time in
                                 try byCamera[angle]?.first { $0.coverage?.contains(time) ?? true }.map(route)
                             },
                             cameraBoundaries: Array(coverageBoundaries[first..<end]), into: &windows)
                }
            }
        case .sequence, .stillSequence:
            guard groupShots.isEmpty else { throw Self.invalid("Group shots require a multicam project.") }
            guard cameraIDs.isSubset(of: Set(clips.values.map(\.file))) else {
                throw Self.invalid("A sequence shot references an unknown recording path.")
            }
            let occurrences = Dictionary(uniqueKeysWithValues: (project.sequenceItems ?? []).enumerated()
                .compactMap { index, item in item.source.map { ($0.id, index) } })
            for span in timeline.spans {
                guard span.placementID == nil, case .source(let clipID, let range) = span.origin,
                      let clip = clips[clipID], let occurrence = occurrences[clipID] else { continue }
                func route() throws -> ParticipantRenderRoute {
                    try .init(id: clip.file, file: path(clip.file), displacement: range.from.subtracting(span.output.from), usesMulticamClock: false)
                }
                try emit(span.output, group: nil, occurrence: occurrence, base: route,
                         camera: { id, _ in id == clip.file ? try route() : nil }, into: &windows)
            }
        }
        if let range {
            let offset = try RationalTime.zero.subtracting(range.from)
            func shifted(_ route: ParticipantRenderRoute) throws -> ParticipantRenderRoute {
                try .init(id: route.id, file: route.file, displacement: route.displacement.adding(range.from),
                          usesMulticamClock: route.usesMulticamClock, feedID: route.feedID)
            }
            self.windows = try windows.compactMap { window in
                guard let overlap = window.range.participantIntersection(range) else { return nil }
                return try .init(range: overlap.participantShifted(by: offset), shot: window.shot,
                                 base: window.base.map(shifted), cameras: window.cameras.mapValues(shifted))
            }
        } else {
            self.windows = windows
        }
    }

    func window(at time: RationalTime) -> ParticipantRenderWindow? {
        let index = windows.lowerBound { $0.range.to > time }
        guard windows.indices.contains(index), windows[index].range.contains(time) else { return nil }
        return windows[index]
    }

    private static func invalid(_ message: String) -> CutError { .init(code: "invalid_participant_plan", message: message) }
}
