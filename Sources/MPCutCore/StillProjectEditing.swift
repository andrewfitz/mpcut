import Foundation

extension CutProject {
    func editingStills(sequence: (inout StillSequenceProject) throws -> Void,
                               multicam: (inout MulticamProject) throws -> Void) throws -> CutProject {
        let result: CutProject
        if var project = stillSequenceValue {
            try sequence(&project)
            result = project.requiresV2 ? .stillSequence(project) : .sequence(project.items.compactMap(\.source))
        } else if case .multicam(var project) = self {
            try multicam(&project)
            result = .multicam(project)
        } else {
            preconditionFailure("Unhandled project kind")
        }
        try result.validate()
        return result
    }

    public func addingStillAsset(_ asset: StillAsset) throws -> CutProject {
        if stillAssets.contains(asset) { return self }
        return try editingStills(sequence: { $0.stillAssets.append(asset) }, multicam: { $0.stillAssets.append(asset) })
    }

    public func addingStillReplacement(_ replacement: StillReplacement) throws -> CutProject {
        try editingStills(sequence: { $0.stillReplacements.append(replacement) },
                          multicam: { $0.stillReplacements.append(replacement) })
    }

    public func settingStillColorPolicy(_ color: StillProgramColorPolicy?) throws -> CutProject {
        try editingStills(sequence: { $0.programColorPolicy = color }, multicam: { $0.programColorPolicy = color })
    }

    public func settingStillFormat(_ format: StillTimelineFormat?) throws -> CutProject {
        try editingStills(sequence: { $0.stillFormat = format },
                          multicam: { _ in throw stillError("A standalone still format requires a sequence") })
    }

    public func relinkingStillAsset(_ id: String, file: String, fingerprint: String) throws -> CutProject {
        func relink(_ assets: inout [StillAsset]) throws {
            guard let index = assets.firstIndex(where: { $0.id == id }) else { throw unknownStill(id) }
            assets[index].file = file
            assets[index].fingerprint = fingerprint
        }
        return try editingStills(sequence: { try relink(&$0.stillAssets) }, multicam: { try relink(&$0.stillAssets) })
    }

    public func updatingStill(id: String, assetID: String? = nil, framing: StillImageFraming? = nil) throws -> CutProject {
        if stillInserts.contains(where: { $0.id == id }) {
            return try editingInsert(id: id) { insert in
                var changed = insert
                if let assetID { changed.assetID = assetID }
                if let framing { changed.framing = framing }
                return [changed]
            }
        }
        func update(_ replacements: inout [StillReplacement]) throws {
            guard let index = replacements.firstIndex(where: { $0.id == id }) else { throw unknownStill(id) }
            if let assetID { replacements[index].assetID = assetID }
            if let framing { replacements[index].framing = framing }
        }
        return try editingStills(sequence: { try update(&$0.stillReplacements) }, multicam: { try update(&$0.stillReplacements) })
    }

    public func removingStill(id: String) throws -> CutProject {
        if stillInserts.contains(where: { $0.id == id }) { return try editingInsert(id: id) { _ in [] } }
        func remove(_ replacements: inout [StillReplacement]) throws {
            guard let index = replacements.firstIndex(where: { $0.id == id }) else { throw unknownStill(id) }
            replacements.remove(at: index)
        }
        return try editingStills(sequence: { try remove(&$0.stillReplacements) }, multicam: { try remove(&$0.stillReplacements) })
    }

    public func resizingStill(id: String, duration: RationalTime, cadence: RationalTime? = nil) throws -> CutProject {
        try editingInsert(id: id) { insert in
            var changed = insert
            changed.duration = duration
            if let cadence { changed.cadence = cadence }
            return [changed]
        }
    }

    public func splittingStill(id: String, at offset: RationalTime, newID: String = UUID().uuidString) throws -> CutProject {
        try editingInsert(id: id) { insert in
            var left = insert
            left.duration = offset
            var right = insert
            right.duration = try insert.duration.subtracting(offset)
            right.id = newID
            return [left, right]
        }
    }

