import XCTest
@testable import MPCutCore

final class TileLayoutsTests: XCTestCase {
    func testSequenceLayoutsSurviveClipsMovingAndSplitAtSourceTime() throws {
        let layouts = [layout(5, 9, kind: .solo)]
        var project = CutProject.sequence([
            .init(id: "gallery", file: "gallery.mov", from: t(3), to: t(10), tileLayouts: layouts),
            .init(id: "next", file: "next.mov", from: .zero, to: t(2))
        ])
        project.participants = metadata
        project = try project.trimmingSequenceClip(id: "gallery", from: t(6), to: t(10))
        XCTAssertEqual(project.sequenceClips?.first?.tileLayouts, layouts)
        project = try project.splittingSequenceClip(id: "gallery", at: t(7), newID: "split")
        XCTAssertEqual(project.sequenceClips?.map(\.tileLayouts), [[layout(5, 7, kind: .solo)], [layout(7, 9, kind: .solo)], []])
        project = try project.duplicatingSequenceClip(id: "split", newID: "copy")
        XCTAssertEqual(project.sequenceClips?.first(where: { $0.id == "copy" })?.tileLayouts, [layout(7, 9, kind: .solo)])
        project = try project.editingStills(sequence: {
            let last = $0.items.removeLast()
            $0.items.insert(last, at: 0)
        }, multicam: { _ in XCTFail("Expected a sequence") })
        let reopened = try CutProject.decode(JSONEncoder().encode(project))
        XCTAssertEqual(reopened, project)
        let shots = try XCTUnwrap(reopened.tileRenderPlan()).shots
        XCTAssertEqual(shots.compactMap(\.range), [r(2, 3), r(3, 5), r(6, 8)])
    }

    func testInspectionShowsMovedLayoutAndUnstyledRecordingInTimelineOrder() throws {
        let authored = layout(3, 6, kind: .solo)
        var project = CutProject.sequence([
            .init(id: "gallery", file: "gallery.mov", from: t(2), to: t(7)),
            .init(id: "plain", file: "plain.mov", from: .zero, to: t(8))
        ])
        project.participants = metadata
        project = try project.settingTileLayout(scope: .clip("gallery"), range: authored.range, layout: authored)
        project = try project.editingStills(sequence: { $0.items.swapAt(0, 1) },
                                            multicam: { _ in XCTFail("Expected a sequence") })

        let document = URL(fileURLWithPath: "/tmp/review.cut")
        let styled = TilesReview(project: project, sourceID: "gallery.mov", document: document)
        let listing = styled.report().layouts
        XCTAssertEqual(listing.map(\.clipID), ["plain", "gallery"])
        XCTAssertEqual(listing.map(\.sourceID), ["plain.mov", "gallery.mov"])
        XCTAssertEqual(listing.map(\.clock), ["source", "source"])
        XCTAssertEqual(listing.map(\.layouts), [[], [authored]])
        XCTAssertEqual(styled.report(at: t(3)).layouts.map(\.layouts), [[authored]])
        XCTAssertEqual(styled.report(at: t(6)).layouts.map(\.layouts), [[]])
        XCTAssertEqual(styled.report(range: r(0, 3)).layouts.map(\.layouts), [[]])

        let unstyled = TilesReview(project: project, sourceID: "plain.mov", document: document)
        XCTAssertEqual(unstyled.report(at: t(3)).layouts.map(\.clipID), ["plain"])
        XCTAssertEqual(unstyled.report(at: t(3)).layouts.map(\.layouts), [[]])
    }

    func testInspectionFiltersMulticamLayoutsUsingRecordingOffsetAndOccurrenceID() throws {
        let group = MulticamProject(referenceAngle: "wide", range: r(0, 15),
                                    angles: [.init(id: "wide", file: "wide.mov"),
                                             .init(id: "gallery", file: "gallery.mov", offset: t(5))],
                                    audio: .none, switches: [.init(at: .zero, angle: "wide")],
                                    assembly: [r(8, 12), r(8, 12)], participants: metadata)
        let original = TileLayoutSpan(range: r(9, 10), layout: .original)
        let project = try CutProject.multicam(group).settingTileLayout(
            scope: .occurrence(try XCTUnwrap(group.tileOccurrenceID(at: 1))), range: original.range, layout: original
        )
        let inspect = TilesReview(project: project, sourceID: "gallery", document: URL(fileURLWithPath: "/tmp/review.cut"))
        let rows = inspect.report(at: t(4)).layouts
        XCTAssertEqual(rows.map(\.clock), ["group", "group", "group"])
        XCTAssertNil(rows.first?.occurrenceID)
        XCTAssertEqual(rows.suffix(2).compactMap(\.occurrenceID).count, 2)
        XCTAssertEqual(rows.last?.occurrenceID, project.tileLayoutListings.last?.occurrenceID)
        XCTAssertEqual(rows.map(\.layouts), [[], [], [original]])
        XCTAssertEqual(inspect.report(at: t(5)).layouts.map(\.layouts), [[], [], []])
    }

