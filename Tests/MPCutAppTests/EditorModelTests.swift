import Foundation
import XCTest
@testable import MPCutApp

final class EditorModelTests: XCTestCase {
    private enum TestError: Error {
        case editTimedOut
    }

    @MainActor
    func testFrameStepAndMarkedDeletionAcrossClipJoin() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let frame = 1001.0 / 30_000
        let model = EditorModel()
        defer { model.endSession() }

        model.importFiles([source, source])
        try await waitForEdit(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)

        model.seek(12 * frame)
        model.step(-1)
        XCTAssertEqual(model.playhead, 11 * frame, accuracy: 1e-9)
        model.step(1)
        XCTAssertEqual(model.playhead, 12 * frame, accuracy: 1e-9)
        model.seek(model.duration)
        model.step(-1)
        XCTAssertEqual(model.playhead, 23 * frame, accuracy: 1e-9)

        model.seek(4 * frame)
        model.setIn()
        model.setOut()
        model.deleteSelection()
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.dismissNotice()

        model.seek(15 * frame)
        model.setIn()
        model.deleteSelection()
        try await waitForEdit(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.timelineClips.count, 2)
        let left = try XCTUnwrap(model.timelineClips.first)
        let right = try XCTUnwrap(model.timelineClips.last)
        XCTAssertEqual(left.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(left.sourceEnd, 4 * frame, accuracy: 1e-9)
        XCTAssertEqual(right.sourceStart, 3 * frame, accuracy: 1e-9)
        XCTAssertEqual(right.sourceEnd, 12 * frame, accuracy: 1e-9)

        model.undo()
        XCTAssertEqual(model.duration, 24 * frame, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.markIn), 15 * frame, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.markOut), 4 * frame, accuracy: 1e-9)
        model.redo()
        XCTAssertEqual(model.duration, 13 * frame, accuracy: 1e-9)
        XCTAssertNil(model.markIn)
        XCTAssertNil(model.markOut)
    }

    @MainActor
    private func waitForEdit(_ model: EditorModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while model.isBusy, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if model.isBusy {
            throw TestError.editTimedOut
        }
    }
}
