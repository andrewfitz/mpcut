import Darwin
import Foundation
@testable import MPCutCore
@testable import MPCutApp
import XCTest

final class TilesPendingReviewStoreTests: XCTestCase {
    func testPendingMonitorStopsDrawingDepartedTilesAndPausedFootage() throws {
        let media = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let stamp = try SceneSourceStamp(identity: SourceIdentity(media))
        let one = RationalTime(numerator: 1), two = RationalTime(numerator: 2), three = RationalTime(numerator: 3)
        let boxes = [UInt64(1), 2].map { id in
            ParticipantRegion(appearanceID: id, participantID: id, rect: .init(x: Double(id - 1) / 2, y: 0, width: 0.5, height: 1),
                              kind: .video, role: .primary, confidence: 1, identityConfidence: 1, identityUncertain: false, possibleMatches: [])
        }
        let analysis = ParticipantTrackingResult(schemaVersion: 1, start: .zero, end: three, sampling: .sparse,
            observations: [.init(time: .zero, display: .init(rotation: .r0, pixelAspectNum: 1, pixelAspectDen: 1),
                                 confidence: 1, regions: boxes)], tracks: [],
            appearances: [.init(id: 1, participantID: 1, start: .zero, end: one),
                          .init(id: 2, participantID: 2, start: .zero, end: three)],
            events: [], coverage: [], diagnostics: [], resumeAt: two)
        let preview = ParticipantPendingTilePreview(sourceID: media.path, stamp: stamp, analysis: analysis, grids: [])
        XCTAssertEqual(preview.boxes(at: .zero).count, 2)
        XCTAssertEqual(preview.boxes(at: one), [CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])
        XCTAssertTrue(preview.boxes(at: two).isEmpty)
        let source = ParticipantScanSource(file: media.path, stamp: stamp, inode: nil, stream: 0, origin: .zero,
            timeBase: .init(numerator: 1, denominator: 30), duration: three,
            transform: .init(rotation: .r0, pixelAspectNum: 1, pixelAspectDen: 1))
        let scan = ParticipantScanResult(state: .paused, source: source, configuration: .init(.init(sampling: .sparse)),
            analysis: analysis, sceneReport: nil, analysisIdentity: "preview")
        var choices = TilesReviewChoices(scan: scan)
        choices.grids = [.init(range: .init(from: .zero, to: one), columns: 1, rows: 1)]
        XCTAssertEqual(choices.maximumVisibleTiles(in: scan, rawMaximum: 2), 1)
        choices.grids.append(.init(range: .init(from: two, to: three), columns: 2, rows: 2))
        XCTAssertEqual(choices.maximumVisibleTiles(in: scan, rawMaximum: 2), 4)
    }

