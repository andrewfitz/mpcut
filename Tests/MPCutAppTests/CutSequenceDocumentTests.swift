@testable import MPCutCore
import XCTest
@testable import MPCutApp

final class CutSequenceDocumentTests: XCTestCase {
    @MainActor
    func testInPlaceSaveRejectsChangesOnlyInStillRedoAndAllowsSaveAs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Original.cut")
        let copy = directory.appendingPathComponent("Recovered.cut")
        let project = CutProject.sequence([])
        let asset = StillAsset(id: "asset", file: "offline.png", displayName: "Still", fingerprint: "fixture")
        let still = StillInsert(id: "card", assetID: asset.id, duration: .init(numerator: 1), cadence: .init(numerator: 1, denominator: 24))
        let format = StillTimelineFormat(width: 640, height: 360, cadence: still.cadence, codec: .h264, container: "mp4")
        func redo(with insert: StillInsert) -> [CutHistoryState] {
            [.init(action: "Insert Still", project: .stillSequence(.init(items: [.still(insert)], stillAssets: [asset], stillFormat: format)))]
        }
        let originalRedo = redo(with: still)
        try project.save(to: url, undo: [], redo: originalRedo)
        let preferences = EditorPreferences()
        preferences.historyLimit = 10
        let editor = EditorModel(preferences: preferences)
        defer { editor.endSession() }
        try editor.openProject([], at: url)

        let initial = try XCTUnwrap(CutProjectMedia.load(from: url).diskRevision)
        var updatedStill = still
        updatedStill.duration = .init(numerator: 2)
        let updatedRedo = redo(with: updatedStill)
        _ = try project.saveRevision(to: url, undo: [], redo: updatedRedo, mediaSnapshot: .empty, expected: initial)
        let published = try Data(contentsOf: url)
        XCTAssertEqual(try CutProject.loadDocument(from: url, limit: 10).redo, updatedRedo)

