import Foundation

extension MulticamProject {
    /// A range in assembly time retains its ordered group slices and any intersecting cards.
    package func assemblySelection(_ selection: MulticamRange) throws -> MulticamProject {
        var cursor = RationalTime.zero
        var items: [StillAssemblyItem] = []
        var occurrences: [Int: Int] = [:]
        for (index, item) in (assemblyItems ?? [.group(range)]).enumerated() {
            let length: RationalTime
            switch item {
            case .group(let group, _, _, _): length = try group.to.subtracting(group.from)
            case .still(let insert): length = insert.duration
            }
            let end = try cursor.adding(length)
            let from = max(cursor, selection.from)
            let to = min(end, selection.to)
            if from < to {
                occurrences[index] = items.count
                let lower = try from.subtracting(cursor)
                let upper = try to.subtracting(cursor)
                switch item {
                case .group(let group, _, _, _):
                    items.append(try item.trimmingGroup(to: .init(from: group.from.adding(lower), to: group.from.adding(upper))))
                case .still(var insert):
                    var prefix = insert
                    prefix.duration = lower
                    insert.duration = try upper.subtracting(lower)
                    guard (lower == .zero || (try? prefix.frameCount()) != nil),
                          (upper == length || (try? insert.frameCount()) != nil) else {
                        throw CutError(code: "invalid_still_time", message: "Select complete frames of card ‘\(insert.id)’.")
                    }
                    items.append(.still(insert))
                }
            }
            cursor = end
        }
        guard selection.from >= .zero, selection.from < selection.to, selection.to <= cursor else {
            throw CutError(code: "invalid_range", message: "Select increasing bounds within the assembly duration.")
        }
        var snapshot = self
        snapshot.assemblyItems = items
        if var render = participants.render {
            render.shots = try render.shots.compactMap { authored in
                guard authored.clock == .output, let range = authored.range else { return authored }
                let from = max(selection.from, range.from)
                let to = min(selection.to, range.to)
                guard from < to else { return nil }
                var shot = authored
                if let oldIndex = authored.occurrence {
                    guard let newIndex = occurrences[oldIndex] else { return nil }
                    shot.occurrence = newIndex
                }
                shot.range = .init(from: try from.subtracting(selection.from), to: try to.subtracting(selection.from))
                return shot
            }
            snapshot.participants.render = render
        }
        try snapshot.validate()
        return snapshot
    }
}

extension MulticamProject {
    package func pictureAngle(at group: RationalTime, in occurrence: Int? = nil,
                              exclusiveEnd: Bool = false) -> String? {
        if let occurrence, let assemblyItems, assemblyItems.indices.contains(occurrence),
           let angle = assemblyItems[occurrence].angleOverride {
            return angle
        }
        return exclusiveEnd ? switches.last(where: { $0.at < group })?.angle : selection(at: group)?.angle
    }
}

extension MulticamProject {
    /// Group-clock exports follow the group switch lane. Carry legacy output-clock
    /// layouts to the new program by their original relationship to group time.
    package func pictureExportSnapshot(ranges: [MulticamRange]) throws -> MulticamProject {
        var snapshot = self
        snapshot.assemblyItems = ranges.map { .group($0) }
        try snapshot.validate()
        guard var render = participants.render, render.shots.contains(where: { $0.range != nil && $0.clock == .output }) else {
            return snapshot
        }
        let old = try plan().intervals.sorted { $0.group.from < $1.group.from }
        var prefixEnds: [RationalTime] = []
        for interval in old {
            prefixEnds.append(max(prefixEnds.last ?? interval.group.to, interval.group.to))
        }
        let new = try snapshot.plan().intervals
        let shots = ParticipantTimedShot.index(render.shots)
        let general = shots[.init(clock: .output, occurrence: nil)] ?? []
        render.shots.removeAll { $0.range != nil && $0.clock == .output }
        for target in new {
            let start = prefixEnds.lowerBound { $0 > target.group.from }
            let end = old.lowerBound { $0.group.from >= target.group.to }
            guard start < end else { continue }
            var uncovered = [target.group]
            // A group position can appear more than once. Prefer its first authored occurrence.
            let candidates = old[start..<end].filter { $0.group.to > target.group.from }
                .sorted { $0.output.from < $1.output.from }
            for source in candidates {
                let specific = shots[.init(clock: .output, occurrence: source.assemblyIndex)] ?? []
                let candidates = specific.overlapping(source.output).map(\.shot)
                    + general.overlapping(source.output).map(\.shot)
                for authored in candidates {
                    guard let interval = authored.range else { continue }
                    let from = max(source.output.from, interval.from)
                    let to = min(source.output.to, interval.to)
                    guard from < to else { continue }
                    let start = try source.group.from.adding(from.subtracting(source.output.from))
                    let end = try source.group.from.adding(to.subtracting(source.output.from))
                    var remaining: [MulticamRange] = []
                    for available in uncovered {
                        let first = max(start, available.from)
                        let last = min(end, available.to)
                        guard first < last else { remaining.append(available); continue }
                        var shot = authored
                        shot.occurrence = target.assemblyIndex
                        shot.range = .init(from: try target.output.from.adding(first.subtracting(target.group.from)),
                                           to: try target.output.from.adding(last.subtracting(target.group.from)))
                        render.shots.append(shot)
                        if available.from < first { remaining.append(.init(from: available.from, to: first)) }
                        if last < available.to { remaining.append(.init(from: last, to: available.to)) }
                    }
                    uncovered = remaining
                }
                if uncovered.isEmpty { break }
            }
        }
        snapshot.participants.render = render
        return snapshot
    }
}
