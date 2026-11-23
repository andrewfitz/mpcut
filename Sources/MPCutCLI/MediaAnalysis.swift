import Foundation
import MPCutCore

enum MediaProgressOutput: String {
    case none, stderr, jsonl

    init(option: String?) throws {
        guard let output = Self(rawValue: option ?? "none") else {
            throw CLIError("invalid_arguments", "--progress requires none, stderr or jsonl.")
        }
        self = output
    }
}

struct SceneScanOptions {
    enum Input {
        case file(String, SceneScanScope)
        case project(String, ProjectScope)
    }

    enum ProjectScope {
        case allSources, clip(String), camera(String)
    }

    let input: Input
    let policy: SceneScanPolicy
    let progress: MediaProgressOutput

    init(_ arguments: [String]) throws {
        let parsed = try MediaAnalysisArguments(
            arguments, values: ["--project", "--from", "--to", "--clip-id", "--camera-id",
                                "--policy", "--operation-id", "--progress"],
            switches: ["--all-sources"], acceptsFile: true)
        let values = parsed.values
        let hasRange = values["--from"] != nil || values["--to"] != nil
        let selections = [values["--clip-id"] != nil, values["--camera-id"] != nil,
                          parsed.switches.contains("--all-sources")].filter { $0 }.count
        if let project = values["--project"] {
            guard parsed.file == nil, !hasRange, selections <= 1 else {
                throw CLIError("invalid_arguments", "Choose a project and at most one project scene scope.")
            }
            let scope: ProjectScope
            if let clip = values["--clip-id"] {
                scope = .clip(clip)
            } else if let camera = values["--camera-id"] {
                scope = .camera(camera)
            } else {
                scope = .allSources
            }
            input = .project(project, scope)
        } else {
            guard let file = parsed.file, selections == 0 else {
                throw CLIError("invalid_arguments", "Supply one media file or --project PROJECT.")
            }
            let scope: SceneScanScope
            if hasRange {
                guard let from = values["--from"], let to = values["--to"],
                      let start = try? RationalTime(parsing: from), let end = try? RationalTime(parsing: to),
                      start >= .zero, end > start else {
                    throw CLIError("invalid_time", "Supply --from and --to as an increasing source range.")
                }
                scope = .range(start: start, end: end)
            } else {
                scope = .fullSource
            }
            input = .file(file, scope)
        }

        let requestedPolicy = values["--policy"] ?? "reuse"
        if values["--operation-id"] != nil && requestedPolicy != "restart" {
            throw CLIError("invalid_arguments", "--operation-id requires a restart.")
        }
        switch requestedPolicy {
        case "reuse": policy = .reuse
        case "resume": policy = .resume
        case "restart": policy = .restart(operationID: values["--operation-id"] ?? UUID().uuidString)
        default: throw CLIError("invalid_arguments", "--policy requires reuse, resume or restart.")
        }
        progress = try MediaProgressOutput(option: values["--progress"])
    }
}

struct RefreshOptions {
    let project: String
    let deep: Bool
    let progress: MediaProgressOutput

    init(_ arguments: [String]) throws {
        let parsed = try MediaAnalysisArguments(arguments, values: ["--project", "--progress"],
                                                switches: ["--deep"], acceptsFile: false)
        guard let project = parsed.values["--project"] else {
            throw CLIError("invalid_arguments", "Refresh requires --project PROJECT.")
        }
        self.project = project
        deep = parsed.switches.contains("--deep")
        progress = try MediaProgressOutput(option: parsed.values["--progress"])
    }
}

private struct MediaAnalysisArguments {
    var file: String?
    var values: [String: String] = [:]
    var switches: Set<String> = []

    init(_ arguments: [String], values allowedValues: Set<String>,
         switches allowedSwitches: Set<String>, acceptsFile: Bool) throws {
        var positional = false
        var iterator = arguments.makeIterator()
        while let word = iterator.next() {
            if !positional {
                if word == "--json" { continue }
                if word == "--" { positional = true; continue }
                if allowedSwitches.contains(word) {
                    guard switches.insert(word).inserted else {
                        throw CLIError("invalid_arguments", "Duplicate \(word).")
                    }
                    continue
                }
                if allowedValues.contains(word) {
                    guard values[word] == nil else {
                        throw CLIError("invalid_arguments", "Duplicate \(word).")
                    }
                    guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                        throw CLIError("invalid_arguments", "Missing value for \(word).")
                    }
                    values[word] = value
                    continue
                }
            }
            guard (positional || !word.hasPrefix("-")), acceptsFile, file == nil else {
                throw CLIError("invalid_arguments", "Unexpected argument '\(word)'.")
            }
            file = word
        }
    }
}
