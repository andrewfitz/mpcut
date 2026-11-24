import Foundation
@testable import MPCutCore
import XCTest

final class ProjectMediaReplaceBindingsTests: XCTestCase {
    func testExistingDestinationGeometryRequiresPrivacyReviewAfterReplacement() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let old = folder.appendingPathComponent("Take A.mp4")
        let candidate = folder.appendingPathComponent("Take B.mp4")
        try FileManager.default.copyItem(at: fixture, to: old)
        try FileManager.default.copyItem(at: fixture, to: candidate)
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        var project = CutProject.sequence([
            .init(id: "target", file: old.lastPathComponent, from: range.from, to: range.to),
            .init(id: "shared", file: old.lastPathComponent, from: range.from, to: range.to),
            .init(id: "existing", file: candidate.lastPathComponent, from: range.from, to: range.to),
        ])
        project.participants = .init(people: [.init(id: "guest", name: "Guest")],
            sources: [old, candidate].map { source in
                .init(sourceID: source.lastPathComponent, coverage: [.init(range: range, state: .verified)])
            },
            render: .init(shots: [.init(layout: .original)], redactions: [.init(participantID: "guest", treatment: .opaque)]))
        let preview = try ProjectMediaReplace.preview(project, relativeTo: document, source: old.path,
                                                      candidate: candidate, options: .init(useID: "target"))
        let replacement = try preview.applying(to: project)
        XCTAssertEqual(preview.report.affectedRedactionIDs, ["guest"])
        XCTAssertEqual(replacement.participants.sources.first { $0.sourceID == old.lastPathComponent }?.coverage,
                       project.participants.sources.first?.coverage)
        let revised = try XCTUnwrap(replacement.participants.sources.first { $0.sourceID == candidate.lastPathComponent })
        XCTAssertEqual(revised.unresolvedParticipantIDs, ["guest"])
        XCTAssertTrue(revised.coverage.isEmpty)
        let render = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try ParticipantRenderer().report(replacement, document: document)
        }
        XCTAssertFalse(render.publishable)
        XCTAssertTrue(render.privacyIssues.contains { $0.sourceID == candidate.lastPathComponent })
    }

    func testSavedReplaceHistoryPreservesLaterChangesToOtherBindingsInSameAttachment() throws {
        let digest = String(repeating: "0", count: 64)
        let asset = TranscriptAsset(file: "edit.transcripts/\(digest).json", sha256: digest, unavailable: .missing)
        let old = TranscriptBinding(trackID: "replaced", file: "old.wav", streamIndex: 0)
        let new = TranscriptBinding(trackID: "replaced", file: "new.wav", streamIndex: 0)
        let other = TranscriptBinding(trackID: "edited-later", file: "unrelated.wav", streamIndex: 0)
        var editedOther = other
        editedOther.streamIndex = 1
        func project(_ first: TranscriptBinding, _ second: TranscriptBinding) -> CutProject {
            var project = CutProject.sequence([.init(id: "clip", file: first.file!, from: .zero, to: .init(numerator: 1))])
            project.transcripts = .init(attachments: [.init(id: "speech", asset: asset, bindings: [first, second])])
            return project
        }
        let original = project(old, other)
        let replacement = project(new, other)
        let current = project(new, editedOther)
        let change = TranscriptBindingChange.changes(from: replacement.transcripts, to: original.transcripts)
        let history = CutHistoryState(action: "Replace Source File", project: original, bindingChanges: change)
        let (data, _) = try current.encodedArchive(undo: [history], redo: [], mediaSnapshot: .empty,
                                                    byteLimit: MulticamProject.maximumFileSize)
        let reopened = try CutProject.decodeEditorDocument(data, limit: 1)
        let previous = try XCTUnwrap(reopened.undo.last)
        XCTAssertEqual(previous.bindingChanges, change)
        XCTAssertEqual(previous.project.transcripts.attachments.first?.bindings, [old, editedOther])
        var undone = previous.project.transcripts
        XCTAssertTrue(TranscriptBindingChange.apply(change.map(\.reversed), to: &undone))
        XCTAssertEqual(undone.attachments.first?.bindings, [new, editedOther])


        let unchanged = CutHistoryState(action: "Rename Clip", project: replacement)
        let (initial, _) = try replacement.encodedArchive(undo: [unchanged], redo: [], mediaSnapshot: .empty,
                                                             byteLimit: MulticamProject.maximumFileSize)
        let retained = try CutProject.decodeEditorDocument(initial, limit: 1).undo
        let (resaved, _) = try current.encodedArchive(undo: retained, redo: [], mediaSnapshot: .empty,
                                                        byteLimit: MulticamProject.maximumFileSize)
        let renamed = try CutProject.decodeEditorDocument(resaved, limit: 1).undo.last
        XCTAssertEqual(renamed?.bindingChanges, [])
        XCTAssertEqual(renamed?.project.transcripts.attachments.first?.bindings, [new, editedOther])
    }
}
