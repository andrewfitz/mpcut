import Foundation
import MPCutCore

/// A shared queue keeps background packet scans from delaying preview probes.
@MainActor
final class SourceIndexLoader {
    struct Key: Hashable, Sendable {
        let url: URL
        let sidecars: Bool
        let preview: Bool
        let identity: SourceIdentity?
        let preferCompleted: Bool
        // SourceIdentity's ordinary equality intentionally ignores metadata-only changes.
        private let changeTime: SourceIdentity.ChangeTime?

        init(url: URL, sidecars: Bool, preview: Bool, identity: SourceIdentity? = nil, preferCompleted: Bool = false) {
            self.url = url.standardizedFileURL
            self.sidecars = sidecars
            self.preview = preview
            self.identity = identity
            self.preferCompleted = preferCompleted
            changeTime = identity?.changeTime
        }
    }

    final class Index: Sendable {
        let ordinary: MediaInfo

        init(ordinary: MediaInfo) {
            self.ordinary = ordinary
        }

        var storageBytes: Int {
            ordinary.indexStorageBytes
        }
    }

    final class MulticamIndex: Sendable {
        let ordinary: MediaInfo
        let multicam: MediaInfo

        init(ordinary: MediaInfo, multicam: MediaInfo) {
            self.ordinary = ordinary
            self.multicam = multicam
        }
    }

    /// This cache adds at most a small bounded set of indexes to those held by open windows.
    private final class CompletedIndexes: @unchecked Sendable {
        private struct Entry {
            let url: URL
            let sidecars: Bool
            let index: Index
            var cost: Int
            var multicam: MulticamIndex?
        }

        // A provisional import can continue with a packet scan after a corrupt sidecar.
        // Pin the miss to both files so a replacement sidecar can be used immediately.
        private struct FailedRestore {
            let url: URL
            let source: SourceIdentity
            let sidecar: SourceIdentity
            let fraction: Double
        }

        private let lock = NSLock()
        private let byteLimit: Int
        private let countLimit = 8
        private var entries: [Entry] = []
        private var bytes = 0
        private var failedRestores: [FailedRestore] = []

        init(byteLimit: Int) {
            self.byteLimit = byteLimit
        }

        func hasCandidate(for key: Key) -> Bool {
            lock.withLock {
                entries.contains { $0.url == key.url && $0.sidecars == key.sidecars }
            }
        }

        func index(for key: Key, identity: SourceIdentity) -> Index? {
            lock.withLock {
                entries.removeAll { entry in
                    guard entry.url == key.url, !entry.index.ordinary.identity.matchesSnapshot(identity) else { return false }
                    bytes -= entry.cost
                    return true
                }
                guard let position = entries.firstIndex(where: { $0.url == key.url && $0.sidecars == key.sidecars }) else {
                    return nil
                }
                let entry = entries.remove(at: position)
                entries.append(entry)
                return entry.index
            }
        }

        func discard(_ url: URL) {
            lock.withLock {
                failedRestores.removeAll { $0.url == url }
                entries.removeAll { entry in
                    guard entry.url.standardizedFileURL == url else { return false }
                    bytes -= entry.cost
                    return true
                }
            }
        }

        func recordFailedRestore(for url: URL, source: SourceIdentity, sidecar: SourceIdentity, fraction: Double) {
            lock.withLock {
                failedRestores.removeAll { $0.url == url }
                if failedRestores.count >= countLimit { failedRestores.removeFirst() }
                failedRestores.append(FailedRestore(url: url, source: source, sidecar: sidecar, fraction: fraction))
            }
        }

        func failedRestoreProgress(for url: URL, source: SourceIdentity, sidecar: SourceIdentity) -> Double? {
            lock.withLock {
                failedRestores.first {
                    $0.url == url && $0.source.matchesSnapshot(source) && $0.sidecar.matchesSnapshot(sidecar)
                }?.fraction
            }
        }

        func multicam(for index: Index) -> MulticamIndex? {
            lock.withLock { entries.first { $0.index === index }?.multicam }
        }

        func store(_ converted: MulticamIndex, for index: Index) {
            let extra = converted.multicam.indexStorageBytes
            lock.withLock {
                guard let position = entries.firstIndex(where: { $0.index === index }),
                      entries[position].multicam == nil, extra <= byteLimit - entries[position].cost else { return }
                var entry = entries.remove(at: position)
                while bytes > byteLimit - extra {
                    bytes -= entries.removeFirst().cost
                }
                entry.multicam = converted
                entry.cost += extra
                bytes += extra
                entries.append(entry)
            }
        }

