import Foundation
import MPCutCore

private enum ReviewPicture: Sendable {
    case video(MediaInfo, RationalTime, exclusiveEnd: Bool)
    case still(StillReviewFrame)

    func render(preset: JPEGPreset) throws -> ReviewImage {
        switch self {
        case .video(let media, let time, let end):
            let (data, frame) = try JPEGExport.reviewFrame(media, at: time, exclusiveEnd: end, preset: preset,
                                                           cancelled: { Task.isCancelled })
            return ReviewImage(data: data, width: frame.width, height: frame.height,
                               duration: frame.frameDuration, sourceTime: frame.frameTime)
        case .still(let frame):
            let jpeg = try frame.jpeg(preset: preset, cancelled: { Task.isCancelled })
            return ReviewImage(data: jpeg.data, width: jpeg.width, height: jpeg.height,
                               duration: try frame.interval.to.subtracting(frame.interval.from), sourceTime: nil)
        }
    }

    func validateIdentity() throws {
        switch self {
        case .still(let frame): try frame.validateIdentity()
        case .video(let media, _, _):
            guard media.identity.isCurrentSnapshot(at: media.url) else {
                throw CutError(code: "source_changed", message: "Relink the changed recording.")
            }
        }
    }

    var still: StillReviewFrame? {
        guard case .still(let frame) = self else { return nil }
        return frame
    }
}

private struct ReviewImage: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let duration: RationalTime
    let sourceTime: RationalTime?
}

private struct ReviewPosition: Sendable {
    let picture: ReviewPicture
    let clock: String
    let time: RationalTime?
    var group: RationalTime? = nil
    var playheadSeconds: Double? = nil
    var occurrence: String? = nil
    var source: String? = nil
    var angle: String? = nil
    var interval: MulticamRange? = nil

    func metadata(for image: ReviewImage) -> [String: Any] {
        var result: [String: Any] = ["space": clock, "width": image.width, "height": image.height,
                                    "duration": image.duration.description]
        result["time"] = time?.description
        result["groupTime"] = group?.description
        result["playheadSeconds"] = playheadSeconds
        result["sourceTime"] = image.sourceTime?.description
        result["occurrence"] = occurrence
        result["source"] = source
        result["angle"] = angle
        if let still = picture.still {
            result["asset"] = still.asset.id
            result["placement"] = still.placementID
            result["picture"] = "still"
            result["from"] = interval?.from.description
            result["to"] = interval?.to.description
        }
        return result
    }
}

private struct ProgramReviewManifest: Encodable {
    struct Frame: Encodable {
        let file: String
        let space: String
        let time: RationalTime?
        let playheadSeconds: Double?
        let groupTime: RationalTime?
        let sourceTime: RationalTime?
        let duration: RationalTime
        let from, to: RationalTime?
        let occurrence, source, angle, asset, placement: String?
        let width, height: Int
    }

    let version = 1
    let selection = "program"
    let preset: JPEGPreset
    let frames: [Frame]
}

/// Review requests are independent of export jobs. Bound simultaneous decoder allocation.
@MainActor
private enum ReviewDecoders {
    static var active = 0
}

