import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class QueueSnapshotTests: XCTestCase {
    func testMCPInspectsAndRevisesFrozenSequenceEntries() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(15)
        while editor.isBusy, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.isBusy)
        let id = try XCTUnwrap(editor.mcpClipIDs.first)
        _ = try await editor.mcpCommand(tool: "timeline_item_split",
                                       arguments: ["space": "source", "time": "1", "occurrence": id.uuidString], validateCommit: {})

        func queue(_ action: String, _ args: [String: Any] = [:]) async throws -> [[String: Any]] {
            let result = try await sessions.mcpOutputs(tool: action, arguments: args, session: session, checkAccess: {})
            return try XCTUnwrap(result?["ranges"] as? [[String: Any]])
        }

        editor.selectRange(0.2, 1.6)
        let added = try await queue("export_queue_range_add")
        let original = try XCTUnwrap(added.first)
        let entryID = try XCTUnwrap(original["id"] as? String)
        let before = try XCTUnwrap(original["items"] as? [[String: String]])
        XCTAssertEqual(before.map { $0["file"] }, [source.path, source.path])
        XCTAssertEqual(before.map { $0["from"] }, ["1/5", "1"])
        XCTAssertEqual(before.map { $0["to"] }, ["1", "8/5"])
        editor.undo()
        XCTAssertEqual(editor.mcpClipIDs.count, 1)
        let inspected = try await queue("export_queue_list")
        XCTAssertEqual(inspected.first?["items"] as? [[String: String]], before)

        let renamed = try await queue("export_queue_entry_rename", ["id": entryID, "name": " Interview "])
        XCTAssertEqual(renamed.first?["name"] as? String, "Interview")
        XCTAssertEqual(renamed.first?["items"] as? [[String: String]], before)

        editor.selectRange(0.4, 1.6)
        do {
            _ = try await queue("export_queue_entry_revise", ["id": entryID, "mode": "extend"])
            XCTFail("Expected an extension to contain the original range.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_extension")
        }
        let retained = try await queue("export_queue_list")
        XCTAssertEqual(retained.first?["items"] as? [[String: String]], before)

        editor.selectRange(0, 2)
        let extended = try await queue("export_queue_entry_revise", ["id": entryID, "mode": "extend"])
        XCTAssertEqual(extended.first?["id"] as? String, entryID)
        XCTAssertEqual(extended.first?["name"] as? String, "Interview")
        XCTAssertEqual(extended.first?["from"] as? String, "0")
        XCTAssertEqual(extended.first?["to"] as? String, "2")
        XCTAssertEqual((extended.first?["items"] as? [[String: String]])?.count, 1)
        XCTAssertFalse(editor.canAddMarkedRange)

        editor.selectRange(0.4, 1.2)
        editor.showBulkQueue()
        XCTAssertTrue(editor.isBusy)
        XCTAssertTrue(editor.canReviseQueuedRange)
        let replaced = try await queue("export_queue_entry_revise", ["id": entryID, "mode": "replace"])
        XCTAssertEqual(replaced.first?["id"] as? String, entryID)
        XCTAssertEqual(replaced.first?["name"] as? String, "Interview")
        let items = try XCTUnwrap(replaced.first?["items"] as? [[String: String]])
        XCTAssertEqual(items, [["kind": "clip", "file": source.path, "from": "2/5", "to": "6/5"]])
        XCTAssertFalse(editor.canReviseQueuedRange)
    }

    func testMulticamInspectionUsesCapturedRecordingOffsetsAndOrder() async throws {
        func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
        func r(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: t(from), to: t(to)) }

        var wide = MulticamSource(id: "wide", file: "/wide.mov", audioStream: 2)
        wide.coverage = r(0, 6)
        wide.additionalRecordings = [
            .init(id: "wide-b", file: "/wide-b.mov", offset: t(7), audioStream: 3, coverage: r(8, 15))
        ]
        let project = MulticamProject(referenceAngle: "wide", range: r(0, 15), angles: [wide], audio: .follow,
                                      switches: [.init(at: .zero, angle: "wide")])
        let entry = MulticamQueuedRange(name: "Take", range: r(4, 10), project: project, media: [:])
        let items = try entry.snapshotItems()
        XCTAssertEqual(items.map(\.kind), ["angle", "gap", "angle", "audio", "audio"])
        XCTAssertEqual(items.map(\.file), ["/wide.mov", "Gap", "/wide-b.mov", "/wide.mov", "/wide-b.mov"])
        XCTAssertEqual(items.map(\.from), [t(4), nil, t(1), t(4), t(1)])
        XCTAssertEqual(items.map(\.to), [t(6), nil, t(3), t(6), t(3)])
        XCTAssertEqual(items.map(\.output), [r(0, 2), r(2, 4), r(4, 6), r(0, 2), r(4, 6)])
        XCTAssertEqual(items.compactMap(\.stream), [2, 3])
    }

    func testMulticamMixSnapshotKeepsBothLanesInCapturedOrder() throws {
        let range = MulticamRange(from: .zero, to: .init(numerator: 2))
        let wide = MulticamSource(id: "wide", file: "/wide.mov", audioStream: 2)
        let close = MulticamSource(id: "close", file: "/close.mov", audioStream: 3)
        var project = MulticamProject(referenceAngle: "wide", range: range, angles: [wide, close], audio: .mix,
                                     switches: [.init(at: .zero, angle: "wide")],
                                     mixLanes: [
                                         .init(id: "close-mic", target: .camera("close"), label: "Close mic", colorSlot: 3),
                                         .init(id: "wide-mic", target: .camera("wide"), label: "Wide mic", colorSlot: 1),
                                     ])
        let entry = MulticamQueuedRange(name: "Take", range: range, project: project, media: [:])
        project.mixLanes.reverse()
        XCTAssertEqual(project.mixLanes.map(\.id), ["wide-mic", "close-mic"])
        let audio = try entry.snapshotItems().filter { $0.kind == "audio" }
        XCTAssertEqual(audio.map(\.laneID), ["close-mic", "wide-mic"])
        XCTAssertEqual(audio.map(\.laneLabel), ["Close mic", "Wide mic"])
        XCTAssertEqual(audio.map(\.laneColorSlot), [3, 1])
        XCTAssertEqual(audio.map(\.stream), [3, 2])
        XCTAssertEqual(audio.map(\.output), [range, range])
        XCTAssertEqual(audio.first?.json["lane_id"] as? String, "close-mic")
    }

    func testMulticamSnapshotReportsDuplicateSourceIDs() {
        let range = MulticamRange(from: .zero, to: .init(numerator: 2))
        let wide = MulticamSource(id: "wide", file: "/wide.mov")
        let duplicate = MulticamSource(id: "wide", file: "/other.mov")
        let project = MulticamProject(referenceAngle: "wide", range: range, angles: [wide, duplicate],
                                      audio: .follow, switches: [.init(at: .zero, angle: "wide")])
        let entry = MulticamQueuedRange(name: "Take", range: range, project: project, media: [:])

        XCTAssertThrowsError(try entry.snapshotItems())
    }

}
