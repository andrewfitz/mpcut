import CryptoKit
import Darwin
import Foundation

extension ProjectSessions {
    func mcpFile(tool: String, arguments: [String: Any], session: ProjectSession?,
                 checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard MCPFileRequest.isFileTool(tool) else { return nil }
        // The cutcache location is not an EditorPreferences value, so it asks the switch itself. The files-only
        // worker runs these through the CLI without the app and is not gated.
        if tool == "analysis_file_cache_settings_set" { try preferences.checkAgentWrite() }
        // `in_place` rewrites the saved project the request names.
        if (arguments["in_place"] as? NSNumber)?.boolValue == true, !preferences.agentsReplaceFiles {
            throw MCPFailure("file_replace_disabled", Self.fileReplaceDisabledMessage)
        }
        try checkAccess()
        let usesCacheProtection = ["analysis_file_cache_preview", "analysis_file_cache_clear"].contains(tool)
        let protected = usesCacheProtection ? SidecarClearContext(sessions: self).protected : []
        return try mcpFileJobs.perform(tool: tool, validatedArguments: arguments,
                                       cacheProtection: protected, cacheNotifications: true)
    }
}

/// File jobs run the installed sibling CLI. Only job metadata and bounded result
/// pages cross the main actor. CLI stdout and stderr spool directly to private files.
@MainActor
final class MCPFileJobs {
    @MainActor
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
        let durable: Bool
        var receiptLock: FileHandle?
        var cacheNotifications = false

        init(id: UUID, tool: String, fingerprint: SHA256.Digest, directory: URL,
             process: Process, cleanup: (() -> Void)?, receiptLock: FileHandle?) {
            self.id = id
            self.tool = tool
            self.fingerprint = fingerprint
            self.directory = directory
            self.process = process
            self.cleanup = cleanup
            self.receiptLock = receiptLock
            self.durable = receiptLock != nil
        }

        var output: URL { directory.appendingPathComponent(durable ? "stdout" : "result.json") }
        var diagnostics: URL { directory.appendingPathComponent("diagnostics") }

