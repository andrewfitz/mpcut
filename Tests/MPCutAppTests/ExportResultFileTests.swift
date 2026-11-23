import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ExportResultFileTests: XCTestCase {
    func testPublishesResultBesideMediaWithoutReplacingExistingResult() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Assembly.mov")
        let mapping = MulticamPlan(intervals: [], picture: [], audio: [], duration: .zero)
        let result = try ExportResultFile(output: output, plan: mapping, cutMap: ExportCutMap(multicam: mapping))
        XCTAssertEqual(result.url.lastPathComponent, "Assembly.mov.export.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.path))
        try Data().write(to: output)
        XCTAssertTrue(result.completionMessage(for: output).contains(" and "))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        XCTAssertEqual(json["output"] as? String, output.path)
        XCTAssertEqual((json["cut_map"] as? [String: Any])?["version"] as? Int, 1)
        XCTAssertThrowsError(try ExportResultFile(output: output, plan: mapping, cutMap: ExportCutMap(multicam: mapping)))

        let other = folder.appendingPathComponent("Second.mov")
        let competing = try ExportResultFile(output: other, plan: mapping, cutMap: ExportCutMap(multicam: mapping))
        try Data().write(to: other)
        let existing = Data("existing result".utf8)
        try existing.write(to: competing.url)
        XCTAssertTrue(competing.completionMessage(for: other).contains("Couldn’t save"))
        XCTAssertEqual(try Data(contentsOf: competing.url), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
