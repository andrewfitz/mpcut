import Darwin
import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class DraftRetentionTests: XCTestCase {
    private var directory: URL!
    private var trashFolder: URL!
    private let files = FileManager.default
    private let now = Date()

    override func setUpWithError() throws {
        let root = files.temporaryDirectory.appendingPathComponent("mpcut-retention-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("Drafts", isDirectory: true)
        trashFolder = root.appendingPathComponent("Trash", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? files.removeItem(at: directory.deletingLastPathComponent())
    }

    /// A fake Trash inside the test folder.
    private func trash(_ url: URL) throws {
        try files.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
    }

    private func run(days: Int, open: Set<URL> = []) -> DraftRetention.Outcome {
        DraftRetention.run(days: days, open: open, directory: directory, now: now, trash: trash)
    }

    @discardableResult
    private func draft(ageDays: Double, name: String = UUID().uuidString) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("Untitled.cut")
        try Data("{}".utf8).write(to: file)
        try files.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: file.path)
        return folder
    }

    private func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path) }

    func testZeroDaysDoesNothing() throws {
        let old = try draft(ageDays: 400)
        XCTAssertEqual(run(days: 0), .init())
        XCTAssertEqual(run(days: -1), .init())
        XCTAssertTrue(exists(old))
    }

    func testTrashesOnlyExpiredDrafts() throws {
        let old = try draft(ageDays: 10)
        let recent = try draft(ageDays: 2)
        let outcome = run(days: 7)
        XCTAssertEqual(outcome.trashed, [old])
        XCTAssertEqual(outcome.skipped, [recent: DraftRetention.recentReason])
        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(trashFolder.appendingPathComponent(old.lastPathComponent).appendingPathComponent("Untitled.cut")))
        XCTAssertTrue(exists(recent))
    }

    func testOpenDraftsSurviveWhetherNamedByFileOrFolder() throws {
        let byFile = try draft(ageDays: 30)
        let byFolder = try draft(ageDays: 30)
        // The temporary folder is reached through /var, which resolves to /private/var.
        let spelled = URL(fileURLWithPath: byFolder.resolvingSymlinksInPath().path)
        let outcome = run(days: 1, open: [byFile.appendingPathComponent("Untitled.cut"), spelled])
        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertEqual(outcome.skipped, [byFile: DraftRetention.openReason, byFolder: DraftRetention.openReason])
        XCTAssertTrue(exists(byFile))
        XCTAssertTrue(exists(byFolder))
    }

    func testLockedDraftSurvives() throws {
        let locked = try draft(ageDays: 30)
        let descriptor = open(locked.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { close(descriptor) }
        let outcome = run(days: 1)
        XCTAssertEqual(outcome.skipped, [locked: DraftRetention.lockedReason])
        XCTAssertTrue(exists(locked))
    }

    func testDraftReservedByProjectDraftSurvives() throws {
        let owner = ProjectDraft(directory: directory)
        try owner.write { try Data("{}".utf8).write(to: $0) }
        let document = try XCTUnwrap(owner.url)
        try files.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: document.path)
        let outcome = run(days: 1)
        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertEqual(outcome.skipped.values.first, DraftRetention.lockedReason)
        XCTAssertTrue(exists(document))
        owner.discard()
    }

    func testNeverTouchesJobsStagingOrForeignEntries() throws {
        let jobs = directory.appendingPathComponent(".transcript-jobs/\(UUID().uuidString)/record.json")
        try files.createDirectory(at: jobs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: jobs)
        try files.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: jobs.path)
        let foreign = directory.appendingPathComponent("Notes", isDirectory: true)
        try files.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: foreign.appendingPathComponent("Untitled.cut"))
        let empty = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: empty, withIntermediateDirectories: false)
        let outside = directory.deletingLastPathComponent().appendingPathComponent("Outside", isDirectory: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: outside.appendingPathComponent("Untitled.cut"))
        let linked = directory.appendingPathComponent(UUID().uuidString)
        try files.createSymbolicLink(at: linked, withDestinationURL: outside)

        let outcome = run(days: 1)
        XCTAssertTrue(outcome.trashed.isEmpty)
        for kept in [jobs, foreign, empty, outside.appendingPathComponent("Untitled.cut"), linked] {
            XCTAssertTrue(exists(kept) || (try? files.destinationOfSymbolicLink(atPath: kept.path)) != nil, kept.path)
        }
    }

    func testRecentStagingFileKeepsAnOldDraft() throws {
        let folder = try draft(ageDays: 30)
        let staged = folder.appendingPathComponent(".pending-\(UUID().uuidString).cut")
        try Data("{}".utf8).write(to: staged)
        let outcome = run(days: 7)
        XCTAssertEqual(outcome.skipped, [folder: DraftRetention.recentReason])
        XCTAssertTrue(exists(staged))
    }

    func testTrashFailureIsReported() throws {
        let old = try draft(ageDays: 30)
        let outcome = DraftRetention.run(days: 1, open: [], directory: directory, now: now) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertNotNil(outcome.skipped[old])
        XCTAssertTrue(exists(old))
    }
}
