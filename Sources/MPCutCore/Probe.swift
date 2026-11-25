import Darwin
import Foundation
import MediaProbe
import PacketWriter

public struct StreamInfo: Encodable, Sendable {
    public let index: Int
    package let trackID: Int32
    public let kind: String
    public let codec: String
    public let codecTag: String
    public let profile: Int
    public let width: Int
    public let height: Int
    public let displayWidth: Int
    public let displayHeight: Int
    public let rotation: Int
    let rotationOnly: Bool
    public let bitDepth: Int
    public let pixelFormat: String
    public let alphaBits: Int
    public let hasAdditionalVideoLayers: Bool
    public var hasAlpha: Bool { alphaBits > 0 }
    public let frameRate: RationalTime
    public let sampleAspectRatio: RationalTime
    public let timeBase: RationalTime
    public internal(set) var start: RationalTime
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
    public let fieldOrder: String
    public let chromaLocation: String
    public let colorRange: String
    public let configuration: Data
    public let codecMetadata: Data
    public let multipleDescriptions: Bool
    let complexPicture: Bool
    let reconstructedDTS: Bool
    public internal(set) var name: String? = nil

    enum CodingKeys: String, CodingKey {
        case index, kind, codec, profile, width, height, rotation, start, duration, channels, language, disposition, name
        case codecTag = "codec_tag"
        case displayWidth = "display_width"
        case displayHeight = "display_height"
        case bitDepth = "bit_depth"
        case pixelFormat = "pixel_format"
        case alphaBits = "alpha_bits"
        case hasAdditionalVideoLayers = "has_additional_video_layers"
        case frameRate = "frame_rate"
        case sampleAspectRatio = "sample_aspect_ratio"
        case timeBase = "time_base"
        case sampleRate = "sample_rate"
        case channelLayout = "channel_layout"
        case isPCM = "is_pcm"
        case initialPadding = "initial_padding"
        case trailingPadding = "trailing_padding"
        case seekPreroll = "seek_preroll"
        case colorPrimaries = "color_primaries"
        case colorTransfer = "color_transfer"
        case colorMatrix = "color_matrix"
        case colorRange = "color_range"
        case fieldOrder = "field_order"
        case chromaLocation = "chroma_location"
    }
}

extension StreamInfo {
    /// The channel layout that two tracks are compared by. A container may state the same sound as "2 channels" or
    /// as "stereo": a layout that names no speakers stands for the standard layout of its channel count, and a
    /// layout that names them stands for itself, so "5.1" and "5.1(side)" stay different.
    /// `channelLayout` keeps what the file states, which sidecars store and reports print.
    public var canonicalChannelLayout: String { Self.canonicalChannelLayout(channelLayout, channels: channels) }

    static func canonicalChannelLayout(_ layout: String, channels: Int) -> String {
        var text = [CChar](repeating: 0, count: 128)
        guard mp_canonical_channel_layout(layout, Int32(channels), &text, text.count) != 0 else { return layout }
        return String(cString: text)
    }

    /// The layout an Opus stream of channel mapping family 1 states for its channel count, which the index reads back.
    static func opusSurroundLayout(channels: Int) -> String? {
        guard let name = mp_vorbis_order_layout(Int32(clamping: channels)) else { return nil }
        return String(cString: name)
    }
}

public struct FrameInfo: Encodable, Sendable {
    public let dts: RationalTime?
    public let time: RationalTime
    public let duration: RationalTime
    public let keyframe: Bool
    public let canStart: Bool
    public let canEnd: Bool
    let byteCount: UInt32

    enum CodingKeys: String, CodingKey { case dts, time, duration, keyframe, canStart, canEnd }
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

struct MP3Anchor: Codable, Sendable {
    let sample: Int64
    let offset: Int64
    let checksum: UInt32

    var native: MPCutMP3Anchor { MPCutMP3Anchor(sample: sample, offset: offset, checksum: checksum) }
}

public struct AudioIndex: Encodable, Sendable {
    public let stream: StreamInfo
    public let packets: [AudioPacket]
    public let start: RationalTime
    public let end: RationalTime
    public let hasPriming: Bool
    public let pcmContinuity: Bool
    let presentationEdits: [AACPresentationEdit]
    var mp3Anchors: [MP3Anchor] = []
    var opusWindow: OpusTrimWindow? = nil
    /// Timestamp holes on the compact PCM index, which does not retain packet rows.
    var pcmGaps: [MulticamRange] = []
    /// The size of the track's compressed packets. Nil for PCM, and for an index that does not record it.
    var codedBytes: Int64? = nil

    /// The average rate of the compressed track over its audible span, in bits per second.
    var averageBitRate: Int? {
        guard let codedBytes, codedBytes > 0,
              let duration = try? end.subtracting(start), duration > .zero else { return nil }
        return Int(exactly: (Double(codedBytes) * 8 / duration.seconds).rounded(.towardZero))
    }

