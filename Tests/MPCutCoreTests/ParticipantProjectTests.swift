import Foundation
@testable import MPCutCore
import XCTest

final class ParticipantProjectTests: XCTestCase {
    private let stage = ParticipantBounds(x: 0, y: 0, width: 0.75, height: 1)
    private let thumbnail = ParticipantBounds(x: 0.75, y: 0, width: 0.25, height: 0.5)

    private func time(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }

    private func range(_ start: Int64, _ end: Int64) -> MulticamRange { .init(from: time(start), to: time(end)) }

    private func accepted(source: String = "gallery.mov") -> ParticipantProject {
        .init(people: [.init(id: "host", name: "Host"), .init(id: "guest", name: "Guest")],
              sources: [.init(sourceID: source, analysisIdentity: "first-scan", appearances: [
                .init(id: "stage", participantID: "host", range: range(0, 5), bounds: stage, role: .stage),
                .init(id: "thumb", participantID: "host", range: range(0, 3), bounds: thumbnail, role: .thumbnail),
                .init(id: "return", participantID: "guest", range: range(7, 10), bounds: stage)
              ], coverage: [.init(range: range(0, 10), state: .verified)])])
    }

    func testScopedAssociationCorrectionAndPinnedDisappearance() throws {
        var project = accepted()
        let source = "gallery.mov"
        XCTAssertEqual(project.resolveAppearance(participantID: "host", sourceID: source, at: time(2), holding: "thumb")?.id,
                       "stage")
        project.appearanceOverrides = [.init(participantID: "host", sourceID: source, appearanceID: "thumb", range: range(1, 5))]
        XCTAssertEqual(project.resolveAppearance(participantID: "host", sourceID: source, at: time(2))?.id, "thumb")
        XCTAssertNil(project.resolveAppearance(participantID: "host", sourceID: source, at: time(3)))
        XCTAssertEqual(project.coverage(sourceID: source, at: time(6)), .verified)
        XCTAssertEqual(project.coverage(sourceID: source, at: time(10)), .unknown)
        try project.linkAppearance(sourceID: source, appearanceID: "return", participantID: "host", range: range(8, 10))
        try project.correctBounds(sourceID: source, appearanceID: "return", bounds: thumbnail, range: range(9, 10))
        try project.splitAppearance(sourceID: source, appearanceID: "thumb", at: time(2), newAppearanceID: "new-thumb")
        XCTAssertEqual(project.resolveAppearance(participantID: "host", sourceID: source, at: time(2))?.id, "new-thumb")
        XCTAssertEqual(project.appearances(sourceID: source, at: time(7)).first?.participantID, "guest")
        XCTAssertEqual(project.resolveAppearance(participantID: "host", sourceID: source, at: time(8))?.bounds, stage)
        XCTAssertEqual(project.resolveAppearance(participantID: "host", sourceID: source, at: time(9))?.bounds, thumbnail)
        try project.markPresentation(sourceID: source, appearanceID: "return", range: range(9, 10))
        XCTAssertNil(project.resolveAppearance(participantID: "host", sourceID: source, at: time(9)))
        XCTAssertEqual(project.appearances(sourceID: source, at: time(9)).first?.role, .presentation)
        try project.validate()
    }

