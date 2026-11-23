import AVFoundation
import CoreImage
import Foundation

public struct ParticipantRenderer: Sendable {
    private let cancelled: (@Sendable () -> Bool)?

    public init(cancelled: (@Sendable () -> Bool)? = nil) {
        self.cancelled = cancelled
    }

    public func report(_ project: CutProject, document: URL, plan: ParticipantRenderPlan? = nil,
                       output: URL? = nil) throws -> ParticipantRenderReport {
        let resolved = try prepare(project, document: document, plan: plan, cancelled: cancelled)
        let sound = try ParticipantRenderSound.resolve(project, document: document, timeline: resolved.timeline.timeline,
                                                       audio: resolved.plan.audio, cancelled: cancelled)
        if let output { try Self.validateDestination(output, hasAudio: !sound.actions.isEmpty) }
        try resolved.verifySources()
        try sound.verifySources()
        return resolved.report(sound: sound)
    }

    @discardableResult
    public func render(_ project: CutProject, document: URL, plan: ParticipantRenderPlan? = nil,
                       to output: URL, progress: ((Double) -> Bool)? = nil) throws -> ParticipantRenderReport {
        let interruption = ParticipantRenderInterruption()
        let isCancelled: @Sendable () -> Bool = { [cancelled] in cancelled?() == true || interruption.stopped }
        func update(_ fraction: Double) -> Bool {
            if progress?(fraction) == false { interruption.stop() }
            return !isCancelled()
        }

        _ = update(0)
        let resolved = try prepare(project, document: document, plan: plan, cancelled: isCancelled)
        let sound = try ParticipantRenderSound.resolve(project, document: document, timeline: resolved.timeline.timeline,
                                                       audio: resolved.plan.audio, cancelled: isCancelled)
        let report = resolved.report(sound: sound)
        if !report.publishable, let issue = report.privacyIssues.first {
            throw CutError(code: "unresolved_participant_privacy",
                           message: "Review source ‘\(issue.sourceID)’ from \(issue.source.from) to \(issue.source.to) "
                           + "(output \(issue.output.from) to \(issue.output.to)) before publishing.")
        }
        let container = try Self.validateDestination(output, hasAudio: !sound.actions.isEmpty)
        let staging = output.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-participants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let video = staging.appendingPathComponent("picture.mov")
        try resolved.writePicture(to: video) { _ = update($0 * 0.85) }
        let inspector = CutEngine(cancelled: isCancelled, useSidecar: false, tracks: .video)
        let written = try inspector.inspect(video, keyframes: true)
        guard written.duration == report.duration, Int64(written.frames.count) == report.frameCount else {
            throw CutError(code: "participant_timing_mismatch",
                           message: "The encoder wrote \(written.frames.count) frames over \(written.duration) seconds, "
                           + "expected \(report.frameCount) frames over \(report.duration) seconds.")
        }
        for (index, frame) in written.frames.enumerated() {
            if index.isMultiple(of: 1_024) { try inspector.checkCancellation() }
            let at = try resolved.cadence.multiplied(by: .init(numerator: Int64(index)))
            let length = min(resolved.cadence, try report.duration.subtracting(at))
            guard frame.time == at, frame.duration == length else {
                throw CutError(code: "participant_timing_mismatch",
                               message: "The encoder changed the presentation timing of frame \(index + 1).")
            }
        }
        let audio = try StillSoundPlanner(cancelled: isCancelled).write(sound, in: staging) { update(0.85 + $0 * 0.1) }
        try MulticamMux(cancelled: isCancelled).export(picture: video, sounds: audio, to: output,
                                                       container: container, duration: report.duration,
                                                       progress: { update(0.95 + $0 * 0.05) }) {
            try resolved.verifySources()
            try sound.verifySources()
        }
        return resolved.report(sound: sound, output: output.standardizedFileURL.path)
    }

    public func frame(_ project: CutProject, document: URL, plan: ParticipantRenderPlan? = nil,
                      at time: RationalTime) throws -> CGImage {
        let resolved = try prepare(project, document: document, plan: plan, cancelled: cancelled, auditPrivacy: false)
        let instant = try resolved.sampleTime(at: time)
        let picture = try resolved.picture(at: instant)
        guard let image = ParticipantCompositor.context.createCGImage(picture, from: resolved.extent, format: .RGBA8,
                                                                       colorSpace: ParticipantCompositor.colorSpace) else {
            throw CutError(code: "frame_export_failed", message: "Could not render the participant composition.")
        }
        try resolved.verifySources()
        return image
    }

