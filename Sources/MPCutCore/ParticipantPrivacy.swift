import CryptoKit
import Foundation

/// An explicit review of this feed over a half-open interval of the accepted recording.
public struct ParticipantPrivacyConfirmation: Codable, Hashable, Sendable {
    public let participantID: String
    public let range: MulticamRange
    let analysisIdentity: String?
    let sourceStamp: SceneSourceStamp?
    let sourceInode: UInt64?
    let reviewDigest: String?

    private enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
        case range
        case analysisIdentity = "analysis_identity"
        case sourceStamp = "source_stamp"
        case sourceInode = "source_inode"
        case reviewDigest = "review_digest"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        participantID = try values.decode(String.self, forKey: .participantID)
        range = try values.decode(MulticamRange.self, forKey: .range)
        analysisIdentity = try values.decodeIfPresent(String.self, forKey: .analysisIdentity)
        sourceStamp = try values.decodeIfPresent(SceneSourceStamp.self, forKey: .sourceStamp)
        sourceInode = try values.decodeIfPresent(UInt64.self, forKey: .sourceInode)
        reviewDigest = try values.decodeIfPresent(String.self, forKey: .reviewDigest)
    }

    init(participantID: String, range: MulticamRange, source: ParticipantSourceGeometry, reviewDigest: String) {
        self.participantID = participantID
        self.range = range
        self.analysisIdentity = source.analysisIdentity
        self.sourceStamp = source.sourceStamp
        self.sourceInode = source.sourceInode
        self.reviewDigest = reviewDigest
    }

    func matches(_ source: ParticipantSourceGeometry) -> Bool {
        analysisIdentity == source.analysisIdentity && sourceStamp == source.sourceStamp && sourceInode == source.sourceInode
    }
}

func verifiedParticipantPrivacyDigest(_ media: MediaInfo, cancelled: () -> Bool) throws -> String {
    let cache = AnalysisSidecar.readsEnabled ? AnalysisSidecar(source: media.url, identity: media.identity) : nil
    if let digest = cachedParticipantSourceDigest(media.identity, in: cache, cancelled: cancelled) { return digest }
    let digest = try participantSourceDigest(media.url, identity: media.identity, cancelled: cancelled)
    cache?.saveAutomatically([media.identity.participantDigestSection: Data(digest.utf8)],
                             retainingLatest: ["participant_content_sha256.v1.": 2], cancelled: cancelled)
    return digest
}

extension ParticipantSourceGeometry {
    private func hasVerifiedCoverage(through end: RationalTime) -> Bool {
        var next = RationalTime.zero
        for coverage in coverage.sorted(by: { $0.range.from < $1.range.from }) where coverage.range.to > next {
            guard coverage.range.from <= next, coverage.state == .verified else { return false }
            next = coverage.range.to
            if next >= end { return true }
        }
        return false
    }

    fileprivate func verifiesCompleteAbsence(of participantID: String, through end: RationalTime) -> Bool {
        guard sourceStamp != nil, sourceInode != nil, sourceContentSHA256 != nil,
              unresolvedParticipantIDs.contains(participantID), hasVerifiedCoverage(through: end) else { return false }
        return appearances.allSatisfy { tile in
            tile.participantID != participantID && tile.participantID != nil && !tile.hasUnresolvedIdentity
        }
    }

    func privacyUnconfirmedRanges(participantID: String, range: MulticamRange,
                                  confirmations: [ParticipantPrivacyConfirmation]) -> [MulticamRange] {
        let located = appearances.filter { $0.participantID == participantID && !$0.hasUnresolvedIdentity }
            .map(\.range).sorted { $0.from < $1.from }
        let confirmed = confirmations.filter { $0.participantID == participantID }.map(\.range).sorted { $0.from < $1.from }
        var reviewed: [MulticamRange] = []
        var first = 0
        for interval in located {
            while first < confirmed.count, confirmed[first].to <= interval.from { first += 1 }
            var index = first
            while index < confirmed.count, confirmed[index].from < interval.to {
                reviewed.append(.init(from: max(confirmed[index].from, interval.from), to: min(confirmed[index].to, interval.to)))
                index += 1
            }
        }
        var unconfirmed: [MulticamRange] = []
        var start = range.from
        for confirmed in reviewed.sorted(by: { $0.from < $1.from }) where confirmed.to > start {
            guard confirmed.from < range.to else { break }
            if start < confirmed.from { unconfirmed.append(.init(from: start, to: confirmed.from)) }
            start = max(start, confirmed.to)
        }
        if start < range.to { unconfirmed.append(.init(from: start, to: range.to)) }
        return unconfirmed
    }

