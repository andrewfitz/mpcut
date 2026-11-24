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

    func testNativeLayoutsAndReviewAreScopedWhenReplacingOneUseOfARecording() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let old = folder.appendingPathComponent("original.mp4")
        let candidate = folder.appendingPathComponent("replacement.mp4")
        try FileManager.default.copyItem(at: fixture, to: old)
        try FileManager.default.copyItem(at: fixture, to: candidate)
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let span = TileLayoutSpan(range: range, layout: .solo, slots: [.init(id: "guest")])
        var project = CutProject.sequence(["replace", "keep"].map {
            .init(id: $0, file: old.lastPathComponent, from: range.from, to: range.to, tileLayouts: [span])
        })
        project.participants = .init(people: [.init(id: "guest", name: "Guest", treatment: .init(mode: .blur))],
            sources: [.init(sourceID: old.lastPathComponent, coverage: [.init(range: range, state: .verified)])])
        try project.participants.confirmPrivacy(sourceID: old.lastPathComponent, participantID: "guest", range: range)
        let preview = try ProjectMediaReplace.preview(project, relativeTo: folder.appendingPathComponent("edit.cut"),
            source: old.path, candidate: candidate, options: .init(useID: "replace"))
        let changed = try preview.applying(to: project)
        XCTAssertEqual(changed.sequenceClips?.first { $0.id == "replace" }?.tileLayouts, [])
        XCTAssertEqual(changed.sequenceClips?.first { $0.id == "keep" }?.tileLayouts, [span])
        XCTAssertEqual(preview.report.affectedRedactionIDs, ["guest"])
        XCTAssertNil(changed.participants.sources.first { $0.sourceID == candidate.lastPathComponent }?.confirmations)
        XCTAssertEqual(changed.participants.sources.first { $0.sourceID == old.lastPathComponent }?.confirmations?.count, 1)
    }

    func testReplacingUnscannedRecordingDoesNotAddUnrelatedPrivacyScope() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let old = folder.appendingPathComponent("unrelated.mp4")
        let candidate = folder.appendingPathComponent("new-unrelated.mp4")
        try FileManager.default.copyItem(at: fixture, to: old)
        try FileManager.default.copyItem(at: fixture, to: candidate)
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        var project = CutProject.sequence([
            .init(id: "protected", file: "gallery.mp4", from: range.from, to: range.to),
            .init(id: "replace", file: old.lastPathComponent, from: range.from, to: range.to)
        ])
        project.participants = .init(people: [.init(id: "guest", name: "Guest", treatment: .init(mode: .blur))],
            sources: [.init(sourceID: "gallery.mp4", appearances: [
                .init(id: "tile", participantID: "guest", range: range, bounds: .init(x: 0, y: 0, width: 1, height: 1))
            ])])
        let preview = try ProjectMediaReplace.preview(project, relativeTo: folder.appendingPathComponent("edit.cut"),
            source: old.path, candidate: candidate, options: .init(useID: "replace"))
        let changed = try preview.applying(to: project)
        XCTAssertEqual(changed.sequenceClips?.last?.file, candidate.lastPathComponent)
        XCTAssertEqual(changed.participants, project.participants)
        XCTAssertTrue(preview.report.affectedRedactionIDs.isEmpty)
    }

    func testByteIdenticalDestinationReviewKeepsOriginalPrivacyScope() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let old = folder.appendingPathComponent("original.mp4")
        let candidate = folder.appendingPathComponent("copy.mp4")
        try FileManager.default.copyItem(at: fixture, to: old)
        try FileManager.default.copyItem(at: fixture, to: candidate)
        let digest = try participantSourceDigest(old, identity: SourceIdentity(old))
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        var project = CutProject.sequence([old, candidate].map { media in
            .init(id: media.lastPathComponent, file: media.lastPathComponent, from: range.from, to: range.to)
        })
        let guest = ParticipantPerson(id: "guest", name: "Guest", treatment: .init(mode: .blur))
        let other = ParticipantPerson(id: "other", name: "Other")
        func accepted(_ media: URL, as person: ParticipantPerson) -> ParticipantSourceGeometry {
            .init(sourceID: media.lastPathComponent, analysisIdentity: person.id, sourceContentSHA256: digest, appearances: [
                .init(id: person.id, participantID: person.id, range: range, bounds: .init(x: 0, y: 0, width: 1, height: 1))
            ], coverage: [.init(range: range, state: .verified)])
        }
        project.participants = .init(people: [guest, other], sources: [accepted(old, as: guest), accepted(candidate, as: other)])
        let preview = try ProjectMediaReplace.preview(project, relativeTo: folder.appendingPathComponent("edit.cut"),
                                                      source: old.path, candidate: candidate)
        let changed = try preview.applying(to: project)
        let destination = try XCTUnwrap(changed.participants.sources.first)
        XCTAssertEqual(changed.participants.sources.count, 1)
        XCTAssertEqual(destination.appearances.first?.participantID, other.id)
        XCTAssertEqual(destination.unresolvedParticipantIDs, [guest.id])
        XCTAssertTrue(destination.historicalParticipantIDs?.contains(guest.id) == true)
        XCTAssertEqual(preview.report.affectedRedactionIDs, [guest.id])

        // An older review may have no digest at all. It cannot invalidate the
        // independently verified assignments on the existing destination clip.
        project.participants.sources[0].sourceContentSHA256 = nil
        let olderReview = try ProjectMediaReplace.preview(project, relativeTo: folder.appendingPathComponent("edit.cut"),
                                                          source: old.path, candidate: candidate)
        let retained = try XCTUnwrap(olderReview.applying(to: project).participants.sources.first)
        XCTAssertEqual(retained.appearances, project.participants.sources[1].appearances)
        XCTAssertEqual(retained.coverage, project.participants.sources[1].coverage)
        XCTAssertEqual(retained.unresolvedParticipantIDs, [guest.id])
        XCTAssertFalse(olderReview.report.removedAppearanceIDs.contains(other.id))
    }

    func testReplacementConformsAnOccurrenceUsingTheFeedAnglesPhysicalRecording() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let old = folder.appendingPathComponent("gallery.mp4")
        let candidate = folder.appendingPathComponent("new-gallery.mp4")
        try FileManager.default.copyItem(at: fixture, to: old)
        try FileManager.default.copyItem(at: fixture, to: candidate)
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let offset = RationalTime(numerator: 1, denominator: 2)
        let layout = TileLayoutSpan(range: range, layout: .original)
        let source = MulticamSource(id: "gallery", file: old.lastPathComponent)
        let feed = MulticamSource(id: "angle", file: source.file, feedAngle: .init(sourceID: source.id, feedID: "guest"))
        let project = CutProject.multicam(.init(referenceAngle: source.id, range: range, angles: [source, feed], audio: .none,
            switches: [.init(at: .zero, angle: feed.id)], assemblyItems: [.group(range, id: "occurrence", layouts: [layout])],
            participants: .init(people: [.init(id: "guest", name: "Guest")])))
        let preview = try ProjectMediaReplace.preview(project, relativeTo: folder.appendingPathComponent("edit.cut"),
            source: old.path, candidate: candidate, options: .init(useID: source.id, replacementOffset: offset))
        guard case .multicam(let changed) = try preview.applying(to: project) else { return XCTFail("Expected multicam.") }
        XCTAssertEqual(changed.angles.map(\.offset), [offset, offset])
        XCTAssertEqual(changed.assemblyItems?.first?.group, .init(from: offset, to: range.to))
        XCTAssertEqual(changed.assemblyItems?.first?.occurrenceID, "occurrence")
        XCTAssertEqual(changed.assemblyItems?.first?.tileLayouts, [layout])
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
