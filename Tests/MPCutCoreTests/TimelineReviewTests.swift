import XCTest
@testable import MPCutCore

final class TimelineReviewTests: XCTestCase {
    func testSourceQueryClipsRangesAndKeepsBothOccurrences() throws {
        let project = CutProject.sequence([
            clip("a", "a.mov", 2, 6), clip("b", "b.mov", 1, 3), clip("again", "a.mov", 4, 9)
        ])
        let query = MulticamRange(from: time(9, 2), to: time(7))
        let result = try project.mapTimelineRange(query, clock: .source, file: "a.mov")
        XCTAssertEqual(result.pieces.map(\.id), ["a", "again"])
        XCTAssertEqual(result.pieces.map(\.input), [MulticamRange(from: time(9, 2), to: time(6)), query])
        XCTAssertEqual(result.pieces.map(\.output), [
            MulticamRange(from: time(5, 2), to: time(4)), MulticamRange(from: time(13, 2), to: time(9))
        ])
        let output = try project.mapTimelineRange(range(4, 6), clock: .sequence)
        XCTAssertEqual(output.pieces.map(\.id), ["b"])
        XCTAssertEqual(output.pieces.first?.input, range(1, 3))
        XCTAssertEqual(try project.mapTimelineRange(range(30, 31), clock: .sequence).pieces, [])
        XCTAssertThrowsError(try project.mapTimelineRange(range(4, 4), clock: .source))
        XCTAssertThrowsError(try project.mapTimelineRange(range(4, 5), clock: .group))
    }

    func testMappingMatchesOriginalFileAfterAudioReplacement() throws {
        var replacement = clip("a", "replacement.mov", 2, 6)
        replacement.originalFile = "original.mov"
        let project = CutProject.sequence([replacement])
        let original = try project.mapTimelineRange(range(3, 5), clock: .source, file: "original.mov")
        let playable = try project.mapTimelineRange(range(3, 5), clock: .source, file: "replacement.mov")
        XCTAssertEqual(original, playable)
        XCTAssertEqual(original.pieces.first?.output, range(1, 3))
        XCTAssertEqual(original.pieces.first?.originalFile, "original.mov")
        XCTAssertEqual(original.pieces.first?.file, "replacement.mov")
    }

    func testIndexedQueryValidatesIndexAndComputesTrailingTimeline() throws {
        let first = clip("first", "a.mov", 0, 2)
        let project = CutProject.sequence([first])
        let query = range(0, 1)
        XCTAssertEqual(try project.mapTimelineRange(query, clock: .sequence, file: "b.mov",
                                                    occurrenceIndex: 0).pieces, [])
        for index in [-1, 1] {
            XCTAssertThrowsError(try project.mapTimelineRange(query, clock: .sequence, occurrenceIndex: index)) {
                XCTAssertEqual(($0 as? CutError)?.code, "invalid_target")
            }
        }

        let overflowing = CutProject.sequence([first, clip("last", "b.mov", 0, .max)])
        for index in [0, 2] {
            XCTAssertThrowsError(try overflowing.mapTimelineRange(query, clock: .sequence, occurrenceIndex: index)) {
                XCTAssertEqual(($0 as? CutError)?.code, "time_overflow")
            }
        }
    }

    func testAssemblyQueryIncludesStillAndPreservesRepeatedGroupRanges() throws {
        let program = CutProject.multicam(MulticamProject(
            referenceAngle: "a", range: range(4, 12), angles: [MulticamSource(id: "a", file: "a.mov")],
            audio: .none, switches: [MulticamSwitch(at: time(4), angle: "a")],
            assemblyItems: [.group(range(4, 7)), .still(StillInsert(id: "card", assetID: "asset",
                                                                    duration: time(1), cadence: time(1, 30))),
                            .group(range(4, 7))]
        ))
        let forward = try program.mapTimelineRange(range(6, 7), clock: .group)
        XCTAssertEqual(forward.pieces.map(\.index), [0, 2])
        XCTAssertEqual(forward.pieces.map(\.output), [range(2, 3), range(6, 7)])
        let backward = try program.mapTimelineRange(range(2, 5), clock: .assembly)
        XCTAssertEqual(backward.pieces.map(\.index), [0, 1, 2])
        XCTAssertEqual(backward.pieces.map(\.input), [range(6, 7), nil, range(4, 5)])
        XCTAssertEqual(backward.pieces[1].assetID, "asset")
        XCTAssertEqual(try program.mapTimelineRange(range(6, 7), clock: .group, occurrenceIndex: 2).pieces,
                       [forward.pieces[1]])
    }

