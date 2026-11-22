import Darwin
import Foundation
import PacketWriter

private struct DecoderInput: Hashable {
    let file: URL
    let seek: Int64?
    // A long branch may need its own decoder so later trims cannot queue its frames.
    var independentSegment: Int?
}

private struct ReencodeInput {
    var decoder: DecoderInput
    let segment: Int
    let media: MediaInfo
    var file: URL { decoder.file }
    let from: RationalTime
    var to: RationalTime
    let outputStart: RationalTime
}

extension ReencodeEngine {
    public func write(_ plan: ReencodePlan, to output: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        try checkCancellation()
        try checkDestination(output, container: plan.edit.container)
        for (file, identity) in plan.edit.identities { try verifyIdentity(file, identity) }

        let destination = output.standardizedFileURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let partial = staging.appendingPathComponent("movie").appendingPathExtension(plan.edit.container)

        let inputs = try filterInputs(plan)
        var extraInputs: [String] = []
        // Filter inputs preserve absolute timestamps. Direct packet mapping is
        // valid only when the entire source already uses the output timeline.
        let directAudio = plan.audioCopy.map { copy in
            guard inputs.count == 1, copy.segments.count == 1, let clip = copy.segments.first,
                  clip.from == .zero, clip.sourceOrigin == .zero, clip.reachesEnd,
                  let media = plan.media[clip.file], media.origin == .zero else { return false }
            return clip.tracks.filter { $0.kind == "audio" }.allSatisfy {
                $0.sourceStart == $0.outputStart && $0.sourceEnd == $0.outputEnd && $0.opusPreSkip == nil
            }
        } ?? false
        if let audioCopy = plan.audioCopy, !directAudio {
            let audio = staging.appendingPathComponent("audio-copy").appendingPathExtension(audioCopy.container)
            try CutEngine(cancelled: cancelled).export(audioCopy, to: audio, audioOnly: true)
            extraInputs += ["-i", audio.path]
        }
        let batches = try inputBatches(inputs, plan: plan)
        if batches.count == 1 {
            try render(plan, inputs: batches[0], in: staging, to: partial, intermediate: false,
                       copiedAudio: extraInputs, progress: progress)
        } else {
            try renderBatches(plan, batches: batches, in: staging, to: partial,
                              copiedAudio: extraInputs, progress: progress)
        }
        let container = plan.edit.container
        try checkCancellation()
        if container == "mkv", let tracks = plan.edit.segments.last?.tracks,
           plan.audioActions.contains(where: { $0.action == .aac }) || tracks.contains(where: { $0.opusPreSkip != nil }) {
            // The final mux measures coded blocks, including hidden AAC priming
            // or Opus padding. A copied track can end before or after the video.
            // The output maps picture first, then sound in the plan's track order.
            let trackEnds = try tracks.map { try $0.outputEnd.roundedToSamples(1_000_000_000) }
            guard mpcut_set_matroska_durations(partial.path, trackEnds, trackEnds.count) == 0 else {
                throw CutError(code: "write_failed", message: "Could not finalize the MKV presentation duration.")
            }
        }
        for (file, identity) in plan.edit.identities { try verifyIdentity(file, identity) }
        try checkCancellation()
        let failure = publishExclusively(from: partial, to: destination)
        guard failure == 0 else {
            if failure == EEXIST { throw CutError(code: "output_exists", message: "A file already exists at the destination.") }
            throw CutError(code: "write_failed", message: String(cString: strerror(failure)))
        }
        progress?(1)
    }

