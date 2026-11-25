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

    func testGalleryHintRoundTripsSeparatelyFromFixedLayout() throws {
        let gallery = try XCTUnwrap(ParticipantFeedLayout(galleryGrid: "5x5"))
        XCTAssertEqual(gallery, .gallery(columns: 5, rows: 5))
        XCTAssertNotEqual(gallery, ParticipantFeedLayout(feedLayout: "5x5"))
        XCTAssertNil(ParticipantFeedLayout(galleryGrid: "9x9"))
        let saved = try JSONEncoder().encode(ParticipantScanConfiguration(.init(feedLayout: gallery)))
        XCTAssertEqual(try JSONDecoder().decode(ParticipantScanConfiguration.self, from: saved).feedLayout, gallery)
    }

    func testEvenGridWithoutAnalyzerProvidesCellIdentityAndInferredCoverage() throws {
        let file = try fixture()
        let options = ParticipantScanOptions(sampling: .everyFrame, useSidecar: false,
                                             feedLayout: .fixed(columns: 2, rows: 2))
        let gpu = ParticipantScanOptions(backend: .gpuRequired, sampling: .everyFrame, useSidecar: false,
                                         feedLayout: options.feedLayout)
        XCTAssertThrowsError(try ParticipantAnalysis.fixedGridScan(file, columns: 2, rows: 2, options: gpu,
            partial: nil, cancelled: { false }, progress: nil)) { error in
            XCTAssertEqual((error as? CutError)?.code, "participant_gpu_unavailable")
        }
        let scan: ParticipantScanResult
        if ParticipantAnalysis.supportsFeedLayouts {
            scan = try ParticipantAnalysis.fixedGridScan(file, columns: 2, rows: 2, options: options,
                                                         partial: nil, cancelled: { false }, progress: nil)
        } else {
            scan = try ParticipantAnalysis.scan(file, options: options)
        }
        let analysis = try XCTUnwrap(scan.analysis)
        XCTAssertEqual(analysis.observations.count, 1)
        XCTAssertEqual(analysis.observations.first?.regions.map(\.participantID), [1, 2, 3, 4])
        XCTAssertEqual(analysis.coverage.map(\.status), [.inferred])
        var project = ParticipantProject()
        try project.acceptAnalysis(scan, sourceID: file.path)
        XCTAssertEqual(project.people.map(\.name), ["Feed 1", "Feed 2", "Feed 3", "Feed 4"])
        XCTAssertEqual(project.appearances(sourceID: file.path, at: .zero).count, 4)
        XCTAssertEqual(project.sources.first?.coverage.map(\.state), [.inferred])
    }

    func testStandaloneScanChecksProvenanceAndRetainsLayoutEvents() throws {
        let file = try fixture()
        let options = ParticipantScanOptions(backend: .cpu, sampling: .everyFrame, useSidecar: false,
                                             feedLayout: .fixed(columns: 2, rows: 1))
        let grid = try ParticipantAnalysis.fixedGridScan(file, columns: 2, rows: 1, options: options,
                                                         partial: nil, cancelled: { false }, progress: nil)
        let tiles = try XCTUnwrap(grid.analysis)
        let first = try XCTUnwrap(tiles.observations.first)
        let returnTime = try tiles.end.multiplied(by: .init(numerator: 1, denominator: 2))
        let other = first.regions[1]
        let returning = ParticipantRegion(appearanceID: other.appearanceID, participantID: nil, rect: other.rect,
            kind: .video, role: .primary, confidence: 1, identityConfidence: nil, identityUncertain: true,
            possibleMatches: [.init(participantID: first.regions[0].appearanceID, confidence: 0.8)])
        // The candidate has left: a feed still shown in another tile could not be this one.
        let later = ParticipantObservation(time: returnTime, display: first.display, confidence: 1,
                                           regions: [returning])
        let analysis = ParticipantTrackingResult(schemaVersion: tiles.schemaVersion, start: tiles.start, end: tiles.end,
            sampling: tiles.sampling, observations: [first, later], tracks: tiles.tracks, appearances: tiles.appearances,
            events: [.init(time: .zero, participantID: 1, appearanceID: 1, kind: .enter, uncertain: false)],
            coverage: tiles.coverage, diagnostics: tiles.diagnostics, resumeAt: nil)
        var source = grid.source
        source.inode = nil
        source.producer = "tiletrail"
        func scan(_ source: ParticipantScanSource) -> ParticipantScanResult {
            .init(state: .completed, source: source, configuration: grid.configuration, analysis: analysis,
                  sceneReport: nil, analysisIdentity: "standalone")
        }
        let document = file.deletingLastPathComponent().appendingPathComponent("review.cut")
        var project = CutProject.sequence([.init(id: "clip", file: file.path, from: .zero, to: source.duration)])
        var missing = source
        missing.contentSHA256 = nil
        XCTAssertThrowsError(try project.acceptParticipantAnalysis(scan(missing), sourceID: file.path, relativeTo: document))
        missing.contentSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try project.acceptParticipantAnalysis(scan(missing), sourceID: file.path, relativeTo: document))
        let wrongStream = ParticipantScanSource(file: source.file, stamp: source.stamp, inode: nil,
            producer: "tiletrail", contentSHA256: source.contentSHA256, stream: source.stream + 1,
            origin: source.origin, timeBase: source.timeBase, duration: source.duration, transform: source.transform)
        XCTAssertThrowsError(try project.acceptParticipantAnalysis(scan(wrongStream), sourceID: file.path, relativeTo: document))
        let envelope = try JSONEncoder().encode(scan(source))
        var standalone = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        standalone["analysis"] = try JSONSerialization.jsonObject(
            with: ParticipantSourceTime.originalClockJSON(analysis, origin: .zero)
        )
        let imported = try JSONDecoder().decode(ParticipantScanResult.self, from: JSONSerialization.data(withJSONObject: standalone))
        XCTAssertEqual(imported.analysis?.observations.map(\.time), [.zero, returnTime])
        try project.acceptParticipantAnalysis(imported, sourceID: file.path, relativeTo: document)
        let geometry = try XCTUnwrap(project.participants.sources.first)
        XCTAssertEqual(geometry.sourceInode, grid.source.inode)
        XCTAssertEqual(geometry.scanEvents.first?.tileID, geometry.appearances.first?.id)
        XCTAssertEqual(geometry.layoutChangeTimes, [.zero])
        let ambiguity = try XCTUnwrap(geometry.scanEvents.first { $0.identityEvidenceOnly == true })
        XCTAssertEqual(ambiguity.time, returnTime)
        XCTAssertEqual(ambiguity.candidates?.first?.precedingTime, .zero)
        XCTAssertEqual(ambiguity.candidates?.first?.precedingTileID, geometry.scanEvents.first?.tileID)
        let roundTrip = try JSONDecoder().decode(ParticipantProject.self, from: JSONEncoder().encode(project.participants))
        XCTAssertEqual(roundTrip.sources.first?.scanEvents, geometry.scanEvents)
    }

    func testAFeedShownInAnotherTileOfTheSameRoleIsNotACandidate() {
        let rect = ParticipantObservationRect(x: 0, y: 0, width: 0.5, height: 0.5)
        func region(_ appearance: UInt64, _ participant: UInt64?, role: ParticipantRegion.Role = .primary,
                    uncertain: Bool = false, matches: [UInt64] = []) -> ParticipantRegion {
            .init(appearanceID: appearance, participantID: participant, rect: rect, kind: .video, role: role,
                  confidence: 1, identityConfidence: nil, identityUncertain: uncertain,
                  possibleMatches: matches.map { .init(participantID: $0, confidence: 0.6) })
        }
        func observation(_ regions: [ParticipantRegion]) -> ParticipantObservation {
            .init(time: .zero, display: .init(rotation: .r0, pixelAspectNum: 1, pixelAspectDen: 1),
                  confidence: 1, regions: regions)
        }
        // Feed 1 is confidently in the other tile, so only feed 3 remains to weigh.
        let shown = observation([region(1, 1), region(2, 2, matches: [2, 1, 3])])
        XCTAssertEqual(shown.competingMatches(for: shown.regions[1]).map(\.participantID), [3])
        // With feed 1 as the only rival, a confident tile needs no review.
        let settled = observation([region(1, 1), region(2, 2, matches: [2, 1])])
        XCTAssertFalse(settled.needsIdentityReview(settled.regions[1]))
        // An uncertain tile still needs review, even without a rival left.
        let uncertain = observation([region(1, 1), region(2, 2, uncertain: true, matches: [1])])
        XCTAssertTrue(uncertain.needsIdentityReview(uncertain.regions[1]))
        // A stage and a thumbnail can show the same feed, and so can an unsure tile.
        let thumbnail = observation([region(1, 1, role: .thumbnail), region(2, 2, matches: [1])])
        XCTAssertEqual(thumbnail.competingMatches(for: thumbnail.regions[1]).map(\.participantID), [1])
        let unsure = observation([region(1, 1, uncertain: true), region(2, 2, matches: [1])])
        XCTAssertEqual(unsure.competingMatches(for: unsure.regions[1]).map(\.participantID), [1])
        // Two tiles that each name the other's feed both stay in question.
        let mutual = observation([region(1, 1, matches: [1, 2]), region(2, 2, matches: [2, 1])])
        XCTAssertTrue(mutual.needsIdentityReview(mutual.regions[0]))
        XCTAssertTrue(mutual.needsIdentityReview(mutual.regions[1]))
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
        let copied = file.deletingLastPathComponent().appendingPathComponent("Copied.mov")
        try FileManager.default.copyItem(at: file, to: copied)
        let rebound = try saved.rebindingPendingReview(to: copied)
        let resumed = try ParticipantAnalysis.scan(copied, options: saved.configuration.options(useSidecar: false), resuming: rebound)
        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(resumed.analysisIdentity, paused.analysisIdentity)
        let tracks = try XCTUnwrap(resumed.analysis?.tracks)
        XCTAssertEqual(tracks.count, 2)
        var project = ParticipantProject()
        try project.acceptAnalysis(resumed, sourceID: file.path)
        XCTAssertEqual(project.people.map(\.name), tracks.map { "Feed \($0.id)" })
    }

    func testCheckpointRestoresWithoutResubmittingPrefix() throws {
        guard ParticipantAnalysis.supportsCheckpoints else { throw XCTSkip("TileTrail checkpoints are unavailable.") }
        guard let file = try swapFixture(["-c:v", "libx264", "-g", "10", "-keyint_min", "10",
                                          "-sc_threshold", "0", "-bf", "2"]) else { throw XCTSkip("libx264 is unavailable.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for sampling in [ParticipantSampling.everyFrame, .adaptive, .sparse] {
            var options = ParticipantScanOptions(backend: .cpu, sampling: sampling, useSidecar: false,
                                                 feedLayout: .automatic)
            let continuous = try ParticipantAnalysis.scan(file, options: options)
            let directory = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            options.checkpointDirectory = directory
            var cancelled = false
            let paused = try ParticipantAnalysis.scan(file, options: options, cancelled: { cancelled }) { time in
                if time >= RationalTime(numerator: 3) { cancelled = true }
            }
            XCTAssertEqual(paused.state, .paused)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
            if sampling == .everyFrame {
                let chunk = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil).first { $0.lastPathComponent != "manifest.json" && $0.pathExtension == "json" })
                let bytes = try Data(contentsOf: chunk)
                try (bytes + Data([0x20])).write(to: chunk)
                XCTAssertThrowsError(try ParticipantAnalysis.scan(file, options: options)) {
                    XCTAssertEqual(($0 as? CutError)?.code, "participant_resume_mismatch")
                }
                try bytes.write(to: chunk)
                let manifestURL = directory.appendingPathComponent("manifest.json")
                let manifest = try Data(contentsOf: manifestURL)
                var unchecked = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
                unchecked["digests"] = [:] as [String: String]
                try JSONSerialization.data(withJSONObject: unchecked).write(to: manifestURL)
                XCTAssertThrowsError(try ParticipantAnalysis.scan(file, options: options)) {
                    XCTAssertEqual(($0 as? CutError)?.code, "participant_resume_mismatch")
                }
                try manifest.write(to: manifestURL)
            }

            var firstProgress: RationalTime?
            let resumed = try ParticipantAnalysis.scan(file, options: options, progress: { time in
                if firstProgress == nil { firstProgress = time }
            })
            let prefix = try XCTUnwrap(paused.analysis?.observations.last?.time)
            XCTAssertEqual(firstProgress, prefix, "\(sampling)")
            XCTAssertGreaterThan(prefix, .zero)
            XCTAssertEqual(resumed.state, .completed)
            XCTAssertEqual(try encoder.encode(resumed.analysis), try encoder.encode(continuous.analysis), "\(sampling)")
            ParticipantAnalysis.discardCheckpoint(for: resumed, directory: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        }
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

    func testCompleteMOVEditTailHasNoUnobservedBoxes() throws {
        guard ParticipantAnalysis.supportsFeedLayouts else { throw XCTSkip("TileTrail feed layouts are unavailable.") }
        let scan = try ParticipantAnalysis.scan(fixture(fractionalEdit: true),
            options: .init(backend: .cpu, sampling: .everyFrame, useSidecar: false, feedLayout: .fixed(columns: 1, rows: 1)))
        let result = try XCTUnwrap(scan.analysis)
        let end = RationalTime(numerator: 3)
        XCTAssertEqual(scan.state, .completed)
        XCTAssertEqual(result.end, RationalTime(numerator: 30399, denominator: 10000))
        XCTAssertEqual(result.coverage.map(\.status), [.observed, .unknown])
        XCTAssertEqual(result.coverage.last?.start, end)
        XCTAssertEqual(result.appearances.map(\.end), [end])
        var project = ParticipantProject()
        try project.acceptAnalysis(scan, sourceID: "clip")
        XCTAssertTrue(project.appearances(sourceID: "clip", at: end).isEmpty)
    }

    func testMatroskaFractionalFrameDurationsPreserveOnlyActualGaps() throws {
        guard ParticipantAnalysis.isAvailable else { throw XCTSkip("TileTrail is unavailable.") }
        let options = ParticipantScanOptions(backend: .cpu, sampling: .everyFrame, useSidecar: false)
        let continuous = try ParticipantAnalysis.scan(fixture(matroskaNTSC: .continuous), options: options)
        XCTAssertEqual(continuous.state, .completed)
        XCTAssertEqual(continuous.source.duration, RationalTime(numerator: 1001, denominator: 1000))
        XCTAssertEqual(continuous.analysis?.observations.count, 30)
        XCTAssertFalse(try XCTUnwrap(continuous.analysis).coverage.contains { $0.status == .incomplete })

        let trimmed = try ParticipantAnalysis.scan(fixture(matroskaNTSC: .trimmedFirstFrame), options: options)
        XCTAssertEqual(trimmed.source.origin, RationalTime(numerator: 33, denominator: 1000))
        XCTAssertEqual(trimmed.state, .completed)
        XCTAssertEqual(trimmed.analysis?.observations.count, 29)

        let withGap = try ParticipantAnalysis.scan(fixture(matroskaNTSC: .droppedFrames), options: options)
        XCTAssertEqual(withGap.state, .incomplete)
        let gaps = try XCTUnwrap(withGap.analysis).coverage.filter { $0.status == .incomplete }
        XCTAssertEqual(gaps.map(\.start), [RationalTime(numerator: 333, denominator: 1000)])
        XCTAssertEqual(gaps.map(\.end), [RationalTime(numerator: 467, denominator: 1000)])

        let shifted = try ParticipantAnalysis.scan(fixture(matroskaNTSC: .shiftedFrame), options: options)
        XCTAssertEqual(shifted.state, .incomplete)
        let shiftedGaps = try XCTUnwrap(shifted.analysis).coverage.filter { $0.status == .incomplete }
        XCTAssertEqual(shiftedGaps.map(\.start), [RationalTime(numerator: 33, denominator: 1000)])
        XCTAssertEqual(shiftedGaps.map(\.end), [RationalTime(numerator: 34, denominator: 1000)])
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

    private enum MatroskaNTSCFixture { case continuous, trimmedFirstFrame, droppedFrames, shiftedFrame }

    private func fixture(withGap: Bool = false, adaptiveMultiview: Bool = false,
                         matroskaNTSC: MatroskaNTSCFixture? = nil, fractionalEdit: Bool = false) throws -> URL {
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
        if fractionalEdit {
            let source = folder.appendingPathComponent("closed-gop.mp4")
            let clip = folder.appendingPathComponent("sub-frame-edit.mp4")
            try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=64x48:rate=25:duration=5",
                        "-f", "lavfi", "-i", "sine=duration=5:sample_rate=48000",
                        "-c:v", "libx264", "-g", "25", "-bf", "0", "-video_track_timescale", "30000",
                        "-c:a", "aac", source.path])
            try ffmpeg(["-ss", "1.0001", "-i", source.path, "-t", "3", "-c", "copy",
                        "-movie_timescale", "240000", clip.path])
            return clip
        }
        if adaptiveMultiview {
            let file = folder.appendingPathComponent("multiview.mov")
            try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=96x64:r=10:d=4",
                        "-f", "lavfi", "-i", "color=c=blue:s=96x64:r=10:d=4",
                        "-filter_complex", "[0:v][1:v]hstack", "-c:v", "mjpeg", "-q:v", "3", file.path])
            return file
        }
        if let matroskaNTSC {
            let file = folder.appendingPathComponent("fractional-cadence.mkv")
            let filters: [String]
            switch matroskaNTSC {
            case .continuous: filters = []
            case .trimmedFirstFrame: filters = ["-vf", "select='gte(n,1)'"]
            case .droppedFrames: filters = ["-vf", "select='not(between(n,10,13))'"]
            case .shiftedFrame: filters = ["-vf", #"settb=1/1000,setpts=PTS+eq(N\,1)"#]
            }
            try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30000/1001:duration=1"]
                + filters + ["-fps_mode", "passthrough", "-enc_time_base", "1/1000", "-c:v", "libx264", file.path])
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
