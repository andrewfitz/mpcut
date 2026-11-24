import Foundation
import XCTest
@testable import MPCutCore

final class ProjectMediaVolumeTests: XCTestCase {
    func testCheckingVolumeKeepsAbsoluteMediaPathOnSave() throws {
        let volume = "/Volumes/\(UUID())"
        let source = volume + "/Media/interview.mov"
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("edit.cut")
        XCTAssertNotEqual(CutProject.relativeMediaPath(source, to: project), source)
        try ProjectMediaVolume.$checking.withValue([volume]) {
            XCTAssertEqual(CutProject.relativeMediaPath(source, to: project), source)
            XCTAssertFalse(ProjectMediaVolume.isChecking(project))
            let blockedOutput = URL(fileURLWithPath: volume + "/new.cut", isDirectory: false)
            XCTAssertThrowsError(try CutProject.validateMediaDestination(blockedOutput, absoluteSources: [:])) {
                XCTAssertEqual(($0 as? CutError)?.code, "media_volume_checking")
            }
        }
    }

    func testWatchPathPreservesAnUnresolvedAncestor() {
        let project = URL(fileURLWithPath: "/Volumes/Example/edit.cut", isDirectory: false)
        let url = ProjectMediaVolume.watchURL("missing/../media.mov", relativeTo: project)
        XCTAssertEqual(url.path, "/Volumes/Example/missing/../media.mov")
        XCTAssertEqual(ProjectMediaVolume.key(for: url), "/Volumes/Example")
    }
}
