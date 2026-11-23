import MPCutCore
import XCTest
@testable import MPCutApp

final class SourceIndexLoaderTests: XCTestCase {
    @MainActor
    func testOpeningUsesCompleteSidecarForSequenceAndMulticam() async throws {
        let (directory, fixture) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cached.mov")
        try FileManager.default.copyItem(at: fixture, to: file)
        let original = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        let sidecar = AnalysisSidecar(media: original)
        try sidecar.save(AnalysisSidecar.indexSections(for: original))
        let key = SourceIndexLoader.Key(url: file, sidecars: true, preview: true, preferCompleted: true)
        let loader = SourceIndexLoader()
        let opened = try await read(key, using: loader)
        XCTAssertTrue(opened.ordinary.hasFullEditIndex)
        XCTAssertEqual(opened.ordinary.frames.map(\.time), original.frames.map(\.time))
        let full = try await read(.init(url: file, sidecars: true, preview: false), using: loader)
        XCTAssertTrue(opened === full)

        let multicam = try await admit(.init(url: file, sidecars: true, preview: true), using: SourceIndexLoader())
        XCTAssertTrue(multicam.ordinary.hasFullEditIndex)
        XCTAssertTrue(multicam.multicam.hasFullEditIndex)
    }

    @MainActor
    func testOpeningFallsBackToProvisionalMediaForIncompleteSidecar() async throws {
        let (directory, fixture) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = SourceIndexLoader()
        for (name, audio) in [("partial", nil), ("corrupt", Data([0xff]))] as [(String, Data?)] {
            let file = directory.appendingPathComponent("\(name).mov")
            try FileManager.default.copyItem(at: fixture, to: file)
            let original = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
            let sidecar = AnalysisSidecar(media: original)
            var sections = try AnalysisSidecar.indexSections(for: original)
            sections["media_index_audio.v1"] = audio
            try sidecar.save(sections)
            let preview = try await read(.init(url: file, sidecars: true, preview: true, preferCompleted: true), using: loader)
            XCTAssertFalse(preview.ordinary.hasFullEditIndex, name)
            let key = SourceIndexLoader.Key(url: file, sidecars: true, preview: false, identity: preview.ordinary.identity)
            let full = try await read(key, using: loader)
            XCTAssertTrue(full.ordinary.hasFullEditIndex, name)
            XCTAssertEqual(full.ordinary.frames.map(\.time), original.frames.map(\.time), name)
            XCTAssertNotNil(try CutEngine().cachedIndex(file), name)
        }
    }