    package var hasDeclaredPCMStart: Bool {
        stream.isPCM && stream.hasDeclaredStart && stream.start == start
    }

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
    static let auxiliaryTrackIssue = "The file contains a track of unknown kind, a second timecode track, or a chapter list that cannot be read."
    public let copyIssue: String?
    /// The first issue found on each audio track, by stream index. `copyIssue` reports
    /// only one issue for the file, which can belong to a track the caller excluded.
    let audioIssues: [Int: String]
    public let timelineIssue: String?
    public let sourceStartSafe: Bool
    // Present only on a sidecar-backed inspection summary. Edit plans open and
    // validate the current muxer as usual.
    let reportedContainers: Set<String>?
    package let identity: SourceIdentity
    private let videoIndex: Int
    private let metadataOnly: Bool
    let hasProvisionalClock: Bool
    private(set) var isFromSavedIndex: Bool
    let refreshEvidence: MediaRefreshEvidence?
    fileprivate(set) var snapshotSourceClock: ProjectMediaSnapshot.Entry.SourceClock?

    var snapshotEvidence: MediaRefreshEvidence? {
        guard let evidence = refreshEvidence, let changeTime = evidence.identity.changeTime,
              identity.changeTime == changeTime, evidence.identity == identity,
              evidence.hasCompleteProof else { return nil }
        return evidence
    }
    package let multicamClockOffset: RationalTime
    // Desktop sources follow their owning document through Save As. This context
    // is session state and is deliberately excluded from the media wire format.
    private var sidecarDocument: @Sendable () -> URL?
    package var sidecarProjectURL: URL? { sidecarDocument() }
    package private(set) var sidecarWriteLocations: SidecarLocations?
    package private(set) var sidecarClearEpoch: SidecarClearEpoch?

    /// Pin a single operation before dispatch. The long-lived index remains reusable
    /// when the user next requests analysis after clearing caches or changing locations.
    package func pinningSidecarWrites() -> Self {
        var copy = self
        let locations = SidecarLocations(source: url, project: SidecarLocations.projectURL ?? sidecarProjectURL)
        copy.sidecarWriteLocations = locations
        copy.sidecarClearEpoch = locations.destination.map { SidecarClearEpoch.capture(sidecar: $0) }
        return copy
    }

    package func inheritingSidecarContext(from original: Self) -> Self {
        var copy = self
        copy.sidecarDocument = original.sidecarDocument
        copy.sidecarWriteLocations = original.sidecarWriteLocations
        copy.sidecarClearEpoch = original.sidecarClearEpoch
        if let originalChangeTime = original.identity.changeTime,
           copy.identity == original.identity, copy.identity.changeTime == originalChangeTime {
            copy.snapshotSourceClock = original.snapshotSourceClock
            copy.isFromSavedIndex = copy.isFromSavedIndex || original.isFromSavedIndex
        }
        return copy
    }

    package func withSidecarDocument(_ document: @escaping @Sendable () -> URL?) -> Self {
        var copy = self
        copy.sidecarDocument = document
        return copy
    }

    public var hasVideo: Bool { videoIndex >= 0 }
    package var hasFullEditIndex: Bool {
        guard !metadataOnly else { return false }
        if hasVideo { return !frames.isEmpty }
        return !audio.isEmpty && audio.allSatisfy { $0.stream.isPCM || !$0.packets.isEmpty || !$0.presentationEdits.isEmpty }
    }
    /// Estimates the retained index's row and stream storage without walking packet arrays.
    package var indexStorageBytes: Int {
        let streamBytes = streams.reduce(0) {
            $0 + MemoryLayout<StreamInfo>.stride + $1.configuration.count + $1.codecMetadata.count
        }
        let audioBytes = audio.reduce(0) {
            $0 + MemoryLayout<AudioIndex>.stride
                + $1.packets.count * MemoryLayout<AudioPacket>.stride
                + $1.mp3Anchors.count * MemoryLayout<MP3Anchor>.stride
                + $1.presentationEdits.count * MemoryLayout<AACPresentationEdit>.stride
                + $1.pcmGaps.count * MemoryLayout<MulticamRange>.stride
                + ($1.opusWindow?.packetStarts.count ?? 0) * MemoryLayout<Int64>.stride
        }
        return frames.count * MemoryLayout<FrameInfo>.stride + streamBytes + audioBytes
    }

    func omittingFrames() -> MediaInfo {
        // Video-only editing metadata may have been built just to populate the sidecar.
        var tracks = audio
        if hasVideo { for index in tracks.indices { tracks[index].opusWindow = nil } }
        return MediaInfo(url: url, format: format, duration: duration, origin: origin, streams: streams,
                  frames: [], audio: tracks, copyIssue: copyIssue, sourceStartSafe: sourceStartSafe,
                  identity: identity, videoIndex: videoIndex, timelineIssue: timelineIssue,
                  reportedContainers: reportedContainers, metadataOnly: metadataOnly, hasProvisionalClock: hasProvisionalClock,
                  multicamClockOffset: multicamClockOffset, audioIssues: audioIssues, refreshEvidence: refreshEvidence).inheritingSidecarContext(from: self)
    }

