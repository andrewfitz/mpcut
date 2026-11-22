import Foundation

public struct StillBoundaryAdjustment: Codable, Equatable, Sendable {
    public enum Boundary: String, Codable, Sendable { case start, end, insertion }
    public let placementID: String
    public let boundary: Boundary
    public let clock: String
    public let occurrenceID: String?
    public let requestedTime: RationalTime
    public let adjustedTime: RationalTime
    public let durationChange: RationalTime
}

struct StillUnsafeJoin: Error {
    let issue: CutError
    let proposals: [StillBoundaryAdjustment]
}

extension CutProject {
    /// Applies a placement boundary adjustment that the export planner returned for this revision.
    public func applyingStillBoundary(_ adjustment: StillBoundaryAdjustment) throws -> CutProject {
        let id = adjustment.placementID
        let stale = CutError(code: "invalid_still_boundary", message: "The reviewed boundary of still placement \(id) no longer matches the project.")
        if adjustment.boundary == .insertion {
            guard let span = try resolveStills().spans.first(where: {
                $0.placementID == id && $0.output.from == adjustment.requestedTime && $0.origin == .insert
            }) else { throw stale }
            let destination = adjustment.adjustedTime <= adjustment.requestedTime ? adjustment.adjustedTime :
                try adjustment.adjustedTime.adding(span.output.to.subtracting(span.output.from))
            return try movingStill(id: id, to: destination)
        }
        guard var replacement = stillReplacements.first(where: { $0.id == id }) else { throw stale }
        func change(_ old: MulticamRange) throws -> MulticamRange {
            if adjustment.boundary == .start, old.from == adjustment.requestedTime {
                return .init(from: adjustment.adjustedTime, to: old.to)
            }
            if adjustment.boundary == .end, old.to == adjustment.requestedTime {
                return .init(from: old.from, to: adjustment.adjustedTime)
            }
            throw stale
        }
        switch replacement.coverage {
        case .sequence(var fragments):
            guard let index = fragments.firstIndex(where: {
                $0.clipID == adjustment.occurrenceID &&
                    (adjustment.boundary == .start ? $0.range.from : $0.range.to) == adjustment.requestedTime
            }) else { throw stale }
            fragments[index].range = try change(fragments[index].range)
            replacement.coverage = .sequence(fragments)
        case .group(let range):
            replacement.coverage = .group(try change(range))
        }
        return try removingStill(id: id).addingStillReplacement(replacement)
    }
}
