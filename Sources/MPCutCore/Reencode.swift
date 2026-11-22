import Darwin
import Foundation

public enum ReencodeCodec: String, CaseIterable, Codable, Sendable {
    case h264, hevc, prores

    var encoder: String { rawValue + "_videotoolbox" }
}

public enum ReencodeQuality: String, CaseIterable, Codable, Sendable {
    case smallerFile = "smaller"
    case balanced
    case highQuality = "high"
    case proresLT = "422-lt"
    case prores422 = "422"
    case proresHQ = "422-hq"
}

public enum ReencodeAudio: String, CaseIterable, Codable, Sendable {
    case auto
    case copyOriginal = "copy"
    case aac, pcm
    case removeAudio = "remove"
    /// Audio-only conversion targets. Movie re-encoding does not write them.
    case mp3, flac

    /// The actions a movie re-encode accepts.
    public static var movieCases: [ReencodeAudio] { ExportRules.movieAudioActions }
}

public struct ReencodeSettings: Codable, Equatable, Sendable {
    public let codec: ReencodeCodec
    public let quality: ReencodeQuality
    public let audio: ReencodeAudio

    public init(codec: ReencodeCodec = .h264, quality: ReencodeQuality? = nil,
                audio: ReencodeAudio = .auto) {
        self.codec = codec
        self.quality = quality ?? (codec == .prores ? .prores422 : .balanced)
        self.audio = audio
    }
}

public struct ReencodeAudioAction: Encodable, Sendable {
    public let track: Int
    public let action: ReencodeAudio
    public let reason: String?
    /// Reported by audio-only exports: the written codec and its rate control.
    public var codec: String? = nil
    public var bitRate: Int? = nil
    public var quality: Int? = nil
    public var bitDepth: Int? = nil

    public init(track: Int, action: ReencodeAudio, reason: String?) {
        self.track = track
        self.action = action
        self.reason = reason
    }
}

public struct ReencodePlan: Encodable, Sendable {
    public let edit: ResolvedEdit
    public let settings: ReencodeSettings
    public let audioActions: [ReencodeAudioAction]
    public let width: Int
    public let height: Int
    public let warnings: [String]
    /// The shared output format when the clips differ. Nil for clips that match, which keep their own format.
    public var canvas: ReencodeCanvas? = nil

    let media: [URL: MediaInfo]
    let helper: URL
    var encoding: ReencodeVideo
    let audioCopy: ResolvedEdit?
    let timeScale: Int
    let exactPCM: Set<Int>

    var movieTimeScale = 1_000_000
    var assemblesStillHDR = false

    enum CodingKeys: String, CodingKey { case edit, settings, audioActions, width, height, warnings, canvas }
}

public struct ReencodeEngine: Sendable {
    let cancelled: (@Sendable () -> Bool)?
    private let helper: URL?

    public init(cancelled: (@Sendable () -> Bool)? = nil, helper: URL? = nil) {
        self.cancelled = cancelled
        self.helper = helper
    }

    public func resolve(_ clips: [ClipRequest], output: URL? = nil, media cached: [URL: MediaInfo] = [:],
                        container: String = "mp4", settings: ReencodeSettings = .init()) throws -> ReencodePlan {
        try plan(clips, output: output, media: cached, container: container, settings: settings, verifyingEncoder: true)
    }

    func resolveStillPictures(_ clips: [ClipRequest], output: URL, media: [URL: MediaInfo],
                              generated: Set<URL>, container: String, settings: ReencodeSettings) throws -> ReencodePlan {
        try plan(clips, output: output, media: media, container: container, settings: settings,
                 verifyingEncoder: true, normalizedStills: generated)
    }

    /// Everything a re-encode plan checks before it asks the helper: sources, cuts, timing and the audio treatment.
    /// The timeline tier asks this on every edit, so it starts no process. The hardware encoder is verified at export.
    func staticWarnings(_ clips: [ClipRequest], media cached: [URL: MediaInfo], container: String,
                        settings: ReencodeSettings = .init()) throws -> [String] {
        try plan(clips, output: nil, media: cached, container: container, settings: settings, verifyingEncoder: false).warnings
    }

