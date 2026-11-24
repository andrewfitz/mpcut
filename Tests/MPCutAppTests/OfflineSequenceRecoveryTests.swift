import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class OfflineSequenceRecoveryTests: XCTestCase {
    @MainActor
    func testOfflineSlatePlaysFullOccurrenceOnSilentClock() async throws {
        try await withEditor { model, directory in
            let end = RationalTime(numerator: 3, denominator: 4)
            let project = directory.appendingPathComponent("Edit.cut")
            try model.openProject([.init(id: "missing", file: "Missing.mov", from: .zero, to: end)], at: project)
            try await waitUntil { !model.isBusy && model.preview.readyForTransport }
            XCTAssertTrue(try XCTUnwrap(model.preview.programPictureIssue).contains("Missing.mov"))
            XCTAssertNil(model.preview.audioWarning)
            model.preview.togglePlayback()
            try await waitUntil { model.preview.time > 0.1 && model.preview.time < end.seconds }
            XCTAssertTrue(model.preview.isPlaying)
            XCTAssertNotNil(model.preview.programPictureIssue)
            try await waitUntil { !model.preview.isPlaying }
            XCTAssertEqual(model.preview.time, end.seconds, accuracy: 0.001)
        }
    }

    @MainActor
    func testRefreshRecoversUnresolvedSourceAndRebuildsMixedPreparation() async throws {
        try await withEditor { model, directory in
            let first = directory.appendingPathComponent("Missing.mp4")
            let second = directory.appendingPathComponent("Online.mov")
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Damage-H264", withExtension: "mp4", subdirectory: "Fixtures"))
            let online = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: online, to: second)
            let onlineDuration = try CutEngine(useSidecar: false).inspect(second, keyframes: true).duration
            let end = RationalTime(numerator: 1, denominator: 4)
            let project = directory.appendingPathComponent("Edit.cut")
            try model.openProject([
                .init(id: "missing", file: first.path, from: .zero, to: end),
                .init(id: "online", file: second.path, from: .zero, to: onlineDuration)
            ], at: project)
            try await waitUntil { !model.isBusy }
            XCTAssertEqual(model.timelineClips.first?.mediaStatus, .offline)
            XCTAssertEqual(model.preferredCopyContainer, "mov")
            XCTAssertFalse(model.isMixedTimeline)
            XCTAssertTrue(model.audioTracks.isEmpty)
            XCTAssertFalse(model.canScanScenes(clipID: try XCTUnwrap(model.timelineClips.first?.id)))
            model.selectRange(end.seconds, model.duration)
            let input = try model.mcpExportInput(selection: true)
            XCTAssertEqual(input.clips.map(\.file), [second])
            let export = directory.appendingPathComponent("Selection.mov")
            let planner = ExportPlanner(useSidecar: false)
            let request = ExportRequest(clips: input.clips, mode: .copy)
            switch planner.resolve(request, output: export, media: input.media) {
            case .ready(let plan, _, _):
                try planner.write(plan, to: export)
                XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
            case .unavailable(let issue, _):
                XCTFail(issue.localizedDescription)
            }

            try FileManager.default.copyItem(at: fixture, to: first)
            model.refreshProjectMedia()
            try await waitUntil { !model.isBusy && model.mediaClipReview.isEmpty }
            XCTAssertEqual(model.timelineClips.first?.mediaStatus, .online)
            XCTAssertEqual(model.preferredCopyContainer, "mp4")
            XCTAssertTrue(model.isMixedTimeline)
            XCTAssertEqual(model.audioTracks.count, 1)
            XCTAssertEqual(try model.mcpExportInput(selection: false).clips.map(\.file), [first, second])

            try FileManager.default.removeItem(at: first)
            model.refreshProjectMedia()
            try await waitUntil { !model.isBusy && model.timelineClips.first?.mediaStatus == .offline }
            XCTAssertEqual(model.preferredCopyContainer, "mov")
            XCTAssertFalse(model.isMixedTimeline)
            XCTAssertTrue(model.audioTracks.isEmpty)
            XCTAssertThrowsError(try model.mcpExportInput(selection: false))
        }
    }

    @MainActor
    func testRefreshDoesNotAliasUnavailableTraversalToOnlineSibling() async throws {
        try await withEditor { model, directory in
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
            let online = directory.appendingPathComponent("Recording.mov")
            try FileManager.default.copyItem(at: fixture, to: online)
            let end = RationalTime(numerator: 1, denominator: 4)
            let project = directory.appendingPathComponent("Edit.cut")
            try model.openProject([
                .init(id: "missing", file: "Absent/../Recording.mov", from: .zero, to: end),
                .init(id: "online", file: "Recording.mov", from: .zero, to: end)
            ], at: project)
            try await waitUntil { !model.isBusy }
            XCTAssertEqual(model.timelineClips.map(\.mediaStatus), [.offline, .online])
            model.refreshProjectMedia()
            try await waitUntil { !model.isBusy }
            XCTAssertEqual(model.timelineClips.map(\.mediaStatus), [.offline, .online])
            model.selectRange(end.seconds, model.duration)
            XCTAssertEqual(try model.mcpExportInput(selection: true).clips.map(\.file), [online])
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let timeout = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
    }

    @MainActor
    private func withEditor(_ exercise: (EditorModel, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = EditorModel()
        model.useAnalysisSidecars = false
        defer {
            model.endSession()
            try? FileManager.default.removeItem(at: directory)
        }
        try await exercise(model, directory)
    }
}