    /// Bound the helper's simultaneously open demuxers, edited-AAC intermediates and
    /// filter branches. Repeated uses of one source at the same seek anchor share a decoder.
    private func inputBatches(_ inputs: [ReencodeInput], plan: ReencodePlan) throws -> [[ReencodeInput]] {
        var limit = rlimit()
        let available = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? Int(clamping: limit.rlim_cur) : 256
        let budget = min(32, max(1, available - 12))
        var batches: [[ReencodeInput]] = []
        var batch: [ReencodeInput] = []
        var decoderBytes: [DecoderInput: Double] = [:]
        var sharedBytes = 0.0
        var stagedAudio = 0
        for var input in inputs {
            try checkCancellation()
            let edits = zip(input.media.audio, plan.audioActions).filter {
                !$0.0.presentationEdits.isEmpty && plan.filtersAudio($0.1)
            }.count
            let lower = input.media.frames.lowerBound { $0.time >= input.from }
            let upper = input.media.frames.lowerBound { $0.time >= input.to }
            let video = input.media.video
            let bytes = Double(upper - lower) * Double(video.width) * Double(video.height) * 8
            // interleave waits for all branches. A later trim on a shared decoder
            // can queue every retained surface of an earlier trim before emitting its
            // first picture. Keep large branches on independently scheduled inputs.
            let prior = decoderBytes[input.decoder]
            let additional = prior.map { $0 + bytes } ?? 0
            if sharedBytes + additional > 128 * 1024 * 1024 {
                input.decoder.independentSegment = input.segment
            }
            let cost = decoderBytes.count + (decoderBytes[input.decoder] == nil ? 1 : 0) + stagedAudio + edits
            if !batch.isEmpty && (cost > budget || batch.count >= 128) {
                batches.append(batch)
                batch = []
                decoderBytes.removeAll(keepingCapacity: true)
                sharedBytes = 0
                stagedAudio = 0
                input.decoder.independentSegment = nil
            }
            if let pending = decoderBytes[input.decoder] {
                // Charge the first branch when its decoder first becomes shared.
                sharedBytes += pending + bytes
                decoderBytes[input.decoder] = 0
            } else {
                decoderBytes[input.decoder] = bytes
            }
            stagedAudio += edits
            batch.append(input)
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private func renderBatches(_ plan: ReencodePlan, batches: [[ReencodeInput]],
                               in staging: URL, to partial: URL, copiedAudio: [String],
                               progress: ((Double) -> Void)?) throws {
        var manifest = "ffconcat version 1.0\n"
        var reference: StreamInfo?
        for (index, batch) in batches.enumerated() {
            try checkCancellation()
            let name = "part-\(index).mov"
            let part = staging.appendingPathComponent(name)
            let work = staging.appendingPathComponent("render-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: work) }
            let start = batch[0].outputStart
            let last = batch[batch.count - 1]
            let end = try last.outputStart.adding(last.to.subtracting(last.from))
            let weight = try end.subtracting(start).seconds
            try render(plan, inputs: batch, in: work, to: part, intermediate: true, copiedAudio: []) { fraction in
                progress?(0.9 * (start.seconds + weight * fraction) / plan.edit.duration.seconds)
            }
            // A concat stream carries the first sample description throughout.
            let media = try Probe.read(part, keyframes: true, cancelled: cancelled)
            guard media.frames.first?.keyframe == true,
                  reference.map({ $0.configuration == media.video.configuration &&
                      $0.timeBase == media.video.timeBase && $0.codecMetadata == media.video.codecMetadata }) ?? true else {
                throw CutError(code: "encode_failed", message: "The encoder changed picture configuration between export batches.")
            }
            reference = media.video
            // ffconcat offsets have a microsecond clock. Round cumulative output
            // ticks, then difference them, so sub-microsecond errors never accumulate.
            func microseconds(_ time: RationalTime) throws -> Int64 {
                try RationalTime(numerator: time.roundedToSamples(plan.timeScale),
                                 denominator: Int64(plan.timeScale)).roundedToSamples(1_000_000)
            }
            let micros = try microseconds(end) - microseconds(start)
            manifest += "file '\(name)'\nduration \(micros)us\n"
        }
        try manifest.write(to: staging.appendingPathComponent("parts.ffconcat"), atomically: true, encoding: .utf8)
        let source = batches[0][0].media
        var args = ["-xerror", "-copyts", "-f", "concat", "-safe", "1", "-i", "parts.ffconcat"]
        args += copiedAudio
        args += ["-map_metadata", "-1", "-map_chapters", "-1", "-map", "0:v:0", "-c:v", "copy"]
        var stagedOrdinal = 0
        for (index, pair) in zip(plan.audioActions, source.audio).enumerated() {
            let (action, audio) = pair
            if action.action == .removeAudio { continue }
            if plan.filtersAudio(action) {
                args += ["-map", "0:a:\(stagedOrdinal)", "-filter:a:\(index)", "asetpts=N/SR/TB"]
                stagedOrdinal += 1
            } else {
                args += ["-map", "1:a:\(index)"]
            }
            args += audioOptions(action.action, track: audio.stream, outputIndex: index,
                                 exactPCM: plan.exactPCM.contains(action.track))
        }
        if plan.edit.container != "mkv" {
            args += ["-movflags", "+faststart", "-video_track_timescale", "\(plan.timeScale)",
                     "-movie_timescale", "\(plan.movieTimeScale)"]
            if plan.settings.codec == .hevc { args += ["-tag:v", "hvc1"] }
        }
        args += ["-f", muxerName(plan.edit.container), partial.path]
        try runHelper(plan.helper, arguments: args, in: staging, duration: plan.edit.duration) { fraction in
            progress?(0.9 + 0.1 * fraction)
        }
    }

    private func render(_ plan: ReencodePlan, inputs: [ReencodeInput], in staging: URL, to partial: URL,
                        intermediate: Bool, copiedAudio: [String], progress: ((Double) -> Void)?) throws {
        let firstInput = inputs[0]
        let base = try firstInput.outputStart.roundedToSamples(plan.timeScale)
        var decoders: [DecoderInput] = []
        var decoderIndexes: [DecoderInput: Int] = [:]
        for input in inputs where decoderIndexes[input.decoder] == nil {
            decoderIndexes[input.decoder] = decoders.count
            decoders.append(input.decoder)
        }
        var extraInputs = copiedAudio
        let graph = try filterGraph(plan, inputs: inputs, decoders: decoderIndexes, base: base,
                                    hasStagedAudio: !extraInputs.isEmpty,
                                    in: staging, inputArguments: &extraInputs)
        do {
            try graph.write(to: staging.appendingPathComponent("filters.txt"), atomically: true, encoding: .utf8)
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        let container = intermediate ? "mov" : plan.edit.container
        var args = ["-map_chapters", "-1", "-map_metadata", "-1",
                 "-fps_mode", "passthrough", "-enc_time_base:v", "1:\(plan.timeScale)"]
        let last = inputs[inputs.count - 1]
        let upper = last.media.frames.lowerBound { $0.time >= last.to }
        let lastFrame = last.media.frames[upper - 1].time
        let end = try last.outputStart.adding(last.to.subtracting(last.from))
        let duration = try end.subtracting(firstInput.outputStart)
        let lastTicks = try last.outputStart.adding(lastFrame.subtracting(last.from)).roundedToSamples(plan.timeScale) - base
        let endTicks = try end.roundedToSamples(plan.timeScale) - base
        args += ["-bsf:v", "setts=duration='if(eq(PTS,\(lastTicks)),\(endTicks - lastTicks),DURATION)'"]
        args += plan.encoding.arguments
        if plan.settings.codec == .hevc, container != "mkv" { args += ["-tag:v", "hvc1"] }
        if container != "mkv" {
            // Only the published movie needs its metadata at the front. The
            // concat demuxer reads local batch files and can seek to the trailer.
            if !intermediate { args += ["-movflags", "+faststart"] }
            args += ["-video_track_timescale", "\(plan.timeScale)",
                     "-movie_timescale", "\(plan.movieTimeScale)"]
        }
        let reference = firstInput.media
        var outputTrack = 0
        for (index, pair) in zip(plan.audioActions, reference.audio).enumerated() {
            let (action, audio) = pair
            if action.action == .removeAudio { continue }
            if intermediate && !plan.filtersAudio(action) { continue }
            let map = plan.filtersAudio(action) ? "[sound\(index)]"
                : "\(copiedAudio.isEmpty ? 0 : decoders.count):a:\(index)"
            args += ["-map", map]
            if intermediate && action.action == .aac {
                // Keep the encoder's float input between batches. Encode AAC once
                // across the assembled recording, with one priming interval.
                args += ["-c:a:\(outputTrack)", "pcm_f32le"]
            } else {
                args += audioOptions(action.action, track: audio.stream, outputIndex: outputTrack,
                                     exactPCM: plan.exactPCM.contains(action.track))
            }
            outputTrack += 1
        }
        let preferred = ReencodeDecode.preferred(for: decoders.compactMap { plan.media[$0.file]?.video },
                                                 output: plan.encoding.pixelFormat)
        var lastProgress = 0.0
        func encode(_ route: ReencodeDecode) throws {
            var sources = ["-xerror", "-copyts", "-y"]
            for input in decoders {
                try checkCancellation()
                guard let media = plan.media[input.file] else {
                    throw CutError(code: "invalid_input", message: "A source is missing from the export plan.")
                }
                sources += ["-threads", "2"] + route.options(for: media.video)
                if let seek = input.seek {
                    sources += ["-seek_timestamp", "1", "-noaccurate_seek", "-ss", "\(seek)us"]
                }
                sources += ["-i", input.file.path]
            }
            // The encoder negotiates the picture format through the timing filters.
            let format = route == .surfaces ? "videotoolbox_vld" : plan.encoding.pixelFormat
            var filters = ["-filter_complex_threads", "2", "-/filter_complex", "filters.txt"]
            if let first = inputs.first, let media = plan.media[first.file], let rotate = route.rotationFilter(for: media.video) {
                filters += ["-filter_complex", "[picture]\(rotate)[oriented]", "-map", "[oriented]"]
            } else {
                filters += ["-map", "[picture]"]
            }
            let outputArgs = ["-pix_fmt", format, "-f", muxerName(container), partial.path]
            let report: ((Double) -> Void)? = progress.map { callback in
                { value in
                    if value > lastProgress {
                        lastProgress = value
                        callback(value)
                    }
                }
            }
            try runHelper(plan.helper, arguments: sources + extraInputs + filters + args + outputArgs, in: staging,
                          duration: duration, progress: report)
        }
        do {
            try encode(preferred)
        } catch let error as CutError where error.code == "encode_failed" {
            if let damage = try damagedPicture(error, inputs: decoders, plan: plan) { throw damage }
            // Hardware support varies by profile and Mac. Retry decoder/filter
            // failures using the compatibility path, reusing the staged audio.
            let reason = error.message.lowercased()
            guard preferred != .compatible,
                  ["decoder", "hwaccel", "videotoolbox", "auto_scale", "convert between the formats",
                   "filter network", "filtergraph", "transpose_vt"].contains(where: reason.contains),
                  !reason.contains("no space left"), !reason.contains("permission denied") else { throw error }
            do {
                try encode(.compatible)
            } catch let error as CutError where error.code == "encode_failed" {
                throw try damagedPicture(error, inputs: decoders, plan: plan) ?? error
            }
        }
    }

    /// Recognize a decoder that rejected one coded picture. The software HEVC decoder conceals
    /// such a picture without an error, so a rejection by VideoToolbox must end the export
    /// here and must not be retried in software.
    private func damagedPicture(_ error: CutError, inputs: [DecoderInput], plan: ReencodePlan) throws -> CutError? {
        let reason = error.message.lowercased()
        let hardware = reason.contains("hardware accelerator failed to decode picture")
        let software = reason.contains("corrupt decoded frame")
            || reason.contains("packet in decoder: invalid data found")
            || reason.contains("packet to decoder: invalid data found")
        guard hardware || software else { return nil }
        // The helper names the failing input as "vist#<input>:<stream>".
        var named: URL?
        for line in reason.split(separator: "\n") where line.contains("decoder") || line.contains("corrupt") {
            guard let mark = line.range(of: "vist#") else { continue }
            if let index = Int(line[mark.upperBound...].prefix(while: \.isNumber)), inputs.indices.contains(index) {
                named = inputs[index].file
            }
        }
        var files: [URL] = []
        for file in named.map({ [$0] }) ?? inputs.map(\.file) where !files.contains(file) { files.append(file) }
        if hardware {
            // A stream that VideoToolbox cannot decode at all fails at every keyframe. That is
            // a missing capability, which the compatibility path handles. One damaged picture
            // can make a single probe fail, so several keyframes are tried.
            for file in files {
                guard let media = plan.media[file] else { continue }
                let keys = media.frames.filter { $0.canStart && $0.time > .zero }
                var seeks: [Int64?] = [nil]
                for index in [keys.count / 3, 2 * keys.count / 3, keys.count - 1] where keys.indices.contains(index) {
                    let seek = try media.origin.adding(keys[index].time).roundedToSamples(1_000_000)
                    if !seeks.contains(seek) { seeks.append(seek) }
                }
                var decodes = false
                for seek in seeks where !decodes {
                    var probe = ["-xerror"] + ReencodeDecode.hardware.options(for: media.video)
                    if let seek { probe += ["-seek_timestamp", "1", "-noaccurate_seek", "-ss", "\(seek)us"] }
                    probe += ["-i", file.path, "-map", "0:\(media.video.index)", "-frames:v", "1", "-f", "null", "-"]
                    do {
                        try runHelper(plan.helper, arguments: probe, in: FileManager.default.temporaryDirectory)
                        decodes = true
                    } catch let failure as CutError where failure.code == "encode_failed" {
                        continue
                    }
                }
                if !decodes { return nil }
            }
        }
        let name = files.count == 1 ? files[0].lastPathComponent : "a source"
        return CutError(code: "encode_failed",
                        message: "A picture in \(name) is damaged and could not be decoded. "
                            + "Re-encode decodes from before each selected range. Choose a range away from the damage.")
    }

    private func filterInputs(_ plan: ReencodePlan) throws -> [ReencodeInput] {
        var inputs: [ReencodeInput] = []
        for (index, segment) in plan.edit.segments.enumerated() {
            try checkCancellation()
            guard let media = plan.media[segment.file] else {
                throw CutError(code: "invalid_input", message: "A source is missing from the export plan.")
            }
            // Consecutive ranges from the same source can share one decoder
            // when their clock fits in the output clock without rounding.
            if let previous = inputs.last, previous.file == segment.file, previous.to == segment.from,
               Int64(plan.timeScale) % media.video.timeBase.denominator == 0 {
                inputs[inputs.count - 1].to = segment.to
            } else {
                let decoder = DecoderInput(file: segment.file, seek: try seekAnchor(segment.from, media: media))
                inputs.append(ReencodeInput(decoder: decoder, segment: index + 1, media: media, from: segment.from,
                                            to: segment.to, outputStart: segment.outputStart))
            }
        }
        return inputs
    }

    private func seekAnchor(_ from: RationalTime, media: MediaInfo) throws -> Int64? {
        let preroll = RationalTime(numerator: 2)
        guard from > preroll, media.format.split(separator: ",").contains("mov"),
              !media.video.multipleDescriptions,
              media.audio.allSatisfy({ $0.presentationEdits.isEmpty }) else { return nil }
        let target = try from.subtracting(preroll)
        let end = media.frames.lowerBound { $0.time > target }
        // This is a seek optimization only. Leave sufficient decode history
        // before the cut, and allow the filters to trim on the original clock.
        guard let frame = media.frames[..<end].last(where: { $0.canStart }),
              frame.time > .zero else { return nil }
        let absolute = try media.origin.adding(frame.time).roundedToSamples(1_000_000)
        return absolute > 0 ? absolute : nil
    }

    private func filterGraph(_ plan: ReencodePlan, inputs: [ReencodeInput], decoders: [DecoderInput: Int], base: Int64,
                             hasStagedAudio: Bool, in staging: URL,
                             inputArguments: inout [String]) throws -> String {
        var filters: [String] = []
        let scale = plan.timeScale
        var nextInput = decoders.count + (hasStagedAudio ? 1 : 0)
        for (index, segment) in inputs.enumerated() {
            try checkCancellation()
            let media = segment.media

            let absoluteStart = try media.origin.adding(segment.from)
            let absoluteEnd = try media.origin.adding(segment.to)
            let start = try absoluteStart.roundedToSamples(scale)
            let end = try absoluteEnd.roundedToSamples(scale)
            let offset = try segment.outputStart.roundedToSamples(scale) - base
            let decoder = decoders[segment.decoder]!
            let videoInput = "[\(decoder):\(media.video.index)]"
            let range = "settb=1/\(scale),trim=start_pts=\(start):end_pts=\(end)"
            let pictureOutput = inputs.count == 1 ? "[picture]" : "[p\(index)]"
            filters.append("\(videoInput)\(range),setpts=PTS-(\(start))+\(offset)\(pictureOutput)")

            for (position, action) in plan.audioActions.enumerated() where plan.filtersAudio(action) {
                let audio = media.audio[position]
                let track = audio.stream
                let rate = track.sampleRate
                let inputStart = try absoluteStart.roundedToSamples(rate)
                let inputEnd = try absoluteEnd.roundedToSamples(rate)
                let outputStart = try segment.outputStart.roundedToSamples(rate)
                let outputEnd = try segment.outputStart.adding(segment.to.subtracting(segment.from)).roundedToSamples(rate)
                let count = outputEnd - outputStart
                guard count > 0 else {
                    throw CutError(code: "unsupported_audio", message: "The selected range is shorter than one audio sample.",
                                   segment: segment.segment, track: track.index)
                }
                let input = "[\(decoder):\(track.index)]"
                let label = inputs.count == 1 ? "[sound\(position)]" : "[s\(position)_\(index)]"
                let trim = "\(input)asettb=1/\(rate),atrim=start_pts=\(inputStart):end_pts=\(inputEnd)"
                if !audio.presentationEdits.isEmpty {
                    let layout = try audioLayout(track)
                    let samples = inputStart..<inputEnd
                    if !samples.isEmpty, audio.presentationEdits.contains(where: { $0.isAudible && $0.samples.overlaps(samples) }) {
                        let caf = staging.appendingPathComponent("sound-\(index)-\(position).caf")
                        try stageEditedAudio(segment.file, track: track, source: samples,
                                             count: count, to: caf, segment: segment.segment)
                        inputArguments += ["-i", caf.path]
                        filters.append("[\(nextInput):a:0]aformat=channel_layouts=\(layout),asetpts=N/SR/TB\(label)")
                        nextInput += 1
                    } else {
                        filters.append("anullsrc=r=\(rate):cl=\(layout),atrim=end_sample=\(count),asetpts=N/SR/TB\(label)")
                    }
                } else if plan.exactPCM.contains(action.track) {
                    filters.append("\(trim),asetpts=N/SR/TB\(label)")
                } else {
                    filters.append("\(trim),asetpts=PTS-(\(inputStart)),"
                        + "aresample=\(rate):async=1:first_pts=0:min_hard_comp=0,"
                        + "apad=whole_len=\(count),atrim=end_sample=\(count),asetpts=N/SR/TB\(label)")
                }
            }
        }
        if inputs.count > 1 {
            let pictures = inputs.indices.map { "[p\($0)]" }.joined()
            filters.append("\(pictures)interleave=n=\(inputs.count),settb=1/\(scale)[picture]")
            for (index, action) in plan.audioActions.enumerated() where plan.filtersAudio(action) {
                let tracks = inputs.indices.map { "[s\(index)_\($0)]" }.joined()
                filters.append("\(tracks)concat=n=\(inputs.count):v=0:a=1,asetpts=N/SR/TB[sound\(index)]")
            }
        }
        return filters.joined(separator: ";\n")
    }
}

private extension ReencodePlan {
    func filtersAudio(_ action: ReencodeAudioAction) -> Bool {
        [.aac, .pcm].contains(action.action) || exactPCM.contains(action.track)
    }
}

func muxerName(_ container: String) -> String { container == "mkv" ? "matroska" : container }

func audioLayout(_ track: StreamInfo) throws -> String {
    let layout = track.channelLayout
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789().+_-")
    if !layout.isEmpty, layout.unicodeScalars.allSatisfy(allowed.contains) { return layout }
    if track.channels == 1 { return "mono" }
    if track.channels == 2 { return "stereo" }
    throw CutError(code: "unsupported_audio", message: "Audio track \(track.index) has an unspecified or unsupported channel layout.",
                   track: track.index)
}

func audioOptions(_ action: ReencodeAudio, track: StreamInfo, outputIndex: Int, exactPCM: Bool) -> [String] {
    let specifier = "a:\(outputIndex)"
    let codec: String
    switch action {
    // The bundled FFmpeg has only little-endian PCM encoders. MOV stores either byte order, and the samples are identical.
    case .copyOriginal: codec = exactPCM ? track.codec.replacingOccurrences(of: "be", with: "le", options: [.anchored, .backwards]) : "copy"
    case .aac: codec = "aac"
    case .pcm: codec = track.codec.contains("f32") ? "pcm_f32le" : "pcm_s32le"
    default: return []
    }
    var args = ["-c:\(specifier)", codec, "-metadata:s:\(specifier)", "language=\(track.language)",
                "-disposition:\(specifier)", "\(track.disposition)"]
    if action == .aac { args += ["-b:\(specifier)", "\(max(96, min(512, track.channels * 96)))k"] }
    if action != .copyOriginal { args += ["-ar:\(specifier)", "\(track.sampleRate)"] }
    return args
}
