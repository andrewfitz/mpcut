import CryptoKit
import Foundation

struct LegacyPresentationOrigin: Codable, Equatable, Sendable {
    var sourceID: String
    let appearanceID: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", appearanceID = "appearance_id", name
    }
}

extension ParticipantProject {
    /// Legacy tiles had an appearance identity but no roster identity for screen
    /// shares. Keep one stable roster identity per recording and appearance.
    func promotingLegacyPresentations(preserving previous: Self? = nil) -> Self {
        struct Track: Hashable {
            let sourceID: String
            let appearanceID: String
        }
        var previousPeople: [Track: ParticipantPerson] = [:]
        for person in previous?.people ?? [] {
            guard let origin = person.legacyPresentation else { continue }
            previousPeople[.init(sourceID: origin.sourceID, appearanceID: origin.appearanceID)] = person
        }
        var result = self
        var usedIDs = Set(people.map(\.id))
        var usedNames = Set(people.map(\.name))
        var nextName = 1
        for index in result.sources.indices {
            var source = result.sources[index]
            var shares: [String: String] = [:]
            var appearances = source.appearances
            for appearanceIndex in appearances.indices {
                let appearance = appearances[appearanceIndex]
                guard appearance.state == .presentation, appearance.participantID == nil else { continue }
                if let id = shares[appearance.id] {
                    appearances[appearanceIndex].participantID = id
                    continue
                }
                let track = Track(sourceID: source.sourceID, appearanceID: appearance.id)
                let key = track.sourceID + "\u{0}" + track.appearanceID
                let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                var id = previousPeople[track]?.id ?? "legacy-share-\(digest)"
                while !usedIDs.insert(id).inserted { id += "-" }
                var name = previousPeople[track]?.legacyPresentation?.name ?? "Screen Share"
                if previousPeople[track] == nil {
                    while !usedNames.insert(name).inserted {
                        nextName += 1
                        name = "Screen Share \(nextName)"
                    }
                } else {
                    usedNames.insert(name)
                }
                var person = ParticipantPerson(id: id, name: name)
                person.legacyPresentation = .init(sourceID: track.sourceID, appearanceID: track.appearanceID, name: name)
                result.people.append(person)
                shares[appearance.id] = id
                appearances[appearanceIndex].participantID = id
            }
            if !shares.isEmpty {
                source.setLegacyPresentationLinks(appearances)
                result.sources[index] = source
            }
        }
        return result
    }

    /// An unedited migrated share can still travel through the appearance-only
    /// legacy wire format. Any use as a feed must remain visible to the caller.
    func demotingLegacyPresentations(plan: ParticipantRenderPlan?) throws -> Self {
        let origins = Dictionary(uniqueKeysWithValues: people.compactMap { person in
            person.legacyPresentation.map { (person.id, $0) }
        })
        let originalTracks = Dictionary(grouping: origins.values, by: \.sourceID)
            .mapValues { Set($0.map(\.appearanceID)) }
        let ids = Set(origins.keys)
        let references = Set((plan?.shots ?? []).flatMap(\.slots).filter { $0.target == .participant }.map(\.id))
        guard references.isDisjoint(with: ids),
              plan?.redactions.allSatisfy({ !ids.contains($0.participantID) }) ?? true,
              plan?.audio.mode != .iso || ids.isDisjoint(with: plan?.audio.ids ?? []),
              appearanceOverrides.allSatisfy({ !ids.contains($0.participantID) }) else {
            throw unsupportedLegacyParticipants("a screen share used as a feed")
        }
        for person in people {
            guard let origin = origins[person.id] else { continue }
            guard person.name == origin.name, person.audio == nil, person.speakers.isEmpty, person.treatment == nil else {
                throw unsupportedLegacyParticipants("an edited screen-share feed")
            }
        }

        var restored: Set<String> = []
        var result = self
        for index in sources.indices {
            let source = sources[index]
            guard ids.isDisjoint(with: source.unresolvedParticipantIDs),
                  source.confirmations?.allSatisfy({ !ids.contains($0.participantID) }) ?? true else {
                throw unsupportedLegacyParticipants("a reviewed screen-share feed")
            }
            var changed = false
            let appearances = try source.appearances.map { appearance in
                let isPresentation = appearance.state == .presentation
                guard let id = appearance.participantID else {
                    if isPresentation, originalTracks[source.sourceID]?.contains(appearance.id) == true {
                        throw unsupportedLegacyParticipants("a screen-share feed partly detached from its tile")
                    }
                    return appearance
                }
                guard let origin = origins[id] else {
                    if isPresentation { throw unsupportedLegacyParticipants("a screen-share feed") }
                    return appearance
                }
                guard isPresentation, origin.sourceID == source.sourceID, origin.appearanceID == appearance.id else {
                    throw unsupportedLegacyParticipants("a screen-share feed linked across tiles")
                }
                changed = true
                restored.insert(id)
                var legacy = appearance
                legacy.participantID = nil
                return legacy
            }
            if changed {
                result.sources[index].setLegacyPresentationLinks(appearances)
            }
            if let historical = source.historicalParticipantIDs {
                let remaining = historical.filter { !ids.contains($0) }
                result.sources[index].historicalParticipantIDs = remaining.isEmpty ? nil : remaining
            }
        }
        guard restored == ids else { throw unsupportedLegacyParticipants("a screen-share feed detached from its original tile") }
        result.people.removeAll { ids.contains($0.id) }
        return result
    }
}

private extension ParticipantSourceGeometry {
    /// Migration adds or removes a roster identity without changing the picture
    /// or invalidating a recording confirmation.
    mutating func setLegacyPresentationLinks(_ revised: [ParticipantAppearance]) {
        let oldHistory = historicalParticipantIDs
        let oldUnresolved = unresolvedParticipantIDs
        let oldConfirmations = confirmations
        appearances = revised
        historicalParticipantIDs = oldHistory
        unresolvedParticipantIDs = oldUnresolved
        confirmations = oldConfirmations
    }
}