    /// A plan made with `verifyingEncoder` false has no helper and is never written.
    private func plan(_ clips: [ClipRequest], output: URL?, media cached: [URL: MediaInfo],
                      container: String, settings: ReencodeSettings, verifyingEncoder: Bool,
                      normalizedStills: Set<URL> = []) throws -> ReencodePlan {
        try checkCancellation()
        guard !clips.isEmpty else { throw CutError(code: "empty_edit", message: "Add at least one clip before exporting.") }
        let container = container.lowercased()
        // The container and audio action lists belong to the export rules.
        guard ExportRules.reencodeContainers(settings.codec).contains(container) else { throw ExportRules.reencodeContainerRefusal }
        if let output { try checkDestination(output, container: container) }
        guard ExportRules.movieAudioActions.contains(settings.audio) else {
            throw ExportRules.audioActionRefusal(settings.audio, source: .movie)
        }

        let engine = CutEngine(cancelled: cancelled)
        var media: [URL: MediaInfo] = [:]
        var segments: [ResolvedSegment] = []
        var duration = RationalTime.zero
        var reference: MediaInfo?
        var warnings: [String] = []
        // The sources in order of first use, and the first one that a uniform timeline would have refused.
        var sources: [MixedSource] = []
        var difference: (clip: Int, labels: [String])?
        for (offset, clip) in clips.enumerated() {
            try checkCancellation()
            let index = offset + 1
            let file = clip.file.standardizedFileURL
            let info: MediaInfo
            do {
                if let existing = media[file] {
                    info = existing
                } else {
                    info = try conversionMedia(file, indexed: cached[file])
                    if reference != nil, !info.hasVideo {
                        throw ExportRules.mixedMediaTypeRefusal(clip: index, name: file.lastPathComponent)
                    }
                    try checkSource(info, normalizedStill: normalizedStills.contains(file))
                    for stream in info.streams where stream.index != info.video.index && stream.kind != "audio" {
                        warnings.append("Clip \(index) \(stream.codecTag == "tmcd" ? "timecode" : stream.kind) track \(stream.index) will be omitted.")
                    }
                    if let reference {
                        do {
                            try engine.checkCompatibility(info, with: reference, reencodingAudio: settings.audio)
                        } catch let issue as CutError where issue.code == "incompatible_clip" && issue.factor == .joinStreamMismatch {
                            // Re-encode decodes every clip, so sources that differ are written on one canvas.
                            if difference == nil { difference = (index, ExportRules.mixedDifferences(info, from: reference)) }
                        }
                    } else {
                        reference = info
                    }
                    sources.append(MixedSource(clip: index, media: info))
                    media[file] = info
                }
            } catch let error as CutError where error.code != "cancelled" {
                throw CutError(code: error.code, message: error.message, segment: index, track: error.track).because(error.reason)
            }

            let from = clip.from ?? .zero
            let to = clip.to ?? info.duration
            guard from >= .zero, to <= info.duration, from < to else {
                throw CutError(code: "invalid_range", message: "Choose a nonempty range within the clip.", segment: index)
            }
            let lower = info.frames.lowerBound { $0.time >= from }
            let upper = info.frames.lowerBound { $0.time >= to }
            guard lower < info.frames.count, info.frames[lower].time == from else {
                throw CutError(code: "invalid_frame_boundary", message: "The start must be a source frame boundary.",
                               segment: index, boundary: "from").because(.cutOffFrame)
            }
            guard to == info.duration || (upper < info.frames.count && info.frames[upper].time == to) else {
                throw CutError(code: "invalid_frame_boundary", message: "The end must be a source frame boundary.",
                               segment: index, boundary: "to").because(.cutOffFrame)
            }
            let end = try duration.adding(to.subtracting(from))
            let tracks = ([info.video] + info.audio.map(\.stream)).compactMap { stream -> ResolvedTrack? in
                if stream.kind == "audio", settings.audio == .removeAudio { return nil }
                return ResolvedTrack(index: stream.index, kind: stream.kind, sourceStart: from, sourceEnd: to,
                                     outputStart: duration, outputEnd: end)
            }
            segments.append(ResolvedSegment(file: file, from: from, to: to, outputStart: duration,
                                            tracks: tracks, sourceOrigin: info.origin,
                                            lastVideoFrame: info.frames[upper - 1].time, reachesEnd: to == info.duration))
            duration = end
        }
        guard let reference else { throw CutError(code: "empty_edit", message: "Add at least one clip before exporting.") }
        let mixed = try difference.map {
            try resolveMixed(sources, difference: $0, settings: settings, container: container)
        }
        let encoding = try mixed?.encoding ?? ReencodeVideo(reference.video, settings: settings)
        if let mixed { warnings += mixed.warnings }
        if let warning = encoding.warning { warnings.append(warning) }
        if reference.video.complexPicture {
            warnings.append("Additional source display or color metadata may change during video encoding.")
        }
        let timeScale = conversionTimeScale(for: media.values.map { $0.video.timeBase.denominator })
        try checkPictureTimestamps(segments, media: media, timeScale: container == "mkv" ? 1_000 : timeScale)
        if container == "mkv", media.values.contains(where: { 1_000 % $0.video.timeBase.denominator != 0 }) {
            warnings.append("MKV uses millisecond presentation timestamps. Sub-millisecond timing will be rounded.")
        } else if media.values.contains(where: { Int64(timeScale) % $0.video.timeBase.denominator != 0 }) {
            warnings.append("The source clock is finer than the output clock. Presentation timestamps will be rounded.")
        }
        // A mixed timeline converts its sound to the canvas. Nothing of it is copied.
        let (actions, audioCopy, exactPCM) = try mixed.map { ($0.actions, nil, []) }
            ?? resolveAudio(reference: reference, settings: settings, clips: clips,
                            segments: segments, media: media, engine: engine,
                            container: container)
        if let audioCopy {
            guard let groups = Self.audioCopyGroups(audioCopy.segments, pictures: segments) else {
                throw CutError(code: "audio_copy_unavailable", message: "Exact audio copy could not be aligned with the picture.")
            }
            let pictures = segments
            segments = pictures.enumerated().map { offset, picture in
                let group = groups[offset]
                let opens = offset == 0 || groups[offset - 1] != group
                let closes = offset == pictures.count - 1 || groups[offset + 1] != group
                let pictureEnd = picture.tracks.first(where: { $0.kind == "video" })?.outputEnd
                    ?? picture.outputStart
                // A coalesced copy segment spans several adjacent clips. Report each clip's share of it.
                let sound = audioCopy.segments[group].tracks.filter { $0.kind == "audio" }.map { track in
                    var share = ResolvedTrack(index: track.index, kind: track.kind,
                                              sourceStart: opens ? track.sourceStart : picture.from,
                                              sourceEnd: closes ? track.sourceEnd : picture.to,
                                              outputStart: opens ? track.outputStart : picture.outputStart,
                                              outputEnd: closes ? track.outputEnd : pictureEnd)
                    share.opusPreSkip = track.opusPreSkip
                    return share
                }
                return ResolvedSegment(file: picture.file, from: picture.from, to: picture.to, outputStart: picture.outputStart,
                                       tracks: picture.tracks.filter { $0.kind == "video" } + sound,
                                       sourceOrigin: picture.sourceOrigin, lastVideoFrame: picture.lastVideoFrame,
                                       reachesEnd: picture.reachesEnd)
            }
        }
        let executable = verifyingEncoder ? try Self.findHelper(override: helper) : URL(fileURLWithPath: "/dev/null")
        if verifyingEncoder {
            for info in media.values where info.video.codec == "av1" {
                try verifyAV1Decoder(executable, media: info)
            }
            try verifyHardware(executable, encoding: encoding, container: container, actions: actions,
                               audio: reference.audio.map(\.stream), exactPCM: exactPCM, canvas: mixed?.canvas)
        }
        let identities = media.mapValues(\.identity)
        for (file, identity) in identities { try verifyIdentity(file, identity) }
        let edit = ResolvedEdit(segments: segments, duration: duration, container: container, identities: identities)
        return ReencodePlan(edit: edit, settings: settings, audioActions: actions, width: encoding.width,
                            height: encoding.height, warnings: warnings, canvas: mixed?.canvas, media: media, helper: executable, encoding: encoding,
                            audioCopy: audioCopy, timeScale: timeScale, exactPCM: exactPCM)
    }

