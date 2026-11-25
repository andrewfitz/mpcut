import Darwin
import Foundation

/// Moves untitled drafts older than the retention limit to the Trash.
enum DraftRetention {
    struct Outcome: Equatable {
        var trashed: [URL] = []
        var skipped: [URL: String] = [:]
    }

    static let openReason = "Open in MPCut."
    static let lockedReason = "In use by MPCut."
    static let recentReason = "Newer than the limit."

    /// `days` of zero or less does nothing. `open` holds the drafts the app has open, as their
    /// `Untitled.cut` files or their folders. Only a UUID-named folder holding a regular
    /// `Untitled.cut` is a draft; hidden entries such as `.transcript-jobs` are never touched.
    /// A draft's age is its newest `Untitled.cut` or `.pending-*.cut` file. Each draft stays
    /// locked, as `ProjectDraft` locks it, until it is in the Trash.
    static func run(days: Int, open: Set<URL>, directory: URL = ProjectDraft.autosaveDirectory,
                    now: Date = Date(),
                    trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Outcome {
        var outcome = Outcome()
        guard days > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return outcome }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let opened = Set(open.map { url -> String in
            let folder = url.lastPathComponent == "Untitled.cut" ? url.deletingLastPathComponent() : url
            return folder.resolvingSymlinksInPath().standardizedFileURL.path
        })
        for name in names.sorted() where !name.hasPrefix(".") && UUID(uuidString: name) != nil {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            if opened.contains(folder.resolvingSymlinksInPath().standardizedFileURL.path) {
                outcome.skipped[folder] = openReason
                continue
            }
            let descriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                outcome.skipped[folder] = lockedReason
                continue
            }
            var held = stat(), named = stat(), document = stat()
            guard fstat(descriptor, &held) == 0, lstat(folder.path, &named) == 0,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                  fstatat(descriptor, "Untitled.cut", &document, AT_SYMLINK_NOFOLLOW) == 0,
                  document.st_mode & S_IFMT == S_IFREG else { continue }
            var newest = document.st_mtimespec
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                where file.hasPrefix(".pending-") && file.hasSuffix(".cut") {
                var staged = stat()
                if fstatat(descriptor, file, &staged, AT_SYMLINK_NOFOLLOW) == 0,
                   (staged.st_mtimespec.tv_sec, staged.st_mtimespec.tv_nsec) > (newest.tv_sec, newest.tv_nsec) {
                    newest = staged.st_mtimespec
                }
            }
            let edited = Date(timeIntervalSince1970: Double(newest.tv_sec) + Double(newest.tv_nsec) / 1e9)
            guard edited < cutoff else {
                outcome.skipped[folder] = recentReason
                continue
            }
            do {
                try trash(folder)
                outcome.trashed.append(folder)
            } catch {
                outcome.skipped[folder] = error.localizedDescription
            }
        }
        return outcome
    }
}
