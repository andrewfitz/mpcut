import CryptoKit
import Darwin
import Foundation
import SQLite3

package enum SidecarStorageMode: String, Codable, CaseIterable, Sendable {
    case media, project, disk
}

/// Keep the mount and directory identities. An unrelated disk or directory mounted at
/// a familiar pathname is never a replacement for a folder the user selected.
private struct SidecarRoot: Codable, Hashable, Sendable {
    let path: String
    let volume: String
    let inode: UInt64
    var diskMarker: String?

    init?(_ url: URL) {
        guard url.isFileURL else { return nil }
        let directory = AnalysisSidecar.canonicalSource(url)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        path = directory.path
        inode = info.st_ino
        volume = Self.volumeIdentifier(fd: fd, info: info)
        diskMarker = nil
    }

    private static func volumeIdentifier(fd: Int32, info: stat) -> String {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_UUID) | ATTR_VOL_INFO
        // Darwin returns the record length followed by the requested 16-byte UUID.
        var payload: (UInt32, uuid_t) = (0, (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        if fgetattrlist(fd, &request, &payload, MemoryLayout.size(ofValue: payload), 0) == 0,
           payload.0 == MemoryLayout.size(ofValue: payload) {
            let uuid = UUID(uuid: payload.1).uuidString
            if uuid != "00000000-0000-0000-0000-000000000000" { return uuid }
        }
        return "device-\(info.st_dev)"
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    private func openVerified() throws -> (fd: Int32, info: stat) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw sidecarError("The cache folder is unavailable.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_ino == inode else {
            close(fd)
            throw sidecarError("The selected cache directory was replaced.")
        }
        let match: Bool
        if let diskMarker { match = (try? Self.marker(in: fd, creating: false)) == diskMarker }
        else { match = Self.volumeIdentifier(fd: fd, info: info) == volume }
        guard match else {
            close(fd)
            throw sidecarError("The selected cache folder or its disk was replaced.")
        }
        return (fd, info)
    }

    // Some removable/network filesystems have no stable volume UUID. At explicit
    // selection time bind them to a random token inside the chosen directory.
    func selectedDisk() throws -> SidecarRoot {
        guard volume.hasPrefix("device-") else { return self }
        let (directory, _) = try openVerified()
        defer { close(directory) }
        var selected = self
        selected.diskMarker = try Self.marker(in: directory, creating: true)
        return selected
    }

    private static func marker(in directory: Int32, creating: Bool) throws -> String {
        let name = ".mpcut-cache-disk-id"
        if creating {
            while flock(directory, LOCK_EX) != 0 {
                if errno != EINTR { throw sidecarError("Could not lock the selected cache folder.") }
            }
            let new = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if new >= 0 {
                defer { close(new) }
                let token = UUID().uuidString
                guard token.withCString({ Darwin.write(new, $0, 36) }) == 36, fsync(new) == 0 else {
                    _ = unlinkat(directory, name, 0)
                    throw sidecarError("Could not save the selected cache disk identity.")
                }
                return token
            }
            guard errno == EEXIST else { throw sidecarError("Could not identify the selected cache disk.") }
        }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw sidecarError("The cache disk identity is missing.") }
        defer { close(fd) }
        var info = stat(), bytes = [UInt8](repeating: 0, count: 36)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == 36,
              Darwin.read(fd, &bytes, 36) == 36, let token = UUID(uuidString: String(decoding: bytes, as: UTF8.self)) else {
            throw sidecarError("The cache disk identity is invalid.")
        }
        return token.uuidString
    }

    var available: Bool {
        guard let (fd, _) = try? openVerified() else { return false }
        close(fd)
        return true
    }

    func directory(for key: String, creating: Bool) throws -> URL {
        var directory = url
        let verified = try openVerified()
        var fd = verified.fd
        defer { close(fd) }
        let rootInfo = verified.info
        for component in ["MPCut Cache", String(key.prefix(2))] {
            directory.appendPathComponent(component, isDirectory: true)
            // Resolve each child against its already-open parent. A replaced ancestor
            // cannot redirect directory creation to a symlink or a different volume.
            var child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT {
                if !creating {
                    if component == "MPCut Cache" { directory.appendPathComponent(String(key.prefix(2)), isDirectory: true) }
                    return directory
                }
                guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
                    throw sidecarError("Could not create the managed cache directory at \(directory.path).")
                }
                child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { throw sidecarError("The managed cache directory is occupied or inaccessible.") }
            var childInfo = stat()
            guard fstat(child, &childInfo) == 0, childInfo.st_dev == rootInfo.st_dev else {
                close(child)
                throw sidecarError("The managed cache directory is on a different disk.")
            }
            close(fd)
            fd = child
        }
        return directory
    }
}

