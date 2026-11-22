import CryptoKit
import Foundation
import MediaProbe

public enum SceneScanScope: Hashable, Codable, Sendable {
    case fullSource
    case range(start: RationalTime, end: RationalTime)

    public var from: RationalTime {
        if case let .range(start, _) = self { return start }
        return .zero
    }
}

public enum SceneScanPolicy: Equatable, Sendable {
    case reuse
    case resume
    case restart(operationID: String)
}

public struct SceneScanProgress: Encodable, Equatable, Sendable {
    public let requested: SceneScanScope
    public let requestedThrough: RationalTime?
    public let decoded: RationalTime?
    public let confirmed: RationalTime?
    public let durable: RationalTime?
    public let fraction: Double
    public let persistenceError: String?

    public init(requested: SceneScanScope, requestedThrough: RationalTime? = nil,
                decoded: RationalTime? = nil, confirmed: RationalTime? = nil,
                durable: RationalTime? = nil, fraction: Double = 0, persistenceError: String? = nil) {
        self.requested = requested
        self.requestedThrough = requestedThrough
        self.decoded = decoded
        self.confirmed = confirmed
        self.durable = durable
        self.fraction = fraction
        self.persistenceError = persistenceError
    }
}

public struct SceneScanOutcome: Encodable, Sendable {
    public enum State: String, Encodable, Sendable { case upToDate, completed, paused }
    public let state: State
    public let report: SceneReport?
    public let progress: SceneScanProgress
}

private struct SceneScanKey: Hashable, Sendable {
    let identity: SourceIdentity
    let changeTime: SourceIdentity.ChangeTime?
    let scope: String
}

private struct SceneStart: Codable, Equatable {
    let pts: Int64
    let time: RationalTime
    let view: Int
    let isBoundary: Bool
}

private struct SceneCheckpoint: Codable {
    let detector: Data
    let layouts: Data
    let decoded: RationalTime?
    let confirmed: RationalTime?
    var names: [Int: String]? = nil
    var leading: SceneStart? = nil
}

private struct SceneScanRecord {
    var operationID: String?
    var checkpoint: SceneCheckpoint?
    var markers: [SceneStart] = []
    var outcome: SceneScanOutcome?
    var durableCheckpointDigest: SHA256.Digest?

    var reportMarkers: [SceneStart] {
        if let leading = checkpoint?.leading { return [leading] + markers }
        return markers
    }
}

private final class SceneScanWork: @unchecked Sendable {
    let policy: SceneScanPolicy
    let scope: SceneScanScope
    var subscribers: Set<UUID> = []
    var progress: SceneScanProgress?
    var markers: [SceneStart] = []
    var reset = 0
    var result: Result<SceneScanOutcome, Error>?
    var stopping = false

    init(policy: SceneScanPolicy, scope: SceneScanScope) {
        self.policy = policy
        self.scope = scope
    }
}

public final class SceneScanSession: @unchecked Sendable {
    public static let shared = SceneScanSession()

    fileprivate let lock = NSCondition()
    fileprivate var active: [SceneScanKey: SceneScanWork] = [:]
    fileprivate var completed: [SceneScanKey: SceneScanRecord] = [:]
    fileprivate var partial: [SceneScanKey: SceneScanRecord] = [:]
    fileprivate var operations: [SceneScanKey: [String: SceneScanRecord]] = [:]
    fileprivate var editedNames: [SceneScanKey: [Int: String?]] = [:]
    private var recent: [SceneScanKey] = []

    public init() {}

    package func setViewName(_ name: String?, view: Int, for media: MediaInfo) {
        guard let request = try? SceneRequest(media, scope: .fullSource) else { return }
        lock.lock()
        defer { lock.unlock() }
        touch(request.key)
        editedNames[request.key, default: [:]].updateValue(name, forKey: view)
        if var record = completed[request.key], let outcome = record.outcome, var report = outcome.report {
            report.setViewName(name, for: view)
            record.outcome = SceneScanOutcome(state: outcome.state, report: report, progress: outcome.progress)
            completed[request.key] = record
        }
    }

    fileprivate func touch(_ key: SceneScanKey) {
        recent.removeAll { $0 == key }
        recent.append(key)
        if recent.count > 64 {
            let expired = recent.removeFirst()
            completed.removeValue(forKey: expired)
            partial.removeValue(forKey: expired)
            operations.removeValue(forKey: expired)
            editedNames.removeValue(forKey: expired)
        }
    }
}

private struct SceneScanWritePermission: @unchecked Sendable {
    let allowed: () -> Bool
}

private struct SceneRequest: Sendable {
    let media: MediaInfo
    let scope: SceneScanScope
    let start: RationalTime
    let end: RationalTime
    let startPTS: Int64
    let endPTS: Int64
    let key: SceneScanKey

    // The unqualified scenes.v2 and viewNames.v2 sections use the ordinary
    // file clock. Shifted clocks persist through their scoped attempts.
    var usesCanonicalReport: Bool { scope == .fullSource && media.multicamClockOffset == .zero }

    init(_ media: MediaInfo, scope: SceneScanScope) throws {
        self.media = media
        self.scope = scope
        guard let video = media.videoStream, video.timeBase.numerator > 0 else {
            throw CutError(code: "no_video", message: "Scene detection requires a video track.")
        }
        switch scope {
        case .fullSource: (start, end) = (.zero, media.duration)
        case let .range(start, end): (self.start, self.end) = (start, end)
        }
        guard start >= .zero, end > start, end <= media.duration else {
            throw CutError(code: "invalid_scene_range", message: "The scene interval must be within the video source.")
        }

        let inverse = RationalTime(numerator: video.timeBase.denominator, denominator: video.timeBase.numerator)
        func firstTick(at time: RationalTime) throws -> Int64 {
            let ticks = try time.adding(media.origin).multiplied(by: inverse)
            let whole = ticks.numerator / ticks.denominator
            return whole + (ticks.numerator % ticks.denominator > 0 ? 1 : 0)
        }
        startPTS = try firstTick(at: start)
        endPTS = try firstTick(at: end)
        let interval = scope == .fullSource ? "full" : "\(start)-\(end)"
        key = SceneScanKey(identity: media.identity, changeTime: media.identity.changeTime,
                           scope: "scene-detector-2/\(video.index)/\(video.timeBase)/\(media.origin)/\(media.duration)/\(interval)")
    }

