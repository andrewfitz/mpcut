import CryptoKit
import Darwin
import Foundation

struct TranscriptRecognitionCache {
    private static let prefix = "transcript_recognition.v1."

    struct Artifacts: Codable {
        let result: Data
        let activity: Data?

        var recognitionKey: String? {
            Self.checkedRecognition(result)?.key
        }

        func matches(key: String, evidence: String, needsActivity: Bool = false) -> Bool {
            guard let result = Self.checkedRecognition(result),
                  result.key == key, result.evidence == evidence else { return false }
            guard let activity else {
                return !needsActivity && result.embedsLevels
            }
            return Self.matchesActivity(activity, evidence: evidence, duration: result.duration)
        }

        /// What a well-formed artifact declares. One run asks about the same bytes when it looks
        /// for a finished result, reads the shared cache, saves to it and attaches, and a long
        /// track's levels are hundreds of thousands of frames. Decode and check each distinct
        /// document once per process and answer later questions from its digest.
        private struct CheckedRecognition {
            let key: String?
            let evidence: String
            let duration: Int64
            let embedsLevels: Bool
        }

        private struct CheckedLevels {
            let evidence: String
            let duration: Int64
        }

        private final class Checks: @unchecked Sendable {
            static let shared = Checks()
            private let lock = NSLock()
            private var recognitions: [SHA256.Digest: CheckedRecognition?] = [:]
            private var levels: [SHA256.Digest: CheckedLevels?] = [:]

            func recognition(_ data: Data, check: () -> CheckedRecognition?) -> CheckedRecognition? {
                let digest = SHA256.hash(data: data)
                lock.lock()
                let known = recognitions[digest]
                lock.unlock()
                if let known { return known }
                let verdict = check()
                lock.lock()
                if recognitions.count >= 256 { recognitions.removeAll() }
                recognitions[digest] = .some(verdict)
                lock.unlock()
                return verdict
            }

            func levels(_ data: Data, check: () -> CheckedLevels?) -> CheckedLevels? {
                let digest = SHA256.hash(data: data)
                lock.lock()
                let known = levels[digest]
                lock.unlock()
                if let known { return known }
                let verdict = check()
                lock.lock()
                if levels.count >= 256 { levels.removeAll() }
                levels[digest] = .some(verdict)
                lock.unlock()
                return verdict
            }
        }

        private static func checkedRecognition(_ data: Data) -> CheckedRecognition? {
            Checks.shared.recognition(data) {
                guard let result = try? JSONDecoder().decode(Recognition.self, from: data),
                      result.version == 1, result.sample_rate == 16_000, result.duration_samples > 0,
                      validWords(result.words, duration: result.duration_samples),
                      result.activity.isEmpty || valid(result.activity, duration: result.duration_samples) else { return nil }
                return CheckedRecognition(key: result.recognition_key, evidence: result.stream_evidence,
                                          duration: result.duration_samples, embedsLevels: !result.activity.isEmpty)
            }
        }

        private static func validWords(_ words: [TranscriptNativeSession.Word], duration: Int64) -> Bool {
            var ids = Set<String>()
            var previousStart: Int64 = 0
            for word in words {
                guard word.precision == .word, !word.id.isEmpty, ids.insert(word.id).inserted,
                      !word.text.isEmpty, word.utterance_id?.isEmpty == false, word.speaker_id?.isEmpty != true,
                      word.start_sample >= previousStart, word.end_sample > word.start_sample,
                      word.end_sample <= duration else { return false }
                previousStart = word.start_sample
            }
            return true
        }

        static func matchesActivity(_ data: Data, evidence: String, duration: Int64? = nil) -> Bool {
            let checked = Checks.shared.levels(data) {
                guard let levels = try? JSONDecoder().decode(Levels.self, from: data),
                      levels.version == 1, levels.sample_rate == 16_000, levels.duration_samples > 0,
                      valid(levels.activity, duration: levels.duration_samples) else { return nil }
                return CheckedLevels(evidence: levels.stream_evidence, duration: levels.duration_samples)
            }
            guard let checked else { return false }
            return checked.evidence == evidence && (duration == nil || checked.duration == duration)
        }

        private static func valid(_ levels: [TranscriptNativeSession.Activity], duration: Int64) -> Bool {
            var end: Int64 = 0
            for frame in levels {
                guard frame.start_sample == end, end < duration,
                      frame.end_sample == end + min(320, duration - end),
                      (0...1).contains(frame.level) else { return false }
                end = frame.end_sample
            }
            return end == duration
        }

