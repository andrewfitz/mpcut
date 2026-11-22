import Foundation
import MPCutCore

/// The settings of a multicam export control. Every list, default and name comes from the export rules,
/// so the inspector, the queue and `mpcut export --project` offer the same thing.
struct MulticamExportChoices: Equatable, Sendable {
    let entry: ExportEntryPoint
    var tracks: ExportTracks = .all
    /// The mode held for picture with sound. A single-type selection is written as the rules say.
    var mode: ExportMode
    var container: String
    var codec = ExportRules.defaultCodec
    var audio: ReencodeAudio
    var standardQuality = ExportRules.defaultQuality(.h264)
    var proResQuality = ExportRules.defaultQuality(.prores)

    init(entry: ExportEntryPoint, preferred: ExportMode = ExportRules.defaultMode(for: .multicam)) {
        self.entry = entry
        mode = preferred
        container = ExportRules.multicamListedContainers(tracks: .all, mode: preferred)[0]
        audio = ExportRules.cell(source: .multicam, tracks: .all, mode: .encode).defaultAudio ?? .auto
    }

    private func cell(_ mode: ExportMode) -> ExportCell { entry.answer(source: .multicam, tracks: tracks, mode: mode) }
    var effectiveMode: ExportMode { ExportRules.defaultMode(for: .multicam, tracks: tracks, preferred: mode) }
    /// The modes the rules write as themselves for the selected tracks.
    var modes: [ExportMode] { entry.selectableModes(source: .multicam, tracks: tracks) }
    func title(of mode: ExportMode) -> String { cell(mode).displayName }
    func containers(mode: ExportMode? = nil) -> [String] {
        ExportRules.multicamListedContainers(tracks: tracks, mode: mode ?? effectiveMode, codec: codec)
    }
    /// The audio actions of a re-encode.
    var audioActions: [ReencodeAudio] { ExportRules.cell(source: .multicam, tracks: .all, mode: .encode).audioActions }
    var qualities: [ReencodeQuality] { ExportRules.qualities(codec) }
    var quality: ReencodeQuality { codec == .prores ? proResQuality : standardQuality }
    var settings: ReencodeSettings { ReencodeSettings(codec: codec, quality: quality, audio: audio) }

    /// A single-type selection names the mode the rules write it with.
    static func title(of tracks: ExportTracks, silentProject: Bool = false) -> String {
        let written = ExportRules.cell(source: .multicam, tracks: tracks, mode: .copy).displayName
        switch tracks {
        case .all: return silentProject ? "Project tracks (picture only)" : "Project tracks"
        case .video: return "Picture only (\(written))"
        case .audio: return "Sound only (\(written))"
        }
    }

    /// Keeps the container among those listed for the selection.
    mutating func settle(mode: ExportMode? = nil) {
        let listed = containers(mode: mode)
        if !listed.contains(container), let first = listed.first { container = first }
    }

    /// The selection an alternative of the export rules stands for.
    mutating func apply(_ alternative: ExportAlternative) {
        tracks = alternative.tracks
        mode = alternative.mode
        container = alternative.container
        if alternative.mode == .encode, let action = alternative.audio { audio = action }
    }
}
