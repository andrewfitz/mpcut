import AVFoundation
import Combine
@testable import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamPreviewAuditTests: XCTestCase {
    func testAudioPreviewKeepsContainerOrderWhenAnEarlierTrackHasNoIndex() throws {
        let original = try indexed("Audio-Ordinal-Subtitle-First", "mov")
        XCTAssertEqual(original.streams.map(\.kind), ["subtitle", "audio", "audio"])
        let selected = try XCTUnwrap(original.audio.last)
        let media = MediaInfo(url: original.url, format: original.format, duration: original.duration,
                              origin: original.origin, streams: original.streams, frames: original.frames,
                              audio: [selected], copyIssue: original.copyIssue,
                              sourceStartSafe: original.sourceStartSafe, identity: original.identity, videoIndex: -1)
        let range = MulticamRange(from: .zero, to: original.duration)
        let span = MulticamSpan(source: "sound", stream: selected.stream.index, input: range, output: range)

        XCTAssertEqual(MulticamPreviewAudioSpan(span: span, media: ["sound": media])?.ordinal, 1)
    }

    func testProvisionalPictureUsesTheFrameThatStartsExactlyAtTheRequestedTime() throws {
        // Frame 29 at 25 fps is 1.16 s; in binary floating point 1.16 × 25 is just under 29.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let engine = CutEngine(useSidecar: false)
        let header = try engine.multicamClock(engine.inspectForPreview(url))
        XCTAssertFalse(header.hasFullEditIndex)
        XCTAssertEqual(try engine.inspect(url, keyframes: true).frames.count, 75)
        let video = try XCTUnwrap(header.videoStream)
        let step = RationalTime(numerator: video.frameRate.denominator, denominator: video.frameRate.numerator)
        let start = max(.zero, video.start)
        var wrong: [Int64] = []
        var checked = 0
        for frame in Int64(0)..<2_000 {
            let time = try start.adding(step.multiplied(by: .init(numerator: frame)))
            guard time < header.duration else { break }
            checked += 1
            let position = MulticamPicturePosition.at(time, source: "wide", media: header, spanIndex: 0)
            if position?.frameTime != time { wrong.append(frame) }
        }
        XCTAssertEqual(checked, 75)
        XCTAssertEqual(wrong, [])
    }

    @MainActor
    func testForwardPlaybackParksAtTheEndOnTheLastPictureAndReverseReturnsToZero() async throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("WebM-Opus-GOP", "webm")
        let end = RationalTime(numerator: 1, denominator: 2)
        let middle = RationalTime(numerator: 1, denominator: 4)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: end),
                                      angles: [.init(id: "wide", file: wide.url.path, audioStream: wide.audio.first?.stream.index),
                                               .init(id: "close", file: close.url.path, audioStream: close.audio.first?.stream.index)],
                                      audio: .follow,
                                      switches: [.init(at: .zero, angle: "wide"), .init(at: middle, angle: "close")])
        let plan = try project.plan()
        let media = ["wide": wide, "close": close]
        let preview = MulticamPreview()
        defer { preview.reset() }
        preview.configure(plan: plan, media: media)
        preview.seek(to: .init(numerator: 1, denominator: 5))
        try await wait { preview.picture?.source == "wide" }
        preview.togglePlayback()
        var last = preview.currentTime()
        try await wait {
            let now = preview.currentTime()
            XCTAssertGreaterThanOrEqual(now, last)
            last = now
            return !preview.isPlaying
        }
        XCTAssertEqual(preview.time, end)
        let expected = try XCTUnwrap(MulticamPicturePosition.at(end, in: plan, media: media))
        XCTAssertEqual(expected.source, "close")
        try await wait { preview.picture == expected }

        preview.shuttle(-1)
        XCTAssertEqual(preview.playbackRate, -1)
        last = preview.currentTime()
        try await wait {
            let now = preview.currentTime()
            XCTAssertLessThanOrEqual(now, last)
            last = now
            return !preview.isPlaying
        }
        XCTAssertEqual(preview.time, .zero)
        try await wait { preview.picture?.source == "wide" && preview.picture?.frameTime == wide.frames[0].time }
        XCTAssertNil(preview.issue)
    }

    @MainActor
    func testPlaybackContinuesAcrossAnUncoveredCameraAndSeekingBackWhilePlayingMovesTheClock() async throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("WebM-Opus-GOP", "webm")
        let late = RationalTime(numerator: 3, denominator: 10)
        // The close camera starts 0.3 s into the group, yet is selected from 0.1 s.
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 3, denominator: 5)),
                                      angles: [.init(id: "wide", file: wide.url.path),
                                               .init(id: "close", file: close.url.path, offset: late)],
                                      audio: .none,
                                      switches: [.init(at: .zero, angle: "wide"),
                                                 .init(at: .init(numerator: 1, denominator: 10), angle: "close")])
        let plan = try project.plan()
        let media = ["wide": wide, "close": close]
        let preview = MulticamPreview()
        defer { preview.reset() }
        preview.configure(plan: plan, media: media)
        XCTAssertNil(MulticamPicturePosition.at(.init(numerator: 1, denominator: 5), in: plan, media: media))
        XCTAssertEqual(MulticamPicturePosition.at(late, in: plan, media: media)?.frameTime, close.frames.first?.time)
        try await wait { preview.picture?.source == "wide" }
        var gapWhilePlaying = false
        let observation = preview.$pictureIssue.sink { if $0 != nil, preview.isPlaying { gapWhilePlaying = true } }
        preview.togglePlayback()
        // The clock has to run through the uncovered 0.1–0.3 s to reach the covered picture.
        try await wait { preview.currentTime() >= late }
        XCTAssertTrue(gapWhilePlaying)
        preview.pause()
        if preview.time < plan.duration {
            let parked = try XCTUnwrap(MulticamPicturePosition.at(preview.time, in: plan, media: media))
            try await wait { preview.picture == parked }
            XCTAssertEqual(parked.source, "close")
            XCTAssertNil(preview.pictureIssue)
        }
        observation.cancel()

        preview.seek(to: .zero)
        preview.togglePlayback()
        try await wait { preview.currentTime().seconds >= 0.2 }
        let target = RationalTime(numerator: 1, denominator: 20)
        preview.seek(to: target)
        XCTAssertTrue(preview.isPlaying)
        let now = preview.currentTime()
        XCTAssertGreaterThanOrEqual(now, target)
        XCTAssertLessThan(now.seconds, 0.2)
    }

    @MainActor
    func testPreviewIsReleasedWhilePlayingInEitherDirection() async throws {
        let wide = try indexed("Shuttle-Chirp", "mov")
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 2)),
                                      angles: [.init(id: "wide", file: wide.url.path, audioStream: wide.audio.first?.stream.index)],
                                      audio: .follow, switches: [.init(at: .zero, angle: "wide")])
        let plan = try project.plan()
        for direction in [1, -1] {
            weak var released: MulticamPreview?
            do {
                let preview = MulticamPreview()
                released = preview
                preview.configure(plan: plan, media: ["wide": wide])
                preview.seek(to: .init(numerator: 1))
                preview.shuttle(direction)
                let start = preview.currentTime()
                let deadline = ContinuousClock.now + .seconds(20)
                while preview.currentTime() == start, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertNotEqual(preview.currentTime(), start)
            }
            let deadline = ContinuousClock.now + .seconds(20)
            while released != nil, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNil(released)
        }
    }

    @MainActor
    func testLiveSwitchDuringReverseShuttleAndIndexCompletionDuringPlaybackKeepTheClock() async throws {
        let wide = try indexed("SmartTrim-GOP", "mp4")
        let close = try indexed("Shuttle-Chirp", "mov")
        let engine = CutEngine(useSidecar: false)
        let header = try engine.multicamClock(engine.inspectForPreview(close.url))
        var project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 3, denominator: 2)),
                                      angles: [.init(id: "wide", file: wide.url.path),
                                               .init(id: "close", file: close.url.path, audioStream: close.audio.first?.stream.index)],
                                      audio: .fixed(.init(source: "close", stream: try XCTUnwrap(close.audio.first?.stream.index))),
                                      switches: [.init(at: .zero, angle: "close")])
        let preview = MulticamPreview()
        defer { preview.reset() }
        preview.configure(plan: try project.plan(), media: ["wide": wide, "close": header])
        try await wait { preview.picture?.provisional == true }
        preview.togglePlayback()
        try await wait { preview.currentTime().seconds >= 0.1 }
        // The index arrives while the provisional picture is playing.
        let before = preview.currentTime()
        let wasPlaying = preview.isPlaying
        preview.configure(plan: try project.plan(), media: ["wide": wide, "close": close])
        XCTAssertEqual(preview.isPlaying, wasPlaying)
        XCTAssertGreaterThanOrEqual(preview.currentTime(), before)
        try await wait { preview.picture?.provisional == false }
        XCTAssertNil(preview.issue)

        preview.seek(to: .init(numerator: 6, denominator: 5))
        preview.shuttle(-1)
        try await wait { preview.currentTime().seconds <= 1 }
        let instant = preview.currentTime()
        // Reverse runs toward earlier group time, so a switch here applies to what was already shown.
        let cut = RationalTime(numerator: 1, denominator: 2)
        project.switches.append(.init(at: cut, angle: "wide"))
        let plan = try project.plan()
        let media = ["wide": wide, "close": close]
        let rate = preview.playbackRate
        preview.configure(plan: plan, media: media)
        XCTAssertEqual(preview.playbackRate, rate)
        XCTAssertLessThanOrEqual(preview.currentTime(), instant)
        preview.pause()
        if preview.time >= cut {
            try await wait { preview.picture?.source == "wide" }
            XCTAssertEqual(preview.picture, MulticamPicturePosition.at(preview.time, in: plan, media: media))
        }
        preview.shuttle(-1)
        try await wait { preview.currentTime() < cut }
        preview.pause()
        try await wait { preview.picture?.source == "close" }
        XCTAssertEqual(preview.picture, MulticamPicturePosition.at(preview.time, in: plan, media: media))
        XCTAssertNil(preview.issue)
    }

    func testFallbackDecoderSeeksOnTheMovieClockWhenThePictureStartsLate() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        XCTAssertGreaterThan(media.multicamClockOffset, .zero)
        XCTAssertEqual(media.origin, .zero)
        // Every ProRes picture is a keyframe, so a seek that lands late cannot reach the requested one.
        for frame in [media.frames[0], media.frames[5], media.frames[media.frames.count - 1]] {
            let reader = FFPreviewReader(videoOnly: true)
            let decoded = try reader.perform(cancelled: { false }) {
                try reader.seek(url: url, to: frame.time.seconds, audioOrigin: media.origin)
                return try reader.indexedFrame(at: previewTime(frame.time), cancelled: { false })
            }
            XCTAssertEqual(decoded?.time, previewTime(frame.time))
        }
    }

    @MainActor
    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !ready(), .now < deadline { try await Task.sleep(for: .milliseconds(4)) }
        XCTAssertTrue(ready())
    }

    private func indexed(_ name: String, _ ext: String) throws -> MediaInfo {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try CutEngine(useSidecar: false).inspect(url, keyframes: true)
    }
}