        func write(result: URL, activity: URL?) throws {
            try self.result.write(to: result, options: .atomic)
            if let activity {
                if let levels = self.activity {
                    try levels.write(to: activity, options: .atomic)
                } else if FileManager.default.fileExists(atPath: activity.path) {
                    try FileManager.default.removeItem(at: activity)
                }
            }
        }

        init(result: Data, activity: Data?) {
            self.result = result
            self.activity = activity
        }

        init?(result: URL, activity: URL?) {
            guard let result = try? Data(contentsOf: result, options: .mappedIfSafe) else { return nil }
            self.result = result
            self.activity = activity.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        }
    }

    private struct Exchange: Codable {
        let result: Data
        let activity: Data?
        let digest: String

        static func digest(result: Data, activity: Data?) -> String {
            TranscriptStore.digest(result + Data([0]) + (activity ?? Data()))
        }

        init(_ artifacts: Artifacts) {
            result = artifacts.result
            activity = artifacts.activity
            digest = Self.digest(result: result, activity: activity)
        }

        var artifacts: Artifacts? {
            guard digest == Self.digest(result: result, activity: activity) else { return nil }
            return Artifacts(result: result, activity: activity)
        }
    }

    private struct Levels: Decodable {
        let version: Int
        let sample_rate: Int
        let stream_evidence: String
        let duration_samples: Int64
        let activity: [TranscriptNativeSession.Activity]
    }

    private struct Recognition: Decodable {
        let version: Int
        let sample_rate: Int
        let recognition_key: String?
        let stream_evidence: String
        let duration_samples: Int64
        let words: [TranscriptNativeSession.Word]
        let activity: [TranscriptNativeSession.Activity]
    }

    let sidecar: AnalysisSidecar
    let key: String
    let evidence: String
    let stream: Int

    var section: String { "\(Self.prefix)\(stream).\(key)" }
    var claimID: String {
        TranscriptExternalCacheDescriptor.claimID(
            scope: TranscriptExternalCacheDescriptor.scope(for: sidecar.source, stream: stream), key: key)
    }

    static func stream(forKey key: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        let components = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2, let stream = Int(components[0]), stream >= 0,
              TranscriptStore.validDigest(String(components[1])) else { return nil }
        return stream
    }

    func read(cancelled: () -> Bool) -> Artifacts? {
        guard AnalysisSidecar.readsEnabled, !sidecar.isExcluded else { return nil }
        if let data = sidecar.read(section, cancelled: cancelled),
           let artifacts = try? JSONDecoder().decode(Artifacts.self, from: data),
           artifacts.matches(key: key, evidence: evidence) { return artifacts }
        return readExchange(cancelled: cancelled)
    }

    private func readExchange(cancelled: () -> Bool = { false }) -> Artifacts? {
        guard !cancelled(), let url = exchangeURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let exchange = try? JSONDecoder().decode(Exchange.self, from: data),
              let artifacts = exchange.artifacts,
              artifacts.matches(key: key, evidence: evidence) else { return nil }
        return artifacts
    }

    private var exchangeURL: URL? {
        try? TranscriptRecognitionClaims.directory().appendingPathComponent(claimID + ".json")
    }

    /// The standalone helper writes only the exchange. Import mirrors a
    /// matching helper artifact into the normal analysis sidecar.
    static func promoteExternal(in record: TranscriptJobRecord, stamps: [String: SourceIdentity],
                                recognizedIDs: Set<String>) {
        guard AnalysisSidecar.readsEnabled, AnalysisSidecar.automaticWritesEnabled else { return }
        for track in record.sessions.flatMap(\.tracks) {
            guard recognizedIDs.contains(track.id), track.hasReusableEvidence, track.sourceIsCurrent,
                  !AnalysisSidecar.isExcluded(track.file, in: AnalysisSidecar.excludedSources), let stream = track.streamIndex,
                  let stamp = stamps[track.id], let result = track.result,
                  let local = Artifacts(result: result, activity: track.activity),
                  let key = local.recognitionKey, TranscriptStore.validDigest(key) else { continue }
            let sidecar = AnalysisSidecar(source: track.file, identity: stamp)
            let cache = Self(sidecar: sidecar, key: key, evidence: track.evidence, stream: stream)
            guard let shared = cache.readExchange(), shared.result == local.result,
                  shared.activity == local.activity, sidecar.read(cache.section) == nil else { continue }
            do {
                let media = try CutEngine().inspectMulticamSource(track.file)
                guard track.sourceIsCurrent else { continue }
                try sidecar.saveTranscript(JSONEncoder().encode(shared), name: cache.section,
                                           media: media, cancelled: { false })
            } catch {
                // The independent result remains importable if its source folder is read-only.
            }
        }
    }

