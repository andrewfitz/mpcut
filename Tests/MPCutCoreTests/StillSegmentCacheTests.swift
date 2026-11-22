import Foundation
import XCTest
@testable import MPCutCore

final class StillSegmentCacheTests: XCTestCase {
    func testReuseValidationAndCorruptionRecovery() throws {
        try withDirectory { directory in
            let cache = StillSegmentCache(directory: directory, shardCount: 1)
            let key = try StillSegmentCache.Key(files: [], parameters: ["cadence": "30000/1001"])
            var generations = 0
            var validations = 0

            func render() throws -> URL {
                try cache.withSegment(key: key, outputExtension: "mov", generate: { url in
                    generations += 1
                    try Data("movie".utf8).write(to: url)
                }, validate: { url in
                    validations += 1
                    XCTAssertEqual(try Data(contentsOf: url), Data("movie".utf8))
                }, use: { $0 })
            }

            let first = try render()
            XCTAssertEqual(try render(), first)
            XCTAssertEqual(generations, 1)
            XCTAssertEqual(validations, 2)
            try Data("broken".utf8).write(to: first)
            XCTAssertEqual(try render(), first)
            XCTAssertEqual(generations, 2)
            XCTAssertEqual(validations, 3)
        }
    }

    func testContentAndParametersDetermineIdentity() throws {
        try withDirectory { directory in
            let first = directory.appendingPathComponent("first")
            let second = directory.appendingPathComponent("second")
            try Data([1]).write(to: first)
            try Data([1]).write(to: second)
            let cache = StillSegmentCache(directory: directory.appendingPathComponent("cache"), shardCount: 1)

            func entry(_ source: URL, _ frames: Int) throws -> URL {
                let key = try StillSegmentCache.Key(files: [source], parameters: frames)
                return try cache.withSegment(key: key, outputExtension: "mov",
                                             generate: { try Data([0]).write(to: $0) },
                                             validate: { _ in }, use: { $0 })
            }

            let original = try entry(first, 10)
            XCTAssertEqual(try entry(second, 10), original)
            XCTAssertNotEqual(try entry(first, 11), original)
            try Data([2]).write(to: second)
            XCTAssertNotEqual(try entry(second, 10), original)
        }
    }

    func testCancellationAndValidationFailureDiscardStage() throws {
        try withDirectory { directory in
            let cache = StillSegmentCache(directory: directory, shardCount: 1)
            let key = try StillSegmentCache.Key(files: [], parameters: 1)
            var cancelled = false
            XCTAssertThrowsError(try cache.withSegment(key: key, outputExtension: "mov",
                                                        cancelled: { cancelled }, generate: { url in
                try Data([0]).write(to: url)
                cancelled = true
            }, validate: { _ in XCTFail("Cancelled generation was validated.") }, use: { _ in
                XCTFail("Cancelled generation was used.")
            })) { XCTAssertEqual(($0 as? CutError)?.code, "cancelled") }
            cancelled = false
            XCTAssertThrowsError(try cache.withSegment(key: key, outputExtension: "mov",
                                                        generate: { try Data([0]).write(to: $0) },
                                                        validate: { _ in throw CocoaError(.fileReadCorruptFile) },
                                                        use: { _ in XCTFail("Invalid generation was used.") }))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("0").path), [])
        }
    }

    func testChangedInputIsRejectedBeforePublishing() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("image")
            try Data([0]).write(to: source)
            let cache = StillSegmentCache(directory: directory, shardCount: 1)
            let key = try StillSegmentCache.Key(files: [source], parameters: 1)
            XCTAssertThrowsError(try cache.withSegment(key: key, outputExtension: "mov", generate: { url in
                try Data([0]).write(to: url)
                try Data([0, 1]).write(to: source)
            }, validate: { _ in XCTFail("Media from a changed input was validated.") }, use: { _ in
                XCTFail("Media from a changed input was used.")
            })) { XCTAssertEqual(($0 as? CutError)?.code, "source_changed") }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("0").path), [])
        }
    }

    func testPrunesOldEntriesAndUsesOversizedMediaTemporarily() throws {
        try withDirectory { directory in
            let cache = StillSegmentCache(directory: directory, maximumBytes: 10, maximumEntries: 2, shardCount: 1)
            func render(_ id: Int, size: Int) throws -> URL {
                let key = try StillSegmentCache.Key(files: [], parameters: id)
                return try cache.withSegment(key: key, outputExtension: "mov",
                                             generate: { try Data(repeating: 0, count: size).write(to: $0) },
                                             validate: { _ in }, use: { url in
                    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                    return url
                })
            }

            let first = try render(1, size: 6)
            let second = try render(2, size: 6)
            let oversized = try render(3, size: 11)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
        }
    }

    func testConcurrentRequestsGenerateOneEntry() throws {
        try withDirectory { directory in
            let cache = StillSegmentCache(directory: directory.appendingPathComponent("cache"), shardCount: 1)
            let key = try StillSegmentCache.Key(files: [], parameters: 1)
            let expected = Data([1, 2, 3])
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                do {
                    let bytes = try cache.withSegment(key: key, outputExtension: "mov", generate: { url in
                        let receipt = directory.appendingPathComponent(String(index))
                        try expected.write(to: receipt)
                        try expected.write(to: url)
                    }, validate: { url in
                        XCTAssertEqual(try Data(contentsOf: url), expected)
                    }, use: { try Data(contentsOf: $0) })
                    XCTAssertEqual(bytes, expected)
                } catch {
                    XCTFail("Concurrent cache request failed: \(error)")
                }
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(files.filter { $0 != "cache" }.count, 1)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
