import Foundation
@testable import MPCutCore
import XCTest

final class SidecarIndexTests: XCTestCase {
    private func copyFixture(_ name: String, to directory: URL) throws -> URL {
        let original = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        let copy = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: copy)
        return copy
    }

    func testColdConversionSharesItsIndexWithCopyAndRespectsOptOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try copyFixture("SmartTrim-GOP.mp4", to: directory)
        let encoder = ReencodeEngine()
        let fresh = try AnalysisSidecar.$readsEnabled.withValue(false) { try encoder.conversionMedia(source) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalysisSidecar.url(for: source).path))
        let first = try encoder.conversionMedia(source)
        let reused = try XCTUnwrap(CutEngine().cachedIndex(source))
        XCTAssertEqual(first.frames.map(\.time), fresh.frames.map(\.time))
        XCTAssertEqual(reused.frames.map(\.time), first.frames.map(\.time))
        XCTAssertEqual(reused.video.pixelFormat, fresh.video.pixelFormat)
    }

    func testIndexRoundTripsPublicReportAndPrivateEditingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = JSONEncoder()
        json.outputFormatting = .sortedKeys
        let engine = CutEngine()
        let uncached = CutEngine(useSidecar: false)

        for name in ["WebM-Opus-GOP.webm", "VFR-PTS.mp4", "SmartTrim-GOP.mp4", "Pause-Quiet.mov", "ProRes-2997.mov"] {
            let file = try copyFixture(name, to: directory)
            let original = try uncached.inspect(file, keyframes: true)
            let sidecar = AnalysisSidecar(media: original)
            let sections = try AnalysisSidecar.indexSections(for: original)
            XCTAssertNil(try engine.cachedIndex(file))
            try sidecar.save(sections)
            let restored = try XCTUnwrap(engine.cachedIndex(file), name)
            XCTAssertEqual(try json.encode(original), try json.encode(restored), name)
            let repacked = try AnalysisSidecar.indexSections(for: restored)
            XCTAssertEqual(sections["media_index_frames.v1"], repacked["media_index_frames.v1"], name)
            XCTAssertEqual(sections["media_index_audio.v1"], repacked["media_index_audio.v1"], name)
            func header(_ sections: [String: Data]) throws -> NSDictionary {
                let data = try XCTUnwrap(sections["media_index.v1"])
                return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
            }
            XCTAssertEqual(try header(sections), try header(repacked), name)
            XCTAssertTrue(try engine.inspectForPreview(file).frames.isEmpty)
            let noFrames = try engine.inspect(file)
            XCTAssertEqual(try json.encode(noFrames), try json.encode(uncached.inspect(file)))
            let summary = try engine.inspectSummary(file)
            XCTAssertEqual(try json.encode(noFrames), try json.encode(summary))
            XCTAssertEqual(engine.suggestedContainers(for: summary), engine.suggestedContainers(for: noFrames))
            XCTAssertTrue(noFrames.audio.allSatisfy { $0.opusWindow == nil })
            XCTAssertNil(try uncached.cachedIndex(file))
        }
    }

    func testFreshAndSavedIndexesReportMeasuredProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try copyFixture("WebM-Opus-GOP.webm", to: directory)
        let engine = CutEngine()
        for cached in [false, true] {
            var updates: [Double] = []
            let media = try engine.inspect(file, keyframes: true, progress: { updates.append($0) })
            XCTAssertEqual(updates.last, 1)
            XCTAssertTrue(updates.contains { $0 > 0 && $0 < 1 })
            XCTAssertEqual(updates, updates.sorted())
            if !cached {
                try AnalysisSidecar(media: media).save(AnalysisSidecar.indexSections(for: media))
            }
        }
    }

    func testDisablingSidecarsWhileArchivingKeepsTheEditingIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try copyFixture("WebM-Opus-GOP.webm", to: directory)
        var allowSave = true
        let media = try CutEngine().inspectFresh(file, keyframes: true, progress: { progress in
            if progress > 0.98, progress < 1 { allowSave = false }
        }, allowAutomaticSave: { allowSave })
        XCTAssertFalse(allowSave)
        XCTAssertFalse(media.frames.isEmpty)
        XCTAssertEqual(AnalysisSidecar(media: media).status(), "missing")
    }

    func testColdWaveformInspectionSavesTheIndexUsedOnReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try copyFixture("WebM-Opus-GOP.webm", to: directory)
        let engine = CutEngine()
        let cold = try engine.inspectForAudioAnalysis(file)
        XCTAssertTrue(cold.frames.isEmpty)
        XCTAssertNil(cold.audio.first?.opusWindow)
        let indexed = try XCTUnwrap(engine.cachedIndex(file))
        XCTAssertFalse(indexed.frames.isEmpty)
        let warm = try engine.inspectForAudioAnalysis(file)
        XCTAssertEqual(warm.duration, cold.duration)
        XCTAssertEqual(warm.origin, cold.origin)
        XCTAssertTrue(try XCTUnwrap(warm.audio.first).packets.isEmpty)
    }

    func testSceneScanVerifiesProvisionalClockBeforePublishing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try copyFixture("WebM-Opus-GOP.webm", to: directory)
        var bytes = try Data(contentsOf: file)
        let durationTag = try XCTUnwrap(bytes.range(of: Data("00:00:04.000000000".utf8)))
        bytes.replaceSubrange(durationTag, with: Data("00:00:01.000000000".utf8))
        try bytes.write(to: file)
        let preview = try CutEngine().inspectForPreview(file)
        XCTAssertEqual(preview.duration.seconds, 1)
        var progress: [Double] = []
        let scanned = try SceneAnalysis.scan(preview, progress: { progress.append($0) })
        XCTAssertEqual(scanned.duration.seconds, 4)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(try SceneAnalysis.scan(file).duration, scanned.duration)
    }

    func testMalformedOrIncompleteIndexFallsBackToNativeInspection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try copyFixture("WebM-Opus-GOP.webm", to: directory)
        let engine = CutEngine()
        let original = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        let sidecar = AnalysisSidecar(media: original)
        let sections = try AnalysisSidecar.indexSections(for: original)
        try sidecar.save(["media_index.v1": try XCTUnwrap(sections["media_index.v1"])])
        XCTAssertNil(try engine.cachedIndex(file))
        try sidecar.save(sections)
        try sidecar.save(["media_index_frames.v1": Data(repeating: 0xff, count: original.frames.count * 8)])
        XCTAssertNil(try engine.cachedIndex(file))
        XCTAssertEqual(try engine.inspect(file, keyframes: true).frames.count, original.frames.count)
        try sidecar.save(sections)
        let audio = try XCTUnwrap(sections["media_index_audio.v1"])
        try sidecar.save(["media_index_audio.v1": Data(audio.dropLast())])
        var partial: [Double] = []
        XCTAssertNil(try engine.cachedIndex(file, progress: { partial.append($0) }))
        XCTAssertTrue(partial.contains { $0 > 0 })
        var updates: [Double] = []
        let repaired = try engine.inspect(file, keyframes: true, progress: { updates.append($0) })
        XCTAssertEqual(repaired.duration, original.duration)
        XCTAssertEqual(updates, updates.sorted())
        XCTAssertEqual(updates.last, 1)
        XCTAssertNotNil(try engine.cachedIndex(file))
    }

    func testMissingIndexRevisionRequiresFreshInspection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CutEngine()
        for name in ["SmartTrim-GOP.mp4", "Standalone-Chirp.opus", "Covered-Audio.mp3"] {
            let file = try copyFixture(name, to: directory)
            let original = try engine.inspect(file, keyframes: true)
            let store = AnalysisSidecar(media: original)
            let sections = try AnalysisSidecar.indexSections(for: original)
            try store.save(sections)
            XCTAssertNotNil(try engine.cachedIndex(file), name)
            let data = try XCTUnwrap(sections["media_index.v1"])
            var header = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertNotNil(header.removeValue(forKey: "probe_revision"))
            func writeHeader() throws {
                try store.save(["media_index.v1": PropertyListSerialization.data(fromPropertyList: header, format: .binary, options: 0)])
            }
            try writeHeader()
            XCTAssertNil(try engine.cachedIndex(file), name)
            header["copy_issue"] = MediaInfo.auxiliaryTrackIssue
            try writeHeader()
            XCTAssertNil(try engine.cachedIndex(file), name)
            XCTAssertEqual(try engine.inspect(file, keyframes: true).copyIssue, original.copyIssue, name)
        }
    }

    func testAudioAnalysisReadsClockWithoutMaterializingPacketIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try copyFixture("WebM-Opus-GOP.webm", to: directory)
        let engine = CutEngine()
        let indexed = try engine.inspect(file, keyframes: true)
        let fullTrack = try XCTUnwrap(indexed.audio.first)
        XCTAssertFalse(fullTrack.packets.isEmpty)
        let store = AnalysisSidecar(media: indexed)
        try store.save(AnalysisSidecar.indexSections(for: indexed))
        let clock = try engine.inspectForAudioAnalysis(file)
        XCTAssertEqual(clock.origin, indexed.origin)
        XCTAssertEqual(clock.duration, indexed.duration)
        XCTAssertTrue(clock.audio.first?.packets.isEmpty == true)
        XCTAssertFalse(clock.hasFullEditIndex)
        XCTAssertThrowsError(try AnalysisSidecar.indexSections(for: clock))
        let request = ClipRequest(file: file)
        let resolved = try engine.resolve([request], media: [file: clock], container: "webm")
        XCTAssertEqual(resolved.duration, indexed.duration)
        let expected = try AudioAnalysis.envelope(indexed, stream: fullTrack.stream.index, from: 0, to: 0.1, columns: 64)
        let result = try AudioAnalysis.envelope(clock, stream: fullTrack.stream.index, from: 0, to: 0.1, columns: 64)
        XCTAssertEqual(result.low, expected.low)
        XCTAssertEqual(result.high, expected.high)
    }
}
