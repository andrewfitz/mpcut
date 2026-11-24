import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class OfflineSequenceTests: XCTestCase {
    private let second = RationalTime(numerator: 1, denominator: 1)

    @MainActor
    func testOfflineFirstClipKeepsItsRangeAndOnlineSelectionCanExport() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let online = folder.appendingPathComponent("Online.mov")
        try FileManager.default.copyItem(at: fixture, to: online)
        let media = try CutEngine(useSidecar: false).inspect(online, keyframes: true)
        let missing = folder.appendingPathComponent("Offline.mov")
        let project = folder.appendingPathComponent("Edit.cut")
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        try model.openProject([
            .init(id: "offline", file: missing.path, from: .zero, to: second),
            .init(id: "online", file: online.path, from: .zero, to: media.duration)
        ], at: project)
        try await awaitIdle(model)
        XCTAssertEqual(model.timelineClips.map(\.name), ["Offline.mov", "Online.mov"])
        XCTAssertEqual(model.unresolvedMediaStatus(for: missing), .offline)
        XCTAssertNil(model.unresolvedMediaStatus(for: online))
        XCTAssertEqual(model.projectMediaSummary.offline, 1)
        XCTAssertEqual(model.mcpSequenceOffsets, [.zero, second])
        XCTAssertTrue(model.hasPicture)
        XCTAssertNotNil(model.preferredCopyContainer)
        XCTAssertNotNil(model.mediaClipReview[try XCTUnwrap(model.timelineClips.first?.id)])
        XCTAssertThrowsError(try model.mcpExportInput(selection: false))

        model.selectRange(second.seconds, model.duration)
        let selection = try model.mcpExportInput(selection: true)
        XCTAssertEqual(selection.clips.map(\.file), [online])
        XCTAssertEqual(selection.occurrenceIDs, ["online"])
        XCTAssertNotNil(selection.media[online])

        try model.ignoreProjectMedia(missing.path)
        XCTAssertEqual(model.mediaStatus(for: missing), .ignored)
        XCTAssertEqual(model.projectMediaSummary.offline, 0)
    }

    @MainActor
    func testOfflineTraversalSurvivesDeleteUndoSaveAndReopen() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrongFile = folder.appendingPathComponent("Recording.mov")
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: wrongFile)
        let model = EditorModel()
        let reopened = EditorModel()
        defer {
            model.endSession()
            reopened.endSession()
        }
        model.useAnalysisSidecars = false
        let path = "MissingParent/../Recording.mov"
        let project = folder.appendingPathComponent("Edit.cut")
        try model.openProject([.init(id: "offline", file: path, from: .zero, to: second)], at: project)
        try await awaitIdle(model)
        let clip = try XCTUnwrap(model.timelineClips.first)
        XCTAssertEqual(clip.mediaStatus, .offline)
        XCTAssertFalse(model.hasPicture)
        XCTAssertFalse(model.isAudioOnly)
        XCTAssertNil(model.trim(clip.id, edge: .end, sourceTime: 0.5, commit: false))
        model.seek(0.5)
        model.split()
        XCTAssertNotNil(model.alert)
        model.alert = nil
        model.deleteClip(clip.id)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.projectMediaSummary.offline, 0)
        model.undo()
        try await awaitIdle(model)
        XCTAssertEqual(model.duration, 1)
        XCTAssertEqual(model.timelineClips.first?.mediaStatus, .offline)
        XCTAssertEqual(model.projectMediaSummary.offline, 1)

        try model.writeProject(to: project, flushDraftAnalysis: false)
        let saved = try CutProject.loadDocument(from: project, limit: 10)
        XCTAssertTrue(saved.project.sequenceClips?.first?.file.hasSuffix(path) == true)
        try reopened.openProject(saved.project.sequenceClips ?? [], at: project)
        try await awaitIdle(reopened)
        XCTAssertEqual(reopened.timelineClips.first?.mediaStatus, .offline)
        XCTAssertTrue(reopened.canRedo)
        reopened.redo()
        try await awaitIdle(reopened)
        XCTAssertTrue(reopened.isEmpty)
        reopened.undo()
        try await awaitIdle(reopened)
        XCTAssertEqual(reopened.timelineClips.first?.mediaStatus, .offline)
    }

    @MainActor
    func testPresentRecordingWithOutOfRangeSavedUsesOpensForReview() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let recording = folder.appendingPathComponent("Changed.mov")
        try FileManager.default.copyItem(at: fixture, to: recording)
        let media = try CutEngine(useSidecar: false).inspect(recording, keyframes: true)
        let model = EditorModel()
        defer { model.endSession() }
        model.useAnalysisSidecars = false
        let lastCut = media.duration + second
        let clips = [
            CutSequenceClip(id: "changed", file: recording.path, from: .zero, to: lastCut),
            CutSequenceClip(id: "hidden", file: recording.path, from: .zero, to: media.duration),
            CutSequenceClip(id: "online", file: recording.path, from: .zero, to: media.duration)
        ]
        let asset = StillAsset(id: "photo", file: folder.appendingPathComponent("Photo.png").path,
                               displayName: "Photo", fingerprint: String(repeating: "a", count: 64))
        let project = try CutProject.sequence(clips).addingStillAsset(asset).addingStillReplacement(
            .init(id: "cover", assetID: asset.id, coverage: .sequence([
                .init(clipID: "hidden", range: .init(from: .zero, to: lastCut))
            ])))
        try model.openProject(clips, at: folder.appendingPathComponent("Edit.cut"), stillProject: project)
        try await awaitIdle(model)
        XCTAssertEqual(model.timelineClips.map(\.mediaStatus), [.needsReview, .needsReview, .online])
        let clip = try XCTUnwrap(model.timelineClips.first)
        XCTAssertEqual(clip.sourceEnd, lastCut.seconds)
        XCTAssertTrue(model.mediaClipReview[clip.id]?.contains("saved trim") == true)
        let hidden = model.timelineClips[1]
        XCTAssertTrue(model.mediaClipReview[hidden.id]?.contains("saved still replacement") == true)
        XCTAssertThrowsError(try model.mcpExportInput(selection: false))
    }

    @MainActor
    func testRecoveredDraftKeepsOfflineAudioOccurrenceAndReviewRange() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = ProjectDraft(directory: folder)
        let missing = folder.appendingPathComponent("OfflineAudio.wav")
        let clip = CutSequenceClip(id: "audio", file: missing.path, from: .zero, to: second, audioTrack: 0)
        try writer.write { url in
            try CutProject.sequence([clip]).saveStaged(to: url, undo: [], redo: [], mediaSnapshot: .empty)
        }
        let file = try XCTUnwrap(writer.url)
        writer.relinquish()

        let model = EditorModel(preferences: EditorPreferences(), draft: ProjectDraft(directory: folder))
        defer { model.endSession() }
        try model.openProject([clip], at: file)
        try await awaitIdle(model)
        XCTAssertEqual(model.draft.url, file)
        XCTAssertNil(model.projectURL)
        XCTAssertTrue(model.isProjectChanged)
        XCTAssertTrue(model.isAudioOnly)
        XCTAssertEqual(model.timelineClips.first?.mediaStatus, .offline)
        XCTAssertEqual(model.transcriptProject.sequenceClips?.first, clip)
    }

    @MainActor
    private func awaitIdle(_ model: EditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isBusy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.alert)
    }

    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }
}
