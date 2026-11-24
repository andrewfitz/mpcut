import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class ProjectMediaRelinkTests: XCTestCase {
    func testRelinkFittedSoundtrackRetainsExactDurationAndSavedHistory() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("edit.cut")
        let moved = folder.appendingPathComponent("Moved.wav")
        try wave().write(to: moved)
        let format = StillTimelineFormat(width: 320, height: 180, cadence: .init(numerator: 1, denominator: 30),
                                         codec: .h264, container: "mov")
        let asset = StillAsset(id: "cover", file: "cover.png", displayName: "Cover", fingerprint: "fixture")
        let original = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "picture",
                                                        duration: .init(numerator: 1))
        let duration = RationalTime(numerator: 15_999, denominator: 16_000)
        let recording = clip("cover-soundtrack", end: duration)
        let attached = try original.attachingStillSoundtrack(recording)
        let fitted = try attached.fittingStillToSoundtrack()
        let undo = [CutHistoryState(action: "Fit Image to Soundtrack", project: attached)]
        let result = try ProjectMedia.relink(project: fitted, undo: undo, relativeTo: document,
                                             from: recording.file, to: moved)
        XCTAssertEqual(result.candidate.outcome, .match)
        XCTAssertEqual(result.project.stillSoundtrack?.file, moved.lastPathComponent)
        XCTAssertEqual(result.undo.first?.project.stillSoundtrack?.file, moved.lastPathComponent)
        XCTAssertEqual(try result.project.resolveStills().duration, duration)
        try result.project.save(to: document, undo: result.undo, redo: [], mediaSnapshot: result.snapshot)
        let reopened = try CutProject.loadDocument(from: document, limit: 10)
        XCTAssertEqual(reopened.project, result.project)
        XCTAssertEqual(reopened.undo, result.undo)
        XCTAssertTrue(reopened.mediaSnapshot.entries.contains { $0.path == moved.lastPathComponent && $0.hasCompleteProof })
    }

    func testCacheOnlyObservationKeepsSavedExpectedProofForTheSameFingerprint() throws {
        let root = try temporaryFolder()
        let file = root.appendingPathComponent("take.wav")
        try wave().write(to: file)
        let engine = CutEngine(useSidecar: false)
        let media = try engine.inspect(file)
        let original = ProjectMediaSnapshot.Entry(path: file.path, media: media)
        let snapshot = ProjectMediaSnapshot(entries: [original])
        XCTAssertTrue(original.hasCompleteProof)

        let sidecar = AnalysisSidecar(media: media)
        try sidecar.save(AnalysisSidecar.indexSections(for: media))
        let indexed = try XCTUnwrap(sidecar.loadIndex(detail: .full, cancelled: { false }))
        XCTAssertFalse(ProjectMediaSnapshot.Entry(path: file.path, media: indexed).hasCompleteProof)
        XCTAssertEqual(snapshot.merging(media: [(file.path, indexed)]), snapshot)

        try wave(amplitude: 400).write(to: file, options: .atomic)
        let newGeneration = try engine.inspect(file)
        let replacementSidecar = AnalysisSidecar(media: newGeneration)
        try replacementSidecar.save(AnalysisSidecar.indexSections(for: newGeneration))
        let newIndex = try XCTUnwrap(replacementSidecar.loadIndex(detail: .full, cancelled: { false }))
        let unverified = try XCTUnwrap(snapshot.merging(media: [(file.path, newIndex)]).entries.first)
        XCTAssertNil(unverified.sourceFingerprint)
        XCTAssertFalse(unverified.hasCompleteProof)

        let updated = try XCTUnwrap(snapshot.merging(media: [(file.path, newGeneration)]).entries.first)
        XCTAssertTrue(updated.verifies(newGeneration))
        XCTAssertNotEqual(updated.sourceFingerprint, original.sourceFingerprint)
    }

    func testSnapshotMappingKeepsProofWithoutJoiningDifferentRevertRecords() throws {
        let root = try temporaryFolder()
        let file = root.appendingPathComponent("take.wav")
        try wave().write(to: file)
        let media = try CutEngine(useSidecar: false).inspect(file)
        var descriptive = ProjectMediaSnapshot.Entry(path: file.lastPathComponent)
        descriptive.previousPath = "first.wav"
        descriptive.relinkUses = ["occurrence-a"]
        descriptive.ignored = true
        descriptive.unknownFields["memo"] = .string("retained")
        var proven = ProjectMediaSnapshot.Entry(path: file.path, media: media)
        proven.previousPath = "second.wav"
        proven.relinkUses = ["occurrence-b"]
        let original = ProjectMediaSnapshot(entries: [descriptive, proven])

        let collapsed = original.mappingPaths { $0 == file.lastPathComponent ? file.path : $0 }
        let saved = try XCTUnwrap(collapsed.entries.first)
        XCTAssertEqual(collapsed.entries.count, 1)
        XCTAssertTrue(saved.verifies(media))
        XCTAssertEqual(saved.sourceFingerprint, proven.sourceFingerprint)
        XCTAssertEqual(saved.ignored, true)
        XCTAssertEqual(saved.unknownFields["memo"], .string("retained"))
        XCTAssertNil(saved.previousPath)
        XCTAssertNil(saved.relinkUses)

        var partial = ProjectMediaSnapshot.Entry(path: file.path)
        partial.previousPath = "third.wav"
        let updated = try XCTUnwrap(original.merging(.init(entries: [partial])).entries.first { $0.path == file.path })
        XCTAssertEqual(updated.previousPath, "third.wav")
        XCTAssertNil(updated.relinkUses)
        XCTAssertFalse(updated.hasCompleteProof)
    }

    func testRelinkKeepsSnapshotEntriesForIndependentDestinationSpellings() throws {
        let root = try temporaryFolder()
        let document = root.appendingPathComponent("edit.cut")
        let file = root.appendingPathComponent("take.wav")
        try wave().write(to: file)
        let project = CutProject.sequence([clip("old"), clip("independent", path: file.path)])
        var source = ProjectMediaSnapshot.Entry(path: "Missing.wav")
        source.unknownFields["source_note"] = .string("source")
        var destination = ProjectMediaSnapshot.Entry(path: file.path)
        destination.unknownFields["destination_note"] = .string("destination")

        let result = try ProjectMedia.relink(project: project, snapshot: .init(entries: [source, destination]),
                                             relativeTo: document, from: "Missing.wav", to: file)
        let entries = Dictionary(uniqueKeysWithValues: result.snapshot.entries.map { ($0.path, $0) })
        let moved = try XCTUnwrap(entries["take.wav"])
        let independent = try XCTUnwrap(entries[file.path])
        XCTAssertNil(moved.previousPath)
        XCTAssertNil(independent.previousPath)
        XCTAssertEqual(moved.unknownFields["source_note"], .string("source"))
        XCTAssertEqual(independent.unknownFields["destination_note"], .string("destination"))
        try result.project.save(to: document, mediaSnapshot: result.snapshot)
        let reopened = try CutProject.loadDocument(from: document, limit: 0).mediaSnapshot
        XCTAssertEqual(Set(reopened.entries.map(\.path)), Set(entries.keys))

        let archive = result.snapshot.mappingPaths { _ in file.path }
        let combined = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertTrue(combined.hasCompleteProof)
        XCTAssertEqual(combined.unknownFields["source_note"], .string("source"))
        XCTAssertEqual(combined.unknownFields["destination_note"], .string("destination"))
    }

    func testRelinkMapsBothHistoryBranchesAndRevertChecksIndependentRedoUse() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let destination = folder.appendingPathComponent("Destination.wav")
        try wave().write(to: destination)
        let current = CutProject.sequence([clip("current")])
        let undo = [CutHistoryState(action: "Undo", origin: .agent, project: .sequence([clip("before")]))]
        let redo = [CutHistoryState(action: "Redo", origin: .user, project: .sequence([clip("after")]))]

        let linked = try ProjectMedia.relink(project: current, undo: undo, redo: redo, relativeTo: document,
                                             from: "Missing.wav", to: destination)
        XCTAssertEqual(linked.candidate.outcome, .match)
        XCTAssertEqual(linked.project.sequenceClips?.map(\.file), ["Destination.wav"])
        XCTAssertEqual(linked.undo.first?.project.sequenceClips?.map(\.file), ["Destination.wav"])
        XCTAssertEqual(linked.redo.first?.project.sequenceClips?.map(\.file), ["Destination.wav"])
        XCTAssertEqual(linked.undo.first?.origin, .agent)

        let encoded = try linked.project.encodedArchive(undo: linked.undo, redo: linked.redo, mediaSnapshot: linked.snapshot,
                                                       byteLimit: MulticamProject.maximumFileSize).0
        let reopened = try CutProject.decodeEditorDocument(encoded, limit: 10)
        let reopenedSnapshot = reopened.media.mediaSnapshot
        XCTAssertTrue(ProjectMedia.inventory(project: reopened.project, undo: reopened.undo, redo: reopened.redo,
                                             relativeTo: document, snapshot: reopenedSnapshot).first?.canRevert == true)
        let independent = CutHistoryState(action: "Import", project: .sequence([clip("independent", path: "Destination.wav")]))
        let extraRedo = linked.redo + [independent]
        XCTAssertFalse(ProjectMedia.inventory(project: linked.project, undo: linked.undo, redo: extraRedo,
                                              relativeTo: document, snapshot: linked.snapshot).first?.canRevert == true)
        XCTAssertThrowsError(try ProjectMedia.revert(project: linked.project, undo: linked.undo, redo: extraRedo,
                                                      snapshot: linked.snapshot, relativeTo: document,
                                                      from: "Destination.wav"))

        let reverted = try ProjectMedia.revert(project: reopened.project, undo: reopened.undo, redo: reopened.redo,
                                               snapshot: reopenedSnapshot, relativeTo: document, from: "Destination.wav")
        XCTAssertEqual(reverted.project.sequenceClips?.map(\.file), ["Missing.wav"])
        XCTAssertEqual(reverted.redo.first?.project.sequenceClips?.map(\.file), ["Missing.wav"])
    }

    func testVerifiedRelinkRestampsOnlyMatchingTranscriptGenerations() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let original = folder.appendingPathComponent("Missing.wav")
        let candidate = folder.appendingPathComponent("Moved.wav")
        try wave().write(to: original)
        let saved = ProjectMediaSnapshot.Entry(path: "Missing.wav", media: try Probe.read(original, forcePayload: true))
        let oldFingerprint = try XCTUnwrap(saved.sourceFingerprint)
        try FileManager.default.copyItem(at: original, to: candidate)
        try FileManager.default.removeItem(at: original)
        let otherFingerprint = String(repeating: "f", count: 64)

        let matching = TranscriptBinding(trackID: "a", file: "Missing.wav", streamIndex: 0,
                                         sourceFingerprint: oldFingerprint, sourceConfirmed: true)
        let stale = TranscriptBinding(trackID: "b", file: "Missing.wav", streamIndex: 0,
                                      sourceFingerprint: otherFingerprint, sourceConfirmed: false)
        let unverified = TranscriptBinding(trackID: "c", file: "Missing.wav", streamIndex: 0)
        let digest = String(repeating: "a", count: 64)
        let asset = TranscriptAsset(file: "Edit.transcripts/\(digest).json", sha256: digest)
        let attachment = TranscriptAttachment(id: "attachment", asset: asset, bindings: [matching, stale, unverified])
        let timing = MulticamRange(from: .zero, to: RationalTime(numerator: 1, denominator: 4))
        let record = TranscriptAuthoredRecord(id: "record", attachmentID: attachment.id,
                                              change: .assignSpeaker(speakerID: "speaker"), anchors: [
                                                .init(binding: matching, range: timing, wordCount: 1, wordingHash: digest)
                                              ], speakerReference:
                                                .init(binding: stale, range: timing, wordCount: 1, wordingHash: digest))
        var project = CutProject.sequence([clip("current")])
        project.transcripts = .init(attachments: [attachment], authoring: [record])
        let relinked = try ProjectMedia.relink(project: project, snapshot: .init(entries: [saved]),
                                               relativeTo: document, from: "Missing.wav", to: candidate)
        let newFingerprint = try SourceIdentity(candidate).transcriptFingerprint
        XCTAssertNotEqual(newFingerprint, oldFingerprint)
        XCTAssertEqual(relinked.candidate.outcome, .verified)
        let bindings = try XCTUnwrap(relinked.project.transcripts.attachments.first?.bindings)
        XCTAssertEqual(bindings.map(\.file), ["Moved.wav", "Moved.wav", "Moved.wav"])
        XCTAssertEqual(bindings.map(\.sourceFingerprint), [newFingerprint, otherFingerprint, nil])
        XCTAssertEqual(bindings.map(\.sourceConfirmed), [true, false, nil])
        let authoring = try XCTUnwrap(relinked.project.transcripts.authoring.first)
        XCTAssertEqual(authoring.anchors.first?.binding.sourceFingerprint, newFingerprint)
        XCTAssertEqual(authoring.speakerReference?.binding.sourceFingerprint, otherFingerprint)
        XCTAssertEqual(authoring.speakerReference?.binding.file, "Moved.wav")
    }

    func testVerifiedRelinkKeepsTileLayoutsAndInvalidatesConfirmationsInHistory() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let original = folder.appendingPathComponent("Original.mp4")
        let candidate = folder.appendingPathComponent("Moved.mp4")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        try FileManager.default.copyItem(at: fixture, to: original)
        let media = try Probe.read(original, forcePayload: true)
        let saved = ProjectMediaSnapshot.Entry(path: original.lastPathComponent, media: media)
        let digest = try participantSourceDigest(original, identity: media.identity)
        try FileManager.default.copyItem(at: original, to: candidate)
        try FileManager.default.removeItem(at: original)

        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let layout = TileLayoutSpan(range: range, layout: .solo, slots: [.init(target: .camera, id: original.lastPathComponent)])
        var project = CutProject.sequence([.init(id: "clip", file: original.lastPathComponent, from: range.from,
                                                  to: range.to, tileLayouts: [layout])])
        let box = ParticipantAppearance(id: "tile", participantID: "guest", range: range,
                                        bounds: .init(x: 0, y: 0, width: 1, height: 1))
        project.participants = .init(people: [.init(id: "guest", name: "Guest", treatment: .init(mode: .blur))], sources: [
            .init(sourceID: original.lastPathComponent, analysisIdentity: "scan", sourceStamp: .init(media: media),
                  sourceInode: media.identity.inode, sourceContentSHA256: digest, appearances: [box],
                  coverage: [.init(range: range, state: .verified)])
        ])
        try project.participants.confirmPrivacy(sourceID: original.lastPathComponent, participantID: "guest", range: range)
        let undo = [CutHistoryState(action: "Edit Tile Layout", project: project)]
        let result = try ProjectMedia.relink(project: project, undo: undo, snapshot: .init(entries: [saved]),
                                             relativeTo: document, from: original.lastPathComponent, to: candidate)
        XCTAssertEqual(result.candidate.outcome, .verified)
        for state in [result.project] + result.undo.map(\.project) {
            XCTAssertEqual(state.sequenceClips?.first?.tileLayouts.first?.slots.first?.id, candidate.lastPathComponent)
            XCTAssertEqual(state.participants.sources.first?.sourceID, candidate.lastPathComponent)
            XCTAssertEqual(state.participants.sources.first?.appearances, [box])
            XCTAssertNil(state.participants.sources.first?.confirmations)
        }
    }

    func testFreshReadVetoesSameSizeWaveRewriteAndHistoryRangeShortfall() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let original = folder.appendingPathComponent("Missing.wav")
        let candidate = folder.appendingPathComponent("Candidate.wav")
        try wave(amplitude: 100).write(to: original)
        let saved = ProjectMediaSnapshot.Entry(path: "Missing.wav", media: try Probe.read(original, forcePayload: true))
        try wave(amplitude: 100).write(to: candidate)
        let current = CutProject.sequence([clip("current")])
        let assessment = try ProjectMedia.assess(project: current, snapshot: .init(entries: [saved]),
                                                  relativeTo: document, from: "Missing.wav", to: candidate)
        XCTAssertEqual(assessment.outcome, .verified)
        let generation = try SourceIdentity(candidate)
        try wave(amplitude: 500).write(to: candidate)
        let stamp = timespec(tv_sec: generation.modifiedSeconds, tv_nsec: generation.modifiedNanoseconds)
        let times = [stamp, stamp]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, candidate.path, $0.baseAddress, 0) }, 0)
        XCTAssertThrowsError(try assessment.checkGeneration())
        let conflict = try ProjectMedia.assess(project: current, snapshot: .init(entries: [saved]),
                                               relativeTo: document, from: "Missing.wav", to: candidate)
        XCTAssertEqual(conflict.outcome, .different)

        let history = [CutHistoryState(action: "Longer clip", project: .sequence([clip("long", end: RationalTime(numerator: 4))]))]
        let short = try ProjectMedia.assess(project: current, undo: history, relativeTo: document,
                                            from: "Missing.wav", to: candidate)
        XCTAssertEqual(short.outcome, .different)
        XCTAssertTrue(short.reason?.contains("long") == true)
    }

    func testLocateNormalizesNamesAndReportsAmbiguity() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let search = folder.appendingPathComponent("Search")
        for branch in ["A", "B"] {
            let root = search.appendingPathComponent(branch)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try wave().write(to: root.appendingPathComponent("cafe\u{301}.WAV"))
            try wave().write(to: root.appendingPathComponent("cafe\u{301}.aif"))
        }
        let project = CutProject.sequence([clip("current", path: "Café.wav")])
        let rows = try ProjectMedia.locate(project: project, relativeTo: document, folder: search)
        XCTAssertEqual(rows.map(\.outcome), [.ambiguous])
        XCTAssertEqual(rows.first?.candidates.count, 2)
    }

    func testReviewPinsGenerationAndBatchPreservesUnresolvedParentTraversal() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let file = folder.appendingPathComponent("Take.wav")
        let project = CutProject.sequence([clip("current")])
        try wave().write(to: file)

        let invalid = CutProject.mediaURL("unknown/../Take.wav", relativeTo: document)
        let unresolved = ProjectMedia.relink(project: project, relativeTo: document,
                                             mappings: [.init(from: "Missing.wav", to: invalid)])
        XCTAssertEqual(unresolved.project, project)
        XCTAssertEqual(unresolved.rows.map(\.candidate.outcome), [.pending])
        XCTAssertEqual(unresolved.rows.first?.to.path, invalid.path)

        let reviewed = try ProjectMedia.assess(project: project, relativeTo: document, from: "Missing.wav", to: file)
        XCTAssertEqual(reviewed.outcome, .match)
        try wave(amplitude: 500).write(to: file, options: .atomic)
        let fresh = try ProjectMedia.assess(project: project, relativeTo: document, from: "Missing.wav", to: file)
        XCTAssertEqual(fresh.outcome, .match)
        let stale = ProjectMedia.relink(project: project, relativeTo: document,
                                        mappings: [.init(from: "Missing.wav", candidate: reviewed)])
        XCTAssertEqual(stale.project, project)
        XCTAssertEqual(stale.rows.map(\.candidate.outcome), [.pending])
        XCTAssertEqual(stale.rows.first?.candidate.reason, "The candidate changed before the project could be updated.")
    }

    func testBatchKeepsOtherMatchesWhenAnInspectedCandidateChanges() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let first = folder.appendingPathComponent("First.wav")
        let second = folder.appendingPathComponent("Second.wav")
        try wave().write(to: first)
        try wave().write(to: second)
        let project = CutProject.sequence([clip("first", path: "Old1.wav"), clip("second", path: "Old2.wav")])
        var removed = false

        let result = ProjectMedia.relink(project: project, relativeTo: document,
                                         mappings: [.init(from: "Old1.wav", to: first), .init(from: "Old2.wav", to: second)],
                                         progress: { progress in
            if progress > 0.5, progress < 1, !removed {
                removed = (try? FileManager.default.removeItem(at: first)) != nil
            }
        })

        XCTAssertTrue(removed)
        XCTAssertEqual(result.rows.map(\.candidate.outcome), [.pending, .match])
        XCTAssertEqual(result.project.sequenceClips?.map(\.file), ["Old1.wav", "Second.wav"])
    }

    func testLocatePrefersMatchingSubfolderAndDefersAnUnresolvedPeer() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let search = folder.appendingPathComponent("Archive")
        let intended = search.appendingPathComponent("Recovered/Day/Take.wav")
        let sibling = search.appendingPathComponent("Other/Take.wav")
        for file in [intended, sibling] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wave().write(to: file)
        }
        let project = CutProject.sequence([clip("current", path: "Old/Day/Take.wav")])
        let resolved = try XCTUnwrap(ProjectMedia.locate(project: project, relativeTo: document, folder: search).first)
        XCTAssertEqual(resolved.outcome, .match)
        XCTAssertEqual(resolved.candidates.first.map { ProjectFile.canonicalFileURL($0.url) }, ProjectFile.canonicalFileURL(intended))

        let unresolved = search.appendingPathComponent("Unreadable/Day/Take.wav")
        try FileManager.default.createDirectory(at: unresolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Incomplete recording".utf8).write(to: unresolved)
        let pending = try XCTUnwrap(ProjectMedia.locate(project: project, relativeTo: document, folder: search).first)
        XCTAssertEqual(pending.outcome, .pending)
    }

    func testRelinkAcceptsAnAbsoluteAliasToTheOfflineProjectPath() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalFolder = folder.appendingPathComponent("Source")
        let aliasFolder = folder.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasFolder, withDestinationURL: originalFolder)
        let document = folder.appendingPathComponent("Edit.cut")
        let file = folder.appendingPathComponent("Moved.wav")
        try wave().write(to: file)
        let project = CutProject.sequence([clip("current", path: "Source/Day/Missing.wav")])
        let alias = aliasFolder.appendingPathComponent("Day/Missing.wav")

        let result = try ProjectMedia.relink(project: project, relativeTo: document, from: alias.path, to: file)
        XCTAssertEqual(result.project.sequenceClips?.first?.file, "Moved.wav")
        XCTAssertEqual(result.snapshot.entries.first?.previousPath, "Source/Day/Missing.wav")
    }

    func testTranscriptAnchorCoverageUsesImportOriginAndBindingOffset() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("Edit.cut")
        let file = folder.appendingPathComponent("Take.wav")
        try wave().write(to: file)
        let digest = String(repeating: "a", count: 64)
        let binding = TranscriptBinding(trackID: "a", file: "Missing.wav", streamIndex: 0,
                                        offset: .init(numerator: 1, denominator: 3))
        let asset = TranscriptAsset(file: "Edit.transcripts/\(digest).json", sha256: digest)
        let attachment = TranscriptAttachment(id: "attachment", asset: asset, bindings: [binding],
                                              importOrigin: .init(numerator: 1, denominator: 3))
        let timing = MulticamRange(from: .zero, to: .init(numerator: 1, denominator: 2))
        let anchor = TranscriptAnchor(binding: binding, range: timing, wordCount: 1, wordingHash: digest)
        let record = TranscriptAuthoredRecord(id: "record", attachmentID: attachment.id,
                                              change: .assignSpeaker(speakerID: "speaker"), anchors: [anchor])
        var project = CutProject.sequence([clip("current")])
        project.transcripts = .init(attachments: [attachment], authoring: [record])

        let candidate = try ProjectMedia.assess(project: project, relativeTo: document, from: "Missing.wav", to: file)
        XCTAssertEqual(candidate.outcome, .different)
        XCTAssertTrue(candidate.reason?.contains("transcriptAnchor") == true)
    }

    private func clip(_ id: String, path: String = "Missing.wav", end: RationalTime = RationalTime(numerator: 1, denominator: 2)) -> CutSequenceClip {
        .init(id: id, file: path, from: .zero, to: end, audioTrack: 0)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func wave(amplitude: UInt16 = 100) -> Data {
        var data = Data()
        func tag(_ value: String) { data.append(contentsOf: value.utf8) }
        func append<Integer: FixedWidthInteger>(_ value: Integer) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let count: UInt32 = 32_000
        tag("RIFF")
        append(count + 36)
        tag("WAVE")
        tag("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(count)
        append(UInt16(2))
        append(UInt16(16))
        tag("data")
        append(count)
        for _ in 0..<(count / 2) { append(amplitude) }
        return data
    }
}
