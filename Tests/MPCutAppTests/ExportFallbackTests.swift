import AppKit
import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

/// The export sheet offers the next export that works when the selected mode cannot write the timeline.
final class ExportFallbackTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"] == nil else { return }
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/mpcut-ffmpeg/install/bin/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: helper.path) { setenv("MPCUT_FFMPEG_HELPER", helper.path, 1) }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundled = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        let copy = scratch.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: bundled, to: copy)
        return copy.standardizedFileURL
    }

    private func time(_ numerator: Int64, _ denominator: Int64) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    @MainActor
    private final class Sheet {
        let panel = NSSavePanel()
        var options: ExportSheetOptions
        private(set) var control: ExportFormatControl!

        init(_ options: ExportSheetOptions, clips: [ClipRequest], media: MediaInfo, name: String) {
            self.options = options
            panel.nameFieldStringValue = name
            let choices = ExportContainerChoices(source: media, clips: clips, preferred: nil, cancelled: { false })
            control = ExportFormatControl(panel: panel, options: options, copyContainers: choices, clips: clips,
                                          media: [media.url: media], useSidecar: false,
                                          changed: { [unowned self] options, _ in self.options = options },
                                          directoryChanged: { _ in })
        }

        private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        var buttons: [NSButton] { views(panel.accessoryView!).compactMap { $0 as? NSButton } }
        func picker(_ label: String) -> NSPopUpButton? {
            views(panel.accessoryView!).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label }
        }

        /// Waits for the availability check, and for the search for an alternative when the export is unavailable.
        func settle() async throws {
            let limit = ContinuousClock.now + .seconds(20)
            while control.selected == nil, !control.isUnavailable, .now < limit { try await Task.sleep(for: .milliseconds(10)) }
            guard control.isUnavailable else { return }
            while control.fallback == nil, .now < limit { try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private func samples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let count = Int(buffer.frameLength) * Int(file.processingFormat.channelCount)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.int16ChannelData?[0]), count: count))
    }

    /// Decodes clips of a source to WAV through the sample-exact conversion.
    private func decoded(_ clips: [ClipRequest], named name: String) throws -> [Int16] {
        let wave = scratch.appendingPathComponent(name + ".wav")
        let engine = AudioExportEngine(useSidecar: false)
        try engine.write(engine.resolve(clips, output: wave, audio: .pcm), to: wave)
        return try samples(wave)
    }

    @MainActor
    func testMP3JoinOffersSameFormatConversionAndExportsTheKeptAudio() async throws {
        _ = NSApplication.shared
        let file = try fixture("Gapless-Crop", "mp3")
        let media = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        let clips = [ClipRequest(file: file, from: time(1, 10), to: time(3, 10)),
                     ClipRequest(file: file, from: time(1, 2), to: time(7, 10))]
        var options = ExportSheetOptions()
        options.tracks = .audio
        options.copyContainer = "mp3"
        let sheet = Sheet(options, clips: clips, media: media, name: "Edit.mp3")
        defer { sheet.control.stopChecking() }
        try await sheet.settle()

        XCTAssertTrue(sheet.control.isUnavailable)
        XCTAssertNil(sheet.control.selected)
        let offer = try XCTUnwrap(sheet.control.fallback)
        XCTAssertEqual(offer.title, "Convert to MP3 (same format)")
        // The alternative is offered. Nothing switches until it is chosen.
        XCTAssertEqual(sheet.options.effectiveMode, .copy)
        XCTAssertEqual(sheet.panel.nameFieldStringValue, "Edit.mp3")
        let mode = try XCTUnwrap(sheet.picker("Mode"))
        XCTAssertTrue(mode.isEnabled)
        XCTAssertEqual(mode.itemTitles, ["Lossless Copy", "Convert Audio"])
        XCTAssertEqual(mode.titleOfSelectedItem, "Lossless Copy")
        let button = try XCTUnwrap(sheet.buttons.first { $0.title == offer.title })
        XCTAssertFalse(button.isHidden)
        XCTAssertThrowsError(try sheet.control.panel(sheet.panel, validate: scratch.appendingPathComponent("Edit.mp3")))

        button.performClick(nil)
        XCTAssertTrue(sheet.options.convertsAudio)
        XCTAssertEqual(sheet.options.audioFormat, .mp3)
        XCTAssertEqual(sheet.options.container, "mp3")
        XCTAssertEqual(sheet.panel.nameFieldStringValue, "Edit.mp3")
        XCTAssertEqual(mode.titleOfSelectedItem, "Convert Audio")
        try await sheet.settle()
        guard case .audio(let plan) = sheet.control.selected else { return XCTFail("The conversion was not prepared.") }
        XCTAssertNil(sheet.control.fallback)
        XCTAssertTrue(button.isHidden)
        XCTAssertEqual(plan.action, .mp3)
        XCTAssertEqual(plan.sampleRate, media.audio[0].stream.sampleRate)
        XCTAssertEqual(plan.channels, media.audio[0].stream.channels)

        let output = scratch.appendingPathComponent("Edit.mp3")
        try sheet.control.panel(sheet.panel, validate: output)
        try AudioExportEngine().write(plan, to: output)
        let written = try CutEngine(useSidecar: false).inspect(output)
        XCTAssertEqual(written.audio.first?.stream.codec, "mp3")
        XCTAssertEqual(written.duration, plan.edit.duration)
        let expected = try decoded(clips, named: "expected")
        let actual = try decoded([ClipRequest(file: output)], named: "actual")
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(actual.count, Int(try plan.edit.duration.multiplied(by: time(Int64(plan.sampleRate), 1)).seconds) * plan.channels)
        let power = expected.reduce(0.0) { $0 + Double($1) * Double($1) }
        let noise = zip(actual, expected).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) }
        XCTAssertGreaterThan(power, 0)
        // This noisy 64 kb/s fixture has error power around 30% after a reference
        // LAME encode. A one-sample displacement raises it above 130%.
        XCTAssertLessThan(noise, 0.5 * power, "The converted MP3 does not match the kept source audio.")

        // A format that changes the extension renames the destination, which is validated again.
        let format = try XCTUnwrap(sheet.picker("Audio"))
        XCTAssertEqual(format.titleOfSelectedItem, "MP3")
        format.selectItem(withTitle: "PCM")
        XCTAssertTrue(format.sendAction(try XCTUnwrap(format.action), to: format.target))
        XCTAssertEqual(sheet.options.container, "wav")
        XCTAssertEqual(sheet.panel.nameFieldStringValue, "Edit.wav")
        XCTAssertEqual(try XCTUnwrap(sheet.picker("Container")).itemTitles.first, containerDisplayName("wav"))
        try await sheet.settle()
        guard case .audio(let wave) = sheet.control.selected else { return XCTFail("PCM conversion was not prepared.") }
        XCTAssertEqual(wave.action, .pcm)
        XCTAssertNotNil(wave.estimatedBytes)
        XCTAssertThrowsError(try sheet.control.panel(sheet.panel, validate: output)) { error in
            XCTAssertEqual((error as? CutError)?.code, "unsupported_container")
        }
        let taken = scratch.appendingPathComponent("expected.wav")
        XCTAssertThrowsError(try sheet.control.panel(sheet.panel, validate: taken)) { error in
            XCTAssertEqual((error as? CutError)?.code, "output_exists")
        }
        try sheet.control.panel(sheet.panel, validate: scratch.appendingPathComponent("Edit.wav"))
    }

    @MainActor
    func testContiguousMP3RangeDefaultsToLosslessCopyWithoutAnOffer() async throws {
        _ = NSApplication.shared
        let file = try fixture("Gapless-Crop", "mp3")
        let media = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        let clips = [ClipRequest(file: file, from: .zero, to: media.duration)]
        var options = ExportSheetOptions()
        options.tracks = .audio
        options.copyContainer = "mp3"
        let sheet = Sheet(options, clips: clips, media: media, name: "Edit.mp3")
        defer { sheet.control.stopChecking() }
        try await sheet.settle()
        guard case .packets(_, .copy, .audio) = sheet.control.selected else {
            return XCTFail("A contiguous MP3 range should copy.")
        }
        XCTAssertFalse(sheet.control.isUnavailable)
        XCTAssertNil(sheet.control.fallback)
        XCTAssertEqual(sheet.options.effectiveMode, .copy)
        XCTAssertEqual(sheet.picker("Mode")?.titleOfSelectedItem, "Lossless Copy")
        XCTAssertTrue(sheet.buttons.filter { $0.title.hasPrefix("Convert") || $0.title.hasPrefix("Use") }.allSatisfy(\.isHidden))
    }

    @MainActor
    func testMovieWithAnUnsafeCopyCutIsOfferedSmartTrim() async throws {
        _ = NSApplication.shared
        let file = try fixture("SmartTrim-GOP", "mp4")
        let media = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
        let clips = [ClipRequest(file: file, from: time(7, 25), to: media.duration)]
        var options = ExportSheetOptions()
        options.mode = .copy
        options.copyContainer = "mp4"
        let sheet = Sheet(options, clips: clips, media: media, name: "Edit.mp4")
        defer { sheet.control.stopChecking() }
        try await sheet.settle()
        XCTAssertTrue(sheet.control.isUnavailable)
        let offer = try XCTUnwrap(sheet.control.fallback)
        XCTAssertTrue(offer.title.hasPrefix("Use Smart Trim"), offer.title)
        XCTAssertEqual(sheet.options.mode, .copy)
        let button = try XCTUnwrap(sheet.buttons.first { $0.title == offer.title })
        XCTAssertFalse(button.isHidden)
        button.performClick(nil)
        XCTAssertEqual(sheet.options.mode, .smart)
        XCTAssertEqual(sheet.picker("Mode")?.titleOfSelectedItem, ExportMode.smart.displayName)
        try await sheet.settle()
        guard case .packets(_, .smart, .all) = sheet.control.selected else {
            return XCTFail("Smart Trim was not prepared.")
        }
        XCTAssertEqual(sheet.panel.nameFieldStringValue, "Edit.mp4")
    }

    func testLadderPrefersExactCopyThenSameFormatThenPCM() throws {
        // FLAC: Matroska carries whole copied frames, so no conversion is offered ahead of it.
        let mp3 = try fixture("Gapless-Crop", "mp3")
        let flac = scratch.appendingPathComponent("Tone.flac")
        let converter = AudioExportEngine(useSidecar: false)
        try converter.write(converter.resolve([ClipRequest(file: mp3)], output: flac, audio: .flac), to: flac)
        func offer(_ file: URL, _ container: String, packetAligned: Bool = false) throws -> ExportFallback? {
            let media = try CutEngine(useSidecar: false).inspect(file, keyframes: true)
            var cuts = [(time(1, 10), time(3, 10)), (time(1, 2), time(7, 10))]
            if packetAligned {
                let edges = CutEngine(useSidecar: false, tracks: .audio).validBoundaries(in: media, start: true)
                guard edges.count > 4 else {
                    XCTFail("The FLAC fixture needs five packet boundaries for two disjoint ranges.")
                    return nil
                }
                cuts = [(edges[1], edges[2]), (edges[3], edges[4])]
            }
            let clips = cuts.map { ClipRequest(file: file, from: $0.0, to: $0.1) }
            var options = ExportSheetOptions()
            options.tracks = .audio
            options.copyContainer = container
            guard case .unavailable = ExportAvailability.check(options, clips: clips, media: [file: media], useSidecar: false) else {
                XCTFail("\(file.lastPathComponent) should not export to \(options.container) with these cuts.")
                return nil
            }
            let choices = ExportContainerChoices(source: media, clips: clips, preferred: nil, cancelled: { false })
            return ExportFallback.find(after: options, clips: clips, media: [file: media], containers: choices, useSidecar: false)
        }
        let lossless = try XCTUnwrap(try offer(flac, "flac", packetAligned: true))
        XCTAssertEqual(lossless.title, "Copy to \(ExportRules.containerDisplayName("mka")) (lossless)")
        XCTAssertEqual(ExportRules.containerDisplayName("mka"), "Matroska Audio (.mka)")
        XCTAssertEqual(lossless.options.effectiveMode, .copy)
        XCTAssertEqual(lossless.options.container, "mka")
        // Cuts inside FLAC frames cannot be copied. Re-encoding FLAC returns the same samples.
        let encoded = try XCTUnwrap(try offer(flac, "flac"))
        XCTAssertEqual(encoded.title, "Convert to FLAC (same format, lossless)")
        XCTAssertEqual(encoded.options.audioFormat, .flac)
        XCTAssertEqual(encoded.options.container, "flac")

        // No container joins copied Opus packets. Encoding Opus again keeps the format, in the container the sheet names.
        let opus = try fixture("Standalone-Chirp", "opus")
        let same = try XCTUnwrap(try offer(opus, "opus"))
        XCTAssertEqual(same.title, "Convert to Opus (same format)")
        XCTAssertEqual(same.options.audioFormat, .opus)
        XCTAssertEqual(same.options.container, "opus")
        let matroska = try XCTUnwrap(try offer(opus, "mka"))
        XCTAssertEqual(matroska.title, "Convert to Opus (same format)")
        XCTAssertEqual(matroska.options.container, "mka")
    }
}
