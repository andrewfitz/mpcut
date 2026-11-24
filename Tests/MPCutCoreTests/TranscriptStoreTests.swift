import Foundation
@testable import MPCutCore
import XCTest

final class TranscriptStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSaveAsCopiesCurrentAttachmentAndAuthoredHistory() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let destination = root.appendingPathComponent("Edit Copy.cut")
        let first = Data("{\"words\":[]}".utf8)
        let second = Data("{\"words\":[\"First\"]}".utf8)
        let discarded = try TranscriptStore.put(first, relativeTo: source)
        let accepted = try TranscriptStore.put(second, relativeTo: source)
        let binding = TranscriptBinding(trackID: "TR1", file: "recordings/Voice.wav", streamIndex: 1)
        var previous = CutProject.sequence([])
        previous.transcripts.attachments = [.init(id: "dialogue", asset: discarded, bindings: [binding])]
        previous.transcripts.documentID = UUID()
        try previous.save(to: source)

        var current = previous
        current.transcripts.attachments[0].asset = accepted
        try current.transcripts.advanceRevision()
        current.transcripts.authoring = [.init(attachmentID: "dialogue", change: .renameSpeaker(speakerID: "a", name: "Host"), anchors: [])]
        _ = try current.saveRevision(to: source, undo: [.init(action: "Rename Speaker", project: previous)], redo: [], mediaSnapshot: .empty,
                                 expected: nil)
        let loaded = try CutProject.loadDocument(from: source, limit: 5)
        XCTAssertEqual(loaded.project, current)
        XCTAssertEqual(loaded.undo.first?.project.transcripts.attachments, current.transcripts.attachments)
        XCTAssertEqual(loaded.undo.first?.project.transcripts.authoring, [])
        XCTAssertEqual(loaded.undo.first?.project.transcripts.documentID, current.transcripts.documentID)
        XCTAssertThrowsError(try TranscriptStore.read(discarded, relativeTo: source))
        XCTAssertEqual(TranscriptStore.assetStatus(discarded, relativeTo: source), .missing)
        XCTAssertEqual(try TranscriptStore.read(accepted, relativeTo: source), second)

        var saved = try current.rebased(from: source, to: destination)
        saved.transcripts = try TranscriptStore.copy(in: saved.transcripts, from: source, to: destination)
        let copy = try XCTUnwrap(saved.transcripts.attachments.first?.asset)
        XCTAssertNotEqual(copy.file, accepted.file)
        XCTAssertEqual(copy.sha256, accepted.sha256)
        try saved.save(to: destination)
        try FileManager.default.removeItem(at: TranscriptStore.folder(relativeTo: source))
        XCTAssertEqual(try TranscriptStore.read(copy, relativeTo: destination), second)
        XCTAssertEqual(try CutProject.load(from: destination), saved)
        XCTAssertEqual(saved.transcripts.documentID, previous.transcripts.documentID)
    }

    func testDraftStoreIsSeparateAndVerifiesBytes() throws {
        let root = try directory()
        let draftFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: false)
        let draft = draftFolder.appendingPathComponent("Untitled.cut")
        let bytes = Data("cue payload".utf8)
        let first = try TranscriptStore.put(bytes, relativeTo: draft, draft: true)
        XCTAssertEqual(try TranscriptStore.put(bytes, relativeTo: draft, draft: true), first)
        XCTAssertEqual(try TranscriptStore.read(first, relativeTo: draft), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: draftFolder.path), [])
        let path = CutProject.mediaURL(first.file, relativeTo: draft)
        try Data("wrong".utf8).write(to: path)
        XCTAssertThrowsError(try TranscriptStore.read(first, relativeTo: draft)) { error in
            XCTAssertEqual((error as? CutError)?.code, "damaged_transcript")
        }
    }

    func testRedirectedDraftStoreDoesNotCreateDirectoriesAtItsTarget() throws {
        let root = try directory()
        let target = try directory()
        let draftID = UUID().uuidString
        let draft = root.appendingPathComponent(draftID).appendingPathComponent("Untitled.cut")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".transcripts"),
                                                   withDestinationURL: target)

        XCTAssertThrowsError(try TranscriptStore.put(Data([1]), relativeTo: draft, draft: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testExclusiveCopyRollsBackOnlyNewTranscriptAssets() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let destination = root.appendingPathComponent("Copy.cut")
        let bytes = Data("attached transcript".utf8)
        let asset = try TranscriptStore.put(bytes, relativeTo: source)
        let retained = try TranscriptStore.put(Data("other transcript".utf8), relativeTo: destination)
        let store = TranscriptStore.folder(relativeTo: destination)
        let copiedPath = store.appendingPathComponent(asset.sha256 + ".json")
        var project = CutProject.sequence([])
        project.transcripts.attachments = [.init(id: "dialogue", asset: asset, bindings: [])]

        enum Cancelled: Error { case test }
        XCTAssertThrowsError(try project.saveNewCopy(to: destination, copyingTranscriptsFrom: source,
                                                    undo: [], redo: [], mediaSnapshot: .empty) {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".mpcut-") }) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: copiedPath.path))
                throw Cancelled.test
            }
        }) { error in
            XCTAssertEqual(error as? Cancelled, .test)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedPath.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".mpcut-") }))
        XCTAssertEqual(try TranscriptStore.read(retained, relativeTo: destination), Data("other transcript".utf8))
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: source), bytes)

        var previous = project
        previous.transcripts.authoring = [.init(attachmentID: "dialogue",
                                                change: .renameSpeaker(speakerID: "a", name: "Host"), anchors: [])]
        try project.saveNewCopy(to: destination, copyingTranscriptsFrom: source,
                                undo: [.init(action: "Rename Speaker", project: previous)], redo: [], mediaSnapshot: .empty, check: {})
        let copy = try CutProject.loadDocument(from: destination, limit: 1)
        let attached = try XCTUnwrap(copy.project.transcripts.attachments.first?.asset)
        XCTAssertEqual(try TranscriptStore.read(attached, relativeTo: destination), bytes)
        XCTAssertEqual(copy.undo.first?.project.transcripts.attachments, copy.project.transcripts.attachments)
        XCTAssertEqual(copy.undo.first?.project.transcripts.authoring, previous.transcripts.authoring)
        XCTAssertThrowsError(try project.saveNewCopy(to: destination, copyingTranscriptsFrom: source,
                                                    undo: [], redo: [], mediaSnapshot: .empty, check: {})) {
            XCTAssertEqual(($0 as? CutError)?.code, "destination_exists")
        }
    }

    func testInPlaceAttachmentBytesFollowExpectedRevisionAndPublication() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let current = CutProject.sequence([])
        try current.save(to: url)
        let revision = try CutProject.loadEditorDocument(from: url, limit: 0).media.diskRevision

        let bytes = Data("new transcript".utf8)
        let asset = TranscriptStore.reference(for: bytes, relativeTo: url)
        var updated = current
        updated.transcripts.attachments = [.init(id: "dialogue", asset: asset, bindings: [])]

        enum Cancelled: Error { case test }
        XCTAssertThrowsError(try updated.saveCopy(to: url, copyingTranscriptsFrom: url, undo: [], redo: [], mediaSnapshot: .empty,
                                                 replacingExisting: true, expected: revision, assetData: [asset: bytes],
                                                 beforePublish: { throw Cancelled.test }, check: {})) {
            XCTAssertEqual($0 as? Cancelled, .test)
        }
        XCTAssertEqual(try CutProject.load(from: url), current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.folder(relativeTo: url).path))

        try updated.saveCopy(to: url, copyingTranscriptsFrom: url, undo: [], redo: [], mediaSnapshot: .empty,
                             replacingExisting: true, expected: revision, assetData: [asset: bytes], check: {})
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: url), bytes)

        let staleBytes = Data("stale transcript".utf8)
        let staleAsset = TranscriptStore.reference(for: staleBytes, relativeTo: url)
        updated.transcripts.attachments[0].asset = staleAsset
        XCTAssertThrowsError(try updated.saveCopy(to: url, copyingTranscriptsFrom: url, undo: [], redo: [], mediaSnapshot: .empty,
                                                 replacingExisting: true, expected: revision,
                                                 assetData: [staleAsset: staleBytes], check: {})) {
            XCTAssertEqual(($0 as? CutError)?.code, "project_save_conflict")
        }
        XCTAssertEqual(try CutProject.load(from: url).transcripts.attachments[0].asset, asset)
        XCTAssertThrowsError(try TranscriptStore.read(staleAsset, relativeTo: url))
    }

    func testBindingDistinguishesUnverifiedChangedAndOfflineRecordings() throws {
        let root = try directory()
        let document = root.appendingPathComponent("Interview.cut")
        let recording = root.appendingPathComponent("Mic.wav")
        try Data([1]).write(to: recording)
        let binding = TranscriptBinding(trackID: "voice", file: "Mic.wav", streamIndex: 1)
        let project = CutProject.sequence([])
        XCTAssertEqual(binding.sourceStatus(in: project, relativeTo: document), .unverified)
        let inferred = binding.stamped(in: project, relativeTo: document, confirmed: false)
        XCTAssertEqual(inferred.sourceStatus(in: project, relativeTo: document), .unverified)
        let confirmed = inferred.stamped(in: project, relativeTo: document, confirmed: true)
        XCTAssertEqual(confirmed.sourceStatus(in: project, relativeTo: document), .available)
        try Data([2, 3]).write(to: recording, options: .atomic)
        XCTAssertEqual(inferred.sourceStatus(in: project, relativeTo: document), .changed)
        XCTAssertEqual(confirmed.sourceStatus(in: project, relativeTo: document), .changed)
        let rebound = confirmed.stamped(in: project, relativeTo: document, confirmed: true)
        XCTAssertEqual(rebound.sourceStatus(in: project, relativeTo: document), .available)
        try FileManager.default.removeItem(at: recording)
        XCTAssertEqual(rebound.sourceStatus(in: project, relativeTo: document), .offline)
        let group = MulticamProject(referenceAngle: "A", range: .init(from: .zero, to: .init(numerator: 1)),
                                    angles: [.init(id: "A", file: "Mic.wav")], audio: .follow,
                                    switches: [.init(at: .zero, angle: "A")])
        let missing = TranscriptBinding(trackID: "voice", sourceID: "B", streamIndex: 1)
        XCTAssertEqual(missing.sourceStatus(in: .multicam(group), relativeTo: document), .bindingMissing)
    }

    func testAuthoredPauseProtectionReanchorsOneAttachmentAndSkipsConflicts() throws {
        let root = try directory()
        let project = root.appendingPathComponent("Edit.cut")
        let file = root.appendingPathComponent("Microphone.wav")
        try Data([0]).write(to: file)
        let shift = RationalTime(numerator: 1, denominator: 8)
        func document(shift: RationalTime = .zero, firstText: String = "before") throws -> TranscriptDocument {
            let words = try [(firstText, 11, 12), ("after", 16, 17)].enumerated().map { index, value in
                let from = try RationalTime(numerator: Int64(value.1)).adding(shift)
                let to = try RationalTime(numerator: Int64(value.2)).adding(shift)
                return TranscriptWord(id: String(index), text: value.0, start: from, end: to,
                    observations: [.init(trackID: "voice", start: from, end: to, evidence: .recognized)])
            }
            return .init(clock: .presentation, tracks: [.init(id: "voice", name: "Voice")], words: words)
        }
        let original = try document()
        func attachment(_ document: TranscriptDocument, id: String, binding: TranscriptBinding) throws -> TranscriptAttachment {
            let bytes = try TranscriptCodec.encode(document, format: .json)
            return .init(id: id, asset: try TranscriptStore.put(bytes, relativeTo: project), bindings: [binding],
                         importOrigin: .init(numerator: 2))
        }
        func state(binding: TranscriptBinding) throws -> ProjectTranscripts {
            let originalAttachment = try attachment(original, id: "dialogue", binding: binding)
            let words = try TranscriptIndex.sourceOccurrences(document: original, attachment: originalAttachment)
            let anchors = try words.map { try TranscriptEditorial.anchor([$0], binding: binding) }
            let refreshed = try attachment(document(shift: shift), id: "dialogue", binding: binding)
            let unrelated = try attachment(original, id: "other", binding: binding)
            return .init(attachments: [refreshed, unrelated],
                         authoring: [.init(attachmentID: "dialogue", change: .pauseProtection(name: "A pause"), anchors: anchors)])
        }
        let binding = TranscriptBinding(trackID: "voice", file: file.path, streamIndex: 1, offset: .init(numerator: 1))
        var sequence = try state(binding: binding)
        var cache = TranscriptPauseProtectionCache()
        let protections = cache.resolve(sequence, relativeTo: project)
        XCTAssertEqual(protections.sequence(file: file.path, origin: .init(numerator: 10), stream: 1, sourceFingerprint: ""),
                       [.init(from: .init(numerator: 41, denominator: 8), to: .init(numerator: 73, denominator: 8))])
        XCTAssertEqual(protections.sequence(file: file.path, origin: .zero, stream: 0, sourceFingerprint: ""), [])
        sequence.attachments[0] = try attachment(document(firstText: "changed"), id: "dialogue", binding: binding)
        XCTAssertEqual(cache.resolve(sequence, relativeTo: project)
            .sequence(file: file.path, origin: .zero, stream: 1, sourceFingerprint: ""), [])
        var ambiguous = try document(shift: shift)
        var another = try document(shift: .init(numerator: -1, denominator: 8)).words[0]
        another.id = "another"
        ambiguous.words.insert(another, at: 0)
        sequence.attachments[0] = try attachment(ambiguous, id: "dialogue", binding: binding)
        XCTAssertTrue(cache.resolve(sequence, relativeTo: project).isEmpty)

        let groupState = try state(binding: .init(trackID: "voice", sourceID: "A", streamIndex: 1,
                                                  offset: .init(numerator: -1)))
        let group = MulticamProject(referenceAngle: "A", range: .init(from: .zero, to: .init(numerator: 30)),
            angles: [.init(id: "A", file: file.path, offset: .init(numerator: 3))], audio: .follow,
            switches: [.init(at: .zero, angle: "A")])
        XCTAssertEqual(cache.resolve(groupState, relativeTo: project).group(sources: group.sources, sourceFingerprints: ["A": ""]),
                       [.init(from: .init(numerator: 129, denominator: 8), to: .init(numerator: 161, denominator: 8))])
    }

    func testSaveAsPreservesUnavailableReferencesWithoutCopyingDamagedBytes() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let destination = root.appendingPathComponent("Copy.cut")
        let missing = try TranscriptStore.put(Data([1]), relativeTo: source)
        let invalid = try TranscriptStore.put(Data([2]), relativeTo: source)
        var project = CutProject.sequence([])
        project.transcripts.attachments = [
            .init(id: "missing", asset: missing, bindings: []),
            .init(id: "invalid", asset: invalid, bindings: [])
        ]
        try project.save(to: source)
        try FileManager.default.removeItem(at: CutProject.mediaURL(missing.file, relativeTo: source))
        try Data([3]).write(to: CutProject.mediaURL(invalid.file, relativeTo: source))
        var copy = project
        copy.transcripts = try TranscriptStore.copy(in: copy.transcripts, from: source, to: destination)
        try copy.save(to: destination)
        let loaded = try CutProject.load(from: destination)
        let assets = loaded.transcripts.attachments.map(\.asset)
        XCTAssertEqual(assets.map(\.unavailable), [.missing, .invalid])
        XCTAssertEqual(assets.map { TranscriptStore.assetStatus($0, relativeTo: destination) }, [.missing, .invalid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.folder(relativeTo: destination).path))
        XCTAssertEqual(loaded.sequenceClips, project.sequenceClips)
        XCTAssertThrowsError(try TranscriptStore.read(assets[1], relativeTo: destination)) {
            XCTAssertEqual(($0 as? CutError)?.code, "damaged_transcript")
        }

        let draftFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: false)
        let draftURL = draftFolder.appendingPathComponent("Untitled.cut")
        var recovery = project
        recovery.transcripts = try TranscriptStore.copy(in: project.transcripts, from: source, to: draftURL, draft: true)
        try recovery.saveStaged(to: draftURL, undo: [], redo: [], mediaSnapshot: .empty)
        let recovered = try CutProject.load(from: draftURL)
        XCTAssertEqual(recovered.transcripts.attachments.map(\.asset.unavailable), [.missing, .invalid])

        _ = try TranscriptStore.put(Data([2]), relativeTo: destination)
        XCTAssertEqual(try TranscriptStore.read(assets[1], relativeTo: destination), Data([2]))
    }

    func testPruningCannotDeleteReplacementDirectoryOrCorruptedBytes() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let directoryAsset = try TranscriptStore.put(Data([1]), relativeTo: source)
        let corruptedAsset = try TranscriptStore.put(Data([2]), relativeTo: source)
        var project = CutProject.sequence([])
        project.transcripts.attachments = [
            .init(id: "directory", asset: directoryAsset, bindings: []),
            .init(id: "corrupt", asset: corruptedAsset, bindings: [])
        ]
        try project.save(to: source)
        let directory = CutProject.mediaURL(directoryAsset.file, relativeTo: source)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let marker = directory.appendingPathComponent("keep")
        try Data([9]).write(to: marker)
        let corrupt = CutProject.mediaURL(corruptedAsset.file, relativeTo: source)
        try Data([3]).write(to: corrupt)
        project.transcripts.attachments = []
        try project.save(to: source)
        XCTAssertEqual(try Data(contentsOf: marker), Data([9]))
        XCTAssertEqual(try Data(contentsOf: corrupt), Data([3]))
    }

    func testFinderRenameReadsTheFormerOrRenamedStoreAndNormalizesTheNextSave() throws {
        for moveStore in [false, true] {
            let root = try directory()
            let original = root.appendingPathComponent("Original.cut")
            let renamed = root.appendingPathComponent("Renamed.cut")
            let data = Data("dialogue".utf8)
            let asset = try TranscriptStore.put(data, relativeTo: original)
            var project = CutProject.sequence([])
            project.transcripts.attachments = [.init(id: "dialogue", asset: asset, bindings: [])]
            try project.save(to: original)
            try FileManager.default.moveItem(at: original, to: renamed)
            if moveStore {
                try FileManager.default.moveItem(at: TranscriptStore.folder(relativeTo: original),
                                                 to: TranscriptStore.folder(relativeTo: renamed))
            }

            let actual = try XCTUnwrap(TranscriptStore.assetLocation(asset, relativeTo: renamed))
            XCTAssertThrowsError(try project.validateDestination(actual, relativeTo: renamed))
            XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: renamed), data)
            project.transcripts = try TranscriptStore.copy(in: project.transcripts, from: renamed, to: renamed)
            try project.save(to: renamed)
            let saved = try XCTUnwrap(CutProject.load(from: renamed).transcripts.attachments.first?.asset)
            XCTAssertEqual(saved.file, "Renamed.cut.transcripts/\(asset.sha256).json")
            XCTAssertEqual(try TranscriptStore.read(saved, relativeTo: renamed), data)
            if !moveStore {
                let oldPath = TranscriptStore.folder(relativeTo: original).appendingPathComponent(asset.sha256 + ".json")
                XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path))
            }
        }
    }

    func testCopiedProjectRequiresExplicitRecoveryFromOriginalNamedStore() throws {
        let root = try directory()
        let original = root.appendingPathComponent("Original.cut")
        let copy = root.appendingPathComponent("Copy.cut")
        let data = Data([7])
        let asset = try TranscriptStore.put(data, relativeTo: original)
        var project = CutProject.sequence([])
        project.transcripts.attachments = [.init(id: "dialogue", asset: asset, bindings: [])]
        try project.save(to: original)
        try FileManager.default.copyItem(at: original, to: copy)

        XCTAssertThrowsError(try TranscriptStore.read(asset, relativeTo: copy)) {
            XCTAssertEqual(($0 as? CutError)?.code, "ambiguous_transcript_store")
        }
        let corrupted = try TranscriptStore.put(data, relativeTo: copy)
        try Data([9]).write(to: CutProject.mediaURL(corrupted.file, relativeTo: copy))
        let restored = try TranscriptStore.recover(asset, from: TranscriptStore.folder(relativeTo: original), relativeTo: copy)
        let entries = try FileManager.default.contentsOfDirectory(at: TranscriptStore.folder(relativeTo: copy),
                                                                  includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(entries.first { $0.lastPathComponent.hasPrefix(".damaged-") })
        XCTAssertEqual(try Data(contentsOf: backup), Data([9]))
        XCTAssertEqual(try TranscriptStore.read(restored, relativeTo: copy), data)
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: original), data)
        XCTAssertNotEqual(restored.file, asset.file)
    }

    func testPhysicalProjectAliasesWorkWhileRedirectedStoresAreRejected() throws {
        let root = try directory()
        let parentAlias = root.appendingPathComponent("Alias", isDirectory: true)
        let physicalRoot = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: physicalRoot)
        let throughAlias = parentAlias.appendingPathComponent("Edit.cut")
        let named = physicalRoot.appendingPathComponent("Edit.cut")
        let asset = try TranscriptStore.put(Data([1]), relativeTo: throughAlias)
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: named), Data([1]))

        let otherDocument = physicalRoot.appendingPathComponent("Other.cut")
        let otherStore = TranscriptStore.folder(relativeTo: otherDocument)
        let realStore = TranscriptStore.folder(relativeTo: named)
        try FileManager.default.createSymbolicLink(at: otherStore, withDestinationURL: realStore)
        XCTAssertThrowsError(try TranscriptStore.put(Data([2]), relativeTo: otherDocument))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realStore.path).count, 1)
    }

    func testStoreRejectsPathsOutsideProject() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let destination = root.appendingPathComponent("Other.cut")
        let asset = try TranscriptStore.put(Data(), relativeTo: source)
        XCTAssertThrowsError(try TranscriptStore.read(asset, relativeTo: destination))
        let claim = root.appendingPathComponent(asset.sha256 + ".json")
        try Data().write(to: claim)
        let forged = TranscriptAsset(file: claim.lastPathComponent, sha256: asset.sha256)
        XCTAssertThrowsError(try TranscriptStore.read(forged, relativeTo: source))
    }
}
