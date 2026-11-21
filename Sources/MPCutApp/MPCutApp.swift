import AppKit
import MPCutCore
import SwiftUI

@main
struct MPCutApp: App {
    @NSApplicationDelegateAdaptor private var application: EditorApplication
    @StateObject private var textFocus = TextFocus()

    var body: some Scene {
        WindowGroup("MPCut", id: ProjectSession.windowID, for: UUID.self) { $identifier in
            ProjectSessionHost(identifier: identifier, sessions: application.sessions)
        }
        .defaultSize(width: 1060, height: 730)
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
            EditorSettings(preferences: application.sessions.preferences)
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
            Divider()
            if let session {
                ProjectFileItems(session: session, editor: session.editor, multicam: session.multicam, sessions: sessions)
            } else {
                Button("Add Clips…") { sessions.chooseClips(using: openWindow) }
                    .keyboardShortcut("o")
                Button("Add as Multicam…") { sessions.chooseMulticamSources(using: openWindow) }
            }
            Button("Open Multicam Project…") { sessions.chooseProject(using: openWindow) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .importExport) {
            if let session {
                ExportCommands(editor: session.editor, multicam: session.multicam, isMulticam: isMulticam)
            }
        }
        CommandGroup(replacing: .undoRedo) {
            if let session {
                UndoCommands(editor: session.editor, multicam: session.multicam, text: textFocus, isMulticam: isMulticam)
            } else {
                Button("Undo") { activeTextUndoManager()?.undo() }
                    .keyboardShortcut("z")
                    .disabled(!textFocus.isEditing)
                Button("Redo") { activeTextUndoManager()?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!textFocus.isEditing)
            }
        }
        CommandMenu("Sequence") {
            if let session {
                SequenceCommands(editor: session.editor, multicam: session.multicam, isMulticam: isMulticam)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Show Video Monitor") { session?.showMonitor() }
                .disabled(session == nil)
            if let session {
                TimelineCommands(editor: session.editor, multicam: session.multicam, isMulticam: isMulticam)
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
        Button(session.isMulticam ? "Add Multicam Sources…" : "Add as Multicam…") {
            sessions.chooseMulticamSources(in: session)
        }
        .keyboardShortcut(session.isMulticam ? KeyboardShortcut("o") : nil)
        .disabled(session.isMulticam ? !multicam.canChooseSources : editor.isBusy)
        Divider()
        if session.isMulticam {
            Button("Save Project") { multicam.requestSaveProject() }
                .keyboardShortcut("s")
                .disabled(multicam.project == nil || multicam.isBusy)
            Button("Save Project As…") { multicam.requestSaveProject(asNew: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(multicam.project == nil || multicam.isBusy)
            Button("Save Analysis Sidecars", action: multicam.saveAnalysisSidecars)
                .disabled(!multicam.canSaveSidecars)
        } else {
            Button("Save Analysis Sidecars", action: editor.saveAnalysisSidecars)
                .keyboardShortcut("s")
                .help("Save the frame index and completed analysis beside each source file.")
                .disabled(!editor.canSaveAnalysisSidecars)
        }
    }
}

private struct TimelineCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let isMulticam: Bool

    var body: some View {
        if !isMulticam {
            Toggle(editor.isAudioOnly ? "Large Timeline Waveform" : "Large Timeline Thumbnails", isOn: $editor.largeThumbnails)
            Divider()
        }
        let zoom = isMulticam ? $multicam.timelineZoom : $editor.timelineZoom
        let isEmpty = isMulticam ? multicam.project == nil : editor.isEmpty
        Button("Zoom In on Timeline") { zoom.wrappedValue = min(SequenceTimeline.maximumZoom, zoom.wrappedValue + 1) }
            .disabled(isEmpty || zoom.wrappedValue >= SequenceTimeline.maximumZoom)
        Button("Zoom Out on Timeline") { zoom.wrappedValue = max(0, zoom.wrappedValue - 1) }
            .disabled(isEmpty || zoom.wrappedValue <= 0)
        Button("Fit Timeline") { zoom.wrappedValue = 0 }
            .disabled(isEmpty || zoom.wrappedValue == 0)
    }
}

private struct ExportCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let isMulticam: Bool

    var body: some View {
        if isMulticam {
            Button("Export Multicam…") { multicam.exportRequested.toggle() }
                .keyboardShortcut("e")
                .disabled(multicam.project == nil || multicam.isBusy)
            Button("Replace Source Audio…", action: multicam.chooseReplacementAudio)
                .disabled(!multicam.canReplaceSourceAudio)
            Button("Export Queue…", action: multicam.showBulkQueue)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!multicam.canShowBulkQueue)
            Button("Export Current Frame…", action: multicam.chooseStillFrame)
                .disabled(!multicam.canExportStillFrame)
            Button("Export JPEG Frames…", action: multicam.chooseJPEGExport)
                .disabled(multicam.project == nil || multicam.isBusy)
            Divider()
            Button("Cancel Multicam Operation", action: multicam.cancel)
                .disabled(!multicam.isBusy)
        } else {
            Button("Export Media…", action: editor.chooseExport)
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!editor.canEdit)
            Menu("Export Media As") {
                ForEach(editor.isAudioOnly ? [.copy] : [ExportMode.smart, .copy, .encode], id: \.self) { mode in
                    Button("\(mode.displayName)…") { editor.chooseExport(mode: mode) }
                }
            }
            .disabled(!editor.canEdit)
            Button("Replace Source Audio…", action: editor.chooseReplacementAudio)
                .disabled(!editor.canReplaceSourceAudio)
            Button("Export Queue…", action: editor.showBulkQueue)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!editor.canShowBulkQueue)
            Button("Export Current Frame…", action: editor.chooseStillFrame)
                .disabled(!editor.canEdit || editor.jpegSourceAtPlayhead == nil)
            Button("Export JPEG Frames…", action: editor.chooseJPEGExport)
                .disabled(!editor.canEdit || editor.audioPreviewClip != nil)
            Button("Show Last Export in Finder", action: editor.showExportInFinder)
                .disabled(editor.lastExportedURL == nil)
            Divider()
            Button("Cancel Import", action: editor.cancelImport)
                .disabled(!editor.isImporting || editor.isCancelling)
            Button("Cancel Export", action: editor.cancelExport)
                .disabled(!editor.isExporting || editor.isCancelling)
        }
    }
}

