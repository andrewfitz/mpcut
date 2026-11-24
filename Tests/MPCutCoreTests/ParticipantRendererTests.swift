import CoreGraphics
import CoreImage
import Foundation
import ImageIO
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
        let migrated = try project.migratingLegacyTiles()
        XCTAssertFalse(try renderer.report(migrated, document: document, plan: override).publishable)
        let native = try migrated.settingFeedTreatment(feedID: "guest", treatment: .init(mode: .remove))
        XCTAssertTrue(try renderer.report(native, document: document, plan: override).publishable)
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

    func testWholeRecordingReviewCanResolveVerifiedAbsence() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        let document = source.deletingLastPathComponent().appendingPathComponent("participant-absence.cut")
        let media = try CutEngine(useSidecar: false, tracks: .video).inspectSummary(source)
        let whole = MulticamRange(from: .zero, to: media.duration)
        let firstSecond = MulticamRange(from: .zero, to: .init(numerator: 1))
        let tail = MulticamRange(from: firstSecond.to, to: whole.to)
        var project = CutProject.sequence([.init(id: "clip", file: source.path, from: .zero, to: whole.to)])
        let confirmedCoverage: [ParticipantCoverage] = [
            .init(range: firstSecond, state: .verified), .init(range: tail, state: .verified)
        ]
        let digest = try verifiedParticipantPrivacyDigest(media, cancelled: { false })
        let host = ParticipantAppearance(id: "host-tile", participantID: "host", range: whole,
                                         bounds: .init(x: 0, y: 0, width: 1, height: 1))
        project.participants = .init(people: [.init(id: "guest", name: "Guest"), .init(id: "host", name: "Host")],
            sources: [.init(sourceID: source.path, sourceStamp: SceneSourceStamp(media: media),
                            sourceInode: media.identity.inode, sourceContentSHA256: digest, appearances: [host],
                            coverage: confirmedCoverage, unresolvedParticipantIDs: ["guest"],
                            historicalParticipantIDs: ["guest"])],
            render: .init(shots: [.init(layout: .original)], redactions: [.init(participantID: "guest", treatment: .opaque)]))
        let renderer = ParticipantRenderer()
        XCTAssertFalse(try renderer.report(project, document: document).publishable)

        func confirm(_ project: inout CutProject, range: MulticamRange? = nil) throws {
            try project.confirmParticipantPrivacy(sourceID: source.path, participantID: "guest", range: range,
                                                  relativeTo: document)
        }

        var partial = project
        try confirm(&partial, range: firstSecond)
        XCTAssertEqual(partial.participants.sources[0].unresolvedParticipantIDs, ["guest"])
        XCTAssertFalse(try renderer.report(partial, document: document).publishable)

        for coverage: [ParticipantCoverage] in [
            [.init(range: firstSecond, state: .verified)],
            [.init(range: whole, state: .inferred)]
        ] {
            var uncertain = project
            uncertain.participants.sources[0].coverage = coverage
            try confirm(&uncertain)
            XCTAssertEqual(uncertain.participants.sources[0].unresolvedParticipantIDs, ["guest"])
            XCTAssertFalse(try renderer.report(uncertain, document: document).publishable)
        }

        var unassigned = project
        unassigned.participants.sources[0].appearances[0].participantID = nil
        try confirm(&unassigned)
        // Unassigning the host tile also makes its former identity unresolved.
        XCTAssertEqual(unassigned.participants.sources[0].unresolvedParticipantIDs, ["guest", "host"])
        XCTAssertFalse(try renderer.report(unassigned, document: document).publishable)

        var unknown = project
        unknown.participants.sources[0].appearances[0].state = .unknown
        try confirm(&unknown)
        XCTAssertEqual(unknown.participants.sources[0].unresolvedParticipantIDs, ["guest"])
        XCTAssertFalse(try renderer.report(unknown, document: document).publishable)

        var changed = project
        changed.participants.sources[0].sourceContentSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try confirm(&changed))
        XCTAssertEqual(changed.participants.sources[0].unresolvedParticipantIDs, ["guest"])

        try confirm(&project)
        XCTAssertEqual(project.participants.sources[0].unresolvedParticipantIDs, [])
        XCTAssertEqual(project.participants.sources[0].historicalParticipantIDs, ["guest"])
        XCTAssertTrue(try renderer.report(project, document: document).publishable)
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

    func testOrdinaryProResSelectionKeepsStillInsertAndLayoutCanvas() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("selection.cut")
        let output = folder.appendingPathComponent("selection.mov")
        let cadence = RationalTime(numerator: 1, denominator: 30)
        let length = RationalTime(numerator: 1, denominator: 20)
        let asset = StillAsset(gapID: "card")
        let canvas = ParticipantCanvas(width: 160, height: 90)
        let clip = CutSequenceClip(id: "camera", file: source.path, from: .zero, to: length)
        let still = StillInsert(id: "insert", assetID: asset.id, duration: .init(numerator: 1, denominator: 15), cadence: cadence)
        var project = CutProject.stillSequence(.init(items: [.source(clip), .still(still)], stillAssets: [asset]))
        project.participants.tileOutput = .init(canvas: canvas, audio: .init(mode: .silence))
        let selection = MulticamRange(from: cadence, to: .init(numerator: 7, denominator: 60))

        try AnalysisSidecar.$readsEnabled.withValue(false) {
            let prepared = try ParticipantProjectExport(project, relativeTo: document, output: output, mode: .encode,
                                                        tracks: .video, settings: .init(codec: .prores), range: selection)
            XCTAssertEqual(prepared.report.duration, .init(numerator: 1, denominator: 12))
            XCTAssertEqual(prepared.report.frameCount, 4)
            try prepared.write(to: output)

            let movie = try CutEngine(useSidecar: false).inspect(output, keyframes: true)
            XCTAssertEqual(movie.frames.count, 4)
            XCTAssertEqual(movie.frames[1].time, .init(numerator: 1, denominator: 60))
            XCTAssertEqual(movie.video.codec, "prores")
            XCTAssertEqual(movie.video.width, canvas.width)
            XCTAssertEqual(movie.video.height, canvas.height)
            let picture = try ParticipantOutputPicture(project: project, document: document, forceSDR: true)
            let jpeg = try picture.jpeg(at: length, preset: .full)
            XCTAssertEqual(jpeg.width, canvas.width)
            XCTAssertEqual(jpeg.height, canvas.height)
        }
    }

    func testNativeAudioOnlySelectionUsesTheOutputClockAndDisclosesSharedAudio() throws {
        let source = fixture("Shuttle-Chirp.mov")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("selection.cut")
        let output = folder.appendingPathComponent("selection.wav")
        let clip = CutSequenceClip(id: "camera", file: source.path, from: .init(numerator: 1), to: .init(numerator: 2))
        var project = CutProject.sequence([clip])
        project.participants = .init(people: [.init(id: "guest", name: "Guest", treatment: .init(mode: .cover))],
                                     tileOutput: .init(audio: .init(mode: .program)))
        let selection = MulticamRange(from: .init(numerator: 1, denominator: 4),
                                      to: .init(numerator: 3, denominator: 4))
        let export = try ParticipantProjectExport(project, relativeTo: document, output: output, mode: .encode,
                                                  tracks: .audio, settings: .init(audio: .pcm), range: selection)
        XCTAssertEqual(export.report.duration, .init(numerator: 1, denominator: 2))
        XCTAssertEqual(export.report.frameCount, 0)
        XCTAssertNotNil(export.report.audioPrivacyNotice)
        XCTAssertEqual(export.report.audioActions.first?.sources.first?.input.from, .init(numerator: 5, denominator: 4))
        try export.write(to: output)

        let rendered = try CutEngine(useSidecar: false, tracks: .audio).inspect(output)
        XCTAssertEqual(rendered.duration, .init(numerator: 1, denominator: 2))
        XCTAssertFalse(rendered.hasVideo)
        let silent = try project.settingProjectOutputAudio(.init(mode: .silence))
        XCTAssertThrowsError(try ParticipantProjectExport(silent, relativeTo: document,
            output: folder.appendingPathComponent("silent.wav"), mode: .encode, tracks: .audio)) {
            XCTAssertEqual(($0 as? CutError)?.code, "no_audio")
        }
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

    func testPrivateOutputScopesCoverageToRecordingAndCrop() throws {
        let original = fixture("SmartTrim-GOP.mp4")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gallery = directory.appendingPathComponent("gallery.mp4")
        let broll = directory.appendingPathComponent("b-roll.mp4")
        try FileManager.default.copyItem(at: original, to: gallery)
        try FileManager.default.copyItem(at: original, to: broll)
        let document = directory.appendingPathComponent("private.cut")
        let one = RationalTime(numerator: 1)
        let two = RationalTime(numerator: 2)
        let three = RationalTime(numerator: 3)
        let sourceRange = MulticamRange(from: .zero, to: one)
        let media = try CutEngine(tracks: .video).inspectSummary(gallery)
        var project = CutProject.sequence([
            .init(id: "opening", file: gallery.path, from: .zero, to: one),
            .init(id: "b-roll", file: broll.path, from: .zero, to: one),
            .init(id: "closing", file: gallery.path, from: .zero, to: one),
        ])
        let unknown = ParticipantAppearance(id: "unassigned", range: sourceRange,
                                            bounds: .init(x: 0.8, y: 0, width: 0.2, height: 1))
        let inset = ParticipantAppearance(id: "inset", participantID: "guest", range: sourceRange,
                                          bounds: .init(x: 0.25, y: 0.3, width: 0.25, height: 0.4))
        let host = ParticipantAppearance(id: "main", participantID: "host", range: sourceRange,
                                         bounds: .init(x: 0, y: 0, width: 0.75, height: 1))
        project.participants = .init(people: [
            .init(id: "host", name: "Host"),
            .init(id: "guest", name: "Guest", treatment: .init(mode: .cover, color: 0xff00ff)),
        ], sources: [
            .init(sourceID: gallery.path, analysisIdentity: "test-scan", sourceStamp: .init(media: media),
                  sourceInode: media.identity.inode, appearances: [host, inset, unknown],
                  coverage: [.init(range: sourceRange, state: .verified)]),
        ])
        let canvas = ParticipantCanvas(width: 160, height: 90)
        let originalPlan = ParticipantRenderPlan(canvas: canvas, shots: [.init(layout: .original)])
        let cropped = ParticipantRenderPlan(canvas: canvas, shots: [
            .init(layout: .original),
            .init(range: .init(from: .zero, to: one), layout: .solo, slots: [.init(id: "host")]),
            .init(range: .init(from: two, to: three), layout: .solo, slots: [.init(id: "host")]),
        ])
        let renderer = ParticipantRenderer()
        XCTAssertEqual(try renderer.report(project, document: document, plan: originalPlan).privacyIssues.map(\.output), [
            .init(from: .zero, to: one), .init(from: two, to: three),
        ])
        XCTAssertThrowsError(try renderer.frame(project, document: document, plan: originalPlan, at: .zero)) {
            XCTAssertEqual(($0 as? CutError)?.code, "unresolved_participant_privacy")
        }
        XCTAssertTrue(try renderer.report(project, document: document, plan: cropped).publishable)
        for time in [RationalTime.zero, two] {
            let image = try renderer.frame(project, document: document, plan: cropped, at: time)
            let (red, green, blue) = try centerPixel(of: image)
            XCTAssertGreaterThan(red, 230)
            XCTAssertLessThan(green, 25)
            XCTAssertGreaterThan(blue, 230)
        }

        // An inferred frame is gated even when the last-known unassigned box is outside the crop.
        project.participants.sources[0].coverage = [.init(range: sourceRange, state: .inferred)]
        XCTAssertFalse(try renderer.report(project, document: document, plan: cropped).publishable)
        try project.confirmParticipantPrivacy(sourceID: gallery.path, participantID: "guest", range: sourceRange,
                                              relativeTo: document)
        let restored = try JSONDecoder().decode(ParticipantProject.self, from: JSONEncoder().encode(project.participants))
        project.participants = restored
        XCTAssertTrue(try renderer.report(project, document: document, plan: cropped).publishable)
        XCTAssertFalse(try renderer.report(project, document: document, plan: originalPlan).publishable)

        // A saved-file edit bypasses in-memory observers and still expires the review.
        let bytes = try JSONEncoder().encode(project.participants)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var sources = try XCTUnwrap(saved["sources"] as? [[String: Any]])
        var appearances = try XCTUnwrap(sources[0]["appearances"] as? [[String: Any]])
        var bounds = try XCTUnwrap(appearances[1]["bounds"] as? [String: Any])
        bounds["x"] = 0.20
        appearances[1]["bounds"] = bounds
        sources[0]["appearances"] = appearances
        saved["sources"] = sources
        project.participants = try JSONDecoder().decode(ParticipantProject.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertFalse(try renderer.report(project, document: document, plan: cropped).publishable)
        project.participants = restored
        let changedTreatment = try project.settingFeedTreatment(feedID: "guest", treatment: .init(mode: .cover, color: 0xffff00))
        XCTAssertFalse(try renderer.report(changedTreatment, document: document, plan: cropped).publishable)
        let restoredTreatment = try changedTreatment.settingFeedTreatment(feedID: "guest", treatment: .init(mode: .cover, color: 0xff00ff))
        XCTAssertFalse(try renderer.report(restoredTreatment, document: document, plan: cropped).publishable)

        // Relinking the last guest tile must reopen review and must keep the source in scope.
        try project.participants.linkAppearance(sourceID: gallery.path, appearanceID: inset.id, participantID: "host",
                                                range: sourceRange)
        XCTAssertNil(project.participants.sources[0].confirmations)
        XCTAssertTrue(project.participants.sources[0].historicalParticipantIDs?.contains("guest") == true)
        XCTAssertFalse(try renderer.report(project, document: document, plan: cropped).publishable)

        try project.confirmParticipantPrivacy(sourceID: gallery.path, participantID: "guest", range: sourceRange,
                                              relativeTo: document)
        let replacement = directory.appendingPathComponent("replacement.mp4")
        try FileManager.default.copyItem(at: original, to: replacement)
        try FileManager.default.removeItem(at: gallery)
        try FileManager.default.moveItem(at: replacement, to: gallery)
        let stale = try renderer.report(project, document: document, plan: cropped)
        XCTAssertEqual(stale.staleSourceIDs, [gallery.path])
        XCTAssertFalse(stale.publishable)
        XCTAssertEqual(stale.privacyIssues.map(\.output), [.init(from: .zero, to: one), .init(from: two, to: three)])
    }

    func testConfirmationCannotPublishUnknownGeometryOrOverlappingNameplate() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("review.cut")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let host = ParticipantAppearance(id: "host-tile", participantID: "host", range: range,
                                        bounds: .init(x: 0, y: 0, width: 0.5, height: 1))
        let guest = ParticipantAppearance(id: "guest-tile", participantID: "guest", range: range,
                                         bounds: .init(x: 0.65, y: 0, width: 0.35, height: 0.4))
        let unassigned = ParticipantAppearance(id: "unassigned", range: range,
                                               bounds: .init(x: 0.6, y: 0.6, width: 0.4, height: 0.4),
                                               labelBounds: .init(x: 0.2, y: 0.4, width: 0.2, height: 0.2))
        var project = CutProject.sequence([.init(id: "clip", file: source.path, from: .zero, to: range.to)])
        project.participants = .init(people: [.init(id: "host", name: "Host"),
                                             .init(id: "guest", name: "Guest", treatment: .init(mode: .cover, color: 0xff00ff))],
            sources: [.init(sourceID: source.path, appearances: [host, guest, unassigned],
                            coverage: [.init(range: range, state: .verified)])])
        let renderer = ParticipantRenderer()
        var plan = ParticipantRenderPlan(canvas: .init(width: 160, height: 90, background: 0x00ff00),
                                         shots: [.init(layout: .solo, slots: [.init(id: "host")])])

        func checkBlocked() throws {
            try project.confirmParticipantPrivacy(sourceID: source.path, participantID: "guest", range: range, relativeTo: document)
            let report = try renderer.report(project, document: document, plan: plan)
            XCTAssertFalse(report.publishable)
            XCTAssertEqual(report.privacyIssues.map(\.source), [range])
            XCTAssertThrowsError(try renderer.frame(project, document: document, plan: plan, at: .zero)) {
                XCTAssertEqual(($0 as? CutError)?.code, "unresolved_participant_privacy")
            }
        }

        try checkBlocked()
        project.participants.sources[0].appearances = [host, guest]
        project.participants.sources[0].coverage = [.init(range: range, state: .unknown)]
        try checkBlocked()
        project.participants.sources[0].coverage = [.init(range: range, state: .inferred)]
        try project.confirmParticipantPrivacy(sourceID: source.path, participantID: "guest", range: range, relativeTo: document)
        XCTAssertTrue(try renderer.report(project, document: document, plan: plan).publishable)
        project.participants.sources[0].appearances = [host]
        try checkBlocked()

        plan.unresolvedPrivacy = .cover
        let output = folder.appendingPathComponent("covered.mov")
        let report = try renderer.render(project, document: document, plan: plan, to: output,
                                         settings: .init(audio: .removeAudio))
        XCTAssertEqual(report.privacyIssues.map(\.output), [range])
        let media = try CutEngine().inspect(output, keyframes: true)
        let (jpeg, _) = try JPEGExport.reviewFrame(media, at: .zero, exclusiveEnd: false, preset: .full, cancelled: { false })
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let (red, green, blue) = try centerPixel(of: XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil)))
        XCTAssertLessThan(red, 25)
        XCTAssertGreaterThan(green, 230)
        XCTAssertLessThan(blue, 25)
    }

    func testOutputOnlyReusesDecodedPixelsFromTheCurrentRecording() throws {
        let source = fixture("SmartTrim-GOP.mp4")
        let other = fixture("Pause-Noisy.mov")
        let document = source.deletingLastPathComponent().appendingPathComponent("handoff.cut")
        let project = CutProject.sequence([.init(id: "clip", file: source.path, from: .zero, to: .init(numerator: 1))])
        let renderer = ParticipantRenderer()
        let plan = ParticipantRenderPlan(canvas: .init(width: 160, height: 90), shots: [.init(layout: .original)])
        let session = try renderer.prepare(project, document: document, plan: plan, cancelled: nil)
        let sentinel = ParticipantCompositor.color(0x00ff00, in: session.extent)
        let buffer = try ParticipantPictureColor.sdr.render(sentinel, extent: session.extent)

        func output(sourceIdentity: SourceIdentity) throws -> (UInt8, UInt8, UInt8) {
            let decoded = ParticipantDecodedPicture(buffer: buffer, sourceID: source.path, sourceTime: .zero,
                                                    sourceIdentity: sourceIdentity)
            let image = try session.picture(at: .zero, decoded: decoded)
            let rendered = try XCTUnwrap(ParticipantCompositor.context.createCGImage(image, from: session.extent,
                format: .RGBA8, colorSpace: ParticipantCompositor.colorSpace))
            return try centerPixel(of: rendered)
        }

        let reused = try output(sourceIdentity: SourceIdentity(source))
        XCTAssertLessThan(reused.0, 25)
        XCTAssertGreaterThan(reused.1, 230)
        XCTAssertLessThan(reused.2, 25)
        let expected = try centerPixel(of: renderer.frame(project, document: document, plan: plan, at: .zero))
        let redecoded = try output(sourceIdentity: SourceIdentity(other))
        XCTAssertEqual([redecoded.0, redecoded.1, redecoded.2], [expected.0, expected.1, expected.2])
    }

    func testRecordingAliasesReceiveTheSameTreatmentInEncodedOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = fixture("SmartTrim-GOP.mp4")
        let source = folder.appendingPathComponent("recording.mp4")
        let alias = folder.appendingPathComponent("alternate.mp4")
        let unrelated = folder.appendingPathComponent("another-recording.mp4")
        try FileManager.default.copyItem(at: original, to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        try FileManager.default.copyItem(at: original, to: unrelated)
        let document = folder.appendingPathComponent("aliases.cut")
        let output = folder.appendingPathComponent("output.mov")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let files = [source.lastPathComponent, source.path, alias.lastPathComponent, unrelated.lastPathComponent, original.path]
        var project = CutProject.sequence(files.enumerated().map { index, file in
            .init(id: "clip-\(index)", file: file, from: .zero, to: range.to)
        })
        let indexed = try CutEngine(tracks: .video).inspectSummary(source)
        let other = try CutEngine(tracks: .video).inspectSummary(unrelated)
        let verified = [ParticipantCoverage(range: range, state: .verified)]
        let appearance = ParticipantAppearance(id: "guest-tile", participantID: "guest", range: range,
                                              bounds: .init(x: 0.25, y: 0.2, width: 0.5, height: 0.6))
        project.participants = .init(people: [.init(id: "guest", name: "Guest", treatment: .init(mode: .cover, color: 0xff00ff))],
            sources: [.init(sourceID: source.lastPathComponent, analysisIdentity: "accepted",
                            sourceStamp: .init(media: indexed), sourceInode: indexed.identity.inode,
                            appearances: [appearance], coverage: verified),
                      .init(sourceID: unrelated.lastPathComponent, analysisIdentity: "unrelated",
                            sourceStamp: .init(media: other), sourceInode: other.identity.inode, coverage: verified)])
        let renderer = ParticipantRenderer()
        let plan = ParticipantRenderPlan(canvas: .init(width: 160, height: 90), shots: [.init(layout: .original)])
        let report = try renderer.render(project, document: document, plan: plan, to: output,
                                         settings: .init(audio: .removeAudio))
        XCTAssertTrue(report.privacyIssues.isEmpty)
        XCTAssertEqual(report.unscannedSourceIDs, [original.path])
        let movie = try CutEngine().inspect(output, keyframes: true)
        for index in files.indices {
            let time = RationalTime(numerator: Int64(index))
            let (jpeg, _) = try JPEGExport.reviewFrame(movie, at: time, exclusiveEnd: false, preset: .full, cancelled: { false })
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let (red, green, blue) = try centerPixel(of: XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil)))
            XCTAssertEqual(red > 220 && green < 35 && blue > 220, index < 3, "Recording at \(time) used the wrong treatment.")
        }

        // An alternate source ID cannot bypass a conflicting accepted assignment on the same file.
        project.participants.sources.append(.init(sourceID: alias.lastPathComponent, analysisIdentity: "conflicting",
                                                  sourceStamp: .init(media: indexed), sourceInode: indexed.identity.inode,
                                                  coverage: verified))
        let conflict = try renderer.report(project, document: document, plan: plan)
        XCTAssertFalse(conflict.publishable)
        XCTAssertEqual(conflict.privacyIssues.map(\.sourceID), [alias.lastPathComponent])
    }

    func testBlurReplacesPartiallyTransparentSourcePixels() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let dot = CGRect(x: 30, y: 30, width: 4, height: 4)
        let field = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 0.5)).cropped(to: extent)
        let sentinel = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.5)).cropped(to: dot)
            .composited(over: field)
        let appearance = ParticipantAppearance(id: "tile", participantID: "guest",
            range: .init(from: .zero, to: .init(numerator: 1)), bounds: .init(x: 0, y: 0, width: 1, height: 1))
        let blurred = ParticipantCompositor.redact(sentinel, appearances: [appearance],
            treatments: ["guest": .init(participantID: "guest", treatment: .blur)], allowMetal: false)

        func check(_ picture: CIImage) throws {
            let flattened = picture.composited(over: ParticipantCompositor.color(0x000000, in: extent))
            let image = try XCTUnwrap(ParticipantCompositor.context.createCGImage(flattened, from: extent,
                format: .RGBA8, colorSpace: ParticipantCompositor.colorSpace))
            let (red, _, blue) = try centerPixel(of: image)
            XCTAssertLessThan(red, 55, "The unfiltered red sentinel must never be composited over its blur.")
            XCTAssertGreaterThan(blue, 100)
        }

        try check(blurred)
        if let metal = ParticipantMetalBlur.shared {
            try check(XCTUnwrap(metal.apply(to: sentinel, areas: [extent])))
        }
    }

    func testPrivateISODeliveryResumesWithoutPublishingWithheldFeed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = directory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: fixture("Pause-Noisy.mov"), to: recording)
        let document = directory.appendingPathComponent("edit.cut")
        let output = directory.appendingPathComponent("delivery")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let media = try CutEngine().inspectSummary(recording)
        let mic = try XCTUnwrap(media.audio.last?.stream.index)
        var project = CutProject.sequence([
            .init(id: "a", file: recording.path, from: range.from, to: range.to),
            .init(id: "b", file: recording.path, from: range.from, to: range.to),
        ])
        let privateName = "Withheld Display Name"
        project.participants = .init(people: [
            .init(id: "host", name: "Host"),
            .init(id: "guest", name: privateName, audio: .init(selection: .init(source: recording.path, stream: mic)),
                  treatment: .init(mode: .cover, color: 0xff00ff)),
        ], sources: [
            .init(sourceID: recording.path, sourceStamp: .init(media: media), sourceInode: media.identity.inode, appearances: [
                .init(id: "main", participantID: "host", range: range, bounds: .init(x: 0, y: 0, width: 1, height: 1)),
                .init(id: "inset", participantID: "guest", range: range, bounds: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2)),
            ], coverage: [.init(range: range, state: .verified)]),
        ])
        let plan = try TilesISODelivery.plan(project: project, document: document, sourceID: recording.path, range: range,
            canvas: .init(width: 160, height: 90), audio: .init(meetingMix: true, includeISOs: true))
        XCTAssertFalse(plan.requiresReview)
        XCTAssertEqual(plan.feeds.map(\.id), ["host"])
        XCTAssertEqual(plan.withheld.map(\.id), ["guest"])
        XCTAssertTrue(plan.issues.contains { $0.code == "shared_mix" && !$0.blocking })
        XCTAssertThrowsError(try TilesISODelivery.render(plan, project: project, document: document, to: output) { $0 < 0.2 })
        XCTAssertFalse(try TilesISODelivery.verify(output).valid)
        let manifest = try TilesISODelivery.render(plan, project: project, document: document, to: output)
        XCTAssertTrue(try TilesISODelivery.verify(output).valid)
        XCTAssertEqual(manifest.files.compactMap { $0.feed?.id }, ["host"])
        XCTAssertTrue(manifest.files.contains { $0.filename == "meeting-mix.mov" && $0.media?.audio.count == 1 })
        let movie = try XCTUnwrap(manifest.files.first { $0.feed?.id == "host" })
        let rendered = try CutEngine().inspect(output.appendingPathComponent(movie.filename), keyframes: true)
        let (jpeg, _) = try JPEGExport.reviewFrame(rendered, at: .zero, exclusiveEnd: false, preset: .full, cancelled: { false })
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let (red, green, blue) = try centerPixel(of: XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil)))
        XCTAssertGreaterThan(red, 215)
        XCTAssertLessThan(green, 40)
        XCTAssertGreaterThan(blue, 215)
        XCTAssertFalse(String(decoding: try Data(contentsOf: output.appendingPathComponent("manifest.json")),
                              as: UTF8.self).contains(privateName))
        XCTAssertFalse(String(decoding: try Data(contentsOf: output.appendingPathComponent("multicam.cut")),
                              as: UTF8.self).contains(privateName))
    }

    private func centerPixel(of image: CGImage) throws -> (UInt8, UInt8, UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            context.draw(image, in: .init(x: -width / 2, y: -height / 2, width: width, height: height))
        }
        return (bytes[0], bytes[1], bytes[2])
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures").appendingPathComponent(name)
    }
}