    func time(_ pts: Int64) throws -> RationalTime {
        try RationalTime(numerator: pts).multiplied(by: media.video.timeBase).subtracting(media.origin)
    }

    func position(_ pts: Int64) throws -> RationalTime? {
        guard pts != .min else { return nil }
        return min(end, max(start, try time(pts)))
    }

    func progress(decoded: RationalTime? = nil, confirmed: RationalTime? = nil,
                  durable: RationalTime? = nil, error: String? = nil, complete: Bool = false) -> SceneScanProgress {
        let duration = (try? end.subtracting(start).seconds) ?? (end.seconds - start.seconds)
        let position = decoded ?? start
        let elapsed = (try? position.subtracting(start).seconds) ?? (position.seconds - start.seconds)
        let ratio = duration > 0 ? elapsed / duration : 0
        return SceneScanProgress(requested: scope, requestedThrough: end, decoded: decoded, confirmed: confirmed, durable: durable,
                                 fraction: complete ? 1 : min(0.999, max(0, ratio)), persistenceError: error)
    }

    func report(_ markers: [SceneStart], names: [Int: String] = [:]) -> SceneReport {
        var members: [Int: [Int]] = [:]
        let scenes = markers.enumerated().map { index, marker in
            let number = index + 1
            members[marker.view, default: []].append(number)
            return DetectedScene(number: number, startPTS: marker.pts, start: marker.time,
                                 startSeconds: marker.time.seconds,
                                 end: index + 1 < markers.count ? markers[index + 1].time : end,
                                 view: marker.view, viewLabel: SceneView.label(for: marker.view))
        }
        let views = members.keys.sorted().map { view in
            SceneView(view: view, label: SceneView.label(for: view), sceneNumbers: members[view] ?? [], name: names[view])
        }
        return SceneReport(file: media.url.standardizedFileURL.path, sourceStamp: SceneSourceStamp(media: media),
                           timeBase: media.video.timeBase, origin: media.origin, duration: media.duration,
                           scenes: scenes, viewCount: views.count, views: views, syntheticLeading: markers.first?.isBoundary == false)
    }

    func slice(_ report: SceneReport) -> SceneReport {
        guard scope != .fullSource else { return report.forSource(media.url) }
        let first = report.scenes.lowerBound { $0.end > start }
        let limit = report.scenes.lowerBound { $0.start >= end }
        var members: [Int: [Int]] = [:]
        let scenes = report.scenes[first..<limit].map { scene in
            members[scene.view, default: []].append(scene.number)
            let leading = max(start, scene.start)
            return DetectedScene(number: scene.number, startPTS: scene.start < start ? startPTS : scene.startPTS,
                                 start: leading, startSeconds: leading.seconds, end: min(end, scene.end),
                                 view: scene.view, viewLabel: scene.viewLabel)
        }
        let views = report.views.compactMap { view -> SceneView? in
            guard let numbers = members[view.view] else { return nil }
            return SceneView(view: view.view, label: view.label, sceneNumbers: numbers, name: view.name)
        }
        let syntheticLeading = first < limit && (report.scenes[first].start < start || (first == 0 && report.syntheticLeading))
        return SceneReport(file: media.url.standardizedFileURL.path, sourceStamp: report.sourceStamp, timeBase: report.timeBase,
                           origin: report.origin, duration: report.duration, scenes: scenes,
                           viewCount: views.count, views: views,
                           syntheticLeading: syntheticLeading)
    }

    func cached(_ report: SceneReport, durable: Bool) -> SceneScanOutcome {
        SceneScanOutcome(state: .upToDate, report: slice(report),
                         progress: progress(decoded: end, confirmed: end, durable: durable ? end : nil, complete: true))
    }
}

private struct SceneObservation {
    var reset = 0
    var count = 0

    mutating func replay(_ markers: [SceneStart], reset generation: Int,
                         onScene: ((RationalTime, Int) -> Void)?, onReset: (() -> Void)?) {
        if generation != reset {
            reset = generation
            count = 0
            onReset?()
        }
        if let onScene {
            for marker in markers.dropFirst(count) where marker.isBoundary {
                onScene(marker.time, marker.view)
            }
        }
        count = markers.count
    }
}

extension SceneAnalysis {
    public static func run(_ url: URL, scope: SceneScanScope = .fullSource,
                           policy: SceneScanPolicy = .reuse, useSidecar: Bool = true,
                           session: SceneScanSession = .shared,
                           allowAutomaticSave: @escaping () -> Bool = { true },
                           cancelled: @escaping () -> Bool = { Task.isCancelled },
                           progress: ((SceneScanProgress) -> Void)? = nil,
                           onScene: ((RationalTime, Int) -> Void)? = nil,
                           onReset: (() -> Void)? = nil) throws -> SceneScanOutcome {
        guard url.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local video file.") }
        let file = url.standardizedFileURL
        let identity = try SourceIdentity(file)
        let cache = useSidecar && AnalysisSidecar.readsEnabled
            && !AnalysisSidecar.isExcluded(file, in: AnalysisSidecar.excludedSources)
            ? AnalysisSidecar(source: AnalysisSidecar.canonicalSource(file), identity: identity) : nil
        if policy == .reuse, scope == .fullSource, let cache,
           !hasSessionOnlyFullReport(identity, session: session),
           let report = cache.sceneReport(cancelled: cancelled),
           !cancelled() {
            let state = SceneScanProgress(requested: scope, requestedThrough: report.duration,
                                          decoded: report.duration, confirmed: report.duration,
                                          durable: report.duration, fraction: 1, persistenceError: nil)
            return try deliverCached(SceneScanOutcome(state: .upToDate, report: report.forSource(file), progress: state),
                                     cancelled: cancelled, progress: progress, onScene: onScene,
                                     checkSource: cache.checkSource)
        }
        let media: MediaInfo
        let verifiedClock: Data?
        do {
            if let cached = try cache?.loadIndex(detail: .preview, cancelled: cancelled)
                ?? cache?.loadSceneClock(cancelled: cancelled) {
                media = cached.forRefreshAlias(file)
                verifiedClock = nil
            } else {
                media = try inspectSceneClock(file, identity: identity, cancelled: cancelled)
                verifiedClock = cache == nil ? nil : try? AnalysisSidecar.encodeSceneClock(media)
            }
        } catch let error as CutError where error.code == "cancelled" {
            let state = SceneScanProgress(requested: scope, decoded: nil, confirmed: nil,
                                          durable: nil, fraction: 0, persistenceError: nil)
            progress?(state)
            return SceneScanOutcome(state: .paused, report: nil, progress: state)
        }
        return try run(media, scope: scope, policy: policy, useSidecar: useSidecar, session: session,
                       allowAutomaticSave: allowAutomaticSave, cancelled: cancelled,
                       progress: progress, onScene: onScene, onReset: onReset, verifiedClock: verifiedClock)
    }

