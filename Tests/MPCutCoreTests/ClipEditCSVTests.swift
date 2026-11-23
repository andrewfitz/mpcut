import MPCutCore
import XCTest

final class ClipEditCSVTests: XCTestCase {
    private let scope = AudioSpan(from: RationalTime(numerator: 10), to: RationalTime(numerator: 20))

    func testSplitKeepsBothEndsOfTrimmedClip() throws {
        let ranges = try ClipEditCSV.ranges(in: "\u{feff}time\r\n\"00:02\"\r\n\r\n9/2", clip: scope)
        XCTAssertEqual(ranges.map(\.from.description), ["10", "12", "29/2"])
        XCTAssertEqual(ranges.map(\.to.description), ["12", "29/2", "20"])
    }

    func testRangeOrderRepeatsAndOverlap() throws {
        for header in ["", "from,to\n", "START,END\n"] {
            let ranges = try ClipEditCSV.ranges(in: header + "4,6\n1,5\n4,6", clip: scope)
            XCTAssertEqual(ranges.map(\.from.description), ["14", "11", "14"])
            XCTAssertEqual(ranges.map(\.to.description), ["16", "15", "16"])
        }
    }

    func testInvalidRowsRejectWholeEdit() {
        for input in ["", "time", "0", "10", "4\n3", "3\n3", "1,0", "2,2", "1,11", "1,2\n3", "1,,3", "time\nfoo"] {
            XCTAssertThrowsError(try ClipEditCSV.ranges(in: input, clip: scope), input)
        }
    }

    func testReaderRejectsSpecialFilesOversizeAndInvalidUTF8() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func fails(_ url: URL, with code: String) {
            XCTAssertThrowsError(try ClipEditCSV.ranges(in: url, clip: scope)) { error in
                XCTAssertEqual((error as? CutError)?.code, code)
            }
        }
        fails(directory, with: "csv_read_failed")
        fails(URL(fileURLWithPath: "/dev/null"), with: "csv_read_failed")
        let file = directory.appendingPathComponent("selects.csv")
        fails(file, with: "csv_read_failed")
        try Data("from,to\n1,2\n".utf8).write(to: file)
        for suffix in ["?query=1", "#fragment", "%00suffix"] {
            let rejected = try XCTUnwrap(URL(string: file.absoluteString + suffix))
            fails(rejected, with: "csv_read_failed")
        }
        try Data([0xff, 0xfe, 0x30]).write(to: file)
        fails(file, with: "invalid_csv")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(MulticamProject.maximumFileSize) + 1)
        try handle.close()
        fails(file, with: "invalid_csv")
    }

    func testRejectsRangeAndTimelinePrecisionOverflowAtOffendingLine() {
        let whole = AudioSpan(from: .zero, to: RationalTime(numerator: 1))
        let tiny = AudioSpan(from: .zero, to: RationalTime(numerator: 1, denominator: 4_000_000_000))
        for (text, clip, line) in [("1/4000000001,1/4000000000", whole, 1),
                                   ("0,1/4000000001\n0,1/4000000000", whole, 2),
                                   ("time\n1/4000000001\n\n", tiny, 2)] {
            XCTAssertThrowsError(try ClipEditCSV.ranges(in: text, clip: clip)) { error in
                XCTAssertEqual((error as? CutError)?.code, "invalid_csv")
                XCTAssertTrue(error.localizedDescription.contains("line \(line):"))
            }
        }
    }

    func testCancellationDuringParsingDiscardsPriorRows() {
        var checks = 0
        XCTAssertThrowsError(try ClipEditCSV.ranges(in: "from,to\n2,3\n5,6\n8,9", clip: scope) {
            checks += 1
            return checks == 3
        }) { error in
            XCTAssertEqual((error as? CutError)?.code, "cancelled")
        }
    }

    func testLargeEditFailsAtFirstExcessPiece() {
        let rows = String(repeating: "0,1\n", count: ClipEditCSV.maximumPieces + 1)
        XCTAssertThrowsError(try ClipEditCSV.ranges(in: rows, clip: scope)) { error in
            XCTAssertEqual((error as? CutError)?.code, "invalid_csv")
            XCTAssertTrue(error.localizedDescription.contains("line 100001:"))
        }
    }
}
