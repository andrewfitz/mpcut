import Foundation

// The timeline tier: the best mode that writes the whole timeline. It is found by asking the planners
// of ExportRules.tierSteps in order, so the tier, the export matrix and the alternatives share one source.
// Names, modes and the written tables live in ExportRules.swift.

/// How much of a timeline has to be encoded to export it. Declared best first, and compared so that a better tier is greater.
public enum FidelityTier: String, CaseIterable, Codable, Comparable, Sendable {
    case trueLossless = "true_lossless", lossless, reencode

    private var order: Int {
        switch self {
        case .reencode: return 0
        case .lossless: return 1
        case .trueLossless: return 2
        }
    }
    public static func < (a: FidelityTier, b: FidelityTier) -> Bool { a.order < b.order }
}

/// What a factor leaves at best, for the written table. The tier itself always comes from the planners.
public enum TierFactorEffect: Sendable {
    case lossless, reencode, unavailable, container

    public var summary: String {
        switch self {
        case .lossless: return ExportRules.displayName(tier: .lossless)
        case .reencode: return ExportRules.displayName(tier: .reencode)
        case .unavailable: return ExportRules.tierUnavailableName
        case .container: return "the same tier in another container"
        }
    }
}

/// Stable ids of the reasons a better mode does not plan. Failures carry one as `reason`.
public enum TierFactorID: String, CaseIterable, Codable, Sendable {
    case cutVideoStart = "cut_video_start"
    case cutVideoEnd = "cut_video_end"
    case cutOffFrame = "cut_off_frame"
    case cutAudioPacket = "cut_audio_packet"
    case cutAudioPriming = "cut_audio_priming"
    case cutAudioSample = "cut_audio_sample"
    case cutAACCoverage = "cut_aac_coverage"
    case cutPCMSampleClock = "cut_pcm_sample_clock"
    case cutOpusWindow = "cut_opus_window"
    case cutMP3Crop = "cut_mp3_crop"
    case joinDecoderHistory = "join_decoder_history"
    case joinVideoDTSOverlap = "join_video_dts_overlap"
    case joinSmartOpenGOP = "join_smart_open_gop"
    case joinStreamMismatch = "join_stream_mismatch"
    case joinMediaType = "join_media_type"
    case joinDynamicRange = "join_dynamic_range"
    case joinTimecode = "join_timecode"
    case sourceUnsupportedTracks = "source_unsupported_tracks"
    case sourceSmartIneligible = "source_smart_ineligible"
    case sourceMultipleDescriptions = "source_multiple_descriptions"
    case sourceStartUnsafe = "source_start_unsafe"
    case sourceTimeline = "source_timeline"
    case sourceEncodeUnsupported = "source_encode_unsupported"
    case sourceChanged = "source_changed"
    case outputContainer = "output_container"
    case selectionTracks = "selection_tracks"
    case placementPicture = "placement_picture"
    case placementSilence = "placement_silence"
    case writerOther = "writer_other"

    /// What the factor is about: one cut, the join of two clips, a source, the output or the selection.
    public var scope: String { String(rawValue.prefix { $0 != "_" }) }

    public var effect: TierFactorEffect {
        switch self {
        case .cutVideoStart, .cutVideoEnd, .joinVideoDTSOverlap, .cutAudioSample, .placementPicture, .placementSilence: return .lossless
        case .cutAudioPacket, .cutAudioPriming, .cutAACCoverage, .cutPCMSampleClock, .cutOpusWindow, .cutMP3Crop,
             .joinDecoderHistory, .joinSmartOpenGOP, .joinTimecode, .sourceUnsupportedTracks, .sourceSmartIneligible, .sourceStartUnsafe,
             .joinStreamMismatch:
            return .reencode
        case .sourceMultipleDescriptions, .outputContainer: return .container
        case .cutOffFrame, .joinMediaType, .joinDynamicRange, .sourceTimeline, .sourceEncodeUnsupported, .sourceChanged,
             .selectionTracks, .writerOther:
            return .unavailable
        }
    }