extension ProjectSessions {
    func mcpReviewFrame(arguments: [String: Any], session: ProjectSession,
                        checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        try checkAccess()
        guard (session.isMulticam ? session.multicam.mediaRefreshProgress : session.editor.mediaRefreshProgress) == nil else {
            throw MCPCommandError("busy", "Wait for the project media refresh to finish.")
        }
        let time = try (arguments["time"] as? String).map { try RationalTime(parsing: $0) }
        let space = arguments["space"] as? String
        guard (time == nil) == (space == nil) else {
            throw MCPCommandError("invalid_arguments", "Supply time and space together, or omit both for the playhead.")
        }
        guard ReviewDecoders.active < 2 else { throw MCPCommandError("busy", "Two review frames are decoding. Retry when one finishes.") }
        ReviewDecoders.active += 1
        defer { ReviewDecoders.active -= 1 }
        let revision = session.mcpRevision
        let handle = session.mcpHandle
        let position: ReviewPosition
        if session.isMulticam {
            position = try multicamReview(session.multicam, time: time, space: space, angle: arguments["angle"] as? String)
        } else {
            guard arguments["angle"] == nil else { throw MCPCommandError("invalid_target", "Angles apply to multicam projects.") }
            position = try sequenceReview(session.editor, time: time, space: space)
        }
        let picture = position.picture
        let work = Task.detached(priority: .userInitiated) { try picture.render(preset: .review) }
        let image = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
        try checkAccess()
        guard session.mcpHandle == handle, session.mcpRevision == revision else {
            throw MCPCommandError("stale_revision", "The timeline changed. Request the frame again.")
        }
        try picture.validateIdentity()
        var result = position.metadata(for: image)
        result["jpeg"] = image.data.base64EncodedString()
        return result
    }

    private func sequenceReview(_ editor: EditorModel, time: RationalTime?, space: String?) throws -> ReviewPosition {
        let project = editor.stillProject
        if project.hasReviewStills {
            let plan = try project.resolveStills()
            let at = time ?? editor.stillReviewTime(in: plan)
            guard space == nil || space == "sequence", let index = plan.pictureIndex(at: at) else {
                throw MCPCommandError("invalid_target", "Choose a position on the open sequence.")
            }
            let span = plan.spans[index]
            if let placement = span.placementID {
                let frame = try project.stillReviewFrame(placementID: placement, interval: span.output,
                                                         document: editor.projectURL, canvas: editor.stillReviewCanvas)
                let occurrence: String?
                if case let .source(clipID, _) = span.origin {
                    occurrence = try editor.stillReviewOccurrence(clipID).id.uuidString
                } else {
                    occurrence = nil
                }
                return ReviewPosition(picture: .still(frame), clock: "sequence", time: at,
                                      occurrence: occurrence, interval: span.output)
            }
            if case let .source(clipID, range) = span.origin {
                let (id, source, media) = try editor.stillReviewOccurrence(clipID)
                if time == nil, let playhead = editor.jpegSourceAtPlayhead, let frame = playhead.frame {
                    return ReviewPosition(picture: .video(playhead.media, frame, exclusiveEnd: false),
                                          clock: "sequence", time: at, occurrence: id.uuidString,
                                          source: playhead.id.uuidString)
                }
                let sourceTime = try range.from.adding(at.subtracting(span.output.from))
                return ReviewPosition(picture: .video(media, sourceTime, exclusiveEnd: at == plan.duration),
                                      clock: "sequence", time: at, occurrence: id.uuidString, source: source.uuidString)
            }
            throw MCPCommandError("no_frame", "No picture covers this sequence position.")
        }
        if let time {
            guard space == "sequence", time >= .zero, time <= editor.mcpDuration, !editor.mcpClipIDs.isEmpty else {
                throw MCPCommandError("invalid_target", "Choose a position on the open sequence.")
            }
            let end = time == editor.mcpDuration
            let i = end ? editor.mcpClipIDs.count - 1 : editor.mcpSequenceOffsets.lowerBound { $0 > time } - 1
            guard editor.mcpClipIDs.indices.contains(i) else { throw MCPCommandError("no_frame", "No occurrence covers this position.") }
            let id = editor.mcpClipIDs[i]
            let range = editor.sequenceClips[i]
            let (source, media) = try editor.mcpReplacementSource(id)
            let sourceTime = try range.from.adding(time.subtracting(editor.mcpSequenceOffsets[i]))
            return ReviewPosition(picture: .video(media, sourceTime, exclusiveEnd: end), clock: "sequence",
                                  time: time, occurrence: id.uuidString, source: source.uuidString)
        }
        guard let source = editor.jpegSourceAtPlayhead, let target = source.frame else {
            throw MCPCommandError("no_frame", "No indexed picture covers the sequence playhead.")
        }
        return ReviewPosition(picture: .video(source.media, target, exclusiveEnd: false), clock: "sequence",
                              time: nil, playheadSeconds: editor.playhead, source: source.id.uuidString)
    }

