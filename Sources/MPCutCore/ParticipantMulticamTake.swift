import Foundation

extension ParticipantMulticam {
    /// Add an output-clock cut from the playhead to the next take, recording boundary or selected angle's end.
    /// The edit affects the current occurrence and leaves group-clock layouts and other occurrences intact.
    public static func taking(_ angle: ParticipantVirtualAngle, at time: RationalTime, in project: CutProject,
                              document: URL, expectedOccurrence: Int? = nil) throws -> CutProject {
        try project.validate()
        guard angle.range.from >= .zero, angle.range.from < angle.range.to,
              project.stillInserts.isEmpty, project.stillReplacements.isEmpty else {
            throw takeError("Choose an angle with a valid source range on a source-picture occurrence.")
        }
        switch angle.kind {
        case .participant:
            guard project.participants.people.contains(where: { $0.id == (angle.targetID ?? angle.id) }) else {
                throw takeError("The virtual angle refers to an unavailable participant.")
            }
        case .presentation:
            guard project.participants.sources.first(where: { $0.sourceID == angle.sourceID })?.appearances.contains(where: {
                $0.role == .presentation && $0.id == (angle.targetID ?? angle.id)
            }) == true else {
                throw takeError("The virtual angle refers to an unavailable presentation.")
            }
        case .original:
            break
        }
        let occurrence = try takeOccurrence(at: time, in: project, sourceID: angle.sourceID, document: document)
        if let expectedOccurrence, expectedOccurrence != occurrence.index {
            throw takeError("The output occurrence changed. Review the suggestion again.")
        }
        guard angle.range.contains(occurrence.sourceTime) else {
            throw takeError("The playhead must be within the virtual angle’s source range.")
        }
        var plan = project.participants.render ?? .init(shots: [.init(layout: .original)], audio: .init(mode: .program))
        let timing = try project.tileRenderPlan() ?? plan
        let native = project.participants.tileOutput != nil || (project.participants.render == nil && project.requiresPictureProcessing)
        var end = min(occurrence.end, try time.adding(angle.range.to.subtracting(occurrence.sourceTime)))
        for shot in timing.shots where shot.clock == .output
            && (shot.occurrence == occurrence.index || (native && shot.occurrence == nil && occurrence.clipID != nil)) {
            if let range = shot.range, time < range.from { end = min(end, range.from) }
        }
        guard time < end else { throw takeError("The take does not contain any output time.") }
        let slot = angle.slot()
        let take = ParticipantShot(range: .init(from: time, to: end), occurrence: occurrence.index,
                                   layout: slot == nil ? .original : .solo, slots: slot.map { [$0] } ?? [])
        var shots: [ParticipantShot] = []
        for shot in plan.shots {
            guard shot.clock == .output, shot.occurrence == occurrence.index, let range = shot.range,
                  range.from < end, time < range.to else {
                shots.append(shot)
                continue
            }
            var retained = shot
            if range.from < time {
                retained.range = .init(from: range.from, to: time)
                shots.append(retained)
            }
            if end < range.to {
                retained.range = .init(from: end, to: range.to)
                shots.append(retained)
            }
        }
        shots.append(take)
        plan.shots = shots
        var updated = project
        if native {
            let scope: TileLayoutScope
            if let clipID = occurrence.clipID {
                scope = .clip(clipID)
            } else if case .multicam(let multicam) = project, let id = multicam.tileOccurrenceID(at: occurrence.index) {
                scope = .occurrence(id)
            } else {
                throw takeError("The take does not refer to an available assembly occurrence.")
            }
            let range = try MulticamRange(from: occurrence.clockTime, to: occurrence.clockTime.adding(end.subtracting(time)))
            updated = try project.settingTileLayout(scope: scope, range: range,
                layout: .init(range: range, layout: take.layout, slots: take.slots))
            if project.participants.render != nil {
                updated.participants.render = plan
            }
        } else {
            updated.participants.render = plan
        }
        try updated.validate()
        return updated
    }

    private static func takeOccurrence(at time: RationalTime, in project: CutProject, sourceID: String, document: URL) throws
        -> (index: Int, clipID: String?, clockTime: RationalTime, sourceTime: RationalTime, end: RationalTime) {
        switch project {
        case .multicam(let multicam):
            let intervals = try multicam.plan().intervals
            let index = intervals.lowerBound { $0.output.to > time }
            guard intervals.indices.contains(index), intervals[index].output.contains(time),
                  intervals[index].pictureSourceID == sourceID,
                  let source = multicam.pictureSources.first(where: { $0.id == sourceID }) else {
                throw takeError("Park the playhead on the virtual angle’s recording.")
            }
            let interval = intervals[index]
            let url = try CutProject.checkedMediaURL(source.file, relativeTo: document)
            let media = try CutEngine().inspectSummary(url)
            let groupTime = try interval.group.from.adding(time.subtracting(interval.output.from))
            let sourceTime = try groupTime.subtracting(source.offset).subtracting(media.multicamSourceOffset)
            var end = interval.output.to
            for next in intervals.dropFirst(index + 1) {
                guard next.assemblyIndex == interval.assemblyIndex, next.pictureSourceID == sourceID,
                      next.output.from == end else { break }
                end = next.output.to
            }
            return (interval.assemblyIndex, nil, groupTime, sourceTime, end)
        case .sequence, .stillSequence:
            let spans = try project.resolveStillsUnchecked().spans
            let index = spans.lowerBound { $0.output.to > time }
            guard spans.indices.contains(index), spans[index].output.contains(time),
                  case .source(let clip, let range) = spans[index].origin,
                  project.sequenceClips?.first(where: { $0.id == clip })?.file == sourceID else {
                throw takeError("Park the playhead on the virtual angle’s recording.")
            }
            let sourceTime = try range.from.adding(time.subtracting(spans[index].output.from))
            return (index, clip, sourceTime, sourceTime, spans[index].output.to)
        }
    }

    private static func takeError(_ message: String) -> CutError {
        .init(code: "invalid_participant_take", message: message)
    }
}
