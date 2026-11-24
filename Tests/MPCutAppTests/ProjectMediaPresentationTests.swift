import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ProjectMediaPresentationTests: XCTestCase {
    func testOfflineSummaryExcludesIgnoredAndChecking() {
        let result = ProjectMediaAlertSummary([.offline, .ignored, .checking, .indexing, .needsReview, .changed, .online])
        XCTAssertEqual(result.offline, 1)
        XCTAssertEqual(result.review, 2)
        XCTAssertEqual(result.title, "1 file offline")
        XCTAssertNil(ProjectMediaAlertSummary([.checking, .ignored]).title)
    }

    func testFiltersSeparateUnavailableMediaFromReview() {
        XCTAssertTrue(ProjectMediaFilter.offline.includes(.ignored))
        XCTAssertTrue(ProjectMediaFilter.offline.includes(.checking))
        XCTAssertFalse(ProjectMediaFilter.offline.includes(.needsReview))
        XCTAssertTrue(ProjectMediaFilter.review.includes(.changed))
        XCTAssertTrue(ProjectMediaFilter.review.includes(.needsReview))
        XCTAssertFalse(ProjectMediaFilter.review.includes(.offline))
    }

    func testPrefixRootsKeepSharedFolderHierarchy() {
        let old = URL(fileURLWithPath: "/Volumes/Shoot/Day 1/Cameras/A.mov")
        let new = URL(fileURLWithPath: "/Volumes/Shoot 1/Day 1/Cameras/A.mov")
        let (from, to) = projectMediaPrefixRoots(from: old, to: new)
        XCTAssertEqual(from.path, "/Volumes/Shoot")
        XCTAssertEqual(to.path, "/Volumes/Shoot 1")
    }

    func testReplacementTranscriptionTargetsOnlyChangedStreams() {
        let document = URL(fileURLWithPath: "/Edit/Sequence.cut")
        let original = TranscriptBinding(trackID: "voice", file: "old.mov", streamIndex: 1, channel: 1)
        let unrelated = TranscriptBinding(trackID: "room", file: "studio.mov", streamIndex: 4)
        let asset = TranscriptAsset(file: "transcript.json", sha256: String(repeating: "0", count: 64))
        let attachment = TranscriptAttachment(id: "transcript", asset: asset, bindings: [original, unrelated])
        let previous = ProjectTranscripts(attachments: [attachment])
        var changed = original
        changed.file = "replacement.mov"
        changed.streamIndex = 2
        var revised = attachment
        revised.bindings = [changed, unrelated]
        let clip = CutSequenceClip(id: "clip", file: "replacement.mov", from: .zero, to: .init(numerator: 1))
        var project = CutProject.sequence([clip])
        project.transcripts = .init(attachments: [revised])
        let archive = LiveProjectMediaArchive(project: project, undo: [], redo: [], snapshot: .init(),
                                              documentURL: document, checkingVolumes: [])

        XCTAssertEqual(replacementTranscriptTargets(previous: previous, current: archive, affected: ["transcript"]),
                       [.init(file: URL(fileURLWithPath: "/Edit/replacement.mov"), sourceID: nil, stream: 2, channel: 1)])
    }

}