    private func editingInsert(id: String, edit: (StillInsert) throws -> [StillInsert]) throws -> CutProject {
        try editingStills(sequence: { project in
            guard let index = project.items.firstIndex(where: { $0.still?.id == id }),
                  let insert = project.items[index].still else { throw unknownStill(id) }
            project.items.replaceSubrange(index...index, with: try edit(insert).map(StillSequenceItem.still))
        }, multicam: { project in
            guard var items = project.assemblyItems,
                  let index = items.firstIndex(where: { $0.still?.id == id }),
                  let insert = items[index].still else { throw unknownStill(id) }
            items.replaceSubrange(index...index, with: try edit(insert).map(StillAssemblyItem.still))
            project.assemblyItems = items.isEmpty ? nil : items
        })
    }

    public func movingStill(id: String, to destination: RationalTime) throws -> CutProject {
        let plan = try resolveStills()
        guard let insert = stillInserts.first(where: { $0.id == id }),
              let span = plan.spans.first(where: { $0.placementID == id }) else { throw unknownStill(id) }
        guard destination >= .zero, destination <= plan.duration else { throw stillError("Still move lies outside the timeline") }
        guard destination < span.output.from || destination > span.output.to else { return self }
        let target = destination < span.output.from ? destination : try destination.subtracting(insert.duration)
        return try removingStill(id: id).insertingStill(insert, at: target)
    }

    public func insertingStill(_ insert: StillInsert, at position: RationalTime) throws -> CutProject {
        guard position >= .zero else { throw stillError("Insertion lies outside the timeline") }
        return try editingStills(sequence: { project in
            var start = RationalTime.zero
            for (index, item) in project.items.enumerated() {
                if position == start { project.items.insert(.still(insert), at: index); return }
                let end = try start.adding(item.duration())
                if position < end {
                    guard let clip = item.source else { throw insertConflict(item.still!.id) }
                    let split = try clip.from.adding(position.subtracting(start))
                    try project.splitClip(at: index, time: split, rightID: UUID().uuidString)
                    project.items.insert(.still(insert), at: index + 1)
                    return
                }
                start = end
            }
            guard position == start else { throw stillError("Insertion lies outside the timeline") }
            project.items.append(.still(insert))
        }, multicam: { project in
            var items = project.assemblyItems ?? [.group(project.range)]
            var start = RationalTime.zero
            for (index, item) in items.enumerated() {
                if position == start { items.insert(.still(insert), at: index); project.assemblyItems = items; return }
                let end = try start.adding(item.duration())
                if position < end {
                    guard let range = item.group else { throw insertConflict(item.still!.id) }
                    let split = try range.from.adding(position.subtracting(start))
                    items.replaceSubrange(index...index, with: [
                        .group(.init(from: range.from, to: split)), .still(insert),
                        .group(.init(from: split, to: range.to))
                    ])
                    project.assemblyItems = items
                    return
                }
                start = end
            }
            guard position == start else { throw stillError("Insertion lies outside the timeline") }
            items.append(.still(insert))
            project.assemblyItems = items
        })
    }

    public func replacingPicture(id: String, assetID: String, framing: StillImageFraming = .fit,
                                 from: RationalTime, to: RationalTime) throws -> CutProject {
        guard sequenceItems != nil else { throw stillError("Multicam replacements are authored in group time") }
        let fragments = try resolveStills().sourceFragments(in: .init(from: from, to: to))
        return try addingStillReplacement(.init(id: id, assetID: assetID, framing: framing, coverage: .sequence(fragments)))
    }

    public func splittingSequenceClip(id: String, at time: RationalTime, newID: String = UUID().uuidString) throws -> CutProject {
        try editSequenceClip(id: id) { try $0.splitClip(at: $1, time: time, rightID: newID) }
    }