    package func conversionMedia(_ file: URL, indexed: MediaInfo? = nil) throws -> MediaInfo {
        guard file.isFileURL else { throw CutError(code: "invalid_input", message: "Choose a local video file.") }
        let source: MediaInfo?
        if let indexed, indexed.url == file, !indexed.frames.isEmpty {
            source = indexed
        } else if AnalysisSidecar.readsEnabled {
            // Share the normal packet index with the editor and copy exports.
            // An explicit fresh conversion can go straight to the decoded probe.
            do {
                source = try CutEngine(cancelled: cancelled).inspect(file, keyframes: true)
            } catch let error as CutError where error.code == "probe_failed" || error.code == "unsupported_tracks" {
                // Some formats need a decoder to discover their stream metadata.
                source = nil
            }
        } else {
            source = nil
        }
        if let source, !source.hasVideo || source.video.pixelFormat != "unknown" {
            try verifyIdentity(file, source.identity)
            return source
        }
        // Image-based codecs can require a decoded picture to establish alpha and pixel format.
        return try Probe.read(file, conversion: true, expectedIdentity: source?.identity, cancelled: cancelled)
    }

    private func checkSource(_ info: MediaInfo, normalizedStill: Bool = false) throws {
        guard info.hasVideo else { throw CutError(code: "no_video", message: "Video re-encoding requires a video track. Choose Copy to export audio.") }
        let stagedRGB = normalizedStill && info.streams.count == 1 &&
            info.video.codec == "rawvideo" && info.video.codecTag == "b48r"
        if let issue = info.timelineIssue, !(stagedRGB && issue == "RAW video is unsupported.") {
            throw CutError(code: "unsupported_tracks", message: issue)
        }
        guard !info.frames.isEmpty, info.duration > .zero else {
            throw CutError(code: "unsupported_tracks", message: "The source has no usable video presentation timeline.")
        }
        guard info.video.pixelFormat != "unknown" else {
            throw CutError(code: "unsupported_format", message: "The source pixel format could not be verified for conversion.")
        }
        guard !info.video.hasAdditionalVideoLayers else {
            throw CutError(code: "unsupported_format", message: "The selected hardware profiles cannot preserve additional HEVC layers such as alpha or a second view.")
        }
        if info.video.multipleDescriptions, info.copyIssue == "The video sample descriptions have different picture formats." {
            throw CutError(code: "unsupported_format", message: "The source changes picture format mid-clip.")
        }
    }

