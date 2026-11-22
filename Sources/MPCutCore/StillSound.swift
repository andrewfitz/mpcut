import Foundation

public struct StillSoundAction: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public let file: URL
        public let stream: Int
        public let input: MulticamRange
        public let output: MulticamRange
    }

    public let ordinal: Int
    public let audio: ReencodeAudio
    public let originalStreams: [Int]
    public let sources: [Source]
    public let warnings: [String]
    public let generatedSilence: [MulticamRange]
}

struct StillSoundPlan: Sendable {
    enum Treatment: Sendable {
        case copy(ResolvedEdit, program: Bool)
        case convert(MulticamAudioConversionPlan)

        var edit: ResolvedEdit {
            switch self {
            case .copy(let edit, _): return edit
            case .convert(let plan): return plan.edit
            }
        }
    }

    let actions: [StillSoundAction]
    let treatments: [Treatment]
    let container: String

    func verifySources() throws {
        for treatment in treatments {
            for (file, identity) in treatment.edit.identities where !identity.isCurrentSnapshot(at: file) {
                throw CutError(code: "source_changed", message: "The soundtrack source changed after export planning: \(file.path)")
            }
        }
    }
}

struct StillSoundPlanner {
    var cancelled: (@Sendable () -> Bool)?

    func resolve(_ project: CutProject, relativeTo location: URL?, timeline: StillTimelinePlan,
                 tracks: ExportTracks, audioStream: Int?, audioTrackOrdinal: Int? = nil, mode: ExportMode, audio: ReencodeAudio,
                 container: String) throws -> StillSoundPlan {
        let muxer = ExportRules.multicamMuxContainer(container)
        if tracks == .video || audio == .removeAudio {
            return StillSoundPlan(actions: [], treatments: [], container: muxer)
        }
        let lanes: [[ConvertedSoundSpan]]
        let followsMulticamRouting: Bool
        let silenceFormats: [ConvertedSoundFormat]
        switch project {
        case .multicam(let multicam):
            guard audioStream == nil, audioTrackOrdinal == nil else {
                throw CutError(code: "invalid_arguments", message: "A multicam program uses its selected microphone routing.")
            }
            followsMulticamRouting = true
            let (routed, format) = try multicamLanes(multicam, relativeTo: location, timeline: timeline)
            lanes = routed
            silenceFormats = [format].compactMap { $0 }
        case .sequence, .stillSequence:
            followsMulticamRouting = false
            if case .stillSequence(let sequence) = project, let template = sequence.stillAudioReference,
               timeline.spans.allSatisfy({ $0.origin == .insert }) {
                let file = try ProjectFile.checkedSourceURL(file: template.file, in: projectDirectory(location))
                let media = try CutEngine(cancelled: cancelled).inspect(file)
                let streams = try selectedAudioStreams(media, stream: audioStream, ordinal: audioTrackOrdinal)
                silenceFormats = try streams.map { stream in
                    guard let audio = media.audio.first(where: { $0.stream.index == stream }) else {
                        throw CutError(code: "missing_audio", message: "The selected soundtrack cannot establish a format.", track: stream)
                    }
                    return ConvertedSoundFormat(media: media, audio: audio)
                }
                let inserts = timeline.spans.map {
                    ConvertedSoundSpan(media: nil, stream: nil, input: $0.output, output: $0.output)
                }
                lanes = Array(repeating: inserts, count: streams.count)
            } else {
                silenceFormats = []
                lanes = try sequenceLanes(project, relativeTo: location, timeline: timeline, audioStream: audioStream,
                                          audioTrackOrdinal: audioTrackOrdinal)
            }
        }
        if tracks == .audio && lanes.isEmpty {
            throw CutError(code: "no_audio", message: "The program has no selected audio tracks.")
        }
        guard lanes.count <= 1 || ["mov", "mp4", "m4a", "mkv", "mka", "webm"].contains(muxer) else {
            throw CutError(code: "unsupported_container", message: "Choose a container that carries multiple audio tracks.")
        }

        var actions: [StillSoundAction] = []
        var treatments: [StillSoundPlan.Treatment] = []
        for (ordinal, lane) in lanes.enumerated() {
            let silenceFormat = silenceFormats.indices.contains(ordinal) ? silenceFormats[ordinal] : nil
            let spans = try coalesce(lane, duration: timeline.duration)
            let sources: [StillSoundAction.Source] = spans.compactMap { span in
                guard let media = span.media, let stream = span.stream else { return nil }
                return .init(file: media.url, stream: stream, input: span.input, output: span.output)
            }
            let streams = (spans.compactMap(\.stream) + [silenceFormat?.audio.stream.index].compactMap { $0 }).reduce(into: [Int]()) { list, stream in
                if !list.contains(stream) { list.append(stream) }
            }
            let explicitConversion = audio == .aac || audio == .pcm
            let allowsAutomaticConversion = mode == .encode && audio == .auto
            let pcmSource: StreamInfo? = mode == .smart && audio == .auto && ["mov", "wav", "wave", "caf"].contains(muxer)
                && spans.contains(where: { $0.media == nil }) ? compatiblePCM(in: spans, format: silenceFormat) : nil
            func append(_ treatment: StillSoundPlan.Treatment, audio: ReencodeAudio,
                        silence: [MulticamRange] = [], warnings: [String] = []) {
                treatments.append(treatment)
                actions.append(StillSoundAction(ordinal: ordinal, audio: audio, originalStreams: streams,
                                                sources: sources, warnings: warnings, generatedSilence: silence))
            }
            var copyFailure: CutError?
            if mode != .encode || !explicitConversion {
                do {
                    let copy = try resolveCopy(spans, duration: timeline.duration, container: muxer,
                                               allowsSourceExtent: !followsMulticamRouting)
                    append(copy, audio: .copyOriginal)
                    continue
                } catch let issue as CutError where issue.code != "cancelled" {
                    guard mode != .copy, explicitConversion || allowsAutomaticConversion ||
                            (pcmSource != nil && ["generated_audio_required", "unsafe_boundary"].contains(issue.code)) else {
                        throw trackIssue(issue, ordinal: ordinal)
                    }
                    copyFailure = issue
                }
            }
            let conversionLane = followsMulticamRouting ? spans : try conversionSpans(spans)
            let candidates: [ReencodeAudio] = allowsAutomaticConversion ? [.aac, .pcm] : [pcmSource == nil ? audio : .pcm]
            var sound = try resolveConversion(conversionLane, duration: timeline.duration, container: muxer,
                                              candidates: candidates, ordinal: ordinal, format: silenceFormat)
            if let pcmSource {
                // Check actual per-span retained sample counts before accepting lossless PCM.
                guard sound.sampleRate == pcmSource.sampleRate, sound.warnings.isEmpty,
                      sound.inputs.allSatisfy({ $0.silence || $0.count == $0.samples.upperBound - $0.samples.lowerBound }) else {
                    throw trackIssue(copyFailure ?? CutError(code: "unsafe_boundary", message: "Silence changes the PCM sample alignment."),
                                     ordinal: ordinal)
                }
                sound.encoderArguments = ["-c:a", pcmSource.codec]
            }
            switch muxer {
            case "m4a": sound.muxer = "ipod"
            case "wave": sound.muxer = "wav"
            default: break
            }
            sound.verifiesSampleRange = true
            let warnings: [String]
            if pcmSource != nil {
                warnings = [sources.isEmpty ? "The output track contains PCM digital silence." :
                    "Retained PCM samples are preserved. Inserted intervals receive digital silence."]
            } else {
                warnings = copyFailure.map { [$0.message] } ?? []
            }
            append(.convert(sound), audio: sound.action, silence: conversionLane.filter { $0.media == nil }.map(\.output),
                   warnings: warnings + sound.warnings)
        }
        let plan = StillSoundPlan(actions: actions, treatments: treatments, container: muxer)
        try plan.verifySources()
        return plan
    }

