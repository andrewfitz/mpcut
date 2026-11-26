import AppKit
import ImageIO
import MPCutCore
import UniformTypeIdentifiers
import XCTest
@testable import MPCutApp

/// Settings → Export values that a live MCP export takes for an omitted argument. Each one applies only where the
/// destination can hold it; otherwise the call gets what it got at factory values. Every preference store here is
/// unpersisted (`EditorPreferences(defaults: nil)`).
@MainActor
final class SettingsFix2ExportTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        try await super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsFix2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func fixture(_ name: String, _ ext: String = "mov") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func preferences() -> EditorPreferences {
        let preferences = EditorPreferences(defaults: nil)
        preferences.useAnalysisSidecars = false
        preferences.warnBeforeLoweringExportTier = false
        return preferences
    }

    /// Waits for `condition`, and fails the test when it is still false after `seconds`: a test must not go on to
    /// check a state it never reached.
    private func waitUntil(_ seconds: Int = 15, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Still waiting after \(seconds) s", file: file, line: line)
    }

    /// The finished job of a live MCP output call, or the refusal it threw before starting one.
    private func call(_ tool: String, _ arguments: [String: Any], sessions: ProjectSessions,
                      session: ProjectSession) async throws -> [String: Any] {
        var arguments = arguments
        arguments["project_handle"] = session.mcpHandle
        let ticket: [String: Any]?
        do {
            ticket = try await sessions.mcpOutputs(tool: tool, arguments: arguments, session: session, checkAccess: {})
        } catch let issue as CutError {
            return ["state": "refused", "code": issue.code, "message": issue.message]
        } catch let issue as MCPCommandError {
            return ["state": "refused", "code": issue.code, "message": issue.message]
        }
        let id = try XCTUnwrap(ticket?["job_id"] as? String)
        for _ in 0..<1_500 {
            let status = try sessions.mcpOutputJobs.status(owner: session.mcpHandle, id: id, cancel: false)
            if !["running", "cancelling"].contains(status["state"] as? String ?? "") { return status }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    private func text(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    private func eligible(_ status: [String: Any]) -> Bool {
        status["state"] as? String == "succeeded" && (status["result"] as? [String: Any])?["eligible"] as? Bool == true
    }

    private func writePNG(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: 32, height: 18))
        let png = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(png))
    }

    // MARK: Findings 1 and 2: the destination must hold the Settings codec

    /// Finding 2. A sequence with an inserted still and no stills timeline format, rendered to MP4 with the codec
    /// omitted: Settings ProRes cannot go into MP4, so the export keeps H.264 as it did at factory values.
    func testStillRenderWithOmittedCodecKeepsH264WhenTheDestinationCannotHoldProRes() async throws {
        let preferences = preferences()
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.editor.endSession() }
        let editor = session.editor
        editor.importFiles([try fixture("ProRes-2997")])
        try await waitUntil { !editor.isBusy }
        XCTAssertNil(editor.alert)
        let folder = try temporaryFolder()
        let image = folder.appendingPathComponent("card.png")
        try writePNG(image)
        let asset = StillAsset(id: "card", file: image.path, displayName: "Card", fingerprint: try StillImage.fingerprint(image))
        let cadence = RationalTime(numerator: 1001, denominator: 30_000)
        let card = StillInsert(id: "card", assetID: asset.id, duration: try cadence.multiplied(by: .init(numerator: 15)), cadence: cadence)
        try editor.applyStillProject(try editor.stillProject.addingStillAsset(asset).insertingStill(card, at: .zero), action: "Insert Still")
        XCTAssertNil(editor.stillProject.stillFormat)

        func plan(_ name: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
            try await call("export_editor_project_plan",
                           ["output": folder.appendingPathComponent(name).path, "mode": "encode", "tracks": "video"]
                               .merging(extra) { $1 }, sessions: sessions, session: session)
        }
        let factory = try await plan("Factory.mp4")
        XCTAssertTrue(eligible(factory), text(factory))
        XCTAssertTrue(text(factory).contains("h264"), text(factory))

        preferences.reencodeCodec = .prores
        preferences.reencodeQuality = .highQuality
        let mp4 = try await plan("Settings.mp4")
        XCTAssertTrue(eligible(mp4), "MP4 cannot hold ProRes, so the omitted codec stays H.264: \(text(mp4))")
        XCTAssertTrue(text(mp4).contains("h264"), text(mp4))
        let mov = try await plan("Settings.mov")
        XCTAssertTrue(eligible(mov), text(mov))
        XCTAssertTrue(text(mov).contains("prores"), "MOV holds the Settings codec: \(text(mov))")
        // An explicit codec is the caller's choice, as before.
        let explicit = try await plan("Explicit.mp4", ["codec": "prores"])
        XCTAssertFalse(eligible(explicit), text(explicit))
    }

    /// Finding 1. A Tiles sequence rendered live to MP4 with the codec omitted keeps H.264 under Settings ProRes; the
    /// container comes from the output's extension, not always MOV.
    func testTilesRenderWithOmittedCodecKeepsH264WhenTheDestinationCannotHoldProRes() async throws {
        let preferences = preferences()
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.editor.endSession() }
        let source = try fixture("ProRes-2997")
        let folder = try temporaryFolder()
        let document = folder.appendingPathComponent("Tiles.cut")
        func time(_ frame: Int64) -> RationalTime { .init(numerator: frame * 1001, denominator: 30_000) }
        let layout = TileLayoutSpan(range: .init(from: .zero, to: time(8)), layout: .solo,
                                    slots: [.init(target: .camera, id: source.path)])
        let clips = [CutSequenceClip(id: "gallery", file: source.path, from: time(1), to: time(7), tileLayouts: [layout])]
        try CutProject.sequence(clips).mapMediaPaths { CutProject.relativeMediaPath($0, to: document) }.save(to: document)
        try session.editor.openProject(clips, at: document)
        try await waitUntil { !session.editor.isBusy }
        XCTAssertTrue(session.editor.stillProject.requiresPictureProcessing)

        // The plan does not name the codec, so each case is also rendered (six small frames) and read back.
        func export(_ name: String, render: Bool) async throws -> (status: [String: Any], codec: String?) {
            let output = folder.appendingPathComponent(name)
            let status = try await call(render ? "export_editor_project_render" : "export_editor_project_plan",
                                        ["output": output.path, "tracks": "video"], sessions: sessions, session: session)
            guard render, status["state"] as? String == "succeeded" else { return (status, nil) }
            return (status, try CutEngine(useSidecar: false).inspect(output).video.codec)
        }
        let factory = try await export("Factory.mp4", render: false)
        XCTAssertTrue(eligible(factory.status), text(factory.status))
        let factoryRender = try await export("Factory-render.mp4", render: true)
        XCTAssertEqual(factoryRender.codec, "h264", text(factoryRender.status))

        preferences.reencodeCodec = .prores
        preferences.proresQuality = .proresHQ
        let mp4 = try await export("Settings.mp4", render: false)
        XCTAssertTrue(eligible(mp4.status), "MP4 cannot hold ProRes, so the omitted codec stays H.264: \(text(mp4.status))")
        let mp4Render = try await export("Settings-render.mp4", render: true)
        XCTAssertEqual(mp4Render.codec, "h264", text(mp4Render.status))
        let mov = try await export("Settings.mov", render: false)
        XCTAssertTrue(eligible(mov.status), text(mov.status))
        let movRender = try await export("Settings-render.mov", render: true)
        XCTAssertEqual(movRender.codec, "prores", "MOV holds the Settings codec: \(text(movRender.status))")
    }

    /// The audit of finding 2. A queue Re-encode with PCM audio and the container omitted wrote MOV at factory values;
    /// Settings MP4 cannot carry PCM, so the queue keeps MOV.
    func testQueueSettingsContainerIsSkippedWhenItCannotCarryTheRequestedAudio() async throws {
        let preferences = preferences()
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.editor.endSession() }
        let editor = session.editor
        editor.importFiles([try fixture("ProRes-2997")])
        try await waitUntil { !editor.isBusy }
        editor.selectRange(0, editor.mcpDuration.seconds)
        editor.addMarkedRange()
        let folder = try temporaryFolder()
        func plan(_ extra: [String: Any]) async throws -> [String: Any] {
            try await call("export_queue_plan", ["output": folder.path, "mode": "encode"].merging(extra) { $1 },
                           sessions: sessions, session: session)
        }
        let factory = try await plan(["audio": "pcm"])
        XCTAssertEqual(factory["state"] as? String, "succeeded", text(factory))
        XCTAssertTrue(text(factory).contains(".mov"), text(factory))

        preferences.reencodeContainer = .mp4
        let pcm = try await plan(["audio": "pcm"])
        XCTAssertEqual(pcm["state"] as? String, "succeeded", "MP4 cannot carry PCM, so the queue keeps MOV: \(text(pcm))")
        XCTAssertTrue(text(pcm).contains(".mov"), text(pcm))
        let aac = try await plan([:])
        XCTAssertEqual(aac["state"] as? String, "succeeded", text(aac))
        XCTAssertTrue(text(aac).contains(".mp4"), "Without PCM the Settings container applies: \(text(aac))")
    }

    // MARK: Finding 9: the queue gives Tiles ranges what the queue sheet starts with

    func testQueueWithTilesRangesTakesTheSettingsCodecAsTheQueueSheetDoes() async throws {
        let preferences = preferences()
        preferences.reencodeCodec = .prores
        let sessions = ProjectSessions(preferences: preferences)
        let session = ProjectSession(id: UUID(), preferences: preferences)
        defer { session.editor.endSession() }
        let editor = session.editor
        let source = try fixture("ProRes-2997")
        let folder = try temporaryFolder()
        let document = folder.appendingPathComponent("Tiles.cut")
        func time(_ frame: Int64) -> RationalTime { .init(numerator: frame * 1001, denominator: 30_000) }
        let layout = TileLayoutSpan(range: .init(from: .zero, to: time(8)), layout: .solo,
                                    slots: [.init(target: .camera, id: source.path)])
        let clips = [CutSequenceClip(id: "gallery", file: source.path, from: time(1), to: time(7), tileLayouts: [layout])]
        try CutProject.sequence(clips).mapMediaPaths { CutProject.relativeMediaPath($0, to: document) }.save(to: document)
        try editor.openProject(clips, at: document)
        try await waitUntil { !editor.isBusy }
        editor.selectRange(0, editor.mcpDuration.seconds)
        editor.addMarkedRange()
        XCTAssertTrue(editor.readyQueuedRanges.contains { ($0.pictureProject ?? $0.stillProject)?.requiresPictureProcessing == true })

        // What the queue sheet starts with for these ranges.
        let sheet = BulkQueueView.startingOptions(editor: editor)
        XCTAssertEqual(sheet.codec, .prores)
        XCTAssertEqual(sheet.mode, .encode)
        XCTAssertEqual(sheet.container, "mov")

        func render(_ name: String, _ extra: [String: Any] = [:]) async throws -> String? {
            let output = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let status = try await call("export_queue_render", ["output": output.path, "tracks": "video"].merging(extra) { $1 },
                                        sessions: sessions, session: session)
            XCTAssertEqual(status["state"] as? String, "succeeded", text(status))
            let written = (status["result"] as? [String: Any])?["destinations"] as? [String] ?? status["outputs"] as? [String] ?? []
            let movie = try XCTUnwrap(written.first { !$0.hasSuffix(".json") }, text(status))
            return try CutEngine(useSidecar: false).inspect(URL(fileURLWithPath: movie)).video.codec
        }
        // The queue's MOV holds the Settings codec, as the sheet would write it; an MP4 container cannot, so H.264.
        let queued = try await render("Settings")
        XCTAssertEqual(queued, "prores")
        let mp4 = try await render("MP4", ["container": "mp4"])
        XCTAssertEqual(mp4, "h264")
    }

    // MARK: The audit: every Settings fallback against its destination

    private enum Variant: String, CaseIterable {
        case prores, mp4, mkv, downmix
        @MainActor func apply(to preferences: EditorPreferences) {
            switch self {
            case .prores:
                preferences.reencodeCodec = .prores
                preferences.proresQuality = .proresHQ
            case .mp4: preferences.reencodeContainer = .mp4
            case .mkv: preferences.reencodeContainer = .mkv
            case .downmix: preferences.multicamAudioLayout = .downmixStereo
            }
        }
        @MainActor static func reset(_ preferences: EditorPreferences) {
            preferences.reencodeCodec = .h264
            preferences.proresQuality = .prores422
            preferences.reencodeContainer = .automatic
            preferences.multicamAudioLayout = .separateTracks
        }
    }

    /// A live call that is eligible at factory values stays eligible under each Settings variant. Where the variant does
    /// not apply or the destination cannot hold it, the result is the factory result, field for field. Whether a
    /// destination holds a value is read from the export rules, not from the code under test.
    func testEverySettingsFallbackKeepsAFactoryEligibleCallEligible() async throws {
        let preferences = preferences()
        let sessions = ProjectSessions(preferences: preferences)
        let folder = try temporaryFolder()

        let sequence = ProjectSession(id: UUID(), preferences: preferences)
        defer { sequence.editor.endSession() }
        sequence.editor.importFiles([try fixture("ProRes-2997")])
        try await waitUntil { !sequence.editor.isBusy }
        sequence.editor.selectRange(0, sequence.editor.mcpDuration.seconds)
        sequence.editor.addMarkedRange()

        let multicam = ProjectSession(id: UUID(), preferences: preferences)
        multicam.isMulticam = true
        defer { multicam.multicam.reset() }
        // A camera with sound, routed to the program, so the downmix variant has sound to render.
        let camera = folder.appendingPathComponent("camera.mov")
        try FileManager.default.copyItem(at: fixture("Pause-Quiet"), to: camera)
        let cameraMedia = try CutEngine(useSidecar: false).inspectMulticamSource(camera)
        let stream = try XCTUnwrap(cameraMedia.audio.first?.stream.index)
        multicam.multicam.confirmSetup(drafts: [.init(source: .init(id: "a", file: camera.path, audioStream: stream), media: cameraMedia)],
                                       opening: "a", audio: .fixed(.init(source: "a", stream: stream)))

        // A sequence with an inserted still and no stills timeline format.
        let still = ProjectSession(id: UUID(), preferences: preferences)
        defer { still.editor.endSession() }
        still.editor.importFiles([try fixture("ProRes-2997")])
        try await waitUntil { !still.editor.isBusy }
        let image = folder.appendingPathComponent("card.png")
        try writePNG(image)
        let asset = StillAsset(id: "card", file: image.path, displayName: "Card", fingerprint: try StillImage.fingerprint(image))
        let cadence = RationalTime(numerator: 1001, denominator: 30_000)
        let card = StillInsert(id: "card", assetID: asset.id, duration: try cadence.multiplied(by: .init(numerator: 15)), cadence: cadence)
        try still.editor.applyStillProject(try still.editor.stillProject.addingStillAsset(asset).insertingStill(card, at: .zero),
                                           action: "Insert Still")

        // A Tiles sequence.
        let tiles = ProjectSession(id: UUID(), preferences: preferences)
        defer { tiles.editor.endSession() }
        let source = try fixture("ProRes-2997")
        let document = folder.appendingPathComponent("Tiles.cut")
        func time(_ frame: Int64) -> RationalTime { .init(numerator: frame * 1001, denominator: 30_000) }
        let layout = TileLayoutSpan(range: .init(from: .zero, to: time(8)), layout: .solo, slots: [.init(target: .camera, id: source.path)])
        let tileClips = [CutSequenceClip(id: "gallery", file: source.path, from: time(1), to: time(7), tileLayouts: [layout])]
        try CutProject.sequence(tileClips).mapMediaPaths { CutProject.relativeMediaPath($0, to: document) }.save(to: document)
        try tiles.editor.openProject(tileClips, at: document)
        try await waitUntil { !tiles.editor.isBusy }

        @MainActor struct Case {
            let session: ProjectSession
            let tool: String
            let arguments: [String: Any]
            var multi: Bool { session.isMulticam }
            var queue: Bool { tool.hasPrefix("export_queue") }
            var mode: String? { arguments["mode"] as? String }
            var tracks: String { arguments["tracks"] as? String ?? "all" }
            var audio: String? { arguments["audio"] as? String }
            var container: String? {
                queue ? arguments["container"] as? String : (arguments["output"] as? String).map { URL(fileURLWithPath: $0).pathExtension }
            }
        }
        func output(_ name: String) -> String { folder.appendingPathComponent(name).path }
        let cases: [Case] = [
            .init(session: sequence, tool: "export_editor_project_plan", arguments: ["output": output("S.mp4"), "mode": "encode"]),
            .init(session: sequence, tool: "export_editor_project_plan", arguments: ["output": output("S.mov"), "mode": "encode"]),
            .init(session: sequence, tool: "export_editor_project_plan", arguments: ["output": output("S.mkv"), "mode": "encode"]),
            .init(session: sequence, tool: "export_editor_project_plan", arguments: ["output": output("S.m4v"), "mode": "encode"]),
            .init(session: sequence, tool: "export_editor_project_plan", arguments: ["output": output("S-copy.mov"), "mode": "copy"]),
            .init(session: sequence, tool: "export_editor_project_plan",
                  arguments: ["output": output("S-video.mp4"), "tracks": "video"]),
            .init(session: sequence, tool: "export_queue_plan", arguments: ["output": folder.path, "mode": "encode"]),
            .init(session: sequence, tool: "export_queue_plan", arguments: ["output": folder.path, "mode": "encode", "audio": "pcm"]),
            .init(session: sequence, tool: "export_queue_plan", arguments: ["output": folder.path, "mode": "encode", "container": "mp4"]),
            .init(session: sequence, tool: "export_queue_plan", arguments: ["output": folder.path, "mode": "copy"]),
            .init(session: still, tool: "export_editor_project_plan",
                  arguments: ["output": output("Still.mp4"), "mode": "encode", "tracks": "video"]),
            .init(session: still, tool: "export_editor_project_plan",
                  arguments: ["output": output("Still.mov"), "mode": "encode", "tracks": "video"]),
            .init(session: still, tool: "export_editor_project_plan",
                  arguments: ["output": output("Still.mkv"), "mode": "encode", "tracks": "video"]),
            .init(session: tiles, tool: "export_editor_project_plan",
                  arguments: ["output": output("Tiles.mp4"), "mode": "encode", "tracks": "video"]),
            .init(session: tiles, tool: "export_editor_project_plan",
                  arguments: ["output": output("Tiles.mov"), "mode": "encode", "tracks": "video"]),
            .init(session: multicam, tool: "export_editor_project_plan", arguments: ["output": output("M.mov"), "mode": "encode"]),
            .init(session: multicam, tool: "export_editor_project_plan", arguments: ["output": output("M.mp4"), "mode": "encode"]),
            .init(session: multicam, tool: "export_editor_project_plan", arguments: ["output": output("M.mkv"), "mode": "encode"]),
            .init(session: multicam, tool: "export_editor_project_plan", arguments: ["output": output("M-copy.mov"), "mode": "copy"]),
            .init(session: multicam, tool: "export_editor_project_plan", arguments: ["output": output("M-copy.webm"), "mode": "copy"]),
            .init(session: multicam, tool: "export_editor_project_plan",
                  arguments: ["output": output("M-original.mov"), "mode": "copy", "audio": "copy"]),
            .init(session: multicam, tool: "export_editor_project_plan",
                  arguments: ["output": output("M-aac.mp4"), "mode": "encode", "audio": "aac"]),
            .init(session: multicam, tool: "export_editor_project_plan",
                  arguments: ["output": output("M-pcm.mov"), "mode": "encode", "audio": "pcm"]),
            .init(session: multicam, tool: "export_editor_project_plan",
                  arguments: ["output": output("M-video.mp4"), "tracks": "video"]),
            .init(session: multicam, tool: "export_editor_project_plan", arguments: ["output": output("M.m4a"), "tracks": "audio"]),
        ]

        /// Whether the variant can change this call: it applies to the call and the destination holds it.
        func applies(_ variant: Variant, _ item: Case) -> Bool {
            let picture = item.mode == "encode" && item.tracks != "audio"
            switch variant {
            case .prores:
                guard picture else { return false }
                let container = item.container ?? "mov"
                return (item.multi ? ExportRules.multicamReencodeContainers(.prores) : ExportRules.reencodeContainers(.prores))
                    .contains(container)
            case .mp4, .mkv:
                guard item.queue, item.container == nil, picture, !item.multi else { return false }
                let audio = item.audio.flatMap(ReencodeAudio.init(rawValue:)) ?? .auto
                return ExportRules.reencodeContainers(for: audio, source: .movie, codec: .h264).contains(variant.rawValue)
            case .downmix:
                guard item.multi, item.tracks != "video", let container = item.container else { return false }
                let rendered = ExportRules.multicamRenderedAudioActions(container: container)
                switch item.audio {
                case nil, "auto": return !rendered.isEmpty
                case "pcm": return rendered.contains(.pcm)
                case "aac": return rendered.contains(.aac)
                default: return false
                }
            }
        }
        func usable(_ status: [String: Any], queue: Bool) -> Bool {
            queue ? status["state"] as? String == "succeeded" : eligible(status)
        }

        var checked = 0
        var skipped: [String] = []
        for item in cases {
            let label = "\(item.tool) \(text(item.arguments.filter { $0.key != "output" }))"
            Variant.reset(preferences)
            let factory = try await call(item.tool, item.arguments, sessions: sessions, session: item.session)
            guard usable(factory, queue: item.queue) else {
                // Only calls that work at factory values are held to the invariant.
                skipped.append("\(label): \(text(factory))")
                continue
            }
            for variant in Variant.allCases {
                Variant.reset(preferences)
                variant.apply(to: preferences)
                let result = try await call(item.tool, item.arguments, sessions: sessions, session: item.session)
                XCTAssertTrue(usable(result, queue: item.queue), "\(variant) \(label): \(text(result))")
                if !applies(variant, item) {
                    XCTAssertEqual(text(result["result"] ?? result), text(factory["result"] ?? factory),
                                   "\(variant) does not apply to \(label), so the factory result stands")
                }
                checked += 1
            }
        }
        Variant.reset(preferences)
        XCTAssertGreaterThanOrEqual(checked, Variant.allCases.count * 20, "Most cases work at factory values. Skipped: \(skipped.joined(separator: "\n"))")
    }
}
