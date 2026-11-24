import Foundation

/// The one output format of a re-encode whose sources differ (a mixed timeline). A uniform timeline has no canvas
/// and is written exactly as before. The policy is stated in `ExportRules.mixedCanvasPolicy`.
public struct ReencodeCanvas: Encodable, Equatable, Sendable {
    public struct Sound: Encodable, Equatable, Sendable {
        public let sampleRate: Int
        public let channels: Int
        public let layout: String
        let language: String
        let disposition: Int
        let floatingPoint: Bool

        enum CodingKeys: String, CodingKey { case sampleRate, channels, layout }
    }

    /// Display size in square pixels.
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let colorPrimaries: String
    public let colorTransfer: String
    public let colorMatrix: String
    public let colorRange: String
    /// One entry per output sound track.
    public let audio: [Sound]
    /// False when only the sound differs. The picture then takes the path of a uniform timeline.
    let normalizesPicture: Bool
    var usesStillColor = false

    enum CodingKeys: String, CodingKey {
        case width, height, pixelFormat, colorPrimaries, colorTransfer, colorMatrix, colorRange, audio
    }
}

extension ReencodeCanvas {
    private static let untagged: Set<String> = ["", "unknown", "unspecified", "reserved"]

    static func tag(_ value: String) -> String { untagged.contains(value) ? "unknown" : value }

    static func isFullRange(_ stream: StreamInfo) -> Bool {
        stream.colorRange == "pc" || stream.pixelFormat.hasPrefix("yuvj")
    }

    /// The name the scaler knows a matrix by, and the coefficients it stands for. Nil when it is untagged or has no conversion.
    private static func matrix(_ value: String) -> (name: String, family: String)? {
        switch value {
        case "bt709": return ("bt709", "709")
        case "smpte170m": return ("smpte170m", "601")
        case "bt470bg": return ("bt470", "601")
        case "bt2020nc", "bt2020c": return ("bt2020", "2020")
        case "smpte240m": return ("smpte240m", "240")
        case "fcc": return ("fcc", "fcc")
        default: return nil
        }
    }

    /// Where a source's upright picture lands on the canvas: its scaled size, never cropped or stretched.
    func fittedSize(_ stream: StreamInfo) -> (width: Int, height: Int) {
        let (sourceWidth, sourceHeight) = (max(1, stream.displayWidth), max(1, stream.displayHeight))
        func even(_ value: Double, limit: Int) -> Int {
            let rounded = min(limit, max(2, 2 * Int((value / 2).rounded())))
            // A sliver of a bar from rounding is not a bar.
            return limit - rounded <= 2 ? limit : rounded
        }
        if sourceWidth * height == sourceHeight * width { return (width, height) }
        if sourceWidth * height < sourceHeight * width {
            return (even(Double(sourceWidth) * Double(height) / Double(sourceHeight), limit: width), height)
        }
        return (width, even(Double(sourceHeight) * Double(width) / Double(sourceWidth), limit: height))
    }

    /// True when the source is shown with bars at its sides, or above and below.
    func addsBars(_ stream: StreamInfo) -> Bool {
        normalizesPicture && fittedSize(stream) != (width, height)
    }

