import Foundation
import PacketWriter

/// The AAC frames Smart Trim encodes where two ranges meet inside a Matroska output, reported like video edges.
/// `from` and `to` are output times: from the end of the earlier range's last copied frame to the start of the later
/// range's first copied frame. A dry run and the export report the same bridges.
public struct EncodedAudioEdge: Codable, Sendable, Equatable {
    /// The audio stream index of the later range's source, which names the output track.
    public let track: Int
    public let from: RationalTime
    public let to: RationalTime
    public let frameCount: Int
    public let targetBitRate: Int64
    /// "ffmpeg" or "apple": the encoder whose window shape matches the copied frames on either side.
    public let encoder: String
}

/// A copy that starts or ends inside an AAC frame of a Matroska output (`MPCutAACTrim`).
struct AACEdgeTrim: Sendable {
    let stream: Int
    let origin: RationalTime
    let grid: Int64
    let cut: Int64
    let copy: Int64
    let padding: Int64
}

/// What the writer needs to rebuild one planned bridge, kept on the later range of the join.
struct AACBridgePlan: Sendable {
    let previousStream: Int
    let previousOrigin: RationalTime
    let previousGrid: Int64
    let previousCut: Int64
    let previousCopyEnd: Int64
    let previousFloor: Int64
    let stream: Int
    let origin: RationalTime
    let grid: Int64
    let cut: Int64
    let copyStart: Int64
    let ceiling: Int64
    let bitRate: Int64
    let encoder: Int32
}

extension AudioIndex {
    /// The sample (on the source clock, from its origin) where the track's first packet starts. Matroska keeps
    /// packet times in milliseconds, so there the codec delay places the first packet, which precedes the origin by it.
    func aacFrameGrid(matroska: Bool) -> Int64? {
        let rate = stream.sampleRate
        guard rate > 0, let first = packets.first, let sample = try? first.time.roundedToSamples(rate) else { return nil }
        if matroska, stream.initialPadding > 0, abs(sample + Int64(stream.initialPadding)) <= Int64(rate / 1_000 + 1) {
            return -Int64(stream.initialPadding)
        }
        return sample
    }
}

/// The fields of an AAC AudioSpecificConfig the bridge encoders reproduce.
func aacConfigurationIssue(_ configuration: Data) -> String? {
    let bytes = [UInt8](configuration.prefix(5))
    guard bytes.count >= 2 else { return "it has no AAC decoder configuration" }
    let object = bytes[0] >> 3
    let rateIndex = ((bytes[0] & 7) << 1) | (bytes[1] >> 7)
    let channels = (bytes[1] >> 3) & 15
    if object == 5 || object == 29 { return "it uses HE-AAC (spectral band replication or parametric stereo)" }
    if object != 2 { return "it is not AAC Low Complexity" }
    if rateIndex == 15 { return "its sample rate is not a standard AAC rate" }
    if channels == 0 || channels > 7 { return "its channel layout is described by a program configuration element" }
    if bytes.count >= 5 {
        let bits = UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        if bits >> 13 == 0x2b7 && (bits >> 8) & 31 == 5 && (bits >> 7) & 1 == 1 {
            return "it signals HE-AAC (spectral band replication or parametric stereo)"
        }
    }
    return nil
}

extension CutEngine {
    /// Containers in which Smart Trim joins AAC ranges with encoded frames and a DiscardPadding trim.
    static let aacBridgeContainers: Set<String> = ["mkv"]

    /// Why the frames of this AAC track cannot be encoded again at a join, or nil when they can. The decoded check
    /// for implicitly signalled HE-AAC happens when the bridge is planned.
    func aacBridgeIssue(_ audio: AudioIndex) -> String? {
        let track = audio.stream
        guard track.codec == "aac" else { return "it is not AAC" }
        if let issue = aacConfigurationIssue(track.configuration) { return issue }
        if !audio.presentationEdits.isEmpty { return "it has its own presentation edits" }
        guard track.sampleRate > 0, audio.packets.count > 2 else { return "its frames are not indexed" }
        return nil
    }

    /// True when Smart Trim joins this track's ranges in this container with encoded AAC frames.
    func bridgesAAC(_ audio: AudioIndex, container: String) -> Bool {
        smartTrim && trimsAAC(audio, container: container)
    }

    /// True when a movie copy into this container can start and end this AAC track inside a frame: a codec delay
    /// hides the start, with the frame before it decoded for its overlap, and DiscardPadding the end. The copied frames
    /// stay byte-identical, as with a MOV edit list, so Lossless Copy and Smart Trim both do it.
    func trimsAAC(_ audio: AudioIndex, container: String) -> Bool {
        tracks == .all && Self.aacBridgeContainers.contains(container) && aacBridgeIssue(audio) == nil
    }

