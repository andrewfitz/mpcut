import AppKit
import Darwin
import MPCutCore
import XCTest
@testable import MPCutApp

final class EditorModelTests: XCTestCase {
    private enum TestError: Error {
        case editTimedOut
    }

    func testFilmstripSamplingRespectsTileBoundsAndHeldPictures() {
        let frames = [0, 4, 10, 14, 19, 20, 26, 30, 34, 40].map {
            RationalTime(numerator: $0, denominator: 10)
        }
        let clip = TimelineClip(id: UUID(), sourceID: UUID(), name: "VFR clip", sourceStart: 1,
                                sourceEnd: 4, sourceDuration: 5, keyframes: [0, 1, 2, 3, 4],
                                thumbnailSyncTimes: [0, 1, 2, 3, 4], frames: frames)
        XCTAssertEqual(clip.thumbnailTime(from: 1, to: 2.9), 2)
        XCTAssertEqual(clip.thumbnailTime(from: 1.1, to: 2), 1.4)
        XCTAssertEqual(clip.thumbnailTime(from: 1.5, to: 1.6), 1.4)
        XCTAssertEqual(clip.thumbnailTime(from: 1.6, to: 1.7), 1.4)
        XCTAssertEqual(clip.thumbnailTime(from: 3.8, to: 4), 3.4)
    }

