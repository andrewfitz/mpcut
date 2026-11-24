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
    var nativeDetail: (() -> [String: Any])?
    var cancelledDetail: (() -> [String: Any])?
    var completionDetail: (() -> [String: Any])?
    var mediaLocateRows: [ProjectMediaSearchRow]?
    var sceneRequest: MCPSceneRequest?
    var sceneCoverage: (() -> [String: SceneScanProgress])?
    fileprivate var sceneWorkerOrigin: String?
    fileprivate var hasEditorSubscriber: Bool
    private var sceneSubscribers: MCPSceneSubscribers?
    private var finishedSceneSources = Set<String>()

    init(owner: String, revision: Int, kind: String) {
        self.owner = owner
        self.revision = revision
        self.kind = kind
        hasEditorSubscriber = owner.isEmpty
    }

    func finish(_ state: String, detail: [String: Any] = [:]) {
        guard self.state == "running" else { return }
        self.state = state
        self.detail = runningDetail()
        self.detail.merge(completionDetail?() ?? [:]) { _, new in new }
        if state == "cancelled" {
            self.detail.merge(cancelledDetail?() ?? [:]) { _, new in new }
        }
        self.detail.merge(detail) { _, new in new }
        cancelNative = nil
        nativeProgress = nil
        nativeDetail = nil
        cancelledDetail = nil
        completionDetail = nil
        sceneSubscribers?.finish(state, detail: self.detail)
        sceneSubscribers = nil
        sceneCoverage = nil
    }

    func cancel() {
        guard state == "running", !cancellationRequested else { return }
        cancellationRequested = true
        cancelNative?()
    }

    func subscribe(_ receipt: MCPAnalysisReceipt, selection: MCPSceneSelection? = nil) {
        let subscribers = sceneSubscribers ?? MCPSceneSubscribers(worker: self)
        sceneSubscribers = subscribers
        subscribers.add(receipt, selection: selection)
        if let selection, finishedSceneSources.contains(selection.source) {
            subscribers.finishSources([selection.source])
        }
    }

    func finishSceneSources(_ ids: [String]) {
        finishedSceneSources.formUnion(ids)
        sceneSubscribers?.finishSources(ids)
    }

    func cancelFromEditor() {
        if owner.isEmpty {
            guard hasEditorSubscriber else { return }
            hasEditorSubscriber = false
            if sceneSubscribers?.hasSubscribers == true { return }
        }
        cancel()
    }

    var snapshot: [String: Any] {
        var result = detail.merging(runningDetail()) { _, new in new }
        if let sceneRequest {
            result["scope"] = sceneRequest.target == nil ? "all" : "selected"
            result["target"] = sceneRequest.target
            result["policy"] = sceneRequest.policyName
            result["worker_origin"] = sceneWorkerOrigin
        }
        result["job_id"] = id
        result["input_revision"] = revision
        result["kind"] = kind
        result["status"] = state
        result["origin"] = "mcp"
        if cancellationRequested && state == "running" { result["cancellation_requested"] = true }
        if let progress = nativeProgress?() { result["progress"] = progress }
        if state == "succeeded" { result["progress"] = 1.0 }
        return result
    }

    private func runningDetail() -> [String: Any] {
        var result = nativeDetail?() ?? [:]
        if let sceneCoverage { result["coverage"] = mcpSceneCoverage(sceneCoverage()) }
        return result
    }
}

struct MCPSceneSelection {
    let source: String
    let target: String
    let interval: SceneScanScope?

    func project(_ progress: SceneScanProgress?) -> SceneScanProgress {
        guard case let .range(start, end)? = interval else {
            return progress ?? SceneScanProgress(requested: .fullSource)
        }
        func covered(_ value: RationalTime?) -> RationalTime? {
            guard let value, value >= start else { return nil }
            return min(value, end)
        }
        let decoded = covered(progress?.decoded)
        let confirmed = covered(progress?.confirmed)
        let ratio = ((decoded ?? start).seconds - start.seconds) / (end.seconds - start.seconds)
        let published = progress?.fraction == 1 && confirmed == end
        return SceneScanProgress(requested: .range(start: start, end: end), requestedThrough: end,
                                 decoded: decoded, confirmed: confirmed, durable: covered(progress?.durable),
                                 fraction: published ? 1 : min(0.999, max(0, ratio)),
                                 persistenceError: progress?.persistenceError)
    }
}

