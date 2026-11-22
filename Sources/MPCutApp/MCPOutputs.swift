import Foundation
import MPCutCore

private let outputCancelled: @Sendable () -> Bool = { Task.isCancelled }

private func prepareOutput<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try work() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: { task.cancel() }
}

private func outputPath(_ args: [String: Any], _ key: String = "output") throws -> URL {
    guard let path = args[key] as? String, path.hasPrefix("/"), !path.utf8.contains(0) else {
        throw MCPCommandError("invalid_arguments", "Supply an absolute local path for \(key).")
    }
    return URL(fileURLWithPath: path)
}

private func outputEnum<T: RawRepresentable>(_ args: [String: Any], _ key: String, _ fallback: T) throws -> T where T.RawValue == String {
    guard let value = args[key] else { return fallback }
    guard let raw = value as? String, let result = T(rawValue: raw) else {
        throw MCPCommandError("invalid_arguments", "Unknown value for \(key).")
    }
    return result
}

private func exportOptions(_ args: [String: Any], container: String, source: ExportSourceKind,
                           defaultMode: ExportMode, placements: ExportPlacementScope = .none) throws -> ExportSheetOptions {
    guard !container.isEmpty, container.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
        throw MCPCommandError("invalid_arguments", "Supply a container filename extension.")
    }
    var options = ExportSheetOptions()
    let tracks = try outputEnum(args, "tracks", source == .audio ? ExportTracks.audio : .all)
    let ordinaryMode: ExportMode = source != .audio && tracks == .all ? defaultMode : .copy
    let mode = try outputEnum(args, "mode", ExportRules.defaultStillMode(tracks: tracks, placements: placements, otherwise: ordinaryMode))
    let cell = ExportRules.cell(source: source, tracks: tracks, mode: mode, placements: placements)
    if let refusal = cell.refusal, refusal.code != "still_generation_required" { throw refusal }
    options.placements = placements
    options.requireCameraCopy = args["requireCameraCopy"] as? Bool ?? false
    options.tracks = cell.tracks
    options.mode = cell.resolvedMode
    options.codec = try outputEnum(args, "codec", .h264)
    options.audio = try outputEnum(args, "audio", .auto)
    let quality = try outputEnum(args, "quality", options.codec == .prores ? ReencodeQuality.prores422 : .balanced)
    options.standardQuality = quality
    options.proResQuality = quality
    options.copyContainer = container
    options.encodeContainer = container
    options.proResContainer = container
    options.audioTrackOrdinal = args["audioTrackOrdinal"] as? Int
    if let ordinal = options.audioTrackOrdinal, options.tracks != .audio || ordinal < 0 {
        throw MCPCommandError("invalid_arguments", "Choose audio tracks before specifying a zero-based track ordinal.")
    }
    if options.tracks == .audio && options.mode == .encode {
        options.audioMode = .encode
        options.audioFormat = args["audio"] == nil ? .pcm : options.audio
        options.conversionContainer = container
        guard args["codec"] == nil, args["quality"] == nil, cell.audioActions.contains(options.audioFormat) else {
            throw MCPCommandError("invalid_arguments", "Choose a supported audio conversion action without video codec or quality settings.")
        }
    } else if options.mode == .encode {
        guard (cell.tracks == .video && options.audio == .auto || cell.audioActions.contains(options.audio)),
              ExportRules.allows(audio: options.audio, inMovieContainer: container) else {
            throw CutError(code: "unsupported_audio", message: "The requested audio action cannot be used for a movie in .\(container).")
        }
    } else {
        let audio: [ReencodeAudio] = placements != .none && options.mode == .smart && options.tracks == .all
            ? [.auto, .copyOriginal, .aac, .pcm, .removeAudio] : [.auto, .copyOriginal]
        guard args["codec"] == nil, args["quality"] == nil, audio.contains(options.audio) else {
            throw MCPCommandError("invalid_arguments", "Choose settings supported for the selected mode and tracks.")
        }
    }
    return options
}

