import Foundation
import XCTest
@testable import MPCutCore

final class ProjectMediaReplaceTests: XCTestCase {
    func testPreviewReportsTrimAndLossBeforeApplying() throws {
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let candidate = folder.appendingPathComponent("short.wav")
            try wave(candidate, seconds: 3)
            let project = CutProject.sequence([
                clip("partial", "old.wav", 1, 4),
                clip("lost", "old.wav", 5, 7)
            ])

            let preview = try ProjectMediaReplace.preview(project, relativeTo: projectURL,
                                                           source: "old.wav", candidate: candidate)
            XCTAssertEqual(preview.report.trimmedUseIDs, ["partial"])
            XCTAssertEqual(preview.report.lostUseIDs, ["lost"])
            XCTAssertEqual(preview.report.beforeDuration, time(5))
            XCTAssertFalse(preview.report.canApply)
            XCTAssertThrowsError(try preview.applying(to: project))

            let approved = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav",
                                                           candidate: candidate, options: .init(loss: .remove))
            XCTAssertEqual(approved.report.afterDuration, time(2))
            let changed = try approved.applying(to: project)
            XCTAssertEqual(changed.sequenceClips, [clip("partial", "short.wav", 1, 3)])
            XCTAssertEqual(approved.snapshot.entries.first?.duration, time(3))
            XCTAssertThrowsError(try approved.applying(to: changed))

