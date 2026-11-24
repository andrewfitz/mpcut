import Foundation

extension MulticamRange {
    func participantIntersection(_ range: Self) -> Self? {
        let start = max(from, range.from)
        let end = min(to, range.to)
        return start < end ? .init(from: start, to: end) : nil
    }

    func participantShifted(by offset: RationalTime) throws -> Self {
        try .init(from: from.adding(offset), to: to.adding(offset))
    }
}

extension StillTimelinePlan {
    func participantScoped(to range: MulticamRange) throws -> Self {
        let offset = try RationalTime.zero.subtracting(range.from)
        let start = spans.lowerBound { $0.output.to > range.from }
        var selected: [StillTimelineSpan] = []
        for span in spans[start...] {
            if span.output.from >= range.to { break }
            guard let overlap = span.output.participantIntersection(range) else { continue }
            let delta = try overlap.from.subtracting(span.output.from)
            let length = try overlap.to.subtracting(overlap.from)
            func scopedSource(_ original: MulticamRange) throws -> MulticamRange {
                let from = try original.from.adding(delta)
                return try .init(from: from, to: from.adding(length))
            }
            let origin: StillTimelineOrigin
            switch span.origin {
            case .insert: origin = .insert
            case .source(let id, let source): origin = try .source(clipID: id, range: scopedSource(source))
            case .group(let index, let group): origin = try .group(assemblyIndex: index, range: scopedSource(group))
            }
            selected.append(.init(output: try overlap.participantShifted(by: offset),
                                  origin: origin, placementID: span.placementID))
        }
        return try .init(duration: range.to.subtracting(range.from), spans: selected)
    }
}

extension CutProject {
    /// Slice the authored audio assembly on the same output clock as the rendered picture.
    func participantSound(in range: MulticamRange?) throws -> Self {
        guard let range else { return self }
        switch self {
        case .sequence: return self
        case .stillSequence(var sequence):
            guard let soundtrack = sequence.stillSoundtrack else { return self }
            if let mapping = try stillSoundtrackMapping(in: range) {
                var clip = soundtrack
                clip.from = mapping.source.from
                clip.to = mapping.source.to
                sequence.stillSoundtrack = clip
            } else {
                sequence.stillSoundtrack = nil
                sequence.stillAudioReference = soundtrack
            }
            return .stillSequence(sequence)
        case .multicam(var multicam):
            var cursor = RationalTime.zero
            multicam.assemblyItems = try (multicam.assemblyItems ?? [.group(multicam.range)]).compactMap { item in
                let length: RationalTime
                switch item {
                case .group(let group, _, _, _): length = try group.to.subtracting(group.from)
                case .still(let insert): length = insert.duration
                }
                let end = try cursor.adding(length)
                defer { cursor = end }
                guard let overlap = MulticamRange(from: cursor, to: end).participantIntersection(range) else { return nil }
                switch item {
                case .group(let group, _, _, _):
                    return item.trimmingGroup(to: try overlap.participantShifted(by: group.from.subtracting(cursor)))
                case .still(var insert):
                    insert.duration = try overlap.to.subtracting(overlap.from)
                    insert.usesExactDuration = true
                    return .still(insert)
                }
            }
            return .multicam(multicam)
        }
    }
}
