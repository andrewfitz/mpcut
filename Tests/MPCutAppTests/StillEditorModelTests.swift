import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class StillEditorModelTests: XCTestCase {
    @MainActor
    func testOfflineStillOnlySequenceHistoryRoundTripsAndRestoresSelection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("offline.png")
        let document = folder.appendingPathComponent("titles.cut")
        let asset = StillAsset(id: "title-art", file: image.path,
                               displayName: "Title", fingerprint: String(repeating: "b", count: 64))
        let cadence = RationalTime(numerator: 1, denominator: 30)
        let format = StillTimelineFormat(width: 640, height: 360, cadence: cadence, codec: .h264, container: "mp4")
        let project = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "title",
                                                       duration: RationalTime(numerator: 2))
        let editor = EditorModel()
        defer { editor.endSession() }
        try editor.applyStillProject(project, action: "Insert Still")
        XCTAssertEqual(editor.mcpDuration, RationalTime(numerator: 2))
        XCTAssertTrue(editor.canNavigate)
        XCTAssertEqual(editor.timelineClips.count, 1)
        XCTAssertTrue(editor.stillPlacementRows.first?.title.contains("offline") == true)
        editor.seek(1)
        editor.setIn()
        editor.seek(2)
        editor.setOut()
        XCTAssertEqual(try editor.stillProjectForSelection().resolveStills().duration, RationalTime(numerator: 1))
        editor.undo()
        XCTAssertTrue(editor.isEmpty)
        try editor.writeProject(to: document)
        let archive = try CutProject.loadEditorDocument(from: document, limit: 5)
        XCTAssertEqual(archive.project, .sequence([]))
        XCTAssertEqual(archive.redo.first?.project.stillAssets.first?.file, "offline.png")
        XCTAssertThrowsError(try editor.validateHistoryDestination(image))

        let reopened = EditorModel()
        defer { reopened.endSession() }
        try reopened.openProject([], at: document)
        XCTAssertTrue(reopened.isEmpty)
        XCTAssertTrue(reopened.canRedo)
        reopened.redo()
        XCTAssertEqual(reopened.stillProject, project)
        XCTAssertEqual(reopened.mcpDuration, RationalTime(numerator: 2))
    }

    @MainActor
    func testSourceOffsetsAccountForAnInlineStillAfterReordering() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.importFiles([source, source])
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(editor.alert)
        let clips = editor.sequenceClips
        XCTAssertEqual(clips.count, 2)
        let start = clips[0].to - clips[0].from
        let asset = StillAsset(id: "card-image", file: "/offline.png",
                               displayName: "Card", fingerprint: String(repeating: "a", count: 64))
        let cadence = RationalTime(numerator: 1001, denominator: 30_000)
        let card = StillInsert(id: "card", assetID: asset.id, duration: cadence, cadence: cadence)
        let edited = try editor.stillProject.addingStillAsset(asset).insertingStill(card, at: start)
        try editor.applyStillProject(edited, action: "Insert Still")
        XCTAssertEqual(editor.mcpSequenceOffsets, [.zero, start + cadence])
        let id = try XCTUnwrap(editor.timelineClips.last?.id)
        editor.moveTimelineItem(id, to: 0)
        XCTAssertEqual(editor.sequenceClips.map(\.id), [clips[1].id, clips[0].id])
        XCTAssertEqual(editor.mcpSequenceOffsets, [.zero, start])
        XCTAssertTrue(editor.timelineClips.last?.isStill == true)
        editor.undo()
        XCTAssertEqual(editor.mcpSequenceOffsets, [.zero, start + cadence])
        XCTAssertEqual(editor.stillProject.stillInserts.map(\.id), ["card"])
    }

    @MainActor
    func testSelectionInsideStillInheritsTwoSilentAudioTracks() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(editor.alert)
        let audioReference = try XCTUnwrap(editor.sequenceClips.first)
        let asset = StillAsset(id: "title-art", file: "/offline-title.png",
                               displayName: "Offline title", fingerprint: String(repeating: "a", count: 64))
        let card = StillInsert(id: "title", assetID: asset.id, duration: RationalTime(numerator: 1),
                               cadence: RationalTime(numerator: 1, denominator: 10))
        let project = try editor.stillProject.addingStillAsset(asset).insertingStill(card, at: .zero)
        try editor.applyStillProject(project, action: "Insert Still")
        editor.selectRange(0.2, 0.5)
        let selection = try editor.stillProjectForSelection()
        XCTAssertEqual(selection.sequenceClips, [])
        XCTAssertEqual(selection.stillAudioReference, audioReference)
        XCTAssertThrowsError(try JSONEncoder().encode(selection))
        let planned = try StillExportPlanner().resolve(selection, tracks: .audio, mode: .encode,
                                                       container: "mov", settings: ReencodeSettings(audio: .pcm))
        let silence = MulticamRange(from: .zero, to: RationalTime(numerator: 3, denominator: 10))
        XCTAssertEqual(planned.report.soundActions.count, 2)
        for track in planned.report.soundActions {
            XCTAssertEqual(track.audio, .pcm)
            XCTAssertTrue(track.sources.isEmpty)
            XCTAssertEqual(track.generatedSilence, [silence])
        }
    }
}
