import Foundation
import XCTest
@testable import MPCutCore

final class ReencodeProcessTests: XCTestCase {
    func testStalledEncoderStartupTimesOutAndReapsHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("encoder")
        try "#!/bin/sh\necho $$ > pid\nexec /bin/sleep 30\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        XCTAssertThrowsError(try ReencodeEngine().runHelper(helper, arguments: [], in: directory, timeout: .seconds(1))) {
            XCTAssertEqual(($0 as? CutError)?.code, "encoder_unavailable")
        }
        let rawPID = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
