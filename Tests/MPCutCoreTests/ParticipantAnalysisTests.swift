import Foundation
import XCTest
@testable import MPCutCore

final class ParticipantAnalysisTests: XCTestCase {
    func testScanConfigurationRoundTripsFeedLayoutAndDefaultsLegacyScansToMeeting() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacy = Data(#"{"backend":"cpu","sampling":"every_frame","include_scenes":false}"#.utf8)
        let meeting = try decoder.decode(ParticipantScanConfiguration.self, from: legacy)
        XCTAssertEqual(meeting.feedLayout, .meeting)
        XCTAssertEqual(meeting, .init(.init(backend: .cpu, sampling: .everyFrame)))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(meeting)) as? [String: Any])
        XCTAssertNil(encoded["feed_layout"])

        for (value, layout) in [("auto", ParticipantFeedLayout.automatic), ("16x4", .fixed(columns: 16, rows: 4))] {
            XCTAssertEqual(ParticipantFeedLayout(feedLayout: value), layout)
            let config = ParticipantScanConfiguration(.init(feedLayout: layout))
            let copy = try decoder.decode(ParticipantScanConfiguration.self, from: encoder.encode(config))
            XCTAssertEqual(copy.options().feedLayout, layout)
        }
        for invalid in ["0x4", "9x8", "1X1", "+1x2", "4294967296x1", "1xx2"] {
            XCTAssertNil(ParticipantFeedLayout(feedLayout: invalid))
        }
    }

    func testFixedFeedsResumeAndAcceptWithFeedNames() throws {
        guard ParticipantAnalysis.supportsFeedLayouts else { throw XCTSkip("TileTrail feed layouts are unavailable.") }
        let file = try fixture()
        let options = ParticipantScanOptions(backend: .cpu, useSidecar: false, feedLayout: .fixed(columns: 1, rows: 2))
        var stop = false
        let paused = try ParticipantAnalysis.scan(file, options: options, cancelled: { stop }) { time in
            if time > .zero { stop = true }
        }
        XCTAssertEqual(paused.state, .paused)
        let saved = try JSONDecoder().decode(ParticipantScanResult.self, from: JSONEncoder().encode(paused))
        for layout in [ParticipantFeedLayout.meeting, .automatic, .fixed(columns: 2, rows: 1)] {
            XCTAssertThrowsError(try ParticipantAnalysis.scan(file, options: .init(backend: .cpu, useSidecar: false,
                                                                                 feedLayout: layout),
                                                                resuming: saved)) {
                XCTAssertEqual(($0 as? CutError)?.code, "participant_resume_mismatch")
            }
        }
        let resumed = try ParticipantAnalysis.scan(file, options: saved.configuration.options(useSidecar: false), resuming: saved)
        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(resumed.analysisIdentity, paused.analysisIdentity)
        let tracks = try XCTUnwrap(resumed.analysis?.tracks)
        XCTAssertEqual(tracks.count, 2)
        var project = ParticipantProject()
        try project.acceptAnalysis(resumed, sourceID: file.path)
        XCTAssertEqual(project.people.map(\.name), tracks.map { "Feed \($0.id)" })
    }

    func testScanStatusShowsIntermediatePercentAndVerifiedCompletion() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail is unavailable.") }
        let file = try fixture()
        let options = ParticipantScanOptions(backend: .cpu, sampling: .sparse)
        var events = [ParticipantScanProgress]()
        _ = try ParticipantAnalysis.scanWithStatus(file, options: options) { events.append($0) }
        XCTAssertEqual(events.first?.phase, .preparing)
        XCTAssertTrue(events.contains { $0.phase == .scanning && (1..<99).contains($0.percent) })
        XCTAssertTrue(events.contains { $0.phase == .finalizing })
        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(events.last?.percent, 100)
        XCTAssertTrue(events.dropLast().allSatisfy { $0.percent < 100 })
        XCTAssertEqual(events.map(\.percent), events.map(\.percent).sorted())
        events.removeAll()
        _ = try ParticipantAnalysis.scanWithStatus(file, options: options) { events.append($0) }
        XCTAssertEqual(events.map(\.phase), [.preparing, .checkingCache, .upToDate])
        XCTAssertEqual(events.last?.percent, 100)
        var stop = false
        events.removeAll()
        _ = try ParticipantAnalysis.scanWithStatus(file, options: .init(backend: .cpu, useSidecar: false),
                                                  cancelled: { stop }) { update in
            events.append(update)
            if update.phase == .scanning && update.percent >= 20 { stop = true }
        }
        XCTAssertEqual(events.last?.phase, .paused)
        XCTAssertTrue(events.allSatisfy { $0.percent < 100 })
    }

    func testAdaptiveProgressResumeCacheAndAcceptedCoverage() throws {
        guard ParticipantAnalysis.supportsFeedLayouts else { throw XCTSkip("TileTrail feed layouts are unavailable.") }
        let file = try fixture(adaptiveMultiview: true)
        let options = ParticipantScanOptions(backend: .cpu, sampling: .adaptive, feedLayout: .fixed(columns: 2, rows: 1))
        var stop = false
        var updates = [ParticipantScanProgress]()
        let paused = try ParticipantAnalysis.scanWithStatus(file, options: options, cancelled: { stop }) { update in
            updates.append(update)
            if update.phase == .scanning && update.percent >= 25 { stop = true }
        }
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(updates.last?.phase, .paused)
        XCTAssertTrue(updates.allSatisfy { $0.percent < 100 })
        updates.removeAll()
        let resumed = try ParticipantAnalysis.scanWithStatus(file, options: options, resuming: paused) { updates.append($0) }
        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(updates.last?.percent, 100)
        let analysis = try XCTUnwrap(resumed.analysis)
        XCTAssertEqual(resumed.configuration.sampling, .adaptive)
        XCTAssertEqual(analysis.sampling, .everyFrame)
        XCTAssertEqual(updates.map(\.percent), updates.map(\.percent).sorted())
        updates.removeAll()
        let reused = try ParticipantAnalysis.scanWithStatus(file, options: options) { updates.append($0) }
        XCTAssertEqual(reused.state, .upToDate)
        XCTAssertEqual(updates.map(\.phase), [.preparing, .checkingCache, .upToDate])

        var project = ParticipantProject()
        try project.acceptAnalysis(reused, sourceID: "grid")
        XCTAssertEqual(project.people.count, 2)
        if ParticipantAnalysis.supportsAdaptiveSampling {
            XCTAssertTrue(analysis.coverage.contains { $0.status == .inferred })
            XCTAssertTrue(try XCTUnwrap(project.sources.first).coverage.contains { $0.state == .inferred })
        } else {
            XCTAssertFalse(analysis.coverage.contains { $0.status == .inferred })
        }
    }

    func testAutomaticBackendUsesGPUOrReportsFallback() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail is unavailable.") }
        let file = try fixture()
        let auto = try ParticipantAnalysis.scan(file, options: .init(backend: .automatic, useSidecar: false))
        let initial = try XCTUnwrap(auto.analysis?.diagnostics.first)
        XCTAssertTrue(initial.backend == .gpu || initial.reason != nil)
        let cpu = try ParticipantAnalysis.scan(file, options: .init(backend: .cpu, useSidecar: false))
        XCTAssertEqual(cpu.analysis?.diagnostics.first?.backend, .cpu)
        XCTAssertNil(cpu.analysis?.diagnostics.first?.reason)
    }

    func testAdaptiveScanRefinesAChangeToTheEveryFrameResult() throws {
        guard ParticipantAnalysis.supportsAdaptiveSampling else { throw XCTSkip("TileTrail coarse pushes are unavailable.") }
        // Two tiles trade places at 3.3 s, between two keyframes. Motion JPEG
        // decodes one picture at a time. H.264 takes the threaded software
        // decoder, the span queue and batched conversion, with and without
        // reordered pictures.
        let encodings: [(name: String, arguments: [String])] = [
            ("mjpeg", ["-c:v", "mjpeg", "-q:v", "3"]),
            ("h264", ["-c:v", "libx264", "-g", "10", "-bf", "0", "-pix_fmt", "yuv420p"]),
            ("h264 reordered", ["-c:v", "libx264", "-g", "10", "-bf", "2", "-pix_fmt", "yuv420p"])
        ]
        var checked = 0
        for encoding in encodings {
            guard let file = try swapFixture(encoding.arguments) else {
                XCTAssertNotEqual(encoding.name, "mjpeg", "The built-in encoder must be available.")
                continue
            }
            checked += 1
            func scan(_ sampling: ParticipantSampling) throws -> ParticipantTrackingResult {
                let result = try ParticipantAnalysis.scan(file, options: .init(backend: .cpu, sampling: sampling, useSidecar: false))
                XCTAssertEqual(result.state, .completed, encoding.name)
                return try XCTUnwrap(result.analysis)
            }
            let every = try scan(.everyFrame)
            let adaptive = try scan(.adaptive)
            let sparse = try scan(.sparse)
            XCTAssertEqual(every.observations.count, 60, encoding.name)
            XCTAssertLessThan(adaptive.observations.count, 30, encoding.name)
            XCTAssertEqual(sparse.observations.count, 30, encoding.name)
            XCTAssertFalse(every.events.isEmpty, encoding.name)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func json(_ value: some Encodable) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
            XCTAssertEqual(try json(adaptive.events), try json(every.events), encoding.name)
            XCTAssertEqual(try json(adaptive.appearances), try json(every.appearances), encoding.name)
            XCTAssertEqual(try json(adaptive.tracks), try json(every.tracks), encoding.name)
            XCTAssertTrue(every.coverage.allSatisfy { $0.status == .observed }, encoding.name)
            let change = try XCTUnwrap(every.events.first?.time)
            // The span holding the change was decoded in full; a quiet one was not.
            XCTAssertEqual(adaptive.coverage.first { $0.start <= change && change < $0.end }?.status, .observed, encoding.name)
            XCTAssertEqual(adaptive.coverage.first?.status, .inferred, encoding.name)
            for observation in adaptive.observations {
                let reference = try XCTUnwrap(every.observations.first { $0.time == observation.time }, encoding.name)
                XCTAssertEqual(observation.regions.map(\.rect), reference.regions.map(\.rect), encoding.name)
                XCTAssertEqual(observation.regions.map(\.appearanceID), reference.regions.map(\.appearanceID), encoding.name)
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testWholePercentUsesExactSourceClockBoundaries() {
        let duration = RationalTime(numerator: 1001, denominator: 30)
        XCTAssertEqual(RationalTime(numerator: 7007, denominator: 3000).wholePercent(of: duration), 7)
        // Both values round to 0.5 as Double. Their exact positions straddle 50%.
        let scale = Int64.max / 2
        let below = RationalTime(numerator: scale, denominator: .max)
        let above = RationalTime(numerator: scale + 1, denominator: .max)
        XCTAssertEqual(below.wholePercent(of: RationalTime(numerator: 1)), 49)
        XCTAssertEqual(above.wholePercent(of: RationalTime(numerator: 1)), 50)
        let nearOne = RationalTime(numerator: Int64.max - 1, denominator: .max)
        XCTAssertEqual(below.wholePercent(of: nearOne), 50)
        XCTAssertEqual(RationalTime.zero.wholePercent(of: duration), 0)
        XCTAssertEqual(duration.wholePercent(of: duration), 100)
    }

    func testCancellationStatusDuringProbeAndCheckpointReplay() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail is unavailable.") }
        let file = try fixture()
        let options = ParticipantScanOptions(backend: .cpu, useSidecar: false)
        var events = [ParticipantScanProgress]()
        XCTAssertThrowsError(try ParticipantAnalysis.scanWithStatus(file, options: options, cancelled: { true }) {
            events.append($0)
        })
        XCTAssertEqual(events.map(\.phase), [.preparing, .paused])

        var stop = false
        let saved = try ParticipantAnalysis.scanWithStatus(file, options: options, cancelled: { stop }) { update in
            if update.phase == .scanning && update.percent >= 45 { stop = true }
        }
        let checkpoint = try XCTUnwrap(saved.analysis?.resumeAt)
        XCTAssertGreaterThan(checkpoint, .zero)
        stop = false
        events.removeAll()
        let interrupted = try ParticipantAnalysis.scanWithStatus(file, options: options, resuming: saved,
                                                               cancelled: { stop }) { update in
            events.append(update)
            if update.phase == .scanning { stop = true }
        }
        XCTAssertEqual(interrupted.state, .paused)
        XCTAssertEqual(interrupted.analysis?.resumeAt, checkpoint)
        XCTAssertEqual(events.last?.time, checkpoint)
        XCTAssertEqual(events.last?.percent, checkpoint.wholePercent(of: saved.source.duration))

        var invalid = try XCTUnwrap(saved.analysis)
        invalid.resumeAt = RationalTime(numerator: -1)
        let malformed = ParticipantScanResult(state: .paused, source: saved.source, configuration: saved.configuration,
                                              analysis: invalid, sceneReport: nil, analysisIdentity: saved.analysisIdentity)
        events.removeAll()
        XCTAssertThrowsError(try ParticipantAnalysis.scanWithStatus(file, options: options, resuming: malformed) {
            events.append($0)
        }) { XCTAssertEqual(($0 as? CutError)?.code, "participant_resume_mismatch") }
        XCTAssertEqual(events.last?.phase, .failed)
    }

    func testReplayVerifiesPastEarlierFrameGap() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail is unavailable.") }
        let file = try fixture(withGap: true)
        let options = ParticipantScanOptions(backend: .cpu, useSidecar: false)
        var stop = false
        let paused = try ParticipantAnalysis.scanWithStatus(file, options: options, cancelled: { stop }) { update in
            if update.phase == .scanning && update.percent >= 60 { stop = true }
        }
        let checkpoint = try XCTUnwrap(paused.analysis?.resumeAt)
        var updates = [ParticipantScanProgress]()
        let resumed = try ParticipantAnalysis.scanWithStatus(file, options: options, resuming: paused) { updates.append($0) }
        let gap = try XCTUnwrap(resumed.analysis?.resumeAt)
        XCTAssertEqual(resumed.state, .incomplete)
        XCTAssertLessThan(gap, checkpoint)
        XCTAssertEqual(updates.last?.phase, .incomplete)
        XCTAssertLessThan(try XCTUnwrap(updates.last?.percent), 100)
    }

    func testPartialCachedScanRequiresFreshAnalysis() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail is unavailable.") }
        let file = try fixture()
        let options = ParticipantScanOptions(backend: .cpu)
        let result = try ParticipantAnalysis.scan(file, options: options)
        let sidecar = try AnalysisSidecar(source: file)
        let section = "participant_tracking.v1." + result.analysisIdentity + ".tiles"
        let data = try XCTUnwrap(sidecar.read(section))
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var analysis = try XCTUnwrap(saved["analysis"] as? [String: Any])
        analysis["resume_at"] = analysis["start"]
        saved["analysis"] = analysis
        try sidecar.save([section: JSONSerialization.data(withJSONObject: saved)])
        var events = [ParticipantScanProgress]()
        let fresh = try ParticipantAnalysis.scanWithStatus(file, options: options) { events.append($0) }
        XCTAssertEqual(fresh.state, .completed)
        XCTAssertEqual(Array(events.prefix(3).map(\.phase)), [.preparing, .checkingCache, .scanning])
        XCTAssertEqual(events.last?.percent, 100)
    }

    func testChunkedReportMatchesFoundationForCompletedAndPartialScans() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail C ABI is unavailable.") }
        let scan = try ParticipantAnalysis.scan(fixture(), options: .init(backend: .cpu, includeScenes: true, useSidecar: false))
        let encoder = JSONEncoder()
        guard var report = try JSONSerialization.jsonObject(with: encoder.encode(scan)) as? [String: Any],
              var analysis = report["analysis"] as? [String: Any], let observations = analysis["observations"] as? [[String: Any]],
              var source = report["source"] as? [String: Any] else { return XCTFail("Missing report fields") }
        source["file"] = "/revisión/雪/\"observations\":[]"
        report["source"] = source
        analysis["observations"] = observations + observations + observations
        for state in ["completed", "up_to_date", "paused", "incomplete", "empty"] {
            let partial = state == "paused" || state == "incomplete"
            report["state"] = state == "empty" ? "paused" : state
            if partial { analysis["resume_at"] = ["numerator": 1, "denominator": 3] }
            else { analysis["resume_at"] = NSNull() }
            report["analysis"] = state == "empty" ? nil : analysis
            if partial { report["scene_report"] = nil }
            let value = try JSONDecoder().decode(ParticipantScanResult.self, from: JSONSerialization.data(withJSONObject: report))
            for pretty in [false, true] {
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
                var actual = Data()
                try value.writeJSON(pretty: pretty) { actual.append($0) }
                XCTAssertEqual(try encoder.encode(value), actual, "\(state), pretty \(pretty)")
            }
        }
    }

    func testSourceDigestNeverReturnsPartialHashAfterCancellation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 42, count: (1 << 20) + 1).write(to: file)
        var checks = 0
        XCTAssertThrowsError(try participantSourceDigest(file, identity: SourceIdentity(file)) {
            checks += 1
            return checks == 2
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testLegacyRegionReadsMissingUncertaintyAndEmitsCurrentWireKey() throws {
        var region: [String: Any] = [
            "appearance_id": 1, "participant_id": 2, "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
            "kind": "video", "role": "primary", "confidence": 0.9, "possible_matches": []
        ]
        func decode() throws -> ParticipantRegion {
            try JSONDecoder().decode(ParticipantRegion.self, from: JSONSerialization.data(withJSONObject: region))
        }
        XCTAssertFalse(try decode().identityUncertain)
        region["possible_matches"] = [["participant_id": 3, "confidence": 0.5]]
        let ambiguous = try decode()
        XCTAssertTrue(ambiguous.identityUncertain)
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ambiguous)) as? [String: Any]
        XCTAssertEqual(current?["identity_uncertain"] as? Bool, true)
        region["identity_uncertain"] = false
        XCTAssertFalse(try decode().identityUncertain)
    }

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
        let cachedClock = try AnalysisSidecar(source: file).loadSceneClock(cancelled: { false })
        XCTAssertEqual(cachedClock?.origin, resumed.source.origin)
        XCTAssertEqual(cachedClock?.duration, resumed.source.duration)
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
        var stopAtDigest = false
        let latePause = try ParticipantAnalysis.scan(file, options: .init(backend: .cpu, useSidecar: false),
                                                     cancelled: { stopAtDigest }) { time in
            if time == continuous.source.duration { stopAtDigest = true }
        }
        XCTAssertEqual(latePause.state, .paused)
        XCTAssertEqual(latePause.analysis?.resumeAt, continuous.source.duration)
        XCTAssertEqual(latePause.analysis?.observations, continuous.analysis?.observations)
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

    /// Two tiles on black that trade places at 3.3 s. Returns nil when
    /// ffmpeg lacks the requested encoder.
    private func swapFixture(_ encoding: [String]) throws -> URL? {
        let paths = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("The participant fixture requires ffmpeg.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-tiletrail-swap-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("swap.mov")
        let left = "x=4:y=44:w=184:h=128", right = "x=196:y=44:w=184:h=128"
        let boxes = [(left, "0xdc1824", "lt"), (right, "0x1ad22c", "lt"), (left, "0x1ad22c", "gte"), (right, "0xdc1824", "gte")]
            .map { "drawbox=\($0.0):color=\($0.1):t=fill:enable='\($0.2)(t,3.3)'" }.joined(separator: ",")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-loglevel", "quiet", "-nostdin", "-f", "lavfi",
                             "-i", "color=black:s=384x216:r=10:d=6", "-vf", boxes] + encoding + [file.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? file : nil
    }

    private func fixture(withGap: Bool = false, adaptiveMultiview: Bool = false) throws -> URL {
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
        if adaptiveMultiview {
            let file = folder.appendingPathComponent("multiview.mov")
            try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=96x64:r=10:d=4",
                        "-f", "lavfi", "-i", "color=c=blue:s=96x64:r=10:d=4",
                        "-filter_complex", "[0:v][1:v]hstack", "-c:v", "mjpeg", "-q:v", "3", file.path])
            return file
        }
        if withGap {
            let file = folder.appendingPathComponent("missing-frame.mkv")
            try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=96x64:r=25:d=0.8",
                        "-vf", "select='not(eq(n,3))'", "-fps_mode", "passthrough", "-c:v", "mpeg4", "-bf", "0", file.path])
            return file
        }
        try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=96x64:r=25:d=0.8",
                    "-f", "lavfi", "-i", "color=c=blue:s=96x64:r=25:d=0.8",
                    "-filter_complex", "[0:v][1:v]hstack,setsar=4/3[v]", "-map", "[v]",
                    "-c:v", "mpeg4", "-output_ts_offset", "2", encoded.path])
        try ffmpeg(["-display_rotation", "90", "-i", encoded.path, "-c", "copy", "-copyts", rotated.path])
        return rotated
    }
}
