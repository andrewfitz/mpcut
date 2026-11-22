import CoreFoundation
import Foundation
import MPCutCore

/// Builds a fixed MPCut CLI command from the typed file tool contract.
struct MCPFileRequest {
    var arguments: [String]
    var input: Data?
    var directory: URL

    private static let dataTools: [String: Set<String>] = {
        let source: Set<String> = ["file", "project", "project_data"]
        let tracks: Set<String> = ["tracks", "audio_stream"]
        let detector: Set<String> = ["threshold_db", "min_pause", "stream"]
        let encoding = tracks.union(["mode", "video", "audio", "quality", "snap"])
        return [
            "inspect": source.union(tracks).union(["detail", "from", "to", "stream", "no_sidecar"]),
            "waveform": ["file", "from", "to", "columns", "stream", "no_sidecar"],
            "frames": source.union(detector).union(["output", "preset", "at", "at_file", "select", "sample", "limit", "no_sidecar"]),
            "sidecar": detector.union(["file", "status", "only", "only_file", "no_sidecar"]),
            "scenes": tracks.union(["file", "project", "report", "input_file", "scenes_file", "export_to", "container",
                                    "group_by", "dry_run", "no_sidecar", "from", "to", "clip_id", "camera_id",
                                    "all_sources", "policy"]),
            "refresh": ["project", "deep", "no_sidecar"],
            "silence": source.union(tracks).union(detector).union(["report", "input_file", "pauses_file", "leave", "waveform", "mode", "output", "dry_run", "no_sidecar"]),
            "export": encoding.union(["output", "project", "project_data", "edit", "input_file", "clips_file", "order_file", "dry_run", "no_sidecar", "require_camera_copy"]),
            "resolve": ["project", "project_data", "output", "edit", "clips_file", "input_file", "open", "no_sidecar"],
            "bulk": encoding.union(["file", "ranges", "ranges_file", "input_file", "output_directory", "container", "dry_run", "no_sidecar"]),
            "rearrange": tracks.union(["file", "ranges", "ranges_file", "output", "snap", "dry_run", "no_sidecar"]),
            "convert": ["file", "output", "to", "allow_loss", "flatten_multicam"],
            "help": ["topic"],
            "version": []
        ]
    }()

    static func supports(_ tool: String) -> Bool {
        tool.hasPrefix("file_") && dataTools[String(tool.dropFirst(5))] != nil
    }