    func write(_ plan: StillSoundPlan, in staging: URL,
               progress: ((Double) -> Bool)? = nil) throws -> [URL] {
        let engine = CutEngine(cancelled: cancelled)
        try plan.verifySources()
        let interruption = StillSoundInterruption()
        let converter = MulticamEngine(cancelled: { [cancelled] in cancelled?() == true || interruption.stopped })
        for index in plan.treatments.indices {
            let trackFolder = folder(in: staging, ordinal: index)
            try FileManager.default.createDirectory(at: trackFolder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let count = Double(plan.treatments.count)
        return try plan.treatments.enumerated().map { index, treatment in
            let output = folder(in: staging, ordinal: index).appendingPathComponent("track")
                .appendingPathExtension(plan.container)
            switch treatment {
            case .copy(let edit, let program):
                try engine.export(edit, to: output, audioOnly: true, programAudio: program) { fraction in
                    progress?((Double(index) + fraction) / count) ?? true
                }
            case .convert(let conversion):
                try converter.writeConvertedSound(conversion, to: output) { fraction in
                    if progress?((Double(index) + fraction) / count) == false { interruption.stop() }
                }
                if interruption.stopped { throw CutError(code: "cancelled", message: "The operation was cancelled.") }
            }
            return output
        }
    }

    private func folder(in staging: URL, ordinal: Int) -> URL {
        staging.appendingPathComponent("sound-\(ordinal)", isDirectory: true)
    }

    private func trackIssue(_ issue: CutError, ordinal: Int) -> CutError {
        CutError(code: issue.code, message: "Audio track \(ordinal + 1): \(issue.message)",
                 segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest, track: issue.track ?? ordinal,
                 multicam: issue.multicam).because(issue.reason)
    }

    private func resolveConversion(_ lane: [ConvertedSoundSpan], duration: RationalTime, container: String,
                                   candidates: [ReencodeAudio], ordinal: Int,
                                   format: ConvertedSoundFormat?) throws -> MulticamAudioConversionPlan {
        var failure = CutError(code: "unsupported_container",
                               message: "\(container.uppercased()) cannot carry the selected sample-exact audio conversion.")
        let converter = MulticamEngine(cancelled: cancelled)
        for action in candidates where conversionAllowed(action, container: container) {
            do {
                return try converter.resolveConvertedSound(lane, duration: duration, container: container,
                                                           action: action, allowsSilence: true, silenceFormat: format) { issue, _ in issue }
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                failure = issue
            }
        }
        throw trackIssue(failure, ordinal: ordinal)
    }

    private func conversionAllowed(_ action: ReencodeAudio, container: String) -> Bool {
        switch action {
        case .aac: return ["mov", "mp4", "m4a"].contains(container)
        case .pcm: return ["mov", "mkv", "wav", "wave", "caf"].contains(container)
        default: return false
        }
    }

    private func compatiblePCM(in spans: [ConvertedSoundSpan], format: ConvertedSoundFormat?) -> StreamInfo? {
        let sources = spans.filter { $0.media != nil }
        let inputs = sources.compactMap { span in
            span.media?.audio.first { $0.stream.index == span.stream }
        }
        guard inputs.count == sources.count,
              let first = inputs.first?.stream ?? format?.audio.stream,
              ["pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
               "pcm_f32le", "pcm_f32be", "pcm_u8", "pcm_s8"].contains(first.codec),
              inputs.allSatisfy({ $0.pcmContinuity && $0.presentationEdits.isEmpty &&
                  $0.stream.codec == first.codec && $0.stream.sampleRate == first.sampleRate &&
                  $0.stream.channels == first.channels &&
                  $0.stream.canonicalChannelLayout == first.canonicalChannelLayout }) else { return nil }
        return first
    }

    private func sequenceLanes(_ project: CutProject, relativeTo location: URL?, timeline: StillTimelinePlan,
                               audioStream: Int?, audioTrackOrdinal: Int?) throws -> [[ConvertedSoundSpan]] {
        let engine = CutEngine(cancelled: cancelled)
        let clips = Dictionary(uniqueKeysWithValues: (project.sequenceClips ?? []).map { ($0.id, $0) })
        let directory = projectDirectory(location)
        var mediaByFile: [String: MediaInfo] = [:]
        var lanes: [[ConvertedSoundSpan]] = []
        var leading: [ConvertedSoundSpan] = []
        var expected: Int?
        for (index, span) in timeline.spans.enumerated() {
            try engine.checkCancellation()
            switch span.origin {
            case .insert:
                let silence = ConvertedSoundSpan(media: nil, stream: nil, input: span.output, output: span.output)
                if expected == nil { leading.append(silence) }
                for ordinal in lanes.indices { lanes[ordinal].append(silence) }
            case .source(let id, let range):
                guard let clip = clips[id] else {
                    throw CutError(code: "invalid_cut_project", message: "A source occurrence is unavailable.", segment: index + 1)
                }
                let media: MediaInfo
                if let known = mediaByFile[clip.file] {
                    media = known
                } else {
                    let file = try ProjectFile.checkedSourceURL(file: clip.file, in: directory)
                    media = try engine.inspect(file)
                    mediaByFile[clip.file] = media
                }
                let streams = try selectedAudioStreams(media, stream: audioStream, ordinal: audioTrackOrdinal,
                                                       segment: index + 1)
                if let expected {
                    guard streams.count == expected else {
                        throw CutError(code: "incompatible_tracks", message: "The number of audio tracks changes between source occurrences.",
                                       segment: index + 1)
                    }
                } else {
                    expected = streams.count
                    lanes = Array(repeating: leading, count: streams.count)
                    leading.removeAll()
                }
                for (ordinal, stream) in streams.enumerated() {
                    lanes[ordinal].append(ConvertedSoundSpan(media: media, stream: stream, input: range, output: span.output))
                }
            case .group:
                throw CutError(code: "invalid_cut_project", message: "A sequence contains a multicam range.")
            }
        }
        return lanes
    }

    private func projectDirectory(_ location: URL?) -> URL {
        location.map(ProjectFile.directory(of:))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private func selectedAudioStreams(_ media: MediaInfo, stream: Int?, ordinal: Int?,
                                      segment: Int? = nil) throws -> [Int] {
        let available = media.streams.filter { $0.kind == "audio" }.map(\.index)
        if let stream {
            guard available.contains(stream) else {
                throw CutError(code: "no_audio", message: "The source has no matching audio stream.",
                               segment: segment, track: stream)
            }
            return [stream]
        }
        if let ordinal {
            guard available.indices.contains(ordinal) else {
                throw CutError(code: "no_audio", message: "The source has no matching audio track position.",
                               segment: segment, track: ordinal)
            }
            return [available[ordinal]]
        }
        return available
    }

    private func multicamLanes(_ project: MulticamProject, relativeTo location: URL?,
                               timeline: StillTimelinePlan) throws -> ([[ConvertedSoundSpan]], ConvertedSoundFormat?) {
        let mapping = try project.plan()
        let engine = CutEngine(cancelled: cancelled)
        let multicam = MulticamEngine(cancelled: cancelled)
        let sources = Dictionary(uniqueKeysWithValues: (project.angles + project.audioSources).map { ($0.id, $0) })
        var mediaByURL: [URL: MediaInfo] = [:]
        var lane: [ConvertedSoundSpan] = []
        var silenceFormat: ConvertedSoundFormat?
        if mapping.audio.isEmpty {
            guard mapping.intervals.isEmpty else { return ([], nil) }
            let reference: MulticamAudioSelection?
            switch project.audio {
            case .fixed(let selection): reference = selection
            case .follow:
                reference = project.angles.compactMap { angle in
                    angle.audioStream.map { MulticamAudioSelection(source: angle.id, stream: $0) }
                }.first ?? project.switches.compactMap(\.audio).first
            case .none: reference = project.switches.compactMap(\.audio).first
            }
            guard let reference, let source = sources[reference.source] else { return ([], nil) }
            let file = multicam.sourceURL(source, project: project, location: location)
            let media = try engine.inspectMulticamSource(file)
            guard let audio = media.audio.first(where: { $0.stream.index == reference.stream }) else {
                throw CutError(code: "missing_audio", message: "The selected microphone cannot establish a soundtrack format.",
                               track: reference.stream)
            }
            silenceFormat = ConvertedSoundFormat(media: media, audio: audio)
        }
        for span in mapping.audio {
            try engine.checkCancellation()
            guard let source = sources[span.source], let stream = span.stream else {
                throw CutError(code: "missing_audio", message: "A multicam sound selection has no source or stream index.")
            }
            let file = multicam.sourceURL(source, project: project, location: location)
            guard !file.path.split(separator: "/").contains("..") else {
                throw CutError(code: "missing_source", message: "Source \(source.id) has an unavailable parent directory: \(file.path).")
            }
            let media = try mediaByURL[file] ?? engine.inspectMulticamSource(file)
            mediaByURL[file] = media
            lane.append(ConvertedSoundSpan(media: media, stream: stream, input: span.input, output: span.output))
        }
        for part in timeline.spans {
            if case .insert = part.origin {
                lane.append(ConvertedSoundSpan(media: nil, stream: nil, input: part.output, output: part.output))
            }
        }
        return ([lane.sorted { $0.output.from < $1.output.from }], silenceFormat)
    }

    private func coalesce(_ lane: [ConvertedSoundSpan], duration: RationalTime) throws -> [ConvertedSoundSpan] {
        var result: [ConvertedSoundSpan] = []
        var end = RationalTime.zero
        for span in lane {
            guard span.output.from == end else {
                throw CutError(code: "uncovered_audio", message: "The selected soundtrack leaves an uncovered program interval.")
            }
            if let last = result.last, let source = last.media, let media = span.media,
               source.url == media.url, source.identity == media.identity, last.stream == span.stream,
               last.input.to == span.input.from {
                result[result.count - 1] = ConvertedSoundSpan(media: media, stream: span.stream,
                    input: MulticamRange(from: last.input.from, to: span.input.to),
                    output: MulticamRange(from: last.output.from, to: span.output.to))
            } else {
                result.append(span)
            }
            end = span.output.to
        }
        guard end == duration else {
            throw CutError(code: "uncovered_audio", message: "The selected soundtrack does not end at the program boundary.")
        }
        return result
    }

    private func conversionSpans(_ spans: [ConvertedSoundSpan]) throws -> [ConvertedSoundSpan] {
        var result: [ConvertedSoundSpan] = []
        for span in spans {
            guard let media = span.media, let sound = media.audio.first(where: { $0.stream.index == span.stream }) else {
                result.append(span)
                continue
            }
            let bounds = try sound.audibleBounds(origin: media.origin)
            let start = max(span.input.from, bounds.lowerBound)
            let end = min(span.input.to, bounds.upperBound)
            if start >= end {
                result.append(ConvertedSoundSpan(media: nil, stream: nil, input: span.output, output: span.output))
                continue
            }
            let outputStart = try span.output.from.adding(start.subtracting(span.input.from))
            let outputEnd = try span.output.from.adding(end.subtracting(span.input.from))
            if outputStart > span.output.from {
                let silence = MulticamRange(from: span.output.from, to: outputStart)
                result.append(ConvertedSoundSpan(media: nil, stream: nil, input: silence, output: silence))
            }
            result.append(ConvertedSoundSpan(media: media, stream: sound.stream.index, input: MulticamRange(from: start, to: end),
                                             output: MulticamRange(from: outputStart, to: outputEnd)))
            if outputEnd < span.output.to {
                let silence = MulticamRange(from: outputEnd, to: span.output.to)
                result.append(ConvertedSoundSpan(media: nil, stream: nil, input: silence, output: silence))
            }
        }
        return result
    }

    private func resolveCopy(_ lane: [ConvertedSoundSpan], duration: RationalTime,
                             container: String, allowsSourceExtent: Bool) throws -> StillSoundPlan.Treatment {
        let engine = CutEngine(cancelled: cancelled, tracks: .audio)
        let multicam = MulticamEngine(cancelled: cancelled)
        var reference: MediaInfo?
        var identities: [URL: SourceIdentity] = [:]
        var silentAAC: [Int: Int] = [:]
        var audibleAAC = Set<Int>()
        var segments: [ResolvedSegment] = []
        var wholeFile = false
        for (index, span) in lane.enumerated() {
            try engine.checkCancellation()
            guard let media = span.media, let stream = span.stream else {
                throw CutError(code: "generated_audio_required",
                               message: "The inserted still needs silence at \(span.output.from)–\(span.output.to). Choose AAC or PCM sound conversion.",
                               segment: index + 1, track: reference?.audio.first?.stream.index ?? lane.compactMap(\.stream).first)
            }
            let selector = CutEngine(cancelled: cancelled, tracks: .audio, audioStream: stream)
            let selected = try selector.selectedMedia(media)
            guard let sound = selected.audio.first else {
                throw CutError(code: "missing_audio", message: "The selected soundtrack is unavailable.", track: stream)
            }
            if let issue = selected.audioIssues[stream] ?? selected.copyIssue,
               !issue.hasPrefix("The video "), !issue.hasPrefix("A ProRes "),
               !issue.hasPrefix("RAW video"), issue != "Multiple video tracks are unsupported." {
                throw CutError(code: "unsupported_tracks", message: issue, segment: index + 1, track: stream)
            }
            if let issue = selector.muxIssue(selected, container: container) {
                throw CutError(code: "unsupported_container", message: issue, segment: index + 1, track: stream)
            }
            if let reference {
                try engine.checkCompatibility(selected, with: reference)
            } else {
                reference = selected
            }
            let from = span.input.from
            let to = span.input.to
            let first = index == 0
            let last = index == lane.count - 1
            wholeFile = allowsSourceExtent && first && last && from == .zero && to == media.duration
            if !wholeFile {
                if container == "flac" {
                    throw CutError(code: "unsupported_container",
                                   message: "Choose Matroska Audio to copy edited FLAC packets.",
                                   segment: index + 1, track: stream)
                }
                try multicam.checkSoundBoundary(input: from, output: span.output.from, media: selected, start: true,
                                               first: first, last: last, container: container, segment: index + 1)
                try multicam.checkSoundBoundary(input: to, output: span.output.to, media: selected, start: false,
                                               first: first, last: last, container: container, segment: index + 1)
                try multicam.checkProgramPackets(sound, media: selected, from: from, to: to,
                                                 single: first && last, container: container)
            }
            let windows = try engine.trackWindows(selected, from: from, to: to, outputStart: span.output.from,
                                                  outputEnd: span.output.to, first: first, last: last,
                                                  whole: wholeFile, container: container, segment: index + 1,
                                                  silentAACSegments: &silentAAC, audibleAACTracks: &audibleAAC)
            if !allowsSourceExtent, let window = windows.first,
               window.outputStart != span.output.from || window.outputEnd != span.output.to {
                throw CutError(code: "uncovered_audio", message: "The selected microphone cannot preserve its exact program interval.",
                               segment: index + 1, track: stream)
            }
            segments.append(ResolvedSegment(file: selected.url, from: from, to: to, outputStart: span.output.from,
                                            tracks: windows, sourceOrigin: selected.origin, reachesEnd: wholeFile))
            identities[selected.url] = selected.identity
        }
        if audibleAAC.isEmpty, let first = silentAAC.values.min() {
            throw CutError(code: "unsafe_boundary", message: "The selected AAC program contains only empty presentation edits.",
                           segment: first, track: lane[first - 1].stream)
        }
        let edit = ResolvedEdit(segments: segments, duration: duration, container: container, identities: identities,
                                tracks: .audio, usesPerSourceAudioStream: true)
        return .copy(edit, program: !wholeFile)
    }
}

private final class StillSoundInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}