        func cleanInputs() {
            cleanup?()
            cleanup = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("request.json"))
        }

        deinit { if !durable { try? FileManager.default.removeItem(at: directory) } }
    }

    static let chunkSize = 131_072
    private let executable: URL?
    private let receipts: MCPFileReceipts?
    private var jobs: [UUID: Job] = [:]
    private var draining: [UUID: Job] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let retention: Duration = .seconds(600)

    var hasRunningJobs: Bool { !draining.isEmpty || jobs.values.contains { $0.ended == nil } }

    init(executable: URL? = nil, receipts: MCPFileReceipts? = nil) {
        self.executable = executable
        self.receipts = receipts
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

    func perform(tool: String, validatedArguments arguments: [String: Any],
                 cacheProtection: Set<URL> = [], cacheNotifications: Bool = false) throws -> [String: Any] {
        switch tool {
        case MCPFileReview.resultTool:
            return try MCPFileReview.readResult(in: self, arguments: arguments)
        case "file_job_status_read", "file_job_cancel", "file_job_result_read", "file_job_release":
            guard let raw = arguments["job_id"] as? String, let id = UUID(uuidString: raw) else {
                throw MCPCommandError("invalid_arguments", "Supply the job_id UUID returned by a file tool.")
            }
            if tool == "file_job_status_read" { return try self.status(id: id) }
            if tool == "file_job_cancel" { return try self.cancel(id: id) }
            if tool == "file_job_release" { return try self.release(id: id) }
            return try self.read(id: id, offset: arguments["offset"], limit: arguments["limit"])
        default:
            return try self.start(tool: tool, arguments: arguments, alreadyValidated: true,
                                  cacheProtection: cacheProtection, cacheNotifications: cacheNotifications)
        }
    }

    func start(tool: String, arguments: [String: Any], cleanup: (() -> Void)? = nil) throws -> [String: Any] {
        try start(tool: tool, arguments: arguments, alreadyValidated: false, cleanup: cleanup)
    }

    private func start(tool: String, arguments: [String: Any], alreadyValidated: Bool,
                       cleanup: (() -> Void)? = nil, cacheProtection: Set<URL> = [],
                       cacheNotifications: Bool = false) throws -> [String: Any] {
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
        var prepared: (request: MCPFileRequest, executable: URL)?
        func prepare() throws {
            if jobs.count >= 512 { prune() }
            guard draining[id] == nil, jobs.values.filter({ $0.ended == nil }).count + draining.count < 8 else {
                throw MCPCommandError("jobs_busy", "The file job queue is full. Retry after other jobs finish.")
            }
            guard receipts != nil || jobs.count < 512 else {
                throw MCPCommandError("job_receipt_capacity", "The desktop receipt limit is full. Completed receipts expire after ten minutes.")
            }
            let request = try alreadyValidated ? MCPFileRequest(tool: tool, validatedFields: arguments,
                                                                 cacheProtection: cacheProtection)
                : MCPFileRequest(tool: tool, fields: arguments)
            prepared = (request, try cli())
        }
        let folder: URL
        let receiptLock: FileHandle?
        if let receipts {
            switch try receipts.lookupOrAdmit(id: id, tool: tool, fingerprint: Data(fingerprint), prepare: prepare) {
            case .existing(let existing):
                guard existing.fingerprint == Data(fingerprint), existing.tool == tool else {
                    throw MCPCommandError("operation_id_conflict", "This operation_id was already used with different arguments.")
                }
                return try status(id: id)
            case .admitted(let admission):
                folder = admission.directory
                receiptLock = admission.lock
            }
        } else {
            try prepare()
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-job-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            receiptLock = nil
        }
        defer { if !launched { receipts?.abort(id: id) } }
        guard let (request, executableURL) = prepared else {
            throw MCPCommandError("file_job_io", "Could not prepare the admitted file job.")
        }
        let process = Process()
        let job = Job(id: id, tool: tool, fingerprint: fingerprint, directory: folder, process: process,
                      cleanup: cleanup, receiptLock: receiptLock)
        job.cacheNotifications = cacheNotifications
        process.executableURL = executableURL
        var environment = ProcessInfo.processInfo.environment
        environment["MPCUT_HISTORY_ORIGIN"] = "agent"
        if tool == MCPFileReview.requestTool {
            let workspace = folder.appendingPathComponent("frame-work", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            environment[MCPFileReview.directoryEnvironment] = workspace.path
        }
        process.environment = environment
        process.arguments = request.arguments
        process.currentDirectoryURL = request.directory
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

    private func localJob(_ id: UUID) -> Job? {
        guard let job = retainedJob(id) else { return nil }
        if job.ended == nil, !job.process.isRunning { finish(job) }
        return jobs[id]
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
        if job.cacheNotifications && job.state == "succeeded" {
            if job.tool == "analysis_file_cache_settings_set" {
                NotificationCenter.default.post(name: .sidecarStorageDidChange, object: nil)
            } else if job.tool == "analysis_file_cache_clear",
                      let bytes = try? job.output.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 4 * 1024 * 1024,
                      let data = try? Data(contentsOf: job.output),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let paths = result["cleared_sources"] as? [String], !paths.isEmpty {
                NotificationCenter.default.post(name: .sidecarCachesDidClear,
                                                object: Set(paths.map { URL(fileURLWithPath: $0) }),
                                                userInfo: ["wholeSidecars": true])
            }
        }
        if let receipts {
            let metadata = (try? status(job, includeResult: false)) ??
                ["job_id": job.id.uuidString, "tool": job.tool, "state": job.state,
                 "exit_code": Int(job.process.terminationStatus)]
            do {
                try receipts.finish(id: job.id, status: metadata)
                jobs.removeValue(forKey: job.id)
            } catch {
                // Keep this worker's known outcome available if receipt publication fails.
                // The persisted admission still forbids a later worker from repeating the mutation.
            }
            job.receiptLock = nil
        }
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
        if let job = localJob(id) {
            interrupt(job)
        } else if let receipts {
            try receipts.access(id: id) { _, state, _ in
                if state == "running" {
                    throw MCPCommandError("job_owned_by_another_worker", "Request cancellation through the worker that started the job.")
                }
            }
        }
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
        if let job = localJob(id) {
            return try status(job, includeResult: true)
        }
        guard let receipts else { throw unavailable() }
        return try receipts.access(id: id) { record, state, output in
            var status = try receipts.terminalStatus(record) ??
                ["job_id": id.uuidString, "tool": record.tool, "state": state]
            if state == "outcome_unknown" {
                status["diagnostic"] = "The worker stopped before recording the outcome. Its CLI process may still be finishing. Check project changes and any published outputs before starting another operation."
                status["result_available"] = false
            } else if record.endedAt != nil {
                try includeResult(in: &status, tool: record.tool, output: output)
            }
            return status
        }
    }

    private func status(_ job: Job, includeResult: Bool) throws -> [String: Any] {
        var result: [String: Any] = ["job_id": job.id.uuidString, "tool": job.tool, "state": job.state]
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
            if includeResult { try self.includeResult(in: &result, tool: job.tool, output: job.output) }
            if job.state != "succeeded", !recent.isEmpty { result["diagnostic"] = recent }
        }
        return result
    }

    private func includeResult(in status: inout [String: Any], tool: String, output: URL) throws {
        guard FileManager.default.fileExists(atPath: output.path) else {
            status["result_available"] = false
            status.removeValue(forKey: "result_bytes")
            return
        }
        status["result_available"] = true
        guard tool != MCPFileReview.requestTool || status["state"] as? String != "succeeded" else { return }
        let size = try resultBytes(output)
        status["result_bytes"] = size
        if size > 0 && size <= Self.chunkSize {
            let data = try Data(contentsOf: output)
            status["result"] = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            if status["result"] == nil { status["output_text"] = String(decoding: data, as: UTF8.self) }
        }
    }

    func release(id: UUID) throws -> [String: Any] {
        if let job = localJob(id) {
            guard job.ended != nil else { throw running() }
            if FileManager.default.fileExists(atPath: job.output.path) {
                try FileManager.default.removeItem(at: job.output)
            }
        } else if let receipts {
            try receipts.release(id: id)
        } else {
            throw unavailable()
        }
        return try status(id: id)
    }

    func read(id: UUID, offset: Any?, limit: Any?) throws -> [String: Any] {
        try withResult(id: id) { tool, state, output in
            guard tool != MCPFileReview.requestTool || state != "succeeded" else {
                throw MCPCommandError("invalid_arguments", "Use review_file_frame_result_read to retrieve this frame.")
            }
            return try page(id: id, output: output, offset: offset, limit: limit)
        }
    }

    func succeededResult(id: UUID, tool: String, maxBytes: Int) throws -> Data {
        try withResult(id: id) { actualTool, state, output in
            guard tool == actualTool else {
                throw MCPCommandError("invalid_arguments", "This job ID was returned by a different tool.")
            }
            guard state == "succeeded" else {
                throw MCPCommandError("job_result_unavailable", "The job did not succeed. Read its status for the outcome.")
            }
            let handle = try FileHandle(forReadingFrom: output)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            guard data.count <= maxBytes else {
                throw MCPCommandError("job_result_too_large", "The job result exceeds the review size limit.")
            }
            return data
        }
    }

    private func withResult<T>(id: UUID, _ body: (String, String, URL) throws -> T) throws -> T {
        func retrieve(tool: String, state: String, output: URL) throws -> T {
            guard !["running", "cancelling"].contains(state) else { throw running() }
            guard state != "outcome_unknown", FileManager.default.fileExists(atPath: output.path) else {
                throw MCPCommandError("job_result_unavailable", "There is no retained result for this job.")
            }
            return try body(tool, state, output)
        }
        if let job = localJob(id) {
            return try retrieve(tool: job.tool, state: job.state, output: job.output)
        }
        guard let receipts else { throw unavailable() }
        return try receipts.access(id: id) { record, state, output in
            try retrieve(tool: record.tool, state: state, output: output)
        }
    }

    private func unavailable() -> MCPCommandError {
        MCPCommandError("job_unavailable", "This job is unknown or expired. Desktop jobs are retained for up to ten minutes.")
    }

    private func running() -> MCPCommandError {
        MCPCommandError("job_running", "Poll file_job_status_read until the job ends.")
    }

    private func page(id: UUID, output: URL, offset: Any?, limit: Any?) throws -> [String: Any] {
        let start = try index(offset, fallback: 0)
        let count = try index(limit, fallback: Self.chunkSize)
        let total = try resultBytes(output)
        guard start <= total, (1...Self.chunkSize).contains(count) else {
            throw MCPCommandError("invalid_arguments", "Choose an offset within the result and a limit from 1 to 131072 bytes.")
        }
        let handle = try FileHandle(forReadingFrom: output)
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

    private func resultBytes(_ output: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
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
