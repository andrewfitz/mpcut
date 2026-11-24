import Foundation

public struct TimelineComparison: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case added, removed, modified }
        public let kind: Kind
        public let before: TimelineOccurrence?
        public let after: TimelineOccurrence?
        public let fields: [String]
        public var id: String { "\(before.map { String($0.index) } ?? "-")/\(after.map { String($0.index) } ?? "-")" }
    }

    public let beforeClock: TimelineClock
    public let afterClock: TimelineClock
    public let beforeDuration: RationalTime
    public let afterDuration: RationalTime
    public let projectFields: [String]
    public private(set) var changes: [Change]
    public private(set) var nextOffset: Int?

    package func page(offset: Int, limit: Int) -> Self {
        var result = self
        let start = min(changes.count, offset)
        let end = start + min(changes.count - start, limit)
        result.changes = Array(changes[start..<end])
        result.nextOffset = end < changes.count ? end : nil
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case beforeClock = "before_clock", afterClock = "after_clock"
        case beforeDuration = "before_duration", afterDuration = "after_duration"
        case projectFields = "project_fields", changes, nextOffset = "next_offset"
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(beforeClock, forKey: .beforeClock)
        try fields.encode(afterClock, forKey: .afterClock)
        try fields.encode(beforeDuration.description, forKey: .beforeDuration)
        try fields.encode(afterDuration.description, forKey: .afterDuration)
        try fields.encode(projectFields, forKey: .projectFields)
        try fields.encode(changes, forKey: .changes)
        try fields.encodeIfPresent(nextOffset, forKey: .nextOffset)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(beforeClock: fields.decode(TimelineClock.self, forKey: .beforeClock),
                      afterClock: fields.decode(TimelineClock.self, forKey: .afterClock),
                      beforeDuration: ProjectField.time(fields, .beforeDuration),
                      afterDuration: ProjectField.time(fields, .afterDuration),
                      projectFields: fields.decode([String].self, forKey: .projectFields),
                      changes: fields.decode([Change].self, forKey: .changes))
        nextOffset = try fields.decodeIfPresent(Int.self, forKey: .nextOffset)
    }

    private init(beforeClock: TimelineClock, afterClock: TimelineClock, beforeDuration: RationalTime,
                 afterDuration: RationalTime, projectFields: [String], changes: [Change]) {
        self.beforeClock = beforeClock
        self.afterClock = afterClock
        self.beforeDuration = beforeDuration
        self.afterDuration = afterDuration
        self.projectFields = projectFields
        self.changes = changes
    }

    public static func compare(from before: CutProject, to after: CutProject) throws -> Self {
        let previous = try before.timelineOccurrences()
        let current = try after.timelineOccurrences()
        let oldContents = Contents(before), newContents = Contents(after)
        let sameClock = before.timelineOutputClock == after.timelineOutputClock
        var projectFields: [String] = []
        if !sameClock { projectFields.append("clock") }
        if before.sourceSelects != after.sourceSelects { projectFields.append("source_selects") }
        if before.transcripts.attachments != after.transcripts.attachments || before.transcripts.authoring != after.transcripts.authoring {
            projectFields.append("transcripts")
        }
        if oldContents.assets != newContents.assets { projectFields.append("still_assets") }
        if oldContents.replacements != newContents.replacements { projectFields.append("picture_replacements") }
        if before.programColorPolicy != after.programColorPolicy { projectFields.append("program_color") }
        if before.stillFormat != after.stillFormat { projectFields.append("still_format") }
        if before.stillAudioReference != after.stillAudioReference { projectFields.append("still_audio_reference") }
        if before.stillSoundtrack != after.stillSoundtrack { projectFields.append("still_soundtrack") }
        var groupChanges: [String] = []
        if case .multicam(let old) = before, case .multicam(let new) = after {
            if old.range != new.range { projectFields.append("group_range") }
            if old.referenceAngle != new.referenceAngle { projectFields.append("reference_angle") }
            if old.angles != new.angles || old.audioSources != new.audioSources { groupChanges.append("group_sources") }
            if old.audio != new.audio || old.fixedAudio != new.fixedAudio || old.mixLanes != new.mixLanes
                || old.audioReplacements != new.audioReplacements {
                groupChanges.append("program_audio")
            }
            if old.switches != new.switches { groupChanges.append("switches") }
        }
        projectFields += groupChanges

        // Multicam group occurrences have revision-local indices. Pair equal
        // ranges in order, while source clips and stills use their authored IDs.
        var oldIndices: [Identity: [Int]] = [:]
        for item in previous.reversed() {
            try Task.checkCancellation()
            if let key = Identity(item) { oldIndices[key, default: []].append(item.index) }
        }
        let groupMetadataChanges = groupChanges.filter { $0 != "switches" }
        let compareSwitches = groupChanges.contains("switches")
        var groupSwitchChanges: [MulticamRange: Bool] = [:]
        var matched = Set<Int>()
        var changes: [Change] = []
        for item in current {
            try Task.checkCancellation()
            guard sameClock, let key = Identity(item), let index = oldIndices[key]?.popLast() else {
                changes.append(Change(kind: .added, before: nil, after: item, fields: []))
                continue
            }
            matched.insert(index)
            let old = previous[index]
            var fields: [String] = []
            if old.index != item.index { fields.append("order") }
            if old.output != item.output { fields.append("output_range") }
            if old.input != item.input { fields.append("input_range") }
            if let id = item.id {
                if oldContents.sourceChanged(id, comparedWith: newContents) { fields.append("source") }
                if oldContents.cards[id] != newContents.cards[id] { fields.append("still") }
            }
            if oldContents.asset(old.assetID) != newContents.asset(item.assetID) { fields.append("still_asset") }
            if oldContents.replacementContents(for: old) != newContents.replacementContents(for: item) {
                fields.append("picture_replacement")
            }
            if key.isGroup {
                if old.angleOverride != item.angleOverride { fields.append("angle_override") }
                fields += groupMetadataChanges
                if compareSwitches, let range = item.input {
                    let changed = groupSwitchChanges[range] ?? (oldContents.switches(in: range) != newContents.switches(in: range))
                    groupSwitchChanges[range] = changed
                    if changed { fields.append("switches") }
                }
            }
            if !fields.isEmpty { changes.append(Change(kind: .modified, before: old, after: item, fields: fields)) }
        }
        for item in previous where !matched.contains(item.index) {
            try Task.checkCancellation()
            changes.append(Change(kind: .removed, before: item, after: nil, fields: []))
        }
        try Task.checkCancellation()
        return Self(beforeClock: before.timelineOutputClock, afterClock: after.timelineOutputClock,
                    beforeDuration: previous.last?.output.to ?? .zero, afterDuration: current.last?.output.to ?? .zero,
                    projectFields: projectFields, changes: changes)
    }

    private enum Identity: Hashable {
        case clip(String), still(String), group(MulticamRange)

        init?(_ item: TimelineOccurrence) {
            if let id = item.id {
                self = item.assetID != nil ? .still(id) : .clip(id)
            } else if let input = item.input {
                self = .group(input)
            } else {
                return nil
            }
        }

        var isGroup: Bool {
            if case .group = self { return true }
            return false
        }
    }

    private struct Contents {
        private struct Source: Equatable {
            let file: String
            let originalFile: String?
            let audioTrack: Int?
            let replacementNames: [Int: String]

            init(_ clip: CutSequenceClip) {
                file = clip.file
                originalFile = clip.originalFile
                audioTrack = clip.audioTrack
                replacementNames = clip.replacementNames
            }
        }

        private let sources: [String: Source]
        let cards: [String: StillInsert]
        let assets: [String: StillAsset]
        let replacements: [StillReplacement]
        let replacementsByClip: [String: [StillReplacement]]
        let groupReplacements: [(MulticamRange, StillReplacement)]
        let switches: [MulticamSwitch]

        init(_ project: CutProject) {
            let sourceClips: [CutSequenceClip]
            let stillCards: [StillInsert]
            switch project {
            case .sequence(let clips):
                sourceClips = clips
                stillCards = []
                switches = []
            case .stillSequence(let sequence):
                sourceClips = sequence.items.compactMap(\.source)
                stillCards = sequence.items.compactMap(\.still)
                switches = []
            case .multicam(let multicam):
                sourceClips = []
                stillCards = multicam.assemblyItems?.compactMap(\.still) ?? []
                switches = multicam.switches
            }
            sources = Dictionary(sourceClips.map { ($0.id, Source($0)) }, uniquingKeysWith: { first, _ in first })
            cards = Dictionary(stillCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            assets = Dictionary(project.stillAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            replacements = project.stillReplacements
            var byClip: [String: [StillReplacement]] = [:]
            var group: [(MulticamRange, StillReplacement)] = []
            for replacement in replacements {
                switch replacement.coverage {
                case .group(let range):
                    group.append((range, replacement))
                case .sequence(let fragments):
                    for fragment in fragments {
                        var fragmentPlacement = replacement
                        fragmentPlacement.coverage = .sequence([fragment])
                        byClip[fragment.clipID, default: []].append(fragmentPlacement)
                    }
                }
            }
            replacementsByClip = byClip
            groupReplacements = group
        }

        func sourceChanged(_ id: String, comparedWith other: Self) -> Bool { sources[id] != other.sources[id] }

        func asset(_ id: String?) -> StillAsset? { id.flatMap { assets[$0] } }

        struct Replacement: Equatable {
            let placement: StillReplacement
            let asset: StillAsset?
        }

        func replacementContents(for item: TimelineOccurrence) -> [Replacement] {
            guard let input = item.input else { return [] }
            let placements = item.id.map { replacementsByClip[$0] ?? [] } ?? groupReplacements.compactMap { range, placement in
                let from = max(range.from, input.from)
                let to = min(range.to, input.to)
                guard from < to else { return nil }
                var fragment = placement
                fragment.coverage = .group(MulticamRange(from: from, to: to))
                return fragment
            }
            return placements.map { Replacement(placement: $0, asset: assets[$0.assetID]) }
        }

        struct Switch: Equatable {
            let at: RationalTime
            let angle: String
            let audio: MulticamAudioSelection?
        }

        func switches(in range: MulticamRange) -> [Switch] {
            // The initial active routing is the last switch at or before the start.
            func precedingOrAt(_ time: RationalTime) -> Int {
                var low = 0, high = switches.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if switches[middle].at <= time { low = middle + 1 }
                    else { high = middle }
                }
                return low - 1
            }
            let start = max(0, precedingOrAt(range.from))
            return switches.dropFirst(start).prefix(while: { $0.at < range.to }).reduce(into: []) { values, item in
                if values.last?.angle == item.angle && values.last?.audio == item.audio { return }
                values.append(Switch(at: max(item.at, range.from), angle: item.angle, audio: item.audio))
            }
        }
    }
}
