import Foundation

extension MulticamProject {
    /// A range in assembly time retains its ordered group slices and any intersecting cards.
    package func assemblySelection(_ selection: MulticamRange) throws -> MulticamProject {
        var cursor = RationalTime.zero
        var items: [StillAssemblyItem] = []
        for item in assemblyItems ?? [.group(range)] {
            let length: RationalTime
            switch item {
            case .group(let group, _): length = try group.to.subtracting(group.from)
            case .still(let insert): length = insert.duration
            }
            let end = try cursor.adding(length)
            let from = max(cursor, selection.from)
            let to = min(end, selection.to)
            if from < to {
                let lower = try from.subtracting(cursor)
                let upper = try to.subtracting(cursor)
                switch item {
                case .group(let group, let angle):
                    items.append(try .group(.init(from: group.from.adding(lower), to: group.from.adding(upper)), angle: angle))
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
