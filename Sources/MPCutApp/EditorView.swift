import AppKit
import MPCutCore
import SwiftUI

struct EditorView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    @ObservedObject var presentation: EditorPresentation
    let addMulticam: () -> Void
    @Environment(\.transcriptSession) private var transcriptSession
    @Environment(\.openDroppedProjects) private var openDroppedProjects
    @State private var sourceRangesPresented = false

    var body: some View {
        EditorWorkspace(viewer: viewer, transport: transport, timeline: timeline, status: status,
                        showsTimeline: !editor.isEmpty || editor.hasHistory,
                        showsStatus: !editor.isEmpty || editor.hasHistory || editor.isBusy || editor.lastExportedURL != nil,
                        showsSidebar: (presentation.sequenceTranscriptVisible || presentation.sequenceParticipantsVisible) &&
                            transcriptSession != nil) {
            if let transcriptSession {
                if presentation.sequenceParticipantsVisible {
                    ParticipantInspector(session: transcriptSession)
                } else {
                    TranscriptPane(session: transcriptSession).equatable()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let url = editor.projectURL {
                ProjectMediaBanner(count: editor.projectMediaSummary.offline) {
                    editor.presentProjectMedia(offlineOnly: true)
                }
                .id(url)
            }
        }
        .sheet(item: $editor.projectMediaRequest, onDismiss: openReplacementTranscription) { request in
            ProjectMediaSheet(jobs: editor.projectMediaJobs, request: request, archive: { editor.projectMediaArchive },
                              revision: { .init(generation: editor.mcpGeneration, edit: editor.mcpRevision) }, isMulticam: false,
                              status: editor.mediaStatus(for:),
                              relinkBatch: { try await editor.relinkProjectMedia($0) },
                              revert: { try await editor.revertProjectMedia($0) },
                              ignore: editor.ignoreProjectMedia,
                              replace: { try await editor.applyProjectMediaReplacement($0) },
                              showUse: editor.showProjectMediaUse)
        }
        .onReceive(editor.projectMediaJobs.$transcriptSetup) { request in
            if request != nil, editor.projectMediaRequest == nil {
                Task { @MainActor in openReplacementTranscription() }
            }
        }
        .background(EditorKeyboardMonitor(handle: handleKey))
        .navigationTitle(editor.windowTitle)
        .navigationSubtitle(editor.formatSummary ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                EditorToolbarButton(title: "Source Ranges", symbol: "list.bullet.rectangle",
                                    toolTip: "Save selects or apply an ordered source range plan") {
                    sourceRangesPresented = true
                }
                .disabled(editor.isBusy)
                if !editor.isEmpty || !editor.queuedRanges.isEmpty {
                    ExportQueueToolbarButton(count: editor.queuedRanges.count, action: editor.showBulkQueue)
                        .disabled(!editor.canShowBulkQueue)
                }
                StillAuthoringControls(rows: editor.stillPlacementRows, enabled: !editor.isBusy,
                                       canReplace: editor.canReplacePicture, canInsert: editor.canInsertStill,
                                       replace: editor.chooseReplacePicture, insert: editor.chooseInsertStill,
                                       insertGap: editor.chooseInsertGap, spaceClips: editor.chooseSpaceClips, canSpace: editor.canSpaceClips,
                                       manage: editor.manageStill, soundtrack: editor.stillSoundtrackControls)
                if !editor.isEmpty {
                    EditorToolbarButton(title: "Transcript", symbol: "text.alignleft",
                                        toolTip: "Show or hide the transcript (⌥⌘T)") {
                        presentation.setTranscriptVisible(!presentation.sequenceTranscriptVisible, multicam: false)
                    }
                    EditorToolbarButton(title: "Tiles", symbol: "rectangle.split.2x2",
                                        toolTip: "Review camera feeds and meeting participants") {
                        presentation.sequenceParticipantsVisible.toggle()
                        if presentation.sequenceParticipantsVisible { presentation.sequenceTranscriptVisible = false }
                    }
                    .disabled(editor.isAudioOnly)
                    SequencePreviewSoundControls(preview: editor.preview)
                    EditorToolbarButton(title: "Add Clips", symbol: "plus", toolTip: "Add clips (⌘O)",
                                        action: editor.chooseFiles)
                        .disabled(editor.isBusy)
                    EditorToolbarButton(title: "Export", symbol: "square.and.arrow.up", toolTip: "Export sequence (⌘E)",
                                        action: editor.chooseExport)
                        .disabled(!editor.canEdit)
                    if let transcriptSession, !editor.isAudioOnly {
                        EditorToolbarButton(title: "Export Settings", symbol: "slider.horizontal.3",
                                            toolTip: "Set the output canvas and soundtrack") {
                            transcriptSession.presentOutputSettings()
                        }
                        .disabled(!editor.canEdit)
                        .accessibilityIdentifier("project.output.open")
                    }
                }
            }
        }
        .sheet(isPresented: $editor.isBulkQueuePresented, onDismiss: editor.bulkQueueDismissed) {
            BulkQueueView(editor: editor)
        }
        .sheet(item: $editor.cutPreview) { _ in
            CutPreviewSheet(editor: editor)
        }
        .sheet(isPresented: $sourceRangesPresented) {
            SourceRangesSheet(editor: editor)
        }
        .toolbarRole(.editor)
        .alert(item: $editor.alert) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK"), action: editor.dismissNotice))
        }
    }

    private func openReplacementTranscription() {
        guard let transcriptSession, let request = editor.projectMediaJobs.takeTranscription() else { return }
        presentation.setTranscriptVisible(true, multicam: false)
        transcriptSession.transcript.replacementSetup = request
    }

    private var viewer: some View {
        Group {
            if let url = editor.projectMediaPreviewURL, editor.mediaStatus(for: url).hidesMedia {
                ProjectMediaSlate(url: url, status: editor.mediaStatus(for: url)) {
                    editor.presentProjectMedia(.locate, path: url.path)
                }
            } else if let audio = editor.audioPreviewClip {
                AudioWaveformViewer(clip: audio.clip, offset: audio.offset, sourceTime: editor.audioPreviewSourceTime ?? audio.clip.sourceStart,
                                    zoom: editor.timelineZoom, span: presentation.waveformSpan, revision: editor.waveformRevision, store: editor.audioStore.detail,
                                    coarse: editor.audioStore.waves[audio.clip.sourceID], pauses: editor.sourcePauses[audio.clip.sourceID] ?? [],
                                    markIn: editor.markIn, markOut: editor.markOut, enabled: editor.canNavigate,
                                    pointerTarget: editor.pointerTarget, onPointerSeek: editor.seekFromPointer, seek: editor.seek, scrub: editor.scrub, endScrub: editor.preview.endScrub)
                    .overlay(alignment: .bottom) {
                        Picker("Waveform span", selection: $presentation.waveformSpan) {
                            ForEach(AudioViewerSpan.allCases, id: \.self) { span in
                                Text(span.label).tag(span)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                        .environment(\.colorScheme, .dark)
                        .help("Set waveform time span")
                        .padding(.bottom, 8)
                    }
                    .overlay(alignment: .bottomLeading) {
                        AudioPreviewNotice(preview: editor.preview)
                    }
            } else {
                ViewerPanel(preview: editor.preview, isEmpty: editor.isEmpty, isBusy: editor.isBusy,
                            canAddMulticam: multicam.canChooseSources, add: editor.chooseFiles,
                            addMulticam: addMulticam)
                    .overlay {
                        if let transcriptSession,
                           presentation.sequenceParticipantsVisible || !editor.participantProject.isEmpty || editor.stillProject.requiresPictureProcessing {
                            ParticipantMonitorOverlay(session: transcriptSession,
                                                      interactive: presentation.sequenceParticipantsVisible)
                        }
                    }
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(editor.isEmpty ? Color(nsColor: .windowBackgroundColor) : .black)
            .modifier(EditorMediaDrop(enabled: !editor.isBusy, importFiles: editor.dropOnViewer))
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
            delete: .init(title: editor.deleteTitle, enabled: editor.canDelete, perform: { editor.byHand(editor.deleteSelection) }),
            undo: .init(title: editor.undoTitle, enabled: editor.canUndo, perform: editor.undo),
            redo: .init(title: transcriptSession?.canRedoFeedAngleConversion == true
                        ? "Redo " + (transcriptSession?.feedAngleConversionAction ?? "") : editor.redoTitle,
                        enabled: editor.canRedo || transcriptSession?.canRedoFeedAngleConversion == true,
                        perform: {
                            if transcriptSession?.canRedoFeedAngleConversion == true { transcriptSession?.redoFeedAngleConversion() }
                            else { editor.redo() }
                        }),
            rangeTools: .init(active: $editor.rangeTool, canAct: editor.canActOnRange, canSplit: editor.canSplitSelectedRange,
                              canDelete: editor.canActOnRange, split: { editor.byHand(editor.splitSelectedRange) },
                              export: editor.chooseSelectionExport, delete: { editor.byHand(editor.deleteSelection) }),
            preview: editor.preview
        ) { EmptyView() }
    }

    private var handleValidation: TimelineHandleValidation? {
        guard editor.usesBackgroundTrimValidation else { return nil }
        return { id, edge, target, commit, completion in
            editor.validateHandle(id, edge: edge, target: target, commit: commit, completion: completion)
        }
    }

    @State private var showTileFeeds = false

    private var timeline: some View {
        let soundtrack = editor.stillSoundtrackWaveform
        var timeline = SequenceTimeline(
            clips: editor.timelineClips,
            playhead: editor.playhead,
            selection: editor.selectedID,
            markIn: editor.markIn,
            markOut: editor.markOut,
            thumbnailHeight: editor.timelineThumbnailHeight,
            sequenceDuration: editor.duration,
            showsSourceRuler: editor.preferences.sourceTimeTicks,
            scenesBySource: editor.scenesBySource, sceneOverlaysByClip: editor.sceneOverlaysByClip,
            viewNamesBySource: editor.viewNamesBySource,
            sceneRevision: editor.sceneRevision,
            audioOnly: editor.isAudioOnly,
            showsWaveform: soundtrack != nil || (!editor.isAudioOnly && !editor.audioTracks.isEmpty),
            soundtrack: soundtrack,
            envelopeStore: editor.audioStore.detail,
            waveforms: editor.audioStore.waves, openingWaveform: editor.audioStore.openingWaveform,
            waveformPauses: editor.sourcePauses, timelinePadding: editor.timelinePadding,
            waveformRevision: editor.waveformRevision,
            snapTarget: Binding(get: { editor.effectiveSnapTarget }, set: editor.chooseSnapTarget),
            largeThumbnails: $editor.largeThumbnails,
            zoom: $editor.timelineZoom,
            timeEntryRequest: editor.timeEntryRequest,
            allowsClipEdits: !editor.isBusy,
            allowsStillEndResize: true,
            onSelect: editor.select,
            onSeek: editor.seek,
            onTrim: editor.trim,
            onMove: { id, slot in editor.byHand { editor.moveTimelineItem(id, to: slot) } },
            onDrop: { editor.dropOnTimeline($0, slot: $1) },
            onDropStills: { editor.addDroppedStills($0, at: $1, replacingMarkedRange: $2) },
            onDropProjects: { openDroppedProjects($0) },
            pointerTarget: editor.pointerTarget, onPointerSeek: editor.seekFromPointer,
            onScrub: editor.scrub, onEndScrub: editor.preview.endScrub,
            onCancelTrim: editor.cancelTrim,
            validateHandle: handleValidation,
            thumbnail: editor.thumbnail
        )
        if let revision = editor.timelineOutputRevision {
            timeline.outputThumbnailRevision = revision
            timeline.outputThumbnail = { time, size in
                await editor.outputThumbnail(at: time, size: size, revision: revision)
            }
        }
        timeline.tileContent = editor.tileTimeline
        timeline.showTileFeeds = $showTileFeeds
        if editor.canEdit {
            timeline.onResizeTileSpan = editor.resizeTimelineTile
            if editor.markIn != nil && editor.markOut != nil {
                timeline.onClearTileLayouts = editor.clearMarkedTileLayout
            }
        }
        timeline.onProjectMedia = editor.actOnTimelineMedia
        timeline.assemblyAssets = editor.stillAssetSpans
        if editor.canEdit {
            timeline.onPreviewJoin = { _ = editor.previewExistingJoin(before: $0) }
            timeline.onClipCSV = { editor.applyClipCSV($0, to: $1) }
            timeline.audioTrackLabels = { id in
                let tracks = editor.analysisSourceMedia[id]?.streams.filter { $0.kind == "audio" } ?? []
                return tracks.enumerated().map { "Track \($0.offset + 1) · \($0.element.audioFormatLabel)" }
            }
            timeline.onMonitorAudio = editor.chooseAnalysisTrack(_:forClip:)
            timeline.onReplaceAudio = editor.chooseReplacementAudio(forClip:)
        }
        if editor.rangeTool && editor.canEdit { timeline.onRangeSelect = editor.selectRange }
        return timeline.disabled(editor.isBusy && !editor.canNavigate)
    }

    private var status: some View {
        EditorStatusBar {
            if editor.isExporting {
                ProgressView(value: editor.exportProgress)
                    .progressViewStyle(.linear)
                    .barLeading()
                    .frame(width: 132)
                    .accessibilityLabel("Export progress")
                Text(editor.isCancelling ? "Cancelling…" : "Exporting… \(progressPercent(editor.exportProgress))")
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: editor.cancelExport)
                    .disabled(editor.isCancelling)
                    .help("Cancel export")
            } else if let progress = editor.mediaRelinkProgress {
                ProgressView(value: progress).frame(width: 100).barLeading()
                    .accessibilityLabel("Relink indexing progress")
                Text("Indexing relinked media… \(progressPercent(progress))").monospacedDigit()
                Spacer()
                Button("Cancel", action: editor.cancelProjectMediaIndexing)
                    .help("Cancel relink indexing")
            } else if let progress = editor.mediaRefreshProgress {
                ProgressView(value: progress).frame(width: 100).barLeading()
                Text("Refreshing project media…")
                Spacer()
                Button("Cancel", action: editor.mediaRefresh.cancel)
                    .help("Cancel media refresh")
            } else if editor.isImporting {
                ProgressView(value: editor.importProgress)
                    .progressViewStyle(.linear)
                    .barLeading()
                    .frame(width: 132)
                    .accessibilityLabel("Indexing audio & video")
                Text(editor.isCancelling ? "Cancelling…" : "Indexing audio & video… \(progressPercent(editor.importProgress))")
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: editor.cancelImport)
                    .disabled(editor.isCancelling)
                    .help("Cancel import")
            } else if editor.isCheckingEdit || editor.isPreparingCopyBoundaries {
                ProgressView()
                    .controlSize(.small)
                    .barLeading()
                    .accessibilityHidden(true)
                Text(editor.isPreparingCopyBoundaries ? "Preparing keyframe edit points…" : "Checking edit…")
                Spacer()
            } else {
                if !editor.audioTracks.isEmpty {
                    Menu {
                        Picker("Monitor audio", selection: Binding<Int?>(
                            get: { editor.audioMonitoringTrack },
                            set: { track in
                                if let track { editor.chooseAnalysisTrack(track) }
                                else { editor.monitorSourceAudio() }
                            }
                        )) {
                            Text("Follow Source Audio").tag(nil as Int?)
                            ForEach(Array(editor.playheadAudioTracks.enumerated()), id: \.offset) { ordinal, stream in
                                Text("Track \(ordinal + 1) · \(stream.audioFormatLabel)").tag(Optional(ordinal))
                            }
                        }
                        .pickerStyle(.inline)
                        .help("Choose monitored audio track")
                        if let note = editor.audioTrackFallbackNote {
                            // A menu shows text as an item that cannot be chosen.
                            Text(note)
                        }
                        Divider()
                        Button("Replace Source Audio…", action: editor.chooseReplacementAudio)
                            .disabled(!editor.canReplaceSourceAudio)
                            .help("Replace clip audio")
                    } label: {
                        Label(editor.useSavedMonitoringTracks ? "Source Audio" : "Track \(editor.playheadAnalysisTrack + 1)",
                              systemImage: "speaker.wave.2")
                    }
                    .barMenu()
                    .help("Monitor or replace audio")
                    silenceControls
                    StatusBarDivider()
                } else if let soundtrack = editor.stillSoundtrackControls {
                    Menu {
                        soundtrack.menuItems
                    } label: {
                        Label(soundtrack.name == nil ? "Add Soundtrack" : "Soundtrack", systemImage: "music.note")
                    }
                    .barMenu()
                    .help(soundtrack.name.map { "Manage soundtrack · \($0)" } ?? "Attach a soundtrack")
                    StatusBarDivider()
                } else if !editor.isEmpty {
                    Label("No audio track", systemImage: "speaker.slash")
                        .foregroundStyle(.tertiary)
                        .barLeading()
                    StatusBarDivider()
                }
                if let progress = editor.sceneProgress {
                    ProgressView(value: progress).frame(width: 72)
                        .accessibilityLabel("Scene analysis progress")
                    Text("\(editor.sceneStatus ?? "Scanning for scenes…") · \(progressPercent(progress))")
                        .monospacedDigit()
                    Button("Cancel", action: editor.cancelSceneAnalysisFromEditor)
                        .accessibilityLabel("Cancel scene analysis")
                        .help("Cancel scene scan")
                    StatusBarDivider()
                } else {
                    if editor.canScanScenes(clipID: nil) {
                        Menu {
                            SequenceFindSceneCommands(editor: editor)
                        } label: {
                            Label("Scan for Scenes", systemImage: "viewfinder")
                        }
                        .barMenu()
                        .help("Find scene changes")
                        .task(id: editor.sceneInspectionKey) { await editor.inspectSceneChoices() }
                        StatusBarDivider()
                    }
                    if let status = editor.sceneStatus {
                        Text(status).lineLimit(1).help(status)
                        StatusBarDivider()
                    }
                    if let label = editor.currentSceneLabel {
                        BarButton(label, symbol: "rectangle.on.rectangle", action: editor.renameCurrentView)
                            .monospacedDigit()
                            .disabled(!editor.canRenameCurrentView)
                            .help("Rename matching scene views")
                        StatusBarDivider()
                    }
                }
                ProjectMediaJobStatus(jobs: editor.projectMediaJobs) { editor.presentProjectMedia() }
                let mediaSummary = editor.projectMediaSummary
                if let title = mediaSummary.title {
                    let state: ProjectMediaStatus = mediaSummary.offline > 0 ? .offline : .needsReview
                    BarButton(title, symbol: state.editorIcon) { editor.presentProjectMedia() }
                        .foregroundStyle(Color(nsColor: state.editorColor))
                        .help("Open Project Media")
                    StatusBarDivider()
                }
                TimelineTierBadge(editor: editor)
                Text(editor.statusMessage)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(editor.statusMessage)
                Spacer(minLength: 8)
                if editor.lastExportedURL != nil {
                    BarButton("Show in Finder", symbol: "folder", action: editor.showExportInFinder)
                        .help("Reveal exported file")
                }
            }
        }
    }

    @ViewBuilder private var silenceControls: some View {
        let progress = editor.silenceProgress
        let count = editor.pausePlan.count
        let title = progress.map { "Finding silence… \(progressPercent($0))" }
            ?? (editor.pauseAnalysisReady ? (count == 1 ? "1 pause" : "\(count) pauses") : "Scan for Silence")
        BarButton(title, symbol: "waveform", active: presentation.pauseControls) {
            if editor.canScanSilence && !editor.pauseAnalysisReady { editor.scanForSilence() }
            presentation.pauseControls = true
        }
        .monospacedDigit()
        .popover(isPresented: $presentation.pauseControls, arrowEdge: .top) { PauseControls(editor: editor) }
        .help("Find and edit pauses")
        if progress != nil {
            Button("Cancel", action: editor.cancelSilenceScan)
                .accessibilityLabel("Cancel silence scan")
                .help("Cancel silence scan")
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
        if presentation.transcriptKeyHandler?(event, modifiers) == true { return nil }
        if modifiers == .option, event.charactersIgnoringModifiers?.lowercased() == "x", editor.canClearMarks {
            editor.clearMarks()
            return nil
        }
        if modifiers.isEmpty, editor.canNavigate {
            if let amount = TimelineViewControls.keyZoom(event.charactersIgnoringModifiers) {
                editor.timelineZoom = TimelineViewControls.adjustedZoom(editor.timelineZoom, by: amount)
                return nil
            }
            if editor.preview.handleSpeedKey(event) { return nil }
            if event.keyCode == 49 {
                if !event.isARepeat { editor.preview.togglePlayback() }
                return nil
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r" where editor.canEdit: editor.rangeTool = true
            case "a" where editor.canEdit: editor.rangeTool = false
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
                    Text("Drop audio or video here to start a sequence.")
                } actions: {
                    HStack(spacing: 10) {
                        Button("Add Clips…", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy)
                            .help("Add clips to sequence")
                        Button("Add as Multicam…", action: addMulticam)
                            .buttonStyle(.bordered)
                            .disabled(!canAddMulticam)
                            .help("Create multicam group")
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
