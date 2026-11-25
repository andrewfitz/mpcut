import Foundation
import os

// The single source of truth for export decisions. Every front end asks these rules what a
// request means, which settings it may carry, what its defaults are and what to offer when
// it cannot be written. docs/EXPORT-RULES.md is generated from this file.

/// What the first clip of an export is.
public enum ExportSourceKind: String, CaseIterable, Codable, Sendable {
    case movie, audio, multicam

    public var displayName: String {
        switch self {
        case .movie: return "Movie"
        case .audio: return "Audio recording"
        case .multicam: return "Multicam program"
        }
    }
}

/// An alternative export offered when the requested one cannot be written.
public enum ExportRung: String, CaseIterable, Codable, Sendable {
    case copyOtherContainer = "copy_other_container", copySampleAligned = "copy_sample_aligned", smartTrim = "smart_trim", convertSameFormat = "convert_same_format", convertPCM = "convert_pcm", convertAAC = "convert_aac", reencode

    /// Named ranking criteria. A lower value is preferred, compared in this order.
    public struct Rank: Comparable, Sendable {
        /// 0 keeps every source packet, 1 encodes only cut edges, 2 encodes the sound, 3 encodes picture and sound.
        public let encodedScope: Int
        /// 0 keeps the source format, 1 changes it.
        public let formatChange: Int
        /// 0 adds no loss, 1 adds an encoding generation.
        public let addedLoss: Int
        /// Relative time to write, lowest first.
        public let cost: Int

        public static func < (a: Rank, b: Rank) -> Bool {
            (a.encodedScope, a.formatChange, a.addedLoss, a.cost) < (b.encodedScope, b.formatChange, b.addedLoss, b.cost)
        }
    }

    public var rank: Rank {
        switch self {
        case .copyOtherContainer: return Rank(encodedScope: 0, formatChange: 0, addedLoss: 0, cost: 0)
        case .copySampleAligned: return Rank(encodedScope: 0, formatChange: 0, addedLoss: 0, cost: 1)
        case .smartTrim: return Rank(encodedScope: 1, formatChange: 0, addedLoss: 1, cost: 2)
        case .convertSameFormat: return Rank(encodedScope: 2, formatChange: 0, addedLoss: 1, cost: 3)
        case .convertPCM: return Rank(encodedScope: 2, formatChange: 1, addedLoss: 0, cost: 3)
        case .convertAAC: return Rank(encodedScope: 2, formatChange: 1, addedLoss: 1, cost: 4)
        case .reencode: return Rank(encodedScope: 3, formatChange: 1, addedLoss: 1, cost: 5)
        }
    }

    /// One description, used by the app, CLI text, CLI JSON, help and the written matrix.
    public var summary: String {
        switch self {
        case .copyOtherContainer: return "Keep the original packets and use a container that supports these cuts."
        case .copySampleAligned: return "Move each cut to the nearest audio sample, then copy the audio. Each cut moves by less than one sample."
        case .smartTrim: return "Copy complete sections and encode only the video at the cut edges."
        case .convertSameFormat: return "Re-encode the selected audio once using the original codec (MP3, AAC, ALAC, FLAC or Opus) and settings."
        case .convertPCM: return "Save the selected audio as a PCM WAV file. This preserves the decoded samples and uses more disk space. A lossless source named into a container that cannot hold its own codec is also offered there as PCM, ALAC or FLAC, the first that container holds, when that keeps every sample."
        case .convertAAC: return "Save the selected audio as AAC in an M4A file."
        case .reencode: return "Encode the whole timeline with the hardware video encoder."
        }
    }

    /// The label of one offer. `container` and `audio` describe the offered export.
    /// A multicam program and a movie re-encode keep their picture, so their sound offers name the re-encode.
    public func label(container: String, audio: ReencodeAudio?, lossless: Bool, source: ExportSourceKind = .audio) -> String {
        let reencode = ExportRules.displayName(mode: .encode)
        switch self {
        case .copyOtherContainer: return "Copy to \(ExportRules.containerDisplayName(container)) (lossless)"
        case .copySampleAligned: return "Copy with cuts on the nearest audio sample (lossless)"
        case .smartTrim: return "Use \(ExportRules.displayName(mode: .smart)) (encodes only the cut edges)"
        case .convertSameFormat:
            let name = audio.map(ExportRules.displayName(audio:)) ?? "the source format"
            return "Convert to \(name) (same format\(lossless ? ", lossless" : ""))"
        case .convertPCM:
            if source == .multicam { return "\(reencode) with PCM sound (no further quality loss)" }
            // The lossless conversion of a named container other than WAV says which codec it writes there.
            guard container != ExportRules.conversionContainers(.pcm)[0] else { return "Convert to WAV (no further quality loss)" }
            return "Convert to \(ExportRules.displayName(audio: audio ?? .pcm)) in \(ExportRules.containerDisplayName(container)) with no further quality loss"
        case .convertAAC:
            return source == .multicam ? "\(reencode) with AAC sound" : "Convert to AAC (.m4a, smaller)"
        case .reencode:
            guard let audio else { return "Choose \(reencode)" }
            return "\(reencode) to \(ExportRules.containerDisplayName(container)) with \(ExportRules.displayName(audio: audio)) audio"
        }
    }
}

/// Where an export request comes from. Restrictions are stated once, here.
public enum ExportEntryPoint: String, CaseIterable, Codable, Sendable {
    case sheet = "export_sheet", queue = "export_queue", multicamSheet = "multicam_export_sheet", multicamQueue = "multicam_export_queue", replacement = "soundtrack_replace"
    case cliExport = "cli_export_clips_join", cliBulk = "cli_export_ranges_separate", cliRearrange = "cli_export_ranges_join"
    case cliSilence = "cli_silence_export", cliScenes = "cli_scenes_export", cliProject = "cli_export_project_render"

    public var displayName: String {
        switch self {
        case .sheet: return "App: Export sheet"
        case .queue: return "App: Export Queue"
        case .multicamSheet: return "App: multicam Export inspector"
        case .multicamQueue: return "App: multicam Export Queue"
        case .replacement: return "App and CLI: Replace Source Audio"
        case .cliExport: return "CLI: export clips join"
        case .cliBulk: return "CLI: export ranges separate"
        case .cliRearrange: return "CLI: export ranges join"
        case .cliSilence: return "CLI: silence export"
        case .cliScenes: return "CLI: scenes export"
        case .cliProject: return "CLI: export project render (multicam)"
        }
    }

    public var source: ExportSourceKind {
        switch self {
        case .multicamSheet, .multicamQueue, .cliProject: return .multicam
        default: return .movie
        }
    }

    /// The modes this entry point can request. The matrix decides what each one means.
    public var modes: [ExportMode] {
        switch self {
        case .replacement: return [.copy]
        case .cliScenes, .cliRearrange: return [.smart]
        case .cliSilence: return [.smart, .copy]
        default: return [.smart, .copy, .encode]
        }
    }

    /// Every entry point reports the ordered alternatives of the ladder, except a replaced soundtrack, which has one way to be written.
    public var offersAlternatives: Bool { self != .replacement }

    /// The refusal of a mode this entry point does not write. Nil when it does.
    public func refusal(of mode: ExportMode) -> CutError? {
        guard !modes.contains(mode) else { return nil }
        let names = modes.map { ExportRules.displayName(mode: $0) }.joined(separator: " or ")
        return CutError(code: "invalid_arguments",
                        message: "\(displayName) writes \(names). Use export for \(ExportRules.displayName(mode: mode)).")
    }

    /// The table's answer for a request made here: the matrix cell, or the refusal of a mode this entry point does not write.
    public func answer(source: ExportSourceKind, tracks: ExportTracks, mode: ExportMode,
                       placements: ExportPlacementScope = .none) -> ExportCell {
        let cell = ExportRules.cell(source: source, tracks: tracks, mode: mode, placements: placements)
        guard let refusal = refusal(of: mode) else { return cell }
        return ExportCell(source: source, tracks: cell.tracks, mode: mode, resolvedMode: cell.resolvedMode, refusal: refusal,
                          containers: nil, audioActions: [], defaultAudio: nil, rungs: [])
    }

    /// The modes a mode control lists here for a selection: those the table writes as themselves.
    public func selectableModes(source: ExportSourceKind, tracks: ExportTracks,
                                placements: ExportPlacementScope = .none) -> [ExportMode] {
        modes.filter {
            let cell = answer(source: source, tracks: tracks, mode: $0, placements: placements)
            return cell.resolvedMode == $0 && (cell.isAllowed || cell.refusal?.code == "still_requires_generation")
        }
    }

    /// Named restrictions with their reason.
    public var restrictions: [String] {
        switch self {
        case .sheet:
            return ["noAutoAudioConversion: Convert Audio names a format, so the sheet always shows what it will write. The first offer is what `--audio auto` applies."]
        case .queue:
            return ["sharedSettings: one setting applies to every range, so an alternative that moves cuts (`copy_sample_aligned`) is not offered.",
                    "sourceCompatible: Lossless Copy and Smart Trim can leave the container to the copy planner."]
        case .multicamSheet, .multicamQueue:
            return ["listedContainers: the app lists containers for the selected picture mode and audio delivery. The CLI accepts every extension the planner verifies.",
                    "switchTimes: an unsafe switch or range edge also reports verified times."]
        case .cliProject:
            return ["namedOutput: the extension of `--output` is the container.",
                    "audioDelivery: separate tracks default to copy. Explicit `--audio auto` chooses treatment per lane. Downmix always renders.",
                    "switchTimes: an unsafe switch or range edge also reports verified times in `nearest`."]
        case .replacement:
            return ["copyOnly: a replaced soundtrack is copied with both track types."]
        case .cliExport:
            return ["namedOutput: `--audio auto` applies the first alternative that fits the extension of `--output`."]
        case .cliBulk:
            return ["namedOutput: `--audio auto` applies the first alternative that fits `container` when one is given."]
        case .cliRearrange:
            return ["noEncode: use export clips join for --mode encode.", "nearestByDefault: video cuts snap to the nearest boundary."]
        case .cliSilence:
            return ["noEncode: retained ranges are written with Smart Trim or Lossless Copy.",
                    "generatedClips: the failing clips are the retained ranges, so each alternative lists them in `clips`.",
                    "projectRanges: with `--project` the retained ranges resolve through `MulticamEngine.resolution` like `export project render --project`. They exist only in the report, so the alternatives listed are the ones this command can request for them: another container or the other mode, through its own `--output` and `--mode`."]
        case .cliScenes:
            return ["smartOnly: every scene is written with Smart Trim, or Lossless Copy for a single-type selection."]
        }
    }
}

/// One cell of the matrix: what a mode means for a source kind and track selection.
public struct ExportCell: Sendable {
    public let source: ExportSourceKind
    public let tracks: ExportTracks
    public let mode: ExportMode
    /// The mode that is written. Smart Trim applies to picture, so other selections copy.
    public let resolvedMode: ExportMode
    /// Nil when allowed.
    public let refusal: CutError?
    /// Fixed containers. Nil means every container the copy planner verifies for the source.
    public let containers: [String]?
    public let audioActions: [ReencodeAudio]
    public let defaultAudio: ReencodeAudio?
    /// Ordered alternatives tried when this export is unavailable.
    public let rungs: [ExportRung]

    public var isAllowed: Bool { refusal == nil }
    /// The name shown for this mode with this selection.
    public var displayName: String { ExportRules.displayName(mode: resolvedMode, soundOnly: soundOnly) }
    var soundOnly: Bool { source == .audio || (tracks == .audio && (source != .multicam || resolvedMode == .encode)) }
}

/// The generated spans that are visible within an export selection.
public enum ExportPlacementScope: Int, Sendable, Equatable {
    case none, replacement, insertion
}

public enum ExportRules {
    // MARK: Names

