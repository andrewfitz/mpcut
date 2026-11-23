import Foundation
import XCTest
@testable import MPCutCore

final class FCPInterchangeTests: XCTestCase {
    func testDuplicateUsedStillAssetIDsFailWithoutPublishingXML() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("fcpxml")
        defer { try? FileManager.default.removeItem(at: output) }
        let cadence = RationalTime(numerator: 1, denominator: 24)
        let still = StillAsset(id: "card", file: "card.jpeg", displayName: "Card", fingerprint: "unused")
        let insert = StillInsert(id: "head", assetID: still.id, duration: cadence, cadence: cadence)
        let project = CutProject.stillSequence(.init(items: [.still(insert)], stillAssets: [still, still]))
        XCTAssertThrowsError(try ResolveExport.writeFCP(project, relativeTo: output, to: output,
                                                        package: nil, allowLoss: false)) {
            XCTAssertTrue($0.localizedDescription.contains("Invalid or repeated still asset"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testInlineStillRoundTripsWithOriginalImageAndExactTimelineGeometry() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        let camera = tests.appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let photo = tests.appendingPathComponent("Integration/fixtures/stills/patch.jpeg")
        let rate = try XCTUnwrap(CutEngine(useSidecar: false).inspectSummary(camera).videoStream?.frameRate)
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        let duration = try cadence.multiplied(by: .init(numerator: 12))
        let image = StillAsset(id: "card-source", file: photo.path, displayName: "Card",
                               fingerprint: try StillImage.fingerprint(photo))
        let first = StillInsert(id: "head", assetID: image.id, duration: duration, cadence: cadence)
        let second = StillInsert(id: "tail", assetID: image.id, duration: duration, cadence: cadence, framing: .fill)
        let clip = CutSequenceClip(id: "keep", file: camera.path, from: .zero, to: duration)
        let project = CutProject.stillSequence(.init(items: [.still(first), .source(clip), .still(second)], stillAssets: [image]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("Source.cut")
        for ext in ["fcpxml", "fcpxmld"] {
            let output = folder.appendingPathComponent("Edit." + ext)
            XCTAssertEqual(try ProjectConverter.write(project, relativeTo: input, to: output), [])
            let (reopened, warnings) = try FCPInterchange.read(output)
            XCTAssertEqual(reopened, project)
            XCTAssertEqual(warnings, [])
            let xml = ext == "fcpxml" ? output : output.appendingPathComponent("Info.fcpxml")
            let document = try FCPInterchange.loadDocument(xml)
            let storyline = try XCTUnwrap(document.nodes(forXPath: "//sequence/spine").first as? XMLElement)
            let nodes = storyline.children?.compactMap { $0 as? XMLElement } ?? []
            XCTAssertEqual(nodes.map(\.name), ["video", "asset-clip", "video"])
            XCTAssertEqual(nodes.map { $0.attribute(forName: "offset")?.stringValue },
                           ["0s", "\(duration)s", "\(try duration.adding(duration))s"])
            XCTAssertEqual(nodes.map { $0.attribute(forName: "duration")?.stringValue }, Array(repeating: "\(duration)s", count: 3))
        }
        let canvas = StillTimelineFormat(width: 1920, height: 1080, cadence: cadence, codec: .prores, container: "mov")
        let standalone = CutProject.stillSequence(.init(items: [.still(first)], stillAssets: [image], stillFormat: canvas))
        let output = folder.appendingPathComponent("Standalone.fcpxml")
        XCTAssertEqual(try FCPInterchange.write(standalone, relativeTo: input, to: output), [])
        XCTAssertEqual(try FCPInterchange.read(output).0, standalone)
    }

    func testMulticamStillKeepsRepeatedAssemblyRangesAndTheGapInProgramSound() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        let camera = tests.appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let photo = tests.appendingPathComponent("Integration/fixtures/stills/patch.jpeg")
        let rate = try XCTUnwrap(CutEngine(useSidecar: false).inspectSummary(camera).videoStream?.frameRate)
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let image = StillAsset(id: "card-source", file: photo.path, displayName: "Card",
                               fingerprint: try StillImage.fingerprint(photo))
        let card = StillInsert(id: "between", assetID: image.id, duration: range.to, cadence: cadence)
        let group = MulticamProject(referenceAngle: "a", range: range,
                                    angles: [.init(id: "a", file: camera.path, name: "Wide", audioStream: 1)],
                                    audio: .follow, switches: [.init(at: .zero, angle: "a")],
                                    assemblyItems: [.group(range), .still(card), .group(range)], stillAssets: [image])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Angles.fcpxml")
        let input = folder.appendingPathComponent("Source.cut")
        XCTAssertEqual(try ProjectConverter.write(.multicam(group), relativeTo: input, to: output), [])
        let (project, warnings) = try FCPInterchange.read(output)
        guard case .multicam(let reopened) = project else { return XCTFail("Expected multicam") }
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(reopened.assemblyItems, group.assemblyItems)
        XCTAssertEqual(reopened.stillAssets, [image])
        let plan = try reopened.plan()
        XCTAssertEqual(plan.duration, .init(numerator: 3))
        XCTAssertEqual(plan.audio.map(\.output), [range, .init(from: .init(numerator: 2), to: .init(numerator: 3))])
    }

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
        <metadata><md key="com.mpcut.sequence_clip.v2"
            value='{&quot;clip_id&quot;:&quot;clip-1&quot;,&quot;track_ordinal&quot;:1,&quot;original_file&quot;:&quot;/raw.mov&quot;,&quot;replacement_names&quot;:{&quot;1&quot;:&quot;Boom&quot;}}'/></metadata>
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

    func testSplitCameraAndReplayOverrideRoundTripWithOriginalAudioAndARecordingGap() throws {
        let developmentHelper = "/opt/homebrew/bin/ffmpeg"
        let configureHelper = ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil
            && FileManager.default.isExecutableFile(atPath: developmentHelper)
        if configureHelper { setenv("MPCUT_FFMPEG_HELPER", developmentHelper, 0) }
        defer { if configureHelper { unsetenv("MPCUT_FFMPEG_HELPER") } }
        try XCTSkipUnless((try? ReencodeEngine.findHelper(override: nil)) != nil, "Requires an FFmpeg helper")

        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        let fixture = tests.appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let photo = tests.appendingPathComponent("Integration/fixtures/stills/patch.jpeg")
        let info = try CutEngine(useSidecar: false).inspectSummary(fixture)
        let stream = try XCTUnwrap(info.streams.first(where: { $0.kind == "audio" })).index
        let rate = try XCTUnwrap(info.videoStream?.frameRate)
        let frame = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        let two = try frame.adding(frame)
        let three = try two.adding(frame)
        let range = MulticamRange(from: .zero, to: three)
        let first = MulticamRange(from: .zero, to: frame)
        let second = MulticamRange(from: two, to: three)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let restart = folder.appendingPathComponent("restart.mov")
        try FileManager.default.copyItem(at: fixture, to: restart)
        let camera = MulticamSource(id: "wide", file: fixture.path, name: "Wide", audioStream: stream,
                                   coverage: first, additionalRecordings: [
                                    .init(id: "restart", file: restart.path, offset: two, audioStream: stream, coverage: second)
                                   ])
        let close = MulticamSource(id: "close", file: fixture.path)
        let image = StillAsset(id: "card-source", file: photo.path, displayName: "Card",
                               fingerprint: try StillImage.fingerprint(photo))
        let insert = StillInsert(id: "replay-card", assetID: image.id, duration: frame, cadence: frame)
        let group = MulticamProject(referenceAngle: camera.id, range: range, angles: [camera, close], audio: .follow,
                                    switches: [.init(at: .zero, angle: camera.id)],
                                    assemblyItems: [.group(range), .still(insert), .group(first, angle: close.id)],
                                    stillAssets: [image])
        let input = folder.appendingPathComponent("Source.cut")
        for ext in ["fcpxml", "fcpxmld"] {
            let output = folder.appendingPathComponent("Edit." + ext)
            XCTAssertEqual(try ProjectConverter.write(.multicam(group), relativeTo: input, to: output), [])
            let (reopened, warnings) = try FCPInterchange.read(output)
            guard case .multicam(let restored) = reopened else { return XCTFail("Expected multicam") }
            XCTAssertEqual(warnings, [])
            XCTAssertEqual(restored.referenceAngle, group.referenceAngle)
            XCTAssertEqual(restored.range, group.range)
            XCTAssertEqual(restored.angles, group.angles)
            XCTAssertEqual(restored.audioSources, [])
            XCTAssertEqual(restored.audio, group.audio)
            XCTAssertEqual(restored.switches, group.switches)
            XCTAssertEqual(restored.assemblyItems, group.assemblyItems)
            XCTAssertEqual(restored.stillAssets, group.stillAssets)
            let plan = try restored.plan()
            XCTAssertEqual(plan.intervals.map(\.pictureSourceID), [camera.id, nil, "restart", close.id])
            XCTAssertEqual(plan.intervals.map { $0.audio?.source }, [camera.id, nil, "restart", camera.id])

            let xml = ext == "fcpxml" ? output : output.appendingPathComponent("Info.fcpxml")
            let document = try FCPInterchange.loadDocument(xml)
            let nodes = try document.nodes(forXPath: "//mc-angle[@angleID='wide']/*")
            XCTAssertEqual(nodes.map(\.name), ["asset-clip", "gap", "asset-clip"])

            let helperID = try XCTUnwrap((document.nodes(forXPath: "(//sequence/spine/mc-clip)[1]/mc-source[@srcEnable='audio']")
                .first as? XMLElement)?.attribute(forName: "angleID")?.stringValue)
            let helper = try XCTUnwrap(document.nodes(forXPath: "//mc-angle[@angleID='\(helperID)']/asset-clip")
                .first as? XMLElement)
            let helperRef = try XCTUnwrap(helper.attribute(forName: "ref"))
            let originalRef = helperRef.stringValue
            helperRef.stringValue = (nodes.last as? XMLElement)?.attribute(forName: "ref")?.stringValue
            try document.xmlData.write(to: xml)
            guard case .multicam(let relinked) = try FCPInterchange.read(output).0 else { return XCTFail("Expected multicam") }
            let relinkedAudio = try XCTUnwrap(relinked.plan().audio.first?.source)
            XCTAssertEqual(relinked.audioSources.first { $0.id == relinkedAudio }?.file, restart.path)
            helperRef.stringValue = originalRef

            let replay = try XCTUnwrap(document.nodes(forXPath: "(//sequence/spine/mc-clip)[last()]/mc-source[@srcEnable='video']")
                .first as? XMLElement)
            replay.attribute(forName: "angleID")?.stringValue = camera.id
            try document.xmlData.write(to: xml)
            guard case .multicam(let edited) = try FCPInterchange.read(output).0 else { return XCTFail("Expected multicam") }
            XCTAssertEqual(try edited.plan().intervals.last?.angle, camera.id)
        }
    }

    func testAllStillAssemblyRestoresItsGroupOnlyWhenEditingMetadataMatches() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        let camera = tests.appendingPathComponent("MPCutAppTests/Fixtures/Shuttle-Chirp.mov")
        let photo = tests.appendingPathComponent("Integration/fixtures/stills/patch.jpeg")
        let rate = try XCTUnwrap(CutEngine(useSidecar: false).inspectSummary(camera).videoStream?.frameRate)
        let frame = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        let range = MulticamRange(from: .zero, to: frame)
        let image = StillAsset(id: "card-source", file: photo.path, displayName: "Card",
                               fingerprint: try StillImage.fingerprint(photo))
        let card = StillInsert(id: "card", assetID: image.id, duration: frame, cadence: frame)
        let group = MulticamProject(referenceAngle: "wide", range: range,
                                    angles: [.init(id: "wide", file: camera.path)],
                                    audio: .none, switches: [.init(at: .zero, angle: "wide")],
                                    assemblyItems: [.still(card)], stillAssets: [image])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Card.fcpxml")
        XCTAssertEqual(try ProjectConverter.write(.multicam(group), relativeTo: folder.appendingPathComponent("Source.cut"),
                                                 to: output), [])
        XCTAssertEqual(try FCPInterchange.read(output).0, .multicam(group))

        let document = try FCPInterchange.loadDocument(output)
        let unrelatedMetadata = try XCTUnwrap(document.nodes(forXPath: "//multicam/metadata/md[@key='\(FCPGroupMetadata.editing)']").first)
        unrelatedMetadata.detach()
        try document.xmlData.write(to: output)
        guard case .stillSequence(let standalone) = try FCPInterchange.read(output).0 else {
            return XCTFail("Expected the still sequence to ignore an unrelated multicam resource")
        }
        XCTAssertEqual(standalone.items, [.still(card)])
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
