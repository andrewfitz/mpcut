import AppKit
import MPCutCore
import SwiftUI

struct MPCutApp: App {
    @NSApplicationDelegateAdaptor private var application: EditorApplication
    @StateObject private var textFocus = TextFocus()

    var body: some Scene {
        WindowGroup("MPCut", id: ProjectSession.windowID, for: UUID.self) { $identifier in
            ProjectSessionHost(identifier: identifier, sessions: application.sessions)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            AboutCommands()
            ProjectCommands(sessions: application.sessions, textFocus: textFocus)
        }
        Window("About MPCut", id: "about") {
            AboutMPCut()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        Settings {
            EditorSettings(preferences: application.sessions.preferences) {
                SidecarClearContext(sessions: application.sessions)
            }
        }
    }
}

private struct ProjectCommands: Commands {
    @ObservedObject var sessions: ProjectSessions
    @ObservedObject var textFocus: TextFocus
    @Environment(\.openWindow) private var openWindow
    private var session: ProjectSession? { sessions.commandContext?.session }
    private var isMulticam: Bool { sessions.commandContext?.isMulticam == true }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project Window") { sessions.newWindow(using: openWindow) }
                .keyboardShortcut("n")
                .help("Open blank project window")
            Divider()
            if let session {
                ProjectFileItems(session: session, editor: session.editor, multicam: session.multicam, sessions: sessions)
            } else {
                Button("Add Clips…") { sessions.chooseClips(using: openWindow) }
                    .keyboardShortcut("o")
                    .help("Add clips to sequence")
                Button("Add as Multicam…") { sessions.chooseMulticamSources(using: openWindow) }
                    .help("Add multicam sources")
            }
            Button("Open MPCut Project…") { sessions.chooseProject(using: openWindow) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .help("Open saved project")
            RecentFilesMenu(files: sessions.preferences.recentFiles) { url in
                sessions.setWindowOpener(openWindow)
                sessions.openFiles([url], in: session)
            }
            Button("Recover Untitled Project…") { sessions.recoverUntitledProject(using: openWindow) }
                .help("Recover unsaved project")
        }
        CommandGroup(after: .importExport) {
            Button(sessions.isConvertingProject ? "Converting Project…" : "Import External Project…") { sessions.chooseExternalImport(in: session, using: openWindow) }
                .disabled(sessions.isConvertingProject)
                .help("Import external project")
            if sessions.isConvertingProject {
                Button(sessions.isCancellingProject ? "Cancelling Project Conversion…" : "Cancel Project Conversion",
                       action: sessions.cancelProjectConversion)
                    .disabled(sessions.isCancellingProject)
                    .help("Cancel project conversion")
            }
            if let session {
                ExportCommands(editor: session.editor, multicam: session.multicam, isMulticam: isMulticam,
                               isConverting: sessions.isConvertingProject, export: { sessions.chooseExternalExport($0, in: session) })
            }
        }
        CommandGroup(replacing: .undoRedo) {
            if let session {
                UndoCommands(editor: session.editor, multicam: session.multicam, text: textFocus,
                             isMulticam: isMulticam, showHistory: { session.isHistoryPresented = true })
            } else {
                Button(textFocus.undoTitle) { textFocus.performUndo() }
                    .keyboardShortcut("z")
                    .disabled(!textFocus.canUndo)
                    .help("Undo text edit")
                Button(textFocus.redoTitle) { textFocus.performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!textFocus.canRedo)
                    .help("Redo text edit")
                Button("Project History…") {}
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                    .disabled(true)
                    .help("Open project history")
            }
        }
        CommandMenu("Sequence") {
            if let session {
                SequenceCommands(editor: session.editor, multicam: session.multicam, isMulticam: isMulticam,
                                 showTimelineMap: { session.isTimelineMapPresented = true })
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Show Video Monitor") { session?.showMonitor() }
                .disabled(session == nil)
                .help("Show separate video preview")
            if let session {
                TimelineCommands(editor: session.editor, multicam: session.multicam, isMulticam: isMulticam) {
                    let presentation = session.presentation
                    presentation.setTranscriptVisible(!presentation.transcriptVisible(multicam: isMulticam), multicam: isMulticam)
                }
            }
        }
        CommandMenu("Playback") {
            if let session {
                if isMulticam {
                    MulticamPlaybackCommands(model: session.multicam, preview: session.multicam.preview)
                } else {
                    PlaybackCommands(editor: session.editor, preview: session.editor.preview)
                }
            }
        }
    }
}

private struct ProjectFileItems: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let sessions: ProjectSessions

