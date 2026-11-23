import CFFmpeg
import CryptoKit
import Foundation

// The public inspection JSON deliberately omits private codec configurations and
// trim flags. Store that representation plus the fields needed to reproduce an edit.
private struct IndexStream: Codable {
    let value: StreamInfo

    init(_ value: StreamInfo) { self.value = value }

    private enum Keys: String, CodingKey {
        case info, configuration
        case trackID = "track_id"
        case rotationOnly = "rotation_only"
        case hasDeclaredStart = "has_declared_start"
        case codecMetadata = "codec_metadata"
        case multipleDescriptions = "multiple_descriptions"
        case complexPicture = "complex_picture"
        case reconstructedDTS = "reconstructed_dts"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(value, forKey: .info)
        try c.encode(value.trackID, forKey: .trackID)
        try c.encode(value.rotationOnly, forKey: .rotationOnly)
        try c.encode(value.hasDeclaredStart, forKey: .hasDeclaredStart)
        try c.encode(value.configuration, forKey: .configuration)
        try c.encode(value.codecMetadata, forKey: .codecMetadata)
        try c.encode(value.multipleDescriptions, forKey: .multipleDescriptions)
        try c.encode(value.complexPicture, forKey: .complexPicture)
        try c.encode(value.reconstructedDTS, forKey: .reconstructedDTS)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let info = try c.nestedContainer(keyedBy: StreamInfo.CodingKeys.self, forKey: .info)
        func field<T: Decodable>(_ key: StreamInfo.CodingKeys) throws -> T { try info.decode(T.self, forKey: key) }
        func integer(_ key: StreamInfo.CodingKeys) throws -> Int { Int(try info.decode(Int32.self, forKey: key)) }
        func extra<T: Decodable>(_ key: Keys) throws -> T { try c.decode(T.self, forKey: key) }
        value = try StreamInfo(
            index: integer(.index), trackID: extra(.trackID), kind: field(.kind), codec: field(.codec),
            codecTag: field(.codecTag), profile: integer(.profile), width: integer(.width), height: integer(.height),
            displayWidth: integer(.displayWidth), displayHeight: integer(.displayHeight), rotation: integer(.rotation),
            rotationOnly: extra(.rotationOnly), bitDepth: integer(.bitDepth), pixelFormat: field(.pixelFormat),
            alphaBits: integer(.alphaBits), hasAdditionalVideoLayers: field(.hasAdditionalVideoLayers),
            frameRate: field(.frameRate), sampleAspectRatio: field(.sampleAspectRatio), timeBase: field(.timeBase),
            start: field(.start), hasDeclaredStart: extra(.hasDeclaredStart), duration: field(.duration),
            sampleRate: integer(.sampleRate), channels: integer(.channels), channelLayout: field(.channelLayout),
            language: field(.language), disposition: integer(.disposition), isPCM: field(.isPCM),
            initialPadding: integer(.initialPadding), trailingPadding: integer(.trailingPadding), seekPreroll: integer(.seekPreroll),
            colorPrimaries: field(.colorPrimaries), colorTransfer: field(.colorTransfer), colorMatrix: field(.colorMatrix),
            fieldOrder: field(.fieldOrder), chromaLocation: field(.chromaLocation), colorRange: field(.colorRange),
            configuration: extra(.configuration), codecMetadata: extra(.codecMetadata),
            multipleDescriptions: extra(.multipleDescriptions), complexPicture: extra(.complexPicture),
            reconstructedDTS: extra(.reconstructedDTS))
    }
}

private struct IndexHeader: Codable {
    private enum CodingKeys: String, CodingKey {
        case identity, format, duration, origin, streams, audio
        case probeRevision = "probe_revision"
        case sourceExtension = "source_extension"
        case muxerBuild = "muxer_build"
        case reportedContainers = "reported_containers"
        case videoIndex = "video_index"
        case frameCount = "frame_count"
        case copyIssue = "copy_issue"
        case audioIssues = "audio_issues"
        case timelineIssue = "timeline_issue"
        case sourceStartSafe = "source_start_safe"
    }

