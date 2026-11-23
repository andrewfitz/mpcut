import Foundation
import MPCutCore

extension ProjectSession {
    var currentTimeline: CutProject? {
        if isMulticam { return multicam.project.map(CutProject.multicam) }
        return editor.transcriptProject
    }

    func retainedTimeline(at index: Int) -> CutProject? {
        isMulticam ? multicam.retainedTimeline(at: index) : editor.retainedTimeline(at: index)
    }

    private var timelineHistoryToken: String {
        if isMulticam { return multicam.historyToken }
        return editor.historyToken
    }

    func mcpTimelineReview(tool: String, arguments: [String: Any], checkAccess: @escaping @MainActor () throws -> Void)
        async throws -> [String: Any]? {
        guard tool == "timeline_editor_range_map" || tool == "history_editor_compare" else { return nil }
        try checkAccess()
        guard let current = currentTimeline else {
            throw MCPCommandError("project_required", "Open a timeline first.")
        }
        let revision = mcpRevision
        let historyIndex = arguments["history_index"].flatMap(mcpInteger)
        let historyToken = arguments["history_token"] as? String
        let comparing = tool == "history_editor_compare"
        guard (historyIndex == nil) == (historyToken == nil), !comparing || historyIndex != nil else {
            throw MCPCommandError("invalid_arguments", "Supply both history_index and history_token from history_read.")
        }
        func checkHistoryToken() throws {
            if let historyToken, historyToken != timelineHistoryToken {
                throw MCPCommandError("stale_history", "Read history again to identify a retained state.")
            }
        }
        try checkHistoryToken()
        let target: CutProject
        if let historyIndex {
            guard let retained = retainedTimeline(at: historyIndex) else {
                throw MCPCommandError("revision_unavailable", "This history state is beyond retained undo and redo.")
            }
            target = retained
        } else {
            target = current
        }
        let offset = arguments["offset"].flatMap(mcpInteger) ?? 0
        let limit = arguments["limit"].flatMap(mcpInteger) ?? 100
        guard offset >= 0, (1...500).contains(limit) else {
            throw MCPCommandError("invalid_arguments", "Use a nonnegative offset and a limit from 1 through 500.")
        }
        let data: Data
        let key: String
        if comparing {
            key = "comparison"
            data = try await Task.detached {
                let result = try TimelineComparison.compare(from: target, to: current)
                return try MCPSchemas.encodeResult(result.page(offset: offset, limit: limit))
            }.value
        } else {
            key = "mapping"
            guard let space = arguments["space"] as? String, let clock = TimelineClock(rawValue: space),
                  let from = arguments["from"] as? String, let to = arguments["to"] as? String else {
                throw MCPCommandError("invalid_arguments", "Supply a clock and both range endpoints.")
            }
            let file = arguments["file"] as? String
            let index = arguments["occurrence_index"].flatMap(mcpInteger)
            let range = try MulticamRange(from: RationalTime(parsing: from), to: RationalTime(parsing: to))
            data = try await Task.detached {
                // Live source paths use the same normalization as the editor's media loader.
                let sourcePath = try file.map { path in
                    path.hasPrefix("/") ? try CutProject.checkedMediaURL(path, relativeTo: URL(fileURLWithPath: path)).path : path
                }
                let result = try target.mapTimelineRange(range, clock: clock, file: sourcePath, occurrenceIndex: index)
                return try MCPSchemas.encodeResult(result.page(offset: offset, limit: limit))
            }.value
        }
        try checkAccess()
        try checkHistoryToken()
        guard mcpRevision == revision else {
            throw MCPCommandError("stale_revision", "The project changed. Read its current state and retry.")
        }
        var result: [String: Any] = [key: try JSONSerialization.jsonObject(with: data), "revision": revision]
        result["history_index"] = historyIndex
        return result
    }
}