        func store(_ index: Index, for key: Key) {
            let cost = index.storageBytes
            guard cost <= byteLimit else { return }
            lock.withLock {
                if let existing = entries.firstIndex(where: { $0.url == key.url && $0.sidecars == key.sidecars }) {
                    bytes -= entries.remove(at: existing).cost
                }
                while entries.count >= countLimit || bytes + cost > byteLimit {
                    bytes -= entries.removeFirst().cost
                }
                entries.append(Entry(url: key.url, sidecars: key.sidecars, index: index, cost: cost))
                bytes += cost
            }
        }
    }

    private struct PreviewUnavailable: Error { let identity: SourceIdentity }

    private final class Request {
        let token = EditCancellation()
        var subscribers: [UUID: Subscriber] = [:]
        var fraction = 0.0
    }

    private final class Conversion {
        let source: URL

        init(source: URL) { self.source = source }

        let token = EditCancellation()
        var completions: [UUID: (Result<MulticamIndex, Error>) -> Void] = [:]
    }

    private struct Subscriber {
        let progress: (Double) -> Void
        let completion: (Result<Index, Error>) -> Void
    }

    static let shared = SourceIndexLoader()
    private let probes = OperationQueue()
    private let restores = OperationQueue()
    private let indexes = OperationQueue()
    private let completed: CompletedIndexes
    private var requests: [Key: Request] = [:]
    private var conversions: [ObjectIdentifier: Conversion] = [:]

    init(completedIndexByteLimit: Int = 64 * 1_024 * 1_024) {
        completed = CompletedIndexes(byteLimit: completedIndexByteLimit)
        probes.maxConcurrentOperationCount = 4
        probes.qualityOfService = .userInitiated
        restores.maxConcurrentOperationCount = 2
        restores.qualityOfService = .userInitiated
        indexes.maxConcurrentOperationCount = 2
        indexes.qualityOfService = .utility
    }

    /// A manual or watched refresh has already paid to index this recording.
    func acceptRefreshedIndex(_ media: MediaInfo, sidecars: Bool) {
        let url = media.url.standardizedFileURL
        let stale = CutError(code: "source_changed", message: "The recording changed while loading.")
        let obsolete = requests.filter { $0.key.url.standardizedFileURL == url }
        for (key, request) in obsolete {
            requests[key] = nil
            request.token.cancel()
        }
        let obsoleteConversions = conversions.filter { $0.value.source == url }
        for (id, conversion) in obsoleteConversions {
            conversions[id] = nil
            conversion.token.cancel()
        }
        completed.discard(url)
        if media.hasFullEditIndex {
            completed.store(Index(ordinary: media), for: Key(url: url, sidecars: sidecars, preview: false))
        }
        // Detach all requests before notifying callers. Their handlers may immediately retry.
        for request in obsolete.values {
            for subscriber in request.subscribers.values { subscriber.completion(.failure(stale)) }
        }
        for conversion in obsoleteConversions.values {
            for completion in conversion.completions.values { completion(.failure(stale)) }
        }
    }

