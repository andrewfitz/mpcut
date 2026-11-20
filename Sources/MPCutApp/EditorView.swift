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
            if !editor.isEmpty || editor.hasHistory {
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
                if !editor.isEmpty || !editor.queuedRanges.isEmpty {
                    Button(action: editor.showBulkQueue) {
                        Label("Export Queue (\(editor.queuedRanges.count))", systemImage: "list.number")
                    }
                    .help("Review and export queued ranges")
                    .disabled(!editor.canShowBulkQueue)
                }
                if !editor.isEmpty {
                    PreviewSoundControls(preview: editor.preview)
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
        .sheet(isPresented: $editor.isBulkQueuePresented, onDismiss: editor.bulkQueueDismissed) {
            BulkQueueView(editor: editor)
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
                ClipTool(icon: "backward.end.alt", label: "Previous Scene", shortcut: "⇧←") { editor.stepScene(-1) }
                    .disabled(!editor.canStepScenes)
                ClipTool(icon: "backward.end.fill", label: "Previous Keyframe", shortcut: "⌥←") {
                    editor.step(-1, keyframes: true)
                }
                .disabled(!editor.canEdit)
                ClipTool(icon: "backward.frame", label: "Previous Frame", shortcut: "←") { editor.step(-1) }
                    .disabled(!editor.canEdit)
                PreviewPlayButton(preview: editor.preview)
                ClipTool(icon: "forward.frame", label: "Next Frame", shortcut: "→") { editor.step(1) }
                    .disabled(!editor.canEdit)
                ClipTool(icon: "forward.end.fill", label: "Next Keyframe", shortcut: "⌥→") {
                    editor.step(1, keyframes: true)
                }
                .disabled(!editor.canEdit)
                ClipTool(icon: "forward.end.alt", label: "Next Scene", shortcut: "⇧→") { editor.stepScene(1) }
                    .disabled(!editor.canStepScenes)
            }
            .disabled(!editor.canNavigate)

            Divider().frame(height: 18)

            HStack(spacing: 9) {
                ClipTool(icon: nil, label: "Mark In", shortcut: "I", active: editor.markIn != nil, action: editor.setIn)
                ClipTool(icon: nil, label: "Mark Out", shortcut: "O", active: editor.markOut != nil, action: editor.setOut)
                ClipTool(icon: "text.badge.plus", label: "Add Marked Range to Export Queue", shortcut: "⇧⌘A", action: editor.addMarkedRange)
                    .disabled(!editor.canAddMarkedRange)
                ClipTool(icon: "scissors", label: "Split at Playhead", visibleTitle: "Split", shortcut: "⌘B", action: editor.split)
                ClipTool(icon: "trash", label: editor.deleteTitle, shortcut: "⌫", action: editor.deleteSelection)
                    .disabled(!editor.canDelete)
                if editor.markIn != nil || editor.markOut != nil {
                    ClipTool(icon: "xmark.circle", label: "Clear Marks", shortcut: "Esc", action: editor.clearMarks)
                }
            }
            .disabled(!editor.canEdit)

            Spacer()

            ClipTool(icon: "arrow.uturn.backward", label: editor.undoTitle, shortcut: "⌘Z", action: editor.undo)
                .disabled(!editor.canUndo)
            ClipTool(icon: "arrow.uturn.forward", label: editor.redoTitle, shortcut: "⇧⌘Z", action: editor.redo)
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
            markIn: editor.markIn,
            markOut: editor.markOut,
            thumbnailHeight: editor.timelineThumbnailHeight,
            sequenceDuration: editor.duration,
            scenesBySource: editor.scenesBySource, viewNamesBySource: editor.viewNamesBySource,
            sceneRevision: editor.sceneRevision,
            snapToKeyframes: $editor.snapToKeyframes,
            largeThumbnails: $editor.largeThumbnails,
            zoom: $editor.timelineZoom,
            timeEntryRequest: editor.timeEntryRequest,
            allowsClipEdits: !editor.isBusy,
            onSelect: editor.select,
            onSeek: editor.seek,
            onTrim: editor.trim,
            onMove: editor.move,
            onDrop: { editor.importFiles($0, at: $1) },
            onScrub: editor.scrub, onEndScrub: editor.preview.endScrub,
            onCancelTrim: editor.cancelTrim,
            thumbnail: editor.thumbnail
        )
        .disabled(editor.isBusy && !editor.canNavigate)
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
                Text(editor.isImporting
                     ? (editor.isCancelling ? "Cancelling…" : (editor.isEmpty ? "Opening clips…" : "Indexing frames and audio…"))
                     : "Checking edit…")
                Spacer()
                if editor.isImporting {
                    Button("Cancel", action: editor.cancelImport)
                        .disabled(editor.isCancelling)
                }
            } else {
                if let progress = editor.sceneProgress {
                    ProgressView(value: progress).frame(width: 62)
                    Text("Finding scenes… \(Int(progress * 100))%")
                    Button("Cancel", action: editor.cancelSceneAnalysis)
                } else {
                    if editor.canScanScenes {
                        Button(action: editor.scanForScenes) {
                            Label("Scan for Scenes", systemImage: "viewfinder")
                        }
                        .help("Find scene cuts in the background and enable scene navigation.")
                        Divider().frame(height: 12)
                    }
                    if let label = editor.currentSceneLabel {
                        Button(label, action: editor.renameCurrentView)
                            .buttonStyle(.borderless)
                            .monospacedDigit()
                            .lineLimit(1)
                            .disabled(!editor.canRenameCurrentView)
                            .help("Rename this view across all matching scenes")
                        Divider().frame(height: 12)
                    }
                }
                Text(editor.statusMessage)
                    .lineLimit(1)
                    .help(editor.statusMessage)
                Spacer()
                if editor.lastExportedURL != nil {
                    Button("Show in Finder", action: editor.showExportInFinder)
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
                  !(window.firstResponder is NSTextView),
                  !(window.firstResponder is NSControl) else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty, editor.canNavigate {
                if event.keyCode == 49 {
                    if !event.isARepeat { editor.preview.togglePlayback() }
                    return nil
                }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "j": if !event.isARepeat { editor.preview.shuttle(-1) }
                case "k": if !event.isARepeat { editor.preview.pause() }
                case "l": if !event.isARepeat { editor.preview.shuttle(1) }
                default: return handleFrameStep(event, modifiers: modifiers)
                }
                return nil
            }
            return handleFrameStep(event, modifiers: modifiers)
        }
    }

    private func handleFrameStep(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard editor.canEdit, modifiers.isEmpty || modifiers == [.option] || modifiers == [.shift] else { return event }
        if modifiers == [.shift], event.keyCode == 123 || event.keyCode == 124 {
            guard editor.canStepScenes else { return event }
            editor.stepScene(event.keyCode == 123 ? -1 : 1)
            return nil
        }
        switch event.keyCode {
        case 123: editor.step(-1, keyframes: modifiers.contains(.option))
        case 124: editor.step(1, keyframes: modifiers.contains(.option))
        default: return event
        }
        return nil
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
                if preview.issue == nil, let warning = preview.audioWarning {
                    Label(warning, systemImage: "speaker.slash.fill")
                        .font(.callout)
                        .padding(8)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
                        .environment(\.colorScheme, .dark)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
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

private struct PreviewSoundControls: View {
    @ObservedObject var preview: SequencePreview
    @State private var showVolume = false

    var body: some View {
        Button {
            showVolume.toggle()
        } label: {
            Label("Preview Audio", systemImage: preview.isMuted || preview.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .help("Preview volume, mute, and audio scrubbing")
        .popover(isPresented: $showVolume) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { preview.isMuted.toggle() } label: {
                        Image(systemName: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 22)
                    }
                    .accessibilityLabel(preview.isMuted ? "Unmute preview" : "Mute preview")
                    .help(preview.isMuted ? "Unmute preview" : "Mute preview")
                    Slider(value: Binding(get: { preview.volume }, set: {
                        preview.volume = $0
                        preview.isMuted = false
                    }), in: 0...1)
                    .accessibilityLabel("Preview volume")
                }
                Toggle("Play audio while scrubbing", isOn: $preview.scrubSoundEnabled)
            }
            .padding(14)
            .frame(width: 228)
        }
    }
}

private struct PreviewPlayButton: View {
    @ObservedObject var preview: SequencePreview

    var body: some View {
        let rate = preview.playbackRate
        let speed = "\(rate < 0 ? "−" : "")\(Int(abs(rate)))×"
        let label = rate == 0 ? "Play" : (rate == 1 ? "Pause" : "Pause \(speed) Playback")
        ClipTool(icon: rate == 0 ? "play.fill" : "pause.fill", label: label,
                 visibleTitle: rate == 0 || rate == 1 ? nil : speed,
                 shortcut: "Space · J / K / L", action: preview.togglePlayback)
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
