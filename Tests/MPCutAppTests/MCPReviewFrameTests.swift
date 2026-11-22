import Foundation
import ImageIO
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPReviewFrameTests: XCTestCase {
    func testRepeatedOccurrenceProducesDecodableReviewWithoutEditing() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        session.editor.importFiles([fixture, fixture])
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while session.editor.isBusy {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = session.editor
        let revision = editor.mcpRevision, cursor = editor.historyCursor, playhead = editor.playhead
        let time = try XCTUnwrap(editor.mcpSequenceOffsets.last)
        let request: [String: Any] = ["space": "sequence", "time": time.description]
        let result = try await registry.mcpReviewFrame(arguments: request, session: session, checkAccess: {})
        XCTAssertEqual(result["occurrence"] as? String, editor.mcpClipIDs.last?.uuidString)
        XCTAssertEqual(result["sourceTime"] as? String, editor.sequenceClips.last?.from.description)
        let encoded = try XCTUnwrap(result["jpeg"] as? String)
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertLessThanOrEqual(bytes.count, 1_048_576)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, result["width"] as? Int)
        XCTAssertEqual(image.height, result["height"] as? Int)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 640)
        XCTAssertEqual(editor.mcpRevision, revision)
        XCTAssertEqual(editor.historyCursor, cursor)
        XCTAssertEqual(editor.playhead, playhead)

        var accessChecks = 0
        do {
            _ = try await registry.mcpReviewFrame(arguments: request, session: session) {
                accessChecks += 1
                if accessChecks > 1 { throw MCPCommandError("control_disabled", "Disabled during rendering.") }
            }
            XCTFail("A revoked request must not return a picture.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "control_disabled")
        }
    }

    func testRepeatedMulticamAssemblyMapsToGroupAndCamera() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let model = session.multicam
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let draft = MulticamEditorModel.SourceDraft(source: .init(id: "wide", file: fixture.path), media: media)
        model.confirmSetup(drafts: [draft], opening: "wide", audio: .none)
        let range = try XCTUnwrap(model.project?.range)
        XCTAssertTrue(model.edit("Repeat") { $0.assembly = [range, range] })
        let secondFrame = try XCTUnwrap(media.frames.dropFirst().first?.time)
        let assemblyTime = try range.to.adding(secondFrame)
        let result = try await registry.mcpReviewFrame(arguments: [
            "time": assemblyTime.description, "space": "assembly", "angle": "wide"
        ], session: session, checkAccess: {})
        XCTAssertEqual(result["sourceTime"] as? String, secondFrame.description)
        XCTAssertEqual(result["time"] as? String, assemblyTime.description)
        XCTAssertEqual(result["groupTime"] as? String, secondFrame.description)
        XCTAssertEqual(result["angle"] as? String, "wide")
    }
}
