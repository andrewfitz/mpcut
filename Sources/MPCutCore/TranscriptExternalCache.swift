import Darwin
import Foundation

/// The standalone provider verifies both files against the snapshot recorded during
/// preparation before looking up or publishing a shared recognition result.
struct TranscriptExternalCacheDescriptor: Encodable {
    struct Snapshot: Codable, Equatable, Sendable {
        let path: String
        let stat_values: [String]

        var isCurrent: Bool { Self(URL(fileURLWithPath: path)) == self }

        init?(_ url: URL) {
            path = url.path
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            stat_values = [String(UInt64(bitPattern: Int64(info.st_dev))), String(info.st_ino), String(info.st_size),
                           String(info.st_mtimespec.tv_sec), String(info.st_mtimespec.tv_nsec),
                           String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)]
        }
    }

    let source: Snapshot
    let audio: Snapshot?
    let scope: String?
    let directory: String?
    let write: Bool
    let restart: Bool

    init?(track: TranscriptJobTrack, restart: Bool) {
        guard track.recognize, track.unavailable == nil, track.streamIndex != nil,
              let source = Snapshot(track.file), track.sourceIsCurrent, source.isCurrent else { return nil }
        self.source = source
        audio = track.stagedAudioSnapshot.flatMap { $0.isCurrent ? $0 : nil }
        self.restart = restart
        if track.hasReusableEvidence,
           let directory = try? TranscriptRecognitionClaims.directory() {
            scope = track.evidence
            self.directory = directory.path
            write = true
            // The provider publishes the exchange version that this folder says MPCut reads.
            TranscriptRecognitionExchange.declareReader(in: directory)
        } else {
            scope = nil
            directory = nil
            write = false
        }
    }

    static func claimID(scope: String, key: String) -> String {
        TranscriptStore.digest(Data("\(scope)\u{0}\(key)".utf8))
    }
}
