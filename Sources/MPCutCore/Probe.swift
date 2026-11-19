import Darwin
import Foundation
import MediaProbe
import PacketWriter

public struct StreamInfo: Encodable, Sendable {
    public let index: Int
    public let kind: String
    public let codec: String
    public let codecTag: String
    public let profile: Int
    public let width: Int
    public let height: Int
    public let displayWidth: Int
    public let displayHeight: Int
    public let rotation: Int
    public let bitDepth: Int
    public let pixelFormat: String
    public let alphaBits: Int
    public var hasAlpha: Bool { alphaBits > 0 }
    public let frameRate: RationalTime
    public let sampleAspectRatio: RationalTime
    public let timeBase: RationalTime
    public let start: RationalTime
    let hasDeclaredStart: Bool
    public let duration: RationalTime
    public let sampleRate: Int
    public let channels: Int
    public let channelLayout: String
    public let language: String
    public let disposition: Int
    public let isPCM: Bool
    public let initialPadding: Int
    public let trailingPadding: Int
    public let seekPreroll: Int
    public let colorPrimaries: String
    public let colorTransfer: String
    public let colorMatrix: String
    public let colorRange: String
    public let configuration: Data
    public let codecMetadata: Data

    enum CodingKeys: String, CodingKey {
        case index, kind, codec, codecTag, profile, width, height, displayWidth, displayHeight
        case rotation, bitDepth, pixelFormat, alphaBits, frameRate, sampleAspectRatio, timeBase
        case start, duration, sampleRate, channels, channelLayout, isPCM, initialPadding, trailingPadding
        case seekPreroll, language, disposition, colorPrimaries, colorTransfer, colorMatrix, colorRange
    }
}

public struct FrameInfo: Encodable, Sendable {
    public let dts: RationalTime?
    public let time: RationalTime
    public let duration: RationalTime
    public let keyframe: Bool
    public let canStart: Bool
    public let canEnd: Bool
}

public struct AudioPacket: Sendable {
    public let time: RationalTime
    public let dts: RationalTime?
    public let duration: RationalTime
    public let skipSamples: Int
    public let discardSamples: Int
    let decodedSamples: Int
}

struct AACPresentationEdit: Sendable {
    let samples: Range<Int64>
    let isAudible: Bool
}

public struct AudioIndex: Encodable, Sendable {
    public let stream: StreamInfo
    public let packets: [AudioPacket]
    public let start: RationalTime
    public let end: RationalTime
    public let hasPriming: Bool
    public let pcmContinuity: Bool
    let presentationEdits: [AACPresentationEdit]

    enum CodingKeys: String, CodingKey {
        case start, end, hasPriming
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(hasPriming, forKey: .hasPriming)
    }
}

public struct MediaInfo: Encodable, Sendable {
    public let url: URL
    public let format: String
    public let duration: RationalTime
    public let origin: RationalTime
    public let streams: [StreamInfo]
    public let frames: [FrameInfo]
    public let audio: [AudioIndex]
    public let copyIssue: String?
    public let sourceStartSafe: Bool
    let identity: SourceIdentity
    private let videoIndex: Int

    public var video: StreamInfo { streams[videoIndex] }

    init(url: URL, format: String, duration: RationalTime, origin: RationalTime, streams: [StreamInfo],
         frames: [FrameInfo], audio: [AudioIndex], copyIssue: String?, sourceStartSafe: Bool,
         identity: SourceIdentity, videoIndex: Int) {
        self.url = url
        self.format = format
        self.duration = duration
        self.origin = origin
        self.streams = streams
        self.frames = frames
        self.audio = audio
        self.copyIssue = copyIssue
        self.sourceStartSafe = sourceStartSafe
        self.identity = identity
        self.videoIndex = videoIndex
    }

    enum CodingKeys: String, CodingKey {
        case url, format, duration, origin, streams, frames, audio, copyIssue, sourceStartSafe
    }
}

struct SourceIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ url: URL) throws {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &info)
        }
        guard status == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CutError(code: "invalid_input", message: "The source is unavailable or is not a regular local file.")
        }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

