import Foundation
import MediaProbe
import XCTest
@testable import MPCutCore

final class TranscriptExtractionTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-extraction-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Interleaved 16-bit PCM.
    private func wave(_ channels: [[Int16]], rate: UInt32 = 16_000, to file: URL) throws {
        let frames = channels[0].count
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let align = UInt16(channels.count * 2)
        append(UInt32(frames * Int(align) + 36))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels.count))
        append(rate)
        append(rate * UInt32(align))
        append(align)
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(frames * Int(align)))
        for frame in 0..<frames {
            for channel in channels { append(channel[frame]) }
        }
        try data.write(to: file)
    }

    func testActivityRejectsDurationBeyondStagedFile() throws {
        let file = try directory().appendingPathComponent("short.wav")
        try wave([[0]], to: file)
        XCTAssertThrowsError(try measureTranscriptActivity(audio: file, duration: .max,
                                                           evidence: "short", cancelled: { false })) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_activity_failed")
        }
    }

    func testActivityEncodingCanStopBetweenBatches() {
        var polls = 0
        XCTAssertThrowsError(try transcriptActivityDocument(levels: Array(repeating: 0, count: 2_048),
                                                           duration: 2_048 * 320, evidence: "levels") {
            polls += 1
            return polls > 1
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    private func readPCM(_ file: URL) throws -> [Int16] {
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes.dropFirst(36).prefix(4), as: UTF8.self), "data")
        return bytes.withUnsafeBytes { buffer in
            stride(from: 44, to: bytes.count, by: 2).map {
                Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: Int16.self))
            }
        }
    }

    private func tone(_ frequency: Double, amplitude: Double, frames: Int, rate: Double = 16_000) -> [Int16] {
        (0..<frames).map { Int16((amplitude * sin(2 * .pi * frequency * Double($0) / rate)).rounded()) }
    }

    private func finish(_ pcm: OpaquePointer) {
        XCTAssertEqual(mp_transcript_pcm_finish(pcm, { _ in 0 }, nil), 0)
        mp_transcript_pcm_close(pcm)
    }

    /// A millisecond container clock can start a 44.1 kHz stream half-way between two samples.
    /// The reader then supplies each frame's time as the run's start plus the samples since.
    func testFramesOfOneRunStayContinuousWhenTheRunStartsBetweenTwoSamples() throws {
        let wav = try directory().appendingPathComponent("run.wav")
        let frames = 400, size = 1_024
        let total = frames * size + 2
        let pcm = try XCTUnwrap(mp_transcript_pcm_open(wav.path, Int64(total), 16_000, -1))
        let runStart = 1.5 / 16_000
        var position = 0
        for _ in 0..<frames {
            // Every value is a distinct multiple of 64 in the 16-bit output, so a moved sample shows.
            let block = (0..<size).map { Float((position + $0) % 251 + 1) / 512 }
            let start = runStart + Double(position) / 16_000
            XCTAssertEqual(mp_transcript_pcm_float(pcm, block, Int32(size), 1, 16_000, start), 0)
            position += size
        }
        finish(pcm)
        let samples = try readPCM(wav)
        XCTAssertEqual(samples.count, total)
        XCTAssertEqual(Array(samples.prefix(2)), [0, 0])
        let moved = samples.indices.dropFirst(2).filter { samples[$0] != Int16(($0 - 2) % 251 + 1) * 64 }
        XCTAssertTrue(moved.isEmpty, "\(moved.count) samples differ from the source, the first at \(moved.first ?? -1)")
    }

    /// Matroska stamps packets in milliseconds. A 44.1 kHz stream that starts at 5 ms
    /// starts at sample 220.5, and every later frame of its run inherits that half sample.
    func testMillisecondClockStreamStartingBetweenSamplesHasNoInsertedSilence() throws {
        let folder = try directory()
        let movie = folder.appendingPathComponent("tie.mkv")
        let paths = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("The Matroska fixture requires ffmpeg.")
        }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=black:s=64x64:r=25:d=20",
                             "-itsoffset", "0.005", "-f", "lavfi", "-i", "aevalsrc=0.5:s=44100:d=20",
                             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "mpeg4", "-c:a", "flac", movie.path]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        let engine = CutEngine(useSidecar: false)
        let wav = folder.appendingPathComponent("tie.wav")
        try engine.extractTranscriptAudio(engine.inspectMulticamSource(movie), stream: 1, to: wav)
        let samples = try readPCM(wav)
        XCTAssertGreaterThan(samples.count, 319_000)
        // A constant level stays constant. An inserted zero rings through the resampling filter.
        let steady = samples[400..<(samples.count - 400)]
        XCTAssertEqual(steady.min(), 16_384)
        XCTAssertEqual(steady.max(), 16_384)
    }

    func testOneSampleGapAndOverlapOnAnExactClockStillMoveTheAudio() throws {
        let wav = try directory().appendingPathComponent("gap.wav")
        let pcm = try XCTUnwrap(mp_transcript_pcm_open(wav.path, 4_000, 16_000, -1))
        let block = (0..<1_000).map { Float($0 % 251 + 1) / 512 }
        // The second block starts one sample late and the third one sample early.
        for start in [0, 1_001, 2_000] {
            XCTAssertEqual(mp_transcript_pcm_float(pcm, block, 1_000, 1, 16_000, Double(start) / 16_000), 0)
        }
        finish(pcm)
        let samples = try readPCM(wav)
        func source(_ index: Int) -> Int16 { Int16(index % 251 + 1) * 64 }
        XCTAssertEqual(samples[999], source(999))
        XCTAssertEqual(samples[1_000], 0)
        XCTAssertEqual(samples[1_001], source(0))
        XCTAssertEqual(samples[2_000], source(999))
        XCTAssertEqual(samples[2_001], source(1))
        XCTAssertEqual(samples[2_999], source(999))
        XCTAssertEqual(samples[3_000], 0)
    }

    /// An HE-AAC stream with implicit SBR declares half the rate its decoder produces.
    func testRateOrLayoutChangePartWayKeepsExtracting() throws {
        let folder = try directory()
        let level = [Float](repeating: 0.5, count: 32_000)
        for (name, first, second) in [("up.wav", 16_000, 32_000), ("down.wav", 32_000, 16_000)] {
            let wav = folder.appendingPathComponent(name)
            let pcm = try XCTUnwrap(mp_transcript_pcm_open(wav.path, 40_000, Int32(first), -1))
            XCTAssertEqual(mp_transcript_pcm_float(pcm, level, Int32(first), 1, Int32(first), 0), 0, name)
            // A click half a second after the change shows where the second rate's audio lands.
            var marked = level
            marked[second / 2] = 1
            XCTAssertEqual(mp_transcript_pcm_float(pcm, marked, Int32(second), 1, Int32(second), 1), 0, name)
            finish(pcm)
            let samples = try readPCM(wav)
            XCTAssertEqual(samples.count, 40_000, name)
            let click = try XCTUnwrap(samples.indices.max { samples[$0] < samples[$1] })
            XCTAssertGreaterThan(samples[click], 20_000, name)
            XCTAssertLessThanOrEqual(abs(click - 24_000), 1, name)
            // The resampling filter rings for a few samples where it starts and stops, and around the click.
            for range in [200..<15_900, 16_100..<23_900, 24_100..<31_800] {
                let worst = range.map { abs(Int(samples[$0]) - 16_384) }.max() ?? 0
                XCTAssertLessThanOrEqual(worst, 4, "\(name) \(range)")
            }
            XCTAssertTrue((15_900..<16_100).allSatisfy { samples[$0] > 8_000 }, "\(name) has a hole at the change")
            XCTAssertTrue(samples[32_200...].allSatisfy { $0 == 0 }, name)
        }

        let wav = folder.appendingPathComponent("layout.wav")
        let pcm = try XCTUnwrap(mp_transcript_pcm_open(wav.path, 32_000, 16_000, -1))
        XCTAssertEqual(mp_transcript_pcm_float(pcm, level, 16_000, 1, 16_000, 0), 0)
        XCTAssertEqual(mp_transcript_pcm_float(pcm, level, 16_000, 2, 16_000, 1), 0)
        finish(pcm)
        XCTAssertTrue(try readPCM(wav).allSatisfy { $0 == 16_384 })
    }

    /// A balanced signal wired across a stereo pair arrives with one channel inverted.
    func testOppositePolarityStereoIsExtractedFromItsStrongestChannel() throws {
        let folder = try directory()
        let engine = CutEngine(useSidecar: false)
        let left = tone(440, amplitude: 8_000, frames: 32_000)
        func extracted(_ name: String, right: [Int16]) throws -> [Int16] {
            let source = folder.appendingPathComponent(name)
            try wave([left, right], to: source)
            let wav = folder.appendingPathComponent("staged-" + name)
            try engine.extractTranscriptAudio(engine.inspectMulticamSource(source), stream: 0, to: wav)
            return try readPCM(wav)
        }
        XCTAssertEqual(try extracted("inverted.wav", right: left.map { -$0 }), left)
        // The channels of a real pair rarely match exactly. The louder one is kept.
        XCTAssertEqual(try extracted("unequal.wav", right: left.map { Int16((-0.9 * Double($0)).rounded()) }), left)

        // An ordinary pair is still averaged.
        let other = tone(660, amplitude: 6_000, frames: 32_000)
        let mixed = try extracted("ordinary.wav", right: other)
        let worst = mixed.indices.map { abs(Int(mixed[$0]) * 2 - Int(left[$0]) - Int(other[$0])) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 2)
        // Wide stereo loses level in the mix without cancelling. It is averaged as well.
        let wide = try extracted("wide.wav", right: zip(left, other).map { Int16(-Int($0) / 2 + Int($1)) })
        XCTAssertNotEqual(wide, left)
        XCTAssertGreaterThan(wide.map { abs(Int($0)) }.max() ?? 0, 2_000)
    }

    func testPreparedJobNamesTheTrackWhoseChannelsCancel() throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("balanced.wav")
        let left = tone(440, amplitude: 8_000, frames: 32_000)
        try wave([left, left.map { -$0 }], to: source)
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try AnalysisSidecar.$readsEnabled.withValue(false) { try store.prepare(media: source, documentID: "one") }
        let track = try XCTUnwrap(job.sessions.first?.tracks.first)
        XCTAssertEqual(track.state, .staged)
        XCTAssertEqual(try readPCM(XCTUnwrap(track.audio)), left)
        XCTAssertTrue(track.message?.contains("cancel each other") == true, track.message ?? "no message")
        XCTAssertTrue(job.warnings.contains { $0.contains("balanced.wav") && $0.contains("cancel each other") })
        // The levels describe the audio that is recognized.
        let levels = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(track.activity))) as? [String: Any]
        let frames = try XCTUnwrap(levels?["activity"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 100)
        XCTAssertTrue(frames.allSatisfy { ($0["level"] as? Double ?? 0) > 0.1 })

        // Recognition of the channel staged alone is kept under that channel. A result cached
        // for the silent mix of both channels, as an earlier version staged it, is not served.
        XCTAssertEqual(track.downmixChannel, 0)
        let capabilities = Data(#"{"version":"fixture","session_schema_version":1,"engines":[{"name":"qwen3","aliases":[],"included":true,"default_model":"fixture-model","diarization":false,"minimum_macos":"14.0","model_source":"hugging-face"}]}"#.utf8)
        let settings = try TranscriptProviderSettings(capabilities: .read(capabilities), options: .init())
        let revisions = Dictionary(uniqueKeysWithValues: settings.modelIDs(for: track).map { ($0, "revision") })
        var mixed = track
        mixed.downmixChannel = nil
        var chosen = mixed
        chosen.channel = 0
        let key = try XCTUnwrap(settings.key(for: track, revisions: revisions))
        XCTAssertNotEqual(key, settings.key(for: mixed, revisions: revisions))
        XCTAssertEqual(key, settings.key(for: chosen, revisions: revisions))
        // Preparing the same document again keeps the staged audio and what it holds.
        let again = try AnalysisSidecar.$readsEnabled.withValue(false) { try store.prepare(media: source, documentID: "one") }
        XCTAssertEqual(again.sessions.first?.tracks.first?.downmixChannel, 0)
        // A recording whose channels do not cancel records no fallback.
        let plain = folder.appendingPathComponent("plain.wav")
        try wave([left, left], to: plain)
        let ordinary = try AnalysisSidecar.$readsEnabled.withValue(false) { try store.prepare(media: plain, documentID: "two") }
        XCTAssertNil(ordinary.sessions.first?.tracks.first?.downmixChannel)
    }

    func testStagedLevelsAreThoseOfTheStagedPCM() throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("speechlike.wav")
        // 3.3 s at 44.1 kHz resamples to a length that ends with a short window.
        let frames = 145_530
        var state: UInt32 = 12_345
        func noise(_ scale: Double) -> [Int16] {
            (0..<frames).map { index in
                state = state &* 1_664_525 &+ 1_013_904_223
                let envelope = 0.5 + 0.5 * sin(Double(index) / 4_000)
                return Int16(scale * envelope * (Double(state >> 16) / 32_768 - 1))
            }
        }
        try wave([noise(9_000), noise(5_000)], rate: 44_100, to: source)
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try AnalysisSidecar.$readsEnabled.withValue(false) { try store.prepare(media: source, documentID: "one") }
        let track = try XCTUnwrap(job.sessions.first?.tracks.first)
        let staged = try XCTUnwrap(track.audio)
        let duration = Int64(try readPCM(staged).count)
        XCTAssertEqual(duration, 52_800)
        let measured = try measureTranscriptActivity(audio: staged, duration: duration, evidence: track.evidence,
                                                     cancelled: { false })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(track.activity)), measured)
        XCTAssertTrue(TranscriptRecognitionCache.Artifacts.matchesActivity(measured, evidence: track.evidence, duration: duration))
    }

    /// An earlier extraction of the stream can have left other levels in the media's sidecar.
    func testLevelsOfFreshlyStagedPCMReplaceASavedCopy() throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("speech.wav")
        try wave([tone(300, amplitude: 9_000, frames: 32_000)], to: source)
        let silence = folder.appendingPathComponent("silence.wav")
        try wave([[Int16](repeating: 0, count: 32_000)], to: silence)
        let planned = try XCTUnwrap(TranscriptJobPlan.inventory(media: source).first?.tracks.first)
        XCTAssertTrue(planned.hasReusableEvidence)
        let stale = try measureTranscriptActivity(audio: silence, duration: 32_000, evidence: planned.evidence,
                                                  cancelled: { false })
        let media = try CutEngine().inspectMulticamSource(source)
        let sidecar = AnalysisSidecar(media: media)
        let key = TranscriptActivityKey(stream: 0)
        try sidecar.saveTranscriptActivity(stale, key: key, media: media)
        XCTAssertEqual(sidecar.readTranscriptActivity(key), stale)

        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try store.prepare(media: source, documentID: "one")
        let track = try XCTUnwrap(job.sessions.first?.tracks.first)
        XCTAssertEqual(track.evidence, planned.evidence)
        let measured = try measureTranscriptActivity(audio: XCTUnwrap(track.audio), duration: 32_000,
                                                     evidence: track.evidence, cancelled: { false })
        XCTAssertNotEqual(measured, stale)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(track.activity)), measured)
        XCTAssertEqual(sidecar.readTranscriptActivity(key), measured)
        XCTAssertFalse(job.warnings.contains { $0.contains("audio activity") }, "\(job.warnings)")
    }

    func testDiscardedJobLeavesNoLockFile() throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("source.wav")
        try wave([tone(300, amplitude: 9_000, frames: 16_000)], to: source)
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try AnalysisSidecar.$readsEnabled.withValue(false) { try store.prepare(media: source, documentID: "one") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(job.id.uuidString + ".lock").path))
        try store.discard(documentID: "one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
        // The job's ID can be used again once its lock file is gone.
        let again = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try store.prepare(media: source, documentID: "one", operationID: job.id)
        }
        XCTAssertEqual(again.state, .prepared)
    }

    func testRecordingsOfOneJobAreStagedTogetherAndReportedInOrder() throws {
        let folder = try directory()
        let names = (0..<6).map { "camera-\($0)" }
        for (index, name) in names.enumerated() {
            try wave([tone(200 + 50 * Double(index), amplitude: 6_000, frames: 48_000)],
                     to: folder.appendingPathComponent(name + ".wav"))
        }
        let project = CutProject.multicam(MulticamProject(
            referenceAngle: names[0], range: .init(from: .zero, to: .init(numerator: 3)),
            angles: names.map { .init(id: $0, file: folder.appendingPathComponent($0 + ".wav").path) },
            audio: .follow, switches: []))
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        var reports: [[TranscriptJobTrackState]] = []
        let job = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try store.prepare(project: project, documentID: "edit") { record in
                if let session = record.sessions.first { reports.append(session.tracks.map(\.state)) }
            }
        }
        XCTAssertEqual(job.state, .prepared)
        let tracks = try XCTUnwrap(job.sessions.first?.tracks)
        XCTAssertEqual(tracks.map(\.state), Array(repeating: .staged, count: 6))
        // Whichever extraction finishes first, tracks are committed in order.
        for states in reports {
            let staged = states.prefix { $0 == .staged }.count
            XCTAssertTrue(states.dropFirst(staged).allSatisfy { $0 == .pending }, "\(states)")
        }
        XCTAssertTrue(reports.contains { $0.filter { $0 == .staged }.count == 3 })
        for (index, track) in tracks.sorted(by: { $0.sourceID < $1.sourceID }).enumerated() {
            XCTAssertEqual(try readPCM(XCTUnwrap(track.audio)), tone(200 + 50 * Double(index), amplitude: 6_000, frames: 48_000))
        }

        // A stop while recordings are being staged leaves no partial audio behind.
        let stopped = TranscriptJobStore(directory: folder.appendingPathComponent("stopped-jobs"))
        let id = UUID()
        let flag = StopFlag()
        XCTAssertThrowsError(try AnalysisSidecar.$readsEnabled.withValue(false) {
            try stopped.prepare(project: project, documentID: "edit", operationID: id,
                                cancelled: { flag.isSet }) { record in
                if record.sessions.first?.tracks.contains(where: { $0.state == .staged }) == true { flag.set() }
            }
        })
        let interrupted = try stopped.status(id)
        XCTAssertEqual(interrupted.state, .interrupted)
        let session = try XCTUnwrap(interrupted.sessions.first)
        let left = try FileManager.default.contentsOfDirectory(atPath: session.manifest.deletingLastPathComponent().path)
        XCTAssertFalse(left.contains { $0.hasPrefix(".") && $0.hasSuffix(".wav") }, "\(left)")
        XCTAssertEqual(try AnalysisSidecar.$readsEnabled.withValue(false) { try stopped.retry(id).state }, .prepared)
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
