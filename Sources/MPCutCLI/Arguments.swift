import Foundation

struct CLIError: Error, Encodable {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

struct InputClip: Decodable {
    var file: String
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
        file = try fields.decode(String.self, forKey: .file)
        from = try fields.decodeIfPresent(String.self, forKey: .from)
        to = try fields.decodeIfPresent(String.self, forKey: .to)
    }
}

struct InputEdit: Decodable {
    var output: String
    var clips: [InputClip]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case output, clips
    }

    init(output: String, clips: [InputClip]) {
        self.output = output
        self.clips = clips
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(CodingKeys.self)
        output = try fields.decode(String.self, forKey: .output)
        clips = try fields.decode([InputClip].self, forKey: .clips)
    }
}

private extension Decoder {
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
    case inspect(file: String, keyframes: Bool)
    case export(input: InputEdit?, dryRun: Bool, snapNearest: Bool)
}

struct Arguments {
    static let version = "1.0.0"
    let command: CLICommand
    let json: Bool

    static let usage = """
    Usage:
      mpcut --version [--json]
      mpcut inspect [--json] [--keyframes] [--] FILE
      mpcut export [--json] [--dry-run] [--snap nearest] --output FILE
                   --clip FILE [--from TIME] [--to TIME] [--clip FILE ...]
      mpcut export --json --stdin [--dry-run] [--snap nearest]

    --keyframes includes keyframe markers and verified video start points.

    TIME accepts decimal seconds, HH:MM:SS with optional fractional seconds,
    or exact rational seconds such as 1001/30000. Starts are inclusive and
    ends are exclusive. Omitted bounds use the source start or end.
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
        case "inspect":
            return Arguments(command: try inspect(options), json: json)
        case "export":
            return Arguments(command: try export(options, json: json), json: json)
        default:
            throw CLIError("invalid_arguments", "Unknown command '\(verb)'. Use mpcut --help for usage.")
        }
    }

    static func requestsJSON(_ tokens: [String]) -> Bool {
        tokens.prefix(while: { $0 != "--" }).contains("--json")
    }

    private static func inspect(_ options: [String]) throws -> CLICommand {
        var file: String?
        var keyframes = false
        var positionalOnly = false

        for argument in options {
            if !positionalOnly {
                switch argument {
                case "--":
                    positionalOnly = true
                    continue
                case "--json":
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
        return .inspect(file: file, keyframes: keyframes)
    }

    private static func export(_ options: [String], json: Bool) throws -> CLICommand {
        var arguments = options.makeIterator()
        var output: String?
        var clips: [InputClip] = []
        var stdin = false
        var dryRun = false
        var snapNearest = false

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
            case "--snap":
                guard try value(for: argument) == "nearest" else {
                    throw CLIError("invalid_arguments", "--snap accepts 'nearest'. Omit --snap for exact cuts.")
                }
                snapNearest = true
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

        if stdin {
            guard json, output == nil, clips.isEmpty else {
                throw CLIError("invalid_arguments", "--stdin requires --json and supplies the output and clips.")
            }
            return .export(input: nil, dryRun: dryRun, snapNearest: snapNearest)
        }

        guard let output, !clips.isEmpty else {
            throw CLIError("invalid_arguments", "Export requires --output and at least one --clip.")
        }
        return .export(input: InputEdit(output: output, clips: clips), dryRun: dryRun, snapNearest: snapNearest)
    }
}