    package func forRefreshAlias(_ url: URL) -> MediaInfo {
        withRefreshEvidence(refreshEvidence, at: url)
    }

    func withRefreshEvidence(_ evidence: MediaRefreshEvidence?, at url: URL? = nil,
                             identity refreshedIdentity: SourceIdentity? = nil) -> MediaInfo {
        MediaInfo(url: url ?? self.url, format: format, duration: duration, origin: origin, streams: streams,
                  frames: frames, audio: audio, copyIssue: copyIssue, sourceStartSafe: sourceStartSafe,
                  identity: refreshedIdentity ?? identity, videoIndex: videoIndex, timelineIssue: timelineIssue,
                  reportedContainers: reportedContainers, metadataOnly: metadataOnly, hasProvisionalClock: hasProvisionalClock,
                  multicamClockOffset: multicamClockOffset, audioIssues: audioIssues, refreshEvidence: evidence).inheritingSidecarContext(from: self)
    }

    public var videoStream: StreamInfo? { hasVideo ? streams[videoIndex] : nil }
    public var primaryStream: StreamInfo { streams[primaryIndex] }
    // Existing picture paths use the source's primary clock. New mixed-media
    // callers can ask for videoStream when actual pictures are required.
    public var video: StreamInfo { primaryStream }
    private let primaryIndex: Int

    public func requiresPresentationAudioAnalysis(stream: Int) -> Bool {
        audio.contains { $0.stream.index == stream && !$0.presentationEdits.isEmpty }
    }

    init(url: URL, format: String, duration: RationalTime, origin: RationalTime, streams: [StreamInfo],
         frames: [FrameInfo], audio: [AudioIndex], copyIssue: String?, sourceStartSafe: Bool,
         identity: SourceIdentity, videoIndex: Int, timelineIssue: String? = nil,
         reportedContainers: Set<String>? = nil, metadataOnly: Bool = false, hasProvisionalClock: Bool = false,
         multicamClockOffset: RationalTime = .zero, audioIssues: [Int: String] = [:],
         refreshEvidence: MediaRefreshEvidence? = nil, isFromSavedIndex: Bool = false) {
        let document = SidecarLocations.projectURL
        sidecarDocument = { document }
        self.url = url
        self.audioIssues = audioIssues
        self.format = format
        self.duration = duration
        self.origin = origin
        self.streams = streams
        self.frames = frames
        self.audio = audio
        self.copyIssue = copyIssue
        self.timelineIssue = timelineIssue
        self.sourceStartSafe = sourceStartSafe
        self.reportedContainers = reportedContainers
        self.metadataOnly = metadataOnly
        self.hasProvisionalClock = hasProvisionalClock
        self.isFromSavedIndex = isFromSavedIndex
        self.refreshEvidence = refreshEvidence
        self.multicamClockOffset = multicamClockOffset
        self.identity = identity
        self.videoIndex = videoIndex
        primaryIndex = videoIndex >= 0 ? videoIndex : streams.firstIndex { $0.kind == "audio" }!
    }

    /// Audio extraction can retain samples past the final picture on the same source clock.
    package func extendingToAudioEnd(stream: Int?) throws -> MediaInfo {
        guard hasVideo else { return self }
        let ends = try audio.filter { stream == nil || $0.stream.index == stream }.map {
            try $0.audibleBounds(origin: origin).upperBound
        }
        guard let end = ends.max(), end > duration else { return self }
        return MediaInfo(url: url, format: format, duration: end, origin: origin, streams: streams,
                         frames: frames, audio: audio, copyIssue: copyIssue, sourceStartSafe: sourceStartSafe,
                         identity: identity, videoIndex: videoIndex, timelineIssue: timelineIssue,
                         reportedContainers: reportedContainers, metadataOnly: metadataOnly, hasProvisionalClock: hasProvisionalClock,
                         audioIssues: audioIssues, refreshEvidence: refreshEvidence).inheritingSidecarContext(from: self)
    }

    enum CodingKeys: String, CodingKey {
        case url, format, duration, origin, streams, frames, audio, copyIssue, sourceStartSafe, timelineIssue
    }
}

package struct SourceIdentity: Codable, Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    // Keep the filesystem change time only for live jobs. Tags and permissions can
    // change it, so it must never invalidate an analysis stored across sessions.
    package struct ChangeTime: Hashable, Sendable {
        package let seconds: Int
        package let nanoseconds: Int
    }
    package private(set) var changeTime: ChangeTime?

    private enum CodingKeys: String, CodingKey {
        case device, inode, size
        case modifiedSeconds = "modified_seconds"
        case modifiedNanoseconds = "modified_nanoseconds"
    }

    package static func == (lhs: SourceIdentity, rhs: SourceIdentity) -> Bool {
        lhs.device == rhs.device && lhs.matches(saved: rhs)
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(inode)
        hasher.combine(size)
        hasher.combine(modifiedSeconds)
        hasher.combine(modifiedNanoseconds)
    }

