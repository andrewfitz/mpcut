import CryptoKit
import Darwin
import Foundation

struct TranscriptRecognitionCache {
    private static let legacyPrefix = "transcript_recognition.v1."
    private static let prefix = "transcript_recognition.v2."

    struct Artifacts: Codable {
        let result: Data
        let activity: Data?

        var recognitionKey: String? {
            Self.checkedRecognition(result)?.key
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

    let sidecar: AnalysisSidecar
    let key: String
    let evidence: String
    let stream: Int
    var channel: Int? = nil
    /// The highest exchange version the provider's capabilities say it reads. A provider
    /// that says nothing reads version 1, and is written that.
    var providerExchangeVersion = 1

    var section: String { "\(Self.prefix)\(stream).\(key)" }
    var claimID: String {
        TranscriptExternalCacheDescriptor.claimID(
            scope: TranscriptExternalCacheDescriptor.scope(for: sidecar.source, stream: stream), key: key)
    }

    static func stream(forKey key: String) -> Int? {
        guard let prefix = [prefix, legacyPrefix].first(where: { key.hasPrefix($0) }) else { return nil }
        let components = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2, let stream = Int(components[0]), stream >= 0,
              TranscriptStore.validDigest(String(components[1])) else { return nil }
        return stream
    }

    func read(cancelled: () -> Bool) -> Artifacts? {
        guard AnalysisSidecar.readsEnabled, !sidecar.isExcluded else { return nil }
        if let hit = readSidecar(cancelled: cancelled) { return hit }
        return readExchange(cancelled: cancelled)
    }

    private var legacySection: String { "\(Self.legacyPrefix)\(stream).\(key)" }

    // An empty first line means the result contains its levels. Otherwise the first
    // line identifies an immutable activity section shared by recognition settings.
    // The rest is the exact original result, including its provider-specific fields.
    private func artifacts(from record: Data, read: (String) -> Data?,
                           alternateLevels: (String) -> Data? = { _ in nil }) -> Artifacts? {
        guard let split = record.prefix(65).firstIndex(of: 10) else { return nil }
        let result = Data(record.suffix(from: split + 1))
        if split == record.startIndex { return Artifacts(result: result, activity: nil) }
        let digest = String(decoding: record[..<split], as: UTF8.self)
        guard TranscriptStore.validDigest(digest) else { return nil }
        if let levels = read(activitySection(digest)), TranscriptStore.digest(levels) == digest {
            return Artifacts(result: result, activity: levels)
        }
        let key = TranscriptActivityKey(stream: stream, channel: channel)
        if let name = try? AnalysisSidecar.transcriptActivitySection(key),
           let alternate = read(name), TranscriptStore.digest(alternate) == digest {
            return Artifacts(result: result, activity: alternate)
        }
        return alternateLevels(digest).map { Artifacts(result: result, activity: $0) }
    }

    /// Copy the paid result and its exact levels as one immutable group.
    /// An extraction alias may be the last surviving copy of a referenced digest.
    static func merge(from peer: AnalysisSidecar.CopySnapshot, into target: AnalysisSidecar.CopySnapshot,
                      peerKeys: [String], cancelled: () -> Bool) throws {
        let targetKeys = try AnalysisSidecar.sectionNames(in: target.db)
        let names = Set(targetKeys + peerKeys).filter { stream(forKey: $0) != nil }
        guard !names.isEmpty else { return }
        func read(_ name: String, _ snapshot: AnalysisSidecar.CopySnapshot) -> Data? {
            try? snapshot.store.verifiedSection(name, in: snapshot.db, stamp: snapshot.stamp, maxBytes: nil, cancelled: cancelled)
        }
        func proof(_ snapshot: AnalysisSidecar.CopySnapshot) -> MediaRefreshEvidence? {
            MediaRefreshEvidence.decode(try? snapshot.store.verifiedSection(AnalysisSidecar.evidenceKey, in: snapshot.db,
                stamp: snapshot.stamp, maxBytes: 16 * 1024 * 1024, cancelled: cancelled))
        }
        let media = [target.store.sourceEvidence, proof(target), proof(peer)].compactMap { $0 }
        var streamProofs: [Int: String] = [:]
        for name in names {
            try checkSidecarCancellation(cancelled)
            guard let stream = stream(forKey: name), let suffix = name.split(separator: ".").last else { continue }
            let key = String(suffix)
            if let index = media.first, !index.streams.indices.contains(stream) || index.streams[stream].kind != "audio" {
                continue
            }
            if streamProofs[stream] == nil {
                for index in media {
                    if let proof = try TranscriptJobPlan.streamEvidence(index, streamIndex: stream) {
                        streamProofs[stream] = proof
                        break
                    }
                }
            }
            let evidence = streamProofs[stream]
            let cache = Self(sidecar: target.store, key: key, evidence: evidence ?? "", stream: stream)
            let local = read(name, target)
            func validated(_ bytes: Data?, in snapshot: AnalysisSidecar.CopySnapshot) -> Artifacts? {
                guard let bytes else { return nil }
                let artifact: Artifacts?
                if name.hasPrefix(legacyPrefix) {
                    artifact = try? JSONDecoder().decode(Artifacts.self, from: bytes)
                } else {
                    artifact = cache.artifacts(from: bytes, read: { read($0, snapshot) }) { digest in
                        // A digest-verified dependency can also be recovered from another copy.
                        let alternate = snapshot.db === target.db ? peer : target
                        if let levels = read(cache.activitySection(digest), alternate), TranscriptStore.digest(levels) == digest {
                            return levels
                        }
                        let prefix = "transcript_activity.v1.\(stream)."
                        for (copy, keys) in [(target, targetKeys), (peer, peerKeys)] {
                            for candidate in keys where candidate.hasPrefix(prefix) {
                                if cancelled() { return nil }
                                if let levels = read(candidate, copy), TranscriptStore.digest(levels) == digest { return levels }
                            }
                        }
                        return nil
                    }
                }
                guard let artifact, artifact.matches(key: key, evidence: evidence) else { return nil }
                return artifact
            }
            let chosen: Artifacts
            if let existing = validated(local, in: target) {
                chosen = existing
            } else {
                guard let incoming = read(name, peer), let valid = validated(incoming, in: peer) else { continue }
                chosen = valid
                if local != incoming {
                    try target.store.writeSection(name, value: incoming, db: target.db, stamp: target.stamp, cancelled: cancelled)
                    let change = try peer.store.changeTime(name, in: peer.db, at: peer.store.url)
                    try target.store.setChangeTime(change, key: name, in: target.db)
                }
            }
            if name.hasPrefix(prefix), let levels = chosen.activity {
                let dependency = cache.activitySection(TranscriptStore.digest(levels))
                if read(dependency, target) != levels {
                    try target.store.writeSection(dependency, value: levels, db: target.db, stamp: target.stamp, cancelled: cancelled)
                }
            }
        }
    }

    func readSidecar(cancelled: () -> Bool) -> Artifacts? {
        guard AnalysisSidecar.readsEnabled, !cancelled() else { return nil }
        // Read a result and its levels together, then release SQLite before parsing
        // provider output. A valid checksum alone cannot identify the right stream.
        for store in sidecar.readCandidates(orderedBy: section) {
            guard !cancelled() else { return nil }
            let candidate: Artifacts? = try? store.withReadSnapshot(cancelled: cancelled) { read in
                guard let record = read(section) else { return nil }
                return artifacts(from: record, read: read)
            }
            if let candidate, candidate.matches(key: key, evidence: evidence), !cancelled(),
               sidecar.identity.isCurrentSnapshot(at: sidecar.source) { return candidate }
        }
        for store in sidecar.readCandidates(orderedBy: legacySection) {
            guard !cancelled() else { return nil }
            if let bytes = store.read(legacySection, cancelled: cancelled),
               let candidate = try? JSONDecoder().decode(Artifacts.self, from: bytes),
               candidate.matches(key: key, evidence: evidence), !cancelled(),
               sidecar.identity.isCurrentSnapshot(at: sidecar.source) { return candidate }
        }
        return nil
    }

    private func activitySection(_ digest: String) -> String {
        "transcript_activity.v1.\(stream).\(digest)"
    }

    private func validatedEvidence(for artifacts: Artifacts, media: MediaInfo) throws -> MediaRefreshEvidence {
        guard media.identity.matchesSnapshot(sidecar.identity), let evidence = media.refreshEvidence else {
            throw transcriptError("Fully indexed stream evidence is required to cache transcript results.",
                                  code: "missing_stream_evidence")
        }
        guard try TranscriptJobPlan.streamEvidence(evidence, streamIndex: stream) == self.evidence,
              artifacts.matches(key: key, evidence: self.evidence) else {
            throw transcriptError("The recognition result does not match its stream evidence or settings.")
        }
        return evidence
    }

    func saveSidecar(_ artifacts: Artifacts, media: MediaInfo, cancelled: () -> Bool) throws {
        try checkSidecarCancellation(cancelled)
        let evidence = try validatedEvidence(for: artifacts, media: media)
        try saveSidecar(artifacts, evidence: evidence, cancelled: cancelled)
    }

    private func saveSidecar(_ artifacts: Artifacts, evidence: MediaRefreshEvidence, cancelled: () -> Bool) throws {
        let digest = artifacts.activity.map(TranscriptStore.digest) ?? ""
        var record = Data(digest.utf8)
        record.append(10)
        record.append(artifacts.result)
        try sidecar.transact([AnalysisSidecar.evidenceKey: evidence.encoded()], cancelled: cancelled) { db, stamp in
            let prior = try sidecar.verifiedSection(section, in: db, stamp: stamp, maxBytes: nil, cancelled: cancelled)
            if prior != record {
                if let prior, let existing = self.artifacts(from: prior, read: { name in
                    try? sidecar.verifiedSection(name, in: db, stamp: stamp, maxBytes: nil, cancelled: cancelled)
                }, alternateLevels: { requested in requested == digest ? artifacts.activity : nil }),
                   existing.matches(key: key, evidence: self.evidence) {
                    // An arriving retry can restore a surviving result's missing levels.
                    guard let levels = existing.activity, levels == artifacts.activity else { return }
                } else {
                    try sidecar.writeSection(section, value: record, db: db, stamp: stamp, cancelled: cancelled)
                }
            }
            if let levels = artifacts.activity,
               try !extractionSectionHolds(levels, in: db, stamp: stamp, cancelled: cancelled) {
                // Equal bytes already under the content name leave that row as it is.
                try sidecar.writeSection(activitySection(digest), value: levels, db: db, stamp: stamp, cancelled: cancelled)
            }
        }
    }

    /// Staging saves a track's levels under its extraction key before the track is recognized,
    /// and a record reads its levels under either name. A section's checksum covers its name
    /// and bytes, so different levels are told apart without reading them. Equal ones are
    /// read once, because a damaged copy cannot stand in for the record's levels.
    private func extractionSectionHolds(_ levels: Data, in db: SidecarDatabase, stamp: String,
                                        cancelled: () -> Bool) throws -> Bool {
        let key = TranscriptActivityKey(stream: stream, channel: channel)
        guard let name = try? AnalysisSidecar.transcriptActivitySection(key) else { return false }
        let checksum = try levels.withUnsafeBytes { try sidecar.checksum(name, stamp: stamp, $0, cancelled: cancelled) }
        return try sidecar.verifiedSection(name, in: db, stamp: stamp, maxBytes: levels.count, cancelled: cancelled,
                                           matchingDigest: checksum) != nil
    }

    /// A record saved while the extraction section held its levels has no other copy of them.
    /// Before different levels replace that section, keep the outgoing bytes under their
    /// content name if a record for the stream still names them.
    static func retainReferencedLevels(at name: String, stream: Int, replacement: Data, in sidecar: AnalysisSidecar,
                                       db: SidecarDatabase, stamp: String, cancelled: () -> Bool) throws {
        guard let outgoing = try sidecar.verifiedSection(name, in: db, stamp: stamp, maxBytes: nil, cancelled: cancelled),
              outgoing != replacement else { return }
        let digest = TranscriptStore.digest(outgoing)
        let reference = Data((digest + "\n").utf8)
        let records = "\(prefix)\(stream)."
        for record in try AnalysisSidecar.sectionNames(in: db) where record.hasPrefix(records) {
            try checkSidecarCancellation(cancelled)
            guard let bytes = try sidecar.verifiedSection(record, in: db, stamp: stamp, maxBytes: nil, cancelled: cancelled),
                  bytes.starts(with: reference) else { continue }
            try sidecar.writeSection("transcript_activity.v1.\(stream).\(digest)", value: outgoing, db: db, stamp: stamp,
                                     cancelled: cancelled)
            return
        }
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

    /// The standalone helper writes only the exchange. Import mirrors a
    /// matching helper artifact into the normal analysis sidecar.
    static func promoteExternal(in record: TranscriptJobRecord, stamps: [String: SourceIdentity],
                                recognizedIDs: Set<String>) {
        guard AnalysisSidecar.readsEnabled, AnalysisSidecar.automaticWritesEnabled else { return }
        for track in record.sessions.flatMap(\.tracks) {
            guard recognizedIDs.contains(track.id), track.hasReusableEvidence, track.sourceIsCurrent,
                  !AnalysisSidecar.isExcluded(track.file, in: AnalysisSidecar.excludedSources), let stream = track.streamIndex,
                  let stamp = stamps[track.id], let result = track.result,
                  // A finished job keeps a track's files packed, and is verified again.
                  let local = Artifacts(job: result, activity: track.activity),
                  let key = local.recognitionKey, TranscriptStore.validDigest(key) else { continue }
            let sidecar = AnalysisSidecar(source: track.file, identity: stamp)
            let cache = Self(sidecar: sidecar, key: key, evidence: track.evidence, stream: stream, channel: track.stagedChannel)
            guard cache.readSidecar(cancelled: { false }) == nil,
                  let shared = cache.readExchange(), shared.result == local.result,
                  shared.activity == local.activity else { continue }
            do {
                let media = try CutEngine().inspectMulticamSource(track.file)
                guard track.sourceIsCurrent else { continue }
                try cache.saveSidecar(shared, media: media, cancelled: { false })
            } catch {
                // The independent result remains importable if its source folder is read-only.
            }
        }
    }

    func save(_ artifacts: Artifacts, media: MediaInfo, cancelled: () -> Bool) throws {
        try checkSidecarCancellation(cancelled)
        let evidence = try validatedEvidence(for: artifacts, media: media)
        guard sidecar.identity.isCurrentSnapshot(at: sidecar.source) else {
            throw transcriptError("The recording changed before its transcript result could be cached.",
                                  code: "missing_stream_evidence")
        }
        try checkSidecarCancellation(cancelled)
        try writeExchange(artifacts, cancelled: cancelled)
        try saveSidecar(artifacts, evidence: evidence, cancelled: cancelled)
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

    /// Removes each shared result, with its claim file, that was last written before the
    /// cutoff and that no process has claimed. Nothing else removes them: every recognized
    /// stream and settings combination leaves a result here for a standalone provider to reuse.
    /// A claim file that a failed or cancelled run left without a result goes the same way.
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
        // A result is in either exchange version, or in both after a change of provider.
        let versions = [TranscriptRecognitionExchange.legacyExtension, TranscriptRecognitionExchange.fileExtension]
        let claims = Set(entries.compactMap { entry -> String? in
            guard entry.pathExtension.isEmpty || versions.contains(entry.pathExtension) else { return nil }
            let name = entry.deletingPathExtension().lastPathComponent
            return TranscriptStore.validDigest(name) ? name : nil
        })
        var removed = 0
        for claim in claims.sorted() {
            let lock = directory.appendingPathComponent(claim)
            let exchanges = versions.map { lock.appendingPathExtension($0) }
            guard isIdle(lock), exchanges.allSatisfy(isIdle) else { continue }
            let descriptor = open(lock.path, O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o600)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // A session holds its claims from lookup to publication.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0, names(lock.path, descriptor),
                  exchanges.allSatisfy(isIdle) else { continue }
            let results = exchanges.filter {
                manager.fileExists(atPath: $0.path) && (try? manager.removeItem(at: $0)) != nil
            }
            if !results.isEmpty { removed += 1 }
            try? manager.removeItem(at: lock)
        }
        return removed
    }
}