extension ProjectSessions {
    func mcpOutputs(tool: String, arguments: [String: Any], session: ProjectSession,
                    checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        let owner = arguments["project"] as? String ?? ""
        let revision = session.mcpRevision
        let handle = session.mcpHandle
        let validateEdit: @MainActor () throws -> Void = {
            try checkAccess()
            guard session.mcpHandle == handle, session.mcpRevision == revision else {
                throw MCPCommandError("stale_revision", "The project changed. Read its current state and retry.")
            }
            guard session.window?.attachedSheet == nil, session.isMulticam || !session.editor.mcpHasActiveTrim else {
                throw MCPCommandError("busy", "Finish the active dialog or timeline gesture.")
            }
        }
        switch tool {
        case "live_job_status", "cancel_live_job":
            try checkAccess()
            return try mcpOutputJobs.status(owner: owner, id: arguments["job"] as? String ?? "", cancel: tool == "cancel_live_job")
        case "get_export_queue", "add_export_range", "remove_export_range":
            if tool == "get_export_queue" { try checkAccess() } else { try validateEdit() }
            return try updateMCPQueue(tool, session: session, id: arguments["id"] as? String)
        case "replace_live_audio":
            try validateEdit()
            return try await replaceMCPAudio(arguments, session: session, checkAccess: validateEdit)
        case "render_project", "export_queue", "export_review_frames", "convert_live_project", "send_live_to_resolve", "apply_export_review":
            break
        default: return nil
        }
        try validateEdit()
        let output = try outputPath(arguments)
        let multi = session.multicam
        let editor = session.editor
        let directory = tool == "export_review_frames" && arguments["selection"] as? String != "still"
            || tool == "convert_live_project" && ["fcpbundle", "fcpxmld"].contains(output.pathExtension.lowercased())
        let sidecars = session.isMulticam ? multi.useAnalysisSidecars : editor.useAnalysisSidecars
        let excluded = session.isMulticam ? multi.sidecarExclusions : editor.sidecarExclusions
        if session.isMulticam {
            guard !multi.isBusy, multi.project != nil || tool == "export_queue" else { throw MCPCommandError("busy", "Wait for the multicam project to become ready.") }
            try multi.validateHistoryDestination(output, includesContents: directory)
        } else {
            guard tool == "export_queue" ? !editor.isBusy : editor.canEdit else {
                throw MCPCommandError("busy", "Wait for a committed sequence.")
            }
            try editor.validateHistoryDestination(output, includesContents: directory)
        }
        let work: MCPLiveOutputJobs.Work
        switch tool {
        case "apply_export_review":
            if let adjustment = arguments["stillAdjustment"] {
                return try await mcpApplyStillExportReview(adjustment, args: arguments, session: session, output: output, validateEdit: validateEdit)
            }
            if let project = session.mcpStillProject, project.mcpHasStills {
                throw MCPCommandError("invalid_target", "Supply a verified stillAdjustment from the camera-copy preflight.")
            }
            guard !session.isMulticam else { throw MCPCommandError("invalid_target", "Use the multicam switch editor for suggested group boundaries.") }
            let input = try editor.mcpExportInput(selection: false)
            let copyOptions = try exportOptions([:], container: output.pathExtension.lowercased(),
                                                source: editor.isAudioOnly ? .audio : .movie, defaultMode: .copy)
            let availability = try await prepareOutput {
                AnalysisSidecar.$excludedSources.withValue(excluded) {
                    ExportAvailability.check(copyOptions, clips: input.clips, media: input.media, useSidecar: sidecars)
                }
            }
            try validateEdit()
            guard case .unavailable(_, let review?) = availability else {
                throw MCPCommandError("no_review", "No boundary changes are available for this sequence.")
            }
            editor.applyExportReview(review)
            guard editor.mcpRevision != revision else { throw MCPCommandError("unavailable", "The native editor could not apply this review.") }
            return ["action": "Apply Reviewed Cuts", "revision": editor.mcpRevision, "review": review.detail]
        case "export_queue": work = try mcpQueueExport(session: session, output: output, args: arguments)
        case "export_review_frames": work = try mcpFrames(session: session, output: output, args: arguments)
        case "render_project": work = try mcpRender(session: session, output: output, args: arguments)
        default:
            work = try mcpInterchange(session: session, output: output, args: arguments, resolve: tool == "send_live_to_resolve")
        }
        try checkAccess()
        let conversion = ["convert_live_project", "send_live_to_resolve"].contains(tool) ? EditCancellation() : nil
        if conversion != nil && isConvertingProject { throw MCPCommandError("busy", "A project conversion is already running.") }
        let ticket = try mcpOutputJobs.start(owner: owner, revision: revision, nativeCancellation: conversion, finished: { [weak self] in
            if let self, let conversion, self.projectConversion === conversion { self.finishProjectConversion() }
        }) { progress in
            try AnalysisSidecar.$excludedSources.withValue(excluded) {
                try AnalysisSidecar.$readsEnabled.withValue(sidecars) { try work(progress) }
            }
        }
        if let conversion {
            conversionOwner = owner
            projectConversion = conversion
        }
        return ticket
    }

    private func updateMCPQueue(_ tool: String, session: ProjectSession, id: String?) throws -> [String: Any] {
        let editor = session.editor, multi = session.multicam
        if tool == "add_export_range" {
            guard session.isMulticam ? multi.canEnqueueMarkedRange : editor.canAddMarkedRange else {
                throw MCPCommandError("no_selection", "Mark a range in the target editor before adding it to the queue.")
            }
            let count = session.isMulticam ? multi.queuedRanges.count : editor.queuedRanges.count
            if session.isMulticam { multi.enqueueMarkedRange() } else { editor.addMarkedRange() }
            guard (session.isMulticam ? multi.queuedRanges.count : editor.queuedRanges.count) > count else {
                throw MCPCommandError("queue_failed", multi.notice?.message ?? editor.alert?.message ?? "The marked range could not be queued.")
            }
        }
        if tool == "remove_export_range" {
            guard let id, let uuid = UUID(uuidString: id),
                  session.isMulticam ? multi.queuedRanges.contains(where: { $0.id == uuid }) : editor.queuedRanges.contains(where: { $0.id == uuid }) else {
                throw MCPCommandError("invalid_target", "Choose an entry from get_export_queue.")
            }
            guard !(session.isMulticam ? multi.isExporting : editor.isExporting) else { throw MCPCommandError("busy", "Wait for the active GUI export.") }
            if session.isMulticam { multi.removeQueuedRange(uuid) } else { editor.removeQueuedRange(uuid) }
        }
        let entries: [[String: String]] = session.isMulticam
            ? multi.queuedRanges.map { ["id": $0.id.uuidString, "from": $0.range.from.description, "to": $0.range.to.description] }
            : editor.queuedRanges.map { ["id": $0.id.uuidString, "from": $0.start.description, "to": $0.end.description] }
        return ["ranges": entries, "coordinateSpace": session.isMulticam ? "group" : "sequence"]
    }