    private static let currentProbeRevision = 7
    let probeRevision: Int
    let identity: SourceIdentity
    let sourceExtension: String
    let muxerBuild: String
    let reportedContainers: [String]
    let format: String
    let duration: RationalTime
    let origin: RationalTime
    let streams: [IndexStream]
    let videoIndex: Int
    let frameCount: Int
    let audio: [Track]

    let copyIssue: String?
    let audioIssues: [Int: String]?
    let timelineIssue: String?
    let sourceStartSafe: Bool

    struct Track: Codable {
        private enum CodingKeys: String, CodingKey {
            case index, start, end, opus
            case hasPriming = "has_priming"
            case pcmContinuity = "pcm_continuity"
            case packetCount = "packet_count"
            case editCount = "edit_count"
            case mp3Anchors = "mp3_anchors"
            case pcmGaps = "pcm_gaps"
            case codedBytes = "coded_bytes"
        }

        let index: Int
        let start: RationalTime
        let end: RationalTime
        let hasPriming: Bool
        let pcmContinuity: Bool
        let packetCount: Int
        let editCount: Int
        let opus: OpusHeader?
        let mp3Anchors: [MP3Anchor]?
        let pcmGaps: [MulticamRange]?
        let codedBytes: Int64?
    }

    struct OpusHeader: Codable {
        private enum CodingKeys: String, CodingKey {
            case start, end, complete, count
            case firstPacketEnd = "first_packet_end"
            case initialPadding = "initial_padding"
        }

        let start: Int64
        let firstPacketEnd: Int64
        let end: Int64
        let initialPadding: Int
        let complete: Bool
        let count: Int
    }

    init(_ media: MediaInfo) {
        probeRevision = Self.currentProbeRevision
        identity = media.identity
        sourceExtension = media.url.pathExtension.lowercased()
        muxerBuild = Self.currentMuxerBuild
        reportedContainers = CutEngine().suggestedContainers(for: media)
        format = media.format
        duration = media.duration
        origin = media.origin
        streams = media.streams.map(IndexStream.init)
        videoIndex = media.videoStream?.index ?? -1
        frameCount = media.frames.count
        audio = media.audio.map { track in
            let opus = track.opusWindow.map {
                OpusHeader(start: $0.start, firstPacketEnd: $0.firstPacketEnd, end: $0.end,
                           initialPadding: $0.initialPadding, complete: $0.complete, count: $0.packetStarts.count)
            }
            return Track(index: track.stream.index, start: track.start, end: track.end, hasPriming: track.hasPriming,
                         pcmContinuity: track.pcmContinuity, packetCount: track.packets.count,
                         editCount: track.presentationEdits.count, opus: opus,
                         mp3Anchors: track.mp3Anchors.isEmpty ? nil : track.mp3Anchors,
                         pcmGaps: track.pcmGaps.isEmpty ? nil : track.pcmGaps, codedBytes: track.codedBytes)
        }
        copyIssue = media.copyIssue
        audioIssues = media.audioIssues.isEmpty ? nil : media.audioIssues
        timelineIssue = media.timelineIssue
        sourceStartSafe = media.sourceStartSafe
    }

    var isUsable: Bool {
        let descriptions = streams.map(\.value)
        guard probeRevision == Self.currentProbeRevision else { return false }
        guard duration > .zero, descriptions.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              audio.map(\.index) == descriptions.filter({ $0.kind == "audio" }).map(\.index),
              audio.allSatisfy({ $0.packetCount >= 0 && $0.editCount >= 0 }) else { return false }
        for track in audio {
            var cursor = track.start
            for gap in track.pcmGaps ?? [] {
                guard descriptions[track.index].isPCM, cursor <= gap.from, gap.from < gap.to, gap.to <= track.end else {
                    return false
                }
                cursor = gap.to
            }
        }
        if videoIndex == -1 {
            guard frameCount == 0, let first = audio.first else { return false }
            return descriptions[first.index].timeBase > .zero && descriptions[first.index].sampleRate > 0 &&
                !descriptions.contains { $0.kind == "video" }
        }
        return frameCount > 0 && descriptions.indices.contains(videoIndex) &&
            descriptions[videoIndex].kind == "video" && descriptions[videoIndex].timeBase > .zero
    }

    // An agent CLI and the app can use different FFmpeg builds. Their available
    // muxers need not agree, even when the source index is identical.
    static let currentMuxerBuild: String = {
        let library = String(avformat_version()) + ":" + String(cString: avformat_configuration())
        return Data(SHA256.hash(data: Data(library.utf8))).base64EncodedString()
    }()
}

