import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

extension ParticipantRenderSession {
    static func validateEncoding(_ settings: ReencodeSettings, color: ParticipantPictureColor) throws {
        guard ExportRules.qualities(settings.codec).contains(settings.quality) else {
            throw CutError(code: "unsupported_quality", message: "Choose a quality available for the selected video codec.")
        }
        guard color == .sdr || settings.codec == .hevc || settings.codec == .prores else {
            throw CutError(code: "unsupported_format", message: "Select HEVC or ProRes to preserve HDR in the participant composition.")
        }
    }

    func writePicture(to file: URL, settings: ReencodeSettings, progress: (Double) -> Void) throws {
        let writer = try ParticipantPictureWriter(session: self, file: file, settings: settings)
        let stride = max(1, frameCount / 1_000)
        for index in 0..<frameCount {
            try writer.append(index)
            if (index + 1).isMultiple(of: stride) || index + 1 == frameCount {
                progress(Double(index + 1) / Double(frameCount))
            }
        }
        try writer.finish()
    }
}

/// Owns one encoder and at most twelve reusable input surfaces.
final class ParticipantPictureWriter {
    static let maximumSurfaces = 12

    private let session: ParticipantRenderSession
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adapter: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool
    private let surfaceLimit: Int
    private var format: CMVideoFormatDescription?

