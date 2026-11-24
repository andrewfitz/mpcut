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
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        writer.movieTimeScale = session.timescale
        let codec: AVVideoCodecType
        var compression: [String: Any] = [:]
        switch settings.codec {
        case .h264, .hevc:
            codec = settings.codec == .h264 ? .h264 : .hevc
            compression = [
                AVVideoAllowFrameReorderingKey: false,
                AVVideoAverageBitRateKey: Self.bitRate(canvas, quality: settings.quality),
                AVVideoExpectedSourceFrameRateKey: canvas.frameRate.seconds
            ]
            if color != .sdr {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            }
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
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else { throw Self.failure(writer) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.mediaTimeScale = session.timescale
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: color.pixelFormat,
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
