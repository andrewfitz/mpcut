import AppKit
import AVFoundation
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

final class VideoMonitorTests: XCTestCase {
    private struct PreviewTimedOut: Error {}

    @MainActor
    func testOrdinaryMonitorSharesFramesAndClosingKeepsPlaybackRunning() async throws {
        _ = NSApplication.shared
        for (name, ext) in [("Shuttle-Chirp", "mov"), ("WebM-Opus-GOP", "webm")] {
            let session = ProjectSession(id: UUID(), preferences: EditorPreferences())
            defer { session.end() }
            let media = try fixture(name, ext)
            let preview = session.editor.preview
            preview.isMuted = true
            let editor = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            editor.isReleasedWhenClosed = false
            editor.contentView = NSHostingView(rootView: PreviewView(preview: preview))
            editor.orderFront(nil)
            defer { editor.close() }
            session.window = editor
            preview.update([PreviewRange(url: media, exactStart: .zero, exactEnd: .init(numerator: 2))], at: 0.4)

            session.showMonitor()
            let monitor = try XCTUnwrap(session.monitor)
            XCTAssertEqual((monitor as? NSPanel)?.becomesKeyOnlyIfNeeded, true)
            XCTAssertFalse(monitor.canBecomeMain)
            XCTAssertTrue(monitor.collectionBehavior.contains(.fullScreenPrimary))
            session.showMonitor()
            XCTAssertTrue(session.monitor === monitor)

            try await wait { self.surface(in: monitor.contentView)?.displayedFrameTime != nil }
            let surface = try XCTUnwrap(surface(in: monitor.contentView))
            preview.seek(to: 0.8)
            try await wait { (surface.displayedFrameTime?.seconds ?? 0) > 0.5 }
            XCTAssertEqual(self.surface(in: editor.contentView)?.displayedFrameTime, surface.displayedFrameTime)

            try await wait {
                if !preview.isPlaying { preview.togglePlayback() }
                return preview.isPlaying
            }
            try await wait { preview.time > 0.8 }
            monitor.performClose(nil)
            XCTAssertNil(session.monitor)
            XCTAssertNil(monitor.contentView)
            XCTAssertNil(surface.displayedFrameTime)
            XCTAssertTrue(preview.isPlaying)

            session.showMonitor()
            let reopened = try XCTUnwrap(session.monitor)
            XCTAssertFalse(reopened === monitor)
            try await wait { self.surface(in: reopened.contentView)?.displayedFrameTime != nil }
            let missing = PreviewRange(url: media.appendingPathExtension("missing"), exactStart: .zero,
                                       exactEnd: .init(numerator: 2))
            preview.audition(missing, at: 0.5)
            try await wait { preview.issue != nil }
            XCTAssertNil(self.surface(in: reopened.contentView)?.displayedFrameTime)
            XCTAssertNil(self.surface(in: editor.contentView)?.displayedFrameTime)
            preview.update([], at: 0)
            session.end()
            XCTAssertNil(session.monitor)
            XCTAssertFalse(reopened.isVisible)
        }
    }

    @MainActor
    func testExistingMonitorSwitchesModesAndClearsAnUncoveredMulticamPicture() async throws {
        _ = NSApplication.shared
        let session = ProjectSession(id: UUID(), preferences: EditorPreferences())
        defer { session.end() }
        let engine = CutEngine(useSidecar: false)
        let wide = try engine.inspect(fixture("SmartTrim-GOP", "mp4"), keyframes: true)
        let close = try engine.inspect(fixture("WebM-Opus-GOP", "webm"), keyframes: true)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 1)),
                                      angles: [.init(id: "wide", file: wide.url.path),
                                               .init(id: "close", file: close.url.path, offset: .init(numerator: 1, denominator: 2))],
                                      audio: .none, switches: [.init(at: .zero, angle: "wide"),
                                                               .init(at: .init(numerator: 1, denominator: 4), angle: "close")])
        session.showMonitor()
        let monitor = try XCTUnwrap(session.monitor)
        try await wait { self.surface(in: monitor.contentView) != nil }
        let ordinary = try XCTUnwrap(surface(in: monitor.contentView))

        session.multicam.preview.configure(plan: try project.plan(), media: ["wide": wide, "close": close])
        try await wait { session.multicam.preview.displayedFrameTime != nil }
        session.isMulticam = true
        try await wait { self.surface(in: monitor.contentView)?.displayedFrameTime != nil }
        let multicam = try XCTUnwrap(surface(in: monitor.contentView))
        XCTAssertFalse(multicam === ordinary)
        XCTAssertEqual(multicam.displayedFrameTime, session.multicam.preview.displayedFrameTime)

        session.multicam.preview.seek(to: .init(numerator: 3, denominator: 8))
        XCTAssertNil(multicam.displayedFrameTime)
        session.multicam.preview.seek(to: .init(numerator: 3, denominator: 4))
        try await wait { multicam.displayedFrameTime != nil && session.multicam.preview.picture?.source == "close" }
        session.isMulticam = false
        try await wait { self.surface(in: monitor.contentView).map { $0 !== multicam } == true }
        XCTAssertNil(surface(in: monitor.contentView)?.displayedFrameTime)
        XCTAssertNil(multicam.displayedFrameTime)
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    @MainActor
    private func surface(in view: NSView?) -> PreviewSurface? {
        guard let view else { return nil }
        if let surface = view as? PreviewSurface { return surface }
        return view.subviews.lazy.compactMap { self.surface(in: $0) }.first
    }

    @MainActor
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard ready() else {
            XCTFail("Timed out waiting for preview.", file: file, line: line)
            throw PreviewTimedOut()
        }
    }
}
