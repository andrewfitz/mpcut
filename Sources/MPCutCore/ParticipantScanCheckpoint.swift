#if canImport(CTileTrail)
import CTileTrail
import CryptoKit
import Darwin
import Foundation

/// A journal belongs to one source snapshot and detector configuration. Each
/// chunk adds the history since the previous checkpoint and replaces live state.
final class ParticipantScanCheckpoint {
    struct Anchor: Codable {
        let pts: Int64
        let time: RationalTime
        let end: RationalTime?
    }

    private struct Manifest: Codable {
        let version: Int
        let fingerprint: String
        let device: Int32
        let changedSeconds: Int?
        let changedNanoseconds: Int?
        var chunks: [UUID]
        var digests: [String: String]?
        var anchor: Anchor?
    }

    private let directory: URL
    private let manifestURL: URL
    private let lock: FileHandle
    private var manifest: Manifest
    private var cursor = mpcut_tiletrail_checkpoint_cursor_t()

    var anchor: Anchor? { manifest.anchor }

    init(directory: URL, fingerprint: String, identity: SourceIdentity, duration: RationalTime) throws {
        self.directory = directory
        manifestURL = directory.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CutError(code: "participant_checkpoint_mismatch",
                           message: "The checkpoint directory cannot be a symbolic link.")
        }
        lock = try Self.openFile(directory.appendingPathComponent(".lock"), flags: O_RDWR | O_CREAT)
        guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CutError(code: "participant_checkpoint_busy", message: "Another scan is using this checkpoint directory.")
        }

        let current = Manifest(version: 2, fingerprint: fingerprint, device: identity.device,
                               changedSeconds: identity.changeTime?.seconds,
                               changedNanoseconds: identity.changeTime?.nanoseconds,
                               chunks: [], anchor: nil)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let file = try Self.openFile(manifestURL, flags: O_RDONLY)
            let saved = try JSONDecoder().decode(Manifest.self, from: file.readToEnd() ?? Data())
            // Version 1 allowed unhashed chunks. Every chunk written to a
            // version 2 journal must have its own checksum in the manifest.
            let chunkKeys = Set(saved.chunks.map(\.uuidString))
            guard (saved.version == 1 || saved.version == current.version),
                  saved.version == 1 || saved.digests.map({ Set($0.keys) == chunkKeys }) == true,
                  saved.fingerprint == current.fingerprint,
                  saved.device == current.device, saved.changedSeconds == current.changedSeconds,
                  saved.changedNanoseconds == current.changedNanoseconds,
                  Set(saved.chunks).count == saved.chunks.count, !saved.chunks.isEmpty,
                  saved.digests?.values.allSatisfy(validParticipantSourceDigest) ?? true,
                  let anchor = saved.anchor, anchor.pts != Int64.min,
                  anchor.time >= .zero, anchor.time < duration,
                  anchor.end.map({ $0 > anchor.time && $0 <= duration }) ?? true else {
                throw CutError(code: "participant_resume_mismatch",
                               message: "The checkpoint does not match this source snapshot and scan configuration.")
            }
            manifest = saved
        } else {
            manifest = current
        }
    }

    func restore(_ analyzer: OpaquePointer?, cancelled: () -> Bool) throws {
        for id in manifest.chunks {
            if cancelled() { throw CancellationError() }
            let file = try Self.openFile(chunkURL(id), flags: O_RDONLY)
            defer { try? file.close() }
            if let expected = manifest.digests?[id.uuidString] {
                guard try Self.digest(file, cancelled: cancelled) == expected else {
                    throw CutError(code: "participant_resume_mismatch", message: "A checkpoint record has changed.")
                }
                try file.seek(toOffset: 0)
            }
            var error = tiletrail_error_t()
            let status = mpcut_tiletrail_checkpoint_read(analyzer, &cursor, file.fileDescriptor, &error)
            try checkTileTrail(status, &error)
        }
    }

    func save(_ analyzer: OpaquePointer?, after anchor: Anchor) throws {
        guard manifest.anchor.map({ $0.time < anchor.time }) ?? true else { return }
        let id = UUID()
        let url = chunkURL(id)
        var nextCursor = cursor
        var nextManifest = manifest
        let file = try Self.openFile(url, flags: O_RDWR | O_CREAT | O_EXCL)
        defer { try? file.close() }
        do {
            var error = tiletrail_error_t()
            let status = mpcut_tiletrail_checkpoint_write(analyzer, &nextCursor, file.fileDescriptor, &error)
            try checkTileTrail(status, &error)
            try file.synchronize()
            try file.seek(toOffset: 0)
            let digest = try Self.digest(file, cancelled: { false })
            nextManifest.chunks.append(id)
            if nextManifest.digests == nil { nextManifest.digests = [:] }
            nextManifest.digests?[id.uuidString] = digest
            nextManifest.anchor = anchor
            try publish(nextManifest)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        cursor = nextCursor
        manifest = nextManifest
    }

    private func publish(_ value: Manifest) throws {
        // Publish only after both records are flushed. A failed rename leaves
        // the previous manifest and cursor usable after restart.
        let url = directory.appendingPathComponent(".manifest-\(UUID())")
        let file = try Self.openFile(url, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: url)
        }
        try file.write(contentsOf: JSONEncoder().encode(value))
        try file.synchronize()
        let renamed = url.withUnsafeFileSystemRepresentation { temporary in
            manifestURL.withUnsafeFileSystemRepresentation { destination in
                guard let temporary, let destination else { return Int32(-1) }
                return Darwin.rename(temporary, destination)
            }
        }
        guard renamed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func digest(_ file: FileHandle, cancelled: () -> Bool) throws -> String {
        var hash = SHA256()
        while true {
            if cancelled() { throw CancellationError() }
            let more = try autoreleasepool { () -> Bool in
                guard let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                return true
            }
            if !more { return hash.finalize().map { String(format: "%02x", $0) }.joined() }
        }
    }

    func removeCommittedChunks() {
        guard !manifest.chunks.isEmpty else { return }
        // Unpublish first. A restart can safely ignore chunks left before
        // cleanup finished, while a failed unpublish leaves a reusable journal.
        do { try FileManager.default.removeItem(at: manifestURL) }
        catch { return }
        for id in manifest.chunks { try? FileManager.default.removeItem(at: chunkURL(id)) }
    }

    private static func openFile(_ url: URL, flags: Int32) throws -> FileHandle {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG else {
            throw CutError(code: "participant_checkpoint_mismatch",
                           message: "A checkpoint record must be a regular file.")
        }
        return file
    }

    private func chunkURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }
}

