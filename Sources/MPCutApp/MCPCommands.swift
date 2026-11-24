import Foundation
import MPCutCore

extension ProjectSessions {
    /// The bridge has already resolved the handle against the open document registry.
    /// Commands that prepare work asynchronously call checkAccess again before committing.
    func handleMCPCommand(tool: String, arguments: [String: Any], session: ProjectSession?,
                          checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        try await HistoryOrigin.$current.withValue(.agent) {
            try await dispatchMCPCommand(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess)
        }
    }

    private func dispatchMCPCommand(tool: String, arguments: [String: Any], session: ProjectSession?,
                                    checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        try checkAccess()
        if let result = try await mcpLifecycle(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpFile(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        guard let session else {
            throw MCPCommandError("project_required", "Supply the project handle returned by project_windows_list.")
        }
        if let result = try await mcpTiles(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpSourceRanges(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await session.mcpTimelineReview(tool: tool, arguments: arguments, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpTranscript(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpProjectMedia(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpStills(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if tool == "timeline_item_split", let result = try session.mcpSplitInlineStill(arguments: arguments, checkAccess: checkAccess) {
            return result
        }
        if tool == "review_editor_frame_read" {
            return try await mcpReviewFrame(arguments: arguments, session: session, checkAccess: checkAccess)
        }
        if let result = try await mcpAnalysis(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        try checkAccess()
        if let result = try await mcpOutputs(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpPresentation(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        try checkAccess()
        if let result = try await session.mcpFeedAngleHistory(tool: tool, arguments: arguments, checkAccess: checkAccess) {
            return result
        }
        let result: [String: Any]?
        if session.isMulticam {
            result = try await session.multicam.mcpCommand(tool: tool, arguments: arguments, validateCommit: checkAccess)
        } else {
            result = try await session.editor.mcpCommand(tool: tool, arguments: arguments, validateCommit: checkAccess)
        }
        guard let result else {
            throw MCPCommandError("unsupported_tool", "This editor does not support \(tool).")
        }
        return result
    }
}

extension ProjectSession {
    fileprivate func mcpFeedAngleHistory(tool: String, arguments: [String: Any],
                                         checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard hasFeedAngleConversionHistory, ["history_read", "history_undo", "history_redo", "history_state_restore"].contains(tool) else {
            return nil
        }
        if tool != "history_read" {
            guard window?.attachedSheet == nil, isMulticam
                ? (!multicam.isBusy && multicam.notice == nil)
                : (!editor.isBusy && editor.alert == nil && !editor.mcpHasActiveTrim) else {
                throw MCPCommandError("editor_busy", "Finish the current edit or close the dialog.")
            }
            let index: Int
            switch tool {
            case "history_undo": index = conversionHistoryCursor - 1
            case "history_redo": index = conversionHistoryCursor + 1
            default:
                guard arguments["history_token"] as? String == conversionHistoryToken else {
                    throw MCPCommandError("stale_history", "Read the retained history again.")
                }
                guard let requested = arguments["index"].flatMap(mcpInteger) else {
                    throw MCPCommandError("invalid_arguments", "Supply a retained history index.")
                }
                index = requested
            }
            guard (0...conversionHistoryActions.count).contains(index) else {
                throw MCPCommandError("invalid_arguments", "The requested history state is unavailable.")
            }
            try checkAccess()
            let boundary = feedAngleSequenceBoundary ?? editor.historyCursor
            let startedInMulticam = isMulticam
            if startedInMulticam, index <= boundary {
                restoreConversionHistory(boundary)
                guard !isMulticam else {
                    throw MCPCommandError("editor_busy", "The sequence history is unavailable.")
                }
            }
            if !isMulticam {
                let destination = min(index, boundary)
                let revision = mcpRevision
                let handle = mcpHandle
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    editor.moveToHistoryState(destination, beforeRestore: {
                        try Task.checkCancellation()
                        if !startedInMulticam { try checkAccess() }
                        guard self.mcpHandle == handle, self.mcpRevision == revision else {
                            throw MCPCommandError("stale_revision", "Read the retained history again.")
                        }
                    }, completion: { continuation.resume(with: $0) })
                }
            }
            if index > boundary { restoreConversionHistory(index) }
        }
        let history = conversionHistoryActions
        return ["actions": history.map(\.name), "origins": history.map(\.origin.rawValue),
                "cursor": conversionHistoryCursor, "history_token": hasFeedAngleConversionHistory
                    ? conversionHistoryToken : (isMulticam ? multicam.historyToken : editor.historyToken),
                "limit": editor.mcpHistoryLimit, "revision": mcpRevision]
    }
}
