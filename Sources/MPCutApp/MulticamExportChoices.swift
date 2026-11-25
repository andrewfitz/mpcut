import Foundation
import MPCutCore

/// The settings of a multicam export control. Every list, default and name comes from the export rules,
/// so the inspector, the queue and `mpcut export project render --project` offer the same thing.
struct MulticamExportChoices: Equatable, Sendable {
    let entry: ExportEntryPoint
    var tracks: ExportTracks = .all
    var placements: ExportPlacementScope = .none
    var requireCameraCopy = false
    var pictureTiming: StillPictureTiming?
    var heldStills: Bool {
        get { pictureTiming == .held }
        set { pictureTiming = newValue ? .held : .cadence }
    }
    private(set) var participantAudio: ParticipantAudioMode?
    private var supportsTileAudioOnly = false
    var trackChoices: [ExportTracks] {
        participantAudio == nil || supportsTileAudioOnly ? ExportTracks.allCases : [.all, .video]
    }
    /// The mode held for picture with sound. A single-type selection is written as the rules say.
    var mode: ExportMode
    var container: String
    var codec = ExportRules.defaultCodec
    var audio: ReencodeAudio
    var audioOutput: MulticamAudioOutput = .separateTracks
    // A quality chosen in the inspector or the queue is explicit for still generation.
    var standardQuality = ExportRules.defaultQuality(.h264) { didSet { qualityChosen = true } }
    var proResQuality = ExportRules.defaultQuality(.prores) { didSet { qualityChosen = true } }
    var qualityChosen = false
    /// The Settings container for an H.264 or HEVC re-encode. Nil is Automatic: the export rules' own first choice.
    var preferredContainer: String?
    /// Whether the last settled selection re-encoded with H.264 or HEVC. The preferred container is taken when a
    /// selection starts doing so, and a container chosen after that is kept.
    private var encodedStandardVideo = false

    init(entry: ExportEntryPoint, preferred: ExportMode = ExportRules.defaultMode(for: .multicam)) {
        self.entry = entry
        mode = preferred
        container = ExportRules.multicamListedContainers(tracks: .all, mode: preferred)[0]
        audio = ExportRules.cell(source: .multicam, tracks: .all, mode: preferred).defaultAudio ?? .copyOriginal
    }

    mutating func usePictureProject(_ project: CutProject?) {
        guard let project, project.requiresPictureProcessing else {
            participantAudio = nil
            supportsTileAudioOnly = false
            return
        }
        if participantAudio == nil { mode = .encode }
        participantAudio = project.projectOutputSettings.audio.mode
        supportsTileAudioOnly = project.participants.render == nil
    }

    private func cell(_ mode: ExportMode) -> ExportCell { entry.answer(source: .multicam, tracks: tracks, mode: mode, placements: placements) }
    var effectiveMode: ExportMode {
        if participantAudio != nil { return tracks == .audio ? mode : .encode }
        if placements != .none && modes.contains(mode) { return mode }
        return ExportRules.defaultMode(for: .multicam, tracks: tracks, preferred: mode)
    }
    /// The modes the rules write as themselves for the selected tracks.
    var modes: [ExportMode] {
        if participantAudio != nil {
            return tracks == .audio ? ExportEntryPoint.queue.selectableModes(source: .audio, tracks: .audio) : [.encode]
        }
        return entry.selectableModes(source: .multicam, tracks: tracks, placements: placements)
    }
    func title(of mode: ExportMode) -> String {
        participantAudio == nil ? cell(mode).displayName : ExportRules.displayName(mode: mode, soundOnly: tracks == .audio)
    }
    func containers(mode: ExportMode? = nil) -> [String] {
        let mode = mode ?? effectiveMode
        if participantAudio != nil {
            return tracks == .audio ? ExportRules.stillContainers(mode: mode, tracks: tracks, codec: codec, audio: audio)
                : ExportRules.multicamReencodeContainers(codec)
        }
        let listed: [String]
        if placements == .none {
            listed = ExportRules.multicamListedContainers(tracks: tracks, mode: mode, codec: codec)
        } else if tracks == .audio && mode == .encode && audio == .auto {
            listed = ExportRules.stillSoundCopyContainers.filter {
                !ExportRules.multicamRenderedAudioActions(container: $0).isEmpty
            }
        } else {
            listed = ExportRules.stillContainers(mode: mode, tracks: tracks, codec: codec, audio: audio)
        }
        guard tracks != .video, audio != .removeAudio else { return listed }
        return listed.filter { container in
            let rendered = ExportRules.multicamRenderedAudioActions(container: container)
            if audio == .pcm || audio == .aac { return rendered.contains(audio) }
            return audioOutput == .separateTracks || !rendered.isEmpty
        }
    }
    var deliveryActions: [ReencodeAudio] {
        let rule = cell(effectiveMode)
        let actions = rule.isAllowed ? rule.audioActions
            : ExportRules.cell(source: .multicam, tracks: tracks, mode: .copy).audioActions
        if participantAudio != nil, tracks == .audio {
            return effectiveMode == .copy ? [.copyOriginal] : [.auto] + ExportRules.stillSoundConversions
        }
        if participantAudio != nil { return ExportRules.multicamAudioActions.filter { $0 != .copyOriginal } }
        return actions.filter { $0 != .copyOriginal || audioOutput == .separateTracks }
    }
    var qualities: [ReencodeQuality] { ExportRules.qualities(codec) }
    var quality: ReencodeQuality { codec == .prores ? proResQuality : standardQuality }
    var settings: ReencodeSettings {
        ReencodeSettings(codec: codec, quality: quality, audio: participantAudio != nil && audio == .copyOriginal ? .auto : audio,
                         qualityIsExplicit: qualityChosen)
    }
    var requestedAudioAction: ReencodeAudio? { audio == .copyOriginal ? nil : audio }

