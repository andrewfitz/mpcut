import CoreFoundation
import Foundation
import MPCutCore

/// Builds a fixed MPCut CLI command from the typed file tool contract.
struct MCPFileRequest {
    var arguments: [String]
    var input: Data?
    var directory: URL

    // Each callable operation has a fixed CLI path. Catalog validation rejects fields
    // belonging to a different operation before any process can start.
    private static let routes: [String: (family: String, path: [String])] = [
        "still_file_soundtrack_attach": ("still", ["still", "soundtrack", "attach"]),
        "still_file_soundtrack_fit": ("still", ["still", "soundtrack", "fit"]),
        "still_file_soundtrack_detach": ("still", ["still", "soundtrack", "detach"]),
        "still_file_project_create": ("still", ["still", "project", "create"]),
        "still_file_placement_insert": ("still", ["still", "placement", "insert"]),
        "still_file_picture_replace": ("still", ["still", "picture", "replace"]),
        "timeline_file_gap_insert": ("still", ["timeline", "gap", "insert"]),
        "still_file_placement_update": ("still", ["still", "placement", "update"]),
        "still_file_placement_remove": ("still", ["still", "placement", "remove"]),
        "still_file_asset_relink": ("still", ["still", "asset", "relink"]),
        "still_file_placements_list": ("still", ["still", "placement", "list"]),
        "timeline_file_clips_space": ("still", ["timeline", "clips", "space"]),
        "participants_file_scan": ("participants", ["participants", "scan"]),
        "participants_file_markers_build": ("participants", ["participants", "markers", "build"]),
        "participants_file_project_inspect": ("participants", ["participants", "project", "inspect"]),
        "participants_file_project_accept": ("participants", ["participants", "project", "accept"]),
        "participants_file_project_apply": ("participants", ["participants", "project", "apply"]),
        "participants_file_render_plan": ("participants", ["participants", "render", "plan"]),
        "participants_file_render_export": ("participants", ["participants", "render", "export"]),
        "participants_file_angles_list": ("participants", ["participants", "angles", "list"]),
        "participants_file_angles_take": ("participants", ["participants", "angles", "take"]),
        "participants_file_angles_plan": ("participants", ["participants", "angles", "plan"]),
        "participants_file_angles_render": ("participants", ["participants", "angles", "render"]),
        "media_file_inspect": ("inspect", ["media", "inspect"]),
        "project_file_inspect": ("inspect", ["project", "inspect"]),
        "waveform_file_envelope_read": ("waveform", ["waveform", "envelope", "read"]),
        "project_file_create": ("author", ["project", "create"]),
        "project_file_edit": ("author", ["project", "edit"]),
        "timeline_file_range_map": ("review_project", ["timeline", "range", "map"]),
        "history_file_compare": ("review_project", ["history", "compare"]),
        "multicam_file_sync_suggest": ("review_project", ["multicam", "sync", "suggest"]),
        "multicam_file_switch_coverage_read": ("review_project", ["multicam", "switch", "coverage"]),
        "silence_file_shorten": ("silence", ["silence", "shorten"]),
        "silence_file_scan": ("silence", ["silence", "scan"]),
        "silence_file_plan": ("silence", ["silence", "plan"]),
        "silence_file_export": ("silence", ["silence", "export"]),
        "scenes_file_scan": ("scenes", ["scenes", "scan"]),
        "scenes_file_export": ("scenes", ["scenes", "export"]),
        "project_file_media_refresh": ("refresh", ["project", "media", "refresh"]),
        "project_file_media_list": ("project_media", ["project", "media", "list"]),
        "project_file_media_locate": ("project_media", ["project", "media", "locate"]),
        "project_file_media_relink": ("project_media", ["project", "media", "relink"]),
        "project_file_media_replace": ("project_media", ["project", "media", "replace"]),
        "review_file_frames_export": ("frames", ["review", "frames", "export"]),
        "analysis_file_sidecar_inspect": ("sidecar", ["analysis", "sidecar", "inspect"]),
        "analysis_file_sidecar_build": ("sidecar", ["analysis", "sidecar", "build"]),
        "export_file_project_render": ("export", ["export", "project", "render"]),
        "export_file_clips_join": ("export", ["export", "clips", "join"]),
        "export_file_soundtrack_replace": ("export", ["export", "soundtrack", "replace"]),
        "export_file_ranges_join": ("rearrange", ["export", "ranges", "join"]),
        "export_file_ranges_separate": ("bulk", ["export", "ranges", "separate"]),
        "project_file_convert": ("convert", ["project", "convert"]),
        "project_file_resolve_export": ("resolve", ["project", "resolve", "export"]),
        "project_file_resolve_import": ("resolve", ["project", "resolve", "import"]),
        "cli_help_read": ("help", ["help"]),
        "cli_version_read": ("version", ["--version"]),
    ]

