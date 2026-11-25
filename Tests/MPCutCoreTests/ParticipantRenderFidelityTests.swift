import AVFoundation
import CoreImage
import Foundation
@testable import MPCutCore
import XCTest

/// Picture fidelity of the composited Tiles render: color encoding, depth, rate control, scaling and cadence.
final class ParticipantRenderFidelityTests: XCTestCase {
    func testSDROutputKeepsBT709CodeValuesAndCanvasColors() throws {
        var input: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 1, kCVPixelFormatType_32BGRA, nil, &input), kCVReturnSuccess)
        let ramp = try XCTUnwrap(input)
        CVPixelBufferLockBaseAddress(ramp, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(ramp)).assumingMemoryBound(to: UInt8.self)
        for x in 0..<256 { (0..<4).forEach { bytes[x * 4 + $0] = $0 == 3 ? 255 : UInt8(x) } }
        CVPixelBufferUnlockBaseAddress(ramp, [])
        // The decoder tags a BT.709 or untagged recording this way.
        CVBufferSetAttachment(ramp, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(ramp, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let extent = CGRect(x: 0, y: 0, width: 256, height: 1)

        let rendered = try ParticipantPictureColor.sdr.render(CIImage(cvPixelBuffer: ramp), extent: extent)
        XCTAssertEqual(CVBufferCopyAttachment(rendered, kCVImageBufferTransferFunctionKey, nil) as? String,
                       kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(ParticipantPictureColor.sdr.encoderTransfer, AVVideoTransferFunction_ITU_R_709_2)
        let output = try greens(rendered)
        XCTAssertLessThanOrEqual(zip(output, 0..<256).map { abs(Int($0) - $1) }.max() ?? 255, 1,
                                 "A BT.709 picture changed code values: \(output)")

        // Canvas colors are written with their own code values.
        let hex = ParticipantCompositor.color(0x232f9b, in: extent, space: ParticipantPictureColor.sdr.canvasSpace)
        let swatch = try ParticipantPictureColor.sdr.render(hex, extent: extent)
        CVPixelBufferLockBaseAddress(swatch, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(swatch, .readOnly) }
        let pixel = try XCTUnwrap(CVPixelBufferGetBaseAddress(swatch)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual([pixel[2], pixel[1], pixel[0]], [0x23, 0x2f, 0x9b])
    }

    func testCanvasWithoutFrameRateFollowsTheRecording() throws {
        let source = fixture("ProRes-2997.mov")
        let document = source.deletingLastPathComponent().appendingPathComponent("participant-rate.cut")
        let project = CutProject.sequence([.init(id: "clip", file: source.path, from: .zero,
                                                 to: .init(numerator: 1001, denominator: 3000))])
        let json = Data(#"{"canvas":{"width":160,"height":90},"shots":[{"layout":"original"}]}"#.utf8)
        let plan = try JSONDecoder().decode(ParticipantRenderPlan.self, from: json)
        XCTAssertNil(plan.canvas.requestedFrameRate)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plan.canvas), as: UTF8.self).contains("frame_rate"))
        XCTAssertEqual(try JSONDecoder().decode(ParticipantRenderPlan.self, from: JSONEncoder().encode(plan)), plan)
        XCTAssertNil(try JSONDecoder().decode(ParticipantRenderPlan.self,
                                              from: Data(#"{"shots":[{"layout":"original"}]}"#.utf8)).canvas.requestedFrameRate)

        let renderer = ParticipantRenderer()
        let followed = try renderer.prepare(project, document: document, plan: plan, cancelled: nil)
        XCTAssertEqual(followed.plan.canvas.frameRate, .init(numerator: 30000, denominator: 1001))
        XCTAssertEqual(followed.frameCount, 10)
        var chosen = plan
        chosen.canvas.frameRate = .init(numerator: 30)
        XCTAssertEqual(try renderer.prepare(project, document: document, plan: chosen, cancelled: nil).plan.canvas.frameRate,
                       .init(numerator: 30))
        // Programmatic canvases keep their historical explicit rate.
        XCTAssertEqual(ParticipantCanvas(width: 160, height: 90).requestedFrameRate, .init(numerator: 30))

        XCTAssertEqual(ParticipantRenderer.canvasRate(.init(numerator: 2997, denominator: 100)),
                       .init(numerator: 30000, denominator: 1001))
        XCTAssertEqual(ParticipantRenderer.canvasRate(.init(numerator: 25)), .init(numerator: 25))
        XCTAssertNil(ParticipantRenderer.canvasRate(.init(numerator: 100_003, denominator: 3001)))
    }

    func testDeepRecordingKeepsTenBitsAndQualityTiersDifferInSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Textured ten-bit ProRes: the bundled fixtures are flat colors, which every tier encodes alike.
        let source = folder.appendingPathComponent("textured.mov")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=30000/1001:d=0.4004,noise=alls=12:allf=t",
                    "-c:v", "prores_ks", "-profile:v", "standard", "-pix_fmt", "yuv422p10le", source.path])
        let document = folder.appendingPathComponent("participant-depth.cut")
        let project = CutProject.sequence([.init(id: "clip", file: source.path, from: .zero,
                                                 to: .init(numerator: 1001, denominator: 2500))])
        let plan = ParticipantRenderPlan(canvas: .init(width: 320, height: 180, frameRate: nil), shots: [.init(layout: .original)])

        var sizes: [ReencodeQuality: Int] = [:]
        for quality in [ReencodeQuality.smallerFile, .highQuality] {
            let output = folder.appendingPathComponent("\(quality.rawValue).mov")
            try AnalysisSidecar.$readsEnabled.withValue(false) {
                _ = try ParticipantRenderer().render(project, document: document, plan: plan, to: output,
                                                     settings: .init(codec: .hevc, quality: quality, audio: .removeAudio))
            }
            let video = try XCTUnwrap(CutEngine(useSidecar: false).inspect(output).videoStream)
            XCTAssertEqual(video.bitDepth, 10, "A ten-bit recording lost depth in SDR HEVC")
            XCTAssertEqual(video.colorTransfer, "bt709")
            XCTAssertEqual(video.frameRate, .init(numerator: 30000, denominator: 1001))
            sizes[quality] = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes[.highQuality]), try XCTUnwrap(sizes[.smallerFile]),
                             "The quality tiers did not change the encoded size")
        XCTAssertEqual(ParticipantPictureWriter.quality(.smallerFile), 0.45)
        XCTAssertEqual(ParticipantPictureWriter.quality(.balanced), 0.60)
        XCTAssertEqual(ParticipantPictureWriter.quality(.highQuality), 0.75)
    }

    func testPlacementResamplesInsideTheCropAndKeepsNativePixels() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 32)
        let red = ParticipantCompositor.color(0xff0000, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let picture = ParticipantCompositor.color(0x00ff00, in: extent)
        let source = red.composited(over: picture)

        // Upscaling a crop must not read the neighboring pixels a privacy crop excludes.
        let slot = CGRect(x: 0, y: 0, width: 96, height: 96)
        let placed = ParticipantCompositor.place(source.cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)),
                                                 inside: slot, framing: .fit)
        let upscaled = try rgba(placed, extent: slot)
        XCTAssertLessThanOrEqual(stride(from: 1, to: upscaled.count, by: 4).map { upscaled[$0] }.max() ?? 255, 2,
                                 "Resampling leaked pixels from outside the crop")
        XCTAssertEqual(stride(from: 3, to: upscaled.count, by: 4).map { upscaled[$0] }.min(), 255,
                       "Resampling darkened or uncovered the border of the cell")

        // At its own size a picture is not resampled.
        let native = try rgba(ParticipantCompositor.place(source, inside: extent, framing: .fit), extent: extent)
        XCTAssertEqual(native, try rgba(source, extent: extent))

        // Cells with fractional edges meet without a gap.
        let canvas = CGRect(x: 0, y: 0, width: 160, height: 30)
        var grid = ParticipantCompositor.color(0x000000, in: canvas)
        for cell in ParticipantCompositor.slots(.grid, count: 9, extent: canvas) {
            grid = ParticipantCompositor.place(picture, inside: cell, framing: .fill).composited(over: grid)
        }
        let row = try rgba(grid, extent: canvas)
        XCTAssertFalse(stride(from: 0, to: row.count, by: 4).contains { row[$0 + 1] < 200 }, "A grid seam shows the canvas")
    }

    private func ffmpeg(_ arguments: [String]) throws {
        let paths = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("The textured fixture requires ffmpeg.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("The installed ffmpeg could not encode the textured fixture.") }
    }

    private func greens(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        return (0..<CVPixelBufferGetWidth(buffer)).map { base[$0 * 4 + 1] }
    }

    private func rgba(_ image: CIImage, extent: CGRect) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
        ParticipantCompositor.context.render(image, toBitmap: &bytes, rowBytes: Int(extent.width) * 4, bounds: extent,
                                             format: .RGBA8, colorSpace: ParticipantCompositor.colorSpace)
        return bytes
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures").appendingPathComponent(name)
    }
}
