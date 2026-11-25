import AppKit
import Darwin
import Foundation

struct TranscriptProviderCapabilities: Decodable {
    struct Engine: Decodable {
        let name: String
        let aliases: [String]
        let included: Bool
        let default_model: String
        let diarization: Bool
        let diarization_speaker_limit: Int?
        let minimum_macos: String
        let helper_present: Bool?
        let model_source: String
        let cache_revision: String?
    }

    let version: String
    let cache_revision: String?
    let session_schema_version: Int?
    /// The newest form of a shared recognition file this helper reads. A helper that
    /// does not say reads the first.
    let shared_cache_exchange_version: Int?
    let engines: [Engine]

    static func read(_ data: Data) throws -> Self {
        guard let capabilities = try? JSONDecoder().decode(Self.self, from: data),
              capabilities.session_schema_version == 1 else {
            throw transcriptError("Update Transcriberrr to a version that supports MPCut session schema 1.",
                                  code: "transcript_capability_missing")
        }
        return capabilities
    }

    func select(_ name: String?) throws -> Engine {
        let name = name ?? "qwen3"
        guard let engine = engines.first(where: { $0.name == name || $0.aliases.contains(name) }),
              engine.included, engine.helper_present != false else {
            throw transcriptError("The installed Transcriberrr helper cannot use the ‘\(name)’ engine.",
                                  code: "transcript_capability_missing")
        }
        let version = engine.minimum_macos.split(separator: ".").compactMap { Int($0) }
        guard !version.isEmpty,
              ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: version[0],
                minorVersion: version.dropFirst().first ?? 0, patchVersion: version.dropFirst(2).first ?? 0)) else {
            throw transcriptError("The ‘\(name)’ engine requires macOS \(engine.minimum_macos) or later.",
                                  code: "transcript_capability_missing")
        }
        return engine
    }
}

struct TranscriptProviderEvent: Decodable {
    let schema_version: Int
    let job_id: String
    let fingerprint: String
    let event: String
    let status: String
    let track_id: String?
    let progress: Double?
    let phase: String?
    let error: String?
    let warning: String?
}

struct TranscriptProviderCommand {
    struct Response {
        let output: Data
        let diagnostic: String
        let exitStatus: Int32

        func check() throws {
            guard exitStatus == 0 else {
                throw transcriptError(diagnostic.isEmpty ? "Transcriberrr exited with status \(exitStatus)." : diagnostic,
                                      code: "transcript_provider_failed")
            }
        }
    }

    let helper: URL
    let directory: URL

