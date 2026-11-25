import CoreImage
import CoreVideo

struct PreviewTransfer {
    let actualHDR: String?
    let program: String
    let source: String
    let convertsProgramToSDR: Bool
    let usesSDRCameraPreview: Bool
    let isVerified: Bool

    init(frame: PreviewFrame) {
        let transfer = CVBufferCopyAttachment(frame.buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let primaries = CVBufferCopyAttachment(frame.buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        actualHDR = Self.hdrTransfer(transfer)
        let expected = Self.hdrTransfer(frame.programTransfer)
        let specifiesSDR = frame.programTransfer.map { expected == nil && $0 != "unknown" } ?? false
        convertsProgramToSDR = specifiesSDR && actualHDR != nil
        usesSDRCameraPreview = frame.cameraTransfer != nil && Self.hdrTransfer(frame.cameraTransfer) == nil &&
            expected != nil && actualHDR == nil
        source = frame.sourceRendition ?? actualHDR ?? (transfer == nil ? "untagged" : "SDR")
        program = expected ?? (specifiesSDR ? "SDR" : actualHDR ?? (transfer == nil ? "unspecified" : "SDR"))
        if actualHDR != nil {
            let format = CVPixelBufferGetPixelFormatType(frame.buffer)
            isVerified = Self.extendedFormats.contains(format) && primaries != nil &&
                (expected == nil || actualHDR == expected)
        } else {
            isVerified = expected == nil || usesSDRCameraPreview
        }
    }

    private static func hdrTransfer(_ transfer: String?) -> String? {
        if ["smpte2084", "pq"].contains(transfer?.lowercased() ?? "") || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { return "PQ" }
        if ["arib-std-b67", "hlg"].contains(transfer?.lowercased() ?? "") || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { return "HLG" }
        return nil
    }

    private static let extendedFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, kCVPixelFormatType_4444AYpCbCr16,
        // VideoToolbox can return losslessly packed 10-bit decoder surfaces.
        kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
        kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange,
        kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
        kCVPixelFormatType_Lossless_64RGBAHalf,
        kCVPixelFormatType_ARGB2101010LEPacked, kCVPixelFormatType_64RGBAHalf,
        kCVPixelFormatType_64RGBALE
    ]

    private static let context = CIContext(options: [
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .name: "MPCut SDR Preview"
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func mapToSDR(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        var output: CVPixelBuffer?
        let options = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  options, &output) == kCVReturnSuccess, let output else { return nil }
        let image = CIImage(cvPixelBuffer: decodable(input), options: [.toneMapHDRtoSDR: true])
        guard !image.extent.isEmpty else { return nil }
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = sRGB
        do {
            let render = try context.startTask(toRender: image, to: destination)
            _ = try render.waitUntilCompleted()
        } catch {
            return nil
        }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        for key in [kCVImageBufferCleanApertureKey, kCVImageBufferPixelAspectRatioKey] {
            if let value = CVBufferCopyAttachment(input, key, nil) {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            }
        }
        return output
    }

    /// VideoToolbox leaves the matrix of a BT.2020 picture that records none unset. Core Animation,
    /// which shows the HDR preview and the FFmpeg preview's surface, decodes it as BT.2020, where
    /// Core Image would read BT.709 (measured on macOS 27). The shared picture keeps its own tags:
    /// a second buffer on the same surface carries the matrix, unpropagated, since a propagated
    /// attachment is stored with the surface and the shared picture would read it too.
    private static func decodable(_ input: CVPixelBuffer) -> CVPixelBuffer {
        guard CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil) == nil,
              CVBufferCopyAttachment(input, kCVImageBufferColorPrimariesKey, nil) as? String
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
              let surface = CVPixelBufferGetIOSurface(input)?.takeUnretainedValue() else { return input }
        var tagged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &tagged) == kCVReturnSuccess,
              let buffer = tagged?.takeRetainedValue() else { return input }
        CVBufferPropagateAttachments(input, buffer)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldNotPropagate)
        return buffer
    }
}
