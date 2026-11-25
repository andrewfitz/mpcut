import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class QueueSnapshotTests: XCTestCase {
    func testMCPInspectsAndRevisesFrozenSequenceEntries() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(15)
        while editor.isBusy, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.isBusy)
        let id = try XCTUnwrap(editor.mcpClipIDs.first)
        _ = try await editor.mcpCommand(tool: "timeline_item_split",
                                       arguments: ["space": "source", "time": "1", "occurrence": id.uuidString], validateCommit: {})

        func queue(_ action: String, _ args: [String: Any] = [:]) async throws -> [[String: Any]] {
            let result = try await sessions.mcpOutputs(tool: action, arguments: args, session: session, checkAccess: {})
            return try XCTUnwrap(result?["ranges"] as? [[String: Any]])
        }

        editor.selectRange(0.2, 1.6)
        let added = try await queue("export_queue_range_add")
        let original = try XCTUnwrap(added.first)
        let entryID = try XCTUnwrap(original["id"] as? String)
        let before = try XCTUnwrap(original["items"] as? [[String: String]])
        XCTAssertEqual(before.map { $0["file"] }, [source.path, source.path])
        XCTAssertEqual(before.map { $0["from"] }, ["1/5", "1"])
        XCTAssertEqual(before.map { $0["to"] }, ["1", "8/5"])
        editor.undo()
        XCTAssertEqual(editor.mcpClipIDs.count, 1)
        let inspected = try await queue("export_queue_list")
        XCTAssertEqual(inspected.first?["items"] as? [[String: String]], before)

        let renamed = try await queue("export_queue_entry_rename", ["id": entryID, "name": " Interview "])
        XCTAssertEqual(renamed.first?["name"] as? String, "Interview")
        XCTAssertEqual(renamed.first?["items"] as? [[String: String]], before)

        editor.selectRange(0.4, 1.6)
        do {
            _ = try await queue("export_queue_entry_revise", ["id": entryID, "mode": "extend"])
            XCTFail("Expected an extension to contain the original range.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_extension")
        }
        let retained = try await queue("export_queue_list")
        XCTAssertEqual(retained.first?["items"] as? [[String: String]], before)

        editor.selectRange(0, 2)
        let extended = try await queue("export_queue_entry_revise", ["id": entryID, "mode": "extend"])
        XCTAssertEqual(extended.first?["id"] as? String, entryID)
        XCTAssertEqual(extended.first?["name"] as? String, "Interview")
        XCTAssertEqual(extended.first?["from"] as? String, "0")
        XCTAssertEqual(extended.first?["to"] as? String, "2")
        XCTAssertEqual((extended.first?["items"] as? [[String: String]])?.count, 1)
        XCTAssertFalse(editor.canAddMarkedRange)

        editor.selectRange(0.4, 1.2)
        editor.showBulkQueue()
        XCTAssertTrue(editor.isBusy)
        XCTAssertTrue(editor.canReviseQueuedRange)
        let replaced = try await queue("export_queue_entry_revise", ["id": entryID, "mode": "replace"])
        XCTAssertEqual(replaced.first?["id"] as? String, entryID)
        XCTAssertEqual(replaced.first?["name"] as? String, "Interview")
        let items = try XCTUnwrap(replaced.first?["items"] as? [[String: String]])
        XCTAssertEqual(items, [["kind": "clip", "file": source.path, "from": "2/5", "to": "6/5"]])
        XCTAssertFalse(editor.canReviseQueuedRange)
    }

    func testMulticamInspectionUsesCapturedRecordingOffsetsAndOrder() async throws {
        func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
        func r(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: t(from), to: t(to)) }

        var wide = MulticamSource(id: "wide", file: "/wide.mov", audioStream: 2)
        wide.coverage = r(0, 6)
        wide.additionalRecordings = [
            .init(id: "wide-b", file: "/wide-b.mov", offset: t(7), audioStream: 3, coverage: r(8, 15))
        ]
        let project = MulticamProject(referenceAngle: "wide", range: r(0, 15), angles: [wide], audio: .follow,
                                      switches: [.init(at: .zero, angle: "wide")])
        let entry = MulticamQueuedRange(name: "Take", range: r(4, 10), project: project, media: [:])
        let items = try entry.snapshotItems()
        XCTAssertEqual(items.map(\.kind), ["angle", "gap", "angle", "audio", "audio"])
        XCTAssertEqual(items.map(\.file), ["/wide.mov", "Gap", "/wide-b.mov", "/wide.mov", "/wide-b.mov"])
        XCTAssertEqual(items.map(\.from), [t(4), nil, t(1), t(4), t(1)])
        XCTAssertEqual(items.map(\.to), [t(6), nil, t(3), t(6), t(3)])
        XCTAssertEqual(items.map(\.output), [r(0, 2), r(2, 4), r(4, 6), r(0, 2), r(4, 6)])
        XCTAssertEqual(items.compactMap(\.stream), [2, 3])
    }

    func testMulticamMixSnapshotKeepsBothLanesInCapturedOrder() throws {
        let range = MulticamRange(from: .zero, to: .init(numerator: 2))
        let wide = MulticamSource(id: "wide", file: "/wide.mov", audioStream: 2)
        let close = MulticamSource(id: "close", file: "/close.mov", audioStream: 3)
        var project = MulticamProject(referenceAngle: "wide", range: range, angles: [wide, close], audio: .mix,
                                     switches: [.init(at: .zero, angle: "wide")],
                                     mixLanes: [
                                         .init(id: "close-mic", target: .camera("close"), label: "Close mic", colorSlot: 3),
                                         .init(id: "wide-mic", target: .camera("wide"), label: "Wide mic", colorSlot: 1),
                                     ])
        let entry = MulticamQueuedRange(name: "Take", range: range, project: project, media: [:])
        project.mixLanes.reverse()
        XCTAssertEqual(project.mixLanes.map(\.id), ["wide-mic", "close-mic"])
        let audio = try entry.snapshotItems().filter { $0.kind == "audio" }
        XCTAssertEqual(audio.map(\.laneID), ["close-mic", "wide-mic"])
        XCTAssertEqual(audio.map(\.laneLabel), ["Close mic", "Wide mic"])
        XCTAssertEqual(audio.map(\.laneColorSlot), [3, 1])
        XCTAssertEqual(audio.map(\.stream), [3, 2])
        XCTAssertEqual(audio.map(\.output), [range, range])
        XCTAssertEqual(audio.first?.json["lane_id"] as? String, "close-mic")
    }

    func testMulticamSnapshotReportsDuplicateSourceIDs() {
        let range = MulticamRange(from: .zero, to: .init(numerator: 2))
        let wide = MulticamSource(id: "wide", file: "/wide.mov")
        let duplicate = MulticamSource(id: "wide", file: "/other.mov")
        let project = MulticamProject(referenceAngle: "wide", range: range, angles: [wide, duplicate],
                                      audio: .follow, switches: [.init(at: .zero, angle: "wide")])
        let entry = MulticamQueuedRange(name: "Take", range: range, project: project, media: [:])

        XCTAssertThrowsError(try entry.snapshotItems())
    }

    func testSequenceReplanKeepsEntryIdentityAndOtherQueuedRangesReady() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        let editor = session.editor
        defer { editor.endSession() }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(15)
        while editor.isBusy, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.isBusy)

        editor.selectRange(0, editor.mcpDuration.seconds)
        editor.addMarkedRange()
        let first = try XCTUnwrap(editor.queuedRanges.first)

        let otherURL = URL(fileURLWithPath: "/unrelated-queue-dependency.png")
        let other = StillAsset(id: "card", file: otherURL.path, displayName: "Card", fingerprint: String(repeating: "0", count: 64))
        let insert = StillInsert(id: "insert", assetID: other.id, duration: .init(numerator: 1), cadence: .init(numerator: 1, denominator: 25))
        // Queue the second source through the model, retaining its frozen project independently of the first range.
        let clip = CutSequenceClip(id: "unrelated", file: source.path, from: .zero, to: .init(numerator: 1))
        let secondSnapshot = CutProject.stillSequence(.init(items: [.source(clip), .still(insert)], stillAssets: [other]))
        let excerpt = TranscriptQueueExcerpt(name: "Other", project: secondSnapshot,
                                             location: source.deletingLastPathComponent().appendingPathComponent("Other.cut"))
        _ = try editor.enqueueTranscriptSnapshot(secondSnapshot, excerpt: excerpt, range: .init(from: .zero, to: .init(numerator: 1)))
        let second = try XCTUnwrap(editor.queuedRanges.last)

        editor.invalidateQueuedMedia(at: [otherURL])
        XCTAssertEqual(editor.invalidatedQueueIDs, [second.id])
        XCTAssertEqual(editor.readyQueuedRanges.map(\.id), [first.id])
        var options = ExportSheetOptions()
        options.mode = .copy
        options.copyContainer = "mov"
        options.tracks = .all
        let issue = await editor.checkQueuedRanges(options: options)
        XCTAssertNil(issue)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = try await sessions.mcpOutputs(tool: "export_queue_plan", arguments: [
            "project_handle": session.mcpHandle, "output": directory.path, "mode": "copy", "tracks": "all"
        ], session: session, checkAccess: {})
        let jobID = try XCTUnwrap(receipt?["job_id"] as? String)
        let planDeadline = ContinuousClock.now + .seconds(15)
        var state = try sessions.mcpOutputJobs.status(owner: session.mcpHandle, id: jobID, cancel: false)
        while state["state"] as? String == "running", .now < planDeadline {
            try await Task.sleep(for: .milliseconds(20))
            state = try sessions.mcpOutputJobs.status(owner: session.mcpHandle, id: jobID, cancel: false)
        }
        XCTAssertEqual(state["state"] as? String, "succeeded", String(describing: state))
        let plan = try XCTUnwrap(state["result"] as? [String: Any])
        XCTAssertEqual((plan["destinations"] as? [String])?.count, 1)
        XCTAssertEqual(plan["skipped_needs_replan"] as? [String], [second.id.uuidString])

        let args: [String: Any] = ["id": second.id.uuidString, "mode": "replace"]
        try editor.setTranscriptMarks(.init(from: .init(numerator: 1, denominator: 10),
                                            to: .init(numerator: 2, denominator: 10)))
        _ = try await sessions.mcpOutputs(tool: "export_queue_entry_revise", arguments: args, session: session, checkAccess: {})
        XCTAssertTrue(editor.invalidatedQueueIDs.isEmpty)
        let revised = try XCTUnwrap(editor.queuedRanges.last)
        XCTAssertEqual(revised.id, second.id)
        XCTAssertNotEqual(revised.contentID, second.contentID)
        XCTAssertEqual(revised.excerpt?.name, "Other")
        let revisedOutput = directory.appendingPathComponent("Revised.cut")
        try XCTUnwrap(revised.excerpt).save(to: revisedOutput)
        let saved = try XCTUnwrap(CutProject.loadDocument(from: revisedOutput, limit: 1).project.sequenceClips?.first)
        XCTAssertEqual(saved.from, revised.clips.first?.from)
        XCTAssertEqual(saved.to, revised.clips.first?.to)

        editor.invalidateQueuedMedia(at: [source])
        try editor.setTranscriptMarks(.init(from: .init(numerator: 2, denominator: 10),
                                            to: .init(numerator: 3, denominator: 10)))
        try editor.replanQueuedRange(second.id)
        let recaptured = try XCTUnwrap(editor.queuedRanges.last)
        let recapturedOutput = directory.appendingPathComponent("Replanned.cut")
        try XCTUnwrap(recaptured.excerpt).save(to: recapturedOutput)
        let savedReplan = try XCTUnwrap(CutProject.loadDocument(from: recapturedOutput, limit: 1).project.sequenceClips?.first)
        XCTAssertEqual(savedReplan.from, recaptured.clips.first?.from)
        XCTAssertNotEqual(savedReplan.from, saved.from)

        editor.invalidateQueuedMedia(at: [source])
        XCTAssertEqual(editor.invalidatedQueueIDs, [first.id, second.id])
        let result = try await sessions.mcpOutputs(tool: "export_queue_entry_revise",
                                                  arguments: ["id": first.id.uuidString, "mode": "replan"],
                                                  session: session, checkAccess: {})
        let entries = try XCTUnwrap(result?["ranges"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["needs_replan"] as? Bool, false)
        XCTAssertEqual(entries.last?["needs_replan"] as? Bool, true)
        XCTAssertEqual(editor.readyQueuedRanges.map(\.id), [first.id])
        XCTAssertNotEqual(editor.readyQueuedRanges.first?.contentID, first.contentID)
        editor.removeQueuedRange(second.id)
        XCTAssertTrue(editor.invalidatedQueueIDs.isEmpty)
    }

    func testPicturePolicyInvalidatesEarlierQueueSnapshotAndReplanUsesProgramClock() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let editor = EditorModel(preferences: preferences)
        defer { editor.endSession() }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(15)
        while editor.isBusy, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.isBusy)
        editor.selectRange(0.2, 0.8)
        editor.addMarkedRange()
        let original = try XCTUnwrap(editor.queuedRanges.first)
        XCTAssertNotNil(editor.readyQueuedRanges.first)

        var policy = editor.participantProject
        policy.tileOutput = .init(canvas: .init(width: 160, height: 90), audio: .init(mode: .silence))
        try editor.replaceParticipantProject(policy, action: "Set Output Canvas")
        XCTAssertEqual(editor.invalidatedQueueIDs, [original.id])
        XCTAssertTrue(editor.readyQueuedRanges.isEmpty)

        try editor.replanQueuedRange(original.id)
        let replanned = try XCTUnwrap(editor.readyQueuedRanges.first)
        XCTAssertEqual(replanned.id, original.id)
        XCTAssertEqual(replanned.start, original.start)
        XCTAssertEqual(replanned.end, original.end)
        XCTAssertEqual(replanned.pictureProject, editor.stillProject)

        var options = ExportSheetOptions()
        options.mode = .copy
        options.copyContainer = "mov"
        let copyIssue = await editor.checkQueuedRanges(options: options)
        XCTAssertEqual(copyIssue?.code, "participant_render_requires_encoding")
        options.mode = .encode
        options.encodeContainer = "mov"
        let encodeIssue = await editor.checkQueuedRanges(options: options)
        XCTAssertNil(encodeIssue)
        options.tracks = .video
        let pictureOnlyIssue = await editor.checkQueuedRanges(options: options)
        XCTAssertNil(pictureOnlyIssue)
    }

    func testMulticamQueueMarksUsedStillsAndUnresolvedRecordingsIndividually() throws {
        func t(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }
        func r(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: t(from), to: t(to)) }

        let wide = MulticamSource(id: "wide", file: "/queue/unavailable/../wide.mov")
        let close = MulticamSource(id: "close", file: "/queue/close.mov")
        let card = StillAsset(id: "card", file: "/queue/card.png", displayName: "Card", fingerprint: String(repeating: "0", count: 64))
        let unused = StillAsset(id: "unused", file: "/queue/unused.png", displayName: "Unused", fingerprint: card.fingerprint)
        let gap = StillAsset(gapID: "gap")
        let insert = StillInsert(id: "insert", assetID: card.id, duration: t(1), cadence: .init(numerator: 1, denominator: 25))
        let gapInsert = StillInsert(id: "insert-gap", assetID: gap.id, duration: t(1), cadence: .init(numerator: 1, denominator: 25))
        let project = MulticamProject(referenceAngle: "wide", range: r(0, 4), angles: [wide, close], audio: .none,
                                      switches: [.init(at: .zero, angle: "wide"), .init(at: t(2), angle: "close")],
                                      assemblyItems: [.group(r(0, 2)), .still(insert), .still(gapInsert)], stillAssets: [card, unused, gap])
        let withCard = MulticamQueuedRange(name: "Card", range: r(0, 4), project: project, media: [:], usesAssembly: true)
        let interview = MulticamQueuedRange(name: "Interview", range: r(2, 4), project: project, media: [:])
        let model = MulticamEditorModel()
        model.queuedRanges = [withCard, interview]
        let frozen = model.queuedRanges.map(\.contentID)

        model.invalidateQueuedMedia(at: [URL(fileURLWithPath: unused.file)])
        XCTAssertTrue(model.invalidatedQueueIDs.isEmpty)
        model.invalidateQueuedMedia(at: [URL(fileURLWithPath: card.file)])
        XCTAssertEqual(model.invalidatedQueueIDs, [withCard.id])
        XCTAssertEqual(model.readyQueuedRanges.map(\.id), [interview.id])
        model.clearQueueInvalidation(withCard.id)
        model.invalidateQueuedMedia(at: [URL(fileURLWithPath: wide.file)])
        XCTAssertEqual(model.invalidatedQueueIDs, [withCard.id])
        XCTAssertEqual(model.queuedRanges.map(\.contentID), frozen)
        model.removeQueuedRange(withCard.id)
        XCTAssertTrue(model.invalidatedQueueIDs.isEmpty)
        XCTAssertEqual(model.readyQueuedRanges.map(\.id), [interview.id])
    }

    func testPictureQueueTracksOnlyStillsIntersectingItsProgramRange() {
        let document = URL(fileURLWithPath: "/queue/Session.cut")
        let card = StillAsset(id: "card", file: "card.png", displayName: "Card", fingerprint: String(repeating: "0", count: 64))
        let later = StillAsset(id: "later", file: "later.png", displayName: "Later", fingerprint: card.fingerprint)
        let second = RationalTime(numerator: 1)
        let cadence = RationalTime(numerator: 1, denominator: 25)
        let insert = StillInsert(id: "first", assetID: card.id, duration: second, cadence: cadence)
        let laterInsert = StillInsert(id: "second", assetID: later.id, duration: second, cadence: cadence)
        let soundtrack = CutSequenceClip(id: "sound", file: "sound.wav", from: .zero, to: second, audioTrack: 0)
        let format = StillTimelineFormat(width: 160, height: 90, cadence: cadence, codec: .h264, container: "mov")
        let project = CutProject.stillSequence(.init(items: [.still(insert), .still(laterInsert)],
                                                     stillAssets: [card, later], stillFormat: format,
                                                     stillSoundtrack: soundtrack))
        let entry = QueuedRange(start: .zero, end: second, clips: [], media: [:], pictureProject: project,
                                pictureDocument: document)
        let firstURL = URL(fileURLWithPath: "/queue/card.png")
        let soundtrackURL = URL(fileURLWithPath: "/queue/sound.wav")
        XCTAssertEqual(entry.mediaDependencies, [firstURL, soundtrackURL])
        var targets = QueueMediaTargets()
        entry.addMediaTargets(to: &targets)
        XCTAssertEqual(targets.presenceOnlyByURL, [firstURL: true, soundtrackURL: false])
    }

}
