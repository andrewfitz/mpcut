import Foundation
import XCTest
@testable import MPCutCore

final class MulticamReplayTests: XCTestCase {
    private func t(_ value: Int64) -> RationalTime { .init(numerator: value) }

    private func range(_ from: Int64, _ to: Int64) -> MulticamRange {
        .init(from: t(from), to: t(to))
    }

    private var project: MulticamProject {
        .init(referenceAngle: "wide", range: range(0, 12),
              angles: [.init(id: "wide", file: "wide.mov", audioStream: 1),
                       .init(id: "close", file: "close.mov", audioStream: 2)],
              audioSources: [.init(id: "mic", file: "sound.wav")], audio: .follow,
              switches: [.init(at: .zero, angle: "wide"), .init(at: t(6), angle: "close",
                                                                audio: .init(source: "mic", stream: 3))],
              assembly: [range(3, 9), range(3, 9)])
    }

    func testAlternativeSearchPropagatesInterruption() {
        let destination = URL(fileURLWithPath: "/tmp/program.mov")
        for code in ["source_changed", "cancelled"] {
            var attempts = 0
            let resolution = MulticamEngine().resolution(output: destination, mode: .copy, tracks: .all,
                                                         settings: .init()) { _, _, _, _, candidate in
                attempts += 1
                throw CutError(code: candidate ? code : "unsafe_boundary", message: "Test planning failure")
            }
            XCTAssertThrowsError(try resolution.get()) { XCTAssertEqual(($0 as? CutError)?.code, code) }
            XCTAssertEqual(attempts, 2)
        }
    }

    func testReencodeAlternativesUseTheExplicitAudioActionWhenChoosingContainers() {
        let destination = URL(fileURLWithPath: "/tmp/program.mov")
        var alternatives: [String] = []
        _ = MulticamEngine().resolution(output: destination, mode: .encode, tracks: .all,
                                        settings: .init(audio: .pcm), audioAction: .aac) { output, _, _, settings, candidate in
            XCTAssertEqual(settings.audio, .aac)
            if candidate { alternatives.append(output.pathExtension) }
            throw CutError(code: "unsupported_audio", message: "Test planning failure")
        }
        XCTAssertEqual(alternatives, ["mp4"])
    }

    func testOccurrencePictureOverrideSurvivesSaveAndTrimWithProgramAudioIntact() throws {
        var edited = project
        edited.assemblyItems?[1] = .group(range(3, 9), angle: "close")
        let decoded = try MulticamProject.decode(JSONEncoder().encode(edited))
        XCTAssertEqual(decoded, edited)
        let plan = try decoded.plan()
        XCTAssertEqual(plan.intervals.map(\.angle), ["wide", "close", "close", "close"])
        XCTAssertEqual(plan.audio, try project.plan().audio)
        XCTAssertEqual(try decoded.groupIntervals(), try project.groupIntervals())
        XCTAssertEqual(try decoded.plan(ranges: [range(3, 9)]).picture.map(\.source), ["wide", "close"])
        let excerpt = try decoded.assemblySelection(range(7, 11))
        XCTAssertEqual(excerpt.assemblyItems, [.group(range(4, 8), angle: "close")])
        XCTAssertEqual(try excerpt.plan().picture.map(\.source), ["close"])
        edited.assemblyItems?[1] = .group(range(3, 9), angle: "mic")
        XCTAssertThrowsError(try edited.validate())
    }

    func testProposedSwitchCoverageUsesNextSwitchAndRetainsOrReplacesRouting() throws {
        let original = project
        let insert = try original.switchCoverage(at: t(2), angle: "close", media: [:])
        XCTAssertEqual(insert.group, range(2, 6))
        XCTAssertEqual(insert.audioRoute, .init(source: "close", stream: 2))
        XCTAssertEqual(insert.picture.status, .unavailable)
        XCTAssertEqual(insert.picture.missing, [range(2, 6)])
        XCTAssertEqual(insert.audio.status, .unavailable)
        let replace = try original.switchCoverage(at: t(6), angle: "wide", media: [:])
        XCTAssertEqual(replace.group, range(6, 12))
        XCTAssertEqual(replace.audioRoute, .init(source: "mic", stream: 3))
        XCTAssertEqual(original.switches, project.switches)
        var silent = original
        silent.audio = .none
        let noRoute = try silent.switchCoverage(at: t(2), angle: "close", media: [:])
        XCTAssertEqual(noRoute.audio.status, .unrouted)
        XCTAssertTrue(noRoute.audio.missing.isEmpty)
        var missingMic = original
        missingMic.angles[1].audioStream = nil
        let missingRoute = try missingMic.switchCoverage(at: t(2), angle: "close", media: [:])
        XCTAssertEqual(missingRoute.audio.status, .gaps)
        XCTAssertEqual(missingRoute.audio.missing, [range(2, 6)])
        XCTAssertThrowsError(try original.switchCoverage(at: t(12), angle: "wide", media: [:]))
    }

