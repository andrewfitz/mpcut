import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPAnalysisTests: XCTestCase {
    func testReadAndRejectConditionsForEmptyEditor() async throws {
        let preferences = EditorPreferences()
        let sessions = ProjectSessions(preferences: preferences)
        let project = ProjectSession(id: UUID(), preferences: preferences)
        let result = try await sessions.mcpAnalysis(tool: "analysis_state", arguments: [:], session: project) {}
        XCTAssertEqual(result?["kind"] as? String, "sequence")
        XCTAssertEqual((result?["sources"] as? [String: Any])?["total"] as? Int, 0)
        do {
            _ = try await sessions.mcpAnalysis(tool: "scan_analysis", arguments: ["kind": "silence"], session: project) {}
            XCTFail("An empty sequence cannot start an audio scan")
        } catch let issue as MCPCommandError {
            XCTAssertEqual(issue.code, "analysis_unavailable")
        }
        do {
            _ = try await sessions.mcpAnalysis(tool: "analysis_state", arguments: ["limit": true], session: project) {}
            XCTFail("JSON booleans must not be accepted as page lengths")
        } catch let issue as MCPCommandError {
            XCTAssertEqual(issue.code, "invalid_arguments")
        }
        project.isMulticam = true
        let multicam = try await sessions.mcpAnalysis(tool: "analysis_state", arguments: [:], session: project) {}
        XCTAssertEqual(multicam?["kind"] as? String, "multicam")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(multicam ?? [:]))
    }

    func testScanReviewAndShortenUseNativeHistory() async throws {
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs)
        let project = ProjectSession(id: UUID(), preferences: prefs)
        let editor = project.editor
        defer { editor.endSession() }
        let input = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([input])
        let deadline = ContinuousClock.now + .seconds(15)
        while !editor.canEdit && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(editor.canEdit)
        func call(_ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
            let result = try await sessions.mcpAnalysis(tool: name, arguments: args, session: project) {}
            return try XCTUnwrap(result)
        }
        _ = try await call("configure_silence", ["thresholdDB": -45, "minimumPause": 0.5, "leavePause": 0.1])
        let scan = try await call("scan_analysis", ["kind": "silence"])
        let job = try XCTUnwrap(scan["job"] as? String)
        while !editor.pauseAnalysisReady && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let terminal = try await call("analysis_job_status", ["job": job])
        XCTAssertEqual(terminal["status"] as? String, "succeeded")
        XCTAssertEqual(terminal["progress"] as? Double, 1)
        let source = try XCTUnwrap(editor.analysisSourceMedia.first)
        let audio = try XCTUnwrap(source.value.audio.first)
        let envelope = try await call("get_waveform", ["source": source.key.uuidString, "stream": audio.stream.index,
                                                      "columns": 16, "from": "0", "to": "1"])
        XCTAssertEqual((envelope["low"] as? [Float])?.count, 16)
        XCTAssertLessThan(try XCTUnwrap((envelope["low"] as? [Float])?.min()), 0)
        let peaks = try await call("get_waveform_peaks", ["source": source.key.uuidString, "stream": audio.stream.index,
                                                         "columns": 16, "from": "0", "to": "1"])
        XCTAssertEqual(peaks["source"] as? String, source.key.uuidString)
        XCTAssertEqual(peaks["stream"] as? Int, audio.stream.index)
        XCTAssertEqual((peaks["peaks"] as? [Any])?.count, 16)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(peaks))
        let result = try await call("list_pauses")
        let pauses = try XCTUnwrap(result["items"] as? [[String: Any]])
        let id = try XCTUnwrap(pauses.first?["id"] as? String)
        _ = try await call("review_pause", ["action": "protect", "pause": id])
        XCTAssertEqual(editor.currentPause?.isProtected, true)
        _ = try await call("review_pause", ["action": "unprotect", "pause": id])
        XCTAssertEqual(editor.currentPause?.isProtected, false)
        let originalDuration = editor.duration
        _ = try await call("apply_pauses", ["mode": "queue"])
        XCTAssertFalse(editor.queuedRanges.isEmpty)
        let shortened = try await call("apply_pauses", ["mode": "shorten"])
        XCTAssertEqual(shortened["changed"] as? Bool, true)
        XCTAssertEqual(shortened["historyRetained"] as? Bool, true)
        XCTAssertLessThan(editor.duration, originalDuration)
        editor.undo()
        XCTAssertEqual(editor.duration, originalDuration)
        do {
            _ = try await call("review_pause", ["action": "seek", "pause": id])
            XCTFail("A pause ID from an earlier revision should expire even after undo restores the same range")
        } catch let issue as MCPCommandError {
            XCTAssertEqual(issue.code, "analysis_unavailable")
        }
    }

    func testDisablingControlCancelsOnlyOwnedNativeMulticamScan() async throws {
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs)
        let project = ProjectSession(id: UUID(), preferences: prefs)
        project.isMulticam = true
        let editor = project.multicam
        defer { editor.reset() }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let camera = MulticamEditorModel.SourceDraft(source: .init(id: "wide", file: url.path, audioStream: stream), media: media)
        editor.confirmSetup(drafts: [camera], opening: "wide", audio: .follow)
        let started = try await sessions.mcpAnalysis(tool: "scan_analysis", arguments: ["kind": "silence"], session: project) {}
        let receipt = try sessions.mcpAnalysisJobs.lookup(started?["job"] as? String, session: project)
        XCTAssertEqual(receipt.state, "running")
        editor.scanAnalysis(.scenes)
        sessions.mcpAnalysisJobs.disable()
        XCTAssertEqual(receipt.state, "cancelled")
        XCTAssertFalse(editor.analysis.isScanning(.silence))
        XCTAssertTrue(editor.analysis.isScanning(.scenes))
        await sessions.mcpAnalysisJobs.cancelAndWaitForJobs()
        XCTAssertFalse(sessions.mcpAnalysisJobs.hasRunningJobs)
        XCTAssertTrue(editor.analysis.isScanning(.scenes) || editor.analysis.sceneReports["wide"] != nil)
    }

    func testSequenceThresholdTargetsNamedSourceAndRetiresChangedScan() async throws {
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs)
        let project = ProjectSession(id: UUID(), preferences: prefs)
        let editor = project.editor
        defer { editor.endSession() }
        let quiet = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let noisy = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([quiet, noisy])
        let deadline = ContinuousClock.now + .seconds(15)
        while !editor.canEdit && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let noisyID = try XCTUnwrap(editor.analysisSourceMedia.first { $0.value.url == noisy }?.key)
        XCTAssertNotEqual(editor.analysisPlayheadSourceID, noisyID)
        func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            let result = try await sessions.mcpAnalysis(tool: name, arguments: args, session: project) {}
            return try XCTUnwrap(result)
        }
        _ = try await call("configure_silence", ["source": noisyID.uuidString, "thresholdDB": -45])
        XCTAssertNil(editor.manualThresholdDB)
        XCTAssertEqual(editor.analysisThreshold(for: noisyID, track: 0), -45)
        let started = try await call("scan_analysis", ["kind": "silence"])
        let job = try XCTUnwrap(started["job"] as? String)
        _ = try await call("configure_silence", ["source": noisyID.uuidString, "thresholdDB": -50])
        let terminal = try await call("analysis_job_status", ["job": job])
        XCTAssertEqual(terminal["status"] as? String, "cancelled")
        XCTAssertEqual(editor.analysisThreshold(for: noisyID, track: 0), -50)
    }

    func testSceneAndSidecarReceiptsDescribePublishedResults() async throws {
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs)
        let project = ProjectSession(id: UUID(), preferences: prefs)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            project.editor.endSession()
            try? FileManager.default.removeItem(at: folder)
        }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let copy = folder.appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: copy)
        project.editor.importFiles([copy])
        let deadline = ContinuousClock.now + .seconds(15)
        while !project.editor.canEdit && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let media = try XCTUnwrap(project.editor.analysisSourceMedia.first)
        let source = media.key.uuidString
        func call(_ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
            let result = try await sessions.mcpAnalysis(tool: name, arguments: args, session: project) {}
            return try XCTUnwrap(result)
        }
        func waitForJob(_ result: [String: Any]) async throws -> [String: Any] {
            let job = try XCTUnwrap(result["job"] as? String)
            let receipt = try sessions.mcpAnalysisJobs.lookup(job, session: project)
            while receipt.state == "running" && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            return try await call("analysis_job_status", ["job": job])
        }
        let scenes = try await waitForJob(call("scan_analysis", ["kind": "scenes"]))
        XCTAssertEqual(scenes["status"] as? String, "succeeded")
        XCTAssertEqual(scenes["sources"] as? [String], [source])
        let listed = try await call("list_scenes", ["source": source, "limit": 1])
        let first = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first)
        let view = try XCTUnwrap(first["view"] as? Int)
        _ = try await call("rename_view", ["source": source, "view": view, "name": "  Wide shot  "])
        let saved = try await waitForJob(call("save_analysis_sidecars"))
        XCTAssertEqual(saved["status"] as? String, "succeeded")
        XCTAssertEqual(saved["outputs"] as? [String], [AnalysisSidecar.url(for: copy).path])
        let reopened = try XCTUnwrap(AnalysisSidecar(media: media.value).sceneReport(for: media.value))
        XCTAssertEqual(reopened.views.first { $0.view == view }?.name, "Wide shot")

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: copy.path)
        do {
            _ = try await call("list_scenes", ["source": source])
            XCTFail("A changed recording should invalidate its live scene report")
        } catch let issue as MCPCommandError {
            XCTAssertEqual(issue.code, "source_changed")
        }
    }

    func testMulticamPauseReviewAndRoomToneInRepeatedAssembly() async throws {
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: prefs)
        let project = ProjectSession(id: UUID(), preferences: prefs)
        project.isMulticam = true
        let model = project.multicam
        defer { model.reset() }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(url)
        let streams = media.audio.map(\.stream.index)
        XCTAssertEqual(streams.count, 2)
        let first = try XCTUnwrap(streams.first), second = try XCTUnwrap(streams.last)
        let camera = MulticamEditorModel.SourceDraft(source: .init(id: "wide", file: url.path, audioStream: first), media: media)
        model.confirmSetup(drafts: [camera], opening: "wide", audio: .follow)
        let over = RationalTime(numerator: 5, denominator: 2)
        let whole = try XCTUnwrap(model.project?.range)
        XCTAssertTrue(model.edit {
            $0.assembly = [whole, whole]
            $0.switches.append(.init(at: over, angle: "wide", audio: .init(source: "wide", stream: second)))
        })
        func call(_ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
            let result = try await sessions.mcpAnalysis(tool: name, arguments: args, session: project) {}
            return try XCTUnwrap(result)
        }
        _ = try await call("configure_silence", ["minimumPause": 0.4, "leavePause": 0.1, "thresholdDB": -45])
        let started = try await call("scan_analysis", ["kind": "silence"])
        let receipt = try sessions.mcpAnalysisJobs.lookup(started["job"] as? String, session: project)
        let deadline = ContinuousClock.now + .seconds(15)
        while receipt.state == "running" && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(receipt.state, "succeeded")
        let listed = try await call("list_pauses")
        let rows = try XCTUnwrap(listed["items"] as? [[String: Any]])
        let repeatPause = try XCTUnwrap(rows.first { ($0["occurrence"] as? Int) == 1 && $0["removal"] is [String: Any] })
        let id = try XCTUnwrap(repeatPause["id"] as? String)
        _ = try await call("review_pause", ["pause": id, "action": "seek"])
        XCTAssertEqual(model.selectedOccurrence, 1)
        let opened = try await call("review_pause", ["pause": id, "action": "preview"])
        XCTAssertEqual(opened["reviewOpen"] as? Bool, true)
        let kept = try await call("review_pause", ["pause": id, "action": "protect"])
        XCTAssertEqual(kept["reviewOpen"] as? Bool, false)
        XCTAssertEqual(model.multicamPausePlan.filter(\.isProtected).map(\.id.occurrence), [0, 1])
        _ = try await call("review_pause", ["pause": id, "action": "unprotect"])

        guard let duration = try? whole.to.subtracting(whole.from) else { return XCTFail("Invalid fixture range") }
        model.assemblySelection = AudioSpan(from: try duration.adding(.init(numerator: 3, denominator: 4)),
                                           to: try duration.adding(.init(numerator: 9, denominator: 4)))
        let scoped = try await call("list_pauses")
        let selected = try XCTUnwrap(scoped["items"] as? [[String: Any]])
        XCTAssertEqual(selected.compactMap { $0["occurrence"] as? Int }, [1])
        _ = try await call("apply_pauses", ["mode": "queue"])
        XCTAssertFalse(model.queuedRanges.isEmpty)
        XCTAssertTrue(model.queuedRanges.allSatisfy { $0.range.from >= .init(numerator: 3, denominator: 4) &&
            $0.range.to <= .init(numerator: 9, denominator: 4) })
        _ = try await call("apply_pauses", ["mode": "shorten"])
        XCTAssertEqual(model.ranges.first, whole)
        XCTAssertLessThan(try XCTUnwrap(model.assemblyRangeEnds.last), try duration.adding(duration))
        model.undo()
        XCTAssertEqual(model.ranges, [whole, whole])

        model.assemblySelection = AudioSpan(from: try duration.adding(.init(numerator: 9, denominator: 4)),
                                           to: try duration.adding(.init(numerator: 11, denominator: 4)))
        _ = try await call("use_room_tone")
        XCTAssertNil(model.assemblySelection)
        XCTAssertNil(model.analysis.pauseThreshold)
        XCTAssertNotNil(model.analysis.threshold(for: .init(source: "wide", stream: first)))
        XCTAssertNotNil(model.analysis.threshold(for: .init(source: "wide", stream: second)))
    }

    func testRevocationPrecedesAnalysis() async {
        let preferences = EditorPreferences()
        let sessions = ProjectSessions(preferences: preferences)
        let project = ProjectSession(id: UUID(), preferences: preferences)
        do {
            _ = try await sessions.mcpAnalysis(tool: "scan_analysis", arguments: ["kind": "silence"], session: project) {
                throw MCPCommandError("disabled", "Control disabled.")
            }
            XCTFail("Revocation should prevent execution")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "disabled")
        } catch { XCTFail(error.localizedDescription) }
    }
}
