import CryptoKit
import Foundation

public struct TilesISOIssue: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public var range: MulticamRange? = nil
    public var sourceTime: RationalTime? = nil
    public var blocking: Bool = true
    public var tileID: String? = nil
    public var feedID: String? = nil
    /// Issues that one link of the whole tile resolves share a group.
    public var groupID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case code, message, range, blocking
        case sourceTime = "source_time", tileID = "tile_id", feedID = "feed_id", groupID = "group_id"
    }

    public init(code: String, message: String, range: MulticamRange? = nil,
                sourceTime: RationalTime? = nil, blocking: Bool = true, tileID: String? = nil, feedID: String? = nil,
                groupID: String? = nil) {
        self.code = code
        self.message = message
        self.range = range
        self.sourceTime = sourceTime ?? range?.from
        self.blocking = blocking
        self.tileID = tileID
        self.feedID = feedID
        self.groupID = groupID
    }
}

public struct TilesISOPlan: Codable, Sendable {
    public struct Feed: Codable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let filename: String
        public let visible: [MulticamRange]
        public let gaps: [MulticamRange]
        public let microphone: ParticipantAudioBinding?
        public let voices: [ParticipantSpeakerBinding]
        public let audioTracks: Int

        private enum CodingKeys: String, CodingKey {
            case id = "feed_id", name, filename, visible, gaps, microphone, voices
            case audioTracks = "audio_tracks"
        }

        var published: Self {
            .init(id: id, name: name, filename: filename, visible: visible, gaps: gaps,
                  microphone: nil, voices: [], audioTracks: audioTracks)
        }
    }

    public struct WithheldFeed: Codable, Sendable {
        public let id: String
        public let treatment: ParticipantMaskTreatment?
        public let reason: String

        private enum CodingKeys: String, CodingKey { case id = "feed_id", treatment, reason }
    }

    public let schemaVersion: Int
    public let projectPath: String
    public let projectRevision: String
    public let sourceID: String
    public let sourcePath: String
    public let sourceFingerprint: String
    public let feedCount: Int
    public let maxVisibleTiles: Int
    public let range: MulticamRange
    public let duration: RationalTime
    public let canvas: ParticipantCanvas
    public let framing: ParticipantSlotFraming
    public let keepCameraOff: Bool
    public let blankUncertain: Bool
    public let audio: ParticipantMulticamAudioRouting
    public let meetingMix: [StillSoundAction]
    public let feeds: [Feed]
    public let withheld: [WithheldFeed]
    public let issues: [TilesISOIssue]
    public let estimatedBytes: Int64
    public let requiresReview: Bool
    let provenance: String
    let allFeeds: Bool
    let countHints: TilesCountHints?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", projectPath = "project_path", projectRevision = "project_revision"
        case sourceID = "source_id", sourcePath = "source_path", sourceFingerprint = "source_fingerprint", range, duration, canvas, framing, audio
        case feedCount = "feed_count", maxVisibleTiles = "max_visible_tiles"
        case keepCameraOff = "keep_camera_off", blankUncertain = "blank_uncertain", meetingMix = "meeting_mix"
        case feeds, withheld, issues, estimatedBytes = "estimated_bytes", requiresReview = "requires_review", provenance
        case allFeeds = "all_feeds", countHints = "count_hints"
    }
}

public enum TilesISODelivery {
    public static func plan(project: CutProject, document: URL, sourceID: String? = nil,
                            feedIDs: [String]? = nil, range: MulticamRange? = nil,
                            canvas: ParticipantCanvas? = nil, width: Int? = nil, height: Int? = nil,
                            frameRate: RationalTime? = nil, gapColor: UInt32? = nil,
                            framing: ParticipantSlotFraming = .fit, keepCameraOff: Bool = true,
                            blankUncertain: Bool = false, audio: ParticipantMulticamAudioRouting = .init(includeISOs: true),
                            countHints: TilesCountHints? = nil,
                            cancelled: (@Sendable () -> Bool)? = nil) throws -> TilesISOPlan {
        try prepare(project: project, document: document, sourceID: sourceID, feedIDs: feedIDs,
                    range: range, canvas: canvas, width: width, height: height, frameRate: frameRate,
                    gapColor: gapColor, framing: framing, keepCameraOff: keepCameraOff, blankUncertain: blankUncertain,
                    audio: audio, countHints: countHints, cancelled: cancelled).plan
    }