    private func mcpRender(session: ProjectSession, output: URL, args: [String: Any]) throws -> MCPLiveOutputJobs.Work {
        let scope = args["scope"] as? String ?? "timeline"
        let dryRun = args["dryRun"] as? Bool ?? true
        if let snapshot = try mcpRenderStillSnapshot(session: session, scope: scope) {
            return try mcpRenderStills(session: session, snapshot: snapshot, output: output, args: args, dryRun: dryRun)
        }
        let source: ExportSourceKind = session.isMulticam ? .multicam : (session.editor.isAudioOnly ? .audio : .movie)
        let options = try exportOptions(args, container: output.pathExtension.lowercased(), source: source,
                                        defaultMode: preferences.defaultExportMode)
        guard !options.requireCameraCopy || options.tracks == .audio || options.effectiveMode == .copy else {
            throw MCPCommandError("invalid_arguments", "Select Lossless Copy to preserve camera samples.")
        }
        let useReviewedCuts = args["useReviewedCuts"] as? Bool ?? false
        guard !useReviewedCuts || (!session.isMulticam && options.mode == .copy && options.tracks == .all) else {
            throw MCPCommandError("invalid_arguments", "Reviewed export cuts apply to ordinary full-track copy exports.")
        }
        if session.isMulticam, let project = session.multicam.project {
            let model = session.multicam
            let selection = scope == "selection" ? model.selectedExportRanges : nil
            guard selection?.isEmpty != true else {
                throw MCPCommandError("no_selection", "Select a multicam range first.")
            }
            if let message = model.exportSourceIssue(tracks: options.tracks, wholeGroup: scope == "group", mode: options.mode,
                                                     settings: options.settings, selection: selection) {
                throw MCPCommandError("unavailable", message)
            }
            guard options.audioTrackOrdinal == nil else { throw MCPCommandError("invalid_arguments", "Use project audio routing for multicam exports.") }
            let ranges = selection ?? (scope == "group" ? [project.range] : nil)
            let indexed = model.media.filter { $0.value.hasFullEditIndex }
            let location = model.projectURL
            return { progress in
                let engine = MulticamEngine(cancelled: outputCancelled)
                try CutEngine().checkDestination(output)
                let plan: MulticamExportPlan
                do {
                    plan = try engine.resolution(project, relativeTo: location, output: output, mode: options.effectiveMode,
                                                 tracks: options.tracks, assembly: ranges, settings: options.settings, indexedSources: indexed).get()
                } catch let issue as CutError where dryRun {
                    try Task.checkCancellation()
                    return try Self.outputRefusal(issue)
                }
                if !dryRun {
                    try engine.write(plan, to: output) { progress.update($0) }
                    progress.published(output)
                }
                return ["eligible": true, "dryRun": dryRun, "plan": try Self.outputJSON(plan)]
            }
        }
        guard scope != "group" else { throw MCPCommandError("invalid_target", "Group time requires a multicam project.") }
        let input = try session.editor.mcpExportInput(selection: scope == "selection")
        let useSidecar = session.editor.useAnalysisSidecars
        return { progress in
            try CutEngine().checkDestination(output)
            var resolved = ExportAvailability.resolve(options, clips: input.clips, media: input.media, useSidecar: useSidecar)
            var reviewDetail: String?
            if useReviewedCuts, case .unavailable(_, let review?) = resolved.availability {
                reviewDetail = Self.outputDetail(review.detail)
                resolved = ExportAvailability.resolve(options, clips: review.revised, media: input.media, useSidecar: useSidecar)
            }
            try Task.checkCancellation()
            switch resolved.availability {
            case .unavailable(let message, let review):
                var issue = resolved.failure ?? CutError(code: "unavailable", message: message)
                let alternatives = resolved.offers.map(\.alternative)
                issue.alternatives = alternatives.isEmpty ? nil : alternatives
                if !dryRun { throw issue }
                var result = try Self.outputRefusal(issue)
                result["reason"] = Self.outputDetail(message)
                if let review {
                    result["review"] = Self.outputDetail(review.detail)
                    result["proposedRanges"] = try Self.outputJSON(review.revised.map { clip in
                        var item = ["file": clip.file.path]
                        item["from"] = clip.from?.description
                        item["to"] = clip.to?.description
                        return item
                    })
                }
                return result
            case .stillReady(let plan):
                if !dryRun {
                    try StillExportPlanner(cancelled: outputCancelled).write(plan, to: output) { fraction in
                        progress.update(fraction)
                        return !Task.isCancelled
                    }
                    progress.published(output)
                }
                return ["eligible": true, "dryRun": dryRun, "plan": try Self.outputJSON(plan.report)]
            case .ready(let plan):
                if !dryRun {
                    try plan.writeOutput(to: output, cancelled: outputCancelled) { progress.update($0) }
                    progress.published(output)
                }
                var result: [String: Any] = ["eligible": true, "dryRun": dryRun, "summary": plan.summary]
                result["appliedToExportOnly"] = reviewDetail
                switch plan {
                case .packets(let edit, _, _): result["plan"] = try Self.outputJSON(edit)
                case .conversion(let conversion): result["plan"] = try Self.outputJSON(conversion)
                case .audio(let audio):
                    result["plan"] = try Self.outputJSON(audio.edit)
                    result["audioActions"] = try Self.outputJSON(audio.actions)
                    result["warnings"] = audio.warnings
                }
                return result
            }
        }
    }

