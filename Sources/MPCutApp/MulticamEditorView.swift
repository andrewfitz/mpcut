import AppKit
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

struct MulticamEditorView: View {
    @ObservedObject var model: MulticamEditorModel
    @State private var inspector: Inspector = .switches
    @State private var showingReport = false
    @State private var showingPauseControls = false
    @State private var showingInspector = true

    private enum Inspector: String, CaseIterable {
        case switches = "Switch", sources = "Sources", assembly = "Assembly", export = "Export"
    }

    var body: some View {
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
                    EditorToolbarButton(title: "Add Sources", symbol: "plus", action: model.chooseSources)
                        .help("Add cameras or audio recordings to the multicam group (⌘O)")
                        .disabled(!model.canChooseSources)
                    EditorToolbarButton(title: "Export", symbol: "square.and.arrow.up") {
                        inspector = .export
                        showingInspector = true
                    }
                    .help("Show the export options (⌘E)")
                    .disabled(model.isBusy)
                    Button("Save Project", systemImage: "square.and.arrow.down") { _ = model.saveProject() }
                        .labelStyle(.iconOnly)
                        .help("Save the multicam project (⌘S)")
                        .disabled(model.isBusy)
                    Button(showingInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") {
                        showingInspector.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .help(showingInspector ? "Hide Multicam Inspector" : "Show Multicam Inspector")
                }
            }
        }
        .onChange(of: model.exportRequested) { _, _ in
            inspector = .export
            showingInspector = true
        }
        .onChange(of: model.suggestionAnchor) { _, at in
            if at != nil {
                inspector = .switches
                showingInspector = true
            }
        }
        .onChange(of: model.splitRevision) { _, _ in
            inspector = .assembly
            showingInspector = true
        }
        .onChange(of: model.report) { _, value in showingReport = value != nil }
        .sheet(isPresented: Binding(get: { !model.setup.isEmpty }, set: { if !$0 { model.dismissSetup() } })) {
            MulticamSetupSheet(model: model, drafts: model.setup)
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
                Button("Open Multicam Project…", action: model.chooseProject)
            }
            .controlSize(.large)
        }
        .disabled(model.isBusy)
        .modifier(EditorMediaDrop(enabled: model.canChooseSources, importFiles: model.importSources))
    }

    private func editor(_ project: MulticamProject) -> some View {
        EditorWorkspace(
            viewer: viewer(project), transport: MulticamTransport(model: model, preview: model.preview, project: project),
            timeline: MulticamTimelineHost(model: model, preview: model.preview, project: project,
                                           inspectingAssembly: showingInspector && inspector == .assembly) {
                inspector = .switches
                showingInspector = true
            }
            .disabled(model.isBusy),
            status: status, showsTimeline: true, showsStatus: showsStatus, allowsTimelineResize: true
        )
    }

    private func viewer(_ project: MulticamProject) -> some View {
        HSplitView {
            MulticamProgramViewer(preview: model.preview)
                .frame(minWidth: 420, idealWidth: 700, maxWidth: .infinity)
                .modifier(EditorMediaDrop(enabled: model.canChooseSources, importFiles: model.importSources))
                .layoutPriority(1)
            if showingInspector {
                inspectorPanel(project)
                    .frame(minWidth: 310, idealWidth: 340, maxWidth: 440)
            }
        }
    }

    private func inspectorPanel(_ project: MulticamProject) -> some View {
        VStack(spacing: 0) {
            Picker("Multicam inspector", selection: $inspector) {
                ForEach(Inspector.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch inspector {
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
            }
            InspectorRow("Microphone") {
                Picker("Microphone", selection: Binding(get: { item.audio }, set: { model.changeSwitch(item.at, audio: $0) })) {
                    Text("Use project audio policy").tag(nil as MulticamAudioSelection?)
                    audioOptions(project.sources, media: model.media)
                    if let selected = item.audio, !hasAudio(selected) {
                        Text("\(selected.source) · stream \(selected.stream) (unavailable)").tag(Optional(selected))
                    }
                }
            }
            if item.at != project.range.from {
                MulticamTimeField(label: "Time", value: item.at) { time in
                    model.parseTime(time) { model.moveSwitch(item.at, to: $0) }
                }
                Button("Delete Switch", systemImage: "trash", role: .destructive) { model.deleteSwitch(item.at) }
                    .help("Delete this switch (⌫)")
                if model.suggestionAnchor == item.at && !model.suggestions.isEmpty {
                    SectionHeading("Timing Alternatives").padding(.top, 4)
                    ForEach(model.suggestions, id: \.self) { at in
                        HStack {
                            Text(timelineTime(at.seconds, milliseconds: true))
                                .font(.system(size: 12, design: .monospaced))
                                .help("\(at.description) s")
                            Spacer()
                            Button("Preview") { model.seekGroup(at) }
                            Button("Apply") { model.moveSwitch(item.at, to: at) }
                        }
                    }
                }
            }
        } else {
            SectionHeading("Switch")
            Text("Select a switch marker on the timeline to edit its picture, microphone, or time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider().padding(.vertical, 2)
        HStack(alignment: .firstTextBaseline) {
            SectionHeading("Compare at the Playhead")
            Spacer()
            Button("Show Program", action: model.preview.endAudition)
                .help("Stop auditioning a camera and show the edited program again.")
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
                    .help("Audition \(source.displayName) at the playhead without switching")
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
                let ends = project.angles.compactMap { source in model.media[source.id].flatMap { try? $0.duration.adding(source.offset) } }
                if let end = ends.max(), end > project.range.to {
                    model.edit { $0.range = MulticamRange(from: $0.range.from, to: end) }
                }
            }
            .help("Move the end of the group to the end of the longest camera.")
            Divider().padding(.vertical, 2)
            SectionHeading("Sources")
            ForEach(project.sources, id: \.id) { source in
                let index = project.angles.firstIndex(where: { $0.id == source.id })
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: index == nil ? "waveform" : "video")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityLabel(index == nil ? "Audio recording" : "Camera")
                        MulticamNameField(name: source.displayName) { name in
                            model.updateSource(source.id) { $0.name = name }
                        }
                        if let index {
                            ControlGroup {
                                Button("Move Earlier", systemImage: "chevron.up") { model.moveSource(source.id, by: -1) }
                                    .disabled(index == 0)
                                    .help("Move this camera earlier in the angle order")
                                Button("Move Later", systemImage: "chevron.down") { model.moveSource(source.id, by: 1) }
                                    .disabled(index == project.angles.count - 1)
                                    .help("Move this camera later in the angle order")
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
                                .help("Nudge this source one \(index == nil ? "sample" : "frame") earlier")
                            Button("+1 \(index == nil ? "sample" : "frame")") { model.moveOffset(source.id, by: 1) }
                                .help("Nudge this source one \(index == nil ? "sample" : "frame") later")
                        }
                        .fixedSize()
                        Spacer()
                        Button("Relink…") { model.relink(source.id) }
                            .help("Point this source at a moved or renamed file")
                    }
                    if let progress = model.sourceIndexProgress[source.id] {
                        ProgressView("Indexing \(source.displayName)", value: progress)
                            .controlSize(.small)
                    }
                    if let message = model.sourceIssues[source.id] ?? model.sourceIndexIssues[source.id] {
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
            if project.assembly == nil {
                Text("The full group is selected for export. Mark and add a range to create an assembly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ControlGroup {
                    Button("Mark In") { model.markIn = model.markAnalysisTime() }
                        .help("Mark In at the playhead (I)")
                    Button("Mark Out") { model.markOut = model.markAnalysisTime() }
                        .help("Mark Out at the playhead (O)")
                }
                .fixedSize()
                Spacer()
                Button("Clear") { model.markIn = nil; model.markOut = nil }
                    .help("Clear Marks (Esc)")
                    .disabled(model.markIn == nil && model.markOut == nil)
            }
            if model.markIn != nil || model.markOut != nil {
                HStack(spacing: 12) {
                    markReadout("In", model.markIn)
                    markReadout("Out", model.markOut)
                }
            }
            HStack {
                Button("Add to Assembly", action: model.addMarkedRange)
                    .fixedSize()
                    .help("Add the marked range to the assembly (⌥⌘A).")
                    .disabled(!model.canAddMarkedRange)
                Button("Queue", action: model.enqueueMarkedRange)
                    .fixedSize()
                    .accessibilityLabel("Queue Range")
                    .help("Add the marked range to the export queue (⇧⌘A).")
                    .disabled(!model.canEnqueueMarkedRange)
                Spacer(minLength: 0)
                Button("Remove", systemImage: "trash", role: .destructive, action: model.removeMarkedRange)
                    .labelStyle(.iconOnly)
                    .help("Remove the marked range from the assembly")
                    .accessibilityLabel("Remove Marked Range")
                    .disabled(model.markedGroupSpan == nil)
            }
            Divider().padding(.vertical, 2)
            SectionHeading("Assembly")
            VStack(spacing: 2) {
                ForEach(Array(model.ranges.enumerated()), id: \.offset) { index, range in
                    let selected = model.selectedOccurrence == index
                    Button {
                        model.selectOccurrence(index)
                    } label: {
                        HStack {
                            Text("Range \(index + 1)").fontWeight(selected ? .semibold : .regular)
                            Spacer()
                            Text("\(timelineTime(range.from.seconds, milliseconds: true)) – \(timelineTime(range.to.seconds, milliseconds: true))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                                    in: RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            if model.ranges.indices.contains(model.selectedOccurrence) {
                let range = model.ranges[model.selectedOccurrence]
                MulticamTimeField(label: "Range Start", value: range.from) { text in
                    model.parseTime(text) { model.changeOccurrence(from: $0) }
                }
                MulticamTimeField(label: "Range End", value: range.to) { text in
                    model.parseTime(text) { model.changeOccurrence(to: $0) }
                }
                MulticamRangeActions(model: model, preview: model.preview)
                HStack {
                    ControlGroup {
                        Button("Earlier", systemImage: "arrow.up") { model.moveOccurrence(-1) }
                            .disabled(model.selectedOccurrence == 0)
                            .help("Move this range earlier in the assembly")
                        Button("Later", systemImage: "arrow.down") { model.moveOccurrence(1) }
                            .disabled(model.selectedOccurrence >= model.ranges.count - 1)
                            .help("Move this range later in the assembly")
                    }
                    .fixedSize()
                    Spacer()
                    Button("Remove", systemImage: "trash", role: .destructive, action: model.removeOccurrence)
                        .labelStyle(.iconOnly)
                        .help("Remove this range from the assembly")
                        .accessibilityLabel("Remove Range")
                        .disabled(project.assembly == nil)
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
            } else {
                if model.project != nil {
                    Button {
                        if model.canScanAnalysis(.silence) { model.scanAnalysis(.silence) }
                        showingPauseControls = true
                    } label: {
                        Label(model.canScanAnalysis(.silence) ? "Scan for Silence" : "Silence",
                              systemImage: "waveform")
                    }
                    .popover(isPresented: $showingPauseControls, arrowEdge: .top) { MulticamPauseControls(model: model) }
                    .help("Find quiet ranges in the routed program audio and open pause editing controls.")
                    if model.canStepAnalysis(.silence) {
                        HStack(spacing: 0) {
                            StatusIconButton(title: "Previous Silence", symbol: "chevron.left",
                                             help: "Previous Silence (⌃⌥←)") { model.stepAnalysis(.silence, direction: -1) }
                            StatusIconButton(title: "Next Silence", symbol: "chevron.right",
                                             help: "Next Silence (⌃⌥→)") { model.stepAnalysis(.silence, direction: 1) }
                        }
                    }
                    StatusBarDivider()
                    if model.analysis.isScanning(.scenes) {
                        Button("Cancel Scene Scan") { model.cancelAnalysis(.scenes) }
                    } else {
                        Button {
                            model.scanAnalysis(.scenes)
                        } label: {
                            Label("Scan for Scenes", systemImage: "viewfinder")
                        }
                        .disabled(!model.canScanAnalysis(.scenes))
                        .help("Find scene cuts in the background and enable scene navigation.")
                    }
                    MulticamSceneStatus(model: model, preview: model.preview)
                    if model.analysis.status != nil || !model.sourceIndexProgress.isEmpty || !model.status.isEmpty {
                        StatusBarDivider()
                    }
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
        EditorSheet(title: "Multicam Export Plan", message: "The checked plan for this export. Nothing has been written.") {
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
            Spacer()
            Button("Done") { showingReport = false }.keyboardShortcut(.defaultAction)
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
        guard modifiers.isEmpty else { return event }
        if (event.keyCode == 51 || event.keyCode == 117) && model.canDeleteSelection {
            if !event.isARepeat { model.deleteSelection() }
            return nil
        }
        if event.keyCode == 49 {
            if !event.isARepeat { model.preview.togglePlayback() }
            return nil
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
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
            Button("Trim End") { model.trimOccurrence(.end) }
                .disabled(!model.canTrimOccurrence)
            Button("Split", action: model.splitOccurrence)
                .disabled(!model.canCutOccurrence)
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
                .help("Rename this view across all matching scenes")
        }
    }
}

private struct MulticamProgramViewer: View {
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        EditorPreview(accessibilityTitle: "Multicam program preview", issue: preview.issue ?? preview.pictureIssue,
                      audioWarning: preview.audioIssue) {
            MulticamPreviewView(preview: preview)
        }
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
    @ObservedObject var preview: MulticamPreview
    let project: MulticamProject
    let inspectingAssembly: Bool
    let showSwitchInspector: () -> Void

    var body: some View {
        MulticamTimeline(project: project, media: model.media, playhead: model.groupTime(at: preview.time),
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
                         markIn: model.markIn, markOut: model.markOut,
                         assembly: model.assemblyPreview || inspectingAssembly
                            ? MulticamAssemblyTimeline(model: model, preview: preview) : nil)
    }
}

struct MulticamTransport: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview
    let project: MulticamProject

    var body: some View {
        let group = model.groupTime(at: preview.time)
        let activeCamera = project.selection(at: group)?.angle ?? project.switches.last?.angle
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
            marks: .init(hasIn: model.markIn != nil, hasOut: model.markOut != nil,
                         setIn: { model.markIn = model.markAnalysisTime() },
                         setOut: { model.markOut = model.markAnalysisTime() },
                         clear: { model.markIn = nil; model.markOut = nil }),
            cameras: cameras,
            addRange: .init(title: "Add Marked Range to Export Queue", enabled: model.canEnqueueMarkedRange,
                            perform: model.enqueueMarkedRange),
            split: .init(title: "Split Assembly Range at Playhead", enabled: model.canCutOccurrence,
                         perform: model.splitOccurrence),
            delete: .init(title: model.deleteTitle, enabled: model.canDeleteSelection, perform: model.deleteSelection),
            undo: .init(title: "Undo", enabled: !model.undoStack.isEmpty, perform: model.undo),
            redo: .init(title: "Redo", enabled: !model.redoStack.isEmpty, perform: model.redo),
            play: PreviewPlayButton(rate: preview.playbackRate, disabled: false, toggle: preview.togglePlayback)
        ) {
            Picker("Preview", selection: Binding(get: { model.assemblyPreview }, set: model.setAssemblyPreview)) {
                Text("Group").tag(false)
                Text("Assembly").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
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
                .help("\(timelineTime(value.seconds, milliseconds: true)) · exact seconds; press Return to apply")
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
    }

    private func save() {
        let proposed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proposed.isEmpty && proposed != name { commit(proposed) }
        else { text = name }
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
                Text("Stream \(audio.stream.index) · \(audio.stream.codec)").tag(Optional(audio.stream.index))
            }
            if let stream, !(media?.audio.contains { $0.stream.index == stream } ?? false) {
                Text("Stream \(stream) (unavailable)").tag(Optional(stream))
            }
          }
        }
    }
}

@ViewBuilder
private func audioOptions(_ sources: [MulticamSource], media: [String: MediaInfo]) -> some View {
    ForEach(sources, id: \.id) { source in
        ForEach(media[source.id]?.audio ?? [], id: \.stream.index) { audio in
            Text("\(source.displayName) · stream \(audio.stream.index) · \(audio.stream.codec)")
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
        }
        if let selection {
            InspectorRow("Master track", labelWidth: labelWidth) {
                Picker("Master track", selection: Binding(get: { Optional(selection) }, set: { value in if let value { audio = .fixed(value) } })) {
                    audioOptions(sources, media: media)
                    if !(media[selection.source]?.audio.contains { $0.stream.index == selection.stream } ?? false) {
                        Text("\(selection.source) · stream \(selection.stream) (unavailable)").tag(Optional(selection))
                    }
                }
            }
        }
    }
}

private struct MulticamSetupSheet: View {
    @ObservedObject var model: MulticamEditorModel
    @State var drafts: [MulticamEditorModel.SourceDraft]
    @State private var opening = ""
    @State private var audio: MulticamAudioPolicy = .none
    @State private var customizedAudio = false

    var body: some View {
        EditorSheet(title: model.project == nil ? "Set Up Multicam" : "Add Multicam Sources",
                    message: "Name each source and set the camera order. Cameras 1–9 switch with the number keys.") {
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
                            ControlGroup {
                                Button("Move Up", systemImage: "chevron.up") { drafts.swapAt(index, index - 1) }
                                    .disabled(index == 0)
                                Button("Move Down", systemImage: "chevron.down") { drafts.swapAt(index, index + 1) }
                                    .disabled(index == drafts.count - 1)
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
                    }
                    MulticamAudioPolicyControl(audio: Binding(get: { audio }, set: { audio = $0; customizedAudio = true }),
                                               sources: drafts.map(\.source),
                                               media: Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0.media) }),
                                               labelWidth: 110)
                }
            }
        } actions: {
            Spacer()
            Button("Cancel", action: model.dismissSetup).keyboardShortcut(.cancelAction)
            Button(model.project == nil ? "Create Multicam" : "Add Sources") {
                model.confirmSetup(drafts: drafts, opening: opening, audio: audio)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy)
        }
        .frame(width: 520)
        .onAppear { opening = drafts.first(where: { $0.media.hasVideo })?.id ?? ""; selectDefaultAudio() }
        .onChange(of: opening) { _, _ in if !customizedAudio { selectDefaultAudio() } }
    }

    private func selectDefaultAudio() {
        let choice = drafts.first { $0.id == opening && !$0.media.audio.isEmpty } ?? drafts.first { !$0.media.audio.isEmpty }
        if let choice, let stream = choice.media.audio.first?.stream.index {
            audio = .fixed(MulticamAudioSelection(source: choice.id, stream: stream))
        } else { audio = .none }
    }
}

private struct MulticamExportControls: View {
    @ObservedObject var model: MulticamEditorModel
    let project: MulticamProject
    @State private var mode: ExportMode
    @State private var tracks: ExportTracks = .all
    @State private var container = "mov"
    @State private var wholeGroup = false
    @State private var codec: ReencodeCodec = .h264
    @State private var audio: ReencodeAudio = .copyOriginal
    @State private var checkedConversion: Conversion?

    init(model: MulticamEditorModel, project: MulticamProject) {
        self.model = model
        self.project = project
        _mode = State(initialValue: model.preferences.defaultExportMode == .copy ? .copy : .smart)
    }

    private struct Conversion: Equatable {
        let project: MulticamProject
        let container: String
        let wholeGroup: Bool
        let settings: ReencodeSettings
    }

    private var conversion: Conversion {
        Conversion(project: project, container: container, wholeGroup: wholeGroup,
                   settings: ReencodeSettings(codec: codec, audio: audio))
    }

    var body: some View {
        SectionHeading("Export")
        InspectorRow("Program") {
            Picker("Program", selection: $wholeGroup) {
                Text("Current assembly").tag(false)
                Text("Whole group").tag(true)
            }
        }
        InspectorRow("Tracks") {
            Picker("Tracks", selection: $tracks) {
                Text(project.audio == .none && project.switches.allSatisfy { $0.audio == nil }
                     ? "Project tracks (picture only)" : "Project tracks").tag(ExportTracks.all)
                Text("Picture only (Lossless Copy)").tag(ExportTracks.video)
                Text("Sound only (Lossless Copy)").tag(ExportTracks.audio)
            }
        }
        if tracks == .all {
            InspectorRow("Mode") {
                Picker("Mode", selection: $mode) {
                    Text("Smart Trim").tag(ExportMode.smart)
                    Text("Lossless Copy").tag(ExportMode.copy)
                }
            }
        }
        InspectorRow("Container") {
            Picker("Container", selection: $container) {
                ForEach(["mov", "mp4", "m4v", "mkv"], id: \.self) { Text(containerDisplayName($0)).tag($0) }
                if tracks == .audio { Text(containerDisplayName("wav")).tag("wav") }
            }
        }
        let sourceIssue = model.exportSourceIssue(tracks: tracks, wholeGroup: wholeGroup)
        if let sourceIssue {
            IssueLabel(sourceIssue)
        }
        HStack {
            Button("Check Export") { checkExport() }
                .help("Plan this export and show the report without writing a file.")
            Spacer()
            Button("Export…") { chooseDestination(mode: effectiveMode, tracks: tracks) }
                .buttonStyle(.borderedProminent)
        }
        .disabled(sourceIssue != nil)
        .onChange(of: tracks) { _, tracks in if tracks != .audio && container == "wav" { container = "mov" } }

        if tracks == .all {
            Divider().padding(.vertical, 2)
            SectionHeading("Re-encode")
            InspectorRow("Video") {
                Picker("Video", selection: $codec) {
                    ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            InspectorRow("Audio") {
                Picker("Audio", selection: $audio) {
                    ForEach([ReencodeAudio.copyOriginal, .aac, .pcm, .removeAudio], id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            HStack {
                Button("Check Re-encode") { checkConversion() }
                    .help("A re-encode must pass this check before it can be exported.")
                Spacer()
                Button("Export Re-encoded…") {
                    chooseDestination(mode: .encode, tracks: .all, settings: conversion.settings)
                }
                .buttonStyle(.borderedProminent)
                .disabled(checkedConversion != conversion)
                .help(checkedConversion == conversion ? "Export with these re-encode settings"
                                                      : "Choose Check Re-encode first.")
            }
            .disabled(sourceIssue != nil)
        }
        Divider().padding(.vertical, 2)
        SectionHeading("Source Audio")
        Button("Replace Source Audio…", action: model.chooseReplacementAudio)
            .help("Use one soundtrack for the whole multicam program.")
            .disabled(!model.canReplaceSourceAudio)
    }

    private var effectiveMode: ExportMode { tracks == .all ? mode : .copy }

    private var checkDestination: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("multicam-check-\(UUID()).\(container)")
    }

    private func checkExport() {
        model.export(output: checkDestination, mode: effectiveMode, tracks: tracks, dryRun: true, wholeGroup: wholeGroup)
    }

    private func checkConversion() {
        let requested = conversion
        model.export(output: checkDestination, mode: .encode, tracks: .all, dryRun: true,
                     wholeGroup: wholeGroup, settings: requested.settings) {
            checkedConversion = requested
        }
    }

    private func chooseDestination(mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings = .init()) {
        let panel = NSSavePanel()
        panel.title = "Export Multicam"
        panel.allowedContentTypes = [UTType(filenameExtension: container) ?? .data]
        panel.nameFieldStringValue = "Multicam.\(container)"
        let wholeGroup = wholeGroup
        ProjectPanels.present(panel, in: model.window) { [weak model] accepted in
            guard accepted, let output = panel.url else { return }
            model?.export(output: output, mode: mode, tracks: tracks, dryRun: false, wholeGroup: wholeGroup, settings: settings)
        }
    }
}

