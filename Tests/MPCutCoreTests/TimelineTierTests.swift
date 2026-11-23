import XCTest
@testable import MPCutCore

/// The timeline tier is found by running the planners. These tests hold it to them.
final class TimelineTierTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static var helper: String {
        ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
            ?? repository.appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
    }
    private static var hasHelper: Bool { FileManager.default.isExecutableFile(atPath: helper) }

    override class func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil, hasHelper { setenv("MPCUT_FFMPEG_HELPER", helper, 1) }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fixture(_ name: String) throws -> URL {
        let bundled = Self.repository.appendingPathComponent("Tests/MPCutAppTests/Fixtures/\(name)")
        let copy = scratch.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: bundled, to: copy) }
        return copy.standardizedFileURL
    }

    private func t(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private func media(_ clips: [ClipRequest]) throws -> [URL: MediaInfo] {
        var result: [URL: MediaInfo] = [:]
        for clip in clips where result[clip.file] == nil {
            result[clip.file] = try CutEngine(useSidecar: false).inspect(clip.file, keyframes: true)
        }
        return result
    }

    private func evaluate(_ clips: [ClipRequest], with evaluator: TimelineTierEvaluator? = nil) throws -> TierState {
        (evaluator ?? TimelineTierEvaluator(useSidecar: false)).evaluate(clips, media: try media(clips))
    }

    /// Converts the MP3 fixture, so that PCM has a short source with known sample times.
    private func wave() throws -> URL {
        try XCTSkipUnless(Self.hasHelper, "Needs the FFmpeg helper to make a PCM source.")
        let output = scratch.appendingPathComponent("Tone.wav")
        if !FileManager.default.fileExists(atPath: output.path) {
            let engine = AudioExportEngine(useSidecar: false)
            try engine.write(engine.resolve([ClipRequest(file: try fixture("Gapless-Crop.mp3"))], output: output, audio: .pcm), to: output)
        }
        return output.standardizedFileURL
    }

    // MARK: Rules

    func testTierFollowsTheRankOfTheLadder() {
        XCTAssertEqual(FidelityTier.allCases, [.trueLossless, .lossless, .reencode])
        XCTAssertTrue(FidelityTier.trueLossless > .lossless && FidelityTier.lossless > .reencode)
        for rung in ExportRung.allCases {
            let expected: FidelityTier
            switch rung {
            case .copyOtherContainer, .copySampleAligned: expected = .trueLossless
            case .smartTrim, .convertPCM: expected = .lossless
            case .convertSameFormat, .convertAAC, .reencode: expected = .reencode
            }
            XCTAssertEqual(ExportRules.tier(of: rung.rank), expected, rung.rawValue)
        }
        XCTAssertEqual(FidelityTier.allCases.map { ExportRules.bestMode(for: $0, source: .movie) }, [.copy, .smart, .encode])
        XCTAssertEqual(FidelityTier.allCases.map { ExportRules.bestMode(for: $0, source: .audio) }, [.copy, .encode, .encode])
        XCTAssertEqual(FidelityTier.allCases.map { ExportRules.displayName(tier: $0) }, ["True Lossless", "Lossless", ExportRules.displayName(mode: .encode)])
        for source in [ExportSourceKind.movie, .audio] {
            let steps = ExportRules.tierSteps(source: source)
            XCTAssertEqual(steps.map(\.tier), FidelityTier.allCases, "\(source)")
            XCTAssertEqual(steps.map(\.rank), steps.map(\.rank).sorted(), "The checks run in rank order.")
        }
    }

    func testExportOpensOnThePreferenceUnlessTheTierIsLower() {
        let cases: [(ExportMode, FidelityTier?, ExportMode)] = [
            (.smart, nil, .smart), (.copy, nil, .copy),
            (.smart, .trueLossless, .smart), (.copy, .trueLossless, .copy), (.encode, .trueLossless, .encode),
            (.smart, .lossless, .smart), (.copy, .lossless, .smart), (.encode, .lossless, .encode),
            (.smart, .reencode, .encode), (.copy, .reencode, .encode), (.encode, .reencode, .encode)
        ]
        for (preferred, tier, expected) in cases {
            XCTAssertEqual(ExportRules.openingMode(preferred: preferred, tier: tier, source: .movie), expected, "\(preferred) \(String(describing: tier))")
        }
        // Sound always opens on Lossless Copy, which lists the ranked alternatives when the copy is unavailable.
        // Opening on the tier's conversion would hide a better-ranked alternative that works, such as copySampleAligned.
        for preferred in [ExportMode.smart, .copy, .encode] {
            for tier in [FidelityTier?.none, .trueLossless, .lossless, .reencode] {
                XCTAssertEqual(ExportRules.openingMode(preferred: preferred, tier: tier, source: .audio), .copy)
            }
        }
        XCTAssertLessThan(ExportRung.copySampleAligned.rank, ExportRung.convertPCM.rank)
    }

    func testWrittenRulesListEveryTierAndFactor() {
        let text = ExportRules.markdown()
        XCTAssertTrue(text.contains("## Timeline tier") && text.contains("## Tier factors"))
        for tier in FidelityTier.allCases { XCTAssertTrue(text.contains("`\(tier.rawValue)`"), tier.rawValue) }
        for factor in TierFactorID.allCases { XCTAssertTrue(text.contains("| `\(factor.rawValue)` |"), factor.rawValue) }
        XCTAssertEqual(Set(TierFactorID.allCases.map(\.rawValue)).count, TierFactorID.allCases.count)
        XCTAssertTrue(ExportRules.helpSummary.contains(ExportRules.tierHelp))
    }

    // MARK: Every factor

    private struct Scenario {
        let factor: TierFactorID
        let clips: [ClipRequest]
        /// Nil when no mode writes the timeline.
        let tier: FidelityTier?
    }

    /// Factors without a scenario here, each with the reason.
    private static let notExercised: [TierFactorID: String] = [
        // TimelineTierFactorFixtureTests has scenarios for cut_audio_packet, cut_aac_coverage, cut_pcm_sample_clock, cut_mp3_crop,
        // cut_opus_window, join_smart_open_gop, join_timecode, source_unsupported_tracks and source_encode_unsupported. The rest were tried
        // with sources the bundled helper can make, and each states what was tried.
        .cutAudioPriming: "Not reached: in MP3 and AAC movies made with the helper (MOV, Matroska, MPEG-TS, sound starting with or after the picture) a cut inside the priming is refused earlier as cut_audio_packet.",
        .joinVideoDTSOverlap: "Not reached: joins of reordered H.264 and HEVC from the helper's hardware encoders are refused earlier as cut_video_start in containers that cannot reschedule (Matroska, MPEG-TS).",
        .joinDynamicRange: "Needs an HDR source; no committed fixture. Tests/Integration/mixed_timeline.py generates PQ and HLG clips and checks the refusal and its reason.",
        .sourceMultipleDescriptions: "Only reached with a named container, which the timeline tier never names; covered by the code mapping below.",
        .sourceTimeline: "Not reached by a planner: a source with a timeline issue, such as two video tracks, is refused as source_unsupported_tracks (see the fixture test). The code `unsupported_timeline` is raised at import and maps to it below.",
        .outputContainer: "Only reached when no container carries the clips, or with a named container; covered by the code mapping below.",
        .selectionTracks: "The timeline tier always asks for every track; covered by the code mapping below.",
        .writerOther: "The fallback for failures that are not about the timeline."
    ]

    func testEveryFactorGivesItsTierAndIsReported() throws {
        let gop = try fixture("SmartTrim-GOP.mp4"), vfr = try fixture("VFR-PTS.mp4"), webm = try fixture("WebM-Opus-GOP.webm")
        let mp3 = try fixture("Gapless-Crop.mp3")
        var scenarios = [
            Scenario(factor: .cutVideoStart, clips: [ClipRequest(file: gop, from: t(7, 25), to: t(2))], tier: .lossless),
            Scenario(factor: .cutVideoEnd, clips: [ClipRequest(file: gop, from: .zero, to: t(12, 25))], tier: .lossless),
            Scenario(factor: .cutOffFrame, clips: [ClipRequest(file: gop, from: t(1, 3), to: t(2))], tier: nil),
            Scenario(factor: .sourceSmartIneligible, clips: [ClipRequest(file: webm, from: t(1, 5), to: t(4))], tier: .reencode),
            Scenario(factor: .joinDecoderHistory,
                     clips: [ClipRequest(file: webm, from: t(1), to: t(2)), ClipRequest(file: webm, from: t(3), to: t(4))], tier: .reencode),
            Scenario(factor: .joinDecoderHistory,
                     clips: [ClipRequest(file: mp3, from: t(1, 10), to: t(3, 10)), ClipRequest(file: mp3, from: t(1, 2), to: t(7, 10))], tier: .lossless),
            // A mixed timeline: copy and Smart Trim refuse it, and Re-encode writes it on one canvas.
            Scenario(factor: .joinStreamMismatch, clips: [ClipRequest(file: gop), ClipRequest(file: vfr)], tier: .reencode),
            Scenario(factor: .joinMediaType, clips: [ClipRequest(file: gop), ClipRequest(file: mp3)], tier: nil)
        ]
        if Self.hasHelper {
            scenarios.append(Scenario(factor: .cutAudioSample, clips: [ClipRequest(file: try wave(), from: t(100_001, 1_000_000), to: t(3, 10))], tier: .lossless))
        }
        var exercised: Set<TierFactorID> = []
        for scenario in scenarios {
            let name = "\(scenario.factor.rawValue) \(scenario.clips.map { "\($0.file.lastPathComponent) \(String(describing: $0.from))–\(String(describing: $0.to))" })"
            let state = try evaluate(scenario.clips)
            XCTAssertEqual(state.tier, scenario.tier, name)
            XCTAssertTrue(state.factors.contains { $0.id == scenario.factor }, "\(name): \(state.factors.map(\.id.rawValue))")
            if scenario.tier == nil, case .known = state { XCTFail("\(name) should not be exportable.") }
            for factor in state.factors where scenario.tier != nil {
                XCTAssertNotNil(factor.forces, name)
                XCTAssertGreaterThanOrEqual(factor.forces ?? .trueLossless, scenario.tier ?? .reencode, "\(name): a factor leaves at best the tier it names.")
            }
            exercised.insert(scenario.factor)
        }

        // The mixed timeline's factor says what differs and between which clips, and the tier carries the canvas warning.
        let mixed = try evaluate([ClipRequest(file: gop), ClipRequest(file: vfr)])
        let mismatch = try XCTUnwrap(mixed.factors.first { $0.id == .joinStreamMismatch })
        XCTAssertEqual(mixed.factors.map(\.id), [.joinStreamMismatch])
        XCTAssertEqual([mismatch.forces, mismatch.segment.map { _ in FidelityTier.reencode }], [.reencode, .reencode])
        XCTAssertEqual(mismatch.segment, 2)
        XCTAssertEqual(mismatch.message, "Clips 1 and 2 differ in picture size and frame rate. Only Re-encode writes them together.")
        if case .known(_, _, _, let warnings) = mixed {
            XCTAssertTrue(warnings.contains("Sources differ in picture size and frame rate (clips 1 and 2); the whole timeline is re-encoded to 320×96."), "\(warnings)")
        } else {
            XCTFail("A mixed timeline has the Re-encode tier.")
        }
        XCTAssertEqual(TierFactorID.joinStreamMismatch.effect.summary, ExportRules.displayName(tier: .reencode))
        // The copy check stops at its first difference; the list names every one, and is empty only for clips that match.
        let engine = CutEngine(useSidecar: false)
        let (first, second) = (try engine.inspect(gop, keyframes: true), try engine.inspect(vfr, keyframes: true))
        XCTAssertThrowsError(try engine.checkCompatibility(second, with: first))
        XCTAssertEqual(ExportRules.mixedDifferences(second, from: first), ["picture size", "frame rate"])
        XCTAssertNoThrow(try engine.checkCompatibility(first, with: first))
        XCTAssertEqual(ExportRules.mixedDifferences(first, from: first), [])

        // A source that cannot be copied from its first picture, as the copy planner reports it.
        let avi = try fixture("Leading-Picture-Gap.avi")
        if case .unavailable(let issue, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: [ClipRequest(file: avi)], mode: .copy)) {
            XCTAssertEqual(issue.factor, .sourceStartUnsafe, issue.message)
            exercised.insert(.sourceStartUnsafe)
        } else {
            XCTFail("The AVI fixture starts after a picture gap and does not copy from its beginning.")
        }

        // A source that changed after it was indexed.
        let changing = scratch.appendingPathComponent("Changing.mp4")
        try FileManager.default.copyItem(at: gop, to: changing)
        let clips = [ClipRequest(file: changing.standardizedFileURL)]
        let indexed = try media(clips)
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        XCTAssertEqual(evaluator.evaluate(clips, media: indexed).tier, .trueLossless)
        let handle = try FileHandle(forWritingTo: changing)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let after = evaluator.evaluate(clips, media: indexed)
        XCTAssertNil(after.tier)
        XCTAssertEqual(after.factors.map(\.id), [.sourceChanged])
        exercised.insert(.sourceChanged)

        for (tracks, placements, expected) in [
            (ExportTracks.video, ExportPlacementScope.replacement, TierFactorID.placementPicture),
            (.audio, .insertion, .placementSilence),
        ] {
            let issue = try XCTUnwrap(ExportRules.cell(source: .movie, tracks: tracks, mode: .copy, placements: placements).refusal)
            XCTAssertEqual(issue.factor, expected)
            exercised.insert(issue.factor)
        }
        if !Self.hasHelper { exercised.insert(.cutAudioSample) }
        // Factors whose sources are made with the helper have their scenarios in their own test.
        exercised.formUnion(TimelineTierFactorFixtureTests.covered)
        for factor in TierFactorID.allCases {
            XCTAssertTrue(exercised.contains(factor) != (Self.notExercised[factor] != nil),
                          "\(factor.rawValue) must have a scenario or a stated reason, not both and not neither.")
        }

        // Failures that name no factor at their throw site stand for one through their code.
        let codes: [String: TierFactorID] = [
            "incompatible_clip": .joinStreamMismatch, "unsupported_timecode": .joinTimecode, "unsafe_smart_join": .joinSmartOpenGOP,
            "unsupported_tracks": .sourceUnsupportedTracks, "unsupported_timeline": .sourceTimeline, "unsupported_container": .outputContainer,
            "invalid_frame_boundary": .cutOffFrame, "unsupported_format": .sourceEncodeUnsupported, "unsupported_timing": .sourceEncodeUnsupported,
            "unsupported_audio": .sourceEncodeUnsupported, "source_changed": .sourceChanged, "no_video": .selectionTracks,
            "invalid_arguments": .selectionTracks, "write_failed": .writerOther
        ]
        for (code, factor) in codes {
            XCTAssertEqual(CutError(code: code, message: "").factor, factor, code)
        }
        XCTAssertEqual(CutError(code: "unsupported_container", message: "").because(.sourceMultipleDescriptions).factor, .sourceMultipleDescriptions)
    }

    // MARK: The tier is what the planner does

    /// The tier's mode plans through `ExportPlanner.resolve`, and the next better mode does not.
    func testTheTiersModeIsReadyAndTheNextBetterModeIsUnavailable() throws {
        let gop = try fixture("SmartTrim-GOP.mp4"), webm = try fixture("WebM-Opus-GOP.webm"), talkie = try fixture("Shuttle-Chirp.mov")
        let mp3 = try fixture("Gapless-Crop.mp3")
        let timelines: [[ClipRequest]] = [
            [ClipRequest(file: gop)],
            [ClipRequest(file: gop, from: t(7, 25), to: t(2))],
            [ClipRequest(file: gop, from: .zero, to: t(1)), ClipRequest(file: gop, from: t(31, 25), to: t(2))],
            [ClipRequest(file: talkie, from: t(3, 5), to: t(6, 5))],
            [ClipRequest(file: talkie, from: t(1, 5), to: t(2))],
            [ClipRequest(file: webm, from: t(1, 5), to: t(4))],
            [ClipRequest(file: webm, from: t(1), to: t(2)), ClipRequest(file: webm, from: t(3), to: t(4))],
            [ClipRequest(file: mp3)],
            [ClipRequest(file: mp3, from: t(1, 10), to: t(3, 10)), ClipRequest(file: mp3, from: t(1, 2), to: t(7, 10))]
        ]
        var seen: Set<FidelityTier> = []
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        for clips in timelines {
            let name = clips.map { "\($0.file.lastPathComponent) \(String(describing: $0.from))–\(String(describing: $0.to))" }.joined(separator: ", ")
            let indexed = try media(clips)
            let kind: ExportSourceKind = indexed[clips[0].file]?.hasVideo == true ? .movie : .audio
            guard case .known(let tier, _, let container, _) = evaluator.evaluate(clips, media: indexed) else {
                XCTFail("\(name) has no tier.")
                continue
            }
            seen.insert(tier)
            let steps = ExportRules.tierSteps(source: kind)
            let position = try XCTUnwrap(steps.firstIndex { $0.tier == tier })
            func resolution(_ step: ExportRules.TierStep, container: String? = nil) -> ExportResolution {
                ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: clips, mode: step.mode, container: container, audio: step.audio ?? .auto),
                                                         media: indexed)
            }
            // A movie re-encode asks the hardware encoder, which needs the helper.
            if steps[position].mode != .encode || Self.hasHelper {
                guard case .ready(let plan, _, _) = resolution(steps[position], container: steps[position].mode == .encode ? container : nil) else {
                    XCTFail("\(name): tier \(tier.rawValue) and its mode does not plan.")
                    continue
                }
                XCTAssertEqual(plan.edit.container, container, name)
            }
            if position > 0 {
                // `auto` for sound resolves to the first alternative, so ask the better mode by name.
                guard case .unavailable = resolution(steps[position - 1]) else {
                    XCTFail("\(name): tier \(tier.rawValue) and the better mode \(steps[position - 1].mode.rawValue) plans.")
                    continue
                }
            }
        }
        XCTAssertEqual(seen, Set(FidelityTier.allCases), "The timelines cover every tier.")
    }

    /// The boundary cache does not record whether Smart Trim asked. Smart Trim accepts every frame, so one cache
    /// shared between the modes would hand the copy planner a frame-accurate set and report True Lossless wrongly.
    func testCopyAndSmartTrimNeverShareBoundarySets() throws {
        let gop = try fixture("SmartTrim-GOP.mp4")
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        // The copy check stops at the first clip. Smart Trim goes on and caches the sets of the second position.
        let first = [ClipRequest(file: gop, from: t(7, 25), to: t(1)), ClipRequest(file: gop, from: t(31, 25), to: t(2))]
        let indexed = try media(first)
        XCTAssertEqual(evaluator.evaluate(first, media: indexed).tier, .lossless)
        // Now only the second clip starts inside a picture group. A copy that read Smart Trim's set would accept it.
        let second = [ClipRequest(file: gop, from: .zero, to: t(1)), ClipRequest(file: gop, from: t(31, 25), to: t(2))]
        let state = evaluator.evaluate(second, media: indexed)
        XCTAssertEqual(state.tier, .lossless)
        XCTAssertEqual(state.factors.map(\.id), [.cutVideoStart])
        XCTAssertEqual(state.factors.first?.segment, 2)
        // And the same evaluator still says True Lossless only where a fresh one does.
        let third = [ClipRequest(file: gop, from: .zero, to: t(1)), ClipRequest(file: gop, from: t(1), to: t(2))]
        XCTAssertEqual(evaluator.evaluate(third, media: indexed).tier, .trueLossless)
        XCTAssertEqual(evaluator.evaluate(second, media: indexed).tier, TimelineTierEvaluator(useSidecar: false).evaluate(second, media: indexed).tier)

        // The hazard itself: one cache passed to both planners accepts the cut. If this ever stops being true the
        // key gained the flag, and the evaluator may share its caches.
        let inside = [ClipRequest(file: gop, from: t(7, 25), to: t(2))], alsoInside = [ClipRequest(file: gop, from: t(8, 25), to: t(2))]
        var shared = CutEngine.BoundaryCache()
        _ = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: inside, mode: .smart), media: indexed, boundaries: &shared)
        var misreported = false
        if case .ready = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: alsoInside, mode: .copy), media: indexed, boundaries: &shared) {
            misreported = true
        }
        // The evaluator asks the same two questions in the same order and keeps them apart.
        XCTAssertEqual(evaluator.evaluate(inside, media: indexed).tier, .lossless)
        XCTAssertEqual(evaluator.evaluate(alsoInside, media: indexed).tier, .lossless)
        XCTAssertEqual(evaluator.evaluate(alsoInside, media: indexed).factors.map(\.id), [.cutVideoStart])
        XCTAssertTrue(misreported, "A cache shared by both modes now keeps them apart. The evaluator's separate caches can be merged.")
    }

    func testEveryCutIsListedUpToTheLimitAndRaisingNamesTheMovedClips() throws {
        let gop = try fixture("SmartTrim-GOP.mp4")
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        let clips = [ClipRequest(file: gop, from: t(7, 25), to: t(1)), ClipRequest(file: gop, from: t(31, 25), to: t(2))]
        let indexed = try media(clips)
        let state = evaluator.evaluate(clips, media: indexed)
        XCTAssertEqual(state.factors.map(\.segment), [1, 2], "Both cuts are listed, not only the first the planner stops at.")
        XCTAssertEqual(state.factors.map(\.forces), [.lossless, .lossless])
        XCTAssertEqual(evaluator.snapped(clips, media: indexed, to: .trueLossless)?.map { [$0.from, $0.to] }, [[.zero, t(1)], [t(1), t(2)]])
        let summary = evaluator.summary(clips, media: indexed)
        XCTAssertEqual([summary.id, summary.name, summary.container ?? ""], ["lossless", "Lossless", "mp4"])
        XCTAssertEqual(summary.mode, .smart)
        XCTAssertEqual(summary.raise.map(\.tier), [.trueLossless])
        XCTAssertEqual(summary.raise.first?.arguments, ["--mode", "copy", "--snap", "nearest"])
        XCTAssertEqual(summary.raise.first?.clips?.map(\.from), ["0", "1"])
        XCTAssertNil(evaluator.snapped([ClipRequest(file: gop)], media: indexed, to: .trueLossless), "Nothing to move on an exact timeline.")

        // Many cuts: the list stops at the limit and says how many more there are.
        var many: [ClipRequest] = []
        for index in 0..<24 { many.append(ClipRequest(file: gop, from: t(Int64(index * 2 + 1), 25), to: t(Int64(index * 2 + 2), 25))) }
        guard case .known(let tier, let factors, _, let warnings) = evaluator.evaluate(many, media: indexed) else { return XCTFail("No tier.") }
        XCTAssertEqual(tier, .lossless)
        XCTAssertEqual(factors.count, TimelineTierEvaluator.factorLimit)
        XCTAssertTrue(warnings.contains { $0.hasSuffix("not listed.") }, "\(warnings)")
    }

    func testProvisionalAndCancelledChecksAreStillChecking() throws {
        let gop = try fixture("SmartTrim-GOP.mp4")
        let clips = [ClipRequest(file: gop)]
        let preview = try CutEngine(useSidecar: false).inspectForPreview(gop)
        XCTAssertFalse(preview.hasFullEditIndex)
        if case .checking = TimelineTierEvaluator(useSidecar: false).evaluate(clips, media: [gop: preview]) {} else {
            XCTFail("A clip without its cut index is still being checked.")
        }
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        let indexed = try media(clips)
        XCTAssertEqual(evaluator.evaluate(clips, media: indexed).tier, .trueLossless)
        if case .checking = evaluator.evaluate(clips, media: indexed, cancelled: { true }) {} else {
            XCTFail("A cancelled check has no answer.")
        }
        XCTAssertNil(TimelineTierEvaluator(useSidecar: false).evaluate([]).tier)
    }

    /// Measures one evaluation on a source named by MPCUT_TIER_BENCH. Skipped otherwise.
    func testMeasureOneEvaluation() throws {
        guard let path = ProcessInfo.processInfo.environment["MPCUT_TIER_BENCH"] else { throw XCTSkip("Set MPCUT_TIER_BENCH to a media file.") }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let info = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        let keys = info.frames.filter { $0.canStart && $0.time > .zero }.map(\.time)
        let frames = info.frames.map(\.time)
        func timeline(cuts: Int, onKeyframes: Bool, shift: Int = 0) -> [ClipRequest] {
            let points = onKeyframes ? keys : frames
            let step = max(2, points.count / (cuts * 2 + 2))
            return (0..<cuts).map { ClipRequest(file: file, from: points[($0 * 2 + 1) * step + shift], to: points[($0 * 2 + 2) * step]) }
        }
        func clock(_ label: String, _ body: () -> TierState) {
            let start = ContinuousClock.now
            let state = body()
            let elapsed = start.duration(to: .now)
            print("TIERBENCH \(label): \(state.name), \(state.factors.count) factors, \(elapsed)")
        }
        print("TIERBENCH source: \(info.frames.count) frames, \(keys.count) start points, \(info.duration.seconds) s")
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        clock("cold, 40 keyframe cuts") { evaluator.evaluate(timeline(cuts: 40, onKeyframes: true), media: [file: info]) }
        clock("warm, 41 keyframe cuts (one edit later)") { evaluator.evaluate(timeline(cuts: 41, onKeyframes: true), media: [file: info]) }
        clock("same timeline again (memo)") { evaluator.evaluate(timeline(cuts: 41, onKeyframes: true), media: [file: info]) }
        clock("cold smart, 40 frame cuts") { evaluator.evaluate(timeline(cuts: 40, onKeyframes: false), media: [file: info]) }
        clock("warm smart, 40 frame cuts moved by one frame") { evaluator.evaluate(timeline(cuts: 40, onKeyframes: false, shift: 1), media: [file: info]) }
        clock("warm, 400 frame cuts") { evaluator.evaluate(timeline(cuts: 400, onKeyframes: false), media: [file: info]) }
        clock("fresh evaluator, 40 frame cuts") { TimelineTierEvaluator(useSidecar: false).evaluate(timeline(cuts: 40, onKeyframes: false), media: [file: info]) }
    }
}
