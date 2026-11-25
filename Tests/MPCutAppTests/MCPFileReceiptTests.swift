import CryptoKit
import Foundation
import XCTest
@testable import MPCutApp

final class MCPFileReceiptTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file-receipts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    @MainActor
    func testConcurrentWorkersShareAdmissionAndReconnectCanPageAndRelease() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("cli")
        let count = folder.appendingPathComponent("mutations")
        let gate = folder.appendingPathComponent("finish")
        let script = """
        #!/bin/sh
        cd -- "$(dirname "$0")"
        printf x >> mutations
        while [ ! -f finish ]; do
            [ -d "$PWD" ] || exit 1
            sleep 0.02
        done
        head -c 150000 /dev/zero
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let receipts = MCPFileReceipts(root: folder.appendingPathComponent("receipts"))
        let first = MCPFileJobs(executable: executable, receipts: receipts)
        let second = MCPFileJobs(executable: executable, receipts: receipts)
        let id = UUID()
        let args = ["operation_id": id.uuidString]
        XCTAssertEqual(try first.start(tool: "cli_version_read", arguments: args)["state"] as? String, "running")
        XCTAssertEqual(try second.start(tool: "cli_version_read", arguments: args)["state"] as? String, "running")
        XCTAssertThrowsError(try second.release(id: id))
        XCTAssertThrowsError(try second.start(tool: "cli_help_read", arguments: args)) {
            XCTAssertEqual(($0 as? MCPCommandError)?.code, "operation_id_conflict")
        }
        try Data().write(to: gate)

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try second.status(id: id)["state"] as? String == "running", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let reconnected = MCPFileJobs(executable: executable, receipts: receipts)
        let status = try reconnected.status(id: id)
        XCTAssertEqual(status["state"] as? String, "succeeded")
        XCTAssertEqual(status["result_bytes"] as? Int, 150_000)
        XCTAssertNil(status["result"])
        let firstPage = try reconnected.read(id: id, offset: nil, limit: nil)
        let secondPage = try reconnected.read(id: id, offset: firstPage["next_offset"], limit: nil)
        let a = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(firstPage["base64"] as? String)))
        let b = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(secondPage["base64"] as? String)))
        XCTAssertEqual(a + b, Data(repeating: 0, count: 150_000))
        XCTAssertEqual(secondPage["done"] as? Bool, true)

        XCTAssertEqual(try reconnected.release(id: id)["result_available"] as? Bool, false)
        XCTAssertEqual(try second.release(id: id)["state"] as? String, "succeeded")
        XCTAssertThrowsError(try first.read(id: id, offset: nil, limit: nil)) {
            XCTAssertEqual(($0 as? MCPCommandError)?.code, "job_result_unavailable")
        }
        XCTAssertEqual(try reconnected.start(tool: "cli_version_read", arguments: args)["state"] as? String, "succeeded")
        XCTAssertEqual(try Data(contentsOf: count), Data("x".utf8))
    }

    @MainActor
    func testClosedAdmissionBecomesUnknownAndCannotBeRestarted() throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MCPFileReceipts(root: folder.appendingPathComponent("receipts"))
        let id = UUID()
        let digest = Data(SHA256.hash(data: Data("{}".utf8)))
        guard case let .admitted(admission) = try store.lookupOrAdmit(
            id: id, tool: "cli_version_read", fingerprint: digest, prepare: {}
        ) else {
            return XCTFail("Expected new standalone admission")
        }
        let worker = MCPFileJobs(receipts: store)
        XCTAssertEqual(try worker.status(id: id)["state"] as? String, "running")
        let abandonedInput = admission.directory.appendingPathComponent("request.json")
        let abandonedOutput = admission.directory.appendingPathComponent("stdout")
        try Data("request".utf8).write(to: abandonedInput)
        try Data("CLI output".utf8).write(to: abandonedOutput)
        try admission.lock.close()
        XCTAssertEqual(try worker.status(id: id)["state"] as? String, "outcome_unknown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedInput.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedOutput.path))
        XCTAssertEqual(try worker.release(id: id)["state"] as? String, "outcome_unknown")
        let replay = try worker.start(tool: "cli_version_read", arguments: ["operation_id": id.uuidString])
        XCTAssertEqual(replay["state"] as? String, "outcome_unknown")
        guard case let .existing(record) = try store.lookupOrAdmit(
            id: id, tool: "cli_version_read", fingerprint: digest, prepare: { XCTFail("Unexpected replay") }
        ) else {
            return XCTFail("Interrupted operation should reuse its admission")
        }
        XCTAssertEqual(record.fingerprint, digest)
        XCTAssertNotNil(record.endedAt)
        XCTAssertThrowsError(try worker.read(id: id, offset: nil, limit: nil))
    }
}
