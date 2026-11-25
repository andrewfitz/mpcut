import CryptoKit
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

    func testOverwritingPinPreservesBothSidesOfScopedEdit() throws {
        let source = "gallery.mov"
        var project = accepted()
        let guest = ParticipantAppearanceOverride(participantID: "guest", sourceID: source, appearanceID: "return",
                                                  range: range(0, 10))
        project.appearanceOverrides = [
            .init(participantID: "host", sourceID: source, appearanceID: "thumb", range: range(0, 5)), guest
        ]
        project.setAppearanceOverride(.init(participantID: "host", sourceID: source, appearanceID: "stage", range: range(1, 2)))
        try project.validate()
        func selected(at second: Int64) -> String? {
            project.resolveAppearance(participantID: "host", sourceID: source, at: time(second))?.id
        }
        XCTAssertEqual(selected(at: 0), "thumb")
        XCTAssertEqual(selected(at: 1), "stage")
        XCTAssertEqual(selected(at: 2), "thumb")
        XCTAssertNil(selected(at: 3))
        XCTAssertTrue(project.appearanceOverrides.contains(guest))
    }

    func testPartialLinkKeepsDistinctTilesAndOnlyApplicablePreferences() throws {
        var project = accepted()
        let source = "gallery.mov"
        let scanEvent = ParticipantTileScanEvent(time: time(4), kind: .cameraState, uncertain: false, tileID: "stage",
            feedID: "host", candidates: [.init(feedID: "host", confidence: 1, precedingTileID: "stage", precedingTime: time(1))])
        project.sources[0].scanEvents = [scanEvent]
        try project.preferTile(sourceID: source, feedID: "host", tileID: "stage", range: range(0, 5))
        let prior = project
        try project.linkAppearance(sourceID: source, appearanceID: "stage", participantID: "guest", range: range(2, 3))
        let pieces = project.sources[0].appearances.filter { $0.id == "stage" || $0.slotID == "stage" }
        XCTAssertEqual(Set(pieces.map(\.id)).count, 3)
        XCTAssertEqual(pieces.map(\.range), [range(0, 2), range(2, 3), range(3, 5)])
        XCTAssertEqual(pieces.map(\.participantID), ["host", "guest", "host"])
        XCTAssertEqual(project.appearanceOverrides.map(\.appearanceID), [pieces[0].id, pieces[2].id])
        XCTAssertEqual(project.resolveAppearance(participantID: "host", sourceID: source, at: time(2))?.id, "thumb")
        XCTAssertEqual(project.sources[0].scanEvents.first?.tileID, pieces[2].id)
        XCTAssertEqual(project.sources[0].scanEvents.first?.candidates?.first?.precedingTileID, pieces[0].id)
        let geometry = try ParticipantGeometryIndex(project, sourceID: source, slots: [], checkCancellation: {})
        for (second, piece) in zip([Int64(1), 2, 3], pieces) {
            XCTAssertEqual(geometry.destination("stage", in: geometry.at(time(second)).appearances)?.id, piece.id)
        }
        var previous = CutProject.sequence([.init(id: "clip", file: source, from: .zero, to: time(10))])
        previous.participants = prior
        var edited = previous
        edited.participants = project
        let (data, _) = try edited.encodedArchive(undo: [.init(action: "Link Tile", project: previous)], redo: [],
                                                  mediaSnapshot: .empty)
        let restored = try CutProject.decodeEditorDocument(data, limit: 1)
        XCTAssertEqual(restored.project, edited)
        XCTAssertEqual(restored.undo.first?.project, previous)
    }

    func testFeedSplitMovesPreferenceAndRetainsTreatmentHistory() throws {
        var project = accepted()
        let source = "gallery.mov"
        project.people[0].treatment = .init(mode: .cover)
        try project.preferTile(sourceID: source, feedID: "host", tileID: "stage", range: range(0, 5))
        try project.confirmPrivacy(sourceID: source, participantID: "host", range: range(0, 5))
        try project.splitFeed("host", sourceID: source, tileID: "stage", range: range(1, 3), newFeedID: "split", name: "Split")
        XCTAssertEqual(project.resolveAppearance(participantID: "split", sourceID: source, at: time(1))?.id, "stage")
        XCTAssertEqual(project.appearanceOverrides.first { $0.participantID == "split" }?.range, range(1, 3))
        XCTAssertEqual(project.appearanceOverrides.filter { $0.participantID == "host" }.map(\.range), [range(0, 1), range(3, 5)])
        XCTAssertTrue(project.sources[0].historicalParticipantIDs?.contains("split") == true)
        XCTAssertNil(project.sources[0].confirmations)
        XCTAssertEqual(project.people.first { $0.id == "split" }?.treatment, .init(mode: .cover))
    }

    func testFeedMergeRewritesNativeSoundtrackAndKeepsUnrelatedLaneID() throws {
        var model = accepted()
        let source = "gallery.mov"
        let binding = ParticipantAudioBinding(selection: .init(source: source, stream: 1))
        model.people[1].audio = binding
        model.people[1].treatment = .init(mode: .cover, color: 0x111111)
        model.people[0].treatment = .init(mode: .cover, color: 0x222222)
        model.render = .init(shots: [.init(layout: .solo, slots: [.init(id: "guest")])],
                             audio: .init(mode: .lanes, ids: ["guest"]))
        model.tileOutput = .init(audio: .init(mode: .iso, ids: ["guest"]))
        let span = TileLayoutSpan(range: range(0, 5), layout: .solo, slots: [.init(id: "guest")])
        var project = CutProject.sequence([.init(id: "clip", file: source, from: .zero, to: time(10), tileLayouts: [span])])
        project.participants = model
        XCTAssertEqual(try project.mergeTileFeeds("guest", into: "host"), [])
        XCTAssertEqual(project.participants.tileOutput?.audio.ids, ["host"])
        XCTAssertEqual(project.participants.render?.audio.ids, ["guest"])
        XCTAssertEqual(project.participants.people.first?.audio, binding)
        XCTAssertEqual(project.participants.people.first?.treatment?.color, 0x222222)
        XCTAssertEqual(project.sequenceClips?.first?.tileLayouts.first?.slots.first?.id, "host")
        XCTAssertEqual(project.participants.sources[0].appearances.last?.participantID, "host")
    }

    func testMergingNativeRemoveWithMigratedOriginalKeepsLegacyTreatmentProvenance() throws {
        var project = CutProject.sequence([.init(id: "clip", file: "gallery.mov", from: .zero, to: time(5))])
        project.participants = accepted()
        project.participants.render = .init(shots: [.init(layout: .original)],
                                            redactions: [.init(participantID: "guest", treatment: .blur)])
        project = try project.settingFeedTreatment(feedID: "guest", treatment: .init(mode: .remove))
        _ = try project.mergeTileFeeds("guest", into: "host")
        XCTAssertEqual(project.participants.effectiveRedactions.map(\.treatment), [.omit])
        XCTAssertEqual(project.participants.render?.redactions, [.init(participantID: "host", treatment: .blur)])
        XCTAssertNoThrow(try project.validate())
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
        XCTAssertEqual(reopened.project, try project.migratingLegacyTiles())
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
        XCTAssertEqual(reopened.project, try current.migratingLegacyTiles())
        XCTAssertEqual(reopened.undo.map(\.project), try undo.map { try $0.project.migratingLegacyTiles() })
        XCTAssertEqual(reopened.redo.map(\.project), try redo.map { try $0.project.migratingLegacyTiles() })
        let bytes = try JSONEncoder().encode(current)
        let json = String(decoding: bytes, as: UTF8.self)
        let invalid = json.replacingOccurrences(of: "\"width\":640", with: "\"width\":640.00000000000001")
        XCTAssertNotEqual(invalid, json)
        XCTAssertThrowsError(try CutProject.decode(Data(invalid.utf8)))
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

    func testISOUsingAReplacementRetainsItsSyncAndFillsGapsWithSilence() throws {
        let camera = MulticamAudioSelection(source: "gallery", stream: 1)
        let external = MulticamAudioSelection(source: "recorder", stream: 0)
        var project = MulticamProject(referenceAngle: "gallery", range: range(0, 10),
                                      angles: [.init(id: "gallery", file: "gallery.mov", audioStream: 1)],
                                      audioSources: [.init(id: "recorder", file: "recorder.wav")],
                                      audio: .follow, switches: [.init(at: .zero, angle: "gallery")],
                                      audioReplacements: [.init(id: "sync", original: camera, replacement: external,
                                                                 relativeOffset: time(2), uncovered: .keepOriginal)])
        try project.validate()
        try ParticipantRenderSound.apply(.init(selection: external), to: &project)
        try project.validate()
        XCTAssertEqual(project.audio, .fixed(camera))
        XCTAssertEqual(project.audioReplacements.first?.relativeOffset, time(2))
        XCTAssertEqual(project.audioReplacements.first?.uncovered, .leaveUncovered)
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
        let scan = try fixtureScan(media, analysisIdentity: "initial")
        let document = directory.appendingPathComponent("gallery.cut")
        var project = CutProject.sequence([.init(id: "source", file: "gallery.mov", from: .zero, to: time(1))])
        XCTAssertThrowsError(try project.acceptParticipantAnalysis(scan, sourceID: "gallery.mov", relativeTo: document,
                                                                    cancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(project.participants.isEmpty)
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

    func testEmbeddedTileScanIntegerFieldsCannotRoundToMatchDigest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("gallery.mov")
        try Data([1, 2, 3]).write(to: media)
        let scan = try fixtureScan(media, analysisIdentity: "initial", verification: true)
        var project = CutProject.sequence([.init(id: "source", file: "gallery.mov", from: .zero, to: time(1))])
        let pending = try PendingTileReview(scan: scan, sourceID: "gallery.mov", file: "gallery.mov")
        project.participants.setPendingReview(pending)
        let url = directory.appendingPathComponent("gallery.cut")
        try project.save(to: url)
        let valid = String(decoding: try CutProject.documentJSON(at: url), as: UTF8.self)
        let malformed = valid.replacingOccurrences(of: #""pixel_aspect_num":1"#,
                                                   with: #""pixel_aspect_num":1.00000000000000000001"#)
        XCTAssertNotEqual(malformed, valid)
        XCTAssertThrowsError(try CutProject.decode(Data(malformed.utf8))) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_project")
            XCTAssertTrue(($0 as? CutError)?.message.contains("non-integer JSON number") == true)
        }
        XCTAssertEqual(try CutProject.decode(Data(valid.utf8)).participants.pendingReviews, [pending])
    }

    func testReconcileCopyRetainsReviewWhileChangedMediaRequiresNewIdentityReview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("edit.cut")
        let media = directory.appendingPathComponent("original.mov")
        let copy = directory.appendingPathComponent("copied.mov")
        let edited = directory.appendingPathComponent("changed.mov")
        try Data([1, 2, 3]).write(to: media)
        try FileManager.default.copyItem(at: media, to: copy)
        try Data([4, 5, 6]).write(to: edited)
        let projectRange = range(0, 1)
        let original = try fixtureScan(media, analysisIdentity: "original-analysis")
        let copied = try fixtureScan(copy, analysisIdentity: "copy-analysis")
        let changed = try fixtureScan(edited, analysisIdentity: "changed-analysis")
        XCTAssertNotEqual(original.source.inode, copied.source.inode)
        XCTAssertEqual(original.source.contentSHA256, copied.source.contentSHA256)
        XCTAssertNotEqual(original.source.contentSHA256, changed.source.contentSHA256)
        var group = MulticamProject(referenceAngle: "gallery", range: projectRange,
            angles: [.init(id: "gallery", file: media.path)], audio: .none,
            switches: [.init(at: .zero, angle: "gallery")])
        var project = CutProject.multicam(group)
        try project.acceptParticipantAnalysis(original, sourceID: "gallery", relativeTo: document)
        let participant = try XCTUnwrap(project.participants.people.first?.id)
        let appearance = try XCTUnwrap(project.participants.sources.first?.appearances.first?.id)
        try project.participants.correctBounds(sourceID: "gallery", appearanceID: appearance, bounds: stage, range: projectRange)
        project.participants.people[0].speakers = [.init(attachmentID: "meeting", speakerID: "host")]
        project.participants.appearanceOverrides = [.init(participantID: participant, sourceID: "gallery",
                                                          appearanceID: appearance, range: projectRange)]
        project.participants.render = .init(shots: [.init(layout: .original)],
                                            redactions: [.init(participantID: participant, treatment: .opaque)])
        let reviewed = project.participants
        group.participants = reviewed
        group.angles[0].file = copy.path
        project = .multicam(group)
        let copyReview = try reviewed.reconciliation(for: copied, sourceID: "gallery")
        XCTAssertTrue(copyReview.retainedCopiedGeometry)
        XCTAssertFalse(copyReview.sourceChanged)
        try project.reconcileParticipantAnalysis(copied, sourceID: "gallery", relativeTo: document, reviewed: copyReview)
        XCTAssertEqual(project.participants.people, reviewed.people)
        XCTAssertEqual(project.participants.render, reviewed.render)
        XCTAssertEqual(project.participants.appearanceOverrides, reviewed.appearanceOverrides)
        XCTAssertEqual(project.participants.sources[0].appearances, reviewed.sources[0].appearances)
        XCTAssertEqual(project.participants.sources[0].sourceInode, copied.source.inode)
        XCTAssertFalse(project.participants.needsReconciliation(sourceID: "gallery", mediaURL: copy))

        group.participants = project.participants
        group.angles[0].file = edited.path
        project = .multicam(group)
        let replacement = try project.participants.reconciliation(for: changed, sourceID: "gallery")
        XCTAssertTrue(replacement.sourceChanged)
        XCTAssertEqual(replacement.affectedParticipantIDs, [participant])
        XCTAssertEqual(replacement.affectedRedactionIDs, [participant])
        XCTAssertEqual(replacement.affectedBindingIDs, [participant])
        XCTAssertEqual(replacement.removedAppearanceIDs, [appearance])
        XCTAssertEqual(replacement.removedOverrideCount, 1)
        var concurrent = project
        try concurrent.participants.correctBounds(sourceID: "gallery", appearanceID: appearance,
                                                  bounds: thumbnail, range: projectRange)
        XCTAssertThrowsError(try concurrent.reconcileParticipantAnalysis(changed, sourceID: "gallery",
                                                                         relativeTo: document, reviewed: replacement))
        let beforeReplacement = project
        try project.reconcileParticipantAnalysis(changed, sourceID: "gallery", relativeTo: document, reviewed: replacement)
        XCTAssertEqual(project.participants.sources[0].unresolvedParticipantIDs, [participant])
        XCTAssertNil(project.participants.appearances(sourceID: "gallery", at: .zero).first { $0.participantID == participant })
        XCTAssertEqual(project.participants.render, reviewed.render)
        XCTAssertEqual(project.participants.people.first, reviewed.people.first)
        XCTAssertTrue(project.participants.appearanceOverrides.isEmpty)
        try project.save(to: document, undo: [.init(action: "Adopt replacement scan", project: beforeReplacement)], redo: [])
        let reopened = try CutProject.loadDocument(from: document, limit: 1)
        XCTAssertEqual(reopened.project.participants.sources[0].unresolvedParticipantIDs, [participant])
        XCTAssertEqual(reopened.undo.first?.project, try beforeReplacement.migratingLegacyTiles())
        try project.participants.confirmReconciledParticipant(sourceID: "gallery", participantID: participant)
        XCTAssertTrue(project.participants.sources[0].unresolvedParticipantIDs.isEmpty)
    }

    func testReconciliationTokenMatchesPreviousSortedJSONPayload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let scan = try fixtureScan(file, analysisIdentity: "scan/with/escaped/slashes")
        var project = ParticipantProject()
        try project.acceptAnalysis(scan, sourceID: "source")
        let review = try project.reconciliation(for: scan, sourceID: "source")
        struct OriginalPayload: Encodable {
            let geometry: ParticipantSourceGeometry
            let overrides: [ParticipantAppearanceOverride]
            let replacement: ParticipantScanResult
            let affectedParticipantIDs, affectedRedactionIDs, affectedBindingIDs, affectedPresentationIDs: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(OriginalPayload(geometry: project.sources[0], overrides: project.appearanceOverrides,
            replacement: scan, affectedParticipantIDs: review.affectedParticipantIDs, affectedRedactionIDs: review.affectedRedactionIDs,
            affectedBindingIDs: review.affectedBindingIDs, affectedPresentationIDs: review.affectedPresentationIDs))
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try review.reviewToken(for: scan), expected)
    }

    func testChangingLayoutReconcilesWithoutReusingOldTrackIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mov")
        let copy = directory.appendingPathComponent("copy.mov")
        try Data([1, 2, 3]).write(to: original)
        try FileManager.default.copyItem(at: original, to: copy)
        let meeting = try fixtureScan(original, analysisIdentity: "meeting")
        var accepted = ParticipantProject()
        try accepted.acceptAnalysis(meeting, sourceID: "source")
        let participant = try XCTUnwrap(accepted.people.first)
        let appearance = try XCTUnwrap(accepted.sources[0].appearances.first)
        XCTAssertNil(accepted.sources[0].feedLayout)

        for file in [original, copy] {
            let feeds = try fixtureScan(file, analysisIdentity: "feeds", feedLayout: "1x1")
            var revised = accepted
            let review = try revised.reconciliation(for: feeds, sourceID: "source")
            XCTAssertFalse(review.retainedCopiedGeometry)
            XCTAssertFalse(review.sourceChanged)
            XCTAssertEqual(review.removedAppearanceIDs, [appearance.id])
            XCTAssertEqual(review.affectedParticipantIDs, [participant.id])
            try revised.reconcileAnalysis(feeds, sourceID: "source", reviewed: review)
            XCTAssertEqual(revised.sources[0].feedLayout, .fixed(columns: 1, rows: 1))
            XCTAssertEqual(revised.sources[0].unresolvedParticipantIDs, [participant.id])
            XCTAssertEqual(revised.people.map(\.name), ["Participant 1", "Feed 1"])
            XCTAssertNotEqual(revised.sources[0].appearances.first?.participantID, participant.id)
            let reopened = try JSONDecoder().decode(ParticipantProject.self, from: JSONEncoder().encode(revised))
            XCTAssertEqual(reopened, revised)
        }
    }

    func testVerificationRetainsEditedTileAndPreferenceThroughNewMotionBoundary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let adaptive = try fixtureScan(file, analysisIdentity: "adaptive", sampling: "adaptive")
        let verified = try fixtureScan(file, analysisIdentity: "verified", verification: true)
        var project = ParticipantProject()
        try project.acceptAnalysis(adaptive, sourceID: "gallery")
        let feedID = try XCTUnwrap(project.people.first?.id)
        let tileID = try XCTUnwrap(project.sources.first?.appearances.first?.id)
        let corrected = MulticamRange(from: RationalTime(numerator: 1, denominator: 4),
                                      to: RationalTime(numerator: 3, denominator: 4))
        try project.correctBounds(sourceID: "gallery", appearanceID: tileID, bounds: stage, range: corrected)
        try project.correctLabelBounds(sourceID: "gallery", appearanceID: tileID, bounds: thumbnail, range: corrected)
        project.appearanceOverrides = [.init(participantID: feedID, sourceID: "gallery",
                                             appearanceID: tileID, range: range(0, 1))]
        let stored = try JSONDecoder().decode(ParticipantProject.self, from: JSONEncoder().encode(project))
        let review = try stored.reconciliation(for: verified, sourceID: "gallery")
        XCTAssertTrue(review.removedAppearanceIDs.isEmpty)
        XCTAssertTrue(review.affectedParticipantIDs.isEmpty)
        XCTAssertEqual(review.removedOverrideCount, 0)
        project = stored
        try project.reconcileAnalysis(verified, sourceID: "gallery", reviewed: review)
        XCTAssertEqual(project.people.map(\.id), [feedID])
        XCTAssertEqual(project.appearanceOverrides, stored.appearanceOverrides)
        XCTAssertEqual(project.sources[0].coverage.map(\.state), [.verified])
        let atHalf = try XCTUnwrap(project.appearances(sourceID: "gallery", at: RationalTime(numerator: 1, denominator: 2)).first)
        XCTAssertEqual(atHalf.id, tileID)
        XCTAssertEqual(atHalf.participantID, feedID)
        XCTAssertEqual(atHalf.bounds, stage)
        XCTAssertEqual(atHalf.labelBounds, thumbnail)
        let atEnd = try XCTUnwrap(project.appearances(sourceID: "gallery", at: RationalTime(numerator: 7, denominator: 8)).first)
        XCTAssertEqual(atEnd.id, tileID)
        XCTAssertEqual(atEnd.bounds.x, 0.02)
    }

    func testVerificationLeavesCompetingTilesUnreconciled() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let adaptive = try fixtureScan(file, analysisIdentity: "adaptive", sampling: "adaptive")
        let verified = try fixtureScan(file, analysisIdentity: "verified", verification: true, competingTile: true)
        var project = ParticipantProject()
        try project.acceptAnalysis(adaptive, sourceID: "gallery")
        let feedID = try XCTUnwrap(project.people.first?.id)
        let tileID = try XCTUnwrap(project.sources.first?.appearances.first?.id)
        let review = try project.reconciliation(for: verified, sourceID: "gallery")
        XCTAssertEqual(review.removedAppearanceIDs, [tileID])
        XCTAssertEqual(review.affectedParticipantIDs, [feedID])
        try project.reconcileAnalysis(verified, sourceID: "gallery", reviewed: review)
        XCTAssertEqual(project.sources[0].unresolvedParticipantIDs, [feedID])
        XCTAssertFalse(project.sources[0].appearances.contains { $0.participantID == feedID })
    }

    func testPendingReconciliationAppliesChoicesToRetainedFeedIDs() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = try fixtureScan(file, analysisIdentity: "original")
        let replacement = try fixtureScan(file, analysisIdentity: "replacement", participantID: 9)
        var project = ParticipantProject()
        try project.acceptAnalysis(original, sourceID: "gallery")
        let retained = try XCTUnwrap(project.people.first?.id)
        let review = try project.reconciliation(for: replacement, sourceID: "gallery")
        var choices = TilesReviewChoices(scan: replacement)
        choices.names = ["feed-9": "Renamed"]
        choices.unchecked = ["feed-1"]
        try project.reconcileAnalysis(replacement, sourceID: "gallery", reviewed: review, applying: choices)
        XCTAssertEqual(project.people.first?.id, retained)
        XCTAssertEqual(project.people.first?.name, "Renamed")
        XCTAssertEqual(project.sources.first?.appearances.first?.participantID, retained)

        let rerun = try project.reconciliation(for: replacement, sourceID: "gallery")
        choices.unchecked = ["feed-9"]
        try project.reconcileAnalysis(replacement, sourceID: "gallery", reviewed: rerun, applying: choices)
        XCTAssertNil(project.sources.first?.appearances.first?.participantID)
    }

    func testVerificationKeepsRangeSpecificLinkAndFreshCameraState() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let adaptive = try fixtureScan(file, analysisIdentity: "adaptive", sampling: "adaptive")
        let verified = try fixtureScan(file, analysisIdentity: "verified", verification: true, cameraOff: true)
        var project = ParticipantProject()
        try project.acceptAnalysis(adaptive, sourceID: "gallery")
        let original = try XCTUnwrap(project.people.first?.id)
        let tile = try XCTUnwrap(project.sources[0].appearances.first?.id)
        project.people.append(.init(id: "reviewed", name: "Reviewed"))
        try project.linkAppearance(sourceID: "gallery", appearanceID: tile, participantID: "reviewed",
                                   range: .init(from: RationalTime(numerator: 1, denominator: 4),
                                                to: RationalTime(numerator: 3, denominator: 4)))
        let times = [1, 3, 5, 7].map { RationalTime(numerator: Int64($0), denominator: 8) }
        let oldIDs = times.map { project.appearances(sourceID: "gallery", at: $0).first?.id }
        let review = try project.reconciliation(for: verified, sourceID: "gallery")
        XCTAssertTrue(review.removedAppearanceIDs.isEmpty)
        try project.reconcileAnalysis(verified, sourceID: "gallery", reviewed: review)
        let current = times.compactMap { project.appearances(sourceID: "gallery", at: $0).first }
        XCTAssertEqual(current.map { Optional($0.id) }, oldIDs)
        XCTAssertEqual(current.map(\.participantID), [original, "reviewed", "reviewed", original])
        XCTAssertEqual(current.map(\.state), [.video, .video, .cameraOff, .cameraOff])
    }

    private func fixtureScan(_ media: URL, analysisIdentity: String, feedLayout: String? = nil,
                             sampling: String = "sparse", verification: Bool = false,
                             competingTile: Bool = false, cameraOff: Bool = false, participantID: Int = 1) throws -> ParticipantScanResult {
        let stamp = try JSONEncoder().encode(SceneSourceStamp(identity: SourceIdentity(media)))
        let stampObject = try JSONSerialization.jsonObject(with: stamp)
        let zero = ["numerator": 0, "denominator": 1]
        let one = ["numerator": 1, "denominator": 1]
        let transform: [String: Any] = ["rotation": "R0", "pixel_aspect_num": 1, "pixel_aspect_den": 1]
        let region: [String: Any] = [
            "appearance_id": 2, "participant_id": participantID, "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
            "kind": "video", "role": "primary", "confidence": 1, "identity_uncertain": false, "possible_matches": []
        ]
        var analysis: [String: Any] = [
            "schema_version": 1, "start": zero, "end": one, "sampling": "sparse",
            "observations": [["timestamp": zero, "display": transform, "confidence": 1, "regions": [region]]],
            "tracks": [["id": participantID, "appearance_ids": [2]]],
            "appearances": [["id": 2, "participant_id": participantID, "start": zero, "end": one]],
            "events": [], "coverage": [["start": zero, "end": one, "status": "observed"]],
            "diagnostics": [], "resume_at": NSNull()
        ]
        let source: [String: Any] = [
            "file": media.path, "stamp": stampObject, "inode": try SourceIdentity(media).inode,
            "content_sha256": try participantSourceDigest(media, identity: SourceIdentity(media)),
            "stream": 0, "origin": zero, "time_base": one,
            "duration": one, "transform": transform
        ]
        var configuration: [String: Any] = ["backend": "cpu", "sampling": sampling, "include_scenes": false]
        if sampling == "adaptive" || verification { analysis["sampling"] = "every_frame" }
        if sampling == "adaptive" {
            analysis["coverage"] = [["start": zero, "end": one, "status": "inferred"]]
        }
        if verification {
            configuration["sampling"] = "every_frame"
            var moved = region
            moved["rect"] = ["x": 0.02, "y": 0, "width": 0.98, "height": 1]
            if cameraOff { moved["kind"] = "camera_off" }
            var first = [region]
            var second = [moved]
            if competingTile {
                var duplicate = region
                duplicate["appearance_id"] = 3
                duplicate["participant_id"] = 2
                first.append(duplicate)
                second.append(duplicate)
                analysis["tracks"] = [["id": 1, "appearance_ids": [2]], ["id": 2, "appearance_ids": [3]]]
                analysis["appearances"] = [
                    ["id": 2, "participant_id": 1, "start": zero, "end": one],
                    ["id": 3, "participant_id": 2, "start": zero, "end": one]
                ]
            }
            analysis["observations"] = [
                ["timestamp": zero, "display": transform, "confidence": 1, "regions": first],
                ["timestamp": ["numerator": 1, "denominator": 2], "display": transform, "confidence": 1, "regions": second]
            ]
        }
        configuration["feed_layout"] = feedLayout
        let result: [String: Any] = [
            "state": "completed", "source": source, "analysis_identity": analysisIdentity,
            "configuration": configuration, "analysis": analysis
        ]
        return try JSONDecoder().decode(ParticipantScanResult.self, from: JSONSerialization.data(withJSONObject: result))
    }

}

