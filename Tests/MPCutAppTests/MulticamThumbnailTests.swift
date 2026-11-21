import CoreGraphics
import Foundation
import XCTest
@testable import MPCutApp
@testable import MPCutCore

final class MulticamThumbnailTests: XCTestCase {
    func testProvisionalCoverageKeepsTheLeadingEmptyEdit() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes", withExtension: "mov",
                                                      subdirectory: "Fixtures"))
        let engine = CutEngine(useSidecar: false)
        let provisional = try engine.multicamClock(engine.inspectForPreview(fixture))
        let indexed = try engine.inspectMulticamSource(fixture)
        XCTAssertFalse(provisional.hasFullEditIndex)
        XCTAssertTrue(provisional.frames.isEmpty)
        let firstPicture = try XCTUnwrap(indexed.frames.first).time.seconds
        XCTAssertGreaterThan(firstPicture, 0)
        XCTAssertEqual(MulticamFilmstrip.pictureCoverage(in: provisional)?.lowerBound, firstPicture)
        XCTAssertNil(MulticamFilmstrip.thumbnailTime(in: provisional, from: 0, to: firstPicture))
        XCTAssertEqual(MulticamFilmstrip.thumbnailTime(in: provisional, from: firstPicture, to: firstPicture + 1), 0)
    }

    func testFilmstripLeavesAnIndexedGapEmptyAndKeepsSourceClockForAdjacentTiles() {
        func frame(at value: Int64) -> FrameInfo {
            FrameInfo(dts: nil, time: .init(numerator: value, denominator: 8),
                      duration: .init(numerator: 1, denominator: 8), keyframe: true,
                      canStart: true, canEnd: true, byteCount: 0)
        }
        let frames = [frame(at: 2), frame(at: 5), frame(at: 6)]
        let clockOffset = RationalTime(numerator: 1, denominator: 4)
        XCTAssertEqual(MulticamFilmstrip.pictureGaps(in: frames), [0.375..<0.625])
        XCTAssertNil(MulticamFilmstrip.thumbnailTime(in: frames, from: 0.375, to: 0.625, clockOffset: clockOffset))
        XCTAssertEqual(MulticamFilmstrip.thumbnailTime(in: frames, from: 0.3125, to: 0.5625, clockOffset: clockOffset), 0)
        XCTAssertEqual(MulticamFilmstrip.thumbnailTime(in: frames, from: 0.5, to: 0.6875, clockOffset: clockOffset), 0.375)
    }

    func testFilmstripUsesTheExactFirstFrameAtACoverageBoundary() {
        let frames = (2...3).map { value in
            FrameInfo(dts: nil, time: .init(numerator: Int64(value), denominator: 8),
                      duration: .init(numerator: 1, denominator: 8), keyframe: true,
                      canStart: true, canEnd: true, byteCount: 0)
        }
        let coverage = 0.25..<5.0
        let scale = (391.0 - 32) / 5
        let startPixel = 16 + coverage.lowerBound * scale
        let layout = TimelineFilmstrip(width: (coverage.upperBound - coverage.lowerBound) * scale, targetWidth: 92)
        let first = MulticamFilmstrip.tileTimeRange(0, count: layout.count, coverage: coverage)
        let roundedStart = (startPixel - 16) / scale
        XCTAssertGreaterThan(roundedStart, coverage.lowerBound)
        XCTAssertEqual(MulticamFilmstrip.thumbnailTime(in: frames, from: roundedStart, to: first.upperBound,
                                                      clockOffset: .zero), 0.375)
        XCTAssertEqual(MulticamFilmstrip.thumbnailTime(in: frames, from: first.lowerBound, to: first.upperBound,
                                                      clockOffset: .zero), 0.25)
        let next = MulticamFilmstrip.tileTimeRange(1, count: layout.count, coverage: coverage)
        XCTAssertEqual(first.upperBound, next.lowerBound)
        XCTAssertEqual(MulticamFilmstrip.tileTimeRange(layout.count - 1, count: layout.count,
                                                       coverage: coverage).upperBound, coverage.upperBound)
    }

    @MainActor
    func testDisablingSidecarReuseAfterCacheHitStagesFreshThumbnail() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                      subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let media = try CutEngine().inspect(source, keyframes: true)
        let key = try XCTUnwrap(FilmstripTileKey(time: 0, size: CGSize(width: 92, height: 53)))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let stored = try XCTUnwrap(bitmap.makeImage())
        let sidecar = AnalysisSidecar(media: media)
        try sidecar.save([key.section: try XCTUnwrap(key.encoded(stored, preserveAlpha: true))])
        let service = MulticamThumbnailService()

        let restored = await service.image(media: media, key: key, reuseSidecar: true)
        XCTAssertEqual(restored?.width, 1)
        XCTAssertTrue(service.snapshot(for: media).isEmpty)

        let rendered = await service.image(media: media, key: key, reuseSidecar: false)
        let width = try XCTUnwrap(rendered?.width)
        XCTAssertGreaterThan(width, 1)
        XCTAssertEqual(service.snapshot(for: media).first?.image.width, width)
        XCTAssertEqual(key.image(in: sidecar)?.width, 1)
        let warm = await service.image(media: media, key: key, reuseSidecar: false)
        XCTAssertTrue(rendered === warm)

        // A source relinked at the same path has a different identity.
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: fixture, to: source)
        let replacement = try CutEngine().inspect(source, keyframes: true)
        XCTAssertNotEqual(replacement.identity, media.identity)
        XCTAssertTrue(service.snapshot(for: replacement).isEmpty)
    }
}

