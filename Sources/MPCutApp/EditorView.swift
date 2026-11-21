import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let addMulticam: () -> Void
    @State private var showPauseControls = false
    @State private var audioViewSpan = AudioViewerSpan.timeline
    @Environment(\.openDroppedProjects) private var openDroppedProjects

    var body: some View {
        EditorWorkspace(viewer: viewer, transport: transport, timeline: timeline, status: status,
                        showsTimeline: !editor.isEmpty || editor.hasHistory,
                        showsStatus: !editor.isEmpty || editor.isBusy || editor.lastExportedURL != nil)
        .background(EditorKeyboardMonitor(handle: handleKey))
        .navigationTitle(windowTitle)
        .navigationSubtitle(editor.formatSummary ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !editor.isEmpty || !editor.queuedRanges.isEmpty {
                    ExportQueueToolbarButton(count: editor.queuedRanges.count, action: editor.showBulkQueue)
                        .disabled(!editor.canShowBulkQueue)
                }
                if !editor.isEmpty {
                    SequencePreviewSoundControls(preview: editor.preview)
                    EditorToolbarButton(title: "Add Clips", symbol: "plus", action: editor.chooseFiles)
                        .help("Add audio or video files to the sequence (⌘O)")
                        .disabled(editor.isBusy)
                    EditorToolbarButton(title: "Export", symbol: "square.and.arrow.up", action: editor.chooseExport)
                        .help("Export the sequence (⌘E)")
                        .disabled(!editor.canEdit)
                }
            }
        }
        .sheet(isPresented: $editor.isBulkQueuePresented, onDismiss: editor.bulkQueueDismissed) {
            BulkQueueView(editor: editor)
        }
        .sheet(item: $editor.cutPreview) { _ in
            CutPreviewSheet(editor: editor)
        }
        .toolbarRole(.editor)
        .alert(item: $editor.alert) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK"), action: editor.dismissNotice))
        }
    }

    private var windowTitle: String {
        guard let first = editor.timelineClips.first else { return "Untitled" }
        let additionalSources = Set(editor.timelineClips.map(\.sourceID)).count - 1
        return additionalSources > 0 ? "\(first.name) + \(additionalSources)" : first.name
    }

    private var viewer: some View {
        Group {
            if let audio = editor.audioPreviewClip {
                AudioWaveformViewer(clip: audio.clip, offset: audio.offset, sourceTime: editor.audioPreviewSourceTime ?? audio.clip.sourceStart,
                                    zoom: editor.timelineZoom, span: audioViewSpan, revision: editor.waveformRevision, store: editor.audioStore.detail,
                                    coarse: editor.audioStore.waves[audio.clip.sourceID], pauses: editor.sourcePauses[audio.clip.sourceID] ?? [],
                                    markIn: editor.markIn, markOut: editor.markOut, enabled: editor.canNavigate,
                                    pointerTarget: editor.pointerTarget, onPointerSeek: editor.seekFromPointer, seek: editor.seek, scrub: editor.scrub, endScrub: editor.preview.endScrub)
                    .overlay(alignment: .bottom) {
                        Picker("Waveform span", selection: $audioViewSpan) {
                            ForEach(AudioViewerSpan.allCases, id: \.self) { span in
                                Text(span.rawValue).tag(span)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                        .environment(\.colorScheme, .dark)
                        .help("Choose how much source audio to show around the playhead")
                        .padding(.bottom, 8)
                    }
                    .overlay(alignment: .bottomLeading) {
                        AudioPreviewNotice(preview: editor.preview)
                    }
            } else {
                ViewerPanel(preview: editor.preview, isEmpty: editor.isEmpty, isBusy: editor.isBusy,
                            canAddMulticam: multicam.canChooseSources, add: editor.chooseFiles,
                            addMulticam: addMulticam)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(editor.isEmpty ? Color(nsColor: .windowBackgroundColor) : .black)
            .modifier(EditorMediaDrop(enabled: !editor.isBusy) { editor.importFiles($0) })
    }

    private var transport: some View {
        EditorTransportBar(
            navigation: editor.isAudioOnly
                ? .audio(pauses: .init(enabled: editor.pauseAnalysisReady && !editor.pausePlan.isEmpty, step: editor.stepPause))
                : .picture(scenes: .init(enabled: editor.canStepScenes, step: editor.stepScene),
                           keyframes: .init(enabled: editor.canEdit) { editor.step($0, keyframes: true) }),
            frames: .init(enabled: editor.canEdit) { editor.step($0) },
            canNavigate: editor.canNavigate,
            canEdit: editor.canEdit,
            marks: .init(hasIn: editor.markIn != nil, hasOut: editor.markOut != nil,
                         setIn: editor.setIn, setOut: editor.setOut, clear: editor.clearMarks),
            addRange: .init(title: "Add Marked Range to Export Queue",
                            enabled: editor.canAddMarkedRange, perform: editor.addMarkedRange),
            split: .init(title: "Split at Playhead", perform: editor.split),
            delete: .init(title: editor.deleteTitle, enabled: editor.canDelete, perform: editor.deleteSelection),
            undo: .init(title: editor.undoTitle, enabled: editor.canUndo, perform: editor.undo),
            redo: .init(title: editor.redoTitle, enabled: editor.canRedo, perform: editor.redo),
            play: SequencePreviewPlayButton(preview: editor.preview)
        ) { EmptyView() }
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
            audioOnly: editor.isAudioOnly,
            showsWaveform: !editor.isAudioOnly && !editor.audioTracks.isEmpty,
            envelopeStore: editor.audioStore.detail,
            waveforms: editor.audioStore.waves, waveformPauses: editor.sourcePauses,
            waveformRevision: editor.waveformRevision,
            snapTarget: Binding(get: { editor.effectiveSnapTarget }, set: editor.chooseSnapTarget),
            largeThumbnails: $editor.largeThumbnails,
            zoom: $editor.timelineZoom,
            timeEntryRequest: editor.timeEntryRequest,
            allowsClipEdits: !editor.isBusy,
            onSelect: editor.select,
            onSeek: editor.seek,
            onTrim: editor.trim,
            onMove: editor.move,
            onDrop: { editor.importFiles(openDroppedProjects($0), at: $1) },
            pointerTarget: editor.pointerTarget, onPointerSeek: editor.seekFromPointer,
            onScrub: editor.scrub, onEndScrub: editor.preview.endScrub,
            onCancelTrim: editor.cancelTrim,
            thumbnail: editor.thumbnail
        )
        .disabled(editor.isBusy && !editor.canNavigate)
    }

    private var status: some View {
        EditorStatusBar {
            if editor.isExporting {
                ProgressView(value: editor.exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 132)
                    .accessibilityLabel("Export progress")
                Text(editor.isCancelling ? "Cancelling…" : "Exporting… \(progressPercent(editor.exportProgress))")
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: editor.cancelExport)
                    .disabled(editor.isCancelling)
            } else if editor.isImporting {
                ProgressView(value: editor.importProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 132)
                    .accessibilityLabel("Indexing frames and audio")
                Text(editor.isCancelling ? "Cancelling…" : "Indexing frames and audio… \(progressPercent(editor.importProgress))")
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: editor.cancelImport)
                    .disabled(editor.isCancelling)
            } else if editor.isCheckingEdit {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Checking edit…")
                Spacer()
            } else {
                if !editor.audioTracks.isEmpty {
                    silenceControls
                    StatusBarDivider()
                } else if !editor.isEmpty {
                    Label("No audio track", systemImage: "speaker.slash")
                        .foregroundStyle(.tertiary)
                    StatusBarDivider()
                }
                if let progress = editor.sceneProgress {
                    ProgressView(value: progress).frame(width: 72)
                        .accessibilityLabel("Scene analysis progress")
                    Text("Finding scenes… \(progressPercent(progress))")
                        .monospacedDigit()
                    Button("Cancel", action: editor.cancelSceneAnalysis)
                        .accessibilityLabel("Cancel scene analysis")
                    StatusBarDivider()
                } else {
                    if editor.canScanScenes {
                        Button(action: editor.scanForScenes) {
                            Label("Scan for Scenes", systemImage: "viewfinder")
                        }
                        .help("Find scene cuts in the background and enable scene navigation.")
                        StatusBarDivider()
                    }
                    if let label = editor.currentSceneLabel {
                        Button(action: editor.renameCurrentView) {
                            Label(label, systemImage: "rectangle.on.rectangle")
                        }
                            .buttonStyle(.borderless)
                            .monospacedDigit()
                            .lineLimit(1)
                            .disabled(!editor.canRenameCurrentView)
                            .help("Rename this view across all matching scenes")
                        StatusBarDivider()
                    }
                }
                Text(editor.statusMessage)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(editor.statusMessage)
                Spacer(minLength: 8)
                if editor.lastExportedURL != nil {
                    Button("Show in Finder", action: editor.showExportInFinder)
                }
            }
        }
    }

    @ViewBuilder private var silenceControls: some View {
        let progress = editor.silenceProgress
        let count = editor.pausePlan.count
        let title = progress.map { "Finding silence… \(progressPercent($0))" }
            ?? (editor.pauseAnalysisReady ? (count == 1 ? "1 pause" : "\(count) pauses") : "Scan for Silence")
        Button {
            if editor.canScanSilence && !editor.pauseAnalysisReady { editor.scanForSilence() }
            showPauseControls = true
        } label: {
            Label(title, systemImage: "waveform")
                .monospacedDigit()
        }
        .popover(isPresented: $showPauseControls, arrowEdge: .top) { PauseControls(editor: editor) }
        .help("Find quiet ranges and adjust silence detection and editing controls.")
        if progress != nil {
            Button("Cancel", action: editor.cancelSilenceScan)
                .accessibilityLabel("Cancel silence scan")
        } else if editor.pauseAnalysisReady && count > 0 {
            HStack(spacing: 0) {
                StatusIconButton(title: "Previous Silence", symbol: "chevron.left",
                                 help: "Previous Silence (⌃⌥←)") { editor.stepPause(-1) }
                StatusIconButton(title: "Next Silence", symbol: "chevron.right",
                                 help: "Next Silence (⌃⌥→)") { editor.stepPause(1) }
            }
        }
    }

    private func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
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

    private func handleFrameStep(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard editor.canEdit, modifiers.isEmpty || modifiers == [.option] || modifiers == [.shift] else { return event }
        if modifiers == [.shift], event.keyCode == 123 || event.keyCode == 124 {
            guard editor.canStepScenes else { return event }
            editor.stepScene(event.keyCode == 123 ? -1 : 1)
            return nil
        }
        if modifiers == [.option], editor.isAudioOnly { return event }
        switch event.keyCode {
        case 123: editor.step(-1, keyframes: modifiers.contains(.option))
        case 124: editor.step(1, keyframes: modifiers.contains(.option))
        default: return event
        }
        return nil
    }
}

