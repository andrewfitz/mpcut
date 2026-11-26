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

    /// The whole picture's size before a review scales or crops it.
    var nativeSize: (width: Int, height: Int) {
        switch self {
        case .still(let frame): return (frame.width, frame.height)
        case .video(let media, _, _):
            let video = media.video, rotated = !video.rotation.isMultiple(of: 180)
            return (video.displayWidth > 0 ? video.displayWidth : rotated ? video.height : video.width,
                    video.displayHeight > 0 ? video.displayHeight : rotated ? video.width : video.height)
        }
    }
}

/// How much of the picture a review returns: its longest edge and an optional crop.
private struct ReviewFraming: Sendable {
    let edge: Int
    let region: CGRect?

    init(_ arguments: [String: Any]) throws {
        edge = arguments["max_edge"].flatMap(mcpInteger) ?? JPEGReviewSize.defaultEdge
        guard JPEGReviewSize.edges.contains(edge) else {
            throw MCPCommandError("invalid_arguments", "Choose a max_edge from \(JPEGReviewSize.edges.lowerBound) through \(JPEGReviewSize.edges.upperBound) pixels.")
        }
        guard let fields = arguments["region"] as? [String: Any] else {
            region = nil
            return
        }
        func value(_ key: String) -> Double? { (fields[key] as? NSNumber)?.doubleValue }
        guard let x = value("x"), let y = value("y"), let width = value("width"), let height = value("height"),
              x >= 0, y >= 0, width >= 0.01, height >= 0.01, x + width <= 1.000001, y + height <= 1.000001 else {
            throw MCPCommandError("invalid_arguments", "Give region as x, y, width and height in fractions of the picture from its top left: each side at least 0.01, and the box inside the picture.")
        }
        region = CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }

    func render<T>(_ work: () throws -> T) rethrows -> T {
        try JPEGReviewSize.$maxEdge.withValue(edge) { try JPEGReviewSize.$region.withValue(region, operation: work) }
    }

    /// Says what the returned picture left out, so a reader can ask for more of it.
    func describe(_ row: inout [String: Any], native size: (width: Int, height: Int)) {
        var native = size
        // The returned picture is upright. Report the whole picture the same way round.
        if let width = row["width"] as? Int, let height = row["height"] as? Int {
            let landscape = Double(width) / Double(region?.width ?? 1) >= Double(height) / Double(region?.height ?? 1)
            if native.width != native.height, (native.width > native.height) != landscape {
                native = (native.height, native.width)
            }
        }
        if let region {
            row["region"] = ["x": Double(region.minX), "y": Double(region.minY),
                             "width": Double(region.width), "height": Double(region.height)]
        }
        if region != nil || row["width"] as? Int != native.width || row["height"] as? Int != native.height {
            row["native_width"] = native.width
            row["native_height"] = native.height
        }
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
    var file: String? = nil

    func metadata(for image: ReviewImage) -> [String: Any] {
        var result: [String: Any] = ["space": clock, "width": image.width, "height": image.height,
                                    "duration": image.duration.description]
        result["time"] = time?.description
        result["group_time"] = group?.description
        result["playhead_seconds"] = playheadSeconds
        result["source_time"] = image.sourceTime?.description
        result["occurrence"] = occurrence
        result["source_id"] = source
        result["angle_id"] = angle
        result["file"] = file
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

        private enum CodingKeys: String, CodingKey {
            case file, space, time, duration, from, to, occurrence, asset, placement, width, height
            case source = "source_id", angle = "angle_id"
            case playheadSeconds = "playhead_seconds"
            case groupTime = "group_time"
            case sourceTime = "source_time"
        }
    }

    let schemaVersion = 2
    let selection = "program"
    let preset: JPEGPreset
    let frames: [Frame]
    var privacyIssues: [ParticipantPrivacyIssue]? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selection, preset, frames
        case privacyIssues = "privacy_issues"
    }
}

/// Review requests are independent of export jobs. Bound simultaneous decoder allocation.
@MainActor
private enum ReviewDecoders {
    static var active = 0
}

