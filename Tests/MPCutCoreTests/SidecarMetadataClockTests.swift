import Foundation
import XCTest
@testable import MPCutCore

final class SidecarMetadataClockTests: XCTestCase {
    func testCutcacheRefusesProjectDecisionsAndRecognitionResults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("camera.mov")
        try Data([1]).write(to: source)
        let cache = try AnalysisSidecar(source: source)
        for name in ["scenes_view_names.v1", "silence_threshold_overrides_db.v1", "transcript_recognition.v2.0.example"] {
            XCTAssertThrowsError(try cache.save([name: Data()]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.url.path))
    }
}
