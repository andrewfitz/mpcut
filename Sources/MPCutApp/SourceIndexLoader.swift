import Foundation
import MPCutCore

/// A shared queue keeps background packet scans from delaying preview probes.
@MainActor
final class SourceIndexLoader {
    struct Key: Hashable, Sendable {
        let url: URL
        let sidecars: Bool
        let preview: Bool
        var identity: SourceIdentity? = nil
    }

    final class Index: Sendable {
        let ordinary: MediaInfo
        let multicam: MediaInfo

        init(ordinary: MediaInfo, multicam: MediaInfo) {
            self.ordinary = ordinary
            self.multicam = multicam
        }

        var storageBytes: Int {
            ordinary.indexStorageBytes + (multicam.multicamClockOffset == .zero ? 0 : multicam.indexStorageBytes)
        }
    }

    /// This cache adds at most a small bounded set of indexes to those held by open windows.
    private final class CompletedIndexes: @unchecked Sendable {
        private struct Entry {
            let url: URL
            let sidecars: Bool
            let index: Index
            let cost: Int
        }

        private let lock = NSLock()
        private let byteLimit: Int
        private let countLimit = 8
        private var entries: [Entry] = []
        private var bytes = 0

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
                    guard entry.url == key.url, entry.index.ordinary.identity != identity else { return false }
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

    private struct Subscriber {
        let progress: (Double) -> Void
        let completion: (Result<Index, Error>) -> Void
    }

    static let shared = SourceIndexLoader()
    private let probes = OperationQueue()
    private let indexes = OperationQueue()
    private let completed: CompletedIndexes
    private var requests: [Key: Request] = [:]

    init(completedIndexByteLimit: Int = 64 * 1_024 * 1_024) {
        completed = CompletedIndexes(byteLimit: completedIndexByteLimit)
        probes.maxConcurrentOperationCount = 4
        probes.qualityOfService = .userInitiated
        indexes.maxConcurrentOperationCount = 2
        indexes.qualityOfService = .utility
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
               completion: @escaping (Result<Index, Error>) -> Void) -> () -> Void {
        var cancel: (() -> Void)?
        cancel = load(key, progress: progress) { result in
            // Some containers do not declare a usable duration in the header.
            if case let .failure(error as PreviewUnavailable) = result {
                cancel = self.load(.init(url: key.url, sidecars: key.sidecars, preview: false, identity: error.identity),
                                   progress: progress, completion: completion)
            } else {
                completion(result)
            }
        }
        return { cancel?() }
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
                    guard self?.requests[key]?.subscribers[id] != nil else { return }
                    progress(fraction)
                }
            }
        } else {
            let request = Request()
            request.subscribers[id] = subscriber
            requests[key] = request
            let token = request.token
            let completed = self.completed
            let finish: @Sendable (Result<Index, Error>) -> Void = { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, let request = self.requests[key], request.token === token else { return }
                    self.requests[key] = nil
                    for subscriber in Array(request.subscribers.values) { subscriber.completion(result) }
                }
            }
            let freshIdentity: @Sendable () throws -> SourceIdentity = {
                let identity = try SourceIdentity(key.url)
                guard key.identity.map({ $0 == identity }) ?? true else {
                    throw CutError(code: "source_changed", message: "The recording changed while loading. Relink it to continue.")
                }
                return identity
            }
            let work: @Sendable () -> Void = { [weak self] in
                guard !token.isCancelled else { return }
                let result = Result {
                    let engine = CutEngine(cancelled: { token.isCancelled }, useSidecar: key.sidecars)
                    let identity = try freshIdentity()
                    if !key.preview, let cached = completed.index(for: key, identity: identity) {
                        return cached
                    }
                    let ordinary: MediaInfo
                    if key.preview {
                        do { ordinary = try engine.inspectForPreview(key.url) }
                        catch { throw PreviewUnavailable(identity: identity) }
                    } else {
                        ordinary = try engine.inspect(key.url, keyframes: true, expectedIdentity: identity) { fraction in
                            guard token.shouldReport(fraction) else { return }
                            Task { @MainActor [weak self] in
                                guard let request = self?.requests[key], request.token === token,
                                      fraction > request.fraction else { return }
                                request.fraction = fraction
                                for subscriber in Array(request.subscribers.values) { subscriber.progress(fraction) }
                            }
                        }
                    }
                    guard key.preview || ordinary.hasFullEditIndex else {
                        throw CutError(code: "incomplete_index", message: "The recording has no complete editing index.")
                    }
                    let index = Index(ordinary: ordinary, multicam: try engine.multicamClock(ordinary))
                    guard ordinary.identity == identity, try SourceIdentity(key.url) == identity else {
                        throw CutError(code: "source_changed", message: "The recording changed while loading. Relink it to continue.")
                    }
                    if token.isCancelled { throw CancellationError() }
                    if !key.preview { completed.store(index, for: key) }
                    return index
                }
                finish(result)
            }
            if key.preview {
                probes.addOperation(work)
            } else if completed.hasCandidate(for: key) {
                // A warm recording can reopen while both scan slots are occupied.
                let indexes = self.indexes
                probes.addOperation {
                    guard !token.isCancelled else { return }
                    do {
                        let identity = try freshIdentity()
                        if let cached = completed.index(for: key, identity: identity) {
                            finish(.success(cached))
                        } else {
                            indexes.addOperation(work)
                        }
                    } catch {
                        finish(.failure(error))
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