    init(session: ParticipantRenderSession, file: URL, settings: ReencodeSettings, surfaceLimit: Int = maximumSurfaces) throws {
        self.session = session
        self.surfaceLimit = surfaceLimit
        try session.control.check()
        try ParticipantRenderSession.validateEncoding(settings, color: session.color)
        let canvas = session.plan.canvas
        let color = session.color
        // HDR, and SDR from a recording deeper than eight bits, keep ten bits through HEVC and ProRes.
        let tenBit = color != .sdr || (session.deepSource && (settings.codec == .hevc || settings.codec == .prores))
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        writer.movieTimeScale = session.timescale
        let codec: AVVideoCodecType
        var compression: [String: Any] = [:]
        switch settings.codec {
        case .h264, .hevc:
            codec = settings.codec == .h264 ? .h264 : .hevc
            // Constant quality with Re-encode's VideoToolbox tiers, so both exports of a picture match.
            compression = [
                AVVideoAllowFrameReorderingKey: false,
                AVVideoQualityKey: Self.quality(settings.quality),
                AVVideoExpectedSourceFrameRateKey: canvas.frameRate.seconds,
                AVVideoProfileLevelKey: settings.codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel
                    : tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        case .jpeg:
            codec = .jpeg
            compression[AVVideoQualityKey] = settings.quality == .smallerFile ? 0.55 : settings.quality == .highQuality ? 0.90 : 0.75
        case .prores:
            switch settings.quality {
            case .proresLT: codec = .proRes422LT
            case .proresHQ: codec = .proRes422HQ
            default: codec = .proRes422
            }
        }
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: color == .sdr ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: color.encoderTransfer,
                AVVideoYCbCrMatrixKey: color == .sdr ? AVVideoYCbCrMatrix_ITU_R_709_2 : AVVideoYCbCrMatrix_ITU_R_2020
            ]
        ]
        if !compression.isEmpty { outputSettings[AVVideoCompressionPropertiesKey] = compression }
        let accepted = Self.acceptedSettings(outputSettings, canvas: canvas, settings: settings) {
            writer.canApply(outputSettings: $0, forMediaType: .video)
        }
        outputSettings = accepted.settings
        session.writtenWarning = accepted.warning
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else { throw Self.failure(writer) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.mediaTimeScale = session.timescale
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: tenBit ? kCVPixelFormatType_ARGB2101010LEPacked : color.pixelFormat,
            kCVPixelBufferWidthKey as String: canvas.width,
            kCVPixelBufferHeightKey as String: canvas.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw Self.failure(writer) }
        writer.add(input)
        guard writer.startWriting() else { throw Self.failure(writer) }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adapter.pixelBufferPool else {
            writer.cancelWriting()
            throw Self.failure(writer)
        }
        self.writer = writer
        self.input = input
        self.adapter = adapter
        self.pool = pool
    }

    deinit { if writer.status == .writing { writer.cancelWriting() } }

    /// Constant quality needs a hardware encoder session. When none takes it, as in a render of many ISOs at once,
    /// the picture is encoded at the tier's average rate instead of failing, and the warning says so.
    /// `canApply` is the writer's check of the settings.
    static func acceptedSettings(_ outputSettings: [String: Any], canvas: ParticipantCanvas, settings: ReencodeSettings,
                                 canApply: ([String: Any]) -> Bool) -> (settings: [String: Any], warning: String?) {
        guard settings.codec == .h264 || settings.codec == .hevc,
              var compression = outputSettings[AVVideoCompressionPropertiesKey] as? [String: Any],
              compression[AVVideoQualityKey] != nil, !canApply(outputSettings) else { return (outputSettings, nil) }
        let rate = bitRate(canvas, quality: settings.quality)
        compression[AVVideoQualityKey] = nil
        compression[AVVideoAverageBitRateKey] = rate
        var changed = outputSettings
        changed[AVVideoCompressionPropertiesKey] = compression
        let codec = settings.codec == .hevc ? "HEVC" : "H.264"
        return (changed, "No hardware encoder session took constant quality, so the \(codec) picture was encoded at an "
                + "average of \(String(format: "%.1f", Double(rate) / 1_000_000)) Mbps instead.")
    }

    /// VideoToolbox quality for H.264 and HEVC: Re-encode's `-q:v` 45, 60 and 75.
    static func quality(_ quality: ReencodeQuality) -> Double {
        switch quality {
        case .smallerFile: 0.45
        case .highQuality: 0.75
        default: 0.60
        }
    }

    /// An estimate of the encoded picture rate for space checks, and the average rate when constant quality is refused.
    static func bitRate(_ canvas: ParticipantCanvas, quality: ReencodeQuality) -> Int {
        let bitsPerPixel: Double
        switch quality {
        case .smallerFile: bitsPerPixel = 0.08
        case .highQuality: bitsPerPixel = 0.24
        default: bitsPerPixel = 0.14
        }
        return max(160_000, Int(Double(canvas.width * canvas.height) * canvas.frameRate.seconds * bitsPerPixel))
    }

    func append(_ index: Int64) throws {
        try append(session.frameTiming(at: index))
    }

    func append(_ timing: (at: RationalTime, length: RationalTime), frameInputs: ParticipantISOFrameInputs? = nil) throws {
        try session.control.check()
        let deadline = DispatchTime.now() + .seconds(10)
        while writer.status == .writing && !input.isReadyForMoreMediaData {
            try session.control.check()
            guard DispatchTime.now() < deadline else { throw Self.failure(writer) }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard writer.status == .writing else { throw Self.failure(writer) }
        let (at, length) = timing
        try autoreleasepool {
            let buffer = try allocate()
            let image = try session.picture(at: at, frameInputs: frameInputs)
            _ = try session.color.render(image, extent: session.extent, into: buffer)
            if format == nil {
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                                   formatDescriptionOut: &format) == noErr else {
                    throw Self.failure(writer)
                }
            }
            var timing = try CMSampleTimingInfo(duration: cmTime(length), presentationTimeStamp: cmTime(at), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                  let sample, input.append(sample) else { throw Self.failure(writer) }
        }
    }

    func finish() throws {
        try waitForFinish(beginFinish())
    }

    func beginFinish() throws -> DispatchSemaphore {
        try session.control.check()
        input.markAsFinished()
        writer.endSession(atSourceTime: try cmTime(session.timeline.timeline.duration))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        return finished
    }

    func waitForFinish(_ finished: DispatchSemaphore) throws {
        while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut { try session.control.check() }
        try session.control.check()
        guard writer.status == .completed else { throw Self.failure(writer) }
    }

    private func allocate() throws -> CVPixelBuffer {
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey: surfaceLimit] as CFDictionary
        let deadline = DispatchTime.now() + .seconds(2)
        repeat {
            try session.control.check()
            guard writer.status == .writing else { throw Self.failure(writer) }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attributes, &buffer)
            if result == kCVReturnSuccess, let buffer { return buffer }
            guard result == kCVReturnWouldExceedAllocationThreshold, DispatchTime.now() < deadline else {
                throw Self.failure(writer)
            }
            Thread.sleep(forTimeInterval: 0.002)
        } while true
    }

    private func cmTime(_ rational: RationalTime) throws -> CMTime {
        let scale = session.timescale
        let ticks = try rational.multiplied(by: .init(numerator: Int64(scale)))
        guard ticks.denominator == 1 else {
            throw CutError(code: "unsupported_participant_timing", message: "A picture falls outside the movie clock.")
        }
        return .init(value: ticks.numerator, timescale: scale)
    }

    private static func failure(_ writer: AVAssetWriter) -> CutError {
        CutError(code: "participant_encode_failed", message: writer.error?.localizedDescription
                    ?? "Could not encode the participant picture at the requested canvas size.")
    }
}
