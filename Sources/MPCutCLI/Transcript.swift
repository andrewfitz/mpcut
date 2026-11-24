import CryptoKit
import Darwin
import Foundation
import MPCutCore

struct TranscriptCLI {
    enum Operation: String, CaseIterable {
        case capabilities, tracks, prepareSession = "prepare-session", status, cancel, retry, runJob = "run-job"
        case `import`, inspect, bind, detach, read, search, locate, export
        case compare, alignScript = "align-script", suggest, correct, select, plan, apply, queue

        var fields: Set<String> {
            let target: Set<String> = ["project_path", "file"]
            let attachment: Set<String> = ["project_path", "attachment_id"]
            let page: Set<String> = ["offset", "limit"]
            let display = attachment.union(["space", "speaker_id", "source_id", "track_id", "lane_id", "assembly_index",
                                            "clip_id", "file", "include_inferred", "expected_attachment_results"])
            let destination: Set<String> = ["in_place", "out_project"]
            let job: Set<String> = ["job_directory", "job_id"]
            switch self {
            case .capabilities: return []
            case .tracks: return target.union(["options", "lane_id"])
            case .prepareSession:
                return target.union(["job_directory", "operation_id", "engine", "model", "language", "expected_speakers",
                                     "diarization", "selected_tracks", "options", "policy", "progress"])
            case .runJob: return job.union(["progress", "download"])
            case .status, .cancel: return job
            case .retry: return job.union(["progress", "project_path"])
            case .import:
                return target.union(attachment).union(destination).union(job).union(
                    ["transcript", "format", "origin", "bindings", "source_id", "audio_stream_index", "channel", "track_id", "output"])
            case .inspect: return attachment.union(["transcript", "format", "origin", "track_id", "lane_id"]).union(page)
            case .bind: return attachment.union(destination).union(["bindings", "source_id", "file", "audio_stream_index",
                                                                    "channel", "track_id", "origin"])
            case .detach: return attachment.union(destination)
            case .read: return display.union(page).union(["occurrence_id"])
            case .search: return display.union(page).union(["query"])
            case .locate: return display.union(page).union(["word_id", "occurrence_id"])
            case .export: return display.union(["format", "output"])
            case .compare: return display.union(page).union(["query", "context_words"])
            case .alignScript: return display.union(page).union(["script", "script_file"])
            case .suggest: return display.union(page).union(["filler_terms"])
            case .correct: return attachment.union(destination).union(
                ["record", "record_id", "change", "selection", "space", "first_word_id", "last_word_id", "first_occurrence_id",
                 "last_occurrence_id", "kind", "leading_padding", "trailing_padding", "selections", "revision"])
            case .select: return attachment.union(
                ["selection", "space", "first_word_id", "last_word_id", "first_occurrence_id", "last_occurrence_id", "kind", "leading_padding", "trailing_padding"])
            case .plan, .apply, .queue:
                return attachment.union(self == .plan ? [] : destination).union(
                    ["request", "plan", "selection", "space", "first_word_id", "last_word_id", "first_occurrence_id",
                     "last_occurrence_id", "kind", "action", "name", "plan_file", "leading_padding", "trailing_padding",
                     "position", "retained_duration", "angle_id", "boundary_policy", "edge", "start_frame_nudge", "end_frame_nudge"]).union(self == .plan ? ["output"] : [])
            }
        }
    }

    let operation: Operation
    private let requestSource: String?
    private let commandRequest: [String: Any]
    private static let boolFields: Set<String> = ["in_place", "include_inferred", "diarization", "download"]
    private static let intFields: Set<String> = ["expected_speakers", "audio_stream_index", "channel", "assembly_index",
                                                  "offset", "limit", "context_words", "start_frame_nudge", "end_frame_nudge"]
    private static let arrayFields: Set<String> = ["selected_tracks", "filler_terms"]
    private static let complexFields: Set<String> = ["bindings", "change", "record", "selection", "request",
                                                      "plan", "options", "revision", "selections", "expected_attachment_results"]
    init(_ tokens: [String]) throws {
        var tokens = tokens.filter { $0 != "--json" }.makeIterator()
        guard let verb = tokens.next(), let operation = Operation(rawValue: verb) else {
            throw CLIError("invalid_arguments", "Use mpcut help transcript for the list of transcript commands.")
        }
        self.operation = operation
        var values: [String: Any] = [:]
        var source: String?
        while let token = tokens.next() {
            if token == "--stdin" || token == "--input" {
                guard source == nil else {
                    throw CLIError("invalid_arguments", "Supply one JSON request with --stdin or --input FILE.")
                }
                if token == "--stdin" {
                    source = "-"
                } else {
                    guard let path = tokens.next(), !path.hasPrefix("--"), !path.isEmpty else {
                        throw CLIError("invalid_arguments", "Specify a request file after --input.")
                    }
                    source = path
                }
                continue
            }
            guard token.hasPrefix("--") else {
                throw CLIError("invalid_arguments", "Unexpected transcript argument '\(token)'.")
            }
            let flag = String(token.dropFirst(2))
            let field = flag == "project" ? "project_path" : flag.replacingOccurrences(of: "-", with: "_")
            guard !flag.contains("_"), flag != "project-path", operation.fields.contains(field), !Self.complexFields.contains(field) else {
                throw CLIError("invalid_arguments", "Unknown transcript \(verb) option '\(token)'.")
            }
            guard values[field] == nil else { throw CLIError("invalid_arguments", "Duplicate \(token).") }
            if Self.boolFields.contains(field) {
                values[field] = true
                continue
            }
            guard let value = tokens.next(), !value.hasPrefix("--"), !value.isEmpty else {
                throw CLIError("invalid_arguments", "Missing value for \(token).")
            }
            if Self.intFields.contains(field) {
                guard let number = Int(value) else {
                    throw CLIError("invalid_arguments", "\(token) requires an integer.")
                }
                values[field] = number
            } else if Self.arrayFields.contains(field) {
                values[field] = value.split(separator: ",").map(String.init)
            } else {
                values[field] = value
            }
        }
        guard source == nil || values.isEmpty else {
            throw CLIError("invalid_arguments", "Put transcript options inside the JSON request when supplying --stdin or --input.")
        }
        requestSource = source
        commandRequest = values
    }

    private func request(interruption: Interruption) throws -> TranscriptCLIRequest {
        if let requestSource {
            let bytes = try requestSource == "-"
                ? readStandardInput(interruption)
                : readFile(requestSource, label: "Request", interruption: interruption)
            return try TranscriptCLIRequest(data: bytes, allowed: operation.fields)
        }
        return TranscriptCLIRequest(values: commandRequest)
    }

    private func readFile(_ path: String, label: String, interruption: Interruption) throws -> Data {
        if path == "-" { return try readPayloadFromStandardInput(label, interruption: interruption) }
        return try ClipEditCSV.readListData(fileURL(path, label: label), kind: label, cancelled: { !interruption.isActive })
    }

    private func readPayloadFromStandardInput(_ label: String, interruption: Interruption) throws -> Data {
        guard requestSource != "-" else {
            throw CLIError("invalid_arguments", "Supply a file for \(label.lowercased()) when stdin carries the request.")
        }
        return try readStandardInput(interruption)
    }

    private func readTranscriptFile(_ path: String, interruption: Interruption) throws -> Data {
        if path == "-" { return try readPayloadFromStandardInput("Transcript", interruption: interruption) }
        try interruption.check()
        let url = try fileURL(path, label: "Transcript")
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CutError(code: "invalid_transcript", message: "The transcript input must be a regular file.")
        }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        try interruption.check()
        return bytes
    }
}

private struct TranscriptCLIRequest {
    let values: [String: Any]
    /// A saved plan or record is exact output and is read back as written.
    private static let editFields: Set<String> = ["bindings", "change", "selection", "selections", "request", "options"]

    init(values: [String: Any]) { self.values = values }

    init(data: Data, allowed: Set<String>) throws {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data), let values = object as? [String: Any] else {
            throw CLIError("invalid_json", "Expected one UTF-8 JSON object for the transcript request.")
        }
        if let issue = jsonInputIssue(data) {
            throw CLIError("invalid_json", "Transcript request \(issue).")
        }
        let unexpected = Set(values.keys).subtracting(allowed)
        if let extra = unexpected.sorted().first {
            throw CLIError("invalid_json", "Unexpected transcript request field '\(extra)'.")
        }
        self.values = values
    }

    func optional<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T? {
        guard var value = values[key], !(value is NSNull) else { return nil }
        do {
            // Nested edit JSON takes the same time strings and space names as live control.
            if Self.editFields.contains(key) { value = try TranscriptRequestJSON.normalize(value, key: key) }
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CLIError("invalid_json", "Invalid transcript request field '\(key)': \(error).")
        }
    }

    func required<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
        guard let value = try optional(key, type) else {
            throw CLIError("invalid_arguments", "Specify \(key) in the transcript request.")
        }
        return value
    }

    func time(_ key: String) throws -> RationalTime? {
        if let text = values[key] as? String { return try RationalTime(parsing: text) }
        return try optional(key)
    }

    func url(_ key: String, directory: Bool = false) throws -> URL? {
        try optional(key, String.self).map { try fileURL($0, label: key, directory: directory) }
    }

    func page() throws -> (offset: Int, limit: Int) {
        let offset = try optional("offset", Int.self) ?? 0
        let limit = try optional("limit", Int.self) ?? 100
        guard offset >= 0, (1...500).contains(limit) else {
            throw CLIError("invalid_arguments", "Use a nonnegative offset and a limit between 1 and 500.")
        }
        return (offset, limit)
    }

    func space(default defaultSpace: TranscriptSpace) throws -> TranscriptSpace {
        guard let space = try optional("space", String.self) else { return defaultSpace }
        switch space {
        case "source": return .source
        case "group": return .group
        case "current_cut": return .currentCut
        default: throw CLIError("invalid_arguments", "Use source, group, or current_cut space.")
        }
    }

    func filter() throws -> TranscriptFilter {
        try .init(speakerID: optional("speaker_id"), sourceID: optional("source_id"), trackID: optional("track_id"),
                  assemblyIndex: optional("assembly_index"), clipID: optional("clip_id"), file: optional("file"),
                  includeInferred: optional("include_inferred") ?? false, laneID: optional("lane_id"))
    }
}

