import CryptoKit
import Darwin
import Foundation

/// Holds validated picture-only media. Generators write one media file at the
/// provided URL. Callers consume the media or copy it inside the use closure.
public struct StillSegmentCache: Sendable {
    public static let shared = Self(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("MPCut/GeneratedStills-v1", isDirectory: true))

    public struct Key: Sendable {
        fileprivate let digest: String
        private let inputs: [Input]

        private struct Input: Sendable {
            let url: URL
            let identity: SourceIdentity
        }

        /// Parameters must describe the effective rendering and codec settings,
        /// timeline schedule, color policy, encoder revision and destination muxer.
        /// File order distinguishes the roles of the content fingerprints.
        public init<Parameters: Encodable>(files: [URL], parameters: Parameters,
                                           cancelled: () -> Bool = { false }) throws {
            var hash = SHA256()
            var fingerprints: [Input] = []
            hash.update(data: Data("MPCut still segment v1\u{0}".utf8))
            for file in files {
                let identity = try SourceIdentity(file)
                let content = try StillSegmentCache.checksum(file, expected: identity, cancelled: cancelled)
                guard identity.isCurrentSnapshot(at: file) else { throw StillSegmentCache.changedInput }
                hash.update(data: Data(content))
                fingerprints.append(Input(url: file, identity: identity))
            }
            hash.update(data: Data("\(files.count)\u{0}".utf8))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            hash.update(data: try encoder.encode(parameters))
            digest = StillSegmentCache.hex(hash.finalize())
            inputs = fingerprints
        }

        fileprivate func checkInputs() throws {
            for input in inputs {
                guard input.identity.isCurrentSnapshot(at: input.url) else { throw StillSegmentCache.changedInput }
            }
        }
    }

    private let directory: URL?
    private let maximumBytes: Int64
    private let maximumEntries: Int
    private let shardCount: Int

    init(directory: URL?, maximumBytes: Int64 = 1 << 30, maximumEntries: Int = 128, shardCount: Int = 8) {
        precondition(maximumBytes > 0 && maximumEntries >= shardCount && 1...256 ~= shardCount)
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
        self.shardCount = shardCount
    }

    public func withSegment<T>(key: Key, outputExtension: String, cancelled: () -> Bool = { false },
                               generate: (URL) throws -> Void, validate: (URL) throws -> Void,
                               use: (URL) throws -> T) throws -> T {
        guard !outputExtension.isEmpty, outputExtension.utf8.count <= 8,
              outputExtension.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            throw CutError(code: "invalid_input", message: "The generated still cache needs a lowercase media extension.")
        }
        try Self.checkCancellation(cancelled)
        try key.checkInputs()

        let files = FileManager.default
        let filename = "picture.\(outputExtension)"

        func createStage(_ directory: URL) throws {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        }

        func generateIn(_ directory: URL) throws -> URL {
            let output = directory.appendingPathComponent(filename)
            try Self.checkCancellation(cancelled)
            try key.checkInputs()
            try generate(output)
            try Self.checkCancellation(cancelled)
            try key.checkInputs()
            try validate(output)
            try Self.checkCancellation(cancelled)
            try key.checkInputs()
            return output
        }

        func consume(_ output: URL) throws -> T {
            let result = try use(output)
            try Self.checkCancellation(cancelled)
            try key.checkInputs()
            return result
        }

        func generateTemporarily() throws -> T {
            let stage = files.temporaryDirectory.appendingPathComponent("mpcut-still-\(UUID().uuidString)", isDirectory: true)
            try createStage(stage)
            defer { try? files.removeItem(at: stage) }
            let output = try generateIn(stage)
            return try consume(output)
        }

        guard let directory, let bucket = Int(key.digest.prefix(2), radix: 16) else {
            return try generateTemporarily()
        }
        let shard = directory.appendingPathComponent(String(bucket % shardCount), isDirectory: true)
        do {
            try files.createDirectory(at: shard, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        } catch {
            return try generateTemporarily()
        }
        let descriptor = open(shard.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return try generateTemporarily() }
        defer { close(descriptor) }

        let deadline = ContinuousClock.now + .seconds(30)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, .now < deadline else {
                return try generateTemporarily()
            }
            try Self.checkCancellation(cancelled)
            usleep(10_000)
        }
        try Self.checkCancellation(cancelled)
        try key.checkInputs()
        let stage = shard.appendingPathComponent(".staging", isDirectory: true)
        // A prior process may have stopped between creating its stage and publishing.
        try? files.removeItem(at: stage)
        let entry = shard.appendingPathComponent("\(key.digest)-\(outputExtension)", isDirectory: true)
        let cached = entry.appendingPathComponent(filename)
        if files.fileExists(atPath: entry.path) {
            do {
                try checkEntry(cached, in: entry, cancelled: cancelled)
                try validate(cached)
            } catch {
                try Self.checkCancellation(cancelled)
                try key.checkInputs()
                do { try files.removeItem(at: entry) }
                catch { return try generateTemporarily() }
            }
            if files.fileExists(atPath: cached.path) {
                try Self.checkCancellation(cancelled)
                try key.checkInputs()
                try? files.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
                return try consume(cached)
            }
        }

