import AppKit
import Combine
import MPCutCore

struct ProjectMediaRefreshInput: Sendable {
    let url: URL
    var previous: MediaInfo?
}

@MainActor
final class ProjectMediaRefresh {
    private var token: EditCancellation?
    private var receipt: MCPAnalysisReceipt?
    private var fraction = 0.0
    private(set) var worker: Task<Void, Never>?

    private struct Recording: Sendable {
        var input: ProjectMediaRefreshInput
        let identity: SourceIdentity?
        var aliases: Set<URL>
    }

    private nonisolated static func recordings(_ inputs: [ProjectMediaRefreshInput]) -> [Recording] {
        var groups: [Recording] = []
        var physical = [SourceIdentity: Int]()
        var offline = [URL: Int]()
        for input in inputs.sorted(by: { $0.url.path < $1.url.path }) {
            let identity = try? SourceIdentity(input.url)
            let canonical = identity == nil ? input.url.resolvingSymlinksInPath() : input.url
            if let index = identity.flatMap({ physical[$0] }) ?? offline[canonical] {
                groups[index].aliases.insert(input.url)
                if groups[index].input.previous == nil && input.previous != nil { groups[index].input = input }
            } else {
                if let identity { physical[identity] = groups.count }
                else { offline[canonical] = groups.count }
                groups.append(Recording(input: input, identity: identity, aliases: [input.url]))
            }
        }
        return groups
    }

    var activeReceipt: MCPAnalysisReceipt? { receipt }

    func cancel() { token?.cancel() }

    func start(inputs: [ProjectMediaRefreshInput], deep: Bool, verify: Set<URL>, persist: Bool, alignForMulticam: Bool = false,
               exclusions: Set<URL>, receipt: MCPAnalysisReceipt?, previewSources: Set<URL> = [],
               preview: ((MediaInfo, Set<URL>) -> Void)? = nil, progress: @escaping (Double) -> Void,
               publish: @escaping (MediaRefreshResult, Set<URL>, MediaInfo?) -> Void, finished: @escaping (String) -> Void) {
        guard token == nil, !inputs.isEmpty else {
            receipt?.finish("failed", detail: ["error": "Project media refresh is unavailable."])
            return
        }
        let token = EditCancellation()
        self.token = token
        self.receipt = receipt
        receipt?.cancelNative = { token.cancel() }
        fraction = 0
        receipt?.nativeProgress = { [weak self] in self?.fraction }
        let cleanup = receipt?.cleanup.begin()
        worker = Task {
            defer { cleanup?() }
            let unique = await Task.detached(priority: .utility) { Self.recordings(inputs) }.value
            var details: [[String: Any]] = []
            var errors = 0
            var updates = 0
            for (index, recording) in unique.enumerated() {
                guard !token.isCancelled else { break }
                let first = recording.input
                let force = deep || !recording.aliases.isDisjoint(with: verify)
                if let preview, let identity = recording.identity, let previous = first.previous,
                   !identity.matchesSnapshot(previous.identity), !recording.aliases.isDisjoint(with: previewSources) {
                    let header = await Task.detached(priority: .userInitiated) {
                        try? CutEngine(cancelled: { token.isCancelled }, useSidecar: false).inspectForPreview(first.url)
                    }.value
                    guard !token.isCancelled, self.token === token else { break }
                    if let header, header.identity.matchesSnapshot(identity) {
                        preview(header, recording.aliases)
                    }
                }
                let interval = 1.0 / Double(unique.count)
                let task = Task.detached(priority: .utility) {
                    try AnalysisSidecar.$readsEnabled.withValue(persist) { () -> (MediaRefreshResult, MediaInfo?) in
                        let result = try MediaRefresh.check(first.url, identity: recording.identity, previous: first.previous,
                                               verification: force ? .deep : .stamp, persist: persist,
                                               exclusions: exclusions, progress: { progressValue in
                            let report = min(0.999, (Double(index) + progressValue) * interval)
                            guard token.shouldReport(report) else { return }
                            DispatchQueue.main.async {
                                guard self.token === token, !token.isCancelled, report >= self.fraction else { return }
                                self.fraction = report
                                progress(report)
                            }
                        }, cancelled: { token.isCancelled })
                        let aligned = alignForMulticam ? result.media.flatMap { media in
                            try? CutEngine(cancelled: { token.isCancelled }).multicamClock(media)
                        } : nil
                        return (result, aligned)
                    }
                }
                do {
                    let (result, aligned) = try await task.value
                    guard !token.isCancelled, self.token === token else { break }
                    if let media = result.media,
                       recording.aliases.contains(where: { !media.identity.isCurrentSnapshot(at: $0) }) {
                        throw CutError(code: "source_changed", message: "The recording changed again during refresh.")
                    }
                    publish(result, recording.aliases, aligned)
                    if result.state != .unchanged { updates += 1 }
                    details.append(["path": result.source.path, "aliases": recording.aliases.map(\.path).sorted(), "state": result.state.rawValue,
                                    "scenesPreserved": result.scenesPreserved,
                                    "preservedAudioStreams": result.preservedAudioStreams.sorted(),
                                    "reviewStreams": result.reviewStreams.sorted(),
                                    "persistenceError": result.persistenceError as Any? ?? NSNull()])
                } catch {
                    if token.isCancelled { break }
                    errors += 1
                    details.append(["path": first.url.path, "state": "failed", "error": error.localizedDescription])
                }
                fraction = min(0.999, Double(index + 1) * interval)
                progress(fraction)
            }
            let outcome = token.isCancelled ? "cancelled" : (errors == 0 ? "succeeded" : "failed")
            receipt?.finish(outcome, detail: ["sources": details])
            guard self.token === token else { return }
            self.token = nil
            self.receipt = nil
            self.worker = nil
            if token.isCancelled { finished("Media refresh cancelled.") }
            else if errors > 0 { finished("Media refresh could not check \(errors) recordings.") }
            else if updates > 0 { finished("Checked project media. \(updates) recordings changed or are offline.") }
            else { finished("Project media is up to date.") }
        }
    }

