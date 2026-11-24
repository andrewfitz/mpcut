import AppKit
@testable import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// The reader asks for the clocks it shows. These hold an open reader to the clocks it
/// builds, and to building none of them by reading one it had not asked for.
final class TranscriptReaderClockTests: XCTestCase {
    /// A window holding the reader alone.
    @MainActor
    private final class Reader {
        private let host: NSHostingView<AnyView>
        private let window: NSWindow

        init(_ session: ProjectSession) {
            host = NSHostingView(rootView: AnyView(TranscriptPane(session: session).equatable().frame(width: 380, height: 700)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: true)
            window.contentView = host
            window.setContentSize(NSSize(width: 380, height: 700))
        }

        private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let found = view as? T { return found }
            for child in view.subviews { if let found = find(type, in: child) { return found } }
            return nil
        }

        var words: [TranscriptOccurrence] { find(TranscriptFlowScrollView.self, in: host)?.layoutResult?.source.words ?? [] }

        /// The clock picker, which AppKit draws for a segmented SwiftUI picker.
        var clocks: NSSegmentedControl? { find(NSSegmentedControl.self, in: host) }

        func wait(for description: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    XCTFail("Timed out waiting for \(description). The reader shows ‘\(TranscriptPaneProbe.status)’.")
                    throw CancellationError()
                }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(4))
                host.layoutSubtreeIfNeeded()
            }
        }

        func close() { window.orderOut(nil); window.contentView = nil }
    }

    @MainActor
    func testAReaderBuildsTheClocksItShows() async throws {
        let fixture = try await Fixture(seconds: 600)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        let attachment = try await fixture.attach()
        TranscriptPaneProbe.status = ""
        let reader = Reader(fixture.session)
        defer { reader.close() }
        func built() -> Set<TranscriptSpace>? { controller.cachedIndex(attachmentID: attachment.id)?.builtSpaces }

        // Open on Current Cut, the reader holds that clock alone.
        try await reader.wait(for: "the transcript") { reader.words.count == 2_400 }
        XCTAssertEqual(reader.words.first?.space, .currentCut)
        XCTAssertEqual(built(), [.currentCut])
        XCTAssertNil(controller.cachedIndex(attachmentID: attachment.id, clocks: [.source]))

        // A reviewed deletion plans against every clock of the revision it reads, and the
        // reader then indexes the new revision for the clock it shows.
        var builds = controller.indexBuilds.count
        let index = try XCTUnwrap(controller.cachedIndex(attachmentID: attachment.id, clocks: [.currentCut]))
        let word = try XCTUnwrap(index.read(space: .currentCut, offset: 100, limit: 1).items.first)
        _ = try controller.apply(controller.plan(.init(action: .delete, selections: [
            .init(firstWordID: word.wordID, firstOccurrenceID: word.id)
        ], boundaryPolicy: .exact)))
        XCTAssertEqual(index.builtSpaces, Set(TranscriptSpace.allCases))
        try await reader.wait(for: "the edit") { reader.words.count == 2_399 }
        XCTAssertEqual(built(), [.currentCut])
        XCTAssertEqual(controller.indexBuilds.count - builds, 2, "The plan's clocks, then the reader's one.")

        // An edit made elsewhere rebuilds the one clock.
        builds = controller.indexBuilds.count
        fixture.session.editor.undo()
        try await reader.wait(for: "the undo") { reader.words.count == 2_400 }
        XCTAssertEqual(built(), [.currentCut])
        XCTAssertEqual(controller.indexBuilds.count - builds, 1)

        // Moving the reader to Source builds it, and a sequence reads no Group clock.
        builds = controller.indexBuilds.count
        let picker = try XCTUnwrap(reader.clocks, "The clock picker is an AppKit segmented control.")
        let stall = MainStall()
        picker.selectedSegment = 0
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        try await reader.wait(for: "the Source words") { reader.words.first?.space == .source }
        print("MEASURE reader moves to a clock it has not built: longest main-thread stall \(stall.finish()) ms")
        XCTAssertEqual(reader.words.count, 2_400)
        XCTAssertEqual(built(), [.source, .currentCut])
        XCTAssertEqual(controller.indexBuilds.count - builds, 1)

        // Back on Current Cut nothing is built, and nothing was built by a reader that had not asked.
        builds = controller.indexBuilds.count
        picker.selectedSegment = picker.segmentCount - 1
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        try await reader.wait(for: "the Current Cut words") { reader.words.first?.space == .currentCut }
        XCTAssertEqual(controller.indexBuilds.count - builds, 0)
        XCTAssertEqual(controller.unrequestedClockBuilds.count, 0)
    }

    @MainActor
    func testAnUndeclaredReadBuildsTheClockAndIsCounted() async throws {
        let fixture = try await Fixture(seconds: 60)
        defer { fixture.end() }
        let controller = fixture.session.transcript
        let attachment = try await fixture.attach()
        let index = try await controller.indexedTranscript(attachmentID: attachment.id, clocks: [.currentCut])
        XCTAssertEqual(index.builtSpaces, [.currentCut])
        let whole = try TranscriptIndex(document: fixture.document, attachment: controller.attachment(),
                                        project: controller.project, projectURL: controller.assetContext(),
                                        sequenceMedia: fixture.session.editor.transcriptMedia,
                                        timelineRevision: controller.timelineRevision)
        // A caller that names no clocks gets the same index, with every clock.
        let builds = controller.indexBuilds.count
        XCTAssertEqual(controller.unrequestedClockBuilds.count, 0)
        XCTAssertEqual(index.readAll(space: .source).map(\.id), whole.readAll(space: .source).map(\.id))
        XCTAssertFalse(whole.readAll(space: .source).isEmpty)
        XCTAssertEqual(controller.unrequestedClockBuilds.count, 1)
        XCTAssertEqual(controller.indexBuilds.count - builds, 1)
        let all = try await controller.indexedTranscript(attachmentID: attachment.id)
        XCTAssertEqual(all.builtSpaces, Set(TranscriptSpace.allCases))
        XCTAssertEqual(index.builtSpaces, Set(TranscriptSpace.allCases), "Every holder of a revision's index shares its clocks.")
        XCTAssertEqual(controller.unrequestedClockBuilds.count, 1)
        for space in TranscriptSpace.allCases {
            XCTAssertEqual(all.readAll(space: space).map(\.id), whole.readAll(space: space).map(\.id), space.rawValue)
        }
    }
}