    /// Processor time used so far by the helper and the processes it started. A helper that
    /// waits on a lock or a dead connection for ever accumulates none.
    private static func processorTime(of pid: Int32) -> UInt64 {
        var total: UInt64 = 0
        var pending = [pid]
        var seen = Set<Int32>()
        while let next = pending.popLast(), seen.count < 64, seen.insert(next).inserted {
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(next, RUSAGE_INFO_V2, $0) }
            }
            if status == 0 { total &+= usage.ri_user_time &+ usage.ri_system_time }
            var children = [Int32](repeating: 0, count: 64)
            let bytes = children.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(next), $0.baseAddress, Int32($0.count))
            }
            if bytes > 0 { pending += children.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { $0 > 0 } }
        }
        return total
    }

    /// Redirect to files so large provider output cannot block on a full pipe.
    /// Read session events while the process runs. Retire each command's logs
    /// after collecting the response.
    ///
    /// `timeout` bounds a query that answers at once. `stall` bounds a long run instead: it
    /// ends a helper that for that long has neither written anything nor used processor time,
    /// however long recognition itself takes.
    func run(_ arguments: [String], input: URL? = nil, timeout: TimeInterval? = nil, stall: TimeInterval? = nil,
             cancelled: () -> Bool = { false }, started: (Int32) throws -> Void = { _ in },
             event: ((TranscriptProviderEvent) throws -> Void)? = nil) throws -> Response {
        if cancelled() { throw CancellationError() }
        let prefix = directory.appendingPathComponent(".provider-\(UUID().uuidString)")
        let outputURL = prefix.appendingPathExtension("out")
        let errorURL = prefix.appendingPathExtension("err")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        let inputHandle = try input.map(FileHandle.init(forReadingFrom:))
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer {
            try? output.close()
            try? errors.close()
            try? inputHandle?.close()
            try? reader.close()
        }

        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        process.executableURL = helper
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["TRANSCRIBERRR_PARENT_PID"] = String(getpid())
        process.environment = environment
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw transcriptError("Could not start Transcriberrr. Check the installed helper at \(helper.path).",
                                  code: "transcript_helper_unavailable")
        }
        let pid = process.processIdentifier
        let processGroup = getpgid(pid) == pid ? -pid : nil
        var finished = false
        defer {
            if !finished, process.isRunning || processGroup != nil {
                if let processGroup { _ = kill(processGroup, SIGTERM) }
                else { process.terminate() }
                let deadline = ContinuousClock.now + .seconds(2)
                func isRunning() -> Bool {
                    process.isRunning || (processGroup.map { kill($0, 0) == 0 } ?? false)
                }
                while isRunning() && .now < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if isRunning() {
                    _ = kill(processGroup ?? pid, SIGKILL)
                }
            }
            process.waitUntilExit()
        }
        try started(process.processIdentifier)

        let start = ContinuousClock.now
        let decoder = JSONDecoder()
        var line = Data()
        let maxLineLength = 65_536
        func written(_ url: URL) -> UInt64 {
            var info = stat()
            return stat(url.path, &info) == 0 ? UInt64(info.st_size) : 0
        }
        func deliverLine() throws {
            if let event, line.count <= maxLineLength,
               let decoded = try? decoder.decode(TranscriptProviderEvent.self, from: line) {
                try event(decoded)
            }
            line.removeAll(keepingCapacity: true)
        }
        func drain(upTo end: UInt64) throws {
            guard event != nil else { return }
            var offset = try reader.offset()
            while offset < end {
                guard let chunk = try reader.read(upToCount: Int(min(65_536, end - offset))), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                for byte in chunk {
                    if byte == 10 {
                        try deliverLine()
                    } else if line.count <= maxLineLength {
                        line.append(byte)
                    }
                }
                if cancelled() { throw CancellationError() }
            }
        }
        func progressMark() -> [UInt64] {
            [written(outputURL), written(errorURL), Self.processorTime(of: process.processIdentifier)]
        }
        var lastMark = stall == nil ? [] : progressMark()
        var lastProgress = start
        var nextStallCheck = start
        while process.isRunning {
            if cancelled() { throw CancellationError() }
            if let timeout, start.duration(to: .now) > .seconds(timeout) {
                throw transcriptError("Transcriberrr did not respond within \(Int(timeout)) seconds.",
                                      code: "transcript_provider_timeout")
            }
            if let stall, .now >= nextStallCheck {
                let mark = progressMark()
                if mark != lastMark {
                    lastMark = mark
                    lastProgress = .now
                } else if lastProgress.duration(to: .now) > .seconds(stall) {
                    throw transcriptError("Transcriberrr stopped responding. It wrote nothing and used no processor time "
                                          + "for \(Int(stall)) seconds. Retry the job.", code: "transcript_provider_timeout")
                }
                nextStallCheck = .now + .seconds(min(1, stall / 4))
            }
            try drain(upTo: min(written(outputURL), try reader.offset() + 1_048_576))
            // Keep polling provider output and cancellation, but handle a short-lived
            // helper as soon as it exits rather than waiting for the next poll.
            _ = exited.wait(timeout: .now() + .milliseconds(100))
        }
        if cancelled() { throw CancellationError() }
        try drain(upTo: written(outputURL))
        if !line.isEmpty { try deliverLine() }
        let diagnostics = try FileHandle(forReadingFrom: errorURL)
        defer { try? diagnostics.close() }
        let end = try diagnostics.seekToEnd()
        try diagnostics.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
        let detail = try diagnostics.read(upToCount: 16_384) ?? Data()
        let bytes = try event == nil ? reader.read(upToCount: 1_048_576) ?? Data() : Data()
        finished = true
        return Response(output: bytes, diagnostic: String(decoding: detail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines), exitStatus: process.terminationStatus)
    }
}

