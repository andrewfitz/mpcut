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
    var soundtrack: SourceSoundtrack?
    var file: String?
    var project: String?
    var from: String?
    var to: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case file, project, from, to, replaceAudio, replaceTrack, replacementStream
    }

    init(file: String) {
        self.file = file
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self, in: "Clip")
        file = try fields.decodeIfPresent(String.self, forKey: .file)
        project = try fields.decodeIfPresent(String.self, forKey: .project)
        guard file == nil || project == nil else {
            throw CLIError("invalid_json", "A clip must select either a file or a project.")
        }
        let donor = try fields.decodeIfPresent(String.self, forKey: .replaceAudio)
        let target = try fields.decodeIfPresent(Int.self, forKey: .replaceTrack)
        let stream = try fields.decodeIfPresent(Int.self, forKey: .replacementStream)
        guard (target ?? 0) >= 0, (stream ?? 0) >= 0,
              donor != nil || (target == nil && stream == nil), project == nil || donor == nil else {
            throw CLIError("invalid_json", "Source replacement requires a file clip, replaceAudio and nonnegative stream indices.")
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
    var order: [Int]?
    var options = ExportOptions()

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case output, clips, file, order, mode, video, quality, audio, snap, tracks, audioStream, replaceAudio, replaceTrack, replacementStream
    }

    init(output: String, clips: [InputClip]) {
        self.output = output
        self.clips = clips
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self, in: "Export request")
        output = try fields.decode(String.self, forKey: .output)
        clips = try fields.decode([InputClip].self, forKey: .clips)
        file = try fields.decodeIfPresent(String.self, forKey: .file)
        order = try fields.decodeIfPresent([Int].self, forKey: .order)
        for key in [CodingKeys.mode, .video, .quality, .audio, .snap, .tracks] {
            if let value = try fields.decodeIfPresent(String.self, forKey: key) {
                try options.set(key.rawValue, to: value, code: "invalid_json")
            }
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

struct ExportOptions {
    var mode: ExportMode?
    var video: ReencodeCodec?
    var quality: ReencodeQuality?
    var audio: ReencodeAudio?
    var snap: SnapMode?
    var tracks: ExportTracks?
    var audioStream: Int?
    var replaceAudio: String?
    var replaceTrack: Int?
    var replacementStream: Int?

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
            snap: resolve("snap", snap, request.snap),
            tracks: resolve("tracks", tracks, request.tracks),
            audioStream: resolve("audio-stream", audioStream, request.audioStream, jsonKey: "audioStream"),
            replaceAudio: resolve("replace-audio", replaceAudio, request.replaceAudio, jsonKey: "replaceAudio"),
            replaceTrack: resolve("replace-track", replaceTrack, request.replaceTrack, jsonKey: "replaceTrack"),
            replacementStream: resolve("replacement-stream", replacementStream, request.replacementStream, jsonKey: "replacementStream")
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
    case manual
    case help(CommandHelp?)
    case version
    case waveform(WaveformOptions)
    case frames(FrameExportOptions)
    case silence(SilenceOptions)
    case scenes(file: String?, export: SceneExportOptions?)
    case inspect(file: String, keyframes: Bool, allFrames: Bool, audioPackets: Bool, packetStream: Int?, from: RationalTime?, to: RationalTime?, tracks: ExportTracks, audioStream: Int?)
    case inspectProject(String)
    case exportProject(project: String, output: String, dryRun: Bool, options: ExportOptions)
    case bulk(dryRun: Bool, options: ExportOptions)
    case export(input: InputEdit?, dryRun: Bool, options: ExportOptions, order: [Int]?)
}

enum SceneGrouping: String, CaseIterable {
    case scene, view
}

struct SceneExportOptions {
    let directory: String
    let grouping: SceneGrouping
    let container: String?
    let dryRun: Bool
    let tracks: ExportTracks
    let audioStream: Int?
}

struct Arguments {
    static let version = MPCutRelease.version
    let command: CLICommand
    let json: Bool
    private(set) var useSidecar = true

    static func parse(_ tokens: [String]) throws -> Arguments {
        let end = tokens.firstIndex(of: "--") ?? tokens.endIndex
        let flags = tokens[..<end].filter { $0 == "--no-sidecar" }
        guard flags.count <= 1 else { throw CLIError("invalid_arguments", "Duplicate --no-sidecar.") }
        if !flags.isEmpty {
            let filtered = tokens[..<end].filter { $0 != "--no-sidecar" } + tokens[end...]
            var result = try parseCommand(Array(filtered))
            if case let .sidecar(options) = result.command, options.statusOnly {
                throw CLIError("invalid_arguments", "--status reads the sidecar and cannot be combined with --no-sidecar.")
            }
            result.useSidecar = false
            return result
        }
        return try parseCommand(tokens)
    }

    private static func parseCommand(_ tokens: [String]) throws -> Arguments {
        // A leading --json belongs to the command that follows: `mpcut --json --help` is `mpcut help --json`.
        if tokens.first == "--json", tokens.count > 1, tokens[1] != "--json", tokens[1] != "--" {
            return try parseCommand([tokens[1], "--json"] + tokens.dropFirst(2))
        }
        guard let verb = tokens.first else {
            throw CLIError("invalid_arguments", "Missing command. Use mpcut --help for usage.")
        }

        let options = Array(tokens.dropFirst())
        let json = requestsJSON(tokens)
        let helpOptions = options.filter { $0 != "--json" }
        if ["--help", "-h", "help"].contains(verb) {
            guard helpOptions.count <= 1 else {
                throw CLIError("invalid_arguments", "Use mpcut help [COMMAND] [--json].")
            }
            if helpOptions == ["--help"] || helpOptions == ["-h"] {
                return Arguments(command: .help(try CommandHelp.topic("help")), json: json)
            }
            if helpOptions == ["manual"] { return Arguments(command: .manual, json: json) }
            return Arguments(command: .help(try helpOptions.first.map(CommandHelp.topic)), json: json)
        }
        if helpOptions == ["--help"] || helpOptions == ["-h"] {
            return Arguments(command: .help(try CommandHelp.topic(verb)), json: json)
        }
        switch verb {
        case "sidecar":
            return Arguments(command: .sidecar(try SidecarOptions(options)), json: json)
        case "--version" where options.isEmpty || options == ["--json"]:
            return Arguments(command: .version, json: json)
        case "silence":
            return Arguments(command: .silence(try SilenceOptions(options)), json: json)
        case "scenes":
            return Arguments(command: try scenes(options), json: json)
        case "waveform":
            return Arguments(command: .waveform(try WaveformOptions(options)), json: json)
        case "frames":
            return Arguments(command: .frames(try FrameExportOptions(options)), json: json)
        case "inspect":
            return Arguments(command: try inspect(options), json: json)
        case "bulk":
            guard options.prefix(while: { $0 != "--" }).contains("--stdin") else {
                throw CLIError("invalid_arguments", "Bulk requires --json --stdin.")
            }
            guard case let .export(nil, dryRun, flags, order) = try export(options, json: json) else {
                throw CLIError("invalid_arguments", "Bulk requires --json --stdin.")
            }
            guard flags.replaceAudio == nil, flags.replaceTrack == nil, flags.replacementStream == nil else {
                throw CLIError("invalid_arguments", "Replace audio through export with one complete source file.")
            }
            guard order == nil else {
                throw CLIError("invalid_arguments", "--order belongs to export, which joins clips into one file.")
            }
            return Arguments(command: .bulk(dryRun: dryRun, options: flags), json: true)
        case "export":
            return Arguments(command: try export(options, json: json), json: json)
        case "rearrange":
            return Arguments(command: try rearrange(options), json: json)
        default:
            throw CLIError("invalid_arguments", "Unknown command '\(verb)'. Use mpcut --help for usage.")
        }
    }

    static func requestsJSON(_ tokens: [String]) -> Bool {
        tokens.prefix(while: { $0 != "--" }).contains("--json")
    }

    private static func rearrange(_ options: [String]) throws -> CLICommand {
        var positional: [String] = []
        var positionalOnly = false
        var output: String?
        var dryRun = false
        var seen: Set<String> = []
        var settings = ExportOptions(mode: .smart)
        var iterator = options.makeIterator()
        while let argument = iterator.next() {
            if !positionalOnly {
                switch argument {
                case "--": positionalOnly = true; continue
                case "--json": continue
                case "--dry-run": dryRun = true; continue
                case "--audio-only", "--video-only":
                    guard settings.tracks == nil else { throw CLIError("invalid_arguments", "Choose one track selection.") }
                    settings.tracks = argument == "--audio-only" ? .audio : .video
                    continue
                case "--output", "--snap", "--tracks", "--audio-stream":
                    guard seen.insert(argument).inserted, !(argument == "--tracks" && settings.tracks != nil) else {
                        throw CLIError("invalid_arguments", "\(argument) may be specified only once.")
                    }
                    guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                        throw CLIError("invalid_arguments", "Missing value for \(argument).")
                    }
                    if argument == "--output" { output = value }
                    else { try settings.set(String(argument.dropFirst(2)), to: value) }
                    continue
                default:
                    if argument.hasPrefix("-") {
                        throw CLIError("invalid_arguments", "Unknown rearrange option '\(argument)'.")
                    }
                }
            }
            positional.append(argument)
        }
        guard let output, positional.count == 2 else {
            throw CLIError("invalid_arguments", "Use rearrange INPUT --output OUTPUT '23:01-26:12,03:02-4:03'.")
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
                case "--export-to", "--group-by", "--container", "--tracks", "--audio-stream":
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
            guard !stdin, !dryRun, values.isEmpty else {
                throw CLIError("invalid_arguments", "--stdin, --dry-run, --group-by, --container, --tracks and --audio-stream require --export-to.")
            }
            return .scenes(file: file, export: nil)
        }
        guard let grouping = SceneGrouping(rawValue: values["--group-by"] ?? "scene") else {
            throw CLIError("invalid_arguments", "--group-by requires scene or view.")
        }
        var settings = ExportOptions()
        if let tracks = values["--tracks"] { try settings.set("tracks", to: tracks) }
        if let stream = values["--audio-stream"] { try settings.set("audio-stream", to: stream) }
        try settings.checkTrackSelection()
        return .scenes(file: file, export: SceneExportOptions(directory: directory, grouping: grouping,
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

    private static func export(_ options: [String], json: Bool) throws -> CLICommand {
        var arguments = options.makeIterator()
        var output: String?
        var project: String?
        var clips: [InputClip] = []
        var stdin = false
        var dryRun = false
        var smartTrim = false
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
            case "--smart-trim":
                guard !smartTrim else {
                    throw CLIError("invalid_arguments", "--smart-trim may be specified only once.")
                }
                smartTrim = true
            case "--audio-only", "--video-only":
                guard suppliedSettings.insert("--tracks").inserted else {
                    throw CLIError("invalid_arguments", "Choose one track selection.")
                }
                exportOptions.tracks = argument == "--audio-only" ? .audio : .video
            case "--mode", "--video", "--quality", "--audio", "--snap", "--tracks", "--audio-stream", "--replace-audio", "--replace-track", "--replacement-stream":
                guard suppliedSettings.insert(argument).inserted else {
                    throw CLIError("invalid_arguments", "\(argument) may be specified only once.")
                }
                try exportOptions.set(String(argument.dropFirst(2)), to: value(for: argument))
            case "--order":
                guard order == nil else {
                    throw CLIError("invalid_arguments", "--order may be specified only once.")
                }
                order = try value(for: argument).split(separator: ",", omittingEmptySubsequences: false).map {
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

        if smartTrim {
            guard exportOptions.mode == nil || exportOptions.mode == .smart else {
                throw CLIError("invalid_arguments", "--smart-trim conflicts with the selected --mode.")
            }
            exportOptions.mode = .smart
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
        return .export(input: InputEdit(output: output, clips: clips), dryRun: dryRun, options: exportOptions, order: order)
    }
}

private enum TimeFields: String, CodingKey, CaseIterable { case numerator, denominator }

extension KeyedDecodingContainer {
    func inputTime(_ key: Key, in label: String) throws -> String? {
        if let string = try? decode(String.self, forKey: key) { return string }
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let decoder = try superDecoder(forKey: key)
        _ = try decoder.requestFields(TimeFields.self, in: label)
        return try RationalTime(from: decoder).description
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

    let file: String
    let outputDirectory: String
    let container: String?
    let ranges: [RangeInput]
    var options = ExportOptions()
    private enum Fields: String, CodingKey, CaseIterable {
        case file, outputDirectory, ranges, container, mode, snap, video, quality, audio, tracks, audioStream
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(Fields.self, in: "Bulk request")
        file = try fields.decode(String.self, forKey: .file)
        outputDirectory = try fields.decode(String.self, forKey: .outputDirectory)
        ranges = try fields.decode([RangeInput].self, forKey: .ranges)
        container = try fields.decodeIfPresent(String.self, forKey: .container)
        options.audioStream = try fields.decodeIfPresent(Int.self, forKey: .audioStream)
        for key in [Fields.mode, .snap, .video, .quality, .audio, .tracks] {
            if let value = try fields.decodeIfPresent(String.self, forKey: key) {
                try options.set(key.rawValue, to: value, code: "invalid_json")
            }
        }
    }
}