    private func checkPictureTimestamps(_ segments: [ResolvedSegment], media: [URL: MediaInfo],
                                        timeScale: Int) throws {
        var previous: Int64?
        for (index, segment) in segments.enumerated() {
            guard let source = media[segment.file] else { continue }
            let frames = source.frames
            let lower = frames.lowerBound { $0.time >= segment.from }
            let upper = frames.lowerBound { $0.time >= segment.to }
            for position in lower..<upper {
                if position.isMultiple(of: 1024) { try checkCancellation() }
                let time = try frames[position].time.subtracting(segment.from).adding(segment.outputStart)
                let tick = try time.roundedToSamples(timeScale)
                guard previous.map({ tick > $0 }) ?? true else {
                    throw CutError(code: "unsupported_timing",
                                   message: "The output time base cannot distinguish two retained pictures.",
                                   segment: index + 1)
                }
                previous = tick
            }
        }
        if let previous, let final = segments.last {
            let end = try final.outputStart.adding(final.duration).roundedToSamples(timeScale)
            guard end > previous else {
                throw CutError(code: "unsupported_timing",
                               message: "The final frame is shorter than the output time base.",
                               segment: segments.count)
            }
        }
    }

    /// Maps each picture segment to the audio-copy segment that covers it. The copy engine merges adjacent
    /// ranges of one source when its audio needs decoder continuity, so one copy segment may cover several clips.
    static func audioCopyGroups(_ copy: [ResolvedSegment], pictures: [ResolvedSegment]) -> [Int]? {
        var groups: [Int] = []
        var next = 0
        for (offset, picture) in pictures.enumerated() {
            if next < copy.count, copy[next].file == picture.file, copy[next].outputStart == picture.outputStart {
                groups.append(next)
                next += 1
            } else if offset > 0, next > 0, copy[next - 1].file == picture.file,
                      pictures[offset - 1].file == picture.file, pictures[offset - 1].to == picture.from {
                groups.append(next - 1)
            } else {
                return nil
            }
        }
        return next == copy.count ? groups : nil
    }

