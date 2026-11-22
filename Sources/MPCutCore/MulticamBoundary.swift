import Foundation

/// Joint switch times are on the group clock. Every grid must admit the same instant.
public enum MulticamBoundary {
    public enum Edge: Sendable { case start, end }

    public struct Grid: Sendable {
        fileprivate let times: [RationalTime]
        fileprivate let offset: RationalTime

        /// `first` and `last` mark a boundary that begins or ends the whole program.
        public init(media: MediaInfo, offset: RationalTime, edge: Edge, mode: ExportMode, container: String? = nil,
                    first: Bool = false, last: Bool = false) {
            self.offset = offset
            if mode == .encode {
                var frames = media.frames.map(\.time)
                if edge == .end { frames.append(media.duration) }
                times = frames
            } else {
                let engine = CutEngine(multicamSmartPicture: mode == .smart, cancelled: nil)
                times = engine.validBoundaries(in: media, start: edge == .start, first: first, last: last,
                                               container: container ?? media.url.pathExtension.lowercased())
            }
        }

        init(times: [RationalTime], offset: RationalTime) {
            self.times = times
            self.offset = offset
        }

        /// A continuous join can be legal between normal cut points, since no
        /// cut occurs on this lane. The additional time is on the source clock.
        func including(_ time: RationalTime?) -> Self {
            guard let time else { return self }
            let index = times.lowerBound { $0 >= time }
            if index < times.count, times[index] == time { return self }
            var values = times
            values.insert(time, at: index)
            return Self(times: values, offset: offset)
        }

        /// Expand a range once to inspect all routing decisions that moving its edge
        /// could expose. A project's group can end before its recording does.
        func expandedPlan(from edge: RationalTime, toward limit: RationalTime, original: MulticamPlan,
                          moving: (RationalTime) throws -> MulticamPlan?) throws -> MulticamPlan {
            guard edge != limit else { return original }
            if let plan = try moving(limit) { return plan }
            let earlier = limit < edge
            let low = try min(edge, limit).subtracting(offset)
            let high = try max(edge, limit).subtracting(offset)
            var lower = times.lowerBound { $0 > low }, upper = times.lowerBound { $0 >= high }
            var best = original
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let plan = try moving(times[middle].adding(offset))
                if let plan { best = plan }
                if (plan != nil) == earlier { upper = middle } else { lower = middle + 1 }
            }
            return best
        }

        /// The first and last instants of this grid on the group clock.
        func extent() throws -> ClosedRange<RationalTime>? {
            guard let first = times.first, let last = times.last, first <= last else { return nil }
            return try first.adding(offset)...last.adding(offset)
        }
    }

    /// Nearest earlier and later alternatives, excluding the rejected instant.
    public static func candidates(near requested: RationalTime, among grids: [Grid],
                                  within bounds: ClosedRange<RationalTime>,
                                  cancelled: () -> Bool = { false },
                                  accepting: (RationalTime) throws -> Bool = { _ in true }) throws -> [RationalTime] {
        try search(near: requested, among: grids, within: bounds, cancelled: cancelled) {
            try accepting($0) ? .accept : .skip
        }
    }

    enum Decision { case accept, skip, stopDirection }

    static func search(near requested: RationalTime, among grids: [Grid],
                       within bounds: ClosedRange<RationalTime>, cancelled: () -> Bool,
                       evaluate: (RationalTime) throws -> Decision) throws -> [RationalTime] {
        guard !grids.isEmpty, grids.allSatisfy({ !$0.times.isEmpty }) else { return [] }
        func nearest(later: Bool) throws -> RationalTime? {
            var indices = try grids.map { grid in
                let local = try requested.subtracting(grid.offset)
                return later ? grid.times.lowerBound { $0 > local } : grid.times.lowerBound { $0 >= local } - 1
            }
            while true {
                if cancelled() { throw CutError(code: "cancelled", message: "Multicam boundary search cancelled.") }
                var frontier: RationalTime?
                for (index, grid) in grids.enumerated() {
                    guard grid.times.indices.contains(indices[index]) else { return nil }
                    let time = try grid.times[indices[index]].adding(grid.offset)
                    if let previous = frontier {
                        frontier = later ? max(previous, time) : min(previous, time)
                    } else {
                        frontier = time
                    }
                }
                guard let time = frontier, later ? time <= bounds.upperBound : time >= bounds.lowerBound else { return nil }
                var aligned = true
                for (index, grid) in grids.enumerated() {
                    let local = try time.subtracting(grid.offset)
                    if grid.times[indices[index]] != local {
                        // Jump to the leading grid when sampling rates or GOP lengths differ.
                        let next = indices[index] + (later ? 1 : -1)
                        if grid.times.indices.contains(next),
                           later ? grid.times[next] >= local : grid.times[next] <= local {
                            indices[index] = next
                        } else {
                            indices[index] = later
                                ? grid.times.lowerBound { $0 >= local }
                                : grid.times.lowerBound { $0 > local } - 1
                        }
                        aligned = false
                    }
                }
                if aligned {
                    if bounds.contains(time) {
                        switch try evaluate(time) {
                        case .accept: return time
                        case .stopDirection: return nil
                        case .skip: break
                        }
                    }
                    for index in indices.indices { indices[index] += later ? 1 : -1 }
                }
            }
        }
        return try [nearest(later: false), nearest(later: true)].compactMap { $0 }
    }
}
