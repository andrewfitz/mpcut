import AppKit
import SwiftUI
import XCTest
@testable import MPCutApp

final class TimelineDisplayTests: XCTestCase {
    private func clip(size: CGSize) -> TimelineClip {
        TimelineClip(id: UUID(), sourceID: UUID(), name: "Clip", sourceStart: 0, sourceEnd: 10,
                     sourceDuration: 10, keyframes: [0], thumbnailSyncTimes: [0], frames: [],
                     displaySize: size)
    }

    @MainActor
    func testAccessibilityFramesMatchTheFlippedTimelineGeometry() throws {
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 600, height: 119))
        surface.viewportWidth = 600
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 119), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = surface
        surface.timeline = timeline([clip(size: .zero)])
        let children = try XCTUnwrap(surface.accessibilityChildren() as? [NSAccessibilityElement])
        let top = window.convertToScreen(surface.convert(surface.bounds, to: nil)).maxY
        let ruler = children[0].accessibilityFrame()
        XCTAssertEqual(ruler.maxY, top, accuracy: 0.5)
        XCTAssertEqual(ruler.height, 31, accuracy: 0.5)
        let clip = children[1].accessibilityFrame()
        XCTAssertLessThanOrEqual(clip.maxY, ruler.minY + 0.5)
        let center = NSPoint(x: clip.midX, y: clip.midY)
        XCTAssertTrue(surface.accessibilityHitTest(center) as AnyObject === children[1])
    }

    @MainActor
    private func timeline(_ clips: [TimelineClip], at time: Double = 0) -> SequenceTimeline {
        SequenceTimeline(clips: clips, playhead: time, selection: nil,
                         thumbnailHeight: clips.map(\.thumbnailHeight).max() ?? TimelineClip.minimumThumbnailHeight,
                         onSelect: { _ in }, onSeek: { _ in }, onTrim: { _, _, _, _ in nil },
                         onMove: { _, _ in }, onDrop: { _, _ in })
    }

    @MainActor
    func testSubmittingUnchangedTimePreservesAnExactNTSCFrame() {
        let frame = 1001.0 / 30_000
        XCTAssertEqual(SequenceTimeline.parseTime("00:00.033", initialTime: frame), frame)
        XCTAssertEqual(SequenceTimeline.parseTime("00:00.034", initialTime: frame), 0.034)
    }

    @MainActor
    func testRulerDragSendsScrubPositionsAndStopsOnceOnRelease() throws {
        _ = NSApplication.shared
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 500, height: 119))
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.viewportWidth = 500
        var state = timeline([clip(size: .zero)])
        var points: [Double] = []
        var stops = 0
        state.onScrub = { points.append($0) }
        state.onEndScrub = { stops += 1 }
        surface.timeline = state
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            let point = surface.convert(NSPoint(x: x, y: 10), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try event(.leftMouseDown, 40))
        surface.mouseDragged(with: try event(.leftMouseDragged, 160))
        surface.mouseDragged(with: try event(.leftMouseDragged, 100))
        surface.mouseUp(with: try event(.leftMouseUp, 100))
        XCTAssertEqual(points.count, 2)
        if points.count == 2 { XCTAssertGreaterThan(points[0], points[1]) }
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    func testPlaybackMovesPlayheadWithoutInvalidatingFilmstrip() throws {
        _ = NSApplication.shared
        let scroll = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 119))
        let window = NSWindow(contentRect: scroll.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.documentView = scroll.surface
        let clips = [clip(size: CGSize(width: 1920, height: 1080))]
        scroll.surface.timeline = timeline(clips)
        scroll.resizeDocument()
        let overlay = try XCTUnwrap(scroll.subviews.first { !$0.isHidden && $0.frame.width == 10 })
        let firstX = overlay.frame.midX
        scroll.displayIfNeeded()
        scroll.surface.needsDisplay = false
        for step in 1...60 {
            scroll.surface.timeline = timeline(clips, at: Double(step) / 60)
            scroll.resizeDocument()
        }
        XCTAssertGreaterThan(overlay.frame.midX, firstX)
        XCTAssertFalse(scroll.surface.needsDisplay)
        XCTAssertNil(overlay.hitTest(.zero))
    }

    @MainActor
    func testZoomedTimelineFollowsVisiblePlayheadAndRespectsManualScroll() {
        _ = NSApplication.shared
        let scroll = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 119))
        let window = NSWindow(contentRect: scroll.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.documentView = scroll.surface
        let clips = [clip(size: .zero)]
        scroll.surface.timeline = timeline(clips)
        scroll.surface.zoom = 4
        scroll.resizeDocument()

        scroll.surface.timeline = timeline(clips, at: 3)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        scroll.scrollHorizontally(to: 0)
        scroll.surface.timeline = timeline(clips, at: 3.1)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
    }

    @MainActor
    func testAccessibleTrimUsesSourceTimeAndHonorsBusyState() throws {
        let first = clip(size: .zero)
        let source = TimelineClip(id: UUID(), sourceID: UUID(), name: "Trimmed", sourceStart: 2,
                                  sourceEnd: 8, sourceDuration: 10, keyframes: [], thumbnailSyncTimes: [], frames: [])
        var calls: [Double] = []
        let surface = TimelineSurface(frame: .zero)
        surface.timeline = SequenceTimeline(clips: [first, source], playhead: 11.5, selection: source.id,
                                            onSelect: { _ in }, onSeek: { _ in },
                                            onTrim: { id, _, time, commit in
                                                XCTAssertEqual(id, source.id)
                                                XCTAssertTrue(commit)
                                                calls.append(time)
                                                return time
                                            }, onMove: { _, _ in }, onDrop: { _, _ in })
        let child = try XCTUnwrap(surface.accessibilityChildren()?.last as? NSAccessibilityElement)
        let actions = try XCTUnwrap(child.accessibilityCustomActions())
        let trimEnd = try XCTUnwrap(actions.first { $0.name == "Trim end to playhead" }?.handler)
        XCTAssertTrue(trimEnd())
        let restoreStart = try XCTUnwrap(actions.first { $0.name == "Restore original start" }?.handler)
        XCTAssertTrue(restoreStart())
        let restoreEnd = try XCTUnwrap(actions.first { $0.name == "Restore original end" }?.handler)
        XCTAssertTrue(restoreEnd())
        surface.isEditingEnabled = false
        XCTAssertFalse(trimEnd())
        XCTAssertEqual(calls, [3.5, 0, 10])
    }

    @MainActor
    func testFilmstripFillsTheVisibleClipWhileIndexing() async throws {
        _ = NSApplication.shared
        var clip = clip(size: CGSize(width: 90, height: 160))
        clip.isIndexed = false
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 1100, height: 342))
        surface.viewportWidth = surface.bounds.width
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        let context = try XCTUnwrap(CGContext(data: nil, width: 90, height: 160, bitsPerComponent: 8,
                                              bytesPerRow: 360, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let picture = try XCTUnwrap(context.makeImage())
        var requests: [(Double, CGSize)] = []
        func state() -> SequenceTimeline {
            var view = timeline([clip])
            view.largeThumbnails = .constant(true)
            view.thumbnailHeight = clip.thumbnailHeight(large: true)
            view.thumbnail = { _, time, size in
                requests.append((time, size))
                return picture
            }
            return view
        }
        surface.timeline = state()
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        // 1,068 points of footage divided into tiles near 162 points wide.
        for _ in 0..<50 where requests.count < 7 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(requests.first?.0, 0)
        XCTAssertGreaterThan(requests.last?.0 ?? 0, 8)
        XCTAssertEqual(requests.first?.1.width, TimelineClip.largeTileWidth * window.backingScaleFactor)
        XCTAssertGreaterThan(clip.thumbnailHeight(large: true), clip.thumbnailHeight)

        clip.isIndexed = true
        surface.timeline = state()
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        for _ in 0..<50 where requests.count <= 7 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(requests.count, 7)
    }

    @MainActor
    func testFinalFilmstripThumbnailMatchesTheFirstInAnUnevenClipWidth() async throws {
        _ = NSApplication.shared
        let portrait = clip(size: CGSize(width: 90, height: 160))
        // The old fixed-width grid left only 32 points for the final picture.
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 432, height: 251))
        surface.viewportWidth = surface.bounds.width
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        let context = try XCTUnwrap(CGContext(data: nil, width: 90, height: 160, bitsPerComponent: 8,
                                               bytesPerRow: 360, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
        let picture = try XCTUnwrap(context.makeImage())
        var state = timeline([portrait])
        var requests = 0
        state.thumbnail = { _, _, _ in
            requests += 1
            return picture
        }
        surface.timeline = state
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        for _ in 0..<50 where requests < 4 { try await Task.sleep(for: .milliseconds(10)) }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)

        func redHeight(at point: CGFloat) -> Int {
            let x = Int(point * CGFloat(bitmap.pixelsWide) / surface.bounds.width)
            return (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: x, y: $0)?.usingColorSpace(.deviceRGB) }
                .filter { $0.redComponent - max($0.greenComponent, $0.blueComponent) > 0.35 }.count
        }
        let first = redHeight(at: 66)
        let last = redHeight(at: 400)
        XCTAssertGreaterThan(first, 100)
        XCTAssertEqual(Double(last), Double(first), accuracy: 2)
    }

    @MainActor
    func testTallFilmstripPreservesTopAndBottomOfPortraitFrame() async throws {
        _ = NSApplication.shared
        let portrait = clip(size: CGSize(width: 90, height: 160))
        let landscape = clip(size: CGSize(width: 160, height: 90))
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 480, height: 251))
        surface.viewportWidth = 480
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        var state = timeline([portrait, landscape])
        XCTAssertEqual(state.thumbnailHeight, 164)
        let context = try XCTUnwrap(CGContext(data: nil, width: 90, height: 160, bitsPerComponent: 8,
                                              bytesPerRow: 360, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 90, height: 15))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 145, width: 90, height: 15))
        let image = try XCTUnwrap(context.makeImage())
        var requestedSize: CGSize?
        state.thumbnail = { id, _, size in
            if id == portrait.sourceID { requestedSize = size }
            return image
        }
        surface.timeline = state
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        for _ in 0..<25 where requestedSize == nil { try await Task.sleep(for: .milliseconds(10)) }
        let size = try XCTUnwrap(requestedSize)
        XCTAssertGreaterThan(size.height, size.width)
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let column = Int(45 * CGFloat(bitmap.pixelsWide) / surface.bounds.width)
        let colors = (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: column, y: $0)?.usingColorSpace(.deviceRGB) }
        XCTAssertGreaterThan(colors.filter { $0.redComponent - max($0.blueComponent, $0.greenComponent) > 0.35 }.count, 3)
        XCTAssertGreaterThan(colors.filter { $0.blueComponent - max($0.redComponent, $0.greenComponent) > 0.35 }.count, 3)
    }
}
