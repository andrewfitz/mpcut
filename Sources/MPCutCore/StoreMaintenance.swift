import Darwin
import Foundation

/// Measures and clears MPCut's own caches under a folder the caller names.
public struct StoreClearResult: Sendable, Equatable {
    public struct Skip: Sendable, Equatable {
        public let url: URL
        public let reason: String
    }

    public var reclaimedBytes: Int64 = 0
    public var removed: [URL] = []
    public var skipped: [Skip] = []

    public init() {}
}

public enum StoreMeasurement {
    /// Allocated bytes of the regular files under `root`, without following symbolic links.
    /// A missing root measures zero. Top-level entries named in `excluding` are left out.
    /// Throws `CancellationError` when `cancelled` returns true or the task is cancelled.
    public static func allocatedBytes(at root: URL, excluding names: Set<String> = [],
                                      cancelled: () -> Bool = { false }) throws -> Int64 {
        var info = stat()
        guard lstat(root.path, &info) == 0 else { return 0 }
        if info.st_mode & S_IFMT == S_IFREG { return Int64(info.st_blocks) * 512 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return 0 }
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            if cancelled() || Task.isCancelled { throw CancellationError() }
            if walk.level == 1, names.contains(url.lastPathComponent) {
                walk.skipDescendants()
                continue
            }
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                total += Int64(info.st_blocks) * 512
            }
        }
        return total
    }

    static func lowercaseHex(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The descriptor still names `path`, so nothing replaced it after it was opened.
    static func names(_ path: String, _ descriptor: Int32) -> Bool {
        var held = stat(), named = stat()
        return fstat(descriptor, &held) == 0 && lstat(path, &named) == 0
            && held.st_ino == named.st_ino && held.st_dev == named.st_dev
    }
}

/// The still segment cache: `<directory>/<shard>/<sha256>-<ext>/`, one flock per shard.
public enum GeneratedStillsStore {
    /// Matches `StillSegmentCache.shared`.
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MPCut/GeneratedStills-v1", isDirectory: true)
    }

    /// Removes cached segments shard by shard. A shard that a render holds is skipped whole.
    /// Only entries named like the cache's own are removed; the shard folders stay.
    public static func clear(in directory: URL) -> StoreClearResult {
        var result = StoreClearResult()
        guard let shards = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return result }
        for shard in shards.sorted() {
            guard let index = Int(shard), String(index) == shard, (0..<256).contains(index) else { continue }
            let folder = directory.appendingPathComponent(shard, isDirectory: true)
            let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                result.skipped.append(.init(url: folder, reason: "A still is being rendered or used."))
                continue
            }
            guard StoreMeasurement.names(folder.path, descriptor),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() {
                let fields = name.split(separator: "-", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0].utf8.count == 64, StoreMeasurement.lowercaseHex(fields[0]),
                      (1...8).contains(fields[1].utf8.count),
                      fields[1].utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else { continue }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                let entry = folder.appendingPathComponent(name, isDirectory: true)
                let bytes = (try? StoreMeasurement.allocatedBytes(at: entry)) ?? 0
                do {
                    try FileManager.default.removeItem(at: entry)
                    result.reclaimedBytes += bytes
                    result.removed.append(entry)
                } catch {
                    result.skipped.append(.init(url: entry, reason: error.localizedDescription))
                }
            }
        }
        return result
    }
}

/// Recognition results shared by the app, the CLI and a standalone Transcriberrr. Each claim is
/// a lock file named by its ID beside its published exchange files; `Results/<key>/` archives
/// every generation by recognition key.
public enum TranscriptRecognitionStore {
    public static func defaultDirectory() throws -> URL { try TranscriptRecognitionClaims.directory() }

    /// Removes every claim whose lock is free, with its exchange files, taking each lock as a
    /// running job does. A claim held by a job is skipped. The archive goes only when no claim was
    /// held, since an archive folder cannot be traced to the claims that write it. A job that
    /// starts after the claims were read can still find its archive folder gone; it then keeps
    /// its result in the job folder.
    public static func clear(in directory: URL) -> StoreClearResult {
        var result = StoreClearResult()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return result }
        let versions = [TranscriptRecognitionExchange.fileExtension, TranscriptRecognitionExchange.legacyExtension]
        var claims = Set<String>()
        for name in names {
            if TranscriptStore.validDigest(name) { claims.insert(name); continue }
            let stem = (name as NSString).deletingPathExtension
            if versions.contains((name as NSString).pathExtension), TranscriptStore.validDigest(stem) {
                claims.insert(stem)
            }
        }
        var busy = false
        for claim in claims.sorted() {
            let lock = directory.appendingPathComponent(claim)
            // An exchange without a lock file is claimed the way a job claims it.
            let descriptor = open(lock.path, O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o600)
            guard descriptor >= 0 else {
                result.skipped.append(.init(url: lock, reason: String(cString: strerror(errno))))
                continue
            }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                busy = true
                result.skipped.append(.init(url: lock, reason: "A transcription is using this result."))
                continue
            }
            guard StoreMeasurement.names(lock.path, descriptor) else {
                busy = true
                result.skipped.append(.init(url: lock, reason: "The claim changed while it was being cleared."))
                continue
            }
            var complete = true
            for version in versions {
                let file = lock.appendingPathExtension(version)
                var info = stat()
                guard lstat(file.path, &info) == 0 else { continue }
                guard info.st_mode & S_IFMT == S_IFREG, unlink(file.path) == 0 else {
                    complete = false
                    result.skipped.append(.init(url: file, reason: "Not a recognition result."))
                    continue
                }
                result.reclaimedBytes += Int64(info.st_blocks) * 512
                result.removed.append(file)
            }
            // Pruning removes idle lock files under the same lock. A waiting job sees the
            // name no longer matches its descriptor and claims again.
            if complete { unlink(lock.path) }
        }
        let archive = directory.appendingPathComponent("Results", isDirectory: true)
        var info = stat()
        guard lstat(archive.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return result }
        guard !busy else {
            result.skipped.append(.init(url: archive, reason: "Kept while a transcription holds a shared result."))
            return result
        }
        for key in ((try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []).sorted()
            where TranscriptStore.validDigest(key) {
            let folder = archive.appendingPathComponent(key, isDirectory: true)
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let bytes = (try? StoreMeasurement.allocatedBytes(at: folder)) ?? 0
            do {
                try FileManager.default.removeItem(at: folder)
                result.reclaimedBytes += bytes
                result.removed.append(folder)
            } catch {
                result.skipped.append(.init(url: folder, reason: error.localizedDescription))
            }
        }
        return result
    }
}
