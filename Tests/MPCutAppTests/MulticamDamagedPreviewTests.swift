import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

/// Damage-H264.mp4 (two B pictures) and Damage-HEVC.mov hold four seconds at 25 pictures a
/// second with a keyframe every second. Each is the only camera of a multicam project.
final class MulticamDamagedPreviewTests: XCTestCase {
    private struct Damage {
        let name: String
        let ext: String
        /// The damaged picture.
        let picture: Int
        /// The pictures that cannot be decoded. H.264 B pictures 38 and 39 are predicted from 40.
        let lost: Range<Int>
        var label: String { "\(name) damaged at \(picture)" }
    }

    private static let cases = [
        Damage(name: "Damage-H264", ext: "mp4", picture: 40, lost: 38..<50),
        Damage(name: "Damage-HEVC", ext: "mov", picture: 40, lost: 40..<50),
        Damage(name: "Damage-H264", ext: "mp4", picture: 50, lost: 50..<75),
        Damage(name: "Damage-HEVC", ext: "mov", picture: 50, lost: 50..<75)
    ]

    /// Overwrite coded picture data and keep the leading bytes of the sample.
    /// VideoToolbox accepts such a sample and then fails to decode it.
    private func damaged(_ damage: Damage) throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: damage.name, withExtension: damage.ext,
                                                     subdirectory: "Fixtures"))
        var data = try Data(contentsOf: source)
        let track = try XCTUnwrap(AVURLAsset(url: source).tracks(withMediaType: .video).first)
        let origin = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder()).presentationTimeStamp
        let target = origin + CMTime(value: Int64(damage.picture), timescale: 25)
        let cursor = try XCTUnwrap(track.makeSampleCursor(presentationTimeStamp: target))
        XCTAssertEqual(cursor.presentationTimeStamp, target)
        let range = cursor.currentSampleStorageRange
        XCTAssertGreaterThan(range.length, 64)
        for i in Int(range.offset) + 24..<Int(range.offset + range.length) - 8 {
            data[i] = UInt8(truncatingIfNeeded: i &* 197 &+ 91)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + damage.ext)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A project that shows the damaged recording from its first picture to its last.
    @MainActor
    private final class Program {
        let damage: Damage
        let media: MediaInfo
        let preview = MulticamPreview()

        init(_ damage: Damage, url: URL) throws {
            self.damage = damage
            media = try CutEngine().inspectMulticamSource(url)
            XCTAssertEqual(media.frames.count, 100, damage.label)
            let project = MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: media.duration),
                                          angles: [.init(id: "camera", file: url.path)], audio: .none,
                                          switches: [.init(at: .zero, angle: "camera")])
            preview.configure(plan: try project.plan(), media: ["camera": media])
        }

        func time(_ picture: Int) -> RationalTime { media.frames[picture].time }

        func shows(_ picture: Int) -> Bool {
            preview.picture?.frameTime == time(picture) && preview.pictureIssue == nil
                && preview.displayedFrameTime.map { abs($0.seconds - time(picture).seconds) < 1e-6 } == true
        }

        /// The position reports an issue and no picture stands in for the missing one.
        var refuses: Bool {
            preview.pictureIssue != nil && preview.picture == nil && preview.displayedFrameTime == nil
        }

        func wait(_ label: String, file: StaticString = #filePath, line: UInt = #line,
                  until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(condition(), "\(damage.label): \(label). Picture "
                          + "\(preview.picture.map { String($0.frameTime.seconds) } ?? "none"), displayed "
                          + "\(preview.displayedFrameTime.map { String($0.seconds) } ?? "none"), issue "
                          + "\(preview.pictureIssue ?? "none"), time \(preview.time.seconds)", file: file, line: line)
        }

        func seek(_ picture: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
            preview.seek(to: time(picture))
            if damage.lost.contains(picture) {
                try await wait("picture \(picture) is refused", file: file, line: line) { refuses }
            } else {
                try await wait("picture \(picture) is shown", file: file, line: line) { shows(picture) }
            }
        }
    }

    @MainActor
    func testSeeksShowIntactPicturesOnBothSidesOfTheDamageAndRefuseTheLostOnes() async throws {
        for damage in Self.cases {
            let program = try Program(damage, url: try damaged(damage))
            defer { program.preview.reset() }
            let lost = damage.lost
            try await program.seek(lost.lowerBound - 8)
            try await program.seek(lost.lowerBound + 3)
            try await program.seek(lost.upperBound + 13)
            // The picture before the damage decodes again after the failed position.
            try await program.seek(lost.lowerBound - 1)
            try await program.seek(damage.picture)
            try await program.seek(lost.upperBound)
            try await program.seek(lost.upperBound - 1)
            try await program.seek(0)
        }
    }

    /// Steps inside the lost range follow one another without waiting for a decode, so each
    /// request cancels the one before it.
    @MainActor
    func testSteppingThroughTheLostPicturesReachesTheNextKeyframeInBothDirections() async throws {
        for damage in Self.cases {
            let program = try Program(damage, url: try damaged(damage))
            defer { program.preview.reset() }
            let pictures = Array(damage.lost.lowerBound - 3...damage.lost.upperBound + 2)
            for picture in pictures { try await program.seek(picture) }
            for picture in pictures.reversed() { try await program.seek(picture) }
        }
    }

    /// A request cancelled after the decoder rejected a picture leaves nothing behind for the next request:
    /// the keyframe after the lost pictures decodes, wherever the cancellation fell.
    func testACancelledRequestInTheLostPicturesDoesNotFailTheNextIntactOne() throws {
        for damage in Self.cases {
            let url = try damaged(damage)
            let media = try CutEngine().inspectMulticamSource(url)
            let lost = damage.lost
            for checks in 1...40 {
                let decoder = try HardwareFrames(url: url)
                XCTAssertNotNil(try decoder.indexedFrame(at: media.frames[lost.lowerBound - 1].time) { false }, damage.label)
                var remaining = checks
                _ = try? decoder.indexedFrame(at: media.frames[lost.upperBound - 3].time) {
                    remaining -= 1
                    return remaining < 0
                }
                for picture in [lost.upperBound, lost.upperBound + 1] {
                    XCTAssertNotNil(try decoder.indexedFrame(at: media.frames[picture].time) { false },
                                    "\(damage.label): picture \(picture) after a request cancelled at check \(checks)")
                }
            }
        }
    }

    @MainActor
    func testPlaybackPassesTheLostPicturesAndCanStartOnOne() async throws {
        for damage in Self.cases {
            let program = try Program(damage, url: try damaged(damage))
            let preview = program.preview
            defer { preview.reset() }
            let recovered = program.time(damage.lost.upperBound)
            let beyond = program.time(damage.lost.upperBound + 3)
            func playsPastTheDamage(_ label: String) async throws {
                preview.togglePlayback()
                XCTAssertTrue(preview.isPlaying, "\(damage.label): \(label)")
                var playing = false
                try await program.wait("\(label) shows a picture after the next keyframe") {
                    guard preview.time >= beyond, preview.pictureIssue == nil,
                          let picture = preview.picture, picture.frameTime >= recovered else { return false }
                    playing = preview.isPlaying || preview.time == preview.duration
                    return true
                }
                XCTAssertTrue(playing, "\(damage.label): \(label) stopped at \(preview.time.seconds)")
                preview.pause()
            }

            try await program.seek(damage.lost.lowerBound - 5)
            try await playsPastTheDamage("playback from before the damage")

            try await program.seek(damage.lost.lowerBound + 2)
            try await playsPastTheDamage("playback from a lost picture")
        }
    }
}
