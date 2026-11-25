import Darwin
import Foundation

/// A sound-only export of an ordinary edit: an exact packet copy, or a sample-exact
/// conversion when no container can carry the copied packets across the cuts.
public struct AudioExportPlan: Sendable {
    public let edit: ResolvedEdit
    /// The requested treatment, which may be `auto`.
    public let requested: ReencodeAudio
    /// The single output track and what will be written for it.
    public let actions: [ReencodeAudioAction]
    public let warnings: [String]
    public let sampleRate: Int
    public let channels: Int
    /// Exact for PCM and a nominal figure for constant-rate codecs. Unknown otherwise.
    public let estimatedBytes: Int64?
    /// True when decoding the output returns the source samples unchanged.
    public let isLossless: Bool

    let conversion: MulticamAudioConversionPlan?
    let tracks: ExportTracks
    let audioStream: Int?
    let audioTrackOrdinal: Int?

    public var action: ReencodeAudio { actions.first?.action ?? .copyOriginal }
    public var isCopy: Bool { conversion == nil }
    public var mode: ExportMode { isCopy ? .copy : .encode }

    /// A short description such as "MP3 · 128 kbps" or "PCM · 24-bit".
    public var formatDescription: String {
        guard let written = actions.first, !isCopy else { return "Copy" }
        switch written.action {
        case .mp3:
            if let quality = written.quality { return "MP3 · VBR V\(quality)" }
            return "MP3 · \((written.bitRate ?? 0) / 1000) kbps"
        case .aac: return "AAC · \((written.bitRate ?? 0) / 1000) kbps"
        case .flac: return "FLAC · \(written.bitDepth ?? 0)-bit"
        case .alac: return "ALAC · \(written.bitDepth ?? 0)-bit"
        case .opus: return "Opus · \((written.bitRate ?? 0) / 1000) kbps"
        default:
            return written.codec == "pcm_f32le" ? "PCM · 32-bit float" : "PCM · \(written.bitDepth ?? 0)-bit"
        }
    }
}

public struct AudioExportEngine: Sendable {
    private let cancelled: (@Sendable () -> Bool)?
    private let useSidecar: Bool
    private let tracks: ExportTracks
    private let audioStream: Int?
    private let audioTrackOrdinal: Int?

    /// `tracks` is `.audio` to take the soundtrack of any source, or `.all` for sources without picture.
    public init(cancelled: (@Sendable () -> Bool)? = nil, useSidecar: Bool = true, tracks: ExportTracks = .audio,
                audioStream: Int? = nil, audioTrackOrdinal: Int? = nil) {
        self.cancelled = cancelled
        self.useSidecar = useSidecar
        self.tracks = tracks
        self.audioStream = audioStream
        self.audioTrackOrdinal = audioTrackOrdinal
    }

    /// Sound-only containers whose muxer writes chapters that read back where they were placed.
    static let chapterContainers: Set<String> = ["m4a", "mp4", "mov", "mka", "mp3"]

    /// The conversions this build can describe, most faithful first.
    public static let conversions: [ReencodeAudio] = [.flac, .alac, .pcm, .mp3, .aac, .opus]

    /// Output extensions for a conversion. The first is its default.
    public static func containers(for action: ReencodeAudio) -> [String] { ExportRules.conversionContainers(action) }

    /// The conversion that writes a source codec back in its own format.
    public static func sameFormat(for codec: String) -> ReencodeAudio? { ExportRules.sameFormat(for: codec) }