private struct SequenceCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let isMulticam: Bool

    var body: some View {
        if isMulticam {
            Button("Mark In") { multicam.markIn = multicam.markAnalysisTime() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(multicam.project == nil || multicam.isBusy)
            Button("Mark Out") { multicam.markOut = multicam.markAnalysisTime() }
                .keyboardShortcut("o", modifiers: [])
                .disabled(multicam.project == nil || multicam.isBusy)
            Button("Clear Marks") {
                multicam.markIn = nil
                multicam.markOut = nil
            }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(multicam.markIn == nil && multicam.markOut == nil)
            Button("Add Marked Range to Assembly", action: multicam.addMarkedRange)
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!multicam.canAddMarkedRange)
            Button("Add Marked Range to Export Queue", action: multicam.enqueueMarkedRange)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!multicam.canEnqueueMarkedRange)
            Button("Remove Marked Range from Assembly", action: multicam.removeMarkedRange)
                .disabled(multicam.isBusy || multicam.markedGroupSpan == nil)
            Divider()
            MulticamRangeCommands(model: multicam, preview: multicam.preview)
            Button(multicam.deleteTitle, action: multicam.deleteSelection)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!multicam.canDeleteSelection)
            Menu("Snap To") {
                SnapTargetPicker(selection: Binding(get: { multicam.analysis.snapTarget }, set: multicam.setAnalysisSnap), audioOnly: false)
                    .labelsHidden()
                    .pickerStyle(.inline)
            }
            .disabled(multicam.project == nil || multicam.isBusy)
        } else {
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
            Menu("Snap To") {
                SnapTargetPicker(selection: Binding(get: { editor.effectiveSnapTarget }, set: editor.chooseSnapTarget), audioOnly: editor.isAudioOnly)
                    .labelsHidden()
                    .pickerStyle(.inline)
            }
        }
    }
}

private struct MulticamRangeCommands: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        Menu("Trim Selected Range") {
            Button("Trim Start to Playhead") { model.trimOccurrence(.start) }
            Button("Trim End to Playhead") { model.trimOccurrence(.end) }
        }
        .disabled(!model.canTrimOccurrence)
        Button("Split Assembly Range at Playhead", action: model.splitOccurrence)
            .keyboardShortcut("b")
            .disabled(!model.canCutOccurrence)
    }
}