/// A single synchronous position lookup pass uses one project and clock.
private struct ReviewPlans {
    var stills: StillTimelinePlan?
    var assembly: MulticamPlan?
}

extension ProjectSessions {
    /// One reply carries every picture, base64-encoded, inside the 4 MiB socket frame.
    private static let reviewBatchFrames = 12
    private static let reviewBatchBytes = 2 << 20

    func mcpReviewFrame(arguments: [String: Any], session: ProjectSession,
                        checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        try checkAccess()
        guard (session.isMulticam ? session.multicam.mediaRefreshProgress : session.editor.mediaRefreshProgress) == nil else {
            throw MCPCommandError("busy", "Wait for the project media refresh to finish.")
        }
        let list = try (arguments["times"] as? [String]).map { try $0.map { try RationalTime(parsing: $0) } }
        let single = try (arguments["time"] as? String).map { try RationalTime(parsing: $0) }
        guard list == nil || single == nil else {
            throw MCPCommandError("invalid_arguments", "Supply time for one frame or times for several, not both.")
        }
        if let list, !(1...Self.reviewBatchFrames).contains(list.count) {
            throw MCPCommandError("invalid_arguments", "Supply 1 through \(Self.reviewBatchFrames) times.")
        }
        // One nil request reads the playhead.
        let requests: [RationalTime?] = list ?? [single]
        let space = arguments["space"] as? String
        let project = session.isMulticam ? session.multicam.project.map(CutProject.multicam) : session.editor.stillProject
        let angle = arguments["angle_id"] as? String
        let sourceID = arguments["source_id"] as? String, file = arguments["file"] as? String
        let sourceClock = space == "source"
        let view = arguments["view"] as? String ?? (angle == nil && !sourceClock ? "output" : "source")
        guard ["source", "output"].contains(view), angle == nil || view == "source" else {
            throw MCPCommandError("invalid_arguments", "Choose Source view to review an individual camera angle.")
        }
        guard angle == nil || session.isMulticam else {
            throw MCPCommandError("invalid_target", "Angles apply to multicam projects.")
        }
        guard sourceClock == (sourceID != nil || file != nil) else {
            throw MCPCommandError("invalid_arguments", "The source clock reads one recording: supply space \"source\" with its source_id or file.")
        }
        guard !sourceClock || (view == "source" && angle == nil) else {
            throw MCPCommandError("invalid_arguments", "The source clock shows the untreated recording. Omit view and angle_id.")
        }
        let sourceOnly = view == "source"
        guard (requests[0] == nil) == (space == nil) else {
            throw MCPCommandError("invalid_arguments", "Supply time or times with space, or omit them all for the playhead.")
        }
        let framing = try ReviewFraming(arguments)
        guard ReviewDecoders.active < 2 else { throw MCPCommandError("busy", "Two review requests are decoding. Retry when one finishes.") }
        ReviewDecoders.active += 1
        defer { ReviewDecoders.active -= 1 }
        let revision = session.mcpRevision
        let handle = session.mcpHandle
        let budget = Self.reviewBatchBytes
        @Sendable func charge(_ bytes: Int, to total: inout Int) throws {
            total += bytes
            guard total <= budget else {
                throw MCPCommandError("response_too_large", "These frames exceed 2 MiB together. Request fewer times or a smaller max_edge.")
            }
        }
        func checkCurrent() throws {
            try checkAccess()
            guard session.mcpHandle == handle, session.mcpRevision == revision else {
                throw MCPCommandError("stale_revision", "The timeline changed. Request the frame again.")
            }
        }
        var rows: [[String: Any]]
        if !sourceOnly, let project, project.requiresPictureProcessing {
            let context = try outputFrameContext(session: session, project: project, clock: space)
            let targets = requests.map { $0 ?? context.playhead }
            let work = session.sidecarWork.detached(priority: .userInitiated) {
                try framing.render {
                    let renderer = try ProjectOutputJPEG(context.project, document: context.document, cancelled: { Task.isCancelled })
                    var total = 0
                    let frames = try targets.map { time in
                        let frame = try renderer.frame(at: time.subtracting(context.origin), preset: .review)
                        try charge(frame.data.count, to: &total)
                        return frame
                    }
                    try renderer.verifySources()
                    return (frames, renderer.nativeSize)
                }
            }
            let (frames, programSize) = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try checkCurrent()
            rows = try zip(targets, frames).map { time, frame in
                var row: [String: Any] = ["space": context.clock, "time": time.description,
                                          "width": frame.width, "height": frame.height, "duration": frame.duration.description,
                                          "frame_time": try frame.frameTime.adding(context.origin).description,
                                          "jpeg": frame.data.base64EncodedString()]
                if !frame.privacyIssues.isEmpty { row["privacy_issues"] = try Self.outputJSON(frame.privacyIssues) }
                framing.describe(&row, native: (Int(programSize.width), Int(programSize.height)))
                return row
            }
        } else {
            var plans = ReviewPlans()
            let positions = try requests.map { time -> ReviewPosition in
                if sourceClock, let time {
                    return try sourceReview(session, time: time, sourceID: sourceID, file: file)
                }
                if session.isMulticam {
                    return try multicamReview(session.multicam, time: time, space: space,
                                              angle: angle, sourceOnly: sourceOnly, plans: &plans)
                }
                return try sequenceReview(session.editor, time: time, space: space, sourceOnly: sourceOnly, plans: &plans)
            }
            let pictures = positions.map(\.picture)
            let work = session.sidecarWork.detached(priority: .userInitiated) {
                try framing.render {
                    var total = 0
                    return try pictures.map { picture in
                        let image = try picture.render(preset: .review)
                        try charge(image.data.count, to: &total)
                        return (image, image.data.base64EncodedString())
                    }
                }
            }
            let images = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try checkCurrent()
            rows = try zip(positions, images).map { position, rendered in
                try position.picture.validateIdentity()
                var row = position.metadata(for: rendered.0)
                row["jpeg"] = rendered.1
                framing.describe(&row, native: position.picture.nativeSize)
                return row
            }
        }
        guard list != nil else {
            rows[0]["view"] = view
            return rows[0]
        }
        return ["view": view, "frames": rows]
    }

