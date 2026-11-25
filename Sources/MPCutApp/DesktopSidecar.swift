import Foundation
import MPCutCore

struct SavedEditorAnalysis: Sendable {
    let report: SceneReport?
    let markers: [TimelineScene]

    init?(media: MediaInfo, cancelled: () -> Bool) {
        let sidecar = AnalysisSidecar(media: media)
        guard var report = sidecar.sceneReport(for: media, cancelled: cancelled) else { return nil }
        for view in report.views { report.setViewName(nil, for: view.view) }
        self.report = report
        markers = report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) }
    }
}

struct DesktopAnalysisSnapshot: Sendable {
    let sourceID: UUID
    let media: MediaInfo
    let scenes: SceneReport?
    let waveforms: [Int: AudioWaveform]
    let envelopeOverviews: [Int: AudioEnvelope]
    let silence: [SilenceAnalysisResult]
    let filmstrip: [FilmstripTile]

    @discardableResult
    func save(cancelled: () -> Bool) throws -> URL {
        var sections = try AnalysisSidecar.indexSections(for: media, cancelled: cancelled)
        let analysis = try AnalysisSidecar.sections(media: media, scenes: scenes, waveforms: waveforms,
                                                    envelopeOverviews: envelopeOverviews, silence: silence, cancelled: cancelled)
        sections.merge(analysis) { _, new in new }
        let preserveAlpha = media.videoStream.map { $0.hasAlpha || $0.hasAdditionalVideoLayers } ?? false
        for tile in filmstrip {
            if cancelled() { throw CutError(code: "cancelled", message: "Saving filmstrip thumbnails was cancelled.") }
            if let data = autoreleasepool(invoking: { tile.key.encoded(tile.image, preserveAlpha: preserveAlpha) }) {
                sections[tile.key.section] = data
            }
        }
        let retention = filmstrip.isEmpty ? [:] : [FilmstripTileKey.sectionPrefix: FilmstripTileBuffer.countLimit]
        let sidecar = AnalysisSidecar(media: media)
        try sidecar.saveAnalysisSections(sections, updating: [:], retainingLatest: retention, cancelled: cancelled)
        // The shared cache limit runs after the app saves a cutcache.
        NotificationCenter.default.post(name: .analysisCutcacheDidSave, object: sidecar.url)
        return sidecar.url
    }
}