    struct Prepared {
        let plan: TilesISOPlan
        let source: CutProject
        let gallery: URL
        let identity: SourceIdentity
        let videoStream: Int
        let mix: StillSoundPlan?
        let mixFingerprint: String?
        let entries: [Entry]
        let blanks: [MulticamRange]
        let snapshots: [URL: SourceIdentity]
        let usedAudio: Set<URL>
        let sharedPicture: ParticipantSharedPictureInputs
    }

    struct Entry {
        let feed: TilesISOPlan.Feed
        let renderPlan: ParticipantRenderPlan
        let fingerprint: String
    }

    private struct RecordedIdentity: Encodable {
        let identity: SourceIdentity
        let contentSHA256: String
        let changeSeconds: Int?
        let changeNanoseconds: Int?

        init(_ identity: SourceIdentity, contentSHA256: String) {
            self.identity = identity
            self.contentSHA256 = contentSHA256
            changeSeconds = identity.changeTime?.seconds
            changeNanoseconds = identity.changeTime?.nanoseconds
        }
    }

    private struct RenderInput: Encodable {
        let renderRevision: Int
        let source: RecordedIdentity
        let videoStream: Int
        let range: MulticamRange
        let displacement: RationalTime
        let geometry: String
        let preferences: [ParticipantAppearanceOverride]
        let plan: ParticipantRenderPlan
        let colorPolicy: StillProgramColorPolicy?
        let privacyIssues: [ParticipantPrivacyIssue]
        let audioActions: [StillSoundAction]
        let audioSources: [String: RecordedIdentity]
        let blanks: [MulticamRange]
    }

    private struct SoundInput: Encodable {
        let renderRevision: Int
        let duration: RationalTime
        let actions: [StillSoundAction]
        let identities: [String: RecordedIdentity]
    }

    struct Provenance: Encodable {
        let entries: [String]
        let mix: String?
    }

