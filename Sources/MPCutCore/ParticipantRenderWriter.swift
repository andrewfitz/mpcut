import AVFoundation
import CoreImage
import Foundation

extension ParticipantRenderSession {
    func writePicture(to file: URL, progress: (Double) -> Void) throws {
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        writer.movieTimeScale = timescale
        let transfer: String
        if #available(macOS 15, *) {
            transfer = AVVideoTransferFunction_IEC_sRGB
        } else {
            transfer = AVVideoTransferFunction_ITU_R_709_2
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.canvas.width,
            AVVideoHeightKey: plan.canvas.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: plan.canvas.frameRate.seconds
            ]
        ])
        input.mediaTimeScale = timescale
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: plan.canvas.width,
            kCVPixelBufferHeightKey as String: plan.canvas.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw Self.failure(writer) }
        writer.add(input)
        guard writer.startWriting() else { throw Self.failure(writer) }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adapter.pixelBufferPool else { throw Self.failure(writer) }

        func cmTime(_ rational: RationalTime) throws -> CMTime {
            let ticks = try rational.multiplied(by: .init(numerator: Int64(timescale)))
            guard ticks.denominator == 1 else {
                throw CutError(code: "unsupported_participant_timing", message: "A picture falls outside the movie clock.")
            }
            return .init(value: ticks.numerator, timescale: timescale)
        }
        func checkReady() throws {
            try control.check()
            while writer.status == .writing && !input.isReadyForMoreMediaData {
                try control.check()
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard writer.status == .writing else { throw Self.failure(writer) }
        }

        let duration = timeline.timeline.duration
        let progressStride = max(1, frameCount / 1_000)
        var format: CMVideoFormatDescription?
        for index in 0..<frameCount {
            try checkReady()
            let at = try cadence.multiplied(by: .init(numerator: index))
            let length = min(cadence, try duration.subtracting(at))
            try autoreleasepool {
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let buffer else { throw Self.failure(writer) }
                let image = try picture(at: at)
                ParticipantCompositor.context.render(image, to: buffer, bounds: extent, colorSpace: ParticipantCompositor.colorSpace)
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
            if (index + 1).isMultiple(of: progressStride) || index + 1 == frameCount {
                progress(Double(index + 1) / Double(frameCount))
            }
        }
        try control.check()
        input.markAsFinished()
        writer.endSession(atSourceTime: try cmTime(duration))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut { try control.check() }
        try control.check()
        guard writer.status == .completed else { throw Self.failure(writer) }
    }

    private static func failure(_ writer: AVAssetWriter) -> CutError {
        CutError(code: "participant_encode_failed", message: writer.error?.localizedDescription
                    ?? "Could not encode the participant picture at the requested canvas size.")
    }
}
