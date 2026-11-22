import Foundation

extension ProjectSessions {
    /// The bridge has already resolved the handle against the open document registry.
    /// Commands that prepare work asynchronously call checkAccess again before committing.
    func handleMCPCommand(tool: String, arguments: [String: Any], session: ProjectSession?,
                          checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
        try checkAccess()
        if let result = try await mcpLifecycle(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if let result = try await mcpFile(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        guard let session else {
            throw MCPCommandError("project_required", "Supply the project handle returned by list_projects.")
        }
        if let result = try await mcpStills(tool: tool, arguments: arguments, session: session, checkAccess: checkAccess) {
            return result
        }
        if tool == "split_at", let result = try session.mcpSplitInlineStill(arguments: arguments, checkAccess: checkAccess) {
            return result
        }
        if tool == "review_frame" {
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