    private func mcpRenderStillSnapshot(session: ProjectSession, scope: String) throws -> CutProject? {
        guard let project = session.mcpStillProject, project.mcpHasStills else { return nil }
        if case .multicam(var value) = project {
            if scope == "group" { value.assemblyItems = nil }
            if scope == "selection" {
                let model = session.multicam
                if let selection = model.assemblySelection {
                    value = try value.assemblySelection(.init(from: selection.from, to: selection.to))
                } else {
                    let ranges = model.selectedExportRanges
                    guard !ranges.isEmpty else { throw MCPCommandError("no_selection", "Select a multicam range first.") }
                    value.assembly = ranges
                }
            }
            return .multicam(value)
        }
        guard scope != "group" else { throw MCPCommandError("invalid_target", "Group time requires a multicam project.") }
        guard scope == "selection" else { return project }
        guard session.editor.canActOnRange else { throw MCPCommandError("no_selection", "Select a timeline range first.") }
        return try session.editor.stillProjectForSelection()
    }

    private func mcpRenderStills(session: ProjectSession, snapshot: CutProject, output: URL,
                                 args: [String: Any], dryRun: Bool) throws -> MCPLiveOutputJobs.Work {
        guard args["useReviewedCuts"] as? Bool != true else {
            throw MCPCommandError("invalid_target", "Use still placement edits to change a still boundary.")
        }
        let tracks = try outputEnum(args, "tracks", ExportTracks.all)
        let placements = try snapshot.exportPlacementScope()
        let ordinaryMode: ExportMode = tracks == .all ? preferences.defaultExportMode : .copy
        let mode = try outputEnum(args, "mode", ExportRules.defaultStillMode(tracks: tracks, placements: placements, otherwise: ordinaryMode))
        let codec = try outputEnum(args, "codec", ReencodeCodec.h264)
        let quality = try outputEnum(args, "quality", codec == .prores ? ReencodeQuality.prores422 : .balanced)
        let audio = try outputEnum(args, "audio", ReencodeAudio.auto)
        if args["codec"] != nil || args["quality"] != nil {
            guard mode == .encode, tracks != .audio else {
                throw MCPCommandError("invalid_arguments", "Video codec and quality apply to picture encode mode.")
            }
        }
        let settings = ReencodeSettings(codec: codec, quality: quality, audio: audio)
        let requireCameraCopy = args["requireCameraCopy"] as? Bool ?? false
        if case .multicam(let project) = snapshot,
           let issue = session.multicam.refreshExportIssue(in: try project.plan(), tracks: tracks, mode: mode, settings: settings) {
            throw MCPCommandError("source_needs_review", issue)
        }
        let location = session.mcpStillLocation
        let sidecar = session.isMulticam ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let mediaFiles: [String]
        switch snapshot {
        case .sequence(let clips):
            if let issue = session.editor.refreshedSourceIssue(for: clips) {
                throw MCPCommandError("source_needs_review", issue)
            }
            mediaFiles = clips.map(\.file)
        case .stillSequence(let sequence):
            let clips = sequence.items.compactMap(\.source)
            if let issue = session.editor.refreshedSourceIssue(for: clips) {
                throw MCPCommandError("source_needs_review", issue)
            }
            mediaFiles = clips.map(\.file)
        case .multicam(let project): mediaFiles = project.sources.map(\.file)
        }
        let document = location ?? URL(fileURLWithPath: "/Untitled.cut")
        let referencedMedia = Set(mediaFiles.map { CutProject.mediaURL($0, relativeTo: document).path })
        let indexed = session.isMulticam ? Array(session.multicam.media.values) : Array(session.editor.analysisSourceMedia.values)
        let pinnedMedia = indexed.filter { referencedMedia.contains($0.url.path) }
        let audioStream: Int?
        if let ordinal = args["audioTrackOrdinal"] as? Int {
            let tracksByOrdinal = session.editor.audioTracks
            guard !session.isMulticam, tracks == .audio, tracksByOrdinal.indices.contains(ordinal) else {
                throw MCPCommandError("invalid_arguments", "Choose an available ordinary audio track ordinal with audio-only output.")
            }
            audioStream = tracksByOrdinal[ordinal].index
        } else {
            audioStream = nil
        }
        return { progress in
            let planner = StillExportPlanner(useSidecar: sidecar, cancelled: outputCancelled)
            let plan: StillExportPlan
            do {
                for media in pinnedMedia where !media.identity.isCurrentSnapshot(at: media.url) {
                    throw CutError(code: "source_changed", message: "\(media.url.lastPathComponent) changed after the render was requested.")
                }
                plan = try planner.resolve(snapshot, relativeTo: location, tracks: tracks, audioStream: audioStream,
                                           mode: mode, requireCameraCopy: requireCameraCopy, output: output, settings: settings)
            } catch let issue as CutError where dryRun {
                try Task.checkCancellation()
                return try Self.outputRefusal(issue)
            }
            if !dryRun {
                try planner.write(plan, to: output) { fraction in
                    progress.update(fraction)
                    return !Task.isCancelled
                }
                progress.published(output)
            }
            return ["eligible": true, "dryRun": dryRun, "plan": try Self.outputJSON(plan.report)]
        }
    }

