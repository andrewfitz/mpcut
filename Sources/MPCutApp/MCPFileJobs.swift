import CryptoKit
import Darwin
import Foundation

extension ProjectSessions {
    func mcpFile(tool: String, arguments: [String: Any], session: ProjectSession?,
                 checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard MCPFileRequest.isFileTool(tool) else { return nil }
        try checkAccess()
        return try mcpFileJobs.perform(tool: tool, validatedArguments: arguments)
    }
}

/// File jobs run the installed sibling CLI. Only job metadata and bounded result
/// pages cross the main actor. CLI stdout and stderr spool directly to private files.
@MainActor
final class MCPFileJobs {
    private final class Job {
        let id: UUID
        let tool: String
        let fingerprint: SHA256.Digest
        let directory: URL
        let process: Process
        var ended: ContinuousClock.Instant?
        var state = "running"
        var cleanup: (() -> Void)?
        var diagnosticsReader: FileHandle?
        var diagnosticsTail: (end: UInt64, text: String, isFinal: Bool)?
        var resultSize: Int?

        init(id: UUID, tool: String, fingerprint: SHA256.Digest, directory: URL,
             process: Process, cleanup: (() -> Void)?) {
            self.id = id
            self.tool = tool
            self.fingerprint = fingerprint
            self.directory = directory
            self.process = process
            self.cleanup = cleanup
        }

        var output: URL { directory.appendingPathComponent("result.json") }
        var diagnostics: URL { directory.appendingPathComponent("diagnostics") }

