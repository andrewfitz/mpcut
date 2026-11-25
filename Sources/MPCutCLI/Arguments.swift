import Foundation
import MPCutCore

struct CLIError: Error, Encodable {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

struct SourceSoundtrack: Equatable {
    let file: String
    let target: Int?
    let stream: Int?
}

struct InputClip: Decodable {
    var occurrenceID: String?  // Internal provenance when expanding a saved sequence.
    var rangesFile: String?
    var soundtrack: SourceSoundtrack?
    var file: String?
    var project: String?
    var from: String?
    var to: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case file, project = "project_path", from, to, rangesFile = "ranges_file",
             replaceAudio = "replace_audio", replaceTrack = "replace_track", replacementStream = "replacement_stream"
    }

    init(file: String) {
        self.file = file
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self, in: "Clip")
        file = try fields.decodeIfPresent(String.self, forKey: .file)
        project = try fields.decodeIfPresent(String.self, forKey: .project)
        rangesFile = try fields.decodeIfPresent(String.self, forKey: .rangesFile)
        guard file == nil || project == nil else {
            throw CLIError("invalid_json", "A clip must select either file or project_path.")
        }
        guard project == nil || rangesFile == nil else {
            throw CLIError("invalid_json", "A range list requires a file clip.")
        }
        let donor = try fields.decodeIfPresent(String.self, forKey: .replaceAudio)
        let target = try fields.decodeIfPresent(Int.self, forKey: .replaceTrack)
        let stream = try fields.decodeIfPresent(Int.self, forKey: .replacementStream)
        guard (target ?? 0) >= 0, (stream ?? 0) >= 0,
              donor != nil || (target == nil && stream == nil), project == nil || donor == nil else {
            throw CLIError("invalid_json", "Source replacement requires a file clip, replace_audio and nonnegative stream indices.")
        }
        soundtrack = donor.map { SourceSoundtrack(file: $0, target: target, stream: stream) }
        from = try fields.inputTime(.from, in: "Clip")
        to = try fields.inputTime(.to, in: "Clip")
    }
}

struct InputEdit: Decodable {
    var output: String
    var clips: [InputClip]
    var file: String?
    var project: String?
    var order: [Int]?
    var options = ExportOptions()

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case output, clips, file, project = "project_path", order, mode, video, quality, audio, audioOutput = "audio_output", snap, tracks, audioStream = "audio_stream", replaceAudio = "replace_audio", replaceTrack = "replace_track", replacementStream = "replacement_stream", requireCameraCopy = "require_camera_copy", spaceClips = "space_clips", stillTiming = "still_timing", container, planToken = "plan_token"
    }

    init(output: String, clips: [InputClip]) {
        self.output = output
        self.clips = clips
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self, in: "Export request")
        output = try fields.decode(String.self, forKey: .output)
        project = try fields.decodeIfPresent(String.self, forKey: .project)
        if project == nil {
            clips = try fields.decode([InputClip].self, forKey: .clips)
        } else {
            guard !fields.contains(.clips), !fields.contains(.file), !fields.contains(.order) else {
                throw CLIError("invalid_json", "A saved project export takes project_path and output. Clip selection and ordering belong to export clips join.")
            }
            clips = []
        }
        options.planToken = try fields.decodeIfPresent(String.self, forKey: .planToken)
        options.container = try fields.decodeIfPresent(String.self, forKey: .container)
        if let value = try fields.decodeIfPresent(String.self, forKey: .stillTiming) {
            try options.set("still-timing", to: value, code: "invalid_json")
        }
        options.requireCameraCopy = try fields.decodeIfPresent(Bool.self, forKey: .requireCameraCopy)
        if let value = try fields.inputTime(.spaceClips, in: "Export request") {
            try options.set("space-clips", to: value, code: "invalid_json")
        }
        file = try fields.decodeIfPresent(String.self, forKey: .file)
        order = try fields.decodeIfPresent([Int].self, forKey: .order)
        for key in [CodingKeys.mode, .video, .quality, .audio, .snap, .tracks] {
            if let value = try fields.decodeIfPresent(String.self, forKey: key) {
                try options.set(key.rawValue, to: value, code: "invalid_json")
            }
        }
        if let value = try fields.decodeIfPresent(String.self, forKey: .audioOutput) {
            try options.set("audio-output", to: value, code: "invalid_json")
        }
        options.audioStream = try fields.decodeIfPresent(Int.self, forKey: .audioStream)
        options.replaceAudio = try fields.decodeIfPresent(String.self, forKey: .replaceAudio)
        options.replaceTrack = try fields.decodeIfPresent(Int.self, forKey: .replaceTrack)
        options.replacementStream = try fields.decodeIfPresent(Int.self, forKey: .replacementStream)
    }

    func resolvedOrder(_ argument: [Int]?) throws -> [Int]? {
        if let argument, let order, argument != order {
            throw CLIError("invalid_arguments", "--order conflicts with the JSON order field.")
        }
        guard let requested = argument ?? order else { return nil }
        guard !requested.isEmpty else {
            throw CLIError("invalid_order", "Order must select at least one clip.")
        }
        if let invalid = requested.first(where: { $0 < 1 || $0 > clips.count }) {
            throw CLIError("invalid_order", "Clip number \(invalid) is outside the input clip list of \(clips.count). Numbering starts at 1.")
        }
        return requested
    }
}

enum ClipSpacing: Equatable, Encodable {
    case source
    case duration(RationalTime)
}

