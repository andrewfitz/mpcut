import AVFoundation
import Foundation
@testable import MPCutCore
import XCTest

/// Every fallback says so: what a plan gives up is a warning, and what only writing shows is a written warning.
final class FallbackNoticeTests: XCTestCase {
    func testWrittenNoticesStayWithTheExportThatRecordedThem() throws {
        ExportWriteNotices.record("Nobody collects this.")
        let outer = ExportWriteNotices.collecting { () -> Int in
            ExportWriteNotices.record("first")
            let inner = ExportWriteNotices.collecting { ExportWriteNotices.record(["second", "first"]) }
            XCTAssertEqual(inner.notices, ["second", "first"])
            XCTAssertEqual(ExportWriteNotices.recorded, ["first", "second"])
            return 7
        }
        XCTAssertEqual(outer.value, 7)
        // A nested collection also reaches the export around it, once each.
        XCTAssertEqual(outer.notices, ["first", "second"])
        XCTAssertEqual(ExportWriteNotices.recorded, [])

        // Exports running side by side keep their own notices.
        let group = DispatchGroup()
        let lock = NSLock()
        var seen: [Int: [String]] = [:]
        for index in 0..<8 {
            group.enter()
            Thread {
                let collected = ExportWriteNotices.collecting { ExportWriteNotices.record("export \(index)") }
                lock.lock()
                seen[index] = collected.notices
                lock.unlock()
                group.leave()
            }.start()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        for index in 0..<8 { XCTAssertEqual(seen[index], ["export \(index)"]) }
    }

    func testRefusedConstantQualityIsEncodedAtTheTierRateAndSaysSo() throws {
        let canvas = ParticipantCanvas(width: 1920, height: 1080, frameRate: .init(numerator: 30))
        let settings = ReencodeSettings(codec: .hevc, quality: .highQuality)
        let requested: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.75, AVVideoAllowFrameReorderingKey: false]
        ]
        let kept = ParticipantPictureWriter.acceptedSettings(requested, canvas: canvas, settings: settings) { _ in true }
        XCTAssertNil(kept.warning)
        XCTAssertEqual((kept.settings[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoQualityKey] as? Double, 0.75)

        let refused = ParticipantPictureWriter.acceptedSettings(requested, canvas: canvas, settings: settings) { candidate in
            (candidate[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoQualityKey] == nil
        }
        let compression = try XCTUnwrap(refused.settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertNil(compression[AVVideoQualityKey])
        let rate = ParticipantPictureWriter.bitRate(canvas, quality: .highQuality)
        XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, rate)
        XCTAssertEqual(compression[AVVideoAllowFrameReorderingKey] as? Bool, false)
        let warning = try XCTUnwrap(refused.warning)
        XCTAssertTrue(warning.contains("constant quality"), warning)
        XCTAssertTrue(warning.contains("HEVC"), warning)
        XCTAssertTrue(warning.contains(String(format: "%.1f Mbps", Double(rate) / 1_000_000)), warning)

        // ProRes and JPEG have no constant-quality setting to refuse.
        let prores: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes422]
        XCTAssertNil(ParticipantPictureWriter.acceptedSettings(prores, canvas: canvas, settings: .init(codec: .prores)) { _ in false }.warning)
    }