    /// Remember the previous scope and treat the loss of an assigned region as an open identity issue.
    /// Box corrections and splits that still show the same feed in the same pixels preserve the assignment.
    mutating func recordPrivacyHistory(previousAppearances: [ParticipantAppearance]) {
        struct Assignment: Hashable {
            let id: String
            let role: ParticipantAppearance.Role
            let bounds: ParticipantBounds
        }

        let previousIDs = Set(previousAppearances.compactMap(\.participantID))
        let history = previousIDs.union(historicalParticipantIDs ?? []).sorted()
        historicalParticipantIDs = history.isEmpty ? nil : history

        struct Track: Hashable {
            let participantID: String
            let tileID: String
        }

        func joinedRanges(_ segments: [ParticipantAppearance]) -> [MulticamRange] {
            var ranges: [MulticamRange] = []
            for range in segments.map(\.range).sorted(by: { $0.from < $1.from }) {
                if let last = ranges.indices.last, range.from <= ranges[last].to {
                    ranges[last].to = max(range.to, ranges[last].to)
                } else {
                    ranges.append(range)
                }
            }
            return ranges
        }

        // The track keeps its identity when the editor adjusts its box.
        // A split can change the track ID while keeping the same region and feed.
        let current = appearances.filter { $0.participantID != nil }
        let tracks = Dictionary(grouping: current) { Track(participantID: $0.participantID!, tileID: $0.id) }
            .mapValues(joinedRanges)
        let regions = Dictionary(grouping: current) {
            Assignment(id: $0.participantID!, role: $0.role, bounds: $0.bounds)
        }.mapValues(joinedRanges)
        var pending = Set(unresolvedParticipantIDs)
        func covers(_ range: MulticamRange, in segments: [MulticamRange]) -> Bool {
            let index = segments.lowerBound { $0.to > range.from }
            return segments.indices.contains(index) && segments[index].from <= range.from && segments[index].to >= range.to
        }
        for appearance in previousAppearances {
            guard let id = appearance.participantID, !pending.contains(id) else { continue }
            if covers(appearance.range, in: tracks[Track(participantID: id, tileID: appearance.id)] ?? []) { continue }
            let region = Assignment(id: id, role: appearance.role, bounds: appearance.bounds)
            if covers(appearance.range, in: regions[region] ?? []) { continue }
            pending.insert(id)
        }
        unresolvedParticipantIDs = pending.sorted()
    }
}

