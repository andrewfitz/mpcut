import Foundation

struct MulticamAudioConversionPlan: Sendable {
    struct Input: Sendable {
        let audio: AudioIndex
        let samples: Range<Int64>
        let decodedStart: Int64?
        let seekablePCM: Bool
        let count: Int64
        var silence = false
    }

    let edit: ResolvedEdit
    let inputs: [Input]
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
    func resolveConvertedSound(_ mapping: MulticamPlan, sources: [String: MediaInfo],
                               container: String, action: ReencodeAudio) throws -> MulticamAudioConversionPlan {
        if let refusal = ExportRules.reencodeRefusal(audio: action, container: container, source: .multicam) { throw refusal }
        let lane = mapping.audio.map {
            ConvertedSoundSpan(media: sources[$0.source], stream: $0.stream, input: $0.input, output: $0.output)
        }
        return try resolveConvertedSound(lane, duration: mapping.duration, container: container, action: action) { issue, index in
            try contextual(issue, span: mapping.audio[index], mapping: mapping, index: index + 1)
        }
    }

    /// Plans sample-exact conversion of ordered soundtrack ranges. `contextual` places
    /// a failure of the span at the given zero-based position in the caller's terms.
    func resolveConvertedSound(_ lane: [ConvertedSoundSpan], duration: RationalTime, container: String,
                               action: ReencodeAudio, allowsSilence: Bool = false,
                               silenceFormat: ConvertedSoundFormat? = nil,
                               contextual: (CutError, Int) throws -> CutError) throws -> MulticamAudioConversionPlan {
        struct SourceRange {
            let media: MediaInfo
            let audio: AudioIndex
            let layout: String
            let samples: Range<Int64>
            let decodedStart: Int64?
        }

        let engine = CutEngine(cancelled: cancelled)
        var aacClocks: [URL: [Int: Bool]] = [:]
        let spans: [SourceRange?] = try lane.enumerated().map { index, span in
            try engine.checkCancellation()
            if allowsSilence && span.media == nil && span.stream == nil { return nil }
            do {
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
                guard span.input.from >= coverageStart, span.input.to <= coverageEnd,
                      lower <= first, first < last, last <= upper else {
                    throw CutError(code: "uncovered_audio", message: "The selected audio stream does not cover this range on its sample clock.")
                }
                // Use decoded sample indices when the indexed stream is
                // contiguous. Compressed clocks can quantize packet PTS.
                var contiguous = (audio.pcmContinuity && audio.stream.isPCM) || opus != nil ||
                    (audio.stream.codec == "mp3" && media.format == "mp3")
                if audio.stream.codec == "aac" {
                    if let known = aacClocks[media.url]?[stream] {
                        contiguous = known
                    } else {
                        contiguous = try usesContinuousAACClock(audio, engine: engine)
                        aacClocks[media.url, default: [:]][stream] = contiguous
                    }
                }
                return SourceRange(media: media, audio: audio, layout: layout, samples: first..<last,
                                   decodedStart: contiguous ? lower : nil)
            } catch let issue as CutError {
                throw try contextual(issue, index)
            }
        }
        var audible = spans.compactMap { $0 }
        if audible.isEmpty, allowsSilence, let silenceFormat {
            let audio = silenceFormat.audio
            guard audio.stream.sampleRate > 0, audio.stream.channels > 0 else {
                throw CutError(code: "unsupported_audio", message: "The selected audio has no usable sample clock or channel layout.")
            }
            audible.append(SourceRange(media: silenceFormat.media, audio: audio, layout: try audioLayout(audio.stream),
                                       samples: 0..<0, decodedStart: nil))
        }
        guard let first = audible.first else {
            throw CutError(code: "missing_audio", message: "There is no soundtrack selected for conversion.")
        }
        let commonLayout = audible.allSatisfy { $0.layout == first.layout && $0.audio.stream.channels == first.audio.stream.channels }
        let commonRate = audible.allSatisfy { $0.audio.stream.sampleRate == first.audio.stream.sampleRate }
        let aacRates = [7_350, 8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000]
        let mp3Rates = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        let preserveRate = commonRate && (action != .aac || aacRates.contains(first.audio.stream.sampleRate))
            && (action != .mp3 || mp3Rates.contains(first.audio.stream.sampleRate))
        let rate = preserveRate ? first.audio.stream.sampleRate : 48_000
        let layout = commonLayout ? first.layout : "stereo"
        let channels = commonLayout ? first.audio.stream.channels : 2
        guard action != .aac || channels <= 8 else {
            throw CutError(code: "unsupported_audio", message: "AAC cannot preserve the selected channel layout. Choose PCM.")
        }
        guard action != .mp3 || channels <= 2 else {
            throw CutError(code: "unsupported_audio", message: "MP3 carries mono or stereo sound. Choose PCM for this channel layout.")
        }
        let floatingPoint = action == .aac || action == .mp3 || audible.contains {
            $0.audio.stream.codec.hasPrefix("pcm_f") || !$0.audio.presentationEdits.isEmpty
        }
        var warnings: [String] = []
        if !commonLayout { warnings.append("The selected soundtracks have different channel layouts and will be mixed to stereo.") }
        if !preserveRate { warnings.append("The program soundtrack will be resampled to 48 kHz.") }

        var segments: [ResolvedSegment] = []
        var inputs: [MulticamAudioConversionPlan.Input] = []
        var identities: [URL: SourceIdentity] = [:]
        if let silenceFormat { identities[silenceFormat.media.url] = silenceFormat.media.identity }
        var end: Int64 = 0
        for (index, span) in lane.enumerated() {
            let source = spans[index] ?? first
            let media = source.media
            let audio = source.audio
            // Round cumulative boundaries so sample rounding cannot
            // accumulate drift across switches.
            let start = try span.output.from.roundedToSamples(rate)
            let next = try span.output.to.roundedToSamples(rate)
            if start == end && next == start && spans[index] == nil { continue }
            guard start == end, next > start else {
                let issue = CutError(code: "unsupported_audio", message: "The soundtrack must cover the program with at least one output sample per span.")
                throw try contextual(issue, index)
            }
            let track = ResolvedTrack(index: audio.stream.index, kind: "audio",
                                      sourceStart: span.input.from, sourceEnd: span.input.to,
                                      outputStart: span.output.from, outputEnd: span.output.to)
            segments.append(ResolvedSegment(file: media.url, from: span.input.from, to: span.input.to,
                                            outputStart: span.output.from, tracks: [track], sourceOrigin: media.origin,
                                            reachesEnd: span.input.to == audio.end))
            inputs.append(.init(audio: audio, samples: source.samples, decodedStart: source.decodedStart,
                                seekablePCM: media.format == "wav" && audio.stream.isPCM && audio.pcmContinuity
                                    && source.decodedStart == 0 && media.origin == .zero,
                                count: next - start, silence: spans[index] == nil))
            if spans[index] != nil { identities[media.url] = media.identity }
            end = next
        }
        guard end == (try duration.roundedToSamples(rate)) else {
            throw CutError(code: "uncovered_audio", message: "The soundtrack does not cover the entire program.")
        }
        let edit = ResolvedEdit(segments: segments, duration: duration, container: container,
                                identities: identities, tracks: .audio)
        return MulticamAudioConversionPlan(edit: edit, inputs: inputs, action: action, warnings: warnings,
                                           helper: try ReencodeEngine.findHelper(override: nil), sampleRate: rate,
                                           channels: channels, layout: layout, floatingPoint: floatingPoint)
    }

