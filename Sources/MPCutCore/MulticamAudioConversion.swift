import Foundation

/// Whether the layout read back from a written file is the planned one. CAF stores quad, 5.0 and 5.1 with
/// one tag for back and side surrounds, in the same channel order, and reads it as the side layout. Its 7.1 tag
/// places the side surrounds before the back ones, an order that has no layout name.
func writtenLayout(_ written: StreamInfo, matches planned: String, in container: String) -> Bool {
    if ["mkv", "mka", "matroska"].contains(container), written.isPCM {
        return written.canonicalChannelLayout == StreamInfo.canonicalChannelLayout(planned, channels: written.channels)
    }
    if container == "caf", planned == "7.1" { return written.channelLayout == "8 channels (FL+FR+FC+LFE+SL+SR+BL+BR)" }
    guard let name = try? audioLayout(written) else { return false }
    if name == planned { return true }
    guard container == "caf", ["quad", "5.0", "5.1"].contains(planned) else { return false }
    return name == planned + "(side)"
}

struct MulticamAudioConversionPlan: Sendable {
    struct Input: Sendable {
        let audio: AudioIndex
        let samples: Range<Int64>
        let decodedStart: Int64?
        let seekablePCM: Bool
        let count: Int64
        var silence = false
        var layoutFilter = ""
        var retainsSamples = false
    }

    let edit: ResolvedEdit
    var inputs: [Input]
    let action: ReencodeAudio
    let warnings: [String]
    let helper: URL
    let sampleRate: Int
    let channels: Int
    let layout: String
    let floatingPoint: Bool
    /// Final encoder arguments and muxer chosen by a plain audio export.
    var encoderArguments: [String]? = nil
    var muxer: String? = nil
    var verifiesSampleRange = false
    var exactEncoding: ExactSoundEncoding? = nil
    /// Float PCM is staged and written in 64 bits when 32-bit float would narrow a source: 64-bit float sound,
    /// or integers longer than 24 bits beside sound that needs floating point.
    var doublePrecision = false
    /// True when a source is resampled or remixed to the output format, so its samples are not kept as they are.
    var conformsSources = false
    /// A cover picture copied into a sound-only file: the source file and the index of its picture stream.
    var coverArt: CoverArt? = nil
    /// Source chapters on the output timeline, for a sound-only file whose muxer writes chapters.
    var chapters: [ReencodeChapter] = []

    struct CoverArt: Sendable {
        let file: URL
        let stream: Int
    }

    var rawFormat: String { exactEncoding?.rawFormat ?? (floatingPoint ? (doublePrecision ? "f64le" : "f32le") : "s32le") }
    var bytesPerSample: Int { rawFormat == "f64le" ? 8 : 4 }
    /// The codec this plan writes: the final encoder a caller chose, or the staging format for PCM.
    var writtenCodec: String {
        if let chosen = encoderArguments.flatMap({ arguments in
            arguments.firstIndex(of: "-c:a").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }) { return chosen == "libmp3lame" ? "mp3" : chosen == "libopus" ? "opus" : chosen }
        return action == .aac ? "aac" : "pcm_\(rawFormat)"
    }
    /// The word length of written PCM, FLAC and ALAC. Nil for a codec that has none.
    var writtenBitDepth: Int? {
        if let exactEncoding { return exactEncoding.bitDepth }
        let codec = writtenCodec
        if let depth = AudioExportEngine.pcmDepth(codec: codec) { return depth }
        guard codec == "flac" || codec == "alac", let arguments = encoderArguments,
              let index = arguments.firstIndex(of: "-bits_per_raw_sample"), arguments.indices.contains(index + 1) else {
            return codec == "flac" && encoderArguments?.contains("s16") == true ? 16 : nil
        }
        return Int(arguments[index + 1])
    }
    /// The rate of written AAC. As in a movie re-encode, the track follows the rate of AAC sources whose channels it
    /// keeps. A downmix, and a track with any other source, gets the default for its channels.
    var writtenBitRate: Int? {
        if let arguments = encoderArguments {
            guard let index = arguments.firstIndex(of: "-b:a"), arguments.indices.contains(index + 1) else { return nil }
            return Int(arguments[index + 1])
        }
        guard action == .aac else { return nil }
        let sources = inputs.filter { !$0.silence }
        let measured = sources.compactMap { input in
            input.audio.stream.codec == "aac" && input.layoutFilter.isEmpty && input.audio.stream.channels == channels
                ? input.audio.averageBitRate : nil
        }
        return AudioExportEngine.aacBitRate(matching: !sources.isEmpty && measured.count == sources.count ? measured.max() : nil,
                                            channels: channels, neverBelowSource: true)
    }
    // N is an integer sample count. Dividing by SR*TB can round long timestamps one tick early.
    var exactSamplePTS: String { "asettb=1/\(sampleRate),asetpts=N" }
}

/// One retained range of a soundtrack on the program clock.
struct ConvertedSoundFormat {
    let media: MediaInfo
    let audio: AudioIndex
}

struct ConvertedSoundSpan {
    let media: MediaInfo?
    let stream: Int?
    let input: MulticamRange
    let output: MulticamRange
}

