import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MPCutCore

final class StillExportTests: XCTestCase {
    private let frame = RationalTime(numerator: 1, denominator: 30)

    func testExplicitCopyRefusesVisibleStillBeforeOpeningOfflineMedia() throws {
        let card = StillAsset(id: "art", file: "offline.png", displayName: "Card", fingerprint: "offline")
        let item = StillInsert(id: "title", assetID: card.id, duration: frame, cadence: frame)
        let format = StillTimelineFormat(width: 320, height: 240, cadence: frame, codec: .prores, container: "mov")
        let project = CutProject.stillSequence(.init(items: [.still(item)], stillAssets: [card], stillFormat: format))
        XCTAssertThrowsError(try StillExportPlanner().resolve(project, tracks: .video, mode: .copy,
                                                              offerAlternatives: false)) {
            guard let issue = $0 as? CutError else { return XCTFail("Expected a structured cut error") }
            XCTAssertEqual(issue.code, "still_requires_generation")
            XCTAssertEqual(issue.reason, .placementPicture)
        }
    }

    func testReviewedBoundaryChangesOnlyMatchingOccurrenceFragment() throws {
        let one = CutSequenceClip(id: "one", file: "camera.mov", from: .zero, to: .init(numerator: 6))
        let two = CutSequenceClip(id: "two", file: "camera.mov", from: .zero, to: .init(numerator: 6))
        let asset = StillAsset(id: "art", file: "offline.png", displayName: "Photo", fingerprint: "offline")
        let from = RationalTime(numerator: 2)
        let to = RationalTime(numerator: 4)
        let replacement = StillReplacement(id: "cover", assetID: asset.id, coverage: .sequence([
            .init(clipID: one.id, range: .init(from: from, to: to)),
            .init(clipID: two.id, range: .init(from: from, to: to)),
        ]))
        let project = CutProject.stillSequence(.init(items: [.source(one), .source(two)],
                                                      stillAssets: [asset], stillReplacements: [replacement]))
        let adjustment = StillBoundaryAdjustment(placementID: replacement.id, boundary: .end, clock: "sequence",
                                                  occurrenceID: two.id, requestedTime: to, adjustedTime: .init(numerator: 5),
                                                  durationChange: .init(numerator: 1))
        let adjusted = try project.applyingStillBoundary(adjustment)
        let spans = try adjusted.resolveStills().spans.filter { $0.placementID == replacement.id }
        XCTAssertEqual(spans.map(\.output), [.init(from: from, to: to), .init(from: .init(numerator: 8), to: .init(numerator: 11))])
        XCTAssertThrowsError(try adjusted.applyingStillBoundary(adjustment))
    }

    func testStandaloneProgramReportsExactGeneratedDurationAndPublishesOnlyOnSuccess() throws {
        do { _ = try ReencodeEngine.findHelper(override: nil) }
        catch { throw XCTSkip("The bundled FFmpeg helper is needed for still video generation.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("card.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let imageDestination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(imageDestination))
        let color = StillTimelineFormat.sdrColorPolicy
        let target = StillTimelineFormat(width: 320, height: 240, cadence: frame, codec: .prores, container: "mov")
        let asset = StillAsset(id: "art", file: png.lastPathComponent, displayName: "Card", fingerprint: try StillImage.fingerprint(png))
        let duration = RationalTime(numerator: 1, denominator: 10)
        let project = try CutProject.makeStillTimeline(format: target, asset: asset, placementID: "title",
                                                       duration: duration, colorPolicy: color)
        let output = folder.appendingPathComponent("program.mov")
        let planner = StillExportPlanner(useSidecar: false)
        let plan = try planner.resolve(project, relativeTo: folder.appendingPathComponent("show.cut"),
                                       tracks: .video, requireCameraCopy: true, output: output)
        XCTAssertEqual(plan.report.mode, .smart)
        XCTAssertEqual(plan.report.generatedStillDuration, duration)
        XCTAssertEqual(plan.report.encodedVideoDuration, duration)
        XCTAssertEqual(plan.report.copiedCameraDuration, .zero)
        XCTAssertEqual(plan.report.encodedCameraDuration, .zero)
        XCTAssertThrowsError(try planner.write(plan, to: output) { _ in false }) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try planner.write(plan, to: output)
        let written = try Probe.read(output, keyframes: true)
        XCTAssertEqual(written.duration, duration)
        XCTAssertEqual(written.frames.count, 3)

        let encodedOutput = folder.appendingPathComponent("conversion.mov")
        let encoded = try planner.resolve(project, relativeTo: folder.appendingPathComponent("show.cut"),
                                          tracks: .video, mode: .encode, requireCameraCopy: true, output: encodedOutput)
        try planner.write(encoded, to: encodedOutput)
        let converted = try Probe.read(encodedOutput, keyframes: true)
        XCTAssertEqual(converted.duration, duration)
        XCTAssertEqual(converted.frames.count, 3)
        XCTAssertEqual(converted.video.colorMatrix, color.matrix)
        XCTAssertEqual(converted.video.colorRange, color.range)
    }
}
