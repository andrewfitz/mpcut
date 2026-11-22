import Foundation

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
    case copyOtherContainer, copySampleAligned, smartTrim, convertSameFormat, convertPCM, convertAAC, reencode

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
        case .copyOtherContainer: return "Copy the same packets into another container that can carry these cuts."
        case .copySampleAligned: return "Copy with each cut moved to the nearest audio sample, less than one sample away."
        case .smartTrim: return "Copy complete sections and encode only the video at the cut edges."
        case .convertSameFormat: return "Decode the kept ranges and encode them once in the source codec (MP3, AAC or FLAC) with the source parameters."
        case .convertPCM: return "Decode the kept ranges to PCM in WAV. No further quality loss, and a much larger file."
        case .convertAAC: return "Decode the kept ranges and encode AAC in M4A."
        case .reencode: return "Encode the whole timeline with the hardware video encoder."
        }
    }

    /// The label of one offer. `container` and `audio` describe the offered export.
    public func label(container: String, audio: ReencodeAudio?, lossless: Bool) -> String {
        switch self {
        case .copyOtherContainer: return "Copy to \(ExportRules.containerDisplayName(container)) (lossless)"
        case .copySampleAligned: return "Copy with cuts on the nearest audio sample (lossless)"
        case .smartTrim: return "Use Smart Trim (encodes only the cut edges)"
        case .convertSameFormat:
            let name = audio.map(ExportRules.displayName(audio:)) ?? "the source format"
            return "Convert to \(name) (same format\(lossless ? ", lossless" : ""))"
        case .convertPCM: return "Convert to WAV (no further quality loss)"
        case .convertAAC: return "Convert to AAC (.m4a, smaller)"
        case .reencode: return "Choose Re-encode"
        }
    }
}

/// Where an export request comes from. Restrictions are stated once, here.
public enum ExportEntryPoint: String, CaseIterable, Codable, Sendable {
    case sheet, queue, multicamSheet, multicamQueue, replacement
    case cliExport, cliBulk, cliRearrange, cliSilence, cliScenes, cliProject