private struct TranscriptCLIPage<Item: Encodable>: Encodable {
    private enum CodingKeys: String, CodingKey {
        case items
        case total
        case nextOffset = "next_offset"
        case attachmentResults = "attachment_results"
    }
    let items: [Item]
    let total: Int
    let nextOffset: Int?
    let attachmentResults: [String: String]?

    init(items: [Item], total: Int, nextOffset: Int?, attachmentResults: [String: String]? = nil) {
        self.items = items
        self.total = total
        self.nextOffset = nextOffset
        self.attachmentResults = attachmentResults
    }

    init(_ values: [Item], page: (offset: Int, limit: Int), attachmentResults: [String: String]? = nil) {
        let items = Array(values.dropFirst(page.offset).prefix(page.limit))
        let next = page.offset + items.count
        self.init(items: items, total: values.count, nextOffset: next < values.count ? next : nil,
                  attachmentResults: attachmentResults)
    }
}

private struct TranscriptCLIProject {
    let url: URL
    let project: CutProject
    let undo: [CutHistoryState]
    let redo: [CutHistoryState]
    let media: CutProjectMedia
    let mediaSnapshot: ProjectMediaSnapshot

    init(url: URL) throws {
        self.url = url
        let loaded = try CutProject.loadEditorDocument(from: url, limit: CutProject.maximumHistorySteps)
        (project, undo, redo, media) = (loaded.project, loaded.undo, loaded.redo, loaded.media)
        mediaSnapshot = loaded.media.mediaSnapshot
    }

    init(indexed: MediaInfo, destination: URL) throws {
        guard indexed.duration > .zero else {
            throw CutError(code: "transcript_source_empty", message: "The recording has no editable duration.")
        }
        url = destination
        let path = CutProject.relativeMediaPath(indexed.url.path, to: destination)
        project = .sequence([.init(id: "recording", file: path, from: .zero, to: indexed.duration)])
        undo = []
        redo = []
        media = try CutProjectMedia.decode(transcriptJSON(project))
        mediaSnapshot = .init(entries: [.init(path: path, media: indexed)])
    }

    func attachment(_ id: String?) throws -> TranscriptAttachment {
        let matches = project.transcripts.attachments.filter { id == nil || $0.id == id }
        guard let result = matches.first else {
            throw CutError(code: "transcript_attachment_missing", message: "No matching transcript attachment.")
        }
        guard matches.count == 1 else {
            throw CutError(code: "ambiguous_transcript_attachment", message: "Choose one transcript with attachment_id.")
        }
        return result
    }

    func document(_ attachment: TranscriptAttachment) throws -> TranscriptDocument {
        try TranscriptCodec.decode(TranscriptStore.read(attachment.asset, relativeTo: url), format: .json)
    }

    func revision(_ attachment: TranscriptAttachment) throws -> TranscriptEditRevision {
        var timeline = project
        timeline.transcripts = .init()
        let digest = SHA256.hash(data: try transcriptJSON(timeline))
        let key = digest.prefix(6).reduce(0) { ($0 << 8) | Int($1) }
        return .init(timelineRevision: key, transcriptRevision: project.transcripts.revision, resultID: attachment.resultID)
    }

    func destination(_ request: TranscriptCLIRequest, queueName: String? = nil) throws -> (url: URL, inPlace: Bool) {
        let allowInPlace = queueName == nil
        let inPlace = try request.optional("in_place", Bool.self) ?? false
        var output = try request.url("out_project")
        if let queueName, output == nil {
            guard !queueName.contains("/"), !queueName.utf8.contains(0), queueName != "." && queueName != ".." else {
                throw CLIError("invalid_arguments", "Specify --out-project when the excerpt name cannot be used as a filename.")
            }
            output = url.deletingLastPathComponent().appendingPathComponent(queueName + ".cut")
        }
        guard inPlace != (output != nil), !inPlace || allowInPlace else {
            throw CLIError("invalid_arguments", allowInPlace
                           ? "Choose either --out-project FILE or --in-place." : "Specify --out-project FILE for the excerpt.")
        }
        let destination = output ?? url
        guard inPlace || media.diskRevision?.matchesDestination(destination) != true else {
            throw CLIError("invalid_arguments", "Use --in-place to change the input project.")
        }
        guard inPlace || !FileManager.default.fileExists(atPath: destination.path) else {
            throw CutError(code: "output_exists", message: "Choose a new project destination.")
        }
        try media.validateDestination(destination, relativeTo: url)
        return (destination, inPlace)
    }

    func save(_ updated: CutProject, to destination: (url: URL, inPlace: Bool), change: CutHistoryState? = nil,
              snapshot: Bool = false, assetData: [TranscriptAsset: Data] = [:], interruption: Interruption,
              beforePublish: () throws -> Void = {}) throws {
        if destination.inPlace, updated == project,
           assetData.keys.allSatisfy({ (try? TranscriptStore.read($0, relativeTo: url)) != nil }) { return }
        try interruption.check()
        var paths: [String: String] = [:]
        func rebase(_ state: CutHistoryState) throws -> CutHistoryState {
            try state.rebased(from: url, to: destination.url, paths: &paths)
        }
        var saved = try updated.rebased(from: url, to: destination.url, paths: &paths)
        if snapshot { saved.transcripts.documentID = nil }
        let past = snapshot ? [] : try (undo + (change.map { [$0] } ?? [])).map(rebase)
        let future = snapshot || change != nil ? [] : try redo.map(rebase)
        try saved.saveCopy(to: destination.url, copyingTranscriptsFrom: url, undo: past, redo: future,
                           mediaSnapshot: mediaSnapshot.rebased(from: url, to: destination.url),
                           replacingExisting: destination.inPlace, expected: destination.inPlace ? media.diskRevision : nil,
                           assetData: assetData, beforePublish: beforePublish, check: interruption.check)
    }

    struct IndexMedia {
        var sequence: [String: MediaInfo] = [:]
        var multicam: [String: MediaInfo] = [:]
    }

    func indexMedia(forSpace space: TranscriptSpace, sequenceCoveragePaths: Set<String> = [],
                    interruption: Interruption) throws -> IndexMedia {
        let engine = CutEngine(cancelled: { !interruption.isActive })
        var resolved = IndexMedia()
        try AnalysisSidecar.$excludedSources.withValue(
            AnalysisSidecar.excludedSources.union(media.sidecarExclusions(relativeTo: url))
        ) {
            switch project {
            case let .multicam(multicam):
                var recordings: [URL: MediaInfo] = [:]
                for source in multicam.sources {
                    try interruption.check()
                    guard let file = try? CutProject.checkedMediaURL(source.file, relativeTo: url) else { continue }
                    if let info = recordings[file] ?? (try? engine.inspectMulticamSource(file)) {
                        recordings[file] = info
                        resolved.multicam[source.id] = info
                    }
                }
            case .sequence, .stillSequence:
                let paths = space == .currentCut
                    ? Set(clips.flatMap { [$0.file, $0.originalFile].compactMap { $0 } }) : sequenceCoveragePaths
                for path in paths {
                    try interruption.check()
                    let file = try? CutProject.checkedMediaURL(path, relativeTo: url)
                    if let info = file.flatMap({ try? engine.inspect($0, keyframes: true) }) {
                        // The index uses authored file paths and the edit planner resolves physical paths.
                        resolved.sequence[path] = info
                        resolved.sequence[info.url.resolvingSymlinksInPath().path] = info
                    }
                }
            }
        }
        try interruption.check()
        return resolved
    }

    func index(document: TranscriptDocument, attachment: TranscriptAttachment, media: IndexMedia,
               spaces: Set<TranscriptSpace> = Set(TranscriptSpace.allCases)) throws -> TranscriptIndex {
        try TranscriptIndex(document: document, attachment: attachment, project: project, projectURL: url,
                            sequenceMedia: media.sequence, multicamMedia: media.multicam,
                            timelineRevision: revision(attachment).timelineRevision, records: project.transcripts.authoring,
                            spaces: spaces)
    }

    var clips: [CutSequenceClip] {
        switch project {
        case let .sequence(clips): return clips
        case let .stillSequence(sequence): return sequence.items.compactMap(\.source)
        case .multicam: return []
        }
    }