    var body: some View {
        Button("Add Clips…") { editor.chooseFiles() }
            .keyboardShortcut(session.isMulticam ? nil : KeyboardShortcut("o"))
            .disabled(session.isMulticam || editor.isBusy)
            .help("Add clips to sequence")
        Button(session.isMulticam ? "Add Multicam Sources…" : "Add as Multicam…") {
            sessions.chooseMulticamSources(in: session)
        }
        .keyboardShortcut(session.isMulticam ? KeyboardShortcut("o") : nil)
        .disabled(session.isMulticam ? !multicam.canChooseSources : editor.isBusy)
        .help("Add multicam sources")
        Divider()
        Button("Save Project") {
            if session.isMulticam { multicam.requestSaveProject() } else { editor.requestSaveProject() }
        }
        .keyboardShortcut("s")
        .disabled(session.isMulticam ? multicam.project == nil || multicam.isBusy : editor.isBusy)
        .help("Save current project")
        Button("Save Project As…") {
            if session.isMulticam { multicam.requestSaveProject(asNew: true) } else { editor.requestSaveProject(asNew: true) }
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(session.isMulticam ? multicam.project == nil || multicam.isBusy : editor.isBusy)
        .help("Save under another name")
        Button("Refresh Project Media") {
            if session.isMulticam { multicam.refreshProjectMedia() } else { editor.refreshProjectMedia() }
        }
        .disabled(session.isMulticam ? !multicam.canRefreshProjectMedia : !editor.canRefreshProjectMedia)
        .help("Refresh changed media")
        Button("Relink Offline Media…") {
            if session.isMulticam { multicam.presentProjectMedia(offlineOnly: true) }
            else { editor.presentProjectMedia(offlineOnly: true) }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(session.isMulticam ? multicam.project == nil : editor.isEmpty)
        Button("Project Media…") {
            if session.isMulticam { multicam.presentProjectMedia() }
            else { editor.presentProjectMedia() }
        }
        .disabled(session.isMulticam ? multicam.project == nil : editor.isEmpty)
        Button("Deep Verify Project Media") {
            if session.isMulticam { multicam.refreshProjectMedia(deep: true) } else { editor.refreshProjectMedia(deep: true) }
        }
        .help("Verify source file contents")
        .disabled(session.isMulticam ? !multicam.canRefreshProjectMedia : !editor.canRefreshProjectMedia)
        if session.isMulticam {
            Button("Save Analysis Sidecars", action: multicam.saveAnalysisSidecars)
                .disabled(!multicam.canSaveSidecars)
                .help("Save the edit index and analysis to the sidecar location chosen in Settings.")
        } else {
            Button("Save Analysis Sidecars", action: editor.saveAnalysisSidecars)
                .help("Save the edit index and analysis to the sidecar location chosen in Settings.")
                .disabled(!editor.canSaveAnalysisSidecars)
        }
    }
}

private struct TimelineCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let isMulticam: Bool

    let toggleTranscript: () -> Void

    var body: some View {
        Button("Toggle Transcript", action: toggleTranscript)
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(isMulticam ? multicam.project == nil : editor.isEmpty)
        if !isMulticam {
            Toggle("Enlarge Thumbnails and Waveforms", isOn: $editor.largeThumbnails)
                .help("Enlarge timeline previews")
            Divider()
        }
        let zoom = isMulticam ? $multicam.timelineZoom : $editor.timelineZoom
        let isEmpty = isMulticam ? multicam.project == nil : editor.isEmpty
        Button("Zoom In on Timeline") { zoom.wrappedValue = TimelineViewControls.adjustedZoom(zoom.wrappedValue, by: 1) }
            .keyboardShortcut("=")
            .disabled(isEmpty || zoom.wrappedValue >= SequenceTimeline.maximumZoom)
            .help("Zoom in (⌘=)")
        Button("Zoom Out on Timeline") { zoom.wrappedValue = TimelineViewControls.adjustedZoom(zoom.wrappedValue, by: -1) }
            .keyboardShortcut("-")
            .disabled(isEmpty || zoom.wrappedValue <= 0)
            .help("Zoom out (⌘−)")
        Button(zoom.wrappedValue > 0 ? "Fit Timeline" : "Restore Timeline Zoom") {
            zoom.wrappedValue = zoom.wrappedValue > 0 ? 0 : (isMulticam ? multicam.previousTimelineZoom : editor.previousTimelineZoom)
        }
        .keyboardShortcut("z", modifiers: .shift)
        .disabled(isEmpty)
        .help(zoom.wrappedValue > 0 ? "Fit timeline" : "Restore timeline zoom")
    }
}

private struct ExportCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let isMulticam: Bool