    /// A source pinned to a running or queued operation may have been rewritten
    /// in place with its original modification time restored.
    package func isCurrentSnapshot(at url: URL) -> Bool {
        (try? SourceIdentity(url)).map(matchesSnapshot) == true
    }

    package func matchesSnapshot(_ other: SourceIdentity) -> Bool {
        self == other && (changeTime == nil || other.changeTime == nil || changeTime == other.changeTime)
    }

    func forPreviewHandoff() -> SourceIdentity {
        // Permission and other metadata changes can advance ctime between a
        // provisional preview read and the full inspection without changing media.
        var identity = self
        identity.changeTime = nil
        return identity
    }

    package init(_ url: URL) throws {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &info)
        }
        try self.init(status: status, info: info)
    }

    init(file: FileHandle) throws {
        var info = stat()
        let status = fstat(file.fileDescriptor, &info)
        try self.init(status: status, info: info)
    }

    private init(status: Int32, info: stat) throws {
        guard status == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CutError(code: "invalid_input", message: "The source is unavailable or is not a regular local file.")
        }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changeTime = ChangeTime(seconds: info.st_ctimespec.tv_sec, nanoseconds: info.st_ctimespec.tv_nsec)
    }

    /// Compares against an identity saved by an earlier session. A volume's
    /// device number can change whenever it is mounted again.
    func matches(saved: SourceIdentity) -> Bool {
        inode == saved.inode && size == saved.size && modifiedSeconds == saved.modifiedSeconds &&
            modifiedNanoseconds == saved.modifiedNanoseconds
    }
}

enum Probe {
    /// The file's change time moved during inspection while its inode, size and modification time held.
    private struct MetadataChanged: Error {}

    static func read(_ url: URL, keyframes: Bool = true, conversion: Bool = false, previewOnly: Bool = false,
                     audioAnalysis: Bool = false, forcePayload: Bool = false,
                     expectedIdentity: SourceIdentity? = nil,
                     progress: ((Double) -> Void)? = nil, cancelled: (() -> Bool)? = nil) throws -> MediaInfo {
        try CutProject.rejectLegacyCache(url)
        do {
            return try readOnce(url, keyframes: keyframes, conversion: conversion, previewOnly: previewOnly,
                                audioAnalysis: audioAnalysis, forcePayload: forcePayload,
                                expectedIdentity: expectedIdentity, progress: progress, cancelled: cancelled)
        } catch is MetadataChanged {
            // macOS writes access metadata, such as the com.apple.macl attribute after an Open panel
            // or a drop, which advances ctime without touching the media. Inspect once more against
            // the new snapshot. A second change during that read is reported.
            do {
                return try readOnce(url, keyframes: keyframes, conversion: conversion, previewOnly: previewOnly,
                                    audioAnalysis: audioAnalysis, forcePayload: forcePayload,
                                    expectedIdentity: expectedIdentity?.forPreviewHandoff(),
                                    progress: progress, cancelled: cancelled)
            } catch is MetadataChanged {
                throw CutError(code: "source_changed", message: "The source changed during inspection.")
            }
        }
    }

    private static func readOnce(_ url: URL, keyframes: Bool, conversion: Bool, previewOnly: Bool,
                                 audioAnalysis: Bool, forcePayload: Bool, expectedIdentity: SourceIdentity?,
                                 progress: ((Double) -> Void)?, cancelled: (() -> Bool)?) throws -> MediaInfo {
        let before = try SourceIdentity(url)
        if let expectedIdentity, !expectedIdentity.matchesSnapshot(before) {
            throw CutError(code: "source_changed", message: "The source changed while opening the clip.")
        }
        var error = [CChar](repeating: 0, count: 256)
        let callback: MPProbeCancelled? = cancelled == nil ? nil : { context in
            guard let context else { return 0 }
            let control = Unmanaged<ProbeCancellation>.fromOpaque(context).takeUnretainedValue()
            return control.cancelled() ? 1 : 0
        }
        let report: MPProbeProgress? = progress == nil ? nil : { context, fraction in
            guard let context else { return }
            Unmanaged<ProbeCancellation>.fromOpaque(context).takeUnretainedValue().report(packetScanShare * fraction)
        }
        let control = ProbeCancellation(cancelled ?? { false }, progress: progress)
        let pointer = withExtendedLifetime(control) {
            url.withUnsafeFileSystemRepresentation { path in
                mp_probe_read(path, conversion ? 1 : 0, previewOnly ? 1 : 0, audioAnalysis ? 1 : 0,
                              forcePayload ? 1 : 0, callback, report,
                              Unmanaged.passUnretained(control).toOpaque(),
                              &error, error.count)
            }
        }
        guard let pointer else {
            try checkCancellation(cancelled)
            throw CutError(code: "probe_failed", message: String(cString: error))
        }
        defer { mp_probe_free(pointer) }
        progress?(packetScanShare)
        var media = try makeMedia(pointer.pointee, url: url, identity: before,
                                  keyframes: keyframes, previewOnly: previewOnly, progress: progress, cancelled: cancelled)
        let stamp = pointer.pointee
        let stampStream = Int(stamp.source_stamp_stream)
        if stamp.source_stamp_kind > 0, media.streams.indices.contains(stampStream),
           let clock = try? MulticamSync.stamp(status: stamp.source_stamp_kind, units: stamp.source_stamp_units,
                                              numerator: stamp.source_stamp_num, denominator: stamp.source_stamp_den,
                                              track: media.streams[stampStream], url: url) {
            media.snapshotSourceClock = .init(kind: clock.kind, start: clock.start)
        }
        guard before.isCurrentSnapshot(at: url) else {
            // Equality ignores ctime, so a match here means only metadata moved.
            if let after = try? SourceIdentity(url), after == before { throw MetadataChanged() }
            throw CutError(code: "source_changed", message: "The source changed during inspection.")
        }
        progress?(1)
        return media
    }

