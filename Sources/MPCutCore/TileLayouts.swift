import Foundation

public struct ParticipantFeedTreatment: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case blur, cover, remove }

    public var mode: Mode
    public var color: UInt32

    public init(mode: Mode, color: UInt32 = 0) {
        self.mode = mode
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case mode, color }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try fields.decode(Mode.self, forKey: .mode),
                  color: try fields.decodeIfPresent(UInt32.self, forKey: .color) ?? 0)
    }

    init(_ redaction: ParticipantRedaction) {
        let mode: Mode
        switch redaction.treatment {
        case .blur: mode = .blur
        case .opaque: mode = .cover
        case .omit: mode = .remove
        }
        self.init(mode: mode, color: redaction.color)
    }

    func redaction(for id: String) -> ParticipantRedaction {
        let treatment: ParticipantMaskTreatment
        switch mode {
        case .blur: treatment = .blur
        case .cover: treatment = .opaque
        case .remove: treatment = .omit
        }
        return .init(participantID: id, treatment: treatment, color: color)
    }
}

public struct TileOutputSettings: Codable, Equatable, Sendable {
    public var canvas: ParticipantCanvas
    public var audio: ParticipantRenderAudio
    public var unresolvedPrivacy: ParticipantUnresolvedPrivacy

    private enum CodingKeys: String, CodingKey {
        case canvas, audio
        case unresolvedPrivacy = "unresolved_privacy"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(canvas: try fields.decode(ParticipantCanvas.self, forKey: .canvas),
                  audio: try fields.decode(ParticipantRenderAudio.self, forKey: .audio),
                  unresolvedPrivacy: try fields.decode(ParticipantUnresolvedPrivacy.self, forKey: .unresolvedPrivacy))
    }

    public init(canvas: ParticipantCanvas = .init(), audio: ParticipantRenderAudio = .init(mode: .program),
                unresolvedPrivacy: ParticipantUnresolvedPrivacy = .stop) {
        self.canvas = canvas
        self.audio = audio
        self.unresolvedPrivacy = unresolvedPrivacy
    }
}

public enum TileLayoutScope: Equatable, Sendable {
    case clip(String)
    case group
    case occurrence(String)
}

public struct TileLayoutListing: Encodable, Sendable {
    public let clipID: String?
    public let occurrenceID: String?
    public let sourceID: String?
    public let clock: String
    public let range: MulticamRange
    public internal(set) var layouts: [TileLayoutSpan]

    private enum CodingKeys: String, CodingKey {
        case clipID = "clip_id", occurrenceID = "occurrence_id", sourceID = "source_id", clock, range, layouts
    }
}

extension CutProject {
    /// Authored scopes in timeline order, including scopes with no layout override.
    public var tileLayoutListings: [TileLayoutListing] {
        if case .multicam(let project) = self {
            let items = project.assemblyItems ?? [.group(project.range)]
            let group = TileLayoutListing(clipID: nil, occurrenceID: nil, sourceID: nil, clock: "group",
                                          range: project.range, layouts: project.groupTileLayouts)
            let ids = project.tileOccurrenceIDs
            return [group] + items.indices.compactMap { index in
                let item = items[index]
                guard let range = item.group, let id = ids[index] else { return nil }
                return .init(clipID: nil, occurrenceID: id, sourceID: nil, clock: "group", range: range,
                             layouts: item.tileLayouts)
            }
        }
        return (sequenceClips ?? []).map { clip in
            .init(clipID: clip.id, occurrenceID: nil, sourceID: clip.file, clock: "source",
                  range: .init(from: clip.from, to: clip.to), layouts: clip.tileLayouts)
        }
    }
}

/// Layout coverage is half-open in the source clock of a clip or the group clock of multicam footage.
public struct TileLayoutSpan: Codable, Equatable, Hashable, Sendable {
    public var range: MulticamRange
    public var layout: ParticipantShotLayout
    public var slots: [ParticipantSlot]
    public var compact: Bool

    public init(range: MulticamRange, layout: ParticipantShotLayout, slots: [ParticipantSlot] = [],
                compact: Bool = false) {
        self.range = range
        self.layout = layout
        self.slots = slots
        self.compact = compact
    }

