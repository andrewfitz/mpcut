import Darwin
import Foundation
import MPCutCore

struct ParticipantCLI {
    fileprivate static let maximumScanBytes = 1024 * 1024 * 1024
    enum Operation {
        case scan, markers, inspect, accept, apply, plan, render, angles, takeAngle, planAngles, renderAngles

        var allowed: Set<String> {
            switch self {
            case .scan: ["file", "backend", "sampling", "feed_layout", "include_scenes", "no_sidecar", "progress", "output",
                         "summary", "resume_file"]
            case .markers: ["analysis_file", "rule"]
            case .inspect: ["project_path"]
            case .accept: ["project_path", "source_id", "analysis_file", "out_project", "in_place"]
            case .apply: ["project_path", "participants", "participants_file", "out_project", "in_place"]
            case .plan: ["project_path", "plan", "output"]
            case .render: ["project_path", "plan", "output", "progress"]
            case .angles: ["project_path", "source_id", "participant_ids", "range", "include_original", "presentation_ids"]
            case .takeAngle: ["project_path", "angle", "output_time", "out_project", "in_place"]
            case .planAngles:
                Operation.angles.allowed.union(["canvas", "audio"])
            case .renderAngles:
                Operation.planAngles.allowed.union(["output_directory"])
            }
        }
    }

    private let operation: Operation
    private let requestFile: String?
    private let flags: [String: Any]

