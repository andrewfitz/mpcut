import Foundation
import XCTest
@testable import MPCutCore

final class SidecarCacheCleanerTests: XCTestCase {
    private func fixture(_ body: (URL, AnalysisSidecar) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try SidecarLocations.$storageDirectory.withValue(root.appendingPathComponent("preferences")) {
            let source = root.appendingPathComponent("A.mov")
            try Data([1, 2, 3]).write(to: source)
            try body(root, AnalysisSidecar(source: source))
        }
    }

    private func entry(_ store: AnalysisSidecar) throws -> SidecarCacheEntry {
        try XCTUnwrap(SidecarCacheCleaner.preview(sources: [store.source]).first { $0.url.lastPathComponent == store.url.lastPathComponent })
    }

    func testSelectiveClearKeepsTranscriptActivityNamedScenesOverridesAndUnknownSections() throws {
        try fixture { _, store in
            let retained = [AnalysisSidecar.viewNameSectionKey: Data(#"{"1":"Speaker"}"#.utf8),
                            AnalysisSidecar.sceneSectionKey: Data("scene boundaries".utf8),
                            AnalysisSidecar.sceneClockKey: Data("clock".utf8),
                            AnalysisSidecar.silenceThresholdOverridesKey: Data(#"{"1":-35}"#.utf8),
                            "transcript_recognition.v2.0.key": Data("recognition".utf8),
                            "transcript_activity.v1.0.key": Data("levels".utf8),
                            "waveform_peaks.v9.0": Data("future".utf8)]
            let disposable = ["waveform_peaks.v1.0": Data(repeating: 6, count: 25000),
                              "timeline_filmstrip.v1.0.4020.4040": Data([5]),
                              // Pause lists are rebuildable in the property-list and the packed layout alike.
                              "silence_pauses.v1.0.auto.3fe0000000000000": Data([8]),
                              "silence_pauses.v2.0.auto.3fe0000000000000": Data([9]),
                              "media_index_audio.v1": Data([7])]
            try store.save(retained.merging(disposable) { old, _ in old })
            let inspected = try entry(store)
            XCTAssertNil(inspected.issue)
            XCTAssertGreaterThan(inspected.rebuildableBytes, 0)
            XCTAssertTrue(inspected.retained.contains("Transcript results and activity"))
            XCTAssertTrue(inspected.retained.contains("Scene names and their reports"))
            let stale = SidecarClearEpoch.capture(sidecar: store.url)
            let result = SidecarCacheCleaner.clear([inspected])
            XCTAssertEqual(result.cleared, [inspected.url], String(describing: result.skipped))
            XCTAssertThrowsError(try stale.check())
            XCTAssertThrowsError(try store.save(["waveform_peaks.v1.0": Data([1])]))
            let after = try AnalysisSidecar(source: store.source)
            for (key, value) in retained { XCTAssertEqual(after.read(key), value) }
            for key in disposable.keys { XCTAssertNil(after.read(key)) }
            XCTAssertEqual(try entry(after).rebuildableBytes, 0)
            try after.save(["waveform_peaks.v1.0": Data([2])])
            XCTAssertEqual(after.read("waveform_peaks.v1.0"), Data([2]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    func testPaidRecognitionAndNamedSceneAreReusableAfterClearingAndReopening() throws {
        try fixture { root, _ in
            let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MPCutAppTests/Fixtures")
            let source = root.appendingPathComponent("scenes.mov")
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Pause-Quiet.mov"), to: source)
            let media = try CutEngine().inspectMulticamSource(source)
            let store = AnalysisSidecar(media: media)
            let full = try XCTUnwrap(SceneAnalysis.run(source, session: SceneScanSession()).report)
            try store.save(AnalysisSidecar.viewNameSections([1: "Interview"], for: full))
            let stream = try XCTUnwrap(media.audio.first?.stream.index)
            let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: media, streamIndex: stream))
            let key = String(repeating: "a", count: 64)
            let recognition = TranscriptRecognitionCache(sidecar: store, key: key, evidence: evidence, stream: stream)
            let levels = try transcriptActivityDocument(levels: [0.3], duration: 320, evidence: evidence)
            let result = Data("""
            {"version":1,"sample_rate":16000,"recognition_key":"\(key)","stream_evidence":"\(evidence)","duration_samples":320,"words":[],"activity":[]}
            """.utf8)
            try recognition.saveSidecar(.init(result: result, activity: levels), media: media, cancelled: { false })
            try store.save(["waveform_peaks.v1.0": Data(repeating: 8, count: 42)])
            let preview = try entry(store)
            let cleared = SidecarCacheCleaner.clear([preview])
            XCTAssertEqual(cleared.cleared, [preview.url], String(describing: cleared.skipped))
            let reopened = try AnalysisSidecar(source: source)
            XCTAssertNil(reopened.read("waveform_peaks.v1.0"))
            XCTAssertEqual(reopened.sceneReport()?.views.first?.name, "Interview")
            let warm = try SceneAnalysis.run(source, session: SceneScanSession())
            XCTAssertEqual(warm.state, .upToDate)
            let cached = TranscriptRecognitionCache(sidecar: reopened, key: key, evidence: evidence, stream: stream)
            let restored = try XCTUnwrap(cached.readSidecar(cancelled: { false }))
            XCTAssertEqual(restored.result, result)
            XCTAssertEqual(restored.activity, levels)
        }
    }

    func testWholeRemovalRequiresUnchangedPreviewAndLeavesOtherFilesAlone() throws {
        try fixture { _, store in
            try store.save(["waveform_peaks.v1.0": Data([1])])
            let oldPreview = try entry(store)
            try store.save(["custom": Data(repeating: 1, count: 4096)])
            XCTAssertFalse(SidecarCacheCleaner.clear([oldPreview], wholeSidecars: true).skipped.isEmpty)
            XCTAssertNotNil(store.read("custom"))
            let fresh = try entry(store)
            XCTAssertFalse(SidecarCacheCleaner.clear([fresh], wholeSidecars: true, protected: [store.url]).skipped.isEmpty)
            let result = SidecarCacheCleaner.clear([fresh], wholeSidecars: true)
            XCTAssertEqual(result.reclaimedBytes, fresh.bytes, String(describing: result.skipped))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.source.path))
            XCTAssertFalse(SidecarLocations.knownEntries().contains { $0.url == fresh.url })
        }
    }

    func testBusyReadersAndLiveLeasesAreSkippedAndReleasedCheckpointsSurvive() throws {
        try fixture { _, store in
            let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "test"))
            let live = try entry(store)
            XCTAssertNotNil(live.issue)
            XCTAssertFalse(SidecarCacheCleaner.clear([live], wholeSidecars: true).skipped.isEmpty)
            try store.commitSceneAttempt(claim, checkpoint: Data([2]), markerBatch: Data([3]),
                                         coveredThrough: 1, complete: false, release: true)
            try store.save(["waveform_peaks.v1.0": Data([9])])
            let paused = try entry(store)
            XCTAssertNil(paused.issue)
            do {
                let reader = try SidecarDatabase(store.url, writing: false)
                try reader.execute("BEGIN")
                _ = try reader.integer("SELECT count(*) FROM sections")
                let result = SidecarCacheCleaner.clear([paused], wholeSidecars: true)
                XCTAssertTrue(result.cleared.isEmpty)
                XCTAssertNotNil(result.skipped[paused.url])
                try reader.execute("ROLLBACK")
            }
            XCTAssertFalse(SidecarCacheCleaner.clear([paused]).cleared.isEmpty)
            let reopened = try AnalysisSidecar(source: store.source)
            XCTAssertEqual(reopened.sceneAttempt(claim)?.checkpoint, Data([2]))
            XCTAssertEqual(reopened.sceneAttempt(claim)?.markerBatches, [Data([3])])
        }
    }

