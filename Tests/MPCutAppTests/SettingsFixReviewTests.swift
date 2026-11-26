import AppKit
import Combine
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// Review findings on agent permissions, storage, preference storage and the Settings window.
@MainActor
final class SettingsFixReviewTests: XCTestCase {
    private let files = FileManager.default
    private var suiteNames: [String] = []
    private var folders: [URL] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        for folder in folders { try? files.removeItem(at: folder) }
        try await super.tearDown()
    }

    private func suite() throws -> (UserDefaults, String) {
        let name = "com.mpcut.tests.settings-fix." + UUID().uuidString
        suiteNames.append(name)
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private func folder() throws -> URL {
        let url = files.temporaryDirectory.appendingPathComponent("mpcut-fix-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    // MARK: 1. Let agents replace existing project files

    private struct Reached: Error {}

    private func fileCall(_ sessions: ProjectSessions, _ tool: String, _ arguments: [String: Any]) async throws {
        _ = try await sessions.mcpFile(tool: tool, arguments: arguments, session: nil, checkAccess: { throw Reached() })
    }

    func testNestedInPlaceRequestsAreRefusedWithReplacingOff() async throws {
        let p = EditorPreferences()
        let sessions = ProjectSessions(preferences: p)
        p.agentsReplaceFiles = false
        let calls: [(String, [String: Any])] = [
            ("transcript_file_words_correct", ["request": ["project_path": "/tmp/none.cut", "attachment_id": "a", "in_place": true]]),
            ("transcript_file_attachment_import", ["request": ["project_path": "/tmp/none.cut", "in_place": true]]),
            ("transcript_file_edit_apply", ["request": ["project_path": "/tmp/none.cut", "request": ["in_place": true]]]),
            ("transcript_file_excerpt_queue", ["request": ["request": ["request": ["in_place": true]]]]),
            ("still_file_placement_remove", ["project_path": "/tmp/none.cut", "in_place": true])
        ]
        for (tool, arguments) in calls {
            do {
                try await fileCall(sessions, tool, arguments)
                XCTFail("\(tool) ran with replacing off")
            } catch let failure as MCPFailure {
                XCTAssertEqual(failure.code, "file_replace_disabled", tool)
                XCTAssertTrue(failure.message.contains("Let agents replace existing project files"), failure.message)
            }
        }
        // A new destination is not a replacement, and turning the switch on lets in-place calls through.
        for arguments: [String: Any] in [["request": ["project_path": "/tmp/none.cut", "out_project": "/tmp/new.cut"]],
                                          ["request": ["project_path": "/tmp/none.cut", "in_place": false]]] {
            do {
                try await fileCall(sessions, "transcript_file_words_correct", arguments)
                XCTFail("The access check was skipped")
            } catch is Reached {}
        }
        p.agentsReplaceFiles = true
        do {
            try await fileCall(sessions, "transcript_file_words_correct", calls[0].1)
            XCTFail("The access check was skipped")
        } catch is Reached {}
    }

    /// Every `in_place` in the app-routed file tool schemas is found by the predicate, wherever it is nested.
    func testEveryInPlaceFieldInTheFileToolSchemasCountsAsReplacing() throws {
        let schemas = try MCPSchemas.loaded.get()
        var found: [(tool: String, path: [String])] = []
        func walk(_ schema: [String: Any], _ path: [String], tool: String) {
            if let properties = schema["properties"] as? [String: [String: Any]] {
                for (name, child) in properties {
                    if name == "in_place" { found.append((tool, path)) }
                    walk(child, path + [name], tool: tool)
                }
            }
            for key in ["allOf", "oneOf", "anyOf"] {
                for child in schema[key] as? [[String: Any]] ?? [] { walk(child, path, tool: tool) }
            }
            for key in ["then", "else", "items"] {
                if let child = schema[key] as? [String: Any] { walk(child, path, tool: tool) }
            }
        }
        for (tool, schema) in schemas.inputs where MCPFileRequest.supports(tool) { walk(schema, [], tool: tool) }
        XCTAssertTrue(found.contains { $0.tool == "transcript_file_words_correct" && $0.path == ["request"] })
        XCTAssertTrue(found.contains { $0.tool == "tiles_file_link" && $0.path.isEmpty })
        for (tool, path) in found {
            XCTAssertTrue(path.allSatisfy { $0 == "request" }, "\(tool) has in_place under \(path); teach replacesProject")
            var arguments: [String: Any] = ["in_place": true]
            for key in path.reversed() { arguments = [key: arguments] }
            XCTAssertTrue(MCPFileRequest.replacesProject(tool: tool, arguments: arguments), "\(tool) \(path)")
            arguments = ["in_place": false]
            for key in path.reversed() { arguments = [key: arguments] }
            XCTAssertFalse(MCPFileRequest.replacesProject(tool: tool, arguments: arguments), "\(tool) \(path)")
        }
        XCTAssertFalse(MCPFileRequest.replacesProject(tool: "project_save", arguments: ["in_place": true]), "Not a file tool")
    }

    // MARK: 2 and 9. The shared cache limit

    /// A sequence project whose history references `recording`, so opening it protects that recording.
    private func project(_ name: String, recording: String, in directory: URL) throws -> (URL, URL) {
        let document = directory.appendingPathComponent(name)
        let media = directory.appendingPathComponent(recording)
        let previous = CutProject.sequence([CutSequenceClip(id: "a", file: recording, from: .zero, to: .init(numerator: 1))])
        try CutProject.sequence([]).save(to: document, undo: [.init(action: "Delete Clip", project: previous)], redo: [])
        return (document, media.resolvingSymlinksInPath())
    }

    private func paths(_ urls: Set<URL>) -> Set<String> { Set(urls.map { $0.resolvingSymlinksInPath().path }) }

    func testTheEnforcerReadsTheProtectionAgainBeforeEachRemoval() async throws {
        let root = try folder()
        let p = EditorPreferences()
        let probe = EnforceProbe()
        var context = SidecarClearContext()
        let early = URL(fileURLWithPath: "/tmp/early.mov"), late = URL(fileURLWithPath: "/tmp/late.mov")
        context.protected = [early]
        let enforcer = SharedCacheLimitEnforcer(preferences: p, context: { context }, root: { root },
                                                retryDelay: .milliseconds(20)) { limit, protected, _, recheck in
            let fresh = recheck()
            probe.record(protected: protected, recheck: fresh)
            var outcome = SharedCacheLimit.Outcome()
            outcome.aborted = fresh == nil
            outcome.bytesBefore = 2 * limit
            outcome.bytesAfter = limit
            if fresh != nil { outcome.removed = [URL(fileURLWithPath: "/tmp/cache")] }
            return outcome
        }
        p.sharedCacheLimitBytes = 1_000
        // The run starts; a project opens before its first removal. The check made on the main actor sees it.
        let task = try XCTUnwrap(enforcer.schedule())
        context.protected = [early, late]
        await task.value
        let first = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(first.protected, [early], "The run started with the protection of its time")
        XCTAssertEqual(first.recheck, [early, late])

        // A window starts opening or importing during the run: the check stops it, and it runs again once settled.
        let second = try XCTUnwrap(enforcer.schedule())
        context.isSettling = true
        await second.value
        XCTAssertEqual(probe.calls.count, 2)
        XCTAssertNil(try XCTUnwrap(probe.calls.last).recheck, "Settling answers nil")
        XCTAssertEqual(enforcer.lastOutcome?.aborted, true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.calls.count, 2, "Nothing runs while a window is settling")
        context.isSettling = false
        try await waitUntil { probe.calls.count == 3 }
        XCTAssertEqual(try XCTUnwrap(probe.calls.last).recheck, [early, late])
    }

    func testARunThatCanRemoveNothingIsNotRepeatedUntilSomethingChanges() async throws {
        let root = try folder()
        let p = EditorPreferences()
        let probe = EnforceProbe()
        var context = SidecarClearContext()
        let enforcer = SharedCacheLimitEnforcer(preferences: p, context: { context }, root: { root },
                                                retryDelay: .milliseconds(20)) { limit, protected, _, _ in
            probe.record(protected: protected, recheck: nil)
            // Over the limit, and every cutcache is protected.
            var outcome = SharedCacheLimit.Outcome()
            outcome.bytesBefore = 2 * limit
            outcome.bytesAfter = 2 * limit
            return outcome
        }
        p.sharedCacheLimitBytes = 1_000
        await enforcer.schedule()?.value
        XCTAssertEqual(probe.calls.count, 1)
        // Another cutcache save does not walk the folder again.
        await enforcer.schedule()?.value
        await enforcer.schedule()?.value
        XCTAssertEqual(probe.calls.count, 1)
        // A change of the protected recordings, or of the limit, measures again.
        context.protected = [URL(fileURLWithPath: "/tmp/closed.mov")]
        await enforcer.schedule()?.value
        XCTAssertEqual(probe.calls.count, 2)
        p.sharedCacheLimitBytes = 2_000
        await enforcer.schedule()?.value
        XCTAssertEqual(probe.calls.count, 3)
    }

    func testTheCacheLimitProtectsRecordingsOfZeroOneAndTwoOpenProjects() async throws {
        let directory = try folder()
        let root = try folder()
        let p = EditorPreferences()
        p.historyLimit = 0
        let sessions = ProjectSessions(preferences: p, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        let probe = EnforceProbe()
        let enforcer = SharedCacheLimitEnforcer(preferences: p, context: { SidecarClearContext(sessions: sessions) },
                                                root: { root }, retryDelay: .milliseconds(20)) { limit, protected, _, recheck in
            probe.record(protected: protected, recheck: recheck())
            var outcome = SharedCacheLimit.Outcome()
            outcome.removedSources = [URL(fileURLWithPath: "/tmp/evicted-\(probe.calls.count).mov")]
            outcome.removed = [URL(fileURLWithPath: "/tmp/evicted.cutcache")]
            return outcome
        }
        let first = try project("First.cut", recording: "first.mov", in: directory)
        let second = try project("Second.cut", recording: "second.mov", in: directory)
        p.sharedCacheLimitBytes = 1
        for (count, opened) in [[], [first], [first, second]].enumerated() {
            for (document, _) in opened where sessions.project(at: document) == nil {
                sessions.openFiles([document])
                try await waitUntil { sessions.project(at: document) != nil && !SidecarClearContext(sessions: sessions).isSettling }
            }
            let posted = expectation(forNotification: .sidecarCachesDidClear, object: nil) { note in
                (note.object as? Set<URL>)?.first?.lastPathComponent == "evicted-\(count + 1).mov"
                    && note.userInfo?["wholeSidecars"] as? Bool == true
            }
            try await XCTUnwrap(enforcer.schedule()).value
            await fulfillment(of: [posted], timeout: 5)
            let call = try XCTUnwrap(probe.calls.last)
            let recordings = Set(opened.map(\.1.path))
            XCTAssertTrue(recordings.isSubset(of: paths(call.protected)), "\(count) projects: \(call.protected)")
            XCTAssertTrue(recordings.isSubset(of: paths(try XCTUnwrap(call.recheck))), "\(count) projects")
            if opened.isEmpty { XCTAssertTrue(call.protected.isEmpty) }
        }
    }

    // MARK: 4. The cache limit field

    func testANonzeroCacheLimitNeverShowsAsZero() throws {
        XCTAssertEqual(SettingsStoragePage.cacheLimitGigabytes(0), 0)
        XCTAssertEqual(SettingsStoragePage.cacheLimitGigabytes(1), 0.001, "One byte shows as the smallest step")
        XCTAssertEqual(SettingsStoragePage.cacheLimitGigabytes(500_000_000), 0.5)
        XCTAssertEqual(SettingsStoragePage.cacheLimitGigabytes(5_000_000_000), 5)
        XCTAssertEqual(SettingsStoragePage.cacheLimitBytes(0.5), 500_000_000)
        XCTAssertEqual(SettingsStoragePage.cacheLimitBytes(0), 0)
        XCTAssertEqual(SettingsStoragePage.cacheLimitBytes(1_000_000), 1_000_000_000_000_000)
        let shown = SettingsStoragePage.cacheLimitGigabytes(400).settingsText(digits: SettingsStoragePage.cacheLimitDigits)
        XCTAssertEqual(shown, "0.001")

        // Showing the page does not write the rounded value back.
        _ = NSApplication.shared
        let p = EditorPreferences()
        p.sharedCacheLimitBytes = 400
        var changes: [EditorPreferences.Change] = []
        let observer = p.observeChanges { changes.append($0) }
        defer { observer.cancel() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsStoragePage(preferences: p, cacheContext: { SidecarClearContext() },
                                                               locations: try temporaryLocations()))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let fields = descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertTrue(fields.contains { $0.stringValue == "0.001" }, fields.map(\.stringValue).description)
        window.close()
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(p.sharedCacheLimitBytes, 400)
        XCTAssertTrue(changes.isEmpty)
    }

    private func temporaryLocations() throws -> StorageLocations {
        let root = try folder()
        return StorageLocations(generatedStills: root.appendingPathComponent("Stills"),
                                transcriptRecognition: root.appendingPathComponent("Claims"),
                                transcriptJobs: [root.appendingPathComponent("Drafts/.transcript-jobs"), root.appendingPathComponent("Jobs")],
                                untitledDrafts: root.appendingPathComponent("Drafts"),
                                agentReceipts: root.appendingPathComponent("Receipts"))
    }

    // MARK: 5. Launch arguments never set the routines that remove files

    func testLaunchArgumentsNeverSetDraftRetentionOrTheCacheLimit() async throws {
        let (defaults, name) = try suite()
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        defaults.set(30, forKey: "draft_retention_days")
        defaults.set(5_000_000_000, forKey: "analysis_shared_cache_max_bytes")
        var launch = arguments
        launch["draft_retention_days"] = "1"
        launch["analysis_shared_cache_max_bytes"] = "1"
        launch["recent_files_max_count"] = "5"
        defaults.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)

        let named = EditorPreferences(defaults: defaults, persistentDomain: name)
        XCTAssertEqual(named.draftRetentionDays, 30, "The saved value applies, not the argument")
        XCTAssertEqual(named.sharedCacheLimitBytes, 5_000_000_000)
        XCTAssertEqual(named.recentFilesLimit, 5, "Other keys still take launch arguments")
        let unnamed = EditorPreferences(defaults: defaults)
        XCTAssertEqual(unnamed.draftRetentionDays, 0, "Without the saved domain the argument is ignored")
        XCTAssertEqual(unnamed.sharedCacheLimitBytes, 0)

        defaults.removeObject(forKey: "draft_retention_days")
        defaults.removeObject(forKey: "analysis_shared_cache_max_bytes")
        let fresh = EditorPreferences(defaults: defaults, persistentDomain: name)
        XCTAssertEqual(fresh.draftRetentionDays, 0)
        XCTAssertEqual(fresh.sharedCacheLimitBytes, 0)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?["draft_retention_days"] as? Int, nil, "Loading stores nothing")

        // Launch maintenance and the cache limit then do nothing.
        let drafts = try folder()
        let expired = drafts.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: expired, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: expired.appendingPathComponent("Untitled.cut"))
        try files.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: expired.path)
        let trashed = TrashRecorder()
        let sessions = ProjectSessions(preferences: fresh)
        await sessions.runLaunchMaintenance(drafts: drafts, trash: { trashed.append($0) })
        XCTAssertTrue(trashed.urls.isEmpty)
        let enforcer = SharedCacheLimitEnforcer(preferences: fresh, context: { SidecarClearContext() }, root: { drafts }) { _, _, _, _ in
            XCTFail("The cache limit ran")
            return SharedCacheLimit.Outcome()
        }
        XCTAssertNil(enforcer.schedule())

        // A value saved in Settings still applies at the next launch, with or without an argument.
        fresh.draftRetentionDays = 7
        XCTAssertEqual(EditorPreferences(defaults: defaults, persistentDomain: name).draftRetentionDays, 7)
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(EditorPreferences(defaults: defaults).draftRetentionDays, 7)
    }

    // MARK: 6. Normalizing setters store and announce once

    func testAnOutOfRangeWriteStoresAndAnnouncesOnce() throws {
        let (defaults, _) = try suite()
        let p = EditorPreferences(defaults: defaults)
        var changes: [EditorPreferences.Change] = []
        let observer = p.observeChanges { changes.append($0) }
        defer { observer.cancel() }

        p.trackLabelWidth = 500
        XCTAssertEqual(p.trackLabelWidth, 360)
        XCTAssertEqual(defaults.double(forKey: "multicam_track_label_width_points"), 360)
        p.recentFilesLimit = 99
        XCTAssertEqual(p.recentFilesLimit, 30)
        p.gapColor = "#abcdef"
        XCTAssertEqual(p.gapColor, "#ABCDEF")
        p.stillTimelineWidth = 1921
        XCTAssertEqual(p.stillTimelineWidth, 1920)
        XCTAssertEqual(changes, [.trackLabelWidth, .recentFilesLimit, .gapColor], "One change per write; 1920 is unchanged")

        // A clamp or a rejected value that lands on the current value changes nothing.
        changes.removeAll()
        p.trackLabelWidth = 400
        p.gapColor = "black"
        p.stillTimelineCodec = .jpeg
        p.reencodeQuality = .prores422
        p.trackLabelWidth = .nan
        XCTAssertEqual(changes, [])
        XCTAssertEqual(p.trackLabelWidth, 360)
        XCTAssertEqual(p.gapColor, "#ABCDEF")
        XCTAssertEqual(p.stillTimelineCodec, .h264)
        XCTAssertEqual(defaults.string(forKey: "gap_default_color"), "#ABCDEF")
    }

    func testARefusedAgentWriteOfAnOutOfRangeValueKeepsTheOriginal() throws {
        let (defaults, _) = try suite()
        let p = EditorPreferences(defaults: defaults)
        var changes: [EditorPreferences.Change] = []
        let observer = p.observeChanges { changes.append($0) }
        defer { observer.cancel() }
        p.agentsChangeSettings = false
        changes.removeAll()
        let request = AgentSettingsRequest()
        AgentOrigin.$request.withValue(request) {
            p.trackLabelWidth = 500
            p.recentFilesLimit = 99
            p.gapColor = "#abcdef"
        }
        XCTAssertEqual(p.trackLabelWidth, 172)
        XCTAssertEqual(p.recentFilesLimit, 10)
        XCTAssertEqual(p.gapColor, "#000000")
        XCTAssertEqual(request.refusedKeys, ["multicam_track_label_width_points", "recent_files_max_count", "gap_default_color"])
        XCTAssertTrue(changes.isEmpty)
        XCTAssertNil(defaults.object(forKey: "multicam_track_label_width_points"))

        // A read-only key, with the switch on.
        p.agentsChangeSettings = true
        changes.removeAll()
        let readOnly = AgentSettingsRequest()
        AgentOrigin.$request.withValue(readOnly) { p.draftRetentionDays = 999 }
        XCTAssertEqual(p.draftRetentionDays, 0)
        XCTAssertEqual(readOnly.refusedKeys, ["draft_retention_days"])
        XCTAssertTrue(changes.isEmpty)
        // The next user write is stored as usual.
        p.trackLabelWidth = 500
        XCTAssertEqual(p.trackLabelWidth, 360)
        XCTAssertEqual(changes, [.trackLabelWidth])
    }

    // MARK: 7 and 8. Numeric fields commit only what the editor typed

    private func host<Value: SettingsNumber>(_ field: SettingsNumericField<Value>) -> (NSWindow, NSTextField?) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: field.frame(width: 360))
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (window, descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    private func type(_ text: String, into entry: NSTextField, in window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(entry))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func testRestoreDefaultsDropsATypedNumberSoClosingCannotCommitIt() async throws {
        let p = EditorPreferences()
        let (window, field) = host(SettingsNumericField(.draftRetention, value: Binding(get: { p.draftRetentionDays },
                                                                                       set: { p.draftRetentionDays = $0 }),
                                                        in: EditorPreferences.draftRetentionRange, step: 1, unit: "days"))
        defer { window.orderOut(nil) }
        let entry = try XCTUnwrap(field)
        XCTAssertEqual(entry.stringValue, "0")
        try type("30", into: entry, in: window)
        await Task.yield()
        XCTAssertEqual(p.draftRetentionDays, 0, "Typing alone never commits")
        SettingsRestoreDefaults.restore(.storage, preferences: p)
        try await Task.sleep(for: .milliseconds(50))
        window.close()
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(p.draftRetentionDays, 0, "Restoring wins over the typed number")
    }

    func testRestoringAnotherPageKeepsATypedNumber() async throws {
        let p = EditorPreferences()
        let (window, field) = host(SettingsNumericField(.draftRetention, value: Binding(get: { p.draftRetentionDays },
                                                                                       set: { p.draftRetentionDays = $0 }),
                                                        in: EditorPreferences.draftRetentionRange, step: 1, unit: "days"))
        defer { window.orderOut(nil) }
        let entry = try XCTUnwrap(field)
        try type("30", into: entry, in: window)
        await Task.yield()
        SettingsRestoreDefaults.restore(.general, preferences: p)
        window.close()
        XCTAssertEqual(p.draftRetentionDays, 30, "Only the restored page drops its typed text")
    }

    func testARetainedFieldNeverWritesItsShownTextBack() throws {
        // The value changes behind a field SwiftUI no longer updates, as in a closed window AppKit keeps.
        let box = Box()
        let (window, field) = host(SettingsNumericField(.draftRetention, value: Binding(get: { box.value }, set: { box.value = $0 }),
                                                        in: EditorPreferences.draftRetentionRange, step: 1, unit: "days"))
        defer { window.orderOut(nil) }
        XCTAssertEqual(field?.stringValue, "0")
        window.close()
        box.value = 30
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(box.value, 30, "The newer value survives the commit at quit")
        box.value = 45
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(box.value, 45)
    }

    func testTypedTextIsStillCommittedAtQuit() async throws {
        let box = Box()
        let (window, field) = host(SettingsNumericField(.draftRetention, value: Binding(get: { box.value }, set: { box.value = $0 }),
                                                        in: EditorPreferences.draftRetentionRange, step: 1, unit: "days"))
        defer { window.orderOut(nil) }
        try type("12", into: try XCTUnwrap(field), in: window)
        await Task.yield()
        XCTAssertEqual(box.value, 0)
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(box.value, 12)
        SettingsWindow.commitPendingEdits()
        XCTAssertEqual(box.value, 12)
    }
}

@MainActor private final class Box {
    var value = 0
}

private final class EnforceProbe: @unchecked Sendable {
    struct Call {
        let protected: Set<URL>
        let recheck: Set<URL>?
    }

    private let lock = NSLock()
    private var stored: [Call] = []
    var calls: [Call] { lock.withLock { stored } }
    func record(protected: Set<URL>, recheck: Set<URL>?) { lock.withLock { stored.append(Call(protected: protected, recheck: recheck)) } }
}

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var urls: [URL] { lock.withLock { stored } }
    func append(_ url: URL) { lock.withLock { stored.append(url) } }
}
