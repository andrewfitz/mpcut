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
    if let refusal = cell.refusal, refusal.code != "still_generation_required",
       !(source == .multicam && tracks == .audio && placements == .insertion && refusal.code == "still_requires_generation") {
        throw refusal
    }
    options.placements = placements
    options.requireCameraCopy = args["require_camera_copy"] as? Bool ?? false
    options.tracks = cell.tracks
    options.mode = cell.resolvedMode
    options.codec = try outputEnum(args, "codec", .h264)
    options.audio = try outputEnum(args, "audio", .auto)
    guard source == .multicam || args["audio_output"] == nil else {
        throw MCPCommandError("invalid_arguments", "Audio delivery applies to multicam projects.")
    }
    let quality = try outputEnum(args, "quality", options.codec == .prores ? ReencodeQuality.prores422 : .balanced)
    options.standardQuality = quality
    options.proResQuality = quality
    options.copyContainer = container
    options.encodeContainer = container
    options.proResContainer = container
    options.audioTrackOrdinal = args["audio_track_ordinal"] as? Int
    if let ordinal = options.audioTrackOrdinal, options.tracks != .audio || ordinal < 0 {
        throw MCPCommandError("invalid_arguments", "Choose audio tracks before specifying a zero-based track ordinal.")
    }
    if source == .multicam {
        guard options.mode == .encode && options.tracks != .audio || args["codec"] == nil && args["quality"] == nil else {
            throw MCPCommandError("invalid_arguments", "Video codec and quality apply to picture encode mode.")
        }
        if options.tracks == .audio { options.audioMode = options.mode }
        return options
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
        let owner = arguments["project_handle"] as? String ?? ""
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
        case "export_editor_job_status_read", "export_editor_job_cancel":
            try checkAccess()
            return try mcpOutputJobs.status(owner: owner, id: arguments["job_id"] as? String ?? "", cancel: tool == "export_editor_job_cancel")
        case "export_queue_list", "export_queue_range_add", "export_queue_entry_remove", "export_queue_entry_rename", "export_queue_entry_revise":
            if tool == "export_queue_list" { try checkAccess() } else { try validateEdit() }
            return try updateMCPQueue(tool, session: session, arguments: arguments)
        case "multicam_program_audio_set" where arguments["mode"] as? String == "replace":
            guard session.isMulticam else { throw MCPCommandError("invalid_target", "Choose a multicam project.") }
            try validateEdit()
            return try await replaceMCPAudio(arguments, session: session, checkAccess: validateEdit)
        case "multicam_track_audio_edit", "multicam_track_audio_sync_suggest":
            guard session.isMulticam else { throw MCPCommandError("invalid_target", "Choose a multicam project.") }
            try validateEdit()
            return try await editMCPTrackAudio(arguments, session: session, suggest: tool == "multicam_track_audio_sync_suggest",
                                               checkAccess: validateEdit)
        case "sequence_source_soundtrack_replace":
            guard !session.isMulticam else { throw MCPCommandError("invalid_target", "Choose a sequence project.") }
            try validateEdit()
            return try await replaceMCPAudio(arguments, session: session, checkAccess: validateEdit)
        case "export_editor_project_plan", "export_editor_project_render", "export_queue_plan", "export_queue_render", "review_editor_frames_export", "project_editor_convert", "project_editor_resolve_export", "project_editor_resolve_import", "export_editor_boundary_apply":
            break
        default: return nil
        }
        try validateEdit()
        let output = try outputPath(arguments)
        let multi = session.multicam
        let editor = session.editor
        let directory = tool == "review_editor_frames_export" && arguments["selection"] as? String != "still"
            || tool == "project_editor_convert" && ["fcpbundle", "fcpxmld"].contains(output.pathExtension.lowercased())
        let sidecars = session.isMulticam ? multi.useAnalysisSidecars : editor.useAnalysisSidecars
        let excluded = session.isMulticam ? multi.sidecarExclusions : editor.sidecarExclusions
        if session.isMulticam {
            guard !multi.isBusy, multi.project != nil || ["export_queue_plan", "export_queue_render"].contains(tool) else { throw MCPCommandError("busy", "Wait for the multicam project to become ready.") }
            try multi.validateHistoryDestination(output, includesContents: directory)
        } else {
            guard ["export_queue_plan", "export_queue_render"].contains(tool) ? !editor.isBusy : editor.canEdit else {
                throw MCPCommandError("busy", "Wait for a committed sequence.")
            }
            try editor.validateHistoryDestination(output, includesContents: directory)
        }
        let work: MCPLiveOutputJobs.Work
        switch tool {
        case "export_editor_boundary_apply":
            if let adjustment = arguments["still_adjustment"] {
                return try await mcpApplyStillExportReview(adjustment, args: arguments, session: session, output: output, validateEdit: validateEdit)
            }
            if let project = session.mcpStillProject, project.mcpHasStills {
                throw MCPCommandError("invalid_target", "Supply a verified still_adjustment from the camera-copy preflight.")
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
        case "export_queue_plan", "export_queue_render": work = try mcpQueueExport(session: session, output: output, args: arguments, dryRun: tool == "export_queue_plan")
        case "review_editor_frames_export": work = try mcpFrames(session: session, output: output, args: arguments)
        case "export_editor_project_plan", "export_editor_project_render": work = try mcpRender(session: session, output: output, args: arguments, dryRun: tool == "export_editor_project_plan")
        default:
            work = try mcpInterchange(session: session, output: output, args: arguments, resolve: ["project_editor_resolve_export", "project_editor_resolve_import"].contains(tool), open: tool == "project_editor_resolve_import")
        }
        try checkAccess()
        let conversion = ["project_editor_convert", "project_editor_resolve_export", "project_editor_resolve_import"].contains(tool) ? EditCancellation() : nil
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

    private func updateMCPQueue(_ tool: String, session: ProjectSession, arguments: [String: Any]) throws -> [String: Any] {
        let editor = session.editor, multi = session.multicam
        if tool == "export_queue_range_add" {
            guard session.isMulticam ? multi.canEnqueueMarkedRange : editor.canAddMarkedRange else {
                throw MCPCommandError("no_selection", "Mark a range in the target editor before adding it to the queue.")
            }
            let count = session.isMulticam ? multi.queuedRanges.count : editor.queuedRanges.count
            if session.isMulticam { multi.enqueueMarkedRange() } else { editor.addMarkedRange() }
            guard (session.isMulticam ? multi.queuedRanges.count : editor.queuedRanges.count) > count else {
                throw MCPCommandError("queue_failed", multi.notice?.message ?? editor.alert?.message ?? "The marked range could not be queued.")
            }
        }
        if ["export_queue_entry_remove", "export_queue_entry_rename", "export_queue_entry_revise"].contains(tool) {
            guard let id = arguments["id"] as? String, let uuid = UUID(uuidString: id),
                  session.isMulticam ? multi.queuedRanges.contains(where: { $0.id == uuid }) : editor.queuedRanges.contains(where: { $0.id == uuid }) else {
                throw MCPCommandError("invalid_target", "Choose an entry from export_queue_list.")
            }
            guard !(session.isMulticam ? multi.isExporting : editor.isExporting) else { throw MCPCommandError("busy", "Wait for the active GUI export.") }
            do {
                switch tool {
                case "export_queue_entry_rename":
                    let name = arguments["name"] as? String ?? ""
                    if session.isMulticam { try multi.renameQueuedRange(uuid, to: name) }
                    else { try editor.renameQueuedRange(uuid, to: name) }
                case "export_queue_entry_revise":
                    guard let mode = arguments["mode"] as? String, ["replace", "extend"].contains(mode) else {
                        throw MCPCommandError("invalid_argument", "Choose replace or extend.")
                    }
                    if session.isMulticam { try multi.reviseQueuedRange(uuid, extending: mode == "extend") }
                    else { try editor.reviseQueuedRange(uuid, extending: mode == "extend") }
                default:
                    if session.isMulticam { multi.removeQueuedRange(uuid) }
                    else { editor.removeQueuedRange(uuid) }
                }
            } catch let issue as QueueEdit {
                throw MCPCommandError(issue.code, issue.localizedDescription)
            }
        }
        let entries: [[String: Any]]
        if session.isMulticam {
            entries = try multi.queuedRanges.map {
                ["id": $0.id.uuidString, "name": $0.name, "coordinate_space": $0.usesAssembly ? "assembly" : "group",
                 "from": $0.range.from.description, "to": $0.range.to.description, "items": try $0.snapshotItems().map(\.json)]
            }
        } else {
            entries = try editor.queuedRanges.map {
                var entry: [String: Any] = ["id": $0.id.uuidString, "from": $0.start.description, "to": $0.end.description,
                                            "items": try $0.snapshotItems().map(\.json)]
                entry["name"] = $0.name
                return entry
            }
        }
        return ["ranges": entries, "coordinate_space": session.isMulticam ? "group" : "sequence"]
    }

    private func mcpRender(session: ProjectSession, output: URL, args: [String: Any], dryRun: Bool) throws -> MCPLiveOutputJobs.Work {
        let scope = args["scope"] as? String ?? "timeline"
        let project = session.isMulticam ? session.multicam.project.map(CutProject.multicam) : session.editor.stillProject
        if let project, project.participants.render != nil {
            let document = session.isMulticam ? session.multicam.projectURL : session.editor.projectURL
            let mode = try outputEnum(args, "mode", ExportMode.encode)
            let tracks = try outputEnum(args, "tracks", ExportTracks.all)
            let codec = try outputEnum(args, "codec", ReencodeCodec.h264)
            let quality = try outputEnum(args, "quality", ReencodeQuality.balanced)
            let audio = try outputEnum(args, "audio", ReencodeAudio.auto)
            let audioOutput = try outputEnum(args, "audio_output", MulticamAudioOutput.separateTracks)
            let settings = ReencodeSettings(codec: codec, quality: quality, audio: audio)
            let requireCopy = args["require_camera_copy"] as? Bool ?? false
            let useReviewedCuts = args["use_reviewed_cuts"] as? Bool ?? false
            let selectsAudio = args["audio_track"] != nil || args["audio_track_ordinal"] != nil
            return { progress in
                let export: ParticipantProjectExport
                do {
                    guard scope == "timeline" else { throw ParticipantProjectExport.unsupported("A range export") }
                    guard !requireCopy else {
                        throw CutError(code: "camera_copy_required", message: "The participant export would encode picture.")
                    }
                    guard !useReviewedCuts, !selectsAudio else {
                        throw ParticipantProjectExport.unsupported("Applying reviewed copy cuts or selecting a source audio track")
                    }
                    export = try ParticipantProjectExport(project, relativeTo: document, output: output, mode: mode,
                                                         tracks: tracks, settings: settings, audioOutput: audioOutput,
                                                         cancelled: outputCancelled)
                } catch let issue as CutError where dryRun {
                    return try Self.outputRefusal(issue)
                }
                if !dryRun {
                    try export.write(to: output, cancelled: outputCancelled) { fraction in
                        progress.update(fraction)
                        return !Task.isCancelled
                    }
                    progress.published(output)
                }
                return ["eligible": true, "dry_run": dryRun, "plan": try Self.outputJSON(export.report)]
            }
        }
        if let snapshot = try mcpRenderStillSnapshot(session: session, scope: scope) {
            return try mcpRenderStills(session: session, snapshot: snapshot, output: output, args: args, dryRun: dryRun)
        }
        let source: ExportSourceKind = session.isMulticam ? .multicam : (session.editor.isAudioOnly ? .audio : .movie)
        let placements: ExportPlacementScope
        if session.isMulticam, args["mode"] as? String == ExportMode.encode.rawValue,
           case .multicam(let project)? = session.multicam.stillExportDocument(wholeGroup: scope == "group",
                selection: scope == "selection" ? session.multicam.selectedExportRanges : nil),
           project.angles.contains(where: { $0.coverage != nil }),
           (try? project.plan().intervals.contains(where: { $0.pictureSourceID == nil })) == true {
            placements = .replacement
        } else { placements = .none }
        let options = try exportOptions(args, container: output.pathExtension.lowercased(), source: source,
                                        defaultMode: preferences.defaultExportMode, placements: placements)
        guard !options.requireCameraCopy || options.tracks == .audio || options.effectiveMode == .copy else {
            throw MCPCommandError("invalid_arguments", "Select Lossless Copy to preserve camera samples.")
        }
        let useReviewedCuts = args["use_reviewed_cuts"] as? Bool ?? false
        guard !useReviewedCuts || (!session.isMulticam && options.mode == .copy && options.tracks == .all) else {
            throw MCPCommandError("invalid_arguments", "Reviewed export cuts apply to ordinary full-track copy exports.")
        }
        if session.isMulticam {
            let model = session.multicam
            let audioOutput = try outputEnum(args, "audio_output", MulticamAudioOutput.separateTracks)
            let audioAction: ReencodeAudio? = args["audio"] == nil ? nil : options.audio
            let selection = scope == "selection" ? model.selectedExportRanges : nil
            guard selection?.isEmpty != true || model.assemblySelection != nil else {
                throw MCPCommandError("no_selection", "Select a multicam range first.")
            }
            if let message = model.exportSourceIssue(tracks: options.tracks, wholeGroup: scope == "group", mode: options.mode,
                                                     settings: options.settings, selection: selection, audioAction: audioAction) {
                throw MCPCommandError("unavailable", message)
            }
            guard options.audioTrackOrdinal == nil else { throw MCPCommandError("invalid_arguments", "Use project audio routing for multicam exports.") }
            guard case .multicam(let snapshot)? = model.stillExportDocument(wholeGroup: scope == "group", selection: selection) else {
                throw MCPCommandError("invalid_range", "Select a valid range to export.")
            }
            let indexed = model.media.filter { $0.value.hasFullEditIndex }
            let location = model.projectURL
            return { progress in
                let engine = MulticamEngine(cancelled: outputCancelled)
                try CutEngine().checkDestination(output)
                let plan: MulticamExportPlan
                do {
                    plan = try engine.resolution(snapshot, relativeTo: location, output: output, mode: options.effectiveMode,
                                                 tracks: options.tracks, settings: options.settings, indexedSources: indexed,
                                                 audioOutput: audioOutput, audioAction: audioAction).get()
                } catch let issue as CutError where dryRun {
                    try Task.checkCancellation()
                    return try Self.outputRefusal(issue)
                }
                if !dryRun {
                    try engine.write(plan, to: output) { progress.update($0) }
                    progress.published(output)
                }
                return ["eligible": true, "dry_run": dryRun, "plan": try Self.outputJSON(plan),
                        "cut_map": try Self.outputJSON(ExportCutMap(multicam: plan.mapping))]
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
                    result["proposed_ranges"] = try Self.outputJSON(review.revised.map { clip in
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
                return ["eligible": true, "dry_run": dryRun, "plan": try Self.outputJSON(plan.report),
                        "cut_map": try Self.outputJSON(plan.report.cutMap)]
            case .ready(let plan):
                let map = try ExportCutMap(edit: plan.edit, clips: input.clips, ids: input.occurrenceIDs)
                if !dryRun {
                    try plan.writeOutput(to: output, cancelled: outputCancelled) { progress.update($0) }
                    progress.published(output)
                }
                var result: [String: Any] = ["eligible": true, "dry_run": dryRun, "summary": plan.summary,
                                            "cut_map": try Self.outputJSON(map)]
                result["applied_to_export_only"] = reviewDetail
                switch plan {
                case .packets(let edit, _, _): result["plan"] = try Self.outputJSON(edit)
                case .conversion(let conversion): result["plan"] = try Self.outputJSON(conversion)
                case .audio(let audio):
                    result["plan"] = try Self.outputJSON(audio.edit)
                    result["audio_actions"] = try Self.outputJSON(audio.actions)
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
        guard args["use_reviewed_cuts"] as? Bool != true else {
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
        let requireCameraCopy = args["require_camera_copy"] as? Bool ?? false
        let audioOutput = try outputEnum(args, "audio_output", MulticamAudioOutput.separateTracks)
        let audioAction = session.isMulticam && args["audio"] != nil ? audio : nil
        guard session.isMulticam || args["audio_output"] == nil else {
            throw MCPCommandError("invalid_arguments", "Audio delivery applies to multicam projects.")
        }
        if case .multicam(let project) = snapshot,
           let issue = session.multicam.refreshExportIssue(in: try project.plan(), tracks: tracks, mode: mode, settings: settings,
                                                           audioAction: audioAction) {
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
        if let ordinal = args["audio_track_ordinal"] as? Int {
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
                                           mode: mode, requireCameraCopy: requireCameraCopy, output: output, settings: settings,
                                           audioOutput: audioOutput, audioAction: audioAction)
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
            return ["eligible": true, "dry_run": dryRun, "plan": try Self.outputJSON(plan.report),
                    "cut_map": try Self.outputJSON(plan.report.cutMap)]
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
                "history_retained": preferences.historyLimit > 0]
    }

    nonisolated private static func outputRefusal(_ issue: CutError) throws -> [String: Any] {
        var detail = issue
        detail.alternatives = nil
        var result: [String: Any] = ["eligible": false, "dry_run": true, "reason": outputDetail(issue.message),
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
        let data = try MCPSchemas.encodeResult(value)
        guard data.count < 1_500_000 else { return ["truncated": true, "encoded_bytes": data.count] }
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
    func mcpInterchange(session: ProjectSession, output: URL, args: [String: Any], resolve: Bool, open: Bool) throws -> MCPLiveOutputJobs.Work {
        let snapshot: CutProject
        let sequence: [ClipRequest]
        let ordinary: [MediaInfo]
        let indexed: [String: MediaInfo]
        if session.isMulticam, let project = session.multicam.project {
            snapshot = .multicam(project)
            indexed = session.multicam.media
            sequence = []; ordinary = []
        } else {
            snapshot = session.editor.transcriptProject
            if snapshot.mcpHasStills {
                sequence = []; ordinary = []; indexed = [:]
            } else {
                let input = try session.editor.mcpExportInput(selection: false)
                sequence = input.clips; ordinary = Array(input.media.values); indexed = [:]
            }
        }
        let location = (session.isMulticam ? session.multicam.projectURL : session.editor.projectURL) ?? output
        let allowLoss = args["allow_loss"] as? Bool ?? false
        let flatten = args["flatten_multicam"] as? Bool ?? false
        return { progress in
            if resolve {
                try ResolveExport.validateTimelineHandoff(snapshot)
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
                return ["opened_in_resolve": open]
            }
            let warnings = try ProjectConverter.write(snapshot, relativeTo: location, to: output, allowLoss: allowLoss,
                                                      flattenMulticam: flatten, auxiliaryOutput: progress.published, cancelled: outputCancelled)
            progress.published(output)
            return ["warnings": warnings]
        }
    }

    func mcpQueueExport(session: ProjectSession, output: URL, args: [String: Any], dryRun: Bool) throws -> MCPLiveOutputJobs.Work {
        let container = (args["container"] as? String ?? "mov").lowercased()
        let multi = session.isMulticam
        let protected = multi ? session.multicam.protectedMediaPaths : session.editor.mcpOutputProtectedMedia
        let ranges = session.editor.queuedRanges
        let groups = session.multicam.queuedRanges
        if let issue = multi ? session.multicam.queuedMediaRefreshIssue() : session.editor.queuedMediaRefreshIssue() {
            throw MCPCommandError(issue.code, issue.message)
        }
        guard !(multi ? groups.isEmpty : ranges.isEmpty) else { throw MCPCommandError("empty_queue", "Queue at least one range first.") }
        let hasVideo = ranges.contains { $0.stillProject != nil || $0.media.values.contains(where: \.hasVideo) }
        let source: ExportSourceKind = multi ? .multicam : (hasVideo ? .movie : .audio)
        var placements = ranges.map(\.placements).max(by: { $0.rawValue < $1.rawValue }) ?? .none
        for entry in groups {
            let project = entry.snapshot
            let scope = try CutProject.multicam(project).exportPlacementScope()
            if scope.rawValue > placements.rawValue { placements = scope }
            if placements == .none, args["mode"] as? String == ExportMode.encode.rawValue,
               project.angles.contains(where: { $0.coverage != nil }),
               (try? project.plan().intervals.contains(where: { $0.pictureSourceID == nil })) == true {
                placements = .replacement
            }
            if placements == .insertion { break }
        }
        var configured = try exportOptions(args, container: container, source: source,
                                           defaultMode: preferences.defaultExportMode, placements: placements)
        configured.organization = .init(subfolder: args["subfolder"] as? String ?? "", baseName: args["base_name"] as? String ?? "")
        let options = configured
        let audioOutput = try outputEnum(args, "audio_output", MulticamAudioOutput.separateTracks)
        let audioAction: ReencodeAudio? = args["audio"] == nil ? nil : options.audio
        let mode = try (args["mode"] as? String).map { _ in try outputEnum(args, "mode", ExportMode.copy) }
        let sidecars = multi ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let defaultOrdinaryMode: ExportMode = source != .audio && options.tracks == .all ? preferences.defaultExportMode : .copy
        let hasStills = placements != .none
        guard !multi || options.audioTrackOrdinal == nil else { throw MCPCommandError("invalid_arguments", "Multicam uses routed program audio.") }

        return { progress in
            let outputs: [URL]
            let write: (Int, @escaping @Sendable (Double) -> Void) throws -> Void
            var plans: [[String: Any]] = []
            var multicamPlans: [[String: Any]] = []
            do {
                try options.organization.validateSubfolder(in: output, protectedMedia: protected)
                if multi {
                    let engine = MulticamEngine(cancelled: outputCancelled)
                    let batch = try MulticamBulkExport(ranges: groups, directory: output, container: container,
                                                       mode: mode ?? (!hasStills ? options.effectiveMode : nil),
                                                       tracks: options.tracks, settings: options.settings, organization: options.organization, engine: engine,
                                                       requireCameraCopy: options.requireCameraCopy, cancelled: outputCancelled,
                                                       audioOutput: audioOutput, audioAction: audioAction)
                    outputs = batch.items.map(\.output)
                    plans = try batch.items.compactMap { item in
                        guard let report = item.stillReport else { return nil }
                        return ["destination": item.output.path, "plan": try Self.outputJSON(report)]
                    }
                    multicamPlans = try batch.items.compactMap { item in
                        guard case .multicam(let plan) = item.payload else { return nil }
                        return ["destination": item.output.path, "plan": try Self.outputJSON(plan)]
                    }
                    write = { try batch.write(batch.items[$0], progress: $1) }
                } else {
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
            } catch let issue as CutError where dryRun && (hasStills || multi) {
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
            var result: [String: Any] = ["dry_run": dryRun, "destinations": outputs.map(\.path)]
            if !plans.isEmpty { result["still_plans"] = plans }
            if !multicamPlans.isEmpty { result["multicam_plans"] = multicamPlans }
            return result
        }
    }

    func mcpFrames(session: ProjectSession, output: URL, args: [String: Any]) throws -> MCPLiveOutputJobs.Work {
        let project = session.isMulticam ? session.multicam.project.map(CutProject.multicam) : session.editor.stillProject
        guard project?.participants.render == nil else { throw ParticipantProjectExport.unsupported("Project frame export") }
        let mode = args["selection"] as? String ?? "playhead"
        let times = try (args["times"] as? [String] ?? []).map { try RationalTime(parsing: $0) }
        guard (mode == "times") == !times.isEmpty, times.count <= 4096 else {
            throw MCPCommandError("invalid_arguments", "Supply up to 4096 times with explicit timestamp selection.")
        }
        if mode == "still", !["jpg", "jpeg"].contains(output.pathExtension.lowercased()) {
            throw MCPCommandError("invalid_arguments", "Choose a .jpg or .jpeg destination for a still frame.")
        }
        let sample = try outputEnum(args, "sample", JPEGSample.midpoint)
        let preset = try outputEnum(args, "preset", mode == "still" ? .full : preferences.jpegPreset)
        let limit = args["limit"] as? Int
        if let limit, limit < 1 || !["scenes", "non_silent"].contains(mode) {
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
                for source in project.pictureSources {
                    if let issue = model.refreshPictureIssue(sourceID: source.id),
                       targets.contains(where: { source.coverage?.contains($0) ?? true }) {
                        throw MCPCommandError("source_needs_review", issue)
                    }
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
                    try Self.writeStill(source, time: active.sourceTime, exclusiveEnd: active.exclusiveEnd,
                                        preset: preset, to: output, progress: progress)
                }
            }
            let ordinary = model.ordinaryAnalysisMedia(active.angle)
            let snapshot = ordinary.map(model.analysis.snapshot(for:))
            let stream = project.pictureSources.first(where: { $0.id == active.angle })?.audioStream ?? source.audio.first?.stream.index
            let threshold = stream.flatMap { model.analysis.threshold(for: .init(source: active.angle, stream: $0)) }
            let minimumPause = preferences.minimumPause
            let maxBlip = preferences.maxBlip
            return { progress in
                let media = try ordinary ?? CutEngine(cancelled: outputCancelled, useSidecar: sidecar)
                    .inspect(source.url, keyframes: true, expectedIdentity: source.identity)
                let selection: JPEGSelection
                if mode == "scenes" {
                    selection = snapshot?.scenes.map(JPEGSelection.sceneReport) ?? .scenes
                } else if let result = snapshot?.silence.first(where: {
                    $0.stream == stream && $0.minimum == minimumPause && $0.requestedThresholdDB == threshold
                }),
                          try media.extendingToAudioEnd(stream: result.stream).duration == media.duration {
                    selection = .audibleRanges(pauses: result.pauses(maxBlip: maxBlip), stream: result.stream,
                                               thresholdDB: result.thresholdDB, minimumPause: minimumPause)
                } else {
                    selection = .nonSilent(stream: stream, thresholdDB: threshold, minimumPause: minimumPause, maxBlip: maxBlip)
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
        case "non_silent":
            if let pauses = source.pauses, let threshold = source.effectiveThreshold, let stream = source.audioStream {
                selection = .audibleRanges(pauses: pauses, stream: stream, thresholdDB: threshold, minimumPause: source.minimumPause)
            } else {
                selection = .nonSilent(stream: source.audioStream, thresholdDB: source.manualThreshold, minimumPause: source.minimumPause,
                                       maxBlip: source.maxBlip)
            }
        case "times": selection = .times(times)
        case "still", "playhead":
            guard let frame = source.frame else { throw MCPCommandError("no_picture", "No frame covers the playhead.") }
            if mode == "still" {
                return { progress in
                    try Self.writeStill(source.media, time: frame, preset: preset, to: output, progress: progress)
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

    private func editMCPTrackAudio(_ args: [String: Any], session: ProjectSession, suggest: Bool,
                                   checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        let model = session.multicam
        guard !model.isBusy, model.notice == nil, let project = model.project else {
            throw MCPCommandError("busy", "Wait for the multicam project to become ready.")
        }
        let revision = model.mcpRevision
        func commit(_ action: String, change: (inout MulticamProject) throws -> Void) throws -> [String: Any] {
            try checkAccess()
            guard model.edit(action, change) else {
                let message = model.notice?.message ?? "The track replacement could not be applied."
                model.notice = nil
                throw MCPCommandError("invalid_target", message)
            }
            let changed = revision != model.mcpRevision
            return ["action": action, "revision": model.mcpRevision, "changed": changed,
                    "history_retained": changed && model.preferences.historyLimit > 0]
        }
        let id = args["id"] as? String ?? UUID().uuidString
        if args["action"] as? String == "remove" {
            guard let index = project.audioReplacements.firstIndex(where: { $0.id == id }) else {
                throw MCPCommandError("invalid_target", "Unknown replacement binding.")
            }
            return try commit("Remove Track Audio Replacement") { $0.audioReplacements.remove(at: index) }
        }
        func selection(_ key: String) throws -> MulticamAudioSelection {
            guard let object = args[key] as? [String: Any], let source = object["source_id"] as? String,
                  let raw = object["audio_stream_index"], let stream = mcpInteger(raw) else {
                throw MCPCommandError("invalid_arguments", "Supply the source and absolute stream index for \(key).")
            }
            return .init(source: source, stream: stream)
        }
        let program = suggest && args["program"] as? Bool == true
        let rawOriginal = args["original"] as? [String: Any]
        let original: MulticamAudioSelection? = try program && rawOriginal?["audio_stream_index"] == nil
            ? nil : selection("original")
        let referenceID = original?.source ?? rawOriginal?["source_id"] as? String
        guard let referenceID, let reference = project.pictureSources.first(where: { $0.id == referenceID }),
              let scratch = model.media[referenceID],
              original.map({ selection in scratch.audio.contains { $0.stream.index == selection.stream } }) ?? program else {
            throw MCPCommandError("invalid_target", "Choose an indexed camera recording and a valid scratch stream when needed.")
        }
        let replacement: MulticamAudioSelection
        let source: MulticamSource
        let indexed: MediaInfo
        let imported: MediaInfo?
        let sidecar = model.useAnalysisSidecars
        if args["replacement"] != nil {
            replacement = try selection("replacement")
            guard let existing = project.audioSources.first(where: { $0.id == replacement.source }),
                  let info = model.media[existing.id] else {
                throw MCPCommandError("invalid_target", "Choose an indexed external audio source.")
            }
            source = existing
            indexed = info
            imported = nil
        } else {
            let path = try outputPath(args, "path")
            let sourceID = args["replacement_source_id"] as? String ?? UUID().uuidString
            guard !project.sources.contains(where: { $0.id == sourceID }),
                  let raw = args["replacement_stream_index"], let stream = mcpInteger(raw) else {
                throw MCPCommandError("invalid_target", "Choose a new source ID and an absolute replacement stream index.")
            }
            replacement = .init(source: sourceID, stream: stream)
            let exclusions = model.sidecarExclusions.union(CutProject.sidecarExclusions(
                absoluteSources: model.protectedMediaPaths, candidates: [path]))
            let pair = try await prepareOutput {
                try AnalysisSidecar.$excludedSources.withValue(exclusions) {
                    let engine = CutEngine(cancelled: outputCancelled, useSidecar: sidecar)
                    let ordinary = try engine.inspect(path, keyframes: true)
                    return (ordinary, try engine.multicamClock(ordinary))
                }
            }
            imported = pair.0
            indexed = pair.1
            source = .init(id: sourceID, file: indexed.url.path, audioStream: stream)
        }
        guard let track = indexed.audio.first(where: { $0.stream.index == replacement.stream }) else {
            throw MCPCommandError("invalid_target", "Choose an available replacement audio stream.")
        }
        if suggest {
            let seed = try (args["seed"] as? String).map { try RationalTime(parsing: $0) }
            let ranges = try MulticamSync.usedReferenceRanges(project: project, referenceSourceID: referenceID,
                                                             referenceStream: original?.stream, program: program)
            let request = MulticamSync.ReplacementRequest(referenceSourceID: referenceID, referenceStream: original?.stream,
                                                          source: source,
                                                          stream: replacement.stream, seed: seed,
                                                          referenceRanges: ranges)
            let location = model.projectURL
            let waveform = args["metadata_only"] as? Bool != true && original != nil
            let scratchWaveform = original.flatMap {
                model.analysis.completedWaveform(sourceID: $0.source, stream: $0.stream)
            }
            let report = try await prepareOutput {
                try MulticamSync.analyzeReplacement(project, request: request, relativeTo: location,
                        indexed: [reference.id: scratch, source.id: indexed], waveform: waveform, useSidecar: sidecar,
                        cachedReferenceWaveform: scratchWaveform)
            }
            try checkAccess()
            var result: [String: Any] = ["revision": revision, "report": try Self.outputJSON(report)]
            if let suggestion = report.suggestions.first {
                if let offset = suggestion.metadataOffset {
                    let relative = try offset.subtracting(reference.offset)
                    result["metadata_relative_offset"] = relative.description
                    result["metadata_coverage"] = try Self.outputJSON(
                        MulticamSync.replacementCoverage(in: ranges, track: track, relativeOffset: relative))
                }
                if let offset = suggestion.waveformOffset {
                    let relative = try offset.subtracting(reference.offset)
                    result["waveform_relative_offset"] = relative.description
                    result["waveform_coverage"] = try Self.outputJSON(
                        MulticamSync.replacementCoverage(in: ranges, track: track, relativeOffset: relative))
                }
            }
            return result
        }
        guard let original, let offset = args["relative_offset"] as? String, let policy = args["uncovered"] as? String,
              let uncovered = MulticamAudioReplacement.Uncovered(rawValue: policy) else {
            throw MCPCommandError("invalid_arguments", "Supply a confirmed relative offset and an uncovered-audio policy.")
        }
        let binding = try MulticamAudioReplacement(id: id, original: original, replacement: replacement,
                                                  relativeOffset: RationalTime(parsing: offset), uncovered: uncovered)
        try checkAccess()
        try AnalysisSidecar(media: scratch).checkSource()
        try AnalysisSidecar(media: indexed).checkSource()
        if let imported { model.cacheIndexedSource(indexed, ordinary: imported) }
        return try commit("Replace Track Audio") { next in
            if imported != nil { next.audioSources.append(source) }
            if let i = next.audioReplacements.firstIndex(where: { $0.id == id }) {
                next.audioReplacements[i] = binding
            } else {
                next.audioReplacements.append(binding)
            }
        }
    }

    func replaceMCPAudio(_ args: [String: Any], session: ProjectSession, checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        if session.isMulticam {
            guard args["clip_id"] == nil, args["output"] == nil, args["target_audio_stream_index"] == nil else {
                throw MCPCommandError("invalid_arguments", "Multicam replacement changes program routing. Choose an existing source and stream, or an external recording.")
            }
            let existing = args["source_id"] != nil || args["audio_stream_index"] != nil
            guard existing ? args["source_id"] != nil && args["audio_stream_index"] != nil && args["replacement"] == nil && args["replacement_audio_stream_index"] == nil : args["replacement"] != nil else {
                throw MCPCommandError("invalid_arguments", "Choose one soundtrack source: project source and stream, or replacement path and optional replacement stream.")
            }
            let model = session.multicam
            guard model.canReplaceSourceAudio else { throw MCPCommandError("busy", "Finish the current multicam operation.") }
            if let source = args["source_id"] as? String, let stream = args["audio_stream_index"] as? Int {
                guard model.replaceProgramAudio(with: .init(source: source, stream: stream)) else {
                    throw MCPCommandError("invalid_target", "Choose an indexed project audio source and stream.")
                }
            } else {
                let url = try outputPath(args, "replacement")
                let relativeOffset = try (args["relative_offset"] as? String).map { try RationalTime(parsing: $0) }
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
                var source = (relativeOffset == nil ? model.project?.sources.first(where: { $0.file == info.url.path }) : nil)
                    ?? MulticamSource(id: UUID().uuidString, file: info.url.path)
                source.audioStream = source.audioStream.flatMap { index in
                    info.audio.contains { $0.stream.index == index } ? index : nil
                } ?? info.audio.first?.stream.index
                let draft = MulticamEditorModel.SourceDraft(source: source, media: info, ordinaryMedia: ordinary)
                guard let stream = args["replacement_audio_stream_index"] as? Int ?? draft.source.audioStream,
                      let track = draft.media.audio.first(where: { $0.stream.index == stream }) else {
                    throw MCPCommandError("invalid_target", "Choose an available program replacement audio stream.")
                }
                let confirmedOffset: RationalTime?
                if let relativeOffset {
                    guard let project = model.project, let reference = args["reference_source_id"] as? String else {
                        throw MCPCommandError("invalid_arguments", "Choose a reference camera recording for the confirmed offset.")
                    }
                    confirmedOffset = try MulticamSync.confirmedProgramOffset(project: project, referenceSourceID: reference,
                                                                              track: track, relativeOffset: relativeOffset)
                } else {
                    confirmedOffset = nil
                }
                guard model.replaceProgramAudio(with: .init(source: draft.id, stream: stream), external: draft,
                                                 confirmedOffset: confirmedOffset) else {
                    throw MCPCommandError("invalid_target", "The external soundtrack could not be applied.")
                }
            }
            return ["action": "Replace Program Audio", "revision": model.mcpRevision]
        }
        let editor = session.editor
        guard args["source_id"] == nil, args["audio_stream_index"] == nil else {
            throw MCPCommandError("invalid_arguments", "Ordinary replacement takes a clip occurrence and a replacement path.")
        }
        guard editor.canEdit, let id = UUID(uuidString: args["clip_id"] as? String ?? "") else {
            throw MCPCommandError("invalid_target", "Supply a ready sequence and its clip occurrence ID.")
        }
        let (sourceID, media) = try editor.mcpReplacementSource(id)
        let replacement = try outputPath(args, "replacement"), output = try outputPath(args)
        try editor.validateHistoryDestination(output)
        let target = args["target_audio_stream_index"] as? Int, stream = args["replacement_audio_stream_index"] as? Int
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
