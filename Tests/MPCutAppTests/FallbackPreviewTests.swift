import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class FallbackPreviewTests: XCTestCase {
    func testScrubCacheReusesSurfacesAndRespectsTrimBoundariesAndSources() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let reader = FFPreviewReader()
        var cache = ScrubFrameCache()
        func request(_ source: URL, end: Double?) throws -> PreviewFrame {
            try XCTUnwrap(cache.frame(url: source, at: 1, before: end) {
                try reader.seek(url: url, to: end == nil ? 1 : 0.999)
                return try reader.still(at: 1, before: end ?? .infinity) { false }
            })
        }
        let first = try request(url, end: nil)
        XCTAssertEqual(first.time.seconds, 1)
        let previous = try request(url, end: 1)
        XCTAssertEqual(previous.time.seconds, 0.96, accuracy: 1e-8)
        let cached = cache.frame(url: url, at: 1, before: nil) {
            XCTFail("Decoded the same seek twice")
            return nil
        }
        XCTAssertTrue(try XCTUnwrap(cached).buffer === first.buffer)
        let second = url.appendingPathExtension("different")
        XCTAssertNil(cache.frame(url: second, at: 1, before: nil) { nil })
    }

    @MainActor
    func testShuttleWorksAcrossBothPreviewRoutes() async throws {
        let clock = ContinuousClock()
        for (name, ext) in [("SmartTrim-GOP", "mp4"), ("WebM-Opus-GOP", "webm")] {
            let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext,
                                                          subdirectory: "Fixtures"))
            let preview = SequencePreview()
            defer { preview.pause() }
            preview.update([PreviewRange(url: source, exactStart: .zero, exactEnd: .init(numerator: 1))], at: 0.4)
            let deadline = clock.now + .seconds(3)
            while preview.playbackRate == 0, preview.issue == nil, clock.now < deadline {
                preview.shuttle(1)
                if preview.playbackRate == 0 { try await Task.sleep(for: .milliseconds(10)) }
            }
            XCTAssertEqual(preview.playbackRate, 1, ext)
            preview.shuttle(1)
            XCTAssertEqual(preview.playbackRate, 2, ext)
            let forward = preview.time
            let forwardDeadline = clock.now + .seconds(3)
            while preview.time <= forward, preview.issue == nil, clock.now < forwardDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(preview.time, forward, ext)
            preview.shuttle(-1)
            XCTAssertEqual(preview.playbackRate, -1, ext)
            preview.shuttle(-1)
            XCTAssertEqual(preview.playbackRate, -2, ext)
            let reverse = preview.time
            let reverseDeadline = clock.now + .seconds(3)
            while preview.time >= reverse, preview.issue == nil, clock.now < reverseDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertLessThan(preview.time, reverse, ext)
            preview.pause()
            XCTAssertEqual(preview.playbackRate, 0, ext)
            XCTAssertNil(preview.issue, ext)
        }
    }

    @MainActor
    func testFilmstripRendersNativeAndWebMThumbnails() async throws {
        let preview = SequencePreview()
        for (name, ext) in [("SmartTrim-GOP", "mp4"), ("WebM-Opus-GOP", "webm")] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
            let image = await preview.thumbnail(source: UUID(), url: url, at: 0.4, size: CGSize(width: 80, height: 80))
            let rendered = try XCTUnwrap(image)
            XCTAssertEqual(max(rendered.width, rendered.height), 80)
            XCTAssertGreaterThan(min(rendered.width, rendered.height), 0)
        }
    }

    @MainActor
    func testSteppingToExactFrameAcrossWebMJoinShowsThatPicture() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                      subdirectory: "Fixtures"))
        let ranges = [PreviewRange(url: source, exactStart: .zero, exactEnd: .init(numerator: 1, denominator: 5)),
                      PreviewRange(url: source, exactStart: .zero, exactEnd: .init(numerator: 1))]
        let rendered = expectation(description: "Render the source picture at 0.4 seconds")
        let player = WebSequencePlayback(ranges: ranges, onFrame: { frame in
            XCTAssertEqual(frame.time.seconds, 0.4, accuracy: 0.0000001)
            rendered.fulfill()
        }, onTime: { _ in }, onIssue: { message in
            XCTFail(message)
            rendered.fulfill()
        }, onAudioWarning: { _ in })
        player.seek(to: 0.6)
        await fulfillment(of: [rendered], timeout: 5)
        player.pause()
    }

    @MainActor
    func testPausingAnAlreadyPausedPreviewPreservesPendingSeek() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                  subdirectory: "Fixtures"))
        let rendered = expectation(description: "The paused seek renders even if a mark is set immediately")
        let player = WebSequencePlayback(ranges: [PreviewRange(url: url, exactStart: .zero,
                                                               exactEnd: .init(numerator: 1))],
                                         onFrame: { frame in
            XCTAssertEqual(frame.time.seconds, 0.4, accuracy: 1e-8)
            rendered.fulfill()
        }, onTime: { _ in }, onIssue: { XCTFail($0) }, onAudioWarning: { _ in })
        player.seek(to: 0.4)
        player.pause()
        await fulfillment(of: [rendered], timeout: 2)
    }

    func testScrubbingJustBeforeKeyframeHoldsPrecedingPicture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let reader = FFPreviewReader()
        for (target, expected) in [(0.99999, 0.96), (1.0, 1.0), (0.999999, 0.96)] {
            try reader.seek(url: url, to: target)
            let frame = try XCTUnwrap(reader.still(at: target) { false })
            XCTAssertEqual(frame.time.seconds, expected, accuracy: 0.0000001)
        }
    }

    @MainActor
    func testUnsupportedAudioStillPlaysPictures() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "WebM-Opus-GOP", withExtension: "webm",
                                                     subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webm")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = try Data(contentsOf: source)
        let codec = try XCTUnwrap(bytes.range(of: Data("A_OPUS".utf8)))
        bytes.replaceSubrange(codec, with: Data("A_VOID".utf8))
        try bytes.write(to: url)
        let range = PreviewRange(url: url, exactStart: .zero, exactEnd: RationalTime(numerator: 1, denominator: 2))
        var warnings: [String] = []
        var failures: [String] = []
        var pictures = 0
        var position = 0.0
        let player = WebSequencePlayback(ranges: [range], onFrame: { _ in pictures += 1 },
                                         onTime: { position = $0 }, onIssue: { failures.append($0) },
                                         onAudioWarning: { if let warning = $0 { warnings.append(warning) } })
        player.play()
        defer { player.pause() }
        let deadline = ContinuousClock.now + .seconds(5)
        while position < range.end, failures.isEmpty, .now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(position, range.end)
        XCTAssertGreaterThan(pictures, 1)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(failures, [])
    }
}
