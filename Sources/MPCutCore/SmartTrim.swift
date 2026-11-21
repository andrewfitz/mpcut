import Foundation
import VideoToolbox

private let hardwareAV1Decode = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

extension CutEngine {
    /// Copy-safe boundaries remain available for every supported stream. Only extend
    /// the choices when we can reproduce the source's picture format at the edges.
    public func smartTrimEligible(in media: MediaInfo, container: String) -> Bool {
        let video = media.video
        let main10 = video.codec == "hevc" && video.profile == 2 && video.bitDepth == 10
            && video.pixelFormat == "yuv420p10le"
        let planar8 = video.bitDepth == 8 && ["yuv420p", "yuvj420p"].contains(video.pixelFormat)
        guard media.sourceStartSafe, !video.multipleDescriptions, !video.hasAdditionalVideoLayers,
              (planar8 || main10), !video.hasAlpha, !video.complexPicture,
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

    func edge(_ range: Range<Int>) -> EncodedEdge {
        let start = frames[range.lowerBound].time
        let end = range.upperBound == kept.upperBound ? to : frames[range.upperBound].time
        // A few dependent pictures alone can contain almost no data. Include their
        // source keyframe when budgeting the replacement's independent first picture.
        let first = frames[...range.lowerBound].lastIndex(where: { $0.canStart && $0.canEnd }) ?? 0
        let next = frames[range.upperBound...].firstIndex(where: { $0.canStart && $0.canEnd }) ?? frames.count
        let budgetEnd = next == frames.count ? sourceEnd : frames[next].time
        let seconds = (budgetEnd - frames[first].time).seconds
        let bytes = frames[first..<next].reduce(0.0) { $0 + Double($1.byteCount) }
        let maximumRate = codec == "av1" ? 100_000_000 : Int32.max
        let rate = Int64(min(Double(maximumRate), max(1, (bytes * 8 / seconds).rounded())))
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
        return [edge(kept)]
    }
    var edges: [EncodedEdge] = []
    if headEnd > kept.lowerBound { edges.append(edge(kept.lowerBound..<headEnd)) }
    if tailStart < kept.upperBound { edges.append(edge(tailStart..<kept.upperBound)) }
    return edges
}