    init(operation: Operation, arguments: [String]) throws {
        self.operation = operation
        let options = arguments.filter { $0 != "--json" }
        if options == ["--stdin"] {
            requestFile = "-"
            flags = [:]
            return
        }
        if options.count == 2, options[0] == "--input", !options[1].hasPrefix("--"), !options[1].isEmpty {
            requestFile = options[1]
            flags = [:]
            return
        }
        requestFile = nil
        let switches: Set<String> = ["include_scenes", "in_place", "include_original", "summary"]
        let strings: Set<String> = ["file", "project_path", "source_id", "analysis_file", "out_project",
                                    "output", "output_directory", "backend", "sampling", "feed_layout", "progress",
                                    "resume_file", "participants_file"]
        var values: [String: Any] = [:]
        var iterator = options.makeIterator()
        while let token = iterator.next() {
            guard token.hasPrefix("--") else { throw CLIError("invalid_arguments", "Unexpected argument " + token) }
            let name = token == "--project" ? "project_path" : token.dropFirst(2).replacingOccurrences(of: "-", with: "_")
            guard !token.contains("_"), token != "--project-path", operation.allowed.contains(name), values[name] == nil else {
                throw CLIError("invalid_arguments", "Unknown or duplicate option " + token)
            }
            if switches.contains(name) {
                values[name] = true
            } else if strings.contains(name), let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") {
                values[name] = value
            } else {
                throw CLIError("invalid_arguments", "Supply a value for " + token + " or pass the request as JSON.")
            }
        }
        flags = values
    }

    func run(json: Bool, useSidecar: Bool, interruption: Interruption) throws {
        try run(request: read(interruption), json: json, useSidecar: useSidecar, interruption: interruption)
    }

    func run(request: ParticipantRequest, json: Bool, useSidecar: Bool, interruption: Interruption, tiles: Bool = false) throws {
        let cancelled: @Sendable () -> Bool = { !interruption.isActive }
        if operation == .scan {
            let resume = try request.value("resume_file", as: String.self)
                .map { _ in try request.analysis(file: "resume_file", cancelled: cancelled) }
            let backend: ParticipantBackendMode
            switch try request.value("backend", as: String.self) {
            case nil: backend = resume?.configuration.backend ?? .automatic
            case "auto": backend = .automatic
            case "cpu-only": backend = .cpu
            case "gpu-required": backend = .gpuRequired
            default: throw CLIError("invalid_arguments", "Choose backend auto, cpu-only or gpu-required.")
            }
            let sampling: ParticipantSampling
            switch try request.value("sampling", as: String.self) {
            case nil: sampling = resume?.configuration.sampling ?? .adaptive
            case "adaptive": sampling = .adaptive
            case "every-frame": sampling = .everyFrame
            case "sparse": sampling = .sparse
            default: throw CLIError("invalid_arguments", "Choose sampling adaptive, every-frame or sparse.")
            }
            let feedLayout: ParticipantFeedLayout
            if tiles, let grid = try request.value("gallery_grid", as: String.self) {
                guard request.fields["feed_layout"] == nil, let layout = ParticipantFeedLayout(galleryGrid: grid) else {
                    throw CLIError("invalid_arguments", "Choose --gallery-grid COLSxROWS with one to 64 tiles, or --feed-layout.")
                }
                feedLayout = layout
            } else if let value = try request.value("feed_layout", as: String.self) {
                guard let layout = ParticipantFeedLayout(feedLayout: value) else {
                    throw CLIError("invalid_arguments", "Choose feed layout auto or COLSxROWS with one to 64 feeds.")
                }
                feedLayout = layout
            } else {
                feedLayout = resume?.configuration.feedLayout ?? .meeting
            }
            let source = try request.url("file")
            let destination = try request.value("output", as: String.self).map { try fileURL($0, label: "Output") }
            if let destination {
                guard destination.pathExtension.lowercased() == "json" else {
                    throw CLIError("invalid_arguments", "Choose a new .json destination for participant analysis.")
                }
                var entry = stat()
                guard lstat(destination.path, &entry) != 0, errno == ENOENT else {
                    throw CutError(code: "output_exists", message: "Choose a new analysis destination.")
                }
            }
            // A saved report can run to hundreds of megabytes. With a summary the
            // caller gets its state, counts and coverage instead of a second copy.
            let summary = try request.value("summary", as: Bool.self) ?? false
            guard !summary || destination != nil else {
                throw CLIError("invalid_arguments", "Supply --output to save the scan that --summary describes.")
            }
            let hints = tiles ? try request.tileCountHints()?.overriding(resume?.countHints) ?? resume?.countHints : nil
            let progress = try request.progress()
            var options = try ParticipantScanOptions(
                backend: backend, sampling: sampling,
                includeScenes: request.value("include_scenes", as: Bool.self) ?? resume?.configuration.includeScenes ?? false,
                useSidecar: useSidecar && !(request.value("no_sidecar", as: Bool.self) ?? false), feedLayout: feedLayout)
            if tiles, let destination {
                options.checkpointDirectory = destination.appendingPathExtension("checkpoints")
            }
            var result: ParticipantScanResult
            var last: ParticipantScanProgress?
            do {
                if progress == .none {
                    result = try ParticipantAnalysis.scan(source, options: options, resuming: resume, cancelled: cancelled)
                } else {
                    result = try ParticipantAnalysis.scanWithStatus(source, options: options, resuming: resume, cancelled: cancelled) { update in
                        last = update
                        switch update.phase {
                        case .preparing, .checkingCache, .scanning, .finalizing:
                            emitScanProgress(progress, phase: update.phase.rawValue, percent: update.percent, time: update.time,
                                             waitForDelivery: update.phase == .preparing)
                        case .completed, .upToDate, .paused, .incomplete, .failed:
                            break
                        }
                    }
                }
                if tiles { result.countHints = hints }
                if let last {
                    // A completed scan or paused checkpoint still needs to be delivered.
                    emitScanProgress(progress, phase: "writing_result", percent: min(99, last.percent), time: last.time,
                                     waitForDelivery: true)
                }
                if tiles, let destination {
                    let journal = options.checkpointDirectory?.appendingPathComponent("manifest.json")
                    let hasJournal = journal.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                    let saveReport = result.state != .paused || !hasJournal
                    if saveReport {
                        try outputScan(result, to: destination, pretty: false, summary: false, summaryPretty: !json,
                                       interruption: interruption, writeResponse: false)
                    }
                    if saveReport, let directory = options.checkpointDirectory {
                        ParticipantAnalysis.discardCheckpoint(for: result, directory: directory)
                    }
                    let review = TilesReview(scan: result, countHints: hints)
                    let report = review.report(issuesOnly: true)
                    struct TilesScanSummary: Encodable {
                        struct Counts: Encodable {
                            let feedCount, maxVisibleTiles, observations: Int
                            enum CodingKeys: String, CodingKey {
                                case observations, feedCount = "feed_count", maxVisibleTiles = "max_visible_tiles"
                            }
                        }
                        let schemaVersion = 1
                        let state: ParticipantScanResult.State
                        let output: String?
                        let checkpointDirectory: String?
                        let source: ParticipantScanSource
                        let counts: Counts
                        let coverage: [ParticipantCoverage]
                        let issues: [TilesIssue]
                        let reviewIssueCount: Int
                        enum CodingKeys: String, CodingKey {
                            case schemaVersion = "schema_version", checkpointDirectory = "checkpoint_directory"
                            case state, output, source, counts, coverage, issues
                            case reviewIssueCount = "review_issue_count"
                        }
                    }
                    try writeJSON(TilesScanSummary(state: result.state, output: saveReport ? destination.path : nil,
                                                   checkpointDirectory: saveReport ? nil : options.checkpointDirectory?.path,
                                                   source: result.source,
                                                   counts: .init(feedCount: report.counts.feedCount, maxVisibleTiles: report.counts.maxVisibleTiles,
                                                                 observations: result.analysis?.observations.count ?? 0),
                                                   coverage: report.coverage, issues: report.issues.filter { $0.kind == .countMismatch },
                                                   reviewIssueCount: report.issues.count),
                                  pretty: !json, checkCancellation: false)
                } else {
                    try outputScan(result, to: destination, pretty: destination == nil && !json, summary: summary,
                                   summaryPretty: !json, interruption: interruption)
                }
            } catch {
                if let last {
                    let wasCancelled = error is CancellationError || (error as? CLIError)?.code == "cancelled"
                        || (error as? CutError)?.code == "cancelled"
                    let phase = wasCancelled ? "paused" : "failed"
                    emitScanProgress(progress, phase: phase, percent: min(99, last.percent), time: last.time,
                                     waitForDelivery: true)
                }
                throw error
            }
            if let last {
                emitScanProgress(progress, phase: last.phase.rawValue, percent: last.percent, time: last.time,
                                 waitForDelivery: true)
            }
            if result.state == .paused { exit(130) }
            if result.state == .incomplete { exit(1) }
            return
        }

        if operation == .markers {
            let result = try request.analysis(cancelled: cancelled)
            let rule = try request.value("rule", as: ParticipantMarkerRule.self) ?? .init()
            struct Result: Encodable { let markers: [ParticipantSceneMarker] }
            try writeJSON(Result(markers: ParticipantAnalysis.markers(result, rule: rule)), pretty: !json)
            return
        }

        let document = try request.url("project_path")
        try SidecarLocations.$projectURL.withValue(document) {
            try runProject(request, document: document, json: json, interruption: interruption, cancelled: cancelled)
        }
    }

    private func runProject(_ request: ParticipantRequest, document: URL, json: Bool,
                            interruption: Interruption, cancelled: @escaping @Sendable () -> Bool) throws {
        let loaded = try CutProject.loadEditorDocument(from: document, limit: CutProject.maximumHistorySteps)
        let project = loaded.project
        let legacy = try project.legacyParticipantView(forRendering: [.plan, .render, .planAngles, .renderAngles].contains(operation))
        switch operation {
        case .scan, .markers:
            return
        case .inspect:
            try writeJSON(legacy.participants.legacyParticipantJSON, pretty: !json)
        case .apply, .accept, .takeAngle:
            let inPlace = try request.value("in_place", as: Bool.self) ?? false
            let outProject = try request.value("out_project", as: String.self)
            guard inPlace != (outProject != nil) else {
                throw CLIError("invalid_arguments", "Choose either out_project or in_place.")
            }
            let destination = try outProject.map { try fileURL($0, label: "Output project") } ?? document
            guard destination.pathExtension.lowercased() == "cut" else {
                throw CLIError("invalid_arguments", "Choose a .cut destination.")
            }
            try loaded.media.validateDestination(destination, relativeTo: document)
            var updated = legacy
            if operation == .apply {
                let edits: ParticipantProject
                if request.fields["participants_file"] != nil {
                    guard request.fields["participants"] == nil else {
                        throw CLIError("invalid_arguments", "Choose participants or participants_file.")
                    }
                    edits = try request.readJSONFile("participants_file", as: ParticipantProject.self,
                                                      label: "Participant edit", cancelled: cancelled)
                } else {
                    edits = try request.required("participants", as: ParticipantProject.self)
                }
                try edits.validateLegacyParticipantEdits()
                try updated.applyParticipantEdits(edits, relativeTo: document)
                updated.participants = updated.participants.preservingTileReview(from: legacy.participants)
            } else if operation == .accept {
                let sourceID = try request.required("source_id", as: String.self)
                let scan = try request.analysis(cancelled: cancelled)
                try updated.acceptParticipantAnalysis(scan, sourceID: sourceID, relativeTo: document,
                                                      promoteScreenShares: false, cancelled: cancelled)
            } else {
                let angle = try request.required("angle", as: ParticipantVirtualAngle.self)
                let time = try RationalTime(parsing: request.required("output_time", as: String.self))
                updated = try ParticipantMulticam.taking(angle, at: time, in: legacy, document: document)
            }
            updated = try project.applyingLegacyParticipantView(updated, previous: legacy)
            let action = operation == .takeAngle ? "Take Participant Angle" : "Edit Participants"
            try updated.validate()
            if inPlace, project != updated {
                let history = loaded.undo + [.init(action: action, project: project)]
                try updated.saveCopy(to: destination, copyingTranscriptsFrom: document,
                                     undo: history, redo: [], mediaSnapshot: loaded.media.mediaSnapshot, replacingExisting: true,
                                     expected: loaded.media.diskRevision, check: interruption.check)
            } else if !inPlace {
                try saveEditedProject(updated, source: document, destination: destination, action: action,
                                      original: project, undo: loaded.undo, redo: loaded.redo,
                                      mediaSnapshot: loaded.media.mediaSnapshot, interruption: interruption)
            }
            try writeJSON(ProjectMutationReceipt(projectPath: destination.path, operationCount: project == updated ? 0 : 1),
                          pretty: !json, checkCancellation: false)
        case .plan, .render:
            let plan = try request.value("plan", as: ParticipantRenderPlan.self)
            let renderer = ParticipantRenderer(cancelled: cancelled, legacyWholeFramePrivacy: true)
            if operation == .plan {
                let output = try request.value("output", as: String.self).map { try fileURL($0, label: "Output") }
                if let output { try loaded.media.validateDestination(output, relativeTo: document) }
                try writeJSON(renderer.report(legacy, document: document, plan: plan, output: output), pretty: !json)
            } else {
                let progress = try request.progress()
                let output = try request.url("output")
                try loaded.media.validateDestination(output, relativeTo: document)
                var lastUpdate = -Double.infinity
                let report = try renderer.render(legacy, document: document, plan: plan, to: output) { fraction in
                    let now = ProcessInfo.processInfo.systemUptime
                    if fraction == 1 || now - lastUpdate >= 0.2 {
                        lastUpdate = now
                        emitProgress(progress, fraction: fraction)
                    }
                    return !cancelled()
                }
                try writeJSON(report, pretty: !json, checkCancellation: false)
            }
        case .angles, .planAngles, .renderAngles:
            let angles = try ParticipantMulticam.virtualAngles(
                legacy, sourceID: request.required("source_id", as: String.self),
                participantIDs: request.value("participant_ids", as: [String].self) ?? [],
                range: request.required("range", as: MulticamRange.self),
                includeOriginal: request.value("include_original", as: Bool.self) ?? false,
                presentationIDs: request.value("presentation_ids", as: [String].self) ?? [])
            if operation == .angles {
                struct Result: Encodable { let angles: [ParticipantVirtualAngle] }
                try writeJSON(Result(angles: angles), pretty: !json)
                return
            }
            let canvas = try request.required("canvas", as: ParticipantCanvas.self)
            let audio = try request.value("audio", as: ParticipantMulticamAudioRouting.self) ?? .init()
            if operation == .planAngles {
                let report = try ParticipantMulticam.report(angles, project: legacy, document: document,
                                                          canvas: canvas, audio: audio, cancelled: cancelled)
                try writeJSON(report, pretty: !json)
            } else {
                let directory = try request.url("output_directory", directory: true)
                try loaded.media.validateDestination(directory, relativeTo: document, includesContents: true)
                let (delivered, written) = try ExportWriteNotices.collecting {
                    try ParticipantMulticam.materialize(angles, project: legacy, document: document,
                                                        canvas: canvas, audio: audio, to: directory, cancelled: cancelled)
                }
                struct Result: Encodable {
                    let projectPath: String
                    let project: MulticamProject
                    /// What each angle's picture gave up, by angle name.
                    let warnings: [String]?
                }
                try writeJSON(Result(projectPath: directory.appendingPathComponent("multicam.cut").path, project: delivered,
                                     warnings: written.isEmpty ? nil : written),
                              pretty: !json, checkCancellation: false)
            }
        }
    }

    /// What a scan saved to a file, without its observations.
    private struct ScanSummary: Encodable {
        struct Counts: Encodable {
            let observations, tracks, appearances, events: Int
        }

        let state: ParticipantScanResult.State
        let output: String
        let bytes: Int
        let source: ParticipantScanSource
        let configuration: ParticipantScanConfiguration
        let analysisIdentity: String
        let counts: Counts?
        let coverage: [ParticipantTrackingCoverage]?
        @ParticipantOptionalSourceTime var resumeAt: RationalTime?

        enum CodingKeys: String, CodingKey {
            case state, output, bytes, source, configuration, counts, coverage
            case analysisIdentity = "analysis_identity"
            case resumeAt = "resume_at"
        }
    }

    private func outputScan(_ result: ParticipantScanResult, to destination: URL?, pretty: Bool,
                            summary: Bool, summaryPretty: Bool, interruption: Interruption, writeResponse: Bool = true) throws {
        let directory = destination?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let staging = directory.appendingPathComponent(".mpcut-participants-\(UUID().uuidString)")
        let fd = open(staging.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, destination == nil ? 0o600 : 0o666)
        guard fd >= 0 else { throw CutError(code: "participant_analysis_write_failed", message: String(cString: strerror(errno))) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        defer { if destination != nil { try? FileManager.default.removeItem(at: staging) } }
        // Keep stdout transactional on an encoding error. An anonymous spool
        // is also reclaimed if the process exits while writing to a closed pipe.
        if destination == nil { try FileManager.default.removeItem(at: staging) }
        var count = 0
        func write(_ bytes: Data) throws {
            if result.state != .paused { try interruption.check() }
            if destination != nil && bytes.count > Self.maximumScanBytes - count {
                throw CutError(code: "participant_analysis_too_large",
                               message: "The scan report exceeds 1 GiB. Scan a shorter recording to save an importable report.")
            }
            try file.write(contentsOf: bytes)
            count += bytes.count
        }
        try result.writeJSON(pretty: pretty, write: write)
        try write(Data([10]))
        try file.seek(toOffset: 0)
        if let destination {
            if result.state != .paused { try interruption.check() }
            let code = publishExclusively(from: staging, to: destination)
            if code == EEXIST { throw CutError(code: "output_exists", message: "Choose a new analysis destination.") }
            if code != 0 { throw CutError(code: "participant_analysis_write_failed", message: String(cString: strerror(code))) }
        }
        guard writeResponse else { return }
        if summary, let destination {
            let analysis = result.analysis
            try writeJSON(ScanSummary(
                state: result.state, output: destination.path, bytes: count, source: result.source,
                configuration: result.configuration, analysisIdentity: result.analysisIdentity,
                counts: analysis.map {
                    .init(observations: $0.observations.count, tracks: $0.tracks.count,
                          appearances: $0.appearances.count, events: $0.events.count)
                },
                coverage: analysis?.coverage, resumeAt: analysis?.resumeAt), pretty: summaryPretty, checkCancellation: false)
            return
        }
        try interruption.beginResponse(checkCancellation: false)
        while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty { try writeOutput(bytes) }
    }

    private func read(_ interruption: Interruption) throws -> ParticipantRequest {
        guard let requestFile else { return .init(fields: flags) }
        let bytes = try requestFile == "-"
            ? readStandardInput(interruption)
            : ClipEditCSV.readListData(fileURL(requestFile, label: "Request"), kind: "JSON request",
                                      cancelled: { !interruption.isActive })
        guard let fields = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw CLIError("invalid_json", "Supply one JSON request object.")
        }
        if let issue = jsonInputIssue(bytes) { throw CLIError("invalid_json", "The request " + issue + ".") }
        if let unexpected = Set(fields.keys).subtracting(operation.allowed).sorted().first {
            throw CLIError("invalid_json", "Unexpected participant field " + unexpected)
        }
        return .init(fields: fields)
    }
}

