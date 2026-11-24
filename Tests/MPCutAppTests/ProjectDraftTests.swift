import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ProjectDraftTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testDraftIsAllocatedOnWriteAndReclaimedAfterInterruptedSession() throws {
        var first: ProjectDraft? = ProjectDraft(directory: directory)
        XCTAssertNil(first?.url)
        XCTAssertEqual(try ProjectDraft.recoverable(in: directory), [])
        let bytes = Data("first".utf8)
        try first?.write { try bytes.write(to: $0, options: .atomic) }
        let file = try XCTUnwrap(first?.url)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(try XCTUnwrap(first).adopt(first?.reserveIfRecoverable(file)))
        XCTAssertTrue(try ProjectDraft.recoverable(in: directory).isEmpty)
        let second = ProjectDraft(directory: directory)
        XCTAssertThrowsError(try second.reserveIfRecoverable(file))
        XCTAssertNil(second.url)
        first = nil
        XCTAssertEqual(try ProjectDraft.recoverable(in: directory).map { $0.resolvingSymlinksInPath().path }, [file.resolvingSymlinksInPath().path])
        XCTAssertTrue(try second.adopt(second.reserveIfRecoverable(file)))
        try second.write { try Data("recovered".utf8).write(to: $0, options: .atomic) }
        XCTAssertEqual(try String(contentsOf: file), "recovered")
        second.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try ProjectDraft.recoverable(in: directory).isEmpty)
    }

    func testFailedWriteCanRetryAndSecondWindowOwnsSeparateFile() throws {
        let first = ProjectDraft(directory: directory)
        let second = ProjectDraft(directory: directory)
        XCTAssertThrowsError(try first.write { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertNil(first.url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        try first.write { try Data("one".utf8).write(to: $0, options: .atomic) }
        try second.write { try Data("two".utf8).write(to: $0, options: .atomic) }
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertThrowsError(try first.write {
            try Data("partial".utf8).write(to: $0)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.url)), "one")
        XCTAssertNil(try first.reserveIfRecoverable(directory.appendingPathComponent("saved.cut")))
        first.discard()
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(second.url)), "two")
        second.discard()
    }

    func testScheduledProjectArchivePublishesUnderExistingDraftLease() throws {
        let draft = ProjectDraft(directory: directory)
        try draft.write { try Data().write(to: $0) }
        let file = try XCTUnwrap(draft.url)
        let project = CutProject.sequence([
            .init(id: "clip", file: "offline.mov", from: .zero, to: .init(numerator: 1))
        ])
        let undo: [CutHistoryState] = [.init(action: "Add Clip", project: .sequence([]))]
        try draft.schedule({ try project.saveStaged(to: $0, undo: undo, redo: [], mediaSnapshot: .empty) },
                           onError: { XCTFail($0.localizedDescription) })

        let deadline = Date().addingTimeInterval(10)
        while draft.hasScheduledWrites && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(draft.hasScheduledWrites)
        let document = try CutProject.loadDocument(from: file, limit: 1)
        XCTAssertEqual(document.project, project)
        XCTAssertEqual(document.undo, undo)
        XCTAssertThrowsError(try ProjectDraft.reserveIfRecoverable(file, in: directory)) {
            XCTAssertEqual(($0 as? CutError)?.code, "draft_in_use")
        }
        draft.discard()
    }

    func testWishlistMediaAndReplayRoundTripThroughRecoveredDrafts() throws {
        let projects = [
            ("wishlist-sequence", false, "cutaway.mov", "unused"),
            ("wishlist-multicam", true, "original-part-2.mov", "A2")
        ]
        for (name, multicam, historyFile, historyID) in projects {
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "cut", subdirectory: "Fixtures"))
            let input = try CutProject.loadDocument(from: fixture, limit: 2)
            if case .multicam(let project) = input.project {
                XCTAssertEqual(project.angles.first?.additionalRecordings.first?.file, "wide-part-2.mov")
                XCTAssertEqual(project.assemblyItems?.last?.angleOverride, "B")
                if case .multicam(let redo) = input.redo.first?.project {
                    XCTAssertNil(redo.assemblyItems?.last?.angleOverride)
                } else {
                    XCTFail("Expected a multicam redo state")
                }
            } else {
                XCTAssertEqual(input.project.sourceSelects.first?.name, "Reaction shot")
                XCTAssertEqual(input.undo.first?.project.sourceSelects.count, 2)
            }
            var draft: ProjectDraft? = ProjectDraft(directory: directory)
            try draft?.write { try input.project.saveStaged(to: $0, undo: input.undo, redo: input.redo, mediaSnapshot: input.mediaSnapshot) }
            let file = try XCTUnwrap(draft?.url)
            draft = nil
            XCTAssertTrue(try ProjectDraft.recoverable(in: directory).contains {
                $0.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path
            })
            let recovered = try CutProject.loadDocument(from: file, limit: 2)
            XCTAssertEqual(recovered.project, input.project)
            XCTAssertEqual(recovered.undo, input.undo)
            XCTAssertEqual(recovered.redo, input.redo)

            let media = try CutProjectMedia.load(from: file, multicam: multicam)
            let protectedURL = file.deletingLastPathComponent().appendingPathComponent(historyFile)
            XCTAssertEqual(media.absoluteSources(relativeTo: file)[protectedURL.path], historyID)
            XCTAssertThrowsError(try media.validateDestination(protectedURL, relativeTo: file)) {
                XCTAssertEqual(($0 as? CutError)?.code, "cut_project_source_collision")
            }
        }
    }

    func testBackgroundWritesCoalesceAndPublishInOrder() throws {
        let draft = ProjectDraft(directory: directory)
        try draft.write { try Data("initial".utf8).write(to: $0) }
        let file = try XCTUnwrap(draft.url)
        let began = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        try draft.schedule({ url in
            began.signal()
            guard resume.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
            try Data("earlier".utf8).write(to: url)
        }, onError: { XCTFail($0.localizedDescription) })
        XCTAssertEqual(began.wait(timeout: .now() + 10), .success)
        try draft.schedule({ _ in XCTFail("Superseded draft should never be encoded") },
                           onError: { XCTFail($0.localizedDescription) })
        try draft.schedule({ try Data("latest".utf8).write(to: $0) },
                           onError: { XCTFail($0.localizedDescription) })
        XCTAssertEqual(try String(contentsOf: file), "initial")
        resume.signal()
        let limit = Date().addingTimeInterval(10)
        while draft.hasScheduledWrites && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(draft.hasScheduledWrites)
        XCTAssertEqual(try String(contentsOf: file), "latest")
        draft.discard()
    }

    func testCompletingBackgroundWriteCannotResurrectDiscardedDraft() throws {
        let draft = ProjectDraft(directory: directory)
        try draft.write { try Data().write(to: $0) }
        let file = try XCTUnwrap(draft.url)
        let staged = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        try draft.schedule({ url in
            try Data("staged".utf8).write(to: url)
            staged.signal()
            _ = resume.wait(timeout: .now() + 10)
            ended.signal()
        }, onError: { XCTFail($0.localizedDescription) })
        XCTAssertEqual(staged.wait(timeout: .now() + 10), .success)
        draft.discard()
        resume.signal()
        XCTAssertEqual(ended.wait(timeout: .now() + 10), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try ProjectDraft.recoverable(in: directory).isEmpty)
    }

    func testReservationExcludesOtherOpenersBeforeDecodeAndReleasesOnCancellation() throws {
        var previous: ProjectDraft? = ProjectDraft(directory: directory)
        try previous?.write { try Data("saved".utf8).write(to: $0) }
        let file = try XCTUnwrap(previous?.url)
        previous = nil
        let first = ProjectDraft(directory: directory)
        let second = ProjectDraft(directory: directory)
        var claim = try first.reserveIfRecoverable(file)
        XCTAssertNotNil(claim)
        XCTAssertNil(first.url)
        XCTAssertThrowsError(try second.reserveIfRecoverable(file))
        XCTAssertTrue(try ProjectDraft.recoverable(in: directory).isEmpty)
        // A canceled or failed open releases its unadopted reservation without altering the file.
        claim = nil
        XCTAssertEqual(try Data(contentsOf: file), Data("saved".utf8))
        XCTAssertTrue(try second.adopt(second.reserveIfRecoverable(file)))
        XCTAssertThrowsError(try first.reserveIfRecoverable(file))
        second.discard()
    }

    func testSaveAsRecognizesTheEntireAutosaveDirectoryThroughAnAlias() throws {
        let draft = ProjectDraft(directory: directory)
        try draft.write { try Data().write(to: $0) }
        defer { draft.discard() }
        let file = try XCTUnwrap(draft.url)
        let other = file.deletingLastPathComponent().appendingPathComponent("My Saved Cut.cut")
        let alias = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertTrue(draft.managesDestination(other))
        XCTAssertTrue(draft.managesDestination(alias.appendingPathComponent("Named.cut")))
        XCTAssertFalse(draft.managesDestination(directory.deletingLastPathComponent().appendingPathComponent("Named.cut")))
    }

    func testMovingTheFolderCannotPublishIntoOrDiscardAReplacementDraft() throws {
        let draft = ProjectDraft(directory: directory)
        try draft.write { try Data("mine".utf8).write(to: $0) }
        let file = try XCTUnwrap(draft.url)
        let folder = file.deletingLastPathComponent()
        let moved = directory.appendingPathComponent("moved")
        let staged = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let failed = expectation(description: "draft reports the moved folder")
        try draft.schedule({ url in
            try Data("next".utf8).write(to: url)
            staged.signal()
            _ = resume.wait(timeout: .now() + 10)
        }, onError: { _ in failed.fulfill() })
        XCTAssertEqual(staged.wait(timeout: .now() + 10), .success)
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("another draft".utf8).write(to: file)
        resume.signal()
        wait(for: [failed], timeout: 10)
        XCTAssertThrowsError(try draft.write { try Data().write(to: $0) })
        draft.discard()
        XCTAssertEqual(try String(contentsOf: file), "another draft")
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent(file.lastPathComponent)), "mine")
    }

    func testRelinquishedDraftDrainsItsLastQueuedEditBeforeItBecomesRecoverable() throws {
        let owner = ProjectDraft(directory: directory)
        try owner.write { try Data("initial".utf8).write(to: $0) }
        let file = try XCTUnwrap(owner.url)
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        try owner.schedule({ url in
            started.signal()
            _ = finish.wait(timeout: .now() + 10)
            try Data("first".utf8).write(to: url)
        }, onError: { XCTFail($0.localizedDescription) })
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        try owner.schedule({ try Data("final".utf8).write(to: $0) }, onError: { XCTFail($0.localizedDescription) })
        owner.relinquish()
        owner.discard()
        XCTAssertNil(owner.url)
        XCTAssertTrue(try ProjectDraft.recoverable(in: directory).isEmpty)
        finish.signal()
        let deadline = Date().addingTimeInterval(10)
        while try ProjectDraft.recoverable(in: directory).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(try ProjectDraft.recoverable(in: directory).count, 1)
        XCTAssertEqual(try String(contentsOf: file), "final")
    }

}
