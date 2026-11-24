import Foundation
import XCTest
@testable import MPCutCore

final class SidecarPlacementTests: XCTestCase {
    func testFailedWriteAcrossLocationsPreservesPreviousCopyAndCanBeRetried() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let disk = root.appendingPathComponent("disk")
        let project = root.appendingPathComponent("edits/project.cut")
        try fm.createDirectory(at: disk, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("prefs")) {
            try SidecarLocations.chooseDisk(disk)
            try SidecarLocations.$projectURL.withValue(project) {
                for first in SidecarStorageMode.allCases {
                    for next in SidecarStorageMode.allCases {
                        let folder = root.appendingPathComponent("\(first)-\(next)")
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                        let source = folder.appendingPathComponent("interview.mov")
                        try Data(folder.path.utf8).write(to: source)
                        try SidecarLocations.setMode(first)
                        let original = try AnalysisSidecar(source: source)
                        try original.save(["analysis": Data([1]), "keep": Data([2])])
                        try SidecarLocations.setMode(next)
                        let current = try AnalysisSidecar(source: source)
                        XCTAssertEqual(current.read("analysis"), Data([1]))
                        if first != next { XCTAssertFalse(fm.fileExists(atPath: current.url.path)) }
                        XCTAssertThrowsError(try current.save(["analysis": Data([9])], updating: [
                            "keep": { _ in throw CancellationError() }
                        ]))
                        XCTAssertEqual(original.read("analysis"), Data([1]))
                        if first != next { XCTAssertFalse(fm.fileExists(atPath: current.url.path)) }
                        try current.save(["analysis": Data([3])])
                        XCTAssertEqual(current.read("keep"), Data([2]))
                        for placement in SidecarStorageMode.allCases {
                            try SidecarLocations.setMode(placement)
                            let reader = try AnalysisSidecar(source: source)
                            XCTAssertEqual(reader.read("analysis"), Data([3]), "\(first) → \(next), reading from \(placement)")
                        }
                    }
                }
            }
        }
    }
}
