import Foundation

extension MulticamProject {
    /// A range in assembly time retains its ordered group slices and any intersecting cards.
    package func assemblySelection(_ selection: MulticamRange) throws -> MulticamProject {
        var cursor = RationalTime.zero
        var items: [StillAssemblyItem] = []
        for item in assemblyItems ?? [.group(range)] {
            let length: RationalTime
            switch item {
            case .group(let group): length = try group.to.subtracting(group.from)
            case .still(let insert): length = insert.duration
            }
            let end = try cursor.adding(length)
            let from = max(cursor, selection.from)
            let to = min(end, selection.to)
            if from < to {
                let lower = try from.subtracting(cursor)
                let upper = try to.subtracting(cursor)
                switch item {
                case .group(let group):
                    items.append(try .group(.init(from: group.from.adding(lower), to: group.from.adding(upper))))
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
