import Foundation
@testable import MPCutCore
import XCTest

final class SceneSidecarLocationTests: XCTestCase {
    func testFailedHandoffPreservesCheckpointAndFencesOriginalOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        try Data([1, 2, 3]).write(to: source)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("config")) {
            let original = try AnalysisSidecar(source: source)
            let first = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: "one",
                                                                 restart: true, owner: "first"))
            try original.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: Data([10]),
                                            coveredThrough: 1, complete: false)
            try SidecarLocations.setMode(.project)
            try SidecarLocations.$projectURL.withValue(root.appendingPathComponent("edit.cut")) {
                let target = try AnalysisSidecar(source: source)
                let path = try SidecarLocations(source: source).prepareDestination()
                try Data("occupied".utf8).write(to: path)
                XCTAssertThrowsError(try target.claimSceneAttempt(scope: "full", operationID: "two",
                                                                  restart: true, owner: "second"))
                XCTAssertThrowsError(try original.renewSceneAttempt(first))
                XCTAssertEqual(original.sceneAttempt(first)?.checkpoint, Data([1]))
                XCTAssertEqual(try Data(contentsOf: path), Data("occupied".utf8))
                let resumed = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: nil, restart: false,
                                                                       resume: true, owner: "resume"))
                XCTAssertEqual(resumed.attemptID, first.attemptID)
                XCTAssertGreaterThan(resumed.fence, first.fence)
                try FileManager.default.removeItem(at: path)
                let replacement = try XCTUnwrap(target.claimSceneAttempt(scope: "full", operationID: "two",
                                                                         restart: true, owner: "second"))
                XCTAssertEqual(replacement.database, target.url)
                XCTAssertThrowsError(try original.renewSceneAttempt(resumed))
                try target.commitSceneAttempt(replacement, checkpoint: Data([2]), markerBatch: Data([20]),
                                              coveredThrough: 2, complete: true)
                XCTAssertEqual(original.sceneAttempt(scope: "full", completed: true)?.markerBatches, [Data([20])])
            }
        }
    }

    func testBusyRevocationAndInterruptedFinalizationCannotDuplicateLeases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        try Data([1, 2, 3]).write(to: source)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("config")) {
            let original = try AnalysisSidecar(source: source)
            let first = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: "first", restart: true, owner: "a"))
            try original.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: Data([10]), coveredThrough: 1, complete: false)
            try SidecarLocations.setMode(.project)
            try SidecarLocations.$projectURL.withValue(root.appendingPathComponent("edit.cut")) {
                let target = try AnalysisSidecar(source: source)
                let oldReader = try SidecarDatabase(original.url, writing: false)
                try oldReader.execute("BEGIN")
                XCTAssertEqual(try oldReader.integer("SELECT count(*) FROM scene_attempts"), 1)
                let deadline = ContinuousClock.now + .milliseconds(200)
                XCTAssertThrowsError(try target.claimSceneAttempt(scope: "full", operationID: "restart", restart: true,
                                                                  owner: "b", cancelled: { .now >= deadline }))
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.url.path))
                try oldReader.execute("COMMIT")
                try original.renewSceneAttempt(first)

                // Cancel precisely after destination publication. This leaves the
                // old database's durable intent for the next process to resolve.
                let next = try XCTUnwrap(target.claimSceneAttempt(scope: "full", operationID: "restart", restart: true,
                                                                 owner: "b", cancelled: {
                    FileManager.default.fileExists(atPath: target.url.path)
                }))
                XCTAssertEqual(try oldReader.integer("SELECT count(*) FROM scene_attempts WHERE state = 0 AND expires = 0 AND owner IS NOT NULL"), 1)
                XCTAssertThrowsError(try original.renewSceneAttempt(first))
                let reopened = try AnalysisSidecar(source: source)
                try oldReader.execute("BEGIN")
                XCTAssertEqual(try oldReader.integer("SELECT count(*) FROM scene_attempts WHERE state = 0 AND expires > 0"), 0)
                XCTAssertNil(try reopened.claimSceneAttempt(scope: "full", operationID: nil, restart: false, resume: true, owner: "c"))
                let replay = try XCTUnwrap(reopened.claimSceneAttempt(scope: "full", operationID: "first", restart: true, owner: "c"))
                XCTAssertTrue(replay.superseded)
                try oldReader.execute("COMMIT")
                XCTAssertNil(try reopened.claimSceneAttempt(scope: "full", operationID: nil, restart: false, resume: true, owner: "c"))
                XCTAssertEqual(try oldReader.integer("SELECT count(*) FROM scene_attempts WHERE state = 0"), 0)
                try reopened.renewSceneAttempt(next)
            }
        }
    }

    func testRestartRecoveryWithOnlyTheCommittedRevocationRestoresReleasedWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        try Data([1, 2, 3]).write(to: source)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("config")) {
            let original = try AnalysisSidecar(source: source)
            let first = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: nil,
                                                                 restart: false, owner: "original"))
            try original.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: Data([10]), coveredThrough: 1, complete: false)
            try SidecarLocations.setMode(.project)
            try SidecarLocations.$projectURL.withValue(root.appendingPathComponent("edit.cut")) {
                let target = try AnalysisSidecar(source: source)
                _ = try XCTUnwrap(target.claimSceneAttempt(scope: "full", operationID: "restart", restart: true,
                                                          owner: "replacement", cancelled: {
                    FileManager.default.fileExists(atPath: target.url.path)
                }))
                // Reconstruct a crash between the two commits: only the precursor's
                // committed revocation and its checkpoint survived.
                try FileManager.default.removeItem(at: target.url)
                let resumed = try XCTUnwrap(target.claimSceneAttempt(scope: "full", operationID: nil,
                                                                     restart: false, resume: true, owner: "recover"))
                XCTAssertEqual(resumed.attemptID, first.attemptID)
                XCTAssertGreaterThan(resumed.fence, first.fence)
                XCTAssertEqual(target.sceneAttempt(resumed)?.markerBatches, [Data([10])])
                XCTAssertThrowsError(try original.renewSceneAttempt(first))
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.url.path))
            }
        }
    }

    func testExclusiveLockCannotHideAnActiveLeaseDuringAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        try Data([1, 2, 3]).write(to: source)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("config")) {
            let original = try AnalysisSidecar(source: source)
            let first = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "first"))
            let registration = SceneLeaseRegistration(store: original, scope: "full")
            let receipt = try XCTUnwrap(try registration.read())
            // A database from an earlier release can already contain a lease.
            registration.remove()
            try SidecarLocations.setMode(.project)
            try SidecarLocations.$projectURL.withValue(root.appendingPathComponent("edit.cut")) {
                let project = try AnalysisSidecar(source: source)
                let locker = try SidecarDatabase(original.url, writing: true)
                try locker.execute("BEGIN EXCLUSIVE")
                XCTAssertThrowsError(try project.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "second"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: project.url.path))
                try locker.execute("COMMIT")
                try registration.write(receipt)
                try original.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: nil, coveredThrough: 1, complete: true)
                XCTAssertEqual(project.sceneAttempt(scope: "full", completed: true)?.checkpoint, Data([1]))
            }
        }
    }

    func testUnavailableActiveLeaseAndOldWriterAfterRemount() throws {
        try checkOfflineTakeover(remountBeforeCompletion: true)
        try checkOfflineTakeover(remountBeforeCompletion: false)
        try checkOfflineTakeover(remountBeforeCompletion: false, remountDuringAdmission: true)
    }

    private func checkOfflineTakeover(remountBeforeCompletion: Bool, remountDuringAdmission: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let disk = root.appendingPathComponent("disk", isDirectory: true)
        let offline = root.appendingPathComponent("offline", isDirectory: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        try Data([1, 2, 3]).write(to: source)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("config")) {
            try SidecarLocations.chooseDisk(disk, selecting: true)
            let original = try AnalysisSidecar(source: source)
            let first = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: "original", restart: true, owner: "first"))
            try original.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: nil, coveredThrough: 1, complete: false)
            try SidecarLocations.setMode(.media)
            try FileManager.default.moveItem(at: disk, to: offline)
            let adjacent = try AnalysisSidecar(source: source)
            XCTAssertThrowsError(try adjacent.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "second"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: adjacent.url.path))
            // Simulate the local lease timing out. The offline database still
            // has the original expiry, so its ordinary SQLite fence would pass.
            let registration = SceneLeaseRegistration(store: original, scope: "full")
            let prior = try XCTUnwrap(try registration.read())
            try registration.write(.init(entry: prior.entry, attempt: prior.attempt, owner: prior.owner, fence: prior.fence, expires: 0))
            var movedDuringAdmission = false
            let replacement = try XCTUnwrap(adjacent.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "second", cancelled: {
                if remountDuringAdmission && !movedDuringAdmission,
                   let files = try? FileManager.default.contentsOfDirectory(atPath: root.path),
                   files.contains(where: { $0.hasPrefix(".mpcut-") }) {
                    // Destination staging starts after the search for owners.
                    do {
                        try FileManager.default.moveItem(at: offline, to: disk)
                        movedDuringAdmission = true
                    } catch { XCTFail("Could not remount the test cache disk: \(error)") }
                }
                return false
            }))
            XCTAssertEqual(movedDuringAdmission, remountDuringAdmission)
            if remountBeforeCompletion {
                try FileManager.default.moveItem(at: offline, to: disk)
                XCTAssertThrowsError(try original.renewSceneAttempt(first))
                let replay = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: "original", restart: true, owner: "first"))
                XCTAssertTrue(replay.superseded)
                XCTAssertThrowsError(try original.commitSceneAttempt(first, checkpoint: Data([9]), markerBatch: nil, coveredThrough: 9, complete: true))
            }
            try adjacent.commitSceneAttempt(replacement, checkpoint: Data([2]), markerBatch: nil, coveredThrough: 2, complete: true)
            if !remountBeforeCompletion && !remountDuringAdmission {
                let extra = try XCTUnwrap(adjacent.claimSceneAttempt(scope: "full", operationID: "while-offline", restart: true, owner: "extra"))
                try adjacent.releaseSceneAttempt(extra)
                try FileManager.default.moveItem(at: offline, to: disk)
            }
            let reopened = try AnalysisSidecar(source: source)
            let replay = try XCTUnwrap(reopened.claimSceneAttempt(scope: "full", operationID: "original", restart: true, owner: "first"))
            XCTAssertTrue(replay.superseded)
            XCTAssertThrowsError(try reopened.renewSceneAttempt(first))
            XCTAssertEqual(reopened.sceneAttempt(scope: "full", completed: true)?.checkpoint, Data([2]))
            let latest = try XCTUnwrap(reopened.claimSceneAttempt(scope: "full", operationID: "fresh", restart: true, owner: "third"))
            XCTAssertFalse(latest.superseded)
            XCTAssertEqual(latest.database, adjacent.url)
            try reopened.releaseSceneAttempt(latest)
            XCTAssertNil(try registration.read())
            let anotherWindow = try AnalysisSidecar(source: source)
            let late = try XCTUnwrap(anotherWindow.claimSceneAttempt(scope: "full", operationID: "original", restart: true, owner: "first"))
            XCTAssertTrue(late.superseded)
        }
    }

    func testConcurrentProjectClaimsChooseOneDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let source = root.appendingPathComponent("camera.mov")
        try Data([1, 2, 3]).write(to: source)
        let projects = try (0..<2).map { index -> URL in
            let directory = root.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("edit.cut")
        }
        try SidecarLocations.$storageDirectory.withValue(config) { try SidecarLocations.setMode(.project) }
        let lock = NSLock()
        var claims: [SceneAttemptClaim] = [], errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: projects.count) { index in
            do {
                let claim = try SidecarLocations.$storageDirectory.withValue(config) {
                    try SidecarLocations.$projectURL.withValue(projects[index]) {
                        try AnalysisSidecar(source: source).claimSceneAttempt(scope: "full", operationID: nil,
                                                                            restart: false, owner: "scan-\(index)")
                    }
                }
                if let claim { lock.withLock { claims.append(claim) } }
            } catch { lock.withLock { errors.append(error) } }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(claims.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathExtension("cutdb").path))
        try SidecarLocations.$storageDirectory.withValue(config) {
            for project in projects {
                try SidecarLocations.$projectURL.withValue(project) {
                    let reader = try AnalysisSidecar(source: source)
                    XCTAssertEqual(reader.persistedSceneAttempts().filter { $0.state == "running" }.count, 1)
                    XCTAssertNil(try reader.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "follower"))
                }
            }
        }
    }

    func testActiveClaimStaysAtOriginalDatabaseAfterDestinationChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        try Data([1, 2, 3]).write(to: source)
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("config")) {
            try SidecarLocations.$projectURL.withValue(root.appendingPathComponent("example.cut")) {
                SidecarLocations.mode = .media
                let original = try AnalysisSidecar(source: source)
                let first = try XCTUnwrap(original.claimSceneAttempt(scope: "full", operationID: nil,
                                                                     restart: false, owner: "first"))
                try original.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: Data([10]),
                                                coveredThrough: 1, complete: false)
                SidecarLocations.mode = .project
                let project = try AnalysisSidecar(source: source)
                try project.save(["other": Data([4])])
                XCTAssertNotEqual(original.url, project.url)
                let db = try SidecarDatabase(project.url, writing: false)
                XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_attempts WHERE state = 0"), 0)
                XCTAssertNil(try project.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "second"))
                XCTAssertEqual(project.sceneAttempt(scope: "full", completed: false)?.checkpoint, Data([1]))
                try project.renewSceneAttempt(first)
                try project.releaseSceneAttempt(first)
                let resumed = try XCTUnwrap(project.claimSceneAttempt(scope: "full", operationID: nil,
                                                                      restart: false, resume: true, owner: "second"))
                XCTAssertEqual(resumed.attemptID, first.attemptID)
                XCTAssertGreaterThan(resumed.fence, first.fence)
                XCTAssertThrowsError(try original.renewSceneAttempt(first))
                try project.commitSceneAttempt(resumed, checkpoint: Data([2]), markerBatch: Data([20]),
                                               coveredThrough: 2, complete: true)
                XCTAssertEqual(project.sceneAttempt(scope: "full", completed: true)?.markerBatches, [Data([10]), Data([20])])
                XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_attempts"), 0)
                // A later ordinary save imports the completed scope as a unit
                // into the existing destination. It can reopen independently.
                try project.save(["other": Data([5])])
                XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_attempts WHERE state = 1"), 1)
                try FileManager.default.removeItem(at: original.url)
                XCTAssertEqual(project.sceneAttempt(scope: "full", completed: true)?.markerBatches, [Data([10]), Data([20])])
            }
        }
    }
}
