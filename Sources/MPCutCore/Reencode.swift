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
}

public struct ReencodePlan: Encodable, Sendable {
    public let edit: ResolvedEdit
    public let settings: ReencodeSettings
    public let audioActions: [ReencodeAudioAction]
    public let width: Int
    public let height: Int
    public let warnings: [String]

    let media: [URL: MediaInfo]
    let helper: URL
    let encoding: ReencodeVideo
    let audioCopy: ResolvedEdit?
    let timeScale: Int
    let exactPCM: Set<Int>

    enum CodingKeys: String, CodingKey { case edit, settings, audioActions, width, height, warnings }
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
        try checkCancellation()
        guard !clips.isEmpty else { throw CutError(code: "empty_edit", message: "Add at least one clip before exporting.") }
        let container = container.lowercased()
        guard ["mp4", "mov", "mkv"].contains(container), container != "mp4" || settings.codec != .prores else {
            throw CutError(code: "unsupported_container", message: "Choose MP4, MOV, or MKV for Re-encode. ProRes requires MOV or MKV.")
        }
        if let output { try checkDestination(output, container: container) }

        let engine = CutEngine(cancelled: cancelled)
        var media: [URL: MediaInfo] = [:]
        var segments: [ResolvedSegment] = []
        var duration = RationalTime.zero
        var reference: MediaInfo?
        var warnings: [String] = []
        for (offset, clip) in clips.enumerated() {
            try checkCancellation()
            let index = offset + 1
            let file = clip.file.standardizedFileURL
            let info: MediaInfo
            do {
                if let existing = media[file] {
                    info = existing
                } else {
                    if let indexed = cached[file], indexed.url == file, !indexed.frames.isEmpty {
                        info = indexed.video.pixelFormat == "unknown"
                            ? try Probe.read(file, conversion: true, cancelled: cancelled) : indexed
                        try verifyIdentity(file, indexed.identity)
                    } else {
                        guard file.isFileURL else {
                            throw CutError(code: "invalid_input", message: "Choose a local video file.")
                        }
                        info = try Probe.read(file, conversion: true, cancelled: cancelled)
                    }
                    try checkSource(info)
                    for stream in info.streams where stream.index != info.video.index && stream.kind != "audio" {
                        warnings.append("Clip \(index) \(stream.codecTag == "tmcd" ? "timecode" : stream.kind) track \(stream.index) will be omitted.")
                    }
                    if let reference { try engine.checkCompatibility(info, with: reference) }
                    else { reference = info }
                    media[file] = info
                }
            } catch let error as CutError where error.code != "cancelled" {
                throw CutError(code: error.code, message: error.message, segment: index, track: error.track)
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
                               segment: index, boundary: "from")
            }
            guard to == info.duration || (upper < info.frames.count && info.frames[upper].time == to) else {
                throw CutError(code: "invalid_frame_boundary", message: "The end must be a source frame boundary.",
                               segment: index, boundary: "to")
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
        let encoding = try ReencodeVideo(reference.video, settings: settings)
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
        let (actions, audioCopy, exactPCM) = try resolveAudio(reference: reference, settings: settings, clips: clips,
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
        let executable = try Self.findHelper(override: helper)
        for info in media.values where info.video.codec == "av1" {
            try verifyAV1Decoder(executable, media: info)
        }
        try verifyHardware(executable, encoding: encoding, container: container, actions: actions,
                           audio: reference.audio.map(\.stream), exactPCM: exactPCM)
        let identities = media.mapValues(\.identity)
        for (file, identity) in identities { try verifyIdentity(file, identity) }
        let edit = ResolvedEdit(segments: segments, duration: duration, container: container, identities: identities)
        return ReencodePlan(edit: edit, settings: settings, audioActions: actions, width: encoding.width,
                            height: encoding.height, warnings: warnings, media: media, helper: executable, encoding: encoding,
                            audioCopy: audioCopy, timeScale: timeScale, exactPCM: exactPCM)
    }

    private func checkSource(_ info: MediaInfo) throws {
        if let issue = info.timelineIssue {
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
                    return audio.pcmContinuity && segment.from >= audio.start && segment.to <= audio.end &&
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
                }
                if effective == .copyOriginal {
                    throw CutError(code: "audio_copy_unavailable",
                                   message: "Exact audio copy could not be verified. \(issue.message)",
                                   segment: issue.segment, boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
                }
                copyFailure = issue
                effective = settings.codec == .prores && container != "mp4" ? .pcm : .aac
            }
        }
        if effective == .pcm, container == "mp4" {
            throw CutError(code: "unsupported_audio", message: "Choose MOV or MKV for PCM audio.")
        }
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
        guard (try? SourceIdentity(file)) == identity else {
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
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw CutError(code: "invalid_output", message: "The destination folder is unavailable.")
        }
    }
}


// The filter interleave clock has microsecond resolution. A multiple of each
// source clock below that ceiling round-trips through interleave exactly.
private func conversionTimeScale(for denominators: [Int64]) -> Int {
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
