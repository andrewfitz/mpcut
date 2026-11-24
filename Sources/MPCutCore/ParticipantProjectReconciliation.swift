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
}

extension CutProject {
    public mutating func reconcileParticipantAnalysis(_ scan: ParticipantScanResult, sourceID: String,
                                                      relativeTo projectURL: URL,
                                                      reviewed: ParticipantReconciliation, cancelled: () -> Bool = { false }) throws {
        try validateParticipantScanSource(scan, sourceID: sourceID, relativeTo: projectURL, cancelled: cancelled)
        try participants.reconcileAnalysis(scan, sourceID: sourceID, reviewed: reviewed)
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
        let digestMatches = previous.sourceContentSHA256 != nil
            && previous.sourceContentSHA256 == scan.source.contentSHA256
        let digestConflicts = previous.sourceContentSHA256 != nil && scan.source.contentSHA256 != nil && !digestMatches
        let sameSource = !digestConflicts && previous.sourceStamp == scan.source.stamp
            && previous.sourceInode != nil && previous.sourceInode == scan.source.inode
        let sameLayout = (previous.feedLayout ?? .meeting) == scan.configuration.feedLayout
        let retainedCopiedGeometry = sameLayout && digestMatches && !sameSource
        let overrides = appearanceOverrides.filter { $0.sourceID == sourceID }
        if retainedCopiedGeometry {
            geometry.appearances = previous.appearances
            geometry.coverage = previous.coverage
            geometry.unresolvedParticipantIDs = previous.unresolvedParticipantIDs
            let review = ParticipantReconciliation(sourceID: sourceID, sourceChanged: false, retainedCopiedGeometry: true,
                removedAppearanceIDs: [], affectedParticipantIDs: [], affectedRedactionIDs: [], affectedBindingIDs: [],
                affectedPresentationIDs: [], removedOverrideCount: 0, previous: previous, previousOverrides: overrides,
                analysisIdentity: scan.analysisIdentity)
            return .init(review: review, index: index, geometry: geometry, newPeople: [], removedIDs: [])
        }

        let oldTracks = Dictionary(grouping: previous.appearances, by: \.id)
        let newTracks = Dictionary(grouping: geometry.appearances, by: \.id)
        var preserved: [String: [ParticipantAppearance]] = [:]
        if sameSource && sameLayout {
            let oldByGeometry = Dictionary(grouping: oldTracks.values, by: Self.trackGeometry)
            let newByGeometry = Dictionary(grouping: newTracks.values, by: Self.trackGeometry)
            for (shape, prior) in oldByGeometry where prior.count == 1 {
                if let candidates = newByGeometry[shape], candidates.count == 1, let id = candidates[0].first?.id {
                    preserved[id] = prior[0]
                }
            }
        }
        geometry.appearances = newTracks.keys.sorted().flatMap { preserved[$0] ?? newTracks[$0] ?? [] }
        let retainedIDs = Set(preserved.values.compactMap { $0.first?.id })
        let removedIDs = Set(oldTracks.keys).subtracting(retainedIDs)
        let removedOverrides = overrides.filter { removedIDs.contains($0.appearanceID) }
        let changedGeometry = !removedIDs.isEmpty || preserved.count < newTracks.count || !sameSource || !sameLayout
        var affected = Set(previous.unresolvedParticipantIDs)
        if changedGeometry {
            affected.formUnion(previous.appearances.compactMap(\.participantID))
            affected.formUnion(overrides.map(\.participantID))
        }
        // A saved privacy treatment can target a person previously absent from this recording.
        let renderRedactions = render?.redactions.map(\.participantID) ?? []
        if changedGeometry { affected.formUnion(renderRedactions) }
        if !sameSource { affected.formUnion(people.map(\.id)) }
        geometry.unresolvedParticipantIDs = affected.sorted()

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
        let referencedPeople = Set(geometry.appearances.compactMap(\.participantID))
        let newPeople = replacement.people.filter { referencedPeople.contains($0.id) }
        return .init(review: review, index: index, geometry: geometry, newPeople: newPeople, removedIDs: removedIDs)
    }

    /// Match whole tracks on the same recording using exact time and picture evidence.
    private static func trackGeometry(_ appearances: [ParticipantAppearance]) -> [ParticipantAppearance] {
        appearances.sorted { $0.range.from < $1.range.from }.map {
            var appearance = $0
            appearance.id = ""
            appearance.participantID = nil
            appearance.labelBounds = nil
            appearance.slotID = nil
            return appearance
        }
    }
}
