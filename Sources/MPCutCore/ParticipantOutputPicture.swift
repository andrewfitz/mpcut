import AVFoundation
import CoreImage
import Foundation
import ImageIO

package struct ParticipantDecodedPicture {
    let buffer: CVPixelBuffer
    let sourceID: String
    let sourceTime: RationalTime
    let sourceIdentity: SourceIdentity
    let displayTransform: CGAffineTransform

    package init(buffer: CVPixelBuffer, sourceID: String, sourceTime: RationalTime,
                 sourceIdentity: SourceIdentity,
                 displayTransform: CGAffineTransform = .identity) {
        self.buffer = buffer
        self.sourceID = sourceID
        self.sourceTime = sourceTime
        self.sourceIdentity = sourceIdentity
        self.displayTransform = displayTransform
    }
}

/// One reusable Output renderer. Access it from one serial queue.
package final class ParticipantOutputPicture {
    private let session: ParticipantRenderSession
    private var pool: CVPixelBufferPool?

    package init(project: CutProject, document: URL, forceSDR: Bool = false, cancelled: (@Sendable () -> Bool)? = nil) throws {
        session = try ParticipantRenderer(cancelled: cancelled, legacyWholeFramePrivacy: false, allowsOriginal: true).prepare(project, document: document, plan: nil,
                                                                      cancelled: cancelled, auditPrivacy: false, forceSDR: forceSDR)
    }

    package func frame(at time: RationalTime, decoded: ParticipantDecodedPicture? = nil,
                       exact: Bool = false,
                       cells: ((ParticipantSlot, CGRect) -> Void)? = nil) throws -> CVPixelBuffer {
        let instant = try session.sampleTime(at: time, exact: exact)
        let picture = try session.picture(at: instant, decoded: decoded, cells: cells)
        let buffer = try session.color.render(picture, extent: session.extent, into: nextSurface())
        try session.verifySources(at: instant)
        return buffer
    }

    private func nextSurface() throws -> CVPixelBuffer {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: session.color.pixelFormat,
                kCVPixelBufferWidthKey: session.plan.canvas.width,
                kCVPixelBufferHeightKey: session.plan.canvas.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
                  let created else { throw JPEGRenderer.failure }
            pool = created
        }
        var surface: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &surface) == kCVReturnSuccess,
              let surface else {
            throw CutError(code: "output_picture_busy", message: "Output is waiting for a display surface.")
        }
        return surface
    }

    package func privacyIssues(at time: RationalTime, exact: Bool = false) throws -> [ParticipantPrivacyIssue] {
        try session.privacyIssues(at: session.sampleTime(at: time, exact: exact))
    }

    package func frameTiming(at time: RationalTime) throws -> (at: RationalTime, length: RationalTime) {
        let sampled = try session.sampleTime(at: time)
        var first: Int64 = 0
        var end = session.frameCount
        while first + 1 < end {
            let index = first + (end - first) / 2
            if try session.frameTiming(at: index).at <= sampled { first = index }
            else { end = index }
        }
        return try session.frameTiming(at: first)
    }

    package var canvas: ParticipantCanvas { session.plan.canvas }
    package var duration: RationalTime { session.timeline.timeline.duration }

    package static func cellRects(layout: ParticipantShotLayout, count: Int, extent: CGRect) -> [CGRect] {
        ParticipantCompositor.slots(layout, count: count, extent: extent)
    }

    package func verifySources() throws { try session.verifySources() }

    package func thumbnail(at time: RationalTime, size: CGSize) throws -> CGImage {
        let picture = try scaledPicture(at: time, size: size, exact: true)
        guard let result = ParticipantCompositor.context.createCGImage(picture, from: picture.extent, format: .RGBA8,
                                                                       colorSpace: ParticipantCompositor.colorSpace) else {
            throw JPEGRenderer.failure
        }
        return result
    }

    package func jpeg(at time: RationalTime, preset: JPEGPreset) throws -> (data: Data, width: Int, height: Int) {
        let size = preset == .review ? CGSize(width: 640, height: 640) : session.extent.size
        let picture = try scaledPicture(at: time, size: size)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = ParticipantCompositor.context.jpegRepresentation(
            of: picture, colorSpace: ParticipantCompositor.colorSpace, options: [quality: preset == .review ? 0.62 : 0.95]
        ) else { throw JPEGRenderer.failure }
        return (data, Int(picture.extent.width), Int(picture.extent.height))
    }

    private func scaledPicture(at time: RationalTime, size: CGSize, exact: Bool = false) throws -> CIImage {
        let instant = try session.sampleTime(at: time, exact: exact)
        let picture = try session.picture(at: instant)
        try session.verifySources(at: instant)
        let scale = min(1, size.width / session.extent.width, size.height / session.extent.height)
        guard scale.isFinite, scale > 0 else { throw JPEGRenderer.failure }
        let width = max(1, (session.extent.width * scale).rounded())
        let height = max(1, (session.extent.height * scale).rounded())
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        return picture.transformed(by: .init(scaleX: width / session.extent.width, y: height / session.extent.height),
                                   highQualityDownsample: true).cropped(to: extent)
    }
}

enum ParticipantPictureColor {
    case sdr, pq, hlg

    init(transfer: String) {
        switch transfer {
        case "smpte2084": self = .pq
        case "arib-std-b67": self = .hlg
        default: self = .sdr
        }
    }

    /// The space Core Video gives a picture tagged BT.709, the same on every system. Rendering into it keeps
    /// a BT.709 recording's code values; `CGColorSpace.itur_709` uses another curve and shifts midtones.
    static let bt709: CGColorSpace = CVImageBufferCreateColorSpaceFromAttachments([
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ] as CFDictionary)?.takeRetainedValue() ?? CGColorSpace(name: CGColorSpace.itur_709)!

    /// SDR output is BT.709 on every system, in both its pixels and its tags, like MPCut's other video output.
    var colorSpace: CGColorSpace {
        switch self {
        case .sdr: Self.bt709
        case .pq: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        case .hlg: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        }
    }

    var stillTransfer: String {
        switch self {
        case .sdr: "bt709"
        case .pq: "smpte2084"
        case .hlg: "arib-std-b67"
        }
    }

    var encoderTransfer: String {
        switch self {
        case .sdr: AVVideoTransferFunction_ITU_R_709_2
        case .pq: AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: AVVideoTransferFunction_ITU_R_2100_HLG
        }
    }

    /// The space canvas, gap and cover colors are given in. SDR colors are written with their own code
    /// values; HDR output keeps reading them as sRGB.
    var canvasSpace: CGColorSpace {
        self == .sdr ? colorSpace : ParticipantCompositor.colorSpace
    }

    var bufferTransfer: CFString {
        switch self {
        case .sdr: kCVImageBufferTransferFunction_ITU_R_709_2
        case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }

    var pixelFormat: OSType {
        self == .sdr ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_ARGB2101010LEPacked
    }

    func render(_ picture: CIImage, extent: CGRect, into target: CVPixelBuffer? = nil) throws -> CVPixelBuffer {
        var buffer = target
        if buffer == nil {
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(nil, Int(extent.width), Int(extent.height), pixelFormat, attributes,
                                      &buffer) == kCVReturnSuccess else {
                throw CutError(code: "frame_export_failed", message: "Could not allocate the output picture.")
            }
        }
        guard let buffer else {
            throw CutError(code: "frame_export_failed", message: "Could not allocate the output picture.")
        }
        let primaries = self == .sdr ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, bufferTransfer, .shouldPropagate)
        ParticipantCompositor.context.render(picture, to: buffer, bounds: extent, colorSpace: colorSpace)
        return buffer
    }
}