extension MulticamEngine {
    /// Plans sample-exact conversion of ordered soundtrack ranges. `contextual` places
    /// a failure of the span at the given zero-based position in the caller's terms.
    func resolveConvertedSound(_ lane: [ConvertedSoundSpan], duration: RationalTime, container: String,
                               action: ReencodeAudio, allowsSilence: Bool = false,
                               silenceFormat: ConvertedSoundFormat? = nil,
                               downmixChannels: Int? = nil,
                               preserveSamples: Bool = false,
                               keepsDoublePrecision: Bool = true,
                               contextual: (CutError, Int) throws -> CutError) throws -> MulticamAudioConversionPlan {
        struct SourceRange {
            let media: MediaInfo
            let audio: AudioIndex
            let layout: String
            let samples: Range<Int64>
            let availableSamples: Range<Int64>
            let decodedStart: Int64?
        }

        let engine = CutEngine(cancelled: cancelled)
        var frameClocks: [URL: [Int: Bool]] = [:]
        var losslessClocks: [URL: [Int: Bool]] = [:]
        let spans: [SourceRange?] = try lane.enumerated().map { index, span in
            try engine.checkCancellation()
            if allowsSilence && span.media == nil && span.stream == nil { return nil }
            do {
                if downmixChannels != nil,
                   try span.output.from.roundedToSamples(MulticamProgramMixer.sampleRate)
                    == span.output.to.roundedToSamples(MulticamProgramMixer.sampleRate) { return nil }
                guard let media = span.media, let stream = span.stream,
                      let audio = media.audio.first(where: { $0.stream.index == stream }) else {
                    throw CutError(code: "missing_audio", message: "The selected audio stream is unavailable.")
                }
                guard audio.stream.sampleRate > 0, audio.stream.channels > 0 else {
                    throw CutError(code: "unsupported_audio", message: "The selected audio has no usable sample clock or channel layout.")
                }
                let layout = try audioLayout(audio.stream)
                let rate = audio.stream.sampleRate
                let opus = audio.opusWindow.flatMap { $0.complete ? $0 : nil }
                let lower = try opus?.start ?? media.origin.adding(audio.start).roundedToSamples(rate)
                let upper = try opus?.end ?? media.origin.adding(audio.end).roundedToSamples(rate)
                let first = try media.origin.adding(span.input.from).roundedToSamples(rate)
                let last = try media.origin.adding(span.input.to).roundedToSamples(rate)
                let coverageStart = try opus.map { try RationalTime(numerator: $0.start, denominator: Int64(rate)).subtracting(media.origin) } ?? audio.start
                let coverageEnd = try opus.map { try RationalTime(numerator: $0.end, denominator: Int64(rate)).subtracting(media.origin) } ?? audio.end
                guard span.input.from >= coverageStart, span.input.from < span.input.to, span.input.to <= coverageEnd,
                      lower <= first, last <= upper, first < last || ((preserveSamples || downmixChannels != nil) && upper > lower) else {
                    throw CutError(code: "uncovered_audio", message: "The selected audio stream does not cover this range on its sample clock.")
                }
                // Use decoded sample indices when the indexed stream is
                // contiguous. Compressed clocks can quantize packet PTS.
                var contiguous = (audio.pcmContinuity && audio.stream.isPCM) || opus != nil ||
                    (audio.stream.codec == "mp3" && media.format == "mp3")
                if audio.stream.codec == "aac" {
                    if let known = frameClocks[media.url]?[stream] {
                        contiguous = known
                    } else {
                        contiguous = try usesContinuousAACClock(audio, engine: engine)
                        frameClocks[media.url, default: [:]][stream] = contiguous
                    }
                } else if ["mp1", "mp2", "mp3"].contains(audio.stream.codec), !contiguous {
                    if let known = frameClocks[media.url]?[stream] {
                        contiguous = known
                    } else {
                        contiguous = try usesContinuousMPEGAudioClock(media, audio, engine: engine)
                        frameClocks[media.url, default: [:]][stream] = contiguous
                    }
                }
                if preserveSamples, ["flac", "alac"].contains(audio.stream.codec) {
                    if let known = losslessClocks[media.url]?[stream] {
                        contiguous = known
                    } else {
                        contiguous = try continuousLosslessSamples(audio) == upper - lower
                        losslessClocks[media.url, default: [:]][stream] = contiguous
                    }
                }
                // A sub-sample edit can still occupy one tick on the shared output clock.
                // Use its nearest indexed source sample, including at the end of the stream.
                let nearest = min(first, upper - 1)
                let samples = first < last ? first..<last : nearest..<(nearest + 1)
                return SourceRange(media: media, audio: audio, layout: layout, samples: samples,
                                   availableSamples: lower..<upper,
                                   decodedStart: contiguous ? lower : nil)
            } catch let issue as CutError {
                throw try contextual(issue, index)
            }
        }
        var audible = spans.compactMap { $0 }
        let silenceOnly = audible.isEmpty
        if silenceOnly, allowsSilence, let silenceFormat {
            let audio = silenceFormat.audio
            guard audio.stream.sampleRate > 0, audio.stream.channels > 0 else {
                throw CutError(code: "unsupported_audio", message: "The selected audio has no usable sample clock or channel layout.")
            }
            audible.append(SourceRange(media: silenceFormat.media, audio: audio, layout: try audioLayout(audio.stream),
                                       samples: 0..<0, availableSamples: 0..<0, decodedStart: nil))
        }
        guard let first = audible.first else {
            throw CutError(code: "missing_audio", message: "There is no soundtrack selected for conversion.")
        }
        let commonLayout = audible.allSatisfy { $0.layout == first.layout && $0.audio.stream.channels == first.audio.stream.channels }
        let commonRate = audible.allSatisfy { $0.audio.stream.sampleRate == first.audio.stream.sampleRate }
        let exactEncoding: ExactSoundEncoding?
        if preserveSamples {
            guard commonLayout, commonRate, downmixChannels == nil else {
                throw CutError(code: "unsupported_audio", message: "Sample preservation requires one channel layout and sample rate per audio track.")
            }
            exactEncoding = try ExactSoundEncoding(action: action, streams: audible.map { $0.audio.stream },
                                                   layout: first.layout, silenceOnly: silenceOnly)
        } else {
            exactEncoding = nil
        }
        let aacRates = [7_350, 8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000]
        let mp3Rates = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        let preserveRate = commonRate && (action != .aac || aacRates.contains(first.audio.stream.sampleRate))
            && (action != .mp3 || mp3Rates.contains(first.audio.stream.sampleRate))
            // Every Opus stream decodes at 48 kHz, whatever rate its encoder was given.
            && (action != .opus || first.audio.stream.sampleRate == 48_000)
        let rate = downmixChannels == nil && preserveRate ? first.audio.stream.sampleRate : MulticamProgramMixer.sampleRate
        let channels = downmixChannels ?? (commonLayout ? first.audio.stream.channels : 2)
        let layout = downmixChannels.map { $0 == 1 ? "mono" : "stereo" } ?? (commonLayout ? first.layout : "stereo")
        if action == .pcm, let issue = matroskaPCMLayoutIssue(layout, channels: channels, container: container) {
            throw CutError(code: "unsupported_audio", message: issue)
        }
        // The AAC helper remaps these side-speaker layouts to their back-speaker variants.
        let remappedAACLayouts = ["5.1(side)", "7.1(wide-side)"]
        guard action != .aac || (channels <= 8 && !remappedAACLayouts.contains(layout)) else {
            throw CutError(code: "unsupported_audio", message: "AAC cannot preserve the selected channel layout. Choose PCM.")
        }
        guard action != .mp3 || channels <= 2 else {
            throw CutError(code: "unsupported_audio", message: "MP3 carries mono or stereo sound. Choose PCM for this channel layout.")
        }
        // libopus writes surround in channel mapping family 1, which states one layout for each channel count.
        // The index reads no speakers from any other Opus stream, so another layout could not be verified.
        guard action != .opus || channels <= 2 || layout == StreamInfo.opusSurroundLayout(channels: channels) else {
            throw CutError(code: "unsupported_audio",
                           message: "Opus conversion writes mono, stereo, 3.0, quad, 5.0, 5.1, 6.1 or 7.1 sound. Choose PCM for this channel layout.")
        }
        // PCM written from a lossy decoder stays float: the decoder can exceed full scale, where integer PCM would clip.
        let floatingPoint = downmixChannels != nil || action == .aac || action == .mp3 || action == .opus || audible.contains {
            $0.audio.stream.codec.hasPrefix("pcm_f") || !$0.audio.presentationEdits.isEmpty
                || (action == .pcm && !AudioExportEngine.decodesToInteger($0.audio.stream))
        }
        var warnings = exactEncoding?.warnings ?? []
        if downmixChannels == nil && !commonLayout { warnings.append("The selected soundtracks have different channel layouts and will be mixed to stereo.") }
        if audible.contains(where: { $0.audio.stream.sampleRate != rate }) { warnings.append("The program soundtrack will be resampled to 48 kHz.") }
        let conformsSources = (downmixChannels == nil && !commonLayout) || audible.contains { $0.audio.stream.sampleRate != rate }

        var segments: [ResolvedSegment] = []
        var inputs: [MulticamAudioConversionPlan.Input] = []
        var identities: [URL: SourceIdentity] = [:]
        if let silenceFormat { identities[silenceFormat.media.url] = silenceFormat.media.identity }
        var end: Int64 = 0
        var alignedCuts = false
        for (index, span) in lane.enumerated() {
            let source = spans[index] ?? first
            let media = source.media
            let audio = source.audio
            // Round cumulative boundaries so sample rounding cannot
            // accumulate drift across switches.
            let start = try span.output.from.roundedToSamples(rate)
            let next = try span.output.to.roundedToSamples(rate)
            if start == end && next == start && (spans[index] == nil || downmixChannels != nil) { continue }
            guard start == end, next > start else {
                let issue = CutError(code: "unsupported_audio", message: "The soundtrack must cover the program with at least one output sample per span.")
                throw try contextual(issue, index)
            }
            let track = ResolvedTrack(index: audio.stream.index, kind: "audio",
                                      sourceStart: span.input.from, sourceEnd: span.input.to,
                                      outputStart: span.output.from, outputEnd: span.output.to)
            segments.append(ResolvedSegment(file: media.url, from: span.input.from, to: span.input.to,
                                            outputStart: span.output.from, tracks: [track], sourceOrigin: media.origin,
                                            reachesEnd: span.input.to == audio.end, sourceClipIndex: index))
            let layoutFilter: String
            do {
                layoutFilter = try downmixChannels.map {
                    try MulticamProgramMixer.panFilter(layout: source.layout, channels: audio.stream.channels, outputChannels: $0)
                } ?? ""
            } catch let issue as CutError {
                throw try contextual(issue, index)
            }
            var retainedSamples = source.samples
            if preserveSamples, spans[index] != nil {
                let inputStart = try media.origin.adding(span.input.from)
                let inputEnd = try media.origin.adding(span.input.to)
                do {
                    let aligned = try samplePreservingRange(from: inputStart, to: inputEnd,
                                                           count: next - start, available: source.availableSamples, rate: rate)
                    retainedSamples = aligned.range
                    alignedCuts = alignedCuts || aligned.rounded
                    if audio.stream.isPCM, source.decodedStart == nil, !audio.pcmGaps.isEmpty {
                        let retainedStart = try RationalTime(numerator: retainedSamples.lowerBound, denominator: Int64(rate))
                            .subtracting(media.origin)
                        let retainedEnd = try RationalTime(numerator: retainedSamples.upperBound, denominator: Int64(rate))
                            .subtracting(media.origin)
                        if audio.pcmGaps.contains(where: { $0.from < retainedEnd && retainedStart < $0.to }) {
                            throw CutError(code: "unsupported_audio",
                                           message: "The retained source range crosses a discontinuity in the PCM sample clock.")
                        }
                    }
                } catch let issue as CutError {
                    throw try contextual(issue, index)
                }
            }
            inputs.append(.init(audio: audio, samples: retainedSamples, decodedStart: source.decodedStart,
                                seekablePCM: media.format == "wav" && audio.stream.isPCM && audio.pcmContinuity
                                    && source.decodedStart == 0 && media.origin == .zero,
                                count: next - start, silence: spans[index] == nil, layoutFilter: layoutFilter,
                                retainsSamples: preserveSamples))
            if spans[index] != nil { identities[media.url] = media.identity }
            end = next
        }
        guard end == (try duration.roundedToSamples(rate)) else {
            throw CutError(code: "uncovered_audio", message: "The soundtrack does not cover the entire program.")
        }
        if alignedCuts { warnings.append("Fractional audio cuts were aligned to whole source samples without resampling.") }
        let edit = ResolvedEdit(segments: segments, duration: duration, container: container,
                                identities: identities, tracks: .audio)
        let helper = try ReencodeEngine.findHelper(override: nil)
        if let exactEncoding { try AudioExportEngine.requireEncoder(named: exactEncoding.codec, helper: helper) }
        // 32-bit float holds 24 bits. Program PCM that would lose more is staged and written as 64-bit float.
        var doublePrecision = false
        if keepsDoublePrecision, action == .pcm, floatingPoint, downmixChannels == nil, exactEncoding == nil, !silenceOnly {
            let streams = audible.map(\.audio.stream)
            let wide = streams.compactMap(AudioExportEngine.integerDepth).max().map { $0 > 24 } ?? false
            if wide || streams.contains(where: { $0.codec.hasPrefix("pcm_f64") }) {
                doublePrecision = (try? AudioExportEngine.requireEncoder(named: "pcm_f64le", helper: helper)) != nil
                if !doublePrecision {
                    warnings.append("The installed FFmpeg helper has no 64-bit float PCM encoder. The soundtrack will be reduced to 32-bit float.")
                }
            }
        }
        var plan = MulticamAudioConversionPlan(edit: edit, inputs: inputs, action: action, warnings: warnings,
                                               helper: helper, sampleRate: rate, channels: channels, layout: layout,
                                               floatingPoint: floatingPoint, encoderArguments: exactEncoding?.arguments,
                                               exactEncoding: exactEncoding)
        plan.doublePrecision = doublePrecision
        plan.conformsSources = conformsSources
        return plan
    }

