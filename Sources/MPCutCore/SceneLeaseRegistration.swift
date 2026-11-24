import CryptoKit
import Darwin
import Foundation

/// The source inode lock serializes lease admissions across destinations. This
/// local receipt remembers the owner even while a cache volume is disconnected.
struct SceneLeaseRegistration {
    struct Grant: Codable {
        let entry: SidecarCatalogEntry
        let attempt: String
        let owner: String
        let fence: Int64
        var expires: Double
        // Keep an offline predecessor fenced until its own database has
        // committed the supersession. Most grants have no displaced attempts.
        var displaced: Set<String>? = nil

        func matches(_ claim: SceneAttemptClaim) -> Bool {
            attempt == claim.attemptID && owner == claim.owner && fence == claim.fence
        }
    }

    private let directory: URL
    private let file: URL

    init(store: AnalysisSidecar, scope: String) {
        directory = store.locations.catalogHome.appendingPathComponent("scene-leases", isDirectory: true)
        let key = "\(store.identity.device):\(store.identity.inode):\(scope)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(digest)
    }

    func read() throws -> Grant? {
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw sidecarError("Cannot inspect the local scene lease.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 131_072,
              let bytes = try handle.read(upToCount: Int(info.st_size)), bytes.count == info.st_size else {
            throw sidecarError("The local scene lease is unreadable.")
        }
        return try JSONDecoder().decode(Grant.self, from: bytes)
    }

    func write(_ value: Grant) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw sidecarError("Cannot write the local scene lease directory.")
        }
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    func finish(_ grant: Grant) throws {
        guard grant.displaced?.isEmpty == false else { remove(); return }
        // An empty owner identifies bookkeeping retained after a release.
        // No worker can use this receipt to publish another checkpoint.
        let inactive = Grant(entry: grant.entry, attempt: grant.attempt, owner: "", fence: grant.fence,
                         expires: 0, displaced: grant.displaced)
        try write(inactive)
    }

    func acknowledge(_ attempt: String) throws {
        guard var grant = try read(), grant.displaced?.remove(attempt) != nil else { return }
        if grant.displaced?.isEmpty == true { grant.displaced = nil }
        if grant.owner.isEmpty { try finish(grant) } else { try write(grant) }
    }

    func remove() { _ = unlink(file.path) }
}
