import Foundation

// The rules of a mixed timeline: clips whose codec, picture, timing or sound differ.
// Copy and Smart Trim join packets, so they need identical streams. Re-encode decodes every clip, so it
// writes them together on one canvas. The wording, the canvas policy, the refusals and the warnings are here,
// and docs/EXPORT-RULES.md lists them under "Mixed timelines".

/// How bright a picture's transfer function is. Re-encode has no tone mapping, so the kinds are never joined.
public enum DynamicRange: String, Sendable {
    case sdr = "SDR", pq = "HDR (PQ)", hlg = "HDR (HLG)"

    public init(_ stream: StreamInfo) {
        switch stream.colorTransfer {
        case "smpte2084": self = .pq
        case "arib-std-b67": self = .hlg
        default: self = .sdr
        }
    }
}

extension ExportRules {
    // MARK: What differs

    /// Every property in which a clip differs from the first one, as people name them. The copy check
    /// (`CutEngine.checkCompatibility`) stops at its first difference; this lists them all for the same pair.
    /// An empty list with a failing copy check means only codec configuration bytes differ.
    public static func mixedDifferences(_ media: MediaInfo, from reference: MediaInfo) -> [String] {
        var found: [String] = []
        func note(_ label: String, _ differs: Bool) { if differs, !found.contains(label) { found.append(label) } }
        if let a = media.videoStream, let b = reference.videoStream {
            note("video codec", a.codec != b.codec)
            note("picture size", a.displayWidth != b.displayWidth || a.displayHeight != b.displayHeight
                || a.width != b.width || a.height != b.height || a.sampleAspectRatio != b.sampleAspectRatio)
            note("orientation", a.rotation != b.rotation)
            note("frame rate", a.frameRate != b.frameRate)
            note("pixel format", a.pixelFormat != b.pixelFormat || a.bitDepth != b.bitDepth || a.alphaBits != b.alphaBits)
            note("field order", a.fieldOrder != b.fieldOrder)
            note("colour", a.colorPrimaries != b.colorPrimaries || a.colorTransfer != b.colorTransfer
                || a.colorMatrix != b.colorMatrix || a.colorRange != b.colorRange || a.chromaLocation != b.chromaLocation)
            note("video profile", a.codec == b.codec && a.profile != b.profile)
        }
        note("audio track count", media.audio.count != reference.audio.count)
        for (a, b) in zip(media.audio.map(\.stream), reference.audio.map(\.stream)) {
            note("audio codec", a.codec != b.codec || a.profile != b.profile)
            note("audio sample rate", a.sampleRate != b.sampleRate)
            note("audio channels", a.channels != b.channels || a.canonicalChannelLayout != b.canonicalChannelLayout)
        }
        return found
    }