    /// Under `auto`, a rendered lane whose every span has one compressed source format keeps it where the container and the
    /// helper allow: FLAC and ALAC keep their samples, AAC, MP3 and Opus their rate. Nil for a lane of PCM, a lane whose spans
    /// differ, or a format the container cannot carry; those keep the rendered codecs of the container. Returns the plan
    /// and the reason, or nil when the source format does not apply or cannot be planned.
    func sourceFormatPlan(_ spans: [ConvertedSoundSpan], duration: RationalTime, container: String, source: ExportSourceKind,
                          silenceFormat: ConvertedSoundFormat?,
                          contextual: (CutError, Int) throws -> CutError) -> (plan: MulticamAudioConversionPlan, note: String)? {
        let audible = spans.compactMap { span -> (media: MediaInfo, audio: AudioIndex)? in
            guard let media = span.media, let stream = span.stream,
                  let audio = media.audio.first(where: { $0.stream.index == stream }) else { return nil }
            return (media, audio)
        }
        // Sound-only containers follow the movie container of their family: M4A carries AAC and ALAC, MKA what MKV
        // carries, and a FLAC file FLAC.
        let written = ExportRules.multicamMuxContainer(container)
        let family = ["mka", "flac"].contains(written) ? "mkv" : written == "m4a" ? "mp4" : written
        guard ["mov", "mp4", "mkv"].contains(family),
              let described = ExportRules.automaticAudioSource(audible.map(\.audio.stream)), let codec = described.codec,
              let format = ExportRules.sourceFormat(for: codec), format != .pcm,
              written != "m4a" || [.aac, .alac].contains(format), written != "flac" || format == .flac,
              // An MP3 track in Matroska does not keep the planned presentation sample range, so it is rendered as before.
              format != .mp3 || family != "mkv",
              ExportRules.sourceFormatIssue(format, track: described, container: family, source: source) == nil,
              let helper = try? ReencodeEngine.findHelper(override: nil),
              ExportRules.automaticEncoders[format].map({ AudioExportEngine.encoders(of: helper).contains($0) }) ?? false else { return nil }
        do {
            var plan = try resolveConvertedSound(spans, duration: duration, container: container, action: format,
                                                 allowsSilence: true, silenceFormat: silenceFormat,
                                                 preserveSamples: format == .flac || format == .alac, contextual: contextual)
            guard plan.sampleRate == described.sampleRate, plan.channels == described.channels else { return nil }
            switch format {
            case .mp3:
                let profiles = audible.compactMap { MP3Profile(media: $0.media, sound: $0.audio)?.asConstant }
                let chosen = MP3Profile.encoding(matching: profiles.count == audible.count ? profiles : [],
                                                 sampleRate: plan.sampleRate, channels: plan.channels)
                plan.encoderArguments = ["-c:a", "libmp3lame"] + chosen.arguments
            case .opus:
                let measured = audible.compactMap(\.audio.averageBitRate)
                let rate = AudioExportEngine.opusBitRate(matching: measured.count == audible.count ? measured.max() : nil,
                                                         channels: plan.channels)
                plan.encoderArguments = ["-c:a", "libopus", "-b:a", "\(rate)", "-vbr", "constrained"]
                    + (plan.channels > 2 ? ["-mapping_family", "1"] : [])
            default:
                break
            }
            let label = ExportRules.audioCodecName(codec)
            let note: String
            switch format {
            case .flac, .alac: note = "The \(label) source is written as \(label) at its own word length, so no lossy encoding is added."
            case .aac where described.highEfficiency != nil:
                note = "The \(described.highEfficiency ?? "HE-AAC") source is written as AAC-LC at its own rate: the AAC encoder writes LC only."
            default: note = "The \(label) source is written as \(label) at its own rate."
            }
            return (plan, note)
        } catch {
            return nil
        }
    }

