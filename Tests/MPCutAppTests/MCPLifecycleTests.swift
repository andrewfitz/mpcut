import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPLifecycleTests: XCTestCase {
    func testLifecycleOpensOnceAndSaveAsPreservesLiveHandle() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Empty.cut"), destination = folder.appendingPathComponent("Copy.cut")
        try CutProject.sequence([]).save(to: source)
        let prefs = EditorPreferences()
        let sessions = ProjectSessions(preferences: prefs, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }

        func call(_ name: String, _ arguments: [String: Any], _ session: ProjectSession? = nil) async throws -> [String: Any] {
            let result = try await sessions.mcpLifecycle(tool: name, arguments: arguments, session: session, checkAccess: {})
            return try XCTUnwrap(result)
        }

        let first = try await call("open_project", ["path": source.path])
        let second = try await call("open_project", ["path": source.path])
        XCTAssertEqual(first["project"] as? String, second["project"] as? String)
        let live = try XCTUnwrap(sessions.project(at: source))
        let saved = try await call("save_project", ["path": destination.path], live)
        XCTAssertEqual(saved["project"] as? String, first["project"] as? String)
        XCTAssertEqual(live.editor.projectURL?.path, destination.path)
        XCTAssertEqual(sessions.sessions.count, 1)

        do {
            _ = try await call("save_project", ["path": source.path], live)
            XCTFail("Save As must require explicit replacement")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "destination_exists") }
        let hardLink = folder.appendingPathComponent("Linked.cut")
        try manager.linkItem(at: destination, to: hardLink)
        do {
            _ = try await call("save_project", ["path": hardLink.path], live)
            XCTFail("A second directory entry still requires explicit replacement")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "destination_exists") }
        XCTAssertEqual(live.editor.projectURL, destination)
        _ = try await call("set_preference", ["key": "historyLimit", "value": 9])
        XCTAssertEqual(prefs.historyLimit, 9)
        do {
            _ = try await call("set_preference", ["key": "localMCPEnabled", "value": true])
            XCTFail("The client cannot grant itself access")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "invalid_arguments") }
    }

    func testPublicPreferenceSchemaRejectsInvalidValues() throws {
        let schemas = try MCPSchemas.loaded.get()
        let invalid: [(String, Any)] = [("historyLimit", 1.5), ("historyLimit", 501), ("volume", true),
            ("volume", -0.1), ("minimumPause", 0), ("leavePause", -1), ("snapTarget", "frames"),
            ("defaultExportMode", "movie"), ("jpegPreset", "jpg"), ("isMuted", 1), ("localMCPEnabled", true)]
        for (key, value) in invalid {
            XCTAssertThrowsError(try schemas.validate(tool: "set_preference", arguments: [
                "operationID": UUID().uuidString, "key": key, "value": value
            ])) { error in XCTAssertEqual((error as? MCPFailure)?.code, "invalid_arguments") }
        }
        XCTAssertNoThrow(try schemas.validate(tool: "set_preference", arguments: [
            "operationID": UUID().uuidString, "key": "minimumPause", "value": 1.0 / Double(AudioWaveform.rate)
        ]))
    }

    func testCloseRequiresDirtyDecisionAndUsesNativeDelegate() async throws {
        _ = NSApplication.shared
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs)
        let session = sessions.session(for: UUID())
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { if sessions.sessions[session.id] != nil { sessions.windowClosed(session); window.close() } }
        let path = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures")).path
        _ = try await sessions.mcpLifecycle(tool: "add_media", arguments: ["paths": [path]], session: session, checkAccess: {})
        XCTAssertTrue(session.hasUnsavedDocument)
        do {
            _ = try await sessions.mcpLifecycle(tool: "close_project", arguments: [:], session: session, checkAccess: {})
            XCTFail("An unsaved edit needs a close decision")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "unsaved_changes") }
        let cancelled = try await sessions.mcpLifecycle(tool: "close_project", arguments: ["changes": "cancel"],
                                                       session: session, checkAccess: {})
        XCTAssertEqual(cancelled?["closed"] as? Bool, false)
        let closed = try await sessions.mcpLifecycle(tool: "close_project", arguments: ["changes": "discard"],
                                                    session: session, checkAccess: {})
        XCTAssertEqual(closed?["closed"] as? Bool, true)
        XCTAssertNil(sessions.sessions[session.id])
    }

    func testNativeMulticamSetupKeepsSourceIDsAndChosenAudio() async throws {
        _ = NSApplication.shared
        let media = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        let created = try await sessions.mcpLifecycle(tool: "new_project",
            arguments: ["kind": "multicam", "paths": [media.path]], session: nil, checkAccess: {})
        let handle = try XCTUnwrap(created?["project"] as? String)
        let session = try XCTUnwrap(sessions.sessions.values.first { $0.mcpHandle == handle })
        let setup = try await sessions.mcpLifecycle(tool: "get_multicam_setup", arguments: [:],
                                                   session: session, checkAccess: {})
        let rows = try XCTUnwrap(setup?["sources"] as? [[String: Any]])
        let angle = try XCTUnwrap(rows.first?["id"] as? String)
        _ = try await sessions.mcpLifecycle(tool: "multicam_setup",
            arguments: ["action": "confirm", "opening": angle, "audio": ["mode": "none"], "names": [angle: "Wide"]],
            session: session, checkAccess: {})
        XCTAssertEqual(session.multicam.project?.angles.first?.name, "Wide")
        XCTAssertEqual(session.multicam.project?.audio, MulticamAudioPolicy.none)
        XCTAssertTrue(session.multicam.setup.isEmpty)
    }

    func testNativeConversionCancellationCannotReachAnotherWindowOrSuccessor() throws {
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let owner = sessions.session(for: UUID()), other = sessions.session(for: UUID())
        let first = EditCancellation()
        sessions.conversionOwner = owner.mcpHandle
        sessions.projectConversion = first
        let query = try sessions.mcpNativeOperations(tool: "get_native_operations", arguments: [:], session: owner)
        let row = try XCTUnwrap((query["operations"] as? [[String: Any]])?.first)
        let receipt = ["nativeOperation": try XCTUnwrap(row["nativeOperation"] as? String)]
        XCTAssertThrowsError(try sessions.mcpNativeOperations(tool: "cancel_native_operation", arguments: receipt, session: other))
        XCTAssertFalse(first.isCancelled)
        _ = try sessions.mcpNativeOperations(tool: "cancel_native_operation", arguments: receipt, session: owner)
        XCTAssertTrue(first.isCancelled)
        sessions.finishProjectConversion()
        let next = EditCancellation()
        sessions.conversionOwner = owner.mcpHandle
        sessions.projectConversion = next
        defer { sessions.finishProjectConversion() }
        XCTAssertThrowsError(try sessions.mcpNativeOperations(tool: "cancel_native_operation", arguments: receipt, session: owner))
        XCTAssertFalse(next.isCancelled)
    }

    func testRevokedOrdinaryImportLeavesNoPartialClipOrHistory() async throws {
        _ = NSApplication.shared
        let media = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let session = ProjectSession(id: UUID(), preferences: prefs)
        defer { session.end() }
        session.editor.importFiles([media, media], allowCommit: { false })
        let deadline = ContinuousClock.now + .seconds(20)
        while session.editor.isImporting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(session.editor.isImporting)
        XCTAssertTrue(session.editor.sequenceClips.isEmpty)
        XCTAssertTrue(session.editor.historyActions.isEmpty)
        XCTAssertEqual(session.editor.mcpRevision, 0)
    }

    func testPendingSheetPreventsAnImportCommit() async throws {
        let media = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs, openWindow: { _ in })
        let session = try sessions.createWindow()
        defer { sessions.windowClosed(session) }
        do {
            _ = try await sessions.mcpLifecycle(tool: "add_media", arguments: ["paths": [media.path]], session: session,
                checkAccess: { if !session.editor.isImporting { session.isHistoryPresented = true } })
            XCTFail("Media must not commit over a new modal presentation")
        } catch let failure as MCPFailure { XCTAssertEqual(failure.code, "busy") }
        XCTAssertTrue(session.editor.sequenceClips.isEmpty)
        XCTAssertTrue(session.editor.historyActions.isEmpty)
        XCTAssertEqual(session.editor.mcpRevision, 0)
    }
}