    private func usesContinuousAACClock(_ audio: AudioIndex, engine: CutEngine) throws -> Bool {
        let stream = audio.stream
        let config = stream.configuration
        // Ordinary AAC-LC AudioSpecificConfig with a table sample rate and an
        // explicit channel configuration. GASpecificConfig supplies frameLengthFlag.
        guard audio.presentationEdits.isEmpty, config.count >= 2, let first = audio.packets.first else { return false }
        let sampleRateIndex = ((config[0] & 7) << 1) | (config[1] >> 7)
        guard config[0] >> 3 == 2, sampleRateIndex < 13, config[1] & 0x78 != 0 else { return false }
        let frameLength: Int64 = config[1] & 4 == 0 ? 1024 : 960
        let rate = Int64(stream.sampleRate)
        guard stream.timeBase > RationalTime(numerator: 1, denominator: rate),
              stream.timeBase < RationalTime(numerator: frameLength / 2, denominator: rate) else { return false }
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
        let runner = ReencodeEngine(cancelled: cancelled)
        let directory = output.deletingLastPathComponent()
        let raw = directory.appendingPathComponent("program-audio.raw")
        var handle: FileHandle?
        defer {
            try? handle?.close()
            try? FileManager.default.removeItem(at: raw)
        }
        if plan.inputs.count > 1 {
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
        let rawFormat = plan.floatingPoint ? "f32le" : "s32le"
        let stagedFormat = ["-f", rawFormat, "-ar", "\(plan.sampleRate)", "-ch_layout", plan.layout]

        func trim(_ input: MulticamAudioConversionPlan.Input, decodedStart: Int64?) -> String {
            let start = input.samples.lowerBound, end = input.samples.upperBound
            if let decodedStart {
                return "atrim=start_sample=\(start - decodedStart):end_sample=\(end - decodedStart),"
            }
            let rate = input.audio.stream.sampleRate
            return "asettb=1/\(rate),atrim=start_pts=\(start):end_pts=\(end),asetpts=PTS-(\(start)),"
                + "aresample=\(rate):async=1:first_pts=0:min_hard_comp=0,"
        }

        // A single validated span already is the complete program sample stream.
        func part(_ index: Int) -> URL {
            plan.inputs.count == 1 ? raw : directory.appendingPathComponent("audio-\(index).raw")
        }

        func outputArguments(prefix: String, for index: Int) -> [String] {
            let count = plan.inputs[index].count
            let filter = prefix + "aresample=\(plan.sampleRate):out_chlayout=\(plan.layout),"
                + "apad=whole_len=\(count),atrim=end_sample=\(count),asetpts=N/SR/TB"
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
            var capacity = Int64(32 << 20) / Int64(plan.channels * 4)
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
                if index >= stagedThrough {
                    stagedThrough = try stageCompressedGroup(from: index)
                }
                if index >= stagedThrough {
                    var arguments = ["-xerror", "-copyts", "-n"]
                    let prefix: String
                    if input.silence {
                        let source = "anullsrc=r=\(plan.sampleRate):cl=\(plan.layout)"
                        arguments += ["-f", "lavfi", "-i", source, "-map", "0:a:0"]
                        prefix = "atrim=end_sample=\(input.count),"
                    } else if !input.audio.presentationEdits.isEmpty {
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
                let expected = input.count.multipliedReportingOverflow(by: Int64(plan.channels * 4))
                guard !expected.overflow, (attributes[.size] as? NSNumber)?.int64Value == expected.partialValue else {
                    throw CutError(code: "audio_conversion_failed", message: "The converted span did not contain the planned number of samples.")
                }
                if let handle {
                    let reader = try FileHandle(forReadingFrom: part)
                    defer { try? reader.close() }
                    while let block = try reader.read(upToCount: 1 << 20), !block.isEmpty {
                        try runner.checkCancellation()
                        try handle.write(contentsOf: block)
                    }
                }
            } catch let error as CutError where error.code != "cancelled" {
                throw CutError(code: "audio_conversion_failed", message: error.message, segment: index + 1, track: track.index)
            } catch let error where !(error is CutError) {
                // File errors while staging samples are conversion failures for this span.
                throw CutError(code: "audio_conversion_failed", message: error.localizedDescription,
                               segment: index + 1, track: track.index)
            }
            progress?(0.8 * (segment.outputStart + segment.duration).seconds / plan.edit.duration.seconds)
        }
        try handle?.close()

        let container = plan.edit.container
        var arguments = ["-xerror"] + stagedFormat + ["-i", raw.path, "-map", "0:a:0"]
        if let custom = plan.encoderArguments {
            arguments += custom
        } else if plan.action == .aac {
            arguments += ["-c:a", "aac", "-b:a", "\(max(96, min(512, plan.channels * 96)))k"]
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
            arguments += ["-movie_timescale", "705600000", "-use_editlist", "1"]
        }
        arguments += ["-f", plan.muxer ?? muxerName(container), "-n", output.path]
        do {
            try runner.runHelper(plan.helper, arguments: arguments, in: directory, duration: plan.edit.duration) {
                progress?(0.8 + 0.2 * $0)
            }
            let result = try Probe.read(output, keyframes: false, cancelled: cancelled)
            guard result.audio.count == 1, let sound = result.audio.first,
                  sound.stream.sampleRate == plan.sampleRate, sound.stream.channels == plan.channels,
                  (try? audioLayout(sound.stream)) == plan.layout else {
                throw CutError(code: "audio_conversion_failed", message: "The output container changed the selected audio clock or channel layout.")
            }
            if MulticamMux.movieContainers.contains(container) || plan.verifiesSampleRange {
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
