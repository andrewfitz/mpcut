import AppKit
import Foundation
import MPCutCore

@MainActor
extension ProjectSessions {
    func mcpLifecycle(tool: String, arguments: [String: Any], session: ProjectSession?,
                      checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        var accessError: Error?
        let commitCheck: (ProjectSession) -> (() -> Bool) = { [weak self] target in
            let handle = target.mcpHandle, revision = target.mcpRevision
            return { [weak target] in
                do {
                    try checkAccess()
                    guard let target, self?.sessions[target.id] === target, target.mcpHandle == handle else {
                        throw MCPFailure("project_closed", "The project has closed or changed.")
                    }
                    guard target.mcpRevision == revision else {
                        throw MCPFailure("stale_revision", "The project changed while loading media. Read its state again.")
                    }
                    guard !target.hasLifecycleModal else { throw lifecycleBusy() }
                    return true
                } catch {
                    accessError = error
                    return false
                }
            }
        }
        switch tool {
        case "get_native_operations", "cancel_native_operation":
            return try mcpNativeOperations(tool: tool, arguments: arguments, session: session)
        case "get_preferences":
            return preferences.mcpValues
        case "set_preference":
            try preferences.mcpSet(arguments)
            return preferences.mcpValues
        case "list_drafts":
            return ["drafts": try ProjectDraft.recoverable().map { url -> [String: Any] in
                let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return ["path": url.path, "modified": date?.ISO8601Format() as Any? ?? NSNull()]
            }]
        case "new_project":
            let kind = arguments["kind"] as? String ?? "sequence"
            guard ["sequence", "multicam"].contains(kind) else { throw lifecycleInvalid("Unknown editor kind.") }
            let urls = try inputMedia(arguments, required: kind == "multicam")
            let target = try createWindow()
            target.isMulticam = kind == "multicam"
            if !urls.isEmpty {
                do { try await addMCPMedia(urls, at: nil, to: target, allowed: commitCheck(target), checkAccess: checkAccess) }
                catch { throw accessError ?? error }
            }
            if let accessError { throw accessError }
            return lifecycleState(target)
        case "open_project", "recover_project":
            let url = try Self.resolvedProjectURL(projectPath(arguments))
            if tool == "recover_project" {
                guard try ProjectDraft.recoverable().contains(where: { Self.sameFile($0, url) }) else {
                    throw MCPFailure("draft_unavailable", "List recoverable drafts and use a returned draft path.")
                }
            }
            let existing = project(at: url)
            let target = try openProjectAtURL(url, in: nil, commitCheck: commitCheck)
            let opening = target.isMulticam ? target.multicam.openingProjectURL : target.editor.openingProjectURL
            if opening != nil {
                try await waitForLoad(target, worker: target.activeMCPWorker, owned: existing == nil, checkAccess: checkAccess)
            }
            if let accessError { throw accessError }
            let installed = target.isMulticam ? target.multicam.projectURL ?? target.multicam.draft.url
                                             : target.editor.projectURL ?? target.editor.draft.url
            guard let installed, Self.sameFile(installed, url) else {
                throw MCPFailure("open_failed", target.multicam.notice?.message ?? target.editor.alert?.message
                                 ?? "The project did not finish opening.")
            }
            return lifecycleState(target)
        case "add_media", "save_project", "close_project", "focus_project", "show_history",
             "set_video_monitor", "get_multicam_setup", "multicam_setup", "dismiss_notice":
            guard let session else { throw lifecycleInvalid("Supply a project handle.") }
            if ["multicam_setup", "get_multicam_setup"].contains(tool) {
                return try setupMCPMulticam(session, arguments: arguments, inspect: tool == "get_multicam_setup")
            }
            switch tool {
            case "add_media":
                guard !session.hasLifecycleModal else { throw lifecycleBusy() }
                let urls = try inputMedia(arguments, required: true)
                let index = try arguments["index"].map { try lifecycleInteger($0, "index") }
                do {
                    try await addMCPMedia(urls, at: index, to: session, allowed: commitCheck(session), checkAccess: checkAccess)
                }
                catch { throw accessError ?? error }
                if let accessError { throw accessError }
            case "save_project":
                try writeMCPProject(session, arguments: arguments)
            case "close_project":
                return try closeMCPProject(session, arguments: arguments)
            case "dismiss_notice":
                let message = session.isMulticam ? session.multicam.notice?.message : session.editor.alert?.message
                guard let message, message == arguments["message"] as? String else {
                    throw MCPFailure("notice_changed", "Read the current notice from editor state.")
                }
                if session.isMulticam { session.multicam.notice = nil }
                else { session.editor.dismissNotice() }
            case "focus_project":
                guard let window = session.window else { throw lifecycleBusy() }
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            case "set_video_monitor":
                guard let visible = lifecycleBool(arguments["visible"]) else { throw lifecycleInvalid("Supply visible.") }
                if visible { session.showMonitor() } else { session.monitor?.close() }
            default:
                if session.isHistoryPresented { return lifecycleState(session) }
                guard !session.hasLifecycleModal,
                      session.isMulticam ? !session.multicam.isBusy && session.multicam.notice == nil
                                        : !session.editor.isBusy && session.editor.alert == nil else { throw lifecycleBusy() }
                session.isHistoryPresented = true
            }
            return lifecycleState(session)
        default: return nil
        }
    }