    private enum CodingKeys: String, CodingKey { case range, layout, slots, compact }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_tile_layout")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(range: try fields.decode(MulticamRange.self, forKey: .range),
                  layout: try fields.decode(ParticipantShotLayout.self, forKey: .layout),
                  slots: try fields.decodeIfPresent([ParticipantSlot].self, forKey: .slots) ?? [],
                  compact: try fields.decodeIfPresent(Bool.self, forKey: .compact) ?? false)
    }

    package func limited(from: RationalTime?, to: RationalTime?) -> Self? {
        var result = self
        result.range.from = max(range.from, from ?? range.from)
        result.range.to = min(range.to, to ?? range.to)
        return result.range.from < result.range.to ? result : nil
    }

    func shot(range: MulticamRange, clock: ParticipantShotClock = .output, occurrence: Int? = nil) -> ParticipantShot {
        .init(range: range, clock: clock, occurrence: occurrence, layout: layout, slots: slots, compact: compact)
    }

    static func replacing(_ spans: [Self], in range: MulticamRange, with layout: Self?) -> [Self] {
        var result = spans.flatMap { span in
            [span.limited(from: nil, to: range.from), span.limited(from: range.to, to: nil)].compactMap { $0 }
        }
        if var layout {
            layout.range = range
            result.append(layout)
        }
        var coalesced: [Self] = []
        for span in result.sorted(by: { $0.range.from < $1.range.from }) {
            if let last = coalesced.last, last.range.to == span.range.from,
               last.layout == span.layout, last.slots == span.slots, last.compact == span.compact {
                coalesced[coalesced.count - 1].range.to = span.range.to
            } else {
                coalesced.append(span)
            }
        }
        return coalesced
    }

    static func replacing(_ spans: [Self], in range: MulticamRange, with layouts: [Self]) -> [Self] {
        (replacing(spans, in: range, with: nil) + layouts).sorted { $0.range.from < $1.range.from }
    }

    static func validate(_ spans: [Self], minTime: RationalTime? = nil,
                         roster: Set<String>? = nil, cameras: Set<String>? = nil) throws {
        guard !spans.isEmpty else { return }
        let sorted = spans.sorted { $0.range.from < $1.range.from }
        guard sorted.allSatisfy({ $0.range.from >= (minTime ?? $0.range.from) }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.range.to <= $1.range.from }) else {
            throw invalidTileLayout("Tile layouts must be nonoverlapping and within their clock.")
        }
        let shots = sorted.map { $0.shot(range: $0.range, clock: .group) }
        try ParticipantRenderPlan(shots: [.init(layout: .original)] + shots).validate(allowNativeLayouts: true)
        for slot in spans.flatMap(\.slots) {
            let known: Bool
            switch slot.target {
            case .participant: known = roster?.contains(slot.id) ?? true
            case .camera: known = cameras?.contains(slot.id) ?? true
            case .presentation, .empty: known = true
            }
            guard known else { throw invalidTileLayout("Unknown feed or camera ‘\(slot.id)’.") }
        }
    }
}

private func invalidTileLayout(_ message: String) -> CutError {
    .init(code: "invalid_tile_layout", message: message)
}

extension ParticipantProject {
    public var hasEffectiveTreatments: Bool { !effectiveRedactions.isEmpty }

    public var effectiveRedactions: [ParticipantRedaction] {
        let native = people.compactMap { person in person.treatment?.redaction(for: person.id) }
        guard tileOutput == nil, let legacy = render?.redactions else { return native }
        let nativeIDs = Set(native.map(\.participantID))
        return native + legacy.filter { !nativeIDs.contains($0.participantID) }
    }
}

extension MulticamProject {
    /// Older assemblies have no stored ID until an override is authored.
    package var tileOccurrenceIDs: [String?] {
        let items = assemblyItems ?? [.group(range)]
        let stored = Set(items.compactMap(\.occurrenceID))
        return items.enumerated().map { index, item in
            guard item.group != nil else { return nil }
            if let id = item.occurrenceID { return id }
            var id = "assembly-\(index + 1)"
            while stored.contains(id) { id += "-" }
            return id
        }
    }

    public func tileOccurrenceID(at index: Int) -> String? {
        let items = assemblyItems ?? [.group(range)]
        guard items.indices.contains(index), items[index].group != nil else { return nil }
        return items[index].occurrenceID ?? tileOccurrenceIDs[index]
    }

