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

struct InputClip: Decodable {
    var file: String?
    var from: String?
    var to: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case file, from, to
    }



    init(file: String) {
        self.file = file
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self)
        file = try fields.decodeIfPresent(String.self, forKey: .file)
        from = try fields.inputTime(.from)
        to = try fields.inputTime(.to)
    }
}

struct InputEdit: Decodable {
    var output: String
    var clips: [InputClip]
    var file: String?
    var order: [Int]?
    var options = ExportOptions()

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case output, clips, file, order, mode, video, quality, audio, snap
    }

    init(output: String, clips: [InputClip]) {
        self.output = output
        self.clips = clips
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self)
        output = try fields.decode(String.self, forKey: .output)
        clips = try fields.decode([InputClip].self, forKey: .clips)
        file = try fields.decodeIfPresent(String.self, forKey: .file)
        order = try fields.decodeIfPresent([Int].self, forKey: .order)
        for key in [CodingKeys.mode, .video, .quality, .audio, .snap] {
            if let value = try fields.decodeIfPresent(String.self, forKey: key) {
                try options.set(key.rawValue, to: value, code: "invalid_json")
            }
        }
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

    mutating func set(_ key: String, to value: String, code: String = "invalid_arguments") throws {
        func checked<T: RawRepresentable & CaseIterable>(_ type: T.Type) throws -> T where T.RawValue == String {
            guard let parsed = T(rawValue: value) else {
                let choices = T.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError(code, "\(key) accepts \(choices).")
            }
            return parsed
        }
        switch key {
        case "mode": mode = try checked(ExportMode.self)
        case "video": video = try checked(ReencodeCodec.self)
        case "quality": quality = try checked(ReencodeQuality.self)
        case "snap": snap = try checked(SnapMode.self)
        case "audio": audio = try checked(ReencodeAudio.self)
        default: preconditionFailure("Unknown export setting")
        }
    }

    func merging(_ request: ExportOptions) throws -> ExportOptions {
        func resolve<T: Equatable>(_ name: String, _ flag: T?, _ field: T?) throws -> T? {
            if let flag, let field, flag != field {
                throw CLIError("invalid_arguments", "--\(name) conflicts with the JSON \(name) field.")
            }
            return flag ?? field
        }
        return try ExportOptions(
            mode: resolve("mode", mode, request.mode),
            video: resolve("video", video, request.video),
            quality: resolve("quality", quality, request.quality),
            audio: resolve("audio", audio, request.audio),
            snap: resolve("snap", snap, request.snap)
        )
    }
}