    /// The sentence a refusal gives at an interior AAC join into Matroska: why Smart Trim cannot encode it, or that it can.
    func aacJoinReason(_ audio: AudioIndex, container: String) -> String? {
        guard audio.stream.codec == "aac", Self.aacBridgeContainers.contains(container) else { return nil }
        if let issue = aacBridgeIssue(audio) {
            return "AAC track \(audio.stream.index) requires its original decoder history at this join, and Smart Trim cannot encode "
                + "its frames again because \(issue)."
        }
        if !smartTrim {
            return "AAC track \(audio.stream.index) requires its original decoder history at this join. "
                + "Smart Trim makes the join exact by encoding the few AAC frames around it."
        }
        return nil
    }

    /// Plan a bridge at each join of AAC tracks that Smart Trim joins with encoded frames, and attach it to the later range.
    func planAACBridges(_ segments: inout [ResolvedSegment], media: [MediaInfo], container: String) throws {
        guard tracks == .all, Self.aacBridgeContainers.contains(container), !segments.isEmpty else { return }
        let matroska = media.map { $0.format.split(separator: ",").contains("matroska") }
        try planAACEdgeTrims(&segments, media: media, matroska: matroska, container: container)
        guard smartTrim else { return }
        for index in 1..<max(1, segments.count) {
            try checkCancellation()
            let earlier = segments[index - 1].tracks.filter { $0.kind == "audio" }
            let later = segments[index].tracks.filter { $0.kind == "audio" }
            var plans: [AACBridgePlan] = []
            var edges: [EncodedAudioEdge] = []
            for (before, after) in zip(earlier, later) {
                guard let first = media[index - 1].audio.first(where: { $0.stream.index == before.index }),
                      let second = media[index].audio.first(where: { $0.stream.index == after.index }),
                      bridgesAAC(first, container: container), bridgesAAC(second, container: container) else { continue }
                let (plan, edge) = try planBridge(first, before, media: media[index - 1], matroska: matroska[index - 1],
                                                  second, after, media: media[index], matroska: matroska[index],
                                                  earlierSegment: segments[index - 1], laterSegment: segments[index],
                                                  segment: index + 1)
                plans.append(plan)
                edges.append(edge)
            }
            if !plans.isEmpty {
                segments[index].aacBridges = plans
                segments[index].encodedAudioEdges = edges
            }
        }
    }

    /// The first range's start and the last range's end, where they fall inside an AAC frame. The copy keeps whole
    /// frames: a codec delay hides the start, with the frame before decoded for its overlap, and DiscardPadding the end.
    private func planAACEdgeTrims(_ segments: inout [ResolvedSegment], media: [MediaInfo], matroska: [Bool],
                                  container: String) throws {
        let frame: Int64 = 1024
        for (index, edge) in [(0, true), (segments.count - 1, false)] {
            var trims: [AACEdgeTrim] = []
            for track in segments[index].tracks where track.kind == "audio" {
                guard let sound = media[index].audio.first(where: { $0.stream.index == track.index }),
                      trimsAAC(sound, container: container), let grid = sound.aacFrameGrid(matroska: matroska[index]) else { continue }
                let rate = sound.stream.sampleRate
                let origin = segments[index].sourceOrigin ?? media[index].origin
                if edge {
                    // A copy from the source's first audible sample keeps the source's own priming.
                    guard track.sourceStart > max(.zero, sound.start) else { continue }
                    let cut = try track.sourceStart.roundedToSamples(rate)
                    let offset = cut - grid
                    let frameStart = grid + (offset >= 0 ? offset / frame : -((-offset + frame - 1) / frame)) * frame
                    let copy = frameStart - frame >= grid ? frameStart - frame : frameStart
                    trims.append(AACEdgeTrim(stream: track.index, origin: origin, grid: grid, cut: cut, copy: copy, padding: cut - copy))
                } else {
                    guard track.sourceEnd < sound.end else { continue }
                    let cut = try track.sourceEnd.roundedToSamples(rate)
                    let offset = cut - grid
                    let below = grid + (offset >= 0 ? offset / frame : -((-offset + frame - 1) / frame)) * frame
                    trims.append(AACEdgeTrim(stream: track.index, origin: origin, grid: grid, cut: cut,
                                             copy: below == cut ? cut : below + frame, padding: 0))
                }
            }
            if edge {
                segments[index].aacHeads = trims.isEmpty ? nil : trims
            } else {
                segments[index].aacTails = trims.isEmpty ? nil : trims
            }
        }
    }