    let isConverting: Bool
    let export: (ExternalProjectFormat) -> Void

    var body: some View {
        Menu("Export Project") {
            ForEach(ExternalProjectFormat.allCases, id: \.rawValue) { format in
                Button(format.title + " (." + format.rawValue + ")…") { export(format) }
                    .help("Export \(format.title) project")
            }
        }
        .disabled(isConverting || (isMulticam ? multicam.project == nil || multicam.isBusy : !editor.canEdit))
        .help("Choose project export format")
        Button("Send Timeline to DaVinci Resolve via FCPXML…") {
            if isMulticam { multicam.chooseResolveExport() }
            else { editor.chooseResolveExport() }
        }
        .disabled(isMulticam ? multicam.project == nil || multicam.isBusy : !editor.canEdit)
        .help("Send timeline to Resolve")
        Button("Export Selection…") {
            if isMulticam { multicam.chooseSelectionExport() } else { editor.chooseSelectionExport() }
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(isMulticam ? !multicam.canActOnRange : !editor.canActOnRange)
        .help("Export selected range")
        if isMulticam {
            Button("Export Multicam…", action: multicam.chooseProgramExport)
                .keyboardShortcut("e")
                .disabled(multicam.project == nil || multicam.isBusy)
                .help("Export multicam program")
            Button("Replace Program Audio…", action: multicam.chooseReplacementAudio)
                .disabled(!multicam.canReplaceSourceAudio)
                .help("Replace multicam soundtrack")
            Button("Export Queue…", action: multicam.showBulkQueue)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!multicam.canShowBulkQueue)
                .help("Open export queue")
            Button("Export Current Frame…", action: multicam.chooseStillFrame)
                .disabled(!multicam.canExportStillFrame)
                .help("Save current frame")
            Button("Export JPEG Frames…", action: multicam.chooseJPEGExport)
                .disabled(multicam.project == nil || multicam.isBusy)
                .help("Export frames as JPEGs")
            Divider()
            Button("Cancel Multicam Operation", action: multicam.cancel)
                .disabled(!multicam.isBusy)
                .help("Cancel multicam operation")
        } else {
            Button("Export Media…", action: editor.chooseExport)
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!editor.canEdit)
                .help("Export edited sequence")
            Menu("Export Media As") {
                // The modes and their names for this source come from the export rules, as the sheet's Mode control does.
                let source: ExportSourceKind = editor.isAudioOnly ? .audio : .movie
                ForEach(ExportEntryPoint.sheet.selectableModes(source: source, tracks: .all), id: \.self) { mode in
                    Button("\(ExportRules.cell(source: source, tracks: .all, mode: mode).displayName)…") { editor.chooseExport(mode: mode) }
                        .help("Export with this mode")
                }
            }
            .disabled(!editor.canEdit)
            .help("Choose media export mode")
            Button("Replace Source Audio…", action: editor.chooseReplacementAudio)
                .disabled(!editor.canReplaceSourceAudio)
                .help("Replace clip audio")
            Button("Export Queue…", action: editor.showBulkQueue)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!editor.canShowBulkQueue)
                .help("Open export queue")
            Button("Export Current Frame…", action: editor.chooseStillFrame)
                .disabled(!editor.canEdit || editor.jpegSourceAtPlayhead?.frame == nil)
                .help("Save current frame")
            Button("Export JPEG Frames…", action: editor.chooseJPEGExport)
                .disabled(!editor.canEdit || editor.audioPreviewClip != nil)
                .help("Export frames as JPEGs")
            Button("Show Last Export in Finder", action: editor.showExportInFinder)
                .disabled(editor.lastExportedURL == nil)
                .help("Reveal last export")
            Divider()
            Button("Cancel Import", action: editor.cancelImport)
                .disabled(!editor.isImporting || editor.isCancelling)
                .help("Cancel clip import")
            Button("Cancel Export", action: editor.cancelExport)
                .disabled(!editor.isExporting || editor.isCancelling)
                .help("Cancel media export")
        }
    }
}

