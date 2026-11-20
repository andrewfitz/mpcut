import MPCutCore
import XCTest
@testable import MPCutApp

final class ExportSheetTests: XCTestCase {
    @MainActor
    func testReviewedCopyBoundsApplyAsOneUndoableEdit() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let engine = CutEngine()
        let media = try engine.inspect(url, keyframes: true)
        let unsafeStart = RationalTime(numerator: 7, denominator: 25)
        let sourceRequest = ClipRequest(file: url, from: unsafeStart, to: media.duration)
        let indexed = [url: media]
        let snapped = try engine.resolve([sourceRequest], snap: .nearest, media: indexed, container: "mp4")
        let review = try XCTUnwrap(ExportCutReview(original: [sourceRequest], snapped: snapped, media: indexed,
                                                   engine: engine, cancelled: { false }))
        XCTAssertEqual(review.revised.first?.from, .zero)
        XCTAssertNotEqual(review.original.first?.from, review.revised.first?.from)
        XCTAssertTrue(review.detail.contains("Total duration change: +"))

        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([url])
        for _ in 0..<500 where model.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try XCTUnwrap(model.selectedID)
        model.trim(id, edge: .start, sourceTime: unsafeStart.seconds, commit: true)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, unsafeStart.seconds)
        model.applyExportReview(review)
        XCTAssertEqual(model.timelineClips.first?.id, id)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0)
        model.undo()
        XCTAssertEqual(model.timelineClips.first?.sourceStart, unsafeStart.seconds)
        model.redo()
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0)
    }
}
