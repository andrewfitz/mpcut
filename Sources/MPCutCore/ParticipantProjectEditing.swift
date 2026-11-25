import Foundation

extension ParticipantProject {
    package mutating func setAppearanceOverride(_ pin: ParticipantAppearanceOverride) {
        let previous = appearanceOverrides
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
        if appearanceOverrides != previous, let index = sources.firstIndex(where: { $0.sourceID == pin.sourceID }) {
            sources[index].confirmations = nil
        }
    }

    public mutating func linkAppearance(sourceID: String, appearanceID: String, participantID: String?,
                                        range: MulticamRange) throws {
        try linkAppearance(sourceID: sourceID, appearanceID: appearanceID, participantID: participantID,
                           range: range, movingPreference: false)
    }

    mutating func linkAppearance(sourceID: String, appearanceID: String, participantID: String?,
                                 range: MulticamRange, movingPreference: Bool) throws {
        guard participantID == nil || people.contains(where: { $0.id == participantID }) else {
            throw invalidParticipantProject("Unknown participant.")
        }
        try assigningAppearance(sourceID: sourceID, appearanceID: appearanceID, participantID: participantID,
                                range: range, movingPreference: movingPreference) {
            $0.participantID = participantID
            // Assigning an unidentified box makes its picture available to the feed.
            // Source coverage and the separate privacy confirmation still apply.
            if participantID != nil, $0.state == .unknown { $0.state = .video }
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
        try assigningAppearance(sourceID: sourceID, appearanceID: appearanceID, participantID: nil, range: range) {
            $0.participantID = nil
            $0.state = .presentation
            $0.role = .presentation
            $0.reviewedPresentation = true
        }
    }

    /// Create or reuse the feed for a screen share while retaining the tile's track ID.
    @discardableResult
    public mutating func setScreenShare(sourceID: String, appearanceID: String,
                                        range: MulticamRange, name: String = "Screen Share") throws -> String {
        guard let sourceIndex = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Choose an accepted source.")
        }
        let track = sources[sourceIndex].appearances.filter { $0.id == appearanceID }
        let touched = track.filter { $0.range.overlapsParticipantRange(range) }
        let existing = Set(track.filter { $0.role == .presentation }.compactMap(\.participantID))
        guard existing.count <= 1 else {
            throw invalidParticipantProject("The tile already tracks more than one screen-share feed.")
        }
        let feedID = existing.first ?? UUID().uuidString.lowercased()
        var updated = self
        if existing.isEmpty { updated.people.append(.init(id: feedID, name: name)) }
        try updated.assigningAppearance(sourceID: sourceID, appearanceID: appearanceID, participantID: feedID, range: range) {
            $0.participantID = feedID
            $0.state = .presentation
            $0.role = .presentation
            $0.reviewedPresentation = true
        }
        let displaced = Set(touched.compactMap(\.participantID)).subtracting([feedID])
        updated.sources[sourceIndex].unresolvedParticipantIDs =
            Set(updated.sources[sourceIndex].unresolvedParticipantIDs).union(displaced).sorted()
        try updated.validate()
        self = updated
        return feedID
    }