    private func mcpApplyStillExportReview(_ value: Any, args: [String: Any], session: ProjectSession, output: URL,
                                           validateEdit: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        guard session.mcpCanEditStills, let project = session.mcpStillProject, project.mcpHasStills else {
            throw MCPCommandError("invalid_target", "An editable still placement is required.")
        }
        let adjustment = try JSONDecoder().decode(StillBoundaryAdjustment.self, from: JSONSerialization.data(withJSONObject: value))
        let mode = try outputEnum(args, "mode", ExportMode.smart)
        let tracks = try outputEnum(args, "tracks", ExportTracks.all)
        let audio = try outputEnum(args, "audio", ReencodeAudio.auto)
        guard tracks != .audio else { throw MCPCommandError("invalid_arguments", "Select picture to review a camera boundary.") }
        let settings = ReencodeSettings(audio: audio)
        let location = session.mcpStillLocation
        let sidecar = session.isMulticam ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let candidate = try project.applyingStillBoundary(adjustment)
        let report = try await prepareOutput {
            let planner = StillExportPlanner(useSidecar: sidecar, cancelled: outputCancelled)
            do {
                _ = try planner.resolve(project, relativeTo: location, tracks: tracks, mode: mode, requireCameraCopy: true,
                                        output: output, settings: settings)
                throw MCPCommandError("no_review", "The current timeline can already preserve camera samples.")
            } catch let issue as CutError {
                guard issue.stillBoundaryAdjustments?.contains(adjustment) == true else { throw issue }
            }
            return try planner.resolve(candidate, relativeTo: location, tracks: tracks, mode: mode, requireCameraCopy: true,
                                       output: output, settings: settings).report
        }
        try validateEdit()
        let action = "Apply Reviewed Still Boundary"
        try session.mcpCommitStill(candidate, action: action)
        return ["action": action, "revision": session.mcpRevision, "placement": adjustment.placementID,
                "review": try Self.outputJSON(adjustment), "plan": try Self.outputJSON(report),
                "historyRetained": preferences.historyLimit > 0]
    }

    nonisolated private static func outputRefusal(_ issue: CutError) throws -> [String: Any] {
        var detail = issue
        detail.alternatives = nil
        var result: [String: Any] = ["eligible": false, "dryRun": true, "reason": outputDetail(issue.message),
                                     "issue": MCPLiveOutputJobs.errorFields(detail)]
        if let alternatives = issue.alternatives, let first = alternatives.first {
            result["fallback"] = ["title": first.label, "mode": first.mode.rawValue, "container": first.container]
            result["alternatives"] = try outputJSON(alternatives)
        }
        return result
    }

    nonisolated private static func outputDetail(_ value: String) -> String {
        String(decoding: value.utf8.prefix(32_768), as: UTF8.self)
    }

    nonisolated private static func outputJSON(_ value: some Encodable) throws -> Any {
        let data = try JSONEncoder().encode(value)
        guard data.count < 1_500_000 else { return ["truncated": true, "encodedBytes": data.count] }
        return try JSONSerialization.jsonObject(with: data)
    }
}

extension EditorExportPlan {
    func writeOutput(to output: URL, cancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double) -> Void) throws {
        try ExportPlanner(cancelled: cancelled).write(self, to: output) {
            progress($0)
            return !cancelled()
        }
    }
}

private extension ProjectSessions {
    func mcpInterchange(session: ProjectSession, output: URL, args: [String: Any], resolve: Bool) throws -> MCPLiveOutputJobs.Work {
        let snapshot: CutProject
        let sequence: [ClipRequest]
        let ordinary: [MediaInfo]
        let indexed: [String: MediaInfo]
        if session.isMulticam, let project = session.multicam.project {
            snapshot = .multicam(project)
            indexed = session.multicam.media
            sequence = []; ordinary = []
        } else {
            snapshot = session.editor.stillProject
            if snapshot.mcpHasStills {
                sequence = []; ordinary = []; indexed = [:]
            } else {
                let input = try session.editor.mcpExportInput(selection: false)
                sequence = input.clips; ordinary = Array(input.media.values); indexed = [:]
            }
        }
        let location = (session.isMulticam ? session.multicam.projectURL : session.editor.projectURL) ?? output
        let allowLoss = args["allowLoss"] as? Bool ?? false
        let flatten = args["flattenMulticam"] as? Bool ?? false
        let open = args["openInResolve"] as? Bool ?? false
        return { progress in
            if resolve {
                try ResolveExport.rejectUnsupportedStills(snapshot)
                switch snapshot {
                case .multicam(let project):
                    try ResolveExport.write(project, relativeTo: location, to: output, useSidecar: AnalysisSidecar.readsEnabled,
                                            matching: indexed, auxiliaryOutput: progress.published, cancelled: outputCancelled)
                case .sequence, .stillSequence:
                    try ResolveExport.write(sequence, to: output, useSidecar: AnalysisSidecar.readsEnabled,
                                            matching: ordinary, auxiliaryOutput: progress.published, cancelled: outputCancelled)
                }
                progress.published(output)
                if open { try ResolveExport.openInResolve(output, cancelled: outputCancelled) }
                return ["openedInResolve": open]
            }
            let warnings = try ProjectConverter.write(snapshot, relativeTo: location, to: output, allowLoss: allowLoss,
                                                      flattenMulticam: flatten, auxiliaryOutput: progress.published, cancelled: outputCancelled)
            progress.published(output)
            return ["warnings": warnings]
        }
    }