    private static func checkCancellation(_ cancelled: (() -> Bool)?) throws {
        if cancelled?() == true {
            throw CutError(code: "cancelled", message: "The operation was cancelled.")
        }
    }
}

// Reading and validating compressed packets dominates the first open of long movies.
private let packetScanShare = 0.97

private final class ProbeCancellation {
    let cancelled: () -> Bool
    private let progress: ((Double) -> Void)?
    private var lastFraction = -1.0

    func report(_ fraction: Double) {
        // An incompatible ProRes sample table can trigger a packet-by-packet retry.
        guard fraction > lastFraction else { return }
        lastFraction = fraction
        progress?(fraction)
    }

    init(_ cancelled: @escaping () -> Bool, progress: ((Double) -> Void)?) {
        self.cancelled = cancelled
        self.progress = progress
    }
}

private extension Probe {
    static func makeMedia(_ native: MPProbeResult, url: URL, identity: SourceIdentity, keyframes: Bool, previewOnly: Bool,
                          progress: ((Double) -> Void)?, cancelled: (() -> Bool)?) throws -> MediaInfo {
        let storage = UnsafeBufferPointer(start: native.streams, count: Int(native.stream_count))
        let videoIndex = Int(native.video_index)
        let primaryIndex = videoIndex >= 0 ? videoIndex : storage.firstIndex { string($0.kind) == "audio" }
        guard let primaryIndex else { throw CutError(code: "unsupported_tracks", message: "The file has no playable audio or video.") }
        let base = timeBase(storage[primaryIndex])
        var origin = try timestamp(native.origin, base: base)
        var duration = try timestamp(native.end, base: base).subtracting(origin)
        var frames: [FrameInfo] = []
        var streams: [StreamInfo] = []
        var audio: [AudioIndex] = []
        let timelineIssue = fixedString(native.timeline_issue)
        var copyIssue: String? = fixedString(native.issue)
        if copyIssue?.isEmpty == true { copyIssue = nil }
        var audioIssues: [Int: String] = [:]
        func audioIssue(_ track: Int, _ message: String) {
            audioIssues[track] = audioIssues[track] ?? message
            copyIssue = copyIssue ?? message
        }
        let format = fixedString(native.format)
        var aacSource: OpaquePointer?
        defer { mpcut_aac_source_free(aacSource) }
        if !previewOnly, format.split(separator: ",").contains("mov"),
           storage.contains(where: { string($0.codec) == "aac" }) {
            var error = [CChar](repeating: 0, count: 256)
            let capacity = error.count
            let clocks = storage.filter { string($0.codec) == "aac" }.map {
                MPCutAACTrackClock(track_id: $0.track_id, sample_rate: $0.sample_rate)
            }
            let status = url.withUnsafeFileSystemRepresentation { path in
                mpcut_aac_source_open(path, clocks, clocks.count, &aacSource, &error, capacity)
            }
            if status != 0 {
                copyIssue = copyIssue ?? String(cString: error)
            }
        }

        if videoIndex < 0, !previewOnly {
            var first: RationalTime?
            for track in storage where string(track.kind) == "audio" && track.sample_rate > 0 {
                let packets = UnsafeBufferPointer(start: track.packets, count: track.count)
                // Vorbis overlap-add primes the decoder with its first packet. Only
                // the second packet can produce the first audible sample.
                let firstAudible = string(track.codec) == "vorbis" ? 1 : 0
                guard packets.indices.contains(firstAudible) else { continue }
                let packet = packets[firstAudible]
                let base = timeBase(track)
                let raw = try timestamp(packet.pts, base: base)
                let skip = Swift.max(Int64(packet.skip), Int64(track.initial_padding))
                var start = try raw.adding(RationalTime(numerator: skip, denominator: Int64(track.sample_rate)))
                if string(track.codec) == "opus", format.split(separator: ",").contains("matroska"),
                   base == RationalTime(numerator: 1, denominator: 1000), track.sample_rate == 48_000 {
                    // Matroska stores the leading codec delay rounded to milliseconds.
                    start = try raw.adding(RationalTime(numerator: (skip + 24) / 48, denominator: 1000))
                }
                var editCount = 0
                var editRate: Int32 = 0
                if let aacSource, string(track.codec) == "aac",
                   let edits = mpcut_aac_source_track(aacSource, track.track_id, &editCount, &editRate),
                   editCount > 0, editRate > 0 {
                    start = RationalTime(numerator: edits[0].presentation_start, denominator: Int64(editRate))
                }
                first = min(first ?? start, start)
            }
            guard let first else { throw CutError(code: "unsupported_tracks", message: "The file has no usable audio samples.") }
            origin = first
        }

        let rowCounts = storage.enumerated().map { index, track -> Double in
            if index == videoIndex { return keyframes ? Double(track.count) : 0 }
            guard !previewOnly, string(track.kind) == "audio" else { return 0 }
            var count = 0
            var rate: Int32 = 0
            if let aacSource, string(track.codec) == "aac",
               mpcut_aac_source_track(aacSource, track.track_id, &count, &rate) != nil, count > 0 { return 0 }
            return Double(track.count)
        }
        let totalRows = max(1, rowCounts.reduce(0, +))
        var completedRows = 0.0
        for (index, value) in storage.enumerated() {
            func reportRows(_ count: Int) {
                progress?(packetScanShare + (1 - packetScanShare) * (completedRows + Double(count)) / totalRows)
            }
            defer { completedRows += rowCounts[index] }
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
            if !previewOnly, stream.multipleDescriptions, copyIssue == nil,
               !matchingMovieDescriptions(url: url, trackID: value.track_id) {
                copyIssue = "The video sample descriptions have different picture formats."
            }
            if index == videoIndex, keyframes {
                frames.reserveCapacity(packets.count)
                try forEachOrderedBatch(count: packets.count, batchSize: 2048, check: {
                    try checkCancellation(cancelled)
                }, transform: { range in
                    try packets[range].map { packet in
                        let time = try relativeTime(packet.pts, base: base, origin: origin)
                        return FrameInfo(
                            dts: packet.dts == packet.pts ? time : try relativeDTS(packet, base: base, origin: origin),
                            time: time, duration: try timestamp(packet.duration, base: base),
                            keyframe: packet.key != 0, canStart: packet.start != 0, canEnd: packet.end != 0,
                            byteCount: packet.byte_count)
                    }
                }, consume: {
                    frames.append(contentsOf: $0)
                    reportRows(frames.count)
                })
            } else if !previewOnly, stream.kind == "audio" {
                let clockIssue = fixedString(value.audio_clock_issue)
                if !clockIssue.isEmpty { audioIssue(index, clockIssue) }
                if packets.isEmpty || stream.sampleRate <= 0 {
                    audioIssue(index, "Audio track \(index) has no usable presentation clock.")
                }
                let edits = try makeAACEdits(aacSource, trackID: value.track_id, stream: stream)
                if let edits {
                    let sampleRate = Int64(stream.sampleRate)
                    let start = try RationalTime(numerator: edits[0].samples.lowerBound, denominator: sampleRate).subtracting(origin)
                    let end = try RationalTime(numerator: edits[edits.count - 1].samples.upperBound, denominator: sampleRate)
                        .subtracting(origin)
                    audio.append(AudioIndex(stream: stream, packets: [], start: start, end: end,
                                            hasPriming: true, pcmContinuity: false, presentationEdits: edits,
                                            codedBytes: value.coded_bytes > 0 ? value.coded_bytes : nil))
                } else {
                    if value.deferred_aac_issue == 1 {
                        audioIssue(index, "AAC track \(index) has non-increasing presentation timestamps without a supported edit list.")
                    } else if value.deferred_aac_issue == 2 {
                        audioIssue(index, "AAC track \(index) has a packet with missing duration.")
                    }
                    var index = try buildAudio(stream, packets: packets, origin: origin, standalone: videoIndex < 0,
                                               progress: reportRows, cancelled: cancelled)
                    index.mp3Anchors = UnsafeBufferPointer(start: value.mp3_anchors, count: value.mp3_anchor_count).map {
                        MP3Anchor(sample: $0.sample, offset: $0.offset, checksum: $0.checksum)
                    }
                    if (keyframes || videoIndex < 0), stream.codec == "opus",
                       format.split(separator: ",").contains(where: { $0 == "matroska" || $0 == "ogg" }) {
                        let window = try opusTrimWindow(index, origin: origin) { try checkCancellation(cancelled) }
                        if videoIndex < 0, let window, window.complete {
                            index = AudioIndex(stream: stream, packets: index.packets,
                                               start: try RationalTime(numerator: window.start, denominator: 48_000).subtracting(origin),
                                               end: try RationalTime(numerator: window.end, denominator: 48_000).subtracting(origin),
                                               hasPriming: index.hasPriming, pcmContinuity: index.pcmContinuity,
                                               presentationEdits: index.presentationEdits)
                        }
                        index.opusWindow = window
                    }
                    index.codedBytes = value.coded_bytes > 0 ? value.coded_bytes : nil
                    audio.append(index)
                }
            }
        }
        if videoIndex < 0, !previewOnly {
            duration = audio.map(\.end).max() ?? .zero
            guard duration > .zero else { throw CutError(code: "unsupported_tracks", message: "The audio has no positive presentation duration.") }
        }
        // Explicit stream selection can drop an auxiliary track. Preserve any
        // packet, clock or codec issue discovered while indexing the retained media.
        if copyIssue == nil, native.has_unsupported_auxiliary != 0 {
            copyIssue = MediaInfo.auxiliaryTrackIssue
        }
        let refreshEvidence = previewOnly ? nil : MediaRefreshEvidence(
            identity: identity, format: format, origin: origin, duration: duration,
            videoIndex: videoIndex, streams: streams, audio: audio,
            indexIssues: [copyIssue ?? "", timelineIssue, String(native.source_start_safe)] +
                audioIssues.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" },
            native: storage
        )
        return MediaInfo(url: url, format: format, duration: duration,
                         origin: origin, streams: streams, frames: frames, audio: audio, copyIssue: copyIssue,
                         sourceStartSafe: native.source_start_safe != 0, identity: identity, videoIndex: videoIndex,
                         timelineIssue: timelineIssue.isEmpty ? nil : timelineIssue, metadataOnly: previewOnly,
                         hasProvisionalClock: previewOnly, audioIssues: audioIssues, refreshEvidence: refreshEvidence)
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
                           origin: RationalTime, standalone: Bool, progress: (Int) -> Void, cancelled: (() -> Bool)?) throws -> AudioIndex {
        let sampleRate = Int64(max(1, stream.sampleRate))
        let samplePeriod = RationalTime(numerator: 1, denominator: sampleRate)
        let useSampleClock = (stream.codec == "flac" || (stream.isPCM && standalone)) && stream.timeBase > samplePeriod
        let pcmGapTolerance = stream.isPCM && !useSampleClock && stream.timeBase > samplePeriod
            ? try stream.timeBase.adding(RationalTime(numerator: 1, denominator: sampleRate * 2)) : .zero
        var start: RationalTime?
        var end: RationalTime?
        var indexed: [AudioPacket] = []
        var hasPriming = stream.initialPadding > 0 || stream.seekPreroll > 0
        var firstAudibleSample: RationalTime?
        var lastAudibleSample: RationalTime?
        var aacFrameSamples = 0
        var priorPCMEnd: RationalTime?
        var priorSampleEnd: RationalTime?
        var pcmContinuity = true
        var pcmAudibleEnd: RationalTime?
        var priorPCMDiscard = 0
        var pcmGaps: [MulticamRange] = []
        if !stream.isPCM { indexed.reserveCapacity(packets.count) }
        for (index, packet) in packets.enumerated() {
            if index.isMultiple(of: 1_024) {
                try checkCancellation(cancelled)
                progress(index)
            }
            let rawStart = try relativeTime(packet.pts, base: stream.timeBase, origin: origin)
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
            // Matroska may round both the packet timestamp and its duration
            // to whole milliseconds. Keep the decoded sample clock through
            // ordinary rounding, and restart it after a real discontinuity.
            var sampleStart = rawStart
            let hasSampleClock = useSampleClock && decodedSamples > 0
            if hasSampleClock, let priorSampleEnd,
               abs(rawStart.seconds - priorSampleEnd.seconds) <= stream.timeBase.seconds + 0.5 / Double(sampleRate) {
                sampleStart = priorSampleEnd
            }
            let audibleStart = skip == 0 ? sampleStart : try sampleStart.adding(RationalTime(numerator: Int64(skip), denominator: sampleRate))
            let decodedEnd = decodedSamples > 0
                ? try sampleStart.adding(RationalTime(numerator: Int64(decodedSamples), denominator: sampleRate))
                : rawEnd
            priorSampleEnd = hasSampleClock ? decodedEnd : nil
            // A demuxer can report an already shortened final packet together
            // with the padding that must be discarded from its coded samples.
            let trimmedEnd = discard == 0 ? decodedEnd : try decodedEnd.subtracting(
                RationalTime(numerator: Int64(discard), denominator: sampleRate))
            let audibleEnd = hasSampleClock ? trimmedEnd : min(rawEnd, trimmedEnd)
            // A gapless encoder can place several packets of decoder priming or
            // terminal padding in one skip/discard tag (for example a cropped MP3).
            if index == 0 && skip > 0 { firstAudibleSample = audibleStart }
            if index == packets.count - 1 && discard > 0 { lastAudibleSample = audibleEnd }
            if audibleStart < audibleEnd && !(index == 0 && stream.codec == "vorbis") {
                if stream.isPCM {
                    if let previous = pcmAudibleEnd, previous < audibleStart {
                        let gap = try audibleStart.subtracting(previous)
                        if skip > 0 || priorPCMDiscard > 0 || gap > pcmGapTolerance {
                            pcmGaps.append(.init(from: previous, to: audibleStart))
                        }
                    }
                    pcmAudibleEnd = max(pcmAudibleEnd ?? audibleEnd, audibleEnd)
                    priorPCMDiscard = discard
                }
                start = min(start ?? audibleStart, audibleStart)
                end = max(end ?? audibleEnd, audibleEnd)
            }
            if !stream.isPCM {
                let dts = packet.dts == packet.pts ? rawStart : try relativeDTS(packet, base: stream.timeBase, origin: origin)
                indexed.append(AudioPacket(time: rawStart, dts: dts,
                                           duration: duration, skipSamples: skip, discardSamples: discard,
                                           decodedSamples: decodedSamples))
            }
        }
        var trackStart = start ?? stream.start
        var trackEnd = end ?? trackStart
        if let firstAudibleSample { trackStart = max(trackStart, firstAudibleSample) }
        if let lastAudibleSample { trackEnd = min(trackEnd, lastAudibleSample) }
        return AudioIndex(stream: stream, packets: indexed, start: trackStart,
                          end: max(trackStart, trackEnd), hasPriming: hasPriming,
                          pcmContinuity: pcmContinuity, presentationEdits: [],
                          pcmGaps: pcmGaps.compactMap { gap in
                              let from = max(trackStart, gap.from), to = min(trackEnd, gap.to)
                              return from < to ? MulticamRange(from: from, to: to) : nil
                          })
    }

