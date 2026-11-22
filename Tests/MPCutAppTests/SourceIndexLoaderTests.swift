import MPCutCore
import XCTest
@testable import MPCutApp

final class SourceIndexLoaderTests: XCTestCase {
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
        let sidecar = try await read(.init(url: file, sidecars: true, preview: false, identity: identity))
        XCTAssertTrue(first === second)
        XCTAssertFalse(admission.ordinary.hasFullEditIndex)
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
