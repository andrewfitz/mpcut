import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamAnalysisAuditTests: XCTestCase {
    @MainActor
    func testKeyframeNavigationUsesThePictureOfEachRepeatedOccurrence() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                      subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let keyframes = media.frames.filter(\.keyframe)
        let opening = try XCTUnwrap(keyframes.first)
        let next = try XCTUnwrap(keyframes.dropFirst().first)
        let offset = try next.time.subtracting(opening.time).multiplied(by: .init(numerator: 1, denominator: 2))
        let range = MulticamRange(from: opening.time, to: next.time)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: media.duration),
            angles: [.init(id: "wide", file: fixture.path), .init(id: "close", file: fixture.path, offset: offset)],
            audio: .none, switches: [.init(at: .zero, angle: "wide")],
            assemblyItems: [.group(range), .group(range, angle: "close")])
        let analysis = MulticamAnalysisStore()
        let indexed = ["wide": media, "close": media]
        analysis.update(project: project, media: indexed, ordinary: indexed, useSidecars: false)
        let expectedReplayMarker = try range.to.subtracting(range.from).adding(offset)
        XCTAssertEqual(analysis.pictureOutputMarkers(.keyframes, in: try project.plan()), [.zero, expectedReplayMarker])
        XCTAssertEqual(analysis.pictureSnapMarkers(.keyframes, angle: "close", project: project,
                                                   near: range.from, within: range, includeEnd: false), [offset])
    }

    @MainActor
    func testRenamingOneViewKeepsOtherAuthoredNames() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov",
                                                      subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture, to: url)
        let source = try CutEngine(useSidecar: false).inspect(url, keyframes: true)
        let report = try SceneAnalysis.scan(source, useSidecar: false)
        XCTAssertGreaterThanOrEqual(report.viewCount, 2)
        let first = report.scenes[0].view
        let other = try XCTUnwrap(report.scenes.map(\.view).first { $0 != first })
        var reviewed = report
        reviewed.setViewName("Room", for: first)
        reviewed.setViewName("Stage", for: other)
        var project = MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: source.duration),
                                      angles: [.init(id: "camera", file: url.path)],
                                      audio: .none, switches: [.init(at: .zero, angle: "camera")])
        XCTAssertTrue(project.analysisAnnotations.setScene(reviewed, for: source))
        let analysis = MulticamAnalysisStore()
        analysis.saveAnnotations = { next, _ in
            project.analysisAnnotations = next
            return true
        }
        analysis.update(project: project, media: ["camera": source], ordinary: ["camera": source], useSidecars: false)
        let scene = try XCTUnwrap(analysis.currentScene(at: .zero, project: project))
        XCTAssertEqual(scene.view, first)
        XCTAssertEqual(scene.name, "Room")
        let next = try XCTUnwrap(report.scenes.dropFirst().first)
        XCTAssertEqual(analysis.currentScene(at: next.start, angle: "camera", exclusiveEnd: true)?.index, 0)
        XCTAssertEqual(analysis.currentScene(at: next.start, angle: "camera", exclusiveEnd: false)?.index, 1)
        analysis.rename(scene, to: "Desk")

        let file = directory.appendingPathComponent("review.cut")
        try CutProject.multicam(project).save(to: file)
        let reopened = try CutProject.load(from: file)
        let saved = try XCTUnwrap(reopened.analysisAnnotations.scene(for: source))
        XCTAssertEqual(saved.views.first(where: { $0.view == first })?.name, "Desk")
        XCTAssertEqual(saved.views.first(where: { $0.view == other })?.name, "Stage")
        XCTAssertEqual(saved.scenes, report.scenes)
    }
}