    public static func displayName(mode: ExportMode, soundOnly: Bool = false) -> String {
        switch mode {
        case .smart: return "Smart Trim"
        case .copy: return "Lossless Copy"
        case .encode: return soundOnly ? "Convert Audio" : "Re-encode"
        }
    }

    public static func displayName(audio: ReencodeAudio) -> String {
        switch audio {
        case .auto: return "Auto"
        case .copyOriginal: return "Copy Original"
        case .aac: return "AAC"
        case .alac: return "ALAC"
        case .pcm: return "PCM"
        case .removeAudio: return "Remove Audio"
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        case .opus: return "Opus"
        }
    }

    public static func summary(audio: ReencodeAudio) -> String {
        switch audio {
        case .auto: return "Copy the original audio when possible. Otherwise, use the first supported alternative."
        case .copyOriginal: return "Copy the original audio packets. Stop if they can’t be copied exactly."
        case .aac: return "Encode AAC."
        case .alac: return "Encode Apple Lossless audio for a sound-only conversion or a still-bearing export."
        case .pcm: return "Write PCM."
        case .removeAudio: return "Omit the audio track."
        case .mp3: return "Encode MP3 with LAME."
        case .flac: return "Encode FLAC, which is lossless."
        case .opus: return "Encode Opus with libopus."
        }
    }

    public static func displayName(tracks: ExportTracks) -> String {
        switch tracks {
        case .all: return "Video and audio"
        case .video: return "Video only"
        case .audio: return "Audio only"
        }
    }

    public static func containerDisplayName(_ container: String) -> String {
        switch container.lowercased() {
        case "mov": return "QuickTime (.mov)"
        case "mp4": return "MPEG-4 (.mp4)"
        case "m4v": return "MPEG-4 (.m4v)"
        case "mkv": return "Matroska (.mkv)"
        case "webm": return "WebM (.webm)"
        case "wav": return "WAVE (.wav)"
        case "mka": return "Matroska Audio (.mka)"
        case "m4a": return "MPEG-4 Audio (.m4a)"
        case "opus": return "Ogg Opus (.opus)"
        case "ogg": return "Ogg (.ogg)"
        default: return container.uppercased()
        }
    }

    // MARK: Static capability

    /// Containers of a movie re-encode for each video codec.
    public static func reencodeContainers(_ codec: ReencodeCodec) -> [String] {
        switch codec {
        case .h264, .hevc: return ["mp4", "mov", "mkv"]
        case .prores: return ["mov", "mkv"]
        case .jpeg: return ["mov"]
        }
    }
    static let reencodeContainerRefusal = CutError(code: "unsupported_container",
                                                   message: "Choose MP4, MOV, or MKV for Re-encode. ProRes requires MOV or MKV. JPEG requires MOV.")
    /// Containers whose movie clock and edit lists carry a multicam program.
    public static let multicamMovieContainers = ["mov", "mp4", "m4v"]
    /// Containers of a multicam program with picture and sound. Matroska ones are muxed by the FFmpeg helper.
    public static let multicamContainers = multicamMovieContainers + ["mkv", "webm"]
    static let multicamContainerRefusal = CutError(code: "unsupported_container",
                                                   message: "Choose MOV, MP4, MKV or WebM for multicam picture and sound.")
    /// What to do when a picture-only or sound-only multicam copy stops at a cut that no other container takes.
    /// That row offers another container only, so this is said in the refusal and is not an alternative.
    /// `together` is the mode that writes picture and sound together for the same program, when one plans.
    static func multicamSingleTypeAdvice(tracks: ExportTracks, hasNearest: Bool, together: ExportMode?) -> String {
        let kind = tracks == .video ? "picture-only" : "sound-only"
        let steps = (hasNearest ? ["move the cut to one of the verified times"] : [])
            + (together.map { ["export picture and sound together with \(displayName(mode: $0))"] } ?? [])
        let advice = "A \(kind) multicam export is a \(displayName(mode: .copy)), which needs a verified time at every cut."
        guard let first = steps.first else { return advice }
        return advice + " " + first.prefix(1).uppercased() + first.dropFirst() + steps.dropFirst().map { ", or \($0)" }.joined() + "."
    }
    /// The container a multicam program is written as. FFmpeg identifies M4V as raw video, so it is written as MP4.
    public static func multicamMuxContainer(_ container: String) -> String { container == "m4v" ? "mp4" : container }
    /// Containers of a multicam re-encode for each video codec.
    public static func multicamReencodeContainers(_ codec: ReencodeCodec) -> [String] {
        multicamContainers.filter { reencodeContainers(codec).contains(multicamMuxContainer($0)) }
    }
    /// Containers a front end lists for a multicam program. A single-type copy is verified by the copy planner,
    /// so the CLI accepts other extensions too.
    public static func multicamListedContainers(tracks: ExportTracks, mode: ExportMode, codec: ReencodeCodec = defaultCodec) -> [String] {
        if tracks == .audio { return multicamMovieContainers + ["mkv", "wav", "caf", "m4a"] }
        return tracks == .all && mode == .encode ? multicamReencodeContainers(codec) : multicamContainers
    }
    /// Rendered program sound is selected independently of picture encoding.
    public static func multicamRenderedAudioActions(container: String) -> [ReencodeAudio] {
        switch multicamMuxContainer(container.lowercased()) {
        case "mov": return [.pcm, .aac]
        case "mp4", "m4a": return [.aac]
        case "mkv", "wav", "wave", "caf": return [.pcm]
        default: return []
        }
    }

    /// Containers that carry an audio treatment of a movie or multicam re-encode. Copy, auto and remove fit every one.
    public static func reencodeContainers(for audio: ReencodeAudio, source: ExportSourceKind, codec: ReencodeCodec = defaultCodec) -> [String] {
        let all = source == .multicam ? multicamReencodeContainers(codec) : reencodeContainers(codec)
        return all.filter { reencodeRefusal(audio: audio, container: $0, source: source) == nil }
    }
    /// The refusal of an audio treatment in a re-encode container. Nil when the container carries it.
    public static func reencodeRefusal(audio: ReencodeAudio, container: String, source: ExportSourceKind) -> CutError? {
        let written = multicamMuxContainer(container)
        switch audio {
        case .pcm where !["mov", "mkv"].contains(written):
            return CutError(code: "unsupported_audio", message: "Choose MOV or MKV for PCM audio.")
        case .aac where source == .multicam && !["mov", "mp4"].contains(written):
            // The program sound keeps gapless timing through a movie edit list, which Matroska lacks.
            return CutError(code: "unsupported_audio", message: "Choose MOV or MP4 for converted multicam AAC with gapless timing.")
        default:
            return nil
        }
    }
    /// What `auto` converts to when the sound of a re-encode cannot be copied exactly, in order of preference.
    public static func automaticAudio(codec: ReencodeCodec, container: String, source: ExportSourceKind) -> [ReencodeAudio] {
        let preferred: [ReencodeAudio] = codec == .prores && multicamMuxContainer(container) != "mp4" ? [.pcm, .aac] : [.aac, .pcm]
        return preferred.filter { reencodeRefusal(audio: $0, container: container, source: source) == nil }
    }
    /// Compressed sound codecs that decode to exactly the samples that were encoded. Linear PCM is lossless as well.
    static let losslessAudioCodecs: Set<String> = ["flac", "alac", "truehd", "mlp"]
    /// True when decoding the codec loses nothing, so writing PCM adds no loss.
    public static func isLosslessAudio(codec: String) -> Bool {
        codec.hasPrefix("pcm_") || losslessAudioCodecs.contains(codec)
    }
    /// What `auto` converts one sound track of a movie re-encode to when it cannot be copied exactly, in order of
    /// preference. `lossless` is true when the track is lossless in every clip: PCM then ranks first, because it is
    /// the less destructive conversion, and AAC is left for a container that cannot carry the track as PCM.
    public static func automaticAudio(codec: ReencodeCodec, container: String, source: ExportSourceKind,
                                      lossless: Bool, channels: Int) -> [ReencodeAudio] {
        let preferred: [ReencodeAudio] = lossless ? [.pcm, .aac] : automaticAudio(codec: codec, container: container, source: source)
        return preferred.filter { action in
            reencodeRefusal(audio: action, container: container, source: source) == nil
                && (action != .pcm || reencodeKeepsPCMLayout(channels: channels, container: container))
        }
    }
    /// Matroska states no speaker positions for PCM. A re-encode can verify mono and stereo PCM there and nothing wider,
    /// so `auto` does not choose PCM for a wider track in Matroska. An explicit `pcm` is refused when it is verified.
    static func reencodeKeepsPCMLayout(channels: Int, container: String) -> Bool {
        multicamMuxContainer(container) != "mkv" || channels <= 2
    }
    /// Why `auto` chose the conversion of a lossless track. Nil for a track that is not lossless.
    static func automaticAudioNote(_ action: ReencodeAudio, lossless: Bool, channels: Int, container: String) -> String? {
        guard lossless else { return nil }
        let name = multicamMuxContainer(container).uppercased()
        switch action {
        case .pcm:
            return "The lossless source is written as PCM, so no lossy encoding is added."
        case .aac where reencodeRefusal(audio: .pcm, container: container, source: .movie) == nil:
            return "The source is lossless, but \(name) cannot keep the channel layout of PCM with more than two channels, so it is converted to AAC. Choose MOV to keep it lossless."
        case .aac:
            return "The source is lossless, but \(name) cannot carry PCM here, so it is converted to AAC. Choose \(channels <= 2 ? "MOV or MKV" : "MOV") to keep it lossless."
        default:
            return nil
        }
    }

    // MARK: Auto keeps the source format

    /// The sound of one output track that `auto` cannot copy, as every clip of the track has it.
    public struct AutomaticAudioSource: Sendable, Equatable {
        /// The codec every clip shares. Nil when the clips differ in codec or settings.
        public var codec: String?
        /// True when every clip is lossless.
        public var lossless: Bool
        /// The word length of a FLAC or ALAC source. Nil when unknown.
        public var integerDepth: Int?
        public var sampleRate: Int
        public var channels: Int
        /// The channel layout name, such as `stereo` or `5.1(side)`.
        public var layout: String
        /// "HE-AAC" or "HE-AAC v2" for an AAC source with a High Efficiency profile.
        public var highEfficiency: String?

        public init(codec: String?, lossless: Bool, integerDepth: Int? = nil, sampleRate: Int, channels: Int,
                    layout: String, highEfficiency: String? = nil) {
            self.codec = codec
            self.lossless = lossless
            self.integerDepth = integerDepth
            self.sampleRate = sampleRate
            self.channels = channels
            self.layout = layout
            self.highEfficiency = highEfficiency
        }
    }

    /// The encoders of the bundled FFmpeg helper that `auto` can write a source format with.
    static let automaticEncoders: [ReencodeAudio: String] = [.aac: "aac", .flac: "flac", .alac: "alac", .mp3: "libmp3lame", .opus: "libopus"]
    /// The name of a source codec in a reason.
    static func audioCodecName(_ codec: String) -> String {
        if codec.hasPrefix("pcm_") { return "PCM" }
        switch codec {
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case "mp2": return "MP2"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "truehd": return "TrueHD"
        case "mlp": return "MLP"
        case "wavpack": return "WavPack"
        default:
            return codec.hasPrefix("dts") ? "DTS" : codec.uppercased()
        }
    }
    /// The codec `auto` writes back for a source codec, when the helper has its encoder.
    static func sourceFormat(for codec: String) -> ReencodeAudio? {
        switch codec {
        case "aac": return .aac
        case "flac": return .flac
        case "alac": return .alac
        case "mp3": return .mp3
        case "opus": return .opus
        default: return codec.hasPrefix("pcm_") ? .pcm : nil
        }
    }
    /// The channel layouts the FLAC and ALAC encoders keep, as `ExactSoundEncoding` states them.
    static func losslessEncoderLayouts(_ action: ReencodeAudio) -> [String] {
        action == .alac ? ["mono", "stereo", "3.0", "4.0", "5.0", "5.1", "6.1(back)", "7.1(wide)"]
            : ["mono", "stereo", "3.0", "quad", "5.0", "5.1", "6.1", "7.1"]
    }

