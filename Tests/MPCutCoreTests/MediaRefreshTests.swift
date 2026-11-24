import Darwin
import XCTest
@testable import MPCutCore

final class MediaRefreshTests: XCTestCase {
    func testDeepRefreshChangesGenerationAfterInPlaceRewriteWithRestoredStamp() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        try wave(samples: 16_000, amplitude: 100).write(to: file)
        let baseline = try MediaRefresh.check(file)
        let initial = try XCTUnwrap(baseline.media)
        XCTAssertEqual(baseline.state, .refreshed)
        XCTAssertNil(baseline.persistenceError)
        let cache = AnalysisSidecar(media: initial)
        let key = "silence_automatic_threshold_db.v1.0"
        let settingsKey = "silence_threshold_overrides_db.v1"
        let settings = try JSONEncoder().encode([0: -27.0])
        try cache.save([key: Data([1, 2, 3]), settingsKey: settings])
        let generation = try XCTUnwrap(cache.persistedGenerations().first?.id)

        try rewritePreservingStamp(file, with: wave(samples: 16_000, amplitude: 300))
        XCTAssertEqual(try SourceIdentity(file), initial.identity)
        XCTAssertEqual(try MediaRefresh.check(file).state, .unchanged)

        let check = try MediaRefresh.check(file, verification: .deep)
        XCTAssertEqual(check.state, .refreshed)
        XCTAssertEqual(check.preservedAudioStreams, [])
        XCTAssertNil(check.persistenceError)
        let refreshed = try AnalysisSidecar(source: file)
        XCTAssertNil(refreshed.read(key))
        XCTAssertEqual(refreshed.read(settingsKey), settings)
        let published = try XCTUnwrap(refreshed.persistedGenerations().first)
        XCTAssertGreaterThan(published.id, generation)
        XCTAssertEqual(published.reason, "content_changed")
        XCTAssertEqual(try MediaRefresh.check(file, verification: .deep).state, .unchanged)
    }

    func testAudioAnalysisRejectsLiveResultsAfterRewriteWithRestoredStamp() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        try wave(samples: 16_000, amplitude: 100).write(to: file)
        let engine = CutEngine(useSidecar: false)
        let original = try engine.inspect(file, keyframes: true)
        let stream = try XCTUnwrap(original.audio.first?.stream.index)
        let waveform = try AudioAnalysis.scan(original, stream: stream, useSidecar: false)
        let envelope = try AudioAnalysis.envelope(original, stream: stream, from: 0, to: original.duration.seconds,
                                                  columns: 16, useSidecar: false)
        let silence = try AudioAnalysis.silence(original, stream: stream, waveform: waveform, useSidecar: false)

        try rewritePreservingStamp(file, with: wave(samples: 16_000, amplitude: 300))
        let current = try engine.inspect(file, keyframes: true)
        XCTAssertEqual(original.identity, current.identity)
        XCTAssertNotEqual(AudioAnalysisCacheKey(media: original, stream: stream),
                          AudioAnalysisCacheKey(media: current, stream: stream))
        XCTAssertThrowsError(try AudioAnalysis.scan(original, stream: stream, useSidecar: false))
        XCTAssertThrowsError(try AudioAnalysis.silence(original, stream: stream, waveform: waveform, useSidecar: false))
        XCTAssertThrowsError(try AudioAnalysis.envelope(original, stream: stream, from: 0, to: original.duration.seconds,
                                                        columns: 16, useSidecar: false))
        XCTAssertThrowsError(try AnalysisSidecar.sections(media: current, waveforms: [stream: waveform]))
        XCTAssertThrowsError(try AnalysisSidecar.sections(media: current, envelopeOverviews: [stream: envelope]))
        XCTAssertThrowsError(try AnalysisSidecar.sections(media: current, silence: [silence]))
    }

    func testProjectRefreshKeepsShortenedRangeWarningOnWarmCheck() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        let project = folder.appendingPathComponent("edit.cut")
        try wave(samples: 16_000, amplitude: 100).write(to: file)
        try CutProject.sequence([
            CutSequenceClip(id: "clip", file: file.lastPathComponent, from: .zero, to: RationalTime(numerator: 1))
        ]).save(to: project)
        let savedProject = try Data(contentsOf: project)
        XCTAssertTrue(try XCTUnwrap(MediaRefresh.project(at: project).first).referenceIssues.isEmpty)

        try wave(samples: 8_000, amplitude: 100).write(to: file, options: .atomic)
        let refresh = try XCTUnwrap(MediaRefresh.project(at: project).first)
        XCTAssertEqual(refresh.state, .refreshed)
        XCTAssertEqual(refresh.referenceIssues, [.init(id: "clip", reason: .rangeOutsideMedia)])
        let warm = try XCTUnwrap(MediaRefresh.project(at: project).first)
        XCTAssertEqual(warm.state, .unchanged)
        XCTAssertEqual(warm.referenceIssues, refresh.referenceIssues)
        XCTAssertEqual(try Data(contentsOf: project), savedProject)
    }

    func testProjectRefreshChecksStillPresenceAndSkipsHistoryOnlyMedia() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("recording.wav")
        let keptStill = folder.appendingPathComponent("current.png")
        let projectURL = folder.appendingPathComponent("edit.cut")
        try wave(samples: 16_000, amplitude: 100).write(to: audio)
        try Data([1]).write(to: keptStill)
        let duration = RationalTime(numerator: 1)
        let current = CutProject.stillSequence(.init(
            items: [.source(.init(id: "clip", file: audio.lastPathComponent, from: .zero, to: duration))],
            stillAssets: [
                .init(id: "kept", file: keptStill.lastPathComponent, displayName: "Current", fingerprint: String(repeating: "a", count: 64)),
                .init(id: "offline", file: "offline.png", displayName: "Absent", fingerprint: String(repeating: "b", count: 64)),
                .init(gapID: "gap")
            ]
        ))
        let prior = CutProject.sequence([.init(id: "prior", file: "history.wav", from: .zero, to: duration)])
        try current.saveStaged(to: projectURL, undo: [.init(action: "Edit", project: prior)], redo: [],
                               mediaSnapshot: .init())
        let results = try MediaRefresh.project(at: projectURL, persist: false)
        let names = Dictionary(uniqueKeysWithValues: results.map { ($0.source.lastPathComponent, $0) })
        XCTAssertEqual(Set(names.keys), ["recording.wav", "current.png", "offline.png"])
        XCTAssertEqual(names["current.png"]?.state, .unchanged)
        XCTAssertNil(names["current.png"]?.media)
        XCTAssertEqual(names["offline.png"]?.referenceIssues, [.init(id: "offline", reason: .offline)])
    }

    func testProjectRefreshFlagsParticipantGeometryForAChangedRecording() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        let url = folder.appendingPathComponent("edit.cut")
        try wave(samples: 16_000, amplitude: 100).write(to: file)
        let identity = try SourceIdentity(file)
        var project = CutProject.sequence([
            .init(id: "clip", file: file.lastPathComponent, from: .zero, to: RationalTime(numerator: 1))
        ])
        project.participants = .init(sources: [
            .init(sourceID: file.lastPathComponent, analysisIdentity: "accepted",
                  sourceStamp: SceneSourceStamp(identity: identity), sourceInode: identity.inode)
        ])
        try project.save(to: url)
        XCTAssertTrue(try XCTUnwrap(MediaRefresh.project(at: url).first).referenceIssues.isEmpty)
        try wave(samples: 16_000, amplitude: 300).write(to: file, options: .atomic)
        let issue = MediaRefreshReferenceIssue(id: file.lastPathComponent, reason: .participantGeometryNeedsReview)
        XCTAssertTrue(try XCTUnwrap(MediaRefresh.project(at: url).first).referenceIssues.contains(issue))
        XCTAssertTrue(try XCTUnwrap(MediaRefresh.project(at: url).first).referenceIssues.contains(issue))
    }

    func testProjectRefreshChecksRangesWithAnEvidenceFreeSidecar() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("short.wav")
        try wave(samples: 8_000, amplitude: 100).write(to: file)
        let sidecar = try AnalysisSidecar(source: file)
        try sidecar.save(["example": Data([1])])
        let project = folder.appendingPathComponent("edit.cut")
        try CutProject.sequence([
            CutSequenceClip(id: "clip", file: file.lastPathComponent, from: .zero, to: RationalTime(numerator: 1))
        ]).save(to: project)

        let result = try XCTUnwrap(MediaRefresh.project(at: project).first)
        XCTAssertEqual(result.referenceIssues, [.init(id: "clip", reason: .rangeOutsideMedia)])
    }

    func testOptOutBypassesAValidSidecar() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        try wave(samples: 16_000, amplitude: 100).write(to: file)
        _ = try MediaRefresh.check(file)
        let cache = AnalysisSidecar.url(for: file)
        let bytes = try Data(contentsOf: cache)

        let result = try MediaRefresh.check(file, persist: false)
        XCTAssertEqual(result.state, .refreshed)
        XCTAssertNotNil(result.media)
        XCTAssertNil(result.persistenceError)
        XCTAssertEqual(try Data(contentsOf: cache), bytes)
    }

    func testExplicitSaveAfterSessionOnlyRefreshInvalidatesSameStampAnalysis() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        try wave(samples: 16_000, amplitude: 100).write(to: file)
        let original = try XCTUnwrap(MediaRefresh.check(file).media)
        let key = "silence_automatic_threshold_db.v1.0"
        try AnalysisSidecar(media: original).save([key: Data([1, 2, 3])])

        try rewritePreservingStamp(file, with: wave(samples: 16_000, amplitude: 300))
        let refreshed = try XCTUnwrap(MediaRefresh.check(file, previous: original, verification: .deep, persist: false).media)
        let store = AnalysisSidecar(media: refreshed)
        XCTAssertNotNil(store.read(key))
        try store.save(AnalysisSidecar.indexSections(for: refreshed))
        XCTAssertNil(store.read(key))
        XCTAssertEqual(store.persistedGenerations().first?.reason, "content_changed")
    }

    func testRefreshChecksIdentityAgainBeforePublishing() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        try wave(samples: 16_000, amplitude: 100).write(to: file)
        _ = try MediaRefresh.check(file)
        let oldStore = try AnalysisSidecar(source: file)
        let generation = try XCTUnwrap(oldStore.persistedGenerations().first?.id)
        try rewritePreservingStamp(file, with: wave(samples: 16_000, amplitude: 200))
        var replaced = false
        XCTAssertThrowsError(try MediaRefresh.check(file, verification: .deep, progress: { fraction in
            guard fraction >= 0.95, !replaced else { return }
            replaced = true
            do {
                try self.rewritePreservingStamp(file, with: self.wave(samples: 16_000, amplitude: 300))
            } catch {
                XCTFail("Unable to replace media during refresh: \(error)")
            }
        })) { error in
            XCTAssertEqual((error as? CutError)?.code, "source_changed")
        }
        XCTAssertTrue(replaced)
        XCTAssertEqual(try AnalysisSidecar(source: file).persistedGenerations().first?.id, generation)
    }

    private func rewritePreservingStamp(_ file: URL, with data: Data) throws {
        var fileInfo = stat()
        XCTAssertEqual(stat(file.path, &fileInfo), 0)
        try data.write(to: file)
        let times = [fileInfo.st_atimespec, fileInfo.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, file.path, $0.baseAddress, 0) }, 0)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func wave(samples: Int, amplitude: UInt16) -> Data {
        var result = Data()
        func tag(_ value: String) { result.append(contentsOf: value.utf8) }
        func append<Integer: FixedWidthInteger>(_ value: Integer) {
            var value = value.littleEndian
            Swift.withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples * 2)
        tag("RIFF")
        append(byteCount + 36)
        tag("WAVE")
        tag("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        tag("data")
        append(byteCount)
        for _ in 0..<samples { append(amplitude) }
        return result
    }
}
