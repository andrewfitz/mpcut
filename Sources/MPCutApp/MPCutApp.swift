import AppKit
import MPCutCore
import SwiftUI

@main
struct MPCutApp: App {
    @StateObject private var editor = EditorModel()
    @NSApplicationDelegateAdaptor private var application: EditorApplication

    var body: some Scene {
        Window("MPCut", id: "editor") {
            EditorView(editor: editor)
                .frame(minWidth: 730, minHeight: max(510, 385 + editor.timelineThumbnailHeight))
                .background(WindowSessionObserver(onClose: editor.endSession, preventsClose: editor.isExporting))
                .onAppear {
                    application.onOpenFiles = editor.openFiles
                    application.waitForExportCleanup = editor.cancelAndWaitForExport
                    application.isExporting = { [weak editor] in editor?.isExporting == true }
                }
        }
        .defaultSize(width: 1060, height: 730)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Clips…", action: editor.chooseFiles)
                    .keyboardShortcut("o")
                    .disabled(editor.isBusy)
            }
            CommandGroup(after: .importExport) {
                Button("Export Movie…", action: editor.chooseExport)
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(!editor.canEdit)
                Menu("Export Movie As") {
                    ForEach([ExportMode.smart, .copy, .encode], id: \.self) { mode in
                        Button("\(mode.displayName)…") { editor.chooseExport(mode: mode) }
                    }
                }
                .disabled(!editor.canEdit)
                Button("Export Queue…", action: editor.showBulkQueue)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!editor.canShowBulkQueue)
                Button("Show Last Export in Finder", action: editor.showExportInFinder)
                    .disabled(editor.lastExportedURL == nil)
                Divider()
                Button("Cancel Import", action: editor.cancelImport)
                    .disabled(!editor.isImporting || editor.isCancelling)
                Button("Cancel Export", action: editor.cancelExport)
                    .disabled(!editor.isExporting || editor.isCancelling)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(editor.undoTitle) {
                    if let text = activeTextUndoManager() { if text.canUndo { text.undo() } } else { editor.undo() }
                }
                .keyboardShortcut("z")
                .disabled(!editor.canUndo)
                Button(editor.redoTitle) {
                    if let text = activeTextUndoManager() { if text.canRedo { text.redo() } } else { editor.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo)
            }
            CommandMenu("Sequence") {
                Button("Mark In", action: editor.setIn)
                    .keyboardShortcut("i", modifiers: [])
                    .disabled(!editor.canEdit)
                Button("Mark Out", action: editor.setOut)
                    .keyboardShortcut("o", modifiers: [])
                    .disabled(!editor.canEdit)
                Button("Clear Marks", action: editor.clearMarks)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!editor.canClearMarks)
                Button("Add Marked Range to Export Queue", action: editor.addMarkedRange)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!editor.canAddMarkedRange)
                Divider()
                Button("Split at Playhead", action: editor.split)
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(!editor.canEdit)
                Button(editor.deleteTitle, action: editor.deleteSelection)
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!editor.canDelete)
                Divider()
                Menu("Trim Selected Clip") {
                    Button("Trim Start to Playhead") { editor.trimSelected(.start) }
                        .disabled(!editor.canTrimSelected(.start, restore: false))
                    Button("Trim End to Playhead") { editor.trimSelected(.end) }
                        .disabled(!editor.canTrimSelected(.end, restore: false))
                    Divider()
                    Button("Restore Original Start") { editor.trimSelected(.start, restore: true) }
                        .disabled(!editor.canTrimSelected(.start, restore: true))
                    Button("Restore Original End") { editor.trimSelected(.end, restore: true) }
                        .disabled(!editor.canTrimSelected(.end, restore: true))
                }
                Button("Move Selected Clip Earlier") { editor.moveSelectedClip(by: -1) }
                    .disabled(!editor.canMoveEarlier)
                Button("Move Selected Clip Later") { editor.moveSelectedClip(by: 1) }
                    .disabled(!editor.canMoveLater)
                Toggle("Snap to Keyframes", isOn: $editor.snapToKeyframes)
                    .disabled(!editor.canEdit)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Large Timeline Thumbnails", isOn: $editor.largeThumbnails)
                Divider()
                Button("Zoom In on Timeline") { editor.timelineZoom = min(6, editor.timelineZoom + 1) }
                    .disabled(editor.isEmpty || editor.timelineZoom >= 6)
                Button("Zoom Out on Timeline") { editor.timelineZoom = max(0, editor.timelineZoom - 1) }
                    .disabled(editor.isEmpty || editor.timelineZoom <= 0)
                Button("Fit Timeline") { editor.timelineZoom = 0 }
                    .disabled(editor.isEmpty || editor.timelineZoom == 0)
            }
            PlaybackCommands(editor: editor, preview: editor.preview)
        }
    }
}

private struct PlaybackCommands: Commands {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preview: SequencePreview

