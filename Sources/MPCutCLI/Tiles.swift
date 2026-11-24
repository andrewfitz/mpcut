import Foundation
import MPCutCore

struct TilesCLI {
    enum Operation: String, CaseIterable {
        case scan, inspect, preview, link, accept, reconcile
        case listFeeds = "feeds list", inspectFeed = "feeds inspect", addFeed = "feeds add", renameFeed = "feeds rename"
        case micFeed = "feeds mic", voiceFeed = "feeds voice", preferFeed = "feeds prefer"
        case mergeFeeds = "feeds merge", splitFeed = "feeds split"
        case treatFeed = "feeds treatment", confirmFeed = "feeds confirm"
        case planAngles = "angles plan", renderAngles = "angles render", verifyAngles = "angles verify"
        case useAngles = "angles use", exportISOs = "export-isos", proposeSwitches = "switches propose"
        case correctGrid = "grid correct", setLayout = "layout set", listLayouts = "layout list"
        case addBox = "box add", setBox = "box set", splitTile = "tile split", screenShare = "tile screen-share"

        var allowed: Set<String> {
            let project: Set<String> = ["project_path", "source_id"]
            let output: Set<String> = ["out_project", "in_place"]
            let feed = project.union(["feed_id"])
            let range: Set<String> = ["from", "to"]
            let scan: Set<String> = ["backend", "sampling", "feed_layout", "gallery_grid", "progress"]
            let counts: Set<String> = ["expected_feeds", "max_visible_tiles"]
            let selection = feed.union(["all"])
            let delivery = selection.union(range).union(["output", "size", "frame_rate", "fit", "gap_color",
                                           "camera_off", "on_uncertain", "no_meeting_mix", "no_isos"])
            switch self {
            case .scan:
                return scan.union(counts).union(["file", "output", "include_scenes", "no_sidecar", "resume_file"])
            case .inspect:
                return project.union(range).union(["analysis_file", "issues", "at", "clock", "layout_changes", "rule"])
            case .preview:
                return project.union(["analysis_file", "at", "clock", "issue_id", "output"])
            case .accept:
                return project.union(output).union(counts).union(["analysis_file", "clear_count_hints"])
            case .link:
                return feed.union(output).union(range).union(["tile_id", "clear"])
            case .listFeeds:
                return project.union(["analysis_file"])
            case .inspectFeed:
                return feed.union(["analysis_file"])
            case .addFeed:
                return output.union(["project_path", "name"])
            case .renameFeed:
                return feed.union(output).union(["name"])
            case .micFeed:
                return feed.union(output).union(["mic_id", "audio_stream_index", "clear", "binding"])
            case .voiceFeed:
                return feed.union(output).union(["attachment_id", "track_id", "speaker_id", "clear"])
            case .preferFeed:
                return feed.union(output).union(range).union(["tile_id", "clear"])
            case .mergeFeeds:
                return feed.union(output).union(["into_feed_id"])
            case .splitFeed:
                return feed.union(output).union(range).union(["tile_id", "name", "new_feed_id"])
            case .treatFeed:
                return feed.union(output).union(["treatment", "color"])
            case .confirmFeed:
                return feed.union(output).union(range)
            case .planAngles:
                return delivery
            case .renderAngles:
                return delivery.union(["plan", "progress", "resume"])
            case .verifyAngles:
                return ["output"]
            case .exportISOs:
                return delivery.union(scan).union(counts).union(["file", "dry_run", "resume"])
            case .useAngles:
                return selection.union(output).union(["clip_id"])
            case .proposeSwitches:
                return ["project_path", "attachment_id", "minimum_hold", "voice_angle"]
            case .reconcile:
                return project.union(output).union(["analysis_file", "apply", "review"])
            case .correctGrid:
                return project.union(output).union(range).union(["grid"])
            case .setLayout:
                return feed.union(output).union(range).union(["clip_id", "layout", "occurrence_id", "group", "slot", "compact"])
            case .listLayouts:
                return project.union(["clip_id"])
            case .addBox, .setBox:
                return feed.union(output).union(range).union(["tile_id", "bounds"])
            case .splitTile:
                return project.union(output).union(["tile_id", "at", "new_tile_id"])
            case .screenShare:
                return project.union(output).union(range).union(["tile_id"])
            }
        }

        var repeated: Set<String> {
            switch self {
            case .planAngles, .renderAngles, .exportISOs, .useAngles:
                return ["feed_id"]
            case .setLayout:
                return ["feed_id", "slot"]
            case .proposeSwitches:
                return ["voice_angle"]
            default:
                return []
            }
        }

        func positionalField(for operand: String) -> String {
            switch self {
            case .scan: "file"
            case .exportISOs: (operand as NSString).pathExtension.lowercased() == "cut" ? "project_path" : "file"
            case .inspect, .preview, .listFeeds, .inspectFeed:
                (operand as NSString).pathExtension.lowercased() == "cut" ? "project_path" : "analysis_file"
            case .verifyAngles: "output"
            default: "project_path"
            }
        }
    }

    let operation: Operation
    private let requestFile: String?
    private let fields: [String: Any]

