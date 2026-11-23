import Foundation

extension CutProject {
    package func editingStills(sequence: (inout StillSequenceProject) throws -> Void,
                               multicam: (inout MulticamProject) throws -> Void) throws -> CutProject {
        let result: CutProject
        if var project = stillSequenceValue {
            try sequence(&project)
            result = project.hasStillContent || !project.transcripts.isEmpty || !project.sourceSelects.isEmpty || !project.participants.isEmpty
                ? .stillSequence(project) : .sequence(project.items.compactMap(\.source))
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

    package var hasSpacingBoundaries: Bool {
        let gaps = Set(stillAssets.filter(\.isGap).map(\.id))
        switch self {
        case .sequence(let clips): return clips.count >= 2
        case .stillSequence(let project):
            return project.items.lazy.filter { $0.still.map { !gaps.contains($0.assetID) } ?? true }.prefix(2).count == 2
        case .multicam(let project):
            return (project.assemblyItems ?? [.group(project.range)]).lazy.filter { $0.still.map { !gaps.contains($0.assetID) } ?? true }.prefix(2).count == 2
        }
    }

    package var hasInteriorSpacingGaps: Bool {
        let gaps = Set(stillAssets.filter(\.isGap).map(\.id))
        guard !gaps.isEmpty else { return false }
        func hasInteriorGap<Item>(_ items: [Item], insert: KeyPath<Item, StillInsert?>) -> Bool {
            let isGap: (Item) -> Bool = { item in
                item[keyPath: insert].map { gaps.contains($0.assetID) } ?? false
            }
            guard let first = items.firstIndex(where: { !isGap($0) }),
                  let last = items.lastIndex(where: { !isGap($0) }), first < last else { return false }
            return items[(first + 1)..<last].contains(where: isGap)
        }
        switch self {
        case .sequence: return false
        case .stillSequence(let project): return hasInteriorGap(project.items, insert: \.still)
        case .multicam(let project): return hasInteriorGap(project.assemblyItems ?? [], insert: \.still)
        }
    }

    /// Set the pauses between consecutive picture items in one history entry.
    /// Keep leading and trailing gaps, and retain the first gap ID at each join.
    public func spacingClips(duration: RationalTime, cadence: RationalTime, background: String) throws -> CutProject {
        guard duration >= .zero, cadence > .zero else { throw stillError("Enter a nonnegative spacing and a positive frame rate") }
        return try spacingClips(cadence: cadence, background: background,
                                sequenceSpacing: { _, _ in duration }, groupSpacing: { _, _ in duration })
    }

    /// Set the pauses between adjacent ranges on the same source or multicam group clock.
    public func spacingClipsUsingSourceTiming(cadence: RationalTime, background: String,
                                             relativeTo projectURL: URL? = nil) throws -> CutProject {
        guard cadence > .zero else { throw stillError("Enter a positive frame rate") }
        let directory = projectURL.map { ProjectFile.directory(of: $0) }

        func sharesSource(_ left: String, _ right: String) throws -> Bool {
            if left == right { return true }
            guard let directory else { return false }
            let leftURL = try ProjectFile.checkedSourceURL(file: left, in: directory)
            let rightURL = try ProjectFile.checkedSourceURL(file: right, in: directory)
            return ProjectFile.canonicalFileURL(leftURL) == ProjectFile.canonicalFileURL(rightURL)
        }

        func hole(from end: RationalTime, to start: RationalTime) throws -> RationalTime {
            guard start >= end else {
                throw stillError("Source timing requires consecutive ranges in chronological order without overlaps")
            }
            return try start.subtracting(end)
        }

        func untimedStill() -> CutError {
            stillError("Source timing cannot determine spacing next to a photo still. Use uniform spacing for those joins.")
        }

        return try spacingClips(cadence: cadence, background: background,
                                sequenceSpacing: { previous, next in
            guard let left = previous.source, let right = next.source else { throw untimedStill() }
            guard try sharesSource(left.file, right.file) else {
                throw stillError("Source timing requires consecutive clips to use the same media file")
            }
            return try hole(from: left.to, to: right.from)
        }, groupSpacing: { previous, next in
            guard let left = previous.group, let right = next.group else { throw untimedStill() }
            return try hole(from: left.to, to: right.from)
        })
    }

    private func spacingClips(
        cadence: RationalTime, background: String,
        sequenceSpacing: (StillSequenceItem, StillSequenceItem) throws -> RationalTime,
        groupSpacing: (StillAssemblyItem, StillAssemblyItem) throws -> RationalTime
    ) throws -> CutProject {
        let framing = StillImageFraming(mode: .fit, background: background)
        try framing.validate()
        let gapIDs = Set(stillAssets.filter(\.isGap).map(\.id))
        let asset = stillAssets.first(where: \.isGap) ?? StillAsset(gapID: UUID().uuidString)
        let previousAssets = Set(stillInserts.map(\.assetID))
        var addedGap = false
        func spaced<Item>(_ items: [Item], insert: KeyPath<Item, StillInsert?>, make: (StillInsert) -> Item,
                          spacing: (Item, Item) throws -> RationalTime) throws -> [Item] {
            let pictures = items.indices.filter { index in
                guard let card = items[index][keyPath: insert] else { return true }
                return !gapIDs.contains(card.assetID)
            }
            guard let first = pictures.first, let last = pictures.last, first < last else {
                throw stillError("Space Clips requires at least two clips or still pictures")
            }
            var result = Array(items[...first])
            for (left, right) in zip(pictures, pictures.dropFirst()) {
                let duration = try spacing(items[left], items[right])
                if duration > .zero {
                    let existing = items[(left + 1)..<right].first?[keyPath: insert]
                    result.append(make(StillInsert(id: existing?.id ?? UUID().uuidString, assetID: existing?.assetID ?? asset.id,
                                                   duration: duration, cadence: cadence, framing: framing)))
                    addedGap = true
                }
                result.append(items[right])
            }
            result.append(contentsOf: items.suffix(from: last + 1))
            return result
        }
        return try editingStills(sequence: { project in
            project.items = try spaced(project.items, insert: \.still, make: StillSequenceItem.still,
                                       spacing: sequenceSpacing)
            if addedGap && !gapIDs.contains(asset.id) { project.stillAssets.append(asset) }
            Self.pruneUnusedGapAssets(&project.stillAssets, previouslyUsed: previousAssets,
                                     inserts: project.items.compactMap(\.still))
        }, multicam: { project in
            let items = try spaced(project.assemblyItems ?? [.group(project.range)], insert: \.still,
                                   make: StillAssemblyItem.still, spacing: groupSpacing)
            project.assemblyItems = items
            if addedGap && !gapIDs.contains(asset.id) { project.stillAssets.append(asset) }
            Self.pruneUnusedGapAssets(&project.stillAssets, previouslyUsed: previousAssets,
                                     inserts: items.compactMap(\.still))
        })
    }

    private static func pruneUnusedGapAssets(_ assets: inout [StillAsset], previouslyUsed: Set<String>,
                                             inserts: [StillInsert]) {
        let unused = previouslyUsed.subtracting(inserts.map(\.assetID))
        assets.removeAll { $0.isGap && unused.contains($0.id) }
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
            guard !assets[index].isGap else { throw stillError("A color gap has no linked image.") }
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

    private func editingInsert(id: String, preserveGapAsset: Bool = false,
                               edit: (StillInsert) throws -> [StillInsert]) throws -> CutProject {
        try editingStills(sequence: { project in
            guard let index = project.items.firstIndex(where: { $0.still?.id == id }),
                  let insert = project.items[index].still else { throw unknownStill(id) }
            project.items.replaceSubrange(index...index, with: try edit(insert).map(StillSequenceItem.still))
            if !preserveGapAsset {
                Self.pruneUnusedGapAssets(&project.stillAssets, previouslyUsed: [insert.assetID],
                                         inserts: project.items.compactMap(\.still))
            }
        }, multicam: { project in
            guard var items = project.assemblyItems,
                  let index = items.firstIndex(where: { $0.still?.id == id }),
                  let insert = items[index].still else { throw unknownStill(id) }
            items.replaceSubrange(index...index, with: try edit(insert).map(StillAssemblyItem.still))
            project.assemblyItems = items.isEmpty ? nil : items
            if !preserveGapAsset {
                Self.pruneUnusedGapAssets(&project.stillAssets, previouslyUsed: [insert.assetID],
                                         inserts: items.compactMap(\.still))
            }
        })
    }

    public func movingStill(id: String, to destination: RationalTime) throws -> CutProject {
        let plan = try resolveStills()
        guard let insert = stillInserts.first(where: { $0.id == id }),
              let span = plan.spans.first(where: { $0.placementID == id }) else { throw unknownStill(id) }
        guard destination >= .zero, destination <= plan.duration else { throw stillError("Still move lies outside the timeline") }
        guard destination < span.output.from || destination > span.output.to else { return self }
        let target = destination < span.output.from ? destination : try destination.subtracting(insert.duration)
        return try editingInsert(id: id, preserveGapAsset: true) { _ in [] }.insertingStill(insert, at: target)
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
                        .group(.init(from: range.from, to: split), angle: item.angleOverride), .still(insert),
                        .group(.init(from: split, to: range.to), angle: item.angleOverride)
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

    /// Remove sorted, disjoint source ranges from each occurrence in one edit.
    package func removingSequencePauses(_ removals: [String: [AudioSpan]],
                                        checkCancellation: () throws -> Void) throws -> CutProject {
        guard !removals.isEmpty else { return self }
        return try editingStills(sequence: { project in
            var fragmentPieces: [String: [(id: String, from: RationalTime?, to: RationalTime?)]] = [:]
            project.items = try project.items.flatMap { item -> [StillSequenceItem] in
                try checkCancellation()
                guard let original = item.source, let cuts = removals[original.id] else { return [item] }
                let retained = AudioAnalysis.retained(in: .init(from: original.from, to: original.to), removing: cuts)
                let pieces = retained.map { span -> CutSequenceClip in
                    var clip = original
                    if span.from != original.from { clip.id = UUID().uuidString }
                    clip.from = span.from
                    clip.to = span.to
                    return clip
                }
                // Split replacement coverage at the same boundaries as normal clip
                // splitting, retaining hidden coverage when a clip is trimmed.
                fragmentPieces[original.id] = pieces.enumerated().map { index, piece in
                    let from = piece.id == original.id ? nil : piece.from
                    let to = index + 1 < pieces.count ? pieces[index + 1].from : nil
                    return (piece.id, from, to)
                }
                return pieces.map(StillSequenceItem.source)
            }
            guard !project.items.isEmpty else {
                throw CutError(code: "empty_edit", message: "The selected pauses cover the entire sequence. Increase --padding-per-side-seconds to retain footage.")
            }
            project.stillReplacements = try project.stillReplacements.compactMap { replacement in
                try checkCancellation()
                guard case .sequence(let fragments) = replacement.coverage else { return replacement }
                let retained = fragments.flatMap { fragment -> [StillReplacementFragment] in
                    guard let pieces = fragmentPieces[fragment.clipID] else { return [fragment] }
                    return pieces.compactMap { piece in
                        let from = max(fragment.range.from, piece.from ?? fragment.range.from)
                        let to = min(fragment.range.to, piece.to ?? fragment.range.to)
                        guard from < to else { return nil }
                        return .init(clipID: piece.id, range: .init(from: from, to: to))
                    }
                }
                guard !retained.isEmpty else { return nil }
                var edited = replacement
                edited.coverage = .sequence(retained)
                return edited
            }
        }, multicam: { _ in throw stillError("Sequence pause removal requires a sequence") })
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
        case .group(let range, _): try range.to.subtracting(range.from)
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
