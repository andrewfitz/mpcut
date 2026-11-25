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
/// its retained history references are protected through `SidecarClearContext`.
@MainActor
final class SharedCacheLimitEnforcer {
    typealias Enforce = @Sendable (_ limit: Int64, _ protected: Set<URL>, _ root: URL) -> SharedCacheLimit.Outcome

    private let preferences: EditorPreferences
    private let context: @MainActor () -> SidecarClearContext
    private let root: @Sendable () -> URL?
    private let enforce: Enforce
    private let retryDelay: Duration
    private var observers = Set<AnyCancellable>()
    private var running = false
    private var rerun = false
    private var retry: Task<Void, Never>?
    private(set) var lastOutcome: SharedCacheLimit.Outcome?

    /// `root` is the shared cache folder in cache-disk mode, nil otherwise. Tests pass a temporary folder.
    init(preferences: EditorPreferences, context: @escaping @MainActor () -> SidecarClearContext,
         root: @escaping @Sendable () -> URL? = { SharedCacheLimit.configuredRoot },
         retryDelay: Duration = .seconds(10),
         enforce: @escaping Enforce = { SharedCacheLimit.enforce(limit: $0, protected: $1, root: $2) }) {
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
        let root = self.root, enforce = self.enforce, protected = current.protected
        return Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> SharedCacheLimit.Outcome? in
                guard let folder = root() else { return nil }
                return enforce(Int64(limit), protected, folder)
            }.value
            guard let self else { return }
            self.running = false
            if let outcome {
                self.lastOutcome = outcome
                if !outcome.removedSources.isEmpty {
                    NotificationCenter.default.post(name: .sidecarCachesDidClear, object: outcome.removedSources,
                                                    userInfo: ["wholeSidecars": true])
                }
            }
            if self.rerun {
                self.rerun = false
                self.schedule()
            }
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