struct ExportOptions: Encodable {
    var mode: ExportMode?
    var video: ReencodeCodec?
    var quality: ReencodeQuality?
    var audio: ReencodeAudio?
    var audioOutput: MulticamAudioOutput?
    var snap: SnapMode?
    var tracks: ExportTracks?
    var audioStream: Int?
    var replaceAudio: String?
    var replaceTrack: Int?
    var replacementStream: Int?
    var subfolder: String?
    var baseName: String?
    var requireCameraCopy: Bool?
    var spaceClips: ClipSpacing?
    var stillTiming: StillPictureTiming?
    var container: String?
    var planToken: String?

    var organization: ExportOrganization { .init(subfolder: subfolder ?? "", baseName: baseName ?? "") }

    mutating func set(_ key: String, to value: String, code: String = "invalid_arguments") throws {
        func checked<T: RawRepresentable & CaseIterable>(_ type: T.Type) throws -> T where T.RawValue == String {
            guard let parsed = T(rawValue: value) else {
                let choices = T.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError(code, "\(key) accepts \(choices).")
            }
            return parsed
        }
        switch key {
        case "tracks": tracks = try checked(ExportTracks.self)
        case "replace-audio": replaceAudio = value
        case "replace-track", "replacement-stream", "audio-stream":
            guard let index = Int(value), index >= 0 else { throw CLIError(code, "\(key) requires a nonnegative stream index.") }
            if key == "replace-track" { replaceTrack = index }
            else if key == "audio-stream" { audioStream = index }
            else { replacementStream = index }
        case "mode": mode = try checked(ExportMode.self)
        case "video": video = try checked(ReencodeCodec.self)
        case "quality": quality = try checked(ReencodeQuality.self)
        case "snap": snap = try checked(SnapMode.self)
        case "audio": audio = try checked(ReencodeAudio.self)
        case "audio-output": audioOutput = try checked(MulticamAudioOutput.self)
        case "still-timing": stillTiming = try checked(StillPictureTiming.self)
        case "container": container = value
        case "space-clips":
            if value == "source" {
                spaceClips = .source
            } else {
                guard let duration = try? RationalTime(parsing: value), duration >= .zero else {
                    throw CLIError(code, "--space-clips requires source or a nonnegative duration.")
                }
                spaceClips = .duration(duration)
            }
        default: preconditionFailure("Unknown export setting")
        }
    }

    func checkTrackSelection() throws {
        if let audioStream, audioStream < 0 || tracks != .audio {
            throw CLIError("invalid_arguments", "--audio-stream requires --tracks audio and a nonnegative absolute stream index.")
        }
        if replaceTrack != nil || replacementStream != nil {
            guard replaceAudio != nil, (replaceTrack ?? 0) >= 0, (replacementStream ?? 0) >= 0 else {
                throw CLIError("invalid_arguments", "Replacement stream indices require --replace-audio and nonnegative values.")
            }
        }
    }

    func merging(_ request: ExportOptions) throws -> ExportOptions {
        func resolve<T: Equatable>(_ name: String, _ flag: T?, _ field: T?, jsonKey: String? = nil) throws -> T? {
            if let flag, let field, flag != field {
                throw CLIError("invalid_arguments", "--\(name) conflicts with the JSON \(jsonKey ?? name) field.")
            }
            return flag ?? field
        }
        return try ExportOptions(
            mode: resolve("mode", mode, request.mode),
            video: resolve("video", video, request.video),
            quality: resolve("quality", quality, request.quality),
            audio: resolve("audio", audio, request.audio),
            audioOutput: resolve("audio-output", audioOutput, request.audioOutput, jsonKey: "audio_output"),
            snap: resolve("snap", snap, request.snap),
            tracks: resolve("tracks", tracks, request.tracks),
            audioStream: resolve("audio-stream", audioStream, request.audioStream, jsonKey: "audio_stream"),
            replaceAudio: resolve("replace-audio", replaceAudio, request.replaceAudio, jsonKey: "replace_audio"),
            replaceTrack: resolve("replace-track", replaceTrack, request.replaceTrack, jsonKey: "replace_track"),
            replacementStream: resolve("replacement-stream", replacementStream, request.replacementStream, jsonKey: "replacement_stream"),
            subfolder: resolve("subfolder", subfolder, request.subfolder),
            baseName: resolve("base-name", baseName, request.baseName, jsonKey: "base_name"),
            requireCameraCopy: resolve("require-camera-copy", requireCameraCopy, request.requireCameraCopy, jsonKey: "require_camera_copy"),
            spaceClips: resolve("space-clips", spaceClips, request.spaceClips, jsonKey: "space_clips"),
            stillTiming: resolve("still-timing", stillTiming, request.stillTiming, jsonKey: "still_timing"),
            container: resolve("container", container, request.container),
            planToken: resolve("plan-token", planToken, request.planToken, jsonKey: "plan_token")
        )
    }
}

extension Decoder {
    /// `label` names the enclosing object. Inside an array it gains the one-based item number.
    func requestFields<Key: CodingKey & CaseIterable>(_ type: Key.Type, in label: String) throws -> KeyedDecodingContainer<Key> {
        let fields = try container(keyedBy: AnyRequestKey.self)
        let allowed = Set(Key.allCases.map(\.stringValue))
        let unknown = fields.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        if let first = unknown.first {
            let location = codingPath.last(where: { $0.intValue != nil })?.intValue.map { "\(label) \($0 + 1)" } ?? label
            throw CLIError("invalid_json", "\(location) has an unknown field '\(first)'.")
        }
        return try container(keyedBy: type)
    }
}