    /// Why the source format of a track cannot be written in a re-encode container, or nil when it can. These pairs were
    /// checked against the muxers of the bundled helper: MOV refuses FLAC and Opus ("only supported in MP4"), MP4 refuses
    /// MP3 below 16 kHz, and Matroska takes all of them, though ALAC there is not read back exactly and is left out.
    /// Multicam AAC keeps the movie edit list it needs for gapless timing.
    static func sourceFormatIssue(_ action: ReencodeAudio, track: AutomaticAudioSource, container: String,
                                  source: ExportSourceKind) -> String? {
        let written = multicamMuxContainer(container)
        let name = written.uppercased()
        let label = displayName(audio: action)
        switch action {
        case .pcm:
            return nil
        case .aac:
            if source == .multicam && !["mov", "mp4"].contains(written) { return "Multicam AAC needs a movie edit list, which \(name) lacks" }
            return track.channels > 8 ? "AAC carries at most eight channels" : nil
        case .flac, .alac:
            // The helper writes ALAC into Matroska, but MPCut cannot read its word length back there, so it is not verified.
            guard (action == .flac ? ["mp4", "mkv"] : ["mov", "mp4"]).contains(written) else { return "\(name) cannot carry \(label) here" }
            if let depth = track.integerDepth, depth > 24 { return "The \(label) encoder keeps at most 24 bits" }
            if track.integerDepth == nil { return "The \(label) source does not declare its word length" }
            guard losslessEncoderLayouts(action).contains(track.layout) else { return "The \(label) encoder cannot keep the \(track.layout) channel layout" }
            // MP4 reads a FLAC 5.1 track back as 5.1(side).
            if action == .flac && written == "mp4" && track.channels > 2 { return "MP4 cannot keep the channel layout of FLAC with more than two channels" }
            if action == .flac && track.sampleRate >= 1 << 20 { return "FLAC cannot carry this sample rate" }
            return nil
        case .mp3:
            guard ["mov", "mp4", "mkv"].contains(written) else { return "\(name) cannot carry MP3 here" }
            if track.channels > 2 { return "MP3 carries mono or stereo sound" }
            if written == "mp4" && track.sampleRate < 16_000 { return "MP4 cannot carry MP3 below 16 kHz" }
            return [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000].contains(track.sampleRate)
                ? nil : "MP3 cannot carry this sample rate"
        case .opus:
            guard ["mp4", "mkv"].contains(written) else { return "\(name) cannot carry Opus here" }
            if track.sampleRate != 48_000 { return "Opus decodes at 48 kHz only" }
            return track.channels <= 2 || track.layout == StreamInfo.opusSurroundLayout(channels: track.channels)
                ? nil : "Opus cannot keep the \(track.layout) channel layout"
        default:
            return "\(name) cannot carry \(label) here"
        }
    }

    /// What `auto` writes for one sound track of a movie re-encode that it cannot copy, and why. The track keeps its
    /// source's codec and settings where the container and the helper allow: PCM stays PCM at its sample format, FLAC
    /// and ALAC keep their word length, and AAC, MP3 and Opus keep their rate. Otherwise a lossless track falls back to
    /// PCM and a lossy one to AAC, or for ProRes to PCM, as `automaticAudio(codec:container:source:lossless:channels:)`
    /// decides, and the reason says why. Tracks whose clips differ in format follow that rule too. `encoders` lists the
    /// helper's encoders when they are known, so no process starts while planning.
    public static func automaticAudio(codec: ReencodeCodec, container: String, source: ExportSourceKind,
                                      track: AutomaticAudioSource, encoders: Set<String>? = nil) -> (action: ReencodeAudio, note: String) {
        let name = multicamMuxContainer(container).uppercased()
        func fallback(_ why: String?) -> (action: ReencodeAudio, note: String) {
            let action = automaticAudio(codec: codec, container: container, source: source,
                                        lossless: track.lossless, channels: track.channels).first ?? .aac
            let kind = track.lossless ? "lossless" : "lossy"
            let subject = track.codec.map { "\(audioCodecName($0)) source" }
                ?? "\(track.lossless ? "lossless " : "")sources of this track, which differ in format,"
            guard let why else {
                // Clips that differ in format follow the rule by category.
                switch action {
                case .pcm where track.lossless:
                    return (action, "The \(subject) are written as PCM, so no lossy encoding is added.")
                case .pcm:
                    return (action, "The \(subject) are written as PCM for ProRes.")
                case .aac where track.lossless:
                    let pcm = reencodeRefusal(audio: .pcm, container: container, source: source) == nil
                    return (action, "The \(subject) are converted to AAC, because \(name) "
                        + (pcm ? "cannot keep the channel layout of PCM with more than two channels" : "cannot carry PCM here")
                        + ". Choose \(track.channels <= 2 && !pcm ? "MOV or MKV" : "MOV") to keep it lossless.")
                default:
                    return (action, "The \(subject) are converted to AAC.")
                }
            }
            switch action {
            case .pcm where track.lossless:
                return (action, "\(why), so the lossless \(subject) is written as PCM.")
            case .pcm:
                return (action, "\(why), so the lossy \(subject) is written as PCM for ProRes.")
            case .aac where track.lossless:
                let pcm = reencodeRefusal(audio: .pcm, container: container, source: source) == nil
                return (action, "\(why), and \(name) "
                    + (pcm ? "cannot keep the channel layout of PCM with more than two channels" : "cannot carry PCM here")
                    + ", so the lossless \(subject) is converted to AAC. Choose \(track.channels <= 2 && !pcm ? "MOV or MKV" : "MOV") to keep it lossless.")
            default:
                return (action, "\(why), so the \(kind) \(subject) is written as \(displayName(audio: action)).")
            }
        }
        guard let codec = track.codec else { return fallback(nil) }
        let label = audioCodecName(codec)
        guard let format = sourceFormat(for: codec) else {
            return fallback("The FFmpeg helper has no \(label) encoder")
        }
        if format == .pcm {
            // PCM keeps its sample format where the container carries PCM, as before.
            let action = automaticAudio(codec: .h264, container: container, source: source, lossless: true, channels: track.channels).first ?? .aac
            if action == .pcm { return (.pcm, "The PCM source is written as PCM at its own sample format, so no lossy encoding is added.") }
            let pcm = reencodeRefusal(audio: .pcm, container: container, source: source) == nil
            return (action, "The PCM source is lossless, but \(name) "
                + (pcm ? "cannot keep the channel layout of PCM with more than two channels" : "cannot carry PCM here")
                + ", so it is converted to AAC. Choose \(track.channels <= 2 && !pcm ? "MOV or MKV" : "MOV") to keep it lossless.")
        }
        if let encoders, !encoders.isEmpty, let encoder = automaticEncoders[format], !encoders.contains(encoder) {
            return fallback("The FFmpeg helper has no \(label) encoder")
        }
        if let issue = sourceFormatIssue(format, track: track, container: container, source: source) { return fallback(issue) }
        switch format {
        case .flac, .alac:
            return (format, "The \(label) source is written as \(label) at its own word length, so no lossy encoding is added.")
        case .aac where track.highEfficiency != nil:
            let profile = track.highEfficiency ?? "HE-AAC"
            return (format, "The \(profile) source is written as AAC-LC at its own rate: the AAC encoder writes LC only.")
        default:
            return (format, "The \(label) source is written as \(label) at its own rate.")
        }
    }
    static func audioActionRefusal(_ audio: ReencodeAudio, source: ExportSourceKind) -> CutError {
        let choices = movieAudioActions.map(\.rawValue)
        let list = choices.dropLast().joined(separator: ", ") + " or " + (choices.last ?? "")
        if audio == .alac {
            return CutError(code: "unsupported_audio", message: "ALAC conversion applies to audio-only and still-bearing exports. Choose \(list) for a movie.")
        }
        return CutError(code: "unsupported_audio", message: source == .multicam
            ? "Multicam conversion writes AAC or PCM sound. Choose \(list)."
            : "\(displayName(audio: audio)) conversion applies to audio-only exports. Choose \(list) for a movie.")
    }
    /// Audio treatments of a movie re-encode.
    public static let movieAudioActions: [ReencodeAudio] = [.auto, .copyOriginal, .aac, .pcm, .removeAudio]
    /// Audio treatments available independently of the multicam picture mode.
    public static let multicamAudioActions: [ReencodeAudio] = movieAudioActions
    /// Legacy settings use Auto as the default spelling of copy. Explicit Auto is resolved per lane.
    public static func multicamAudio(_ requested: ReencodeAudio) -> ReencodeAudio { requested == .auto ? .copyOriginal : requested }
    /// Audio treatments of a sound-only conversion.
    public static let soundAudioActions: [ReencodeAudio] = [.auto, .copyOriginal, .pcm, .alac, .flac, .aac, .mp3, .opus]
    /// The sound-only conversions that name a format, in the order help and the written rules list them.
    static let soundConversions: [ReencodeAudio] = [.pcm, .aac, .mp3, .alac, .flac, .opus]
    /// The refusal of a sound-only conversion whose output names no extension.
    static var soundExtensionRefusal: CutError {
        let extensions = [ReencodeAudio.mp3, .flac, .opus, .pcm, .aac].map { "." + conversionContainers($0)[0] }
        return CutError(code: "unsupported_container",
                        message: "Give the output an extension to choose its format: \(extensions.dropLast().joined(separator: ", ")) or \(extensions.last ?? "").")
    }
    /// The formats a Convert Audio control names: the source's own first, then every conversion with a container.
    public static func namedConversions(sourceCodec: String?) -> [ReencodeAudio] {
        let named = soundAudioActions.filter { !conversionContainers($0).isEmpty }
        return ([sourceCodec.flatMap(sameFormat(for:))].compactMap { $0 } + named).reduce(into: []) { list, format in
            if !list.contains(format) { list.append(format) }
        }
    }
    /// Containers a batch can ask a movie copy for before its cuts are verified. Each range is verified when it is planned,
    /// and no choice leaves the container to the copy planner.
    public static let movieCopyContainers = ["mp4", "mov", "mkv", "webm"]
    /// Containers a replaced soundtrack can be written into, default first after the source's own. Each is still
    /// verified against the tracks when the replacement is planned.
    public static func replacementContainers(hasVideo: Bool) -> [String] {
        hasVideo ? ["mov", "mp4", "mkv", "webm"] : ["mov", "mka", "m4a", "wav", "mp4", "mkv", "webm"]
    }
    /// The refusal of a container outside the list above.
    public static func replacementContainerRefusal(hasVideo: Bool) -> CutError {
        CutError(code: "unsupported_container",
                 message: "Choose a supported replacement container: \(replacementContainers(hasVideo: hasVideo).joined(separator: ", ")).")
    }
    /// The refusal of video settings, or of an action outside the list above, for a sound-only conversion.
    public static var soundSettingsRefusal: CutError {
        CutError(code: "invalid_arguments",
                 message: "Audio conversion accepts --audio \(soundAudioActions.map(\.rawValue).joined(separator: ", ")). Video settings apply to movies.")
    }
    /// Containers of each sound-only conversion. The first is its default. These were checked against the muxers of the
    /// bundled helper and MPCut's own read-back: MPCut reads ALAC in CAF with priming and a shorter span, and ALAC in
    /// Matroska without its word length, so ALAC is written to M4A, MOV and MP4 only. Those read ALAC with more than two
    /// channels back without a layout, as MKA and MP4 do for FLAC, so there the conversion is planned for mono and stereo.
    public static func conversionContainers(_ action: ReencodeAudio) -> [String] {
        switch action {
        case .pcm: return ["wav", "caf", "mov"]
        case .aac: return ["m4a", "mp4", "mov"]
        case .mp3: return ["mp3"]
        case .alac: return ["m4a", "mov", "mp4"]
        case .flac: return ["flac", "mka", "mp4"]
        case .opus: return ["opus", "ogg", "webm", "mka"]
        default: return []
        }
    }
    /// The conversion that writes a source codec back in its own format.
    public static func sameFormat(for codec: String) -> ReencodeAudio? {
        switch codec {
        case "mp3": return .mp3
        case "aac": return .aac
        case "alac": return .alac
        case "flac": return .flac
        case "opus": return .opus
        default: return nil
        }
    }
    /// Movie re-encode cannot write PCM into MP4.
    public static func allows(audio: ReencodeAudio, inMovieContainer container: String) -> Bool {
        movieAudioActions.contains(audio) && reencodeRefusal(audio: audio, container: container, source: .movie) == nil
    }

