import Foundation
import MPCutCore

struct MCPProjectMediaPreview {
    let id = UUID().uuidString
    let owner: String
    let revision: Int
    let request: Data
    let replacement: MediaReplacePreview
}

@MainActor
extension ProjectSession {
    var mcpMediaArchive: LiveProjectMediaArchive? {
        isMulticam ? multicam.projectMediaArchive : editor.projectMediaArchive
    }

    var mcpHasProjectMedia: Bool {
        isMulticam ? multicam.project != nil : !editor.isEmpty || editor.hasHistory || editor.projectURL != nil
    }

    var mcpMediaCheckingVolumes: Set<String> {
        isMulticam ? multicam.interchangeCheckingVolumes : editor.interchangeCheckingVolumes
    }

    func mcpMediaStatus(_ row: ProjectMediaRow) -> ProjectMediaStatus {
        let status = isMulticam ? multicam.mediaStatus(for: row.url) : editor.mediaStatus(for: row.url)
        return status == .offline && row.status == .ignored ? .ignored : status
    }

    func mcpMediaStatusSnapshot() throws -> Any {
        guard let archive = mcpMediaArchive else { return [] as [Any] }
        let rows = ProjectMedia.inventory(project: archive.project, relativeTo: archive.documentURL,
                                          snapshot: archive.snapshot, checkFile: false).map { row in
            var current = row
            current.status = mcpMediaStatus(row)
            return current
        }
        return try mediaJSON(rows)
    }

    var mcpCanEditProjectMedia: Bool {
        guard window?.attachedSheet == nil else { return false }
        if isMulticam {
            return multicam.project != nil && !multicam.isBusy && multicam.notice == nil
                && multicam.setup.isEmpty && multicam.pauseEdits.review == nil
        }
        return !editor.isBusy && editor.alert == nil && !editor.mcpHasActiveTrim && editor.cutPreview == nil
    }

    func mcpRelinkMedia(_ mappings: [ProjectMediaMapping],
                        checkAccess: @escaping @MainActor () throws -> Void) async throws -> LiveProjectMediaRelinkBatch {
        if isMulticam {
            return try await multicam.relinkProjectMedia(mappings, validateCommit: checkAccess)
        }
        return try await editor.relinkProjectMedia(mappings, validateCommit: checkAccess)
    }
}

