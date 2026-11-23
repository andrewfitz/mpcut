import Foundation
import XCTest
@testable import MPCutCore

final class ReencodeProcessTests: XCTestCase {
    func testProgressResumesAfterAnOversizedStdoutLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("encoder")
        let script = """
            #!/bin/sh
            printf 'out_time_us=100000\\n'
            /usr/bin/head -c 32768 /dev/zero
            printf 'out_time_us=900000\\n'
            printf 'out_time_us=500000\\n'
            """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        var progress: [Double] = []
        try ReencodeEngine().runHelper(helper, arguments: [], in: directory, duration: RationalTime(numerator: 1)) {
            progress.append($0)
        }
        XCTAssertEqual(progress, [0.1, 0.5])
    }

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
        // Read errno before any other call can overwrite it.
        let status = kill(pid, 0)
        let code = errno
        XCTAssertEqual(status, -1, "The stalled helper \(pid) is still running")
        XCTAssertEqual(code, ESRCH)
    }
}