    func bindings(_ request: TranscriptCLIRequest, document: TranscriptDocument, original: [TranscriptBinding] = [],
                  interruption: Interruption) throws -> [TranscriptBinding] {
        let explicit = try request.optional("bindings", [TranscriptBinding].self)
        let trackID = try request.optional("track_id", String.self)
        let sourceID = try request.optional("source_id", String.self)
        let file = try request.url("file")
        let stream = try request.optional("audio_stream_index", Int.self)
        let channel = try request.optional("channel", Int.self)
        let explicitTrack = trackID != nil || sourceID != nil || file != nil || stream != nil || channel != nil
        guard explicit == nil || !explicitTrack else {
            throw CLIError("invalid_arguments", "Use bindings or single-track binding fields.")
        }
        let knownTracks = Set(document.tracks.map(\.id))
        let engine = CutEngine(cancelled: { !interruption.isActive })
        let referenced = Set(clips.flatMap { [$0.file, $0.originalFile].compactMap { $0 } }.map(canonicalMediaPath))
        if let explicit {
            return try explicit.map { binding in
                try interruption.check()
                guard knownTracks.contains(binding.trackID) else {
                    throw CutError(code: "transcript_track_missing", message: "A binding names a track outside this transcript.")
                }
                var checked = binding
                let media: MediaInfo?
                switch project {
                case let .multicam(multicam):
                    guard let source = multicam.sources.first(where: { $0.id == binding.sourceID }), binding.file == nil else {
                        throw CutError(code: "invalid_transcript_binding", message: "Choose a source in this multicam project.")
                    }
                    let sourceURL = try CutProject.checkedMediaURL(source.file, relativeTo: url)
                    media = try? engine.inspectMulticamSource(sourceURL)
                case .sequence, .stillSequence:
                    guard let path = binding.file, binding.sourceID == nil, referenced.contains(canonicalMediaPath(path)) else {
                        throw CutError(code: "invalid_transcript_binding", message: "Choose a media file in this sequence.")
                    }
                    let sourceURL = try CutProject.checkedMediaURL(path, relativeTo: url)
                    media = try? engine.inspect(sourceURL, keyframes: true)
                    if let media {
                        checked.sequenceClockOrigin = media.multicamSourceOffset
                        checked.sequenceStreamOrdinal = media.audio.firstIndex { $0.stream.index == binding.streamIndex }
                    }
                }
                try checkBinding(media: media, streamIndex: binding.streamIndex, channel: binding.channel, explicit: true)
                return checked.stamped(in: project, relativeTo: url, confirmed: true)
            }
        }
        let tracks = document.tracks.filter { trackID == nil || $0.id == trackID }
        guard trackID == nil || !tracks.isEmpty else {
            throw CutError(code: "transcript_track_missing", message: "No matching track in the transcript.")
        }
        guard !explicitTrack || tracks.count == 1 else {
            throw CLIError("invalid_arguments", "Choose --track-id ID to bind a single track, or supply bindings in JSON.")
        }
        guard explicitTrack || original.isEmpty else { return original }
        let candidates = Set(clips.map { $0.originalFile ?? $0.file })
        var changed: [TranscriptBinding] = []
        for track in tracks where track.coverage != .coverageOnly {
            try interruption.check()
            let existing = original.first { $0.trackID == track.id }
            switch project {
            case let .multicam(multicam):
                guard file == nil else { throw CLIError("invalid_arguments", "Use source_id for a multicam binding.") }
                let wanted = sourceID ?? existing?.sourceID ?? track.sourceID
                let identified = multicam.sources.filter { $0.id == wanted }
                let named = multicam.sources.filter {
                    $0.file == track.name || $0.name == track.name || URL(fileURLWithPath: $0.file).lastPathComponent == track.name
                }
                let sources = sourceID != nil || !identified.isEmpty ? identified : (named.isEmpty ? multicam.sources : named)
                guard let source = sources.first, sources.count == 1 else {
                    if explicitTrack { throw CLIError("invalid_arguments", "Supply a matching multicam source_id.") }
                    continue
                }
                let sourceURL = try CutProject.checkedMediaURL(source.file, relativeTo: url)
                let slot = stream ?? existing?.streamIndex ?? track.streamIndex ?? source.audioStream
                let media = try? engine.inspectMulticamSource(sourceURL)
                guard let streamIndex = slot ?? media?.audio.first?.stream.index else { continue }
                let channel = channel ?? existing?.channel ?? track.channel
                try checkBinding(media: media, streamIndex: streamIndex, channel: channel, explicit: explicitTrack)
                changed.append(.init(trackID: track.id, sourceID: source.id, streamIndex: streamIndex,
                                     channel: channel, offset: existing?.offset ?? .zero))
            case .sequence, .stillSequence:
                if sourceID != nil || (file.map { !referenced.contains(canonicalMediaPath($0.path)) } ?? false) {
                    throw CutError(code: "invalid_transcript_binding", message: "Choose a media file in this sequence.")
                }
                let matching = candidates.filter { $0 == track.sourceID || $0 == track.name
                    || URL(fileURLWithPath: $0).lastPathComponent == track.name
                    || CutProject.mediaURL($0, relativeTo: url).path == track.name }
                let matchingPath = matching.count == 1 ? matching.first : nil
                guard let path = file?.path ?? existing?.file ?? matchingPath ?? (candidates.count == 1 ? candidates.first : nil) else {
                    if explicitTrack { throw CLIError("invalid_arguments", "Supply a source recording with --file.") }
                    continue
                }
                let sourceURL = try CutProject.checkedMediaURL(path, relativeTo: url)
                let slot = stream ?? existing?.streamIndex ?? track.streamIndex
                let media = try? engine.inspect(sourceURL, keyframes: true)
                guard let streamIndex = slot ?? media?.audio.first?.stream.index else { continue }
                let channel = channel ?? existing?.channel ?? track.channel
                try checkBinding(media: media, streamIndex: streamIndex, channel: channel, explicit: explicitTrack)
                changed.append(.init(trackID: track.id, file: path, streamIndex: streamIndex,
                                     channel: channel, offset: existing?.offset ?? .zero,
                                     sequenceClockOrigin: media?.multicamSourceOffset ?? existing?.sequenceClockOrigin,
                                     sequenceStreamOrdinal: media?.audio.firstIndex(where: { $0.stream.index == streamIndex })
                                         ?? existing?.sequenceStreamOrdinal))
            }
        }
        let ids = Set(changed.map(\.trackID))
        return original.filter { !ids.contains($0.trackID) }
            + changed.map { $0.stamped(in: project, relativeTo: url, confirmed: explicitTrack) }
    }

    private func canonicalMediaPath(_ path: String) -> String {
        CutProject.mediaURL(path, relativeTo: url).resolvingSymlinksInPath().path
    }

    private func checkBinding(media: MediaInfo?, streamIndex: Int, channel: Int?, explicit: Bool) throws {
        guard explicit, let media else { return }
        guard let stream = media.audio.first(where: { $0.stream.index == streamIndex })?.stream,
              channel.map({ (0..<stream.channels).contains($0) }) ?? true else {
            throw CutError(code: "transcript_stream_missing", message: "Choose an available audio stream and channel.")
        }
    }
}

private func transcriptJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private struct TranscriptCLIResult: Encodable {
    private enum CodingKeys: String, CodingKey {
        case ok
        case project = "project_path"
        case output
        case attachment
        case revision
        case historyAction = "history_action"
        case name
        case unboundTracks = "unbound_tracks"
    }
    let ok = true
    var project: String?
    var output: String?
    var attachment: TranscriptAttachment?
    var revision: TranscriptEditRevision?
    var historyAction: String?
    var name: String?
    var unboundTracks: [String]?
}

private struct TranscriptCLIInspection: Encodable {
    private enum CodingKeys: String, CodingKey {
        case project = "project_path"
        case revision
        case attachments
        case nextOffset = "next_offset"
        case authoring
    }
    let project: String?
    let revision: UInt64?
    let attachments: [Entry]
    let nextOffset: Int?
    var authoring: TranscriptCLIPage<TranscriptAuthoredRecord>? = nil

    struct Entry: Encodable {
        private enum CodingKeys: String, CodingKey {
            case attachment
            case clock
            case approximateClock = "approximate_clock"
            case words
            case tracks
            case speakers
            case status
        }
        let attachment: TranscriptAttachment?
        let clock: TranscriptClock?
        let approximateClock: Bool?
        let words: Int?
        let tracks: TranscriptCLIPage<TranscriptLaneReadout<Track>>?
        let speakers: TranscriptCLIPage<TranscriptLaneReadout<TranscriptSpeaker>>?
        let status: String

        struct Track: Encodable {
            private enum CodingKeys: String, CodingKey {
                case id
                case name
                case coverage
                case activityFrames = "activity_frames"
                case activity
                case binding
                case sourceStatus = "source_status"
                case streamEvidence = "stream_evidence"
                case origin
                case sessionStart = "session_start"
                case role
                case error
                case warning
            }
            let id: String
            let name: String
            let coverage: TranscriptCoverage
            let activityFrames: Int
            let activity: TranscriptCLIPage<TranscriptActivityFrame>?
            let binding: TranscriptBinding?
            let sourceStatus: String?
            let streamEvidence: TranscriptJSONValue?
            let origin: RationalTime
            let sessionStart: RationalTime
            let role: TranscriptRole
            let error: String?
            let warning: String?
        }

