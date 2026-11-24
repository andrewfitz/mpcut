import AppKit
import Combine
import MPCutCore

struct ProjectMediaRefreshInput: Sendable {
    let url: URL
    var previous: MediaInfo?
    var requiresIndex = false
    var presenceOnly = false
}

extension CutProject {
    func mediaRefreshTargets(relativeTo location: URL) -> [URL: Bool] {
        var targets: [String: Bool] = [:]
        for use in ProjectMedia.references(in: self, includePlannedSpans: false) {
            targets[use.path] = (targets[use.path] ?? true) && use.kind == .still
        }
        return Dictionary(targets.map { path, presenceOnly in
            (ProjectMediaVolume.watchURL(path, relativeTo: location), presenceOnly)
        }, uniquingKeysWith: { $0 && $1 })
    }
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
            let canonical = ProjectMediaVolume.watchURL(input.url)
            let index: Int?
            if let identity { index = physical[identity] }
            else { index = offline[canonical] }
            if let index {
                groups[index].aliases.insert(input.url)
                let requiresIndex = groups[index].input.requiresIndex || input.requiresIndex
                let presenceOnly = groups[index].input.presenceOnly && input.presenceOnly
                if groups[index].input.previous == nil && input.previous != nil { groups[index].input = input }
                groups[index].input.presenceOnly = presenceOnly
                groups[index].input.requiresIndex = requiresIndex
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
               project: URL? = nil, exclusions: Set<URL>, receipt: MCPAnalysisReceipt?, previewSources: Set<URL> = [],
               preview: ((MediaInfo, Set<URL>) -> Void)? = nil, progress: @escaping (Double) -> Void,
               publish: @escaping (MediaRefreshResult, Set<URL>, MediaInfo?, SourceIdentity?) -> Void, finished: @escaping (String) -> Void) {
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
                    let (header, verified) = await Task.detached(priority: .userInitiated) {
                        let header = try? CutEngine(cancelled: { token.isCancelled }, useSidecar: false).inspectForPreview(first.url)
                        let verified = recording.aliases.intersection(previewSources).filter { identity.isCurrentSnapshot(at: $0) }
                        return (header, verified)
                    }.value
                    guard !token.isCancelled, self.token === token else { break }
                    if let header, header.identity.matchesSnapshot(identity), !verified.isEmpty {
                        preview(header, verified)
                    }
                }
                let interval = 1.0 / Double(unique.count)
                let task = ProjectSidecarWork(project: project).detached(priority: .utility) {
                    try AnalysisSidecar.$readsEnabled.withValue(persist) { () -> (MediaRefreshResult, MediaInfo?, SourceIdentity?) in
                        let result = try first.presenceOnly ? MediaRefresh.presence(of: first.url, identity: recording.identity)
                            : MediaRefresh.check(first.url, identity: recording.identity, previous: first.previous,
                                               verification: force ? .deep : .stamp, persist: persist,
                                               exclusions: exclusions, requiresIndex: first.requiresIndex, progress: { progressValue in
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
                        let expected = result.media?.identity ?? recording.identity
                        if recording.aliases.contains(where: { url in
                            if let expected { return !expected.isCurrentSnapshot(at: url) }
                            return (try? SourceIdentity(url)) != nil
                        }) {
                            throw CutError(code: "source_changed", message: "The recording changed again during refresh.")
                        }
                        return (result, aligned, expected)
                    }
                }
                do {
                    let (result, aligned, identity) = try await task.value
                    guard !token.isCancelled, self.token === token else { break }
                    publish(result, recording.aliases, aligned, identity)
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

/// Stamp probes are always enabled. File and ancestor descriptors are opt-in.
@MainActor
final class ProjectMediaWatcher {
    private struct ProbeResult: Sendable {
        let stamps: [URL: SourceIdentity]
        let descriptors: [URL: Int32]
    }

    /// A blocked system call cannot be cancelled. Share the permit across
    /// editors so opening another project cannot add a second call to the mount.
    private static var volumeOwners: [String: UUID] = [:]
    private(set) static var knownCheckingVolumes = Set<String>()
    private static var volumeWaiters: [String: [UUID: () -> Void]] = [:]
    private let waiter = UUID()
    private var waiting = Set<String>()

    private var files = Set<URL>()
    private var stamps: [URL: SourceIdentity] = [:]
    private var expected: [URL: SourceIdentity] = [:]
    private var assumedOffline = Set<URL>()
    private var checked = Set<URL>()
    private var checking = Set<String>()
    private var active: [String: UUID] = [:]
    private var pending = Set<String>()
    private var verify = Set<URL>()
    private var settling: [URL: SourceIdentity] = [:]
    private var retry = Set<URL>()
    private var perFile = false
    private var watches: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounce: DispatchWorkItem?
    private var scheduledVolumes = Set<String>()
    private var allVolumesScheduled = false
    private var notifications = Set<AnyCancellable>()
    private let timeout: Duration
    private let readStamp: @Sendable (URL) -> SourceIdentity?
    private let publish: (Set<URL>) -> Void
    private let refresh: (Set<URL>, Set<URL>) -> Bool

    init(timeout: Duration = .seconds(2),
         readStamp: @escaping @Sendable (URL) -> SourceIdentity? = { try? SourceIdentity($0) },
         publish: @escaping (Set<URL>) -> Void,
         refresh: @escaping (Set<URL>, Set<URL>) -> Bool) {
        self.timeout = timeout
        self.readStamp = readStamp
        self.publish = publish
        self.refresh = refresh
        let application = NotificationCenter.default
        ProjectMediaVolume.refreshMounts()
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(application, NSApplication.didBecomeActiveNotification),
                               (workspace, NSWorkspace.didMountNotification),
                               (workspace, NSWorkspace.didUnmountNotification)] {
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    ProjectMediaVolume.refreshMounts()
                    self?.schedule()
                }.store(in: &notifications)
        }
    }

    func status(for url: URL) -> ProjectMediaStatus? {
        let url = ProjectMediaVolume.watchURL(url)
        let volume = ProjectMediaVolume.key(for: url)
        if checking.contains(volume) || Self.knownCheckingVolumes.contains(volume) { return .checking }
        guard checked.contains(url) else { return nil }
        if settling[url] != nil || retry.contains(url) { return .changed }
        return stamps[url] == nil ? .offline : .online
    }

    var checkingVolumes: Set<String> { checking.union(Self.knownCheckingVolumes) }

    /// A completed manual or automatic refresh already rechecked these stamps on its worker.
    func noteVerified(_ urls: Set<URL>, identity: SourceIdentity?) {
        for url in urls.map(ProjectMediaVolume.watchURL) where files.contains(url) {
            checked.insert(url)
            stamps[url] = identity
            retry.remove(url)
            settling[url] = nil
        }
    }

    func update(_ urls: Set<URL>, expected: [URL: SourceIdentity] = [:],
                assumedOffline: Set<URL> = [], perFile: Bool) {
        let urls = Set(urls.map(ProjectMediaVolume.watchURL))
        let changed = urls.symmetricDifference(files)
        let modeChanged = self.perFile != perFile
        self.expected = expected
        self.assumedOffline = assumedOffline
        guard !changed.isEmpty || modeChanged else { return }
        self.perFile = perFile
        files = urls
        let volumes = Set(urls.map(ProjectMediaVolume.key(for:)))
        for volume in waiting.subtracting(volumes) { Self.volumeWaiters[volume]?[waiter] = nil }
        waiting.formIntersection(volumes)
        pending.formIntersection(volumes)
        checked.formIntersection(urls)
        stamps = stamps.filter { urls.contains($0.key) }
        verify.formIntersection(urls)
        retry.formIntersection(urls)
        settling = settling.filter { urls.contains($0.key) }
        if modeChanged || !changed.isEmpty {
            for source in watches.values { source.cancel() }
            watches.removeAll()
        }
        schedule()
    }

    private func schedule(volume: String? = nil) {
        guard !files.isEmpty else { return }
        if let volume { scheduledVolumes.insert(volume) }
        else { allVolumesScheduled = true }
        guard debounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounce = nil
            let volumes = self.allVolumesScheduled ? nil : self.scheduledVolumes
            self.scheduledVolumes.removeAll()
            self.allVolumesScheduled = false
            self.check(volumes)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: work)
    }

    func checkNow() { check(nil) }

    private func check(_ selectedVolumes: Set<String>?) {
        let groups = Dictionary(grouping: files, by: ProjectMediaVolume.key(for:))
        for (volume, urls) in groups where selectedVolumes?.contains(volume) != false {
            guard active[volume] == nil else {
                pending.insert(volume)
                continue
            }
            guard Self.volumeOwners[volume] == nil else {
                waitForVolume(volume)
                continue
            }
            let id = UUID()
            Self.volumeOwners[volume] = id
            active[volume] = id
            let perFile = self.perFile
            let stamp = readStamp
            let observed = Set(urls)
            let watchedPaths = Set(watches.keys)
            // Blocking mount calls belong on a dispatch worker, outside the
            // cooperative Swift executor and off the UI thread.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let stamps = Dictionary(uniqueKeysWithValues: observed.compactMap { url in stamp(url).map { (url, $0) } })
                let result = ProbeResult(stamps: stamps, descriptors: perFile ? Self.openWatches(observed, excluding: watchedPaths) : [:])
                DispatchQueue.main.async { [weak self] in
                    Self.releaseVolume(volume, owner: id)
                    guard let self else {
                        for fd in result.descriptors.values { close(fd) }
                        return
                    }
                    self.complete(result, observed: observed, volume: volume, id: id)
                }
            }
            Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                guard Self.volumeOwners[volume] == id else { return }
                Self.knownCheckingVolumes.insert(volume)
                self?.markChecking(volume)
            }
        }
    }

    private func waitForVolume(_ volume: String) {
        guard waiting.insert(volume).inserted else { return }
        Self.volumeWaiters[volume, default: [:]][waiter] = { [weak self] in
            guard let self else { return }
            self.waiting.remove(volume)
            self.schedule(volume: volume)
        }
        Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard let self, self.waiting.contains(volume) else { return }
            self.markChecking(volume)
        }
    }

    private static func releaseVolume(_ volume: String, owner: UUID) {
        guard volumeOwners[volume] == owner else { return }
        volumeOwners[volume] = nil
        knownCheckingVolumes.remove(volume)
        if let waiters = volumeWaiters.removeValue(forKey: volume) {
            for wake in waiters.values { wake() }
        }
    }

    private func markChecking(_ volume: String) {
        let affected = Set(files.filter { ProjectMediaVolume.key(for: $0) == volume })
        if !affected.isEmpty, checking.insert(volume).inserted { publish(affected) }
    }

    private func complete(_ result: ProbeResult, observed: Set<URL>, volume: String, id: UUID) {
        guard active[volume] == id else {
            for fd in result.descriptors.values { close(fd) }
            return
        }
        active[volume] = nil
        let wasChecking = checking.remove(volume) != nil
        let current = files.intersection(observed)
        var changed = Set<URL>()
        var reindex = Set<URL>()
        for url in current {
            let previous = stamps[url] ?? expected[url]
            let firstCheck = checked.insert(url).inserted
            let wasOffline = firstCheck ? assumedOffline.contains(url) : stamps[url] == nil
            let next = result.stamps[url]
            if wasChecking || (firstCheck && next == nil) { changed.insert(url) }
            if let next, (previous.map { !next.matchesSnapshot($0) } ?? false) || wasOffline || verify.contains(url) || retry.contains(url) {
                if let candidate = settling[url], candidate.matchesSnapshot(next) {
                    reindex.insert(url)
                } else {
                    if settling[url] == nil { changed.insert(url) }
                    settling[url] = next
                    schedule(volume: volume)
                }
            } else {
                if settling.removeValue(forKey: url) != nil || (!firstCheck && ((stamps[url] == nil) != (next == nil))) {
                    changed.insert(url)
                }
                if next == nil {
                    retry.remove(url)
                    verify.remove(url)
                }
                stamps[url] = next
            }
        }
        for (url, fd) in result.descriptors {
            if perFile, current == observed, watches[url] == nil { installWatch(url, fd: fd) }
            else { close(fd) }
        }
        if !changed.isEmpty { publish(changed) }
        let force = verify.intersection(reindex)
        if !reindex.isEmpty {
            if refresh(reindex, force) {
                verify.subtract(force)
                retry.subtract(reindex)
                for url in reindex {
                    settling[url] = nil
                    stamps[url] = result.stamps[url]
                }
                publish(reindex)
            } else {
                retry.formUnion(reindex)
                schedule(volume: volume)
            }
        }
        if pending.remove(volume) != nil { schedule(volume: volume) }
    }

    private nonisolated static func openWatches(_ files: Set<URL>, excluding watched: Set<URL>) -> [URL: Int32] {
        var paths = files
        for file in files {
            var parent = file.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                parent.deleteLastPathComponent()
            }
            paths.insert(parent)
        }
        return Dictionary(uniqueKeysWithValues: paths.subtracting(watched).compactMap { url in
            let fd = open(url.path, O_EVTONLY)
            return fd >= 0 ? (url, fd) : nil
        })
    }

    private func installWatch(_ url: URL, fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                          eventMask: [.write, .extend, .rename, .delete, .revoke], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, let data = self.watches[url]?.data else { return }
            if !data.intersection([.delete, .revoke, .rename]).isEmpty {
                self.watches.removeValue(forKey: url)?.cancel()
            }
            if self.files.contains(url), !data.intersection([.write, .extend]).isEmpty {
                self.verify.insert(url)
            }
            self.schedule(volume: self.files.contains(url) ? ProjectMediaVolume.key(for: url) : nil)
        }
        watches[url] = source
        source.resume()
    }

    func stop() {
        notifications.removeAll()
        debounce?.cancel()
        debounce = nil
        scheduledVolumes.removeAll()
        allVolumesScheduled = false
        files.removeAll()
        active.removeAll()
        expected.removeAll()
        assumedOffline.removeAll()
        checked.removeAll()
        stamps.removeAll()
        checking.removeAll()
        for volume in waiting { Self.volumeWaiters[volume]?[waiter] = nil }
        waiting.removeAll()
        pending.removeAll()
        verify.removeAll()
        retry.removeAll()
        settling.removeAll()
        perFile = false
        for source in watches.values { source.cancel() }
        watches.removeAll()
    }

    deinit {
        debounce?.cancel()
        for source in watches.values { source.cancel() }
    }
}
