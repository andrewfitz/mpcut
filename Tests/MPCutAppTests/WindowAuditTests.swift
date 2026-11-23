import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class WindowAuditTests: XCTestCase {
    private struct TimedOut: Error {}

    @MainActor
    private func waitUntilIdle(_ model: EditorModel, seconds: Int = 10) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while model.isBusy, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if model.isBusy { throw TimedOut() }
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func makeProject(angle: String) -> MulticamProject {
        MulticamProject(referenceAngle: angle, range: .init(from: .zero, to: .init(numerator: 1)),
                        angles: [.init(id: angle, file: "offline.mov")], audio: .none,
                        switches: [.init(at: .zero, angle: angle)])
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                 backing: .buffered, defer: true)
    }

    @MainActor
    func testSessionWindowForwardsResizeAndFocusAcrossRebindingAndRestoresDelegate() throws {
        final class ResizeDelegate: NSObject, NSWindowDelegate {
            var resizeCount = 0
            var focusCount = 0
            func windowDidBecomeKey(_ notification: Notification) { focusCount += 1 }
            func windowDidResize(_ notification: Notification) { resizeCount += 1 }
            func windowShouldClose(_ sender: NSWindow) -> Bool { false }
        }
        _ = NSApplication.shared
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        let session = sessions.session(for: UUID())
        let first = window(), second = window()
        var original: ResizeDelegate? = ResizeDelegate()
        weak var forwarded = original
        first.delegate = original
        sessions.register(session, window: first)
        let delegate = try XCTUnwrap(first.delegate)
        original = nil
        session.isMulticam = true
        sessions.register(session, window: first)
        XCTAssertTrue(first.delegate === delegate)
        let target = try XCTUnwrap(forwarded)
        let before = target.resizeCount
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
        XCTAssertEqual(target.resizeCount, before + 1)
        let initialFocus = target.focusCount
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        XCTAssertEqual(target.focusCount, initialFocus + 1)
        XCTAssertEqual(delegate.windowShouldClose?(first), false)

        let secondOriginal = ResizeDelegate()
        second.delegate = secondOriginal
        sessions.register(session, window: second)
        XCTAssertTrue(first.delegate === target)
        XCTAssertFalse(second.delegate === delegate)
        sessions.windowClosed(session)
        XCTAssertTrue(second.delegate === secondOriginal)
    }

    // MARK: Sessions

    @MainActor
    func testQuitWaitsForCancelledMulticamWorkFromAClosedWindow() async throws {
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        session.isMulticam = true
        let releaseWorker = DispatchSemaphore(value: 0)
        session.multicam.run("Exporting…", exporting: true) { _, _ in
            releaseWorker.wait()
        } onSuccess: { _ in
            XCTFail("A closed multicam window must discard the export result.")
        }

        sessions.windowClosed(session)
        XCTAssertTrue(sessions.sessions.isEmpty)
        XCTAssertFalse(session.multicam.isBusy)
        var replies: [Bool] = []
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { XCTFail("Already cancelled"); return true },
                                              reply: { replies.append($0) }), .later)
        XCTAssertTrue(replies.isEmpty)
        releaseWorker.signal()
        let deadline = ContinuousClock.now + .seconds(5)
        while replies.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, reply: { _ in XCTFail("No work remains") }), .now)
    }

    @MainActor
    func testPopoverChildWindowKeepsTheEditorCommands() throws {
        _ = NSApplication.shared
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        defer { sessions.windowClosed(session) }
        let editor = window(), popover = window()
        session.window = editor
        editor.addChildWindow(popover, ordered: .above)
        defer { editor.removeChildWindow(popover) }

        let notifications = NotificationCenter.default
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: editor)
        XCTAssertTrue(sessions.commandContext?.session === session)
        // A popover with a text field takes key status from the editor it belongs to.
        notifications.post(name: NSWindow.didResignKeyNotification, object: editor)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: popover)
        XCTAssertTrue(sessions.commandContext?.session === session)
        // A transfer within the same editor must follow the actual key window.
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: editor)
        notifications.post(name: NSWindow.didResignKeyNotification, object: popover)
        XCTAssertTrue(sessions.commandContext?.session === session)
        notifications.post(name: NSWindow.didResignKeyNotification, object: editor)
        XCTAssertNil(sessions.commandContext)
    }

    @MainActor
    func testMediaOpenedWithoutAKeyWindowUsesTheFrontEditor() async throws {
        _ = NSApplication.shared
        var opened: [UUID] = []
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { opened.append($0) })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let blank = try XCTUnwrap(sessions.sessions.values.first)
        let editor = window()
        blank.window = editor
        sessions.orderedWindows = { [self.window(), editor] }
        // Finder can deliver the open event while MPCut is still in the background.
        try XCTSkipIf(NSApp.keyWindow != nil, "Another test left a key window.")
        sessions.openFiles([try fixture("ProRes-2997", "mov")])
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(blank.editor.isImporting)
        try await waitUntilIdle(blank.editor)
        XCTAssertEqual(blank.editor.timelineClips.count, 1)
    }

    @MainActor
    func testProjectReopensThroughSymlinkedFolderRelativeAndCaseVariantPaths() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let document = folder.appendingPathComponent("Interview.cut")
        try makeProject(angle: "wide").save(to: document)
        let alias = base.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)

        var opened: [UUID] = []
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { opened.append($0) })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let blank = try XCTUnwrap(sessions.sessions.values.first)
        sessions.openFiles([document], in: blank)
        XCTAssertEqual(opened.count, 1)
        let variants = [
            alias.appendingPathComponent("Interview.cut"),
            folder.appendingPathComponent("../Shoot/./Interview.cut"),
            URL(fileURLWithPath: "Shoot/Interview.cut", relativeTo: URL(fileURLWithPath: base.path, isDirectory: true)),
            folder.appendingPathComponent("INTERVIEW.CUT"),
        ]
        // While the project is still loading and again once it is open.
        for round in 0..<2 {
            for variant in variants {
                sessions.openFiles([variant])
                XCTAssertEqual(opened.count, 1, "round \(round): \(variant.path)")
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while blank.multicam.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(sessions.sessions.count, 1)
    }

    @MainActor
    func testClosedWindowReleasesItsEditorAndStopsItsImport() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        weak var editor: EditorModel?
        weak var closed: ProjectSession?
        try await {
            XCTAssertTrue(sessions.reopen())
            let session = try XCTUnwrap(sessions.sessions.values.first)
            editor = session.editor
            closed = session
            session.editor.importFiles([try fixture("SmartTrim-GOP", "mp4")])
            try await waitUntilIdle(session.editor)
            XCTAssertEqual(session.editor.timelineClips.count, 1)
            session.editor.scanForScenes()
            session.editor.scanForSilence()
            session.editor.importFiles([try fixture("SmartTrim-GOP", "mp4")])
            XCTAssertTrue(session.editor.isImporting)
            sessions.windowClosed(session)
            XCTAssertFalse(session.editor.isBusy)
            XCTAssertTrue(session.editor.isEmpty)
            XCTAssertNil(session.editor.sceneProgress)
        }()
        XCTAssertTrue(sessions.sessions.isEmpty)
        let deadline = ContinuousClock.now + .seconds(10)
        while editor != nil || !sessions.closingEditors.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sessions.closingEditors.isEmpty)
        XCTAssertNil(closed)
        XCTAssertNil(editor, "A closed window must not keep its editor, decoders and indexes alive.")
    }

    @MainActor
    func testClosingAWindowDuringExportRemovesThePartialOutput() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        let model = session.editor
        model.importFiles([try fixture("ProRes-2997", "mov")])
        try await waitUntilIdle(model)
        let source = try XCTUnwrap(model.jpegSourceAtPlayhead)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let options = JPEGExportOptions()
        options.mode = .scenes
        model.exportJPEGFrames(source, to: output, options: options)
        XCTAssertTrue(model.isExporting)
        XCTAssertFalse(session.confirmClose())
        // The close button and ⌘W are unavailable for as long as closing would be refused.
        let closable = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        session.window = closable
        session.applyCloseState()
        XCTAssertFalse(closable.styleMask.contains(.closable))
        session.isMulticam = true
        session.applyCloseState()
        XCTAssertTrue(closable.styleMask.contains(.closable))
        session.isMulticam = false
        session.applyCloseState()
        XCTAssertFalse(closable.styleMask.contains(.closable))
        // Quit and forced closes bypass the close button.
        sessions.windowClosed(session)
        XCTAssertFalse(model.isExporting)
        XCTAssertTrue(sessions.closingEditors[session.id] === model)
        let deadline = ContinuousClock.now + .seconds(10)
        while !sessions.closingEditors.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sessions.closingEditors.isEmpty)
        XCTAssertNil(model.lastExportedURL)
        XCTAssertTrue(model.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    @MainActor
    func testCancellingTheSavePromptKeepsOtherWindowsExportingAndEveryDirtyWindowIsAsked() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        var opened: [UUID] = []
        let sessions = ProjectSessions(preferences: preferences, openWindow: { opened.append($0) })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let regular = try XCTUnwrap(sessions.sessions.values.first)
        var dirty: [ProjectSession] = []
        for name in ["first", "second"] {
            let document = folder.appendingPathComponent("\(name).cut")
            try makeProject(angle: name).save(to: document)
            sessions.openProject(document, in: nil)
            let session = try XCTUnwrap(sessions.project(at: document))
            let deadline = ContinuousClock.now + .seconds(5)
            while session.multicam.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            session.multicam.updateSource(name) { $0.name = "Edited" }
            XCTAssertTrue(session.multicam.isChanged)
            dirty.append(session)
        }
        XCTAssertFalse(dirty[0] === regular)

        regular.editor.importFiles([try fixture("ProRes-2997", "mov")])
        try await waitUntilIdle(regular.editor)
        let source = try XCTUnwrap(regular.editor.jpegSourceAtPlayhead)
        let output = folder.appendingPathComponent("Frames", isDirectory: true)
        let options = JPEGExportOptions()
        options.mode = .scenes
        regular.editor.exportJPEGFrames(source, to: output, options: options)
        XCTAssertTrue(regular.editor.isExporting)

        var asked: [UUID] = [], replies: [Bool] = []
        let cancelled = sessions.prepareToQuit(stopExports: { true }, confirmClose: {
            asked.append($0.id)
            return false
        }, reply: { replies.append($0) })
        XCTAssertEqual(cancelled, .cancel)
        XCTAssertEqual(asked.count, 1)
        XCTAssertFalse(regular.editor.isCancelling, "Cancel at the save prompt must leave the export running.")
        try await waitUntilIdle(regular.editor)
        XCTAssertEqual(regular.editor.lastExportedURL, output)
        XCTAssertTrue(replies.isEmpty)

        // With nothing left to stop, each dirty window is asked once and one Cancel aborts the quit.
        asked = []
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { XCTFail("no export"); return true },
                                              confirmClose: { asked.append($0.id); return asked.count < 2 },
                                              reply: { replies.append($0) }), .cancel)
        XCTAssertEqual(Set(asked).count, 2)
        XCTAssertTrue(Set(asked).isSubset(of: Set((dirty + [regular]).map(\.id))))
        asked = []
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, confirmClose: { asked.append($0.id); return true },
                                              reply: { replies.append($0) }), .now)
        XCTAssertEqual(asked.count, 3)
        XCTAssertEqual(Set(asked), Set((dirty + [regular]).map(\.id)))

        // Declining to stop an export cancels the quit before any window is asked.
        regular.editor.exportJPEGFrames(source, to: folder.appendingPathComponent("Again", isDirectory: true), options: options)
        asked = []
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { false }, confirmClose: { asked.append($0.id); return true },
                                              reply: { replies.append($0) }), .cancel)
        XCTAssertTrue(asked.isEmpty)
        // Agreeing stops it, waits for the cleanup, and then reports the answer.
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, confirmClose: { asked.append($0.id); return true },
                                              reply: { replies.append($0) }), .later)
        XCTAssertEqual(asked.count, 2)
        let deadline = ContinuousClock.now + .seconds(10)
        while replies.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(regular.editor.isBusy)
    }

    @MainActor
    func testCommandsFollowARealPopoverShownFromTheEditorWindow() throws {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let popover = NSPopover()
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        popover.contentViewController = controller
        popover.animates = false
        popover.show(relativeTo: host.contentView!.bounds, of: host.contentView!, preferredEdge: .maxY)
        defer { popover.close() }
        guard let popoverWindow = controller.view.window else {
            throw XCTSkip("Showing a popover needs a window server.")
        }
        // The command routing relies on AppKit attaching a popover to the window that shows it.
        XCTAssertTrue(popoverWindow.parent === host)
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        defer { sessions.windowClosed(session) }
        session.window = host
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: popoverWindow)
        XCTAssertTrue(sessions.commandContext?.session === session)
    }

    // MARK: Index loader

    @MainActor
    func testTwoWindowsShareOneScanAndOneCanCancelWithoutStoppingTheOther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("camera.mp4")
        try FileManager.default.copyItem(at: try fixture("SmartTrim-GOP", "mp4"), to: file)
        let loader = SourceIndexLoader()
        let key = SourceIndexLoader.Key(url: file, sidecars: false, preview: false)
        var closedWindowResults = 0
        var kept: [Result<SourceIndexLoader.Index, Error>] = []
        // Both subscriptions exist before the scan can report back on the main actor.
        let closeFirst = loader.load(key) { _ in closedWindowResults += 1 }
        _ = loader.load(key) { kept.append($0) }
        closeFirst()
        closeFirst()
        let deadline = ContinuousClock.now + .seconds(10)
        while kept.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(closedWindowResults, 0, "A closed window must not hear from the shared scan.")
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(try XCTUnwrap(kept.first).get().ordinary.hasFullEditIndex)

        // Cancelling the only subscriber leaves the loader usable for the same recording.
        let other = directory.appendingPathComponent("other.mp4")
        try FileManager.default.copyItem(at: file, to: other)
        let otherKey = SourceIndexLoader.Key(url: other, sidecars: false, preview: false)
        let abandon = loader.load(otherKey) { _ in closedWindowResults += 1 }
        abandon()
        let again = try await loader.read(otherKey, token: EditCancellation(), preference: EditCancellation(), progress: { _ in })
        XCTAssertTrue(again.ordinary.hasFullEditIndex)
        XCTAssertEqual(closedWindowResults, 0)

        let cancelled = EditCancellation()
        cancelled.cancel()
        do {
            _ = try await loader.read(otherKey, token: EditCancellation(), preference: cancelled, progress: { _ in })
            XCTFail("A cancelled request must not return an index.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: Preferences

    @MainActor
    func testStoredPreferencesOfTheWrongTypeFallBackOrConvert() throws {
        let name = "mpcut.preferences-audit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // `defaults write` without a type flag stores strings.
        defaults.set("loud", forKey: "playback_preview_volume_fraction")
        defaults.set("NO", forKey: "analysis_sidecar_reuse_enabled")
        defaults.set("false", forKey: "playback_scrub_audio_enabled")
        defaults.set("2.5", forKey: "silence_min_pause_seconds")
        defaults.set(["x"], forKey: "silence_padding_per_side_seconds")
        defaults.set(7, forKey: "export_movie_default_mode")
        defaults.set("sideways", forKey: "timeline_snap_target")
        defaults.set(12, forKey: "export_jpeg_default_preset")
        let settings = EditorPreferences(defaults: defaults)
        XCTAssertEqual(settings.volume, 1, "An unreadable volume must not silence the preview.")
        XCTAssertFalse(settings.useAnalysisSidecars)
        XCTAssertFalse(settings.scrubSoundEnabled)
        XCTAssertEqual(settings.minimumPause, 2.5)
        XCTAssertEqual(settings.padding, 0.2)
        XCTAssertEqual(settings.defaultExportMode, .smart)
        XCTAssertEqual(settings.snapTarget, .off)
        XCTAssertEqual(settings.jpegPreset, .review)

        defaults.set("0.25", forKey: "playback_preview_volume_fraction")
        defaults.set("maybe", forKey: "analysis_sidecar_reuse_enabled")
        defaults.set(-3.0, forKey: "silence_min_pause_seconds")
        defaults.set(Double.infinity, forKey: "silence_padding_per_side_seconds")
        let reopened = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reopened.volume, 0.25)
        XCTAssertTrue(reopened.useAnalysisSidecars)
        XCTAssertEqual(reopened.minimumPause, 1.5)
        XCTAssertEqual(reopened.padding, 0.2)
    }

    // MARK: Editor

    @MainActor
    func testSnapTargetChosenInSettingsAppliesToAPointerPlacedPlayhead() async throws {
        let settings = EditorPreferences()
        settings.useAnalysisSidecars = false
        let own = EditorModel(preferences: settings), other = EditorModel(preferences: settings)
        defer { own.endSession(); other.endSession() }
        for model in [own, other] {
            model.importFiles([try fixture("SmartTrim-GOP", "mp4")])
            try await waitUntilIdle(model)
        }
        let clip = try XCTUnwrap(own.timelineClips.first)
        let keyframes = clip.keyframes
        let target = try XCTUnwrap(clip.frames.map(\.seconds).first { time in
            time > 0.2 && !keyframes.contains { abs($0 - time) < 0.01 }
        })
        // The window's own picker makes the next mark snap.
        own.seekFromPointer(target)
        own.snapTarget = .keyframes
        own.setIn()
        let expected = try XCTUnwrap(own.markIn)
        XCTAssertTrue(keyframes.contains { abs($0 - expected) < 1e-9 })

        settings.snapTarget = .off
        other.seekFromPointer(target)
        XCTAssertEqual(other.playhead, target, accuracy: 1e-9)
        // Settings and other windows change the shared preference directly.
        settings.snapTarget = .keyframes
        other.setIn()
        XCTAssertEqual(other.markIn, expected)
    }
}