extension TranscriptJobStore {
    /// The Transcriberrr helper. `MPCUT_TRANSCRIBERRR_HELPER` comes first, so a script or test launch
    /// keeps its own helper. `chosen` is the helper the desktop app's Settings name; the CLI and the
    /// file worker never pass one. Without either, the installed Transcriberrr app supplies it.
    public static func helperURL(chosen: String? = nil) throws -> URL {
        let manager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIBERRR_HELPER"] {
            guard path.hasPrefix("/"), manager.isExecutableFile(atPath: path) else {
                throw transcriptError("Set MPCUT_TRANSCRIBERRR_HELPER to the absolute path of an executable Transcriberrr helper.",
                                      code: "transcript_helper_unavailable")
            }
            return URL(fileURLWithPath: path)
        }
        if let chosen, !chosen.isEmpty {
            guard chosen.hasPrefix("/"), manager.isExecutableFile(atPath: chosen) else {
                throw transcriptError("The Transcriberrr helper chosen in Settings is missing or cannot run. Choose it again in "
                                      + "Settings → Transcripts, or set Helper location to Automatic.",
                                      code: "transcript_helper_unavailable")
            }
            return URL(fileURLWithPath: chosen)
        }
        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.transcriberrr.app") {
            let helper = application.appendingPathComponent("Contents/Helpers/transcriberrr")
            if manager.isExecutableFile(atPath: helper.path) { return helper }
        }
        throw transcriptError("Install Transcriberrr or set MPCUT_TRANSCRIBERRR_HELPER to its batch helper.",
                              code: "transcript_helper_unavailable")
    }

    public static func capabilities(helper: URL, cancelled: () -> Bool = { false }) throws -> Data {
        let command = TranscriptProviderCommand(helper: helper, directory: FileManager.default.temporaryDirectory)
        let response = try command.run(["capabilities"], timeout: 15, cancelled: cancelled)
        try response.check()
        _ = try TranscriptProviderCapabilities.read(response.output)
        return response.output
    }

    /// Confirms that the helper can run a session with these options: that it is installed,
    /// speaks this session schema, and offers the engine, model, language and diarization asked for.
    /// An owner that runs the provider itself calls this before `prepare`, which decodes every
    /// recording, so the request fails in a second instead of after the audio is staged.
    public static func checkProvider(options: TranscriptJobOptions, helper: URL? = nil) throws {
        let command = TranscriptProviderCommand(helper: try helper ?? helperURL(),
                                                directory: FileManager.default.temporaryDirectory)
        _ = try command.settings(for: options)
    }
}

extension TranscriptProviderCommand {
    func settings(for options: TranscriptJobOptions, cancelled: () -> Bool = { false },
                  started: (Int32) throws -> Void = { _ in }) throws -> TranscriptProviderSettings {
        let response = try run(["capabilities"], timeout: 15, cancelled: cancelled, started: started)
        try response.check()
        return try TranscriptProviderSettings(capabilities: TranscriptProviderCapabilities.read(response.output),
                                              options: options)
    }
}

struct TranscriptProviderSettings {
    let providerVersion: String
    let sharedCacheRevision: String?
    let sharedExchangeVersion: Int
    let engine: TranscriptProviderCapabilities.Engine
    let model: String
    let language: String
    let diarize: Bool
    let speakers: Int?
    let models: [String]
    let diarizationIssue: String?

    init(capabilities: TranscriptProviderCapabilities, options: TranscriptJobOptions) throws {
        providerVersion = capabilities.version
        sharedCacheRevision = capabilities.cache_revision
        sharedExchangeVersion = capabilities.shared_cache_exchange_version ?? 1
        engine = try capabilities.select(options.engine)
        model = options.model ?? engine.default_model
        guard engine.model_source != "macos" || model == engine.default_model else {
            throw jobError("transcript_capability_missing", "Apple Speech uses its built-in model. Choose the default model for this engine.")
        }
        let requestedLanguage = options.language?.lowercased() ?? "en"
        guard ["en", "en-us", "english"].contains(requestedLanguage) else {
            throw transcriptError("The Transcriberrr session engine supports English. Choose English or import an existing transcript.",
                                  code: "transcript_capability_missing")
        }
        language = "en"
        diarize = options.expectedSpeakers != nil || (options.diarization ?? engine.diarization)
        speakers = options.expectedSpeakers
        let supportedLimit = engine.diarization_speaker_limit.flatMap { $0 > 0 ? $0 : nil }
        if let speakers, speakers < 1 || (supportedLimit.map { speakers > $0 } ?? false) {
            throw transcriptError("The ‘\(engine.name)’ engine cannot use the requested speaker count.",
                                  code: "transcript_capability_missing")
        }
        diarizationIssue = diarize && (!engine.diarization || supportedLimit == nil)
            ? "The ‘\(engine.name)’ engine does not support the requested diarization."
            : nil
        var required = engine.model_source == "macos" ? [] : [model]
        if engine.name == "qwen3" { required.append("Qwen/Qwen3-ForcedAligner-0.6B") }
        models = required
    }

    func issue(for track: TranscriptJobTrack) -> String? {
        track.role == "isolated_mic" ? nil : diarizationIssue
    }

    func modelIDs(for track: TranscriptJobTrack) -> [String] {
        diarize && issue(for: track) == nil && track.role != "isolated_mic" ? models + ["sortformer"] : models
    }

