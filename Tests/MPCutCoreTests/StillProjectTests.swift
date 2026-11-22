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

    func testRedoOnlyStillUsesV2AndProtectsAssetAcrossHistory() throws {
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
        let bytes = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 2)
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
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(legacy["schemaVersion"] as? Int, 1)
    }

    func testMixedVersionMulticamHistoryRetainsRepeatedRangeIdentityAndRelink() throws {
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