    /// A single-type selection names the mode the rules write it with.
    static func title(of tracks: ExportTracks, silentProject: Bool = false, placements: ExportPlacementScope = .none) -> String {
        let written = ExportRules.cell(source: .multicam, tracks: tracks, mode: .copy).displayName
        switch tracks {
        case .all: return silentProject ? "Project tracks (picture only)" : "Project tracks"
        case .video: return placements == .none ? "Picture only (\(written))" : "Picture only"
        case .audio: return "Sound only"
        }
    }

    /// Keeps the container among those listed for the selection.
    mutating func settle(mode: ExportMode? = nil) {
        if !trackChoices.contains(tracks) { tracks = .all }
        if participantAudio != nil, tracks == .audio, effectiveMode == .copy { audio = .copyOriginal }
        else if (participantAudio != nil || audioOutput != .separateTracks) && audio == .copyOriginal { audio = .auto }
        if tracks == .audio && audio == .removeAudio { audio = .auto }
        if placements == .insertion, tracks == .audio, (mode ?? effectiveMode) == .encode, audio == .copyOriginal {
            audio = .pcm
        }
        let listed = containers(mode: mode)
        let encodes = encodesStandardVideo(mode: mode)
        if encodes, !encodedStandardVideo, let preferredContainer, listed.contains(preferredContainer) {
            container = preferredContainer
        }
        encodedStandardVideo = encodes
        if !listed.contains(container), let first = listed.first { container = first }
    }

    /// True when the selection re-encodes picture with H.264 or HEVC, the case the container preference names.
    func encodesStandardVideo(mode: ExportMode? = nil) -> Bool {
        (mode ?? effectiveMode) == .encode && tracks != .audio && codec != .prores
    }

    /// Records the current selection as settled, so that a container set by hand stays.
    mutating func keepContainer() { encodedStandardVideo = encodesStandardVideo() }

    /// The selection an alternative of the export rules stands for.
    mutating func apply(_ alternative: ExportAlternative) {
        tracks = alternative.tracks
        mode = alternative.mode
        container = alternative.container
        if let video = alternative.stillVideoSettings {
            codec = video.codec
            if video.codec == .prores { proResQuality = video.quality }
            else { standardQuality = video.quality }
            qualityChosen = video.qualityIsExplicit
        }
        let requestedAudio = alternative.argument("--audio").flatMap(ReencodeAudio.init(rawValue:))
        if let action = requestedAudio ?? alternative.audio { audio = action }
        audioOutput = alternative.argument("--audio-output").flatMap(MulticamAudioOutput.init(rawValue:)) ?? .separateTracks
        if placements != .none {
            requireCameraCopy = alternative.arguments.contains("--require-camera-copy")
            pictureTiming = alternative.argument("--still-timing").flatMap(StillPictureTiming.init(rawValue:)) ?? pictureTiming
        }
        // The alternative names its container. The preference does not replace it.
        keepContainer()
    }

    /// Fresh choices start from the Settings export defaults. The export rules still decide what the selection can use:
    /// `settle` replaces a default the selection cannot take, and the controls show the effective choice.
    @MainActor
    mutating func seed(from preferences: EditorPreferences) {
        // A starting value from Settings is not a quality chosen in the inspector or the queue.
        let chosen = qualityChosen
        defer { qualityChosen = chosen }
        codec = preferences.reencodeCodec
        standardQuality = preferences.reencodeQuality
        proResQuality = preferences.proresQuality
        audioOutput = preferences.multicamAudioLayout
        // A downmix renders the program sound, so it cannot copy the original tracks.
        if audioOutput != .separateTracks && audio == .copyOriginal { audio = .auto }
        // Another codec can list other containers.
        if !containers().contains(container), let first = containers().first { container = first }
        // Automatic keeps the multicam split: the export rules list MOV first. ProRes is always MOV.
        switch preferences.reencodeContainer {
        case .automatic: preferredContainer = nil
        case .mp4, .mov, .mkv: preferredContainer = preferences.reencodeContainer.rawValue
        }
        guard let preferredContainer else { return }
        if encodesStandardVideo(), containers().contains(preferredContainer) { container = preferredContainer }
        keepContainer()
    }
}

extension MulticamAudioOutput {
    var title: String {
        switch self {
        case .separateTracks: "Separate tracks"
        case .downmixMono: "Downmix to mono"
        case .downmixStereo: "Downmix to stereo"
        }
    }

    static let playbackHelp = "Players typically play one separate track at a time. A downmix delivers the timeline’s combined sound as one track."
}
