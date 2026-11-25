import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MPCutCore
import XCTest
@testable import MPCutApp

final class StillEditorModelTests: XCTestCase {
    @MainActor
    func testSavedSoundtrackQueueUsesHeldPictureAndPreservesExplicitCadenceOverride() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (project, asset, media) = try soundtrackStill(in: folder, duration: .init(numerator: 1))
        let sound = media.url
        let engine = CutEngine(useSidecar: false)
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        try editor.applyStillProject(project, action: "Insert Still")
        try editor.applyStillProject(project.attachingStillSoundtrack(StillSoundtrack.reference(media: media)),
                                     action: "Attach Soundtrack")
        editor.cacheStillSoundtrackMedia(media)
        let document = folder.appendingPathComponent("show.cut")
        try editor.writeProject(to: document)

        let reopened = EditorModel()
        defer { reopened.endSession() }
        reopened.useAnalysisSidecars = false
        try reopened.openProject([], at: document)
        try await waitUntil { !reopened.isBusy }
        try reopened.cacheStillSoundtrackMedia(engine.inspect(sound))
        reopened.selectRange(0, 1)
        reopened.addMarkedRange()
        XCTAssertNil(reopened.alert, reopened.alert?.message ?? "")
        let queued = try XCTUnwrap(reopened.queuedRanges.first)
        reopened.showBulkQueue()
        XCTAssertTrue(reopened.isBulkQueuePresented)
        reopened.isBulkQueuePresented = false
        reopened.bulkQueueDismissed()
        XCTAssertEqual(reopened.readyQueuedRanges.map(\.id), [queued.id])

        let selectedProject = try XCTUnwrap(queued.stillProject)
        var audioOnly = ExportSheetOptions()
        audioOnly.placements = queued.placements
        audioOnly.tracks = .audio
        audioOnly.convertAudio(to: .alac, preferred: "m4a")
        XCTAssertEqual(audioOnly.container, "m4a")
        let audioPlan = try audioOnly.planStills(selectedProject, useSidecar: false, cancelled: { false })
        XCTAssertEqual(audioPlan.report.soundActions.map(\.audio), [.alac])

