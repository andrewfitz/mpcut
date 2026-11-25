import CryptoKit
import Foundation

/// The result and the level document a job keeps for each track. A provider reads and writes
/// them as JSON at the path the manifest names, and a recognition record addresses their
/// bytes by digest. A finished job keeps them for as long as its project exists, and a
/// three-hour track's levels are tens of megabytes of text that packs to about a twentieth.
///
/// A packed artifact is a second file beside the first, named with one more extension. The
/// plain file is always the current one when it exists: a provider or an older version of
/// MPCut may have written it since. Each swap writes the new form completely before it
/// removes the old, so a crash between the two leaves both and never neither. An older
/// version does not look for the packed form. It finds no artifact, and recognizes or
/// measures the track again.
enum TranscriptJobArtifact {
    enum Kind {
        case result, levels

        /// Selects the packing the analysis sidecar uses for the same document.
        fileprivate var payloadKey: String {
            switch self {
            case .result: ""
            case .levels: "transcript_activity.v1.job"
            }
        }
    }

    private static let magic = Array("MPCutJobArtifact1".utf8)
    private static let headerSize = magic.count + 8 + SHA256.byteCount
    /// A shorter artifact stays as written: about twenty seconds of levels, where a swap
    /// and the restore before every retry cost more than the few blocks they would free.
    static let minimumSize = 64 * 1024

    static func packedURL(_ url: URL) -> URL { url.appendingPathExtension("z") }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: packedURL(url).path)
    }

    /// Whether a plain file is there and long enough for `pack` to consider.
    static func isPackable(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return size.map { $0 >= minimumSize } ?? false
    }

    /// The artifact's exact bytes from whichever form holds them, or nil when neither can be read.
    static func read(_ url: URL) -> Data? {
        if let plain = try? Data(contentsOf: url, options: .mappedIfSafe) { return plain }
        if let packed = try? Data(contentsOf: packedURL(url), options: .mappedIfSafe) { return unpacked(packed) }
        // A restore in another process removes the packed form after it writes the plain one.
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Writes the artifact at its own path for a reader outside this process, then drops the
    /// packed form. A packed form beside a plain file is left over from an interrupted swap.
    /// Throws when the plain file cannot be written: `read` would go on answering for an
    /// artifact that a provider cannot open.
    static func restore(_ url: URL) throws {
        let packed = packedURL(url)
        guard FileManager.default.fileExists(atPath: packed.path), try writePlain(url) else { return }
        try? FileManager.default.removeItem(at: packed)
    }

    /// The first half of `restore`. False when the artifact has no form this version can read.
    /// A packed form it cannot read stays where it is: a later version may have written it,
    /// and the next plain file takes its place either way.
    @discardableResult
    static func writePlain(_ url: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        guard let stored = try? Data(contentsOf: packedURL(url), options: .mappedIfSafe),
              let bytes = unpacked(stored) else { return false }
        try write(bytes, to: url)
        return true
    }

    /// Replaces the plain file with its packed form and returns the bytes saved, or nil when
    /// the artifact stays as it is: absent, already packed, short, or no smaller packed.
    @discardableResult
    static func pack(_ url: URL, as kind: Kind) -> Int? {
        guard let saved = writePacked(url, as: kind) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return saved
    }

    /// The first half of `pack`: the packed form is on disk, read back and equal to the plain file.
    static func writePacked(_ url: URL, as kind: Kind) -> Int? {
        let packed = packedURL(url)
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard bytes.count >= minimumSize,
              let payload = try? SidecarPayload.encode(bytes, key: kind.payloadKey, providerActivity: kind == .levels, cancelled: { false }),
              payload.logicalSize == bytes.count, payload.bytes.count + headerSize < bytes.count else {
            // A packed form from an earlier swap no longer describes this file.
            try? FileManager.default.removeItem(at: packed)
            return nil
        }
        var container = Data(magic)
        withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { container.append(contentsOf: $0) }
        container.append(contentsOf: SHA256.hash(data: bytes))
        container.append(payload.bytes)
        guard (try? write(container, to: packed)) != nil,
              let stored = try? Data(contentsOf: packed), unpacked(stored) == bytes else {
            try? FileManager.default.removeItem(at: packed)
            return nil
        }
        return bytes.count - container.count
    }

    /// Removes both forms, so that a packed copy cannot stand in for an artifact that was discarded.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: packedURL(url))
    }

    /// The bytes a packed file stands for. A file that is cut short, altered or written by a
    /// later version answers nil, which a reader treats as an artifact that is not there.
    private static func unpacked(_ stored: Data) -> Data? {
        guard stored.count > headerSize, stored.prefix(magic.count).elementsEqual(magic) else { return nil }
        let fields = stored.dropFirst(magic.count)
        let size = fields.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        let digest = fields.dropFirst(8).prefix(SHA256.byteCount)
        guard size > 0, size <= UInt64(Int32.max),
              let bytes = try? SidecarPayload(bytes: Data(fields.dropFirst(8 + SHA256.byteCount)),
                                              logicalSize: Int(size)).decode(cancelled: { false }),
              bytes.count == Int(size), SHA256.hash(data: bytes).elementsEqual(digest) else { return nil }
        return bytes
    }

    /// The whole file reaches the disk under another name before it takes this one, so
    /// the form it replaces can be removed as soon as this returns.
    private static func write(_ data: Data, to url: URL) throws {
        let scratch = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).artifact")
        do {
            guard FileManager.default.createFile(atPath: scratch.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw jobError("transcript_job_storage", "Could not write \(url.lastPathComponent).")
            }
            let file = try FileHandle(forWritingTo: scratch)
            defer { try? file.close() }
            try file.write(contentsOf: data)
            try file.synchronize()
            guard rename(scratch.path, url.path) == 0 else {
                throw jobError("transcript_job_storage", String(cString: strerror(errno)))
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }
}

extension TranscriptRecognitionCache.Artifacts {
    /// A job's artifacts for one track, from whichever form the job holds each in.
    init?(job result: URL, activity: URL?) {
        guard let result = TranscriptJobArtifact.read(result) else { return nil }
        self.init(result: result, activity: activity.flatMap(TranscriptJobArtifact.read))
    }
}
