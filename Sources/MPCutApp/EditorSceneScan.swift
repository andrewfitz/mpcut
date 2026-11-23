import Foundation
import MPCutCore

/// A batch captures its source clocks and selection before any background work begins.
struct EditorSceneRequest: Sendable {
    let id: String
    let media: MediaInfo
    var scope: SceneScanScope = .fullSource

    var duration: Double {
        switch scope {
        case .fullSource: return max(0, media.duration.seconds)
        case .range(let start, let end): return max(0, end.seconds - start.seconds)
        }
    }

    var start: RationalTime {
        if case .range(let start, _) = scope { return start }
        return .zero
    }

    var name: String { media.url.lastPathComponent }
}

private struct SceneRecording: Hashable, Sendable {
    let identity: SourceIdentity
    let changeTime: SourceIdentity.ChangeTime?
    let origin: RationalTime
    let scope: SceneScanScope
    let stream: Int?
    let duration: RationalTime

    init(_ request: EditorSceneRequest) {
        identity = request.media.identity
        changeTime = identity.changeTime
        origin = request.media.origin
        scope = request.scope
        stream = request.media.videoStream?.index
        duration = request.media.duration
    }
}

struct EditorSceneMarker: Sendable {
    let time: RationalTime
    let view: Int
}

@MainActor
final class EditorSceneScan {
    let cache = SceneScanSession.shared
    private var token: EditCancellation?
    private var inspections: [SceneRecording: SceneRequestInspection] = [:]
    private var inspectionGeneration = 0
    private(set) var inspectionRevision = 0
    private(set) var requests: [EditorSceneRequest] = []
    private(set) var checkpointRequests: [EditorSceneRequest] = []
    private(set) var coverage: [String: SceneScanProgress] = [:]
    private(set) var progress: Double?
    private(set) var status: String?
    private(set) var paused = false

    func cancel() {
        guard let token, !token.isCancelled else { return }
        token.cancel()
        status = "Saving scene progress…"
    }

    func pruneCheckpoints(keeping media: [MediaInfo]) {
        let identities = Set(media.map(\.identity))
        checkpointRequests.removeAll { !identities.contains($0.media.identity) }
        inspections = inspections.filter { identities.contains($0.key.identity) }
        if progress == nil, requests.contains(where: { !identities.contains($0.media.identity) }) {
            requests = []
            coverage = [:]
            status = nil
            paused = false
        }
    }

    func invalidateInspection() {
        inspectionGeneration += 1
        inspectionRevision += 1
        inspections = [:]
    }

    func reset(preservingCheckpoints: Bool = false) {
        token?.cancel()
        token = nil
        invalidateInspection()
        requests = []
        if !preservingCheckpoints { checkpointRequests = [] }
        coverage = [:]
        progress = nil
        status = nil
        paused = false
    }