    private func multicamReview(_ model: MulticamEditorModel, time: RationalTime?, space: String?,
                                angle: String?) throws -> ReviewPosition {
        guard let project = model.project else { throw MCPCommandError("no_frame", "Open a multicam project.") }
        let clock = space ?? (model.assemblyPreview ? "assembly" : "group")
        if CutProject.multicam(project).hasReviewStills {
            let context = try model.stillReviewContext(clock: clock, time: time)
            let span = context.plan.spans[context.index]
            let atEnd = context.time == context.plan.duration
            let group: RationalTime?
            let groupRange: MulticamRange?
            if case let .group(_, range) = span.origin {
                groupRange = range
                group = try range.from.adding(context.time.subtracting(span.output.from))
            } else {
                groupRange = nil
                group = nil
            }
            let addressedTime = clock == "group" ? group : context.time
            if angle == nil, let placement = span.placementID {
                let frame = try context.project.stillReviewFrame(placementID: placement, interval: span.output,
                                                                 document: model.projectURL, canvas: model.stillReviewCanvas)
                return ReviewPosition(picture: .still(frame), clock: clock, time: addressedTime, group: group,
                                      interval: clock == "group" ? groupRange : span.output)
            }
            guard let group else {
                throw MCPCommandError("invalid_target", "This insert has no camera or group time.")
            }
            let selected = angle ?? (atEnd ? project.switches.last(where: { $0.at < group }) : project.selection(at: group))?.angle
            if let selected, let issue = model.refreshPictureIssue(sourceID: selected) {
                throw MCPCommandError("source_needs_review", issue)
            }
            guard let camera = project.angles.first(where: { $0.id == selected }),
                  let media = model.media[camera.id], media.hasFullEditIndex else {
                throw MCPCommandError("no_frame", "Choose an indexed camera in this project.")
            }
            let time = try group.subtracting(camera.offset)
            return ReviewPosition(picture: .video(media, time, exclusiveEnd: atEnd), clock: clock,
                                  time: addressedTime, group: group, angle: camera.id)
        }
        let group: RationalTime
        let clockTime: RationalTime
        let exclusiveEnd: Bool
        let programAngle: String
        if clock == "group", let time {
            guard project.range.contains(time), let selected = project.selection(at: time) else {
                throw MCPCommandError("invalid_target", "Choose a time within the multicam group.")
            }
            group = time
            clockTime = time
            exclusiveEnd = false
            programAngle = selected.angle
        } else {
            guard time == nil || clock == "assembly" else { throw MCPCommandError("invalid_target", "Choose group or assembly time.") }
            let plan: MulticamPlan
            if time != nil { plan = try project.plan() }
            else if let current = model.mapping { plan = current }
            else { throw MCPCommandError("no_frame", "The program preview is unavailable.") }
            let at = time ?? model.preview.currentTime()
            let position = try MulticamStillPosition.at(at, in: plan)
            guard let active = project.angles.first(where: { $0.id == position.angle }) else {
                throw MCPCommandError("no_frame", "No active camera at this time.")
            }
            group = try position.sourceTime.adding(active.offset)
            clockTime = clock == "group" ? group : at
            exclusiveEnd = position.exclusiveEnd
            programAngle = position.angle
        }
        let selected = angle ?? programAngle
        if let issue = model.refreshPictureIssue(sourceID: selected) {
            throw MCPCommandError("source_needs_review", issue)
        }
        guard let source = project.angles.first(where: { $0.id == selected }),
              let media = model.media[source.id], media.hasFullEditIndex else {
            throw MCPCommandError("no_frame", "Choose an indexed camera in this project.")
        }
        return try ReviewPosition(picture: .video(media, group.subtracting(source.offset), exclusiveEnd: exclusiveEnd),
                                  clock: clock, time: clockTime, group: group, angle: source.id)
    }
}

