import XCTest
@testable import MPCutCore

/// Canonical channel layouts, seamless splits, the multicam single-type refusal, the times in messages people read,
/// and mixed timelines in Premiere interchange.
final class ExportFindingsTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static var helper: String {
        ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
            ?? repository.appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fixture(_ name: String, as copyName: String? = nil) throws -> URL {
        let bundled = Self.repository.appendingPathComponent("Tests/MPCutAppTests/Fixtures/\(name)")
        let copy = scratch.appendingPathComponent(copyName ?? name)
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

    /// The same packets in another container, written by the FFmpeg helper.
    private func remux(_ source: URL, to name: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.helper), "Needs the FFmpeg helper to remux a source.")
        let output = scratch.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.helper)
        process.arguments = ["-v", "error", "-nostdin", "-y", "-i", source.path, "-map", "0", "-c", "copy", output.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output.standardizedFileURL
    }

    // MARK: Channel layouts

    func testALayoutWithoutSpeakerNamesStandsForTheStandardLayoutOfItsChannelCount() {
        func canonical(_ layout: String, _ channels: Int) -> String { StreamInfo.canonicalChannelLayout(layout, channels: channels) }
        XCTAssertEqual(canonical("1 channels", 1), "mono")
        XCTAssertEqual(canonical("2 channels", 2), "stereo")
        XCTAssertEqual(canonical("6 channels", 6), "5.1")
        XCTAssertEqual(canonical("8 channels", 8), "7.1")
        XCTAssertEqual(canonical("stereo", 2), "stereo")
        XCTAssertEqual(canonical("5.1", 6), "5.1")
        // Layouts that name other speakers stay different from the standard one.
        XCTAssertEqual(canonical("5.1(side)", 6), "5.1(side)")
        XCTAssertNotEqual(canonical("5.1(side)", 6), canonical("6 channels", 6))
        XCTAssertNotEqual(canonical("quad", 4), canonical("4.0", 4))
        XCTAssertEqual(canonical("4 channels", 4), canonical("4.0", 4))
        XCTAssertNotEqual(canonical("2 channels", 2), canonical("1 channels", 1))
        // Nothing to read, or a description that contradicts the channel count, is left as the file states it.
        XCTAssertEqual(canonical("", 0), "")
        XCTAssertEqual(canonical("not a layout", 2), "not a layout")
        XCTAssertEqual(canonical("2 channels", 6), "2 channels")
    }

    func testTheSameSoundInMP4AndMOVCopiesTogether() throws {
        let mov = try fixture("Shuttle-Chirp.mov")
        let mp4 = try remux(mov, to: "Shuttle-Chirp.mp4")
        // Keyframes are 0.6 s apart in this fixture.
        let clips = [ClipRequest(file: mov, from: .zero, to: t(6, 10)), ClipRequest(file: mp4, from: t(6, 10), to: t(12, 10))]
        let indexed = try media(clips)
        let layouts = clips.map { indexed[$0.file]!.audio[0].stream }
        XCTAssertEqual(layouts.map(\.channelLayout), ["stereo", "2 channels"], "The containers word the layout differently. The stored value stays as stated.")
        XCTAssertEqual(Set(layouts.map(\.canonicalChannelLayout)), ["stereo"])
        XCTAssertNoThrow(try CutEngine(useSidecar: false).checkCompatibility(indexed[mp4]!, with: indexed[mov]!))
        XCTAssertEqual(ExportRules.mixedDifferences(indexed[mp4]!, from: indexed[mov]!), [])

        for order in [clips, [ClipRequest(file: mp4, from: .zero, to: t(6, 10)), ClipRequest(file: mov, from: t(6, 10), to: t(12, 10))]] {
            XCTAssertEqual(TimelineTierEvaluator(useSidecar: false).evaluate(order, media: indexed).tier, .trueLossless)
            for mode in [ExportMode.copy, .smart] {
                guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: order, mode: mode), media: indexed) else {
                    return XCTFail("\(mode) refuses the same stream in two containers.")
                }
                XCTAssertEqual(plan.edit.segments.count, 2)
                XCTAssertEqual(try plan.edit.encodedVideoDuration(for: mode), .zero)
            }
        }
        // Written, the file reads back with the layout and the length of its clips.
        guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: clips, mode: .copy, container: "mp4"), media: indexed) else {
            return XCTFail("No plan.")
        }
        let output = scratch.appendingPathComponent("joined.mp4")
        try ExportPlanner(useSidecar: false).write(plan, to: output)
        let written = try CutEngine(useSidecar: false).inspect(output, keyframes: true)
        XCTAssertEqual(written.audio.count, 1)
        XCTAssertEqual(written.audio[0].stream.canonicalChannelLayout, "stereo")
        XCTAssertEqual(written.audio[0].stream.configuration, layouts[0].configuration)
        XCTAssertEqual(written.duration, t(12, 10))
    }

    func testGenuinelyDifferentLayoutsStillDoNotCopyTogether() throws {
        // Two mono tracks against one stereo track: the track count, and then the layout, differ.
        let stereo = try fixture("Shuttle-Chirp.mov"), mono = try fixture("Pause-Quiet.mov")
        let indexed = try media([ClipRequest(file: stereo), ClipRequest(file: mono)])
        XCTAssertThrowsError(try CutEngine(useSidecar: false).checkCompatibility(indexed[mono]!, with: indexed[stereo]!))
        XCTAssertTrue(ExportRules.mixedDifferences(indexed[mono]!, from: indexed[stereo]!).contains("audio channels"))
    }

    // MARK: Seamless splits

    func testASplitThatRemovesNothingIsTheUnsplitRangeInEveryMode() throws {
        let gop = try fixture("SmartTrim-GOP.mp4")
        let whole = [ClipRequest(file: gop, from: .zero, to: t(2))]
        // 7/25 is inside the first picture group.
        let split = [ClipRequest(file: gop, from: .zero, to: t(7, 25)), ClipRequest(file: gop, from: t(7, 25), to: t(2))]
        let thrice = [ClipRequest(file: gop, from: .zero, to: t(7, 25)), ClipRequest(file: gop, from: t(7, 25), to: t(31, 25)),
                      ClipRequest(file: gop, from: t(31, 25), to: t(2))]
        let indexed = try media(whole)
        for clips in [split, thrice] {
            let state = TimelineTierEvaluator(useSidecar: false).evaluate(clips, media: indexed)
            XCTAssertEqual(state.tier, .trueLossless)
            XCTAssertEqual(state.factors.map(\.id), [])
            for mode in [ExportMode.copy, .smart] {
                guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: clips, mode: mode), media: indexed) else {
                    return XCTFail("\(mode) refuses a split that removes nothing.")
                }
                XCTAssertEqual(plan.edit.segments.count, 1, "The pieces are planned as the one range they are.")
                XCTAssertEqual([plan.edit.segments[0].from, plan.edit.segments[0].to], [.zero, t(2)])
                XCTAssertEqual(try plan.edit.encodedVideoDuration(for: mode), .zero)
            }
        }
        // The copy of the split is the copy of the unsplit clip, byte for byte.
        var files: [Data] = []
        for (name, clips) in [("whole", whole), ("split", split)] {
            guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: clips, mode: .copy, container: "mp4"), media: indexed) else {
                return XCTFail("No plan.")
            }
            let output = scratch.appendingPathComponent("\(name).mp4")
            try ExportPlanner(useSidecar: false).write(plan, to: output)
            files.append(try Data(contentsOf: output))
        }
        XCTAssertEqual(files[0], files[1])
    }

    func testASplitWithARemovedFrameIsACutAndStaysLossless() throws {
        let gop = try fixture("SmartTrim-GOP.mp4")
        let removed = [ClipRequest(file: gop, from: .zero, to: t(7, 25)), ClipRequest(file: gop, from: t(8, 25), to: t(2))]
        let indexed = try media(removed)
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        let state = evaluator.evaluate(removed, media: indexed)
        XCTAssertEqual(state.tier, .lossless)
        XCTAssertEqual(Set(state.factors.map(\.id)), [.cutVideoEnd, .cutVideoStart])
        guard case .unavailable(let issue, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: removed, mode: .copy), media: indexed) else {
            return XCTFail("A copy accepted a cut inside a picture group.")
        }
        XCTAssertEqual(issue.code, "unsafe_boundary")
        guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: removed, mode: .smart), media: indexed) else {
            return XCTFail("Smart Trim refuses the cut.")
        }
        XCTAssertGreaterThan(try plan.edit.encodedVideoDuration(for: .smart), .zero)
        // Repeating a piece is not a seam either: the pieces are not contiguous in the source.
        let repeated = [ClipRequest(file: gop, from: .zero, to: t(7, 25)), ClipRequest(file: gop, from: .zero, to: t(7, 25))]
        XCTAssertEqual(evaluator.evaluate(repeated, media: indexed).tier, .lossless)
    }

    func testRaisingATimelineWithASeamlessSplitMovesTheOuterCutsAndKeepsTheSeam() throws {
        let gop = try fixture("SmartTrim-GOP.mp4")
        // A seam at 7/25 that removes nothing, and an end inside the second picture group.
        let clips = [ClipRequest(file: gop, from: .zero, to: t(7, 25)), ClipRequest(file: gop, from: t(7, 25), to: t(31, 25))]
        let indexed = try media(clips)
        let evaluator = TimelineTierEvaluator(useSidecar: false)
        let state = evaluator.evaluate(clips, media: indexed)
        XCTAssertEqual(state.tier, .lossless)
        XCTAssertEqual(state.factors.map(\.id), [.cutVideoEnd])
        XCTAssertEqual(state.factors.first?.segment, 2)
        let moved = try XCTUnwrap(evaluator.snapped(clips, media: indexed, to: .trueLossless))
        XCTAssertEqual(moved.map { [$0.from, $0.to] }, [[.zero, t(7, 25)], [t(7, 25), t(1)]])
        XCTAssertEqual(evaluator.evaluate(moved, media: indexed).tier, .trueLossless)
    }

    // MARK: Multicam picture-only refusal

    func testAPictureOnlyMulticamCutWithoutAlternativesSaysWhatToDo() throws {
        let a = try fixture("SmartTrim-GOP.mp4", as: "A.mp4"), b = try fixture("SmartTrim-GOP.mp4", as: "B.mp4")
        let project = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: t(2)),
                                      angles: [.init(id: "a", file: a.path), .init(id: "b", file: b.path)], audio: .none,
                                      switches: [.init(at: .zero, angle: "a"), .init(at: t(7, 25), angle: "b")])
        let output = scratch.appendingPathComponent("program.mp4")
        guard case .unavailable(let issue, let offers) = MulticamEngine().resolution(project, output: output, mode: .copy, tracks: .video) else {
            return XCTFail("A copy accepted a switch inside a picture group.")
        }
        XCTAssertEqual(issue.code, "unsafe_boundary")
        XCTAssertEqual(ExportRules.cell(source: .multicam, tracks: .video, mode: .copy).rungs, [.copyOtherContainer],
                       "The row offers another container only. If it gains rungs, offer them instead of the advice.")
        XCTAssertTrue(offers.isEmpty, "No container takes a cut inside a picture group.")
        XCTAssertFalse((issue.nearest ?? []).isEmpty)
        XCTAssertTrue(issue.message.contains("There is no verified video"), issue.message)
        XCTAssertTrue(issue.message.hasSuffix("A picture-only multicam export is a Lossless Copy, which needs a verified time at every cut. "
                                              + "Move the cut to one of the verified times, or export picture and sound together with Smart Trim."), issue.message)
        XCTAssertEqual(issue.factor, .cutVideoEnd)
        XCTAssertNotNil(issue.multicam)

        // The request for picture and sound has its alternatives and no advice.
        guard case .unavailable(let together, let listed) = MulticamEngine().resolution(project, output: output, mode: .copy) else {
            return XCTFail("A copy accepted a switch inside a picture group.")
        }
        XCTAssertEqual(listed.first?.alternative.rung, .smartTrim)
        XCTAssertTrue(listed.allSatisfy { $0.tracks == .all })
        XCTAssertFalse(together.message.contains("picture-only"))

        // A switch on a keyframe is copied, and is not advised about.
        var safe = project
        safe.switches = [.init(at: .zero, angle: "a"), .init(at: t(1), angle: "b")]
        guard case .ready = MulticamEngine().resolution(safe, output: output, mode: .copy, tracks: .video) else {
            return XCTFail("A switch on a keyframe is refused.")
        }
        XCTAssertEqual(ExportRules.multicamSingleTypeAdvice(tracks: .audio, hasNearest: false, together: nil),
                       "A sound-only multicam export is a Lossless Copy, which needs a verified time at every cut.")
    }

    // MARK: Times in messages

    func testMessagesShowTheirTimesInSecondsOnlyWhereTheyAreDisplayed() {
        let raw = "There is no verified video start boundary at 1/5."
        XCTAssertEqual(ExportRules.displayMessage(raw), "There is no verified video start boundary at 0.200 s.")
        XCTAssertEqual(ExportRules.displayMessage("There is no verified video end boundary at 201/2."),
                       "There is no verified video end boundary at 100.500 s.")
        XCTAssertEqual(ExportRules.displayMessage("The picture and audio track 1 do not share a verified end boundary at 1."),
                       "The picture and audio track 1 do not share a verified end boundary at 1.000 s.")
        XCTAssertEqual(ExportRules.displayMessage("No active switch at 7/25"), "No active switch at 0.280 s")
        XCTAssertEqual(ExportRules.displayMessage("Source a stream 0, group 0–13/25, source 1/2–13/25, output 0–13/25: There is no verified video end boundary at 13/25. Move the cut."),
                       "Source a stream 0, group 0.000–0.520 s, source 0.500–0.520 s, output 0.000–0.520 s: There is no verified video end boundary at 0.520 s. Move the cut.")
        // Paths, rates, track numbers and anything that is not a time stay as written.
        for untouched in ["Expected a regular project file at /tmp/1/5.", "Resolve imported the timeline at 30 fps for 12 frames.",
                          "Audio track 1 has an unspecified or unsupported channel layout.", "Clips 1 and 2 differ in frame rate.",
                          "Timeline cut at 1/5s rounds to 1/4s at 24 fps.", "The frame rate is 30000/1001."] {
            XCTAssertEqual(ExportRules.displayMessage(untouched), untouched)
        }

        // The failure itself keeps the exact time: programs and sidecars match it.
        let file = URL(fileURLWithPath: "/tmp/Clip.mp4")
        let issue = CutError(code: "unsafe_boundary", message: raw, segment: 1, boundary: "from", nearest: [RationalTime(numerator: 1)])
        XCTAssertEqual(issue.message, raw)
        XCTAssertEqual(TierFactor(issue, forces: .lossless).message, raw)
        let described = ExportRules.describe(issue, clips: [ClipRequest(file: file, from: RationalTime(numerator: 1, denominator: 5), to: nil)])
        XCTAssertEqual(described, "Clip 1 · Clip.mp4 at 0.200 s\nThere is no verified video start boundary at 0.200 s.\nVerified alternatives: 1.000 s")
        XCTAssertFalse(described.contains("1/5"))
    }

    // MARK: Mixed timelines in Premiere interchange

    func testPremiereXMLDescribesEachClipOfAMixedTimelineInItsOwnFormat() throws {
        // H.264 320×96 at 25 fps with stereo AAC, then 192×96 at 10 fps with two mono tracks.
        let wide = try fixture("Shuttle-Chirp.mov"), slow = try fixture("Pause-Quiet.mov")
        let project = CutProject.sequence([
            .init(id: "clip-1", file: wide.path, from: .zero, to: t(1)),
            .init(id: "clip-2", file: slow.path, from: t(1), to: t(2)),
            .init(id: "clip-3", file: wide.path, from: t(2), to: t(3))
        ])
        let xml = scratch.appendingPathComponent("mixed.xml")
        XCTAssertEqual(try PremiereTimeline.write(project, relativeTo: xml, to: xml, name: "Mixed", allowLoss: false), [],
                       "Cuts on frames of both clocks lose nothing, so nothing is warned about.")
        let document = try XMLDocument(contentsOf: xml, options: [])
        func values(_ path: String) throws -> [String] { try document.nodes(forXPath: path).compactMap(\.stringValue) }
        // The sequence follows the first clip.
        XCTAssertEqual(try values("/xmeml/sequence/rate/timebase"), ["25"])
        XCTAssertEqual(try values("/xmeml/sequence/media/video/format/samplecharacteristics/width"), ["320"])
        XCTAssertEqual(try values("/xmeml/sequence/media/video/format/samplecharacteristics/height"), ["96"])
        // Each file states its native picture and rate. Premiere interprets the
        // clipitem trim and timeline positions on the sequence clock.
        let items = "/xmeml/sequence/media/video/track/clipitem"
        XCTAssertEqual(try values("\(items)/file/rate/timebase"), ["25", "10"], "A file is described once, where it is first used.")
        XCTAssertEqual(try values("\(items)/file/media/video/samplecharacteristics/rate/timebase"), ["25", "10"])
        XCTAssertEqual(try values("\(items)/file/media/video/samplecharacteristics/width"), ["320", "192"])
        XCTAssertEqual(try values("\(items)[2]/rate/timebase"), ["25"])
        XCTAssertEqual(try values("\(items)[2]/in") + values("\(items)[2]/out"), ["25", "50"])
        XCTAssertEqual(try values("\(items)[2]/start") + values("\(items)[2]/end"), ["25", "50"])
        XCTAssertEqual(try PremiereTimeline.read(xml, allowLoss: false).0, project)

        // A cut the sequence clock cannot place is refused unless loss is allowed, and is then warned about.
        let offClock = CutProject.sequence([
            .init(id: "clip-1", file: wide.path, from: .zero, to: t(1)),
            .init(id: "clip-2", file: slow.path, from: t(1), to: t(21, 10))
        ])
        XCTAssertThrowsError(try PremiereTimeline.write(offClock, relativeTo: xml, to: xml, name: "Mixed", allowLoss: false)) {
            XCTAssertEqual(($0 as? CutError)?.code, "premiere_conversion_loss")
        }
        XCTAssertFalse(try PremiereTimeline.write(offClock, relativeTo: xml, to: xml, name: "Mixed", allowLoss: true).isEmpty)
    }
}
