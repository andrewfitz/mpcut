import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class ProjectSessionsTests: XCTestCase {
    @MainActor
    func testFinderColdLaunchWaitsForActualWindowAndWarmOpenCreatesOne() async throws {
        _ = NSApplication.shared
        var opened: [UUID] = []
        let sessions = ProjectSessions(preferences: EditorPreferences(), launching: true,
                                       openWindow: { opened.append($0) })
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        try CutProject.sequence([]).save(to: document)
        defer {
            for session in Array(sessions.sessions.values) { sessions.windowClosed(session) }
            try? FileManager.default.removeItem(at: document)
        }
        let provisional = sessions.session(for: nil)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sessions.register(provisional, window: window)
        sessions.openFiles([document])
        sessions.windowClosed(provisional)
        sessions.openFiles([document])
        sessions.finishLaunching()
        XCTAssertTrue(sessions.reopen(), "A Dock reopen during launch should use the upcoming window")
        XCTAssertTrue(opened.isEmpty)
        let actual = sessions.session(for: nil)
        sessions.register(actual, window: window)
        let deadline = ContinuousClock.now + .seconds(5)
        while sessions.project(at: document) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sessions.project(at: document) === actual)
        XCTAssertEqual(sessions.sessions.count, 1)
        XCTAssertTrue(opened.isEmpty, "WindowGroup already provided the launch window")

        sessions.windowClosed(actual)
        sessions.openFiles([document, document])
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(sessions.sessions.count, 1)
    }

    @MainActor
    func testOpeningSequenceRaisesReusedEditor() throws {
        final class OrderingWindow: NSWindow {
            var orderedFront = false
            override func makeKeyAndOrderFront(_ sender: Any?) { orderedFront = true }
        }
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        try CutProject.sequence([]).save(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        let session = sessions.session(for: nil)
        let window = OrderingWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sessions.register(session, window: window)
        defer { sessions.windowClosed(session); window.close() }
        XCTAssertFalse(window.orderedFront)
        sessions.openFiles([file], in: session)
        XCTAssertTrue(sessions.project(at: file) === session)
        XCTAssertTrue(window.orderedFront)
        XCTAssertEqual(sessions.sessions.count, 1)
    }

    @MainActor
    func testRoutedOpenProtectsMediaOutsideTheLoadedHistoryLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("history-only.mov")
        let sequence = folder.appendingPathComponent("Sequence.cut")
        let previous = CutProject.sequence([CutSequenceClip(id: "a", file: missing.lastPathComponent, from: .zero,
                                                           to: .init(numerator: 1))])
        try CutProject.sequence([]).save(to: sequence, undo: [.init(action: "Delete Clip", project: previous)], redo: [])
        let preferences = EditorPreferences()
        preferences.historyLimit = 0
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        sessions.openFiles([sequence])
        let ordinary = try XCTUnwrap(sessions.project(at: sequence))
        XCTAssertTrue(ordinary.editor.historyActions.isEmpty)
        XCTAssertThrowsError(try ordinary.editor.validateHistoryDestination(missing))

        let multicam = folder.appendingPathComponent("Multicam.cut")
        let current = makeProject(angle: "wide")
        var old = current
        old.angles[0].file = missing.lastPathComponent
        try CutProject.multicam(current).save(to: multicam, undo: [],
                                              redo: [.init(action: "Relink Camera", project: .multicam(old))])
        sessions.openFiles([multicam])
        let multi = try XCTUnwrap(sessions.project(at: multicam))
        try await waitForProject(multi.multicam)
        XCTAssertTrue(multi.multicam.historyActions.isEmpty)
        XCTAssertThrowsError(try multi.multicam.validateHistoryDestination(missing))
    }

    @MainActor
    func testFinderOpenDuringDockReopenUsesPendingWindow() throws {
        var opened: [UUID] = []
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { opened.append($0) })
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        try CutProject.sequence([]).save(to: document)
        defer {
            for session in Array(sessions.sessions.values) { sessions.windowClosed(session) }
            try? FileManager.default.removeItem(at: document)
        }
        XCTAssertTrue(sessions.reopen())
        sessions.openFiles([document])
        XCTAssertTrue(sessions.reopen())
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(sessions.project(at: document)?.id, opened.first)
    }

    @MainActor
    func testBatchOpensEachProjectOnceAndSaveAsReleasesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.cut")
        let second = directory.appendingPathComponent("second.cut")
        let linked = directory.appendingPathComponent("link.cut")
        let renamed = directory.appendingPathComponent("renamed.cut")
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
        let document = directory.appendingPathComponent("new.cut")
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
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        try makeProject(angle: "wide").save(to: document)
        defer {
            for session in Array(sessions.sessions.values) { sessions.windowClosed(session) }
            try? FileManager.default.removeItem(at: document)
        }
        sessions.openProject(document, in: nil)
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

    @MainActor
    func testDraftCleanupRequiresApprovalFromEveryWindow() throws {
        _ = NSApplication.shared
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        let windows = (0..<2).map { _ in NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true) }
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        let files = try windows.map { window in
            let session = sessions.session(for: nil)
            session.isMulticam = true
            sessions.register(session, window: window)
            try session.multicam.draft.write { try CutProject.sequence([]).save(to: $0) }
            return try XCTUnwrap(session.multicam.draft.url)
        }
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        var asked = 0
        let decision = sessions.prepareToQuit(stopExports: { true }, confirmClose: { _ in
            asked += 1
            return asked == 1
        }, reply: { _ in XCTFail("No work is pending") })
        XCTAssertEqual(decision, .cancel)
        XCTAssertEqual(asked, 2)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, confirmClose: { _ in true },
                                              reply: { _ in XCTFail("No work is pending") }), .now)
        sessions.finishTermination()
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testChangesAfterQuitApprovalRemainRecoverableAtTermination() async throws {
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        defer { try? FileManager.default.removeItem(at: file) }
        try makeProject(angle: "camera").save(to: file)
        sessions.openFiles([file])
        let session = try XCTUnwrap(sessions.project(at: file))
        defer { sessions.windowClosed(session) }
        try await waitForProject(session.multicam)
        session.multicam.updateSource("camera") { $0.name = "First edit" }
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, confirmClose: { _ in true },
                                              reply: { _ in XCTFail("Nothing to wait for") }), .now)
        let before = Set(try ProjectDraft.recoverable())
        let name = UUID().uuidString
        session.multicam.updateSource("camera") { $0.name = name }
        sessions.finishTermination()
        let recovered = try XCTUnwrap(try ProjectDraft.recoverable().first { url in
            guard !before.contains(url), case .multicam(let project) = try? CutProject.load(from: url) else { return false }
            return project.angles.first?.name == name
        })
        defer { try? FileManager.default.removeItem(at: recovered.deletingLastPathComponent()) }
        XCTAssertEqual(try CutProject.loadDocument(from: recovered, limit: 1).undo.map(\.action), ["Rename Source"])
        XCTAssertNil(try MulticamProject.load(from: file).angles.first?.name)
    }

    @MainActor
    func testDeferredQuitRechecksTheProvisionalOpeningCamera() throws {
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        defer { sessions.windowClosed(session) }
        session.isMulticam = true
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let drafts = ["wide", "close"].map { name in
            MulticamEditorModel.SourceDraft(source: .init(id: name, file: url.path), media: media)
        }
        session.multicam.setup = drafts
        session.multicam.updatePendingSetup(drafts, opening: "wide", audio: .none)
        sessions.projectConversion = EditCancellation()
        var asked = 0
        var replies: [Bool] = []
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, confirmClose: { _ in
            asked += 1
            return asked == 1
        }, reply: { replies.append($0) }), .later)
        session.multicam.updatePendingSetup(drafts, opening: "close", audio: .none)
        sessions.finishProjectConversion()
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(replies, [false])
    }

    @MainActor
    func testDeferredQuitRechecksEditedAndNewSessionsBeforeDiscardingDrafts() async throws {
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        defer { try? FileManager.default.removeItem(at: file) }
        try makeProject(angle: "camera").save(to: file)
        sessions.openFiles([file])
        let edited = try XCTUnwrap(sessions.project(at: file))
        try await waitForProject(edited.multicam)
        edited.multicam.updateSource("camera") { $0.name = "First edit" }

        sessions.projectConversion = EditCancellation()
        var confirmations: [UUID] = []
        var shouldCancelRecheck = false
        var replies: [Bool] = []
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, confirmClose: { session in
            confirmations.append(session.id)
            return !shouldCancelRecheck
        }, reply: { replies.append($0) }), .later)
        XCTAssertEqual(confirmations, [edited.id])

        edited.multicam.updateSource("camera") { $0.name = "Edited while waiting" }
        shouldCancelRecheck = true
        sessions.finishProjectConversion()
        XCTAssertEqual(confirmations, [edited.id, edited.id])
        XCTAssertEqual(replies, [false])

        sessions.projectConversion = EditCancellation()
        var laterSession: ProjectSession?
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, confirmClose: { session in
            session !== laterSession
        }, reply: { replies.append($0) }), .later)
        let newFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cut")
        defer { try? FileManager.default.removeItem(at: newFile) }
        try makeProject(angle: "second").save(to: newFile)
        sessions.openProject(newFile, in: nil)
        let added = try XCTUnwrap(sessions.project(at: newFile))
        laterSession = added
        try await waitForProject(added.multicam)
        added.multicam.updateSource("second") { $0.name = "Keep me" }
        sessions.finishProjectConversion()
        XCTAssertEqual(replies, [false, false])
    }

    @MainActor
    func testDirectAppKitCloseLeavesUntitledProjectRecoverable() async throws {
        _ = NSApplication.shared
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let binding = ProjectWindowBinding.WindowView()
        binding.session = session
        binding.sessions = sessions
        window.contentView = binding
        sessions.register(session, window: window)
        let delegate = try XCTUnwrap(window.delegate)
        binding.applyDocumentState()
        window.contentView = NSView()
        XCTAssertTrue(window.delegate === delegate)
        let deadline = ContinuousClock.now + .seconds(10)
        defer { if sessions.sessions[session.id] != nil { sessions.windowClosed(session) }; window.orderOut(nil) }
        let media = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        session.editor.importFiles([media])
        while session.editor.isImporting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let draftFile = try XCTUnwrap(session.editor.draft.url)
        defer { try? FileManager.default.removeItem(at: draftFile.deletingLastPathComponent()) }
        XCTAssertTrue(session.editor.isProjectChanged)
        // AppKit's close() skips windowShouldClose; performClose() asks first.
        window.close()
        XCTAssertNil(sessions.sessions[session.id])
        let flushDeadline = ContinuousClock.now + .seconds(10)
        func isRecoverable() throws -> Bool {
            try ProjectDraft.recoverable().contains { ProjectSessions.sameFile($0, draftFile) }
        }
        while try !isRecoverable(), ContinuousClock.now < flushDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try isRecoverable())
        let recovered = try CutProject.loadDocument(from: draftFile, limit: 1)
        XCTAssertEqual(recovered.undo.map(\.action), ["Add Clip"])
    }

    @MainActor
    func testQuittingCanLeaveConversionRunningOrWaitForCleanup() {
        let sessions = ProjectSessions(preferences: EditorPreferences())
        let token = EditCancellation()
        sessions.projectConversion = token
        var replies: [Bool] = []
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { false }, reply: { replies.append($0) }), .cancel)
        XCTAssertFalse(token.isCancelled)
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, reply: { replies.append($0) }), .later)
        XCTAssertTrue(token.isCancelled)
        XCTAssertTrue(sessions.isCancellingProject)
        XCTAssertTrue(replies.isEmpty)
        sessions.finishProjectConversion()
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(sessions.isConvertingProject)
        XCTAssertFalse(sessions.isCancellingProject)
    }

    @MainActor
    func testQuitWaitsForMCPOutputCleanupEvenWithNoOpenWindows() async throws {
        let sessions = ProjectSessions(preferences: EditorPreferences())
        var cleaned = false
        _ = try sessions.mcpOutputJobs.start(owner: "test-window/generation", revision: 1,
                                              finished: { cleaned = true }) { _ in
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            throw CancellationError()
        }
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { false }, reply: { _ in XCTFail() }), .cancel)
        XCTAssertTrue(sessions.mcpOutputJobs.hasRunningJobs)
        XCTAssertFalse(sessions.isDrainingMCPForQuit)

        let canQuit = expectation(description: "Editor can terminate after workers clean up")
        let decision = sessions.prepareToQuit(stopExports: { true }, reply: { allowed in
            XCTAssertTrue(allowed)
            XCTAssertTrue(cleaned)
            XCTAssertFalse(sessions.mcpOutputJobs.hasRunningJobs)
            canQuit.fulfill()
        })
        XCTAssertEqual(decision, .later)
        XCTAssertTrue(sessions.isDrainingMCPForQuit)
        await fulfillment(of: [canQuit], timeout: 5)
        XCTAssertFalse(sessions.isDrainingMCPForQuit)
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