struct ParticipantRequest {
    let fields: [String: Any]

    func value<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        guard let raw = fields[key] else { return nil }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(type, from: bytes)
        } catch {
            throw CLIError("invalid_json", "Invalid participant request field \(key). \(error)")
        }
    }

    func required<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        guard let value = try value(key, as: type) else {
            throw CLIError("invalid_arguments", "Supply " + key + ".")
        }
        return value
    }

    func url(_ key: String, directory: Bool = false) throws -> URL {
        try fileURL(required(key, as: String.self), label: key, directory: directory)
    }

    func analysis(file key: String = "analysis_file", cancelled: () -> Bool) throws -> ParticipantScanResult {
        try readJSONFile(key, as: ParticipantScanResult.self, label: "Participant analysis",
                         maximumBytes: ParticipantCLI.maximumScanBytes, cancelled: cancelled)
    }

    func readJSONFile<T: Decodable>(_ key: String, as type: T.Type, label: String,
                                     maximumBytes: Int = MulticamProject.maximumFileSize,
                                     cancelled: () -> Bool) throws -> T {
        let bytes = try ClipEditCSV.readListData(url(key), kind: label, maximumBytes: maximumBytes, cancelled: cancelled)
        let decoded: T
        do {
            decoded = try JSONDecoder().decode(type, from: bytes)
        } catch {
            throw CLIError("invalid_json", "Invalid \(label.lowercased()). \(error)")
        }
        if let issue = jsonInputIssue(bytes) { throw CLIError("invalid_json", "The \(label.lowercased()) " + issue + ".") }
        return decoded
    }

    func progress() throws -> MediaProgressOutput {
        let format = try value("progress", as: String.self) ?? "none"
        guard let output = MediaProgressOutput(rawValue: format) else {
            throw CLIError("invalid_arguments", "Choose progress none, stderr or jsonl.")
        }
        return output
    }
}

