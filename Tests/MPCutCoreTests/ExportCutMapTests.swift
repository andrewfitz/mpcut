import Foundation
import XCTest
@testable import MPCutCore

final class ExportCutMapTests: XCTestCase {
    func testRetainsReusedClipAndInternalSeamInCoalescedSegment() throws {
        let file = URL(fileURLWithPath: "/camera.mov")
        let one = RationalTime(numerator: 1)
        let two = RationalTime(numerator: 2)
        let three = RationalTime(numerator: 3)
        let clips = [
            ClipRequest(file: file, from: .zero, to: one),
            ClipRequest(file: file, from: .zero, to: one),
            ClipRequest(file: file, from: one, to: two)
        ]
        let segments = [
            ResolvedSegment(file: file, from: .zero, to: one, outputStart: .zero, tracks: [],
                            reachesEnd: false, sourceClipIndex: 0),
            ResolvedSegment(file: file, from: .zero, to: two, outputStart: one, tracks: [],
                            reachesEnd: false, sourceClipIndex: 1, sourceClipSeams: [one])
        ]
        let edit = ResolvedEdit(segments: segments, duration: three, container: "mov", identities: [:])
        let map = try ExportCutMap(edit: edit, clips: clips, ids: ["first", "reused", "adjacent"])
        XCTAssertEqual(map.occurrences.map(\.occurrenceID), ["first", "reused", "adjacent"])
        XCTAssertEqual(map.occurrences.map(\.segmentNumber), [1, 2, 2])
        XCTAssertEqual(map.occurrences.map(\.input), [.init(from: .zero, to: one), .init(from: .zero, to: one), .init(from: one, to: two)])
        XCTAssertEqual(map.occurrences.map(\.output), [.init(from: .zero, to: one), .init(from: one, to: two), .init(from: two, to: three)])
    }

    func testKeepsStillInsertAndOriginalSourceOccurrenceBoundaries() throws {
        let one = RationalTime(numerator: 1)
        let two = RationalTime(numerator: 2)
        let three = RationalTime(numerator: 3)
        let project = CutProject.stillSequence(.init(items: [
            .source(.init(id: "a", file: "camera.mov", from: .zero, to: one)),
            .still(.init(id: "title", assetID: "card", duration: one, cadence: one)),
            .source(.init(id: "b", file: "camera.mov", from: .zero, to: one))
        ]))
        let map = try ExportCutMap(stills: project, relativeTo: URL(fileURLWithPath: "/project/Edit.cut"))
        XCTAssertEqual(map.occurrences.map(\.occurrenceID), ["a", "title", "b"])
        XCTAssertEqual(map.occurrences.map(\.inputClock), ["source", "generated", "source"])
        XCTAssertEqual(map.occurrences.map(\.inputNumber), [1, 2, 3])
        XCTAssertNil(map.occurrences[1].input)
        XCTAssertEqual(map.occurrences[1].placementID, "title")
        XCTAssertEqual(map.occurrences[2].output, .init(from: two, to: three))
    }

    func testMixedJoinPreservesRepeatedAndReorderedInputNumbers() {
        func range(_ from: Int64, _ to: Int64) -> MulticamRange {
            .init(from: .init(numerator: from), to: .init(numerator: to))
        }
        let intervals: [MulticamInterval] = [
            .init(group: range(4, 5), output: range(0, 1), angle: "a", audio: nil, assemblyIndex: 1),
            .init(group: range(5, 6), output: range(1, 2), angle: "b", audio: nil, assemblyIndex: 1),
            .init(group: range(4, 5), output: range(2, 3), angle: "a", audio: nil, assemblyIndex: 1),
            .init(group: range(5, 6), output: range(3, 4), angle: "b", audio: nil, assemblyIndex: 1),
            .init(group: range(8, 9), output: range(4, 5), angle: "c", audio: nil, assemblyIndex: 0),
            .init(group: range(4, 5), output: range(5, 6), angle: "a", audio: nil, assemblyIndex: 1),
            .init(group: range(5, 6), output: range(6, 7), angle: "b", audio: nil, assemblyIndex: 1)
        ]
        let plan = MulticamPlan(intervals: intervals, picture: [], audio: [], duration: .init(numerator: 7))
        let map = ExportCutMap(multicam: plan, inputNumbersByAssemblyIndex: [0: 1, 1: 2])
        XCTAssertEqual(map.occurrences.map(\.occurrenceNumber), [1, 2, 3, 4])
        XCTAssertEqual(map.occurrences.map(\.inputNumber), [2, 2, 1, 2])
        XCTAssertEqual(map.occurrences.map(\.input), [range(4, 6), range(4, 6), range(8, 9), range(4, 6)])
        XCTAssertEqual(map.occurrences.map(\.output), [range(0, 2), range(2, 4), range(4, 5), range(5, 7)])
    }

    func testMixedJoinDoesNotMapTheOutputGapBetweenGroupIntervals() {
        func range(_ from: Int64, _ to: Int64) -> MulticamRange {
            .init(from: .init(numerator: from), to: .init(numerator: to))
        }
        let intervals: [MulticamInterval] = [
            .init(group: range(4, 5), output: range(0, 1), angle: "a", audio: nil, assemblyIndex: 0),
            .init(group: range(5, 6), output: range(2, 3), angle: "a", audio: nil, assemblyIndex: 0)
        ]
        let plan = MulticamPlan(intervals: intervals, picture: [], audio: [], duration: .init(numerator: 3))
        let map = ExportCutMap(multicam: plan, inputNumbersByAssemblyIndex: [0: 1])
        XCTAssertEqual(map.occurrences.map(\.input), [range(4, 5), range(5, 6)])
        XCTAssertEqual(map.occurrences.map(\.output), [range(0, 1), range(2, 3)])
    }
}
