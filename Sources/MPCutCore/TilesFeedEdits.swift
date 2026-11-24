import Foundation

extension ParticipantProject {
    public mutating func addFeed(name: String? = nil) throws -> String {
        let name = name ?? "Feed \(people.count + 1)"
        guard validStillID(name) else { throw invalidParticipantProject("A feed needs a display name.") }
        let id = ProjectIdentifier.make(avoiding: people.map(\.id))
        people.append(.init(id: id, name: name))
        return id
    }

    public mutating func renameFeed(_ feedID: String, name: String) throws {
        let index = try feedIndex(feedID)
        guard validStillID(name) else { throw invalidParticipantProject("A feed needs a display name.") }
        people[index].name = name
    }

    public mutating func setFeedMicrophone(_ feedID: String, binding: ParticipantAudioBinding?) throws {
        let index = try feedIndex(feedID)
        if let binding {
            let lane = binding.laneID.map(validStillID) == true && binding.selection == nil
            let stream = binding.selection.map { validStillID($0.source) && (0...Int(Int32.max)).contains($0.stream) } == true
                && binding.laneID == nil
            guard lane || stream else { throw invalidParticipantProject("Bind a feed to one audio lane or one audio stream.") }
        }
        people[index].audio = binding
    }

    public mutating func setFeedVoice(_ feedID: String, attachmentID: String?, speakerID: String?) throws {
        let index = try feedIndex(feedID)
        guard let speakerID else {
            people[index].speakers.removeAll { attachmentID == nil || $0.attachmentID == attachmentID }
            return
        }
        guard let attachmentID, validStillID(attachmentID), validStillID(speakerID) else {
            throw invalidParticipantProject("A transcript voice needs an attachment and a speaker ID.")
        }
        let voice = ParticipantSpeakerBinding(attachmentID: attachmentID, speakerID: speakerID)
        guard !people.contains(where: { $0.id != feedID && $0.speakers.contains(voice) }) else {
            throw invalidParticipantProject("This transcript voice already belongs to another feed.")
        }
        if !people[index].speakers.contains(voice) { people[index].speakers.append(voice) }
    }

    private func feedIndex(_ feedID: String) throws -> Int {
        guard let index = people.firstIndex(where: { $0.id == feedID }) else {
            throw invalidParticipantProject("Unknown feed ‘\(feedID)’.")
        }
        return index
    }

