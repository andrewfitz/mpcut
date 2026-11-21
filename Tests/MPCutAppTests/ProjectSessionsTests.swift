import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class ProjectSessionsTests: XCTestCase {
    @MainActor
    func testBatchOpensEachProjectOnceAndSaveAsReleasesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.multicam.json")
        let second = directory.appendingPathComponent("second.multicam.json")
        let linked = directory.appendingPathComponent("link.multicam.json")
        let renamed = directory.appendingPathComponent("renamed.multicam.json")
        try makeProject(angle: "first").save(to: first)
        try makeProject(angle: "second").save(to: second)
        try FileManager.default.linkItem(at: first, to: linked)

        var opened: [UUID] = []
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { opened.append($0) })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let blank = try XCTUnwrap(sessions.sessions.values.first)
        sessions.openFiles([first, second, linked, first], in: blank)
        XCTAssertEqual(opened.count, 2)
        let a = try XCTUnwrap(sessions.project(at: first))
        XCTAssertTrue(a === blank)
        let b = try XCTUnwrap(sessions.project(at: second))
        XCTAssertFalse(a === b)
        XCTAssertTrue(a === sessions.project(at: linked))
        try await waitForProject(a.multicam)
        try await waitForProject(b.multicam)
        XCTAssertNil(a.multicam.openingProjectURL)
        XCTAssertNil(b.multicam.openingProjectURL)

        a.multicam.updateSource("first") { $0.name = "Edited camera" }
        XCTAssertTrue(a.multicam.isChanged)
        XCTAssertFalse(b.multicam.isChanged)
        XCTAssertEqual(b.multicam.project?.referenceAngle, "second")
        XCTAssertTrue(a.multicam.saveProject(to: renamed))
        XCTAssertNil(sessions.project(at: first))
        XCTAssertTrue(a === sessions.project(at: renamed))
        sessions.openFiles([first])
        XCTAssertEqual(opened.count, 3)
        let original = try XCTUnwrap(sessions.project(at: first))
        XCTAssertFalse(original === a)
        try await waitForProject(original.multicam)
        XCTAssertNil(original.multicam.project?.angles.first?.name)
        XCTAssertEqual(a.multicam.project?.angles.first?.name, "Edited camera")

        sessions.windowClosed(b)
        XCTAssertNil(sessions.project(at: second))
        XCTAssertEqual(sessions.sessions.count, 2)
    }

    @MainActor
    func testSessionOwnsIndependentEditorAndMulticamState() {
        let preferences = EditorPreferences()
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        let regular = sessions.session(for: nil)
        let multicam = sessions.session(for: nil)
        XCTAssertFalse(regular === multicam)
        XCTAssertTrue(regular.canStartMulticam())
        XCTAssertTrue(regular.canReceiveMedia)
        multicam.isMulticam = true
        multicam.multicam.timelineZoom = 4
        regular.editor.timelineZoom = 2
        XCTAssertFalse(multicam.canReceiveMedia)
        XCTAssertFalse(regular.isMulticam)
        XCTAssertEqual(regular.multicam.timelineZoom, 0)
        XCTAssertEqual(multicam.editor.timelineZoom, 0)

        multicam.end()
        XCTAssertEqual(regular.editor.timelineZoom, 2)
        XCTAssertEqual(multicam.multicam.timelineZoom, 0)
    }

    @MainActor
    func testOpeningProjectPreservesAnActiveRegularImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("new.multicam.json")
        try makeProject(angle: "new").save(to: document)
        let media = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))

        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let regular = try XCTUnwrap(sessions.sessions.values.first)
        sessions.openFiles([media], in: regular)
        XCTAssertTrue(regular.editor.isImporting)
        sessions.openFiles([document], in: regular)
        let multicam = try XCTUnwrap(sessions.project(at: document))
        XCTAssertFalse(multicam === regular)
        XCTAssertFalse(regular.isMulticam)
        try await waitForProject(multicam.multicam)

        let deadline = ContinuousClock.now + .seconds(5)
        while regular.editor.isImporting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(regular.editor.timelineClips.count, 1)
        sessions.windowClosed(multicam)
        XCTAssertEqual(regular.editor.timelineClips.count, 1)
    }

    @MainActor
    func testKeyWindowNotificationsSelectOnlyTheCurrentProjectCommands() throws {
        _ = NSApplication.shared
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let regular = try XCTUnwrap(sessions.sessions.values.first)
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).multicam.json")
        try makeProject(angle: "wide").save(to: document)
        defer {
            for session in Array(sessions.sessions.values) { sessions.windowClosed(session) }
            try? FileManager.default.removeItem(at: document)
        }
        sessions.openFiles([document])
        let multicam = try XCTUnwrap(sessions.project(at: document))
        let regularWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let multicamWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let settingsWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        regular.window = regularWindow
        multicam.window = multicamWindow

        let notifications = NotificationCenter.default
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: regularWindow)
        XCTAssertTrue(sessions.commandContext?.session === regular)
        XCTAssertEqual(sessions.commandContext?.isMulticam, false)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: multicamWindow)
        XCTAssertTrue(sessions.commandContext?.session === multicam)
        XCTAssertEqual(sessions.commandContext?.isMulticam, true)
        notifications.post(name: NSWindow.didResignKeyNotification, object: regularWindow)
        XCTAssertTrue(sessions.commandContext?.session === multicam)
        multicam.isMulticam = false
        XCTAssertEqual(sessions.commandContext?.isMulticam, false)
        notifications.post(name: NSWindow.willBeginSheetNotification, object: multicamWindow)
        XCTAssertNil(sessions.commandContext)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: multicamWindow)
        XCTAssertTrue(sessions.commandContext?.session === multicam)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        XCTAssertNil(sessions.commandContext)
    }

    @MainActor
    func testAcceptedPickerCanReuseBlankWindowWhileStillAttached() {
        final class SheetOwner: NSWindow {
            var testSheet: NSWindow?
            override var attachedSheet: NSWindow? { testSheet }
        }

        _ = NSApplication.shared
        let session = ProjectSession(id: UUID(), preferences: EditorPreferences())
        let window = SheetOwner(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let picker = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let otherSheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        session.window = window
        window.testSheet = picker

        XCTAssertFalse(session.canReceiveMedia)
        XCTAssertFalse(session.canStartMulticam())
        XCTAssertFalse(session.canStartMulticam(accepting: otherSheet))
        XCTAssertTrue(session.canStartMulticam(accepting: picker))

        window.testSheet = otherSheet
        XCTAssertFalse(session.canStartMulticam(accepting: picker))
    }

    private func makeProject(angle: String) -> MulticamProject {
        MulticamProject(referenceAngle: angle, range: .init(from: .zero, to: .init(numerator: 1)),
                        angles: [.init(id: angle, file: "offline.mov")], audio: .none,
                        switches: [.init(at: .zero, angle: angle)])
    }

    @MainActor
    private func waitForProject(_ model: MulticamEditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.project)
        XCTAssertFalse(model.isBusy)
    }
}
