import Foundation
import XCTest
@testable import MPCutCore

final class SceneScanClockTests: XCTestCase {
    func testShiftedMovieClockDoesNotReplaceOrdinaryReport() throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("Needs ffmpeg for the leading-empty-edit fixture.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("late.mov")
        let graph = "color=red:s=160x90:r=25:d=1[a];color=blue:s=160x90:r=25:d=1[b];[a][b]concat=n=2:v=1:a=0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", graph, "-c:v", "libx264",
                             "-output_ts_offset", "2", source.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let engine = CutEngine()
        let ordinary = try engine.inspect(source)
        let shifted = try engine.inspectMulticamSource(source)
        XCTAssertGreaterThan(ordinary.origin, .zero)
        XCTAssertEqual(shifted.origin, .zero)
        XCTAssertGreaterThan(shifted.duration, ordinary.duration)

        let prepared = try SceneAnalysis.run(shifted, session: SceneScanSession())
        XCTAssertEqual(prepared.progress.durable, shifted.duration)
        XCTAssertEqual(prepared.report?.duration, shifted.duration)
        let cachedShifted = try SceneAnalysis.run(shifted, session: SceneScanSession())
        XCTAssertEqual(cachedShifted.state, .upToDate)
        XCTAssertEqual(cachedShifted.report?.duration, shifted.duration)

        let plain = try SceneAnalysis.run(source, session: SceneScanSession())
        let report = try XCTUnwrap(plain.report)
        XCTAssertEqual(report.origin, ordinary.origin)
        XCTAssertEqual(report.duration, ordinary.duration)
        XCTAssertEqual(report.scenes.count, 2)

        var replayed: [RationalTime] = []
        let cancelled = try SceneAnalysis.run(source, session: SceneScanSession(), cancelled: { !replayed.isEmpty },
                                              onScene: { time, _ in replayed.append(time) })
        XCTAssertEqual(cancelled.state, .paused)
        XCTAssertEqual(replayed, [.zero])
        XCTAssertEqual(cancelled.progress.durable, ordinary.duration)

        let start = try XCTUnwrap(report.scenes.dropFirst().first).start
        var boundaries: [RationalTime] = []
        let selected = try SceneAnalysis.run(ordinary, scope: .range(start: start, end: report.duration),
                                             session: SceneScanSession(), onScene: { time, _ in boundaries.append(time) })
        XCTAssertEqual(selected.state, .upToDate)
        XCTAssertEqual(boundaries, [start])
    }
}
