import Foundation
import XCTest
@testable import MPCutCore

final class StillProjectTests: XCTestCase {
    private let asset = StillAsset(id: "photo", file: "stills/photo.avif", displayName: "Photo", fingerprint: "digest")
    private let clip = CutSequenceClip(id: "interview", file: "interview.mov", from: .zero, to: .init(numerator: 30))
    private let title = StillInsert(id: "title", assetID: "photo", duration: .init(numerator: 2),
                                    cadence: .init(numerator: 1, denominator: 30))

    private func time(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
    private func range(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: time(from), to: time(to)) }

    func testSourceRangeSplicePreservesHiddenStillHandlesAtSurvivingTrimEdges() throws {
        let source = CutSequenceClip(id: "interview", file: "interview.mov", from: time(5), to: time(25))
        let overlay = StillReplacement(id: "overlay", assetID: asset.id,
                                       coverage: .sequence([.init(clipID: source.id, range: range(2, 28))]))
        let project = try CutProject.sequence([source]).addingStillAsset(asset).addingStillReplacement(overlay)
        let timeline = try TranscriptEditTimeline(project)
        let (before, after) = try timeline.retaining(before: time(4), after: time(8))
        let inserted = CutSequenceClip(id: "new", file: "new.mov", from: .zero, to: time(2))
        let result = try timeline.project(project, with: before + [.sequence(inserted)] + after,
                                          preservingHiddenStillHandles: true)
        let clips = try XCTUnwrap(result.sequenceClips)
        XCTAssertEqual(clips.map(\.from), [time(5), .zero, time(13)])
        XCTAssertEqual(clips.map(\.to), [time(9), time(2), time(25)])
        XCTAssertEqual(result.stillReplacements.first?.coverage, .sequence([
            .init(clipID: clips[0].id, range: range(2, 9)),
            .init(clipID: clips[2].id, range: range(13, 28))
        ]))
    }

    func testSourceSpacingRecalculatesExistingGapsAndUsesExactSourceTime() throws {
        let rightStart = RationalTime(numerator: 151, denominator: 10)
        let clips = [
            CutSequenceClip(id: "left", file: clip.file, from: time(10), to: time(12)),
            CutSequenceClip(id: "right", file: clip.file, from: rightStart, to: time(19)),
            CutSequenceClip(id: "touching", file: clip.file, from: time(19), to: time(20))
        ]
        let project = try CutProject.sequence(clips)
            .spacingClips(duration: time(1), cadence: title.cadence, background: "#000000")
        let firstGap = try XCTUnwrap(project.stillInserts.first)
        let result = try project.spacingClipsUsingSourceTiming(cadence: title.cadence, background: "#ff0000")
        XCTAssertEqual(result.sequenceClips, clips)
        XCTAssertEqual(result.stillInserts, [
            StillInsert(id: firstGap.id, assetID: firstGap.assetID, duration: .init(numerator: 31, denominator: 10),
                        cadence: title.cadence, framing: .init(mode: .fit, background: "#ff0000"))
        ])
        XCTAssertEqual(try result.resolveStills().spans.map(\.output), [
            range(0, 2), .init(from: time(2), to: .init(numerator: 51, denominator: 10)),
            .init(from: .init(numerator: 51, denominator: 10), to: time(9)), range(9, 10)
        ])
        XCTAssertEqual(try result.spacingClipsUsingSourceTiming(cadence: title.cadence, background: "#ff0000"), result)
        XCTAssertEqual(try CutProject.decode(JSONEncoder().encode(result)), result)
    }