    func mcpQueueExport(session: ProjectSession, output: URL, args: [String: Any]) throws -> MCPLiveOutputJobs.Work {
        let container = (args["container"] as? String ?? "mov").lowercased()
        let multi = session.isMulticam
        let protected = multi ? session.multicam.protectedMediaPaths : session.editor.mcpOutputProtectedMedia
        let ranges = session.editor.queuedRanges
        let groups = session.multicam.queuedRanges
        let dryRun = args["dryRun"] as? Bool ?? true
        if let issue = multi ? session.multicam.queuedMediaRefreshIssue() : session.editor.queuedMediaRefreshIssue() {
            throw MCPCommandError(issue.code, issue.message)
        }
        guard !(multi ? groups.isEmpty : ranges.isEmpty) else { throw MCPCommandError("empty_queue", "Queue at least one range first.") }
        let hasVideo = ranges.contains { $0.stillProject != nil || $0.media.values.contains(where: \.hasVideo) }
        let source: ExportSourceKind = multi ? .multicam : (hasVideo ? .movie : .audio)
        var placements = ranges.map(\.placements).max(by: { $0.rawValue < $1.rawValue }) ?? .none
        for entry in groups {
            var project = entry.project
            if !entry.usesAssembly { project.assemblyItems = [.group(entry.range)] }
            let scope = try CutProject.multicam(project).exportPlacementScope()
            if scope.rawValue > placements.rawValue { placements = scope }
        }
        let options = try exportOptions(args, container: container, source: source,
                                        defaultMode: preferences.defaultExportMode, placements: placements)
        let mode = try (args["mode"] as? String).map { _ in try outputEnum(args, "mode", ExportMode.copy) }
        let sidecars = multi ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let defaultOrdinaryMode: ExportMode = source != .audio && options.tracks == .all ? preferences.defaultExportMode : .copy
        let hasStills = placements != .none
        guard !multi || options.audioTrackOrdinal == nil else { throw MCPCommandError("invalid_arguments", "Multicam uses routed program audio.") }

        return { progress in
            let outputs: [URL]
            let write: (Int, @escaping @Sendable (Double) -> Void) throws -> Void
            var plans: [[String: Any]] = []
            do {
                if multi {
                    let engine = MulticamEngine(cancelled: outputCancelled)
                    let batch = try MulticamBulkExport(ranges: groups, directory: output, container: container,
                                                       mode: mode ?? (!hasStills ? options.effectiveMode : nil),
                                                       tracks: options.tracks, settings: options.batchSettings, engine: engine,
                                                       requireCameraCopy: options.requireCameraCopy, cancelled: outputCancelled)
                    outputs = batch.items.map(\.output)
                    plans = try batch.items.compactMap { item in
                        guard let report = item.stillReport else { return nil }
                        return ["destination": item.output.path, "plan": try Self.outputJSON(report)]
                    }
                    write = { try batch.write(batch.items[$0], progress: $1) }
                } else {
                    var identities: [URL: SourceIdentity] = [:]
                    for range in ranges {
                        try Task.checkCancellation()
                        for (url, media) in range.media {
                            if let previous = identities[url], previous != media.identity {
                                throw CutError(code: "source_changed", message: "Queued ranges refer to different versions of \(url.lastPathComponent).")
                            }
                            identities[url] = media.identity
                        }
                    }
                    let batch = try SequenceQueuePlan(ranges, directory: output, options: options, useSidecar: sidecars,
                                                      ordinaryModeWhenUnspecified: mode == nil ? defaultOrdinaryMode : nil,
                                                      cancelled: outputCancelled)
                    outputs = batch.items.map(\.output)
                    plans = try batch.items.compactMap { item in
                        guard case .still(let plan) = item.payload else { return nil }
                        return ["destination": item.output.path, "plan": try Self.outputJSON(plan.report)]
                    }
                    write = { index, update in
                        try batch.write(batch.items[index]) {
                            update($0)
                            return !Task.isCancelled
                        }
                    }
                }
            } catch let issue as CutError where dryRun && hasStills {
                try Task.checkCancellation()
                return try Self.outputRefusal(issue)
            }
            for path in outputs { try CutProject.validateMediaDestination(path, absoluteSources: protected) }
            if !dryRun {
                for (i, path) in outputs.enumerated() {
                    try Task.checkCancellation()
                    try write(i) { progress.update((Double(i) + $0) / Double(outputs.count)) }
                    progress.published(path)
                }
            }
            var result: [String: Any] = ["dryRun": dryRun, "destinations": outputs.map(\.path)]
            if !plans.isEmpty { result["stillPlans"] = plans }
            return result
        }
    }

