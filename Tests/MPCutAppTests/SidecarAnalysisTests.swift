import Foundation
@testable import MPCutCore
import XCTest

final class SidecarAnalysisTests: XCTestCase {
    func testDisablingAutomaticSceneSaveDuringDetectionKeepsCompletedReport() throws {
        let original = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                       subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("scan.mov")
        try FileManager.default.copyItem(at: original, to: source)
        let media = try CutEngine(useSidecar: false).inspect(source, keyframes: true)
        let sidecar = try AnalysisSidecar(source: source)
        let session = SceneScanSession()
        // Allow the initial lease, then disable persistence before the first analysis write.
        // Marker delivery can be coalesced until after a short scan has completed.
        let outcome = try SceneAnalysis.run(media, session: session, allowAutomaticSave: {
            !FileManager.default.fileExists(atPath: sidecar.url.path)
        })
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertFalse(try XCTUnwrap(outcome.report).scenes.isEmpty)
        XCTAssertEqual(sidecar.status(), "current")
        XCTAssertNil(outcome.progress.durable)
        XCTAssertNil(sidecar.sceneReport(for: media))
        XCTAssertNil(SceneAnalysis.lookup(media, session: SceneScanSession()))
        XCTAssertEqual(SceneAnalysis.lookup(media, useSidecar: false, session: session)?.state, .upToDate)
    }

    func testLegacyRoundedPeaksAreRecomputedWhileSignedEnvelopeIsReused() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mka",
                                                      subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mka")
        try FileManager.default.copyItem(at: fixture, to: source)

        let media = try CutEngine().inspect(source, keyframes: true)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let store = AnalysisSidecar(media: media)
        _ = try AudioAnalysis.silence(media, stream: stream, minimum: 0.2)
        _ = try AudioAnalysis.envelope(media, stream: stream, from: 0, to: media.duration.seconds, columns: 32)
        let peakKeys = store.keys().filter { $0.hasPrefix("wave.") || $0.hasPrefix("silence.") || $0.hasPrefix("calibration.") }
        XCTAssertEqual(peakKeys.count, 3)
        for key in peakKeys {
            let data = try XCTUnwrap(store.read(key))
            var record = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(record.removeValue(forKey: "sampleAlignedPeaks") as? Bool, true)
            try store.save([key: PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)])
        }
        XCTAssertNil(store.waveform(for: media, stream: stream))
        XCTAssertNil(store.automaticThresholdDB(for: media, stream: stream))
        XCTAssertNil(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.2))
        XCTAssertEqual(store.envelopeOverview(for: media, stream: stream)?.low.count, 32)
        _ = try AudioAnalysis.silence(media, stream: stream, minimum: 0.2)
        XCTAssertNotNil(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.2))
    }

    func testSceneWaveformAndSilenceRoundTrip() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: fixture, to: url)

        let engine = CutEngine()
        let media = try engine.inspect(url, keyframes: true)
        let stream = try XCTUnwrap(media.audio.first?.stream.index)
        let store = AnalysisSidecar(media: media)
        let scenes = try SceneAnalysis.scan(media)
        let wave = try AudioAnalysis.scan(media, stream: stream)
        let silence = try AudioAnalysis.silence(media, stream: stream, minimum: 0.45, waveform: wave)
        XCTAssertEqual(store.status(), "current")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(SceneAnalysis.scan(url)), try encoder.encode(scenes))
        XCTAssertEqual(try encoder.encode(XCTUnwrap(store.sceneReport(for: media))), try encoder.encode(scenes))
        try store.save(AnalysisSidecar.viewNameSections([1: " Presenter "], for: scenes))
        let named = try SceneAnalysis.scan(url)
        XCTAssertEqual(named.views.first?.name, "Presenter")
        XCTAssertEqual(named.views.first?.label, scenes.views.first?.label)
        try store.save(AnalysisSidecar.viewNameSections([:], for: named))
        XCTAssertNil(try SceneAnalysis.scan(url).views.first?.name)
        let restored = try XCTUnwrap(store.waveform(for: media, stream: stream))
        XCTAssertEqual(restored.count, wave.count)
        for bin in 0..<wave.count {
            let from = Double(bin) / Double(AudioWaveform.rate)
            let to = Double(bin + 1) / Double(AudioWaveform.rate)
            XCTAssertEqual(restored.peak(from: from, to: to), wave.peak(from: from, to: to))
        }
        XCTAssertEqual(store.automaticThresholdDB(for: media, stream: stream), silence.automaticThresholdDB)
        XCTAssertEqual(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.45)?.pauses, silence.pauses)
        XCTAssertNil(store.silence(for: media, stream: stream, thresholdDB: silence.thresholdDB, minimum: 0.45))
        XCTAssertNil(store.silence(for: media, stream: stream, thresholdDB: nil, minimum: 0.5))
        let adjusted = try AudioAnalysis.silence(media, stream: stream, thresholdDB: -30, minimum: 0.5)
        XCTAssertEqual(adjusted.pauses, try wave.pauses(thresholdDB: -30, minimum: 0.5))
        XCTAssertThrowsError(try SceneAnalysis.scan(url, cancelled: { true }))
        XCTAssertThrowsError(try AudioAnalysis.scan(media, stream: stream, cancelled: { true }))

        // A cancellation token can fire while the cached span array is being
        // deserialized, before a full validation pass or a decoder fallback.
        let minimum = 0.000001
        let manySpans = (0..<8192).map { index in
            let start = Int64(index) * 2
            return AudioSpan(from: RationalTime(numerator: start, denominator: 100_000),
                             to: RationalTime(numerator: start + 1, denominator: 100_000))
        }
        let many = SilenceAnalysisResult(media: media, stream: stream, requestedThresholdDB: nil,
                                         minimum: minimum, automaticThresholdDB: -40, pauses: manySpans)
        try store.save(AnalysisSidecar.sections(media: media, silence: [many]))
        XCTAssertEqual(try AudioAnalysis.silence(media, stream: stream, minimum: minimum).pauses.count, manySpans.count)
        var polls = 0
        XCTAssertThrowsError(try AudioAnalysis.silence(media, stream: stream, minimum: minimum, cancelled: {
            polls += 1
            return polls >= 12
        })) { error in
            XCTAssertEqual((error as? CutError)?.code, "cancelled")
        }

        // Replacing one section with bytes of the wrong type leaves other
        // persisted results usable and falls back to a real waveform scan.
        try store.save(["wave.v1.\(stream)": Data([0xff])])
        XCTAssertNil(store.waveform(for: media, stream: stream))
        XCTAssertEqual(try AudioAnalysis.scan(media, stream: stream).count, wave.count)
        XCTAssertEqual(try AudioAnalysis.silence(media, stream: stream, minimum: 0.45).pauses, silence.pauses)

        // A provisional preview probe carries no audio packet index, so its
        // waveform cannot be stored against the fully indexed media.
        let preview = try engine.inspectForPreview(url)
        XCTAssertTrue(preview.audio.isEmpty, "The preview probe is expected to defer the audio index")
        let provisional = try AudioAnalysis.scan(preview, stream: stream, useSidecar: false)
        XCTAssertThrowsError(try AnalysisSidecar.sections(media: media, waveforms: [stream: provisional]))
    }
}
