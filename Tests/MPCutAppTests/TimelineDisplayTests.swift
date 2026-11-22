import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

final class TimelineDisplayTests: XCTestCase {
    func testWheelZoomAndPanRespectDeviceAndModifiers() {
        func action(_ x: CGFloat, _ y: CGFloat, precise: Bool = false, inverted: Bool = false,
                    modifiers: NSEvent.ModifierFlags = []) -> TimelineWheelAction? {
            TimelineWheelAction(horizontal: x, vertical: y, precise: precise, inverted: inverted, modifiers: modifiers)
        }
        XCTAssertEqual(action(0, 2), .zoom(0.5))
        XCTAssertEqual(action(0, -2, inverted: true), .zoom(0.5))
        XCTAssertEqual(action(0, -4, precise: true, modifiers: .option), .zoom(-0.05))
        XCTAssertEqual(action(0, -2, modifiers: .command), .pan(32))
        XCTAssertEqual(action(0, 2, inverted: true, modifiers: .command), .pan(-32))
        XCTAssertEqual(action(18, -2, precise: true, modifiers: .command), .pan(-18))
        XCTAssertNil(action(18, -2, precise: true))
        XCTAssertNil(action(0, 2, modifiers: .control))
    }

    private func clip(size: CGSize) -> TimelineClip {
        TimelineClip(id: UUID(), sourceID: UUID(), name: "Clip", sourceStart: 0, sourceEnd: 10,
                     sourceDuration: 10, keyframes: [0], thumbnailSyncTimes: [0], frames: [],
                     displaySize: size)
    }

    func testSharedFilmstripLayoutDividesCoverageEvenly() {
        let strip = TimelineFilmstrip(width: 400, targetWidth: 92)
        XCTAssertEqual(strip.count, 4)
        XCTAssertEqual(strip.tileWidth, 100)
        XCTAssertEqual(strip.visibleTiles(origin: 31, visible: 131..<231), 1..<2)
        XCTAssertEqual(strip.visibleTiles(origin: 31, visible: 429..<500), 3..<4)
        XCTAssertTrue(strip.visibleTiles(origin: 31, visible: 500..<600).isEmpty)
    }

    @MainActor
    func testMulticamTrackWidthReservesSpaceForTimeAtNarrowWidths() {
        XCTAssertEqual(MulticamTimeline.trackWidth(8, available: 960), 106)
        XCTAssertEqual(MulticamTimeline.trackWidth(280, available: 960), 280)
        XCTAssertEqual(MulticamTimeline.trackWidth(800, available: 960), 360)
        XCTAssertEqual(MulticamTimeline.trackWidth(360, available: 310), 148.8, accuracy: 0.001)
        XCTAssertEqual(MulticamTimeline.trackWidth(360, available: 280), 121)
        XCTAssertEqual(MulticamTimeline.trackWidth(.nan, available: 960), 172)
    }

    @MainActor
    private final class MulticamTimelineState: ObservableObject {
        @Published var zoom = 0.0
        @Published var playhead = RationalTime(numerator: 5, denominator: 1)
        var selectedSwitch: RationalTime?
        let thumbnails = MulticamThumbnailService()
    }

    private struct MulticamTimelineFixture: View {
        @ObservedObject var state: MulticamTimelineState

        var body: some View {
            let end = RationalTime(numerator: 10, denominator: 1)
            let project = MulticamProject(referenceAngle: "one", range: .init(from: .zero, to: end),
                                          angles: [.init(id: "one", file: "camera.mov")],
                                          audio: .none, switches: [.init(at: .zero, angle: "one"),
                                                                  .init(at: .init(numerator: 8), angle: "one")])
            MulticamTimeline(project: project, media: [:], playhead: state.playhead,
                             seek: { _ in }, take: { _ in }, moveSwitch: { _, _ in },
                             deleteSwitch: { _ in }, selectSwitch: { _ in },
                             thumbnailService: state.thumbnails, selectedSwitch: state.selectedSwitch, zoom: $state.zoom)
        }
    }