private struct SequenceCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let isMulticam: Bool

    let showTimelineMap: () -> Void

    var body: some View {
        let tool = isMulticam ? $multicam.rangeTool : $editor.rangeTool
        Picker("Timeline Tool", selection: tool) {
            Text("Pointer (A)").tag(false)
            Text("Range Selection (R)").tag(true)
        }
        .pickerStyle(.inline)
        .disabled(isMulticam ? multicam.project == nil || multicam.isBusy : !editor.canEdit)
        .help("Choose timeline tool")
        Divider()
        if isMulticam {
            Button("Replace Picture…", action: multicam.chooseReplaceMulticamPicture)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!multicam.canReplaceMulticamPicture)
                .help("Replace picture with still")
            Button("Insert Still…", action: multicam.chooseInsertMulticamStill)
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(multicam.project == nil || multicam.isBusy)
                .help("Insert a still image")
            Button("Space Clips…", action: multicam.chooseSpaceClips)
                .disabled(!multicam.canSpaceClips)
            Button("Insert Color Gap…", action: multicam.chooseInsertGap)
                .disabled(multicam.project == nil || multicam.isBusy)
            Divider()
            Button("Mark In") { multicam.markIn = multicam.markAnalysisTime() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(multicam.project == nil || multicam.isBusy)
                .help("Set range start")
            Button("Mark Out") { multicam.markOut = multicam.markAnalysisTime() }
                .keyboardShortcut("o", modifiers: [])
                .disabled(multicam.project == nil || multicam.isBusy)
                .help("Set range end")
            Button("Clear Marks") {
                multicam.markIn = nil
                multicam.markOut = nil
            }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(multicam.markIn == nil && multicam.markOut == nil && multicam.assemblySelection == nil)
                .help("Clear range marks")
            Button("Add Marked Range to Assembly") { multicam.byHand(multicam.addMarkedRange) }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!multicam.canAddMarkedRange)
                .help("Add range to assembly")
            Button("Add Marked Range to Export Queue", action: multicam.enqueueMarkedRange)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!multicam.canEnqueueMarkedRange)
                .help("Queue marked range")
            Button("Remove Marked Range from Assembly") { multicam.byHand(multicam.removeMarkedRange) }
                .disabled(multicam.isBusy || multicam.markedGroupSpan == nil)
                .help("Remove range from assembly")
            Divider()
            MulticamRangeCommands(model: multicam, preview: multicam.preview)
            Button(multicam.deleteTitle, action: multicam.deleteSelection)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!multicam.canDeleteSelection)
                .help("Delete selected material")
            Menu("Snap To") {
                SnapTargetPicker(selection: Binding(get: { multicam.analysis.snapTarget }, set: multicam.setAnalysisSnap), audioOnly: false)
                    .labelsHidden()
                    .pickerStyle(.inline)
            }
            .disabled(multicam.project == nil || multicam.isBusy)
            .help("Choose snapping targets")
        } else {
            Button("Replace Picture…", action: editor.chooseReplacePicture)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!editor.canReplacePicture)
                .help("Replace picture with still")
            Button("Insert Still…", action: editor.chooseInsertStill)
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!editor.canInsertStill)
                .help("Insert a still image")
            Button("Space Clips…", action: editor.chooseSpaceClips)
                .disabled(!editor.canSpaceClips)
            Button("Insert Color Gap…", action: editor.chooseInsertGap)
                .disabled(!editor.canInsertStill)
            Divider()
            Button("Mark In", action: editor.setIn)
                .keyboardShortcut("i", modifiers: [])
                .disabled(!editor.canEdit)
                .help("Set range start")
            Button("Mark Out", action: editor.setOut)
                .keyboardShortcut("o", modifiers: [])
                .disabled(!editor.canEdit)
                .help("Set range end")
            Button("Clear Marks", action: editor.clearMarks)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!editor.canClearMarks)
                .help("Clear range marks")
            Button("Add Marked Range to Export Queue", action: editor.addMarkedRange)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!editor.canAddMarkedRange)
                .help("Queue marked range")
            Divider()
            Button(editor.rangeTool ? "Split at Selection Edges" : "Split at Playhead") {
                if editor.rangeTool { editor.byHand(editor.splitSelectedRange) } else { editor.split() }
            }
            .keyboardShortcut("b")
            .disabled(editor.rangeTool ? !editor.canSplitSelectedRange : !editor.canEdit)
            .help(editor.rangeTool ? "Split at range edges" : "Split at playhead")
            Button(editor.deleteTitle) { editor.byHand(editor.deleteSelection) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!editor.canDelete)
                .help("Delete selected material")
            Divider()
            Button("Apply CSV to Selected Clip…", action: editor.chooseClipCSV)
                .disabled(!editor.canEdit || editor.selectedID == nil)
                .help("Import CSV edits")
            Menu("Trim Selected Clip") {
                Button("Trim Start to Playhead") { editor.trimSelected(.start) }
                    .disabled(!editor.canTrimSelected(.start, restore: false))
                    .help("Set start at playhead")
                Button("Trim End to Playhead") { editor.trimSelected(.end) }
                    .disabled(!editor.canTrimSelected(.end, restore: false))
                    .help("Set end at playhead")
                Divider()
                Button("Restore Original Start") { editor.trimSelected(.start, restore: true) }
                    .disabled(!editor.canTrimSelected(.start, restore: true))
                    .help("Restore original clip start")
                Button("Restore Original End") { editor.trimSelected(.end, restore: true) }
                    .disabled(!editor.canTrimSelected(.end, restore: true))
                    .help("Restore original clip end")
            }
            .help("Show clip trim controls")
            Button("Move Selected Clip Earlier") { editor.moveSelectedClip(by: -1) }
                .disabled(!editor.canMoveEarlier)
                .help("Move clip earlier")
            Button("Move Selected Clip Later") { editor.moveSelectedClip(by: 1) }
                .disabled(!editor.canMoveLater)
                .help("Move clip later")
            Menu("Snap To") {
                SnapTargetPicker(selection: Binding(get: { editor.effectiveSnapTarget }, set: editor.chooseSnapTarget), audioOnly: editor.isAudioOnly)
                    .labelsHidden()
                    .pickerStyle(.inline)
            }
            .help("Choose snapping targets")
        }
        Button("Preview Selected Join") {
            if isMulticam { multicam.previewSelectedJoin() } else { editor.previewSelectedJoin() }
        }
        .disabled(isMulticam ? !multicam.canPreviewSelectedJoin : !editor.canPreviewSelectedJoin)
        .help("Audition the incoming join of the selected clip, assembly range, or switch")
        Button("Map Timeline Range…", action: showTimelineMap)
            .disabled(isMulticam ? multicam.project == nil : editor.isEmpty)
            .help("Map a range between source and output time")
    }
}