enum Probe {
    static func read(_ url: URL, keyframes: Bool = true, cancelled: (() -> Bool)? = nil) throws -> MediaInfo {
        let before = try SourceIdentity(url)
        var error = [CChar](repeating: 0, count: 256)
        let callback: MPProbeCancelled? = cancelled == nil ? nil : { context in
            guard let context else { return 0 }
            let control = Unmanaged<ProbeCancellation>.fromOpaque(context).takeUnretainedValue()
            return control.cancelled() ? 1 : 0
        }
        let control = cancelled.map(ProbeCancellation.init)
        let pointer = withExtendedLifetime(control) {
            url.withUnsafeFileSystemRepresentation { path in
                mp_probe_read(path, callback, control.map { Unmanaged.passUnretained($0).toOpaque() },
                              &error, error.count)
            }
        }
        guard let pointer else {
            try checkCancellation(cancelled)
            throw CutError(code: "probe_failed", message: String(cString: error))
        }
        defer { mp_probe_free(pointer) }
        let media = try makeMedia(pointer.pointee, url: url, identity: before,
                                  keyframes: keyframes, cancelled: cancelled)
        guard try SourceIdentity(url) == before else {
            throw CutError(code: "source_changed", message: "The source changed during inspection.")
        }
        return media
    }

    private static func checkCancellation(_ cancelled: (() -> Bool)?) throws {
        if cancelled?() == true {
            throw CutError(code: "cancelled", message: "The operation was cancelled.")
        }
    }
}

private final class ProbeCancellation {
    let cancelled: () -> Bool
    init(_ cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
}

private extension Probe {
    static func makeMedia(_ native: MPProbeResult, url: URL, identity: SourceIdentity, keyframes: Bool,
                          cancelled: (() -> Bool)?) throws -> MediaInfo {
        let storage = UnsafeBufferPointer(start: native.streams, count: Int(native.stream_count))
        let videoIndex = Int(native.video_index)
        let videoBase = timeBase(storage[videoIndex])
        let origin = try timestamp(native.origin, base: videoBase)
        let duration = try timestamp(native.end, base: videoBase).subtracting(origin)
        var frames: [FrameInfo] = []
        var streams: [StreamInfo] = []
        var audio: [AudioIndex] = []
        var copyIssue: String? = fixedString(native.issue)
        if copyIssue?.isEmpty == true { copyIssue = nil }
        let format = fixedString(native.format)
        var aacSource: OpaquePointer?
        defer { mpcut_aac_source_free(aacSource) }
        if format.split(separator: ",").contains("mov"),
           storage.contains(where: { string($0.codec) == "aac" }) {
            var error = [CChar](repeating: 0, count: 256)
            let capacity = error.count
            let status = url.withUnsafeFileSystemRepresentation { path in
                mpcut_aac_source_open(path, &aacSource, &error, capacity)
            }
            if status != 0 {
                copyIssue = copyIssue ?? String(cString: error)
            }
        }

        for (index, value) in storage.enumerated() {
            try checkCancellation(cancelled)
            let base = timeBase(value)
            let packets = UnsafeBufferPointer(start: value.packets, count: value.count)
            let firstPTS = value.start != .min ? value.start : packets.first?.pts ?? .min
            let absoluteStart = try timestamp(firstPTS, base: base)
            let start = firstPTS == .min ? .zero : try absoluteStart.subtracting(origin)
            let streamDuration: RationalTime
            if index == videoIndex {
                streamDuration = duration
            } else if value.duration > 0 {
                streamDuration = try timestamp(value.duration, base: base)
            } else if let tail = packets.last {
                streamDuration = try timestamp(tail.pts, base: base)
                    .adding(timestamp(tail.duration, base: base)).subtracting(absoluteStart)
            } else {
                streamDuration = .zero
            }
            let stream = describe(value, index: index, base: base, start: start, duration: streamDuration)
            streams.append(stream)
            if index == videoIndex, keyframes {
                frames.reserveCapacity(packets.count)
                for (position, packet) in packets.enumerated() {
                    if position.isMultiple(of: 1_024) { try checkCancellation(cancelled) }
                    frames.append(FrameInfo(
                        dts: try relativeDTS(packet, base: base, origin: origin),
                        time: try timestamp(packet.pts, base: base).subtracting(origin),
                        duration: try timestamp(packet.duration, base: base),
                        keyframe: packet.key != 0, canStart: packet.start != 0, canEnd: packet.end != 0))
                }
            } else if stream.kind == "audio" {
                if packets.isEmpty || stream.sampleRate <= 0 {
                    copyIssue = copyIssue ?? "Audio track \(index) has no usable presentation clock."
                }
                let edits = try makeAACEdits(aacSource, trackID: value.track_id, stream: stream)
                if let edits {
                    let sampleRate = Int64(stream.sampleRate)
                    let start = try RationalTime(numerator: edits[0].samples.lowerBound, denominator: sampleRate).subtracting(origin)
                    let end = try RationalTime(numerator: edits[edits.count - 1].samples.upperBound, denominator: sampleRate)
                        .subtracting(origin)
                    audio.append(AudioIndex(stream: stream, packets: [], start: start, end: end,
                                            hasPriming: true, pcmContinuity: false, presentationEdits: edits))
                } else {
                    if value.deferred_aac_issue == 1 {
                        copyIssue = copyIssue ?? "AAC track \(index) has non-increasing presentation timestamps without a supported edit list."
                    } else if value.deferred_aac_issue == 2 {
                        copyIssue = copyIssue ?? "AAC track \(index) has a packet with missing duration."
                    }
                    audio.append(try buildAudio(stream, packets: packets, origin: origin, cancelled: cancelled))
                }
            }
        }
        return MediaInfo(url: url, format: format, duration: duration,
                         origin: origin, streams: streams, frames: frames, audio: audio, copyIssue: copyIssue,
                         sourceStartSafe: native.source_start_safe != 0, identity: identity, videoIndex: videoIndex)
    }