    private static func hasSessionOnlyFullReport(_ identity: SourceIdentity, session: SceneScanSession) -> Bool {
        session.lock.lock()
        defer { session.lock.unlock() }
        return session.completed.contains { key, record in
            guard key.identity == identity, key.changeTime == identity.changeTime,
                  let outcome = record.outcome, outcome.progress.requested == .fullSource,
                  let report = outcome.report else { return false }
            return outcome.progress.durable != report.duration
        }
    }

    public static func run(_ media: MediaInfo, scope: SceneScanScope = .fullSource,
                           policy: SceneScanPolicy = .reuse, useSidecar: Bool = true,
                           session: SceneScanSession = .shared,
                           allowAutomaticSave: @escaping () -> Bool = { true },
                           cancelled: @escaping () -> Bool = { Task.isCancelled },
                           progress: ((SceneScanProgress) -> Void)? = nil,
                           onScene: ((RationalTime, Int) -> Void)? = nil,
                           onReset: (() -> Void)? = nil) throws -> SceneScanOutcome {
        try run(media, scope: scope, policy: policy, useSidecar: useSidecar, session: session,
                allowAutomaticSave: allowAutomaticSave, cancelled: cancelled,
                progress: progress, onScene: onScene, onReset: onReset, verifiedClock: nil)
    }