private struct MulticamRangeCommands: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        Menu("Trim Selected Range") {
            Button("Trim Start to Playhead") { model.trimOccurrence(.start) }
                .help("Set start at playhead")
            Button("Trim End to Playhead") { model.trimOccurrence(.end) }
                .help("Set end at playhead")
        }
        .disabled(!model.canTrimOccurrence)
        .help("Show range trim controls")
        Button(model.rangeTool ? "Split at Selection Edges" : "Split Assembly Range at Playhead") {
            model.byHand { if model.rangeTool { model.splitSelectedRange() } else { model.splitOccurrence() } }
        }
        .keyboardShortcut("b")
        .disabled(model.rangeTool ? !model.canSplitSelectedRange : !model.canCutOccurrence)
        .help(model.rangeTool ? "Split at range edges" : "Split at playhead")
    }
}

private struct PlaybackCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preview: SequencePreview

    var body: some View {
        Button(editor.pauseAnalysisReady ? "Rescan Silence" : "Scan for Silence", action: editor.scanForSilence)
            .disabled(!editor.canScanSilence)
            .help("Detect silent sections")
        Button("Cancel Silence Scan", action: editor.cancelSilenceScan)
            .disabled(editor.silenceProgress == nil)
            .help("Cancel silence scan")
        EditorBoundaryCommands(name: "Silence", modifiers: [.control, .option],
                               enabled: editor.pauseAnalysisReady && !editor.pausePlan.isEmpty, step: editor.stepPause)
        Toggle("Skip Pauses During Playback", isOn: $editor.skipPauses)
            .disabled(!editor.pauseAnalysisReady)
            .help("Skip pauses in preview")
        Divider()
        EditorTransportCommands(preview: preview, canNavigate: editor.canNavigate, canStep: editor.canEdit,
                                canPlay: editor.canNavigate && !preview.hasBlockingIssue, audioOnly: editor.isAudioOnly, enterTime: editor.seekUsingTimeField,
                                seekBoundary: { editor.seek($0 ? editor.duration : 0) }, step: { editor.step($0) })
        Menu("Scan for Scenes") { SequenceFindSceneCommands(editor: editor) }
            .disabled(!editor.canScanScenes(clipID: nil))
            .help("Show scene scan options")
        Button("Cancel Scene Analysis", action: editor.cancelSceneAnalysisFromEditor)
            .disabled(editor.sceneProgress == nil)
            .help("Cancel scene scan")
        Button("Rename Current View…", action: editor.renameCurrentView)
            .disabled(!editor.canRenameCurrentView)
            .help("Rename matching scene views")
        EditorBoundaryCommands(name: "Scene", modifiers: .shift, enabled: editor.canStepScenes, step: editor.stepScene)
        EditorBoundaryCommands(name: "Keyframe", enabled: editor.canEdit && !editor.isAudioOnly) { editor.step($0, keyframes: true) }
        Divider()
        EditorAudioCommands(preview: preview)
    }
}