    var body: some Commands {
        CommandMenu("Playback") {
            Button(preview.isPlaying ? "Pause" : "Play", action: preview.togglePlayback)
                .disabled(!editor.canNavigate || preview.issue != nil)
            Button("Shuttle Reverse (J)") { preview.shuttle(-1) }
                .disabled(!editor.canNavigate || preview.issue != nil)
            Button("Stop Shuttle (K)", action: preview.pause)
                .disabled(!editor.canNavigate || !preview.isPlaying)
            Button("Shuttle Forward (L)") { preview.shuttle(1) }
                .disabled(!editor.canNavigate || preview.issue != nil)
            Divider()
            Button("Go to Time…", action: editor.seekUsingTimeField)
                .disabled(!editor.canNavigate)
            Button("Go to Start") { editor.seek(0) }
                .disabled(!editor.canNavigate)
            Button("Go to End") { editor.seek(editor.duration) }
                .disabled(!editor.canNavigate)
            Button("Previous Frame") { editor.step(-1) }.disabled(!editor.canEdit)
            Button("Next Frame") { editor.step(1) }.disabled(!editor.canEdit)
            Button("Scan for Scenes", action: editor.scanForScenes)
                .disabled(!editor.canScanScenes)
            Button("Cancel Scene Analysis", action: editor.cancelSceneAnalysis)
                .disabled(editor.sceneProgress == nil)
            Button("Rename Current View…", action: editor.renameCurrentView)
                .disabled(!editor.canRenameCurrentView)
            Button("Previous Scene") { editor.stepScene(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .shift).disabled(!editor.canStepScenes)
            Button("Next Scene") { editor.stepScene(1) }
                .keyboardShortcut(.rightArrow, modifiers: .shift).disabled(!editor.canStepScenes)
            Button("Previous Keyframe") { editor.step(-1, keyframes: true) }.disabled(!editor.canEdit)
            Button("Next Keyframe") { editor.step(1, keyframes: true) }.disabled(!editor.canEdit)
            Divider()
            Toggle("Mute Preview Audio", isOn: $preview.isMuted)
            Button("Increase Preview Volume") { changeVolume(by: 0.1) }
                .disabled(preview.volume >= 1 && !preview.isMuted)
            Button("Decrease Preview Volume") { changeVolume(by: -0.1) }
                .disabled(preview.volume <= 0)
            Toggle("Play Audio While Scrubbing", isOn: $preview.scrubSoundEnabled)
        }
    }

    private func changeVolume(by delta: Float) {
        preview.volume = min(1, max(0, preview.volume + delta))
        preview.isMuted = false
    }
}

/// While text is being edited, Undo belongs to the text field rather than to the timeline.
@MainActor private func activeTextUndoManager() -> UndoManager? {
    guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return nil }
    return text.undoManager ?? UndoManager()
}

private final class EditorApplication: NSObject, NSApplicationDelegate {
    private var pendingFiles: [URL] = []
    var waitForExportCleanup: ((@escaping () -> Void) -> Bool)?
    var isExporting: (() -> Bool)?

    var onOpenFiles: (([URL]) -> Void)? {
        didSet {
            guard let onOpenFiles, !pendingFiles.isEmpty else { return }
            let files = pendingFiles
            pendingFiles.removeAll()
            onOpenFiles(files)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if let onOpenFiles {
            onOpenFiles(files)
        } else {
            pendingFiles.append(contentsOf: files)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isExporting?() == true {
            let alert = NSAlert()
            alert.messageText = "Stop the export and quit?"
            alert.informativeText = "MPCut is still exporting. Quitting cancels the export and removes the unfinished movie."
            alert.addButton(withTitle: "Continue Export")
            let quit = alert.addButton(withTitle: "Stop Export and Quit")
            quit.hasDestructiveAction = true
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        if waitForExportCleanup?({ sender.reply(toApplicationShouldTerminate: true) }) == true {
            return .terminateLater
        }
        return .terminateNow
    }
}

private struct WindowSessionObserver: NSViewRepresentable {
    let onClose: () -> Void
    /// Closing the window ends the session, so it stays open while an export the user started is running.
    let preventsClose: Bool

    func makeNSView(context: Context) -> SessionView {
        let view = SessionView()
        view.onClose = onClose
        view.preventsClose = preventsClose
        return view
    }

    func updateNSView(_ nsView: SessionView, context: Context) {
        nsView.onClose = onClose
        nsView.preventsClose = preventsClose
    }

    final class SessionView: NSView {
        var onClose: (() -> Void)?
        var preventsClose = false {
            didSet { if preventsClose != oldValue { applyCloseState() } }
        }

        private func applyCloseState() {
            guard let window else { return }
            if preventsClose { window.styleMask.remove(.closable) } else { window.styleMask.insert(.closable) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyCloseState()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window
                )
            }
        }

        @objc private func windowWillClose(_ notification: Notification) {
            onClose?()
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
