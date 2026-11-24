import Foundation

extension CutProject {
    /// Build the project view used by the original participants commands. The
    /// migration's saved shots are reusable only while they still reproduce
    /// the current layouts and treatment settings.
    package func legacyParticipantView(forRendering: Bool = false) throws -> Self {
        if case .multicam(let group) = self,
           group.angles.contains(where: { $0.feedAngle != nil }) || !group.speakerAngles.isEmpty {
            throw unsupportedLegacyParticipants("a live feed or speaker angle")
        }

        let layouts: [TileLayoutSpan]
        let hasClipLayouts: Bool
        switch self {
        case .sequence, .stillSequence:
            layouts = sequenceClips?.flatMap(\.tileLayouts) ?? []
            hasClipLayouts = !layouts.isEmpty
        case .multicam(let group):
            let occurrenceLayouts = (group.assemblyItems ?? []).flatMap(\.tileLayouts)
            hasClipLayouts = !occurrenceLayouts.isEmpty
            layouts = group.groupTileLayouts + occurrenceLayouts
        }
        if layouts.contains(where: { $0.layout == .arranged }) {
            throw unsupportedLegacyParticipants("an arranged layout")
        }
        if layouts.contains(where: { $0.layout == .grid && $0.slots.count > 4 }) {
            throw unsupportedLegacyParticipants("a grid with more than four cells")
        }

        let needsProjection = !layouts.isEmpty || participants.tileOutput != nil
            || participants.people.contains { $0.treatment != nil }
        let current = try tileRenderPlan()
        if usesTilesFormat, participants.sources.contains(where: { source in
            source.appearances.contains { $0.state == .presentation && $0.participantID == nil }
        }) {
            throw unsupportedLegacyParticipants("an unassigned screen-share tile")
        }
        let metadata = try participants.demotingLegacyPresentations(plan: current)
        var legacy = needsProjection ? try removingTilePictureEdits() : self
        // Legacy JSON identifies a share only by its tile. Keep its migrated feed
        // identity for picture processing so native unassigned tiles stay private.
        legacy.participants = forRendering ? participants : metadata
        guard needsProjection else { return legacy }
        legacy.participants.tileOutput = nil
        for index in legacy.participants.people.indices {
            legacy.participants.people[index].treatment = nil
        }
        if legacy.participants.render != nil,
           let reconstructed = try? legacy.migratingLegacyTiles(),
           (try? reconstructed.tileRenderPlan()) == current {
            return legacy
        }
        guard !hasClipLayouts, let plan = current, (try? plan.validate()) != nil else {
            throw unsupportedLegacyParticipants("a clip layout or treatment unavailable in the participants format")
        }
        legacy.participants.render = plan
        return legacy
    }

    package func applyingLegacyParticipantView(_ edited: Self, previous legacy: Self) throws -> Self {
        guard edited != legacy else { return self }
        if edited.participants.render == legacy.participants.render {
            // Roster and geometry edits can leave the stored picture and its
            // scope intact. Reproject only if the script actually edited shots,
            // treatments, or their settings.
            var result = self
            var metadata = edited.participants.promotingLegacyPresentations(preserving: participants)
            metadata.render = participants.render
            metadata.tileOutput = participants.tileOutput
            let treatments = Dictionary(uniqueKeysWithValues: participants.people.compactMap { person in
                person.treatment.map { (person.id, $0) }
            })
            for index in metadata.people.indices {
                metadata.people[index].treatment = treatments[metadata.people[index].id]
            }
            result.participants = metadata
            return try result.migratingLegacyTiles()
        }
        var result = edited
        result.participants = edited.participants.promotingLegacyPresentations(preserving: participants)
        return try result.migratingLegacyTiles()
    }
}

extension ParticipantProject {
    /// Preserve the wire shape that inspect and apply used before Tiles.
    package var legacyParticipantJSON: Self {
        var legacy = self
        for index in legacy.sources.indices {
            legacy.sources[index].appearances = legacy.sources[index].appearances.map(\.legacyJSON)
            legacy.sources[index].historicalParticipantIDs = nil
            legacy.sources[index].confirmations = nil
            legacy.sources[index].scanEvents = []
            legacy.sources[index].countHints = nil
            legacy.sources[index].layoutCapacityRanges = nil
        }
        return legacy
    }

    package func validateLegacyParticipantEdits() throws {
        if tileOutput != nil || people.contains(where: { $0.treatment != nil || $0.legacyPresentation != nil }) ||
            sources.contains(where: { source in
                source.historicalParticipantIDs != nil || source.confirmations != nil
                    || !source.scanEvents.isEmpty || source.countHints != nil || source.layoutCapacityRanges != nil
                    || source.appearances.contains { tile in
                        (tile.state == .presentation && tile.participantID != nil) || tile != tile.legacyJSON
                    }
            }) {
            throw unsupportedLegacyParticipants("native Tiles fields in the participant edits")
        }
        try render?.validate()
    }

    /// Preserve review evidence when a legacy script replaces the visible
    /// object. Geometry changes still invalidate confirmations.
    package func preservingTileReview(from previous: Self) -> Self {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.sources.map { ($0.sourceID, $0) })
        let roster = Set(people.map(\.id))
        var revised = self
        for index in revised.sources.indices {
            var source = revised.sources[index]
            guard let saved = previousByID[source.sourceID] else { continue }
            source.countHints = saved.countHints
            if saved.analysisIdentity == source.analysisIdentity,
               saved.sourceStamp == source.sourceStamp, saved.sourceInode == source.sourceInode,
               saved.sourceContentSHA256 == source.sourceContentSHA256, saved.feedLayout == source.feedLayout {
                source.scanEvents = saved.scanEvents
                source.layoutCapacityRanges = saved.layoutCapacityRanges
                let reviewed = Dictionary(saved.appearances.map { ($0.legacyJSON, $0) }, uniquingKeysWith: { first, _ in first })
                source.appearances = source.appearances.map { reviewed[$0] ?? $0 }
            }
            source.historicalParticipantIDs = saved.historicalParticipantIDs
            if saved.appearances != source.appearances {
                source.recordPrivacyHistory(previousAppearances: saved.appearances)
                source.unresolvedParticipantIDs.removeAll { !roster.contains($0) }
            } else if saved.coverage == source.coverage {
                let confirmations = saved.confirmations?.filter { roster.contains($0.participantID) && $0.matches(source) }
                source.confirmations = confirmations?.isEmpty == false ? confirmations : nil
            }
            revised.sources[index] = source
        }
        return revised
    }
}

private extension ParticipantAppearance {
    var legacyJSON: Self {
        var tile = self
        tile.detectedBounds = nil
        tile.reviewedIdentity = nil
        tile.reviewedPresentation = nil
        return tile
    }
}

func unsupportedLegacyParticipants(_ feature: String) -> CutError {
    CutError(code: "unsupported_legacy_participant_edit",
             message: "The participants commands cannot represent \(feature). Use the tiles commands for this project.")
}