    static func makeAACEdits(_ source: OpaquePointer?, trackID: Int32, stream: StreamInfo) throws -> [AACPresentationEdit]? {
        guard let source, stream.codec == "aac" else { return nil }
        var count = 0
        var rate: Int32 = 0
        guard let edits = mpcut_aac_source_track(source, trackID, &count, &rate), count > 0 else {
            return nil
        }
        guard rate > 0, rate == stream.sampleRate else {
            throw CutError(code: "unsupported_tracks", message: "AAC track \(stream.index) has inconsistent edit sample rates.")
        }
        var presentation: [AACPresentationEdit] = []
        presentation.reserveCapacity(count)
        for edit in UnsafeBufferPointer(start: edits, count: count) {
            guard edit.presentation_start < edit.presentation_end else {
                throw CutError(code: "unsupported_tracks", message: "AAC track \(stream.index) has an invalid presentation interval.")
            }
            presentation.append(AACPresentationEdit(samples: edit.presentation_start..<edit.presentation_end,
                                                    isAudible: edit.media_start >= 0))
        }
        return presentation
    }

    static func buildAudio(_ stream: StreamInfo, packets: UnsafeBufferPointer<MPProbePacket>,
                           origin: RationalTime, cancelled: (() -> Bool)?) throws -> AudioIndex {
        let sampleRate = Int64(max(1, stream.sampleRate))
        var start: RationalTime?
        var end: RationalTime?
        var indexed: [AudioPacket] = []
        var hasPriming = stream.initialPadding > 0 || stream.seekPreroll > 0
        var aacFrameSamples = 0
        var priorPCMEnd: RationalTime?
        var pcmContinuity = true
        if !stream.isPCM { indexed.reserveCapacity(packets.count) }
        for (index, packet) in packets.enumerated() {
            if index.isMultiple(of: 1_024) { try checkCancellation(cancelled) }
            let rawStart = try timestamp(packet.pts, base: stream.timeBase).subtracting(origin)
            let duration = try timestamp(packet.duration, base: stream.timeBase)
            let rawEnd = try rawStart.adding(duration)
            if stream.isPCM {
                if let priorPCMEnd, priorPCMEnd != rawStart {
                    pcmContinuity = false
                }
                priorPCMEnd = rawEnd
            }
            let skip = index == 0 ? max(Int(packet.skip), stream.initialPadding) : Int(packet.skip)
            let discard = index == packets.count - 1
                ? max(Int(packet.discard), stream.trailingPadding) : Int(packet.discard)
            var decodedSamples = Int(packet.decoded_samples)
            if stream.codec == "aac" {
                let demuxSamples = Int(try duration.roundedToSamples(Int(sampleRate)))
                if discard == 0 {
                    aacFrameSamples = max(aacFrameSamples, demuxSamples)
                    decodedSamples = demuxSamples
                } else {
                    decodedSamples = max(aacFrameSamples, demuxSamples)
                    if aacFrameSamples == 0 {
                        // A short source can have only an edited terminal packet.
                        decodedSamples += discard
                    }
                }
            }
            hasPriming = hasPriming || skip > 0 || discard > 0
            let audibleStart = try rawStart.adding(RationalTime(numerator: Int64(skip), denominator: sampleRate))
            let decodedEnd = decodedSamples > 0
                ? try rawStart.adding(RationalTime(numerator: Int64(decodedSamples), denominator: sampleRate))
                : rawEnd
            // A demuxer can report an already shortened final packet together
            // with the padding that must be discarded from its coded samples.
            let audibleEnd = min(rawEnd, try decodedEnd.subtracting(
                RationalTime(numerator: Int64(discard), denominator: sampleRate)))
            if audibleStart < audibleEnd {
                start = min(start ?? audibleStart, audibleStart)
                end = max(end ?? audibleEnd, audibleEnd)
            }
            if !stream.isPCM {
                indexed.append(AudioPacket(time: rawStart, dts: try relativeDTS(packet, base: stream.timeBase, origin: origin),
                                           duration: duration, skipSamples: skip, discardSamples: discard,
                                           decodedSamples: decodedSamples))
            }
        }
        return AudioIndex(stream: stream, packets: indexed, start: start ?? stream.start,
                          end: end ?? stream.start, hasPriming: hasPriming,
                          pcmContinuity: pcmContinuity, presentationEdits: [])
    }