    static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
    }

    static func clips(_ numbers: [Int]) -> String {
        (numbers.count == 1 ? "Clip " : "Clips ") + list(numbers.map(String.init))
    }

    /// "video codec and picture size (clips 1 and 2)". `clip` is the first clip that differs from clip 1.
    public static func mixedDescription(_ differences: [String], clip: Int) -> String {
        "\(differences.isEmpty ? "stream format" : list(differences)) (clips 1 and \(clip))"
    }

    /// The tier factor of a mixed timeline: what differs, between which clips, and what still writes them.
    public static func mixedFactorMessage(_ differences: [String], clip: Int) -> String {
        "Clips 1 and \(clip) differ in \(differences.isEmpty ? "stream format" : list(differences)). Only \(displayName(mode: .encode)) writes them together."
    }

    // MARK: Canvas policy

    public static let mixedCanvasPolicy = [
        "Picture size: the first clip's display size, with its rotation and pixel shape applied, rounded up to even numbers. Pixels are square.",
        "Fit: every other clip is turned upright, scaled to fit inside the canvas and centred on black. Bars are added at the sides or at top and bottom. Nothing is cropped or stretched.",
        "Pixel format: the chosen encoder's (8-bit 4:2:0 for H.264, 4:2:2 10-bit for ProRes, 4:2:0 for HEVC with ten bits when any clip has more than eight).",
        "Colour: tagged like the first clip. A clip with another matrix or range is converted to it. Primaries and transfer function are not converted, so an HDR clip is never joined to an SDR one.",
        "Frame rate: not converted. Every picture keeps its own time, so clips with different frame rates give a variable frame rate.",
        "Sound: one output track per track position, as many as the clip with the most. A position keeps its sample rate and channel layout when the clips agree; otherwise it is resampled to 48 kHz or mixed to stereo. A clip without that track is written as silence. The sound is always converted: AAC, or PCM where the rules choose it for the sources, codec and container.",
        "There is no project setting for the canvas. Put the clip whose picture should be kept first.",
    ]

    // MARK: Warnings

    public static func mixedWarning(_ differences: [String], clip: Int, width: Int, height: Int) -> String {
        "Sources differ in \(mixedDescription(differences, clip: clip)); the whole timeline is re-encoded to \(width)×\(height)."
    }
    public static func mixedSoundOnlyWarning(_ differences: [String], clip: Int) -> String {
        "Sources differ in \(mixedDescription(differences, clip: clip)); the sound of the whole timeline is converted."
    }
    public static func mixedFitWarning(_ numbers: [Int], width: Int, height: Int) -> String {
        "\(clips(numbers)) \(numbers.count == 1 ? "has" : "have") another picture shape and \(numbers.count == 1 ? "is" : "are") fitted inside \(width)×\(height) with black bars. Nothing is cropped or stretched."
    }
    public static let mixedFrameRateWarning = "The clips have different frame rates. Every picture keeps its own time, so the output has a variable frame rate."
    public static let mixedColorWarning = "The clips have different colour primaries or transfer functions. They are not converted, and the output is tagged like clip 1."
    public static func mixedResampleWarning(track: Int, rate: Int) -> String {
        "Audio track \(track) is resampled to \(rate / 1000) kHz, so that every clip has one sample rate the encoder accepts."
    }
    public static func mixedLayoutWarning(track: Int) -> String {
        "Audio track \(track) has different channel layouts and is mixed to stereo."
    }
    public static func mixedSilenceWarning(track: Int, clips numbers: [Int]) -> String {
        "\(clips(numbers)) \(numbers.count == 1 ? "has" : "have") no audio track \(track). Silence is written there."
    }
    static let mixedAudioReason = "The clips differ, so their sound is converted to one format."

    // MARK: Refusals

    /// Copy Original joins packets, which a mixed timeline cannot do. The alternatives name the conversions.
    static func mixedAudioCopyRefusal(_ differences: [String], clip: Int) -> CutError {
        CutError(code: "incompatible_clip",
                 message: "Sources differ in \(mixedDescription(differences, clip: clip)), so their sound cannot be copied. Choose --audio auto, aac, pcm or remove.",
                 segment: clip).because(.joinStreamMismatch)
    }

    static func mixedMediaTypeRefusal(clip: Int, name: String) -> CutError {
        CutError(code: "incompatible_clip",
                 message: "Clip \(clip) (\(name)) has no picture. A timeline holds movies or sound-only recordings, not both. To change a movie's soundtrack, use Replace Source Audio.",
                 segment: clip).because(.joinMediaType)
    }

    static func mixedDynamicRangeRefusal(first: (clip: Int, name: String, range: DynamicRange),
                                         other: (clip: Int, name: String, range: DynamicRange)) -> CutError {
        CutError(code: "incompatible_clip",
                 message: "Clip \(first.clip) (\(first.name)) is \(first.range.rawValue) and clip \(other.clip) (\(other.name)) is \(other.range.rawValue). "
                     + "Re-encode cannot convert between them, so they cannot share a timeline. Export them separately.",
                 segment: other.clip).because(.joinDynamicRange)
    }

    /// The same refusal where the clip is being added and has no number yet.
    static func mixedImportDynamicRangeRefusal(_ range: DynamicRange, timeline: DynamicRange) -> CutError {
        CutError(code: "incompatible_clip",
                 message: "This clip is \(range.rawValue) and the timeline is \(timeline.rawValue). "
                     + "Re-encode cannot convert between them, so they cannot share a timeline.").because(.joinDynamicRange)
    }

    // MARK: The app's question before a clip makes the timeline mixed

    /// Added to the question an edit asks before it lowers the tier, when the edit makes the timeline mixed.
    public static var mixedImportNote: String {
        "Exporting these clips together requires \(displayName(mode: .encode)). "
            + "All clips will use the first clip’s frame size."
    }
    /// The button that goes ahead with it.
    public static let mixedImportProceedTitle = "Add Anyway"
    /// Shown where a feature needs one sound format for every clip.
    public static func mixedUnavailable(_ feature: String) -> String {
        "\(feature) requires clips in the same format. Use \(displayName(mode: .encode)) to export this timeline."
    }
    /// Editor interchange is not an export mode and is not refused: it writes no media.
    public static let mixedInterchangeNote = "Editor interchange (Resolve, Final Cut Pro, Premiere Pro) writes no media, so a mixed timeline is not refused there. Each clip is described in its own format, and the sequence takes its size and frame rate from the first clip with picture."

    // MARK: The written section

    static func mixedMarkdown() -> [String] {
        var lines = ["", "## Mixed timelines", "",
                     "A timeline is mixed when a clip differs from the first one in anything a packet copy has to match: codec, picture size, orientation, pixel format, frame rate, colour tags, codec configuration, track layout, or the codec, sample rate and channels of a sound track. The container itself is not compared: the same picture-only streams in MP4, MOV and MKV copy together. A container can describe the same stream in other words: MP4 states an AAC track as “2 channels” where MOV states “stereo”. Channel layouts are compared by what they stand for, so a layout that names no speakers equals the standard layout of its channel count (mono, stereo, 5.1) and those two clips copy together. Layouts that name different speakers, such as 5.1 and 5.1(side), are different.", "",
                     "| Mode | Mixed timeline | If unavailable, offer |", "| --- | --- | --- |"]
        for mode in [ExportMode.smart, .copy] {
            lines.append("| `\(mode.rawValue)` | refused: `incompatible_clip`, reason `\(TierFactorID.joinStreamMismatch.rawValue)`. The message names the first property that differs. | `\(ExportRung.reencode.rawValue)` |")
        }
        lines.append("| `\(ExportMode.encode.rawValue)` | written on one canvas, with the warnings below | — |")
        lines += ["", "The tier of a mixed timeline is \(displayName(tier: .reencode)) with the factor `\(TierFactorID.joinStreamMismatch.rawValue)`. Nothing switches mode by itself: a copy or Smart Trim request is refused and offers the re-encode. In the app, adding a clip that makes the timeline mixed asks first, like any edit that lowers the tier, and says: “\(mixedImportNote)” The choices are “\(mixedImportProceedTitle)” and “Cancel”. These rules are about movies. Sound-only recordings in different formats are joined by Convert Audio, as before; the app still asks for matching recordings when one is added to a sound-only timeline.", "",
                  "### Canvas", ""]
        lines += mixedCanvasPolicy.map { "- " + $0 }
        lines += ["", "### Audio actions on a mixed timeline", "", "| Action | Result |", "| --- | --- |"]
        for action in movieAudioActions {
            let result: String
            switch action {
            case .auto: result = "Converted: a track whose clips all have one format keeps it where the container carries it, as in a uniform re-encode. Otherwise PCM for a track that is lossless in every clip that has it, in MOV, and in MKV for mono and stereo, and AAC, or for ProRes PCM under the same container limits."
            case .copyOriginal: result = "Refused: `incompatible_clip`. Offers the re-encode with `auto`."
            case .removeAudio: result = "No sound is written."
            default: result = "Converted to \(displayName(audio: action)) in the canvas format."
            }
            lines.append("| `\(action.rawValue)` | \(result) |")
        }
        lines += ["", "### Refused in every mode", "", "| Mix | Refusal | Reason id |", "| --- | --- | --- |",
                  "| A movie and a sound-only recording | “\(mixedMediaTypeRefusal(clip: 2, name: "name").message)” | `\(TierFactorID.joinMediaType.rawValue)` |",
                  "| SDR with HDR, or PQ with HLG | “\(mixedDynamicRangeRefusal(first: (1, "name", .sdr), other: (2, "name", .pq)).message)” | `\(TierFactorID.joinDynamicRange.rawValue)` |",
                  "| A source Re-encode cannot read (alpha, interlaced, extra HEVC layers, a rotation that is not a quarter turn) | the source's own refusal, with the clip number | `\(TierFactorID.sourceEncodeUnsupported.rawValue)` |",
                  "", "A single-type selection of a mixed timeline is not a re-encode. Video only is a packet copy, so it is refused with `incompatible_clip` and has no alternative. Audio only is refused as a copy and offers Convert Audio, which converts sound in different formats.",
                  "", mixedInterchangeNote,
                  "", "### Warnings", "", "A dry run and the export it plans report the same warnings.", ""]
        lines += [mixedWarning(["video codec", "picture size"], clip: 2, width: 1920, height: 1080),
                  mixedSoundOnlyWarning(["audio sample rate"], clip: 2),
                  mixedFitWarning([2], width: 1920, height: 1080), mixedFrameRateWarning, mixedColorWarning,
                  mixedResampleWarning(track: 1, rate: 48_000), mixedLayoutWarning(track: 1),
                  mixedSilenceWarning(track: 1, clips: [3])].map { "- " + $0 }
        return lines
    }
}