    /// A completed report shadows the markers of a replacement until it publishes.
    func start(_ requests: [EditorSceneRequest], policy: SceneScanPolicy, preference: SidecarPreference,
               receipt: MCPAnalysisReceipt?,
               update: @escaping @MainActor () -> Void,
               markers: @escaping @MainActor (EditorSceneRequest, [EditorSceneMarker], Bool, SceneScanProgress?) -> Void,
               report: @escaping @MainActor (EditorSceneRequest, SceneReport, SceneScanOutcome.State) -> Void) {
        guard token == nil, !requests.isEmpty else { return }
        let token = EditCancellation()
        self.token = token
        inspectionGeneration += 1
        self.requests = requests
        for request in requests where !checkpointRequests.contains(where: { SceneRecording($0) == SceneRecording(request) }) {
            checkpointRequests.append(request)
        }
        progress = 0
        paused = false
        coverage = Dictionary(uniqueKeysWithValues: requests.map { request in
            let inspection = inspections[SceneRecording(request)]
            let cached: SceneScanProgress?
            switch policy {
            case .reuse: cached = inspection?.completed ?? inspection?.pending
            case .resume: cached = inspection?.pending ?? inspection?.completed
            case .restart: cached = nil
            }
            return (request.id, cached ?? SceneScanProgress(requested: request.scope))
        })
        status = "Scanning for scenes in \(requests[0].name)…"
        let endWork = receipt?.cleanup.begin()
        let groups = Dictionary(grouping: requests, by: SceneRecording.init)
        var seen = Set<SceneRecording>()
        let recordings = requests.filter { seen.insert(SceneRecording($0)).inserted }
        let duration = recordings.reduce(0) { $0 + $1.duration }
        let cachedDuration = recordings.reduce(0.0) { $0 + $1.duration * (coverage[$1.id]?.fraction ?? 0) }
        if duration > 0 { progress = min(0.999, cachedDuration / duration) }
        let cache = cache

        Task {
            defer { endWork?() }
            var finished: [String] = []
            var completedDuration = 0.0
            var remainingCachedDuration = cachedDuration
            var allCurrent = true
            var diskIssue: String?
            var error: Error?
            for request in recordings {
                guard !token.isCancelled else { break }
                let aliases = groups[SceneRecording(request)] ?? [request]
                let previous = completedDuration
                remainingCachedDuration -= request.duration * (coverage[request.id]?.fraction ?? 0)
                let pendingCachedDuration = remainingCachedDuration
                do {
                    let outcome = try await EditorAnalysisQueues.scan {
                        var pending: [EditorSceneMarker] = []
                        var lastUpdate = -Double.infinity
                        var latest: SceneScanProgress?
                        var reset = true

                        func publish() {
                            let now = ProcessInfo.processInfo.systemUptime
                            guard now - lastUpdate >= 0.15 else { return }
                            lastUpdate = now
                            let batch = pending, replacement = reset, current = latest
                            pending.removeAll(keepingCapacity: true)
                            reset = false
                            DispatchQueue.main.async {
                                guard self.token === token else { return }
                                if let current {
                                    aliases.forEach { self.coverage[$0.id] = current }
                                    if !token.isCancelled {
                                        let decoded = (current.decoded ?? request.start).seconds
                                        let elapsed = max(0, decoded - request.start.seconds)
                                        self.status = "\(request.name) · \(timelineTime(elapsed)) scanned"
                                        if duration > 0 {
                                            self.progress = min(0.999, (previous + request.duration * current.fraction + pendingCachedDuration) / duration)
                                        }
                                    }
                                }
                                for alias in aliases { markers(alias, batch, replacement, current) }
                                update()
                            }
                        }

                        let outcome = try SceneAnalysis.run(request.media, scope: request.scope, policy: policy,
                                                             useSidecar: preference.permits(request.media.url), session: cache,
                                                             allowAutomaticSave: { preference.permits(request.media.url) },
                                                             cancelled: { token.isCancelled }, progress: {
                            latest = $0
                            publish()
                        }, onScene: { time, view in
                            pending.append(EditorSceneMarker(time: time, view: view))
                        }, onReset: {
                            pending.removeAll(keepingCapacity: true)
                            reset = true
                        })
                        return (outcome, pending, reset)
                    }
                    // Drain marker publications before applying the final batch or closing the receipt.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    guard self.token === token else { return }
                    let (result, batch, reset) = outcome
                    aliases.forEach {
                        coverage[$0.id] = result.progress
                        markers($0, batch, reset, result.progress)
                    }
                    if let issue = result.progress.persistenceError { diskIssue = issue }
                    let key = SceneRecording(request)
                    inspections[key] = SceneRequestInspection(
                        completed: result.report != nil ? result.progress : inspections[key]?.completed,
                        pending: result.state == .paused ? result.progress : nil)
                    if result.state == .paused {
                        paused = true
                        status = Self.pauseStatus(request, progress: result.progress)
                        break
                    }
                    allCurrent = allCurrent && result.state == .upToDate
                    if let sceneReport = result.report {
                        for alias in aliases {
                            let resultForAlias = sceneReport.file == alias.media.url.path
                                ? sceneReport : sceneReport.forRefreshedMedia(alias.media)
                            report(alias, resultForAlias, result.state)
                        }
                    }
                    completedDuration += request.duration
                    let sourceIDs = aliases.map(\.id)
                    finished.append(contentsOf: sourceIDs)
                    receipt?.finishSceneSources(sourceIDs)
                } catch let failure {
                    guard self.token === token else { return }
                    error = failure
                    break
                }
            }
            guard self.token === token else { return }
            if paused || token.isCancelled {
                paused = true
                if status == "Saving scene progress…" {
                    status = finished.isEmpty ? "Paused · no new coverage" : "Paused · \(finished.count) complete"
                }
                receipt?.finish("cancelled", detail: ["sources": finished])
            } else if let error {
                status = error.localizedDescription
                receipt?.finish("failed", detail: ["error": error.localizedDescription, "sources": finished])
            } else {
                status = diskIssue.map { "Scenes available this session · \($0)" }
                    ?? (allCurrent ? "Up to date" : "Scene analysis complete")
                receipt?.finish("succeeded", detail: ["sources": finished])
            }
            self.token = nil
            progress = nil
            update()
        }
        update()
    }