    private static func run(_ media: MediaInfo, scope: SceneScanScope,
                            policy: SceneScanPolicy, useSidecar: Bool, session: SceneScanSession,
                            allowAutomaticSave: @escaping () -> Bool, cancelled: @escaping () -> Bool,
                            progress: ((SceneScanProgress) -> Void)?,
                            onScene: ((RationalTime, Int) -> Void)?, onReset: (() -> Void)?,
                            verifiedClock: Data?) throws -> SceneScanOutcome {
        let cache = sidecar(for: media, enabled: useSidecar)
        try checkSnapshot(media)
        if media.hasProvisionalClock, !cancelled() {
            let exact: MediaInfo
            do {
                if let indexed = try cache?.loadIndex(detail: .preview, cancelled: cancelled) {
                    let selected = indexed.forRefreshAlias(media.url)
                    exact = media.multicamClockOffset > .zero ? try CutEngine().multicamClock(selected) : selected
                } else {
                    exact = try inspectSceneClock(media.url, identity: media.identity, preview: media, cancelled: cancelled)
                }
            } catch let error as CutError where error.code == "cancelled" {
                let state = SceneScanProgress(requested: scope)
                progress?(state)
                return SceneScanOutcome(state: .paused, report: nil, progress: state)
            }
            return try run(exact, scope: scope, policy: policy, useSidecar: useSidecar, session: session,
                           allowAutomaticSave: allowAutomaticSave, cancelled: cancelled, progress: progress,
                           onScene: onScene, onReset: onReset)
        }
        let request = try SceneRequest(media, scope: scope)
        if cancelled() {
            let state = lookup(media, scope: scope, useSidecar: useSidecar, session: session, policy: .resume)?.progress
                ?? request.progress()
            progress?(state)
            return SceneScanOutcome(state: .paused, report: nil, progress: state)
        }

        if let cached = cachedResult(request, cache: cache, session: session, policy: policy,
                                     allowRepair: AnalysisSidecar.automaticWritesEnabled && allowAutomaticSave()) {
            return try deliverCached(cached, cancelled: cancelled, progress: progress, onScene: onScene,
                                     checkSource: { try checkSnapshot(media) })
        }

        let subscriber = UUID()
        let fullKey = scope != .fullSource && policy == .reuse
            ? (try? SceneRequest(media, scope: .fullSource))?.key : nil
        session.lock.lock()
        while let other = session.active[request.key], other.stopping || !compatible(other.policy, policy) {
            if cancelled() {
                session.lock.unlock()
                return SceneScanOutcome(state: .paused, report: nil, progress: request.progress())
            }
            _ = session.lock.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        let coveringWork = fullKey.flatMap { session.active[$0] }
        if let work = session.active[request.key] ?? coveringWork, !work.stopping {
            work.subscribers.insert(subscriber)
            session.lock.unlock()
            return try observe(work, request: request, session: session, subscriber: subscriber,
                               cancelled: cancelled, progress: progress, onScene: onScene, onReset: onReset)
        }
        let work = SceneScanWork(policy: policy, scope: request.scope)
        work.subscribers.insert(subscriber)
        session.active[request.key] = work
        session.lock.unlock()

        let canWrite = AnalysisSidecar.automaticWritesEnabled
        let permission = SceneScanWritePermission(allowed: allowAutomaticSave)
        DispatchQueue.global(qos: .userInitiated).async {
            func publish(_ state: SceneScanProgress, _ markers: [SceneStart], _ reset: Bool) {
                session.lock.lock()
                if reset { work.reset += 1 }
                work.progress = state
                work.markers = markers
                session.lock.broadcast()
                session.lock.unlock()
            }
            func shouldStop() -> Bool {
                session.lock.lock()
                defer { session.lock.unlock() }
                if work.subscribers.isEmpty { work.stopping = true }
                return work.stopping
            }
            let result = Result {
                try perform(request, policy: policy, cache: cache, session: session, verifiedClock: verifiedClock,
                            allowSave: { canWrite && permission.allowed() }, cancelled: shouldStop, publish: publish)
            }
            session.lock.lock()
            work.result = result
            session.active.removeValue(forKey: request.key)
            session.lock.broadcast()
            session.lock.unlock()
        }
        return try observe(work, request: request, session: session, subscriber: subscriber,
                           cancelled: cancelled, progress: progress, onScene: onScene, onReset: onReset)
    }

    private static func deliverCached(_ outcome: SceneScanOutcome, cancelled: () -> Bool,
                                      progress: ((SceneScanProgress) -> Void)?,
                                      onScene: ((RationalTime, Int) -> Void)?, checkSource: () throws -> Void) throws -> SceneScanOutcome {
        try checkSource()
        if let onScene, let report = outcome.report {
            for scene in report.scenes.dropFirst(report.syntheticLeading ? 1 : 0) {
                if cancelled() { break }
                onScene(scene.start, scene.view)
            }
        }
        try checkSource()
        progress?(outcome.progress)
        return cancelled() ? SceneScanOutcome(state: .paused, report: nil, progress: outcome.progress) : outcome
    }

    public static func lookup(_ media: MediaInfo, scope: SceneScanScope = .fullSource,
                              useSidecar: Bool = true, session: SceneScanSession = .shared,
                              policy: SceneScanPolicy = .reuse) -> SceneScanOutcome? {
        guard let request = try? SceneRequest(media, scope: scope),
              (try? checkSnapshot(media)) != nil else { return nil }
        let cache = sidecar(for: media, enabled: useSidecar)
        if let report = cachedResult(request, cache: cache, session: session, policy: policy) { return report }
        session.lock.lock()
        let local = session.partial[request.key]?.outcome
        session.lock.unlock()
        if let local { return local }
        guard let snapshot = cache?.sceneAttempt(scope: request.key.scope, completed: false),
              let stored = decode(snapshot, operationID: nil), let checkpoint = stored.checkpoint else { return nil }
        return SceneScanOutcome(state: .paused, report: nil,
                                progress: request.progress(decoded: checkpoint.decoded, confirmed: checkpoint.confirmed,
                                                           durable: checkpoint.decoded))
    }

    private static func inspectSceneClock(_ url: URL, identity: SourceIdentity, preview: MediaInfo? = nil,
                                          cancelled: @escaping () -> Bool) throws -> MediaInfo {
        let header = preview ?? (try? Probe.read(url, keyframes: false, previewOnly: true,
                                                expectedIdentity: identity, cancelled: cancelled))
        if let header, let video = header.videoStream,
           header.format.split(separator: ",").contains(where: { $0 == "mov" || $0 == "matroska" }) {
            var timing = MPSceneTiming()
            let cancellation = SceneScanWritePermission(allowed: cancelled)
            let valid = withUnsafePointer(to: cancellation) { context in
                mp_scene_verify_clock(url.path, Int32(video.index), { pointer in
                    guard let pointer else { return 0 }
                    return pointer.assumingMemoryBound(to: SceneScanWritePermission.self).pointee.allowed() ? 1 : 0
                }, UnsafeMutableRawPointer(mutating: context), &timing)
            }
            if valid != 0 {
                let base = RationalTime(numerator: Int64(timing.tb_num), denominator: Int64(timing.tb_den))
                let origin = try RationalTime(numerator: timing.origin).multiplied(by: base)
                let duration = try RationalTime(numerator: timing.end).multiplied(by: base).subtracting(origin)
                let expectedOrigin = header.multicamClockOffset > .zero ? header.multicamClockOffset : header.origin
                if base == video.timeBase, origin == expectedOrigin, duration > .zero,
                   identity.isCurrentSnapshot(at: url) {
                    let sourceDuration = try duration.adding(header.multicamClockOffset)
                    return MediaInfo(url: header.url, format: header.format, duration: sourceDuration,
                                     origin: header.origin, streams: header.streams, frames: [], audio: [],
                                     copyIssue: header.copyIssue, sourceStartSafe: header.sourceStartSafe,
                                     identity: identity, videoIndex: header.streams.firstIndex { $0.index == video.index } ?? -1,
                                     timelineIssue: header.timelineIssue, metadataOnly: true,
                                     multicamClockOffset: header.multicamClockOffset, audioIssues: header.audioIssues)
                }
            }
        }
        let media = try Probe.read(url, keyframes: false, expectedIdentity: identity, cancelled: cancelled)
        if let preview, preview.multicamClockOffset > .zero { return try CutEngine().multicamClock(media) }
        return media
    }

    private static func checkSnapshot(_ media: MediaInfo) throws {
        guard media.identity.isCurrentSnapshot(at: media.url) else {
            throw CutError(code: "source_changed", message: "The source changed during scene analysis.")
        }
    }

    private static func sidecar(for media: MediaInfo, enabled: Bool) -> AnalysisSidecar? {
        guard enabled, AnalysisSidecar.readsEnabled, !AnalysisSidecar.isExcluded(media.url, in: AnalysisSidecar.excludedSources) else { return nil }
        return AnalysisSidecar(source: AnalysisSidecar.canonicalSource(media.url), identity: media.identity)
    }

    private static func compatible(_ running: SceneScanPolicy, _ requested: SceneScanPolicy) -> Bool {
        switch (running, requested) {
        case let (.restart(active), .restart(incoming)): return active == incoming
        case (_, .restart): return false
        default: return true
        }
    }

    private static func observe(_ work: SceneScanWork, request: SceneRequest, session: SceneScanSession, subscriber: UUID,
                                cancelled: () -> Bool, progress: ((SceneScanProgress) -> Void)?,
                                onScene: ((RationalTime, Int) -> Void)?, onReset: (() -> Void)?) throws -> SceneScanOutcome {
        var observation = SceneObservation()
        var lastProgress: SceneScanProgress?
        var waitForCheckpoint = false
        while true {
            let stopped = cancelled()
            session.lock.lock()
            if stopped, work.subscribers.remove(subscriber) != nil, work.subscribers.isEmpty {
                work.stopping = true
                waitForCheckpoint = true
            }
            let result = work.result
            let workState = work.progress
            let markers = work.markers
            let reset = work.reset
            session.lock.unlock()
            let finished = result != nil || (stopped && !waitForCheckpoint)
            let state: SceneScanProgress
            if let workState, work.scope != request.scope {
                func covered(_ position: RationalTime?) -> RationalTime? {
                    guard let position, position >= request.start else { return nil }
                    return min(request.end, position)
                }
                state = request.progress(decoded: covered(workState.decoded), confirmed: covered(workState.confirmed),
                                         durable: covered(workState.durable), error: workState.persistenceError,
                                         complete: workState.fraction == 1)
            } else {
                state = workState ?? request.progress()
            }
            observation.replay(markers, reset: reset, onScene: { time, view in
                if time >= request.start && time < request.end { onScene?(time, view) }
            }, onReset: onReset)
            if lastProgress != state || finished {
                progress?(state)
                lastProgress = state
            }
            if stopped, !waitForCheckpoint { return SceneScanOutcome(state: .paused, report: nil, progress: state) }
            if let result {
                let outcome = try result.get()
                let report = work.scope == request.scope
                    ? outcome.report?.forSource(request.media.url) : outcome.report.map(request.slice)
                return SceneScanOutcome(state: outcome.state, report: report, progress: state)
            }
            session.lock.lock()
            if work.result == nil { _ = session.lock.wait(until: Date(timeIntervalSinceNow: 0.05)) }
            session.lock.unlock()
        }
    }

    private static func cachedResult(_ request: SceneRequest, cache: AnalysisSidecar?, session: SceneScanSession,
                                     policy: SceneScanPolicy, allowRepair: Bool = false) -> SceneScanOutcome? {
        guard policy == .reuse else { return nil }
        let fullRequest = try? SceneRequest(request.media, scope: .fullSource)
        session.lock.lock()
        let currentRecord = session.completed[request.key]
        let current = currentRecord?.outcome
        if current != nil || session.partial[request.key] != nil { session.touch(request.key) }
        let fullRecord = fullRequest.flatMap { session.completed[$0.key] }
        let full = fullRecord?.outcome
        let hasLocalNames = fullRequest.map { !(session.editedNames[$0.key] ?? [:]).isEmpty } ?? false
        session.lock.unlock()
        // Keep an intentional session-only restart or rename ahead of an older
        // disk report. A plain in-memory scan can still acquire saved names.
        if let current, let report = current.report, current.progress.durable != request.end,
           cache == nil || currentRecord?.operationID != nil || hasLocalNames {
            return SceneScanOutcome(state: .upToDate, report: report.forSource(request.media.url), progress: current.progress)
        }

        func storedReport(_ owner: SceneRequest) -> SceneScanOutcome? {
            guard let cache, let snapshot = cache.sceneAttempt(scope: owner.key.scope, completed: true),
                  let stored = decode(snapshot, operationID: nil) else { return nil }
            var report = owner.report(stored.reportMarkers, names: stored.checkpoint?.names ?? [:])
            if owner.usesCanonicalReport {
                report = cache.restoringViewNames(to: report, cancelled: { false })
                if allowRepair, let sections = try? AnalysisSidecar.sceneSections(for: report) {
                    try? cache.repairCanonicalSceneReport(scope: owner.key.scope, expectedCheckpoint: snapshot.checkpoint,
                                                         sections: sections)
                }
            }
            return request.cached(report, durable: true)
        }
        if request.scope != .fullSource {
            if let result = storedReport(request) { return result }
            if let current, let report = current.report { return request.cached(report, durable: current.progress.durable != nil) }
        }
        if let full, let report = full.report, full.progress.durable != request.media.duration,
           cache == nil || fullRecord?.operationID != nil || hasLocalNames {
            return request.cached(report, durable: false)
        }
        if let report = cache?.sceneReport(for: request.media) { return request.cached(report, durable: true) }
        if let full, let report = full.report {
            let restored = fullRequest?.usesCanonicalReport == true
                ? cache?.restoringViewNames(to: report, cancelled: { false }) ?? report : report
            if allowRepair, restored.views.map(\.name) != report.views.map(\.name) {
                // Rebuild the canonical report before a subsequent metadata edit.
                // The scan restores only names whose legacy markers still match.
                return nil
            }
            return request.cached(restored, durable: full.progress.durable != nil)
        }
        return fullRequest.flatMap(storedReport)
    }

    private static func decode(_ snapshot: SceneAttemptSnapshot, operationID: String?) -> SceneScanRecord? {
        let decoder = JSONDecoder()
        guard let checkpoint = try? decoder.decode(SceneCheckpoint.self, from: snapshot.checkpoint) else { return nil }
        var markers: [SceneStart] = []
        for batch in snapshot.markerBatches {
            guard let next = try? decoder.decode([SceneStart].self, from: batch) else { return nil }
            markers.append(contentsOf: next)
        }
        let count = Int(MP_SCENE_FEATURE_SIZE)
        guard checkpoint.layouts.count.isMultiple(of: count),
              (checkpoint.leading.map { [$0] } ?? []).allSatisfy({ $0.view > 0 && $0.view <= checkpoint.layouts.count / count }),
              markers.allSatisfy({ $0.view > 0 && $0.view <= checkpoint.layouts.count / count }),
              zip(markers, markers.dropFirst()).allSatisfy({ $0.time < $1.time }) else { return nil }
        return SceneScanRecord(operationID: operationID, checkpoint: checkpoint, markers: markers,
                               durableCheckpointDigest: SHA256.hash(data: snapshot.checkpoint))
    }
}

private final class ResumableSceneCollector {
    let request: SceneRequest
    let cancelled: () -> Bool
    let receive: (ResumableSceneCollector, Bool) -> Void
    var record: SceneScanRecord
    var layouts: Data
    var leading: SceneStart?
    var error: Error?