        do { try createStage(stage) }
        catch { return try generateTemporarily() }
        defer { try? files.removeItem(at: stage) }
        let output = try generateIn(stage)
        var result = output
        do {
            let size = try Self.regularFile(output).st_size
            if size <= maximumBytes / Int64(shardCount),
               try files.contentsOfDirectory(atPath: stage.path) == [filename] {
                let checksum = try Self.checksum(output, cancelled: cancelled)
                try Data(checksum).write(to: stage.appendingPathComponent("sha256"))
                try prune(shard, incomingBytes: size)
                try Self.checkCancellation(cancelled)
                try key.checkInputs()
                try files.moveItem(at: stage, to: entry)
                result = cached
            }
        } catch {
            // Cache maintenance failures must not lose usable, validated job media.
            try Self.checkCancellation(cancelled)
            try key.checkInputs()
        }
        try Self.checkCancellation(cancelled)
        try key.checkInputs()
        return try consume(result)
    }

    private func checkEntry(_ output: URL, in entry: URL, cancelled: () -> Bool) throws {
        var info = stat()
        guard lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let digest = entry.appendingPathComponent("sha256")
        guard try Self.regularFile(output).st_size <= maximumBytes / Int64(shardCount),
              try Self.regularFile(digest).st_size == 32,
              try Data(contentsOf: digest) == Data(Self.checksum(output, cancelled: cancelled)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func prune(_ shard: URL, incomingBytes: Int64) throws {
        let files = FileManager.default
        let entries = try files.contentsOfDirectory(at: shard, includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])
        var retained: [(url: URL, size: Int64, accessed: Date)] = []
        var bytes: Int64 = 0
        for entry in entries {
            let fields = entry.lastPathComponent.split(separator: "-")
            guard fields.count == 2, fields[0].count == 64,
                  fields[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            let media = entry.appendingPathComponent("picture.\(fields[1])")
            guard let info = try? Self.regularFile(media),
                  info.st_size <= maximumBytes / Int64(shardCount) else {
                try files.removeItem(at: entry)
                continue
            }
            let accessed = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            retained.append((entry, info.st_size, accessed))
            bytes += info.st_size
        }
        let available = maximumBytes / Int64(shardCount) - incomingBytes
        var count = retained.count
        for victim in retained.sorted(by: { $0.accessed < $1.accessed }) {
            guard count >= maximumEntries / shardCount || bytes > available else { break }
            try files.removeItem(at: victim.url)
            bytes -= victim.size
            count -= 1
        }
    }

    private static func regularFile(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return info
    }

    private static func checksum(_ url: URL, expected: SourceIdentity? = nil, cancelled: () -> Bool) throws -> SHA256.Digest {
        let file = try StillImage.openRegularImage(url)
        defer { try? file.close() }
        let identity = try SourceIdentity(file: file)
        guard expected?.matchesSnapshot(identity) != false else { throw changedInput }
        var digest = SHA256()
        let capacity = Int(min(1 << 20, max(4 << 10, identity.size)))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt64>.alignment)
        defer { buffer.deallocate() }
        while true {
            try checkCancellation(cancelled)
            let count = Darwin.read(file.fileDescriptor, buffer, capacity)
            if count < 0 {
                let failure = errno
                if failure == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
            guard count > 0 else { break }
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        guard identity.matchesSnapshot(try SourceIdentity(file: file)) else { throw changedInput }
        return digest.finalize()
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var changedInput: CutError {
        CutError(code: "source_changed", message: "A generated still input changed during rendering.")
    }

    private static func checkCancellation(_ cancelled: () -> Bool) throws {
        if Task.isCancelled || cancelled() {
            throw CutError(code: "cancelled", message: "Still generation cancelled.")
        }
    }
}
