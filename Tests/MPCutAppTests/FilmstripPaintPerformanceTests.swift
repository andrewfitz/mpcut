import AppKit
import Darwin
import XCTest
@testable import MPCutApp

final class FilmstripPaintPerformanceTests: XCTestCase {
    @MainActor
    func testDirtyFilmstripPaint() async throws {
        guard ProcessInfo.processInfo.environment["MPCUT_FILMSTRIP_PAINT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set MPCUT_FILMSTRIP_PAINT_BENCHMARK=1 to measure filmstrip paint")
        }
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 3840, height: 110)
        let surface = TimelineSurface(frame: bounds)
        surface.viewportWidth = bounds.width
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        let backingScale = window.backingScaleFactor
        let size = CGSize(width: 160, height: 90)
        let syncTimes = (0..<7200).map(Double.init)
        let clips = (0..<12).map { _ in
            TimelineClip(id: UUID(), sourceID: UUID(), name: "Recording", sourceStart: 0,
                         sourceEnd: 7200, sourceDuration: 7200, keyframes: syncTimes,
                         thumbnailSyncTimes: syncTimes, frames: [], displaySize: size)
        }
        let expectedTimes: [Double] = [900, 2700, 4500, 6300]
        let thumbnailHeight = clips[0].thumbnailHeight
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8,
                                              bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let thumbnail = try XCTUnwrap(context.makeImage())
        let started = ContinuousClock.now
        var arrivals = [Double]()
        var requests = [(UUID, Double)]()
        surface.timeline = SequenceTimeline(
            clips: clips, playhead: 0, selection: nil, thumbnailHeight: thumbnailHeight,
            onSelect: { _ in }, onSeek: { _ in }, onTrim: { _, _, _, _ in nil },
            onMove: { _, _ in }, onDrop: { _, _ in }, thumbnail: { id, time, requestedSize in
                XCTAssertEqual(requestedSize.width, TimelineClip.tileWidth * backingScale)
                XCTAssertEqual(requestedSize.height, thumbnailHeight * backingScale)
                requests.append((id, time))
                arrivals.append(Self.milliseconds(since: started))
                return thumbnail
            }
        )
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: bounds))
        surface.cacheDisplay(in: bounds, to: bitmap)
        for _ in 0..<300 where arrivals.count < 48 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests.map(\.0), clips.flatMap { clip in expectedTimes.map { _ in clip.sourceID } })
        XCTAssertEqual(requests.map(\.1), clips.flatMap { _ in expectedTimes })
        surface.cacheDisplay(in: bounds, to: bitmap)
        let dirty = NSRect(x: 405, y: 56, width: 30, height: 12)
        let patch = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: dirty))
        var paints = [Double]()
        var paintCPU = [Double]()
        for index in 0..<350 {
            let start = ContinuousClock.now
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            surface.cacheDisplay(in: dirty, to: patch)
            let cpuElapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart
            if index >= 50 {
                paints.append(Self.milliseconds(since: start))
                paintCPU.append(Double(cpuElapsed) / 1e6)
            }
        }
        paints.sort()
        paintCPU.sort()
        let sample = try XCTUnwrap(patch.colorAt(x: patch.pixelsWide / 2, y: patch.pixelsHigh / 2))
        let rgb = try XCTUnwrap(sample.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(rgb.redComponent - max(rgb.greenComponent, rgb.blueComponent), 0.35)
        XCTAssertEqual(requests.count, 48, "Repainting a loaded tile should not schedule any further requests")
        let metrics = ["firstTileMs": try XCTUnwrap(arrivals.first), "lastTileMs": try XCTUnwrap(arrivals.last),
                       "dirtyPaintMedianMs": paints[149], "dirtyPaintP95Ms": paints[284],
                       "dirtyPaintCPUMedianMs": paintCPU[149], "dirtyPaintCPUP95Ms": paintCPU[284]]
        let json = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("MPCUT_FILMSTRIP_PAINT_BENCHMARK \(String(decoding: json, as: UTF8.self))")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
}