    static func prepare(project: CutProject, document: URL, sourceID: String?, feedIDs: [String]?,
                        range: MulticamRange?, canvas: ParticipantCanvas?, width: Int? = nil, height: Int? = nil,
                        frameRate: RationalTime? = nil, gapColor: UInt32? = nil,
                        framing: ParticipantSlotFraming, keepCameraOff: Bool,
                        blankUncertain: Bool, audio: ParticipantMulticamAudioRouting, countHints: TilesCountHints?,
                        expectedSourceFingerprint: String? = nil,
                        cancelled: (@Sendable () -> Bool)?) throws -> Prepared {
        let engine = CutEngine(cancelled: cancelled, tracks: .video)
        try engine.checkCancellation()
        try project.validate()
        let roster = project.participants
        guard let sourceID = sourceID ?? (roster.sources.count == 1 ? roster.sources.first?.sourceID : nil),
              let geometry = roster.sources.first(where: { $0.sourceID == sourceID }) else {
            throw invalid("Choose a recording with accepted tiles using --source-id.")
        }
        let multicam: MulticamProject?
        if case .multicam(let value) = project { multicam = value } else { multicam = nil }
        let recording = multicam?.pictureSources.first { $0.id == sourceID }
        let gallery = try CutProject.checkedMediaURL(recording?.file ?? sourceID, relativeTo: document)
        let media: MediaInfo
        do { media = try engine.inspectSummary(gallery) }
        catch where expectedSourceFingerprint != nil {
            try engine.checkCancellation()
            throw CutError(code: "stale_iso_plan", message: "The recording can no longer be read as planned.")
        }
        let sourceContent = try contentDigest(gallery, identity: media.identity, cancelled: cancelled)
        let sourceIdentity = RecordedIdentity(media.identity, contentSHA256: sourceContent)
        let sourceFingerprint = try digest(sourceIdentity)
        guard expectedSourceFingerprint.map({ $0 == sourceFingerprint }) ?? true else {
            throw CutError(code: "stale_iso_plan", message: "The recording changed after planning.")
        }
        guard let video = media.videoStream else { throw invalid("The recording has no picture.") }
        let range = try range ?? defaultRange(multicam: multicam, recording: recording, media: media)
        let excerpt = try ParticipantMulticam.excerpt(project, document: document, sourceID: sourceID,
                                                    range: range, cancelled: cancelled)
        let timeline = try excerpt.project.resolveStills()
        let duration = timeline.duration
        let displacement = try recording.map { try $0.offset.adding(media.multicamSourceOffset) } ?? .zero
        var canvas = canvas ?? .init(width: max(2, video.displayWidth / 2 * 2),
                                     height: max(2, video.displayHeight / 2 * 2),
                                     frameRate: video.frameRate > .zero ? video.frameRate : .init(numerator: 30))
        if let width { canvas.width = width }
        if let height { canvas.height = height }
        if let frameRate { canvas.frameRate = frameRate }
        if let gapColor { canvas.background = gapColor }
        try ParticipantRenderPlan(canvas: canvas, shots: [.init(layout: .original)]).validate()

        let visibleFeedIDs = Set(geometry.appearances.compactMap(\.participantID))
        let sourceFeedIDs = visibleFeedIDs.union(geometry.unresolvedParticipantIDs)
        let available = roster.people.filter { sourceFeedIDs.contains($0.id) }
        let requested = Set(feedIDs ?? available.map(\.id))
        guard feedIDs.map({ $0.count == requested.count }) ?? true,
              requested.isSubset(of: sourceFeedIDs) else { throw invalid("Choose unique feed IDs on this recording.") }
        let redactions = roster.effectiveRedactions
        let privacyPolicy = roster.tileOutput?.unresolvedPrivacy ?? roster.render?.unresolvedPrivacy ?? .stop
        let hidden = Dictionary(uniqueKeysWithValues: redactions.filter { $0.treatment != .blur }.map { ($0.participantID, $0.treatment) })
        let withheld: [TilesISOPlan.WithheldFeed] = available.compactMap { person in
            if let treatment = hidden[person.id] {
                return .init(id: person.id, treatment: treatment, reason: "treatment")
            }
            return requested.contains(person.id) ? nil : .init(id: person.id, treatment: nil, reason: "excluded")
        }
        if feedIDs != nil, !requested.isDisjoint(with: hidden.keys) {
            throw invalid("A covered or removed feed cannot be selected for ISO export.")
        }

        let reviewHints = countHints.map {
            TilesCountHints(expectedFeeds: $0.expectedFeeds ?? geometry.countHints?.expectedFeeds,
                            maxVisibleTiles: $0.maxVisibleTiles ?? geometry.countHints?.maxVisibleTiles)
        }
        let review = TilesReview(project: project, sourceID: sourceID, document: document, countHints: reviewHints,
                                 sourceClockOrigin: media.multicamSourceOffset)
        var issues: [TilesISOIssue] = review.issues.compactMap { issue in
            let code: String
            switch issue.kind {
            case .unassignedTile: code = "unassigned_tiles"
            case .ambiguousMatch: code = "unresolved_feeds"
            case .countMismatch: code = issue.id == "count-feeds" ? "feed_count_mismatch" : "visible_tile_limit"
            case .layoutChange, .uncheckedRange, .changedSource: return nil
            }
            let span = issue.range.flatMap { overlap($0, range) }
            if issue.range != nil && span == nil { return nil }
            return .init(code: code, message: issue.message, range: span,
                         sourceTime: issue.sourceTime.flatMap { range.contains($0) ? $0 : nil } ?? span?.from, tileID: issue.tileID, feedID: issue.feedID,
                         groupID: issue.groupID)
        }
        let unresolvedWithEvidence = Set(issues.filter { $0.code == "unresolved_feeds" }.compactMap(\.feedID))
        for id in geometry.unresolvedParticipantIDs
        where !unresolvedWithEvidence.contains(id) && !visibleFeedIDs.contains(id) {
            issues.append(.init(code: "unresolved_feeds", message: "Review an unresolved feed identity.", feedID: id))
        }
        let staleSource = roster.needsReconciliation(sourceID: sourceID, identity: media.identity)
            || geometry.sourceContentSHA256.map { $0 != sourceContent } == true
        if staleSource {
            issues.append(.init(code: "source_changed", message: "The recording changed after its tiles were accepted.", range: range))
        }
        let blanks = blankUncertain ? unite(issues.filter { $0.blocking && $0.code != "source_changed" }.compactMap(\.range)) : []
        let snapshots = ParticipantMulticam.snapshots(in: excerpt.project, document: document)
        var soundIdentities = [String: RecordedIdentity]()
        func identities(for actions: [StillSoundAction]) throws -> [String: RecordedIdentity] {
            var result = [String: RecordedIdentity]()
            for file in Set(actions.flatMap { $0.sources.map { $0.file.standardizedFileURL } }) {
                guard let identity = snapshots[file], identity.isCurrentSnapshot(at: file) else {
                    throw CutError(code: "source_changed", message: "Audio source changed while planning ISOs: \(file.path)")
                }
                let cached = soundIdentities[file.path]
                let digest = try cached?.contentSHA256 ?? (identity.matchesSnapshot(media.identity)
                    ? sourceContent : contentDigest(file, identity: identity, cancelled: cancelled))
                let recorded = cached ?? RecordedIdentity(identity, contentSHA256: digest)
                soundIdentities[file.path] = recorded
                result[file.path] = recorded
            }
            return result
        }
        // With no embedded or explicitly designated meeting audio, the program soundtrack
        // could be the microphone of a feed excluded from this delivery.
        let hasMeetingAudio = audio.meetingAudio != nil || media.streams.contains { $0.kind == "audio" }
        let mix = audio.meetingMix && hasMeetingAudio && !staleSource ? try ParticipantMulticam.meetingMix(in: excerpt.project, galleryID: sourceID,
            document: document, timeline: timeline, binding: audio.meetingAudio, cancelled: cancelled) : nil
        if let mix, !mix.actions.isEmpty, !redactions.isEmpty || !withheld.isEmpty {
            issues.append(.init(code: "shared_mix", message: "The shared audio can carry voices from treated or withheld feeds.", blocking: false))
        }
        let renderRevision = 4
        let mixFingerprint = try mix.flatMap { sound in
            sound.actions.isEmpty ? nil : try digest(SoundInput(renderRevision: renderRevision, duration: duration,
                actions: sound.actions, identities: identities(for: sound.actions)))
        }
        let renderer = ParticipantRenderer(cancelled: cancelled)
        var entries: [Entry] = []
        var privacy = Set<MulticamRange>()
        var usedAudio = Set<URL>()
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        let selected = feedIDs.map { $0.compactMap { byID[$0] } } ?? available
        let candidates = selected.filter { hidden[$0.id] == nil }
        let candidateIDs = Set(candidates.map(\.id))
        let sharedPicture = ParticipantSharedPictureInputs(slots: candidateIDs, privacyDigests: [gallery: sourceContent])
        let cropIndex = try sharedPicture.geometry(roster, sourceID: sourceID, slots: candidateIDs,
                                                   control: JPEGControl(cancelled ?? { false }))
        let appearancesByFeed = Dictionary(grouping: geometry.appearances, by: \.participantID)
        func pictureFingerprint(_ appearances: [ParticipantAppearance], includePrivacy: Bool) throws -> String {
            try digest(ParticipantSourceGeometry(sourceID: geometry.sourceID, analysisIdentity: geometry.analysisIdentity,
                sourceStamp: geometry.sourceStamp, sourceInode: geometry.sourceInode,
                sourceContentSHA256: geometry.sourceContentSHA256, feedLayout: geometry.feedLayout, appearances: appearances,
                coverage: includePrivacy ? geometry.coverage : [],
                unresolvedParticipantIDs: includePrivacy ? geometry.unresolvedParticipantIDs : [],
                historicalParticipantIDs: includePrivacy ? geometry.historicalParticipantIDs : nil,
                confirmations: includePrivacy ? geometry.confirmations : nil))
        }
        let protectedPicture = redactions.isEmpty ? nil : try pictureFingerprint(geometry.appearances, includePrivacy: true)

        for person in candidates {
            try engine.checkCancellation()
            let angle = ParticipantVirtualAngle(id: person.id, name: person.name, sourceID: sourceID, range: range)
            let sound = ParticipantMulticam.iso(for: angle, in: excerpt.project, routing: audio)
            let renderPlan = ParticipantRenderPlan(canvas: canvas, shots: [.init(layout: .solo, slots: [
                .init(id: person.id, framing: framing, includeCameraOff: keepCameraOff)
            ])], audio: sound, redactions: redactions,
                unresolvedPrivacy: blankUncertain ? .cover : privacyPolicy)
            let report = staleSource ? nil
                : try renderer.report(excerpt.project, document: document, plan: renderPlan,
                                      settings: .init(audio: .auto), sharedInputs: sharedPicture)
            let actions = report?.audioActions ?? []
            let actualSources = try identities(for: actions)
            usedAudio.formUnion(actualSources.keys.map { URL(fileURLWithPath: $0) })
            privacy.formUnion(report?.privacyIssues.map(\.source) ?? [])
            let appearances = appearancesByFeed[person.id] ?? []
            let visible = unite(cropIndex.visibleRanges(for: person.id, includeCameraOff: keepCameraOff, in: range))
            let feed = TilesISOPlan.Feed(id: person.id, name: person.name, filename: try filename(person),
                                         visible: visible, gaps: gaps(in: range, occupied: visible),
                                         microphone: actions.isEmpty ? nil : roster.audioBinding(for: person.id), voices: person.speakers,
                                         audioTracks: actions.count)
            let picture = try protectedPicture ?? pictureFingerprint(appearances, includePrivacy: false)
            let preferences = roster.appearanceOverrides.filter {
                $0.sourceID == sourceID && $0.participantID == person.id
            }
            let fingerprint = try digest(RenderInput(renderRevision: renderRevision, source: sourceIdentity,
                videoStream: video.index, range: range, displacement: displacement,
                geometry: picture, preferences: preferences, plan: renderPlan, colorPolicy: excerpt.project.programColorPolicy,
                privacyIssues: report?.privacyIssues ?? [], audioActions: actions,
                audioSources: actualSources, blanks: blanks))
            entries.append(.init(feed: feed, renderPlan: renderPlan, fingerprint: fingerprint))
        }
        for span in unite(Array(privacy)) {
            issues.append(.init(code: "unchecked_privacy", message: "Check the source interval before publishing.", range: span,
                                blocking: privacyPolicy == .stop))
        }
        if entries.isEmpty {
            issues.append(.init(code: "no_feeds", message: "No eligible feeds are selected for ISO export."))
        }
        if blankUncertain {
            for index in issues.indices where issues[index].range != nil && issues[index].code != "source_changed" {
                issues[index].blocking = false
            }
        }
        let plan = TilesISOPlan(schemaVersion: 1, projectPath: document.standardizedFileURL.path, projectRevision: try digest(project),
            sourceID: sourceID, sourcePath: gallery.path, sourceFingerprint: sourceFingerprint,
            feedCount: review.counts.feedCount, maxVisibleTiles: review.counts.maxVisibleTiles, range: range, duration: duration, canvas: canvas,
            framing: framing, keepCameraOff: keepCameraOff, blankUncertain: blankUncertain, audio: audio,
            meetingMix: mix?.actions ?? [], feeds: entries.map(\.feed), withheld: withheld, issues: issues,
            estimatedBytes: estimate(canvas: canvas, duration: duration, feedCount: entries.count, mix: mixFingerprint != nil),
            requiresReview: issues.contains(where: \.blocking),
            provenance: try digest(Provenance(entries: entries.map(\.fingerprint), mix: mixFingerprint)),
            allFeeds: feedIDs == nil, countHints: countHints)
        try engine.verifyIdentity(gallery, identity: media.identity)
        try ParticipantMulticam.verifyISOs(usedAudio, against: snapshots)
        try mix?.verifySources()
        return .init(plan: plan, source: excerpt.project, gallery: gallery, identity: media.identity, videoStream: video.index, mix: mix,
                     mixFingerprint: mixFingerprint, entries: entries, blanks: blanks, snapshots: snapshots, usedAudio: usedAudio,
                     sharedPicture: sharedPicture)
    }

