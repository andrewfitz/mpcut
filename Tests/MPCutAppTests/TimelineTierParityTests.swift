import MPCutCore
import XCTest
@testable import MPCutApp

/// The `mpcut` CLI reports the tier the app's evaluator finds for the same clips.
final class TimelineTierParityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var cli: URL {
        var path = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        if path.lastPathComponent == "PlugIns" {
            path = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return path.appendingPathComponent("mpcut")
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundled = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        let copy = scratch.appendingPathComponent("\(name).\(ext)")
        if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: bundled, to: copy) }
        return copy.standardizedFileURL
    }

    private func t(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private func run(_ arguments: [String], stdin: Data? = nil) throws -> (json: [String: Any], data: Data, text: String) {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], data, text)
    }

    private func tier(_ object: Any?) throws -> TierSummary {
        try JSONDecoder().decode(TierSummary.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object)))
    }

    private func flags(_ clips: [ClipRequest]) -> [String] {
        clips.flatMap { clip in
            ["--clip", clip.file.path] + (clip.from.map { ["--from", $0.description] } ?? []) + (clip.to.map { ["--to", $0.description] } ?? [])
        }
    }

    private func expected(_ clips: [ClipRequest]) throws -> TierSummary {
        var media: [URL: MediaInfo] = [:]
        for clip in clips where media[clip.file] == nil { media[clip.file] = try CutEngine(useSidecar: false).inspect(clip.file, keyframes: true) }
        return TimelineTierEvaluator(useSidecar: false).summary(clips, media: media)
    }

    func testDryRunAndInspectReportTheTierTheAppFinds() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let gop = try fixture("SmartTrim-GOP", "mp4"), webm = try fixture("WebM-Opus-GOP", "webm"), mp3 = try fixture("Gapless-Crop", "mp3")
        // Each timeline with a mode that writes it and a container for the output name.
        let timelines: [(clips: [ClipRequest], mode: String, container: String, tier: String)] = [
            ([ClipRequest(file: gop, from: .zero, to: t(2))], "copy", "mp4", "trueLossless"),
            ([ClipRequest(file: gop, from: t(7, 25), to: t(1)), ClipRequest(file: gop, from: t(31, 25), to: t(2))], "smart", "mp4", "lossless"),
            ([ClipRequest(file: webm, from: t(1), to: t(2)), ClipRequest(file: webm, from: t(3), to: t(4))], "encode", "mp4", "reencode"),
            ([ClipRequest(file: mp3, from: t(1, 10), to: t(3, 10)), ClipRequest(file: mp3, from: t(1, 2), to: t(7, 10))], "encode", "wav", "lossless")
        ]
        for timeline in timelines {
            let app = try expected(timeline.clips)
            XCTAssertEqual(app.id, timeline.tier)
            let needsHelper = timeline.mode == "encode"
            if needsHelper, ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil { continue }
            let result = try run(["export", "--json", "--no-sidecar", "--dry-run", "--mode", timeline.mode,
                                  "--output", scratch.appendingPathComponent("\(UUID().uuidString).\(timeline.container)").path] + flags(timeline.clips))
            XCTAssertEqual(result.json["ok"] as? Bool, true, String(decoding: result.data, as: UTF8.self))
            XCTAssertEqual(try tier(result.json["tier"]), app, "\(timeline.tier): the CLI and the app evaluator disagree.")
        }

        // inspect reports the tier of the whole source, or of the range it is asked about, once the cut index is read.
        let whole = try run(["inspect", "--json", "--no-sidecar", "--keyframes", gop.path])
        XCTAssertEqual(try tier(whole.json["tier"]), try expected([ClipRequest(file: gop)]))
        let range = try run(["inspect", "--json", "--no-sidecar", "--keyframes", "--from", "7/25", "--to", "2", gop.path])
        let cut = try tier(range.json["tier"])
        XCTAssertEqual(cut, try expected([ClipRequest(file: gop, from: t(7, 25), to: t(2))]))
        XCTAssertEqual([cut.id, cut.name, cut.mode?.rawValue ?? ""], ["lossless", "Lossless", "smart"])
        XCTAssertEqual(cut.factors.map(\.id), [.cutVideoStart])
        XCTAssertEqual(cut.raise.first?.arguments, ["--mode", "copy", "--snap", "nearest"])
        XCTAssertNil(try run(["inspect", "--json", "--no-sidecar", gop.path]).json["tier"], "A summary read has no cut index to check.")

        // The arguments that raise the tier do raise it.
        let raised = try run(["export", "--json", "--no-sidecar", "--dry-run", "--output", scratch.appendingPathComponent("raised.mp4").path]
                             + (cut.raise.first?.arguments ?? []) + ["--clip", gop.path, "--from", "7/25", "--to", "2"])
        XCTAssertEqual(raised.json["mode"] as? String, "copy", String(decoding: raised.data, as: UTF8.self))

        // A batch reports the tier of each range.
        let request: [String: Any] = ["file": gop.path, "outputDirectory": scratch.path,
                                      "ranges": [["from": "0", "to": "1"], ["from": "7/25", "to": "2"]]]
        let bulk = try run(["bulk", "--stdin", "--json", "--no-sidecar", "--dry-run"], stdin: JSONSerialization.data(withJSONObject: request))
        let outputs = try XCTUnwrap(bulk.json["outputs"] as? [[String: Any]], String(decoding: bulk.data, as: UTF8.self))
        XCTAssertEqual(try outputs.map { try tier($0["tier"]).id }, ["trueLossless", "lossless"])

        // A project lists the tier of its sequence.
        let project = scratch.appendingPathComponent("edit.cut")
        try CutProject.sequence([CutSequenceClip(id: "a", file: gop.path, from: t(7, 25), to: t(2))]).save(to: project)
        let inspected = try run(["inspect", "--project", project.path, "--json", "--no-sidecar"])
        if inspected.json["ok"] as? Bool == true {
            XCTAssertEqual(try tier(inspected.json["tier"]).id, "lossless")
        } else {
            XCTFail(String(decoding: inspected.data, as: UTF8.self))
        }
    }

    /// `rearrange --dry-run` and `silence --output --dry-run` report the tier of the clips they would write, in the
    /// shape `export` reports it. A bare `inspect` of a movie reads no cut index: it omits the tier and says where it is.
    func testRearrangeSilenceAndInspectReportTheTier() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let gop = try fixture("SmartTrim-GOP", "mp4"), talk = try fixture("Pause-Quiet", "mov")
        func output(_ ext: String) -> String { scratch.appendingPathComponent("\(UUID().uuidString).\(ext)").path }

        // rearrange: the ranges as given, without its default snap, are the clips whose tier is reported.
        let ranges = [ClipRequest(file: gop, from: t(7, 25), to: t(1)), ClipRequest(file: gop, from: .zero, to: t(7, 25))]
        let rearranged = try run(["rearrange", "--json", "--no-sidecar", "--dry-run", "--snap", "exact", gop.path, "--output", output("mp4"), "7/25-1,0-7/25"])
        XCTAssertEqual(rearranged.json["ok"] as? Bool, true, String(decoding: rearranged.data, as: UTF8.self))
        let reported = try tier(rearranged.json["tier"])
        XCTAssertEqual(reported, try expected(ranges))
        XCTAssertEqual(reported.id, FidelityTier.lossless.rawValue)

        // silence: the tier of the retained ranges, which the report lists as segments.
        for mode in ["smart", "copy"] {
            let shortened = try run(["silence", "--json", "--no-sidecar", "--dry-run", "--min-pause", "0.3", "--leave", "0.1", "--mode", mode,
                                     "--output", output("mov"), talk.path])
            XCTAssertEqual(shortened.json["ok"] as? Bool, true, String(decoding: shortened.data, as: UTF8.self))
            let segments = try XCTUnwrap(shortened.json["segments"] as? [[String: Any]])
            let retained = try segments.map { segment -> ClipRequest in
                func time(_ key: String) throws -> RationalTime {
                    try JSONDecoder().decode(RationalTime.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(segment[key])))
                }
                return ClipRequest(file: talk, from: try time("from"), to: try time("to"))
            }
            // Smart Trim removes the pause. Lossless Copy keeps a pause whose edges are not copy points.
            if mode == "smart" { XCTAssertGreaterThan(retained.count, 1, "The fixture has a pause to remove.") }
            let silenceTier = try tier(shortened.json["tier"])
            XCTAssertEqual(silenceTier.id, try expected(retained).id, mode)
            // The same clips through export report the same tier.
            let exported = try run(["export", "--json", "--no-sidecar", "--dry-run", "--mode", mode, "--output", output("mov")] + flags(retained))
            XCTAssertEqual(try tier(exported.json["tier"]).id, silenceTier.id, mode)
        }

        // inspect: the tier needs the cut index. A bare inspection of a movie does not read it.
        let bare = try run(["inspect", "--json", "--no-sidecar", gop.path])
        XCTAssertEqual(bare.json["ok"] as? Bool, true)
        XCTAssertNil(bare.json["tier"], "A bare inspect stays a metadata read.")
        for flag in ["--keyframes", "--frames"] {
            let indexed = try run(["inspect", "--json", "--no-sidecar", flag, gop.path])
            XCTAssertEqual(try tier(indexed.json["tier"]).id, FidelityTier.trueLossless.rawValue, flag)
        }
        let sound = try run(["inspect", "--json", "--no-sidecar", try fixture("Covered-Audio", "mp3").path])
        XCTAssertNotNil(sound.json["tier"], "A sound-only source always reads its packets.")
        let help = try run(["help", "inspect", "--json"])
        XCTAssertTrue((help.json["result"] as? String ?? "").contains(ExportRules.tierReportingHelp))
        for command in ["rearrange", "silence --output", "export --project", "--keyframes"] {
            XCTAssertTrue(ExportRules.tierReportingHelp.contains(command), command)
        }
    }

    /// A multicam program has a tier too. `inspect --project` and `export --project --dry-run` report the one
    /// `MulticamEngine.tier` finds, with the factor that lowers it.
    func testMulticamProjectCommandsReportTheProgramsTier() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let gop = try fixture("SmartTrim-GOP", "mp4")
        let media = try CutEngine(useSidecar: false).inspect(gop, keyframes: true)
        let cases: [(from: RationalTime, id: String, factor: TierFactorID?)] = [
            (.zero, "trueLossless", nil), (t(7, 25), "lossless", .cutVideoStart), (t(1, 3), "unavailable", .cutOffFrame)
        ]
        for (from, id, factor) in cases {
            var project = MulticamProject(referenceAngle: "a", range: MulticamRange(from: .zero, to: media.duration),
                                          angles: [.init(id: "a", file: gop.path)], audio: .none, switches: [.init(at: .zero, angle: "a")])
            project.assembly = [MulticamRange(from: from, to: media.duration)]
            let file = scratch.appendingPathComponent("\(UUID().uuidString).cut")
            try CutProject.multicam(project).save(to: file)
            let state = MulticamEngine().tier(project, relativeTo: file)
            let engine = state.summary(source: .multicam)
            XCTAssertEqual(engine.id, id)
            XCTAssertEqual(engine.factors.map(\.id), factor.map { [$0] } ?? [])
            if let factor {
                XCTAssertEqual(engine.factors.first?.segment, 1)
                XCTAssertEqual(engine.factors.first?.boundary, "from")
                XCTAssertFalse((engine.factors.first?.nearest ?? []).isEmpty, "\(factor.rawValue) offers verified times.")
            }
            let inspected = try run(["inspect", "--project", file.path, "--json", "--no-sidecar"])
            XCTAssertEqual(try tier(inspected.json["tier"]), engine, "inspect --project, \(id)")
            guard id != "unavailable" else { continue }
            // The tier's own mode plans, and the report carries the same tier whatever mode was asked.
            let mode = try XCTUnwrap(engine.mode)
            let planned = try run(["export", "--project", file.path, "--json", "--no-sidecar", "--dry-run", "--mode", mode.rawValue,
                                   "--output", scratch.appendingPathComponent("\(UUID().uuidString).mov").path])
            XCTAssertEqual(planned.json["ok"] as? Bool, true, String(decoding: planned.data, as: UTF8.self))
            XCTAssertEqual(try tier(planned.json["tier"]), engine, "export --project, \(id)")
            // The next better mode does not plan, and its failure names the factor.
            if let factor {
                let better = try run(["export", "--project", file.path, "--json", "--no-sidecar", "--dry-run", "--mode", "copy",
                                      "--output", scratch.appendingPathComponent("\(UUID().uuidString).mov").path])
                let error = try XCTUnwrap(better.json["error"] as? [String: Any])
                XCTAssertEqual(error["reason"] as? String, factor.rawValue)
            }
        }

        // `silence --project --output` reports the tier of its retained ranges.
        let talk = try fixture("Pause-Quiet", "mov")
        let spoken = try CutEngine(useSidecar: false).inspect(talk, keyframes: true)
        let sound = try XCTUnwrap(spoken.streams.first { $0.kind == "audio" })
        let program = MulticamProject(referenceAngle: "a", range: MulticamRange(from: .zero, to: spoken.duration),
                                      angles: [.init(id: "a", file: talk.path)], audio: .fixed(.init(source: "a", stream: sound.index)),
                                      switches: [.init(at: .zero, angle: "a")])
        let file = scratch.appendingPathComponent("talk.cut")
        try CutProject.multicam(program).save(to: file)
        let shortened = try run(["silence", "--project", file.path, "--json", "--no-sidecar", "--min-pause", "0.3", "--leave", "0.1",
                                 "--output", scratch.appendingPathComponent("talk.mov").path, "--dry-run"])
        XCTAssertEqual(shortened.json["ok"] as? Bool, true, String(decoding: shortened.data, as: UTF8.self))
        let reported = try tier(shortened.json["tier"])
        struct Span: Decodable {
            let from: RationalTime
            let to: RationalTime
        }
        let ranges = try JSONDecoder().decode([Span].self, from: JSONSerialization.data(
            withJSONObject: try XCTUnwrap(shortened.json["clips"] as? [[String: Any]]).map { try XCTUnwrap($0["group"]) }))
            .map { MulticamRange(from: $0.from, to: $0.to) }
        XCTAssertGreaterThan(ranges.count, 1, "The fixture has a pause to remove.")
        XCTAssertEqual(reported, MulticamEngine().tier(program, relativeTo: file, assembly: ranges).summary(source: .multicam))
    }

    func testFailuresCarryTheirFactorAndPeopleReadTheTier() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let gop = try fixture("SmartTrim-GOP", "mp4"), other = try fixture("VFR-PTS", "mp4")
        func refusal(_ arguments: [String]) throws -> [String: Any] {
            let result = try run(["export", "--json", "--no-sidecar", "--dry-run", "--output", scratch.appendingPathComponent("\(UUID().uuidString).mp4").path] + arguments)
            return try XCTUnwrap(result.json["error"] as? [String: Any], String(decoding: result.data, as: UTF8.self))
        }
        let unsafe = try refusal(["--mode", "copy", "--clip", gop.path, "--from", "7/25"])
        XCTAssertEqual([unsafe["code"] as? String, unsafe["reason"] as? String], ["unsafe_boundary", "cut.videoStart"])
        XCTAssertEqual((unsafe["alternatives"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["smartTrim", "reencode"],
                       "The reason is added. What the failure offers is unchanged.")

        // Clips that do not match (a mixed timeline) are refused by the modes that join packets, which say why in terms
        // of the tier and offer the re-encode. Re-encode writes them, so the tier is Re-encode.
        for mode in ["copy", "smart"] {
            let mismatch = try refusal(["--mode", mode, "--clip", gop.path, "--clip", other.path])
            XCTAssertEqual([mismatch["code"] as? String, mismatch["reason"] as? String], ["incompatible_clip", "join.streamMismatch"], mode)
            XCTAssertEqual((mismatch["alternatives"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["reencode"], mode)
        }
        XCTAssertEqual(try expected([ClipRequest(file: gop), ClipRequest(file: other)]).mode, .encode)
        XCTAssertEqual(try expected([ClipRequest(file: gop), ClipRequest(file: other)]).factors.map(\.id), [.joinStreamMismatch])

        // Without --json the failure names the tier of the clips.
        let human = try run(["export", "--no-sidecar", "--dry-run", "--mode", "copy", "--output", scratch.appendingPathComponent("human.mp4").path,
                             "--clip", gop.path, "--from", "7/25"])
        XCTAssertTrue(human.text.contains("Timeline tier: Lossless"), human.text)

        // Without --mode, export uses the table's default, as the app does. The tier never changes what is written.
        let plain = try run(["export", "--json", "--no-sidecar", "--dry-run", "--output", scratch.appendingPathComponent("plain.mp4").path, "--clip", gop.path])
        XCTAssertEqual(plain.json["mode"] as? String, ExportRules.defaultMode(for: .movie).rawValue)
        XCTAssertEqual(try tier(plain.json["tier"]).mode, .copy)
    }
}