    func read(_ key: Key, token: EditCancellation, preference: EditCancellation,
              progress: @escaping (Double) -> Void) async throws -> Index {
        guard !token.isCancelled, !preference.isCancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            let tokens = [token, preference]
            var observers: [UUID] = []
            var finished = false
            func finish(_ result: Result<Index, Error>) {
                guard !finished else { return }
                finished = true
                for (token, id) in zip(tokens, observers) { token.removeCancellationHandler(id) }
                continuation.resume(with: result)
            }
            let cancel = load(key, progress: progress, completion: finish)
            for token in tokens {
                observers.append(token.onCancel {
                    Task { @MainActor in
                        cancel()
                        finish(.failure(CancellationError()))
                    }
                })
            }
        }
    }

    func admit(_ key: Key, progress: @escaping (Double) -> Void = { _ in },
               completion: @escaping (Result<MulticamIndex, Error>) -> Void) -> () -> Void {
        let key = Key(url: key.url, sidecars: key.sidecars, preview: key.preview,
                      identity: key.identity, preferCompleted: key.preview)
        var cancel: (() -> Void)?
        let convert: (Result<Index, Error>) -> Void = { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(index): cancel = self.convert(index, key: key, completion: completion)
            }
        }
        cancel = load(key, progress: progress) { result in
            // Some containers do not declare a usable duration in the header.
            if case let .failure(error as PreviewUnavailable) = result {
                cancel = self.load(.init(url: key.url, sidecars: key.sidecars, preview: false, identity: error.identity),
                                   progress: progress, completion: convert)
            } else {
                convert(result)
            }
        }
        return { cancel?() }
    }

    private func convert(_ index: Index, key: Key,
                         completion: @escaping (Result<MulticamIndex, Error>) -> Void) -> () -> Void {
        let ordinary = index.ordinary
        if ordinary.hasFullEditIndex, ordinary.multicamSourceOffset == .zero {
            completion(.success(MulticamIndex(ordinary: ordinary, multicam: ordinary)))
            return {}
        }
        if let warm = completed.multicam(for: index) {
            completion(.success(warm))
            return {}
        }
        let id = ObjectIdentifier(index)
        let subscriber = UUID()
        if let conversion = conversions[id] {
            conversion.completions[subscriber] = completion
        } else {
            let conversion = Conversion(source: key.url.standardizedFileURL)
            conversion.completions[subscriber] = completion
            conversions[id] = conversion
            let token = conversion.token
            let queue = ordinary.hasFullEditIndex ? indexes : probes
            queue.addOperation { [weak self] in
                guard !token.isCancelled else { return }
                let result = Result {
                    let engine = CutEngine(cancelled: { token.isCancelled }, useSidecar: key.sidecars)
                    let multicam = try engine.multicamClock(ordinary)
                    guard ordinary.identity.isCurrentSnapshot(at: key.url) else {
                        throw CutError(code: "source_changed", message: "The recording changed while loading. Relink it to continue.")
                    }
                    return MulticamIndex(ordinary: ordinary, multicam: multicam)
                }
                Task { @MainActor [weak self] in
                    guard let self, let current = self.conversions[id], current.token === token else { return }
                    self.conversions[id] = nil
                    if case let .success(converted) = result, ordinary.hasFullEditIndex {
                        self.completed.store(converted, for: index)
                    }
                    for completion in current.completions.values { completion(result) }
                }
            }
        }
        return { [weak self] in
            guard let self, let conversion = self.conversions[id],
                  conversion.completions.removeValue(forKey: subscriber) != nil,
                  conversion.completions.isEmpty else { return }
            conversion.token.cancel()
            self.conversions[id] = nil
        }
    }

    func load(_ key: Key, progress: @escaping (Double) -> Void = { _ in },
              completion: @escaping (Result<Index, Error>) -> Void) -> () -> Void {
        let id = UUID()
        let subscriber = Subscriber(progress: progress, completion: completion)
        if let request = requests[key] {
            request.subscribers[id] = subscriber
            let fraction = request.fraction
            if fraction > 0 {
                Task { @MainActor [weak self] in
                    guard let current = self?.requests[key], current.subscribers[id] != nil,
                          current.fraction == fraction else { return }
                    progress(fraction)
                }
            }
        } else {
            let request = Request()
            request.subscribers[id] = subscriber
            requests[key] = request
            let token = request.token
            let completed = self.completed
            let finish: @Sendable (Result<Index, Error>, Bool) -> Void = { [weak self] result, shouldStore in
                Task { @MainActor [weak self] in
                    guard let self, let request = self.requests[key], request.token === token else { return }
                    self.requests[key] = nil
                    if shouldStore, case let .success(index) = result { self.completed.store(index, for: key) }
                    for subscriber in Array(request.subscribers.values) { subscriber.completion(result) }
                }
            }
            let freshIdentity: @Sendable () throws -> SourceIdentity = {
                let identity = try SourceIdentity(key.url)
                guard key.identity.map({ $0.matchesSnapshot(identity) }) ?? true else {
                    throw CutError(code: "source_changed", message: "The recording changed while loading. Relink it to continue.")
                }
                return identity
            }
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                guard token.shouldReport(fraction) else { return }
                Task { @MainActor [weak self] in
                    guard let request = self?.requests[key], request.token === token,
                          fraction > request.fraction else { return }
                    request.fraction = fraction
                    for subscriber in Array(request.subscribers.values) { subscriber.progress(fraction) }
                }
            }
            let sidecarURL = AnalysisSidecar.url(for: key.url)
            let work: @Sendable () -> Void = {
                guard !token.isCancelled else { return }
                var shouldStore = false
                let result = Result {
                    let engine = CutEngine(cancelled: { token.isCancelled }, useSidecar: key.sidecars)
                    let identity = try freshIdentity()
                    if !key.preview || key.preferCompleted,
                       let cached = completed.index(for: key, identity: identity) {
                        return cached
                    }
                    let ordinary: MediaInfo
                    if key.preview {
                        do { ordinary = try engine.inspectForPreview(key.url) }
                        catch { throw PreviewUnavailable(identity: identity) }
                    } else {
                        if key.sidecars, let sidecar = try? SourceIdentity(sidecarURL),
                           let restored = completed.failedRestoreProgress(for: key.url, source: identity, sidecar: sidecar) {
                            report(restored)
                            ordinary = try engine.inspectFresh(key.url, keyframes: true, expectedIdentity: identity,
                                                               progress: { report(restored + (1 - restored) * $0) })
                        } else {
                            ordinary = try engine.inspect(key.url, keyframes: true, expectedIdentity: identity, progress: report)
                        }
                    }
                    guard key.preview || ordinary.hasFullEditIndex else {
                        throw CutError(code: "incomplete_index", message: "The recording has no complete editing index.")
                    }
                    let index = Index(ordinary: ordinary)
                    guard ordinary.identity.matchesSnapshot(identity), identity.isCurrentSnapshot(at: key.url) else {
                        throw CutError(code: "source_changed", message: "The recording changed while loading. Relink it to continue.")
                    }
                    if token.isCancelled { throw CancellationError() }
                    shouldStore = !key.preview
                    return index
                }
                finish(result, shouldStore)
            }
            if key.preview, key.preferCompleted, key.sidecars {
                let probes = self.probes
                let restores = self.restores
                probes.addOperation {
                    guard !token.isCancelled else { return }
                    do {
                        let identity = try freshIdentity()
                        if let cached = completed.index(for: key, identity: identity) {
                            finish(.success(cached), false)
                            return
                        }
                        guard let sidecar = try? SourceIdentity(sidecarURL),
                              let cache = try? AnalysisSidecar(source: key.url),
                              completed.failedRestoreProgress(for: key.url, source: identity, sidecar: sidecar) == nil else {
                            work()
                            return
                        }
                        // Check the section names before occupying a slot that restores packet indexes.
                        guard cache.containsSections(AnalysisSidecar.indexKeys, cancelled: { token.isCancelled }) else {
                            work()
                            return
                        }
                        restores.addOperation {
                            guard !token.isCancelled else { return }
                            do {
                                if let cached = completed.index(for: key, identity: try freshIdentity()) {
                                    finish(.success(cached), false)
                                    return
                                }
                                let engine = CutEngine(cancelled: { token.isCancelled }, useSidecar: true)
                                var fraction = 0.0
                                if let media = try engine.cachedIndex(key.url, expectedIdentity: identity, progress: {
                                    fraction = max(fraction, min($0, 0.999))
                                    report(fraction)
                                }), media.hasFullEditIndex {
                                    report(1)
                                    finish(.success(Index(ordinary: media)), true)
                                } else {
                                    guard !token.isCancelled else { return }
                                    completed.recordFailedRestore(for: key.url, source: identity, sidecar: sidecar, fraction: fraction)
                                    probes.addOperation(work)
                                }
                            } catch {
                                finish(.failure(error), false)
                            }
                        }
                    } catch {
                        finish(.failure(error), false)
                    }
                }
            } else if key.preview {
                probes.addOperation(work)
            } else if completed.hasCandidate(for: key) {
                // A warm recording can reopen while both scan slots are occupied.
                let indexes = self.indexes
                probes.addOperation {
                    guard !token.isCancelled else { return }
                    do {
                        let identity = try freshIdentity()
                        if let cached = completed.index(for: key, identity: identity) {
                            finish(.success(cached), false)
                        } else {
                            indexes.addOperation(work)
                        }
                    } catch {
                        finish(.failure(error), false)
                    }
                }
            } else {
                indexes.addOperation(work)
            }
        }
        return { [weak self] in
            guard let self, let request = self.requests[key],
                  request.subscribers.removeValue(forKey: id) != nil, request.subscribers.isEmpty else { return }
            request.token.cancel()
            self.requests[key] = nil
        }
    }
}