    func mcpFrames(session: ProjectSession, output: URL, args: [String: Any]) throws -> MCPLiveOutputJobs.Work {
        let mode = args["selection"] as? String ?? "playhead"
        let times = try (args["times"] as? [String] ?? []).map { try RationalTime(parsing: $0) }
        guard (mode == "times") == !times.isEmpty, times.count <= 4096 else {
            throw MCPCommandError("invalid_arguments", "Supply up to 4096 times with explicit timestamp selection.")
        }
        if mode == "still", !["jpg", "jpeg"].contains(output.pathExtension.lowercased()) {
            throw MCPCommandError("invalid_arguments", "Choose a .jpg or .jpeg destination for a still frame.")
        }
        let sample = try outputEnum(args, "sample", JPEGSample.midpoint)
        let preset = try outputEnum(args, "preset", preferences.jpegPreset)
        let limit = args["limit"] as? Int
        if let limit, limit < 1 || !["scenes", "nonSilent"].contains(mode) {
            throw MCPCommandError("invalid_arguments", "Supply a positive limit with scene or non-silent sampling.")
        }
        if let work = try mcpProgramFrameExport(session: session, output: output, args: args, mode: mode, times: times, preset: preset) {
            return work
        }
        if session.isMulticam, let project = session.multicam.project {
            let model = session.multicam, indexed = model.media
            let sidecar = model.useAnalysisSidecars
            if ["playhead", "times", "switches"].contains(mode) {
                let targets: [RationalTime]
                switch mode {
                case "switches": targets = project.switches.map(\.at)
                case "times": targets = times
                default:
                    guard let mapping = model.mapping else { throw MCPCommandError("no_picture", "No active program preview.") }
                    let position = model.preview.currentTime()
                    var group = model.groupTime(at: position)
                    if position == mapping.duration, let last = mapping.intervals.last {
                        let epsilon = RationalTime(numerator: 1, denominator: 1_000_000_000)
                        group = max(last.group.from, (try? group.subtracting(epsilon)) ?? last.group.from)
                    }
                    targets = [group]
                }
                let cameras = targets.compactMap { project.selection(at: $0)?.angle }
                if let issue = cameras.lazy.compactMap({ model.refreshPictureIssue(sourceID: $0) }).first {
                    throw MCPCommandError("source_needs_review", issue)
                }
                let url = model.projectURL
                return { progress in
                    let manifest = try JPEGExport.writeMulticam(project, document: url, at: targets, to: output, preset: preset,
                                                                useSidecar: sidecar, indexedSources: indexed, cancelled: outputCancelled)
                    progress.published(output)
                    let count = manifest.frames.filter { $0.file != nil }.count
                    return ["manifest": output.appendingPathComponent("manifest.json").path,
                            "frames": count, "unavailable": manifest.frames.count - count]
                }
            }
            guard let mapping = model.mapping else { throw MCPCommandError("no_picture", "No active program preview.") }
            let active = try MulticamStillPosition.at(model.preview.currentTime(), in: mapping)
            if let issue = model.refreshPictureIssue(sourceID: active.angle) {
                throw MCPCommandError("source_needs_review", issue)
            }
            guard let source = indexed[active.angle], source.hasFullEditIndex else {
                throw MCPCommandError("unavailable", "Wait for the active camera to finish indexing.")
            }
            if mode == "still" {
                return { progress in
                    try Self.writeStill(source, time: active.sourceTime, exclusiveEnd: active.exclusiveEnd, to: output, progress: progress)
                }
            }
            let ordinary = model.ordinaryAnalysisMedia(active.angle)
            let snapshot = ordinary.map(model.analysis.snapshot(for:))
            let stream = project.angles.first(where: { $0.id == active.angle })?.audioStream ?? source.audio.first?.stream.index
            let threshold = stream.flatMap { model.analysis.threshold(for: .init(source: active.angle, stream: $0)) }
            let minimumPause = preferences.minimumPause
            return { progress in
                let media = try ordinary ?? CutEngine(cancelled: outputCancelled, useSidecar: sidecar)
                    .inspect(source.url, keyframes: true, expectedIdentity: source.identity)
                let selection: JPEGSelection
                if mode == "scenes" {
                    selection = snapshot?.scenes.map(JPEGSelection.sceneReport) ?? .scenes
                } else if let result = snapshot?.silence.first(where: { $0.stream == stream && $0.minimum == minimumPause }),
                          try media.extendingToAudioEnd(stream: result.stream).duration == media.duration {
                    selection = .audibleRanges(pauses: result.pauses, stream: result.stream,
                                               thresholdDB: result.thresholdDB, minimumPause: minimumPause)
                } else {
                    selection = .nonSilent(stream: stream, thresholdDB: threshold, minimumPause: minimumPause)
                }
                return try Self.writeFrameSet(media, selection: selection, sample: sample, preset: preset, limit: limit,
                                              useSidecar: sidecar, to: output, progress: progress)
            }
        }
        let editor = session.editor
        guard let source = editor.jpegSourceAtPlayhead else { throw MCPCommandError("no_picture", "No picture source at the playhead.") }
        let selection: JPEGSelection
        switch mode {
        case "scenes": selection = source.scenes.map(JPEGSelection.sceneReport) ?? .scenes
        case "nonSilent":
            if let pauses = source.pauses, let threshold = source.effectiveThreshold, let stream = source.audioStream {
                selection = .audibleRanges(pauses: pauses, stream: stream, thresholdDB: threshold, minimumPause: source.minimumPause)
            } else {
                selection = .nonSilent(stream: source.audioStream, thresholdDB: source.manualThreshold, minimumPause: source.minimumPause)
            }
        case "times": selection = .times(times)
        case "still", "playhead":
            guard let frame = source.frame else { throw MCPCommandError("no_picture", "No frame covers the playhead.") }
            if mode == "still" {
                return { progress in
                    try Self.writeStill(source.media, time: frame, to: output, progress: progress)
                }
            }
            selection = .times([frame])
        default: throw MCPCommandError("invalid_arguments", "Switch sampling requires a multicam project.")
        }
        let sidecar = editor.useAnalysisSidecars
        return { progress in
            try Self.writeFrameSet(source.media, selection: selection, sample: sample, preset: preset, limit: limit,
                                   useSidecar: sidecar, to: output, progress: progress)
        }
    }

