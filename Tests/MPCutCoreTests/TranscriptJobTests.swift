import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptJobTests: XCTestCase {
    func testZoomSuggestionRequiresCoverageAndUsesTheSelectedSegmentsClock() throws {
        let mix = URL(fileURLWithPath: "/private/tmp/video2067067067.mp4")
        let first = "/private/tmp/Audio Record/audioAlice11067067067.m4a"
        let second = "/private/tmp/Audio Record/audioBob22067067067.m4a"
        let meeting = "/private/tmp|067067067"
        let plan = TranscriptZoomPlan(schema_version: 1, files: [
            .init(path: "/private/tmp/video2067067067.mp4", zoom_segment: nil, meeting: meeting,
                  covered_by: [first, second], iso: nil, speaker: nil),
            .init(path: first, zoom_segment: nil, meeting: meeting, covered_by: nil, iso: true, speaker: "Alice"),
            .init(path: second, zoom_segment: nil, meeting: meeting, covered_by: nil, iso: true, speaker: "Bob")
        ])
        XCTAssertEqual(plan.participants(for: mix), [.init(path: second, speaker: "Bob")])
        XCTAssertTrue(plan.participants(for: URL(fileURLWithPath: first)).isEmpty)
        XCTAssertTrue(plan.participants(for: URL(fileURLWithPath: "/tmp/unrelated.mov")).isEmpty)
        let later = URL(fileURLWithPath: "/private/tmp/zoom_2.mp4")
        let renamed = URL(fileURLWithPath: "/private/tmp/custom.mp4")
        let legacy = TranscriptZoomPlan(schema_version: 1, files: [
            .init(path: later.path, zoom_segment: nil, meeting: meeting, covered_by: [first], iso: nil, speaker: nil),
            .init(path: renamed.path, zoom_segment: 1, meeting: meeting, covered_by: [first], iso: nil, speaker: nil),
            plan.files[1]
        ])
        XCTAssertTrue(legacy.participants(for: later).isEmpty)
        XCTAssertTrue(legacy.participants(for: renamed).isEmpty)
        var verified = legacy.files[1]
        verified.zoom_audio_copy_clock_verified = true
        let checked = TranscriptZoomPlan(schema_version: 1, files: [verified, plan.files[1]])
        XCTAssertEqual(checked.participants(for: renamed), [.init(path: first, speaker: "Alice")])
    }

    func testZoomParticipantJobUsesIsolatedAudioAndBindsToTheMix() throws {
        try inTemporaryFolder { folder in
            let mix = folder.appendingPathComponent("mix.wav")
            let participant = folder.appendingPathComponent("participant.wav")
            try wave(click: 20_000).write(to: mix)
            try wave(click: 40_000).write(to: participant)
            let mixTrack = try XCTUnwrap(TranscriptJobPlan.inventory(media: mix).first?.tracks.first)
            XCTAssertTrue(mixTrack.recognize)
            var options = TranscriptJobOptions(selectedTracks: [mixTrack.id])
            options.zoomParticipants = [mixTrack.id: [.init(path: participant.path, speaker: "Alice")]]
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let job = try store.prepare(media: mix, documentID: "test", options: options)
            let session = try XCTUnwrap(job.sessions.first)
            XCTAssertEqual(session.tracks.map(\.recognize), [false, true])
            XCTAssertEqual(session.bindings.map(\.file), [mixTrack.file.path, mixTrack.file.path])
            let isolated = session.tracks[1]
            XCTAssertEqual(isolated.file.path, participant.path)
            XCTAssertEqual(isolated.speaker, "Alice")
            XCTAssertEqual(isolated.role, "isolated_mic")
            XCTAssertNotEqual(isolated.evidence, mixTrack.evidence)
            XCTAssertEqual(try store.retry(job.id).sessions.first?.fingerprint, session.fingerprint)
            try FileManager.default.moveItem(at: participant, to: folder.appendingPathComponent("moved.wav"))
            let missing = try XCTUnwrap(store.retry(job.id).sessions.first)
            XCTAssertNotEqual(missing.fingerprint, session.fingerprint)
            XCTAssertEqual(missing.tracks.map(\.recognize), [false, true])
            XCTAssertNotNil(missing.tracks[1].unavailable)
            let fresh = try store.prepare(media: mix, documentID: "offline", options: options)
            let unavailable = try XCTUnwrap(fresh.sessions.first?.tracks.last)
            XCTAssertEqual(unavailable.id, isolated.id)
            XCTAssertTrue(unavailable.recognize)
            XCTAssertNotNil(unavailable.unavailable)
            XCTAssertEqual(unavailable.speaker, "Alice")
        }
    }

    func testRequestNormalizationPreservesTrackIDsThatMatchRequestFields() throws {
        let options: [String: Any] = ["track_options": [
            "bindings": ["channel": 0],
            "options": ["speaker": "Host"],
            "offset": ["role": "isolated_mic"]
        ]]
        let normalized = try TranscriptRequestJSON.normalize(options, key: "options")
        let decoded = try JSONDecoder().decode(TranscriptJobOptions.self,
                                               from: JSONSerialization.data(withJSONObject: normalized))
        XCTAssertEqual(decoded.trackOptions, [
            "bindings": .init(channel: 0),
            "options": .init(speaker: "Host"),
            "offset": .init(role: "isolated_mic")
        ])
    }

    func testDiscoveryFindsCurrentAndMovedRecordsWithoutRecoveringOwners() throws {
        try inTemporaryFolder { folder in
            let store = TranscriptJobStore(directory: folder)
            let owner = UUID()
            let moving = try writeDiscoveryRecord(to: store, document: "old.cutdb", owner: owner, running: true)
            let current = try writeDiscoveryRecord(to: store, document: "new.cutdb", owner: owner)
            _ = try writeDiscoveryRecord(to: store, document: "different.cutdb", owner: nil)

            let candidates = try store.matchingRecords(documentID: "new.cutdb", documentIdentity: owner)
            XCTAssertEqual(Set(candidates.map(\.id)), [current.id, moving.id])
            XCTAssertEqual(try store.read(moving.id), candidates.first { $0.id == moving.id })
            XCTAssertEqual(try store.read(moving.id).state, .running)
            XCTAssertEqual(try store.matchingRecords(documentID: "new.cutdb", documentIdentity: nil).map(\.id), [current.id])
        }
    }

    @MainActor
    func testProjectTranscriptDiscoveryPerformance() async throws {
        guard let setting = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_DISCOVERY_JOBS"],
              let count = Int(setting), (1...10_000).contains(count) else {
            throw XCTSkip("Set MPCUT_TRANSCRIPT_DISCOVERY_JOBS to 1–10000 to benchmark project-open job discovery")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TranscriptJobStore(directory: folder)
        let owner = UUID()
        let document = "target.cutdb"
        let current = try writeDiscoveryRecord(to: store, document: document, owner: owner)
        for index in 0..<count {
            _ = try writeDiscoveryRecord(to: store, document: "\(index).cutdb", owner: UUID())
        }
        func baseline() throws -> [TranscriptJobRecord] {
            let paths = Set(try store.list(documentIdentity: owner).map(\.documentID))
            precondition(paths == [document])
            return try store.list(documentID: document)
        }
        func revised() async throws -> (Duration, [TranscriptJobRecord]) {
            let start = ContinuousClock.now
            let work = Task.detached(priority: .utility) {
                try store.matchingRecords(documentID: document, documentIdentity: owner)
            }
            let dispatch = ContinuousClock.now - start
            let candidates = try await work.value
            let commit = ContinuousClock.now
            let records = candidates.compactMap { try? store.status($0.id) }
            return (dispatch + (ContinuousClock.now - commit), records)
        }
        _ = try baseline()
        _ = try await revised()
        for run in 0..<5 {
            let beforeStart = ContinuousClock.now
            let before = try baseline()
            let beforeElapsed = ContinuousClock.now - beforeStart
            let afterStart = ContinuousClock.now
            let after = try await revised()
            let afterElapsed = ContinuousClock.now - afterStart
            XCTAssertEqual(before, after.1)
            XCTAssertEqual(after.1.map(\.id), [current.id])
            print("MPCUT_TRANSCRIPT_DISCOVERY_BENCHMARK run=\(run + 1) jobs=\(count + 1) before_main=\(beforeElapsed) after_main=\(after.0) after_wall=\(afterElapsed)")
        }
    }

    private func writeDiscoveryRecord(to store: TranscriptJobStore, document: String, owner: UUID?,
                                      running: Bool = false) throws -> TranscriptJobRecord {
        let id = UUID()
        let record = TranscriptJobRecord(id: id, documentID: document, documentIdentity: owner, options: .init(),
                                         policy: .reuse, state: running ? .running : .prepared, sessions: [],
                                         workingDirectory: store.directory.appendingPathComponent(id.uuidString, isDirectory: true),
                                         ownerPID: running ? Int32.max : nil,
                                         ownerToken: running ? UUID() : nil)
        try JSONEncoder().encode(record).write(to: store.recordURL(id))
        return record
    }

    func testSupersededJobIsRejectedBeforeReuse() throws {
        try inTemporaryFolder { folder in
            let id = UUID()
            let url = folder.appendingPathComponent(id.uuidString + ".json")
            let bytes = Data(#"{"version":1,"state":"prepared"}"#.utf8)
            try bytes.write(to: url)
            let store = TranscriptJobStore(directory: folder)
            XCTAssertThrowsError(try store.prepare(media: folder.appendingPathComponent("unused.wav"),
                                                   documentID: "project", operationID: id)) {
                XCTAssertEqual(($0 as? CutError)?.code, "unsupported_transcript_job_version")
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testReplacementBindingsHaveDistinctTrackIdentityAndShareRecognitionEvidence() throws {
        try inTemporaryFolder { folder in
            let audio = folder.appendingPathComponent("audio.wav")
            try wave(click: 20_000).write(to: audio)
            let first = MulticamAudioReplacement(id: "recording-a", original: .init(source: "a", stream: 0),
                                                 replacement: .init(source: "replacement", stream: 0),
                                                 relativeOffset: .init(numerator: 1, denominator: 2),
                                                 uncovered: .leaveUncovered)
            let second = MulticamAudioReplacement(id: "recording-b", original: .init(source: "b", stream: 0),
                                                  replacement: first.replacement, relativeOffset: .init(numerator: 1, denominator: 4),
                                                  uncovered: .leaveUncovered)
            var multicam = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: .init(numerator: 4)), angles: [
                .init(id: "a", file: audio.path, audioStream: 0),
                .init(id: "b", file: audio.path, offset: .init(numerator: 2), audioStream: 0)
            ], audioSources: [.init(id: "replacement", file: audio.path, offset: .init(numerator: 99))],
                audio: .mix, switches: [.init(at: .zero, angle: "a")],
                mixLanes: [
                    .init(id: "a-lane", target: .camera("a"), label: "A", colorSlot: 0),
                    .init(id: "b-lane", target: .camera("b"), label: "B", colorSlot: 1)
                ], audioReplacements: [first, second])
            func boundTracks(_ project: MulticamProject) throws -> [TranscriptJobTrack] {
                let session = try XCTUnwrap(TranscriptJobPlan.inventory(project: .multicam(project)).first)
                return session.tracks.filter { $0.projectSourceID == "replacement" }.sorted { $0.sessionStart < $1.sessionStart }
            }
            let bound = try boundTracks(multicam)
            XCTAssertEqual(bound.map(\.id), [first, second].map(TranscriptJobPlan.replacementTrackID))
            XCTAssertEqual(bound.map(\.sessionStart), [.init(numerator: 1, denominator: 2), .init(numerator: 9, denominator: 4)])
            XCTAssertEqual(bound.map(\.sourceID), ["replacement", "replacement"])
            XCTAssertEqual(Set(bound.map(\.evidence)).count, 1)
            XCTAssertEqual(bound.compactMap(\.binding).map(\.trackID), bound.map(\.id))
            let iso = folder.appendingPathComponent("speaker.wav")
            try wave(click: 30_000).write(to: iso)
            var options = TranscriptJobOptions()
            options.zoomParticipants = [bound[0].id: [.init(path: iso.path, speaker: "Alice")]]
            let session = try XCTUnwrap(TranscriptJobPlan.inventory(project: .multicam(multicam), options: options).first)
            let speaker = try XCTUnwrap(session.tracks.first { $0.file == iso })
            XCTAssertEqual(TranscriptJobPlan.replacementTrackIdentity(speaker.id), bound[0].id)
            XCTAssertEqual(speaker.sessionStart, bound[0].sessionStart)
            XCTAssertEqual(CutProject.multicam(multicam).transcriptLane(for: speaker)?.id, "a-lane")
            multicam.audioReplacements[1].relativeOffset = .init(numerator: 1)
            let realigned = try boundTracks(multicam)
            XCTAssertEqual(realigned.map(\.id), bound.map(\.id))
            XCTAssertEqual(realigned.map(\.evidence), bound.map(\.evidence))
            XCTAssertEqual(realigned.last?.sessionStart, .init(numerator: 3))
        }
    }

    func testMultistreamHandoffPreservesIndexedClicksAndReplacementOrdinals() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("first.wav")
            let second = folder.appendingPathComponent("second.wav")
            let movie = folder.appendingPathComponent("dual.mov")
            try wave(click: 20_000).write(to: first)
            try wave(click: 60_000, rate: 48_000).write(to: second)
            try ffmpeg(["-f", "lavfi", "-i", "color=black:s=64x64:r=25:d=4",
                        "-i", first.path, "-itsoffset", "0.5", "-i", second.path,
                        "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0",
                        "-c:v", "mpeg4", "-c:a", "aac", movie.path])
            let clip = CutSequenceClip(id: "source", file: movie.path, from: .zero, to: .init(numerator: 4))
            let repeatClip = CutSequenceClip(id: "repeat", file: movie.path, from: .zero, to: .init(numerator: 2))
            let project = CutProject.sequence([clip, repeatClip])
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let record = try store.prepare(project: project, documentID: "draft")
            XCTAssertEqual(record.state, .prepared)
            XCTAssertEqual(record.sessions.count, 1)
            let session = try XCTUnwrap(record.sessions.first)
            XCTAssertEqual(session.tracks.map(\.state), [.staged, .staged])
            XCTAssertEqual(session.tracks.map(\.streamIndex), [1, 2])
            XCTAssertEqual(session.tracks.map(\.sequenceStreamOrdinal), [0, 1])
            XCTAssertEqual(session.tracks.map { $0.binding?.sequenceStreamOrdinal }, [0, 1])
            XCTAssertTrue(session.tracks.allSatisfy(\.recognize))
            for (track, expected) in zip(session.tracks, [20_000, 28_000]) {
                let samples = try pcm(XCTUnwrap(track.audio))
                XCTAssertEqual(samples.count, 64_000)
                let peak = try XCTUnwrap(samples.indices.max { abs(Int(samples[$0])) < abs(Int(samples[$1])) })
                XCTAssertGreaterThan(abs(Int(samples[peak])), 1_000)
                XCTAssertLessThanOrEqual(abs(peak - expected), 1)
            }
            let replay = try store.prepare(project: .sequence([repeatClip, clip]), documentID: "draft",
                                           operationID: record.id)
            XCTAssertEqual(record, replay)
            let deliberatelySkipped = try store.prepare(project: project, documentID: "draft",
                                                        options: .init(selectedTracks: [session.tracks[1].id]))
            XCTAssertEqual(deliberatelySkipped.sessions[0].tracks.map(\.state), [.skipped, .staged])

            let angle = MulticamSource(id: "camera", file: movie.path, offset: .init(numerator: -1, denominator: 2))
            var multicam = MulticamProject(referenceAngle: angle.id, range: .init(from: .zero, to: .init(numerator: 3)),
                                           angles: [angle], audio: .follow, switches: [])
            let synchronized = try store.prepare(project: .multicam(multicam), documentID: "multicam")
            let synchronizedSession = try XCTUnwrap(synchronized.sessions.first)
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: synchronizedSession.manifest))
                as? [String: Any])
            let tracks = try XCTUnwrap(manifest["tracks"] as? [[String: Any]])
            XCTAssertEqual(tracks.compactMap { $0["start_frame"] as? Int }, [-8_000, -8_000])
            XCTAssertTrue(synchronizedSession.tracks.allSatisfy { $0.binding?.offset == .zero })
            multicam.angles[0].offset = .init(numerator: 1, denominator: 2)
            XCTAssertThrowsError(try store.verifiedOutputs(synchronized.id, project: .multicam(multicam))) {
                XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_job")
            }
            let reconciled = try store.retry(synchronized.id, project: .multicam(multicam))
            XCTAssertNotEqual(reconciled.sessions[0].fingerprint, synchronizedSession.fingerprint)
            XCTAssertEqual(reconciled.sessions[0].tracks.map(\.evidence), synchronizedSession.tracks.map(\.evidence))
        }
    }

    func testRetryByIDUsesReboundSidecarProject() throws {
        try inTemporaryFolder { folder in
            let source = folder.appendingPathComponent("mic.wav")
            try wave(click: 20_000).write(to: source)
            let project = folder.appendingPathComponent("edit.cut")
            let moved = folder.appendingPathComponent("moved/edit.cut")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let id = UUID()
            try SidecarLocations.$storageDirectory.withValue(folder.appendingPathComponent("preferences")) {
                SidecarLocations.mode = .project
                try SidecarLocations.$projectURL.withValue(project) {
                    XCTAssertThrowsError(try store.prepare(media: source, documentID: project.path,
                                                           operationID: id, cancelled: { true }))
                }
                try store.rebindDocument(from: project.path, to: moved.path)
                let resumed = try store.retry(id)
                XCTAssertEqual(resumed.sidecarProjectURL?.path, moved.path)
                let destination = try XCTUnwrap(SidecarLocations(source: source, project: moved).destination)
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathExtension("cutdb").path))
            }
        }
    }

    func testInterruptedDiscoveryCanResumeAfterRebindingDocument() throws {
        try inTemporaryFolder { folder in
            let source = folder.appendingPathComponent("capture.wav")
            try wave(click: 20_000).write(to: source)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let id = UUID()
            XCTAssertThrowsError(try store.prepare(media: source, documentID: "untitled",
                                                       operationID: id, cancelled: { true }))
            XCTAssertEqual(try store.status(id).state, .interrupted)
            try store.rebindDocument(from: "untitled", to: "saved")
            XCTAssertEqual(try store.list(documentID: "saved").map(\.id), [id])
            let prepared = try store.retry(id)
            XCTAssertEqual(prepared.state, .prepared)
            let staged = try XCTUnwrap(prepared.sessions.first?.tracks.first?.audio)
            let alias = folder.appendingPathComponent("jobs-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store.directory)
            XCTAssertEqual(try TranscriptJobStore(directory: alias).status(id).state, .prepared)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
            let track = try XCTUnwrap(prepared.sessions.first?.tracks.first)
            let levels = try Data(contentsOf: XCTUnwrap(track.activity))
            XCTAssertTrue(TranscriptRecognitionCache.Artifacts.matchesActivity(levels, evidence: track.evidence, duration: 48_000))
            let acceptedPCM = try Data(contentsOf: staged)
            try Data("modified staged audio".utf8).write(to: staged)
            XCTAssertEqual(try store.retry(id).state, .prepared)
            XCTAssertEqual(try Data(contentsOf: staged), acceptedPCM)
            XCTAssertEqual(try store.cancel(id).state, .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
            XCTAssertEqual(try store.retry(id).state, .prepared)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
            _ = try store.cancel(id)
            try store.discard(documentID: "saved")
            XCTAssertTrue(try store.list(documentID: "saved").isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.workingDirectory.path))
        }
    }

    func testExternalResultIsBoundAndRejectsChangedMedia() throws {
        try inTemporaryFolder { folder in
            let source = folder.appendingPathComponent("capture.wav")
            try wave(click: 20_000).write(to: source)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let prepared = try store.prepare(media: source, documentID: "capture")
            let session = try XCTUnwrap(prepared.sessions.first)
            let track = try XCTUnwrap(session.tracks.first)
            let result: [String: Any] = [
                "version": 1, "clock": "session", "sample_rate": 16_000,
                "job_id": prepared.id.uuidString, "fingerprint": session.fingerprint,
                "tracks": [["id": track.id, "source_id": track.sourceID, "name": track.name,
                            "stream_index": 0, "role": "unknown", "coverage": "recognized",
                            "origin": ["numerator": 0, "denominator": 1], "stream_evidence": track.evidence,
                            "session_start": ["numerator": 0, "denominator": 1]]],
                "speakers": [], "words": [],
            ]
            var skipped = result
            var skippedTracks = try XCTUnwrap(skipped["tracks"] as? [[String: Any]])
            skippedTracks[0]["coverage"] = "skipped"
            skipped["tracks"] = skippedTracks
            try JSONSerialization.data(withJSONObject: skipped).write(to: session.output, options: .atomic)
            XCTAssertThrowsError(try store.verifiedOutputs(prepared.id, media: source)) {
                XCTAssertEqual(($0 as? CutError)?.code, "invalid_transcript_result")
            }
            try JSONSerialization.data(withJSONObject: result).write(to: session.output, options: .atomic)
            let missingHelper = folder.appendingPathComponent("absent-helper")
            let completed = try store.run(prepared.id, helper: missingHelper)
            XCTAssertEqual(completed.state, .completed)
            XCTAssertEqual(try store.run(prepared.id, helper: missingHelper).updatedAt, completed.updatedAt)
            XCTAssertEqual(try store.verifiedOutputs(prepared.id, media: source), [session.output])
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(track.audio).path))
            var oldStamp = stat()
            XCTAssertEqual(stat(source.path, &oldStamp), 0)
            let oldIdentity = try SourceIdentity(source)
            try wave(click: 22_000).write(to: source)
            let oldTimes = [oldStamp.st_atimespec, oldStamp.st_mtimespec]
            XCTAssertEqual(oldTimes.withUnsafeBufferPointer { utimensat(AT_FDCWD, source.path, $0.baseAddress, 0) }, 0)
            XCTAssertEqual(try SourceIdentity(source), oldIdentity)
            XCTAssertThrowsError(try store.verifiedOutputs(prepared.id, media: source)) {
                XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_job")
            }
            XCTAssertEqual(try store.status(prepared.id).state, .stale)
        }
    }

    func testRetryRefreshesOwnerTimestampBeforeProgress() throws {
        try inTemporaryFolder { folder in
            let source = folder.appendingPathComponent("capture.wav")
            try wave(click: 20_000).write(to: source)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let prepared = try store.prepare(media: source, documentID: "capture")
            let receipt = store.recordURL(prepared.id)
            var job = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
            job["updated_at"] = 0
            try JSONSerialization.data(withJSONObject: job).write(to: receipt, options: .atomic)
            let retried = try store.retry(prepared.id) { progress in
                if progress.state == .preparing {
                    XCTAssertEqual(try? store.status(progress.id).state, .preparing)
                }
            }
            XCTAssertEqual(retried.state, .prepared)
        }
    }

    func testRemovedSelectionMarksStaleAndPreservesHealthyArtifacts() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("wide.wav")
            let second = folder.appendingPathComponent("close.wav")
            try wave(click: 16_000).write(to: first)
            try wave(click: 20_000).write(to: second)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            var group = multicam(wide: first, close: second)
            let inventory = try XCTUnwrap(TranscriptJobPlan.inventory(project: .multicam(group)).first)
            let removed = try XCTUnwrap(inventory.tracks.first { $0.sourceID == "close" })
            let original = try store.prepare(project: .multicam(group), documentID: "edit",
                                             options: .init(selectedTracks: inventory.tracks.map(\.id),
                                                            trackOptions: [removed.id: .init(channel: 0)]))
            let wide = try XCTUnwrap(original.sessions.first?.tracks.first { $0.sourceID == "wide" })
            let marker = Data("accepted result".utf8)
            try marker.write(to: XCTUnwrap(wide.result))
            try store.update(original.id) {
                let index = try XCTUnwrap($0.sessions[0].tracks.firstIndex { $0.id == wide.id })
                $0.sessions[0].tracks[index].recognitionKey = "valid-key-for-this-test"
            }
            group.angles.removeAll { $0.id == "close" }
            XCTAssertThrowsError(try store.verifiedOutputs(original.id, project: .multicam(group))) {
                XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_job")
            }
            XCTAssertEqual(try store.status(original.id).state, .stale)
            let retried = try store.retry(original.id, project: .multicam(group))
            let retained = try XCTUnwrap(retried.sessions.first?.tracks.first)
            XCTAssertEqual(retried.sessions[0].tracks.map(\.id), [wide.id])
            XCTAssertTrue(retained.recognize)
            XCTAssertEqual(retained.recognitionKey, "valid-key-for-this-test")
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.result)), marker)
            XCTAssertTrue(retried.warnings.contains { $0.contains("close.wav") })
        }
    }

    func testOfflineRecordingCanReconcileHealthySiblingAndInvalidateWhenRestored() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("wide.wav")
            let second = folder.appendingPathComponent("close.wav")
            let backup = folder.appendingPathComponent("backup.wav")
            try wave(click: 16_000).write(to: first)
            try wave(click: 20_000).write(to: second)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let project = CutProject.multicam(multicam(wide: first, close: second))
            let original = try store.prepare(project: project, documentID: "edit")
            let oldBinding = try XCTUnwrap(original.sessions[0].tracks.first { $0.sourceID == "close" })
            try FileManager.default.moveItem(at: second, to: backup)
            XCTAssertThrowsError(try store.verifiedOutputs(original.id, project: project)) {
                XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_job")
            }

            let fresh = try TranscriptJobPlan.inventory(project: project)
            let unknownOffline = try XCTUnwrap(fresh[0].tracks.first { $0.sourceID == "close" })
            XCTAssertNil(unknownOffline.streamIndex)
            XCTAssertEqual(unknownOffline.state, .failed)

            let retried = try store.retry(original.id, project: project)
            let session = try XCTUnwrap(retried.sessions.first)
            let offline = try XCTUnwrap(session.tracks.first { $0.sourceID == "close" })
            XCTAssertEqual(offline.id, oldBinding.id)
            XCTAssertEqual(offline.streamIndex, oldBinding.streamIndex)
            XCTAssertTrue(offline.sourceIsCurrent)
            XCTAssertNotNil(offline.unavailable)
            XCTAssertNil(offline.audio)
            try writeResult(session: session, jobID: retried.id)
            let output = try XCTUnwrap(store.verifiedDocuments(retried.id, project: project).first)
            XCTAssertEqual(try store.status(retried.id).state, .partial)
            XCTAssertEqual(output.document.tracks.first { $0.sourceID == "wide" }?.coverage, .recognized)
            XCTAssertEqual(output.document.tracks.first { $0.sourceID == "close" }?.coverage, .failed)

            try FileManager.default.moveItem(at: backup, to: second)
            XCTAssertThrowsError(try store.verifiedDocuments(retried.id, project: project)) {
                XCTAssertEqual(($0 as? CutError)?.code, "stale_transcript_job")
            }
        }
    }

    func testStandaloneJobCanImportCompletedSiblingBeforeOtherManifestRuns() throws {
        try inTemporaryFolder { folder in
            let files = [folder.appendingPathComponent("first.wav"), folder.appendingPathComponent("second.wav")]
            for file in files { try wave(click: 16_000).write(to: file) }
            let project = CutProject.sequence(files.map {
                CutSequenceClip(id: $0.lastPathComponent, file: $0.path, from: .zero, to: .init(numerator: 2))
            })
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let owner = UUID()
            let prepared = try store.prepare(project: project, documentID: "edit", documentIdentity: owner,
                                             documentDiskFingerprint: "persisted-revision")
            XCTAssertEqual(try store.list(documentIdentity: owner).map(\.id), [prepared.id])
            try store.rebindDocument(from: "edit", to: "different-window", documentIdentity: UUID())
            XCTAssertEqual(try store.status(prepared.id).documentID, "edit")
            try writeResult(session: prepared.sessions[0], jobID: prepared.id)
            XCTAssertEqual(try store.verifiedDocuments(prepared.id, project: project).count, 1)
            XCTAssertEqual(try store.status(prepared.id).state, .partial)

            let backup = folder.appendingPathComponent("offline")
            let offline = try XCTUnwrap(prepared.sessions[1].tracks.first?.file)
            try FileManager.default.moveItem(at: offline, to: backup)
            XCTAssertEqual(try store.verifiedDocuments(prepared.id, project: project).count, 1)
            XCTAssertEqual(try store.status(prepared.id).sessions[1].tracks.first?.state, .failed)
            try FileManager.default.moveItem(at: backup, to: offline)
            try writeResult(session: prepared.sessions[1], jobID: prepared.id)
            XCTAssertEqual(try store.verifiedDocuments(prepared.id, project: project).count, 2)
            XCTAssertEqual(try store.status(prepared.id).state, .completed)
            XCTAssertEqual(try store.cancelPendingAttachment(prepared.id, expectedPreparationID: UUID()).state, .completed)
            XCTAssertEqual(try store.cancelPendingAttachment(prepared.id, expectedPreparationID: prepared.preparationID).state, .cancelled)
        }
    }

    func testInterruptedManagedJobCannotAttachUnconfirmedOutput() throws {
        try inTemporaryFolder { folder in
            let file = folder.appendingPathComponent("source.wav")
            try wave(click: 16_000).write(to: file)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let job = try store.prepare(media: file, documentID: "one")
            let running = try store.claimRun(job.id, token: UUID())
            XCTAssertEqual(running.state, .running)
            try writeResult(session: try XCTUnwrap(running.sessions.first), jobID: job.id)
            _ = try store.interrupt(job.id)
            try store.update(job.id) {
                $0.ownerToken = nil
                $0.ownerPID = nil
            }
            XCTAssertThrowsError(try store.verifiedDocuments(job.id, media: file)) {
                XCTAssertEqual(($0 as? CutError)?.code, "transcript_job_unavailable")
            }
            XCTAssertEqual(try store.status(job.id).state, .interrupted)
        }
    }

    func testJobWhoseOwnerNumberNowBelongsToAnotherProcessIsRecovered() throws {
        try inTemporaryFolder { folder in
            let file = folder.appendingPathComponent("wide.wav")
            try wave(click: 16_000).write(to: file)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let job = try store.prepare(media: file, documentID: "one")
            // After a crash and restart the recorded owner number is a system process this user cannot signal.
            try store.update(job.id) { $0.state = .running; $0.ownerToken = UUID(); $0.ownerPID = 1 }
            let recovered = try store.status(job.id)
            XCTAssertEqual(recovered.state, .interrupted)
            XCTAssertNil(recovered.ownerToken)
            XCTAssertEqual(try store.retry(job.id).state, .prepared)
            XCTAssertNoThrow(try store.discard(documentID: "one"))
            // A process that started after the record was last written only reuses the number.
            XCTAssertTrue(TranscriptJobStore.ownerIsGone(getpid(), lastSeen: Date(timeIntervalSince1970: 0)))
            XCTAssertFalse(TranscriptJobStore.ownerIsGone(getpid(), lastSeen: Date()))
        }
    }

    func testEditorRetryOverFinishedTracksDecodesNoAudio() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("wide.wav")
            let second = folder.appendingPathComponent("close.wav")
            try wave(click: 16_000).write(to: first)
            try wave(click: 20_000).write(to: second)
            let provider = folder.appendingPathComponent("provider.py")
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MPCutAppTests/Fixtures/TranscriptLifecycleProvider.py")
            try FileManager.default.copyItem(at: fixture, to: provider)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
            for attempt in 1...4 {
                try Data("completed".utf8).write(to: folder.appendingPathComponent("release-\(attempt)"))
            }
            var group = multicam(wide: first, close: second)
            let options = TranscriptJobOptions(engine: "lifecycle-fixture")
            func staged(_ record: TranscriptJobRecord) -> [Bool] {
                record.sessions[0].tracks.map { FileManager.default.fileExists(atPath: $0.audio?.path ?? "") }
            }

            // An editor that runs the provider itself.
            var editor = TranscriptJobStore(directory: folder.appendingPathComponent("editor-jobs"))
            editor.stagesAudioForStandaloneProvider = false
            let prepared = try editor.prepare(project: .multicam(group), documentID: "edit", options: options)
            XCTAssertEqual(staged(prepared), [true, true])
            let finished = try editor.run(prepared.id, helper: provider)
            XCTAssertEqual(finished.state, .completed)
            XCTAssertEqual(staged(finished), [false, false])
            // Moving a camera changes placement only. Both recognitions still answer for their audio.
            group.angles[1].offset = .init(numerator: 1, denominator: 2)
            let retried = try editor.retry(finished.id, project: .multicam(group))
            XCTAssertEqual(retried.state, .prepared)
            XCTAssertEqual(staged(retried), [false, false])
            let reconciled = try editor.run(retried.id, helper: provider)
            XCTAssertEqual(reconciled.state, .completed)
            XCTAssertEqual(reconciled.sessions[0].tracks.map(\.state), [.recognized, .recognized])
            XCTAssertNoThrow(try editor.verifiedOutputs(reconciled.id, project: .multicam(group)))

            // A standalone provider is handed every recording again.
            let standalone = TranscriptJobStore(directory: folder.appendingPathComponent("standalone-jobs"))
            let handoff = try standalone.prepare(project: .multicam(group), documentID: "edit", options: options)
            let done = try standalone.run(handoff.id, helper: provider)
            XCTAssertEqual(done.state, .completed)
            group.angles[1].offset = .init(numerator: 1, denominator: 4)
            XCTAssertEqual(staged(try standalone.retry(done.id, project: .multicam(group))), [true, true])
        }
    }

    /// Copies the provider that recognizes by rule. `outcomes` holds what each launch reports, in order.
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

    private func exists(_ file: URL?) -> Bool {
        file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func testAttachedJobGivesUpItsSessionOutputAndStillReconciles() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("wide.wav")
            let second = folder.appendingPathComponent("close.wav")
            try wave(click: 16_000).write(to: first)
            try wave(click: 20_000).write(to: second)
            let provider = try lifecycleProvider(in: folder, outcomes: ["completed", "completed", "completed"])
            var group = multicam(wide: first, close: second)
            var editor = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            editor.stagesAudioForStandaloneProvider = false
            let prepared = try editor.prepare(project: .multicam(group), documentID: "edit",
                                              options: .init(engine: "lifecycle-fixture"))
            let finished = try editor.run(prepared.id, helper: provider)
            XCTAssertEqual(finished.state, .completed)
            let output = finished.sessions[0].output
            let original = try XCTUnwrap(editor.verifiedDocuments(finished.id, project: .multicam(group)).first)
            XCTAssertFalse(original.document.words.isEmpty)
            XCTAssertTrue(exists(output))

            let attached = try editor.markAttached(finished.id, expectedPreparationID: finished.preparationID)
            XCTAssertTrue(attached.attached)
            XCTAssertFalse(exists(output))
            // The manifest and each track's result and levels are what a retry reads.
            XCTAssertTrue(exists(attached.sessions[0].manifest))
            for track in attached.sessions[0].tracks {
                XCTAssertTrue(exists(track.result), track.name)
                XCTAssertTrue(exists(track.activity), track.name)
            }
            let status = try editor.status(finished.id)
            XCTAssertEqual(status.state, .completed)
            XCTAssertTrue(status.attached)
            XCTAssertEqual(status.updatedAt, attached.updatedAt)
            XCTAssertEqual(try editor.status(finished.id), status)
            XCTAssertEqual(try editor.list(documentID: "edit"), [status])
            XCTAssertNoThrow(try editor.markAttached(finished.id, expectedPreparationID: finished.preparationID))

            // A second import says what happened and leaves the job as it was.
            XCTAssertThrowsError(try editor.verifiedDocuments(finished.id, project: .multicam(group))) {
                XCTAssertEqual(($0 as? CutError)?.code, "transcript_output_removed")
                XCTAssertTrue(($0 as? CutError)?.message.contains("Retry") == true)
            }
            let refused = try editor.status(finished.id)
            XCTAssertEqual(refused.state, .completed)
            XCTAssertTrue(refused.attached)
            // The retry it asks for builds the same result from the track results, and decodes no audio.
            let again = try editor.retry(finished.id, project: .multicam(group))
            XCTAssertEqual(again.state, .prepared)
            XCTAssertFalse(again.attached)
            XCTAssertEqual(again.sessions[0].tracks.map { exists($0.audio) }, [false, false])
            let rebuilt = try editor.run(again.id, helper: provider)
            XCTAssertEqual(rebuilt.state, .completed)
            let replay = try XCTUnwrap(editor.verifiedDocuments(rebuilt.id, project: .multicam(group)).first)
            XCTAssertEqual(replay.document.words, original.document.words)
            XCTAssertEqual(replay.document.fingerprint, original.document.fingerprint)
            // A job acknowledged by a version that kept the output gives it up to the next prune.
            try editor.update(rebuilt.id) { $0.attached = true }
            XCTAssertTrue(exists(rebuilt.sessions[0].output))
            XCTAssertEqual(try editor.prune(olderThan: 30 * 86_400), [])
            XCTAssertFalse(exists(rebuilt.sessions[0].output))
            XCTAssertEqual(try editor.status(rebuilt.id).state, .completed)

            // Reconcile after a camera moves: placement changes and the recognitions still answer.
            group.angles[1].offset = .init(numerator: 1, denominator: 2)
            let retried = try editor.retry(rebuilt.id, project: .multicam(group))
            XCTAssertEqual(retried.state, .prepared)
            XCTAssertEqual(retried.sessions[0].tracks.map { exists($0.audio) }, [false, false])
            let reconciled = try editor.run(retried.id, helper: provider)
            XCTAssertEqual(reconciled.state, .completed)
            XCTAssertEqual(reconciled.sessions[0].tracks.map(\.state), [.recognized, .recognized])
            let moved = try XCTUnwrap(editor.verifiedDocuments(reconciled.id, project: .multicam(group)).first)
            XCTAssertEqual(moved.document.words.map(\.text), original.document.words.map(\.text))
            XCTAssertNotEqual(moved.document.fingerprint, original.document.fingerprint)
            XCTAssertTrue(exists(reconciled.sessions[0].output))
        }
    }

    func testAcknowledgedSessionLeavesItsSiblingToTheProviderStillToRun() throws {
        try inTemporaryFolder { folder in
            let files = [folder.appendingPathComponent("first.wav"), folder.appendingPathComponent("second.wav")]
            for file in files { try wave(click: 16_000).write(to: file) }
            let project = CutProject.sequence(files.map {
                CutSequenceClip(id: $0.lastPathComponent, file: $0.path, from: .zero, to: .init(numerator: 2))
            })
            // A provider run on its own writes each session output, with or without a result for each track.
            for trackResults in [false, true] {
                let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs-\(trackResults)"))
                let prepared = try store.prepare(project: project, documentID: "edit")
                let (done, waiting) = (prepared.sessions[0], prepared.sessions[1])
                func provide(_ session: TranscriptJobSession) throws {
                    try writeResult(session: session, jobID: prepared.id)
                    if trackResults { try writeTrackResults(session: session) }
                }
                try provide(done)
                XCTAssertEqual(try store.verifiedDocuments(prepared.id, project: project).map(\.url), [done.output])
                XCTAssertEqual(try store.status(prepared.id).state, .partial)
                // The manifest still to run names this recording.
                XCTAssertTrue(exists(waiting.tracks[0].audio))

                // Without track results the output is the job's only copy of the recognition.
                _ = try store.markAttached(prepared.id, expectedPreparationID: prepared.preparationID)
                XCTAssertEqual(exists(done.output), !trackResults)
                try provide(waiting)
                XCTAssertEqual(try store.prune(olderThan: 30 * 86_400), [])
                XCTAssertEqual(exists(done.output), !trackResults)
                XCTAssertTrue(exists(waiting.output))
                XCTAssertEqual(try store.verifiedDocuments(prepared.id, project: project).map(\.url),
                               trackResults ? [waiting.output] : [done.output, waiting.output])
                let completed = try store.status(prepared.id)
                XCTAssertEqual(completed.state, .completed)
                XCTAssertEqual(completed.sessions.flatMap(\.tracks).map { exists($0.audio) }, [false, false])

                _ = try store.markAttached(prepared.id, expectedPreparationID: prepared.preparationID)
                XCTAssertEqual(try store.prune(olderThan: 30 * 86_400), [])
                XCTAssertEqual([done, waiting].map { exists($0.output) }, [!trackResults, !trackResults])
                if trackResults {
                    XCTAssertThrowsError(try store.verifiedDocuments(prepared.id, project: project)) {
                        XCTAssertEqual(($0 as? CutError)?.code, "transcript_output_removed")
                    }
                } else {
                    // A second import reads the same outputs and leaves the job as it was.
                    XCTAssertEqual(try store.verifiedDocuments(prepared.id, project: project).map(\.url),
                                   [done.output, waiting.output])
                    XCTAssertTrue(try store.status(prepared.id).attached)
                }
                XCTAssertEqual(try store.status(prepared.id).state, .completed)
            }
        }
    }

    func testAttachedOutputStaysUntilTrackResultsRepeatIt() throws {
        try inTemporaryFolder { folder in
            let source = folder.appendingPathComponent("capture.wav")
            try wave(click: 20_000).write(to: source)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let prepared = try store.prepare(media: source, documentID: "capture")
            let session = try XCTUnwrap(prepared.sessions.first)
            let result = try XCTUnwrap(session.tracks.first?.result)
            try writeResult(session: session, jobID: prepared.id)
            XCTAssertEqual(try store.verifiedOutputs(prepared.id, media: source), [session.output])
            XCTAssertEqual(try store.status(prepared.id).state, .completed)

            // Only the session output holds the recognition. Neither an acknowledgement nor a
            // prune of a job acknowledged earlier removes it, and it can be imported again.
            try store.update(prepared.id) { $0.attached = true }
            XCTAssertEqual(try store.prune(olderThan: 30 * 86_400), [])
            XCTAssertTrue(exists(session.output))
            _ = try store.markAttached(prepared.id, expectedPreparationID: prepared.preparationID)
            XCTAssertTrue(exists(session.output))
            XCTAssertEqual(try store.verifiedOutputs(prepared.id, media: source), [session.output])

            // With a result for the recognized track, the output is a copy, and prune removes it.
            try writeTrackResults(session: session)
            XCTAssertEqual(try store.prune(olderThan: 30 * 86_400), [])
            XCTAssertFalse(exists(session.output))
            XCTAssertThrowsError(try store.verifiedOutputs(prepared.id, media: source)) {
                XCTAssertEqual(($0 as? CutError)?.code, "transcript_output_removed")
            }
            XCTAssertEqual(try store.status(prepared.id).state, .completed)

            // An output written since the record is still to be imported, so prune leaves it.
            // The acknowledgement that follows its import removes it.
            try writeResult(session: session, jobID: prepared.id)
            XCTAssertEqual(try store.prune(olderThan: 30 * 86_400), [])
            XCTAssertTrue(exists(session.output))
            XCTAssertEqual(try store.verifiedOutputs(prepared.id, media: source), [session.output])
            _ = try store.markAttached(prepared.id, expectedPreparationID: prepared.preparationID)
            XCTAssertFalse(exists(session.output))

            // Losing the track result makes a new output the only copy again.
            try FileManager.default.removeItem(at: result)
            try writeResult(session: session, jobID: prepared.id)
            _ = try store.markAttached(prepared.id, expectedPreparationID: prepared.preparationID)
            XCTAssertEqual(try store.prune(olderThan: 30 * 86_400), [])
            XCTAssertTrue(exists(session.output))
            XCTAssertEqual(try store.verifiedOutputs(prepared.id, media: source), [session.output])
        }
    }

    func testPartialRunKeepsOnlyTheAudioItsRetryReads() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("wide.wav")
            let second = folder.appendingPathComponent("close.wav")
            try wave(click: 16_000).write(to: first)
            try wave(click: 20_000).write(to: second)
            let provider = try lifecycleProvider(in: folder, outcomes: ["partial", "completed"])
            let group = multicam(wide: first, close: second)
            func staged(_ record: TranscriptJobRecord) -> [Bool] {
                record.sessions[0].tracks.map { exists($0.audio) }
            }
            var editor = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            editor.stagesAudioForStandaloneProvider = false
            let prepared = try editor.prepare(project: .multicam(group), documentID: "edit",
                                              options: .init(engine: "lifecycle-fixture"))
            XCTAssertEqual(staged(prepared), [true, true])
            let partial = try editor.run(prepared.id, helper: provider)
            XCTAssertEqual(partial.state, .partial, partial.message ?? "")
            XCTAssertEqual(partial.sessions[0].tracks.map(\.state), [.recognized, .failed])
            XCTAssertEqual(staged(partial), [false, true])
            // Attaching the partial result reads no audio and removes none that the retry needs.
            XCTAssertEqual(try editor.verifiedDocuments(partial.id, project: .multicam(group)).count, 1)
            _ = try editor.markAttached(partial.id, expectedPreparationID: partial.preparationID)
            XCTAssertEqual(staged(partial), [false, true])
            // The failed track has no result to wait for: the output repeats the one that was recognized.
            XCTAssertFalse(exists(partial.sessions[0].output))
            XCTAssertTrue(exists(partial.sessions[0].tracks[0].result))
            XCTAssertFalse(exists(partial.sessions[0].tracks[1].result))

            let failedAudio = try XCTUnwrap(partial.sessions[0].tracks[1].audio)
            let stagedOnce = try SourceIdentity(failedAudio)
            let retried = try editor.retry(partial.id, project: .multicam(group))
            XCTAssertEqual(retried.state, .prepared)
            XCTAssertEqual(staged(retried), [false, true])
            XCTAssertEqual(try SourceIdentity(failedAudio), stagedOnce)
            let completed = try editor.run(retried.id, helper: provider)
            XCTAssertEqual(completed.state, .completed, completed.message ?? "")
            XCTAssertEqual(completed.sessions[0].tracks.map(\.state), [.recognized, .recognized])
            XCTAssertEqual(staged(completed), [false, false])
            XCTAssertNoThrow(try editor.verifiedOutputs(completed.id, project: .multicam(group)))
        }
    }

    func testTrackThatIsOnlyMeasuredKeepsNoStagedAudio() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("wide.wav")
            let second = folder.appendingPathComponent("close.wav")
            try wave(click: 16_000).write(to: first)
            try wave(click: 20_000).write(to: second)
            // Recognizes what it is asked to, and for any other track accepts levels in place of audio.
            let provider = folder.appendingPathComponent("provider.py")
            try Data(#"""
            #!/usr/bin/python3
            import json, sys, wave
            from pathlib import Path
            if sys.argv[1:] == ["capabilities"]:
                print(json.dumps({"version": "measured-fixture", "session_schema_version": 1, "engines": [{
                    "name": "lifecycle-fixture", "aliases": [], "included": True, "default_model": "fixture",
                    "diarization": False, "minimum_macos": "14.0", "model_source": "macos"}]}))
                sys.exit()
            manifest = json.load(sys.stdin)
            def event(name, state, **extra):
                print(json.dumps({"schema_version": 1, "job_id": manifest["job_id"],
                                  "fingerprint": manifest["fingerprint"], "event": name, "status": state, **extra}), flush=True)
            tracks = []
            for track in manifest["tracks"]:
                output = {"id": track["track_id"], "source_id": track["source_id"], "name": track["name"],
                          "stream_evidence": track["stream_evidence"], "role": track["role"],
                          "channel": track.get("channel"), **track["binding"]}
                if track["recognize"]:
                    with wave.open(track["audio"]) as wav:
                        duration = wav.getnframes()
                    levels = {"version": 1, "sample_rate": 16000, "stream_evidence": track["stream_evidence"],
                              "duration_samples": duration,
                              "activity": [{"start_sample": start, "end_sample": min(start + 320, duration), "level": 0.25}
                                           for start in range(0, duration, 320)]}
                    Path(track["activity"]).write_text(json.dumps(levels))
                    Path(track["result"]).write_text(json.dumps({**levels, "recognition_key": track.get("recognition_key"), "words": []}))
                    output["coverage"] = "recognized"
                else:
                    if track.get("audio") is not None:
                        Path("handed-audio").write_text(track["audio"])
                    assert json.loads(Path(track["activity"]).read_text())["stream_evidence"] == track["stream_evidence"]
                    output["coverage"] = "skipped"
                tracks.append(output)
                event("track_finished", output["coverage"], track_id=output["id"])
            Path(manifest["output"]).write_text(json.dumps({
                "version": 1, "sample_rate": 16000, "clock": "session", "tracks": tracks, "speakers": [], "words": [],
                "job_id": manifest["job_id"], "fingerprint": manifest["fingerprint"]}))
            event("session_finished", "completed")
            """#.utf8).write(to: provider)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)

            let project = CutProject.multicam(multicam(wide: first, close: second))
            let inventory = try XCTUnwrap(TranscriptJobPlan.inventory(project: project).first)
            let chosen = try XCTUnwrap(inventory.tracks.first { $0.sourceID == "wide" })
            let options = TranscriptJobOptions(engine: "lifecycle-fixture", selectedTracks: [chosen.id])
            func staged(_ record: TranscriptJobRecord) -> [Bool] {
                ["wide", "close"].map { source in exists(record.sessions[0].tracks.first { $0.sourceID == source }?.audio) }
            }

            var editor = TranscriptJobStore(directory: folder.appendingPathComponent("editor-jobs"))
            editor.stagesAudioForStandaloneProvider = false
            let prepared = try editor.prepare(project: project, documentID: "edit", options: options)
            let measured = try XCTUnwrap(prepared.sessions[0].tracks.first { $0.sourceID == "close" })
            XCTAssertFalse(measured.recognize)
            XCTAssertEqual(staged(prepared), [true, false])
            XCTAssertTrue(exists(measured.activity))
            let finished = try editor.run(prepared.id, helper: provider)
            XCTAssertEqual(finished.state, .completed, finished.message ?? "")
            XCTAssertEqual(finished.sessions[0].tracks.first { $0.id == measured.id }?.state, .skipped)
            XCTAssertFalse(exists(finished.workingDirectory.appendingPathComponent("handed-audio")))
            XCTAssertNoThrow(try editor.verifiedOutputs(finished.id, project: project))
            // A retry measures nothing again.
            XCTAssertEqual(staged(try editor.retry(finished.id, project: project)), [false, false])

            // A restart measures from the audio again, and a standalone provider is handed every recording.
            let restarted = try editor.prepare(project: project, documentID: "edit", options: options,
                                               operationID: prepared.id, policy: .restart)
            XCTAssertEqual(staged(restarted), [true, true])
            let standalone = TranscriptJobStore(directory: folder.appendingPathComponent("standalone-jobs"))
            XCTAssertEqual(staged(try standalone.prepare(project: project, documentID: "edit", options: options)), [true, true])
        }
    }

    func testPartialRunForAStandaloneStoreStagesItsRetryFromTheMedia() throws {
        try inTemporaryFolder { folder in
            let first = folder.appendingPathComponent("wide.wav")
            let second = folder.appendingPathComponent("close.wav")
            try wave(click: 16_000).write(to: first)
            try wave(click: 20_000).write(to: second)
            let provider = try lifecycleProvider(in: folder, outcomes: ["partial", "completed"])
            let group = multicam(wide: first, close: second)
            let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
            let prepared = try store.prepare(project: .multicam(group), documentID: "edit",
                                             options: .init(engine: "lifecycle-fixture"))
            let partial = try store.run(prepared.id, helper: provider)
            XCTAssertEqual(partial.state, .partial, partial.message ?? "")
            XCTAssertEqual(partial.sessions[0].tracks.map { exists($0.audio) }, [false, true])
            // A standalone provider is handed every recording, so the retry extracts the removed one again.
            let retried = try store.retry(partial.id, project: .multicam(group))
            XCTAssertEqual(retried.sessions[0].tracks.map { exists($0.audio) }, [true, true])
            let completed = try store.run(retried.id, helper: provider)
            XCTAssertEqual(completed.state, .completed, completed.message ?? "")
            XCTAssertNoThrow(try store.verifiedOutputs(completed.id, project: .multicam(group)))
        }
    }

    private func multicam(wide: URL, close: URL) -> MulticamProject {
        MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 2)),
                        angles: [.init(id: "wide", file: wide.path), .init(id: "close", file: close.path)],
                        audio: .follow, switches: [])
    }

    private func writeResult(session: TranscriptJobSession, jobID: UUID) throws {
        func time(_ value: RationalTime) -> [String: Int64] {
            ["numerator": value.numerator, "denominator": value.denominator]
        }
        let tracks = session.tracks.map { input -> [String: Any] in
            var track: [String: Any] = [
                "id": input.id, "source_id": input.sourceID, "name": input.name, "role": input.role,
                "coverage": input.unavailable != nil ? "failed" : (input.recognize ? "recognized" : "skipped"),
                "origin": time(input.origin), "session_start": time(input.sessionStart),
                "stream_evidence": input.evidence,
            ]
            track["stream_index"] = input.streamIndex
            track["channel"] = input.channel
            track["error"] = input.unavailable
            return track
        }
        let output: [String: Any] = [
            "version": 1, "sample_rate": 16_000, "clock": "session", "job_id": jobID.uuidString,
            "fingerprint": session.fingerprint, "tracks": tracks, "speakers": [], "words": [],
        ]
        try JSONSerialization.data(withJSONObject: output).write(to: session.output, options: .atomic)
    }

    /// The result a provider leaves for each track it recognizes, beside the session output.
    private func writeTrackResults(session: TranscriptJobSession) throws {
        for track in session.tracks where track.recognize && track.unavailable == nil {
            let samples = try track.duration.roundedToSamples(16_000)
            let result: [String: Any] = [
                "version": 1, "sample_rate": 16_000, "stream_evidence": track.evidence, "duration_samples": samples,
                "activity": [[String: Any]](), "words": [[String: Any]](),
            ]
            try JSONSerialization.data(withJSONObject: result).write(to: XCTUnwrap(track.result), options: .atomic)
        }
    }

    private func inTemporaryFolder(_ work: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try work(folder)
    }

    private func ffmpeg(_ args: [String]) throws {
        let paths = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("The AAC fixture requires ffmpeg.")
        }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = ["-hide_banner", "-loglevel", "error"] + args
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
    }

    private func wave(click: Int, rate: UInt32 = 16_000) throws -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ integer: T) {
            var littleEndian = integer.littleEndian
            withUnsafeBytes(of: &littleEndian) { header.append(contentsOf: $0) }
        }
        let frames = Int(rate) * 3
        header.append(Data("RIFF".utf8))
        append(UInt32(frames * 2 + 36))
        header.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        header.append(Data("data".utf8))
        append(UInt32(frames * 2))
        for position in 0..<frames { append(Int16(position == click ? 25_000 : 0)) }
        return header
    }

    private func pcm(_ file: URL) throws -> [Int16] {
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes.dropFirst(36).prefix(4), as: UTF8.self), "data")
        return bytes.withUnsafeBytes { buffer in
            stride(from: 44, to: bytes.count, by: 2).map {
                Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: Int16.self))
            }
        }
    }
}