        init(attachment: TranscriptAttachment? = nil, document: TranscriptDocument? = nil,
             status: String = "available", at page: (offset: Int, limit: Int), project: TranscriptCLIProject? = nil,
             trackID: String? = nil, laneID: String? = nil, interruption: Interruption) {
            self.attachment = attachment
            clock = document?.clock
            approximateClock = document.map { $0.approximateClock && attachment?.importOrigin == nil }
            words = document?.words.count
            let engine = CutEngine(cancelled: { !interruption.isActive })
            var cache: [URL: MediaInfo] = [:]
            tracks = document.map {
                let selected = $0.tracks.compactMap { track -> (TranscriptTrack, TranscriptLaneMetadata?)? in
                    let lane = project?.project.transcriptLane(for: track, attachment: attachment)
                    guard (trackID == nil || track.id == trackID), laneID == nil || lane?.id == laneID else { return nil }
                    return (track, lane)
                }
                let displayed = trackID == nil ? Array(selected.dropFirst(page.offset).prefix(page.limit)) : selected
                let summaries = displayed.map { track, lane in
                    let binding = attachment?.bindings.first { $0.trackID == track.id }
                    let sourceStatus = project.map { loaded -> String in
                        guard let binding else { return TranscriptBindingStatus.unbound.rawValue }
                        let state = binding.sourceStatus(in: loaded.project, relativeTo: loaded.url)
                        guard state == .changed, track.streamEvidence != nil else { return state.rawValue }
                        let path: String?
                        let indexed: (URL) throws -> MediaInfo
                        switch loaded.project {
                        case let .multicam(multicam):
                            path = multicam.sources.first(where: { $0.id == binding.sourceID })?.file
                            indexed = engine.inspectMulticamSource
                        case .sequence, .stillSequence:
                            path = binding.file
                            indexed = { try engine.inspect($0, keyframes: true) }
                        }
                        guard let path, let url = try? CutProject.checkedMediaURL(path, relativeTo: loaded.url) else {
                            return state.rawValue
                        }
                        let media = cache[url] ?? (try? indexed(url))
                        cache[url] = media
                        return binding.sourceStatus(in: loaded.project, relativeTo: loaded.url,
                                                    track: track, indexedMedia: media).rawValue
                    }
                    let item = Track(id: track.id, name: track.name, coverage: track.coverage,
                                     activityFrames: track.activity.count,
                                     activity: trackID == nil ? nil : .init(track.activity, page: page),
                                     binding: binding, sourceStatus: sourceStatus, streamEvidence: track.streamEvidence,
                                     origin: track.origin, sessionStart: track.sessionStart, role: track.role,
                                     error: track.error, warning: track.warning)
                    return TranscriptLaneReadout(item, lane: lane)
                }
                let next = trackID == nil && summaries.count < selected.count - page.offset
                    ? page.offset + summaries.count : nil
                return TranscriptCLIPage(items: summaries, total: selected.count,
                                         nextOffset: next)
            }
            speakers = document.map { document in
                if let project, case let .multicam(multicam) = project.project, !multicam.mixLanes.isEmpty,
                   let index = try? TranscriptIndex(document: document, attachment: attachment, project: project.project,
                                                    projectURL: project.url, records: project.project.transcripts.authoring,
                                                    spaces: [.source]) {
                    return TranscriptCLIPage(index.transcriptSpeakerReadouts(project: project.project, laneID: laneID), page: page)
                }
                return TranscriptCLIPage(laneID == nil ? document.speakers.map { .init($0, lane: nil) } : [], page: page)
            }
            self.status = status
        }


    }
}

