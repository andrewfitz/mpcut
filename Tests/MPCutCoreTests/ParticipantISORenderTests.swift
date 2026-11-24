import Darwin
import Foundation
@testable import MPCutCore
import XCTest

final class ParticipantISORenderTests: XCTestCase {
    func testFullHDISOsBatchUnderSurfaceBudget() throws {
        try checkLargeISOOutputs(width: 1920, height: 1080, expectedPasses: 2, expectedEncoders: 2)
    }

    func test4KISOsUseSeparatePicturePasses() throws {
        try checkLargeISOOutputs(width: 3840, height: 2160, expectedPasses: 3, expectedEncoders: 1)
    }

    private func checkLargeISOOutputs(width: Int, height: Int, expectedPasses: Int, expectedEncoders: Int) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let duration = RationalTime(numerator: 1, denominator: 8)
        let project = CutProject.sequence([.init(id: "clip", file: fixture.path, from: .zero, to: duration)])
        let plan = ParticipantRenderPlan(canvas: .init(width: width, height: height, frameRate: .init(numerator: 8)),
                                         shots: [.init(layout: .original)], audio: .init(mode: .silence))
        let jobs = (0..<3).map { (plan: plan, output: folder.appendingPathComponent("movie-\($0).mov")) }
        let start = ContinuousClock.now
        var completed = 0
        let metrics = try ParticipantRenderer().renderISOs(project, document: folder.appendingPathComponent("edit.cut"),
                                                           jobs: jobs) { index, report in
            XCTAssertEqual(report.frameCount, 1)
            let movie = try CutEngine(useSidecar: false, tracks: .video).inspect(jobs[index].output, keyframes: true)
            XCTAssertEqual(movie.videoStream?.displayWidth, width)
            XCTAssertEqual(movie.videoStream?.displayHeight, height)
            XCTAssertEqual(movie.duration, duration)
            XCTAssertEqual(movie.frames.count, 1)
            completed += 1
        }
        XCTAssertEqual(completed, jobs.count)
        XCTAssertEqual(metrics.picturePasses, expectedPasses)
        XCTAssertEqual(metrics.readerCount, expectedPasses)
        XCTAssertEqual(metrics.decodedPictureRequests, expectedPasses)
        XCTAssertEqual(metrics.peakEncoders, expectedEncoders)
        let stride = (width * 4 + 255) / 256 * 256
        XCTAssertEqual(metrics.peakSurfaceBytes, expectedEncoders * stride * height * 12)
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        print("ISO benchmark: \(width)x\(height), \(jobs.count) outputs / 1 frame, \(start.duration(to: .now)), process peak RSS \(usage.ru_maxrss) bytes, capped input surfaces \(metrics.peakSurfaceBytes) bytes")
    }

    func testOnlyPendingMixStillPreflightsDiskSpace() throws {
        let folder = FileManager.default.temporaryDirectory
        let project = CutProject.sequence([])
        XCTAssertThrowsError(try ParticipantRenderer().renderISOs(project,
            document: folder.appendingPathComponent("edit.cut"), jobs: [],
            additionalSpace: (file: folder.appendingPathComponent("mix.mov"), estimated: Double(Int64.max))) { _, _ in
                XCTFail("Disk preflight must finish before writing media.")
            }) {
                XCTAssertEqual(($0 as? CutError)?.code, "insufficient_disk_space")
            }
    }

    func testFortyFeedRenderSharesOneDecoder() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/SmartTrim-GOP.mp4")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("program.cut")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let ids = (0..<40).map { "feed-\($0)" }
        let people = ids.map { ParticipantPerson(id: $0, name: $0) }
        let appearances = ids.enumerated().map { index, id in
            ParticipantAppearance(id: "tile-\(index)", participantID: id, range: range,
                bounds: .init(x: Double(index % 8) / 8, y: Double(index / 8) / 5, width: 1.0 / 8, height: 1.0 / 5))
        }
        var project = CutProject.sequence([.init(id: "clip", file: fixture.path, from: range.from, to: range.to)])
        project.participants = .init(people: people, sources: [
            .init(sourceID: fixture.path, appearances: appearances, coverage: [.init(range: range, state: .verified)])
        ])
        let canvas = ParticipantCanvas(width: 160, height: 90, frameRate: .init(numerator: 8))
        let jobs = ids.map { id in
            (plan: ParticipantRenderPlan(canvas: canvas, shots: [.init(layout: .solo, slots: [.init(id: id)])],
                                         audio: .init(mode: .silence)),
             output: folder.appendingPathComponent(id).appendingPathExtension("mov"))
        }
        let start = ContinuousClock.now
        var finished: [Int] = []
        let metrics = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try ParticipantRenderer().renderISOs(project, document: document, jobs: jobs) { index, report in
                XCTAssertEqual(report.frameCount, 8)
                XCTAssertEqual(report.duration, range.to)
                XCTAssertEqual(report.output, jobs[index].output.path)
                finished.append(index)
            }
        }
        XCTAssertEqual(finished, Array(jobs.indices))
        XCTAssertEqual(metrics.readerCount, 1)
        XCTAssertEqual(metrics.picturePasses, 1)
        XCTAssertEqual(metrics.decodedPictureRequests, 8)
        XCTAssertEqual(metrics.peakEncoders, 40)
        XCTAssertLessThanOrEqual(metrics.peakSurfaceBytes, 32 * 1_024 * 1_024)
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        print("ISO benchmark: 40 crops / 8 frames, \(start.duration(to: .now)), process peak RSS \(usage.ru_maxrss) bytes, capped input surfaces \(metrics.peakSurfaceBytes) bytes")
    }
}