/// A scene worker is owned by the editor. Each MCP caller owns a separate
/// receipt and can release its own interest without cancelling another caller.
@MainActor
private final class MCPSceneSubscribers {
    private weak var worker: MCPAnalysisReceipt?
    private struct Subscription {
        let receipt: MCPAnalysisReceipt
        let endWork: @MainActor () -> Void
        let selection: MCPSceneSelection?
    }

    private var subscriptions: [String: Subscription] = [:]
    var hasSubscribers: Bool { !subscriptions.isEmpty }

    init(worker: MCPAnalysisReceipt) { self.worker = worker }

    func add(_ receipt: MCPAnalysisReceipt, selection: MCPSceneSelection?) {
        guard let worker else { return }
        subscriptions[receipt.id] = Subscription(receipt: receipt, endWork: receipt.cleanup.begin(), selection: selection)
        receipt.sceneRequest = selection.map { MCPSceneRequest(target: $0.target, policy: .reuse, interval: $0.interval) }
            ?? worker.sceneRequest
        receipt.sceneWorkerOrigin = worker.owner.isEmpty ? "editor" : "mcp"
        if let selection {
            receipt.sceneCoverage = { [weak worker] in
                [selection.target: selection.project(worker?.sceneCoverage?()[selection.source])]
            }
            receipt.nativeProgress = { [weak receipt] in
                min(0.999, receipt?.sceneCoverage?()[selection.target]?.fraction ?? 0)
            }
        } else {
            receipt.nativeProgress = { [weak worker] in worker?.nativeProgress?() }
            receipt.nativeDetail = { [weak worker] in worker?.nativeDetail?() ?? [:] }
            receipt.sceneCoverage = { [weak worker] in worker?.sceneCoverage?() ?? [:] }
        }
        receipt.cancelNative = { [weak self, weak receipt] in
            guard let self, let receipt else { return }
            self.remove(receipt)
        }
    }

    func finishSources(_ ids: [String]) {
        let completed = subscriptions.values.filter { item in
            item.selection.map { ids.contains($0.source) } ?? false
        }
        for subscription in completed {
            subscriptions.removeValue(forKey: subscription.receipt.id)
            let target = subscription.selection?.target
            subscription.receipt.finish("succeeded", detail: ["sources": target.map { [$0] } ?? []])
            subscription.endWork()
        }
        if !completed.isEmpty, subscriptions.isEmpty, worker?.hasEditorSubscriber == false {
            worker?.cancel()
        }
    }

    private func remove(_ receipt: MCPAnalysisReceipt) {
        guard let worker else { return }
        if subscriptions.count == 1 && !worker.hasEditorSubscriber {
            // The final MCP subscriber stays attached until the flush has
            // reported its actual durable coverage.
            worker.cancel()
        } else if let subscription = subscriptions.removeValue(forKey: receipt.id) {
            receipt.finish("cancelled")
            subscription.endWork()
        }
    }

    func finish(_ state: String, detail: [String: Any]) {
        let subscriptions = Array(subscriptions.values)
        self.subscriptions.removeAll()
        for subscription in subscriptions {
            let item = subscription.receipt
            if let selection = subscription.selection {
                let sources = detail["sources"] as? [String] ?? []
                var subset = detail
                subset["coverage"] = nil
                subset["sources"] = sources.contains(selection.source) ? [selection.target] : []
                item.finish(state, detail: subset)
            } else {
                item.finish(state, detail: detail)
            }
        }
        if let cleanup = worker?.cleanup, cleanup.pending {
            Task {
                await cleanup.wait()
                for subscription in subscriptions { subscription.endWork() }
            }
        } else {
            for subscription in subscriptions { subscription.endWork() }
        }
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
        let window = owner.prefix(while: { $0 != "/" }) + "/"
        revoke(receipts.filter { $0.owner.hasPrefix(window) })
        receipts.removeAll { $0.owner.hasPrefix(window) }
        for (handle, requests) in waveformRequests where handle.hasPrefix(window) {
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
