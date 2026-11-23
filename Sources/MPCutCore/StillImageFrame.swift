import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

public struct StillImageFrame: Sendable {
    public let sourceInfo: StillImageInfo
    public let width: Int
    public let height: Int
    fileprivate let encoded: Data
    fileprivate let target: StillImageTarget
    fileprivate let pixelAspect: Double

    // Top-to-bottom, interleaved, full-range RGB with the canvas primaries and transfer.
    public func rgb48LE() -> Data { encoded }

    public var pixelBuffer: CVPixelBuffer {
        get throws {
            let format = target.isHDR ? kCVPixelFormatType_ARGB2101010LEPacked : kCVPixelFormatType_32BGRA
            var output: CVPixelBuffer?
            let settings = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, settings, &output) == kCVReturnSuccess,
                  let output else {
                throw StillImage.error("still_surface", "Cannot allocate a still image display buffer.")
            }
            guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else {
                throw StillImage.error("still_surface", "Cannot write the still image display buffer.")
            }
            defer { CVPixelBufferUnlockBaseAddress(output, []) }
            guard let base = CVPixelBufferGetBaseAddress(output) else {
                throw StillImage.error("still_surface", "Cannot address the still image display buffer.")
            }
            let stride = CVPixelBufferGetBytesPerRow(output)
            let isHDR = target.isHDR
            try encoded.withUnsafeBytes { bytes in
                let source = bytes.bindMemory(to: UInt16.self)
                guard var rgb = source.baseAddress else {
                    throw StillImage.error("still_surface", "Cannot address the encoded still frame.")
                }
                for row in 0..<height {
                    let pixels = base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
                    for column in 0..<width {
                        let red = UInt32(UInt16(littleEndian: rgb[0]))
                        let green = UInt32(UInt16(littleEndian: rgb[1]))
                        let blue = UInt32(UInt16(littleEndian: rgb[2]))
                        if isHDR {
                            pixels[column] = 0xc0000000 | ((red >> 6) << 20) | ((green >> 6) << 10) | (blue >> 6)
                        } else {
                            pixels[column] = 0xff000000 | ((red >> 8) << 16) | ((green >> 8) << 8) | (blue >> 8)
                        }
                        rgb += 3
                    }
                }
            }
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, target.primariesAttachment, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, target.transferAttachment, .shouldPropagate)
            if let colorSpace = target.displayColorSpace {
                CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
            }
            if target.transfer == .gamma22 || target.transfer == .gamma28 {
                let gamma = target.transfer == .gamma22 ? 2.2 : 2.8
                CVBufferSetAttachment(output, kCVImageBufferGammaLevelKey, NSNumber(value: gamma), .shouldPropagate)
            }
            if abs(pixelAspect - 1) > 0.000_001 {
                let horizontal = max(1, Int((pixelAspect * 10_000).rounded()))
                let aspect = [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey: horizontal,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: 10_000,
                ] as CFDictionary
                CVBufferSetAttachment(output, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
            }
            return output
        }
    }

    public func sdrImage() throws -> CGImage {
        guard target.transfer == .sRGB, target.primaries == .bt709,
              let provider = CGDataProvider(data: encoded as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48,
                  bytesPerRow: width * 6, space: StillImage.sRGB,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .relativeColorimetric
              ) else {
            throw StillImage.error("still_surface", "Cannot create an sRGB review image from this still frame.")
        }
        return image
    }
}

