import Foundation
import MPCutCore

struct ProjectMediaOptions {
    enum Operation: String { case list, relink, locate, replace }

    let project: String
    let operation: Operation
    private let values: [String: [String]]
    private let flags: Set<String>
    private let replacement: MediaReplaceOptions

    init(_ operation: Operation, arguments: [String]) throws {
        var tokens = arguments.filter { $0 != "--json" }.makeIterator()
        guard let project = tokens.next(), !project.hasPrefix("--"), !isStandardInput(project) else {
            throw CLIError("invalid_arguments", "Supply a saved project as the first operand.")
        }
        self.project = project
        self.operation = operation
        let destination: Set<String> = ["--out-project", "--in-place"]
        let allowed: Set<String>
        switch operation {
        case .list: allowed = ["--include-history"]
        case .relink: allowed = destination.union(["--from", "--to", "--map-prefix"])
        case .locate: allowed = destination.union(["--folder", "--apply-matches", "--include-history"])
        case .replace:
            allowed = destination.union(["--source", "--with", "--conform", "--allow-loss", "--loss", "--use-id",
                                         "--clock", "--stream-map", "--reset-crop", "--replacement-offset",
                                         "--shared-time-of-day", "--transcript", "--resync"])
        }
        let switches: Set<String> = ["--in-place", "--apply-matches", "--allow-loss", "--include-history",
                                     "--reset-crop", "--shared-time-of-day"]
        let repeated: Set<String> = ["--from", "--to", "--map-prefix", "--stream-map"]
        var flags: Set<String> = []
        var values: [String: [String]] = [:]
        while let option = tokens.next() {
            guard allowed.contains(option) else {
                throw CLIError("invalid_arguments", "Unknown project media option " + option + ".")
            }
            guard flags.insert(option).inserted || repeated.contains(option) else {
                throw CLIError("invalid_arguments", "Duplicate " + option + ".")
            }
            if !switches.contains(option) {
                guard let value = tokens.next(), !value.isEmpty, !value.hasPrefix("--"), !value.utf8.contains(0) else {
                    throw CLIError("invalid_arguments", "Missing or invalid value for " + option + ".")
                }
                values[option, default: []].append(value)
            }
        }
        let inPlace = flags.contains("--in-place")
        let output = flags.contains("--out-project")
        guard !(inPlace && output) else {
            throw CLIError("invalid_arguments", "Choose either --out-project FILE or --in-place.")
        }
        let writing = inPlace || output
        switch operation {
        case .list: break
        case .relink:
            guard writing else {
                throw CLIError("invalid_arguments", "Choose --out-project FILE or --in-place to relink.")
            }
            let fromCount = values["--from"]?.count ?? 0
            guard fromCount == values["--to", default: []].count, fromCount > 0 || flags.contains("--map-prefix") else {
                throw CLIError("invalid_arguments", "Supply paired --from and --to paths or --map-prefix OLD=NEW.")
            }
        case .locate:
            guard flags.contains("--folder"), writing == flags.contains("--apply-matches") else {
                throw CLIError("invalid_arguments", "Supply --folder DIR. Use --apply-matches with --out-project FILE or --in-place.")
            }
        case .replace:
            guard flags.contains("--source"), flags.contains("--with") else {
                throw CLIError("invalid_arguments", "Supply --source PATH and --with FILE.")
            }
        }
        self.values = values
        self.flags = flags
        replacement = operation == .replace ? try Self.replacementOptions(values: values, flags: flags) : .init()
    }

