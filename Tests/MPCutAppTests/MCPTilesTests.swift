import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPTilesTests: XCTestCase {
    func testCountHintAcceptSchemasRequireAnEdit() throws {
        let schemas = try MCPSchemas.loaded.get()
        let editor: [String: Any] = ["project_handle": "window", "expected_revision": 1]
        let file: [String: Any] = ["operation_id": UUID().uuidString, "project_path": "/tmp/example.cut", "in_place": true]
        for (tool, base) in [("tiles_editor_accept", editor), ("tiles_file_accept", file)] {
            XCTAssertThrowsError(try schemas.validate(tool: tool, arguments: base))
            XCTAssertNoThrow(try schemas.validate(tool: tool, arguments: base.merging(
                ["expected_feeds": 2, "max_visible_tiles": 3]) { _, new in new }))
            XCTAssertNoThrow(try schemas.validate(tool: tool, arguments: base.merging(
                ["clear_count_hints": true]) { _, new in new }))
            XCTAssertNoThrow(try schemas.validate(tool: tool, arguments: base.merging(
                ["analysis_file": "/tmp/scan.json", "clear_count_hints": true]) { _, new in new }))
            XCTAssertThrowsError(try schemas.validate(tool: tool, arguments: base.merging(
                ["clear_count_hints": true, "expected_feeds": 2]) { _, new in new }))
        }
    }

    func testLiveTilesReadAndEditShareRevisionAndUndo() async throws {
        try await withSequence { sessions, session in
            try await checkReadAndEdit(in: sessions, session)
        }
    }

    func testCreateFeedBeforeDrawingABox() async throws {
        try await withSequence { sessions, session in
            let original = session.participantProject
            let start = session.mcpRevision
            let cursor = session.editor.historyCursor
            let result = try await sessions.handleMCPCommand(tool: "tiles_editor_feeds_add", arguments: [
                "expected_revision": start, "name": "Guest"
            ], session: session, checkAccess: {})
            let feedID = try XCTUnwrap(result["feed_id"] as? String)
            XCTAssertEqual(session.participantProject.people.first { $0.id == feedID }?.name, "Guest")
            XCTAssertEqual(session.editor.historyCursor, cursor + 1)
            do {
                _ = try await sessions.handleMCPCommand(tool: "tiles_editor_feeds_add", arguments: [
                    "expected_revision": start
                ], session: session, checkAccess: {})
                XCTFail("A stale retry must not create a second feed.")
            } catch let error as MCPCommandError {
                XCTAssertEqual(error.code, "stale_revision")
            }
            session.editor.undo()
            XCTAssertEqual(session.participantProject, original)
        }
    }

    func testScanResumeAndSwitchScopeMatchDiscovery() throws {
        let schemas = try MCPSchemas.loaded.get()
        let target: [String: Any] = ["project_handle": "window"]
        XCTAssertNoThrow(try schemas.validate(tool: "tiles_editor_scan", arguments: target.merging(
            ["resume": true]) { _, new in new }))
        XCTAssertThrowsError(try schemas.validate(tool: "tiles_editor_switches_propose", arguments: target.merging(
            ["source_id": "unused"]) { _, new in new }))
    }

    func testMergingFeedsUpdatesSequenceLayoutAndAssignmentsInOneEdit() async throws {
        try await withSequence { sessions, session in
            let clip = try XCTUnwrap(session.editor.sequenceClips.first)
            let sourceURL = URL(fileURLWithPath: clip.file)
            let projectURL = sourceURL.deletingLastPathComponent().appendingPathComponent("Test.cut")
            var project = session.editor.transcriptProject
            project.participants.people = [.init(id: "old-feed", name: "Old Feed"), .init(id: "keep-feed", name: "Keep Feed")]
            let range = MulticamRange(from: clip.from, to: clip.to)
            try project.addTileBox(sourceID: clip.file, document: projectURL, appearance: .init(
                id: "tile", participantID: "old-feed", range: range,
                bounds: .init(x: 0, y: 0, width: 1, height: 1)))
            let layout = TileLayoutSpan(range: range, layout: .solo, slots: [.init(id: "old-feed")])
            project = try project.settingTileLayout(scope: .clip(clip.id), range: range, layout: layout)
            try session.editor.applyStillProject(project, action: "Set Up Tile Layout", installsParticipants: true)

            let cursor = session.editor.historyCursor
            let response = try await sessions.handleMCPCommand(tool: "tiles_editor_feeds_merge", arguments: [
                "expected_revision": session.mcpRevision, "feed_id": "old-feed", "into_feed_id": "keep-feed",
            ], session: session, checkAccess: {})

            XCTAssertEqual(response["operation_count"] as? Int, 1)
            XCTAssertEqual(session.editor.historyCursor, cursor + 1)
            XCTAssertEqual(session.participantProject.people.map(\.id), ["keep-feed"])
            XCTAssertEqual(session.participantProject.sources.first?.appearances.first?.participantID, "keep-feed")
            XCTAssertEqual(session.editor.sequenceClips.first?.tileLayouts.first?.slots.first?.id, "keep-feed")
            session.editor.undo()
            XCTAssertEqual(session.editor.historyCursor, cursor)
            XCTAssertEqual(session.participantProject, project.participants)
            XCTAssertEqual(session.editor.sequenceClips.first?.tileLayouts, [layout])
        }
    }

    func testBlockedSavedISOPlanMustMatchCurrentEditorRevision() async throws {
        try await withSequence { sessions, session in
            let clip = try XCTUnwrap(session.editor.sequenceClips.first)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            var project = session.editor.transcriptProject
            project.participants.people = [.init(id: "feed", name: "Feed")]
            let range = MulticamRange(from: clip.from, to: clip.to)
            try project.addTileBox(sourceID: clip.file, document: directory.appendingPathComponent("Test.cut"),
                                   appearance: .init(id: "tile", participantID: "feed", range: range,
                                                     bounds: .init(x: 0, y: 0, width: 1, height: 1)))
            try session.commitParticipants(project.participants, action: "Add Tiles")

            func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
                try await sessions.handleMCPCommand(tool: tool, arguments: arguments, session: session, checkAccess: {})
            }
            func status(plan: URL, output: URL) async throws -> [String: Any] {
                let receipt = try await call("tiles_editor_angles_render", ["plan": plan.path, "output": output.path])
                let id = try XCTUnwrap(receipt["job_id"] as? String)
                let deadline = ContinuousClock.now + .seconds(15)
                while .now < deadline {
                    let job = try await call("analysis_job_status_read", ["job_id": id])
                    if job["status"] as? String != "running" { return job }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw CancellationError()
            }

            let plan = directory.appendingPathComponent("Blocked.json")
            let output = directory.appendingPathComponent("Delivery")
            let cursor = session.editor.historyCursor
            let accepted = try await call("tiles_editor_accept", ["expected_revision": session.mcpRevision, "expected_feeds": 2,
                                                                  "max_visible_tiles": 1])
            let inspected = try await call("tiles_editor_inspect", ["issues": true])
            let issues = try XCTUnwrap(inspected["issues"] as? [[String: Any]])
            XCTAssertFalse(issues.isEmpty)
            XCTAssertEqual(accepted["review_issue_count"] as? Int, issues.count)
            XCTAssertEqual(session.editor.historyCursor, cursor + 1)
            let blocked = try await call("tiles_editor_angles_plan", ["output": plan.path, "no_meeting_mix": true])
            XCTAssertEqual(blocked["requires_review"] as? Bool, true)
            let fresh = try await status(plan: plan, output: output)
            XCTAssertEqual(fresh["status"] as? String, "needs_review", String(describing: fresh))

            _ = try await call("tiles_editor_accept", ["expected_revision": session.mcpRevision, "expected_feeds": 1])
            XCTAssertEqual(session.participantProject.sources.first?.countHints?.maxVisibleTiles, 1)
            let stale = try await status(plan: plan, output: output)
            XCTAssertEqual(stale["status"] as? String, "failed", String(describing: stale))
            XCTAssertEqual(stale["code"] as? String, "stale_iso_plan")
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            let corrected = try await call("tiles_editor_angles_plan", ["no_meeting_mix": true])
            XCTAssertEqual(corrected["requires_review"] as? Bool, false)

            _ = try await call("tiles_editor_accept", ["expected_revision": session.mcpRevision, "clear_count_hints": true])
            XCTAssertNil(session.participantProject.sources.first?.countHints)
            session.editor.undo()
            XCTAssertEqual(session.participantProject.sources.first?.countHints?.expectedFeeds, 1)
            XCTAssertEqual(session.participantProject.sources.first?.appearances, project.participants.sources.first?.appearances)
        }
    }

    private func withSequence(_ body: (ProjectSessions, ProjectSession) async throws -> Void) async throws {
        let suite = "mpcut-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        session.editor.importFiles([fixture])
        let deadline = ContinuousClock.now + .seconds(15)
        while session.editor.isBusy {
            guard .now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await body(sessions, session)
    }

    private func checkReadAndEdit(in sessions: ProjectSessions, _ session: ProjectSession) async throws {
        let start = session.mcpRevision
        let cursor = session.editor.historyCursor
        let box: [String: Any] = ["tile_id": "manual", "from": "0", "to": "1/100", "bounds": "0,0,1,1"]
        func invoke(_ operation: String, _ fields: [String: Any]) async throws -> [String: Any] {
            try await sessions.handleMCPCommand(tool: "tiles_editor_" + operation,
                                                 arguments: fields, session: session, checkAccess: {})
        }

        do {
            _ = try await invoke("box_add", box)
            XCTFail("A tile edit requires the revision the caller reviewed.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_arguments")
        }

        let edit = box.merging(["expected_revision": start]) { _, new in new }
        let created = try await invoke("box_add", edit)
        XCTAssertEqual(created["operation_count"] as? Int, 1)
        XCTAssertEqual(created["tile_id"] as? String, "manual")
        XCTAssertEqual(session.editor.historyCursor, cursor + 1)
        let revision = session.mcpRevision
        XCTAssertGreaterThan(revision, start)

        let reviewed = try await invoke("inspect", ["at": "0"])
        XCTAssertEqual(reviewed["visible_tiles"] as? Int, 1)
        XCTAssertEqual(reviewed["revision"] as? Int, revision)
        XCTAssertEqual(session.editor.historyCursor, cursor + 1)
        XCTAssertEqual(session.mcpRevision, revision)
        do {
            _ = try await invoke("inspect", ["at": "-1"])
            XCTFail("Tile times use the nonnegative recording clock.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_arguments")
        }

        do {
            _ = try await invoke("box_set", edit)
            XCTFail("The project revision changed after the caller read it.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "stale_revision")
        }

        let request = box.merging(["expected_revision": revision, "bounds": "0,0,0.5,0.5"]) { _, new in new }
        var accessChecks = 0
        do {
            _ = try await sessions.handleMCPCommand(tool: "tiles_editor_box_set", arguments: request,
                                                    session: session) {
                accessChecks += 1
                if accessChecks == 2 { session.editor.undo() }
            }
            XCTFail("An undo during preparation must prevent the stale edit from reaching the editor.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "stale_revision")
        }
        XCTAssertEqual(accessChecks, 2)
        XCTAssertTrue(session.participantProject.sources.isEmpty)
        XCTAssertEqual(session.editor.historyCursor, cursor)
        XCTAssertGreaterThan(session.mcpRevision, revision)
    }
}
