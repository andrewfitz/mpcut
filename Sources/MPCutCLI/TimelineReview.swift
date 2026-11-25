import Foundation
import MPCutCore

enum TimelineReviewOptions {
    case map(project: String, clock: TimelineClock, range: MulticamRange, file: String?, index: Int?)
    case compare(before: String, after: String)
    case compareRetained(project: String, index: Int)
    case restoreCopy(project: String, index: Int, output: String)

    init(path: String, arguments: [String]) throws {
        let isMap = path == "timeline range map"
        let supported: Set<String>
        switch path {
        case "timeline range map": supported = ["--project", "--space", "--from", "--to", "--file", "--occurrence-index"]
        case "history restore-copy": supported = ["--project", "--history-index", "--out-project"]
        default: supported = ["--project", "--before-project", "--history-index"]
        }
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
        } else if let rawIndex = values["--history-index"] {
            guard let index = Int(rawIndex), index >= 0, values["--before-project"] == nil else {
                throw CLIError("invalid_arguments", "Supply a nonnegative --history-index without --before-project.")
            }
            if path == "history restore-copy" {
                guard let output = values["--out-project"], output != "-" else {
                    throw CLIError("invalid_arguments", "Supply a new .cut path for --out-project.")
                }
                self = .restoreCopy(project: project, index: index, output: output)
            } else {
                self = .compareRetained(project: project, index: index)
            }
        } else {
            guard let before = values["--before-project"], before != "-" else {
                throw CLIError("invalid_arguments", path == "history restore-copy" ? "Supply --history-index." :
                               "Choose --before-project FILE or --history-index INDEX.")
            }
            self = .compare(before: before, after: project)
        }
    }

    func run(pretty: Bool, interruption: Interruption) throws {
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
        case let .compareRetained(path, index):
            let archive = try CLIProjectMediaArchive(at: fileURL(path, label: "Project"))
            let selected = try archive.historyState(at: index)
            try writeJSON(TimelineComparison.compare(from: selected.withAbsoluteMediaPaths(relativeTo: archive.location),
                                                     to: archive.project.withAbsoluteMediaPaths(relativeTo: archive.location)),
                          pretty: pretty)
        case let .restoreCopy(path, index, output):
            let archive = try CLIProjectMediaArchive(at: fileURL(path, label: "Project"))
            guard let destination = try archive.destination(output: output, inPlace: false) else {
                throw CLIError("invalid_arguments", "Choose a .cut destination.")
            }
            let selected = try archive.historyState(at: index)
            var undo = archive.undo
            var redo = archive.redo
            var current = archive.project
            let cursor = undo.count
            func reverse(_ step: CutHistoryState, returningTo project: CutProject) -> CutHistoryState {
                .init(action: step.action, origin: step.origin, project: project,
                      bindingChanges: step.bindingChanges?.map(\.reversed))
            }
            if index < cursor {
                while undo.count > index {
                    let step = undo.removeLast()
                    redo.append(reverse(step, returningTo: current))
                    current = step.project
                }
            } else {
                while undo.count < index {
                    let step = redo.removeLast()
                    undo.append(reverse(step, returningTo: current))
                    current = step.project
                }
            }
            _ = try archive.save(selected, undo: undo, redo: redo, snapshot: archive.media.mediaSnapshot,
                                 destination: destination, interruption: interruption, beforePublish: {})
            struct Receipt: Encodable {
                let ok = true
                let projectPath: String
                let outProject: String
                let historyIndex: Int
            }
            try writeJSON(Receipt(projectPath: archive.location.path, outProject: destination.url.path, historyIndex: index),
                          pretty: pretty, checkCancellation: false)
        }
    }
}

private extension CLIProjectMediaArchive {
    func historyState(at index: Int) throws -> CutProject {
        guard (0...(undo.count + redo.count)).contains(index) else {
            throw CutError(code: "revision_unavailable", message: "This history state is beyond retained undo and redo.")
        }
        if index == undo.count { return project }
        if index < undo.count { return undo[index].project }
        return redo[redo.count - (index - undo.count)].project
    }
}