private struct AnyRequestKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum CLICommand {
    case sidecar(SidecarOptions)
    case sidecarCache(SidecarCacheOptions)
    case manual
    case help(CommandHelp?)
    case version
    case waveform(WaveformOptions)
    case frames(FrameExportOptions)
    case authorProject(creating: Bool)
    case timelineReview(TimelineReviewOptions)
    case multicamSwitchCoverage
    case still(StillOptions)
    case transcript(TranscriptCLI)
    case participants(ParticipantCLI)
    case tiles(TilesCLI)
    case stillCreate(StillCreateOptions)
    case projectAnalysisEdit(ProjectAnalysisEdit)
    case silence(SilenceOptions)
    case scenes(SceneScanOptions)
    case sceneExport(file: String?, options: SceneExportOptions)
    case refresh(RefreshOptions)
    case projectMedia(ProjectMediaOptions)
    case projectOutput(ProjectOutputOptions)
    case inspect(file: String, keyframes: Bool, allFrames: Bool, audioPackets: Bool, packetStream: Int?, from: RationalTime?, to: RationalTime?, tracks: ExportTracks, audioStream: Int?)
    case convert(input: String, output: String, allowLoss: Bool, flattenMulticam: Bool)
    case printDocument(String)
    case mergeProject(base: String, ours: String, theirs: String)
    case resolve(project: String, output: String, open: Bool)
    case inspectProject(String)
    case multicamSync(MulticamSyncOptions)
    case exportProject(project: String, output: String, dryRun: Bool, options: ExportOptions)
    case bulk(dryRun: Bool, options: ExportOptions, list: BulkList?)
    case export(input: InputEdit?, dryRun: Bool, options: ExportOptions, order: [Int]?, resolveOpen: Bool? = nil)
}

enum SceneGrouping: String, CaseIterable {
    case scene, view
}

struct SceneExportOptions {
    var organization = ExportOrganization()
    var list: String? = nil
    let directory: String
    let grouping: SceneGrouping
    let container: String?
    let dryRun: Bool
    let tracks: ExportTracks
    let audioStream: Int?
}

struct BulkList {
    let source: String
    let ranges: String
    let directory: String
    let container: String?
}

struct Arguments {
    static let version = MPCutRelease.version
    let command: CLICommand
    let json: Bool
    private(set) var useSidecar = true
    private(set) var requestFile: String?

    func replacingCommand(_ replacement: CLICommand) -> Arguments {
        Arguments(command: replacement, json: json, useSidecar: useSidecar)
    }

    private(set) var operation: String?

    static func parse(_ tokens: [String]) throws -> Arguments {
        let end = tokens.firstIndex(of: "--") ?? tokens.endIndex
        let prefix = tokens[..<end]
        let json = prefix.contains("--json")
        let sidecar = !prefix.contains("--no-sidecar")
        for flag in ["--json", "--no-sidecar"] where prefix.filter({ $0 == flag }).count > 1 {
            throw CLIError("invalid_arguments", "Duplicate " + flag)
        }
        let words = Array(prefix.filter { !["--json", "--no-sidecar"].contains($0) }) + Array(tokens[end...])
        if words == ["--help"] { return Arguments(command: .help(nil), json: json) }
        if words.first == "help" {
            let topic = words == ["help", "--help"] ? "help" : words.dropFirst().joined(separator: " ")
            if topic == "manual" { return Arguments(command: .manual, json: json) }
            return Arguments(command: .help(try topic.isEmpty ? nil : CommandHelp.topic(topic)), json: json)
        }
        if words == ["--version"] { return Arguments(command: .version, json: json) }
        if words.last == "--help", !words.contains("--") {
            return Arguments(command: .help(try CommandHelp.topic(words.dropLast().joined(separator: " "))), json: json)
        }
        guard let operation = CommandPath.match(words) else {
            throw CLIError("invalid_arguments", "Unknown command. Use mpcut help to list command paths.")
        }
        var options = Array(words.dropFirst(operation.split(separator: " ").count))
        let flags = options.prefix { $0 != "--" }
        var requestFile: String?
        if !operation.hasPrefix("transcript "), CommandPath.participants[operation] == nil, CommandPath.tiles[operation] == nil, let index = flags.firstIndex(of: "--input") {
            guard index + 1 < flags.endIndex, !options[index + 1].hasPrefix("--"),
                  flags.filter({ $0 == "--input" }).count == 1, !flags.contains("--stdin"),
                  ["project create", "project edit", "multicam switch coverage", "export clips join", "export project render", "export soundtrack replace", "export ranges separate",
                   "project resolve import", "project resolve export", "silence plan", "silence export", "scenes export"].contains(operation) else {
                throw CLIError("invalid_arguments", "Supply one JSON request with --input FILE on a command that accepts --stdin.")
            }
            requestFile = options[index + 1]
            options.replaceSubrange(index...index + 1, with: ["--stdin"])
        }
        // A participants or Tiles command reads a JSON request alone. Say so, instead of calling --stdin an unknown option.
        if CommandPath.participants[operation] != nil || CommandPath.tiles[operation] != nil,
           flags.contains("--stdin") && options != ["--stdin"] || flags.contains("--input") && options.count != 2 {
            throw CLIError("invalid_arguments", "Put the other options inside the JSON request when supplying --stdin or --input FILE.")
        }
        if json || requestFile != nil && operation.hasPrefix("export ") { options.insert("--json", at: 0) }
        let parsed = try parseCommand(operation, options: options, json: json || requestFile != nil)
        if !sidecar, case let .sidecar(settings) = parsed.command, settings.statusOnly {
            throw CLIError("invalid_arguments", "Inspecting a sidecar requires sidecar access.")
        }
        if !sidecar, case let .sidecarCache(cache) = parsed.command, cache.operation == .preview || cache.operation == .clear {
            throw CLIError("invalid_arguments", "Previewing or clearing caches requires sidecar access.")
        }
        return Arguments(command: parsed.command, json: json, useSidecar: sidecar,
                         requestFile: requestFile, operation: operation)
    }