    // MARK: Defaults

    /// The mode used when a request names none. The app's Settings can change it for movies.
    public static func defaultMode(for source: ExportSourceKind) -> ExportMode {
        source == .audio ? .copy : .smart
    }
    /// The default mode for a selection: the default above, written as the table writes it. A multicam single-type selection copies.
    public static func defaultMode(for source: ExportSourceKind, tracks: ExportTracks, preferred: ExportMode? = nil) -> ExportMode {
        let mode = preferred ?? defaultMode(for: source)
        let cell = cell(source: source, tracks: tracks, mode: mode)
        return cell.isAllowed || source != .multicam ? cell.resolvedMode : .copy
    }
    public static let defaultCodec = ReencodeCodec.h264
    public static func defaultQuality(_ codec: ReencodeCodec) -> ReencodeQuality { codec == .prores ? .prores422 : .balanced }
    /// The quality presets of each video codec.
    public static func qualities(_ codec: ReencodeCodec) -> [ReencodeQuality] {
        codec == .prores ? [.proresLT, .prores422, .proresHQ] : [.smallerFile, .balanced, .highQuality]
    }
    public static func defaultReencodeContainer(_ codec: ReencodeCodec) -> String { reencodeContainers(codec)[0] }

    // MARK: The matrix

    public static func cell(source: ExportSourceKind, tracks requested: ExportTracks, mode: ExportMode,
                            placements: ExportPlacementScope = .none) -> ExportCell {
        func make(_ tracks: ExportTracks, resolved: ExportMode, refusal: CutError? = nil, containers: [String]? = nil,
                  audio: [ReencodeAudio] = [], defaultAudio: ReencodeAudio? = nil, rungs: [ExportRung] = []) -> ExportCell {
            ExportCell(source: source, tracks: tracks, mode: mode, resolvedMode: resolved, refusal: refusal,
                       containers: containers, audioActions: audio, defaultAudio: defaultAudio,
                       rungs: rungs.sorted { $0.rank < $1.rank })
        }
        let soundRungs: [ExportRung] = [.copyOtherContainer, .copySampleAligned, .convertSameFormat, .convertPCM, .convertAAC]
        let conversionRungs: [ExportRung] = [.convertSameFormat, .convertPCM, .convertAAC]
        if source != .audio, placements != .none {
            if requested != .audio {
                let rungs: [ExportRung] = [.smartTrim, .reencode]
                let audioActions = source == .multicam ? [.auto] + stillMovieAudioActions : stillMovieAudioActions
                switch mode {
                case .copy:
                    return make(requested, resolved: .copy, refusal: CutError(code: "still_requires_generation",
                        message: "Visible stills need generated video samples. Choose Smart Trim or Re-encode.").because(.placementPicture),
                        rungs: rungs)
                case .smart:
                    return make(requested, resolved: .smart, containers: stillMovieContainers,
                                audio: requested == .video ? [] : audioActions,
                                defaultAudio: requested == .video ? nil : .copyOriginal, rungs: rungs)
                case .encode:
                    let movie = cell(source: source, tracks: .all, mode: .encode)
                    return make(requested, resolved: .encode,
                                containers: stillContainers(mode: mode, tracks: requested, codec: defaultCodec, audio: .copyOriginal),
                                audio: requested == .video ? [] : audioActions,
                                defaultAudio: requested == .video ? nil : .copyOriginal, rungs: movie.rungs)
                }
            }
            if placements == .insertion {
                if mode == .encode {
                    let audioActions: [ReencodeAudio] = source == .multicam ? [.auto] + stillSoundConversions : stillSoundConversions
                    return make(.audio, resolved: .encode, audio: audioActions, defaultAudio: .pcm, rungs: conversionRungs)
                }
                return make(.audio, resolved: .copy, refusal: CutError(code: "still_requires_generation",
                    message: "This selection includes inserted silence. Choose Convert Audio.").because(.placementSilence),
                    rungs: conversionRungs)
            }
        }
        switch source {
        case .audio:
            // A recording without picture has one selection. Asking for all of it means its sound.
            if requested == .video {
                return make(.video, resolved: .copy, refusal: CutError(code: "no_video", message: "The source has no video track."))
            }
            return mode == .encode
                ? make(.audio, resolved: .encode, audio: soundAudioActions, defaultAudio: .auto, rungs: conversionRungs)
                : make(.audio, resolved: .copy, rungs: soundRungs)
        case .movie:
            switch (requested, mode) {
            case (.all, .smart): return make(.all, resolved: .smart, rungs: [.copyOtherContainer, .smartTrim, .reencode])
            case (.all, .copy): return make(.all, resolved: .copy, rungs: [.copyOtherContainer, .smartTrim, .reencode])
            case (.all, .encode):
                // An audio treatment the container cannot carry offers the containers that can, then `auto`.
                return make(.all, resolved: .encode, containers: reencodeContainers(.h264), audio: movieAudioActions, defaultAudio: .auto,
                            rungs: [.reencode])
            case (.video, .encode):
                return make(.video, resolved: .copy, refusal: CutError(code: "invalid_arguments",
                                                                       message: "A video-only selection uses Lossless Copy."))
            case (.video, _): return make(.video, resolved: .copy, rungs: [.copyOtherContainer])
            case (.audio, .encode):
                return make(.audio, resolved: .encode, audio: soundAudioActions, defaultAudio: .auto, rungs: conversionRungs)
            case (.audio, _): return make(.audio, resolved: .copy, rungs: soundRungs)
            }
        case .multicam:
            switch (requested, mode) {
            case (.all, .encode):
                return make(.all, resolved: .encode, containers: multicamReencodeContainers(.h264), audio: multicamAudioActions,
                            defaultAudio: .copyOriginal, rungs: [.convertPCM, .convertAAC, .reencode])
            case (.all, .smart):
                return make(.all, resolved: .smart, containers: multicamContainers, audio: multicamAudioActions,
                            defaultAudio: .copyOriginal, rungs: [.copyOtherContainer, .smartTrim, .reencode])
            case (.all, .copy):
                return make(.all, resolved: .copy, containers: multicamContainers, audio: multicamAudioActions,
                            defaultAudio: .copyOriginal, rungs: [.copyOtherContainer, .smartTrim, .reencode])
            case (.audio, .copy):
                return make(.audio, resolved: .copy, audio: multicamAudioActions.filter { $0 != .removeAudio },
                            defaultAudio: .copyOriginal, rungs: [.copyOtherContainer])
            case (.video, .copy): return make(.video, resolved: .copy, rungs: [.copyOtherContainer])
            default:
                return make(requested, resolved: .copy, refusal: CutError(
                    code: "invalid_arguments",
                    message: "Multicam single-type track selection uses copy. Omit --mode or choose --mode copy."))
            }
        }
    }

    /// Every cell, in the order of the written matrix.
    public static var cells: [ExportCell] {
        ExportSourceKind.allCases.flatMap { source in
            ExportTracks.allCases.flatMap { tracks in
                [ExportMode.smart, .copy, .encode].map { cell(source: source, tracks: tracks, mode: $0) }
            }
        }
    }

    // MARK: Requests as CLI arguments

    /// The flags that request this export from `mpcut export`, without clips and output.
    public static func arguments(for request: ExportRequest, audioStream: Int? = nil) -> [String] {
        var flags = ["--mode", request.mode.rawValue]
        if request.tracks != .all { flags += ["--tracks", request.tracks.rawValue] }
        if let stream = audioStream ?? request.audioStream { flags += ["--audio-stream", String(stream)] }
        if request.mode == .encode {
            if request.tracks == .all, request.movieSettings {
                flags += ["--video", request.codec.rawValue]
                if let quality = request.quality { flags += ["--quality", quality.rawValue] }
            }
            flags += ["--audio", request.audio.rawValue]
        }
        if request.snap == .nearest { flags += ["--snap", "nearest"] }
        return flags
    }

    // MARK: Timeline tier

    /// One check of the timeline tier: a mode, the audio action of a sound-only conversion, and the rank it stands for.
    public struct TierStep: Sendable {
        public let rank: ExportRung.Rank
        public let mode: ExportMode
        public let audio: ReencodeAudio?
        public var tier: FidelityTier { ExportRules.tier(of: rank) }
    }

    /// The tier of a rank: nothing encoded is True Lossless, cut edges only or no added loss is Lossless, the rest is Re-encode.
    public static func tier(of rank: ExportRung.Rank) -> FidelityTier {
        if rank.encodedScope == 0 { return .trueLossless }
        return rank.encodedScope == 1 || rank.addedLoss == 0 ? .lossless : .reencode
    }

    /// The checks that decide a timeline's tier, best first. The tier is that of the first one that plans for the whole
    /// timeline with every track and exact cuts.
    public static func tierSteps(source: ExportSourceKind) -> [TierStep] {
        let copy = TierStep(rank: ExportRung.copyOtherContainer.rank, mode: .copy, audio: nil)
        switch source {
        case .audio:
            return [copy, TierStep(rank: ExportRung.convertPCM.rank, mode: .encode, audio: .pcm),
                    TierStep(rank: ExportRung.convertAAC.rank, mode: .encode, audio: .aac)]
        case .movie, .multicam:
            return [copy, TierStep(rank: ExportRung.smartTrim.rank, mode: .smart, audio: nil),
                    TierStep(rank: ExportRung.reencode.rank, mode: .encode, audio: .auto)]
        }
    }

    public static func displayName(tier: FidelityTier) -> String {
        switch tier {
        case .trueLossless: return "True Lossless"
        case .lossless: return "Lossless"
        case .reencode: return "Re-encode"
        }
    }
    /// The badge while the timeline is being checked, and when no mode writes it.
    public static let tierCheckingName = "Checking…"
    public static let tierUnavailableName = "Can’t Export"

    public static func summary(tier: FidelityTier, source: ExportSourceKind = .movie) -> String {
        switch tier {
        case .trueLossless: return "MPCut copies the original media without re-encoding it."
        case .lossless:
            return source == .audio ? "Export as PCM to keep the audio samples unchanged."
                : "Smart Trim re-encodes the video around cuts that need it and copies the rest."
        case .reencode:
            return source == .audio ? "This audio needs a lossy conversion to export." : "Exporting this timeline requires a full re-encode."
        }
    }

    /// The best mode a tier allows for a selection, as the table writes it.
    public static func bestMode(for tier: FidelityTier, source: ExportSourceKind, tracks: ExportTracks = .all) -> ExportMode {
        let mode = tierSteps(source: source).first { $0.tier == tier }?.mode ?? .encode
        let cell = cell(source: source, tracks: tracks, mode: mode)
        return cell.isAllowed ? cell.resolvedMode : .copy
    }

    /// The tier a mode asks of the timeline.
    public static func tier(of mode: ExportMode, source: ExportSourceKind) -> FidelityTier {
        tierSteps(source: source).first { $0.mode == mode }?.tier ?? .reencode
    }

