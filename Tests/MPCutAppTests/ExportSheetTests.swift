import AppKit
import AVFoundation
import XCTest
@testable import MPCutApp
@testable import MPCutCore

final class ExportSheetTests: XCTestCase {
    func testMulticamAudioOutputAndActionAreIndependentOfPictureMode() {
        var choices = MulticamExportChoices(entry: .multicamSheet, preferred: .copy)
        XCTAssertEqual(choices.audioOutput, .separateTracks)
        XCTAssertEqual(choices.audio, .copyOriginal)
        XCTAssertNil(choices.requestedAudioAction)
        XCTAssertTrue(choices.deliveryActions.contains(.auto))
        XCTAssertTrue(choices.deliveryActions.contains(.removeAudio))

        choices.container = "webm"
        choices.audioOutput = .downmixStereo
        choices.settle()
        XCTAssertEqual(choices.effectiveMode, .copy)
        XCTAssertEqual(choices.audio, .auto)
        XCTAssertEqual(choices.requestedAudioAction, .auto)
        XCTAssertFalse(choices.deliveryActions.contains(.copyOriginal))
        XCTAssertFalse(choices.containers().contains("webm"))

        choices.audio = .pcm
        choices.container = "mp4"
        choices.settle()
        XCTAssertEqual(choices.container, "mov")
        XCTAssertEqual(choices.containers(), ["mov", "mkv"])
    }

    func testMulticamAlternativeRestoresItsRequestedAudioDelivery() {
        var choices = MulticamExportChoices(entry: .multicamSheet)
        choices.audioOutput = .downmixStereo
        choices.audio = .pcm
        func offer(audio: ReencodeAudio, flags: [String]) -> ExportAlternative {
            ExportAlternative(id: "delivery", rung: .copyOtherContainer, label: "Use MOV",
                              mode: .copy, tracks: .all, container: "mov", audio: audio,
                              codec: nil, bitRate: nil, quality: nil, lossless: audio == .copyOriginal,
                              warnings: [], arguments: flags, clips: nil)
        }
        choices.apply(offer(audio: .copyOriginal, flags: ["--audio", "copy"]))
        choices.settle()
        XCTAssertEqual(choices.audioOutput, .separateTracks)
        XCTAssertEqual(choices.audio, .copyOriginal)

        choices.apply(offer(audio: .aac, flags: ["--audio-output", "downmix_mono", "--audio", "aac"]))
        choices.settle()
        XCTAssertEqual(choices.audioOutput, .downmixMono)
        XCTAssertEqual(choices.audio, .aac)
    }

    func testMulticamQueueReviewsDownmixWithCopiedPicture() throws {
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspectMulticamSource(movie)
        let range = MulticamRange(from: .zero, to: media.duration)
        let streams = media.audio.prefix(2).map(\.stream.index)
        XCTAssertEqual(streams.count, 2)
        let lanes = streams.enumerated().map { ordinal, stream in
            MulticamAudioLane(id: "mic-\(ordinal)", target: .recording(.init(source: "a", stream: stream)),
                              label: "Mic \(ordinal + 1)", colorSlot: ordinal)
        }
        let project = MulticamProject(referenceAngle: "a", range: range,
                                      angles: [.init(id: "a", file: movie.path)], audio: .mix,
                                      switches: [.init(at: .zero, angle: "a")], mixLanes: lanes)
        let entry = MulticamQueuedRange(name: "Take", range: range, project: project, media: ["a": media])
        var choices = MulticamExportChoices(entry: .multicamQueue, preferred: .copy)
        choices.audioOutput = .downmixStereo
        choices.audio = .pcm
        choices.settle()
        let summary = try AnalysisSidecar.$readsEnabled.withValue(false) {
            try MulticamBulkExport.review([entry], choices: choices, organization: .init()).get()
        }
        XCTAssertTrue(summary.contains("1 audio track · stereo · PCM"), summary)
        XCTAssertTrue(summary.contains("Stereo downmix"), summary)
    }

