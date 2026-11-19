import AppKit
import SwiftUI

@main
struct MPCutApp: App {
    @StateObject private var editor = EditorModel()
    @NSApplicationDelegateAdaptor private var application: EditorApplication

    var body: some Scene {
        Window("MPCut", id: "editor") {
            EditorView(editor: editor)
                .frame(minWidth: 730, minHeight: 510)
                .background(WindowSessionObserver(onClose: editor.endSession))
                .onAppear {
                    application.onOpenFiles = editor.openFiles
                    application.waitForExportCleanup = editor.cancelAndWaitForExport
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
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: editor.undo)
                    .keyboardShortcut("z")
                    .disabled(!editor.canUndo)
                Button("Redo", action: editor.redo)
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
                Divider()
                Button("Split at Playhead", action: editor.split)
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(!editor.canEdit)
                Button("Delete", action: editor.deleteSelection)
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!editor.canDelete)
                Divider()
                Button("Export Movie…", action: editor.chooseExport)
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(!editor.canEdit)
            }
        }
    }
}

private final class EditorApplication: NSObject, NSApplicationDelegate {
    private var pendingFiles: [URL] = []
    var waitForExportCleanup: ((@escaping () -> Void) -> Bool)?

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
        if waitForExportCleanup?({ sender.reply(toApplicationShouldTerminate: true) }) == true {
            return .terminateLater
        }
        return .terminateNow
    }
}

private struct WindowSessionObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> SessionView {
        let view = SessionView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: SessionView, context: Context) {
        nsView.onClose = onClose
    }

    final class SessionView: NSView {
        var onClose: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
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
