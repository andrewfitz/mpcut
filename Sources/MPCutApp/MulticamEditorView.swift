import AppKit
import Combine
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

struct MulticamEditorView: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var presentation: EditorPresentation
    @State private var showingReport = false

    var body: some View {
        let setupID = model.setupPresentationID
        Group {
            if let project = model.project {
                editor(project)
            } else {
                EditorWorkspace(viewer: emptyViewer, transport: EmptyView(), timeline: EmptyView(), status: status,
                                showsTimeline: false, showsStatus: showsStatus)
            }
        }
        .background(EditorKeyboardMonitor(handle: handleKey))
        .modifier(MulticamPausePlayback(model: model))
        .navigationTitle(windowTitle)
        .navigationSubtitle(cameraSummary)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.project != nil {
                    ExportQueueToolbarButton(count: model.queuedRanges.count, action: model.showBulkQueue)
                        .disabled(!model.canShowBulkQueue)
                    MulticamPreviewSoundControls(preview: model.preview)
                    EditorToolbarButton(title: "Add Sources", symbol: "plus", toolTip: "Add multicam sources (⌘O)",
                                        action: model.chooseSources)
                        .disabled(!model.canChooseSources)
                    EditorToolbarButton(title: "Export", symbol: "square.and.arrow.up", toolTip: "Export multicam (⌘E)",
                                        action: model.chooseProgramExport)
                        .disabled(model.isBusy)
                    Button("Save Project", systemImage: "square.and.arrow.down") { _ = model.saveProject() }
                        .labelStyle(.iconOnly)
                        .help("Save multicam project (⌘S)")
                        .disabled(model.isBusy)
                    Button(presentation.inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") {
                        presentation.inspectorVisible.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .help(presentation.inspectorVisible ? "Hide Multicam Inspector" : "Show Multicam Inspector")
                }
            }
        }
        .onChange(of: model.exportRequested) { _, _ in
            presentation.inspector = .export
            presentation.inspectorVisible = true
        }
        .onChange(of: model.suggestionAnchor) { _, at in
            if at != nil {
                presentation.inspector = .switches
                presentation.inspectorVisible = true
            }
        }
        .onChange(of: model.splitRevision) { _, _ in
            presentation.inspector = .assembly
            presentation.inspectorVisible = true
        }
        .onChange(of: model.report) { _, value in showingReport = value != nil }
        .sheet(isPresented: Binding(get: { setupID != nil && model.setupPresentationID == setupID }, set: {
            if !$0, let setupID { model.dismissSetup(ifCurrent: setupID) }
        })) {
            if let setupID, model.setupPresentationID == setupID {
                MulticamSetupSheet(model: model, setupID: setupID, drafts: model.setup)
                    .id(setupID)
            }
        }
        .sheet(isPresented: $showingReport, onDismiss: { model.report = nil }) { reportSheet }
        .sheet(isPresented: $model.isBulkQueuePresented) { MulticamBulkQueueView(model: model) }
        .sheet(isPresented: $model.isReplacementAudioPresented) { MulticamReplacementAudioView(model: model) }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var windowTitle: String {
        if let name = model.projectName { return name }
        if let camera = model.project?.angles.first { return "\(camera.displayName) Multicam" }
        return "Multicam"
    }

    private var cameraSummary: String {
        guard let count = model.project?.angles.count else { return "" }
        return count == 1 ? "1 camera" : "\(count) cameras"
    }

    private var emptyViewer: some View {
        ContentUnavailableView {
            Label("Add cameras to start editing", systemImage: "film.stack")
        } description: {
            Text("Add synchronized recordings or open a saved multicam project.")
        } actions: {
            HStack(spacing: 10) {
                Button("Add as Multicam…", action: model.chooseSources)
                    .buttonStyle(.borderedProminent)
                    .help("Add multicam sources")
                Button("Open MPCut Project…", action: model.chooseProject)
                    .help("Open saved project")
            }
            .controlSize(.large)
        }
        .disabled(model.isBusy)
        .modifier(EditorMediaDrop(enabled: model.canChooseSources, importFiles: { model.importSources($0) }))
    }

    private func editor(_ project: MulticamProject) -> some View {
        EditorWorkspace(
            viewer: viewer(project), transport: MulticamTransport(model: model, preview: model.preview, project: project),
            timeline: MulticamTimelineHost(model: model, preview: model.preview, project: project,
                                           inspectingAssembly: presentation.inspectorVisible && presentation.inspector == .assembly) {
                presentation.inspector = .switches
                presentation.inspectorVisible = true
            }
            .disabled(model.isBusy),
            status: status, showsTimeline: true, showsStatus: showsStatus, allowsTimelineResize: true
        )
    }

    private func viewer(_ project: MulticamProject) -> some View {
        HSplitView {
            MulticamProgramViewer(preview: model.preview)
                .frame(minWidth: 420, idealWidth: 700, maxWidth: .infinity)
                .modifier(EditorMediaDrop(enabled: model.canChooseSources, importFiles: { model.importSources($0) }))
                .layoutPriority(1)
            if presentation.inspectorVisible {
                inspectorPanel(project)
                    .frame(minWidth: 310, idealWidth: 340, maxWidth: 440)
            }
        }
    }

    private func inspectorPanel(_ project: MulticamProject) -> some View {
        VStack(spacing: 0) {
            Picker("Multicam inspector", selection: $presentation.inspector) {
                ForEach(EditorPresentation.Inspector.allCases, id: \.self) { inspector in
                    let toolTip = switch inspector {
                    case .switches: "Inspect camera switches"
                    case .sources: "Inspect multicam sources"
                    case .assembly: "Inspect assembly ranges"
                    case .export: "Configure multicam export"
                    }
                    Text(inspector.rawValue).help(toolTip).tag(inspector)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .help("Choose inspector panel")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch presentation.inspector {
                    case .switches: switchInspector(project)
                    case .sources: sourceInspector(project)
                    case .assembly: assemblyInspector(project)
                    case .export: MulticamExportControls(model: model, project: project)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .disabled(model.isBusy)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func switchInspector(_ project: MulticamProject) -> some View {
        if let item = project.switches.first(where: { $0.at == model.selectedSwitch }) {
            SectionHeading(item.at == project.range.from
                           ? "Opening Switch" : "Switch at \(timelineTime(item.at.seconds, milliseconds: true))")
            InspectorRow("Picture") {
                Picker("Picture", selection: Binding(get: { item.angle }, set: { model.changeSwitch(item.at, angle: $0) })) {
                    ForEach(project.angles, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                .help("Choose camera angle")
            }
            InspectorRow("Microphone") {
                Picker("Microphone", selection: Binding(get: { item.audio }, set: { model.changeSwitch(item.at, audio: $0) })) {
                    Text("Use project audio policy").tag(nil as MulticamAudioSelection?)
                    audioOptions(project.sources, media: model.media)
                    if let selected = item.audio, !hasAudio(selected) {
                        Text("\(selected.source) · stream \(selected.stream) (unavailable)").tag(Optional(selected))
                    }
                }
                .help("Choose active microphone")
            }
            if item.at != project.range.from {
                MulticamTimeField(label: "Time", value: item.at) { time in
                    model.parseTime(time) { model.moveSwitch(item.at, to: $0) }
                }
                Button("Delete Switch", systemImage: "trash", role: .destructive) { model.deleteSwitch(item.at) }
                    .help("Delete switch (⌫)")
                if model.suggestionAnchor == item.at && !model.suggestions.isEmpty {
                    SectionHeading("Timing Alternatives").padding(.top, 4)
                    ForEach(model.suggestions, id: \.self) { at in
                        HStack {
                            Text(timelineTime(at.seconds, milliseconds: true))
                                .font(.system(size: 12, design: .monospaced))
                                .help("\(at.description) s")
                            Spacer()
                            Button("Preview") { model.seekGroup(at) }
                                .help("Preview switch timing")
                            Button("Apply") { model.moveSwitch(item.at, to: at) }
                                .help("Apply switch timing")
                        }
                    }
                }
            }
        } else {
            SectionHeading("Switch")
            Text("Select a switch marker to change its camera, microphone, or time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider().padding(.vertical, 2)
        HStack(alignment: .firstTextBaseline) {
            SectionHeading("Compare at the Playhead")
            Spacer()
            Button("Show Program", action: model.preview.endAudition)
                .help("Resume program preview")
        }
        ForEach(Array(project.angles.enumerated()), id: \.element.id) { index, source in
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
                Text(source.displayName).lineLimit(1).truncationMode(.middle)
                    .help(source.displayName)
                Spacer(minLength: 4)
                Button("Audition", systemImage: "eye") { model.audition(source.id) }
                    .labelStyle(.iconOnly)
                    .help("Audition \(source.displayName)")
                    .accessibilityLabel("Audition \(source.displayName)")
                Button("Take") { model.takeCamera(number: index + 1) }
                    .help(index < 9 ? "Switch to \(source.displayName) (\(index + 1))" : "Switch to \(source.displayName)")
                    .accessibilityLabel("Take \(source.displayName)")
            }
            .disabled(model.media[source.id] == nil)
        }
    }

    private func sourceInspector(_ project: MulticamProject) -> some View {
        Group {
            SectionHeading("Group")
            MulticamAudioPolicyControl(audio: Binding(get: { project.audio }, set: { audio in
                model.edit { $0.audio = audio }
            }), sources: project.sources, media: model.media)
            MulticamTimeField(label: "Group End", value: project.range.to) { text in
                model.parseTime(text) { time in
                    model.edit { $0.range = MulticamRange(from: $0.range.from, to: time) }
                }
            }
            Button("Extend to Last Camera") {
                if let end = model.lastCameraGroupEnd, end > project.range.to {
                    model.edit { $0.range = MulticamRange(from: $0.range.from, to: end) }
                }
            }
            .help("Extend to longest camera")
            Divider().padding(.vertical, 2)
            SectionHeading("Sources")
            let mediaIssues = model.mediaRefreshIssues
            ForEach(project.sources, id: \.id) { source in
                let index = project.angles.firstIndex(where: { $0.id == source.id })
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: index == nil ? "waveform" : "video")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityLabel(index == nil ? "Audio recording" : "Camera")
                        MulticamNameField(name: source.displayName) { name in
                            model.renameSource(source.id, to: name)
                        }
                        if let index {
                            ControlGroup {
                                Button("Move Earlier", systemImage: "chevron.up") { model.moveSource(source.id, by: -1) }
                                    .disabled(index == 0)
                                    .help("Move camera earlier")
                                Button("Move Later", systemImage: "chevron.down") { model.moveSource(source.id, by: 1) }
                                    .disabled(index == project.angles.count - 1)
                                    .help("Move camera later")
                            }
                            .fixedSize()
                        }
                    }
                    Text(source.id == project.referenceAngle ? "Reference camera · \(source.file)" : source.file)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(source.file)
                    MulticamTimeField(label: "Offset", value: source.offset) { text in
                        model.parseTime(text) { offset in model.updateSource(source.id) { $0.offset = offset } }
                    }
                    HStack {
                        ControlGroup {
                            Button("−1 \(index == nil ? "sample" : "frame")") { model.moveOffset(source.id, by: -1) }
                                .help("Shift earlier one \(index == nil ? "sample" : "frame")")
                            Button("+1 \(index == nil ? "sample" : "frame")") { model.moveOffset(source.id, by: 1) }
                                .help("Shift later one \(index == nil ? "sample" : "frame")")
                        }
                        .fixedSize()
                        Spacer()
                        Button("Relink…") { model.relink(source.id) }
                            .help("Locate missing source")
                    }
                    if let progress = model.sourceIndexProgress[source.id] {
                        ProgressView("Indexing \(source.displayName)", value: progress)
                            .controlSize(.small)
                    }
                    if let message = mediaIssues[source.id] ?? model.sourceIssues[source.id] ?? model.sourceIndexIssues[source.id] {
                        IssueLabel(message)
                    }
                    if index != nil {
                        MulticamSourceTrackPicker(stream: Binding(get: { source.audioStream }, set: { stream in
                            model.updateSource(source.id) { $0.audioStream = stream }
                        }), media: model.media[source.id])
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func assemblyInspector(_ project: MulticamProject) -> some View {
        Group {
            SectionHeading("Marked Range")
            if project.assemblyItems == nil {
                Text("Export includes the whole group. To export part of it, mark a range and add it to the assembly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ControlGroup {
                    Button("Mark In") { model.markIn = model.markAnalysisTime() }
                        .help("Mark range start (I)")
                    Button("Mark Out") { model.markOut = model.markAnalysisTime() }
                        .help("Mark range end (O)")
                }
                .fixedSize()
                Spacer()
                Button("Clear") { model.markIn = nil; model.markOut = nil }
                    .help("Clear marks (⌥X / Esc)")
                    .disabled(model.displayedMarkIn == nil && model.displayedMarkOut == nil)
            }
            if model.displayedMarkIn != nil || model.displayedMarkOut != nil {
                HStack(spacing: 12) {
                    markReadout("In", model.displayedMarkIn)
                    markReadout("Out", model.displayedMarkOut)
                }
            }
            HStack {
                Button("Add to Assembly", action: model.addMarkedRange)
                    .fixedSize()
                    .help("Add range to assembly (⌥⌘A)")
                    .disabled(!model.canAddMarkedRange)
                Button("Queue", action: model.enqueueMarkedRange)
                    .fixedSize()
                    .accessibilityLabel("Queue Range")
                    .help("Queue marked range (⇧⌘A)")
                    .disabled(!model.canEnqueueMarkedRange)
                Spacer(minLength: 0)
                Button("Remove", systemImage: "trash", role: .destructive, action: model.deleteSelectedRange)
                    .labelStyle(.iconOnly)
                    .help("Remove range from assembly")
                    .accessibilityLabel("Remove Marked Range")
                    .disabled(!model.canDeleteSelectedRange)
            }
            Divider().padding(.vertical, 2)
            SectionHeading("Assets")
            StillAuthoringControls(rows: model.multicamStillRows, enabled: !model.isBusy,
                                   canReplace: model.canReplaceMulticamPicture, canInsert: true,
                                   replace: model.chooseReplaceMulticamPicture, insert: model.chooseInsertMulticamStill,
                                   manage: model.manageMulticamStill)
            ForEach(model.multicamStillRows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.callout)
                    Text(row.details).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.vertical, 2)
            SectionHeading("Assembly")
            VStack(spacing: 2) {
                ForEach(Array(model.assemblyItems.enumerated()), id: \.offset) { index, item in
                    let selected = model.selectedOccurrence == index
                    Button {
                        model.selectOccurrence(index)
                    } label: {
                        HStack {
                            Text(item.still.flatMap { still in project.stillAssets.first(where: { $0.id == still.assetID })?.displayName }
                                 ?? "Range \(index + 1)").fontWeight(selected ? .semibold : .regular)
                            Spacer()
                            if let range = item.group {
                                Text("\(timelineTime(range.from.seconds, milliseconds: true)) – \(timelineTime(range.to.seconds, milliseconds: true))")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            } else if let still = item.still {
                                Text("\(timelineTime(still.duration.seconds, milliseconds: true))")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                                    in: RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .help("Select assembly item")
                }
            }
            if let range = model.assemblyRange(at: model.selectedOccurrence) {
                MulticamTimeField(label: "Range Start", value: range.from) { text in
                    model.parseTime(text) { model.changeOccurrence(from: $0) }
                }
                MulticamTimeField(label: "Range End", value: range.to) { text in
                    model.parseTime(text) { model.changeOccurrence(to: $0) }
                }
                MulticamRangeActions(model: model, preview: model.preview)
            }
            if model.assemblyItems.indices.contains(model.selectedOccurrence) {
                HStack {
                    ControlGroup {
                        Button("Earlier", systemImage: "arrow.up") { model.moveOccurrence(-1) }
                            .disabled(model.selectedOccurrence == 0)
                            .help("Move range earlier")
                        Button("Later", systemImage: "arrow.down") { model.moveOccurrence(1) }
                            .disabled(model.selectedOccurrence >= model.assemblyItems.count - 1)
                            .help("Move range later")
                    }
                    .fixedSize()
                    Spacer()
                    Button("Remove", systemImage: "trash", role: .destructive, action: model.removeOccurrence)
                        .labelStyle(.iconOnly)
                        .help("Remove assembly item")
                        .accessibilityLabel("Remove Range")
                        .disabled(project.assemblyItems == nil)
                }
            }
        }
    }

    private func markReadout(_ name: String, _ time: RationalTime?) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary)
            Text(time.map { timelineTime($0.seconds, milliseconds: true) } ?? "—")
                .font(.system(size: 12, design: .monospaced))
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var showsStatus: Bool { model.project != nil || !model.status.isEmpty || model.isBusy }

    private var status: some View {
        EditorStatusBar {
            if model.isBusy {
                if let progress = model.progress {
                    ProgressView(value: progress).frame(width: 132)
                    Text(progressPercent(progress)).monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(1).help(model.status)
                Spacer(minLength: 8)
                Button("Cancel", action: model.cancel)
                    .help("Cancel current operation")
            } else {
                if model.project != nil {
                    Button {
                        if model.canScanAnalysis(.silence) { model.scanAnalysis(.silence) }
                        presentation.pauseControls = true
                    } label: {
                        Label(model.canScanAnalysis(.silence) ? "Scan for Silence" : "Silence",
                              systemImage: "waveform")
                    }
                    .popover(isPresented: $presentation.pauseControls, arrowEdge: .top) { MulticamPauseControls(model: model) }
                    .help("Find and edit pauses")
                    if model.canStepAnalysis(.silence) {
                        HStack(spacing: 0) {
                            StatusIconButton(title: "Previous Silence", symbol: "chevron.left",
                                             help: "Previous Silence (⌃⌥←)") { model.stepAnalysis(.silence, direction: -1) }
                            StatusIconButton(title: "Next Silence", symbol: "chevron.right",
                                             help: "Next Silence (⌃⌥→)") { model.stepAnalysis(.silence, direction: 1) }
                        }
                    }
                    StatusBarDivider()
                    if let progress = model.analysis.sceneProgress {
                        ProgressView(value: progress).frame(width: 72)
                            .accessibilityLabel("Scene analysis progress")
                        Text(progressPercent(progress)).monospacedDigit()
                        Button("Cancel Scene Scan", action: model.analysis.cancelSceneAnalysisFromEditor)
                            .help("Cancel scene scan")
                    } else {
                        Menu {
                            MulticamFindSceneCommands(model: model)
                        } label: {
                            Label("Find Scenes", systemImage: "viewfinder")
                        }
                        .disabled(!model.analysis.canScanScenes(camera: nil))
                        .help("Find camera scene changes")
                        .task(id: model.analysis.sceneInspectionKey(camera: nil)) {
                            await model.analysis.inspectSceneChoices(camera: nil)
                        }
                    }
                    MulticamSceneStatus(model: model, preview: model.preview)
                    if model.analysis.status != nil || !model.sourceIndexProgress.isEmpty || !model.status.isEmpty {
                        StatusBarDivider()
                    }
                    // The tier of the saved program, as the editor's status bar shows it for a file timeline.
                    MulticamTierBadge(model: model)
                }
                if let issue = model.mediaRefreshIssues.values.sorted().first {
                    Label("Media refresh", systemImage: "exclamationmark.triangle").help(issue)
                }
                if let analysis = model.analysis.status {
                    Text(analysis).lineLimit(1).help(analysis)
                }
                if !model.sourceIndexProgress.isEmpty {
                    let count = model.sourceIndexProgress.count
                    ProgressView().controlSize(.small)
                    Text(count == 1 ? "Indexing 1 source…" : "Indexing \(count) sources…")
                } else if !model.status.isEmpty {
                    Text(model.status).lineLimit(1).help(model.status)
                }
                Spacer(minLength: 8)
            }
        }
    }

    private var reportSheet: some View {
        EditorSheet(title: "Multicam Export Plan", message: "Review the settings before you export.") {
            ScrollView {
                Text(model.report ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .modifier(InsetPanel())
        } actions: {
            Button("Copy JSON", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.report ?? "", forType: .string)
            }
            .help("Copy report as JSON")
            Spacer()
            Button("Done") { showingReport = false }.keyboardShortcut(.defaultAction)
                .help("Close export report")
        }
        .frame(width: 660, height: 480)
    }

    private func hasAudio(_ selection: MulticamAudioSelection) -> Bool {
        model.media[selection.source]?.audio.contains { $0.stream.index == selection.stream } ?? false
    }

    private func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard model.project != nil, !model.isBusy else { return event }
        if event.keyCode == 123 || event.keyCode == 124 {
            let direction = event.keyCode == 123 ? -1 : 1
            switch modifiers {
            case []: model.step(direction)
            case [.option] where model.canStepAnalysis(.keyframes): model.stepAnalysis(.keyframes, direction: direction)
            case [.shift] where model.canStepAnalysis(.scenes): model.stepAnalysis(.scenes, direction: direction)
            case [.control, .option] where model.canStepAnalysis(.silence): model.stepAnalysis(.silence, direction: direction)
            default: return event
            }
            return nil
        }
        if modifiers == .option, event.charactersIgnoringModifiers?.lowercased() == "x" {
            model.markIn = nil
            model.markOut = nil
            return nil
        }
        guard modifiers.isEmpty else { return event }
        if (event.keyCode == 51 || event.keyCode == 117) && model.canDeleteSelection {
            if !event.isARepeat { model.deleteSelection() }
            return nil
        }
        if let amount = TimelineViewControls.keyZoom(event.charactersIgnoringModifiers) {
            model.timelineZoom = TimelineViewControls.adjustedZoom(model.timelineZoom, by: amount)
            return nil
        }
        if model.preview.handleSpeedKey(event) { return nil }
        if event.keyCode == 49 {
            if !event.isARepeat { model.preview.togglePlayback() }
            return nil
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": model.rangeTool = true
        case "a": model.rangeTool = false
        case "j": if !event.isARepeat { model.preview.shuttle(-1) }
        case "k": if !event.isARepeat { model.preview.pause() }
        case "l": if !event.isARepeat { model.preview.shuttle(1) }
        case let character?:
            guard !event.isARepeat, let number = Int(character), (1...9).contains(number),
                  model.takeCamera(number: number) else { return event }
        default: return event
        }
        return nil
    }
}

extension MulticamEditorModel {
    var canAddMarkedRange: Bool {
        project != nil && !isBusy && markedGroupSpan != nil
    }
}

private struct MulticamRangeActions: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        HStack {
            Button("Trim Start") { model.trimOccurrence(.start) }
                .disabled(!model.canTrimOccurrence)
                .help("Trim start to playhead")
            Button("Trim End") { model.trimOccurrence(.end) }
                .disabled(!model.canTrimOccurrence)
                .help("Trim end to playhead")
            Button("Split", action: model.splitOccurrence)
                .disabled(!model.canCutOccurrence)
                .help("Split assembly range")
        }
    }
}

private struct MulticamSceneStatus: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        if let label = model.currentSceneLabel {
            Button(action: model.renameCurrentView) {
                Label(label, systemImage: "rectangle.on.rectangle")
            }
                .buttonStyle(.borderless)
                .monospacedDigit()
                .lineLimit(1)
                .disabled(!model.canRenameCurrentView)
                .help("Rename matching scene views")
        }
    }
}

private struct MulticamProgramViewer: View {
    let preview: MulticamPreview
    @State private var issue: String?
    @State private var audioWarning: String?

    var body: some View {
        EditorPreview(accessibilityTitle: "Multicam program preview", issue: issue, audioWarning: audioWarning) {
            MulticamPreviewView(preview: preview)
        }
        // The preview surface receives frames directly. SwiftUI only displays the warnings.
        .onReceive(preview.$issue.combineLatest(preview.$pictureIssue).map { $0 ?? $1 }.removeDuplicates()) {
            issue = $0
        }
        .onReceive(preview.$audioIssue.removeDuplicates()) { audioWarning = $0 }
    }
}

private struct MulticamPreviewSoundControls: View {
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        PreviewSoundControls(volume: $preview.volume, isMuted: $preview.isMuted,
                             scrubSoundEnabled: $preview.scrubSoundEnabled)
    }
}

private struct MulticamTimelineHost: View {
    @ObservedObject var model: MulticamEditorModel
    let preview: MulticamPreview
    let project: MulticamProject
    let inspectingAssembly: Bool
    let showSwitchInspector: () -> Void

    var body: some View {
        var timeline = MulticamTimeline(project: project, media: model.media, playhead: .zero,
                         clock: MulticamTimelineClock(preview: preview, groupTime: model.groupTime(at:)),
                         seek: model.seekTimeline, take: model.take,
                         moveSwitch: { model.moveSwitch($0, to: $1, snap: true) },
                         deleteSwitch: model.deleteSwitch,
                         selectSwitch: { model.selectMarker($0); showSwitchInspector() },
                         useAnalysisSidecars: model.useAnalysisSidecars, thumbnailService: model.filmstrip,
                         selectedSwitch: model.selectedSwitch, scrubEnded: preview.endScrub,
                         zoom: $model.timelineZoom, largeThumbnails: Binding(
                            get: { model.preferences.largeThumbnails },
                            set: { model.preferences.largeThumbnails = $0 }
                         ), timeEntryRequest: model.timeEntryRequest, analysis: model.analysis,
                         snapTarget: Binding(get: { model.analysis.snapTarget }, set: model.setAnalysisSnap),
                         jump: { model.preview.pause(); model.seekGroup($0) },
                         markIn: model.markIn, markOut: model.markOut, assemblySelection: model.assemblySelection,
                         showGroupAssets: !model.assemblyPreview,
                         groupStillFrames: model.groupStillFrames,
                         dropGroupStills: { urls, group in
                             guard !model.isBusy else { return }
                             if NSEvent.modifierFlags.contains(.option), urls.count == 1, let url = urls.first,
                                model.canReplaceMulticamPicture {
                                 model.replaceMulticamPicture(with: url)
                             } else if let time = model.assemblyPosition(for: group) {
                                 model.insertMulticamStills(urls, atAssembly: time)
                             } else {
                                 model.fail("This group position is outside the assembled ranges. Drop the still on the assembly timeline.")
                             }
                         },
                         assembly: model.assemblyPreview || inspectingAssembly
                            ? MulticamAssemblyTimeline(model: model, preview: preview) : nil)
        if model.rangeTool && !model.isBusy { timeline.selectRange = model.selectGroupRange }
        return timeline
    }
}

struct MulticamTransport: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview
    let project: MulticamProject

    var body: some View {
        let activeCamera = model.interval(at: preview.time)?.angle
        let cameras = project.angles.enumerated().map { index, camera in
            EditorCameraAction(id: camera.id, number: index + 1, name: camera.displayName, active: camera.id == activeCamera) {
                model.takeCamera(number: index + 1)
            }
        }
        EditorTransportBar(
            navigation: .picture(
                scenes: .init(enabled: model.canStepAnalysis(.scenes)) { model.stepAnalysis(.scenes, direction: $0) },
                keyframes: .init(enabled: model.canStepAnalysis(.keyframes)) { model.stepAnalysis(.keyframes, direction: $0) }
            ),
            frames: .init(enabled: true, step: model.step),
            canNavigate: !model.isBusy,
            canEdit: !model.isBusy,
            marks: .init(hasIn: model.displayedMarkIn != nil, hasOut: model.displayedMarkOut != nil,
                         setIn: { model.markIn = model.markAnalysisTime() },
                         setOut: { model.markOut = model.markAnalysisTime() },
                         clear: { model.markIn = nil; model.markOut = nil }),
            cameras: cameras,
            addRange: .init(title: "Add Marked Range to Export Queue", enabled: model.canEnqueueMarkedRange,
                            perform: model.enqueueMarkedRange),
            split: .init(title: "Split Assembly Item at Playhead", enabled: model.canCutOccurrence,
                         perform: model.splitOccurrence),
            delete: .init(title: model.deleteTitle, enabled: model.canDeleteSelection, perform: model.deleteSelection),
            undo: .init(title: model.undoTitle, enabled: !model.isBusy && !model.undoStack.isEmpty, perform: model.undo),
            redo: .init(title: model.redoTitle, enabled: !model.isBusy && !model.redoStack.isEmpty, perform: model.redo),
            rangeTools: .init(active: $model.rangeTool, canAct: model.canActOnRange,
                              canSplit: model.canSplitSelectedRange, canDelete: model.canDeleteSelectedRange,
                              split: model.splitSelectedRange,
                              export: model.chooseSelectionExport, delete: model.deleteSelectedRange),
            preview: preview
        ) {
            Picker("Preview", selection: Binding(get: { model.assemblyPreview }, set: model.setAssemblyPreview)) {
                Text("Group").help("Preview entire group").tag(false)
                Text("Assembly").help("Preview assembly").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .help("Choose preview timeline")
        }
        .disabled(model.isBusy)
    }
}

private struct MulticamTimeField: View {
    let label: String
    let value: RationalTime
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            TextField(label, text: $text)
                .labelsHidden()
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity)
                .onSubmit {
                    commit(text)
                    text = value.description
                }
                .help("Edit \(label.lowercased()) in seconds")
            Text("s").foregroundStyle(.secondary)
        }
        .onAppear { text = value.description }
        .onChange(of: value) { _, newValue in text = newValue.description }
    }
}

private struct MulticamNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("Source name", text: $text)
            .focused($editing)
            .onAppear { text = name }
            .onChange(of: name) { _, name in if !editing { text = name } }
            .onChange(of: editing) { _, editing in if !editing { save() } }
            .onSubmit { save(); editing = false }
            .help("Rename source")
    }

    private func save() {
        let proposed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if proposed != name { commit(proposed) }
        if proposed.isEmpty || proposed == name { text = name }
    }
}

private struct MulticamSourceTrackPicker: View {
    @Binding var stream: Int?
    let media: MediaInfo?

    var body: some View {
        InspectorRow("Microphone") {
          Picker("Camera microphone", selection: $stream) {
            Text("None assigned").tag(nil as Int?)
            ForEach(media?.audio ?? [], id: \.stream.index) { audio in
                Text(audio.stream.exportLabel).tag(Optional(audio.stream.index))
            }
            if let stream, !(media?.audio.contains { $0.stream.index == stream } ?? false) {
                Text("Stream \(stream) (unavailable)").tag(Optional(stream))
            }
          }
          .help("Choose camera microphone")
        }
    }
}

@ViewBuilder
private func audioOptions(_ sources: [MulticamSource], media: [String: MediaInfo]) -> some View {
    ForEach(sources, id: \.id) { source in
        ForEach(media[source.id]?.audio ?? [], id: \.stream.index) { audio in
            Text("\(source.displayName) · \(audio.stream.exportLabel)")
                .tag(Optional(MulticamAudioSelection(source: source.id, stream: audio.stream.index)))
        }
    }
}

private struct MulticamAudioPolicyControl: View {
    @Binding var audio: MulticamAudioPolicy
    let sources: [MulticamSource]
    let media: [String: MediaInfo]
    var labelWidth: CGFloat = 88

    private enum Policy: String, CaseIterable {
        case fixed = "Fixed master", follow = "Audio follows camera", none = "Video only"
    }

    private var policy: Policy {
        switch audio {
        case .fixed: return .fixed
        case .follow: return .follow
        case .none: return .none
        }
    }

    private var selection: MulticamAudioSelection? {
        if case .fixed(let selection) = audio { return selection }
        return nil
    }

    var body: some View {
        InspectorRow("Soundtrack", labelWidth: labelWidth) {
          Picker("Soundtrack", selection: Binding(get: { policy }, set: { policy in
            switch policy {
            case .none: audio = .none
            case .follow: audio = .follow
            case .fixed:
                if let source = sources.first(where: { !(media[$0.id]?.audio.isEmpty ?? true) }),
                   let track = media[source.id]?.audio.first {
                    audio = .fixed(MulticamAudioSelection(source: source.id, stream: track.stream.index))
                }
            }
        })) {
            ForEach(Policy.allCases, id: \.self) { option in Text(option.rawValue).tag(option) }
          }
          .help("Choose soundtrack policy")
        }
        if let selection {
            InspectorRow("Master track", labelWidth: labelWidth) {
                Picker("Master track", selection: Binding(get: { Optional(selection) }, set: { value in if let value { audio = .fixed(value) } })) {
                    audioOptions(sources, media: media)
                    if !(media[selection.source]?.audio.contains { $0.stream.index == selection.stream } ?? false) {
                        Text("\(selection.source) · stream \(selection.stream) (unavailable)").tag(Optional(selection))
                    }
                }
                .help("Choose fixed audio track")
            }
        }
    }
}

private struct MulticamSetupSheet: View {
    @ObservedObject var model: MulticamEditorModel
    let setupID: UUID
    @State var drafts: [MulticamEditorModel.SourceDraft]
    @State private var opening = ""
    @State private var audio: MulticamAudioPolicy = .none
    @State private var customizedAudio = false

    var body: some View {
        EditorSheet(title: model.project == nil ? "Set Up Multicam" : "Add Multicam Sources",
                    message: "Name the sources and arrange the cameras. Press 1–9 to switch cameras.") {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(drafts.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            Image(systemName: drafts[index].media.hasVideo ? "video" : "waveform")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                                .accessibilityLabel(drafts[index].media.hasVideo ? "Camera" : "Audio recording")
                            TextField("Source name", text: Binding(get: { drafts[index].source.displayName }, set: {
                                drafts[index].source.name = $0
                            }))
                                .help("Rename source")
                            ControlGroup {
                                Button("Move Up", systemImage: "chevron.up") { drafts.swapAt(index, index - 1) }
                                    .disabled(index == 0)
                                    .help("Move camera earlier")
                                Button("Move Down", systemImage: "chevron.down") { drafts.swapAt(index, index + 1) }
                                    .disabled(index == drafts.count - 1)
                                    .help("Move camera later")
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding(1)
            }
            .frame(minHeight: 80, idealHeight: 150, maxHeight: 220)
            if model.project == nil {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    InspectorRow("Opening camera", labelWidth: 110) {
                        Picker("Opening camera", selection: $opening) {
                            ForEach(drafts.filter { $0.media.hasVideo }) { Text($0.source.displayName).tag($0.id) }
                        }
                        .help("Choose first camera")
                    }
                    MulticamAudioPolicyControl(audio: Binding(get: { audio }, set: { audio = $0; customizedAudio = true }),
                                               sources: drafts.map(\.source),
                                               media: Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0.media) }),
                                               labelWidth: 110)
                }
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.dismissSetup(ifCurrent: setupID) }.keyboardShortcut(.cancelAction)
                .help("Cancel multicam setup")
            Button(model.project == nil ? "Create Multicam" : "Add Sources") {
                model.confirmSetup(drafts: drafts, opening: opening, audio: audio, ifCurrent: setupID)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy)
            .help(model.project == nil ? "Create multicam group" : "Add sources to group")
        }
        .frame(width: 520)
        .background(MulticamSetupWindowBinding(model: model, setupID: setupID))
        .onAppear { opening = drafts.first(where: { $0.media.hasVideo })?.id ?? ""; selectDefaultAudio() }
        .onChange(of: opening) { _, _ in
            if !customizedAudio { selectDefaultAudio() }
            model.updatePendingSetup(drafts, opening: opening, audio: audio)
        }
        .onChange(of: audio) { _, _ in model.updatePendingSetup(drafts, opening: opening, audio: audio) }
        .onChange(of: drafts.map(\.source)) { _, _ in model.updatePendingSetup(drafts, opening: opening, audio: audio) }
    }

    private func selectDefaultAudio() {
        let choice = drafts.first { $0.id == opening && !$0.media.audio.isEmpty } ?? drafts.first { !$0.media.audio.isEmpty }
        if let choice, let stream = choice.media.audio.first?.stream.index {
            audio = .fixed(MulticamAudioSelection(source: choice.id, stream: stream))
        } else { audio = .none }
    }
}

