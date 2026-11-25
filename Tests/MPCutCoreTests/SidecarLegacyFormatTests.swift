import Foundation
import XCTest
@testable import MPCutCore

final class SidecarLegacyFormatTests: XCTestCase {
    func testOldFileIsIgnoredAndItsHeaderIsRefusedAtTheNewDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("settings")) {
            let source = root.appendingPathComponent("camera.mov")
            try Data([1]).write(to: source)
            let legacy = source.appendingPathExtension("cutdb")
            try Data().write(to: legacy)
            do {
                let db = try SidecarDatabase(legacy, writing: true)
                try db.execute("PRAGMA application_id = 0x4d504354; PRAGMA user_version = 5; CREATE TABLE user_notes(value TEXT)")
            }
            let before = try Data(contentsOf: legacy)
            let store = try AnalysisSidecar(source: source)
            XCTAssertEqual(store.status(), "missing")
            XCTAssertEqual(store.url, source.appendingPathExtension("cutcache"))
            try store.save(["test": Data([42])])
            XCTAssertEqual(store.read("test"), Data([42]))
            XCTAssertEqual(try Data(contentsOf: legacy), before)
            try FileManager.default.removeItem(at: store.url)
            try FileManager.default.copyItem(at: legacy, to: store.url)
            XCTAssertEqual(store.status(), "unsupported")
            XCTAssertThrowsError(try store.save(["test": Data([0])])) {
                XCTAssertEqual(($0 as? CutError)?.code, "unsupported_sidecar")
            }
            XCTAssertEqual(try Data(contentsOf: store.url), before)
        }
    }
}