    private func lifecycleState(_ session: ProjectSession) -> [String: Any] {
        let url = session.isMulticam ? session.multicam.projectURL : session.editor.projectURL
        return ["project": session.mcpHandle, "revision": session.mcpRevision,
                "kind": session.isMulticam ? "multicam" : "sequence",
                "dirty": session.hasUnsavedDocument, "path": url?.path as Any? ?? NSNull(),
                "setupPending": !session.multicam.setup.isEmpty, "monitorVisible": session.monitor?.isVisible == true]
    }

    private func waitForLoad(_ session: ProjectSession, worker: MCPNativeOperation?, owned: Bool,
                             checkAccess: @MainActor () throws -> Void) async throws {
        guard let worker else { return }
        let mode = session.mcpModeGeneration
        do {
            while session.activeMCPWorker?.id == worker.id {
                try checkAccess()
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            if owned { session.cancelMCPWorker(worker) }
            throw error
        }
        guard sessions[session.id] === session, session.mcpModeGeneration == mode else {
            throw MCPFailure("project_closed", "The target project closed or changed.")
        }
    }

    private func addMCPMedia(_ urls: [URL], at index: Int?, to session: ProjectSession,
                             allowed: @escaping () -> Bool, checkAccess: @MainActor () throws -> Void) async throws {
        let before = session.editor.mcpClipIDs
        if session.isMulticam {
            guard index == nil else { throw lifecycleInvalid("An insertion index applies to ordinary sequences.") }
            guard session.multicam.canChooseSources, session.multicam.notice == nil else { throw lifecycleBusy() }
            let known = session.multicam.project?.sources.map { URL(fileURLWithPath: $0.file) } ?? []
            if urls.allSatisfy({ url in known.contains { Self.sameFile($0, url) } }) { return }
            session.multicam.importSources(urls, allowCommit: allowed)
        } else {
            guard session.canChooseMedia else { throw lifecycleBusy() }
            if let index, !(0...session.editor.sequenceClips.count).contains(index) {
                throw lifecycleInvalid("The insertion index is outside the sequence.")
            }
            session.editor.importFiles(urls, at: index, allowCommit: allowed)
        }
        try await waitForLoad(session, worker: session.activeMCPWorker, owned: true, checkAccess: checkAccess)
        if session.isMulticam ? session.multicam.setup.isEmpty : session.editor.mcpClipIDs == before {
            let reason = session.multicam.notice?.message ?? session.editor.alert?.message ?? "Import ended without adding media."
            throw MCPFailure("import_incomplete", reason + " Project: " + session.mcpHandle)
        }
        if let message = session.isMulticam ? session.multicam.notice?.message : session.editor.alert?.message {
            throw MCPFailure("import_incomplete", message + " Inspect successfully imported sources in project " + session.mcpHandle)
        }
    }

    private func writeMCPProject(_ session: ProjectSession, arguments: [String: Any]) throws {
        guard !session.hasLifecycleModal else { throw lifecycleBusy() }
        let current = session.isMulticam ? session.multicam.projectURL : session.editor.projectURL
        let url: URL
        if arguments["path"] != nil { url = try projectPath(arguments) }
        else if let current { url = current }
        else { throw lifecycleInvalid("Supply a destination path for this untitled project.") }
        guard url.pathExtension.lowercased() == "cut" else { throw lifecycleInvalid("Choose a .cut destination.") }
        guard project(at: url, excluding: session) == nil else {
            throw MCPFailure("project_open", "Another window already has this project open.")
        }
        // A distinct hard link or symbolic link can be a Save As destination.
        // Only the current pathname grants implicit replacement.
        let replacing = current?.standardizedFileURL == url || lifecycleBool(arguments["replaceExisting"]) == true
        do {
            if session.isMulticam { try session.multicam.writeProject(to: url, replacingExisting: replacing) }
            else { try session.editor.writeProject(to: url, replacingExisting: replacing) }
        } catch let error as CutError {
            throw MCPFailure(error.code, error.localizedDescription)
        }
    }

    private func closeMCPProject(_ session: ProjectSession, arguments: [String: Any]) throws -> [String: Any] {
        let choice = arguments["changes"] as? String
        if let choice, !["save", "discard", "cancel"].contains(choice) { throw lifecycleInvalid("Unknown close decision.") }
        if choice == "cancel" { return ["closed": false] }
        guard session.window != nil, !session.hasLifecycleModal,
              !(session.isMulticam ? session.multicam.isBusy : session.editor.isBusy || session.editor.isSavingSidecars)
        else { throw lifecycleBusy() }
        if session.hasUnsavedDocument {
            switch choice {
            case "save": try writeMCPProject(session, arguments: arguments)
            case "discard": break
            default: throw MCPFailure("unsaved_changes", "Choose save, discard, or cancel to close this edited window.")
            }
        }
        session.requestWindowClose(discardingChanges: choice == "discard")
        guard sessions[session.id] == nil else { throw MCPFailure("close_refused", "The window declined the close request.") }
        return ["closed": true]
    }

    private func setupMCPMulticam(_ session: ProjectSession, arguments: [String: Any], inspect: Bool) throws -> [String: Any] {
        let model = session.multicam
        guard session.isMulticam, !model.setup.isEmpty else { throw MCPFailure("no_setup", "Add multicam sources to start setup.") }
        if inspect {
            let rows = model.setup.map { draft -> [String: Any] in
                ["id": draft.id, "path": draft.source.file, "video": draft.media.hasVideo,
                 "name": draft.source.name as Any? ?? NSNull(), "streams": draft.media.audio.map { $0.stream.index }]
            }
            return ["sources": rows, "adding": model.project != nil,
                    "opening": model.pendingSetupProject?.referenceAngle as Any? ?? NSNull(),
                    "audio": try (model.pendingSetupProject?.audio ?? model.project?.audio).map {
                        try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                    } ?? NSNull()]
        }
        guard !model.isBusy, model.notice == nil, !session.isHistoryPresented,
              !model.isBulkQueuePresented, !model.isReplacementAudioPresented, model.report == nil,
              session.window?.attachedSheet == nil || session.window?.attachedSheet === model.setupWindow else {
            throw lifecycleBusy()
        }
        switch arguments["action"] as? String {
        case "dismiss": model.dismissSetup()
        case "confirm":
            var drafts = model.setup
            if let ids = arguments["sourceOrder"] as? [String] {
                guard ids.count == drafts.count, Set(ids) == Set(drafts.map(\.id)) else {
                    throw lifecycleInvalid("List every pending source ID once in sourceOrder.")
                }
                let byID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
                drafts = ids.compactMap { byID[$0] }
            }
            let names = arguments["names"] as? [String: String] ?? [:]
            let streams = arguments["audioStreams"] as? [String: Any] ?? [:]
            let known = Set(drafts.map(\.id))
            guard Set(names.keys).isSubset(of: known), Set(streams.keys).isSubset(of: known) else {
                throw lifecycleInvalid("The setup contains an unknown source ID.")
            }
            for index in drafts.indices {
                let id = drafts[index].id
                if let name = names[id] { drafts[index].source.name = name }
                if let selection = streams[id] {
                    if selection is NSNull { drafts[index].source.audioStream = nil }
                    else {
                        let stream = try lifecycleInteger(selection, "audio stream")
                        guard drafts[index].media.audio.contains(where: { $0.stream.index == stream }) else {
                            throw lifecycleInvalid("The selected microphone stream is unavailable.")
                        }
                        drafts[index].source.audioStream = stream
                    }
                }
            }
            let opening = arguments["opening"] as? String ?? model.pendingSetupProject?.referenceAngle
                ?? drafts.first(where: { $0.media.hasVideo })?.id ?? ""
            if model.project == nil, !drafts.contains(where: { $0.id == opening && $0.media.hasVideo }) {
                throw lifecycleInvalid("Choose an opening camera from the setup sources.")
            }
            var audio = model.pendingSetupProject?.audio ?? model.project?.audio ?? .none
            if let raw = arguments["audio"] {
                guard let value = raw as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let policy = try? JSONDecoder().decode(MulticamAudioPolicy.self, from: data) else {
                    throw lifecycleInvalid("Choose follow, none or a fixed source and stream for program audio.")
                }
                audio = policy
                if case let .fixed(track) = audio,
                   !drafts.contains(where: { $0.id == track.source && $0.media.audio.contains(where: { $0.stream.index == track.stream }) }) {
                    throw lifecycleInvalid("Choose a fixed microphone and stream from the setup sources.")
                }
            }
            if model.project != nil, arguments["opening"] != nil || arguments["audio"] != nil {
                throw lifecycleInvalid("Set the opening camera and program audio during initial project setup.")
            }
            model.confirmSetup(drafts: drafts, opening: opening, audio: audio)
            guard model.setup.isEmpty else { throw MCPFailure("setup_failed", model.notice?.message ?? "The editor declined setup.") }
        default: throw lifecycleInvalid("Choose confirm or dismiss.")
        }
        return lifecycleState(session)
    }
}

private func lifecycleBusy() -> MCPFailure { MCPFailure("busy", "Finish the current editor operation or close its sheet.") }
private func lifecycleInvalid(_ message: String) -> MCPFailure { MCPFailure("invalid_arguments", message) }

private func projectPath(_ arguments: [String: Any]) throws -> URL {
    guard let path = arguments["path"] as? String, path.hasPrefix("/"), !path.utf8.contains(0) else {
        throw lifecycleInvalid("Supply an absolute local file path.")
    }
    return URL(fileURLWithPath: path).standardizedFileURL
}

private func inputMedia(_ arguments: [String: Any], required: Bool) throws -> [URL] {
    guard arguments["paths"] != nil || required else { return [] }
    guard let paths = arguments["paths"] as? [String], !paths.isEmpty,
          paths.count <= 512 else { throw lifecycleInvalid("Supply 1 to 512 local media paths.") }
    return try paths.map { path in
        let url = try projectPath(["path": path])
        guard FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw lifecycleInvalid("The recording is unavailable at \(url.path).")
        }
        return url
    }
}