    init(tool: String, fields: [String: Any]) throws {
        let command = String(tool.dropFirst(5))
        let a = Fields(values: fields)
        guard Self.supports(tool), let allowed = Self.dataTools[command] else {
            throw MCPCommandError("unknown_tool", "Unknown file tool.")
        }
        let extra = Set(fields.keys).subtracting(allowed).subtracting(["operationID", "working_directory"])
        guard extra.isEmpty else { throw a.invalid("Unknown fields: " + extra.sorted().joined(separator: ", ")) }
        directory = try a.path("working_directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        arguments = [command == "version" ? "--version" : command, "--json"]

        for name in ["dry_run", "no_sidecar", "open", "allow_loss", "flatten_multicam", "status", "all_sources", "deep", "require_camera_copy"] where fields[name] != nil {
            if try a.bool(name) { arguments.append(a.flag(name)) }
        }
        for name in ["stream", "columns", "waveform", "audio_stream", "limit"] where fields[name] != nil {
            arguments += [a.flag(name), try a.number(name, integer: true)]
        }
        for name in ["min_pause", "threshold_db", "leave"] where fields[name] != nil {
            arguments += [a.flag(name), try a.number(name, integer: false)]
        }
        for name in ["from", "to", "select", "sample", "preset", "group_by", "audio", "mode", "video", "quality", "tracks", "snap"] {
            if let value = try a.string(name) { arguments += [a.flag(name), value] }
        }
        if command == "scenes" {
            let rangePresent = fields["from"] != nil || fields["to"] != nil
            let selectedScopes = ["clip_id", "camera_id"].filter { fields[$0] != nil }.count
            let projectScopes = selectedScopes + (fields["all_sources"] as? Bool == true ? 1 : 0)
            let policy = try a.string("policy")
            guard projectScopes <= 1, projectScopes == 0 || fields["project"] != nil else {
                throw a.invalid("Choose one saved-project scene scope.")
            }
            if rangePresent {
                guard fields["file"] != nil, let from = try a.string("from"), let to = try a.string("to"),
                      let start = try? RationalTime(parsing: from), let end = try? RationalTime(parsing: to),
                      start >= .zero, end > start else {
                    throw a.invalid("A file range requires a nonnegative from and a later to.")
                }
            }
            let exportFields = ["report", "input_file", "scenes_file", "export_to", "dry_run", "container", "group_by", "tracks", "audio_stream"]
            if fields["project"] != nil || rangePresent || policy != nil {
                guard exportFields.allSatisfy({ fields[$0] == nil }) else {
                    throw a.invalid("Project, range, and policy options are for scanning scenes.")
                }
            }
            for name in ["clip_id", "camera_id"] {
                if let value = try a.string(name) { arguments += [a.flag(name), value] }
            }
            if let policy {
                guard ["reuse", "resume", "restart"].contains(policy) else { throw a.invalid("Unknown scene scan policy.") }
                arguments += ["--policy", policy]
                if policy == "restart" {
                    guard let raw = try a.string("operationID"), let id = UUID(uuidString: raw) else {
                        throw a.invalid("Supply an operationID UUID to restart the scan.")
                    }
                    arguments += ["--operation-id", id.uuidString]
                }
            }
            if fields["export_to"] == nil && (fields["file"] != nil || fields["project"] != nil) {
                arguments += ["--progress", "jsonl"]
            }
        } else if command == "refresh" {
            try a.requireOne(["project"])
            arguments += ["--progress", "jsonl"]
        }
        if let detail = try a.string("detail"), detail != "metadata" {
            guard ["keyframes", "frames", "audio_packets"].contains(detail) else { throw a.invalid("Unknown inspect detail.") }
            arguments.append(a.flag(detail))
        }
        if let path = try a.path("export_to") { arguments += ["--export-to", path] }
        if let path = try a.path("output") { arguments += ["--output", path] }
        if let topic = try a.string("topic") { arguments.append(topic) }
        if fields["only"] != nil { arguments += ["--only", try a.strings("only").joined(separator: ",")] }
        if fields["at"] != nil {
            for time in try a.strings("at") {
                // The CLI also recognizes list filenames in --at. Require times here;
                // a tool caller supplies a path explicitly through at_file.
                arguments += ["--at", try RationalTime(parsing: time).description]
            }
        }
        for (key, flag) in [("only_file","--only-file"), ("at_file","--at-file"), ("order_file","--order-file"),
                            ("scenes_file","--scenes-file"), ("pauses_file","--pauses-file")] {
            if let path = try a.path(key) { arguments += [flag, path] }
        }
        if let ext = try a.string("container"), command != "bulk" || fields["ranges_file"] != nil {
            arguments += ["--container", ext]
        }

        if ["inspect", "frames", "export", "resolve", "scenes", "silence"].contains(command) {
            try a.requireOne(["file", "project", "project_data", "edit", "report", "input_file", "clips_file"])
        }

        switch command {
        case "bulk":
            if fields["input_file"] != nil,
               !Set(fields.keys).isDisjoint(with: ["file", "output_directory", "ranges", "ranges_file", "container"]) {
                throw a.invalid("A bulk input_file contains its own source, destination, ranges and container.")
            }
        case "export", "resolve":
            if fields["require_camera_copy"] != nil, fields["project"] == nil && fields["project_data"] == nil {
                throw a.invalid("Use require_camera_copy with a project input.")
            }
            let needsOutput = ["project", "project_data", "clips_file"].contains { fields[$0] != nil }
            guard needsOutput == (fields["output"] != nil) else {
                throw a.invalid(needsOutput ? "Supply output for the selected input." : "Supply the destination in the edit request.")
            }
        case "frames", "rearrange", "convert":
            guard fields["output"] != nil else { throw a.invalid("Supply output.") }
        default:
            break
        }
        if let project = try a.path("project") {
            arguments += ["--project", project]
        } else if let project = fields["project_data"] {
            arguments += ["--project", "-"]
            input = try a.jsonObject(project)
        } else if let value = fields["edit"] {
            guard let edit = value as? [String: Any], let clips = edit["clips"] as? [[String: Any]], !clips.isEmpty,
                  try Fields(values: edit).path("output") != nil else {
                throw a.invalid("Supply edit.output and a nonempty edit.clips array.")
            }
            if clips.contains(where: { $0["csv"] != nil || $0["rangesFile"] != nil }) {
                guard command == "export" else { throw a.invalid("CSV/range files are supported by file_export.") }
                arguments += try a.csvExport(edit: edit, clips: clips)
            } else {
                arguments += ["--stdin"]
                input = try a.jsonObject(edit)
            }
        } else if let report = fields["report"] {
            arguments += ["--stdin"]
            input = try a.jsonObject(report)
        } else if let file = try a.path("input_file") {
            arguments += ["--input", file]
        } else if let list = try a.path("clips_file") {
            arguments += ["--clips", list]
        } else if command == "bulk" || command == "rearrange" {
            try a.requireOne(["ranges", "ranges_file"])
            guard let file = try a.path("file") else { throw a.invalid("Supply the source file.") }
            if let extList = try a.path("ranges_file") {
                if command == "bulk" {
                    guard let output = try a.path("output_directory") else { throw a.invalid("Supply output_directory.") }
                    arguments += ["--output", output]
                }
                arguments += ["--ranges", extList, "--", file]
            } else {
                let ranges = try a.ranges()
                if command == "bulk" {
                    guard let output = try a.path("output_directory") else { throw a.invalid("Supply output_directory.") }
                    var request: [String: Any] = ["file": file, "outputDirectory": output,
                                                  "ranges": ranges.map { ["from": $0.from, "to": $0.to] }]
                    request["container"] = try a.string("container")
                    arguments.append("--stdin")
                    input = try a.jsonObject(request)
                } else {
                    arguments += ["--", file, ranges.map { $0.from + "-" + $0.to }.joined(separator: ",")]
                }
            }
        } else if let file = try a.path("file") {
            arguments += ["--", file]
        } else if !["version", "help"].contains(command) {
            throw a.invalid("Supply a file, project or structured request for " + command + ".")
        }
    }

    private struct Fields {
        let values: [String: Any]
        func invalid(_ message: String) -> MCPCommandError { MCPCommandError("invalid_arguments", message) }
        func flag(_ key: String) -> String { "--" + key.replacingOccurrences(of: "_", with: "-") }
        func requireOne(_ keys: [String]) throws {
            guard keys.filter({ values[$0] != nil }).count == 1 else {
                throw invalid("Choose one input: " + keys.joined(separator: ", "))
            }
        }

        func string(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            guard let text = value as? String, !text.isEmpty, !text.hasPrefix("--"), !text.contains("\0") else {
                throw invalid("Invalid value for " + key + ".")
            }
            return text
        }

        func path(_ key: String) throws -> String? {
            guard let value = try string(key) else { return nil }
            guard value.hasPrefix("/") else { throw invalid("Use an absolute path for " + key + ".") }
            return value
        }

        func bool(_ key: String) throws -> Bool {
            guard let n = values[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                throw invalid(key + " requires a boolean.")
            }
            return n.boolValue
        }

        func number(_ key: String, integer: Bool) throws -> String {
            guard let n = values[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite else { throw invalid(key + " requires a finite number.") }
            if integer {
                guard let value = mcpInteger(n), value >= 0 else { throw invalid(key + " requires a nonnegative integer.") }
                return String(value)
            }
            return n.stringValue
        }

        func strings(_ key: String) throws -> [String] {
            guard let list = values[key] as? [String], !list.isEmpty,
                  list.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") && !$0.contains("\0") }) else {
                throw invalid(key + " requires a nonempty array of strings.")
            }
            return list
        }

        func jsonObject(_ value: Any) throws -> Data {
            guard value is [String: Any], JSONSerialization.isValidJSONObject(value) else { throw invalid("Expected a JSON object.") }
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }

        func timestamp(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            if let rational = value as? [String: Any], Set(rational.keys) == ["numerator", "denominator"],
               let numerator = rational["numerator"].flatMap(mcpInteger),
               let denominator = rational["denominator"].flatMap(mcpInteger), denominator > 0 {
                return RationalTime(numerator: Int64(numerator), denominator: Int64(denominator)).description
            }
            return try string(key)
        }

        func ranges() throws -> [(from: String, to: String)] {
            guard let ranges = values["ranges"] as? [[String: Any]], !ranges.isEmpty else {
                throw invalid("Supply a nonempty array of from/to ranges.")
            }
            return try ranges.map { range in
                let fields = Self(values: range)
                guard Set(range.keys) == ["from", "to"],
                      let from = try fields.timestamp("from"), let to = try fields.timestamp("to") else {
                    throw invalid("Each range needs a from and to timestamp.")
                }
                let start = try RationalTime(parsing: from)
                let end = try RationalTime(parsing: to)
                guard start >= .zero, end > start else {
                    throw invalid("Each range needs a nonnegative start and a later end.")
                }
                return (from: start.description, to: end.description)
            }
        }

        func csvExport(edit: [String: Any], clips: [[String: Any]]) throws -> [String] {
            let e = Self(values: edit)
            guard let output = try e.path("output"),
                  Set(edit.keys).isSubset(of: ["file","output","clips","order","replaceAudio","replaceTrack","replacementStream"]) else {
                throw invalid("Supply edit.output and supported file edit fields.")
            }
            var result = ["--output", output]
            if let donor = try e.path("replaceAudio") { result += ["--replace-audio", donor] }
            for (key, option) in [("replaceTrack","--replace-track"), ("replacementStream","--replacement-stream")] where edit[key] != nil {
                result += [option, try e.number(key, integer: true)]
            }
            if edit["order"] != nil {
                let values = edit["order"] as? [Any] ?? []
                let order = values.compactMap(mcpInteger)
                guard !order.isEmpty, order.count == values.count, order.allSatisfy({ $0 >= 1 }) else {
                    throw invalid("Supply one-based clip numbers for order.")
                }
                result += ["--order", order.map(String.init).joined(separator: ",")]
            }
            let source = try e.path("file")
            for clip in clips {
                let c = Self(values: clip)
                guard let file = try c.path("file") ?? source,
                      Set(clip.keys).isSubset(of: ["file", "from", "to", "csv", "rangesFile"]),
                      clip["csv"] == nil || clip["rangesFile"] == nil else {
                    throw invalid("CSV/range edits accept file clips with from, to, and one cut list.")
                }
                result += ["--clip", file]
                for key in ["from", "to"] {
                    if let t = try c.timestamp(key) { result += [c.flag(key), t] }
                }
                if let csv = try c.path("csv") { result += ["--csv", csv] }
                if let ranges = try c.path("rangesFile") { result += ["--ranges", ranges] }
            }
            return result
        }
    }
}
