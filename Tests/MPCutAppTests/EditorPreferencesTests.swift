import AppKit
import SwiftUI
import MPCutCore
import XCTest
@testable import MPCutApp

final class EditorPreferencesTests: XCTestCase {
    @MainActor
    func testSteppingFromTypedLimitCommitsOnlyTheFinishedCount() async throws {
        _ = NSApplication.shared
        let settings = EditorPreferences()
        let field = HistoryLimitField(limit: Binding(get: { settings.historyLimit }, set: { settings.historyLimit = $0 }))
        let host = NSHostingView(rootView: field)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        let views = descendants(host)
        let entry = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first)
        let stepper = try XCTUnwrap(views.compactMap { $0 as? NSStepper }.first)
        XCTAssertTrue(window.makeFirstResponder(entry))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("200", replacementRange: editor.selectedRange())
        let deadline = ContinuousClock.now + .seconds(2)
        while entry.stringValue != "200", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        XCTAssertEqual(settings.historyLimit, 50)
        XCTAssertEqual(entry.stringValue, "200")
        // AppKit sends a relative step to the SwiftUI stepper while its neighboring field still owns focus.
        stepper.integerValue += 1
        XCTAssertTrue(stepper.sendAction(try XCTUnwrap(stepper.action), to: stepper.target))
        XCTAssertEqual(settings.historyLimit, 201)

        let stepDeadline = ContinuousClock.now + .seconds(2)
        while entry.stringValue != "201", ContinuousClock.now < stepDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(entry.stringValue, "201")
        XCTAssertTrue(window.makeFirstResponder(entry))
        let currentEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        currentEditor.selectAll(nil)
        currentEditor.insertText("250", replacementRange: currentEditor.selectedRange())
        XCTAssertEqual(currentEditor.string, "250")
        XCTAssertEqual(settings.historyLimit, 201)
        window.isReleasedWhenClosed = false
        window.close()
        XCTAssertEqual(settings.historyLimit, 250)
    }

    @MainActor
    func testHistoryLimitPersistsZeroAndClampsBeforeNotifyingEditors() throws {
        let name = "mpcut.history-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorPreferences(defaults: defaults)
        XCTAssertEqual(settings.historyLimit, 50)
        var observed: [Int] = []
        let observer = settings.observeChanges {
            if $0 == .historyLimit { observed.append(settings.historyLimit) }
        }
        defer { observer.cancel() }

        settings.historyLimit = Int.max
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 500)
        settings.historyLimit = Int.min
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 0)
        settings.historyLimit = -1
        XCTAssertEqual(observed, [500, 0])
        defaults.set(1500, forKey: "historyLimit")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 500)
        XCTAssertEqual(defaults.integer(forKey: "historyLimit"), 500)
        defaults.set("not a count", forKey: "historyLimit")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 50)
        defaults.set(2.5, forKey: "historyLimit")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 50)
        defaults.set(false, forKey: "historyLimit")
        XCTAssertEqual(EditorPreferences(defaults: defaults).historyLimit, 50)
    }

    @MainActor
    func testPreferencesPersistWithoutAnyEditor() throws {
        let name = "mpcut.preferences-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorPreferences(defaults: defaults)
        XCTAssertTrue(settings.useAnalysisSidecars)
        XCTAssertEqual(settings.snapTarget, .off)
        XCTAssertEqual(settings.volume, 1)
        settings.useAnalysisSidecars = false
        settings.defaultExportMode = .copy
        settings.jpegPreset = .full
        settings.isMuted = true
        settings.volume = 0.35

        let reopened = EditorPreferences(defaults: defaults)
        XCTAssertFalse(reopened.useAnalysisSidecars)
        XCTAssertEqual(reopened.defaultExportMode, .copy)
        XCTAssertEqual(reopened.jpegPreset, .full)
        XCTAssertTrue(reopened.isMuted)
        XCTAssertEqual(reopened.volume, 0.35)
    }

    @MainActor
    func testMultipleEditorsUseSharedPreferencesAndKeepSessionState() {
        let settings = EditorPreferences()
        let first = EditorModel(preferences: settings)
        let second = EditorModel(preferences: settings)
        let multicam = MulticamEditorModel(preferences: settings)
        let independent = EditorModel()
        first.timelineZoom = 0.5
        second.skipPauses = true
        multicam.markIn = .init(numerator: 2)

        first.snapTarget = .scenes
        first.largeThumbnails = true
        second.minimumPause = 2
        second.leavePause = 0.25
        multicam.useAnalysisSidecars = false
        settings.defaultExportMode = .copy
        first.preview.isMuted = true
        second.preview.scrubSoundEnabled = false
        multicam.preview.volume = 0.4

        XCTAssertEqual(second.snapTarget, .scenes)
        XCTAssertTrue(second.largeThumbnails)
        XCTAssertTrue(multicam.preferences.largeThumbnails)
        XCTAssertEqual(first.minimumPause, 2)
        XCTAssertEqual(first.leavePause, 0.25)
        XCTAssertFalse(first.useAnalysisSidecars)
        XCTAssertFalse(second.useAnalysisSidecars)
        XCTAssertEqual(second.defaultExportMode, .copy)
        XCTAssertEqual(multicam.preferences.defaultExportMode, .copy)
        XCTAssertTrue(second.preview.isMuted)
        XCTAssertTrue(multicam.preview.isMuted)
        XCTAssertFalse(first.preview.scrubSoundEnabled)
        XCTAssertFalse(multicam.preview.scrubSoundEnabled)
        XCTAssertEqual(first.preview.volume, 0.4)
        XCTAssertEqual(second.preview.volume, 0.4)
        XCTAssertEqual(settings.volume, 0.4)
        XCTAssertEqual(first.timelineZoom, 0.5)
        XCTAssertEqual(second.timelineZoom, 0)
        XCTAssertFalse(first.skipPauses)
        XCTAssertTrue(second.skipPauses)
        XCTAssertEqual(multicam.markIn, .init(numerator: 2))
        XCTAssertTrue(independent.useAnalysisSidecars)
        XCTAssertFalse(independent.preview.isMuted)
    }

    @MainActor
    func testChangingSnapTargetInAnotherWindowPreservesTrimAudition() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Chirp", withExtension: "opus",
                                                     subdirectory: "Fixtures"))
        let settings = EditorPreferences()
        settings.useAnalysisSidecars = false
        let first = EditorModel(preferences: settings)
        let second = EditorModel(preferences: settings)
        defer { first.endSession() }
        first.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(5)
        while first.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(first.isAudioOnly)
        let clip = try XCTUnwrap(first.timelineClips.first)
        let boundary = try XCTUnwrap(first.trim(clip.id, edge: .start, sourceTime: clip.sourceEnd / 2, commit: false))
        XCTAssertEqual(first.audioPreviewSourceTime, boundary)
        XCTAssertEqual(first.playhead, 0)

        second.snapTarget = .keyframes

        XCTAssertEqual(first.snapTarget, .keyframes)
        XCTAssertEqual(first.effectiveSnapTarget, .off)
        XCTAssertEqual(first.audioPreviewSourceTime, boundary)
        XCTAssertEqual(first.playhead, 0)
        XCTAssertEqual(first.timelineClips.first?.sourceStart, 0)
    }
}