    static func describe(_ value: MPProbeStream, index: Int, base: RationalTime,
                         start: RationalTime, duration: RationalTime) -> StreamInfo {
        let name = fixedString(value.name).trimmingCharacters(in: .whitespacesAndNewlines)
        return StreamInfo(
            index: index, trackID: value.track_id, kind: string(value.kind), codec: string(value.codec),
            codecTag: fixedString(value.codec_tag),
            profile: Int(value.profile), width: Int(value.width), height: Int(value.height),
            displayWidth: Int(value.display_width), displayHeight: Int(value.display_height), rotation: Int(value.rotation),
            rotationOnly: value.rotation_only != 0,
            bitDepth: Int(value.bit_depth), pixelFormat: string(value.pixel_format), alphaBits: Int(value.alpha_bits),
            hasAdditionalVideoLayers: value.multilayer != 0,
            frameRate: ratio(value.rate_num, value.rate_den), sampleAspectRatio: ratio(value.sar_num, value.sar_den),
            timeBase: base, start: start, hasDeclaredStart: value.start != .min,
            duration: duration, sampleRate: Int(value.sample_rate),
            channels: Int(value.channels), channelLayout: fixedString(value.channel_layout),
            language: value.language.map { String(cString: $0).lowercased() } ?? "und",
            disposition: Int(value.disposition), isPCM: value.pcm != 0,
            initialPadding: Int(value.initial_padding), trailingPadding: Int(value.trailing_padding),
            seekPreroll: Int(value.seek_preroll), colorPrimaries: string(value.primaries),
            colorTransfer: string(value.transfer), colorMatrix: string(value.matrix),
            fieldOrder: fieldOrder(value.field_order), chromaLocation: string(value.chroma_location),
            colorRange: string(value.range),
            configuration: data(value.config, size: value.config_size), codecMetadata: data(value.metadata, size: value.metadata_size),
            multipleDescriptions: value.multiple_descriptions != 0, complexPicture: value.complex_picture != 0,
            reconstructedDTS: value.reconstructed_dts != 0, name: name.isEmpty ? nil : name)
    }

