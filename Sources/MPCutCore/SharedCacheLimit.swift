import Darwin
import Foundation

/// Keeps the managed `MPCut Cache` folder of cache-disk mode under a byte limit by removing
/// the least recently written cutcaches through `SidecarCacheCleaner`.
package enum SharedCacheLimit {
    package struct Outcome: Sendable {
        package var bytesBefore: Int64 = 0
        package var bytesAfter: Int64 = 0
        package var reclaimedBytes: Int64 = 0
        package var removed: [URL] = []
        /// Recordings whose cutcache was removed, for `sidecarCachesDidClear`.
        package var removedSources: Set<URL> = []
        package var skipped: [URL: String] = [:]
        /// The run stopped before a removal because `recheck` answered nil, for example while a project opens.
        package var aborted = false

        package init() {}
    }

    /// Asked before each removal. Returns the protected set as it is now, or nil to stop the run.
    package typealias Recheck = @Sendable () -> Set<URL>?

    /// The selected shared cache folder while disk mode is on and the folder is reachable.
    package static var configuredRoot: URL? {
        let settings = SidecarLocations.settingsSnapshot()
        guard settings.mode == .disk, settings.available else { return nil }
        return settings.disk
    }

    /// `root` is the shared cache folder the user chose; its managed `MPCut Cache` child is the only folder read.
    /// The chosen folder may itself be named `MPCut Cache`. A limit of zero or less does nothing. `protected`
    /// holds media, project and cutcache URLs; a cutcache whose own path or recording is protected is never
    /// removed. `recheck` runs before each removal and replaces `protected` with its answer, so a project
    /// opened during the run keeps its cutcaches; nil stops the run. Last use is the cutcache's modification
    /// date, which every analysis save updates; opening a cache for reading does not.
    package static func enforce(limit: Int64, protected: Set<URL>, root: URL? = configuredRoot,
                                recheck: Recheck? = nil, cancelled: () -> Bool = { false }) -> Outcome {
        var outcome = Outcome()
        guard limit > 0, let root else { return outcome }
        let folder = AnalysisSidecar.canonicalSource(root.appendingPathComponent("MPCut Cache", isDirectory: true))
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let total = try? StoreMeasurement.allocatedBytes(at: folder, cancelled: cancelled) else { return outcome }
        outcome.bytesBefore = total
        outcome.bytesAfter = total
        guard total > limit else { return outcome }

        let candidates = layoutCaches(in: folder)
        guard !candidates.isEmpty, !cancelled() else { return outcome }
        var current = protected
        var forbidden = Set(protected.map { AnalysisSidecar.canonicalSource($0).path })
        // Scan only the managed folder. The chosen folder can be a whole disk.
        let entries = SidecarCacheCleaner.preview(scanning: [folder], protected: protected, scannedOnly: true)
        var verified: [String: SidecarCacheEntry] = [:]
        for entry in entries where entry.location == .disk {
            let path = AnalysisSidecar.canonicalSource(entry.url).path
            if verified[path] == nil { verified[path] = entry }
        }

        var remaining = total
        for candidate in candidates {
            guard remaining > limit, !cancelled() else { break }
            guard let entry = verified[candidate.url.path] else {
                outcome.skipped[candidate.url] = "MPCut could not confirm this cache belongs to the shared folder."
                continue
            }
            func isProtected() -> Bool {
                forbidden.contains(candidate.url.path) || forbidden.contains(AnalysisSidecar.canonicalSource(entry.source).path)
            }
            if isProtected() {
                outcome.skipped[candidate.url] = "An open project uses this cache."
                continue
            }
            if let issue = entry.issue {
                outcome.skipped[candidate.url] = issue
                continue
            }
            // A project can open while the folder is being measured. Ask again just before removing anything.
            if let recheck {
                guard let fresh = recheck() else {
                    outcome.aborted = true
                    break
                }
                if fresh != current {
                    current = fresh
                    forbidden = Set(fresh.map { AnalysisSidecar.canonicalSource($0).path })
                }
                if isProtected() {
                    outcome.skipped[candidate.url] = "An open project uses this cache."
                    continue
                }
            }
            let cleared = SidecarCacheCleaner.clear([entry], protected: current)
            if let reason = cleared.skippedEntries.first?.reason {
                outcome.skipped[candidate.url] = reason
                continue
            }
            remaining -= cleared.reclaimedBytes
            outcome.reclaimedBytes += cleared.reclaimedBytes
            outcome.removed += cleared.cleared
            outcome.removedSources.formUnion(cleared.clearedSources)
        }
        outcome.bytesAfter = (try? StoreMeasurement.allocatedBytes(at: folder)) ?? remaining
        return outcome
    }

    /// `<folder>/<2 hex>/<64 hex, starting with the shard>.cutcache` regular files, oldest first.
    private static func layoutCaches(in folder: URL) -> [(url: URL, written: timespec)] {
        var result: [(url: URL, written: timespec)] = []
        for shard in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            where shard.utf8.count == 2 && StoreMeasurement.lowercaseHex(Substring(shard)) {
            let directory = folder.appendingPathComponent(shard, isDirectory: true)
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix("." + AnalysisSidecar.fileExtension) {
                let key = name.dropLast(1 + AnalysisSidecar.fileExtension.count)
                let url = directory.appendingPathComponent(name)
                guard key.utf8.count == 64, key.hasPrefix(shard), StoreMeasurement.lowercaseHex(key),
                      lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                result.append((url, info.st_mtimespec))
            }
        }
        return result.sorted {
            ($0.written.tv_sec, $0.written.tv_nsec, $0.url.path) < ($1.written.tv_sec, $1.written.tv_nsec, $1.url.path)
        }
    }
}
