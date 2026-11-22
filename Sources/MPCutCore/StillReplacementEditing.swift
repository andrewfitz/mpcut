import Foundation

extension CutProject {
    /// Edit authored replacement coverage. Source times are relative to the selected occurrence's
    /// media, sequence times include inserted cards, and group times are independent of assembly.
    /// `at` translates the selected coverage without changing its duration. A sequence placement
    /// with multiple fully visible fragments can move or trim as a unit in sequence time. Edit a
    /// single fragment by passing its index, and use source time for bounds hidden by a clip trim.
    /// A duplicate keeps the original placement and assigns the destination its own ID. Detaching
    /// requires only a fragment index and a new ID, and leaves the total authored coverage intact.
    public func editingStillReplacement(id: String, fragmentIndex: Int? = nil,
                                        from: RationalTime? = nil, to: RationalTime? = nil,
                                        at: RationalTime? = nil, clock: String? = nil,
                                        duplicateID: String? = nil, detachID: String? = nil) throws -> CutProject {
        guard let original = stillReplacements.first(where: { $0.id == id }) else { throw unknownStill(id) }
        if let detachID {
            guard case .sequence(var fragments) = original.coverage, fragments.count > 1,
                  let fragmentIndex, fragments.indices.contains(fragmentIndex),
                  duplicateID == nil, from == nil, to == nil, at == nil, clock == nil else {
                throw stillError("Detach requires a single fragment index from a fragmented sequence replacement")
            }
            var detached = original
            detached.id = detachID
            detached.coverage = .sequence([fragments.remove(at: fragmentIndex)])
            var remainder = original
            remainder.coverage = .sequence(fragments)
            return try modifyingReplacement(id: id, replacement: remainder, adding: detached)
        }
        guard from != nil || to != nil || at != nil else { throw stillError("Specify a destination or replacement bounds") }
        guard at == nil || (from == nil && to == nil) else {
            throw stillError("Use a destination or replacement bounds")
        }

        var changed = original
        switch original.coverage {
        case .group(let range):
            guard (clock ?? "group") == "group", fragmentIndex == nil else {
                throw stillError("Multicam replacements use group time and have no source fragments")
            }
            changed.coverage = .group(try editingRange(range, from: from, to: to, at: at))
        case .sequence(var fragments):
            if let fragmentIndex, !fragments.indices.contains(fragmentIndex) {
                throw stillError("Unknown source fragment index \(fragmentIndex)")
            }
            let selected = fragmentIndex ?? (fragments.count == 1 ? fragments.startIndex : nil)
            switch clock ?? "sequence" {
            case "source":
                guard let selected else { throw stillError("Select a fragment to edit in source time") }
                var fragment = fragments[selected]
                fragment.range = try editingRange(fragment.range, from: from, to: to, at: at)
                fragments.replaceSubrange(selected...selected, with: [fragment])
                changed.coverage = .sequence(duplicateID == nil ? fragments : [fragment])
            case "sequence":
                let plan = try resolveStills()
                let visible = plan.visibleSourceFragments(for: id)
                func output(for fragment: StillReplacementFragment) throws -> MulticamRange {
                    guard let range = visible[fragment] else {
                        throw stillError("Edit a hidden or partially visible replacement fragment in source time")
                    }
                    return range
                }
                if let selected {
                    let output = try output(for: fragments[selected])
                    let destination = try editingRange(output, from: from, to: to, at: at)
                    let additions = try plan.sourceFragments(in: destination)
                    fragments.replaceSubrange(selected...selected, with: additions)
                    changed.coverage = .sequence(duplicateID == nil ? fragments : additions)
                } else {
                    var intervals = try fragments.map(output).sorted { $0.from < $1.from }
                    guard let first = intervals.first, let last = intervals.last else {
                        throw stillError("Sequence still needs source fragments")
                    }
                    if let at {
                        let delta = try at.subtracting(first.from)
                        intervals = try intervals.map { interval in
                            try .init(from: interval.from.adding(delta), to: interval.to.adding(delta))
                        }
                    } else {
                        let bounds = MulticamRange(from: from ?? first.from, to: to ?? last.to)
                        guard bounds.from >= .zero, bounds.to <= plan.duration, bounds.from < bounds.to else {
                            throw stillError("Picture replacement lies outside the timeline")
                        }
                        intervals[intervals.startIndex].from = min(first.from, bounds.from)
                        intervals[intervals.count - 1].to = max(last.to, bounds.to)
                        intervals = intervals.compactMap { interval in
                            let lower = max(interval.from, bounds.from)
                            let upper = min(interval.to, bounds.to)
                            return lower < upper ? .init(from: lower, to: upper) : nil
                        }
                        guard !intervals.isEmpty else { throw stillError("The new bounds leave no replacement coverage") }
                    }
                    changed.coverage = .sequence(try intervals.flatMap { try plan.sourceFragments(in: $0) })
                }
            default:
                throw stillError("Sequence replacements use sequence or source time")
            }
        }

        if let duplicateID {
            changed.id = duplicateID
            return try modifyingReplacement(id: id, replacement: original, adding: changed)
        }
        return try modifyingReplacement(id: id, replacement: changed)
    }

    private func modifyingReplacement(id: String, replacement: StillReplacement,
                                      adding: StillReplacement? = nil) throws -> CutProject {
        func update(_ replacements: inout [StillReplacement]) throws {
            guard let index = replacements.firstIndex(where: { $0.id == id }) else { throw unknownStill(id) }
            replacements[index] = replacement
            if let adding { replacements.append(adding) }
        }
        return try editingStills(sequence: { try update(&$0.stillReplacements) },
                                 multicam: { try update(&$0.stillReplacements) })
    }
}

private func editingRange(_ range: MulticamRange, from: RationalTime?, to: RationalTime?,
                          at: RationalTime?) throws -> MulticamRange {
    if let at {
        return try .init(from: at, to: at.adding(range.to.subtracting(range.from)))
    }
    return .init(from: from ?? range.from, to: to ?? range.to)
}

extension StillTimelinePlan {
    func sourceFragments(in output: MulticamRange) throws -> [StillReplacementFragment] {
        guard output.from >= .zero, output.to <= duration, output.from < output.to else {
            throw stillError("Picture replacement lies outside the timeline")
        }
        var fragments: [StillReplacementFragment] = []
        let first = spans.lowerBound { $0.output.to > output.from }
        for span in spans[first...] {
            if span.output.from >= output.to { break }
            guard case .source(let clipID, let range) = span.origin else {
                if let id = span.placementID { throw insertConflict(id) }
                throw stillError("Picture replacement requires a source occurrence")
            }
            let source = try MulticamRange(
                from: range.from.adding(max(span.output.from, output.from).subtracting(span.output.from)),
                to: range.from.adding(min(span.output.to, output.to).subtracting(span.output.from))
            )
            if let last = fragments.last, last.clipID == clipID, last.range.to == source.from {
                fragments[fragments.count - 1].range.to = source.to
            } else {
                fragments.append(.init(clipID: clipID, range: source))
            }
        }
        return fragments
    }

    func visibleSourceFragments(for placementID: String) -> [StillReplacementFragment: MulticamRange] {
        var visible: [StillReplacementFragment: MulticamRange] = [:]
        for span in spans where span.placementID == placementID {
            guard case .source(let clipID, let range) = span.origin else { continue }
            visible[.init(clipID: clipID, range: range)] = span.output
        }
        return visible
    }
}