extension ProjectSessions {
    nonisolated static func writeStill(_ media: MediaInfo, time: RationalTime, exclusiveEnd: Bool = false,
                                       to output: URL, progress: MCPLiveOutputProgress) throws -> [String: Any] {
        let frame = try JPEGExport.stillFrameTime(in: media, at: time, exclusiveEnd: exclusiveEnd)
        try JPEGExport.writeStill(media, at: time, to: output, replacing: nil, exclusiveEnd: exclusiveEnd, cancelled: { Task.isCancelled })
        progress.published(output)
        return ["sourceTime": frame.description, "frames": 1]
    }

    func mcpProgramFrameExport(session: ProjectSession, output: URL, args: [String: Any],
                               mode: String, times: [RationalTime], preset: JPEGPreset) throws -> MCPLiveOutputJobs.Work? {
        let clock = args["space"] as? String
        let project = session.isMulticam ? session.multicam.project.map(CutProject.multicam) : session.editor.stillProject
        guard clock != nil || (mode == "still" || mode == "playhead") && project?.hasReviewStills == true else { return nil }
        guard ["still", "playhead", "times"].contains(mode) else {
            throw MCPCommandError("invalid_arguments", "Program clocks support still, playhead, or explicit times.")
        }
        if let clock {
            let available = session.isMulticam ? (session.multicam.assemblyPreview ? "assembly" : "group") : "sequence"
            guard mode == "times" || clock == available else {
                throw MCPCommandError("invalid_target", "The playhead uses \(available) time.")
            }
        }
        let requests = mode == "times" ? times.map(Optional.some) : [nil]
        let positions = try requests.map { time in
            if session.isMulticam {
                return try multicamReview(session.multicam, time: time, space: clock, angle: nil)
            }
            return try sequenceReview(session.editor, time: time, space: clock)
        }
        let cancelled: @Sendable () -> Bool = { Task.isCancelled }
        if mode == "still", let position = positions.first {
            return { progress in
                switch position.picture {
                case .still(let frame):
                    try frame.write(to: output, cancelled: cancelled)
                    progress.published(output)
                    return ["frames": 1, "placement": frame.placementID, "asset": frame.asset.id]
                case .video(let media, let time, let end):
                    return try Self.writeStill(media, time: time, exclusiveEnd: end, to: output, progress: progress)
                }
            }
        }
        return { progress in
            let manifest = try JPEGExport.writeProgramFrameDirectory(to: output, cancelled: cancelled, validate: {
                for position in positions { try position.picture.validateIdentity() }
            }) { staging in
                var frames: [ProgramReviewManifest.Frame] = []
                for (i, position) in positions.enumerated() {
                    try Task.checkCancellation()
                    let image = try position.picture.render(preset: preset)
                    let name = String(format: "%06d.jpg", i + 1)
                    try image.data.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
                    frames.append(.init(file: name, space: position.clock, time: position.time,
                                        playheadSeconds: position.playheadSeconds, groupTime: position.group,
                                        sourceTime: image.sourceTime, duration: image.duration,
                                        from: position.interval?.from, to: position.interval?.to,
                                        occurrence: position.occurrence, source: position.source, angle: position.angle,
                                        asset: position.picture.still?.asset.id, placement: position.picture.still?.placementID,
                                        width: image.width, height: image.height))
                    progress.update(Double(i + 1) / Double(positions.count))
                }
                return ProgramReviewManifest(preset: preset, frames: frames)
            }
            progress.published(output)
            return ["manifest": output.appendingPathComponent("manifest.json").path, "frames": manifest.frames.count]
        }
    }
}

extension CutProject {
    var hasReviewStills: Bool { !stillReplacements.isEmpty || !stillInserts.isEmpty }
}