    @MainActor
    func testSceneSteppingAcrossClipSeamsAndSessionReset() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertTrue(model.canScanScenes)
        XCTAssertFalse(model.canStepScenes)
        model.stepScene(1)
        XCTAssertNil(model.sceneProgress)
        XCTAssertTrue(model.scenesBySource.isEmpty)
        XCTAssertEqual(model.playhead, 0)
        model.scanForScenes()
        XCTAssertNotNil(model.sceneProgress)
        XCTAssertFalse(model.canStepScenes)
        model.cancelSceneAnalysis()
        XCTAssertTrue(model.canScanScenes)
        XCTAssertFalse(model.canStepScenes)
        model.scanForScenes()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.sceneProgress != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.sceneProgress)
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.canScanScenes)
        XCTAssertTrue(model.canStepScenes)
        XCTAssertEqual(model.playhead, 0)
        model.stepScene(1)
        XCTAssertEqual(model.playhead, model.duration / 2, accuracy: 1e-8)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · View A · 1 view")
        let sourceID = try XCTUnwrap(model.timelineClips.first?.sourceID)
        XCTAssertEqual(model.scenesBySource[sourceID], [TimelineScene(start: 0, view: 1)])
        model.setViewName(" Wide ", source: sourceID, view: 1)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · Wide · 1 view")
        model.stepScene(-1)
        XCTAssertEqual(model.playhead, 0)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · Wide · 1 view")
        model.setViewName("", source: sourceID, view: 1)
        XCTAssertEqual(model.currentSceneLabel, "Scene 1/1 · View A · 1 view")
        model.endSession()
        XCTAssertTrue(model.scenesBySource.isEmpty)
        XCTAssertTrue(model.viewNamesBySource.isEmpty)
    }

    func testSceneReportHonorsExactDurationAndCancellation() throws {
        XCTAssertEqual([1, 26, 27, 52, 53, 703].map(SceneView.label(for:)), ["A", "Z", "AA", "AZ", "BA", "AAA"])
        let url = try XCTUnwrap(Bundle.module.url(forResource: "VFR-PTS", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine().inspect(url, keyframes: true)
        let report = try SceneAnalysis.scan(media)
        XCTAssertEqual(report.scenes.first?.start, .zero)
        XCTAssertEqual(report.scenes.last?.end, media.duration)
        for scene in report.scenes {
            XCTAssertTrue(media.frames.contains { $0.time == scene.start })
            XCTAssertEqual(try RationalTime(numerator: scene.startPTS).multiplied(by: report.timeBase),
                           report.origin + scene.start)
        }
        XCTAssertThrowsError(try SceneAnalysis.scan(media, cancelled: { true })) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
    }

    @MainActor
    func testQueueCapturesIndependentTimelineRangesAcrossSourceSeams() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        let frame = RationalTime(numerator: 1001, denominator: 30000)
        model.seek(10 * frame.seconds)
        model.setIn()
        model.seek(14 * frame.seconds)
        model.setOut()
        model.addMarkedRange()
        let first = try XCTUnwrap(model.queuedRanges.first)
        XCTAssertEqual(first.clips.count, 2)
        XCTAssertEqual(first.clips[0].from?.seconds ?? -1, 10 * frame.seconds, accuracy: 1e-8)
        XCTAssertEqual(first.clips[1].to?.seconds ?? -1, 2 * frame.seconds, accuracy: 1e-8)
        XCTAssertFalse(model.canAddMarkedRange)
        model.seek(0)
        model.setIn()
        model.seek(frame.seconds)
        model.setOut()
        model.addMarkedRange()
        XCTAssertEqual(model.queuedRanges.count, 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.showBulkQueue()
        var options = ExportSheetOptions()
        options.copyContainer = "mov"
        model.exportQueuedRanges(to: directory, options: options)
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.lastExportedURL, directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["ProRes-2997-001.mov", "ProRes-2997-002.mov"])
        model.removeQueuedRange(first.id)
        XCTAssertEqual(model.queuedRanges.first?.start, .zero)
        XCTAssertEqual(model.queuedRanges.first?.end, frame)
        model.endSession()
        XCTAssertTrue(model.queuedRanges.isEmpty)
    }

    @MainActor
    func testDragHandlesBackIntoExcludedFootageAfterCommit() async throws {
        _ = NSApplication.shared
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)

        // Two twelve-frame sources, 40 points per frame and a 16-point margin.
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 992, height: 119))
        surface.viewportWidth = 992
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        func refresh() {
            surface.timeline = SequenceTimeline(clips: model.timelineClips, playhead: model.playhead,
                                               selection: model.selectedID, onSelect: model.select,
                                               onSeek: model.seek, onTrim: model.trim, onMove: model.move,
                                               onDrop: { _, _ in }, onCancelTrim: model.cancelTrim)
        }
        func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 60) throws -> NSEvent {
            let location = surface.convert(NSPoint(x: x, y: y), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1))
        }
        func drag(_ from: CGFloat, _ to: CGFloat) async throws {
            surface.mouseDown(with: try mouse(.leftMouseDown, x: from))
            surface.mouseDragged(with: try mouse(.leftMouseDragged, x: to))
            surface.mouseUp(with: try mouse(.leftMouseUp, x: to))
            try await waitForEdit(model)
            XCTAssertNil(model.alert)
            refresh()
        }
        let frame = 1001.0 / 30_000
        refresh()
        try await drag(18, 138)
        try await drag(494, 414)
        XCTAssertEqual(model.timelineClips[0].sourceStart, 3 * frame, accuracy: 1e-9)
        XCTAssertEqual(model.timelineClips[0].sourceEnd, 10 * frame, accuracy: 1e-9)

        // Frame two of the second source now plays at frame nine of the sequence.
        surface.mouseDown(with: try mouse(.leftMouseDown, x: 576, y: 10))
        surface.mouseUp(with: try mouse(.leftMouseUp, x: 576, y: 10))
        XCTAssertEqual(model.playhead, 9 * frame, accuracy: 1e-9)

        // Both restore drags start just outside the kept range, on the faded side.
        try await drag(134, 14)
        try await drag(418, 498)
        XCTAssertEqual(model.timelineClips[0].sourceStart, 0)
        XCTAssertEqual(model.timelineClips[0].sourceEnd, 12 * frame, accuracy: 1e-9)
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)

        try await drag(498, 658)
        XCTAssertEqual(model.timelineClips[1].sourceStart, 4 * frame, accuracy: 1e-9)
        try await drag(654, 494)
        XCTAssertEqual(model.timelineClips[1].sourceStart, 0)
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)
    }

    @MainActor
    func testFrameEditingAndOptInCopySnappingAcrossUndo() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([file])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        let fullDuration = model.duration

        XCTAssertFalse(model.snapToKeyframes)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.285, commit: false), 0.28)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.285, commit: true), 0.28)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0.28)
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 1.285, commit: true), 1.28)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1.28)
        XCTAssertEqual(model.playhead, 0.96, accuracy: 1e-9)

        model.snapToKeyframes = true
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0.28)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1.28)
        XCTAssertNil(model.trim(id, edge: .end, sourceTime: 1.0, commit: true))
        XCTAssertTrue(model.alert?.message.contains("Review Cuts") == true)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1.28)
        model.dismissNotice()
        XCTAssertEqual(model.undoTitle, "Undo Trim Clip")
        model.undo()
        XCTAssertEqual(model.redoTitle, "Redo Trim Clip")
        model.undo()
        XCTAssertTrue(model.snapToKeyframes)
        XCTAssertEqual(model.duration, fullDuration)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.6, commit: false), 1)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.6, commit: true), 1)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 1)
        model.undo()

        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 0.6, commit: false), 1)
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 0.6, commit: true), 1)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1)
        XCTAssertEqual(model.playhead, 0.96, accuracy: 1e-9)
        model.undo()

        model.seek(0.6)
        model.split()
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1)
        model.undo()
        model.snapToKeyframes = false
        model.seek(0.605)
        model.split()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.6)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 0.6)
        model.undo()

        model.seek(0.285)
        model.setIn()
        model.seek(0.605)
        model.setOut()
        XCTAssertEqual(model.deleteTitle, "Delete Marked Range")
        XCTAssertEqual(model.markIn, 0.28)
        XCTAssertEqual(model.markOut, 0.6)
        model.deleteSelection()
        XCTAssertEqual(model.undoTitle, "Undo Delete Marked Range")
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.28)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 0.6)
        model.undo()
        XCTAssertEqual(model.duration, fullDuration)
        XCTAssertEqual(model.markIn, 0.28)
        XCTAssertEqual(model.markOut, 0.6)
    }

    @MainActor
    func testVariableFrameRateUsesPresentationBoundariesForBothHandlesAndMarks() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "VFR-PTS", withExtension: "mp4",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(model.trim(id, edge: .end, sourceTime: 0.34, commit: true), 0.4)
        XCTAssertEqual(model.playhead, 0.2)
        model.undo()
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.34, commit: true), 0.4)
        model.undo()
        model.seek(0.34)
        model.setIn()
        XCTAssertEqual(model.markIn, 0.4)
        model.split()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.4)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 0.4)
    }

    @MainActor
    func testSingleMarkPersistsWhileSeekingAndProtectsSelectedClip() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        model.setIn()
        model.step(1)
        XCTAssertEqual(model.markIn, 0)
        XCTAssertNil(model.markOut)
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertNotNil(model.alert)
        model.dismissNotice()
        model.clearMarks()
        model.setOut()
        let out = model.playhead
        model.seek(0)
        XCTAssertEqual(model.markOut, out)
        XCTAssertNil(model.markIn)
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertNotNil(model.alert)
        model.dismissNotice()
        model.setIn()
        XCTAssertEqual(model.markedRange, 0...out)
        model.clearMarks()
        XCTAssertNil(model.markIn)
        XCTAssertNil(model.markOut)
    }

    @MainActor
    func testFrameStepAndMarkedDeletionAcrossClipJoin() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let frame = 1001.0 / 30_000
        let model = EditorModel()
        defer { model.endSession() }

        model.importFiles([source, source])
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.sourceID, model.timelineClips.last?.sourceID)
        XCTAssertNotEqual(model.timelineClips.first?.id, model.timelineClips.last?.id)
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)

        model.seek(12 * frame)
        model.step(-1)
        XCTAssertEqual(model.playhead, 11 * frame, accuracy: 1e-9)
        model.step(1)
        XCTAssertEqual(model.playhead, 12 * frame, accuracy: 1e-9)
        model.seek(model.duration)
        model.step(-1)
        XCTAssertEqual(model.playhead, 23 * frame, accuracy: 1e-9)

        model.seek(4 * frame)
        model.setIn()
        model.setOut()
        model.deleteSelection()
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.dismissNotice()

        model.seek(15 * frame)
        model.setIn()
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        let left = try XCTUnwrap(model.timelineClips.first)
        let right = try XCTUnwrap(model.timelineClips.last)
        XCTAssertEqual(left.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(left.sourceEnd, 4 * frame, accuracy: 1e-9)
        XCTAssertEqual(right.sourceStart, 3 * frame, accuracy: 1e-9)
        XCTAssertEqual(right.sourceEnd, 12 * frame, accuracy: 1e-9)

        model.undo()
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.markIn), 15 * frame, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.markOut), 4 * frame, accuracy: 1e-9)
        model.redo()
        XCTAssertEqual(model.duration, 13 * frame, accuracy: 1e-9)
        XCTAssertNil(model.markIn)
        XCTAssertNil(model.markOut)
    }

    @MainActor
    func testSplitContinuousWebMWithOpus() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        let originalDuration = model.duration
        let cuts = model.timelineClips.first?.keyframes ?? []
        let cut = try XCTUnwrap(cuts.first(where: { $0 >= 2 }))
        model.seek(cut)
        model.split()
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, cut)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, cut)
        XCTAssertEqual(model.duration, originalDuration)
        let first = try XCTUnwrap(model.timelineClips.first)
        let last = try XCTUnwrap(model.timelineClips.last)
        XCTAssertEqual(model.trim(first.id, edge: .start, sourceTime: 1, commit: true), 1)
        try await waitForEdit(model)
        XCTAssertEqual(model.trim(last.id, edge: .end, sourceTime: 3, commit: true), 3)
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.duration, 2)
        model.move(last.id, to: 0)
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.map(\.id), [last.id, first.id])
    }

    @MainActor
    func testSnapCanRestoreContinuityAcrossAnOffKeyframeWebMSeam() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([file])
        try await waitForEdit(model)
        let originalDuration = model.duration
        model.seek(1.2)
        model.split()
        let left = try XCTUnwrap(model.timelineClips.first)
        XCTAssertEqual(left.sourceEnd, 1.2)
        XCTAssertFalse(left.keyframes.contains(1.2))
        XCTAssertEqual(model.trim(left.id, edge: .end, sourceTime: 0.8, commit: true), 0.8)
        model.snapToKeyframes = true
        XCTAssertEqual(model.trim(left.id, edge: .end, sourceTime: 1.2, commit: true), 1.2)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.duration, originalDuration)
        model.undo()
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 0.8)
    }

    @MainActor
    func testWebMOpusImportAndDeletionCanCreateACopyUnsafeJoin() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.undo()

        model.importFiles([source])
        try await waitForEdit(model)
        model.snapToKeyframes = true
        model.seek(1)
        model.setIn()
        model.seek(2)
        model.setOut()
        model.deleteSelection()
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertTrue(model.alert?.message.contains("Opus track 1") == true)
        model.dismissNotice()

        model.snapToKeyframes = false
        model.deleteSelection()
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.sourceEnd, 1)
        XCTAssertEqual(model.timelineClips.last?.sourceStart, 2)
    }

    @MainActor
    func testSelectingSeventhNTSCClipLandsExactlyAtJoin() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles(Array(repeating: source, count: 8))
        try await waitForEdit(model)

        let surface = TimelineSurface(frame: .zero)
        surface.timeline = SequenceTimeline(clips: model.timelineClips, playhead: model.playhead,
                                             selection: model.selectedID, onSelect: model.select, onSeek: model.seek,
                                             onTrim: model.trim, onMove: model.move, onDrop: { _, _ in })
        // The first accessibility child is the ruler.
        let button = try XCTUnwrap(surface.accessibilityChildren()?[7] as? NSAccessibilityElement)
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(model.playhead, RationalTime(numerator: 6 * 12 * 1001, denominator: 30_000).seconds)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 8)
        XCTAssertEqual(model.selectedID, model.timelineClips[6].id)
    }

    @MainActor
    func testSingleClipPublishesPreviewBeforeItCanBeEdited() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        var provisionalID: UUID?
        let observation = model.$playhead.sink { _ in
            guard model.isImporting, let clip = model.timelineClips.first else { return }
            provisionalID = clip.id
            XCTAssertTrue(clip.frames.isEmpty)
            XCTAssertGreaterThan(model.duration, 0)
            XCTAssertTrue(model.canNavigate)
            XCTAssertFalse(model.canEdit)
            XCTAssertFalse(model.hasHistory)
        }
        defer { observation.cancel() }
        model.importFiles([file])
        try await waitForEdit(model)
        XCTAssertEqual(try XCTUnwrap(provisionalID), model.selectedID)
        XCTAssertFalse(try XCTUnwrap(model.timelineClips.first).frames.isEmpty)
        XCTAssertTrue(model.canEdit)
        XCTAssertNil(model.alert)
        model.undo()
        XCTAssertTrue(model.isEmpty)
    }

    func testPreviewIdentityIgnoresMetadataAndDetectsMediaChanges() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                      subdirectory: "Fixtures"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: fixture, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = CutEngine()
        let provisional = try engine.inspectForPreview(file)
        XCTAssertTrue(provisional.frames.isEmpty)
        XCTAssertEqual(file.path.withCString { chmod($0, 0o600) }, 0)
        let indexed = try engine.inspect(file, keyframes: true, matchingPreview: provisional)
        XCTAssertEqual(provisional.duration, indexed.duration)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertThrowsError(try engine.inspect(file, keyframes: true, matchingPreview: provisional)) {
            XCTAssertEqual(($0 as? CutError)?.code, "source_changed")
        }
    }

    @MainActor
    func testCancellingAnImportDiscardsItsProvisionalClip() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        let observation = model.$playhead.sink { _ in
            if model.isImporting, !model.isEmpty { model.cancelImport() }
        }
        defer { observation.cancel() }
        model.importFiles([file])
        try await waitForEdit(model)
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.hasHistory)
        XCTAssertFalse(model.isCancelling)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testImportManyMatchingClips() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let files = Array(repeating: source, count: 96)
        let model = EditorModel()
        defer { model.endSession() }
        var sawFirstDuringImport = false
        let observation = model.$playhead.sink { _ in
            if model.isImporting && model.timelineClips.count == 1 { sawFirstDuringImport = true }
        }
        defer { observation.cancel() }
        model.importFiles(files)
        try await waitForEdit(model)
        XCTAssertTrue(sawFirstDuringImport)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, files.count)
    }

    @MainActor
    func testMixedBatchKeepsCompatibleClipsAndReportsFailuresInDropOrder() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let incompatible = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                           subdirectory: "Fixtures"))
        let missing = source.deletingLastPathComponent().appendingPathComponent("missing.mov")
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        let original = try XCTUnwrap(model.selectedID)
        model.importFiles([incompatible, source, missing, source], at: 0)
        try await waitForEdit(model)
        let errors = try XCTUnwrap(model.alert).message.components(separatedBy: "\n\n")
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.first?.hasPrefix(incompatible.lastPathComponent) == true)
        XCTAssertTrue(errors.last?.hasPrefix(missing.lastPathComponent) == true)
        XCTAssertEqual(model.timelineClips.count, 3)
        XCTAssertEqual(model.timelineClips.last?.id, original)
        model.dismissNotice()
        model.undo()
        XCTAssertEqual(model.timelineClips.map(\.id), [original])
    }

    @MainActor
    func testOpenAlertBlocksPlainKeyEditsAndUndo() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        model.select(model.timelineClips[0].id)
        model.alert = EditorNotice(title: "Can’t Split Clip", message: "Test")
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.canDelete)
        XCTAssertFalse(model.canUndo)
        model.deleteSelection()
        model.setIn()
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertNil(model.markIn)
        model.dismissNotice()
        XCTAssertTrue(model.canDelete)
        model.deleteSelection()
        XCTAssertEqual(model.timelineClips.count, 1)
    }

    @MainActor
    func testSplitAtAJoinExplainsWhyNothingChanged() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, source])
        try await waitForEdit(model)
        model.seek(model.duration / 2)
        model.split()
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.alert?.title, "Can’t Split Clip")
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testEmptyingTheTimelineForgetsTheChosenCopyContainerButKeepsHistoryVisible() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source])
        try await waitForEdit(model)
        model.preferCopyContainer("mkv")
        XCTAssertEqual(model.preferredCopyContainer, "mkv")
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNotEqual(model.preferredCopyContainer, "mkv")
        XCTAssertTrue(model.hasHistory)
        model.undo()
        XCTAssertEqual(model.timelineClips.count, 1)
    }

    @MainActor
    private func waitForEdit(_ model: EditorModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while model.isBusy, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if model.isBusy {
            throw TestError.editTimedOut
        }
    }
}
