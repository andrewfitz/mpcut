import Foundation

public struct ParticipantDialogueLine: Sendable {
    public let speaker: ParticipantSpeakerBinding
    public let range: MulticamRange
    public let utteranceID: String?

    public init(speaker: ParticipantSpeakerBinding, range: MulticamRange, utteranceID: String? = nil) {
        self.speaker = speaker
        self.range = range
        self.utteranceID = utteranceID
    }
}

public struct ParticipantDialogueOptions: Equatable, Sendable {
    public enum Overlap: String, CaseIterable, Sendable { case hold, visibleSpeaker }
    public enum Offscreen: String, CaseIterable, Sendable { case hold, original, reaction }

    public var minimumHold: RationalTime
    public var overlap: Overlap
    public var offscreen: Offscreen

    public init(minimumHold: RationalTime = .init(numerator: 1), overlap: Overlap = .hold, offscreen: Offscreen = .hold) {
        self.minimumHold = minimumHold
        self.overlap = overlap
        self.offscreen = offscreen
    }
}

public struct ParticipantDialogueProposal: Equatable, Identifiable, Sendable {
    public enum Reason: String, Sendable { case speaker, overlap, offscreen, reaction }

    public let angle: ParticipantVirtualAngle
    public let at: RationalTime
    public let occurrence: Int
    public let reason: Reason
    public var id: String { "\(occurrence):\(at):\(angle.id)" }
}

public enum ParticipantDialogue {
    /// Project only timing and attachment-scoped speaker identity into the suggestion engine.
    public static func lines(from index: TranscriptIndex) -> [ParticipantDialogueLine] {
        index.readAll(space: .currentCut).compactMap { occurrence in
            guard let attachment = occurrence.attachmentID ?? index.attachment?.id,
                  let speaker = occurrence.speakerID ?? occurrence.originalSpeakerID else { return nil }
            return .init(speaker: .init(attachmentID: attachment, speakerID: speaker),
                         range: occurrence.range, utteranceID: occurrence.utteranceID)
        }
    }

    /// Analyze the selected virtual angles on the edited output clock without modifying the project.
    public static func suggest(_ lines: [ParticipantDialogueLine], angles: [ParticipantVirtualAngle],
                               in project: CutProject, document: URL, options: ParticipantDialogueOptions = .init(),
                               cancelled: (@Sendable () -> Bool)? = nil) throws -> [ParticipantDialogueProposal] {
        try project.validate()
        guard let first = angles.first, first.range.from >= .zero, (first.range.from < first.range.to),
              options.minimumHold > .zero, angles.allSatisfy({ $0.sourceID == first.sourceID && $0.range == first.range }),
              project.stillInserts.isEmpty, project.stillReplacements.isEmpty else {
            throw CutError(code: "invalid_participant_dialogue",
                           message: "Choose angles from one recording, source-picture occurrences, and a positive minimum hold.")
        }
        let roster = Set(project.participants.people.map(\.id))
        let masks = Set(project.participants.render?.redactions.filter { $0.treatment == .omit }.map(\.participantID) ?? [])
        var choices: [ParticipantVirtualAngle] = []
        var ids = Set<String>()
        for angle in angles where angle.kind == .participant {
            let id = angle.targetID ?? angle.id
            guard roster.contains(id) else {
                throw CutError(code: "invalid_participant_dialogue", message: "An angle refers to an unavailable participant.")
            }
            if !masks.contains(id), ids.insert(id).inserted { choices.append(angle) }
        }
        guard !choices.isEmpty else { return [] }
        let mapped = Dictionary(uniqueKeysWithValues: project.participants.people.flatMap { person in
            person.speakers.map { ($0, person.id) }
        })
        let engine = CutEngine(cancelled: cancelled)
        let turns = try makeTurns(lines, mapped: mapped, checkCancellation: engine.checkCancellation)
        guard !turns.isEmpty else { return [] }
        let geometry = try ParticipantGeometryIndex(project.participants, sourceID: first.sourceID, slots: ids,
                                                    checkCancellation: engine.checkCancellation)
        let appearances = project.participants.sources.first { $0.sourceID == first.sourceID }?
            .appearances.flatMap { [$0.range.from, $0.range.to] } ?? []
        let pinned = project.participants.appearanceOverrides.filter { $0.sourceID == first.sourceID }
            .flatMap { [$0.range.from, $0.range.to] }
        let points = Set(appearances + pinned).sorted()
        var originalID = "original"
        while angles.contains(where: { $0.id == originalID }) { originalID += "-" }
        let original = masks.isEmpty ? (angles.first { $0.kind == .original } ?? .init(
            id: originalID, name: "Original Gallery", sourceID: first.sourceID, range: first.range, kind: .original)) : nil
        let windows = try occurrences(project, document: document, angle: first, engine: engine)
        var proposals: [ParticipantDialogueProposal] = []
        var end = RationalTime.zero
        let maxima = turns.map {
            end = max(end, $0.range.to)
            return end
        }
        for window in windows {
            try engine.checkCancellation()
            let firstTurn = maxima.lowerBound { $0 > window.output.from }
            let lastTurn = turns.lowerBound { $0.range.from >= window.output.to }
            guard firstTurn < lastTurn else { continue }
            let runs = try candidates(turns[firstTurn..<lastTurn], window: window, geometry: geometry, points: points,
                                      choices: choices, original: original, options: options, checkCancellation: engine.checkCancellation)
            var previous: ParticipantDialogueProposal?
            for run in runs {
                guard try run.to.subtracting(run.proposal.at) >= options.minimumHold,
                      previous.map({ $0.angle.id != run.proposal.angle.id }) ?? true else { continue }
                if let previous, try run.proposal.at.subtracting(previous.at) < options.minimumHold { continue }
                proposals.append(run.proposal)
                previous = run.proposal
            }
        }
        return proposals
    }

