import Foundation
import CFFmpeg
import PacketWriter
import VideoToolbox

private let hardwareAV1Decode = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

/// What one encoded edge of a written export cost. Only an export reports it: a plan cannot know it,
/// so it is kept apart from `encoded_edges`, which a dry run and the export report alike.
public struct EncodedEdgeResult: Encodable, Sendable {
    /// One-based segment of the export.
    public let segment: Int
    public let from: RationalTime
    public let to: RationalTime
    /// Bytes the edge encoder produced. The muxer then drops AV1 temporal delimiters (2 bytes a picture)
    /// and moves AVC/HEVC parameter sets from the edge's first picture into its sample description.
    public let encodedBytes: UInt64
    /// The edge's duration at its `target_bit_rate`, in bytes.
    public let targetBytes: UInt64
    /// True when an AV1 edge over its budget was encoded a second time with a higher QP ceiling.
    public let retried: Bool
    /// The first encode's size, when the edge was retried.
    public let firstAttemptBytes: UInt64?
    /// The AV1 QP ceiling of the encode that was kept.
    public let maxQp: Int?
}

/// The cost of the edges an export writes, read from the edge encoder after `mpcut_write`.
public enum SmartTrimEdgeResults {
    public static func reset() { mpcut_edge_results_reset() }

    /// The edges written since `reset`, matched to the edit's encoded edges in output order.
    public static func take(for edit: ResolvedEdit) -> [EncodedEdgeResult] {
        var native = [MPCutEdgeResult](repeating: MPCutEdgeResult(), count: 256)
        let count = native.withUnsafeMutableBufferPointer { mpcut_edge_results_take($0.baseAddress, $0.count) }
        var written = native.prefix(count).map { result in
            (from: RationalTime(numerator: result.from.numerator, denominator: max(1, result.from.denominator)),
             to: RationalTime(numerator: result.to.numerator, denominator: max(1, result.to.denominator)), result: result)
        }
        var results: [EncodedEdgeResult] = []
        for (index, segment) in edit.segments.enumerated() {
            for edge in (segment.encodedEdges ?? []).sorted(by: { $0.from < $1.from }) {
                guard let match = written.firstIndex(where: { $0.from == edge.from && $0.to == edge.to }) else { continue }
                let item = written.remove(at: match).result
                results.append(EncodedEdgeResult(segment: index + 1, from: edge.from, to: edge.to, encodedBytes: item.bytes,
                                                 targetBytes: item.target_bytes, retried: item.retried != 0,
                                                 firstAttemptBytes: item.retried != 0 ? item.first_attempt_bytes : nil,
                                                 maxQp: item.max_qp > 0 ? Int(item.max_qp) : nil))
            }
        }
        return results
    }
}

extension CutEngine {
    /// True when Smart Trim encodes edges of this picture with every layer: 8-bit HEVC with an alpha layer, or
    /// MV-HEVC with two views, which AVFoundation decodes and VideoToolbox encodes again (`layered_edge.m`).
    public func smartTrimKeepsLayers(_ video: StreamInfo) -> Bool {
        guard video.codec == "hevc", video.hasAdditionalVideoLayers, video.profile == 1, video.bitDepth == 8 else { return false }
        return video.configuration.withUnsafeBytes { bytes in
            mpcut_smart_trim_keeps_layers(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) != 0
        }
    }

    /// Why Smart Trim cuts a picture with more than one layer only at keyframes where every layer starts, or nil.
    /// Its edges keep an HEVC alpha layer or a second view; other layers (H.264 auxiliary pictures, MVC or SVC,
    /// HEVC depth or Main 10 layers) an encoded edge would drop.
    public func smartTrimLayerNote(in media: MediaInfo) -> String? {
        guard media.hasVideo, media.video.hasAdditionalVideoLayers, !smartTrimKeepsLayers(media.video) else { return nil }
        let layers = media.video.codec == "h264" ? "H.264 auxiliary (alpha), MVC or SVC pictures"
            : "an additional HEVC layer (the second view of spatial video, or an alpha layer)"
        return "Smart Trim does not re-encode the edges of \(media.url.lastPathComponent): its picture carries \(layers), "
            + "which an encoded edge would drop, so it cuts only at keyframes where every layer starts."
    }

    /// Copy-safe boundaries remain available for every supported stream. Only extend
    /// the choices when we can reproduce the source's picture format at the edges.
    public func smartTrimEligible(in media: MediaInfo, container: String) -> Bool {
        let video = media.video
        let main10 = video.codec == "hevc" && video.profile == 2 && video.bitDepth == 10
            && video.pixelFormat == "yuv420p10le"
        let planar8 = video.bitDepth == 8 && ["yuv420p", "yuvj420p"].contains(video.pixelFormat)
        let keepsLayers = video.hasAdditionalVideoLayers && smartTrimKeepsLayers(video)
        // Spatial video states its stereo layout as container side data, which the copied entries keep and the layered
        // edge encoder states again, so that alone does not make the picture too complex for an encoded edge.
        let complex = video.complexPicture && !(keepsLayers && ["progressive", "unknown"].contains(video.fieldOrder)
            && video.codecMetadataTypes.isSubset(of: [UInt32(AV_PKT_DATA_DISPLAYMATRIX.rawValue),
                                                      UInt32(AV_PKT_DATA_STEREO3D.rawValue)]))
        guard media.sourceStartSafe, !video.multipleDescriptions, !video.hasAdditionalVideoLayers || keepsLayers,
              (planar8 || main10), !video.hasAlpha, !complex,
              ["unknown", "bt709", "bt470m", "bt470bg", "smpte170m", "smpte240m", "iec61966-2-1"].contains(video.colorTransfer),
              video.width > 0, video.height > 0, video.width.isMultiple(of: 2), video.height.isMultiple(of: 2) else {
            return false
        }
        let sourceFormats = media.format.split(separator: ",")
        switch video.codec {
        case "av1":
            return hardwareAV1Decode && sourceFormats.contains("matroska") && ["webm", "mkv"].contains(container)
                && video.profile == 0 && video.width >= 64 && video.height >= 64
        case "h264", "hevc":
            guard sourceFormats.contains("mov"), ["mov", "mp4", "m4v"].contains(container),
                  video.configuration.first == 1 else { return false }
            // A patch uses four-byte NAL lengths to match the original samples.
            // The hardware AVC encoder pads smaller coded pictures to at least 192×96.
            // Apple's reader cannot switch to those larger coded dimensions mid-track.
            if video.codec == "h264", video.width < 192 || video.height < 96 { return false }
            let lengthField = video.codec == "h264" ? 4 : 21
            return video.configuration.count > lengthField && video.configuration[lengthField] & 3 == 3
                && (video.codec == "hevc" ? (video.profile == 1 || main10) : [66, 578, 77, 100].contains(video.profile))
        default:
            return false
        }
    }
}