    func save(_ artifacts: Artifacts, media: MediaInfo, cancelled: () -> Bool) throws {
        guard artifacts.matches(key: key, evidence: evidence) else {
            throw transcriptError("The recognition result does not match its stream evidence or settings.")
        }
        guard media.identity == sidecar.identity, sidecar.identity.isCurrentSnapshot(at: sidecar.source),
              media.refreshEvidence != nil else {
            throw transcriptError("Fully indexed stream evidence is required to cache transcript results.",
                                  code: "missing_stream_evidence")
        }
        let encoded = try JSONEncoder().encode(artifacts)
        if !cancelled(), let url = exchangeURL, let exchange = try? JSONEncoder().encode(Exchange(artifacts)) {
            try? exchange.write(to: url, options: .atomic)
        }
        try sidecar.saveTranscript(encoded, name: section, media: media, cancelled: cancelled)
    }
}

/// A process releases its claims on exit. Sort claim IDs before acquisition so
/// two sessions with overlapping inputs can wait without deadlocking.
final class TranscriptRecognitionClaims {
    private var descriptors: [Int32] = []

    deinit {
        for descriptor in descriptors { close(descriptor) }
    }

    static func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("MPCut/Transcript Claims", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    func acquire(_ ids: Set<String>, cancelled: () -> Bool) throws {
        guard !ids.isEmpty else { return }
        try acquire(ids, in: Self.directory(), cancelled: cancelled)
    }

    func acquire(_ ids: Set<String>, in root: URL, cancelled: () -> Bool) throws {
        guard ids.allSatisfy(TranscriptStore.validDigest) else {
            throw transcriptError("Invalid shared recognition claim.", code: "transcript_cache_unavailable")
        }
        let first = descriptors.count
        var acquired = false
        defer {
            if !acquired {
                for descriptor in descriptors[first...] { close(descriptor) }
                descriptors.removeSubrange(first...)
            }
        }
        for id in ids.sorted() {
            let path = root.appendingPathComponent(id).path
            while true {
                if cancelled() { throw CancellationError() }
                let descriptor = open(path, O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o600)
                guard descriptor >= 0 else {
                    throw transcriptError("Could not open the shared recognition claim directory.", code: "transcript_cache_unavailable")
                }
                descriptors.append(descriptor)
                while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                    guard errno == EWOULDBLOCK || errno == EINTR else {
                        throw transcriptError("Could not lock the shared recognition cache.", code: "transcript_cache_unavailable")
                    }
                    if cancelled() { throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // Pruning removes an idle claim file. The claim counts only while its path
                // still names the locked file.
                if Self.names(path, descriptor) { break }
                descriptors.removeLast()
                close(descriptor)
            }
        }
        acquired = true
    }

    private static func names(_ path: String, _ descriptor: Int32) -> Bool {
        var held = stat(), named = stat()
        return fstat(descriptor, &held) == 0 && stat(path, &named) == 0
            && held.st_ino == named.st_ino && held.st_dev == named.st_dev
    }

    /// Removes each shared result, with its claim file, that was last written before the
    /// cutoff and that no process has claimed. Nothing else removes them: every recognized
    /// stream and settings combination leaves a result here for a standalone provider to reuse.
    static func prune(in directory: URL, olderThan age: TimeInterval, now: Date) -> Int {
        let manager = FileManager.default
        guard age > 0, let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        let cutoff = now.addingTimeInterval(-age)
        func isIdle(_ url: URL) -> Bool {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return true }
            return date < cutoff
        }
        let claims = Set(entries.compactMap { entry -> String? in
            guard ["", "json"].contains(entry.pathExtension) else { return nil }
            let name = entry.deletingPathExtension().lastPathComponent
            return TranscriptStore.validDigest(name) ? name : nil
        })
        var removed = 0
        for claim in claims.sorted() {
            let lock = directory.appendingPathComponent(claim)
            let exchange = lock.appendingPathExtension("json")
            guard isIdle(lock), isIdle(exchange) else { continue }
            let descriptor = open(lock.path, O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o600)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // A session holds its claims from lookup to publication.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0, names(lock.path, descriptor), isIdle(exchange) else { continue }
            if manager.fileExists(atPath: exchange.path), (try? manager.removeItem(at: exchange)) != nil { removed += 1 }
            try? manager.removeItem(at: lock)
        }
        return removed
    }
}