private struct TranscriptCLIPlan: Codable {
    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case revision
        case request
        case action
        case historyAction = "history_action"
        case selections
        case boundaries
        case affectedOccurrences = "affected_occurrences"
        case previousDuration = "previous_duration"
        case duration
        case requestedRetainedDuration = "requested_retained_duration"
        case retainedDuration = "retained_duration"
        case previousTier = "previous_tier"
        case tier
        case projectDigest = "project_digest"
        case attachmentResults = "attachment_results"
        case affectedSpeech = "affected_speech"
        case unavailableEvidenceAttachmentIDs = "unavailable_evidence_attachment_ids"
    }
    let attachmentID: String
    let revision: TranscriptEditRevision
    let request: TranscriptEditRequest
    let action: TranscriptEditRequest.Action
    let historyAction: String
    let selections: [TranscriptResolvedSelection]
    let boundaries: [TranscriptEditBoundary]
    let affectedOccurrences: [String]
    let previousDuration: RationalTime
    let duration: RationalTime
    let requestedRetainedDuration: RationalTime?
    let retainedDuration: RationalTime?
    let previousTier: TierSummary?
    let tier: TierSummary?
    let projectDigest: String
    let attachmentResults: [String: String]
    let affectedSpeech: [TranscriptOccurrence]
    let unavailableEvidenceAttachmentIDs: [String]

    init(_ plan: TranscriptEditPlan, request: TranscriptEditRequest, attachmentID: String, project: CutProject) throws {
        self.attachmentID = attachmentID
        self.request = request
        revision = plan.revision
        action = plan.action
        historyAction = plan.historyAction
        selections = plan.selections
        boundaries = plan.boundaries
        affectedOccurrences = plan.affectedOccurrences
        previousDuration = plan.previousDuration
        duration = plan.duration
        requestedRetainedDuration = plan.requestedRetainedDuration
        retainedDuration = plan.retainedDuration
        previousTier = plan.previousTier
        tier = plan.tier
        attachmentResults = plan.attachmentResults
        affectedSpeech = plan.affectedSpeech
        unavailableEvidenceAttachmentIDs = plan.unavailableEvidenceAttachmentIDs
        projectDigest = try SHA256.hash(data: transcriptJSON(project)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension TranscriptCLIRequest {
    func format(path: String? = nil, default fallback: TranscriptFormat = .json) throws -> TranscriptFormat {
        if let format = try optional("format", String.self) {
            guard let value = TranscriptFormat(rawValue: format) else {
                throw CLIError("invalid_arguments", "Use json, srt, vtt, or text format.")
            }
            return value
        }
        let ext = path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
        return ext == "txt" ? .text : ext.flatMap(TranscriptFormat.init(rawValue:)) ?? fallback
    }

    func wordSelection() throws -> TranscriptWordSelection {
        if let selection = try optional("selection", TranscriptWordSelection.self) { return selection }
        return try .init(firstWordID: required("first_word_id"), lastWordID: optional("last_word_id"),
                         space: space(default: .currentCut), firstOccurrenceID: optional("first_occurrence_id"),
                         lastOccurrenceID: optional("last_occurrence_id"), kind: optional("kind") ?? .phrase,
                         leadingPadding: time("leading_padding"), trailingPadding: time("trailing_padding"))
    }

    func editRequest(queue: Bool) throws -> TranscriptEditRequest {
        if let request = try optional("request", TranscriptEditRequest.self) { return request }
        return try .init(action: queue ? .queue : required("action"), selections: [wordSelection()],
                         position: time("position"), retainedDuration: time("retained_duration"), angleID: optional("angle_id"),
                         name: optional("name"), boundaryPolicy: optional("boundary_policy") ?? .nearestFrame,
                         edge: optional("edge"), startFrameNudge: optional("start_frame_nudge"), endFrameNudge: optional("end_frame_nudge"))
    }
}

extension TranscriptCLI {
    func run(json: Bool, useSidecar: Bool, interruption: Interruption) throws {
        let writeSidecar = useSidecar && [.runJob, .prepareSession, .retry, .import].contains(operation)
        try AnalysisSidecar.$automaticWritesEnabled.withValue(writeSidecar) {
            try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                let input = try request(interruption: interruption)
                try SidecarLocations.$projectURL.withValue(try input.url("project_path")) {
                    try run(input, json: json, interruption: interruption)
                }
            }
        }
    }

    private func run(_ request: TranscriptCLIRequest, json: Bool, interruption: Interruption) throws {
        func reply<T: Encodable>(_ value: T, committed: Bool = false) throws {
            try writeJSON(value, pretty: !json, checkCancellation: !committed)
        }
        try interruption.check()
        switch operation {
        case .capabilities, .tracks, .prepareSession, .status, .cancel, .retry, .runJob:
            try runJob(request, json: json, interruption: interruption)
            return
        case .import:
            try runImport(request, json: json, interruption: interruption)
            return
        case .inspect:
            let page = try request.page()
            let trackID = try request.optional("track_id", String.self)
            let laneID = try request.optional("lane_id", String.self)
            if let raw = try request.optional("transcript", String.self) {
                guard try request.url("project_path") == nil else {
                    throw CLIError("invalid_arguments", "Choose either --transcript FILE or --project FILE.")
                }
                let document = try TranscriptCodec.decode(readTranscriptFile(raw, interruption: interruption),
                                                          format: request.format(path: raw), origin: request.time("origin"))
                try reply(TranscriptCLIInspection(project: nil, revision: nil,
                                                  attachments: [.init(document: document, at: page, trackID: trackID, laneID: laneID,
                                                                      interruption: interruption)], nextOffset: nil))
                return
            }
            let loaded = try loadProject(request)
            let id = try request.optional("attachment_id", String.self)
            // Attachment IDs and per-document evidence use the same page size.
            let attachments = id == nil ? loaded.project.transcripts.attachments : [try loaded.attachment(id)]
            let pageAttachments = id == nil && trackID == nil
            let selected = pageAttachments ? Array(attachments.dropFirst(page.offset).prefix(page.limit)) : attachments
            let result = selected.map { attachment -> TranscriptCLIInspection.Entry in
                do {
                    let document = try loaded.document(attachment)
                    return .init(attachment: attachment, document: document, at: pageAttachments ? (0, page.limit) : page,
                                 project: loaded, trackID: trackID, laneID: laneID, interruption: interruption)
                } catch let error as CutError {
                    return .init(attachment: attachment, status: error.code, at: page, interruption: interruption)
                } catch {
                    return .init(attachment: attachment, status: "transcript_unavailable", at: page, interruption: interruption)
                }
            }
            let next = pageAttachments && result.count < attachments.count - page.offset
                ? page.offset + result.count : nil
            try interruption.check()
            try reply(TranscriptCLIInspection(project: loaded.url.path, revision: loaded.project.transcripts.revision,
                                              attachments: result, nextOffset: next,
                                              authoring: .init(loaded.project.transcripts.authoring, page: page)))
            return
        default: break
        }

        let loaded = try loadProject(request)
        let reviewed = try reviewedPlan(request, interruption: interruption)
        let requestedID = try request.optional("attachment_id", String.self)
        if let reviewed, let requestedID, reviewed.attachmentID != requestedID {
            throw CutError(code: "stale_transcript_plan", message: "The reviewed plan names a different transcript attachment.")
        }
        let readOperations: Set<Operation> = [.read, .search, .locate, .compare, .alignScript, .suggest, .export]
        if readOperations.contains(operation) {
            try runRead(request, loaded: loaded, attachmentID: requestedID, json: json, interruption: interruption)
            return
        }

        let primaryID: String?
        if let requestedID {
            primaryID = requestedID
        } else if let reviewed {
            primaryID = reviewed.attachmentID
        } else if let edit = try request.optional("request", TranscriptEditRequest.self) {
            primaryID = edit.selections.first?.attachmentID ?? edit.target?.attachmentID
        } else if let selection = try request.optional("selection", TranscriptWordSelection.self) {
            primaryID = selection.attachmentID
        } else if let record = try request.optional("record", TranscriptAuthoredRecord.self) {
            primaryID = record.attachmentID
        } else {
            primaryID = nil
        }
        let attachment: TranscriptAttachment
        do {
            attachment = try loaded.attachment(primaryID)
        } catch where reviewed != nil {
            throw CutError(code: "stale_transcript_plan", message: "The reviewed transcript attachment is unavailable.")
        }
        if operation == .detach {
            let destination = try loaded.destination(request)
            var updated = loaded.project
            updated.transcripts.attachments.removeAll { $0.id == attachment.id }
            try updated.transcripts.advanceRevision()
            try loaded.save(updated, to: destination, interruption: interruption)
            try reply(TranscriptCLIResult(project: destination.url.path), committed: true)
            return
        }

        if let reviewed, try loaded.revision(attachment) != reviewed.revision {
            throw CutError(code: "stale_transcript_plan", message: "The project or transcript changed after the edit was reviewed.")
        }
        let document = try loaded.document(attachment)
        if operation == .bind {
            let destination = try loaded.destination(request)
            let origin = try request.time("origin")
            var updatedAttachment = attachment
            updatedAttachment.bindings = try loaded.bindings(request, document: document, original: attachment.bindings,
                                                              interruption: interruption)
            if request.values.keys.contains("origin") { updatedAttachment.importOrigin = origin }
            var updated = loaded.project
            if updatedAttachment != attachment {
                updated.transcripts.attachments = updated.transcripts.attachments.map { $0.id == attachment.id ? updatedAttachment : $0 }
                try updated.transcripts.advanceRevision()
            }
            try loaded.save(updated, to: destination, interruption: interruption)
            let saved = try TranscriptCLIProject(url: destination.url)
            try reply(TranscriptCLIResult(project: destination.url.path, attachment: try saved.attachment(attachment.id)),
                      committed: true)
            return
        }

        let space = try request.space(default: .currentCut)
        let buildSpace: TranscriptSpace = [.plan, .apply, .queue, .select, .correct, .locate].contains(operation) ? .currentCut : space
        let media = try loaded.indexMedia(forSpace: buildSpace, interruption: interruption)
        let index = try loaded.index(document: document, attachment: attachment, media: media, spaces: indexSpaces(request))
        switch operation {
        case .select:
            try reply(TranscriptEditPlanner.select(request.wordSelection(), in: index))
        case .plan, .apply, .queue, .correct:
            try runEdit(request, loaded: loaded, attachment: attachment, index: index, media: media, reviewed: reviewed,
                        json: json, interruption: interruption)
        default:
            preconditionFailure("Operation handled before indexing")
        }
    }

    /// The transcript views an operation consults. Resolving a selection reads the view it
    /// names, and a correction also anchors it in Source. Planning an edit reads all three.
    /// A request that cannot be read here keeps every view, and fails where it is used.
    private func indexSpaces(_ request: TranscriptCLIRequest) -> Set<TranscriptSpace> {
        let all = Set(TranscriptSpace.allCases)
        let single = request.values["selection"] != nil || request.values["first_word_id"] != nil
        switch operation {
        case .select:
            return (try? request.wordSelection()).map { [$0.space] } ?? all
        case .correct:
            let selections: [TranscriptWordSelection]?
            if request.values["record"] != nil {
                selections = []
            } else if request.values["selections"] != nil {
                selections = try? request.optional("selections", [TranscriptWordSelection].self)
            } else {
                selections = single ? (try? request.wordSelection()).map { [$0] } : []
            }
            return selections.map { Set($0.map(\.space)).union([.source]) } ?? all
        default:
            return all
        }
    }

    private func runRead(_ request: TranscriptCLIRequest, loaded: TranscriptCLIProject, attachmentID: String?,
                         json: Bool, interruption: Interruption) throws {
        let attachments = try attachmentID.map { [try loaded.attachment($0)] } ?? loaded.project.transcripts.attachments
        guard !attachments.isEmpty else {
            throw CutError(code: "transcript_attachment_missing", message: "No matching transcript attachment.")
        }
        let space = try request.space(default: .currentCut)
        let filter = try request.filter()
        // Source and Group reads both report input coverage, which needs each bound recording's bounds.
        let sourceCoveragePaths: Set<String> = operation == .read && space != .currentCut ? Set(attachments.flatMap { attachment in
            attachment.bindings.filter { filter.trackID == nil || filter.trackID == $0.trackID }.compactMap(\.file)
        }) : []
        let media = try loaded.indexMedia(forSpace: space, sequenceCoveragePaths: sourceCoveragePaths,
                                          interruption: interruption)
        var spaces: Set<TranscriptSpace> = [.read, .search, .locate].contains(operation) ? [space] : Set(TranscriptSpace.allCases)
        if operation == .read, case let .multicam(multicam) = loaded.project, !multicam.mixLanes.isEmpty {
            spaces.insert(.source)
        }
        let indexes = try attachments.map { attachment in
            try interruption.check()
            return try loaded.index(document: loaded.document(attachment), attachment: attachment, media: media, spaces: spaces)
        }
        let index = TranscriptProjectIndex(indexes: indexes, space: space)
        if let expected = try request.optional("expected_attachment_results", [String: String].self),
           expected != index.attachmentResults {
            throw CutError(code: "stale_transcript_result", message: "The attachment results changed after the previous read.")
        }
        let page = try request.page()
        let occurrenceID = try request.optional("occurrence_id", String.self)
        switch operation {
        case .read:
            let occurrences: TranscriptCLIPage<TranscriptOccurrence>
            if let occurrenceID {
                occurrences = .init(index.occurrence(id: occurrenceID, filter: filter).map { [$0] } ?? [], page: page)
            } else {
                let selected = index.read(filter: filter, offset: page.offset, limit: page.limit)
                occurrences = .init(items: selected.items, total: selected.total, nextOffset: selected.nextOffset)
            }
            let revision = try attachments.count == 1 ? loaded.revision(attachments[0]) : nil
            let inputCoverage = space == .currentCut ? nil : try index.inputCoverage(filter: filter, offset: page.offset,
                                                                                     limit: page.limit)
            let speakers = indexes.flatMap {
                $0.transcriptSpeakerReadouts(project: loaded.project, laneID: filter.laneID)
            }
            let gaps = space == .currentCut ? index.gaps.filter { filter.laneID == nil || $0.laneID == filter.laneID } : []
            let result = TranscriptCLIRead(items: occurrences.items, total: occurrences.total, nextOffset: occurrences.nextOffset,
                                           space: space, revision: revision, attachmentResults: index.attachmentResults,
                                           speakers: TranscriptCLIPage(speakers, page: page),
                                           coverageGaps: TranscriptCLIPage(gaps, page: page),
                                           inputCoverage: inputCoverage,
                                           authoring: TranscriptCLIPage(indexes.flatMap(\.authoredReview), page: page))
            try writeJSON(result, pretty: !json)
        case .search:
            let query = try request.required("query", String.self)
            let response = index.search(query, filter: filter, offset: page.offset, limit: page.limit)
            try writeJSON(TranscriptCLIPage(items: response.items, total: response.total, nextOffset: response.nextOffset,
                                            attachmentResults: index.attachmentResults), pretty: !json)
        case .locate:
            let wordID = try request.optional("word_id", String.self)
            let locations: [TranscriptOccurrence]
            if let occurrenceID {
                locations = index.occurrence(id: occurrenceID, filter: filter).flatMap { occurrence in
                    wordID == nil || occurrence.wordID == wordID ? [occurrence] : nil
                } ?? []
            } else if let wordID {
                locations = index.locate(wordID: wordID, filter: filter)
            } else {
                throw CLIError("invalid_arguments", "Specify --word ID or --occurrence ID.")
            }
            try writeJSON(TranscriptCLIPage(locations, page: page, attachmentResults: index.attachmentResults), pretty: !json)
        default:
            try runEditorial(request, project: loaded, indexes: indexes, words: index.readAll(filter: filter),
                             space: space, filter: filter, page: page, json: json, interruption: interruption)
        }
    }

    private func loadProject(_ request: TranscriptCLIRequest) throws -> TranscriptCLIProject {
        guard let url = try request.url("project_path") else {
            throw CLIError("invalid_arguments", "Specify --project FILE.")
        }
        return try TranscriptCLIProject(url: url)
    }

    private func reviewedPlan(_ request: TranscriptCLIRequest, interruption: Interruption) throws -> TranscriptCLIPlan? {
        if let path = try request.optional("plan_file", String.self) {
            guard request.values["plan"] == nil else {
                throw CLIError("invalid_arguments", "Use plan or --plan-file FILE.")
            }
            let data = try readFile(path, label: "Transcript plan", interruption: interruption)
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
                throw CLIError("invalid_json", "Expected a UTF-8 transcript plan.")
            }
            if let issue = jsonInputIssue(data) {
                throw CLIError("invalid_json", "Transcript plan \(issue).")
            }
            do { return try JSONDecoder().decode(TranscriptCLIPlan.self, from: data) }
            catch { throw CLIError("invalid_json", "Expected a transcript plan from mpcut transcript plan.") }
        }
        return try request.optional("plan")
    }

    private func runEdit(_ request: TranscriptCLIRequest, loaded: TranscriptCLIProject, attachment: TranscriptAttachment,
                         index: TranscriptIndex, media: TranscriptCLIProject.IndexMedia, reviewed: TranscriptCLIPlan?,
                         json: Bool, interruption: Interruption) throws {
        let revision = try loaded.revision(attachment)
        if operation == .correct {
            let destination = try loaded.destination(request)
            if let expected = try request.optional("revision", TranscriptEditRevision.self), expected != revision {
                throw CutError(code: "stale_transcript_plan", message: "The project or transcript changed before the correction.")
            }
            // A caller that names the record can send the same correction again after a lost
            // reply: the second request finds the record it already saved and changes nothing.
            let recordID = try request.optional("record_id", String.self)
            let record: TranscriptAuthoredRecord
            if let supplied = try request.optional("record", TranscriptAuthoredRecord.self) {
                guard recordID == nil || recordID == supplied.id else {
                    throw CLIError("invalid_arguments", "record_id names a different record than the one supplied.")
                }
                record = supplied
            } else {
                let change = try request.required("change", TranscriptAuthoredChange.self)
                let selections: [TranscriptWordSelection]
                if let supplied = try request.optional("selections", [TranscriptWordSelection].self) {
                    selections = supplied
                } else if request.values["selection"] != nil || request.values["first_word_id"] != nil {
                    selections = [try request.wordSelection()]
                } else {
                    selections = []
                }
                record = try TranscriptEditorial.makeRecord(change: change, selections: selections, in: index,
                                                            id: recordID ?? ProjectIdentifier.make())
            }
            try record.validate()
            guard record.attachmentID == attachment.id else {
                throw CutError(code: "invalid_transcript_authoring", message: "Choose the attachment named in the correction.")
            }
            var updated = loaded.project
            let change: CutHistoryState?
            let existing = updated.transcripts.authoring.firstIndex { $0.id == record.id }
            if let existing, updated.transcripts.authoring[existing] == record {
                change = nil
            } else {
                if let existing { updated.transcripts.authoring[existing] = record }
                else { updated.transcripts.authoring.append(record) }
                try updated.transcripts.advanceRevision()
                change = .init(action: record.change.historyAction, project: loaded.project)
            }
            try loaded.save(updated, to: destination, change: change, interruption: interruption)
            let saved = try TranscriptCLIProject(url: destination.url)
            let result = TranscriptCLIResult(project: destination.url.path, revision: try saved.revision(saved.attachment(attachment.id)),
                                             historyAction: change?.action)
            try writeJSON(result, pretty: !json, checkCancellation: false)
            return
        }

        if operation == .apply, reviewed == nil {
            throw CLIError("invalid_arguments", "Supply a reviewed plan with --plan-file FILE or the plan JSON field.")
        }
        guard reviewed == nil || request.values["request"] == nil else {
            throw CLIError("invalid_arguments", "Supply a reviewed plan or a new request.")
        }
        let edit = try reviewed?.request ?? request.editRequest(queue: operation == .queue)
        guard operation != .queue || (edit.action == .queue && !(edit.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw CLIError("invalid_arguments", "Provide a queue request and a name for the excerpt.")
        }
        let selectedAttachments = Set((edit.selections + [edit.target].compactMap { $0 }).compactMap(\.attachmentID))
        var additionalIndexes = try selectedAttachments.subtracting([attachment.id]).sorted().map { id in
            let extra = try loaded.attachment(id)
            let document = try loaded.document(extra)
            return try loaded.index(document: document, attachment: extra, media: media)
        }
        if edit.action.reviewsRemovedSpeech {
            let optional = loaded.project.transcripts.attachments.filter {
                $0.id != attachment.id && !selectedAttachments.contains($0.id)
            }
            for asset in optional {
                try interruption.check()
                if let document = try? loaded.document(asset),
                   let index = try? loaded.index(document: document, attachment: asset, media: media) {
                    additionalIndexes.append(index)
                }
            }
        }
        let plan = try TranscriptEditPlanner.plan(edit, in: index, project: loaded.project, revision: revision,
                                                relativeTo: loaded.url, sequenceMedia: media.sequence,
                                                multicamMedia: media.multicam, additionalIndexes: additionalIndexes)
        let report = try TranscriptCLIPlan(plan, request: edit, attachmentID: attachment.id, project: loaded.project)
        if let reviewed, try transcriptJSON(reviewed) != transcriptJSON(report) {
            throw CutError(code: "stale_transcript_plan", message: "The project or resolved boundaries changed after review.")
        }
        if operation == .plan {
            if let output = try request.url("output") {
                try loaded.media.validateDestination(output, relativeTo: loaded.url)
                guard loaded.media.diskRevision?.matchesDestination(output) != true else {
                    throw CLIError("invalid_arguments", "Use a separate plan output file.")
                }
                try publish(try transcriptJSON(report), to: output, interruption: interruption)
            }
            try writeJSON(report, pretty: !json)
            return
        }
        let destination = try loaded.destination(request, queueName: operation == .queue ? edit.name : nil)
        let result: TranscriptCLIResult
        if operation == .queue {
            var snapshot = plan.snapshot
            snapshot.transcripts = loaded.project.transcripts
            try loaded.save(snapshot, to: destination, snapshot: true, interruption: interruption)
            result = .init(project: destination.url.path, name: edit.name)
        } else {
            let commit = try plan.apply(to: loaded.project, revision: revision)
            try loaded.save(commit.project, to: destination, change: commit.undo, interruption: interruption)
            let saved = try TranscriptCLIProject(url: destination.url)
            result = try .init(project: destination.url.path, revision: saved.revision(saved.attachment(attachment.id)),
                               historyAction: commit.undo?.action)
        }
        try writeJSON(result, pretty: !json, checkCancellation: false)
    }

    private func publish(_ data: Data, to output: URL, interruption: Interruption) throws {
        try interruption.check()
        let staging = output.deletingLastPathComponent().appendingPathComponent(".mpcut-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: [.withoutOverwriting])
        try interruption.check()
        let result = publishExclusively(from: staging, to: output)
        if result == EEXIST {
            throw CutError(code: "output_exists", message: "Output already exists at \(output.path).")
        }
        if result != 0 {
            throw CutError(code: "transcript_write_failed", message: String(cString: strerror(result)))
        }
    }

}

private extension TranscriptCLI {
    func runJob(_ request: TranscriptCLIRequest, json: Bool, interruption: Interruption) throws {
        if operation == .capabilities {
            let helper = try TranscriptJobStore.helperURL()
            let data = try TranscriptJobStore.capabilities(helper: helper, cancelled: { !interruption.isActive })
            try interruption.beginResponse()
            try writeOutput(data + (data.last == 10 ? Data() : Data([10])))
            return
        }

        let store = try jobStore(request)
        let progressMode = try MediaProgressOutput(option: request.optional("progress"))
        func progress(_ record: TranscriptJobRecord) {
            guard progressMode != .none else { return }
            let tracks = record.sessions.flatMap(\.tracks)
            let staged = tracks.filter { $0.state != .pending }.count
            if progressMode == .jsonl {
                let event: TranscriptProgress = .init(jobID: record.id, state: record.state, tracks: tracks.count, staged: staged)
                if let data = try? transcriptJSON(event) { progressOutput(String(decoding: data, as: UTF8.self)) }
            } else {
                progressOutput("Transcript \(record.state.rawValue) (\(staged)/\(tracks.count) tracks)")
            }
        }
        switch operation {
        case .runJob, .status, .cancel, .retry:
            let id = try request.required("job_id", UUID.self)
            switch operation {
            case .runJob:
                let download = try request.optional("download", Bool.self) ?? false
                let record = try store.status(id)
                // Recognition can update analysis caches. Honor the same protected media paths as preparation.
                let owner = URL(fileURLWithPath: record.documentID)
                var excluded = AnalysisSidecar.excludedSources
                if owner.pathExtension.lowercased() == "cut" {
                    if let media = try? CutProjectMedia.load(from: owner) {
                        excluded.formUnion(media.sidecarExclusions(relativeTo: owner))
                    } else {
                        excluded.formUnion(record.sessions.flatMap(\.tracks).map(\.file))
                    }
                }
                let result = try AnalysisSidecar.$excludedSources.withValue(excluded) {
                    try store.run(id, download: download, interrupted: { !interruption.isActive }, progress: progress)
                }
                switch result.state {
                case .completed, .partial: try writeJSON(result, pretty: !json)
                case .cancelled, .interrupted: throw CancellationError()
                default:
                    throw CutError(code: "transcript_job_" + result.state.rawValue,
                                   message: result.message ?? "Inspect transcription job " + id.uuidString + " before retrying.")
                }
            case .status: try writeJSON(store.status(id), pretty: !json)
            case .cancel:
                let job = try store.cancel(id)
                let receipt = !job.attached && [.completed, .partial].contains(job.state)
                    ? try store.cancelPendingAttachment(id, expectedPreparationID: job.preparationID) : job
                try writeJSON(receipt, pretty: !json, checkCancellation: false)
            case .retry:
                let record: TranscriptJobRecord
                if let project = try request.url("project_path") {
                    let loaded = try TranscriptCLIProject(url: project)
                    let job = try store.status(id)
                    let sameOwner = job.documentIdentity != nil && job.documentIdentity == loaded.project.transcripts.documentID
                    guard sameOwner || (job.documentIdentity == nil && job.documentID == project.resolvingSymlinksInPath().path) else {
                        throw CutError(code: "transcript_operation_conflict", message: "This job belongs to another project.")
                    }
                    record = try AnalysisSidecar.$excludedSources.withValue(
                        AnalysisSidecar.excludedSources.union(loaded.media.sidecarExclusions(relativeTo: project))
                    ) {
                        try store.retry(id, project: loaded.project, relativeTo: project,
                                        cancelled: { !interruption.isActive }, progress: progress)
                    }
                } else {
                    record = try store.retry(id, cancelled: { !interruption.isActive }, progress: progress)
                }
                try writeJSON(TranscriptPreparation(record), pretty: !json)
            default: preconditionFailure()
            }
        case .tracks, .prepareSession:
            let project = try request.url("project_path")
            let media = try request.url("file")
            guard (project != nil) != (media != nil) else {
                throw CLIError("invalid_arguments", "Choose either --project FILE or --file MEDIA.")
            }
            let options = try jobOptions(request)
            let laneID = try request.optional("lane_id", String.self)
            let operationID = try request.optional("operation_id", UUID.self) ?? UUID()
            let policy = try request.optional("policy", TranscriptJobPolicy.self) ?? .reuse
            if let project {
                let loaded = try TranscriptCLIProject(url: project)
                try AnalysisSidecar.$excludedSources.withValue(
                    AnalysisSidecar.excludedSources.union(loaded.media.sidecarExclusions(relativeTo: project))
                ) {
                    if operation == .tracks {
                        let sessions = try TranscriptJobPlan.inventory(project: loaded.project, relativeTo: project, options: options)
                        let inventory = sessions.map { TrackInventory.Session($0, project: loaded.project, laneID: laneID) }
                        try writeJSON(TrackInventory(sessions: inventory), pretty: !json)
                    } else {
                        let record = try store.prepare(project: loaded.project, documentID: project.resolvingSymlinksInPath().path,
                                                       relativeTo: project, documentIdentity: loaded.project.transcripts.documentID,
                                                       options: options, operationID: operationID,
                                                       policy: policy, cancelled: { !interruption.isActive }, progress: progress)
                        try writeJSON(TranscriptPreparation(record), pretty: !json)
                    }
                }
            } else if let media {
                if operation == .tracks {
                    let sessions = try TranscriptJobPlan.inventory(media: media, options: options)
                    let inventory = sessions.map { TrackInventory.Session($0, laneID: laneID) }
                    try writeJSON(TrackInventory(sessions: inventory), pretty: !json)
                } else {
                    let record = try store.prepare(media: media, documentID: media.resolvingSymlinksInPath().path,
                                                   options: options, operationID: operationID, policy: policy, cancelled: { !interruption.isActive }, progress: progress)
                    try writeJSON(TranscriptPreparation(record), pretty: !json)
                }
            }
        default: preconditionFailure()
        }
    }

    func jobOptions(_ request: TranscriptCLIRequest) throws -> TranscriptJobOptions {
        if let options = try request.optional("options", TranscriptJobOptions.self) {
            guard Set(request.values.keys).isDisjoint(with: ["engine", "model", "language", "expected_speakers",
                                                                  "diarization", "selected_tracks"]) else {
                throw CLIError("invalid_arguments", "Put all job options in options or pass them at the top level.")
            }
            return options
        }
        return try .init(engine: request.optional("engine"), model: request.optional("model"),
                         language: request.optional("language"), expectedSpeakers: request.optional("expected_speakers"),
                         diarization: request.optional("diarization"), selectedTracks: request.optional("selected_tracks"))
    }

    func jobStore(_ request: TranscriptCLIRequest) throws -> TranscriptJobStore {
        try .init(directory: request.url("job_directory", directory: true) ?? TranscriptJobStore.defaultDirectory)
    }

    func runImport(_ request: TranscriptCLIRequest, json: Bool, interruption: Interruption) throws {
        let savedProject = try request.url("project_path").map(TranscriptCLIProject.init)
        let media = savedProject == nil ? try request.url("file") : nil
        let raw = try request.optional("transcript", String.self)
        let jobID = try request.optional("job_id", UUID.self)
        guard (raw != nil) != (jobID != nil), savedProject != nil || media != nil else {
            throw CLIError("invalid_arguments", "Choose a project or media target and one transcript file or prepared job ID.")
        }
        let output = try request.url("output")
        let bareProject = savedProject == nil ? try request.url("out_project") : nil
        let bareMedia: MediaInfo?
        let loaded: TranscriptCLIProject?
        if let media {
            guard (output != nil) != (bareProject != nil), try request.optional("in_place", Bool.self) != true else {
                throw CLIError("invalid_arguments", "Choose --output FILE.json or --out-project FILE.cut for bare media.")
            }
            guard try request.optional("source_id", String.self) == nil else {
                throw CLIError("invalid_arguments", "A bare recording has one source. Choose its audio with --stream.")
            }
            let engine = CutEngine(cancelled: { !interruption.isActive })
            let indexed = try engine.inspect(media, keyframes: true)
            bareMedia = indexed
            loaded = try bareProject.map { try TranscriptCLIProject(indexed: indexed, destination: $0) }
        } else {
            guard output == nil else {
                throw CLIError("invalid_arguments", "Use --out-project FILE or --in-place when importing into a project.")
            }
            bareMedia = nil
            loaded = savedProject
        }
        let target = try loaded?.destination(request)
        let origin = try request.time("origin")
        var results: [(document: TranscriptDocument, session: TranscriptJobSession?)] = []
        let acknowledgement: (store: TranscriptJobStore, id: UUID, preparation: UUID?)?
        if let jobID {
            let store = try jobStore(request)
            let outputs: [TranscriptJobOutput]
            if let media {
                outputs = try store.verifiedDocuments(jobID, media: media)
            } else if let loaded {
                outputs = try AnalysisSidecar.$excludedSources.withValue(
                    AnalysisSidecar.excludedSources.union(loaded.media.sidecarExclusions(relativeTo: loaded.url))
                ) {
                    try store.verifiedDocuments(jobID, project: loaded.project, relativeTo: loaded.url)
                }
            } else { preconditionFailure() }
            let job = try store.status(jobID)
            for output in outputs {
                try interruption.check()
                guard output.preparationID == job.preparationID,
                      let session = job.sessions.first(where: {
                          $0.output == output.url && $0.fingerprint == output.document.fingerprint
                      }) else {
                    throw CutError(code: "stale_transcript_job", message: "The prepared session changed during import.")
                }
                results.append((output.document, session))
            }
            acknowledgement = (store, jobID, outputs.first?.preparationID)
        } else if let raw {
            acknowledgement = nil
            let bytes = try readTranscriptFile(raw, interruption: interruption)
            // The attachment stores its cue adjustment. Keep the original source timings in the asset.
            let document = try TranscriptCodec.decode(bytes, format: request.format(path: raw),
                                                      origin: loaded == nil ? origin : nil)
            results.append((document, nil))
        } else { preconditionFailure() }
        if let bareMedia {
            for i in results.indices {
                let entry = results[i]
                results[i].document = try validateBareImport(request, document: entry.document, media: bareMedia,
                                                             projectOutput: bareProject != nil, session: entry.session)
            }
        }
        var bindingValues = request.values
        if media != nil { bindingValues.removeValue(forKey: "file") }
        let bindingRequest = TranscriptCLIRequest(values: bindingValues)
        if let loaded, let target {
            let requestedID = try request.optional("attachment_id", String.self)
            guard requestedID == nil || results.count == 1 else {
                throw CLIError("invalid_arguments", "Each prepared session has its own attachment ID.")
            }
            var updated = loaded.project
            var attachmentIDs: [String] = []
            var newAssets: [TranscriptAsset: Data] = [:]
            for (document, session) in results {
                let id = requestedID ?? session?.id ?? ProjectIdentifier.make(avoiding: updated.transcripts.attachments.map(\.id))
                let previous = updated.transcripts.attachments.first { $0.id == id }
                if let session, session.tracks.contains(where: { !$0.sourceIsCurrent }) {
                    throw CutError(code: "stale_transcript_job", message: "A recording changed before its prepared result could be saved.")
                }
                let verified = session?.bindings
                let bindings = try loaded.bindings(bindingRequest, document: document, original: verified ?? previous?.bindings ?? [],
                                                   interruption: interruption)
                let bytes = try TranscriptCodec.encodeStored(document)
                let file = TranscriptStore.reference(for: bytes, relativeTo: target.url)
                newAssets[file] = bytes
                let attachment = TranscriptAttachment(id: id, asset: file, bindings: bindings,
                                                      importOrigin: request.values.keys.contains("origin") ? origin : previous?.importOrigin,
                                                      fingerprint: document.fingerprint)
                if let index = updated.transcripts.attachments.firstIndex(where: { $0.id == id }) {
                    updated.transcripts.attachments[index] = attachment
                } else {
                    updated.transcripts.attachments.append(attachment)
                }
                attachmentIDs.append(id)
            }
            if updated != loaded.project { try updated.transcripts.advanceRevision() }
            try loaded.save(updated, to: target, assetData: newAssets, interruption: interruption) {
                guard let acknowledgement else { return }
                let job = try acknowledgement.store.status(acknowledgement.id)
                guard job.preparationID == acknowledgement.preparation, [.completed, .partial].contains(job.state),
                      results.compactMap(\.session).flatMap(\.tracks).allSatisfy(\.sourceIsCurrent) else {
                    throw CutError(code: "stale_transcript_job", message: "The transcript job or a recording changed before the project could be saved.")
                }
            }
            var warnings: [String] = []
            if let acknowledgement {
                do {
                    _ = try acknowledgement.store.markAttached(acknowledgement.id, expectedPreparationID: acknowledgement.preparation)
                } catch {
                    warnings.append("The project was saved. The job could not acknowledge the attachment. \(error.localizedDescription)")
                }
            }
            let saved = try TranscriptCLIProject(url: target.url)
            let attachments = try attachmentIDs.map { try saved.attachment($0) }
            var unbound: [String] = []
            for (attachment, result) in zip(attachments, results) {
                let bound = Set(attachment.bindings.map(\.trackID))
                unbound += result.document.tracks.filter { $0.coverage != .coverageOnly && !bound.contains($0.id) }.map(\.id)
            }
            let result = TranscriptImportReport(project: target.url.path, attachment: attachments.first,
                                                attachments: attachments, revision: saved.project.transcripts.revision,
                                                unboundTracks: unbound, warnings: warnings)
            try writeJSON(result, pretty: !json, checkCancellation: false)
        } else if let first = results.first, let output {
            guard results.count == 1, output.pathExtension.lowercased() == "json" else {
                throw CLIError("invalid_arguments", "A bare-media JSON import needs one transcript and --output FILE.json.")
            }
            try publish(try TranscriptCodec.encode(first.document, format: .json), to: output, interruption: interruption)
            try writeJSON(TranscriptCLIResult(output: output.path), pretty: !json, checkCancellation: false)
        }
    }

    func validateBareImport(_ request: TranscriptCLIRequest, document: TranscriptDocument, media: MediaInfo,
                            projectOutput: Bool, session: TranscriptJobSession?) throws -> TranscriptDocument {
        let trackID = try request.optional("track_id", String.self)
        let streamIndex = try request.optional("audio_stream_index", Int.self)
        let channel = try request.optional("channel", Int.self)
        if request.values["bindings"] != nil {
            guard projectOutput else {
                throw CLIError("invalid_arguments", "Use --out-project to save explicit transcript bindings.")
            }
            // The editable-project importer validates each explicit binding against the recording.
            return document
        }
        let eligible = document.tracks.filter { $0.coverage != .coverageOnly && (trackID == nil || $0.id == trackID) }
        if trackID != nil && eligible.isEmpty {
            throw CutError(code: "transcript_track_missing", message: "No matching audio track in the transcript.")
        }
        if streamIndex != nil || channel != nil {
            guard eligible.count == 1 else {
                throw CLIError("invalid_arguments", "Choose --track-id ID before assigning a stream or channel.")
            }
        }
        var validated = document
        let bindings = Dictionary(uniqueKeysWithValues: (session?.bindings ?? []).map { ($0.trackID, $0) })
        let ids = Set(eligible.map(\.id))
        for i in document.tracks.indices where ids.contains(document.tracks[i].id) {
            let track = document.tracks[i]
            let boundStream = bindings[track.id]?.streamIndex ?? track.streamIndex
            guard let stream = streamIndex ?? boundStream ?? media.audio.first?.stream.index,
                  let audio = media.audio.first(where: { $0.stream.index == stream }) else {
                throw CutError(code: "transcript_stream_missing", message: "Choose an available audio stream on this recording.")
            }
            let selectedChannel = channel ?? track.channel
            if let selectedChannel, !(0..<audio.stream.channels).contains(selectedChannel) {
                throw CutError(code: "transcript_stream_missing", message: "Choose an available audio channel on this recording.")
            }
            if session != nil, (boundStream != stream || track.channel != selectedChannel) {
                throw CutError(code: "invalid_transcript_binding", message: "The prepared result identifies a different audio stream or channel.")
            }
            if !projectOutput && session == nil {
                validated.tracks[i].streamIndex = stream
                validated.tracks[i].channel = selectedChannel
            }
        }
        return validated
    }
}

private struct TrackInventory: Encodable {
    let sessions: [Session]

    struct Session: Encodable {
        private enum CodingKeys: String, CodingKey {
            case id
            case fingerprint
            case tracks
            case recognitionDurationSeconds = "recognition_duration_seconds"
        }
        let id: String
        let fingerprint: String
        let tracks: [TranscriptLaneReadout<TranscriptJobTrack>]
        let recognitionDurationSeconds: Double

        init(_ session: TranscriptJobSession, project: CutProject? = nil, laneID: String?) {
            id = session.id
            fingerprint = session.fingerprint
            tracks = session.tracks.compactMap { track in
                let lane = project?.transcriptLane(for: track)
                guard laneID == nil || lane?.id == laneID else { return nil }
                return .init(track, lane: lane)
            }
            recognitionDurationSeconds = tracks.reduce(0) { $0 + ($1.item.recognize ? $1.item.duration.seconds : 0) }
        }
    }
}

private struct TranscriptProgress: Encodable {
    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state
        case tracks
        case staged
    }
    let jobID: UUID
    let state: TranscriptJobState
    let tracks: Int
    let staged: Int
}

private struct TranscriptPreparation: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case state
        case workingDirectory = "working_directory"
        case sessions
        case warnings
    }
    let id: UUID
    let state: TranscriptJobState
    let workingDirectory: String
    let sessions: [Session]
    let warnings: [String]

    struct Session: Encodable {
        private enum CodingKeys: String, CodingKey {
            case id
            case fingerprint
            case manifest
            case output
            case command
            case tracks
            case recognitionDurationSeconds = "recognition_duration_seconds"
        }
        let id: String
        let fingerprint: String
        let manifest: String
        let output: String
        let command: [String]
        let tracks: [TranscriptJobTrack]
        let recognitionDurationSeconds: Double
    }

    init(_ job: TranscriptJobRecord) {
        id = job.id
        state = job.state
        workingDirectory = job.workingDirectory.path
        warnings = job.warnings
        let helper = (try? TranscriptJobStore.helperURL().path) ?? "transcriberrr"
        sessions = job.sessions.map { session in
            .init(id: session.id, fingerprint: session.fingerprint, manifest: session.manifest.path,
                  output: session.output.path, command: [helper, "session", "--manifest", session.manifest.path, "--offline", "--jsonl"],
                  tracks: session.tracks, recognitionDurationSeconds: session.recognitionDurationSeconds)
        }
    }
}