    public func trimmingSequenceClip(id: String, from: RationalTime, to: RationalTime) throws -> CutProject {
        try editSequenceClip(id: id) { project, index in
            guard var clip = project.items[index].source else { throw unknownStill(id) }
            clip.from = from
            clip.to = to
            project.items[index] = .source(clip)
        }
    }

    public func removingSequenceClip(id: String) throws -> CutProject {
        try editSequenceClip(id: id) { project, index in
            project.items.remove(at: index)
            project.stillReplacements = project.stillReplacements.compactMap { replacement in
                guard case .sequence(let fragments) = replacement.coverage else { return replacement }
                let remainder = fragments.filter { $0.clipID != id }
                guard !remainder.isEmpty else { return nil }
                var edited = replacement
                edited.coverage = .sequence(remainder)
                return edited
            }
        }
    }

    public func duplicatingSequenceClip(id: String, newID: String = UUID().uuidString) throws -> CutProject {
        try editSequenceClip(id: id) { project, index in
            guard var clip = project.items[index].source else { throw unknownStill(id) }
            clip.id = newID
            project.items.insert(.source(clip), at: index + 1)
            let copies = project.stillReplacements.compactMap { replacement -> StillReplacement? in
                guard case .sequence(let fragments) = replacement.coverage else { return nil }
                let added = fragments.filter { $0.clipID == id }.map { StillReplacementFragment(clipID: newID, range: $0.range) }
                guard !added.isEmpty else { return nil }
                return .init(id: UUID().uuidString, assetID: replacement.assetID, framing: replacement.framing,
                             coverage: .sequence(added))
            }
            project.stillReplacements.append(contentsOf: copies)
        }
    }

    private func editSequenceClip(id: String, edit: (inout StillSequenceProject, Int) throws -> Void) throws -> CutProject {
        try editingStills(sequence: { project in
            guard let index = project.items.firstIndex(where: { $0.source?.id == id }) else {
                throw stillError("Unknown source occurrence ‘\(id)’")
            }
            try edit(&project, index)
        }, multicam: { _ in throw stillError("Sequence clip editing requires a sequence") })
    }
}

private extension StillSequenceProject {
    mutating func splitClip(at index: Int, time: RationalTime, rightID: String) throws {
        guard let original = items[index].source, time > original.from, time < original.to else {
            throw stillError("Source split must lie within the clip trim")
        }
        var left = original
        left.to = time
        var right = original
        right.id = rightID
        right.from = time
        items.replaceSubrange(index...index, with: [.source(left), .source(right)])
        for placement in stillReplacements.indices {
            guard case .sequence(let fragments) = stillReplacements[placement].coverage else { continue }
            stillReplacements[placement].coverage = .sequence(fragments.flatMap { fragment in
                guard fragment.clipID == original.id else { return [fragment] }
                var split: [StillReplacementFragment] = []
                if fragment.range.from < time {
                    split.append(.init(clipID: original.id,
                                       range: .init(from: fragment.range.from, to: min(time, fragment.range.to))))
                }
                if fragment.range.to > time {
                    split.append(.init(clipID: rightID,
                                       range: .init(from: max(time, fragment.range.from), to: fragment.range.to)))
                }
                return split
            })
        }
    }
}

private extension StillSequenceItem {
    func duration() throws -> RationalTime {
        switch self {
        case .source(let clip): try clip.to.subtracting(clip.from)
        case .still(let insert): insert.duration
        }
    }
}

private extension StillAssemblyItem {
    func duration() throws -> RationalTime {
        switch self {
        case .group(let range): try range.to.subtracting(range.from)
        case .still(let insert): insert.duration
        }
    }
}

func unknownStill(_ id: String) -> CutError {
    stillError("Unknown still ‘\(id)’", code: "unknown_still")
}

func insertConflict(_ id: String) -> CutError {
    stillError("The requested edit intersects inserted still ‘\(id)’", code: "still_insert_conflict", placementIDs: [id])
}
