import Darwin
import Foundation
@testable import MPCutCore
import XCTest

final class ProjectMediaSnapshotTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func clip(_ file: String, id: String = "clip") -> CutSequenceClip {
        CutSequenceClip(id: id, file: file, from: .zero, to: .init(numerator: 1))
    }

    func testPreservesUnknownEntryFieldsAndIgnoresUnknownVersion() throws {
        let json = #"{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[{"id":"one","file":"A.wav","from":"0","to":"1"}],"media_snapshot":{"version":1,"entries":[{"path":"A.wav","future":{"file":4,"fraction":0.25,"bindings":[null,{"offset":"anything"}]}}]}}"#
        let loaded = try CutProject.decodeDocument(Data(json.utf8), limit: 0)
        let file = try temporaryDirectory().appendingPathComponent("saved.cut")
        try loaded.project.save(to: file, mediaSnapshot: loaded.mediaSnapshot)
        XCTAssertEqual(try CutProject.loadDocument(from: file, limit: 0).mediaSnapshot, loaded.mediaSnapshot)
        XCTAssertNotNil(loaded.mediaSnapshot.entries.first?.unknownFields["future"])

        let unknown = json.replacingOccurrences(of: #""version":1"#, with: #""version":99"#)
            .replacingOccurrences(of: #""entries":"#, with: #""future_shape":"#)
        XCTAssertEqual(try CutProject.decodeDocument(Data(unknown.utf8), limit: 0).mediaSnapshot, .empty)
        let withoutSnapshot = #"{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[]}"#
        XCTAssertEqual(try CutProject.decodeDocument(Data(withoutSnapshot.utf8), limit: 0).mediaSnapshot, .empty)
    }

    func testSnapshotKeepsEntriesReferencedByCurrentAndHistory() throws {
        let current = CutProject.sequence([clip("now")])
        let undo: [CutHistoryState] = [.init(action: "Undo", project: .sequence([clip("a-undo")]))]
        let redo: [CutHistoryState] = [.init(action: "Redo", project: .sequence([clip("b-redo")]))]
        let snapshot = ProjectMediaSnapshot(entries: ["a-undo", "b-redo", "now"].map { .init(path: $0) })
        let (bytes, _) = try current.encodedArchive(undo: undo, redo: redo, mediaSnapshot: snapshot)
        let reopened = try CutProject.decodeDocument(bytes, limit: 10)
        XCTAssertEqual(reopened.mediaSnapshot.entries.map(\.path), ["now", "a-undo", "b-redo"])
        XCTAssertEqual(reopened.undo, undo)
        XCTAssertEqual(reopened.redo, redo)
    }

    func testLargeSnapshotKeepsAllReferencedEntries() throws {
        let current = CutProject.sequence([clip("a", id: "one"), clip("b", id: "two")])
        var entry = ProjectMediaSnapshot.Entry(path: "a")
        entry.unknownFields["future"] = .string(String(repeating: "x", count: 4 << 20))
        let snapshot = ProjectMediaSnapshot(entries: [entry, .init(path: "b")])
        let (bytes, _) = try current.encodedArchive(undo: [], redo: [], mediaSnapshot: snapshot)
        let reopened = try CutProject.decodeDocument(bytes, limit: 0)
        XCTAssertEqual(reopened.mediaSnapshot, snapshot)
    }

    func testRevisionStageAndCopyKeepCurrentAndHistoryOnlyEntries() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("original.cut")
        let stage = directory.appendingPathComponent("stage.cut")
        let destination = directory.appendingPathComponent("copy.cut")
        let current = CutProject.sequence([clip("now")])
        let undo: [CutHistoryState] = [.init(action: "Edit", project: .sequence([clip("older")]))]
        let snapshot = ProjectMediaSnapshot(entries: [.init(path: "now"), .init(path: "older")])
        _ = try current.saveRevision(to: source, undo: undo, redo: [], mediaSnapshot: snapshot, expected: nil)
        try current.saveStaged(to: stage, undo: undo, redo: [], mediaSnapshot: snapshot)
        try current.saveNewCopy(to: destination, undo: undo, redo: [],
                                mediaSnapshot: snapshot, check: {})
        for url in [source, stage, destination] {
            let document = try CutProject.loadDocument(from: url, limit: 10)
            XCTAssertEqual(document.mediaSnapshot, snapshot)
            XCTAssertEqual(document.undo, undo)
        }
    }

    func testMulticamBareWriterPreservesSnapshot() throws {
        let group = MulticamProject(referenceAngle: "A", range: .init(from: .zero, to: .init(numerator: 2)),
                                    angles: [.init(id: "A", file: "missing.mov")],
                                    audio: .follow, switches: [.init(at: .zero, angle: "A")])
        let snapshot = ProjectMediaSnapshot(entries: [.init(path: "missing.mov")])
        let file = try temporaryDirectory().appendingPathComponent("group.cut")
        try group.save(to: file, mediaSnapshot: snapshot)
        let reopened = try MulticamProject.loadDocument(from: file)
        XCTAssertEqual(reopened.project, group)
        XCTAssertEqual(reopened.mediaSnapshot, snapshot)
    }

    func testBindingHistoryAppliesBothWaysAndKeepsLaterAttachment() throws {
        let asset = try TranscriptStore.put(TranscriptDocument(clock: .presentation))
        let later = TranscriptAttachment(id: "later", asset: asset, bindings: [.init(trackID: "other", file: "third.wav", streamIndex: 0)])
        func project(_ path: String, laterAttachment: Bool = false) -> CutProject {
            var result = CutProject.sequence([clip(path)])
            let attachment = TranscriptAttachment(id: "speech", asset: asset, bindings: [.init(trackID: "track", file: path, streamIndex: 0)])
            result.transcripts = ProjectTranscripts(attachments: laterAttachment ? [attachment, later] : [attachment], revision: 7)
            return result
        }
        let current = project("current.wav", laterAttachment: true)
        let undo: [CutHistoryState] = [.init(action: "Replace", project: project("old.wav"))]
        let redo: [CutHistoryState] = [.init(action: "Replace", project: project("future.wav"))]
        let snapshot = ProjectMediaSnapshot(entries: ["old.wav", "future.wav"].map { .init(path: $0) })
        let (data, _) = try current.encodedArchive(undo: undo, redo: redo, mediaSnapshot: snapshot)
        let loaded = try CutProject.decodeEditorDocument(data, limit: 10)
        XCTAssertEqual(loaded.project, current)
        XCTAssertEqual(loaded.undo.first?.project.transcripts.attachments.first?.bindings.first?.file, "old.wav")
        XCTAssertEqual(loaded.redo.first?.project.transcripts.attachments.first?.bindings.first?.file, "future.wav")
        XCTAssertEqual(loaded.undo.first?.project.transcripts.attachments.last, later)
        XCTAssertEqual(loaded.redo.first?.project.transcripts.revision, 8)
        XCTAssertEqual(Set(loaded.media.mediaSnapshot.entries.map(\.path)), ["old.wav", "future.wav"])
    }

    func testCutConversionPreservesBindingOnlyHistoryAndRebasesItsSnapshot() throws {
        let directory = try temporaryDirectory()
        let copyDirectory = directory.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("original.cut")
        let destination = copyDirectory.appendingPathComponent("copied.cut")
        let asset = try TranscriptStore.put(TranscriptDocument(clock: .presentation))
        var project = CutProject.sequence([clip("program.wav")])
        let before = TranscriptBinding(trackID: "speech", file: "after.wav", streamIndex: 0)
        let after = TranscriptBinding(trackID: "speech", file: "before.wav", streamIndex: 0)
        project.transcripts.attachments = [.init(id: "speech", asset: asset, bindings: [before])]
        let change = TranscriptBindingChange(attachmentID: "speech", trackID: "speech", before: before, after: after)
        let undo = [CutHistoryState(action: "Replace", project: project, bindingChanges: [change])]
        let snapshot = ProjectMediaSnapshot(entries: [.init(path: "before.wav"), .init(path: "after.wav")])
        try project.save(to: source, undo: undo, redo: [], mediaSnapshot: snapshot)
        try ProjectConverter.convert(input: source, output: destination)
        let reopened = try CutProject.loadDocument(from: destination, limit: 1)
        XCTAssertEqual(reopened.project.transcripts.attachments.first?.bindings.first?.file, "../after.wav")
        XCTAssertEqual(reopened.undo.first?.project.transcripts.attachments.first?.bindings.first?.file, "../before.wav")
        XCTAssertEqual(reopened.undo.first?.bindingChanges?.first?.before.file, "../after.wav")
        XCTAssertEqual(reopened.mediaSnapshot.entries.map(\.path), ["../after.wav", "../before.wav"])
    }

    func testProofAndFingerprintComeFromTheSameGeneration() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.wav")
        let copy = directory.appendingPathComponent("copy.wav")
        let engine = CutEngine(useSidecar: false)
        try wave(amplitude: 123).write(to: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let first = try engine.inspect(source)
        let original = ProjectMediaSnapshot.Entry(path: "source.wav", media: first)
        XCTAssertEqual(original.sourceFingerprint, first.identity.transcriptFingerprint)
        XCTAssertTrue(original.verifies(try engine.inspect(copy)))

        try wave(amplitude: 456).write(to: source, options: .atomic)
        let second = try engine.inspect(source)
        let replacement = ProjectMediaSnapshot.Entry(path: "source.wav", media: second)
        XCTAssertNotEqual(replacement.sourceFingerprint, original.sourceFingerprint)
        XCTAssertEqual(replacement.sourceFingerprint, second.identity.transcriptFingerprint)
        XCTAssertFalse(original.verifies(second))
        XCTAssertFalse(original.verifies(first))

        let rebound = first.withRefreshEvidence(first.refreshEvidence, identity: second.identity)
        let unproven = ProjectMediaSnapshot.Entry(path: "source.wav", media: rebound)
        XCTAssertNil(unproven.sourceFingerprint)
        XCTAssertFalse(unproven.hasCompleteProof)

        let savedEvidence = try XCTUnwrap(first.refreshEvidence).encoded()
        let cacheOnly = first.withRefreshEvidence(MediaRefreshEvidence.decode(savedEvidence))
        let cacheEntry = ProjectMediaSnapshot.Entry(path: "source.wav", media: cacheOnly)
        XCTAssertNil(cacheEntry.sourceFingerprint)
        XCTAssertFalse(cacheEntry.hasCompleteProof)
        XCTAssertEqual(cacheEntry.duration, original.duration)
    }

    func testAProjectKeepsADigestOfTheEvidence() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.wav")
        let copy = directory.appendingPathComponent("copy.wav")
        let engine = CutEngine(useSidecar: false)
        try wave(amplitude: 123).write(to: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let media = try engine.inspect(source)
        let entry = ProjectMediaSnapshot.Entry(path: "source.wav", media: media)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertNil(saved["evidence"])
        let digest = try XCTUnwrap(saved["evidence_sha256"] as? String)
        XCTAssertEqual(digest.count, 64)

        let reread = try JSONDecoder().decode(ProjectMediaSnapshot.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertTrue(reread.hasCompleteProof)
        XCTAssertTrue(reread.verifies(try engine.inspect(copy)))

        // A digest that is not one is refused.
        var damaged = saved
        damaged["evidence_sha256"] = "not a digest"
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectMediaSnapshot.Entry.self,
                                                      from: JSONSerialization.data(withJSONObject: damaged)))
    }

    func testInPlaceRewriteWithRestoredModificationTimeCannotReuseProof() throws {
        let source = try temporaryDirectory().appendingPathComponent("source.wav")
        try wave(amplitude: 123).write(to: source)
        let engine = CutEngine(useSidecar: false)
        let first = try engine.inspect(source)
        let saved = ProjectMediaSnapshot.Entry(path: "source.wav", media: first)

        var before = stat()
        XCTAssertEqual(stat(source.path, &before), 0)
        let file = try FileHandle(forWritingTo: source)
        try file.write(contentsOf: wave(amplitude: 456))
        var timestamps = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(futimens(file.fileDescriptor, &timestamps), 0)
        try file.close()

        let second = try engine.inspect(source)
        XCTAssertEqual(first.identity.transcriptFingerprint, second.identity.transcriptFingerprint)
        XCTAssertNotEqual(first.identity.changeTime, second.identity.changeTime)
        XCTAssertFalse(saved.verifies(second))
        XCTAssertFalse(saved.verifies(first))
        let rebound = first.withRefreshEvidence(first.refreshEvidence, identity: second.identity)
        let unproven = ProjectMediaSnapshot.Entry(path: "source.wav", media: rebound)
        XCTAssertFalse(unproven.hasCompleteProof)
        XCTAssertNil(unproven.sourceFingerprint)
    }

    func testSnapshotClockUsesSourceRelativeZeroForDelayedPicture() throws {
        let candidates = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                          "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let ffmpeg = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("FFmpeg is required to build the timecode fixture.")
        }
        let source = try temporaryDirectory().appendingPathComponent("camera.mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error",
                             "-itsoffset", "0.4", "-f", "lavfi", "-i", "color=black:s=32x32:r=25:d=2",
                             "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono:d=2.4",
                             "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-threads", "1",
                             "-preset", "ultrafast", "-c:a", "pcm_s16le", "-timecode", "00:00:02:01", source.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let engine = CutEngine(useSidecar: false)
        let media = try engine.inspect(source, keyframes: true)
        let entry = ProjectMediaSnapshot.Entry(path: "camera.mov", media: media)
        let clock = try XCTUnwrap(entry.sourceClock)
        XCTAssertEqual(media.origin, RationalTime(numerator: 2, denominator: 5))
        XCTAssertEqual(clock.kind, .timecode)
        XCTAssertEqual(clock.start, RationalTime(numerator: 51, denominator: 25))
        XCTAssertEqual(clock.start, try MulticamSync.stamp(media)?.start)
        let multicam = ProjectMediaSnapshot.Entry(path: "camera.mov", media: try engine.multicamClock(media))
        XCTAssertEqual(multicam.origin, entry.origin)
        XCTAssertEqual(multicam.duration, entry.duration)
        XCTAssertEqual(multicam.sourceClock, clock)
    }

    private func wave(amplitude: Int16) -> Data {
        let samples = 800
        var result = Data()
        func append<Integer: FixedWidthInteger>(_ value: Integer) {
            var value = value.littleEndian
            Swift.withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        result.append(contentsOf: "RIFF".utf8)
        append(UInt32(samples * 2 + 36))
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8_000))
        append(UInt32(16_000))
        append(UInt16(2))
        append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(UInt32(samples * 2))
        for _ in 0..<samples { append(amplitude) }
        return result
    }
}
