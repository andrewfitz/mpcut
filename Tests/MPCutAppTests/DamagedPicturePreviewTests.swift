import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

/// Damage-H264.mp4 (two B pictures) and Damage-HEVC.mov hold four seconds at 25 pictures a
/// second with a keyframe every second. The picture at 1.6 s is a P picture in both.
final class DamagedPicturePreviewTests: XCTestCase {
    private static let fixtures = [("Damage-H264", "mp4"), ("Damage-HEVC", "mov")]

    /// Overwrite coded picture data and keep the leading bytes of each sample.
    /// VideoToolbox accepts such a sample and then fails to decode it.
    private func damaged(_ name: String, _ ext: String, at seconds: Double) throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        var data = try Data(contentsOf: source)
        let track = try XCTUnwrap(AVURLAsset(url: source).tracks(withMediaType: .video).first)
        let origin = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder()).presentationTimeStamp
        let target = origin + CMTime(value: Int64((seconds * 25).rounded()), timescale: 25)
        let cursor = try XCTUnwrap(track.makeSampleCursor(presentationTimeStamp: target))
        XCTAssertEqual(cursor.presentationTimeStamp, target)
        let range = cursor.currentSampleStorageRange
        XCTAssertGreaterThan(range.length, 64)
        for i in Int(range.offset) + 24..<Int(range.offset + range.length) - 8 {
            data[i] = UInt8(truncatingIfNeeded: i &* 197 &+ 91)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertDamaged(_ expression: @autoclosure () throws -> PreviewFrame?, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), label, file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, WebSequencePlayback.damagedPicture, label, file: file, line: line)
        }
    }

    func testFallbackPlaybackResumesAtTheKeyframeAfterADamagedPicture() throws {
        for (name, ext) in Self.fixtures {
            let url = try damaged(name, ext, at: 1.6)
            let reader = FFPreviewReader(videoOnly: true)
            try reader.seek(url: url, to: 0)
            var times: [Double] = []
            for _ in 0..<200 {
                let batch = try reader.batch(from: 0, end: 4, timelineOffset: 0.0, first: times.isEmpty, cancelled: { false })
                times += batch.video.map(\.time.seconds)
                if batch.end { break }
            }
            let pictures = times.map { Int(($0 * 25).rounded()) }
            // The pictures decoded before the damage, then every picture from the next keyframe.
            // The H.264 B pictures at 1.52 and 1.56 s are predicted from the damaged picture, and
            // the decoder can withhold one picture that was due when it met the damage.
            let lastIntact = name == "Damage-H264" ? 37 : 39
            let before = pictures.prefix { $0 < 50 }
            XCTAssertEqual(Array(before.prefix(lastIntact - 1)), Array(0..<lastIntact - 1), name)
            XCTAssertEqual(before, before.sorted()[...], name)
            XCTAssertLessThanOrEqual(try XCTUnwrap(before.last), lastIntact, name)
            XCTAssertEqual(Array(pictures.dropFirst(before.count)), Array(50..<100), name)
        }
    }

    @MainActor
    func testPlayFromDamageWaitsForRecoveryPictureTime() async throws {
        for (damage, start, recovery) in [(1.6, 1.72, 2.0), (2.0, 2.4, 3.0)] {
            let url = try damaged("Damage-H264", "mp4", at: damage)
            let range = PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 4))
            let reader = FFPreviewReader(videoOnly: true)
            try reader.seek(url: url, to: start)
            var decoded: PreviewFrame?
            while decoded == nil {
                let batch = try reader.batch(from: start, end: 4, timelineOffset: 0.0,
                                             first: true, cancelled: { false })
                decoded = batch.video.first
                if batch.end { break }
            }
            XCTAssertEqual(try XCTUnwrap(decoded).time.seconds, recovery, accuracy: 0.001)

            // A late display tick presents the newest due frame. onTime reports the same
            // tick's transport clock immediately after onFrame.
            var firstPicture: Double?
            var presentationClock: Double?
            let clock = ContinuousClock.now
            let player = WebSequencePlayback(ranges: [range], onFrame: { frame in
                if firstPicture == nil { firstPicture = frame.time.seconds }
            }, onTime: { time in
                if firstPicture != nil && presentationClock == nil { presentationClock = time }
            }, onIssue: { XCTFail($0) }, onAudioWarning: { _ in })
            player.park(at: start)
            player.play()
            defer { player.pause() }
            while presentationClock == nil, clock.duration(to: .now) < .seconds(4) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let shown = try XCTUnwrap(firstPicture)
            XCTAssertGreaterThanOrEqual(shown, recovery)
            XCTAssertLessThanOrEqual(shown, try XCTUnwrap(presentationClock))
        }
    }

    func testAStillInADamagedGroupIsRefusedAndOtherPositionsDecode() throws {
        for (name, ext) in Self.fixtures {
            let url = try damaged(name, ext, at: 1.6)
            let reader = FFPreviewReader(videoOnly: true)
            func still(_ time: Double, before end: Double = .infinity) throws -> PreviewFrame? {
                try reader.seek(url: url, to: time)
                return try reader.still(at: time, before: end) { false }
            }
            try reader.seek(url: url, to: 0)
            let recovered = try XCTUnwrap(reader.still(at: 2.53) { false })
            XCTAssertEqual(recovered.time.seconds, 2.52, accuracy: 1e-9, name)
            XCTAssertEqual(try XCTUnwrap(still(1.2)).time.seconds, 1.2, accuracy: 1e-9, name)
            for time in [1.6, 1.72, 1.96] {
                assertDamaged(try still(time), "\(name) \(time)")
            }
            // A trim boundary inside the damaged group must not show the last intact picture.
            assertDamaged(try still(1.72, before: 1.8), name)
            XCTAssertEqual(try XCTUnwrap(still(2.0)).time.seconds, 2.0, accuracy: 1e-9, name)
            XCTAssertEqual(try XCTUnwrap(still(2.52)).time.seconds, 2.52, accuracy: 1e-9, name)
            XCTAssertEqual(try XCTUnwrap(still(1.48)).time.seconds, 1.48, accuracy: 1e-9, name)
        }
    }

    func testAGroupWithADamagedKeyframeShowsNoPictureFromTheNextGroup() throws {
        for (name, ext) in Self.fixtures {
            let url = try damaged(name, ext, at: 2.0)
            let reader = FFPreviewReader(videoOnly: true)
            try reader.seek(url: url, to: 1.999)
            XCTAssertEqual(try XCTUnwrap(reader.still(at: 2, before: 2) { false }).time.seconds,
                           1.96, accuracy: 1e-9, name)
            for time in [2.0, 2.4, 2.96] {
                try reader.seek(url: url, to: time)
                assertDamaged(try reader.still(at: time) { false }, "\(name) \(time)")
            }
            try reader.seek(url: url, to: 3.2)
            XCTAssertEqual(try XCTUnwrap(reader.still(at: 3.2) { false }).time.seconds, 3.2, accuracy: 1e-9, name)
            try reader.seek(url: url, to: 1.96)
            XCTAssertEqual(try XCTUnwrap(reader.still(at: 1.96) { false }).time.seconds, 1.96, accuracy: 1e-9, name)
        }
    }

    func testNativeFramesDecodeAgainAfterADamagedPicture() throws {
        for (name, ext) in Self.fixtures {
            let url = try damaged(name, ext, at: 1.6)
            let frames = try HardwareFrames(url: url)
            XCTAssertEqual(try XCTUnwrap(frames.frame(at: 1.2) { false }).time.seconds, 1.2, accuracy: 1e-9, name)
            XCTAssertThrowsError(try frames.frame(at: 1.72) { false }, name)
            // The next keyframe is less than half a second ahead, which continues the same pass.
            XCTAssertEqual(try XCTUnwrap(frames.frame(at: 2.04) { false }).time.seconds, 2.04, accuracy: 1e-9, name)
            XCTAssertThrowsError(try frames.frame(at: 1.96) { false }, name)
            XCTAssertEqual(try XCTUnwrap(frames.frame(at: 1.48) { false }).time.seconds, 1.48, accuracy: 1e-9, name)
        }
    }

    @MainActor
    func testThumbnailsAreMissingOnlyInTheDamagedGroup() async throws {
        for (name, ext) in Self.fixtures {
            let url = try damaged(name, ext, at: 1.6)
            let preview = SequencePreview()
            let source = UUID()
            let size = CGSize(width: 96, height: 48)
            var rendered: [Bool] = []
            for time in [0.4, 1.2, 1.72, 1.96, 2.2, 1.8, 3.0] {
                rendered.append(await preview.thumbnail(source: source, url: url, at: time, size: size) != nil)
            }
            XCTAssertEqual(rendered, [true, true, false, false, true, false, true], name)
        }
    }

    @MainActor
    func testScrubbingAndPlaybackPassADamagedPicture() async throws {
        for (name, ext) in Self.fixtures {
            let url = try damaged(name, ext, at: 1.6)
            let preview = SequencePreview()
            preview.isMuted = true
            defer { preview.pause() }
            func wait(_ label: String, _ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(6)
                while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(condition(), "\(name): \(label), issue \(preview.issue ?? "none"), "
                              + "picture \(preview.displayedFrameTime?.seconds ?? -1), time \(preview.time)")
            }
            func shows(_ time: Double) -> Bool {
                preview.displayedFrameTime.map { abs($0.seconds - time) < 1e-6 } == true
            }
            func parkedOnDamage() -> Bool { preview.issue?.hasPrefix(WebSequencePlayback.damagedPicture) == true }

            preview.update([PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 4))], at: 1.2)
            try await wait("first picture") { shows(1.2) }
            XCTAssertNil(preview.issue, name)

            preview.seek(to: 1.72)
            try await wait("damaged position") { parkedOnDamage() }
            XCTAssertFalse(preview.hasBlockingIssue, name)

            preview.seek(to: 2.52)
            try await wait("picture after the next keyframe") { shows(2.52) && preview.issue == nil }
            preview.seek(to: 1.48)
            try await wait("picture before the damage") { shows(1.48) && preview.issue == nil }

            // Playback runs through the damaged group and shows pictures again after it.
            preview.togglePlayback()
            try await wait("playback starts") { preview.isPlaying }
            try await wait("playback passes the damage") {
                preview.time > 2.3 && (preview.displayedFrameTime?.seconds ?? 0) >= 2
            }
            XCTAssertNil(preview.issue, name)
            XCTAssertTrue(preview.isPlaying, name)
            preview.pause()

            // Play can start while parked on the damaged position.
            preview.seek(to: 1.72)
            try await wait("damaged position again") { parkedOnDamage() }
            preview.togglePlayback()
            try await wait("playback from the damaged position") { preview.isPlaying }
            try await wait("playback leaves the damaged group") {
                preview.time > 2.3 && (preview.displayedFrameTime?.seconds ?? 0) >= 2
            }
            XCTAssertNil(preview.issue, name)
        }
    }
}
