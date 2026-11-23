import Darwin
import Foundation
import XCTest
@testable import MPCutCore

/// An access grant writes metadata to a recording while MPCut reads it. Only a change to the media is a failure.
final class ProbeMetadataChangeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("probe-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeClip() throws -> URL {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile)
        guard let ffmpeg else { throw XCTSkip("Needs ffmpeg to make a video fixture.") }
        let source = directory.appendingPathComponent("clip.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=1",
                             "-c:v", "mpeg4", source.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return source
    }

    func testAttributeWrittenDuringInspectionDoesNotFailTheRead() throws {
        let clip = try makeClip()
        var written = false
        let media = try Probe.read(clip, cancelled: {
            // Once, as an Open panel's access grant would.
            if !written {
                written = true
                let value = Data([1, 2, 3])
                _ = value.withUnsafeBytes { setxattr(clip.path, "com.mpcut.test-grant", $0.baseAddress, $0.count, 0, 0) }
            }
            return false
        })
        XCTAssertTrue(written, "The probe never polled for cancellation, so no change was made mid-read.")
        XCTAssertTrue(media.identity.isCurrentSnapshot(at: clip))
    }

    func testAttributeWrittenOnEveryReadIsReported() throws {
        let clip = try makeClip()
        var count: UInt8 = 0
        XCTAssertThrowsError(try Probe.read(clip, cancelled: {
            count &+= 1
            let value = Data([count])
            _ = value.withUnsafeBytes { setxattr(clip.path, "com.mpcut.test-grant", $0.baseAddress, $0.count, 0, 0) }
            return false
        })) { error in
            XCTAssertEqual((error as? CutError)?.code, "source_changed")
        }
    }

    func testContentChangeDuringInspectionIsReported() throws {
        let clip = try makeClip()
        var appended = false
        XCTAssertThrowsError(try Probe.read(clip, cancelled: {
            if !appended, let handle = try? FileHandle(forWritingTo: clip) {
                appended = true
                handle.seekToEndOfFile()
                handle.write(Data(repeating: 0, count: 16))
                try? handle.close()
            }
            return false
        })) { error in
            XCTAssertEqual((error as? CutError)?.code, "source_changed")
        }
    }
}
