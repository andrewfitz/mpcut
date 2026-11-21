import Foundation

struct MulticamAudioConversionPlan: Sendable {
    struct Input: Sendable {
        let audio: AudioIndex
        let samples: Range<Int64>
        let decodedStart: Int64?
        let count: Int64
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
}

extension MulticamEngine {
    func resolveConvertedSound(_ mapping: MulticamPlan, sources: [String: MediaInfo],
                               container: String, action: ReencodeAudio) throws -> MulticamAudioConversionPlan {
        switch action {
        case .aac where !["mov", "mp4"].contains(container):
            throw CutError(code: "unsupported_audio",
                           message: "Choose MOV or MP4 for converted multicam AAC with gapless timing.")
        case .pcm where !["mov", "mkv"].contains(container):
            throw CutError(code: "unsupported_audio", message: "Choose MOV or MKV for PCM audio.")
        default:
            break
        }

        struct SourceRange {
            let media: MediaInfo
            let audio: AudioIndex
            let layout: String
            let samples: Range<Int64>
            let decodedStart: Int64?
        }

        let engine = CutEngine(cancelled: cancelled)
        var aacClocks: [URL: [Int: Bool]] = [:]
        let spans = try mapping.audio.enumerated().map { index, span in
            try engine.checkCancellation()
            do {
                guard let media = sources[span.source], let stream = span.stream,
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
                throw try contextual(issue, span: span, mapping: mapping, index: index + 1)
            }
        }
        guard let first = spans.first else {
            throw CutError(code: "missing_audio", message: "There is no soundtrack selected for conversion.")
        }
        let commonLayout = spans.allSatisfy { $0.layout == first.layout && $0.audio.stream.channels == first.audio.stream.channels }
        let commonRate = spans.allSatisfy { $0.audio.stream.sampleRate == first.audio.stream.sampleRate }
        let aacRates = [7_350, 8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000]
        let preserveRate = commonRate && (action != .aac || aacRates.contains(first.audio.stream.sampleRate))
        let rate = preserveRate ? first.audio.stream.sampleRate : 48_000
        let layout = commonLayout ? first.layout : "stereo"
        let channels = commonLayout ? first.audio.stream.channels : 2
        guard action != .aac || channels <= 8 else {
            throw CutError(code: "unsupported_audio", message: "AAC cannot preserve the selected channel layout. Choose PCM.")
        }
        let floatingPoint = action == .aac || spans.contains {
            $0.audio.stream.codec.hasPrefix("pcm_f") || !$0.audio.presentationEdits.isEmpty
        }
        var warnings: [String] = []
        if !commonLayout { warnings.append("The selected soundtracks have different channel layouts and will be mixed to stereo.") }
        if !preserveRate { warnings.append("The program soundtrack will be resampled to 48 kHz.") }

        var segments: [ResolvedSegment] = []
        var inputs: [MulticamAudioConversionPlan.Input] = []
        var identities: [URL: SourceIdentity] = [:]
        var end: Int64 = 0
        for (index, span) in mapping.audio.enumerated() {
            let source = spans[index]
            let media = source.media
            let audio = source.audio
            // Round cumulative boundaries so sample rounding cannot
            // accumulate drift across switches.
            let start = try span.output.from.roundedToSamples(rate)
            let next = try span.output.to.roundedToSamples(rate)
            guard start == end, next > start else {
                let issue = CutError(code: "unsupported_audio", message: "The soundtrack must cover the program with at least one output sample per span.")
                throw try contextual(issue, span: span, mapping: mapping, index: index + 1)
            }
            let track = ResolvedTrack(index: audio.stream.index, kind: "audio",
                                      sourceStart: span.input.from, sourceEnd: span.input.to,
                                      outputStart: span.output.from, outputEnd: span.output.to)
            segments.append(ResolvedSegment(file: media.url, from: span.input.from, to: span.input.to,
                                            outputStart: span.output.from, tracks: [track], sourceOrigin: media.origin,
                                            reachesEnd: span.input.to == audio.end))
            inputs.append(.init(audio: audio, samples: source.samples, decodedStart: source.decodedStart, count: next - start))
            identities[media.url] = media.identity
            end = next
        }
        guard end == (try mapping.duration.roundedToSamples(rate)) else {
            throw CutError(code: "uncovered_audio", message: "The soundtrack does not cover the entire program.")
        }
        let edit = ResolvedEdit(segments: segments, duration: mapping.duration, container: container,
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
        guard FileManager.default.createFile(atPath: raw.path, contents: nil) else {
            throw CutError(code: "audio_conversion_failed", message: "Could not create the program audio staging file.")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: raw)
        } catch {
            try? FileManager.default.removeItem(at: raw)
            throw CutError(code: "audio_conversion_failed",
                           message: "Could not open the program audio staging file. \(error.localizedDescription)")
        }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: raw)
        }
        let rawFormat = plan.floatingPoint ? "f32le" : "s32le"
        let stagedFormat = ["-f", rawFormat, "-ar", "\(plan.sampleRate)", "-ch_layout", plan.layout]

