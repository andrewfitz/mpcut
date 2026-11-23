import Foundation

public enum TimelineClock: String, Codable, Sendable {
    case source, sequence, group, assembly

    var isInput: Bool { self == .source || self == .group }
}

/// A half-open piece of an authored occurrence. For a still insert, the
/// presentation range has no underlying source or group range.
public struct TimelineOccurrence: Codable, Equatable, Sendable {
    public let index: Int
    public let id: String?
    public let input: MulticamRange?
    public let output: MulticamRange
    public let file: String?
    public let originalFile: String?
    public let assetID: String?
    public let angleOverride: String?

    private enum CodingKeys: String, CodingKey {
        case index, id, input, output, file
        case originalFile = "original_file", assetID = "asset_id", angleOverride = "angle_override"
    }

    func clipping(to requested: MulticamRange, clock: TimelineClock) throws -> Self? {
        guard let extent = clock.isInput ? input : output,
              let overlap = extent.intersection(with: requested) else { return nil }
        let start = try overlap.from.subtracting(extent.from)
        let end = try overlap.to.subtracting(extent.from)
        func translated(_ other: MulticamRange) throws -> MulticamRange {
            try MulticamRange(from: other.from.adding(start), to: other.from.adding(end))
        }
        return try Self(index: index, id: id, input: clock.isInput ? overlap : input.map(translated),
                        output: clock.isInput ? translated(output) : overlap, file: file, originalFile: originalFile,
                        assetID: assetID, angleOverride: angleOverride)
    }
}

extension MulticamRange {
    fileprivate func intersection(with other: Self) -> Self? {
        let start = max(from, other.from)
        let end = min(to, other.to)
        return start < end ? Self(from: start, to: end) : nil
    }
}

public struct TimelineMapping: Codable, Equatable, Sendable {
    public let clock: TimelineClock
    public let inputClock: TimelineClock
    public let outputClock: TimelineClock
    public let range: MulticamRange
    public private(set) var pieces: [TimelineOccurrence]
    public private(set) var nextOffset: Int?

    package func page(offset: Int, limit: Int) -> Self {
        var result = self
        let start = min(pieces.count, offset)
        let end = start + min(pieces.count - start, limit)
        result.pieces = Array(pieces[start..<end])
        result.nextOffset = end < pieces.count ? end : nil
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case clock, inputClock = "input_clock", outputClock = "output_clock", range, pieces, nextOffset = "next_offset"
    }
}

extension CutProject {
    public var timelineInputClock: TimelineClock {
        if case .multicam = self { return .group }
        return .source
    }

    public var timelineOutputClock: TimelineClock {
        timelineInputClock == .group ? .assembly : .sequence
    }

    public func timelineOccurrences() throws -> [TimelineOccurrence] {
        var occurrences: [TimelineOccurrence] = []
        switch self {
        case .sequence(let clips): occurrences.reserveCapacity(clips.count)
        case .stillSequence(let sequence): occurrences.reserveCapacity(sequence.items.count)
        case .multicam(let multicam): occurrences.reserveCapacity(multicam.assemblyItems?.count ?? 1)
        }
        try forEachTimelineOccurrence { occurrences.append($0) }
        return occurrences
    }

    private func forEachTimelineOccurrence(_ visit: (TimelineOccurrence) -> Void) throws {
        var offset = RationalTime.zero
        func piece(index: Int, id: String? = nil, input: MulticamRange? = nil,
                   duration: RationalTime, file: String? = nil, originalFile: String? = nil,
                   assetID: String? = nil, angleOverride: String? = nil) throws {
            try Task.checkCancellation()
            let end = try offset.adding(duration)
            let occurrence = TimelineOccurrence(index: index, id: id, input: input,
                                                output: MulticamRange(from: offset, to: end), file: file,
                                                originalFile: originalFile, assetID: assetID, angleOverride: angleOverride)
            offset = end
            visit(occurrence)
        }
        func source(_ index: Int, _ clip: CutSequenceClip) throws {
            try piece(index: index, id: clip.id, input: MulticamRange(from: clip.from, to: clip.to),
                      duration: clip.to.subtracting(clip.from), file: clip.file, originalFile: clip.originalFile)
        }
        func still(_ index: Int, _ card: StillInsert) throws {
            try piece(index: index, id: card.id, duration: card.duration, assetID: card.assetID)
        }
        switch self {
        case .sequence(let clips):
            for (index, clip) in clips.enumerated() { try source(index, clip) }
        case .stillSequence(let sequence):
            for (index, item) in sequence.items.enumerated() {
                switch item {
                case .source(let clip): try source(index, clip)
                case .still(let card): try still(index, card)
                }
            }
        case .multicam(let multicam):
            let items: [StillAssemblyItem] = multicam.assemblyItems ?? [.group(multicam.range)]
            for (index, item) in items.enumerated() {
                switch item {
                case .group(let range, let angle):
                    try piece(index: index, input: range, duration: range.to.subtracting(range.from), angleOverride: angle)
                case .still(let card): try still(index, card)
                }
            }
        }
    }

    /// The source file filter matches the playable or original recording path.
    /// Callers can normalize stored media paths before querying.
    public func mapTimelineRange(_ range: MulticamRange, clock: TimelineClock, file: String? = nil,
                                 occurrenceIndex: Int? = nil) throws -> TimelineMapping {
        guard clock == timelineInputClock || clock == timelineOutputClock else {
            throw CutError(code: "invalid_clock", message: "Use \(timelineInputClock.rawValue) or \(timelineOutputClock.rawValue) time for this project.")
        }
        guard range.to > range.from, clock == .group || range.from >= .zero else {
            throw CutError(code: "invalid_range", message: "Supply a positive duration with nonnegative source or output bounds.")
        }
        guard file == nil || timelineInputClock == .source, file?.isEmpty != true else {
            throw CutError(code: "invalid_target", message: "The file filter identifies a source in a sequence project.")
        }
        var pieces: [TimelineOccurrence] = []
        var foundIndex = occurrenceIndex == nil
        var clippingError: (any Error)?
        try forEachTimelineOccurrence { item in
            guard occurrenceIndex == nil || occurrenceIndex == item.index else { return }
            foundIndex = true
            guard clippingError == nil, file == nil || file == item.file || file == item.originalFile else { return }
            do {
                if let clipped = try item.clipping(to: range, clock: clock) { pieces.append(clipped) }
            } catch {
                // Report errors computing the authored timeline before errors translating the query.
                clippingError = error
            }
        }
        guard foundIndex else {
            throw CutError(code: "invalid_target", message: "This occurrence index is unavailable.")
        }
        if let clippingError { throw clippingError }
        return TimelineMapping(clock: clock, inputClock: timelineInputClock, outputClock: timelineOutputClock,
                               range: range, pieces: pieces)
    }
}
