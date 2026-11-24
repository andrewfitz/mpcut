import Foundation
@testable import MPCutCore
import XCTest

final class ParticipantRendererTests: XCTestCase {
    func testRendererProtectsAnOfflineCameraPath() throws {
        let folder = FileManager.default.temporaryDirectory
        let output = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let project = CutProject.multicam(.init(referenceAngle: "active", range: .init(from: .zero, to: .init(numerator: 1)),
            angles: [.init(id: "active", file: fixture("SmartTrim-GOP.mp4").path), .init(id: "offline", file: output.lastPathComponent)],
            audio: .none, switches: [.init(at: .zero, angle: "active")],
            participants: .init(render: .init(shots: [.init(layout: .original)]))))
        let document = folder.appendingPathComponent("program.cut")
        let renderer = ParticipantRenderer()
        XCTAssertThrowsError(try renderer.report(project, document: document, output: output)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cut_project_source_collision")
        }
        XCTAssertThrowsError(try renderer.render(project, document: document, to: output)) {
            XCTAssertEqual(($0 as? CutError)?.code, "cut_project_source_collision")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

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

    func testPendingReconciledIdentityBlocksMaskEvenWithVerifiedFrames() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        let document = source.deletingLastPathComponent().appendingPathComponent("participant-reconcile.cut")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        var project = CutProject.sequence([.init(id: "clip", file: source.path, from: range.from, to: range.to)])
        project.participants = .init(people: [.init(id: "guest", name: "Guest")],
            sources: [.init(sourceID: source.path, coverage: [.init(range: range, state: .verified)],
                            unresolvedParticipantIDs: ["guest"])],
            render: .init(shots: [.init(layout: .original)], redactions: [.init(participantID: "guest", treatment: .opaque)]))
        try AnalysisSidecar.$readsEnabled.withValue(false) {
            let renderer = ParticipantRenderer()
            let pending = try renderer.report(project, document: document)
            XCTAssertFalse(pending.publishable)
            XCTAssertEqual(pending.privacyIssues.first?.source, range)
            try project.participants.confirmReconciledParticipant(sourceID: source.path, participantID: "guest")
            let approved = try renderer.report(project, document: document)
            XCTAssertTrue(approved.publishable)
            XCTAssertTrue(approved.privacyIssues.isEmpty)
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

    func testTimedShotsKeepAdjacentCutsAndOccurrencePrecedence() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        func time(_ halves: Int64) -> RationalTime { .init(numerator: halves, denominator: 2) }
        func range(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: time(from), to: time(to)) }
        let project = CutProject.sequence([
            .init(id: "a", file: source.path, from: .zero, to: time(4)),
            .init(id: "b", file: source.path, from: .zero, to: time(4))
        ])
        let fallback = ParticipantShot(layout: .original)
        let first = ParticipantShot(range: range(0, 2), layout: .original)
        let second = ParticipantShot(range: range(2, 6), layout: .original)
        let scoped = ParticipantShot(range: range(5, 7), occurrence: 1, layout: .original)
        var plan = ParticipantRenderPlan(shots: [second, fallback, scoped, first])
        try plan.validate()
        let timeline = try ParticipantRenderTimeline(project: project, document: source,
            timeline: project.resolveStillsUnchecked(), plan: plan, checkCancellation: {})

        XCTAssertEqual(timeline.window(at: time(0))?.shot, first)
        XCTAssertEqual(timeline.window(at: time(2))?.shot, second)
        XCTAssertEqual(timeline.window(at: time(4))?.shot, second)
        XCTAssertEqual(timeline.window(at: time(5))?.shot, scoped)
        XCTAssertEqual(timeline.window(at: time(6))?.shot, scoped)
        XCTAssertEqual(timeline.window(at: time(7))?.shot, fallback)
        XCTAssertNil(timeline.window(at: time(8)))

        plan.shots.append(.init(range: range(1, 3), layout: .original))
        XCTAssertThrowsError(try plan.validate()) {
            XCTAssertEqual(($0 as? CutError)?.message, "Timed shots on the same clock must not overlap.")
        }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures").appendingPathComponent(name)
    }
}
