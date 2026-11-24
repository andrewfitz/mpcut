import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class SidecarStorageSettingsTests: XCTestCase {
    @MainActor
    func testClearPreviewProtectsSourcesAndProjectsAcrossWindows() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.historyLimit = 0
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        let documents = ["First.cut", "Second.cut"].map { folder.appendingPathComponent($0) }
        let sources = ["A.mov", "A.mov.cutdb"].map { folder.appendingPathComponent($0) }
        for (document, source) in zip(documents, sources) {
            let clip = CutSequenceClip(id: "clip", file: source.lastPathComponent, from: .zero, to: .init(numerator: 1))
            try CutProject.sequence([]).save(to: document, undo: [.init(action: "Delete clip", project: .sequence([clip]))], redo: [])
            sessions.openFiles([document])
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while sessions.sessions.values.contains(where: { $0.editor.projectURL == nil }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = SidecarClearContext(sessions: sessions)
        XCTAssertEqual(Set(documents.map(\.path)), Set(sessions.sessions.values.compactMap { $0.editor.projectURL?.path }))
        XCTAssertEqual(Set(documents.map(\.path)), Set(context.projects.map(\.path)))
        XCTAssertTrue(Set(sources.map(\.path)).isSubset(of: Set(context.sources.map(\.path))))
        XCTAssertTrue(Set((documents + sources).map(\.path)).isSubset(of: Set(context.protected.map(\.path))))
    }
}