    private func usesContinuousAACClock(_ audio: AudioIndex, engine: CutEngine) throws -> Bool {
        let stream = audio.stream
        let config = stream.configuration
        // Ordinary AAC-LC AudioSpecificConfig with a table sample rate and an
        // explicit channel configuration. GASpecificConfig supplies frameLengthFlag.
        guard audio.presentationEdits.isEmpty, config.count >= 2, !audio.packets.isEmpty else { return false }
        let sampleRateIndex = ((config[0] & 7) << 1) | (config[1] >> 7)
        guard config[0] >> 3 == 2, sampleRateIndex < 13, config[1] & 0x78 != 0 else { return false }
        let frameLength: Int64 = config[1] & 4 == 0 ? 1024 : 960
        let rate = Int64(stream.sampleRate)
        guard stream.timeBase > RationalTime(numerator: 1, denominator: rate),
              stream.timeBase < RationalTime(numerator: frameLength / 2, denominator: rate) else { return false }
        return try followsFrameClock(audio, frameLength: frameLength, engine: engine)
    }

    /// Matroska times MP3 and MP2 blocks to the millisecond, between samples at 44.1 kHz, so trimming the decoded
    /// sound by those timestamps can start a few samples off and keep a different count. When every block lies on
    /// the track's own frame clock, the decoded samples are contiguous from the indexed start and are cut by count.
    private func usesContinuousMPEGAudioClock(_ media: MediaInfo, _ audio: AudioIndex, engine: CutEngine) throws -> Bool {
        let stream = audio.stream
        guard media.format.split(separator: ",").contains("matroska"), audio.presentationEdits.isEmpty,
              stream.sampleRate > 0 else { return false }
        let frameLength: Int64
        switch stream.codec {
        case "mp1": frameLength = 384
        case "mp2": frameLength = 1152
        // MPEG-2 and MPEG-2.5 Layer III, below 32 kHz, code half as many samples in a frame.
        case "mp3": frameLength = stream.sampleRate >= 32_000 ? 1152 : 576
        default: return false
        }
        guard stream.timeBase < RationalTime(numerator: frameLength / 2, denominator: Int64(stream.sampleRate)) else { return false }
        return try followsFrameClock(audio, frameLength: frameLength, engine: engine)
    }