    private static func defaultRange(multicam: MulticamProject?, recording: MulticamSource?, media: MediaInfo) throws -> MulticamRange {
        guard let multicam, let recording else { return .init(from: .zero, to: media.duration) }
        let offset = try recording.offset.adding(media.multicamSourceOffset)
        return .init(from: max(.zero, try max(multicam.range.from, recording.coverage?.from ?? multicam.range.from).subtracting(offset)),
                     to: min(media.duration, try min(multicam.range.to, recording.coverage?.to ?? multicam.range.to).subtracting(offset)))
    }

    private static func contentDigest(_ file: URL, identity: SourceIdentity, cancelled: (() -> Bool)?) throws -> String {
        let cancelled = cancelled ?? { false }
        let cache = AnalysisSidecar.readsEnabled ? AnalysisSidecar(source: file, identity: identity) : nil
        if let cached = cachedParticipantSourceDigest(identity, in: cache, cancelled: cancelled) { return cached }
        let digest = try participantSourceDigest(file, identity: identity, cancelled: cancelled)
        cache?.saveAutomatically([identity.participantDigestSection: Data(digest.utf8)],
                                 retainingLatest: ["participant_content_sha256.v1.": 2], cancelled: cancelled)
        return digest
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hex(SHA256.hash(data: try encoder.encode(value)))
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func filename(_ person: ParticipantPerson) throws -> String {
        let safe = person.name.lowercased().utf8.prefix(64).map { byte -> Character in
            switch byte {
            case 97...122, 48...57: Character(UnicodeScalar(byte))
            default: "-"
            }
        }
        let name = String(safe).split(separator: "-").joined(separator: "-")
        let suffix = try digest(person.id).prefix(20)
        return "\(name.isEmpty ? "feed" : name)-\(suffix).mov"
    }

    private static func estimate(canvas: ParticipantCanvas, duration: RationalTime, feedCount: Int, mix: Bool) -> Int64 {
        let video = Double(ParticipantPictureWriter.bitRate(canvas, quality: .balanced)) / 8
        let bytes = duration.seconds * (Double(feedCount) * (video + 192_000) + (mix ? 192_000 : 0))
        guard bytes.isFinite, bytes < Double(Int64.max) else { return Int64.max }
        return Int64(max(0, bytes))
    }

    static func unite(_ intervals: [MulticamRange]) -> [MulticamRange] {
        var merged: [MulticamRange] = []
        for interval in intervals.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
            if let last = merged.last, interval.from <= last.to {
                merged[merged.count - 1].to = max(last.to, interval.to)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func overlap(_ a: MulticamRange, _ b: MulticamRange) -> MulticamRange? {
        let start = max(a.from, b.from)
        let end = min(a.to, b.to)
        return start < end ? .init(from: start, to: end) : nil
    }

    private static func gaps(in range: MulticamRange, occupied: [MulticamRange]) -> [MulticamRange] {
        var start = range.from
        var result: [MulticamRange] = []
        for interval in occupied {
            if interval.from > start { result.append(.init(from: start, to: interval.from)) }
            start = interval.to
        }
        if start < range.to { result.append(.init(from: start, to: range.to)) }
        return result
    }

    static func invalid(_ message: String) -> CutError {
        .init(code: "invalid_iso_delivery", message: message)
    }
}
