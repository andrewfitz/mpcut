import CryptoKit
import Darwin
import Foundation

/// Identifies the exact archive bytes read by an editor, including discarded or
/// unmaterialized history. The path lets Save As distinguish a separate file.
package struct ProjectDiskRevision: Equatable, Sendable {
    private let openedPath: URL
    private let destination: URL
    private let digest: SHA256.Digest

    fileprivate init(url: URL, destination: URL, bytes: Data) {
        openedPath = url.absoluteURL
        self.destination = destination
        digest = SHA256.hash(data: bytes)
    }

    package func matchesDestination(_ url: URL) -> Bool {
        openedPath == url.absoluteURL || Self.sameDestination(destination, Self.saveDestination(url))
    }

    package func checkCurrent(at url: URL) throws {
        let target = Self.saveDestination(url)
        var current = stat()
        guard let verified = verifiedFile(at: target),
              lstat(target.path, &current) == 0, Self.sameFile(verified, current),
              Self.sameDestination(target, Self.saveDestination(url)) else {
            throw CutError(code: "project_save_conflict", message: "The project at \(url.path) changed. Reopen it before editing media.")
        }
    }

    fileprivate func verifiedFile(at destination: URL) -> stat? {
        guard Self.sameDestination(self.destination, destination) else { return nil }
        let descriptor = open(destination.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let limit = MulticamProject.maximumFileSize
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= limit else { return nil }

        // Only the digest is needed here. Keep the old archive out of memory while
        // the new archive is waiting to be published.
        var hash = SHA256()
        var remaining = limit
        let bufferSize = min(1 << 20, max(4 << 10, Int(info.st_size) + 1))
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let matches = buffer.withUnsafeMutableBytes { bytes in
            while true {
                let count = read(descriptor, bytes.baseAddress, min(bytes.count, remaining + 1))
                if count == 0 { return hash.finalize() == digest }
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count <= remaining else { return false }
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                remaining -= count
            }
        }
        var afterward = stat()
        guard matches, fstat(descriptor, &afterward) == 0, Self.sameFile(info, afterward) else { return nil }
        return afterward
    }

    fileprivate static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    fileprivate static func sameDestination(_ first: URL, _ second: URL) -> Bool {
        if first == second { return true }
        let directory = first.deletingLastPathComponent()
        return directory == second.deletingLastPathComponent()
            && first.lastPathComponent.caseInsensitiveCompare(second.lastPathComponent) == .orderedSame
            && (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames == false
    }

    // Keep the writer's target semantics and resolve directory aliases as well.
    fileprivate static func saveDestination(_ url: URL) -> URL {
        if let physical = realpath(url.path, nil) {
            defer { free(physical) }
            return URL(fileURLWithPath: String(cString: physical))
        }
        // Resolve aliases before walking a parent component. Lexically
        // standardizing a path like "shortcut/../edit.cut" can choose another file.
        let target = ProjectFile.documentURL(url).absoluteURL
        let directory = target.deletingLastPathComponent()
        if let physical = realpath(directory.path, nil) {
            defer { free(physical) }
            return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                .appendingPathComponent(target.lastPathComponent)
        }
        return target
    }
}

extension ProjectFile {
    static func readSnapshot<T: Decodable>(_ type: T.Type, from url: URL, multicam: Bool = false)
        throws -> (T, ProjectDiskRevision) {
        let destination = ProjectDiskRevision.saveDestination(url)
        let bytes = try readBytes(from: destination, multicam: multicam)
        let document = try decode(type, data: bytes, multicam: multicam)
        return (document, ProjectDiskRevision(url: url, destination: destination, bytes: bytes))
    }

    static func coordinatedWrite(to url: URL, prefix: String, expected: ProjectDiskRevision?,
                                 publish: (URL, () throws -> Void) throws -> Data) throws -> ProjectDiskRevision {
        let destination = ProjectDiskRevision.saveDestination(url)
        // A file lease would follow the inode replaced by atomic publication.
        // Lock the containing directory so all writers coordinate across renames.
        let descriptor = open(destination.deletingLastPathComponent().path, O_SEARCH | O_CLOEXEC)
        guard descriptor >= 0 else { throw writeError(errno) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw writeError(errno) }
        }
        guard ProjectDiskRevision.sameDestination(destination, ProjectDiskRevision.saveDestination(url)) else {
            throw conflict()
        }
        let verified = expected?.verifiedFile(at: destination)
        if expected != nil, verified == nil {
            throw conflict()
        }
        let data = try publish(destination, verifyDestination)
        return ProjectDiskRevision(url: url, destination: destination, bytes: data)

        func verifyDestination() throws {
            guard ProjectDiskRevision.sameDestination(destination, ProjectDiskRevision.saveDestination(url)) else {
                throw conflict()
            }
            if let verified {
                var current = stat()
                guard lstat(destination.path, &current) == 0, ProjectDiskRevision.sameFile(verified, current) else {
                    throw conflict()
                }
            }
        }

        func conflict() -> CutError {
            CutError(code: "project_save_conflict",
                     message: "The project at \(url.path) changed since it was opened. Save a copy to keep your edits, or reopen the project.")
        }

        func writeError(_ code: Int32) -> CutError {
            CutError(code: "\(prefix)_project_write_failed",
                     message: "Could not coordinate the save at \(url.path): \(String(cString: strerror(code)))")
        }
    }
}
