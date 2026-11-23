import Darwin
import Foundation
import MPCutCore

struct ParticipantCLI {
    fileprivate static let maximumScanBytes = 1024 * 1024 * 1024
    enum Operation {
        case scan, markers, inspect, accept, apply, plan, render, angles, planAngles, renderAngles

        var allowed: Set<String> {
            switch self {
            case .scan: ["file", "backend", "sampling", "include_scenes", "no_sidecar", "progress", "output", "resume_file"]
            case .markers: ["analysis_file", "rule"]
            case .inspect: ["project_path"]
            case .accept: ["project_path", "source_id", "analysis_file", "out_project", "in_place"]
            case .apply: ["project_path", "participants", "participants_file", "out_project", "in_place"]
            case .plan: ["project_path", "plan", "output"]
            case .render: ["project_path", "plan", "output", "progress"]
            case .angles: ["project_path", "source_id", "participant_ids", "range", "include_original", "presentation_ids"]
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
        let switches: Set<String> = ["include_scenes", "in_place", "include_original"]
        let strings: Set<String> = ["file", "project_path", "source_id", "analysis_file", "out_project",
                                    "output", "output_directory", "backend", "sampling", "progress", "resume_file", "participants_file"]
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
        let request = try read(interruption)
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
            case nil: sampling = resume?.configuration.sampling ?? .everyFrame
            case "every-frame": sampling = .everyFrame
            case "sparse": sampling = .sparse
            default: throw CLIError("invalid_arguments", "Choose sampling every-frame or sparse.")
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
            let progress = try request.progress()
            var lastUpdate = -Double.infinity
            let result = try ParticipantAnalysis.scan(source, options: .init(
                backend: backend, sampling: sampling,
                includeScenes: request.value("include_scenes", as: Bool.self) ?? resume?.configuration.includeScenes ?? false,
                useSidecar: useSidecar && !(request.value("no_sidecar", as: Bool.self) ?? false)),
                resuming: resume, cancelled: cancelled, progress: progress == .none ? nil : { time in
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - lastUpdate >= 0.2 else { return }
                    lastUpdate = now
                    emitProgress(progress, time: time)
                })
            if result.state == .completed || result.state == .upToDate {
                emitProgress(progress, time: result.source.duration, fraction: 1)
            }
            if let destination {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(result)
                data.append(0x0A)
                try publishAnalysis(data, paused: result.state == .paused, to: destination, interruption: interruption)
                try interruption.beginResponse(checkCancellation: false)
                try writeOutput(data)
            } else {
                try writeJSON(result, pretty: !json, checkCancellation: false)
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
        let loaded = try CutProject.loadEditorDocument(from: document, limit: CutProject.maximumHistorySteps)
        let project = loaded.project
        switch operation {
        case .scan, .markers:
            return
        case .inspect:
            try writeJSON(project.participants, pretty: !json)
        case .apply, .accept:
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
            var updated = project
            if operation == .apply {
                if request.fields["participants_file"] != nil {
                    guard request.fields["participants"] == nil else {
                        throw CLIError("invalid_arguments", "Choose participants or participants_file.")
                    }
                    updated.participants = try request.readJSONFile("participants_file", as: ParticipantProject.self,
                                                                    label: "Participant edit", cancelled: cancelled)
                } else {
                    updated.participants = try request.required("participants", as: ParticipantProject.self)
                }
            } else {
                let sourceID = try request.required("source_id", as: String.self)
                let scan = try request.analysis(cancelled: cancelled)
                try updated.acceptParticipantAnalysis(scan, sourceID: sourceID, relativeTo: document)
            }
            try updated.validate()
            if inPlace, project != updated {
                let history = loaded.undo + [.init(action: "Edit Participants", project: project)]
                try updated.saveCopy(to: destination, copyingTranscriptsFrom: document,
                                     undo: history, redo: [], replacingExisting: true,
                                     expected: loaded.media.diskRevision, check: interruption.check)
            } else if !inPlace {
                try saveEditedProject(updated, source: document, destination: destination, action: "Edit Participants",
                                      original: project, undo: loaded.undo, redo: loaded.redo, interruption: interruption)
            }
            try writeJSON(ProjectMutationReceipt(projectPath: destination.path, operationCount: project == updated ? 0 : 1),
                          pretty: !json, checkCancellation: false)
        case .plan, .render:
            let plan = try request.value("plan", as: ParticipantRenderPlan.self)
            let renderer = ParticipantRenderer(cancelled: cancelled)
            if operation == .plan {
                let output = try request.value("output", as: String.self).map { try fileURL($0, label: "Output") }
                if let output { try loaded.media.validateDestination(output, relativeTo: document) }
                try writeJSON(renderer.report(project, document: document, plan: plan, output: output), pretty: !json)
            } else {
                let progress = try request.progress()
                let output = try request.url("output")
                try loaded.media.validateDestination(output, relativeTo: document)
                var lastUpdate = -Double.infinity
                let report = try renderer.render(project, document: document, plan: plan, to: output) { fraction in
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
                project, sourceID: request.required("source_id", as: String.self),
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
                let report = try ParticipantMulticam.report(angles, project: project, document: document,
                                                          canvas: canvas, audio: audio, cancelled: cancelled)
                try writeJSON(report, pretty: !json)
            } else {
                let directory = try request.url("output_directory", directory: true)
                try loaded.media.validateDestination(directory, relativeTo: document, includesContents: true)
                let delivered = try ParticipantMulticam.materialize(angles, project: project, document: document,
                    canvas: canvas, audio: audio, to: directory, cancelled: cancelled)
                struct Result: Encodable {
                    let projectPath: String
                    let project: MulticamProject
                }
                try writeJSON(Result(projectPath: directory.appendingPathComponent("multicam.cut").path, project: delivered),
                              pretty: !json, checkCancellation: false)
            }
        }
    }

    private func publishAnalysis(_ data: Data, paused: Bool, to destination: URL,
                                 interruption: Interruption) throws {
        guard data.count <= Self.maximumScanBytes else {
            throw CutError(code: "participant_analysis_too_large",
                           message: "The scan report exceeds 1 GiB. Scan a shorter recording to save an importable report.")
        }
        if !paused { try interruption.check() }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".mpcut-participants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: [.withoutOverwriting])
        if !paused { try interruption.check() }
        let code = publishExclusively(from: staging, to: destination)
        if code == EEXIST {
            throw CutError(code: "output_exists", message: "Choose a new analysis destination.")
        }
        if code != 0 {
            throw CutError(code: "participant_analysis_write_failed", message: String(cString: strerror(code)))
        }
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

private struct ParticipantRequest {
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

private func emitProgress(_ output: MediaProgressOutput, time: RationalTime? = nil, fraction: Double? = nil) {
    switch output {
    case .none: break
    case .stderr:
        if let time { progressOutput(String(format: "%.2f s media scanned", time.seconds)) }
        if let fraction { progressOutput(String(format: "%.1f%%", 100 * fraction)) }
    case .jsonl:
        struct Event: Encodable {
            let event = "progress"
            let time: RationalTime?
            let fraction: Double?
        }
        if let data = try? JSONEncoder().encode(Event(time: time, fraction: fraction)) {
            progressOutput(String(decoding: data, as: UTF8.self))
        }
    }
}
