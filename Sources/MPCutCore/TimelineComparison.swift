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
    public private(set) var participantChanges: [ParticipantChange]
    public private(set) var nextOffset: Int?

    package func page(offset: Int, limit: Int) -> Self {
        var result = self
        let count = changes.count + participantChanges.count
        let start = min(count, offset)
        let end = start + min(count - start, limit)
        result.changes = Array(changes[min(changes.count, start)..<min(changes.count, end)])
        result.participantChanges = Array(participantChanges[max(0, start - changes.count)..<max(0, end - changes.count)])
        result.nextOffset = end < count ? end : nil
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case beforeClock = "before_clock", afterClock = "after_clock"
        case beforeDuration = "before_duration", afterDuration = "after_duration"
        case projectFields = "project_fields", changes, nextOffset = "next_offset"
        case participantChanges = "participant_changes"
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(beforeClock, forKey: .beforeClock)
        try fields.encode(afterClock, forKey: .afterClock)
        try fields.encode(beforeDuration.description, forKey: .beforeDuration)
        try fields.encode(afterDuration.description, forKey: .afterDuration)
        try fields.encode(projectFields, forKey: .projectFields)
        try fields.encode(changes, forKey: .changes)
        try fields.encode(participantChanges, forKey: .participantChanges)
        try fields.encodeIfPresent(nextOffset, forKey: .nextOffset)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(beforeClock: fields.decode(TimelineClock.self, forKey: .beforeClock),
                      afterClock: fields.decode(TimelineClock.self, forKey: .afterClock),
                      beforeDuration: ProjectField.time(fields, .beforeDuration),
                      afterDuration: ProjectField.time(fields, .afterDuration),
                      projectFields: fields.decode([String].self, forKey: .projectFields),
                      changes: fields.decode([Change].self, forKey: .changes),
                      participantChanges: fields.decodeIfPresent([ParticipantChange].self, forKey: .participantChanges) ?? [])
        nextOffset = try fields.decodeIfPresent(Int.self, forKey: .nextOffset)
    }

    private init(beforeClock: TimelineClock, afterClock: TimelineClock, beforeDuration: RationalTime,
                 afterDuration: RationalTime, projectFields: [String], changes: [Change],
                 participantChanges: [ParticipantChange]) {
        self.beforeClock = beforeClock
        self.afterClock = afterClock
        self.beforeDuration = beforeDuration
        self.afterDuration = afterDuration
        self.projectFields = projectFields
        self.changes = changes
        self.participantChanges = participantChanges
    }

    public static func compare(from before: CutProject, to after: CutProject) throws -> Self {
        let previous = try before.timelineOccurrences()
        let current = try after.timelineOccurrences()
        let oldContents = Contents(before), newContents = Contents(after)
        let participant = try TimelineParticipantComparison(before.participants, after.participants)
        let participantFields = Set(participant.rows.map(\.category))
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
        let treatmentChanged = before.participants.effectiveRedactions != after.participants.effectiveRedactions
        if treatmentChanged { projectFields.append("feed_treatments") }
        projectFields += participantFields.map(\.rawValue).sorted()
        if before.participants.tileOutput != after.participants.tileOutput { projectFields.append("tile_output") }
        let groupLayoutsChanged = oldContents.groupLayouts != newContents.groupLayouts
        if groupLayoutsChanged { projectFields.append("group_tile_layouts") }
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
            if old.speakerAngles != new.speakerAngles { projectFields.append("speaker_angles") }
        }
        projectFields += groupChanges

        // Match authored IDs first. A legacy group occurrence can acquire an ID
        // when its first override is authored, so fall back to its range.
        let currentIDs = Set(current.compactMap(Identity.init))
        var oldIndices: [Identity: [Int]] = [:]
        for item in previous.reversed() {
            try Task.checkCancellation()
            if let key = Identity(item) {
                oldIndices[key, default: []].append(item.index)
                if case .groupID = key, !currentIDs.contains(key), let range = item.input {
                    oldIndices[.group(range), default: []].append(item.index)
                }
            }
        }
        let groupMetadataChanges = groupChanges.filter { $0 != "switches" }
        let compareSwitches = groupChanges.contains("switches")
        var groupSwitchChanges: [MulticamRange: Bool] = [:]
        var matched = Set<Int>()
        var changes: [Change] = []
        for item in current {
            try Task.checkCancellation()
            guard sameClock, let key = Identity(item) else {
                changes.append(Change(kind: .added, before: nil, after: item, fields: []))
                continue
            }
            var oldIndex = oldIndices[key]?.popLast()
            if oldIndex == nil, case .groupID = key, let range = item.input {
                oldIndex = oldIndices[.group(range)]?.popLast()
            }
            guard let index = oldIndex else {
                changes.append(Change(kind: .added, before: nil, after: item, fields: []))
                continue
            }
            matched.insert(index)
            let old = previous[index]
            var fields: [String] = []
            if old.index != item.index { fields.append("order") }
            if old.output != item.output { fields.append("output_range") }
            if old.input != item.input { fields.append("input_range") }
            if let id = item.id, !key.isGroup {
                if oldContents.sourceChanged(id, comparedWith: newContents) { fields.append("source") }
                if oldContents.cards[id] != newContents.cards[id] { fields.append("still") }
            }
            if oldContents.tileLayouts(for: old) != newContents.tileLayouts(for: item) { fields.append("tile_layouts") }
            if treatmentChanged, item.input != nil { fields.append("feed_treatments") }
            if !participantFields.isEmpty {
                let oldCategories = try oldContents.participantCategories(for: old, comparison: participant, after: false)
                let newCategories = try newContents.participantCategories(for: item, comparison: participant, after: true)
                fields += oldCategories.union(newCategories).map(\.rawValue).sorted()
            }
            if oldContents.asset(old.assetID) != newContents.asset(item.assetID) { fields.append("still_asset") }
            if oldContents.replacementContents(for: old) != newContents.replacementContents(for: item) {
                fields.append("picture_replacement")
            }
            if key.isGroup {
                if old.id != item.id { fields.append("occurrence_id") }
                if old.angleOverride != item.angleOverride { fields.append("angle_override") }
                fields += groupMetadataChanges
                if groupLayoutsChanged, oldContents.groupLayouts(in: old.input) != newContents.groupLayouts(in: item.input) {
                    fields.append("group_tile_layouts")
                }
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
                    projectFields: projectFields, changes: changes, participantChanges: participant.rows)
    }

    private enum Identity: Hashable {
        case clip(String), still(String), group(MulticamRange), groupID(String)

        init?(_ item: TimelineOccurrence) {
            if item.file == nil, let input = item.input {
                self = item.id.map(Self.groupID) ?? .group(input)
            } else if let id = item.id {
                self = item.assetID != nil ? .still(id) : .clip(id)
            } else {
                return nil
            }
        }

        var isGroup: Bool {
            switch self {
            case .group, .groupID: return true
            case .clip, .still: return false
            }
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
        let groupLayouts: [TileLayoutSpan]
        private let assembly: [StillAssemblyItem]
        private let clipLayouts: [String: [TileLayoutSpan]]
        private let recordingsByID: [String: MulticamSource]
        private let recordingsByAngle: [String: [MulticamSource]]
        private let usesLegacyRender: Bool
        private let legacyShots: [ParticipantTimedShot.Scope: [ParticipantTimedShot]]
        private let defaultShot: ParticipantShot
        private let omittedFeeds: Set<String>

        init(_ project: CutProject) {
            let sourceClips: [CutSequenceClip]
            let stillCards: [StillInsert]
            let participants = project.participants
            let render = participants.tileOutput == nil ? participants.render : nil
            usesLegacyRender = render != nil
            legacyShots = ParticipantTimedShot.index(render?.shots ?? [])
            defaultShot = render?.shots.first { $0.range == nil } ?? .init(layout: .original)
            omittedFeeds = Set(participants.effectiveRedactions.filter { $0.treatment == .omit }.map(\.participantID))
            switch project {
            case .sequence(let clips):
                sourceClips = clips
                stillCards = []
                switches = []
                groupLayouts = []
                recordingsByID = [:]
                recordingsByAngle = [:]
                assembly = []
            case .stillSequence(let sequence):
                sourceClips = sequence.items.compactMap(\.source)
                stillCards = sequence.items.compactMap(\.still)
                switches = []
                groupLayouts = []
                recordingsByID = [:]
                recordingsByAngle = [:]
                assembly = []
            case .multicam(let multicam):
                sourceClips = []
                stillCards = multicam.assemblyItems?.compactMap(\.still) ?? []
                switches = multicam.switches
                groupLayouts = multicam.groupTileLayouts
                recordingsByID = Dictionary(multicam.pictureSources.map { ($0.id, $0) },
                                            uniquingKeysWith: { first, _ in first })
                recordingsByAngle = Dictionary(multicam.angles.map { ($0.id, $0.recordings) },
                                               uniquingKeysWith: { first, _ in first })
                assembly = multicam.assemblyItems ?? []
            }
            sources = Dictionary(sourceClips.map { ($0.id, Source($0)) }, uniquingKeysWith: { first, _ in first })
            clipLayouts = Dictionary(sourceClips.map { ($0.id, $0.tileLayouts) }, uniquingKeysWith: { first, _ in first })
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

        func groupLayouts(in range: MulticamRange?) -> [TileLayoutSpan] {
            guard let range else { return [] }
            return groupLayouts.compactMap { $0.limited(from: range.from, to: range.to) }
        }

        func tileLayouts(for item: TimelineOccurrence) -> [TileLayoutSpan] {
            guard let input = item.input else { return [] }
            let layouts: [TileLayoutSpan] = if item.file != nil, let id = item.id {
                clipLayouts[id] ?? []
            } else if assembly.indices.contains(item.index) {
                assembly[item.index].tileLayouts
            } else {
                []
            }
            return layouts.compactMap { $0.limited(from: input.from, to: input.to) }
        }

        func participantCategories(for item: TimelineOccurrence, comparison: TimelineParticipantComparison,
                                   after: Bool) throws -> Set<ParticipantChange.Category> {
            guard let input = item.input else { return [] }
            if let file = item.file { return comparison.categories(in: input, source: file, after: after) }

            var fields: Set<ParticipantChange.Category> = []
            func add(_ sources: [MulticamSource], in interval: MulticamRange) throws {
                for source in sources {
                    let extent = source.coverage ?? MulticamRange(from: source.offset, to: interval.to)
                    guard let overlap = interval.participantIntersection(extent) else { continue }
                    let physical = source.feedAngle.flatMap { recordingsByID[$0.sourceID] } ?? source
                    let range = try MulticamRange(from: overlap.from.subtracting(physical.offset),
                                                  to: overlap.to.subtracting(physical.offset))
                    fields.formUnion(comparison.categories(in: range, source: physical.id, after: after))
                }
            }

            func addBase(in range: MulticamRange) throws {
                if let angle = item.angleOverride {
                    try add(recordingsByAngle[angle] ?? [], in: range)
                    return
                }
                let start = max(0, switches.lowerBound { $0.at > range.from } - 1)
                for index in switches.indices.dropFirst(start) {
                    guard switches[index].at < range.to else { break }
                    let next = index + 1 < switches.count ? switches[index + 1].at : range.to
                    let interval = MulticamRange(from: max(switches[index].at, range.from), to: min(next, range.to))
                    try add(recordingsByAngle[switches[index].angle] ?? [], in: interval)
                    if next >= range.to { break }
                }
            }

            let groupShots = Array((legacyShots[.init(clock: .group)] ?? []).overlapping(input))
            let outputShots = Array((legacyShots[.init(clock: .output)] ?? []).overlapping(item.output))
            let occurrenceShots = Array((legacyShots[.init(clock: .output, occurrence: item.index)] ?? []).overlapping(item.output))
            let clipLayouts = usesLegacyRender ? [] : tileLayouts(for: item).sorted { $0.range.from < $1.range.from }
            let sharedLayouts = usesLegacyRender ? [] : groupLayouts(in: input).sorted { $0.range.from < $1.range.from }
            let hasLayoutOverrides = !clipLayouts.isEmpty || !sharedLayouts.isEmpty || !groupShots.isEmpty
                || !outputShots.isEmpty || !occurrenceShots.isEmpty || defaultShot.layout != .original
            guard hasLayoutOverrides else {
                try addBase(in: input)
                return fields
            }

            let displacement = try input.from.subtracting(item.output.from)
            var points = Set([input.from, input.to])
            let groupRanges = clipLayouts.map(\.range) + sharedLayouts.map(\.range) + groupShots.map(\.range)
            for range in groupRanges {
                if let overlap = range.participantIntersection(input) { points.formUnion([overlap.from, overlap.to]) }
            }
            for shot in outputShots + occurrenceShots {
                if let overlap = shot.range.participantIntersection(item.output) {
                    let range = try overlap.participantShifted(by: displacement)
                    points.formUnion([range.from, range.to])
                }
            }
            let boundaries = points.sorted()
            for (from, to) in zip(boundaries, boundaries.dropFirst()) {
                try Task.checkCancellation()
                let range = MulticamRange(from: from, to: to)
                let outputTime = try from.subtracting(displacement)
                func activeLayout(_ layouts: [TileLayoutSpan]) -> TileLayoutSpan? {
                    let index = layouts.lowerBound { $0.range.to > from }
                    guard layouts.indices.contains(index), layouts[index].range.contains(from) else { return nil }
                    return layouts[index]
                }
                let nativeLayout = activeLayout(clipLayouts) ?? activeLayout(sharedLayouts)
                let shot = nativeLayout?.shot(range: range)
                    ?? occurrenceShots.shot(at: outputTime)
                    ?? outputShots.shot(at: outputTime)
                    ?? groupShots.shot(at: from)
                    ?? defaultShot
                let slots = shot.slots.filter { $0.target != .participant || !omittedFeeds.contains($0.id) }
                if shot.layout == .original || shot.layout == .arranged
                    || slots.contains(where: { $0.target == .participant || $0.target == .presentation }) {
                    try addBase(in: range)
                }
                for id in Set(slots.filter { $0.target == .camera }.map(\.id)) {
                    try add(recordingsByAngle[id] ?? [], in: range)
                }
            }
            return fields
        }

        func sourceChanged(_ id: String, comparedWith other: Self) -> Bool { sources[id] != other.sources[id] }

        func asset(_ id: String?) -> StillAsset? { id.flatMap { assets[$0] } }

        struct Replacement: Equatable {
            let placement: StillReplacement
            let asset: StillAsset?
        }

        func replacementContents(for item: TimelineOccurrence) -> [Replacement] {
            guard let input = item.input else { return [] }
            if item.file != nil, let id = item.id {
                return (replacementsByClip[id] ?? []).map { Replacement(placement: $0, asset: assets[$0.assetID]) }
            }
            let placements = groupReplacements.compactMap { range, placement -> StillReplacement? in
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
