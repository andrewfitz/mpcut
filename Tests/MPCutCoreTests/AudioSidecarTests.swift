import AVFoundation
import XCTest
@testable import MPCutCore

final class AudioSidecarTests: XCTestCase {
    func testOpusPrerollWithoutAudibleSamplesHasNoTrimWindow() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Standalone-Chirp.opus")
        let media = try CutEngine(useSidecar: false).inspect(fixture, keyframes: true)
        let audio = try XCTUnwrap(media.audio.first)
        let first = try XCTUnwrap(audio.packets.first)
        XCTAssertGreaterThan(first.skipSamples, 1)
        let packet = AudioPacket(time: first.time, dts: first.time, duration: first.duration,
                                 skipSamples: first.skipSamples, discardSamples: 0, decodedSamples: 1)
        let truncated = AudioIndex(stream: audio.stream, packets: [packet], start: audio.start, end: audio.end,
                                   hasPriming: true, pcmContinuity: false, presentationEdits: [])
        XCTAssertNil(try opusTrimWindow(truncated, origin: media.origin))
    }

    func testConversionProgressCanCancelBeforePublishing() throws {
        try XCTSkipUnless((try? ReencodeEngine.findHelper(override: nil)) != nil, "Requires an FFmpeg helper")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Gapless-Crop.mp3")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("cancelled.wav")
        let engine = AudioExportEngine(useSidecar: false)
        let plan = try engine.resolve([ClipRequest(file: fixture)], output: output, audio: .pcm)
        for limit in [0.0, 1.0] {
            XCTAssertThrowsError(try engine.write(plan, to: output) { $0 < limit }) {
                XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testWaveformScanHonorsSwiftTaskCancellationByDefault() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Standalone-Chirp.opus")
        let media = try Probe.read(fixture)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let code = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try AudioAnalysis.scan(media, stream: stream, useSidecar: false)
                return nil as String?
            } catch {
                return (error as? CutError)?.code
            }
        }.value
        XCTAssertEqual(code, "cancelled")
    }

    func testStandaloneRecordingRestoresIndexAndBothWaveformResolutions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<16_000 { samples[i] = i < 4_000 ? Float(sin(Double(i) * 0.1)) * 0.5 : 0 }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let engine = CutEngine()
        let media = try engine.inspect(source, keyframes: true)
        XCTAssertFalse(media.hasVideo)
        XCTAssertTrue(media.frames.isEmpty)
        XCTAssertEqual(media.duration, RationalTime(numerator: 1))
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let store = AnalysisSidecar(media: media)
        let coarse = try AudioAnalysis.scan(media, stream: stream)
        let envelope = try AudioAnalysis.envelope(media, stream: stream, from: 0, to: media.duration.seconds, columns: 1024)
        let silence = try AudioAnalysis.silence(media, stream: stream, minimum: 0.2, waveform: coarse)
        XCTAssertEqual(silence.pauses.count, 1)
        var sections = try AnalysisSidecar.indexSections(for: media)
        let analyses = try AnalysisSidecar.sections(media: media, waveforms: [stream: coarse],
                                                    envelopeOverviews: [stream: envelope], silence: [silence])
        sections.merge(analyses) { _, new in new }
        try store.save(sections)
        let cached = try XCTUnwrap(engine.cachedIndex(source))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(cached), try encoder.encode(media))
        XCTAssertEqual(try XCTUnwrap(store.waveform(for: cached, stream: stream)).count, coarse.count)
        let restored = try XCTUnwrap(store.envelopeOverview(for: cached, stream: stream))
        XCTAssertEqual(restored.low, envelope.low)
        XCTAssertEqual(restored.high, envelope.high)
        XCTAssertNoThrow(try AnalysisSidecar.sections(media: cached, envelopeOverviews: [stream: restored]))
        let subrange = try AudioAnalysis.envelope(media, stream: stream, from: 0.1, to: 0.3, columns: 1024)
        XCTAssertThrowsError(try AnalysisSidecar.sections(media: cached, envelopeOverviews: [stream: subrange]))
        XCTAssertEqual(try AudioAnalysis.silence(cached, stream: stream, minimum: 0.2).pauses, silence.pauses)
        for threshold in [nil, -50.0] as [Double?] {
            let prior = try AudioAnalysis.silence(media, stream: stream, thresholdDB: threshold,
                                                   minimum: 0.2, waveform: coarse, useSidecar: false)
            try store.save(AnalysisSidecar.sections(media: media, silence: [prior]))
            let calibration = -120.0
            let cold = try AudioAnalysis.silence(media, stream: stream, thresholdDB: threshold, minimum: 0.2,
                                                  waveform: coarse, automaticThresholdDB: calibration, useSidecar: false)
            let hot = try AudioAnalysis.silence(cached, stream: stream, thresholdDB: threshold, minimum: 0.2,
                                                 waveform: coarse, automaticThresholdDB: calibration)
            XCTAssertNotEqual(prior.automaticThresholdDB, calibration)
            XCTAssertEqual(hot.automaticThresholdDB, cold.automaticThresholdDB)
            XCTAssertEqual(hot.pauses, cold.pauses)
            XCTAssertTrue(try AnalysisSidecar.sections(media: cached, silence: [hot]).isEmpty)
            XCTAssertEqual(store.automaticThresholdDB(for: cached, stream: stream), prior.automaticThresholdDB)
            let restored = try AudioAnalysis.silence(cached, stream: stream, thresholdDB: threshold, minimum: 0.2)
            XCTAssertEqual(restored.automaticThresholdDB, prior.automaticThresholdDB)
            XCTAssertEqual(restored.pauses, prior.pauses)
            let newMinimum = try AudioAnalysis.silence(cached, stream: stream, minimum: 0.3)
            XCTAssertEqual(newMinimum.automaticThresholdDB, prior.automaticThresholdDB)
        }
        let calibrationKey = "silence_automatic_threshold_db.v1.\(stream)"
        let bytes = try XCTUnwrap(store.read(calibrationKey))
        var legacy = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        legacy.removeValue(forKey: "clock")
        legacy["value"] = -120.0
        try store.save([calibrationKey: PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)])
        XCTAssertNil(store.automaticThresholdDB(for: cached, stream: stream))
        XCTAssertEqual(try AudioAnalysis.silence(cached, stream: stream, minimum: 0.4).automaticThresholdDB,
                       silence.automaticThresholdDB)
        XCTAssertThrowsError(try SceneAnalysis.scan(source)) { XCTAssertEqual(($0 as? CutError)?.code, "no_video") }
        let output = directory.appendingPathComponent("frames")
        XCTAssertThrowsError(try JPEGExport.write(cached, to: output, selection: .times([.zero]))) {
            XCTAssertEqual(($0 as? CutError)?.code, "no_video")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
