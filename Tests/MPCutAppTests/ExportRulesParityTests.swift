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
            "\"Convert Audio\""
        ]
        // Front ends that are not migrated yet. Remove a file from this list when it asks ExportRules.
        let notMigrated: Set<String> = ["BulkQueueView.swift", "MulticamBulkQueue.swift", "MulticamEditorView.swift", "MCPOutputs.swift"]
        var offences: [String] = []
        for folder in ["Sources/MPCutApp", "Sources/MPCutCLI"] {
            let directory = Self.repository.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            where name.hasSuffix(".swift") && !notMigrated.contains(name) {
                let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
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

    /// Runs `mpcut export --dry-run --json` and reads the fields the sheet also knows.
    private func runCLI(_ flags: [String], clips: [String], container: String, helper: String? = nil) throws
        -> (outcome: Outcome, alternatives: [[String: Any]]) {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["export", "--json", "--no-sidecar", "--dry-run"] + flags
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
        let actions = report["audioActions"] as? [[String: Any]] ?? []
        outcome.actions = actions.compactMap { $0["action"] as? String }
        outcome.bitRate = actions.first?["bitRate"] as? Int
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
                               expecting: ["convertSameFormat", "convertPCM", "convertAAC"])
        let whole = try CutEngine(useSidecar: false).inspect(mp3, keyframes: true)
        try await assertParity("contiguous MP3", file: mp3, clips: [ClipRequest(file: mp3, from: .zero, to: whole.duration)],
                               options: soundOptions("mp3"), expecting: [])
        try await assertParity("MP3 join converting to PCM in a wrong extension", file: mp3, clips: cuts(mp3),
                               options: soundOptions("m4a", converting: .pcm))

        let flac = try converted("Tone.flac", to: .flac)
        try await assertParity("FLAC join inside frames", file: flac, clips: cuts(flac), options: soundOptions("flac"),
                               expecting: ["convertSameFormat", "convertPCM", "convertAAC"])
        let frames = CutEngine(useSidecar: false, tracks: .audio)
            .validBoundaries(in: try CutEngine(useSidecar: false).inspect(flac, keyframes: true), start: true)
        if frames.count > 4 {
            let aligned = [ClipRequest(file: flac, from: frames[1], to: frames[2]), ClipRequest(file: flac, from: frames[3], to: frames[4])]
            try await assertParity("FLAC join on frame boundaries", file: flac, clips: aligned, options: soundOptions("flac"),
                                   expecting: ["copyOtherContainer:mka", "convertSameFormat", "convertPCM", "convertAAC"])
        }

        let m4a = try converted("Tone.m4a", to: .aac)
        let between = [ClipRequest(file: m4a, from: time(100_001, 1_000_000), to: time(3, 10)),
                       ClipRequest(file: m4a, from: time(1, 2), to: time(700_001, 1_000_000))]
        try await assertParity("AAC in M4A cut between samples", file: m4a, clips: between, options: soundOptions("m4a"))
        let media = try CutEngine(useSidecar: false).inspect(m4a, keyframes: true)
        let first = ExportAvailability.resolve(soundOptions("m4a"), clips: between, media: [m4a: media], useSidecar: false).offers.first
        XCTAssertEqual(first?.alternative.id, "copySampleAligned", "An exact copy on the sample clock ranks before any conversion.")
        XCTAssertEqual(first?.alternative.lossless, true)

        let opus = try fixture("Standalone-Chirp", "opus")
        try await assertParity("Opus join", file: opus, clips: cuts(opus), options: soundOptions("opus"),
                               expecting: ["convertPCM", "convertAAC"])

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

    @MainActor
    func testMissingEncoderIsSkippedIdenticallyInBothFrontEnds() async throws {
        _ = NSApplication.shared
        // Stand in for an earlier helper: the same program, reporting no MP3 or FLAC encoder.
        let folder = scratch.appendingPathComponent("earlier helper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let old = folder.appendingPathComponent("ffmpeg")
        let script = "#!/bin/sh\ncase \" $* \" in\n  *\" -encoders \"*) \"\(Self.helper)\" \"$@\" | grep -v -e libmp3lame -e \" flac \"; exit 0 ;;\nesac\nexec \"\(Self.helper)\" \"$@\"\n"
        try script.write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
        let previous = ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"]
        setenv("MPCUT_FFMPEG_HELPER", old.path, 1)
        defer { if let previous { setenv("MPCUT_FFMPEG_HELPER", previous, 1) } else { unsetenv("MPCUT_FFMPEG_HELPER") } }
        let mp3 = try fixture("Gapless-Crop", "mp3")
        let clips = [ClipRequest(file: mp3, from: time(1, 10), to: time(3, 10)), ClipRequest(file: mp3, from: time(1, 2), to: time(7, 10))]
        try await assertParity("MP3 join without an MP3 encoder", file: mp3, clips: clips, options: soundOptions("mp3"),
                               expecting: ["convertPCM", "convertAAC"], helper: old.path)
        try await assertParity("MP3 conversion without an MP3 encoder", file: mp3, clips: clips,
                               options: soundOptions("mp3", converting: .mp3), helper: old.path)
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

    // MARK: Help

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
        XCTAssertEqual(Set(help["audioOptions"] as? [String] ?? []),
                       Set((ExportRules.movieAudioActions + ExportRules.soundAudioActions).map(\.rawValue)))
        XCTAssertEqual(help["exportModes"] as? [String], ExportMode.allCases.map(\.rawValue))
        XCTAssertEqual(help["exportTracks"] as? [String], ExportTracks.allCases.map(\.rawValue))
        XCTAssertEqual(help["defaultBulkMode"] as? String, ExportRules.defaultMode(for: .movie).rawValue)
        XCTAssertEqual(help["defaultMulticamExportMode"] as? String, ExportRules.defaultMode(for: .multicam).rawValue)
        let commands = try XCTUnwrap(help["commands"] as? [String: Any])
        for name in ["export", "bulk"] {
            let command = try XCTUnwrap(commands[name] as? [String: Any])
            let text = (command["instructions"] as? [String] ?? []).joined(separator: " ")
            XCTAssertTrue(text.contains(ExportRules.helpSummary), "\(name) help does not carry the rules summary.")
        }
    }
}