    /// Every packet starts one frame after the previous one, within a tick of the stream clock, and only the first
    /// skips samples and only the last discards them.
    private func followsFrameClock(_ audio: AudioIndex, frameLength: Int64, engine: CutEngine) throws -> Bool {
        guard let first = audio.packets.first else { return false }
        let stream = audio.stream
        let rate = Int64(stream.sampleRate)
        for (index, packet) in audio.packets.enumerated() {
            if index.isMultiple(of: 1024) { try engine.checkCancellation() }
            if index > 0 && packet.skipSamples != 0 { return false }
            if index < audio.packets.count - 1 && packet.discardSamples != 0 { return false }
            let ideal = try first.time.adding(RationalTime(numerator: Int64(index) * frameLength, denominator: rate))
            // Two separately quantized timestamps can disagree by one tick.
            let offset = try packet.time.subtracting(ideal)
            if offset > stream.timeBase { return false }
            if try offset.adding(stream.timeBase) < .zero { return false }
        }
        return try audio.start == first.time.adding(RationalTime(numerator: Int64(first.skipSamples), denominator: rate))
    }

    func writeConvertedSound(_ plan: MulticamAudioConversionPlan, to output: URL,
                             progress: (@Sendable (Double) -> Void)? = nil) throws {
        // A continuous, indexed WAV range can feed the lossless encoder directly.
        // For an hour of stereo at 48 kHz this avoids a 1.38 GB PCM scratch file.
        if plan.exactEncoding != nil, plan.inputs.count == 1, let input = plan.inputs.first,
           input.retainsSamples, input.seekablePCM, !input.silence, input.audio.presentationEdits.isEmpty,
           let segment = plan.edit.segments.first {
            let rate = Int64(plan.sampleRate)
            let seek = input.samples.lowerBound / rate
            let offset = seek * rate
            let trim = "atrim=start_sample=\(input.samples.lowerBound - offset):end_sample=\(input.samples.upperBound - offset),\(plan.exactSamplePTS)"
            var arguments = seek > 0 ? ["-ss", String(seek)] : []
            arguments += ["-i", segment.file.path, "-map", "0:\(input.audio.stream.index)", "-map_metadata", "-1",
                          "-map_chapters", "-1", "-af", trim]
            try encodeConvertedSound(plan, inputArguments: arguments, to: output, progress: progress)
            return
        }
        let raw = output.deletingLastPathComponent().appendingPathComponent("program-audio.raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        try stageConvertedSound(plan, to: raw, progress: { progress?(0.8 * $0) })
        try encodeConvertedSound(plan, from: raw, to: output) { progress?(0.8 + 0.2 * $0) }
    }

    func stageConvertedSound(_ plan: MulticamAudioConversionPlan, to raw: URL,
                             consumeSpan: ((URL, Int64, Int64) throws -> Void)? = nil,
                             progress: (@Sendable (Double) -> Void)? = nil) throws {
        let runner = ReencodeEngine(cancelled: cancelled)
        let directory = raw.deletingLastPathComponent()
        var handle: FileHandle?
        defer { try? handle?.close() }
        if consumeSpan == nil, plan.inputs.count > 1 || plan.inputs.first?.silence == true {
            guard FileManager.default.createFile(atPath: raw.path, contents: nil) else {
                throw CutError(code: "audio_conversion_failed", message: "Could not create the program audio staging file.")
            }
            do {
                handle = try FileHandle(forWritingTo: raw)
            } catch {
                throw CutError(code: "audio_conversion_failed",
                               message: "Could not open the program audio staging file. \(error.localizedDescription)")
            }
        }
        let rawFormat = plan.rawFormat
        let stagedFormat = ["-f", rawFormat, "-ar", "\(plan.sampleRate)", "-ch_layout", plan.layout]

        func trim(_ input: MulticamAudioConversionPlan.Input, decodedStart: Int64?) -> String {
            let start = input.samples.lowerBound, end = input.samples.upperBound
            if let decodedStart {
                return "atrim=start_sample=\(start - decodedStart):end_sample=\(end - decodedStart),"
            }
            let rate = input.audio.stream.sampleRate
            if input.retainsSamples {
                return "asettb=1/\(rate),atrim=start_pts=\(start):end_pts=\(end),"
            }
            return "asettb=1/\(rate),atrim=start_pts=\(start):end_pts=\(end),asetpts=PTS-(\(start)),"
                + "aresample=\(rate):async=1:first_pts=0:min_hard_comp=0,"
        }

        // A single validated span already is the complete program sample stream.
        func part(_ index: Int) -> URL {
            plan.inputs.count == 1 ? raw : directory.appendingPathComponent("audio-\(index).raw")
        }

        func outputArguments(prefix: String, for index: Int) -> [String] {
            let input = plan.inputs[index]
            let filter: String
            if input.retainsSamples {
                // Match the indexed sample count before padding or output conversion can hide a discrepancy.
                filter = prefix + plan.exactSamplePTS
            } else {
                let count = input.count
                var resample = "aresample=\(plan.sampleRate):out_chlayout=\(plan.layout)"
                let retained = input.samples.upperBound - input.samples.lowerBound
                if !input.layoutFilter.isEmpty, input.audio.stream.sampleRate != plan.sampleRate, retained < 64 {
                    // The default long filter can flush without producing a sample from a short edit.
                    resample += ":filter_size=\(max(1, retained / 2))"
                    if retained == 1, input.audio.stream.sampleRate > plan.sampleRate {
                        // Keep the nearest physical sample when downsampling would discard it.
                        resample = "asetrate=\(plan.sampleRate)," + resample
                    }
                }
                filter = prefix + input.layoutFilter + resample
                    + ",apad=whole_len=\(count),atrim=end_sample=\(count),asetpts=N/SR/TB"
            }
            return ["-af", filter, "-c:a", "pcm_\(rawFormat)"] + stagedFormat + [part(index).path]
        }

        // Share decoder history for adjacent cuts from the same compressed track. Each
        // output keeps its own trim and resampler. Stage only retained samples, with
        // at most eight outputs and 32 MiB of PCM per group.
        func stageCompressedGroup(from index: Int) throws -> Int {
            let file = plan.edit.segments[index].file
            let stream = plan.inputs[index].audio.stream
            guard !plan.inputs[index].silence, !stream.isPCM,
                  plan.inputs[index].audio.presentationEdits.isEmpty else { return index }
            var capacity = Int64(32 << 20) / Int64(plan.channels * plan.bytesPerSample)
            var end = index
            while end < plan.inputs.count && end - index < 8 {
                let input = plan.inputs[end]
                guard !input.silence, plan.edit.segments[end].file == file, input.audio.stream.index == stream.index,
                      input.audio.presentationEdits.isEmpty, input.count <= capacity else { break }
                capacity -= input.count
                end += 1
            }
            guard end - index >= 2 else { return index }
            var arguments = ["-xerror", "-copyts", "-n", "-i", file.path]
            for item in index..<end {
                let input = plan.inputs[item]
                arguments += ["-map", "0:\(stream.index)"]
                    + outputArguments(prefix: trim(input, decodedStart: input.decodedStart), for: item)
            }
            do {
                try runner.runHelper(plan.helper, arguments: arguments, in: directory)
                return end
            } catch let error as CutError where error.code == "encode_failed" {
                // Retry individually to preserve the failing segment and track diagnostic.
                for item in index..<end where FileManager.default.fileExists(atPath: part(item).path) {
                    try FileManager.default.removeItem(at: part(item))
                }
                return index
            }
        }

        var stagedThrough = 0
        var outputFrame: Int64 = 0
        let outputFrames = try plan.edit.duration.roundedToSamples(plan.sampleRate)
        for (index, pair) in zip(plan.edit.segments, plan.inputs).enumerated() {
            try runner.checkCancellation()
            let (segment, input) = pair
            let part = part(index)
            let caf = directory.appendingPathComponent("audio-\(index).caf")
            defer {
                if part != raw { try? FileManager.default.removeItem(at: part) }
                try? FileManager.default.removeItem(at: caf)
            }
            let track = input.audio.stream
            do {
                let expected = input.count.multipliedReportingOverflow(by: Int64(plan.channels * plan.bytesPerSample))
                guard !expected.overflow, expected.partialValue > 0 else {
                    throw CutError(code: "audio_conversion_failed", message: "The planned audio span has an invalid PCM size.")
                }
                if input.silence {
                    // Synthetic gaps already use the program clock and layout. All-zero bytes
                    // represent silence in both staging formats.
                    if let handle {
                        var remaining = expected.partialValue
                        let block = Data(count: Int(min(remaining, 1 << 20)))
                        while remaining > 0 {
                            try runner.checkCancellation()
                            let count = Int(min(remaining, Int64(block.count)))
                            try handle.write(contentsOf: block.prefix(count))
                            remaining -= Int64(count)
                        }
                    }
                } else {
                    if index >= stagedThrough {
                        stagedThrough = try stageCompressedGroup(from: index)
                    }
                    if index >= stagedThrough {
                        var arguments = ["-xerror", "-copyts", "-n"]
                        let prefix: String
                        if !input.audio.presentationEdits.isEmpty {
                            if input.audio.presentationEdits.contains(where: { $0.isAudible && $0.samples.overlaps(input.samples) }) {
                                try runner.stageEditedAudio(segment.file, track: track, source: input.samples,
                                                            count: input.samples.upperBound - input.samples.lowerBound,
                                                            to: caf, segment: index + 1)
                                arguments += ["-i", caf.path, "-map", "0:a:0"]
                                prefix = ""
                            } else {
                                let source = "anullsrc=r=\(track.sampleRate):cl=\(try audioLayout(track))"
                                arguments += ["-f", "lavfi", "-i", source, "-map", "0:a:0"]
                                prefix = "atrim=end_sample=\(input.samples.upperBound - input.samples.lowerBound),"
                            }
                        } else {
                            var decodedStart = input.decodedStart
                            if input.seekablePCM {
                                // Integer seconds are exact on both FFmpeg's seek clock and the WAV sample clock.
                                let rate = Int64(track.sampleRate)
                                let seconds = input.samples.lowerBound / rate
                                if seconds > 0 {
                                    arguments += ["-ss", String(seconds)]
                                    decodedStart = seconds * rate
                                }
                            }
                            arguments += ["-i", segment.file.path, "-map", "0:\(track.index)"]
                            prefix = trim(input, decodedStart: decodedStart)
                        }
                        arguments += outputArguments(prefix: prefix, for: index)
                        try runner.runHelper(plan.helper, arguments: arguments, in: directory)
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
                    guard (attributes[.size] as? NSNumber)?.int64Value == expected.partialValue else {
                        throw CutError(code: "audio_conversion_failed", message: "The converted span did not contain the planned number of samples.")
                    }
                    if let consumeSpan {
                        try consumeSpan(part, outputFrame, input.count)
                    } else if let handle {
                        let reader = try FileHandle(forReadingFrom: part)
                        defer { try? reader.close() }
                        while let block = try reader.read(upToCount: 1 << 20), !block.isEmpty {
                            try runner.checkCancellation()
                            try handle.write(contentsOf: block)
                        }
                    }
                }
            } catch let error as CutError where error.code != "cancelled" {
                throw CutError(code: "audio_conversion_failed", message: error.message, segment: index + 1, track: track.index)
            } catch let error where !(error is CutError) {
                // File errors while staging samples are conversion failures for this span.
                throw CutError(code: "audio_conversion_failed", message: error.localizedDescription,
                               segment: index + 1, track: track.index)
            }
            outputFrame += input.count
            if consumeSpan != nil {
                progress?(Double(outputFrame) / Double(outputFrames))
            } else {
                progress?((segment.outputStart + segment.duration).seconds / plan.edit.duration.seconds)
            }
        }
        try handle?.close()
    }

    func encodeConvertedSound(_ plan: MulticamAudioConversionPlan, from raw: URL, to output: URL,
                              inputSampleFormat: String? = nil, progress: (@Sendable (Double) -> Void)? = nil) throws {
        let stagedFormat = ["-f", inputSampleFormat ?? plan.rawFormat, "-ar", "\(plan.sampleRate)", "-ch_layout", plan.layout]
        try encodeConvertedSound(plan, inputArguments: stagedFormat + ["-i", raw.path, "-map", "0:a:0"],
                                 to: output, progress: progress)
    }

    private func encodeConvertedSound(_ plan: MulticamAudioConversionPlan, inputArguments: [String],
                                      to output: URL, progress: (@Sendable (Double) -> Void)?) throws {
        let runner = ReencodeEngine(cancelled: cancelled)
        let directory = output.deletingLastPathComponent()
        let rawFormat = plan.rawFormat
        let container = plan.edit.container
        var arguments = ["-xerror"] + inputArguments
        if let art = plan.coverArt, let firstMap = arguments.firstIndex(of: "-map") {
            // The picture is a second input, copied as it is. Its input precedes the output options.
            arguments.insert(contentsOf: ["-i", art.file.path], at: firstMap)
            // Only the picture is taken from that source. Its chapters are on the source timeline, not this one.
            arguments += ["-map", "1:\(art.stream)", "-c:v", "copy", "-disposition:v:0", "attached_pic", "-map_chapters", "-1"]
        }
        var chapterFile: URL?
        defer { if let chapterFile { try? FileManager.default.removeItem(at: chapterFile) } }
        if !plan.chapters.isEmpty, let firstMap = arguments.firstIndex(of: "-map") {
            // The remapped chapters are one more input without streams. They replace any refusal to map chapters above.
            let metadata = directory.appendingPathComponent("chapters-\(UUID().uuidString).ffmeta")
            chapterFile = metadata
            do {
                try ReencodeChapter.metadata(plan.chapters).write(to: metadata, atomically: true, encoding: .utf8)
            } catch {
                throw CutError(code: "write_failed", message: error.localizedDescription)
            }
            let index = arguments[..<firstMap].filter { $0 == "-i" }.count
            arguments.insert(contentsOf: ["-f", "ffmetadata", "-i", metadata.path], at: firstMap)
            var position = arguments.startIndex
            while position < arguments.count - 1 {
                if arguments[position] == "-map_chapters" && arguments[position + 1] == "-1" {
                    arguments.removeSubrange(position...(position + 1))
                } else {
                    position += 1
                }
            }
            arguments += ["-map_chapters", "\(index)"]
        }
        if container == "caf", plan.layout == "7.1" {
            // FFmpeg tags 7.1 in CAF as side surrounds then back surrounds but writes the samples in its own
            // order, back then side. Writing them in the order of the tag keeps each sound on its speaker.
            arguments += ["-af", "channelmap=map=0|1|2|3|6|7|4|5:channel_layout=7.1"]
        }
        if let custom = plan.encoderArguments {
            arguments += custom
            if custom.contains("libopus") { arguments += opusTailOptions(container: container, specifier: "a") }
        } else if plan.action == .aac, let rate = plan.writtenBitRate {
            // The plan reports this rate, so the report states what is encoded here.
            arguments += ["-c:a", "aac", "-b:a", "\(rate)"]
        } else {
            if container == "mkv" {
                // Place every PCM packet on a whole millisecond in Matroska.
                // A short final packet keeps the planned sample count.
                let samplesPerTick = plan.sampleRate / commonAudioSampleRate([plan.sampleRate, 1_000])
                let packetSamples = samplesPerTick * max(1, 1_024 / samplesPerTick)
                arguments += ["-af", "asetnsamples=n=\(packetSamples):p=0"]
            }
            arguments += ["-c:a", "pcm_\(rawFormat)"]
        }
        if MulticamMux.movieContainers.contains(container) || container == "m4a" {
            let sharedMovieClock = 705_600_000
            let movieClock = sharedMovieClock.isMultiple(of: plan.sampleRate) ? sharedMovieClock : plan.sampleRate
            // Make the movie metadata visible before PCM bytes that could resemble MPEG-TS packets.
            arguments += ["-movie_timescale", "\(movieClock)", "-use_editlist", "1", "-movflags", "+faststart"]
        }
        arguments += ["-f", plan.muxer ?? muxerName(container), "-n", output.path]
        do {
            try runner.runHelper(plan.helper, arguments: arguments, in: directory, duration: plan.edit.duration, progress: progress)
            let result = try Probe.read(output, keyframes: false, cancelled: cancelled)
            guard result.audio.count == 1, let sound = result.audio.first,
                  sound.stream.sampleRate == plan.sampleRate, sound.stream.channels == plan.channels,
                  writtenLayout(sound.stream, matches: plan.layout, in: container) else {
                throw CutError(code: "audio_conversion_failed", message: "The output container changed the selected audio clock or channel layout.")
            }
            if plan.exactEncoding != nil {
                try plan.verifyExactSound(sound, origin: result.origin)
            } else if MulticamMux.movieContainers.contains(container) || plan.verifiesSampleRange {
                let expected = try plan.edit.duration.roundedToSamples(plan.sampleRate)
                // An MP3 file places its first audible sample after the encoder delay.
                let origin = container == "mp3" ? RationalTime.zero : result.origin
                let start = try origin.adding(sound.start).roundedToSamples(plan.sampleRate)
                let end = try origin.adding(sound.end).roundedToSamples(plan.sampleRate)
                guard start == 0, end == expected else {
                    throw CutError(code: "audio_conversion_failed", message: "The converted track did not retain the planned presentation sample range.")
                }
            }
        } catch let error as CutError where error.code != "cancelled" {
            throw CutError(code: "audio_conversion_failed", message: error.message)
        }
    }
}
