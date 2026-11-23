import Foundation
import MPCutCore

enum TimelineReviewOptions {
    case map(project: String, clock: TimelineClock, range: MulticamRange, file: String?, index: Int?)
    case compare(before: String, after: String)

    init(path: String, arguments: [String]) throws {
        let isMap = path == "timeline range map"
        let supported: Set<String> = isMap
            ? ["--project", "--space", "--from", "--to", "--file", "--occurrence-index"]
            : ["--project", "--before-project"]
        var values: [String: String] = [:]
        var options = arguments.filter { $0 != "--json" }.makeIterator()
        while let flag = options.next() {
            guard supported.contains(flag), values[flag] == nil, let value = options.next(),
                  !value.hasPrefix("--"), !value.isEmpty else {
                throw CLIError("invalid_arguments", "Supply each supported option once with a value. See mpcut \(path) --help.")
            }
            values[flag] = value
        }
        guard let project = values["--project"], project != "-" else {
            throw CLIError("invalid_arguments", "Supply a named --project FILE.")
        }
        if isMap {
            guard let space = values["--space"], let clock = TimelineClock(rawValue: space),
                  let from = values["--from"], let to = values["--to"] else {
                throw CLIError("invalid_arguments", "Supply --space, --from and --to.")
            }
            let index = try values["--occurrence-index"].map { value in
                guard let number = Int(value), number >= 0 else {
                    throw CLIError("invalid_arguments", "Supply a nonnegative occurrence index.")
                }
                return number
            }
            self = try .map(project: project, clock: clock,
                            range: MulticamRange(from: RationalTime(parsing: from), to: RationalTime(parsing: to)),
                            file: values["--file"], index: index)
        } else {
            guard let before = values["--before-project"], before != "-" else {
                throw CLIError("invalid_arguments", "Supply a named --before-project FILE.")
            }
            self = .compare(before: before, after: project)
        }
    }

    func run(pretty: Bool) throws {
        func project(_ path: String) throws -> CutProject {
            let url = try fileURL(path, label: "Project")
            return try CutProject.load(from: url).withAbsoluteMediaPaths(relativeTo: url)
        }
        switch self {
        case let .map(path, clock, range, file, index):
            let resolvedFile = try file.map { try fileURL($0, label: "Source").path }
            try writeJSON(project(path).mapTimelineRange(range, clock: clock, file: resolvedFile, occurrenceIndex: index),
                          pretty: pretty)
        case let .compare(before, after):
            try writeJSON(TimelineComparison.compare(from: project(before), to: project(after)), pretty: pretty)
        }
    }
}