    private static func parseCommand(_ path: String, options: [String], json: Bool) throws -> Arguments {
        if let operation = CommandPath.sidecarCache[path] {
            return Arguments(command: .sidecarCache(try SidecarCacheOptions(operation, arguments: options)), json: json)
        }
        if path.hasPrefix("project output "), let operation = ProjectOutputOptions.Operation(rawValue: String(path.dropFirst("project output ".count))) {
            return Arguments(command: .projectOutput(try ProjectOutputOptions(operation, arguments: options)), json: json)
        }
        if path.hasPrefix("project media "), let operation = ProjectMediaOptions.Operation(rawValue: String(path.dropFirst("project media ".count))) {
            return Arguments(command: .projectMedia(try ProjectMediaOptions(operation, arguments: options)), json: json)
        }
        if let operation = CommandPath.tiles[path] {
            return Arguments(command: .tiles(try TilesCLI(operation: operation, arguments: options)), json: json)
        }
        if let operation = CommandPath.participants[path] {
            return Arguments(command: .participants(try ParticipantCLI(operation: operation, arguments: options)), json: json)
        }
        if let operation = CommandPath.transcript[path] {
            return Arguments(command: .transcript(try TranscriptCLI([operation.rawValue] + options)), json: json)
        }
        if let operation = CommandPath.stills[path] {
            return Arguments(command: .still(try StillOptions(operation: operation, arguments: options,
                                                              gap: path == "timeline gap insert",
                                                              replace: path == "still picture replace")), json: json)
        }
        switch path {
        case "timeline range map", "history compare", "history restore-copy":
            return Arguments(command: .timelineReview(try TimelineReviewOptions(path: path, arguments: options)), json: json)
        case "multicam sync suggest":
            return Arguments(command: .multicamSync(try MulticamSyncOptions(options)), json: json)
        case "multicam switch coverage":
            guard options.filter({ $0 != "--json" }) == ["--stdin"] else { throw CLIError("invalid_arguments", "Supply --input FILE or --stdin.") }
            return Arguments(command: .multicamSwitchCoverage, json: json)
        case "project create", "project edit":
            guard options.filter({ $0 != "--json" }) == ["--stdin"] else { throw CLIError("invalid_arguments", "Supply --input FILE or --stdin.") }
            return Arguments(command: .authorProject(creating: path == "project create"), json: json)
        case "project convert":
            return Arguments(command: try convert(options), json: json)
        case "project document print":
            let operands = options.filter { $0 != "--json" }
            guard operands.count == 1, !operands[0].hasPrefix("--") else {
                throw CLIError("invalid_arguments", "Use project document print FILE, or - to read the project from standard input.")
            }
            return Arguments(command: .printDocument(operands[0]), json: json)
        case "project merge":
            guard options.count == 3, !json, !options.contains(where: { $0.hasPrefix("--") }) else {
                throw CLIError("invalid_arguments", "Use project merge BASE OURS THEIRS. The merged project replaces OURS.")
            }
            return Arguments(command: .mergeProject(base: options[0], ours: options[1], theirs: options[2]), json: false)
        case "project resolve export", "project resolve import":
            let importing = path == "project resolve import"
            if options.contains("--clips") {
                let command = try export(options, json: json, forResolve: true, openResolve: importing)
                guard case .export(.some, false, _, _, .some) = command else {
                    throw CLIError("invalid_arguments", "Use project resolve export --clips LIST --output FILE.fcpxml.")
                }
                return Arguments(command: command, json: json)
            }
            if options.contains("--stdin") {
                guard Set(options).isSubset(of: ["--stdin", "--json"]), Set(options).count == options.count else {
                    throw CLIError("invalid_arguments", "Supply an edit request with --stdin [--json].")
                }
                return Arguments(command: .export(input: nil, dryRun: false, options: ExportOptions(), order: nil,
                                                  resolveOpen: importing), json: json)
            }
            var values: [String: String] = [:]
            var flags = Set<String>()
            var iterator = options.makeIterator()
            while let option = iterator.next() {
                guard flags.insert(option).inserted else { throw CLIError("invalid_arguments", "Duplicate " + option) }
                if option == "--json" { continue }
                guard ["--project", "--output"].contains(option), let value = iterator.next(),
                      !value.isEmpty, !value.hasPrefix("--") else {
                    throw CLIError("invalid_arguments", "Expected --project PROJECT --output FILE.fcpxml.")
                }
                values[option] = value
            }
            guard let project = values["--project"], let output = values["--output"] else {
                throw CLIError("invalid_arguments", "Specify both --project and --output.")
            }
            return Arguments(command: .resolve(project: project, output: output, open: importing), json: json)
        case "analysis sidecar inspect", "analysis sidecar build":
            return Arguments(command: .sidecar(try SidecarOptions(options, statusOnly: path == "analysis sidecar inspect")), json: json)
        case "still project create":
            return Arguments(command: .stillCreate(try StillCreateOptions(options.filter { $0 != "--json" })), json: json)
        case "silence pause protect", "silence room-tone calibrate", "scenes view rename":
            return Arguments(command: .projectAnalysisEdit(try ProjectAnalysisEdit(path: path, arguments: options)), json: json)
        case "silence scan", "silence plan", "silence export", "silence shorten":
            var settings = try SilenceOptions(options)
            guard (path == "silence shorten") == (settings.outProject != nil),
                  settings.outProject == nil || (settings.project != nil && settings.output == nil && !settings.dryRun),
                  (settings.protectedPauses.isEmpty && settings.retainedPauseSeconds.isEmpty && settings.takeBoundaries.isEmpty) || settings.project != nil else {
                throw CLIError("invalid_arguments", "Use silence shorten --project FILE --out-project NEW.cut. Pause IDs and take boundaries require a project.")
            }
            if !settings.takeBoundaries.isEmpty && (settings.output != nil || settings.outProject != nil) {
                throw CLIError("invalid_arguments", "--take-boundary edits the take candidates in a project scan or plan report.")
            }
            switch path {
            case "silence scan" where settings.stdin || settings.pausesFile != nil || settings.output != nil:
                throw CLIError("invalid_arguments", "Use silence scan with fresh media. Choose silence plan for saved reports or an export preview.")
            case "silence export" where settings.dryRun || settings.output == nil:
                throw CLIError("invalid_arguments", "Silence export requires an output. Use silence plan to preview the result.")
            case "silence plan": settings.dryRun = settings.output != nil
            default: break
            }
            return Arguments(command: .silence(settings), json: json)
        case "scenes scan":
            return Arguments(command: .scenes(try SceneScanOptions(options)), json: json)
        case "scenes export":
            return Arguments(command: try scenes(options), json: json)
        case "project media refresh":
            return Arguments(command: .refresh(try RefreshOptions(options)), json: json)
        case "waveform envelope read":
            return Arguments(command: .waveform(try WaveformOptions(options)), json: json)
        case "review frames export":
            return Arguments(command: .frames(try FrameExportOptions(options)), json: json)
        case "media inspect", "project inspect":
            let command = try inspect(options)
            if case .inspectProject = command {
                guard path == "project inspect" else { throw CLIError("invalid_arguments", "Use project inspect for a project.") }
            } else if path == "project inspect" {
                throw CLIError("invalid_arguments", "Specify --project FILE.")
            }
            return Arguments(command: command, json: json)
        case "export ranges separate":
            if !options.prefix(while: { $0 != "--" }).contains("--stdin") { return Arguments(command: try bulkList(options), json: json) }
            guard case let .export(nil, dryRun, flags, order, nil) = try export(options, json: json, forBulk: true) else {
                throw CLIError("invalid_arguments", "Export ranges separate requires --json with --stdin.")
            }
            guard flags.replaceAudio == nil, flags.replaceTrack == nil, flags.replacementStream == nil else {
                throw CLIError("invalid_arguments", "Use export soundtrack replace to replace source audio.")
            }
            guard order == nil else {
                throw CLIError("invalid_arguments", "Use --order with export clips join.")
            }
            return Arguments(command: .bulk(dryRun: dryRun, options: flags, list: nil), json: true)
        case "export project render", "export clips join", "export soundtrack replace":
            let command = try export(options, json: json, forProject: path == "export project render")
            if case .exportProject = command, path != "export project render" {
                throw CLIError("invalid_arguments", "Use export project render with --project.")
            }
            return Arguments(command: command, json: json)
        case "export ranges join":
            return Arguments(command: try rearrange(options), json: json)
        default:
            throw CLIError("invalid_arguments", "Unknown command '\(path)'.")
        }
    }

