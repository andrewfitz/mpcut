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

    func testSourceClockReadsRemovedMaterialInBatchesAtARequestedSize() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov", subdirectory: "Fixtures"))
        let editor = session.editor
        func settle() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while editor.isBusy {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        editor.importFiles([fixture])
        try await settle()
        let (sourceID, media) = try editor.mcpReplacementSource(try XCTUnwrap(editor.mcpClipIDs.first))
        let frames = media.frames.map(\.time)
        let cut = frames[frames.count / 2]
        func read(_ arguments: [String: Any]) async throws -> [String: Any] {
            try await registry.mcpReviewFrame(arguments: arguments, session: session, checkAccess: {})
        }
        func code(_ arguments: [String: Any]) async -> String? {
            do { _ = try await read(arguments) } catch let error as MCPCommandError { return error.code } catch {}
            return nil
        }

        // Remove the opening half. Its pictures keep their source times and lose their sequence times.
        _ = try await editor.mcpCommand(tool: "sequence_range_edit",
                                        arguments: ["action": "delete_range", "from": "0", "to": cut.description], validateCommit: {})
        try await settle()
        XCTAssertEqual(editor.sequenceClips.first?.from, cut)
        let kept = try await read(["space": "sequence", "time": "0"])
        XCTAssertEqual(kept["source_time"] as? String, cut.description)
        let beyond = try editor.mcpDuration.adding(cut)
        do {
            _ = try await read(["space": "sequence", "time": beyond.description])
            XCTFail("A time past the sequence has no picture.")
        } catch let error as MCPCommandError {
            XCTAssertEqual(error.code, "invalid_target")
            XCTAssertTrue(error.message.contains("space \"source\""), error.message)
        }

        let removed = try await read(["space": "source", "time": "0", "source_id": sourceID.uuidString])
        XCTAssertEqual(removed["space"] as? String, "source")
        XCTAssertEqual(removed["view"] as? String, "source")
        XCTAssertEqual(removed["source_time"] as? String, "0")
        XCTAssertEqual(removed["source_id"] as? String, sourceID.uuidString)
        XCTAssertEqual(removed["file"] as? String, media.url.path)
        XCTAssertEqual(removed["width"] as? Int, 640)
        XCTAssertNotEqual(removed["jpeg"] as? String, kept["jpeg"] as? String)

        // Several times by file in one reply, at a smaller size.
        let times = [frames[0], frames[1], cut].map(\.description)
        let batch = try await read(["space": "source", "times": times, "file": fixture.path, "max_edge": 320])
        XCTAssertEqual(batch["view"] as? String, "source")
        XCTAssertNil(batch["jpeg"])
        let rows = try XCTUnwrap(batch["frames"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["source_time"] as? String }, times)
        for row in rows {
            XCTAssertEqual(row["width"] as? Int, 320)
            XCTAssertEqual(row["height"] as? Int, 180)
            let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(row["jpeg"] as? String)))
            let image = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(image.width, 320)
        }
        // A region keeps the picture's own pixels: a quarter of this 640 by 360 frame is 320 by 180.
        func quarter(y: Double, edge: Int? = nil) async throws -> [String: Any] {
            var arguments: [String: Any] = ["space": "source", "time": "0", "file": fixture.path,
                                            "region": ["x": 0.5, "y": y, "width": 0.5, "height": 0.5]]
            arguments["max_edge"] = edge
            return try await read(arguments)
        }
        let lowerRight = try await quarter(y: 0.5), upperRight = try await quarter(y: 0)
        for crop in [lowerRight, upperRight] {
            XCTAssertEqual(crop["width"] as? Int, 320)
            XCTAssertEqual(crop["height"] as? Int, 180)
            XCTAssertEqual(crop["native_width"] as? Int, 640)
            XCTAssertEqual(crop["native_height"] as? Int, 360)
            XCTAssertEqual((crop["region"] as? [String: Double])?["width"], 0.5)
        }
        // The fixture's brown block sits mostly below the middle of the right half.
        XCTAssertGreaterThan(try meanRed(lowerRight), try meanRed(upperRight) + 10)
        let smallCrop = try await quarter(y: 0.5, edge: 160)
        XCTAssertEqual(smallCrop["width"] as? Int, 160)
        // A reduced whole frame says how large the picture really is. A full-size one has nothing to add.
        XCTAssertEqual(rows[0]["native_width"] as? Int, 640)
        XCTAssertNil(removed["native_width"])
        XCTAssertNil(removed["region"])

        // The requested size ends with its request.
        let after = try await read(["space": "sequence", "time": "0"])
        XCTAssertEqual(after["width"] as? Int, 640)
        let one = try await read(["space": "sequence", "times": ["0"]])
        XCTAssertEqual((one["frames"] as? [[String: Any]])?.count, 1)

        // With every clip removed, the recording is still found in the retained history.
        _ = try await editor.mcpCommand(tool: "sequence_range_edit",
                                        arguments: ["action": "delete_range", "from": "0", "to": editor.mcpDuration.description],
                                        validateCommit: {})
        try await settle()
        XCTAssertTrue(editor.mcpClipIDs.isEmpty)
        let retained = try await read(["space": "source", "time": cut.description, "file": fixture.path])
        XCTAssertEqual(retained["source_time"] as? String, cut.description)
        XCTAssertEqual(retained["source_id"] as? String, sourceID.uuidString)

        let invalid: [[String: Any]] = [
            ["space": "source", "time": "0"],
            ["space": "sequence", "time": "0", "source_id": sourceID.uuidString],
            ["space": "source", "time": "0", "file": fixture.path, "view": "output"],
            ["space": "sequence", "time": "0", "times": ["0"]],
            ["space": "sequence", "times": Array(repeating: "0", count: 13)],
            ["space": "sequence", "time": "0", "max_edge": 4000],
            ["space": "sequence", "time": "0", "region": ["x": 0.5, "y": 0, "width": 0.75, "height": 1]],
            ["space": "sequence", "time": "0", "region": ["x": 0, "y": 0, "width": 0, "height": 1]],
        ]
        for arguments in invalid {
            let rejected = await code(arguments)
            XCTAssertEqual(rejected, "invalid_arguments", "\(arguments)")
        }
        let unknown = await code(["space": "source", "time": "0", "file": "/tmp/not-in-this-project.mov"])
        XCTAssertEqual(unknown, "invalid_target")
        let past = await code(["space": "source", "time": "3600", "file": fixture.path])
        XCTAssertEqual(past, "invalid_target")
    }

    /// The rendered program and a still picture have their own scaling code. Each crops from the top left.
    func testRegionAndBatchesOnTheRenderedProgramAndOnAStill() async throws {
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let registry = ProjectSessions(preferences: preferences)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Scene-Cadence-Change", withExtension: "mov", subdirectory: "Fixtures"))
        func region(y: Double, height: Double = 0.5) -> [String: Double] { ["x": 0.5, "y": y, "width": 0.5, "height": height] }

        let program = ProjectSession(id: UUID(), preferences: preferences)
        defer { program.end() }
        program.isMulticam = true
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(fixture)
        program.multicam.confirmSetup(drafts: [.init(source: .init(id: "wide", file: fixture.path), media: media)],
                                      opening: "wide", audio: .none)
        XCTAssertTrue(program.multicam.edit("Set Output Canvas") {
            $0.participants.tileOutput = .init(canvas: .init(width: 640, height: 360), audio: .init(mode: .silence))
        })
        func output(_ arguments: [String: Any]) async throws -> [String: Any] {
            try await registry.mcpReviewFrame(arguments: arguments.merging(["space": "assembly"]) { old, _ in old },
                                              session: program, checkAccess: {})
        }
        let lower = try await output(["time": "0", "region": region(y: 0.5)])
        let upper = try await output(["time": "0", "region": region(y: 0)])
        for crop in [lower, upper] {
            XCTAssertEqual(crop["view"] as? String, "output")
            XCTAssertEqual(crop["width"] as? Int, 320)
            XCTAssertEqual(crop["height"] as? Int, 180)
            XCTAssertEqual(crop["native_width"] as? Int, 640)
        }
        // The fixture's brown block sits mostly below the middle of the right half.
        XCTAssertGreaterThan(try meanRed(lower), try meanRed(upper) + 10)
        let second = try XCTUnwrap(media.frames.dropFirst().first?.time)
        let batch = try await output(["times": ["0", second.description], "max_edge": 320])
        let frames = try XCTUnwrap(batch["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.map { $0["time"] as? String }, ["0", second.description])
        XCTAssertEqual(frames.map { $0["width"] as? Int }, [320, 320])
        XCTAssertEqual(frames.map { $0["native_width"] as? Int }, [640, 640])
        XCTAssertNotNil(frames[1]["frame_time"])

        // A still that is red above its middle and blue below it.
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.end() }
        session.editor.importFiles([fixture])
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while session.editor.isBusy {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
        let (plain, directory) = try makeArtwork()
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 18))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 18, width: 64, height: 18))
        let splitURL = directory.appendingPathComponent("split.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(splitURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let asset = StillAsset(id: "split", file: splitURL.path, displayName: "Split", fingerprint: try StillImage.fingerprint(splitURL))
        let title = StillInsert(id: "title", assetID: asset.id, duration: .init(numerator: 1), cadence: .init(numerator: 1, denominator: 30))
        let clips = session.editor.sequenceClips.map(StillSequenceItem.source)
        try session.editor.applyStillProject(.stillSequence(StillSequenceProject(items: [.still(title)] + clips, stillAssets: [asset, plain])),
                                             action: "Add title")
        func still(_ arguments: [String: Any]) async throws -> [String: Any] {
            try await registry.mcpReviewFrame(arguments: arguments.merging(["space": "sequence", "time": "1/2"]) { old, _ in old },
                                              session: session, checkAccess: {})
        }
        let whole = try await still([:])
        XCTAssertEqual(whole["placement"] as? String, "title")
        let width = try XCTUnwrap(whole["width"] as? Int), height = try XCTUnwrap(whole["height"] as? Int)
        let top = try await still(["region": ["x": 0, "y": 0, "width": 1, "height": 0.5]])
        let bottom = try await still(["region": ["x": 0, "y": 0.5, "width": 1, "height": 0.5]])
        for crop in [top, bottom] {
            XCTAssertEqual(crop["width"] as? Int, width)
            XCTAssertEqual(crop["height"] as? Int, height / 2)
            XCTAssertEqual(crop["native_height"] as? Int, height)
        }
        XCTAssertGreaterThan(try meanRed(top), try meanRed(bottom) + 100)
        let smaller = try await still(["max_edge": 160])
        XCTAssertEqual(smaller["width"] as? Int, 160)
        XCTAssertEqual(smaller["native_width"] as? Int, width)
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

    private func meanRed(_ row: [String: Any]) throws -> Double {
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(row["jpeg"] as? String)))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / Double(image.width * image.height)
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