final class MulticamThumbnailAuditTests: XCTestCase {
    @MainActor
    func testFourLargeFilmstripsRenderConcurrentRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordings: [URL]
        let benchmark = ProcessInfo.processInfo.environment["MPCUT_THUMBNAIL_BENCHMARK_MEDIA"]
        if let path = benchmark {
            recordings = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                    includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "mp4" }.sorted { $0.path < $1.path }
            XCTAssertEqual(recordings.count, 4)
        } else {
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov",
                                                         subdirectory: "Fixtures"))
            recordings = try (0..<4).map { index in
                let url = directory.appendingPathComponent("angle-\(index).mov")
                try FileManager.default.copyItem(at: fixture, to: url)
                return url
            }
        }

        let engine = CutEngine(useSidecar: false)
        let cameras = try recordings.map { try engine.multicamClock(engine.inspectForPreview($0)) }
        let service = MulticamThumbnailService()
        let size = CGSize(width: 486, height: 274)
        let commonEnd = try XCTUnwrap(cameras.map(\.duration.seconds).min())
        let keys = try (0..<6).map { index in
            try XCTUnwrap(FilmstripTileKey(time: commonEnd * Double(index) / 6, size: size))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let rendered = await withTaskGroup(of: Bool.self) { group in
            for camera in cameras {
                group.addTask {
                    for key in keys {
                        guard let image = await service.image(media: camera, key: key, reuseSidecar: false),
                              image.width == Int(size.width),
                              image.height > 1, image.height <= Int(size.height) + 1 else { return false }
                    }
                    return true
                }
            }
            var successes = 0
            for await result in group where result { successes += 1 }
            return successes
        }
        print("Four large filmstrips, 24 source renders: \(start.duration(to: clock.now))")
        XCTAssertEqual(rendered, 4)
        XCTAssertEqual(service.decodersOpened, 4)
        let warmStart = clock.now
        for camera in cameras {
            for key in keys {
                let image = await service.image(media: camera, key: key, reuseSidecar: false)
                XCTAssertNotNil(image)
            }
        }
        print("Four large filmstrips, 24 warm requests: \(warmStart.duration(to: clock.now))")

        if benchmark != nil {
            let sequential = MulticamThumbnailService()
            let sequentialStart = clock.now
            for key in keys {
                for camera in cameras {
                    let image = await sequential.image(media: camera, key: key, reuseSidecar: false)
                    XCTAssertNotNil(image)
                }
            }
            print("Four large filmstrips, 24 sequential source renders: \(sequentialStart.duration(to: clock.now))")
            var acceleratedCameras = 0
            for camera in cameras {
                if let decoder = try? HardwareFrames(url: camera.url),
                   (try? decoder.frame(at: 0, cancelled: { false })) != nil {
                    acceleratedCameras += 1
                }
            }
            print("Four large filmstrips, VideoToolbox hardware decoding available: \(acceleratedCameras)/4")
        }
    }

    @MainActor
    func testEveryVisibleCameraKeepsItsThumbnailDecoderWhileTilesInterleave() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                      subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cameras = try (0..<6).map { index -> MediaInfo in
            let url = directory.appendingPathComponent("camera-\(index).mp4")
            try FileManager.default.copyItem(at: fixture, to: url)
            return try CutEngine(useSidecar: false).inspect(url, keyframes: true)
        }
        let service = MulticamThumbnailService()
        // Six visible lanes ask for their tiles in turn, as a scrolling timeline does.
        for round in 0..<3 {
            let key = try XCTUnwrap(FilmstripTileKey(time: Double(round) * 0.4, size: CGSize(width: 64, height: 36)))
            for camera in cameras {
                let image = await service.image(media: camera, key: key, reuseSidecar: false)
                XCTAssertNotNil(image)
            }
        }
        XCTAssertEqual(service.decodersOpened, cameras.count)
        XCTAssertEqual(service.openDecoders, cameras.count)

        // Cameras that have left the view give their decoders back without another cold render.
        let expiring = MulticamThumbnailService(decoderIdle: .seconds(2))
        let key = try XCTUnwrap(FilmstripTileKey(time: 0, size: CGSize(width: 64, height: 36)))
        for camera in cameras { _ = await expiring.image(media: camera, key: key, reuseSidecar: false) }
        XCTAssertEqual(expiring.openDecoders, cameras.count)
        let deadline = ContinuousClock.now + .seconds(4)
        while expiring.openDecoders > 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(expiring.openDecoders, 4)
        let cached = await expiring.image(media: cameras[0], key: key, reuseSidecar: false)
        XCTAssertNotNil(cached)
        XCTAssertEqual(expiring.decodersOpened, cameras.count)

        let idle = MulticamThumbnailService(decoderIdle: .zero)
        for camera in cameras { _ = await idle.image(media: camera, key: key, reuseSidecar: false) }
        XCTAssertEqual(idle.openDecoders, 4)
    }
}
