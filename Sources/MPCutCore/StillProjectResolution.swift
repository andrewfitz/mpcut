import Foundation

public enum StillTimelineOrigin: Codable, Equatable, Sendable {
    case source(clipID: String, range: MulticamRange)
    case group(assemblyIndex: Int, range: MulticamRange)
    case insert
}

public struct StillTimelineSpan: Codable, Equatable, Sendable {
    public let output: MulticamRange
    public let origin: StillTimelineOrigin
    public let placementID: String?
}

public struct StillTimelinePlan: Codable, Equatable, Sendable {
    public let duration: RationalTime
    public let spans: [StillTimelineSpan]

    public func visibleDuration(for placementID: String) throws -> RationalTime {
        try spans.lazy.filter { $0.placementID == placementID }.reduce(.zero) {
            try $0.adding($1.output.to.subtracting($1.output.from))
        }
    }

    public func span(at time: RationalTime) -> StillTimelineSpan? {
        let index = spans.lowerBound { $0.output.to > time }
        guard index < spans.count, spans[index].output.contains(time) else { return nil }
        return spans[index]
    }
}

extension CutProject {
    public var sequenceItems: [StillSequenceItem]? {
        switch self {
        case .sequence(let clips): clips.map(StillSequenceItem.source)
        case .stillSequence(let project): project.items
        case .multicam: nil
        }
    }

    public var sequenceClips: [CutSequenceClip]? {
        switch self {
        case .sequence(let clips): clips
        case .stillSequence(let project): project.items.compactMap(\.source)
        case .multicam: nil
        }
    }

    private static let maximumResolvedStillSpans = 1_000_000

    var stillSequenceValue: StillSequenceProject? {
        switch self {
        case .sequence(let clips): StillSequenceProject(items: clips.map(StillSequenceItem.source))
        case .stillSequence(let project): project
        case .multicam: nil
        }
    }

    public var stillAssets: [StillAsset] {
        switch self {
        case .sequence: []
        case .stillSequence(let project): project.stillAssets
        case .multicam(let project): project.stillAssets
        }
    }

    public var stillReplacements: [StillReplacement] {
        switch self {
        case .sequence: []
        case .stillSequence(let project): project.stillReplacements
        case .multicam(let project): project.stillReplacements
        }
    }

    public var stillInserts: [StillInsert] {
        switch self {
        case .sequence: []
        case .stillSequence(let project): project.items.compactMap(\.still)
        case .multicam(let project): project.assemblyItems?.compactMap(\.still) ?? []
        }
    }

    public var programColorPolicy: StillProgramColorPolicy? {
        switch self {
        case .sequence: nil
        case .stillSequence(let project): project.programColorPolicy
        case .multicam(let project): project.programColorPolicy
        }
    }

    public var stillFormat: StillTimelineFormat? {
        if case .stillSequence(let project) = self { return project.stillFormat }
        return nil
    }

    package var stillAudioReference: CutSequenceClip? {
        if case .stillSequence(let project) = self { return project.stillAudioReference }
        return nil
    }

    public func resolveStills() throws -> StillTimelinePlan {
        try validate()
        return try resolveStillsUnchecked()
    }

    func stillTimelineDuration() throws -> RationalTime {
        var duration = RationalTime.zero
        func add(_ range: MulticamRange) throws {
            duration = try duration.adding(range.to.subtracting(range.from))
        }
        if case .multicam(let project) = self {
            for item in project.assemblyItems ?? [.group(project.range)] {
                switch item {
                case .group(let range, _, _, _): try add(range)
                case .still(let insert): duration = try duration.adding(insert.duration)
                }
            }
        } else {
            for item in sequenceItems ?? [] {
                switch item {
                case .source(let clip): try add(.init(from: clip.from, to: clip.to))
                case .still(let insert): duration = try duration.adding(insert.duration)
                }
            }
        }
        return duration
    }

    /// Verify authored handles when the media is online. Each value is the available source-time domain.
    public func validateStillSourceExtents(_ extents: [String: MulticamRange]) throws {
        for replacement in stillReplacements {
            guard case .sequence(let fragments) = replacement.coverage else { continue }
            for fragment in fragments {
                if let extent = extents[fragment.clipID],
                   fragment.range.from < extent.from || fragment.range.to > extent.to {
                    throw stillError("Still ‘\(replacement.id)’ extends outside source ‘\(fragment.clipID)’",
                                     placementIDs: [replacement.id])
                }
            }
        }
    }

    func resolveStillsUnchecked() throws -> StillTimelinePlan {
        var replacements: [String: [(range: MulticamRange, id: String)]] = [:]
        for replacement in stillReplacements {
            switch replacement.coverage {
            case .sequence(let fragments):
                for fragment in fragments {
                    replacements[fragment.clipID, default: []].append((fragment.range, replacement.id))
                }
            case .group(let range): replacements["", default: []].append((range, replacement.id))
            }
        }
        for id in Array(replacements.keys) {
            replacements[id]?.sort { $0.range.from < $1.range.from }
        }
        var output = RationalTime.zero
        var spans: [StillTimelineSpan] = []
        func append(duration: RationalTime, origin: StillTimelineOrigin, placementID: String?) throws {
            guard spans.count < Self.maximumResolvedStillSpans else {
                throw stillError("Still timeline exceeds the resolved span limit")
            }
            let end = try output.adding(duration)
            spans.append(.init(output: .init(from: output, to: end), origin: origin, placementID: placementID))
            output = end
        }
        func appendSource(_ range: MulticamRange, key: String, origin: (MulticamRange) -> StillTimelineOrigin) throws {
            func appendPart(from: RationalTime, to: RationalTime, id: String? = nil) throws {
                guard from < to else { return }
                try append(duration: to.subtracting(from), origin: origin(.init(from: from, to: to)), placementID: id)
            }
            var cursor = range.from
            let intervals = replacements[key] ?? []
            let first = intervals.lowerBound { $0.range.to > range.from }
            for (authored, id) in intervals[first...] {
                if authored.from >= range.to { break }
                let from = max(cursor, authored.from)
                let to = min(range.to, authored.to)
                try appendPart(from: cursor, to: from)
                try appendPart(from: from, to: to, id: id)
                cursor = to
            }
            try appendPart(from: cursor, to: range.to)
        }
        switch self {
        case .multicam(let project):
            for (index, item) in (project.assemblyItems ?? [.group(project.range)]).enumerated() {
                switch item {
                case .group(let range, _, _, _):
                    try appendSource(range, key: "") { .group(assemblyIndex: index, range: $0) }
                case .still(let insert):
                    try append(duration: insert.duration, origin: .insert, placementID: insert.id)
                }
            }
        case .sequence, .stillSequence:
            for item in sequenceItems ?? [] {
                switch item {
                case .source(let clip):
                    try appendSource(.init(from: clip.from, to: clip.to), key: clip.id) { .source(clipID: clip.id, range: $0) }
                case .still(let insert):
                    try append(duration: insert.duration, origin: .insert, placementID: insert.id)
                }
            }
        }
        return StillTimelinePlan(duration: output, spans: spans)
    }
}