private enum IndexCodingError: Error { case invalid }
enum SidecarIndexDetail { case preview, summary, analysis, audio, full }

private struct CachedSceneClock: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, duration, origin, video
        case changedSeconds = "changed_seconds"
        case changedNanoseconds = "changed_nanoseconds"
    }

    let format: String
    let duration: RationalTime
    let origin: RationalTime
    let video: IndexStream
    let changedSeconds: Int
    let changedNanoseconds: Int
}

extension AnalysisSidecar {
    // A scene-only sidecar can resolve later ranges and resumes without
    // opening the media or storing the editor's complete packet index.
    static let sceneClockKey = "scenes_clock.v1"

    static func encodeSceneClock(_ media: MediaInfo) throws -> Data? {
        guard let video = media.videoStream, !media.hasProvisionalClock,
              media.multicamClockOffset == .zero, let change = media.identity.changeTime else { return nil }
        return try PropertyListEncoder().encode(CachedSceneClock(format: media.format, duration: media.duration,
                                                                 origin: media.origin, video: IndexStream(video),
                                                                 changedSeconds: change.seconds,
                                                                 changedNanoseconds: change.nanoseconds))
    }

    func loadSceneClock(cancelled: () -> Bool) -> MediaInfo? {
        guard let change = identity.changeTime,
              let data = read(Self.sceneClockKey, cancelled: cancelled),
              let clock = try? PropertyListDecoder().decode(CachedSceneClock.self, from: data),
              clock.changedSeconds == change.seconds, clock.changedNanoseconds == change.nanoseconds,
              clock.duration > .zero, clock.video.value.kind == "video",
              clock.video.value.index >= 0, clock.video.value.timeBase > .zero else { return nil }
        return MediaInfo(url: source, format: clock.format, duration: clock.duration, origin: clock.origin,
                         streams: [clock.video.value], frames: [], audio: [], copyIssue: nil,
                         sourceStartSafe: false, identity: identity, videoIndex: 0, metadataOnly: true)
    }
}

// Unsigned LEB128 and zigzag integers retain the exact rational values without
// storing repeated field names, padding, or a second timestamp when PTS == DTS.
private struct IndexWriter {
    var bytes: [UInt8] = []

    mutating func unsigned(_ value: UInt64) {
        var n = value
        while n >= 128 {
            bytes.append(UInt8(truncatingIfNeeded: n) | 0x80)
            n >>= 7
        }
        bytes.append(UInt8(n))
    }

    mutating func signed(_ value: Int64) {
        unsigned(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func time(_ value: RationalTime) {
        signed(value.numerator)
        unsigned(UInt64(value.denominator))
    }

    mutating func timestamps(_ time: RationalTime, _ dts: RationalTime?, flags: UInt8) {
        let kind: UInt8 = dts == nil ? 0 : dts == time ? 1 : 2
        bytes.append(flags | kind)
        self.time(time)
        if kind == 2, let dts { self.time(dts) }
    }
}

private struct IndexReader {
    let bytes: UnsafeRawBufferPointer
    var position = 0
    private var lastDuration: RationalTime?
    var remaining: Int { bytes.count - position }

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw IndexCodingError.invalid }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func unsigned() throws -> UInt64 {
        let first = try byte()
        if first < 128 { return UInt64(first) }

        var n = UInt64(first & 0x7f)
        var shift = 7
        while position < bytes.count, shift <= 63 {
            let next = bytes[position]
            position += 1
            guard shift != 63 || next <= 1 else { throw IndexCodingError.invalid }
            n |= UInt64(next & 0x7f) << shift
            if next < 128 { return n }
            shift += 7
        }
        throw IndexCodingError.invalid
    }

    mutating func signed() throws -> Int64 {
        let n = try unsigned()
        return Int64(bitPattern: n >> 1) ^ -Int64(n & 1)
    }

    private mutating func timeParts() throws -> (numerator: Int64, denominator: Int64) {
        let top = try signed()
        guard let bottom = Int64(exactly: try unsigned()), bottom > 0 else { throw IndexCodingError.invalid }
        return (top, bottom)
    }

    mutating func time() throws -> RationalTime {
        let (top, bottom) = try timeParts()
        return RationalTime(numerator: top, denominator: bottom)
    }

    mutating func duration() throws -> RationalTime {
        let (top, bottom) = try timeParts()
        // The writer stores reduced rationals. Repeated durations are common
        // even when presentation timestamps differ on every row.
        if let lastDuration, lastDuration.numerator == top, lastDuration.denominator == bottom {
            return lastDuration
        }
        let value = RationalTime(numerator: top, denominator: bottom)
        lastDuration = value
        return value
    }

    mutating func timestamps(allowedFlags: UInt8) throws -> (UInt8, RationalTime, RationalTime?) {
        let flags = try byte()
        let kind = flags & 3
        guard flags & ~(allowedFlags | 3) == 0, kind != 3 else { throw IndexCodingError.invalid }
        let pts = try time()
        let dts = kind == 0 ? nil : kind == 1 ? pts : try time()
        return (flags, pts, dts)
    }

    func checkCount(_ count: Int, minimumBytes: Int) throws {
        guard count >= 0, count <= remaining / minimumBytes else { throw IndexCodingError.invalid }
    }
}

private func checkIndexCancellation(_ cancelled: () -> Bool) throws {
    if cancelled() { throw CutError(code: "cancelled", message: "Index loading or saving was cancelled.") }
}

extension AnalysisSidecar {
    public static var indexKeys: Set<String> { ["media_index.v1", "media_index_frames.v1", "media_index_audio.v1"] }