    func testSequenceSaveReopenHistoryAndSaveAs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("gallery.cut")
        let original = CutProject.sequence([
            .init(id: "first", file: "gallery.mov", from: time(0), to: time(10)),
            .init(id: "repeat", file: "gallery.mov", from: time(7), to: time(10))
        ])
        var project = original
        project.participants = accepted()
        project.participants.render = .init(shots: [.init(layout: .solo, slots: [.init(id: "host", anchorX: 0.35)])])
        try project.participants.linkAppearance(sourceID: "gallery.mov", appearanceID: "return", participantID: "host",
                                                range: range(7, 10))
        var prior = original
        prior.participants = accepted()
        let undo: [CutHistoryState] = [
            .init(action: "Accept participants", project: original), .init(action: "Link returning appearance", project: prior)
        ]
        try project.save(to: url, undo: undo, redo: [])
        let reopened = try CutProject.loadDocument(from: url, limit: 2)
        XCTAssertEqual(reopened.project, project)
        XCTAssertEqual(reopened.undo, undo)
        let moved = try reopened.project.rebased(from: url, to: folder.appendingPathComponent("edits/Saved.cut"))
        let source = try XCTUnwrap(moved.sequenceClips?.first?.file)
        XCTAssertEqual(moved.participants.resolveAppearance(participantID: "host", sourceID: source, at: time(9))?.id, "return")
        XCTAssertEqual(moved.sequenceClips?.count, 2)
        XCTAssertFalse(project.participants.needsReconciliation(sourceID: "gallery.mov", analysisIdentity: "first-scan"))
        XCTAssertTrue(project.participants.needsReconciliation(sourceID: "gallery.mov", analysisIdentity: "new-scan"))
    }

    func testMulticamKeepsPhysicalSourceIDThroughRebase() throws {
        let group = MulticamProject(referenceAngle: "camera", range: range(0, 10),
                                    angles: [.init(id: "camera", file: "gallery.mov")],
                                    audio: .none, switches: [.init(at: .zero, angle: "camera")],
                                    participants: accepted(source: "camera"))
        let project = CutProject.multicam(group)
        let decoded = try CutProject.decode(JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project)
        let root = FileManager.default.temporaryDirectory
        let moved = try decoded.rebased(from: root.appendingPathComponent("edit.cut"),
                                       to: root.appendingPathComponent("subfolder/edit.cut"))
        XCTAssertEqual(moved.participants.sources.first?.sourceID, "camera")
    }

    func testFractionalGeometryAndAnchorsReopenWithUndoAndRedo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("geometry.cut")
        let base = CutProject.sequence([.init(id: "source", file: "gallery.mov", from: .zero, to: time(10))])
        func project(x: Double, anchor: Double) -> CutProject {
            var result = base
            var participants = accepted()
            participants.sources[0].appearances[0].bounds.x = x
            participants.sources[0].appearances[0].labelBounds = .init(x: x, y: 0.73, width: 0.155, height: 0.125)
            participants.render = .init(canvas: .init(width: 640, height: 360), shots: [
                .init(layout: .solo, slots: [.init(id: "host", anchorX: anchor, anchorY: 0.625)])
            ])
            result.participants = participants
            return result
        }
        let current = project(x: 0.025, anchor: 0.195)
        let undo = [CutHistoryState(action: "Update bounds", project: project(x: 0.125, anchor: 0.205))]
        let redo = [CutHistoryState(action: "Update framing", project: project(x: 0.035, anchor: 0.215))]
        try current.save(to: url, undo: undo, redo: redo)
        let reopened = try CutProject.loadDocument(from: url, limit: 2)
        XCTAssertEqual(reopened.project, current)
        XCTAssertEqual(reopened.undo, undo)
        XCTAssertEqual(reopened.redo, redo)
    }

    func testOccurrenceShotAppliesOnlyToSelectedRepeat() throws {
        let excerpt = range(2, 4)
        let group = MulticamProject(referenceAngle: "gallery", range: range(0, 10),
                                    angles: [.init(id: "gallery", file: "gallery.mov")], audio: .none,
                                    switches: [.init(at: .zero, angle: "gallery")],
                                    assemblyItems: [.group(excerpt), .group(excerpt)],
                                    participants: accepted(source: "gallery"))
        let project = CutProject.multicam(group)
        let plan = ParticipantRenderPlan(shots: [
            .init(layout: .original),
            .init(range: excerpt, clock: .group, layout: .solo, slots: [.init(id: "host")]),
            .init(range: range(0, 4), occurrence: 1, layout: .pair,
                  slots: [.init(id: "host"), .init(id: "guest")])
        ])
        let timeline = try ParticipantRenderTimeline(project: project,
            document: URL(fileURLWithPath: "/tmp/participants.cut"),
            timeline: project.resolveStills(), plan: plan, checkCancellation: {})
        XCTAssertEqual(timeline.window(at: time(1))?.shot.layout, .solo)
        XCTAssertEqual(timeline.window(at: time(3))?.shot.layout, .pair)
        XCTAssertEqual(timeline.window(at: time(1))?.base?.displacement, time(2))
        XCTAssertEqual(timeline.window(at: time(3))?.base?.displacement, .zero)
    }

    func testAttachmentScopedSpeakerBindingHonorsOverlapAndBoundaries() throws {
        var project = accepted()
        project.people[0].speakers = [.init(attachmentID: "first", speakerID: "a")]
        project.people[1].speakers = [.init(attachmentID: "second", speakerID: "a")]
        func word(attachment: String, start: Int64, end: Int64) -> TranscriptWord {
            .init(id: attachment, text: "Hello", start: time(start), end: time(end), speakerID: "a",
                  projection: .init(clock: .currentCut, wordID: attachment, attachmentID: attachment, originalText: "Hello",
                                    originalSpeakerID: "a", partial: false, staleMatches: false))
        }
        let words = [word(attachment: "first", start: 1, end: 4), word(attachment: "second", start: 2, end: 6)]
        XCTAssertEqual(project.speakingParticipantIDs(at: time(2), in: words), Set(["host", "guest"]))
        XCTAssertEqual(project.speakingParticipantIDs(at: time(4), in: words), Set(["guest"]))
        XCTAssertEqual(project.speakingParticipantIDs(at: time(6), in: words), [])
        try project.validate()
        project.people[1].speakers = project.people[0].speakers
        XCTAssertThrowsError(try project.validate())
    }

    func testAcceptsSparseScanAndDetectsChangedSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("gallery.mov")
        try Data([1, 2, 3]).write(to: media)
        let stamp = try JSONEncoder().encode(SceneSourceStamp(identity: SourceIdentity(media)))
        let stampObject = try JSONSerialization.jsonObject(with: stamp)
        let zero = ["numerator": 0, "denominator": 1]
        let one = ["numerator": 1, "denominator": 1]
        let transform: [String: Any] = ["rotation": "R0", "pixel_aspect_num": 1, "pixel_aspect_den": 1]
        let region: [String: Any] = [
            "appearance_id": 2, "participant_id": 1, "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
            "kind": "video", "role": "primary", "confidence": 1, "possible_matches": []
        ]
        let analysis: [String: Any] = [
            "schema_version": 1, "start": zero, "end": one, "sampling": "sparse",
            "observations": [["timestamp": zero, "display": transform, "confidence": 1, "regions": [region]]],
            "tracks": [["id": 1, "appearance_ids": [2]]],
            "appearances": [["id": 2, "participant_id": 1, "start": zero, "end": one]],
            "events": [], "coverage": [["start": zero, "end": one, "status": "observed"]],
            "diagnostics": [], "resume_at": NSNull()
        ]
        let source: [String: Any] = [
            "file": media.path, "stamp": stampObject, "inode": try SourceIdentity(media).inode,
            "stream": 0, "origin": zero, "time_base": one,
            "duration": one, "transform": transform
        ]
        let result: [String: Any] = [
            "state": "completed", "source": source, "analysis_identity": "fixture",
            "configuration": ["backend": "cpu", "sampling": "sparse", "include_scenes": false], "analysis": analysis
        ]
        let scan = try JSONDecoder().decode(ParticipantScanResult.self, from: JSONSerialization.data(withJSONObject: result))
        let document = directory.appendingPathComponent("gallery.cut")
        var project = CutProject.sequence([.init(id: "source", file: "gallery.mov", from: .zero, to: time(1))])
        try project.acceptParticipantAnalysis(scan, sourceID: "gallery.mov", relativeTo: document)
        XCTAssertEqual(project.participants.people.count, 1)
        XCTAssertEqual(project.participants.appearances(sourceID: "gallery.mov", at: .zero).count, 1)
        XCTAssertEqual(project.participants.coverage(sourceID: "gallery.mov", at: .zero), .inferred)
        XCTAssertFalse(project.participants.needsReconciliation(sourceID: "gallery.mov", mediaURL: media))
        let accepted = project.participants
        try project.acceptParticipantAnalysis(scan, sourceID: "gallery.mov", relativeTo: document)
        XCTAssertEqual(project.participants, accepted)
        let alias = directory.appendingPathComponent("moved.mov")
        try FileManager.default.linkItem(at: media, to: alias)
        XCTAssertFalse(project.participants.needsReconciliation(sourceID: "gallery.mov", mediaURL: alias))
        let replacement = directory.appendingPathComponent("replacement.mov")
        try FileManager.default.copyItem(at: media, to: replacement)
        XCTAssertEqual(SceneSourceStamp(identity: try SourceIdentity(replacement)),
                       SceneSourceStamp(identity: try SourceIdentity(media)))
        XCTAssertTrue(project.participants.needsReconciliation(sourceID: "gallery.mov", mediaURL: replacement))
        try Data([1, 2, 3, 4]).write(to: media)
        XCTAssertTrue(project.participants.needsReconciliation(sourceID: "gallery.mov", mediaURL: media))
        XCTAssertThrowsError(try project.acceptParticipantAnalysis(scan, sourceID: "gallery.mov", relativeTo: document))
        XCTAssertEqual(project.participants, accepted)
    }

}