    private var copyEngine: CutEngine {
        CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: tracks == .all ? .all : .audio,
                  audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal)
    }

    public func resolve(_ clips: [ClipRequest], output: URL? = nil, media cached: [URL: MediaInfo] = [:],
                        container requested: String? = nil, audio: ReencodeAudio) throws -> AudioExportPlan {
        let engine = copyEngine
        try engine.checkCancellation()
        // `auto` is a rule about alternatives. ExportPlanner resolves it and asks here for one named treatment.
        guard audio != .auto else {
            throw CutError(code: "invalid_arguments", message: "Resolve an automatic audio treatment through the export planner.")
        }
        guard !clips.isEmpty else { throw CutError(code: "empty_edit", message: "Add at least one clip before exporting.") }
        guard tracks != .video, audio != .removeAudio else {
            throw CutError(code: "invalid_arguments", message: "Audio conversion needs an audio selection and an audio treatment.")
        }
        if let output { try engine.checkDestination(output) }
        let named = output?.pathExtension.lowercased() ?? ""
        if output != nil, named.isEmpty { throw ExportRules.soundExtensionRefusal }
        let explicit = requested?.lowercased() ?? (named.isEmpty ? nil : named)
        if let explicit {
            guard !explicit.isEmpty, explicit.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }),
                  named.isEmpty || named == explicit else {
                throw CutError(code: "unsupported_container", message: "The container must match the destination extension.")
            }
        }

        // Index every source once and share it with the copy planner.
        var indexed = cached
        var sources: [(media: MediaInfo, audio: AudioIndex)] = []
        for (offset, clip) in clips.enumerated() {
            try engine.checkCancellation()
            let file = clip.file.standardizedFileURL
            do {
                let original: MediaInfo
                if let known = indexed[file], known.url == file, known.hasFullEditIndex {
                    original = known
                } else {
                    original = try engine.inspect(file, keyframes: true)
                    indexed[file] = original
                }
                guard tracks == .audio || !original.hasVideo else {
                    throw CutError(code: "unsupported_tracks",
                                   message: "Audio conversion writes sound only. Select the audio tracks of a movie to convert its soundtrack.")
                }
                let selected = try engine.selectedMedia(original)
                guard let sound = selected.audio.first else {
                    throw CutError(code: "no_audio", message: "There is no indexed audio track.")
                }
                sources.append((selected, sound))
            } catch let issue as CutError where issue.code != "cancelled" {
                throw CutError(code: issue.code, message: issue.message, segment: offset + 1,
                               boundary: issue.boundary, nearest: issue.nearest, track: issue.track).because(issue.reason)
            }
        }

        let copyFailure: CutError? = nil
        if audio == .copyOriginal {
            func copyPlan(_ requests: [ClipRequest], warnings: [String] = []) throws -> AudioExportPlan {
                let edit = try engine.resolve(requests, snap: .exact, media: indexed, container: explicit)
                let stream = sources[0].audio.stream
                let copied = edit.segments.first?.tracks.filter { $0.kind == "audio" } ?? []
                let actions = copied.map { track -> ReencodeAudioAction in
                    var action = ReencodeAudioAction(track: track.index, action: .copyOriginal, reason: nil)
                    action.codec = sources[0].media.streams.first(where: { $0.index == track.index })?.codec
                    return action
                }
                return AudioExportPlan(edit: edit, requested: audio, actions: actions, warnings: warnings,
                                       sampleRate: stream.sampleRate, channels: stream.channels, estimatedBytes: nil,
                                       isLossless: true, conversion: nil, tracks: tracks, audioStream: audioStream,
                                       audioTrackOrdinal: audioTrackOrdinal)
            }
            do {
                return try copyPlan(clips)
            } catch let issue as CutError {
                if ["cancelled", "source_changed", "output_exists", "invalid_output"].contains(issue.code) { throw issue }
                throw CutError(code: "audio_copy_unavailable",
                               message: "Exact audio copy could not be verified. \(issue.message)",
                               segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
                    .because(issue.factor)
            }
        }

        // The conversion writes one track. Several selected tracks have no single program.
        if let position = sources.firstIndex(where: { $0.media.audio.count != 1 }) {
            throw CutError(code: "unsupported_audio",
                           message: "Audio conversion writes one track. Select one audio track of this source.",
                           segment: position + 1)
        }

        let codecs = Set(sources.map(\.audio.stream.codec))
        let native = codecs.count == 1 ? Self.sameFormat(for: codecs.first!) : nil
        let helper = try ReencodeEngine.findHelper(override: nil)
        let action = audio
        let container = explicit ?? Self.containers(for: action)[0]
        guard Self.containers(for: action).contains(container) else {
            throw Self.containerIssue(container, action: action, copyFailure: copyFailure)
        }
        try Self.requireEncoder(for: action, helper: helper)

        // Place every cut on its source sample clock, so each range keeps exactly its own samples.
        func soundLane() throws -> ([ConvertedSoundSpan], RationalTime) {
        var lane: [ConvertedSoundSpan] = []
        var duration = RationalTime.zero
        for (offset, clip) in clips.enumerated() {
            try engine.checkCancellation()
            let (media, sound) = sources[offset]
            let rate = sound.stream.sampleRate
            do {
                guard rate > 0, sound.stream.channels > 0 else {
                    throw CutError(code: "unsupported_audio", message: "The selected audio has no usable sample clock or channel layout.",
                                   track: sound.stream.index)
                }
                let bounds = try sound.audibleBounds(origin: media.origin)
                let limit = max(media.duration, bounds.upperBound)
                let from = clip.from ?? .zero, to = clip.to ?? limit
                guard from >= .zero, from < to, to <= limit else {
                    throw CutError(code: "invalid_range", message: "Choose a nonempty range within the source.")
                }
                let window = sound.opusWindow.flatMap { $0.complete ? $0 : nil }
                var lower = try window?.start ?? media.origin.adding(sound.start).roundedToSamples(rate)
                var upper = try window?.end ?? media.origin.adding(sound.end).roundedToSamples(rate)
                func time(_ sample: Int64) throws -> RationalTime {
                    try RationalTime(numerator: sample, denominator: Int64(rate)).subtracting(media.origin)
                }
                // A track edge can fall between samples. Keep only whole covered samples.
                if window == nil {
                    if try time(lower) < sound.start { lower += 1 }
                    if try time(upper) > sound.end { upper -= 1 }
                }
                let first = max(lower, try media.origin.adding(max(from, bounds.lowerBound)).roundedToSamples(rate))
                let last = min(upper, try media.origin.adding(min(to, bounds.upperBound)).roundedToSamples(rate))
                guard first < last else {
                    throw CutError(code: "invalid_range", message: "No selected audio overlaps this range.")
                }
                let input = MulticamRange(from: try time(first), to: try time(last))
                let end = try duration.adding(input.to.subtracting(input.from))
                lane.append(ConvertedSoundSpan(media: media, stream: sound.stream.index, input: input,
                                               output: MulticamRange(from: duration, to: end)))
                duration = end
            } catch let issue as CutError where issue.code != "cancelled" {
                throw CutError(code: issue.code, message: issue.message, segment: offset + 1,
                               boundary: issue.boundary, nearest: issue.nearest, track: issue.track ?? sound.stream.index)
                    .because(issue.reason)
            }
        }
        return (lane, duration)
        }
        let (lane, duration) = try soundLane()

        var plan = try MulticamEngine(cancelled: cancelled)
            .resolveConvertedSound(lane, duration: duration, container: container, action: action,
                                   keepsDoublePrecision: false) { issue, index in
                guard issue.code != "cancelled", issue.code != "source_changed" else { return issue }
                return CutError(code: issue.code, message: issue.message, segment: index + 1, boundary: issue.boundary,
                                nearest: issue.nearest, track: issue.track ?? lane[index].stream).because(issue.reason)
            }
        let streams = sources.map(\.audio.stream)
        let resampled = plan.conformsSources
        let samples = try duration.roundedToSamples(plan.sampleRate)
        let seconds = Double(samples) / Double(plan.sampleRate)
        func estimatedSize(at bitRate: Int) -> Int64? {
            Int64(exactly: (Double(bitRate) / 8 * seconds).rounded(.towardZero))
        }
        var written = ReencodeAudioAction(track: streams[0].index, action: action,
                                          reason: copyFailure.map { "Exact audio copy could not be verified. \($0.message)" })
        var warnings = plan.warnings
        var estimate: Int64?
        var lossless = false
        // Integer sources keep their word length. Decoded lossy sound has no word length of its own.
        let integerDepth: Int? = resampled ? nil : streams.reduce(Optional(0)) { depth, stream in
            guard let depth, let bits = Self.integerDepth(stream) else { return nil }
            return max(depth, bits)
        }
        switch action {
        case .pcm:
            let codec: String
            if streams.contains(where: { $0.codec.hasPrefix("pcm_f") }) {
                codec = "pcm_f32le"
                if streams.contains(where: { $0.codec.hasPrefix("pcm_f64") }) {
                    warnings.append("The 64-bit floating-point source will be reduced to 32-bit float.")
                }
                if let wide = streams.compactMap(Self.integerDepth).max(), wide > 24 {
                    warnings.append("The \(wide)-bit integer source is written as 32-bit float beside the floating-point source, which keeps 24 bits of it.")
                }
            } else if let integerDepth {
                codec = integerDepth <= 16 ? "pcm_s16le" : integerDepth <= 24 ? "pcm_s24le" : "pcm_s32le"
                lossless = integerDepth <= 32
                if integerDepth > 32 {
                    warnings.append("The \(integerDepth)-bit source will be reduced to 32-bit PCM.")
                }
            } else if streams.contains(where: { !Self.decodesToInteger($0) }) {
                // A lossy decoder works in floating point and can exceed full scale. Integer PCM would clip there.
                codec = "pcm_f32le"
                if let wide = streams.compactMap(Self.integerDepth).max(), wide > 24 {
                    warnings.append("The \(wide)-bit integer source is written as 32-bit float beside the decoded source, which keeps 24 bits of it.")
                }
            } else {
                codec = "pcm_s24le"
                if let wide = streams.compactMap(Self.integerDepth).max(), wide > 24 {
                    warnings.append("The \(wide)-bit source is resampled or remixed and will be reduced to 24-bit PCM.")
                }
            }
            let bytes = codec == "pcm_s16le" ? 2 : codec == "pcm_s24le" ? 3 : 4
            written.codec = codec
            written.bitDepth = bytes * 8
            lossless = lossless || streams.allSatisfy { $0.codec.hasPrefix("pcm_f32") } && !resampled
            let size = samples.multipliedReportingOverflow(by: Int64(plan.channels * bytes))
            let total = size.partialValue.addingReportingOverflow(128)
            guard !size.overflow, !total.overflow else {
                throw CutError(code: "time_overflow", message: "The converted audio is too large.")
            }
            estimate = total.partialValue
            if container == "wav", size.partialValue > 0xFFFF_F000 {
                throw CutError(code: "unsupported_container",
                               message: "This PCM audio exceeds the 4 GB limit of WAV. Choose .caf, or convert to FLAC or AAC.")
            }
            plan.encoderArguments = ["-c:a", codec]
        case .flac:
            let depth = integerDepth.map { $0 <= 16 ? 16 : 24 } ?? 24
            if let integerDepth, integerDepth > 24 {
                warnings.append("FLAC stores 24-bit samples. The 32-bit source will be reduced to 24 bits.")
            } else if integerDepth != nil {
                lossless = true
            } else if streams.contains(where: { $0.codec.hasPrefix("pcm_f") }) {
                warnings.append("FLAC stores integer samples. The floating-point source will be reduced to 24 bits, and samples above full scale will clip. Choose PCM to keep them.")
            } else if let decoded = streams.first(where: { !Self.decodesToInteger($0) }) {
                warnings.append("FLAC stores integer samples. Peaks of the decoded \(decoded.codec) source above full scale will clip. Choose PCM to keep them.")
            }
            // MP4 and Matroska read a FLAC track with more than two channels back without its layout, or in another one.
            if container != "flac", plan.channels > 2 {
                throw CutError(code: "unsupported_audio",
                               message: "\(container.uppercased()) cannot keep the channel layout of FLAC with more than two channels. Choose .flac.")
            }
            written.codec = "flac"
            written.bitDepth = depth
            plan.encoderArguments = depth == 16 ? ["-c:a", "flac", "-sample_fmt", "s16"]
                : ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
        case .alac:
            // Like FLAC: integer sources keep their word length up to 24 bits, the longest the encoder keeps here.
            // M4A, MOV and MP4 read an ALAC track with more than two channels back without its layout.
            guard plan.channels <= 2 else {
                throw CutError(code: "unsupported_audio",
                               message: "ALAC conversion keeps mono or stereo sound here. Choose FLAC in .flac or PCM for the \(plan.layout) channel layout.")
            }
            let depth = integerDepth.map { $0 <= 16 ? 16 : 24 } ?? 24
            if let integerDepth, integerDepth > 24 {
                warnings.append("ALAC is written with 24-bit samples here. The \(integerDepth)-bit source will be reduced to 24 bits.")
            } else if integerDepth != nil {
                lossless = true
            } else if streams.contains(where: { $0.codec.hasPrefix("pcm_f") }) {
                warnings.append("ALAC stores integer samples. The floating-point source will be reduced to 24 bits, and samples above full scale will clip. Choose PCM to keep them.")
            } else if let decoded = streams.first(where: { !Self.decodesToInteger($0) }) {
                warnings.append("ALAC stores integer samples. Peaks of the decoded \(decoded.codec) source above full scale will clip. Choose PCM to keep them.")
            }
            written.codec = "alac"
            written.bitDepth = depth
            plan.encoderArguments = ["-c:a", "alac", "-sample_fmt", depth == 16 ? "s16p" : "s32p", "-bits_per_raw_sample", "\(depth)"]
        case .aac:
            let measured = sources.compactMap { Self.averageBitRate($0.audio, in: indexed[$0.media.url]) }
            let rate = Self.aacBitRate(matching: native == .aac && measured.count == sources.count ? measured.max() : nil,
                                       channels: plan.channels)
            written.codec = "aac"
            written.bitRate = rate
            estimate = estimatedSize(at: rate)
            if let note = Self.aacProfileChange(streams, bitRate: rate) { warnings.append(note) }
            plan.encoderArguments = ["-c:a", "aac", "-b:a", "\(rate)"]
        case .mp3:
            let profiles = native == .mp3 ? sources.compactMap { MP3Profile(media: $0.media, sound: $0.audio) } : []
            let chosen = MP3Profile.encoding(matching: profiles.count == sources.count ? profiles : [],
                                             sampleRate: plan.sampleRate, channels: plan.channels)
            written.codec = "mp3"
            written.bitRate = chosen.bitRate
            written.quality = chosen.quality
            if let rate = chosen.bitRate { estimate = estimatedSize(at: rate) }
            warnings.append(chosen.note)
            plan.encoderArguments = ["-c:a", "libmp3lame"] + chosen.arguments + ["-write_xing", "1", "-id3v2_version", "0"]
        case .opus:
            // An Opus stream states no rate. The size of its packets over its audible span gives the average.
            let measured = sources.compactMap { Self.averageBitRate($0.audio, in: indexed[$0.media.url]) }
            let matched = native == .opus && measured.count == sources.count ? measured.max() : nil
            let rate = Self.opusBitRate(matching: matched, channels: plan.channels)
            written.codec = "opus"
            written.bitRate = rate
            estimate = estimatedSize(at: rate)
            warnings.append("Opus is encoded at \(rate / 1000) kbps." + (matched.map { " The source averages \($0 / 1000) kbps." } ?? ""))
            // Unconstrained libopus VBR takes the rate as a quality target, and the written average can differ from it by a third.
            plan.encoderArguments = ["-c:a", "libopus", "-b:a", "\(rate)", "-vbr", "constrained"]
            // Without a named mapping family the helper's libopus encoder assigns the channels of 5.0 and 6.1 to the wrong speakers.
            if plan.channels > 2 { plan.encoderArguments? += ["-mapping_family", "1"] }
        default:
            throw CutError(code: "invalid_arguments", message: "Choose auto, copy, aac, pcm, mp3, alac, flac or opus for audio conversion.")
        }
        // The first source with a cover picture supplies it, where the output format holds one.
        for (media, _) in sources {
            let pictures = (indexed[media.url] ?? media).streams.filter { $0.kind == "attachment" && $0.disposition & 0x400 != 0 }
            guard let picture = pictures.first else { continue }
            if ["m4a", "mp4", "mp3", "flac"].contains(container), ["mjpeg", "png"].contains(picture.codec) {
                plan.coverArt = .init(file: media.url, stream: picture.index)
                // An MP3 file holds its picture in an ID3v2 tag.
                if action == .mp3, let version = plan.encoderArguments?.firstIndex(of: "-id3v2_version") {
                    plan.encoderArguments?[version + 1] = "3"
                }
            } else {
                warnings.append("The cover art of \(media.url.lastPathComponent) cannot be carried in .\(container) and will be omitted.")
            }
            break
        }
        // Source chapters follow the kept ranges onto the output timeline, as in a movie re-encode. MP4, M4A, MOV, MKA and MP3
        // (in an ID3v2 tag) write them. FLAC, WAV and CAF have no chapter list here, and the helper's Ogg muxer misplaces
        // chapter starts in Opus comments, so those files omit them and say so. A plan that names no output reads no chapters.
        if output != nil {
            let carried = try ReencodeChapter.remapped(plan.edit.segments, media: indexed, cancelled: cancelled)
            warnings += carried.warnings
            if !carried.chapters.isEmpty {
                if Self.chapterContainers.contains(container) {
                    plan.chapters = carried.chapters
                    if action == .mp3, let version = plan.encoderArguments?.firstIndex(of: "-id3v2_version"),
                       plan.encoderArguments?[version + 1] == "0" {
                        plan.encoderArguments?[version + 1] = "3"
                    }
                } else {
                    warnings.append("The source chapters cannot be carried in .\(container) and will be omitted.")
                }
            }
        }
        plan.muxer = container == "m4a" ? "ipod" : container == "mka" ? "matroska" : muxerName(container)
        plan.verifiesSampleRange = true
        return AudioExportPlan(edit: plan.edit, requested: audio, actions: [written], warnings: warnings,
                               sampleRate: plan.sampleRate, channels: plan.channels, estimatedBytes: estimate,
                               isLossless: lossless, conversion: plan, tracks: tracks, audioStream: audioStream,
                               audioTrackOrdinal: audioTrackOrdinal)
    }

    public func write(_ plan: AudioExportPlan, to output: URL,
                      progress: (@Sendable (Double) -> Bool)? = nil) throws {
        guard let conversion = plan.conversion else {
            let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: plan.tracks == .all ? .all : .audio,
                                   audioStream: plan.audioStream, audioTrackOrdinal: plan.audioTrackOrdinal)
            try engine.export(plan.edit, to: output, progress: progress)
            return
        }
        let cancellation = AudioExportCancellation()
        let isCancelled: @Sendable () -> Bool = { cancelled?() == true || cancellation.isCancelled }
        let engine = CutEngine(cancelled: isCancelled)
        try engine.checkCancellation()
        try engine.checkDestination(output)
        guard output.pathExtension.lowercased() == plan.edit.container else {
            throw CutError(code: "invalid_output", message: "Choose a local destination matching the export container.")
        }
        func verifySources() throws {
            for (file, identity) in plan.edit.identities { try engine.verifyIdentity(file, identity: identity) }
            try engine.checkCancellation()
        }
        try verifySources()
        let destination = output.standardizedFileURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-audio-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let partial = staging.appendingPathComponent("audio").appendingPathExtension(plan.edit.container)
        try MulticamEngine(cancelled: isCancelled).writeConvertedSound(conversion, to: partial) { fraction in
            if progress?(fraction * 0.98) == false { cancellation.cancel() }
        }
        try verifySources()
        if progress?(1) == false { cancellation.cancel() }
        try engine.checkCancellation()
        // The helper creates the file with the caller's ordinary creation mask.
        let failure = publishExclusively(from: partial, to: destination)
        if failure == EEXIST { throw CutError(code: "output_exists", message: "A file already exists at the destination.") }
        if failure != 0 { throw CutError(code: "write_failed", message: String(cString: strerror(failure))) }
    }

    private static func containerIssue(_ container: String, action: ReencodeAudio?, copyFailure: CutError?) -> CutError {
        func list(_ action: ReencodeAudio) -> String {
            containers(for: action).map { "." + $0 }.joined(separator: ", ")
        }
        let message: String
        if let action {
            message = "\(ExportRules.displayName(audio: action)) conversion cannot be written to .\(container). Use \(list(action))."
        } else {
            let choices = conversions.map { "\(list($0)) for \(ExportRules.displayName(audio: $0))" }.joined(separator: "; ")
            let reason = copyFailure.map { "Exact audio copy is unavailable. \($0.message) " } ?? ""
            message = "\(reason)No conversion writes .\(container). Use \(choices)."
        }
        return CutError(code: "unsupported_container", message: message, segment: copyFailure?.segment,
                        boundary: copyFailure?.boundary, track: copyFailure?.track)
    }

    static func integerDepth(_ stream: StreamInfo) -> Int? {
        if stream.codec.hasPrefix("pcm_") {
            guard !stream.codec.hasPrefix("pcm_f"), !stream.codec.contains("law") else { return nil }
            let digits = stream.codec.dropFirst(5).prefix { $0.isNumber }
            return Int(digits)
        }
        guard stream.codec == "flac" || stream.codec == "alac" else { return nil }
        return declaredDepth(stream) ?? 24
    }

    /// True when the decoder returns integer samples: integer and companded PCM and the lossless codecs.
    /// Every other decoder works in floating point, so its output can exceed full scale and integer PCM would clip it.
    static func decodesToInteger(_ stream: StreamInfo) -> Bool {
        if stream.codec.hasPrefix("pcm_") { return !stream.codec.hasPrefix("pcm_f") }
        return ExportRules.losslessAudioCodecs.contains(stream.codec)
    }

    /// The bit depth of a PCM codec name such as `pcm_s24le` or `pcm_f64le`.
    static func pcmDepth(codec: String) -> Int? {
        guard codec.hasPrefix("pcm_"), !codec.contains("law") else { return nil }
        return Int(codec.dropFirst(5).prefix { $0.isNumber })
    }

    /// The built-in AAC encoder writes AAC-LC. Says so when a source uses a High Efficiency profile, whose
    /// spectral band replication and parametric stereo are decoded and not written again.
    static func aacProfileChange(_ streams: [StreamInfo], bitRate: Int) -> String? {
        guard let name = streams.lazy.compactMap(highEfficiencyProfile).first else { return nil }
        return "The \(name) source is re-encoded as AAC-LC at \(bitRate / 1000) kbps. The encoder does not write \(name)."
    }

    /// "HE-AAC" or "HE-AAC v2" when the AudioSpecificConfig of an AAC stream signals spectral band replication
    /// or parametric stereo. A stream that signals neither, or only inside its frames, gives nil.
    static func highEfficiencyProfile(_ stream: StreamInfo) -> String? {
        guard stream.codec == "aac" else { return nil }
        // FFmpeg profile numbers, when a decoder has stated one: 4 is HE-AAC and 28 is HE-AAC v2.
        if stream.profile == 4 { return "HE-AAC" }
        if stream.profile == 28 { return "HE-AAC v2" }
        let bytes = [UInt8](stream.configuration)
        var position = 0
        func read(_ count: Int) -> Int? {
            guard position + count <= bytes.count * 8 else { return nil }
            var value = 0
            for bit in position..<(position + count) { value = value << 1 | Int(bytes[bit / 8] >> (7 - bit % 8) & 1) }
            position += count
            return value
        }
        func objectType() -> Int? {
            guard let short = read(5) else { return nil }
            return short == 31 ? read(6).map { $0 + 32 } : short
        }
        func skipRate() -> Bool {
            guard let index = read(4) else { return false }
            return index != 15 || read(24) != nil
        }
        guard let type = objectType(), skipRate(), let channels = read(4) else { return nil }
        if type == 5 { return "HE-AAC" }
        if type == 29 { return "HE-AAC v2" }
        // GASpecificConfig of AAC-LC and its relatives, then the backward-compatible extension.
        guard [1, 2, 3, 4, 6, 7].contains(type), channels != 0, read(1) != nil, let core = read(1),
              core == 0 || read(14) != nil, let extended = read(1), extended == 0,
              read(11) == 0x2B7, objectType() == 5, read(1) == 1, skipRate() else { return nil }
        return read(11) == 0x548 && read(1) == 1 ? "HE-AAC v2" : "HE-AAC"
    }

    /// The word length a stream states: its own field, or the codec header of FLAC and ALAC. Nil when neither states one.
    static func declaredDepth(_ stream: StreamInfo) -> Int? {
        if stream.bitDepth > 0 { return stream.bitDepth }
        return stream.codec == "flac" || stream.codec == "alac" ? headerDepth(stream) : nil
    }

    /// The AAC rate that follows its sources: the customary step nearest their highest measured average, and at
    /// least 32 kbps for each channel. Without a measured AAC source it is 96 kbps for each channel, up to 512 kbps.
    /// A movie soundtrack passes `neverBelowSource`: the first step that is not under the source rate, and never
    /// under the default for its channels, so a re-encode is not written at a lower rate than its source.
    static func aacBitRate(matching average: Int?, channels: Int, neverBelowSource: Bool = false) -> Int {
        let fallback = max(96, min(512, channels * 96)) * 1000
        guard let average else { return fallback }
        let steps = [32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512].map { $0 * 1000 }
        // A nominal 256 kbps encode averages a little either side of 256, so a step within 3% under counts as its own.
        if neverBelowSource { return max(fallback, steps.first { $0 * 100 >= average * 97 } ?? steps[steps.count - 1]) }
        let rate = steps.min { abs($0 - average) < abs($1 - average) } ?? fallback
        return max(rate, 32_000 * channels)
    }

    /// The PCM codec of a movie re-encode for the streams one output track decodes. Integer sources keep the
    /// longest word length among them. Float PCM and decoded lossy sound are written as float, because a decoder
    /// that works in floating point can exceed full scale and integer PCM would clip there.
    static func moviePCM(_ streams: [StreamInfo]) -> (codec: String, bitDepth: Int) {
        var depth = 0
        for stream in streams {
            if stream.codec == "pcm_alaw" || stream.codec == "pcm_mulaw" {
                // Companded telephone PCM decodes to 16-bit integers.
                depth = max(depth, 16)
            } else if stream.codec.hasPrefix("pcm_") && !stream.codec.hasPrefix("pcm_f") {
                // A PCM variant whose name states no word length (Blu-ray, DVD) is written in full.
                depth = max(depth, integerDepth(stream) ?? 32)
            } else if stream.codec == "flac" || stream.codec == "alac" {
                // An unreadable header gives no word length to trust.
                depth = max(depth, declaredDepth(stream) ?? 32)
            } else if ExportRules.losslessAudioCodecs.contains(stream.codec) {
                depth = 32
            } else {
                return ("pcm_f32le", 32)
            }
        }
        return depth <= 16 ? ("pcm_s16le", 16) : depth <= 24 ? ("pcm_s24le", 24) : ("pcm_s32le", 32)
    }

    /// MOV, Matroska and CAF leave the word length of FLAC and ALAC to the decoder. This reads it from the codec header.
    private static func headerDepth(_ stream: StreamInfo) -> Int? {
        let header = [UInt8](stream.configuration)
        let depth: Int
        if stream.codec == "flac" {
            // STREAMINFO, alone or after "fLaC" and a metadata block header. The word length follows
            // 20 bits of sample rate and 3 of channel count, 80 bits in.
            let start = header.count >= 42 && header.starts(with: Array("fLaC".utf8)) ? 8 : header.count == 34 ? 0 : -1
            guard start >= 0 else { return nil }
            depth = Int((header[start + 12] & 1) << 4 | header[start + 13] >> 4) + 1
        } else {
            // The ALAC cookie: size, "alac", version, frame length, compatible version, then the word length.
            guard header.count >= 36, header[4..<8].elementsEqual("alac".utf8) else { return nil }
            depth = Int(header[17])
        }
        return (8...32).contains(depth) ? depth : nil
    }

    /// The average rate of the selected sound from the size of its packets. An index without that size gives
    /// the whole-file rate of a source whose only stream is the selected sound.
    private static func averageBitRate(_ sound: AudioIndex, in media: MediaInfo?) -> Int? {
        if let rate = sound.averageBitRate { return rate }
        guard let media, !media.hasVideo, media.streams.count == 1, media.duration > .zero,
              let size = (try? FileManager.default.attributesOfItem(atPath: media.url.path))?[.size] as? NSNumber else { return nil }
        return Int(exactly: (size.doubleValue * 8 / media.duration.seconds).rounded(.towardZero))
    }

    /// The libopus target: the source's average to the nearest 1 kbps, or a default for its channels.
    static func opusBitRate(matching average: Int?, channels: Int) -> Int {
        // libopus takes any rate from 500 bps to 256 kbps per channel (measured with the helper), so an Opus source is
        // matched at its own average. A ladder step could miss it by a tenth: 141 kbps became 128 kbps.
        // A source that is mostly silence averages a few kbps, which would starve the kept speech or music,
        // so the match never goes below the floor the ladder used.
        if let average {
            let floor = max(16_000, channels * 12_000)
            return min(max(1, channels) * 256_000, max(floor, (average + 500) / 1_000 * 1_000))
        }
        let steps = [8, 12, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 510].map { $0 * 1000 }
        // The libopus default: 64 kbps for each stream and 32 kbps more for each coupled pair of channels.
        let pairs = [0, 1, 1, 2, 2, 2, 2, 3]
        let coupled = pairs.indices.contains(channels - 1) ? pairs[channels - 1] : 1
        let target = max(1, channels) * 64_000 - coupled * 32_000
        // libopus accepts at most 256 kbps per channel.
        let allowed = steps.filter { $0 >= max(16_000, channels * 12_000) && $0 <= channels * 256_000 }
        return allowed.min { abs($0 - target) < abs($1 - target) } ?? 96_000
    }

    // MARK: Helper capabilities

    private static let encoderCache = EncoderCache()

    private final class EncoderCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Set<String>] = [:]

        func encoders(of helper: URL) -> Set<String> {
            let stamp = (try? FileManager.default.attributesOfItem(atPath: helper.path))?[.modificationDate] as? Date
            let key = "\(helper.path)\n\(stamp?.timeIntervalSince1970 ?? 0)"
            lock.lock()
            defer { lock.unlock() }
            if let found = known[key] { return found }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-encoders"]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var names: Set<String> = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                if fields.count >= 2, fields[0].count == 6 { names.insert(String(fields[1])) }
            }
            if process.terminationStatus == 0 { known[key] = names }
            return names
        }
    }

    /// The encoder names of a helper, read once for each build of it.
    static func encoders(of helper: URL) -> Set<String> { encoderCache.encoders(of: helper) }

    /// Refuses a conversion at planning time when the installed helper cannot encode it.
    static func requireEncoder(for action: ReencodeAudio, helper: URL) throws {
        let name: String
        switch action {
        case .mp3: name = "libmp3lame"
        case .flac: name = "flac"
        case .alac: name = "alac"
        case .aac: name = "aac"
        case .opus: name = "libopus"
        default: return
        }
        try requireEncoder(named: name, displayName: ExportRules.displayName(audio: action), helper: helper)
    }

    static func requireEncoder(named name: String, displayName: String? = nil, helper: URL) throws {
        guard encoderCache.encoders(of: helper).contains(name) else {
            throw CutError(code: "encoder_unavailable",
                           message: "The installed FFmpeg helper has no \(displayName ?? name) encoder. Choose another format, or update the helper.")
        }
    }
}