    public mutating func splitAppearance(sourceID: String, appearanceID: String, at time: RationalTime,
                                         newAppearanceID: String) throws {
        guard let index = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Choose an accepted source.")
        }
        let source = sources[index]
        let track = source.appearances.filter { $0.id == appearanceID }
        guard validStillID(newAppearanceID), !source.appearances.contains(where: { $0.id == newAppearanceID }),
              let first = track.map(\.range.from).min(), let last = track.map(\.range.to).max(),
              first < time, time < last else {
            throw invalidParticipantProject("Select an interior time and unused appearance ID to split a track.")
        }
        sources[index].appearances = source.appearances.flatMap { tile in
            guard tile.id == appearanceID else { return [tile] }
            let slot = tile.slotID ?? appearanceID
            var pieces: [ParticipantAppearance] = []
            if tile.range.from < time {
                var left = tile
                left.range.to = min(time, tile.range.to)
                left.slotID = slot
                pieces.append(left)
            }
            if time < tile.range.to {
                var right = tile
                right.id = newAppearanceID
                right.range.from = max(time, tile.range.from)
                right.slotID = slot
                pieces.append(right)
            }
            return pieces
        }
        sources[index].scanEvents = source.scanEvents.map {
            $0.remappingTiles { id, eventTime in id == appearanceID && eventTime >= time ? newAppearanceID : id }
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

    private mutating func assigningAppearance(sourceID: String, appearanceID: String, participantID: String?,
                                               range: MulticamRange, movingPreference: Bool = false,
                                               edit: (inout ParticipantAppearance) -> Void) throws {
        guard range.from < range.to, let index = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Select a source and a nonempty correction interval.")
        }
        let track = sources[index].appearances.filter { $0.id == appearanceID }
        let touched = track.filter { $0.range.overlapsParticipantRange(range) }
        guard !touched.isEmpty else {
            throw invalidParticipantProject("The appearance has no geometry in the correction interval.")
        }
        guard touched.contains(where: { piece in
            var changed = piece
            edit(&changed)
            return changed != piece
        }) else { return }

        let beforeID = track.contains { $0.range.from < range.from } ? ProjectIdentifier.make() : appearanceID
        let afterID = track.contains { range.to < $0.range.to } ? ProjectIdentifier.make() : appearanceID
        let partitioned = beforeID != appearanceID || afterID != appearanceID
        func tileID(_ time: RationalTime) -> String {
            if time < range.from { return beforeID }
            return time >= range.to ? afterID : appearanceID
        }
        sources[index].appearances = sources[index].appearances.flatMap { tile -> [ParticipantAppearance] in
            guard tile.id == appearanceID else { return [tile] }
            func piece(from: RationalTime, to: RationalTime, id: String) -> ParticipantAppearance? {
                let lower = max(from, tile.range.from)
                let upper = min(to, tile.range.to)
                guard lower < upper else { return nil }
                var piece = tile
                piece.range = .init(from: lower, to: upper)
                piece.id = id
                if partitioned { piece.slotID = tile.slotID ?? appearanceID }
                return piece
            }
            let before = piece(from: tile.range.from, to: range.from, id: beforeID)
            let assigned = piece(from: range.from, to: range.to, id: appearanceID).map { appearance in
                var result = appearance
                edit(&result)
                result.reviewedIdentity = true
                return result
            }
            let after = piece(from: range.to, to: tile.range.to, id: afterID)
            return [before, assigned, after].compactMap { $0 }
        }
        sources[index].scanEvents = sources[index].scanEvents.map {
            $0.remappingTiles { id, time in id == appearanceID ? tileID(time) : id }
        }
        appearanceOverrides = appearanceOverrides.flatMap { pin -> [ParticipantAppearanceOverride] in
            guard pin.sourceID == sourceID, pin.appearanceID == appearanceID else { return [pin] }
            func piece(from: RationalTime, to: RationalTime, tile: String, feed: String?) -> ParticipantAppearanceOverride? {
                let lower = max(from, pin.range.from)
                let upper = min(to, pin.range.to)
                guard let feed, lower < upper else { return nil }
                return .init(participantID: feed, sourceID: sourceID, appearanceID: tile,
                             range: .init(from: lower, to: upper))
            }
            let selected = movingPreference || pin.participantID == participantID ? participantID : nil
            return [piece(from: pin.range.from, to: range.from, tile: beforeID, feed: pin.participantID),
                    piece(from: range.from, to: range.to, tile: appearanceID, feed: selected),
                    piece(from: range.to, to: pin.range.to, tile: afterID, feed: pin.participantID)].compactMap { $0 }
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
            if corrected.bounds != appearance.bounds {
                corrected.detectedBounds = appearance.detectedBounds ?? appearance.bounds
            }
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
        var result = mapSourceIDs(map)
        for index in pendingReviews.indices { result.pendingReviews[index].file = map(pendingReviews[index].file) }
        return result
    }

    func mapSourceIDs(_ map: (String) -> String) -> Self {
        var result = self
        for index in pendingReviews.indices { result.pendingReviews[index].sourceID = map(pendingReviews[index].sourceID) }
        for index in sources.indices { result.sources[index].sourceID = map(sources[index].sourceID) }
        for index in appearanceOverrides.indices { result.appearanceOverrides[index].sourceID = map(appearanceOverrides[index].sourceID) }
        for index in people.indices {
            if let origin = people[index].legacyPresentation {
                result.people[index].legacyPresentation?.sourceID = map(origin.sourceID)
            }
            if var selection = people[index].audio?.selection {
                selection.source = map(selection.source)
                result.people[index].audio = .init(selection: selection)
            }
        }
        result.render = render?.mapSourcePaths(map)
        return result
    }

    var pendingMediaPaths: [(id: String, path: String)] {
        pendingReviews.map { ($0.sourceID, $0.file) }
    }

    package var protectedMediaPaths: [(id: String, path: String)] {
        let picture = sources.map { ($0.sourceID, $0.sourceID) }
        let audio = people.compactMap { person in person.audio?.selection.map { (person.id, $0.source) } }
        let slots = render?.shots.flatMap(\.slots).filter { $0.target == .camera }.map { ($0.id, $0.id) } ?? []
        return picture + audio + slots + pendingMediaPaths
    }

    public func validate() throws {
        let reviews = pendingReviews
        guard Set(reviews.map(\.sourceID)).count == reviews.count, Set(reviews.map(\.id)).count == reviews.count,
              reviews.allSatisfy({ review in
                  validStillID(review.id) && validStillID(review.sourceID) && ProjectFile.validMediaPath(review.file)
                  && review.choices.analysisIdentity == review.asset.scan.analysisIdentity
                  && TilesReviewChoices.validMerges(review.choices.merged)
                  && review.choices.grids.allSatisfy { grid in
                      grid.isValid && grid.range.from >= .zero && grid.range.from < grid.range.to
                          && grid.range.to <= review.asset.scan.source.duration
                  } }) else {
            throw invalidParticipantProject("Invalid pending tile review.")
        }
        let roster = Set(people.map(\.id))
        guard roster.count == people.count,
              people.allSatisfy({ validStillID($0.id) && validStillID($0.name) && ($0.treatment?.color ?? 0) <= 0xFFFFFF }) else {
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
                  (source.historicalParticipantIDs ?? []).allSatisfy(validStillID),
                  (source.confirmations ?? []).allSatisfy({
                      roster.contains($0.participantID) && $0.range.from >= .zero && $0.range.from < $0.range.to
                          && ($0.reviewDigest.map(validParticipantSourceDigest) ?? true)
                  }),
                  Set(source.unresolvedParticipantIDs).count == source.unresolvedParticipantIDs.count,
                  source.unresolvedParticipantIDs.allSatisfy(roster.contains) else {
                throw invalidParticipantProject("Participant geometry needs unique source IDs.")
            }
            guard source.countHints?.expectedFeeds.map({ $0 > 0 }) ?? true,
                  source.countHints?.maxVisibleTiles.map({ $0 > 0 }) ?? true,
                  source.scanEvents.allSatisfy({ event in
                      event.time >= .zero && (event.tileID.map(validStillID) ?? true)
                          && (event.feedID.map(validStillID) ?? true) && (event.candidates ?? []).allSatisfy { candidate in
                          validStillID(candidate.feedID) && candidate.confidence.isFinite
                              && (candidate.precedingTileID.map(validStillID) ?? true)
                              && (candidate.precedingTime.map { $0 >= .zero && $0 < event.time } ?? true)
                      }
                  }) else {
                throw invalidParticipantProject("Invalid scan evidence on source ‘\(source.sourceID)’.")
            }
            for appearance in source.appearances {
                guard validStillID(appearance.id), appearance.bounds.isValid,
                      appearance.labelBounds?.isValid ?? true, appearance.detectedBounds?.isValid ?? true,
                      appearance.slotID.map(validStillID) ?? true,
                      appearance.participantID.map(roster.contains) ?? true,
                      (appearance.state == .presentation) == (appearance.role == .presentation) else {
                    throw invalidParticipantProject("Invalid appearance ‘\(appearance.id)’ on source ‘\(source.sourceID)’.")
                }
            }
            let tracks = Dictionary(grouping: source.appearances, by: \.id)
            guard tracks.values.allSatisfy({ Self.nonoverlapping($0.map(\.range)) }),
                  Self.nonoverlapping(source.coverage.map(\.range)),
                  Self.nonoverlapping(source.layoutCapacityRanges ?? []),
                  source.layoutCapacityRanges?.allSatisfy({ $0.from >= .zero }) ?? true else {
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
        if let tileOutput {
            try ParticipantRenderPlan(canvas: tileOutput.canvas, shots: [.init(layout: .original)],
                                      audio: tileOutput.audio).validate(allowNativeLayouts: true)
            if tileOutput.audio.mode == .iso,
               !tileOutput.audio.ids.allSatisfy({ audioBinding(for: $0) != nil }) {
                throw invalidParticipantProject("The output soundtrack refers to a missing ISO binding.")
            }
        }
        try render?.validate()
        if let render, tileOutput == nil {
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
        let sourceRecords = sources.reduce(0) { $0 + 1 + $1.appearances.count + $1.coverage.count + $1.unresolvedParticipantIDs.count + $1.scanEvents.count }
        let rosterRecords = people.reduce(0) { $0 + 1 + $1.speakers.count + ($1.audio == nil ? 0 : 1) }
        let shotRecords = render?.shots.reduce(0) { $0 + 1 + $1.slots.count } ?? 0
        return sourceRecords + rosterRecords + appearanceOverrides.count + shotRecords + (render?.redactions.count ?? 0)
    }
}
