import Foundation
import MediaProbe
import XCTest

final class NativeSceneScanTests: XCTestCase {
    private struct Marker: Equatable {
        let pts: Int64
        let descriptor: Data
    }

    private final class Capture {
        var markers: [Marker] = []
        var checkpoint = Data()
        var ordinal: Int64 = 0
        var decodedPTS: Int64 = .min
        var confirmedPTS: Int64 = .min
        var stopAt: Int64?
    }

    private func scan(_ file: URL, range: Range<Int64>? = nil, resume: Data = Data(),
                      capture: Capture) -> Int32 {
        var error = [CChar](repeating: 0, count: 256)
        let context = Unmanaged.passUnretained(capture).toOpaque()
        return resume.withUnsafeBytes { bytes in
            var options = MPSceneScanOptions(
                has_range: range == nil ? 0 : 1, start_pts: range?.lowerBound ?? 0,
                end_pts: range?.upperBound ?? 0, resume: bytes.bindMemory(to: UInt8.self).baseAddress,
                resume_size: bytes.count)
            return mp_scene_scan_resumable(file.path, 0, &options, { pointer in
                let capture = Unmanaged<Capture>.fromOpaque(pointer!).takeUnretainedValue()
                return capture.ordinal >= (capture.stopAt ?? .max) ? 1 : 0
            }, { pointer, pts, feature in
                guard let feature else { return }
                let capture = Unmanaged<Capture>.fromOpaque(pointer!).takeUnretainedValue()
                let descriptor = Data(bytes: feature, count: Int(MP_SCENE_FEATURE_SIZE))
                capture.markers.append(Marker(pts: pts, descriptor: descriptor))
            }, { pointer, decoded, confirmed, ordinal, state, size in
                let capture = Unmanaged<Capture>.fromOpaque(pointer!).takeUnretainedValue()
                capture.decodedPTS = decoded
                capture.confirmedPTS = confirmed
                capture.ordinal = ordinal
                capture.checkpoint = Data(bytes: state!, count: size)
            }, context, &error, error.count)
        }
    }

    private func withFixture(_ name: String, source: String, encoder: [String],
                             run: (URL) -> Void) throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile)
        guard let ffmpeg else { throw XCTSkip("Needs ffmpeg to make scene fixtures.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", source, "-an", "-fps_mode", "passthrough"]
            + encoder + [file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("ffmpeg could not encode \(name).") }
        run(file)
    }

    func testResumeMatchesUninterruptedVFRWithOpenGOPAndFlashes() throws {
        let source = "nullsrc=size=160x90:rate=25:duration=19.2,"
            + "geq=lum='80+60*mod(floor(N/40),2)+70*eq(mod(N,97),0)+75*eq(N,479)':"
            + "cb='90+60*mod(floor(N/59),2)':cr=128,setpts='PTS+floor(N/7)'"
        let encoder = [
            "-c:v", "libx264",
            "-x264-params", "open-gop=1:keyint=100:min-keyint=100:scenecut=0",
            "-bf", "3", "-video_track_timescale", "10000"
        ]
        try withFixture("scenes.mp4", source: source, encoder: encoder) { file in
            verifyOpenGOP(file)
        }
    }

    private func verifyOpenGOP(_ file: URL) {
        let whole = Capture()
        XCTAssertEqual(scan(file, capture: whole), 0)
        XCTAssertEqual(whole.ordinal, 480)
        XCTAssertGreaterThan(whole.markers.count, 10)
        XCTAssertEqual(whole.markers.last?.pts, whole.decodedPTS)
        XCTAssertFalse(whole.markers.contains { $0.pts == 177_200 })

        let paused = Capture()
        paused.stopAt = 320
        XCTAssertEqual(scan(file, capture: paused), Int32(MP_SCENE_SCAN_CANCELLED))
        XCTAssertEqual(paused.ordinal, 320)
        XCTAssertLessThan(paused.confirmedPTS, paused.decodedPTS)
        paused.stopAt = 480
        XCTAssertEqual(scan(file, resume: paused.checkpoint, capture: paused), Int32(MP_SCENE_SCAN_CANCELLED))
        XCTAssertEqual(paused.ordinal, 480)
        XCTAssertNotEqual(paused.markers.last?.pts, paused.decodedPTS)
        paused.stopAt = nil
        XCTAssertEqual(scan(file, resume: paused.checkpoint, capture: paused), 0)
        XCTAssertEqual(paused.markers, whole.markers)
        XCTAssertEqual(paused.ordinal, whole.ordinal)

        let trim: Range<Int64> = 150_000..<190_000
        let local = Capture()
        XCTAssertEqual(scan(file, range: trim, capture: local), 0)
        XCTAssertLessThan(local.ordinal, 230)
        XCTAssertEqual(local.confirmedPTS, trim.upperBound)
        XCTAssertEqual(local.markers.first?.pts, Int64.min + 1)
        XCTAssertTrue(local.markers.dropFirst().allSatisfy { trim.contains($0.pts) })
        XCTAssertFalse(local.markers.contains { $0.pts == 177_200 })

        let localPaused = Capture()
        localPaused.stopAt = 96
        XCTAssertEqual(scan(file, range: trim, capture: localPaused), Int32(MP_SCENE_SCAN_CANCELLED))
        localPaused.stopAt = nil
        XCTAssertEqual(scan(file, range: trim, resume: localPaused.checkpoint, capture: localPaused), 0)
        XCTAssertEqual(localPaused.markers, local.markers)

        let mismatch = Capture()
        XCTAssertEqual(scan(file, resume: localPaused.checkpoint, capture: mismatch), Int32(MP_SCENE_RESUME_MISMATCH))
        XCTAssertTrue(mismatch.markers.isEmpty)
        XCTAssertTrue(mismatch.checkpoint.isEmpty)
    }

    func testResumeReconcilesDuplicatePresentationTimestamps() throws {
        let source = "nullsrc=size=80x60:rate=25:duration=8,"
            + "geq=lum='80+100*mod(floor(N/14),2)':cb=90:cr=128,setpts='floor(N/2)*2'"
        try withFixture("duplicates.mkv", source: source, encoder: ["-c:v", "ffv1", "-g", "13"]) { file in
            let whole = Capture()
            XCTAssertEqual(scan(file, capture: whole), 0)
            XCTAssertEqual(whole.ordinal, 200)
            XCTAssertGreaterThan(whole.markers.count, 1)

            let paused = Capture()
            paused.stopAt = 96
            XCTAssertEqual(scan(file, capture: paused), Int32(MP_SCENE_SCAN_CANCELLED))
            XCTAssertEqual(paused.ordinal, 96)
            XCTAssertEqual(paused.confirmedPTS, paused.decodedPTS)
            paused.stopAt = nil
            XCTAssertEqual(scan(file, resume: paused.checkpoint, capture: paused), 0)
            XCTAssertEqual(paused.markers, whole.markers)
            XCTAssertEqual(paused.ordinal, whole.ordinal)
        }
    }
}