    private static func replacementOptions(values: [String: [String]], flags: Set<String>) throws -> MediaReplaceOptions {
        func option<T: RawRepresentable>(_ name: String, as type: T.Type) throws -> T? where T.RawValue == String {
            guard let raw = values[name]?.first else { return nil }
            guard let value = T(rawValue: raw.replacingOccurrences(of: "-", with: "_")) else {
                throw CLIError("invalid_arguments", "Invalid value for " + name + ". Use project media replace --help.")
            }
            return value
        }
        let conform = try option("--conform", as: MediaReplaceConform.self) ?? .trim
        let explicitLoss = try option("--loss", as: MediaReplaceLoss.self)
        let allowLoss = flags.contains("--allow-loss")
        guard explicitLoss == nil || !allowLoss else {
            throw CLIError("invalid_arguments", "Choose either --loss or --allow-loss.")
        }
        let loss = explicitLoss ?? (allowLoss ? (conform == .keep ? .keepOffline : .remove) : nil)
        var streamMapping: [Int: Int] = [:]
        for pair in values["--stream-map", default: []] {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, let old = Int(parts[0]), let new = Int(parts[1]), old >= 0, new >= 0,
                  streamMapping[old] == nil else {
                throw CLIError("invalid_arguments", "Use --stream-map OLD=NEW with nonnegative stream indices and one mapping per old stream.")
            }
            streamMapping[old] = new
        }
        return try .init(useID: values["--use-id"]?.first, conform: conform, loss: loss,
                         clock: option("--clock", as: MediaReplaceClock.self) ?? .sourceRelative, streamMapping: streamMapping,
                         resetCrop: flags.contains("--reset-crop"), replacementOffset: values["--replacement-offset"]?.first.map {
                             try RationalTime(parsing: $0)
                         }, sharedTimeOfDay: flags.contains("--shared-time-of-day"),
                         transcript: option("--transcript", as: MediaReplaceTranscript.self) ?? .keepUnverified,
                         resync: option("--resync", as: MediaReplaceSync.self))
    }

    func run(json: Bool, interruption: Interruption) throws {
        let source = try fileURL(project, label: "Project")
        let archive = try CLIProjectMediaArchive(at: source)
        let destination = try archive.destination(output: values["--out-project"]?.first, inPlace: flags.contains("--in-place"))
        let snapshot = archive.media.mediaSnapshot
        let project = archive.project
        let undo = archive.undo
        let redo = archive.redo
        func value(_ key: String) -> String { values[key, default: []][0] }

        switch operation {
        case .list:
            let rows = ProjectMedia.inventory(project: project, undo: undo, redo: redo, relativeTo: source, snapshot: snapshot,
                                              includeHistory: flags.contains("--include-history"))
            if json {
                try writeJSON(ProjectMediaReceipt(projectPath: source.path, sources: rows))
            } else {
                try interruption.beginResponse()
                for row in rows { try writeOutput("\(row.status.rawValue)\t\(row.path)") }
            }
        case .relink:
            var mappings = try zip(values["--from", default: []], values["--to", default: []]).map { old, new in
                ProjectMediaMapping(from: old, to: try fileURL(new, label: "Candidate"))
            }
            for prefix in values["--map-prefix", default: []] {
                let parts = prefix.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw CLIError("invalid_arguments", "Use --map-prefix OLD=NEW.")
                }
                mappings += ProjectMedia.prefixMappings(project: project, undo: undo, redo: redo, relativeTo: source,
                                                        from: try fileURL(String(parts[0]), label: "Old folder", directory: true),
                                                        to: try fileURL(String(parts[1]), label: "New folder", directory: true))
            }
            guard !mappings.isEmpty else { throw CutError(code: "media_mapping_empty", message: "No project media paths match the requested prefix.") }
            try archive.relink(mappings, destination: destination, json: json, interruption: interruption)
        case .locate:
            let folder = try fileURL(value("--folder"), label: "Search folder", directory: true)
            let rows = try ProjectMedia.locate(project: project, undo: undo, redo: redo, snapshot: snapshot,
                                               relativeTo: source, folder: folder, includeHistory: flags.contains("--include-history"),
                                               cancelled: { !interruption.isActive })
            if destination != nil {
                let mappings = rows.compactMap { row -> ProjectMediaMapping? in
                    guard row.outcome.canRelink, let candidate = row.candidates.first(where: { $0.outcome == row.outcome }) else {
                        return nil
                    }
                    return .init(from: row.path, candidate: candidate)
                }
                try archive.relink(mappings, destination: destination, search: rows, json: json, interruption: interruption)
            } else {
                try writeJSON(ProjectMediaReceipt(projectPath: source.path, sources: rows), pretty: !json)
            }
        case .replace:
            let candidate = try fileURL(value("--with"), label: "Replacement")
            let preview = try ProjectMediaReplace.preview(
                project, snapshot: snapshot, relativeTo: source, source: value("--source"), candidate: candidate,
                options: replacement,
                cancelled: { !interruption.isActive }
            )
            if let destination {
                let updated = try preview.applying(to: project)
                let changed = updated != project
                _ = try archive.save(updated, undo: changed ? undo + [.init(action: "Replace Source File", project: project)] : undo,
                                     redo: changed ? [] : redo, snapshot: preview.snapshot, destination: destination,
                                     interruption: interruption, beforePublish: preview.checkGeneration)
            }
            try writeJSON(ProjectMediaReceipt(projectPath: source.path, outProject: destination?.url.path, report: preview.report),
                          pretty: !json, checkCancellation: destination == nil)
        }
    }
}

