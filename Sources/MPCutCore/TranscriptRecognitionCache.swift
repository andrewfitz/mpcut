import CryptoKit
import Darwin
import Foundation

struct TranscriptRecognitionCache {
    struct Artifacts: Codable {
        let result: Data
        let activity: Data?

        var recognitionKey: String? {
            Self.checkedRecognition(result)?.key
        }

        /// Partial jobs can leave a valid track result before session assembly finishes.
        func belongs(to track: TranscriptJobTrack) -> Bool {
            guard let checked = Self.checkedRecognition(result), checked.evidence == track.evidence,
                  let duration = try? track.duration.roundedToSamples(16_000), duration == checked.duration else { return false }
            return true
        }

        func matches(key: String, evidence: String?, needsActivity: Bool = false) -> Bool {
            guard let result = Self.checkedRecognition(result),
                  result.key == key, evidence == nil || result.evidence == evidence else { return false }
            guard let activity else {
                return !needsActivity && result.embedsLevels
            }
            return Self.matchesActivity(activity, evidence: result.evidence, duration: result.duration)
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

        fileprivate static func valid(_ levels: [TranscriptNativeSession.Activity], duration: Int64) -> Bool {
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
            var hash = SHA256()
            hash.update(data: result)
            hash.update(data: Data([0]))
            if let activity { hash.update(data: activity) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
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

    static func providerActivity(for track: TranscriptJobTrack) throws -> [TranscriptActivityFrame] {
        let duration = try track.duration.roundedToSamples(16_000)
        var frames: [TranscriptNativeSession.Activity] = []
        if let data = track.activity.flatMap(TranscriptJobArtifact.read),
           track.measuredActivitySHA256 != TranscriptStore.digest(data),
           Artifacts.matchesActivity(data, evidence: track.evidence, duration: duration) {
            frames = try JSONDecoder().decode(Levels.self, from: data).activity
        } else if let data = track.result.flatMap(TranscriptJobArtifact.read),
                  let result = try? JSONDecoder().decode(Recognition.self, from: data),
                  result.version == 1, result.stream_evidence == track.evidence, result.sample_rate == 16_000,
                  result.duration_samples == duration, Artifacts.valid(result.activity, duration: duration) {
            frames = result.activity
        }
        return try frames.map { frame in
            let bounds = try TranscriptNativeSession.Bounds(start: frame.start_sample, end: frame.end_sample,
                                                           rate: 16_000, origin: track.origin)
            return .init(start: bounds.start, end: bounds.end, level: frame.level)
        }
    }

    let key: String
    let evidence: String
    /// The highest exchange version the provider's capabilities say it reads. A provider
    /// that says nothing reads version 1, and is written that.
    var providerExchangeVersion = 1

    var claimID: String {
        TranscriptExternalCacheDescriptor.claimID(scope: evidence, key: key)
    }

    func read(cancelled: () -> Bool) -> Artifacts? {
        guard !cancelled() else { return nil }
        if let shared = readExchange(cancelled: cancelled) { return shared }
        guard let folder = try? archiveDirectory() else { return nil }
        return Self.readArchive(in: folder, cancelled: cancelled) {
            $0.matches(key: key, evidence: evidence)
        }
    }

    static func readPreserved(track: TranscriptJobTrack, key: String, in jobResults: URL,
                              cancelled: () -> Bool) -> Artifacts? {
        readArchive(in: trackArchive(track, in: jobResults), cancelled: cancelled) {
            $0.belongs(to: track) && $0.matches(key: key, evidence: track.evidence, needsActivity: track.activity != nil)
        }
    }

    private static func readArchive(in folder: URL, cancelled: () -> Bool,
                                    matching: (Artifacts) -> Bool) -> Artifacts? {
        guard !cancelled(),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if cancelled() { return nil }
            guard let candidate = Self.decodeFile(file, cancelled: cancelled),
                  matching(candidate), digest(candidate) == file.lastPathComponent else { continue }
            return candidate
        }
        return nil
    }

    private func archiveDirectory() throws -> URL {
        guard TranscriptStore.validDigest(key) else { throw transcriptError("Invalid recognition key.") }
        return try TranscriptRecognitionClaims.directory().appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private static func digest(_ value: Artifacts) -> String {
        Exchange.digest(result: value.result, activity: value.activity)
    }

    private static func decodeFile(_ file: URL, cancelled: () -> Bool) -> Artifacts? {
        guard !cancelled(), let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        if let pair = try? TranscriptRecognitionExchange.decode(bytes, cancelled: cancelled) {
            return .init(result: pair.result, activity: pair.activity)
        }
        return (try? JSONDecoder().decode(Exchange.self, from: bytes))?.artifacts
    }

    /// The lookup key describes a track and the recognition settings. Each result under it
    /// is immutable, including earlier results when a provider repeats a run.
    private func archive(_ value: Artifacts, cancelled: () -> Bool) throws {
        guard value.matches(key: key, evidence: evidence) else {
            throw transcriptError("The recognition result does not match its stream evidence or settings.")
        }
        try Self.archive(value, in: archiveDirectory(), cancelled: cancelled)
    }

    private static func archive(_ value: Artifacts, in directory: URL, cancelled: () -> Bool) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let digest = Self.digest(value)
        let file = directory.appendingPathComponent(digest)
        func verified() -> Bool {
            guard let copy = Self.decodeFile(file, cancelled: cancelled) else { return false }
            return copy.result == value.result && copy.activity == value.activity
        }
        if verified() { return }
        let data = try TranscriptRecognitionExchange.encode(result: value.result, activity: value.activity,
                                                             cancelled: cancelled) ?? JSONEncoder().encode(Exchange(value))
        try data.write(to: file, options: .atomic)
        try checkSidecarCancellation(cancelled)
        guard verified() else { throw transcriptError("The saved recognition result could not be verified.") }
    }

    /// Before changing a preparation, retain completed tracks even when the session
    /// stopped before it produced a transcript. Incomplete stream proof scopes them to this job.
    static func preserve(track: TranscriptJobTrack, in jobResults: URL, cancelled: () -> Bool) throws {
        guard let result = track.result, let value = Artifacts(job: result, activity: track.activity),
              value.belongs(to: track) else { return }
        if track.hasReusableEvidence, let key = value.recognitionKey, TranscriptStore.validDigest(key),
           value.matches(key: key, evidence: track.evidence) {
            do {
                try Self(key: key, evidence: track.evidence).archive(value, cancelled: cancelled)
                return
            } catch {
                try checkSidecarCancellation(cancelled)
                // Keep the job's result locally when the shared store is unavailable.
            }
        }
        try archive(value, in: trackArchive(track, in: jobResults), cancelled: cancelled)
    }

    private static func trackArchive(_ track: TranscriptJobTrack, in jobResults: URL) -> URL {
        let name = TranscriptStore.digest(Data(track.id.utf8))
        return jobResults.appendingPathComponent("Tracks").appendingPathComponent(name)
    }

    /// Either program may have written either version. A current file that is damaged or
    /// describes other settings leaves the earlier one to answer.
    private func readExchange(cancelled: () -> Bool = { false }) -> Artifacts? {
        if !cancelled(), let url = exchangeURL(TranscriptRecognitionExchange.fileExtension),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe), !cancelled(),
           let exchange = try? TranscriptRecognitionExchange.decode(data, cancelled: cancelled), !cancelled() {
            let artifacts = Artifacts(result: exchange.result, activity: exchange.activity)
            if artifacts.matches(key: key, evidence: evidence), !cancelled() { return artifacts }
        }
        guard !cancelled(), let url = exchangeURL(TranscriptRecognitionExchange.legacyExtension),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !cancelled(), let exchange = try? JSONDecoder().decode(Exchange.self, from: data),
              !cancelled(), let artifacts = exchange.artifacts,
              !cancelled(), artifacts.matches(key: key, evidence: evidence), !cancelled() else { return nil }
        return artifacts
    }

    private func exchangeURL(_ pathExtension: String) -> URL? {
        try? TranscriptRecognitionClaims.directory().appendingPathComponent(claimID + "." + pathExtension)
    }

    /// Writes the version the provider reads, then removes the other one. A run saves only
    /// what no copy answered, so a file left in the other version is stale or repeats this.
    private func writeExchange(_ artifacts: Artifacts, cancelled: () -> Bool) throws {
        let current = providerExchangeVersion >= TranscriptRecognitionExchange.version
        guard !cancelled(),
              let url = exchangeURL(current ? TranscriptRecognitionExchange.fileExtension
                                            : TranscriptRecognitionExchange.legacyExtension),
              let other = exchangeURL(current ? TranscriptRecognitionExchange.legacyExtension
                                              : TranscriptRecognitionExchange.fileExtension) else { return }
        let file = current
            ? try? TranscriptRecognitionExchange.encode(result: artifacts.result, activity: artifacts.activity,
                                                        cancelled: cancelled)
            : try? JSONEncoder().encode(Exchange(artifacts))
        try checkSidecarCancellation(cancelled)
        guard let file, (try? file.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.removeItem(at: other)
    }

    /// A standalone provider can publish only the track files and a session result.
    static func promoteExternal(in record: TranscriptJobRecord, stamps: [String: SourceIdentity],
                                recognizedIDs: Set<String>, jobResults: URL) throws {
        for track in record.sessions.flatMap(\.tracks) {
            guard recognizedIDs.contains(track.id),
                  let stamp = stamps[track.id], stamp.isCurrentSnapshot(at: track.file) else { continue }
            try preserve(track: track, in: jobResults, cancelled: { false })
        }
    }

    func save(_ artifacts: Artifacts, cancelled: () -> Bool) throws {
        try checkSidecarCancellation(cancelled)
        try archive(artifacts, cancelled: cancelled)
        // A standalone reader can have published a different result for these settings.
        // Its exchange stays current while this generation is retained by digest.
        if readExchange(cancelled: cancelled) == nil {
            try writeExchange(artifacts, cancelled: cancelled)
        }
    }
}

/// A process releases its claims on exit. Sort claim IDs before acquisition so
/// two sessions with overlapping inputs can wait without deadlocking.
final class TranscriptRecognitionClaims {
    private var descriptors: [Int32] = []

    deinit {
        for descriptor in descriptors { close(descriptor) }
    }

    /// Production GUI, CLI and a standalone provider share one folder. A test process keeps
    /// its claims and results out of it without changing the user's own.
    private static let testDirectory: URL? = {
        guard NSClassFromString("XCTestCase") != nil || CommandLine.arguments[0].contains("xctest") else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("mpcut-test-claims-" + UUID().uuidString, isDirectory: true)
    }()

    static func directory() throws -> URL {
        let root: URL
        // Read the override on each call. A test sets it for itself and for the processes
        // it starts, which must exchange results in the same folder.
        if let path = getenv("MPCUT_TRANSCRIPT_CLAIMS_HOME").map({ String(cString: $0) }), path.hasPrefix("/") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else if let testDirectory {
            root = testDirectory
        } else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
                .appendingPathComponent("MPCut/Transcript Claims", isDirectory: true)
        }
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

    /// Providers read the published exchange directly. Keep it reachable even when the
    /// project moved or another job attached the same track. Reclaim abandoned lock files.
    static func prune(in directory: URL, olderThan age: TimeInterval, now: Date) -> Int {
        let manager = FileManager.default
        guard age > 0, let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        let cutoff = now.addingTimeInterval(-age)
        let versions = [TranscriptRecognitionExchange.legacyExtension, TranscriptRecognitionExchange.fileExtension]
        for lock in entries where TranscriptStore.validDigest(lock.lastPathComponent) {
            guard let date = (try? lock.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date < cutoff else { continue }
            let descriptor = open(lock.path, O_NOFOLLOW | O_CLOEXEC | O_RDWR)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0, names(lock.path, descriptor),
                  versions.allSatisfy({ !manager.fileExists(atPath: lock.appendingPathExtension($0).path) }) else { continue }
            try? manager.removeItem(at: lock)
        }
        return 0
    }
}