    func key(for track: TranscriptJobTrack, revisions: [String: String]) -> String? {
        guard issue(for: track) == nil else { return nil }
        let ids = modelIDs(for: track)
        let versions = ids.compactMap { revisions[$0] }
        guard versions.count == ids.count else { return nil }
        guard let values = keyValues(for: track) else { return nil }
        return digestKey(values + versions)
    }

    func settingsKey(for track: TranscriptJobTrack) -> String? {
        keyValues(for: track).map(digestKey)
    }

    private func keyValues(for track: TranscriptJobTrack) -> [String]? {
        let effectiveDiarization = diarize && track.role != "isolated_mic"
        let platform: String
        if engine.model_source == "macos" {
            if let sharedCacheRevision, !sharedCacheRevision.isEmpty {
                guard let revision = engine.cache_revision else { return nil }
                platform = revision
            } else {
                platform = ProcessInfo.processInfo.operatingSystemVersionString
            }
        } else {
            platform = ""
        }
        let keyModel = model.hasPrefix("~") && sharedCacheRevision != nil
            ? (model as NSString).expandingTildeInPath : model
        return ["pcm-v1", "session-v1", sharedCacheRevision ?? providerVersion, engine.name, keyModel, language,
                String(effectiveDiarization), effectiveDiarization ? speakers.map(String.init) ?? "" : "",
                platform, track.evidence, track.stagedChannel.map(String.init) ?? "", track.streamIndex.map(String.init) ?? ""]
    }

    private func digestKey(_ values: [String]) -> String {
        if sharedCacheRevision != nil {
            return TranscriptStore.digest(Data(values.joined(separator: "\u{0}").utf8))
        }
        let encoded = (try? JSONEncoder().encode(values)) ?? Data()
        return TranscriptStore.digest(encoded)
    }

    private struct CachedModel: Decodable {
        let id: String
        let cached: Bool
        let path: String?
        let revision: String?
    }

    func revisions(for ids: Set<String>, using command: TranscriptProviderCommand, download: Bool,
                   stall: TimeInterval? = nil,
                   cancelled: () -> Bool, started: (Int32) throws -> Void) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let requested = ids.sorted()
        func status() throws -> [CachedModel] {
            let response = try command.run(requested.flatMap { ["--cached-model", $0] } + ["--offline"],
                                           timeout: 30, cancelled: cancelled, started: started)
            try response.check()
            return try JSONDecoder().decode([CachedModel].self, from: response.output)
        }
        var known = try status()
        let missing = requested.filter { id in !known.contains { $0.id == id && $0.cached } }
        if download && !missing.isEmpty {
            // A download can fail after installing some models. Query the
            // resulting inventory and let each track proceed with what it needs.
            _ = try command.run(missing.flatMap { ["--download-model", $0] }, stall: stall,
                                cancelled: cancelled, started: started)
            known = try status()
        }
        let pairs = try known.compactMap { model -> (String, String)? in
            guard model.cached, let path = model.path else { return nil }
            if sharedCacheRevision != nil {
                guard let revision = model.revision, TranscriptStore.validDigest(revision) else { return nil }
                return (model.id, revision)
            }
            do {
                return (model.id, try Self.revision(of: URL(fileURLWithPath: path), cancelled: cancelled))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    private static func revision(of url: URL, cancelled: () -> Bool) throws -> String {
        let components = url.pathComponents
        if let marker = components.lastIndex(of: "snapshots"), components.indices.contains(marker + 1) {
            let revision = components[marker + 1]
            if revision.count >= 40, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                return components.dropFirst(marker + 1).joined(separator: "/")
            }
        }
        // Manually installed models lack a hub revision. Record their resolved
        // file identities so a replacement or edit invalidates cached words.
        let manager = FileManager.default
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        var inventory: [String] = []
        func inspect(_ file: URL) throws {
            if cancelled() { throw CancellationError() }
            let resolved = file.resolvingSymlinksInPath()
            guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return }
            let stamp = try SourceIdentity(resolved)
            inventory.append("\(file.path)\u{0}\(stamp)\u{0}\(String(describing: stamp.changeTime))")
        }
        if isDirectory {
            var readError: Error?
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                      errorHandler: { _, error in
                readError = error
                return false
            }) else {
                throw jobError("transcript_model_missing", "Transcriberrr cannot read the model at \(url.path).")
            }
            for case let file as URL in enumerator { try inspect(file) }
            if let readError { throw readError }
            inventory.sort()
        } else {
            try inspect(url)
        }
        guard !inventory.isEmpty else {
            throw jobError("transcript_model_missing", "Transcriberrr found no model files at \(url.path).")
        }
        return TranscriptStore.digest(try JSONEncoder().encode(inventory))
    }
}
