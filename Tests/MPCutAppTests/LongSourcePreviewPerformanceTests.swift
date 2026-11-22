import AppKit
import Darwin
import XCTest
@testable import MPCutApp

final class LongSourcePreviewPerformanceTests: XCTestCase {
    @MainActor
    func testTimelinePreviewAfterImportAndRefresh() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let initialPath = environment["MPCUT_LONG_PREVIEW_SOURCE"],
              let changedPath = environment["MPCUT_LONG_PREVIEW_REPLACEMENT"] else {
            throw XCTSkip("Set MPCUT_LONG_PREVIEW_SOURCE and MPCUT_LONG_PREVIEW_REPLACEMENT to two compatible long A/V files")
        }
        let initial = URL(fileURLWithPath: initialPath)
        let changed = URL(fileURLWithPath: changedPath)
        let fileManager = FileManager.default
        let directory = initial.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }
        let source = directory.appendingPathComponent(initial.lastPathComponent)
        let replacement = directory.appendingPathComponent("replacement").appendingPathExtension(changed.pathExtension)
        try fileManager.copyItem(at: initial, to: source)
        try fileManager.copyItem(at: changed, to: replacement)

        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let model = EditorModel(preferences: preferences)
        defer { model.endSession() }

        let bounds = NSRect(x: 0, y: 0, width: 951, height: 160)
        let surface = TimelineSurface(frame: bounds)
        surface.viewportWidth = bounds.width
        let scroll = NSScrollView(frame: bounds)
        scroll.documentView = surface
        defer { scroll.documentView = nil }
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: bounds))
        var started = ContinuousClock.now
        var hits = [Double: Double]()
        var openingHits = [Double: Double]()
        var indexedHits = [Double: Double]()
        var phase = "import"

        func elapsed() -> Double {
            let time = started.duration(to: .now).components
            return Double(time.seconds) * 1000 + Double(time.attoseconds) / 1e15
        }

        func draw(_ clip: TimelineClip) {
            surface.timeline = SequenceTimeline(
                clips: [clip], playhead: model.playhead, selection: clip.id,
                thumbnailHeight: clip.thumbnailHeight, showsWaveform: true,
                envelopeStore: model.audioStore.detail, waveforms: model.audioStore.waves,
                openingWaveform: model.audioStore.openingWaveform,
                onSelect: { _ in }, onSeek: { _ in }, onTrim: { _, _, _, _ in nil },
                onMove: { _, _ in }, onDrop: { _, _ in },
                thumbnail: { id, time, size in
                    let clip = model.timelineClips.first
                    let isIndexed = clip?.isIndexed == true && clip?.hasProvisionalFilmstrip == false
                    let image = await model.thumbnail(for: id, at: time, size: size)
                    if image != nil, !Task.isCancelled {
                        let completed = elapsed()
                        if hits[time] == nil { hits[time] = completed }
                        if isIndexed { indexedHits[time] = completed }
                        else { openingHits[time] = completed }
                    }
                    return image
                }
            )
            surface.cacheDisplay(in: bounds, to: bitmap)
        }

        func sample(oldRevision: Int?) async throws -> [String: Any] {
            var metrics = [String: Any]()
            var drawn: TimelineClip?
            var maxSparseBuckets = 0
            while elapsed() < 90_000 {
                try Task.checkCancellation()
                if let alert = model.alert {
                    XCTFail("Unexpected editor notice: \(alert)")
                    break
                }
                if let clip = model.timelineClips.first, clip.mediaRevision != oldRevision {
                    metrics["clipAvailableMs"] = metrics["clipAvailableMs"] ?? elapsed()
                    if drawn?.isIndexed != clip.isIndexed || drawn?.mediaRevision != clip.mediaRevision ||
                       drawn?.hasProvisionalFilmstrip != clip.hasProvisionalFilmstrip {
                        draw(clip)
                        drawn = clip
                    }
                    if !hits.isEmpty { metrics["firstTileMs"] = hits.values.min() }
                    if indexedHits.count >= 10, metrics["tenIndexedTileRequestsMs"] == nil {
                        metrics["tenIndexedTileRequestsMs"] = indexedHits.values.sorted()[9]
                    }
                    if clip.isIndexed, !clip.hasProvisionalFilmstrip, !model.isImporting, model.mediaRefreshProgress == nil {
                        metrics["indexReadyMs"] = metrics["indexReadyMs"] ?? elapsed()
                    }
                    if oldRevision == nil, let rough = model.audioStore.openingWaveform, rough.source == clip.sourceID {
                        let measured = rough.waveform.peaks.compactMap { $0 }.count
                        if measured > 0 { metrics["firstSparseAudioMs"] = metrics["firstSparseAudioMs"] ?? elapsed() }
                        maxSparseBuckets = max(maxSparseBuckets, measured)
                    }
                    if oldRevision == nil, let wave = model.audioStore.waves[clip.sourceID], wave.count > 0 {
                        metrics["firstOverviewAudioMs"] = metrics["firstOverviewAudioMs"] ?? elapsed()
                    }
                    if oldRevision != nil, !clip.hasProvisionalFilmstrip, let sparse = model.audioStore.detail.sparseWaveform(
                        for: clip.sourceID, surface: .timeline(clip.id)
                    ) {
                        let measured = sparse.peaks.compactMap { $0 }.count
                        if measured > 0 { metrics["firstSparseAudioMs"] = metrics["firstSparseAudioMs"] ?? elapsed() }
                        maxSparseBuckets = max(maxSparseBuckets, measured)
                    }
                    if oldRevision != nil, !clip.hasProvisionalFilmstrip, model.audioStore.detail.envelope(
                        for: clip.sourceID, surface: .timeline(clip.id),
                        from: clip.sourceStart, to: clip.sourceEnd, pixels: Int((bounds.width - 32) * 2)
                    ) != nil {
                        metrics["firstRefreshedAudioMs"] = metrics["firstRefreshedAudioMs"] ?? elapsed()
                    }
                    let audioMetric = oldRevision == nil ? "firstSparseAudioMs" : "firstRefreshedAudioMs"
                    if metrics["indexReadyMs"] != nil, metrics["tenIndexedTileRequestsMs"] != nil,
                       metrics[audioMetric] != nil {
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            metrics["openingDistinctTileRequests"] = openingHits.count
            if openingHits.count >= 10 { metrics["tenOpeningTileRequestsMs"] = openingHits.values.sorted()[9] }
            metrics["maxSparseBuckets"] = maxSparseBuckets
            metrics["phase"] = phase
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            print("MPCUT_LONG_PREVIEW_BENCHMARK \(String(decoding: data, as: UTF8.self))")
            _ = try XCTUnwrap(metrics["indexReadyMs"])
            _ = try XCTUnwrap(metrics["tenIndexedTileRequestsMs"])
            return metrics
        }

        started = .now
        model.importFiles([source])
        let imported = try await sample(oldRevision: nil)
        _ = try XCTUnwrap(imported["firstSparseAudioMs"])
        let original = try XCTUnwrap(model.timelineClips.first)
        let settle = ContinuousClock.now + .seconds(30)
        while model.isBusy, ContinuousClock.now < settle { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(model.canRefreshProjectMedia)
        guard rename(replacement.path, source.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        phase = "refresh"
        hits.removeAll()
        openingHits.removeAll()
        indexedHits.removeAll()
        started = .now
        model.refreshProjectMedia()
        let refreshed = try await sample(oldRevision: original.mediaRevision)
        _ = try XCTUnwrap(refreshed["firstRefreshedAudioMs"])
        _ = try XCTUnwrap(refreshed["firstSparseAudioMs"])
        XCTAssertEqual(model.timelineClips.first?.id, original.id)
    }
}