    static func requestsJSON(_ tokens: [String]) -> Bool {
        tokens.prefix(while: { $0 != "--" }).contains("--json")
    }

    private static func convert(_ options: [String]) throws -> CLICommand {
        var input: String?
        var output: String?
        var format: String?
        var seen = Set<String>()
        var positionalOnly = false
        var iterator = options.makeIterator()
        while let token = iterator.next() {
            if !positionalOnly && token == "--" {
                positionalOnly = true
                continue
            }
            if !positionalOnly && token.hasPrefix("-") {
                guard seen.insert(token).inserted else {
                    throw CLIError("invalid_arguments", "Duplicate " + token)
                }
                switch token {
                case "--json", "--allow-loss", "--flatten-multicam": continue
                case "--output", "--to":
                    guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                        throw CLIError("invalid_arguments", token + " requires a value.")
                    }
                    if token == "--to" { format = value } else { output = value }
                default: throw CLIError("invalid_arguments", "Unknown convert option '" + token + "'.")
                }
            } else {
                guard input == nil, !token.isEmpty else {
                    throw CLIError("invalid_arguments", "Convert accepts one source project.")
                }
                input = token
            }
        }
        guard let input, let output else {
            throw CLIError("invalid_arguments", "Use project convert INPUT [--to FORMAT] --output FILE [--allow-loss].")
        }
        let destination = URL(fileURLWithPath: output)
        if let format, !ProjectConverter.accepts(format: format, for: destination) {
            throw CLIError("invalid_arguments", "Output extension does not match --to " + format + ". Choose cut, resolve, premiere, or fcp.")
        }
        let allowLoss = seen.contains("--allow-loss")
        let flattenMulticam = seen.contains("--flatten-multicam")
        if flattenMulticam {
            guard allowLoss, ProjectConverter.accepts(format: "premiere", for: destination) else {
                throw CLIError("invalid_arguments", "--flatten-multicam requires --allow-loss and a Premiere Pro .prproj output.")
            }
        }
        return .convert(input: input, output: output, allowLoss: allowLoss, flattenMulticam: flattenMulticam)
    }

    private static func bulkList(_ options: [String]) throws -> CLICommand {
        var source: String?, ranges: String?, directory: String?, container: String?
        var flags: [String] = ["--stdin"]
        var iterator = options.makeIterator()
        while let option = iterator.next() {
            func value() throws -> String {
                guard let next = iterator.next(), !next.isEmpty, !next.hasPrefix("--") else {
                    throw CLIError("invalid_arguments", "Missing value for \(option).")
                }
                return next
            }
            switch option {
            case "--ranges" where ranges == nil: ranges = try value()
            case "--output":
                guard directory == nil else { throw CLIError("invalid_arguments", "Duplicate output directory.") }
                directory = try value()
            case "--container" where container == nil: container = try value()
            case "--json", "--dry-run": flags.append(option)
            case "--mode", "--tracks", "--audio-stream", "--snap", "--audio", "--video", "--quality", "--subfolder", "--base-name":
                flags += [option, try value()]
            case "--":
                let remaining = Array(iterator)
                guard source == nil, remaining.count == 1 else { throw CLIError("invalid_arguments", "Expected one source after --.") }
                source = remaining[0]
                iterator = [].makeIterator()
            default:
                guard !option.hasPrefix("-"), source == nil else { throw CLIError("invalid_arguments", "Unexpected export ranges separate argument '\(option)'.") }
                source = option
            }
        }
        guard let source, let ranges, let directory,
              case let .export(nil, dryRun, settings, nil, nil) = try export(flags, json: true, forBulk: true) else {
            throw CLIError("invalid_arguments", "Use export ranges separate SOURCE --ranges LIST --output DIRECTORY, or supply a complete range export request.")
        }
        return .bulk(dryRun: dryRun, options: settings, list: BulkList(source: source, ranges: ranges, directory: directory, container: container))
    }

    private static func rearrange(_ options: [String]) throws -> CLICommand {
        var positional: [String] = []
        var positionalOnly = false
        var output: String?
        var list: String?
        var dryRun = false
        var seen: Set<String> = []
        var settings = ExportOptions(mode: ExportRules.defaultMode(for: ExportEntryPoint.cliRearrange.source))
        var iterator = options.makeIterator()
        while let argument = iterator.next() {
            if !positionalOnly {
                switch argument {
                case "--": positionalOnly = true; continue
                case "--json": continue
                case "--dry-run": dryRun = true; continue
                case "--output", "--ranges", "--snap", "--tracks", "--audio-stream":
                    guard seen.insert(argument).inserted, !(argument == "--tracks" && settings.tracks != nil) else {
                        throw CLIError("invalid_arguments", "\(argument) may be specified only once.")
                    }
                    guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                        throw CLIError("invalid_arguments", "Missing value for \(argument).")
                    }
                    if argument == "--output" { output = value }
                    else if argument == "--ranges" { list = value }
                    else { try settings.set(String(argument.dropFirst(2)), to: value) }
                    continue
                default:
                    if argument.hasPrefix("-") {
                        throw CLIError("invalid_arguments", "Unknown export ranges join option '\(argument)'.")
                    }
                }
            }
            positional.append(argument)
        }
        if let list, let output, positional.count == 1 {
            var clip = InputClip(file: positional[0])
            clip.rangesFile = list
            settings.snap = settings.snap ?? .nearest
            return .export(input: InputEdit(output: output, clips: [clip]), dryRun: dryRun, options: settings, order: nil)
        }
        guard list == nil, let output, positional.count == 2 else {
            throw CLIError("invalid_arguments", "Use export ranges join INPUT --output OUTPUT '23:01-26:12,03:02-4:03'.")
        }
        let clips = try positional[1].split(separator: ",", omittingEmptySubsequences: false).enumerated().map { offset, range in
            let bounds = range.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "–" }
            guard bounds.count == 2,
                  let start = try? RationalTime(parsing: bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let end = try? RationalTime(parsing: bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  start >= .zero, end > start else {
                throw CLIError("invalid_range", "Range \(offset + 1) requires a nonnegative start and a later end, for example 3:02-4:03.")
            }
            var clip = InputClip(file: positional[0])
            clip.from = start.description
            clip.to = end.description
            return clip
        }
        settings.snap = settings.snap ?? .nearest
        return .export(input: InputEdit(output: output, clips: clips), dryRun: dryRun, options: settings, order: nil)
    }

    private static func scenes(_ options: [String]) throws -> CLICommand {
        var file: String?
        var values: [String: String] = [:]
        var stdin = false
        var dryRun = false
        var positional = false
        var iterator = options.makeIterator()
        while let option = iterator.next() {
            if !positional {
                switch option {
                case "--": positional = true; continue
                case "--json": continue
                case "--stdin": stdin = true; continue
                case "--dry-run": dryRun = true; continue
                case "--export-to", "--scenes-file", "--group-by", "--subfolder", "--base-name", "--container", "--tracks", "--audio-stream":
                    guard values[option] == nil else {
                        throw CLIError("invalid_arguments", "\(option) may be specified only once.")
                    }
                    guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                        throw CLIError("invalid_arguments", "Missing value for \(option).")
                    }
                    values[option] = value
                    continue
                default:
                    if option.hasPrefix("-") {
                        throw CLIError("invalid_arguments", "Unknown scenes option '\(option)'.")
                    }
                }
            }
            guard file == nil else { throw CLIError("invalid_arguments", "Scenes accepts one input file.") }
            file = option
        }
        guard stdin == (file == nil) else {
            throw CLIError("invalid_arguments", "Supply either one input file or --stdin with a scene report.")
        }
        guard let directory = values["--export-to"] else {
            throw CLIError("invalid_arguments", "Scene export options require --export-to.")
        }
        guard let grouping = SceneGrouping(rawValue: values["--group-by"] ?? "scene") else {
            throw CLIError("invalid_arguments", "--group-by requires scene or view.")
        }
        var settings = ExportOptions()
        if let tracks = values["--tracks"] { try settings.set("tracks", to: tracks) }
        if let stream = values["--audio-stream"] { try settings.set("audio-stream", to: stream) }
        try settings.checkTrackSelection()
        let organization = ExportOrganization(subfolder: values["--subfolder"] ?? "", baseName: values["--base-name"] ?? "")
        return .sceneExport(file: file, options: SceneExportOptions(organization: organization, list: values["--scenes-file"],
                                                            directory: directory, grouping: grouping,
                                                            container: values["--container"], dryRun: dryRun, tracks: settings.tracks ?? .all, audioStream: settings.audioStream))
    }

    private static func inspect(_ options: [String]) throws -> CLICommand {
        var file: String?
        var project: String?
        var keyframes = false
        var allFrames = false
        var audioPackets = false
        var packetStream: Int?
        var settings = ExportOptions()
        var from: RationalTime?
        var to: RationalTime?
        var positionalOnly = false

        var iterator = options.makeIterator()
        while let argument = iterator.next() {
            if !positionalOnly {
                switch argument {
                case "--":
                    positionalOnly = true
                    continue
                case "--json":
                    continue
                case "--project":
                    guard project == nil, let value = iterator.next(), !value.hasPrefix("--") else {
                        throw CLIError("invalid_arguments", "Supply one path for --project.")
                    }
                    project = value
                    continue
                case "--tracks", "--audio-stream":
                    guard (argument == "--tracks" ? settings.tracks == nil : settings.audioStream == nil), let value = iterator.next() else {
                        throw CLIError("invalid_arguments", "Supply one value for \(argument).")
                    }
                    try settings.set(String(argument.dropFirst(2)), to: value)
                    continue
                case "--audio-packets":
                    audioPackets = true
                    continue
                case "--stream":
                    guard packetStream == nil, let value = iterator.next(), let index = Int(value), index >= 0 else {
                        throw CLIError("invalid_arguments", "Supply a nonnegative audio stream index.")
                    }
                    packetStream = index
                    continue
                case "--frames":
                    allFrames = true
                    continue
                case "--from", "--to":
                    guard (argument == "--from" ? from : to) == nil else {
                        throw CLIError("invalid_arguments", argument + " may be specified only once.")
                    }
                    guard let raw = iterator.next(), !raw.hasPrefix("--") else { throw CLIError("invalid_arguments", "Missing timestamp for " + argument) }
                    let time = try RationalTime(parsing: raw)
                    guard time >= .zero else { throw CLIError("invalid_range", "Inspect timestamps must be nonnegative.") }
                    if argument == "--from" { from = time } else { to = time }
                    continue
                case "--keyframes":
                    keyframes = true
                    continue
                default:
                    if argument.hasPrefix("-") {
                        throw CLIError("invalid_arguments", "Unknown inspect option '\(argument)'.")
                    }
                }
            }
            guard file == nil else {
                throw CLIError("invalid_arguments", "Inspect accepts one input file.")
            }
            file = argument
        }

        if let project {
            guard file == nil, !keyframes, !allFrames, !audioPackets, packetStream == nil,
                  from == nil, to == nil, settings.tracks == nil, settings.audioStream == nil else {
                throw CLIError("invalid_arguments", "Project inspection accepts --project FILE and --json. Inspect individual recordings for picture and packet queries.")
            }
            return .inspectProject(project)
        }
        guard let file else {
            throw CLIError("invalid_arguments", "Inspect requires an input file.")
        }
        guard [keyframes, allFrames, audioPackets].filter({ $0 }).count <= 1 else {
            throw CLIError("invalid_arguments", "Choose --frames, --keyframes or --audio-packets.")
        }
        guard packetStream == nil || audioPackets else {
            throw CLIError("invalid_arguments", "--stream selects a track for --audio-packets.")
        }
        guard (from == nil && to == nil) || keyframes || allFrames || audioPackets else {
            throw CLIError("invalid_arguments", "--from and --to require a picture or packet query.")
        }
        if let to, to <= (from ?? .zero) { throw CLIError("invalid_range", "The end must follow the start.") }
        try settings.checkTrackSelection()
        return .inspect(file: file, keyframes: keyframes, allFrames: allFrames, audioPackets: audioPackets, packetStream: packetStream, from: from, to: to, tracks: settings.tracks ?? .all, audioStream: settings.audioStream)
    }

    private static func export(_ options: [String], json: Bool, forResolve: Bool = false, forBulk: Bool = false, openResolve: Bool = false,
                               forProject: Bool = false) throws -> CLICommand {
        var arguments = options.makeIterator()
        var output: String?
        var project: String?
        var clips: [InputClip] = []
        var stdin = false
        var dryRun = false
        var exportOptions = ExportOptions()
        var order: [Int]?
        var suppliedSettings: Set<String> = []

        func value(for option: String) throws -> String {
            guard let value = arguments.next(), !value.hasPrefix("--") else {
                throw CLIError("invalid_arguments", "Missing value for \(option).")
            }
            return value
        }

        while let argument = arguments.next() {
            switch argument {
            case "--json":
                break
            case "--stdin":
                stdin = true
            case "--dry-run":
                dryRun = true
            case "--require-camera-copy" where !forResolve && !forBulk:
                guard exportOptions.requireCameraCopy == nil else {
                    throw CLIError("invalid_arguments", "Duplicate --require-camera-copy.")
                }
                exportOptions.requireCameraCopy = true
            case "--space-clips" where !forResolve && !forBulk:
                guard suppliedSettings.insert(argument).inserted else {
                    throw CLIError("invalid_arguments", "--space-clips may be specified only once.")
                }
                try exportOptions.set("space-clips", to: value(for: argument))
            case "--plan-token" where forProject:
                guard suppliedSettings.insert(argument).inserted else {
                    throw CLIError("invalid_arguments", "--plan-token may be specified only once.")
                }
                exportOptions.planToken = try value(for: argument)
            case "--still-timing", "--container":
                guard !forResolve, !forBulk, suppliedSettings.insert(argument).inserted else {
                    throw CLIError("invalid_arguments", "Use \(argument) once when rendering a still project.")
                }
                try exportOptions.set(String(argument.dropFirst(2)), to: value(for: argument))
            case "--mode", "--video", "--quality", "--audio", "--audio-output", "--snap", "--tracks", "--audio-stream", "--replace-audio", "--replace-track", "--replacement-stream":
                guard suppliedSettings.insert(argument).inserted else {
                    throw CLIError("invalid_arguments", "\(argument) may be specified only once.")
                }
                try exportOptions.set(String(argument.dropFirst(2)), to: value(for: argument))
            case "--subfolder", "--base-name":
                guard forBulk, suppliedSettings.insert(argument).inserted else {
                    throw CLIError("invalid_arguments", "Use \(argument) once on a batch export.")
                }
                let name = try value(for: argument)
                if argument == "--subfolder" {
                    exportOptions.subfolder = name
                } else {
                    exportOptions.baseName = name
                }
            case "--order", "--order-file":
                guard order == nil else {
                    throw CLIError("invalid_arguments", "--order may be specified only once.")
                }
                let raw = try value(for: argument)
                let entries = argument == "--order-file" ? try ListFile.scalars(raw, header: "order")
                    : raw.components(separatedBy: ",")
                order = try entries.map {
                    guard let index = Int($0.trimmingCharacters(in: .whitespaces)) else {
                        throw CLIError("invalid_order", "--order requires comma-separated clip numbers, for example 3,1,2.")
                    }
                    return index
                }
            case "--output":
                guard output == nil else {
                    throw CLIError("invalid_arguments", "--output may be specified only once.")
                }
                output = try value(for: argument)
            case "--clips":
                clips += try ListFile.clips(value(for: argument))
            case "--ranges":
                guard let index = clips.indices.last, clips[index].rangesFile == nil, clips[index].project == nil else {
                    throw CLIError("invalid_arguments", "--ranges requires a preceding --clip and one range list per clip.")
                }
                clips[index].rangesFile = try value(for: argument)
            case "--clip":
                clips.append(InputClip(file: try value(for: argument)))
            case "--project":
                guard project == nil else {
                    throw CLIError("invalid_arguments", "--project may be specified only once.")
                }
                project = try value(for: argument)
            case "--from", "--to":
                guard let index = clips.indices.last else {
                    throw CLIError("invalid_arguments", "\(argument) must follow --clip. To select a project range use a project clip in --stdin JSON.")
                }
                let timestamp = try value(for: argument)
                if argument == "--from", clips[index].from == nil {
                    clips[index].from = timestamp
                } else if argument == "--to", clips[index].to == nil {
                    clips[index].to = timestamp
                } else {
                    throw CLIError("invalid_arguments", "\(argument) may be specified only once per clip.")
                }
            default:
                throw CLIError("invalid_arguments", "Unknown export option '\(argument)'.")
            }
        }

        if stdin {
            guard json, output == nil, clips.isEmpty, project == nil else {
                throw CLIError("invalid_arguments", "--stdin requires --json and supplies the output and clips.")
            }
            return .export(input: nil, dryRun: dryRun, options: exportOptions, order: order)
        }

        if let project {
            guard let output, clips.isEmpty, order == nil else {
                throw CLIError("invalid_arguments", "Use --project FILE --output FILE to render its saved assembly. Use --stdin for explicit project clip ranges and ordering.")
            }
            return .exportProject(project: project, output: output, dryRun: dryRun, options: exportOptions)
        }

        guard let output, !clips.isEmpty else {
            throw CLIError("invalid_arguments", "Export requires --output and at least one --clip.")
        }
        return .export(input: InputEdit(output: output, clips: clips), dryRun: dryRun, options: exportOptions, order: order,
                       resolveOpen: forResolve ? openResolve : nil)
    }
}