    func testSourceSpacingResolvesProjectRelativeMediaWithoutRewritingPaths() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let media = folder.appendingPathComponent("Media", isDirectory: true)
        try files.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let source = media.appendingPathComponent("interview.mov")
        try Data().write(to: source)
        try files.createSymbolicLink(atPath: media.appendingPathComponent("shortcut.mov").path,
                                     withDestinationPath: source.lastPathComponent)
        let projectURL = folder.appendingPathComponent("Edit.cut")
        let clips = [
            CutSequenceClip(id: "left", file: "Media/./interview.mov", from: time(10), to: time(12)),
            CutSequenceClip(id: "middle", file: source.path, from: time(15), to: time(19)),
            CutSequenceClip(id: "right", file: "Media/shortcut.mov", from: time(20), to: time(25))
        ]
        let project = try CutProject.sequence(clips)
            .spacingClipsUsingSourceTiming(cadence: title.cadence, background: "#000000", relativeTo: projectURL)
        XCTAssertEqual(project.sequenceClips, clips)
        XCTAssertEqual(project.stillInserts.map(\.duration), [time(3), time(1)])
        try project.save(to: projectURL)
        let reopened = try CutProject.load(from: projectURL)
        XCTAssertEqual(reopened, project)
        XCTAssertEqual(try reopened.spacingClipsUsingSourceTiming(cadence: title.cadence, background: "#000000",
                                                                   relativeTo: projectURL), reopened)
    }

    func testSpacingRetainsFirstInteriorGapIdentityAndRestoresDirectJoin() throws {
        let primary = StillAsset(gapID: "primary")
        let interior = StillAsset(gapID: "interior")
        let unused = StillAsset(gapID: "unused")
        let head = StillInsert(id: "head", assetID: primary.id, duration: time(1), cadence: title.cadence)
        let first = StillInsert(id: "first", assetID: interior.id, duration: time(1), cadence: title.cadence)
        let second = StillInsert(id: "second", assetID: primary.id, duration: time(1), cadence: title.cadence)
        let tail = StillInsert(id: "tail", assetID: primary.id, duration: time(1), cadence: title.cadence)
        let right = CutSequenceClip(id: "right", file: clip.file, from: time(32), to: time(36))
        let project = CutProject.stillSequence(.init(
            items: [.still(head), .source(clip), .still(first), .still(second), .source(right), .still(tail)],
            stillAssets: [primary, interior, unused]
        ))
        let spaced = try project.spacingClips(duration: time(3), cadence: title.cadence, background: "#000000")
        var updated = first
        updated.duration = time(3)
        XCTAssertTrue(spaced.hasInteriorSpacingGaps)
        XCTAssertEqual(spaced.stillInserts, [head, updated, tail])
        let joined = try spaced.spacingClips(duration: .zero, cadence: title.cadence, background: "#000000")
        XCTAssertFalse(joined.hasInteriorSpacingGaps)
        XCTAssertEqual(joined.stillInserts, [head, tail])
        XCTAssertEqual(joined.stillAssets, [primary, unused])
        XCTAssertEqual(joined.sequenceClips, [clip, right])
    }

    func testRemovingTheLastGeneratedGapRestoresAnOrdinarySequence() throws {
        let right = CutSequenceClip(id: "right", file: clip.file, from: time(32), to: time(36))
        let original = CutProject.sequence([clip, right])
        let spaced = try original.spacingClips(duration: time(2), cadence: title.cadence, background: "#000000")
        XCTAssertEqual(try spaced.spacingClips(duration: .zero, cadence: title.cadence, background: "#000000"),
                       original)
        let insert = try XCTUnwrap(spaced.stillInserts.first)
        XCTAssertEqual(try spaced.removingStill(id: insert.id), original)
        let moved = try spaced.movingStill(id: insert.id, to: .zero)
        XCTAssertEqual(moved.stillInserts, [insert])
        XCTAssertEqual(moved.stillAssets, spaced.stillAssets)
        XCTAssertEqual(try moved.resolveStills().spans.first?.placementID, insert.id)
    }

    func testSourceSpacingUsesMulticamGroupTimeAndPreservesExteriorGaps() throws {
        let group = MulticamProject(referenceAngle: "a", range: range(0, 30),
                                    angles: [.init(id: "a", file: "a.mov"), .init(id: "b", file: "b.mov")],
                                    audio: .fixed(.init(source: "a", stream: 1)),
                                    switches: [.init(at: .zero, angle: "a"), .init(at: time(11), angle: "b")],
                                    assembly: [range(8, 10), range(12, 16)])
        let gap = StillAsset(gapID: "gap")
        let head = StillInsert(id: "head", assetID: gap.id, duration: time(1), cadence: title.cadence)
        let tail = StillInsert(id: "tail", assetID: gap.id, duration: time(1), cadence: title.cadence)
        let project = try CutProject.multicam(group).addingStillAsset(gap)
            .insertingStill(head, at: .zero).insertingStill(tail, at: time(7))
        XCTAssertFalse(project.hasInteriorSpacingGaps)
        let result = try project.spacingClipsUsingSourceTiming(cadence: title.cadence, background: "#000000")
        XCTAssertTrue(result.hasInteriorSpacingGaps)
        XCTAssertEqual(result.stillInserts.map(\.duration), [time(1), time(2), time(1)])
        XCTAssertEqual(result.stillInserts.first, head)
        XCTAssertEqual(result.stillInserts.last, tail)
        XCTAssertEqual(try result.resolveStills().spans.filter { $0.placementID == nil }.map(\.output),
                       [range(1, 3), range(5, 9)])
    }

    func testSourceSpacingRejectsJoinsWithoutAnUnambiguousSharedClock() throws {
        let left = CutSequenceClip(id: "left", file: clip.file, from: time(10), to: time(30))
        let sameFileOverlap = CutSequenceClip(id: "overlap", file: clip.file, from: time(29), to: time(31))
        let sameFileReverse = CutSequenceClip(id: "reverse", file: clip.file, from: time(3), to: time(5))
        let otherFile = CutSequenceClip(id: "other", file: "other.mov", from: time(32), to: time(34))
        let photo = try CutProject.sequence([clip]).addingStillAsset(asset).insertingStill(title, at: clip.to)
        for project in [CutProject.sequence([left, sameFileOverlap]), .sequence([left, sameFileReverse]),
                        .sequence([left, otherFile]), photo] {
            XCTAssertThrowsError(try project.spacingClipsUsingSourceTiming(cadence: title.cadence, background: "#000000")) {
                XCTAssertEqual(($0 as? CutError)?.code, "invalid_still_project")
            }
        }
    }

    func testHeadTitleShiftsPictureReplacementAndPreservesUnderlyingCoordinates() throws {
        let project = try CutProject.sequence([clip]).addingStillAsset(asset)
            .replacingPicture(id: "replace", assetID: asset.id, from: time(8), to: time(12))
            .insertingStill(title, at: .zero)
        let plan = try project.resolveStills()
        XCTAssertEqual(plan.duration, time(32))
        XCTAssertEqual(plan.spans.map(\.output), [range(0, 2), range(2, 10), range(10, 14), range(14, 32)])
        XCTAssertEqual(plan.spans.map(\.placementID), ["title", nil, "replace", nil])
        XCTAssertEqual(plan.span(at: time(14))?.origin, .source(clipID: clip.id, range: range(12, 30)))
        XCTAssertNil(plan.span(at: time(32)))
        XCTAssertEqual(try CutProject.decode(JSONEncoder().encode(project)), project)
    }

    func testHiddenReplacementOverlapAndSplitPartition() throws {
        let project = try CutProject.sequence([clip]).addingStillAsset(asset)
            .addingStillReplacement(.init(id: "replace", assetID: asset.id,
                                          coverage: .sequence([.init(clipID: clip.id, range: range(3, 9))])))
        let trimmed = try project.trimmingSequenceClip(id: clip.id, from: time(4), to: time(6))
        let split = try trimmed.splittingSequenceClip(id: clip.id, at: time(5), newID: "right")
        XCTAssertEqual(split.stillReplacements.first?.coverage,
                       .sequence([.init(clipID: clip.id, range: range(3, 5)),
                                  .init(clipID: "right", range: range(5, 9))]))
        let hidden = try split.trimmingSequenceClip(id: "right", from: time(9), to: time(10))
        XCTAssertEqual(try hidden.resolveStills().spans.filter { $0.placementID == "replace" }.map(\.output), [range(0, 1)])
        XCTAssertThrowsError(try hidden.addingStillReplacement(.init(
            id: "overlap", assetID: asset.id, coverage: .sequence([.init(clipID: "right", range: range(8, 10))])
        ))) {
            XCTAssertEqual(($0 as? CutError)?.placementIDs, ["replace", "overlap"])
        }
        let restored = try hidden.trimmingSequenceClip(id: "right", from: time(5), to: time(10))
        XCTAssertEqual(try restored.resolveStills().spans.filter { $0.placementID == "replace" }.map(\.output),
                       [range(0, 1), range(1, 5)])
    }

    func testBatchPauseRemovalPreservesSequenceEditsAndReplacementCoverage() throws {
        let project = try CutProject.sequence([clip]).addingStillAsset(asset)
            .addingStillReplacement(.init(id: "replace", assetID: asset.id,
                                          coverage: .sequence([.init(clipID: clip.id, range: range(1, 29))])))
            .insertingStill(title, at: time(30))
        let edited = try project.removingSequencePauses([
            clip.id: [.init(from: .zero, to: time(2)), .init(from: time(8), to: time(12)),
                      .init(from: time(20), to: time(30))]
        ], checkCancellation: {})
        let pieces = try XCTUnwrap(edited.sequenceClips)
        XCTAssertEqual(pieces.map { MulticamRange(from: $0.from, to: $0.to) }, [range(2, 8), range(12, 20)])
        XCTAssertFalse(pieces.contains { $0.id == clip.id })
        XCTAssertEqual(edited.stillReplacements.first?.coverage, .sequence([
            .init(clipID: pieces[0].id, range: range(2, 12)),
            .init(clipID: pieces[1].id, range: range(12, 29))
        ]))
        XCTAssertEqual(edited.stillInserts, [title])
    }

    func testInsertSplitsVisibleReplacementAndMovesInPreEditTime() throws {
        let project = try CutProject.sequence([clip]).addingStillAsset(asset)
            .replacingPicture(id: "replace", assetID: asset.id, from: time(8), to: time(12))
            .insertingStill(title, at: time(10))
        XCTAssertEqual(try project.resolveStills().spans.filter { $0.placementID == "replace" }.map(\.output),
                       [range(8, 10), range(12, 14)])
        XCTAssertThrowsError(try project.replacingPicture(id: "other", assetID: asset.id, from: time(9), to: time(13))) {
            XCTAssertEqual(($0 as? CutError)?.placementIDs, ["title"])
        }
        XCTAssertEqual(try project.movingStill(id: "title", to: time(11)), project)
        let moved = try project.movingStill(id: "title", to: time(16))
        XCTAssertEqual(try moved.resolveStills().spans.first { $0.placementID == "title" }?.output, range(14, 16))
        XCTAssertEqual(try moved.removingStill(id: "title").resolveStills().duration, time(30))
    }

    func testRepeatedGroupReplacementAndPureAssemblyInsert() throws {
        let group = MulticamProject(referenceAngle: "a", range: range(0, 30),
                                    angles: [.init(id: "a", file: "a.mov"), .init(id: "b", file: "b.mov")],
                                    audio: .fixed(.init(source: "a", stream: 1)),
                                    switches: [.init(at: .zero, angle: "a"), .init(at: time(11), angle: "b")],
                                    assembly: [range(8, 16), range(8, 16)])
        let project = try CutProject.multicam(group).addingStillAsset(asset)
            .addingStillReplacement(.init(id: "replace", assetID: asset.id, coverage: .group(range(8, 12))))
            .insertingStill(title, at: time(8))
        XCTAssertEqual(try project.resolveStills().spans.map(\.placementID), ["replace", nil, "title", "replace", nil])
        guard case .multicam(let edited) = project else { return XCTFail("Expected multicam") }
        let plan = try edited.plan()
        XCTAssertEqual(plan.duration, time(18))
        XCTAssertEqual(plan.audio.map(\.output), [range(0, 8), range(10, 18)])
        XCTAssertEqual(plan.intervals.map(\.assemblyIndex), [0, 0, 2, 2])
        XCTAssertEqual(plan.picture.last?.source, "b")
        XCTAssertEqual(try MulticamProject.decode(JSONEncoder().encode(edited)), edited)
    }

    func testStandaloneFormatAndFramingValidateOffline() throws {
        let format = StillTimelineFormat(width: 1920, height: 1080,
                                         cadence: title.cadence, codec: .h264, container: "mp4")
        let crop = StillImageFraming.Crop(x: .zero, y: .zero, width: .init(numerator: 1, denominator: 2),
                                         height: .init(numerator: 1))
        let framing = StillImageFraming(mode: .fill, crop: crop, background: "#C41a30")
        let project = try CutProject.sequence([]).settingStillFormat(format).addingStillAsset(asset)
            .insertingStill(.init(id: title.id, assetID: title.assetID, duration: title.duration,
                                  cadence: title.cadence, framing: framing), at: .zero)
        let reopened = try CutProject.decode(JSONEncoder().encode(project))
        XCTAssertEqual(reopened, project)
        XCTAssertEqual(reopened.stillInserts.first?.framing, framing)
        XCTAssertThrowsError(try project.resizingStill(id: title.id, duration: .init(numerator: 1, denominator: 31)))
        XCTAssertThrowsError(try project.settingStillFormat(nil))
    }

    func testFittedSoundtrackUsesExactClockAndSurvivesHistoryRoundTrip() throws {
        let format = StillTimelineFormat(width: 1920, height: 1080, cadence: title.cadence,
                                         codec: .h264, container: "mov")
        let original = try CutProject.makeStillTimeline(format: format, asset: asset,
                                                        placementID: title.id, duration: title.duration)
        let end = RationalTime(numerator: 96_001, denominator: 48_000)
        let duration = RationalTime(numerator: 48_001, denominator: 48_000)
        let audio = CutSequenceClip(id: "soundtrack", file: "recordings/source.wav",
                                    from: time(1), to: end, audioTrack: 0)
        let attached = try original.attachingStillSoundtrack(audio)
        let fitted = try attached.fittingStillToSoundtrack()

        let longer = try duration.adding(time(2))
        let resized = try attached.resizingStill(id: title.id, duration: longer)
        XCTAssertEqual(try resized.resolveStills().duration, longer)
        XCTAssertEqual(resized.stillSoundtrack, audio)
        XCTAssertEqual(try CutProject.decode(JSONEncoder().encode(resized)), resized)
        XCTAssertEqual(try resized.resizingStill(id: title.id, duration: time(2)).stillInserts.first?.usesExactDuration, false)

        XCTAssertEqual(try fitted.resolveStills().duration, duration)
        XCTAssertEqual(fitted.stillInserts.first?.usesExactDuration, true)
        let mapping = try XCTUnwrap(fitted.stillSoundtrackMapping(in: range(1, 2)))
        XCTAssertEqual(mapping.output, .init(from: time(1), to: duration))
        XCTAssertEqual(mapping.source, .init(from: time(2), to: end))
        XCTAssertNil(try fitted.stillSoundtrackMapping(in: range(2, 3)))
        XCTAssertEqual(try fitted.attachingStillSoundtrack(nil).resolveStills().duration, duration)
        XCTAssertThrowsError(try CutProject.sequence([clip]).attachingStillSoundtrack(audio))

        let plain = try JSONEncoder().encode(fitted)
        XCTAssertEqual(try CutProject.decode(plain), fitted)
        let refs = ProjectMedia.references(in: fitted)
        XCTAssertEqual(refs.first(where: { $0.kind == .stillSoundtrack })?.path, audio.file)
        XCTAssertEqual(fitted.mapMediaPaths { "/new/" + $0 }.stillSoundtrack?.file, "/new/" + audio.file)

        let redo = [CutHistoryState(action: "Fit Image to Soundtrack", project: fitted)]
        let (bytes, _) = try original.encodedArchive(undo: [], redo: redo, mediaSnapshot: .empty,
                                                     byteLimit: MulticamProject.maximumFileSize)
        let archive = try CutProject.decodeDocument(bytes, limit: 10)
        XCTAssertEqual(archive.project, original)
        XCTAssertEqual(archive.redo, redo)
    }

    func testRedoOnlyStillUsesCurrentSchemaAndProtectsAssetAcrossHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = CutProject.sequence([clip])
        let withStill = try current.addingStillAsset(.init(id: asset.id, file: "photo.avif", displayName: asset.displayName,
                                                          fingerprint: asset.fingerprint))
            .insertingStill(title, at: .zero)
        let url = folder.appendingPathComponent("edit.cut")
        let media = folder.appendingPathComponent("photo.avif")
        let history = [CutHistoryState(action: "Insert Still", project: withStill)]
        try current.save(to: url, undo: [], redo: history)
        let bytes = try ProjectFile.documentJSON(Data(contentsOf: url))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(root["schema_version"] as? Int, 4)
        let reopened = try CutProject.decodeDocument(bytes, limit: 10)
        XCTAssertEqual(reopened.project, current)
        XCTAssertEqual(reopened.redo, history)
        XCTAssertThrowsError(try current.save(to: media, undo: [], redo: history))
        let symlink = folder.appendingPathComponent("alias.avif")
        try Data([1]).write(to: media)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: media)
        XCTAssertThrowsError(try current.save(to: symlink, undo: [], redo: history))
        let savedMedia = try CutProjectMedia.load(from: url)
        XCTAssertThrowsError(try savedMedia.validateDestination(symlink, relativeTo: url))
        try current.save(to: url, undo: [], redo: [])
        let withoutHistory = try XCTUnwrap(JSONSerialization.jsonObject(with: CutProject.documentJSON(saved: Data(contentsOf: url))) as? [String: Any])
        XCTAssertEqual(withoutHistory["schema_version"] as? Int, 4)
    }

    func testMixedMediaMulticamHistoryRetainsRepeatedRangeIdentityAndRelink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = CutProject.multicam(.init(referenceAngle: "a", range: range(0, 20),
                                              angles: [.init(id: "a", file: "a.mov")], audio: .none,
                                              switches: [.init(at: .zero, angle: "a")],
                                              assembly: [range(1, 5), range(1, 5)]))
        let inserted = try base.addingStillAsset(asset).insertingStill(title, at: time(6))
        let relinked = try inserted.relinkingStillAsset(asset.id, file: "moved.avif", fingerprint: "new")
        let history = [
            CutHistoryState(action: "Insert Still", project: base),
            CutHistoryState(action: "Relink Asset", project: inserted)
        ]
        let url = folder.appendingPathComponent("edit.cut")
        try relinked.save(to: url, undo: history, redo: [])
        let reopened = try CutProject.loadDocument(from: url, limit: 10)
        XCTAssertEqual(reopened.project, relinked)
        XCTAssertEqual(reopened.undo, history)
        let subfolder = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        let rebased = try reopened.undo.last?.project.rebased(from: url, to: subfolder.appendingPathComponent("edit.cut"))
        XCTAssertEqual(rebased?.stillAssets.first?.file, "../stills/photo.avif")
    }
}
