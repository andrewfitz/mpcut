import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import MPCutApp

@MainActor
final class StillTimelineWindowTests: XCTestCase {
    private struct PreviewTimedOut: Error {}

    func testOrdinaryWindowAndMonitorShareStillFrameDuringPlayback() async throws {
        try await exerciseWindow(multicam: false)
    }

    func testMulticamWindowAndMonitorShareStillFrameDuringPlayback() async throws {
        try await exerciseWindow(multicam: true)
    }

    private func exerciseWindow(multicam: Bool) async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let card = directory.appendingPathComponent("Card.png")
        try writeCard(card)
        let source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                     subdirectory: "Fixtures"))
        let cadence = try RationalTime(parsing: "1001/30000")
        let boundary = try RationalTime(parsing: "1001/10000")
        let sourceEnd = try RationalTime(parsing: "1001/2500")
        let color = StillProgramColorPolicy(transfer: "smpte2084", primaries: "bt2020", matrix: "bt2020nc",
                                            range: "tv", viewingConditions: "Rec.2100 reference",
                                            diffuseWhiteNits: 203)

        let suite = "MPCut.StillWindow.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        preferences.useAnalysisSidecars = false
        preferences.historyLimit = 10
        preferences.defaultExportMode = .copy
        preferences.warnBeforeLoweringExportTier = false
        let sessions = ProjectSessions(preferences: preferences, openWindow: { _ in })
        defer {
            for session in Array(sessions.sessions.values) {
                sessions.windowClosed(session)
            }
        }
        let path = directory.appendingPathComponent(multicam ? "Assembly.cut" : "Sequence.cut")
        let project: CutProject = multicam
            ? .multicam(.init(referenceAngle: "wide", range: .init(from: .zero, to: sourceEnd),
                              angles: [.init(id: "wide", file: source.path)], audio: .none,
                              switches: [.init(at: .zero, angle: "wide")]))
            : .sequence([.init(id: "video", file: source.path, from: .zero, to: sourceEnd)])
        try project.settingStillColorPolicy(color).save(to: path)
        _ = try await sessions.handleMCPCommand(tool: "open_project", arguments: ["path": path.path],
                                                session: nil, checkAccess: {})
        let session = try XCTUnwrap(sessions.project(at: path))
        XCTAssertEqual(session.isMulticam, multicam)
        try await wait("indexed source") {
            multicam ? !session.multicam.isBusy && session.multicam.media["wide"]?.hasFullEditIndex == true
                : session.editor.canEdit && session.editor.tierIsCurrent
        }
        let editor = NSWindow(contentRect: .init(x: 40, y: 40, width: 900, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        defer {
            sessions.windowClosed(session)
            editor.close()
        }
        if multicam {
            editor.contentView = NSHostingView(rootView: MulticamEditorView(model: session.multicam,
                                                                           presentation: session.presentation))
            session.multicam.preview.isMuted = true
        } else {
            editor.contentView = NSHostingView(rootView: EditorView(editor: session.editor, multicam: session.multicam,
                                                                    presentation: session.presentation, addMulticam: {}))
            session.editor.preview.isMuted = true
        }
        sessions.register(session, window: editor)
        editor.orderFront(nil)

        if multicam {
            session.multicam.insertMulticamStill(card, atAssembly: boundary)
        } else {
            session.editor.addDroppedStills([card], at: boundary.seconds)
        }
        try await wait("insert duration sheet") { editor.attachedSheet != nil }
        let apply = try XCTUnwrap(button(in: editor.attachedSheet?.contentView, titled: "Apply"))
        apply.performClick(nil)
        try await wait("committed still placement") { session.mcpStillProject?.stillInserts.count == 1 }
        let insert = try XCTUnwrap(session.mcpStillProject?.stillInserts.first)
        XCTAssertEqual(insert.cadence, cadence)
        try await wait("editable inserted still") { session.mcpCanEditStills }
        if multicam {
            let row = try XCTUnwrap(session.multicam.multicamStillRows.first)
            session.multicam.manageMulticamStill(row, action: .resize)
        } else {
            let row = try XCTUnwrap(session.editor.stillPlacementRows.first)
            session.editor.manageStill(row, action: .resize)
        }
        try await wait("change duration sheet") { editor.attachedSheet != nil }
        let changeDuration = try RationalTime(parsing: "3003/1000")
        let field = try XCTUnwrap(descendant(NSTextField.self, in: editor.attachedSheet?.contentView) {
            $0.isEditable && $0.stringValue == insert.duration.description
        })
        field.stringValue = changeDuration.description
        if let editor = field.currentEditor() as? NSTextView { editor.string = changeDuration.description }
        let update = try XCTUnwrap(button(in: editor.attachedSheet?.contentView, titled: "Apply"))
        update.performClick(nil)
        try await wait("updated still duration") { session.mcpStillProject?.stillInserts.first?.duration == changeDuration }
        if multicam { session.multicam.setAssemblyPreview(true) }
        let monitorReply = try await sessions.handleMCPCommand(tool: "set_video_monitor", arguments: ["visible": true],
                                                               session: session, checkAccess: {})
        XCTAssertEqual(monitorReply["monitorVisible"] as? Bool, true)
        let monitor = try XCTUnwrap(session.monitor)
        XCTAssertTrue(monitor.isVisible)
        if let panelScreen = monitor.screen, let editorScreen = editor.screen,
           NSScreen.screens.contains(where: { $0 != editorScreen }) {
            XCTAssertNotEqual(panelScreen, editorScreen)
        }
        try await wait("both preview surfaces") {
            self.surface(in: editor.contentView) != nil && self.surface(in: monitor.contentView) != nil
        }
        let viewer = try XCTUnwrap(surface(in: editor.contentView))
        let monitorView = try XCTUnwrap(surface(in: monitor.contentView))
        let expected = previewTime(boundary)
        let outputAfterCard = try boundary.adding(changeDuration).adding(cadence)
        if multicam {
            session.multicam.preview.seek(to: .zero)
            session.multicam.preview.togglePlayback()
        } else {
            session.editor.seek(0)
            try await wait("ordinary preview transport") {
                if !session.editor.preview.isPlaying { session.editor.preview.togglePlayback() }
                return session.editor.preview.isPlaying
            }
        }
        try await wait("playback reaches the same inserted still in both windows") {
            let playing = multicam ? session.multicam.preview.isPlaying : session.editor.preview.isPlaying
            let time = multicam ? session.multicam.preview.currentTime().seconds : session.editor.preview.time
            return playing && time >= boundary.seconds &&
                viewer.displayedFrameTime == expected && monitorView.displayedFrameTime == expected
        }
        session.pausePreview()
        for preview in [viewer, monitorView] {
            let status = try XCTUnwrap(preview.presentationDescription)
            XCTAssertTrue(status.contains("program PQ"), status)
            if let screen = preview.window?.screen, screen.maximumPotentialExtendedDynamicRangeColorComponentValue <= 1 {
                XCTAssertTrue(status.hasPrefix("SDR preview"), status)
            }
        }
        if multicam {
            session.multicam.preview.seek(to: outputAfterCard)
        } else {
            session.editor.seek(outputAfterCard.seconds)
        }
        try await wait("source picture replaces the still in both windows") {
            guard let frame = viewer.displayedFrameTime else { return false }
            return frame != expected && frame == monitorView.displayedFrameTime
        }
        try await wait("updated fidelity tier") {
            multicam ? session.multicam.tierIsCurrent : session.editor.tierIsCurrent
        }
        let tier = try XCTUnwrap(multicam ? session.multicam.settledTier : session.editor.settledTier)
        XCTAssertLessThan(tier, .trueLossless)
        if !multicam { XCTAssertNotEqual(session.editor.openingExportMode(), .copy) }
    }

    private func writeCard(_ url: URL) throws {
        let rgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8,
            bytesPerRow: 0, space: rgb,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: 64, height: 36))
        let image = try XCTUnwrap(context.makeImage())
        let file = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(file, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(file))
    }

    private func surface(in view: NSView?) -> PreviewSurface? {
        descendant(PreviewSurface.self, in: view) { _ in true }
    }

    private func button(in view: NSView?, titled title: String) -> NSButton? {
        descendant(NSButton.self, in: view) { $0.title == title }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView?, where matches: (T) -> Bool) -> T? {
        guard let view else { return nil }
        if let element = view as? T, matches(element) { return element }
        for child in view.subviews {
            if let element = descendant(type, in: child, where: matches) { return element }
        }
        return nil
    }

    private func wait(_ label: String, file: StaticString = #filePath, line: UInt = #line,
                      _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard ready() else {
            XCTFail("Timed out waiting for \(label).", file: file, line: line)
            throw PreviewTimedOut()
        }
    }
}