    init(operation: Operation, arguments: [String]) throws {
        self.operation = operation
        let options = arguments.first == "--json" ? Array(arguments.dropFirst()) : arguments
        if options == ["--stdin"] {
            requestFile = "-"
            fields = [:]
            return
        }
        if options.count == 2, options[0] == "--input", !options[1].isEmpty, !options[1].hasPrefix("--") {
            requestFile = options[1]
            fields = [:]
            return
        }
        requestFile = nil
        let switches: Set<String> = ["include_scenes", "no_sidecar", "issues", "layout_changes", "in_place",
                                     "clear", "clear_count_hints", "all", "no_meeting_mix", "no_isos", "dry_run", "resume", "apply", "group", "compact"]
        let integers: Set<String> = ["expected_feeds", "max_visible_tiles", "audio_stream_index"]
        let aliases = ["--project": "project_path", "--scan": "analysis_file"]
        var values: [String: Any] = [:]
        var operand: String?
        var iterator = options.makeIterator()
        while let token = iterator.next() {
            guard token.hasPrefix("--") else {
                guard operand == nil, !token.isEmpty else { throw CLIError("invalid_arguments", "Unexpected argument " + token) }
                operand = token
                continue
            }
            if token == "--" {
                guard operand == nil, let literal = iterator.next(), !literal.isEmpty, iterator.next() == nil else {
                    throw CLIError("invalid_arguments", "Supply one input path after --.")
                }
                operand = literal
                break
            }
            let field = aliases[token] ?? token.dropFirst(2).replacingOccurrences(of: "-", with: "_")
            guard !token.contains("_"), operation.allowed.contains(field),
                  values[field] == nil || operation.repeated.contains(field) else {
                throw CLIError("invalid_arguments", "Unknown or duplicate option " + token)
            }
            if switches.contains(field) {
                values[field] = true
                continue
            }
            guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw CLIError("invalid_arguments", "Supply a value for " + token + ".")
            }
            if integers.contains(field) {
                guard let number = Int(value), number >= 0 else {
                    throw CLIError("invalid_arguments", "Supply a nonnegative integer for " + token + ".")
                }
                values[field] = number
            } else if field == "slot" || field == "rule" || field == "binding" {
                guard let parsed = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] else {
                    throw CLIError("invalid_arguments", "Supply a JSON object for " + token + ".")
                }
                if field == "slot" {
                    values[field] = (values[field] as? [[String: Any]] ?? []) + [parsed]
                } else {
                    values[field] = parsed
                }
            } else if operation.repeated.contains(field) {
                values[field] = (values[field] as? [String] ?? []) + [value]
            } else {
                values[field] = value
            }
        }
        if let operand {
            let key = operation.positionalField(for: operand)
            guard values[key] == nil else { throw CLIError("invalid_arguments", "Supply the input path once.") }
            values[key] = operand
        }
        fields = values
    }

    func request(_ interruption: Interruption) throws -> ParticipantRequest {
        guard let requestFile else { return .init(fields: fields) }
        let bytes = try requestFile == "-"
            ? readStandardInput(interruption)
            : ClipEditCSV.readListData(fileURL(requestFile, label: "Request"), kind: "JSON request",
                                      cancelled: { !interruption.isActive })
        guard let fields = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw CLIError("invalid_json", "Supply one JSON request object.")
        }
        if let issue = jsonInputIssue(bytes) { throw CLIError("invalid_json", "The request " + issue + ".") }
        if let unexpected = Set(fields.keys).subtracting(operation.allowed).sorted().first {
            throw CLIError("invalid_json", "Unexpected Tiles field " + unexpected)
        }
        return .init(fields: fields)
    }

    func run(json: Bool, useSidecar: Bool, interruption: Interruption) throws {
        switch operation {
        case .planAngles, .renderAngles, .verifyAngles, .exportISOs:
            try runDelivery(json: json, useSidecar: useSidecar, interruption: interruption)
        case .useAngles, .proposeSwitches:
            try runAnglesAndSwitches(json: json, useSidecar: useSidecar, interruption: interruption)
        case .correctGrid, .reconcile, .confirmFeed, .treatFeed, .setLayout, .listLayouts, .addBox, .setBox, .splitTile, .screenShare:
            try runTileEdits(json: json, useSidecar: useSidecar, interruption: interruption)
        default:
            try runReview(json: json, useSidecar: useSidecar, interruption: interruption)
        }
    }
}

func mutateProject(_ request: ParticipantRequest, document: URL, action: String, interruption: Interruption,
                   mutate: (inout CutProject) throws -> Void) throws -> ProjectMutationReceipt {
    let loaded = try CutProject.loadEditorDocument(from: document, limit: CutProject.maximumHistorySteps)
    let inPlace = try request.value("in_place", as: Bool.self) ?? false
    let outProject = try request.value("out_project", as: String.self)
    guard inPlace != (outProject != nil) else {
        throw CLIError("invalid_arguments", "Choose either --out-project or --in-place.")
    }
    let destination = try outProject.map { try fileURL($0, label: "Output project") } ?? document
    guard destination.pathExtension.lowercased() == "cut" else {
        throw CLIError("invalid_arguments", "Choose a .cut destination.")
    }
    try loaded.media.validateDestination(destination, relativeTo: document)
    var updated = loaded.project
    try SidecarLocations.$projectURL.withValue(document) { try mutate(&updated) }
    try updated.validate()
    if inPlace, loaded.project != updated {
        try updated.saveCopy(to: destination, copyingTranscriptsFrom: document,
                             undo: loaded.undo + [.init(action: action, project: loaded.project)],
                             redo: [], mediaSnapshot: loaded.media.mediaSnapshot, replacingExisting: true,
                             expected: loaded.media.diskRevision, check: interruption.check)
    } else if !inPlace {
        try saveEditedProject(updated, source: document, destination: destination, action: action,
                              original: loaded.project, undo: loaded.undo, redo: loaded.redo,
                              mediaSnapshot: loaded.media.mediaSnapshot, interruption: interruption)
    }
    return ProjectMutationReceipt(projectPath: destination.path, operationCount: loaded.project == updated ? 0 : 1)
}
