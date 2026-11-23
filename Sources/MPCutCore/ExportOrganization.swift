import Darwin
import Foundation

/// Optional names applied to a batch beneath its chosen destination.
public struct ExportOrganization: Sendable, Equatable {
    public var subfolder: String
    public var baseName: String

    public init(subfolder: String = "", baseName: String = "") {
        self.subfolder = subfolder
        self.baseName = baseName
    }

    public func filename(stem: String, suffix: String, container: String) -> String {
        let name = "\(baseName.isEmpty ? stem : baseName)-\(suffix)"
        return container.isEmpty ? name : "\(name).\(container)"
    }

    package func destination(in directory: URL, stem: String, suffix: String, container: String) throws -> URL {
        let name = filename(stem: stem, suffix: suffix, container: container)
        guard !name.contains("/"), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CutError(code: "invalid_output", message: "An export filename must be a single name without path separators or control characters.")
        }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    public func validate() throws {
        for (label, value) in [("Subfolder", subfolder), ("Base name", baseName)] where !value.isEmpty {
            guard value != ".", value != "..", !value.trimmingCharacters(in: .whitespaces).isEmpty,
                  value.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)) == nil else {
                throw CutError(code: "invalid_output", message: "\(label) must be a single name without path separators or control characters.")
            }
        }
    }

    package func validateSubfolder(in root: URL, protectedMedia: [String: String]) throws {
        guard !subfolder.isEmpty else { return }
        let child = try directory(in: root, create: false)
        try CutProject.validateMediaDestination(child, absoluteSources: protectedMedia)
    }

    /// Validate the chosen root and check the child without following a child symlink.
    package func directory(in root: URL, create: Bool) throws -> URL {
        try validate()
        guard root.isFileURL else {
            throw CutError(code: "invalid_output", message: "Choose a local export folder.")
        }
        guard !subfolder.isEmpty else { return root }
        let child = root.appendingPathComponent(subfolder, isDirectory: true)
        let path = child.path
        if create && mkdir(path, 0o777) != 0 && errno != EEXIST {
            throw CutError(code: "invalid_output", message: "Cannot create export subfolder at \(path).")
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, access(path, W_OK | X_OK) == 0 else {
                throw CutError(code: "invalid_output", message: "Choose a writable export subfolder at \(path).")
            }
        } else {
            guard !create, errno == ENOENT, stat(root.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR, access(root.path, W_OK | X_OK) == 0 else {
                throw CutError(code: "invalid_output", message: "The export folder is unavailable.")
            }
        }
        return child
    }
}
