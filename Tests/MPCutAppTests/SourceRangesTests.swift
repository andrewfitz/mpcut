import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class SourceRangesTests: XCTestCase {
    func testSavedSelectSurvivesRemovalAndReopensWithoutTimelineMedia() async throws {
        let file = try fixture("ProRes-2997")
        let range = try SequenceSourceRange(file: file.path, from: .zero, to: RationalTime(parsing: "1001/30000"))
        let select = try NamedSourceSelect(id: "shot", name: "Opening shot", range: range)
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        try await editor.saveSourceSelect(select, expectedRevision: editor.mcpRevision)
        XCTAssertTrue(editor.sequenceClips.isEmpty)
        XCTAssertEqual(editor.stillProject.sourceSelects, [select])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Selects.cut")
        try editor.writeProject(to: project)
        let reopened = EditorModel()
        reopened.useAnalysisSidecars = false
        defer { reopened.endSession() }
        try reopened.openProject([], at: project)
        XCTAssertEqual(reopened.stillProject.sourceSelects, [select])
        try await reopened.applySourceRanges([select.range], destination: .init(from: .zero, to: .zero),
                                             expectedRevision: reopened.mcpRevision)
        XCTAssertEqual(reopened.sequenceClips.map(\.file), [file.path])
        reopened.deleteClip(try XCTUnwrap(reopened.mcpClipIDs.first))
        XCTAssertTrue(reopened.sequenceClips.isEmpty)
        XCTAssertEqual(reopened.stillProject.sourceSelects, [select])
        XCTAssertThrowsError(try reopened.validateHistoryDestination(file))
    }

    func testReplacementPreservesOrderAndCommitsOnlyAfterRevisionCheck() async throws {
        let first = try fixture("ProRes-2997")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try FileManager.default.copyItem(at: first, to: second)
        defer { try? FileManager.default.removeItem(at: second) }
        let frame = try RationalTime(parsing: "1001/30000")
        let a = try SequenceSourceRange(file: first.path, from: .zero, to: frame)
        let b = try SequenceSourceRange(file: second.path, from: frame, to: frame.adding(frame))
        let editor = EditorModel()
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        let start = MulticamRange(from: .zero, to: .zero)
        try await editor.applySourceRanges([a, a], destination: start, expectedRevision: editor.mcpRevision)
        let revision = editor.mcpRevision
        let original = editor.sequenceClips
        let destination = MulticamRange(from: .zero, to: frame)
        let invalid = try SequenceSourceRange(file: first.path, from: .zero, to: .init(numerator: 99))
        do {
            try await editor.applySourceRanges([a, invalid], destination: destination, expectedRevision: revision)
            XCTFail("Expected the entire plan to be rejected.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "invalid_source_range")
        }
        XCTAssertEqual(editor.sequenceClips, original)
        XCTAssertEqual(editor.mcpRevision, revision)
        do {
            try await editor.applySourceRanges([a], destination: destination, expectedRevision: revision - 1)
            XCTFail("Expected a stale revision refusal.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "stale_revision")
        }
        do {
            try await editor.applySourceRanges([a], destination: destination, expectedRevision: revision) {
                throw CutError(code: "control_disabled", message: "Refuse the staged edit.")
            }
            XCTFail("Expected the commit guard to refuse the staged plan.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "control_disabled")
        }
        XCTAssertEqual(editor.sequenceClips, original)
        XCTAssertEqual(editor.mcpRevision, revision)
        try await editor.applySourceRanges([b, a, b], destination: destination, expectedRevision: revision)
        XCTAssertEqual(editor.sequenceClips.map(\.file), [second.path, first.path, second.path, first.path])
        XCTAssertEqual(Set(editor.sequenceClips.map(\.id)).count, 4)
        XCTAssertEqual(editor.sequenceClips.last, original.last)
        XCTAssertEqual(editor.undoTitle, "Undo Replace With Source Ranges")
        editor.undo()
        XCTAssertEqual(editor.sequenceClips, original)
    }

    func testNewRangeDoesNotCreateSidecarAtSelectOnlyRecordingPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Camera.mov")
        try FileManager.default.copyItem(at: fixture("ProRes-2997"), to: file)
        let reserved = AnalysisSidecar.url(for: file)
        let end = RationalTime(numerator: 1001, denominator: 30000)
        let select = try NamedSourceSelect(id: "offline", name: "Offline recording",
                                          range: .init(file: reserved.path, from: .zero, to: end))
        let project = directory.appendingPathComponent("Reserved.cut")
        try CutProject.sequence([]).settingSourceSelect(select).save(to: project)
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = true
        try editor.openProject([], at: project)
        let range = try SequenceSourceRange(file: file.path, from: .zero, to: end)
        try await editor.applySourceRanges([range], destination: .init(from: .zero, to: .zero),
                                           expectedRevision: editor.mcpRevision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reserved.path))
        XCTAssertTrue(AnalysisSidecar.isExcluded(file, in: editor.sidecarExclusions))
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures"))
    }
}