    func didSaveCheckpoint(_ id: String, progress: SceneScanProgress) {
        guard self.progress == nil, coverage[id]?.requested == progress.requested,
              let request = requests.first(where: { $0.id == id }) else { return }
        coverage[id] = progress
        let key = SceneRecording(request)
        inspections[key] = SceneRequestInspection(completed: inspections[key]?.completed, pending: progress)
        if paused { status = Self.pauseStatus(request, progress: progress) }
    }

    private static func pauseStatus(_ request: EditorSceneRequest, progress: SceneScanProgress) -> String {
        let from = timelineTime(request.start.seconds)
        let confirmed = progress.confirmed.map { "\(from)–\(timelineTime($0.seconds)) confirmed" } ?? "no confirmed coverage"
        if progress.persistenceError != nil {
            let saved = progress.durable.map { "saved through \(timelineTime($0.seconds))" } ?? "no checkpoint saved"
            return "\(request.name) · Paused · \(confirmed) · \(saved) · save failed"
        }
        if let durable = progress.durable, let current = progress.decoded, durable < current {
            return "\(request.name) · Paused · this session only · \(confirmed) · saved through \(timelineTime(durable.seconds))"
        }
        let mode = progress.durable == nil ? "this session only" : "saved"
        return "\(request.name) · Paused · \(mode) · \(confirmed)"
    }
}

enum SceneScanDisposition {
    case current
    case partial(position: RationalTime?, saved: Bool)
    case stale
}

struct SceneInspectionKey: Hashable {
    private let recordings: Set<SceneRecording>
    private let readsSidecars: Bool
    private let revision: Int

    init(_ requests: [EditorSceneRequest], readingSidecars: Bool, revision: Int) {
        recordings = Set(requests.map(SceneRecording.init))
        readsSidecars = readingSidecars
        self.revision = revision
    }
}

private struct SceneRequestInspection: Sendable {
    let completed: SceneScanProgress?
    let pending: SceneScanProgress?
}

extension EditorSceneScan {
    func disposition(_ requests: [EditorSceneRequest]) -> SceneScanDisposition? {
        let recordings = Set(requests.map(SceneRecording.init))
        let states = recordings.map { inspections[$0] }
        if let pending = states.compactMap({ $0?.pending }).first {
            // Multiple recordings have independent source clocks.
            guard recordings.count == 1 else { return .partial(position: nil, saved: false) }
            return .partial(position: pending.durable ?? pending.decoded, saved: pending.durable != nil)
        }
        if !states.isEmpty, states.allSatisfy({ $0?.completed != nil }) { return .current }
        return nil
    }

    func inspect(_ requests: [EditorSceneRequest], preference: SidecarPreference) async {
        let scope = requests.filter { inspections[SceneRecording($0)] == nil }
        guard !scope.isEmpty else { return }
        let generation = inspectionGeneration
        let result = try? await EditorAnalysisQueues.scan {
            var states: [SceneRecording: SceneRequestInspection] = [:]
            for request in scope {
                let key = SceneRecording(request)
                guard states[key] == nil else { continue }
                let disk = preference.permits(request.media.url)
                let latest = SceneAnalysis.lookup(request.media, scope: request.scope, useSidecar: disk)
                // A reuse lookup already checks pending work when it finds no completed report.
                let pending = latest?.report == nil ? latest
                    : SceneAnalysis.lookup(request.media, scope: request.scope, useSidecar: disk, policy: .resume)
                states[key] = SceneRequestInspection(completed: latest?.report == nil ? nil : latest?.progress, pending: pending?.progress)
            }
            return states
        }
        guard inspectionGeneration == generation, let result else { return }
        inspections.merge(result) { current, _ in current }
    }
}