private struct MulticamSetupWindowBinding: NSViewRepresentable {
    let model: MulticamEditorModel
    let setupID: UUID

    func makeNSView(context: Context) -> SheetView {
        let view = SheetView()
        view.model = model
        view.setupID = setupID
        return view
    }

    func updateNSView(_ view: SheetView, context: Context) {}

    final class SheetView: NSView {
        weak var model: MulticamEditorModel?
        var setupID: UUID?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let model, model.setupPresentationID == setupID else { return }
            model.setupWindow = window
        }
    }
}

private struct MulticamExportControls: View {
    @ObservedObject var model: MulticamEditorModel
    let project: MulticamProject
    /// The settings on offer. Their lists, defaults and names come from the export rules.
    @State private var choices: MulticamExportChoices
    private var tracks: ExportTracks { choices.tracks }
    private var container: String { choices.container }
    private var wholeGroup: Bool { model.exportProgram == .group }
    private var selectionRanges: [MulticamRange]? {
        model.exportProgram == .selection ? model.selectedExportRanges : nil
    }
    private var stillScope: ExportPlacementScope {
        guard let document = model.stillExportDocument(wholeGroup: wholeGroup, selection: selectionRanges) else { return .none }
        return (try? document.exportPlacementScope()) ?? .none
    }
    @State private var checkedConversion: Conversion?
    @State private var pendingBoundary: StillBoundaryAdjustment?

