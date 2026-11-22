import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import XCTest
@testable import MPCutCore

final class StillImageTests: XCTestCase {
    func testSDRArtworkWhiteUsesProgramReferenceWhite() throws {
        let url = try writeImage(width: 8, height: 8, pixels: Array(repeating: [255, 255, 255, 255], count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        for (transfer, expected) in [("smpte2084", 0.5807), ("arib-std-b67", 0.75)] {
            let frame = try StillImage.render(url, canvas: .init(width: 8, height: 8, transfer: transfer, primaries: "bt2020"))
            XCTAssertEqual(component(frame, x: 4, y: 4), expected, accuracy: 0.001)
            let pixels = try frame.pixelBuffer
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixels), kCVPixelFormatType_ARGB2101010LEPacked)
            let tag = try XCTUnwrap(CVBufferCopyAttachment(pixels, kCVImageBufferTransferFunctionKey, nil) as? String)
            let expectedTag = transfer == "smpte2084" ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG
            XCTAssertEqual(tag, expectedTag as String)
        }
    }

    func testNormalizedCropFitAndLinearAlphaUseTheSameGeometry() throws {
        // Two rows of opaque red above two rows of half-transparent green.
        let pixels = Array(repeating: [UInt8(255), 0, 0, 255], count: 8)
            + Array(repeating: [0, 128, 0, 128], count: 8)
        let url = try writeImage(width: 4, height: 4, pixels: pixels)
        defer { try? FileManager.default.removeItem(at: url) }
        let crop = StillImageFraming.Crop(
            x: .zero, y: .init(numerator: 1, denominator: 2),
            width: .init(numerator: 1), height: .init(numerator: 1, denominator: 2)
        )
        let frame = try StillImage.render(
            url, canvas: .init(width: 8, height: 8), framing: .init(mode: .fit, crop: crop, background: "#0000ff"),
            forceSDR: true
        )
        XCTAssertTrue(frame.sourceInfo.hasAlpha)
        XCTAssertEqual(component(frame, x: 4, y: 0, channel: 2), 1, accuracy: 0.002)
        XCTAssertEqual(component(frame, x: 4, y: 4, channel: 0), 0, accuracy: 0.002)
        XCTAssertEqual(component(frame, x: 4, y: 4, channel: 1), 0.737, accuracy: 0.005)
        XCTAssertEqual(component(frame, x: 4, y: 4, channel: 2), 0.734, accuracy: 0.005)
        XCTAssertEqual(try frame.sdrImage().colorSpace?.name, CGColorSpace.sRGB)
    }

    func testISOGainMapLinearPatchesAndSDRShoulder() throws {
        for suffix in ["jpeg", "heic"] {
            let url = fixture("gain-map.\(suffix)")
            let canvas = StillImageCanvas(width: 64, height: 64, transfer: "pq", primaries: "bt2020")
            let hdr = try StillImage.render(url, canvas: canvas)
            XCTAssertEqual(hdr.sourceInfo.rendition, .gainMap)
            XCTAssertTrue(hdr.sourceInfo.auxiliaryImages.contains("isoGainMap"))
            XCTAssertEqual(component(hdr, x: 16, y: 32), 0.510, accuracy: 0.004)
            XCTAssertEqual(component(hdr, x: 48, y: 32), 0.729, accuracy: 0.004)
            let sdr = try StillImage.render(url, canvas: canvas, forceSDR: true)
            XCTAssertEqual(component(sdr, x: 16, y: 32), 0.737, accuracy: 0.004)
            XCTAssertEqual(component(sdr, x: 48, y: 32), 0.972, accuracy: 0.004)
        }
    }

    func testISOGainMapFallbackRecoversLinearPatches() throws {
        for suffix in ["jpeg", "heic"] {
            let decoded = try StillImage.decode(fixture("gain-map.\(suffix)"), forceISOGainMapFallback: true)
            XCTAssertEqual(decoded.info.rendition, .gainMap)
            XCTAssertEqual(decoded.info.headroom, 4)
            let image = CIImage(cgImage: decoded.image, options: [.colorSpace: decoded.colorSpace])
            let context = CIContext(options: [.workingColorSpace: decoded.colorSpace])
            for (x, expected) in [(16, Float(0.5)), (48, Float(4))] {
                var pixel = [Float](repeating: 0, count: 4)
                context.render(image, toBitmap: &pixel, rowBytes: 16,
                               bounds: CGRect(x: x, y: 32, width: 1, height: 1),
                               format: .RGBAf, colorSpace: decoded.colorSpace)
                for channel in 0..<3 {
                    XCTAssertEqual(pixel[channel], expected, accuracy: 0.03, "\(suffix) at x=\(x)")
                }
            }
        }
    }

