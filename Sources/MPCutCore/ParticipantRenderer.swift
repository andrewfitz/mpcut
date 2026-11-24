import AVFoundation
import CoreImage
import Foundation

public struct ParticipantRenderer: Sendable {
    let cancelled: (@Sendable () -> Bool)?
    private let legacyWholeFramePrivacy: Bool
    private let allowsOriginal: Bool

    public init(cancelled: (@Sendable () -> Bool)? = nil) {
        self.init(cancelled: cancelled, legacyWholeFramePrivacy: false)
    }

    package init(cancelled: (@Sendable () -> Bool)?, legacyWholeFramePrivacy: Bool, allowsOriginal: Bool = false) {
        self.cancelled = cancelled
        self.legacyWholeFramePrivacy = legacyWholeFramePrivacy
        self.allowsOriginal = allowsOriginal
    }

    public func report(_ project: CutProject, document: URL, plan: ParticipantRenderPlan? = nil,
                       output: URL? = nil, settings: ReencodeSettings = .init(audio: .pcm),
                       range: MulticamRange? = nil, audioOutput: MulticamAudioOutput? = nil) throws -> ParticipantRenderReport {
        try report(project, document: document, plan: plan, output: output, settings: settings, range: range,
                   audioOutput: audioOutput, sharedInputs: nil)
    }

    func report(_ project: CutProject, document: URL, plan: ParticipantRenderPlan? = nil,
                output: URL? = nil, settings: ReencodeSettings = .init(audio: .pcm),
                range: MulticamRange? = nil, audioOutput: MulticamAudioOutput? = nil,
                sharedInputs: ParticipantSharedPictureInputs?) throws -> ParticipantRenderReport {
        if let output { try project.validateDestination(output, relativeTo: document) }
        let resolved = try prepare(project, document: document, plan: plan, cancelled: cancelled, range: range,
                                   silenceAudio: settings.audio == .removeAudio, sharedInputs: sharedInputs)
        let sound = try ParticipantRenderSound.resolve(project.participantSound(in: range), document: document, timeline: resolved.timeline.timeline,
                                                       audio: resolved.plan.audio, cancelled: cancelled, action: settings.audio,
                                                       container: output?.pathExtension.lowercased() ?? "mov", audioOutput: audioOutput)
        if let output { try Self.validateDestination(output, hasAudio: false, settings: settings, color: resolved.color) }
        try resolved.verifySources()
        try sound.verifySources()
        return resolved.report(sound: sound)
    }

    @discardableResult
    public func render(_ project: CutProject, document: URL, plan: ParticipantRenderPlan? = nil,
                       to output: URL, settings: ReencodeSettings = .init(audio: .pcm),
                       range: MulticamRange? = nil, audioOutput: MulticamAudioOutput? = nil, progress: ((Double) -> Bool)? = nil) throws -> ParticipantRenderReport {
        let interruption = ParticipantRenderInterruption()
        let isCancelled: @Sendable () -> Bool = { [cancelled] in cancelled?() == true || interruption.stopped }
        func update(_ fraction: Double) -> Bool {
            if progress?(fraction) == false { interruption.stop() }
            return !isCancelled()
        }

        _ = update(0)
        try project.validateDestination(output, relativeTo: document)
        let resolved = try prepare(project, document: document, plan: plan, cancelled: isCancelled, range: range, silenceAudio: settings.audio == .removeAudio)
        let sound = try ParticipantRenderSound.resolve(project.participantSound(in: range), document: document, timeline: resolved.timeline.timeline,
                                                       audio: resolved.plan.audio, cancelled: isCancelled, action: settings.audio,
                                                       container: output.pathExtension.lowercased(), audioOutput: audioOutput)
        try resolved.requirePublishable(sound: sound)
        let container = try Self.validateDestination(output, hasAudio: false, settings: settings, color: resolved.color)
        let staging = try Self.stagingDirectory(for: output)
        defer { try? FileManager.default.removeItem(at: staging) }
        let video = staging.appendingPathComponent("picture.mov")
        try resolved.writePicture(to: video, settings: settings) { _ = update($0 * 0.85) }
        return try resolved.publishPicture(video, sound: sound, staging: staging, output: output, container: container,
                                           cancelled: isCancelled, progress: { update(0.85 + $0 * 0.15) })
    }

    static func stagingDirectory(for output: URL) throws -> URL {
        let staging = output.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-participants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return staging
    }

    public func frame(_ project: CutProject, document: URL, plan: ParticipantRenderPlan? = nil,
                      at time: RationalTime) throws -> CGImage {
        let resolved = try prepare(project, document: document, plan: plan, cancelled: cancelled, auditPrivacy: false, forceSDR: true)
        let instant = try resolved.sampleTime(at: time)
        let picture = try resolved.picture(at: instant)
        guard let image = ParticipantCompositor.context.createCGImage(picture, from: resolved.extent, format: .RGBA8,
                                                                       colorSpace: ParticipantCompositor.colorSpace) else {
            throw CutError(code: "frame_export_failed", message: "Could not render the participant composition.")
        }
        try resolved.verifySources()
        return image
    }