    func testPlannedPictureLossesAreWarnings() throws {
        // Eight-bit codecs say they shorten a deep recording. HEVC and ProRes keep ten bits; HDR never reaches H.264.
        XCTAssertNotNil(ParticipantRenderSession.depthWarning(deepSource: true, color: .sdr, codec: .h264))
        XCTAssertNotNil(ParticipantRenderSession.depthWarning(deepSource: true, color: .sdr, codec: .jpeg))
        XCTAssertNil(ParticipantRenderSession.depthWarning(deepSource: true, color: .sdr, codec: .hevc))
        XCTAssertNil(ParticipantRenderSession.depthWarning(deepSource: true, color: .sdr, codec: .prores))
        XCTAssertNil(ParticipantRenderSession.depthWarning(deepSource: false, color: .sdr, codec: .h264))

        // A rate the canvas cannot follow is named with the 30 fps it takes instead.
        let irregular = RationalTime(numerator: 273_001, denominator: 10_000)
        XCTAssertNil(ParticipantRenderer.canvasRate(irregular))
        let warning = ParticipantRenderer.irregularRateWarning("call.mp4", rate: irregular)
        XCTAssertTrue(warning.contains("call.mp4") && warning.contains("27.300") && warning.contains("30 fps"), warning)
        XCTAssertTrue(ParticipantRenderer.irregularRateWarning("call.mp4", rate: .zero).contains("could not be read"))
    }

    func testRenderReportKeepsPlannedAndWrittenWarningsApart() throws {
        let report = ParticipantRenderReport(
            canvas: .init(), duration: .init(numerator: 1), frameCount: 30, audio: .init(), audioActions: [], privacyIssues: [],
            publishable: true, staleSourceIDs: [], output: "/tmp/out.mov", warnings: ["planned"], writtenWarnings: ["written"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any])
        XCTAssertEqual(json["warnings"] as? [String], ["planned"])
        XCTAssertEqual(json["written_warnings"] as? [String], ["written"])
        XCTAssertEqual(report.allWarnings, ["planned", "written"])
        let decoded = try JSONDecoder().decode(ParticipantRenderReport.self, from: encoder.encode(report))
        XCTAssertEqual(decoded.allWarnings, ["planned", "written"])
    }

    func testISOMovieWarningsSurviveTheCheckpointAndReachTheReceipt() throws {
        // A checkpoint written before warnings existed still reads.
        let old = Data(#"{"filename":"ana.mov","sha256":"00","bytes":12}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TilesISOManifest.File.self, from: old).warnings)

        var file = try JSONDecoder().decode(TilesISOManifest.File.self, from: old)
        file.warnings = ["No hardware encoder session took constant quality, so the H.264 picture was encoded at an average of 8.7 Mbps instead."]
        let reread = try JSONDecoder().decode(TilesISOManifest.File.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(reread.warnings, file.warnings)

        let issues = TilesISODelivery.renderIssues([reread, try JSONDecoder().decode(TilesISOManifest.File.self, from: old)])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.code, "iso_render_warning")
        XCTAssertEqual(issues.first?.blocking, false)
        XCTAssertTrue(issues.first?.message.hasPrefix("ana.mov: No hardware encoder session") == true)
    }

    func testUnreadableMulticamEditingIsRebuiltWithAWarning() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        let camera = tests.appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let group = MulticamProject(referenceAngle: "a", range: range,
                                    // Group coverage is editing FCPXML has no field for, so the export writes MPCut's own.
                                    angles: [.init(id: "a", file: camera.path, name: "Wide", audioStream: 1, coverage: range)],
                                    audio: .follow, switches: [.init(at: .zero, angle: "a")])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Angles.fcpxml")
        _ = try ProjectConverter.write(.multicam(group), relativeTo: folder.appendingPathComponent("Source.cut"), to: output)
        XCTAssertFalse(try FCPInterchange.read(output).1.contains { $0.contains("rebuilt from its visible clips") })

        let document = try FCPInterchange.loadDocument(output)
        let fields = try document.nodes(forXPath: "//md[@key='\(FCPGroupMetadata.editing)']").compactMap { $0 as? XMLElement }
        let field = try XCTUnwrap(fields.first, "The export keeps MPCut's multicam editing.")
        field.attribute(forName: "value")?.stringValue = "{"
        try document.xmlData(options: .nodePrettyPrint).write(to: output)
        let (_, warnings) = try FCPInterchange.read(output)
        XCTAssertTrue(warnings.contains { $0.contains("rebuilt from its visible clips") }, "\(warnings)")
    }
}
