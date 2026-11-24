import Foundation

extension ParticipantProject {
    package mutating func setAppearanceOverride(_ pin: ParticipantAppearanceOverride) {
        appearanceOverrides = appearanceOverrides.flatMap { previous -> [ParticipantAppearanceOverride] in
            guard previous.participantID == pin.participantID, previous.sourceID == pin.sourceID,
                  previous.range.overlapsParticipantRange(pin.range) else { return [previous] }
            var retained: [ParticipantAppearanceOverride] = []
            if previous.range.from < pin.range.from {
                var before = previous
                before.range.to = pin.range.from
                retained.append(before)
            }
            if pin.range.to < previous.range.to {
                var after = previous
                after.range.from = pin.range.to
                retained.append(after)
            }
            return retained
        }
        appearanceOverrides.append(pin)
    }

    public mutating func linkAppearance(sourceID: String, appearanceID: String, participantID: String?,
                                        range: MulticamRange) throws {
        guard participantID == nil || people.contains(where: { $0.id == participantID }) else {
            throw invalidParticipantProject("Unknown participant.")
        }
        try editAppearance(sourceID: sourceID, appearanceID: appearanceID, range: range) {
            guard participantID == nil || $0.state != .presentation else {
                throw invalidParticipantProject("A presentation cannot be linked to a participant.")
            }
            $0.participantID = participantID
        }
    }

    public mutating func correctBounds(sourceID: String, appearanceID: String, bounds: ParticipantBounds,
                                       range: MulticamRange) throws {
        guard bounds.isValid else { throw invalidParticipantProject("Appearance bounds must fit inside the display frame.") }
        try editAppearance(sourceID: sourceID, appearanceID: appearanceID, range: range) { $0.bounds = bounds }
    }

    public mutating func correctLabelBounds(sourceID: String, appearanceID: String, bounds: ParticipantBounds?,
                                            range: MulticamRange) throws {
        guard bounds?.isValid ?? true else {
            throw invalidParticipantProject("Nameplate bounds must fit inside the display frame.")
        }
        try editAppearance(sourceID: sourceID, appearanceID: appearanceID, range: range) { $0.labelBounds = bounds }
    }

    public mutating func markPresentation(sourceID: String, appearanceID: String, range: MulticamRange) throws {
        try editAppearance(sourceID: sourceID, appearanceID: appearanceID, range: range) {
            $0.participantID = nil
            $0.state = .presentation
            $0.role = .presentation
        }
    }

    public mutating func splitAppearance(sourceID: String, appearanceID: String, at time: RationalTime,
                                         newAppearanceID: String) throws {
        guard let source = sources.first(where: { $0.sourceID == sourceID }),
              validStillID(newAppearanceID), !source.appearances.contains(where: { $0.id == newAppearanceID }),
              let first = source.appearances.filter({ $0.id == appearanceID }).map(\.range.from).min(),
              let last = source.appearances.filter({ $0.id == appearanceID }).map(\.range.to).max(),
              first < time, time < last else {
            throw invalidParticipantProject("Select an interior time and unused appearance ID to split a track.")
        }
        try editAppearance(sourceID: sourceID, appearanceID: appearanceID, range: .init(from: time, to: last)) {
            $0.id = newAppearanceID
        }
        appearanceOverrides = appearanceOverrides.flatMap { override in
            guard override.sourceID == sourceID, override.appearanceID == appearanceID,
                  override.range.to > time else { return [override] }
            var changed = override
            changed.appearanceID = newAppearanceID
            changed.range.from = max(override.range.from, time)
            if override.range.from >= time { return [changed] }
            var before = override
            before.range.to = time
            return [before, changed]
        }
    }

