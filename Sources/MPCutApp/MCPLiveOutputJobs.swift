import Foundation
import MPCutCore

/// Progress and already-published outputs must survive an interruption between queue items.
final class MCPLiveOutputProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = 0.0
    private var outputs: [String] = []

    func update(_ fraction: Double) {
        guard fraction.isFinite else { return }
        lock.withLock { progress = min(1, max(progress, fraction)) }
    }
    func published(_ url: URL) { lock.withLock { outputs.append(url.path) } }
    var snapshot: [String: Any] {
        lock.withLock { ["progress": progress, "outputs": outputs] }
    }
}

@MainActor
final class MCPLiveOutputJobs {
    typealias Work = @Sendable (MCPLiveOutputProgress) throws -> [String: Any]
    private enum Outcome {
        case success([String: Any])
        case failure([String: Any])
    }

    private final class Job {
        let id = UUID().uuidString
        let owner: String
        let revision: Int
        let nativeCancellation: EditCancellation?
        let progress = MCPLiveOutputProgress()
        var visible = true
        var state = "running"
        var task: Task<Outcome, Never>?
        var detail: [String: Any] = [:]
        init(owner: String, revision: Int, nativeCancellation: EditCancellation?) {
            self.owner = owner
            self.revision = revision
            self.nativeCancellation = nativeCancellation
        }
        func cancel() {
            guard let task else { return }
            nativeCancellation?.cancel()
            task.cancel()
        }
        var status: [String: Any] {
            var result = progress.snapshot
            result["job_id"] = id
            result["state"] = task?.isCancelled == true ? "cancelling" : state
            result["input_revision"] = revision
            return result.merging(detail) { _, value in value }
        }
    }

    private var jobs: [Job] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    var hasRunningJobs: Bool { jobs.contains { $0.task != nil } }

    func start(owner: String, revision: Int, nativeCancellation: EditCancellation? = nil,
               finished: @escaping @MainActor () -> Void = {}, work: @escaping Work) throws -> [String: Any] {
        guard shutdownWaiters.isEmpty else { throw MCPCommandError("busy", "Output jobs are shutting down.") }
        guard jobs.filter({ $0.task != nil }).count < 4 else {
            throw MCPCommandError("busy", "Four output jobs are active. Wait for a job to finish.")
        }
        if jobs.count >= 32, let i = jobs.firstIndex(where: { $0.task == nil }) { jobs.remove(at: i) }
        let job = Job(owner: owner, revision: revision, nativeCancellation: nativeCancellation)
        let progress = job.progress
        let task = Task.detached(priority: .userInitiated) { () -> Outcome in
            do {
                try Task.checkCancellation()
                return .success(try work(progress))
            } catch {
                // Large export diagnostics need JSON conversion before they can be returned over MCP.
                return .failure(Self.errorFields(error))
            }
        }
        let handler = nativeCancellation?.onCancel { task.cancel() }
        job.task = task
        jobs.append(job)
        Task {
            switch await task.value {
            case .success(let value):
                job.progress.update(1)
                job.state = "succeeded"
                job.detail = ["result": value]
            case .failure(let fields):
                job.state = fields["code"] as? String == "cancelled" ? "cancelled" : "failed"
                job.detail = ["error": fields]
            }
            if let handler { nativeCancellation?.removeCancellationHandler(handler) }
            job.task = nil
            if !job.visible { jobs.removeAll { $0 === job } }
            finished()
            if !hasRunningJobs {
                let waiters = shutdownWaiters
                shutdownWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return job.status
    }

    nonisolated static func errorFields(_ error: Error) -> [String: Any] {
        if let issue = error as? CutError, let data = try? MCPSchemas.encodeResult(issue), data.count <= 750_000,
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return fields }
        let code = (error as? CutError)?.code ?? (error as? MCPCommandError)?.code
            ?? (error is CancellationError ? "cancelled" : "output_failed")
        let message = String(decoding: error.localizedDescription.utf8.prefix(32_768), as: UTF8.self)
        var fields: [String: Any] = ["code": code, "message": message]
        if error is CutError { fields["truncated"] = true }
        return fields
    }

    func status(owner: String, id: String, cancel: Bool) throws -> [String: Any] {
        guard let job = jobs.first(where: { $0.visible && $0.owner == owner && $0.id == id }) else {
            throw MCPCommandError("unknown_job", "This project has no retained output job with that ID.")
        }
        if cancel { job.cancel() }
        return job.status
    }

    func close(owner: String) {
        let window = owner.prefix(while: { $0 != "/" }) + "/"
        revoke { $0.owner.hasPrefix(window) }
    }

    func disable() { revoke { _ in true } }

    func cancelAndWaitForJobs() async {
        guard hasRunningJobs else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
            jobs.forEach { $0.cancel() }
        }
    }

    private func revoke(_ matches: (Job) -> Bool) {
        for job in jobs where matches(job) {
            job.visible = false
            job.cancel()
        }
        jobs.removeAll { !$0.visible && $0.task == nil }
    }
}