final class ParticipantScanChunks {
    private let origin: RationalTime
    private var header: ParticipantTrackingResult?
    private var observations: [ParticipantObservation] = []
    private var tracks: [ParticipantTrack] = []
    private var appearances: [ParticipantDetectedAppearance] = []
    private var events: [ParticipantChangeEvent] = []
    private var coverage: [ParticipantTrackingCoverage] = []
    private var diagnostics: [ParticipantBackendDiagnostic] = []
    private var failure: Error?

    init(origin: RationalTime) {
        self.origin = origin
    }

    func result(_ analyzer: OpaquePointer?, end: tiletrail_timestamp_t) throws -> ParticipantTrackingResult {
        let visit: mpcut_tiletrail_result_chunk_t = { context, kind, bytes, count in
            let chunks = Unmanaged<ParticipantScanChunks>.fromOpaque(context!).takeUnretainedValue()
            do {
                guard let bytes else { throw ParticipantScanChunks.invalid }
                // The callback decodes synchronously. Borrow the batch only for
                // this visit, keeping the JSON parser's transient size bounded.
                let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: count,
                                deallocator: .none)
                try chunks.append(kind: kind, data: data)
                return 0
            } catch {
                chunks.failure = error
                return 1
            }
        }
        var error = tiletrail_error_t()
        let status = mpcut_tiletrail_result_chunks(analyzer, end, visit, Unmanaged.passUnretained(self).toOpaque(), &error)
        if let failure { throw failure }
        try checkTileTrail(status, &error)
        guard let header else { throw Self.invalid }
        return ParticipantTrackingResult(schemaVersion: header.schemaVersion, start: header.start, end: header.end,
                                         sampling: header.sampling, observations: observations, tracks: tracks,
                                         appearances: appearances, events: events, coverage: coverage,
                                         diagnostics: diagnostics, resumeAt: header.resumeAt)
    }

    private func append(kind: UInt32, data: Data) throws {
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try ParticipantSourceTime.decodeOriginalClock(type, data: data, origin: origin)
        }
        switch kind {
        case 0: header = try decode(ParticipantTrackingResult.self)
        case 1: observations.append(contentsOf: try decode([ParticipantObservation].self))
        case 2: tracks.append(contentsOf: try decode([ParticipantTrack].self))
        case 3: appearances.append(contentsOf: try decode([ParticipantDetectedAppearance].self))
        case 4: events.append(contentsOf: try decode([ParticipantChangeEvent].self))
        case 5: coverage.append(contentsOf: try decode([ParticipantTrackingCoverage].self))
        case 6: diagnostics.append(contentsOf: try decode([ParticipantBackendDiagnostic].self))
        default: throw Self.invalid
        }
    }

    private static var invalid: CutError {
        CutError(code: "participant_result_invalid", message: "TileTrail returned an invalid result chunk.")
    }
}
#endif