    func testPendingScanMovesWithProjectAndHistoryBindsItToOnePictureSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("Original")
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = original.appendingPathComponent("Gallery.mp4")
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: movie, to: media)
        let cut = original.appendingPathComponent("Project.cut")
        let scan = try ParticipantAnalysis.scan(media, options: .init(sampling: .everyFrame, useSidecar: false,
                                                                     feedLayout: .fixed(columns: 2, rows: 1)))
        let first = "left", second = "right"
        let group = MulticamProject(referenceAngle: first, range: .init(from: .zero, to: .init(numerator: 1)),
                                    angles: [.init(id: first, file: "Gallery.mp4"), .init(id: second, file: "Gallery.mp4")],
                                    audio: .follow, switches: [.init(at: .zero, angle: first)])
        var project = CutProject.multicam(group)
        var pending = try PendingTileReview(scan: scan, sourceID: second, file: "Gallery.mp4")
        let feed = try XCTUnwrap(TilesReviewCard.list(scan).cards.first?.id)
        pending.choices.names = [feed: "Alex"]
        project.participants.setPendingReview(pending)
        // Every destination must survive: a feed cannot itself be merged away.
        for invalidMerges in [["a": "a"], ["a": "b", "b": "a"], ["a": "b", "b": "c"]] {
            var invalid = project
            var choices = pending
            choices.choices.merged = invalidMerges
            invalid.participants.setPendingReview(choices)
            XCTAssertThrowsError(try invalid.validate())
        }
        let one = RationalTime(numerator: 1)
        for range in [MulticamRange(from: .init(numerator: -1), to: .zero),
                      MulticamRange(from: scan.source.duration, to: try scan.source.duration.adding(one))] {
            var invalid = project
            var choices = pending
            choices.choices.grids = [.init(range: range, columns: 1, rows: 1)]
            invalid.participants.setPendingReview(choices)
            XCTAssertThrowsError(try invalid.validate())
        }
        try project.save(to: cut)
        var expanded = try XCTUnwrap(JSONSerialization.jsonObject(with: CutProject.documentJSON(at: cut)) as? [String: Any])
        var assets = try XCTUnwrap(expanded["embedded_assets"] as? [String: Any])
        let scans = try XCTUnwrap(assets["tile_scans"] as? [String: [String: Any]])
        var encodedScan = try XCTUnwrap(scans[pending.scanSHA256])
        let encodedSource = try XCTUnwrap(encodedScan["source"] as? [String: Any])
        XCTAssertNil(encodedSource["file"])
        XCTAssertNil(encodedSource["inode"])
        XCTAssertEqual(encodedSource["content_sha256"] as? String, scan.source.contentSHA256)
        var participantFields = try XCTUnwrap(expanded["participants"] as? [String: Any])
        var reviews = try XCTUnwrap(participantFields["pending_reviews"] as? [[String: Any]])
        reviews[0]["choices"] = ["names": [feed: "Alex"]]
        participantFields["pending_reviews"] = reviews
        expanded["participants"] = participantFields
        let shorthand = try JSONSerialization.data(withJSONObject: expanded)
        XCTAssertEqual(try CutProject.decode(shorthand).participants.pendingReviews, [pending])
        func branch(_ edit: (inout TilesReviewChoices) -> Void) throws -> Data {
            var branch = project
            var review = pending
            edit(&review.choices)
            branch.participants.setPendingReview(review)
            return try JSONEncoder().encode(branch)
        }
        let ancestor = try branch { _ in }
        let renamed = try branch { $0.names[feed] = "Robin" }
        let hinted = try branch { $0.expectedFeeds = "3" }
        let independent = try ProjectMerge.sides(base: ancestor, ours: renamed, theirs: hinted)
        for side in [independent.ours, independent.theirs] {
            let merged = try CutProject.decode(independent.restoringAssets(in: side))
            let choices = try XCTUnwrap(merged.participants.pendingReviews.first?.choices)
            XCTAssertEqual(choices.names[feed], "Robin")
            XCTAssertEqual(choices.expectedFeeds, "3")
        }
        let competing = try branch { $0.names[feed] = "Sam" }
        let conflict = try ProjectMerge.sides(base: ancestor, ours: renamed, theirs: competing)
        for (side, name) in [(conflict.ours, "Robin"), (conflict.theirs, "Sam")] {
            let merged = try CutProject.decode(conflict.restoringAssets(in: side))
            XCTAssertEqual(merged.participants.pendingReviews.first?.choices.names[feed], name)
        }
        let excludeLeft = try branch { $0.unchecked.insert("left") }
        let excludeRight = try branch { $0.unchecked.insert("right") }
        let exclusions = try ProjectMerge.sides(base: ancestor, ours: excludeLeft, theirs: excludeRight)
        for side in [exclusions.base, exclusions.ours, exclusions.theirs] {
            let merged = try CutProject.decode(exclusions.restoringAssets(in: side))
            XCTAssertEqual(merged.participants.pendingReviews.first?.choices.unchecked, ["left", "right"])
        }
        let mergeLeft = try branch { $0.merged = ["left": "right"] }
        let mergeRight = try branch { $0.merged = ["right": "third"] }
        let overlapping = try ProjectMerge.sides(base: ancestor, ours: mergeLeft, theirs: mergeRight)
        for (side, choices) in [(overlapping.ours, ["left": "right"]), (overlapping.theirs, ["right": "third"])] {
            let merged = try CutProject.decode(overlapping.restoringAssets(in: side))
            XCTAssertEqual(merged.participants.pendingReviews.first?.choices.merged, choices)
        }
        encodedScan["analysis_identity"] = "changed"
        assets["tile_scans"] = [pending.scanSHA256: encodedScan]
        expanded["embedded_assets"] = assets
        XCTAssertThrowsError(try CutProject.decode(JSONSerialization.data(withJSONObject: expanded))) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_embedded_asset")
        }
        expanded.removeValue(forKey: "embedded_assets")
        XCTAssertThrowsError(try CutProject.decode(JSONSerialization.data(withJSONObject: expanded))) {
            XCTAssertEqual(($0 as? CutError)?.code, "missing_embedded_asset")
        }

        // Move just the document and its recording, leaving every other file behind.
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let copy = moved.appendingPathComponent("Copy.cut")
        let copiedMedia = moved.appendingPathComponent("Gallery.mp4")
        try FileManager.default.copyItem(at: cut, to: copy)
        try FileManager.default.copyItem(at: media, to: copiedMedia)
        let reopened = try CutProject.load(from: copy)
        XCTAssertEqual(reopened.participants.pendingReviews, [pending])
        let reviewed = try XCTUnwrap(reopened.participants.pendingReviews.first)
        XCTAssertEqual(try reviewed.load(recording: copiedMedia).source.file, AnalysisSidecar.canonicalSource(copiedMedia).path)
        let preview = try TilesReview(reviewing: reopened, sourceID: second, document: copy, useSidecar: false, cancelled: { false })
        XCTAssertEqual(preview.sourceID, second)
        XCTAssertEqual(preview.counts.feedCount, 2)
        var accepted = reopened
        XCTAssertThrowsError(try accepted.acceptPendingTileReview(sourceID: first, relativeTo: copy))
        try accepted.acceptPendingTileReview(sourceID: second, relativeTo: copy)
        XCTAssertTrue(accepted.participants.pendingReviews.isEmpty)
        XCTAssertEqual(accepted.participants.sources.map(\.sourceID), [second])
        XCTAssertTrue(accepted.participants.people.contains { $0.name == "Alex" })
        var staging = accepted
        staging.participants.setPendingReview(reviewed)
        let pendingRead = try staging.pendingTileReview(nil).report()
        XCTAssertEqual(pendingRead.sourceID, second)
        XCTAssertEqual(pendingRead.choices.value.names[feed], "Alex")
        XCTAssertTrue(pendingRead.feedIDs.contains(feed))
        var stagedChoices = pendingRead.choices.value
        stagedChoices.names[feed] = "Robin"
        stagedChoices.expectedFeeds = "2"
        stagedChoices.expectedTiles = "2"
        stagedChoices.editedHints = true
        let secondFeed = try XCTUnwrap(pendingRead.feedIDs.first { $0 != feed })
        stagedChoices.unchecked.insert(secondFeed)
        stagedChoices.merged = [secondFeed: feed]
        stagedChoices.grids = [.init(range: .init(from: .zero, to: one), columns: 2, rows: 1)]
        let staged = try staging.stagePendingTileChoices(sourceID: second, token: pendingRead.reviewToken, choices: stagedChoices)
        let newReview = try staged.report()
        XCTAssertEqual(newReview.choices.value, stagedChoices)
        XCTAssertEqual(newReview.scanSHA256, pendingRead.scanSHA256)
        XCTAssertEqual(newReview.reviewID, pendingRead.reviewID)
        XCTAssertNotEqual(newReview.reviewToken, pendingRead.reviewToken)
        XCTAssertEqual(staging.participants.people, accepted.participants.people)
        XCTAssertEqual(staging.participants.sources, accepted.participants.sources)
        XCTAssertThrowsError(try staging.discardPendingTileReview(sourceID: second, token: pendingRead.reviewToken)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_tile_review")
        }
        XCTAssertThrowsError(try staging.acceptPendingTileReview(sourceID: second, relativeTo: copy, token: pendingRead.reviewToken)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_tile_review")
        }
        var invalidChoices = stagedChoices
        invalidChoices.names["unknown-feed"] = "Unbound"
        XCTAssertThrowsError(try staging.stagePendingTileChoices(sourceID: second, token: newReview.reviewToken, choices: invalidChoices))
        XCTAssertEqual(staging.participants.pendingReviews, [staged])
        try staging.discardPendingTileReview(sourceID: second, token: newReview.reviewToken)
        XCTAssertEqual(staging, accepted)

        var reconciling = accepted
        reconciling.participants.setPendingReview(reviewed)
        let (replacement, reboundScan) = try reconciling.pendingTileScan(sourceID: second, relativeTo: copy)
        let report = try reconciling.participantReconciliation(reboundScan, sourceID: second, relativeTo: copy)
        let token = try replacement.reconciliationToken(for: report, scan: reboundScan)
        var changed = replacement
        changed.choices.names[feed] = "Robin"
        reconciling.participants.setPendingReview(changed)
        XCTAssertThrowsError(try reconciling.reconcilePendingTileReview(sourceID: second, relativeTo: copy, token: token))
        XCTAssertEqual(reconciling.participants.pendingReviews, [changed])
        let currentToken = try changed.reconciliationToken(for: report, scan: reboundScan)
        try reconciling.reconcilePendingTileReview(sourceID: second, relativeTo: copy, token: currentToken)
        XCTAssertTrue(reconciling.participants.pendingReviews.isEmpty)
        try accepted.save(to: copy, undo: [.init(action: "Accept Tiles", project: reopened)], redo: [])
        let history = try CutProject.loadHistory(from: copy, limit: 10)
        let restored = try XCTUnwrap(history.undo.last?.project)
        XCTAssertEqual(restored.participants.pendingReviews, [pending])
        XCTAssertEqual(try restored.participants.pendingReviews.first?.load(recording: copiedMedia).analysisIdentity,
                       scan.analysisIdentity)
        try restored.save(to: copy, undo: [], redo: [.init(action: "Accept Tiles", project: accepted)])
        XCTAssertEqual(try CutProject.loadHistory(from: copy, limit: 10).redo.last?.project.participants, accepted.participants)
        try accepted.save(to: copy)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
        XCTAssertNil((saved["embedded_assets"] as? [String: Any])?["tile_scans"])
    }
}
