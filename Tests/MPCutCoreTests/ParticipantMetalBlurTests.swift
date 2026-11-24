import CoreImage
import Metal
@testable import MPCutCore
import XCTest

final class ParticipantMetalBlurTests: XCTestCase {
    func testBlurSamplesOnlyWithinEachRegionAndLastRegionWinsAtOverlap() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let metal = try XCTUnwrap(ParticipantMetalBlur.shared)
        let extent = CGRect(x: 7, y: 11, width: 144, height: 100)
        let left = CGRect(x: 7, y: 11, width: 44, height: 52)
        let right = CGRect(x: 45, y: 24, width: 50, height: 32)
        let top = CGRect(x: 7, y: 74, width: 144, height: 37)
        let input = ParticipantCompositor.color(0xff0000, in: right)
            .composited(over: ParticipantCompositor.color(0x0000ff, in: top))
            .composited(over: ParticipantCompositor.color(0x204080, in: extent))
        let first = try XCTUnwrap(metal.apply(to: input, areas: [left]))
        let last = try XCTUnwrap(metal.apply(to: input, areas: [right]))
        let combined = try XCTUnwrap(metal.apply(to: input, areas: [left, right]))
        let nextInput = ParticipantCompositor.color(0xffffff, in: extent)
        let next = try XCTUnwrap(metal.apply(to: nextInput, areas: [left, right]))
        let reversed = try XCTUnwrap(metal.apply(to: input, areas: [right, left]))

        let context = ParticipantCompositor.context
        func pixels(_ image: CIImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
            context.render(image, toBitmap: &result, rowBytes: Int(extent.width) * 4, bounds: extent,
                           format: .RGBA8, colorSpace: ParticipantCompositor.colorSpace)
            return result
        }
        let original = pixels(input)
        let firstPixels = pixels(first)
        let lastPixels = pixels(last)
        let combinedPixels = pixels(combined)
        XCTAssertEqual(pixels(next), pixels(nextInput))
        let reversedPixels = pixels(reversed)
        var largestSourceDifference = 0
        var largestLayerDifference = 0
        for row in 0..<Int(extent.height) {
            for col in 0..<Int(extent.width) {
                let x = extent.minX + Double(col) + 0.5
                let y = extent.maxY - Double(row) - 0.5
                let point = CGPoint(x: x, y: y)
                let offset = 4 * (row * Int(extent.width) + col)
                let range = offset..<(offset + 4)
                let inRight = right.contains(point)
                let inLeft = left.contains(point)
                if inRight || !inLeft {
                    for channel in range {
                        largestSourceDifference = max(largestSourceDifference,
                            abs(Int(combinedPixels[channel]) - Int(original[channel])))
                    }
                }
                if inRight || inLeft {
                    let expected = inRight ? lastPixels : firstPixels
                    let expectedReversed = inLeft ? firstPixels : lastPixels
                    for channel in range {
                        largestLayerDifference = max(largestLayerDifference,
                            abs(Int(combinedPixels[channel]) - Int(expected[channel])),
                            abs(Int(reversedPixels[channel]) - Int(expectedReversed[channel])))
                    }
                }
            }
        }
        // An extra half-float color conversion may round a saturated channel by one SDR code.
        XCTAssertLessThanOrEqual(largestSourceDifference, 1)
        XCTAssertLessThanOrEqual(largestLayerDifference, 1)
        let overlapSample = 4 * (67 * Int(extent.width) + 39)
        XCTAssertNotEqual(firstPixels[overlapSample..<(overlapSample + 4)],
                          combinedPixels[overlapSample..<(overlapSample + 4)])
    }
}