    /// The mode an export opens on: the preferred one, unless the timeline's tier is lower, then the tier's mode.
    /// While the tier is unknown the preference stands.
    /// A recording without picture always opens on Lossless Copy. When its exact copy is unavailable that mode lists
    /// every working alternative of the ladder best first, so no conversion is opened ahead of a better one that works,
    /// such as `copy_sample_aligned`. The first one listed is what `--audio auto` applies.
    public static func openingMode(preferred: ExportMode, tier: FidelityTier?, source: ExportSourceKind) -> ExportMode {
        guard source != .audio else { return defaultMode(for: .audio) }
        guard let tier, tier < self.tier(of: preferred, source: source) else { return preferred }
        return bestMode(for: tier, source: source)
    }


    /// The flags that would raise a timeline to `tier`, when its cuts are moved to verified times.
    public static func raiseArguments(to tier: FidelityTier, source: ExportSourceKind) -> [String] {
        ["--mode", bestMode(for: tier, source: source).rawValue, "--snap", SnapMode.nearest.rawValue]
    }

    /// Which commands report `tier`, for command help and the written rules.
    public static var tierReportingHelp: String {
        "media inspect reads the cut index for a movie or sound-only source to report tier, including with --frames or --keyframes. A sidecar can supply the index. Selecting one track type or requesting --audio-packets omits tier. Project inspection reports the saved timeline tier. Export clips join, export project render, export ranges join, export ranges separate, scenes export and silence export also report it."
    }

    /// One paragraph for command help.
    public static var tierHelp: String {
        let names = FidelityTier.allCases.map { "\($0.rawValue) (\(displayName(tier: $0)), --mode \(bestMode(for: $0, source: .movie).rawValue))" }
        return "\(tierReportingHelp) The tier is the best mode that writes all the clips with every track and exact cuts. "
            + "Tiers, best first: \(names.joined(separator: ", ")). tier.factors lists what lowers it, each with a stable id that failures also carry as error.reason, "
            + "and tier.raise lists the arguments that would raise it. The tier never changes what a command writes."
    }

    // MARK: Messages

    /// The one wording of an export failure for people: where it happened, why, and verified times.
    /// `issue.segment` is a position in `clips`. `numbered` is the number the caller knows that clip by, when it differs.
    public static func describe(_ issue: CutError, clips: [ClipRequest], numbered: Int? = nil) -> String {
        var message = displayMessage(issue.message)
        if let index = issue.segment, index > 0, clips.indices.contains(index - 1) {
            let clip = clips[index - 1]
            let boundary = issue.boundary == "from" ? clip.from : issue.boundary == "to" ? clip.to : nil
            let location = boundary.map { " at \(seconds($0.seconds))" } ?? ""
            message = "Clip \(numbered ?? index) · \(clip.file.lastPathComponent)\(location)\n\(message)"
        }
        if let times = issue.nearest, !times.isEmpty {
            message += "\nVerified alternatives: " + times.map { seconds($0.seconds) }.joined(separator: ", ")
        }
        return message
    }

    /// The ordered alternatives for people: the label every front end shows, and how to request each one.
    public static func describe(alternatives: [ExportAlternative]) -> String {
        guard !alternatives.isEmpty else { return "" }
        return "\nAlternatives, least destructive first:" + alternatives.map {
            "\n  \($0.label): \($0.arguments.joined(separator: " ")), output .\($0.container)"
        }.joined()
    }