    func validateTileLayouts() throws {
        let roster = Set(participants.people.map(\.id))
        let cameras = Set(angles.map(\.id))
        try TileLayoutSpan.validate(groupTileLayouts, roster: roster, cameras: cameras)
        var ids: Set<String> = []
        for item in assemblyItems ?? [] {
            if let id = item.occurrenceID {
                guard validStillID(id), ids.insert(id).inserted else {
                    throw invalidTileLayout("Assembly occurrence IDs must be unique.")
                }
            } else if !item.tileLayouts.isEmpty {
                throw invalidTileLayout("An assembly occurrence with tile layouts needs an ID.")
            }
            try TileLayoutSpan.validate(item.tileLayouts, roster: roster, cameras: cameras)
        }
    }
}

extension CutProject {
    var usesTilesFormat: Bool {
        if participants.tileOutput != nil || participants.people.contains(where: { $0.treatment != nil || $0.legacyPresentation != nil })
            || participants.sources.contains(where: {
                if case .gallery = $0.feedLayout { return true }
                return $0.countHints != nil || !$0.scanEvents.isEmpty || $0.confirmations != nil
                    || $0.historicalParticipantIDs != nil || $0.layoutCapacityRanges != nil || $0.appearances.contains { tile in
                        (tile.state == .presentation && tile.participantID != nil) || tile.detectedBounds != nil
                            || tile.reviewedIdentity != nil || tile.reviewedPresentation != nil
                    }
            }) {
            return true
        }
        switch self {
        case .sequence, .stillSequence: return sequenceClips?.contains { !$0.tileLayouts.isEmpty } ?? false
        case .multicam(let project):
            return !project.groupTileLayouts.isEmpty || project.assemblyItems?.contains { $0.occurrenceID != nil } == true
                || project.angles.contains { $0.feedAngle != nil } || !project.speakerAngles.isEmpty
        }
    }

    public var requiresPictureProcessing: Bool {
        if participants.render != nil || participants.tileOutput != nil || participants.hasEffectiveTreatments { return true }
        switch self {
        case .sequence, .stillSequence: return sequenceClips?.contains { !$0.tileLayouts.isEmpty } ?? false
        case .multicam(let project):
            return !project.groupTileLayouts.isEmpty || project.assemblyItems?.contains { !$0.tileLayouts.isEmpty } == true
                || project.angles.contains { $0.feedAngle != nil }
        }
    }

    public func settingFeedTreatment(feedID: String, treatment: ParticipantFeedTreatment?) throws -> Self {
        var result = try migratingLegacyTiles()
        guard let index = result.participants.people.firstIndex(where: { $0.id == feedID }) else {
            throw invalidParticipantProject("Unknown feed ‘\(feedID)’.")
        }
        var metadata = result.participants
        if metadata.people[index].treatment != treatment {
            for index in metadata.sources.indices {
                guard let reviewed = metadata.sources[index].confirmations else { continue }
                let remaining = reviewed.filter { $0.participantID != feedID }
                metadata.sources[index].confirmations = remaining.isEmpty ? nil : remaining
            }
        }
        metadata.people[index].treatment = treatment
        result.participants = metadata
        try result.validate()
        return result
    }

    public func settingTileLayout(scope: TileLayoutScope, range: MulticamRange, layout: TileLayoutSpan?,
                                  relativeTo document: URL? = nil) throws -> Self {
        guard range.from < range.to else { throw invalidTileLayout("Choose a nonempty layout range.") }
        var layout = layout
        layout?.range = range
        let base = try migratingLegacyTiles()
        return try base.editingStills(sequence: { project in
            guard case .clip(let id) = scope, let index = project.items.firstIndex(where: { $0.source?.id == id }),
                  var clip = project.items[index].source else { throw invalidTileLayout("Choose a source clip.") }
            guard clip.from <= range.from, range.to <= clip.to else {
                throw invalidTileLayout("Choose a layout range inside the clip.")
            }
            if let layout {
                try TileLayoutSpan.validate([layout], roster: Set(project.participants.people.map(\.id)), cameras: [clip.file])
            }
            let spans = try layout.map {
                try project.participants.arrangedSpans($0, sourceID: clip.file, sourceOffset: .zero)
            } ?? []
            clip.tileLayouts = TileLayoutSpan.replacing(clip.tileLayouts, in: range, with: spans.filter { $0.layout != .original })
            project.items[index] = .source(clip)
        }, multicam: { project in
            switch scope {
            case .clip: throw invalidTileLayout("Choose the multicam group or an assembly occurrence.")
            case .group:
                guard project.range.from <= range.from, range.to <= project.range.to else {
                    throw invalidTileLayout("Choose a layout range inside the group.")
                }
                let spans = try project.epochSpans(layout, angle: nil, document: document)
                project.groupTileLayouts = TileLayoutSpan.replacing(project.groupTileLayouts, in: range,
                                                                    with: spans.filter { $0.layout != .original })
            case .occurrence(let id):
                var items = project.assemblyItems ?? [.group(project.range)]
                let index = project.tileOccurrenceIDs.firstIndex(of: id)
                guard let index,
                      let group = items[index].group, group.from <= range.from, range.to <= group.to else {
                    throw invalidTileLayout("Choose a layout range inside an assembly occurrence.")
                }
                let item = items[index]
                let spans = try project.epochSpans(layout, angle: item.angleOverride, document: document)
                let layouts = TileLayoutSpan.replacing(item.tileLayouts, in: range, with: spans)
                guard item.tileLayouts != layouts else { return }
                items[index] = .group(group, angle: item.angleOverride,
                                      id: id, layouts: layouts)
                if project.assemblyItems == nil {
                    project.replaceAssembly(items, carryingPauseReviewsFrom: [index])
                } else {
                    project.assemblyItems = items
                }
            }
        })
    }