    private func prepare(_ project: CutProject, document: URL, plan: ParticipantRenderPlan?,
                         cancelled: (@Sendable () -> Bool)?, auditPrivacy: Bool = true) throws -> ParticipantRenderSession {
        let saved = project.participants.render
        guard var plan = plan ?? saved else {
            throw CutError(code: "missing_participant_plan", message: "Choose a participant shot before rendering.")
        }
        try project.validate()
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
        try plan.validate()
        guard project.stillInserts.isEmpty, project.stillReplacements.isEmpty else {
            throw CutError(code: "invalid_participant_plan", message: "Participant composition currently requires source picture throughout.")
        }
        return try .init(project: project, document: document, plan: plan, cancelled: cancelled, auditPrivacy: auditPrivacy)
    }

    @discardableResult
    private static func validateDestination(_ output: URL, hasAudio: Bool) throws -> String {
        let container = output.pathExtension.lowercased()
        guard container == "mov" || (container == "mp4" && !hasAudio) else {
            throw CutError(code: "unsupported_container",
                           message: "Use MOV for participant movies with audio. Silent movies also support MP4.")
        }
        try ReencodeEngine().checkDestination(output, container: container)
        return container
    }
}

private final class ParticipantRenderInterruption: @unchecked Sendable {
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
    let frameCount: Int64
    let cadence: RationalTime
    let timescale: Int32
    private let media: [URL: MediaInfo]
    private let geometry: [String: ParticipantGeometryIndex]
    private let stale: Set<String>
    private let treatments: [String: ParticipantRedaction]
    private var readers: [(file: URL, reader: ParticipantPictureReader)] = []
    private var privacyIssues: [ParticipantPrivacyIssue] = []

    init(project: CutProject, document: URL, plan: ParticipantRenderPlan, cancelled: (@Sendable () -> Bool)?,
         auditPrivacy: Bool) throws {
        self.plan = plan
        let control = JPEGControl(cancelled ?? { false })
        self.control = control
        let engine = CutEngine(cancelled: cancelled, tracks: .video)
        self.engine = engine
        let original = try project.resolveStillsUnchecked()
        timeline = try .init(project: project, document: document, timeline: original, plan: plan,
                             checkCancellation: control.check)
        let duration = original.duration
        guard duration > .zero else {
            throw CutError(code: "empty_edit", message: "Add a source interval before rendering participants.")
        }
        let length = try duration.multiplied(by: plan.canvas.frameRate)
        frameCount = length.numerator / length.denominator + (length.numerator % length.denominator == 0 ? 0 : 1)
        cadence = .init(numerator: plan.canvas.frameRate.denominator, denominator: plan.canvas.frameRate.numerator)
        let scale = try Self.movieTimescale(cadence.denominator, duration.denominator)
        _ = try duration.multiplied(by: .init(numerator: Int64(scale)))
        timescale = scale
        extent = .init(x: 0, y: 0, width: plan.canvas.width, height: plan.canvas.height)
        treatments = Dictionary(uniqueKeysWithValues: plan.redactions.map { ($0.participantID, $0) })

        let slots = Set(plan.shots.flatMap(\.slots).filter { $0.target == .participant }.map(\.id))
        var media: [URL: MediaInfo] = [:]
        var geometry: [String: ParticipantGeometryIndex] = [:]
        var stale: Set<String> = []
        for window in timeline.windows {
            try control.check()
            for route in window.routes {
                if media[route.file] == nil {
                    let source = try engine.inspect(route.file, keyframes: true)
                    guard source.hasVideo, !source.frames.isEmpty, source.video.timeBase > .zero else {
                        throw CutError(code: "missing_picture", message: "Source ‘\(route.id)’ has no indexed video.")
                    }
                    media[route.file] = source
                }
                if geometry[route.id] == nil {
                    geometry[route.id] = try .init(project.participants, sourceID: route.id, slots: slots,
                                                   checkCancellation: control.check)
                    if project.participants.needsReconciliation(sourceID: route.id, identity: media[route.file]!.identity) {
                        stale.insert(route.id)
                    }
                }
            }
        }
        self.media = media
        self.geometry = geometry
        self.stale = stale
        if auditPrivacy && !treatments.isEmpty { privacyIssues = try audit() }
    }

    func report(sound: StillSoundPlan, output: String? = nil) -> ParticipantRenderReport {
        .init(canvas: plan.canvas, duration: timeline.timeline.duration, frameCount: frameCount, audio: plan.audio,
              audioActions: sound.actions, privacyIssues: privacyIssues,
              publishable: privacyIssues.isEmpty || plan.unresolvedPrivacy == .cover,
              staleSourceIDs: stale.sorted(), output: output)
    }

