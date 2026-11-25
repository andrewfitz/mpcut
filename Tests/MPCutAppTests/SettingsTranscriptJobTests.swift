import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// A desktop transcription job with the lifecycle fixture standing in for Transcriberrr. The helper is
/// named only in Settings, never in the environment.
final class SettingsTranscriptJobTests: XCTestCase {
    private final class Activities: ActivityProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var begun = 0
        private var ended = 0
        var active: Int { lock.withLock { begun - ended } }
        var counts: (begun: Int, ended: Int) { lock.withLock { (begun, ended) } }

        func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
            lock.withLock { begun += 1 }
            return NSObject()
        }

        func endActivity(_ activity: NSObjectProtocol) { lock.withLock { ended += 1 } }
    }

    @MainActor
    func testSettingsHelperRunsTheJobWhichKeepsTheMacAwakeUntilItEnds() async throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("SettingsTranscriptJob-\(UUID())", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("fixture-helper")
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "TranscriptLifecycleProvider", withExtension: "py",
                                                      subdirectory: "Fixtures"))
        try files.copyItem(at: fixture, to: helper)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        func started(_ attempt: Int) -> Bool { files.fileExists(atPath: folder.appendingPathComponent("started-\(attempt)").path) }
        func release(_ attempt: Int, as state: String) throws {
            try Data(state.utf8).write(to: folder.appendingPathComponent("release-\(attempt)"), options: .atomic)
        }

        // The environment variable would win over Settings, so it is cleared for this test.
        let previousHelper = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIBERRR_HELPER"]
        unsetenv("MPCUT_TRANSCRIBERRR_HELPER")
        defer {
            if let previousHelper { setenv("MPCUT_TRANSCRIBERRR_HELPER", previousHelper, 1) } else { unsetenv("MPCUT_TRANSCRIBERRR_HELPER") }
        }
        let activities = Activities()
        let previousProvider = LiveTranscriptController.activityProvider
        LiveTranscriptController.activityProvider = activities
        defer { LiveTranscriptController.activityProvider = previousProvider }

        let source = folder.appendingPathComponent("Camera.mov")
        try files.copyItem(at: XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures")),
                           to: source)
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.historyLimit = 10
        preferences.transcriptHelperPath = helper.path
        let session = ProjectSession(id: UUID(), preferences: preferences)
        session.isMulticam = true
        let editor = session.multicam
        let controller = session.transcript
        defer { editor.reset() }
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        editor.confirmSetup(drafts: [.init(source: .init(id: "camera", file: source.path), media: media)],
                            opening: "camera", audio: .none)
        let store = TranscriptJobStore(directory: LiveTranscriptController.jobsDirectory)
        var ids: [UUID] = []
        defer {
            for id in ids {
                if let record = try? store.status(id) {
                    if record.ownerToken != nil { _ = try? store.interrupt(id) }
                    try? store.discard(documentID: record.documentID)
                }
            }
        }

        // Decision 8: an agent's start without an engine gets the Settings engine, resolved to a name.
        XCTAssertEqual(try controller.helperURL(), helper)
        let automatic = try await controller.settingsEngine()
        XCTAssertEqual(automatic, "lifecycle-fixture")
        preferences.transcriptEngine = "not-installed"
        let fallback = try await controller.settingsEngine()
        XCTAssertEqual(fallback, "lifecycle-fixture", "An unavailable preferred engine resolves as Automatic")
        XCTAssertEqual(preferences.transcriptEngine, "not-installed", "and the preference is kept")
        XCTAssertEqual(activities.counts.begun, 0, "Reading engines is not a job")

        let options = TranscriptJobOptions(engine: "lifecycle-fixture")
        // Finish.
        ids.append(try controller.start(options: options))
        try await until("the first job reaches the Settings helper") { started(1) }
        XCTAssertEqual(activities.active, 1)
        try release(1, as: "completed")
        try await until("the first job finishes") { controller.activeJobID == nil }
        XCTAssertEqual(try controller.status(ids[0]).state, .completed, controller.jobError ?? "")
        XCTAssertEqual(activities.active, 0)

        // Cancel.
        ids.append(try controller.start(options: options, policy: .restart))
        try await until("the second job reaches the helper") { started(2) }
        XCTAssertEqual(activities.active, 1)
        _ = try controller.cancel(ids[1])
        try await until("the cancelled job stops") { controller.activeJobID == nil }
        XCTAssertEqual(activities.active, 0)

        // Failure: the helper chosen in Settings is gone. It is the job's error, not a refused start.
        preferences.transcriptHelperPath = folder.appendingPathComponent("missing-helper").path
        ids.append(try controller.start(options: options, policy: .restart))
        try await until("the failed job stops") { controller.activeJobID == nil }
        XCTAssertTrue(controller.jobError?.contains("Settings") == true, controller.jobError ?? "No error was reported.")
        XCTAssertEqual(activities.active, 0)
        XCTAssertEqual(activities.counts.begun, 3)
    }

    @MainActor
    private func until(_ description: String, _ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CutError(code: "test_timeout", message: "Timed out waiting for \(description)")
    }
}
