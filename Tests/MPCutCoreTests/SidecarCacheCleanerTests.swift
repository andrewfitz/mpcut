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

    func testScopedPreviewOmitsOtherFoldersAndIssuesTokensOnlyForCurrentEligibleCopies() throws {
        try fixture { root, store in
            let outside = root.appendingPathComponent("recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let source = outside.appendingPathComponent("B.mov")
            try Data([4, 5, 6]).write(to: source)
            let adjacent = try AnalysisSidecar(source: source)
            try store.save(["waveform_peaks.v1.0": Data([1])])
            try adjacent.save(["waveform_peaks.v1.0": Data([2])])

            func preview(protected: Set<URL> = []) -> [SidecarCacheEntry] {
                SidecarCacheCleaner.preview(scanning: [outside], protected: protected, scannedOnly: true)
            }
            let initial = preview()
            let token = try XCTUnwrap(initial.first?.clearToken)
            XCTAssertEqual(initial.map(\.url.lastPathComponent), [adjacent.url.lastPathComponent])
            XCTAssertEqual(preview().first?.clearToken, token)

            let blocked = try XCTUnwrap(preview(protected: [adjacent.url]).first)
            XCTAssertNil(blocked.clearToken)
            XCTAssertNotNil(blocked.issue)
            try adjacent.save(["new_section": Data(repeating: 3, count: 4_096)])
            XCTAssertNotEqual(try XCTUnwrap(preview().first?.clearToken), token)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: adjacent.url.path))
        }
    }

    func testClearRemovesWholeCacheAndRejectsWritesFromPreviousEpoch() throws {
        try fixture { _, store in
            let key = "waveform_peaks.v1.0"
            try store.save([key: Data(repeating: 6, count: 25000)])
            let inspected = try entry(store)
            let usage = try XCTUnwrap(inspected.usage)
            XCTAssertGreaterThan(try XCTUnwrap(usage.sectionBytes[key]), 0)
            XCTAssertEqual(usage.databaseBytes, usage.sectionBytes.values.reduce(0, +) + usage.sqliteOverheadBytes)
            XCTAssertGreaterThan(inspected.bytes, 0)
            let stale = SidecarClearEpoch.capture(sidecar: store.url)
            let result = SidecarCacheCleaner.clear([inspected])
            XCTAssertEqual(result.cleared, [inspected.url], String(describing: result.skipped))
            XCTAssertThrowsError(try stale.check())
            XCTAssertThrowsError(try store.save([key: Data([1])]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
            let reopened = try AnalysisSidecar(source: store.source)
            XCTAssertNil(reopened.read(key))
            try reopened.save([key: Data([2])])
            XCTAssertEqual(reopened.read(key), Data([2]))
        }
    }

    func testWholeRemovalRequiresUnchangedPreviewAndLeavesOtherFilesAlone() throws {
        try fixture { _, store in
            try store.save(["waveform_peaks.v1.0": Data([1])])
            let oldPreview = try entry(store)
            try store.save(["custom": Data(repeating: 1, count: 4096)])
            XCTAssertFalse(SidecarCacheCleaner.clear([oldPreview]).skipped.isEmpty)
            XCTAssertNotNil(store.read("custom"))
            let fresh = try entry(store)
            XCTAssertFalse(SidecarCacheCleaner.clear([fresh], protected: [store.url]).skipped.isEmpty)
            let result = SidecarCacheCleaner.clear([fresh])
            XCTAssertEqual(result.reclaimedBytes, fresh.bytes, String(describing: result.skipped))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.source.path))
            XCTAssertFalse(SidecarLocations.knownEntries().contains { $0.url == fresh.url })
        }
    }

    func testBusyReadersAndLiveLeasesAreSkippedAndReleasedCheckpointsCanBeCleared() throws {
        try fixture { _, store in
            let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "test"))
            let live = try entry(store)
            XCTAssertNotNil(live.issue)
            XCTAssertFalse(SidecarCacheCleaner.clear([live]).skipped.isEmpty)
            try store.commitSceneAttempt(claim, checkpoint: Data([2]), markerBatch: Data([3]),
                                         coveredThrough: 1, complete: false, release: true)
            try store.save(["waveform_peaks.v1.0": Data([9])])
            let paused = try entry(store)
            XCTAssertNil(paused.issue)
            do {
                let reader = try SidecarDatabase(store.url, writing: false)
                try reader.execute("BEGIN")
                _ = try reader.integer("SELECT count(*) FROM sections")
                let result = SidecarCacheCleaner.clear([paused])
                XCTAssertTrue(result.cleared.isEmpty)
                XCTAssertNotNil(result.skipped[paused.url])
                try reader.execute("ROLLBACK")
            }
            XCTAssertFalse(SidecarCacheCleaner.clear([paused]).cleared.isEmpty)
            let reopened = try AnalysisSidecar(source: store.source)
            XCTAssertNil(reopened.sceneAttempt(claim))
        }
    }

    func testClearRebuildsCompletedUnnamedScenesAndRemovesTheirMarkers() throws {
        try fixture { _, store in
            let claim = try XCTUnwrap(store.claimSceneAttempt(scope: "full", operationID: nil, restart: false, owner: "test"))
            try store.commitSceneAttempt(claim, checkpoint: Data([2]), markerBatch: Data([3]),
                                         coveredThrough: 1, complete: true)
            let preview = try entry(store)
            XCTAssertGreaterThan(try XCTUnwrap(preview.usage?.markerBytes), 0)
            let result = SidecarCacheCleaner.clear([preview])
            XCTAssertEqual(result.cleared, [preview.url], String(describing: result.skipped))
            let reopened = try AnalysisSidecar(source: store.source)
            XCTAssertNil(reopened.sceneAttempt(scope: "full", completed: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
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
            let busy = SidecarCacheCleaner.clear([preview])
            XCTAssertTrue(busy.cleared.isEmpty)
            XCTAssertNotNil(busy.skipped[preview.url])
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    func testExplicitFolderScanFindsNewFilesAndSkipsLegacyForeignAndSymlinks() throws {
        try fixture { root, store in
            try store.save(["waveform_peaks.v1.0": Data([1])])
            SidecarLocations.forget([store.url])
            let legacy = store.source.appendingPathExtension("cutdb")
            try FileManager.default.copyItem(at: store.url, to: legacy)
            let unrelated = root.appendingPathComponent("foreign.mov")
            try Data([1]).write(to: unrelated)
            try Data("user file".utf8).write(to: unrelated.appendingPathExtension("cutcache"))
            let alias = root.appendingPathComponent("link.mov")
            try Data([2]).write(to: alias)
            try FileManager.default.createSymbolicLink(at: alias.appendingPathExtension("cutcache"), withDestinationURL: store.url)
            let entries = SidecarCacheCleaner.preview(scanning: [root])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.source.lastPathComponent, "A.mov")
            XCTAssertTrue(SidecarLocations.knownEntries().contains { $0.source.lastPathComponent == "A.mov" })
        }
    }

    func testAdjacentAndManagedCachesWithSameFilenameAppearAndClearSeparately() throws {
        try fixture { root, original in
            let project = root.appendingPathComponent("edit.cut")
            try SidecarLocations.setMode(.project)
            let managed = try SidecarLocations.$projectURL.withValue(project) {
                let store = try AnalysisSidecar(source: original.source)
                try store.save(["custom": Data([1])])
                return store.url
            }
            try SidecarLocations.setMode(.media)
            let otherMedia = root.appendingPathComponent(managed.deletingPathExtension().lastPathComponent)
            try Data([4, 5, 6]).write(to: otherMedia)
            let adjacent = try AnalysisSidecar(source: otherMedia)
            try adjacent.save(["custom": Data([2])])
            XCTAssertEqual(managed.lastPathComponent, adjacent.url.lastPathComponent)

            let preview = SidecarCacheCleaner.preview(sources: [otherMedia, original.source], projects: [project])
            XCTAssertEqual(Set(preview.map(\.url.path)), Set([managed.path, adjacent.url.path]))
            XCTAssertEqual(Set(preview.map(\.id)).count, 2)
            let result = SidecarCacheCleaner.clear(preview)
            XCTAssertTrue(result.skippedEntries.isEmpty, String(describing: result.skipped))
            XCTAssertEqual(Set(result.cleared.map(\.path)), Set([managed.path, adjacent.url.path]))
        }
    }

    func testCaseVariantsCountPhysicalCachesAndForgetAllRemovedPaths() throws {
        try fixture { root, original in
            let alternate = root.appendingPathComponent("a.mov")
            let sameFile = FileManager.default.fileExists(atPath: alternate.path)
            if !sameFile { try Data([4, 5, 6]).write(to: alternate) }
            let other = try AnalysisSidecar(source: alternate)
            try original.save(["custom": Data([1])])
            try other.save(["custom": Data([2])])
            let preview = SidecarCacheCleaner.preview(sources: [original.source, alternate])
            XCTAssertEqual(preview.count, sameFile ? 1 : 2)
            XCTAssertTrue(preview.allSatisfy { $0.issue == nil })
            let result = SidecarCacheCleaner.clear(preview)
            XCTAssertTrue(result.skippedEntries.isEmpty, String(describing: result.skipped))
            XCTAssertEqual(result.cleared.count, sameFile ? 1 : 2)
            XCTAssertEqual(Set(result.clearedSources.map(\.path)), Set([original.source.path, alternate.path]))
            XCTAssertTrue(SidecarLocations.knownEntries().isEmpty)
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
            for version in [AnalysisSidecar.schemaVersion + 1, AnalysisSidecar.schemaVersion] {
                let source = root.appendingPathComponent("wrong-\(version).mov")
                try Data([1, 2, 3]).write(to: source)
                let foreign = source.appendingPathExtension("cutcache")
                try FileManager.default.copyItem(at: original.url, to: foreign)
                if version != AnalysisSidecar.schemaVersion {
                    let db = try SidecarDatabase(foreign, writing: true)
                    try db.execute("PRAGMA user_version=\(version)")
                }
                let before = try Data(contentsOf: foreign)
                let scanned = SidecarCacheCleaner.preview(scanning: [root])
                XCTAssertFalse(scanned.contains { $0.url == foreign && $0.issue == nil })
                XCTAssertFalse(SidecarLocations.knownEntries().contains { $0.url == foreign })
                let opened = try XCTUnwrap(SidecarCacheCleaner.preview(sources: [source]).first { $0.url == foreign })
                XCTAssertNotNil(opened.issue)
                let cleared = SidecarCacheCleaner.clear([opened])
                XCTAssertTrue(cleared.cleared.isEmpty)
                XCTAssertNotNil(cleared.skipped[foreign])
                XCTAssertEqual(try Data(contentsOf: foreign), before)
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
            let cleared = SidecarCacheCleaner.clear([preview])
            XCTAssertNotNil(cleared.skipped[store.url])
            XCTAssertEqual(try Data(contentsOf: store.url), saved)
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
            XCTAssertFalse(SidecarCacheCleaner.clear([found]).cleared.isEmpty)
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
            XCTAssertFalse(SidecarCacheCleaner.clear([inspected]).skipped.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.path), [])
            try FileManager.default.removeItem(at: disk)
            try FileManager.default.moveItem(at: offline, to: disk)
            XCTAssertNotNil(try AnalysisSidecar(source: original.source).read("waveform_peaks.v1.0"))
        }
    }
}