    func prepare(_ project: CutProject, document: URL, plan: ParticipantRenderPlan?,
                         cancelled: (@Sendable () -> Bool)?, auditPrivacy: Bool = true, forceSDR: Bool = false, range: MulticamRange? = nil,
                         silenceAudio: Bool = false, sharedInputs: ParticipantSharedPictureInputs? = nil) throws -> ParticipantRenderSession {
        let saved: ParticipantRenderPlan?
        if let sharedInputs {
            saved = try sharedInputs.validatedSavedPlan(project)
        } else {
            saved = try project.tileRenderPlan()
        }
        let fallback = allowsOriginal ? ParticipantRenderPlan(shots: [.init(layout: .original)], audio: .init(mode: .program)) : nil
        let usesSourceCanvas = plan == nil && project.participants.tileOutput == nil
            && project.participants.render == nil && project.stillFormat == nil
        guard var plan = plan ?? saved ?? fallback else {
            throw CutError(code: "missing_participant_plan", message: "Choose a participant shot before rendering.")
        }
        if sharedInputs == nil { try project.validate() }
        // The project treatment belongs to the source and survives one-off shot overrides.
        for mask in saved?.redactions ?? [] {
            if let requested = plan.redactions.first(where: { $0.participantID == mask.participantID }) {
                guard requested == mask else {
                    throw CutError(code: "participant_mask_conflict",
                                   message: "Change the saved treatment for ‘\(mask.participantID)’ before exporting a different mask.")
                }
            } else {
                plan.redactions.append(mask)
            }
        }
        if !legacyWholeFramePrivacy, project.stillFormat != nil { plan.canvas = project.projectOutputSettings.canvas }
        if usesSourceCanvas, let source = try Self.sourceCanvas(project, document: document, cancelled: cancelled) {
            plan.canvas = source
        }
        if silenceAudio { plan.audio = .init() }
        let legacyTreatments = project.participants.render?.redactions ?? []
        let usesLegacyTreatment = plan.redactions.contains(where: legacyTreatments.contains)
        let legacyPrivacy = legacyWholeFramePrivacy || usesLegacyTreatment
        let legacyFormat = legacyWholeFramePrivacy || (project.participants.tileOutput == nil && usesLegacyTreatment)
        try plan.validate(allowNativeLayouts: !legacyFormat)
        return try .init(project: project, document: document, plan: plan, cancelled: cancelled, auditPrivacy: auditPrivacy,
                         forceSDR: forceSDR || legacyWholeFramePrivacy, range: range, sharedInputs: sharedInputs,
                         legacyWholeFramePrivacy: legacyPrivacy)
    }

    private static func sourceCanvas(_ project: CutProject, document: URL,
                                     cancelled: (@Sendable () -> Bool)?) throws -> ParticipantCanvas? {
        let candidates: [String]
        if case .multicam(let multicam) = project {
            candidates = multicam.recordings(for: multicam.referenceAngle).map(\.file)
        } else {
            candidates = project.sequenceClips?.map(\.file) ?? []
        }
        let engine = CutEngine(cancelled: cancelled, tracks: .video)
        var seen: Set<String> = []
        for path in candidates where seen.insert(path).inserted {
            try engine.checkCancellation()
            let file = CutProject.mediaURL(path, relativeTo: document)
            guard let video = try? engine.inspectSummary(file).videoStream,
                  video.displayWidth > 0, video.displayHeight > 0 else { continue }
            let scale = min(1, 8192 / Double(max(video.displayWidth, video.displayHeight)))
            func even(_ dimension: Int) -> Int { max(2, Int((Double(dimension) * scale / 2).rounded()) * 2) }
            let rate = video.frameRate
            let supported = rate > .zero && rate.seconds <= 120 && rate.numerator <= Int64(Int32.max)
            return .init(width: even(video.displayWidth), height: even(video.displayHeight),
                         frameRate: supported ? rate : .init(numerator: 30))
        }
        try engine.checkCancellation()
        return nil
    }

    @discardableResult
    static func validateDestination(_ output: URL, hasAudio: Bool, settings: ReencodeSettings,
                                            color: ParticipantPictureColor) throws -> String {
        let container = output.pathExtension.lowercased()
        guard ExportRules.reencodeContainers(settings.codec).contains(ExportRules.multicamMuxContainer(container)) else {
            throw CutError(code: "unsupported_container", message: "Choose a supported container for \(settings.codec.rawValue).")
        }
        if hasAudio, let issue = ExportRules.reencodeRefusal(audio: .pcm, container: container, source: .movie) {
            throw issue
        }
        try MulticamMux().check(container: ExportRules.multicamMuxContainer(container))
        try ParticipantRenderSession.validateEncoding(settings, color: color)
        try ReencodeEngine().checkDestination(output, container: container)
        return container
    }
}

final class ParticipantRenderInterruption: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}

final class ParticipantRenderSession {
    let plan: ParticipantRenderPlan
    let timeline: ParticipantRenderTimeline
    let control: JPEGControl
    let engine: CutEngine
    let extent: CGRect
    let color: ParticipantPictureColor
    let frameCount: Int64
    let cadence: RationalTime
    let timescale: Int32
    private let cadenceFrameCount: Int64
    private let stillBoundaries: [(index: Int64, time: RationalTime)]
    private let media: [URL: MediaInfo]
    private let stills: [String: StillReviewFrame]
    private let stillCanvas: StillImageCanvas
    private var lastStill: (id: String, image: CIImage)?
    private let geometry: [String: ParticipantGeometryIndex]
    private let stale: Set<String>
    private let pendingIdentities: [String: Set<String>]
    private let legacyWholeFramePrivacy: Bool
    private let privacyScopes: [String: Set<String>]
    private let privacyConfirmations: [String: [String: [ParticipantPrivacyConfirmation]]]
    private let treatments: [String: ParticipantRedaction]
    private let treatmentIndex: Int
    private let unscannedSourceIDs: [String]
    private let pictureInputs: ParticipantSharedPictureInputs
    private lazy var background = ParticipantCompositor.color(plan.canvas.background, in: extent)
    var blankSourceRanges: [MulticamRange] = []
    private var privacyIssues: [ParticipantPrivacyIssue] = []
    private let reportsPrivacyInRenderSummary: Bool