        // Stage one input at a time so long assemblies do not require an open
        // demuxer per cut. The final pass writes one continuous encoded track.
        for (index, pair) in zip(plan.edit.segments, plan.inputs).enumerated() {
            try runner.checkCancellation()
            let (segment, input) = pair
            let part = directory.appendingPathComponent("audio-\(index).raw")
            let caf = directory.appendingPathComponent("audio-\(index).caf")
            defer {
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: caf)
            }
            let track = input.audio.stream
            var arguments = ["-xerror", "-copyts"]
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
                arguments += ["-i", segment.file.path, "-map", "0:\(track.index)"]
                if let start = input.decodedStart {
                    prefix = "atrim=start_sample=\(input.samples.lowerBound - start):end_sample=\(input.samples.upperBound - start),"
                } else {
                    let rate = track.sampleRate
                    let start = input.samples.lowerBound
                    let end = input.samples.upperBound
                    prefix = "asettb=1/\(rate),atrim=start_pts=\(start):end_pts=\(end),asetpts=PTS-(\(start)),"
                        + "aresample=\(rate):async=1:first_pts=0:min_hard_comp=0,"
                }
            }
            let filter = prefix
                + "aresample=\(plan.sampleRate):out_chlayout=\(plan.layout),"
                + "apad=whole_len=\(input.count),atrim=end_sample=\(input.count),asetpts=N/SR/TB"
            arguments += ["-af", filter, "-c:a", "pcm_\(rawFormat)"] + stagedFormat + ["-n", part.path]
            do {
                try runner.runHelper(plan.helper, arguments: arguments, in: directory)
                let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
                let expected = input.count.multipliedReportingOverflow(by: Int64(plan.channels * 4))
                guard !expected.overflow, (attributes[.size] as? NSNumber)?.int64Value == expected.partialValue else {
                    throw CutError(code: "audio_conversion_failed", message: "The converted span did not contain the planned number of samples.")
                }
                let reader = try FileHandle(forReadingFrom: part)
                defer { try? reader.close() }
                while let block = try reader.read(upToCount: 1 << 20), !block.isEmpty {
                    try runner.checkCancellation()
                    try handle.write(contentsOf: block)
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
        try handle.close()

        let container = plan.edit.container
        var arguments = ["-xerror"] + stagedFormat + ["-i", raw.path, "-map", "0:a:0"]
        if plan.action == .aac {
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
        if MulticamMux.movieContainers.contains(container) {
            arguments += ["-movie_timescale", "705600000", "-use_editlist", "1"]
        }
        arguments += ["-f", muxerName(container), "-n", output.path]
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
            if MulticamMux.movieContainers.contains(container) {
                let expected = try plan.edit.duration.roundedToSamples(plan.sampleRate)
                let start = try result.origin.adding(sound.start).roundedToSamples(plan.sampleRate)
                let end = try result.origin.adding(sound.end).roundedToSamples(plan.sampleRate)
                guard start == 0, end == expected else {
                    throw CutError(code: "audio_conversion_failed", message: "The converted track did not retain the planned presentation sample range.")
                }
            }
        } catch let error as CutError where error.code != "cancelled" {
            throw CutError(code: "audio_conversion_failed", message: error.message)
        }
    }
}
