import AppKit
import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class AudioWaveformDisplayTests: XCTestCase {
    @MainActor
    func testOpeningAudioIsSampledFromTheSelectedTrackAndDiscardedOnClose() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let header = try CutEngine(useSidecar: false).inspectForPreview(url)
        let source = UUID(), store = WaveformStore()
        for ordinal in [0, 1] {
            store.update(sources: [:], track: ordinal, useSidecar: false, opening: (source, header, ordinal))
            XCTAssertNil(store.openingWaveform)
            let deadline = ContinuousClock.now + .seconds(3)
            while store.openingWaveform?.waveform.peaks.last.flatMap({ $0 }) == nil && .now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let preview = try XCTUnwrap(store.openingWaveform)
            XCTAssertEqual(preview.source, source)
            XCTAssertEqual(preview.waveform.range, 0..<header.duration.seconds)
            XCTAssertEqual(preview.waveform.peaks.count, 24)
            XCTAssertGreaterThan(preview.waveform.peaks.compactMap { $0 }.max() ?? 0, 0)
            XCTAssertNil(store.waves[source])
            XCTAssertFalse(store.finished.contains(source))
            XCTAssertTrue(store.completedWaveforms(for: source, media: header).isEmpty)
        }
        store.clear()
        XCTAssertNil(store.openingWaveform)
    }

    @MainActor
    func testVideoTimelineLoadsDetailOnlyAtFineZoomAndReusesTheWindow() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspect(url, keyframes: true)
        let id = UUID(), store = AudioEnvelopeStore()
        store.update(sources: [id: media], track: 0, readSidecars: false)
        let clip = TimelineClip(id: UUID(), sourceID: id, name: "Video", sourceStart: 0, sourceEnd: media.duration.seconds,
                                sourceDuration: media.duration.seconds, keyframes: [], thumbnailSyncTimes: [], frames: [])
        let surface = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 160))
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.viewportWidth = surface.bounds.width
        surface.timeline = SequenceTimeline(clips: [clip], playhead: 0, selection: nil, showsWaveform: true,
            envelopeStore: store, onSelect: { _ in }, onSeek: { _ in }, onTrim: { _, _, _, _ in nil },
            onMove: { _, _ in }, onDrop: { _, _ in })
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        func draw() { surface.cacheDisplay(in: surface.bounds, to: bitmap) }
        draw()
        surface.zoom = 64
        draw()
        surface.zoom = 1
        draw()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.windowRevision, 0)
        XCTAssertTrue(store.completed(for: id, media: media).isEmpty)

        surface.zoom = 64
        draw()
        let deadline = ContinuousClock.now + .seconds(5)
        while store.windowRevision == 0 && .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.windowRevision, 1)
        draw()
        XCTAssertGreaterThan(tealPixels(nearCenterOf: bitmap), 1)
        let detail = try XCTUnwrap(store.envelope(for: id, surface: .timeline(clip.id), from: 0.02, to: 0.04, pixels: 8))
        XCTAssertLessThan(detail.samples.to, media.duration.seconds / 4)
        XCTAssertTrue(detail === store.envelope(for: id, surface: .timeline(UUID()), from: 0.03, to: 0.05, pixels: 8))
        XCTAssertEqual(store.windowRevision, 1)
    }

    @MainActor
    func testDuplicateVisibleRequestsShareWorkWhenTheFirstClipScrollsAway() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspect(url, keyframes: true)
        let id = UUID(), store = AudioEnvelopeStore()
        let first = WaveformSurface.timeline(UUID()), second = WaveformSurface.timeline(UUID())
        store.update(sources: [id: media], track: 0, readSidecars: false)
        XCTAssertNil(store.envelope(for: id, surface: first, from: 0.9, to: 1.1, pixels: 320))
        XCTAssertNil(store.envelope(for: id, surface: second, from: 0.95, to: 1.05, pixels: 160))
        store.setVisibleTimelineSurfaces([second])
        let deadline = ContinuousClock.now + .seconds(5)
        while store.windowRevision == 0 && .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let shared = try XCTUnwrap(store.envelope(for: id, surface: second, from: 0.95, to: 1.05, pixels: 160))
        XCTAssertTrue(shared === store.envelope(for: id, surface: first, from: 0.9, to: 1.1, pixels: 320))
        XCTAssertEqual(store.windowRevision, 1)
        store.update(sources: [id: media], track: 1, readSidecars: false)
        XCTAssertNil(store.envelope(for: id, surface: second, from: 0.95, to: 1.05, pixels: 160))
        store.setVisibleTimelineSurfaces([])
    }

    func testEnvelopeLevelOfDetailPreservesSignedExtrema() throws {
        let lows = (0..<681).map { Float(($0 * 19) % 71 - 59) / 100 }
        let highs = (0..<681).map { Float(($0 * 11) % 37 + 30) / 100 }
        let display = DisplayEnvelope(AudioEnvelope(from: 0, to: 681, low: lows, high: highs))
        for start in stride(from: 0, to: 681, by: 23) {
            for width in [1, 7, 8, 63, 64, 127, 513] {
                let end = min(start + width, 681)
                let result = try XCTUnwrap(display.range(from: Double(start), to: Double(end)))
                XCTAssertEqual(result.0, lows[start..<end].min())
                XCTAssertEqual(result.1, highs[start..<end].max())
            }
        }
        XCTAssertNil(display.range(from: 700, to: 701))
    }

    func testEnvelopeDoesNotBorrowAdjacentSamplesAtRoundedBinEdges() throws {
        let start = 3_600.0
        let step = 1.0 / 48_000
        let display = DisplayEnvelope(AudioEnvelope(from: start, to: start + step * 16,
            low: Array(repeating: 0, count: 16),
            high: [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0]))
        for index in stride(from: 1, to: 16, by: 2) {
            let bin = try XCTUnwrap(display.range(from: start + step * Double(index),
                                                  to: start + step * Double(index + 1)))
            XCTAssertEqual(bin.1, 0, "Adjacent samples leaked into bin \(index)")
        }
    }

    @MainActor
    func testWaveformCachesRejectReplacementWithSameSizeAndTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-wave-swap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (url, value) in [(first, Float(0.25)), (second, Float(-0.75))] {
            let count: AVAudioFrameCount = 4800
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
                buffer.frameLength = count
                for frame in 0..<Int(count) { buffer.floatChannelData![0][frame] = value }
                try file.write(from: buffer)
            }
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        }
        let engine = CutEngine()
        let id = UUID(), store = WaveformStore()
        let original = try engine.inspect(first, keyframes: true)
        store.update(sources: [id: original], track: 0, useSidecar: false)

        func wait(for media: MediaInfo) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while (!store.finished.contains(id) || store.completedEnvelope(for: id, media: media).isEmpty) && .now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(store.finished.contains(id))
        }
        try await wait(for: original)
        XCTAssertEqual(store.waves[id]?.peak(from: 0, to: 0.1), 0.25)

        try FileManager.default.removeItem(at: first)
        try FileManager.default.moveItem(at: second, to: first)
        let updated = try engine.inspect(first, keyframes: true)
        XCTAssertEqual(SceneSourceStamp(media: updated), SceneSourceStamp(media: original))
        XCTAssertTrue(store.completedWaveforms(for: id, media: updated).isEmpty)
        XCTAssertTrue(store.completedEnvelope(for: id, media: updated).isEmpty)
        store.update(sources: [id: updated], track: 0, useSidecar: false)
        try await wait(for: updated)
        XCTAssertEqual(store.waves[id]?.peak(from: 0, to: 0.1), 0.75)
        XCTAssertEqual(store.completedEnvelope(for: id, media: updated).values.first?.low.first, -0.75)
    }

    func testFineWaveformSpanIsIndependentOfRecordingLengthAndTimelineZoom() {
        for zoom in [0.0, 6.0] {
            let last = AudioViewerSpan.ms10.range(from: 300, to: 3900, at: 3900, zoom: zoom)
            XCTAssertEqual(last.upperBound, 3900, accuracy: 1e-10)
            XCTAssertEqual(last.lowerBound, 3899.99, accuracy: 1e-10)
            let inside = AudioViewerSpan.ms10.range(from: 300, to: 3900, at: 3678.423, zoom: zoom)
            XCTAssertTrue(inside.contains(3678.423))
            XCTAssertEqual(inside.upperBound - inside.lowerBound, 0.01, accuracy: 1e-10)
        }
        let follow = AudioViewerSpan.timeline.range(from: 300, to: 3900, at: 500, zoom: 2)
        XCTAssertEqual(follow, 300..<1200)
    }

    @MainActor
    func testAudioSourceDetailIsCachedAndBothSurfacesShowTheWaveform() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-wave-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frameCount: AVAudioFrameCount = 96_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            for i in 0..<Int(frameCount) {
                buffer.floatChannelData![0][i] = Float(0.9 * sin(Double(i) * 2 * .pi / 48))
            }
            try file.write(from: buffer)
        }
        let media = try CutEngine().inspect(url, keyframes: true)
        XCTAssertFalse(media.hasVideo)
        let source = UUID(), store = AudioEnvelopeStore()
        store.update(sources: [source: media], track: 0, readSidecars: false)
        let deadline = ContinuousClock.now + .seconds(6)
        while store.completed(for: source, media: media).isEmpty && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let overview = try XCTUnwrap(store.completed(for: source, media: media).first?.value)
        XCTAssertEqual(overview.low.min() ?? 0, -0.9, accuracy: 0.001)
        store.update(sources: [source: media], track: 1, readSidecars: false)
        XCTAssertNil(store.envelope(for: source, surface: .viewer, from: 0, to: 2, pixels: 10))
        XCTAssertEqual(store.completed(for: source, media: media).values.first?.low, overview.low)
        store.update(sources: [source: media], track: 0, readSidecars: false)
        XCTAssertEqual(store.envelope(for: source, surface: .viewer, from: 0, to: 2, pixels: 10)?.samples.low, overview.low)
        let precision: Double = 1.0 / 48_000
        var detail: DisplayEnvelope?
        repeat {
            detail = store.envelope(for: source, surface: .viewer, from: 1, to: 1.01, pixels: 960)
            if let detail, detail.secondsPerBin <= precision * 1.01 { break }
            try await Task.sleep(for: .milliseconds(10))
        } while .now < deadline
        let finest = try XCTUnwrap(detail)
        XCTAssertLessThanOrEqual(finest.secondsPerBin, precision * 1.01)
        XCTAssertTrue(finest === store.envelope(for: source, surface: .viewer, from: 1.001, to: 1.009, pixels: 700))

        let clip = TimelineClip(id: UUID(), sourceID: source, name: "Recording", sourceStart: 0.5, sourceEnd: 1.5,
                                sourceDuration: 2, keyframes: [], thumbnailSyncTimes: [], frames: [],
                                isAudioOnly: true, audioSampleRate: 48_000)
        let viewer = AudioWaveformCanvas(frame: CGRect(x: 0, y: 0, width: 564, height: 230))
        let window = NSWindow(contentRect: viewer.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = viewer
        var sought: [Double] = []
        viewer.set(AudioWaveformViewer(clip: clip, offset: 3, sourceTime: 0.75, zoom: 0, revision: 1,
                                       store: store, coarse: nil, pauses: [], markIn: nil, markOut: nil, enabled: true,
                                       seek: { sought.append($0) }, scrub: { sought.append($0) }, endScrub: {}))
        let picture = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: picture)
        XCTAssertGreaterThan(tealPixels(nearCenterOf: picture), 40)
        let point = viewer.convert(CGPoint(x: 294, y: 120), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        viewer.mouseDown(with: click)
        XCTAssertEqual(try XCTUnwrap(sought.last), 3.5, accuracy: 0.001)

        let timeline = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView = timeline
        timeline.viewportWidth = 600
        var state = SequenceTimeline(clips: [clip], playhead: 0, selection: nil, thumbnailHeight: 86,
                                     audioOnly: true, envelopeStore: store, onSelect: { _ in }, onSeek: { _ in },
                                     onTrim: { _, _, _, _ in nil }, onMove: { _, _ in }, onDrop: { _, _ in })
        state.thumbnail = { _, _, _ in XCTFail("Audio strips should only request waveform data"); return nil }
        timeline.timeline = state
        let strip = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
        timeline.cacheDisplay(in: timeline.bounds, to: strip)
        XCTAssertGreaterThan(tealPixels(nearCenterOf: strip), 22)
        store.update(sources: [:], track: 0, readSidecars: false)
        XCTAssertTrue(store.completed(for: source, media: media).isEmpty)
    }

    @MainActor
    func testViewerDragKeepsTheClockOfTheClipWhereItStarted() throws {
        let canvas = AudioWaveformCanvas(frame: CGRect(x: 0, y: 0, width: 564, height: 230))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let first = TimelineClip(id: UUID(), sourceID: UUID(), name: "First", sourceStart: 2, sourceEnd: 3,
                                 sourceDuration: 3, keyframes: [], thumbnailSyncTimes: [], frames: [], isAudioOnly: true)
        let second = TimelineClip(id: UUID(), sourceID: UUID(), name: "Second", sourceStart: 24, sourceEnd: 25,
                                  sourceDuration: 25, keyframes: [], thumbnailSyncTimes: [], frames: [], isAudioOnly: true)
        let store = AudioEnvelopeStore()
        var seeks: [Double] = [], scrubs: [Double] = []
        var stops = 0
        func show(_ clip: TimelineClip, offset: Double) {
            canvas.set(AudioWaveformViewer(clip: clip, offset: offset, sourceTime: clip.sourceStart, zoom: 0,
                                           revision: 0, store: store, coarse: nil, pauses: [],
                                           markIn: nil, markOut: nil, enabled: true,
                                           pointerTarget: { time, _ in time == 1 ? 1.006 : time },
                                           seek: { seeks.append($0) }, scrub: { scrubs.append($0) },
                                           endScrub: { stops += 1 }))
        }
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            let point = canvas.convert(CGPoint(x: x, y: 120), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: 1, pressure: 1))
        }
        show(first, offset: 0)
        canvas.mouseDown(with: try mouse(.leftMouseDown, x: 544))
        XCTAssertEqual(seeks, [1])
        // A seek to the join makes the next clip active before the drag event arrives.
        show(second, offset: 1)
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, x: 294))
        canvas.mouseUp(with: try mouse(.leftMouseUp, x: 294))
        XCTAssertEqual(scrubs, [0.5])
        XCTAssertEqual(stops, 1)
    }

    private func tealPixels(nearCenterOf image: NSBitmapImageRep) -> Int {
        let x = image.pixelsWide / 2 + 19
        return (0..<image.pixelsHigh).filter { y in
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.greenComponent - color.redComponent > 0.14 && color.blueComponent - color.redComponent > 0.12
        }.count
    }
}
