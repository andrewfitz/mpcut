import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

final class AuditRegressionTests: XCTestCase {
    private struct TimedOut: Error {}

    func testOpenEventRecognizesCutDocumentsAndPreservesMediaProbing() {
        let folder = FileManager.default.temporaryDirectory
        XCTAssertTrue(isCutDocument(folder.appendingPathComponent("Interview.cut")))
        XCTAssertTrue(isCutDocument(folder.appendingPathComponent("Interview.CUT")))
        XCTAssertFalse(isCutDocument(folder.appendingPathComponent("Interview.json")))
        XCTAssertFalse(isCutDocument(folder.appendingPathComponent("Interview.mov")))
        XCTAssertFalse(isCutDocument(folder.appendingPathComponent("Interview.mov.cutdb")))
    }

    @MainActor
    private func waitUntilIdle(_ model: EditorModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while model.isBusy, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if model.isBusy { throw TimedOut() }
    }

    func testJPEGProgressCountsCompletedPicturesInUnsortedRequest() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                    subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let times = try [2, 0, 2, 1].map { index in
            try XCTUnwrap(media.frames.indices.contains(index) ? media.frames[index].time : nil)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        var completed: [Int] = []
        let report = try JPEGExport.write(media, to: output, selection: .times(times), useSidecar: false,
                                          progress: { count, total in
            XCTAssertEqual(total, times.count)
            completed.append(count)
        })

        XCTAssertEqual(completed, [1, 2, 3, 4])
        XCTAssertEqual(report.frames.map(\.requestedTime), times)
    }

    func testRecentKeysEvictTheLeastRecentlyUsedKey() {
        var recent = RecentKeys<Int>(limit: 3)
        XCTAssertNil(recent.use(1))
        XCTAssertNil(recent.use(2))
        XCTAssertNil(recent.use(3))
        // A window that is drawn again outlives one that only finished decoding later.
        XCTAssertNil(recent.use(1))
        XCTAssertEqual(recent.use(4), 2)
        XCTAssertEqual(recent.keys, [3, 1, 4])
        XCTAssertNil(recent.use(4))
        XCTAssertEqual(recent.use(5), 3)
        recent.removeAll { $0 == 1 }
        XCTAssertEqual(recent.keys, [4, 5])
    }

    @MainActor
    func testFilmstripLoadsAgainWhenARemovedSourceReturns() async throws {
        _ = NSApplication.shared
        let clip = TimelineClip(id: UUID(), sourceID: UUID(), name: "Clip", sourceStart: 0, sourceEnd: 10,
                                sourceDuration: 10, keyframes: [0], thumbnailSyncTimes: [0], frames: [],
                                displaySize: CGSize(width: 160, height: 90))
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 1100, height: 342))
        surface.viewportWidth = surface.bounds.width
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8,
                                              bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let picture = try XCTUnwrap(context.makeImage())
        var removed = true, requests = 0
        func state(_ clips: [TimelineClip]) -> SequenceTimeline {
            var view = SequenceTimeline(clips: clips, playhead: 0, selection: nil,
                                        thumbnailHeight: clip.thumbnailHeight,
                                        onSelect: { _ in }, onSeek: { _ in }, onTrim: { _, _, _, _ in nil },
                                        onMove: { _, _ in }, onDrop: { _, _ in })
            view.thumbnail = { _, _, _ in
                requests += 1
                return removed ? nil : picture
            }
            return view
        }
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        // The model has already dropped the source, so every tile request fails.
        surface.timeline = state([clip])
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        for _ in 0..<50 where requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        let failed = requests
        XCTAssertGreaterThan(failed, 0)
        surface.timeline = state([])
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        removed = false
        surface.timeline = state([clip])
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        for _ in 0..<50 where requests == failed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(requests, failed, "Undo restores the same source and tile keys.")
    }

    @MainActor
    func testViewerKeepsTheDraggedClipOnScreenUntilRelease() throws {
        let canvas = AudioWaveformCanvas(frame: CGRect(x: 0, y: 0, width: 564, height: 230))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        func audio(_ name: String, _ from: Double) -> TimelineClip {
            TimelineClip(id: UUID(), sourceID: UUID(), name: name, sourceStart: from, sourceEnd: from + 1,
                         sourceDuration: from + 1, keyframes: [], thumbnailSyncTimes: [], frames: [], isAudioOnly: true)
        }
        let first = audio("First", 2), second = audio("Second", 24)
        let store = AudioEnvelopeStore()
        var scrubs: [Double] = []
        func show(_ clip: TimelineClip, offset: Double) {
            canvas.set(AudioWaveformViewer(clip: clip, offset: offset, sourceTime: clip.sourceStart, zoom: 0,
                                           revision: 0, store: store, coarse: nil, pauses: [],
                                           markIn: nil, markOut: nil, enabled: true,
                                           seek: { _ in }, scrub: { scrubs.append($0) }, endScrub: {}))
        }
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            let point = canvas.convert(CGPoint(x: x, y: 120), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: 1, pressure: 1))
        }
        show(first, offset: 0)
        canvas.mouseDown(with: try mouse(.leftMouseDown, x: 544))
        show(second, offset: 1)
        XCTAssertEqual(canvas.accessibilityHelp(), "Seek or drag to scrub First")
        XCTAssertEqual(canvas.accessibilityValue() as? String, timelineTime(3, milliseconds: true))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, x: 294))
        XCTAssertEqual(scrubs, [0.5])
        canvas.mouseUp(with: try mouse(.leftMouseUp, x: 294))
        XCTAssertEqual(canvas.accessibilityHelp(), "Seek or drag to scrub Second")
    }

    @MainActor
    func testUndoRestoresTheChosenCopyContainerAfterDeletingTheLastClip() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([url])
        try await waitUntilIdle(model)
        model.preferCopyContainer("mkv")
        XCTAssertEqual(model.preferredCopyContainer, "mkv")
        model.select(try XCTUnwrap(model.timelineClips.first?.id))
        model.deleteSelection()
        try await waitUntilIdle(model)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.preferredCopyContainer)
        model.undo()
        XCTAssertEqual(model.timelineClips.count, 1)
        XCTAssertEqual(model.preferredCopyContainer, "mkv")
        model.redo()
        XCTAssertNil(model.preferredCopyContainer)
        model.undo()
        XCTAssertEqual(model.preferredCopyContainer, "mkv")
    }

    @MainActor
    func testAcceptedExportStartsDespiteANoticeRaisedWhileThePanelWasOpen() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([url])
        try await waitUntilIdle(model)
        let source = try XCTUnwrap(model.jpegSourceAtPlayhead)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        model.alert = EditorNotice(title: "Couldn’t Save Analysis Sidecars", message: "The folder is read-only.")
        model.exportJPEGFrames(source, to: output, options: JPEGExportOptions())
        XCTAssertTrue(model.isExporting)
        // A second accepted panel cannot start another export.
        model.exportJPEGFrames(source, to: output.appendingPathExtension("again"), options: JPEGExportOptions())
        try await waitUntilIdle(model)
        XCTAssertEqual(model.lastExportedURL, output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("again").path))
    }
}