    func testRevisionComparisonUsesStableClipIDsAndReportsBothClocks() throws {
        let original = CutProject.sequence([clip("a", "source.mov", 2, 6),
                                            clip("removed", "source.mov", 1, 3),
                                            clip("b", "source.mov", 2, 6)])
        let updated = CutProject.sequence([clip("b", "source.mov", 3, 6),
                                           clip("a", "source.mov", 2, 6),
                                           clip("new", "source.mov", 1, 3)])
        let comparison = try TimelineComparison.compare(from: original, to: updated)
        XCTAssertEqual(comparison.beforeDuration, time(10))
        XCTAssertEqual(comparison.afterDuration, time(9))
        XCTAssertEqual(comparison.changes.map(\.kind), [.modified, .modified, .added, .removed])
        XCTAssertEqual(comparison.changes[0].before?.output, range(6, 10))
        XCTAssertEqual(comparison.changes[0].after?.output, range(0, 3))
        XCTAssertEqual(comparison.changes[0].after?.input, range(3, 6))
        XCTAssertEqual(comparison.changes[0].before?.id, "b")
        XCTAssertEqual(comparison.changes[0].after?.id, "b")
        let page = comparison.page(offset: 0, limit: 1)
        XCTAssertEqual(page.changes.count, 1)
        XCTAssertEqual(page.nextOffset, 1)
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(TimelineComparison.self, from: data), page)
    }

    func testOnlyOccurrencesIntersectingChangedSwitchAreReported() throws {
        var project = MulticamProject(
            referenceAngle: "a", range: range(0, 8),
            angles: [MulticamSource(id: "a", file: "a.mov"), MulticamSource(id: "b", file: "b.mov")],
            audio: .none, switches: [MulticamSwitch(at: time(0), angle: "a"), MulticamSwitch(at: time(6), angle: "a")],
            assembly: [range(0, 2), range(2, 4), range(2, 4), range(6, 8)]
        )
        let old = CutProject.multicam(project)
        project.switches.insert(MulticamSwitch(at: time(3), angle: "b"), at: 1)
        let updated = CutProject.multicam(project)
        let diff = try TimelineComparison.compare(from: old, to: updated)
        XCTAssertEqual(diff.changes.map { $0.after?.index }, [1, 2])
        XCTAssertEqual(diff.changes.map(\.fields), [["switches"], ["switches"]])
    }

    func testComparisonReportsSourceSelectsAndReplayAngleEdits() throws {
        let sequence = CutProject.sequence([clip("clip", "source.mov", 0, 2)])
        let select = try NamedSourceSelect(id: "take", name: "Take",
                                           range: .init(file: "source.mov", from: time(0), to: time(1)))
        let selected = try sequence.settingSourceSelect(select)
        XCTAssertEqual(try TimelineComparison.compare(from: sequence, to: selected).projectFields, ["source_selects"])

        var group = MulticamProject(referenceAngle: "a", range: range(0, 2),
                                    angles: [.init(id: "a", file: "a.mov"), .init(id: "b", file: "b.mov")],
                                    audio: .none, switches: [.init(at: time(0), angle: "a")],
                                    assemblyItems: [.group(range(0, 2))])
        let original = CutProject.multicam(group)
        group.assemblyItems = [.group(range(0, 2), angle: "b")]
        let replay = CutProject.multicam(group)
        let diff = try TimelineComparison.compare(from: original, to: replay)
        XCTAssertEqual(diff.changes.map(\.fields), [["angle_override"]])
        let mapping = try replay.mapTimelineRange(range(1, 2), clock: .assembly)
        XCTAssertEqual(mapping.pieces.first?.angleOverride, "b")
    }

    func testComparisonReportsClipLayoutsAndIgnoresLayoutsOutsideTheTrim() throws {
        let first = clip("first", "a.mov", 1, 4)
        let second = clip("second", "a.mov", 0, 4)
        var updated = first
        updated.tileLayouts = [.init(range: range(0, 1), layout: .original)]
        let before = CutProject.sequence([first, second])
        XCTAssertTrue(try TimelineComparison.compare(from: before, to: .sequence([updated, second])).changes.isEmpty)
        updated.tileLayouts.append(.init(range: range(2, 3), layout: .original))
        let comparison = try TimelineComparison.compare(from: before, to: .sequence([updated, second]))
        XCTAssertEqual(comparison.changes.map { $0.after?.id }, ["first"])
        XCTAssertEqual(comparison.changes.map(\.fields), [["tile_layouts"]])
    }

    func testComparisonMatchesNamedRepeatedOccurrencesAndReportsOverlappingGroupLayouts() throws {
        var project = MulticamProject(
            referenceAngle: "camera", range: range(0, 8), angles: [.init(id: "camera", file: "camera.mov")],
            audio: .none, switches: [.init(at: .zero, angle: "camera")],
            assemblyItems: [.group(range(0, 2)), .group(range(3, 5), id: "first"), .group(range(3, 5), id: "second")]
        )
        let before = CutProject.multicam(project)
        let layout = TileLayoutSpan(range: range(3, 4), layout: .original)
        project.assemblyItems = [.group(range(0, 2), id: "new-id"),
                                 .group(range(3, 5), id: "second", layouts: [layout]),
                                 .group(range(3, 5), id: "first")]
        project.groupTileLayouts = [layout]
        let after = CutProject.multicam(project)
        let comparison = try TimelineComparison.compare(from: before, to: after)
        XCTAssertEqual(comparison.projectFields, ["group_tile_layouts"])
        XCTAssertEqual(comparison.changes.map(\.kind), [.modified, .modified, .modified])
        XCTAssertEqual(comparison.changes.map { $0.before?.index }, [0, 2, 1])
        XCTAssertEqual(comparison.changes[0].fields, ["occurrence_id"])
        XCTAssertTrue(comparison.changes[1].fields.contains("tile_layouts"))
        XCTAssertFalse(comparison.changes[2].fields.contains("tile_layouts"))
        XCTAssertEqual(comparison.changes.filter { $0.fields.contains("group_tile_layouts") }.map { $0.after?.id },
                       ["second", "first"])
        XCTAssertEqual(try after.mapTimelineRange(range(3, 4), clock: .group).pieces.map(\.id), ["second", "first"])
    }

    private func clip(_ id: String, _ path: String, _ from: Int64, _ to: Int64) -> CutSequenceClip {
        CutSequenceClip(id: id, file: path, from: time(from), to: time(to))
    }

    private func time(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private func range(_ from: Int64, _ to: Int64) -> MulticamRange {
        MulticamRange(from: time(from), to: time(to))
    }
}