    public static func accepting(_ proposal: ParticipantDialogueProposal, in project: CutProject,
                                 document: URL) throws -> CutProject {
        try ParticipantMulticam.taking(proposal.angle, at: proposal.at, in: project, document: document,
                                      expectedOccurrence: proposal.occurrence)
    }

    private struct Turn {
        var participant: String
        var range: MulticamRange
    }

    private struct TurnKey: Hashable {
        let speaker: ParticipantSpeakerBinding
        let utteranceID: String?
    }

    private static func makeTurns(_ lines: [ParticipantDialogueLine], mapped: [ParticipantSpeakerBinding: String],
                                  checkCancellation: () throws -> Void) throws -> [Turn] {
        let byTurn = Dictionary(grouping: lines.filter { mapped[$0.speaker] != nil && $0.range.from < $0.range.to }) {
            TurnKey(speaker: $0.speaker, utteranceID: $0.utteranceID)
        }
        let gap = RationalTime(numerator: 1, denominator: 4)
        var turns: [Turn] = []
        for (key, words) in byTurn {
            try checkCancellation()
            guard let participant = mapped[key.speaker] else { continue }
            var active: MulticamRange?
            for word in words.sorted(by: { $0.range.from < $1.range.from }) {
                if var current = active, word.range.from <= (try current.to.adding(gap)) {
                    current.to = max(current.to, word.range.to)
                    active = current
                } else {
                    if let active { turns.append(.init(participant: participant, range: active)) }
                    active = word.range
                }
            }
            if let active { turns.append(.init(participant: participant, range: active)) }
        }
        return turns.sorted {
            if $0.range.from != $1.range.from { return $0.range.from < $1.range.from }
            if $0.range.to != $1.range.to { return $0.range.to < $1.range.to }
            return $0.participant < $1.participant
        }
    }

    private struct Window {
        let index: Int
        var output: MulticamRange
        let displacement: RationalTime
    }

