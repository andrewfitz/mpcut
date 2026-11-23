import Foundation
import MPCutCore

extension ProjectSessions {
    func mcpSourceRanges(tool: String, arguments: [String: Any], session: ProjectSession,
                         checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        switch tool {
        case "source_selects_list", "source_select_save", "source_select_remove", "sequence_source_ranges_apply": break
        default: return nil
        }
        guard !session.isMulticam else {
            throw MCPCommandError("expected_sequence", "Source selects and range plans require a sequence.")
        }
        let editor = session.editor
        let input = SequenceInput(fields: arguments)
        let checkEdit: @MainActor () throws -> Void = {
            try checkAccess()
            guard session.window?.attachedSheet == nil else {
                throw MCPCommandError("editor_busy", "Close the sheet in this project window.")
            }
        }
        if tool == "source_selects_list" { try checkAccess() } else { try checkEdit() }
        switch tool {
        case "source_select_save":
            let row = arguments["range"] as? [String: Any] ?? [:]
            let range = try SequenceSourceRange.request(row, selects: [])
            let select = try NamedSourceSelect(id: input.string("id"), name: input.string("name"), range: range)
            try await editor.saveSourceSelect(select, expectedRevision: input.integer("expected_revision"), checkAccess: checkEdit)
        case "source_select_remove":
            try editor.removeSourceSelect(input.string("id"), expectedRevision: input.integer("expected_revision"))
        case "sequence_source_ranges_apply":
            let rows = arguments["ranges"] as? [[String: Any]] ?? []
            let ranges = try rows.map { try SequenceSourceRange.request($0, selects: editor.stillProject.sourceSelects) }
            let destination = try MulticamRange(from: input.time("from"), to: input.time("to"))
            try await editor.applySourceRanges(ranges, destination: destination,
                                               expectedRevision: input.integer("expected_revision"), checkAccess: checkEdit)
            return ["revision": editor.mcpRevision, "range_count": ranges.count]
        default: break
        }
        let selects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(editor.stillProject.sourceSelects))
        return ["revision": editor.mcpRevision, "source_selects": selects]
    }
}
