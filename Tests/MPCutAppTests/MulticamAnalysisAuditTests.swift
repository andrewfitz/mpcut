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
        let sidecar = AnalysisSidecar(media: source)
        var sections = try AnalysisSidecar.sceneSections(for: report)
        sections[AnalysisSidecar.viewNameSectionKey] = try AnalysisSidecar.viewNameData(
            [first: "Room", other: "Stage"], for: report)
        try sidecar.save(sections)

        let project = MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: source.duration),
                                      angles: [.init(id: "camera", file: url.path)],
                                      audio: .none, switches: [.init(at: .zero, angle: "camera")])
        let sessions = ProjectSessions(preferences: EditorPreferences(), openWindow: { _ in })
        XCTAssertTrue(sessions.reopen())
        let session = try XCTUnwrap(sessions.sessions.values.first)
        session.isMulticam = true
        let analysis = session.multicam.analysis
        analysis.update(project: project, media: ["camera": source], ordinary: ["camera": source], useSidecars: true)
        analysis.scan(.scenes)
        try await waitUntil { !analysis.sourceScenes("camera").isEmpty && !analysis.isScanning(.scenes) }
        let scene = try XCTUnwrap(analysis.currentScene(at: .zero, project: project))
        XCTAssertEqual(scene.view, first)
        XCTAssertEqual(scene.name, "Room")
        let next = try XCTUnwrap(report.scenes.dropFirst().first)
        XCTAssertEqual(analysis.currentScene(at: next.start, angle: "camera", exclusiveEnd: true)?.index, 0)
        XCTAssertEqual(analysis.currentScene(at: next.start, angle: "camera", exclusiveEnd: false)?.index, 1)
        analysis.rename(scene, to: "Desk")

        func saved() -> [Int: String] {
            let views = sidecar.sceneReport(for: source)?.views ?? []
            return Dictionary(uniqueKeysWithValues: views.compactMap { view in view.name.map { (view.view, $0) } })
        }
        // Read only after the write. A reader in this process can make a concurrent sidecar write fail.
        sessions.windowClosed(session)
        var quitAllowed = false
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, reply: { quitAllowed = $0 }), .later)
        try await waitUntil { quitAllowed }
        XCTAssertEqual(sessions.prepareToQuit(stopExports: { true }, reply: { _ in }), .now)

        XCTAssertEqual(saved(), [first: "Desk", other: "Stage"])
    }

    @MainActor
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready())
    }
}