    /// True when failures of this kind list verified times to cut at instead.
    public var offersNearest: Bool {
        switch self {
        case .cutVideoStart, .cutVideoEnd, .cutOffFrame, .cutAudioPacket, .cutAudioSample, .joinVideoDTSOverlap: return true
        default: return false
        }
    }

    public var summary: String {
        switch self {
        case .cutVideoStart: return "The first frame needs an earlier frame to decode. Smart Trim re-encodes the start of the clip."
        case .cutVideoEnd: return "Frames near the end of the clip depend on frames past the cut. Smart Trim re-encodes the end of the clip."
        case .cutOffFrame: return "The cut falls between video frames."
        case .cutAudioPacket: return "A cut falls inside a compressed audio packet, or the picture and a sound track share no boundary there."
        case .cutAudioPriming: return "The clip starts in the audio track’s encoder delay, before the first audible sample."
        case .cutAudioSample: return "A cut falls between audio samples."
        case .cutAACCoverage: return "An AAC track does not cover the cut with continuous, audible samples."
        case .cutPCMSampleClock: return "A PCM track cannot place the cut on its sample clock in this container."
        case .cutOpusWindow: return "An Opus track cannot keep the requested start or end within its trim window."
        case .cutMP3Crop: return "An MP3 track cannot be cropped to the range with gapless timing."
        case .joinDecoderHistory: return "The audio decoder needs samples from before the join. It can copy one continuous range."
        case .joinVideoDTSOverlap: return "The two ranges overlap in video decode time at the join."
        case .joinSmartOpenGOP: return "Frames in this open GOP depend on frames from an earlier group of pictures. Smart Trim has no verified keyframe where it can resume copying."
        case .joinStreamMismatch: return "These clips use different codecs, frame formats, timing or audio formats. Use Re-encode to export them together."
        case .joinMediaType: return "The timeline contains both video clips and audio-only recordings."
        case .joinDynamicRange: return "MPCut can’t combine HDR with SDR, or PQ with HLG. Export them separately."
        case .joinTimecode: return "The timecode track cannot be rewritten for these ranges. A re-encode omits it."
        case .sourceUnsupportedTracks: return "The source has tracks or timing a copy cannot write."
        case .sourceSmartIneligible: return "Smart Trim cannot encode this picture format at cut edges, so it copies on verified boundaries only."
        case .sourceMultipleDescriptions: return "The source uses several video sample descriptions and needs MOV or MP4."
        case .sourceStartUnsafe: return "The source cannot be copied from its first picture."
        case .sourceTimeline: return "The source timeline is unsupported."
        case .sourceEncodeUnsupported: return "The encoder cannot read or keep this source's picture, timing or sound."
        case .sourceChanged: return "A source file changed since it was indexed."
        case .outputContainer: return "The container cannot carry these tracks or cuts."
        case .selectionTracks: return "These tracks or settings aren’t available for this source."
        case .placementPicture: return "A visible still needs generated picture samples."
        case .placementSilence: return "An inserted still needs generated silence."
        case .writerOther: return "MPCut couldn’t prepare or write the export."
        }
    }

    /// The factor a failure stands for when its throw site names none.
    public static func of(code: String) -> TierFactorID {
        switch code {
        case "incompatible_clip": return .joinStreamMismatch
        case "unsupported_timecode": return .joinTimecode
        case "unsafe_smart_join": return .joinSmartOpenGOP
        case "unsupported_tracks": return .sourceUnsupportedTracks
        case "unsupported_timeline": return .sourceTimeline
        case "unsupported_container": return .outputContainer
        case "invalid_frame_boundary": return .cutOffFrame
        case "unsupported_format", "unsupported_timing", "unsupported_audio", "audio_copy_unavailable", "encoder_unavailable",
             "helper_unavailable":
            return .sourceEncodeUnsupported
        case "source_changed": return .sourceChanged
        case "no_video", "no_audio", "invalid_arguments": return .selectionTracks
        default: return .writerOther
        }
    }
}

extension CutError {
    /// The tier factor of this failure: the one its throw site named, or the one its code stands for.
    public var factor: TierFactorID { reason ?? TierFactorID.of(code: code) }

    /// The failure with its factor written out, as programs read it.
    public var reasoned: CutError { because(factor) }
}

