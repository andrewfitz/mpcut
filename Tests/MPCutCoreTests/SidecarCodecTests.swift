import Foundation
import XCTest
@testable import MPCutCore

final class SidecarCodecTests: XCTestCase {
    func testLZFSEStreamMustExactlyFillStoredBlob() throws {
        for size in [65535, 65536, 65537, 2 * 65536] {
            let value = Data(repeating: 42, count: size)
            let stored = try SidecarPayload.encode(value, cancelled: { false })
            XCTAssertEqual(stored.bytes.first, 1)
            XCTAssertEqual(try stored.decode(cancelled: { false }), value)
            for bytes in [stored.bytes.dropLast(), stored.bytes + Data([0]), stored.bytes + stored.bytes.dropFirst()] {
                XCTAssertNil(try SidecarPayload(bytes: bytes, logicalSize: size).decode(cancelled: { false }))
            }
        }
    }

    func testLongActivityLevelChecksCancellationWithinOneWindow() throws {
        let digits = String(repeating: "7", count: 200_000)
        let value = Data(#"{"activity":[{"end_sample":320,"level":0.\#(digits),"start_sample":0}]}"#.utf8)
        let packed = try XCTUnwrap(SidecarActivityPacking.pack(value, cancelled: { false }))
        var checks = 0
        func cancel() -> Bool {
            checks += 1
            return checks >= 2
        }
        XCTAssertThrowsError(try SidecarActivityPacking.pack(value, cancelled: cancel)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
        checks = 0
        XCTAssertThrowsError(try SidecarActivityPacking.unpack(packed, logicalSize: value.count, cancelled: cancel)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
    }

    func testRegularPacketsAfterExceptionalTimestampsUseRuns() throws {
        // A packet with distinct PTS/DTS, followed by one with zero duration.
        var bytes = Data([2, 0, 1, 2, 1, 2, 1, 0, 0, 2, 1, 0, 1, 0, 1, 0, 0, 2])
        for i in 0..<2000 {
            let timestamp = i * 2
            bytes.append(1)
            if timestamp < 128 {
                bytes.append(UInt8(timestamp))
            } else {
                bytes.append(UInt8(timestamp & 127) | 128)
                bytes.append(UInt8(timestamp >> 7))
            }
            bytes.append(contentsOf: [1, 2, 1, 0, 0, 2])
        }
        let payload = try SidecarPayload.encode(bytes, key: "media_index_audio.v1", cancelled: { false })
        XCTAssertTrue([4, 5].contains(try XCTUnwrap(payload.bytes.first)))
        XCTAssertLessThan(payload.bytes.count, 64)
        XCTAssertEqual(try payload.decode(cancelled: { false }), bytes)
    }
}