private func lifecycleBool(_ value: Any?) -> Bool? {
    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}

private func lifecycleNumber(_ value: Any?, _ key: String) throws -> Double {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
        throw lifecycleInvalid("Supply a finite number for \(key).")
    }
    return n.doubleValue
}

private func lifecycleInteger(_ value: Any?, _ key: String) throws -> Int {
    guard let integer = Int(exactly: try lifecycleNumber(value, key)) else { throw lifecycleInvalid("Supply an integer for \(key).") }
    return integer
}

@MainActor
private extension EditorPreferences {
    var mcpValues: [String: Any] {
        ["historyLimit": historyLimit, "useAnalysisSidecars": useAnalysisSidecars,
         "defaultExportMode": defaultExportMode.rawValue, "snapTarget": snapTarget.rawValue,
         "largeThumbnails": largeThumbnails, "minimumPause": minimumPause, "leavePause": leavePause,
         "volume": volume, "isMuted": isMuted, "scrubSoundEnabled": scrubSoundEnabled, "jpegPreset": jpegPreset.rawValue,
         "localMCPEnabled": localMCPEnabled]
    }

    func mcpSet(_ arguments: [String: Any]) throws {
        guard let key = arguments["key"] as? String, let value = arguments["value"] else { throw lifecycleInvalid("Supply key and value.") }
        func flag() throws -> Bool {
            guard let b = lifecycleBool(value) else { throw lifecycleInvalid("Supply a Boolean for \(key).") }
            return b
        }
        switch key {
        case "useAnalysisSidecars": useAnalysisSidecars = try flag()
        case "largeThumbnails": largeThumbnails = try flag()
        case "scrubSoundEnabled": scrubSoundEnabled = try flag()
        case "isMuted": isMuted = try flag()
        case "historyLimit":
            let limit = try lifecycleInteger(value, key)
            guard Self.historyStepRange.contains(limit) else { throw lifecycleInvalid("History limit must be between 0 and 500.") }
            historyLimit = limit
        case "volume":
            let v = try lifecycleNumber(value, key)
            guard (0...1).contains(v) else { throw lifecycleInvalid("Volume must be between 0 and 1.") }
            volume = Float(v)
        case "minimumPause", "leavePause":
            let v = try lifecycleNumber(value, key)
            let minimum = key == "minimumPause" ? 1.0 / Double(AudioWaveform.rate) : 0
            guard v >= minimum else { throw lifecycleInvalid("The pause duration is too short.") }
            if key == "minimumPause" { minimumPause = v } else { leavePause = v }
        case "defaultExportMode":
            guard let s = value as? String, let v = ExportMode(rawValue: s) else { throw lifecycleInvalid("Choose copy, smart, or encode.") }
            defaultExportMode = v
        case "snapTarget":
            guard let s = value as? String, let v = TimelineSnapTarget(rawValue: s) else { throw lifecycleInvalid("Choose off, keyframes, scenes, or silence.") }
            snapTarget = v
        case "jpegPreset":
            guard let s = value as? String, let v = JPEGPreset(rawValue: s) else { throw lifecycleInvalid("Choose review or full.") }
            jpegPreset = v
        default: throw lifecycleInvalid("Unknown or read-only preference: \(key).")
        }
    }
}