private struct UndoCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    @ObservedObject var text: TextFocus
    let isMulticam: Bool
    let showHistory: () -> Void

    var body: some View {
        Button(text.isEditing ? text.undoTitle : (isMulticam ? multicam.undoTitle : editor.undoTitle)) {
            text.performUndo { if isMulticam { multicam.undo() } else { editor.undo() } }
        }
        .keyboardShortcut("z")
        .disabled(text.isEditing ? !text.canUndo : (isMulticam ? multicam.isBusy || multicam.undoStack.isEmpty : !editor.canUndo))
        .help("Undo last change")
        Button(text.isEditing ? text.redoTitle : (isMulticam ? multicam.redoTitle : editor.redoTitle)) {
            text.performRedo { if isMulticam { multicam.redo() } else { editor.redo() } }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(text.isEditing ? !text.canRedo : (isMulticam ? multicam.isBusy || multicam.redoStack.isEmpty : !editor.canRedo))
        .help("Redo last change")
        Button("Project History…", action: showHistory)
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(isMulticam ? multicam.isBusy || multicam.notice != nil : editor.isBusy || editor.alert != nil)
            .help("Open project history")
    }
}

/// Project shortcuts follow the field editor while it owns the keyboard, even if its undo stack is empty.
@MainActor final class TextFocus: NSObject, ObservableObject {
    private struct Editing: Equatable {
        let undo: String?
        let redo: String?
    }

