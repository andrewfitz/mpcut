import Foundation
import SQLite3
import XCTest
@testable import MPCutCore

final class SidecarMetadataClockTests: XCTestCase {
    func testIndependentEditsToMigratedCopiesDoNotAdvanceUntouchedFields() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("source.mov")
        let projectURL = folder.appendingPathComponent("edit.cut")
        try Data([1]).write(to: file)
        try SidecarLocations.$storageDirectory.withValue(folder.appendingPathComponent("state")) {
            try SidecarLocations.$projectURL.withValue(projectURL) {
                let name = AnalysisSidecar.viewNameSectionKey
                let adjacent = try AnalysisSidecar(source: file)
                try adjacent.save([name: Data(#"{"1":"Original 1","2":"Original 2","3":"Original 3"}"#.utf8)])
                try SidecarLocations.setMode(.project)
                let project = try AnalysisSidecar(source: file)
                try project.save(["create": Data([2])])

                // Both copies have migrated legacy metadata whose individual
                // fields and section were never explicitly edited.
                for store in [adjacent, project] {
                    let db = try SidecarDatabase(store.url, writing: true)
                    try db.update("DELETE FROM sidecar_field_changes WHERE name = ?", [name])
                    try db.update("DELETE FROM sidecar_changes WHERE name = ?", [name])
                    try db.execute("UPDATE sidecar_location SET legacy_mtime = 123 WHERE id = 1")
                }
                try adjacent.pinned(to: adjacent.url).save([name: Data(#"{"1":"Ann","2":"Original 2"}"#.utf8)])
                try project.pinned(to: project.url).save([name: Data(#"{"1":"Original 1","2":"Ben","3":"Original 3"}"#.utf8)])
                let db = try SidecarDatabase(project.url, writing: true)
                func clock(_ field: String) throws -> Double? {
                    try db.statement("SELECT changed FROM sidecar_field_changes WHERE name = ? AND field = ?",
                                     [name, field]) { row in
                        sqlite3_step(row) == SQLITE_ROW ? sqlite3_column_double(row, 0) : nil
                    }
                }
                XCTAssertEqual(try clock("1"), -123)
                XCTAssertEqual(try clock("3"), -123)
                let expected = ["1": "Ann", "2": "Ben"]
                func names(_ store: AnalysisSidecar) throws -> [String: String] {
                    try JSONDecoder().decode([String: String].self, from: XCTUnwrap(store.read(name)))
                }
                XCTAssertEqual(try names(project), expected)

                // Old v5 copies may already have a recorded section edit but
                // lack the baseline clocks for values carried over from v4.
                try db.update("DELETE FROM sidecar_field_changes WHERE name = ? AND field IN ('1','3')", [name])
                XCTAssertEqual(try names(project), expected)
                try project.save(["publish": Data([3])])
                XCTAssertEqual(try names(project.pinned(to: project.url)), expected)
            }
        }
    }
}
