import MPCutCore
import XCTest

final class MulticamJPEGExportTests: XCTestCase {
    func testUnsavedCameraReviewPreservesLeadingPictureGap() throws {
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes",
                                                    withExtension: "mov", subdirectory: "Fixtures"))
        let indexed = try CutEngine(useSidecar: false).inspectMulticamSource(movie)
        let first = try XCTUnwrap(indexed.frames.first)
        XCTAssertGreaterThan(first.time, .zero)
        let project = MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: indexed.duration),
                                      angles: [.init(id: "camera", file: movie.path)],
                                      audio: .none, switches: [.init(at: .zero, angle: "camera")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try JPEGExport.writeMulticam(project, document: nil, at: [.zero, first.time],
            to: directory, preset: .review, useSidecar: false, indexedSources: ["camera": indexed],
            cancelled: { false })
        XCTAssertNil(manifest.projectPath)
        XCTAssertNil(manifest.frames[0].file)
        XCTAssertEqual(manifest.frames[0].availability, .pictureGap)
        XCTAssertEqual(manifest.frames[1].frameTime, first.time)
        let frame = try XCTUnwrap(manifest.frames[1].file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(frame).path))
    }
}
