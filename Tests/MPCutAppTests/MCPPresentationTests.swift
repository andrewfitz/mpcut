import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

final class MCPPresentationTests: XCTestCase {
    @MainActor
    func testZoomRestoreAndNativeWaveformSpanAreWindowScoped() async throws {
        _ = NSApplication.shared
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let project = sessions.session(for: UUID())
        let other = sessions.session(for: UUID())
        project.editor.useAnalysisSidecars = false
        defer { project.end(); other.end() }
        let recording = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Chirp", withExtension: "opus",
                                                        subdirectory: "Fixtures"))
        project.editor.importFiles([recording])
        let deadline = ContinuousClock.now + .seconds(10)
        while project.editor.isBusy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let history = project.editor.historyActions
        func apply(_ arguments: [String: Any]) async throws -> [String: Any]? {
            try await sessions.mcpPresentation(tool: "set_presentation", arguments: arguments,
                                               session: project, checkAccess: {})
        }
        _ = try await apply(["action": "setZoom", "zoom": 3])
        _ = try await apply(["action": "fit"])
        let restored = try await apply(["action": "restoreZoom"])
        XCTAssertEqual(restored?["zoomFactor"] as? Double, 8)
        XCTAssertEqual(project.editor.timelineZoom, 3)
        XCTAssertEqual(other.editor.timelineZoom, 0)
        let result = try await apply(["action": "setWaveformSpan", "span": "10 ms"])
        XCTAssertEqual(result?["waveformSpan"] as? String, "10 ms")
        XCTAssertEqual(project.presentation.waveformSpan, .ms10)
        XCTAssertEqual(other.presentation.waveformSpan, .timeline)
        XCTAssertEqual(project.editor.historyActions, history)
        do {
            _ = try await apply(["action": "setZoom", "zoom": true])
            XCTFail("Boolean accepted as a numeric zoom")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_arguments")
        }
        XCTAssertEqual(project.editor.timelineZoom, 3)
    }

    @MainActor
    func testNativeMulticamScrollAndInspector() async throws {
        _ = NSApplication.shared
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let session = sessions.session(for: UUID())
        session.isMulticam = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        let project = MulticamProject(referenceAngle: "1", range: .init(from: .zero, to: .init(numerator: 20)),
                                      angles: (1...12).map { .init(id: String($0), file: "camera-\($0).mov") },
                                      audio: .none, switches: [.init(at: .zero, angle: "1")])
        try project.save(to: url)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1060, height: 730),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        session.window = window
        defer {
            window.close()
            session.end()
            try? FileManager.default.removeItem(at: url)
        }
        session.multicam.openProject(url)
        let deadline = ContinuousClock.now + .seconds(8)
        while session.multicam.project == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let hosting = NSHostingView(rootView: MulticamEditorView(model: session.multicam,
                                                                 presentation: session.presentation))
        window.contentView = hosting
        func apply(_ args: [String: Any]) async throws -> [String: Any] {
            try await sessions.mcpPresentation(tool: "set_presentation", arguments: args,
                                               session: session, checkAccess: {}) ?? [:]
        }
        _ = try await apply(["action": "setInspector", "section": "Assembly"])
        _ = try await apply(["action": "setZoom", "zoom": 2])
        let layoutDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < layoutDeadline {
            hosting.layoutSubtreeIfNeeded()
            let state = try await sessions.mcpPresentation(tool: "get_presentation", arguments: [:],
                                                           session: session, checkAccess: {})
            if let scroll = state?["scrollPositions"] as? [String: Double],
               scroll["group"] != nil, scroll["tracks"] != nil, scroll["assembly"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let panned = try await apply(["action": "setScroll", "surface": "group", "fraction": 0.6])
        let positions = try XCTUnwrap(panned["scrollPositions"] as? [String: Double])
        XCTAssertEqual(positions["group"] ?? -1, 0.6, accuracy: 0.005)
        XCTAssertNotNil(positions["tracks"])
        XCTAssertNotNil(positions["assembly"])
        XCTAssertEqual(panned["inspector"] as? String, "Assembly")
        XCTAssertTrue(session.presentation.inspectorVisible)
        XCTAssertNotNil(panned["timelineHeight"])
        let playhead = session.multicam.preview.time
        _ = try await apply(["action": "revealTime", "surface": "group", "time": "1/10"])
        XCTAssertEqual(session.multicam.preview.time, playhead)
        let hidden = try await apply(["action": "setInspector", "visible": false])
        XCTAssertEqual(hidden["inspectorVisible"] as? Bool, false)
    }
}
