import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class ExclusivePublishTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func unsupported(_ code: Int32) -> (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32 {
        { _, _, _ in errno = code; return -1 }
    }

    func testFilePublishesWithoutAnExclusiveRename() throws {
        let fm = FileManager.default
        for code in [ENOTSUP, EINVAL] {
            let staged = directory.appendingPathComponent("staged"), output = directory.appendingPathComponent("out-\(code)")
            try Data([1, 2]).write(to: staged)
            XCTAssertEqual(publishExclusively(from: staged, to: output, exclusiveRename: unsupported(code)), 0)
            XCTAssertEqual(try Data(contentsOf: output), Data([1, 2]))
            XCTAssertFalse(fm.fileExists(atPath: staged.path))

            try Data([3]).write(to: staged)
            XCTAssertEqual(publishExclusively(from: staged, to: output, exclusiveRename: unsupported(code)), EEXIST)
            XCTAssertEqual(try Data(contentsOf: output), Data([1, 2]))
            XCTAssertEqual(try Data(contentsOf: staged), Data([3]))
            try fm.removeItem(at: staged)
        }
        // A failed move leaves no placeholder behind.
        let missing = directory.appendingPathComponent("missing"), output = directory.appendingPathComponent("unused")
        XCTAssertEqual(publishExclusively(from: missing, to: output, exclusiveRename: unsupported(ENOTSUP)), ENOENT)
        XCTAssertFalse(fm.fileExists(atPath: output.path))
        // Other failures are reported as they are.
        try Data([4]).write(to: missing)
        XCTAssertEqual(publishExclusively(from: missing, to: output, exclusiveRename: unsupported(EACCES)), EACCES)
        XCTAssertFalse(fm.fileExists(atPath: output.path))
    }

    func testDirectoryPublishesWithoutAnExclusiveRename() throws {
        let fm = FileManager.default
        let staged = directory.appendingPathComponent("staged"), output = directory.appendingPathComponent("frames")
        func stage() throws {
            try fm.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            try Data([1]).write(to: staged.appendingPathComponent("manifest.json"))
        }
        try stage()
        XCTAssertEqual(publishExclusively(from: staged, to: output, isDirectory: true, exclusiveRename: unsupported(ENOTSUP)), 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), ["manifest.json"])
        XCTAssertFalse(fm.fileExists(atPath: staged.path))
        XCTAssertEqual(try fm.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int, 0o755)

        try stage()
        XCTAssertEqual(publishExclusively(from: staged, to: output, isDirectory: true, exclusiveRename: unsupported(ENOTSUP)), EEXIST)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: staged.path), ["manifest.json"])
        // An existing empty folder also counts as taken.
        let empty = directory.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: false)
        XCTAssertEqual(publishExclusively(from: staged, to: empty, isDirectory: true, exclusiveRename: unsupported(ENOTSUP)), EEXIST)
        try fm.removeItem(at: staged)
        let unused = directory.appendingPathComponent("unused")
        XCTAssertEqual(publishExclusively(from: staged, to: unused, isDirectory: true, exclusiveRename: unsupported(ENOTSUP)), ENOENT)
        XCTAssertFalse(fm.fileExists(atPath: unused.path))
    }

    func testNativeExclusiveRenameReportsAnExistingDestination() throws {
        let staged = directory.appendingPathComponent("staged"), output = directory.appendingPathComponent("out")
        try Data([1]).write(to: staged)
        try Data([2]).write(to: output)
        XCTAssertEqual(publishExclusively(from: staged, to: output), EEXIST)
        try FileManager.default.removeItem(at: output)
        XCTAssertEqual(publishExclusively(from: staged, to: output), 0)
        XCTAssertEqual(try Data(contentsOf: output), Data([1]))
    }

    func testFrameExportFolderUsesOrdinaryPermissions() throws {
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
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let output = directory.appendingPathComponent("frames")
        let manifest = try JPEGExport.write(media, to: output, selection: .times([.zero]), useSidecar: false)
        XCTAssertEqual(manifest.frames.count, 1)
        var info = stat()
        XCTAssertEqual(stat(output.path, &info), 0)
        let ordinary = directory.appendingPathComponent("ordinary")
        XCTAssertEqual(mkdir(ordinary.path, 0o777), 0)
        var expected = stat()
        XCTAssertEqual(stat(ordinary.path, &expected), 0)
        XCTAssertEqual(info.st_mode & 0o7777, expected.st_mode & 0o7777)
    }
}