    @Published private var editing: Editing?
    private let keyWindow: @MainActor () -> NSWindow?
    var isEditing: Bool { editing != nil }
    var canUndo: Bool { editing?.undo != nil }
    var canRedo: Bool { editing?.redo != nil }
    var undoTitle: String { editing?.undo ?? "Undo" }
    var redoTitle: String { editing?.redo ?? "Redo" }

    init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow }) {
        self.keyWindow = keyWindow
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: NSApplication.didUpdateNotification, object: nil)
        refresh()
    }

    private var fieldEditor: NSTextView? {
        guard let view = keyWindow()?.firstResponder as? NSTextView, view.isEditable else { return nil }
        return view
    }

    @objc func refresh() {
        let state = fieldEditor.map { view in
            let manager = view.undoManager
            return Editing(undo: manager?.canUndo == true ? manager?.undoMenuItemTitle : nil,
                           redo: manager?.canRedo == true ? manager?.redoMenuItemTitle : nil)
        }
        if state != editing { editing = state }
    }

    func performUndo(timeline: () -> Void = {}) {
        if let view = fieldEditor {
            if let manager = view.undoManager, manager.canUndo { manager.undo() }
        } else { timeline() }
        refresh()
    }

    func performRedo(timeline: () -> Void = {}) {
        if let view = fieldEditor {
            if let manager = view.undoManager, manager.canRedo { manager.redo() }
        } else { timeline() }
        refresh()
    }
}

private struct MulticamPlaybackCommands: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        Button("Scan for Silence") { model.scanAnalysis(.silence) }
            .disabled(!model.canScanAnalysis(.silence))
            .help("Detect silent sections")
        Button("Cancel Silence Scan") { model.cancelAnalysis(.silence) }
            .disabled(model.analysis.silenceProgress == nil)
            .help("Cancel silence scan")
        EditorBoundaryCommands(name: "Silence", modifiers: [.control, .option], enabled: model.canStepAnalysis(.silence)) {
            model.stepAnalysis(.silence, direction: $0)
        }
        Toggle("Skip Pauses During Playback", isOn: Binding(get: { model.pauseEdits.skip }, set: { model.pauseEdits.skip = $0 }))
            .disabled(!model.canApplyPauses)
            .help("Skip pauses in preview")
        Divider()
        EditorTransportCommands(preview: preview, canNavigate: canNavigate, canStep: canNavigate, canPlay: canNavigate,
                                enterTime: { model.timeEntryRequest += 1 },
                                seekBoundary: model.seekPlaybackBoundary, step: model.step)
        Menu("Scan for Scenes") { MulticamFindSceneCommands(model: model) }
            .disabled(model.isBusy || !model.analysis.canScanScenes(camera: nil))
            .help("Show scene scan options")
        Button("Cancel Scene Analysis", action: model.analysis.cancelSceneAnalysisFromEditor)
            .disabled(!model.analysis.isScanning(.scenes))
            .help("Cancel scene scan")
        Button("Rename Current View…", action: model.renameCurrentView)
            .disabled(!model.canRenameCurrentView)
            .help("Rename matching scene views")
        EditorBoundaryCommands(name: "Scene", modifiers: .shift, enabled: model.canStepAnalysis(.scenes)) {
            model.stepAnalysis(.scenes, direction: $0)
        }
        EditorBoundaryCommands(name: "Keyframe", enabled: model.canStepAnalysis(.keyframes)) {
            model.stepAnalysis(.keyframes, direction: $0)
        }
        Divider()
        EditorAudioCommands(preview: preview)
    }

    private var canNavigate: Bool { model.project != nil && !model.isBusy }
}