extension ParticipantProjectTests {
    func testChangingCountHintsKeepsAcceptedTilesAndFeeds() throws {
        let feed = ParticipantPerson(id: "feed", name: "Host")
        let tile = ParticipantAppearance(id: "tile", participantID: feed.id,
            range: .init(from: .zero, to: RationalTime(numerator: 1)),
            bounds: .init(x: 0, y: 0, width: 1, height: 1))
        let source = ParticipantSourceGeometry(sourceID: "recording", appearances: [tile])
        var metadata = ParticipantProject(people: [feed], sources: [source])

        let hints = TilesCountHints(expectedFeeds: 2, maxVisibleTiles: 1)
        try metadata.setTileCountHints(sourceID: source.sourceID, hints: hints)
        XCTAssertEqual(metadata.sources[0].countHints, hints)
        XCTAssertEqual(metadata.sources[0].appearances, [tile])
        XCTAssertEqual(metadata.people, [feed])

        XCTAssertThrowsError(try metadata.setTileCountHints(sourceID: source.sourceID,
                                                            hints: .init(maxVisibleTiles: 0)))
        XCTAssertEqual(metadata.sources[0].countHints, hints)
        try metadata.setTileCountHints(sourceID: source.sourceID, hints: nil)
        XCTAssertEqual(metadata.sources, [source])
        XCTAssertEqual(metadata.people, [feed])
    }
}
