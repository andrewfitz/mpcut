import CryptoKit
import Foundation

func participantSourceDigest(_ url: URL, identity: SourceIdentity,
                             cancelled: () -> Bool = { false }) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let changed = CutError(code: "source_changed", message: "The recording changed while verifying its content.")
    guard identity.matchesSnapshot(try SourceIdentity(file: file)) else { throw changed }
    var hash = SHA256()
    while true {
        if cancelled() { throw CancellationError() }
        // Release each megabyte as it is hashed. Without a pool the blocks
        // accumulate until the caller returns, up to the size of the recording.
        let more = try autoreleasepool { () -> Bool in
            guard let data = try file.read(upToCount: 1 << 20), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }
        if !more { break }
    }
    if cancelled() { throw CancellationError() }
    guard identity.isCurrentSnapshot(at: url) else { throw changed }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

extension SourceIdentity {
    var participantDigestSection: String {
        let prefix = "participant_content_sha256.v1."
        return prefix + (changeTime.map { "\($0.seconds).\($0.nanoseconds)" } ?? "current")
    }
}

func cachedParticipantSourceDigest(_ identity: SourceIdentity, in cache: AnalysisSidecar?,
                                   cancelled: () -> Bool = { false }) -> String? {
    guard let data = cache?.read(identity.participantDigestSection, maxBytes: 64, cancelled: cancelled),
          let saved = String(data: data, encoding: .utf8), validParticipantSourceDigest(saved) else { return nil }
    return saved
}