package struct SidecarCatalogEntry: Hashable, Codable, Sendable {
    package let source: URL
    package let url: URL
    package let mode: SidecarStorageMode
    fileprivate let root: SidecarRoot
    fileprivate let key: String?
    package var lookupKey: String? { key }
    package var rootURL: URL { root.url }
    var catalogPath: String {
        mode == .media ? root.url.appendingPathComponent(url.lastPathComponent).path : url.path
    }
    package var rootIdentity: String { "\(root.diskMarker ?? root.volume)/\(root.inode)" }

    package static func adjacent(source: URL) -> Self? {
        guard source.isFileURL, let root = SidecarRoot(source.deletingLastPathComponent()) else { return nil }
        let file = source.standardizedFileURL
        return Self(source: file, url: file.appendingPathExtension(AnalysisSidecar.fileExtension), mode: .media, root: root, key: nil)
    }
}

package struct SidecarLocations: Sendable {
    @TaskLocal package static var projectURL: URL?
    @TaskLocal package static var projectsBySource: [URL: URL] = [:]
    @TaskLocal package static var storageDirectory: URL?

    private struct Configuration: Codable {
        var mode: SidecarStorageMode = .media
        var disk: SidecarRoot?
        var unreadable = false
        private enum CodingKeys: String, CodingKey { case mode, disk }
    }

    /// Production GUI, CLI and MCP share this directory. Test suites can isolate both
    /// the preferences and catalog without changing the user's defaults domain.
    package static var home: URL { storageDirectory ?? defaultHome }

    package static var configurationRevision: SourceIdentity? { try? SourceIdentity(home.appendingPathComponent("config.json")) }

    private static let defaultHome: URL = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["MPCUT_SIDECAR_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let socket = env["MPCUT_TEST_SOCKET_DIRECTORY"], !socket.isEmpty {
            let folder = "mpcut-test-sidecars-" + digest(socket)
            return FileManager.default.temporaryDirectory.appendingPathComponent(folder, isDirectory: true)
        }
        if NSClassFromString("XCTestCase") != nil || CommandLine.arguments[0].contains("xctest") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-test-sidecars-" + UUID().uuidString)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MPCut/Sidecars", isDirectory: true)
    }()

    private static func configuration(in home: URL) -> Configuration {
        let file = home.appendingPathComponent("config.json")
        var info = stat()
        if lstat(file.path, &info) != 0 {
            return Configuration(unreadable: errno != ENOENT)
        }
        guard info.st_mode & S_IFMT == S_IFREG, (1...65_536).contains(info.st_size),
              let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return Configuration(unreadable: true)
        }
        return config
    }

    private static func updateConfiguration(_ update: (inout Configuration) throws -> Void) throws {
        let directory = home
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw sidecarError("Cannot open the sidecar settings directory.") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw sidecarError("Cannot lock the sidecar settings directory.") }
        }
        var config = configuration(in: directory)
        try update(&config)
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("config.json"), options: .atomic)
    }

    package static var mode: SidecarStorageMode {
        get { configuration(in: home).mode }
        set { try? setMode(newValue) }
    }

    package static func setMode(_ mode: SidecarStorageMode) throws {
        try updateConfiguration { $0.mode = mode }
    }

    package static func configureStorage(_ mode: SidecarStorageMode, folder: URL?) throws {
        if let folder {
            guard mode == .disk else { throw sidecarError("A shared cache folder requires disk mode.") }
            try chooseDisk(folder, selecting: true)
        } else {
            try updateConfiguration { config in
                guard mode != .disk || config.disk != nil else {
                    throw sidecarError("Select a shared cache folder when enabling disk mode.")
                }
                config.mode = mode
            }
        }
    }

    package static func settingsSnapshot() -> (mode: SidecarStorageMode, disk: URL?, available: Bool) {
        let config = configuration(in: home)
        return (config.mode, config.disk?.url, config.disk?.available == true)
    }

    package static var diskURL: URL? { configuration(in: home).disk?.url }
    package static var diskAvailable: Bool { configuration(in: home).disk?.available == true }

    package static func chooseDisk(_ directory: URL, selecting: Bool = false) throws {
        guard let root = SidecarRoot(directory), FileManager.default.isWritableFile(atPath: root.path) else {
            throw sidecarError("Select a writable directory on an available cache disk.")
        }
        let disk = try root.selectedDisk()
        try updateConfiguration { config in
            config.disk = disk
            if selecting { config.mode = .disk }
        }
    }

    private let source: URL
    private let canonical: URL
    private let projectRoot: SidecarRoot?
    private let projectKey: String?
    private let diskKey: String?
    private let preferences: Configuration
    let catalogHome: URL

    package init(source: URL, project: URL? = SidecarLocations.projectURL) {
        self.source = source.standardizedFileURL
        canonical = AnalysisSidecar.canonicalSource(source)
        let context = project ?? Self.projectsBySource[canonical]
        projectRoot = context.flatMap { SidecarRoot(ProjectFile.directory(of: $0)) }
        catalogHome = Self.home
        preferences = Self.configuration(in: catalogHome)
        let volume = (projectRoot == nil && preferences.disk == nil) ? nil :
            try? canonical.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
        let file = canonical
        projectKey = projectRoot.map { Self.managedKey(source: file, volume: volume, projectRoot: $0) }
        diskKey = preferences.disk.map { _ in Self.managedKey(source: file, volume: volume, projectRoot: nil) }
    }

    package static func sourceKey(_ url: URL) -> URL { AnalysisSidecar.canonicalSource(url) }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func managedKey(source: URL, volume: URLResourceValues?, projectRoot: SidecarRoot?) -> String {
        let path = source.path
        let namespace: String
        if let root = projectRoot, let uuid = volume?.volumeUUIDString, uuid == root.volume {
            let from = root.url.pathComponents, to = source.pathComponents
            let shared = zip(from, to).prefix { $0 == $1 }.count
            let relative = Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared)
            namespace = "project\0" + relative.joined(separator: "/")
        } else if let uuid = volume?.volumeUUIDString, let mount = volume?.volume?.path {
            let prefix = mount.hasSuffix("/") ? mount : mount + "/"
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            namespace = "volume\0" + uuid + "\0" + relative
        } else {
            namespace = "path\0" + path
        }
        return Self.digest(namespace)
    }

    private func entry(_ mode: SidecarStorageMode, creating: Bool = false) throws -> SidecarCatalogEntry {
        if mode == .media {
            guard let entry = SidecarCatalogEntry.adjacent(source: source) else {
                throw sidecarError("The recording folder is unavailable.")
            }
            return entry
        }
        let root: SidecarRoot
        let key: String
        switch mode {
        case .project:
            guard let folder = projectRoot, let projectKey else {
                throw sidecarError("Save the project or supply its location before saving analysis in its folder.")
            }
            root = folder
            key = projectKey
        case .disk:
            guard let folder = preferences.disk, let diskKey else { throw sidecarError("Choose a cache disk in Settings → Storage first.") }
            root = folder
            key = diskKey
        case .media:
            preconditionFailure()
        }
        let directory = try root.directory(for: key, creating: creating)
        return SidecarCatalogEntry(source: canonical, url: directory.appendingPathComponent(key + "." + AnalysisSidecar.fileExtension),
                                   mode: mode, root: root, key: key)
    }

    package var destination: URL? { preferences.unreadable ? nil : try? entry(preferences.mode).url }
    package func checkWriteConfiguration() throws {
        if preferences.unreadable {
            throw sidecarError("Cannot read the sidecar storage setting. Select a storage location in Settings → Storage to save again.")
        }
    }

    package func prepareDestination() throws -> URL {
        try checkWriteConfiguration()
        return try entry(preferences.mode, creating: true).url
    }

    /// Compare the actual entry (if present) or its parent and filename. Resolving
    /// the *media* instead would collapse two genuinely different companions when
    /// the user opens a symlink to a recording with another name.
    private static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.path == rhs.path { return true }
        var a = stat(), b = stat()
        if lstat(lhs.path, &a) == 0, lstat(rhs.path, &b) == 0 {
            return a.st_dev == b.st_dev && a.st_ino == b.st_ino
        }
        let left = lhs.lastPathComponent, right = rhs.lastPathComponent
        guard left.caseInsensitiveCompare(right) == .orderedSame else { return false }
        let parent = lhs.deletingLastPathComponent()
        guard stat(parent.path, &a) == 0, stat(rhs.deletingLastPathComponent().path, &b) == 0,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { return false }
        if left == right { return true }
        return (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) == false
    }

    package var candidateEntries: [SidecarCatalogEntry] {
        var result: [SidecarCatalogEntry] = []
        func add(_ row: SidecarCatalogEntry?) {
            if let row, !result.contains(where: { Self.sameLocation($0.url, row.url) }) { result.append(row) }
        }
        for mode in [preferences.mode] + SidecarStorageMode.allCases.filter({ $0 != preferences.mode }) {
            switch mode {
            case .media:
                add(SidecarCatalogEntry.adjacent(source: source))
                if source.path != canonical.path { add(SidecarCatalogEntry.adjacent(source: canonical)) }
            case .project where projectRoot != nil, .disk where preferences.disk != nil:
                add(try? entry(mode))
            default:
                break
            }
        }
        for row in SidecarLocationCatalog.entries(home: catalogHome, source: canonical.path) {
            if !result.contains(where: { Self.sameLocation($0.url, row.url) }), Self.validate(row) { add(row) }
        }
        return result
    }

    package var candidates: [URL] {
        // Ordinary reads probe adjacent paths directly. Capturing the source
        // directory's persistent identity is only needed for catalog maintenance.
        var urls = [source.appendingPathExtension(AnalysisSidecar.fileExtension)]
        let physical = canonical.appendingPathExtension(AnalysisSidecar.fileExtension)
        if !Self.sameLocation(urls[0], physical) { urls.append(physical) }
        for mode in [SidecarStorageMode.project, .disk] {
            guard let row = try? entry(mode) else { continue }
            if !urls.contains(where: { Self.sameLocation($0, row.url) }) {
                if mode == preferences.mode { urls.insert(row.url, at: 0) } else { urls.append(row.url) }
            }
        }
        for row in SidecarLocationCatalog.entries(home: catalogHome, source: canonical.path) {
            if !urls.contains(where: { Self.sameLocation($0, row.url) }), Self.validate(row) { urls.append(row.url) }
        }
        return urls
    }

    package func isAdjacent(_ candidate: URL) -> Bool {
        Self.sameLocation(candidate, source.appendingPathExtension(AnalysisSidecar.fileExtension)) ||
            Self.sameLocation(candidate, canonical.appendingPathExtension(AnalysisSidecar.fileExtension))
    }

    package func lookupKey(for candidate: URL) -> String? {
        if isAdjacent(candidate) { return nil }
        for mode in [SidecarStorageMode.project, .disk] {
            if let row = try? entry(mode), Self.sameLocation(row.url, candidate) { return row.key }
        }
        return SidecarLocationCatalog.entries(home: catalogHome, source: canonical.path)
            .first { Self.sameLocation($0.url, candidate) && Self.validate($0) }?.key
    }

    /// A successful read may be the first time this process sees a cutcache
    /// or a project-local cache written on another Mac. Remember it for this
    /// session's clear dialog and workers, without writing the durable catalog.
    func observeValidated(_ sidecar: URL, device: dev_t, inode: ino_t) {
        let known = SidecarLocationCatalog.entries(home: catalogHome, source: canonical.path)
        if known.contains(where: { Self.sameLocation($0.url, sidecar) && Self.validate($0) }) { return }
        let observed: SidecarCatalogEntry?
        if isAdjacent(sidecar) {
            observed = SidecarCatalogEntry.adjacent(source: sidecar.deletingPathExtension())
        } else {
            observed = [SidecarStorageMode.project, .disk].compactMap { try? entry($0) }
                .first { Self.sameLocation($0.url, sidecar) }
        }
        guard let observed else { return }
        SidecarLocationCatalog.observe(observed, home: catalogHome, source: canonical.path, device: device, inode: inode)
    }

    package func registerSaved(_ sidecar: URL) {
        guard let saved = try? entry(preferences.mode), Self.sameLocation(saved.url, sidecar) else { return }
        SidecarLocationCatalog.record(saved, home: catalogHome, source: canonical.path)
    }

    package static func knownEntries() -> [SidecarCatalogEntry] {
        SidecarLocationCatalog.entries(home: home, source: nil)
    }

    /// Enumerate managed directories only for an explicit clear dialog/scan. Every
    /// candidate must have our exact shard layout and a manifest belonging to
    /// the source that produced its filename. Regular reads use direct lookups.
    package static func managedEntries(scanning folders: [URL], sources: [URL] = [],
                                       restrictedTo scopes: [[String]] = [],
                                       sourceForCache: (URL) -> URL?) -> [SidecarCatalogEntry] {
        let known = knownEntries().filter { $0.mode != .media }
        let durable = SidecarLocationCatalog.persisted(home: home, source: nil)
        var roots: [SidecarRoot: Set<SidecarStorageMode>] = [:]
        func include(_ root: SidecarRoot?, _ mode: SidecarStorageMode) {
            if let root { roots[root, default: []].insert(mode) }
        }
        for row in known { include(row.root, row.mode) }
        include(configuration(in: home).disk, .disk)
        for project in [projectURL].compactMap({ $0 }) + Array(projectsBySource.values) {
            include(SidecarRoot(ProjectFile.directory(of: project)), .project)
        }
        for folder in folders {
            let base = folder.lastPathComponent == "MPCut Cache" ? folder.deletingLastPathComponent() : folder
            guard let root = SidecarRoot(base), !roots.keys.contains(where: { $0.path == root.path }) else { continue }
            include(root, .project)
            include(root, .disk)
        }

        var result: [SidecarCatalogEntry] = []
        for (root, modes) in roots {
            let top = root.url.appendingPathComponent("MPCut Cache", isDirectory: true)
            let components = top.pathComponents
            guard scopes.isEmpty || scopes.contains(where: {
                components.starts(with: $0) || $0.starts(with: components)
            }), root.available else { continue }
            var info = stat()
            guard lstat(top.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  let shards = try? FileManager.default.contentsOfDirectory(atPath: top.path) else { continue }
            let registered = Set(durable.filter { $0.root == root }.map { $0.url.path })
            var lookup: [String: URL] = [:]
            func capture(_ source: URL) {
                let file = sourceKey(source)
                let volume = try? file.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
                for mode in modes {
                    lookup[managedKey(source: file, volume: volume, projectRoot: mode == .project ? root : nil)] = file
                }
            }
            for source in sources { capture(source) }
            for shard in shards where shard.utf8.count == 2 && isHex(shard) {
                guard let directory = try? root.directory(for: shard, creating: false),
                      let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
                for name in files where name.hasSuffix("." + AnalysisSidecar.fileExtension) {
                    let key = String(name.dropLast(1 + AnalysisSidecar.fileExtension.count))
                    guard key.utf8.count == 64, key.hasPrefix(shard), isHex(key) else { continue }
                    let url = directory.appendingPathComponent(name)
                    guard scopes.isEmpty || scopes.contains(where: { url.pathComponents.starts(with: $0) }) else { continue }
                    guard !registered.contains(url.path) else { continue }
                    let verified = sourceForCache(url)
                    guard let file = verified ?? lookup[key], file.isFileURL else { continue }
                    let source = sourceKey(file)
                    let volume = try? source.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
                    let matched = SidecarStorageMode.allCases.first { mode in
                        modes.contains(mode) && managedKey(source: source, volume: volume, projectRoot: mode == .project ? root : nil) == key
                    }
                    // Media can be offline or have moved since this copy was written.
                    // The cleaner has already checked the SQLite header and its stored
                    // key against the physical filename before returning a source path.
                    let inferred: SidecarStorageMode? = verified == nil ? nil : (modes.contains(.project) ? .project : .disk)
                    guard let mode = matched ?? inferred else { continue }
                    result.append(SidecarCatalogEntry(source: source, url: url, mode: mode, root: root, key: key))
                }
            }
        }
        return result
    }

    private static func isHex(_ text: String) -> Bool {
        text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Explicit scans promote validated discoveries from this session to the durable
    /// catalog. Keep the caller's verified SQLite read transaction open throughout.
    static func registerDiscovered(_ row: SidecarCatalogEntry, in db: SidecarDatabase) throws {
        guard validate(row) else { return }
        let source = sourceKey(row.source)
        if row.mode == .media {
            guard try AnalysisSidecar(source: source).currentStamp(db) != nil else { return }
        } else {
            guard let key = row.lookupKey else { return }
            let volume = try? source.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
            let recomputed = managedKey(source: source, volume: volume, projectRoot: row.mode == .project ? row.root : nil)
            let verified = try db.statement("SELECT source_path FROM sidecar_location WHERE id = 1 AND lookup_key = ?", [key]) { q in
                guard sqlite3_step(q) == SQLITE_ROW else { return false }
                if recomputed == key { return true }
                guard sqlite3_column_type(q, 0) == SQLITE_TEXT, let path = sqlite3_column_text(q, 0) else { return false }
                let stored = String(cString: path)
                return stored.utf8.count == sqlite3_column_bytes(q, 0) && stored == source.path
            }
            guard verified else { return }
        }
        SidecarLocationCatalog.record(row, home: home, source: source.path)
    }

    package static func validate(_ row: SidecarCatalogEntry) -> Bool {
        guard row.source.isFileURL, row.url.isFileURL else { return false }
        if row.mode == .media {
            return row.source.appendingPathExtension(AnalysisSidecar.fileExtension).path == row.url.path &&
                SidecarRoot(row.source.deletingLastPathComponent()) == row.root
        }
        guard let key = row.key, key.count == 64, isHex(key),
              let directory = try? row.root.directory(for: key, creating: false) else { return false }
        return row.url.path == directory.appendingPathComponent(key + "." + AnalysisSidecar.fileExtension).path
    }

    static func forgetEntries(_ entries: [SidecarCatalogEntry]) { SidecarLocationCatalog.forget(entries, home: home) }
    package static func forgetEntry(_ entry: SidecarCatalogEntry) { forgetEntries([entry]) }

    package static func forget(_ urls: Set<URL>) {
        SidecarLocationCatalog.forget(knownEntries().filter { urls.contains($0.url) && validate($0) }, home: home)
    }
}

/// The catalog is a hint, independently rebuildable from deterministic locations.
/// A missing catalog is always a read-only miss. SQLite serializes writers from
/// the GUI, CLI and background workers without dropping registrations.
private enum SidecarLocationCatalog {
    /// The SQLite catalog uses rollback journaling. Commits change the database
    /// file itself, including commits made by a separate CLI process.
    private struct Revision: Equatable {
        let device: dev_t
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        /// The mount's device number may change after reconnection. The
        /// catalog entry separately verifies its original directory and volume.
        func matchesObservedFile(_ other: Self) -> Bool {
            inode == other.inode && size == other.size && seconds == other.seconds && nanoseconds == other.nanoseconds
        }

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_ctimespec.tv_sec
            nanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private struct SessionSource: Hashable {
        let home: URL
        let source: String
    }

    private struct Observation: Equatable {
        let entry: SidecarCatalogEntry
        let revision: Revision
    }

    private final class Recent: @unchecked Sendable {
        let lock = NSLock()
        var values: [URL: (Revision, [String: [SidecarCatalogEntry]])] = [:]
        var observations: [SessionSource: [Observation]] = [:]
        var order: [SessionSource] = []
    }
    private static let recent = Recent()

    static func entries(home: URL, source: String?) -> [SidecarCatalogEntry] {
        var result = persisted(home: home, source: source)
        let snapshots: [(SessionSource, [Observation])] = recent.lock.withLock {
            if let source {
                let key = SessionSource(home: home, source: source)
                return recent.observations[key].map { [(key, $0)] } ?? []
            }
            return recent.observations.filter { $0.key.home == home }.map { ($0.key, $0.value) }
        }
        for (key, values) in snapshots {
            for observation in values {
                let row = observation.entry
                if let current = Revision(row.url), current.matchesObservedFile(observation.revision),
                   SidecarLocations.validate(row) {
                    if !result.contains(row) { result.append(row) }
                } else if !row.root.available {
                    // Keep the bounded hint while the original root is offline.
                    // The clear dialog can explain a skipped disk, whereas media
                    // lookup only receives entries from currently verified roots.
                    if source == nil, !result.contains(row) { result.append(row) }
                } else {
                    recent.lock.withLock {
                        recent.observations[key]?.removeAll { $0 == observation }
                        if recent.observations[key]?.isEmpty == true {
                            recent.observations.removeValue(forKey: key)
                            recent.order.removeAll { $0 == key }
                        }
                    }
                }
            }
        }
        return result
    }

    static func observe(_ row: SidecarCatalogEntry, home: URL, source: String, device: dev_t, inode: ino_t) {
        guard let revision = Revision(row.url), revision.device == device, revision.inode == inode else { return }
        let key = SessionSource(home: home, source: source)
        let value = Observation(entry: row, revision: revision)
        recent.lock.withLock {
            if recent.observations[key] == nil {
                if recent.order.count >= 1024 {
                    recent.observations.removeValue(forKey: recent.order.removeFirst())
                }
                recent.order.append(key)
            }
            var copies = recent.observations[key] ?? []
            copies.removeAll { $0.entry.catalogPath == row.catalogPath && $0.entry.rootIdentity == row.rootIdentity }
            if copies.count >= 32 { copies.removeFirst() }
            copies.append(value)
            recent.observations[key] = copies
        }
    }

    static func persisted(home: URL, source: String?) -> [SidecarCatalogEntry] {
        let path = home.appendingPathComponent("locations.sqlite")
        guard let revision = Revision(path) else { return [] }
        if let source, let hit = recent.lock.withLock({ () -> [SidecarCatalogEntry]? in
            guard let (saved, table) = recent.values[home], saved == revision else { return nil }
            return table[source]
        }) { return hit }
        guard let db = openDatabase(home, writing: false) else { return [] }
        defer { sqlite3_close(db) }
        let sql = source == nil ? "SELECT entry FROM locations ORDER BY path" :
            "SELECT entry FROM locations WHERE source = ? ORDER BY path"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        if let source { sqlite3_bind_text(statement, 1, source, -1, transient) }
        var rows: [SidecarCatalogEntry] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if (1...131_072).contains(count), let bytes = sqlite3_column_blob(statement, 0) {
                let data = Data(bytes: bytes, count: count)
                if let row = try? JSONDecoder().decode(SidecarCatalogEntry.self, from: data) { rows.append(row) }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return [] }
        if let source {
            recent.lock.withLock {
                if recent.values.count >= 32 { recent.values.removeAll(keepingCapacity: true) }
                if recent.values[home]?.0 != revision || (recent.values[home]?.1.count ?? 0) >= 1024 {
                    recent.values[home] = (revision, [:])
                }
                recent.values[home]?.1[source] = rows
            }
        }
        return rows
    }

    static func record(_ row: SidecarCatalogEntry, home: URL, source: String) {
        if persisted(home: home, source: source).contains(row) { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(row), let db = openDatabase(home, writing: true) else { return }
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO locations(path, root, source, entry) VALUES(?, ?, ?, ?)
            ON CONFLICT(path, root) DO UPDATE SET source=excluded.source, entry=excluded.entry
            WHERE locations.source != excluded.source OR locations.entry != excluded.entry
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, row.catalogPath, -1, transient)
        sqlite3_bind_text(statement, 2, row.rootIdentity, -1, transient)
        sqlite3_bind_text(statement, 3, source, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_step(statement)
    }

    static func forget(_ entries: [SidecarCatalogEntry], home: URL) {
        guard !entries.isEmpty else { return }
        recent.lock.withLock {
            for key in Array(recent.observations.keys) where key.home == home {
                recent.observations[key]?.removeAll { seen in entries.contains { row in
                    row.catalogPath == seen.entry.catalogPath && row.rootIdentity == seen.entry.rootIdentity
                } }
                if recent.observations[key]?.isEmpty == true {
                    recent.observations.removeValue(forKey: key)
                    recent.order.removeAll { $0 == key }
                }
            }
        }
        // Forgetting a read-only session observation has no durable bookkeeping.
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("locations.sqlite").path),
              let db = openDatabase(home, writing: true) else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM locations WHERE path=? AND root=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        for row in entries {
            sqlite3_bind_text(statement, 1, row.catalogPath, -1, transient)
            sqlite3_bind_text(statement, 2, row.rootIdentity, -1, transient)
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func openDatabase(_ home: URL, writing: Bool) -> OpaquePointer? {
        let url = home.appendingPathComponent("locations.sqlite")
        if writing {
            do { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700]) }
            catch { return nil }
        } else if !FileManager.default.fileExists(atPath: url.path) { return nil }
        let flags = (writing ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOFOLLOW
        guard let physical = realpath(home.path, nil) else { return nil }
        defer { free(physical) }
        let path = String(cString: physical) + "/locations.sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(handle, 5000)
        if writing {
            let schema = "CREATE TABLE IF NOT EXISTS locations(path TEXT NOT NULL, root TEXT NOT NULL, source TEXT NOT NULL, entry BLOB NOT NULL, PRIMARY KEY(path,root)); CREATE INDEX IF NOT EXISTS catalog_source ON locations(source);"
            guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                return nil
            }
        }
        return handle
    }
}
