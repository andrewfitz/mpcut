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
        if let result = try await mcpSourceRanges(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await session.mcpTimelineReview(tool: tool, arguments: arguments, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpTranscript(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
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
