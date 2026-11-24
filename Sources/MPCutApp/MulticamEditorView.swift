import AppKit
import Combine
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

struct MulticamEditorView: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var presentation: EditorPresentation
    @Environment(\.transcriptSession) private var transcriptSession
    @State private var showingReport = false
    @State private var proposedCamera: CameraCoverageReview?

    private struct CameraCoverageReview: Identifiable {
        let id = UUID()
        let revision: Int
        let generation: UUID
        let mediaRevision: UInt64
        let camera: String
        let report: MulticamSwitchCoverage
    }
    @State private var showingSyncSuggestions = false

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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let url = model.projectURL {
                ProjectMediaBanner(count: model.projectMediaSummary.offline) {
                    model.presentProjectMedia(offlineOnly: true)
                }
                .id(url)
            }
        }
        .sheet(item: $model.projectMediaRequest, onDismiss: openReplacementTranscription) { request in
            ProjectMediaSheet(jobs: model.projectMediaJobs, request: request, archive: { model.projectMediaArchive },
                              revision: { .init(generation: model.mcpGeneration, edit: model.mcpRevision) }, isMulticam: true,
                              status: model.mediaStatus(for:),
                              relinkBatch: { try await model.relinkProjectMedia($0) },
                              revert: { try await model.revertProjectMedia($0) },
                              ignore: model.ignoreProjectMedia,
                              replace: { try await model.applyProjectMediaReplacement($0) },
                              showUse: model.showProjectMediaUse)
        }
        .onReceive(model.projectMediaJobs.$transcriptSetup) { request in
            if request != nil, model.projectMediaRequest == nil {
                Task { @MainActor in openReplacementTranscription() }
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
        .sheet(item: $proposedCamera) { proposal in
            cameraCoverageSheet(proposal)
        }
        .sheet(isPresented: $showingSyncSuggestions) { MulticamSyncSheet(model: model) }
        .sheet(isPresented: $showingReport, onDismiss: { model.report = nil }) { reportSheet }
        .sheet(isPresented: $model.isBulkQueuePresented) { MulticamBulkQueueView(model: model) }
        .sheet(isPresented: $model.isReplacementAudioPresented) { MulticamReplacementAudioView(model: model) }
        .sheet(isPresented: Binding(get: { model.trackReplacementTarget != nil },
                                    set: { if !$0 { model.trackReplacementTarget = nil } })) {
            if let target = model.trackReplacementTarget {
                MulticamTrackReplacementView(model: model, original: target) { model.trackReplacementTarget = nil }
            }
        }
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

    private func openReplacementTranscription() {
        guard let transcriptSession, let request = model.projectMediaJobs.takeTranscription() else { return }
        presentation.setTranscriptVisible(true, multicam: true)
        transcriptSession.transcript.replacementSetup = request
    }

    private func editor(_ project: MulticamProject) -> some View {
        EditorWorkspace(
            viewer: MulticamProgramViewer(preview: model.preview)
                .overlay {
                    let editing = presentation.inspectorVisible && presentation.inspector == .participants
                    if let transcriptSession, editing || !project.participants.isEmpty {
                        ParticipantMonitorOverlay(session: transcriptSession, interactive: editing)
                    }
                }
                .overlay { MulticamMediaSlate(model: model, preview: model.preview) }
                .modifier(EditorMediaDrop(enabled: model.canChooseSources, importFiles: { model.dropMulticamMedia($0) })),
            transport: MulticamTransport(model: model, preview: model.preview, project: project),
            timeline: MulticamTimelineHost(model: model, preview: model.preview, project: project,
                                           inspectingAssembly: presentation.inspectorVisible && presentation.inspector == .assembly) {
                presentation.inspector = .switches
                presentation.inspectorVisible = true
            }
            .disabled(model.isBusy),
            status: status, showsTimeline: true, showsStatus: showsStatus, allowsTimelineResize: true,
            showsSidebar: presentation.inspectorVisible
        ) {
            inspectorPanel(project)
        }
    }

    private var inspectorPicker: some View {
        Picker("Multicam inspector", selection: $presentation.inspector) {
            ForEach(EditorPresentation.Inspector.allCases, id: \.self) { inspector in
                let toolTip = switch inspector {
                case .switches: "Inspect camera switches"
                case .sources: "Inspect multicam sources"
                case .assembly: "Inspect assembly ranges"
                case .export: "Configure multicam export"
                case .transcript: "Read and edit the transcript"
                case .participants: "Review camera feeds and meeting participants"
                }
                Text(inspector.label).help(toolTip).tag(inspector)
            }
        }
        .labelsHidden()
    }

    private func inspectorPanel(_ project: MulticamProject) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    inspectorPicker.pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    PanelDockToggle()
                }
                HStack {
                    Text("Inspector").font(.headline)
                    Spacer()
                    inspectorPicker.pickerStyle(.menu).fixedSize()
                    PanelDockToggle()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .help("Choose inspector panel")
            Divider()
            if presentation.inspector == .transcript, let transcriptSession {
                TranscriptPane(session: transcriptSession).equatable()
            } else if presentation.inspector == .participants, let transcriptSession {
                ParticipantInspector(session: transcriptSession)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch presentation.inspector {
                        case .switches: switchInspector(project)
                        case .sources: sourceInspector(project)
                        case .assembly: assemblyInspector(project)
                        case .export: MulticamExportControls(model: model, project: project)
                        case .transcript, .participants: EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .disabled(model.isBusy)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func switchInspector(_ project: MulticamProject) -> some View {
        if let item = project.switches.first(where: { $0.at == model.selectedSwitch }) {
            SectionHeading(item.at == project.range.from
                           ? "Opening Switch" : "Switch at \(timelineTime(item.at.seconds, milliseconds: true))")
            InspectorRow("Picture") {
                Picker("Picture", selection: Binding(get: { item.angle }, set: { angle in model.byHand { model.changeSwitch(item.at, angle: angle) } })) {
                    ForEach(project.angles, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                .help("Choose camera angle")
            }
            InspectorRow("Audio Stream") {
                Picker("Audio Stream", selection: Binding(get: { item.audio }, set: { audio in model.byHand { model.changeSwitch(item.at, audio: audio) } })) {
                    Text("Use project audio policy").tag(nil as MulticamAudioSelection?)
                    let sources = directAudioSources(project)
                    audioOptions(sources, media: model.media)
                    if let selected = item.audio, !hasAudio(selected) || !sources.contains(where: { $0.id == selected.source }) {
                        Text("\(selected.source) · stream \(selected.stream) (unavailable)").tag(Optional(selected))
                    }
                }
                .help("Choose the audio stream for this switch")
            }
            if item.at != project.range.from {
                MulticamTimeField(label: "Group time", value: item.at) { time in
                    model.parseTime(time) { model.moveSwitch(item.at, to: $0) }
                }
                Button("Delete Switch", systemImage: "trash", role: .destructive) { model.byHand { model.deleteSwitch(item.at) } }
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
                            Button("Move Switch") { model.byHand { model.moveSwitch(item.at, to: at) } }
                                .help("Move the selected switch to this group time")
                        }
                    }
                }
            }
        } else {
            SectionHeading("Switch")
            Text("Select a switch marker to change its camera, audio stream, or time.")
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
                    .disabled(source.recordings.allSatisfy { model.media[$0.id] == nil })
                Button("Take Camera…") {
                    do {
                        proposedCamera = try .init(revision: model.mcpRevision, generation: model.mcpGeneration,
                                                   mediaRevision: model.transcriptMediaRevision, camera: source.displayName,
                                                   report: model.cameraCoverageAtPlayhead(source.id))
                    } catch { model.fail(error.localizedDescription) }
                }
                    .help("Review picture and audio coverage before taking \(source.displayName)")
                    .accessibilityLabel("Review camera \(source.displayName) at group time")
            }
        }
    }

    private func cameraCoverageSheet(_ proposal: CameraCoverageReview) -> some View {
        let report = proposal.report
        func isCurrent() -> Bool {
            model.mcpRevision == proposal.revision && model.mcpGeneration == proposal.generation &&
                model.transcriptMediaRevision == proposal.mediaRevision
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Take \(proposal.camera)").font(.headline)
            Text("Group \(report.group.from.description)–\(report.group.to.description) seconds")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    coverageLane("Picture", report.picture)
                    if let lanes = report.audioLanes {
                        ForEach(lanes, id: \.id) { lane in
                            coverageLane(lane.label, lane.coverage)
                        }
                    } else {
                        coverageLane("Audio", report.audio)
                    }
                    ForEach(Array(report.audioRoutes.enumerated()), id: \.offset) { _, route in
                        let label = report.audioLanes?.first { $0.id == route.laneID }?.label
                        let name = model.project?.sources.first { $0.id == route.audio.source }?.displayName ?? route.audio.source
                        Text("\(label.map { $0 + " · " } ?? "")\(name) · Stream \(route.audio.stream) · \(route.group.from.description)–\(route.group.to.description) seconds")
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90, maxHeight: 220)
            if !isCurrent() {
                Text("The project or source media changed. Close this review and select the camera again.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { proposedCamera = nil }.keyboardShortcut(.cancelAction)
                Button("Take Camera") {
                    proposedCamera = nil
                    guard isCurrent() else { return }
                    model.byHand { _ = model.take(report.angleID, at: report.group.from, snap: false) }
                }
                .disabled(!isCurrent() || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 410)
    }

    private func coverageLane(_ name: String, _ lane: MulticamSwitchCoverage.Lane) -> some View {
        let status: String = switch lane.status {
        case .covered: "Full coverage"
        case .gaps: "Coverage gaps"
        case .unavailable: "Index unavailable"
        case .unrouted: "No audio routed"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(name).fontWeight(.semibold)
            Text(status)
            ForEach(lane.missing, id: \.self) { gap in
                Text("\(gap.from.description)–\(gap.to.description) seconds").monospacedDigit()
            }
        }
    }

    private func sourceInspector(_ project: MulticamProject) -> some View {
        Group {
            SectionHeading("Group")
            MulticamAudioPolicyControl(audio: Binding(get: { project.audio }, set: { audio in
                model.byHand { model.setProgramAudio(audio) }
            }), sources: directAudioSources(project), media: model.media, fixedAudio: project.fixedAudio,
               canSelectMix: !project.mixLanes.isEmpty || !project.defaultMixLanes.isEmpty)
            MulticamMixControls(model: model, project: project)
            MulticamTimeField(label: "Group End", value: project.range.to) { text in
                model.parseTime(text) { time in
                    model.edit { $0.range = MulticamRange(from: $0.range.from, to: time) }
                }
            }
            Button("Extend to Last Camera") {
                if let end = model.lastCameraGroupEnd, end > project.range.to {
                    model.byHand { model.edit { $0.range = MulticamRange(from: $0.range.from, to: end) } }
                }
            }
            .help("Extend to longest camera")
            Divider().padding(.vertical, 2)
            HStack {
                SectionHeading("Sources")
                Spacer()
                Button("Project Media…") { model.presentProjectMedia() }
                Button("Suggest Sync…") { showingSyncSuggestions = true }
                    .disabled(directAudioSources(project).count < 2 || model.isBusy)
            }
            let mediaIssues = model.mediaRefreshIssues
            let boundSources = Set(project.audioReplacements.map(\.replacement.source))
            ForEach(project.sources, id: \.id) { source in
                let index = project.angles.firstIndex(where: { $0.id == source.id })
                let isCamera = project.pictureSources.contains { $0.id == source.id }
                let isBoundReplacement = boundSources.contains(source.id)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: isCamera ? "video" : "waveform")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityLabel(isCamera ? "Camera recording" : "Audio recording")
                        MulticamNameField(name: source.displayName) { name in
                            model.renameSource(source.id, to: name)
                        }
                        if let index {
                            ControlGroup {
                                Button("Move Earlier", systemImage: "chevron.up") { model.byHand { model.moveSource(source.id, by: -1) } }
                                    .disabled(index == 0)
                                    .help("Move camera earlier")
                                Button("Move Later", systemImage: "chevron.down") { model.byHand { model.moveSource(source.id, by: 1) } }
                                    .disabled(index == project.angles.count - 1)
                                    .help("Move camera later")
                            }
                            .fixedSize()
                        }
                    }
                    if index != nil {
                        Button("Add Recording…") { model.chooseAdditionalRecording(for: source.id) }
                    }
                    if let coverage = source.coverage {
                        Text("Group \(coverage.from)–\(coverage.to)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(source.id == project.referenceAngle ? "Reference camera · \(source.file)" : source.file)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(source.file)
                    if isBoundReplacement {
                        Text("Synced replacement").font(.caption).foregroundStyle(.secondary)
                    } else {
                        MulticamTimeField(label: "Offset", value: source.offset) { text in
                            model.parseTime(text) { offset in model.updateSource(source.id) { $0.offset = offset } }
                        }
                    }
                    HStack {
                        if !isBoundReplacement {
                            ControlGroup {
                                Button("−1 \(isCamera ? "frame" : "sample")") { model.byHand { model.moveOffset(source.id, by: -1) } }
                                    .help("Shift earlier one \(isCamera ? "frame" : "sample")")
                                Button("+1 \(isCamera ? "frame" : "sample")") { model.byHand { model.moveOffset(source.id, by: 1) } }
                                    .help("Shift later one \(isCamera ? "frame" : "sample")")
                            }
                            .fixedSize()
                        }
                        Spacer()
                        Menu("Media") {
                            ForEach([ProjectMediaAction.locate, .replace, .reveal, .show], id: \.rawValue) { action in
                                Button(action.title) {
                                    model.presentProjectMedia(action, path: model.projectMediaURL(source.file).path)
                                }
                                .disabled(action == .reveal && model.mediaStatus(for: model.projectMediaURL(source.file)).hidesMedia)
                            }
                        }
                    }
                    if let progress = model.sourceIndexProgress[source.id] {
                        ProgressView("Indexing \(source.displayName)", value: progress)
                            .controlSize(.small)
                    }
                    if let message = mediaIssues[source.id] ?? model.sourceIssues[source.id] ?? model.sourceIndexIssues[source.id] {
                        IssueLabel(message)
                    }
                    if isCamera {
                        MulticamSourceTrackPicker(stream: Binding(get: { source.audioStream }, set: { stream in
                            model.byHand { model.updateSource(source.id) { $0.audioStream = stream } }
                        }), media: model.media[source.id])
                        if let tracks = model.media[source.id]?.audio, !tracks.isEmpty {
                            Menu("Replace Track Audio…") {
                                ForEach(tracks.map(\.stream), id: \.index) { stream in
                                    Button(stream.exportLabel) {
                                        model.chooseTrackReplacementAudio(.init(source: source.id, stream: stream.index))
                                    }
                                }
                            }
                            .disabled(!model.canReplaceSourceAudio)
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func directAudioSources(_ project: MulticamProject) -> [MulticamSource] {
        let boundSources = Set(project.audioReplacements.map(\.replacement.source))
        return project.sources.filter { !boundSources.contains($0.id) }
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
                Button("Clear Marks") { model.markIn = nil; model.markOut = nil }
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
                Button("Add to Assembly") { model.byHand { model.addMarkedRange() } }
                    .fixedSize()
                    .help("Add range to assembly (⌥⌘A)")
                    .disabled(!model.canAddMarkedRange)
                Button("Queue", action: model.enqueueMarkedRange)
                    .fixedSize()
                    .accessibilityLabel("Queue Range")
                    .help("Queue marked range (⇧⌘A)")
                    .disabled(!model.canEnqueueMarkedRange)
                Spacer(minLength: 0)
                Button("Remove", systemImage: "trash", role: .destructive) { model.byHand { model.deleteSelectedRange() } }
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
                                   insertGap: model.chooseInsertGap, spaceClips: model.chooseSpaceClips, canSpace: model.canSpaceClips, manage: model.manageMulticamStill)
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
                let occurrence = model.selectedOccurrence
                InspectorRow("Picture Angle") {
                    Picker("Picture Angle", selection: Binding(get: { model.assemblyItems.indices.contains(occurrence) ? model.assemblyItems[occurrence].angleOverride : nil },
                                                                set: { angle in
                        model.byHand {
                            if model.setOccurrenceAngle(occurrence, angle: angle) {
                                model.selectAssemblyOccurrence(occurrence)
                            }
                        }
                    })) {
                        Text("Group Switches").tag(nil as String?)
                        ForEach(project.angles) { camera in
                            Text(camera.displayName).tag(Optional(camera.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isBusy)
                    .help("Choose one camera for the selected occurrence while retaining the group audio route")
                }
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
                        Button("Earlier", systemImage: "arrow.up") { model.byHand { model.moveOccurrence(-1) } }
                            .disabled(model.selectedOccurrence == 0)
                            .help("Move range earlier")
                        Button("Later", systemImage: "arrow.down") { model.byHand { model.moveOccurrence(1) } }
                            .disabled(model.selectedOccurrence >= model.assemblyItems.count - 1)
                            .help("Move range later")
                    }
                    .fixedSize()
                    Spacer()
                    Button("Remove", systemImage: "trash", role: .destructive) { model.byHand { model.removeOccurrence() } }
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
                    ProgressView(value: progress).frame(width: 132).barLeading()
                    Text(progressPercent(progress)).monospacedDigit()
                } else { ProgressView().controlSize(.small).barLeading() }
                Text(model.status).lineLimit(1).help(model.status)
                Spacer(minLength: 8)
                Button("Cancel", action: model.cancel)
                    .help("Cancel current operation")
            } else {
                if model.project != nil {
                    BarButton(model.canScanAnalysis(.silence) ? "Scan for Silence" : "Silence", symbol: "waveform",
                              active: presentation.pauseControls) {
                        if model.canScanAnalysis(.silence) { model.scanAnalysis(.silence) }
                        presentation.pauseControls = true
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
                            Label("Scan for Scenes", systemImage: "viewfinder")
                        }
                        .barMenu()
                        .disabled(!model.analysis.canScanScenes(camera: nil))
                        .help("Find camera scene changes")
                        .task(id: model.analysis.sceneInspectionKey(camera: nil)) {
                            await model.analysis.inspectSceneChoices(camera: nil)
                        }
                    }
                    MulticamSceneStatus(model: model, preview: model.preview)
                    // The badge sits behind a divider in both editors, whatever follows it.
                    StatusBarDivider()
                    // The tier of the saved program, as the editor's status bar shows it for a file timeline.
                    MulticamTierBadge(model: model)
                }
                ProjectMediaJobStatus(jobs: model.projectMediaJobs) { model.presentProjectMedia() }
                let mediaSummary = model.projectMediaSummary
                if let title = mediaSummary.title {
                    let state: ProjectMediaStatus = mediaSummary.offline > 0 ? .offline : .needsReview
                    BarButton(title, symbol: state.editorIcon) { model.presentProjectMedia() }
                        .foregroundStyle(Color(nsColor: state.editorColor))
                        .help("Open Project Media")
                }
                if let analysis = model.analysis.status {
                    Text(analysis).lineLimit(1).help(analysis)
                }
                if !model.sourceIndexProgress.isEmpty {
                    let count = model.sourceIndexProgress.count
                    ProgressView().controlSize(.small).accessibilityHidden(true)
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
            if let summary = model.exportDeliverySummary {
                Text(summary).font(.callout).lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
            }
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
        if presentation.transcriptKeyHandler?(event, modifiers) == true { return nil }
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
                  model.byHand({ model.takeCamera(number: number) }) else { return event }
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
            Button("Split") { model.byHand { model.splitOccurrence() } }
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

private struct MulticamMediaSlate: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        if let url = model.projectMediaPreviewURL(at: preview.time) {
            let status = model.mediaStatus(for: url)
            if status.hidesMedia {
                ProjectMediaSlate(url: url, status: status) {
                    model.presentProjectMedia(.locate, path: url.path)
                }
            }
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
                         ), showsSourceRuler: model.preferences.sourceTimeTicks, timeEntryRequest: model.timeEntryRequest, analysis: model.analysis,
                         snapTarget: Binding(get: { model.analysis.snapTarget }, set: model.setAnalysisSnap),
                         jump: { model.preview.pause(); model.seekGroup($0) },
                         markIn: model.markIn, markOut: model.markOut, assemblySelection: model.assemblySelection,
                         showGroupAssets: !model.assemblyPreview,
                         groupStillFrames: model.groupStillFrames,
                         dropGroupStills: model.isBusy ? nil : { urls, group in
                             model.dropMulticamStills(urls, atGroup: group,
                                                     replacingMarkedRange: NSEvent.modifierFlags.contains(.option))
                         },
                         assembly: model.assemblyPreview || inspectingAssembly
                            ? MulticamAssemblyTimeline(model: model, preview: preview, paddingSpans: model.paddingSpans(assembly: true)) : nil)
        timeline.sourceMediaStatus = { model.mediaStatus(for: model.projectMediaURL($0.file)) }
        timeline.onProjectMedia = { action, source in
            model.presentProjectMedia(action, path: model.projectMediaURL(source.file).path, useID: source.id)
        }
        if !model.isBusy { timeline.onPreviewSwitch = { _ = model.previewMulticamSwitch(at: $0) } }
        timeline.groupPadding = model.paddingSpans(assembly: false)
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
                    MulticamTierGate.byHand { commit(text) }
                    text = value.description
                }
                .help("Edit \(label.lowercased()) in seconds")
            Text("s").foregroundStyle(.secondary)
        }
        .onAppear { text = value.description }
        .onChange(of: value) { _, newValue in text = newValue.description }
    }
}

struct MulticamNameField: View {
    let name: String
    var fieldLabel = "Source name"
    var help = "Rename source"
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField(fieldLabel, text: $text)
            .focused($editing)
            .onAppear { text = name }
            .onChange(of: name) { _, name in if !editing { text = name } }
            .onChange(of: editing) { _, editing in if !editing { save() } }
            .onSubmit { save(); editing = false }
            .help(help)
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
        InspectorRow("Audio Stream") {
          Picker("Camera audio stream", selection: $stream) {
            Text("None assigned").tag(nil as Int?)
            ForEach(media?.audio ?? [], id: \.stream.index) { audio in
                Text(audio.stream.exportLabel).tag(Optional(audio.stream.index))
            }
            if let stream, !(media?.audio.contains { $0.stream.index == stream } ?? false) {
                Text("Stream \(stream) (unavailable)").tag(Optional(stream))
            }
          }
          .help("Choose the audio stream that follows this camera")
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
    var fixedAudio: MulticamAudioSelection? = nil
    var canSelectMix = false

    private enum Policy: String, CaseIterable {
        case fixed = "Fixed master", follow = "Audio follows camera", mix = "Mix", none = "Video only"
    }

    private var policy: Policy {
        switch audio {
        case .fixed: return .fixed
        case .follow: return .follow
        case .mix: return .mix
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
            case .mix: audio = .mix
            case .fixed:
                if let fixedAudio {
                    audio = .fixed(fixedAudio)
                } else if let source = sources.first(where: { !(media[$0.id]?.audio.isEmpty ?? true) }),
                   let track = media[source.id]?.audio.first {
                    audio = .fixed(MulticamAudioSelection(source: source.id, stream: track.stream.index))
                }
            }
        })) {
            ForEach(Policy.allCases, id: \.self) { option in
                Text(option.rawValue).tag(option).disabled(option == .mix && !canSelectMix)
            }
          }
          .help("Choose soundtrack policy")
        }
        if let selection {
            InspectorRow("Master track", labelWidth: labelWidth) {
                Picker("Master track", selection: Binding(get: { Optional(selection) }, set: { value in if let value { audio = .fixed(value) } })) {
                    audioOptions(sources, media: media)
                    if !sources.contains(where: { $0.id == selection.source }) ||
                        !(media[selection.source]?.audio.contains { $0.stream.index == selection.stream } ?? false) {
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
    @State private var fixedAudio: MulticamAudioSelection?
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
                    MulticamAudioPolicyControl(audio: Binding(get: { audio }, set: {
                        audio = $0
                        if case .fixed(let selection) = $0 { fixedAudio = selection }
                        customizedAudio = true
                    }),
                                               sources: drafts.map(\.source),
                                               media: Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0.media) }),
                                               labelWidth: 110,
                                               fixedAudio: fixedAudio,
                                               canSelectMix: drafts.contains { $0.media.hasVideo && $0.source.audioStream != nil })
                }
            }
        } actions: {
            Spacer()
            Button("Cancel") { model.dismissSetup(ifCurrent: setupID) }.keyboardShortcut(.cancelAction)
                .help("Cancel multicam setup")
            Button(model.project == nil ? "Create Multicam" : "Add Sources") {
                model.confirmSetup(drafts: drafts, opening: opening, audio: audio, fixedAudio: fixedAudio, ifCurrent: setupID)
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
            model.updatePendingSetup(drafts, opening: opening, audio: audio, fixedAudio: fixedAudio)
        }
        .onChange(of: audio) { _, _ in model.updatePendingSetup(drafts, opening: opening, audio: audio, fixedAudio: fixedAudio) }
        .onChange(of: drafts.map(\.source)) { _, _ in
            model.updatePendingSetup(drafts, opening: opening, audio: audio, fixedAudio: fixedAudio)
        }
    }

    private func selectDefaultAudio() {
        let choice = drafts.first { $0.id == opening && !$0.media.audio.isEmpty } ?? drafts.first { !$0.media.audio.isEmpty }
        if let choice, let stream = choice.media.audio.first?.stream.index {
            let selection = MulticamAudioSelection(source: choice.id, stream: stream)
            audio = .fixed(selection)
            fixedAudio = selection
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
        Self.placementScope(model.stillExportDocument(wholeGroup: wholeGroup, selection: selectionRanges))
    }

    private static func placementScope(_ document: CutProject?) -> ExportPlacementScope {
        guard let document, document.participants.render == nil else { return .none }
        let authored = (try? document.exportPlacementScope()) ?? .none
        guard authored == .none, case .multicam(let project) = document, project.angles.contains(where: { $0.coverage != nil }),
              (try? project.plan().recordingGaps.isEmpty) == false else { return authored }
        return .replacement
    }
    @State private var pendingBoundary: StillBoundaryAdjustment?

    init(model: MulticamEditorModel, project: MulticamProject) {
        self.model = model
        self.project = project
        // A failed check moves the inspector to the switch it names. Coming back, the offers still on show are about
        // the mode that failed, so the control reopens on it rather than on the preference.
        let preferred = model.unavailableExportMode ?? model.preferences.defaultExportMode
        var initial = MulticamExportChoices(entry: .multicamSheet, preferred: preferred)
        let selection = model.exportProgram == .selection ? model.selectedExportRanges : nil
        let document = model.stillExportDocument(wholeGroup: model.exportProgram == .group, selection: selection)
        initial.participantAudio = project.participants.render?.audio.mode
        initial.placements = Self.placementScope(document)
        if initial.participantAudio != nil { initial.settle() }
        if initial.placements != .none {
            initial.mode = model.unavailableExportMode ?? .smart
            initial.container = document?.stillFormat?.container ?? "mov"
            initial.settle()
        }
        _choices = State(initialValue: initial)
    }

    private struct Review: Equatable {
        let project: MulticamProject
        let choices: MulticamExportChoices
        let wholeGroup: Bool
        let selection: [MulticamRange]?
    }

    private var review: Review {
        Review(project: project, choices: choices, wholeGroup: wholeGroup, selection: selectionRanges)
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
                ForEach(choices.participantAudio == nil ? ExportTracks.allCases : [.all, .video], id: \.self) {
                    Text(choices.participantAudio == nil
                         ? MulticamExportChoices.title(of: $0, silentProject: silent, placements: choices.placements)
                         : ($0 == .all ? "Saved composition" : "Picture only")).tag($0)
                }
            }
            .help("Choose output tracks")
        }
        if choices.modes.count > 1 {
            InspectorRow("Mode") {
                Picker("Mode", selection: Binding(get: { effectiveMode }, set: { choices.mode = $0 })) {
                    ForEach(choices.modes, id: \.self) { Text(choices.title(of: $0)).tag($0) }
                }
                .help(tracks == .audio ? "Choose sound export mode" : "Choose picture export mode")
            }
        }
        InspectorRow("Container") {
            Picker("Container", selection: $choices.container) {
                ForEach(choices.containers(), id: \.self) { Text(containerDisplayName($0)).tag($0) }
            }
            .help("Choose file format")
        }
        if choices.placements != .none && tracks != .audio {
            InspectorRow("Camera") {
                Toggle("Require Camera Video Copy", isOn: $choices.requireCameraCopy)
                    .help("Require stream copy for retained camera video")
            }
            InspectorRow("Stills") {
                Toggle("One frame per still", isOn: $choices.heldStills)
            }
        }
        if choices.participantAudio == nil && effectiveMode == .encode && tracks != .audio {
            InspectorRow("Video") {
                Picker("Video", selection: $choices.codec) {
                    ForEach(ReencodeCodec.allCases.filter { $0 != .jpeg }, id: \.self) { Text($0.displayName).tag($0) }
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
        if choices.participantAudio == nil && tracks != .video { audioDelivery }
        let sourceIssue = model.exportSourceIssue(tracks: tracks, wholeGroup: wholeGroup, mode: effectiveMode,
                                                  settings: choices.settings, selection: selectionRanges,
                                                  audioAction: choices.requestedAudioAction)
        if let sourceIssue {
            IssueLabel(sourceIssue)
        }
        HStack {
            Button("Check Export") { checkExport() }
                .help("Check export settings")
            Spacer()
            Button("Export…") {
                chooseDestination()
            }
                .buttonStyle(.borderedProminent)
                .help("Export multicam program")
        }
        .disabled(sourceIssue != nil || model.isBusy)
        .onChange(of: stillScope) { previous, scope in
            choices.placements = scope
            if scope != .none && previous == .none { choices.mode = .smart }
        }
        .onChange(of: choices) { _, _ in
            choices.settle()
            model.exportAlternatives = []
            model.stillExportBoundaryChoices = []
            pendingBoundary = nil
        }
        .onChange(of: project) { _, project in
            choices.participantAudio = project.participants.render?.audio.mode
            if choices.participantAudio != nil {
                if choices.tracks == .audio { choices.tracks = .all }
                choices.audioOutput = .separateTracks
            }
            model.stillExportBoundaryChoices = []
            pendingBoundary = nil
        }
        // An unavailable export offers what the export rules report for it, least destructive first.
        if !model.exportAlternatives.isEmpty {
            ExportOffersView(message: "This export is unavailable. These alternatives work.", alternatives: model.exportAlternatives) {
                choices.apply($0)
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
                    model.byHand { model.applyStillExportBoundary(pendingBoundary) }
                    self.pendingBoundary = nil
                }
                .help("Apply reviewed boundary")
            }
        }
        // An unsafe edge of an assembly range offers its verified times. Applying one moves that edge.
        if let suggestion = model.currentEdgeSuggestion {
            MulticamEdgeSuggestionsView(suggestion: suggestion, preview: { model.seekGroup($0) }) {
                let time = $0
                model.byHand { model.applyEdgeSuggestion(time) }
            }
        }

        Divider().padding(.vertical, 2)
        SectionHeading("Source Audio")
        Button("Replace Program Audio…", action: model.chooseReplacementAudio)
            .help("Replace program soundtrack")
            .disabled(!model.canReplaceSourceAudio)
    }

    private var effectiveMode: ExportMode { choices.effectiveMode }

    private var checkDestination: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("multicam-check-\(UUID()).\(container)")
    }

    private var audioDelivery: some View {
        Group {
            InspectorRow("Audio output") {
                Picker("Audio output", selection: $choices.audioOutput) {
                    ForEach(MulticamAudioOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help(MulticamAudioOutput.playbackHelp)
                .disabled(choices.audio == .removeAudio)
            }
            InspectorRow("Audio action") {
                Picker("Audio action", selection: $choices.audio) {
                    ForEach(choices.deliveryActions, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Choose audio treatment independently of picture")
            }
            if project.audio == .mix && choices.audio != .removeAudio {
                Text(MulticamAudioOutput.playbackHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func checkExport() {
        model.export(output: checkDestination, mode: effectiveMode, tracks: tracks, dryRun: true, wholeGroup: wholeGroup,
                     settings: choices.settings, selection: selectionRanges,
                     requireCameraCopy: choices.placements != .none && choices.requireCameraCopy,
                     audioOutput: choices.audioOutput, audioAction: choices.requestedAudioAction, pictureTiming: choices.pictureTiming)
    }

    private func chooseDestination() {
        let requested = review
        model.export(output: checkDestination, mode: effectiveMode, tracks: tracks, dryRun: true,
                     wholeGroup: wholeGroup, settings: choices.settings, selection: selectionRanges,
                     requireCameraCopy: choices.placements != .none && choices.requireCameraCopy,
                     audioOutput: choices.audioOutput, audioAction: choices.requestedAudioAction, pictureTiming: choices.pictureTiming,
                     reviewed: { summary in
            guard requested == review, requested.project == model.project else { return }
            presentDestination(requested, summary: summary)
        })
    }

    private func presentDestination(_ request: Review, summary: String) {
        let chosen = request.choices
        let panel = NSSavePanel()
        panel.title = "Export Multicam"
        panel.allowedContentTypes = [UTType(filenameExtension: chosen.container) ?? .data]
        panel.nameFieldStringValue = "Multicam.\(chosen.container)"
        let saveResult = ExportResultFile.checkbox()
        panel.accessoryView = multicamDeliveryAccessory(summary, additionalControl: saveResult)
        ProjectPanels.present(panel, in: model.window) { [weak model] accepted in
            guard accepted, let output = panel.url, let model, model.project == request.project else { return }
            model.export(output: output, mode: chosen.effectiveMode, tracks: chosen.tracks, dryRun: false,
                         wholeGroup: request.wholeGroup, settings: chosen.settings, selection: request.selection,
                         requireCameraCopy: chosen.placements != .none && chosen.requireCameraCopy,
                         saveResult: saveResult.state == .on, audioOutput: chosen.audioOutput, audioAction: chosen.requestedAudioAction,
                         pictureTiming: chosen.pictureTiming)
        }
    }

}

