import Foundation
import XCTest
@testable import MPCutCore

final class FCPInterchangeTests: XCTestCase {
    private func read(_ story: String, allowLoss: Bool = false) throws -> (CutProject, [String]) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).fcpxml")
        defer { try? FileManager.default.removeItem(at: file) }
        let xml = """
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11"><resources><asset id="a" start="3600s" duration="8s" hasVideo="1">
        <media-rep src="file:///recordings/Wide%20Angle.mov"/></asset></resources>
        <project><sequence><spine>\(story)</spine></sequence></project></fcpxml>
        """
        try Data(xml.utf8).write(to: file)
        return try FCPInterchange.read(file, allowLoss: allowLoss)
    }

    func testRepeatedRangesAndSourceTimecode() throws {
        let (result, warnings) = try read("""
        <asset-clip ref="a" start="3603s" duration="1s"/>
        <asset-clip ref="a" start="3600s" offset="1s" duration="1001/24000s"/>
        <asset-clip ref="a" start="3603s" duration="1s"/>
        """)
        XCTAssertTrue(warnings.isEmpty)
        guard case .sequence(let clips) = result else { return XCTFail("Expected ordinary timeline") }
        XCTAssertEqual(clips.map(\.from), [RationalTime(numerator: 3), .zero, RationalTime(numerator: 3)])
        XCTAssertEqual(clips[1].to, RationalTime(numerator: 1001, denominator: 24000))
        XCTAssertEqual(clips[0].file, "/recordings/Wide Angle.mov")
    }

    func testGapsAndRetimingNeedExplicitLoss() throws {
        let story = """
        <gap duration="1s"/><asset-clip ref="a" start="3600s" duration="1s"><timeMap/></asset-clip>
        """
        XCTAssertThrowsError(try read(story))
        XCTAssertEqual(try read(story, allowLoss: true).1.count, 2)
    }

    func testRejectsMissingAssetEvenWithLoss() {
        XCTAssertThrowsError(try read("<asset-clip ref=\"missing\" duration=\"1s\"/>", allowLoss: true))
    }

    func testSplitClipGetsDistinctIDAndRetainsReplacementMetadata() throws {
        let metadata = """
        <metadata><md key="com.mpcut.clip.v1"
            value='{&quot;id&quot;:&quot;clip-1&quot;,&quot;audioTrack&quot;:1,&quot;originalFile&quot;:&quot;/raw.mov&quot;,&quot;replacementNames&quot;:{&quot;1&quot;:&quot;Boom&quot;}}'/></metadata>
        """
        let (project, warnings) = try read("""
        <asset-clip ref="a" start="3600s" duration="1s"/>
        <asset-clip ref="a" start="3602s" duration="1s">\(metadata)</asset-clip>
        <asset-clip ref="a" start="3603s" duration="1s">\(metadata)</asset-clip>
        """)
        guard case .sequence(let clips) = project else { return XCTFail("Expected ordinary timeline") }
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(clips.map(\.id), ["clip-2", "clip-1", "clip-3"])
        XCTAssertEqual(clips[2].audioTrack, 1)
        XCTAssertEqual(clips[2].replacementNames, [1: "Boom"])
        XCTAssertEqual(clips[2].originalFile, "/raw.mov")
    }

    func testConcurrentSoundLanesRequireLossPermission() throws {
        let story = """
        <gap start="3600s" duration="2s">
          <asset-clip ref="a" lane="1" start="3604s" offset="3600s" duration="2s"/>
          <asset-clip ref="a" lane="2" start="3601s" offset="3600s" duration="2s"/>
        </gap>
        """
        XCTAssertThrowsError(try read(story))
        let (project, warnings) = try read(story, allowLoss: true)
        XCTAssertTrue(warnings.contains { $0.contains("overlapping clip on lane 2") })
        guard case .sequence(let clips) = project else { return XCTFail("Expected connected lane") }
        XCTAssertEqual(clips.map(\.from), [.init(numerator: 4)])
    }

    func testNonoverlappingConnectedClipsOnDifferentLanesTransferInRecordOrder() throws {
        let (project, warnings) = try read("""
        <gap start="3600s" duration="2s">
          <asset-clip ref="a" lane="1" start="3604s" offset="3601s" duration="1s"/>
          <asset-clip ref="a" lane="2" start="3601s" offset="3600s" duration="1s"/>
        </gap>
        """)
        guard case .sequence(let clips) = project else { return XCTFail("Expected ordered clips") }
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(clips.map(\.from), [.init(numerator: 1), .init(numerator: 4)])
    }

    func testWrapperReportsPartialPictureAndRestoredVideoOnAudioOnlyMovie() throws {
        let short = """
        <clip start="3600s" duration="2s"><video ref="a" offset="3600s" start="3600s" duration="1s"/></clip>
        """
        XCTAssertThrowsError(try read(short))
        XCTAssertTrue(try read(short, allowLoss: true).1.contains { $0.contains("partial primary") })
        let soundOnly = """
        <clip start="3600s" duration="2s"><audio ref="a" offset="3600s" start="3600s" duration="2s"/></clip>
        """
        XCTAssertThrowsError(try read(soundOnly))
    }

    func testUnresolvedPathCannotSilentlySelectDifferentMovie() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xml = folder.appendingPathComponent("Source.fcpxml")
        try Data("""
        <fcpxml version="1.10"><resources><asset id="a"><media-rep src="nonexistent/../recording.mov"/></asset></resources>
        <project><sequence><spine><asset-clip ref="a" duration="1s"/></spine></sequence></project></fcpxml>
        """.utf8).write(to: xml)
        XCTAssertThrowsError(try FCPInterchange.read(xml, allowLoss: true))
    }

    func testMediaRelativeToSymlinkedXMLUsesOriginalDocumentFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = folder.appendingPathComponent("original")
        let links = folder.appendingPathComponent("links")
        defer { try? FileManager.default.removeItem(at: folder) }
        for directory in [original, links] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("Recording.mov"))
        }
        let document = original.appendingPathComponent("Edit.fcpxml")
        try Data("""
        <fcpxml version="1.10"><resources><asset id="a"><media-rep src="Recording.mov"/></asset></resources>
        <project><sequence><spine><asset-clip ref="a" duration="1s"/></spine></sequence></project></fcpxml>
        """.utf8).write(to: document)
        let link = links.appendingPathComponent("Edit.fcpxml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: document)
        guard case .sequence(let clips) = try FCPInterchange.read(link).0 else { return XCTFail("Expected sequence") }
        XCTAssertEqual(URL(fileURLWithPath: clips[0].file).resolvingSymlinksInPath(),
                       original.appendingPathComponent("Recording.mov").resolvingSymlinksInPath())
    }

    func testNegativeOffsetAndSilentFollowCameraPreserveGroupClock() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let group = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: .init(numerator: 1)),
                                    angles: [.init(id: "a", file: fixture.path, name: "Wide", audioStream: 1),
                                             .init(id: "b", file: fixture.path, offset: .init(numerator: -1), name: "Close")],
                                    audio: .follow, switches: [.init(at: .zero, angle: "b")])
        let xml = folder.appendingPathComponent("Angles.fcpxml")
        XCTAssertEqual(try FCPInterchange.write(.multicam(group), relativeTo: folder.appendingPathComponent("Source.cut"), to: xml), [])
        let (result, warnings) = try FCPInterchange.read(xml)
        guard case .multicam(let restored) = result else { return XCTFail("Expected multicam") }
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(restored.range, group.range)
        XCTAssertEqual(restored.angles.map(\.offset), group.angles.map(\.offset))
        XCTAssertEqual(restored.angles.map(\.audioStream), [1, nil])
        XCTAssertEqual(restored.audio, .follow)
        XCTAssertEqual(try restored.plan().audio.count, 0)
    }

    func testIllegalXMLDisplayNameRequiresLossBeforeWritingReadableXML() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let group = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: .init(numerator: 1)),
                                    angles: [.init(id: "a", file: fixture.path, name: "Camera\u{1}Name")],
                                    audio: .none, switches: [.init(at: .zero, angle: "a")])
        let xml = folder.appendingPathComponent("Edit.fcpxml")
        let input = folder.appendingPathComponent("Source.cut")
        XCTAssertThrowsError(try FCPInterchange.write(.multicam(group), relativeTo: input, to: xml))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xml.path))
        XCTAssertFalse(try FCPInterchange.write(.multicam(group), relativeTo: input, to: xml, allowLoss: true).isEmpty)
        guard case .multicam(let restored) = try FCPInterchange.read(xml).0 else { return XCTFail("Expected multicam") }
        XCTAssertEqual(restored.angles[0].name, "Camera\u{FFFD}Name")
    }

    func testCancellingFinalCutInteractionStopsOnlyTheHelper() throws {
        let start = ContinuousClock.now
        XCTAssertThrowsError(try FCPLibraryInterchange.run("/usr/bin/osascript", ["-e", "delay 30"],
                                                           cancelled: { ContinuousClock.now - start > .milliseconds(100) })) {
            XCTAssertEqual(($0 as? CutError)?.code, "cancelled")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testPackageMulticamRoundTrip() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let info = try CutEngine(useSidecar: false).inspectSummary(fixture)
        let audio = try XCTUnwrap(info.streams.first(where: { $0.kind == "audio" }))
        let frameRate = try XCTUnwrap(info.videoStream?.frameRate)
        let frame = RationalTime(numerator: frameRate.denominator, denominator: frameRate.numerator)
        let two = try frame.adding(frame)
        let three = try frame.adding(two)
        let group = MulticamProject(referenceAngle: "a", range: .init(from: .zero, to: three),
                                    angles: ["a", "b"].map { .init(id: $0, file: fixture.path, name: $0) },
                                    audio: .fixed(.init(source: "b", stream: audio.index)),
                                    switches: [.init(at: .zero, angle: "a"), .init(at: two, angle: "b")],
                                    assembly: [.init(from: two, to: three), .init(from: .zero, to: two)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Angles.fcpxmld")
        XCTAssertEqual(try FCPInterchange.write(.multicam(group), relativeTo: folder.appendingPathComponent("Source.cut"), to: output), [])
        let (result, warnings) = try FCPInterchange.read(output)
        XCTAssertTrue(warnings.isEmpty)
        guard case .multicam(let restored) = result else { return XCTFail("Expected multicam") }
        let plan = try restored.plan()
        XCTAssertEqual(plan.intervals.map(\.group), group.assembly)
        XCTAssertEqual(plan.intervals.map { interval in restored.angles.first { $0.id == interval.angle }?.name }, ["b", "a"])
        XCTAssertTrue(plan.intervals.allSatisfy { $0.audio?.source == restored.angles[1].id })
    }
}