        XCTAssertThrowsError(try editor.writeProject(to: url)) {
            XCTAssertEqual(($0 as? CutError)?.code, "project_save_conflict")
        }
        XCTAssertEqual(try Data(contentsOf: url), published)
        XCTAssertEqual(editor.projectURL, url)
        try editor.writeProject(to: copy)
        XCTAssertEqual(editor.projectURL, copy)
        XCTAssertNoThrow(try editor.writeProject(to: copy))
        let recovered = try CutProject.loadDocument(from: copy, limit: 10)
        XCTAssertEqual(recovered.project, project)
        XCTAssertEqual(recovered.redo, originalRedo)
    }

    @MainActor
    func testOpenEditSaveAsPreservesExactRepeatedClipsAndReplacementAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent("working.mka"))
        let project = directory.appendingPathComponent("First.cut")
        let clips = try [("second-half", "0.1", "0.2"), ("first-half", "0", "0.1")].map { id, from, to in
            CutSequenceClip(id: id, file: "working.mka", from: try RationalTime(parsing: from), to: try RationalTime(parsing: to),
                            audioTrack: 1, originalFile: "original.mka", replacementNames: [1: "dialog.wav"])
        }
        try CutProject.sequence(clips).save(to: project)

        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        defer { sessions.windowClosed(session) }
        sessions.openFiles([project, project], in: session)
        XCTAssertEqual(sessions.sessions.count, 1)
        try await waitForImport(session.editor)
        let editor = session.editor
        XCTAssertNil(editor.alert)
        XCTAssertFalse(session.isMulticam)
        XCTAssertFalse(editor.isProjectChanged)
        XCTAssertFalse(editor.hasHistory)
        XCTAssertEqual(editor.analysisTrack, 1)
        XCTAssertTrue(sessions.project(at: project) === session)
        XCTAssertEqual(editor.timelineClips.map(\.replacementAudio), ["dialog.wav", "dialog.wav"])

        editor.moveSelectedClip(by: 1)
        XCTAssertTrue(editor.isProjectChanged)
        let destination = directory.appendingPathComponent("Reordered.cut")
        XCTAssertTrue(editor.saveProject(to: destination))
        XCTAssertFalse(editor.isProjectChanged)
        XCTAssertNil(sessions.project(at: project))
        XCTAssertTrue(sessions.project(at: destination) === session)
        XCTAssertEqual(try CutProject.load(from: destination), .sequence(Array(clips.reversed())))
    }

    @MainActor
    func testSequenceLoadKeepsEveryOccurrenceWhenOneSourceIsMissing() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        let clips = [file.path, url.appendingPathExtension("missing").path].enumerated().map {
            CutSequenceClip(id: String($0.offset), file: $0.element, from: .zero, to: RationalTime(numerator: 1, denominator: 30))
        }
        let model = EditorModel(preferences: EditorPreferences())
        defer { model.endSession() }
        try model.openProject(clips, at: url)
        try await waitForImport(model)
        XCTAssertEqual(model.sequenceClips.map(\.id), clips.map(\.id))
        XCTAssertEqual(model.timelineClips.map(\.mediaStatus), [.online, .offline])
        XCTAssertEqual(model.projectURL, url)
        XCTAssertNil(model.openingProjectURL)
        XCTAssertFalse(model.isProjectChanged)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testFailedSequenceLoadDoesNotInstallPartialTimeline() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = CutSequenceClip(id: "first", file: source.path, from: .zero, to: RationalTime(numerator: 1, denominator: 10))
        let second = CutSequenceClip(id: "second", file: source.path, from: .zero, to: RationalTime(numerator: 1, denominator: 5))
        let data = try JSONEncoder().encode(CutProject.sequence([first, second]))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var clips = try XCTUnwrap(document["clips"] as? [[String: Any]])
        clips[1]["to"] = try XCTUnwrap(clips[1]["from"])
        document["clips"] = clips
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        let model = EditorModel(preferences: EditorPreferences())
        defer { model.endSession() }
        XCTAssertThrowsError(try model.openProject([first, second], at: url))
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.projectURL)
        XCTAssertNil(model.openingProjectURL)
        XCTAssertFalse(model.isProjectChanged)
    }

    @MainActor
    func testOpeningAnotherProjectKeepsAnEmptyTimelineWithUndoHistory() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        try CutProject.sequence([]).save(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        defer { for session in Array(sessions.sessions.values) { sessions.windowClosed(session) } }
        XCTAssertTrue(sessions.reopen())
        let original = try XCTUnwrap(sessions.sessions.values.first)
        original.editor.importFiles([file])
        try await waitForImport(original.editor)
        original.editor.deleteSelection()
        XCTAssertTrue(original.editor.isEmpty)
        XCTAssertTrue(original.editor.canUndo)

        sessions.openFiles([url], in: original)
        let opened = try XCTUnwrap(sessions.project(at: url))
        XCTAssertFalse(opened === original)
        XCTAssertFalse(opened.editor.hasHistory)
        original.editor.undo()
        XCTAssertEqual(original.editor.timelineClips.count, 1)
        XCTAssertTrue(opened.editor.isEmpty)
    }

    @MainActor
    func testDistinctReplacementProvenanceKeepsSeparateSourceIdentities() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        let clips = ["first", "second", "first"].enumerated().map { index, name in
            CutSequenceClip(id: String(index), file: file.path, from: .zero, to: RationalTime(numerator: 1, denominator: 10),
                            audioTrack: index == 1 ? 0 : 1, originalFile: name + ".mka", replacementNames: [1: name])
        }
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let editor = EditorModel(preferences: prefs)
        defer { editor.endSession() }
        try editor.openProject(clips, at: url)
        try await waitForImport(editor)
        let ids = editor.timelineClips.map(\.sourceID)
        XCTAssertEqual(ids.count, 3)
        guard ids.count == 3 else { return }
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(ids[0], ids[2])
        XCTAssertEqual(editor.sequenceClips.map(\.replacementNames), clips.map(\.replacementNames))
        XCTAssertEqual(editor.preview.ranges.map(\.audioTrack), [1, 0, 1])
        editor.chooseAnalysisTrack(0)
        XCTAssertEqual(editor.preview.ranges.map(\.audioTrack), [0, 0, 0])
        XCTAssertFalse(editor.isProjectChanged)
    }

    @MainActor
    func testAddingOriginalMediaKeepsItsExplicitTimelineSource() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let working = directory.appendingPathComponent("working.mka")
        try FileManager.default.copyItem(at: file, to: working)
        let end = RationalTime(numerator: 1, denominator: 10)
        let original = CutSequenceClip(id: "original", file: file.path, from: .zero, to: end)
        let replaced = CutSequenceClip(id: "working", file: working.path, from: .zero, to: end, originalFile: file.path)
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let editor = EditorModel(preferences: prefs)
        defer { editor.endSession() }
        try editor.openProject([original, replaced], at: directory.appendingPathComponent("edit.cut"))
        try await waitForImport(editor)
        editor.importFiles([file])
        try await waitForImport(editor)
        XCTAssertEqual(editor.sequenceClips.map(\.file), [file.path, working.path, file.path])
    }

    @MainActor
    func testUntitledDraftPromotesAndReopensWithBothHistoryBranches() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let editor = EditorModel(preferences: prefs)
        defer { editor.endSession() }
        XCTAssertNil(editor.draft.url)
        editor.importFiles([file])
        try await waitForImport(editor)
        let draft = try XCTUnwrap(editor.draft.url)
        let original = editor.sequenceClips
        XCTAssertNil(editor.projectURL)
        editor.deleteSelection()
        editor.undo()
        XCTAssertEqual(editor.historyActions, ["Add Clip", "Delete Clip"])
        XCTAssertEqual(editor.historyCursor, 1)
        let stored = try CutProject.loadDocument(from: draft, limit: 100)
        XCTAssertEqual(prefs.recentFiles.urls.map(\.lastPathComponent), [file.lastPathComponent])
        XCTAssertEqual(stored.undo.map(\.action), ["Add Clip"])
        XCTAssertEqual(stored.redo.map(\.action), ["Delete Clip"])
        XCTAssertTrue(editor.saveProject(to: url))
        XCTAssertNil(editor.draft.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.path))

        let reopened = EditorModel(preferences: prefs)
        defer { reopened.endSession() }
        guard case .sequence(let clips) = try CutProject.load(from: url) else { return XCTFail("Expected a sequence") }
        try reopened.openProject(clips, at: url)
        try await waitForImport(reopened)
        XCTAssertEqual(prefs.recentFiles.urls.map(\.lastPathComponent), [url.lastPathComponent, file.lastPathComponent])
        XCTAssertEqual(reopened.historyActions, editor.historyActions)
        XCTAssertEqual(reopened.historyCursor, 1)
        XCTAssertFalse(reopened.isProjectChanged)
        reopened.moveToHistoryState(0)
        XCTAssertTrue(reopened.isEmpty)
        XCTAssertTrue(reopened.isProjectChanged)
        reopened.redo()
        try await waitForImport(reopened)
        XCTAssertEqual(reopened.sequenceClips, original)
        XCTAssertFalse(reopened.isProjectChanged)
        reopened.deleteSelection()
        XCTAssertFalse(reopened.canRedo)
        XCTAssertEqual(reopened.historyCursor, 2)
        prefs.historyLimit = 1
        XCTAssertEqual(reopened.historyActions, ["Delete Clip"])
        prefs.historyLimit = 0
        XCTAssertFalse(reopened.hasHistory)
        XCTAssertTrue(reopened.saveProject(to: url))
        let fields = try ProjectFile.decode([String: TranscriptJSONValue].self, data: Data(contentsOf: url))
        XCTAssertNil(fields["history"])
    }

    @MainActor
    func testReopenEmptySequenceRestoresOfflineUndoAndRechecksMediaWhenItReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Offline.cut")
        let file = directory.appendingPathComponent("old.mka")
        let state = CutSequenceClip(id: "deleted", file: "old.mka", from: .zero, to: RationalTime(numerator: 1, denominator: 10))
        try CutProject.sequence([]).save(to: url, undo: [CutHistoryState(action: "Delete Clip", project: .sequence([state]))], redo: [])
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let model = EditorModel(preferences: prefs)
        defer { model.endSession() }
        try model.openProject([], at: url)
        XCTAssertTrue(model.canUndo)
        model.undo()
        try await waitForImport(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.historyCursor, 0)
        XCTAssertEqual(model.timelineClips.first?.mediaStatus, .offline)
        XCTAssertTrue(model.isProjectChanged)
        model.redo()
        XCTAssertTrue(model.isEmpty)
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: file)
        model.undo()
        try await waitForImport(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.first?.mediaStatus, .online)
        XCTAssertEqual(model.sequenceClips.map(\.id), ["deleted"])
        XCTAssertEqual(model.historyCursor, 0)
        XCTAssertEqual(model.redoTitle, "Redo Delete Clip")
    }

    @MainActor
    func testCSVReplacesTargetOccurrenceAsOneUndoableEdit() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let clips = try ["first", "target"].map {
            CutSequenceClip(id: $0, file: file.path, from: try RationalTime(parsing: "0.1"), to: try RationalTime(parsing: "0.2"))
        }
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let editor = EditorModel(preferences: prefs)
        defer { editor.endSession() }
        try editor.openProject(clips, at: url.appendingPathExtension("cut"))
        try await waitForImport(editor)
        let target = try XCTUnwrap(editor.timelineClips.last?.id)
        try "0,.02\n.03,.2".write(to: url, atomically: true, encoding: .utf8)
        editor.applyClipCSV(url, to: target)
        try await waitForImport(editor)
        XCTAssertNotNil(editor.alert)
        XCTAssertEqual(editor.sequenceClips, clips)
        editor.alert = nil
        try ".05,.1\n0,.05\n.05,.1".write(to: url, atomically: true, encoding: .utf8)
        editor.applyClipCSV(url, to: target)
        try await waitForImport(editor)
        XCTAssertEqual(editor.sequenceClips.first, clips.first)
        XCTAssertEqual(editor.sequenceClips.dropFirst().map { $0.from.description }, ["3/20", "1/10", "3/20"])
        editor.undo()
        XCTAssertEqual(editor.sequenceClips, clips)
        editor.redo()
        XCTAssertEqual(editor.timelineClips.count, 4)
    }

    @MainActor
    func testLargeRecoveredSequenceSavesLatestCursorWhileRecoveryWritesArePending() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        var clips = (0..<32).map { CutSequenceClip(id: String($0), file: file.path, from: .zero, to: RationalTime(numerator: 1, denominator: 10)) }
        var undo: [CutHistoryState] = []
        for _ in 0..<32 {
            undo.append(CutHistoryState(action: "Move Clip", project: .sequence(clips)))
            clips.append(clips.removeFirst())
        }
        let draftURL: URL = try {
            let interrupted = ProjectDraft()
            try interrupted.write { try CutProject.sequence(clips).saveStaged(to: $0, undo: undo, redo: [], mediaSnapshot: .empty) }
            return try XCTUnwrap(interrupted.url)
        }()
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let model = EditorModel(preferences: prefs)
        defer { model.endSession() }
        try model.openProject(clips, at: draftURL)
        try await waitForImport(model)
        XCTAssertNil(model.alert)
        XCTAssertNil(model.projectURL)
        XCTAssertTrue(model.isProjectChanged)
        model.moveToHistoryState(12)
        model.redo()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.saveProject(to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        let saved = try CutProject.loadDocument(from: url, limit: 50)
        XCTAssertEqual(saved.undo.count, 13)
        XCTAssertEqual(saved.redo.count, 19)
        guard case .sequence(let timeline) = saved.project else { return XCTFail("Expected a sequence") }
        XCTAssertEqual(timeline.map(\.id), model.sequenceClips.map(\.id))
    }

    @MainActor
    func testArchivedAndLiveUndoRestoreOfflineMediaWithoutBlockingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let file = directory.appendingPathComponent("working.mka")
        try FileManager.default.copyItem(at: source, to: file)
        let current = CutSequenceClip(id: "a", file: "working.mka", from: .zero, to: RationalTime(numerator: 1, denominator: 5), audioTrack: 1)
        let project = directory.appendingPathComponent("edit.cut")
        let old = CutSequenceClip(id: current.id, file: current.file, from: .zero, to: RationalTime(numerator: 1, denominator: 10), audioTrack: 1)
        try CutProject.sequence([current]).save(to: project, undo: [.init(action: "Trim Clip", project: .sequence([old]))], redo: [])
        let prefs = EditorPreferences()
        prefs.useAnalysisSidecars = false
        let editor = EditorModel(preferences: prefs)
        defer { editor.endSession() }
        try editor.openProject([current], at: project)
        try await waitForImport(editor)
        editor.selectRange(0, 0.18)
        XCTAssertNotNil(editor.markOut)
        try FileManager.default.removeItem(at: file)
        editor.undo()
        try await waitForImport(editor)
        XCTAssertNil(editor.alert)
        XCTAssertEqual(editor.historyCursor, 0)
        XCTAssertTrue(editor.isProjectChanged)
        XCTAssertEqual(editor.timelineClips.first?.mediaStatus, .offline)
        XCTAssertEqual(editor.sequenceClips.map(\.to), [old.to])
        XCTAssertNil(editor.markOut, "A mark beyond the restored edit must not survive.")
        editor.deleteSelection()
        XCTAssertTrue(editor.isEmpty)
        editor.undo()
        try await waitForImport(editor)
        XCTAssertNil(editor.alert)
        XCTAssertFalse(editor.isEmpty)
        XCTAssertEqual(editor.timelineClips.first?.mediaStatus, .offline)
        XCTAssertEqual(editor.sequenceClips.map(\.to), [old.to])
    }

    @MainActor
    func testHistoricalSymlinkTraversalResolvesWhenVolumeComesBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mount = directory.appendingPathComponent("card/subdir")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let file = mount.deletingLastPathComponent().appendingPathComponent("recording.mka")
        try FileManager.default.copyItem(at: source, to: file)
        let project = directory.appendingPathComponent("edit.cut")
        let archived = CutSequenceClip(id: "offline", file: "reader/../recording.mka", from: .zero, to: RationalTime(numerator: 1, denominator: 10))
        try CutProject.sequence([]).save(to: project, undo: [.init(action: "Delete Clip", project: .sequence([archived]))], redo: [])
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        try editor.openProject([], at: project)
        editor.undo()
        try await waitForImport(editor)
        XCTAssertNil(editor.alert)
        XCTAssertEqual(editor.timelineClips.first?.mediaStatus, .offline)
        editor.redo()
        XCTAssertTrue(editor.isEmpty)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("reader"), withDestinationURL: mount)
        editor.undo()
        try await waitForImport(editor)
        XCTAssertNil(editor.alert)
        XCTAssertEqual(editor.historyCursor, 0)
        XCTAssertEqual(editor.sequenceClips.first?.file, file.resolvingSymlinksInPath().path)
    }

    @MainActor
    func testHistoryJumpAcrossEmptyTimelineRestoresOriginalCopyContainer() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        editor.importFiles([file])
        try await waitForImport(editor)
        editor.preferCopyContainer("mkv")
        editor.deleteSelection()
        editor.importFiles([file])
        try await waitForImport(editor)
        editor.preferCopyContainer("mov")
        editor.moveToHistoryState(1)
        XCTAssertEqual(editor.preferredCopyContainer, "mkv")
        XCTAssertEqual(editor.historyCursor, 1)
        editor.moveToHistoryState(3)
        XCTAssertEqual(editor.preferredCopyContainer, "mov")
    }

    @MainActor
    func testHistoryProtectsMissingMediaInsideFrameExportAndBesideAnalysisSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let file = directory.appendingPathComponent("source.mov")
        try FileManager.default.copyItem(at: fixture, to: file)
        let current = CutSequenceClip(id: "current", file: file.path, from: .zero, to: RationalTime(numerator: 1, denominator: 10))
        var archived = current
        archived.file = "stills/frame.jpg"
        archived.originalFile = AnalysisSidecar.url(for: file).path
        let project = directory.appendingPathComponent("edit.cut")
        try CutProject.sequence([current]).save(to: project, undo: [], redo: [.init(action: "Replace Source Audio", project: .sequence([archived]))])
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        try editor.openProject([current], at: project)
        try await waitForImport(editor)
        let dir = directory.appendingPathComponent("stills")
        let jpegSource = try XCTUnwrap(editor.jpegSourceAtPlayhead)
        editor.exportJPEGFrames(jpegSource, to: dir, options: JPEGExportOptions(preset: editor.preferences.jpegPreset))
        XCTAssertNotNil(editor.alert)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        editor.dismissNotice()
        editor.saveAnalysisSidecars()
        XCTAssertNotNil(editor.alert)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: file).path))
    }

    @MainActor
    func testBypassedClosePreservesCommittedNamedEditAndExcludesPendingImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let project = directory.appendingPathComponent("Named.cut")
        let drafts = directory.appendingPathComponent("Drafts")
        let editor = EditorModel(preferences: EditorPreferences(), draft: ProjectDraft(directory: drafts))
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.importFiles([file])
        try await waitForImport(editor)
        XCTAssertTrue(editor.saveProject(to: project))
        let saved = try Data(contentsOf: project)
        editor.deleteSelection()
        editor.importFiles(Array(repeating: file, count: 150))
        XCTAssertTrue(editor.isImporting)
        editor.preserveAfterUnconfirmedClose()
        editor.endSession()
        XCTAssertEqual(try Data(contentsOf: project), saved)
        let restored = try XCTUnwrap(try ProjectDraft.recoverable(in: drafts).first)
        let document = try CutProject.loadDocument(from: restored, limit: 50)
        XCTAssertEqual(document.project, .sequence([]))
        XCTAssertEqual(document.undo.map(\.action), ["Add Clip", "Delete Clip"])
    }

    @MainActor
    func testPruningNamedHistoryWhileUndoIsLoadingLeavesTheFileDirty() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cut")
        defer { try? FileManager.default.removeItem(at: project) }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka", subdirectory: "Fixtures"))
        let past = CutSequenceClip(id: "past", file: source.path, from: .zero, to: RationalTime(numerator: 1, denominator: 10))
        try CutProject.sequence([]).save(to: project, undo: [.init(action: "Delete Clip", project: .sequence([past]))], redo: [])
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let editor = EditorModel(preferences: preferences)
        defer { editor.endSession() }
        try editor.openProject([], at: project)
        editor.undo()
        XCTAssertTrue(editor.isImporting)
        preferences.historyLimit = 0
        try await waitForImport(editor)
        XCTAssertNil(editor.alert)
        XCTAssertTrue(editor.isEmpty)
        XCTAssertTrue(editor.isProjectChanged)
        XCTAssertTrue(editor.historyActions.isEmpty)
        XCTAssertTrue(editor.saveProject(to: project))
        XCTAssertTrue(try CutProject.loadHistory(from: project, limit: 50).undo.isEmpty)
    }

    @MainActor
    func testAutomaticAnalysisPreservesDiskOnlyMediaDuringProjectOpenAndLaterImport() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        for importLater in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let sources = ["protected.mov", "healthy.mov"].map { dir.appendingPathComponent($0) }
            for file in sources { try FileManager.default.copyItem(at: fixture, to: file) }
            let clips = sources.map { CutSequenceClip(id: $0.lastPathComponent, file: $0.path, from: .zero, to: RationalTime(numerator: 1, denominator: 10)) }
            let protected = AnalysisSidecar.url(for: sources[0])
            var archived = clips[0]
            archived.file = protected.lastPathComponent
            let project = dir.appendingPathComponent("Edit.cut")
            let active = importLater ? [] : clips
            try CutProject.sequence(active).save(to: project, undo: [], redo: [.init(action: "Add Clip", project: .sequence([archived]))])
            let prefs = EditorPreferences()
            prefs.historyLimit = 0
            prefs.useAnalysisSidecars = true
            let editor = EditorModel(preferences: prefs)
            defer { editor.endSession() }
            try editor.openProject(active, at: project)
            if importLater { editor.importFiles(sources) }
            try await waitForImport(editor)
            XCTAssertNil(editor.alert)
            XCTAssertEqual(editor.sequenceClips.count, 2)
            XCTAssertTrue(editor.historyActions.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: protected.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: sources[1]).path))
            XCTAssertThrowsError(try editor.validateHistoryDestination(protected))
            XCTAssertTrue(editor.saveProject(to: project))
            XCTAssertNoThrow(try editor.validateHistoryDestination(protected))
        }
    }

    @MainActor
    private func waitForImport(_ model: EditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
    }
}