    static func supports(_ tool: String) -> Bool {
        routes[tool] != nil || transcriptCommand(for: tool) != nil
    }

    static func isFileTool(_ tool: String) -> Bool {
        supports(tool) || ["file_job_status_read", "file_job_result_read", "file_job_cancel"].contains(tool)
    }

    init(tool: String, fields: [String: Any]) throws {
        let validated = try MCPSchemas.loaded.get().validate(tool: tool, arguments: fields)
        try self.init(tool: tool, validatedFields: validated)
    }

    init(tool: String, validatedFields fields: [String: Any]) throws {
        let transcript = Self.transcriptCommand(for: tool)
        guard let route = Self.routes[tool] ?? transcript.map({ ("transcript", $0) }) else {
            throw MCPCommandError("unknown_tool", "Unknown file tool.")
        }
        let command = route.family
        let a = Fields(values: fields)
        directory = try a.path("working_directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let command = transcript {
            guard var request = fields["request"] as? [String: Any] else {
                throw a.invalid("Supply a JSON request object.")
            }
            let payload = Fields(values: request)
            for key in ["project_path", "file", "transcript", "output", "out_project", "script_file", "plan_file", "job_directory"] {
                _ = try payload.path(key)
            }
            if command.starts(with: ["transcript", "job"]) || request["job_id"] != nil {
                let liveDirectory = LiveTranscriptController.jobsDirectory.resolvingSymlinksInPath().standardizedFileURL
                let directory = try payload.path("job_directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? TranscriptJobStore.defaultDirectory
                let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path != liveDirectory.path, !resolved.path.hasPrefix(liveDirectory.path + "/") else {
                    throw a.invalid("Use a file job directory. Access live jobs through transcript_editor_job_status_read and a project handle.")
                }
                request["job_directory"] = resolved.path
            }
            if tool == "transcript_file_job_prepare", request["operation_id"] == nil {
                request["operation_id"] = fields["operation_id"]
            }
            if ["transcript_file_job_prepare", "transcript_file_job_retry", "transcript_file_job_run"].contains(tool), request["progress"] == nil {
                request["progress"] = "jsonl"
            }
            arguments = command + ["--stdin", "--json"]
            input = try a.jsonObject(request)
            return
        }
        arguments = route.path + ["--json"]
        if command == "project_media" {
            guard let project = try a.path("project_path") else { throw a.invalid("Supply an absolute project_path.") }
            arguments.append(project)
            for key in ["folder", "to", "with", "out_project"] {
                if let value = try a.path(key) { arguments += [a.flag(key), value] }
            }
            for key in ["from", "source", "conform", "use_id", "clock", "loss", "replacement_offset", "transcript", "resync"] {
                if let value = try a.string(key) { arguments += [a.flag(key), value] }
            }
            for row in fields["mappings"] as? [[String: Any]] ?? [] {
                let mapping = Fields(values: row)
                guard let source = try mapping.string("from"),
                      let candidate = try mapping.path("to") else { throw a.invalid("Invalid media mapping.") }
                arguments += ["--from", source, "--to", candidate]
            }
            if let from = try a.path("from_prefix"), let to = try a.path("to_prefix") {
                guard !from.contains("=") else { throw a.invalid("The old folder root must not contain an equals sign.") }
                arguments += ["--map-prefix", from + "=" + to]
            }
            for row in fields["stream_mapping"] as? [[String: Any]] ?? [] {
                let mapping = Fields(values: row)
                let from = try mapping.number("from", integer: true)
                let to = try mapping.number("to", integer: true)
                arguments += ["--stream-map", from + "=" + to]
            }
            for key in ["in_place", "allow_loss", "reset_crop", "shared_time_of_day"] where fields[key] != nil {
                if try a.bool(key) { arguments.append(a.flag(key)) }
            }
            return
        }
        if command == "participants" {
            for key in ["file", "project_path", "analysis_file", "resume_file", "participants_file", "out_project", "output", "output_directory"] {
                _ = try a.path(key)
            }
            var request = fields.filter { !["operation_id", "working_directory"].contains($0.key) }
            if ["participants_file_scan", "participants_file_render_export"].contains(tool) {
                request["progress"] = "jsonl"
            }
            arguments.append("--stdin")
            input = try a.jsonObject(request)
            return
        }
        if command == "review_project" {
            guard let project = try a.path("project_path") else { throw a.invalid("Supply an absolute project_path.") }
            if tool == "multicam_file_switch_coverage_read" {
                guard let angle = try a.string("angle_id"), let groupTime = try a.string("group_time") else {
                    throw a.invalid("Supply angle_id and group_time.")
                }
                arguments.append("--stdin")
                input = try a.jsonObject(["project_path": project, "angle_id": angle, "group_time": groupTime])
                return
            }
            arguments += ["--project", project]
            for (key, flag) in [("before_project_path", "--before-project"), ("file", "--file")] {
                if let value = try a.path(key) { arguments += [flag, value] }
            }
            for key in ["space", "from", "to", "source_id", "reference_source_id"] {
                if let value = try a.string(key) { arguments += [a.flag(key), value] }
            }
            if fields["occurrence_index"] != nil {
                arguments += ["--occurrence-index", try a.number("occurrence_index", integer: true)]
            }
            if let path = try a.path("replacement") {
                arguments += ["--replacement", path]
                if fields["reference_stream"] != nil {
                    arguments += ["--reference-stream", try a.number("reference_stream", integer: true)]
                }
                arguments += ["--replacement-stream", try a.number("replacement_stream", integer: true)]
                if fields["program"] != nil, try a.bool("program") { arguments.append("--program") }
                if let seed = try a.string("seed") { arguments += ["--seed", seed] }
            }
            if fields["metadata_only"] != nil, try a.bool("metadata_only") { arguments.append("--metadata-only") }
            return
        }
        if command == "author" {
            guard let request = fields["request"] as? [String: Any] else { throw a.invalid("Supply a project request.") }
            let paths = Fields(values: request)
            _ = try paths.path("out_project")
            _ = try paths.path("project_path")
            arguments.append("--stdin")
            input = try a.jsonObject(request)
            return
        }
        if command == "still" {
            for key in fields.keys.sorted() where !["operation_id", "working_directory"].contains(key) {
                let flag = key == "project_path" ? "--project" : a.flag(key)
                switch key {
                case "in_place", "gap", "source_timing", "fit_soundtrack":
                    if try a.bool(key) { arguments.append(flag) }
                case "width", "height", "frames", "fragment_index", "audio_stream":
                    arguments += [flag, try a.number(key, integer: true)]
                case "image", "out_project", "project_path", "soundtrack":
                    if let path = try a.path(key) { arguments += [flag, path] }
                default:
                    if let value = try a.string(key) { arguments += [flag, value] }
                }
            }
            return
        }

        for name in ["dry_run", "no_sidecar", "allow_loss", "flatten_multicam", "all_sources", "deep", "require_camera_copy"] where fields[name] != nil {
            if try a.bool(name) { arguments.append(a.flag(name)) }
        }
        for name in ["columns", "waveform", "limit"] where fields[name] != nil {
            arguments += [a.flag(name), try a.number(name, integer: true)]
        }
        for (name, flag) in [("packet_audio_stream_index", "--stream"), ("silence_audio_stream_index", "--stream"),
                             ("audio_stream_index", command == "waveform" ? "--stream" : "--audio-stream")] where fields[name] != nil {
            arguments += [flag, try a.number(name, integer: true)]
        }
        for (key, flag) in [("silence_min_pause_seconds", "--min-pause-seconds"), ("silence_threshold_db", "--threshold-db"),
                            ("silence_padding_per_side_seconds", "--padding-per-side-seconds")] where fields[key] != nil {
            arguments += [flag, try a.number(key, integer: false)]
        }
        if fields["silence_max_blip_seconds"] != nil {
            let raw = try a.number("silence_max_blip_seconds", integer: false)
            guard let seconds = Double(raw), (0...1).contains(seconds),
                  fields["report"] == nil, fields["input_file"] == nil else {
                throw a.invalid("Use silence_max_blip_seconds between 0 and 1 seconds with a new silence scan.")
            }
            arguments += ["--max-blip-seconds", raw]
        }
        for (key, flag) in [("source_from", "--from"), ("source_to", "--to"), ("destination_format", "--to")] {
            if let value = try a.string(key) { arguments += [flag, value] }
        }
        if let destination = try a.path("out_project") { arguments += ["--out-project", destination] }
        let hasProject = fields["project_path"] != nil || fields["project_data"] != nil
        if fields["protect_pauses"] != nil {
            guard hasProject else { throw a.invalid("Protected pause IDs require a project.") }
            for id in try a.strings("protect_pauses") { arguments += ["--protect-pause", id] }
        }
        if let overrides = fields["retain_pauses"] as? [[String: Any]] {
            guard hasProject else {
                throw a.invalid("Retained pause durations require a project.")
            }
            for override in overrides {
                let duration = Fields(values: override)
                guard let id = try duration.string("pause_id"), !id.contains("=") else {
                    throw a.invalid("Supply a pause ID returned by the project scan.")
                }
                arguments += ["--retain-pause", id + "=" + (try duration.number("retained_seconds", integer: false))]
            }
        }
        if fields["take_boundaries"] != nil {
            guard hasProject, fields["output"] == nil else {
                throw a.invalid("Take boundaries require a project report without an output movie.")
            }
            for time in try a.strings("take_boundaries") { arguments += ["--take-boundary", time] }
        }
        if let clock = try a.string("clock") {
            guard hasProject else { throw a.invalid("clock requires a project.") }
            arguments += ["--clock", clock]
        }
        let subfolder = try a.string("subfolder")
        let baseName = try a.string("base_name")
        try ExportOrganization(subfolder: subfolder ?? "", baseName: baseName ?? "").validate()
        if let subfolder { arguments += ["--subfolder", subfolder] }
        if let baseName { arguments += ["--base-name", baseName] }
        if let selection = try a.string("select") {
            arguments += ["--select", selection == "non_silent" ? "non-silent" : selection]
        }
        for name in ["sample", "preset", "group_by", "audio", "audio_output", "mode", "video", "quality", "tracks", "snap", "still_timing"] {
            if let value = try a.string(name) { arguments += [a.flag(name), value] }
        }
        if command == "scenes" {
            let rangePresent = fields["source_from"] != nil || fields["source_to"] != nil
            let selectedScopes = ["clip_id", "camera_id"].filter { fields[$0] != nil }.count
            let projectScopes = selectedScopes + (fields["all_sources"] as? Bool == true ? 1 : 0)
            let policy = try a.string("policy")
            guard projectScopes <= 1, projectScopes == 0 || fields["project_path"] != nil else {
                throw a.invalid("Choose one saved-project scene scope.")
            }
            if rangePresent {
                guard fields["file"] != nil, let from = try a.string("source_from"), let to = try a.string("source_to"),
                      let start = try? RationalTime(parsing: from), let end = try? RationalTime(parsing: to),
                      start >= .zero, end > start else {
                    throw a.invalid("A file range requires a nonnegative source_from and a later source_to.")
                }
            }
            let exportFields = ["report", "input_file", "scenes_file", "export_to", "dry_run", "container", "group_by", "tracks", "audio_stream_index"]
            if fields["project_path"] != nil || rangePresent || policy != nil {
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
                    guard let raw = try a.string("operation_id"), let id = UUID(uuidString: raw) else {
                        throw a.invalid("Supply an operation_id UUID to restart the scan.")
                    }
                    arguments += ["--operation-id", id.uuidString]
                }
            }
            if fields["export_to"] == nil && (fields["file"] != nil || fields["project_path"] != nil) {
                arguments += ["--progress", "jsonl"]
            }
        } else if command == "refresh" {
            try a.requireOne(["project_path"])
            arguments += ["--progress", "jsonl"]
        }
        if let detail = try a.string("detail"), detail != "metadata" {
            guard ["keyframes", "frames", "audio_packets"].contains(detail) else { throw a.invalid("Unknown inspect detail.") }
            arguments.append(a.flag(detail))
        }
        if let path = try a.path("export_to") { arguments += ["--export-to", path] }
        if let path = try a.path("output") { arguments += ["--output", path] }
        if let topic = try a.string("topic") { arguments += topic.split(separator: " ").map(String.init) }
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
            try a.requireOne(["file", "project_path", "project_data", "edit", "report", "input_file", "clips_file"])
        }