    public mutating func mergeFeeds(_ removed: String, into surviving: String) throws -> [String] {
        guard removed != surviving, let old = people.first(where: { $0.id == removed }),
              let index = people.firstIndex(where: { $0.id == surviving }) else {
            throw invalidParticipantProject("Choose two different existing feeds.")
        }
        var copy = self
        var conflicts: [String] = []
        if let mic = old.audio {
            if let current = copy.people[index].audio, current != mic {
                conflicts.append("Kept the surviving feed's microphone.")
            } else {
                copy.people[index].audio = mic
            }
        }
        copy.people[index].speakers.append(contentsOf: old.speakers.filter { !copy.people[index].speakers.contains($0) })
        func strictness(_ treatment: ParticipantFeedTreatment?) -> Int {
            switch treatment?.mode {
            case nil: 0
            case .blur: 1
            case .cover: 2
            case .remove: 3
            }
        }
        let effective = Dictionary(effectiveRedactions.map { ($0.participantID, ParticipantFeedTreatment($0)) },
                                   uniquingKeysWith: { first, second in strictness(first) >= strictness(second) ? first : second })
        let previous = effective[removed]
        let current = effective[surviving]
        let treatment = strictness(previous) > strictness(current) ? previous : current
        copy.people[index].treatment = treatment
        copy.people.removeAll { $0.id == removed }
        for source in copy.sources.indices {
            var geometry = copy.sources[source]
            let pending = geometry.unresolvedParticipantIDs
            geometry.appearances = geometry.appearances.map { tile in
                guard tile.participantID == removed else { return tile }
                var changed = tile
                changed.participantID = surviving
                changed.reviewedIdentity = true
                return changed
            }
            geometry.scanEvents = geometry.scanEvents.map { $0.remapping(tiles: [:], feeds: [removed: surviving]) }
            if geometry.historicalParticipantIDs?.contains(removed) == true {
                geometry.historicalParticipantIDs = Set(geometry.historicalParticipantIDs!.map { $0 == removed ? surviving : $0 }).sorted()
            }
            geometry.unresolvedParticipantIDs = Set(pending.map { $0 == removed ? surviving : $0 }).sorted()
            geometry.confirmations = geometry.confirmations?.filter { $0.participantID != removed && $0.participantID != surviving }
            copy.sources[source] = geometry
        }
        let moved = copy.appearanceOverrides.filter { $0.participantID == removed }
        copy.appearanceOverrides.removeAll { $0.participantID == removed }
        for pin in moved {
            let accepted = copy.appearanceOverrides.filter {
                $0.participantID == surviving && $0.sourceID == pin.sourceID &&
                    $0.range.from < pin.range.to && pin.range.from < $0.range.to
            }
            let conflict = "Kept the surviving feed's preferred tiles where choices overlapped on \(pin.sourceID)."
            if accepted.contains(where: { $0.appearanceID != pin.appearanceID }), !conflicts.contains(conflict) {
                conflicts.append(conflict)
            }
            var retained = [pin.range]
            for existing in accepted {
                retained = retained.flatMap { Self.excluding(existing.range, from: $0) }
            }
            copy.appearanceOverrides += retained.map {
                .init(participantID: surviving, sourceID: pin.sourceID, appearanceID: pin.appearanceID, range: $0)
            }
        }
        if var render = copy.render {
            for shot in render.shots.indices {
                for slot in render.shots[shot].slots.indices where render.shots[shot].slots[slot].target == .participant
                    && render.shots[shot].slots[slot].id == removed {
                    render.shots[shot].slots[slot].id = surviving
                }
            }
            // Keep the original composition's treatment provenance. A newer
            // Remove treatment can be used with Original only in native layouts.
            let removedTreatment = render.redactions.first { $0.participantID == removed }.map(ParticipantFeedTreatment.init)
            let survivingTreatment = render.redactions.first { $0.participantID == surviving }.map(ParticipantFeedTreatment.init)
            let savedTreatment = strictness(removedTreatment) > strictness(survivingTreatment) ? removedTreatment : survivingTreatment
            render.redactions.removeAll { $0.participantID == removed || $0.participantID == surviving }
            if let savedTreatment { render.redactions.append(savedTreatment.redaction(for: surviving)) }
            if render.audio.mode == .iso, render.audio.ids == [removed] { render.audio.ids = [surviving] }
            copy.render = render
        }
        if copy.tileOutput?.audio.mode == .iso, copy.tileOutput?.audio.ids == [removed] {
            copy.tileOutput?.audio.ids = [surviving]
        }
        try copy.validate()
        self = copy
        return conflicts
    }

