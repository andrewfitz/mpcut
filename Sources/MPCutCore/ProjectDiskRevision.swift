import CryptoKit
import Darwin
import Foundation

/// Identifies the exact archive bytes read by an editor, including discarded or
/// unmaterialized history. The path lets Save As distinguish a separate file.
package struct ProjectDiskRevision: Sendable {
    private let openedPath: URL
    private let destination: URL
    private let digest: SHA256.Digest

    fileprivate init(url: URL, destination: URL, bytes: Data) {
        openedPath = url.standardizedFileURL
        self.destination = destination
        digest = SHA256.hash(data: bytes)
    }

    package func matchesDestination(_ url: URL) -> Bool {
        openedPath == url.standardizedFileURL || Self.sameDestination(destination, Self.saveDestination(url))
    }

    fileprivate func matches(_ bytes: Data, at destination: URL) -> Bool {
        Self.sameDestination(self.destination, destination) && digest == SHA256.hash(data: bytes)
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
        let target = ProjectFile.documentURL(url).standardizedFileURL
        if let physical = realpath(target.path, nil) {
            defer { free(physical) }
            return URL(fileURLWithPath: String(cString: physical))
        }
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

    static func coordinatedWrite(to url: URL, prefix: String, expected: ProjectDiskRevision?, data: Data,
                                 publish: (URL) throws -> Void) throws -> ProjectDiskRevision {
        let destination = ProjectDiskRevision.saveDestination(url)
        // A file lease would follow the inode replaced by atomic publication.
        // Lock the containing directory so all writers coordinate across renames.
        let descriptor = open(destination.deletingLastPathComponent().path, O_SEARCH | O_CLOEXEC)
        guard descriptor >= 0 else { throw writeError(errno) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw writeError(errno) }
        }
        if let expected {
            guard ProjectDiskRevision.sameDestination(destination, ProjectDiskRevision.saveDestination(url)),
                  let bytes = try? readBytes(from: destination, multicam: prefix == "multicam"),
                  expected.matches(bytes, at: destination) else {
                throw CutError(code: "project_save_conflict",
                               message: "The project at \(url.path) changed since it was opened. Save a copy to keep your edits, or reopen the project.")
            }
        }
        try publish(destination)
        return ProjectDiskRevision(url: url, destination: destination, bytes: data)

        func writeError(_ code: Int32) -> CutError {
            CutError(code: "\(prefix)_project_write_failed",
                     message: "Could not coordinate the save at \(url.path): \(String(cString: strerror(code)))")
        }
    }
}