    func testClearRebuildsCompletedUnnamedScenesAndRemovesTheirMarkers() throws {
        try fixture { _, store in
            let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "test"))
            try store.commitSceneAttempt(claim, checkpoint: Data([2]), markerBatch: Data([3]),
                                         coveredThrough: 1, complete: true)
            let preview = try entry(store)
            XCTAssertGreaterThan(preview.rebuildableBytes, 0)
            let result = SidecarCacheCleaner.clear([preview])
            XCTAssertEqual(result.cleared, [preview.url], String(describing: result.skipped))
            let reopened = try AnalysisSidecar(source: store.source)
            XCTAssertNil(reopened.sceneAttempt(scope: "full", completed: true))
            let db = try SidecarDatabase(store.url, writing: false)
            XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_markers"), 0)
            XCTAssertEqual(try db.integer("SELECT count(*) FROM scene_reports"), 0)
        }
    }

    func testUnexpectedDeleteTriggerCannotErasePreservedMetadata() throws {
        try fixture { _, store in
            try store.save([AnalysisSidecar.viewNameSectionKey: Data([1]), "waveform_peaks.v1.0": Data([2])])
            let db = try SidecarDatabase(store.url, writing: true)
            try db.execute("CREATE TRIGGER external_cleanup AFTER DELETE ON sections BEGIN DELETE FROM sections; END")
            let preview = try entry(store)
            let result = SidecarCacheCleaner.clear([preview])
            XCTAssertNotNil(result.skipped[preview.url])
            XCTAssertEqual(store.read(AnalysisSidecar.viewNameSectionKey), Data([1]))
            XCTAssertEqual(store.read("waveform_peaks.v1.0"), Data([2]))
        }
    }

    func testOpenReaderInAnotherProcessPreventsWholeSidecarRemoval() throws {
        try fixture { _, store in
            try store.save(["media_index_audio.v1": Data([1])])
            let preview = try entry(store)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-batch", "-bail", store.url.path]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            // The result is printed after SQLite takes its SHARED lock.
            input.fileHandleForWriting.write(Data("BEGIN; SELECT count(*) FROM sections;\n".utf8))
            let reply = output.fileHandleForReading.availableData
            XCTAssertFalse(reply.isEmpty)
            let busy = SidecarCacheCleaner.clear([preview], wholeSidecars: true)
            XCTAssertTrue(busy.cleared.isEmpty)
            XCTAssertNotNil(busy.skipped[preview.url])
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    func testExplicitFolderScanFindsLegacyAdjacentFilesButSkipsForeignDatabasesAndSymlinks() throws {
        try fixture { root, store in
            try store.save(["waveform_peaks.v1.0": Data([1])])
            SidecarLocations.forget([store.url])
            let unrelated = root.appendingPathComponent("foreign.mov")
            try Data([1]).write(to: unrelated)
            try Data("user file".utf8).write(to: unrelated.appendingPathExtension("cutdb"))
            let alias = root.appendingPathComponent("link.mov")
            try Data([2]).write(to: alias)
            try FileManager.default.createSymbolicLink(at: alias.appendingPathExtension("cutdb"), withDestinationURL: store.url)
            let entries = SidecarCacheCleaner.preview(scanning: [root])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.source.lastPathComponent, "A.mov")
            XCTAssertTrue(SidecarLocations.knownEntries().contains { $0.source.lastPathComponent == "A.mov" })
        }
    }

    func testExplicitScanRegistersManagedCacheForLaterFileOnlyReads() throws {
        try fixture { root, original in
            let folder = root.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let project = folder.appendingPathComponent("edit.cut")
            try SidecarLocations.setMode(.project)
            let cache = try SidecarLocations.$projectURL.withValue(project) {
                let store = try AnalysisSidecar(source: original.source)
                try store.save(["custom": Data([7])])
                return store.url
            }
            for wasOpened in [false, true] {
                let home = root.appendingPathComponent("fresh-\(wasOpened)")
                try SidecarLocations.$storageDirectory.withValue(home) {
                    let ordinary = SidecarCacheCleaner.preview(projects: [project])
                    XCTAssertEqual(ordinary.first?.url, cache)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
                    if wasOpened {
                        try SidecarLocations.$projectURL.withValue(project) {
                            XCTAssertEqual(try AnalysisSidecar(source: original.source).read("custom"), Data([7]))
                        }
                        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
                    }
                    let scanned = SidecarCacheCleaner.preview(scanning: [folder], sources: [], projects: [])
                    XCTAssertEqual(scanned.first?.url, cache)
                    let catalog = try SidecarDatabase(home.appendingPathComponent("locations.sqlite"), writing: false)
                    XCTAssertEqual(try catalog.integer("SELECT count(*) FROM locations"), 1)
                    let fileOnly = try AnalysisSidecar(source: original.source)
                    XCTAssertEqual(fileOnly.read("custom"), Data([7]))
                }
            }
        }
    }

    func testMisnamedAdjacentCacheForDifferentRecordingCannotBeRegisteredOrCleared() throws {
        try fixture { root, original in
            try original.save(["waveform_peaks.v1.0": Data([7])])
            for version in [4, 5] {
                let source = root.appendingPathComponent("wrong-\(version).mov")
                try Data([1, 2, 3]).write(to: source)
                let foreign = source.appendingPathExtension("cutdb")
                try FileManager.default.copyItem(at: original.url, to: foreign)
                if version == 4 {
                    let db = try SidecarDatabase(foreign, writing: true)
                    try db.execute("PRAGMA user_version=4")
                }
                let before = try Data(contentsOf: foreign)
                let scanned = SidecarCacheCleaner.preview(scanning: [root])
                XCTAssertFalse(scanned.contains { $0.url == foreign && $0.issue == nil })
                XCTAssertFalse(SidecarLocations.knownEntries().contains { $0.url == foreign })
                let opened = try XCTUnwrap(SidecarCacheCleaner.preview(sources: [source]).first { $0.url == foreign })
                XCTAssertNotNil(opened.issue)
                for whole in [false, true] {
                    let cleared = SidecarCacheCleaner.clear([opened], wholeSidecars: whole)
                    XCTAssertTrue(cleared.cleared.isEmpty)
                    XCTAssertNotNil(cleared.skipped[foreign])
                    XCTAssertEqual(try Data(contentsOf: foreign), before)
                }
            }
        }
    }

    func testReplacingMediaAfterPreviewPreventsAdjacentClear() throws {
        try fixture { root, store in
            try store.save(["waveform_peaks.v1.0": Data([7])])
            let preview = try entry(store)
            let saved = try Data(contentsOf: store.url)
            try FileManager.default.moveItem(at: store.source, to: root.appendingPathComponent("original.mov"))
            try Data([1, 2, 3]).write(to: store.source)
            for whole in [false, true] {
                let cleared = SidecarCacheCleaner.clear([preview], wholeSidecars: whole)
                XCTAssertNotNil(cleared.skipped[store.url])
                XCTAssertEqual(try Data(contentsOf: store.url), saved)
            }
        }
    }

    func testSelectedDiskCachesRemainDiscoverableAfterCatalogAndSourceAreRemoved() throws {
        try fixture { root, original in
            let disk = root.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            try SidecarLocations.chooseDisk(disk)
            try SidecarLocations.setMode(.disk)
            let store = try AnalysisSidecar(source: original.source)
            try store.save(["waveform_peaks.v1.0": Data([1])])
            SidecarLocations.forget([store.url])
            try FileManager.default.removeItem(at: original.source)
            XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
            let caches = SidecarCacheCleaner.preview()
            let found = try XCTUnwrap(caches.first)
            XCTAssertEqual(found.source.lastPathComponent, original.source.lastPathComponent)
            XCTAssertEqual(found.location, .disk)
            XCTAssertNil(found.issue)
            XCTAssertFalse(SidecarCacheCleaner.clear([found], wholeSidecars: true).cleared.isEmpty)
        }
    }

    func testCatalogEntryForOfflineDiskIsReportedAndReplacementDirectoryIsUntouched() throws {
        try fixture { root, original in
            let disk = root.appendingPathComponent("disk")
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            try SidecarLocations.chooseDisk(disk)
            try SidecarLocations.setMode(.disk)
            let store = try AnalysisSidecar(source: original.source)
            try store.save(["waveform_peaks.v1.0": Data([1])])
            let inspected = try entry(store)
            let offline = root.appendingPathComponent("disconnected")
            try FileManager.default.moveItem(at: disk, to: offline)
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            let after = SidecarCacheCleaner.preview()
            let missing = try XCTUnwrap(after.first { $0.url == inspected.url })
            XCTAssertNotNil(missing.issue)
            XCTAssertFalse(SidecarCacheCleaner.clear([inspected], wholeSidecars: true).skipped.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.path), [])
            try FileManager.default.removeItem(at: disk)
            try FileManager.default.moveItem(at: offline, to: disk)
            XCTAssertNotNil(try AnalysisSidecar(source: original.source).read("waveform_peaks.v1.0"))
        }
    }
}
