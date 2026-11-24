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

    func testTranscriptSavesRejectEvidenceFromRewrittenMedia() throws {
        let folder = try directory()
        let file = try wave(in: folder)
        let original = try CutEngine(useSidecar: false).inspectMulticamSource(file)
        var statBefore = stat()
        XCTAssertEqual(stat(file.path, &statBefore), 0)
        _ = try wave(in: folder) { _, _ in 1 }
        let times = [statBefore.st_atimespec, statBefore.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, file.path, $0.baseAddress, 0) }, 0)
        let sidecar = try AnalysisSidecar(source: file)
        XCTAssertEqual(original.identity, sidecar.identity)
        XCTAssertFalse(original.identity.matchesSnapshot(sidecar.identity))
        let key = TranscriptActivityKey(stream: 0)
        XCTAssertThrowsError(try sidecar.saveTranscriptActivity(Data(), key: key, media: original))
        let recognition = TranscriptRecognitionCache(sidecar: sidecar, key: String(repeating: "a", count: 64),
                                                     evidence: "old evidence", stream: 0)
        let artifacts = TranscriptRecognitionCache.Artifacts(result: Data(), activity: nil)
        XCTAssertThrowsError(try recognition.saveSidecar(artifacts, media: original, cancelled: { false }))
        XCTAssertNil(sidecar.readTranscriptActivity(key))
        XCTAssertNil(sidecar.read(recognition.section))
    }

    func testNewerRecognitionWithWrongStreamEvidenceFallsBackToCompatibleCopy() throws {
        let folder = try directory()
        let source = try wave(in: folder)
        let key = String(repeating: "a", count: 64)

        let document = folder.appendingPathComponent("edit.cut")
        func bytes(_ stamp: String) -> Data {
            Data("""
            {"version":1,"sample_rate":16000,"recognition_key":"\(key)","stream_evidence":"\(stamp)","duration_samples":320,"words":[],"activity":[{"start_sample":0,"end_sample":320,"level":0.5}]}
            """.utf8)
        }
        try SidecarLocations.$storageDirectory.withValue(folder.appendingPathComponent("prefs")) {
            try SidecarLocations.$projectURL.withValue(document) {
                let media = try CutEngine().inspectMulticamSource(source)
                let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: media, streamIndex: 0))
                let adjacent = AnalysisSidecar(media: media)
                let good = TranscriptRecognitionCache(sidecar: adjacent, key: key, evidence: evidence, stream: 0)
                let original = TranscriptRecognitionCache.Artifacts(result: bytes(evidence), activity: nil)
                try good.saveSidecar(original, media: media, cancelled: { false })
                try SidecarLocations.setMode(.project)
                let project = try AnalysisSidecar(source: source)
                let reader = TranscriptRecognitionCache(sidecar: project, key: key, evidence: evidence, stream: 0)
                try project.save([reader.section: Data([10]) + bytes("other-stream")])
                XCTAssertEqual(reader.readSidecar(cancelled: { false })?.result, original.result)
            }
        }
    }

    func testUnrelatedSaveKeepsPaidRecognitionAcrossCopiesAndRepairsBadSeed() throws {
        for defect in ["wrong stream", "missing activity", "inconsistent activity"] {
            let folder = try directory()
            let source = try wave(in: folder)
            let disk = folder.appendingPathComponent("disk", isDirectory: true)
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
            try SidecarLocations.$storageDirectory.withValue(folder.appendingPathComponent("prefs")) {
                try SidecarLocations.$projectURL.withValue(folder.appendingPathComponent("edit.cut")) {
                    let media = try CutEngine().inspectMulticamSource(source)
                    let key = String(repeating: "a", count: 64)
                    let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: media, streamIndex: 0))
                    func cache(_ sidecar: AnalysisSidecar) -> TranscriptRecognitionCache {
                        TranscriptRecognitionCache(sidecar: sidecar, key: key, evidence: evidence, stream: 0)
                    }
                    func result(_ proof: String) -> Data {
                        Data("""
                        {"version":1,"sample_rate":16000,"recognition_key":"\(key)","stream_evidence":"\(proof)","duration_samples":320,"words":[],"activity":[]}
                        """.utf8)
                    }
                    let paid = result(evidence)
                    let levels = try transcriptActivityDocument(levels: [0.25], duration: 320, evidence: evidence)
                    let digest = TranscriptStore.digest(levels)
                    let address = "transcript_activity.v1.0." + digest
                    let artifacts = TranscriptRecognitionCache.Artifacts(result: paid, activity: levels)
                    let adjacent = AnalysisSidecar(media: media)
                    try cache(adjacent).saveSidecar(artifacts, media: media, cancelled: { false })
                    try SidecarLocations.setMode(.project)
                    let project = try AnalysisSidecar(source: source)
                    let record = cache(project).section
                    var bad = [address: Data("bad levels".utf8)]
                    switch defect {
                    case "wrong stream":
                        bad[record] = Data((digest + "\n").utf8) + result("other")
                    case "missing activity":
                        bad[record] = Data((String(repeating: "e", count: 64) + "\n").utf8) + paid
                    default:
                        let mismatched = try transcriptActivityDocument(levels: [0.6], duration: 320, evidence: "other")
                        let mismatchedDigest = TranscriptStore.digest(mismatched)
                        bad["transcript_activity.v1.0." + mismatchedDigest] = mismatched
                        bad[record] = Data((mismatchedDigest + "\n").utf8) + paid
                    }
                    try project.save(bad)
                    XCTAssertNil(cache(project.pinned(to: project.url)).readSidecar(cancelled: { false }), defect)
                    // The latest physical DB is the defective project copy.
                    try SidecarLocations.chooseDisk(disk, selecting: true)
                    let third = try AnalysisSidecar(source: source)
                    try third.save(["unrelated": Data([1])])
                    for copy in [third, adjacent] {
                        try copy.save(["unrelated": Data([2])])
                        let pinned = cache(copy.pinned(to: copy.url))
                        XCTAssertEqual(pinned.readSidecar(cancelled: { false })?.result, paid, defect)
                        XCTAssertEqual(pinned.readSidecar(cancelled: { false })?.activity, levels, defect)
                    }
                    let damaged = cache(project.pinned(to: project.url))
                    try damaged.saveSidecar(artifacts, media: media, cancelled: { false })
                    XCTAssertEqual(damaged.readSidecar(cancelled: { false })?.activity, levels, defect)
                    let another = TranscriptRecognitionCache.Artifacts(result: paid + Data([10]), activity: levels)
                    try damaged.saveSidecar(another, media: media, cancelled: { false })
                    XCTAssertEqual(damaged.readSidecar(cancelled: { false })?.result, paid, defect)
                }
            }
        }
    }

    func testRecognitionSettingsShareExactLevelsAndReadLegacyArtifacts() throws {
        let folder = try directory()
        let source = try wave(in: folder)
        let media = try CutEngine().inspectMulticamSource(source)
        let sidecar = AnalysisSidecar(media: media)
        let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: media, streamIndex: 0))
        let count = 18_000
        let duration = Int64(count * 320)
        let levels = try transcriptActivityDocument(levels: (0..<count).map { Float(($0 * 37) % 1009) / 1009 },
                                                    duration: duration, evidence: evidence)
        let activityKey = TranscriptActivityKey(stream: 0)
        try sidecar.saveTranscriptActivity(levels, key: activityKey, media: media)
        let caches = ["a", "b"].map {
            TranscriptRecognitionCache(sidecar: sidecar, key: String(repeating: $0, count: 64), evidence: evidence, stream: 0)
        }
        let artifacts = caches.map { cache in
            let result = Data("""
            {"version":1,"sample_rate":16000,"recognition_key":"\(cache.key)","stream_evidence":"\(evidence)","duration_samples":\(duration),"words":[],"activity":[]}
            """.utf8)
            return TranscriptRecognitionCache.Artifacts(result: result, activity: levels)
        }
        for (cache, artifact) in zip(caches, artifacts) {
            try cache.saveSidecar(artifact, media: media, cancelled: { false })
            XCTAssertEqual(cache.readSidecar(cancelled: { false })?.result, artifact.result)
        }
        // The same physical URL is pinned across writes. Stat each database
        // separately so URL's cached resource values cannot mask a replacement.
        func currentSize() throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.url.path)
            return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        }
        let newSize = try currentSize()
        let keys = Set(sidecar.keys().filter { $0.hasPrefix("transcript_") })
        XCTAssertEqual(MediaRefreshEvidence.Comparison(audio: [0]).preservedSectionKeys(keys), keys)
        XCTAssertTrue(MediaRefreshEvidence.Comparison(audio: [1]).preservedSectionKeys(keys).isEmpty)
        let content = "transcript_activity.v1.0." + TranscriptStore.digest(levels)
        XCTAssertNil(sidecar.read(content))
        XCTAssertEqual(sidecar.keys().filter { $0.hasPrefix("transcript_activity.") }.count, 1)
        let originalKeys = sidecar.keys()
        let competing = TranscriptRecognitionCache.Artifacts(result: artifacts[0].result, activity: levels + Data([10]))
        try caches[0].saveSidecar(competing, media: media, cancelled: { false })
        XCTAssertEqual(sidecar.keys(), originalKeys)
        XCTAssertEqual(caches[0].readSidecar(cancelled: { false })?.activity, levels)
        try sidecar.saveTranscriptActivity(Data("updated levels".utf8), key: activityKey, media: media, replacing: true)
        XCTAssertEqual(sidecar.read(content), levels)
        XCTAssertEqual(sidecar.keys().filter { $0.hasPrefix("transcript_activity.") }.count, 2)
        for cache in caches {
            XCTAssertEqual(cache.readSidecar(cancelled: { false })?.activity, levels)
            XCTAssertNil(cache.readSidecar(cancelled: { true }))
        }
        try sidecar.save([content: Data("corrupt".utf8)])
        XCTAssertNil(caches[0].readSidecar(cancelled: { false }))
        try sidecar.saveTranscriptActivity(levels, key: activityKey, media: media, replacing: true)
        XCTAssertEqual(caches[0].readSidecar(cancelled: { false })?.activity, levels)

        try FileManager.default.removeItem(at: sidecar.url)
        try sidecar.saveTranscriptActivity(levels, key: activityKey, media: media)
        for (cache, artifact) in zip(caches, artifacts) {
            let legacy = "transcript_recognition.v1.0." + cache.key
            try sidecar.saveTranscript(JSONEncoder().encode(artifact), name: legacy, media: media, cancelled: { false })
            XCTAssertEqual(cache.readSidecar(cancelled: { false })?.activity, levels)
        }
        let oldSize = try currentSize()
        print("Two recognition settings, six-minute activity: legacy=\(oldSize) shared=\(newSize) bytes")
        XCTAssertLessThan(newSize, oldSize)
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

    /// Prepares a job for `document` and gives it a result: every track recognized, and a
    /// session output on disk from before the record was last written. A job MPCut ran also
    /// holds a result for each track. A provider run on its own may leave only the output.
    private func finishedJob(in store: TranscriptJobStore, source: URL, document: URL, fingerprint: String,
                             trackResults: Bool = true,
                             _ change: (inout TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
        let prepared = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try store.prepare(media: source, documentID: document.path)
        }
        try Data("session result".utf8).write(to: prepared.sessions[0].output)
        for track in prepared.sessions[0].tracks where trackResults {
            let result: [String: Any] = [
                "version": 1, "sample_rate": 16_000, "stream_evidence": track.evidence, "duration_samples": 16_000,
                "activity": [[String: Any]](), "recognition_key": String(repeating: "a", count: 64),
                "words": [[String: Any]](),
            ]
            try JSONSerialization.data(withJSONObject: result).write(to: XCTUnwrap(track.result))
        }
        return try store.update(prepared.id) {
            $0.state = .completed
            $0.attached = true
            $0.sessions[0].fingerprint = fingerprint
            for index in $0.sessions[0].tracks.indices { $0.sessions[0].tracks[index].state = .recognized }
            change(&$0)
        }
    }

    private func saveProject(to document: URL, source: URL, owner: UUID?,
                             attachments: [TranscriptAttachment], multicam: Bool = false) throws {
        let second = RationalTime(numerator: 1)
        var project = multicam
            ? CutProject.multicam(MulticamProject(referenceAngle: "camera", range: .init(from: .zero, to: second),
                                                  angles: [.init(id: "camera", file: source.lastPathComponent)],
                                                  audio: .follow, switches: [.init(at: .zero, angle: "camera")]))
            : CutProject.sequence([.init(id: "clip", file: source.lastPathComponent, from: .zero, to: second)])
        project.transcripts = .init(attachments: attachments, revision: 1, documentID: owner)
        try project.save(to: document)
    }

    func testPruneReadsWhatAMulticamDocumentHasAttached() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let source = try wave(in: folder)
        let document = folder.appendingPathComponent("group.cut")
        let owner = UUID()
        let current = try finishedJob(in: store, source: source, document: document, fingerprint: "current") {
            $0.documentIdentity = owner
        }
        let replaced = try finishedJob(in: store, source: source, document: document, fingerprint: "replaced") {
            $0.documentIdentity = owner
        }
        let asset = try TranscriptStore.put(TranscriptCodec.encodeStored(TranscriptDocument(clock: .presentation)),
                                            relativeTo: document)
        try saveProject(to: document, source: source, owner: owner, attachments: [
            .init(id: "current", asset: asset, bindings: [], fingerprint: "current"),
        ], multicam: true)
        guard case .multicam = try CutProject.load(from: document) else {
            return XCTFail("Expected the saved document to read as a multicam project.")
        }
        let later = Date().addingTimeInterval(40 * 86_400)
        XCTAssertEqual(try store.prune(olderThan: 30 * 86_400, now: later), [replaced.id])
        XCTAssertEqual(try store.status(current.id).state, .completed)
    }

    func testPruneRemovesAttachedOutputsAndJobsTheDocumentHasReplaced() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let source = try wave(in: folder)
        let document = folder.appendingPathComponent("edit.cut")
        let owner = UUID()
        func job(_ fingerprint: String, _ change: (inout TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
            try finishedJob(in: store, source: source, document: document, fingerprint: fingerprint) {
                $0.documentIdentity = owner
                change(&$0)
            }
        }
        func exists(_ record: TranscriptJobRecord) -> Bool {
            [store.recordURL(record.id), record.workingDirectory].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        func hasOutput(_ record: TranscriptJobRecord) -> Bool {
            FileManager.default.fileExists(atPath: record.sessions[0].output.path)
        }
        let current = try job("current")
        let replaced = try job("replaced")
        let replacedPartial = try job("replaced-partial") { $0.state = .partial }
        // A result that was never attached exists nowhere else.
        let waiting = try job("waiting") { $0.attached = false }
        // Retried since the document was saved: its sessions have new fingerprints, and the
        // saved transcript still names this job.
        let named = try job("after-retry")
        let otherOwner = try job("other-owner") { $0.documentIdentity = UUID() }
        let owned = try job("owned") { $0.ownerToken = UUID(); $0.ownerPID = getpid() }
        let locked = try job("locked")
        // Its provider wrote this output after the job was acknowledged.
        let late = try job("current")
        try Data("later session result".utf8).write(to: late.sessions[0].output)
        // A session still to be recognized keeps the place its provider writes.
        let unfinished = try job("current") { $0.state = .partial; $0.sessions[0].tracks[0].state = .staged }
        // Its provider ran on its own and left no track result: the output is the only copy.
        let standalone = try finishedJob(in: store, source: source, document: document, fingerprint: "current",
                                         trackResults: false) { $0.documentIdentity = owner }

        func asset(_ transcript: TranscriptDocument) throws -> TranscriptAsset {
            try TranscriptStore.put(TranscriptCodec.encodeStored(transcript), relativeTo: document)
        }
        func transcript(_ track: String, job: UUID? = nil) -> TranscriptDocument {
            TranscriptDocument(clock: .presentation, tracks: [.init(id: track, name: "Mic")], jobID: job?.uuidString)
        }
        try saveProject(to: document, source: source, owner: owner, attachments: [
            .init(id: "current", asset: asset(transcript("current")), bindings: [], fingerprint: "current"),
            .init(id: "imported", asset: asset(transcript("imported")), bindings: []),
            .init(id: "named", asset: asset(transcript("named", job: named.id)), bindings: [], fingerprint: "before-retry"),
        ])
        let all = [current, replaced, replacedPartial, waiting, named, otherOwner, owned, locked, late, unfinished,
                   standalone]
        let held = open(store.directory.appendingPathComponent(locked.id.uuidString + ".lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(held, 0)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        defer { close(held) }
        XCTAssertTrue(all.allSatisfy(hasOutput))

        // Nothing is old enough to remove. An attached job gives up, at any age, the outputs
        // its track results repeat.
        XCTAssertEqual(try store.prune(olderThan: 30 * 86_400), [])
        XCTAssertTrue(all.allSatisfy(exists))
        for record in [current, replaced, replacedPartial, named, otherOwner] {
            XCTAssertFalse(hasOutput(record), record.sessions[0].fingerprint)
        }
        for record in [waiting, owned, locked, late, unfinished, standalone] {
            XCTAssertTrue(hasOutput(record), record.sessions[0].fingerprint)
        }

        let later = Date().addingTimeInterval(40 * 86_400)
        XCTAssertEqual(Set(try store.prune(olderThan: 30 * 86_400, now: later)), [replaced.id, replacedPartial.id])
        for record in [replaced, replacedPartial] {
            XCTAssertFalse(exists(record), record.sessions[0].fingerprint)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: store.directory.appendingPathComponent(record.id.uuidString + ".lock").path))
        }
        for record in [current, waiting, named, otherOwner, owned, locked, late, unfinished, standalone] {
            XCTAssertTrue(exists(record), record.sessions[0].fingerprint)
        }
        // However old, the only copy of a recognition stays while its job does.
        XCTAssertTrue(hasOutput(standalone))
        // A kept job reads as before without its output.
        for record in [current, named] {
            XCTAssertEqual(try store.status(record.id).state, .completed)
            XCTAssertEqual(try store.status(record.id), try store.status(record.id))
        }

        // The document moves on from the remaining results.
        try saveProject(to: document, source: source, owner: owner, attachments: [
            .init(id: "imported", asset: asset(transcript("imported")), bindings: []),
        ])
        let removed = Set(try store.prune(olderThan: 30 * 86_400, now: later))
        XCTAssertEqual(removed, [current.id, named.id, late.id, unfinished.id, standalone.id])
        for record in [waiting, otherOwner, owned, locked] {
            XCTAssertTrue(exists(record), record.sessions[0].fingerprint)
        }
    }

    func testPruneKeepsAttachedJobsWhenTheDocumentCannotAnswer() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let source = try wave(in: folder)
        let later = Date().addingTimeInterval(40 * 86_400)

        // A transcript without a fingerprint, whose stored result cannot be read, may be this job's.
        let unreadable = folder.appendingPathComponent("unreadable.cut")
        let opaque = try TranscriptStore.put(Data("not a transcript".utf8), relativeTo: unreadable)
        try saveProject(to: unreadable, source: source, owner: nil,
                        attachments: [.init(id: "opaque", asset: opaque, bindings: [])])
        let doubtful = try finishedJob(in: store, source: source, document: unreadable, fingerprint: "replaced")

        // A file at the document's path that is not a project.
        let damaged = folder.appendingPathComponent("damaged.cut")
        try Data("{".utf8).write(to: damaged)
        let unknown = try finishedJob(in: store, source: source, document: damaged, fingerprint: "replaced")

        // A project whose transcripts were all removed answers that none came from this job.
        let emptied = folder.appendingPathComponent("emptied.cut")
        try saveProject(to: emptied, source: source, owner: nil, attachments: [])
        let detached = try finishedJob(in: store, source: source, document: emptied, fingerprint: "replaced")

        XCTAssertEqual(try store.prune(olderThan: 30 * 86_400, now: later), [detached.id])
        for record in [doubtful, unknown] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordURL(record.id).path), record.documentID)
            XCTAssertEqual(try store.status(record.id).state, .completed)
        }
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
