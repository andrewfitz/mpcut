import Foundation

public struct ParticipantPrivacyIssue: Codable, Equatable, Sendable {
    public let sourceID: String
    public var source: MulticamRange
    public var output: MulticamRange

    private enum CodingKeys: String, CodingKey { case sourceID = "source_id", source, output }
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
    public let output: String?

    private enum CodingKeys: String, CodingKey {
        case canvas, duration, audio, publishable, output
        case staleSourceIDs = "stale_source_ids"
        case frameCount = "frame_count", audioActions = "audio_actions", privacyIssues = "privacy_issues"
    }
}

struct ParticipantRenderRoute {
    let id: String
    let file: URL
    /// Add this to output time to recover relative source presentation time.
    let displacement: RationalTime
    let usesMulticamClock: Bool
}

struct ParticipantRenderWindow {
    let range: MulticamRange
    let shot: ParticipantShot
    let base: ParticipantRenderRoute?
    let cameras: [String: ParticipantRenderRoute]

    func route(for slot: ParticipantSlot) -> ParticipantRenderRoute? {
        slot.target == .camera ? cameras[slot.id] : base
    }
}

struct ParticipantRenderTimeline {
    let timeline: StillTimelinePlan
    let windows: [ParticipantRenderWindow]

    init(project: CutProject, document: URL, timeline: StillTimelinePlan, plan: ParticipantRenderPlan,
         checkCancellation: () throws -> Void) throws {
        self.timeline = timeline
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
                let groupTime = try group.map { try $0.from.adding(from.subtracting(output.from)) }
                let shot = occurrenceShots.shot(at: from)
                    ?? outputShots.shot(at: from)
                    ?? groupTime.flatMap { groupShots.shot(at: $0) }
                    ?? defaultShot
                let slots = shot.slots.filter { $0.target != .participant || !omitted.contains($0.id) }
                let base = shot.layout == .original || slots.contains(where: { $0.target != .camera }) ? try base() : nil
                var cameras: [String: ParticipantRenderRoute] = [:]
                for id in Set(slots.filter { $0.target == .camera }.map(\.id)) {
                    cameras[id] = try camera(id, groupTime ?? from)
                }
                windows.append(.init(range: .init(from: from, to: to), shot: shot, base: base, cameras: cameras))
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
                    try .init(id: recording.id, file: path(recording.file), displacement: displacement.subtracting(recording.offset), usesMulticamClock: true)
                }
                let first = coverageBoundaries.lowerBound { $0 >= interval.group.from }
                let end = coverageBoundaries.lowerBound { $0 >= interval.group.to }
                try emit(interval.output, group: interval.group, occurrence: interval.assemblyIndex,
                         base: { try interval.pictureSourceID.flatMap { byID[$0] }.map(route) },
                         camera: { angle, time in
                             try byCamera[angle]?.first { $0.coverage?.contains(time) ?? true }.map(route)
                         },
                         cameraBoundaries: Array(coverageBoundaries[first..<end]), into: &windows)
            }
        case .sequence, .stillSequence:
            guard groupShots.isEmpty else { throw Self.invalid("Group shots require a multicam project.") }
            guard cameraIDs.isSubset(of: Set(clips.values.map(\.file))) else {
                throw Self.invalid("A sequence shot references an unknown recording path.")
            }
            for (occurrence, span) in timeline.spans.enumerated() {
                guard case .source(let clipID, let range) = span.origin, let clip = clips[clipID] else {
                    throw Self.invalid("Participant composition requires source clips.")
                }
                func route() throws -> ParticipantRenderRoute {
                    try .init(id: clip.file, file: path(clip.file), displacement: range.from.subtracting(span.output.from), usesMulticamClock: false)
                }
                try emit(span.output, group: nil, occurrence: occurrence, base: route,
                         camera: { id, _ in id == clip.file ? try route() : nil }, into: &windows)
            }
        }
        self.windows = windows
    }

    func window(at time: RationalTime) -> ParticipantRenderWindow? {
        let index = windows.lowerBound { $0.range.to > time }
        guard windows.indices.contains(index), windows[index].range.contains(time) else { return nil }
        return windows[index]
    }

    private static func invalid(_ message: String) -> CutError { .init(code: "invalid_participant_plan", message: message) }
}