    func verifySources() throws {
        try control.check()
        for (file, media) in media { try engine.verifyIdentity(file, identity: media.identity) }
    }

    func sampleTime(at time: RationalTime) throws -> RationalTime {
        guard time >= .zero, time <= timeline.timeline.duration else {
            throw CutError(code: "invalid_range", message: "The requested frame is outside the participant program.")
        }
        let count = try time.multiplied(by: plan.canvas.frameRate)
        return try cadence.multiplied(by: .init(numerator: min(frameCount - 1, count.numerator / count.denominator)))
    }

    private static func movieTimescale(_ a: Int64, _ b: Int64) throws -> Int32 {
        var lhs = a
        var rhs = b
        while rhs != 0 { (lhs, rhs) = (rhs, lhs % rhs) }
        let (rate, overflow) = (a / lhs).multipliedReportingOverflow(by: b)
        guard !overflow, let scale = Int32(exactly: rate) else {
            throw CutError(code: "unsupported_participant_timing", message: "The canvas cadence and edit duration need a finer movie clock.")
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
                    guard from < to, needsCover(route: route, index: index) else { continue }
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

    private func needsCover(route: ParticipantRenderRoute, index: Int) -> Bool {
        let frames = media[route.file]!.frames
        let time = frames[index].time
        return stale.contains(route.id)
            || geometry[route.id]!.at(time).needsPrivacyCover
            || (index > 0 && frames[index - 1].time == time)
            || (index + 1 < frames.count && frames[index + 1].time == time)
    }

    private func relativeDisplacement(_ route: ParticipantRenderRoute) throws -> RationalTime {
        let origin = route.usesMulticamClock ? media[route.file]!.multicamSourceOffset : .zero
        return try route.displacement.subtracting(origin)
    }

    private func sourceFrame(_ route: ParticipantRenderRoute, at output: RationalTime) throws -> Int? {
        let indexed = media[route.file]!
        let time = try output.adding(relativeDisplacement(route))
        let index = indexed.frames.lowerBound { $0.time > time } - 1
        guard time >= .zero, time < indexed.duration, indexed.frames.indices.contains(index),
              time < (try indexed.frames[index].time.adding(indexed.frames[index].duration)) else { return nil }
        return index
    }

    func picture(at time: RationalTime) throws -> CIImage {
        try control.check()
        let background = ParticipantCompositor.color(plan.canvas.background, in: extent)
        guard let window = timeline.window(at: time) else { return background }
        var frames: [String: Int] = [:]
        var pictures: [String: CIImage] = [:]
        for route in window.routes {
            let index = try sourceFrame(route, at: time)
            frames[route.id] = index
            if !treatments.isEmpty, let index, needsCover(route: route, index: index) { return background }
        }
        func image(_ route: ParticipantRenderRoute, _ index: Int) throws -> CIImage {
            if let cached = pictures[route.id] { return cached }
            let original = try read(route.file, index)
            let result = ParticipantCompositor.redact(original,
                appearances: geometry[route.id]!.at(media[route.file]!.frames[index].time).appearances, treatments: treatments)
            pictures[route.id] = result
            return result
        }
        if window.shot.layout == .original {
            guard let base = window.base, let index = frames[base.id] else { return background }
            return try ParticipantCompositor.place(image(base, index), inside: extent, framing: .fit).composited(over: background)
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
            if let rgb = layer.slot.background { result = ParticipantCompositor.color(rgb, in: rect).composited(over: result) }
            guard let route = layer.route, let index = layer.index else { continue }
            var picture = try image(route, index)
            if let bounds = layer.bounds {
                let crop = ParticipantCompositor.rect(bounds, in: picture.extent).intersection(picture.extent)
                picture = picture.cropped(to: crop)
            }
            let layerImage = ParticipantCompositor.place(picture, inside: rect, framing: layer.slot.framing,
                                                         anchorX: layer.slot.anchorX, anchorY: layer.slot.anchorY)
            result = layerImage.composited(over: result)
        }
        return result
    }

    private func read(_ file: URL, _ index: Int) throws -> CIImage {
        let reader: ParticipantPictureReader
        if let found = readers.firstIndex(where: { $0.file == file }) {
            reader = readers.remove(at: found).reader
        } else {
            if readers.count >= 4 { readers.removeFirst() }
            reader = try .init(media[file]!, control: control)
        }
        readers.append((file, reader))
        return try reader.picture(at: index)
    }
}

private extension ParticipantRenderWindow {
    var routes: [ParticipantRenderRoute] {
        var seen: Set<String> = []
        return ([base].compactMap { $0 } + cameras.values.sorted { $0.id < $1.id }).filter { seen.insert($0.id).inserted }
    }
}
