import Darwin
import Foundation

/// The admission record is published before starting the CLI. A worker crash can
/// leave the outcome unknown, but the same operation ID cannot start a second CLI.
struct MCPFileReceipts {
    struct Record: Codable {
        let id: UUID
        let tool: String
        let fingerprint: Data
        let admittedAt: Date
        var endedAt: Date?
        var terminalStatus: Data?
    }

    struct Admission {
        let directory: URL
        let lock: FileHandle
    }

    enum Lookup {
        case existing(Record)
        case admitted(Admission)
    }

    static var standalone: Self {
        if let path = ProcessInfo.processInfo.environment["MPCUT_FILE_RECEIPT_DIRECTORY"], path.hasPrefix("/") {
            return Self(root: URL(fileURLWithPath: path, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(root: support.appendingPathComponent("MPCut/File Job Receipts/v1", isDirectory: true))
    }

    let root: URL
    private let files = FileManager.default
    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let maxReceipts = 8_192
    private static let maxResultBytes = 256 * 1_024 * 1_024

    func lookupOrAdmit(id: UUID, tool: String, fingerprint: Data, prepare: () throws -> Void) throws -> Lookup {
        try withLock {
            if let record = try record(id), !isExpired(record) { return .existing(record) }
            let directories = try receiptDirectories()
            var receiptCount = directories.count
            // Reclaim old receipts opportunistically and always before admitting beyond capacity.
            if directories.count >= Self.maxReceipts || directories.count.isMultiple(of: 64) {
                for (id, folder) in directories {
                    guard let record = try record(id) else {
                        try files.removeItem(at: folder)
                        receiptCount -= 1
                        continue
                    }
                    if isExpired(record) {
                        try files.removeItem(at: folder)
                        receiptCount -= 1
                    } else if record.endedAt == nil, try !isActive(id) {
                        try recordInterruption(record)
                    }
                }
            }
            if let existing = try record(id), isExpired(existing) {
                try files.removeItem(at: directory(id))
                receiptCount -= 1
            }
            guard receiptCount < Self.maxReceipts else {
                throw MCPCommandError("job_receipt_capacity", "The standalone receipt store is full. New jobs can start as receipts reach their seven-day expiry.")
            }
            try prepare()
            let folder = directory(id)
            // A worker can die after creating the directory but before writing the
            // record. No CLI runs until both steps and record publication succeed.
            if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
            try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                let lock = try openLock(folder.appendingPathComponent("active.lock"), flags: O_CREAT | O_EXCL)
                guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw posixError() }
                try save(Record(id: id, tool: tool, fingerprint: fingerprint, admittedAt: Date()))
                return .admitted(Admission(directory: folder, lock: lock))
            } catch {
                try? files.removeItem(at: folder)
                throw error
            }
        }
    }

    func finish(id: UUID, status: [String: Any]) throws {
        try withLock {
            guard var record = try record(id) else { throw unavailable() }
            record.endedAt = Date()
            record.terminalStatus = try JSONSerialization.data(withJSONObject: status)
            let folder = directory(id)
            let stdout = folder.appendingPathComponent("stdout")
            try? publishResult(from: stdout, to: folder.appendingPathComponent("result.json"))
            discardStaging(in: folder)
            // Record the outcome even if the result cannot be published.
            try save(record)
        }
    }

    func abort(id: UUID) {
        try? withLock { try files.removeItem(at: directory(id)) }
    }

    func access<T>(id: UUID, _ body: (Record, String, URL) throws -> T) throws -> T {
        try withLock {
            guard let record = try record(id), !isExpired(record) else { throw unavailable() }
            let state: String
            if let status = try terminalStatus(record), let terminalState = status["state"] as? String {
                state = terminalState
            } else {
                if try isActive(id) {
                    state = "running"
                } else {
                    try recordInterruption(record)
                    state = "outcome_unknown"
                }
            }
            return try body(record, state, directory(id).appendingPathComponent("result.json"))
        }
    }

    func terminalStatus(_ record: Record) throws -> [String: Any]? {
        guard let data = record.terminalStatus else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func release(id: UUID) throws {
        try access(id: id) { _, state, output in
            guard state != "running" else {
                throw MCPCommandError("job_running", "Poll file_job_status_read until the job ends.")
            }
            // Keep the operation record even for interrupted work.
            if files.fileExists(atPath: output.path) { try files.removeItem(at: output) }
            discardStaging(in: output.deletingLastPathComponent())
        }
    }

    private func publishResult(from stdout: URL, to output: URL) throws {
        guard let size = try stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (0...Self.maxResultBytes).contains(size) else { return }
        try reserveResultBytes(size)
        try files.moveItem(at: stdout, to: output)
    }

    private func reserveResultBytes(_ size: Int) throws {
        let budget = root.appendingPathComponent("result-bytes")
        // Reserve space before publishing. A crash or release can overestimate
        // usage, which is reconciled against actual files when the budget fills.
        if let value = try? String(contentsOf: budget, encoding: .utf8),
           let reserved = Int(value), (0...(Self.maxResultBytes - size)).contains(reserved) {
            try Data(String(reserved + size).utf8).write(to: budget, options: .atomic)
            return
        }
        var results: [(url: URL, size: Int, date: Date)] = []
        for (_, folder) in try receiptDirectories() {
            let output = folder.appendingPathComponent("result.json")
            guard let values = try? output.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let date = values.contentModificationDate else { continue }
            results.append((output, size, date))
        }
        var total = results.reduce(size) { $0 + $1.size }
        for result in results.sorted(by: { $0.date < $1.date }) where total > Self.maxResultBytes {
            try files.removeItem(at: result.url)
            total -= result.size
        }
        try Data(String(total).utf8).write(to: budget, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let handle = try openLock(root.appendingPathComponent("store.lock"), flags: O_CREAT)
        defer { try? handle.close() }
        while flock(handle.fileDescriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw posixError() }
        }
        return try body()
    }

    private func openLock(_ url: URL, flags: Int32) throws -> FileHandle {
        let fd = open(url.path, flags | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func isActive(_ id: UUID) throws -> Bool {
        let handle = try openLock(directory(id).appendingPathComponent("active.lock"), flags: 0)
        defer { try? handle.close() }
        if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 { return false }
        if errno == EWOULDBLOCK { return true }
        throw posixError()
    }

    private func receiptDirectories() throws -> [(UUID, URL)] {
        try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).compactMap {
            guard let id = UUID(uuidString: $0.lastPathComponent) else { return nil }
            return (id, $0)
        }
    }

    private func isExpired(_ record: Record) -> Bool {
        guard let ended = record.endedAt else { return false }
        return Date().timeIntervalSince(ended) >= Self.retention
    }

    private func recordInterruption(_ record: Record) throws {
        var interrupted = record
        interrupted.endedAt = Date()
        interrupted.terminalStatus = try JSONSerialization.data(withJSONObject: [
            "job_id": record.id.uuidString, "tool": record.tool, "state": "outcome_unknown"
        ])
        // The CLI may still hold open spool descriptors. Unlink these private paths;
        // its descriptors can close normally without leaving an untracked result.
        let folder = directory(record.id)
        discardStaging(in: folder)
        try? files.removeItem(at: folder.appendingPathComponent("result.json"))
        try save(interrupted)
    }

    private func discardStaging(in folder: URL) {
        for name in ["request.json", "stdout", "diagnostics", "frame-work"] {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func record(_ id: UUID) throws -> Record? {
        let url = directory(id).appendingPathComponent("receipt.json")
        guard files.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    private func save(_ record: Record) throws {
        try JSONEncoder().encode(record).write(to: directory(record.id).appendingPathComponent("receipt.json"), options: .atomic)
    }

    private func unavailable() -> MCPCommandError {
        MCPCommandError("job_unavailable", "This standalone job is unknown or its seven-day receipt has expired.")
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
