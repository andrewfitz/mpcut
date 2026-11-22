import Darwin
import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class ProjectMediaRefreshTests: XCTestCase {
    @MainActor
    func testSequenceShorteningKeepsOccurrenceTrimsAndHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: fixture("Scene-Cadence-Change"), to: source)
        let model = EditorModel(preferences: preferences())
        defer { model.endSession() }
        model.importFiles([source, source])
        try await wait { !model.isBusy }
        XCTAssertNil(model.alert)
        let moved = try XCTUnwrap(model.timelineClips.last?.id)
        model.move(moved, to: 0)
        try await wait { !model.isBusy }
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.first?.id, moved)
        let ids = model.timelineClips.map(\.id)
        let trims = model.sequenceClips
        let history = model.historyEntryIDs

        try replace(source, with: fixture("ProRes-2997"))
        model.refreshProjectMedia()
        try await wait { model.mediaRefreshProgress == nil }
        XCTAssertEqual(model.timelineClips.map(\.id), ids)
        XCTAssertEqual(model.sequenceClips, trims)
        XCTAssertEqual(model.historyEntryIDs, history)
        XCTAssertEqual(Set(model.mediaClipReview.keys), Set(ids))
        XCTAssertThrowsError(try model.mcpExportInput(selection: false)) { error in
            XCTAssertEqual((error as? MCPCommandError)?.code, "source_needs_review")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: source).path))
    }

    @MainActor
    func testMulticamOfflineCameraStaysInProjectAndReturnsAfterRefresh() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.mov")
        let second = directory.appendingPathComponent("second.mov")
        for url in [first, second] { try FileManager.default.copyItem(at: fixture("ProRes-2997"), to: url) }
        let model = MulticamEditorModel(preferences: preferences())
        defer { model.reset() }
        let engine = CutEngine(useSidecar: false)
        let drafts = try [("a", first), ("b", second)].map { id, url in
            MulticamEditorModel.SourceDraft(source: .init(id: id, file: url.path), media: try engine.inspectMulticamSource(url))
        }
        model.confirmSetup(drafts: drafts, opening: "a", audio: .none)
        let project = try XCTUnwrap(model.project)
        let replacement = directory.appendingPathComponent("backup.mov")
        try FileManager.default.moveItem(at: second, to: replacement)

        model.refreshProjectMedia()
        try await wait { model.mediaRefreshProgress == nil }
        XCTAssertEqual(model.project, project)
        XCTAssertNil(model.media["b"])
        XCTAssertNotNil(model.media["a"])
        XCTAssertNotNil(model.mediaRefreshIssues["b"])
        XCTAssertNil(model.exportSourceIssue(tracks: .video, wholeGroup: true))

        try FileManager.default.moveItem(at: replacement, to: second)
        model.refreshProjectMedia()
        try await wait { model.mediaRefreshProgress == nil }
        XCTAssertEqual(model.project, project)
        XCTAssertNotNil(model.media["b"])
        XCTAssertNil(model.mediaRefreshIssues["b"])
    }

    @MainActor
    func testMulticamRefreshPreservesLeadingPCMSilenceForMOVExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: fixture("Multicam-Delayed-PCM"), to: source)

        let engine = CutEngine(useSidecar: false)
        let ordinary = try engine.inspect(source)
        let index = try engine.inspectMulticamSource(source)
        let audio = try XCTUnwrap(index.audio.first)
        XCTAssertGreaterThan(audio.start, .zero)
        let model = MulticamEditorModel(preferences: preferences())
        defer { model.reset() }
        model.confirmSetup(drafts: [.init(source: .init(id: "cam", file: source.path, audioStream: audio.stream.index),
                                         media: index, ordinaryMedia: ordinary)], opening: "cam", audio: .follow)
        let project = try XCTUnwrap(model.project)
        XCTAssertLessThan(try XCTUnwrap(project.plan().audio.first).input.from, audio.start)
        let revision = model.mcpRevision
        let original = try Data(contentsOf: source)
        try original.write(to: source, options: .atomic)
        model.refreshProjectMedia()
        try await wait { model.mediaRefreshProgress == nil }

        XCTAssertGreaterThan(model.mcpRevision, revision)
        XCTAssertNil(model.mediaRefreshIssues["cam"])
        XCTAssertNil(model.exportSourceIssue(tracks: .all, wholeGroup: true))
        XCTAssertNoThrow(try MulticamEngine().resolution(project, output: directory.appendingPathComponent("output.mov"),
                                                          mode: .copy, indexedSources: model.media).get())
        let document = directory.appendingPathComponent("editor.cut")
        try CutProject.multicam(project).save(to: document)
        let cold = try XCTUnwrap(MediaRefresh.project(at: document).first)
        let warm = try XCTUnwrap(MediaRefresh.project(at: document).first)
        XCTAssertEqual(cold.state, .refreshed)
        XCTAssertEqual(warm.state, .unchanged)
        XCTAssertTrue(cold.referenceIssues.isEmpty)
        XCTAssertTrue(warm.referenceIssues.isEmpty)
    }

    @MainActor
    func testAutomaticRefreshFollowsAtomicReplacementWhenEnabled() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: fixture("Scene-Cadence-Change"), to: source)
        let preferences = preferences()
        XCTAssertFalse(preferences.automaticallyRefreshMedia)
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        model.importFiles([source])
        try await wait { !model.isBusy }
        let id = try XCTUnwrap(model.timelineClips.first?.id)

        preferences.automaticallyRefreshMedia = true
        try replace(source, with: fixture("ProRes-2997"))
        try await wait { model.mediaClipReview[id] != nil && model.mediaRefreshProgress == nil }
        XCTAssertEqual(model.timelineClips.first?.id, id)
    }

    @MainActor
    func testAutomaticRefreshDetectsInPlaceRewriteWithRestoredStamp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.wav")
        try wave(amplitude: 100).write(to: source)
        let preferences = preferences()
        preferences.automaticallyRefreshMedia = true
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }
        model.importFiles([source])
        try await wait { !model.isBusy && model.analysisSourceMedia.values.first?.hasFullEditIndex == true }
        let id = try XCTUnwrap(model.analysisSourceMedia.keys.first)
        let before = try XCTUnwrap(model.analysisSourceMedia[id])
        func visiblePeak() -> Float? {
            model.audioStore.detail.envelope(for: id, surface: .viewer, from: 0, to: 0.1, pixels: 50)?
                .range(from: 0, to: 0.1)?.1
        }
        try await wait { visiblePeak().map { $0 > 0 && $0 < 0.01 } == true }
        let revision = model.mcpRevision
        var fileInfo = stat()
        XCTAssertEqual(stat(source.path, &fileInfo), 0)
        try wave(amplitude: 3_000).write(to: source)
        let times = [fileInfo.st_atimespec, fileInfo.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, source.path, $0.baseAddress, 0) }, 0)
        XCTAssertEqual(try SourceIdentity(source), before.identity)
        XCTAssertFalse(before.identity.isCurrentSnapshot(at: source))

        try await wait { model.mcpRevision > revision && model.mediaRefreshProgress == nil }
        let after = try XCTUnwrap(model.analysisSourceMedia[id])
        XCTAssertTrue(after.identity.isCurrentSnapshot(at: source))
        try await wait { visiblePeak().map { $0 > 0.08 } == true }
        XCTAssertTrue(model.sourcePauses.isEmpty)
        XCTAssertTrue(model.sceneReports.isEmpty)
        XCTAssertTrue(model.mediaClipReview.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: source).path))
    }

    @MainActor
    private func preferences() -> EditorPreferences {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        return preferences
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures"))
    }

    private func replace(_ source: URL, with fixture: URL) throws {
        try Data(contentsOf: fixture).write(to: source, options: .atomic)
    }

    private func wave(amplitude: UInt16) -> Data {
        let sampleCount = 16_000
        let byteCount = UInt32(sampleCount * 2)
        var result = Data("RIFF".utf8)
        func append<Integer: FixedWidthInteger>(_ value: Integer) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { result.append(contentsOf: $0) }
        }
        append(byteCount + 36)
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(byteCount)
        for _ in 0..<sampleCount { append(amplitude) }
        return result
    }

    @MainActor
    private func wait(_ completed: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !completed(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(completed(), "Timed out waiting for the editor")
    }
}