    init(project: CutProject, document: URL, plan: ParticipantRenderPlan, cancelled: (@Sendable () -> Bool)?,
         auditPrivacy: Bool, forceSDR: Bool = false, range: MulticamRange? = nil,
         sharedInputs: ParticipantSharedPictureInputs? = nil, legacyWholeFramePrivacy: Bool = false) throws {
        self.plan = plan
        self.legacyWholeFramePrivacy = legacyWholeFramePrivacy
        self.reportsPrivacyInRenderSummary = auditPrivacy
        let control = JPEGControl(cancelled ?? { false })
        self.control = control
        self.pictureInputs = sharedInputs ?? .init()
        let engine = CutEngine(cancelled: cancelled, tracks: .video)
        self.engine = engine
        let original = try pictureInputs.timeline(project)
        if let range, range.from < .zero || range.to > original.duration || range.from >= range.to {
            throw CutError(code: "invalid_range", message: "Choose a nonempty selection inside the program.")
        }
        timeline = try .init(project: project, document: document, timeline: original, plan: plan,
                             range: range, checkCancellation: control.check)
        let duration = timeline.timeline.duration
        guard duration > .zero else {
            throw CutError(code: "empty_edit", message: "Add a source interval before rendering participants.")
        }
        let length = try duration.multiplied(by: plan.canvas.frameRate)
        let regularFrames = Self.roundingUp(length)
        cadenceFrameCount = regularFrames
        cadence = .init(numerator: plan.canvas.frameRate.denominator, denominator: plan.canvas.frameRate.numerator)
        let boundaries = Set(timeline.timeline.spans.lazy.filter { $0.placementID != nil }
            .flatMap { [$0.output.from, $0.output.to] }).sorted()
        var scale = try Self.movieTimescale(cadence.denominator, duration.denominator)
        var inserted: [(index: Int64, time: RationalTime)] = []
        for boundary in boundaries where .zero < boundary && boundary < duration {
            try control.check()
            let position = try boundary.multiplied(by: plan.canvas.frameRate)
            if position.denominator == 1 { continue }
            let (index, overflow) = Self.roundingUp(position).addingReportingOverflow(Int64(inserted.count))
            guard !overflow else { throw Self.timingError }
            inserted.append((index, boundary))
            scale = try Self.movieTimescale(Int64(scale), boundary.denominator)
        }
        let (count, overflow) = regularFrames.addingReportingOverflow(Int64(inserted.count))
        guard !overflow else { throw Self.timingError }
        frameCount = count
        stillBoundaries = inserted
        _ = try duration.multiplied(by: .init(numerator: Int64(scale)))
        timescale = scale
        extent = .init(x: 0, y: 0, width: plan.canvas.width, height: plan.canvas.height)
        let treatments = Dictionary(uniqueKeysWithValues: plan.redactions.map { ($0.participantID, $0) })
        self.treatments = treatments
        treatmentIndex = pictureInputs.treatmentIndex(treatments)

        var slots = Set(plan.shots.flatMap(\.slots).filter { $0.target == .participant }.map(\.id))
        if case .multicam(let multicam) = project {
            slots.formUnion(multicam.pictureSources.compactMap { $0.feedAngle?.feedID })
        }
        var media: [URL: MediaInfo] = [:]
        var sourceTransfers: [String] = []
        var geometry: [String: ParticipantGeometryIndex] = [:]
        var stale: Set<String> = []
        var conflictingAliases: Set<String> = []
        var acceptedRoutes: [String: ParticipantSourceGeometry] = [:]
        let accepted = Dictionary(uniqueKeysWithValues: project.participants.sources.map { ($0.sourceID, $0) })
        let physicalPaths: [String: String]?
        if case .multicam(let multicam) = project {
            physicalPaths = Dictionary(uniqueKeysWithValues: multicam.pictureSources.filter { $0.feedAngle == nil }
                .map { ($0.id, $0.file) })
        } else {
            physicalPaths = nil
        }
        struct ReviewedSnapshot: Hashable {
            let stamp: SceneSourceStamp
            let inode: UInt64
        }
        var acceptedByRecording: [SourceIdentity: [(ParticipantSourceGeometry, SourceIdentity)]] = [:]
        var acceptedBySnapshot: [ReviewedSnapshot: [ParticipantSourceGeometry]] = [:]
        for source in project.participants.sources {
            try control.check()
            if let stamp = source.sourceStamp, let inode = source.sourceInode {
                acceptedBySnapshot[.init(stamp: stamp, inode: inode), default: []].append(source)
            }
            let path = physicalPaths == nil ? source.sourceID : physicalPaths?[source.sourceID]
            guard let path, let file = try? CutProject.checkedMediaURL(path, relativeTo: document),
                  let identity = try? SourceIdentity(file) else { continue }
            acceptedByRecording[identity, default: []].append((source, identity))
        }
        let allTreated = Set(treatments.keys)
        func scope(_ source: ParticipantSourceGeometry) -> Set<String> {
            if legacyWholeFramePrivacy || source.appearances.contains(where: \.hasUnresolvedIdentity) { return allTreated }
            return Set(source.appearances.compactMap(\.participantID))
                .union(source.historicalParticipantIDs ?? []).union(source.unresolvedParticipantIDs).intersection(allTreated)
        }
        func sameReview(_ lhs: ParticipantSourceGeometry, _ rhs: ParticipantSourceGeometry) -> Bool {
            lhs.sourceStamp == rhs.sourceStamp && lhs.sourceInode == rhs.sourceInode
                && lhs.analysisIdentity == rhs.analysisIdentity && lhs.sourceContentSHA256 == rhs.sourceContentSHA256
                && lhs.feedLayout == rhs.feedLayout && lhs.appearances == rhs.appearances && lhs.coverage == rhs.coverage
                && lhs.scanEvents == rhs.scanEvents && scope(lhs) == scope(rhs)
                && lhs.unresolvedParticipantIDs == rhs.unresolvedParticipantIDs && lhs.confirmations == rhs.confirmations
        }
        for window in timeline.windows {
            try control.check()
            for route in window.routes {
                if media[route.file] == nil {
                    let source = try pictureInputs.source(route.file, engine: engine)
                    guard source.hasVideo, !source.frames.isEmpty, source.video.timeBase > .zero else {
                        throw CutError(code: "missing_picture", message: "Source ‘\(route.id)’ has no indexed video.")
                    }
                    media[route.file] = source
                    sourceTransfers.append(source.video.colorTransfer)
                }
                if geometry[route.id] == nil {
                    let sourceMedia = media[route.file]!
                    let currentAliases = (acceptedByRecording[sourceMedia.identity] ?? []).compactMap { record, identity in
                        identity.matchesSnapshot(sourceMedia.identity) ? record : nil
                    }
                    let candidate = ReviewedSnapshot(stamp: .init(identity: sourceMedia.identity), inode: sourceMedia.identity.inode)
                    let matchedIDs = Set(currentAliases.map(\.sourceID))
                    let savedAliases = (acceptedBySnapshot[candidate] ?? []).filter { !matchedIDs.contains($0.sourceID) }
                    let aliases = currentAliases + savedAliases
                    let protected = aliases.filter {
                        !allTreated.isEmpty && (!scope($0).isEmpty || project.participants.needsReconciliation(
                            sourceID: $0.sourceID, identity: sourceMedia.identity))
                    }
                    let source = accepted[route.id] ?? protected.first ?? aliases.first
                    let geometryID = source?.sourceID ?? route.id
                    geometry[route.id] = try pictureInputs.geometry(project.participants, sourceID: geometryID,
                                                                    slots: slots, control: control)
                    acceptedRoutes[route.id] = source
                    if let source, protected.contains(where: { $0.sourceID != geometryID && !sameReview($0, source) }) {
                        conflictingAliases.insert(route.id)
                    }
                    if project.participants.needsReconciliation(sourceID: geometryID, identity: sourceMedia.identity) {
                        stale.insert(route.id)
                    } else if !treatments.isEmpty, let expected = source?.sourceContentSHA256,
                              try pictureInputs.privacyDigest(sourceMedia, control: control) != expected {
                        stale.insert(route.id)
                    } else if geometryID != route.id, !matchedIDs.contains(geometryID), source?.sourceContentSHA256 == nil,
                              protected.contains(where: { $0.sourceID == geometryID }) {
                        // A detached path and an inode stamp alone cannot verify which bytes were reviewed.
                        stale.insert(route.id)
                    }
                }
            }
        }
        let assets = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0) })
        let placements = Dictionary(uniqueKeysWithValues: project.stillInserts.map { ($0.id, ($0.assetID, $0.framing)) }
            + project.stillReplacements.map { ($0.id, ($0.assetID, $0.framing)) })
        var stills: [String: StillReviewFrame] = [:]
        for span in timeline.timeline.spans {
            guard let id = span.placementID, stills[id] == nil,
                  let (assetID, framing) = placements[id], let asset = assets[assetID] else { continue }
            let frame = try StillReviewFrame(asset: asset, placementID: id, framing: framing, interval: span.output,
                                             document: document, width: plan.canvas.width, height: plan.canvas.height,
                                             displayAspect: Double(plan.canvas.width) / Double(plan.canvas.height))
            try frame.validateAsset(cancelled: control.cancelled)
            stills[id] = frame
        }
        self.stills = stills
        let inferred = sourceTransfers.lazy.map(ParticipantPictureColor.init(transfer:)).first { $0 != .sdr } ?? .sdr
        let canvasColor: ParticipantPictureColor = forceSDR ? .sdr
            : project.programColorPolicy.map { ParticipantPictureColor(transfer: $0.transfer) } ?? inferred
        self.color = canvasColor
        stillCanvas = StillImageCanvas(width: plan.canvas.width, height: plan.canvas.height,
                                       transfer: canvasColor.stillTransfer, primaries: canvasColor == .sdr ? "bt709" : "bt2020",
                                       diffuseWhiteNits: project.programColorPolicy?.diffuseWhiteNits ?? 203)
        self.media = media
        self.geometry = geometry
        self.stale = stale.union(conflictingAliases)
        self.pendingIdentities = acceptedRoutes.mapValues { Set($0.unresolvedParticipantIDs) }
        self.unscannedSourceIDs = allTreated.isEmpty || legacyWholeFramePrivacy ? []
            : geometry.keys.filter { acceptedRoutes[$0]?.analysisIdentity == nil }.sorted()
        var privacyScopes: [String: Set<String>] = [:]
        var privacyConfirmations: [String: [String: [ParticipantPrivacyConfirmation]]] = [:]
        if !allTreated.isEmpty {
            if legacyWholeFramePrivacy {
                for sourceID in geometry.keys { privacyScopes[sourceID] = allTreated }
            }
            for (routeID, source) in acceptedRoutes {
                privacyScopes[routeID] = stale.contains(routeID) || conflictingAliases.contains(routeID) ? allTreated : scope(source)
                let reviewed = try project.participants.currentPrivacyConfirmations(for: source, treatments: treatments)
                privacyConfirmations[routeID] = Dictionary(grouping: reviewed, by: \.participantID)
            }
        }
        self.privacyScopes = privacyScopes
        self.privacyConfirmations = privacyConfirmations
        if auditPrivacy && !treatments.isEmpty { privacyIssues = try audit() }
    }

    func report(sound: StillSoundPlan, output: String? = nil) -> ParticipantRenderReport {
        .init(canvas: plan.canvas, duration: timeline.timeline.duration, frameCount: frameCount, audio: plan.audio,
              audioActions: sound.actions, privacyIssues: privacyIssues,
              publishable: privacyIssues.isEmpty || plan.unresolvedPrivacy == .cover,
              staleSourceIDs: stale.sorted(), unscannedSourceIDs: unscannedSourceIDs.isEmpty ? nil : unscannedSourceIDs, output: output,
              audioPrivacyNotice: treatments.isEmpty || plan.audio.mode == .iso || sound.actions.isEmpty
                ? nil : "Shared audio can still contain speech from treated feeds.")
    }

    func verifySources() throws {
        try control.check()
        for (file, media) in media { try engine.verifyIdentity(file, identity: media.identity) }
        for frame in stills.values { try frame.validateIdentity() }
    }

    func verifySources(at time: RationalTime) throws {
        try control.check()
        if let id = timeline.timeline.span(at: time)?.placementID, let still = stills[id] {
            try still.validateIdentity()
        }
        if let window = timeline.window(at: time) {
            for route in window.routes {
                try engine.verifyIdentity(route.file, identity: media[route.file]!.identity)
            }
        }
    }

    func sampleTime(at time: RationalTime, exact: Bool = false) throws -> RationalTime {
        guard time >= .zero, time <= timeline.timeline.duration else {
            throw CutError(code: "invalid_range", message: "The requested frame is outside the participant program.")
        }
        if exact, time < timeline.timeline.duration { return time }
        let count = try time.multiplied(by: plan.canvas.frameRate)
        let regular = try cadence.multiplied(by: .init(numerator: min(cadenceFrameCount - 1, count.numerator / count.denominator)))
        let inserted = stillBoundaries.lowerBound { $0.time > time } - 1
        return stillBoundaries.indices.contains(inserted) ? max(regular, stillBoundaries[inserted].time) : regular
    }

    func frameTiming(at index: Int64) throws -> (at: RationalTime, length: RationalTime) {
        func start(_ index: Int64) throws -> RationalTime {
            if index == frameCount { return timeline.timeline.duration }
            let insertion = stillBoundaries.lowerBound { $0.index >= index }
            if stillBoundaries.indices.contains(insertion), stillBoundaries[insertion].index == index {
                return stillBoundaries[insertion].time
            }
            return try cadence.multiplied(by: .init(numerator: index - Int64(insertion)))
        }
        let at = try start(index)
        return try (at, start(index + 1).subtracting(at))
    }

    private static func roundingUp(_ time: RationalTime) -> Int64 {
        time.numerator / time.denominator + (time.numerator % time.denominator == 0 ? 0 : 1)
    }

    private static var timingError: CutError {
        CutError(code: "unsupported_participant_timing", message: "The canvas cadence and edit boundaries need a finer movie clock.")
    }

    private static func movieTimescale(_ a: Int64, _ b: Int64) throws -> Int32 {
        var lhs = a
        var rhs = b
        while rhs != 0 { (lhs, rhs) = (rhs, lhs % rhs) }
        let (rate, overflow) = (a / lhs).multipliedReportingOverflow(by: b)
        guard !overflow, let scale = Int32(exactly: rate) else {
            throw timingError
        }
        return scale
    }

    private func audit() throws -> [ParticipantPrivacyIssue] {
        var issues: [String: [ParticipantPrivacyIssue]] = [:]
        for window in timeline.windows {
            try control.check()
            for route in window.routes {
                let indexed = media[route.file]!
                let displacement = try relativeDisplacement(route)
                let sourceFrom = max(.zero, try window.range.from.adding(displacement))
                let sourceTo = try window.range.to.adding(displacement)
                guard sourceFrom < sourceTo else { continue }
                let low = max(0, indexed.frames.lowerBound { $0.time >= sourceFrom } - 1)
                let high = indexed.frames.lowerBound { $0.time >= sourceTo }
                for index in low..<high {
                    if index.isMultiple(of: 1_024) { try control.check() }
                    let frame = indexed.frames[index]
                    let from = max(sourceFrom, frame.time)
                    let to = min(sourceTo, indexed.duration, try frame.time.adding(frame.duration))
                    guard from < to, needsCover(route: route, index: index, window: window) else { continue }
                    let issue = try ParticipantPrivacyIssue(sourceID: route.id, source: .init(from: from, to: to),
                        output: .init(from: from.subtracting(displacement), to: to.subtracting(displacement)))
                    var spans = issues.removeValue(forKey: route.id) ?? []
                    if let last = spans.indices.last, issue.output.from <= spans[last].output.to,
                       try spans[last].source.from.subtracting(spans[last].output.from) == displacement {
                        spans[last].output.to = max(spans[last].output.to, issue.output.to)
                        spans[last].source.to = max(spans[last].source.to, issue.source.to)
                    } else {
                        spans.append(issue)
                    }
                    issues[route.id] = spans
                }
            }
        }
        return issues.values.flatMap { $0 }.sorted {
            $0.output.from == $1.output.from ? $0.sourceID < $1.sourceID : $0.output.from < $1.output.from
        }
    }

    private func needsCover(route: ParticipantRenderRoute, index: Int, window: ParticipantRenderWindow) -> Bool {
        guard let scope = privacyScopes[route.id], !scope.isEmpty else { return false }
        if stale.contains(route.id) { return true }
        let indexed = media[route.file]!
        let frames = indexed.frames
        let frame = frames[index]
        let time = frame.time
        if (index > 0 && frames[index - 1].time == time)
            || (index + 1 < frames.count && frames[index + 1].time == time) { return true }

        let sourceGeometry = geometry[route.id]!
        let frameGeometry = sourceGeometry.at(time)
        guard frameGeometry.coverage != .unknown else { return true }
        let uncertain = frameGeometry.appearances.filter(\.hasUnresolvedIdentity)
        if !uncertain.isEmpty {
            let output = visibleRegions(of: route, window: window, geometry: sourceGeometry, time: time)
            if legacyWholeFramePrivacy || output.whole { return true }
            // Include the neighboring source pixels used when a crop lands between pixel centers.
            let marginX = 2 / Double(max(1, indexed.video.displayWidth))
            let marginY = 2 / Double(max(1, indexed.video.displayHeight))
            for appearance in uncertain {
                for box in [appearance.bounds, appearance.labelBounds].compactMap({ $0 }) {
                    if output.crops.contains(where: { overlaps(box, $0, marginX: marginX, marginY: marginY) }) {
                        return true
                    }
                }
            }
        }
        let disputed = frameGeometry.coverage == .inferred ? scope : scope.intersection(pendingIdentities[route.id] ?? [])
        guard !disputed.isEmpty else { return false }
        // Review can confirm an existing assignment. It cannot supply a missing region for a mask.
        let located = Set(frameGeometry.appearances.lazy.filter { !$0.hasUnresolvedIdentity }.compactMap(\.participantID))
        guard disputed.isSubset(of: located) else { return true }
        guard let end = try? time.adding(frame.duration) else { return true }
        let confirmed = privacyConfirmations[route.id] ?? [:]
        return disputed.contains { id in
            confirmed[id]?.contains { $0.range.from <= time && min(end, indexed.duration) <= $0.range.to } != true
        }
    }

    private func visibleRegions(of route: ParticipantRenderRoute, window: ParticipantRenderWindow,
                                geometry: ParticipantGeometryIndex, time: RationalTime) -> (whole: Bool, crops: [ParticipantBounds]) {
        var crops: [ParticipantBounds] = []
        // Arranged starts with the full treated source picture, then replaces destination tiles.
        if window.base?.id == route.id && window.shot.layout == .arranged { return (true, []) }
        func appendCamera(_ camera: ParticipantRenderRoute) -> Bool {
            guard let feedID = camera.feedID else { return true }
            if treatments[feedID]?.treatment != .omit, let crop = geometry.appearance(.init(id: feedID), at: time)?.bounds {
                crops.append(crop)
            }
            return false
        }
        if let base = window.base, base.id == route.id, window.shot.layout == .original, appendCamera(base) {
            return (true, [])
        }
        for slot in window.shot.slots where slot.target != .empty {
            if slot.target == .participant && treatments[slot.id]?.treatment == .omit { continue }
            guard let layer = window.route(for: slot), layer.id == route.id else { continue }
            if slot.target == .camera {
                if appendCamera(layer) { return (true, []) }
            } else if let box = geometry.appearance(slot, at: time)?.bounds {
                crops.append(box)
            }
        }
        return (false, crops)
    }

    private func overlaps(_ a: ParticipantBounds, _ b: ParticipantBounds, marginX: Double, marginY: Double) -> Bool {
        a.x < b.x + b.width + marginX && b.x < a.x + a.width + marginX
            && a.y < b.y + b.height + marginY && b.y < a.y + a.height + marginY
    }

    func privacyIssues(at time: RationalTime, frameInputs: ParticipantISOFrameInputs? = nil) throws -> [ParticipantPrivacyIssue] {
        guard !privacyScopes.isEmpty, let window = timeline.window(at: time) else { return [] }
        return try window.routes.compactMap { route in
            guard let index = try sourceFrame(route, at: time, frameInputs: frameInputs),
                  needsCover(route: route, index: index, window: window) else { return nil }
            let media = media[route.file]!
            let frame = media.frames[index]
            let displacement = try relativeDisplacement(route)
            let from = max(frame.time, try window.range.from.adding(displacement))
            let to = min(media.duration, try frame.time.adding(frame.duration), try window.range.to.adding(displacement))
            return try .init(sourceID: route.id, source: .init(from: from, to: to),
                             output: .init(from: from.subtracting(displacement), to: to.subtracting(displacement)))
        }
    }

    private func relativeDisplacement(_ route: ParticipantRenderRoute) throws -> RationalTime {
        let origin = route.usesMulticamClock ? media[route.file]!.multicamSourceOffset : .zero
        return try route.displacement.subtracting(origin)
    }

    private func sourceFrame(_ route: ParticipantRenderRoute, at output: RationalTime,
                             frameInputs: ParticipantISOFrameInputs?) throws -> Int? {
        func resolve() throws -> Int? {
            let indexed = media[route.file]!
            let time = try output.adding(relativeDisplacement(route))
            let index = indexed.frames.lowerBound { $0.time > time } - 1
            guard time >= .zero, time < indexed.duration, indexed.frames.indices.contains(index),
                  time < (try indexed.frames[index].time.adding(indexed.frames[index].duration)) else { return nil }
            return index
        }
        if let frameInputs { return try frameInputs.sourceFrame(route, at: output, resolve: resolve) }
        return try resolve()
    }

    func picture(at time: RationalTime, decoded: ParticipantDecodedPicture? = nil, frameInputs: ParticipantISOFrameInputs? = nil,
                 cells: ((ParticipantSlot, CGRect) -> Void)? = nil) throws -> CIImage {
        try control.check()
        if let id = timeline.timeline.span(at: time)?.placementID, let still = stills[id] {
            if let lastStill, lastStill.id == id { return lastStill.image }
            let image = try StillImage.render(still.url, canvas: stillCanvas, framing: still.framing, forceSDR: color == .sdr,
                                             expectedIdentity: still.identity, cancelled: control.cancelled)
            let picture = try CIImage(cvPixelBuffer: image.pixelBuffer)
            lastStill = (id, picture)
            return picture
        }
        let background = self.background
        guard let window = timeline.window(at: time) else { return background }
        if let issue = try privacyIssues(at: time, frameInputs: frameInputs).first {
            if plan.unresolvedPrivacy == .stop { throw issue.unresolvedError }
            if !reportsPrivacyInRenderSummary {
                NSLog("Covered output because %@", issue.unresolvedError.message)
            }
            return background
        }
        var frames: [String: Int] = [:]
        var pictures: [String: CIImage] = [:]
        for route in window.routes {
            let index = try sourceFrame(route, at: time, frameInputs: frameInputs)
            frames[route.id] = index
            if !blankSourceRanges.isEmpty {
                let sourceTime = try time.adding(relativeDisplacement(route))
                let ranges = blankSourceRanges
                func blanks(_ instant: RationalTime) -> Bool {
                    let rangeIndex = ranges.lowerBound { $0.to > instant }
                    return ranges.indices.contains(rangeIndex) && ranges[rangeIndex].contains(instant)
                }
                if blanks(sourceTime) || index.map({ blanks(media[route.file]!.frames[$0].time) }) == true {
                    return background
                }
            }
        }
        func image(_ route: ParticipantRenderRoute, _ index: Int) throws -> CIImage {
            if let cached = pictures[route.id] { return cached }
            let sourceGeometry = geometry[route.id]!
            let usesCrop = route.feedID != nil || (window.base?.id == route.id &&
                (window.shot.layout == .arranged || window.shot.slots.contains { $0.target != .camera }))
            let scanned = sourceGeometry.usesScannedGeometry && (!treatments.isEmpty || usesCrop)
            let source = media[route.file]!
            func preparePicture() throws -> CIImage {
                let original: CIImage
                if let decoded, (decoded.sourceID == route.id || decoded.sourceID == route.file.path),
                   decoded.sourceTime == source.frames[index].time, decoded.sourceIdentity.matchesSnapshot(source.identity) {
                    original = try ParticipantPictureReader.oriented(decoded, source: source, usingScannedGeometry: scanned,
                                                                     toneMapHDR: color == .sdr)
                } else {
                    original = try read(route.file, index, usingScannedGeometry: scanned)
                }
                guard !treatments.isEmpty else { return original }
                // Legacy delivery retains the exact Core Image blur used by saved compositions.
                return ParticipantCompositor.redact(original, appearances: sourceGeometry.at(source.frames[index].time)
                    .appearances, treatments: treatments, allowMetal: !legacyWholeFramePrivacy)
            }
            let result: CIImage
            if let frameInputs, decoded == nil, !treatments.isEmpty {
                let key = ParticipantISOFrameInputs.TreatedPicture(file: route.file, geometryID: sourceGeometry.sourceID,
                    index: index, treatmentIndex: treatmentIndex, toneMapHDR: color == .sdr, scanned: scanned,
                    allowMetal: !legacyWholeFramePrivacy)
                result = try frameInputs.treatedPicture(key, render: preparePicture)
            } else {
                result = try preparePicture()
            }
            pictures[route.id] = result
            return result
        }
        func appearance(_ slot: ParticipantSlot, of route: ParticipantRenderRoute, index: Int) -> ParticipantAppearance? {
            guard !stale.contains(route.id) else { return nil }
            return geometry[route.id]!.appearance(slot, at: media[route.file]!.frames[index].time)
        }

        func cropForFeed(_ route: ParticipantRenderRoute, index: Int, in picture: CIImage) -> CIImage? {
            guard let id = route.feedID else { return picture }
            guard treatments[id]?.treatment != .omit,
                  let bounds = appearance(.init(id: id), of: route, index: index)?.bounds else { return nil }
            return picture.cropped(to: ParticipantCompositor.rect(bounds, in: picture.extent))
        }

        if window.shot.layout == .original || window.shot.layout == .arranged {
            guard let base = window.base, let index = frames[base.id] else { return background }
            let source = try image(base, index)
            var picture = source
            if window.shot.layout == .arranged {
                let sourceTime = media[base.file]!.frames[index].time
                guard !stale.contains(base.id) else { return background }
                let sourceGeometry = geometry[base.id]!
                let appearances = sourceGeometry.at(sourceTime).appearances
                var resolvedIDs: Set<String> = []
                let targets = try window.shot.slots.map { slot -> (ParticipantSlot, ParticipantAppearance) in
                    guard let target = slot.arrangedDestination else {
                        throw CutError(code: "invalid_tile_layout", message: "An arranged slot needs a destination.")
                    }
                    guard let tile = sourceGeometry.destination(target, in: appearances) else {
                        throw unavailableArrangedTile(target, sourceID: base.id, at: sourceTime)
                    }
                    guard resolvedIDs.insert(tile.id).inserted else {
                        throw CutError(code: "unmappable_tile_layout",
                            message: "Arranged destinations resolve to the same tile on source ‘\(base.id)’ at \(sourceTime).")
                    }
                    return (slot, tile)
                }
                var movedFeeds: Set<String> = []
                var movedPresentations: Set<String> = []
                for slot in window.shot.slots {
                    guard let route = window.route(for: slot), route.id == base.id else { continue }
                    switch slot.target {
                    case .participant: movedFeeds.insert(slot.id)
                    case .presentation: movedPresentations.insert(slot.id)
                    case .camera:
                        if let id = route.feedID { movedFeeds.insert(id) }
                    case .empty: break
                    }
                }
                func clear(_ tile: ParticipantAppearance, color: UInt32) -> CGRect {
                    let area = ParticipantCompositor.rect(tile.bounds, in: source.extent)
                    if let label = tile.labelBounds {
                        let region = ParticipantCompositor.rect(label, in: source.extent)
                        picture = ParticipantCompositor.color(color, in: region).composited(over: picture)
                    }
                    picture = ParticipantCompositor.color(color, in: area).composited(over: picture)
                    return area
                }
                // Consume every native appearance of each moved feed before writing any destination.
                for tile in appearances where movedPresentations.contains(tile.id)
                    || tile.participantID.map(movedFeeds.contains) == true {
                    _ = clear(tile, color: plan.canvas.background)
                }
                var destinations: [(slot: ParticipantSlot, area: CGRect)] = []
                let fit = ParticipantCompositor.placementTransform(source.extent, inside: extent, framing: .fit)
                for (slot, appearance) in targets {
                    let area = clear(appearance, color: slot.background ?? plan.canvas.background)
                    destinations.append((slot, area))
                    cells?(slot, area.applying(fit).intersection(extent))
                }
                for (slot, area) in destinations where slot.target != .empty {
                    if slot.target == .participant, treatments[slot.id]?.treatment == .omit { continue }
                    let route = window.route(for: slot)
                    guard let route, let index = frames[route.id] else { continue }
                    var isolated = try image(route, index)
                    if slot.target != .camera {
                        guard let bounds = appearance(slot, of: route, index: index)?.bounds else { continue }
                        isolated = isolated.cropped(to: ParticipantCompositor.rect(bounds, in: isolated.extent))
                    } else {
                        guard let crop = cropForFeed(route, index: index, in: isolated) else { continue }
                        isolated = crop
                    }
                    picture = ParticipantCompositor.place(isolated, inside: area, framing: slot.framing,
                                                         anchorX: slot.anchorX, anchorY: slot.anchorY).composited(over: picture)
                }
            } else {
                guard let cropped = cropForFeed(base, index: index, in: source) else { return background }
                picture = cropped
            }
            return ParticipantCompositor.place(picture, inside: extent, framing: .fit).composited(over: background)
        }

        struct Layer {
            let slot: ParticipantSlot
            let route: ParticipantRenderRoute?
            let index: Int?
            let bounds: ParticipantBounds?
        }
        var layers: [Layer] = []
        for slot in window.shot.slots {
            if slot.target == .participant && treatments[slot.id]?.treatment == .omit { continue }
            let route = window.route(for: slot)
            let index = route.flatMap { frames[$0.id] }
            if let route, let index, slot.target != .camera {
                let frameTime = media[route.file]!.frames[index].time
                let geometry = geometry[route.id]!
                let appearance = stale.contains(route.id) ? nil : geometry.appearance(slot, at: frameTime)
                if let appearance {
                    layers.append(.init(slot: slot, route: route, index: index, bounds: appearance.bounds))
                    continue
                }
                let frameGeometry = geometry.at(frameTime)
                let confirmedAbsent = !frameGeometry.needsPrivacyCover && !stale.contains(route.id)
                    && !(slot.target == .participant && pendingIdentities[route.id]?.contains(slot.id) == true)
                    && !frameGeometry.appearances.contains {
                        slot.target == .participant ? $0.participantID == slot.id : $0.id == slot.id
                    }
                if window.shot.compact && confirmedAbsent { continue }
                layers.append(.init(slot: slot, route: nil, index: nil, bounds: nil))
            } else {
                layers.append(.init(slot: slot, route: route, index: index, bounds: nil))
            }
        }
        var result = background
        let slots = ParticipantCompositor.slots(window.shot.layout, count: layers.count, extent: extent)
        for (layer, rect) in zip(layers, slots) {
            cells?(layer.slot, rect)
            if let rgb = layer.slot.background { result = ParticipantCompositor.color(rgb, in: rect).composited(over: result) }
            guard let route = layer.route, let index = layer.index else { continue }
            var picture = try image(route, index)
            if let bounds = layer.bounds {
                let crop = ParticipantCompositor.rect(bounds, in: picture.extent).intersection(picture.extent)
                picture = picture.cropped(to: crop)
            } else if layer.slot.target == .camera {
                guard let crop = cropForFeed(route, index: index, in: picture) else { continue }
                picture = crop
            }
            let layerImage = ParticipantCompositor.place(picture, inside: rect, framing: layer.slot.framing,
                                                         anchorX: layer.slot.anchorX, anchorY: layer.slot.anchorY)
            result = layerImage.composited(over: result)
        }
        return result
    }

    private func read(_ file: URL, _ index: Int, usingScannedGeometry: Bool) throws -> CIImage {
        try pictureInputs.picture(media[file]!, index: index, control: control,
                                  toneMapHDR: color == .sdr, usingScannedGeometry: usingScannedGeometry)
    }
}