        let outputs: [(container: String, codec: ReencodeCodec, audio: ReencodeAudio, timing: StillPictureTiming?, count: Int)] = [
            ("mov", .hevc, .pcm, nil, 1),
            ("mp4", .h264, .alac, nil, 1),
            ("m4v", .h264, .flac, nil, 1),
            ("mkv", .h264, .flac, nil, 1),
            ("mov", .h264, .pcm, .cadence, 24)
        ]
        for (container, codec, audio, timing, count) in outputs {
            let label = "\(container)-\(timing?.rawValue ?? "held")"
            var options = ExportSheetOptions()
            options.placements = queued.placements
            options.mode = .smart
            options.copyContainer = container
            options.codec = codec
            options.stillVideoCodec = codec
            options.audio = audio
            options.pictureTiming = timing

            let choices = ExportContainerChoices(stillSource: media, cancelled: { false })
            XCTAssertTrue(choices.choices(for: options).contains(container))
            let direct = folder.appendingPathComponent("sheet-\(label).\(container)")
            let planner = StillExportPlanner(useSidecar: false)
            let sheet = try options.planStills(reopened.stillProject, output: direct, useSidecar: false, cancelled: { false })
            let explicit = try planner.resolve(selectedProject, mode: .smart, container: container,
                                               audioAction: audio, pictureTiming: timing, videoCodec: codec)
            XCTAssertEqual(sheet.report.soundActions.map(\.audio), [audio])
            XCTAssertEqual(sheet.report.soundActions.map(\.codec), explicit.report.soundActions.map(\.codec))
            XCTAssertEqual(sheet.report.generatedVideoSampleCount, count)
            XCTAssertFalse(FileManager.default.fileExists(atPath: direct.path))
            try planner.write(sheet, to: direct)

            let outputFolder = folder.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: false)
            reopened.showBulkQueue()
            reopened.exportQueuedRanges(to: outputFolder, options: options)
            try await waitUntil { !reopened.isExporting }
            XCTAssertNil(reopened.alert, reopened.alert?.message ?? "")
            let queuedOutputs = try FileManager.default.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: nil)
            XCTAssertEqual(queuedOutputs.count, 1)
            for output in [direct, try XCTUnwrap(queuedOutputs.first)] {
                let delivered = try engine.inspect(output, keyframes: true)
                XCTAssertEqual(output.pathExtension, container)
                XCTAssertEqual(delivered.streams.first(where: { $0.kind == "video" })?.codec, codec.rawValue)
                XCTAssertEqual(delivered.frames.count, count, output.lastPathComponent)
                XCTAssertEqual(delivered.audio.first?.stream.sampleRate, 48_000)
            }
        }

        let originalMovie = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                            subdirectory: "Fixtures"))
        let movie = try engine.inspect(originalMovie, keyframes: true)
        let replacement = try CutProject.sequence([.init(id: "source", file: originalMovie.path,
                                                          from: .zero, to: movie.duration)])
            .addingStillAsset(asset)
            .replacingPicture(id: "replacement", assetID: asset.id, from: .zero, to: movie.duration)
        let replacementQueue = QueuedRange(start: .zero, end: movie.duration,
                                            clips: [.init(file: originalMovie, from: .zero, to: movie.duration)],
                                            media: [originalMovie: movie], stillProject: replacement, placements: .replacement)
        XCTAssertEqual(movie.audio.map { $0.stream.codec }, ["aac", "aac"])
        for action: ReencodeAudio in [.pcm, .aac] {
            var options = ExportSheetOptions()
            options.mode = .smart
            options.placements = .replacement
            options.copyContainer = "mov"
            options.pictureTiming = .held
            options.audio = action
            let checked = try options.planStills(replacement, useSidecar: false, cancelled: { false })
            XCTAssertEqual(checked.report.soundActions.map(\.audio), [action, action])

            let directory = folder.appendingPathComponent(action.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let batch = try SequenceQueuePlan([replacementQueue], directory: directory, options: options,
                                              useSidecar: false, cancelled: { false })
            let item = try XCTUnwrap(batch.items.first)
            guard case .still(let queuedPlan) = item.payload else { return XCTFail("Expected a still export.") }
            XCTAssertEqual(queuedPlan.report.soundActions.map(\.audio), checked.report.soundActions.map(\.audio))
            try batch.write(item) { _ in true }
            let delivered = try engine.inspect(item.output, keyframes: true)
            XCTAssertEqual(delivered.audio.map { $0.stream.codec }, checked.report.soundActions.compactMap(\.codec))
        }

        try await waitUntil { !reopened.isBusy }
        let extended = try reopened.stillProject.resizingStill(id: "cover", duration: .init(numerator: 2))
        try reopened.applyStillProject(extended, action: "Extend Picture")
        reopened.selectRange(1, 2)
        reopened.addMarkedRange()
        let tail = try XCTUnwrap(reopened.readyQueuedRanges.last)
        XCTAssertEqual(tail.pictureTiming, .held)
        XCTAssertNil(tail.stillProject?.stillSoundtrack)
        XCTAssertEqual(tail.stillProject?.stillAudioReference?.audioTrack, 0)

        try FileManager.default.moveItem(at: sound, to: folder.appendingPathComponent("moved.wav"))
        XCTAssertNotNil(reopened.stillSoundtrackExportIssue(in: reopened.stillProject, tracks: .all))
        XCTAssertNil(reopened.stillSoundtrackExportIssue(in: reopened.stillProject, tracks: .video))
        var pictureOnly = ExportSheetOptions()
        pictureOnly.tracks = .video
        pictureOnly.placements = queued.placements
        pictureOnly.mode = .smart
        pictureOnly.copyContainer = "mov"
        let withoutSoundtrack = try pictureOnly.planStills(XCTUnwrap(queued.stillProject), useSidecar: false, cancelled: { false })
        XCTAssertTrue(withoutSoundtrack.report.soundActions.isEmpty)
        XCTAssertEqual(withoutSoundtrack.report.generatedVideoSampleCount, 1)
    }

    @MainActor
    func testDropSoundtrackAndLengthenStillThroughTimelineTrim() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalDuration = RationalTime(numerator: 1, denominator: 2)
        let newDuration = RationalTime(numerator: 3, denominator: 2)
        let soundtrackDuration = RationalTime(numerator: 48_001, denominator: 48_000)
        let (project, _, media) = try soundtrackStill(in: folder, duration: originalDuration, soundtrackFrames: 48_001)
        let suite = "StillEditorModelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = EditorModel(defaults: defaults)
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        try editor.applyStillProject(project, action: "Insert Still")

        editor.dropOnTimeline([media.url], slot: 1)
        try await waitUntil { !editor.isBusy }
        XCTAssertNil(editor.alert, editor.alert?.message ?? "")
        let attached = try XCTUnwrap(editor.stillProject.stillSoundtrack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.url.appendingPathExtension("cutcache").path))
        XCTAssertEqual(attached.file, media.url.resolvingSymlinksInPath().path)
        XCTAssertEqual(attached.to - attached.from, soundtrackDuration)
        XCTAssertEqual(editor.mcpDuration, originalDuration)
        XCTAssertEqual(editor.stillSoundtrackWaveform?.output.to, originalDuration)

        let surface = TimelineSurface(frame: NSRect(x: 0, y: 0, width: 700, height: 119))
        let window = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.viewportWidth = 232
        var dragResult: Double?
        surface.timeline = SequenceTimeline(clips: editor.timelineClips, playhead: editor.playhead,
                                            selection: editor.selectedID, thumbnailHeight: 32,
                                            zoom: .constant(0), allowsStillEndResize: true,
                                            onSelect: editor.select, onSeek: editor.seek, onTrim: editor.trim,
                                            onMove: { _, _ in }, onDrop: { editor.dropOnTimeline($0, slot: $1) },
                                            onEndScrub: editor.preview.endScrub, onCancelTrim: editor.cancelTrim,
                                            validateHandle: { id, edge, time, commit, done in
            editor.validateHandle(id, edge: edge, target: time, commit: commit) { result in
                dragResult = result
                done(result)
            }
        })
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            let point = surface.convert(NSPoint(x: x, y: 33), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        }
        // Fit zoom gives the half-second card 200 points between the 16-point margins.
        let revision = editor.mcpRevision
        surface.mouseDown(with: try mouse(.leftMouseDown, x: 214))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, x: 614))
        XCTAssertEqual(dragResult, 1.5)
        XCTAssertEqual(editor.mcpRevision, revision)
        XCTAssertEqual(editor.mcpDuration, originalDuration)
        dragResult = nil
        surface.mouseUp(with: try mouse(.leftMouseUp, x: 614))
        XCTAssertEqual(dragResult, 1.5)
        XCTAssertNil(editor.alert, editor.alert?.message ?? "")
        XCTAssertEqual(editor.mcpDuration, newDuration)
        XCTAssertEqual(editor.stillProject.stillSoundtrack, attached)
        XCTAssertEqual(editor.stillSoundtrackWaveform?.output.to, soundtrackDuration)
        XCTAssertEqual(editor.preview.ranges.count, 2)
        XCTAssertEqual(editor.preview.ranges.first?.exactEnd, soundtrackDuration)
        XCTAssertEqual(editor.preview.ranges.last?.isSilentInsert, true)
        XCTAssertEqual(editor.preview.ranges.last?.exactEnd, newDuration - soundtrackDuration)
        editor.scrub(1.25)
        XCTAssertEqual(editor.playhead, 1.25)
        try await waitUntil { editor.preview.displayedFrameTime != nil }
        XCTAssertNil(editor.preview.programPictureIssue)
        editor.preview.endScrub()

        let document = folder.appendingPathComponent("lengthened.cut")
        try editor.writeProject(to: document)
        let reopened = EditorModel(defaults: defaults)
        defer { reopened.endSession() }
        reopened.useAnalysisSidecars = false
        try reopened.openProject([], at: document)
        try await waitUntil { !reopened.isBusy && reopened.currentSoundtrackMedia != nil }
        XCTAssertEqual(reopened.mcpDuration, newDuration)
        XCTAssertEqual(reopened.stillProject.stillSoundtrack, attached)
        reopened.undo()
        try await waitUntil { !reopened.isBusy && reopened.mcpDuration == originalDuration }
        XCTAssertEqual(reopened.stillProject.stillSoundtrack, attached)
        XCTAssertEqual(reopened.stillSoundtrackWaveform?.output.to, originalDuration)
        reopened.redo()
        try await waitUntil { !reopened.isBusy && reopened.mcpDuration == newDuration }

        var options = ExportSheetOptions()
        options.mode = .smart
        options.placements = .insertion
        options.copyContainer = "mov"
        let destination = folder.appendingPathComponent("lengthened.mov")
        let export = try options.planStills(reopened.stillProject, output: destination,
                                            useSidecar: false, cancelled: { false })
        XCTAssertEqual(export.report.generatedVideoSampleCount, 1)
        XCTAssertEqual(export.report.soundActions.first?.generatedSilence, [.init(from: soundtrackDuration, to: newDuration)])
        try StillExportPlanner(useSidecar: false).write(export, to: destination)
        let engine = CutEngine(useSidecar: false)
        let movie = try engine.inspect(destination, keyframes: true)
        XCTAssertEqual(movie.frames.map(\.duration), [newDuration])
        XCTAssertEqual(movie.audio.first?.end, newDuration)
        // Auto keeps the recording's own format: the 16-bit PCM WAV soundtrack stays 16-bit PCM in MOV.
        XCTAssertEqual(movie.audio.first?.stream.codec, "pcm_s16le")

        let picture = try XCTUnwrap(reopened.timelineClips.first)
        // One second lies on the picture grid but the recording has one more sample.
        XCTAssertEqual(reopened.trim(picture.id, edge: .end, sourceTime: 1, commit: true),
                       soundtrackDuration.seconds)
        XCTAssertEqual(reopened.mcpDuration, soundtrackDuration)
        XCTAssertEqual(reopened.stillProject.stillInserts.first?.usesExactDuration, true)
        let fitted = folder.appendingPathComponent("fitted.mov")
        let fittedPlan = try options.planStills(reopened.stillProject, output: fitted,
                                               useSidecar: false, cancelled: { false })
        XCTAssertEqual(fittedPlan.report.soundActions.first?.generatedSilence, [])
        try StillExportPlanner(useSidecar: false).write(fittedPlan, to: fitted)
        let fittedMovie = try engine.inspect(fitted, keyframes: true)
        XCTAssertEqual(fittedMovie.frames.map(\.duration), [soundtrackDuration])
        XCTAssertEqual(fittedMovie.audio.first?.end, soundtrackDuration)

        reopened.select(picture.id)
        reopened.seek(0.5)
        XCTAssertTrue(reopened.canTrimSelected(.end, restore: false))
        XCTAssertFalse(reopened.canTrimSelected(.start, restore: false))
        XCTAssertFalse(reopened.canTrimSelected(.end, restore: true))
        reopened.trimSelected(.end)
        XCTAssertEqual(reopened.mcpDuration, originalDuration)
        XCTAssertEqual(reopened.stillProject.stillSoundtrack, attached)
        reopened.undo()
        try await waitUntil { !reopened.isBusy && reopened.mcpDuration == soundtrackDuration }
    }

    @MainActor
    func testAudioOnlyMP4DroppedOnViewerAttachesSoundtrack() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (project, _, media) = try soundtrackStill(in: folder, duration: .init(numerator: 1))
        let sound = folder.appendingPathComponent("recording.m4a")
        let movie = folder.appendingPathComponent("recording.mp4")
        do {
            let input = try AVAudioFile(forReading: media.url)
            let output = try AVAudioFile(forWriting: sound, settings: [
                AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 16
            ])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                        frameCapacity: AVAudioFrameCount(input.length)))
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
        try FileManager.default.moveItem(at: sound, to: movie)
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        try editor.applyStillProject(project, action: "Insert Still")
        editor.dropOnViewer([movie])
        try await waitUntil { !editor.isBusy }
        XCTAssertNil(editor.alert, editor.alert?.message ?? "")
        XCTAssertEqual(editor.stillProject.stillSoundtrack?.file, movie.resolvingSymlinksInPath().path)
        XCTAssertEqual(editor.stillProject.stillInserts, project.stillInserts)
        XCTAssertEqual(editor.stillProject.stillFormat, project.stillFormat)
        XCTAssertEqual(editor.stillProject.sequenceClips?.count, 0)
        editor.undo()
        try await waitUntil { !editor.isBusy }
        XCTAssertEqual(editor.stillProject, project)
    }

    private func soundtrackStill(in folder: URL, duration: RationalTime, soundtrackFrames: AVAudioFrameCount = 48_000) throws
        -> (CutProject, StillAsset, MediaInfo) {
        let image = folder.appendingPathComponent("cover.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: 16, height: 16))
        let png = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(png))

        let sound = folder.appendingPathComponent("soundtrack.wav")
        do {
            let file = try AVAudioFile(forWriting: sound, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
            ])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: soundtrackFrames))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = 0.25 * sin(2 * .pi * Float(index % 96) / 96)
            }
            try file.write(from: buffer)
        }

        let media = try CutEngine(useSidecar: false).inspect(sound)
        let asset = StillAsset(id: "cover", file: image.path, displayName: "Cover",
                               fingerprint: try StillImage.fingerprint(image))
        let cadence = RationalTime(numerator: 1, denominator: 24)
        let format = StillTimelineFormat(width: 320, height: 180, cadence: cadence, codec: .h264, container: "mov")
        let project = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "cover",
                                                       duration: duration)
        return (project, asset, media)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    @MainActor
    func testOfflineStillOnlySequenceHistoryRoundTripsAndRestoresSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("offline.png")
        let document = folder.appendingPathComponent("titles.cut")
        let asset = StillAsset(id: "title-art", file: image.path,
                               displayName: "Title", fingerprint: String(repeating: "b", count: 64))
        let cadence = RationalTime(numerator: 1, denominator: 30)
        let format = StillTimelineFormat(width: 640, height: 360, cadence: cadence, codec: .h264, container: "mp4")
        let project = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "title",
                                                       duration: RationalTime(numerator: 2))
        let editor = EditorModel()
        defer { editor.endSession() }
        try editor.applyStillProject(project, action: "Insert Still")
        XCTAssertEqual(editor.mcpDuration, RationalTime(numerator: 2))
        XCTAssertTrue(editor.canNavigate)
        XCTAssertEqual(editor.timelineClips.count, 1)
        let checkDeadline = ContinuousClock.now + .seconds(5)
        while editor.stillPlacementRows.first?.mediaStatus != .offline, ContinuousClock.now < checkDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(editor.stillPlacementRows.first?.title, "Insert · Title")
        XCTAssertEqual(editor.stillPlacementRows.first?.mediaStatus, .offline)
        editor.seek(1)
        editor.setIn()
        editor.seek(2)
        editor.setOut()
        XCTAssertEqual(try editor.stillProjectForSelection().resolveStills().duration, RationalTime(numerator: 1))
        editor.undo()
        XCTAssertTrue(editor.isEmpty)
        try editor.writeProject(to: document)
        let archive = try CutProject.loadEditorDocument(from: document, limit: 5)
        XCTAssertEqual(archive.project, .sequence([]))
        XCTAssertEqual(archive.redo.first?.project.stillAssets.first?.file, "offline.png")
        XCTAssertThrowsError(try editor.validateHistoryDestination(image))

        let reopened = EditorModel()
        defer { reopened.endSession() }
        try reopened.openProject([], at: document)
        XCTAssertTrue(reopened.isEmpty)
        XCTAssertTrue(reopened.canRedo)
        reopened.redo()
        XCTAssertEqual(reopened.stillProject, project)
        XCTAssertEqual(reopened.mcpDuration, RationalTime(numerator: 2))
    }

    @MainActor
    func testMarkedRangeSplitsBothEdgesOfAStillInOneUndoStep() throws {
        let editor = EditorModel()
        defer { editor.endSession() }
        let asset = StillAsset(id: "title", file: "/offline.png", displayName: "Title", fingerprint: String(repeating: "a", count: 64))
        let format = StillTimelineFormat(width: 640, height: 360, cadence: RationalTime(numerator: 1, denominator: 30), codec: .h264, container: "mp4")
        let project = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "card", duration: RationalTime(numerator: 3))
        try editor.applyStillProject(project, action: "Insert Still")
        editor.selectRange(1, 2)
        editor.splitSelectedRange()
        XCTAssertEqual(editor.stillProject.stillInserts.map(\.duration), Array(repeating: RationalTime(numerator: 1), count: 3))
        XCTAssertFalse(editor.canSplitSelectedRange)
        editor.undo()
        XCTAssertEqual(editor.stillProject, project)
        editor.selectRange(1, 2)
        editor.deleteSelection()
        XCTAssertEqual(editor.stillProject.stillInserts.map(\.duration), [RationalTime(numerator: 2)])
        XCTAssertNil(editor.markIn)
        XCTAssertNil(editor.markOut)
        XCTAssertEqual(editor.playhead, 1)
        editor.undo()
        XCTAssertEqual(editor.stillProject, project)
    }

    @MainActor
    func testSourceOffsetsAccountForAnInlineStillAfterReordering() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.importFiles([source, source])
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(editor.alert)
        let clips = editor.sequenceClips
        XCTAssertEqual(clips.count, 2)
        let start = clips[0].to - clips[0].from
        let asset = StillAsset(id: "card-image", file: "/offline.png",
                               displayName: "Card", fingerprint: String(repeating: "a", count: 64))
        let cadence = RationalTime(numerator: 1001, denominator: 30_000)
        let card = StillInsert(id: "card", assetID: asset.id, duration: cadence, cadence: cadence)
        let edited = try editor.stillProject.addingStillAsset(asset).insertingStill(card, at: start)
        try editor.applyStillProject(edited, action: "Insert Still")
        XCTAssertEqual(editor.mcpSequenceOffsets, [.zero, start + cadence])
        let id = try XCTUnwrap(editor.timelineClips.last?.id)
        editor.moveTimelineItem(id, to: 0)
        XCTAssertEqual(editor.sequenceClips.map(\.id), [clips[1].id, clips[0].id])
        XCTAssertEqual(editor.mcpSequenceOffsets, [.zero, start])
        XCTAssertTrue(editor.timelineClips.last?.isStill == true)
        editor.undo()
        XCTAssertEqual(editor.mcpSequenceOffsets, [.zero, start + cadence])
        XCTAssertEqual(editor.stillProject.stillInserts.map(\.id), ["card"])

        let beforeDrop = editor.stillProject
        for slot in [1, 2] {
            editor.dropOnTimeline([source, source], slot: slot)
            try await waitUntil { !editor.isBusy }
            XCTAssertNil(editor.alert)
            XCTAssertEqual(editor.sequenceClips.count, 4)
            XCTAssertEqual(editor.timelineClips.firstIndex(where: \.isStill), slot == 1 ? 3 : 1)
            editor.undo()
            XCTAssertEqual(editor.stillProject, beforeDrop)
        }
    }

    @MainActor
    func testSelectionInsideStillInheritsTwoSilentAudioTracks() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.importFiles([source])
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(editor.alert)
        let audioReference = try XCTUnwrap(editor.sequenceClips.first)
        let asset = StillAsset(id: "title-art", file: "/offline-title.png",
                               displayName: "Offline title", fingerprint: String(repeating: "a", count: 64))
        let card = StillInsert(id: "title", assetID: asset.id, duration: RationalTime(numerator: 1),
                               cadence: RationalTime(numerator: 1, denominator: 10))
        let project = try editor.stillProject.addingStillAsset(asset).insertingStill(card, at: .zero)
        try editor.applyStillProject(project, action: "Insert Still")
        editor.selectRange(0.2, 0.5)
        let selection = try editor.stillProjectForSelection()
        XCTAssertEqual(selection.sequenceClips, [])
        XCTAssertEqual(selection.stillAudioReference, audioReference)
        XCTAssertThrowsError(try JSONEncoder().encode(selection))
        let planned = try StillExportPlanner().resolve(selection, tracks: .audio, mode: .encode,
                                                       container: "mov", settings: ReencodeSettings(audio: .pcm))
        let silence = MulticamRange(from: .zero, to: RationalTime(numerator: 3, denominator: 10))
        XCTAssertEqual(planned.report.soundActions.count, 2)
        for track in planned.report.soundActions {
            XCTAssertEqual(track.audio, .pcm)
            XCTAssertTrue(track.sources.isEmpty)
            XCTAssertEqual(track.generatedSilence, [silence])
        }

        let slicedEditor = EditorModel()
        defer { slicedEditor.endSession() }
        slicedEditor.useAnalysisSidecars = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cut")
        try slicedEditor.openProject([], at: url, stillProject: selection)
        slicedEditor.selectRange(0, 0.2)
        let slice = try slicedEditor.stillProjectForSelection()
        XCTAssertEqual(slice.stillAudioReference, audioReference)
        slicedEditor.addMarkedRange()
        let queued = try XCTUnwrap(slicedEditor.readyQueuedRanges.first)
        XCTAssertEqual(queued.stillProject?.stillAudioReference, audioReference)
        let croppedPlan = try StillExportPlanner().resolve(XCTUnwrap(queued.stillProject), tracks: .audio, mode: .encode,
                                                             container: "mov", settings: .init(audio: .pcm))
        XCTAssertEqual(croppedPlan.report.soundActions.map(\.generatedSilence), Array(repeating: [
            MulticamRange(from: .zero, to: RationalTime(numerator: 1, denominator: 5))
        ], count: 2))
    }
}
