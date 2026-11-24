import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class LiveProjectMediaTests: XCTestCase {
    @MainActor
    func testSequenceRelinkPreservesHistoryOnBothSidesOfCursorAndSurvivesSave() async throws {
        let (directory, source) = try recording()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = EditorModel(preferences: preferences(), draft: ProjectDraft(directory: directory.appendingPathComponent("Drafts")))
        defer { model.endSession() }
        model.importFiles([source])
        try await wait { !model.isBusy }
        let archive = try XCTUnwrap(model.projectMediaArchive)
        XCTAssertEqual(archive.project.sequenceClips?.count, 1)
        // Add a second edit and undo it so the same recording can be reached by redo.
        model.importFiles([source])
        try await wait { !model.isBusy }
        model.undo()
        try await wait { !model.isBusy }
        let beforeIDs = model.historyEntryIDs
        let cursor = model.historyCursor
        model.scanForScenes()
        try await wait { model.sceneProgress == nil && !model.sceneReports.isEmpty }
        let originalReport = try XCTUnwrap(model.sceneReports.values.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: source).path))

        let moved = directory.appendingPathComponent("Moved.mp4")
        try FileManager.default.moveItem(at: source, to: moved)
        let changed = try await model.relinkProjectMedia(from: source.path, to: moved)
        XCTAssertTrue(changed)
        XCTAssertEqual(model.sequenceClips.map(\.file), [moved.path])
        XCTAssertEqual(model.historyEntryIDs, beforeIDs)
        XCTAssertEqual(model.historyCursor, cursor)
        let relinkedID = try XCTUnwrap(model.analysisSourceMedia.keys.first)
        let relinkedReport = try XCTUnwrap(model.sceneReports[relinkedID])
        XCTAssertEqual(relinkedReport.file, moved.path)
        XCTAssertEqual(relinkedReport.scenes.map(\.start), originalReport.scenes.map(\.start))
        model.redo()
        try await wait { !model.isBusy }
        XCTAssertEqual(model.sequenceClips.map(\.file), [moved.path, moved.path])

        let document = directory.appendingPathComponent("Edit.cut")
        try model.writeProject(to: document)
        let disk = try CutProject.loadEditorDocument(from: document, limit: 8)
        XCTAssertEqual(disk.project.sequenceClips?.map(\.file), [moved.lastPathComponent, moved.lastPathComponent])
        XCTAssertEqual(disk.undo.last?.project.sequenceClips?.first?.file, moved.lastPathComponent)
        XCTAssertEqual(disk.media.mediaSnapshot.entries.first?.previousPath, source.lastPathComponent)
    }

    @MainActor
    func testMulticamReplaceIsUndoableAndCommitValidationPreventsWrite() async throws {
        let (directory, source) = try recording()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MulticamEditorModel(preferences: preferences(), draft: ProjectDraft(directory: directory.appendingPathComponent("Drafts")))
        defer { model.reset() }
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        model.confirmSetup(drafts: [.init(source: .init(id: "camera", file: source.path), media: media)],
                           opening: "camera", audio: .none)
        let archive = try XCTUnwrap(model.projectMediaArchive)
        let candidate = directory.appendingPathComponent("Other.mp4")
        try FileManager.default.copyItem(at: source, to: candidate)
        let preview = try ProjectMediaReplace.preview(archive.project, snapshot: archive.snapshot,
                                                      relativeTo: archive.documentURL, source: source.path, candidate: candidate)
        XCTAssertTrue(preview.report.canApply, preview.report.blockers.joined(separator: "\n"))
        do {
            _ = try await model.applyProjectMediaReplacement(preview) { throw CancellationError() }
            XCTFail("The commit should honor cancellation.")
        } catch is CancellationError {}
        XCTAssertEqual(model.project?.sources.first?.file, source.path)
        XCTAssertEqual(model.historyCursor, 0)

        let changed = try await model.applyProjectMediaReplacement(preview)
        XCTAssertTrue(changed)
        XCTAssertEqual(model.project?.sources.first?.file, candidate.path)
        XCTAssertEqual(model.undoTitle, "Undo Replace Source File")
        model.undo()
        XCTAssertEqual(model.project?.sources.first?.file, source.path)
        model.redo()
        XCTAssertEqual(model.project?.sources.first?.file, candidate.path)
    }

    @MainActor
    func testSequenceReplaceUndoPreservesLaterBindingEdits() async throws {
        let (directory, _) = try recording()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mov", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("Original.mov")
        let candidate = directory.appendingPathComponent("Replacement.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        try FileManager.default.copyItem(at: fixture, to: candidate)
        let model = EditorModel(preferences: preferences(), draft: ProjectDraft(directory: directory.appendingPathComponent("Drafts")))
        defer { model.endSession() }
        model.importFiles([source])
        try await wait { !model.isBusy }
        let digest = String(repeating: "0", count: 64)
        let asset = TranscriptAsset(file: "edit.transcripts/\(digest).json", sha256: digest, unavailable: .missing)
        let old = TranscriptBinding(trackID: "target", file: source.path, streamIndex: 0)
        let other = TranscriptBinding(trackID: "other", file: directory.appendingPathComponent("Other.mov").path, streamIndex: 0)
        try model.setTranscriptState(.init(attachments: [.init(id: "speech", asset: asset, bindings: [old, other])]))
        let archive = try XCTUnwrap(model.projectMediaArchive)
        let preview = try ProjectMediaReplace.preview(archive.project, snapshot: archive.snapshot, relativeTo: archive.documentURL,
                                                      source: source.path, candidate: candidate)
        let changed = try await model.applyProjectMediaReplacement(preview)
        XCTAssertTrue(changed)
        let replacement = try XCTUnwrap(model.transcriptState.attachments.first?.bindings.first)
        XCTAssertEqual(replacement.file, candidate.path)
        var revised = model.transcriptState
        revised.attachments[0].bindings[1].streamIndex = 1
        let edited = revised.attachments[0].bindings[1]
        try model.setTranscriptState(revised)

        model.undo()
        try await wait { !model.isBusy }
        XCTAssertEqual(model.transcriptState.attachments.first?.bindings, [old, edited])
        model.redo()
        try await wait { !model.isBusy }
        XCTAssertEqual(model.transcriptState.attachments.first?.bindings, [replacement, edited])
    }

    @MainActor
    func testMulticamVerifiedRelinkRestampsLiveSceneAnalysis() async throws {
        let (directory, source) = try recording()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MulticamEditorModel(preferences: preferences(), draft: ProjectDraft(directory: directory.appendingPathComponent("Drafts")))
        defer { model.reset() }
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(source)
        model.confirmSetup(drafts: [.init(source: .init(id: "camera", file: source.path), media: media)],
                           opening: "camera", audio: .none)
        model.analysis.scanScenes()
        try await wait { model.analysis.sceneReports["camera"] != nil }
        let originalReport = try XCTUnwrap(model.analysis.sceneReports["camera"])
        let moved = directory.appendingPathComponent("Moved.mp4")
        try FileManager.default.moveItem(at: source, to: moved)
        model.refreshProjectMedia()
        try await wait { !model.isBusy && model.media["camera"] == nil }
        let offline = try XCTUnwrap(model.projectMediaArchive)
        XCTAssertEqual(offline.snapshot.entries.first { $0.path == source.path }?.sourceFingerprint,
                       media.identity.transcriptFingerprint)
        let changed = try await model.relinkProjectMedia(from: source.path, to: moved)
        XCTAssertTrue(changed)
        try await wait { model.media["camera"]?.url.path == moved.path && model.media["camera"]?.hasFullEditIndex == true }
        let relinkedReport = try XCTUnwrap(model.analysis.sceneReports["camera"])
        XCTAssertEqual(relinkedReport.file, moved.path)
        XCTAssertEqual(relinkedReport.scenes.map(\.start), originalReport.scenes.map(\.start))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: moved).path))
    }

    @MainActor
    func testSequenceReplaceUndoRestoresBindingsAndKeepsLaterAttachments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let source = directory.appendingPathComponent("Original.mov")
        let candidate = directory.appendingPathComponent("Replacement.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        try FileManager.default.copyItem(at: fixture, to: candidate)
        let model = EditorModel(preferences: preferences(), draft: ProjectDraft(directory: directory.appendingPathComponent("Drafts")))
        defer { model.endSession() }
        model.importFiles([source])
        try await wait { !model.isBusy }
        let media = try XCTUnwrap(model.analysisSourceMedia.values.first)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let assetContext = try model.transcriptAssetContext()
        let asset = try TranscriptStore.put(Data("{\"version\":1}".utf8), relativeTo: assetContext, draft: true)
        let original = TranscriptAttachment(id: "original", asset: asset, bindings: [
            TranscriptBinding(trackID: "track", file: source.path, streamIndex: stream)
        ])
        try model.setTranscriptState(.init(attachments: [original]))
        let archive = try XCTUnwrap(model.projectMediaArchive)
        let preview = try ProjectMediaReplace.preview(archive.project, snapshot: archive.snapshot,
                                                      relativeTo: archive.documentURL, source: source.path, candidate: candidate)
        let changed = try await model.applyProjectMediaReplacement(preview)
        XCTAssertTrue(changed)
        XCTAssertEqual(model.transcriptState.attachments.first?.bindings.first?.file, candidate.path)
        var current = model.transcriptState
        let later = TranscriptAttachment(id: "later", asset: asset, bindings: [])
        current.attachments.append(later)
        try model.setTranscriptState(current)

        model.undo()
        try await wait { !model.isBusy }
        XCTAssertEqual(model.transcriptState.attachments, [original, later])
        XCTAssertEqual(model.sequenceClips.first?.file, source.path)
        model.redo()
        try await wait { !model.isBusy }
        XCTAssertEqual(model.transcriptState.attachments.map(\.id), [original.id, later.id])
        XCTAssertEqual(model.transcriptState.attachments.first?.bindings.first?.file, candidate.path)
    }

    private func recording() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Original.mp4")
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: source)
        return (directory, source)
    }

    @MainActor
    private func preferences() -> EditorPreferences {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        preferences.automaticallyRefreshMedia = false
        preferences.historyLimit = 8
        return preferences
    }

    @MainActor
    private func wait(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(done())
    }
}
