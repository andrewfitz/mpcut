import AppKit
import MPCutCore
import XCTest
@testable import MPCutApp

/// Drift tests for export decisions. The rules live in MPCutCore/ExportRules.swift. These tests
/// fail when the written matrix, the app's export sheet or the `mpcut` CLI stops agreeing with them.
final class ExportRulesParityTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static var helper: String {
        ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
            ?? repository.appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg").path
    }

    override class func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil,
           FileManager.default.isExecutableFile(atPath: helper) { setenv("MPCUT_FFMPEG_HELPER", helper, 1) }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: The written matrix

    func testWrittenMatrixIsGeneratedFromTheRules() throws {
        let document = Self.repository.appendingPathComponent("docs/EXPORT-RULES.md")
        let generated = ExportRules.markdown()
        if ProcessInfo.processInfo.environment["MPCUT_WRITE_EXPORT_RULES"] == "1" {
            try generated.write(to: document, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), generated,
                       "docs/EXPORT-RULES.md is out of date. Regenerate it with MPCUT_WRITE_EXPORT_RULES=1 swift test --filter ExportRulesParityTests.")
    }

    func testVisiblePlacementsKeepTrackSelectionInTheExportRules() {
        for (source, entry) in [(ExportSourceKind.movie, ExportEntryPoint.sheet), (.multicam, .multicamSheet)] {
            XCTAssertEqual(entry.selectableModes(source: source, tracks: .video, placements: .replacement), [.smart, .copy, .encode])
            XCTAssertEqual(entry.answer(source: source, tracks: .video, mode: .copy,
                                        placements: .replacement).refusal?.factor, .placementPicture)
            XCTAssertEqual(entry.answer(source: source, tracks: .audio, mode: .copy,
                                        placements: .insertion).refusal?.factor, .placementSilence)
            XCTAssertTrue(entry.answer(source: source, tracks: .audio, mode: .copy,
                                       placements: .replacement).isAllowed)
            XCTAssertTrue(entry.answer(source: source, tracks: .audio, mode: .encode,
                                       placements: .insertion).isAllowed)
        }
        XCTAssertEqual(ExportRules.defaultStillMode(tracks: .all, placements: .replacement, otherwise: .copy), .smart)
        XCTAssertEqual(ExportRules.defaultStillMode(tracks: .audio, placements: .replacement, otherwise: .copy), .copy)
    }

    func testLadderOrderFollowsTheNamedRankingCriteria() {
        let ranked = ExportRung.allCases.sorted { $0.rank < $1.rank }
        XCTAssertEqual(ranked, [.copyOtherContainer, .copySampleAligned, .smartTrim, .convertSameFormat, .convertPCM, .convertAAC, .reencode])
        for cell in ExportRules.cells {
            XCTAssertEqual(cell.rungs, cell.rungs.sorted { $0.rank < $1.rank }, "\(cell.source) \(cell.tracks) \(cell.mode)")
            XCTAssertEqual(cell.refusal == nil, cell.isAllowed)
        }
    }

    /// Export rule literals belong to ExportRules.swift. Front ends ask the rules instead of restating them.
    func testFrontEndsDoNotRestateExportRules() throws {
        // Each pattern is a rule that used to be written out by hand in more than one place.
        let patterns = [
            "? mode : .copy",              // forcing copy for a single-type selection
            "? requestedMode : .copy",
            "[\"mp4\", \"mov\", \"mkv\"]", // re-encode containers
            "[\"mov\", \"mkv\"]",          // ProRes containers
            "[\"wav\", \"caf\", \"mov\"]", // PCM conversion containers
            "\"Lossless Copy\"",           // mode names
            "\"Smart Trim\"",
            "\"Convert Audio\"",
            "\"Re-encode\"",
            "(Lossless Copy)\"",           // the mode a single-type multicam selection is written with
            "[ExportMode.smart, .copy, .encode]", // the modes of an entry point
            "Choose MOV, MP4, MKV or WebM for multicam", // multicam containers
            "[.proresLT, .prores422, .proresHQ]", // quality presets
            "[.smallerFile, .balanced, .highQuality]",
            "[.copyOriginal, .aac, .pcm, .removeAudio]", // audio actions
            "Choose MOV or MKV for PCM audio", // refusal wording
            "Choose MP4, MOV, or MKV for Re-encode",
            "[\"mov\", \"mp4\", \"mkv\", \"webm\"]", // Replace Source Audio containers
            "\"mka\", \"m4a\", \"wav\"",
            "Choose a supported replacement container",
            "\"Matroska Audio (.mka)\"",       // container names
            "\"MPEG-4 Audio (.m4a)\""
        ]
        // The MCP front end is being rewritten separately. Every other file asks ExportRules.
        let notMigrated: Set<String> = ["MCPOutputs.swift"]
        // Lines that use the same literal for something that is not an export rule, with the reason.
        let exempt: [(file: String, line: String, reason: String)] = [
            ("CutEngine.swift", "probeOrder.append(contentsOf: [\"mov\", \"mkv\"])", "the order in which the copy planner probes containers")
        ]
        // The rules module is where these literals belong.
        let rules = "ExportRules.swift"
        var offences: [String] = []
        for folder in ["Sources/MPCutApp", "Sources/MPCutCLI", "Sources/MPCutCore"] {
            let directory = Self.repository.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            where name.hasSuffix(".swift") && !notMigrated.contains(name) && name != rules {
                let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if exempt.contains(where: { $0.file == name && line.contains($0.line) }) { continue }
                    for pattern in patterns where line.contains(pattern) {
                        offences.append("\(folder)/\(name):\(number + 1) restates \(pattern)")
                    }
                }
            }
        }
        XCTAssertEqual(offences, [], "Ask ExportRules for these instead.")
    }

    // MARK: Running both front ends

    private struct Outcome: Equatable, CustomStringConvertible {
        var mode = "", container = "", actions: [String] = [], bitRate: Int?
        var code = "", message = ""
        var alternatives: [String] = [], labels: [String] = []
        var description: String {
            code.isEmpty ? "ready \(mode) .\(container) \(actions) \(bitRate.map(String.init) ?? "")"
                : "\(code): \(message) → \(alternatives) \(labels)"
        }
    }

    private var cli: URL {
        var path = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        if path.lastPathComponent == "PlugIns" {
            path = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return path.appendingPathComponent("mpcut")
    }

    private func arguments(_ clips: [ClipRequest]) -> [String] {
        clips.flatMap { clip -> [String] in
            ["--clip", clip.file.path] + (clip.from.map { ["--from", $0.description] } ?? [])
                + (clip.to.map { ["--to", $0.description] } ?? [])
        }
    }

    /// Runs `mpcut export clips join --dry-run --json` and reads the fields the sheet also knows.
    private func runCLI(_ flags: [String], clips: [String], container: String, helper: String? = nil) throws
        -> (outcome: Outcome, alternatives: [[String: Any]]) {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["export", "clips", "join", "--json", "--no-sidecar", "--dry-run"] + flags
            + ["--output", scratch.appendingPathComponent("\(UUID().uuidString).\(container)").path] + clips
        var environment = ProcessInfo.processInfo.environment
        environment["MPCUT_FFMPEG_HELPER"] = helper ?? Self.helper
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
        var outcome = Outcome()
        if let error = report["error"] as? [String: Any] {
            outcome.code = error["code"] as? String ?? ""
            outcome.message = error["message"] as? String ?? ""
            let offers = error["alternatives"] as? [[String: Any]] ?? []
            outcome.alternatives = offers.compactMap { $0["id"] as? String }
            outcome.labels = offers.compactMap { $0["label"] as? String }
            return (outcome, offers)
        }
        outcome.mode = report["mode"] as? String ?? ""
        outcome.container = report["container"] as? String ?? ""
        let actions = report["audio_actions"] as? [[String: Any]] ?? []
        outcome.actions = actions.compactMap { $0["action"] as? String }
        outcome.bitRate = actions.first?["bit_rate"] as? Int
        return (outcome, [])
    }

    @MainActor
    private final class Sheet {
        let panel = NSSavePanel()
        let control: ExportFormatControl
        private(set) var options: ExportSheetOptions

        init(_ options: ExportSheetOptions, clips: [ClipRequest], media: MediaInfo) {
            self.options = options
            let choices = ExportContainerChoices(source: media, clips: clips, preferred: nil, cancelled: { false })
            let box = Box()
            self.box = box
            control = ExportFormatControl(panel: panel, options: options, copyContainers: choices, clips: clips,
                                          media: [media.url: media], useSidecar: false,
                                          changed: { changed, _ in box.options = changed },
                                          directoryChanged: { _ in })
        }

        private final class Box { var options: ExportSheetOptions? }
        private let box: Box
        var current: ExportSheetOptions { box.options ?? options }

        func settle() async throws {
            let limit = ContinuousClock.now + .seconds(30)
            while control.isChecking, .now < limit { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(control.isChecking, "The export check did not finish.")
        }

        var outcome: Outcome {
            var result = Outcome()
            if let failure = control.failure {
                result.code = failure.code
                result.message = failure.message
                result.alternatives = control.alternatives.map(\.alternative.id)
                result.labels = control.alternatives.map(\.title)
                return result
            }
            guard let plan = control.selected else { return result }
            result.mode = plan.mode.rawValue
            result.container = plan.edit.container
            switch plan {
            case .packets: break
            case .conversion(let conversion): result.actions = conversion.audioActions.map(\.action.rawValue)
            case .audio(let audio):
                result.actions = audio.actions.map(\.action.rawValue)
                result.bitRate = audio.actions.first?.bitRate
            }
            return result
        }

        var modeTitles: [String] {
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
            return views(panel.accessoryView!).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityLabel() == "Mode" }?.itemTitles ?? []
        }
    }

    /// The same request through the sheet and the CLI, then every alternative through both.
    @MainActor
    private func assertParity(_ name: String, file: URL, clips: [ClipRequest], options: ExportSheetOptions,
                              expecting ids: [String]? = nil, helper: String? = nil,
                              line: UInt = #line) async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let media = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        let sound = media.streams.filter { $0.kind == "audio" }
        let stream = options.audioTrackOrdinal.flatMap { sound.indices.contains($0) ? sound[$0].index : nil }
        let sheet = Sheet(options, clips: clips, media: media)
        defer { sheet.control.stopChecking() }
        try await sheet.settle()
        let app = sheet.outcome
        let flags = ExportRules.arguments(for: options.request(clips), audioStream: stream)
        let tool = try runCLI(flags, clips: arguments(clips), container: options.container, helper: helper)
        XCTAssertEqual(app, tool.outcome, "\(name): the sheet and `mpcut \(flags.joined(separator: " "))` disagree.", line: line)
        if let ids { XCTAssertEqual(app.alternatives, ids, name, line: line) }

        for (index, offer) in sheet.control.alternatives.enumerated() {
            // Applying alternative N in the sheet is the request the CLI makes with alternative N's arguments.
            let applied = Sheet(options, clips: clips, media: media)
            defer { applied.control.stopChecking() }
            try await applied.settle()
            let chosen = try XCTUnwrap(applied.control.alternatives.indices.contains(index) ? applied.control.alternatives[index] : nil)
            applied.control.apply(chosen)
            try await applied.settle()
            let listed = try XCTUnwrap(tool.alternatives.indices.contains(index) ? tool.alternatives[index] : nil)
            let moved = (listed["clips"] as? [[String: String]])?.flatMap {
                ["--clip", $0["file"] ?? "", "--from", $0["from"] ?? "", "--to", $0["to"] ?? ""]
            }
            let result = try runCLI(listed["arguments"] as? [String] ?? [], clips: moved ?? arguments(clips),
                                    container: listed["container"] as? String ?? "", helper: helper)
            XCTAssertEqual(applied.outcome, result.outcome, "\(name): alternative \(offer.alternative.id) resolves differently.", line: line)
            XCTAssertEqual(applied.outcome.code, "", "\(name): alternative \(offer.alternative.id) was offered and does not work.", line: line)
            XCTAssertEqual(applied.outcome.container, offer.alternative.container, name, line: line)
            XCTAssertEqual(applied.outcome.mode, offer.alternative.mode.rawValue, name, line: line)
            XCTAssertEqual(listed["lossless"] as? Bool, offer.alternative.lossless, name, line: line)
            XCTAssertEqual(applied.current.container, offer.alternative.container, name, line: line)
        }
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundled = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        let copy = scratch.appendingPathComponent("\(name).\(ext)")
        if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: bundled, to: copy) }
        return copy.standardizedFileURL
    }

    private func time(_ numerator: Int64, _ denominator: Int64) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private func soundOptions(_ container: String, converting: ReencodeAudio? = nil) -> ExportSheetOptions {
        var options = ExportSheetOptions()
        options.tracks = .audio
        options.copyContainer = container
        if let converting {
            options.convertAudio(to: converting)
            options.conversionContainer = container
        }
        return options
    }

    /// Converts the MP3 fixture so that every codec has a short source with known cuts.
    private func converted(_ name: String, to action: ReencodeAudio) throws -> URL {
        let output = scratch.appendingPathComponent(name)
        let engine = AudioExportEngine(useSidecar: false)
        try engine.write(engine.resolve([ClipRequest(file: try fixture("Gapless-Crop", "mp3"))], output: output, audio: action), to: output)
        return output.standardizedFileURL
    }

    // MARK: The request matrix

    @MainActor
    func testSameRequestsResolveIdenticallyInTheSheetAndTheCLI() async throws {
        _ = NSApplication.shared
        let mp3 = try fixture("Gapless-Crop", "mp3")
        func cuts(_ file: URL) -> [ClipRequest] {
            [ClipRequest(file: file, from: time(1, 10), to: time(3, 10)), ClipRequest(file: file, from: time(1, 2), to: time(7, 10))]
        }

        try await assertParity("MP3 join", file: mp3, clips: cuts(mp3), options: soundOptions("mp3"),
                               expecting: ["convert_same_format", "convert_pcm", "convert_aac"])
        let whole = try CutEngine(useSidecar: false).inspect(mp3, keyframes: true)
        try await assertParity("contiguous MP3", file: mp3, clips: [ClipRequest(file: mp3, from: .zero, to: whole.duration)],
                               options: soundOptions("mp3"), expecting: [])
        try await assertParity("MP3 join converting to PCM in a wrong extension", file: mp3, clips: cuts(mp3),
                               options: soundOptions("m4a", converting: .pcm))

        let flac = try converted("Tone.flac", to: .flac)
        try await assertParity("FLAC join inside frames", file: flac, clips: cuts(flac), options: soundOptions("flac"),
                               expecting: ["convert_same_format", "convert_pcm", "convert_aac"])
        let frames = CutEngine(useSidecar: false, tracks: .audio)
            .validBoundaries(in: try CutEngine(useSidecar: false).inspect(flac, keyframes: true), start: true)
        if frames.count > 4 {
            let aligned = [ClipRequest(file: flac, from: frames[1], to: frames[2]), ClipRequest(file: flac, from: frames[3], to: frames[4])]
            try await assertParity("FLAC join on frame boundaries", file: flac, clips: aligned, options: soundOptions("flac"),
                                   expecting: ["copy_other_container:mka", "convert_same_format", "convert_pcm", "convert_aac"])
        }

        let m4a = try converted("Tone.m4a", to: .aac)
        let between = [ClipRequest(file: m4a, from: time(100_001, 1_000_000), to: time(3, 10)),
                       ClipRequest(file: m4a, from: time(1, 2), to: time(700_001, 1_000_000))]
        try await assertParity("AAC in M4A cut between samples", file: m4a, clips: between, options: soundOptions("m4a"))
        let media = try CutEngine(useSidecar: false).inspect(m4a, keyframes: true)
        let first = ExportAvailability.resolve(soundOptions("m4a"), clips: between, media: [m4a: media], useSidecar: false).offers.first
        XCTAssertEqual(first?.alternative.id, "copy_sample_aligned", "An exact copy on the sample clock ranks before any conversion.")
        XCTAssertEqual(first?.alternative.lossless, true)

        let opus = try fixture("Standalone-Chirp", "opus")
        try await assertParity("Opus join", file: opus, clips: cuts(opus), options: soundOptions("opus"),
                               expecting: ["convert_same_format", "convert_pcm", "convert_aac"])
        try await assertParity("Opus join converting to Opus in WebM", file: opus, clips: cuts(opus),
                               options: soundOptions("webm", converting: .opus))
        try await assertParity("MP3 join converting to Opus", file: mp3, clips: cuts(mp3), options: soundOptions("opus", converting: .opus))
        try await assertParity("Opus conversion in a wrong extension", file: opus, clips: cuts(opus),
                               options: soundOptions("m4a", converting: .opus))

        let movie = try fixture("SmartTrim-GOP", "mp4")
        let picture = try CutEngine(useSidecar: false).inspect(movie, keyframes: true)
        var copy = ExportSheetOptions()
        copy.mode = .copy
        copy.copyContainer = "mp4"
        try await assertParity("movie with an unsafe copy cut", file: movie,
                               clips: [ClipRequest(file: movie, from: time(7, 25), to: picture.duration)], options: copy)
        let offered = ExportAvailability.resolve(copy, clips: [ClipRequest(file: movie, from: time(7, 25), to: picture.duration)],
                                                 media: [movie: picture], useSidecar: false).offers.map(\.alternative.rung)
        XCTAssertEqual(offered.first, .smartTrim)

        let talkie = try fixture("Shuttle-Chirp", "mov")
        let talk = try CutEngine(useSidecar: false).inspect(talkie, keyframes: true)
        let soundtrack = CutEngine(useSidecar: false, tracks: .audio).suggestedContainers(for: talk).first ?? "m4a"
        try await assertParity("movie, audio tracks only", file: talkie,
                               clips: [ClipRequest(file: talkie, from: .zero, to: talk.duration)], options: soundOptions(soundtrack))

        let multitrack = try fixture("Standalone-Multitrack", "mka")
        let tracks = try CutEngine(useSidecar: false).inspect(multitrack, keyframes: true)
        try await assertParity("multitrack audio selection", file: multitrack,
                               clips: [ClipRequest(file: multitrack, from: .zero, to: tracks.duration)],
                               options: soundOptions("wav", converting: .pcm))
    }

    /// A sound-only timeline whose exact copy is unavailable opens on Lossless Copy, where the alternatives that work
    /// are listed best first. Opening on the tier's conversion, PCM, hid `copy_sample_aligned`, which ranks above it.
    /// `--audio auto` applies the same first alternative.
    @MainActor
    func testSoundOnlyExportOpensOnCopyWithTheBestWorkingAlternativeFirst() async throws {
        _ = NSApplication.shared
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let wave = try converted("between-samples.wav", to: .pcm)
        let media = try CutEngine(useSidecar: false).inspect(wave)
        // A cut between two samples: the copy is refused, the copy on the nearest samples works, and so does a PCM rewrite.
        let clips = [ClipRequest(file: wave, from: time(100_001, 1_000_000), to: time(3, 10))]
        let tier = TimelineTierEvaluator(useSidecar: false).evaluate(clips, media: [wave: media])
        XCTAssertEqual(tier.tier, .lossless, "\(tier.factors.map(\.message))")

        // The opening state, as EditorModel.chooseExport builds it for a new installation.
        let mode = ExportRules.openingMode(preferred: EditorPreferences.factoryExportMode, tier: tier.tier, source: .audio)
        XCTAssertEqual(mode, .copy)
        let request = ExportRequest(clips: clips, mode: mode, tracks: .audio)
        let verified = ExportPlanner(useSidecar: false).openingContainer(for: request, preferred: nil, media: [wave: media])
        let choices = ExportContainerChoices(source: media, clips: clips, preferred: nil, cancelled: { false })
        let options = EditorModel.openingExportOptions(ExportSheetOptions(), mode: mode, convertingByName: false, source: media,
                                                       choices: choices, preferred: nil, verified: verified)
        XCTAssertEqual(options.tracks, .audio)
        XCTAssertFalse(options.convertsAudio, "The sheet opens on Lossless Copy, not on Convert Audio.")
        XCTAssertEqual(options.effectiveMode, .copy)

        let sheet = Sheet(options, clips: clips, media: media)
        try await sheet.settle()
        let offered = sheet.outcome.alternatives
        XCTAssertEqual(sheet.outcome.code, "unsafe_boundary", sheet.outcome.description)
        XCTAssertEqual(offered.first, ExportRung.copySampleAligned.rawValue, "The best-ranked alternative that works comes first.")
        XCTAssertTrue(offered.contains(ExportRung.convertPCM.rawValue), "\(offered)")
        let ranks = offered.compactMap { id in ExportRung(rawValue: String(id.prefix { $0 != ":" }))?.rank }
        XCTAssertEqual(ranks, ranks.sorted(), "No lower-ranked alternative is listed ahead of a better one.")

        // Convert Audio asked for by name still opens on the conversion.
        let named = EditorModel.openingExportOptions(ExportSheetOptions(), mode: .encode, convertingByName: true, source: media,
                                                     choices: choices, preferred: nil, verified: nil)
        XCTAssertTrue(named.convertsAudio)

        // The CLI: a copy reports the same alternatives, and `--audio auto` applies the first of them.
        let flags = ["--tracks", "audio"]
        let copied = try runCLI(["--mode", "copy"] + flags, clips: arguments(clips), container: "wav")
        XCTAssertEqual(copied.outcome.alternatives, offered)
        let process = Process()
        process.executableURL = cli
        process.arguments = ["export", "clips", "join", "--json", "--no-sidecar", "--dry-run", "--mode", "encode", "--audio", "auto"] + flags
            + ["--output", scratch.appendingPathComponent("auto.wav").path] + arguments(clips)
        var environment = ProcessInfo.processInfo.environment
        environment["MPCUT_FFMPEG_HELPER"] = Self.helper
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
        XCTAssertEqual(report["applied"] as? String, offered.first, String(decoding: data, as: UTF8.self))
        XCTAssertEqual(report["mode"] as? String, ExportMode.copy.rawValue)
    }

    @MainActor
    func testMissingEncoderIsSkippedIdenticallyInBothFrontEnds() async throws {
        _ = NSApplication.shared
        // Stand in for an earlier helper: the same program, reporting no MP3, FLAC or Opus encoder.
        let folder = scratch.appendingPathComponent("earlier helper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let old = folder.appendingPathComponent("ffmpeg")
        let script = "#!/bin/sh\ncase \" $* \" in\n  *\" -encoders \"*) \"\(Self.helper)\" \"$@\" | grep -v -e libmp3lame -e \" flac \" -e libopus; exit 0 ;;\nesac\nexec \"\(Self.helper)\" \"$@\"\n"
        try script.write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
        let previous = ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
        setenv("MPCUT_FFMPEG_HELPER", old.path, 1)
        defer { if let previous { setenv("MPCUT_FFMPEG_HELPER", previous, 1) } else { unsetenv("MPCUT_FFMPEG_HELPER") } }
        let mp3 = try fixture("Gapless-Crop", "mp3")
        let clips = [ClipRequest(file: mp3, from: time(1, 10), to: time(3, 10)), ClipRequest(file: mp3, from: time(1, 2), to: time(7, 10))]
        try await assertParity("MP3 join without an MP3 encoder", file: mp3, clips: clips, options: soundOptions("mp3"),
                               expecting: ["convert_pcm", "convert_aac"], helper: old.path)
        try await assertParity("MP3 conversion without an MP3 encoder", file: mp3, clips: clips,
                               options: soundOptions("mp3", converting: .mp3), helper: old.path)
        let opus = try fixture("Standalone-Chirp", "opus")
        let pieces = [ClipRequest(file: opus, from: time(1, 10), to: time(3, 10)), ClipRequest(file: opus, from: time(1, 2), to: time(7, 10))]
        try await assertParity("Opus join without an Opus encoder", file: opus, clips: pieces, options: soundOptions("opus"),
                               expecting: ["convert_pcm", "convert_aac"], helper: old.path)
        try await assertParity("Opus conversion without an Opus encoder", file: opus, clips: pieces,
                               options: soundOptions("opus", converting: .opus), helper: old.path)
        let refused = ExportAvailability.resolve(soundOptions("opus", converting: .opus), clips: pieces,
                                                 media: [opus: try CutEngine(useSidecar: false).inspect(opus, keyframes: true)], useSidecar: false)
        XCTAssertEqual(refused.failure?.code, "encoder_unavailable")
    }

    // MARK: Every cell of the matrix

    @MainActor
    func testEveryCellOfTheMatrixIsWhatTheSheetAndTheCLIDo() async throws {
        _ = NSApplication.shared
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let sources: [ExportSourceKind: URL] = [.movie: try fixture("Shuttle-Chirp", "mov"), .audio: try fixture("Gapless-Crop", "mp3")]
        for cell in ExportRules.cells {
            // A multicam program is planned by MulticamEngine. Its cells are stated in the table as restrictions.
            guard let file = sources[cell.source] else { continue }
            let name = "\(cell.source.rawValue) × \(cell.tracks.rawValue) × \(cell.mode.rawValue)"
            let media = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
            let clips = [ClipRequest(file: file, from: .zero, to: media.duration)]
            let copyContainer = CutEngine(useSidecar: false, tracks: cell.tracks).suggestedContainers(for: media, clips: clips).first
                ?? file.pathExtension
            let container = cell.resolvedMode == .encode && !cell.audioActions.contains(.mp3) ? (cell.containers?.first ?? copyContainer) : copyContainer
            var flags = ["--mode", cell.mode.rawValue]
            // The table merges `all` into `audio` for a recording without picture. Ask for what the cell was built from.
            let asked: ExportTracks = cell.source == .audio && cell.tracks == .audio ? .all : cell.tracks
            if asked != .all { flags += ["--tracks", asked.rawValue] }
            let tool = try runCLI(flags, clips: arguments(clips), container: container).outcome
            if let refusal = cell.refusal {
                XCTAssertEqual([tool.code, tool.message], [refusal.code, refusal.message], name)
            } else {
                XCTAssertEqual(tool.code, "", "\(name): \(tool.message)")
                // A whole source copies exactly, which is what `auto` does first for a sound-only encode.
                let written = cell.resolvedMode == .encode && cell.defaultAudio == .auto && cell.audioActions.contains(.mp3)
                    ? ExportMode.copy : cell.resolvedMode
                XCTAssertEqual(tool.mode, written.rawValue, name)
                XCTAssertEqual(tool.container, container, name)
            }

            // The sheet offers exactly the modes the table writes as themselves for this selection.
            guard cell.source == .movie || cell.tracks == .audio else { continue }
            var options = ExportSheetOptions()
            options.tracks = cell.tracks
            options.copyContainer = copyContainer
            let sheet = Sheet(options, clips: clips, media: media)
            defer { sheet.control.stopChecking() }
            let selectable = [ExportMode.smart, .copy, .encode].map { ExportRules.cell(source: cell.source, tracks: cell.tracks, mode: $0) }
                .filter { $0.isAllowed && $0.resolvedMode == $0.mode }
            XCTAssertEqual(sheet.modeTitles, selectable.map(\.displayName), name)
            if cell.isAllowed, cell.resolvedMode == cell.mode, cell.mode != .encode {
                var chosen = options
                if cell.tracks == .all { chosen.mode = cell.mode }
                let direct = ExportAvailability.resolve(chosen, clips: clips, media: [file: media], useSidecar: false)
                guard case .ready(let plan) = direct.availability else {
                    XCTFail("\(name): the sheet refuses what the table allows. \(direct.failure?.message ?? "")")
                    continue
                }
                XCTAssertEqual([plan.mode.rawValue, plan.edit.container], [tool.mode, tool.container], name)
            }
        }
    }

    // MARK: Every entry point

    /// Runs one `mpcut` command with `--json` and reads its plan or failure, wherever the command nests the plan.
    private func tool(_ arguments: [String], stdin: Data? = nil) throws -> (outcome: Outcome, alternatives: [[String: Any]]) {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["MPCUT_FFMPEG_HELPER"] = Self.helper
        process.environment = environment
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   "\(arguments.joined(separator: " ")): \(String(decoding: data, as: UTF8.self))")
        var outcome = Outcome()
        if let error = report["error"] as? [String: Any] {
            outcome.code = error["code"] as? String ?? ""
            outcome.message = error["message"] as? String ?? ""
            let offers = error["alternatives"] as? [[String: Any]] ?? []
            outcome.alternatives = offers.compactMap { $0["id"] as? String }
            outcome.labels = offers.compactMap { $0["label"] as? String }
            return (outcome, offers)
        }
        let first = (report["outputs"] as? [[String: Any]])?.first
        let plan = (first?["export"] as? [String: Any]) ?? first ?? report
        outcome.mode = plan["mode"] as? String ?? ""
        outcome.container = plan["container"] as? String ?? ""
        return (outcome, [])
    }

    /// One whole-source request through a CLI entry point.
    private func run(_ entry: ExportEntryPoint, flags: [String], clip: ClipRequest, container: String?) throws
        -> (outcome: Outcome, alternatives: [[String: Any]]) {
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = clip.file.path
        let output = folder.appendingPathComponent("out.\(container ?? clip.file.pathExtension)").path
        let from = (clip.from ?? .zero).description, to = clip.to?.description ?? ""
        let common = ["--json", "--no-sidecar", "--dry-run"]
        switch entry {
        case .cliBulk:
            var request: [String: Any] = ["file": file, "output_directory": folder.path, "ranges": [["from": from, "to": to]]]
            if let container { request["container"] = container }
            return try tool(["export", "ranges", "separate", "--stdin"] + common + flags, stdin: JSONSerialization.data(withJSONObject: request))
        case .cliRearrange: return try tool(["export", "ranges", "join"] + common + flags + [file, "--output", output, "\(from)-\(to)"])
        case .cliSilence: return try tool(["silence", "plan"] + common + flags + ["--output", output, file])
        case .cliScenes: return try tool(["scenes", "export"] + common + ["--export-to", folder.path] + flags + [file])
        default:
            var arguments = ["export", "clips", "join"] + common + flags + ["--output", output, "--clip", file, "--from", from]
            if clip.to != nil { arguments += ["--to", to] }
            return try tool(arguments)
        }
    }

    /// A one-angle program over a fixture, written as a project file the CLI and the app both load.
    private func program(_ movie: URL, assembly: (from: RationalTime, to: RationalTime)? = nil) throws
        -> (file: URL, project: MulticamProject) {
        let media = try CutEngine(useSidecar: false).inspect(movie, keyframes: true)
        let sound = media.streams.first { $0.kind == "audio" }
        let project = MulticamProject(referenceAngle: "a", range: MulticamRange(from: .zero, to: media.duration),
                                      angles: [.init(id: "a", file: movie.path)],
                                      audio: sound.map { .fixed(.init(source: "a", stream: $0.index)) } ?? .none,
                                      switches: [.init(at: .zero, angle: "a")])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        if let assembly { object["assembly"] = [["from": assembly.from.description, "to": assembly.to.description]] }
        let data = try JSONSerialization.data(withJSONObject: object)
        let file = scratch.appendingPathComponent("\(UUID().uuidString).cut")
        try data.write(to: file)
        return (file, try JSONDecoder().decode(MulticamProject.self, from: data))
    }

    private func outcome(_ resolution: MulticamResolution) -> Outcome {
        var result = Outcome()
        switch resolution {
        case .ready(let plan, _):
            result.mode = plan.mode.rawValue
            result.container = plan.container
        case .unavailable(let issue, let offers):
            result.code = issue.code
            result.message = issue.message
            result.alternatives = offers.map(\.alternative.id)
            result.labels = offers.map(\.alternative.label)
        }
        return result
    }

    private func outcome(_ issue: CutError?) -> Outcome {
        var result = Outcome()
        result.code = issue?.code ?? ""
        result.message = issue?.message ?? ""
        result.alternatives = (issue?.alternatives ?? []).map(\.id)
        result.labels = (issue?.alternatives ?? []).map(\.label)
        return result
    }

    private func projectFlags(_ choices: MulticamExportChoices, mode: ExportMode) -> [String] {
        ["--mode", mode.rawValue] + (choices.tracks == .all ? [] : ["--tracks", choices.tracks.rawValue])
            + (mode == .encode ? ["--video", choices.codec.rawValue, "--audio", choices.audio.rawValue] : [])
    }

    private func exportProject(_ file: URL, flags: [String], container: String) throws -> (outcome: Outcome, alternatives: [[String: Any]]) {
        try tool(["export", "project", "render", "--project", file.path, "--json", "--no-sidecar", "--dry-run"] + flags
                 + ["--output", scratch.appendingPathComponent("\(UUID().uuidString).\(container)").path])
    }

    /// For every entry point and every request of the matrix, the app's model path and the CLI give the table's answer.
    @MainActor
    func testEveryEntryPointGivesTheTablesAnswer() async throws {
        _ = NSApplication.shared
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let files: [ExportSourceKind: URL] = [.movie: try fixture("Shuttle-Chirp", "mov"), .audio: try fixture("Gapless-Crop", "mp3"),
                                               .multicam: try fixture("Shuttle-Chirp", "mov")]
        let program = try program(files[.multicam]!)
        var checked: [ExportEntryPoint: Int] = [:]
        for entry in ExportEntryPoint.allCases where entry != .replacement {
            for source in ExportSourceKind.allCases where (source == .multicam) == (entry.source == .multicam)
                && !(entry == .cliScenes && source == .audio) {
                let file = try XCTUnwrap(files[source])
                let media = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
                let clip = ClipRequest(file: file, from: .zero, to: media.duration)
                for tracks in ExportTracks.allCases {
                    for mode in [ExportMode.smart, .copy, .encode] {
                        let name = "\(entry.rawValue): \(source.rawValue) × \(tracks.rawValue) × \(mode.rawValue)"
                        let answer = entry.answer(source: source, tracks: tracks, mode: mode)
                        checked[entry, default: 0] += 1
                        // A whole source copies exactly, which is what `auto` does first for a sound-only encode.
                        let written = answer.resolvedMode == .encode && answer.defaultAudio == .auto && answer.audioActions.contains(.mp3)
                            ? ExportMode.copy : answer.resolvedMode
                        let copyContainer = source == .multicam ? "mov"
                            : CutEngine(useSidecar: false, tracks: answer.tracks).suggestedContainers(for: media, clips: [clip]).first ?? file.pathExtension
                        let container = answer.resolvedMode == .encode && !answer.audioActions.contains(.mp3)
                            ? (answer.containers?.first ?? copyContainer) : copyContainer

                        switch entry {
                        case .cliExport, .cliBulk, .cliRearrange, .cliSilence, .cliScenes:
                            let named = entry != .cliRearrange && entry != .cliScenes
                            // A command without a mode flag asks for the default. The table refuses the rest.
                            if !named, mode != ExportRules.defaultMode(for: .movie) {
                                XCTAssertNotNil(entry.refusal(of: mode), name)
                                continue
                            }
                            let flags = (named ? ["--mode", mode.rawValue] : []) + (tracks == .all ? [] : ["--tracks", tracks.rawValue])
                            let result = try run(entry, flags: flags, clip: clip, container: entry == .cliBulk || entry == .cliScenes ? nil : container).outcome
                            if let refusal = answer.refusal {
                                XCTAssertEqual(result.code, refusal.code, "\(name): \(result.message)")
                                // A mode the command has no flag value for is refused by its parser.
                                if entry.refusal(of: mode) == nil {
                                    XCTAssertTrue(result.message.hasSuffix(refusal.message), "\(name): \(result.message)")
                                }
                            } else {
                                XCTAssertEqual(result.code, "", "\(name): \(result.message)")
                                XCTAssertEqual(result.mode, written.rawValue, name)
                            }

                        case .sheet, .queue:
                            let choices = ExportQueueChoices(media: [media], audioCodec: media.streams.first { $0.kind == "audio" }?.codec)
                            let selected = entry == .queue ? choices.tracks(tracks) : (source == .audio ? .audio : tracks)
                            let selectable = entry.selectableModes(source: source, tracks: selected)
                            guard answer.isAllowed, answer.resolvedMode == mode, selected == answer.tracks else {
                                // The control lists only what the table writes as itself.
                                if selected == answer.tracks { XCTAssertFalse(selectable.contains(mode), name) }
                                continue
                            }
                            XCTAssertTrue(selectable.contains(mode), name)
                            var options = ExportSheetOptions()
                            options.tracks = selected
                            options.copyContainer = entry == .queue ? "" : copyContainer
                            if selected != .audio {
                                options.mode = mode
                            } else if mode == .encode {
                                options.convertAudio(to: try XCTUnwrap(choices.conversions.first))
                            }
                            let flags = ExportRules.arguments(for: options.request([clip]))
                            let app: Outcome
                            let counterpart: ExportEntryPoint = entry == .queue ? .cliBulk : .cliExport
                            if entry == .queue {
                                XCTAssertEqual(choices.modes(tracks: selected), selectable, name)
                                app = outcome(ExportQueueChoices.check([[clip]], media: [file: media], options: options))
                            } else {
                                let resolved = ExportAvailability.resolve(options, clips: [clip], media: [file: media], useSidecar: false)
                                var result = outcome(resolved.failure)
                                if case .ready(let plan) = resolved.availability {
                                    result.mode = plan.mode.rawValue
                                    result.container = plan.edit.container
                                }
                                app = result
                            }
                            let asked = options.container.isEmpty ? nil : options.container
                            var result = try run(counterpart, flags: flags, clip: clip, container: asked).outcome
                            XCTAssertEqual(app.code, "", "\(name): \(app.message)")
                            // The queue check reports only a failure, so compare what both report.
                            if entry == .queue { result.mode = ""; result.container = "" }
                            XCTAssertEqual(app, result, "\(name): the app and `mpcut \(flags.joined(separator: " "))` disagree.")

                        case .multicamSheet, .multicamQueue, .cliProject:
                            var choices = MulticamExportChoices(entry: entry == .cliProject ? .multicamSheet : entry)
                            choices.tracks = tracks
                            let result = try exportProject(program.file, flags: projectFlags(choices, mode: mode), container: choices.container).outcome
                            if let refusal = answer.refusal {
                                XCTAssertEqual([result.code, result.message], [refusal.code, refusal.message], name)
                                XCTAssertFalse(choices.modes.contains(mode), name)
                                continue
                            }
                            // A whole program copies, so its copying rows must be written, not merely allowed.
                            if mode != .encode { XCTAssertEqual(result.code, "", "\(name): \(result.message)") }
                            if result.code.isEmpty { XCTAssertEqual(result.mode, answer.resolvedMode.rawValue, name) }
                            guard entry != .cliProject else { continue }
                            XCTAssertTrue(choices.modes.contains(mode), name)
                            choices.mode = mode
                            XCTAssertEqual(choices.effectiveMode, answer.resolvedMode, name)
                            XCTAssertEqual(choices.containers(), ExportRules.multicamListedContainers(tracks: tracks, mode: mode), name)
                            XCTAssertEqual(choices.deliveryActions, answer.audioActions, name)
                            let app: Outcome = AnalysisSidecar.$readsEnabled.withValue(false) {
                                if entry == .multicamQueue {
                                    let range = MulticamQueuedRange(name: "Program", range: program.project.range, project: program.project, media: [:])
                                    var failure = outcome(MulticamBulkExport.check([range], choices: choices))
                                    failure.message = failure.message.replacingOccurrences(of: "Range 1: ", with: "")
                                    return failure
                                }
                                let output = scratch.appendingPathComponent("\(UUID().uuidString).\(choices.container)")
                                return outcome(MulticamEngine().resolution(program.project, output: output, mode: choices.effectiveMode,
                                                                           tracks: tracks, settings: choices.settings))
                            }
                            var tool = result
                            if entry == .multicamQueue { tool.mode = ""; tool.container = "" }
                            XCTAssertEqual(app, tool, "\(name): the app and `mpcut export project render --project` disagree.")
                        case .replacement:
                            continue
                        }
                    }
                }
            }
        }
        // Every entry point was asked every request of its source kinds.
        for entry in ExportEntryPoint.allCases where entry != .replacement {
            XCTAssertGreaterThanOrEqual(checked[entry] ?? 0, 9, entry.rawValue)
        }
        XCTAssertEqual(ExportEntryPoint.replacement.modes, [.copy])
    }

    /// An unavailable request offers the same ordered alternatives on every front end, and each one works when asked for.
    @MainActor
    func testUnavailableRequestsOfferTheSameAlternativesOnEveryFrontEnd() async throws {
        _ = NSApplication.shared
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")

        // PCM cannot be written into MP4. The sheet and the CLI refuse alike and offer the containers that carry it, then auto.
        let talkie = try fixture("Shuttle-Chirp", "mov")
        let talk = try CutEngine(useSidecar: false).inspect(talkie, keyframes: true)
        var pcm = ExportSheetOptions()
        pcm.mode = .encode
        pcm.audio = .pcm
        pcm.encodeContainer = "mp4"
        XCTAssertEqual(pcm.request([ClipRequest(file: talkie)]).audio, .pcm, "The sheet requests the audio action it shows.")
        try await assertParity("PCM into MP4", file: talkie, clips: [ClipRequest(file: talkie, from: .zero, to: talk.duration)],
                               options: pcm, expecting: ["reencode:mov", "reencode:mkv", "reencode"])
        let refused = ExportAvailability.resolve(pcm, clips: [ClipRequest(file: talkie, from: .zero, to: talk.duration)],
                                                 media: [talkie: talk], useSidecar: false)
        XCTAssertEqual(refused.failure?.code, "unsupported_audio")
        XCTAssertEqual(refused.failure?.message, ExportRules.reencodeRefusal(audio: .pcm, container: "mp4", source: .movie)?.message)

        // A copy cut inside a GOP: the sheet shows the whole list, and the queue offers what `bulk` reports.
        let movie = try fixture("SmartTrim-GOP", "mp4")
        let picture = try CutEngine(useSidecar: false).inspect(movie, keyframes: true)
        let cut = ClipRequest(file: movie, from: time(7, 25), to: picture.duration)
        for mode in [ExportMode.smart, .copy] {
            let denied = try run(.cliExport, flags: ["--mode", mode.rawValue], clip: cut, container: "webm")
            XCTAssertEqual(denied.outcome.code, "unsupported_container")
            XCTAssertFalse(denied.outcome.alternatives.contains { $0.hasPrefix("copy_other_container") })
            let trim = try XCTUnwrap(denied.alternatives.first { $0["id"] as? String == "smart_trim:mp4" })
            XCTAssertEqual(trim["lossless"] as? Bool, false)
            let replay = try run(.cliExport, flags: XCTUnwrap(trim["arguments"] as? [String]), clip: cut, container: "mp4")
            XCTAssertEqual([replay.outcome.code, replay.outcome.mode, replay.outcome.container], ["", "smart", "mp4"])
        }
        var copy = ExportSheetOptions()
        copy.mode = .copy
        copy.copyContainer = "mp4"
        let sheet = Sheet(copy, clips: [cut], media: picture)
        defer { sheet.control.stopChecking() }
        try await sheet.settle()
        XCTAssertGreaterThan(sheet.control.alternatives.count, 1)
        XCTAssertEqual(sheet.control.offeredTitles, sheet.control.alternatives.map(\.title),
                       "The sheet offers every alternative: the first as its button, the rest in the pull-down.")

        // People who run the CLI read the wording of the sheet, and each alternative under the label of its button.
        let human = Process()
        human.executableURL = cli
        human.arguments = ["export", "clips", "join", "--no-sidecar", "--dry-run", "--mode", "copy", "--output", scratch.appendingPathComponent("human.mp4").path,
                           "--clip", movie.path, "--from", "7/25"]
        let said = Pipe()
        human.standardError = said
        human.standardOutput = FileHandle.nullDevice
        try human.run()
        let text = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        human.waitUntilExit()
        let shown = try XCTUnwrap(sheet.control.failure)
        XCTAssertTrue(text.contains(ExportRules.describe(shown, clips: [ClipRequest(file: movie, from: time(7, 25), to: nil)])), text)
        for title in sheet.control.offeredTitles { XCTAssertTrue(text.contains(title), "\(title) is missing from: \(text)") }

        var queued = copy
        queued.copyContainer = ""
        let failure = try XCTUnwrap(ExportQueueChoices.check([[cut]], media: [movie: picture], options: queued))
        let offers = ExportQueueChoices.offers(for: failure)
        let bulk = try run(.cliBulk, flags: ExportRules.arguments(for: queued.request([cut])), clip: cut, container: nil)
        XCTAssertEqual([failure.code, failure.message], [bulk.outcome.code, bulk.outcome.message])
        XCTAssertEqual((failure.alternatives ?? []).map(\.id), bulk.outcome.alternatives)
        XCTAssertEqual(offers.first?.rung, .smartTrim)
        for (offer, listed) in zip(failure.alternatives ?? [], bulk.alternatives) {
            // Each alternative of a batch lists its clips, so `export` can be asked for it as reported.
            let clips = try XCTUnwrap(listed["clips"] as? [[String: String]]).flatMap {
                ["--clip", $0["file"] ?? "", "--from", $0["from"] ?? "", "--to", $0["to"] ?? ""]
            }
            let replay = try runCLI(listed["arguments"] as? [String] ?? [], clips: clips, container: offer.container).outcome
            XCTAssertEqual([replay.code, replay.mode, replay.container], ["", offer.mode.rawValue, offer.container], offer.id)
            if offer.rung != .copySampleAligned {
                XCTAssertNil(ExportQueueChoices.check([[cut]], media: [movie: picture], options: queued.applying(offer)), offer.id)
            }
        }

        // The same cut as a multicam range edge: the inspector, the queue and `export --project` offer the same list.
        let program = try program(movie, assembly: (time(7, 25), picture.duration))
        var choices = MulticamExportChoices(entry: .multicamSheet)
        choices.mode = .copy
        let tool = try exportProject(program.file, flags: projectFlags(choices, mode: .copy), container: choices.container)
        let app = AnalysisSidecar.$readsEnabled.withValue(false) {
            MulticamEngine().resolution(program.project, output: scratch.appendingPathComponent("\(UUID().uuidString).\(choices.container)"),
                                        mode: .copy, tracks: .all, settings: choices.settings)
        }
        XCTAssertEqual(outcome(app), tool.outcome)
        guard case .unavailable(_, let programOffers) = app, !programOffers.isEmpty else {
            return XCTFail("A copy cut inside a GOP is unavailable for a multicam program and offers alternatives. \(tool.outcome)")
        }
        XCTAssertTrue(programOffers.map(\.alternative.rung).contains(.smartTrim))
        // Every alternative has its own id, whatever container and audio action were asked for.
        for flags in [["--mode", "copy"], ["--mode", "encode", "--audio", "auto"], ["--mode", "encode", "--audio", "pcm"]] {
            for container in ["mkv", "mp4"] {
                let listed = try exportProject(program.file, flags: flags, container: container).outcome.alternatives
                XCTAssertEqual(Set(listed).count, listed.count, "\(flags) .\(container): \(listed)")
            }
        }
        XCTAssertEqual(programOffers.map(\.alternative.rung), programOffers.map(\.alternative.rung).sorted { $0.rank < $1.rank })
        let queue = AnalysisSidecar.$readsEnabled.withValue(false) {
            MulticamBulkExport.check([MulticamQueuedRange(name: "Program", range: MulticamRange(from: time(7, 25), to: picture.duration),
                                                          project: program.project, media: [:])], choices: choices)
        }
        XCTAssertEqual((queue?.alternatives ?? []).map(\.id), tool.outcome.alternatives)
        for (offer, listed) in zip(programOffers, tool.alternatives) {
            var applied = choices
            applied.apply(offer.alternative)
            XCTAssertEqual([applied.mode.rawValue, applied.container], [offer.mode.rawValue, offer.container])
            let replay = try exportProject(program.file, flags: listed["arguments"] as? [String] ?? [], container: offer.container).outcome
            XCTAssertEqual([replay.code, replay.mode], ["", offer.mode.rawValue], "\(offer.alternative.id): \(replay.message)")
        }
    }

    func testDestinationExtensionConstrainsExportPlannerWithoutExplicitContainer() throws {
        let movie = try fixture("SmartTrim-GOP", "mp4")
        let videoRequest = ExportRequest(clips: [.init(file: movie, from: time(7, 25))], mode: .smart)
        let planner = ExportPlanner(useSidecar: false)
        let rejected = scratch.appendingPathComponent("rejected.webm")
        guard case .unavailable(let issue, let trims) = planner.resolve(videoRequest, output: rejected) else {
            return XCTFail("WebM cannot carry this H.264 video.")
        }
        XCTAssertEqual(issue.code, "unsupported_container")
        XCTAssertTrue(trims.contains { $0.alternative.id == "smart_trim:mp4" })

        let audio = try fixture("Covered-Audio", "mp3")
        let audioRequest = ExportRequest(clips: [.init(file: audio)], mode: .encode)
        guard case .unavailable(let audioIssue, let remuxes) = planner.resolve(audioRequest, output: rejected) else {
            return XCTFail("Automatic audio export must not write another container to the requested WebM output.")
        }
        XCTAssertEqual(audioIssue.code, "unsupported_container")
        XCTAssertTrue(remuxes.contains { $0.alternative.rung == .copyOtherContainer && $0.alternative.mode == .copy })
        let wav = scratch.appendingPathComponent("sound.wav")
        guard case .ready(let plan, _, _) = planner.resolve(audioRequest, output: wav) else {
            return XCTFail("Automatic audio export should still convert to the named container if supported.")
        }
        XCTAssertEqual(plan.edit.container, "wav")

        var conflicting = audioRequest
        conflicting.container = "mp3"
        guard case .unavailable(let conflict, _) = planner.resolve(conflicting, output: wav) else {
            return XCTFail("A conflicting container request must not produce a plan for the wrong extension.")
        }
        XCTAssertEqual(conflict.code, "unsupported_container")
    }

    // MARK: Help

    /// `silence --project --output` resolves its retained ranges through the export rules, as `export --project`
    /// resolves the same ranges saved as an assembly: one refusal, one wording, and the alternatives it can request.
    func testProjectSilenceResolvesItsRangesLikeProjectExport() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let movie = try fixture("Pause-Quiet", "mov")
        let saved = try program(movie)
        let silence = ["silence", "plan", "--project", saved.file.path, "--json", "--no-sidecar", "--min-pause-seconds", "0.3", "--padding-per-side-seconds", "0.05"]
        for mode in ExportEntryPoint.cliSilence.modes {
            // The retained ranges of the report, saved as the assembly of a second project.
            let process = Process()
            process.executableURL = cli
            process.arguments = silence + ["--mode", mode.rawValue]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
            let clips = try XCTUnwrap(report["clips"] as? [[String: Any]])
            XCTAssertFalse(clips.isEmpty)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CutProject.documentJSON(saved: Data(contentsOf: saved.file))) as? [String: Any])
            object["assembly"] = try clips.map { clip -> [String: String] in
                let group = try XCTUnwrap(clip["group"] as? [String: Any])
                func text(_ key: String) throws -> String {
                    if let written = group[key] as? String { return written }
                    let time = try XCTUnwrap(group[key] as? [String: Any])
                    return "\(try XCTUnwrap(time["numerator"] as? Int))/\(try XCTUnwrap(time["denominator"] as? Int))"
                }
                return ["from": try text("from"), "to": try text("to")]
            }
            let assembled = scratch.appendingPathComponent("\(UUID().uuidString).cut")
            try JSONSerialization.data(withJSONObject: object).write(to: assembled)

            for container in ["mov", "mp4", "mkv", "webm"] {
                let output = scratch.appendingPathComponent("\(UUID().uuidString).\(container)").path
                // The pauses are planned for the container that is written, and the report above planned for the
                // default one. For the other containers nothing is removed, so the ranges are the saved program's.
                let ranged = container == ExportRules.multicamContainers[0]
                let command = ranged ? silence : ["silence", "plan", "--project", saved.file.path, "--json", "--no-sidecar", "--min-pause-seconds", "100"]
                let shortened = try tool(command + ["--mode", mode.rawValue, "--output", output, "--dry-run"])
                let exported = try exportProject(ranged ? assembled : saved.file, flags: ["--mode", mode.rawValue], container: container)
                if ranged { XCTAssertTrue(shortened.outcome.code.isEmpty, shortened.outcome.description) }
                let name = "\(mode.rawValue) .\(container)"
                XCTAssertEqual(shortened.outcome.code, exported.outcome.code, name)
                XCTAssertEqual(shortened.outcome.message, exported.outcome.message, name)
                // Silence lists the alternatives of the same ladder that it can request itself.
                let requestable = exported.alternatives.filter { offer in
                    ExportEntryPoint.cliSilence.modes.contains { $0.rawValue == offer["mode"] as? String }
                }
                XCTAssertEqual(shortened.outcome.alternatives, requestable.compactMap { $0["id"] as? String }, name)
                XCTAssertEqual(shortened.outcome.labels, requestable.compactMap { $0["label"] as? String }, name)
                if exported.outcome.code.isEmpty { XCTAssertTrue(shortened.outcome.code.isEmpty, name) }
            }
            // A mode this command does not write is refused in the table's words.
            let refused = try tool(silence + ["--mode", "encode", "--output", scratch.appendingPathComponent("refused.mov").path, "--dry-run"])
            XCTAssertEqual(refused.outcome.code, "invalid_arguments")
        }
        XCTAssertTrue(ExportEntryPoint.cliSilence.restrictions.contains { $0.hasPrefix("projectRanges") })
        XCTAssertFalse(ExportRules.markdown().contains("plans its retained ranges with the engine directly"))
    }

    /// "GUI and CLI behaviour should be identical": for each source kind, a request without a mode is written with
    /// the table's default by every CLI command, and that default is the app's factory setting.
    @MainActor
    func testDefaultModeIsTheTablesInTheCLIAndTheAppsFactorySettings() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let movie = try fixture("SmartTrim-GOP", "mp4"), sound = try fixture("Covered-Audio", "mp3")
        let suite = "mpcut.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let factory = EditorPreferences(defaults: defaults).defaultExportMode

        let process = Process()
        process.executableURL = cli
        process.arguments = ["help", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let help = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let listed = try XCTUnwrap(help["default_export_modes"] as? [String: String])

        for kind in ExportSourceKind.allCases {
            let table = ExportRules.defaultMode(for: kind, tracks: .all)
            XCTAssertEqual(table, ExportRules.cell(source: kind, tracks: .all, mode: ExportRules.defaultMode(for: kind)).resolvedMode)
            XCTAssertEqual(listed[kind.rawValue], table.rawValue, "help, \(kind.rawValue)")
            // The app: the sheet's options as a new installation opens them for this kind of source.
            let app: ExportMode
            let commands: [(name: String, mode: String)]
            switch kind {
            case .movie:
                var options = ExportSheetOptions()
                XCTAssertEqual(options.mode, factory)
                options.mode = ExportRules.openingMode(preferred: factory, tier: nil, source: .movie)
                app = options.effectiveMode
                let clip = ClipRequest(file: movie, from: time(1, 1), to: time(2, 1))
                let talkie = try fixture("Shuttle-Chirp", "mov")
                commands = try [ExportEntryPoint.cliExport, .cliBulk, .cliRearrange, .cliScenes].map {
                    ($0.rawValue, try run($0, flags: [], clip: clip, container: nil).outcome.mode)
                } + [(ExportEntryPoint.cliSilence.rawValue, try run(.cliSilence, flags: [], clip: ClipRequest(file: talkie), container: nil).outcome.mode),
                     ("export --order", try tool(["export", "clips", "join", "--json", "--no-sidecar", "--dry-run", "--order", "1", "--output",
                                                 scratch.appendingPathComponent("ordered.mp4").path, "--clip", movie.path]).outcome.mode)]
            case .audio:
                var options = ExportSheetOptions()
                options.mode = ExportRules.openingMode(preferred: factory, tier: nil, source: .audio)
                options.tracks = .audio
                app = options.effectiveMode
                let whole = ClipRequest(file: sound, from: .zero, to: try CutEngine(useSidecar: false).inspect(sound).duration)
                commands = try [ExportEntryPoint.cliExport, .cliBulk].map {
                    ($0.rawValue, try run($0, flags: [], clip: whole, container: nil).outcome.mode)
                }
            case .multicam:
                app = MulticamExportChoices(entry: .multicamSheet, preferred: factory).effectiveMode
                XCTAssertEqual(MulticamExportChoices(entry: .multicamSheet).effectiveMode, app)
                let project = try program(movie).file
                commands = [("export --project", try exportProject(project, flags: [], container: "mov").outcome.mode)]
            }
            XCTAssertEqual(app, table, "app, \(kind.rawValue)")
            for command in commands {
                XCTAssertEqual(command.mode, table.rawValue, "\(command.name), \(kind.rawValue)")
            }
        }
    }

    func testCommandHelpListsWhatTheRulesAllow() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "The mpcut binary is not built at \(cli.path).")
        let process = Process()
        process.executableURL = cli
        process.arguments = ["help", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let help = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(help["audio_options"] as? [String] ?? []),
                       Set((ExportRules.stillMovieAudioActions + ExportRules.soundAudioActions).map(\.rawValue)))
        XCTAssertEqual(help["export_modes"] as? [String], ExportMode.allCases.map(\.rawValue))
        XCTAssertEqual(help["export_tracks"] as? [String], ExportTracks.allCases.map(\.rawValue))
        XCTAssertEqual(help["export_ranges_separate_default_mode"] as? String, ExportRules.defaultMode(for: .movie).rawValue)
        XCTAssertEqual(help["default_multicam_export_mode"] as? String, ExportRules.defaultMode(for: .multicam).rawValue)
        // `export` has no default of its own: with or without --order it is the table's, like every other command.
        XCTAssertEqual(help["default_export_mode"] as? String, ExportRules.defaultMode(for: .movie).rawValue)
        XCTAssertEqual(help["default_ordered_export_mode"] as? String, ExportRules.defaultMode(for: .movie).rawValue)
        XCTAssertFalse(ExportRules.markdown().contains("defaultCopy"))
        XCTAssertFalse(ExportEntryPoint.allCases.contains { $0.restrictions.contains { $0.hasPrefix("defaultCopy") } })
        let commands = try XCTUnwrap(help["commands"] as? [String: Any])
        let exportHelp = try XCTUnwrap(commands["export clips join"] as? [String: Any])
        XCTAssertTrue((exportHelp["instructions"] as? [String] ?? []).joined(separator: " ").contains(ExportRules.modeHelp(.cliExport)))
        // Usage and instructions list the modes, tracks and multicam rules of the module.
        let usages: [(String, ExportEntryPoint)] = [("export clips join", .cliExport), ("export ranges separate", .cliBulk), ("silence export", .cliSilence), ("export project render", .cliProject)]
        for (name, entry) in usages {
            let command = try XCTUnwrap(commands[name] as? [String: Any])
            let usage = (command["usage"] as? [String] ?? []).joined(separator: " ")
            XCTAssertTrue(usage.contains(ExportRules.modeUsage(entry)), "\(name) usage does not list the modes of \(entry.rawValue).")
            XCTAssertTrue(usage.contains(ExportRules.tracksUsage), name)
        }
        let multicam = try XCTUnwrap(commands["multicam"] as? [String: Any])
        XCTAssertTrue((multicam["instructions"] as? [String] ?? []).joined(separator: " ").contains(ExportRules.multicamHelpSummary))
        for (name, entry) in [("scenes export", ExportEntryPoint.cliScenes), ("export ranges join", .cliRearrange), ("export ranges separate", .cliBulk), ("silence export", .cliSilence)] {
            let command = try XCTUnwrap(commands[name] as? [String: Any])
            XCTAssertTrue((command["instructions"] as? [String] ?? []).joined(separator: " ").contains(ExportRules.modeHelp(entry)), name)
        }
        for name in ["export clips join", "export ranges separate"] {
            let command = try XCTUnwrap(commands[name] as? [String: Any])
            let text = (command["instructions"] as? [String] ?? []).joined(separator: " ")
            XCTAssertTrue(text.contains(ExportRules.helpSummary), "\(name) help does not carry the rules summary.")
        }
    }
}