    /// Archive a fully inspected source. Merge all returned sections in one save.
    public static func indexSections(for media: MediaInfo, progress: ((Double) -> Void)? = nil, cancelled: () -> Bool = { false }) throws -> [String: Data] {
        try checkIndexCancellation(cancelled)
        guard media.hasFullEditIndex else {
            throw CutError(code: "incomplete_index", message: "A full editing index is required to save analysis.")
        }
        let header = IndexHeader(media)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        // Each row stores absolute timestamps. Encoded batches can be joined
        // directly without rebasing any row.
        let total = max(1, media.audio.reduce(Double(media.frames.count)) { sum, track in
            sum + Double(track.packets.count) + Double(track.presentationEdits.count) + Double(track.opusWindow?.packetStarts.count ?? 0)
        })
        var completed = 0
        func appendRows<Row>(_ rows: [Row], to data: inout Data, write: (inout IndexWriter, Row) -> Void) throws {
            try forEachOrderedBatch(count: rows.count, batchSize: 2048, check: {
                try checkIndexCancellation(cancelled)
            }, transform: { range in
                var writer = IndexWriter()
                for row in rows[range] { write(&writer, row) }
                return (writer.bytes, range.count)
            }, consume: { bytes, count in
                data.append(contentsOf: bytes)
                completed += count
                progress?(Double(completed) / total)
            })
        }
        var frames = Data()
        try appendRows(media.frames, to: &frames) { writer, frame in
            let flags: UInt8 = (frame.keyframe ? 4 : 0) | (frame.canStart ? 8 : 0) | (frame.canEnd ? 16 : 0)
            writer.timestamps(frame.time, frame.dts, flags: flags)
            writer.time(frame.duration)
            writer.unsigned(UInt64(frame.byteCount))
        }
        var audio = Data()
        for track in media.audio {
            try appendRows(track.packets, to: &audio) { writer, packet in
                writer.timestamps(packet.time, packet.dts, flags: 0)
                writer.time(packet.duration)
                writer.signed(Int64(packet.skipSamples))
                writer.signed(Int64(packet.discardSamples))
                writer.signed(Int64(packet.decodedSamples))
            }
            try appendRows(track.presentationEdits, to: &audio) { writer, edit in
                writer.signed(edit.samples.lowerBound)
                writer.signed(edit.samples.upperBound)
                writer.bytes.append(edit.isAudible ? 1 : 0)
            }
            if let window = track.opusWindow {
                try appendRows(window.packetStarts, to: &audio) { writer, start in writer.signed(start) }
            }
        }
        try checkIndexCancellation(cancelled)
        var sections = ["media_index.v1": try encoder.encode(header), "media_index_frames.v1": frames, "media_index_audio.v1": audio]
        if let evidence = media.refreshEvidence {
            sections[MediaRefreshEvidence.sectionKey] = try evidence.encoded()
        }
        return sections
    }