extension Decoder {
    func requestFields<Key: CodingKey & CaseIterable>(_ type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let fields = try container(keyedBy: AnyRequestKey.self)
        let allowed = Set(Key.allCases.map(\.stringValue))
        let unknown = fields.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        if let first = unknown.first {
            let location = codingPath.last?.intValue.map { "Clip \($0 + 1)" } ?? "Export request"
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
    case help
    case version
    case scenes(file: String?, export: SceneExportOptions?)
    case inspect(file: String, keyframes: Bool, allFrames: Bool, from: RationalTime?, to: RationalTime?)
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
}

struct Arguments {
    static let version = "1.1.0"
    let command: CLICommand
    let json: Bool

    static let usage = """
    Usage:
      mpcut --version [--json]
      mpcut scenes [--json] [--] FILE
      mpcut scenes [--json] --export-to DIRECTORY [--group-by scene|view] [--container EXT] [--dry-run] FILE
      mpcut scenes [--json] --stdin --export-to DIRECTORY [--group-by scene|view] [--container EXT] [--dry-run]
      mpcut inspect [--json] [--keyframes | --frames] [--from TIME] [--to TIME] [--] FILE
      mpcut rearrange [--json] [--dry-run] [--snap exact|nearest] FILE --output FILE '23:01-26:12,03:02-4:03'
      mpcut export [--json] [--dry-run] [--mode copy|smart|encode] [--snap exact|nearest] --output FILE
                   --clip FILE [--from TIME] [--to TIME] [--clip FILE ...] [--order 3,1,2]
      mpcut bulk --json --stdin [--dry-run] [--mode smart|copy|encode] [--snap exact|nearest]
      mpcut export --json --stdin [--dry-run] [--mode copy|smart|encode] [--snap exact|nearest] [--order 3,1,2]

    --keyframes includes keyframe markers and verified video start points.
    --frames includes every indexed picture in presentation order. Use --from and --to
    with either option to limit timestamps to a source interval [from, to).

    Scenes reports exact ranges and recurring view labels without writing video by default.
    --export-to Smart Trims one file per scene, or joins each view's scenes in source order
    with --group-by view. --stdin reuses a saved scene report without another scene scan.

    Bulk defaults to Smart Trim. Supply an existing output folder and one range per file:
    {"file":"movie.mp4","outputDirectory":"clips","ranges":[{"from":"1","to":"2"},{"from":"3","to":"4"}]}
    Bulk outputs use the source stem and a sequence number. Optional container selects the extension.
    All ranges are checked before writing. Existing files are never replaced.

    Use --order 3,1,2 or JSON "order":[3,1,2] to select and rearrange clips before joining
    them into one movie. Clip numbers start at 1. You can omit or repeat numbers.
    Exports with an explicit order default to Smart Trim. Other single exports default to Copy.
    --smart-trim is an alias for --mode smart.
    Rearrange joins a comma-separated range list from one source in the order listed,
    using Smart Trim and nearest-frame snapping by default.
    --snap nearest applies to copy and smart. Encode uses exact source frame boundaries.
    Encode accepts --video h264|hevc|prores, --quality smaller|balanced|high|422-lt|422|422-hq,
    and --audio auto|copy|aac|pcm|remove. ProRes uses the 422 quality options.
    For Re-encode, the output extension selects MP4, MOV, or MKV. Without an extension, encode
    uses MP4 for H.264 or HEVC and MOV for ProRes.
    Stdin accepts mode, video, quality, audio, and snap as optional JSON string fields
    alongside output and clips. A top-level file applies to clips without their own file.
    Use --dry-run --json to see resolved ranges and copy and encode durations.

    TIME accepts decimal seconds, MM:SS or HH:MM:SS with optional fractional seconds,
    or exact rational seconds such as 1001/30000. Starts are inclusive and
    ends are exclusive. JSON clips also accept the {numerator, denominator} times returned
    by inspect. Omitted bounds use the source start or end.
    """

    static func parse(_ tokens: [String]) throws -> Arguments {
        guard let verb = tokens.first else {
            throw CLIError("invalid_arguments", "Missing command. Use mpcut --help for usage.")
        }

        let options = Array(tokens.dropFirst())
        let json = requestsJSON(tokens)
        let helpOptions = options.filter { $0 != "--json" }
        if ["--help", "-h", "help"].contains(verb) || helpOptions == ["--help"] || helpOptions == ["-h"] {
            return Arguments(command: .help, json: json)
        }
        switch verb {
        case "--version" where options.isEmpty || options == ["--json"]:
            return Arguments(command: .version, json: json)
        case "scenes":
            return Arguments(command: try scenes(options), json: json)
        case "inspect":
            return Arguments(command: try inspect(options), json: json)
        case "bulk":
            guard case let .export(nil, dryRun, flags, order) = try export(options, json: json) else {
                throw CLIError("invalid_arguments", "Bulk requires --json --stdin.")
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
        var settings = ExportOptions(mode: .smart)
        var iterator = options.makeIterator()
        while let argument = iterator.next() {
            if !positionalOnly {
                switch argument {
                case "--": positionalOnly = true; continue
                case "--json": continue
                case "--dry-run": dryRun = true; continue
                case "--output", "--snap":
                    guard (argument == "--output" ? output == nil : settings.snap == nil) else {
                        throw CLIError("invalid_arguments", "\(argument) may be specified only once.")
                    }
                    guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                        throw CLIError("invalid_arguments", "Missing value for \(argument).")
                    }
                    if argument == "--output" { output = value }
                    else { try settings.set("snap", to: value) }
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
                case "--export-to", "--group-by", "--container":
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
                throw CLIError("invalid_arguments", "--stdin, --dry-run, --group-by and --container require --export-to.")
            }
            return .scenes(file: file, export: nil)
        }
        guard let grouping = SceneGrouping(rawValue: values["--group-by"] ?? "scene") else {
            throw CLIError("invalid_arguments", "--group-by requires scene or view.")
        }
        return .scenes(file: file, export: SceneExportOptions(directory: directory, grouping: grouping,
                                                            container: values["--container"], dryRun: dryRun))
    }

    private static func inspect(_ options: [String]) throws -> CLICommand {
        var file: String?
        var keyframes = false
        var allFrames = false
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

        guard let file else {
            throw CLIError("invalid_arguments", "Inspect requires an input file.")
        }
        guard !keyframes || !allFrames else { throw CLIError("invalid_arguments", "Choose --frames or --keyframes.") }
        guard (from == nil && to == nil) || keyframes || allFrames else {
            throw CLIError("invalid_arguments", "--from and --to require --frames or --keyframes for inspection.")
        }
        if let to, to <= (from ?? .zero) { throw CLIError("invalid_range", "The end must follow the start.") }
        return .inspect(file: file, keyframes: keyframes, allFrames: allFrames, from: from, to: to)
    }

    private static func export(_ options: [String], json: Bool) throws -> CLICommand {
        var arguments = options.makeIterator()
        var output: String?
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
            case "--mode", "--video", "--quality", "--audio", "--snap":
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
            case "--from", "--to":
                guard let index = clips.indices.last else {
                    throw CLIError("invalid_arguments", "\(argument) must follow --clip.")
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
            guard json, output == nil, clips.isEmpty else {
                throw CLIError("invalid_arguments", "--stdin requires --json and supplies the output and clips.")
            }
            return .export(input: nil, dryRun: dryRun, options: exportOptions, order: order)
        }

        guard let output, !clips.isEmpty else {
            throw CLIError("invalid_arguments", "Export requires --output and at least one --clip.")
        }
        return .export(input: InputEdit(output: output, clips: clips), dryRun: dryRun, options: exportOptions, order: order)
    }
}

/// Returns the first key repeated within one object of syntactically valid JSON.
/// JSONDecoder keeps one value silently, while repeated command-line options are rejected.
func repeatedJSONKey(in data: Data) -> String? {
    let bytes = [UInt8](data)
    var objects: [(keys: Set<String>, expectsKey: Bool)?] = []
    var index = 0
    while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "{"): objects.append((keys: [], expectsKey: true))
        case UInt8(ascii: "["): objects.append(nil)
        case UInt8(ascii: "}"), UInt8(ascii: "]"): _ = objects.popLast()
        case UInt8(ascii: ","):
            if objects.last??.keys != nil { objects[objects.count - 1]?.expectsKey = true }
        case UInt8(ascii: "\""):
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { return nil }
            if let object = objects.last ?? nil, object.expectsKey {
                let key = (try? JSONDecoder().decode(String.self, from: Data(bytes[start...index]))) ?? ""
                if object.keys.contains(key) { return key }
                objects[objects.count - 1]?.keys.insert(key)
                objects[objects.count - 1]?.expectsKey = false
            }
        default: break
        }
        index += 1
    }
    return nil
}


private enum TimeFields: String, CodingKey, CaseIterable { case numerator, denominator }

extension KeyedDecodingContainer {
    func inputTime(_ key: Key) throws -> String? {
        if let string = try? decode(String.self, forKey: key) { return string }
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let decoder = try superDecoder(forKey: key)
        _ = try decoder.requestFields(TimeFields.self)
        return try RationalTime(from: decoder).description
    }
}

struct BulkInput: Decodable {
    struct RangeInput: Decodable {
        let from: String
        let to: String
        private enum Fields: String, CodingKey, CaseIterable { case from, to }
        init(from decoder: Decoder) throws {
            let fields = try decoder.requestFields(Fields.self)
            guard let start = try fields.inputTime(.from), let end = try fields.inputTime(.to) else {
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
        case file, outputDirectory, ranges, container, mode, snap, video, quality, audio
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(Fields.self)
        file = try fields.decode(String.self, forKey: .file)
        outputDirectory = try fields.decode(String.self, forKey: .outputDirectory)
        ranges = try fields.decode([RangeInput].self, forKey: .ranges)
        container = try fields.decodeIfPresent(String.self, forKey: .container)
        for key in [Fields.mode, .snap, .video, .quality, .audio] {
            if let value = try fields.decodeIfPresent(String.self, forKey: key) {
                try options.set(key.rawValue, to: value, code: "invalid_json")
            }
        }
    }
}
