import AVFoundation
import XCTest
@testable import MPCutCore

/// Damage-H264.mp4 holds 100 pictures at 25 a second with a keyframe every second and AAC sound.
/// Picture 40 is damaged here. A helper wrapper records every helper run.
final class ReencodeDamageRetryTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private var scratch: URL!
    private var source: URL!
    private var wrapper: URL!
    private var frames: [FrameInfo] = []

    override func setUpWithError() throws {
        let helper: URL
        do { helper = try ReencodeEngine.findHelper(override: nil) }
        catch { throw XCTSkip("The FFmpeg helper is needed to re-encode.") }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        source = scratch.appendingPathComponent("damaged.mp4")
        try damagedFixture(picture: 40).write(to: source)
        frames = try CutEngine().inspect(source, keyframes: true).frames
        XCTAssertEqual(frames.count, 100)

        // A render reads its filter graph from filters.txt. Other runs check the encoder or probe a decoder.
        wrapper = scratch.appendingPathComponent("helper")
        let script = """
            #!/bin/sh
            folder=$(dirname "$0")
            case " $* " in *" filters.txt "*) kind=render ;; *) kind=other ;; esac
            printf '%s %s\\n' "$kind" "$*" >> "$folder/log"
            if [ "$kind" = render ] && [ -e "$folder/refuse" ]; then echo "Permission denied" >&2; exit 1; fi
            "\(helper.path)" "$@"
            status=$?
            printf '%s-exit %s\\n' "$kind" "$status" >> "$folder/log"
            exit $status

            """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// Overwrite coded picture data and keep the leading bytes of the sample.
    /// VideoToolbox accepts such a sample and then fails to decode it.
    private func damagedFixture(picture: Int) throws -> Data {
        let fixture = Self.repository.appendingPathComponent("Tests/MPCutAppTests/Fixtures/Damage-H264.mp4")
        var data = try Data(contentsOf: fixture)
        let track = try XCTUnwrap(AVURLAsset(url: fixture).tracks(withMediaType: .video).first)
        let origin = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder()).presentationTimeStamp
        let target = origin + CMTime(value: Int64(picture), timescale: 25)
        let cursor = try XCTUnwrap(track.makeSampleCursor(presentationTimeStamp: target))
        XCTAssertEqual(cursor.presentationTimeStamp, target)
        let range = cursor.currentSampleStorageRange
        XCTAssertGreaterThan(range.length, 64)
        for i in Int(range.offset) + 24..<Int(range.offset + range.length) - 8 {
            data[i] = UInt8(truncatingIfNeeded: i &* 197 &+ 91)
        }
        return data
    }

    private func log() -> [String] {
        ((try? String(contentsOf: scratch.appendingPathComponent("log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private var renders: [String] { log().filter { $0.hasPrefix("render ") } }

    /// Re-encode pictures `range` into a folder of its own and return that folder and the output.
    private func export(_ range: Range<Int>, audio: ReencodeAudio = .auto,
                        cancelled: (@Sendable () -> Bool)? = nil) throws -> (URL, URL) {
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let output = folder.appendingPathComponent("out.mp4")
        let engine = ReencodeEngine(cancelled: cancelled, helper: wrapper)
        let clip = ClipRequest(file: source, from: frames[range.lowerBound].time, to: frames[range.upperBound].time)
        do {
            try engine.write(engine.resolve([clip], output: output, container: "mp4",
                                            settings: ReencodeSettings(audio: audio)), to: output)
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            throw error
        }
        return (folder, output)
    }

    func testRemovingSoundSeeksPastDamageBeforeTheNearestRestartPoint() throws {
        let (_, output) = try export(80..<95, audio: .removeAudio)
        let written = try CutEngine().inspect(output, keyframes: true)
        XCTAssertEqual(written.frames.count, 15)
        XCTAssertTrue(written.audio.isEmpty)
        XCTAssertEqual(renders.count, 1)
        XCTAssertEqual(renders.first?.contains(" -ss 3000000us "), true)
    }

    func testCopiedSoundNeedsNoWarmUpSoDamageBeforeTheRangeIsNeverDecoded() throws {
        // Auto copies the AAC of a single MP4 trim, so the render seeks to keyframe 75 and never meets picture 40.
        let (folder, output) = try export(80..<95)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["out.mp4"])
        let written = try CutEngine().inspect(output, keyframes: true)
        XCTAssertEqual(written.frames.count, 15)
        XCTAssertEqual(written.audio.count, 1)
        XCTAssertEqual(renders.count, 1)
    }

    func testDamageInTheSoundWarmUpRendersOnceMoreFromTheNearestRestartPoint() throws {
        // Converted sound decodes from a warm-up before the range: the single input seeks to keyframe 25 and meets
        // picture 40. Keyframe 75 precedes the range.
        let (folder, output) = try export(80..<95, audio: .aac)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["out.mp4"])
        let written = try CutEngine().inspect(output, keyframes: true)
        XCTAssertEqual(written.frames.count, 15)
        XCTAssertEqual(written.audio.count, 1)

        let runs = renders
        XCTAssertEqual(runs.count, 2)
        guard runs.count == 2 else { return }
        func inputs(_ run: String) -> Int { run.components(separatedBy: " -i \(source.path)").count - 1 }
        XCTAssertEqual(inputs(runs[0]), 1)
        XCTAssertFalse(runs[0].contains(" -vn "))
        XCTAssertTrue(runs[0].contains(" -ss 1000000us "))
        // The picture input starts at keyframe 75. The sound input keeps the seek of the first render.
        XCTAssertEqual(inputs(runs[1]), 2)
        XCTAssertTrue(runs[1].contains(" -hwaccel videotoolbox"))
        XCTAssertTrue(runs[1].contains(" -ss 3000000us -i \(source.path) -threads 2 -vn "
                                       + "-seek_timestamp 1 -noaccurate_seek -ss 1000000us -i \(source.path) "))
    }

    func testDamageThatTheRangeNeedsReportsTheFirstFailureAfterTheSecondRender() throws {
        // Keyframe 25 is the restart point before picture 45, and picture 40 follows it. The sound is converted, so
        // the first render starts at its warm-up and a second one starts at the restart point.
        XCTAssertThrowsError(try export(45..<60, audio: .aac)) {
            let error = $0 as? CutError
            XCTAssertEqual(error?.code, "encode_failed")
            XCTAssertTrue(error?.message.hasPrefix("A picture in damaged.mp4 is damaged") == true, "\($0)")
        }
        let runs = renders
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.allSatisfy { $0.contains(" -hwaccel videotoolbox") })
    }

    func testDamageThatTheRangeNeedsRendersOnceWhenTheSoundIsCopied() throws {
        // With copied sound the first render already starts at keyframe 25, so another would decode the same pictures.
        XCTAssertThrowsError(try export(45..<60)) {
            let error = $0 as? CutError
            XCTAssertEqual(error?.code, "encode_failed")
            XCTAssertTrue(error?.message.hasPrefix("A picture in damaged.mp4 is damaged") == true, "\($0)")
        }
        XCTAssertEqual(renders.count, 1)
    }

    func testARangeBeforeAnyLaterRestartPointRendersOnce() throws {
        // No keyframe after the first precedes picture 10, so a second render would decode the same pictures.
        XCTAssertThrowsError(try export(10..<60)) {
            XCTAssertTrue(($0 as? CutError)?.message.contains("damaged") == true, "\($0)")
        }
        XCTAssertEqual(renders.count, 1)
    }

    func testACancelledExportDoesNotRenderAgain() throws {
        let file = scratch.appendingPathComponent("log")
        // Cancel once the failed render has been recognized as damage by a decoder probe.
        let cancelled: @Sendable () -> Bool = {
            let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
            guard let failed = lines.firstIndex(where: { $0.hasPrefix("render-exit") }) else { return false }
            return lines[failed...].contains { $0 == "other-exit 0" }
        }
        // Converted sound, so the first render meets the damage in its warm-up.
        XCTAssertThrowsError(try export(80..<95, audio: .aac, cancelled: cancelled)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
        XCTAssertEqual(renders.count, 1)
    }

    func testAnotherFailureIsNotRenderedAgain() throws {
        try Data().write(to: scratch.appendingPathComponent("refuse"))
        XCTAssertThrowsError(try export(80..<95)) {
            let error = $0 as? CutError
            XCTAssertEqual(error?.code, "encode_failed")
            XCTAssertEqual(error?.message, "Permission denied")
        }
        XCTAssertEqual(renders.count, 1)
    }
}