        switch command {
        case "silence":
            if (fields["audio"] != nil || fields["audio_output"] != nil) && (!hasProject || fields["output"] == nil) {
                throw a.invalid("Audio delivery requires a project and an output path.")
            }
            if hasProject && ["silence_audio_stream_index", "audio_stream_index", "waveform", "tracks", "pauses_file"]
                .contains(where: { fields[$0] != nil }) {
                throw a.invalid("Project silence uses the tracks selected in the project and scans its original media.")
            }
            if (fields["report"] != nil || fields["input_file"] != nil)
                && ["silence_audio_stream_index", "silence_threshold_db", "silence_min_pause_seconds", "waveform"]
                .contains(where: { fields[$0] != nil }) {
                throw a.invalid("Detection settings and waveform columns require a new silence scan.")
            }
        case "frames":
            let exact = fields["at"] != nil || fields["at_file"] != nil
            if hasProject && !exact {
                throw a.invalid("Supply at or at_file for project frame exports.")
            }
            if exact && ["select", "sample", "limit"].contains(where: { fields[$0] != nil }) {
                throw a.invalid("Use select, sample and limit for automatic frame selection.")
            }
            if fields["select"] as? String != "non_silent"
                && ["silence_audio_stream_index", "silence_threshold_db", "silence_min_pause_seconds"]
                .contains(where: { fields[$0] != nil }) {
                throw a.invalid("Audio settings require select non_silent.")
            }
        case "bulk":
            if fields["input_file"] != nil,
               !Set(fields.keys).isDisjoint(with: ["file", "output_directory", "ranges", "ranges_file", "container"]) {
                throw a.invalid("A bulk input_file contains its own source, destination, ranges and container.")
            }
        case "export", "resolve":
            if fields["require_camera_copy"] != nil, fields["project_path"] == nil && fields["project_data"] == nil {
                throw a.invalid("Use require_camera_copy with a project input.")
            }
            if let spacing = try a.string("space_clips") {
                guard spacing == "source" || (try? RationalTime(parsing: spacing)).map({ $0 >= .zero }) == true else {
                    throw a.invalid("Use source or a nonnegative gap duration for space_clips.")
                }
                arguments += ["--space-clips", spacing]
            }
            let needsOutput = ["project_path", "project_data", "clips_file"].contains { fields[$0] != nil }
            guard needsOutput == (fields["output"] != nil) else {
                throw a.invalid(needsOutput ? "Supply output for the selected input." : "Supply the destination in the edit request.")
            }
        case "rearrange", "convert":
            guard fields["output"] != nil else { throw a.invalid("Supply output.") }
        default:
            break
        }
        if command == "sidecar", let project = try a.path("project_path") {
            guard let file = try a.path("file") else { throw a.invalid("Supply a source file.") }
            arguments += ["--project", project, "--", file]
        } else if let project = try a.path("project_path") {
            arguments += ["--project", project]
        } else if let project = fields["project_data"] {
            arguments += ["--project", "-"]
            input = try a.jsonObject(project)
        } else if let value = fields["edit"] {
            guard let edit = value as? [String: Any], let clips = edit["clips"] as? [[String: Any]], !clips.isEmpty,
                  try Fields(values: edit).path("output") != nil else {
                throw a.invalid("Supply edit.output and a nonempty edit.clips array.")
            }
            arguments += ["--stdin"]
            input = try a.jsonObject(edit)
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
                    var request: [String: Any] = ["file": file, "output_directory": output,
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

    struct Fields {
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

    }
}

extension MCPFileRequest {
    static func transcriptCommand(for tool: String) -> [String]? {
        switch tool {
        case "transcript_file_provider_capabilities_read": ["transcript", "provider", "capabilities"]
        case "transcript_file_tracks_list": ["transcript", "tracks", "list"]
        case "transcript_file_job_run": ["transcript", "job", "run"]
        case "transcript_file_job_prepare": ["transcript", "job", "prepare"]
        case "transcript_file_job_status_read": ["transcript", "job", "status"]
        case "transcript_file_job_cancel": ["transcript", "job", "cancel"]
        case "transcript_file_job_retry": ["transcript", "job", "retry"]
        case "transcript_file_attachment_import": ["transcript", "attachment", "import"]
        case "transcript_file_attachment_inspect": ["transcript", "attachment", "inspect"]
        case "transcript_file_attachment_bind": ["transcript", "attachment", "bind"]
        case "transcript_file_attachment_detach": ["transcript", "attachment", "detach"]
        case "transcript_file_words_read": ["transcript", "words", "read"]
        case "transcript_file_words_search": ["transcript", "words", "search"]
        case "transcript_file_occurrences_locate": ["transcript", "words", "locate"]
        case "transcript_file_takes_compare": ["transcript", "words", "compare"]
        case "transcript_file_edits_suggest": ["transcript", "words", "suggest"]
        case "transcript_file_words_correct": ["transcript", "words", "correct"]
        case "transcript_file_selection_resolve": ["transcript", "words", "select"]
        case "transcript_file_script_align": ["transcript", "script", "align"]
        case "transcript_file_edit_plan": ["transcript", "edit", "plan"]
        case "transcript_file_edit_apply": ["transcript", "edit", "apply"]
        case "transcript_file_excerpt_queue": ["transcript", "excerpt", "queue"]
        case "transcript_file_export": ["transcript", "export"]
        default: nil
        }
    }
}
