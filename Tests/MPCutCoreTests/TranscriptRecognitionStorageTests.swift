import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptRecognitionStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPCut-recognition-storage-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// One second of silent 16 kHz mono PCM.
    private func wave(in folder: URL, name: String = "source.wav") throws -> URL {
        let file = folder.appendingPathComponent(name)
        let frames = 16_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(frames * 2 + 36))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(frames * 2))
        data.append(Data(count: frames * 2))
        try data.write(to: file)
        return file
    }

    private func size(_ sidecar: AnalysisSidecar) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.url.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    func testRecognitionSharesTheLevelsThatExtractionSaved() throws {
        let folder = try directory()
        let media = try CutEngine().inspectMulticamSource(try wave(in: folder))
        let sidecar = AnalysisSidecar(media: media)
        let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: media, streamIndex: 0))
        // Ten minutes of 20 ms frames.
        let count = 30_000
        let duration = Int64(count * 320)
        func document(_ level: (Int) -> Float) throws -> Data {
            try transcriptActivityDocument(levels: (0..<count).map(level), duration: duration, evidence: evidence)
        }
        func content(_ levels: Data) -> String { "transcript_activity.v1.0." + TranscriptStore.digest(levels) }
        func cache(_ letter: String, in sidecar: AnalysisSidecar, channel: Int? = nil) -> TranscriptRecognitionCache {
            TranscriptRecognitionCache(sidecar: sidecar, key: String(repeating: letter, count: 64), evidence: evidence,
                                       stream: 0, channel: channel)
        }
        func artifacts(_ cache: TranscriptRecognitionCache, _ levels: Data) -> TranscriptRecognitionCache.Artifacts {
            let result = Data("""
            {"version":1,"sample_rate":16000,"recognition_key":"\(cache.key)","stream_evidence":"\(evidence)","duration_samples":\(duration),"words":[],"activity":[]}
            """.utf8)
            return .init(result: result, activity: levels)
        }
        func levelSections(_ sidecar: AnalysisSidecar) -> Set<String> {
            Set(sidecar.keys().filter { $0.hasPrefix("transcript_activity.") })
        }
        let key = TranscriptActivityKey(stream: 0)
        let extraction = try AnalysisSidecar.transcriptActivitySection(key)
        // Full-precision levels, which the sidecar cannot store in less than their digits.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let levels = try document { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * 0.4
        }

        try sidecar.saveTranscriptActivity(levels, key: key, media: media)
        let extracted = try size(sidecar)
        let caches = ["a", "b"].map { cache($0, in: sidecar) }
        for cache in caches {
            let artifact = artifacts(cache, levels)
            try cache.saveSidecar(artifact, media: media, cancelled: { false })
            XCTAssertEqual(cache.readSidecar(cancelled: { false })?.result, artifact.result)
            XCTAssertEqual(cache.readSidecar(cancelled: { false })?.activity, levels)
        }
        XCTAssertEqual(levelSections(sidecar), [extraction])
        let shared = try size(sidecar)

        // The same saves with a second copy under the content name, as a record once kept.
        let duplicateMedia = try CutEngine().inspectMulticamSource(try wave(in: folder, name: "duplicate.wav"))
        let duplicate = AnalysisSidecar(media: duplicateMedia)
        try duplicate.saveTranscriptActivity(levels, key: key, media: duplicateMedia)
        try duplicate.save([content(levels): levels])
        for letter in ["a", "b"] {
            let cache = cache(letter, in: duplicate)
            try cache.saveSidecar(artifacts(cache, levels), media: duplicateMedia, cancelled: { false })
        }
        XCTAssertEqual(levelSections(duplicate), [extraction, content(levels)])
        let doubled = try size(duplicate)
        print("Two recognition settings, ten-minute levels: levels_only=\(extracted) one_copy=\(shared) two_copies=\(doubled) bytes")
        XCTAssertLessThan(shared, doubled)

        // A later extraction takes the extraction key. The records keep the levels they name.
        let later = try document { _ in 0.5 }
        try sidecar.saveTranscriptActivity(later, key: key, media: media, replacing: true)
        XCTAssertEqual(sidecar.readTranscriptActivity(key), later)
        XCTAssertEqual(sidecar.read(content(levels)), levels)
        XCTAssertEqual(levelSections(sidecar), [extraction, content(levels)])
        for cache in caches { XCTAssertEqual(cache.readSidecar(cancelled: { false })?.activity, levels) }

        // Levels that no record names are replaced without a copy.
        let latest = try document { _ in 0.25 }
        try sidecar.saveTranscriptActivity(latest, key: key, media: media, replacing: true)
        XCTAssertEqual(sidecar.readTranscriptActivity(key), latest)
        XCTAssertEqual(levelSections(sidecar), [extraction, content(levels)])

        // A record whose levels differ from the extraction's, or that was staged from
        // another channel, stores its own.
        let other = try document { _ in 0.75 }
        let third = cache("c", in: sidecar)
        try third.saveSidecar(artifacts(third, other), media: media, cancelled: { false })
        XCTAssertEqual(third.readSidecar(cancelled: { false })?.activity, other)
        XCTAssertEqual(levelSections(sidecar), [extraction, content(levels), content(other)])
        let channel = cache("d", in: sidecar, channel: 1)
        try channel.saveSidecar(artifacts(channel, latest), media: media, cancelled: { false })
        XCTAssertEqual(channel.readSidecar(cancelled: { false })?.activity, latest)
        XCTAssertEqual(levelSections(sidecar), [extraction, content(levels), content(other), content(latest)])
    }

    func testChannelRecognitionSharesItsOwnExtraction() throws {
        let folder = try directory()
        let media = try CutEngine().inspectMulticamSource(try wave(in: folder))
        let sidecar = AnalysisSidecar(media: media)
        let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: media, streamIndex: 0))
        let levels = try transcriptActivityDocument(levels: [0.25, 0.5], duration: 640, evidence: evidence)
        let key = TranscriptActivityKey(stream: 0, channel: 1)
        try sidecar.saveTranscriptActivity(levels, key: key, media: media)
        let cache = TranscriptRecognitionCache(sidecar: sidecar, key: String(repeating: "a", count: 64), evidence: evidence,
                                               stream: 0, channel: 1)
        let result = Data("""
        {"version":1,"sample_rate":16000,"recognition_key":"\(cache.key)","stream_evidence":"\(evidence)","duration_samples":640,"words":[],"activity":[]}
        """.utf8)
        try cache.saveSidecar(.init(result: result, activity: levels), media: media, cancelled: { false })
        XCTAssertEqual(cache.readSidecar(cancelled: { false })?.activity, levels)
        XCTAssertEqual(sidecar.keys().filter { $0.hasPrefix("transcript_activity.") },
                       [try AnalysisSidecar.transcriptActivitySection(key)])
    }

    func testTestProcessKeepsSharedRecognitionOutOfApplicationSupport() throws {
        let variable = "MPCUT_TRANSCRIPT_CLAIMS_HOME"
        let inherited = getenv(variable).map { String(cString: $0) }
        unsetenv(variable)
        defer {
            if let inherited { setenv(variable, inherited, 1) } else { unsetenv(variable) }
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        let shared = try TranscriptJobStore.sharedRecognitionDirectory()
        XCTAssertEqual(shared, try TranscriptRecognitionClaims.directory())
        XCTAssertFalse(shared.resolvingSymlinksInPath().path.hasPrefix(support.resolvingSymlinksInPath().path))
        XCTAssertEqual(shared.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        XCTAssertTrue(shared.lastPathComponent.hasPrefix("mpcut-test-claims-"))

        // The override serves a test that shares one folder with the processes it starts.
        let folder = try directory().appendingPathComponent("claims", isDirectory: true)
        setenv(variable, folder.path, 1)
        XCTAssertEqual(try TranscriptRecognitionClaims.directory().path, folder.path)
        let claim = String(repeating: "4", count: 64)
        let claims = TranscriptRecognitionClaims()
        try claims.acquire([claim], cancelled: { false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(claim).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent(claim).path))
        withExtendedLifetime(claims) {}

        setenv(variable, "relative/claims", 1)
        XCTAssertEqual(try TranscriptRecognitionClaims.directory(), shared)
        unsetenv(variable)
        XCTAssertEqual(try TranscriptRecognitionClaims.directory(), shared)
    }

    func testPruneRemovesClaimFilesLeftWithoutResults() throws {
        let folder = try directory()
        let abandoned = String(repeating: "1", count: 64)
        let held = String(repeating: "2", count: 64)
        let finished = String(repeating: "3", count: 64)
        for name in [abandoned, held, finished] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent(finished + ".json"))
        let claims = TranscriptRecognitionClaims()
        try claims.acquire([held], in: folder, cancelled: { false })
        func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) }

        XCTAssertEqual(TranscriptRecognitionClaims.prune(in: folder, olderThan: 30 * 86_400, now: Date()), 0)
        XCTAssertEqual(try names(), [abandoned, held, finished, finished + ".json"])
        // Only a result counts as removed. A claim another process holds stays.
        let later = Date().addingTimeInterval(31 * 86_400)
        XCTAssertEqual(TranscriptRecognitionClaims.prune(in: folder, olderThan: 30 * 86_400, now: later), 1)
        XCTAssertEqual(try names(), [held])
        withExtendedLifetime(claims) {}
    }

    func testPruneTreatsBothExchangeVersionsAsOneResult() throws {
        let folder = try directory()
        let both = String(repeating: "1", count: 64)
        let unlocked = String(repeating: "2", count: 64)
        let held = String(repeating: "3", count: 64)
        let rewritten = String(repeating: "4", count: 64)
        let old = [both, both + ".json", both + ".mpx", unlocked + ".mpx", held, held + ".mpx",
                   rewritten, rewritten + ".json"]
        for name in old + [rewritten + ".mpx"] {
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }
        for name in old {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86_400)],
                                                  ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        let claims = TranscriptRecognitionClaims()
        try claims.acquire([held], in: folder, cancelled: { false })
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86_400)],
                                              ofItemAtPath: folder.appendingPathComponent(held).path)

        // A claim with a result in each version is one result. A current file without a claim
        // file, as a build that knows only version 1 leaves it, goes too. A result written
        // again in the current version keeps its claim, and so does one that is held.
        XCTAssertEqual(TranscriptRecognitionClaims.prune(in: folder, olderThan: 30 * 86_400, now: Date()), 2)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       [held, held + ".mpx", rewritten, rewritten + ".json", rewritten + ".mpx"])
        withExtendedLifetime(claims) {}
    }

    func testSharedResultIsReadInEitherVersionAndWrittenInTheOneTheProviderReads() throws {
        let variable = "MPCUT_TRANSCRIPT_CLAIMS_HOME"
        let inherited = getenv(variable).map { String(cString: $0) }
        let folder = try directory()
        let claims = folder.appendingPathComponent("claims", isDirectory: true)
        setenv(variable, claims.path, 1)
        defer {
            if let inherited { setenv(variable, inherited, 1) } else { unsetenv(variable) }
        }
        let media = try CutEngine().inspectMulticamSource(try wave(in: folder))
        let sidecar = AnalysisSidecar(media: media)
        let evidence = try XCTUnwrap(TranscriptJobPlan.streamEvidence(media: media, streamIndex: 0))
        let duration: Int64 = 200 * 320 - 10
        let levels = try transcriptActivityDocument(levels: (0..<200).map { Float($0 % 7) / 8 }, duration: duration,
                                                    evidence: evidence)
        func cache(_ letter: String, providerReads version: Int = 1) -> TranscriptRecognitionCache {
            var cache = TranscriptRecognitionCache(sidecar: sidecar, key: String(repeating: letter, count: 64),
                                                   evidence: evidence, stream: 0)
            cache.providerExchangeVersion = version
            return cache
        }
        func artifacts(_ cache: TranscriptRecognitionCache) -> TranscriptRecognitionCache.Artifacts {
            let result = Data("""
            {"version":1,"sample_rate":16000,"recognition_key":"\(cache.key)","stream_evidence":"\(evidence)","duration_samples":\(duration),"words":[],"activity":[]}
            """.utf8)
            return .init(result: result, activity: levels)
        }
        func file(_ cache: TranscriptRecognitionCache, _ version: String) -> URL {
            claims.appendingPathComponent(cache.claimID + "." + version)
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func current(_ artifacts: TranscriptRecognitionCache.Artifacts) throws -> Data {
            try XCTUnwrap(TranscriptRecognitionExchange.encode(result: artifacts.result, activity: artifacts.activity,
                                                               cancelled: { false }))
        }
        struct Legacy: Codable {
            let result: Data
            let activity: Data?
            let digest: String
        }
        func legacy(_ artifacts: TranscriptRecognitionCache.Artifacts) throws -> Data {
            let digest = TranscriptRecognitionExchange.digest(result: artifacts.result, activity: artifacts.activity)
            return try JSONEncoder().encode(Legacy(result: artifacts.result, activity: artifacts.activity,
                                                   digest: digest.map { String(format: "%02x", $0) }.joined()))
        }

        // A provider that has not said it reads version 2 is written version 1, as before.
        let earlier = cache("a")
        try earlier.save(artifacts(earlier), media: media, cancelled: { false })
        XCTAssertFalse(exists(file(earlier, "mpx")))
        let written = try Data(contentsOf: file(earlier, "json"))
        let decoded = try JSONDecoder().decode(Legacy.self, from: written)
        XCTAssertEqual(decoded.result, artifacts(earlier).result)
        XCTAssertEqual(decoded.activity, levels)
        XCTAssertEqual(decoded.digest, try JSONDecoder().decode(Legacy.self, from: legacy(artifacts(earlier))).digest)

        // One that has is written version 2, and a version 1 file for the claim goes.
        let later = cache("b", providerReads: 2)
        try Data("stale".utf8).write(to: file(later, "json"))
        try later.save(artifacts(later), media: media, cancelled: { false })
        XCTAssertFalse(exists(file(later, "json")))
        let compact = try Data(contentsOf: file(later, "mpx"))
        let read = try XCTUnwrap(TranscriptRecognitionExchange.decode(compact, cancelled: { false }))
        XCTAssertEqual(read.result, artifacts(later).result)
        XCTAssertEqual(read.activity, levels)
        XCTAssertEqual(Array(compact[8..<40]),
                       TranscriptRecognitionExchange.digest(result: artifacts(later).result, activity: levels))
        XCTAssertLessThan(compact.count * 8, written.count)

        // Whatever the provider reads, MPCut reads both. Nothing is in this key's sidecar.
        let reader = cache("c")
        let expected = artifacts(reader)
        XCTAssertNil(reader.read(cancelled: { false }))
        try current(expected).write(to: file(reader, "mpx"))
        XCTAssertEqual(reader.read(cancelled: { false })?.result, expected.result)
        XCTAssertEqual(reader.read(cancelled: { false })?.activity, levels)
        try FileManager.default.removeItem(at: file(reader, "mpx"))
        XCTAssertNil(reader.read(cancelled: { false }))
        try legacy(expected).write(to: file(reader, "json"))
        XCTAssertEqual(reader.read(cancelled: { false })?.result, expected.result)
        XCTAssertEqual(reader.read(cancelled: { false })?.activity, levels)
        // A current file that is damaged, or holds another key's result, leaves version 1 to answer.
        try current(expected).dropLast(7).write(to: file(reader, "mpx"))
        XCTAssertEqual(reader.read(cancelled: { false })?.result, expected.result)
        try current(artifacts(later)).write(to: file(reader, "mpx"))
        XCTAssertEqual(reader.read(cancelled: { false })?.result, expected.result)
        try legacy(artifacts(later)).write(to: file(reader, "json"))
        XCTAssertNil(reader.read(cancelled: { false }))
    }

    func testImportPromotesAProviderResultFromPackedJobFiles() throws {
        let variable = "MPCUT_TRANSCRIPT_CLAIMS_HOME"
        let inherited = getenv(variable).map { String(cString: $0) }
        let folder = try directory()
        let claims = folder.appendingPathComponent("claims", isDirectory: true)
        setenv(variable, claims.path, 1)
        defer {
            if let inherited { setenv(variable, inherited, 1) } else { unsetenv(variable) }
        }
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try store.prepare(media: try wave(in: folder), documentID: "promote")
        let session = try XCTUnwrap(job.sessions.first)
        let track = try XCTUnwrap(session.tracks.first)
        XCTAssertTrue(track.hasReusableEvidence)

        // Preparing a standalone session tells the provider which exchange version this build
        // reads, in the shared folder. The manifest gains no field, which an earlier provider
        // would reject.
        XCTAssertEqual(try Data(contentsOf: claims.appendingPathComponent("exchange-version")), Data("2\n".utf8))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.manifest)) as? [String: Any])
        let described = try XCTUnwrap((manifest["tracks"] as? [[String: Any]])?.first?["shared_cache"] as? [String: Any])
        XCTAssertEqual(described["directory"] as? String, claims.path)
        XCTAssertTrue(Set(described.keys).isSubset(of: ["source", "audio", "scope", "directory", "write", "restart"]),
                      "\(described.keys.sorted())")

        // What the provider leaves for a ten-minute track, long enough for a finished job to pack.
        let key = String(repeating: "e", count: 64)
        let count = 30_000
        let duration = Int64(count * 320)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let levels = try transcriptActivityDocument(levels: (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * 0.4
        }, duration: duration, evidence: track.evidence)
        let words = (0..<2_000).map { index in
            "{\"id\":\"w\(index)\",\"utterance_id\":\"u\(index / 12)\",\"text\":\"word\",\"start_sample\":\(index * 4_000),"
                + "\"end_sample\":\(index * 4_000 + 3_000),\"speaker_id\":null,\"precision\":\"word\"}"
        }.joined(separator: ",")
        let result = Data("""
        {"version":1,"sample_rate":16000,"recognition_key":"\(key)","stream_evidence":"\(track.evidence)","duration_samples":\(duration),"words":[\(words)],"activity":[]}
        """.utf8)
        let files = [try XCTUnwrap(track.result), try XCTUnwrap(track.activity)]
        try result.write(to: files[0])
        try levels.write(to: files[1])
        XCTAssertNotNil(TranscriptJobArtifact.pack(files[0], as: .result))
        XCTAssertNotNil(TranscriptJobArtifact.pack(files[1], as: .levels))
        func plainFiles() -> [Bool] { files.map { FileManager.default.fileExists(atPath: $0.path) } }
        XCTAssertEqual(plainFiles(), [false, false])

        let sidecar = AnalysisSidecar(source: track.file, identity: try SourceIdentity(track.file))
        let cache = TranscriptRecognitionCache(sidecar: sidecar, key: key, evidence: track.evidence,
                                               stream: try XCTUnwrap(track.streamIndex), channel: track.stagedChannel)
        func promote() {
            TranscriptRecognitionCache.promoteExternal(in: job, stamps: [track.id: sidecar.identity], recognizedIDs: [track.id])
        }
        // Only a result that the provider shared is mirrored into the sidecar.
        promote()
        XCTAssertNil(cache.readSidecar(cancelled: { false }))
        try XCTUnwrap(TranscriptRecognitionExchange.encode(result: result, activity: levels, cancelled: { false }))
            .write(to: claims.appendingPathComponent(cache.claimID + ".mpx"))
        promote()
        let promoted = try XCTUnwrap(cache.readSidecar(cancelled: { false }))
        XCTAssertEqual(promoted.result, result)
        XCTAssertEqual(promoted.activity, levels)
        XCTAssertEqual(plainFiles(), [false, false])
    }
}
