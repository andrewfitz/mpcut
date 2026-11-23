import Foundation
import XCTest
@testable import MPCutCore

final class ParticipantAnalysisTests: XCTestCase {
    func testCombinedScanUsesSourceClockAndReplayMatchesContinuousScan() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail C ABI is unavailable.") }
        let file = try fixture()
        let options = ParticipantScanOptions(backend: .cpu, includeScenes: true)
        var stop = false
        let paused = try ParticipantAnalysis.scan(file, options: options, cancelled: { stop }) { time in
            if time > .zero { stop = true }
        }
        XCTAssertEqual(paused.state, .paused)
        let prefix = try XCTUnwrap(paused.analysis)
        let resume = try XCTUnwrap(prefix.resumeAt)
        XCTAssertGreaterThan(resume, .zero)
        XCTAssertLessThan(resume, paused.source.duration)
        XCTAssertEqual(prefix.coverage.last?.start, resume)
        XCTAssertEqual(prefix.coverage.last?.status, .incomplete)
        XCTAssertNil(paused.sceneReport)
        let saved = try JSONDecoder().decode(ParticipantScanResult.self, from: JSONEncoder().encode(paused))
        XCTAssertThrowsError(try ParticipantAnalysis.scan(file, options: .init(backend: .cpu), resuming: saved)) {
            XCTAssertEqual(($0 as? CutError)?.code, "participant_resume_mismatch")
        }
        let resumed = try ParticipantAnalysis.scan(file, options: saved.configuration.options(), resuming: saved)
        let continuous = try ParticipantAnalysis.scan(file, options: .init(backend: .cpu, includeScenes: true, useSidecar: false))
        let reused = try ParticipantAnalysis.scan(file, options: options)
        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(continuous.state, .completed)
        XCTAssertEqual(reused.state, .upToDate)
        XCTAssertEqual(resumed.analysisIdentity, continuous.analysisIdentity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(resumed.analysis), try encoder.encode(continuous.analysis))
        var stopReplay = false
        let pausedAgain = try ParticipantAnalysis.scan(file, options: options, resuming: saved,
                                                       cancelled: { stopReplay }) { _ in stopReplay = true }
        XCTAssertEqual(pausedAgain.state, .paused)
        XCTAssertEqual(try encoder.encode(pausedAgain.analysis), try encoder.encode(saved.analysis))
        XCTAssertEqual(reused.analysis?.observations, resumed.analysis?.observations)
        XCTAssertEqual(resumed.source.origin, RationalTime(numerator: 2))
        XCTAssertEqual(resumed.source.duration, RationalTime(numerator: 4, denominator: 5))
        XCTAssertEqual(resumed.source.transform.rotation, .r270)
        XCTAssertEqual(resumed.source.transform.pixelAspectNum, 4)
        XCTAssertEqual(resumed.source.transform.pixelAspectDen, 3)
        XCTAssertEqual(resumed.analysis?.observations.first?.time, .zero)
        XCTAssertEqual(resumed.analysis?.observations.last?.time, RationalTime(numerator: 19, denominator: 25))
        XCTAssertEqual(resumed.analysis?.observations.count, 20)
        XCTAssertEqual(resumed.analysis?.observations.first?.display, resumed.source.transform)
        XCTAssertEqual(resumed.sceneReport?.scenes.first?.start, .zero)
        let sceneOnly = try SceneAnalysis.scan(file, useSidecar: false)
        XCTAssertEqual(resumed.sceneReport?.scenes.map(\.startPTS), sceneOnly.scenes.map(\.startPTS))
        XCTAssertEqual(resumed.sceneReport?.scenes.map(\.view), sceneOnly.scenes.map(\.view))
        XCTAssertNoThrow(try ParticipantAnalysis.markers(resumed))
        let sparse = try ParticipantAnalysis.scan(file, options: .init(backend: .cpu, sampling: .sparse, useSidecar: false))
        XCTAssertEqual(sparse.state, .completed)
        XCTAssertEqual(sparse.analysis?.observations.count, 4)
        XCTAssertFalse(sparse.analysis?.coverage.contains(where: { $0.status == .observed }) ?? true)
    }

    private func fixture() throws -> URL {
        let paths = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("The participant fixture requires ffmpeg.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-tiletrail-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let encoded = folder.appendingPathComponent("encoded.mov")
        let rotated = folder.appendingPathComponent("rotated.mov")
        func ffmpeg(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=96x64:r=25:d=0.8",
                    "-f", "lavfi", "-i", "color=c=blue:s=96x64:r=25:d=0.8",
                    "-filter_complex", "[0:v][1:v]hstack,setsar=4/3[v]", "-map", "[v]",
                    "-c:v", "mpeg4", "-output_ts_offset", "2", encoded.path])
        try ffmpeg(["-display_rotation", "90", "-i", encoded.path, "-c", "copy", "-copyts", rotated.path])
        return rotated
    }
}