struct AudioPreviewNotice: View {
    @ObservedObject var preview: SequencePreview

    var body: some View {
        if let message = preview.issue ?? preview.audioWarning {
            Label(message, systemImage: "speaker.slash.fill")
                .modifier(PreviewNoticeStyle())
                .padding(12)
                .allowsHitTesting(false)
        }
    }
}

private struct ViewerPanel: View {
    @ObservedObject var preview: SequencePreview
    let isEmpty: Bool
    let isBusy: Bool
    let canAddMulticam: Bool
    let add: () -> Void
    let addMulticam: () -> Void

    var body: some View {
        ZStack {
            if isEmpty {
                ContentUnavailableView {
                    Label("Add clips to start editing", systemImage: "film.stack")
                } description: {
                    Text("Drag audio or video files here to build a sequence.")
                } actions: {
                    HStack(spacing: 10) {
                        Button("Add Clips…", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy)
                        Button("Add as Multicam…", action: addMulticam)
                            .buttonStyle(.bordered)
                            .disabled(!canAddMulticam)
                    }
                    .controlSize(.large)
                }
            } else {
                EditorPreview(accessibilityTitle: "Movie preview", issue: preview.issue,
                              audioWarning: preview.audioWarning) {
                    PreviewView(preview: preview)
                }
            }
        }
    }
}

private struct SequencePreviewSoundControls: View {
    @ObservedObject var preview: SequencePreview

    var body: some View {
        PreviewSoundControls(volume: $preview.volume, isMuted: $preview.isMuted,
                             scrubSoundEnabled: $preview.scrubSoundEnabled)
    }
}

private struct SequencePreviewPlayButton: View {
    @ObservedObject var preview: SequencePreview

    var body: some View {
        PreviewPlayButton(rate: preview.playbackRate, disabled: preview.hasBlockingIssue,
                          toggle: preview.togglePlayback)
    }
}