        func cleanInputs() {
            cleanup?()
            cleanup = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("request.json"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    static let chunkSize = 131_072
    private let executable: URL?
    private var jobs: [UUID: Job] = [:]
    private var draining: [UUID: Job] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let retention: Duration = .seconds(600)

    var hasRunningJobs: Bool { !draining.isEmpty || jobs.values.contains { $0.ended == nil } }

    init(executable: URL? = nil) {
        self.executable = executable
    }

    private func cli() throws -> URL {
        if let executable { return executable }
        let bundle = Bundle.main
        let installed = bundle.bundleURL.appendingPathComponent("Contents/Helpers/mpcut")
        // SwiftPM development binaries are siblings. An app bundle always uses its bundled CLI.
        let url = bundle.bundleURL.pathExtension == "app" ? installed :
            bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("mpcut")
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MCPCommandError("cli_unavailable", "The MPCut CLI is missing from this build.")
        }
        return url
    }

    func perform(tool: String, validatedArguments arguments: [String: Any]) throws -> [String: Any] {
        switch tool {
        case "file_job_status_read", "file_job_cancel", "file_job_result_read":
            guard let raw = arguments["job_id"] as? String, let id = UUID(uuidString: raw) else {
                throw MCPCommandError("invalid_arguments", "Supply the job_id UUID returned by a file tool.")
            }
            if tool == "file_job_status_read" { return try self.status(id: id) }
            if tool == "file_job_cancel" { return try self.cancel(id: id) }
            return try self.read(id: id, offset: arguments["offset"], limit: arguments["limit"])
        default:
            return try self.start(tool: tool, arguments: arguments, alreadyValidated: true)
        }
    }

    func start(tool: String, arguments: [String: Any], cleanup: (() -> Void)? = nil) throws -> [String: Any] {
        try start(tool: tool, arguments: arguments, alreadyValidated: false, cleanup: cleanup)
    }

    private func start(tool: String, arguments: [String: Any], alreadyValidated: Bool,
                       cleanup: (() -> Void)? = nil) throws -> [String: Any] {
        var launched = false
        defer { if !launched { cleanup?() } }
        guard waiters.isEmpty else {
            throw MCPCommandError("jobs_busy", "File jobs are shutting down.")
        }
        guard let raw = arguments["operation_id"] as? String, let id = UUID(uuidString: raw) else {
            throw MCPCommandError("invalid_arguments", "Supply a fresh UUID in operation_id for each distinct file job.")
        }
        let data = try JSONSerialization.data(withJSONObject: arguments.filter { $0.key != "operation_id" },
                                              options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: data)
        if let job = retainedJob(id) {
            guard job.fingerprint == fingerprint, job.tool == tool else {
                throw MCPCommandError("operation_id_conflict", "This operation_id was already used with different arguments.")
            }
            return try status(id: id)
        }
        let request = try alreadyValidated ? MCPFileRequest(tool: tool, validatedFields: arguments)
            : MCPFileRequest(tool: tool, fields: arguments)
        if jobs.count >= 512 { prune() }
        guard draining[id] == nil, jobs.values.filter({ $0.ended == nil }).count + draining.count < 8,
              jobs.count < 512 else {
            throw MCPCommandError("jobs_busy", "The file job queue is full. Retry after other jobs finish or expire.")
        }
        let process = Process()
        process.executableURL = try cli()
        process.environment = ProcessInfo.processInfo.environment.merging(["MPCUT_HISTORY_ORIGIN": "agent"]) { _, new in new }
        process.arguments = request.arguments
        process.currentDirectoryURL = request.directory
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-job-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let job = Job(id: id, tool: tool, fingerprint: fingerprint, directory: folder, process: process, cleanup: cleanup)
        let stdout = try openForWriting(job.output)
        defer { try? stdout.close() }
        let stderr = try openForWriting(job.diagnostics)
        defer { try? stderr.close() }
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin: FileHandle
        if let input = request.input {
            let url = folder.appendingPathComponent("request.json")
            try input.write(to: url)
            stdin = try FileHandle(forReadingFrom: url)
        } else {
            stdin = FileHandle.nullDevice
        }
        defer { if request.input != nil { try? stdin.close() } }
        process.standardInput = stdin
        process.terminationHandler = { [weak self, job] child in
            Task { @MainActor in
                child.terminationHandler = nil
                if let self { self.finish(job) }
                else { Self.complete(job) }
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
        launched = true
        jobs[id] = job
        return try status(id: id)
    }

    private func openForWriting(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MCPCommandError("file_job_io", "Could not create file job output.")
        }
        return try FileHandle(forWritingTo: url)
    }

    private func prune() {
        let now = ContinuousClock.now
        jobs = jobs.filter { $0.value.ended.map { $0.duration(to: now) < Self.retention } ?? true }
    }

    private func retainedJob(_ id: UUID) -> Job? {
        guard let job = jobs[id] else { return nil }
        if let ended = job.ended, ended.duration(to: .now) >= Self.retention {
            jobs.removeValue(forKey: id)
            return nil
        }
        return job
    }

    private func job(_ id: UUID) throws -> Job {
        guard let job = retainedJob(id) else {
            throw MCPCommandError("job_unavailable", "This job is unknown or expired. Completed jobs are retained for ten minutes.")
        }
        if job.ended == nil, !job.process.isRunning { finish(job) }
        return job
    }

    private static func complete(_ job: Job) {
        guard job.ended == nil else { return }
        let process = job.process
        let code = process.terminationStatus
        let interrupted = job.state == "cancelling" && process.terminationReason == .uncaughtSignal
            && [SIGINT, SIGTERM, SIGKILL].contains(code)
        if process.terminationReason == .exit && code == 0 {
            job.state = "succeeded"
        } else if process.terminationReason == .exit && code == 3,
                  ["tiles_file_export_isos", "tiles_file_angles_render"].contains(job.tool) {
            job.state = "needs_review"
        } else if code == 130 || interrupted {
            job.state = "cancelled"
        } else {
            job.state = "failed"
        }
        job.ended = .now
        job.diagnosticsReader = nil
        job.cleanInputs()
    }

    private func finish(_ job: Job) {
        guard job.ended == nil else { return }
        Self.complete(job)
        if draining[job.id] === job {
            draining.removeValue(forKey: job.id)
            if draining.isEmpty {
                let waiting = waiters
                waiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        } else {
            // Release the spool at expiry even if the caller never polls again.
            Task { [weak self, weak job] in
                guard let deadline = job?.ended?.advanced(by: Self.retention) else { return }
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard let job, self?.jobs[job.id] === job else { return }
                self?.jobs.removeValue(forKey: job.id)
            }
        }
    }

    private func interrupt(_ job: Job) {
        guard job.ended == nil, job.state == "running" else { return }
        job.state = "cancelling"
        job.process.interrupt()
        // Give the CLI time to remove its staging files and report any batch outputs.
        // Escalate if I/O or a helper prevents cooperative cancellation.
        Task { [weak job] in
            try? await Task.sleep(for: .seconds(3))
            if let process = job?.process, process.isRunning { process.terminate() }
            try? await Task.sleep(for: .seconds(3))
            if let process = job?.process, process.isRunning {
                let pid = process.processIdentifier
                kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            }
        }
    }

    func cancel(id: UUID) throws -> [String: Any] {
        interrupt(try job(id))
        return try status(id: id)
    }

    func disable() {
        let revoked = jobs
        jobs.removeAll()
        for job in revoked.values where job.ended == nil {
            draining[job.id] = job
            if job.process.isRunning { interrupt(job) }
            else { finish(job) }
        }
    }

    func cancelAndWaitForJobs() async {
        disable()
        guard !draining.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func status(id: UUID) throws -> [String: Any] {
        let job = try job(id)
        var result: [String: Any] = ["job_id": id.uuidString, "tool": job.tool, "state": job.state]
        let recent = try tail(job)
        let lines = recent.split(whereSeparator: \.isNewline).reversed()
        if MCPFileRequest.transcriptCommand(for: job.tool) != nil,
           let event = lines.lazy.compactMap({ line -> [String: Any]? in
               guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                     event["job_id"] is String, event["state"] is String,
                     event["tracks"] is Int, event["staged"] is Int else { return nil }
               return event
           }).first {
            result["progress_event"] = event
            if let tracks = event["tracks"] as? Int, let staged = event["staged"] as? Int, tracks > 0, staged >= 0 {
                result["progress_percent"] = min(job.ended == nil ? 99 : 100, Int(100 * min(1, Double(staged) / Double(tracks))))
            }
        } else if (job.tool.hasPrefix("tiles_file_") || ["scenes_file_scan", "project_file_media_refresh", "participants_file_scan", "participants_file_render_export"].contains(job.tool)),
           let event = lines.lazy.compactMap({ line -> [String: Any]? in
               let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
               return object?["event"] as? String == "progress" ? object : nil
           }).first {
            result["progress_event"] = event
            if let fraction = event["fraction"] as? Double, fraction.isFinite {
                let percent = event["percent"] as? Int ?? Int(100 * min(1, max(0, fraction)))
                result["progress_percent"] = min(job.state == "succeeded" ? 100 : 99, max(0, percent))
            }
        } else if let percent = lines.lazy.compactMap({ line -> Int? in
            guard line.hasPrefix("Export "), line.hasSuffix("%") else { return nil }
            return Int(line.dropFirst(7).dropLast())
        }).first {
            result["progress_percent"] = percent
        }
        if job.ended != nil {
            if ["participants_file_scan", "tiles_file_scan"].contains(job.tool), job.state == "succeeded" {
                // Advisory diagnostics may be dropped. A zero exit confirms the scan report was delivered.
                result["progress_percent"] = 100
            }
            result["exit_code"] = Int(job.process.terminationStatus)
            let size = try resultBytes(job)
            result["result_bytes"] = size
            if size > 0 && size <= Self.chunkSize {
                let data = try Data(contentsOf: job.output)
                result["result"] = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
                if result["result"] == nil { result["output_text"] = String(decoding: data, as: UTF8.self) }
            }
            if job.state != "succeeded", !recent.isEmpty { result["diagnostic"] = recent }
        }
        return result
    }

    func read(id: UUID, offset: Any?, limit: Any?) throws -> [String: Any] {
        let job = try job(id)
        guard job.ended != nil else { throw MCPCommandError("job_running", "Poll file_job_status_read until the job ends.") }
        let start = try index(offset, fallback: 0)
        let count = try index(limit, fallback: Self.chunkSize)
        let total = try resultBytes(job)
        guard start <= total, (1...Self.chunkSize).contains(count) else {
            throw MCPCommandError("invalid_arguments", "Choose an offset within the result and a limit from 1 to 131072 bytes.")
        }
        let handle = try FileHandle(forReadingFrom: job.output)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let page = try handle.read(upToCount: count) ?? Data()
        return ["job_id": id.uuidString, "offset": start, "next_offset": start + page.count,
                "result_bytes": total, "done": start + page.count == total, "base64": page.base64EncodedString()]
    }

    private func index(_ raw: Any?, fallback: Int) throws -> Int {
        guard let raw else { return fallback }
        guard let value = mcpInteger(raw), value >= 0 else {
            throw MCPCommandError("invalid_arguments", "Byte offsets and limits must be nonnegative integers.")
        }
        return value
    }

    private func resultBytes(_ job: Job) throws -> Int {
        if let size = job.resultSize { return size }
        let attrs = try FileManager.default.attributesOfItem(atPath: job.output.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        job.resultSize = size
        return size
    }

    private func tail(_ job: Job) throws -> String {
        // Only the child appends to the private spool. Refresh once after exit.
        if let tail = job.diagnosticsTail, tail.isFinal { return tail.text }
        let handle: FileHandle
        if let reader = job.diagnosticsReader {
            handle = reader
        } else {
            let fd = open(job.diagnostics.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        if job.ended == nil { job.diagnosticsReader = handle }
        let end = try handle.seekToEnd()
        let text: String
        if let tail = job.diagnosticsTail, tail.end == end {
            text = tail.text
        } else {
            let count = min(end, 4096)
            try handle.seek(toOffset: end - count)
            text = String(decoding: try handle.read(upToCount: Int(count)) ?? Data(), as: UTF8.self)
        }
        job.diagnosticsTail = (end, text, isFinal: job.ended != nil)
        return text
    }
}
