import Darwin
import Foundation
@testable import MPCutCore
import XCTest

final class TranscriptStoreStorageTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Several megabytes that no volume keeps inside the file record or matches to other data by chance.
    private func payload() -> Data {
        var bytes = Data(count: 3 << 20)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return bytes
    }

    private func sharesStorage(_ url: URL) -> Bool? {
        try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.mayShareFileContentKey]).mayShareFileContent
    }

    private func requireCloning(in root: URL) throws {
        let plain = root.appendingPathComponent("plain.probe")
        let clone = root.appendingPathComponent("clone.probe")
        defer {
            unlink(plain.path)
            unlink(clone.path)
        }
        try payload().write(to: plain)
        guard sharesStorage(plain) == false, clonefile(plain.path, clone.path, 0) == 0, sharesStorage(clone) == true else {
            throw XCTSkip("This volume does not clone files or does not report that it has.")
        }
    }

    private func location(_ asset: TranscriptAsset, in project: URL) throws -> URL {
        try XCTUnwrap(TranscriptStore.assetLocation(asset, relativeTo: project))
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func modified(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func entries(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func project(_ assets: [TranscriptAsset]) -> CutProject {
        var project = CutProject.sequence([])
        project.transcripts.attachments = assets.enumerated().map { .init(id: "result\($0.offset)", asset: $0.element, bindings: []) }
        return project
    }

    /// Save as an editor does, then let the store judge its files as though `elapsed` had passed.
    /// A file’s change time cannot be set, so only the clock can make one that was just written old.
    private func save(_ project: CutProject, to url: URL, after elapsed: TimeInterval) throws {
        try TranscriptStore.publish(relativeTo: url, keeping: project.transcripts.attachments.map(\.asset),
                                    hasTranscriptMetadata: !project.transcripts.isEmpty,
                                    now: Date().addingTimeInterval(elapsed)) {
            try project.save(to: url)
        }
    }

    private func refusing(_ code: Int32) -> TranscriptStore.Clone {
        { _, _, _ in
            errno = code
            return -1
        }
    }

    func testSaveAsSharesStorageWithTheSourceAsset() throws {
        let root = try directory()
        try requireCloning(in: root)
        let source = root.appendingPathComponent("Edit.cut")
        let destination = root.appendingPathComponent("Copy.cut")
        let data = payload()
        let asset = try TranscriptStore.put(data, relativeTo: source)
        let original = try location(asset, in: source)
        XCTAssertEqual(sharesStorage(original), false)
        let edit = project([asset])
        try edit.save(to: source)
        try setModified(original, Date().addingTimeInterval(-30 * day))

        let saved = try edit.saveNewCopy(to: destination, copyingTranscriptsFrom: source, undo: [], redo: [],
                                         mediaSnapshot: .empty, check: {})
        let copied = try XCTUnwrap(saved.transcripts.attachments.first?.asset)
        let copy = try location(copied, in: destination)
        XCTAssertNotEqual(copy, original)
        XCTAssertEqual(sharesStorage(copy), true)
        XCTAssertEqual(try TranscriptStore.read(copied, relativeTo: destination), data)
        XCTAssertEqual(try CutProject.load(from: destination).transcripts.attachments.map(\.asset), [copied])
        // The copy was placed now, whatever the age of the file it shares storage with.
        XCTAssertLessThan(abs(try modified(copy).timeIntervalSinceNow), 60)
        XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: destination)), [asset.sha256 + ".json"])
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: source), data)

        // Changing one file afterwards leaves the other as it was verified.
        try Data("replaced".utf8).write(to: original)
        XCTAssertEqual(try TranscriptStore.read(copied, relativeTo: destination), data)
    }

    func testRecoveryDraftSharesStorageWithTheNamedProject() throws {
        let root = try directory()
        try requireCloning(in: root)
        let source = root.appendingPathComponent("Edit.cut")
        let draftFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: false)
        let draft = draftFolder.appendingPathComponent("Untitled.cut")
        let data = payload()
        let asset = try TranscriptStore.put(data, relativeTo: source)

        let recovery = try TranscriptStore.copy(in: project([asset]).transcripts, from: source, to: draft, draft: true)
        let copied = try XCTUnwrap(recovery.attachments.first?.asset)
        XCTAssertEqual(sharesStorage(try location(copied, in: draft)), true)
        XCTAssertEqual(try TranscriptStore.read(copied, relativeTo: draft), data)
        // The next recovery write finds the result already there.
        XCTAssertEqual(try TranscriptStore.copy(in: project([asset]).transcripts, from: source, to: draft, draft: true), recovery)
    }

    func testLockedSourceYieldsACopyThatCanBePublishedAndRemoved() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let destination = root.appendingPathComponent("Copy.cut")
        let data = payload()
        let asset = try TranscriptStore.put(data, relativeTo: source)
        let original = try location(asset, in: source)
        XCTAssertEqual(chflags(original.path, UInt32(UF_IMMUTABLE)), 0)
        addTeardownBlock { chflags(original.path, 0) }

        let copied = try XCTUnwrap(TranscriptStore.copy(in: project([asset]).transcripts, from: source, to: destination)
            .attachments.first?.asset)
        let copy = try location(copied, in: destination)
        var info = stat()
        XCTAssertEqual(lstat(copy.path, &info), 0)
        XCTAssertEqual(info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND), 0)
        XCTAssertEqual(try TranscriptStore.read(copied, relativeTo: destination), data)
        XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: destination)), [asset.sha256 + ".json"])
        XCTAssertEqual(unlink(copy.path), 0)
    }

    func testCopyWritesTheBytesWhenTheVolumeRefusesToClone() throws {
        for code in [ENOTSUP, EXDEV, EEXIST] {
            let root = try directory()
            let source = root.appendingPathComponent("Edit.cut")
            let destination = root.appendingPathComponent("Copy.cut")
            let data = payload()
            let asset = try TranscriptStore.put(data, relativeTo: source)

            let copied = try XCTUnwrap(TranscriptStore.copy(in: project([asset]).transcripts, from: source, to: destination,
                                                            draft: false, clone: refusing(code)).attachments.first?.asset)
            let copy = try location(copied, in: destination)
            XCTAssertNotEqual(sharesStorage(copy), true)
            XCTAssertEqual(try TranscriptStore.read(copied, relativeTo: destination), data)
            XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: destination)), [asset.sha256 + ".json"])
        }
    }

    func testCloneThatDoesNotVerifyIsDiscardedForTheVerifiedBytes() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let data = payload()
        let asset = try TranscriptStore.put(data, relativeTo: source)
        let original = try location(asset, in: source)
        // The source changed between the check and the clone, or the clone is not a file at all.
        let clones: [TranscriptStore.Clone] = [
            { _, staged, _ in FileManager.default.createFile(atPath: String(cString: staged), contents: Data("changed".utf8)) ? 0 : -1 },
            { _, staged, _ in symlink(original.path, staged) },
            { _, staged, _ in mkdir(staged, 0o700) }
        ]
        for (index, clone) in clones.enumerated() {
            let destination = root.appendingPathComponent("Copy \(index).cut")
            let copied = try XCTUnwrap(TranscriptStore.copy(in: project([asset]).transcripts, from: source, to: destination,
                                                            draft: false, clone: clone).attachments.first?.asset)
            XCTAssertNil(copied.unavailable)
            XCTAssertEqual(try TranscriptStore.read(copied, relativeTo: destination), data)
            var info = stat()
            XCTAssertEqual(lstat(try location(copied, in: destination).path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: destination)), [asset.sha256 + ".json"])
        }
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: source), data)
    }

    func testDamagedSourceIsReportedWithoutLeavingAStoreBehind() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let destination = root.appendingPathComponent("Copy.cut")
        let asset = try TranscriptStore.put(payload(), relativeTo: source)
        try Data("damaged".utf8).write(to: try location(asset, in: source))

        let copied = try XCTUnwrap(TranscriptStore.copy(in: project([asset]).transcripts, from: source, to: destination)
            .attachments.first?.asset)
        XCTAssertEqual(copied.unavailable, .invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.folder(relativeTo: destination).path))
    }

    func testChosenStoreIsRecoveredWithoutASecondCopyOfItsBytes() throws {
        let root = try directory()
        try requireCloning(in: root)
        let original = root.appendingPathComponent("Original.cut")
        let copy = root.appendingPathComponent("Copy.cut")
        let data = payload()
        let asset = try TranscriptStore.put(data, relativeTo: original)
        try project([asset]).save(to: original)
        try FileManager.default.copyItem(at: original, to: copy)

        let restored = try TranscriptStore.recover(asset, from: TranscriptStore.folder(relativeTo: original), relativeTo: copy)
        XCTAssertEqual(sharesStorage(try location(restored, in: copy)), true)
        XCTAssertEqual(try TranscriptStore.read(restored, relativeTo: copy), data)

        // A damaged file already under the name is set aside before the verified one takes its place.
        try Data("damaged".utf8).write(to: try location(restored, in: copy))
        XCTAssertEqual(try TranscriptStore.recover(asset, from: TranscriptStore.folder(relativeTo: original), relativeTo: copy), restored)
        XCTAssertEqual(try TranscriptStore.read(restored, relativeTo: copy), data)
        XCTAssertEqual(sharesStorage(try location(restored, in: copy)), true)
        XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: copy)).filter { $0.hasPrefix(".damaged-") }.count, 1)

        try Data("damaged".utf8).write(to: try location(asset, in: original))
        XCTAssertThrowsError(try TranscriptStore.recover(asset, from: TranscriptStore.folder(relativeTo: original), relativeTo: copy)) {
            XCTAssertEqual(($0 as? CutError)?.code, "damaged_transcript")
        }
        XCTAssertEqual(try TranscriptStore.read(restored, relativeTo: copy), data)
    }

    func testHeldBytesShareStorageWhileTheirFileRemainsAndAreWrittenOnceItIsGone() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Edit.cut")
        let data = payload()
        let asset = try TranscriptStore.put(data, relativeTo: source)
        let held = try TranscriptStore.read(asset, relativeTo: source)

        let first = root.appendingPathComponent("First.cut")
        let shared = try TranscriptStore.put(held, readFrom: asset, in: source, relativeTo: first)
        XCTAssertEqual(try TranscriptStore.read(shared, relativeTo: first), data)
        let refused = root.appendingPathComponent("Refused.cut")
        let written = try TranscriptStore.put(held, readFrom: asset, in: source, relativeTo: refused, draft: false,
                                              clone: refusing(ENOTSUP))
        XCTAssertEqual(try TranscriptStore.read(written, relativeTo: refused), data)
        XCTAssertNotEqual(sharesStorage(try location(written, in: refused)), true)

        // The source project replaced the file, then pruned it. The held bytes may be a mapping
        // of the old file, which a write in place would cut short.
        try Data("damaged".utf8).write(to: try location(asset, in: source), options: .atomic)
        let second = root.appendingPathComponent("Second.cut")
        XCTAssertEqual(try TranscriptStore.read(TranscriptStore.put(held, readFrom: asset, in: source, relativeTo: second),
                                                relativeTo: second), data)
        try FileManager.default.removeItem(at: TranscriptStore.folder(relativeTo: source))
        let third = root.appendingPathComponent("Third.cut")
        XCTAssertEqual(try TranscriptStore.read(TranscriptStore.put(held, readFrom: asset, in: source, relativeTo: third),
                                                relativeTo: third), data)
        let fourth = root.appendingPathComponent("Fourth.cut")
        XCTAssertThrowsError(try TranscriptStore.put(Data("other".utf8), readFrom: asset, in: source, relativeTo: fourth)) {
            XCTAssertEqual(($0 as? CutError)?.code, "damaged_transcript")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.folder(relativeTo: fourth).path))

        try requireCloning(in: root)
        XCTAssertEqual(sharesStorage(try location(shared, in: first)), true)
    }

    func testStoringBytesTheStoreAlreadyHoldsMarksTheFileInUse() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let data = Data("dialogue".utf8)
        let asset = try TranscriptStore.put(data, relativeTo: url)
        let file = try location(asset, in: url)

        let recent = Date().addingTimeInterval(-600)
        try setModified(file, recent)
        XCTAssertEqual(try TranscriptStore.put(data, relativeTo: url), asset)
        XCTAssertEqual(try modified(file).timeIntervalSince(recent), 0, accuracy: 1)

        try setModified(file, Date().addingTimeInterval(-3 * day))
        XCTAssertEqual(try TranscriptStore.put(data, relativeTo: url), asset)
        XCTAssertLessThan(abs(try modified(file).timeIntervalSinceNow), 60)
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: url), data)
    }

    func testSavingRemovesOnlyOldUnreferencedResults() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let store = TranscriptStore.folder(relativeTo: url)
        let kept = try TranscriptStore.put(Data("kept".utf8), relativeTo: url)
        let edit = project([kept])
        try edit.save(to: url)

        // Attached and replaced without a save in between: no saved project ever named them.
        let abandoned = try TranscriptStore.put(Data("abandoned".utf8), relativeTo: url)
        let recent = try TranscriptStore.put(Data("recent".utf8), relativeTo: url)
        func digest(_ content: String) -> String { TranscriptStore.digest(Data(content.utf8)) }
        let outside = root.appendingPathComponent("Outside.json")
        try Data("outside".utf8).write(to: outside)
        let link = digest("outside") + ".json"
        try FileManager.default.createSymbolicLink(at: store.appendingPathComponent(link), withDestinationURL: outside)
        let folder = String(repeating: "cd", count: 32) + ".json"
        try FileManager.default.createDirectory(at: store.appendingPathComponent(folder), withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: store.appendingPathComponent(folder).appendingPathComponent("keep"))
        // Each holds the bytes its name would promise, so only the name keeps it.
        let misnamed = [
            "notes": "notes.json", "capitals": digest("capitals").uppercased() + ".json",
            "short": String(digest("short").dropLast()) + ".json", "long": digest("long") + "0.json",
            "text": digest("text") + ".txt", "backup": digest("backup") + ".json.bak",
            "suffix": digest("suffix") + ".JSON", "hidden": "." + digest("hidden") + ".json",
            "set aside": ".damaged-" + UUID().uuidString
        ]
        for (content, name) in misnamed { try Data(content.utf8).write(to: store.appendingPathComponent(name)) }
        // Named like a result, but these are not the bytes the name promises.
        try Data("damaged".utf8).write(to: store.appendingPathComponent(String(repeating: "ab", count: 32) + ".json"))
        let before = try entries(store)
        XCTAssertEqual(before.count, 3 + 2 + misnamed.count + 1)

        // Nothing here has gone a day untouched.
        try edit.save(to: url)
        XCTAssertEqual(try entries(store), before)

        // One hour old by the clock the store is about to be given.
        try setModified(try location(recent, in: url), Date().addingTimeInterval(24 * 60 * 60))
        try save(edit, to: url, after: 25 * 60 * 60)
        XCTAssertEqual(try entries(store), before.filter { $0 != abandoned.sha256 + ".json" })
        XCTAssertEqual(TranscriptStore.assetStatus(abandoned, relativeTo: url), .missing)
        XCTAssertEqual(try TranscriptStore.read(kept, relativeTo: url), Data("kept".utf8))
        XCTAssertEqual(try TranscriptStore.read(recent, relativeTo: url), Data("recent".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: store.appendingPathComponent(link).path), outside.path)
        XCTAssertEqual(try entries(store.appendingPathComponent(folder)), ["keep"])
        XCTAssertEqual(try CutProject.load(from: url), edit)
    }

    func testResultDeliveredRecentlyWithAnOldModificationTimeStays() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let edit = project([try TranscriptStore.put(Data("kept".utf8), relativeTo: url)])
        try edit.save(to: url)
        let arriving = try TranscriptStore.put(Data("arriving".utf8), relativeTo: url)
        // A copy or a sync keeps the time the file was written elsewhere.
        try setModified(try location(arriving, in: url), Date().addingTimeInterval(-30 * day))

        try edit.save(to: url)
        XCTAssertEqual(try TranscriptStore.read(arriving, relativeTo: url), Data("arriving".utf8))
    }

    func testUndoHistoryNamesNoResultThatASaveMustKeep() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let current = try TranscriptStore.put(Data("current".utf8), relativeTo: url)
        let edit = project([current])
        try edit.save(to: url)
        let earlier = try TranscriptStore.put(Data("earlier".utf8), relativeTo: url)
        var before = project([earlier])
        before.transcripts.authoring = [.init(attachmentID: "result0", change: .renameSpeaker(speakerID: "a", name: "Host"),
                                              anchors: [])]

        try TranscriptStore.publish(relativeTo: url, keeping: [current], hasTranscriptMetadata: true,
                                    now: Date().addingTimeInterval(25 * 60 * 60)) {
            try edit.save(to: url, undo: [.init(action: "Rename Speaker", project: before)], redo: [])
        }
        // Undo brings back the authored record. The attachment stays the current one.
        let loaded = try CutProject.loadDocument(from: url, limit: 5)
        XCTAssertEqual(loaded.undo.first?.project.transcripts.authoring, before.transcripts.authoring)
        XCTAssertEqual(loaded.undo.first?.project.transcripts.attachments, edit.transcripts.attachments)
        XCTAssertEqual(TranscriptStore.assetStatus(earlier, relativeTo: url), .missing)
        XCTAssertEqual(try TranscriptStore.read(current, relativeTo: url), Data("current".utf8))
    }

    func testResultMarkedUnavailableKeepsTheFileUnderItsName() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let asset = try TranscriptStore.put(Data("dialogue".utf8), relativeTo: url)
        let edit = project([.init(file: asset.file, sha256: asset.sha256, unavailable: .missing)])
        try edit.save(to: url)

        try save(edit, to: url, after: 25 * 60 * 60)
        XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: url), Data("dialogue".utf8))
    }

    func testSavingLeavesEveryOtherStoreAlone() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let former = root.appendingPathComponent("Former.cut")
        let edit = project([try TranscriptStore.put(Data("kept".utf8), relativeTo: url)])
        try edit.save(to: url)
        let abandoned = try TranscriptStore.put(Data("abandoned".utf8), relativeTo: url)

        // A project one folder down, a store whose project is gone, and the recovery store of
        // an unsaved project. None of them puts a second project in this folder.
        let nestedFolder = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: false)
        let nested = nestedFolder.appendingPathComponent("Nested.cut")
        let attached = try TranscriptStore.put(Data("nested".utf8), relativeTo: nested)
        try project([attached]).save(to: nested)
        let pending = try TranscriptStore.put(Data("nested pending".utf8), relativeTo: nested)
        let left = try TranscriptStore.put(Data("left behind".utf8), relativeTo: former)
        let draftFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: false)
        let draft = draftFolder.appendingPathComponent("Untitled.cut")
        let unsaved = try TranscriptStore.put(Data("unsaved".utf8), relativeTo: draft, draft: true)

        try save(edit, to: url, after: 25 * 60 * 60)
        XCTAssertEqual(TranscriptStore.assetStatus(abandoned, relativeTo: url), .missing)
        XCTAssertEqual(try TranscriptStore.read(attached, relativeTo: nested), Data("nested".utf8))
        XCTAssertEqual(try TranscriptStore.read(pending, relativeTo: nested), Data("nested pending".utf8))
        XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: former)), [left.sha256 + ".json"])
        XCTAssertEqual(try TranscriptStore.read(unsaved, relativeTo: draft), Data("unsaved".utf8))
    }

    func testNothingIsSweptWhileAnotherProjectSharesTheFolder() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let sibling = root.appendingPathComponent("Sibling.cut")
        let edit = project([try TranscriptStore.put(Data("kept".utf8), relativeTo: url)])
        try edit.save(to: url)
        let abandoned = try TranscriptStore.put(Data("abandoned".utf8), relativeTo: url)
        let attached = try TranscriptStore.put(Data("sibling".utf8), relativeTo: sibling)
        try project([attached]).save(to: sibling)
        let pending = try TranscriptStore.put(Data("sibling pending".utf8), relativeTo: sibling)

        try save(edit, to: url, after: 25 * 60 * 60)
        XCTAssertEqual(try TranscriptStore.read(abandoned, relativeTo: url), Data("abandoned".utf8))
        XCTAssertEqual(try TranscriptStore.read(pending, relativeTo: sibling), Data("sibling pending".utf8))

        // Alone in its folder, the project can tell that the result is its own leftover.
        try FileManager.default.removeItem(at: sibling)
        try save(edit, to: url, after: 25 * 60 * 60)
        XCTAssertEqual(TranscriptStore.assetStatus(abandoned, relativeTo: url), .missing)
        XCTAssertEqual(try TranscriptStore.read(edit.transcripts.attachments[0].asset, relativeTo: url), Data("kept".utf8))
        XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: sibling)), [attached.sha256, pending.sha256].sorted().map { $0 + ".json" })
    }

    func testOldOrphanIsRemovedWhenTheFolderHoldsOnlyThisProject() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let kept = try TranscriptStore.put(Data("kept".utf8), relativeTo: url)
        let edit = project([kept])
        try edit.save(to: url)
        let abandoned = try TranscriptStore.put(Data("abandoned".utf8), relativeTo: url)
        // Not a project, whatever it has in its name.
        try Data().write(to: root.appendingPathComponent("Edit.cut.bak"))

        try save(edit, to: url, after: 25 * 60 * 60)
        XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: url)), [kept.sha256 + ".json"])
        XCTAssertEqual(TranscriptStore.assetStatus(abandoned, relativeTo: url), .missing)
    }

    func testRenamedProjectKeepsTheStoreANewProjectOfItsNameFinds() throws {
        for name in ["Q.cut", "Q.CUT"] {
            let root = try directory()
            let original = root.appendingPathComponent("P.cut")
            let renamed = root.appendingPathComponent(name)
            let data = Data("dialogue".utf8)
            let asset = try TranscriptStore.put(data, relativeTo: original)
            try project([asset]).save(to: original)
            // Finder renames the project and leaves its store under the former name.
            try FileManager.default.moveItem(at: original, to: renamed)
            XCTAssertEqual(try TranscriptStore.read(asset, relativeTo: renamed), data)

            // The second save replaces a project, so only the renamed one beside it holds the sweep back.
            for _ in 0..<2 { try save(project([]), to: original, after: 25 * 60 * 60) }
            XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: original)), [asset.sha256 + ".json"])
            XCTAssertEqual(try CutProject.load(from: renamed).transcripts.attachments.map(\.asset), [asset])
            XCTAssertThrowsError(try TranscriptStore.read(asset, relativeTo: renamed)) {
                XCTAssertEqual(($0 as? CutError)?.code, "ambiguous_transcript_store")
            }
            let restored = try TranscriptStore.recover(asset, from: TranscriptStore.folder(relativeTo: original), relativeTo: renamed)
            XCTAssertEqual(restored.file, "\(name).transcripts/\(asset.sha256).json")
            XCTAssertEqual(try TranscriptStore.read(restored, relativeTo: renamed), data)
            XCTAssertEqual(try entries(TranscriptStore.folder(relativeTo: original)), [asset.sha256 + ".json"])
        }
    }

    func testFolderThatCannotBeListedIsNotSwept() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let edit = project([try TranscriptStore.put(Data("kept".utf8), relativeTo: url)])
        try edit.save(to: url)
        let abandoned = try TranscriptStore.put(Data("abandoned".utf8), relativeTo: url)
        // Files can still be written and reached by name, but another project would go unseen.
        XCTAssertEqual(chmod(root.path, 0o300), 0)
        addTeardownBlock { chmod(root.path, 0o700) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) == nil else {
            throw XCTSkip("This user can list a folder without read permission.")
        }

        try save(edit, to: url, after: 25 * 60 * 60)
        XCTAssertEqual(try TranscriptStore.read(abandoned, relativeTo: url), Data("abandoned".utf8))
    }

    func testFirstWriteLeavesAStoreThatWasAlreadyThere() throws {
        let root = try directory()
        let former = root.appendingPathComponent("Edit.cut")
        // The project that wrote this was moved elsewhere without its store.
        let left = try TranscriptStore.put(Data("left behind".utf8), relativeTo: former)

        try save(project([]), to: former, after: 25 * 60 * 60)
        XCTAssertEqual(try TranscriptStore.read(left, relativeTo: former), Data("left behind".utf8))
    }

    func testRecoveryDraftStoresAreNeverSwept() throws {
        let root = try directory()
        let draftFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: false)
        let draft = draftFolder.appendingPathComponent("Untitled.cut")
        let unsaved = try TranscriptStore.put(Data("unsaved".utf8), relativeTo: draft, draft: true)
        let beside = try TranscriptStore.put(Data("beside".utf8), relativeTo: draft)

        for _ in 0..<2 { try save(project([]), to: draft, after: 25 * 60 * 60) }
        XCTAssertEqual(try TranscriptStore.read(unsaved, relativeTo: draft), Data("unsaved".utf8))
        XCTAssertEqual(try TranscriptStore.read(beside, relativeTo: draft), Data("beside".utf8))
    }

    func testStoreReachedThroughALinkIsNotSwept() throws {
        let root = try directory()
        let url = root.appendingPathComponent("Edit.cut")
        let other = root.appendingPathComponent("Other.cut")
        let pending = try TranscriptStore.put(Data("pending".utf8), relativeTo: other)
        try FileManager.default.createSymbolicLink(at: TranscriptStore.folder(relativeTo: url),
                                                   withDestinationURL: TranscriptStore.folder(relativeTo: other))

        for _ in 0..<2 { try save(project([]), to: url, after: 25 * 60 * 60) }
        XCTAssertEqual(try TranscriptStore.read(pending, relativeTo: other), Data("pending".utf8))
    }
}
