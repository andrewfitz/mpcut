import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptJobArtifactTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-artifacts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    private func size(_ file: URL) throws -> Int {
        try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// Levels as a recording has them: silence, room tone and speech, each with its own spelling.
    private func levels(frames: Int) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<frames).map { frame in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            switch (frame / 250) % 4 {
            case 0: return 0
            case 1: return unit * 0.004
            default: return 0.02 + unit * 0.3
            }
        }
    }

    /// The same frames as Transcriberrr writes them: header fields first, each start before its end.
    private func providerLevels(_ levels: [Float], evidence: String) -> Data {
        let duration = levels.count * 320
        var text = #"{"version":1,"sample_rate":16000,"stream_evidence":"\#(evidence)","duration_samples":\#(duration),"activity":["#
        for (index, level) in levels.enumerated() {
            if index > 0 { text += "," }
            let spelled = level.description
            text += #"{"start_sample":\#(index * 320),"end_sample":\#(index * 320 + 320),"level":\#(spelled)}"#
        }
        return Data((text + "]}").utf8)
    }

    private func recognition(words: Int, evidence: String, duration: Int) throws -> Data {
        let spoken = ["the", "recording", "starts", "here", "and", "nobody", "interrupts", "until", "later"]
        let entries = (0..<words).map { index -> [String: Any] in
            ["id": "w\(index)", "text": spoken[index % spoken.count], "precision": "word",
             "start_sample": index * 6_000, "end_sample": index * 6_000 + 4_200 + index % 7 * 100,
             "speaker_id": "speaker-\(index / 40 % 2)", "utterance_id": "u\(index / 12)",
             "confidence": Double(900 + index % 97) / 1_000]
        }
        return try JSONSerialization.data(withJSONObject: [
            "version": 1, "sample_rate": 16_000, "stream_evidence": evidence, "duration_samples": duration,
            "recognition_key": String(repeating: "b", count: 64), "activity": [[String: Any]](), "words": entries,
        ], options: [.sortedKeys])
    }

    func testTenMinuteTrackFilesShrinkAndRestoreToTheSameBytes() throws {
        let folder = try directory()
        let frames = 10 * 60 * 50
        let measured = levels(frames: frames)
        let evidence = String(repeating: "e", count: 64)
        let documents: [(name: String, kind: TranscriptJobArtifact.Kind, bytes: Data, limit: Int)] = [
            ("track.activity.json", .levels, providerLevels(measured, evidence: evidence), 8),
            ("measured.activity.json", .levels,
             try transcriptActivityDocument(levels: measured, duration: Int64(frames * 320), evidence: evidence), 8),
            ("track.json", .result, try recognition(words: 1_500, evidence: evidence, duration: frames * 320), 4),
        ]
        var before = 0, after = 0
        for document in documents {
            let file = folder.appendingPathComponent(document.name)
            try document.bytes.write(to: file)
            let saved = try XCTUnwrap(TranscriptJobArtifact.pack(file, as: document.kind), document.name)
            let packed = try size(TranscriptJobArtifact.packedURL(file))
            print("Ten-minute track, \(document.name): \(document.bytes.count) bytes as written, \(packed) packed")
            XCTAssertEqual(saved, document.bytes.count - packed)
            XCTAssertLessThan(packed * document.limit, document.bytes.count, document.name)
            before += document.bytes.count
            after += packed
            // Every reader is given the bytes the provider wrote, whichever form is on disk.
            XCTAssertFalse(exists(file))
            XCTAssertTrue(TranscriptJobArtifact.exists(file))
            XCTAssertEqual(TranscriptJobArtifact.read(file), document.bytes)
            XCTAssertNil(TranscriptJobArtifact.pack(file, as: document.kind))
            try TranscriptJobArtifact.restore(file)
            XCTAssertEqual(try Data(contentsOf: file), document.bytes)
            XCTAssertFalse(exists(TranscriptJobArtifact.packedURL(file)))
            XCTAssertEqual(TranscriptJobArtifact.read(file), document.bytes)
        }
        print("Ten-minute track, three files: \(before) bytes as written, \(after) packed")

        // A short artifact is not worth a swap, and one that is absent has nothing to pack.
        let short = folder.appendingPathComponent("short.activity.json")
        try providerLevels(levels(frames: 500), evidence: evidence).write(to: short)
        XCTAssertNil(TranscriptJobArtifact.pack(short, as: .levels))
        XCTAssertTrue(exists(short))
        XCTAssertFalse(TranscriptJobArtifact.isPackable(short))
        XCTAssertNil(TranscriptJobArtifact.pack(folder.appendingPathComponent("absent.json"), as: .result))
        XCTAssertNil(TranscriptJobArtifact.read(folder.appendingPathComponent("absent.json")))
        XCTAssertFalse(TranscriptJobArtifact.exists(folder.appendingPathComponent("absent.json")))
    }

    func testInterruptedSwapAlwaysLeavesAReadableArtifact() throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("track.activity.json")
        let packed = TranscriptJobArtifact.packedURL(file)
        let written = providerLevels(levels(frames: 4_000), evidence: "first")
        let rewritten = providerLevels(levels(frames: 4_100), evidence: "second")

        // Stopped while writing the packed form: only a scratch file exists beside the artifact.
        try written.write(to: file)
        try Data(written.prefix(1_000)).write(to: folder.appendingPathComponent(".\(UUID().uuidString).artifact"))
        XCTAssertEqual(TranscriptJobArtifact.read(file), written)

        // Stopped after the packed form was written and before the plain file was removed.
        XCTAssertNotNil(TranscriptJobArtifact.writePacked(file, as: .levels))
        XCTAssertTrue(exists(file) && exists(packed))
        XCTAssertEqual(TranscriptJobArtifact.read(file), written)
        // A provider that then writes the artifact again is the one that is read, and kept.
        try rewritten.write(to: file)
        XCTAssertEqual(TranscriptJobArtifact.read(file), rewritten)
        try TranscriptJobArtifact.restore(file)
        XCTAssertFalse(exists(packed))
        XCTAssertEqual(try Data(contentsOf: file), rewritten)
        // Packing again replaces what the earlier swap left.
        try written.write(to: file)
        XCTAssertNotNil(TranscriptJobArtifact.writePacked(file, as: .levels))
        try rewritten.write(to: file)
        XCTAssertNotNil(TranscriptJobArtifact.pack(file, as: .levels))
        XCTAssertFalse(exists(file))
        XCTAssertEqual(TranscriptJobArtifact.read(file), rewritten)

        // Stopped after the plain file was restored and before the packed form was removed.
        XCTAssertTrue(try TranscriptJobArtifact.writePlain(file))
        XCTAssertTrue(exists(file) && exists(packed))
        XCTAssertEqual(try Data(contentsOf: file), rewritten)
        XCTAssertEqual(TranscriptJobArtifact.read(file), rewritten)
        try TranscriptJobArtifact.restore(file)
        XCTAssertTrue(exists(file))
        XCTAssertFalse(exists(packed))

        // A packed form that is cut short, altered or of another format is an artifact that is
        // not there. It never stands in for the plain file, and never comes back as other bytes.
        XCTAssertNotNil(TranscriptJobArtifact.pack(file, as: .levels))
        let stored = try Data(contentsOf: packed)
        var altered = stored
        altered[altered.count - 20] ^= 0x55
        for damaged in [stored.prefix(stored.count / 2), stored.prefix(40), altered, Data("{}".utf8), Data()] {
            try Data(damaged).write(to: packed)
            XCTAssertNil(TranscriptJobArtifact.read(file))
            try written.write(to: file)
            XCTAssertEqual(TranscriptJobArtifact.read(file), written)
            try FileManager.default.removeItem(at: file)
        }
        // Restoring it writes nothing, and leaves a file that a later version may have written.
        XCTAssertFalse(try TranscriptJobArtifact.writePlain(file))
        XCTAssertNoThrow(try TranscriptJobArtifact.restore(file))
        XCTAssertFalse(exists(file))
        XCTAssertTrue(exists(packed))
        XCTAssertNil(TranscriptJobArtifact.read(file))

        // A restore that cannot write the plain file says so, and the packed form stays readable.
        try stored.write(to: packed)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try TranscriptJobArtifact.restore(file))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertFalse(exists(file))
        XCTAssertEqual(TranscriptJobArtifact.read(file), rewritten)

        // Discarding an artifact discards both forms.
        try written.write(to: file)
        XCTAssertNotNil(TranscriptJobArtifact.writePacked(file, as: .levels))
        TranscriptJobArtifact.remove(file)
        XCTAssertFalse(TranscriptJobArtifact.exists(file))
    }

    /// A ten-minute recording and a short one, synchronized as two cameras.
    private func recordings(in folder: URL) throws -> (project: MulticamProject, long: URL) {
        func wave(_ name: String, seconds: Int) throws -> URL {
            let file = folder.appendingPathComponent(name)
            let frames = seconds * 16_000
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
            var samples = [Int16](repeating: 0, count: frames)
            for index in stride(from: 0, to: frames, by: 37) { samples[index] = Int16(truncatingIfNeeded: index &* 31) / 8 }
            samples.withUnsafeBytes { data.append(contentsOf: $0) }
            try data.write(to: file)
            return file
        }
        let long = try wave("wide.wav", seconds: 600)
        let short = try wave("close.wav", seconds: 3)
        return (MulticamProject(referenceAngle: "long", range: .init(from: .zero, to: .init(numerator: 2)),
                                angles: [.init(id: "long", file: long.path), .init(id: "short", file: short.path)],
                                audio: .follow, switches: []), long)
    }

    /// `outcomes` holds what each launch of the provider reports, in order.
    private func lifecycleProvider(in folder: URL, outcomes: [String]) throws -> URL {
        let provider = folder.appendingPathComponent("provider.py")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/TranscriptLifecycleProvider.py")
        try FileManager.default.copyItem(at: fixture, to: provider)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
        for (index, outcome) in outcomes.enumerated() {
            try Data(outcome.utf8).write(to: folder.appendingPathComponent("release-\(index + 1)"))
        }
        return provider
    }

    func testPartialJobPacksTheTrackThatFinishedAndRetriesTheOther() throws {
        let folder = try directory()
        let (group, _) = try recordings(in: folder)
        let provider = try lifecycleProvider(in: folder, outcomes: ["partial", "completed"])
        var editor = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        editor.stagesAudioForStandaloneProvider = false
        let prepared = try editor.prepare(project: .multicam(group), documentID: "edit",
                                          options: .init(engine: "lifecycle-fixture"))
        let partial = try editor.run(prepared.id, helper: provider)
        XCTAssertEqual(partial.state, .partial, partial.message ?? "")
        func track(_ source: String, in record: TranscriptJobRecord) throws -> TranscriptJobTrack {
            try XCTUnwrap(record.sessions[0].tracks.first { $0.sourceID == source })
        }
        let long = try track("long", in: partial)
        XCTAssertEqual(long.state, .recognized)
        XCTAssertEqual(try track("short", in: partial).state, .failed)
        let files = [try XCTUnwrap(long.result), try XCTUnwrap(long.activity)]
        let written = try files.map { try Data(contentsOf: $0) }

        XCTAssertEqual(try editor.verifiedDocuments(partial.id, project: .multicam(group)).count, 1)
        XCTAssertEqual(try editor.status(partial.id).state, .partial)
        XCTAssertEqual(files.map(exists), [false, false])
        XCTAssertEqual(files.map(TranscriptJobArtifact.read), written)
        // The track a retry works on keeps its levels as they were written.
        XCTAssertTrue(exists(try XCTUnwrap(track("short", in: partial).activity)))

        // The retry hands the provider one finished result to reuse and one recording to recognize.
        let retried = try editor.retry(partial.id, project: .multicam(group))
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, written)
        XCTAssertFalse(exists(try XCTUnwrap(track("long", in: retried).audio)))
        XCTAssertTrue(exists(try XCTUnwrap(track("short", in: retried).audio)))
        let completed = try editor.run(retried.id, helper: provider)
        XCTAssertEqual(completed.state, .completed, completed.message ?? "")
        XCTAssertEqual(completed.sessions[0].tracks.map(\.state), [.recognized, .recognized])
        // The provider read the finished result and did not write it again.
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, written)
        XCTAssertEqual(try editor.verifiedDocuments(completed.id, project: .multicam(group)).count, 1)
        XCTAssertEqual(files.map(exists), [false, false])
        XCTAssertEqual(files.map(TranscriptJobArtifact.read), written)
    }

    func testFinishedJobKeepsTrackFilesPackedAndRetriesFromThem() throws {
        let folder = try directory()
        var (group, _) = try recordings(in: folder)
        let provider = try lifecycleProvider(in: folder, outcomes: Array(repeating: "completed", count: 4))
        var editor = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        editor.stagesAudioForStandaloneProvider = false
        let prepared = try editor.prepare(project: .multicam(group), documentID: "edit",
                                          options: .init(engine: "lifecycle-fixture"))
        let finished = try editor.run(prepared.id, helper: provider)
        XCTAssertEqual(finished.state, .completed, finished.message ?? "")
        let long = try XCTUnwrap(finished.sessions[0].tracks.first { $0.sourceID == "long" })
        let short = try XCTUnwrap(finished.sessions[0].tracks.first { $0.sourceID == "short" })
        let files = [try XCTUnwrap(long.result), try XCTUnwrap(long.activity)]
        let written = try files.map { try Data(contentsOf: $0) }
        let before = written.reduce(0) { $0 + $1.count }

        // Reading the result is the last use of a finished track's files until a retry.
        let original = try XCTUnwrap(editor.verifiedDocuments(finished.id, project: .multicam(group)).first)
        let after = try files.reduce(0) { $0 + (try size(TranscriptJobArtifact.packedURL($1))) }
        print("Ten-minute track in a finished job: \(before) bytes as written, \(after) packed")
        XCTAssertLessThan(after * 8, before)
        XCTAssertEqual(files.map(exists), [false, false])
        XCTAssertEqual(files.map(TranscriptJobArtifact.read), written)
        // The three-second track's files are too short to be worth packing.
        XCTAssertTrue(exists(try XCTUnwrap(short.result)))

        // The packed result still makes the session output a copy, and a second read of the job says so.
        _ = try editor.markAttached(finished.id, expectedPreparationID: finished.preparationID)
        XCTAssertFalse(exists(finished.sessions[0].output))
        XCTAssertThrowsError(try editor.verifiedDocuments(finished.id, project: .multicam(group))) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_output_removed")
        }
        XCTAssertEqual(try editor.status(finished.id).state, .completed)
        XCTAssertEqual(files.map(exists), [false, false])

        // A retry puts the provider's files back as it wrote them, decodes no audio and recognizes nothing again.
        let again = try editor.retry(finished.id, project: .multicam(group))
        XCTAssertEqual(again.state, .prepared)
        XCTAssertEqual(again.sessions[0].tracks.map { $0.audio.map(exists) ?? false }, [false, false])
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, written)
        XCTAssertEqual(files.map { exists(TranscriptJobArtifact.packedURL($0)) }, [false, false])
        let rebuilt = try editor.run(again.id, helper: provider)
        XCTAssertEqual(rebuilt.state, .completed, rebuilt.message ?? "")
        XCTAssertEqual(rebuilt.sessions[0].tracks.map(\.state), [.recognized, .recognized])
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, written)
        let replay = try XCTUnwrap(editor.verifiedDocuments(rebuilt.id, project: .multicam(group)).first)
        XCTAssertEqual(replay.document.words, original.document.words)
        XCTAssertEqual(files.map(exists), [false, false])
        XCTAssertEqual(files.map(TranscriptJobArtifact.read), written)

        // Reconcile after a camera moves, from the packed files.
        group.angles[1].offset = .init(numerator: 1, denominator: 2)
        let retried = try editor.retry(rebuilt.id, project: .multicam(group))
        XCTAssertEqual(retried.sessions[0].tracks.map { $0.audio.map(exists) ?? false }, [false, false])
        let reconciled = try editor.run(retried.id, helper: provider)
        XCTAssertEqual(reconciled.state, .completed, reconciled.message ?? "")
        XCTAssertEqual(reconciled.sessions[0].tracks.map(\.state), [.recognized, .recognized])
        let moved = try XCTUnwrap(editor.verifiedDocuments(reconciled.id, project: .multicam(group)).first)
        XCTAssertEqual(moved.document.words.map(\.text), original.document.words.map(\.text))
        let carried = try XCTUnwrap(reconciled.sessions[0].tracks.first { $0.sourceID == "long" })
        let kept = [try XCTUnwrap(carried.result), try XCTUnwrap(carried.activity)]
        XCTAssertEqual(kept.map(TranscriptJobArtifact.read), written)
        XCTAssertEqual(kept.map(exists), [false, false])

        // A job finished by a version that kept the files as written is packed by the next prune.
        try kept.forEach(TranscriptJobArtifact.restore)
        XCTAssertEqual(kept.map(exists), [true, true])
        XCTAssertEqual(try editor.prune(olderThan: 30 * 86_400), [])
        XCTAssertEqual(kept.map(exists), [false, false])
        XCTAssertEqual(kept.map(TranscriptJobArtifact.read), written)
        XCTAssertEqual(try editor.status(reconciled.id).state, .completed)
    }

    func testUnreadablePackedFileIsAMissingArtifactAndNeverFailsTheJob() throws {
        let folder = try directory()
        let (group, _) = try recordings(in: folder)
        let provider = try lifecycleProvider(in: folder, outcomes: ["completed", "completed"])
        var editor = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        editor.stagesAudioForStandaloneProvider = false
        let prepared = try editor.prepare(project: .multicam(group), documentID: "edit",
                                          options: .init(engine: "lifecycle-fixture"))
        let finished = try editor.run(prepared.id, helper: provider)
        XCTAssertEqual(try editor.verifiedDocuments(finished.id, project: .multicam(group)).count, 1)
        let long = try XCTUnwrap(finished.sessions[0].tracks.first { $0.sourceID == "long" })
        let result = try XCTUnwrap(long.result)
        let packed = TranscriptJobArtifact.packedURL(result)
        // What a version that does not know the packed form finds, or one that finds it damaged: no result.
        try Data(try Data(contentsOf: packed).prefix(100)).write(to: packed)

        let retried = try editor.retry(finished.id, project: .multicam(group))
        XCTAssertEqual(retried.state, .prepared)
        // Only the track without a result is staged for the provider again.
        XCTAssertEqual(retried.sessions[0].tracks.map { $0.audio.map(exists) ?? false },
                       retried.sessions[0].tracks.map { $0.sourceID == "long" })
        let completed = try editor.run(retried.id, helper: provider)
        XCTAssertEqual(completed.state, .completed, completed.message ?? "")
        XCTAssertEqual(try editor.verifiedDocuments(completed.id, project: .multicam(group)).count, 1)
        XCTAssertNotNil(TranscriptJobArtifact.read(result))
    }
}