    private func resolveAudio(reference: MediaInfo, settings: ReencodeSettings, clips: [ClipRequest],
                              segments: [ResolvedSegment], media: [URL: MediaInfo], engine: CutEngine, container: String)
        throws -> ([ReencodeAudioAction], ResolvedEdit?, Set<Int>) {
        guard !reference.audio.isEmpty else { return ([], nil, []) }
        var copyFailure: CutError?
        var exactPCM: Set<Int> = []
        var effective = settings.audio
        if effective == .auto || effective == .copyOriginal {
            for (index, track) in reference.audio.enumerated() where canPreservePCM(track.stream, container: container) {
                if try segments.allSatisfy({ segment in
                    guard let source = media[segment.file] else { return false }
                    let audio = source.audio[index]
                    let rate = RationalTime(numerator: Int64(track.stream.sampleRate))
                    let from = try source.origin.adding(segment.from).multiplied(by: rate)
                    let to = try source.origin.adding(segment.to).multiplied(by: rate)
                    return audio.stream.codec == track.stream.codec && audio.pcmContinuity &&
                        segment.from >= audio.start && segment.to <= audio.end &&
                        from.denominator == 1 && to.denominator == 1
                }) {
                    exactPCM.insert(track.stream.index)
                }
            }
            if exactPCM.count == reference.audio.count {
                return (reference.audio.map { exactPCMAction($0.stream.index) }, nil, exactPCM)
            }

            do {
                if reference.audio.contains(where: { $0.stream.codec == "aac" }) {
                    guard segments.count == 1,
                          media.values.allSatisfy({ $0.audio.allSatisfy { $0.presentationEdits.isEmpty } }) else {
                        throw CutError(code: "unsupported_audio", message: "The AAC audio requires edit lists that the re-encode muxer cannot preserve.")
                    }
                }
                if reference.audio.contains(where: { $0.stream.codec == "opus" }) {
                    guard segments.count == 1, segments[0].from == .zero, segments[0].reachesEnd else {
                        throw CutError(code: "unsupported_audio", message: "The trimmed Opus preroll cannot be preserved by the re-encode muxer.")
                    }
                }
                let copy = try engine.resolve(clips, media: media, container: container)
                guard Self.audioCopyGroups(copy.segments, pictures: segments) != nil else {
                    throw CutError(code: "unsupported_audio", message: "The source’s picture and sound start at different presentation origins.")
                }
                return (reference.audio.map { ReencodeAudioAction(track: $0.stream.index, action: .copyOriginal,
                                                                  reason: nil) }, copy, [])
            } catch var issue as CutError {
                if issue.code == "cancelled" || issue.code == "source_changed" { throw issue }
                if issue.track == nil, issue.code == "unsafe_boundary" || issue.code == "unsupported_tracks" {
                    // The copy planner checks the source picture too. Say so instead of citing video keyframes.
                    issue = CutError(code: issue.code,
                                     message: "Audio is copied only at cuts where the source picture could also be copied without re-encoding. \(issue.message)",
                                     segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
                        .because(issue.reason)
                }
                if effective == .copyOriginal {
                    throw CutError(code: "audio_copy_unavailable",
                                   message: "Exact audio copy could not be verified. \(issue.message)",
                                   segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
                        .because(issue.factor)
                }
                copyFailure = issue
                effective = ExportRules.automaticAudio(codec: settings.codec, container: container, source: .movie).first ?? .aac
            }
        }
        if let refusal = ExportRules.reencodeRefusal(audio: effective, container: container, source: .movie) { throw refusal }
        return (try reference.audio.map { audio in
            if exactPCM.contains(audio.stream.index) { return exactPCMAction(audio.stream.index) }
            if effective != .removeAudio {
                guard audio.stream.sampleRate > 0, audio.stream.channels > 0 else {
                    throw CutError(code: "unsupported_audio", message: "Audio track \(audio.stream.index) has no usable sample clock or channel layout.",
                                   track: audio.stream.index)
                }
                if effective == .aac, audio.stream.channels > 8 {
                    throw CutError(code: "unsupported_audio", message: "AAC cannot preserve the channel layout of audio track \(audio.stream.index).",
                                   track: audio.stream.index)
                }
            }
            return ReencodeAudioAction(track: audio.stream.index, action: effective,
                                       reason: copyFailure.map { "Exact audio copy could not be verified. \($0.message)" })
        }, nil, exactPCM)
    }

    private func exactPCMAction(_ track: Int) -> ReencodeAudioAction {
        ReencodeAudioAction(track: track, action: .copyOriginal, reason: "The original PCM sample format and values are preserved.")
    }

    private func canPreservePCM(_ track: StreamInfo, container: String) -> Bool {
        let littleEndian = ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"]
        let bigEndian = ["pcm_s16be", "pcm_s24be", "pcm_s32be", "pcm_f32be"]
        return track.isPCM && track.sampleRate > 0 && container != "mp4" &&
            (littleEndian.contains(track.codec) || (container == "mov" && bigEndian.contains(track.codec)))
    }

    func checkCancellation() throws {
        if cancelled?() == true { throw CutError(code: "cancelled", message: "The operation was cancelled.") }
    }

    func verifyIdentity(_ file: URL, _ identity: SourceIdentity) throws {
        guard identity.isCurrentSnapshot(at: file) else {
            throw CutError(code: "source_changed", message: "The source changed since inspection: \(file.lastPathComponent)")
        }
    }

    func checkDestination(_ file: URL, container: String) throws {
        guard file.isFileURL, !file.hasDirectoryPath,
              file.pathExtension.isEmpty || file.pathExtension.lowercased() == container else {
            throw CutError(code: "invalid_output", message: "Choose a local destination matching the export container.")
        }
        let destination = file.standardizedFileURL
        var metadata = stat()
        if lstat(destination.path, &metadata) == 0 {
            throw CutError(code: "output_exists", message: "A file already exists at the destination.")
        }
        guard errno == ENOENT, stat(destination.deletingLastPathComponent().path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              access(destination.deletingLastPathComponent().path, W_OK | X_OK) == 0 else {
            throw CutError(code: "invalid_output", message: "The destination folder is unavailable.")
        }
    }
}


// The filter interleave clock has microsecond resolution. A multiple of each
// source clock below that ceiling round-trips through interleave exactly.
func conversionTimeScale(for denominators: [Int64]) -> Int {
    let ceiling: Int64 = 1_000_000
    var combined: Int64 = 1
    for denominator in denominators {
        guard denominator > 0, denominator <= ceiling else { return Int(ceiling) }
        var a = combined
        var b = denominator
        while b != 0 { (a, b) = (b, a % b) }
        combined = combined / a * denominator
        if combined > ceiling { return Int(ceiling) }
    }
    return Int(ceiling / combined * combined)
}
