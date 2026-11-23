import Foundation

extension MulticamSync {
    public struct ReplacementCoverage: Encodable, Sendable {
        public let overlap: [MulticamRange]
        public let uncovered: [MulticamRange]
        /// Stream extent on the original recording's presentation clock.
        public let incoming: MulticamRange
    }

    /// Scratch-local portions required by the current cut. An inactive scratch
    /// stream falls back to the recording's coverage within the cut.
    public static func usedReferenceRanges(project: MulticamProject, reference: MulticamAudioSelection,
                                           program: Bool = false) throws -> [MulticamRange] {
        try usedReferenceRanges(project: project, referenceSourceID: reference.source, referenceStream: reference.stream,
                                program: program)
    }

    package static func usedReferenceRanges(project: MulticamProject, referenceSourceID: String,
                                            referenceStream: Int?, program: Bool) throws -> [MulticamRange] {
        guard let source = project.pictureSources.first(where: { $0.id == referenceSourceID }) else {
            throw CutError(code: "invalid_sync_reference", message: "Choose a camera recording.")
        }
        let plan = try project.plan()
        let routed = plan.audioLanes.flatMap(\.spans)
            .filter { $0.source == referenceSourceID && $0.stream == referenceStream }
            .map(\.input)
        let ranges: [MulticamRange]
        if !program, !routed.isEmpty {
            ranges = routed
        } else {
            let extent = source.coverage ?? project.range
            ranges = try plan.intervals.compactMap { interval in
                let start = program ? interval.group.from : max(interval.group.from, extent.from)
                let end = program ? interval.group.to : min(interval.group.to, extent.to)
                guard start < end else { return nil }
                return try .init(from: start.subtracting(source.offset), to: end.subtracting(source.offset))
            }
        }
        return ranges.sorted { $0.from < $1.from }.reduce(into: []) { result, next in
            if let last = result.indices.last, next.from <= result[last].to {
                result[last].to = max(result[last].to, next.to)
            } else {
                result.append(next)
            }
        }
    }

    public static func replacementCoverage(in used: [MulticamRange], track: AudioIndex,
                                           relativeOffset: RationalTime) throws -> ReplacementCoverage {
        let incoming = try MulticamRange(from: track.start.adding(relativeOffset), to: track.end.adding(relativeOffset))
        var overlap: [MulticamRange] = []
        var uncovered: [MulticamRange] = []
        for range in used where range.from < range.to {
            let mapped = try MulticamSpan(source: "", stream: track.stream.index,
                                          input: .init(from: range.from.subtracting(relativeOffset),
                                                       to: range.to.subtracting(relativeOffset)),
                                          output: range)
            let sound = try MulticamPlan.audibleParts(of: mapped, track: track)
            overlap.append(contentsOf: sound.map(\.output))
            uncovered.append(contentsOf: MulticamPlan.uncovered(in: range, sound: sound))
        }
        return .init(overlap: overlap, uncovered: uncovered, incoming: incoming)
    }

    package static func confirmedProgramOffset(project: MulticamProject, referenceSourceID: String,
                                               track: AudioIndex, relativeOffset: RationalTime) throws -> RationalTime {
        guard let reference = project.pictureSources.first(where: { $0.id == referenceSourceID }) else {
            throw CutError(code: "invalid_sync_reference", message: "Choose a camera recording as the program audio reference.")
        }
        let used = try usedReferenceRanges(project: project, referenceSourceID: referenceSourceID,
                                           referenceStream: nil, program: true)
        let coverage = try replacementCoverage(in: used, track: track, relativeOffset: relativeOffset)
        if let missing = coverage.uncovered.first {
            throw CutError(code: "uncovered_audio",
                           message: "The program replacement leaves \(missing.from)–\(missing.to) uncovered on the reference recording clock.",
                           track: track.stream.index, laneID: MulticamPlan.programAudioLaneID)
        }
        return try reference.offset.adding(relativeOffset)
    }
}