    @MainActor
    func testDelayedMovieFitsOrdinaryCacheAndConvertsOnMulticamAdmission() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Multicam-Delayed-ProRes", withExtension: "mov",
                                                  subdirectory: "Fixtures"))
        let ordinary = try CutEngine(useSidecar: false).inspect(url, keyframes: true)
        XCTAssertGreaterThan(ordinary.multicamSourceOffset, .zero)
        let loader = SourceIndexLoader(completedIndexByteLimit: ordinary.indexStorageBytes)
        let key = SourceIndexLoader.Key(url: url, sidecars: false, preview: false)
        let first = try await read(key, using: loader)
        XCTAssertEqual(first.storageBytes, ordinary.indexStorageBytes)
        let admitted = try await admit(key, using: loader)
        XCTAssertEqual(admitted.multicam.multicamClockOffset, ordinary.multicamSourceOffset)
        XCTAssertEqual(admitted.multicam.frames.first?.time,
                       try XCTUnwrap(ordinary.frames.first).time.adding(ordinary.multicamSourceOffset))
        let warm = try await read(key, using: loader)
        XCTAssertTrue(warm === first)
        let tooLargeToCache = try await admit(key, using: loader)
        XCTAssertFalse(admitted === tooLargeToCache)

        let roomy = SourceIndexLoader(completedIndexByteLimit: ordinary.indexStorageBytes + admitted.multicam.indexStorageBytes)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try FileManager.default.copyItem(at: url, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let otherKey = SourceIndexLoader.Key(url: copy, sidecars: false, preview: false)
        let older = try await read(otherKey, using: roomy)
        async let one = admit(key, using: roomy)
        async let two = admit(key, using: roomy)
        let (shared, other) = try await (one, two)
        let cached = try await admit(key, using: roomy)
        XCTAssertTrue(shared === other)
        XCTAssertTrue(shared === cached)
        let evicted = try await read(otherKey, using: roomy)
        XCTAssertFalse(older === evicted)
    }

    @MainActor
    private func admit(_ key: SourceIndexLoader.Key, using loader: SourceIndexLoader) async throws -> SourceIndexLoader.MulticamIndex {
        try await withCheckedThrowingContinuation { continuation in
            _ = loader.admit(key) { continuation.resume(with: $0) }
        }
    }

    @MainActor
    func testCompletedIndexReuseRequiresSameFileIdentityAndPreference() async throws {
        let (directory, fixture) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture, to: file)
        let identity = try SourceIdentity(file)
        let key = SourceIndexLoader.Key(url: file, sidecars: false, preview: false, identity: identity)
        let first = try await read(key)
        let second = try await read(key)
        let admission = try await read(.init(url: file, sidecars: false, preview: true))
        let warmPreview = try await read(.init(url: file, sidecars: false, preview: true, preferCompleted: true))
        let sidecar = try await read(.init(url: file, sidecars: true, preview: false, identity: identity))
        XCTAssertTrue(first === second)
        XCTAssertFalse(admission.ordinary.hasFullEditIndex)
        XCTAssertTrue(warmPreview === first)
        XCTAssertFalse(first === sidecar)

        let newFile = directory.appendingPathComponent("new-camera.mov")
        try FileManager.default.copyItem(at: fixture, to: newFile)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: newFile, to: file)
        let updatedIdentity = try SourceIdentity(file)
        XCTAssertNotEqual(identity, updatedIdentity)
        do {
            _ = try await read(key)
            XCTFail("An earlier preview identity must be rejected after recording replacement.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "source_changed")
        }
        let replacement = try await read(.init(url: file, sidecars: false, preview: false, identity: updatedIdentity))
        XCTAssertFalse(replacement === first)
        XCTAssertEqual(replacement.ordinary.identity, updatedIdentity)
    }

    @MainActor
    func testExplicitRefreshReplacesWarmIndexAndRejectsEarlierSnapshot() async throws {
        let (directory, fixture) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.mov")
        let fm = FileManager.default
        try fm.copyItem(at: fixture, to: file)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let key = SourceIndexLoader.Key(url: file, sidecars: false, preview: false)
        let loader = SourceIndexLoader()
        let original = try await read(key, using: loader)
        let originalIdentity = original.ordinary.identity
        // Rewrite the same bytes so this remains a readable recording. A writer can
        // restore mtime, but the old in-flight provider must still drop its snapshot.
        let bytes = try Data(contentsOf: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: bytes)
        try writer.close()
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let fresh = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        XCTAssertEqual(originalIdentity, fresh.identity)
        loader.acceptRefreshedIndex(fresh, sidecars: false)
        let updated = try await read(key, using: loader)
        XCTAssertFalse(original === updated)
        XCTAssertTrue(fresh.identity.matchesSnapshot(updated.ordinary.identity))
        let stale = SourceIndexLoader.Key(url: file, sidecars: false, preview: false, identity: originalIdentity)
        do {
            _ = try await read(stale, using: loader)
            XCTFail("The superseded recording was accepted")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "source_changed")
        }
    }

    @MainActor
    func testCompletedIndexCacheEvictsLeastRecentlyUsedEntry() async throws {
        let (directory, fixture) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var keys: [SourceIndexLoader.Key] = []
        for number in 0...8 {
            let url = directory.appendingPathComponent("camera-\(number).mov")
            try FileManager.default.copyItem(at: fixture, to: url)
            keys.append(.init(url: url, sidecars: false, preview: false))
        }

        let first = try await read(keys[0])
        let second = try await read(keys[1])
        for key in keys[2..<8] { _ = try await read(key) }
        let touched = try await read(keys[0])
        XCTAssertTrue(touched === first)
        _ = try await read(keys[8])
        let stillCached = try await read(keys[0])
        let evicted = try await read(keys[1])
        XCTAssertTrue(stillCached === first)
        XCTAssertFalse(evicted === second)
    }

    @MainActor
    func testOversizedIndexIsNotRetainedByCompletedCache() async throws {
        let (directory, fixture) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture, to: file)
        let loader = SourceIndexLoader(completedIndexByteLimit: 1)
        let key = SourceIndexLoader.Key(url: file, sidecars: false, preview: false)
        let first = try await read(key, using: loader)
        let second = try await read(key, using: loader)
        XCTAssertGreaterThan(first.storageBytes, 1)
        XCTAssertFalse(first === second)
    }

    @MainActor
    private func read(_ key: SourceIndexLoader.Key,
                      using loader: SourceIndexLoader? = nil) async throws -> SourceIndexLoader.Index {
        try await (loader ?? .shared).read(key, token: EditCancellation(), preference: EditCancellation(), progress: { _ in })
    }

    private func fixtureDirectory() throws -> (URL, URL) {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return (directory, fixture)
    }
}
