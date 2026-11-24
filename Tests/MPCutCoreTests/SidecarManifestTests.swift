import Foundation
@testable import MPCutCore
import XCTest

final class SidecarManifestTests: XCTestCase {
    func testUnsupportedVersionsPreserveAuthoredDataAndRejectWrites() throws {
        try withStore { store in
            try store.save([AnalysisSidecar.viewNameSectionKey: Data(#"{"1":"Wide shot"}"#.utf8)])
            // Formats 1 and 2 are replaced on write; SidecarLegacyFormatTests covers them.
            for version in [100] {
                do {
                    let db = try SidecarDatabase(store.url, writing: true)
                    try db.execute("PRAGMA user_version = \(version)")
                }
                let before = try Data(contentsOf: store.url)
                XCTAssertEqual(store.status(), "unsupported")
                XCTAssertTrue(store.persistedGenerations().isEmpty)
                XCTAssertNil(store.read(AnalysisSidecar.viewNameSectionKey))
                store.saveAutomatically(["waveform_peaks.v1.0": Data([1])])
                XCTAssertThrowsError(try store.save(["waveform_peaks.v1.0": Data([1])])) {
                    XCTAssertEqual(($0 as? CutError)?.code, "unsupported_sidecar")
                }
                XCTAssertEqual(try Data(contentsOf: store.url), before)
            }
        }
    }

    func testIncrementalCancellationAndTakeover() throws {
        try withStore { store in
            let first = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "a"))
            try store.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: Data([10]), coveredThrough: 1,
                                         complete: false)
            XCTAssertNil(try store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "b"))
            var checks = 0
            XCTAssertThrowsError(try store.commitSceneAttempt(first, checkpoint: Data([2]), markerBatch: Data([20]),
                                                               coveredThrough: 2, complete: false, cancelled: {
                checks += 1
                return checks > 1
            }))
            let reopened = try AnalysisSidecar(source: store.source)
            XCTAssertEqual(reopened.sceneAttempt(first)?.checkpoint, Data([1]))
            XCTAssertEqual(reopened.sceneAttempt(first)?.markerBatches, [Data([10])])
            XCTAssertNil(reopened.sceneAttempt(scope: "full", completed: false, afterCoverage: 1,
                                               followedAttempt: first.attemptID, followedFence: first.fence))
            do {
                let db = try SidecarDatabase(store.url, writing: true)
                try db.update("UPDATE scene_attempts SET expires = 0 WHERE id = ?", [first.attemptID])
            }
            let next = try XCTUnwrap(reopened.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "b"))
            XCTAssertEqual(first.attemptID, next.attemptID)
            XCTAssertGreaterThan(next.fence, first.fence)
            XCTAssertEqual(reopened.sceneAttempt(scope: "full", completed: false, afterCoverage: 1,
                                                 followedAttempt: first.attemptID, followedFence: first.fence)?.fence,
                           next.fence)
            XCTAssertThrowsError(try store.commitSceneAttempt(first, checkpoint: Data(), markerBatch: Data([30]),
                                                               coveredThrough: 3, complete: true))
            try reopened.commitSceneAttempt(next, checkpoint: Data([2]), markerBatch: Data([20]), coveredThrough: 2,
                                            complete: true, sections: ["scenes_boundaries.v1": Data([2])])
            XCTAssertEqual(reopened.sceneAttempt(scope: "full", completed: true)?.markerBatches, [Data([10]), Data([20])])
            XCTAssertEqual(reopened.read("scenes_boundaries.v1"), Data([2]))
        }
    }

    func testCanonicalSceneRepairReplacesInvalidSectionAndRejectsStaleCheckpoint() throws {
        try withStore { store in
            let key = AnalysisSidecar.sceneSectionKey
            let invalid = Data("{}".utf8)
            let checkpoint = Data([1])
            let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil,
                                                               restart: false, owner: "owner"))
            try store.commitSceneAttempt(claim, checkpoint: checkpoint, markerBatch: nil,
                                         coveredThrough: 2, complete: true, sections: [key: invalid])
            let replacement = Data("""
                {"origin":{"numerator":0,"denominator":1},"duration":{"numerator":2,"denominator":1},
                 "time_base":{"numerator":1,"denominator":1},"markers":[{"pts":0,"view":1}]}
                """.utf8)
            XCTAssertNil(store.sceneReport())
            XCTAssertThrowsError(try store.repairCanonicalSceneReport(scope: "full", expectedCheckpoint: Data([2]),
                                                                      sections: [key: replacement]))
            XCTAssertEqual(store.read(key), invalid)
            try store.repairCanonicalSceneReport(scope: "full", expectedCheckpoint: checkpoint, sections: [key: replacement])
            XCTAssertEqual(store.sceneReport()?.scenes.count, 1)
            XCTAssertThrowsError(try store.repairCanonicalSceneReport(scope: "full", expectedCheckpoint: checkpoint,
                                                                      sections: [key: replacement]))
        }
    }

    func testRestartReplayAndRefreshGenerationCompareAndSwap() throws {
        try withStore { store in
            let originalEvidence = Data([0])
            try store.save(["media_refresh_evidence.v1": originalEvidence, "waveform_peaks.v1.1": Data([1]),
                            "waveform_peaks.v1.2": Data([2]), "silence_pauses.v1.2": Data([2]),
                            "silence_threshold_overrides_db.v1": JSONEncoder().encode([1: -45.0, 2: -50.0])])
            let first = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "a"))
            try store.commitSceneAttempt(first, checkpoint: Data([1]), markerBatch: nil, coveredThrough: 9,
                                         complete: true, sections: ["scenes_boundaries.v1": Data([3])])
            let replacement = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: "replace", restart: true, owner: "b"))
            try store.commitSceneAttempt(replacement, checkpoint: Data([2]), markerBatch: Data([3]), coveredThrough: 1,
                                         complete: false, release: true)
            XCTAssertEqual(store.sceneAttempt(scope: "full", completed: true)?.checkpoint, Data([1]))
            XCTAssertEqual(store.sceneAttempt(scope: "full", completed: false)?.checkpoint, Data([2]))
            let replay = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: "replace", restart: true, owner: "c"))
            XCTAssertEqual(replay.attemptID, replacement.attemptID)
            let currentEvidence = Data([1])
            try store.refreshGeneration(evidence: currentEvidence, preserving: ["waveform_peaks.v1.1", "scenes_boundaries.v1"],
                                        expectedEvidence: originalEvidence, force: true, preservingScenes: true,
                                        preservingThresholdStreams: [2])
            XCTAssertThrowsError(try store.commitSceneAttempt(replay, checkpoint: Data([3]), markerBatch: nil,
                                                               coveredThrough: 10, complete: true))
            XCTAssertThrowsError(try store.refreshGeneration(evidence: Data([2]), preserving: [],
                                                              expectedEvidence: originalEvidence, force: true))
            XCTAssertEqual(store.persistedGenerations().map(\.reason), ["content_changed", "initial"])
            XCTAssertEqual(store.read("waveform_peaks.v1.1"), Data([1]))
            XCTAssertNil(store.read("waveform_peaks.v1.2"))
            XCTAssertNil(store.readArchived("waveform_peaks.v1.2", generation: 1))
            XCTAssertEqual(store.readArchived("silence_pauses.v1.2", generation: 1), Data([2]))
            let overrides = try XCTUnwrap(store.read("silence_threshold_overrides_db.v1"))
            XCTAssertEqual(try JSONDecoder().decode([Int: Double].self, from: overrides), [2: -50.0])
            XCTAssertNil(store.sceneAttempt(scope: "full", completed: false))
            XCTAssertEqual(store.sceneAttempt(scope: "full", completed: true)?.checkpoint, Data([1]))
            XCTAssertEqual(store.persistedSceneAttempts().filter(\.current).map(\.id), [first.attemptID])
        }
    }

    func testInventoryReadsOnlyCommittedGenerationsAndSections() throws {
        try withStore { store in
            try store.save(["before": Data()])
            let writer = try SidecarDatabase(store.url, writing: true)
            try writer.execute("BEGIN IMMEDIATE")
            try writer.execute("INSERT INTO source_generations(stamp, reason) SELECT stamp, 'content_changed' FROM source")
            try writer.execute("DELETE FROM sections WHERE name = 'before'")

            let before = AnalysisSidecar.inventorySnapshot(source: store.source)
            XCTAssertEqual(before.status, "current")
            XCTAssertEqual(before.generations.first?.id, 1)
            XCTAssertEqual(before.sections, ["before"])
            try writer.execute("COMMIT")
            let after = AnalysisSidecar.inventorySnapshot(source: store.source)
            XCTAssertEqual(after.generations.first?.id, 2)
            XCTAssertTrue(after.sections.isEmpty)

            try Data([1, 2, 3, 4, 5]).write(to: store.source)
            let stale = AnalysisSidecar.inventorySnapshot(source: store.source)
            XCTAssertEqual(stale.status, "stale")
            XCTAssertFalse(stale.generations.contains(where: \.current))
        }
    }

    func testMarkerIntegrityAndOfflineInspection() throws {
        try withStore { store in
            let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "owner"))
            try store.commitSceneAttempt(claim, checkpoint: Data([1]), markerBatch: Data([2]), coveredThrough: 2,
                                         complete: false, release: true)
            do {
                let db = try SidecarDatabase(store.url, writing: true)
                try db.update("DELETE FROM scene_markers WHERE attempt = ?", [claim.attemptID])
            }
            XCTAssertNil(store.sceneAttempt(scope: "full", completed: false))

            try FileManager.default.removeItem(at: store.source)
            let inventory = AnalysisSidecar.offlineInventory(source: store.source)
            XCTAssertEqual(inventory.status, "offline")
            XCTAssertEqual(inventory.generations.first?.current, false)
            XCTAssertEqual(inventory.attempts.first?.current, false)
            XCTAssertEqual(inventory.attempts.first?.coveredThrough, 2)
        }
    }

    func testRepeatedRefreshAndRestartReclaimPayloads() throws {
        try withStore { store in
            let bytes = Data(repeating: 1, count: 512 * 1024)
            try store.save(["media_refresh_evidence.v1": Data([0]), "silence_pauses.v1.1": bytes, "waveform_peaks.v1.1": bytes])
            for i in UInt8(1)...6 {
                try store.refreshGeneration(evidence: Data([i]), preserving: [], expectedEvidence: Data([i - 1]),
                                            force: true, sections: ["silence_pauses.v1.1": bytes, "waveform_peaks.v1.1": bytes])
            }
            XCTAssertNil(store.readArchived("silence_pauses.v1.1", generation: 1))
            XCTAssertEqual(store.readArchived("silence_pauses.v1.1", generation: 4), bytes)
            XCTAssertNil(store.readArchived("waveform_peaks.v1.1", generation: 4))
            for i in 0..<6 {
                let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: "operation-\(i)",
                                                                  restart: true, owner: "owner"))
                try store.commitSceneAttempt(claim, checkpoint: Data([1]), markerBatch: bytes,
                                             coveredThrough: 2, complete: true)
            }
            let replay = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: "operation-0",
                                                               restart: true, owner: "other"))
            XCTAssertTrue(replay.superseded)
            let db = try SidecarDatabase(store.url, writing: false)
            XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_markers"), 3)
            XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_attempts"), 6)
            let metadata = try FileManager.default.attributesOfItem(atPath: store.url.path)
            let size = try XCTUnwrap(metadata[.size] as? NSNumber)
            XCTAssertLessThan(size.intValue, bytes.count * 9)
        }
    }

    func testExplicitSaveOfRefreshedIndexDoesNotBlessLegacySameStampAnalysis() throws {
        try withStore { store in
            try store.save(["silence_pauses.v1.1": Data([42]), "media_index.v1": Data([1])])
            var evidence = MediaRefreshEvidence(identity: store.identity, format: "mov", origin: .zero,
                                                duration: RationalTime(numerator: 1), videoIndex: -1, streams: [],
                                                audio: [], indexIssues: [],
                                                native: UnsafeBufferPointer(start: nil, count: 0))
            evidence.reviewStreams = []
            evidence.pictureNeedsReview = true
            try store.save(["media_index.v1": Data([2]), MediaRefreshEvidence.sectionKey: evidence.encoded()])
            XCTAssertEqual(store.read("media_index.v1"), Data([2]))
            XCTAssertNil(store.read("silence_pauses.v1.1"))
            XCTAssertEqual(store.readArchived("silence_pauses.v1.1", generation: 1), Data([42]))
            XCTAssertEqual(store.persistedGenerations().first?.reason, "content_changed")
            evidence.reviewStreams = nil
            evidence.pictureNeedsReview = nil
            try store.save(["media_index.v1": Data([3]), MediaRefreshEvidence.sectionKey: evidence.encoded()])
            XCTAssertEqual(MediaRefreshEvidence.decode(store.read(MediaRefreshEvidence.sectionKey))?.pictureNeedsReview, true)
            evidence.reviewStreams = []
            evidence.pictureNeedsReview = false
            try store.save(["media_index.v1": Data([4]), MediaRefreshEvidence.sectionKey: evidence.encoded()])
            XCTAssertEqual(MediaRefreshEvidence.decode(store.read(MediaRefreshEvidence.sectionKey))?.pictureNeedsReview, true)
            XCTAssertEqual(store.persistedGenerations().count, 2)
        }
    }

    private func withStore(_ test: (AnalysisSidecar) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mov")
        try Data([0]).write(to: source)
        try test(AnalysisSidecar(source: source))
    }
}