/// One reason a better mode does not plan, located on the timeline.
public struct TierFactor: Codable, Equatable, Sendable {
    public let id: TierFactorID
    /// The best tier this factor leaves. Nil when it stops every mode.
    public let forces: FidelityTier?
    /// One-based clip number, when the factor belongs to a clip.
    public let segment: Int?
    /// "from" or "to", when it belongs to one edge.
    public let boundary: String?
    public let track: Int?
    public let message: String
    /// Verified times that could replace the cut.
    public let nearest: [RationalTime]?
    /// The multicam switch that a `nearest` time can replace, in group time. Absent unless the cut is a switch.
    public let switchAt: RationalTime?
    /// The multicam assembly range edge that a `nearest` time can replace. Absent at a switch.
    public let edge: MulticamEdge?

    private enum CodingKeys: String, CodingKey {
        case id, forces, segment, boundary, track, message, nearest, edge
        case switchAt = "switch_group_time"
    }

    public init(_ issue: CutError, forces: FidelityTier?) {
        id = issue.factor
        self.forces = forces
        segment = issue.segment
        boundary = issue.boundary
        track = issue.track
        message = issue.message
        nearest = issue.nearest
        switchAt = issue.multicamAt
        edge = issue.multicam?.edge
    }

    public init(id: TierFactorID, forces: FidelityTier?, segment: Int? = nil, boundary: String? = nil, track: Int? = nil,
                message: String, nearest: [RationalTime]? = nil, switchAt: RationalTime? = nil, edge: MulticamEdge? = nil) {
        self.id = id
        self.forces = forces
        self.segment = segment
        self.boundary = boundary
        self.track = track
        self.message = message
        self.nearest = nearest
        self.switchAt = switchAt
        self.edge = edge
    }
}

public enum TierState: Sendable {
    /// A source is still being indexed, or the check was cancelled.
    case checking
    case known(tier: FidelityTier, factors: [TierFactor], container: String, warnings: [String])
    /// No mode writes the timeline.
    case unavailable(CutError)

    public var tier: FidelityTier? {
        if case .known(let tier, _, _, _) = self { return tier }
        return nil
    }
    public var factors: [TierFactor] {
        switch self {
        case .checking: return []
        case .known(_, let factors, _, _): return factors
        case .unavailable(let issue): return [TierFactor(issue, forces: nil)]
        }
    }
    /// True when there are more factors than the list shows.
    public var hasUnlistedFactors: Bool {
        if case .known(_, _, _, let warnings) = self { return warnings.contains { $0.hasSuffix(TimelineTierEvaluator.unlistedSuffix) } }
        return false
    }
    public var name: String {
        switch self {
        case .checking: return ExportRules.tierCheckingName
        case .known(let tier, _, _, _): return ExportRules.displayName(tier: tier)
        case .unavailable: return ExportRules.tierUnavailableName
        }
    }
}

/// A way to raise the tier: the arguments to ask for, and the clips with their cuts moved when they map one to one.
public struct TierRaise: Codable, Equatable, Sendable {
    public let tier: FidelityTier
    public let name: String
    public let arguments: [String]
    public let clips: [ExportAlternative.Clip]?
}

/// The tier as programs read it.
public struct TierSummary: Codable, Equatable, Sendable {
    /// A tier id, `checking` or `unavailable`.
    public let id: String
    public let name: String
    public let mode: ExportMode?
    public let container: String?
    public let factors: [TierFactor]
    public let raise: [TierRaise]
    public let warnings: [String]
}

/// Evaluates the tier of a timeline. One evaluator serves one editor or one command: it keeps the boundary sets of
/// the sources between evaluations, so an edit costs one planning pass per mode that has to be asked.
public final class TimelineTierEvaluator: @unchecked Sendable {
    public static let factorLimit = 20
    static let unlistedSuffix = "not listed."

    private struct Key: Hashable {
        struct Clip: Hashable {
            let file: URL
            let from: RationalTime?
            let to: RationalTime?
        }
        let clips: [Clip]
        let identities: [SourceIdentity]
        let kind: ExportSourceKind
        let preferred: String?
    }

