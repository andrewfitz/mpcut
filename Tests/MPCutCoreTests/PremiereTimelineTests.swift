import Foundation
import XCTest
@testable import MPCutCore

final class PremiereTimelineTests: XCTestCase {
    func testStereoReorderedSequenceXMLRoundTrip() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = folder.appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov").standardizedFileURL.path
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let project = CutProject.sequence([
            .init(id: "clip-1", file: file, from: .init(numerator: 1), to: .init(numerator: 2)),
            .init(id: "clip-2", file: file, from: .zero, to: .init(numerator: 1))
        ])
        let xml = stage.appendingPathComponent("sequence.xml")
        XCTAssertEqual(try PremiereTimeline.write(project, relativeTo: stage.appendingPathComponent("test.cut"),
                                                  to: xml, name: "Sequence", allowLoss: false), [])
        let document = try XMLDocument(contentsOf: xml, options: [])
        let links = try document.nodes(forXPath: "/xmeml/sequence/media/video/track/clipitem[2]/link/clipindex")
        XCTAssertEqual(links.compactMap(\.stringValue), ["2", "2", "2"])
        XCTAssertEqual(try PremiereTimeline.read(xml, allowLoss: false).0, project)
    }

    func testNativeInputRequiresExplicitLossPermission() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("prproj")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PremiereInterchange.read(url, allowLoss: false)) {
            XCTAssertEqual(($0 as? CutError)?.code, "conversion_loss")
        }
    }

    func testNativeOrFlattenedCameraGroupKeepsExplicitSelection() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures")
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let one = RationalTime(numerator: 1), two = RationalTime(numerator: 2)
        let group = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: two),
                                    angles: [.init(id: "a", file: fixtures.appendingPathComponent("Pause-Quiet.mov").path),
                                             .init(id: "b", file: fixtures.appendingPathComponent("Pause-Noisy.mov").path)],
                                    audio: .fixed(.init(source: "a", stream: 2)),
                                    switches: [.init(at: .zero, angle: "a"), .init(at: one, angle: "b")],
                                    assembly: [.init(from: one, to: two), .init(from: .zero, to: one)])
        let location = stage.appendingPathComponent("source.cut")
        let native = stage.appendingPathComponent("native.xml"), flat = stage.appendingPathComponent("flat.xml")
        _ = try PremiereTimeline.write(.multicam(group), relativeTo: location, to: native, name: "Native", allowLoss: false)
        XCTAssertEqual(try PremiereTimeline.nativeAngles(in: native), [2, 1])
        _ = try PremiereTimeline.write(.multicam(group), relativeTo: location, to: flat, name: "Flat",
                                       allowLoss: true, flattenMulticam: true)
        XCTAssertEqual(try PremiereTimeline.nativeAngles(in: flat), [])
        guard case .multicam(let imported) = try PremiereTimeline.read(flat, allowLoss: true).0 else {
            return XCTFail("Expected independent camera and microphone tracks")
        }
        let plan = try imported.plan()
        XCTAssertEqual(plan.picture.map(\.input.from), [one, .zero])
        XCTAssertEqual(plan.audio.map(\.stream), [2, 2])
    }

    private func withStereoEdit(_ body: (URL, XMLDocument) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let clips = [CutSequenceClip(id: "clip-1", file: file.path, from: .zero, to: .init(numerator: 1)),
                     CutSequenceClip(id: "clip-2", file: file.path, from: .init(numerator: 1), to: .init(numerator: 2))]
        let xml = folder.appendingPathComponent("Edit.xml")
        _ = try PremiereTimeline.write(.sequence(clips), relativeTo: folder.appendingPathComponent("Edit.cut"),
                                       to: xml, name: "Edit", allowLoss: false)
        try body(xml, XMLDocument(contentsOf: xml, options: []))
    }

    func testChannelOrderLossIsReported() throws {
        try withStereoEdit { xml, doc in
            let audio = try XCTUnwrap(doc.nodes(forXPath: "/xmeml/sequence/media/audio").first as? XMLElement)
            let tracks = audio.elements(forName: "track")
            XCTAssertEqual(tracks.count, 2)
            let second = try XCTUnwrap(tracks.last)
            second.detach()
            audio.insertChild(second, at: 0)
            try doc.xmlData.write(to: xml)
            XCTAssertThrowsError(try PremiereTimeline.read(xml, allowLoss: false))
            let (project, warnings) = try PremiereTimeline.read(xml, allowLoss: true)
            guard case .sequence(let clips) = project else { return XCTFail("Expected sequence") }
            XCTAssertEqual(clips.count, 2)
            XCTAssertTrue(warnings.contains { $0.contains("channel order") })
        }
    }

    func testDisjointPictureTracksCanShareOneTimeline() throws {
        try withStereoEdit { xml, doc in
            let video = try XCTUnwrap(doc.nodes(forXPath: "/xmeml/sequence/media/video").first as? XMLElement)
            let clip = try XCTUnwrap(video.elements(forName: "track").first?.elements(forName: "clipitem").last)
            clip.detach()
            let track = XMLElement(name: "track")
            track.addChild(clip)
            video.addChild(track)
            try doc.xmlData.write(to: xml)
            XCTAssertThrowsError(try PremiereTimeline.read(xml, allowLoss: false))
            let (project, warnings) = try PremiereTimeline.read(xml, allowLoss: true)
            guard case .sequence(let clips) = project else { return XCTFail("Expected sequence") }
            XCTAssertEqual(clips.map(\.from), [.zero, .init(numerator: 1)])
            XCTAssertTrue(warnings.contains { $0.contains("picture tracks") })
        }
    }

    func testOutOfMediaTrimIsRejected() throws {
        try withStereoEdit { xml, doc in
            for case let item as XMLElement in try doc.nodes(forXPath: "//clipitem") {
                for key in ["in", "out"] {
                    let field = try XCTUnwrap(item.elements(forName: key).first)
                    field.stringValue = String(100000 + (Int(field.stringValue ?? "") ?? 0))
                }
            }
            try doc.xmlData.write(to: xml)
            XCTAssertThrowsError(try PremiereTimeline.read(xml, allowLoss: true))
        }
    }

    func testAdjacentAssemblyRangesRemainDistinct() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = RationalTime(numerator: 1), two = RationalTime(numerator: 2)
        let group = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: two),
                                    angles: [.init(id: "a", file: fixtures.appendingPathComponent("Pause-Quiet.mov").path),
                                             .init(id: "b", file: fixtures.appendingPathComponent("Pause-Noisy.mov").path)],
                                    audio: .fixed(.init(source: "a", stream: 2)), switches: [.init(at: .zero, angle: "a")],
                                    assembly: [.init(from: .zero, to: one), .init(from: one, to: two)])
        let xml = folder.appendingPathComponent("Cuts.xml")
        _ = try PremiereTimeline.write(.multicam(group), relativeTo: folder.appendingPathComponent("Cuts.cut"),
                                       to: xml, name: "Cuts", allowLoss: false)
        XCTAssertEqual(try PremiereTimeline.nativeAngles(in: xml), [1, 1])
        XCTAssertEqual(try XMLDocument(contentsOf: xml, options: []).nodes(forXPath: "//sequence/media/audio/track/clipitem").count, 2)
    }

    func testMixedFrameRateTrimsUseTheSequenceClock() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures").standardizedFileURL
        let xml = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).xml")
        defer { try? FileManager.default.removeItem(at: xml) }
        let one = RationalTime(numerator: 1), two = RationalTime(numerator: 2)
        let project = CutProject.sequence([
            .init(id: "clip-1", file: fixtures.appendingPathComponent("Pause-Quiet.mov").path, from: .zero, to: one),
            .init(id: "clip-2", file: fixtures.appendingPathComponent("Shuttle-Chirp.mov").path, from: one, to: two)
        ])
        XCTAssertTrue(try PremiereTimeline.write(project, relativeTo: xml, to: xml, name: "Mixed", allowLoss: false).isEmpty)
        let doc = try XMLDocument(contentsOf: xml, options: [])
        let second = try XCTUnwrap(doc.nodes(forXPath: "/xmeml/sequence/media/video/track/clipitem[2]").first)
        XCTAssertEqual(try second.nodes(forXPath: "./in").first?.stringValue, "10")
        XCTAssertEqual(try second.nodes(forXPath: "./out").first?.stringValue, "20")
        XCTAssertEqual(try second.nodes(forXPath: "./rate/timebase").first?.stringValue, "10")
        XCTAssertEqual(try second.nodes(forXPath: "./file/rate/timebase").first?.stringValue, "25")
        XCTAssertEqual(try PremiereTimeline.read(xml, allowLoss: false).0, project)
    }

    func testReversePlaybackRejectsEqualSourceAndRecordDurations() throws {
        try withStereoEdit { xml, doc in
            let item = try XCTUnwrap(doc.nodes(forXPath: "//video/track/clipitem").first as? XMLElement)
            let filter = try XMLElement(xmlString: "<filter><effect><effectid>timeremap</effectid></effect></filter>")
            item.addChild(filter)
            try doc.xmlData.write(to: xml)
            XCTAssertThrowsError(try PremiereTimeline.read(xml, allowLoss: true))
        }
    }
}