    /// A time on one recording's own clock, whether or not the edit still uses that part of it.
    private func sourceReview(_ session: ProjectSession, time: RationalTime, sourceID: String?, file: String?) throws -> ReviewPosition {
        let path = file.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        func check(_ media: MediaInfo) throws {
            guard time >= .zero, time <= media.duration else {
                throw MCPCommandError("invalid_target", "Choose a source time from 0 through \(media.duration) seconds.")
            }
        }
        guard session.isMulticam else {
            let (id, media) = try session.editor.mcpReviewSource(id: sourceID, file: file)
            try check(media)
            return ReviewPosition(picture: .video(media, time, exclusiveEnd: time == media.duration), clock: "source",
                                  time: time, source: id.uuidString, file: media.url.path)
        }
        let model = session.multicam
        guard let project = model.project else { throw MCPCommandError("no_frame", "Open a multicam project.") }
        guard let source = project.pictureSources.first(where: { source in
            (sourceID == nil || source.id == sourceID)
                && (path == nil || source.file == file || model.media[source.id]?.url.standardizedFileURL.path == path)
        }) else {
            throw MCPCommandError("invalid_target", "No camera recording in this project matches. Read source IDs from multicam_state_read.")
        }
        if let issue = model.refreshPictureIssue(sourceID: source.id) {
            throw MCPCommandError("source_needs_review", issue)
        }
        guard let media = model.media[source.id], media.hasFullEditIndex else {
            throw MCPCommandError("no_frame", "Choose an indexed camera in this project.")
        }
        try check(media)
        return try ReviewPosition(picture: .video(media, time, exclusiveEnd: time == media.duration), clock: "source",
                                  time: time, group: time.adding(source.offset), source: source.id, file: media.url.path)
    }

    private static let offSequence = "Choose a position on the open sequence. Material the edit no longer uses has no sequence time: read it with space \"source\" and its source_id or file."