    private mutating func editAppearance(sourceID: String, appearanceID: String, range: MulticamRange,
                                         edit: (inout ParticipantAppearance) throws -> Void) throws {
        guard range.from < range.to, let index = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Select a source and a nonempty correction interval.")
        }
        var found = false
        let revised = try sources[index].appearances.flatMap { appearance -> [ParticipantAppearance] in
            guard appearance.id == appearanceID, appearance.range.overlapsParticipantRange(range) else { return [appearance] }
            found = true
            var pieces: [ParticipantAppearance] = []
            if appearance.range.from < range.from {
                var before = appearance
                before.range.to = range.from
                pieces.append(before)
            }
            var corrected = appearance
            corrected.range = .init(from: max(range.from, appearance.range.from), to: min(range.to, appearance.range.to))
            try edit(&corrected)
            pieces.append(corrected)
            if range.to < appearance.range.to {
                var after = appearance
                after.range.from = range.to
                pieces.append(after)
            }
            return pieces
        }
        guard found else { throw invalidParticipantProject("The appearance has no geometry in the correction interval.") }
        sources[index].appearances = revised
    }

    public func mapSourcePaths(_ map: (String) -> String) -> Self {
        var result = self
        for index in sources.indices { result.sources[index].sourceID = map(sources[index].sourceID) }
        for index in appearanceOverrides.indices { result.appearanceOverrides[index].sourceID = map(appearanceOverrides[index].sourceID) }
        for index in people.indices {
            if var selection = people[index].audio?.selection {
                selection.source = map(selection.source)
                result.people[index].audio = .init(selection: selection)
            }
        }
        result.render = render?.mapSourcePaths(map)
        return result
    }

    package var protectedMediaPaths: [(id: String, path: String)] {
        let picture = sources.map { ($0.sourceID, $0.sourceID) }
        let audio = people.compactMap { person in person.audio?.selection.map { (person.id, $0.source) } }
        let slots = render?.shots.flatMap(\.slots).filter { $0.target == .camera }.map { ($0.id, $0.id) } ?? []
        return picture + audio + slots
    }

    public func validate() throws {
        let roster = Set(people.map(\.id))
        guard roster.count == people.count,
              people.allSatisfy({ validStillID($0.id) && validStillID($0.name) }) else {
            throw invalidParticipantProject("Participant IDs must be unique and participants need a display name.")
        }
        var speakers = Set<ParticipantSpeakerBinding>()
        for person in people {
            for speaker in person.speakers {
                guard validStillID(speaker.attachmentID), validStillID(speaker.speakerID),
                      speakers.insert(speaker).inserted else {
                    throw invalidParticipantProject("Each attachment-scoped speaker must belong to one participant.")
                }
            }
            if let audio = person.audio {
                if let laneID = audio.laneID, audio.selection == nil, validStillID(laneID) { continue }
                if let selection = audio.selection, audio.laneID == nil, validStillID(selection.source),
                   (0...Int(Int32.max)).contains(selection.stream) { continue }
                throw invalidParticipantProject("Bind a participant to one audio lane or one audio stream.")
            }
        }
        var sourceIDs = Set<String>()
        for source in sources {
            guard source.feedLayout?.isValid ?? true else {
                throw invalidParticipantProject("Invalid feed layout on source ‘\(source.sourceID)’.")
            }
            guard validStillID(source.sourceID), sourceIDs.insert(source.sourceID).inserted,
                  source.analysisIdentity.map(validStillID) ?? true,
                  source.sourceContentSHA256.map(validParticipantSourceDigest) ?? true,
                  Set(source.unresolvedParticipantIDs).count == source.unresolvedParticipantIDs.count,
                  source.unresolvedParticipantIDs.allSatisfy(roster.contains) else {
                throw invalidParticipantProject("Participant geometry needs unique source IDs.")
            }
            for appearance in source.appearances {
                guard validStillID(appearance.id), appearance.bounds.isValid,
                      appearance.labelBounds?.isValid ?? true, appearance.slotID.map(validStillID) ?? true,
                      appearance.participantID.map(roster.contains) ?? true,
                      (appearance.state == .presentation) == (appearance.role == .presentation),
                      appearance.state != .presentation || appearance.participantID == nil else {
                    throw invalidParticipantProject("Invalid appearance ‘\(appearance.id)’ on source ‘\(source.sourceID)’.")
                }
            }
            let tracks = Dictionary(grouping: source.appearances, by: \.id)
            guard tracks.values.allSatisfy({ Self.nonoverlapping($0.map(\.range)) }),
                  Self.nonoverlapping(source.coverage.map(\.range)) else {
                throw invalidParticipantProject("Appearance and coverage intervals must be nonempty and nonoverlapping within a track.")
            }
        }
        for override in appearanceOverrides {
            guard roster.contains(override.participantID),
                  sources.first(where: { $0.sourceID == override.sourceID })?.appearances.contains(where: { $0.id == override.appearanceID }) == true else {
                throw invalidParticipantProject("An appearance override refers to an unknown participant or appearance.")
            }
        }
        let overridesBySource = Dictionary(grouping: appearanceOverrides, by: \.sourceID)
        for overrides in overridesBySource.values {
            let byPerson = Dictionary(grouping: overrides, by: \.participantID)
            guard byPerson.values.allSatisfy({ Self.nonoverlapping($0.map(\.range)) }) else {
                throw invalidParticipantProject("Appearance override intervals must be nonempty and nonoverlapping.")
            }
        }
        try render?.validate()
        if let render {
            let slots = render.shots.flatMap(\.slots)
            guard slots.filter({ $0.target == .participant }).allSatisfy({ roster.contains($0.id) }),
                  render.redactions.allSatisfy({ roster.contains($0.participantID) }),
                  render.audio.mode != .iso || render.audio.ids.allSatisfy({ audioBinding(for: $0) != nil }) else {
                throw invalidParticipantProject("The render plan refers to an unknown participant or missing ISO binding.")
            }
        }
    }

    private static func nonoverlapping(_ ranges: [MulticamRange]) -> Bool {
        let sorted = ranges.sorted { $0.from < $1.from }
        return sorted.allSatisfy { $0.from < $0.to } && zip(sorted, sorted.dropFirst()).allSatisfy { $0.to <= $1.from }
    }
}

extension MulticamRange {
    fileprivate func overlapsParticipantRange(_ other: Self) -> Bool { from < other.to && other.from < to }
}

extension ParticipantProject {
    var historyRecordCount: Int {
        let sourceRecords = sources.reduce(0) { $0 + 1 + $1.appearances.count + $1.coverage.count + $1.unresolvedParticipantIDs.count }
        let rosterRecords = people.reduce(0) { $0 + 1 + $1.speakers.count + ($1.audio == nil ? 0 : 1) }
        let shotRecords = render?.shots.reduce(0) { $0 + 1 + $1.slots.count } ?? 0
        return sourceRecords + rosterRecords + appearanceOverrides.count + shotRecords + (render?.redactions.count ?? 0)
    }
}
