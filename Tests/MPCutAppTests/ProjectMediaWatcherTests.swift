import MPCutCore
import os
import XCTest
@testable import MPCutApp

final class ProjectMediaWatcherTests: XCTestCase {
    @MainActor
    func testBlockedVolumeDoesNotDelayOtherVolumesOrDuplicateProbes() async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let stamp = try SourceIdentity(local)
        let stalled = URL(fileURLWithPath: "/Volumes/\(UUID())/camera.mov", isDirectory: false)
        let otherOnStalledVolume = stalled.deletingLastPathComponent().appendingPathComponent("mic.wav")
        let entered = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        let first = ProjectMediaWatcher(timeout: .milliseconds(50), readStamp: { url in
            if url == stalled {
                let firstProbe = entered.withLock { count in
                    count += 1
                    return count == 1
                }
                if firstProbe { _ = release.wait(timeout: .now() + 5) }
            }
            return stamp
        }, publish: { _ in }, refresh: { _, _ in true })
        let second = ProjectMediaWatcher(timeout: .milliseconds(50), readStamp: { _ in
            entered.withLock { $0 += 1 }
            return stamp
        }, publish: { _ in }, refresh: { _, _ in true })
        defer {
            release.signal()
            first.stop()
            second.stop()
        }

        first.update([local, stalled], perFile: false)
        first.checkNow()
        try await waitUntil {
            first.status(for: local) == .online && first.status(for: stalled) == .checking
        }
        XCTAssertEqual(second.status(for: otherOnStalledVolume), .checking)
        second.update([otherOnStalledVolume], perFile: false)
        second.checkNow()
        for _ in 0..<5 { first.checkNow() }
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(second.status(for: otherOnStalledVolume), .checking)
        XCTAssertEqual(entered.withLock { $0 }, 1)

        release.signal()
        try await waitUntil {
            first.status(for: stalled) == .online && second.status(for: otherOnStalledVolume) == .online
        }
    }

    @MainActor
    func testStampModeRecognizesRemovalAndRequestsRefreshOnReturn() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stamp = try SourceIdentity(file)
        let availability = OSAllocatedUnfairLock(initialState: true)
        var refreshed: Set<URL> = []
        let watcher = ProjectMediaWatcher(readStamp: { _ in
            availability.withLock { $0 ? stamp : nil }
        }, publish: { _ in }, refresh: { urls, verify in
            XCTAssertTrue(verify.isEmpty)
            refreshed.formUnion(urls)
            return true
        })
        defer { watcher.stop() }
        watcher.update([file], expected: [file: stamp], perFile: false)
        watcher.checkNow()
        try await waitUntil { watcher.status(for: file) == .online }

        availability.withLock { $0 = false }
        watcher.checkNow()
        try await waitUntil { watcher.status(for: file) == .offline }
        XCTAssertTrue(refreshed.isEmpty)

        availability.withLock { $0 = true }
        watcher.checkNow()
        try await waitUntil { refreshed == [file] }
        XCTAssertEqual(watcher.status(for: file), .online)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for media status.", file: file, line: line)
        throw CancellationError()
    }
}
