import Foundation
import MPCutCore
import XCTest

final class MediaExportIdentityTests: XCTestCase {
    private func withRecording(_ body: (URL, URL) throws -> Void) throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        try body(source, directory)
    }

    func testReplacementPreflightRejectsMediaChangedSinceSelection() throws {
        try withRecording { source, directory in
            let donor = directory.appendingPathComponent("donor.mov")
            try FileManager.default.copyItem(at: source, to: donor)
            let cut = CutEngine(useSidecar: false)
            let movie = try cut.inspectSummary(source)
            let replacement = try cut.inspectSummary(donor)
            let track = try XCTUnwrap(movie.streams.first { $0.kind == "audio" }).index
            let engine = AudioReplacementEngine(useSidecar: false)

            func resolve() throws {
                _ = try engine.resolve(source: movie, replacement: replacement, container: "mov",
                                       targetStream: track, replacementStream: track)
            }

            // An equivalent file at the same path still has a new identity.
            let previousDonor = directory.appendingPathComponent("previous-donor.mov")
            try FileManager.default.moveItem(at: donor, to: previousDonor)
            try FileManager.default.copyItem(at: source, to: donor)
            XCTAssertThrowsError(try resolve()) { error in
                XCTAssertEqual((error as? CutError)?.code, "source_changed")
                XCTAssertTrue(error.localizedDescription.contains(donor.lastPathComponent))
            }
            try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent("previous-source.mov"))
            try FileManager.default.copyItem(at: donor, to: source)
            XCTAssertThrowsError(try resolve()) { error in
                XCTAssertEqual((error as? CutError)?.code, "source_changed")
                XCTAssertTrue(error.localizedDescription.contains(source.lastPathComponent))
            }
        }
    }

    func testStillAndReviewExportRejectRemovedRecording() throws {
        try withRecording { source, directory in
            let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
            try FileManager.default.removeItem(at: source)
            let still = directory.appendingPathComponent("frame.jpg")
            let review = directory.appendingPathComponent("review")
            XCTAssertThrowsError(try JPEGExport.writeStill(media, at: .zero, to: still)) { error in
                XCTAssertEqual((error as? CutError)?.code, "source_changed")
            }
            XCTAssertThrowsError(try JPEGExport.write(media, to: review, selection: .times([.zero]))) { error in
                XCTAssertEqual((error as? CutError)?.code, "source_changed")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
}
