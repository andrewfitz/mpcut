import AppKit
import Combine
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// The Time display setting in both editors. Every preference store here is unpersisted
/// (`EditorPreferences(defaults: nil)`) and every draft folder is temporary.
@MainActor
final class SettingsTimeDisplayWiringTests: XCTestCase {
    private struct TimedOut: Error {}

    private let thirty = RationalTime(numerator: 1, denominator: 30)
    private let pal = RationalTime(numerator: 1, denominator: 25)
    private let ntsc = RationalTime(numerator: 1001, denominator: 30_000)
    private let film = RationalTime(numerator: 1001, denominator: 24_000)

    private func frames(_ cadence: RationalTime?) -> TimelineTimeFormat {
        TimelineTimeFormat(display: .frames, cadence: cadence)
    }

    private func preferences() -> EditorPreferences {
        let preferences = EditorPreferences(defaults: nil)
        preferences.useAnalysisSidecars = false
        return preferences
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func fixture(_ name: String, _ ext: String = "mov") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func wait(_ label: String, seconds: Int = 15, file: StaticString = #filePath, line: UInt = #line,
                      _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard ready() else {
            XCTFail("Timed out waiting for \(label).", file: file, line: line)
            throw TimedOut()
        }
    }

    private func sequence(_ name: String, _ ext: String = "mov") async throws -> EditorModel {
        let model = EditorModel(preferences: preferences(), draft: ProjectDraft(directory: try temporaryFolder()))
        model.importFiles([try fixture(name, ext)])
        try await wait("\(name) imported") { !model.isBusy && !model.isEmpty }
        return model
    }

    private func multicam(_ angles: [(id: String, fixture: String, ext: String)],
                          preferences supplied: EditorPreferences? = nil) throws -> MulticamEditorModel {
        let model = MulticamEditorModel(preferences: supplied ?? preferences(), draft: ProjectDraft(directory: try temporaryFolder()))
        let drafts = try angles.map { angle in
            let url = try fixture(angle.fixture, angle.ext)
            return MulticamEditorModel.SourceDraft(source: .init(id: angle.id, file: url.path),
                                       media: try CutEngine(useSidecar: false).inspectMulticamSource(url))
        }
        model.confirmSetup(drafts: drafts, opening: angles[0].id, audio: .none)
        return model
    }

    // MARK: Formatting

    func testMillisecondsProducesTodaysStrings() {
        let samples: [Double] = [0, 0.0004, 0.0005, 0.033, 1.5, 59.999, 61.25, 3_599.999_6, 3_600, 7_384.123, -2, .nan]
        let factory = EditorPreferences(defaults: nil)
        XCTAssertEqual(factory.timeDisplay, .milliseconds)
        for cadence in [nil, thirty, pal, ntsc, film] {
            let format = TimelineTimeFormat(display: factory.timeDisplay, cadence: cadence)
            XCTAssertNil(format.frameCadence)
            for seconds in samples {
                XCTAssertEqual(format.string(seconds), timelineTime(seconds, milliseconds: true), "\(seconds)")
            }
            for scale in [0.01, 0.5, 3, 40, 86, 200, 900, 5_000, 90_000] as [CGFloat] {
                let step = format.rulerStep(scale: scale)
                XCTAssertEqual(step, timelineRulerStep(scale: scale))
                for time in [0, step * 5, step * 37] {
                    XCTAssertEqual(format.rulerLabel(time, step: step), timelineTime(time, milliseconds: step < 1))
                }
            }
        }
        XCTAssertEqual(TimelineTimeFormat.milliseconds, TimelineTimeFormat(display: .milliseconds, cadence: nil))
    }

    func testFramesShowsFramesAtFourCadencesAndMillisecondsWithoutOne() throws {
        XCTAssertEqual(frames(thirty).string(1.5), "00:01:15")
        XCTAssertEqual(frames(thirty).string(61 + 29.0 / 30), "01:01:29")
        XCTAssertEqual(frames(pal).string(1.5), "00:01:12")
        XCTAssertEqual(frames(pal).string(59.96), "00:59:24")
        // Frame 45 at 29.97 starts at 1.5015 s; at 23.976 frame 36 starts at 1.5015 s too.
        XCTAssertEqual(frames(ntsc).string(try ntsc.multiplied(by: RationalTime(numerator: 45)).seconds), "00:01:15")
        XCTAssertEqual(frames(film).string(try film.multiplied(by: RationalTime(numerator: 36)).seconds), "00:01:12")
        XCTAssertEqual(frames(film).string(3_600 * 1.001), "1:00:00:00")
        // Audio-only and unknown cadences fall back to milliseconds.
        for seconds in [0, 1.5, 3_700.25] {
            XCTAssertEqual(frames(nil).string(seconds), timelineTime(seconds, milliseconds: true))
            XCTAssertNil(frames(nil).frameCadence)
        }
    }

    func testPlayheadFieldReadsFramesAndRefusesAnInvalidFrame() throws {
        func parse(_ text: String, _ format: TimelineTimeFormat, initial: Double = 0) -> Double? {
            TimelineTimeControl.parseTime(text, initialTime: initial, format: format)
        }
        XCTAssertEqual(try XCTUnwrap(parse("00:01:15", frames(thirty))), 1.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(parse(" 1:00:00:00 ", frames(thirty))), 3_600, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(parse("00:01:12", frames(pal))), 1.48, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(parse("00:01:15", frames(ntsc))), 45 * 1001 / 30_000.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(parse("00:01:12", frames(film))), 36 * 1001 / 24_000.0, accuracy: 1e-9)
        // An invalid frame is refused, as an invalid entry is today, rather than read as hours.
        XCTAssertNil(parse("00:01:30", frames(thirty)))
        XCTAssertNil(parse("00:01:25", frames(pal)))
        XCTAssertNil(parse("00:61:00", frames(thirty)))
        XCTAssertNil(parse("00::00", frames(thirty)))
        XCTAssertNil(parse("1:2:3:4:5", frames(thirty)))
        XCTAssertNil(parse("abc", frames(thirty)))
        XCTAssertNil(parse("abc", .milliseconds))
        // Today's forms still read the same way in Frames mode.
        for text in ["12.5", "01:02.500", "1:01:02.5", "0", "25:34:56.789"] {
            XCTAssertEqual(parse(text, frames(thirty)), parse(text, .milliseconds), text)
            XCTAssertNotNil(parse(text, frames(thirty)), text)
        }
        // Return on the untouched field keeps the exact playhead.
        let inside = 1.517
        XCTAssertEqual(frames(thirty).string(inside), "00:01:15")
        XCTAssertEqual(parse("00:01:15", frames(thirty), initial: inside), inside)
        XCTAssertEqual(parse(timelineTime(inside, milliseconds: true), .milliseconds, initial: inside), inside)
        // Without a cadence the field reads entries exactly as milliseconds does: three fields are H:MM:SS.
        XCTAssertEqual(parse("00:01:15", frames(nil)), 75)
        XCTAssertEqual(parse("00:01:15", .milliseconds), 75)
        // The default argument keeps today's parser for existing callers.
        XCTAssertEqual(TimelineTimeControl.parseTime("00:01:15", initialTime: 0), 75)
        XCTAssertEqual(SequenceTimeline.parseTime("00:00.034", initialTime: 0), 0.034)
    }

    func testRulerLabelsInFramesLandOnWholeFrames() throws {
        for cadence in [thirty, pal, ntsc, film] {
            let format = frames(cadence)
            let rate = try XCTUnwrap(TimelineTimeDisplay.nominalRate(cadence))
            for scale in [40, 120, 300, 900, 3_000, 20_000, 200_000] as [CGFloat] {
                let step = format.rulerStep(scale: scale)
                if timelineRulerStep(scale: scale) >= 1 {
                    XCTAssertEqual(step, timelineRulerStep(scale: scale))
                    XCTAssertEqual(format.rulerLabel(step * 3, step: step), timelineTime(step * 3))
                    continue
                }
                if step == 1 { continue }
                let count = Int((step / cadence.seconds).rounded())
                XCTAssertEqual(step, Double(count) * cadence.seconds, accuracy: 1e-12)
                XCTAssertTrue(rate.isMultiple(of: count), "\(count) frames at \(rate)")
                XCTAssertGreaterThanOrEqual(Double(count) + 1e-9, 86 / Double(scale) / cadence.seconds)
                for major in 1...40 {
                    let label = format.rulerLabel(Double(major) * step, step: step)
                    let frame = major * count
                    let expected = String(format: "%02ld:%02ld:%02ld", frame / rate / 60, frame / rate % 60, frame % rate)
                    XCTAssertEqual(label, expected)
                }
            }
        }
        // One frame apart at full zoom, at most one label a frame.
        XCTAssertEqual(frames(thirty).rulerStep(scale: 1_000_000), thirty.seconds, accuracy: 1e-12)
        // 25 fps has no whole-frame step between 5 frames and a second.
        XCTAssertEqual(frames(pal).rulerStep(scale: 86 / 0.3), 1)
    }

    // MARK: Sequence editor

    func testSequenceReadOutsFollowTheSettingLive() async throws {
        let model = try await sequence("ProRes-2997")
        defer { model.endSession() }
        XCTAssertEqual(model.timelineTimeFormat, .milliseconds)
        var changes = 0
        let watcher = model.objectWillChange.sink { _ in changes += 1 }
        defer { watcher.cancel() }

        model.preferences.timeDisplay = .frames
        XCTAssertGreaterThan(changes, 0, "An open window redraws when the setting changes.")
        XCTAssertEqual(model.timelineTimeFormat.frameCadence, ntsc)
        XCTAssertEqual(model.timelineTimeFormat.string(45 * 1001 / 30_000.0), "00:01:15")

        changes = 0
        model.preferences.timeDisplay = .milliseconds
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(model.timelineTimeFormat, .milliseconds)
        XCTAssertEqual(model.timelineTimeFormat.string(1.5), "00:01.500")
    }

    func testAudioOnlyAndVariableRateSequencesStayInMilliseconds() async throws {
        for (name, ext) in [("Covered-Audio", "mp3"), ("VFR-PTS", "mp4")] {
            let model = try await sequence(name, ext)
            defer { model.endSession() }
            model.preferences.timeDisplay = .frames
            XCTAssertNil(model.timelineTimeFormat.frameCadence, name)
            XCTAssertEqual(model.timelineTimeFormat.string(1.5), "00:01.500", name)
        }
    }

    func testOpenSequenceWindowRedrawsItsTimelineWhenTheSettingChanges() async throws {
        _ = WindowTestHost.application
        let editor = try await sequence("ProRes-2997")
        defer { editor.endSession() }
        let multicam = MulticamEditorModel(preferences: editor.preferences, draft: ProjectDraft(directory: try temporaryFolder()))
        defer { multicam.reset() }
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 900, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        editor.preview.isMuted = true
        window.contentView = NSHostingView(rootView: EditorView(editor: editor, multicam: multicam,
                                                                presentation: EditorPresentation(), addMulticam: {}))
        window.orderFront(nil)
        var surface: TimelineSurface?
        try await wait("sequence timeline") {
            surface = descendant(TimelineSurface.self, in: window.contentView) { $0.timeline != nil }
            return surface != nil
        }
        XCTAssertEqual(surface?.timeline?.timeFormat, .milliseconds)
        editor.preferences.timeDisplay = .frames
        try await wait("frames on the open timeline") { surface?.timeline?.timeFormat.frameCadence == self.ntsc }
        editor.preferences.timeDisplay = .milliseconds
        try await wait("milliseconds on the open timeline") { surface?.timeline?.timeFormat == .milliseconds }
    }

    // MARK: Multicam editor

    func testMulticamReadOutsFollowTheSettingLive() throws {
        let model = try multicam([("wide", "ProRes-2997", "mov")])
        defer { model.reset() }
        XCTAssertEqual(model.timelineTimeFormat, .milliseconds)
        var changes = 0
        let watcher = model.objectWillChange.sink { _ in changes += 1 }
        defer { watcher.cancel() }

        model.preferences.timeDisplay = .frames
        XCTAssertGreaterThan(changes, 0, "An open window redraws when the setting changes.")
        XCTAssertEqual(model.timelineTimeFormat.frameCadence, ntsc)
        XCTAssertEqual(model.timelineTimeFormat.string(45 * 1001 / 30_000.0), "00:01:15")

        changes = 0
        model.preferences.timeDisplay = .milliseconds
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(model.timelineTimeFormat, .milliseconds)
    }

    func testMulticamAnglesAtDifferentRatesStayInMilliseconds() throws {
        let preferences = preferences()
        preferences.timeDisplay = .frames
        let same = try multicam([("wide", "ProRes-2997", "mov"), ("close", "ProRes-2997", "mov")], preferences: preferences)
        defer { same.reset() }
        XCTAssertEqual(same.timelineTimeFormat.frameCadence, ntsc)
        let mixed = try multicam([("wide", "ProRes-2997", "mov"), ("fast", "Playback-120", "mp4")], preferences: preferences)
        defer { mixed.reset() }
        XCTAssertNil(mixed.timelineTimeFormat.frameCadence)
        XCTAssertEqual(mixed.timelineTimeFormat.string(1.5), "00:01.500")
    }

    func testOpenMulticamAssemblyRedrawsWhenTheSettingChanges() async throws {
        _ = WindowTestHost.application
        let model = try multicam([("wide", "ProRes-2997", "mov")])
        defer { model.reset() }
        model.preview.isMuted = true
        model.setAssemblyPreview(true)
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 900, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: MulticamEditorView(model: model, presentation: EditorPresentation()))
        window.orderFront(nil)
        var surface: TimelineSurface?
        try await wait("assembly timeline") {
            surface = descendant(TimelineSurface.self, in: window.contentView) { $0.timeline != nil }
            return surface != nil
        }
        XCTAssertEqual(surface?.timeline?.timeFormat, .milliseconds)
        model.preferences.timeDisplay = .frames
        try await wait("frames on the open assembly") { surface?.timeline?.timeFormat.frameCadence == self.ntsc }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView?, where matches: (T) -> Bool) -> T? {
        guard let view else { return nil }
        if let element = view as? T, matches(element) { return element }
        for child in view.subviews {
            if let element = descendant(type, in: child, where: matches) { return element }
        }
        return nil
    }
}
