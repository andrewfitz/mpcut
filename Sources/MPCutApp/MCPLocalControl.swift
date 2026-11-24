import Combine
import CryptoKit
import Foundation
import MPCutCore

extension ProjectSession {
    var mcpHandle: String {
        if let handle = feedAngleProjectHandle { return handle }
        let generation = isMulticam ? multicam.mcpGeneration : editor.mcpGeneration
        return id.uuidString + "/" + mcpModeGeneration.uuidString + "/" + generation.uuidString
    }
    var mcpRevision: Int { isMulticam ? multicam.mcpRevision : editor.mcpRevision }
}

@MainActor
final class MCPLocalControl {
    private weak var sessions: ProjectSessions?
    private let socket: MCPSocket
    private var observer: AnyCancellable?
    private var generation = UUID()
    private(set) var running = false

    // Keep at most 256 operation results, for ten minutes after completion.
    @MainActor private final class Operation {
        let digest: Data
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<[String: Any], Error>] = [:]
        var outcome: Result<[String: Any], Error>?
        var completedAt: TimeInterval?

        init(digest: Data) { self.digest = digest }

        func complete(_ outcome: Result<[String: Any], Error>) {
            self.outcome = outcome
            completedAt = ProcessInfo.processInfo.systemUptime
            task = nil
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume(with: outcome) }
        }
    }
    private var operations: [String: Operation] = [:]

    init(sessions: ProjectSessions, socket: MCPSocket = MCPSocket()) {
        self.sessions = sessions
        self.socket = socket
    }

    func observeSetting() {
        guard let preferences = sessions?.preferences, observer == nil else { return }
        observer = preferences.observeChanges { [weak self] change in
            if change == .localMCPEnabled { self?.applySetting() }
        }
        applySetting()
    }

    private func applySetting() {
        guard let preferences = sessions?.preferences, preferences.localMCPEnabled else { stop(); return }
        guard !running else { return }
        do {
            let token = generation
            try socket.start { [weak self] data in
                guard let self else { return Self.errorData(MCPFailure("control_disabled", "Local control has stopped.")) }
                return await self.receive(data, generation: token)
            }
            running = true
            preferences.localMCPStatus = "Listening"
        } catch {
            preferences.localMCPStatus = error.localizedDescription
        }
    }

    func stop() {
        running = false
        generation = UUID()
        socket.stop()
        for entry in operations.values where entry.outcome == nil {
            entry.task?.cancel()
            entry.complete(.failure(MCPFailure("control_disabled", "Local control has stopped.")))
        }
        operations.removeAll()
        sessions?.mcpFileJobs.disable()
        sessions?.mcpOutputJobs.disable()
        sessions?.mcpAnalysisJobs.disable()
        sessions?.mcpTranscriptPlans.removeAll()
        if let sessions {
            for session in sessions.sessions.values {
                session.editor.cancelMCPTrimPreview()
                session.mcpMediaPreview = nil
            }
        }
        sessions?.preferences.localMCPStatus = "Off"
    }

    static func errorData(_ error: Error) -> Data {
        let failure = error as? MCPFailure ?? (error as? CutError).map { MCPFailure($0.code, $0.message) }
            ?? (error is CancellationError ? cancelled() : MCPFailure("operation_failed", error.localizedDescription))
        var fields: [String: Any] = ["code": failure.code, "message": failure.message]
        if let ids = (error as? CutError)?.placementIDs { fields["placement_ids"] = ids }
        return (try? JSONSerialization.data(withJSONObject: ["error": fields])) ?? Data()
    }

    private func receive(_ data: Data, generation token: UUID) async -> Data {
        do {
            let (tool, arguments, integers) = try await Self.decode(data)
            let result = try await perform(tool: tool, arguments: arguments, generation: token, wireIntegers: integers)
            let encoded = try await Self.encode(result)
            try requireAccess(token)
            return encoded
        } catch { return Self.errorData(error) }
    }

    nonisolated static func decode(_ data: Data) async throws -> (String, [String: Any], MCPSchemas.WireIntegers) {
        guard String(data: data, encoding: .utf8) != nil,
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MCPFailure("invalid_arguments", "Provide a UTF-8 JSON request object.")
        }
        let root = request as NSDictionary
        var integers = MCPSchemas.WireIntegers()
        var invalidProjectNumber = false
        if let issue = jsonInputIssue(data, inspectDecimal: { path, token in
            guard path.first == .key("arguments") || path == [.key("version")] else { return }
            let exact = exactJSONInteger(token)
            if exact == nil, path.starts(with: MCPSchemas.projectDataPath) {
                invalidProjectNumber = true
                return
            }
            let value: Any? = path.reduce(root as Any?) { value, part in
                switch part {
                case let .key(key): return (value as? NSDictionary)?.object(forKey: key)
                case let .index(index):
                    guard let array = value as? NSArray, index < array.count else { return nil }
                    return array.object(at: index)
                }
            }
            if exact != value.flatMap(mcpInteger) { integers[path] = .init(exact: exact) }
        }) {
            throw MCPFailure("invalid_arguments", "The JSON request \(issue).")
        }
        guard !invalidProjectNumber else {
            throw MCPFailure("invalid_arguments", "project_data: Expected integers within the supported range.")
        }
        let version: Int?
        if let wire = integers[[.key("version")]] { version = wire.exact }
        else { version = request["version"].flatMap(mcpInteger) }
        guard version == 2 else {
            throw MCPFailure("bridge_version", "Use the helper bundled with this version of MPCut.")
        }
        guard let tool = request["tool"] as? String, let arguments = request["arguments"] as? [String: Any] else {
            throw MCPFailure("invalid_arguments", "Provide a tool name and arguments object.")
        }
        return (tool, arguments, integers)
    }

    nonisolated static func encode(_ result: [String: Any]) async throws -> Data {
        guard JSONSerialization.isValidJSONObject(result) else {
            throw MCPFailure("invalid_result", "The native command returned a result that cannot be encoded.")
        }
        return try JSONSerialization.data(withJSONObject: ["result": result])
    }

    func perform(tool: String, arguments input: [String: Any], generation token: UUID? = nil,
                 wireIntegers: MCPSchemas.WireIntegers = [:]) async throws -> [String: Any] {
        let epoch = token ?? generation
        try requireAccess(epoch)
        let (arguments, operation) = try await Self.prepareOperation(tool: tool, arguments: input, wireIntegers: wireIntegers)
        try requireAccess(epoch)
        guard let sessions else { throw MCPFailure("app_unavailable", "Open MPCut and enable local control.") }
        let isFile = MCPFileRequest.isFileTool(tool)
        let handle = isFile ? nil : arguments["project_handle"] as? String
        let session = handle.flatMap { Self.findProject($0, in: sessions) }
        let missingProject = handle != nil && session == nil

        if let (key, digest) = operation, let previous = operations[key], !isExpired(previous) {
            // A successful close invalidates its own handle. Only an exact retry can
            // retrieve that terminal receipt after the document has gone away.
            if missingProject && (tool != "project_close" || previous.digest != digest) { throw Self.projectClosed() }
            guard previous.digest == digest else {
                throw MCPFailure("operation_conflict", "This operation ID already identifies a different request.")
            }
            let outcome: Result<[String: Any], Error>
            do { outcome = .success(try await wait(for: previous)) }
            catch { outcome = .failure(error) }
            try requireAccess(epoch)
            if let handle, Self.findProject(handle, in: sessions) == nil {
                guard tool == "project_close", (try? outcome.get())?["closed"] as? Bool == true else {
                    throw Self.projectClosed()
                }
            }
            let result = try outcome.get()
            if handle == nil, let returned = result["project_handle"] as? String, Self.findProject(returned, in: sessions) == nil {
                throw Self.projectClosed()
            }
            return result
        }
        if missingProject { throw Self.projectClosed() }

        let expected = arguments["expected_revision"] as? Int
        // Native callbacks may run on a different task from the original tool call.
        let cancellation = EditCancellation()
        let check: @MainActor () throws -> Void = { [weak self, weak sessions, weak session] in
            guard let self else { throw MCPFailure("control_disabled", "Local control has stopped.") }
            try self.requireAccess(epoch)
            if cancellation.isCancelled { throw Self.cancelled() }
            if let handle {
                guard let session, sessions?.sessions[session.id] === session, session.mcpHandle == handle else {
                    throw MCPFailure("project_closed", "The project has closed or changed.")
                }
                if let expected, expected != session.mcpRevision {
                    if ["transcript_editor_edit_apply", "transcript_editor_excerpt_queue"].contains(tool) {
                        throw MCPFailure("stale_transcript_plan", "The timeline changed. Review the transcript edit again.")
                    }
                    throw MCPFailure("stale_revision", "Current revision is \(session.mcpRevision). Read the project state again.")
                }
            }
        }
        if tool == "project_windows_list" {
            return ["projects": sessions.sessions.values.filter { $0.window != nil }.sorted { $0.mcpHandle < $1.mcpHandle }
                .map { self.summary($0, sessions: sessions) }]
        }
        if tool == "project_editor_state_read", let session { try check(); return try snapshot(session, arguments: arguments, sessions: sessions) }

        let dispatch: @MainActor () async throws -> [String: Any] = {
            try check()
            let originalRevision = session?.mcpRevision
            var result = try await sessions.handleMCPCommand(tool: tool, arguments: arguments, session: session, checkAccess: check)
            if let session, let handle {
                let closed = tool == "project_close" && result["closed"] as? Bool == true
                if result["revision"] == nil {
                    if closed { result["revision"] = originalRevision }
                    else if Self.findProject(handle, in: sessions) === session { result["revision"] = session.mcpRevision }
                    else { throw Self.projectClosed() }
                }
                if result["project_handle"] == nil { result["project_handle"] = handle }
            }
            return result
        }
        let run: @MainActor () async throws -> [String: Any] = {
            try await withTaskCancellationHandler { try await dispatch() } onCancel: { cancellation.cancel() }
        }
        guard let (key, digest) = operation else {
            let result = try await run()
            try requireAccess(epoch)
            return result
        }
        let now = ProcessInfo.processInfo.systemUptime
        operations = operations.filter { !isExpired($0.value, now: now) }
        guard operations.count < 256 else {
            // Preserve the retry guarantee through its TTL rather than evicting live receipts.
            throw MCPFailure("retry_cache_full", "The local operation retry cache is full. Retry after older operations expire.")
        }
        let entry = Operation(digest: digest)
        operations[key] = entry
        entry.task = Task { @MainActor [weak entry] in
            let outcome: Result<[String: Any], Error>
            do { outcome = .success(try await run()) }
            catch { outcome = .failure(error) }
            if let entry, entry.outcome == nil { entry.complete(outcome) }
        }
        let result = try await wait(for: entry)
        try requireAccess(epoch)
        return result
    }

    private nonisolated static func prepareOperation(tool: String, arguments input: [String: Any],
                                                     wireIntegers: MCPSchemas.WireIntegers) async throws -> ([String: Any], (String, Data)?) {
        let schemas = try MCPSchemas.loaded.get()
        let arguments = try schemas.validate(tool: tool, arguments: input, wireIntegers: wireIntegers)
        // File operations manage replay for their app-owned jobs independently.
        guard !MCPFileRequest.isFileTool(tool), let key = arguments["operation_id"] as? String else { return (arguments, nil) }
        guard (schemas.inputs[tool]?["properties"] as? [String: Any])?["operation_id"] != nil, key.utf8.count <= 128, !key.isEmpty else {
            throw MCPFailure("invalid_arguments", "Supply a unique operation ID of up to 128 bytes.")
        }
        let fingerprint = try JSONSerialization.data(withJSONObject: [tool, arguments], options: [.sortedKeys])
        return (arguments, (key, Data(SHA256.hash(data: fingerprint))))
    }

    private func isExpired(_ operation: Operation, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        operation.completedAt.map { now - $0 >= 600 } ?? false
    }

    private func wait(for operation: Operation) async throws -> [String: Any] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The operation can finish before this continuation registers.
                if let outcome = operation.outcome {
                    continuation.resume(with: outcome)
                } else if Task.isCancelled {
                    if operation.waiters.isEmpty { operation.task?.cancel() }
                    continuation.resume(throwing: Self.cancelled())
                } else {
                    operation.waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak operation] in
                guard let operation, let waiter = operation.waiters.removeValue(forKey: id) else { return }
                if operation.waiters.isEmpty { operation.task?.cancel() }
                waiter.resume(throwing: Self.cancelled())
            }
        }
    }

    private func requireAccess(_ token: UUID) throws {
        guard running, generation == token, sessions?.preferences.localMCPEnabled == true else {
            throw MCPFailure("control_disabled", "Enable local MCP control in MPCut Settings.")
        }
        if sessions?.isDrainingMCPForQuit == true {
            throw MCPFailure("app_quitting", "MPCut is preparing to quit.")
        }
        if Task.isCancelled { throw Self.cancelled() }
    }

    private static func findProject(_ handle: String, in sessions: ProjectSessions) -> ProjectSession? {
        guard let separator = handle.firstIndex(of: "/"),
              let id = UUID(uuidString: String(handle[..<separator])),
              let session = sessions.sessions[id], session.mcpHandle == handle else { return nil }
        return session
    }

    private static func projectClosed() -> MCPFailure {
        MCPFailure("project_closed", "List open projects to obtain a current document handle.")
    }

    private static func cancelled() -> MCPFailure {
        MCPFailure("cancelled", "The request was cancelled.")
    }

    private func summary(_ session: ProjectSession, sessions: ProjectSessions) -> [String: Any] {
        let url = session.isMulticam ? session.multicam.projectURL : session.editor.projectURL
        var info: [String: Any] = ["project_handle": session.mcpHandle, "revision": session.mcpRevision,
                                   "name": url?.lastPathComponent ?? session.window?.title ?? "Untitled",
                                   "kind": session.isMulticam ? "multicam" : "sequence", "dirty": session.hasUnsavedDocument,
                                   "focused": sessions.commandContext?.session === session]
        info["project_path"] = url?.path
        return info
    }

    private func snapshot(_ session: ProjectSession, arguments: [String: Any], sessions: ProjectSessions) throws -> [String: Any] {
        var result = summary(session, sessions: sessions)
        let limit = arguments["limit"] as? Int ?? 50
        let offset = arguments["offset"] as? Int ?? 0
        result["offset"] = offset
        result["history_max_steps"] = sessions.preferences.historyLimit
        result["modal"] = session.window?.attachedSheet != nil
        func page(_ total: Int) -> Range<Int> {
            let start = min(total, offset)
            return start..<(start + min(limit, total - start))
        }
        var available: [String] = [], unavailable: [String: String] = [:]
        let modal = session.window?.attachedSheet != nil
        func capability(_ tool: String, _ enabled: Bool, _ reason: String, allowsSheet: Bool = false) {
            let blockedBySheet = modal && !allowsSheet
            if enabled && !blockedBySheet { available.append(tool) }
            else { unavailable[tool] = blockedBySheet ? "The project window has an open sheet." : reason }
        }
        if session.isMulticam {
            let model = session.multicam, items = model.assemblyItems, ends = model.assemblyRangeEnds
            guard ends.count == items.count else { throw MCPFailure("invalid_result", "The assembly timeline is inconsistent.") }
            result["total"] = items.count
            result["busy"] = model.isBusy
            if let notice = model.notice { result["notice"] = ["title": notice.title, "message": notice.message] }
            result["playhead"] = model.preview.currentTime().description
            result["clock"] = model.assemblyPreview ? "assembly" : "group"
            if !model.assemblyPreview || model.assemblyStill(at: model.activeOccurrenceIndex) == nil {
                result["group_time"] = model.currentGroupTime().description
            }
            result["playing"] = model.preview.isPlaying
            result["selected_occurrence"] = model.selectedOccurrence
            result["selected_switch"] = model.selectedSwitch?.description
            result["mark_in"] = model.displayedMarkIn?.description
            result["mark_out"] = model.displayedMarkOut?.description
            result["mark_space"] = model.assemblySelection == nil ? "group" : "assembly"
            result["range_tool"] = model.rangeTool
            result["snap"] = model.analysis.snapTarget.rawValue
            result["angles"] = model.project?.angles.map { ["id": $0.id, "name": $0.name ?? URL(fileURLWithPath: $0.file).lastPathComponent] } ?? []
            result["occurrences"] = model.mcpAssemblyRows(in: page(items.count))
            result["tier"] = model.tierReport
            let idle = model.project != nil && !model.isBusy && model.notice == nil
            let canEdit = idle && model.setup.isEmpty
            result["can_edit"] = canEdit && !modal
            for tool in ["timeline_playhead_seek", "playback_transport_play", "playback_transport_pause", "timeline_item_split", "multicam_camera_take", "multicam_assembly_edit"] {
                capability(tool, canEdit, "A loaded, idle multicam project is required.")
            }
            capability("history_undo", canEdit && (!model.undoStack.isEmpty || session.canUndoFeedAngleConversion), "No available undo step.")
            capability("history_redo", canEdit && !model.redoStack.isEmpty, "No available redo step.")
            capability("multicam_sync_suggest", model.project != nil, "Open a multicam project to compare sources.", allowsSheet: true)
            let hasJoin = items.count > 1 || (model.project?.switches.count ?? 0) > 1
            capability("timeline_editor_join_preview", idle && hasJoin && model.pauseEdits.review == nil,
                       "A multicam timeline with an existing join and an idle preview is required.")
            capability("scenes_editor_scan", idle && (model.canScanAnalysis(.scenes) || model.analysis.isScanning(.scenes)), "No available scene scan.")
            capability("silence_editor_scan", idle && (model.canScanAnalysis(.silence) || model.analysis.isScanning(.silence)), "No available silence scan.")
            capability("analysis_editor_sidecars_save", idle && model.canSaveSidecars, "An indexed source and an idle editor are required.")
        } else {
            let model = session.editor, clips = model.sequenceClips, timeline = model.timelineClips.filter { !$0.isStill }
            let offsets = model.mcpSequenceOffsets
            guard clips.count == timeline.count, clips.count == offsets.count else {
                throw MCPFailure("invalid_result", "The sequence timeline is inconsistent.")
            }
            let inserts = try session.mcpStillProject?.mcpStillOccurrences() ?? []
            let entriesByIndex = Dictionary(uniqueKeysWithValues: inserts.map { ($0.index, $0) })
            let total = clips.count + inserts.count
            result["total"] = total
            result["busy"] = model.isBusy
            if let notice = model.alert { result["notice"] = ["title": notice.title, "message": notice.message] }
            let canEdit = model.canEdit && !model.mcpHasActiveTrim
            let canNavigate = model.canNavigate && !model.mcpHasActiveTrim
            result["can_edit"] = canEdit && !modal
            result["playing"] = model.preview.isPlaying
            result["playhead"] = model.playhead
            result["clock"] = "sequence"
            result["snap"] = model.effectiveSnapTarget.rawValue
            result["selected_clip"] = model.mcpSelectedItemID
            result["mark_in"] = model.markIn
            result["mark_out"] = model.markOut
            result["mark_space"] = "sequence"
            result["range_tool"] = model.rangeTool
            var entries = [[String: Any]]()
            let window = page(total)
            var i = window.lowerBound - inserts.prefix { $0.index < window.lowerBound }.count
            for index in window {
                if let card = entriesByIndex[index] {
                    entries.append(["id": card.insert.id, "type": "still", "placement": card.insert.id,
                                    "asset": card.insert.assetID, "sequence_from": card.from.description,
                                    "sequence_to": card.to.description])
                    continue
                }
                let clip = clips[i], start = offsets[i]
                let end = try start.adding(clip.to.subtracting(clip.from))
                entries.append(["id": timeline[i].id.uuidString, "type": "source", "document_id": clip.id, "file": clip.file,
                                "source_id": timeline[i].sourceID.uuidString, "name": timeline[i].name,
                                "source_from": clip.from.description, "source_to": clip.to.description,
                                "sequence_from": start.description, "sequence_to": end.description])
                i += 1
            }
            result["clips"] = entries
            result["tier"] = model.tierReport
            capability("timeline_playhead_seek", canNavigate, "A navigable preview is required.")
            capability("playback_transport_pause", canNavigate, "Playback is unavailable.")
            capability("playback_transport_play", canNavigate && (!model.preview.hasBlockingIssue || model.preview.isPlaying), "Playback is unavailable.")
            capability("timeline_item_split", canEdit, "A loaded, idle timeline is required.")
            capability("history_undo", model.canUndo && !model.mcpHasActiveTrim, "No available undo step.")
            capability("history_redo", (model.canRedo || session.canRedoFeedAngleConversion) && !model.mcpHasActiveTrim, "No available redo step.")
            capability("timeline_editor_join_preview", canEdit && total > 1 && model.cutPreview == nil,
                       "A sequence with an existing join and an idle preview is required.")
            capability("source_selects_list", true, "", allowsSheet: true)
            let canEditSources = !model.isBusy && model.alert == nil && !model.mcpHasActiveTrim
            for tool in ["source_select_save", "source_select_remove", "sequence_source_ranges_apply"] {
                capability(tool, canEditSources, "An idle sequence editor is required.")
            }
            capability("scenes_editor_scan", canEdit && (model.canScanScenes || model.sceneProgress != nil), "No available scene scan.")
            capability("silence_editor_scan", canEdit && (model.canScanSilence || model.silenceProgress != nil), "No available silence scan.")
            capability("analysis_editor_sidecars_save", canEdit && model.canSaveAnalysisSidecars, "An indexed source and an idle editor are required.")
        }
        let hasTimeline = !session.isMulticam || session.multicam.project != nil
        let hasMedia = session.mcpHasProjectMedia
        capability("project_editor_media_list", hasMedia, "Open a project to list its media.", allowsSheet: true)
        capability("project_editor_media_locate", hasMedia, "Open a project to locate its media.", allowsSheet: true)
        for tool in ["project_editor_media_relink", "project_editor_media_replace"] {
            capability(tool, hasMedia && session.mcpCanEditProjectMedia, "An idle project is required.")
        }
        capability("timeline_editor_range_map", hasTimeline, "Open a timeline to map a range.", allowsSheet: true)
        capability("history_editor_compare", hasTimeline, "Open a timeline to compare retained states.", allowsSheet: true)
        capability("still_editor_placements_list", session.mcpStillProject != nil, "Open a timeline to list still placements.", allowsSheet: true)
        for tool in ["timeline_gap_insert", "still_editor_placement_insert", "still_editor_picture_replace", "still_editor_placement_update", "still_editor_placement_remove", "still_editor_asset_relink"] {
            capability(tool, session.mcpCanEditStills, "An editable picture timeline is required.")
        }
        let stillProject = session.mcpStillProject
        let stillOnly = stillProject?.stillFormat != nil
        let hasSoundtrack = stillProject?.stillSoundtrack != nil
        let firstAsset = stillProject?.stillInserts.first?.assetID
        let onlyImage = stillProject?.stillInserts.count == 1 &&
            stillProject?.stillAssets.contains(where: { $0.id == firstAsset && !$0.isGap }) == true
        capability("still_editor_soundtrack_attach", session.mcpCanEditStills && stillOnly, "An editable still-only project is required.")
        capability("still_editor_soundtrack_fit", session.mcpCanEditStills && hasSoundtrack && onlyImage,
                   "One image and an attached soundtrack are required.")
        capability("still_editor_soundtrack_detach", session.mcpCanEditStills && hasSoundtrack, "An attached soundtrack is required.")
        capability("timeline_clips_space", session.mcpCanEditStills && session.mcpStillProject?.hasSpacingBoundaries == true,
                   "An editable picture timeline with at least two clips or still pictures is required.")
        if let project = session.mcpStillProject, project.mcpHasStills || project.programColorPolicy != nil {
            let stills = try project.mcpStillList(location: session.mcpStillLocation, offset: offset, limit: limit)
            result["stills"] = stills
            result["program_color_policy"] = stills["program_color_policy"]
        }
        result["available_operations"] = available
        result["unavailable_operations"] = unavailable
        return result
    }
}
