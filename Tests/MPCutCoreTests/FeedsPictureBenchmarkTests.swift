import CoreImage
import CoreVideo
@testable import MPCutCore
import XCTest

final class FeedsPictureBenchmarkTests: XCTestCase {
    func testDenseGalleryCropAndBlur() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MPCUT_FEEDS_BENCH"] == "1" else {
            throw XCTSkip("Set MPCUT_FEEDS_BENCH=1 to measure.")
        }
        let allowMetal = environment["MPCUT_FEEDS_BENCH_FORCE_CI"] != "1"

        let appearances = (0..<40).map { index -> ParticipantAppearance in
            let x = Double(index % 8) * 0.12 + 0.02
            let y = Double(index / 8) * 0.19 + 0.025
            return ParticipantAppearance(
                id: "tile-\(index)", participantID: "feed-\(index)",
                range: .init(from: .zero, to: .init(numerator: 1)),
                bounds: .init(x: x, y: y, width: 0.12, height: 0.18),
                labelBounds: .init(x: x, y: y + 0.15, width: 0.04, height: 0.025))
        }
        let treatments = Dictionary(uniqueKeysWithValues: appearances.compactMap(\.participantID).map {
            ($0, ParticipantRedaction(participantID: $0, treatment: .blur))
        })
        XCTAssertEqual(treatments.count, 40)

        for (width, height) in [(1920, 1080), (3840, 2160)] {
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let crop = extent.insetBy(dx: 8, dy: 8)
            let transfers: [(String, CFString?)] = [
                ("bt709", nil),
                ("smpte2084", kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
                ("arib-std-b67", kCVImageBufferTransferFunction_ITU_R_2100_HLG)
            ]
            for (transfer, expectedHDR) in transfers {
                let color = ParticipantPictureColor(transfer: transfer)
                let pattern = CIFilter(name: "CICheckerboardGenerator", parameters: [
                    "inputWidth": 12,
                    "inputColor0": CIColor(red: 0.25, green: 0.28, blue: 0.3),
                    "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8)
                ])
                let chart = try XCTUnwrap(pattern?.outputImage).cropped(to: extent)
                let linearHighlight = try XCTUnwrap(CGColor(colorSpace: StillImage.linear2020, components: [2, 2, 2, 1]))
                let bright = CIImage(color: CIColor(cgColor: linearHighlight))
                let lower = bright.cropped(to: CGRect(x: 0, y: 0, width: width, height: 25))
                let upper = bright.cropped(to: CGRect(x: 0, y: height - 25, width: width, height: 25))
                let highlight = lower.composited(over: upper)
                let input = try color.render(highlight.composited(over: chart), extent: extent)
                let source = CIImage(cvPixelBuffer: input, options: [.toneMapHDRtoSDR: false])
                let reference = try color.render(
                    ParticipantCompositor.place(source.cropped(to: crop), inside: extent, framing: .fill),
                    extent: extent)
                let referenceTile = try pixel(reference, x: width / 16, y: height / 2)
                let referenceHighlight = try pixel(reference, x: width / 2, y: 8)
                let referenceWhite = try pixel(try color.render(CIImage(color: .white), extent: extent), x: width / 2, y: 8)
                let output = try color.render(chart, extent: extent)
                var samples: [Double] = []
                for frame in 0..<70 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    try autoreleasepool {
                        let treated = ParticipantCompositor.redact(source, appearances: appearances,
                                                                  treatments: treatments, allowMetal: allowMetal)
                        let picture = ParticipantCompositor.place(treated.cropped(to: crop), inside: extent, framing: .fill)
                        _ = try color.render(picture, extent: extent, into: output)
                        // A CPU read also waits for the GPU work that produces the buffer.
                        let blurred = try pixel(output, x: width / 16, y: height / 2)
                        XCTAssertNotEqual(blurred, referenceTile)
                    }
                    if frame >= 10 {
                        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    }
                }
                let actualTransfer = CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
                let primaries = CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String
                let outputHighlight = try pixel(output, x: width / 2, y: 8)
                XCTAssertEqual(outputHighlight, referenceHighlight)
                if let expectedHDR {
                    XCTAssertEqual(actualTransfer, expectedHDR as String)
                    XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
                    XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_ARGB2101010LEPacked)
                    XCTAssertGreaterThan(outputHighlight, referenceWhite)
                } else {
                    XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_32BGRA)
                }
                samples.sort()
                print(String(format: "FEEDS_PICTURE %dx%d %@ path=%@ median=%.2fms p95=%.2fms transfer=%@ primaries=%@ highlight=%08x reference=%08x white=%08x",
                             width, height, transfer, allowMetal ? "automatic" : "core-image", samples[29], samples[56],
                             actualTransfer ?? "missing", primaries ?? "missing", outputHighlight, referenceHighlight, referenceWhite))
            }
        }
    }

    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> UInt32 {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw NSError(domain: "FeedsPictureBenchmark", code: Int(status))
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        return base.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4, as: UInt32.self)
    }
}