/// The rate control of an MP3 source, read from its first frame and Xing or Info tag.
/// An MP3 track in another container gives the average rate of its packets.
struct MP3Profile {
    enum Control { case constant, average, variable }
    private(set) var control: Control
    private(set) var bitRate: Int
    let quality: Int?

    struct Encoding {
        let arguments: [String]
        let bitRate: Int?
        let quality: Int?
        let note: String
    }

    init?(media: MediaInfo, sound: AudioIndex) {
        guard sound.stream.codec == "mp3" else { return nil }
        guard media.format == "mp3" else {
            // A track in another container carries no tag to read. The size of its packets gives its average rate.
            guard let average = sound.averageBitRate else { return nil }
            control = .average
            bitRate = average
            quality = nil
            return
        }
        guard let file = try? FileHandle(forReadingFrom: media.url) else { return nil }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 10), head.count == 10 else { return nil }
        var offset: UInt64 = 0
        if head.starts(with: [0x49, 0x44, 0x33]) {
            let size = head[6...9].reduce(0) { ($0 << 7) | UInt64($1 & 0x7F) }
            offset = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)
        }
        guard (try? file.seek(toOffset: offset)) != nil,
              let bytes = try? file.read(upToCount: 1 << 16), bytes.count > 200 else { return nil }
        let data = [UInt8](bytes)
        guard let start = (0..<(data.count - 4)).first(where: { index in
            data[index] == 0xFF && data[index + 1] & 0xE0 == 0xE0 && (data[index + 1] >> 1) & 3 == 1
                && data[index + 1] & 0x18 != 0x08
                && data[index + 2] >> 4 != 0 && data[index + 2] >> 4 != 15 && (data[index + 2] >> 2) & 3 != 3
        }) else { return nil }
        let first = data[start + 1] & 0x18 == 0x18
        let mono = data[start + 3] >> 6 == 3
        let table = first ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                          : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let frameRate = table[Int(data[start + 2] >> 4)] * 1000
        let seconds = sound.end.seconds - sound.start.seconds
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: media.url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        var average = frameRate
        if let measured = sound.averageBitRate {
            average = measured
        } else if seconds > 0, fileSize > offset {
            average = Int(exactly: (Double(fileSize - offset) * 8 / seconds).rounded(.towardZero)) ?? frameRate
        }
        let tag = start + 4 + (first ? (mono ? 17 : 32) : (mono ? 9 : 17))
        guard tag + 8 <= data.count else { return nil }
        let name = String(decoding: data[tag..<(tag + 4)], as: UTF8.self)
        guard name == "Xing" || name == "Info" else {
            // Without a tag, a file whose size matches its first frame's rate is constant.
            let constant = abs(average - frameRate) <= frameRate / 20
            control = constant ? .constant : .variable
            bitRate = constant ? frameRate : average
            quality = nil
            return
        }
        func word(_ at: Int) -> Int? {
            guard at + 4 <= data.count else { return nil }
            return data[at..<(at + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let flags = word(tag + 4) ?? 0
        var cursor = tag + 8
        var frames: Int?, size: Int?, level: Int?
        if flags & 1 != 0 { frames = word(cursor); cursor += 4 }
        if flags & 2 != 0 { size = word(cursor); cursor += 4 }
        if flags & 4 != 0 { cursor += 100 }
        if flags & 8 != 0 { level = word(cursor); cursor += 4 }
        if let frames, let size, frames > 0, sound.stream.sampleRate > 0 {
            let samples = Double(frames) * (first ? 1152 : 576)
            average = Int(Double(size) * 8 * Double(sound.stream.sampleRate) / samples)
        }
        bitRate = average
        // LAME records its rate control after the nine-byte encoder name.
        let lame = cursor + 10 <= data.count && String(decoding: data[cursor..<(cursor + 4)], as: UTF8.self) == "LAME"
        let method = lame ? Int(data[cursor + 9] & 0x0F) : 0
        if name == "Info" || method == 1 || method == 8 {
            control = .constant
            quality = nil
        } else if method == 2 || method == 9 {
            control = .average
            quality = nil
            // The tag also records the requested average, after the replay gain fields.
            if cursor + 21 <= data.count, data[cursor + 20] > 0, data[cursor + 20] < 255 {
                bitRate = Int(data[cursor + 20]) * 1000
            }
        } else {
            control = .variable
            quality = lame ? level.map { max(0, min(9, (100 - $0) / 10)) } : nil
        }
    }

    /// The same rate taken as constant. A track in a movie container states only the average of its packets, and LAME's
    /// ABR undershoots a requested average on dense material, while a constant rate at the nearest step meets it.
    var asConstant: MP3Profile {
        var profile = self
        if profile.control == .average { profile.control = .constant }
        return profile
    }

    /// Chooses the LAME setting closest to the sources, or a default for other sources.
    static func encoding(matching profiles: [MP3Profile], sampleRate: Int, channels: Int) -> Encoding {
        let rates = sampleRate >= 32_000 ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : sampleRate >= 16_000 ? [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            : [8, 16, 24, 32, 40, 48, 56, 64]
        func nearest(_ rate: Int) -> Int {
            (rates.min { abs($0 * 1000 - rate) < abs($1 * 1000 - rate) } ?? 128) * 1000
        }
        guard let highest = profiles.max(by: { $0.bitRate < $1.bitRate }) else {
            let rate = nearest(channels == 1 ? 128_000 : 192_000)
            return Encoding(arguments: ["-b:a", "\(rate)"], bitRate: rate, quality: nil,
                            note: "MP3 is encoded at a constant \(rate / 1000) kbps.")
        }
        switch highest.control {
        case .constant:
            let rate = nearest(highest.bitRate)
            return Encoding(arguments: ["-b:a", "\(rate)"], bitRate: rate, quality: nil,
                            note: "MP3 is encoded at the source's constant \(rate / 1000) kbps.")
        case .average:
            let rate = max(rates[0] * 1000, min(rates[rates.count - 1] * 1000, highest.bitRate / 1000 * 1000))
            return Encoding(arguments: ["-abr", "1", "-b:a", "\(rate)"], bitRate: rate, quality: nil,
                            note: "MP3 is encoded at the source's average \(rate / 1000) kbps (ABR).")
        case .variable:
            if let recorded = profiles.compactMap(\.quality).min(), profiles.allSatisfy({ $0.quality != nil }) {
                return Encoding(arguments: ["-q:a", "\(recorded)"], bitRate: nil, quality: recorded,
                                note: "MP3 is encoded with the source's variable-rate setting, LAME V\(recorded).")
            }
            // Typical averages of LAME V0–V9 for 44.1 kHz stereo.
            let typical = [245, 225, 190, 175, 165, 130, 115, 100, 85, 65]
            let scale = (channels == 1 ? 0.55 : 1) * (sampleRate >= 32_000 ? 1 : 0.5)
            let target = Double(highest.bitRate) / 1000
            let level = typical.indices.min { abs(Double(typical[$0]) * scale - target) < abs(Double(typical[$1]) * scale - target) } ?? 2
            return Encoding(arguments: ["-q:a", "\(level)"], bitRate: nil, quality: level,
                            note: "MP3 is encoded at variable rate LAME V\(level), the setting nearest the source's average \(highest.bitRate / 1000) kbps.")
        }
    }
}