    @MainActor
    func testMulticamRevealsAnExistingSelectionWhenTheZoomedTimelineOpens() async throws {
        _ = NSApplication.shared
        let state = MulticamTimelineState()
        state.zoom = 2
        state.selectedSwitch = .init(numerator: 8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 240),
                              styleMask: .titled, backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MulticamTimelineFixture(state: state))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        func horizontalScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.hasHorizontalScroller { return scroll }
            return view.subviews.lazy.compactMap { horizontalScroll(in: $0) }.first
        }

        for _ in 0..<30 where (horizontalScroll(in: hosting)?.contentView.bounds.minX ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let scroll = try XCTUnwrap(horizontalScroll(in: hosting))
        let visible = scroll.contentView.bounds
        let switchX = 16 + 0.8 * (4 * visible.width - 32)
        XCTAssertTrue((visible.minX...visible.maxX).contains(switchX))
    }

    @MainActor
    func testMulticamZoomAnchorsAndFollowsThePlayheadUntilManualScroll() async throws {
        _ = NSApplication.shared
        let state = MulticamTimelineState()
        let suite = "MulticamTimelineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(230.0, forKey: "multicamTimelineTrackWidth")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 240),
                              styleMask: .titled, backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MulticamTimelineFixture(state: state).defaultAppStorage(defaults))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        func findHorizontalScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.hasHorizontalScroller { return scroll }
            return view.subviews.lazy.compactMap { findHorizontalScroll(in: $0) }.first
        }

        for _ in 0..<30 where findHorizontalScroll(in: hosting) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let scroll = try XCTUnwrap(findHorizontalScroll(in: hosting))
        let viewport = scroll.contentView.bounds.width
        XCTAssertGreaterThan(viewport, 390)
        XCTAssertLessThan(viewport, 420, "The track viewport should respect the saved name column width.")

        state.zoom = 2
        for _ in 0..<30 where scroll.contentView.bounds.minX == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let zoomedOrigin = scroll.contentView.bounds.minX
        XCTAssertEqual(zoomedOrigin, viewport * 1.5, accuracy: 3)
        state.playhead = RationalTime(numerator: 8, denominator: 1)
        for _ in 0..<30 where scroll.contentView.bounds.minX == zoomedOrigin {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, zoomedOrigin)

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(30))
        state.playhead = RationalTime(numerator: 9, denominator: 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)

        scroll.contentView.scroll(to: NSPoint(x: 300, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        state.zoom = 0
        for _ in 0..<30 where scroll.contentView.bounds.minX != 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
    }

    private struct TransportGeometryProbe: NSViewRepresentable {
        final class ProbeView: NSView {}

        func makeNSView(context: Context) -> ProbeView { ProbeView() }
        func updateNSView(_ view: ProbeView, context: Context) {}
    }

    @MainActor
    private final class TimeEntryState: ObservableObject {
        @Published var request = 0
    }

    private struct TimeEntryFixture: View {
        @ObservedObject var state: TimeEntryState

        var body: some View {
            HStack {
                TimelineTimeControl(playhead: 3690, duration: 93_000, durationLabel: "Duration",
                                    request: state.request, seek: { _ in })
                    .layoutPriority(1)
                Color.clear.frame(width: 20, height: 20).background { TransportGeometryProbe() }
                Spacer()
            }
            .frame(width: 730)
        }
    }

    @MainActor
    func testEnteringLongTimelineTimeKeepsAdjacentControlsInPlace() async throws {
        _ = NSApplication.shared
        let state = TimeEntryState()
        let hosting = NSHostingView(rootView: TimeEntryFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }

        let probe = try XCTUnwrap(find(TransportGeometryProbe.ProbeView.self, in: hosting))
        let original = probe.convert(probe.bounds, to: hosting).minX
        state.request += 1
        for _ in 0..<30 where find(NSTextField.self, in: hosting) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(find(NSTextField.self, in: hosting))
        XCTAssertEqual(probe.convert(probe.bounds, to: hosting).minX, original, accuracy: 0.5)
        XCTAssertEqual(TimelineTimeControl.parseTime("25:34:56.789", initialTime: 3690), 92_096.789)
    }

    @MainActor
    func testAssemblyRowsScrollBelowTheTimelineHeaderAndTransport() async throws {
        _ = NSApplication.shared
        let model = MulticamEditorModel()
        let preview = model.preview
        let project = MulticamProject(referenceAngle: "camera-1", range: .init(from: .zero, to: .init(numerator: 10)),
                                      angles: (1...12).map { .init(id: "camera-\($0)", file: "camera-\($0).mov") },
                                      audio: .none, switches: [.init(at: .zero, angle: "camera-1")])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            model.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("layout.cut")
        try project.save(to: url)
        model.openProject(url)
        for _ in 0..<100 where model.project == nil { try await Task.sleep(for: .milliseconds(10)) }
        let installed = try XCTUnwrap(model.project)

        let root = EditorWorkspace(
            viewer: Color.black,
            transport: Color.orange.frame(height: 43).background { TransportGeometryProbe() },
            timeline: MulticamTimeline(project: installed, media: [:], playhead: .zero, seek: { _ in },
                                        take: { _ in }, moveSwitch: { _, _ in }, deleteSwitch: { _ in },
                                        selectSwitch: { _ in }, thumbnailService: model.filmstrip,
                                        assembly: MulticamAssemblyTimeline(model: model, preview: preview))
                .frame(minHeight: 150, idealHeight: 240, maxHeight: .infinity),
            status: Color.gray.frame(height: 32), showsTimeline: true, showsStatus: true, allowsTimelineResize: true)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 730),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = hosting

        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            (view as? T) ?? view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }

        for height in [730, 480] {
            window.setContentSize(NSSize(width: 1060, height: height))
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let split = try XCTUnwrap(descendant(NSSplitView.self, in: hosting))
            let assembly = try XCTUnwrap(descendant(TimelineScrollView.self, in: split))
            let index = try XCTUnwrap(split.arrangedSubviews.firstIndex { assembly.isDescendant(of: $0) })
            let timelinePane = split.arrangedSubviews[index]
            if height == 480, index > 0 {
                split.setPosition(split.bounds.maxY - 150, ofDividerAt: index - 1)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            let transport = try XCTUnwrap(descendant(TransportGeometryProbe.ProbeView.self, in: split))
            let rows = try XCTUnwrap(assembly.superview?.enclosingScrollView)
            let paneFrame = timelinePane.convert(timelinePane.bounds, to: nil)
            let transportFrame = transport.convert(transport.bounds, to: nil)
            XCTAssertEqual(transportFrame.height, 43, accuracy: 1)
            let rowsFrame = rows.convert(rows.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(transportFrame.minY + 1, paneFrame.maxY)
            XCTAssertEqual(paneFrame.maxY - rowsFrame.maxY, 39, accuracy: 2,
                           "The 38-point timeline header must remain above the scrolling rows.")
            XCTAssertGreaterThanOrEqual(rowsFrame.minY + 1, paneFrame.minY)
            XCTAssertGreaterThan(rowsFrame.height, 70, "The assembly row must fit at the minimum split height.")

            let document = try XCTUnwrap(rows.documentView)
            XCTAssertGreaterThan(document.bounds.height, rows.contentView.bounds.height)
            let clip = rows.contentView
            let initialY = clip.bounds.minY
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: initialY + 76))
            rows.reflectScrolledClipView(clip)
            XCTAssertNotEqual(clip.bounds.minY, initialY)
            XCTAssertEqual(rows.convert(rows.bounds, to: nil), rowsFrame)
        }
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
    func testRangeToolCommitsSnappedOrderedBoundsAndClickCollapsesSelection() throws {
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 1032, height: 119))
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.viewportWidth = surface.bounds.width
        var state = timeline([clip(size: .zero)], at: 5)
        var ranges: [ClosedRange<Double>] = []
        var seeks: [Double] = []
        state.pointerTarget = { raw, _ in raw.rounded() }
        state.onRangeSelect = { ranges.append($0...$1) }
        state.onPointerSeek = { seeks.append($0) }
        state.onScrub = { _ in XCTFail("A range drag must not scrub") }
        surface.timeline = state
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            let point = surface.convert(NSPoint(x: x, y: y), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        }
        // Start on the playhead, drag backward, then release beyond the left edge.
        surface.mouseDown(with: try event(.leftMouseDown, 523, 22))
        surface.mouseDragged(with: try event(.leftMouseDragged, 190, 45))
        XCTAssertTrue(ranges.isEmpty)
        let overlay = try XCTUnwrap(surface.subviews.first as? TimelineRangeOverlay)
        let bitmap = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        let pixelScale = CGFloat(bitmap.pixelsWide) / overlay.bounds.width
        let inside = try XCTUnwrap(bitmap.colorAt(x: Int(300 * pixelScale), y: Int(45 * pixelScale)))
        let outside = try XCTUnwrap(bitmap.colorAt(x: Int(800 * pixelScale), y: Int(45 * pixelScale)))
        XCTAssertGreaterThan(inside.alphaComponent, outside.alphaComponent)
        overlay.layer?.displayIfNeeded()
        surface.displayIfNeeded()
        let drawRange = overlay.drawRange
        var layerPaints = 0
        overlay.drawRange = { visible in
            layerPaints += 1
            drawRange?(visible)
        }
        surface.needsDisplay = false
        surface.mouseDragged(with: try event(.leftMouseDragged, 280, 45))
        XCTAssertFalse(surface.needsDisplay)
        overlay.layer?.displayIfNeeded()
        XCTAssertEqual(layerPaints, 1)
        surface.mouseUp(with: try event(.leftMouseUp, -40, 45))
        XCTAssertEqual(ranges, [0...5])
        XCTAssertTrue(seeks.isEmpty)

        surface.mouseDown(with: try event(.leftMouseDown, 238, 55))
        surface.mouseUp(with: try event(.leftMouseUp, 239, 55))
        XCTAssertEqual(ranges, [0...5, 2...2])
        XCTAssertEqual(seeks, [2])

        surface.mouseDown(with: try event(.leftMouseDown, 238, 55))
        surface.mouseDragged(with: try event(.leftMouseDragged, 1300, 55))
        XCTAssertTrue(surface.performKeyEquivalent(with: try escapeKey(window: window)))
        surface.mouseUp(with: try event(.leftMouseUp, 1300, 55))
        XCTAssertEqual(ranges, [0...5, 2...2])
    }

    @MainActor
    func testRangeOverlayShadesKeptClipsAroundTrimmedSourceHandles() throws {
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 1032, height: 119))
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.viewportWidth = surface.bounds.width
        let clips = (0..<2).map { _ in
            TimelineClip(id: UUID(), sourceID: UUID(), name: "Trimmed", sourceStart: 2, sourceEnd: 8,
                         sourceDuration: 10, keyframes: [], thumbnailSyncTimes: [], frames: [])
        }
        var state = timeline(clips)
        state.markIn = 1
        state.markOut = 11
        surface.timeline = state
        let overlay = try XCTUnwrap(surface.subviews.first)
        let bitmap = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        let pixelScale = CGFloat(bitmap.pixelsWide) / overlay.bounds.width
        func alpha(at x: CGFloat) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: Int(x * pixelScale), y: Int(45 * pixelScale))).alphaComponent
        }
        let gap = try alpha(at: 500)
        XCTAssertGreaterThan(try alpha(at: 240), gap)
        XCTAssertGreaterThan(try alpha(at: 700), gap)
    }

    @MainActor
    func testGroupRangeDragContinuesScrollingAndEscapeCancels() async throws {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        let scroller = NSScrollView(frame: frame)
        let surface = MulticamGroupRangeSurface.Surface(frame: NSRect(x: 0, y: 0, width: 2000, height: 120))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scroller
        scroller.documentView = surface
        var ranges: [ClosedRange<RationalTime>] = []
        surface.configuration = MulticamGroupRangeSurface(markIn: nil, markOut: nil, markTop: 28,
                                                           timeAt: { RationalTime(numerator: Int64($0)) },
                                                           positionAt: { CGFloat($0.seconds) },
                                                           commit: { ranges.append($0...$1) })
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 60), modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 1, clickCount: 1, pressure: 1))
        }

        surface.mouseDown(with: try mouse(.leftMouseDown, 120))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, 395))
        let deadline = ContinuousClock.now + .seconds(1)
        while scroller.contentView.bounds.minX < 24, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let origin = scroller.contentView.bounds.minX
        XCTAssertGreaterThanOrEqual(origin, 24)
        XCTAssertTrue(ranges.isEmpty)
        surface.mouseUp(with: try mouse(.leftMouseUp, 395))
        XCTAssertEqual(ranges, [RationalTime(numerator: 120)...RationalTime(numerator: Int64(origin + 395))])

        surface.mouseDown(with: try mouse(.leftMouseDown, 210))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, 150))
        XCTAssertTrue(surface.performKeyEquivalent(with: try escapeKey(window: window)))
        surface.mouseUp(with: try mouse(.leftMouseUp, 135))
        XCTAssertEqual(ranges.count, 1)
    }

    @MainActor
    private func escapeKey(window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53))
    }

    @MainActor
    func testBenchmarkRangeDragAcrossFiftyThousandClips() throws {
        guard ProcessInfo.processInfo.environment["MPCUT_RANGE_DRAG_BENCHMARK"] == "1" else {
            throw XCTSkip("Set MPCUT_RANGE_DRAG_BENCHMARK=1 to time range drag")
        }
        let clipCount = 50_000
        let eventCount = 2_000
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 1032, height: 119))
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.viewportWidth = surface.bounds.width
        var state = timeline((0..<clipCount).map { _ in clip(size: .zero) })
        var range: ClosedRange<Double>?
        state.pointerTarget = { raw, _ in raw.rounded() }
        state.onRangeSelect = { range = $0...$1 }
        surface.timeline = state
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 60), modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let events = try (0..<eventCount).map { index in
            try event(.leftMouseDragged, 16 + 1000 * CGFloat((index * 7919) % 1999) / 1998)
        }
        surface.mouseDown(with: try event(.leftMouseDown, 16))
        let start = ContinuousClock.now
        for event in events { surface.mouseDragged(with: event) }
        let elapsed = start.duration(to: .now)
        surface.mouseUp(with: try event(.leftMouseUp, 1016))
        XCTAssertEqual(range, 0...500_000)
        print("Range drag, \(clipCount) sequence clips and \(eventCount) mouse updates: \(elapsed)")

        // At this zoom the viewport contains ten clips. The isolated layer can be painted
        // into a reusable bitmap without drawing the ruler, thumbnails, or waveform.
        surface.zoom = 5_000
        surface.mouseDown(with: try event(.leftMouseDown, 16))
        surface.mouseDragged(with: events[1])
        let overlay = try XCTUnwrap(surface.subviews.first)
        let bitmap = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        let paintStart = ContinuousClock.now
        for event in events {
            surface.mouseDragged(with: event)
            overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        }
        let paintElapsed = paintStart.duration(to: .now)
        surface.mouseUp(with: try event(.leftMouseUp, 1016))
        XCTAssertEqual(range, 0...100)
        print("Range drag and overlay rasterization, ten visible clips out of \(clipCount), \(eventCount) updates: \(paintElapsed)")
    }

    @MainActor
    func testOffCenterPlayheadGrabPreservesTimeAndDragOffset() throws {
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 1032, height: 119))
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.viewportWidth = surface.bounds.width
        var state = timeline([clip(size: .zero)], at: 5)
        var seeks: [Double] = [], scrubs: [Double] = []
        state.onPointerSeek = { seeks.append($0) }
        state.onScrub = { scrubs.append($0) }
        surface.timeline = state
        func mouse(_ type: NSEvent.EventType, at x: CGFloat) throws -> NSEvent {
            let point = surface.convert(NSPoint(x: x, y: 22), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        }
        // 100 points per second. The five-second playhead is centered at x = 516.
        surface.mouseDown(with: try mouse(.leftMouseDown, at: 523))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, at: 623))
        surface.mouseUp(with: try mouse(.leftMouseUp, at: 623))
        XCTAssertEqual(seeks, [5])
        XCTAssertEqual(scrubs, [6])
    }

    @MainActor
    func testWaveformDrawsAndScrubsCompactRangesAtSourceOffsets() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Scrub-Tone", withExtension: "webm", subdirectory: "Fixtures"))
        let media = try CutEngine().inspectForPreview(url)
        let stream = try XCTUnwrap(media.streams.first { $0.kind == "audio" })
        let wave = try AudioAnalysis.scan(media, stream: stream.index)
        let source = UUID()
        func span(_ from: Int64, _ to: Int64) -> AudioSpan {
            AudioSpan(from: RationalTime(numerator: from, denominator: 100), to: RationalTime(numerator: to, denominator: 100))
        }
        let clips = [span(0, 10), span(30, 50)].map { range in
            TimelineClip(id: UUID(), sourceID: source, name: "Take", sourceStart: range.from.seconds,
                         sourceEnd: range.to.seconds, sourceDuration: media.duration.seconds,
                         keyframes: [], thumbnailSyncTimes: [], frames: [], displayRange: range)
        }
        // 300 visible points cover 300 ms after the gap has been removed.
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 332, height: 150))
        surface.viewportWidth = surface.frame.width
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        var seeks: [Double] = [], scrubs: [Double] = []
        var state = SequenceTimeline(clips: clips, playhead: 0, selection: clips[0].id, showsWaveform: true,
                                     onSelect: { _ in XCTFail("Waveform clicks should seek") }, onSeek: { seeks.append($0) },
                                     onTrim: { _, _, _, _ in XCTFail("Waveform drags should scrub"); return nil },
                                     onMove: { _, _ in XCTFail("Waveform drags should scrub") }, onDrop: { _, _ in },
                                     onScrub: { scrubs.append($0) })
        func render() throws -> NSBitmapImageRep {
            surface.timeline = state
            let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            return bitmap
        }
        let empty = try render()
        state.waveforms = [source: wave]
        state.waveformRevision += 1
        let drawn = try render()
        state.waveformPauses = [source: [span(40, 45)]]
        state.waveformRevision += 1
        let shaded = try render()
        state.waveforms = [:]
        state.waveformRevision += 1
        let shadedBeforePeaks = try render()

        func changedPixels(at point: CGFloat, _ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            let x = Int(point * CGFloat(a.pixelsWide) / surface.bounds.width)
            return (0..<a.pixelsHigh).filter { y in a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) }.count
        }
        let peakPixels = (180...183).map { changedPixels(at: CGFloat($0), empty, drawn) }
        XCTAssertGreaterThan(peakPixels.max() ?? 0, 2)
        XCTAssertGreaterThan(changedPixels(at: 241, drawn, shaded), 20)
        XCTAssertEqual(changedPixels(at: 181, drawn, shaded), 0)
        XCTAssertGreaterThan(changedPixels(at: 241, empty, shadedBeforePeaks), 20)

        func mouse(_ type: NSEvent.EventType, at x: CGFloat) throws -> NSEvent {
            let point = surface.convert(NSPoint(x: x, y: 116), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                    clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try mouse(.leftMouseDown, at: 118))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, at: 241))
        surface.mouseUp(with: try mouse(.leftMouseUp, at: 241))
        XCTAssertEqual(try XCTUnwrap(seeks.first), 0.102, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(scrubs.last), 0.225, accuracy: 1e-8)
    }

    @MainActor
    func testCSVFileDropTargetsClipInsteadOfInsertionSlot() {
        let clips = (0..<2).map { _ in clip(size: CGSize(width: 1920, height: 1080)) }
        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 632, height: 150))
        surface.viewportWidth = surface.frame.width
        var state = timeline(clips)
        var targets: [UUID] = []
        state.onClipCSV = { _, id in targets.append(id) }
        surface.timeline = state
        let csv = URL(fileURLWithPath: "/tmp/selects.CSV")
        for x: CGFloat in [250, 350, 580] {
            XCTAssertTrue(surface.dropFiles([csv], at: NSPoint(x: x, y: 50)))
        }
        XCTAssertFalse(surface.dropFiles([csv], at: .zero))
        XCTAssertFalse(surface.dropFiles([csv, csv], at: NSPoint(x: 350, y: 50)))
        XCTAssertEqual(targets, [clips[0].id, clips[1].id, clips[1].id])
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
        let overlay = try XCTUnwrap(scroll.subviews.first { !$0.isHidden && $0.frame.width == 20 })
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
    func testFilmstripWaitsForTheIndexedClock() async throws {
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
        await Task.yield()
        XCTAssertTrue(requests.isEmpty)
        clip.isIndexed = true
        surface.timeline = state()
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        for _ in 0..<300 where requests.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.first?.0, 0)
        XCTAssertEqual(requests.first?.1.width, TimelineClip.largeTileWidth * window.backingScaleFactor)

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
        for _ in 0..<300 where requests < 4 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(requests, 4, "Expected four filmstrip tile requests within 3 s")
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
        for _ in 0..<300 where requestedSize == nil { try await Task.sleep(for: .milliseconds(10)) }
        let size = try XCTUnwrap(requestedSize, "The portrait clip requested no thumbnail within 3 s")
        XCTAssertGreaterThan(size.height, size.width)
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let column = Int(45 * CGFloat(bitmap.pixelsWide) / surface.bounds.width)
        let colors = (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: column, y: $0)?.usingColorSpace(.deviceRGB) }
        XCTAssertGreaterThan(colors.filter { $0.redComponent - max($0.blueComponent, $0.greenComponent) > 0.35 }.count, 3)
        XCTAssertGreaterThan(colors.filter { $0.blueComponent - max($0.redComponent, $0.greenComponent) > 0.35 }.count, 3)
    }
}