    func reset() {
        cancel()
        token = nil
        worker = nil
        receipt?.finish("cancelled")
        receipt = nil
    }
}

/// Directory events detect atomic replacements. Per-file events verify writes
/// that preserve mtime and size. A second stamp after a quiet period gives a
/// file still being written another chance to settle before indexing.
@MainActor
final class ProjectMediaWatcher {
    private var watches: [URL: DispatchSourceFileSystemObject] = [:]
    private var files = Set<URL>()
    private var stamps: [URL: SourceIdentity] = [:]
    private var verify = Set<URL>()
    private var checkOnActivation = false
    private var task: Task<Void, Never>?
    private var directoryCheck: Task<Void, Never>?
    private var observedDirectoryStamps: [URL: SourceIdentity]?
    private var notifications = Set<AnyCancellable>()
    private let refresh: (Set<URL>) -> Bool

    init(refresh: @escaping (Set<URL>) -> Bool) {
        self.refresh = refresh
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.event(check: true) }.store(in: &notifications)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .sink { [weak self] _ in self?.event(check: true) }.store(in: &notifications)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
            .sink { [weak self] _ in self?.event(check: true) }.store(in: &notifications)
    }

    func update(_ urls: Set<URL>) {
        guard urls != files else { return }
        stamps = stamps.filter { urls.contains($0.key) }
        files = urls
        observedDirectoryStamps = nil
        verify.formIntersection(urls)
        installWatches()
        event(check: true)
    }

    private func installWatches() {
        var paths = files
        for file in files {
            var parent = file.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                parent.deleteLastPathComponent()
            }
            paths.insert(parent)
        }
        for path in Set(watches.keys).subtracting(paths) { watches.removeValue(forKey: path)?.cancel() }
        for path in paths where watches[path] == nil {
            let fd = open(path.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let mask: DispatchSource.FileSystemEvent = files.contains(path)
                ? [.write, .extend, .rename, .delete, .revoke] : [.write, .rename, .delete, .revoke]
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self] in
                guard let self, let data = self.watches[path]?.data else { return }
                if !data.intersection([.delete, .revoke, .rename]).isEmpty {
                    self.watches.removeValue(forKey: path)?.cancel()
                }
                if self.files.contains(path) {
                    let written = !data.intersection([.write, .extend]).isEmpty
                    self.event(verify: written ? path : nil)
                } else {
                    self.directoryChanged()
                }
            }
            watches[path] = source
            source.resume()
        }
    }

    private func directoryChanged() {
        guard directoryCheck == nil, !files.isEmpty else { return }
        directoryCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let files = self.files
            let observed = await Task.detached(priority: .utility) { Self.readStamps(files) }.value
            guard !Task.isCancelled else { return }
            self.directoryCheck = nil
            // SQLite journal churn can touch this directory without changing a recording.
            guard self.files == files, observed != self.stamps, observed != self.observedDirectoryStamps else { return }
            self.observedDirectoryStamps = observed
            self.event()
        }
    }

    private func event(verify url: URL? = nil, check: Bool = false) {
        checkOnActivation = checkOnActivation || check
        if let url { verify.insert(url) }
        task?.cancel()
        guard !files.isEmpty else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let files = self.files
            let initial = await Task.detached(priority: .utility) { Self.readStamps(files) }.value
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let stable = await Task.detached(priority: .utility) { Self.readStamps(files) }.value
            guard !Task.isCancelled, self.files == files else { return }
            guard stable == initial else { self.event(); return }
            self.installWatches()
            guard self.checkOnActivation || stable != self.stamps || !self.verify.isEmpty else { return }
            guard self.refresh(self.verify) else { self.event(); return }
            self.stamps = stable
            self.observedDirectoryStamps = nil
            self.checkOnActivation = false
            self.verify.removeAll()
        }
    }

    private nonisolated static func readStamps(_ files: Set<URL>) -> [URL: SourceIdentity] {
        Dictionary(uniqueKeysWithValues: files.compactMap { url in
            (try? SourceIdentity(url)).map { (url, $0) }
        })
    }

    func stop() {
        notifications.removeAll()
        task?.cancel()
        task = nil
        directoryCheck?.cancel()
        directoryCheck = nil
        files.removeAll()
        verify.removeAll()
        for source in watches.values { source.cancel() }
        watches.removeAll()
    }

    deinit {
        task?.cancel()
        directoryCheck?.cancel()
        for source in watches.values { source.cancel() }
    }
}