extension KeyedDecodingContainer {
    func inputTime(_ key: Key, in label: String) throws -> String? {
        if let string = try? decode(String.self, forKey: key) { return string }
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let decoder = try superDecoder(forKey: key)
        return try ListFile.exactRational(from: decoder, in: label).description
    }
}

struct BulkInput: Decodable {
    struct RangeInput: Decodable {
        let from: String
        let to: String
        private enum Fields: String, CodingKey, CaseIterable { case from, to }
        init(from decoder: Decoder) throws {
            let fields = try decoder.requestFields(Fields.self, in: "Range")
            guard let start = try fields.inputTime(.from, in: "Range"), let end = try fields.inputTime(.to, in: "Range") else {
                throw CLIError("invalid_json", "Each range requires from and to timestamps.")
            }
            from = start
            to = end
        }
    }

    enum Ranges {
        case request([RangeInput])
        case parsed([AudioSpan])
    }

    let file: String
    let outputDirectory: String
    let container: String?
    let ranges: Ranges
    var options = ExportOptions()
    init(list: BulkList, spans: [AudioSpan]) {
        file = list.source
        outputDirectory = list.directory
        container = list.container
        ranges = .parsed(spans)
    }
    private enum Fields: String, CodingKey, CaseIterable {
        case file, outputDirectory = "output_directory", ranges, subfolder, baseName = "base_name", container, mode, snap, video, quality, audio, tracks, audioStream = "audio_stream"
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(Fields.self, in: "Bulk request")
        file = try fields.decode(String.self, forKey: .file)
        outputDirectory = try fields.decode(String.self, forKey: .outputDirectory)
        ranges = .request(try fields.decode([RangeInput].self, forKey: .ranges))
        options.subfolder = try fields.decodeIfPresent(String.self, forKey: .subfolder)
        options.baseName = try fields.decodeIfPresent(String.self, forKey: .baseName)
        container = try fields.decodeIfPresent(String.self, forKey: .container)
        options.audioStream = try fields.decodeIfPresent(Int.self, forKey: .audioStream)
        for key in [Fields.mode, .snap, .video, .quality, .audio, .tracks] {
            if let value = try fields.decodeIfPresent(String.self, forKey: key) {
                try options.set(key.rawValue, to: value, code: "invalid_json")
            }
        }
    }
}
