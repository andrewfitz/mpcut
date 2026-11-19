import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var editor: EditorModel
    @State private var editorWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var isViewerDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            viewer
                .frame(minHeight: 180, maxHeight: .infinity)
            if !editor.isEmpty || editor.canUndo || editor.canRedo {
                transport
                Divider()
                timeline
            }
            if !editor.isEmpty || editor.isBusy || editor.lastExportedURL != nil {
                Divider()
                status
            }
        }
        .background(WindowReader { editorWindow = $0 })
        .navigationSubtitle(editor.formatSummary ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !editor.isEmpty {
                    Button(action: editor.chooseFiles) {
                        Label("Add Clips", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    .disabled(editor.isBusy)
                    Button(action: editor.chooseExport) {
                        Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                    }
                    .disabled(!editor.canEdit)
                }
            }
        }
        .toolbarRole(.editor)
        .onAppear(perform: installKeyboardMonitor)
        .onDisappear(perform: removeKeyboardMonitor)
        .alert(item: $editor.alert) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK"), action: editor.dismissNotice))
        }
    }

    private var viewer: some View {
        ViewerPanel(preview: editor.preview, isEmpty: editor.isEmpty, isBusy: editor.isBusy, add: editor.chooseFiles)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(editor.isEmpty ? Color(nsColor: .windowBackgroundColor) : .black)
            .overlay {
                if isViewerDropTarget && !editor.isBusy {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !editor.isBusy, !files.isEmpty else { return false }
                editor.importFiles(files)
                return true
            } isTargeted: {
                isViewerDropTarget = $0
            }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                ClipTool(icon: "backward.frame", label: "Previous Frame", shortcut: "←") { editor.step(-1) }
                PreviewPlayButton(preview: editor.preview)
                ClipTool(icon: "forward.frame", label: "Next Frame", shortcut: "→") { editor.step(1) }
            }
            .disabled(!editor.canEdit)

            Divider().frame(height: 18)

            HStack(spacing: 9) {
                ClipTool(icon: nil, label: "Mark In", shortcut: "I", active: editor.markIn != nil, action: editor.setIn)
                ClipTool(icon: nil, label: "Mark Out", shortcut: "O", active: editor.markOut != nil, action: editor.setOut)
                ClipTool(icon: "scissors", label: "Split at Playhead", visibleTitle: "Split", shortcut: "⌘B", action: editor.split)
                ClipTool(icon: "trash", label: "Delete", shortcut: "⌫", action: editor.deleteSelection)
                    .disabled(!editor.canDelete)
            }
            .disabled(!editor.canEdit)

            Spacer()

            ClipTool(icon: "arrow.uturn.backward", label: "Undo", shortcut: "⌘Z", action: editor.undo)
                .disabled(!editor.canUndo)
            ClipTool(icon: "arrow.uturn.forward", label: "Redo", shortcut: "⇧⌘Z", action: editor.redo)
                .disabled(!editor.canRedo)
        }
        .padding(.horizontal, 17)
        .frame(height: 43)
        .background(.bar)
    }

    private var timeline: some View {
        SequenceTimeline(
            clips: editor.timelineClips,
            playhead: editor.playhead,
            selection: editor.selectedID,
            markedRange: editor.markedRange,
            onSelect: editor.select,
            onSeek: editor.seek,
            onTrim: editor.trim,
            onMove: editor.move,
            onDrop: { editor.importFiles($0, at: $1) },
            onCancelTrim: editor.cancelTrim,
            thumbnail: editor.thumbnail
        )
        .disabled(editor.isBusy)
    }

    private var status: some View {
        HStack(spacing: 9) {
            if editor.isExporting {
                ProgressView(value: editor.exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 132)
                    .accessibilityLabel("Export progress")
                Text(editor.isCancelling ? "Cancelling…" : "Exporting \(editor.exportProgress.formatted(.percent.precision(.fractionLength(0))))")
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: editor.cancelExport)
                    .disabled(editor.isCancelling)
            } else if editor.isImporting || editor.isCheckingEdit {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(editor.isImporting ? "Checking clips…" : "Checking edit…")
                Spacer()
            } else {
                Text(editor.statusMessage)
                    .lineLimit(1)
                    .help(editor.statusMessage)
                Spacer()
                if let exportURL = editor.lastExportedURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([exportURL])
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(.bar)
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window === editorWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView) else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == [] && event.keyCode == 49 && editor.canEdit {
                editor.preview.togglePlayback()
                return nil
            }
            if (modifiers == [] || modifiers == [.option]), editor.canEdit {
                switch event.keyCode {
                case 123: editor.step(-1, keyframes: modifiers.contains(.option))
                case 124: editor.step(1, keyframes: modifiers.contains(.option))
                default: return event
                }
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onChange?(self.window)
            }
        }
    }
}

private struct ViewerPanel: View {
    @ObservedObject var preview: SequencePreview
    let isEmpty: Bool
    let isBusy: Bool
    let add: () -> Void

    var body: some View {
        ZStack {
            if isEmpty {
                ContentUnavailableView {
                    Label("Add clips to start editing", systemImage: "film.stack")
                } description: {
                    Text("Drag video files here to build a sequence.")
                } actions: {
                    Button("Add Clips…", action: add)
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                }
            } else {
                PreviewView(preview: preview)
                    .accessibilityLabel("Movie preview")
                if let issue = preview.issue {
                    Label(issue, systemImage: "video.slash")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(13)
                        .frame(maxWidth: 430)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 9))
                        .environment(\.colorScheme, .dark)
                }
            }
        }
    }
}

private struct PreviewPlayButton: View {
    @ObservedObject var preview: SequencePreview

    var body: some View {
        ClipTool(icon: preview.isPlaying ? "pause.fill" : "play.fill",
                 label: preview.isPlaying ? "Pause" : "Play", shortcut: "Space", action: preview.togglePlayback)
            .disabled(preview.issue != nil)
    }
}

private struct ClipTool: View {
    let icon: String?
    let label: String
    var visibleTitle: String? = nil
    let shortcut: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                }
                if let title = visibleTitle ?? (icon == nil ? label : nil) {
                    Text(title)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, icon == nil || visibleTitle != nil ? 6 : 0)
            .frame(minWidth: 28, minHeight: 26)
            .background(active ? Color.accentColor.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(label) (\(shortcut))")
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