    init(request: SceneRequest, record: SceneScanRecord, cancelled: @escaping () -> Bool,
         receive: @escaping (ResumableSceneCollector, Bool) -> Void) {
        self.request = request
        self.record = record
        self.cancelled = cancelled
        self.receive = receive
        layouts = record.checkpoint?.layouts ?? Data()
        leading = record.checkpoint?.leading
    }

    func marker(pts: Int64, feature: UnsafePointer<UInt8>) throws {
        let seed = pts == .min + 1
        let time = seed || (request.scope == .fullSource && record.markers.isEmpty) ? request.start : try request.time(pts)
        guard time >= request.start, time < request.end,
              record.markers.last.map({ $0.time < time }) ?? true else { return }
        if !seed, time == request.start, leading != nil, record.markers.isEmpty {
            leading = nil
            layouts.removeAll(keepingCapacity: true)
        }
        let size = Int(MP_SCENE_FEATURE_SIZE)
        let count = layouts.count / size
        let match = layouts.withUnsafeBytes { bytes in
            mp_scene_match_view(feature, bytes.bindMemory(to: UInt8.self).baseAddress, count)
        }
        if match == count { layouts.append(feature, count: size) }
        let marker = SceneStart(pts: seed ? request.startPTS : pts, time: time, view: match + 1, isBoundary: !seed)
        if seed { leading = marker }
        else { record.markers.append(marker) }
    }