    static func describe(_ value: MPProbeStream, index: Int, base: RationalTime,
                         start: RationalTime, duration: RationalTime) -> StreamInfo {
        StreamInfo(
            index: index, kind: string(value.kind), codec: string(value.codec), codecTag: fixedString(value.codec_tag),
            profile: Int(value.profile), width: Int(value.width), height: Int(value.height),
            displayWidth: Int(value.display_width), displayHeight: Int(value.display_height), rotation: Int(value.rotation),
            bitDepth: Int(value.bit_depth), pixelFormat: string(value.pixel_format), alphaBits: Int(value.alpha_bits),
            frameRate: ratio(value.rate_num, value.rate_den), sampleAspectRatio: ratio(value.sar_num, value.sar_den),
            timeBase: base, start: start, hasDeclaredStart: value.start != .min,
            duration: duration, sampleRate: Int(value.sample_rate),
            channels: Int(value.channels), channelLayout: fixedString(value.channel_layout),
            language: value.language.map { String(cString: $0).lowercased() } ?? "und",
            disposition: Int(value.disposition), isPCM: value.pcm != 0,
            initialPadding: Int(value.initial_padding), trailingPadding: Int(value.trailing_padding),
            seekPreroll: Int(value.seek_preroll), colorPrimaries: string(value.primaries),
            colorTransfer: string(value.transfer), colorMatrix: string(value.matrix), colorRange: string(value.range),
            configuration: data(value.config, size: value.config_size), codecMetadata: data(value.metadata, size: value.metadata_size))
    }

    static func relativeDTS(_ packet: MPProbePacket, base: RationalTime, origin: RationalTime) throws -> RationalTime? {
        packet.dts == .min ? nil : try timestamp(packet.dts, base: base).subtracting(origin)
    }

    static func ratio(_ numerator: Int32, _ denominator: Int32) -> RationalTime {
        guard denominator > 0 else { return .zero }
        return RationalTime(numerator: Int64(numerator), denominator: Int64(denominator))
    }

    static func timeBase(_ stream: MPProbeStream) -> RationalTime { ratio(stream.tb_num, stream.tb_den) }

    static func timestamp(_ ticks: Int64, base: RationalTime) throws -> RationalTime {
        guard ticks != .min else { return .zero }
        return try RationalTime(numerator: ticks).multiplied(by: base)
    }

    static func fixedString<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? "unknown"
    }

    static func data(_ pointer: UnsafePointer<UInt8>?, size: Int) -> Data {
        pointer.map { Data(bytes: $0, count: size) } ?? Data()
    }
}
