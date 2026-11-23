import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// A remote client reads the export tier with the editor state, and the range-edge suggestion with the switch suggestions.
final class MCPTierReportTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    @MainActor
    func testEditorStateReportsTheTierOfSequenceAndMulticamProjects() async throws {
        let directory = "/tmp/mpcut-test-" + UUID().uuidString
        let suite = "mpcut-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(atPath: directory) }
        let preferences = EditorPreferences(defaults: defaults)
        let sessions = ProjectSessions(preferences: preferences)
        let bridge = MCPLocalControl(sessions: sessions, socket: MCPSocket(directory: directory))
        bridge.observeSetting()
        defer { bridge.stop() }
        preferences.localMCPEnabled = true
        let session = sessions.session(for: nil)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { session.editor.endSession(); sessions.windowClosed(session); window.close() }

        // An empty timeline has no tier.
        var state = try await bridge.perform(tool: "project_editor_state_read", arguments: ["project_handle": session.mcpHandle])
        XCTAssertNil(state["tier"])

        let editor = session.editor
        editor.importFiles([try fixture("SmartTrim-GOP", "mp4")])
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isBusy || !editor.tierIsCurrent, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        state = try await bridge.perform(tool: "project_editor_state_read", arguments: ["project_handle": session.mcpHandle])
        var tier = try XCTUnwrap(state["tier"] as? [String: Any])
        XCTAssertEqual(tier["id"] as? String, "true_lossless")
        XCTAssertEqual(tier["name"] as? String, "True Lossless")
        XCTAssertEqual(tier["current"] as? Bool, true)
        XCTAssertEqual(tier["mode"] as? String, editor.tierReport?["mode"] as? String)
        XCTAssertNotNil(tier["container"] as? String)
        XCTAssertEqual((tier["factors"] as? [[String: Any]])?.count, 0)

        // A multicam window reports the tier of its program in the same shape.
        let factor = TierFactor(id: .cutVideoStart, forces: .lossless, message: "Range 1 starts between keyframes.")
        session.multicam.tierState = .known(tier: .lossless, factors: [factor], container: "mov", warnings: [])
        session.isMulticam = true
        state = try await bridge.perform(tool: "project_editor_state_read", arguments: ["project_handle": session.mcpHandle])
        XCTAssertEqual(state["kind"] as? String, "multicam")
        tier = try XCTUnwrap(state["tier"] as? [String: Any])
        XCTAssertEqual(tier["id"] as? String, "lossless")
        XCTAssertEqual(tier["container"] as? String, "mov")
        let factors = try XCTUnwrap(tier["factors"] as? [[String: Any]])
        XCTAssertEqual(factors.first?["id"] as? String, TierFactorID.cutVideoStart.rawValue)
        XCTAssertEqual(factors.first?["forces"] as? String, "lossless")
    }

    @MainActor
    func testRangeEdgeSuggestionIsListedAndAppliedOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = EditorPreferences()
        preferences.historyLimit = 10
        preferences.useAnalysisSidecars = false
        let model = MulticamEditorModel(preferences: preferences, draft: ProjectDraft(directory: directory))
        defer { model.reset() }
        let source = try fixture("ProRes-2997", "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: source.path), media: media)], opening: "wide", audio: .none)
        let whole = try XCTUnwrap(model.project?.range)
        let earlier = media.frames[media.frames.count / 2].time

        var listed = try await model.mcpCommand(tool: "multicam_state_read", arguments: ["section": "suggestions"]) {}
        XCTAssertNil(listed?["edge"])

        model.edgeSuggestion = MulticamEdgeSuggestion(edge: MulticamEdge(range: 1, boundary: "to", at: whole.to), times: [earlier])
        listed = try await model.mcpCommand(tool: "multicam_state_read", arguments: ["section": "suggestions"]) {}
        let edge = try XCTUnwrap(listed?["edge"] as? [String: Any])
        XCTAssertEqual(edge["range_number"] as? Int, 1)
        XCTAssertEqual(edge["boundary"] as? String, "to")
        XCTAssertEqual(edge["group_time"] as? String, whole.to.description)
        XCTAssertEqual(edge["times"] as? [String], [earlier.description])

        // A time that was not suggested changes nothing.
        let revision = model.mcpRevision
        do {
            _ = try await model.mcpCommand(tool: "multicam_assembly_edit", arguments: [
                "action": "apply_edge_suggestion", "to": media.frames[1].time.description
            ]) {}
            XCTFail("A time outside the suggestion must be refused.")
        } catch {
            XCTAssertEqual((error as? MCPCommandError)?.code, "invalid_target")
        }
        XCTAssertNil(model.project?.assembly)
        XCTAssertEqual(model.mcpRevision, revision)

        let applied = try await model.mcpCommand(tool: "multicam_assembly_edit", arguments: [
            "action": "apply_edge_suggestion", "to": earlier.description
        ]) {}
        XCTAssertEqual(applied?["action"] as? String, "Move Range Edge")
        XCTAssertEqual(model.project?.assembly, [.init(from: whole.from, to: earlier)])
        XCTAssertGreaterThan(model.mcpRevision, revision)

        // The suggestion is spent.
        listed = try await model.mcpCommand(tool: "multicam_state_read", arguments: ["section": "suggestions"]) {}
        XCTAssertNil(listed?["edge"])
        do {
            _ = try await model.mcpCommand(tool: "multicam_assembly_edit", arguments: [
                "action": "apply_edge_suggestion", "to": earlier.description
            ]) {}
            XCTFail("A spent suggestion must be refused.")
        } catch {
            XCTAssertEqual((error as? MCPCommandError)?.code, "invalid_target")
        }
        XCTAssertEqual(model.project?.assembly, [.init(from: whole.from, to: earlier)])
    }
}