    public var legacyTileCanvasConflict: CutError? {
        guard let format = stillFormat, let legacy = participants.render else { return nil }
        let stored = participants.tileOutput?.canvas ?? legacy.canvas
        let rate = RationalTime(numerator: format.cadence.denominator, denominator: format.cadence.numerator)
        guard stored.width != format.width || stored.height != format.height || stored.frameRate != rate else { return nil }
        return CutError(code: "conflicting_project_output_format",
                        message: "The legacy layout canvas and still timeline specify different dimensions or frame rates. Set one output format before rendering.")
    }

    /// Output clock translation for render-plan clients. The stored ranges stay attached to their footage.
    public func tileRenderPlan() throws -> ParticipantRenderPlan? {
        guard requiresPictureProcessing else { return nil }
        if let conflict = legacyTileCanvasConflict { throw conflict }
        let settings = projectOutputSettings
        if participants.tileOutput == nil, let legacy = participants.render {
            var legacy = legacy
            legacy.redactions = participants.effectiveRedactions
            return legacy
        }
        var shots = [ParticipantShot(layout: .original)]
        var cursor = RationalTime.zero
        func append(_ spans: [TileLayoutSpan], in source: MulticamRange, occurrence: Int? = nil) throws {
            let shift = try cursor.subtracting(source.from)
            for span in spans {
                guard let visible = span.range.participantIntersection(source) else { continue }
                shots.append(try span.shot(range: visible.participantShifted(by: shift), occurrence: occurrence))
            }
            cursor = try cursor.adding(source.to.subtracting(source.from))
        }
        switch self {
        case .sequence, .stillSequence:
            for item in stillSequenceValue?.items ?? [] {
                if let clip = item.source {
                    try append(clip.tileLayouts, in: .init(from: clip.from, to: clip.to))
                } else if let still = item.still {
                    cursor = try cursor.adding(still.duration)
                }
            }
        case .multicam(let project):
            shots += project.groupTileLayouts.map { $0.shot(range: $0.range, clock: .group) }
            for (index, item) in (project.assemblyItems ?? [.group(project.range)]).enumerated() {
                if let group = item.group {
                    try append(item.tileLayouts, in: group, occurrence: index)
                } else if let still = item.still {
                    cursor = try cursor.adding(still.duration)
                }
            }
        }
        return .init(canvas: settings.canvas, shots: shots, audio: settings.audio,
                     redactions: participants.effectiveRedactions, unresolvedPrivacy: settings.unresolvedPrivacy)
    }
}

extension CutProject {
    /// Convert old shots once the original clock and occurrence order are still available.
    public func migratingLegacyTiles() throws -> Self {
        var updated = self
        if !usesTilesFormat {
            updated.participants = participants.promotingLegacyPresentations()
        }
        return try updated.migratingLegacyRenderPlan()
    }