    func testReviewShowsUncheckedTailOfPartiallyAnnotatedRecording() {
        var project = CutProject.sequence([.init(id: "clip", file: "call.mov", from: .zero, to: t(12))])
        project.participants = .init(sources: [.init(sourceID: "call.mov", coverage: [.init(range: r(0, 5), state: .verified)])])
        let review = TilesReview(project: project, sourceID: "call.mov", document: URL(fileURLWithPath: "/tmp/review.cut"))
        XCTAssertEqual(review.issues.filter { $0.kind == .uncheckedRange }.compactMap(\.range), [r(5, 12)])
    }

    func testReturningTileEventsMatchOnlyTheirCoalescedHalfOpenSpans() {
        var project = CutProject.sequence([.init(id: "clip", file: "call.mov", from: .zero, to: t(12))])
        let bounds = ParticipantBounds(x: 0, y: 0, width: 1, height: 1)
        var geometry = ParticipantSourceGeometry(sourceID: "call.mov", appearances: [r(7, 9), r(3, 5), r(1, 3)].map {
            .init(id: "tile", participantID: nil, range: $0, bounds: bounds)
        })
        geometry.scanEvents = [0, 1, 3, 5, 6, 7, 9, 10].map {
            .init(time: t($0), kind: .cameraState, uncertain: true, tileID: "tile", feedID: nil, candidates: nil)
        }
        project.participants = .init(sources: [geometry])
        let review = TilesReview(project: project, sourceID: "call.mov", document: URL(fileURLWithPath: "/tmp/review.cut"))
        let returns = review.issues.filter { $0.kind == .ambiguousMatch }
        XCTAssertEqual(returns.compactMap(\.sourceTime), [t(1), t(3), t(7)])
        XCTAssertEqual(returns.compactMap(\.range), [r(1, 5), r(1, 5), r(7, 9)])
    }

