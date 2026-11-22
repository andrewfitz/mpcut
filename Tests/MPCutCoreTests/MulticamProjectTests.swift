import Foundation
import XCTest
import MPCutCore

final class MulticamProjectTests: XCTestCase {
    private func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }

    private func r(_ start: Int64, _ end: Int64) -> MulticamRange {
        .init(from: t(start), to: t(end))
    }

    private var project: MulticamProject {
        .init(referenceAngle: "wide", range: r(0, 40),
              angles: [.init(id: "wide", file: "wide.mov", audioStream: 2),
                       .init(id: "close", file: "close.mov", offset: t(1), audioStream: 4)],
              audioSources: [.init(id: "lav", file: "lav.wav", offset: t(-2))],
              audio: .fixed(.init(source: "lav", stream: 0)),
              switches: [.init(at: .zero, angle: "wide"),
                         .init(at: t(12), angle: "close"),
                         .init(at: t(20), angle: "wide")])
    }

    func testFixedMasterSpansSurviveCutsAndBreakAtAssemblyJumps() throws {
        var edit = project
        edit.assembly = [r(12, 25), r(5, 12), r(12, 25)]
        let plan = try edit.plan()
        XCTAssertEqual(plan.duration, t(33))
        XCTAssertEqual(plan.intervals.map(\.assemblyIndex), [0, 0, 1, 2, 2])
        XCTAssertEqual(plan.intervals.map(\.angle), ["close", "wide", "wide", "close", "wide"])
        XCTAssertEqual(plan.picture.map(\.input), [r(11, 19), r(20, 25), r(5, 12), r(11, 19), r(20, 25)])
        XCTAssertEqual(plan.audio.map(\.source), Array(repeating: "lav", count: 2))
        XCTAssertEqual(plan.audio.map(\.input), [r(14, 27), r(7, 27)])
        XCTAssertEqual(plan.audio.map(\.output), [r(0, 13), r(13, 33)])
        XCTAssertEqual(try edit.plan(ranges: [r(12, 13)]).picture.first?.input, r(11, 12))
        XCTAssertEqual(edit.selection(at: t(12))?.angle, "close")
        XCTAssertNil(edit.selection(at: t(40)))
    }

    func testOverrideResumesFollowAndExplicitPinsSurviveRoundTrip() throws {
        var edit = project
        edit.audio = .follow
        edit.switches[0].audio = .init(source: "wide", stream: 2)
        edit.switches[1].audio = .init(source: "wide", stream: 2)
        edit.switches.insert(.init(at: t(16), angle: "close"), at: 2)
        edit.switches.append(.init(at: t(30), angle: "close"))
        edit.angles[1].audioStream = nil
        let decoded = try JSONDecoder().decode(MulticamProject.self, from: JSONEncoder().encode(edit))
        XCTAssertEqual(decoded, edit)
        let plan = try decoded.plan()
        XCTAssertEqual(plan.intervals.map(\.audio?.stream), [2, 2, nil, 2, nil])
        XCTAssertEqual(plan.picture.map(\.output), [r(0, 12), r(12, 20), r(20, 30), r(30, 40)])
        XCTAssertEqual(plan.audio.map(\.output), [r(0, 16), r(20, 30)])
    }

    func testFractionalSwitchesKeepTheExactSourceAndOutputClocks() throws {
        var edit = project
        let frame = RationalTime(numerator: 1_001, denominator: 30_000)
        edit.range = .init(from: .zero, to: try frame.multiplied(by: t(5)))
        edit.angles[1].offset = try RationalTime(parsing: "0.01")
        edit.switches = [.init(at: .zero, angle: "wide"), .init(at: frame, angle: "close")]
        let plan = try edit.plan()
        XCTAssertEqual(plan.picture[1].input.from, try RationalTime(parsing: "701/30000"))
        XCTAssertEqual(plan.picture[1].output.from, frame)
        XCTAssertEqual(plan.audio.count, 1)
        XCTAssertEqual(try plan.duration.multiplied(by: t(48_000)), t(8_008))
    }

    func testProjectSaveIsAtomicAndKeepsReferenceRangeAndRelativePaths() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("edit.cut")
        var edit = project
        edit.angles.reverse()
        edit.angles[0].name = "Close-up"
        edit.angles[0].file = "media space/close#.mov"
        edit.switches[0].angle = "close"
        edit.assembly = [r(30, 40), r(5, 10)]
        try edit.save(to: url)
        let reopened = try MulticamProject.load(from: url)
        XCTAssertEqual(reopened, edit)
        XCTAssertEqual(reopened.referenceAngle, "wide")
        XCTAssertEqual(reopened.sourceURL(for: reopened.angles[0], relativeTo: url),
                       folder.appendingPathComponent("media space/close#.mov"))
        XCTAssertEqual(try reopened.plan().duration, t(15))
        edit.referenceAngle = "invalid"
        XCTAssertThrowsError(try edit.save(to: url))
        XCTAssertEqual(try MulticamProject.load(from: url), reopened)
    }

    func testInvalidSchemaAndDecisionsAreRejected() throws {
        var edit = project
        let data = try JSONEncoder().encode(edit)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        document["schemaVersion"] = 3
        let future = try JSONSerialization.data(withJSONObject: document)
        XCTAssertThrowsError(try JSONDecoder().decode(MulticamProject.self, from: future)) {
            XCTAssertEqual(($0 as? CutError)?.code, "unsupported_multicam_version")
        }
        edit.switches.insert(.init(at: t(12), angle: "wide"), at: 1)
        XCTAssertThrowsError(try edit.plan())
        edit = project
        edit.switches[2].at = t(40)
        XCTAssertThrowsError(try edit.validate())
        edit = project
        edit.audioSources[0].id = "wide"
        XCTAssertThrowsError(try edit.validate())
        XCTAssertThrowsError(try project.plan(ranges: [r(39, 41)]))
    }

    func testUnknownProjectFieldsReportTheirJSONLocation() throws {
        let data = try JSONEncoder().encode(project)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var angles = try XCTUnwrap(document["angles"] as? [[String: Any]])
        angles[0]["audioSteam"] = 2
        document["angles"] = angles
        let invalid = try JSONSerialization.data(withJSONObject: document)
        XCTAssertThrowsError(try JSONDecoder().decode(MulticamProject.self, from: invalid)) {
            let issue = $0 as? CutError
            XCTAssertEqual(issue?.code, "invalid_multicam_project")
            XCTAssertTrue(issue?.message.contains("audioSteam") == true)
            XCTAssertTrue(issue?.message.contains("angles") == true)
        }
    }

    private func document(_ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        try change(&document)
        return try JSONSerialization.data(withJSONObject: document)
    }

    func testMalformedProjectTimesReportTheirJSONLocation() throws {
        let cases: [(String, (inout [String: Any]) throws -> Void)] = [
            ("switches[1].at", { document in
                var switches = try XCTUnwrap(document["switches"] as? [[String: Any]])
                switches[1]["at"] = "12x"
                document["switches"] = switches
            }),
            ("angles[1].offset", { document in
                var angles = try XCTUnwrap(document["angles"] as? [[String: Any]])
                angles[1]["offset"] = "1/0"
                document["angles"] = angles
            }),
            ("range.to", { $0["range"] = ["from": "0", "to": "9223372036854775808"] }),
            ("assembly[0].from", { $0["assembly"] = [["from": "", "to": "4"]] })
        ]
        for (location, change) in cases {
            XCTAssertThrowsError(try JSONDecoder().decode(MulticamProject.self, from: document(change)), location) {
                let issue = $0 as? CutError
                // A malformed time has one code wherever it is written, so the CLI exits 2 for it.
                XCTAssertEqual(issue?.code, "invalid_time", location)
                XCTAssertTrue(issue?.message.hasSuffix(" in " + location) == true, issue?.message ?? "")
            }
        }
        let unknown = try document { document in
            var angles = try XCTUnwrap(document["angles"] as? [[String: Any]])
            angles[1]["audioSteam"] = 2
            document["angles"] = angles
        }
        XCTAssertThrowsError(try JSONDecoder().decode(MulticamProject.self, from: unknown)) {
            XCTAssertEqual(($0 as? CutError)?.message, "Unknown field ‘audioSteam’ in angles[1]")
        }
    }

    func testStreamIndicesBeyondTheMediaRangeAreRejected() throws {
        let limit = Int(Int32.max)
        var edit = project
        edit.audio = .fixed(.init(source: "lav", stream: limit))
        XCTAssertNoThrow(try edit.validate())
        edit.audio = .fixed(.init(source: "lav", stream: limit + 1))
        XCTAssertThrowsError(try edit.validate())
        edit = project
        edit.angles[0].audioStream = limit + 1
        XCTAssertThrowsError(try edit.validate())
        edit = project
        edit.switches[1].audio = .init(source: "wide", stream: .max)
        XCTAssertThrowsError(try edit.validate()) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_multicam_project")
        }
    }

    func testOversizedProjectFileIsRejectedBeforeReading() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        // A sparse file stands in for a recording passed as the project.
        let recording = folder.appendingPathComponent("recording.mov")
        XCTAssertTrue(manager.createFile(atPath: recording.path, contents: nil))
        let handle = try FileHandle(forWritingTo: recording)
        try handle.truncate(atOffset: UInt64(MulticamProject.maximumFileSize) + 1)
        try handle.close()
        let link = folder.appendingPathComponent("link.cut")
        try manager.createSymbolicLink(at: link, withDestinationURL: recording)
        for url in [recording, link] {
            XCTAssertThrowsError(try MulticamProject.load(from: url)) {
                let issue = $0 as? CutError
                XCTAssertEqual(issue?.code, "invalid_multicam_project")
                XCTAssertTrue(issue?.message.contains("64 MB") == true, issue?.message ?? "")
            }
        }
        XCTAssertThrowsError(try MulticamProject.load(from: folder.appendingPathComponent("absent.cut"))) {
            XCTAssertEqual(($0 as? CutError)?.code, "multicam_project_read_failed")
        }
    }

    func testSavedProjectReloadsIdenticallyWithExactTimes() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let frame = RationalTime(numerator: 1001, denominator: 30000)
        var edit = project
        edit.angles[0].name = "Wide \"A\" / ü"
        edit.angles[1].offset = RationalTime(numerator: -1001, denominator: 30000)
        edit.audioSources[0].offset = RationalTime(numerator: .min + 1)
        edit.audio = .follow
        edit.switches[1] = .init(at: frame, angle: "close", audio: .init(source: "lav", stream: 0))
        edit.assembly = [.init(from: frame, to: t(20)), r(0, 12), .init(from: frame, to: t(20))]
        let url = folder.appendingPathComponent("edit.cut")
        try edit.save(to: url)
        let first = try Data(contentsOf: url)
        let reopened = try MulticamProject.load(from: url)
        XCTAssertEqual(reopened, edit)
        try reopened.save(to: url)
        XCTAssertEqual(try Data(contentsOf: url), first)

        // Typed forms keep their exact value.
        let typed = try document { document in
            document["switches"] = [["at": "0", "angle": "wide"], ["at": "1001/30000", "angle": "close"],
                                    ["at": "0.1", "angle": "wide"], ["at": "00:00:12.5", "angle": "close"]]
        }
        let parsed = try JSONDecoder().decode(MulticamProject.self, from: typed)
        XCTAssertEqual(parsed.switches.map(\.at), [.zero, frame, .init(numerator: 1, denominator: 10),
                                                   .init(numerator: 25, denominator: 2)])
    }

    func testSaveCompactsAtSizeLimitAndPreservesPreviousFileOnOverflow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edit.cut")
        var edit = project
        edit.angles[0].name = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let overhead = try encoder.encode(edit).count
        edit.angles[0].name = String(repeating: "x", count: MulticamProject.maximumFileSize - overhead)
        try edit.save(to: url)
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, MulticamProject.maximumFileSize)
        XCTAssertEqual(try MulticamProject.load(from: url), edit)

        edit.angles[0].name!.append("x")
        XCTAssertThrowsError(try edit.save(to: url)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_multicam_project")
        }
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, MulticamProject.maximumFileSize)
    }

    func testSavingOverSourceOrLinkLeavesMediaIntact() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let source = folder.appendingPathComponent("wide.mov")
        let hardLink = folder.appendingPathComponent("hardlink.cut")
        let symlink = folder.appendingPathComponent("symlink.cut")
        let alias = folder.appendingPathComponent("alias.cut")
        let media = Data("original media".utf8)
        try media.write(to: source)
        try manager.linkItem(at: source, to: hardLink)
        try manager.createSymbolicLink(at: symlink, withDestinationURL: source)
        try URL.writeBookmarkData(source.bookmarkData(options: [.suitableForBookmarkFile]), to: alias)
        let aliasContents = try Data(contentsOf: alias)
        for destination in [source, hardLink, symlink, alias] {
            XCTAssertThrowsError(try project.save(to: destination)) {
                XCTAssertEqual(($0 as? CutError)?.code, "multicam_project_source_collision")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), media)
        XCTAssertEqual(try Data(contentsOf: hardLink), media)
        XCTAssertEqual(try Data(contentsOf: symlink), media)
        XCTAssertEqual(try Data(contentsOf: alias), aliasContents)
    }

    func testUnrepresentableOutputClockReturnsAnError() throws {
        var edit = project
        edit.range = r(0, .max)
        edit.audio = .none
        edit.assembly = [edit.range, edit.range]
        XCTAssertThrowsError(try edit.plan()) {
            XCTAssertEqual(($0 as? CutError)?.code, "time_overflow")
        }
        XCTAssertThrowsError(try JSONEncoder().encode(CutProject.multicam(edit))) {
            XCTAssertEqual(($0 as? CutError)?.code, "time_overflow")
        }
    }
}
