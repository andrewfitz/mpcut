import AppKit
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
    func testSmartTrimKeepsExactFramesAndModeAcrossUndo() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([file])
        try await waitForEdit(model)
        let id = try XCTUnwrap(model.selectedID)
        XCTAssertFalse(model.smartTrim)
        XCTAssertTrue(model.canUseSmartTrim)
        model.setSmartTrim(true)
        try await waitForEdit(model)
        XCTAssertTrue(model.smartTrim)
        XCTAssertEqual(model.trim(id, edge: .start, sourceTime: 0.28, commit: true), 0.28)
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0.28)
        model.setSmartTrim(false)
        try await waitForEdit(model)
        XCTAssertNotNil(model.alert)
        XCTAssertTrue(model.smartTrim)
        model.dismissNotice()
        model.undo()
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0)
        model.undo()
        XCTAssertFalse(model.smartTrim)
        model.redo()
        model.redo()
        XCTAssertTrue(model.smartTrim)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0.28)
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