    private func planBridge(_ first: AudioIndex, _ before: ResolvedTrack, media earlierMedia: MediaInfo, matroska earlierMatroska: Bool,
                            _ second: AudioIndex, _ after: ResolvedTrack, media laterMedia: MediaInfo, matroska laterMatroska: Bool,
                            earlierSegment: ResolvedSegment, laterSegment: ResolvedSegment,
                            segment: Int) throws -> (AACBridgePlan, EncodedAudioEdge) {
        let frame: Int64 = 1024
        let rate = first.stream.sampleRate
        func refuse(_ message: String) -> CutError {
            CutError(code: "unsafe_boundary", message: message, segment: segment, boundary: "from", track: after.index)
                .because(.joinDecoderHistory)
        }
        guard second.stream.sampleRate == rate, second.stream.channels == first.stream.channels,
              let previousGrid = first.aacFrameGrid(matroska: earlierMatroska),
              let grid = second.aacFrameGrid(matroska: laterMatroska) else {
            throw refuse("The AAC tracks at this join do not share a frame clock Smart Trim can encode on.")
        }
        func floorFrame(_ sample: Int64, _ anchor: Int64) -> Int64 {
            let offset = sample - anchor
            return anchor + (offset >= 0 ? offset / frame : -((-offset + frame - 1) / frame)) * frame
        }
        func ceilFrame(_ sample: Int64, _ anchor: Int64) -> Int64 {
            let below = floorFrame(sample, anchor)
            return below == sample ? sample : below + frame
        }
        let previousCut = try before.sourceEnd.roundedToSamples(rate)
        let cut = try after.sourceStart.roundedToSamples(rate)
        let previousStart = try before.sourceStart.roundedToSamples(rate)
        let end = try after.sourceEnd.roundedToSamples(rate)
        // The earlier range copies up to a frame start at least one frame before its cut, after its own first frame
        // and any frames a bridge at its own start encodes.
        var previousFloor = ceilFrame(previousStart, previousGrid)
        if let head = earlierSegment.aacBridges?.first(where: { $0.stream == before.index }) { previousFloor = head.copyStart }
        let previousCopyEnd = floorFrame(previousCut - frame, previousGrid)
        var copyStart = ceilFrame(cut, grid)
        if (previousCut - previousCopyEnd) + (copyStart - cut) <= frame { copyStart += frame }
        // The later range copies from there, and keeps at least two whole frames before its end.
        let ceiling = floorFrame(end, grid) - 2 * frame
        guard previousCopyEnd >= previousFloor, copyStart <= ceiling else {
            throw refuse("A range at this join is too short for Smart Trim to encode AAC frames around it. Keep each range at least about 0.1 s long.")
        }
        let bitRate = Int64(max(second.averageBitRate ?? first.averageBitRate ?? 0, 64_000 * max(1, first.stream.channels)))
        var report = MPCutAACBridgeReport()
        var diagnostic = [CChar](repeating: 0, count: 512)
        let capacity = diagnostic.count
        let earlierPath = earlierMedia.url.withUnsafeFileSystemRepresentation { $0.flatMap { strdup($0) } }
        let laterPath = laterMedia.url.withUnsafeFileSystemRepresentation { $0.flatMap { strdup($0) } }
        defer { free(earlierPath); free(laterPath) }
        guard let earlierPath, let laterPath else {
            throw CutError(code: "write_failed", message: "Could not allocate the source file paths.")
        }
        let earlierOrigin = earlierSegment.sourceOrigin ?? earlierMedia.origin
        let laterOrigin = laterSegment.sourceOrigin ?? laterMedia.origin
        var native = MPCutAACBridge(previous_path: earlierPath, previous_stream: Int32(before.index),
                                    previous_origin: MPCutTime(numerator: earlierOrigin.numerator, denominator: earlierOrigin.denominator),
                                    previous_grid: previousGrid, previous_cut: previousCut, previous_copy_end: previousCopyEnd,
                                    previous_floor: previousFloor, path: laterPath, stream: Int32(after.index),
                                    origin: MPCutTime(numerator: laterOrigin.numerator, denominator: laterOrigin.denominator),
                                    grid: grid, cut: cut, copy_start: copyStart, ceiling: ceiling, bit_rate: bitRate,
                                    encoder: Int32(MPCUT_AAC_BRIDGE_FFMPEG))
        let status = mpcut_plan_aac_bridge(&native, &report, &diagnostic, capacity)
        try checkCancellation()
        guard status == 0 else { throw refuse(String(cString: diagnostic)) }
        let plan = AACBridgePlan(previousStream: before.index, previousOrigin: earlierOrigin, previousGrid: previousGrid,
                                 previousCut: previousCut, previousCopyEnd: native.previous_copy_end, previousFloor: previousFloor,
                                 stream: after.index, origin: laterOrigin, grid: grid, cut: cut,
                                 copyStart: native.copy_start, ceiling: ceiling, bitRate: bitRate, encoder: native.encoder)
        // On the output clock: the bridge runs from the earlier copy's end to the later copy's start.
        let clock = Int64(rate)
        let from = try after.outputStart.subtracting(RationalTime(numerator: previousCut - native.previous_copy_end, denominator: clock))
        let to = try after.outputStart.adding(RationalTime(numerator: native.copy_start - cut, denominator: clock))
        let edge = EncodedAudioEdge(track: after.index, from: from, to: to, frameCount: Int(report.frames), targetBitRate: bitRate,
                                    encoder: native.encoder == Int32(MPCUT_AAC_BRIDGE_APPLE) ? "apple" : "ffmpeg")
        return (plan, edge)
    }
}

extension ResolvedEdit {
    /// The output time Smart Trim encodes in AAC bridges, summed over tracks.
    public var encodedAudioDuration: RationalTime {
        segments.reduce(RationalTime.zero) { total, segment in
            (segment.encodedAudioEdges ?? []).reduce(total) { (try? $0.adding($1.to.subtracting($1.from))) ?? $0 }
        }
    }
}
