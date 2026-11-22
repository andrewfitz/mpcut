import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class OpenIssuesAuditTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func waitUntil(seconds: Int = 10, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func closableWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
                 backing: .buffered, defer: true)
    }

    @MainActor
    private func assemblyModel(_ assembly: (MulticamRange) -> [MulticamRange]) throws -> (MulticamEditorModel, [RationalTime], MulticamRange) {
        let url = try fixture("ProRes-2997", "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let model = MulticamEditorModel()
        model.useAnalysisSidecars = false
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path), media: media)],
                           opening: "wide", audio: .none)
        let original = MulticamRange(from: .zero, to: media.duration)
        XCTAssertTrue(model.edit { $0.assembly = assembly(original) })
        model.setAssemblyPreview(true)
        return (model, media.frames.map(\.time), original)
    }

    // MARK: 1. Busy multicam window

    @MainActor
    func testBusyMulticamWindowCannotBeClosedUntilItsWorkEnds() async throws {
        let session = ProjectSession(id: UUID(), preferences: EditorPreferences())
        defer { session.end() }
        let window = closableWindow()
        session.window = window
        session.isMulticam = true
        XCTAssertTrue(window.styleMask.contains(.closable))

        // The window follows the model without waiting for a SwiftUI update.
        let release = DispatchSemaphore(value: 0)
        session.multicam.run("Saving analysis sidecars…") { _, _ in release.wait() } onSuccess: { _ in }
        try await waitUntil(seconds: 2) { !window.styleMask.contains(.closable) }
        // A refused close with an enabled close button gives no feedback.
        XCTAssertFalse(window.styleMask.contains(.closable))
        XCTAssertFalse(session.confirmClose())

        release.signal()
        try await waitUntil(seconds: 5) { window.styleMask.contains(.closable) }
        XCTAssertFalse(session.multicam.isBusy)
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(session.confirmClose())
    }

    // MARK: 3. Waveform failures

    @MainActor
    func testFailedWaveformIsReportedAndRetriedByTheNextScan() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("camera.mov")
        let hidden = directory.appendingPathComponent("hidden.mov")
        try FileManager.default.copyItem(at: try fixture("Pause-Quiet", "mov"), to: url)
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let route = MulticamAudioSelection(source: "wide", stream: stream)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: media.duration),
                                      angles: [.init(id: "wide", file: url.path, audioStream: stream)],
                                      audio: .fixed(route), switches: [.init(at: .zero, angle: "wide")])
        try FileManager.default.moveItem(at: url, to: hidden)

        let analysis = MulticamAnalysisStore()
        defer { analysis.reset() }
        analysis.update(project: project, media: ["wide": media], ordinary: ["wide": media], useSidecars: false)
        try await waitUntil { analysis.status != nil }
        XCTAssertNotNil(analysis.status, "A waveform that could not be read must be reported.")
        XCTAssertNil(analysis.waveform(sourceID: "wide", stream: stream))

        try FileManager.default.moveItem(at: hidden, to: url)
        analysis.scan(.silence)
        try await waitUntil { analysis.waveform(sourceID: "wide", stream: stream) != nil && !analysis.isScanning(.silence) }
        XCTAssertNotNil(analysis.waveform(sourceID: "wide", stream: stream))
        XCTAssertNil(analysis.status)
    }

    // MARK: 4. Duplicate sources

    @MainActor
    func testSourceAddedAgainThroughSymlinkOrCaseVariantPathIsADuplicate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try fixture("ProRes-2997", "mov"), to: folder.appendingPathComponent("camera.mov"))
        let linked = directory.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
        // A reopened project stores the physical path.
        let physical = try XCTUnwrap(realpath(folder.appendingPathComponent("camera.mov").path, nil))
        defer { free(physical) }
        let recording = URL(fileURLWithPath: String(cString: physical))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(recording)

        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: recording.path), media: media)],
                           opening: "wide", audio: .none)
        let variants = [linked.appendingPathComponent("camera.mov"), folder.appendingPathComponent("CAMERA.MOV"),
                        folder.appendingPathComponent("camera.mov")]
        for variant in variants {
            model.importSources([variant])
            XCTAssertFalse(model.isBusy, variant.path)
        }

        let fresh = MulticamEditorModel()
        defer { fresh.reset() }
        fresh.useAnalysisSidecars = false
        fresh.importSources(variants)
        try await waitUntil { !fresh.isBusy }
        XCTAssertEqual(fresh.setup.count, 1)
    }

    // MARK: 5. Assembly playhead

    @MainActor
    func testRemovingAMarkedRangeKeepsThePlayheadOnItsGroupContent() throws {
        let (model, frames, original) = try assemblyModel { [$0] }
        defer { model.reset() }
        model.preview.seek(to: frames[8])
        model.markIn = frames[2]
        model.markOut = frames[5]
        model.removeMarkedRange()
        XCTAssertEqual(model.ranges, [.init(from: .zero, to: frames[2]), .init(from: frames[5], to: original.to)])
        XCTAssertEqual(model.currentGroupTime(), frames[8])
        XCTAssertEqual(model.activeOccurrenceIndex, 1)
        XCTAssertEqual(model.selectedOccurrence, 1)
    }

    @MainActor
    func testRemovingTheRangeUnderThePlayheadMovesItToTheEditPoint() throws {
        let (model, frames, original) = try assemblyModel { [$0] }
        defer { model.reset() }
        model.preview.seek(to: frames[3])
        model.markIn = frames[2]
        model.markOut = frames[5]
        model.removeMarkedRange()
        XCTAssertEqual(model.currentGroupTime(), frames[5])
        XCTAssertEqual(model.activeOccurrenceIndex, 1)

        // Removing the tail under the playhead leaves it at the end of the program.
        model.preview.seek(to: try XCTUnwrap(model.mapping).duration.subtracting(frames[1]))
        let group = model.currentGroupTime()
        model.markIn = try group.subtracting(frames[1])
        model.markOut = original.to
        model.removeMarkedRange()
        XCTAssertEqual(model.preview.currentTime(), model.mapping?.duration)
    }

    @MainActor
    func testRemovingAMarkedRangeKeepsThePlayheadInItsRepeatedOccurrence() throws {
        let (model, frames, original) = try assemblyModel { [$0, $0] }
        defer { model.reset() }
        model.preview.seek(to: try original.to.adding(frames[8]))
        XCTAssertEqual(model.activeOccurrenceIndex, 1)
        model.markIn = frames[2]
        model.markOut = frames[5]
        model.removeMarkedRange()
        XCTAssertEqual(model.ranges.count, 4)
        XCTAssertEqual(model.currentGroupTime(), frames[8])
        XCTAssertEqual(model.activeOccurrenceIndex, 3)

        model.undo()
        model.preview.seek(to: frames[8])
        model.markIn = frames[2]
        model.markOut = frames[5]
        model.removeMarkedRange()
        XCTAssertEqual(model.ranges.count, 4)
        XCTAssertEqual(model.currentGroupTime(), frames[8])
        XCTAssertEqual(model.activeOccurrenceIndex, 1)
    }

    @MainActor
    func testShorteningPausesKeepsThePlayheadOnItsGroupContent() async throws {
        let url = try fixture("Pause-Quiet", "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let model = MulticamEditorModel()
        defer { model.reset() }
        model.useAnalysisSidecars = false
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: url.path, audioStream: stream), media: media)],
                           opening: "wide", audio: .fixed(.init(source: "wide", stream: stream)))
        let whole = try XCTUnwrap(model.project?.range)
        XCTAssertTrue(model.edit { $0.assembly = [whole, whole] })
        model.setAssemblyPreview(true)
        model.configureSilenceAnalysis(minimum: 1, threshold: -45)
        model.scanAnalysis(.silence)
        try await waitUntil { model.canApplyPauses }
        let pauses = model.multicamPausePlan
        let cut = try XCTUnwrap(pauses.last?.removal)
        XCTAssertEqual(pauses.last?.id.occurrence, 1)
        XCTAssertLessThan(cut.to, whole.to)

        // In the second occurrence, on content after the removed pause.
        let after = try XCTUnwrap(model.snappedFrame(cut.to, delta: 1))
        model.preview.seek(to: try whole.to.adding(after))
        XCTAssertEqual(model.currentGroupTime(), after)
        XCTAssertTrue(model.applyMulticamPauses(queueTakes: false, plan: pauses))
        XCTAssertEqual(model.currentGroupTime(), after)
        XCTAssertEqual(model.activeOccurrenceIndex, model.ranges.count - 1)

        // Inside a removed pause the playhead lands on the first content after it.
        model.undo()
        let inside = try XCTUnwrap(model.snappedFrame(cut.from, delta: 1))
        XCTAssertLessThan(inside, cut.to)
        model.preview.seek(to: try whole.to.adding(inside))
        XCTAssertTrue(model.applyMulticamPauses(queueTakes: false, plan: pauses))
        XCTAssertEqual(model.currentGroupTime(), cut.to)
        XCTAssertEqual(model.activeOccurrenceIndex, model.ranges.count - 1)
    }

    // MARK: 2. Dropped projects

    @MainActor
    func testProjectDroppedOnAnEditorOpensAsAProjectAndLeavesTheMediaToImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("Interview.cut")
        let plain = directory.appendingPathComponent("Second.cut")
        for (url, angle) in [(document, "wide"), (plain, "close")] {
            try MulticamProject(referenceAngle: angle, range: .init(from: .zero, to: .init(numerator: 1)),
                                angles: [.init(id: angle, file: "offline.mov")], audio: .none,
                                switches: [.init(at: .zero, angle: angle)]).save(to: url)
        }
        let media = try fixture("ProRes-2997", "mov")

        var opened: [UUID] = []
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { opened.append($0) })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let blank = try XCTUnwrap(sessions.sessions.values.first)

        // A blank editor becomes the project, as it does for File → Open.
        // The project opens once the drag session has ended.
        XCTAssertEqual(sessions.openDroppedProjects([document, media], in: blank), [media])
        try await waitUntil(seconds: 2) { sessions.project(at: document) != nil }
        XCTAssertTrue(sessions.project(at: document) === blank)
        XCTAssertTrue(blank.isMulticam)
        XCTAssertEqual(opened.count, 1)
        try await waitUntil { blank.multicam.project != nil }
        XCTAssertNil(blank.multicam.notice)
        XCTAssertEqual(blank.multicam.project?.referenceAngle, "wide")

        // Dropped on a window that holds a project, another project gets its own window
        // and the one that is already open is not opened twice.
        XCTAssertEqual(sessions.openDroppedProjects([plain, document], in: blank), [])
        try await waitUntil(seconds: 2) { sessions.project(at: plain) != nil }
        XCTAssertEqual(opened.count, 2)
        let second = try XCTUnwrap(sessions.project(at: plain))
        XCTAssertFalse(second === blank)
        XCTAssertEqual(blank.multicam.project?.referenceAngle, "wide")
        XCTAssertEqual(sessions.openDroppedProjects([media], in: blank), [media])
        XCTAssertEqual(opened.count, 2)
    }

    // MARK: 6. Add Clips while a utility window is key

    @MainActor
    func testAddClipsWithoutAnEditorCommandWindowReusesTheFrontEditor() async throws {
        _ = NSApplication.shared
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let blank = try XCTUnwrap(sessions.sessions.values.first)
        let editor = closableWindow(), settings = closableWindow()
        blank.window = editor
        // Settings is in front and key. It belongs to no editor.
        sessions.orderedWindows = { [settings, editor] }
        try XCTSkipIf(NSApp.keyWindow != nil, "Another test left a key window.")
        XCTAssertNil(sessions.commandContext)
        XCTAssertTrue(sessions.clipCommandTarget === blank)

        // An editor that cannot show the picker now leaves the command to a new window.
        sessions.openFiles([try fixture("ProRes-2997", "mov")], in: blank)
        XCTAssertTrue(blank.editor.isImporting)
        XCTAssertNil(sessions.clipCommandTarget)
        try await waitUntil { !blank.editor.isBusy }
        XCTAssertTrue(sessions.clipCommandTarget === blank)
        blank.isMulticam = true
        XCTAssertNil(sessions.clipCommandTarget)
    }

    // MARK: 8. Snap picker in an audio-only window

    @MainActor
    func testAudioOnlySnapPickerDoesNotReplaceTheSharedPictureTarget() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.snapTarget = .keyframes
        let editor = EditorModel(preferences: preferences)
        defer { editor.endSession() }
        editor.importFiles([try fixture("Standalone-Chirp", "opus")])
        try await waitUntil { !editor.isBusy && !editor.isEmpty }
        XCTAssertTrue(editor.isAudioOnly)
        XCTAssertEqual(editor.effectiveSnapTarget, .off)

        // The picker shows Off as a fallback. Choosing it again is not a new choice.
        editor.chooseSnapTarget(.off)
        XCTAssertEqual(preferences.snapTarget, .keyframes)
        editor.chooseSnapTarget(.silence)
        XCTAssertEqual(preferences.snapTarget, .silence)
        editor.chooseSnapTarget(.off)
        XCTAssertEqual(preferences.snapTarget, .off)
    }

    // MARK: 7. Media opened while the editor is busy

    @MainActor
    func testMediaOpenedWhileTheEditorIsImportingJoinsItsTimeline() async throws {
        var opened: [UUID] = []
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { opened.append($0) })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        let media = try fixture("ProRes-2997", "mov")
        sessions.openFiles([media], in: session)
        XCTAssertTrue(session.editor.isImporting)
        // Finder can deliver a second open event before the first import ends.
        sessions.openFiles([media], in: session)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(sessions.sessions.count, 1)
        try await waitUntil { !session.editor.isBusy && session.editor.timelineClips.count == 2 }
        XCTAssertEqual(session.editor.timelineClips.count, 2)
    }
}