extension StreamInfo {
    /// The side data types the probe kept for this stream (`copy_metadata`: type, size, bytes, little-endian).
    var codecMetadataTypes: Set<UInt32> {
        codecMetadata.withUnsafeBytes { buffer in
            var types: Set<UInt32> = []
            var offset = 0
            while buffer.count - offset >= 8 {
                let type = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let size = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                guard size <= buffer.count - offset - 8 else { break }
                types.insert(type)
                offset += 8 + Int(size)
            }
            return types
        }
    }
}

/// Input is the existing presentation-order index. A verified seam also partitions
/// decode order, so copied pictures never reference the newly encoded pictures.
func smartTrimEdges(frames: [FrameInfo], kept: Range<Int>, from: RationalTime, to: RationalTime,
                    sourceEnd: RationalTime, codec: String, segment: Int) throws -> [EncodedEdge] {
    guard !kept.isEmpty else { return [] }
    let startSafe = from == .zero || frames[kept.lowerBound].canStart
    let endSafe = to == sourceEnd || (kept.upperBound < frames.count && frames[kept.upperBound].canEnd)
    if startSafe && endSafe { return [] }

    let headEnd = startSafe ? kept.lowerBound
        : kept.first(where: { frames[$0].canStart && frames[$0].canEnd }) ?? kept.upperBound
    let tailStart = endSafe ? kept.upperBound
        : kept.last(where: { frames[$0].canEnd }) ?? kept.lowerBound

    func edge(_ range: Range<Int>) throws -> EncodedEdge {
        let start = frames[range.lowerBound].time
        let end = range.upperBound == kept.upperBound ? to : frames[range.upperBound].time
        // A few dependent pictures alone can contain almost no data. Include their
        // source keyframe when budgeting the replacement's independent first picture.
        let first = frames[...range.lowerBound].lastIndex(where: { $0.canStart && $0.canEnd }) ?? 0
        let next = frames[range.upperBound...].firstIndex(where: { $0.canStart && $0.canEnd }) ?? frames.count
        let budgetEnd = next == frames.count ? sourceEnd : frames[next].time
        let seconds = try budgetEnd.subtracting(frames[first].time).seconds
        guard seconds > 0 else {
            throw CutError(code: "unsupported_timing", message: "The Smart Trim edge has no usable duration.", segment: segment)
        }
        let bytes = frames[first..<next].reduce(0.0) { $0 + Double($1.byteCount) }
        var bitsPerSecond = bytes * 8 / seconds
        // In footage that changes little, the source keyframe holds most of the picture group's bytes,
        // and the group's average rate leaves the edge's new keyframe far fewer bits than the source gave
        // it: a one-picture edge of a held still measured 36 dB against the source, 56 dB with this floor.
        // Such an edge gets at least the source keyframe's bytes plus the source bytes of its later
        // pictures. Where the average picture is half the keyframe or more (grain, moving graphics), the
        // edge pictures carry their own detail and the floor would spend bytes for little gain.
        let keyframe = Double(frames[first].byteCount)
        if bytes / Double(next - first) < keyframe / 2 {
            let later = frames[(range.lowerBound + 1)..<range.upperBound].reduce(0.0) { $0 + Double($1.byteCount) }
            let span = try end.subtracting(start).seconds
            if span > 0 { bitsPerSecond = max(bitsPerSecond, (keyframe + later) * 8 / span) }
        }
        let maximumRate = codec == "av1" ? 100_000_000 : Int32.max
        let rate = Int64(min(Double(maximumRate), max(1, bitsPerSecond.rounded())))
        return EncodedEdge(from: start, to: end, frameCount: range.count,
                           targetBitRate: rate, decodeFrom: frames[first].time)
    }

    if headEnd >= tailStart {
        // A short selection inside one GOP can consist entirely of edge frames.
        // Refuse to silently encode a run of open GOPs with no safe return to copy.
        if kept.dropFirst().contains(where: { frames[$0].keyframe && !frames[$0].canStart }) {
            throw CutError(code: "unsafe_smart_join",
                           message: "This range crosses open picture groups without a verified point to resume copying. Choose a verified boundary.",
                           segment: segment)
        }
        return [try edge(kept)]
    }
    var edges: [EncodedEdge] = []
    if headEnd > kept.lowerBound { edges.append(try edge(kept.lowerBound..<headEnd)) }
    if tailStart < kept.upperBound { edges.append(try edge(tailStart..<kept.upperBound)) }
    return edges
}
