import Foundation
@testable import MPCutCore
import XCTest

final class TilesISODeliveryTests: XCTestCase {
    func testAliasReviewChangeInvalidatesCoverCheckpoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let recording = folder.appendingPathComponent("gallery.mp4")
        let linked = folder.appendingPathComponent("alias.mp4")
        try FileManager.default.copyItem(at: fixture, to: recording)
        try FileManager.default.linkItem(at: recording, to: linked)

        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let sources = [recording.path, linked.path]
        var project = CutProject.sequence(sources.enumerated().map { index, file in
            .init(id: "clip-\(index)", file: file, from: range.from, to: range.to)
        })
        let host = ParticipantAppearance(id: "main", participantID: "host", range: range,
                                         bounds: .init(x: 0, y: 0, width: 1, height: 1))
        let guest = ParticipantAppearance(id: "inset", participantID: "guest", range: range,
                                          bounds: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        project.participants = .init(people: [
            .init(id: "host", name: "Host"), .init(id: "guest", name: "Guest", treatment: .init(mode: .cover)),
        ], sources: sources.map { .init(sourceID: $0, appearances: [host, guest],
                                        coverage: [.init(range: range, state: .verified)]) })
        let document = folder.appendingPathComponent("edit.cut")
        func prepare() throws -> TilesISOPlan {
            try TilesISODelivery.plan(project: project, document: document, sourceID: recording.path, range: range,
                canvas: .init(width: 160, height: 90), blankUncertain: true, audio: .init(meetingMix: false))
        }

        let checked = try prepare()
        XCTAssertFalse(checked.issues.contains { $0.code == "unchecked_privacy" })
        project.participants.sources[1].appearances[1].bounds.x = 0.6
        let changed = try prepare()
        XCTAssertTrue(changed.issues.contains { $0.code == "unchecked_privacy" && !$0.blocking })
        XCTAssertNotEqual(checked.provenance, changed.provenance)
    }
}