    func testStillFallbackReplaysVerifiedVideoAndSoundSettings() {
        let alternative = ExportAlternative(id: "still-encode-mov", rung: .reencode, label: "Re-encode the program",
                                            mode: .encode, tracks: .all, container: "mov", audio: .aac,
                                            codec: "hevc", bitRate: nil, quality: nil, lossless: false, warnings: [],
                                            arguments: ["--mode", "encode", "--video", "hevc", "--quality", "high",
                                                        "--audio", "auto"], clips: nil)
        var sheet = ExportSheetOptions()
        sheet.placements = .replacement
        let replay = sheet.applying(alternative)
        var multicam = MulticamExportChoices(entry: .multicamQueue)
        multicam.placements = .replacement
        multicam.apply(alternative)
        // The alternative names --quality, so the replay carries it as an explicit choice.
        let settings = ReencodeSettings(codec: .hevc, quality: .highQuality, audio: .auto, qualityIsExplicit: true)
        XCTAssertEqual(replay.settings, settings)
        XCTAssertEqual(multicam.settings, settings)
        XCTAssertEqual(replay.container, "mov")
        XCTAssertEqual(multicam.container, "mov")
    }

    /// `swift test` runs inside Xcode's xctest, so the development helper cannot be
    /// found relative to the running executable.
    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil else { return }
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: helper.path) { setenv("MPCUT_FFMPEG_HELPER", helper.path, 1) }
    }

    @MainActor
    func testAudioTrackPickerFollowsTrackOrderAcrossDifferentStreamLayouts() async throws {
        _ = NSApplication.shared
        let first = try XCTUnwrap(Bundle.module.url(forResource: "Audio-Ordinal-Subtitle-First", withExtension: "mov", subdirectory: "Fixtures"))
        let second = try XCTUnwrap(Bundle.module.url(forResource: "Audio-Ordinal-Subtitle-Last", withExtension: "mov", subdirectory: "Fixtures"))
        let engine = CutEngine()
        let firstMedia = try engine.inspect(first, keyframes: true)
        let secondMedia = try engine.inspect(second, keyframes: true)
        XCTAssertEqual(firstMedia.audio.map(\.stream.index), [1, 2])
        XCTAssertEqual(secondMedia.audio.map(\.stream.index), [0, 1])
        let media = [first: firstMedia, second: secondMedia]
        let clips: [ClipRequest] = [.init(file: first), .init(file: second)]
        let choices = ExportContainerChoices(source: firstMedia, clips: clips, preferred: "mov", cancelled: { false })
        let panel = NSSavePanel()
        var options = ExportSheetOptions()
        options.tracks = .audio
        options.copyContainer = "mov"
        let control = ExportFormatControl(panel: panel, options: options, copyContainers: choices,
                                         clips: clips, media: media, changed: { options = $0; _ = $1 },
                                         directoryChanged: { _ in })
        defer { control.stopChecking() }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let picker = try XCTUnwrap(views(try XCTUnwrap(panel.accessoryView)).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Audio tracks" })
        picker.selectItem(at: 1)
        XCTAssertTrue(picker.sendAction(try XCTUnwrap(picker.action), to: picker.target))
        XCTAssertEqual(options.audioTrackOrdinal, 0)
        XCTAssertEqual(options.container, "wav")
        let deadline = ContinuousClock.now + .seconds(8)
        while control.selected == nil, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .packets(let edit, .copy, .audio) = control.selected else {
            return XCTFail("Audio-track preflight did not produce a copy plan.")
        }
        XCTAssertEqual(edit.segments.map { $0.tracks.map(\.index) }, [[1], [0]])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        func checkAudio(_ url: URL, sample: Int16, length: Int) throws {
            let sound = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
            XCTAssertEqual(sound.processingFormat.channelCount, 1)
            XCTAssertEqual(sound.length, Int64(length))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sound.processingFormat,
                                                     frameCapacity: AVAudioFrameCount(sound.length)))
            try sound.read(into: pcm)
            let channel = try XCTUnwrap(pcm.int16ChannelData?[0])
            XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength))),
                           Array(repeating: sample, count: length))
        }
        let output = directory.appendingPathComponent("Export.wav")
        try engine.export(edit, to: output)
        try checkAudio(output, sample: 4_096, length: 3_200)

        let editor = EditorModel()
        defer { editor.endSession() }
        editor.useAnalysisSidecars = false
        editor.preview.isMuted = true
        func waitForEditor() async throws {
            let limit = ContinuousClock.now + .seconds(8)
            while editor.isBusy, .now < limit { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(editor.canEdit, editor.alert?.message ?? editor.statusMessage)
        }
        editor.importFiles([first, second])
        try await waitForEditor()
        XCTAssertTrue(editor.isAudioOnly)
        XCTAssertEqual(editor.timelineClips.count, 2)
        editor.seek(0)
        editor.setIn()
        editor.seek(editor.duration)
        editor.setOut()
        editor.addMarkedRange()
        editor.seek(firstMedia.duration.seconds)
        editor.setIn()
        editor.seek(editor.duration)
        editor.setOut()
        editor.addMarkedRange()
        XCTAssertEqual(editor.queuedRanges.map { $0.clips.count }, [2, 1])
        editor.showBulkQueue()
        options.copyContainer = ""
        options.audioTrackOrdinal = 1
        editor.exportQueuedRanges(to: directory, options: options)
        try await waitForEditor()
        let stem = first.deletingPathExtension().lastPathComponent
        for (suffix, length) in [("001", 3_200), ("002", 1_600)] {
            let queuedOutput = directory.appendingPathComponent("\(stem)-\(suffix).wav")
            try checkAudio(queuedOutput, sample: 16_384, length: length)
        }

        let absolute = CutEngine(tracks: .audio, audioStream: 1)
        let absoluteEdit = try absolute.resolve(clips, media: media, container: "wav")
        XCTAssertEqual(absoluteEdit.segments.map { $0.tracks.map(\.index) }, [[1], [1]])
    }

    @MainActor
    func testTrackCheckboxesPrepareCopyOnlyPlansAndUpdateFilenames() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: "mov", subdirectory: "Fixtures"))
        let media = try CutEngine().inspect(file, keyframes: true)
        let choices = ExportContainerChoices(source: media, clips: [.init(file: file)], preferred: "mov", cancelled: { false })
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Edited.mov"
        var options = ExportSheetOptions()
        options.copyContainer = "mov"
        let control = ExportFormatControl(panel: panel, options: options, copyContainers: choices,
                                         clips: [.init(file: file)], media: [file: media],
                                         changed: { options = $0; _ = $1 }, directoryChanged: { _ in })
        defer { control.stopChecking() }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let buttons = views(try XCTUnwrap(panel.accessoryView)).compactMap { $0 as? NSButton }
        let video = try XCTUnwrap(buttons.first { $0.title == "Video" })
        let audio = try XCTUnwrap(buttons.first { $0.title == "Audio" })
        XCTAssertEqual(video.state, .on)
        XCTAssertEqual(audio.state, .on)
        video.performClick(nil)
        XCTAssertEqual(options.tracks, .audio)
        XCTAssertFalse(audio.isEnabled)
        XCTAssertEqual(options.effectiveMode, .copy)
        XCTAssertEqual(options.container, "m4a")
        XCTAssertEqual(panel.nameFieldStringValue, "Edited.m4a")
        let deadline = ContinuousClock.now + .seconds(8)
        while control.selected == nil, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .packets(let sound, .copy, .audio) = control.selected else {
            return XCTFail("Audio-only preflight did not produce a copy plan.")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent("Edited.m4a")
        try CutEngine().export(sound, to: output)
        let audioInfo = try CutEngine().inspect(output)
        XCTAssertFalse(audioInfo.hasVideo)
        XCTAssertEqual(audioInfo.audio.first?.stream.codec, "aac")
        video.performClick(nil)
        audio.performClick(nil)
        XCTAssertEqual(options.effectiveMode, .copy)
        XCTAssertEqual(options.tracks, .video)
        XCTAssertFalse(video.isEnabled)
        let videoDeadline = ContinuousClock.now + .seconds(8)
        while control.selected == nil, .now < videoDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .packets(let picture, .copy, .video) = control.selected else {
            return XCTFail("Video-only preflight did not produce a copy plan.")
        }
        let silent = scratch.appendingPathComponent("Edited." + options.container)
        try CutEngine().export(picture, to: silent)
        let videoInfo = try CutEngine().inspect(silent)
        XCTAssertTrue(videoInfo.hasVideo)
        XCTAssertTrue(videoInfo.audio.isEmpty)
    }

    @MainActor
    func testReplacementSheetTracksFollowTheSelectedFiles() throws {
        let engine = CutEngine()
        let original = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov", subdirectory: "Fixtures"))
        let processed = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let control = try ReplacementExportPanel(source: engine.inspectSummary(original), replacement: engine.inspectSummary(processed))
        defer { control.stopChecking() }
        let panel = NSSavePanel()
        control.attach(to: panel)
        XCTAssertEqual(control.targets.map(\.index), [1, 2])
        XCTAssertEqual(control.replacements.map(\.index), [1, 2])
        XCTAssertEqual(control.targetIndex, 1)
        XCTAssertEqual(control.replacementIndex, 1)
        XCTAssertNotNil(panel.accessoryView)
        XCTAssertEqual(panel.nameFieldStringValue, "Pause-Noisy Audio.mov")
        control.targetIndex = 2
        control.replacementIndex = 1
        control.container = "mov"
        XCTAssertNil(control.plan, "Changing track selections must invalidate any prior preflight.")
    }

    @MainActor
    func testWorkingSoundtrackFollowsSourceUsesAndUndo() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Noisy", withExtension: "mov", subdirectory: "Fixtures"))
        let donor = try XCTUnwrap(Bundle.module.url(forResource: "Pause-Quiet", withExtension: "mov", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("working.mov")
        let plan = try AudioReplacementEngine(useSidecar: false).resolve(source: source, replacement: donor, output: output)
        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([source, donor, source])
        func waitForWork() async throws {
            for _ in 0..<1000 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isBusy)
        }
        try await waitForWork()
        let ids = model.timelineClips.map(\.id)
        model.applyReplacement(plan, output: output, useSidecar: false)
        try await waitForWork()
        XCTAssertEqual(model.timelineClips.map(\.replacementAudio), [donor.lastPathComponent, nil, donor.lastPathComponent])
        XCTAssertEqual(model.timelineClips.map(\.id), ids)
        model.seek(0)
        let atStart = try XCTUnwrap(model.jpegSourceAtPlayhead)
        XCTAssertEqual(atStart.media.url.standardizedFileURL.path, output.standardizedFileURL.path)
        let frame = directory.appendingPathComponent("still.jpg")
        let picture = try XCTUnwrap(atStart.frame)
        try JPEGExport.writeStill(atStart.media, at: picture, to: frame)
        XCTAssertNotNil(NSImage(contentsOf: frame))
        let reference = directory.appendingPathComponent("reference")
        let expected = try JPEGExport.write(atStart.media, to: reference, selection: .times([picture]), preset: .full)
        let named = try XCTUnwrap(expected.frames.first?.file)
        XCTAssertEqual(try Data(contentsOf: frame), try Data(contentsOf: reference.appendingPathComponent(named)))
        model.undo()
        XCTAssertTrue(model.timelineClips.allSatisfy { $0.replacementAudio == nil })
        model.redo()
        XCTAssertEqual(model.timelineClips.first?.replacementAudio, donor.lastPathComponent)
    }

    @MainActor
    func testMonitorClosesIndependentlyAndReopensForTheProject() throws {
        _ = WindowTestHost.application
        let session = ProjectSession(id: UUID(), preferences: EditorPreferences())
        session.showMonitor()
        let first = try XCTUnwrap(session.monitor)
        XCTAssertTrue(first.isVisible)
        session.showMonitor()
        XCTAssertIdentical(first, session.monitor)
        first.close()
        XCTAssertNil(session.monitor)
        session.showMonitor()
        XCTAssertNotNil(session.monitor)
        session.end()
        XCTAssertNil(session.monitor)
    }

    @MainActor
    func testSilentMovieKeepsAllExportModesAvailable() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let source = try CutEngine().inspect(file, keyframes: true)
        XCTAssertTrue(source.hasVideo)
        XCTAssertTrue(source.audio.isEmpty)
        let clips: [ClipRequest] = [.init(file: file)]
        let choices = ExportContainerChoices(source: source, clips: clips, preferred: "mp4", cancelled: { false })
        let panel = NSSavePanel()
        let control = ExportFormatControl(panel: panel, options: .init(), copyContainers: choices, clips: clips,
                                         media: [file: source], changed: { _, _ in }, directoryChanged: { _ in })
        defer { control.stopChecking() }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let controls = views(try XCTUnwrap(panel.accessoryView))
        let mode = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Mode" })
        XCTAssertTrue(mode.isEnabled)
        XCTAssertEqual(mode.titleOfSelectedItem, ExportMode.smart.displayName)
        XCTAssertEqual(mode.itemTitles, [ExportMode.smart, .copy, .encode].map(\.displayName))
        let audio = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Audio" })
        XCTAssertEqual(audio.state, .off)
        XCTAssertFalse(audio.isEnabled)
    }

    func testExportPreflightHonorsSidecarReadPreference() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4", subdirectory: "Fixtures"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: file)
        let source = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        var sections = try AnalysisSidecar.indexSections(for: source)
        let data = try XCTUnwrap(sections["media_index.v1"])
        var header = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let advisory = "Synthetic copy restriction from the saved index."
        header["copy_issue"] = advisory
        sections["media_index.v1"] = try PropertyListSerialization.data(fromPropertyList: header, format: .binary, options: 0)
        try AnalysisSidecar(media: source).save(sections)
        let clips: [ClipRequest] = [.init(file: file)]
        guard case .unavailable(let reason, _) = ExportAvailability.check(.init(), clips: clips, media: [:]) else {
            return XCTFail("The export check did not use the saved index.")
        }
        XCTAssertTrue(reason.contains(advisory))
        guard case .ready(.packets(_, .smart, .all)) = ExportAvailability.check(.init(), clips: clips, media: [:], useSidecar: false) else {
            return XCTFail("The export check did not bypass the saved index.")
        }
    }

    @MainActor
    func testSelectionExportReviewCannotApplyPartialCutsToTimeline() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                   subdirectory: "Fixtures"))
        let media = try CutEngine().inspect(file, keyframes: true)
        let clips = [ClipRequest(file: file, from: RationalTime(numerator: 7, denominator: 25), to: media.duration)]
        var options = ExportSheetOptions()
        options.mode = .copy
        options.copyContainer = "mp4"
        let panel = NSSavePanel()
        let choices = ExportContainerChoices(source: media, clips: clips, preferred: "mp4", cancelled: { false })
        let control = ExportFormatControl(panel: panel, options: options, copyContainers: choices,
                                         clips: clips, media: [file: media], allowsApplyingReviewToTimeline: false,
                                         changed: { _, _ in }, directoryChanged: { _ in })
        defer { control.stopChecking() }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let buttons = views(try XCTUnwrap(panel.accessoryView)).compactMap { $0 as? NSButton }
        let review = try XCTUnwrap(buttons.first { $0.title == "Review Cuts…" })
        let apply = try XCTUnwrap(buttons.first { $0.title == "Apply to Timeline" })
        let deadline = ContinuousClock.now + .seconds(5)
        while review.isHidden, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(review.isHidden)
        review.performClick(nil)
        XCTAssertTrue(apply.isHidden)
        apply.performClick(nil)
        XCTAssertNil(control.appliedReview)
    }

    @MainActor
    func testReviewedCopyBoundsApplyAsOneUndoableEdit() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SmartTrim-GOP", withExtension: "mp4",
                                                  subdirectory: "Fixtures"))
        let engine = CutEngine()
        let media = try engine.inspect(url, keyframes: true)
        let unsafeStart = RationalTime(numerator: 7, denominator: 25)
        let sourceRequest = ClipRequest(file: url, from: unsafeStart, to: media.duration)
        let indexed = [url: media]
        let snapped = try engine.resolve([sourceRequest], snap: .nearest, media: indexed, container: "mp4")
        let review = try XCTUnwrap(ExportCutReview(original: [sourceRequest], snapped: snapped, media: indexed,
                                                   engine: engine, cancelled: { false }))
        XCTAssertEqual(review.revised.first?.from, .zero)
        XCTAssertNotEqual(review.original.first?.from, review.revised.first?.from)
        XCTAssertTrue(review.detail.contains("Total duration change: +"))

        let model = EditorModel()
        defer { model.endSession() }
        model.importFiles([url])
        for _ in 0..<500 where model.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try XCTUnwrap(model.selectedID)
        model.trim(id, edge: .start, sourceTime: unsafeStart.seconds, commit: true)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, unsafeStart.seconds)
        model.applyExportReview(review)
        XCTAssertEqual(model.timelineClips.first?.id, id)
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0)
        model.undo()
        XCTAssertEqual(model.timelineClips.first?.sourceStart, unsafeStart.seconds)
        model.redo()
        XCTAssertEqual(model.timelineClips.first?.sourceStart, 0)
    }
}