    init(model: MulticamEditorModel, project: MulticamProject) {
        self.model = model
        self.project = project
        // Re-encode has its own section below, so the Mode control starts from a copying mode.
        // A failed check moves the inspector to the switch it names. Coming back, the offers still on show are about
        // the mode that failed, so the control reopens on it rather than on the preference.
        let preferred = model.unavailableExportMode ?? model.preferences.defaultExportMode
        var initial = MulticamExportChoices(entry: .multicamSheet,
            preferred: preferred == .encode ? ExportRules.defaultMode(for: .multicam) : preferred)
        let selection = model.exportProgram == .selection ? model.selectedExportRanges : nil
        let document = model.stillExportDocument(wholeGroup: model.exportProgram == .group, selection: selection)
        initial.placements = (try? document?.exportPlacementScope()) ?? .none
        if initial.placements != .none {
            initial.mode = model.unavailableExportMode ?? .smart
            initial.container = document?.stillFormat?.container ?? "mov"
            initial.settle()
        }
        _choices = State(initialValue: initial)
    }

    private struct Conversion: Equatable {
        let project: MulticamProject
        let container: String
        let wholeGroup: Bool
        let selection: [MulticamRange]?
        let settings: ReencodeSettings
    }

    private var conversion: Conversion {
        Conversion(project: project, container: container, wholeGroup: wholeGroup, selection: selectionRanges,
                   settings: ReencodeSettings(codec: choices.codec, audio: choices.audio))
    }
    /// The copying modes of the Mode control. Re-encode is requested from its own section.
    private var copyModes: [ExportMode] {
        choices.placements == .none ? choices.modes.filter { $0 != .encode } : choices.modes
    }

