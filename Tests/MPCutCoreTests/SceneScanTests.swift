import Foundation
import XCTest
@testable import MPCutCore

final class SceneScanTests: XCTestCase {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func cancel() { lock.withLock { value = true } }
        var isCancelled: Bool { lock.withLock { value } }
    }

    private func copyFixture() throws -> URL {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = tests.appendingPathComponent("MPCutAppTests/Fixtures/Scene-Cadence-Change.mov")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        return source
    }

    func testCurrentFullReportSlicesWithoutManufacturingBoundary() throws {
        let source = try copyFixture()
        let session = SceneScanSession()
        let full = try XCTUnwrap(SceneAnalysis.run(source, session: session).report)
        let sidecar = try AnalysisSidecar(source: source)
        XCTAssertNil(try sidecar.loadIndex(detail: .preview, cancelled: { false }))
        let savedClock = try XCTUnwrap(sidecar.loadSceneClock(cancelled: { false }))
        XCTAssertEqual(savedClock.duration, full.duration)
        XCTAssertEqual(savedClock.origin, full.origin)
        XCTAssertEqual(savedClock.video.timeBase, full.timeBase)
        let first = try XCTUnwrap(full.scenes.first)
        let span = try first.end.subtracting(first.start)
        let start = try first.start.adding(span.multiplied(by: RationalTime(numerator: 1, denominator: 4)))
        let end = try first.start.adding(span.multiplied(by: RationalTime(numerator: 3, denominator: 4)))
        var markers: [RationalTime] = []
        let warm = try SceneAnalysis.run(source, scope: .range(start: start, end: end), session: SceneScanSession(),
                                        onScene: { time, _ in markers.append(time) })
        let report = try XCTUnwrap(warm.report)
        XCTAssertEqual(warm.state, .upToDate)
        XCTAssertEqual(warm.progress.durable, end)
        XCTAssertEqual(report.scenes.map(\.start), [start])
        XCTAssertEqual(report.scenes.map(\.end), [end])
        XCTAssertEqual(report.scenes.map(\.view), [first.view])
        XCTAssertTrue(markers.isEmpty)
        XCTAssertThrowsError(try AnalysisSidecar.sceneSections(for: report)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_sidecar_analysis")
        }
    }

    func testRestartReplayDoesNotReturnNewerReport() throws {
        let source = try copyFixture()
        let firstPolicy = SceneScanPolicy.restart(operationID: "initial")
        let first = try XCTUnwrap(SceneAnalysis.run(source, policy: firstPolicy, session: SceneScanSession()).report)
        let sidecar = try AnalysisSidecar(source: source)
        let original = try XCTUnwrap(sidecar.persistedSceneAttempts().first?.id)
        let replacement = try SceneAnalysis.run(source, policy: .restart(operationID: "replacement"),
                                                session: SceneScanSession())
        XCTAssertEqual(replacement.state, .completed)
        let latest = try XCTUnwrap(sidecar.persistedSceneAttempts().first { $0.current }?.id)
        XCTAssertNotEqual(latest, original)

        let replay = try SceneAnalysis.run(source, policy: firstPolicy, session: SceneScanSession())
        XCTAssertEqual(replay.state, .upToDate)
        XCTAssertEqual(replay.report?.scenes.map(\.start), first.scenes.map(\.start))
        XCTAssertEqual(sidecar.persistedSceneAttempts().first { $0.current }?.id, latest)
    }

    func testWholeSidecarClearInvalidatesCompletedSceneInOpenSession() throws {
        let source = try copyFixture()
        let root = source.deletingLastPathComponent().appendingPathComponent("config")
        try SidecarLocations.$storageDirectory.withValue(root) {
            let session = SceneScanSession()
            let media = try CutEngine(useSidecar: false).inspect(source, keyframes: false)
            let result = try SceneAnalysis.run(media, session: session)
            XCTAssertEqual(result.progress.durable, media.duration)
            XCTAssertNotNil(SceneAnalysis.lookup(media, session: session)?.report)
            let entries = SidecarCacheCleaner.preview(sources: [source])
            XCTAssertEqual(entries.count, 1)
            let clear = SidecarCacheCleaner.clear(entries)
            XCTAssertEqual(clear.cleared.count, 1, "\(clear.skipped)")
            XCTAssertNil(SceneAnalysis.lookup(media, session: session)?.report)
        }
    }

    func testRecoveringSceneCheckpointRestoresOriginalMarkers() throws {
        let source = try copyFixture()
        let first = try XCTUnwrap(SceneAnalysis.run(source, session: SceneScanSession()).report)
        let sidecar = try AnalysisSidecar(source: source)
        try sidecar.save([AnalysisSidecar.sceneSectionKey: Data("{}".utf8)])
        let recovered = try XCTUnwrap(SceneAnalysis.run(source, session: SceneScanSession()).report)
        XCTAssertEqual(recovered.scenes.map(\.start), first.scenes.map(\.start))
        XCTAssertEqual(recovered.scenes.map(\.end), first.scenes.map(\.end))
    }

    func testOneSubscriberCanCancelWhileCompatibleWorkContinues() throws {
        let source = try copyFixture()
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: false)
        let session = SceneScanSession()
        let first = expectation(description: "first subscriber returned")
        let second = expectation(description: "remaining subscriber finished")
        let workerEntered = DispatchSemaphore(value: 0)
        let startDecode = DispatchSemaphore(value: 0)
        let secondAttached = DispatchSemaphore(value: 0)
        let cancellation = Cancellation()
        let firstThread = DispatchQueue(label: "scene-test-first-subscriber")
        let caller = DispatchSpecificKey<Bool>()
        firstThread.setSpecific(key: caller, value: true)

        firstThread.async {
            defer { first.fulfill() }
            do {
                let outcome = try SceneAnalysis.run(media, useSidecar: false, session: session, allowAutomaticSave: {
                    if DispatchQueue.getSpecific(key: caller) == nil {
                        workerEntered.signal()
                        _ = startDecode.wait(timeout: .now() + 10)
                    }
                    return false
                }, cancelled: { cancellation.isCancelled })
                XCTAssertEqual(outcome.state, .paused)
            } catch { XCTFail("First subscriber failed: \(error)") }
        }
        XCTAssertEqual(workerEntered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            defer { second.fulfill() }
            do {
                let outcome = try SceneAnalysis.run(media, useSidecar: false, session: session,
                                                    progress: { _ in secondAttached.signal() })
                XCTAssertEqual(outcome.state, .completed)
                XCTAssertNotNil(outcome.report)
            } catch { XCTFail("Remaining subscriber failed: \(error)") }
        }
        XCTAssertEqual(secondAttached.wait(timeout: .now() + 5), .success)
        cancellation.cancel()
        wait(for: [first], timeout: 5)
        startDecode.signal()
        wait(for: [second], timeout: 5)
    }

    func testEditingOneReportKeepsReusedAndRecomputedDetectionsIndependent() throws {
        let source = try copyFixture()
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: false)
        let session = SceneScanSession()
        var edited = try XCTUnwrap(SceneAnalysis.run(media, useSidecar: false, session: session).report)
        edited.setViewName("Wide", for: 1)
        let reused = try SceneAnalysis.run(media, useSidecar: false, session: session)
        let restarted = try SceneAnalysis.run(media, policy: .restart(operationID: "restart"),
                                              useSidecar: false, session: session)
        XCTAssertEqual(edited.views.first?.name, "Wide")
        XCTAssertNil(reused.report?.views.first?.name)
        XCTAssertNil(restarted.report?.views.first?.name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: source).path))
    }

    func testNamedViewsAreSavedAsFullSourceChoicesAndRetainTheirEvidence() throws {
        let source = try copyFixture()
        let engine = CutEngine(useSidecar: false)
        let media = try engine.inspect(source, keyframes: true)
        let session = SceneScanSession()
        var report = try XCTUnwrap(SceneAnalysis.run(media, useSidecar: false, session: session).report)
        let view = try XCTUnwrap(report.views.first?.view)
        report.setViewName("Wide", for: view)
        var annotations = ProjectAnalysisAnnotations()
        XCTAssertTrue(annotations.setScene(report, for: media))
        let named = try XCTUnwrap(annotations.scene(for: media))
        let evidence = try XCTUnwrap(named.sourceEvidence)

        let otherLocation = source.deletingLastPathComponent().appendingPathComponent("moved.mov")
        try FileManager.default.copyItem(at: source, to: otherLocation)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: otherLocation.path)
        let moved = try engine.inspect(otherLocation, keyframes: true)
        XCTAssertNotEqual(named.sourceStamp, SceneSourceStamp(media: moved))
        XCTAssertEqual(named.forSource(otherLocation).sourceEvidence, evidence)
        var relinked = annotations.mappingPaths { _ in otherLocation.path }
        var restored = try XCTUnwrap(relinked.scene(for: moved))
        XCTAssertEqual(restored.views.first?.name, "Wide")
        XCTAssertEqual(restored.sourceStamp, SceneSourceStamp(media: moved))
        restored.setViewName("Establishing", for: view)
        XCTAssertTrue(relinked.setScene(restored, for: moved))
        XCTAssertEqual(relinked.scene(for: moved)?.sourceEvidence, evidence)

        let first = try XCTUnwrap(report.scenes.first)
        let inside = try first.end.multiplied(by: .init(numerator: 1, denominator: 2))
        let slice = try XCTUnwrap(SceneAnalysis.run(media, scope: .range(start: .zero, end: inside),
                                                          useSidecar: false, session: session).report)
        XCTAssertFalse(annotations.setScene(slice, for: media))
        XCTAssertEqual(annotations.scene(for: media), named)
    }

    func testCompletedRangeReplacementWinsOverDerivedFullSlice() throws {
        let source = try copyFixture()
        let full = try XCTUnwrap(SceneAnalysis.run(source, session: SceneScanSession()).report)
        let last = try XCTUnwrap(full.scenes.last)
        XCTAssertGreaterThan(last.number, 1)
        let middle = try last.start.adding(last.end).multiplied(by: RationalTime(numerator: 1, denominator: 2))
        let scope = SceneScanScope.range(start: middle, end: last.end)
        let sliced = try SceneAnalysis.run(source, scope: scope, session: SceneScanSession())
        XCTAssertEqual(sliced.report?.scenes.first?.number, last.number)

        let restarted = try SceneAnalysis.run(source, scope: scope, policy: .restart(operationID: "range"),
                                               session: SceneScanSession())
        XCTAssertEqual(restarted.report?.scenes.first?.number, 1)
        let reused = try SceneAnalysis.run(source, scope: scope, session: SceneScanSession())
        XCTAssertEqual(reused.state, .upToDate)
        XCTAssertEqual(reused.report?.scenes.first?.number, 1)
    }
}