    /// The filters that fit one source's decoded, upright picture into the canvas. Empty for a timeline whose pictures match.
    func fit(_ stream: StreamInfo) -> [String] {
        guard normalizesPicture else { return [] }
        let turn = !stream.rotation.isMultiple(of: 180)
        let decoded = turn ? (stream.height, stream.width) : (stream.width, stream.height)
        let fitted = fittedSize(stream)
        let shape = stream.sampleAspectRatio
        let square = shape.numerator <= 0 || shape.numerator == shape.denominator

        var conversion: [String] = []
        if let source = Self.matrix(stream.colorMatrix), let target = Self.matrix(colorMatrix), source.family != target.family {
            conversion += ["in_color_matrix=\(source.name)", "out_color_matrix=\(target.name)"]
        }
        if usesStillColor, stream.colorMatrix == "gbr", let target = Self.matrix(colorMatrix) {
            conversion += ["out_color_matrix=\(target.name)"]
        }
        let full = colorRange == "pc"
        let sourceFullRange = Self.isFullRange(stream) || (usesStillColor && stream.codecTag == "b48r" && stream.colorRange != "tv")
        if sourceFullRange != full {
            conversion += ["in_range=\(full ? "limited" : "full")", "out_range=\(full ? "full" : "limited")"]
        }
        var filters: [String] = []
        if decoded != fitted || !square || !conversion.isEmpty {
            filters.append((["scale=\(fitted.width):\(fitted.height)"] + conversion).joined(separator: ":"))
        }
        filters.append("setsar=1")
        if fitted != (width, height) {
            // Even offsets keep the chroma planes aligned.
            let (x, y) = ((width - fitted.width) / 2 & ~1, (height - fitted.height) / 2 & ~1)
            filters.append("pad=\(width):\(height):\(x):\(y):black")
        }
        filters.append("format=\(pixelFormat)")
        let tags = [stream.colorRange, stream.colorPrimaries, stream.colorTransfer, stream.colorMatrix].map(Self.tag)
        let wanted = [colorRange, colorPrimaries, colorTransfer, colorMatrix].map(Self.tag)
        if tags != wanted {
            // Every branch carries the canvas tags, so the encoder is configured alike whichever clip it meets first.
            filters.append("setparams=range=\(wanted[0]):color_primaries=\(wanted[1]):color_trc=\(wanted[2]):colorspace=\(wanted[3])")
        }
        return filters
    }
}

extension CutEngine {
    /// Whether a clip can share a timeline with `reference` when the timeline is re-encoded. Clips that pass
    /// `checkCompatibility` copy together and pass here too. Movies that differ pass when Re-encode can write them
    /// on one canvas. Refused: a movie with a sound-only recording, HDR with SDR, a source the encoder cannot read,
    /// and sound-only recordings that differ, which have no canvas.
    public func checkEncodeCombinable(_ media: MediaInfo, with reference: MediaInfo) throws {
        do {
            try checkCompatibility(media, with: reference)
        } catch let issue as CutError where issue.code == "incompatible_clip" && issue.factor == .joinStreamMismatch {
            guard let video = media.videoStream, let other = reference.videoStream else { throw issue }
            let (range, wanted) = (DynamicRange(video), DynamicRange(other))
            guard range == wanted else { throw ExportRules.mixedImportDynamicRangeRefusal(range, timeline: wanted) }
            // The checks every source of a re-encode passes. The codec and the picture size are the canvas's to decide.
            _ = try ReencodeVideo(video, settings: ReencodeSettings(codec: .hevc), frame: .init(width: 2, height: 2, deep: true))
        }
    }

    /// True when the sources cannot be joined by a packet copy, so only Re-encode writes them together.
    public func isMixed(_ sources: [MediaInfo]) -> Bool {
        guard let reference = sources.first else { return false }
        return sources.dropFirst().contains { source in
            do { try checkCompatibility(source, with: reference) } catch { return true }
            return false
        }
    }
}

/// One source of a mixed timeline, with the number of the first clip that uses it.
struct MixedSource {
    let clip: Int
    let media: MediaInfo
}