    private static func occurrences(_ project: CutProject, document: URL, angle: ParticipantVirtualAngle,
                                    engine: CutEngine) throws -> [Window] {
        var result: [Window] = []
        func append(index: Int, output: MulticamRange, displacement: RationalTime) throws {
            let from = max(output.from, try angle.range.from.subtracting(displacement))
            let to = min(output.to, try angle.range.to.subtracting(displacement))
            guard from < to else { return }
            if let last = result.indices.last, result[last].index == index,
               result[last].displacement == displacement, result[last].output.to == from {
                result[last].output.to = to
            } else {
                result.append(.init(index: index, output: .init(from: from, to: to), displacement: displacement))
            }
        }
        switch project {
        case .multicam(let multicam):
            guard let recording = multicam.pictureSources.first(where: { $0.id == angle.sourceID }) else { return [] }
            let file = try CutProject.checkedMediaURL(recording.file, relativeTo: document)
            let offset = try recording.offset.adding(engine.inspectSummary(file).multicamSourceOffset)
            for interval in try multicam.plan().intervals where interval.pictureSourceID == angle.sourceID {
                try engine.checkCancellation()
                let displacement = try interval.group.from.subtracting(interval.output.from).subtracting(offset)
                try append(index: interval.assemblyIndex, output: interval.output, displacement: displacement)
            }
        case .sequence, .stillSequence:
            let clips = Dictionary(uniqueKeysWithValues: (project.sequenceClips ?? []).map { ($0.id, $0.file) })
            for (index, span) in try project.resolveStillsUnchecked().spans.enumerated() {
                try engine.checkCancellation()
                guard case .source(let clip, let range) = span.origin, clips[clip] == angle.sourceID else { continue }
                try append(index: index, output: span.output, displacement: range.from.subtracting(span.output.from))
            }
        }
        return result
    }

    private struct Run {
        let proposal: ParticipantDialogueProposal
        var to: RationalTime
    }

    private static func candidates(_ turns: ArraySlice<Turn>, window: Window, geometry: ParticipantGeometryIndex,
                                   points sourcePoints: [RationalTime], choices: [ParticipantVirtualAngle],
                                   original: ParticipantVirtualAngle?, options: ParticipantDialogueOptions,
                                   checkCancellation: () throws -> Void) throws -> [Run] {
        var events: [RationalTime: [(String, Int)]] = [:]
        for turn in turns {
            let start = max(window.output.from, turn.range.from)
            let end = min(window.output.to, turn.range.to)
            guard start < end else { continue }
            events[start, default: []].append((turn.participant, 1))
            events[end, default: []].append((turn.participant, -1))
        }
        let sourceStart = try window.output.from.adding(window.displacement)
        let sourceEnd = try window.output.to.adding(window.displacement)
        let firstPoint = sourcePoints.lowerBound { $0 > sourceStart }
        let lastPoint = sourcePoints.lowerBound { $0 >= sourceEnd }
        var points = Set(events.keys)
        points.insert(window.output.to)
        for point in sourcePoints[firstPoint..<lastPoint] { points.insert(try point.subtracting(window.displacement)) }
        let ordered = points.sorted()
        var active: [String: Int] = [:]
        var runs: [Run] = []
        for (at, end) in zip(ordered, ordered.dropFirst()) {
            try checkCancellation()
            for (participant, change) in events[at] ?? [] {
                let count = active[participant, default: 0] + change
                active[participant] = count == 0 ? nil : count
            }
            guard !active.isEmpty, options.overlap != .hold || active.count == 1 else { continue }
            let sourceTime = try at.adding(window.displacement)
            let visible = choices.filter { angle in
                guard let slot = angle.slot() else { return false }
                var videoOnly = slot
                videoOnly.includeCameraOff = false
                return geometry.appearance(videoOnly, at: sourceTime) != nil
            }
            let speaking = visible.filter { active[$0.targetID ?? $0.id] != nil }
            let choice: ParticipantVirtualAngle?
            let reason: ParticipantDialogueProposal.Reason
            if !speaking.isEmpty {
                choice = speaking.first { $0.id == runs.last?.proposal.angle.id } ?? speaking.first
                reason = active.count > 1 ? .overlap : .speaker
            } else {
                switch options.offscreen {
                case .hold: choice = nil; reason = .offscreen
                case .original: choice = original; reason = .offscreen
                case .reaction: choice = visible.first; reason = .reaction
                }
            }
            guard let choice else { continue }
            if let last = runs.indices.last, runs[last].proposal.angle.id == choice.id, runs[last].to == at {
                runs[last].to = end
            } else {
                runs.append(.init(proposal: .init(angle: choice, at: at, occurrence: window.index, reason: reason), to: end))
            }
        }
        return runs
    }
}
