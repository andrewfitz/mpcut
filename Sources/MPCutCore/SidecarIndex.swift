import CFFmpeg
import CryptoKit
import Foundation

// The public inspection JSON deliberately omits private codec configurations and
// trim flags. Store that representation plus the fields needed to reproduce an edit.
private struct IndexStream: Codable {
    let value: StreamInfo

    init(_ value: StreamInfo) { self.value = value }

    private enum Keys: String, CodingKey {
        case info, trackID, rotationOnly, hasDeclaredStart, configuration, codecMetadata
        case multipleDescriptions, complexPicture, reconstructedDTS
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
    private static let currentProbeRevision = 5
    let probeRevision: Int?
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
        let index: Int
        let start: RationalTime
        let end: RationalTime
        let hasPriming: Bool
        let pcmContinuity: Bool
        let packetCount: Int
        let editCount: Int
        let opus: OpusHeader?
    }

    struct OpusHeader: Codable {
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
                         editCount: track.presentationEdits.count, opus: opus)
        }
        copyIssue = media.copyIssue
        audioIssues = media.audioIssues.isEmpty ? nil : media.audioIssues
        timelineIssue = media.timelineIssue
        sourceStartSafe = media.sourceStartSafe
    }

    var isUsable: Bool {
        let descriptions = streams.map(\.value)
        let revision = probeRevision ?? 1
        guard (1...Self.currentProbeRevision).contains(revision) else { return false }
        if revision < 2 {
            // The auxiliary-track advisory could previously hide a packet defect.
            // These standalone audio codecs also gained corrected clocks or preroll.
            if copyIssue == MediaInfo.auxiliaryTrackIssue { return false }
            if videoIndex == -1, descriptions.contains(where: { ["mp3", "vorbis", "opus"].contains($0.codec) }) { return false }
        }
        if revision < 3, videoIndex == -1, descriptions.contains(where: {
            ($0.isPCM || $0.codec == "flac") && $0.sampleRate > 0 &&
                $0.timeBase > RationalTime(numerator: 1, denominator: Int64($0.sampleRate))
        }) { return false }
        // A per-track issue used to be recorded for the first affected track only.
        if revision < 4, audio.count > 1, let copyIssue,
           copyIssue.hasPrefix("Audio track ") || copyIssue.hasPrefix("AAC track ") { return false }
        // Older indexes recorded these audio clock defects without a stream index.
        if revision < 5,
           copyIssue == "An audio track has non-increasing presentation timestamps." ||
           copyIssue == "An audio packet is missing its duration." { return false }
        guard duration > .zero, descriptions.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              audio.map(\.index) == descriptions.filter({ $0.kind == "audio" }).map(\.index),
              audio.allSatisfy({ $0.packetCount >= 0 && $0.editCount >= 0 }) else { return false }
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
    var remaining: Int { bytes.count - position }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw IndexCodingError.invalid }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func unsigned() throws -> UInt64 {
        var n: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let b = try byte()
            guard shift != 63 || b <= 1 else { throw IndexCodingError.invalid }
            n |= UInt64(b & 0x7f) << shift
            if b < 128 { return n }
        }
        throw IndexCodingError.invalid
    }

    mutating func signed() throws -> Int64 {
        let n = try unsigned()
        return Int64(bitPattern: n >> 1) ^ -Int64(n & 1)
    }

    mutating func time() throws -> RationalTime {
        let top = try signed()
        guard let bottom = Int64(exactly: try unsigned()), bottom > 0 else { throw IndexCodingError.invalid }
        return RationalTime(numerator: top, denominator: bottom)
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
    public static var indexKeys: Set<String> { ["index.v1", "index.frames.v1", "index.audio.v1"] }

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
        // directly, including on older sidecars that use this same byte layout.
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
        return ["index.v1": try encoder.encode(header), "index.frames.v1": frames, "index.audio.v1": audio]
    }

    func loadIndex(detail: SidecarIndexDetail, progress: ((Double) -> Void)? = nil, cancelled: () -> Bool) throws -> MediaInfo? {
        try withReadSnapshot(cancelled: cancelled) { read in
            try decodeIndex(detail: detail, read: read, progress: progress, cancelled: cancelled)
        }
    }

    private func decodeIndex(detail: SidecarIndexDetail, read: (String) -> Data?, progress: ((Double) -> Void)?,
                             cancelled: () -> Bool) throws -> MediaInfo? {
        guard let metadata = read("index.v1"),
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
                guard let data = read("index.frames.v1") else { return nil }
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
                        let duration = try reader.time()
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
                               hasPriming: $0.hasPriming, pcmContinuity: $0.pcmContinuity, presentationEdits: [])
                }
            } else if detail != .preview {
                guard let data = read("index.audio.v1") else { return nil }
                audio = try data.withUnsafeBytes { bytes in
                    var reader = IndexReader(bytes: bytes)
                    let tracks = try header.audio.map { track in
                        let result = try reader.audio(track, stream: streams[track.index], keepOpusWindow: detail == .full || (detail == .audio && header.videoIndex < 0),
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
                         audioIssues: header.audioIssues ?? [:])
    }
}

private extension IndexReader {
    mutating func audio(_ track: IndexHeader.Track, stream: StreamInfo, keepOpusWindow: Bool,
                        progress: (Double) -> Void, cancelled: () -> Bool) throws -> AudioIndex {
        try checkCount(track.packetCount, minimumBytes: 8)
        var packets: [AudioPacket] = []
        packets.reserveCapacity(track.packetCount)
        for i in 0..<track.packetCount {
            if i.isMultiple(of: 1024) {
                try checkIndexCancellation(cancelled)
                progress(Double(i))
            }
            let (_, pts, dts) = try timestamps(allowedFlags: 0)
            let duration = try time()
            let skip = Int(try signed()), discard = Int(try signed()), decoded = Int(try signed())
            guard (0...Int(UInt32.max)).contains(skip), (0...Int(UInt32.max)).contains(discard) else {
                throw IndexCodingError.invalid
            }
            packets.append(AudioPacket(time: pts, dts: dts, duration: duration, skipSamples: skip,
                                       discardSamples: discard, decodedSamples: decoded))
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
            guard opus.count > 0, opus.count <= packets.count,
                  opus.complete == (opus.count == packets.count), (0...65_535).contains(opus.initialPadding),
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
                          presentationEdits: edits, opusWindow: window)
    }
}