extension StillImage {
    private static let linearContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: linear2020,
        .workingFormat: CIFormat.RGBAh,
        .name: "MPCut Still Images",
    ])

    // ColorSync gives HLG images different luminance depending on the
    // executable's linked SDK. Decode scene-referred signal explicitly so a
    // 1,000 cd/m² HLG reference stays identical in the app and CLI.
    private static let hlgToLinear = CIColorKernel(source: """
        kernel vec4 hlgToLinear(__sample sample, vec3 weights) {
            float alpha = sample.a;
            if (alpha <= 0.0) return vec4(0.0);
            vec3 encoded = max(sample.rgb / alpha, vec3(0.0));
            vec3 low = encoded * encoded / 3.0;
            vec3 high = (exp((encoded - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
            vec3 scene = mix(low, high, step(vec3(0.5), encoded));
            float luminance = max(dot(scene, weights), 0.0);
            vec3 display = scene * pow(luminance, 0.2) * (1000.0 / 203.0);
            return vec4(display * alpha, alpha);
        }
        """)

    private static func sourceImage(_ image: CGImage, colorSpace: CGColorSpace) throws -> CIImage {
        guard CGColorSpaceIsHLGBased(colorSpace) else {
            return CIImage(cgImage: image, options: [.colorSpace: colorSpace])
        }
        let sourceLinear: CGColorSpace
        let luma: CIVector
        switch colorSpace.name {
        case CGColorSpace.itur_709_HLG:
            sourceLinear = linear709
            luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722)
        case CGColorSpace.displayP3_HLG:
            sourceLinear = linearP3
            luma = CIVector(x: 0.2290, y: 0.6917, z: 0.0793)
        default:
            sourceLinear = linear2020
            luma = CIVector(x: 0.2627, y: 0.6780, z: 0.0593)
        }
        // Read the encoded RGB values unchanged, then apply HLG before
        // transforming the linear source primaries into the working gamut.
        let signal = CIImage(cgImage: image, options: [.colorSpace: linear2020])
        guard let linear = hlgToLinear?.apply(extent: signal.extent, arguments: [signal, luma]) else {
            throw error("still_color", "Cannot apply the HLG reference viewing transform.")
        }
        if sourceLinear == linear2020 { return linear }
        guard let converted = linear.matchedToWorkingSpace(from: sourceLinear) else {
            throw error("still_color", "Cannot convert HLG source primaries to the working color space.")
        }
        return converted
    }

    public static func render(
        _ url: URL, canvas: StillImageCanvas, framing: StillImageFraming = .fit,
        forceSDR: Bool = false, preview: Bool = false, cancelled: (() -> Bool)? = nil
    ) throws -> StillImageFrame {
        try render(url, canvas: canvas, framing: framing, forceSDR: forceSDR, preview: preview,
                   expectedIdentity: nil, cancelled: cancelled)
    }

    package static func render(
        _ url: URL, canvas: StillImageCanvas, framing: StillImageFraming = .fit,
        forceSDR: Bool = false, preview: Bool = false, expectedIdentity: SourceIdentity?,
        cancelled: (() -> Bool)? = nil
    ) throws -> StillImageFrame {
        try withStableFile(url, expectedIdentity: expectedIdentity, cancelled: cancelled) { file, _ in
            try render(file, name: url.lastPathComponent, isGap: url.lastPathComponent == "Gap.png" && url.standardizedFileURL == StillAsset.gapImage.standardizedFileURL, canvas: canvas, framing: framing,
                       forceSDR: forceSDR, preview: preview, cancelled: cancelled)
        }
    }

    private static func render(
        _ file: FileHandle, name: String, isGap: Bool, canvas: StillImageCanvas, framing: StillImageFraming,
        forceSDR: Bool, preview: Bool, cancelled: (() -> Bool)?
    ) throws -> StillImageFrame {
        try validateDimensions(canvas.width, canvas.height, maximumPixels: 8_192 * 4_320)
        let aspect = canvas.displayAspect ?? Double(canvas.width) / Double(canvas.height)
        guard aspect.isFinite, (0.01...100).contains(aspect) else {
            throw error("still_canvas", "Still image display aspect ratio is invalid.")
        }
        try framing.validate()
        let target = try StillImageTarget(canvas: canvas, forceSDR: forceSDR)
        let background = try backgroundColor(framing.background, target: target)
        let largestDimension = max(canvas.width, canvas.height)
        let cropFraction = framing.crop.map { min($0.width.seconds, $0.height.seconds) } ?? 1
        let decodeDimension = preview ? Int(min(32_768, Double(largestDimension) / cropFraction * 2)) : nil
        let decoded = try decode(file, name: name, previewDimension: decodeDimension, forceISOGainMapFallback: false)
        if isGap {
            // Convert the uniform fill once. The sample generator repeats this
            // frame on the output clock and can reuse an identical encoded span.
            let rgb = target.encode(.zero, alpha: 0, background: background, isHDRSource: false)
            let pixel = [rgb.x.littleEndian, rgb.y.littleEndian, rgb.z.littleEndian]
            var row = Data(capacity: canvas.width * 6)
            pixel.withUnsafeBytes { bytes in
                for _ in 0..<canvas.width { row.append(contentsOf: bytes) }
            }
            var raster = Data(capacity: canvas.width * canvas.height * 6)
            for _ in 0..<canvas.height {
                if Task.isCancelled || cancelled?() == true { throw CancellationError() }
                raster.append(row)
            }
            return StillImageFrame(sourceInfo: decoded.info, width: canvas.width, height: canvas.height,
                                   encoded: raster, target: target, pixelAspect: aspect * Double(canvas.height) / Double(canvas.width))
        }
        let image = try sourceImage(decoded.image, colorSpace: decoded.colorSpace)
            .oriented(forExifOrientation: Int32(decoded.info.orientation))
        let placed = place(image, width: canvas.width, height: canvas.height, aspect: aspect, framing: framing)
        let width = canvas.width
        let height = canvas.height
        // Read back bounded bands instead of allocating a full float
        // raster in addition to the encoded frame.
        let bandHeight = min(height, max(1, 8_388_608 / (width * 16)))
        var linear = [Float](repeating: 0, count: width * bandHeight * 4)
        let isHDRSource = decoded.info.rendition != .sdr
        var encoded = Data(count: width * height * 6)
        try encoded.withUnsafeMutableBytes { bytes in
            let words = bytes.bindMemory(to: UInt16.self)
            for row in stride(from: 0, to: height, by: bandHeight) {
                try Task.checkCancellation()
                if cancelled?() == true { throw CancellationError() }
                let rows = min(bandHeight, height - row)
                let bounds = CGRect(x: 0, y: height - row - rows, width: width, height: rows)
                linear.withUnsafeMutableBytes { pixels in
                    linearContext.render(
                        placed, toBitmap: pixels.baseAddress!, rowBytes: width * 16,
                        bounds: bounds, format: .RGBAf, colorSpace: target.linearColorSpace
                    )
                }
                let destinationOffset = row * width * 3
                for pixel in 0..<(rows * width) {
                    let source = 4 * pixel
                    let destination = destinationOffset + 3 * pixel
                    let channels = target.encode(
                        SIMD3(linear[source], linear[source + 1], linear[source + 2]),
                        alpha: linear[source + 3], background: background, isHDRSource: isHDRSource
                    )
                    words[destination] = channels.x.littleEndian
                    words[destination + 1] = channels.y.littleEndian
                    words[destination + 2] = channels.z.littleEndian
                }
            }
        }
        return StillImageFrame(
            sourceInfo: decoded.info, width: width, height: height, encoded: encoded,
            target: target, pixelAspect: aspect * Double(height) / Double(width)
        )
    }

    private static func place(
        _ image: CIImage, width: Int, height: Int, aspect: Double, framing: StillImageFraming
    ) -> CIImage {
        let extent = image.extent
        let crop: CGRect
        if let authored = framing.crop {
            let x = authored.x.seconds
            let y = authored.y.seconds
            let w = authored.width.seconds
            let h = authored.height.seconds
            crop = CGRect(
                x: extent.minX + x * extent.width, y: extent.minY + (1 - y - h) * extent.height,
                width: w * extent.width, height: h * extent.height
            )
        } else {
            crop = extent
        }
        let displayWidth = Double(height) * aspect
        let codedScale = Double(width) / displayWidth
        let horizontal = displayWidth / crop.width
        let vertical = Double(height) / crop.height
        let scale = framing.mode == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
        let scaleX = scale * codedScale
        let originX = (Double(width) - crop.width * scaleX) / 2
        let originY = (Double(height) - crop.height * scale) / 2
        let transform = CGAffineTransform(
            a: scaleX, b: 0, c: 0, d: scale,
            tx: originX - crop.minX * scaleX, ty: originY - crop.minY * scale
        )
        return image.cropped(to: crop).transformed(by: transform, highQualityDownsample: true)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func backgroundColor(_ color: String, target: StillImageTarget) throws -> SIMD3<Float> {
        guard let rgb = UInt32(color.dropFirst(), radix: 16),
              let background = CGColor(
                  colorSpace: sRGB,
                  components: [Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255,
                               Double(rgb & 255) / 255, 1]
              )?.converted(to: target.linearColorSpace, intent: .relativeColorimetric, options: nil),
              let components = background.components, components.count == 4 else {
            throw error("still_background", "Cannot convert the still background to the program color space.")
        }
        return SIMD3(Float(components[0]), Float(components[1]), Float(components[2]))
    }
}