    private func sequenceReview(_ editor: EditorModel, time: RationalTime?, space: String?,
                                sourceOnly: Bool = false, plans: inout ReviewPlans) throws -> ReviewPosition {
        let project = editor.stillProject
        if project.hasReviewStills {
            let plan = try plans.stills ?? project.resolveStills()
            plans.stills = plan
            let at = time ?? editor.stillReviewTime(in: plan)
            guard space == nil || space == "sequence", let index = plan.pictureIndex(at: at) else {
                throw MCPCommandError("invalid_target", Self.offSequence)
            }
            let span = plan.spans[index]
            if !sourceOnly, let placement = span.placementID {
                let frame = try project.stillReviewFrame(placementID: placement, interval: span.output,
                                                         document: editor.projectURL, canvas: editor.stillReviewCanvas)
                let occurrence: String?
                if case let .source(clipID, _) = span.origin {
                    occurrence = try editor.stillReviewOccurrenceID(clipID).uuidString
                } else {
                    occurrence = nil
                }
                return ReviewPosition(picture: .still(frame), clock: "sequence", time: at,
                                      occurrence: occurrence, interval: span.output)
            }
            if case let .source(clipID, range) = span.origin {
                let (id, source, media) = try editor.stillReviewOccurrence(clipID)
                if !sourceOnly, time == nil, let playhead = editor.jpegSourceAtPlayhead, let frame = playhead.frame {
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
                throw MCPCommandError("invalid_target", Self.offSequence)
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
                                angle: String?, sourceOnly: Bool = false, plans: inout ReviewPlans) throws -> ReviewPosition {
        guard let project = model.project else { throw MCPCommandError("no_frame", "Open a multicam project.") }
        let clock = space ?? (model.assemblyPreview ? "assembly" : "group")
        if CutProject.multicam(project).hasReviewStills {
            let context = try model.stillReviewContext(clock: clock, time: time, resolvedPlan: plans.stills)
            plans.stills = context.plan
            let span = context.plan.spans[context.index]
            let atEnd = context.time == context.plan.duration
            let group: RationalTime?
            let groupRange: MulticamRange?
            let occurrence: Int?
            if case let .group(index, range) = span.origin {
                occurrence = clock == "assembly" ? index : nil
                groupRange = range
                group = try range.from.adding(context.time.subtracting(span.output.from))
            } else {
                occurrence = nil
                groupRange = nil
                group = nil
            }
            let addressedTime = clock == "group" ? group : context.time
            if !sourceOnly, angle == nil, let placement = span.placementID {
                let frame = try context.project.stillReviewFrame(placementID: placement, interval: span.output,
                                                                 document: model.projectURL, canvas: model.stillReviewCanvas)
                return ReviewPosition(picture: .still(frame), clock: clock, time: addressedTime, group: group,
                                      occurrence: occurrence.map(String.init),
                                      interval: clock == "group" ? groupRange : span.output)
            }
            guard let group else {
                throw MCPCommandError("invalid_target", "This insert has no camera or group time.")
            }
            let selected = angle ?? project.pictureAngle(at: group, in: occurrence, exclusiveEnd: atEnd)
            guard let selected, let camera = project.pictureSource(for: selected, at: group, exclusiveEnd: atEnd) else {
                throw MCPCommandError("no_frame", "No camera recording covers this time.")
            }
            if let issue = model.refreshPictureIssue(sourceID: camera.id) {
                throw MCPCommandError("source_needs_review", issue)
            }
            guard let media = model.media[camera.id], media.hasFullEditIndex else {
                throw MCPCommandError("no_frame", "Choose an indexed camera in this project.")
            }
            let time = try group.subtracting(camera.offset)
            return ReviewPosition(picture: .video(media, time, exclusiveEnd: atEnd), clock: clock,
                                  time: addressedTime, group: group, occurrence: occurrence.map(String.init),
                                  source: camera.id, angle: selected)
        }
        let group: RationalTime
        let clockTime: RationalTime
        let exclusiveEnd: Bool
        let programAngle: String
        var occurrence: String?
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
            if time != nil {
                plan = try plans.assembly ?? project.plan()
                plans.assembly = plan
            } else if let current = model.mapping {
                plan = current
            } else {
                throw MCPCommandError("no_frame", "The program preview is unavailable.")
            }
            let at = time ?? model.preview.currentTime()
            let atEnd = at == plan.duration
            let index = plan.intervals.lowerBound { $0.output.to > at } - (atEnd ? 1 : 0)
            guard plan.intervals.indices.contains(index), plan.intervals[index].output.from <= at else {
                throw MCPCommandError("no_frame", "No active camera at this time.")
            }
            let interval = plan.intervals[index]
            group = try interval.group.from.adding(at.subtracting(interval.output.from))
            clockTime = clock == "group" ? group : at
            exclusiveEnd = atEnd
            programAngle = interval.angle
            if clock == "assembly" { occurrence = String(interval.assemblyIndex) }
        }
        let selected = angle ?? programAngle
        guard let source = project.pictureSource(for: selected, at: group, exclusiveEnd: exclusiveEnd) else {
            throw MCPCommandError("no_frame", "No camera recording covers this time.")
        }
        if let issue = model.refreshPictureIssue(sourceID: source.id) {
            throw MCPCommandError("source_needs_review", issue)
        }
        guard let media = model.media[source.id], media.hasFullEditIndex else {
            throw MCPCommandError("no_frame", "Choose an indexed camera in this project.")
        }
        return try ReviewPosition(picture: .video(media, group.subtracting(source.offset), exclusiveEnd: exclusiveEnd),
                                  clock: clock, time: clockTime, group: group, occurrence: occurrence,
                                  source: source.id, angle: selected)
    }
}

extension ProjectSessions {
    nonisolated static func writeStill(_ media: MediaInfo, time: RationalTime, exclusiveEnd: Bool = false,
                                       preset: JPEGPreset, to output: URL, progress: MCPLiveOutputProgress) throws -> [String: Any] {
        let frame = try JPEGExport.stillFrameTime(in: media, at: time, exclusiveEnd: exclusiveEnd)
        try JPEGExport.writeStill(media, at: time, to: output, replacing: nil, exclusiveEnd: exclusiveEnd,
                                  preset: preset, cancelled: { Task.isCancelled })
        progress.published(output)
        return ["source_time": frame.description, "frames": 1]
    }

    private struct OutputFrameContext: Sendable {
        let project: CutProject
        let document: URL?
        let clock: String
        let origin: RationalTime
        let playhead: RationalTime
    }

    private func outputFrameContext(session: ProjectSession, project: CutProject, clock: String?) throws -> OutputFrameContext {
        if case .multicam(let value) = project {
            let model = session.multicam
            let clock = clock ?? (model.assemblyPreview ? "assembly" : "group")
            if clock == "group" {
                let snapshot = try value.pictureExportSnapshot(ranges: [value.range])
                return .init(project: .multicam(snapshot), document: model.projectURL, clock: clock, origin: value.range.from,
                             playhead: model.currentGroupTime())
            }
            guard clock == "assembly" else { throw MCPCommandError("invalid_target", "Choose group or assembly time.") }
            return .init(project: project, document: model.projectURL, clock: clock, origin: .zero,
                         playhead: model.preview.currentTime())
        }
        guard clock == nil || clock == "sequence" else {
            throw MCPCommandError("invalid_target", "Choose sequence time.")
        }
        let editor = session.editor
        let position = editor.stillReviewTime(in: try project.resolveStills())
        return .init(project: project, document: editor.projectURL, clock: "sequence", origin: .zero, playhead: position)
    }

    func mcpProgramFrameExport(session: ProjectSession, output: URL, args: [String: Any],
                               mode: String, times: [RationalTime], preset: JPEGPreset) throws -> MCPLiveOutputJobs.Work? {
        let clock = args["space"] as? String
        if let clock, mode == "still" || mode == "playhead" {
            let active = session.isMulticam ? (session.multicam.assemblyPreview ? "assembly" : "group") : "sequence"
            guard clock == active else {
                throw MCPCommandError("invalid_target", "The playhead uses \(active) time.")
            }
        }
        let project = session.isMulticam ? session.multicam.project.map(CutProject.multicam) : session.editor.stillProject
        if let project, project.requiresPictureProcessing {
            let context: OutputFrameContext
            let requests: [RationalTime]
            if mode == "switches" {
                guard case .multicam(let value) = project, clock == nil || clock == "group" else {
                    throw MCPCommandError("invalid_target", "Switch sampling uses multicam group time.")
                }
                context = try outputFrameContext(session: session, project: project, clock: "group")
                requests = value.switches.map(\.at)
            } else {
                guard ["still", "playhead", "times"].contains(mode) else {
                    throw ParticipantProjectExport.unsupported("Sampling source scenes or audio")
                }
                context = try outputFrameContext(session: session, project: project, clock: clock)
                requests = mode == "times" ? times : [context.playhead]
            }
            let cancelled: @Sendable () -> Bool = { Task.isCancelled }
            return { progress in
                let renderer = try ProjectOutputJPEG(context.project, document: context.document, cancelled: cancelled)
                if mode == "still", let time = requests.first {
                    let frame = try renderer.writeStill(at: time.subtracting(context.origin), to: output, preset: preset)
                    progress.published(output)
                    var result: [String: Any] = ["frames": 1]
                    if !frame.privacyIssues.isEmpty { result["privacy_issues"] = try Self.outputJSON(frame.privacyIssues) }
                    return result
                }
                var privacyIssues: [ParticipantPrivacyIssue] = []
                try context.project.validateDestination(output, relativeTo: renderer.document, includesContents: true)
                let manifest = try JPEGExport.writeProgramFrameDirectory(to: output, cancelled: cancelled, validate: {
                    try context.project.validateDestination(output, relativeTo: renderer.document, includesContents: true)
                    try renderer.verifySources()
                }) { staging in
                    let frames = try requests.enumerated().map { index, time in
                        let image = try renderer.frame(at: time.subtracting(context.origin), preset: preset)
                        let name = String(format: "%06d.jpg", index + 1)
                        try image.data.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
                        privacyIssues.append(contentsOf: image.privacyIssues)
                        progress.update(Double(index + 1) / Double(requests.count))
                        return ProgramReviewManifest.Frame(file: name, space: context.clock, time: time,
                            playheadSeconds: nil, groupTime: context.clock == "group" ? time : nil, sourceTime: nil,
                            duration: image.duration,
                            from: try image.range.from.adding(context.origin), to: try image.range.to.adding(context.origin),
                            occurrence: nil, source: nil, angle: nil, asset: nil, placement: nil, width: image.width, height: image.height)
                    }
                    return ProgramReviewManifest(preset: preset, frames: frames, privacyIssues: privacyIssues.isEmpty ? nil : privacyIssues)
                }
                progress.published(output)
                var result: [String: Any] = ["manifest": output.appendingPathComponent("manifest.json").path, "frames": manifest.frames.count]
                if !privacyIssues.isEmpty { result["privacy_issues"] = try Self.outputJSON(privacyIssues) }
                return result
            }
        }
        guard clock != nil || (mode == "still" || mode == "playhead") && project?.hasReviewStills == true else { return nil }
        guard ["still", "playhead", "times"].contains(mode) else {
            throw MCPCommandError("invalid_arguments", "Program clocks support still, playhead, or explicit times.")
        }
        let requests = mode == "times" ? times.map(Optional.some) : [nil]
        var plans = ReviewPlans()
        let positions = try requests.map { time in
            if session.isMulticam {
                return try multicamReview(session.multicam, time: time, space: clock, angle: nil, plans: &plans)
            }
            return try sequenceReview(session.editor, time: time, space: clock, plans: &plans)
        }
        let cancelled: @Sendable () -> Bool = { Task.isCancelled }
        if mode == "still", let position = positions.first {
            return { progress in
                switch position.picture {
                case .still(let frame):
                    try frame.write(to: output, preset: preset, cancelled: cancelled)
                    progress.published(output)
                    return ["frames": 1, "placement": frame.placementID, "asset": frame.asset.id]
                case .video(let media, let time, let end):
                    return try Self.writeStill(media, time: time, exclusiveEnd: end, preset: preset, to: output, progress: progress)
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
