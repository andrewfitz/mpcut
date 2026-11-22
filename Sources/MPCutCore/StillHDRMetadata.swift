import Foundation
import MediaProbe

struct StillHDRMetadata: Sendable {
    let mastering: [UInt32]?
    let hasConflictingMastering: Bool
    let hasContentLight: Bool
    let hasInBandContentLight: Bool
    let hasDolbyVision: Bool
    let hasHDR10Plus: Bool
    let hasAdditionalLayers: Bool

    var masteringOption: String? {
        mastering.map { m in
            "G(\(m[0]),\(m[1]))B(\(m[2]),\(m[3]))R(\(m[4]),\(m[5]))WP(\(m[6]),\(m[7]))L(\(m[8]),\(m[9]))"
        }
    }

    static func inspect(_ media: MediaInfo, retaining ranges: [MulticamRange] = [],
                        cancelled: (@Sendable () -> Bool)?) throws -> Self {
        let scale = media.video.timeBase.denominator
        guard let nativeScale = Int32(exactly: scale), nativeScale > 0 else { throw unverifiable(media.url) }
        var windows: [MPProbeHDRRange] = []
        for range in ranges.sorted(by: { $0.from < $1.from }) {
            let start = try range.from.adding(media.origin).roundedToSamples(Int(scale))
            let end = try range.to.adding(media.origin).roundedToSamples(Int(scale))
            if let last = windows.last, start <= last.end {
                windows[windows.count - 1].end = max(last.end, end)
            } else {
                windows.append(MPProbeHDRRange(start: start, end: end, scale: nativeScale))
            }
        }
        let control = Cancellation(cancelled)
        let callback: MPProbeCancelled = { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<Cancellation>.fromOpaque(pointer).takeUnretainedValue().cancelled?() == true ? 1 : 0
        }
        guard let stream = Int32(exactly: media.video.index) else { throw unverifiable(media.url) }
        var result = MPProbeHDR()
        var error = [CChar](repeating: 0, count: 256)
        let size = error.count
        let status = withExtendedLifetime(control) {
            windows.withUnsafeBufferPointer { buffer in
                media.url.withUnsafeFileSystemRepresentation { path in
                    mp_probe_hdr(path, stream, buffer.baseAddress, buffer.count, callback,
                                 Unmanaged.passUnretained(control).toOpaque(), &result, &error, size)
                }
            }
        }
        try CutEngine(cancelled: cancelled).checkCancellation()
        guard status == 0 else { throw unverifiable(media.url, reason: String(cString: error)) }
        try CutEngine(cancelled: cancelled).verifyIdentity(media.url, identity: media.identity)
        let mastering = result.has_mastering == 0 ? nil : withUnsafeBytes(of: result.mastering) {
            Array($0.bindMemory(to: UInt32.self))
        }
        return Self(mastering: mastering, hasConflictingMastering: result.conflicting_mastering != 0,
                    hasContentLight: result.content_light != 0,
                    hasInBandContentLight: result.inband_content_light != 0,
                    hasDolbyVision: result.dolby_vision != 0, hasHDR10Plus: result.hdr10plus != 0,
                    hasAdditionalLayers: result.additional_layers != 0)
    }

    static func unverifiable(_ file: URL, reason: String? = nil) -> CutError {
        CutError(code: "unverified_hdr_metadata",
                 message: "MPCut could not verify HDR metadata in \(file.lastPathComponent)." +
                    (reason.map { " \($0)." } ?? ""))
    }

    private final class Cancellation {
        let cancelled: (@Sendable () -> Bool)?
        init(_ cancelled: (@Sendable () -> Bool)?) { self.cancelled = cancelled }
    }
}

extension StreamInfo {
    var metadataWithoutContentLight: Data {
        filterCodecMetadata { $0 != MP_PROBE_SIDE_CONTENT_LIGHT }
    }

    var hasOnlyHDRStaticMetadata: Bool {
        filterCodecMetadata { $0 != MP_PROBE_SIDE_CONTENT_LIGHT && $0 != MP_PROBE_SIDE_MASTERING_DISPLAY }.isEmpty
    }

    private func filterCodecMetadata(_ include: (Int32) -> Bool) -> Data {
        var result = Data()
        var offset = codecMetadata.startIndex
        while offset < codecMetadata.endIndex {
            guard codecMetadata.endIndex - offset >= 8 else { return codecMetadata }
            let size = Int(readMetadataWord(at: offset + 4))
            let end = offset + 8 + size
            guard end <= codecMetadata.endIndex else { return codecMetadata }
            if include(mp_probe_hdr_side_type(readMetadataWord(at: offset))) {
                result.append(codecMetadata[offset..<end])
            }
            offset = end
        }
        return result
    }

    private func readMetadataWord(at offset: Data.Index) -> UInt32 {
        codecMetadata.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset - codecMetadata.startIndex, as: UInt32.self))
        }
    }
}

extension StillExportPlanner {
    func planHDR(_ retained: [URL: [MulticamRange]], media: [URL: MediaInfo],
                 preservingCamera: Bool) throws -> [StillHDRMetadata] {
        var reports: [StillHDRMetadata] = []
        for file in retained.keys.sorted(by: { $0.path < $1.path }) {
            guard let info = media[file], let ranges = retained[file] else { continue }
            let video = info.video
            // These codecs can carry HDR signaling inside ordinary compressed samples.
            guard ["h264", "hevc", "av1"].contains(video.codec) || video.complexPicture ||
                    DynamicRange(video) != .sdr else { continue }
            let report = try StillHDRMetadata.inspect(info, retaining: ranges, cancelled: cancelled)
            let dynamic = [report.hasDolbyVision ? "Dolby Vision" : nil, report.hasHDR10Plus ? "HDR10+" : nil,
                           report.hasAdditionalLayers ? "additional picture layers" : nil].compactMap { $0 }
            if !dynamic.isEmpty {
                throw CutError(code: "unsupported_dynamic_hdr",
                               message: "\(file.lastPathComponent) contains \(dynamic.joined(separator: " and ")). MPCut cannot verify equivalent signaling across the generated and retained pictures.")
            }
            if report.hasConflictingMastering || reports.contains(where: { $0.mastering != report.mastering }) {
                throw CutError(code: "unsupported_hdr_mastering",
                               message: "The retained picture does not have a consistent mastering display for the assembled program.")
            }
            if preservingCamera, report.hasInBandContentLight {
                throw CutError(code: "unsupported_hdr_content_light",
                               message: "\(file.lastPathComponent) embeds content-light statistics in its picture stream. Choose conversion to omit stale values while adding stills.")
            }
            reports.append(report)
        }
        return reports
    }
}
