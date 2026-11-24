import CryptoKit
import Foundation

public struct ParticipantReconciliation: Equatable, Sendable {
    public let sourceID: String
    public let sourceChanged: Bool
    public let retainedCopiedGeometry: Bool
    public let removedAppearanceIDs: [String]
    public let affectedParticipantIDs: [String]
    public let affectedRedactionIDs: [String]
    public let affectedBindingIDs: [String]
    public let affectedPresentationIDs: [String]
    public let removedOverrideCount: Int

    fileprivate let previous: ParticipantSourceGeometry
    fileprivate let previousOverrides: [ParticipantAppearanceOverride]
    fileprivate let analysisIdentity: String

    public func reviewToken(for scan: ParticipantScanResult) throws -> String {
        struct Input: Encodable {
            let geometry: ParticipantSourceGeometry
            let overrides: [ParticipantAppearanceOverride]
            let affectedParticipantIDs: [String]
            let affectedRedactionIDs: [String]
            let affectedBindingIDs: [String]
            let affectedPresentationIDs: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(Input(geometry: previous, overrides: previousOverrides,
            affectedParticipantIDs: affectedParticipantIDs,
            affectedRedactionIDs: affectedRedactionIDs, affectedBindingIDs: affectedBindingIDs,
            affectedPresentationIDs: affectedPresentationIDs))
        // "replacement" is the last sorted field of the original token payload.
        // Stream its rows while retaining the existing JSON bytes and tokens.
        var hash = SHA256()
        hash.update(data: bytes.dropLast())
        hash.update(data: Data(#","replacement":"#.utf8))
        try scan.writeJSON(pretty: false, escapeSlashes: true) { hash.update(data: $0) }
        hash.update(data: Data([0x7d]))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension CutProject {
    public func participantReconciliation(_ scan: ParticipantScanResult, sourceID: String,
                                          relativeTo projectURL: URL,
                                          cancelled: @escaping () -> Bool = { false }) throws -> ParticipantReconciliation {
        let validated = try validateParticipantScanSource(scan, sourceID: sourceID, relativeTo: projectURL, cancelled: cancelled)
        return try participants.reconciliation(for: validated, sourceID: sourceID)
    }

    public mutating func applyReviewedParticipantReconciliation(_ scan: ParticipantScanResult, sourceID: String,
                                                               relativeTo projectURL: URL, token: String,
                                                               cancelled: @escaping () -> Bool = { false }) throws {
        let validated = try validateParticipantScanSource(scan, sourceID: sourceID, relativeTo: projectURL, cancelled: cancelled)
        let review = try participants.reconciliation(for: validated, sourceID: sourceID)
        guard try review.reviewToken(for: scan) == token else {
            throw invalidParticipantProject("The accepted geometry or replacement scan changed after review. Review the replacement again.")
        }
        try participants.reconcileAnalysis(validated, sourceID: sourceID, reviewed: review)
    }

    public mutating func reconcileParticipantAnalysis(_ scan: ParticipantScanResult, sourceID: String,
                                                      relativeTo projectURL: URL,
                                                      reviewed: ParticipantReconciliation, cancelled: @escaping () -> Bool = { false }) throws {
        let validated = try validateParticipantScanSource(scan, sourceID: sourceID, relativeTo: projectURL, cancelled: cancelled)
        try participants.reconcileAnalysis(validated, sourceID: sourceID, reviewed: reviewed)
    }
}

extension ParticipantProject {
    public func reconciliation(for scan: ParticipantScanResult, sourceID: String) throws -> ParticipantReconciliation {
        try prepareReconciliation(scan, sourceID: sourceID).review
    }

    public mutating func reconcileAnalysis(_ scan: ParticipantScanResult, sourceID: String,
                                           reviewed: ParticipantReconciliation) throws {
        let prepared = try prepareReconciliation(scan, sourceID: sourceID)
        guard prepared.review == reviewed else {
            throw invalidParticipantProject("The accepted geometry or affected decisions changed after review. Review the replacement again.")
        }
        var revised = self
        revised.sources[prepared.index] = prepared.geometry
        revised.people.append(contentsOf: prepared.newPeople)
        revised.appearanceOverrides.removeAll { override in
            override.sourceID == sourceID && prepared.removedIDs.contains(override.appearanceID)
        }
        try revised.validate()
        self = revised
    }

    /// Confirm that all appearances and absences for this person have been reviewed throughout this source.
    public mutating func confirmReconciledParticipant(sourceID: String, participantID: String) throws {
        guard let index = sources.firstIndex(where: { $0.sourceID == sourceID }),
              sources[index].unresolvedParticipantIDs.contains(participantID) else {
            throw invalidParticipantProject("The participant has no pending reconciliation on this source.")
        }
        sources[index].unresolvedParticipantIDs.removeAll { $0 == participantID }
    }

    private struct PreparedReconciliation {
        let review: ParticipantReconciliation
        let index: Int
        let geometry: ParticipantSourceGeometry
        let newPeople: [ParticipantPerson]
        let removedIDs: Set<String>
    }

    private func prepareReconciliation(_ scan: ParticipantScanResult, sourceID: String) throws -> PreparedReconciliation {
        guard let index = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("This source has no accepted geometry to reconcile.")
        }
        let previous = sources[index]
        var replacement = ParticipantProject()
        try replacement.acceptAnalysis(scan, sourceID: sourceID)
        guard var geometry = replacement.sources.first else {
            throw invalidParticipantProject("The replacement scan has no usable geometry.")
        }
        geometry.countHints = previous.countHints
        let digestMatches = previous.sourceContentSHA256 != nil
            && previous.sourceContentSHA256 == scan.source.contentSHA256
        let digestConflicts = previous.sourceContentSHA256 != nil && scan.source.contentSHA256 != nil && !digestMatches
        let sameSource = !digestConflicts && previous.sourceStamp == scan.source.stamp
            && previous.sourceInode != nil && previous.sourceInode == scan.source.inode
        let sameLayout = (previous.feedLayout ?? .meeting) == scan.configuration.feedLayout
        let retainedCopiedGeometry = sameLayout && digestMatches && !sameSource
        let overrides = appearanceOverrides.filter { $0.sourceID == sourceID }
        let historical = Set(previous.historicalParticipantIDs ?? []).union(previous.appearances.compactMap(\.participantID))
        if retainedCopiedGeometry {
            geometry.appearances = previous.appearances
            geometry.coverage = previous.coverage
            geometry.scanEvents = previous.scanEvents
            geometry.layoutCapacityRanges = previous.layoutCapacityRanges
            geometry.unresolvedParticipantIDs = previous.unresolvedParticipantIDs
            geometry.historicalParticipantIDs = historical.isEmpty ? nil : historical.sorted()
            let review = ParticipantReconciliation(sourceID: sourceID, sourceChanged: false, retainedCopiedGeometry: true,
                removedAppearanceIDs: [], affectedParticipantIDs: [], affectedRedactionIDs: [], affectedBindingIDs: [],
                affectedPresentationIDs: [], removedOverrideCount: 0, previous: previous, previousOverrides: overrides,
                analysisIdentity: scan.analysisIdentity)
            return .init(review: review, index: index, geometry: geometry, newPeople: [], removedIDs: [])
        }

        let oldTracks = Dictionary(grouping: previous.appearances, by: \.id)
            .mapValues { $0.sorted { $0.range.from < $1.range.from } }
        let newTracks = Dictionary(grouping: geometry.appearances, by: \.id)
            .mapValues { $0.sorted { $0.range.from < $1.range.from } }
        let previousDetections = Self.detectorPaths(oldTracks)
        let retainedTiles = sameSource && sameLayout ? Self.matchTiles(previousDetections, newTracks) : [:]
        var feedCandidates: [String: Set<String>] = [:]
        for (newID, oldID) in retainedTiles {
            guard let prior = previousDetections[oldID], let fresh = newTracks[newID] else { continue }
            Self.intersect(prior, fresh) { oldTile, newTile, _ in
                if oldTile.reviewedIdentity != true,
                   let oldFeed = oldTile.participantID, let newFeed = newTile.participantID,
                   Self.boundsAgree(oldTile, newTile) {
                    feedCandidates[newFeed, default: []].insert(oldFeed)
                }
            }
        }
        let feedMatches = feedCandidates.compactMapValues { $0.count == 1 ? $0.first : nil }
        let feedMatchCounts = Dictionary(grouping: feedMatches.values, by: { $0 }).mapValues(\.count)
        let retainedFeeds = feedMatches.filter { feedMatchCounts[$0.value] == 1 }
        var uncertainFeeds = Set<String>()
        geometry.appearances = newTracks.keys.sorted().flatMap { id -> [ParticipantAppearance] in
            guard let fresh = newTracks[id] else { return [] }
            let mapped = fresh.map { tile in
                var result = tile
                result.id = retainedTiles[id] ?? id
                result.participantID = tile.participantID.map { retainedFeeds[$0] ?? $0 }
                return result
            }
            guard let oldID = retainedTiles[id], let prior = previousDetections[oldID] else { return mapped }
            return Self.applyingReview(prior, to: mapped, uncertainFeeds: &uncertainFeeds)
        }
        geometry.scanEvents = geometry.scanEvents.map { event in
            event.remappingTiles { id, time in
                guard let oldID = retainedTiles[id], let prior = previousDetections[oldID] else { return id }
                var first = 0
                var end = prior.count
                while first < end {
                    let middle = first + (end - first) / 2
                    if prior[middle].range.from <= time { first = middle + 1 }
                    else { end = middle }
                }
                return first > 0 ? prior[first - 1].id : oldID
            }.remapping(tiles: [:], feeds: retainedFeeds)
        }
        let retainedIDs = Set(geometry.appearances.map(\.id)).intersection(oldTracks.keys)
        let removedIDs = Set(oldTracks.keys).subtracting(retainedIDs)
        let removedOverrides = overrides.filter { removedIDs.contains($0.appearanceID) }
        let changedGeometry = !removedIDs.isEmpty || retainedTiles.count < newTracks.count || !sameSource || !sameLayout
        var affected = Set(previous.unresolvedParticipantIDs)
        affected.formUnion(uncertainFeeds)
        affected.formUnion(removedIDs.flatMap { oldTracks[$0]?.compactMap(\.participantID) ?? [] })
        affected.formUnion(removedOverrides.map(\.participantID))
        // A saved privacy treatment can target a person previously absent from this recording.
        let renderRedactions = effectiveRedactions.map(\.participantID)
        if changedGeometry { affected.formUnion(renderRedactions) }
        if !sameSource { affected.formUnion(people.map(\.id)) }
        geometry.unresolvedParticipantIDs = affected.sorted()
        geometry.historicalParticipantIDs = historical.isEmpty ? nil : historical.sorted()

        let presentationIDs = render?.shots.flatMap(\.slots).filter { $0.target == .presentation }.map(\.id) ?? []
        let bindings = people.filter { affected.contains($0.id) && ($0.audio != nil || !$0.speakers.isEmpty) }.map(\.id)
        let review = ParticipantReconciliation(sourceID: sourceID, sourceChanged: !sameSource && !digestMatches,
            retainedCopiedGeometry: false,
            removedAppearanceIDs: removedIDs.sorted(), affectedParticipantIDs: affected.sorted(),
            affectedRedactionIDs: renderRedactions.filter(affected.contains).sorted(),
            affectedBindingIDs: bindings.sorted(),
            affectedPresentationIDs: Set(presentationIDs).intersection(removedIDs).sorted(),
            removedOverrideCount: removedOverrides.count, previous: previous, previousOverrides: overrides,
            analysisIdentity: scan.analysisIdentity)
        let eventFeeds = geometry.scanEvents.flatMap { event in
            (event.feedID.map { [$0] } ?? []) + (event.candidates ?? []).map(\.feedID)
        }
        let referencedPeople = Set(geometry.appearances.compactMap(\.participantID) + eventFeeds)
        let newPeople = replacement.people.filter { referencedPeople.contains($0.id) }
        return .init(review: review, index: index, geometry: geometry, newPeople: newPeople, removedIDs: removedIDs)
    }

    /// A split or range-specific link may give a detector tile several edited
    /// IDs. A shared slot joins disjoint pieces for matching the whole path.
    private static func detectorPaths(_ tracks: [String: [ParticipantAppearance]]) -> [String: [ParticipantAppearance]] {
        var paths = tracks
        let grouped = Dictionary(grouping: tracks.keys) { id -> String? in
            guard let segments = tracks[id], let slot = segments.first?.slotID,
                  segments.allSatisfy({ $0.slotID == slot }) else { return nil }
            return slot
        }
        for (slot, ids) in grouped where slot != nil && ids.count > 1 {
            let segments = ids.flatMap { tracks[$0] ?? [] }.sorted { $0.range.from < $1.range.from }
            guard let id = segments.first?.id,
                  zip(segments, segments.dropFirst()).allSatisfy({ $0.range.to <= $1.range.from }) else { continue }
            for piece in ids { paths.removeValue(forKey: piece) }
            paths[id] = segments
        }
        return paths
    }

    private static func matchTiles(_ prior: [String: [ParticipantAppearance]],
                                   _ fresh: [String: [ParticipantAppearance]]) -> [String: String] {
        struct Track {
            let id: String
            let start: RationalTime
            let end: RationalTime
            let replacement: Bool
        }
        func tracks(_ source: [String: [ParticipantAppearance]], replacement: Bool) -> [Track] {
            source.compactMap { id, segments in
                guard let start = segments.first?.range.from, let end = segments.last?.range.to else { return nil }
                return Track(id: id, start: start, end: end, replacement: replacement)
            }
        }
        var activePrior: [String: RationalTime] = [:]
        var activeFresh: [String: RationalTime] = [:]
        var priorCandidates: [String: [String]] = [:]
        var replacementCounts: [String: Int] = [:]
        func compare(_ oldID: String, _ newID: String) {
            guard let old = prior[oldID], let new = fresh[newID], sameTile(old, new) else { return }
            priorCandidates[newID, default: []].append(oldID)
            replacementCounts[oldID, default: 0] += 1
        }
        // Consider each pair once, when the second track begins. The active
        // tracks stay bounded by a frame's layout even on long recordings.
        for track in (tracks(prior, replacement: false) + tracks(fresh, replacement: true))
            .sorted(by: { $0.start < $1.start }) {
            activePrior = activePrior.filter { $0.value > track.start }
            activeFresh = activeFresh.filter { $0.value > track.start }
            if track.replacement {
                for id in activePrior.keys { compare(id, track.id) }
                activeFresh[track.id] = track.end
            } else {
                for id in activeFresh.keys { compare(track.id, id) }
                activePrior[track.id] = track.end
            }
        }
        return priorCandidates.compactMapValues { candidates in
            guard candidates.count == 1, let id = candidates.first, replacementCounts[id] == 1 else { return nil }
            return id
        }
    }

    private static func sameTile(_ prior: [ParticipantAppearance], _ fresh: [ParticipantAppearance]) -> Bool {
        guard let oldStart = prior.first?.range.from, let oldEnd = prior.last?.range.to,
              let newStart = fresh.first?.range.from, let newEnd = fresh.last?.range.to,
              oldStart < newEnd, newStart < oldEnd else { return false }
        var support = 0.0
        intersect(prior, fresh) { old, new, range in
            if boundsAgree(old, new) {
                support += range.to.seconds - range.from.seconds
            }
        }
        let length = min(oldEnd.seconds - oldStart.seconds, newEnd.seconds - newStart.seconds)
        return support > 0 && support >= length * 0.6
    }

    private static func boundsAgree(_ prior: ParticipantAppearance, _ fresh: ParticipantAppearance) -> Bool {
        let old = (prior.detectedBounds ?? prior.bounds).rect
        let new = fresh.bounds.rect
        let common = old.intersection(new)
        guard !common.isEmpty else { return false }
        let shared = common.width * common.height
        return shared >= 0.65 * (old.width * old.height + new.width * new.height - shared)
    }

    private static func intersect(_ prior: [ParticipantAppearance], _ fresh: [ParticipantAppearance],
                                  visit: (ParticipantAppearance, ParticipantAppearance, MulticamRange) -> Void) {
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < prior.count && newIndex < fresh.count {
            let old = prior[oldIndex]
            let new = fresh[newIndex]
            let start = max(old.range.from, new.range.from)
            let stop = min(old.range.to, new.range.to)
            if start < stop { visit(old, new, .init(from: start, to: stop)) }
            if old.range.to <= new.range.to { oldIndex += 1 }
            if new.range.to <= old.range.to { newIndex += 1 }
        }
    }

    private static func applyingReview(_ prior: [ParticipantAppearance], to fresh: [ParticipantAppearance],
                                       uncertainFeeds: inout Set<String>) -> [ParticipantAppearance] {
        var result: [ParticipantAppearance] = []
        var oldIndex = 0
        var corroborated: [String: Double] = [:]
        func append(_ tile: ParticipantAppearance, from start: RationalTime, to end: RationalTime) {
            guard start < end else { return }
            var segment = tile
            segment.range = .init(from: start, to: end)
            if var last = result.last, last.range.to == start {
                last.range = segment.range
                if last == segment {
                    result[result.count - 1].range.to = end
                    return
                }
            }
            result.append(segment)
        }
        for tile in fresh {
            var start = tile.range.from
            while oldIndex < prior.count {
                let old = prior[oldIndex]
                if old.range.to <= start {
                    oldIndex += 1
                    continue
                }
                if old.range.from >= tile.range.to { break }
                append(tile, from: start, to: old.range.from)
                var reviewed = tile
                reviewed.id = old.id
                reviewed.labelBounds = old.labelBounds
                reviewed.slotID = old.slotID
                if old.detectedBounds != nil {
                    reviewed.bounds = old.bounds
                    reviewed.detectedBounds = tile.bounds
                }
                if old.reviewedIdentity == true {
                    reviewed.participantID = old.participantID
                    reviewed.reviewedIdentity = true
                }
                if old.reviewedPresentation == true {
                    reviewed.state = old.state
                    reviewed.role = old.role
                    reviewed.reviewedPresentation = true
                }
                let from = max(start, old.range.from)
                start = min(tile.range.to, old.range.to)
                if let feed = old.participantID, reviewed.participantID == feed, boundsAgree(old, tile) {
                    corroborated[feed, default: 0] += start.seconds - from.seconds
                }
                append(reviewed, from: from, to: start)
                if start == tile.range.to { break }
                oldIndex += 1
            }
            append(tile, from: start, to: tile.range.to)
        }
        var previouslyLinked: [String: Double] = [:]
        for tile in prior {
            if let feed = tile.participantID {
                previouslyLinked[feed, default: 0] += tile.range.to.seconds - tile.range.from.seconds
            }
        }
        for (feed, duration) in previouslyLinked where corroborated[feed, default: 0] + 0.000_001 < duration {
            uncertainFeeds.insert(feed)
        }
        return result
    }
}