    func testProposedCoverageRejectsStaleIndexAndKeepsLaneSpecificAvailability() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Multicam-Delayed-PCM.mov")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture, to: file)
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(file)
        let track = try XCTUnwrap(media.audio.first)
        let frame = try XCTUnwrap(media.frames.first { $0.time >= track.start })
        let span = try MulticamRange(from: frame.time, to: min(track.end, frame.time.adding(frame.duration)))
        XCTAssertLessThan(span.from, span.to)
        let program = MulticamProject(referenceAngle: "cam", range: .init(from: .zero, to: span.to),
            angles: [.init(id: "cam", file: file.path, audioStream: track.stream.index)], audio: .follow,
            switches: [.init(at: .zero, angle: "cam")])
        let current = try program.switchCoverage(at: span.from, angle: "cam", media: ["cam": media])
        XCTAssertEqual(current.picture.status, .covered)
        XCTAssertEqual(current.audio.status, .covered)
        var missingStream = program
        missingStream.angles[0].audioStream = track.stream.index + 100
        let missing = try missingStream.switchCoverage(at: span.from, angle: "cam", media: ["cam": media])
        XCTAssertEqual(missing.audio.status, .unavailable)
        XCTAssertEqual(missing.audio.missing, [span])
        let review = try program.switchCoverage(at: span.from, angle: "cam", media: ["cam": media]) { $0.stream == nil }
        XCTAssertEqual(review.picture.status, .covered)
        XCTAssertEqual(review.audio.status, .unavailable)
        XCTAssertEqual(review.audio.missing, [span])
        try Data("changed".utf8).write(to: file)
        let stale = try program.switchCoverage(at: span.from, angle: "cam", media: ["cam": media])
        XCTAssertEqual(stale.picture.status, .unavailable)
        XCTAssertEqual(stale.audio.status, .unavailable)
    }

    func testMixSwitchCoverageKeepsOfflineLaneVisible() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Multicam-Delayed-PCM.mov")
        let info = try CutEngine(useSidecar: false).inspectMulticamSource(file)
        let track = try XCTUnwrap(info.audio.first)
        let frame = try XCTUnwrap(info.frames.first { $0.time >= track.start })
        let end = try frame.time.adding(frame.duration)
        var group = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: end),
                                    angles: [.init(id: "wide", file: file.path, audioStream: track.stream.index),
                                             .init(id: "close", file: "offline.mov", audioStream: 1)],
                                    audio: .mix, switches: [.init(at: .zero, angle: "wide")])
        group.mixLanes = group.defaultMixLanes
        let report = try group.switchCoverage(at: frame.time, angle: "wide", media: ["wide": info])
        XCTAssertEqual(report.audioLanes?.map(\.coverage.status), [.covered, .unavailable])
        XCTAssertEqual(report.audio.status, .unavailable)
        XCTAssertNil(report.audioRoute)
        XCTAssertEqual(report.audioRoutes.map(\.laneID), group.mixLanes.map { Optional($0.id) })

        let engine = CutEngine(useSidecar: false)
        let preview = try engine.multicamClock(engine.inspectForPreview(file))
        let from = try info.duration.adding(.init(numerator: 1))
        group.range.to = try from.adding(.init(numerator: 1))
        let provisional = try group.switchCoverage(at: from, angle: "wide", media: ["wide": preview, "close": info])
        XCTAssertEqual(provisional.audioLanes?.first?.coverage.status, .unavailable)
        XCTAssertEqual(provisional.audioLanes?.first?.coverage.missing, [.init(from: from, to: group.range.to)])
    }
}
