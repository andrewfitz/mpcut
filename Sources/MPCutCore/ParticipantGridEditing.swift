import Foundation

public struct ParticipantGridCorrection: Encodable, Equatable, Sendable {
    public let sourceID: String
    public let range: MulticamRange
    public let columns: Int
    public let rows: Int
    public let retainedAppearanceIDs: [String]
    public let unmatchedAppearanceIDs: [String]
    public let affectedParticipantIDs: [String]
    public let droppedPreferenceCount: Int

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", range, columns, rows
        case retainedAppearanceIDs = "retained_tile_ids", unmatchedAppearanceIDs = "unmatched_tile_ids"
        case affectedParticipantIDs = "affected_feed_ids", droppedPreferenceCount = "dropped_preference_count"
    }
}

extension ParticipantProject {
    public mutating func addAppearance(sourceID: String, appearance: ParticipantAppearance) throws {
        guard let index = sources.firstIndex(where: { $0.sourceID == sourceID }),
              appearance.range.from >= .zero,
              !sources[index].appearances.contains(where: { $0.id == appearance.id }) else {
            throw invalidParticipantProject("Select an accepted source, nonnegative time and an unused tile ID.")
        }
        var updated = self
        updated.sources[index].appearances.append(appearance)
        try updated.validate()
        self = updated
    }

    /// Corrects geometry without guessing identities where more than one old box maps to a cell.
    public mutating func correctGrid(sourceID: String, range: MulticamRange, columns: Int, rows: Int,
                                     cancelled: () -> Bool = { false }) throws -> ParticipantGridCorrection {
        guard (1...64).contains(columns), (1...64).contains(rows), columns * rows <= 64,
              range.from >= .zero, range.from < range.to,
              let sourceIndex = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Select an accepted source, a nonempty interval and a grid of one to 64 cells.")
        }
        let source = sources[sourceIndex]
        let corrected = source.appearances.filter { range.from < $0.range.to && $0.range.from < range.to }
        let boundaries = Set(corrected.flatMap {
            [max(range.from, $0.range.from), min(range.to, $0.range.to)]
        } + [range.from, range.to]).sorted()
        var output = source.appearances.flatMap { appearance -> [ParticipantAppearance] in
            Self.outside(range, keeping: appearance.range).map {
                var retained = appearance
                retained.range = $0
                return retained
            }
        }
        let cellIDs = (0..<(columns * rows)).map { _ in UUID().uuidString.lowercased() }
        var matches: [String: [MulticamRange]] = [:]
        var unmatched = Set<String>()
        var affected = Set<String>()
        var lastByID: [String: Int] = [:]
        let starting = Dictionary(grouping: corrected) { max(range.from, $0.range.from) }
        let ending = Dictionary(grouping: corrected) { min(range.to, $0.range.to) }
        var active: [String: ParticipantAppearance] = [:]
        for (from, to) in zip(boundaries, boundaries.dropFirst()) {
            if cancelled() { throw CancellationError() }
            for appearance in ending[from] ?? [] { active.removeValue(forKey: appearance.id) }
            for appearance in starting[from] ?? [] { active[appearance.id] = appearance }
            let interval = MulticamRange(from: from, to: to)
            let byCell = Dictionary(grouping: active.values) { box in
                let center = box.bounds.rect
                let column = min(columns - 1, Int(center.midX * Double(columns)))
                let row = min(rows - 1, Int(center.midY * Double(rows)))
                return row * columns + column
            }
            for cell in cellIDs.indices {
                let x = Double(cell % columns) / Double(columns)
                let y = Double(cell / columns) / Double(rows)
                let width = Double(cell % columns + 1) / Double(columns) - x
                let height = Double(cell / columns + 1) / Double(rows) - y
                let bounds = ParticipantBounds(x: x, y: y, width: width, height: height)
                let old = byCell[cell] ?? []
                let candidate = old.count == 1 ? old.first : nil
                // Large boxes spanning several cells are ambiguous even when their center falls in only one.
                let match = candidate.flatMap { box -> ParticipantAppearance? in
                    let intersection = box.bounds.rect.intersection(bounds.rect)
                    return intersection.width * intersection.height >= box.bounds.width * box.bounds.height * 0.75
                        ? box : nil
                }
                var new = ParticipantAppearance(id: match?.id ?? cellIDs[cell], participantID: match?.participantID,
                    range: interval, bounds: bounds, labelBounds: match?.labelBounds,
                    role: match?.role, state: match?.state ?? .unknown, slotID: match?.slotID)
                if let match {
                    new.detectedBounds = match.detectedBounds ?? (match.bounds == bounds ? nil : match.bounds)
                    new.reviewedIdentity = match.reviewedIdentity
                    new.reviewedPresentation = match.reviewedPresentation
                    if let participant = match.participantID, !bounds.rect.contains(match.bounds.rect) {
                        affected.insert(participant)
                    }
                    if let last = matches[match.id]?.last, last.to == from {
                        matches[match.id]?.removeLast()
                        matches[match.id, default: []].append(.init(from: last.from, to: to))
                    } else {
                        matches[match.id, default: []].append(interval)
                    }
                } else {
                    unmatched.formUnion(old.map(\.id))
                    affected.formUnion(old.compactMap(\.participantID))
                }
                if let index = lastByID[new.id], output[index].range.to == from {
                    var extended = output[index]
                    extended.range = interval
                    if extended == new {
                        output[index].range.to = to
                        continue
                    }
                }
                lastByID[new.id] = output.count
                output.append(new)
            }
        }
        var updated = self
        updated.sources[sourceIndex].appearances = output
        if let capacity = source.layoutCapacityRanges {
            let remaining = capacity.flatMap { Self.outside(range, keeping: $0) }
            updated.sources[sourceIndex].layoutCapacityRanges = remaining.isEmpty ? nil : remaining
        }
        updated.sources[sourceIndex].unresolvedParticipantIDs =
            Set(updated.sources[sourceIndex].unresolvedParticipantIDs).union(affected).sorted()
        var dropped = 0
        updated.appearanceOverrides = appearanceOverrides.flatMap { pin -> [ParticipantAppearanceOverride] in
            guard pin.sourceID == sourceID, range.from < pin.range.to, pin.range.from < range.to else { return [pin] }
            let within = MulticamRange(from: max(pin.range.from, range.from), to: min(pin.range.to, range.to))
            let keptWithin = (matches[pin.appearanceID] ?? []).compactMap { match -> MulticamRange? in
                let from = max(match.from, within.from)
                let to = min(match.to, within.to)
                return from < to ? .init(from: from, to: to) : nil
            }
            if keptWithin != [within] { dropped += 1 }
            return (Self.outside(range, keeping: pin.range) + keptWithin).map {
                var retained = pin
                retained.range = $0
                return retained
            }
        }
        // Preferences outside the interval can still refer to a track removed in its entirety.
        let remainingIDs = Set(output.map(\.id))
        updated.appearanceOverrides.removeAll {
            guard $0.sourceID == sourceID, !remainingIDs.contains($0.appearanceID) else { return false }
            dropped += 1
            return true
        }
        try updated.validate()
        self = updated
        return .init(sourceID: sourceID, range: range, columns: columns, rows: rows,
                     retainedAppearanceIDs: matches.keys.sorted(), unmatchedAppearanceIDs: unmatched.sorted(),
                     affectedParticipantIDs: affected.sorted(), droppedPreferenceCount: dropped)
    }

    private static func outside(_ removed: MulticamRange, keeping original: MulticamRange) -> [MulticamRange] {
        guard removed.from < original.to, original.from < removed.to else { return [original] }
        var pieces: [MulticamRange] = []
        if original.from < removed.from { pieces.append(.init(from: original.from, to: removed.from)) }
        if removed.to < original.to { pieces.append(.init(from: removed.to, to: original.to)) }
        return pieces
    }
}