private func emitScanProgress(_ output: MediaProgressOutput, phase: String, percent: Int, time: RationalTime,
                              waitForDelivery: Bool) {
    emitProgress(output, time: time, fraction: Double(percent) / 100, phase: phase, percent: percent,
                 waitForDelivery: waitForDelivery)
}

private func emitProgress(_ output: MediaProgressOutput, time: RationalTime? = nil, fraction: Double? = nil,
                          phase: String? = nil, percent: Int? = nil, waitForDelivery: Bool = false) {
    switch output {
    case .none: break
    case .stderr:
        if let phase, let percent {
            progressOutput("\(phase) \(percent)%", waitForDelivery: waitForDelivery)
            return
        }
        if let time { progressOutput(String(format: "%.2f s media scanned", time.seconds)) }
        if let fraction { progressOutput(String(format: "%.1f%%", 100 * fraction)) }
    case .jsonl:
        struct Event: Encodable {
            let event = "progress"
            let phase: String?
            let percent: Int?
            let time: RationalTime?
            let fraction: Double?
        }
        if let data = try? JSONEncoder().encode(Event(phase: phase, percent: percent, time: time, fraction: fraction)) {
            progressOutput(String(decoding: data, as: UTF8.self), waitForDelivery: waitForDelivery)
        }
    }
}