private struct TranscriptImportReport: Encodable {
    private enum CodingKeys: String, CodingKey {
        case ok
        case project = "project_path"
        case attachment
        case attachments
        case revision
        case unboundTracks = "unbound_tracks"
        case warnings
    }
    let ok = true
    let project: String
    let attachment: TranscriptAttachment?
    let attachments: [TranscriptAttachment]
    let revision: UInt64
    let unboundTracks: [String]
    let warnings: [String]
}

private extension TranscriptCLI {
    func runEditorial(_ request: TranscriptCLIRequest, project: TranscriptCLIProject,
                      indexes: [TranscriptIndex], words: [TranscriptOccurrence], space: TranscriptSpace, filter: TranscriptFilter,
                      page: (offset: Int, limit: Int), json: Bool, interruption: Interruption) throws {
        switch operation {
        case .compare:
            let phrase = try request.required("query", String.self)
            let context = try request.optional("context_words", Int.self) ?? 8
            guard (0...100).contains(context) else {
                throw CLIError("invalid_arguments", "Specify between 0 and 100 context words.")
            }
            let takes = TranscriptEditorial.compare(phrase, words: words, contextWords: context)
            try writeJSON(TranscriptCLIPage(takes, page: page), pretty: !json)
        case .alignScript:
            let file = try request.optional("script_file", String.self)
            let inline = try request.optional("script", String.self)
            guard (file != nil) != (inline != nil) else {
                throw CLIError("invalid_arguments", "Specify script text or --script-file FILE.")
            }
            let script: String
            if let file {
                let bytes = try readFile(file, label: "Script", interruption: interruption)
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw CLIError("invalid_arguments", "The script must be UTF-8 text.")
                }
                script = text
            } else { script = inline ?? "" }
            let beats = TranscriptEditorial.alignScript(script, words: words)
            try writeJSON(TranscriptCLIPage(beats, page: page), pretty: !json)
        case .suggest:
            let fillers = try request.optional("filler_terms", [String].self) ?? []
            let suggestions = TranscriptEditorial.suggest(words: words, fillerTerms: fillers)
            try writeJSON(TranscriptCLIPage(suggestions, page: page), pretty: !json)
        case .export:
            let output = try request.url("output")
            let format = try request.format(path: output?.path, default: json ? .json : .text)
            let bytes = try TranscriptCodec.encode(indexes, space: space, format: format, filter: filter)
            if let output {
                try project.media.validateDestination(output, relativeTo: project.url)
                guard project.media.diskRevision?.matchesDestination(output) != true else {
                    throw CLIError("invalid_arguments", "Choose a separate transcript output file.")
                }
                try publish(bytes, to: output, interruption: interruption)
                try writeJSON(TranscriptExportReceipt(output: output.path, space: space, format: format, words: words.count),
                              pretty: !json, checkCancellation: false)
            } else {
                try interruption.beginResponse()
                try writeOutput(bytes + (bytes.last == 10 ? Data() : Data([10])))
            }
        default: preconditionFailure()
        }
    }


}

private struct TranscriptExportReceipt: Encodable {
    let ok = true
    let output: String
    let space: TranscriptSpace
    let format: TranscriptFormat
    let words: Int
}

private struct TranscriptCLIRead: Encodable {
    private enum CodingKeys: String, CodingKey {
        case items
        case total
        case nextOffset = "next_offset"
        case space
        case revision
        case attachmentResults = "attachment_results"
        case speakers
        case coverageGaps = "coverage_gaps"
        case inputCoverage = "input_coverage"
        case authoring
    }
    let items: [TranscriptOccurrence]
    let total: Int
    let nextOffset: Int?
    let space: TranscriptSpace
    let revision: TranscriptEditRevision?
    let attachmentResults: [String: String]
    let speakers: TranscriptCLIPage<TranscriptLaneReadout<TranscriptSpeaker>>
    let coverageGaps: TranscriptCLIPage<TranscriptCoverageGap>
    let inputCoverage: TranscriptInputCoverageReport?
    let authoring: TranscriptCLIPage<TranscriptAuthoredReview>
}
