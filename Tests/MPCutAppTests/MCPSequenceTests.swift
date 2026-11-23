import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPSequenceTests: XCTestCase {
    func testIntegerArgumentsPreserveWirePrecision() throws {
        let value = 9_007_199_254_740_993
        XCTAssertEqual(try SequenceInput(fields: ["value": value]).integer("value"), value)
    }

    func testSplitTargetsRepeatedOccurrenceAndSharesNativeHistory() async throws {
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let session = sessions.session(for: nil)
        let editor = session.editor
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([url, url])
        try await waitUntilReady(editor)
        let clips = editor.mcpClipIDs
        XCTAssertEqual(clips.count, 2)
        let originalRevision = editor.mcpRevision
        let firstDuration = editor.sequenceClips[0].to
        let sourceTime = try RationalTime(parsing: "1001/30000")
        let request: [String: Any] = ["occurrence": clips[1].uuidString, "space": "source", "time": sourceTime.description]
        let result = try await sessions.handleMCPCommand(tool: "timeline_item_split", arguments: request, session: session, checkAccess: {})
        XCTAssertEqual(result["source_time"] as? String, sourceTime.description)
        XCTAssertEqual(result["sequence_time"] as? String, try firstDuration.adding(sourceTime).description)
        XCTAssertEqual(editor.mcpClipIDs.prefix(2), clips[...])
        XCTAssertEqual(editor.sequenceClips.count, 3)
        XCTAssertGreaterThan(editor.mcpRevision, originalRevision)
        XCTAssertEqual(editor.undoTitle, "Undo Split Clip")
        editor.undo()
        XCTAssertEqual(editor.mcpClipIDs, clips)
        let redo = try await editor.mcpCommand(tool: "history_redo", arguments: [:], validateCommit: {})
        XCTAssertEqual(redo?["origins"] as? [String], ["user", "agent"])
        XCTAssertEqual(redo?["cursor"] as? Int, editor.historyCursor)
        XCTAssertEqual(editor.sequenceClips.count, 3)
    }

    func testRevocationRejectsSplitAndNavigationPreservesRevision() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([url])
        try await waitUntilReady(editor)
        let id = try XCTUnwrap(editor.mcpClipIDs.first)
        let request: [String: Any] = ["occurrence": id.uuidString, "space": "sequence", "time": "1001/30000"]
        let revision = editor.mcpRevision
        var checks = 0
        do {
            _ = try await editor.mcpCommand(tool: "timeline_item_split", arguments: request) {
                checks += 1
                if checks == 2 { throw MCPFailure(code: "disabled", message: "Local control disabled.") }
            }
            XCTFail("Edit should be rejected before the native commit")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "disabled")
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(editor.mcpClipIDs, [id])
        XCTAssertEqual(editor.mcpRevision, revision)
        _ = try await editor.mcpCommand(tool: "timeline_playhead_seek", arguments: request, validateCommit: {})
        XCTAssertEqual(editor.mcpRevision, revision)
    }

    func testTrimPreviewCanBeCancelledOrCommittedWithNativeHistory() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([url])
        try await waitUntilReady(editor)
        let id = try XCTUnwrap(editor.mcpClipIDs.first)
        let request: [String: Any] = ["action": "preview_trim", "occurrence": id.uuidString, "edge": "start", "time": "1001/30000"]
        let actions = editor.historyActions
        let preview = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: request, validateCommit: {})
        let token = try XCTUnwrap(preview?["trim_preview"] as? String)
        XCTAssertEqual(editor.historyActions, actions)
        var wrongEdge = request
        wrongEdge["action"] = "trim"
        wrongEdge["edge"] = "end"
        wrongEdge["trim_preview"] = token
        do {
            _ = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: wrongEdge, validateCommit: {})
            XCTFail("The receipt should only authorize the previewed edge")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "invalid_argument")
        }
        XCTAssertEqual(editor.mcpTrimPreview?.uuidString, token)
        XCTAssertEqual(editor.historyActions, actions)
        let cancel: [String: Any] = ["action": "cancel_trim", "trim_preview": token]
        _ = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: cancel, validateCommit: {})
        XCTAssertNil(editor.mcpTrimPreview)
        XCTAssertEqual(editor.sequenceClips[0].from, .zero)
        let second = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: request, validateCommit: {})
        let secondToken = try XCTUnwrap(second?["trim_preview"] as? String)
        var commit = request
        commit["action"] = "trim"
        commit["trim_preview"] = secondToken
        _ = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: commit, validateCommit: {})
        XCTAssertEqual(editor.sequenceClips[0].from.description, "1001/30000")
        XCTAssertEqual(editor.historyActions, actions + ["Trim Clip"])
    }

    func testRevokedHistoryRestorePreservesTheTimelineAndOriginalError() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        let past = CutSequenceClip(id: "past", file: source.path, from: .zero, to: try RationalTime(parsing: "1/10"))
        try editor.openProject([], at: project,
                               history: (undo: [.init(action: "Delete Clip", project: .sequence([past]))], redo: []))
        let revision = editor.mcpRevision
        var checks = 0
        do {
            _ = try await editor.mcpCommand(tool: "history_undo", arguments: [:]) {
                checks += 1
                if checks == 2 { throw MCPFailure(code: "control_disabled", message: "Local control stopped.") }
            }
            XCTFail("The restored source must only install when access is current")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "control_disabled")
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(editor.historyCursor, 1)
        XCTAssertEqual(editor.mcpRevision, revision)
        XCTAssertTrue(editor.isEmpty)
        XCTAssertFalse(editor.isImporting)
        XCTAssertNil(editor.alert)

        let result = try await editor.mcpCommand(tool: "history_undo", arguments: [:], validateCommit: {})
        XCTAssertEqual(result?["cursor"] as? Int, 0)
        XCTAssertEqual(result?["revision"] as? Int, revision + 1)
        XCTAssertEqual(editor.sequenceClips, [past])
    }

    func testCSVImportRevalidatesBeforeEditingOneRepeatedOccurrence() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([source, source])
        try await waitUntilReady(editor)
        let clips = editor.sequenceClips
        let occurrences = editor.mcpClipIDs
        let csv = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: csv) }
        try "1001/30000,1001/15000\n".write(to: csv, atomically: true, encoding: .utf8)
        let request: [String: Any] = ["action": "apply_csv", "occurrence": occurrences[1].uuidString, "path": csv.path]
        let revision = editor.mcpRevision
        var checks = 0
        do {
            _ = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: request) {
                checks += 1
                if checks == 2 { throw MCPFailure(code: "stale_revision", message: "The sequence changed.") }
            }
            XCTFail("CSV must revalidate immediately before commit")
        } catch let failure as MCPFailure {
            XCTAssertEqual(failure.code, "stale_revision")
        }
        XCTAssertEqual(editor.sequenceClips, clips)
        XCTAssertEqual(editor.mcpRevision, revision)
        XCTAssertNil(editor.alert)

        let result = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: request, validateCommit: {})
        XCTAssertEqual(result?["changed"] as? Bool, true)
        XCTAssertEqual(result?["revision"] as? Int, revision + 1)
        XCTAssertEqual(editor.mcpClipIDs, occurrences)
        XCTAssertEqual(editor.sequenceClips[0], clips[0])
        XCTAssertEqual(editor.sequenceClips[1].from.description, "1001/30000")
        XCTAssertEqual(editor.sequenceClips[1].to.description, "1001/15000")
        try "0,1001/30000\n".write(to: csv, atomically: true, encoding: .utf8)
        let unchanged = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: request, validateCommit: {})
        XCTAssertEqual(unchanged?["changed"] as? Bool, false)
        XCTAssertEqual(unchanged?["revision"] as? Int, revision + 1)
        editor.undo()
        XCTAssertEqual(editor.sequenceClips, clips)
    }

    func testDeleteClipUsesExplicitOccurrenceAndPreservesUndoSelection() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([source, source])
        try await waitUntilReady(editor)
        let occurrences = editor.mcpClipIDs
        editor.select(occurrences[0])
        editor.rangeTool = true
        editor.selectRange(0, try RationalTime(parsing: "1001/30000").seconds)
        let priorMarkOut = try XCTUnwrap(editor.markOut)

        let request: [String: Any] = ["action": "delete_clip", "occurrence": occurrences[1].uuidString]
        _ = try await editor.mcpCommand(tool: "sequence_clip_edit", arguments: request, validateCommit: {})
        XCTAssertEqual(editor.mcpClipIDs, [occurrences[0]])
        XCTAssertTrue(editor.rangeTool)
        XCTAssertNil(editor.markOut)
        editor.undo()
        XCTAssertEqual(editor.mcpClipIDs, occurrences)
        XCTAssertEqual(editor.selectedID, occurrences[0])
        XCTAssertEqual(editor.markIn, 0)
        XCTAssertEqual(editor.markOut, priorMarkOut)
    }

    func testSplitRejectsAnUnrepresentableSnappedBoundary() async throws {
        let preferences = EditorPreferences()
        preferences.snapTarget = .off
        preferences.useAnalysisSidecars = false
        let editor = EditorModel(preferences: preferences)
        defer { editor.endSession() }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        let start = try RationalTime(parsing: "1/400000000000000001")
        let end = try RationalTime(parsing: "100000000000000000/400000000000000001")
        let clip = CutSequenceClip(id: "precise", file: source.path, from: start, to: end)
        try editor.openProject([clip], at: project)
        try await waitUntilReady(editor)
        let occurrence = try XCTUnwrap(editor.mcpClipIDs.first)
        let revision = editor.mcpRevision
        do {
            _ = try await editor.mcpCommand(tool: "timeline_item_split", arguments:
                ["occurrence": occurrence.uuidString, "space": "source", "time": "1001/30000"], validateCommit: {})
            XCTFail("The split offset exceeds the supported rational range")
        } catch let failure as CutError {
            XCTAssertEqual(failure.code, "time_overflow")
        }
        XCTAssertEqual(editor.mcpRevision, revision)
        XCTAssertEqual(editor.sequenceClips, [clip])
        XCTAssertNil(editor.alert)
    }

    private func waitUntilReady(_ editor: EditorModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while editor.isBusy {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(editor.alert)
    }
}
