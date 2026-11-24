import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// What an export leaves behind or encodes, on every surface outside the CLI: the export sheet, the Export Queue
/// review, the saved Export Result JSON, the MCP results and the tier details. The sentences are the engine's own.
final class ExportNoticesTests: XCTestCase {
    private static let chapterNote = "MOV chapters begin with the file, so the first chapter starts at 0 instead of 0.200 s."
    private static let depthNote = "The selected profile will reduce video from 10-bit to 8-bit and chroma from 4:2:2 to 4:2:0."

    /// `swift test` runs inside Xcode's xctest, so the development helper cannot be found beside the executable.
    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil else { return }
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: helper.path) { setenv("MPCUT_FFMPEG_HELPER", helper.path, 1) }
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-notices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The H.264 fixture in Matroska with two chapters, the first beginning 0.2 s in. A MOV chapter track begins with
    /// the file, so a copy to MOV cannot keep that start, and the engine says so.
    private func chapteredMovie(in folder: URL) throws -> URL {
        let helper = try XCTUnwrap(ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"], "The FFmpeg helper is not built.")
        let listing = folder.appendingPathComponent("chapters.txt")
        let chapters = ";FFMETADATA1\n"
            + "[CHAPTER]\nTIMEBASE=1/1000\nSTART=200\nEND=600\ntitle=One\n"
            + "[CHAPTER]\nTIMEBASE=1/1000\nSTART=600\nEND=1000\ntitle=Two\n"
        try Data(chapters.utf8).write(to: listing)
        let movie = folder.appendingPathComponent("Chaptered.mkv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["-v", "error", "-nostdin", "-i", try fixture("SmartTrim-GOP", "mp4").path, "-i", listing.path,
                             "-map", "0", "-map_metadata", "1", "-map_chapters", "1", "-c", "copy", movie.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        return movie
    }

    private func plan(_ request: ExportRequest, media: [URL: MediaInfo] = [:]) throws -> ExportPlan {
        switch ExportPlanner(useSidecar: false).resolve(request, media: media) {
        case .ready(let plan, _, _): return plan
        case .unavailable(let issue, _): throw issue
        }
    }

    @MainActor
    private func ready(_ editor: EditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while editor.isBusy || !editor.tierIsCurrent, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.canEdit, editor.alert?.message ?? "The editor did not settle.")
    }

    // MARK: Wording

    func testSmartTrimWordingStatesCopiedAndEncodedVideo() {
        let second = RationalTime(numerator: 1), half = RationalTime(numerator: 1, denominator: 2)
        XCTAssertNil(ExportNotices.smartTrimSplit(copied: second, encoded: .zero), "Nothing is encoded, so there is nothing to add.")
        XCTAssertEqual(ExportNotices.smartTrimSplit(copied: second, encoded: half), "Copied video: 1.000 s · Encoded video: 0.500 s")
        XCTAssertEqual(ExportNotices.smartTrimSplit(copied: .zero, encoded: half),
                       "Copied video: 0.000 s · Encoded video: 0.500 s\nSmart Trim needs to re-encode every frame in this selection.")
        XCTAssertNil(ExportNotices.smartTrimShare(encoded: .zero, of: second))
        XCTAssertEqual(ExportNotices.smartTrimShare(encoded: RationalTime(numerator: 3, denominator: 2), of: RationalTime(numerator: 42)),
                       "Smart Trim re-encodes 1.500 s of 42.000 s.")
        XCTAssertEqual(ExportNotices.smartTrimShare(encoded: second, of: second),
                       "Smart Trim re-encodes every frame of this timeline (1.000 s).")
        XCTAssertEqual(ExportNotices.appending(["B", "C"], to: "A\nB"), "A\nB\nC", "A line the text already states is not repeated.")
    }

    // MARK: The plan

    func testACopyReportsWhatTheContainerCannotKeepInTheSummaryTheWarningsAndTheResultFile() throws {
        let folder = try scratch()
        let movie = try chapteredMovie(in: folder)
        let clips = [ClipRequest(file: movie)]
        let copy = try plan(ExportRequest(clips: clips, mode: .copy, container: "mov"))
        XCTAssertEqual(copy.copyOmissions, [Self.chapterNote], "The engine reports the moved chapter, as the CLI prints it.")

        // The summary of the sheet is unchanged. The omission follows it.
        XCTAssertEqual(copy.summary, "Copy 2.000 s of media to MOV.")
        XCTAssertEqual(copy.summary(noting: copy.copyOmissions), "Copy 2.000 s of media to MOV.\n" + Self.chapterNote)
        XCTAssertEqual(copy.summary(noting: []), copy.summary)
        XCTAssertEqual(copy.reportedWarnings, [Self.chapterNote])
        XCTAssertEqual(try copy.mcpNotes()["warnings"] as? [String], [Self.chapterNote])
        XCTAssertEqual(copy.queueReview(omissions: copy.copyOmissions), "Copy 2.000 s of media to MOV.\n" + Self.chapterNote)

        // The saved Export Result JSON carries it under plan.warnings.
        let output = folder.appendingPathComponent("Copy.mov")
        let result = try copy.resultFile(for: output, cutMap: ExportCutMap(edit: copy.edit, clips: clips))
        try Data().write(to: output)
        XCTAssertTrue(result.completionMessage(for: output).contains(result.url.lastPathComponent))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        XCTAssertEqual((saved["plan"] as? [String: Any])?["warnings"] as? [String], [Self.chapterNote])

        // Matroska keeps the chapters where they are: a plain copy has nothing to add anywhere.
        let kept = try plan(ExportRequest(clips: clips, mode: .copy, container: "mkv"))
        XCTAssertEqual(kept.copyOmissions, [])
        XCTAssertEqual(kept.reportedWarnings, [])
        XCTAssertNil(try kept.mcpNotes()["warnings"], "A plain copy has no warnings field, as in the CLI.")
        XCTAssertNil(kept.queueReview(omissions: []), "A plain copy that keeps everything adds no review.")
    }

    func testASoundOnlyCopyReportsTheChaptersWAVCannotHold() throws {
        // One second of PCM in Matroska with two chapters. WAV has no place for them.
        let folder = try scratch()
        let helper = try XCTUnwrap(ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"], "The FFmpeg helper is not built.")
        let listing = folder.appendingPathComponent("chapters.txt")
        try Data(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=500\nEND=1000\ntitle=Two\n".utf8)
            .write(to: listing)
        let sound = folder.appendingPathComponent("Chaptered.mka")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
                             "-i", listing.path, "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1",
                             "-c:a", "pcm_s16le", sound.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let note = "Chapters cannot be written to WAV. 2 chapters are not copied."
        let copy = try plan(ExportRequest(clips: [.init(file: sound)], mode: .copy, container: "wav"))
        XCTAssertEqual(copy.mode, .copy)
        XCTAssertEqual(copy.reportedWarnings, [note])
        XCTAssertEqual(try copy.mcpNotes()["warnings"] as? [String], [note])
        XCTAssertEqual(copy.queueReview(omissions: copy.copyOmissions), copy.summary + "\n" + note)
        XCTAssertNil(try MCPRangePlan(destination: "/tmp/Chaptered-001.wav", plan: copy).json()["copied_video_duration"],
                     "A sound-only range reports no picture.")
    }

    func testAReencodeReportsItsWarningsAndAudioActions() throws {
        // Ten-bit 4:2:2 ProRes written as H.264 loses depth and chroma. The plan says so.
        let prores = try fixture("ProRes-2997", "mov")
        let reduced = try plan(ExportRequest(clips: [.init(file: prores)], mode: .encode, container: "mp4"))
        XCTAssertEqual(reduced.reportedWarnings, [Self.depthNote])
        XCTAssertEqual(reduced.copyOmissions, [], "An encode reports its own warnings.")
        XCTAssertTrue(reduced.summary.hasSuffix(Self.depthNote), reduced.summary)
        XCTAssertEqual(reduced.queueReview(omissions: []), reduced.summary, "The queue shows an encode as the sheet does.")
        let notes = try reduced.mcpNotes()
        XCTAssertEqual(notes["warnings"] as? [String], [Self.depthNote])
        XCTAssertEqual((notes["audio_actions"] as? [[String: Any]])?.count, 0)

        // A lossless track that cannot be copied is written as PCM in MOV. Its row states the codec, the word length
        // and the reason, for the sheet, the queue and MCP alike.
        let flac = try fixture("Held-H264-FLAC", "mkv")
        let converted = try plan(ExportRequest(clips: [.init(file: flac)], mode: .encode, container: "mov"))
        let actions = try XCTUnwrap(try converted.mcpNotes()["audio_actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?["track"] as? Int, 1)
        XCTAssertEqual(actions.first?["action"] as? String, "pcm")
        XCTAssertEqual(actions.first?["codec"] as? String, "pcm_s16le")
        XCTAssertEqual(actions.first?["bit_depth"] as? Int, 16)
        XCTAssertTrue((actions.first?["reason"] as? String)?.contains("written as PCM") == true, String(describing: actions.first))
        XCTAssertTrue(converted.summary.contains("Audio: Track 1: PCM (16-bit)"), converted.summary)
        let row = try MCPRangePlan(destination: "/tmp/Clip-001.mov", plan: converted).json()
        XCTAssertEqual(row["mode"] as? String, "encode")
        XCTAssertEqual((row["audio_actions"] as? [[String: Any]])?.first?["bit_depth"] as? Int, 16)
        XCTAssertEqual(row["summary"] as? String, converted.summary)

        // An AAC track of a movie re-encode states its bit rate.
        let noisy = try fixture("Pause-Noisy", "mov")
        var request = ExportRequest(clips: [.init(file: noisy)], mode: .encode, container: "mp4")
        request.audio = .aac
        let aac = try XCTUnwrap(try plan(request).mcpNotes()["audio_actions"] as? [[String: Any]])
        XCTAssertEqual(aac.map { $0["codec"] as? String }, ["aac", "aac"])
        XCTAssertEqual(aac.map { $0["bit_rate"] as? Int }, [96_000, 96_000])
    }

    // MARK: The export sheet

    @MainActor
    func testTheExportSheetShowsWhatACopyLeavesBehind() async throws {
        _ = NSApplication.shared
        let movie = try chapteredMovie(in: try scratch())
        let media = try CutEngine(useSidecar: false).inspect(movie, keyframes: true)
        let clips = [ClipRequest(file: movie)]
        let choices = ExportContainerChoices(source: media, clips: clips, preferred: "mov", cancelled: { false })
        let panel = NSSavePanel()
        var options = ExportSheetOptions()
        options.mode = .copy
        options.copyContainer = "mov"
        let control = ExportFormatControl(panel: panel, options: options, copyContainers: choices,
                                         clips: clips, media: [movie: media], useSidecar: false,
                                         changed: { _, _ in }, directoryChanged: { _ in })
        defer { control.stopChecking() }
        let deadline = ContinuousClock.now + .seconds(10)
        while control.selected == nil, !control.isUnavailable, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .packets(_, .copy, .all) = control.selected else {
            return XCTFail("The sheet did not plan a copy: \(control.failure?.message ?? "no plan")")
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let texts = views(try XCTUnwrap(panel.accessoryView)).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains("Copy 2.000 s of media to MOV.\n" + Self.chapterNote), texts.description)
    }

    // MARK: The Export Queue

    @MainActor
    func testTheQueueReviewShowsSmartTrimDurationsAndStaysQuietForAPlainCopy() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        let source = try fixture("SmartTrim-GOP", "mp4")
        editor.importFiles([source])
        try await ready(editor)

        // The whole clip is a plain copy: nothing is added to the review, as before.
        editor.selectRange(0, 2)
        editor.addMarkedRange()
        var options = ExportSheetOptions()
        options.copyContainer = ""
        options.mode = .copy
        guard case .success(let plain) = await editor.reviewQueuedRanges(options: options) else { return XCTFail("The whole clip did not plan.") }
        XCTAssertNil(plain)

        // A range that starts inside the first picture group is copied from its next keyframe. The review says how much.
        let whole = try XCTUnwrap(editor.queuedRanges.first?.id)
        editor.removeQueuedRange(whole)
        editor.selectRange(0.28, 2)
        editor.addMarkedRange()
        options.mode = .smart
        let range = try XCTUnwrap(editor.readyQueuedRanges.first)
        let expected = try plan(ExportRequest(clips: range.clips, mode: .smart), media: range.media)
        XCTAssertGreaterThan(try expected.edit.encodedVideoDuration(for: .smart), .zero)
        XCTAssertGreaterThan(try expected.edit.copiedVideoDuration(for: .smart), .zero)
        guard case .success(let split?) = await editor.reviewQueuedRanges(options: options) else { return XCTFail("Smart Trim added no review.") }
        XCTAssertTrue(split.hasPrefix("SmartTrim-GOP"), split)
        XCTAssertTrue(split.hasSuffix("\nCopied video: 1.000 s · Encoded video: 0.720 s"), split)
        XCTAssertEqual(split.split(separator: "\n").last.map(String.init), expected.summary)

        // A second range with no keyframe inside it is encoded whole, and its entry says so.
        editor.selectRange(0.28, 0.8)
        editor.addMarkedRange()
        guard case .success(let both?) = await editor.reviewQueuedRanges(options: options) else { return XCTFail("Smart Trim added no review.") }
        let entries = both.components(separatedBy: "\n\n")
        XCTAssertEqual(entries.count, 2, both)
        XCTAssertTrue(entries[0].hasSuffix("Copied video: 1.000 s · Encoded video: 0.720 s"), both)
        XCTAssertTrue(entries[1].hasSuffix("Copied video: 0.000 s · Encoded video: 0.520 s\nSmart Trim needs to re-encode every frame in this selection."), both)

        // A re-encode shows what the sheet shows: codec, quality, size, audio and warnings.
        options.mode = .encode
        guard case .success(let encoded?) = await editor.reviewQueuedRanges(options: options) else { return XCTFail("Re-encode added no review.") }
        XCTAssertTrue(encoded.contains("H.264 · Balanced · "), encoded)
        XCTAssertTrue(encoded.contains("Audio: No audio tracks"), encoded)
    }

    @MainActor
    func testTheQueueReviewShowsWhatACopyLeavesBehind() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.importFiles([try chapteredMovie(in: try scratch())])
        try await ready(editor)
        editor.selectRange(0, 2)
        editor.addMarkedRange()
        var options = ExportSheetOptions()
        options.mode = .copy
        options.copyContainer = "mov"
        guard case .success(let review?) = await editor.reviewQueuedRanges(options: options) else {
            return XCTFail("The copy that moves a chapter added no review.")
        }
        // The file name of the range, the summary of the sheet, then the omission.
        let lines = review.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, review)
        XCTAssertTrue(lines[0].hasPrefix("Chaptered") && lines[0].hasSuffix(".mov"), review)
        XCTAssertEqual(Array(lines.dropFirst()), ["Copy 2.000 s of media to MOV.", Self.chapterNote])
        options.copyContainer = "mkv"
        guard case .success(let kept) = await editor.reviewQueuedRanges(options: options) else { return XCTFail("The Matroska copy did not plan.") }
        XCTAssertNil(kept, "Matroska keeps the chapters, so there is nothing to review.")
    }

    func testTheMulticamQueueReviewShowsSmartTrimDurations() throws {
        let movie = try fixture("Pause-Noisy", "mov")
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(movie)
        // Keyframes fall on whole seconds. The range starts half a second into the first picture group.
        let range = MulticamRange(from: RationalTime(numerator: 1, denominator: 2), to: RationalTime(numerator: 3))
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let project = MulticamProject(referenceAngle: "a", range: MulticamRange(from: .zero, to: media.duration),
                                      angles: [.init(id: "a", file: movie.path, audioStream: stream)], audio: .follow,
                                      switches: [.init(at: .zero, angle: "a")])
        let entry = MulticamQueuedRange(name: "Take", range: range, project: project, media: ["a": media])
        var choices = MulticamExportChoices(entry: .multicamQueue, preferred: .smart)
        choices.settle()
        XCTAssertEqual(choices.effectiveMode, .smart)
        let review = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try MulticamBulkExport.review([entry], choices: choices, organization: .init()).get()
        }
        XCTAssertTrue(review.contains("\nCopied video: 2.000 s · Encoded video: 0.500 s\n"), review)
        XCTAssertTrue(review.contains("1 audio track"), review)
    }

    // MARK: MCP

    @MainActor
    private func finished(_ receipt: [String: Any]?, owner: String, in jobs: MCPLiveOutputJobs) async throws -> [String: Any] {
        let id = try XCTUnwrap(receipt?["job_id"] as? String)
        let limit = ContinuousClock.now + .seconds(30)
        while .now < limit {
            let state = try jobs.status(owner: owner, id: id, cancel: false)
            if !["running", "cancelling"].contains(state["state"] as? String ?? "") {
                XCTAssertEqual(state["state"] as? String, "succeeded", String(describing: state))
                return try XCTUnwrap(state["result"] as? [String: Any], String(describing: state))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MCPCommandError("timeout", "Timed out waiting for the output job.")
    }

    @MainActor
    func testMCPPlanRenderAndQueuePlanReportWhatACopyLeavesBehind() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        // The outputs go to their own folder, away from the source.
        let folder = try scratch()
        editor.importFiles([try chapteredMovie(in: try scratch())])
        try await ready(editor)
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let receipt = try await sessions.mcpOutputs(tool: tool, arguments: arguments.merging(["project_handle": session.mcpHandle]) { $1 },
                                                        session: session, checkAccess: {})
            return try await finished(receipt, owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        }

        // The plan of a copy to MOV lists the moved chapter under warnings. A copy to Matroska has no such field.
        let moved = try await call("export_editor_project_plan", ["output": folder.appendingPathComponent("Movie.mov").path, "mode": "copy"])
        XCTAssertEqual(moved["eligible"] as? Bool, true)
        XCTAssertEqual(moved["summary"] as? String, "Copy 2.000 s of media to MOV.")
        XCTAssertEqual(moved["warnings"] as? [String], [Self.chapterNote])
        let kept = try await call("export_editor_project_plan", ["output": folder.appendingPathComponent("Movie.mkv").path, "mode": "copy"])
        XCTAssertEqual(kept["eligible"] as? Bool, true)
        XCTAssertNil(kept["warnings"])

        // The render reports it too, and the file is written.
        let rendered = folder.appendingPathComponent("Rendered.mov")
        let render = try await call("export_editor_project_render", ["output": rendered.path, "mode": "copy"])
        XCTAssertEqual(render["warnings"] as? [String], [Self.chapterNote])
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendered.path))

        // A queued range reports its plan under range_plans.
        editor.selectRange(0, 2)
        editor.addMarkedRange()
        let queued = try await call("export_queue_plan", ["output": folder.path, "container": "mov", "mode": "copy"])
        let rows = try XCTUnwrap(queued["range_plans"] as? [[String: Any]], String(describing: queued))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["destination"] as? String, (queued["destinations"] as? [String])?.first)
        XCTAssertEqual(rows.first?["mode"] as? String, "copy")
        XCTAssertEqual(rows.first?["tracks"] as? String, "all")
        XCTAssertEqual(rows.first?["container"] as? String, "mov")
        XCTAssertEqual(rows.first?["warnings"] as? [String], [Self.chapterNote])
        XCTAssertEqual(rows.first?["summary"] as? String, "Copy 2.000 s of media to MOV.")
        // Durations are exact rationals, as in every plan.
        XCTAssertEqual((rows.first?["encoded_video_duration"] as? [String: Any])?["numerator"] as? Int, 0)
        XCTAssertEqual((rows.first?["copied_video_duration"] as? [String: Any])?["numerator"] as? Int, 2)
        XCTAssertEqual((rows.first?["copied_video_duration"] as? [String: Any])?["denominator"] as? Int, 1)
        XCTAssertNil(rows.first?["audio_actions"], "A copy converts no sound.")
    }

    @MainActor
    func testMCPQueuePlanReportsHowMuchSmartTrimEncodes() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        let folder = try scratch()
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let receipt = try await sessions.mcpOutputs(tool: tool, arguments: arguments.merging(["project_handle": session.mcpHandle]) { $1 },
                                                        session: session, checkAccess: {})
            return try await finished(receipt, owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        }

        // A queued range that starts inside a picture group: the row says how much Smart Trim copies and encodes.
        editor.importFiles([try fixture("SmartTrim-GOP", "mp4")])
        try await ready(editor)
        editor.selectRange(0.28, 2)
        editor.addMarkedRange()
        let queued = try await call("export_queue_plan", ["output": folder.path, "container": "mov", "mode": "smart"])
        let row = try XCTUnwrap((queued["range_plans"] as? [[String: Any]])?.first, String(describing: queued))
        XCTAssertEqual(row["mode"] as? String, "smart")
        XCTAssertEqual(row["summary"] as? String, "Copied video: 1.000 s · Encoded video: 0.720 s")
        let copied = try XCTUnwrap(row["copied_video_duration"] as? [String: Any])
        let encoded = try XCTUnwrap(row["encoded_video_duration"] as? [String: Any])
        XCTAssertEqual([copied["numerator"] as? Int, copied["denominator"] as? Int], [1, 1])
        XCTAssertEqual([encoded["numerator"] as? Int, encoded["denominator"] as? Int], [18, 25])
        XCTAssertEqual(row["warnings"] as? [String], [])
    }

    @MainActor
    func testMCPReencodePlanReportsItsWarningsAndAudioActionsAtTheTopLevel() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        let folder = try scratch()
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let receipt = try await sessions.mcpOutputs(tool: tool, arguments: arguments.merging(["project_handle": session.mcpHandle]) { $1 },
                                                        session: session, checkAccess: {})
            return try await finished(receipt, owner: session.mcpHandle, in: sessions.mcpOutputJobs)
        }

        // Ten-bit 4:2:2 ProRes re-encoded as H.264: the plan's warning is at the top level too.
        editor.importFiles([try fixture("ProRes-2997", "mov")])
        try await ready(editor)
        let encode = try await call("export_editor_project_plan", ["output": folder.appendingPathComponent("Movie.mp4").path, "mode": "encode"])
        XCTAssertEqual(encode["eligible"] as? Bool, true)
        XCTAssertEqual(encode["warnings"] as? [String], [Self.depthNote])
        XCTAssertEqual((encode["plan"] as? [String: Any])?["warnings"] as? [String], [Self.depthNote])
        XCTAssertNotNil(encode["audio_actions"] as? [Any])
        XCTAssertTrue((encode["summary"] as? String)?.hasSuffix(Self.depthNote) == true)
    }

    // MARK: Tier details

    @MainActor
    func testTheTierDetailsSayHowMuchSmartTrimEncodes() async throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.tierPrompt = { _, answer in answer(.init(answer: .proceed)) }
        editor.importFiles([try fixture("SmartTrim-GOP", "mp4")])
        try await ready(editor)
        XCTAssertEqual(editor.tierState?.tier, .trueLossless)
        let whole = await editor.smartTrimShare()
        XCTAssertNil(whole, "A True Lossless timeline encodes nothing.")

        // Removing the first seven frames leaves a cut inside the picture group: the tier is Lossless, and Smart Trim
        // encodes up to the next keyframe.
        editor.seek(7.0 / 25)
        editor.split()
        try await ready(editor)
        let left = try XCTUnwrap(editor.timelineClips.first?.id)
        editor.byHand { editor.deleteClip(left) }
        try await ready(editor)
        XCTAssertEqual(editor.tierState?.tier, .lossless)
        let share = await editor.smartTrimShare()
        XCTAssertEqual(share, "Smart Trim re-encodes 0.720 s of 1.720 s.")
        // The badge and its help keep the documented tier name and summary.
        XCTAssertEqual(editor.tierState?.name, "Lossless")
    }
}
