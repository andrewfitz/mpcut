import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ParticipantDisplayedPictureTests: XCTestCase {
    func testReviewIndexMatchesProjectOrderWhenPlayingAndSeekingBackward() throws {
        func time(_ value: Int64) -> RationalTime { .init(numerator: value) }
        let bounds = ParticipantBounds(x: 0, y: 0, width: 1, height: 1)
        let ranges: [(Int64, Int64)] = [(3, 9), (0, 12), (1, 3), (3, 5), (7, 8)]
        let appearances = ranges.enumerated().map { id, range in
            ParticipantAppearance(id: String(id), participantID: nil, range: .init(from: time(range.0), to: time(range.1)), bounds: bounds)
        }
        let index = ParticipantAppearanceIndex(appearances)
        for instant: Int64 in [4, 5, 5, 10, 8, 7, 6, 3, 2, 0, 19, 1] {
            XCTAssertEqual(index.at(time(instant)), appearances.filter { $0.range.contains(time(instant)) })
        }
    }

    func testReflowReviewUsesIndexedPicturesOnBothSidesOfBoundary() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine().inspectMulticamSource(url)
        let position = ParticipantMonitorPosition(sourceID: "gallery", media: media, time: .zero)
        let current = try media.frames[1].time.subtracting(media.multicamClockOffset)
        XCTAssertGreaterThan(media.multicamClockOffset, .zero)
        XCTAssertEqual(position.frameRange(atReflow: current, before: true)?.from, .zero)
        XCTAssertEqual(position.frameRange(atReflow: current, before: false)?.from, current)
        XCTAssertNil(position.frameRange(atReflow: .zero, before: true))
    }

    @MainActor
    func testPendingSeekKeepsTheDisplayedSourcePicture() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let preview = SequencePreview()
        defer { preview.pause() }
        preview.update([PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 2))], at: 0)
        func wait(for expected: RationalTime) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while preview.sourcePicture.value?.time != expected, .now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(preview.sourcePicture.value?.time, expected)
            XCTAssertEqual(preview.sourcePicture.value?.url, url)
        }
        try await wait(for: .zero)
        preview.seek(to: 1)
        XCTAssertEqual(preview.time, 1)
        XCTAssertEqual(preview.sourcePicture.value?.time, .zero)
        try await wait(for: .init(numerator: 1))
    }

    func testFallbackPlaybackRetainsSourcePTSWhenPrerollGetsAnOutputTimestamp() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let reader = FFPreviewReader(videoOnly: true)
        try reader.seek(url: url, to: 1.01)
        let batch = try reader.batch(from: 1.01, end: 1.5, timelineOffset: -1.01, first: true) { false }
        let first = try XCTUnwrap(batch.video.first)
        XCTAssertEqual(first.time.seconds, 0, accuracy: 1e-8)
        XCTAssertEqual(first.sourcePicture?.url, url)
        XCTAssertEqual(first.sourcePicture?.time, RationalTime(numerator: 1))
    }
}