extension ReencodeEngine {
    /// Decides whether differing sources can be encoded together, and into what. Throws the refusals of
    /// `ExportRules` for an HDR and SDR mix, a source the encoder cannot read, or an exact audio copy.
    /// `difference` is the first clip that differs from clip 1 and what differs.
    func resolveMixed(_ sources: [MixedSource], difference: (clip: Int, labels: [String]), settings: ReencodeSettings,
                      container: String) throws -> (canvas: ReencodeCanvas, encoding: ReencodeVideo,
                                                    actions: [ReencodeAudioAction], warnings: [String]) {
        let reference = sources[0].media
        func name(_ source: MixedSource) -> String { source.media.url.lastPathComponent }
        let range = DynamicRange(reference.video)
        if let other = sources.first(where: { DynamicRange($0.media.video) != range }) {
            throw ExportRules.mixedDynamicRangeRefusal(first: (sources[0].clip, name(sources[0]), range),
                                                       other: (other.clip, name(other), DynamicRange(other.media.video)))
        }
        guard settings.audio != .copyOriginal else {
            throw ExportRules.mixedAudioCopyRefusal(difference.labels, clip: difference.clip)
        }

        let engine = CutEngine(cancelled: cancelled)
        let pictureDiffers = sources.dropFirst().contains { source in
            do { try engine.checkPictureCompatibility(source.media, with: reference) } catch { return true }
            return false
        }
        var warnings: [String] = []
        let encoding: ReencodeVideo
        if pictureDiffers {
            let frame = ReencodeVideo.Frame(width: reference.video.displayWidth + reference.video.displayWidth % 2,
                                            height: reference.video.displayHeight + reference.video.displayHeight % 2,
                                            deep: sources.contains { $0.media.video.bitDepth > 8 })
            encoding = try ReencodeVideo(reference.video, settings: settings, frame: frame)
            warnings.append(ExportRules.mixedWarning(difference.labels, clip: difference.clip, width: frame.width, height: frame.height))
            for source in sources.dropFirst() {
                do {
                    // The same checks the first clip passed: alpha, field order, rotation and what the profile keeps.
                    if let reduction = try ReencodeVideo(source.media.video, settings: settings, frame: frame).warning,
                       reduction != encoding.warning {
                        warnings.append("Clip \(source.clip): \(reduction)")
                    }
                } catch let issue as CutError {
                    throw CutError(code: issue.code, message: issue.message, segment: source.clip).because(issue.reason)
                }
            }
        } else {
            encoding = try ReencodeVideo(reference.video, settings: settings)
            warnings.append(ExportRules.mixedSoundOnlyWarning(difference.labels, clip: difference.clip))
        }

        var sounds: [ReencodeCanvas.Sound] = []
        var actions: [ReencodeAudioAction] = []
        var soundWarnings: [String] = []
        let trackCount = settings.audio == .removeAudio ? 0 : sources.map { $0.media.audio.count }.max() ?? 0
        if trackCount > 0 {
            if settings.audio != .auto,
               let refusal = ExportRules.reencodeRefusal(audio: settings.audio, container: container, source: .movie) { throw refusal }
            let aacRates = [7_350, 8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000]
            for position in 0..<trackCount {
                let present = sources.filter { $0.media.audio.count > position }
                var layouts: [String] = []
                for source in present {
                    let stream = source.media.audio[position].stream
                    do {
                        guard stream.sampleRate > 0, stream.channels > 0 else {
                            throw CutError(code: "unsupported_audio",
                                           message: "Audio track \(stream.index) has no usable sample clock or channel layout.")
                        }
                        layouts.append(try audioLayout(stream))
                    } catch let issue as CutError {
                        throw CutError(code: issue.code, message: issue.message, segment: source.clip, track: stream.index)
                    }
                }
                let streams = present.map { $0.media.audio[position].stream }
                let first = streams[0]
                // The multicam sound conversion set the precedent: keep what the clips share, else 48 kHz stereo.
                let commonLayout = zip(streams, layouts).allSatisfy { $0.channels == first.channels && $1 == layouts[0] }
                let commonRate = streams.allSatisfy { $0.sampleRate == first.sampleRate }
                let channels = commonLayout ? first.channels : 2
                // Auto decides for each track position. A position that is lossless in every clip that has it is written as PCM
                // where the container carries it. A clip without the track adds silence, which loses nothing.
                let lossless = streams.allSatisfy { ExportRules.isLosslessAudio(codec: $0.codec) }
                let action = settings.audio == .auto
                    ? ExportRules.automaticAudio(codec: settings.codec, container: container, source: .movie,
                                                 lossless: lossless, channels: channels).first ?? .aac
                    : settings.audio
                if let refusal = ExportRules.reencodeRefusal(audio: action, container: container, source: .movie) { throw refusal }
                let keepsRate = commonRate && (action != .aac || aacRates.contains(first.sampleRate))
                guard action != .aac || channels <= 8 else {
                    throw CutError(code: "unsupported_audio",
                                   message: "AAC cannot preserve the channel layout of audio track \(position + 1). Choose PCM.",
                                   track: first.index)
                }
                let sound = ReencodeCanvas.Sound(sampleRate: keepsRate ? first.sampleRate : 48_000, channels: channels,
                                                 layout: commonLayout ? layouts[0] : "stereo", language: first.language,
                                                 disposition: first.disposition,
                                                 // Float PCM and decoded lossy sound can exceed full scale, where integer PCM would clip.
                                                 floatingPoint: streams.contains { AudioExportEngine.moviePCM([$0]).codec == "pcm_f32le" })
                sounds.append(sound)
                let note = settings.audio == .auto
                    ? ExportRules.automaticAudioNote(action, lossless: lossless, channels: channels, container: container) : nil
                var written = ReencodeAudioAction(track: position + 1, action: action,
                                                  reason: [ExportRules.mixedAudioReason, note].compactMap { $0 }.joined(separator: " "))
                if action == .aac {
                    // An AAC position keeps the rate of its AAC sources when their channels are kept too.
                    let measured = present.compactMap { source -> Int? in
                        let audio = source.media.audio[position]
                        return audio.stream.codec == "aac" ? audio.averageBitRate : nil
                    }
                    written.codec = "aac"
                    written.bitRate = AudioExportEngine.aacBitRate(
                        matching: commonLayout && measured.count == present.count ? measured.max() : nil, channels: channels, neverBelowSource: true)
                    if let note = AudioExportEngine.aacProfileChange(streams, bitRate: written.bitRate ?? 0) {
                        soundWarnings.append("Audio track \(position + 1): \(note)")
                    }
                } else if action == .pcm {
                    // Sound that is neither resampled nor mixed keeps the word length of its integer sources.
                    let pcm = keepsRate && commonLayout ? AudioExportEngine.moviePCM(streams)
                        : (sound.floatingPoint ? "pcm_f32le" : "pcm_s32le", 32)
                    written.codec = pcm.0
                    written.bitDepth = pcm.1
                }
                actions.append(written)
                if action == .pcm, streams.contains(where: { $0.codec.hasPrefix("pcm_f64") }) {
                    soundWarnings.append("The 64-bit floating-point audio of track \(position + 1) will be reduced to 32-bit float.")
                }
                if !keepsRate { soundWarnings.append(ExportRules.mixedResampleWarning(track: position + 1, rate: sound.sampleRate)) }
                if !commonLayout { soundWarnings.append(ExportRules.mixedLayoutWarning(track: position + 1)) }
                let silent = sources.filter { $0.media.audio.count <= position }.map(\.clip)
                if !silent.isEmpty { soundWarnings.append(ExportRules.mixedSilenceWarning(track: position + 1, clips: silent)) }
            }
        }

        let video = reference.video
        let canvas = ReencodeCanvas(width: encoding.width, height: encoding.height, pixelFormat: encoding.pixelFormat,
                                    colorPrimaries: ReencodeCanvas.tag(video.colorPrimaries),
                                    colorTransfer: ReencodeCanvas.tag(video.colorTransfer),
                                    colorMatrix: ReencodeCanvas.tag(video.colorMatrix == "gbr" ? "bt709" : video.colorMatrix),
                                    colorRange: ReencodeCanvas.isFullRange(video) ? "pc" : ReencodeCanvas.tag(video.colorRange),
                                    audio: sounds, normalizesPicture: pictureDiffers)
        if pictureDiffers {
            let barred = sources.filter { canvas.addsBars($0.media.video) }.map(\.clip)
            if !barred.isEmpty { warnings.append(ExportRules.mixedFitWarning(barred, width: canvas.width, height: canvas.height)) }
            if sources.contains(where: { $0.media.video.frameRate != video.frameRate }) {
                warnings.append(ExportRules.mixedFrameRateWarning)
            }
            if sources.contains(where: {
                ReencodeCanvas.tag($0.media.video.colorPrimaries) != canvas.colorPrimaries
                    || ReencodeCanvas.tag($0.media.video.colorTransfer) != canvas.colorTransfer
            }) {
                warnings.append(ExportRules.mixedColorWarning)
            }
        }
        return (canvas, encoding, actions, warnings + soundWarnings)
    }
}

/// The encoder options of one converted sound track of a mixed timeline.
func audioOptions(_ planned: ReencodeAudioAction, sound: ReencodeCanvas.Sound, outputIndex: Int) -> [String] {
    let action = planned.action
    let specifier = "a:\(outputIndex)"
    // The plan states the codec and bit rate it chose from every clip of the position.
    let codec = action == .aac ? "aac" : planned.codec ?? (sound.floatingPoint ? "pcm_f32le" : "pcm_s32le")
    var args = ["-c:\(specifier)", codec, "-metadata:s:\(specifier)", "language=\(sound.language)",
                "-disposition:\(specifier)", "\(sound.disposition)"]
    if action == .aac {
        args += ["-b:\(specifier)", "\(planned.bitRate ?? AudioExportEngine.aacBitRate(matching: nil, channels: sound.channels))"]
    }
    args += ["-ar:\(specifier)", "\(sound.sampleRate)"]
    return args
}
