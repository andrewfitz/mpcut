import AppKit
import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class PlaybackSpeedTests: XCTestCase {
    @MainActor
    func testHighFrameRateSequenceAndMulticamTransport() async throws {
        for (fps, ext) in [(120, "mp4"), (240, "webm")] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Playback-\(fps)", withExtension: ext,
                                                      subdirectory: "Fixtures"))
            let media = try CutEngine().inspectMulticamSource(url)
            XCTAssertEqual(media.frames.count, fps * 2)
            let sequence = SequencePreview()
            sequence.update([PreviewRange(media: media, from: .zero, to: media.duration)], at: 0)
            try await exercise(sequence, time: { sequence.time }, picture: { sequence.displayedFrameTime },
                               issue: { sequence.issue })
            let project = MulticamProject(referenceAngle: "cam", range: .init(from: .zero, to: media.duration),
                                          angles: [.init(id: "cam", file: url.path)], audio: .none,
                                          switches: [.init(at: .zero, angle: "cam")])
            let multicam = MulticamPreview()
            multicam.configure(plan: try project.plan(), media: ["cam": media])
            try await exercise(multicam, time: { multicam.time.seconds }, picture: { multicam.displayedFrameTime },
                               issue: { multicam.issue })
        }
    }

    @MainActor
    private func exercise(_ player: some EditorPlayback, time: () -> Double, picture: () -> CMTime?,
                          issue: () -> String?) async throws {
        defer { player.pause() }
        player.selectPlaybackSpeed(.quarter)
        XCTAssertFalse(player.isPlaying)
        let deadline = ContinuousClock.now + .seconds(5)
        while time() < 0.03, .now < deadline, issue() == nil {
            if !player.isPlaying { player.togglePlayback() }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(issue())
        XCTAssertEqual(player.playbackRate, 0.25)
        for speed in [PlaybackSpeed.quarter, .normal, .double] {
            player.selectPlaybackSpeed(speed)
            let start = time()
            let clock = ContinuousClock.now
            var pictures = Set<Double>()
            while clock.duration(to: .now) < .milliseconds(240) {
                if let timestamp = picture() { pictures.insert(timestamp.seconds) }
                try await Task.sleep(for: .milliseconds(3))
            }
            let elapsed = clock.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            XCTAssertEqual(time() - start, seconds * Double(speed.rawValue), accuracy: 0.06 * Double(speed.rawValue))
            XCTAssertGreaterThanOrEqual(pictures.count, 3)
            XCTAssertNil(issue())
        }
        player.pause()
        player.togglePlayback()
        XCTAssertEqual(player.playbackRate, 2)
        player.selectPlaybackSpeed(.oneAndHalf)
        player.shuttle(1)
        XCTAssertEqual(player.playbackRate, 2)
        for (key, expected) in [("[", Float(1.5)), ("]", 2), ("\\", 1)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: key, charactersIgnoringModifiers: key,
                                                       isARepeat: false, keyCode: 0))
            XCTAssertTrue(player.handleSpeedKey(event))
            XCTAssertEqual(player.playbackRate, expected)
        }
        XCTAssertEqual(PlaybackSpeed.eighth.label, Float(0.125).formatted() + "×")
    }
}
