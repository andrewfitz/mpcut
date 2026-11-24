import Foundation
import ImageIO
import MPCutCore
import XCTest
@testable import MPCutApp

@MainActor
final class MCPReviewFrameTests: XCTestCase {
    func testRepeatedOccurrenceProducesDecodableReviewWithoutEditing() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        session.editor.importFiles([fixture, fixture])
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while session.editor.isBusy {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = session.editor
        let revision = editor.mcpRevision, cursor = editor.historyCursor, playhead = editor.playhead
        let time = try XCTUnwrap(editor.mcpSequenceOffsets.last)
        let request: [String: Any] = ["space": "sequence", "time": time.description]
        let result = try await registry.mcpReviewFrame(arguments: request, session: session, checkAccess: {})
        XCTAssertEqual(result["occurrence"] as? String, editor.mcpClipIDs.last?.uuidString)
        XCTAssertEqual(result["source_time"] as? String, editor.sequenceClips.last?.from.description)
        let encoded = try XCTUnwrap(result["jpeg"] as? String)
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertLessThanOrEqual(bytes.count, 1_048_576)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, result["width"] as? Int)
        XCTAssertEqual(image.height, result["height"] as? Int)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 640)
        XCTAssertEqual(editor.mcpRevision, revision)
        XCTAssertEqual(editor.historyCursor, cursor)
        XCTAssertEqual(editor.playhead, playhead)

        var accessChecks = 0
        do {
            _ = try await registry.mcpReviewFrame(arguments: request, session: session) {
                accessChecks += 1
                if accessChecks > 1 { throw MCPCommandError("control_disabled", "Disabled during rendering.") }
            }
            XCTFail("A revoked request must not return a picture.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "control_disabled")
        }
    }

    func testRepeatedMulticamAssemblyMapsToGroupAndCamera() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let model = session.multicam
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let draft = MulticamEditorModel.SourceDraft(source: .init(id: "wide", file: fixture.path), media: media)
        model.confirmSetup(drafts: [draft], opening: "wide", audio: .none)
        let range = try XCTUnwrap(model.project?.range)
        XCTAssertTrue(model.edit("Repeat") { $0.assembly = [range, range] })
        let secondFrame = try XCTUnwrap(media.frames.dropFirst().first?.time)
        let assemblyTime = try range.to.adding(secondFrame)
        let result = try await registry.mcpReviewFrame(arguments: [
            "time": assemblyTime.description, "space": "assembly", "angle_id": "wide"
        ], session: session, checkAccess: {})
        XCTAssertEqual(result["source_time"] as? String, secondFrame.description)
        XCTAssertEqual(result["time"] as? String, assemblyTime.description)
        XCTAssertEqual(result["group_time"] as? String, secondFrame.description)
        XCTAssertEqual(result["angle_id"] as? String, "wide")
        XCTAssertEqual(result["source_id"] as? String, "wide")
        XCTAssertEqual(result["occurrence"] as? String, "1")
    }

    func testTileReviewSeparatesOutputAndExplicitSourceAndReportsFrameDuration() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let model = session.multicam
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: fixture.path), media: media)],
                           opening: "wide", audio: .none)
        let end = RationalTime(numerator: 7, denominator: 60)
        XCTAssertTrue(model.edit("Set Output Canvas") { project in
            project.assembly = [.init(from: .zero, to: end)]
            project.participants.tileOutput = .init(canvas: .init(width: 192, height: 108), audio: .init(mode: .silence))
        })

        let output = try await registry.mcpReviewFrame(arguments: ["space": "assembly", "time": end.description],
                                                       session: session, checkAccess: {})
        XCTAssertEqual(output["view"] as? String, "output")
        XCTAssertEqual(output["duration"] as? String, "1/60")
        XCTAssertEqual(output["frame_time"] as? String, "1/10")
        XCTAssertEqual(output["width"] as? Int, 192)
        XCTAssertNil(output["source_id"])

        let explicit = try await registry.mcpReviewFrame(arguments: ["space": "group", "time": "0", "view": "source"],
                                                         session: session, checkAccess: {})
        XCTAssertEqual(explicit["view"] as? String, "source")
        XCTAssertEqual(explicit["source_id"] as? String, "wide")
        XCTAssertNotEqual(explicit["width"] as? Int, output["width"] as? Int)
        let named = try await registry.mcpReviewFrame(arguments: ["space": "group", "time": "0", "angle_id": "wide"],
                                                      session: session, checkAccess: {})
        XCTAssertEqual(named["view"] as? String, "source")
        XCTAssertEqual(named["jpeg"] as? String, explicit["jpeg"] as? String)
        do {
            _ = try await registry.mcpReviewFrame(arguments: ["view": "output", "angle_id": "wide"],
                                                  session: session, checkAccess: {})
            XCTFail("Output with a named camera must not return untreated pixels.")
        } catch let issue as MCPCommandError {
            XCTAssertEqual(issue.code, "invalid_arguments")
        }

        let interval = MulticamRange(from: .zero, to: end)
        XCTAssertTrue(model.edit("Set Occurrence Layout") { project in
            project.participants.tileOutput = nil
            project.assemblyItems = [.group(interval, id: "only-occurrence", layouts: [
                .init(range: interval, layout: .original),
            ])]
        })
        let group = try await registry.mcpReviewFrame(arguments: ["space": "group", "time": "0", "view": "output"],
                                                      session: session, checkAccess: {})
        XCTAssertEqual(group["view"] as? String, "output")
        XCTAssertEqual(group["width"] as? Int, explicit["width"] as? Int)
    }

    func testProcessedFrameExportUsesActiveClockForPlayheadSamples() throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let model = session.multicam
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: fixture.path), media: media)],
                           opening: "wide", audio: .none)
        XCTAssertTrue(model.edit("Set Output Canvas") { project in
            project.assembly = [.init(from: .zero, to: .init(numerator: 7, denominator: 60))]
            project.participants.tileOutput = .init(canvas: .init(width: 192, height: 108), audio: .init(mode: .silence))
        })
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        func request(_ mode: String, space: String, times: [RationalTime] = []) throws -> MCPLiveOutputJobs.Work? {
            try registry.mcpProgramFrameExport(session: session, output: output, args: ["space": space],
                                               mode: mode, times: times, preset: .review)
        }
        for (active, inactive) in [("group", "assembly"), ("assembly", "group")] {
            model.setAssemblyPreview(active == "assembly")
            XCTAssertEqual(model.assemblyPreview, active == "assembly")
            for mode in ["still", "playhead"] {
                XCTAssertThrowsError(try request(mode, space: inactive)) { error in
                    XCTAssertEqual((error as? MCPCommandError)?.code, "invalid_target")
                }
                XCTAssertNotNil(try request(mode, space: active))
            }
            XCTAssertNotNil(try request("times", space: inactive, times: [.zero]))
            XCTAssertNotNil(try request("switches", space: "group"))
        }
    }

    func testReviewFrameIdentifiesRecordingAndLogicalAngle() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let model = session.multicam
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: fixture.path), media: media)],
                           opening: "wide", audio: .none)
        let end = try XCTUnwrap(media.frames.last)
        let start = try end.time.adding(end.duration)
        let recording = try await model.addRecording(to: "wide", from: fixture, at: start)
        for clock in ["group", "assembly"] {
            let result = try await registry.mcpReviewFrame(arguments: ["time": start.description, "space": clock],
                                                           session: session, checkAccess: {})
            XCTAssertEqual(result["angle_id"] as? String, "wide")
            XCTAssertEqual(result["source_id"] as? String, recording)
        }
    }

    func testProgramReviewSelectsAnUnsavedInsertAndRetainedCamera() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        session.editor.importFiles([fixture])
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while session.editor.isBusy {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
        let (asset, directory) = try makeArtwork()
        let title = StillInsert(id: "title", assetID: asset.id, duration: .init(numerator: 1), cadence: .init(numerator: 1, denominator: 30))
        let clips = session.editor.sequenceClips.map(StillSequenceItem.source)
        let edited = CutProject.stillSequence(StillSequenceProject(items: [.still(title)] + clips, stillAssets: [asset]))
        try session.editor.applyStillProject(edited, action: "Add title")
        let revision = session.mcpRevision

        let held = try await registry.mcpReviewFrame(arguments: ["space": "sequence", "time": "1/2"], session: session, checkAccess: {})
        XCTAssertEqual(held["asset"] as? String, "art")
        XCTAssertEqual(held["placement"] as? String, "title")
        XCTAssertNil(held["source_time"])
        let encoded = try XCTUnwrap(held["jpeg"] as? String)
        let jpeg = try XCTUnwrap(Data(base64Encoded: encoded))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 640)
        XCTAssertEqual(image.colorSpace?.name.map { $0 as String }, CGColorSpace.sRGB as String)

        let next = try await registry.mcpReviewFrame(arguments: ["space": "sequence", "time": "1"], session: session, checkAccess: {})
        XCTAssertNil(next["placement"])
        XCTAssertEqual(next["source_time"] as? String, session.editor.sequenceClips.first?.from.description)
        let output = directory.appendingPathComponent("review", isDirectory: true)
        let job = try XCTUnwrap(registry.mcpProgramFrameExport(session: session, output: output, args: ["space": "sequence"],
                                                               mode: "times", times: [.zero, title.duration], preset: .review))
        let exported = try job(MCPLiveOutputProgress())
        XCTAssertEqual(exported["frames"] as? Int, 2)
        let manifestURL = output.appendingPathComponent("manifest.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let frames = try XCTUnwrap(manifest["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.first?["placement"] as? String, "title")
        let sourceTime = try XCTUnwrap(frames.last?["source_time"] as? [String: Int64])
        XCTAssertEqual(sourceTime["numerator"], session.editor.sequenceClips.first?.from.numerator)
        XCTAssertEqual(sourceTime["denominator"], session.editor.sequenceClips.first?.from.denominator)
        XCTAssertEqual(session.mcpRevision, revision)
    }

    func testSingleStillExportUsesReviewPreset() throws {
        let suite = "MPCut.ReviewPreset.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let (asset, directory) = try makeArtwork()
        let format = StillTimelineFormat(width: 1280, height: 720, cadence: .init(numerator: 1, denominator: 30),
                                         codec: .h264, container: "mp4")
        let project = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "title",
                                                       duration: .init(numerator: 1))
        try session.editor.applyStillProject(project, action: "Add title")
        let output = directory.appendingPathComponent("review.jpg")
        let job = try XCTUnwrap(registry.mcpProgramFrameExport(session: session, output: output, args: ["space": "sequence"],
                                                               mode: "still", times: [], preset: .review))
        XCTAssertEqual(try job(MCPLiveOutputProgress())["placement"] as? String, "title")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 360)
    }

    func testMulticamProgramReviewKeepsAngleAddressingAcrossStillEdits() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.isMulticam = true
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        let model = session.multicam
        model.confirmSetup(drafts: [.init(source: .init(id: "wide", file: fixture.path), media: media)], opening: "wide", audio: .none)
        let (asset, directory) = try makeArtwork()
        let range = try XCTUnwrap(model.project?.range)
        let replacementEnd = try XCTUnwrap(media.frames.dropFirst(3).first?.time)
        let replacement = StillReplacement(id: "photo", assetID: asset.id,
                                           coverage: .group(.init(from: range.from, to: replacementEnd)))
        let title = StillInsert(id: "title", assetID: asset.id, duration: .init(numerator: 1), cadence: .init(numerator: 1, denominator: 30))
        XCTAssertTrue(model.edit("Add images") {
            $0.stillAssets = [asset]
            $0.stillReplacements = [replacement]
            $0.assemblyItems = [.still(title), .group(range), .group(range)]
        })
        let groupPicture = try await registry.mcpReviewFrame(arguments: ["space": "group", "time": range.from.description],
                                                              session: session, checkAccess: {})
        XCTAssertEqual(groupPicture["placement"] as? String, "photo")
        let angleFrame = try await registry.mcpReviewFrame(arguments: ["space": "group", "time": range.from.description, "angle_id": "wide"],
                                                            session: session, checkAccess: {})
        XCTAssertEqual(angleFrame["angle_id"] as? String, "wide")
        XCTAssertNotNil(angleFrame["source_time"])
        XCTAssertNil(angleFrame["placement"])

        let insert = try await registry.mcpReviewFrame(arguments: ["space": "assembly", "time": "0"],
                                                       session: session, checkAccess: {})
        XCTAssertEqual(insert["placement"] as? String, "title")
        XCTAssertNil(insert["group_time"])
        do {
            _ = try await registry.mcpReviewFrame(arguments: ["space": "assembly", "time": "0", "angle_id": "wide"],
                                                  session: session, checkAccess: {})
            XCTFail("An inserted still has no angle frame.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_target")
        }
        let repeated = try title.duration.adding(range.to.subtracting(range.from))
        let secondPhoto = try await registry.mcpReviewFrame(arguments: ["space": "assembly", "time": repeated.description],
                                                            session: session, checkAccess: {})
        XCTAssertEqual(secondPhoto["placement"] as? String, "photo")
        XCTAssertEqual(secondPhoto["group_time"] as? String, range.from.description)
    }

    private func makeArtwork() throws -> (StillAsset, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let titleURL = directory.appendingPathComponent("title.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        try png.write(to: titleURL)
        let asset = StillAsset(id: "art", file: titleURL.path, displayName: "Title", fingerprint: try StillImage.fingerprint(titleURL))
        return (asset, directory)
    }

}