extension CutProject {
    public mutating func correctTileGrid(sourceID: String, document: URL, range: MulticamRange,
                                         columns: Int, rows: Int, cancelled: () -> Bool = { false }) throws -> ParticipantGridCorrection {
        let media = try tileEditMedia(sourceID: sourceID, document: document, range: range)
        var updated = participants
        let report = try updated.correctGrid(sourceID: sourceID, range: range, columns: columns, rows: rows, cancelled: cancelled)
        if let index = updated.sources.firstIndex(where: { $0.sourceID == sourceID }), updated.sources[index].sourceStamp == nil {
            updated.sources[index].sourceStamp = SceneSourceStamp(media: media)
            updated.sources[index].sourceInode = media.identity.inode
        }
        participants = updated
        return report
    }

    /// Stamps a manually drawn source on first edit so that changed media cannot reuse its boxes.
    public mutating func addTileBox(sourceID: String, document: URL, appearance: ParticipantAppearance) throws {
        let media = try tileEditMedia(sourceID: sourceID, document: document, range: appearance.range)
        var updated = participants
        if !updated.sources.contains(where: { $0.sourceID == sourceID }) {
            updated.sources.append(.init(sourceID: sourceID, media: media))
        }
        try updated.addAppearance(sourceID: sourceID, appearance: appearance)
        try applyParticipantEdits(updated, relativeTo: document)
    }

    private func tileEditMedia(sourceID: String, document: URL, range: MulticamRange) throws -> MediaInfo {
        let file = try participantRecording(sourceID, relativeTo: document)
        let media = try CutEngine(tracks: .video).inspectSummary(file)
        guard media.hasVideo, range.to <= media.duration else {
            throw invalidParticipantProject("Choose a tile range inside the recording.")
        }
        guard !participants.needsReconciliation(sourceID: sourceID, identity: media.identity) else {
            throw invalidParticipantProject("Reconcile the changed recording before editing its tiles.")
        }
        return media
    }

}