    func loadIndex(detail: SidecarIndexDetail, progress: ((Double) -> Void)? = nil, cancelled: () -> Bool) throws -> MediaInfo? {
        try withReadSnapshot(cancelled: cancelled) { read in
            try decodeIndex(detail: detail, read: read, progress: progress, cancelled: cancelled)
        }
    }

    private func decodeIndex(detail: SidecarIndexDetail, read: (String) -> Data?, progress: ((Double) -> Void)?,
                             cancelled: () -> Bool) throws -> MediaInfo? {
        guard let metadata = read("media_index.v1"),
              let header = try? PropertyListDecoder().decode(IndexHeader.self, from: metadata),
              identity.matches(saved: header.identity), header.isUsable
        else { return nil }
        let frameRows = detail == .full ? header.frameCount : 0
        let total = max(1, header.audio.reduce(Double(frameRows)) {
            $0 + Double($1.packetCount) + Double($1.editCount) + Double($1.opus?.count ?? 0)
        })
        var done = Double(frameRows)
        let streams = header.streams.map(\.value)
        let suggestions: Set<String>? = detail == .summary && header.muxerBuild == IndexHeader.currentMuxerBuild &&
            source.pathExtension.lowercased() == header.sourceExtension ? Set(header.reportedContainers) : nil
        var frames: [FrameInfo] = []
        var audio: [AudioIndex] = []
        do {
            if detail == .full {
                guard let data = read("media_index_frames.v1") else { return nil }
                frames = try data.withUnsafeBytes { bytes in
                    var reader = IndexReader(bytes: bytes)
                    try reader.checkCount(header.frameCount, minimumBytes: 6)
                    var rows: [FrameInfo] = []
                    rows.reserveCapacity(header.frameCount)
                    for i in 0..<header.frameCount {
                        if i.isMultiple(of: 1024) {
                            try checkIndexCancellation(cancelled)
                            progress?(Double(i) / total)
                        }
                        let (flags, pts, dts) = try reader.timestamps(allowedFlags: 28)
                        let duration = try reader.duration()
                        guard let size = UInt32(exactly: try reader.unsigned()), duration > .zero,
                              rows.last.map({ $0.time <= pts }) ?? true else { throw IndexCodingError.invalid }
                        rows.append(FrameInfo(dts: dts, time: pts, duration: duration, keyframe: flags & 4 != 0,
                                              canStart: flags & 8 != 0, canEnd: flags & 16 != 0, byteCount: size))
                    }
                    guard reader.remaining == 0 else { throw IndexCodingError.invalid }
                    return rows
                }
            }
            let useHeaderOnly: Bool
            switch detail {
            case .analysis:
                // Waveforms need the exact origin and any MOV presentation edits.
                // The packet list used to plan a lossless cut can stay on disk.
                useHeaderOnly = header.audio.allSatisfy { $0.editCount == 0 }
            case .summary:
                // AAC presentation edits and the final Opus packet's discard count
                // affect mux compatibility. For ordinary tracks the header is enough.
                useHeaderOnly = suggestions != nil || header.audio.allSatisfy { $0.editCount == 0 && streams[$0.index].codec != "opus" }
            default:
                useHeaderOnly = false
            }
            if useHeaderOnly {
                audio = header.audio.map {
                    AudioIndex(stream: streams[$0.index], packets: [], start: $0.start, end: $0.end,
                               hasPriming: $0.hasPriming, pcmContinuity: $0.pcmContinuity, presentationEdits: [],
                               pcmGaps: $0.pcmGaps ?? [], codedBytes: $0.codedBytes)
                }
            } else if detail != .preview {
                guard let data = read("media_index_audio.v1") else { return nil }
                audio = try data.withUnsafeBytes { bytes in
                    var reader = IndexReader(bytes: bytes)
                    let tracks = try header.audio.map { track in
                        let result = try reader.audio(track, stream: streams[track.index], keepPackets: detail != .analysis,
                                         keepOpusWindow: detail == .full || (detail == .audio && header.videoIndex < 0),
                                         progress: { progress?((done + $0) / total) }, cancelled: cancelled)
                        done += Double(track.packetCount) + Double(track.editCount) + Double(track.opus?.count ?? 0)
                        return result
                    }
                    guard reader.remaining == 0 else { throw IndexCodingError.invalid }
                    return tracks
                }
            }
        } catch is IndexCodingError { return nil }
        progress?(1)
        return MediaInfo(url: source, format: header.format, duration: header.duration, origin: header.origin,
                         streams: streams, frames: frames, audio: audio, copyIssue: header.copyIssue,
                         sourceStartSafe: header.sourceStartSafe, identity: identity, videoIndex: header.videoIndex,
                         timelineIssue: header.timelineIssue, reportedContainers: suggestions,
                         metadataOnly: detail == .preview || detail == .summary || detail == .analysis,
                         audioIssues: header.audioIssues ?? [:],
                         refreshEvidence: MediaRefreshEvidence.decode(read(MediaRefreshEvidence.sectionKey)))
    }
}

private extension IndexReader {
    mutating func audio(_ track: IndexHeader.Track, stream: StreamInfo, keepPackets: Bool, keepOpusWindow: Bool,
                        progress: (Double) -> Void, cancelled: () -> Bool) throws -> AudioIndex {
        try checkCount(track.packetCount, minimumBytes: 8)
        var packets: [AudioPacket] = []
        if keepPackets { packets.reserveCapacity(track.packetCount) }
        for i in 0..<track.packetCount {
            if i.isMultiple(of: 1024) {
                try checkIndexCancellation(cancelled)
                progress(Double(i))
            }
            let (_, pts, dts) = try timestamps(allowedFlags: 0)
            let duration = try duration()
            let skip = Int(try signed()), discard = Int(try signed()), decoded = Int(try signed())
            guard (0...Int(UInt32.max)).contains(skip), (0...Int(UInt32.max)).contains(discard) else {
                throw IndexCodingError.invalid
            }
            if keepPackets {
                packets.append(AudioPacket(time: pts, dts: dts, duration: duration, skipSamples: skip,
                                           discardSamples: discard, decodedSamples: decoded))
            }
        }
        try checkCount(track.editCount, minimumBytes: 3)
        var edits: [AACPresentationEdit] = []
        edits.reserveCapacity(track.editCount)
        for i in 0..<track.editCount {
            if i.isMultiple(of: 1024) {
                try checkIndexCancellation(cancelled)
                progress(Double(track.packetCount) + Double(i))
            }
            let from = try signed(), to = try signed(), audible = try byte()
            guard from < to, audible <= 1 else { throw IndexCodingError.invalid }
            edits.append(AACPresentationEdit(samples: from..<to, isAudible: audible == 1))
        }

        var window: OpusTrimWindow?
        if let opus = track.opus {
            try checkCount(opus.count, minimumBytes: 1)
            guard opus.count > 0, opus.count <= track.packetCount,
                  opus.complete == (opus.count == track.packetCount), (0...65_535).contains(opus.initialPadding),
                  opus.firstPacketEnd <= opus.end else { throw IndexCodingError.invalid }
            var starts: [Int64] = []
            if keepOpusWindow { starts.reserveCapacity(opus.count) }
            var prior: Int64?
            for i in 0..<opus.count {
                if i.isMultiple(of: 1024) {
                    try checkIndexCancellation(cancelled)
                    progress(Double(track.packetCount) + Double(track.editCount) + Double(i))
                }
                let start = try signed()
                guard prior.map({ start > $0 }) ?? true else { throw IndexCodingError.invalid }
                prior = start
                if keepOpusWindow { starts.append(start) }
            }
            if keepOpusWindow {
                window = OpusTrimWindow(start: opus.start, firstPacketEnd: opus.firstPacketEnd, end: opus.end,
                                        initialPadding: opus.initialPadding, complete: opus.complete, packetStarts: starts)
            }
        }
        return AudioIndex(stream: stream, packets: packets, start: track.start, end: track.end,
                          hasPriming: track.hasPriming, pcmContinuity: track.pcmContinuity,
                          presentationEdits: edits, mp3Anchors: track.mp3Anchors ?? [], opusWindow: window,
                          pcmGaps: track.pcmGaps ?? [], codedBytes: track.codedBytes)
    }
}
