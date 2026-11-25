import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamVoiceAngleMCPTests: XCTestCase {
    func testFileEditSchemaAcceptsRequestAndRowRevisions() throws {
        let schema = try MCPSchemas.loaded.get()
        let arguments: [String: Any] = [
            "operation_id": UUID().uuidString,
            "request": [
                "project_path": "/tmp/group.cut",
                "out_project": "/tmp/edited.cut",
                "project_revision": "reviewed",
                "operations": [
                    ["action": "switch_set", "at": "1", "angle_id": "wide", "project_revision": "reviewed"],
                    ["action": "switch_remove", "at": "2", "project_revision": "reviewed"]
                ]
            ]
        ]
        XCTAssertNoThrow(try schema.validate(tool: "project_file_edit", arguments: arguments))
    }

    @MainActor
    func testLiveVoiceAngleCanBeReadClearedSavedAndUndone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.historyLimit = 4
        let model = MulticamEditorModel(preferences: preferences,
            draft: ProjectDraft(directory: directory.appendingPathComponent("Drafts")))
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: fixture.path), media: media)],
                           opening: "wide", audio: .none)
        let document = TranscriptDocument(clock: .presentation, speakers: [.init(id: "host", name: "Host")])
        let attachment = TranscriptAttachment(id: "dialogue", asset: try TranscriptStore.put(document), bindings: [])
        try model.setTranscriptState(.init(attachments: [attachment]))
        let schema = try MCPSchemas.loaded.get()

        func link(_ action: String, speaker: String = "host", angle: String? = nil) async throws -> [String: Any]? {
            var arguments: [String: Any] = [
                "project_handle": "multicam", "expected_revision": model.mcpRevision,
                "action": action, "attachment_id": attachment.id, "speaker_id": speaker
            ]
            arguments["angle_id"] = angle
            let tool = "multicam_voice_angle_edit"
            return try await model.mcpCommand(tool: tool, arguments: schema.validate(tool: tool, arguments: arguments),
                                              validateCommit: {})
        }

        do {
            _ = try await link("set", speaker: "missing", angle: "wide")
            XCTFail("Linked an unknown speaker")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "invalid_target")
        }
        let assigned = try await link("set", angle: "wide")
        XCTAssertEqual(assigned?["changed"] as? Bool, true)
        let repeated = try await link("set", angle: "wide")
        XCTAssertEqual(repeated?["changed"] as? Bool, false)
        let state = try await model.mcpCommand(tool: "multicam_state_read", arguments: ["section": "voice_angles"],
                                               validateCommit: {})
        XCTAssertEqual(state?["total"] as? Int, 1)
        let rows = state?["voice_angles"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["angle_id"] as? String, "wide")
        let cleared = try await link("clear")
        XCTAssertEqual(cleared?["changed"] as? Bool, true)
        XCTAssertEqual(model.project?.speakerAngles, [])
        model.moveToHistoryState(model.historyCursor - 1)
        let saved = directory.appendingPathComponent("Linked.cut")
        try model.writeProject(to: saved)
        guard case .multicam(let reopened) = try CutProject.load(from: saved) else {
            return XCTFail("Expected a multicam project")
        }
        XCTAssertEqual(reopened.speakerAngles, [.init(voice: .init(attachmentID: attachment.id, speakerID: "host"),
                                                    angleID: "wide")])
    }
}