    private func migratingLegacyRenderPlan() throws -> Self {
        guard let legacy = participants.render, participants.tileOutput == nil else { return self }
        try legacy.validate()
        let index = ParticipantTimedShot.index(legacy.shots)
        let shared = index[.init(clock: .output)] ?? []
        let groupShots = index[.init(clock: .group)] ?? []
        let defaultShot = legacy.shots.first { $0.range == nil }!
        var metadata = participants
        let treatments = Dictionary(uniqueKeysWithValues: legacy.redactions.map { ($0.participantID, ParticipantFeedTreatment($0)) })
        for i in metadata.people.indices where metadata.people[i].treatment == nil {
            metadata.people[i].treatment = treatments[metadata.people[i].id]
        }
        metadata.tileOutput = .init(canvas: legacy.canvas, audio: legacy.audio, unresolvedPrivacy: legacy.unresolvedPrivacy)

        var cursor = RationalTime.zero
        func spans(in source: MulticamRange, occurrence: Int, default shot: ParticipantShot?,
                   underlyingGroup: Bool) throws -> [TileLayoutSpan] {
            let output = try MulticamRange(from: cursor, to: cursor.adding(source.to.subtracting(source.from)))
            let shift = try source.from.subtracting(output.from)
            cursor = output.to
            var layouts: [TileLayoutSpan] = []
            if let shot, shot.layout != .original {
                layouts.append(.init(range: source, layout: shot.layout, slots: shot.slots, compact: shot.compact))
            }
            for list in [shared, index[.init(clock: .output, occurrence: occurrence)] ?? []] {
                for item in list.overlapping(output) {
                    guard let overlap = item.range.participantIntersection(output) else { continue }
                    let range = try overlap.participantShifted(by: shift)
                    let shot = item.shot
                    let span = TileLayoutSpan(range: range, layout: shot.layout, slots: shot.slots, compact: shot.compact)
                    layouts = TileLayoutSpan.replacing(layouts, in: range,
                                                       with: shot.layout == .original && !underlyingGroup ? nil : span)
                }
            }
            return layouts
        }

        let result = try editingStills(sequence: { sequence in
            sequence.participants = metadata
            for i in sequence.items.indices {
                guard var clip = sequence.items[i].source else {
                    if let insert = sequence.items[i].still { cursor = try cursor.adding(insert.duration) }
                    continue
                }
                // Preserve the old default on every occurrence that used it, including its
                // vacant cells. Clips added after migration have no authored layout.
                clip.tileLayouts = try spans(in: .init(from: clip.from, to: clip.to), occurrence: i,
                                             default: defaultShot, underlyingGroup: false)
                sequence.items[i] = .source(clip)
            }
        }, multicam: { multicam in
            multicam.participants = metadata
            if defaultShot.layout != .original {
                multicam.groupTileLayouts = [.init(range: multicam.range, layout: defaultShot.layout,
                                                   slots: defaultShot.slots, compact: defaultShot.compact)]
            }
            for shot in groupShots {
                let span = TileLayoutSpan(range: shot.range, layout: shot.shot.layout, slots: shot.shot.slots,
                                          compact: shot.shot.compact)
                multicam.groupTileLayouts = TileLayoutSpan.replacing(multicam.groupTileLayouts, in: span.range,
                                                                     with: span.layout == .original ? nil : span)
            }
            if !shared.isEmpty || index.keys.contains(where: { $0.occurrence != nil }) {
                let items = multicam.assemblyItems ?? [.group(multicam.range)]
                let ids = multicam.tileOccurrenceIDs
                let revised = try items.enumerated().map { i, item in
                    guard let group = item.group else {
                        if let still = item.still { cursor = try cursor.adding(still.duration) }
                        return item
                    }
                    let layouts = try spans(in: group, occurrence: i, default: nil, underlyingGroup: true)
                    guard !layouts.isEmpty else { return item }
                    return .group(group, angle: item.angleOverride, id: ids[i], layouts: layouts)
                }
                if revised != items { multicam.assemblyItems = revised }
            }
        })
        return result
    }

    /// Reset only the picture state expressible by the legacy composition commands.
    public func removingTilePictureEdits() throws -> Self {
        var metadata = participants
        metadata.render = nil
        metadata.tileOutput = nil
        for i in metadata.people.indices { metadata.people[i].treatment = nil }
        return try editingStills(sequence: { sequence in
            sequence.participants = metadata
            for i in sequence.items.indices {
                guard var clip = sequence.items[i].source else { continue }
                clip.tileLayouts = []
                sequence.items[i] = .source(clip)
            }
        }, multicam: { multicam in
            multicam.participants = metadata
            multicam.groupTileLayouts = []
            multicam.assemblyItems = multicam.assemblyItems?.map { item in
                guard let range = item.group else { return item }
                return .group(range, angle: item.angleOverride, id: item.occurrenceID)
            }
        })
    }
}
