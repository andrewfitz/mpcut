import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamStillEditorTests: XCTestCase {
    @MainActor
    func testTypedAssemblyTimelineAndHiddenCoverUndo() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = EditorPreferences()
        let savedHistoryLimit = preferences.historyLimit
        preferences.historyLimit = 10
        defer { preferences.historyLimit = savedHistoryLimit }
        let model = MulticamEditorModel(preferences: preferences, draft: ProjectDraft(directory: root.appendingPathComponent("Drafts")))
        defer { model.reset() }
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        model.confirmSetup(drafts: [.init(source: .init(id: "camera", file: fixture.path), media: media)],
                           opening: "camera", audio: .none)
        func time(_ hundredths: Int64) -> RationalTime { .init(numerator: hundredths, denominator: 100) }
        let group = MulticamRange(from: .zero, to: time(30))
        let photo = StillAsset(id: "photo", file: root.appendingPathComponent("photo.png").path,
                               displayName: "Photo", fingerprint: "fixture")
        XCTAssertTrue(model.edit("Repeat Group") { $0.assemblyItems = [.group(group), .group(group)] })
        XCTAssertTrue(model.performStillEdit("Replace Picture") {
            try $0.addingStillAsset(photo).addingStillReplacement(
                .init(id: "cover", assetID: photo.id, framing: .fit, coverage: .group(.init(from: time(10), to: time(20)))))
        })
        XCTAssertTrue(model.performStillEdit("Insert Still") {
            try $0.insertingStill(.init(id: "title", assetID: photo.id, duration: time(4), cadence: time(2)), at: time(30))
        })
        model.setAssemblyPreview(true)
        XCTAssertEqual(model.assemblyRangeEnds, [time(30), time(34), time(64)])
        XCTAssertEqual(model.occurrenceIndex(at: time(30)), 1)
        XCTAssertNil(model.interval(at: time(30)))
        XCTAssertEqual(model.occurrenceIndex(at: time(34)), 2)
        XCTAssertEqual(model.interval(at: time(34))?.assemblyIndex, 2)
        XCTAssertEqual(model.assemblyAssetSpans.map(\.interval), [
            .init(from: time(10), to: time(20)), .init(from: time(30), to: time(34)),
            .init(from: time(44), to: time(54))
        ])
        model.seekAssembly(at: time(32), scrubbing: false)
        model.step(1)
        XCTAssertEqual(model.preview.time, time(34))
        XCTAssertEqual(model.selectedOccurrence, 2)
        model.step(-1)
        XCTAssertEqual(model.preview.time, time(32))
        XCTAssertEqual(model.selectedOccurrence, 1)

        model.changeOccurrence(2, to: time(5))
        XCTAssertEqual(model.assemblyStill(at: 1)?.id, "title")
        XCTAssertEqual(model.assemblyAssetSpans.count, 2)
        model.undo()
        XCTAssertEqual(model.assemblyAssetSpans.count, 3)

        model.reorderAssemblyOccurrence(1, before: 0)
        XCTAssertEqual(model.assemblyStill(at: 0)?.id, "title")
        XCTAssertEqual(model.assemblyRangeEnds, [time(4), time(34), time(64)])
        model.undo()
        XCTAssertEqual(model.assemblyStill(at: 1)?.id, "title")

        model.selectAssemblyRange(time(30), time(34))
        model.exportProgram = .selection
        let selection = try XCTUnwrap(model.stillExportDocument(wholeGroup: false, selection: model.selectedExportRanges))
        XCTAssertEqual(selection.stillInserts.map(\.id), ["title"])
        XCTAssertEqual(try selection.resolveStills().duration, time(4))

        model.seekAssembly(at: time(32), scrubbing: false)
        XCTAssertTrue(model.canCutOccurrence)
        model.splitOccurrence()
        XCTAssertEqual(model.assemblyItems.compactMap(\.still).map(\.duration), [time(2), time(2)])
        model.undo()
        XCTAssertEqual(model.assemblyItems.compactMap(\.still).map(\.duration), [time(4)])

        XCTAssertTrue(model.saveProject(to: root.appendingPathComponent("Interview.cut")))
        let reopened = try CutProject.loadDocument(from: root.appendingPathComponent("Interview.cut"), limit: 10)
        XCTAssertEqual(reopened.project.stillInserts.first?.id, "title")
        XCTAssertEqual(reopened.project.stillAssets.first?.file, "photo.png")
        XCTAssertTrue(model.protectedMediaPaths.keys.contains(photo.file))
    }
}