    private let lock = NSLock()
    private let useSidecar: Bool
    // The boundary cache does not record whether Smart Trim asked, and Smart Trim accepts every frame.
    // Each mode keeps its own, so a frame-accurate set is never read by the copy planner.
    private var caches: [ExportMode: CutEngine.BoundaryCache] = [:]
    private var identities: [URL: SourceIdentity] = [:]
    private var inspected: [URL: MediaInfo] = [:]
    private var memo: [(key: Key, state: TierState)] = []
    private var preferred: String?

    public init(useSidecar: Bool = true) {
        self.useSidecar = useSidecar
    }

    /// The container the caller's exports prefer. The tier reports it when the timeline verifies in it and otherwise
    /// the first container that verifies: the rule the export sheet opens by (`ExportPlanner.openingContainer`).
    /// It never changes the tier, only the container named with it. A command has none.
    public var preferredContainer: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return preferred
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            preferred = newValue
        }
    }

    /// The tier of `clips`. `media` holds the indexes the caller has; a missing one is read here.
    /// `source` is found from the first clip when nil.
    public func evaluate(_ clips: [ClipRequest], media: [URL: MediaInfo] = [:], source: ExportSourceKind? = nil,
                         cancelled: (@Sendable () -> Bool)? = nil) -> TierState {
        lock.lock()
        defer { lock.unlock() }
        return state(clips, media: media, source: source, cancelled: cancelled).state
    }

    /// The clips with their cuts moved to the nearest verified times so that the timeline reaches `tier`,
    /// when every clip keeps its place and joined ranges stay joined. Nil when there is no such timeline.
    public func snapped(_ clips: [ClipRequest], media: [URL: MediaInfo] = [:], to tier: FidelityTier,
                        source: ExportSourceKind? = nil, cancelled: (@Sendable () -> Bool)? = nil) -> [ClipRequest]? {
        lock.lock()
        defer { lock.unlock() }
        return raise(clips, media: media, to: tier, source: source, cancelled: cancelled)?.clips
    }

    /// The tier with what would raise it, as `inspect` and `--dry-run` report it.
    public func summary(_ clips: [ClipRequest], media: [URL: MediaInfo] = [:], source: ExportSourceKind? = nil,
                        cancelled: (@Sendable () -> Bool)? = nil) -> TierSummary {
        summary(clips, media: media, source: source, replacementSources: [], cancelled: cancelled)
    }

    package func summary(_ clips: [ClipRequest], media: [URL: MediaInfo], source: ExportSourceKind? = nil,
                         replacementSources: [URL], cancelled: (@Sendable () -> Bool)?) -> TierSummary {
        lock.lock()
        defer { lock.unlock() }
        let (state, kind) = self.state(clips, media: media, source: source, cancelled: cancelled)
        switch state {
        case .checking:
            return TierSummary(id: "checking", name: state.name, mode: nil, container: nil, factors: [], raise: [], warnings: [])
        case .unavailable:
            return TierSummary(id: "unavailable", name: state.name, mode: nil, container: nil, factors: state.factors, raise: [], warnings: [])
        case .known(let tier, let factors, let container, let warnings):
            var raises: [TierRaise] = []
            for better in FidelityTier.allCases where better > tier {
                if !replacementSources.isEmpty, ExportRules.bestMode(for: better, source: kind) != .copy { continue }
                guard let found = raise(clips, media: media, to: better, source: source, cancelled: cancelled) else { continue }
                raises.append(TierRaise(tier: better, name: ExportRules.displayName(tier: better),
                                        arguments: ExportRules.raiseArguments(to: better, source: kind),
                                        clips: found.clips?.enumerated().map { offset, clip in
                                            let file = replacementSources.indices.contains(offset) ? replacementSources[offset] : clip.file
                                            return .init(file: file.path, from: (clip.from ?? .zero).description, to: clip.to?.description ?? "")
                                        }))
            }
            return TierSummary(id: tier.rawValue, name: state.name, mode: ExportRules.bestMode(for: tier, source: kind),
                               container: container, factors: factors, raise: raises, warnings: warnings)
        }
    }

    // MARK: Evaluation

    private func prepare(_ clips: [ClipRequest], media: [URL: MediaInfo], source: ExportSourceKind?,
                         cancelled: (@Sendable () -> Bool)?) throws -> (media: [URL: MediaInfo], kind: ExportSourceKind, key: Key)? {
        guard !clips.isEmpty else { throw CutError(code: "empty_edit", message: "Add at least one clip before exporting.") }
        var indexed: [URL: MediaInfo] = [:]
        for (file, info) in media { indexed[file.standardizedFileURL] = info }
        var used: [URL: MediaInfo] = [:]
        let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
        for clip in clips {
            try engine.checkCancellation()
            let file = clip.file.standardizedFileURL
            guard used[file] == nil else { continue }
            if let known = indexed[file] {
                // A provisional clip has no cut index yet. Planning it would read the file again.
                guard known.url == file, known.hasFullEditIndex else { return nil }
                try engine.verifyIdentity(file, identity: known.identity)
                used[file] = known
            } else if let earlier = inspected[file], earlier.identity.isCurrentSnapshot(at: file) {
                used[file] = earlier
            } else {
                // Asking for the tier reads. It never leaves a sidecar behind.
                let read = try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                    try AnalysisSidecar.$readsEnabled.withValue(useSidecar && AnalysisSidecar.readsEnabled) {
                        try engine.inspect(file, keyframes: true)
                    }
                }
                inspected[file] = read
                used[file] = read
            }
        }
        for (file, info) in used where identities[file]?.matchesSnapshot(info.identity) != true {
            // Boundary sets belong to one state of the file.
            if identities[file] != nil {
                for mode in caches.keys { caches[mode]?.discard(file) }
                memo.removeAll()
            }
            identities[file] = info.identity
        }
        let first = used[clips[0].file.standardizedFileURL]
        let kind = source ?? (first?.hasVideo == true ? ExportSourceKind.movie : .audio)
        let key = Key(clips: clips.map { .init(file: $0.file.standardizedFileURL, from: $0.from, to: $0.to) },
                      identities: clips.compactMap { used[$0.file.standardizedFileURL]?.identity }, kind: kind,
                      preferred: preferred)
        return (used, kind, key)
    }

    private func state(_ clips: [ClipRequest], media: [URL: MediaInfo], source: ExportSourceKind?,
                       cancelled: (@Sendable () -> Bool)?) -> (state: TierState, kind: ExportSourceKind) {
        let prepared: (media: [URL: MediaInfo], kind: ExportSourceKind, key: Key)
        do {
            guard let ready = try prepare(clips, media: media, source: source, cancelled: cancelled) else {
                return (.checking, source ?? .movie)
            }
            prepared = ready
        } catch let issue as CutError {
            return (issue.code == "cancelled" ? .checking : .unavailable(issue), source ?? .movie)
        } catch {
            return (.unavailable(CutError(code: "probe_failed", message: error.localizedDescription)), source ?? .movie)
        }
        if let found = memo.first(where: { $0.key == prepared.key }) { return (found.state, prepared.kind) }
        guard prepared.kind != .multicam else {
            return (.unavailable(CutError(code: "invalid_arguments", message: "A multicam program is planned by its own engine, which also finds its tier (MulticamEngine.tier).")),
                    prepared.kind)
        }

        let planner = ExportPlanner(cancelled: cancelled, useSidecar: useSidecar)
        let steps = ExportRules.tierSteps(source: prepared.kind)
        var factors: [TierFactor] = []
        var hidden = 0
        var last = CutError(code: "export_failed", message: "No export mode is available.")
        var first: CutError?
        var result: TierState?
        for (position, step) in steps.enumerated() {
            let next = position + 1 < steps.count ? steps[position + 1].tier : nil
            var request = ExportRequest(clips: clips, mode: step.mode, audio: step.audio ?? .auto)
            let soundOnly = prepared.kind == .audio && step.mode == .encode
            let containers: [String?] = step.mode == .encode && !soundOnly
                ? ExportRules.reencodeContainers(request.codec).map { Optional($0) } : [nil]
            var failure: CutError?
            for container in containers {
                request.container = container
                do {
                    var cache = caches[step.mode] ?? CutEngine.BoundaryCache()
                    defer { caches[step.mode] = cache }
                    let verdict = try planner.verdict(request, preferring: preferred, media: prepared.media, boundaries: &cache)
                    result = .known(tier: step.tier, factors: Self.listed(factors, hidden: hidden).factors, container: verdict.container,
                                    warnings: verdict.warnings + Self.listed(factors, hidden: hidden).notes)
                } catch let issue as CutError {
                    if issue.code == "cancelled" { return (.checking, prepared.kind) }
                    if issue.code == "source_changed" { return (.unavailable(issue), prepared.kind) }
                    if soundOnly, issue.code == "helper_unavailable" || issue.code == "encoder_unavailable", let action = step.audio {
                        // The helper is asked at export. Everything about the timeline itself was checked before it.
                        result = .known(tier: step.tier, factors: Self.listed(factors, hidden: hidden).factors,
                                        container: ExportRules.conversionContainers(action).first ?? "",
                                        warnings: [issue.message] + Self.listed(factors, hidden: hidden).notes)
                    } else if failure == nil {
                        failure = issue
                    }
                } catch {
                    if failure == nil { failure = CutError(code: "export_failed", message: error.localizedDescription) }
                }
                if result != nil { break }
            }
            if result != nil { break }
            guard let failure else { continue }
            last = failure
            if first == nil { first = failure }
            // Every cut this mode refuses, then the planner's own failure, which may be about a join or a source.
            var found: [CutError] = []
            if step.mode != .encode, prepared.kind == .movie {
                var cache = caches[step.mode] ?? CutEngine.BoundaryCache()
                let engine = CutEngine(cancelled: cancelled, smartTrim: step.mode == .smart, useSidecar: useSidecar)
                let scan = engine.boundaryIssues(clips, media: prepared.media, boundaries: &cache, limit: Self.factorLimit)
                caches[step.mode] = cache
                found = scan.issues
                hidden += max(0, scan.total - scan.issues.count)
                if step.mode == .smart, let container = scan.container, let first = prepared.media[clips[0].file.standardizedFileURL],
                   !engine.smartTrimEligible(in: first, container: container) {
                    factors.removeAll { $0.id == .sourceSmartIneligible }
                    factors.append(TierFactor(id: .sourceSmartIneligible, forces: next, message: TierFactorID.sourceSmartIneligible.summary))
                }
            }
            if !found.contains(where: { $0.factor == failure.factor && $0.segment == failure.segment && $0.boundary == failure.boundary }) {
                found.insert(failure, at: 0)
            }
            for issue in found {
                var factor = TierFactor(issue, forces: next)
                if factor.id == .joinStreamMismatch, let segment = factor.segment, clips.indices.contains(segment - 1),
                   let media = prepared.media[clips[segment - 1].file.standardizedFileURL],
                   let reference = prepared.media[clips[0].file.standardizedFileURL] {
                    // The copy planner names the first property it met. The factor names all of them, and the clips.
                    factor = TierFactor(id: factor.id, forces: next, segment: segment,
                                        message: ExportRules.mixedFactorMessage(ExportRules.mixedDifferences(media, from: reference), clip: segment))
                }
                // A later mode that stops at the same cut is the stronger statement about it.
                factors.removeAll { $0.id == factor.id && $0.segment == factor.segment && $0.boundary == factor.boundary }
                factors.append(factor)
            }
        }
        // When the best mode already met something no mode gets past, such as clips that do not match, say that.
        let state = result ?? .unavailable(first.flatMap { $0.factor.effect == .unavailable && $0.factor != .writerOther ? $0 : nil } ?? last)
        if cancelled?() != true {
            memo.append((prepared.key, state))
            if memo.count > 8 { memo.removeFirst() }
        }
        return (state, prepared.kind)
    }

    /// The factors people are shown: the most limiting first, then in timeline order, up to the limit.
    private static func listed(_ factors: [TierFactor], hidden: Int) -> (factors: [TierFactor], notes: [String]) {
        let ordered = factors.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.forces != y.forces { return (x.forces.map { $0 == .reencode ? 0 : 1 } ?? -1) < (y.forces.map { $0 == .reencode ? 0 : 1 } ?? -1) }
            if x.segment != y.segment { return (x.segment ?? 0) < (y.segment ?? 0) }
            return a.offset < b.offset
        }.map(\.element)
        let shown = Array(ordered.prefix(factorLimit))
        let more = hidden + ordered.count - shown.count
        return (shown, more > 0 ? ["\(more) more cut\(more == 1 ? " is" : "s are") \(unlistedSuffix)"] : [])
    }

    private func raise(_ clips: [ClipRequest], media: [URL: MediaInfo], to tier: FidelityTier, source: ExportSourceKind?,
                       cancelled: (@Sendable () -> Bool)?) -> (clips: [ClipRequest]?, container: String)? {
        guard let prepared = try? prepare(clips, media: media, source: source, cancelled: cancelled), prepared.kind != .multicam,
              let step = ExportRules.tierSteps(source: prepared.kind).first(where: { $0.tier == tier }), step.mode != .encode else { return nil }
        var request = ExportRequest(clips: clips, mode: step.mode)
        request.snap = .nearest
        var cache = caches[step.mode] ?? CutEngine.BoundaryCache()
        defer { caches[step.mode] = cache }
        guard let verdict = try? ExportPlanner(cancelled: cancelled, useSidecar: useSidecar)
            .verdict(request, preferring: preferred, media: prepared.media, boundaries: &cache), let edit = verdict.edit else { return nil }
        // The planner plans the pieces of a seamless split as one range. Its moved ends go to the outer clips of the
        // split, and the seams inside stay where they are. A result that does not map back names no moved clips.
        let starts = edit.segments.enumerated().map { offset, segment in
            edit.segments.count == clips.count ? segment.sourceClipIndex ?? offset : segment.sourceClipIndex ?? -1
        }
        guard starts.first == 0, zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }), (starts.last ?? 0) < clips.count else {
            return (nil, verdict.container)
        }
        var moved = clips.map { ClipRequest(file: $0.file, from: $0.from ?? .zero, to: $0.to) }
        for (position, segment) in edit.segments.enumerated() {
            let lower = starts[position], upper = position + 1 < starts.count ? starts[position + 1] : clips.count
            let seams = (lower..<upper).dropFirst().map { clips[$0].from ?? .zero }
            guard clips[lower..<upper].allSatisfy({ $0.file.standardizedFileURL == segment.file.standardizedFileURL }),
                  zip(lower..<upper, (lower..<upper).dropFirst()).allSatisfy({ clips[$0].to == clips[$1].from }),
                  seams.allSatisfy({ $0 > segment.from && $0 < segment.to }) else { return (nil, verdict.container) }
            moved[lower] = ClipRequest(file: clips[lower].file, from: segment.from, to: upper - lower == 1 ? segment.to : clips[lower].to)
            moved[upper - 1] = ClipRequest(file: clips[upper - 1].file, from: moved[upper - 1].from, to: segment.to)
        }
        // A join inside one source must stay a join, or pictures would be dropped or repeated. Each side was moved on
        // its own, so where they disagree both take the closer of the two times that leaves both clips a range.
        for index in clips.indices.dropFirst() {
            let (before, after) = (clips[index - 1], clips[index])
            guard before.file == after.file, let seam = before.to, seam == (after.from ?? .zero),
                  let end = moved[index - 1].to, let start = moved[index].from, end != start else { continue }
            let options = (seam.isCloserToEarlier(min(end, start), than: max(end, start)) ? [min(end, start), max(end, start)]
                                                                                           : [max(end, start), min(end, start)])
                .filter { time in time > (moved[index - 1].from ?? .zero) && (moved[index].to.map { time < $0 } ?? true) }
            guard let joined = options.first else { return (nil, verdict.container) }
            moved[index - 1] = ClipRequest(file: before.file, from: moved[index - 1].from, to: joined)
            moved[index] = ClipRequest(file: after.file, from: joined, to: moved[index].to)
        }
        guard zip(moved, clips).contains(where: { $0.from != ($1.from ?? .zero) || ($1.to != nil && $0.to != $1.to) }) else { return nil }
        guard let reached = state(moved, media: media, source: source, cancelled: cancelled).state.tier, reached >= tier else {
            return (nil, verdict.container)
        }
        return (moved, verdict.container)
    }
}
