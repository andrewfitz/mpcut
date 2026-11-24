import AVFoundation
import CoreImage
import MPCutCore
import XCTest
@testable import MPCutApp

final class PublishedSparsePlaybackTests: XCTestCase {
    func testFallbackPrerollEmitsAHeldPictureWithTheFirstAudioBatch() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Held-H264-FLAC", withExtension: "mkv",
                                                     subdirectory: "Fixtures"))
        let reader = FFPreviewReader()
        let target = 4.0
        try reader.seek(url: source, to: target, withAudio: true)
        var firstPicture: PreviewFrame?
        var reachedAudio = false
        for _ in 0..<10 {
            let batch = try reader.batch(from: target, end: 8, timelineOffset: .zero,
                                         first: firstPicture == nil, cancelled: { false }, audioLimit: 1)
            firstPicture = firstPicture ?? batch.video.first
            XCTAssertFalse(batch.end)
            if !batch.audio.isEmpty {
                reachedAudio = true
                break
            }
        }
        XCTAssertTrue(reachedAudio)
        let picture = try XCTUnwrap(firstPicture)
        XCTAssertEqual(picture.time.seconds, target)
        XCTAssertEqual(picture.sourcePicture?.time, RationalTime(numerator: 1))
    }

    func testPhotoJPEGCanSeekIntoTheFinalHoldAndBack() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "PhotoJPEG-Sparse", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let decoder = try HardwareFrames(url: source)
        for (position, expected) in [(0.75, 0.0), (0.999, 0.0), (1.0, 1.0), (3.9, 1.0), (4.0, 1.0), (0.25, 0.0)] {
            let frame = try XCTUnwrap(decoder.frame(at: position, before: 4) { false })
            XCTAssertEqual(frame.sourcePicture?.time.seconds, expected, "Seek at \(position)")
        }
    }

    private struct Time: Decodable {
        let numerator: Int64
        let denominator: Int64

        var rational: RationalTime { RationalTime(numerator: numerator, denominator: denominator) }
        var mediaTime: CMTime { previewTime(rational) }
    }

    private struct Movie: Decodable {
        struct Seek: Decodable {
            let numerator: Int64
            let denominator: Int64
            let bright: Bool
            let frame: Time

            var time: Time { Time(numerator: numerator, denominator: denominator) }
        }

        let file: String
        let end: Time
        let seeks: [Seek]

        var url: URL { URL(fileURLWithPath: file) }
        var isMatroska: Bool { url.pathExtension == "mkv" }
    }

    private func movies() throws -> [Movie] {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["MPCUT_SPARSE_PLAYBACK_MANIFEST"],
                                    "The sparse export matrix must publish a playback manifest.")
        let movies = try JSONDecoder().decode([Movie].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(movies.isEmpty)
        return movies
    }

    @MainActor
    func testPublishedSparseMoviesInMPCut() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MPCUT_SPARSE_PLAYBACK_MANIFEST"] != nil)
        for movie in try movies() {
            let media = try CutEngine(useSidecar: false).inspect(movie.url)
            XCTAssertEqual(media.duration, movie.end.rational, movie.file)
            let preview = SequencePreview()
            preview.isMuted = true
            defer { preview.pause() }
            let range = PreviewRange(media: media, from: .zero, to: media.duration)
            preview.update([range], at: 0)
            for seek in movie.seeks {
                preview.seek(to: seek.time.rational.seconds)
                try await wait { preview.sourcePicture.value?.time == seek.frame.rational || preview.issue != nil }
                XCTAssertEqual(preview.sourcePicture.value?.time, seek.frame.rational, "\(movie.file) at \(seek.time.rational)")
                XCTAssertNil(preview.issue, movie.file)
            }

            let final = try XCTUnwrap(movie.seeks.dropLast().last)
            let end = movie.end.rational.seconds
            let start = max(final.frame.rational.seconds, end - 0.25)
            preview.seek(to: start)
            try await wait { preview.sourcePicture.value?.time == final.frame.rational || preview.issue != nil }
            try await wait {
                if !preview.isPlaying && preview.time == start { preview.togglePlayback() }
                return preview.isPlaying || preview.issue != nil
            }
            XCTAssertTrue(preview.isPlaying, movie.file)
            try await wait { !preview.isPlaying || preview.issue != nil }
            XCTAssertEqual(preview.time, end, accuracy: 0.001, movie.file)
            XCTAssertEqual(preview.sourcePicture.value?.time, final.frame.rational, movie.file)
            XCTAssertNil(preview.issue, movie.file)

            let first = try XCTUnwrap(movie.seeks.last)
            preview.seek(to: first.time.rational.seconds)
            try await wait { preview.sourcePicture.value?.time == first.frame.rational || preview.issue != nil }
            XCTAssertEqual(preview.sourcePicture.value?.time, first.frame.rational, movie.file)
            XCTAssertNil(preview.issue, movie.file)
        }
    }

    @MainActor
    func testPublishedSparseMoviesInAVPlayer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MPCUT_SPARSE_PLAYBACK_MANIFEST"] != nil)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for movie in try movies() where !movie.isMatroska {
            let item = AVPlayerItem(url: movie.url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            defer { player.pause() }
            try await wait { item.status != .unknown }
            guard item.status == .readyToPlay else {
                XCTFail("\(movie.file): \(String(describing: item.error))")
                continue
            }
            for seek in movie.seeks {
                let time = seek.time.mediaTime
                let completed = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                XCTAssertTrue(completed, "\(movie.file) at \(seek.time.rational)")
                var pixel: CVPixelBuffer?
                try await wait {
                    pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
                    return pixel != nil
                }
                guard let pixel else {
                    XCTFail("AVPlayer displayed no picture for \(movie.file) at \(seek.time.rational)")
                    continue
                }
                let image = CIImage(cvPixelBuffer: pixel)
                var rgba = [UInt8](repeating: 0, count: 4)
                context.render(image, toBitmap: &rgba, rowBytes: 4,
                               bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                XCTAssertEqual(rgba[0] > 40, seek.bright, "\(movie.file) at \(seek.time.rational) returned \(rgba)")
            }
            let final = try XCTUnwrap(movie.seeks.dropLast().last)
            let end = movie.end.rational.seconds
            let start = max(final.frame.rational.seconds, end - 0.25)
            let completed = await player.seek(to: previewTime(start), toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(completed, movie.file)
            player.play()
            try await wait { player.currentTime().seconds >= end - 0.001 && player.rate == 0 }
            XCTAssertEqual(player.currentTime().seconds, end, accuracy: 0.001, movie.file)
            XCTAssertEqual(player.rate, 0, movie.file)
        }
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
}