    public mutating func splitFeed(_ feedID: String, sourceID: String, tileID: String, range: MulticamRange,
                                   newFeedID: String, name: String) throws {
        guard people.contains(where: { $0.id == feedID }), validStillID(newFeedID),
              !people.contains(where: { $0.id == newFeedID }), validStillID(name) else {
            throw invalidParticipantProject("Choose an existing feed, an unused ID and a name for the new feed.")
        }
        let overlapping = sources.first(where: { $0.sourceID == sourceID })?.appearances.filter {
            $0.id == tileID && $0.range.from < range.to && range.from < $0.range.to
        } ?? []
        guard !overlapping.isEmpty, overlapping.allSatisfy({ $0.participantID == feedID }) else {
            throw invalidParticipantProject("Choose a tile range assigned to the feed being split.")
        }
        var copy = self
        let treatment = effectiveRedactions.first { $0.participantID == feedID }.map(ParticipantFeedTreatment.init)
        copy.people.append(.init(id: newFeedID, name: name, treatment: treatment))
        guard let source = copy.sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Choose a recording with accepted tiles.")
        }
        let pending = Set(copy.sources[source].unresolvedParticipantIDs)
        try copy.linkAppearance(sourceID: sourceID, appearanceID: tileID, participantID: newFeedID,
                                range: range, movingPreference: true)
        copy.sources[source].unresolvedParticipantIDs = pending.contains(feedID) ? pending.union([newFeedID]).sorted() : pending.sorted()
        copy.sources[source].confirmations = nil
        copy.sources[source].historicalParticipantIDs = Set(copy.sources[source].historicalParticipantIDs ?? [])
            .union([feedID, newFeedID]).sorted()
        try copy.validate()
        self = copy
    }

    public mutating func preferTile(sourceID: String, feedID: String, tileID: String?, range: MulticamRange) throws {
        guard people.contains(where: { $0.id == feedID }), range.from < range.to else {
            throw invalidParticipantProject("Choose a feed and a nonempty source range.")
        }
        if let tileID {
            guard sources.first(where: { $0.sourceID == sourceID })?.appearances.contains(where: {
                $0.id == tileID && $0.participantID == feedID && $0.range.from < range.to && range.from < $0.range.to
            }) == true else {
                throw invalidParticipantProject("Choose a tile linked to this feed in the preference range.")
            }
            setAppearanceOverride(.init(participantID: feedID, sourceID: sourceID, appearanceID: tileID, range: range))
        } else {
            let previous = appearanceOverrides
            appearanceOverrides = appearanceOverrides.flatMap { previous in
                guard previous.participantID == feedID, previous.sourceID == sourceID,
                      previous.range.from < range.to, range.from < previous.range.to else { return [previous] }
                return Self.excluding(range, from: previous.range).map { range in
                    var piece = previous
                    piece.range = range
                    return piece
                }
            }
            if appearanceOverrides != previous, let index = sources.firstIndex(where: { $0.sourceID == sourceID }) {
                sources[index].confirmations = nil
            }
        }
    }

    private static func excluding(_ removal: MulticamRange, from range: MulticamRange) -> [MulticamRange] {
        guard range.from < removal.to, removal.from < range.to else { return [range] }
        var retained: [MulticamRange] = []
        if range.from < removal.from { retained.append(.init(from: range.from, to: removal.from)) }
        if removal.to < range.to { retained.append(.init(from: removal.to, to: range.to)) }
        return retained
    }
}

extension CutProject {
    public mutating func mergeTileFeeds(_ removed: String, into surviving: String) throws -> [String] {
        var model = participants
        let conflicts = try model.mergeFeeds(removed, into: surviving)
        func remap(_ layouts: [TileLayoutSpan]) -> [TileLayoutSpan] {
            layouts.map { layout in
                var result = layout
                for index in result.slots.indices where result.slots[index].target == .participant
                    && result.slots[index].id == removed {
                    result.slots[index].id = surviving
                }
                return result
            }
        }
        self = try editingStills(sequence: { project in
            project.participants = model
            for index in project.items.indices {
                guard var clip = project.items[index].source else { continue }
                clip.tileLayouts = remap(clip.tileLayouts)
                project.items[index] = .source(clip)
            }
        }, multicam: { project in
            project.participants = model
            project.groupTileLayouts = remap(project.groupTileLayouts)
            if var assembly = project.assemblyItems {
                for index in assembly.indices {
                    let item = assembly[index]
                    guard let range = item.group else { continue }
                    assembly[index] = .group(range, angle: item.angleOverride,
                                             id: item.occurrenceID, layouts: remap(item.tileLayouts))
                }
                project.assemblyItems = assembly
            }
            project.mergeFeedAngleReferences(removed, into: surviving)
        })
        return conflicts
    }
}
