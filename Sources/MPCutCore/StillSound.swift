import Foundation

public struct StillSoundAction: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public let file: URL
        public let stream: Int
        public let input: MulticamRange
        public let output: MulticamRange
        public var codec: String? = nil
    }

    public let ordinal: Int
    public var laneID: String? = nil
    public var label: String? = nil
    public var colorSlot: Int? = nil
    public var sourceLaneIDs: [String]? = nil
    public var codec: String? = nil
    public var sampleRate: Int? = nil
    public var channelLayout: String? = nil
    public var bitDepth: Int? = nil
    /// The rate of a converted AAC track, as it is encoded.
    public var bitRate: Int? = nil
    public var treatment: String? = nil
    /// Why `auto` wrote this format, for a soundtrack that keeps its source's compressed format.
    public var reason: String? = nil
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
        case downmix(MulticamAudioDownmixPlan)

        var edit: ResolvedEdit {
            switch self {
            case .copy(let edit, _): return edit
            case .convert(let plan): return plan.edit
            case .downmix(let plan): return plan.output.edit
            }
        }
    }

    let actions: [StillSoundAction]
    let treatments: [Treatment]
    let container: String

    func verifySources() throws {
        for treatment in treatments {
            let edits: [ResolvedEdit]
            if case .downmix(let plan) = treatment {
                edits = plan.lanes.compactMap { $0?.edit }
            } else {
                edits = [treatment.edit]
            }
            for (file, identity) in edits.flatMap({ $0.identities }) where !identity.isCurrentSnapshot(at: file) {
                throw CutError(code: "source_changed", message: "The soundtrack source changed after export planning: \(file.path)")
            }
        }
    }
}

private struct StillRoutedSound {
    var id: String? = nil
    var label: String? = nil
    var colorSlot: Int? = nil
    let spans: [ConvertedSoundSpan]
    var format: ConvertedSoundFormat? = nil
    var leadingDelay: ConvertedSoundSpan? = nil

    var sources: [StillSoundAction.Source] { Self.sources(in: spans) }

    static func sources(in spans: [ConvertedSoundSpan]) -> [StillSoundAction.Source] {
        spans.compactMap { span in
            guard let media = span.media, let stream = span.stream else { return nil }
            return .init(file: media.url, stream: stream, input: span.input, output: span.output,
                         codec: media.audio.first(where: { $0.stream.index == stream })?.stream.codec)
        }
    }
}

struct StillSoundPlanner {
    var cancelled: (@Sendable () -> Bool)?
    var expectedSoundtrackIdentity: SourceIdentity? = nil

