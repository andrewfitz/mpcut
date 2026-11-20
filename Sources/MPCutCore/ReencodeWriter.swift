import Darwin
import Foundation
import PacketWriter

private struct ReencodeInput {
    let segment: Int
    let file: URL
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
        let preferred = ReencodeDecode.preferred(for: plan.media.values.map(\.video), output: plan.encoding.pixelFormat)
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
        let graph = try filterGraph(plan, inputs: inputs, hasStagedAudio: !extraInputs.isEmpty,
                                    in: staging, inputArguments: &extraInputs)
        do {
            try graph.write(to: staging.appendingPathComponent("filters.txt"), atomically: true, encoding: .utf8)
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        let container = plan.edit.container
        var args = ["-map_chapters", "-1", "-map_metadata", "-1",
                 "-fps_mode", "passthrough", "-enc_time_base:v", "1:\(plan.timeScale)"]
        if let last = plan.edit.segments.last, let lastFrame = last.lastVideoFrame {
            let presentation = try last.outputStart.adding(lastFrame.subtracting(last.from))
            let lastTicks = try presentation.roundedToSamples(plan.timeScale)
            let endTicks = try plan.edit.duration.roundedToSamples(plan.timeScale)
            args += ["-bsf:v", "setts=duration='if(eq(PTS,\(lastTicks)),\(endTicks - lastTicks),DURATION)'"]
        }
        args += plan.encoding.arguments
        if plan.settings.codec == .hevc, container != "mkv" { args += ["-tag:v", "hvc1"] }
        if container != "mkv" {
            args += ["-movflags", "+faststart", "-video_track_timescale", "\(plan.timeScale)",
                     "-movie_timescale", "1000000"]
        }
        if let first = plan.edit.segments.first, let reference = plan.media[first.file] {
            for (index, pair) in zip(plan.audioActions, reference.audio).enumerated() {
                let (action, audio) = pair
                if action.action == .removeAudio { continue }
                let exactPCM = plan.exactPCM.contains(action.track)
                let map = action.action == .copyOriginal && !exactPCM
                    ? "\(directAudio ? 0 : inputs.count):a:\(index)"
                    : "[sound\(index)]"
                args += ["-map", map]
                args += audioOptions(action.action, track: audio.stream, outputIndex: index, exactPCM: exactPCM)
            }
        }
        var lastProgress = 0.0
        func encode(_ route: ReencodeDecode) throws {
            var sources = ["-xerror", "-copyts", "-y"]
            for input in inputs {
                try checkCancellation()
                guard let media = plan.media[input.file] else {
                    throw CutError(code: "invalid_input", message: "A source is missing from the export plan.")
                }
                sources += ["-threads", "2"] + route.options(for: media.video)
                if let seek = try seekAnchor(input.from, media: media) {
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
                          duration: plan.edit.duration, progress: report)
        }
        do {
            try encode(preferred)
        } catch let error as CutError where preferred != .compatible && error.code == "encode_failed" {
            // Hardware support varies by profile and Mac. Retry decoder/filter
            // failures using the compatibility path, reusing the staged audio.
            let reason = error.message.lowercased()
            guard ["decoder", "hwaccel", "videotoolbox", "auto_scale", "convert between the formats",
                   "filter network", "filtergraph", "transpose_vt"].contains(where: reason.contains),
                  !reason.contains("no space left"), !reason.contains("permission denied") else { throw error }
            try encode(.compatible)
        }
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
        guard renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw CutError(code: "output_exists", message: "A file already exists at the destination.") }
            throw CutError(code: "write_failed", message: String(cString: strerror(errno)))
        }
        progress?(1)
    }

    private func filterInputs(_ plan: ReencodePlan) throws -> [ReencodeInput] {
        var inputs: [ReencodeInput] = []
        for (index, segment) in plan.edit.segments.enumerated() {
            try checkCancellation()
            // Consecutive ranges from the same source can share one decoder
            // when their clock fits in the output clock without rounding.
            if let previous = inputs.last, previous.file == segment.file, previous.to == segment.from,
               let media = plan.media[segment.file], Int64(plan.timeScale) % media.video.timeBase.denominator == 0 {
                inputs[inputs.count - 1].to = segment.to
            } else {
                inputs.append(ReencodeInput(segment: index + 1, file: segment.file, from: segment.from,
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

    private func filterGraph(_ plan: ReencodePlan, inputs: [ReencodeInput], hasStagedAudio: Bool, in staging: URL,
                             inputArguments: inout [String]) throws -> String {
        var filters: [String] = []
        let scale = plan.timeScale
        var nextInput = inputs.count + (hasStagedAudio ? 1 : 0)
        for (index, segment) in inputs.enumerated() {
            try checkCancellation()
            guard let media = plan.media[segment.file] else {
                throw CutError(code: "invalid_input", message: "A source is missing from the export plan.")
            }

            let absoluteStart = try media.origin.adding(segment.from)
            let absoluteEnd = try media.origin.adding(segment.to)
            let start = try absoluteStart.roundedToSamples(scale)
            let end = try absoluteEnd.roundedToSamples(scale)
            let offset = try segment.outputStart.roundedToSamples(scale)
            let videoInput = "[\(index):\(media.video.index)]"
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
                let input = "[\(index):\(track.index)]"
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