    func testTaggedTenBitAVIFRecoversBothHDRTransfers() throws {
        for (name, rendition) in [("pq", StillImageInfo.Rendition.pq), ("hlg", .hlg)] {
            let url = fixture("hdr-\(name).avif")
            let frame = try StillImage.render(url, canvas: .init(width: 64, height: 64, transfer: name, primaries: "bt2020"))
            XCTAssertEqual(frame.sourceInfo.codec, .avif)
            XCTAssertEqual(frame.sourceInfo.bitsPerComponent, 10)
            XCTAssertEqual(frame.sourceInfo.rendition, rendition)
            let patches: [(Int, Double)] = name == "hlg"
                ? [(8, 0.58), (24, 0.75), (40, 0.86), (56, 0.96)]
                : [(16, 0.58), (48, 0.75)]
            for (x, signal) in patches {
                XCTAssertEqual(component(frame, x: x, y: 32), signal, accuracy: 0.007)
            }
        }
    }

    func testJXLPQPreservesHighDepthHighlightSignal() throws {
        let url = fixture("pq_gradient.jxl")
        let frame = try StillImage.render(url, canvas: .init(width: 1088, height: 64, transfer: "pq", primaries: "bt2020"))
        XCTAssertEqual(frame.sourceInfo.codec, .jxl)
        XCTAssertEqual(frame.sourceInfo.bitsPerComponent, 16)
        XCTAssertEqual(frame.sourceInfo.rendition, .pq)
        XCTAssertEqual(component(frame, x: 540, y: 32), 0.50, accuracy: 0.004)
        XCTAssertEqual(component(frame, x: 864, y: 32), 0.749, accuracy: 0.004)
        XCTAssertEqual(component(frame, x: 1080, y: 32), 0.898, accuracy: 0.004)
    }

    func testAnimatedInputsRejectEvenWhenImageIOReportsOneImage() throws {
        for suffix in ["jxl", "webp"] {
            XCTAssertThrowsError(try StillImage.inspect(fixture("animated.\(suffix)"))) { error in
                XCTAssertEqual((error as? CutError)?.code, "still_animated")
            }
        }
    }

    func testOrientationAppliedOnceBeforeFraming() throws {
        let pixels = Array(repeating: [UInt8(255), 0, 0, 255], count: 4)
            + Array(repeating: [0, 0, 255, 255], count: 4)
        let url = try writeImage(
            width: 4, height: 2, pixels: pixels, type: "public.tiff",
            properties: [kCGImagePropertyOrientation: 6]
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = try StillImage.render(url, canvas: .init(width: 2, height: 4), forceSDR: true)
        XCTAssertEqual(frame.sourceInfo.orientation, 6)
        XCTAssertEqual(frame.sourceInfo.displayWidth, 2)
        XCTAssertEqual(frame.sourceInfo.displayHeight, 4)
        XCTAssertEqual(component(frame, x: 0, y: 2, channel: 2), 1, accuracy: 0.002)
        XCTAssertEqual(component(frame, x: 1, y: 2), 1, accuracy: 0.002)
    }

    func testTruncatedImageIsRejectedBeforePlacement() throws {
        let bytes = try Data(contentsOf: fixture("patch.png"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.prefix(32).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try StillImage.inspect(url))
    }

    func testWideGamutICCIsSDRAndKeepsProgramPrimaries() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let color: [UInt8] = [240, 100, 40, 255]
        let url = try writeImage(width: 4, height: 4, pixels: Array(repeating: color, count: 16), colorSpace: displayP3)
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = try StillImage.render(
            url, canvas: .init(width: 4, height: 4, transfer: "srgb", primaries: "smpte432")
        )
        XCTAssertEqual(frame.sourceInfo.rendition, .sdr)
        XCTAssertEqual(frame.sourceInfo.colorSpace, CGColorSpace.displayP3 as String)
        for channel in 0..<3 {
            XCTAssertEqual(component(frame, x: 2, y: 2, channel: channel), Double(color[channel]) / 255, accuracy: 0.004)
        }
    }

    func testBandedRenderingKeepsTopToBottomRasterOrder() throws {
        let url = try writeImage(width: 1, height: 2, pixels: [[255, 0, 0, 255], [0, 0, 255, 255]])
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = try StillImage.render(
            url, canvas: .init(width: 1024, height: 1024), framing: .fill, forceSDR: true
        )
        XCTAssertGreaterThan(component(frame, x: 512, y: 100), component(frame, x: 512, y: 100, channel: 2))
        XCTAssertGreaterThan(component(frame, x: 512, y: 900, channel: 2), component(frame, x: 512, y: 900))
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/fixtures/stills/\(name)")
    }

    private func component(_ frame: StillImageFrame, x: Int, y: Int, channel: Int = 0) -> Double {
        let bytes = frame.rgb48LE()
        let index = (y * frame.width + x) * 6 + channel * 2
        return Double(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8) / 65_535
    }

    private func writeImage(
        width: Int, height: Int, pixels: [[UInt8]], type: String = "public.png", properties: [CFString: Any] = [:],
        colorSpace: CGColorSpace = StillImage.sRGB
    ) throws -> URL {
        let data = Data(pixels.flatMap { $0 })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric
        ))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
