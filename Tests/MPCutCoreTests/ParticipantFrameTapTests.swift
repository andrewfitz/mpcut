import Foundation
import MediaProbe
import XCTest

final class ParticipantFrameTapTests: XCTestCase {
    func testH264TapPreservesFrameDurationAndDeclaredColor() throws {
        let path = try fixture(extension: "mp4", arguments: [
            "-f", "lavfi", "-i", "nullsrc=s=128x96:r=25:d=0.2,geq=lum=32:cb=200:cr=100,format=yuv420p",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_range", "pc"
        ])
        let samples = try scan(path)
        XCTAssertEqual(samples.count, 5)
        assertClock(samples)
        for sample in samples {
            // Reference from FFmpeg's explicit full-range BT.709 conversion.
            XCTAssertEqual(sample.red, 0, accuracy: 2)
            XCTAssertEqual(sample.green, 13, accuracy: 2)
            XCTAssertEqual(sample.blue, 162, accuracy: 2)
        }
    }

    func testPackedRGBTapPreservesComponents() throws {
        let path = try fixture(extension: "nut", arguments: [
            "-f", "lavfi", "-i", "nullsrc=s=128x96:r=25:d=0.2,format=gbrp,geq=r=23:g=97:b=201",
            "-c:v", "rawvideo", "-pix_fmt", "rgb24"
        ])
        let samples = try scan(path)
        XCTAssertEqual(samples.count, 5)
        assertClock(samples)
        for sample in samples {
            XCTAssertEqual([sample.red, sample.green, sample.blue], [23, 97, 201])
        }
    }

    private struct Sample {
        let pts: Int64
        let duration: Int64
        let red: Int
        let green: Int
        let blue: Int
    }

    private func scan(_ file: URL) throws -> [Sample] {
        var samples: [Sample] = []
        var damage: Int32 = 0
        var message = [CChar](repeating: 0, count: 256)
        let status = withUnsafeMutablePointer(to: &samples) { context in
            file.withUnsafeFileSystemRepresentation { path in
                mp_participant_scan(path, 0, { _ in 0 }, { context, pts, duration, rgb, width, height, stride, _, _ in
                    guard let context, let rgb else { return 1 }
                    let pixel = rgb.advanced(by: (Int(height) / 2) * Int(stride) + (Int(width) / 2) * 3)
                    context.assumingMemoryBound(to: [Sample].self).pointee.append(
                        Sample(pts: pts, duration: duration, red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2])))
                    return 0
                }, nil, UnsafeMutableRawPointer(context), &damage, &message, message.count)
            }
        }
        XCTAssertEqual(status, 0, String(cString: message))
        XCTAssertEqual(damage, 0)
        return samples
    }

    private func assertClock(_ samples: [Sample], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(samples.first?.pts, 0, file: file, line: line)
        for (sample, next) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThan(sample.duration, 0, file: file, line: line)
            XCTAssertEqual(sample.pts + sample.duration, next.pts, file: file, line: line)
        }
        XCTAssertEqual(samples.last?.duration, samples.first?.duration, file: file, line: line)
    }

    private func fixture(extension fileExtension: String, arguments: [String]) throws -> URL {
        let paths = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("The participant frame tap fixture requires ffmpeg.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-frame-tap-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("swatch").appendingPathExtension(fileExtension)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + arguments + [output.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("The installed ffmpeg could not encode the participant frame tap fixture.")
        }
        return output
    }
}