    var body: some View {
        SectionHeading("Export")
        InspectorRow("Program") {
            Picker("Program", selection: $model.exportProgram) {
                Text("Current assembly").tag(MulticamExportProgram.assembly)
                Text("Whole group").tag(MulticamExportProgram.group)
                Text("Selected range").tag(MulticamExportProgram.selection)
            }
            .help("Choose program to export")
        }
        InspectorRow("Tracks") {
            Picker("Tracks", selection: $choices.tracks) {
                let silent = project.audio == .none && project.switches.allSatisfy { $0.audio == nil }
                ForEach(ExportTracks.allCases, id: \.self) {
                    Text(MulticamExportChoices.title(of: $0, silentProject: silent, placements: choices.placements)).tag($0)
                }
            }
            .help("Choose output tracks")
        }
        if copyModes.count > 1 {
            InspectorRow("Mode") {
                Picker("Mode", selection: Binding(get: { effectiveMode }, set: { choices.mode = $0 })) {
                    ForEach(copyModes, id: \.self) { Text(choices.title(of: $0)).tag($0) }
                }
                .help("Choose export mode")
            }
        }
        InspectorRow("Container") {
            Picker("Container", selection: $choices.container) {
                ForEach(choices.containers(mode: choices.placements == .none && tracks != .all ? .copy : nil), id: \.self) { Text(containerDisplayName($0)).tag($0) }
            }
            .help("Choose file format")
        }
        if choices.placements != .none && tracks != .audio {
            InspectorRow("Camera") {
                Toggle("Preserve camera picture", isOn: $choices.requireCameraCopy)
                    .help("Copy camera footage")
            }
        }
        if choices.placements != .none && effectiveMode == .encode && tracks != .audio {
            InspectorRow("Video") {
                Picker("Video", selection: $choices.codec) {
                    ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Choose video codec")
            }
            InspectorRow("Quality") {
                Picker("Quality", selection: choices.codec == .prores ? $choices.proResQuality : $choices.standardQuality) {
                    ForEach(choices.qualities, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Set video quality")
            }
        }
        if choices.placements != .none && tracks != .video && (effectiveMode == .smart || effectiveMode == .encode) {
            InspectorRow("Audio") {
                Picker("Audio", selection: $choices.audio) {
                    let actions = tracks == .audio ? ExportRules.stillSoundConversions : ExportRules.stillMovieAudioActions
                    ForEach(actions, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Choose audio encoding")
            }
        }
        let sourceIssue = model.exportSourceIssue(tracks: tracks, wholeGroup: wholeGroup, mode: effectiveMode,
                                                  settings: choices.settings, selection: selectionRanges)
        if let sourceIssue {
            IssueLabel(sourceIssue)
        }
        HStack {
            Button("Check Export") { checkExport() }
                .help("Check export settings")
            Spacer()
            Button("Export…") {
                chooseDestination(mode: effectiveMode, tracks: tracks, settings: choices.settings)
            }
                .buttonStyle(.borderedProminent)
                .help("Export multicam program")
        }
        .disabled(sourceIssue != nil)
        .onChange(of: stillScope) { previous, scope in
            choices.placements = scope
            if scope != .none && previous == .none { choices.mode = .smart }
            if scope == .none && choices.mode == .encode { choices.mode = ExportRules.defaultMode(for: .multicam) }
        }
        .onChange(of: choices) { _, _ in
            if choices.placements == .insertion && choices.tracks == .audio && choices.effectiveMode == .encode,
               ![ReencodeAudio.pcm, .aac].contains(choices.audio) {
                choices.audio = .pcm
            }
            choices.settle()
            model.exportAlternatives = []
            model.stillExportBoundaryChoices = []
            pendingBoundary = nil
        }
        .onChange(of: project) { _, _ in
            model.stillExportBoundaryChoices = []
            pendingBoundary = nil
        }
        // An unavailable export offers what the export rules report for it, least destructive first.
        if !model.exportAlternatives.isEmpty {
            ExportOffersView(message: "This export is unavailable. These alternatives work.", alternatives: model.exportAlternatives) {
                choices.apply($0)
                // Re-encode is requested from its own section, so the Mode control keeps a copying mode.
                if choices.placements == .none && $0.mode == .encode {
                    choices.mode = ExportRules.defaultMode(for: .multicam)
                }
            }
        }
        if !model.stillExportBoundaryChoices.isEmpty {
            ForEach(Array(model.stillExportBoundaryChoices.enumerated()), id: \.offset) { _, choice in
                Button(choice.reviewDescription) {
                    pendingBoundary = choice
                    if choice.clock == "group" {
                        model.seekGroup(choice.adjustedTime)
                    } else {
                        model.seekAssembly(at: choice.adjustedTime, scrubbing: false)
                    }
                }
                .help("Preview verified boundary")
            }
            if let pendingBoundary {
                Button("Apply to Timeline") {
                    model.applyStillExportBoundary(pendingBoundary)
                    self.pendingBoundary = nil
                }
                .help("Apply reviewed boundary")
            }
        }
        // An unsafe edge of an assembly range offers its verified times. Applying one moves that edge.
        if let suggestion = model.currentEdgeSuggestion {
            MulticamEdgeSuggestionsView(suggestion: suggestion, preview: { model.seekGroup($0) }) {
                model.applyEdgeSuggestion($0)
            }
        }

        if choices.placements == .none && choices.modes.contains(.encode) {
            Divider().padding(.vertical, 2)
            SectionHeading(choices.title(of: .encode))
            InspectorRow("Video") {
                Picker("Video", selection: $choices.codec) {
                    ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Choose video codec")
            }
            InspectorRow("Audio") {
                Picker("Audio", selection: $choices.audio) {
                    ForEach(choices.audioActions, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .help("Choose audio encoding")
            }
            let conversionIssue = sourceIssue.flatMap { _ in
                model.exportSourceIssue(tracks: .all, wholeGroup: wholeGroup, mode: .encode, settings: conversion.settings, selection: selectionRanges)
            }
            HStack {
                Button("Check \(choices.title(of: .encode))") { checkConversion() }
                    .help("Check encoder settings")
                Spacer()
                Button("Export Re-encoded…") {
                    chooseDestination(mode: .encode, tracks: .all, settings: conversion.settings)
                }
                .buttonStyle(.borderedProminent)
                .disabled(checkedConversion != conversion)
                .help(checkedConversion == conversion ? "Export re-encoded program" : "Check encoder settings first")
            }
            .disabled(conversionIssue != nil)
        }
        Divider().padding(.vertical, 2)
        SectionHeading("Source Audio")
        Button("Replace Source Audio…", action: model.chooseReplacementAudio)
            .help("Replace program soundtrack")
            .disabled(!model.canReplaceSourceAudio)
    }

    private var effectiveMode: ExportMode { choices.effectiveMode }

    private var checkDestination: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("multicam-check-\(UUID()).\(container)")
    }

    private func checkExport() {
        model.export(output: checkDestination, mode: effectiveMode, tracks: tracks, dryRun: true, wholeGroup: wholeGroup,
                     settings: choices.settings, selection: selectionRanges,
                     requireCameraCopy: choices.placements != .none && choices.requireCameraCopy)
    }

    private func checkConversion() {
        let requested = conversion
        model.export(output: checkDestination, mode: .encode, tracks: .all, dryRun: true,
                     wholeGroup: wholeGroup, settings: requested.settings, selection: requested.selection) {
            checkedConversion = requested
        }
    }

    private func chooseDestination(mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings = .init()) {
        let panel = NSSavePanel()
        panel.title = "Export Multicam"
        panel.allowedContentTypes = [UTType(filenameExtension: container) ?? .data]
        panel.nameFieldStringValue = "Multicam.\(container)"
        let wholeGroup = wholeGroup
        let selection = selectionRanges
        let requireCameraCopy = choices.placements != .none && choices.requireCameraCopy
        ProjectPanels.present(panel, in: model.window) { [weak model] accepted in
            guard accepted, let output = panel.url else { return }
            model?.export(output: output, mode: mode, tracks: tracks, dryRun: false, wholeGroup: wholeGroup, settings: settings, selection: selection, requireCameraCopy: requireCameraCopy)
        }
    }
}