private struct ProjectMediaReceipt<Payload: Encodable>: Encodable {
    let ok = true
    let projectPath: String
    var outProject: String?
    var sources: Payload?
    var report: Payload?
    var search: [ProjectMediaSearchRow]?
    var appliedCount: Int?
}

/// Relinking transports every retained state. Replacement adds an ordinary undo step.
struct CLIProjectMediaArchive {
    let location: URL
    let project: CutProject
    let undo: [CutHistoryState]
    let redo: [CutHistoryState]
    let media: CutProjectMedia

    init(at location: URL) throws {
        let archive = try CutProject.loadEditorDocument(from: location, limit: CutProject.maximumHistorySteps)
        self.init(location: location, project: archive.project, undo: archive.undo, redo: archive.redo, media: archive.media)
    }

    init(location: URL, project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], media: CutProjectMedia) {
        self.location = location
        self.project = project
        self.undo = undo
        self.redo = redo
        self.media = media
    }

    struct Destination {
        var url: URL
        var inPlace: Bool
    }

    func destination(output: String?, inPlace: Bool) throws -> Destination? {
        guard inPlace || output != nil else { return nil }
        let url = try output.map { try fileURL($0, label: "Output project") } ?? location
        guard url.pathExtension.lowercased() == "cut" else {
            throw CLIError("invalid_arguments", "Choose a .cut destination.")
        }
        guard inPlace || media.diskRevision?.matchesDestination(url) != true else {
            throw CLIError("invalid_arguments", "Use --in-place to change the input project.")
        }
        try media.validateDestination(url, relativeTo: location)
        return .init(url: url, inPlace: inPlace)
    }

    func save(_ updated: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], snapshot: ProjectMediaSnapshot,
              destination: Destination, interruption: Interruption, beforePublish: () throws -> Void) throws -> CutProject {
        if destination.inPlace {
            _ = try updated.saveRevision(to: destination.url, undo: undo, redo: redo, mediaSnapshot: snapshot,
                                         expected: media.diskRevision) {
                try interruption.check()
                try beforePublish()
            }
            return updated
        }
        var paths: [String: String] = [:]
        func rebase(_ state: CutHistoryState) throws -> CutHistoryState {
            try interruption.check()
            return try state.rebased(from: location, to: destination.url, paths: &paths)
        }
        let project = try updated.rebased(from: location, to: destination.url, paths: &paths)
        return try project.saveNewCopy(to: destination.url, copyingTranscriptsFrom: location,
                                       undo: undo.map(rebase), redo: redo.map(rebase),
                                       mediaSnapshot: snapshot.rebased(from: location, to: destination.url),
                                       beforePublish: {
                                           try media.diskRevision?.checkCurrent(at: location)
                                           try beforePublish()
                                       }, check: interruption.check)
    }

    func relink(_ mappings: [ProjectMediaMapping], destination: Destination?, search: [ProjectMediaSearchRow]? = nil,
                json: Bool, interruption: Interruption) throws {
        try interruption.check()
        guard let destination else { throw CLIError("invalid_arguments", "Choose a project destination.") }
        if mappings.isEmpty {
            try writeJSON(ProjectMediaReceipt(projectPath: location.path, sources: [ProjectMediaBatchRow](),
                                              search: search, appliedCount: 0), pretty: !json)
            return
        }
        let result = ProjectMedia.relink(project: project, undo: undo, redo: redo, snapshot: media.mediaSnapshot,
                                         relativeTo: location, mappings: mappings, cancelled: { !interruption.isActive })
        try interruption.check()
        let applied = result.rows.filter { $0.candidate.outcome.canRelink }
        if !applied.isEmpty {
            _ = try save(result.project, undo: result.undo, redo: result.redo, snapshot: result.snapshot,
                         destination: destination, interruption: interruption) {
                for row in applied { try row.candidate.checkGeneration() }
            }
        }
        try writeJSON(ProjectMediaReceipt(projectPath: location.path, outProject: applied.isEmpty ? nil : destination.url.path,
                                          sources: result.rows, search: search, appliedCount: applied.count),
                      pretty: !json, checkCancellation: applied.isEmpty)
    }
}
