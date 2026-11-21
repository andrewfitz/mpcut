import Foundation
import MPCutCore

struct SavedEditorAnalysis: Sendable {
    let report: SceneReport?
    let markers: [TimelineScene]
    let names: [Int: String]
    let thresholdsByTrack: [Int: Double]

    init?(media: MediaInfo, cancelled: () -> Bool) {
        let sidecar = AnalysisSidecar(media: media)
        report = sidecar.sceneReport(for: media, cancelled: cancelled)
        if cancelled() { return nil }
        if let report {
            markers = report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) }
            names = Dictionary(uniqueKeysWithValues: report.views.compactMap { view in
                view.name.map { (view.view, $0) }
            })
        } else {
            markers = []
            names = [:]
        }
        let thresholds = sidecar.read("thresholdOverrides.v1", cancelled: cancelled).flatMap {
            try? JSONDecoder().decode([Int: Double].self, from: $0)
        } ?? [:]
        let audio = media.streams.filter { $0.kind == "audio" }
        thresholdsByTrack = Dictionary(uniqueKeysWithValues: audio.enumerated().compactMap { offset, stream in
            guard let value = thresholds[stream.index], (-120...0).contains(value) else { return nil }
            return (offset, value)
        })
        if report == nil && thresholdsByTrack.isEmpty { return nil }
    }
}

struct EditorMetadataEdits: Sendable {
    // A present key with a nil value records an explicit reset to the default.
    var names: [Int: String?] = [:]
    var thresholds: [Int: Double?] = [:]

    /// Apply explicit edits to the latest map while the sidecar writer holds its lock.
    /// The in-memory seed is only used for new or unreadable sections.
    static func merged<Value: Codable>(_ data: Data?, seed: [Int: Value] = [:],
                                       edits: [Int: Value?]) -> [Int: Value] {
        var values = data.flatMap { try? JSONDecoder().decode([Int: Value].self, from: $0) } ?? seed
        for (key, value) in edits { values[key] = value }
        return values
    }

    mutating func discardSaved(_ edits: Self) {
        for (key, value) in edits.names where names[key] == .some(value) { names.removeValue(forKey: key) }
        for (key, value) in edits.thresholds where thresholds[key] == .some(value) { thresholds.removeValue(forKey: key) }
    }

    mutating func update(_ edits: Self, saved: Bool) {
        for (key, value) in edits.names { names[key] = saved ? nil : .some(value) }
        for (key, value) in edits.thresholds { thresholds[key] = saved ? nil : .some(value) }
    }
}

struct DesktopAnalysisSnapshot: Sendable {
    let sourceID: UUID
    let media: MediaInfo
    let scenes: SceneReport?
    let viewNames: [Int: String]
    let thresholdOverrides: [Int: Double]
    var edits: EditorMetadataEdits
    let waveforms: [Int: AudioWaveform]
    let envelopeOverviews: [Int: AudioEnvelope]
    let silence: [SilenceAnalysisResult]
    let filmstrip: [FilmstripTile]

    func save(cancelled: () -> Bool) throws {
        var sections = try AnalysisSidecar.indexSections(for: media, cancelled: cancelled)
        let analysis = try AnalysisSidecar.sections(media: media, scenes: scenes, waveforms: waveforms,
                                                    envelopeOverviews: envelopeOverviews, silence: silence, cancelled: cancelled)
        sections.merge(analysis) { _, new in new }
        var updates: [String: (Data?) throws -> Data] = [:]
        if let scenes, !viewNames.isEmpty || !edits.names.isEmpty {
            updates[AnalysisSidecar.viewNameSectionKey] = { old in
                let names = EditorMetadataEdits.merged(old, seed: viewNames, edits: edits.names)
                let valid = names.filter { $0.key > 0 && $0.key <= scenes.viewCount }
                return try AnalysisSidecar.viewNameData(valid, for: scenes)
            }
        }
        if !thresholdOverrides.isEmpty || !edits.thresholds.isEmpty {
            updates["thresholdOverrides.v1"] = { old in
                try JSONEncoder().encode(EditorMetadataEdits.merged(old, seed: thresholdOverrides, edits: edits.thresholds))
            }
        }
        let preserveAlpha = media.videoStream.map { $0.hasAlpha || $0.hasAdditionalVideoLayers } ?? false
        for tile in filmstrip {
            if cancelled() { throw CutError(code: "cancelled", message: "Saving filmstrip thumbnails was cancelled.") }
            if let data = autoreleasepool(invoking: { tile.key.encoded(tile.image, preserveAlpha: preserveAlpha) }) {
                sections[tile.key.section] = data
            }
        }
        let retention = filmstrip.isEmpty ? [:] : [FilmstripTileKey.sectionPrefix: FilmstripTileBuffer.countLimit]
        try AnalysisSidecar(media: media).save(sections, updating: updates, retainingLatest: retention, cancelled: cancelled)
    }
}