    func testReviewUsesNormalizedSourceTimeForDelayedMulticamRecording() {
        func frame(_ index: Int64) -> RationalTime { .init(numerator: index * 1001, denominator: 30_000) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures")
        let document = fixtures.appendingPathComponent("review.cut")
        let layout = TileLayoutSpan(range: .init(from: frame(12), to: frame(14)), layout: .original)
        let group = MulticamProject(referenceAngle: "gallery", range: .init(from: .zero, to: frame(20)),
                                    angles: [.init(id: "gallery", file: "Multicam-Delayed-ProRes.mov", offset: frame(2))],
                                    audio: .none, switches: [.init(at: .zero, angle: "gallery")],
                                    participants: .init(sources: [.init(sourceID: "gallery", coverage: [
                                        .init(range: .init(from: .zero, to: frame(10)), state: .verified)
                                    ])]), groupTileLayouts: [layout])
        let review = TilesReview(project: .multicam(group), sourceID: "gallery", document: document, useSidecar: false)
        XCTAssertEqual(review.report(at: frame(4)).layouts.map(\.layouts), [[layout], []])
        XCTAssertEqual(review.report(at: frame(6)).layouts.map(\.layouts), [[], []])
        XCTAssertEqual(review.issues.filter { $0.kind == .uncheckedRange }.compactMap(\.range),
                       [.init(from: frame(10), to: frame(12))])
    }

    func testLegacyShotMigrationPreservesSourceClocksAndTreatments() throws {
        var legacy = CutProject.sequence([
            .init(id: "repeat-a", file: "gallery.mov", from: t(5), to: t(10)),
            .init(id: "other", file: "other.mov", from: .zero, to: t(2)),
            .init(id: "repeat-b", file: "gallery.mov", from: t(2), to: t(7))
        ])
        legacy.participants = metadata
        legacy.participants.render = .init(shots: [
            .init(layout: .solo, slots: [.init(id: "feed")]),
            .init(range: r(7, 9), layout: .original)
        ], redactions: [.init(participantID: "feed", treatment: .blur)])
        let migrated = try legacy.migratingLegacyTiles()
        XCTAssertEqual(migrated.sequenceClips?.map(\.tileLayouts),
                       [[layout(5, 10, kind: .solo)], [layout(0, 2, kind: .solo)], [layout(4, 7, kind: .solo)]])
        let extended = try migrated.editingStills(sequence: { sequence in
            sequence.items.append(.source(.init(id: "new", file: "new.mov", from: .zero, to: t(2))))
        }, multicam: { _ in XCTFail("Expected a sequence") })
        XCTAssertEqual(extended.sequenceClips?.last?.tileLayouts, [])
        XCTAssertEqual(migrated.participants.people.first?.treatment, .init(mode: .blur))
        let cleared = try migrated.settingFeedTreatment(feedID: "feed", treatment: nil)
        XCTAssertTrue(cleared.participants.effectiveRedactions.isEmpty)
        XCTAssertEqual(try cleared.migratingLegacyTiles(), cleared)
    }

    func testConflictingLegacyCanvasesOpenWithAnOutputDiagnostic() throws {
        let format = StillTimelineFormat(width: 640, height: 360, cadence: .init(numerator: 1, denominator: 30),
                                         codec: .h264, container: "mov")
        var sequence = StillSequenceProject(items: [], stillFormat: format)
        sequence.participants.render = .init(shots: [.init(layout: .original)])
        let document = CutProject.stillSequence(sequence)
        let reopened = try CutProject.decode(JSONEncoder().encode(document))
        XCTAssertNotNil(reopened.legacyTileCanvasConflict)
        XCTAssertThrowsError(try reopened.tileRenderPlan()) {
            XCTAssertEqual(($0 as? CutError)?.code, "conflicting_project_output_format")
        }
        let reconciled = try reopened.settingProjectOutputCanvas(reopened.projectOutputSettings.canvas)
        XCTAssertNil(reconciled.legacyTileCanvasConflict)
        XCTAssertEqual(try reconciled.tileRenderPlan()?.canvas.width, format.width)
    }

    func testMulticamOccurrenceIDAndLayoutMoveTogether() throws {
        let group = MulticamProject(referenceAngle: "gallery", range: r(0, 10),
                                    angles: [.init(id: "gallery", file: "gallery.mov")],
                                    audio: .none, switches: [.init(at: .zero, angle: "gallery")],
                                    assembly: [r(2, 6), r(2, 6)], participants: metadata)
        let program = CutProject.multicam(group)
        let original = TileLayoutSpan(range: r(3, 5), layout: .original)
        let withGroupLayout = try program.settingTileLayout(scope: .group, range: r(0, 10), layout: layout(0, 10, kind: .solo))
        guard case .multicam(var edited) = try withGroupLayout.settingTileLayout(
            scope: .occurrence(try XCTUnwrap(group.tileOccurrenceID(at: 0))), range: original.range, layout: original
        ) else { return XCTFail("Expected a multicam project") }
        let id = try XCTUnwrap(edited.assemblyItems?.first?.occurrenceID)
        edited.assemblyItems?.swapAt(0, 1)
        XCTAssertEqual(edited.tileOccurrenceID(at: 1), id)
        let reopened = try MulticamProject.decode(JSONEncoder().encode(edited))
        XCTAssertEqual(reopened.assemblyItems?.last?.tileLayouts, [original])
        let plan = try XCTUnwrap(CutProject.multicam(reopened).tileRenderPlan())
        let override = try XCTUnwrap(plan.shots.first { $0.occurrence == 1 })
        XCTAssertEqual(override.range, r(5, 7))
        XCTAssertEqual(override.layout, .original)
    }

    func testLegacyOccurrenceAddressDoesNotCollideWithStoredClipID() throws {
        let group = MulticamProject(referenceAngle: "gallery", range: r(0, 10),
                                    angles: [.init(id: "gallery", file: "gallery.mov")],
                                    audio: .none, switches: [.init(at: .zero, angle: "gallery")],
                                    assemblyItems: [.group(r(0, 5)), .group(r(5, 10), id: "assembly-1")])
        let project = CutProject.multicam(group)
        let ids = project.tileLayoutListings.compactMap(\.occurrenceID)
        XCTAssertEqual(Set(ids).count, 2)
        let original = TileLayoutSpan(range: r(0, 5), layout: .original)
        guard case .multicam(let updated) = try project.settingTileLayout(scope: .occurrence(ids[0]),
            range: original.range, layout: original) else { return XCTFail("Expected multicam") }
        XCTAssertEqual(updated.assemblyItems?.compactMap(\.occurrenceID), ids)
        XCTAssertEqual(updated.assemblyItems?.map(\.tileLayouts), [[original], []])
    }

    func testArrangedDestinationCannotBeWrittenTwice() throws {
        var project = CutProject.sequence([.init(id: "gallery", file: "gallery.mov", from: .zero, to: t(10))])
        project.participants = metadata
        let duplicate = TileLayoutSpan(range: r(0, 5), layout: .arranged, slots: [
            .init(id: "feed", destinationTileID: "tile"), .init(target: .empty, id: "tile")
        ])
        XCTAssertThrowsError(try project.settingTileLayout(scope: .clip("gallery"), range: duplicate.range, layout: duplicate))
        let arranged = TileLayoutSpan(range: r(0, 5), layout: .arranged, slots: [.init(target: .empty, id: "tile")])
        let edited = try project.settingTileLayout(scope: .clip("gallery"), range: arranged.range, layout: arranged)
        XCTAssertEqual(edited.sequenceClips?.first?.tileLayouts, [arranged])
    }

    func testArrangedMulticamSplitsAtGalleryChangeAndRejectsDisappearingDestination() throws {
        let bounds = ParticipantBounds(x: 0, y: 0, width: 0.5, height: 0.5)
        let roster = ParticipantProject(people: [.init(id: "feed", name: "Feed")], sources: [
            .init(sourceID: "gallery", appearances: [
                .init(id: "old", participantID: "feed", range: r(0, 2), bounds: bounds, slotID: "one"),
                .init(id: "gone", range: r(0, 2), bounds: bounds, slotID: "two"),
                .init(id: "new", participantID: "feed", range: r(2, 4), bounds: bounds, slotID: "one")
            ])
        ])
        let group = MulticamProject(referenceAngle: "gallery", range: r(0, 10),
                                    angles: [.init(id: "gallery", file: "gallery.mov", offset: t(3))],
                                    audio: .none, switches: [.init(at: .zero, angle: "gallery")], participants: roster)
        let source = CutProject.multicam(group)
        let whole = r(3, 7)
        let missing = TileLayoutSpan(range: whole, layout: .arranged, slots: [.init(target: .empty, id: "gone")])
        XCTAssertThrowsError(try source.settingTileLayout(scope: .group, range: whole, layout: missing)) { error in
            XCTAssertEqual((error as? CutError)?.code, "unmappable_tile_layout")
            XCTAssertTrue((error as? CutError)?.message.contains("at 2.") == true)
        }
        XCTAssertEqual(source.tileLayoutListings.first?.layouts, [])

        let available = TileLayoutSpan(range: whole, layout: .arranged, slots: [.init(id: "feed", destinationTileID: "old")])
        let updated = try source.settingTileLayout(scope: .group, range: whole, layout: available)
        XCTAssertEqual(updated.tileLayoutListings.first?.layouts.map(\.range), [r(3, 5), r(5, 7)])
    }

    private var metadata: ParticipantProject {
        let bounds = ParticipantBounds(x: 0, y: 0, width: 0.5, height: 0.5)
        return .init(people: [.init(id: "feed", name: "Feed")],
                     sources: [.init(sourceID: "gallery.mov", appearances: [
                        .init(id: "tile", participantID: "feed", range: r(0, 10), bounds: bounds,
                              role: .tile, state: .video)
                     ])])
    }

    private func layout(_ from: Int64, _ to: Int64, kind: ParticipantShotLayout) -> TileLayoutSpan {
        .init(range: r(from, to), layout: kind, slots: [.init(id: "feed")])
    }

    private func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
    private func r(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: t(from), to: t(to)) }
}