    public static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3...6)).locale(Locale(identifier: "en_US_POSIX"))) + " s"
    }

    /// A failure or factor message as people read it. The engines name the time of a cut by the exact rational they
    /// compared ("no verified video end boundary at 201/2"), and programs, sidecars and tests match those messages, so
    /// the messages stay as they are. This shows the same times the way `describe` shows every other time: in seconds.
    /// It rewrites the time that closes a sentence after "at", and the group, source and output ranges a multicam
    /// failure opens with. Anything else, such as a path, a frame rate or a track number, is left alone.
    public static func displayMessage(_ message: String) -> String {
        let text = message as NSString
        let whole = NSRange(location: 0, length: text.length)
        func shown(_ range: NSRange, unit: Bool = true) -> String? {
            guard let time = try? RationalTime(parsing: text.substring(with: range)) else { return nil }
            return unit ? seconds(time.seconds) : String(seconds(time.seconds).dropLast(2))
        }
        var changes: [(range: NSRange, text: String)] = []
        for match in displayCutTime.matches(in: message, range: whole) {
            if let time = shown(match.range(at: 1)) { changes.append((match.range(at: 1), time)) }
        }
        for match in displaySpan.matches(in: message, range: whole) {
            guard let from = shown(match.range(at: 1), unit: false), let to = shown(match.range(at: 2)) else { continue }
            changes.append((NSUnionRange(match.range(at: 1), match.range(at: 2)), "\(from)–\(to)"))
        }
        let result = NSMutableString(string: message)
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: change.range, with: change.text)
        }
        return result as String
    }
    private static let displayCutTime = try! NSRegularExpression(pattern: #" at (\d+(?:/\d+)?)(?=\.(?:\s|$)|$)"#)
    private static let displaySpan = try! NSRegularExpression(pattern: #"\b(?:group|source|output) (\d+(?:/\d+)?)–(\d+(?:/\d+)?)(?=[,:])"#)

    // MARK: Help and the written matrix

    /// Usage fragments for command help, so no command lists modes, tracks, codecs or actions by hand.
    public static func modeUsage(_ entry: ExportEntryPoint) -> String {
        "[--mode " + entry.modes.map(\.rawValue).joined(separator: "|") + "]"
    }
    public static var tracksUsage: String { "[--tracks " + ExportTracks.allCases.map(\.rawValue).joined(separator: "|") + "]" }
    public static var snapUsage: String { "[--snap " + SnapMode.allCases.map(\.rawValue).joined(separator: "|") + "]" }
    public static var encodeUsage: String { "[--video CODEC] [--quality PRESET] [--audio ACTION]" }
    /// The default and the presets of each encode setting.
    public static var encodeSettingsHelp: String {
        let presets = ReencodeCodec.allCases.map { codec in
            "\(codec.rawValue) uses " + qualities(codec).map { $0.rawValue + ($0 == defaultQuality(codec) ? " (default)" : "") }.joined(separator: ", ")
        }.joined(separator: ". ")
        return "Encoding settings require --mode \(ExportMode.encode.rawValue). CODEC is \(ReencodeCodec.allCases.map(\.rawValue).joined(separator: ", ")) and defaults to \(defaultCodec.rawValue). "
            + "For PRESET, \(presets). ACTION is one of \(ReencodeAudio.allCases.map(\.rawValue).joined(separator: ", ")) and defaults to \(ReencodeAudio.auto.rawValue). Encode requires exact boundaries."
    }
    /// How each command names its modes and what it does without one.
    public static func modeHelp(_ entry: ExportEntryPoint) -> String {
        let names = entry.modes.map { "\($0.rawValue) (\(displayName(mode: $0)))" }.joined(separator: ", ")
        let defaults = "Modes: \(names). The default is \(defaultMode(for: entry.source).rawValue) for picture with sound, as in the app."
        if entry.source == .multicam {
            return defaults + " Use copy mode for a single-type selection in an ordinary multicam program. The audio action controls whether sound is copied or rendered."
        }
        return defaults + " A single-type selection, or a source without picture, is written as \(displayName(mode: .copy))"
            + (entry.modes.contains(.encode) ? ", or converted with --mode \(ExportMode.encode.rawValue)." : ".")
    }
    /// The multicam part of command help.
    public static var multicamHelpSummary: String {
        func list(_ values: [String]) -> String { values.joined(separator: ", ") }
        return "A multicam program with picture and sound writes \(list(multicamContainers)). Video codecs for re-encoding are "
            + ReencodeCodec.allCases.map { "\($0.rawValue): \(list(multicamReencodeContainers($0)))" }.joined(separator: "; ")
            + ". Independently of picture mode, --audio-output accepts \(list(MulticamAudioOutput.allCases.map(\.rawValue))). "
            + "Separate tracks default to copy. A downmix renders one track. --audio accepts \(list(multicamAudioActions.map(\.rawValue))). "
            + "Explicit auto tries copy per lane for separate tracks and renders when copy is unavailable, in the lane's own compressed format where the container carries it. An unavailable export lists error.alternatives."
    }

    /// One paragraph for command help, derived from the matrix.
    public static var helpSummary: String {
        func list(_ actions: [ReencodeAudio]) -> String { actions.map(\.rawValue).joined(separator: ", ") }
        let conversions = soundConversions.map {
            "\($0.rawValue) (\(conversionContainers($0).map { "." + $0 }.joined(separator: ", ")))"
        }.joined(separator: ", ")
        let ladder = ExportRung.allCases.sorted { $0.rank < $1.rank }.map(\.rawValue).joined(separator: ", ")
        return "Export rules are shared by the app and the CLI and are listed in docs/EXPORT-RULES.md. "
            + "Movie re-encode audio accepts \(list(movieAudioActions)). H.264/HEVC write \(reencodeContainers(.h264).joined(separator: ", ")) and ProRes \(reencodeContainers(.prores).joined(separator: ", ")). "
            + "Sound-only encode (a source without picture, or --tracks audio) accepts \(list(soundAudioActions)): \(conversions). "
            + "auto copies when the copy is exact and otherwise applies the first working alternative. "
            + "In a movie re-encode, auto decides for each track it cannot copy and keeps the source's own format where the container and the FFmpeg helper allow: PCM at its sample format (MOV, MKV for mono and stereo), FLAC at its word length (MP4, MKV), ALAC at its word length (MOV, MP4), and AAC, MP3 (MOV, MP4, MKV) and Opus (MP4, MKV) at the source's rate. Otherwise a lossless track is written as PCM where the container carries it, and any other track as AAC, or for ProRes as PCM. Each converted movie track reports codec, bit_rate or bit_depth and a reason in audio_actions. "
            + "An unavailable export lists error.alternatives in this order: \(ladder). Each has an id, label, lossless flag and the arguments that request it. Nothing switches unless auto was asked for. "
            + tierHelp
    }

    public static func markdown() -> String {
        func code(_ values: [String]) -> String { values.isEmpty ? "—" : values.map { "`\($0)`" }.joined(separator: ", ") }
        var lines = ["# Export rules", "",
                     "<!-- Generated from Sources/MPCutCore/ExportRules.swift. Regenerate with MPCUT_WRITE_EXPORT_RULES=1 swift test --filter ExportRulesParityTests. -->", "",
                     "These rules apply to the app and the CLI alike. Both resolve every export through `ExportPlanner` in MPCutCore.", "",
                     "## Names", "", "| Concept | Identifier | Name |", "| --- | --- | --- |"]
        for mode in [ExportMode.smart, .copy, .encode] {
            let name = mode == .encode ? "Re-encode (movies), Convert Audio (sound only)" : displayName(mode: mode)
            lines.append("| Mode | `\(mode.rawValue)` | \(name) |")
        }
        for tracks in ExportTracks.allCases { lines.append("| Tracks | `\(tracks.rawValue)` | \(displayName(tracks: tracks)) |") }
        for audio in ReencodeAudio.allCases {
            lines.append("| Audio action | `\(audio.rawValue)` | \(displayName(audio: audio)). \(summary(audio: audio)) |")
        }
        for source in ExportSourceKind.allCases { lines.append("| Source kind | `\(source.rawValue)` | \(source.displayName) |") }
        lines += ["", "## Matrix", "",
                  "Containers marked *verified* are those the copy planner accepts for the source and its cuts.", "",
                  "| Source | Tracks | Mode | Written as | Containers | Audio actions | Default audio | If unavailable, offer |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        let requests = ExportSourceKind.allCases.flatMap { source in
            ExportTracks.allCases.flatMap { tracks in [ExportMode.smart, .copy, .encode].map { (source, tracks, $0) } }
        }
        for (source, tracks, mode) in requests {
            let cell = cell(source: source, tracks: tracks, mode: mode)
            let head = "| \(source.rawValue) | \(tracks.rawValue) | \(mode.rawValue) "
            if let refusal = cell.refusal {
                lines.append(head + "| refused: `\(refusal.code)` “\(refusal.message)” | — | — | — | — |")
            } else {
                let containers = cell.containers.map(code) ?? (cell.resolvedMode == .encode ? "by audio action" : "*verified*")
                lines.append(head + "| \(cell.displayName) | \(containers) | \(code(cell.audioActions.map(\.rawValue))) "
                    + "| \(cell.defaultAudio.map { "`\($0.rawValue)`" } ?? "—") | \(code(cell.rungs.map(\.rawValue))) |")
            }
        }
        lines += ["", "A source without picture has one selection, so `all` means `audio`. Smart Trim applies to picture, so a single-type selection is written as Lossless Copy.", "",
                  "The multicam rows describe picture mode and the available audio actions. The export inspector, queue and CLI resolve the requested picture and sound independently. A sound-only request uses the copy mode for track selection and can still render audio. The planner validates the program clock, the cut times reported in `nearest` and the source and output boundaries of every copied lane.", "",
                  "## Containers by setting", "", "| Setting | Containers (default first) |", "| --- | --- |"]
        for codec in ReencodeCodec.allCases {
            lines.append("| Re-encode, `\(codec.rawValue)` | \(code(reencodeContainers(codec))) |")
        }
        for action in soundConversions {
            lines.append("| Convert Audio, `\(action.rawValue)` | \(code(conversionContainers(action))) |")
        }
        lines.append("| Multicam program, picture and sound | \(code(multicamContainers)) |")
        for codec in ReencodeCodec.allCases {
            lines.append("| Multicam re-encode, `\(codec.rawValue)` | \(code(multicamReencodeContainers(codec))) |")
        }
        lines.append("| Multicam picture only, listed by the app | \(code(multicamListedContainers(tracks: .video, mode: .copy))) |")
        lines.append("| Multicam sound only, listed by the app | \(code(multicamListedContainers(tracks: .audio, mode: .copy))) |")
        lines.append("| Replace Source Audio, movie (after the source's own) | \(code(replacementContainers(hasVideo: true))) |")
        lines.append("| Replace Source Audio, recording without picture (after the source's own) | \(code(replacementContainers(hasVideo: false))) |")
        for source in [ExportSourceKind.movie, .multicam] {
            for action in [ReencodeAudio.pcm, .aac] {
                lines.append("| \(source.displayName) re-encode with `\(action.rawValue)` sound | \(code(reencodeContainers(for: action, source: source))) |")
            }
        }
        lines += ["", "An audio action its container cannot carry is refused with `unsupported_audio` and offers the containers that carry it, then `auto` for a movie. No front end substitutes another action. A multicam `m4v` is written as MP4. Multicam AAC needs a movie edit list for gapless timing, so it is not written into Matroska.", "",
                  "PCM bit depth is chosen by the engine that writes it. A sound-only conversion keeps the source depth (16, 24 or 32-bit, or 32-bit float). A movie re-encode keeps the depth of integer sources too, the longest among the clips of a track (16, 24 or 32-bit), and writes 32-bit float for float PCM and for decoded lossy sound, which can exceed full scale. A track of a mixed timeline that is resampled or mixed to stereo is written as 32-bit, or as 32-bit float under the same rule. A multicam re-encode writes 32-bit, or 32-bit float for a float source. A movie track made only of integer sources of up to 32 bits, neither resampled nor mixed, keeps every bit.", "",
                  "When `auto` cannot copy the sound of a movie re-encode exactly it decides for each track, and writes the track in its source's own codec and settings where the container and the FFmpeg helper allow. PCM stays PCM at its sample format in MOV, and in MKV for mono and stereo. FLAC stays FLAC at its word length in MP4 (mono and stereo) and MKV, and ALAC stays ALAC in MOV and MP4; MOV cannot carry FLAC, and ALAC in MKV is not read back exactly, so there they are written as PCM. AAC stays AAC, MP3 stays MP3 in MOV, MP4 (16 kHz and up) and MKV, and Opus stays Opus in MP4 and MKV, each at the source's rate: AAC at the first customary step not under the source's measured average, MP3 at the nearest constant rate, Opus at the source's measured average to the nearest 1 kbps. The built-in AAC encoder writes AAC-LC, so an HE-AAC source is written as AAC-LC and its reason says so. A track whose clips differ in format, a codec the helper cannot encode (AC-3, E-AC-3, Vorbis, TrueHD, MLP, DTS, WavPack) or a pair the container cannot carry falls back: a lossless track is written as PCM where the container carries it, and otherwise as AAC; any other track as AAC, or for ProRes as PCM under the same container limits. MP4 cannot carry PCM here, and MKV states no speaker positions for wider PCM, so there a lossless fallback is converted to AAC. Converted AAC from any other source gets 96 kbps for each channel, up to 512 kbps. `audio_actions` reports the codec of each converted track with its bit rate or bit depth and a reason naming the source format and, for a fallback, why. A multicam export uses `separate_tracks` by default, with one selectable track per lane in project order. Copy preserves source formats and refuses a lane that needs rendering. Explicit `auto` tries copy for each lane and may render the affected lanes or insert silence while retaining eligible PCM samples. A rendered lane whose every span has one compressed format keeps it where the container carries it (FLAC in MP4 and MKV, ALAC in MOV and MP4, AAC in MOV and MP4, MP3 in MOV and MP4, Opus in MP4 and MKV) and states why in `reason`. Other lanes and downmixes use the rendered codecs below. `downmix_mono` and `downmix_stereo` always render one track. For picture with sound, MOV renders PCM or AAC, MP4 and M4V render AAC, and MKV renders PCM. WebM offers audio copy. For sound-only output, WAV, WAVE and CAF render PCM, and M4A renders AAC.", "",
                  "## Defaults", "", "| Setting | Default |", "| --- | --- |"]
        for source in ExportSourceKind.allCases {
            lines.append("| Mode, \(source.displayName.lowercased()) | `\(defaultMode(for: source).rawValue)` |")
        }
        lines += ["| Tracks | `all` |", "| Snap | `exact` |", "| Video codec | `\(defaultCodec.rawValue)` |",
                  "| Quality | `\(defaultQuality(.h264).rawValue)`, ProRes `\(defaultQuality(.prores).rawValue)` |",
                  "| Audio action in encode | `auto` |", "",
                  "Every CLI command and the app's factory settings use the default above. The app's Settings can change the movie default mode for the app.", "",
                  "## Alternatives when an export is unavailable", "",
                  "Alternatives are checked in rank order and every one that works is reported, least destructive first. The rank compares, in order: how much is encoded (nothing, cut edges, the sound, picture and sound), whether the source format changes, whether an encoding generation is added, and the time to write. An alternative is offered, never applied, unless the request asked for `--audio auto`.", "",
                  "| Rank | Id | Encoded | Format | Added loss | What it does |", "| --- | --- | --- | --- | --- | --- |"]
        let scopes = ["nothing", "cut edges", "sound", "picture and sound"]
        for (index, rung) in ExportRung.allCases.sorted(by: { $0.rank < $1.rank }).enumerated() {
            let rank = rung.rank
            lines.append("| \(index + 1) | `\(rung.rawValue)` | \(scopes[rank.encodedScope]) | \(rank.formatChange == 0 ? "kept" : "changed") "
                + "| \(rank.addedLoss == 0 ? "none" : "one generation") | \(rung.summary) |")
        }
        lines += mixedMarkdown()
        lines += stillMarkdown()
        lines += ["", "## Timeline tier", "",
                  "The tier of a timeline is the best mode that plans for all of its clips with every track and exact cuts, over the containers the planner verifies. It is computed by running the planners in the order below, never by restating their rules, and it uses the same rank as the alternatives above. The app shows it as a badge and asks before an edit made by hand lowers it. For a multicam program the tier is found the same way from `MulticamEngine`, with picture and sound; the multicam editor shows the badge and asks after an edit made by hand lowers it, because the program is planned off the main thread and the tier of an edit arrives after it: it is compared with the tier of the program before the first of those edits, the question offers to move the switches and range edges that lower it to their nearest verified times when that keeps the tier, and Cancel undoes those edits. In the CLI, \(tierReportingHelp) The tier never changes what a request writes.", "",
                  "Adjacent clips that are contiguous in one source, a split that removes nothing, are planned as the single range they make, in every mode and container. Their seam is not a cut: it needs no verified boundary, nothing is encoded there, and the copy is the one the unsplit range gives. The seam becomes a cut when a piece is removed, moved or trimmed.", "",
                  "| Tier | Id | Movie mode | Sound-only mode | What is encoded |", "| --- | --- | --- | --- | --- |"]
        for tier in FidelityTier.allCases {
            let sound = tierSteps(source: .audio).first { $0.tier == tier }
            let soundMode = sound.map { "`\($0.mode.rawValue)`" + ($0.audio.map { " with `\($0.rawValue)`" } ?? "") } ?? "—"
            lines.append("| \(displayName(tier: tier)) | `\(tier.rawValue)` | `\(bestMode(for: tier, source: .movie).rawValue)` | \(soundMode) "
                + "| \(summary(tier: tier)) Sound only: \(summary(tier: tier, source: .audio)) |")
        }
        lines += ["", "The badge shows “\(tierCheckingName)” during indexing and “\(tierUnavailableName)” if none of the export modes work. "
                  + "The export sheet starts with your preferred mode when the timeline supports it. Otherwise, it selects the best available mode. Audio-only exports always open on Lossless Copy. If an exact copy isn’t possible, the sheet lists the available alternatives in order of preference. `--audio auto` uses the first one. "
                  + "Both checks try the preferred container first, then use the first compatible one. MPCut checks the hardware encoder when you export.", "",
                  "## Tier factors", "",
                  "Each factor explains why a higher-quality mode is unavailable. Errors include the factor ID in `reason`. An audio-only timeline can still qualify as Lossless when it can export as PCM without changing the decoded samples.", "",
                  "| Id | Scope | Leaves at best | Exact alternative | Meaning |", "| --- | --- | --- | --- | --- |"]
        for factor in TierFactorID.allCases {
            lines.append("| `\(factor.rawValue)` | \(factor.scope) | \(factor.effect.summary) | \(factor.offersNearest ? "verified times in `nearest`" : "—") | \(factor.summary) |")
        }
        lines += ["", "## Entry points", "", "| Entry point | Source | Modes | Reports alternatives | Named restrictions |", "| --- | --- | --- | --- | --- |"]
        for entry in ExportEntryPoint.allCases {
            lines.append("| \(entry.displayName) | \(entry.source.rawValue) | \(code(entry.modes.map(\.rawValue))) "
                + "| \(entry.offersAlternatives ? "yes" : "no") | \(entry.restrictions.joined(separator: "<br>")) |")
        }
        lines += ["", "## Refusals", "", "| Code | Meaning |", "| --- | --- |"]
        for (code, meaning) in refusals { lines.append("| `\(code)` | \(meaning) |") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Error codes of export planning, with their meaning.
    public static let refusals: [(String, String)] = [
        ("invalid_arguments", "The matrix refuses this combination of tracks, mode and settings."),
        ("unsafe_boundary", "A cut cannot be copied exactly. `nearest` lists verified times when there are any."),
        ("still_requires_generation", "Visible still picture or inserted silence requires generated samples."),
        ("camera_copy_required", "The requested settings encode retained camera picture. Review any verified placement adjustments in `stillBoundaryAdjustments`."),
        ("unsupported_container", "The container cannot carry the selected tracks or this conversion. The message names the valid extensions."),
        ("unsupported_tracks", "The source has tracks or timing that this mode cannot write."),
        ("unsupported_audio", "The audio action does not apply to this source, selection or container."),
        ("audio_copy_unavailable", "`--audio copy` was requested and the sound cannot be copied exactly."),
        ("uncovered_audio", "A copied multicam lane would require new silence samples. The error identifies the lane and output interval."),
        ("incompatible_clip", "The clips differ, so their packets cannot be joined. Re-encode writes a mixed timeline; see Mixed timelines for what no mode joins."),
        ("encoder_unavailable", "The FFmpeg helper lacks the encoder, or the hardware encoder did not start."),
        ("no_video", "A picture was requested from a source without one."),
        ("no_audio", "Sound was requested from a source without a matching track."),
        ("output_exists", "The destination exists. MPCut never overwrites."),
        ("invalid_output", "The destination is not a writable local file path matching the container.")
    ]
}

// MARK: - Requests and plans

/// One export request in the terms shared by every front end.
public struct ExportRequest: Sendable {
    public var clips: [ClipRequest]
    public var mode: ExportMode
    public var tracks: ExportTracks
    public var audioStream: Int?
    public var audioTrackOrdinal: Int?
    /// Nil uses the destination extension when present, otherwise the first container the rules allow.
    public var container: String?
    public var audio: ReencodeAudio
    public var codec: ReencodeCodec
    public var quality: ReencodeQuality?
    public var snap: SnapMode
    /// True when the request named a video codec or quality.
    public var movieSettings: Bool

    public init(clips: [ClipRequest], mode: ExportMode, tracks: ExportTracks = .all, audioStream: Int? = nil,
                audioTrackOrdinal: Int? = nil, container: String? = nil, audio: ReencodeAudio = .auto,
                codec: ReencodeCodec = ExportRules.defaultCodec, quality: ReencodeQuality? = nil,
                snap: SnapMode = .exact, movieSettings: Bool = false) {
        self.clips = clips
        self.mode = mode
        self.tracks = tracks
        self.audioStream = audioStream
        self.audioTrackOrdinal = audioTrackOrdinal
        self.container = container
        self.audio = audio
        self.codec = codec
        self.quality = quality
        self.snap = snap
        self.movieSettings = movieSettings
    }

    fileprivate func namingContainer(from output: URL?) -> Self {
        var request = self
        let pathExtension = output?.pathExtension.lowercased() ?? ""
        request.container = container?.lowercased() ?? (pathExtension.isEmpty ? nil : pathExtension)
        return request
    }
}

public enum ExportPlan: Sendable {
    case packets(ResolvedEdit, mode: ExportMode, tracks: ExportTracks)
    case conversion(ReencodePlan)
    case audio(AudioExportPlan)

    public var edit: ResolvedEdit {
        switch self {
        case .packets(let edit, _, _): return edit
        case .conversion(let plan): return plan.edit
        case .audio(let plan): return plan.edit
        }
    }
    public var mode: ExportMode {
        switch self {
        case .packets(_, let mode, _): return mode
        case .conversion: return .encode
        case .audio(let plan): return plan.mode
        }
    }
    public var warnings: [String] {
        switch self {
        case .packets: return []
        case .conversion(let plan): return plan.warnings
        case .audio(let plan): return plan.warnings
        }
    }
}

/// A working alternative, as reported to people and programs.
public struct ExportAlternative: Codable, Equatable, Sendable {
    public let id: String
    public let rung: ExportRung
    public let label: String
    public let mode: ExportMode
    public let tracks: ExportTracks
    public let container: String
    public let audio: ReencodeAudio?
    public let codec: String?
    public let bitRate: Int?
    public let quality: Int?
    public let lossless: Bool
    public let warnings: [String]
    /// The flags for `mpcut export`. Use an output with the `container` extension.
    public let arguments: [String]
    /// Present when the alternative moves cuts: the clips to request, in playback order.
    public let clips: [Clip]?

    public struct Clip: Codable, Equatable, Sendable {
        public let file: String
        public let from: String
        public let to: String
    }
}

extension ExportAlternative {
    /// The alternative with its clips listed, for a command whose clips are not the ones `mpcut export` would be given:
    /// the ranges of a batch, retained ranges or scenes.
    public func listing(_ requested: [ClipRequest]) -> ExportAlternative {
        ExportAlternative(id: id, rung: rung, label: label, mode: mode, tracks: tracks, container: container, audio: audio,
                          codec: codec, bitRate: bitRate, quality: quality, lossless: lossless, warnings: warnings,
                          arguments: arguments, clips: requested.map {
                              .init(file: $0.file.path, from: ($0.from ?? .zero).description, to: $0.to?.description ?? "")
                          })
    }
}

public struct ExportOffer: Sendable {
    public let alternative: ExportAlternative
    public let request: ExportRequest
    public let plan: ExportPlan
}

public enum ExportResolution: Sendable {
    /// `request` is what was planned. It differs from the input when `auto` applied an alternative.
    case ready(ExportPlan, request: ExportRequest, applied: ExportAlternative?)
    case unavailable(CutError, offers: [ExportOffer])
}

/// Resolves every export request: the plan, or the failure with the ordered alternatives that work.
public struct ExportPlanner: Sendable {
    private let cancelled: (@Sendable () -> Bool)?
    private let useSidecar: Bool

    public init(cancelled: (@Sendable () -> Bool)? = nil, useSidecar: Bool = true) {
        self.cancelled = cancelled
        self.useSidecar = useSidecar
    }

    /// Codes that describe the request or destination, for which no other export helps.
    private static let terminal: Set<String> = ["cancelled", "source_changed", "output_exists", "invalid_output", "invalid_arguments",
                                             "empty_edit", "invalid_range", "invalid_time", "no_video", "no_audio", "probe_failed"]

    public func resolve(_ request: ExportRequest, output: URL? = nil, media: [URL: MediaInfo] = [:]) -> ExportResolution {
        var boundaries = CutEngine.BoundaryCache()
        return resolve(request, output: output, media: media, boundaries: &boundaries)
    }

    /// A batch shares one boundary cache between the requests it resolves from the same recordings.
    func resolve(_ request: ExportRequest, output: URL? = nil, media: [URL: MediaInfo] = [:],
                 boundaries: inout CutEngine.BoundaryCache) -> ExportResolution {
        let request = request.namingContainer(from: output)
        if let container = request.container, let pathExtension = output?.pathExtension.lowercased(),
           !pathExtension.isEmpty, container != pathExtension {
            return .unavailable(CutError(code: "unsupported_container", message: "The container must match the destination extension."),
                                offers: [])
        }
        var indexed = media
        do {
            let source = try self.source(of: request, media: &indexed)
            let cell = ExportRules.cell(source: source.kind, tracks: request.tracks, mode: request.mode)
            if let refusal = cell.refusal { throw refusal }
            if cell.soundOnly, cell.resolvedMode == .encode, request.movieSettings || !cell.audioActions.contains(request.audio) {
                throw ExportRules.soundSettingsRefusal
            }
            if cell.soundOnly, cell.resolvedMode == .encode, let output, output.pathExtension.isEmpty {
                throw ExportRules.soundExtensionRefusal
            }
            // Auto for sound asks for the exact copy first. Its alternatives are the ones a copy request reports.
            let automatic = cell.soundOnly && cell.resolvedMode == .encode && request.audio == .auto
            var attempt = request
            if automatic { attempt.mode = .copy }
            do {
                // A re-encode container that cannot carry the audio action is refused here, for every front end.
                // A source without sound has no audio action to refuse.
                if cell.resolvedMode == .encode, !cell.soundOnly, source.media.streams.contains(where: { $0.kind == "audio" }),
                   let refusal = ExportRules.reencodeRefusal(audio: request.audio, container: request.container
                                                               ?? ExportRules.defaultReencodeContainer(request.codec), source: source.kind) {
                    throw refusal
                }
                return .ready(try plan(attempt, cell: automatic ? ExportRules.cell(source: source.kind, tracks: request.tracks, mode: .copy) : cell,
                                       output: output, media: indexed, boundaries: &boundaries), request: attempt, applied: nil)
            } catch let issue as CutError {
                guard !Self.terminal.contains(issue.code) else { return .unavailable(issue, offers: []) }
                let offers = self.offers(after: attempt, source: source.media, kind: source.kind, output: output, media: indexed)
                if cancelled?() == true {
                    throw CutError(code: "cancelled", message: "Operation cancelled.")
                }
                if automatic {
                    // A named container is the caller's choice of file. Apply the first alternative that fits it.
                    if let chosen = offers.first(where: { request.container == nil || $0.alternative.container == request.container }) {
                        return .ready(chosen.plan, request: chosen.request, applied: chosen.alternative)
                    }
                    if let container = request.container, !offers.isEmpty {
                        let valid = offers.map { "." + $0.alternative.container }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        let refusal = CutError(code: "unsupported_container",
                                               message: "Exact audio copy is unavailable. \(issue.message) No alternative writes .\(container). Use \(valid.joined(separator: ", ")).",
                                               segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
                            .because(issue.reason)
                        return .unavailable(refusal, offers: offers)
                    }
                }
                return .unavailable(issue, offers: offers)
            }
        } catch let issue as CutError {
            return .unavailable(issue, offers: [])
        } catch {
            return .unavailable(CutError(code: "export_failed", message: error.localizedDescription), offers: [])
        }
    }

    public func write(_ plan: ExportPlan, to output: URL, progress: (@Sendable (Double) -> Bool)? = nil) throws {
        switch plan {
        case .packets(let edit, let mode, let tracks):
            try CutEngine(cancelled: cancelled, smartTrim: mode == .smart, useSidecar: useSidecar, tracks: tracks,
                          audioStream: edit.audioStream).export(edit, to: output, progress: progress)
        case .conversion(let conversion):
            if progress?(0) == false { throw CutError(code: "cancelled", message: "Operation cancelled.") }
            let stopped = OSAllocatedUnfairLock(initialState: false)
            try ReencodeEngine(cancelled: { cancelled?() == true || stopped.withLock { $0 } }).write(conversion, to: output) { fraction in
                if progress?(fraction) == false { stopped.withLock { $0 = true } }
            }
        case .audio(let audio):
            try AudioExportEngine(cancelled: cancelled, useSidecar: useSidecar).write(audio, to: output, progress: progress)
        }
    }

    // MARK: Planning one request

    private func source(of request: ExportRequest, media: inout [URL: MediaInfo]) throws -> (media: MediaInfo, kind: ExportSourceKind) {
        guard let first = request.clips.first else {
            throw CutError(code: "empty_edit", message: "Add at least one clip before exporting.")
        }
        let file = first.file.standardizedFileURL
        let info = try media[file] ?? media[first.file]
            ?? CutEngine(cancelled: cancelled, useSidecar: useSidecar).inspectSummary(file)
        return (info, info.hasVideo ? .movie : .audio)
    }

    private func plan(_ request: ExportRequest, cell: ExportCell, output: URL?, media: [URL: MediaInfo]) throws -> ExportPlan {
        var boundaries = CutEngine.BoundaryCache()
        return try plan(request, cell: cell, output: output, media: media, boundaries: &boundaries)
    }

    private func plan(_ request: ExportRequest, cell: ExportCell, output: URL?, media: [URL: MediaInfo],
                      boundaries: inout CutEngine.BoundaryCache) throws -> ExportPlan {
        try AnalysisSidecar.$readsEnabled.withValue(useSidecar && AnalysisSidecar.readsEnabled) {
            switch cell.resolvedMode {
            case .encode where cell.soundOnly:
                let converter = AudioExportEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: cell.tracks,
                                                  audioStream: request.audioStream, audioTrackOrdinal: request.audioTrackOrdinal)
                return .audio(try converter.resolve(request.clips, output: output, media: media,
                                                    container: request.container, audio: request.audio))
            case .encode:
                let container = request.container ?? ExportRules.defaultReencodeContainer(request.codec)
                let settings = ReencodeSettings(codec: request.codec, quality: request.quality, audio: request.audio)
                return .conversion(try ReencodeEngine(cancelled: cancelled)
                    .resolve(request.clips, output: output, media: media, container: container, settings: settings,
                             carryingChapters: true))
            case .copy, .smart:
                let engine = CutEngine(cancelled: cancelled, smartTrim: cell.resolvedMode == .smart, useSidecar: useSidecar,
                                       tracks: request.tracks, audioStream: request.audioStream,
                                       audioTrackOrdinal: request.audioTrackOrdinal)
                let edit = try engine.resolve(request.clips, output: output, snap: request.snap, media: media,
                                              container: request.container, boundaries: &boundaries)
                return .packets(edit, mode: cell.resolvedMode, tracks: request.tracks)
            }
        }
    }

    // MARK: The timeline tier's question

    /// Whether one mode plans for these clips: the request's cell and refusals, then the planner of that mode, sharing
    /// `boundaries`. No ladder, and no helper process: a movie re-encode is checked up to the hardware encoder.
    func verdict(_ request: ExportRequest, media: [URL: MediaInfo],
                 boundaries: inout CutEngine.BoundaryCache) throws -> (container: String, warnings: [String], edit: ResolvedEdit?) {
        var indexed = media
        let source = try self.source(of: request, media: &indexed)
        let cell = ExportRules.cell(source: source.kind, tracks: request.tracks, mode: request.mode)
        if let refusal = cell.refusal { throw refusal }
        return try AnalysisSidecar.$readsEnabled.withValue(useSidecar && AnalysisSidecar.readsEnabled) {
            switch cell.resolvedMode {
            case .encode where cell.soundOnly:
                let plan = try self.plan(request, cell: cell, output: nil, media: indexed, boundaries: &boundaries)
                return (plan.edit.container, plan.warnings, nil)
            case .encode:
                let container = request.container ?? ExportRules.defaultReencodeContainer(request.codec)
                if source.media.streams.contains(where: { $0.kind == "audio" }),
                   let refusal = ExportRules.reencodeRefusal(audio: request.audio, container: container, source: source.kind) {
                    throw refusal
                }
                let settings = ReencodeSettings(codec: request.codec, quality: request.quality, audio: request.audio)
                return (container, try ReencodeEngine(cancelled: cancelled)
                    .staticWarnings(request.clips, media: indexed, container: container, settings: settings), nil)
            case .copy, .smart:
                let plan = try self.plan(request, cell: cell, output: nil, media: indexed, boundaries: &boundaries)
                return (plan.edit.container, plan.warnings, plan.edit)
            }
        }
    }

    /// The one container choice rule of the timeline tier and of the export sheet's opening state: the preferred
    /// container when the request plans in it, otherwise the first container the planner verifies.
    /// A re-encode names its container by its settings, so the rule applies to packet copies and Smart Trim.
    func verdict(_ request: ExportRequest, preferring preferred: String?, media: [URL: MediaInfo],
                 boundaries: inout CutEngine.BoundaryCache) throws -> (container: String, warnings: [String], edit: ResolvedEdit?) {
        guard let preferred, request.container == nil, request.mode != .encode else {
            return try verdict(request, media: media, boundaries: &boundaries)
        }
        var named = request
        named.container = preferred
        do {
            return try verdict(named, media: media, boundaries: &boundaries)
        } catch let issue as CutError where issue.code == "cancelled" || issue.code == "source_changed" {
            throw issue
        } catch {
            return try verdict(request, media: media, boundaries: &boundaries)
        }
    }

    /// The container an export of `request` opens on, by the rule above. Nil when the request plans in no container,
    /// or is a re-encode.
    public func openingContainer(for request: ExportRequest, preferred: String?, media: [URL: MediaInfo] = [:]) -> String? {
        guard request.mode != .encode else { return nil }
        var open = request
        open.container = nil
        var boundaries = CutEngine.BoundaryCache()
        return try? verdict(open, preferring: preferred, media: media, boundaries: &boundaries).container
    }

    // MARK: The ladder

    /// Every alternative of the cell that works for this request, in rank order.
    public func offers(after request: ExportRequest, source: MediaInfo, kind: ExportSourceKind, output: URL? = nil,
                       media: [URL: MediaInfo]) -> [ExportOffer] {
        let request = request.namingContainer(from: output)
        let cell = ExportRules.cell(source: kind, tracks: request.tracks, mode: request.mode)
        guard cell.isAllowed else { return [] }
        let sound = source.streams.filter { $0.kind == "audio" }
        let selected: StreamInfo? = request.audioStream.flatMap { index in sound.first { $0.index == index } }
            ?? request.audioTrackOrdinal.flatMap { sound.indices.contains($0) ? sound[$0] : nil }
            ?? (sound.count == 1 ? sound.first : nil)
        let stream = request.audioStream ?? request.audioTrackOrdinal.flatMap { sound.indices.contains($0) ? sound[$0].index : nil }
        let native = selected.flatMap { ExportRules.sameFormat(for: $0.codec) }
        let own = source.url.pathExtension.lowercased()

        var candidates: [(ExportRung, ExportRequest)] = []
        for rung in cell.rungs {
            if cancelled?() == true { return [] }
            var next = request
            next.snap = .exact
            switch rung {
            case .copyOtherContainer:
                next.mode = .copy
                let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: cell.tracks,
                                       audioStream: request.audioStream, audioTrackOrdinal: request.audioTrackOrdinal)
                for container in engine.suggestedContainers(for: source, clips: request.clips) where container != request.container {
                    next.container = container
                    candidates.append((rung, next))
                }
            case .copySampleAligned:
                // The conversion planner places every cut on the source sample clock.
                let converter = AudioExportEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: cell.tracks,
                                                  audioStream: request.audioStream, audioTrackOrdinal: request.audioTrackOrdinal)
                guard request.clips.allSatisfy({ $0.from != nil && $0.to != nil }),
                      let aligned = try? converter.resolve(request.clips, media: media, container: "wav", audio: .pcm),
                      aligned.edit.segments.count == request.clips.count else { continue }
                let moved = zip(request.clips, aligned.edit.segments).map { ClipRequest(file: $0.file, from: $1.from, to: $1.to) }
                guard zip(request.clips, moved).contains(where: { $0.from != $1.from || $0.to != $1.to }) else { continue }
                next.clips = moved
                candidates.append((rung, next))
            case .smartTrim:
                next.mode = .smart
                if request.mode == .copy {
                    candidates.append((rung, next))
                }
                if request.container != nil {
                    let engine = CutEngine(cancelled: cancelled, smartTrim: true, useSidecar: useSidecar, tracks: cell.tracks,
                                           audioStream: request.audioStream, audioTrackOrdinal: request.audioTrackOrdinal)
                    for container in engine.suggestedContainers(for: source, clips: request.clips) where container != request.container {
                        next.container = container
                        candidates.append((rung, next))
                    }
                }
            case .convertSameFormat, .convertPCM, .convertAAC:
                guard let action = rung == .convertSameFormat ? native : rung == .convertPCM ? .pcm : .aac else { continue }
                // The same-format rung already covers AAC for an AAC source.
                if rung == .convertAAC, native == .aac { continue }
                let containers = ExportRules.conversionContainers(action)
                next.mode = .encode
                next.audio = action
                // The source format stays in the named container when it writes there, then in the source's own.
                let kept = [request.container, own].compactMap { $0 }.first(where: containers.contains)
                next.container = rung == .convertSameFormat ? kept ?? containers[0] : containers[0]
                if !(request.mode == .encode && request.audio == action) { candidates.append((rung, next)) }
                // A lossless source named into a container that cannot hold its own codec keeps its samples there: as PCM,
                // ALAC or FLAC, the first that container holds. Only an offer that plans losslessly is kept below.
                let holdsNative = native.map { ExportRules.conversionContainers($0).contains(request.container ?? "") } ?? false
                if rung == .convertPCM, !holdsNative, let named = request.container, named != containers[0],
                   let codec = selected?.codec, ExportRules.isLosslessAudio(codec: codec),
                   let target = ([.pcm, .alac, .flac] as [ReencodeAudio]).first(where: { ExportRules.conversionContainers($0).contains(named) }),
                   !(request.mode == .encode && request.audio == target) {
                    next.audio = target
                    next.container = named
                    candidates.append((rung, next))
                }
            case .reencode where request.mode == .encode:
                // Keep the audio action in the containers that carry it, then offer `auto` where the request was made.
                let here = request.container ?? ExportRules.defaultReencodeContainer(request.codec)
                for container in ExportRules.reencodeContainers(for: request.audio, source: kind, codec: request.codec) where container != here {
                    next.container = container
                    candidates.append((rung, next))
                }
                if request.audio != .auto, ExportRules.reencodeContainers(request.codec).contains(here) {
                    next.container = here
                    next.audio = .auto
                    candidates.append((rung, next))
                }
            case .reencode:
                next.mode = .encode
                next.audio = .auto
                let containers = ExportRules.reencodeContainers(request.codec)
                next.container = request.container.flatMap { containers.contains($0) ? $0 : nil } ?? containers[0]
                candidates.append((rung, next))
            }
        }

        var offers: [ExportOffer] = []
        for (rung, candidate) in candidates {
            if cancelled?() == true { return offers }
            if rung == .smartTrim, candidate.container != request.container,
               offers.contains(where: { ($0.alternative.rung == .smartTrim && $0.request.container == request.container)
                   || ($0.alternative.mode == .copy && $0.alternative.container == candidate.container) }) { continue }
            let target = ExportRules.cell(source: kind, tracks: candidate.tracks, mode: candidate.mode)
            // The destination is named for the original request. Each alternative is planned on its own.
            guard target.isAllowed, let plan = try? self.plan(candidate, cell: target, output: nil, media: media) else { continue }
            let container = plan.edit.container
            var action: ReencodeAudioAction?
            var lossless = rung.rank.encodedScope == 0
            if case .audio(let audio) = plan {
                action = audio.actions.first
                lossless = audio.isLossless
            }
            // The lossless conversion into a named container other than WAV is offered only when it keeps every sample.
            let losslessInNamed = rung == .convertPCM && kind != .multicam && container != ExportRules.conversionContainers(.pcm)[0]
            if losslessInNamed && !lossless { continue }
            let changed = zip(candidate.clips, request.clips).contains { $0.from != $1.from || $0.to != $1.to }
            let warnings = plan.warnings + (rung == .copySampleAligned ? ["Cuts were placed on the nearest audio sample."] : [])
            // A re-encode offered for a re-encode names its container and audio action.
            let variant = rung == .reencode && request.mode == .encode
            let named = variant && candidate.audio == request.audio
            let smartOtherContainer = rung == .smartTrim && candidate.container != request.container
            let label = rung.label(container: container, audio: variant ? candidate.audio : action?.action, lossless: lossless)
            let alternative = ExportAlternative(
                id: rung == .copyOtherContainer || named || smartOtherContainer || losslessInNamed ? "\(rung.rawValue):\(container)" : rung.rawValue, rung: rung,
                label: smartOtherContainer ? "\(label) in \(ExportRules.containerDisplayName(container))" : label,
                mode: plan.mode, tracks: candidate.tracks, container: container, audio: variant ? candidate.audio : action?.action,
                codec: action?.codec, bitRate: action?.bitRate, quality: action?.quality, lossless: lossless,
                warnings: warnings, arguments: ExportRules.arguments(for: candidate, audioStream: stream),
                clips: changed ? candidate.clips.map {
                    .init(file: $0.file.path, from: ($0.from ?? .zero).description, to: $0.to?.description ?? "")
                } : nil)
            offers.append(ExportOffer(alternative: alternative, request: candidate, plan: plan))
        }
        return offers
    }
}
