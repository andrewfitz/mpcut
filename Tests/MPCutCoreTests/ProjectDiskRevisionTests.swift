import Foundation
import XCTest
@testable import MPCutCore

final class ProjectDiskRevisionTests: XCTestCase {
    func testRevisionPreservesExternalSaveDuringPublicationPreparation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Project.cut")
        let externalURL = directory.appendingPathComponent("External.cut")
        try CutProject.sequence([]).save(to: url)
        let revision = try XCTUnwrap(CutProjectMedia.load(from: url).diskRevision)
        let external = CutProject.sequence([.init(id: "other", file: "other.mov", from: .zero, to: .init(numerator: 1))])
        try external.save(to: externalURL)
        let data = try Data(contentsOf: externalURL)

        let edit = CutProject.sequence([.init(id: "mine", file: "mine.mov", from: .zero, to: .init(numerator: 1))])
        XCTAssertThrowsError(try edit.saveRevision(to: url, undo: [], redo: [], mediaSnapshot: .empty, expected: revision) {
            let staged = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".mpcut-") }
            XCTAssertEqual(staged.count, 1)
            if let name = staged.first {
                XCTAssertEqual(try CutProject.load(from: directory.appendingPathComponent(name)), edit)
            }
            try data.write(to: url, options: .atomic)
        }) {
            XCTAssertEqual(($0 as? CutError)?.code, "project_save_conflict")
        }
        XCTAssertEqual(try CutProject.load(from: url), external)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["Project.cut", "External.cut"]))
    }

    func testReplacementPreservesDestinationPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Project.cut")
        try CutProject.sequence([]).save(to: url)
        try files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let revision = try XCTUnwrap(CutProjectMedia.load(from: url).diskRevision)
        let edit = CutProject.sequence([.init(id: "mine", file: "mine.mov", from: .zero, to: .init(numerator: 1))])

        _ = try edit.saveRevision(to: url, undo: [], redo: [], mediaSnapshot: .empty, expected: revision)
        XCTAssertEqual(try files.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try CutProject.load(from: url), edit)
    }

    func testUnversionedSaveWaitsForRevisionPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Project.cut")
        let original = CutProject.sequence([])
        try original.save(to: url)
        let revision = try XCTUnwrap(CutProjectMedia.load(from: url).diskRevision)
        let first = CutProject.sequence([.init(id: "first", file: "first.mov", from: .zero, to: .init(numerator: 1))])
        let second = CutProject.sequence([.init(id: "second", file: "second.mov", from: .zero, to: .init(numerator: 1))])
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        _ = try first.saveRevision(to: url, undo: [], redo: [], mediaSnapshot: .empty, expected: revision) {
            DispatchQueue.global().async {
                started.signal()
                do {
                    try second.save(to: url)
                } catch {
                    XCTFail("Ordinary save failed: \(error)")
                }
                finished.signal()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 0.25), .timedOut)
            XCTAssertEqual(try CutProject.load(from: url), original)
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try CutProject.load(from: url), second)
    }

    func testRevisionResolvesParentTraversalAfterDirectorySymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileManager.default
        let physical = directory.appendingPathComponent("physical")
        let child = physical.appendingPathComponent("child")
        try files.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        try files.createSymbolicLink(at: directory.appendingPathComponent("shortcut"), withDestinationURL: child)
        let traversal = directory.appendingPathComponent("shortcut/../Project.cut")
        let project = physical.appendingPathComponent("Project.cut")
        let lexical = directory.appendingPathComponent("Project.cut")
        let original = CutProject.sequence([])
        try original.save(to: traversal)

        let opened = try CutProjectMedia.load(from: traversal)
        let revision = try XCTUnwrap(opened.diskRevision)
        XCTAssertFalse(files.fileExists(atPath: lexical.path))
        XCTAssertTrue(revision.matchesDestination(project))
        XCTAssertFalse(revision.matchesDestination(lexical))

        let edited = CutProject.sequence([.init(id: "clip", file: "offline.mov", from: .zero, to: .init(numerator: 1))])
        _ = try edited.saveRevision(to: traversal, undo: [], redo: [], mediaSnapshot: .empty, expected: revision)
        XCTAssertEqual(try CutProject.load(from: project), edited)
        XCTAssertFalse(files.fileExists(atPath: lexical.path))
    }

    func testConcurrentSavesThroughProjectAndSymlinkPublishExactlyOneRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Project.cut")
        let alias = directory.appendingPathComponent("Alias.cut")
        try CutProject.sequence([]).save(to: project)
        try files.createSymbolicLink(at: alias, withDestinationURL: project)
        let first = try XCTUnwrap(CutProjectMedia.load(from: project).diskRevision)
        let second = try XCTUnwrap(CutProjectMedia.load(from: alias).diskRevision)
        XCTAssertTrue(second.matchesDestination(project))
        XCTAssertTrue(first.matchesDestination(alias))
        let attempts = [(project, first), (alias, second)]
        let lock = NSLock()
        var outcomes: [String] = []

        DispatchQueue.concurrentPerform(iterations: attempts.count) { index in
            let (url, expected) = attempts[index]
            let edit = CutProject.sequence([
                .init(id: "edit-\(index)", file: "offline.mov", from: .zero, to: .init(numerator: 1))
            ])
            let outcome: String
            do {
                _ = try edit.saveRevision(to: url, undo: [], redo: [], mediaSnapshot: .empty, expected: expected)
                outcome = "saved"
            } catch {
                outcome = (error as? CutError)?.code ?? error.localizedDescription
            }
            lock.withLock { outcomes.append(outcome) }
        }
        XCTAssertEqual(outcomes.sorted(), ["project_save_conflict", "saved"])
        XCTAssertEqual(try CutProject.load(from: project), try CutProject.load(from: alias))
        XCTAssertNoThrow(try files.destinationOfSymbolicLink(atPath: alias.path))
    }
}
