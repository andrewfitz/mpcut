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
    }

    func testPendingArtifactAndChoicesMoveWithCut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = directory.appendingPathComponent("Original")
        let moved = directory.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cut = original.appendingPathComponent("Project.cut")
        let media = original.appendingPathComponent("Gallery.mp4")
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                     subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: movie, to: media)
        var project = CutProject.sequence([
            .init(id: "gallery", file: "Gallery.mp4", from: .zero, to: .init(numerator: 1))
        ])
        project.participants = .init(people: [.init(id: "accepted", name: "Accepted Feed")])
        try project.save(to: cut)
        let bytes = try Data(contentsOf: cut)
        let store = TilesPendingReviewStore(project: cut, recordingID: media.path)
        let file = AnalysisSidecar.canonicalSource(media)
        let identity = try SourceIdentity(file)
        let clock = try SceneAnalysis.inspectSceneClock(file, identity: identity, cancelled: { false })
        var source = try ParticipantScanSource(file: file.path, media: clock, video: XCTUnwrap(clock.videoStream))
        source.contentSHA256 = try participantSourceDigest(file, identity: identity)
        let configuration = try JSONDecoder().decode(ParticipantScanConfiguration.self,
            from: Data(#"{"backend":"automatic","sampling":"sparse","include_scenes":false}"#.utf8))
        let scan = ParticipantScanResult(state: .incomplete, source: source, configuration: configuration,
                                         analysis: nil, sceneReport: nil, analysisIdentity: "pending")
        let concurrent = TilesPendingReviewStore(project: original.appendingPathComponent("Concurrent.cut"),
                                                 recordingID: media.path)
        _ = try concurrent.save(scan)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            do {
                if index.isMultiple(of: 3) {
                    _ = try concurrent.save(scan)
                } else {
                    XCTAssertEqual(try concurrent.load()?.0.analysisIdentity, scan.analysisIdentity)
                }
            } catch { XCTFail("Concurrent pending review failed: \(error)") }
        }
        let generations = try FileManager.default.contentsOfDirectory(atPath: concurrent.scanURL.deletingLastPathComponent().path)
            .filter { UUID(uuidString: String($0.dropLast(5))) != nil }
        XCTAssertEqual(generations.count, 1)
        var staleChoices = TilesReviewChoices(scan: scan)
        staleChoices.analysisIdentity += "-stale"
        XCTAssertThrowsError(try concurrent.save(staleChoices))
        let published = try store.save(scan)
        let exported = try JSONDecoder().decode(ParticipantScanResult.self, from: Data(contentsOf: published))
        XCTAssertEqual(exported.analysisIdentity, scan.analysisIdentity)
        var choices = TilesReviewChoices(scan: scan)
        choices.names = ["feed-1": "Pending Name"]
        try store.save(choices)
        XCTAssertEqual(try Data(contentsOf: cut), bytes)
        let savedAs = directory.appendingPathComponent("Copy.cut")
        let copied = TilesPendingReviewStore(project: savedAs, recordingID: media.path)
        XCTAssertNil(try copied.load())
        try copied.save(scan)
        var oldChoices = choices
        oldChoices.names = ["feed-1": "Old Destination"]
        try copied.save(oldChoices)
        XCTAssertThrowsError(try TilesPendingReviewStore.carryReviews(from: cut, to: savedAs, recordingIDs: [media.path]) {
            throw CocoaError(.fileWriteFileExists)
        } as Void)
        XCTAssertEqual(try copied.load(recording: media)?.1.names, oldChoices.names)
        try TilesPendingReviewStore.carryReviews(from: cut, to: savedAs, recordingIDs: [media.path]) {}
        XCTAssertEqual(try copied.load(recording: media)?.1.names, choices.names)

        let draft = directory.appendingPathComponent("Untitled.cut")
        let draftStore = TilesPendingReviewStore(project: draft, recordingID: media.path)
        XCTAssertNil(try draftStore.load())
        try TilesPendingReviewStore.carryReviews(from: cut, to: draft, recordingIDs: [media.path]) {}
        XCTAssertEqual(try draftStore.load(recording: media)?.1.names, choices.names)
        TilesPendingReviewStore.discardDraft(at: draft)
        XCTAssertNil(try draftStore.load())

        try FileManager.default.moveItem(at: original, to: moved)
        let movedCut = moved.appendingPathComponent(cut.lastPathComponent)
        let movedMedia = moved.appendingPathComponent(media.lastPathComponent)
        let reopened = TilesPendingReviewStore(project: movedCut, recordingID: movedMedia.path)
        let rebound = try XCTUnwrap(reopened.load(recording: movedMedia))
        XCTAssertEqual(rebound.0.analysisIdentity, "pending")
        XCTAssertEqual(rebound.0.source.file, AnalysisSidecar.canonicalSource(movedMedia).path)
        XCTAssertEqual(rebound.1.names, choices.names)
        // A replacement may keep both the inode and the exact original mtime.
        // Reload the same path saved by this companion to exercise that case.
        try reopened.save(rebound.0)
        let current = try SourceIdentity(movedMedia)
        let writer = try FileHandle(forUpdating: movedMedia)
        let firstByte = try XCTUnwrap(try writer.read(upToCount: 1)?.first)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: Data([firstByte ^ 0xff]))
        var times = [timespec(tv_sec: current.modifiedSeconds, tv_nsec: current.modifiedNanoseconds),
                     timespec(tv_sec: current.modifiedSeconds, tv_nsec: current.modifiedNanoseconds)]
        XCTAssertEqual(futimens(writer.fileDescriptor, &times), 0)
        try writer.close()
        XCTAssertEqual(current, try SourceIdentity(movedMedia))
        XCTAssertThrowsError(try reopened.load(recording: movedMedia)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_scan")
        }

        try Data("other media".utf8).write(to: movedMedia, options: .atomic)
        XCTAssertThrowsError(try reopened.load(recording: movedMedia)) {
            XCTAssertEqual(($0 as? CutError)?.code, "stale_scan")
        }

        let package = reopened.scanURL.deletingLastPathComponent()
        let generation = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: package.path).first {
            UUID(uuidString: String($0.dropLast(5))) != nil
        })
        let artifact = package.appendingPathComponent(generation)
        try Data("changed".utf8).write(to: artifact)
        XCTAssertThrowsError(try reopened.load()) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_pending_tile_scan")
        }
        XCTAssertThrowsError(try TilesPendingReviewStore.carryReviews(from: movedCut, to: savedAs,
                                                                      recordingIDs: [movedMedia.path]) {
            XCTFail("A corrupt review cannot replace a destination project")
        })
        try FileManager.default.removeItem(at: artifact)
        XCTAssertThrowsError(try reopened.load()) {
            XCTAssertEqual(($0 as? CutError)?.code, "missing_pending_tile_scan")
        }
        XCTAssertEqual(try CutProject.load(from: movedCut).participants.people.first?.id, "accepted")
    }
}