            let keep = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav",
                                                        candidate: candidate, options: .init(conform: .keep, loss: .keepOffline))
            XCTAssertEqual(try keep.applying(to: project).sequenceClips, [
                clip("partial", "short.wav", 1, 4), clip("lost", "short.wav", 5, 7)
            ])
        }
    }

    func testReplacementMapsClockFromSavedOfflineEntry() throws {
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let candidate = folder.appendingPathComponent("later.wav")
            try wave(candidate, seconds: 44, clockSeconds: 30)
            var old = ProjectMediaSnapshot.Entry(path: "offline.wav")
            old.sourceClock = .init(kind: .broadcastWave, start: time(20))
            let snapshot = ProjectMediaSnapshot(entries: [old])
            let project = CutProject.sequence([clip("take", "offline.wav", 40, 42)])

            let moved = try ProjectMediaReplace.preview(project, snapshot: snapshot, relativeTo: projectURL,
                                                        source: "offline.wav", candidate: candidate,
                                                        options: .init(clock: .sourceTimecode))
            XCTAssertTrue(moved.report.canKeepTimecode)
            XCTAssertEqual(try moved.applying(to: project).sequenceClips?.first?.from, time(30))
            let relative = try ProjectMediaReplace.preview(project, snapshot: snapshot, relativeTo: projectURL,
                                                           source: "offline.wav", candidate: candidate)
            XCTAssertEqual(try relative.applying(to: project).sequenceClips?.first?.from, time(40))

            old.sourceClock = .init(kind: .timecode, start: time(20))
            let mixed = ProjectMediaSnapshot(entries: [old])
            let unconfirmed = try ProjectMediaReplace.preview(project, snapshot: mixed, relativeTo: projectURL,
                source: "offline.wav", candidate: candidate, options: .init(clock: .sourceTimecode))
            XCTAssertTrue(unconfirmed.report.needsSharedTimeOfDay)
            XCTAssertFalse(unconfirmed.report.canApply)
            let confirmed = try ProjectMediaReplace.preview(project, snapshot: mixed, relativeTo: projectURL,
                source: "offline.wav", candidate: candidate, options: .init(clock: .sourceTimecode, sharedTimeOfDay: true))
            XCTAssertEqual(try confirmed.applying(to: project).sequenceClips?.first?.from, time(30))
        }
    }

    func testOccurrenceAndAllUsesKeepBindingUndoIndependentOfLaterAttachment() throws {
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let candidate = folder.appendingPathComponent("take.wav")
            try wave(candidate, seconds: 4)
            let bindings = [TranscriptBinding(trackID: "track", file: "old.wav", streamIndex: 0,
                                               sourceFingerprint: String(repeating: "a", count: 64), sourceConfirmed: true)]
            let digest = String(repeating: "b", count: 64)
            let attachment = TranscriptAttachment(id: "old",
                asset: .init(file: "edit.transcripts/\(digest).json", sha256: digest, unavailable: .missing),
                bindings: bindings)
            var project = CutProject.sequence([clip("first", "old.wav", 0, 2), clip("other", "old.wav", 2, 4)])
            project.transcripts = .init(attachments: [attachment])
            let one = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav",
                                                      candidate: candidate, options: .init(useID: "first"))
            let occurrence = try one.applying(to: project)
            XCTAssertEqual(occurrence.sequenceClips?.map(\.file), ["take.wav", "old.wav"])
            XCTAssertEqual(occurrence.transcripts.attachments, [attachment])

            let all = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav", candidate: candidate)
            var replaced = try all.applying(to: project)
            XCTAssertEqual(replaced.transcripts.attachments.first?.bindings.first?.file, "take.wav")
            XCTAssertEqual(replaced.transcripts.attachments.first?.bindings.first?.sourceConfirmed, false)
            XCTAssertEqual(replaced.transcripts.attachments.first?.bindings.first?.sourceStatus(in: replaced, relativeTo: projectURL), .changed)
            var later = attachment
            later.id = "later"
            later.bindings = []
            replaced.transcripts.attachments.append(later)
            try replaced.save(to: projectURL, undo: [.init(action: "Replace Source File", project: project)], redo: [],
                              mediaSnapshot: all.snapshot)
            let saved = try CutProject.loadDocument(from: projectURL, limit: 4)
            XCTAssertEqual(saved.undo.first?.project.transcripts.attachments, [attachment, later])
        }
    }

    func testMissingSelectedTrackRequiresExplicitMapping() throws {
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let candidate = folder.appendingPathComponent("mono.wav")
            try wave(candidate, seconds: 3)
            let project = CutProject.sequence([.init(id: "clip", file: "old.wav", from: .zero, to: time(1), audioTrack: 1)])
            let blocked = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav", candidate: candidate)
            XCTAssertEqual(blocked.report.unresolvedAudioStreams, [1])
            XCTAssertFalse(blocked.report.canApply)
            let chosen = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav",
                                                         candidate: candidate, options: .init(streamMapping: [1: 0]))
            XCTAssertEqual(chosen.report.audioMapping, [1: 0])
            XCTAssertEqual(try chosen.applying(to: project).sequenceClips?.first?.audioTrack, 0)
        }
    }

    func testReorderedIdenticalLayoutsMapBySavedTrackName() throws {
        let executables = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"],
                           "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let ffmpeg = executables.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Requires FFmpeg for the named multistream fixture.")
        }
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let old = folder.appendingPathComponent("old.mka")
            let new = folder.appendingPathComponent("reordered.mka")
            let wav = folder.appendingPathComponent("source.wav")
            try wave(wav, seconds: 2)

            func make(_ file: URL, names: [String]) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", wav.path,
                    "-map", "0:a:0", "-map", "0:a:0", "-c:a", "pcm_s16le",
                    "-metadata:s:a:0", "title=\(names[0])", "-metadata:s:a:1", "title=\(names[1])", file.path]
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }

            try make(old, names: ["Dialogue", "Room"])
            try make(new, names: ["Room", "Dialogue"])
            let indexed = try CutEngine(useSidecar: false).inspect(old, keyframes: true)
            let entry = ProjectMediaSnapshot.Entry(path: "old.mka", media: indexed)
            let snapshot = try JSONDecoder().decode(ProjectMediaSnapshot.self,
                from: JSONEncoder().encode(ProjectMediaSnapshot(entries: [entry])))
            try FileManager.default.removeItem(at: old)
            let project = CutProject.sequence([clip("take", "old.mka", 0, 1)])
            let preview = try ProjectMediaReplace.preview(project, snapshot: snapshot, relativeTo: projectURL,
                                                           source: "old.mka", candidate: new)
            XCTAssertEqual(preview.report.audioMapping, [0: 1])
            XCTAssertEqual(preview.report.candidateAudioStreams.map(\.name), ["Room", "Dialogue"])
            XCTAssertEqual(try preview.applying(to: project).sequenceClips?.first?.audioTrack, 1)
        }
    }

    func testStillPlacementReplacementForksSharedAssetAndResetsOnlySelectedCrop() throws {
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let candidate = folder.appendingPathComponent("replacement.png")
            let fixture = StillAsset(gapID: "fixture").file
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: candidate)
            let crop = StillImageFraming.Crop(x: .zero, y: .zero,
                                               width: .init(numerator: 1, denominator: 2), height: time(1))
            let framing = StillImageFraming(mode: .fill, crop: crop)
            let cadence = RationalTime(numerator: 1, denominator: 24)
            let project = CutProject.stillSequence(.init(items: [
                .still(.init(id: "first", assetID: "photo", duration: time(1), cadence: cadence, framing: framing)),
                .still(.init(id: "second", assetID: "photo", duration: time(1), cadence: cadence, framing: framing))
            ], stillAssets: [.init(id: "photo", file: "old.png", displayName: "Old image", fingerprint: "old")],
               stillFormat: .init(width: 128, height: 128, cadence: cadence, codec: .h264, container: "mov")))
            let preview = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.png",
                                                           candidate: candidate, options: .init(useID: "first", resetCrop: true))
            let revised = try preview.applying(to: project)
            XCTAssertNotNil(preview.report.newStill)
            XCTAssertEqual(revised.stillAssets.count, 2)
            XCTAssertEqual(revised.stillAssets.first { $0.id == revised.stillInserts[0].assetID }?.file, "replacement.png")
            XCTAssertNil(revised.stillInserts[0].framing.crop)
            XCTAssertEqual(revised.stillInserts[1], project.stillInserts[1])
        }
    }

    func testMulticamReplacementAudioRechecksRelativeOffsetAndCoverage() throws {
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let candidate = folder.appendingPathComponent("microphone.wav")
            try wave(candidate, seconds: 2)
            let camera = MulticamSource(id: "camera", file: "camera.mov", audioStream: 1)
            let mic = MulticamSource(id: "mic", file: "old.wav", audioStream: 0)
            let original = MulticamAudioSelection(source: camera.id, stream: 1)
            let dub = MulticamAudioReplacement(id: "dub", original: original, replacement: .init(source: mic.id, stream: 0),
                                                relativeOffset: .zero, uncovered: .keepOriginal)
            let project = CutProject.multicam(.init(referenceAngle: camera.id, range: .init(from: .zero, to: time(5)),
                angles: [camera], audioSources: [mic], audio: .fixed(original),
                switches: [.init(at: .zero, angle: camera.id)], audioReplacements: [dub]))
            let preview = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav",
                                                           candidate: candidate, options: .init(replacementOffset: time(1)))
            XCTAssertTrue(preview.report.warnings.contains { $0.contains("uncovered audio") })
            XCTAssertEqual(preview.report.offsets.first?.after, time(1))
            let revised = try preview.applying(to: project)
            if case .multicam(let multicam) = revised {
                XCTAssertEqual(multicam.audioReplacements[0].relativeOffset, time(1))
                XCTAssertEqual(multicam.audioSources[0].file, "microphone.wav")
            } else {
                XCTFail("Expected a multicam project")
            }
        }
    }

    func testReplacementGenerationIsCheckedOnCommit() throws {
        try withDirectory { folder in
            let projectURL = folder.appendingPathComponent("edit.cut")
            let candidate = folder.appendingPathComponent("new.wav")
            try wave(candidate, seconds: 2)
            let project = CutProject.sequence([clip("take", "old.wav", 0, 1)])
            let preview = try ProjectMediaReplace.preview(project, relativeTo: projectURL, source: "old.wav", candidate: candidate)
            try wave(candidate, seconds: 3)
            XCTAssertThrowsError(try preview.applying(to: project)) {
                XCTAssertEqual(($0 as? CutError)?.code, "source_changed")
            }
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func clip(_ id: String, _ file: String, _ from: Int64, _ to: Int64) -> CutSequenceClip {
        .init(id: id, file: file, from: time(from), to: time(to), audioTrack: 0)
    }

    private func time(_ seconds: Int64) -> RationalTime { .init(numerator: seconds) }

    private func wave(_ url: URL, seconds: Int, clockSeconds: Int? = nil) throws {
        let sampleRate = 8_000
        let samples = Data(count: sampleRate * seconds * 2)
        var chunks = Data()
        func write<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append(_ id: String, _ bytes: Data) {
            chunks.append(contentsOf: id.utf8)
            write(UInt32(bytes.count), into: &chunks)
            chunks.append(bytes)
        }
        var format = Data()
        write(UInt16(1), into: &format)
        write(UInt16(1), into: &format)
        write(UInt32(sampleRate), into: &format)
        write(UInt32(sampleRate * 2), into: &format)
        write(UInt16(2), into: &format)
        write(UInt16(16), into: &format)
        append("fmt ", format)
        if let clockSeconds {
            var broadcast = Data(count: 338)
            write(UInt64(clockSeconds * sampleRate), into: &broadcast)
            broadcast.append(Data(count: 602 - broadcast.count))
            append("bext", broadcast)
        }
        append("data", samples)
        var riff = Data("RIFF".utf8)
        write(UInt32(chunks.count + 4), into: &riff)
        riff.append(contentsOf: "WAVE".utf8)
        riff.append(chunks)
        try riff.write(to: url)
    }
}