private struct PlaybackCommands: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preview: SequencePreview

    var body: some View {
        Button(editor.pauseAnalysisReady ? "Rescan Silence" : "Scan for Silence", action: editor.scanForSilence)
            .disabled(!editor.canScanSilence)
        Button("Cancel Silence Scan", action: editor.cancelSilenceScan)
            .disabled(editor.silenceProgress == nil)
        EditorBoundaryCommands(name: "Silence", modifiers: [.control, .option],
                               enabled: editor.pauseAnalysisReady && !editor.pausePlan.isEmpty, step: editor.stepPause)
        Toggle("Skip Pauses During Playback", isOn: $editor.skipPauses)
            .disabled(!editor.pauseAnalysisReady)
        Divider()
        EditorTransportCommands(preview: preview, canNavigate: editor.canNavigate, canStep: editor.canEdit,
                                canPlay: editor.canNavigate && !preview.hasBlockingIssue, audioOnly: editor.isAudioOnly, enterTime: editor.seekUsingTimeField,
                                seekBoundary: { editor.seek($0 ? editor.duration : 0) }, step: { editor.step($0) })
        Button("Scan for Scenes", action: editor.scanForScenes)
            .disabled(!editor.canScanScenes)
        Button("Cancel Scene Analysis", action: editor.cancelSceneAnalysis)
            .disabled(editor.sceneProgress == nil)
        Button("Rename Current View…", action: editor.renameCurrentView)
            .disabled(!editor.canRenameCurrentView)
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

    var body: some View {
        Button(text.isEditing || isMulticam ? "Undo" : editor.undoTitle) {
            if let text = activeTextUndoManager() { if text.canUndo { text.undo() } }
            else if isMulticam { multicam.undo() }
            else { editor.undo() }
        }
        .keyboardShortcut("z")
        .disabled(!text.isEditing && !(isMulticam ? !multicam.isBusy && !multicam.undoStack.isEmpty : editor.canUndo))
        Button(text.isEditing || isMulticam ? "Redo" : editor.redoTitle) {
            if let text = activeTextUndoManager() { if text.canRedo { text.redo() } }
            else if isMulticam { multicam.redo() }
            else { editor.redo() }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!text.isEditing && !(isMulticam ? !multicam.isBusy && !multicam.redoStack.isEmpty : editor.canRedo))
    }
}

@MainActor private var activeTextView: NSTextView? {
    guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return nil }
    return text
}

/// While text is being edited, Undo belongs to the text field rather than to the timeline.
@MainActor private func activeTextUndoManager() -> UndoManager? {
    activeTextView.map { $0.undoManager ?? UndoManager() }
}

/// A focus change publishes nothing by itself, so the Undo commands follow it from here.
@MainActor private final class TextFocus: ObservableObject {
    @Published private(set) var isEditing = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let editing = activeTextView != nil
                if editing != self.isEditing { self.isEditing = editing }
            }
        }
    }
}


private struct MulticamPlaybackCommands: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        Button("Scan for Silence") { model.scanAnalysis(.silence) }
            .disabled(!model.canScanAnalysis(.silence))
        Button("Cancel Silence Scan") { model.cancelAnalysis(.silence) }
            .disabled(model.analysis.silenceProgress == nil)
        EditorBoundaryCommands(name: "Silence", modifiers: [.control, .option], enabled: model.canStepAnalysis(.silence)) {
            model.stepAnalysis(.silence, direction: $0)
        }
        Toggle("Skip Pauses During Playback", isOn: Binding(get: { model.pauseEdits.skip }, set: { model.pauseEdits.skip = $0 }))
            .disabled(!model.canApplyPauses)
        Divider()
        EditorTransportCommands(preview: preview, canNavigate: canNavigate, canStep: canNavigate, canPlay: canNavigate,
                                enterTime: { model.timeEntryRequest += 1 },
                                seekBoundary: model.seekPlaybackBoundary, step: model.step)
        Button("Scan for Scenes") { model.scanAnalysis(.scenes) }
            .disabled(!model.canScanAnalysis(.scenes))
        Button("Cancel Scene Analysis") { model.cancelAnalysis(.scenes) }
            .disabled(!model.analysis.isScanning(.scenes))
        Button("Rename Current View…", action: model.renameCurrentView)
            .disabled(!model.canRenameCurrentView)
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