    public var displayName: String {
        switch self {
        case .sheet: return "App: Export sheet"
        case .queue: return "App: Export Queue"
        case .multicamSheet: return "App: multicam Export inspector"
        case .multicamQueue: return "App: multicam Export Queue"
        case .replacement: return "App and CLI: Replace Source Audio"
        case .cliExport: return "CLI: export"
        case .cliBulk: return "CLI: bulk"
        case .cliRearrange: return "CLI: rearrange"
        case .cliSilence: return "CLI: silence --output"
        case .cliScenes: return "CLI: scenes --export-to"
        case .cliProject: return "CLI: export --project (multicam)"
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

    /// True when an unavailable export reports the ordered alternatives of the ladder.
    public var offersAlternatives: Bool {
        switch self {
        case .sheet, .cliExport, .cliRearrange, .cliBulk: return true
        default: return false
        }
    }

    /// Named restrictions with their reason.
    public var restrictions: [String] {
        switch self {
        case .sheet:
            return ["noAutoAudioConversion: Convert Audio names a format, so the sheet always shows what it will write. The offer button is what `--audio auto` applies."]
        case .queue:
            return ["copyOnlySound: sound-only queues use Lossless Copy. Convert the ranges with the Export sheet or `bulk --mode encode`.",
                    "noAlternatives: a failed range reports its error without the ladder."]
        case .multicamSheet, .multicamQueue, .cliProject:
            return ["multicamConversion: Re-encode converts program sound to AAC or PCM only.",
                    "singleTypeCopy: picture-only and sound-only selections use Lossless Copy.",
                    "noAlternatives: an unavailable export reports verified switch times instead of the ladder."]
        case .replacement:
            return ["copyOnly: a replaced soundtrack is copied with both track types."]
        case .cliExport:
            return ["namedOutput: `--audio auto` applies the first alternative that fits the extension of `--output`.",
                    "defaultCopy: without `--mode`, export copies, or uses Smart Trim when `--order` is given. The app starts from Smart Trim. Existing scripts depend on this default, so it is kept until a change is approved."]
        case .cliBulk:
            return ["namedOutput: `--audio auto` applies the first alternative that fits `container` when one is given."]
        case .cliRearrange:
            return ["noEncode: use export for --mode encode.", "nearestByDefault: video cuts snap to the nearest boundary."]
        case .cliSilence:
            return ["noEncode: retained ranges are written with Smart Trim or Lossless Copy.",
                    "noAlternatives: an unavailable export reports its error without the ladder."]
        case .cliScenes:
            return ["smartOnly: every scene is written with Smart Trim.",
                    "noAlternatives: an unavailable export reports its error without the ladder."]
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
    var soundOnly: Bool { source == .audio || (tracks == .audio && source != .multicam) }
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
        case .pcm: return "PCM"
        case .removeAudio: return "Remove Audio"
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        }
    }

    public static func summary(audio: ReencodeAudio) -> String {
        switch audio {
        case .auto: return "Copy when the copy is exact, otherwise the first alternative that works."
        case .copyOriginal: return "Copy the source packets, or fail."
        case .aac: return "Encode AAC."
        case .pcm: return "Write PCM."
        case .removeAudio: return "Write no sound."
        case .mp3: return "Encode MP3 with LAME."
        case .flac: return "Encode FLAC, which is lossless."
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
        default: return container.uppercased()
        }
    }

    // MARK: Static capability

    /// Containers of a movie re-encode for each video codec.
    public static func reencodeContainers(_ codec: ReencodeCodec) -> [String] {
        codec == .prores ? ["mov", "mkv"] : ["mp4", "mov", "mkv"]
    }
    public static let multicamContainers = ["mov", "mp4", "m4v", "mkv", "webm"]
    /// Audio treatments of a movie or multicam re-encode.
    public static let movieAudioActions: [ReencodeAudio] = [.auto, .copyOriginal, .aac, .pcm, .removeAudio]
    /// Audio treatments of a sound-only conversion.
    public static let soundAudioActions: [ReencodeAudio] = [.auto, .copyOriginal, .pcm, .flac, .aac, .mp3]
    /// Containers of each sound-only conversion. The first is its default.
    public static func conversionContainers(_ action: ReencodeAudio) -> [String] {
        switch action {
        case .pcm: return ["wav", "caf", "mov"]
        case .aac: return ["m4a", "mp4", "mov"]
        case .mp3: return ["mp3"]
        case .flac: return ["flac"]
        default: return []
        }
    }
    /// The conversion that writes a source codec back in its own format.
    public static func sameFormat(for codec: String) -> ReencodeAudio? {
        switch codec {
        case "mp3": return .mp3
        case "aac": return .aac
        case "flac": return .flac
        default: return nil
        }
    }
    /// Movie re-encode cannot write PCM into MP4.
    public static func allows(audio: ReencodeAudio, inMovieContainer container: String) -> Bool {
        !(audio == .pcm && container == "mp4")
    }

    // MARK: Defaults

    /// The mode used when a request names none. The app's Settings can change it for movies.
    public static func defaultMode(for source: ExportSourceKind) -> ExportMode {
        source == .audio ? .copy : .smart
    }
    public static let defaultCodec = ReencodeCodec.h264
    public static func defaultQuality(_ codec: ReencodeCodec) -> ReencodeQuality { codec == .prores ? .prores422 : .balanced }
    public static func defaultReencodeContainer(_ codec: ReencodeCodec) -> String { reencodeContainers(codec)[0] }

    // MARK: The matrix

    public static func cell(source: ExportSourceKind, tracks requested: ExportTracks, mode: ExportMode) -> ExportCell {
        func make(_ tracks: ExportTracks, resolved: ExportMode, refusal: CutError? = nil, containers: [String]? = nil,
                  audio: [ReencodeAudio] = [], defaultAudio: ReencodeAudio? = nil, rungs: [ExportRung] = []) -> ExportCell {
            ExportCell(source: source, tracks: tracks, mode: mode, resolvedMode: resolved, refusal: refusal,
                       containers: containers, audioActions: audio, defaultAudio: defaultAudio,
                       rungs: rungs.sorted { $0.rank < $1.rank })
        }
        let soundRungs: [ExportRung] = [.copyOtherContainer, .copySampleAligned, .convertSameFormat, .convertPCM, .convertAAC]
        let conversionRungs: [ExportRung] = [.convertSameFormat, .convertPCM, .convertAAC]
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
            case (.all, .smart): return make(.all, resolved: .smart, rungs: [.reencode])
            case (.all, .copy): return make(.all, resolved: .copy, rungs: [.copyOtherContainer, .smartTrim, .reencode])
            case (.all, .encode):
                return make(.all, resolved: .encode, containers: reencodeContainers(.h264), audio: movieAudioActions, defaultAudio: .auto)
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
                return make(.all, resolved: .encode, containers: multicamContainers, audio: movieAudioActions, defaultAudio: .auto)
            case (.all, _): return make(.all, resolved: mode, containers: multicamContainers)
            case (_, .copy): return make(requested, resolved: .copy, containers: multicamContainers)
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

    // MARK: Messages

    /// The one wording of an export failure for people: where it happened, why, and verified times.
    public static func describe(_ issue: CutError, clips: [ClipRequest]) -> String {
        var message = issue.message
        if let index = issue.segment, clips.indices.contains(index - 1) {
            let clip = clips[index - 1]
            let boundary = issue.boundary == "from" ? clip.from : issue.boundary == "to" ? clip.to : nil
            let location = boundary.map { " at \(seconds($0.seconds))" } ?? ""
            message = "Clip \(index) · \(clip.file.lastPathComponent)\(location)\n\(message)"
        }
        if let times = issue.nearest, !times.isEmpty {
            message += "\nVerified alternatives: " + times.map { seconds($0.seconds) }.joined(separator: ", ")
        }
        return message
    }

    public static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3...6)).locale(Locale(identifier: "en_US_POSIX"))) + " s"
    }

    // MARK: Help and the written matrix

    /// One paragraph for command help, derived from the matrix.
    public static var helpSummary: String {
        func list(_ actions: [ReencodeAudio]) -> String { actions.map(\.rawValue).joined(separator: ", ") }
        let conversions = [ReencodeAudio.pcm, .aac, .mp3, .flac].map {
            "\($0.rawValue) (\(conversionContainers($0).map { "." + $0 }.joined(separator: ", ")))"
        }.joined(separator: ", ")
        let ladder = ExportRung.allCases.sorted { $0.rank < $1.rank }.map(\.rawValue).joined(separator: ", ")
        return "Export rules are shared by the app and the CLI and are listed in docs/EXPORT-RULES.md. "
            + "Movie re-encode audio accepts \(list(movieAudioActions)). H.264/HEVC write \(reencodeContainers(.h264).joined(separator: ", ")) and ProRes \(reencodeContainers(.prores).joined(separator: ", ")). "
            + "Sound-only encode (a source without picture, or --tracks audio) accepts \(list(soundAudioActions)): \(conversions). "
            + "auto copies when the copy is exact and otherwise applies the first working alternative. "
            + "An unavailable export lists error.alternatives in this order: \(ladder). Each has an id, label, lossless flag and the arguments that request it. Nothing switches unless auto was asked for."
    }

    public static func markdown() -> String {
        func code(_ values: [String]) -> String { values.isEmpty ? "—" : values.map { "`\($0)`" }.joined(separator: ", ") }
        var lines = ["# Export rules", "",
                     "<!-- Generated from Sources/MPCutCore/ExportRules.swift. Do not edit. ExportRulesTests regenerates and compares it. -->", "",
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
                  "The multicam rows describe `MulticamEngine`, which plans programs itself and is not yet resolved through `ExportPlanner`. A sound-only multicam copy can also be written to `wav`.", "",
                  "## Containers by setting", "", "| Setting | Containers (default first) |", "| --- | --- |"]
        for codec in ReencodeCodec.allCases {
            lines.append("| Re-encode, `\(codec.rawValue)` | \(code(reencodeContainers(codec))) |")
        }
        for action in [ReencodeAudio.pcm, .aac, .mp3, .flac] {
            lines.append("| Convert Audio, `\(action.rawValue)` | \(code(conversionContainers(action))) |")
        }
        lines.append("| Multicam program | \(code(multicamContainers)) |")
        lines += ["", "PCM cannot be written into MP4 by a movie re-encode.", "",
                  "## Defaults", "", "| Setting | Default |", "| --- | --- |"]
        for source in ExportSourceKind.allCases {
            lines.append("| Mode, \(source.displayName.lowercased()) | `\(defaultMode(for: source).rawValue)` |")
        }
        lines += ["| Tracks | `all` |", "| Snap | `exact` |", "| Video codec | `\(defaultCodec.rawValue)` |",
                  "| Quality | `\(defaultQuality(.h264).rawValue)`, ProRes `\(defaultQuality(.prores).rawValue)` |",
                  "| Audio action in encode | `auto` |", "",
                  "The app's Settings can change the movie default mode. CLI commands use the default above, except `export`, whose exception is named under Entry points.", "",
                  "## Alternatives when an export is unavailable", "",
                  "Alternatives are checked in rank order and every one that works is reported, least destructive first. The rank compares, in order: how much is encoded (nothing, cut edges, the sound, picture and sound), whether the source format changes, whether an encoding generation is added, and the time to write. An alternative is offered, never applied, unless the request asked for `--audio auto`.", "",
                  "| Rank | Id | Encoded | Format | Added loss | What it does |", "| --- | --- | --- | --- | --- | --- |"]
        let scopes = ["nothing", "cut edges", "sound", "picture and sound"]
        for (index, rung) in ExportRung.allCases.sorted(by: { $0.rank < $1.rank }).enumerated() {
            let rank = rung.rank
            lines.append("| \(index + 1) | `\(rung.rawValue)` | \(scopes[rank.encodedScope]) | \(rank.formatChange == 0 ? "kept" : "changed") "
                + "| \(rank.addedLoss == 0 ? "none" : "one generation") | \(rung.summary) |")
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
        ("unsupported_container", "The container cannot carry the selected tracks or this conversion. The message names the valid extensions."),
        ("unsupported_tracks", "The source has tracks or timing that this mode cannot write."),
        ("unsupported_audio", "The audio action does not apply to this source, selection or container."),
        ("audio_copy_unavailable", "`--audio copy` was requested and the sound cannot be copied exactly."),
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
    /// Nil chooses the first container the rules allow.
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
        var indexed = media
        do {
            let source = try self.source(of: request, media: &indexed)
            let cell = ExportRules.cell(source: source.kind, tracks: request.tracks, mode: request.mode)
            if let refusal = cell.refusal { throw refusal }
            if cell.soundOnly, cell.resolvedMode == .encode, request.movieSettings || !cell.audioActions.contains(request.audio) {
                throw CutError(code: "invalid_arguments",
                               message: "Audio conversion accepts --audio \(cell.audioActions.map(\.rawValue).joined(separator: ", ")). Video settings apply to movies.")
            }
            if cell.soundOnly, cell.resolvedMode == .encode, let output, output.pathExtension.isEmpty {
                throw CutError(code: "unsupported_container",
                               message: "Give the output an extension to choose its format: .mp3, .flac, .wav or .m4a.")
            }
            // Auto for sound asks for the exact copy first. Its alternatives are the ones a copy request reports.
            let automatic = cell.soundOnly && cell.resolvedMode == .encode && request.audio == .auto
            var attempt = request
            if automatic { attempt.mode = .copy }
            do {
                return .ready(try plan(attempt, cell: automatic ? ExportRules.cell(source: source.kind, tracks: request.tracks, mode: .copy) : cell,
                                       output: output, media: indexed), request: attempt, applied: nil)
            } catch let issue as CutError {
                guard !Self.terminal.contains(issue.code) else { return .unavailable(issue, offers: []) }
                let offers = self.offers(after: attempt, source: source.media, kind: source.kind, output: output, media: indexed)
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
            try ReencodeEngine(cancelled: cancelled).write(conversion, to: output) { _ = progress?($0) }
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
                    .resolve(request.clips, output: output, media: media, container: container, settings: settings))
            case .copy, .smart:
                let engine = CutEngine(cancelled: cancelled, smartTrim: cell.resolvedMode == .smart, useSidecar: useSidecar,
                                       tracks: request.tracks, audioStream: request.audioStream,
                                       audioTrackOrdinal: request.audioTrackOrdinal)
                let edit = try engine.resolve(request.clips, output: output, snap: request.snap, media: media,
                                              container: request.container)
                return .packets(edit, mode: cell.resolvedMode, tracks: request.tracks)
            }
        }
    }

    // MARK: The ladder

    /// Every alternative of the cell that works for this request, in rank order.
    public func offers(after request: ExportRequest, source: MediaInfo, kind: ExportSourceKind, output: URL? = nil,
                       media: [URL: MediaInfo]) -> [ExportOffer] {
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
            var next = request
            next.snap = .exact
            switch rung {
            case .copyOtherContainer:
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
                candidates.append((rung, next))
            case .convertSameFormat, .convertPCM, .convertAAC:
                guard let action = rung == .convertSameFormat ? native : rung == .convertPCM ? .pcm : .aac else { continue }
                // The same-format rung already covers AAC for an AAC source.
                if rung == .convertAAC, native == .aac { continue }
                let containers = ExportRules.conversionContainers(action)
                next.mode = .encode
                next.audio = action
                next.container = rung == .convertSameFormat && containers.contains(own) ? own : containers[0]
                if request.mode == .encode, request.audio == action { continue }
                candidates.append((rung, next))
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
            let changed = zip(candidate.clips, request.clips).contains { $0.from != $1.from || $0.to != $1.to }
            let warnings = plan.warnings + (rung == .copySampleAligned ? ["Cuts were placed on the nearest audio sample."] : [])
            let alternative = ExportAlternative(
                id: rung == .copyOtherContainer ? "\(rung.rawValue):\(container)" : rung.rawValue, rung: rung,
                label: rung.label(container: container, audio: action?.action, lossless: lossless),
                mode: plan.mode, tracks: candidate.tracks, container: container, audio: action?.action,
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