    func checkpoint(decoded: Int64, confirmed: Int64, detector: UnsafePointer<UInt8>, size: Int) throws {
        record.checkpoint = SceneCheckpoint(detector: Data(bytes: detector, count: size), layouts: layouts,
                                           decoded: try request.position(decoded), confirmed: try request.position(confirmed),
                                           leading: leading)
        receive(self, false)
    }

    func run() -> (Int32, String) {
        var error = [CChar](repeating: 0, count: 256)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let previous = record.checkpoint?.detector ?? Data()
        let status = previous.withUnsafeBytes { bytes in
            var options = MPSceneScanOptions(has_range: request.scope == .fullSource ? 0 : 1,
                                             start_pts: request.startPTS, end_pts: request.endPTS,
                                             resume: bytes.bindMemory(to: UInt8.self).baseAddress, resume_size: bytes.count)
            return mp_scene_scan_resumable(request.media.url.path, Int32(request.media.video.index), &options, { context in
                let collector = Unmanaged<ResumableSceneCollector>.fromOpaque(context!).takeUnretainedValue()
                return collector.error != nil || collector.cancelled() ? 1 : 0
            }, { context, pts, feature in
                guard let feature else { return }
                let collector = Unmanaged<ResumableSceneCollector>.fromOpaque(context!).takeUnretainedValue()
                do { try collector.marker(pts: pts, feature: feature) }
                catch { collector.error = error }
            }, { context, decoded, confirmed, _, state, size in
                guard let state else { return }
                let collector = Unmanaged<ResumableSceneCollector>.fromOpaque(context!).takeUnretainedValue()
                do { try collector.checkpoint(decoded: decoded, confirmed: confirmed, detector: state, size: size) }
                catch { collector.error = error }
            }, context, &error, error.count)
        }
        return (status, String(cString: error))
    }
}

extension SceneAnalysis {
    private static func perform(_ request: SceneRequest, policy: SceneScanPolicy, cache: AnalysisSidecar?,
                                session: SceneScanSession, verifiedClock: Data?, allowSave: @escaping () -> Bool,
                                cancelled: @escaping () -> Bool,
                                publish: @escaping (SceneScanProgress, [SceneStart], Bool) -> Void) throws -> SceneScanOutcome {
        if let cached = cachedResult(request, cache: cache, session: session, policy: policy,
                                     allowRepair: allowSave()), let report = cached.report {
            let markers = report.scenes.dropFirst(report.syntheticLeading ? 1 : 0).compactMap { scene -> SceneStart? in
                guard scene.start >= request.start else { return nil }
                return SceneStart(pts: scene.startPTS, time: scene.start, view: scene.view, isBoundary: true)
            }
            publish(cached.progress, markers, false)
            return cached
        }

        session.lock.lock()
        let operation: String?
        let local: SceneScanRecord?
        if case let .restart(operationID) = policy {
            operation = operationID
            local = session.operations[request.key]?[operationID]
        } else {
            local = session.partial[request.key]
            operation = local?.operationID
        }
        let newestPartial = session.partial[request.key]?.operationID
        session.lock.unlock()
        if let local, let operation {
            if let completed = local.outcome, let report = completed.report {
                let replay = SceneScanOutcome(state: .upToDate, report: report, progress: completed.progress)
                publish(replay.progress, local.markers, false)
                return replay
            }
            if local.outcome?.state == .paused, newestPartial != operation {
                throw CutError(code: "operation_superseded", message: "This restart was superseded by a newer scene scan.")
            }
        }

        let owner = UUID().uuidString
        var claim: SceneAttemptClaim?
        var writeError: String?
        var durable: RationalTime?
        var storedCount = 0
        var stored: SceneScanRecord?
        var observedMarkers: [SceneStart] = []
        var followed: (id: String, fence: Int64, coverage: Double)?
        if let cache, allowSave() {
            do {
                repeat {
                    if cancelled() { break }
                    claim = try cache.claimSceneAttempt(scope: request.key.scope, operationID: operation,
                                                        restart: operation != nil, resume: policy == .resume,
                                                        owner: owner, cancelled: cancelled)
                    if claim == nil {
                        if let snapshot = cache.sceneAttempt(scope: request.key.scope, completed: false,
                                                             afterCoverage: followed?.coverage,
                                                             followedAttempt: followed?.id, followedFence: followed?.fence),
                           let record = decode(snapshot, operationID: operation) {
                            let reset = followed.map { $0.id != snapshot.attemptID || $0.coverage > snapshot.coveredThrough } == true
                                || !record.markers.starts(with: observedMarkers)
                            followed = (snapshot.attemptID, snapshot.fence, snapshot.coveredThrough)
                            observedMarkers = record.markers
                            stored = record
                            durable = record.checkpoint?.decoded
                            publish(request.progress(decoded: record.checkpoint?.decoded,
                                                     confirmed: record.checkpoint?.confirmed, durable: durable), record.markers, reset)
                        }
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                } while claim == nil
                if let claim {
                    stored = cache.sceneAttempt(claim).flatMap { decode($0, operationID: operation) }
                    if claim.superseded {
                        throw CutError(code: "operation_superseded", message: "This restart was superseded by a newer scene scan.")
                    }
                    if claim.completed {
                        guard let stored else {
                            throw CutError(code: "invalid_sidecar_analysis", message: "The completed scene checkpoint cannot be read.")
                        }
                        let ownReport = request.report(stored.reportMarkers, names: stored.checkpoint?.names ?? [:])
                        let report = operation == nil && request.scope == .fullSource
                            ? (cache.sceneReport(for: request.media) ?? ownReport) : ownReport
                        let outcome = request.cached(report, durable: true)
                        publish(outcome.progress, stored.markers, !stored.markers.starts(with: observedMarkers))
                        return outcome
                    }
                    if stored == nil { try cache.resetSceneAttempt(claim) }
                    storedCount = stored?.markers.count ?? 0
                    durable = stored?.checkpoint?.decoded
                }
            } catch let error as CutError where error.code == "operation_superseded"
                || error.code == "scene_claim_lost" || error.code == "source_changed" {
                throw error
            } catch {
                if !cancelled() { writeError = error.localizedDescription }
                if let claim, !claim.completed { try? cache.releaseSceneAttempt(claim) }
                claim = nil
            }
        }

        // A readable sidecar can still provide native resume state when the
        // database cannot grant a write claim. Keep its last committed coverage
        // separate from the work that continues in memory.
        if claim == nil, stored == nil, operation == nil,
           let snapshot = cache?.sceneAttempt(scope: request.key.scope, completed: false),
           let record = decode(snapshot, operationID: nil) {
            stored = record
            durable = record.checkpoint?.decoded
        }

        if policy == .resume, stored == nil, local == nil,
           let cached = cachedResult(request, cache: cache, session: session, policy: .reuse) {
            if let claim { try? cache?.releaseSceneAttempt(claim) }
            let markers = cached.report.map { report in report.scenes.dropFirst(report.syntheticLeading ? 1 : 0).compactMap { scene -> SceneStart? in
                guard scene.start >= request.start else { return nil }
                return SceneStart(pts: scene.startPTS, time: scene.start, view: scene.view, isBoundary: true)
            } } ?? []
            publish(cached.progress, markers, false)
            return cached
        }

        let initial: SceneScanRecord
        if let local, let checkpoint = local.checkpoint, let stored,
           local.durableCheckpointDigest != nil,
           local.durableCheckpointDigest == stored.durableCheckpointDigest,
           local.markers.starts(with: stored.markers),
           (checkpoint.decoded ?? request.start) >= (stored.checkpoint?.decoded ?? request.start) {
            initial = local
        } else {
            initial = stored ?? local ?? SceneScanRecord(operationID: operation)
        }
        var lastFlush = ProcessInfo.processInfo.systemUptime
        var lastUpdate = -Double.infinity
        var lastRenewal = lastFlush
        var durableCheckpointDigest = stored?.durableCheckpointDigest
        var clockToSave = verifiedClock
        var invalidated: CutError?
        func stopOrRenew() -> Bool {
            if cancelled() || invalidated != nil { return true }
            guard let cache, let claim else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastRenewal > 10, allowSave() {
                lastRenewal = now
                do { try cache.renewSceneAttempt(claim, cancelled: cancelled) }
                catch let error as CutError where error.code == "scene_claim_lost" || error.code == "source_changed" {
                    invalidated = error
                } catch { writeError = error.localizedDescription }
            }
            return false
        }
        func save(_ record: SceneScanRecord, report: SceneReport? = nil, release: Bool = false) {
            guard let cache, let current = claim, !current.completed, let checkpoint = record.checkpoint,
                  allowSave() else { return }
            do {
                let encoder = JSONEncoder()
                let batch = record.markers.count > storedCount ? try encoder.encode(Array(record.markers.dropFirst(storedCount))) : nil
                var sections: [String: Data] = [:]
                if let report, request.usesCanonicalReport {
                    sections = try AnalysisSidecar.sceneSections(for: report)
                    if !(checkpoint.names ?? [:]).isEmpty || cache.read(AnalysisSidecar.viewNameSectionKey) != nil {
                        sections.merge(try AnalysisSidecar.viewNameSections(checkpoint.names ?? [:], for: report)) { _, new in new }
                    }
                }
                if let clockToSave { sections[AnalysisSidecar.sceneClockKey] = clockToSave }
                let coverage = report == nil ? checkpoint.decoded : request.end
                let payload = try encoder.encode(checkpoint)
                try cache.commitSceneAttempt(current, checkpoint: payload, markerBatch: batch,
                                             coveredThrough: coverage?.seconds ?? request.start.seconds,
                                             complete: report != nil, sections: sections, release: release)
                clockToSave = nil
                durableCheckpointDigest = SHA256.hash(data: payload)
                lastRenewal = ProcessInfo.processInfo.systemUptime
                storedCount = record.markers.count
                durable = coverage
                writeError = nil
                if release || report != nil { claim = nil }
            } catch let error as CutError where error.code == "scene_claim_lost" || error.code == "source_changed" {
                invalidated = error
            } catch {
                writeError = error.localizedDescription
            }
        }
        func receive(_ collector: ResumableSceneCollector, _ reset: Bool) {
            let now = ProcessInfo.processInfo.systemUptime
            let record = collector.record
            if now - lastFlush >= 5 {
                save(record)
                lastFlush = now
            }
            if reset || now - lastUpdate >= 0.2 {
                lastUpdate = now
                publish(request.progress(decoded: record.checkpoint?.decoded, confirmed: record.checkpoint?.confirmed,
                                         durable: durable, error: writeError), record.markers, reset)
            }
        }

        defer {
            if let cache, let claim, !claim.completed { try? cache.releaseSceneAttempt(claim) }
        }
        var collector = ResumableSceneCollector(request: request, record: initial, cancelled: stopOrRenew, receive: receive)
        receive(collector, !initial.markers.starts(with: observedMarkers))
        var (status, message) = cancelled() ? (Int32(MP_SCENE_SCAN_CANCELLED), "") : collector.run()
        if status == MP_SCENE_RESUME_MISMATCH {
            if let cache, let current = claim {
                do { try cache.resetSceneAttempt(current) }
                catch let error as CutError where error.code == "scene_claim_lost" || error.code == "source_changed" {
                    throw error
                } catch {
                    writeError = error.localizedDescription
                    try? cache.releaseSceneAttempt(current)
                    claim = nil
                }
            }
            durable = nil
            durableCheckpointDigest = nil
            storedCount = 0
            collector = ResumableSceneCollector(request: request, record: SceneScanRecord(operationID: operation),
                                                 cancelled: stopOrRenew, receive: receive)
            receive(collector, true)
            (status, message) = collector.run()
        }
        if let error = collector.error ?? invalidated { throw error }
        try checkSnapshot(request.media)
        var record = collector.record
        let paused = status == MP_SCENE_SCAN_CANCELLED
        guard paused || (status == 0 && !record.reportMarkers.isEmpty) else {
            throw CutError(code: "scene_analysis_failed", message: "Could not analyze this video. " + message)
        }
        var report: SceneReport?
        if !paused {
            session.lock.lock()
            let previousComplete = session.completed[request.key]
            let editedNames = session.editedNames[request.key] ?? [:]
            session.lock.unlock()
            var names: [Int: String] = [:]
            let previousStored = cache?.sceneAttempt(scope: request.key.scope, completed: true).flatMap { decode($0, operationID: nil) }
            let canonical = request.usesCanonicalReport ? cache?.sceneReport(for: request.media) : nil
            let oldReport = canonical ?? previousComplete?.outcome?.report
            var oldNames = oldReport.map { report in
                Dictionary(uniqueKeysWithValues: report.views.compactMap { view in view.name.map { (view.view, $0) } })
            } ?? previousStored?.checkpoint?.names ?? [:]
            for (view, name) in editedNames { oldNames[view] = name }
            if let oldLayouts = previousStored?.checkpoint?.layouts ?? previousComplete?.checkpoint?.layouts,
               let newLayouts = record.checkpoint?.layouts {
                let stride = Int(MP_SCENE_FEATURE_SIZE)
                for (view, name) in oldNames {
                    guard view > 0, view <= min(oldLayouts.count, newLayouts.count) / stride else { continue }
                    let start = (view - 1) * stride
                    let end = start + stride
                    guard oldLayouts[start..<end].elementsEqual(newLayouts[start..<end]) else { continue }
                    names[view] = name
                }
            }
            var completed = request.report(record.reportMarkers, names: names)
            if request.usesCanonicalReport, let cache, operation == nil, canonical == nil {
                completed = cache.restoringViewNames(to: completed, cancelled: { false })
                names = Dictionary(uniqueKeysWithValues: completed.views.compactMap { view in
                    view.name.map { (view.view, $0) }
                })
            }
            record.checkpoint?.names = names
            report = completed
        }
        save(record, report: report, release: paused)
        if let invalidated { throw invalidated }
        try checkSnapshot(request.media)
        let final = request.progress(decoded: paused ? record.checkpoint?.decoded : request.end,
                                     confirmed: paused ? record.checkpoint?.confirmed : request.end,
                                     durable: durable, error: writeError, complete: !paused)
        let outcome = SceneScanOutcome(state: paused ? .paused : .completed, report: report, progress: final)
        record.outcome = outcome
        record.durableCheckpointDigest = durableCheckpointDigest
        session.lock.lock()
        session.touch(request.key)
        if paused { session.partial[request.key] = record }
        else {
            session.completed[request.key] = record
            session.partial.removeValue(forKey: request.key)
            session.editedNames.removeValue(forKey: request.key)
        }
        if let operation {
            var operations = session.operations[request.key] ?? [:]
            if operations.count >= 8, operations[operation] == nil, let evicted = operations.keys.first {
                operations.removeValue(forKey: evicted)
            }
            operations[operation] = record
            session.operations[request.key] = operations
        }
        session.lock.unlock()
        publish(final, record.markers, false)
        return outcome
    }

    public static func saveCheckpoint(for media: MediaInfo, scope: SceneScanScope = .fullSource,
                                      session: SceneScanSession = .shared) throws -> SceneScanProgress? {
        let request = try SceneRequest(media, scope: scope)
        session.lock.lock()
        let record = session.partial[request.key]
        session.lock.unlock()
        guard let record, let checkpoint = record.checkpoint else { return nil }
        let cache = AnalysisSidecar(source: AnalysisSidecar.canonicalSource(media.url), identity: media.identity)
        return try AnalysisSidecar.$readsEnabled.withValue(true) {
            try AnalysisSidecar.$automaticWritesEnabled.withValue(true) {
                var operation = record.operationID
                let owner = UUID().uuidString
                func claimCheckpoint() throws -> SceneAttemptClaim? {
                    try cache.claimSceneAttempt(scope: request.key.scope, operationID: operation,
                                                restart: operation != nil, resume: true, owner: owner)
                }
                var available = try claimCheckpoint()
                if available?.completed == true && operation == nil {
                    operation = UUID().uuidString
                    available = try claimCheckpoint()
                }
                guard let claim = available, !claim.completed, !claim.superseded else {
                    throw CutError(code: "scene_checkpoint_busy", message: "The scene checkpoint is already owned by another scan.")
                }
                defer { try? cache.releaseSceneAttempt(claim) }
                let encoder = JSONEncoder()
                let existing = cache.sceneAttempt(claim).flatMap { decode($0, operationID: record.operationID) }
                let markers = existing?.markers ?? []
                let isPrefix = record.markers.starts(with: markers)
                let matchesCheckpoint = existing == nil || existing?.durableCheckpointDigest == record.durableCheckpointDigest
                    || (existing?.checkpoint?.detector == checkpoint.detector && existing?.checkpoint?.layouts == checkpoint.layouts)
                guard matchesCheckpoint, isPrefix,
                      (existing?.checkpoint?.decoded ?? request.start) <= (checkpoint.decoded ?? request.start) else {
                    throw CutError(code: "scene_checkpoint_conflict", message: "The saved scan has changed since this checkpoint.")
                }
                let batch = Array(record.markers.dropFirst(markers.count))
                let payload = try encoder.encode(checkpoint)
                try cache.commitSceneAttempt(claim, checkpoint: payload,
                                             markerBatch: batch.isEmpty ? nil : encoder.encode(batch),
                                             coveredThrough: checkpoint.decoded?.seconds ?? request.start.seconds,
                                             complete: false, release: true)
                let progress = request.progress(decoded: checkpoint.decoded, confirmed: checkpoint.confirmed,
                                                durable: checkpoint.decoded)
                var updated = record
                updated.operationID = operation
                updated.durableCheckpointDigest = SHA256.hash(data: payload)
                updated.outcome = SceneScanOutcome(state: .paused, report: nil, progress: progress)
                session.lock.lock()
                session.partial[request.key] = updated
                if let operation { session.operations[request.key, default: [:]][operation] = updated }
                session.lock.unlock()
                return progress
            }
        }
    }
}
