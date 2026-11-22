import Combine
import CryptoKit
import Foundation
import MPCutCore

extension ProjectSession {
    var mcpHandle: String {
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
        if let sessions { for session in sessions.sessions.values { session.editor.cancelMCPTrimPreview() } }
        sessions?.preferences.localMCPStatus = "Off"
    }

    private static func errorData(_ error: Error) -> Data {
        let failure = error as? MCPFailure ?? (error as? CutError).map { MCPFailure($0.code, $0.message) }
            ?? (error is CancellationError ? cancelled() : MCPFailure("operation_failed", error.localizedDescription))
        var fields: [String: Any] = ["code": failure.code, "message": failure.message]
        if let ids = (error as? CutError)?.placementIDs { fields["placementIDs"] = ids }
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

    private nonisolated static func decode(_ data: Data) async throws -> (String, [String: Any], MCPSchemas.WireIntegers) {
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
        guard version == 1 else {
            throw MCPFailure("bridge_version", "Use the helper bundled with this version of MPCut.")
        }
        guard let tool = request["tool"] as? String, let arguments = request["arguments"] as? [String: Any] else {
            throw MCPFailure("invalid_arguments", "Provide a tool name and arguments object.")
        }
        return (tool, arguments, integers)
    }

    private nonisolated static func encode(_ result: [String: Any]) async throws -> Data {
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
        let isFile = tool.hasPrefix("file_")
        let handle = isFile ? nil : arguments["project"] as? String
        let session = handle.flatMap { Self.findProject($0, in: sessions) }
        let missingProject = handle != nil && session == nil

        if let (key, digest) = operation, let previous = operations[key], !isExpired(previous) {
            // A successful close invalidates its own handle. Only an exact retry can
            // retrieve that terminal receipt after the document has gone away.
            if missingProject && (tool != "close_project" || previous.digest != digest) { throw Self.projectClosed() }
            guard previous.digest == digest else {
                throw MCPFailure("operation_conflict", "This operation ID already identifies a different request.")
            }
            let outcome: Result<[String: Any], Error>
            do { outcome = .success(try await wait(for: previous)) }
            catch { outcome = .failure(error) }
            try requireAccess(epoch)
            if let handle, Self.findProject(handle, in: sessions) == nil {
                guard tool == "close_project", (try? outcome.get())?["closed"] as? Bool == true else {
                    throw Self.projectClosed()
                }
            }
            let result = try outcome.get()
            if handle == nil, let returned = result["project"] as? String, Self.findProject(returned, in: sessions) == nil {
                throw Self.projectClosed()
            }
            return result
        }
        if missingProject { throw Self.projectClosed() }

        let expected = arguments["expectedRevision"] as? Int
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
                    throw MCPFailure("stale_revision", "Current revision is \(session.mcpRevision). Read the project state again.")
                }
            }
        }
        if tool == "list_projects" {
            return ["projects": sessions.sessions.values.filter { $0.window != nil }.sorted { $0.mcpHandle < $1.mcpHandle }
                .map { self.summary($0, sessions: sessions) }]
        }
        if tool == "get_editor_state", let session { try check(); return try snapshot(session, arguments: arguments, sessions: sessions) }

        let dispatch: @MainActor () async throws -> [String: Any] = {
            try check()
            let originalRevision = session?.mcpRevision
            var result = try await sessions.handleMCPCommand(tool: tool, arguments: arguments, session: session, checkAccess: check)
            if let session, let handle {
                let closed = tool == "close_project" && result["closed"] as? Bool == true
                if result["revision"] == nil {
                    if closed { result["revision"] = originalRevision }
                    else if Self.findProject(handle, in: sessions) === session { result["revision"] = session.mcpRevision }
                    else { throw Self.projectClosed() }
                }
                if result["project"] == nil { result["project"] = handle }
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
        guard !tool.hasPrefix("file_"), let key = arguments["operationID"] as? String else { return (arguments, nil) }
        guard (schemas.inputs[tool]?["properties"] as? [String: Any])?["operationID"] != nil, key.utf8.count <= 128, !key.isEmpty else {
            throw MCPFailure("invalid_arguments", "Supply a unique operation ID of up to 128 bytes.")
        }
        let fingerprint = try JSONSerialization.data(withJSONObject: [tool, arguments], options: [.sortedKeys])
        return (arguments, (key, Data(SHA256.hash(data: fingerprint))))
    }

    private func isExpired(_ operation: Operation, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        operation.completedAt.map { now - $0 >= 600 } ?? false
    }

    private func wait(for operation: Operation) async throws -> [String: Any] {
        if let outcome = operation.outcome { return try outcome.get() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.waiters[id] = $0 }
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
        var info: [String: Any] = ["project": session.mcpHandle, "revision": session.mcpRevision,
                                   "name": url?.lastPathComponent ?? session.window?.title ?? "Untitled",
                                   "kind": session.isMulticam ? "multicam" : "sequence", "dirty": session.hasUnsavedDocument,
                                   "focused": sessions.commandContext?.session === session]
        info["path"] = url?.path
        return info
    }

    private func snapshot(_ session: ProjectSession, arguments: [String: Any], sessions: ProjectSessions) throws -> [String: Any] {
        var result = summary(session, sessions: sessions)
        let limit = arguments["limit"] as? Int ?? 50
        let offset = arguments["offset"] as? Int ?? 0
        result["offset"] = offset
        result["historyLimit"] = sessions.preferences.historyLimit
        result["modal"] = session.window?.attachedSheet != nil
        func page(_ total: Int) -> Range<Int> {
            let start = min(total, offset)
            return start..<(start + min(limit, total - start))
        }
        var available: [String] = [], unavailable: [String: String] = [:]
        let modal = session.window?.attachedSheet != nil
        func capability(_ tool: String, _ enabled: Bool, _ reason: String) {
            if enabled && !modal { available.append(tool) }
            else { unavailable[tool] = modal ? "The project window has an open sheet." : reason }
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
                result["groupTime"] = model.currentGroupTime().description
            }
            result["playing"] = model.preview.isPlaying
            result["selectedOccurrence"] = model.selectedOccurrence
            result["selectedSwitch"] = model.selectedSwitch?.description
            result["markIn"] = model.displayedMarkIn?.description
            result["markOut"] = model.displayedMarkOut?.description
            result["markSpace"] = model.assemblySelection == nil ? "group" : "assembly"
            result["rangeTool"] = model.rangeTool
            result["snap"] = model.analysis.snapTarget.rawValue
            result["angles"] = model.project?.angles.map { ["id": $0.id, "name": $0.name ?? URL(fileURLWithPath: $0.file).lastPathComponent] } ?? []
            result["occurrences"] = model.mcpAssemblyRows(in: page(items.count))
            let idle = model.project != nil && !model.isBusy && model.notice == nil
            let canEdit = idle && model.setup.isEmpty
            result["canEdit"] = canEdit && !modal
            for tool in ["seek", "set_playback", "split_at", "set_camera_at", "multicam_assembly"] {
                capability(tool, canEdit, "A loaded, idle multicam project is required.")
            }
            capability("undo", canEdit && !model.undoStack.isEmpty, "No available undo step.")
            capability("redo", canEdit && !model.redoStack.isEmpty, "No available redo step.")
            let canScan = model.canScanAnalysis(.scenes) || model.canScanAnalysis(.silence)
                || model.analysis.isScanning(.scenes) || model.analysis.isScanning(.silence)
            capability("scan_analysis", idle && canScan, "No available scan.")
            capability("save_analysis_sidecars", idle && model.canSaveSidecars, "An indexed source and an idle editor are required.")
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
            result["canEdit"] = canEdit && !modal
            result["playing"] = model.preview.isPlaying
            result["playhead"] = model.playhead
            result["clock"] = "sequence"
            result["snap"] = model.effectiveSnapTarget.rawValue
            result["selectedClip"] = model.mcpSelectedItemID
            result["markIn"] = model.markIn
            result["markOut"] = model.markOut
            result["markSpace"] = "sequence"
            result["rangeTool"] = model.rangeTool
            var entries = [[String: Any]]()
            let window = page(total)
            var i = window.lowerBound - inserts.prefix { $0.index < window.lowerBound }.count
            for index in window {
                if let card = entriesByIndex[index] {
                    entries.append(["id": card.insert.id, "type": "still", "placement": card.insert.id,
                                    "asset": card.insert.assetID, "sequenceFrom": card.from.description,
                                    "sequenceTo": card.to.description])
                    continue
                }
                let clip = clips[i], start = offsets[i]
                let end = try start.adding(clip.to.subtracting(clip.from))
                entries.append(["id": timeline[i].id.uuidString, "type": "source", "documentID": clip.id, "file": clip.file,
                                "sourceID": timeline[i].sourceID.uuidString, "name": timeline[i].name,
                                "sourceFrom": clip.from.description, "sourceTo": clip.to.description,
                                "sequenceFrom": start.description, "sequenceTo": end.description])
                i += 1
            }
            result["clips"] = entries
            capability("seek", canNavigate, "A navigable preview is required.")
            capability("set_playback", canNavigate && (!model.preview.hasBlockingIssue || model.preview.isPlaying), "Playback is unavailable.")
            capability("split_at", canEdit, "A loaded, idle timeline is required.")
            capability("undo", model.canUndo && !model.mcpHasActiveTrim, "No available undo step.")
            capability("redo", model.canRedo && !model.mcpHasActiveTrim, "No available redo step.")
            let canScan = model.canScanSilence || model.canScanScenes || model.sceneProgress != nil || model.silenceProgress != nil
            capability("scan_analysis", canEdit && canScan, "No available scan.")
            capability("save_analysis_sidecars", canEdit && model.canSaveAnalysisSidecars, "An indexed source and an idle editor are required.")
        }
        capability("list_stills", session.mcpStillProject != nil, "Open a timeline to list still placements.")
        for tool in ["add_still", "update_still", "remove_still", "relink_still"] {
            capability(tool, session.mcpCanEditStills, "An editable picture timeline is required.")
        }
        if let project = session.mcpStillProject, project.mcpHasStills || project.programColorPolicy != nil {
            let stills = try project.mcpStillList(location: session.mcpStillLocation, offset: offset, limit: limit)
            result["stills"] = stills
            result["programColorPolicy"] = stills["programColorPolicy"]
        }
        result["availableOperations"] = available
        result["unavailableOperations"] = unavailable
        return result
    }
}
