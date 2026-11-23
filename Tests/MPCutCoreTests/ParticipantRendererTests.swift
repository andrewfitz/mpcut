import Foundation
@testable import MPCutCore
import XCTest

final class ParticipantRendererTests: XCTestCase {
    func testTemporaryShotCannotRemoveSavedPrivacyTreatment() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        let document = source.deletingLastPathComponent().appendingPathComponent("participant-privacy.cut")
        let rangeEnd = RationalTime(numerator: 1)
        var project = CutProject.sequence([.init(id: "clip", file: source.path, from: .zero, to: rangeEnd)])
        project.participants = .init(people: [.init(id: "guest", name: "Guest")],
            render: .init(shots: [.init(layout: .original)], redactions: [.init(participantID: "guest", treatment: .opaque)]))
        let renderer = ParticipantRenderer()
        let override = ParticipantRenderPlan(shots: [.init(layout: .original)])
        let plan = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try renderer.report(project, document: document, plan: override)
        }
        XCTAssertFalse(plan.publishable)
        XCTAssertEqual(plan.privacyIssues, [
            .init(sourceID: source.path, source: .init(from: .zero, to: rangeEnd), output: .init(from: .zero, to: rangeEnd))
        ])
        var conflicting = override
        conflicting.redactions = [.init(participantID: "guest", treatment: .blur)]
        XCTAssertThrowsError(try renderer.report(project, document: document, plan: conflicting)) {
            XCTAssertEqual(($0 as? CutError)?.code, "participant_mask_conflict")
        }
    }

    func testRenderKeepsExactPartialFinalSample() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        let document = source.deletingLastPathComponent().appendingPathComponent("participant-cadence.cut")
        let length = RationalTime(numerator: 121, denominator: 120)
        let project = CutProject.sequence([.init(id: "clip", file: source.path, from: .zero, to: length)])
        let plan = ParticipantRenderPlan(canvas: .init(width: 160, height: 90), shots: [.init(layout: .original)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("result.mov")

        let report = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try ParticipantRenderer().render(project, document: document, plan: plan, to: output)
        }
        XCTAssertEqual(report.duration, length)
        XCTAssertEqual(report.frameCount, 31)
        XCTAssertEqual(report.output, output.path)
        let result = try CutEngine(useSidecar: false).inspect(output, keyframes: true)
        XCTAssertEqual(result.duration, length)
        XCTAssertEqual(result.frames.last?.time, .init(numerator: 1))
        XCTAssertEqual(result.frames.last?.duration, .init(numerator: 1, denominator: 120))
    }

    func testPlanRejectsUnrecognizedPrivacyKey() throws {
        let data = Data(#"{"shots":[{"layout":"original"}],"redaction":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ParticipantRenderPlan.self, from: data)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_participant_plan")
        }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures").appendingPathComponent(name)
    }
}