    static func fieldOrder(_ value: Int32) -> String {
        switch value {
        case 1: return "progressive"
        case 2: return "tt"
        case 3: return "bb"
        case 4: return "tb"
        case 5: return "bt"
        default: return "unknown"
        }
    }

    static func relativeTime(_ ticks: Int64, base: RationalTime, origin: RationalTime) throws -> RationalTime {
        let time = try timestamp(ticks, base: base)
        return origin == .zero ? time : try time.subtracting(origin)
    }

    static func relativeDTS(_ packet: MPProbePacket, base: RationalTime, origin: RationalTime) throws -> RationalTime? {
        packet.dts == .min ? nil : try relativeTime(packet.dts, base: base, origin: origin)
    }

    static func ratio(_ numerator: Int32, _ denominator: Int32) -> RationalTime {
        guard denominator > 0 else { return .zero }
        return RationalTime(numerator: Int64(numerator), denominator: Int64(denominator))
    }

    static func timeBase(_ stream: MPProbeStream) -> RationalTime { ratio(stream.tb_num, stream.tb_den) }

    static func timestamp(_ ticks: Int64, base: RationalTime) throws -> RationalTime {
        guard ticks != .min else { return .zero }
        if base.numerator == 1 { return RationalTime(numerator: ticks, denominator: base.denominator) }
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
