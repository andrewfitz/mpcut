import Foundation
import MPCutCore

@MainActor
final class MCPAnalysisCleanup {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var pending: Bool { count > 0 }

    func begin() -> @MainActor () -> Void {
        count += 1
        return {
            self.count -= 1
            guard self.count == 0 else { return }
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func wait() async {
        guard pending else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Native callbacks finish the same receipt returned by the initiating client.
/// Holding its own cancellation closure keeps a later GUI operation independent.
@MainActor
final class MCPAnalysisReceipt {
    let id = UUID().uuidString
    let owner: String
    let revision: Int
    let kind: String
    private(set) var state = "running"
    private(set) var cancellationRequested = false
    let cleanup = MCPAnalysisCleanup()
    private var detail: [String: Any] = [:]
    var cancelNative: (() -> Void)?
    var nativeProgress: (() -> Double?)?
    var cancelledDetail: (() -> [String: Any])?

    init(owner: String, revision: Int, kind: String) {
        self.owner = owner
        self.revision = revision
        self.kind = kind
    }

    func finish(_ state: String, detail: [String: Any] = [:]) {
        guard self.state == "running" else { return }
        self.state = state
        self.detail = state == "cancelled" ? (cancelledDetail?() ?? [:]).merging(detail) { _, new in new } : detail
        cancelNative = nil
        nativeProgress = nil
        cancelledDetail = nil
    }

    func cancel() {
        guard state == "running", !cancellationRequested else { return }
        cancellationRequested = true
        cancelNative?()
    }

    var snapshot: [String: Any] {
        var result = detail
        result["job"] = id
        result["inputRevision"] = revision
        result["kind"] = kind
        result["status"] = state
        result["origin"] = "mcp"
        if cancellationRequested && state == "running" { result["cancellationRequested"] = true }
        if let progress = nativeProgress?() { result["progress"] = progress }
        if state == "succeeded" { result["progress"] = 1.0 }
        return result
    }
}

@MainActor
final class MCPAnalysisJobs {
    @MainActor
    private struct WaveformRequest {
        let token = EditCancellation()
        let cleanup = MCPAnalysisCleanup()
    }

    private var receipts: [MCPAnalysisReceipt] = []
    private var retired: [MCPAnalysisReceipt] = []
    private var waveformRequests: [String: [UUID: WaveformRequest]] = [:]

    var hasRunningJobs: Bool {
        !waveformRequests.isEmpty || retired.contains { $0.cleanup.pending }
            || receipts.contains { $0.state == "running" || $0.cleanup.pending }
    }

    func reserve(session: ProjectSession, kind: String) throws -> MCPAnalysisReceipt {
        retired.removeAll { !$0.cleanup.pending }
        if receipts.count + retired.count >= 64 {
            guard let old = receipts.firstIndex(where: { $0.state != "running" && !$0.cleanup.pending }) else {
                throw MCPCommandError("busy", "The active analysis job limit has been reached.")
            }
            receipts.remove(at: old)
        }
        let receipt = MCPAnalysisReceipt(owner: session.mcpHandle, revision: session.mcpRevision, kind: kind)
        receipts.append(receipt)
        return receipt
    }

    func lookup(_ id: String?, session: ProjectSession) throws -> MCPAnalysisReceipt {
        guard let id, let item = receipts.first(where: { $0.id == id && $0.owner == session.mcpHandle }) else {
            throw MCPCommandError("unknown_job", "No retained analysis job with this ID belongs to this project.")
        }
        return item
    }

    func disable() {
        revoke(receipts)
        receipts.removeAll()
        for requests in waveformRequests.values {
            for request in requests.values { request.token.cancel() }
        }
    }

    func close(owner: String) {
        revoke(receipts.filter { $0.owner == owner })
        receipts.removeAll { $0.owner == owner }
        if let requests = waveformRequests[owner] {
            for request in requests.values { request.token.cancel() }
        }
    }

    private func revoke(_ items: [MCPAnalysisReceipt]) {
        retired.removeAll { !$0.cleanup.pending }
        for receipt in items {
            receipt.cancel()
            if receipt.cleanup.pending { retired.append(receipt) }
        }
    }

    func cancelAndWaitForJobs() async {
        let requests = waveformRequests.values.flatMap { $0.values }
        let jobs = receipts + retired
        for receipt in jobs { receipt.cancel() }
        for request in requests { request.token.cancel() }
        for receipt in jobs { await receipt.cleanup.wait() }
        for request in requests { await request.cleanup.wait() }
        retired.removeAll { !$0.cleanup.pending }
    }

    func waveform(owner: String, work: @escaping @Sendable (EditCancellation) throws -> AudioEnvelope) async throws -> AudioEnvelope {
        // The native scan queue bounds decoding. Also bound the number of
        // requests it can be made to retain while other scans are running.
        guard waveformRequests.values.reduce(0, { $0 + $1.count }) < 8 else {
            throw MCPCommandError("busy", "Waveform requests are queued. Retry after one finishes.")
        }
        let id = UUID(), request = WaveformRequest()
        let token = request.token, endWork = request.cleanup.begin()
        waveformRequests[owner, default: [:]][id] = request
        defer {
            waveformRequests[owner]?[id] = nil
            if waveformRequests[owner]?.isEmpty == true { waveformRequests[owner] = nil }
            endWork()
        }
        return try await withTaskCancellationHandler {
            try await EditorAnalysisQueues.scan {
                if token.isCancelled { throw MCPCommandError("cancelled", "Waveform analysis was cancelled.") }
                return try work(token)
            }
        } onCancel: { token.cancel() }
    }
}
