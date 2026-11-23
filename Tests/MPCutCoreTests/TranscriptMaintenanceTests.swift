import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptMaintenanceTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-maintenance-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func wave(in folder: URL, name: String = "source.wav", channels: UInt16 = 1,
                      sample: (Int, Int) -> Int16 = { _, _ in 0 }) throws -> URL {
        let file = folder.appendingPathComponent(name)
        let frames = 16_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(frames * Int(channels) * 2 + 36))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(UInt32(16_000))
        append(UInt32(32_000) * UInt32(channels))
        append(channels * 2)
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(frames * Int(channels) * 2))
        for frame in 0..<frames {
            for channel in 0..<Int(channels) { append(sample(frame, channel)) }
        }
        try data.write(to: file)
        return file
    }

    private func helper(in folder: URL, session: String) throws -> URL {
        let file = folder.appendingPathComponent("helper")
        let revision = String(repeating: "a", count: 64)
        let script = """
        #!/bin/sh
        case "$1" in
          capabilities)
            printf '%s\\n' '{"version":"fixture","cache_revision":"provider","session_schema_version":1,"engines":[{"name":"qwen3","aliases":[],"included":true,"default_model":"fixture-model","diarization":false,"minimum_macos":"14.0","model_source":"hugging-face"}]}'
            ;;
          --cached-model)
            printf '[{"id":"fixture-model","cached":true,"path":"/unused","revision":"\(revision)"},{"id":"Qwen/Qwen3-ForcedAligner-0.6B","cached":true,"path":"/unused","revision":"\(revision)"}]\\n'
            ;;
          session) \(session) ;;
        esac
        """
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private struct EncodedActivity: Encodable {
        struct Frame: Encodable {
            let start_sample: Int64
            let end_sample: Int64
            let level: Float
        }
        let version = 1
        let sample_rate = 16_000
        let stream_evidence: String
        let duration_samples: Int64
        let activity: [Frame]
    }

    func testLevelDocumentEqualsTheGeneralEncoderOutput() throws {
        var generator = SystemRandomNumberGenerator()
        var levels: [Float] = [0, 1, 0.5, 0.1, 1e-5, 1.0e-7, 3.0517578e-05, 0.25, 0.999_999_9, .leastNonzeroMagnitude,
                               1.1754944e-38, 0.001, 0.000_123_456_78]
        levels += (0..<20_000).map { _ in Float.random(in: 0...1, using: &generator) }
        levels += (0..<20_000).map { _ in Float.random(in: 0...0.001, using: &generator) }
        // RMS of 16-bit PCM, including the quietest levels a window can hold.
        levels += (0..<5_000).map { (Float($0) / (32_768 * 32_768 * 320)).squareRoot() }
        for (evidence, tail) in [(String(repeating: "ab", count: 32), Int64(0)), ("un/us\"ual\\ \u{e9}\u{1}", 7)] {
            let duration = Int64(levels.count) * 320 - tail
            var start: Int64 = 0
            let frames = levels.map { level -> EncodedActivity.Frame in
                defer { start = min(duration, start + 320) }
                return .init(start_sample: start, end_sample: min(duration, start + 320), level: level)
            }
            let expected = try encodeJob(EncodedActivity(stream_evidence: evidence, duration_samples: duration, activity: frames))
            XCTAssertEqual(try transcriptActivityDocument(levels: levels, duration: duration, evidence: evidence), expected)
        }
        XCTAssertThrowsError(try transcriptActivityDocument(levels: [0.5], duration: 321, evidence: "a"))
        XCTAssertThrowsError(try transcriptActivityDocument(levels: [.nan], duration: 320, evidence: "a"))
    }

    func testExtractionReturnsItsLevelsAndTheChannelItFellBackTo() throws {
        let folder = try directory()
        let engine = CutEngine(useSidecar: false)
        let ordinary = try wave(in: folder, name: "ordinary.wav", channels: 2) { frame, channel in
            Int16(8_000 * sin(Double(frame) * (channel == 0 ? 0.2 : 0.31)))
        }
        let first = try engine.extractTranscriptAudio(engine.inspectMulticamSource(ordinary), stream: 0,
                                                      to: folder.appendingPathComponent("ordinary-staged.wav"))
        XCTAssertNil(first.downmixFallbackChannel)
        XCTAssertEqual(first.levels.count, 50)
        XCTAssertTrue(first.levels.allSatisfy { $0 > 0.05 && $0 < 0.3 })

        // The second channel is the louder half of an inverted pair.
        let inverted = try wave(in: folder, name: "inverted.wav", channels: 2) { frame, channel in
            Int16((channel == 0 ? 6_000 : -8_000) * sin(Double(frame) * 0.2))
        }
        let second = try engine.extractTranscriptAudio(engine.inspectMulticamSource(inverted), stream: 0,
                                                       to: folder.appendingPathComponent("inverted-staged.wav"))
        XCTAssertEqual(second.downmixFallbackChannel, 1)
        XCTAssertTrue(second.levels.allSatisfy { $0 > 0.15 })
        // A chosen channel is never replaced.
        let chosen = try engine.extractTranscriptAudio(engine.inspectMulticamSource(inverted), stream: 0, channel: 0,
                                                       to: folder.appendingPathComponent("chosen-staged.wav"))
        XCTAssertNil(chosen.downmixFallbackChannel)
    }

    func testRepeatedArtifactChecksAgreeWithTheFirst() throws {
        let levels = [Float](repeating: 0.25, count: 10)
        let evidence = String(repeating: "c", count: 64)
        let document = try transcriptActivityDocument(levels: levels, duration: 3_100, evidence: evidence)
        for _ in 0..<3 {
            XCTAssertTrue(TranscriptRecognitionCache.Artifacts.matchesActivity(document, evidence: evidence))
            XCTAssertTrue(TranscriptRecognitionCache.Artifacts.matchesActivity(document, evidence: evidence, duration: 3_100))
            XCTAssertFalse(TranscriptRecognitionCache.Artifacts.matchesActivity(document, evidence: evidence, duration: 3_200))
            XCTAssertFalse(TranscriptRecognitionCache.Artifacts.matchesActivity(document, evidence: "other"))
            var damaged = document
            damaged[damaged.count - 20] = UInt8(ascii: "x")
            XCTAssertFalse(TranscriptRecognitionCache.Artifacts.matchesActivity(damaged, evidence: evidence))
            let result = Data("""
            {"version":1,"sample_rate":16000,"recognition_key":"key","stream_evidence":"\(evidence)","duration_samples":3100,"words":[],"activity":[]}
            """.utf8)
            let artifacts = TranscriptRecognitionCache.Artifacts(result: result, activity: document)
            XCTAssertTrue(artifacts.matches(key: "key", evidence: evidence, needsActivity: true))
            XCTAssertFalse(artifacts.matches(key: "another", evidence: evidence, needsActivity: true))
            XCTAssertFalse(artifacts.matches(key: "key", evidence: "other", needsActivity: true))
            XCTAssertFalse(TranscriptRecognitionCache.Artifacts(result: result, activity: nil)
                .matches(key: "key", evidence: evidence))
        }
    }

    func testProviderCheckFailsBeforeAnyAudioIsStaged() throws {
        let folder = try directory()
        let provider = try helper(in: folder, session: "exit 1")
        XCTAssertNoThrow(try TranscriptJobStore.checkProvider(options: .init(), helper: provider))
        XCTAssertThrowsError(try TranscriptJobStore.checkProvider(options: .init(engine: "absent"), helper: provider)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_capability_missing")
        }
        XCTAssertThrowsError(try TranscriptJobStore.checkProvider(options: .init(language: "fr"), helper: provider)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_capability_missing")
        }
        XCTAssertThrowsError(try TranscriptJobStore.checkProvider(
            options: .init(), helper: folder.appendingPathComponent("missing-helper"))) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_helper_unavailable")
        }
    }

    func testSilentIdleHelperIsStoppedAndABusyOneIsNot() throws {
        let folder = try directory()
        let idle = folder.appendingPathComponent("idle")
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: idle)
        let busy = folder.appendingPathComponent("busy")
        // Works for several stall periods without writing a byte.
        try Data("#!/bin/sh\nend=$(( $(date +%s) + 5 ))\nwhile [ $(date +%s) -lt $end ]; do :; done\n".utf8).write(to: busy)
        for file in [idle, busy] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let began = ContinuousClock.now
        XCTAssertThrowsError(try TranscriptProviderCommand(helper: idle, directory: folder).run(["session"], stall: 1)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_provider_timeout")
        }
        XCTAssertLessThan(began.duration(to: .now), .seconds(30))
        let response = try TranscriptProviderCommand(helper: busy, directory: folder).run(["session"], stall: 2)
        XCTAssertEqual(response.exitStatus, 0)
    }

    func testHungSessionFailsTheJobAndLeavesItRetryable() throws {
        let folder = try directory()
        var store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        store.providerStallLimit = 1
        let provider = try helper(in: folder, session: "exec /bin/sleep 60")
        let source = try wave(in: folder)
        let (job, result) = try AnalysisSidecar.$readsEnabled.withValue(false) {
            let job = try store.prepare(media: source, documentID: "one")
            return (job, try store.run(job.id, helper: provider))
        }
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.message?.contains("stopped responding") == true, result.message ?? "")
        XCTAssertNil(result.helperPID)
        XCTAssertNil(result.ownerToken)
        XCTAssertEqual(try store.retry(job.id).state, .prepared)
    }

    func testPruneRemovesIdleJobsAndKeepsOwnedLockedRecentAndUnattachedOnes() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let source = try wave(in: folder)
        func job(_ document: String, _ change: (inout TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
            let record = try AnalysisSidecar.$readsEnabled.withValue(false) {
                try store.prepare(media: source, documentID: document)
            }
            return try store.update(record.id, change)
        }
        func exists(_ record: TranscriptJobRecord) -> [Bool] {
            [store.recordURL(record.id), record.workingDirectory,
             store.directory.appendingPathComponent(record.id.uuidString + ".lock")]
                .map { FileManager.default.fileExists(atPath: $0.path) }
        }
        let attached = try job("attached") { $0.state = .completed; $0.attached = true }
        let failed = try job("failed") { $0.state = .failed }
        let abandoned = try job("abandoned")
        let owned = try job("owned") { $0.state = .running; $0.ownerToken = UUID(); $0.ownerPID = getpid() }
        let crashed = try job("crashed") { $0.state = .running; $0.ownerToken = UUID(); $0.ownerPID = 1 }
        // A finished result that its document has yet to attach exists nowhere else.
        let waiting = try job(source.path) { $0.state = .completed }
        // An attached result of a document that still exists is what Reconcile reads.
        let reconcilable = try job(folder.path) { $0.state = .completed; $0.attached = true }
        let orphaned = try job("gone-document") { $0.state = .completed }
        let locked = try job("locked") { $0.state = .failed }
        let held = open(store.directory.appendingPathComponent(locked.id.uuidString + ".lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(held, 0)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        defer { close(held) }
        let strayLock = store.directory.appendingPathComponent(UUID().uuidString + ".lock")
        try Data().write(to: strayLock)
        // A folder whose record and lock are gone, last written long ago.
        let strayFolder = store.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: strayFolder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -50 * 86_400)],
                                              ofItemAtPath: strayFolder.path)
        let unrelated = store.directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)

        // Only the abandoned folder is old enough yet.
        XCTAssertEqual(try store.prune(olderThan: 30 * 86_400).map(\.uuidString), [strayFolder.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayFolder.path + ".lock"))
        XCTAssertEqual(try store.prune(olderThan: 0), [])
        let all = [attached, failed, abandoned, owned, crashed, waiting, reconcilable, orphaned, locked]
        XCTAssertTrue(all.allSatisfy { exists($0) == [true, true, true] })

        let later = Date().addingTimeInterval(40 * 86_400)
        let removed = Set(try store.prune(olderThan: 30 * 86_400, now: later))
        XCTAssertEqual(removed, Set([attached, failed, abandoned, crashed, orphaned].map(\.id)))
        for record in [attached, failed, abandoned, crashed, orphaned] {
            XCTAssertEqual(exists(record), [false, false, false], record.documentID)
        }
        for record in [owned, waiting, reconcilable, locked] {
            XCTAssertEqual(exists(record), [true, true, true], record.documentID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayLock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        // The kept jobs still work, and a discarded job leaves no lock behind.
        XCTAssertEqual(try store.status(waiting.id).state, .completed)
        _ = try store.update(owned.id) { $0.state = .failed; $0.ownerToken = nil; $0.ownerPID = nil }
        try store.discard(documentID: "owned")
        XCTAssertEqual(exists(owned), [false, false, false])
    }

    func testPruneRemovesIdleSharedResultsAndKeepsClaimedOnes() throws {
        let folder = try directory()
        let idle = String(repeating: "1", count: 64)
        let claimed = String(repeating: "2", count: 64)
        let unlocked = String(repeating: "3", count: 64)
        for name in [idle, idle + ".json", claimed, claimed + ".json", unlocked + ".json", "notes.txt", "short.json"] {
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }
        let claims = TranscriptRecognitionClaims()
        try claims.acquire([claimed], in: folder, cancelled: { false })
        func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) }
        let everything = try names()

        XCTAssertEqual(TranscriptJobStore.pruneSharedRecognition(in: folder, olderThan: 90 * 86_400), 0)
        XCTAssertEqual(try names(), everything)
        let later = Date().addingTimeInterval(100 * 86_400)
        XCTAssertEqual(TranscriptJobStore.pruneSharedRecognition(in: folder, olderThan: 90 * 86_400, now: later), 2)
        XCTAssertEqual(try names(), [claimed, claimed + ".json", "notes.txt", "short.json"])

        // A claim taken after its file was pruned locks the file that now carries the name.
        let next = TranscriptRecognitionClaims()
        try next.acquire([idle], in: folder, cancelled: { false })
        XCTAssertEqual(TranscriptJobStore.pruneSharedRecognition(in: folder, olderThan: 90 * 86_400, now: later), 0)
        XCTAssertTrue(try names().contains(idle))
        withExtendedLifetime((claims, next)) {}
    }

    func testFailedClaimAcquisitionReleasesEarlierClaims() throws {
        let folder = try directory()
        let available = String(repeating: "1", count: 64)
        let blocked = String(repeating: "2", count: 64)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(blocked),
                                                withIntermediateDirectories: false)
        let claims = TranscriptRecognitionClaims()
        XCTAssertThrowsError(try claims.acquire([available, blocked], in: folder, cancelled: { false }))

        let replacement = TranscriptRecognitionClaims()
        let deadline = Date().addingTimeInterval(1)
        XCTAssertNoThrow(try replacement.acquire([available], in: folder, cancelled: { Date() >= deadline }))
        withExtendedLifetime((claims, replacement)) {}
    }
}