@MainActor
extension ProjectSessions {
    func mcpProjectMedia(tool: String, arguments: [String: Any], session: ProjectSession,
                         checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard ["project_editor_media_list", "project_editor_media_locate", "project_editor_media_relink",
               "project_editor_media_replace", "project_editor_media_leave_offline",
               "project_editor_media_revert", "still_editor_asset_relink"].contains(tool) else { return nil }
        guard let archive = session.mcpMediaArchive else {
            throw MCPCommandError("invalid_target", "Open a project with media references.")
        }
        let revision = session.mcpRevision
        let input = MCPFileRequest.Fields(values: arguments)
        func path(_ key: String, directory: Bool = false) throws -> URL {
            guard let value = try input.path(key) else { throw input.invalid("Supply " + key + ".") }
            return URL(fileURLWithPath: value, isDirectory: directory)
        }
        func text(_ key: String) throws -> String {
            guard let value = try input.string(key) else { throw input.invalid("Supply " + key + ".") }
            return value
        }
        let checkRevision: @MainActor () throws -> Void = { [weak session] in
            try checkAccess()
            guard session?.mcpRevision == revision else {
                throw MCPCommandError("stale_revision", "The project changed. Read the current revision again.")
            }
        }

        switch tool {
        case "project_editor_media_list":
            let includeHistory = arguments["include_history"] as? Bool == true
            let current = await Task.detached(priority: .userInitiated) {
                ProjectMedia.inventory(project: archive.project, undo: archive.undo, redo: archive.redo,
                                       relativeTo: archive.documentURL, snapshot: archive.snapshot, checkFile: false)
            }.value
            try checkRevision()
            let rows: [ProjectMediaRow]
            if includeHistory {
                // Keep live presentation for current paths and probe history-only paths off the main actor.
                let statuses = Dictionary(uniqueKeysWithValues: current.map { ($0.url, session.mcpMediaStatus($0)) })
                rows = await Task.detached(priority: .userInitiated) {
                    ProjectMediaVolume.$checking.withValue(archive.checkingVolumes) {
                        ProjectMedia.inventory(project: archive.project, undo: archive.undo, redo: archive.redo,
                                               relativeTo: archive.documentURL, snapshot: archive.snapshot,
                                               includeHistory: true, statuses: statuses)
                    }
                }.value
                try checkRevision()
            } else {
                rows = current
            }
            let start = min(rows.count, arguments["offset"] as? Int ?? 0)
            let end = start + min(rows.count - start, arguments["limit"] as? Int ?? 50)
            let page = rows[start..<end].map { row in
                var current = row
                if !includeHistory {
                    current.status = session.mcpMediaStatus(row)
                }
                return current
            }
            return ["items": try mediaJSON(page), "total": rows.count, "offset": start]

        case "project_editor_media_locate":
            let folder = try path("folder", directory: true)
            let includeHistory = arguments["include_history"] as? Bool == true
            let applyMatches = arguments["apply_matches"] as? Bool == true
            if applyMatches, !session.mcpCanEditProjectMedia {
                throw MCPCommandError("editor_busy", "Finish the current project operation before relinking media.")
            }
            let checking = session.mcpMediaCheckingVolumes
            let receipt = try mcpAnalysisJobs.reserve(session: session, kind: "media_locate")
            let endWork = receipt.cleanup.begin()
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let candidates = try ProjectMediaVolume.$checking.withValue(checking) {
                    try ProjectMedia.locate(project: archive.project, undo: archive.undo, redo: archive.redo,
                                            snapshot: archive.snapshot, relativeTo: archive.documentURL,
                                            folder: folder, includeHistory: includeHistory)
                }
                try Task.checkCancellation()
                return (candidates, try MCPSchemas.encodeResult(candidates))
            }
            receipt.cancelNative = { worker.cancel() }
            Task { @MainActor in
                defer { endWork() }
                do {
                    let (candidates, data) = try await worker.value
                    guard !receipt.cancellationRequested else { throw CancellationError() }
                    try checkRevision()
                    receipt.mediaLocateRows = candidates
                    var detail: [String: Any] = ["candidates": try JSONSerialization.jsonObject(with: data)]
                    if applyMatches {
                        guard session.mcpCanEditProjectMedia else {
                            throw MCPCommandError("editor_busy", "Finish the current project operation before relinking media.")
                        }
                        let mappings = candidates.compactMap(\.eligibleMapping)
                        if mappings.isEmpty {
                            detail["changed"] = false
                            detail["applied"] = [String]()
                            detail["failures"] = [String: String]()
                        } else {
                            let result = try await session.mcpRelinkMedia(mappings) {
                                guard !receipt.cancellationRequested else { throw CancellationError() }
                                try checkRevision()
                            }
                            detail["changed"] = result.changed
                            detail["applied"] = result.applied
                            detail["failures"] = result.failures
                        }
                        detail["revision"] = session.mcpRevision
                        detail["history_retained"] = false
                    }
                    receipt.finish("succeeded", detail: detail)
                } catch {
                    if receipt.cancellationRequested || error is CancellationError {
                        receipt.finish("cancelled")
                    } else {
                        receipt.finish("failed", detail: ["error": error.localizedDescription])
                    }
                }
            }
            return receipt.snapshot

        case "project_editor_media_leave_offline", "project_editor_media_revert":
            guard session.mcpCanEditProjectMedia else {
                throw MCPCommandError("editor_busy", "Finish the current project operation before changing media.")
            }
            let source = try text("source")
            try checkRevision()
            let changed: Bool
            if tool == "project_editor_media_revert" {
                if session.isMulticam {
                    changed = try await session.multicam.revertProjectMedia(source, validateCommit: checkRevision)
                } else {
                    changed = try await session.editor.revertProjectMedia(source, validateCommit: checkRevision)
                }
            } else if session.isMulticam {
                try session.multicam.ignoreProjectMedia(source)
                changed = session.mcpRevision != revision
            } else {
                try session.editor.ignoreProjectMedia(source)
                changed = session.mcpRevision != revision
            }
            return ["changed": changed, "history_retained": false]

        case "project_editor_media_relink", "still_editor_asset_relink":
            guard session.mcpCanEditProjectMedia else {
                throw MCPCommandError("editor_busy", "Finish the current project operation before relinking media.")
            }
            var mappings: [ProjectMediaMapping]
            var aliasAsset: String?
            if tool == "still_editor_asset_relink" {
                let asset = try text("asset")
                guard let still = archive.project.stillAssets.first(where: { $0.id == asset && !$0.isGap }) else {
                    throw MCPCommandError("invalid_target", "Read the current still placements and choose a linked asset ID.")
                }
                aliasAsset = asset
                mappings = [.init(from: still.file, to: try path("path"))]
            } else if let entries = arguments["mappings"] as? [[String: Any]] {
                mappings = try entries.map {
                    let row = MCPFileRequest.Fields(values: $0)
                    guard let from = try row.string("from"), let to = try row.path("to") else {
                        throw input.invalid("Supply a from and to path for each mapping.")
                    }
                    return .init(from: from, to: URL(fileURLWithPath: to, isDirectory: false))
                }
            } else if arguments["from_prefix"] != nil {
                let from = try path("from_prefix", directory: true)
                let to = try path("to_prefix", directory: true)
                let checking = session.mcpMediaCheckingVolumes
                mappings = await Task.detached(priority: .userInitiated) {
                    ProjectMediaVolume.$checking.withValue(checking) {
                        ProjectMedia.prefixMappings(project: archive.project, undo: archive.undo, redo: archive.redo,
                                                    relativeTo: archive.documentURL, from: from, to: to)
                    }
                }.value
            } else {
                mappings = [.init(from: try text("from"), to: try path("to"))]
            }
            guard !mappings.isEmpty else {
                throw MCPCommandError("media_mapping_empty", "No project media paths match the requested prefix.")
            }
            try checkRevision()
            if let id = arguments["locate_job_id"] as? String {
                let receipt = try mcpAnalysisJobs.lookup(id, session: session)
                guard receipt.kind == "media_locate", receipt.state == "succeeded",
                      receipt.revision == revision, let rows = receipt.mediaLocateRows else {
                    throw MCPCommandError("invalid_media_receipt", "Use a successful locate receipt from the current project revision.")
                }
                let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0) })
                mappings = try mappings.map { mapping in
                    guard let candidate = byPath[mapping.from]?.candidates.first(where: {
                        $0.url.path == mapping.to.path && $0.outcome.canRelink
                    }) else {
                        throw MCPCommandError("invalid_media_candidate", "Select an eligible path pair from the locate receipt.")
                    }
                    return .init(from: mapping.from, candidate: candidate)
                }
            }
            let result = try await session.mcpRelinkMedia(mappings, checkAccess: checkRevision)
            var response: [String: Any] = ["changed": result.changed, "applied": result.applied,
                                            "failures": result.failures, "history_retained": false]
            if result.changed { response["action"] = "Relink Source" }
            if let aliasAsset {
                if let failure = result.failures.values.first {
                    throw MCPCommandError("media_relink_failed", failure)
                }
                response["asset"] = aliasAsset
            }
            return response

        default:
            let source = try text("source")
            let candidate = try path("with")
            let confirm = arguments["confirm"] as? Bool == true
            let conform = (arguments["conform"] as? String).flatMap(MediaReplaceConform.init(rawValue:)) ?? .trim
            let explicitLoss = (arguments["loss"] as? String).flatMap(MediaReplaceLoss.init(rawValue:))
            let loss = explicitLoss ?? (arguments["allow_loss"] as? Bool == true
                ? (conform == .trim ? .remove : .keepOffline) : nil)
            let clock = (arguments["clock"] as? String).flatMap(MediaReplaceClock.init(rawValue:)) ?? .sourceRelative
            let transcript = (arguments["transcript"] as? String).flatMap(MediaReplaceTranscript.init(rawValue:)) ?? .keepUnverified
            let resync = (arguments["resync"] as? String).flatMap(MediaReplaceSync.init(rawValue:))
            let replacementOffset = try input.string("replacement_offset").map { try RationalTime(parsing: $0) }
            var streams: [Int: Int] = [:]
            for row in arguments["stream_mapping"] as? [[String: Any]] ?? [] {
                guard let from = row["from"] as? Int, let to = row["to"] as? Int,
                      streams.updateValue(to, forKey: from) == nil else {
                    throw input.invalid("Map each old audio stream at most once.")
                }
            }
            let options = MediaReplaceOptions(useID: try input.string("use_id"), conform: conform, loss: loss,
                                              clock: clock, streamMapping: streams,
                                              resetCrop: arguments["reset_crop"] as? Bool == true,
                                              replacementOffset: replacementOffset,
                                              sharedTimeOfDay: arguments["shared_time_of_day"] as? Bool == true,
                                              transcript: transcript, resync: resync)
            let checking = session.mcpMediaCheckingVolumes
            let reviewFields = arguments.filter {
                !["project_handle", "expected_revision", "operation_id", "confirm", "preview_id"].contains($0.key)
            }
            let reviewRequest = try JSONSerialization.data(withJSONObject: reviewFields, options: .sortedKeys)
            let preview: MediaReplacePreview
            if let previewID = arguments["preview_id"] as? String {
                guard confirm, let reviewed = session.mcpMediaPreview, reviewed.id == previewID,
                      reviewed.owner == session.mcpHandle, reviewed.revision == revision,
                      reviewed.request == reviewRequest else {
                    throw MCPCommandError("stale_media_preview", "Review this replacement again before applying.")
                }
                preview = reviewed.replacement
            } else {
                let prepare = Task.detached(priority: .userInitiated) {
                    try ProjectMediaVolume.$checking.withValue(checking) {
                        let origin = ProjectMediaVolume.watchURL(source, relativeTo: archive.documentURL)
                        guard !ProjectMediaVolume.isChecking(origin), !ProjectMediaVolume.isChecking(candidate) else {
                            throw MCPCommandError("media_checking", "Wait for the source and replacement volumes to respond.")
                        }
                        return try ProjectMediaReplace.preview(archive.project, snapshot: archive.snapshot,
                                                               relativeTo: archive.documentURL, source: source,
                                                               candidate: candidate, options: options)
                    }
                }
                preview = try await withTaskCancellationHandler {
                    try await prepare.value
                } onCancel: {
                    prepare.cancel()
                }
            }
            try checkRevision()
            let report = try mediaJSON(preview.report)
            if !confirm {
                let reviewed = MCPProjectMediaPreview(owner: session.mcpHandle, revision: revision,
                                                      request: reviewRequest, replacement: preview)
                session.mcpMediaPreview = reviewed
                return ["report": report, "preview_id": reviewed.id, "changed": false]
            }
            guard preview.report.canApply else { return ["report": report, "changed": false] }
            guard session.mcpCanEditProjectMedia else {
                throw MCPCommandError("editor_busy", "Finish the current project operation before replacing media.")
            }
            let changed: Bool
            if session.isMulticam {
                changed = try await session.multicam.applyProjectMediaReplacement(preview, validateCommit: checkRevision)
            } else {
                changed = try await session.editor.applyProjectMediaReplacement(preview, validateCommit: checkRevision)
            }
            if changed { session.mcpMediaPreview = nil }
            return ["report": report, "changed": changed,
                    "history_retained": changed && preferences.historyLimit > 0]
        }
    }
}

private func mediaJSON(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: MCPSchemas.encodeResult(value))
}