    func resolve(_ project: CutProject, relativeTo location: URL?, timeline: StillTimelinePlan,
                 tracks: ExportTracks, audioStream: Int?, audioTrackOrdinal: Int? = nil, mode: ExportMode, audio: ReencodeAudio,
                 container: String, audioOutput: MulticamAudioOutput = .separateTracks,
                 independentAudio: Bool = false, defaultSoundtrackPCM: Bool = false,
                 defaultSoundtrackCodec: Bool = false) throws -> StillSoundPlan {
        let muxer = ExportRules.multicamMuxContainer(container)
        if tracks == .video || audio == .removeAudio {
            return StillSoundPlan(actions: [], treatments: [], container: muxer)
        }
        let lanes: [StillRoutedSound]
        let followsMulticamRouting: Bool
        switch project {
        case .multicam(let multicam):
            guard audioStream == nil, audioTrackOrdinal == nil else {
                throw CutError(code: "invalid_arguments", message: "A multicam program uses its selected microphone routing.")
            }
            followsMulticamRouting = true
            lanes = try multicamLanes(multicam, relativeTo: location, timeline: timeline,
                                      needsSilenceFormat: audio != .copyOriginal && audioOutput == .separateTracks)
        case .sequence, .stillSequence:
            followsMulticamRouting = false
            if let soundtrack = project.stillSoundtrack {
                lanes = [try soundtrackLane(project, clip: soundtrack, relativeTo: location, duration: timeline.duration,
                                           audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal)]
            } else if case .stillSequence(let sequence) = project, let template = sequence.stillAudioReference,
               timeline.spans.allSatisfy({ $0.origin == .insert }) {
                let file = try ProjectFile.checkedSourceURL(file: template.file, in: projectDirectory(location))
                let media = try CutEngine(cancelled: cancelled).inspect(file, keyframes: false,
                                                                        expectedIdentity: expectedSoundtrackIdentity)
                let streams = try selectedAudioStreams(media, stream: audioStream, ordinal: audioTrackOrdinal ?? template.audioTrack)
                let inserts = timeline.spans.map { silence($0.output) }
                lanes = try streams.map { stream in
                    guard let audio = media.audio.first(where: { $0.stream.index == stream }) else {
                        throw CutError(code: "missing_audio", message: "The selected soundtrack cannot establish a format.", track: stream)
                    }
                    return StillRoutedSound(spans: inserts, format: ConvertedSoundFormat(media: media, audio: audio))
                }
            } else {
                lanes = try sequenceLanes(project, relativeTo: location, timeline: timeline, audioStream: audioStream,
                                          audioTrackOrdinal: audioTrackOrdinal).map { StillRoutedSound(spans: $0) }
            }
        }
        if tracks == .audio && lanes.isEmpty {
            throw CutError(code: "no_audio", message: "The program has no selected audio tracks.")
        }
        if audioOutput != .separateTracks && !lanes.isEmpty {
            return try resolveDownmix(lanes, duration: timeline.duration, container: muxer,
                                      audio: audio, audioOutput: audioOutput)
        }
        guard lanes.count <= 1 || ["mov", "mp4", "m4a", "mkv", "mka", "webm"].contains(muxer) else {
            throw CutError(code: "unsupported_container",
                           message: "Choose a mono or stereo downmix, or a container that carries separate tracks.")
        }

        if lanes.count > 1 { try MulticamMux(cancelled: cancelled).check(container: muxer) }

        var actions: [StillSoundAction] = []
        var treatments: [StillSoundPlan.Treatment] = []
        for (ordinal, lane) in lanes.enumerated() {
            let spans = try coalesce(lane.spans, duration: timeline.duration)
            let sources = StillRoutedSound.sources(in: spans)
            var soundtrackWarnings: [String] = []
            if let soundtrack = project.stillSoundtrack {
                let recordingDuration = try soundtrack.to.subtracting(soundtrack.from)
                if timeline.duration < recordingDuration, let source = sources.last {
                    soundtrackWarnings.append("The recording is trimmed to source time \(source.input.from)–\(source.input.to).")
                } else if timeline.duration > recordingDuration {
                    soundtrackWarnings.append("Generated silence follows the recording from \(recordingDuration) to \(timeline.duration).")
                }
            }
            let streams = (spans.compactMap(\.stream) + [lane.format?.audio.stream.index].compactMap { $0 }).reduce(into: [Int]()) { list, stream in
                if !list.contains(stream) { list.append(stream) }
            }
            let explicitLossless = audio == .alac || audio == .flac
            let explicitConversion = explicitLossless || audio == .aac || audio == .pcm
            let hasSoundtrackSelection = project.stillSoundtrack != nil || project.stillAudioReference?.audioTrack != nil
            let soundtrackDefault = hasSoundtrackSelection && mode != .copy && audio == .auto
            let matchingLossless = explicitLossless && conversionAllowed(audio, container: muxer) && spans.allSatisfy { span in
                span.media?.audio.first(where: { $0.stream.index == span.stream })?.stream.codec == audio.rawValue
            }
            let allowsAutomaticConversion = (independentAudio || mode == .encode) && audio == .auto
            let prefersRetainedPCM = (independentAudio || mode == .smart) && audio == .auto
            let copySpans: [ConvertedSoundSpan]
            if let delay = lane.leadingDelay, muxer == "mov", lane.spans.count >= 2, lane.spans[0].media == nil {
                copySpans = try coalesce([delay] + lane.spans.dropFirst(2), duration: timeline.duration)
            } else {
                copySpans = spans
            }
            func append(_ treatment: StillSoundPlan.Treatment, audio: ReencodeAudio, codec: String?,
                        rate: Int?, layout: String?, bitDepth: Int? = nil, bitRate: Int? = nil,
                        silence: [MulticamRange] = [], warnings: [String] = [],
                        description: String? = nil, reason: String? = nil) {
                treatments.append(treatment)
                actions.append(StillSoundAction(ordinal: ordinal, laneID: lane.id, label: lane.label,
                                                colorSlot: lane.colorSlot, sourceLaneIDs: lane.id.map { [$0] }, codec: codec,
                                                sampleRate: rate, channelLayout: layout, bitDepth: bitDepth, bitRate: bitRate,
                                                treatment: description, reason: reason,
                                                audio: audio, originalStreams: streams, sources: sources, warnings: soundtrackWarnings + warnings,
                                                generatedSilence: silence))
            }
            // The default codec of a soundtrack would only wrap the decoded sound of a lossy recording.
            // Its packets are copied where the range and the container allow, and decoded as before where they do not.
            let copiesLossySoundtrack = defaultSoundtrackCodec && !sources.isEmpty && ["mov", "mp4", "mkv", "m4a"].contains(muxer)
                && spans.allSatisfy { span in
                    guard let media = span.media, let stream = media.audio.first(where: { $0.stream.index == span.stream })?.stream else { return false }
                    return Self.copiesByDefault(codec: stream.codec, format: media.format)
                }
            var copyFailure: CutError?
            var silenceNote: String?
            if !explicitConversion || matchingLossless || copiesLossySoundtrack || (mode == .copy && !independentAudio)
                || (!explicitLossless && !independentAudio && mode != .encode) {
                do {
                    let copy = try resolveCopy(copySpans, duration: timeline.duration, container: muxer,
                                               allowsSourceExtent: !followsMulticamRouting)
                    let stream = format(of: spans)?.audio.stream ?? lane.format?.audio.stream
                    append(copy, audio: .copyOriginal, codec: stream?.codec, rate: stream?.sampleRate,
                           layout: stream?.canonicalChannelLayout, bitDepth: stream.flatMap(AudioExportEngine.integerDepth),
                           warnings: copy.edit.audioJoinNotes, description: "copied packets")
                    continue
                } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                    copyFailure = trackIssue(issue, ordinal: ordinal, lane: lane, spans: copySpans)
                    if issue.code == "generated_audio_required" {
                        // When the track is converted below, its warning states that instead of asking for a conversion.
                        silenceNote = trackIssue(CutError(code: issue.code, message: "This interval requires generated silence, so the track is converted.",
                                                          segment: issue.segment, track: issue.track),
                                                 ordinal: ordinal, lane: lane, spans: copySpans).message
                    }
                }
            }
            let conversionLane = followsMulticamRouting ? spans : try conversionSpans(spans)
            let conversionFormat = lane.format ?? format(of: spans)
            let retained: MulticamAudioConversionPlan?
            if prefersRetainedPCM && (independentAudio || mode != .copy) {
                retained = try resolveRetainedPCM(conversionLane, duration: timeline.duration, container: muxer,
                                                  format: conversionFormat)
            } else {
                retained = nil
            }
            if let copyFailure, retained == nil, !allowsAutomaticConversion, !soundtrackDefault,
               !explicitConversion || (!independentAudio && mode == .copy) {
                throw copyFailure
            }
            let candidates: [ReencodeAudio]
            if soundtrackDefault {
                switch muxer {
                case "mov": candidates = project.stillFormat?.codec == .jpeg ? [.pcm] : [.alac, .pcm]
                case "mp4": candidates = [.alac, .flac]
                case "mkv": candidates = [.flac]
                default: candidates = [.pcm, .aac]
                }
            } else if defaultSoundtrackPCM {
                candidates = [audio, .pcm]
            } else if allowsAutomaticConversion {
                // As in a movie re-encode: a lane whose every source is lossless is written as PCM where the container carries it,
                // and otherwise in the container's lossless codec (ALAC or FLAC in MP4 and M4A) before it would become AAC.
                let lossless = !sources.isEmpty && sources.allSatisfy { $0.codec.map(ExportRules.isLosslessAudio(codec:)) ?? false }
                candidates = lossless ? [.pcm, .alac, .flac, .aac] : [.aac, .pcm]
            } else {
                candidates = [audio]
            }
            // Auto keeps the soundtrack's own compressed format where the container and the helper allow, as a movie re-encode does.
            // A soundtrack's default lossless codec stands in for auto, so it applies there too.
            let automatic = audio == .auto && (soundtrackDefault || allowsAutomaticConversion) || defaultSoundtrackCodec
            let kept = retained == nil && automatic
                ? MulticamEngine(cancelled: cancelled).sourceFormatPlan(conversionLane, duration: timeline.duration, container: muxer,
                                                                        source: .multicam, silenceFormat: conversionFormat) { issue, index in
                    trackIssue(issue, ordinal: ordinal, laneID: lane.id, label: lane.label, output: conversionLane[index].output)
                }
                : nil
            // A PCM soundtrack stays PCM where the container carries it.
            let sourcePCM = !sources.isEmpty && sources.allSatisfy { $0.codec?.hasPrefix("pcm_") ?? false }
            let ordered = automatic && sourcePCM && candidates.contains(.pcm) ? [.pcm] + candidates.filter { $0 != .pcm } : candidates
            var sound = try kept?.plan ?? retained ?? resolveConversion(conversionLane, duration: timeline.duration, container: muxer,
                                                                        candidates: ordered, ordinal: ordinal, lane: lane,
                                                                        format: conversionFormat, preservePCM: independentAudio || hasSoundtrackSelection)
            configureMuxer(&sound, container: muxer)
            let copyNote = copiesLossySoundtrack ? "The soundtrack packets cannot be copied, so the recording is decoded. " : ""
            var warnings = retained == nil ? (copyFailure.map { [copyNote + (silenceNote ?? $0.message)] } ?? []) :
                ["Retained PCM samples are preserved. Uncovered intervals receive digital silence."]
            // A lossless lane that Auto writes as AAC loses samples. Say so; an explicit AAC request is a choice.
            let losslessSources = !sources.isEmpty && sources.allSatisfy { $0.codec.map(ExportRules.isLosslessAudio(codec:)) ?? false }
            if allowsAutomaticConversion, kept == nil, retained == nil, losslessSources, sound.action == .aac {
                warnings.append("This lossless sound could not be written losslessly in .\(muxer), so Auto encoded it as AAC.")
            }
            let codec = sound.writtenCodec
            let description: String?
            if sound.inputs.allSatisfy(\.silence) {
                description = "generated digital silence"
            } else if retained != nil {
                description = "retained PCM samples + generated silence"
            } else {
                description = sound.exactEncoding.map { $0.warnings.isEmpty ? "losslessly encoded PCM samples" : "decoded source audio" }
            }
            append(.convert(sound), audio: sound.action, codec: codec, rate: sound.sampleRate, layout: sound.layout,
                   bitDepth: sound.writtenBitDepth, bitRate: sound.writtenBitRate,
                   silence: conversionLane.filter { $0.media == nil }.map(\.output),
                   warnings: warnings + sound.warnings, description: description, reason: kept?.note)
        }
        let plan = StillSoundPlan(actions: actions, treatments: treatments, container: muxer)
        try plan.verifySources()
        return plan
    }

    /// Soundtrack copies that plan but whose written track fails the still export's read-back: Opus and ALAC in Matroska
    /// (the final track loses its audible range, or its duration), and MP2 in MP4. Refused when planned, with the
    /// containers that carry the copy, so a dry run and the export agree.
    static func copyIssue(_ codec: String, container: String) -> String? {
        switch (codec, container) {
        case ("opus", "mkv"), ("opus", "mka"):
            return "A copied Opus soundtrack does not keep its audible range in Matroska here. Choose MP4, or convert the audio."
        case ("alac", "mkv"), ("alac", "mka"):
            return "A copied ALAC soundtrack does not keep its duration in Matroska here. Choose MOV, MP4 or M4A, or convert the audio."
        case ("mp2", "mp4"), ("mp2", "m4v"):
            return "A copied MP2 soundtrack does not keep its audible range in MP4 here. Choose MOV or MKV, or convert the audio."
        default:
            return nil
        }
    }

    /// The lossy soundtracks whose packets a still project copies without being asked, in place of decoding them
    /// into its default lossless codec. These are the codecs and source formats whose copy into MOV, MP4 and
    /// Matroska was measured to return the source packets. Any other lossy recording is decoded as before.
    static func copiesByDefault(codec: String, format: String) -> Bool {
        switch codec {
        case "aac":
            // An AAC track from Matroska has no edit list for its priming, and its copy into Matroska is refused late.
            return format == "aac" || format.split(separator: ",").contains("mov")
        case "ac3", "eac3":
            return true
        default:
            return false
        }
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
            do {
                let update: @Sendable (Double) -> Void = { fraction in
                    if progress?((Double(index) + fraction) / count) == false { interruption.stop() }
                }
                switch treatment {
                case .copy(let edit, let program):
                    try engine.export(edit, to: output, audioOnly: true, programAudio: program) { fraction in
                        update(fraction)
                        return !interruption.stopped
                    }
                case .downmix(let conversion):
                    try converter.writeConvertedSound(conversion, to: output, progress: update)
                case .convert(let conversion):
                    try converter.writeConvertedSound(conversion, to: output, progress: update)
                }
                if interruption.stopped { throw CutError(code: "cancelled", message: "The operation was cancelled.") }
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" && issue.laneID == nil {
                let lane = plan.actions[index]
                throw trackIssue(issue, ordinal: index, laneID: lane.laneID, label: lane.label)
            }
            return output
        }
    }

    private func folder(in staging: URL, ordinal: Int) -> URL {
        staging.appendingPathComponent("sound-\(ordinal)", isDirectory: true)
    }

    private func trackIssue(_ issue: CutError, ordinal: Int, lane: StillRoutedSound, spans: [ConvertedSoundSpan]) -> CutError {
        let output = issue.segment.flatMap { segment in spans.indices.contains(segment - 1) ? spans[segment - 1].output : nil }
        return trackIssue(issue, ordinal: ordinal, laneID: lane.id, label: lane.label, output: output)
    }

    private func trackIssue(_ issue: CutError, ordinal: Int, laneID: String?, label: String?,
                            output: MulticamRange? = nil) -> CutError {
        let label = label ?? "Audio track \(ordinal + 1)"
        let location = output.map { ", output \($0.from)–\($0.to)" } ?? ""
        return CutError(code: issue.code, message: "\(label)\(location): \(issue.message)",
                        segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest, track: issue.track ?? ordinal,
                        multicam: issue.multicam, laneID: laneID).because(issue.reason)
    }

    private func resolveConversion(_ spans: [ConvertedSoundSpan], duration: RationalTime, container: String,
                                   candidates: [ReencodeAudio], ordinal: Int, lane: StillRoutedSound,
                                   format: ConvertedSoundFormat?, preservePCM: Bool) throws -> MulticamAudioConversionPlan {
        var failure = CutError(code: "unsupported_container",
                               message: "\(container.uppercased()) cannot carry the selected sample-exact audio conversion.")
        let converter = MulticamEngine(cancelled: cancelled)
        for action in candidates where conversionAllowed(action, container: container) {
            do {
                return try converter.resolveConvertedSound(spans, duration: duration, container: container,
                                                           action: action, allowsSilence: true, silenceFormat: format,
                                                           preserveSamples: action == .alac || action == .flac ||
                                                               (preservePCM && action == .pcm && container == "mov")) { issue, index in
                    trackIssue(issue, ordinal: ordinal, laneID: lane.id, label: lane.label, output: spans[index].output)
                }
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                failure = issue
            }
        }
        if failure.laneID != nil { throw failure }
        throw trackIssue(failure, ordinal: ordinal, lane: lane, spans: spans)
    }

    private func configureMuxer(_ sound: inout MulticamAudioConversionPlan, container: String) {
        switch container {
        case "m4a": sound.muxer = "ipod"
        case "wave": sound.muxer = "wav"
        // The helper names the Matroska muxer, and has no format called "mka".
        case "mka": sound.muxer = "matroska"
        default: break
        }
        sound.verifiesSampleRange = true
    }

    func resolveRetainedPCM(_ spans: [ConvertedSoundSpan], duration: RationalTime, container: String,
                            format: ConvertedSoundFormat? = nil) throws -> MulticamAudioConversionPlan? {
        guard ["mov", "wav", "wave", "caf"].contains(container), spans.contains(where: { $0.media == nil }),
              let source = compatiblePCM(in: spans, format: format) else { return nil }
        do {
            var sound = try MulticamEngine(cancelled: cancelled).resolveConvertedSound(
                spans, duration: duration, container: container, action: .pcm, allowsSilence: true,
                silenceFormat: format) { issue, _ in issue }
            guard sound.sampleRate == source.sampleRate, sound.warnings.isEmpty,
                  sound.inputs.allSatisfy({ $0.silence || $0.count == $0.samples.upperBound - $0.samples.lowerBound }) else {
                return nil
            }
            // Raw staging uses little-endian PCM. Numeric samples survive the byte-order change.
            let codec = source.codec.replacingOccurrences(of: "be", with: "le", options: [.anchored, .backwards])
            sound.encoderArguments = ["-c:a", codec]
            for index in sound.inputs.indices where !sound.inputs[index].silence {
                sound.inputs[index].retainsSamples = true
            }
            configureMuxer(&sound, container: container)
            return sound
        } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
            return nil
        }
    }

    private func format(of spans: [ConvertedSoundSpan]) -> ConvertedSoundFormat? {
        spans.lazy.compactMap { span -> ConvertedSoundFormat? in
            guard let media = span.media, let stream = span.stream,
                  let audio = media.audio.first(where: { $0.stream.index == stream }) else { return nil }
            return ConvertedSoundFormat(media: media, audio: audio)
        }.first
    }

    private func silence(_ range: MulticamRange) -> ConvertedSoundSpan {
        ConvertedSoundSpan(media: nil, stream: nil, input: range, output: range)
    }

    private func resolveDownmix(_ lanes: [StillRoutedSound], duration: RationalTime, container: String,
                                audio: ReencodeAudio, audioOutput: MulticamAudioOutput) throws -> StillSoundPlan {
        guard ![.copyOriginal, .alac, .flac].contains(audio) else {
            throw CutError(code: "unsupported_audio", message: "Choose Auto, AAC, or PCM to render a downmix.")
        }
        let multicam = MulticamEngine(cancelled: cancelled)
        let spans = try lanes.map { try conversionSpans(coalesce($0.spans, duration: duration)) }
        let channels = audioOutput == .downmixMono ? 1 : 2
        let laneIDs = lanes.map(\.id)
        let labels = lanes.map(\.label)
        let candidates: [ReencodeAudio] = audio == .auto ? [.aac, .pcm] : [audio]
        var failure = CutError(code: "unsupported_container",
                               message: "\(container.uppercased()) cannot carry the selected downmix codec.")
        for action in candidates where conversionAllowed(action, container: container) {
            do {
                let plan = try multicam.resolveDownmixedSound(spans, duration: duration, container: container,
                                                              action: action, channels: channels) { issue, lane, span in
                    let label = labels[lane] ?? "Audio track \(lane + 1)"
                    return CutError(code: issue.code, message: "\(label): \(issue.message)", segment: span + 1,
                                    boundary: issue.boundary, track: issue.track, laneID: laneIDs[lane])
                }
                let sources = lanes.flatMap(\.sources)
                var report = StillSoundAction(ordinal: 0, laneID: audioOutput.rawValue,
                                              label: channels == 1 ? "Mono downmix" : "Stereo downmix",
                                              sourceLaneIDs: laneIDs.compactMap { $0 }, codec: action == .aac ? "aac" : "pcm_f32le",
                                              sampleRate: plan.sampleRate, channelLayout: plan.layout,
                                              bitDepth: plan.output.writtenBitDepth, bitRate: plan.output.writtenBitRate, audio: action,
                                              originalStreams: Set(sources.map(\.stream)).sorted(), sources: sources,
                                              warnings: plan.warnings, generatedSilence: commonSilence(spans))
                report.treatment = "downmix"
                let result = StillSoundPlan(actions: [report], treatments: [.downmix(plan)], container: container)
                try result.verifySources()
                return result
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                failure = issue
            }
        }
        throw failure
    }

    private func commonSilence(_ lanes: [[ConvertedSoundSpan]]) -> [MulticamRange] {
        let edges = lanes.flatMap { $0.filter { $0.media != nil } }.sorted { $0.output.from < $1.output.from }
        guard let duration = lanes.first?.last?.output.to else { return [] }
        var gaps: [MulticamRange] = []
        var end = RationalTime.zero
        for span in edges {
            if end < span.output.from { gaps.append(.init(from: end, to: span.output.from)) }
            end = max(end, span.output.to)
        }
        if end < duration { gaps.append(.init(from: end, to: duration)) }
        return gaps
    }

    private func conversionAllowed(_ action: ReencodeAudio, container: String) -> Bool {
        ExportRules.allows(stillAudio: action, in: container)
    }

    private func soundtrackLane(_ project: CutProject, clip: CutSequenceClip, relativeTo location: URL?,
                                duration: RationalTime, audioStream: Int?, audioTrackOrdinal: Int?) throws -> StillRoutedSound {
        let file = try ProjectFile.checkedSourceURL(file: clip.file, in: projectDirectory(location))
        let media = try CutEngine(cancelled: cancelled).inspect(file, keyframes: false, expectedIdentity: expectedSoundtrackIdentity)
        let ordinal = clip.audioTrack ?? 0
        let streams = media.streams.filter { $0.kind == "audio" }
        guard streams.indices.contains(ordinal),
              let sound = media.audio.first(where: { $0.stream.index == streams[ordinal].index }) else {
            throw CutError(code: "missing_audio", message: "The attached recording's selected audio track is unavailable.")
        }
        guard clip.from >= sound.start, clip.to <= sound.end else {
            throw CutError(code: "uncovered_audio", message: "The attached recording no longer covers its saved soundtrack range.",
                           track: sound.stream.index)
        }
        guard (audioTrackOrdinal.map { $0 == ordinal } ?? true),
              (audioStream.map { $0 == sound.stream.index } ?? true) else {
            throw CutError(code: "missing_audio", message: "Choose the track selected for the attached recording.")
        }
        let output = MulticamRange(from: .zero, to: duration)
        let format = ConvertedSoundFormat(media: media, audio: sound)
        guard let mapping = try project.stillSoundtrackMapping(in: output) else {
            return StillRoutedSound(spans: [silence(output)], format: format)
        }
        var spans = [ConvertedSoundSpan(media: media, stream: sound.stream.index, input: mapping.source, output: mapping.output)]
        if mapping.output.to < duration { spans.append(silence(.init(from: mapping.output.to, to: duration))) }
        return StillRoutedSound(spans: spans, format: format)
    }

    private func compatiblePCM(in spans: [ConvertedSoundSpan], format: ConvertedSoundFormat?) -> StreamInfo? {
        let sources = spans.filter { $0.media != nil }
        let inputs = sources.compactMap { span in
            span.media?.audio.first { $0.stream.index == span.stream }
        }
        guard inputs.count == sources.count,
              let first = inputs.first?.stream ?? format?.audio.stream,
              ["pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
               "pcm_f32le", "pcm_f32be"].contains(first.codec),
              zip(sources, inputs).allSatisfy({ span, audio in
                  guard audio.stream.sampleRate > 0 else { return false }
                  let samplePeriod = RationalTime(numerator: 1, denominator: Int64(audio.stream.sampleRate))
                  let exactGapRange = !audio.pcmGaps.isEmpty && audio.stream.timeBase == samplePeriod &&
                      audio.pcmGaps.allSatisfy { $0.to <= span.input.from || span.input.to <= $0.from }
                  return (audio.pcmContinuity || exactGapRange) && !audio.hasPriming && audio.presentationEdits.isEmpty &&
                      audio.stream.codec == first.codec && audio.stream.sampleRate == first.sampleRate &&
                      audio.stream.channels == first.channels &&
                      audio.stream.canonicalChannelLayout == first.canonicalChannelLayout
              }) else { return nil }
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
                               timeline: StillTimelinePlan, needsSilenceFormat: Bool) throws -> [StillRoutedSound] {
        let mapping = try project.plan()
        let engine = CutEngine(cancelled: cancelled)
        let multicam = MulticamEngine(cancelled: cancelled)
        let sources = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0) })
        var mediaByURL: [URL: MediaInfo] = [:]
        var indexed: [String: MediaInfo] = [:]

        func index(_ id: String) throws -> MediaInfo {
            if let media = indexed[id] { return media }
            try engine.checkCancellation()
            guard let source = sources[id] else {
                throw CutError(code: "missing_source", message: "Source \(id) has no recording.")
            }
            let file = multicam.sourceURL(source, project: project, location: location)
            guard !file.path.split(separator: "/").contains("..") else {
                throw CutError(code: "missing_source", message: "Source \(id) has an unavailable parent directory: \(file.path).")
            }
            let media = try mediaByURL[file] ?? engine.inspectMulticamSource(file)
            mediaByURL[file] = media
            indexed[id] = media
            return media
        }

        func requiredMedia(_ id: String, lane: MulticamPlannedAudioLane, output: MulticamRange,
                           stream: Int?) throws -> MediaInfo {
            do {
                return try index(id)
            } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                throw CutError(code: issue.code,
                               message: "Lane ‘\(lane.label)’ (\(lane.id)), output \(output.from)–\(output.to): \(issue.message)",
                               segment: issue.segment, boundary: issue.boundary, track: stream ?? issue.track,
                               laneID: lane.id).because(issue.reason)
            }
        }

        let bindings = Dictionary(uniqueKeysWithValues: project.audioReplacements.map { ($0.original, $0) })
        func primarySelection(_ original: MulticamAudioSelection) -> MulticamAudioSelection {
            bindings[original]?.replacement ?? original
        }
        func formatForSelection(_ selection: MulticamAudioSelection, lane: MulticamPlannedAudioLane) throws -> ConvertedSoundFormat? {
            let whole = MulticamRange(from: .zero, to: timeline.duration)
            let media = try requiredMedia(selection.source, lane: lane, output: whole, stream: selection.stream)
            guard let audio = media.audio.first(where: { $0.stream.index == selection.stream }) else { return nil }
            return ConvertedSoundFormat(media: media, audio: audio)
        }
        for lane in mapping.audioLanes {
            for span in lane.spans {
                guard let stream = span.stream else { continue }
                let selected = primarySelection(.init(source: span.source, stream: stream))
                _ = try requiredMedia(selected.source, lane: lane, output: span.output, stream: selected.stream)
            }
        }
        if bindings.values.contains(where: { $0.uncovered == .keepOriginal }) {
            let provisional = try project.resolveAudioLanes(plan: mapping, indexedSources: indexed, unavailableAsGap: true)
            for lane in provisional {
                for span in lane.unavailableSpans ?? [] {
                    _ = try requiredMedia(span.source, lane: lane, output: span.output, stream: span.stream)
                }
            }
        }
        let routed = try project.resolveAudioLanes(plan: mapping, indexedSources: indexed)
        if project.audio != .mix && mapping.intervals.isEmpty {
            let reference: MulticamAudioSelection?
            switch project.audio {
            case .fixed(let selection): reference = selection
            case .follow:
                reference = project.pictureSources.compactMap { angle in
                    angle.audioStream.map { MulticamAudioSelection(source: angle.id, stream: $0) }
                }.first ?? project.switches.compactMap(\.audio).first
            case .none: reference = project.switches.compactMap(\.audio).first
            case .mix: reference = nil
            }
            guard let reference else { return [] }
            let lane = MulticamPlannedAudioLane(id: MulticamPlan.programAudioLaneID, label: "Program audio", spans: [])
            let format = needsSilenceFormat ? try formatForSelection(primarySelection(reference), lane: lane) : nil
            if needsSilenceFormat && format == nil {
                throw CutError(code: "missing_audio", message: "The selected microphone cannot establish a soundtrack format.",
                               track: reference.stream, laneID: lane.id)
            }
            return [StillRoutedSound(id: lane.id, label: lane.label,
                                     spans: timeline.spans.map { silence($0.output) }, format: format)]
        }

        let authored = Dictionary(uniqueKeysWithValues: mapping.audioLanes.map { ($0.id, $0) })
        return try routed.map { lane in
            let covered = try lane.spans.map { span in
                ConvertedSoundSpan(media: try requiredMedia(span.source, lane: lane, output: span.output, stream: span.stream),
                                   stream: span.stream, input: span.input, output: span.output)
            }
            let original = authored[lane.id] ?? lane
            var parts: [ConvertedSoundSpan] = []
            var cursor = RationalTime.zero
            for span in covered {
                if cursor < span.output.from {
                    parts.append(silence(.init(from: cursor, to: span.output.from)))
                }
                parts.append(span)
                cursor = span.output.to
            }
            if cursor < timeline.duration {
                parts.append(silence(.init(from: cursor, to: timeline.duration)))
            }
            let copySpans = try multicam.copySpansPreservingLeadingPCM(
                original: original, lane: lane, project: project, sources: indexed, container: "mov")
            let leadingDelay: ConvertedSoundSpan?
            if let expanded = copySpans.first, expanded.output.from == .zero,
               let audible = covered.first, audible.output.from > .zero {
                leadingDelay = ConvertedSoundSpan(media: audible.media, stream: audible.stream,
                                                  input: expanded.input, output: expanded.output)
            } else {
                leadingDelay = nil
            }
            let soundFormat: ConvertedSoundFormat?
            if let known = format(of: covered) {
                soundFormat = known
            } else if !needsSilenceFormat {
                soundFormat = nil
            } else if let planned = original.spans.first, let stream = planned.stream {
                soundFormat = try formatForSelection(primarySelection(.init(source: planned.source, stream: stream)), lane: lane)
            } else if let reference = project.configuredSelection(for: lane) {
                soundFormat = try formatForSelection(reference, lane: lane)
            } else {
                soundFormat = nil
            }
            return StillRoutedSound(id: lane.id, label: lane.label, colorSlot: lane.colorSlot, spans: parts,
                                    format: soundFormat, leadingDelay: leadingDelay)
        }
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
        var joinRanges: [AudioJoinNotes.Range] = []
        var wholeFile = false
        for (index, span) in lane.enumerated() {
            try engine.checkCancellation()
            guard let media = span.media, let stream = span.stream else {
                throw CutError(code: "generated_audio_required",
                               message: "This interval requires generated silence. Choose Auto, AAC, or PCM.",
                               segment: index + 1, track: reference?.audio.first?.stream.index ?? lane.compactMap(\.stream).first)
            }
            let selector = CutEngine(cancelled: cancelled, tracks: .audio, audioStream: stream)
            let selected = try selector.selectedMedia(media)
            guard let sound = selected.audio.first else {
                throw CutError(code: "missing_audio", message: "The selected soundtrack is unavailable.", track: stream)
            }
            if let issue = selected.audioIssues[stream] ?? selected.copyIssue,
               !issue.hasPrefix("The video "), !issue.hasPrefix("A ProRes "),
               !issue.hasPrefix("RAW video"), issue != "Multiple video tracks are unsupported.",
               !(issue.hasPrefix("Audio track ") || issue.hasPrefix("AAC track "))
                   || issue.hasPrefix("Audio track \(stream) ") || issue.hasPrefix("AAC track \(stream) ") {
                throw CutError(code: "unsupported_tracks", message: issue, segment: index + 1, track: stream)
            }
            if let issue = selector.muxIssue(selected, container: container) ?? Self.copyIssue(sound.stream.codec, container: container) {
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
            if !allowsSourceExtent {
                let declaredDelay = first && container == "mov" && sound.hasDeclaredPCMStart
                    && from >= .zero && from < sound.start
                guard let window = windows.first, (declaredDelay || window.outputStart == span.output.from),
                      window.outputEnd == span.output.to else {
                    throw CutError(code: "uncovered_audio", message: "The selected microphone cannot preserve its exact program interval.",
                                   segment: index + 1, track: stream)
                }
            }
            segments.append(ResolvedSegment(file: selected.url, from: from, to: to, outputStart: span.output.from,
                                            tracks: windows, sourceOrigin: selected.origin, reachesEnd: wholeFile))
            joinRanges.append(AudioJoinNotes.Range(segment: segments[segments.count - 1], media: selected))
            identities[selected.url] = selected.identity
        }
        if audibleAAC.isEmpty, let first = silentAAC.values.min() {
            throw CutError(code: "unsafe_boundary", message: "The selected AAC program contains only empty presentation edits.",
                           segment: first, track: lane[first - 1].stream)
        }
        var edit = ResolvedEdit(segments: segments, duration: duration, container: container, identities: identities,
                                tracks: .audio, usesPerSourceAudioStream: true)
        edit.noteAudioJoins(joinRanges)
        return .copy(edit, program: !wholeFile)
    }
}

private final class StillSoundInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}