extension ParticipantProject {
    private func privacyGeometryDigest(_ source: ParticipantSourceGeometry) throws -> String {
        struct Geometry: Encodable {
            let contentSHA256: String?
            let feedLayout: ParticipantFeedLayout?
            let appearances: [ParticipantAppearance]
            let coverage: [ParticipantCoverage]
            let unresolved: [String]
            let historical: [String]?
            let events: [ParticipantTileScanEvent]
            let preferences: [ParticipantAppearanceOverride]
        }

        // The revision is durable across save/reopen, including edits to the saved JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let preferences = appearanceOverrides.filter { $0.sourceID == source.sourceID }.map { preference in
            var local = preference
            local.sourceID = ""
            return local
        }
        let geometry = Geometry(contentSHA256: source.sourceContentSHA256, feedLayout: source.feedLayout,
                                appearances: source.appearances, coverage: source.coverage,
                                unresolved: source.unresolvedParticipantIDs, historical: source.historicalParticipantIDs,
                                events: source.scanEvents, preferences: preferences)
        return Self.privacyDigest(try encoder.encode(geometry))
    }

    private static func privacyDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func privacyReviewDigest(_ geometry: String, treatment: ParticipantRedaction?) -> String {
        guard let treatment else { return geometry }
        return privacyDigest(Data("\(geometry):\(treatment.treatment.rawValue):\(treatment.color)".utf8))
    }

    func currentPrivacyConfirmations(for source: ParticipantSourceGeometry, treatments: [String: ParticipantRedaction]) throws
        -> [ParticipantPrivacyConfirmation] {
        guard source.sourceStamp != nil, source.sourceInode != nil,
              let saved = source.confirmations, !saved.isEmpty else { return [] }
        let geometry = try privacyGeometryDigest(source)
        var digests: [String: String] = [:]
        return saved.filter { confirmation in
            guard confirmation.matches(source) else { return false }
            let id = confirmation.participantID
            let digest = digests[id] ?? Self.privacyReviewDigest(geometry, treatment: treatments[id])
            digests[id] = digest
            return confirmation.reviewDigest == digest
        }
    }

    public mutating func confirmPrivacy(sourceID: String, participantID: String, range: MulticamRange) throws {
        guard range.from >= .zero, range.from < range.to, people.contains(where: { $0.id == participantID }),
              let index = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Choose a feed, a reviewed recording and a nonempty source range.")
        }
        var source = sources[index]
        let treatments = Dictionary(effectiveRedactions.map { ($0.participantID, $0) }, uniquingKeysWith: { first, _ in first })
        let earlier = try currentPrivacyConfirmations(for: source, treatments: treatments)
        let digest = try Self.privacyReviewDigest(privacyGeometryDigest(source), treatment: treatments[participantID])
        let reviewed = (earlier.filter { $0.participantID == participantID }.map(\.range) + [range])
            .sorted { $0.from < $1.from }
        var joined: [MulticamRange] = []
        for interval in reviewed {
            if let last = joined.indices.last, interval.from <= joined[last].to {
                joined[last].to = max(joined[last].to, interval.to)
            } else {
                joined.append(interval)
            }
        }
        source.confirmations = (earlier.filter { $0.participantID != participantID }
            + joined.map { ParticipantPrivacyConfirmation(participantID: participantID, range: $0, source: source,
                                                            reviewDigest: digest) })
            .sorted {
                $0.participantID == $1.participantID ? $0.range.from < $1.range.from : $0.participantID < $1.participantID
            }
        sources[index] = source
    }
}

extension CutProject {
    public mutating func confirmParticipantPrivacy(sourceID: String, participantID: String, range: MulticamRange? = nil,
                                                  relativeTo document: URL, cancelled: (@Sendable () -> Bool)? = nil) throws {
        let file = try participantRecording(sourceID, relativeTo: document)
        let media = try CutEngine(cancelled: cancelled, tracks: .video).inspectSummary(file)
        guard !participants.needsReconciliation(sourceID: sourceID, identity: media.identity) else {
            throw invalidParticipantProject("The recording changed. Reconcile it before confirming reviewed footage.")
        }
        let range = range ?? .init(from: .zero, to: media.duration)
        guard media.hasVideo, range.to <= media.duration else {
            throw invalidParticipantProject("The reviewed range must fit inside the recording.")
        }
        guard let index = participants.sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Choose an accepted recording.")
        }
        var updated = participants
        let digest = try verifiedParticipantPrivacyDigest(media, cancelled: cancelled ?? { false })
        if let expected = updated.sources[index].sourceContentSHA256, digest != expected {
            throw invalidParticipantProject("The recording changed. Reconcile it before confirming reviewed footage.")
        }
        guard media.identity.isCurrentSnapshot(at: media.url) else {
            throw invalidParticipantProject("The recording changed while confirming reviewed footage.")
        }
        if range.from == .zero, range.to == media.duration,
           updated.sources[index].verifiesCompleteAbsence(of: participantID, through: media.duration) {
            try updated.confirmReconciledParticipant(sourceID: sourceID, participantID: participantID)
            participants = updated
            return
        }
        if updated.sources[index].sourceStamp == nil {
            updated.sources[index].sourceStamp = SceneSourceStamp(media: media)
        }
        if updated.sources[index].sourceInode == nil {
            updated.sources[index].sourceInode = media.identity.inode
        }
        updated.sources[index].sourceContentSHA256 = digest
        try updated.confirmPrivacy(sourceID: sourceID, participantID: participantID, range: range)
        participants = updated
    }
}
