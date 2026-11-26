import Combine
import Foundation
import MPCutCore

extension Notification.Name {
    /// Posted after the app writes a cutcache. The object is the cutcache URL.
    static let analysisCutcacheDidSave = Notification.Name("MPCutAnalysisCutcacheDidSave")
}

/// Keeps the managed `MPCut Cache` folder under Settings → Storage → Limit the shared cache folder.
/// It runs at launch, when the limit changes and after the app saves a cutcache, off the main actor. It does
/// nothing while the limit is 0 and reads nothing outside cache-disk mode. Recordings that an open project or
/// its retained history references are protected through `SidecarClearContext`, which is read again on the main
/// actor before each removal: a project that opens during a run keeps its cutcaches, and a window that starts
/// opening or importing stops the run until it settles. A run that could remove nothing is not repeated until
/// the limit, the folder or the protected recordings change.
@MainActor
final class SharedCacheLimitEnforcer {
    typealias Enforce = @Sendable (_ limit: Int64, _ protected: Set<URL>, _ root: URL,
                                   _ recheck: @escaping SharedCacheLimit.Recheck) -> SharedCacheLimit.Outcome
    /// A run that ended over the limit with nothing it could remove.
    private struct Stall: Equatable, Sendable {
        let limit: Int
        let protected: Set<URL>
        let root: URL
    }

    private let preferences: EditorPreferences
    private let context: @MainActor () -> SidecarClearContext
    private let root: @Sendable () -> URL?
    private let enforce: Enforce
    private let retryDelay: Duration
    private var observers = Set<AnyCancellable>()
    private var running = false
    private var rerun = false
    private var retry: Task<Void, Never>?
    private var stall: Stall?
    private(set) var lastOutcome: SharedCacheLimit.Outcome?

    /// `root` is the shared cache folder in cache-disk mode, nil otherwise. Tests pass a temporary folder.
    init(preferences: EditorPreferences, context: @escaping @MainActor () -> SidecarClearContext,
         root: @escaping @Sendable () -> URL? = { SharedCacheLimit.configuredRoot },
         retryDelay: Duration = .seconds(10),
         enforce: @escaping Enforce = { SharedCacheLimit.enforce(limit: $0, protected: $1, root: $2, recheck: $3) }) {
        self.preferences = preferences
        self.context = context
        self.root = root
        self.retryDelay = retryDelay
        self.enforce = enforce
    }

    deinit { retry?.cancel() }

    /// Enforces now, then on every change of the limit and every cutcache the app saves.
    func start() {
        preferences.observeChanges { [weak self] change in
            if change == .sharedCacheLimitBytes { self?.schedule() }
        }
        .store(in: &observers)
        NotificationCenter.default.publisher(for: .analysisCutcacheDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &observers)
        schedule()
    }

    /// Starts one enforcement and returns its task, or nil when there is nothing to do yet.
    @discardableResult
    func schedule() -> Task<Void, Never>? {
        let limit = preferences.sharedCacheLimitBytes
        guard limit > 0 else { return nil }
        guard !running else {
            rerun = true
            return nil
        }
        let current = context()
        // A project still opening or importing has not listed its recordings yet, so nothing is safe to evict.
        guard !current.isSettling else {
            retryLater()
            return nil
        }
        running = true
        let root = self.root, enforce = self.enforce, protected = current.protected, stall = self.stall
        let recheck = Self.recheck(context)
        return Task { [weak self] in
            let run = await Task.detached(priority: .utility) { () -> (outcome: SharedCacheLimit.Outcome, stall: Stall)? in
                guard let folder = root() else { return nil }
                let attempt = Stall(limit: limit, protected: protected, root: folder)
                // Nothing could be removed last time and nothing has changed since: do not walk the folder again.
                guard attempt != stall else { return nil }
                return (enforce(Int64(limit), protected, folder, recheck), attempt)
            }.value
            guard let self else { return }
            self.running = false
            if let run {
                let outcome = run.outcome
                self.lastOutcome = outcome
                self.stall = !outcome.aborted && outcome.removed.isEmpty && outcome.bytesAfter > Int64(limit) ? run.stall : nil
                if !outcome.removedSources.isEmpty {
                    NotificationCenter.default.post(name: .sidecarCachesDidClear, object: outcome.removedSources,
                                                    userInfo: ["wholeSidecars": true])
                }
                if outcome.aborted { self.retryLater() }
            }
            if self.rerun {
                self.rerun = false
                self.schedule()
            }
        }
    }

    /// Hops to the main actor and reads the protection again. Nil, while a window is opening or importing, stops the run.
    private nonisolated static func recheck(_ context: @escaping @MainActor () -> SidecarClearContext) -> SharedCacheLimit.Recheck {
        { () -> Set<URL>? in
            let read = { @MainActor () -> Set<URL>? in
                let current = context()
                return current.isSettling ? nil : current.protected
            }
            if Thread.isMainThread { return MainActor.assumeIsolated(read) }
            return DispatchQueue.main.sync { MainActor.assumeIsolated(read) }
        }
    }

    private func retryLater() {
        guard retry == nil else { return }
        let delay = retryDelay
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.schedule()
        }
    }
}
