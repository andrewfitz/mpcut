import Foundation
import XCTest
@testable import MPCutCore

final class ProjectDiskRevisionTests: XCTestCase {
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
                _ = try edit.saveRevision(to: url, undo: [], redo: [], expected: expected)
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