final class FallbackPreviewTests: XCTestCase {
    func testNegativeFractionalOriginSeeksBeforeNextKeyframe() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        // The source clock is 1/12800. At timeline second one the next keyframe is still half a tick away.
        let origin = RationalTime(numerator: -1, denominator: 25_600)
        let reader = FFPreviewReader(videoOnly: true)
        try reader.seek(url: url, to: 1, audioOrigin: origin)
        let frame = try XCTUnwrap(reader.still(at: 1) { false })
        XCTAssertEqual(frame.time.seconds, 0.96 - origin.seconds, accuracy: 1e-8)
    }

    @MainActor
    func testLeadingPictureGapClearsTheParkedPreviewAndRemainsPlayable() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Leading-Picture-Gap", withExtension: "avi",
                                                   subdirectory: "Fixtures"))
        let preview = SequencePreview()
        defer { preview.pause() }
        preview.update([PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 2))], at: 0.4)
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(condition(), preview.issue ?? "Preview did not reach the expected state")
        }
        try await wait { preview.displayedFrameTime != nil }
        preview.seek(to: 0.05)
        try await wait { preview.displayedFrameTime == nil }
        XCTAssertNil(preview.issue)
        preview.togglePlayback()
        XCTAssertTrue(preview.isPlaying)
        try await wait { preview.displayedFrameTime != nil }
        XCTAssertGreaterThanOrEqual(preview.time, 0.2)
        XCTAssertNil(preview.issue)
    }

    @MainActor
    func testRangeEntirelyInsideALeadingGapClearsThePreviousClip() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Leading-Picture-Gap", withExtension: "avi",
                                                   subdirectory: "Fixtures"))
        let ranges = [(2, 4), (0, 1), (4, 8)].map { start, end in
            PreviewRange(url: url, exactStart: .init(numerator: Int64(start), denominator: 10),
                         exactEnd: .init(numerator: Int64(end), denominator: 10))
        }
        var events: [String] = []
        let player = WebSequencePlayback(ranges: ranges, onFrame: { _ in
            if events.last != "picture" { events.append("picture") }
        }, onTime: { _ in }, onIssue: { XCTFail($0) }, onAudioWarning: { _ in }, onGap: {
            events.append("gap")
        })
        player.play()
        defer { player.pause() }
        let deadline = ContinuousClock.now + .seconds(4)
        while events.count < 3, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(events, ["picture", "gap", "picture"])
    }

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
            // Leave enough timeline for the rate changes even if a display callback is delayed.
            let clip = PreviewRange(url: source, exactStart: .zero, exactEnd: .init(numerator: 2))
            preview.update(Array(repeating: clip, count: 32), at: 0.4)
            let deadline = clock.now + .seconds(3)
            while preview.playbackRate == 0, preview.issue == nil, clock.now < deadline {
                preview.shuttle(1)
                if preview.playbackRate == 0 { try await Task.sleep(for: .milliseconds(10)) }
            }
            XCTAssertEqual(preview.playbackRate, 1, ext)
            for rate: Float in [2, 4, 8] {
                preview.shuttle(1)
                XCTAssertEqual(preview.playbackRate, rate, ext)
                let forward = preview.time
                let forwardDeadline = clock.now + .seconds(3)
                while preview.time <= forward, preview.issue == nil, clock.now < forwardDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThan(preview.time, forward, "\(ext) at \(rate)×")
            }
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
    func testReverseShuttleDrainsAtSequenceStartAndResumesForward() async throws {
        for ext in ["mov", "webm"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: ext, subdirectory: "Fixtures"))
            let preview = SequencePreview()
            preview.isMuted = true
            defer { preview.pause() }
            let segment = PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 1))
            preview.update([segment], at: 0.16)
            let deadline = ContinuousClock.now + .seconds(4)
            while !preview.isPlaying && preview.issue == nil && .now < deadline {
                preview.shuttle(-1)
                if !preview.isPlaying { try await Task.sleep(for: .milliseconds(5)) }
            }
            XCTAssertEqual(preview.playbackRate, -1, ext)
            let drainDeadline = ContinuousClock.now + .seconds(4)
            while preview.isPlaying && .now < drainDeadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(preview.issue, ext)
            XCTAssertEqual(preview.time, 0, ext)
            XCTAssertFalse(preview.isPlaying, ext)
            preview.shuttle(1)
            XCTAssertEqual(preview.playbackRate, 1, ext)
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
    func testAudioOnlyScrubClearsAndRetiresTheVideoPicture() async throws {
        let video = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                    subdirectory: "Fixtures"))
        let audio = try XCTUnwrap(Bundle.module.url(forResource: "Gapless-Crop", withExtension: "mp3",
                                                    subdirectory: "Fixtures"))
        let picture = PreviewRange(url: video, exactStart: .zero, exactEnd: .init(numerator: 1))
        let sound = PreviewRange(url: audio, exactStart: .zero, exactEnd: .init(numerator: 1),
                                 isAudioOnly: true, usesMP3GaplessClock: true)
        let preview = SequencePreview()
        preview.scrubSoundEnabled = false
        preview.update([picture, sound], at: 0.4)
        let deadline = ContinuousClock.now + .seconds(5)
        while preview.displayedFrameTime == nil, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(preview.displayedFrameTime)

        preview.scrub(to: 0.8, rangeIndex: 0, sourceFrame: 0.8)
        preview.scrub(to: 1.2, rangeIndex: 1, sourceFrame: 0.2)
        XCTAssertNil(preview.displayedFrameTime)
        XCTAssertTrue(preview.readyForTransport)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(preview.displayedFrameTime)
        preview.endScrub()
    }

    @MainActor
    func testFallbackScrubHoldsTheLastPictureBeforeTheClipEnd() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                      subdirectory: "Fixtures"))
        let range = PreviewRange(url: source, exactStart: .zero, exactEnd: .init(numerator: 1))
        let rendered = expectation(description: "The first excluded keyframe is not displayed")
        let audioOccurrence = PreviewRange(url: source, exactStart: .zero, exactEnd: range.exactEnd, isAudioOnly: true)
        let player = WebSequencePlayback(ranges: [audioOccurrence, range], onFrame: { frame in
            XCTAssertEqual(frame.time.seconds, 0.96, accuracy: 1e-8)
            rendered.fulfill()
        }, onTime: { _ in }, onIssue: { message in
            XCTFail(message)
            rendered.fulfill()
        }, onAudioWarning: { _ in })
        player.audition(url: source, at: range.end, before: range.end)
        await fulfillment(of: [rendered], timeout: 3)
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
