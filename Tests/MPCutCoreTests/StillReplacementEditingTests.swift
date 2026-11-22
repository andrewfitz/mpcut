import XCTest
import MPCutCore

final class StillReplacementEditingTests: XCTestCase {
    private let asset = StillAsset(id: "photo", file: "offline.png", displayName: "Photo", fingerprint: "offline")
    private func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
    private func range(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: t(from), to: t(to)) }

    private func sequence() throws -> CutProject {
        let clips = [
            CutSequenceClip(id: "first", file: "shared.mov", from: t(2), to: t(12)),
            CutSequenceClip(id: "second", file: "shared.mov", from: t(2), to: t(12))
        ]
        return try CutProject.sequence(clips).addingStillAsset(asset)
            .replacingPicture(id: "replacement", assetID: asset.id, from: t(8), to: t(12))
    }

    func testDetachPreservesSoundAndCoverageAndCanBeEditedIndependently() throws {
        let before = try sequence()
        let detached = try before.editingStillReplacement(id: "replacement", fragmentIndex: 1, detachID: "detached")
        XCTAssertEqual(try before.resolveStills().spans.map(\.origin), try detached.resolveStills().spans.map(\.origin))
        XCTAssertEqual(try before.resolveStills().spans.map(\.output), try detached.resolveStills().spans.map(\.output))
        XCTAssertEqual(detached.stillReplacements[0].coverage, .sequence([.init(clipID: "first", range: range(10, 12))]))
        XCTAssertEqual(detached.stillReplacements[1].coverage, .sequence([.init(clipID: "second", range: range(2, 4))]))
        let moved = try detached.editingStillReplacement(id: "detached", at: t(4), clock: "sequence")
        XCTAssertEqual(moved.stillReplacements[1].coverage, .sequence([.init(clipID: "first", range: range(6, 8))]))
        XCTAssertEqual(moved.stillReplacements[0], detached.stillReplacements[0])
        let originalAgain = try detached.removingStill(id: "detached")
            .removingStill(id: "replacement").addingStillReplacement(before.stillReplacements[0])
        XCTAssertEqual(originalAgain, before)
    }

    func testDetachRoundTripsWithUndoAndRedoStates() throws {
        let before = try sequence()
        let detached = try before.editingStillReplacement(id: "replacement", fragmentIndex: 1, detachID: "detached")
        let changed = try detached.updatingStill(id: "detached", framing: .fill)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edit.cut")
        try detached.save(to: url, undo: [.init(action: "Detach Still Fragment", project: before)],
                          redo: [.init(action: "Change Still Framing", project: changed)])
        let history = try CutProject.loadHistory(from: url, limit: 2)
        XCTAssertEqual(history.undo.first?.project, before)
        XCTAssertEqual(history.redo.first?.project, changed)
    }

    func testMoveAcrossAnInsertReportsItsID() throws {
        let before = try sequence().insertingStill(.init(id: "card", assetID: asset.id, duration: t(2), cadence: t(1)), at: t(4))
        XCTAssertThrowsError(try before.editingStillReplacement(id: "replacement", at: t(3))) {
            let error = $0 as? CutError
            XCTAssertEqual(error?.code, "still_insert_conflict")
            XCTAssertTrue(error?.message.contains("card") == true)
        }
    }

    func testDuplicateUsesIndependentIDAndRejectsHiddenOverlap() throws {
        let before = try sequence()
        let copied = try before.editingStillReplacement(id: "replacement", at: t(2), duplicateID: "copy")
        XCTAssertEqual(copied.stillReplacements[0], before.stillReplacements[0])
        XCTAssertEqual(Set(copied.stillReplacements.map(\.id)), ["replacement", "copy"])
        XCTAssertEqual(copied.stillReplacements[1].assetID, asset.id)
        XCTAssertEqual(try copied.resolveStills().spans.filter { $0.placementID == "copy" }.map(\.output), [range(2, 4), range(4, 6)])

        let hidden = try copied.trimmingSequenceClip(id: "first", from: t(2), to: t(5))
        XCTAssertThrowsError(try hidden.editingStillReplacement(id: "copy", fragmentIndex: 0,
                                                                at: t(10), clock: "source",
                                                                duplicateID: "overlap")) {
            let error = $0 as? CutError
            XCTAssertEqual(error?.code, "still_replacement_overlap")
            XCTAssertTrue(error?.message.contains("replacement") == true)
            XCTAssertTrue(error?.message.contains("overlap") == true)
        }
        let widened = try hidden.trimmingSequenceClip(id: "first", from: t(2), to: t(12))
        XCTAssertEqual(widened, copied)
    }

    func testWholePlacementTrimPreservesTheGapBetweenReorderedFragments() throws {
        let before = try sequence()
        guard case .stillSequence(var project) = before else { return XCTFail("Expected typed sequence") }
        project.items.swapAt(0, 1)
        let reordered = CutProject.stillSequence(project)
        let trimmed = try reordered.editingStillReplacement(id: "replacement", from: t(1), to: t(19))
        XCTAssertEqual(try trimmed.resolveStills().spans.filter { $0.placementID == "replacement" }.map(\.output),
                       [range(1, 2), range(18, 19)])
        XCTAssertThrowsError(try reordered.editingStillReplacement(id: "replacement", from: t(3), to: t(17)))
    }

    func testSourceTrimKeepsHiddenAuthoredBounds() throws {
        let before = try sequence()
        let hidden = try before.trimmingSequenceClip(id: "second", from: t(6), to: t(12))
        let changed = try hidden.editingStillReplacement(id: "replacement", fragmentIndex: 1, to: t(5), clock: "source")
        XCTAssertEqual(try changed.resolveStills().spans.filter { $0.placementID == "replacement" }.map(\.output),
                       [range(8, 10)])
        let widened = try changed.trimmingSequenceClip(id: "second", from: t(2), to: t(12))
        XCTAssertEqual(try widened.resolveStills().spans.filter { $0.placementID == "replacement" }.map(\.output),
                       [range(8, 10), range(10, 13)])
    }

    func testGroupEditsUseAuthoredClockAcrossRepeatedAssemblyOccurrences() throws {
        var group = MulticamProject(referenceAngle: "wide", range: range(0, 30),
                                    angles: [.init(id: "wide", file: "wide.mov")],
                                    audio: .follow, switches: [.init(at: .zero, angle: "wide")])
        group.assemblyItems = [.group(range(8, 14)), .group(range(21, 25)), .group(range(8, 14))]
        let before = try CutProject.multicam(group).addingStillAsset(asset).addingStillReplacement(
            .init(id: "replacement", assetID: asset.id, coverage: .group(range(9, 11))))
        let changed = try before.editingStillReplacement(id: "replacement", from: t(10), to: t(13), clock: "group")
        let copied = try changed.editingStillReplacement(id: "replacement", at: t(21), duplicateID: "copy")
        let plan = try copied.resolveStills()
        XCTAssertEqual(plan.spans.filter { $0.placementID == "replacement" }.map(\.output), [range(2, 5), range(12, 15)])
        XCTAssertEqual(plan.spans.filter { $0.placementID == "copy" }.map(\.output), [range(6, 9)])
        XCTAssertThrowsError(try copied.editingStillReplacement(id: "copy", at: t(-1), clock: "group"))
        XCTAssertThrowsError(try copied.editingStillReplacement(id: "copy", at: t(9), clock: "assembly"))
    }
}