    nonisolated static func writeFrameSet(_ media: MediaInfo, selection: JPEGSelection, sample: JPEGSample, preset: JPEGPreset,
                                          limit: Int?, useSidecar: Bool, to output: URL, progress: MCPLiveOutputProgress) throws -> [String: Any] {
        let manifest = try JPEGExport.write(media, to: output, selection: selection, sample: sample, preset: preset,
                                            limit: limit, useSidecar: useSidecar, cancelled: outputCancelled) { i, n in
            if n > 0 { progress.update(Double(i) / Double(n)) }
        }
        progress.published(output)
        return ["manifest": output.appendingPathComponent("manifest.json").path, "frames": manifest.frames.count]
    }

    func replaceMCPAudio(_ args: [String: Any], session: ProjectSession, checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        if session.isMulticam {
            guard args["clip"] == nil, args["output"] == nil, args["targetStream"] == nil else {
                throw MCPCommandError("invalid_arguments", "Multicam replacement changes program routing. Choose an existing source and stream, or an external recording.")
            }
            let existing = args["source"] != nil || args["stream"] != nil
            guard existing ? args["source"] != nil && args["stream"] != nil && args["replacement"] == nil && args["replacementStream"] == nil : args["replacement"] != nil else {
                throw MCPCommandError("invalid_arguments", "Choose one soundtrack source: project source and stream, or replacement path and optional replacement stream.")
            }
            let model = session.multicam
            guard model.canReplaceSourceAudio else { throw MCPCommandError("busy", "Finish the current multicam operation.") }
            if let source = args["source"] as? String, let stream = args["stream"] as? Int {
                guard model.replaceProgramAudio(with: .init(source: source, stream: stream)) else {
                    throw MCPCommandError("invalid_target", "Choose an indexed project audio source and stream.")
                }
            } else {
                let url = try outputPath(args, "replacement")
                let sidecar = model.useAnalysisSidecars
                let exclusions = model.sidecarExclusions.union(CutProject.sidecarExclusions(absoluteSources: model.protectedMediaPaths, candidates: [url]))
                let (ordinary, info) = try await prepareOutput {
                    try AnalysisSidecar.$excludedSources.withValue(exclusions) {
                        let engine = CutEngine(cancelled: outputCancelled, useSidecar: sidecar)
                        let ordinary = try engine.inspect(url, keyframes: true)
                        return (ordinary, try engine.multicamClock(ordinary))
                    }
                }
                try checkAccess()
                var source = model.project?.sources.first(where: { $0.file == info.url.path })
                    ?? MulticamSource(id: UUID().uuidString, file: info.url.path)
                source.audioStream = source.audioStream.flatMap { index in
                    info.audio.contains { $0.stream.index == index } ? index : nil
                } ?? info.audio.first?.stream.index
                let draft = MulticamEditorModel.SourceDraft(source: source, media: info, ordinaryMedia: ordinary)
                guard let stream = args["replacementStream"] as? Int ?? draft.source.audioStream,
                      model.replaceProgramAudio(with: .init(source: draft.id, stream: stream), external: draft) else {
                    throw MCPCommandError("invalid_target", "The external soundtrack could not be applied.")
                }
            }
            return ["action": "Replace Program Audio", "revision": model.mcpRevision]
        }
        let editor = session.editor
        guard args["source"] == nil, args["stream"] == nil else {
            throw MCPCommandError("invalid_arguments", "Ordinary replacement takes a clip occurrence and a replacement path.")
        }
        guard editor.canEdit, let id = UUID(uuidString: args["clip"] as? String ?? "") else {
            throw MCPCommandError("invalid_target", "Supply a ready sequence and its clip occurrence ID.")
        }
        let (sourceID, media) = try editor.mcpReplacementSource(id)
        let replacement = try outputPath(args, "replacement"), output = try outputPath(args)
        try editor.validateHistoryDestination(output)
        let target = args["targetStream"] as? Int, stream = args["replacementStream"] as? Int
        let sidecars = editor.useAnalysisSidecars
        let excluded = editor.sidecarExclusions.union(CutProject.sidecarExclusions(
            absoluteSources: editor.mcpOutputProtectedMedia, candidates: [replacement]))
        let plan = try await prepareOutput {
            try AnalysisSidecar.$excludedSources.withValue(excluded) {
                try AudioReplacementEngine(cancelled: outputCancelled, useSidecar: sidecars).resolve(source: media, replacement: replacement,
                        output: output, targetStream: target, replacementStream: stream)
            }
        }
        try checkAccess()
        guard editor.canEdit else { throw MCPCommandError("busy", "Finish the current sequence operation.") }
        let revision = try await editor.mcpApplyReplacement(plan, output: output, sourceID: sourceID, validateCommit: checkAccess)
        return ["action": "Replace Source Audio", "revision": revision, "output": output.path]
    }
}
