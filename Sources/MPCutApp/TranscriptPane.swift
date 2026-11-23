import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import MPCutCore

private struct TranscriptSessionKey: EnvironmentKey {
    static let defaultValue: ProjectSession? = nil
}

extension EnvironmentValues {
    var transcriptSession: ProjectSession? {
        get { self[TranscriptSessionKey.self] }
        set { self[TranscriptSessionKey.self] = newValue }
    }
}

private let transcriptPageSize = 160

/// Counts reader work so tests can hold the pane to its budget while the playhead moves.
@MainActor
enum TranscriptPaneProbe {
    static var initializations = 0
    static var bodyEvaluations = 0
    static var wordEvaluations = 0
    static var page = ""
}

@MainActor
private final class TranscriptPaneObservation: ObservableObject {
    private struct Key: Equatable {
        let generation: UUID
        let mode: UUID
        let revision: Int
        let transcriptRevision: UInt64
        let mediaRevision: UInt64?
        let assemblyPreview: Bool
        let document: URL?
    }

    private var changes: AnyCancellable?

    init(session: ProjectSession) {
        changes = Publishers.Merge3(session.editor.objectWillChange, session.multicam.objectWillChange, session.objectWillChange)
            .receive(on: DispatchQueue.main)
            .map { [weak session] _ -> Key? in
                guard let session else { return nil }
                let multicam = session.isMulticam
                return Key(generation: multicam ? session.multicam.mcpGeneration : session.editor.mcpGeneration,
                           mode: session.mcpModeGeneration, revision: session.mcpRevision,
                           transcriptRevision: session.transcript.state.revision,
                           mediaRevision: multicam ? session.multicam.transcriptMediaRevision : nil,
                           assemblyPreview: multicam && session.multicam.assemblyPreview,
                           document: multicam ? session.multicam.projectURL : session.editor.projectURL)
            }
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

@MainActor
private final class TranscriptReaderGeometry {
    var wordFrames: [String: CGRect] = [:]
    var viewportHeight: CGFloat = 0
    var lastFollowedParagraph: Int?
    var keepsScrollPosition = false
    var revealsAtTop = false
    var followedTime: RationalTime?
}

private struct TranscriptTimeSelection {
    let first: TranscriptOccurrence
    let last: TranscriptOccurrence
}

@MainActor
struct TranscriptPane: View {
    let session: ProjectSession
    @AppStorage("transcript_suggested_angles") private var suggestedAnglesData = Data()
    @ObservedObject private var basket: TranscriptPaneBasket
    @ObservedObject private var controller: LiveTranscriptController
    @StateObject private var modelObservation: TranscriptPaneObservation
    private var editor: EditorModel { session.editor }
    private var multicam: MulticamEditorModel { session.multicam }
    @State private var index: TranscriptIndex?
    @State private var document: TranscriptDocument?
    @State private var attachmentID: String?
    @State private var pendingParticipantBinding: ParticipantSpeakerBinding?
    @State private var space = TranscriptSpace.currentCut
    @State private var searchText = ""
    @State private var query = ""
    @State private var speakerID: String?
    @State private var laneID: String?
    @State private var trackID: String?
    @State private var sourceID: String?
    @State private var file: String?
    @State private var clipID: String?
    @State private var assemblyIndex: Int?
    @State private var includeInferred = false
    @State private var filteredWords: TranscriptPaneWordList?
    @State private var offset = 0
    @State private var topRequest = 0
    @State private var pendingSheet: TranscriptPaneSheet?
    @State private var pendingSelection: (TranscriptSpace, TranscriptTimeSelection)?
    @State private var revealWordID: String?
    @State private var total = 0
    @State private var words: [TranscriptOccurrence] = []
    @State private var paragraphs: [[TranscriptOccurrence]] = []
    @State private var paragraphForWord: [String: Int] = [:]
    @State private var readerGeometry = TranscriptReaderGeometry()
    @State private var matches: [TranscriptMatch] = []
    @State private var matchNumber: Int?
    @State private var selectionStart: TranscriptOccurrence?
    @State private var selectionEnd: TranscriptOccurrence?
    @State private var activeWordID: String?
    @State private var followPlayback = true
    @State private var dragging = false
    @State private var alert: String?
    @State private var sheet: TranscriptPaneSheet?
    @State private var detail: String?
    @State private var needsReconciliation = false
    @State private var status: String?
    @State private var loadingIndex = false
    @State private var loadedRevision: Revision?
    @State private var loadTask: Task<Void, Never>?
    @State private var indexGeneration = 0
    @State private var restoring: TranscriptReaderPlace?
    @State private var queuedChoice: (word: TranscriptOccurrence, extending: Bool, seek: Bool)?
    @State private var searchTask: Task<Void, Never>?
    @State private var preparedSearch: PreparedSearch?
    @State private var importTask: Task<Void, Never>?
    @State private var contextPlayback: AnyCancellable?
    @FocusState private var searchFocused: Bool
    @FocusState private var dialogueFocused: Bool

    init(session: ProjectSession) {
        TranscriptPaneProbe.initializations += 1
        self.session = session
        _basket = ObservedObject(wrappedValue: session.transcriptBasket)
        _controller = ObservedObject(wrappedValue: session.transcript)
        _modelObservation = StateObject(wrappedValue: TranscriptPaneObservation(session: session))
        // A pane that was hidden opens where it was left.
        if let place = session.transcriptPaneMemory.place, place.owner == session.mcpHandle {
            _attachmentID = State(initialValue: place.selectedAttachmentID)
            _space = State(initialValue: place.scope.space)
            _speakerID = State(initialValue: place.scope.speaker)
            _laneID = State(initialValue: place.scope.lane)
            _sourceID = State(initialValue: place.scope.source)
            _file = State(initialValue: place.scope.file)
            _trackID = State(initialValue: place.scope.track)
            _assemblyIndex = State(initialValue: place.scope.assembly)
            _clipID = State(initialValue: place.scope.clip)
            _includeInferred = State(initialValue: place.scope.inferred)
            _searchText = State(initialValue: place.searchText)
            _query = State(initialValue: place.query)
            _followPlayback = State(initialValue: place.followPlayback)
            _restoring = State(initialValue: place)
        }
    }

    private var isMulticam: Bool { session.isMulticam }
    private var filter: TranscriptFilter {
        TranscriptFilter(speakerID: speakerID, sourceID: sourceID, trackID: trackID,
                         assemblyIndex: assemblyIndex, clipID: clipID, file: file, includeInferred: includeInferred, laneID: laneID)
    }

    private struct Revision: Equatable {
        let timeline: Int
        let transcript: UInt64
        let media: UInt64?
        let attachment: String?
        let resultID: String?
        let projectURL: URL?
        let owner: String
    }

    private struct PreparedSearch {
        let query: String
        let scope: BrowseScope
        let indexGeneration: Int
        let result: TranscriptIndex.PreparedSearch
    }

    private var revision: Revision {
        Revision(timeline: controller.timelineRevision, transcript: controller.state.revision,
                 media: isMulticam ? multicam.transcriptMediaRevision : nil,
                 attachment: selectedAttachment?.id, resultID: selectedAttachment?.resultID,
                 projectURL: isMulticam ? multicam.projectURL : editor.projectURL, owner: session.mcpHandle)
    }

    private var readerReady: Bool { !loadingIndex && loadedRevision == revision }

    /// The reader keeps showing the revision it has while an edit to the same result is
    /// indexed. Dimming it for every trim makes the pane flash. Its words stay unusable
    /// for seeking and editing until the new revision replaces them.
    private var readerVisible: Bool { readerReady || (loadingIndex && index != nil) }

    private var hasFilter: Bool {
        laneID != nil || speakerID != nil || sourceID != nil || file != nil || trackID != nil || assemblyIndex != nil || clipID != nil
    }

    struct BrowseScope: Equatable {
        let space: TranscriptSpace
        let speaker: String?
        let source: String?
        let file: String?
        let track: String?
        let assembly: Int?
        let clip: String?
        let inferred: Bool
        var lane: String? = nil
    }

    private var browseScope: BrowseScope {
        BrowseScope(space: space, speaker: speakerID, source: sourceID, file: file,
                    track: trackID, assembly: assemblyIndex, clip: clipID, inferred: includeInferred, lane: laneID)
    }

    var body: some View {
        let _ = TranscriptPaneProbe.bodyEvaluations += 1
        let _ = TranscriptPaneProbe.page = pageLabel
        VStack(spacing: 0) {
            header
            if let detail {
                Label(detail, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if needsReconciliation, let attachment = selectedAttachment, attachment.fingerprint != nil {
                HStack {
                    Spacer()
                    Button("Reconcile Transcript") { reconcileTranscript(attachment.id) }
                        .controlSize(.small)
                        .accessibilityIdentifier("transcript.reconcile")
                        .disabled(controller.activeJobID != nil || loadingIndex)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            jobStatus
            if index == nil, loadingIndex || importTask != nil {
                ProgressView(loadingIndex ? "Opening transcript…" : "Reading transcript…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if index == nil, controller.activeJobID != nil {
                activeTrackList
            } else if index == nil {
                emptyState
            } else {
                controls.disabled(!readerVisible)
                Divider()
                transcriptBody.disabled(!readerVisible)
                Divider()
                footer.disabled(!readerVisible)
            }
        }
        .background(.background)
        .onChange(of: session.mcpHandle, initial: true) { previous, owner in
            basket.bind(to: owner)
            if previous != owner { pendingSelection = nil }
        }
        .onChange(of: revision, initial: true) { previous, next in
            if previous != next {
                stopContextPlayback()
                controller.closeSourceAudition()
            }
            if previous.attachment != next.attachment {
                speakerID = pendingParticipantBinding?.attachmentID == next.attachment ? pendingParticipantBinding?.speakerID : nil
                pendingParticipantBinding = nil
                laneID = nil
                trackID = nil
                sourceID = nil
                file = nil
                clipID = nil
                assemblyIndex = nil
            }
            reload()
        }
        .onChange(of: multicam.project?.mixLanes.map(\.id)) { _, lanes in
            if let laneID, lanes?.contains(laneID) != true { self.laneID = nil }
        }
        .onChange(of: browseScope, initial: false) { previous, next in
            if previous.space != next.space, next.space != .currentCut, assemblyIndex != nil || clipID != nil {
                assemblyIndex = nil
                clipID = nil
                return
            }
            refresh(reset: true)
            followPlayhead(turningPages: false)
            if let pending = pendingSelection, pending.0 == next.space, pending.1.first.attachmentID == index?.attachment?.id, !hasFilter {
                pendingSelection = nil
                reveal(pending.1, in: next.space)
            }
        }
        .onReceive(editor.$playhead) { seconds in
            if !isMulticam, let time = timelineRationalTime(seconds) { follow(time) }
        }
        .onReceive(multicam.preview.$time) { output in
            if isMulticam { followMulticam(output) }
        }
        .onChange(of: multicam.assemblyPreview) { _, _ in
            if isMulticam { followPlayhead(turningPages: false) }
        }
        .onDisappear {
            session.transcriptPaneMemory.place = restoring ?? place()
            stopContextPlayback()
            controller.closeSourceAudition()
            loadTask?.cancel()
            searchTask?.cancel()
            searchTask = nil
            importTask?.cancel()
            importTask = nil
            session.presentation.transcriptKeyHandler = nil
        }
        .onAppear {
            if let binding = session.presentation.participantTranscriptFilter {
                restoring = nil
                if selectedAttachment?.id != binding.attachmentID {
                    pendingParticipantBinding = binding
                    attachmentID = binding.attachmentID
                }
                speakerID = binding.speakerID
                sourceID = nil
                file = nil
                laneID = nil
                trackID = nil
                clipID = nil
                assemblyIndex = nil
                query = ""
                searchText = ""
                session.presentation.participantTranscriptFilter = nil
            }
            session.presentation.transcriptKeyHandler = handleKey
        }
        .alert("Transcript", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") { alert = nil }
        } message: {
            Text(alert ?? "")
        }
        .sheet(item: $sheet, onDismiss: {
            stopContextPlayback()
            controller.closeSourceAudition()
            if let pending = pendingSheet {
                pendingSheet = nil
                sheet = pending
            }
        }) { sheet in
            TranscriptPaneSheetView(sheet: sheet, dismiss: {
                stopContextPlayback()
                controller.closeSourceAudition()
                pendingSheet = nil
                self.sheet = nil
            })
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Transcript").font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 2)
            if controller.state.attachments.count > 1 {
                Picker("Transcript attachment", selection: Binding(
                    get: { selectedAttachment?.id }, set: { attachmentID = $0 }
                )) {
                    ForEach(controller.state.attachments, id: \.id) { attachment in
                        Text(attachmentLabel(attachment)).tag(Optional(attachment.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                .accessibilityIdentifier("transcript.attachment")
            }
            if !isMulticam { PanelDockToggle() }
            PaneIconButton(title: "Import Transcript…", symbol: "square.and.arrow.down",
                           help: "Import Transcriberrr JSON, SubRip, or WebVTT", action: chooseImport)
                .accessibilityIdentifier("transcript.import")
            Menu {
                Button("Transcribe with Transcriberrr…", action: showSetup)
                Button("Import Transcript…", action: chooseImport)
                Button("Transcription Jobs…", action: showJobs)
                if !basket.items.isEmpty { Button("Ordered Selects…", action: showOrderedSelects) }
                if !controller.state.authoring.isEmpty { Button("Named Selects and Corrections…", action: showAuthored) }
                if selectedAttachment != nil {
                    Divider()
                    if document != nil {
                        Button("Inspect Attachment…", action: showAttachment)
                        Button("Rebind Transcript…", action: showRebind)
                    } else {
                        Button("Recover Transcript Store…", action: locateTranscriptStore)
                    }
                    Button("Export Transcript…", action: showExport)
                    Button("Detach Transcript", role: .destructive, action: confirmDetach)
                }
            } label: {
                PaneMenuIcon(symbol: "ellipsis.circle")
                    .accessibilityLabel("Transcript Options")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Transcript Options")
            .help("Transcript options")
        }
        .padding(.leading, EditorMetrics.paneInset).padding(.trailing, EditorMetrics.paneInset - 6)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        // The same centred invitation as the empty project window.
        ContentUnavailableView {
            Label(selectedAttachment == nil ? "Create a transcript" : "Transcript unavailable",
                  systemImage: selectedAttachment == nil ? "text.quote" : "exclamationmark.triangle")
        } description: {
            Text(selectedAttachment == nil ? "Transcribe the project audio or import an existing transcript."
                 : "The transcript store for this attachment could not be read.")
        } actions: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { emptyStateActions }
                VStack(spacing: 8) { emptyStateActions }.fixedSize()
            }
        }
        .padding(EditorMetrics.paneInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var emptyStateActions: some View {
        if selectedAttachment == nil {
            Button("Transcribe Audio…", action: showSetup)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("transcript.transcribe")
        } else {
            Button("Recover Transcript Store…", action: locateTranscriptStore)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("transcript.recoverStore")
        }
        Button("Import Transcript…", action: chooseImport)
        if selectedAttachment != nil {
            Button("Transcribe Audio…", action: showSetup)
                .accessibilityIdentifier("transcript.transcribe")
        }
    }

    private var activeTrackList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(controller.job?.sessions.flatMap(\.tracks).filter(\.recognize) ?? []) { track in
                    let name = HStack {
                        Text(track.name).font(.callout.weight(.medium))
                        if let lane = controller.project.transcriptLane(for: track) {
                            TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot)
                        }
                    }
                    let status = Text(track.message ?? trackStatus(track.state))
                        .font(.callout).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            name
                            Spacer(minLength: 0)
                            status
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            name.lineLimit(2).truncationMode(.middle)
                            status.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .help(track.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func trackStatus(_ state: TranscriptJobTrackState) -> String {
        switch state {
        case .pending: "Waiting for audio"
        case .staged: "Audio ready"
        case .cached: "Using saved transcript"
        case .recognized: "Complete"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .coverageOnly: "Camera coverage only"
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Transcript clock", selection: $space) {
                Text("Source").tag(TranscriptSpace.source)
                if isMulticam { Text("Group").tag(TranscriptSpace.group) }
                Text("Current Cut").tag(TranscriptSpace.currentCut)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("transcript.space")
            HStack(spacing: 7) {
                iconButton("Find dialogue", symbol: "magnifyingglass", action: runSearch)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcript.search.submit")
                    .help("Find dialogue")
                TextField("Find dialogue", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("transcript.search")
                    .onSubmit { runSearch() }
                if !searchText.isEmpty {
                    iconButton("Clear search", symbol: "xmark.circle.fill") {
                        searchText = ""
                        runSearch()
                    }
                }
                Menu {
                    if let document {
                        Picker("Speaker", selection: $speakerID) {
                            Text("All Speakers").tag(nil as String?)
                            ForEach(index?.speakers ?? document.speakers, id: \.id) { speaker in
                                Text(speakerName(speaker.id)).tag(Optional(speaker.id))
                            }
                        }
                        if let lanes = multicam.project?.mixLanes, isMulticam, !lanes.isEmpty {
                            Picker("Lane", selection: $laneID) {
                                Text("All Lanes").tag(nil as String?)
                                ForEach(lanes, id: \.id) { lane in
                                    TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot).tag(Optional(lane.id))
                                }
                            }
                        }
                        if isMulticam {
                            Picker("Source", selection: $sourceID) {
                                Text("All Sources").tag(nil as String?)
                                ForEach(Array(Set((selectedAttachment?.bindings ?? []).compactMap(\.sourceID))).sorted(), id: \.self) { source in
                                    Text(displaySource(source)).tag(Optional(source))
                                }
                            }
                        } else {
                            Picker("Source", selection: $file) {
                                Text("All Sources").tag(nil as String?)
                                ForEach(Array(Set((selectedAttachment?.bindings ?? []).compactMap(\.file))).sorted(), id: \.self) { source in
                                    Text(displaySource(source)).tag(Optional(source))
                                }
                            }
                        }
                        Picker("Track", selection: $trackID) {
                            Text("All Tracks").tag(nil as String?)
                            ForEach(document.tracks, id: \.id) { track in
                                HStack {
                                    Text(trackLabel(track))
                                    if let lane = controller.project.transcriptLane(for: track, attachment: selectedAttachment) {
                                        TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot)
                                    }
                                }
                                .tag(Optional(track.id))
                            }
                        }
                        if isMulticam && space == .currentCut {
                            Picker("Occurrence", selection: $assemblyIndex) {
                                Text("All Occurrences").tag(nil as Int?)
                                ForEach(multicam.assemblyItems.indices, id: \.self) { index in
                                    Text("Occurrence \(index + 1)").tag(Optional(index))
                                }
                            }
                        }
                        if !isMulticam && space == .currentCut {
                            Picker("Occurrence", selection: $clipID) {
                                Text("All Occurrences").tag(nil as String?)
                                ForEach(Array(editor.sequenceClips.enumerated()), id: \.element.id) { entry in
                                    Text("Clip \(entry.offset + 1) · \(displaySource(entry.element.file))").tag(Optional(entry.element.id))
                                }
                            }
                        }
                        Toggle("Include Inferred Track Matches", isOn: $includeInferred)
                            .disabled(trackID == nil)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .symbolVariant(hasFilter ? .fill : .none)
                        .accessibilityLabel("Filter Transcript")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Filter Transcript")
                .accessibilityIdentifier("transcript.filter")
                .help(hasFilter ? "Filter transcript (active)" : "Filter transcript")
            }
            .padding(.horizontal, 8).frame(minHeight: 30)
            .background(.quaternary.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous))
        }
        .padding(.horizontal, EditorMetrics.paneInset).padding(.bottom, 10)
    }

    private var transcriptBody: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if (searchTask != nil || (loadingIndex && !query.isEmpty)) && matches.isEmpty {
                        ProgressView("Finding dialogue…").controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else if total == 0 {
                        emptyDialogue
                    } else if query.isEmpty {
                        // A row is its place on the page. An edit gives every word a new
                        // occurrence ID, and rows named by one would all be torn down and the
                        // scroll position lost.
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { entry in
                            if let first = entry.element.first {
                                passage(entry.element, header: first)
                                    .id(TranscriptScrollTarget.paragraph(entry.offset))
                            }
                        }
                    } else {
                        ForEach(Array(matches.enumerated()), id: \.offset) { entry in
                            if let first = entry.element.words.first {
                                VStack(alignment: .leading, spacing: 5) {
                                    passage(entry.element.words, header: first, primary: .accentColor)
                                    let context = contextText(entry.element)
                                    if !context.isEmpty {
                                        Text(context)
                                            .font(.callout).foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                                .id(TranscriptScrollTarget.match(offset + entry.offset))
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                readerGeometry.viewportHeight = height
            }
            .onChange(of: topRequest) { _, _ in
                readerGeometry.lastFollowedParagraph = nil
                if !paragraphs.isEmpty {
                    scroll.scrollTo(TranscriptScrollTarget.paragraph(0), anchor: .top)
                } else if !matches.isEmpty {
                    scroll.scrollTo(TranscriptScrollTarget.match(offset), anchor: .top)
                }
            }
            .onChange(of: activeWordID) { _, id in
                if readerGeometry.keepsScrollPosition {
                    readerGeometry.keepsScrollPosition = false
                    return
                }
                guard followPlayback, query.isEmpty, let id, let paragraph = paragraphForWord[id] else { return }
                let height = readerGeometry.viewportHeight
                if let frame = readerGeometry.wordFrames[id], height > 0 {
                    guard frame.minY < 0 || frame.maxY > height else {
                        readerGeometry.lastFollowedParagraph = nil
                        return
                    }
                } else if readerGeometry.lastFollowedParagraph == paragraph {
                    return
                }
                readerGeometry.lastFollowedParagraph = paragraph
                scroll.scrollTo(TranscriptScrollTarget.paragraph(paragraph), anchor: .center)
            }
            .onChange(of: revealWordID) { _, id in
                guard let id, let paragraph = paragraphForWord[id] else { return }
                scroll.scrollTo(TranscriptScrollTarget.paragraph(paragraph), anchor: readerGeometry.revealsAtTop ? .top : .center)
                readerGeometry.revealsAtTop = false
                revealWordID = nil
            }
            .onChange(of: matchNumber) { _, position in
                if let position { scroll.scrollTo(TranscriptScrollTarget.match(position), anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity)
        .focusable(true, interactions: .edit)
        .focused($dialogueFocused)
        .accessibilityIdentifier("transcript.dialogue")
        .coordinateSpace(name: "transcript.words")
        .onPreferenceChange(TranscriptWordFrames.self) { readerGeometry.wordFrames = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("transcript.words"))
                .onChanged { gesture in
                    guard readerReady, abs(gesture.translation.width) >= abs(gesture.translation.height) || dragging,
                          let start = wordAt(gesture.startLocation), let end = wordAt(gesture.location) else { return }
                    if !dragging {
                        selectionStart = start
                        selectionEnd = start
                    }
                    dragging = true
                    dialogueFocused = true
                    if space != .source || start.trackID == end.trackID {
                        selectionEnd = end
                    }
                }
                .onEnded { _ in dragging = false }
        )
    }

    private var emptyDialogue: some View {
        let audioTracks = document?.tracks.filter { $0.coverage != .coverageOnly }.count ?? 0
        let needsBinding = (selectedAttachment?.bindings.count ?? 0) < audioTracks
            || index?.gaps.contains(where: { $0.reason == .changed || $0.reason == .unbound }) == true
        return VStack(spacing: 10) {
            Text(query.isEmpty ? "No Dialogue in This View" : "No Matches")
                .font(.headline)
            if query.isEmpty && needsBinding {
                Text("Choose an audio stream for the unbound transcript tracks.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { emptyDialogueActions(needsBinding: needsBinding) }
                VStack(spacing: 8) { emptyDialogueActions(needsBinding: needsBinding) }.fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    @ViewBuilder private func emptyDialogueActions(needsBinding: Bool) -> some View {
        if query.isEmpty && needsBinding {
            Button("Rebind Transcript…", action: showRebind)
                .accessibilityIdentifier("transcript.rebind")
        }
        if query.isEmpty && space != .source {
            Button("Show Source Dialogue") { space = .source }
        }
    }

    private func wordAt(_ location: CGPoint) -> TranscriptOccurrence? {
        guard let id = readerGeometry.wordFrames.first(where: { $0.value.contains(location) })?.key else { return nil }
        return index?.occurrence(id: id, space: space)
    }

    private func passage(_ words: [TranscriptOccurrence], header: TranscriptOccurrence, primary: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(timelineTime(header.range.from.seconds, milliseconds: true))
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel("At \(timelineTime(header.range.from.seconds, milliseconds: true))")
                Text(speakerName(header.speakerID)).font(.caption.weight(.semibold))
                if let laneLabel = header.laneLabel, let slot = header.laneColorSlot {
                    TranscriptLaneChip(label: laneLabel, colorSlot: slot)
                    if let laneID, laneID != header.laneID, header.heardOnLaneIDs?.contains(laneID) == true,
                       let lane = multicam.project?.mixLanes.first(where: { $0.id == laneID }) {
                        TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot)
                            .help("Also heard on \(lane.label)")
                    }
                } else if let track = header.trackID, (document?.tracks.count ?? 0) > 1, let detail = document?.tracks.first(where: { $0.id == track }) {
                    Text(trackLabel(detail)).font(.caption).lineLimit(1)
                }
                Spacer(minLength: 0)
                if words.contains(where: \.staleMatches) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .accessibilityLabel("Cross-track alignment is out of date")
                        .help("Cross-track alignment is out of date")
                }
                if let occurrence = header.assemblyIndex, hasMultipleOccurrences {
                    Text("Take \(occurrence + 1)").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            let chosen = selectedPositions
            TranscriptWordFlow {
                ForEach(Array(words.enumerated()), id: \.offset) { entry in
                    let word = entry.element
                    TranscriptWordView(word: word, selected: isSelected(word, within: chosen),
                                       active: activeWordID == word.id, accented: primary == .accentColor,
                                       generation: indexGeneration, describe: wordDescription,
                                       press: { word, extending in
                        guard !dragging else { return }
                        dialogueFocused = true
                        choose(word, extending: extending)
                    }, choose: { choose($0, extending: $1, seek: $2) }, inspect: showEvidence)
                    .equatable()
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                iconButton(query.isEmpty ? "Previous page" : "Previous match", symbol: "chevron.left") {
                    move(-1)
                }
                .accessibilityIdentifier("transcript.previousMatch")
                .disabled(searchTask != nil || total == 0 || (query.isEmpty && offset == 0))
                Text(pageLabel)
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("transcript.results")
                iconButton(query.isEmpty ? "Next page" : "Next match", symbol: "chevron.right") {
                    move(1)
                }
                .accessibilityIdentifier("transcript.nextMatch")
                .disabled(searchTask != nil || total == 0 || (query.isEmpty && offset + transcriptPageSize >= total))
                Spacer(minLength: 0)
                if let index {
                    let count = laneID.map { selected in index.gaps.lazy.filter { $0.laneID == selected }.count } ?? index.gaps.count
                    if space != .currentCut || count > 0 {
                        let title = space == .currentCut ? "Coverage gaps (\(count))" : "Transcript coverage"
                        iconButton(title, symbol: "waveform.badge.exclamationmark", action: showGaps)
                            .accessibilityIdentifier("transcript.gaps")
                    }
                }
                PaneIconButton(title: "Follow Playback", symbol: followPlayback ? "scope" : "location.slash",
                               active: followPlayback, help: "Follow the active word as the playhead moves") {
                    followPlayback.toggle()
                    if followPlayback { followPlayhead(turningPages: false) }
                    else { activeWordID = nil }
                }
                .accessibilityValue(followPlayback ? "On" : "Off")
            }
            actionsBar
            if let status = importTask == nil ? status : "Reading transcript…" {
                Text(status)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, EditorMetrics.paneInset - 6).padding(.vertical, 8)
        .background(.bar)
    }

    private var pageLabel: String {
        if !query.isEmpty {
            if let matchNumber { return "Match \(matchNumber + 1) of \(total)" }
            return total == 1 ? "1 match" : "\(total) matches"
        }
        return total == 0 ? "0 words" : "\(offset + 1)–\(min(offset + transcriptPageSize, total)) of \(total)"
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        PaneIconButton(title: title, symbol: symbol, action: action)
    }

    private func reload() {
        let reopened = restoring != nil
        let previous = restoring ?? place()
        loadTask?.cancel()
        searchTask?.cancel()
        searchTask = nil
        preparedSearch = nil
        loadingIndex = false
        if let attachmentID, !controller.state.attachments.contains(where: { $0.id == attachmentID }) {
            self.attachmentID = nil
        }
        if index?.attachment?.id != selectedAttachment?.id || controller.state.attachments.isEmpty {
            activeWordID = nil
            detail = nil
            needsReconciliation = false
        }
        if index?.attachment?.id != selectedAttachment?.id {
            loadedRevision = nil
            index = nil
            document = nil
            refresh(reset: true)
        }
        guard !controller.state.attachments.isEmpty else {
            restoring = nil
            loadedRevision = nil
            index = nil
            document = nil
            refresh(reset: true)
            return
        }
        let requested = revision
        let attachmentID = attachmentID
        if let built = controller.cachedIndex(attachmentID: attachmentID) {
            show(built, for: requested, returningTo: previous, reopened: reopened)
            return
        }
        loadingIndex = true
        loadTask = Task { @MainActor in
            do {
                let result = try await controller.indexedTranscript(attachmentID: attachmentID)
                guard !Task.isCancelled, requested == revision else { return }
                show(result, for: requested, returningTo: previous, reopened: reopened)
            } catch {
                guard !Task.isCancelled, requested == revision else { return }
                index = nil
                document = nil
                loadedRevision = nil
                queuedChoice = nil
                needsReconciliation = false
                refresh(reset: true)
                loadingIndex = false
                detail = error.localizedDescription
            }
        }
    }

    private func show(_ result: TranscriptIndex, for requested: Revision, returningTo previous: TranscriptReaderPlace,
                      reopened: Bool) {
        restoring = nil
        let earlier = index
        document = result.document
        index = result
        indexGeneration &+= 1
        loadedRevision = requested
        needsReconciliation = false
        if result.attachment?.fingerprint != nil, isMulticam {
            needsReconciliation = result.read(space: .source, limit: 1).items.first?.staleMatches == true
                || result.read(space: .group, limit: 1).items.first?.staleMatches == true
        }
        if needsReconciliation {
            detail = "Cross-track alignment is out of date."
        } else if result.document.approximateClock, result.attachment?.importOrigin == nil {
            detail = "Approximate clock. Review binding before editing."
        } else {
            detail = nil
        }
        loadingIndex = false
        if previous.owner == requested.owner, previous.attachmentID == requested.attachment,
           previous.resultID == requested.resultID, previous.scope == browseScope {
            restore(previous, in: result, after: earlier, reopened: reopened)
        } else {
            refresh(reset: true)
        }
        // The playhead has not moved, so nothing else marks the word under it again.
        // Marking it must not scroll a reader who is looking elsewhere on the page.
        let marked = activeWordID
        followPlayhead(turningPages: false)
        if activeWordID != marked { readerGeometry.keepsScrollPosition = true }
        if let pending = pendingSelection, pending.1.first.attachmentID == result.attachment?.id {
            pendingSelection = nil
            reveal(pending.1, in: pending.0)
        }
        if let queued = queuedChoice {
            queuedChoice = nil
            if let word = result.revalidatedPaneWord(queued.word, in: space, after: earlier) {
                choose(word, extending: queued.extending, seek: queued.seek)
            }
        }
    }

    /// What the reader shows now, described by words that a later index can find again.
    private func place() -> TranscriptReaderPlace {
        // The first word in view marks the place. Before the reader has been laid out it is the page's first.
        let height = readerGeometry.viewportHeight
        let top = query.isEmpty ? words.firstIndex { word in
            readerGeometry.wordFrames[word.id].map { $0.maxY > 0 && $0.minY < height } ?? false
        } ?? (words.isEmpty ? nil : 0) : nil
        return TranscriptReaderPlace(owner: loadedRevision?.owner ?? session.mcpHandle, attachmentID: loadedRevision?.attachment,
                              resultID: loadedRevision?.resultID, selectedAttachmentID: attachmentID, scope: browseScope,
                              searchText: searchText, query: query, followPlayback: followPlayback,
                              anchor: top.map { words[$0] }, anchorIndex: top ?? 0, selectionStart: selectionStart,
                              selectionEnd: selectionEnd, matchNumber: matchNumber,
                              matchWord: matchNumber.flatMap { number in
                                  matches.indices.contains(number - offset) ? matches[number - offset].words.first : nil
                              })
    }

    /// Returns to the page, selection and match the reader showed before its index was replaced.
    private func restore(_ place: TranscriptReaderPlace, in result: TranscriptIndex, after earlier: TranscriptIndex?,
                         reopened: Bool) {
        searchTask?.cancel()
        searchTask = nil
        filteredWords = hasFilter && query.isEmpty ? TranscriptPaneWordList(result.readAll(space: space, filter: filter)) : nil
        guard place.query == query else { return refresh(reset: true) }
        guard query.isEmpty else {
            let number = place.matchNumber ?? 0
            searchPage(in: result, pageOffset: number / transcriptPageSize * transcriptPageSize,
                       revealMatch: number, seek: false, returningTo: place.matchWord, after: earlier)
            return
        }
        // A word names one occurrence. It is followed into a renamed clip only when the cut
        // held it once before the edit, so neither the selection nor the page moves to a replay.
        func found(_ word: TranscriptOccurrence?) -> TranscriptOccurrence? {
            word.flatMap { word in
                result.revalidatedPaneWord(word, in: space, after: earlier)
            }
        }
        let start = found(place.selectionStart)
        let end = found(place.selectionEnd)
        func position(of word: TranscriptOccurrence) -> Int? {
            filteredWords.map { $0.position(of: word.id) } ?? result.position(of: word.id, space: space)
        }
        // A word the edit removed has no successor. The word nearest its time takes its place.
        let kept = found(place.anchor).flatMap(position)
        let position = kept ?? place.anchor.flatMap { anchor in
            filteredWords.map { $0.nearestPosition(to: anchor.range.from) }
                ?? result.nearestPanePosition(to: anchor.range.from, in: space)
        }
        // The page starts as many words before that word as it did, so words keep their rows
        // when an edit earlier in the cut moves every position after it.
        let count = filteredWords?.words.count ?? result.read(space: space, limit: 1).total
        offset = max(0, min(count - 1, (position ?? place.anchorIndex) - place.anchorIndex))
        matchNumber = nil
        refresh(reset: false)
        selectionStart = end == nil ? nil : start
        selectionEnd = start == nil ? nil : end
        if reopened, words.indices.contains(place.anchorIndex) {
            readerGeometry.revealsAtTop = true
            revealWordID = words[place.anchorIndex].id
        }
    }

    private func refresh(reset: Bool) {
        searchTask?.cancel()
        searchTask = nil
        if reset {
            preparedSearch = nil
            offset = 0
            matchNumber = nil
            selectionStart = nil
            selectionEnd = nil
            activeWordID = nil
            topRequest += 1
            filteredWords = nil
        }
        guard let index else { words = []; paragraphs = []; paragraphForWord = [:]; matches = []; total = 0; return }
        if query.isEmpty {
            preparedSearch = nil
            if hasFilter, filteredWords == nil { filteredWords = TranscriptPaneWordList(index.readAll(space: space, filter: filter)) }
            if let filteredWords {
                total = filteredWords.words.count
                words = Array(filteredWords.words.dropFirst(offset).prefix(transcriptPageSize))
            } else {
                let page = index.read(space: space, offset: offset, limit: transcriptPageSize)
                total = page.total
                words = page.items
            }
            paragraphs = Self.paragraphs(words)
            var targets: [String: Int] = [:]
            for (ordinal, paragraph) in paragraphs.enumerated() {
                for word in paragraph { targets[word.id] = ordinal }
            }
            paragraphForWord = targets
            matches = []
        } else {
            total = 0
            words = []
            matches = []
            paragraphs = []
            paragraphForWord = [:]
            searchPage(in: index, pageOffset: offset, revealMatch: reset ? 0 : nil, seek: false)
        }
    }

    private func searchPage(in index: TranscriptIndex, pageOffset: Int, revealMatch: Int?, seek: Bool,
                            returningTo previous: TranscriptOccurrence? = nil, after earlier: TranscriptIndex? = nil) {
        guard readerReady else { return }
        searchTask?.cancel()
        let query = query
        let clock = space
        let filter = filter
        let scope = browseScope
        let expected = revision
        let generation = indexGeneration
        let cachedSearch = preparedSearch.flatMap { cached in
            cached.query == query && cached.scope == scope && cached.indexGeneration == generation ? cached.result : nil
        }
        searchTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) { () -> (TranscriptIndex.PreparedSearch, TranscriptPage<TranscriptMatch>)? in
                guard let search = cachedSearch ?? (try? index.prepareSearch(query, space: clock, filter: filter)),
                      !Task.isCancelled else { return nil }
                return (search, search.page(offset: pageOffset, limit: transcriptPageSize))
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            searchTask = nil
            guard let (search, page) = result, readerReady, expected == revision,
                  query == self.query, scope == browseScope, generation == indexGeneration else { return }
            if cachedSearch == nil {
                preparedSearch = PreparedSearch(query: query, scope: scope, indexGeneration: generation, result: search)
            }
            if page.total > 0, pageOffset >= page.total {
                let last = page.total - 1
                searchPage(in: index, pageOffset: last / transcriptPageSize * transcriptPageSize,
                           revealMatch: last, seek: seek, returningTo: previous, after: earlier)
                return
            }
            offset = pageOffset
            total = page.total
            matches = page.items
            var seen = Set<String>()
            words = matches.flatMap(\.words).filter { seen.insert($0.id).inserted }
            if total == 0 {
                matchNumber = nil
                selectionStart = nil
                selectionEnd = nil
            } else if let previous, !matches.isEmpty {
                // The match the reader was on, found again by its word or else by its time.
                let same = index.revalidatedPaneWord(previous, in: clock, after: earlier)
                let starts = page.items.map { $0.words.first }
                let distances = starts.map { abs(($0?.range.from.seconds ?? .infinity) - previous.range.from.seconds) }
                let nearest = same.flatMap { word in starts.firstIndex { $0?.id == word.id } }
                    ?? distances.indices.min { distances[$0] < distances[$1] }
                showMatch(pageOffset + (nearest ?? 0), seek: false)
            } else if let revealMatch, total > 0 {
                showMatch(min(revealMatch, total - 1), seek: seek)
            }
        }
    }

    private static func paragraphs(_ words: [TranscriptOccurrence]) -> [[TranscriptOccurrence]] {
        var paragraphs: [[TranscriptOccurrence]] = []
        for word in words {
            if let previous = paragraphs.last?.last, let count = paragraphs.last?.count,
               count < 28, previous.laneID == word.laneID, previous.speakerID == word.speakerID, previous.trackID == word.trackID,
               previous.assemblyIndex == word.assemblyIndex, previous.clipID == word.clipID,
               word.range.from.seconds - previous.range.to.seconds < 2 {
                paragraphs[paragraphs.count - 1].append(word)
            } else {
                paragraphs.append([word])
            }
        }
        return paragraphs
    }

    private func runSearch() {
        query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        refresh(reset: true)
    }

    private func move(_ direction: Int) {
        if query.isEmpty {
            // A page that an edit has moved off a multiple of the page size still turns by whole pages.
            let turned = offset + direction * transcriptPageSize
            offset = direction > 0 ? (turned < total ? turned : offset) : max(0, turned)
            refresh(reset: false)
            topRequest += 1
        } else if total > 0 {
            showMatch(((matchNumber ?? (direction < 0 ? 0 : -1)) + direction + total) % total)
        }
    }

    private func showMatch(_ number: Int, seek: Bool = true) {
        if !(offset..<offset + matches.count).contains(number) {
            guard let index else { return }
            searchPage(in: index, pageOffset: number / transcriptPageSize * transcriptPageSize, revealMatch: number, seek: seek)
            return
        }
        guard matches.indices.contains(number - offset),
              let first = matches[number - offset].words.first,
              let last = matches[number - offset].words.last else { return }
        matchNumber = number
        choose(first, extending: false, seek: seek)
        selectionEnd = last
    }

    private func choose(_ word: TranscriptOccurrence, extending: Bool, seek: Bool = true) {
        guard readerReady, word.timelineRevision == controller.timelineRevision else {
            // A click that lands while an edit is indexed chooses the same word once it is.
            if loadingIndex, index != nil { queuedChoice = (word, extending, seek) }
            return
        }
        if extending, let start = selectionStart {
            guard space != .source || start.trackID == word.trackID else { return }
        } else {
            selectionStart = word
        }
        selectionEnd = word
        if seek {
            stopContextPlayback()
            perform {
                try controller.seek(word, space: space, attachmentID: word.attachmentID)
                if let attachment = word.attachmentID ?? selectedAttachment?.id,
                   let speaker = word.speakerID ?? word.originalSpeakerID {
                    session.presentation.selectedTranscriptSpeaker = .init(
                        binding: .init(attachmentID: attachment, speakerID: speaker), time: session.participantTimelineTime)
                } else {
                    session.presentation.selectedTranscriptSpeaker = nil
                }
            }
        }
    }

    private func followMulticam(_ output: RationalTime, turningPages: Bool = true) {
        guard readerReady, followPlayback, query.isEmpty else { return }
        guard let position = MulticamTranscriptPlaybackPosition.resolve(
            output: output, readerSpace: space, assemblyPreview: multicam.assemblyPreview,
            interval: multicam.interval(at: output), assemblyItems: multicam.assemblyItems,
            assemblyStart: multicam.assemblyStart(at:)
        ) else {
            readerGeometry.followedTime = nil
            if activeWordID != nil { activeWordID = nil }
            return
        }
        follow(position.time, playbackSpace: position.space, turningPages: turningPages)
    }

    private func followPlayhead(turningPages: Bool) {
        if isMulticam {
            followMulticam(multicam.preview.time, turningPages: turningPages)
        } else if let time = timelineRationalTime(editor.playhead) {
            follow(time, turningPages: turningPages)
        }
    }

    private func follow(_ time: RationalTime, playbackSpace: TranscriptSpace = .currentCut, turningPages: Bool = true) {
        guard readerReady, followPlayback, query.isEmpty, let index else { return }
        let scoped = filteredWords
        var position: Int?
        if space == .source {
            position = index.sourcePanePosition(at: time, playbackSpace: playbackSpace, scoped: scoped)
        } else {
            guard space == playbackSpace else { return }
            position = if let scoped { scoped.position(at: time) }
                else { index.position(at: time, space: space) }
        }
        // A publisher repeats its value to a pane that has just opened. Only a playhead that
        // has moved takes the reader to another page.
        let moved = readerGeometry.followedTime != time
        readerGeometry.followedTime = time
        if turningPages, moved, let position, !(offset..<offset + words.count).contains(position) {
            offset = position / transcriptPageSize * transcriptPageSize
            refresh(reset: false)
        }
        let active = position.flatMap { pos in
            let visibleIndex = pos - offset
            return words.indices.contains(visibleIndex) ? words[visibleIndex].id : nil
        }
        if activeWordID != active { activeWordID = active }
    }

    private func handleKey(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            searchFocused = true
            return true
        }
        guard readerReady, dialogueFocused, modifiers.isEmpty || modifiers == .shift else { return false }
        if event.keyCode == 53 {
            dialogueFocused = false
            selectionStart = nil
            selectionEnd = nil
            return true
        }
        guard event.keyCode == 123 || event.keyCode == 124 else { return false }
        guard !words.isEmpty else { return true }
        let direction = event.keyCode == 123 ? -1 : 1
        if modifiers == .shift, !query.isEmpty, let index, let end = selectionEnd, let start = selectionStart,
           let position = index.position(of: end.id, space: space), position + direction >= 0,
           let adjacent = index.read(space: space, offset: position + direction, limit: 1).items.first,
           space != .source || adjacent.trackID == start.trackID {
            reveal(.init(first: start, last: adjacent), in: space)
            perform { try controller.seek(adjacent, space: space, attachmentID: adjacent.attachmentID ?? attachmentID) }
            return true
        }
        let current = words.firstIndex { $0.id == selectionEnd?.id } ?? (direction == 1 ? -1 : words.count)
        let destination = current + direction
        if words.indices.contains(destination) {
            if space == .source, modifiers == .shift, let start = selectionStart,
               words[destination].trackID != start.trackID { return true }
            choose(words[destination], extending: modifiers == .shift)
            return true
        }
        if query.isEmpty, (direction < 0 && offset > 0) || (direction > 0 && offset + words.count < total) {
            let edge = direction < 0 ? words.first?.id : words.last?.id
            move(direction)
            // The first page can overlap the one after it. The step is taken from the word it left.
            let shared = edge.flatMap { id in words.firstIndex { $0.id == id } }
            let neighbour = shared.flatMap { words.indices.contains($0 + direction) ? words[$0 + direction] : nil }
            if let next = neighbour ?? (direction < 0 ? words.last : words.first),
               space != .source || modifiers != .shift || next.trackID == selectionStart?.trackID {
                choose(next, extending: modifiers == .shift)
            }
            return true
        }
        return true
    }

    private func reveal(_ selection: TranscriptTimeSelection, in clock: TranscriptSpace) {
        let newAttachment = selection.first.attachmentID
        if !readerReady || newAttachment != index?.attachment?.id || space != clock || hasFilter {
            pendingSelection = (clock, selection)
            attachmentID = newAttachment
            space = clock
            speakerID = nil
            laneID = nil
            trackID = nil
            sourceID = nil
            file = nil
            clipID = nil
            assemblyIndex = nil
            return
        }
        guard let index,
              let first = index.occurrence(id: selection.first.id, space: clock),
              let last = index.occurrence(id: selection.last.id, space: clock),
              let position = index.position(of: first.id, space: clock) else {
            alert = "The chosen passage changed. Search the project transcripts again."
            return
        }
        searchText = ""
        query = ""
        offset = position / transcriptPageSize * transcriptPageSize
        filteredWords = nil
        refresh(reset: false)
        selectionStart = first
        selectionEnd = last
        revealWordID = first.id
        dialogueFocused = true
    }

    /// The positions a selection of several words spans, looked up once for a passage.
    private var selectedPositions: ClosedRange<Int>? {
        guard let start = selectionStart, let end = selectionEnd, start.id != end.id, let index,
              let first = index.position(of: start.id, space: space),
              let last = index.position(of: end.id, space: space) else { return nil }
        return min(first, last)...max(first, last)
    }

    private func isSelected(_ word: TranscriptOccurrence, within chosen: ClosedRange<Int>?) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        if start.id == end.id { return word.id == start.id }
        if space == .source, word.trackID != start.trackID { return false }
        guard let chosen, let point = index?.position(of: word.id, space: space) else { return false }
        return chosen.contains(point)
    }

    private func contextText(_ match: TranscriptMatch) -> String {
        (match.before + match.words + match.after).map(\.text).joined(separator: " ")
    }

    private func speakerName(_ id: String?) -> String {
        guard let id else { return "Unknown speaker" }
        return (index?.speakers ?? document?.speakers ?? []).first(where: { $0.id == id })?.name ?? id
    }

    private func displaySource(_ id: String) -> String {
        if let sources = multicam.project?.sources, let source = sources.first(where: { $0.id == id }) {
            let name = source.name ?? URL(fileURLWithPath: source.file).lastPathComponent
            let duplicates = sources.filter { ($0.name ?? URL(fileURLWithPath: $0.file).lastPathComponent) == name }
            return duplicates.count > 1 ? name + " · " + source.id : name
        }
        let url = URL(fileURLWithPath: id)
        let name = url.lastPathComponent
        let files = Set(controller.state.attachments.flatMap(\.bindings).compactMap(\.file)
                        + editor.sequenceClips.flatMap { [$0.file, $0.originalFile].compactMap { $0 } })
        let duplicates = files.filter { URL(fileURLWithPath: $0).lastPathComponent == name }
        return duplicates.count > 1 ? name + " · " + url.deletingLastPathComponent().path : name
    }

    private var hasMultipleOccurrences: Bool {
        isMulticam ? multicam.assemblyItems.count > 1 : editor.timelineClips.count > 1
    }

    private func trackLabel(_ track: TranscriptTrack) -> String {
        if let stream = track.streamIndex { return "\(track.name) · Stream \(stream)" }
        return track.name
    }

    private func wordDescription(_ word: TranscriptOccurrence) -> String {
        var parts = [timelineTime(word.range.from.seconds, milliseconds: true), speakerName(word.speakerID)]
        if word.partial { parts.append("Partial word") }
        if word.approximate { parts.append("Approximate clock") }
        if word.audibility == .inferred { parts.append("Inferred on the routed track") }
        if word.staleMatches { parts.append("Stale cross-track matches") }
        return parts.joined(separator: ", ")
    }

    private func perform<T>(_ action: () throws -> T) {
        do { _ = try action() } catch { alert = error.localizedDescription }
    }
}

private enum TranscriptScrollTarget: Hashable {
    case paragraph(Int)
    case match(Int)
}

extension TranscriptPane: Equatable {
    /// The pane reads its session through its own observers. An editor that redraws for
    /// every preview frame hands it the same session each time.
    nonisolated static func == (first: TranscriptPane, second: TranscriptPane) -> Bool {
        first.session === second.session
    }
}

/// One word of a passage. Its appearance depends only on these values, so a moving
/// playhead redraws the word it leaves and the word it reaches.
private struct TranscriptWordView: View, Equatable {
    let word: TranscriptOccurrence
    let selected: Bool
    let active: Bool
    let accented: Bool
    /// Corrections change a word's text or speaker under the same occurrence ID.
    let generation: Int
    let describe: (TranscriptOccurrence) -> String
    let press: (_ word: TranscriptOccurrence, _ extending: Bool) -> Void
    let choose: (_ word: TranscriptOccurrence, _ extending: Bool, _ seek: Bool) -> Void
    let inspect: () -> Void

    static func == (first: Self, second: Self) -> Bool {
        first.word.id == second.word.id && first.selected == second.selected && first.active == second.active
            && first.accented == second.accented && first.generation == second.generation
    }

    var body: some View {
        let _ = TranscriptPaneProbe.wordEvaluations += 1
        let description = describe(word)
        Button {
            press(word, NSEvent.modifierFlags.contains(.shift))
        } label: {
            HStack(spacing: 2) {
                Text(word.text)
                    .foregroundStyle(accented && !selected ? Color(nsColor: .linkColor) : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if word.partial || word.audibility == .inferred {
                    Image(systemName: word.partial ? "scissors" : "circle.dotted")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 1)
            .background(selected ? Color.accentColor.opacity(0.22) :
                            active ? Color.accentColor.opacity(0.11) : .clear,
                        in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TranscriptWordFrames.self,
                                       value: [word.id: proxy.frame(in: .named("transcript.words"))])
            }
        }
        .help(description)
        .accessibilityIdentifier("transcript.word.\(word.id)")
        .accessibilityHint(description)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Seek to Word") { choose(word, false, true) }
            Button("Extend Selection to Word") { choose(word, true, true) }
            Button("Inspect Word Evidence") { choose(word, false, false); inspect() }
        }
    }
}

private struct TranscriptWordFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TranscriptWordFlow: Layout {
    struct Cache {
        var width: CGFloat?
        var height: CGFloat = 0
        var frames: [CGRect] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 320
        arrange(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        arrange(width: bounds.width, subviews: subviews, cache: &cache)
        for (subview, frame) in zip(subviews, cache.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        cache.width = width
        cache.frames.removeAll(keepingCapacity: true)
        let proposal = ProposedViewSize(width: width, height: nil)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + 1
                lineHeight = 0
            }
            cache.frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + 1
            lineHeight = max(lineHeight, size.height)
        }
        cache.height = y + lineHeight
    }
}

extension TranscriptPane {
    private var selectedAttachment: TranscriptAttachment? {
        try? controller.attachment(id: attachmentID)
    }

    private var selection: TranscriptTimeSelection? {
        guard readerReady, let start = selectionStart, let end = selectionEnd else { return nil }
        if start.range.from == end.range.from, let index,
           let a = index.position(of: start.id, space: space), let b = index.position(of: end.id, space: space) {
            return a <= b ? .init(first: start, last: end) : .init(first: end, last: start)
        }
        return start.range.from <= end.range.from ? .init(first: start, last: end) : .init(first: end, last: start)
    }

    private func address(_ pair: TranscriptTimeSelection, in space: TranscriptSpace,
                         kind: TranscriptWordSelection.Kind = .phrase, leading: RationalTime? = nil,
                         trailing: RationalTime? = nil) -> TranscriptWordSelection {
        transcriptAddress(from: pair.first, through: pair.last, space: space,
                          attachment: pair.first.attachmentID ?? selectedAttachment?.id, kind: kind,
                          leading: leading, trailing: trailing)
    }

    private func attachmentLabel(_ attachment: TranscriptAttachment) -> String {
        func base(_ attachment: TranscriptAttachment) -> String {
            let sources = Set(attachment.bindings.compactMap { $0.sourceID ?? $0.file })
            guard let source = sources.sorted().first else { return "Unbound Transcript" }
            return displaySource(source) + (sources.count > 1 ? " + \(sources.count - 1)" : "")
        }
        let label = base(attachment)
        let siblings = controller.state.attachments.filter { base($0) == label }
        if siblings.count <= 1 { return label }
        let position = (siblings.firstIndex(where: { $0.id == attachment.id }) ?? 0) + 1
        return "\(label) · Transcript \(position)"
    }

    private var actionsBar: some View {
        HStack(spacing: 4) {
            Menu("Selection", systemImage: "text.cursor") {
                Button("Play Context", systemImage: "play.fill", action: playContext)
                Button("Inspect Word Evidence", action: showEvidence)
                Divider()
                Button("Mark Selection") { mark(.phrase) }
                Button("Mark Gap") { mark(.gap) }
                Menu("Expand Selection") {
                    Button("One Word Earlier") { expand(.earlier) }
                    Button("One Word Later") { expand(.later) }
                    Button("Sentence") { expand(.sentence) }
                    Button("Speaker Turn") { expand(.turn) }
                    Button("Include Preceding Question") { expand(.question) }
                }
                Divider()
                Button("Split at Word Edge…") { showEdit(.split) }
                Button("Trim Start to Selection…") { showEdit(.trimStart) }
                Button("Trim End to Selection…") { showEdit(.trimEnd) }
                Button("Delete Selected Time…", role: .destructive) { showEdit(.delete) }
                Button("Tighten Pause…") { showEdit(.tighten) }
                Button("Protect Pause…") { showNamedChange("Protect Pause", gap: true) { .pauseProtection(name: $0) } }
                if isMulticam, let word = selection?.first,
                   word.groupRange != nil || selection?.last.groupRange != nil {
                    let preferred = suggestedAngle(for: word.speakerID)
                    Button("Switch Angle at Dialogue…") { showEdit(.switchAngle) }
                    if let speaker = word.speakerID, let project = multicam.project {
                        Menu("Suggested Angle for " + speakerName(speaker)) {
                            Button("No Preference") { rememberAngle(nil, for: speaker) }
                            ForEach(project.angles, id: \.id) { angle in
                                Button {
                                    rememberAngle(angle.id, for: speaker)
                                } label: {
                                    if angle.id == preferred {
                                        Label(angle.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(angle.displayName)
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Correct Text…", action: showTextCorrection)
                Button("Rename Speaker…", action: showRenameSpeaker)
                    .disabled(selection?.first.speakerID == nil)
                Menu("Assign or Split Speaker") {
                    ForEach(index?.speakers ?? document?.speakers ?? [], id: \.id) { speaker in
                        Button(speaker.name) { correct(.assignSpeaker(speakerID: speaker.id)) }
                    }
                    Button("New Speaker…") { showNamedChange("New Speaker") { .splitSpeaker(speakerID: UUID().uuidString, name: $0) } }
                }
                if let speaker = selection?.first.speakerID {
                    Menu("Merge Speaker Into") {
                        ForEach((index?.speakers ?? document?.speakers ?? []).filter { $0.id != speaker }, id: \.id) { target in
                            Button(target.name) { correct(.mergeSpeakers(sourceID: speaker, targetID: target.id), anchored: false) }
                        }
                    }
                }
                Divider()
                Button("Save Named Select…") { showNamedChange("Save Named Select") { .namedSelect(name: $0) } }
                Button("Add to Ordered Selects") { addToOrderedSelects() }
                Button("Queue Excerpt…") { showEdit(.queue, defaultName: selectedText()) }
                Button("Copy Quote with References", action: copyQuote)
            }
            .barMenu()
            .accessibilityIdentifier("transcript.actions")
            .disabled(selection == nil || loadingIndex)

            Menu("Review", systemImage: "list.bullet.rectangle") {
                Button("Coverage Gaps…", action: showGaps)
                Button("Compare Takes…") { showEditorial(.takes) }
                Button("Align Script…") { showEditorial(.script) }
                Button("Review Restarts and Fillers…") { showEditorial(.suggestions) }
                Button("Named Selects and Corrections…", action: showAuthored)
            }
            .barMenu()
            .accessibilityIdentifier("transcript.reviewMenu")
            Spacer(minLength: 0)
            if !basket.items.isEmpty {
                BarButton("Selects \(basket.items.count)", symbol: "list.number", action: showOrderedSelects)
                    .accessibilityIdentifier("transcript.orderedSelects")
            }
        }
    }

    private func angleChoices(_ word: TranscriptOccurrence, edge: TranscriptEditRequest.Edge) -> [TranscriptAngleChoice] {
        guard let group = word.groupRange, let project = multicam.project else { return [] }
        let at = edge == .start ? group.from : group.to
        guard project.range.contains(at) else { return [] }
        let preferred = suggestedAngle(for: word.speakerID)
        return project.angles.compactMap { angle in
            guard let source = project.pictureSource(for: angle.id, at: at),
                  let media = multicam.media[source.id], let video = media.videoStream,
                  let local = try? at.subtracting(source.offset) else { return nil }
            let end = video.duration > .zero ? (try? video.start.adding(video.duration)) ?? media.duration : media.duration
            guard local >= video.start, local < min(end, media.duration) else { return nil }
            guard let picture = MulticamPicturePosition.at(local, source: source.id, media: media, spanIndex: 0) else {
                return nil
            }
            let time = timelineTime(picture.frameTime.seconds, milliseconds: true)
            let suffix = angle.id == preferred ? " · Suggested" : ""
            return TranscriptAngleChoice(id: angle.id, label: "\(displaySource(angle.id)) · \(time)\(suffix)")
        }
    }

    private func anglePreferenceKey(for speaker: String?) -> String? {
        guard let speaker, let attachment = selectedAttachment else { return nil }
        return attachment.id + ":" + speaker
    }

    private var suggestedAngles: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: suggestedAnglesData)) ?? [:]
    }

    private func suggestedAngle(for speaker: String?) -> String? {
        anglePreferenceKey(for: speaker).flatMap { suggestedAngles[$0] }
    }

    private func rememberAngle(_ angle: String?, for speaker: String) {
        guard let key = anglePreferenceKey(for: speaker) else { return }
        var angles = suggestedAngles
        angles[key] = angle
        if let encoded = try? JSONEncoder().encode(angles) { suggestedAnglesData = encoded }
    }

    private var transcriptPanelDirectory: URL? {
        if let projectURL = isMulticam ? multicam.projectURL : editor.projectURL {
            return projectURL.resolvingSymlinksInPath().deletingLastPathComponent()
        }
        if isMulticam, let project = multicam.project {
            let groupTime = multicam.groupTime(at: multicam.preview.currentTime())
            let source = project.selection(at: groupTime).flatMap { project.pictureSource(for: $0.angle, at: groupTime) }
                ?? project.sources.first
            return source.map { URL(fileURLWithPath: $0.file).deletingLastPathComponent() }
        }
        if let sourceID = editor.analysisPlayheadSourceID, let media = editor.analysisSourceMedia[sourceID] {
            return media.url.deletingLastPathComponent()
        }
        return editor.sequenceClips.first.map { URL(fileURLWithPath: $0.file).deletingLastPathComponent() }
    }

    private func chooseImport() {
        guard importTask == nil else { return }
        let owner = session.mcpHandle
        let panel = NSOpenPanel()
        panel.directoryURL = transcriptPanelDirectory
        panel.prompt = "Choose"
        panel.message = "Choose a Transcriberrr JSON, SubRip, or WebVTT file."
        panel.allowedContentTypes = [.json] + ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }
        let receive: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else { return }
            guard let format = TranscriptFormat(rawValue: url.pathExtension.lowercased()), format != .text else {
                alert = "Choose a JSON, SRT, or VTT transcript."
                return
            }
            guard owner == session.mcpHandle else { return }
            status = nil
            importTask = Task { @MainActor in
                defer { if !Task.isCancelled { importTask = nil } }
                let worker = Task.detached(priority: .userInitiated) {
                    try LiveTranscriptController.readImport(url, format: format)
                }
                do {
                    let transcript = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard !Task.isCancelled, owner == session.mcpHandle else { return }
                    status = nil
                    sheet = TranscriptPaneSheet("Import Transcript") {
                        TranscriptBindingsForm(tracks: transcript.tracks, choices: bindingChoices, bindings: [], origin: nil,
                                               applyTitle: "Import Transcript") { bindings, origin in
                            guard owner == session.mcpHandle else {
                                throw CutError(code: "stale_transcript", message: "The project changed. Choose the transcript again.")
                            }
                            let attached = try await controller.attachImportedTranscript(transcript, bindings: bindings, origin: origin)
                            attachmentID = attached.id
                            sheet = nil
                            status = nil
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    status = nil
                    alert = error.localizedDescription
                }
            }
        }
        if let window = session.window { panel.beginSheetModal(for: window, completionHandler: receive) }
        else { panel.begin(completionHandler: receive) }
    }

    private func locateTranscriptStore() {
        guard let attachment = selectedAttachment else { return }
        perform {
            let context = try controller.assetContext()
            let requested = revision
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = context.deletingLastPathComponent()
            panel.prompt = "Recover"
            panel.message = "Choose the transcript store beside this project."
            let finish: (NSApplication.ModalResponse) -> Void = { result in
                guard result == .OK, let directory = panel.url, requested == revision else { return }
                perform {
                    try controller.recoverAttachment(id: attachment.id, from: directory)
                    status = "Recovered the transcript."
                    reload()
                }
            }
            if let window = session.window { panel.beginSheetModal(for: window, completionHandler: finish) }
            else { panel.begin(completionHandler: finish) }
        }
    }

    private var bindingChoices: [TranscriptBindingChoice] {
        if isMulticam, let project = multicam.project {
            return project.sources.flatMap { source in
                let name = "\(source.displayName) [\(source.id)]"
                return (multicam.media[source.id]?.streams ?? []).filter { $0.kind == "audio" }.map {
                    TranscriptBindingChoice(sourceID: source.id, file: nil, streamIndex: $0.index,
                                            label: "\(name) · Stream \($0.index)")
                }
            }
        }
        let clips = editor.sequenceClips
        let originals = Set(clips.compactMap(\.originalFile))
        let replacements = Set(clips.filter { $0.originalFile != nil }.map(\.file))
        let files = Set(clips.map(\.file)).union(originals)
        return files.sorted().flatMap { file in
            let url = URL(fileURLWithPath: file)
            let label = originals.contains(file) ? "Original recording" : replacements.contains(file) ? "Replacement audio" : "Recording"
            let streams = (try? editor.transcriptMediaInfo(for: file))?.streams ?? []
            return streams.filter { $0.kind == "audio" }.map {
                TranscriptBindingChoice(sourceID: nil, file: file, streamIndex: $0.index,
                                        label: "\(url.lastPathComponent) · \(label) · Stream \($0.index) · \(url.deletingLastPathComponent().path)")
            }
        }
    }

    private func showRebind() {
        guard let attachment = selectedAttachment, let transcript = document else { return }
        sheet = TranscriptPaneSheet("Rebind Transcript") {
            TranscriptBindingsForm(tracks: transcript.tracks, choices: bindingChoices, bindings: attachment.bindings,
                                   origin: attachment.importOrigin, applyTitle: "Rebind Transcript") { bindings, origin in
                try controller.bind(attachmentID: attachment.id, bindings: bindings, origin: origin)
                sheet = nil
            }
        }
    }

    private func showAttachment() {
        guard let attachment = selectedAttachment, let document else { return }
        let context = try? controller.assetContext()
        let snapshot = controller.project
        let bindings = Dictionary(uniqueKeysWithValues: attachment.bindings.map { binding in
            (binding.trackID, context.map { binding.sourceStatus(in: snapshot, relativeTo: $0) } ?? .unverified)
        })
        sheet = TranscriptPaneSheet("Transcript Attachment") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Clock", value: document.clock.rawValue.capitalized)
                    LabeledContent("Timing", value: document.approximateClock && attachment.importOrigin == nil ? "Approximate" : "Declared")
                    if let origin = attachment.importOrigin { LabeledContent("Cue origin", value: origin.description) }
                    LabeledContent("Words and cues", value: String(document.words.count))
                    ForEach(document.tracks, id: \.id) { track in
                        let binding = attachment.bindings.first(where: { $0.trackID == track.id })
                        VStack(alignment: .leading, spacing: 3) {
                            Text(trackLabel(track)).font(.headline)
                            Text(coverageLabel(track.coverage))
                            if let binding {
                                let source = binding.sourceID ?? binding.file ?? "Unbound"
                                Text("\(displaySource(source)) · Stream \(binding.streamIndex) · Offset \(binding.offset.description)")
                                    .foregroundStyle(.secondary)
                                if let status = bindings[track.id], status != .available {
                                    Label(bindingStatus(status), systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                Label("Unbound audio stream", systemImage: "link.badge.plus").foregroundStyle(.orange)
                            }
                        }
                    }
                    if bindings.values.contains(where: { $0 != .available }) || attachment.bindings.count < document.tracks.count {
                        Button("Rebind Transcript…", action: showRebind)
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 120, idealHeight: 230, maxHeight: 360)
            .textSelection(.enabled)
        }
    }

    private func bindingStatus(_ status: TranscriptBindingStatus) -> String {
        switch status {
        case .available: "Verified Media"
        case .unverified: "Unverified Media"
        case .offline: "Media Offline"
        case .changed: "Media Changed"
        case .unbound: "Unbound Audio Stream"
        case .bindingMissing: "Source Removed from Project"
        }
    }

    private func coverageLabel(_ coverage: TranscriptCoverage) -> String {
        switch coverage {
        case .recognized: "Recognized"
        case .skipped: "Skipped recognition"
        case .failed: "Recognition failed"
        case .coverageOnly: "Camera coverage only"
        }
    }

    private func confirmDetach() {
        guard let attachment = selectedAttachment else { return }
        sheet = TranscriptPaneSheet("Detach Transcript", actionTitle: "Detach", action: {
            try controller.detach(attachmentID: attachment.id)
            attachmentID = nil
            sheet = nil
        }) {
            Text("Remove this transcript attachment from the project?")
        }
    }

    private func showExport() {
        sheet = TranscriptPaneSheet("Export Transcript") {
            TranscriptExportForm(space: space, isMulticam: isMulticam) { format, clock in
                let requested = revision
                let attachmentID = selectedAttachment?.id
                let panel = NSSavePanel()
                panel.directoryURL = transcriptPanelDirectory
                panel.nameFieldStringValue = "Transcript-\(clock.rawValue).\(format == .text ? "txt" : format.rawValue)"
                let save: (NSApplication.ModalResponse) -> Void = { result in
                    guard result == .OK, let url = panel.url else { return }
                    guard requested == revision else {
                        alert = "The transcript changed. Choose the export options again."
                        return
                    }
                    status = "Exporting transcript…"
                    Task { @MainActor in
                        do {
                            let index = try await controller.indexedTranscript(attachmentID: attachmentID)
                            try await Task.detached(priority: .userInitiated) {
                                let data = try TranscriptCodec.encode(index, space: clock, format: format)
                                try data.write(to: url, options: .atomic)
                            }.value
                            status = "Exported \(url.lastPathComponent)."
                        } catch {
                            status = nil
                            alert = error.localizedDescription
                        }
                    }
                }
                if let window = session.window?.attachedSheet { panel.beginSheetModal(for: window, completionHandler: save) }
                else { panel.begin(completionHandler: save) }
            }
        }
    }

    private func mark(_ kind: TranscriptWordSelection.Kind) {
        guard let selection else { return }
        perform {
            let marked = try controller.mark(address(selection, in: space, kind: kind), attachmentID: attachmentID)
            let length = try marked.range.to.subtracting(marked.range.from)
            status = "Marked \(timelineTime(length.seconds, milliseconds: true))."
        }
    }

    private func showEvidence() {
        guard let word = selection?.first else { return }
        var evidenceRows = word.observations
        if let primary = word.observation, !evidenceRows.contains(primary) { evidenceRows.append(primary) }
        let rejected = (word.matchReviews ?? []).filter { $0.disposition == .rejected }.map(\.observation)
        evidenceRows.append(contentsOf: rejected)
        let read = try? controller.editRevision(attachmentID: word.attachmentID ?? attachmentID)
        sheet = TranscriptPaneSheet("Word Evidence") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(word.text).font(.title3)
                    if word.text != word.originalText { LabeledContent("Original wording", value: word.originalText) }
                    LabeledContent("Speaker", value: speakerName(word.speakerID))
                    if let label = word.laneLabel, let slot = word.laneColorSlot {
                        LabeledContent("Lane") { TranscriptLaneChip(label: label, colorSlot: slot) }
                    }
                    if let laneIDs = word.heardOnLaneIDs, !laneIDs.isEmpty, let project = multicam.project {
                        LabeledContent("Also heard on") {
                            VStack(alignment: .trailing) {
                                ForEach(project.mixLanes.filter { laneIDs.contains($0.id) }) { lane in
                                    TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot)
                                }
                            }
                        }
                    }
                    LabeledContent("Timing", value: wordDescription(word))
                    if let routed = word.routedStreamIndex {
                        LabeledContent("Routed stream", value: "\(word.routedSourceID.map(displaySource) ?? "Program") · \(routed)")
                    }
                    ForEach(Array(evidenceRows.enumerated()), id: \.offset) { row in
                        let evidence = row.element
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document?.tracks.first(where: { $0.id == evidence.trackID })?.name ?? evidence.trackID).font(.headline)
                            Text("\(evidence.evidence.rawValue.capitalized) · \(evidence.start.description)–\(evidence.end.description)")
                            if let review = word.matchReviews?.first(where: { $0.observation == evidence }) {
                                Text(review.disposition == .confirmed ? "Match confirmed by editor" : "Match rejected by editor")
                            }
                            if let basis = evidence.basis { Text(basis).foregroundStyle(.secondary) }
                            if let text = evidence.text { Text(text) }
                            if evidence.evidence == .inferred {
                                HStack {
                                    Button("Accept Match") { correct(.matchOverride(trackID: evidence.trackID, accepted: true, observation: .init(evidence)), expecting: read) }
                                    Button("Reject Match") { correct(.matchOverride(trackID: evidence.trackID, accepted: false, observation: .init(evidence)), expecting: read) }
                                }
                            }
                        }
                    }
                    if !word.candidateTrackIDs.isEmpty {
                        Text("Candidate tracks: " + word.candidateTrackIDs.joined(separator: ", "))
                    }
                    ForEach(word.angles, id: \.sourceID) { angle in
                        LabeledContent(displaySource(angle.sourceID), value: (angle.frameTime ?? angle.sourceRange.from).description)
                    }
                }
                .textSelection(.enabled)
                .padding(2)
            }
            .frame(minHeight: 140, idealHeight: 240, maxHeight: 400)
        }
    }

    private func showGaps() {
        guard let index else { return }
        let clock = space
        if clock != .currentCut {
            let requested = revision
            let seek: ((RationalTime) -> Void)? = isMulticam && clock == .group ? { time in
                guard requested == revision else {
                    alert = "The transcript changed. Open coverage again to use the current group clock."
                    return
                }
                multicam.preview.pause()
                multicam.setAssemblyPreview(false)
                multicam.seekGroup(time)
                sheet = nil
            } : nil
            sheet = TranscriptPaneSheet("Transcript Coverage") {
                TranscriptCoverageReview(index: index, space: clock, filter: filter, sourceLabel: displaySource, seek: seek)
            }
            return
        }
        let selectedLane = laneID
        let gaps = index.gaps.filter { selectedLane == nil || $0.laneID == selectedLane }
        sheet = TranscriptPaneSheet("Transcript Coverage") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(document?.tracks ?? [], id: \.id) { track in
                        let lane = controller.project.transcriptLane(for: track, attachment: selectedAttachment)
                        if selectedLane == nil || lane?.id == selectedLane {
                            LabeledContent {
                                Text(coverageLabel(track.coverage))
                            } label: {
                                HStack {
                                    Text(trackLabel(track))
                                    if let lane { TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot) }
                                }
                            }
                        }
                    }
                    if !gaps.isEmpty {
                        Divider()
                        Text("Current Cut").font(.headline)
                        ForEach(Array(gaps.enumerated()), id: \.offset) { row in
                            let gap = row.element
                            Button {
                                if isMulticam { multicam.seekAssembly(at: gap.range.from, scrubbing: false) }
                                else { editor.seek(gap.range.from.seconds) }
                                sheet = nil
                            } label: {
                                let time = timelineTime(gap.range.from.seconds, milliseconds: true)
                                let end = timelineTime(gap.range.to.seconds, milliseconds: true)
                                HStack {
                                    Label("\(time)–\(end) · \(gap.reason.rawValue.capitalized)", systemImage: "waveform")
                                    if let label = gap.laneLabel, let slot = gap.laneColorSlot {
                                        TranscriptLaneChip(label: label, colorSlot: slot)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 110, idealHeight: 250, maxHeight: 390)
        }
    }

    private func showEdit(_ action: TranscriptEditRequest.Action, defaultName: String = "") {
        guard let selection else { return }
        let chosenSpace = space
        sheet = TranscriptPaneSheet(editTitle(action)) {
            TranscriptEditOptionsForm(action: action, queueName: defaultName,
                                      startAngles: action == .switchAngle ? angleChoices(selection.first, edge: .start) : [],
                                      endAngles: action == .switchAngle ? angleChoices(selection.last, edge: .end) : []) {
                name, leading, trailing, retained, startNudge, endNudge, policy, edge, kind, angleID in
                let words = address(selection, in: chosenSpace, kind: kind, leading: leading, trailing: trailing)
                let request = TranscriptEditRequest(action: action, selections: [words], retainedDuration: retained,
                                                    angleID: angleID, name: name, boundaryPolicy: policy, edge: edge,
                                                    startFrameNudge: startNudge,
                                                    endFrameNudge: endNudge)
                try await review(request, name: name)
            }
        }
    }

    private func editTitle(_ action: TranscriptEditRequest.Action) -> String {
        switch action {
        case .split: "Split at Word Edge"
        case .trimStart: "Trim Start"
        case .trimEnd: "Trim End"
        case .delete: "Delete Selected Time"
        case .tighten: "Tighten Pause"
        case .assemble: "Assemble Selects"
        case .insert: "Insert Selects"
        case .replace: "Replace with Selects"
        case .switchAngle: "Switch Camera"
        case .queue: "Queue Excerpt"
        }
    }

    private func review(_ request: TranscriptEditRequest, name: String) async throws {
        try Task.checkCancellation()
        guard let presentingSheetID = sheet?.id else { throw CancellationError() }
        let requested = revision
        let presenting = request.selections.first?.attachmentID ?? selectedAttachment?.id
        let prebuilt = !loadingIndex && index?.attachment?.id == presenting && index?.timelineRevision == requested.timeline ? index : nil
        let work = try controller.preparePlanReview(request, attachmentID: presenting, index: prebuilt)
        let worker = Task.detached(priority: .userInitiated, operation: work)
        let (plan, evidence) = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard sheet?.id == presentingSheetID else { throw CancellationError() }
        guard requested == revision else {
            throw CutError(code: "stale_transcript_plan", message: "The project changed while the edit was being reviewed.")
        }
        var passages: [TranscriptReviewPassage] = []
        for selection in plan.selections {
            let scoped = selection.attachmentID.flatMap { evidence[$0] }
            let firstPosition = scoped?.position(of: selection.first.id, space: selection.space)
            let lastPosition = scoped?.position(of: selection.last.id, space: selection.space)
            let snippet: [String]
            if let scoped, let firstPosition, let lastPosition, firstPosition <= lastPosition {
                let offset = max(0, firstPosition - 3)
                let count = lastPosition + 4 - offset
                func context(at offset: Int, count: Int) -> [String] {
                    scoped.read(space: selection.space, offset: offset, limit: count).items
                        .filter { selection.space != .source || $0.trackID == selection.first.trackID }
                        .map(\.text)
                }
                if count > 24 {
                    snippet = context(at: offset, count: 12) + ["…"] + context(at: lastPosition - 8, count: 12)
                } else {
                    snippet = context(at: offset, count: count)
                }
            } else {
                snippet = [selection.first.text] + (selection.first.id == selection.last.id ? [] : [selection.last.text])
            }
            let attachment = selection.attachmentID.flatMap { id in
                controller.state.attachments.first { $0.id == id }
            }
            passages.append(.init(attachment: attachment.map(attachmentLabel), space: selection.space,
                                  range: selection.range, adjacent: snippet,
                                  waveform: await activity(for: selection, in: scoped)))
            try Task.checkCancellation()
            guard sheet?.id == presentingSheetID else { throw CancellationError() }
        }
        guard requested == revision else {
            throw CutError(code: "stale_transcript_plan", message: "The project changed while the edit was being reviewed.")
        }
        let attachmentNames = Dictionary(uniqueKeysWithValues: controller.state.attachments.map {
            ($0.id, attachmentLabel($0))
        })
        let occurrenceLabels = plan.affectedOccurrences.map { id in
            guard plan.action == .switchAngle, id.hasPrefix("assembly:"),
                  let index = Int(id.dropFirst("assembly:".count)), let range = multicam.assemblyRange(at: index) else {
                return id
            }
            let group: MulticamRange
            if case .multicam(let result) = plan.snapshot,
               let at = plan.boundaries.first(where: { $0.space == .group })?.resolved {
                let next = result.switches.first(where: { $0.at > at })?.at ?? result.range.to
                group = MulticamRange(from: max(range.from, at), to: min(range.to, next))
            } else {
                group = range
            }
            let output = multicam.assemblyStart(at: index)
            let cutFrom = timelineTime(output.seconds + group.from.seconds - range.from.seconds, milliseconds: true)
            let cutTo = timelineTime(output.seconds + group.to.seconds - range.from.seconds, milliseconds: true)
            let from = timelineTime(group.from.seconds, milliseconds: true)
            let to = timelineTime(group.to.seconds, milliseconds: true)
            return "Occurrence \(index + 1) · Cut \(cutFrom)–\(cutTo) · Group \(from)–\(to)"
        }
        let next = TranscriptPaneSheet(editTitle(plan.action), actionTitle: plan.action == .queue ? "Add to Export Queue" : "Apply",
                                    actionIdentifier: "transcript.apply", action: {
            if plan.action == .queue {
                _ = try controller.queue(plan, name: name)
                status = "Queued \(name)."
            } else {
                // A plan that already matches the cut adds no undo step. Say so.
                // Applied by hand, so a multicam editor asks before the edit lowers its export tier.
                let commit = try MulticamTierGate.byHand { try controller.apply(plan) }
                status = commit.undo == nil ? "The cut already matches. Nothing changed." : plan.historyAction
            }
            sheet = nil
        }) {
            TranscriptEditReview(plan: plan, passages: passages, attachmentNames: attachmentNames, occurrenceLabels: occurrenceLabels)
        }
        pendingSheet = next
        sheet = nil
    }

    private func activity(for resolved: TranscriptResolvedSelection, in index: TranscriptIndex?) async -> [Double] {
        guard resolved.first.trackID == resolved.last.trackID,
              resolved.first.binding == resolved.last.binding,
              let first = resolved.first.sourceRange, let last = resolved.last.sourceRange else { return [] }
        let from = resolved.kind == .gap ? first.to : first.from
        let to = resolved.kind == .gap ? last.from : last.to
        guard from < to else { return [] }
        if let track = index?.document.tracks.first(where: { $0.id == resolved.first.trackID }),
           let origin = try? (index?.attachment?.importOrigin ?? .zero).adding(resolved.first.binding?.offset ?? .zero),
           let rawFrom = try? from.subtracting(origin), let rawTo = try? to.subtracting(origin) {
            let frames = track.activity.filter { $0.start < rawTo && $0.end > rawFrom }
            if !frames.isEmpty {
                let step = max(1, (frames.count + 179) / 180)
                return stride(from: 0, to: frames.count, by: step).map { start in
                    frames[start..<min(start + step, frames.count)].map(\.level).max() ?? 0
                }
            }
        }
        guard let binding = resolved.first.binding else { return [] }
        let media: MediaInfo?
        let lower: Double
        let upper: Double
        if let source = binding.sourceID {
            media = multicam.media[source]
            lower = from.seconds
            upper = to.seconds
        } else if let file = binding.file, let available = try? editor.transcriptMediaInfo(for: file) {
            media = available
            lower = from.seconds - available.multicamSourceOffset.seconds
            upper = to.seconds - available.multicamSourceOffset.seconds
        } else {
            return []
        }
        guard let media, let ordinal = media.streams.filter({ $0.kind == "audio" }).firstIndex(where: {
            $0.index == binding.streamIndex
        }) else { return [] }
        let range = max(0, lower)..<max(0, upper)
        guard !range.isEmpty else { return [] }
        let token = EditCancellation()
        let samples = Task.detached(priority: .userInitiated) {
            var result: [Double] = []
            SparseWaveform.sample(media: media, ordinal: ordinal, range: range, token: token) { waveform in
                result = waveform.peaks.map { Double($0 ?? 0) }
            }
            return result
        }
        return await withTaskCancellationHandler {
            await samples.value
        } onCancel: {
            token.cancel()
        }
    }

    private func selectedText() -> String {
        guard let selected = selection, let index else { return "" }
        return transcriptWording(transcriptWords(from: selected.first, through: selected.last, in: index, space: space))
    }

    private func copyQuote() {
        guard let selection else { return }
        let first = selection.first
        let last = selection.last
        let text = selectedText()
        let reference = [speakerName(first.speakerID), first.sourceID.map(displaySource) ?? first.file.map(displaySource),
                         first.streamIndex.map { "stream \($0)" },
                         "\(space.label) \(first.range.from)–\(last.range.to)",
                         first.assemblyIndex.map { "occurrence \($0 + 1)" }, "word \(first.wordID)"].compactMap { $0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([text, reference.joined(separator: " · ")].joined(separator: "\n"), forType: .string)
        status = "Copied quote and references."
    }

    private func showTextCorrection() {
        guard selection != nil else { return }
        showNamedChange("Correct Text", starting: selectedText()) { .replaceText(text: $0) }
    }

    private func showRenameSpeaker() {
        guard let speaker = selection?.first.speakerID else { return }
        showNamedChange("Rename Speaker", starting: speakerName(speaker)) { .renameSpeaker(speakerID: speaker, name: $0) }
    }

    private func showNamedChange(_ title: String, starting: String = "", gap: Bool = false,
                                 transform: @escaping (String) -> TranscriptAuthoredChange) {
        guard let selection else { return }
        let subject = address(selection, in: space, kind: gap ? .gap : .phrase)
        let attachment = attachmentID
        // The sheet can stay open while a job or another client replaces what was selected.
        let read = try? controller.editRevision(attachmentID: attachment ?? subject.attachmentID)
        sheet = TranscriptPaneSheet(title) {
            TranscriptTextForm(label: title == "Correct Text" ? "Corrected text" : "Name", initial: starting) { value in
                _ = try controller.correct(transform(value), selection: subject, attachmentID: attachment, expecting: read)
                sheet = nil
                status = title
            }
        }
    }

    private func correct(_ change: TranscriptAuthoredChange, anchored: Bool = true,
                         expecting read: TranscriptEditRevision? = nil) {
        perform {
            let subject = anchored ? selection.map { address($0, in: space) } : nil
            _ = try controller.correct(change, selection: subject, attachmentID: subject?.attachmentID ?? attachmentID,
                                       expecting: read)
            sheet = nil
            status = "Saved transcript correction."
        }
    }

    private func playContext() {
        guard let selection else { return }
        playContext(selection, in: space)
    }

    private func stopContextPlayback() {
        guard let contextPlayback else { return }
        contextPlayback.cancel()
        self.contextPlayback = nil
        if isMulticam { multicam.preview.pause() }
        else { editor.preview.pause() }
    }

    private func playContext(_ selection: TranscriptTimeSelection, in clock: TranscriptSpace) {
        stopContextPlayback()
        perform {
            if clock == .source {
                try controller.auditionSource(selection.first, through: selection.last)
                return
            }
            let lead = RationalTime(numerator: 3, denominator: 4)
            let tail = RationalTime(numerator: 5, denominator: 4)
            try controller.seek(selection.first, space: clock, attachmentID: selection.first.attachmentID)
            let origin = clock == .group ? multicam.project?.range.from ?? .zero : .zero
            let beginning = max(origin, try selection.first.range.from.subtracting(lead))
            let requestedEnd = try max(selection.first.range.to, selection.last.range.to).adding(tail)
            if isMulticam {
                let preview = multicam.preview
                if clock == .group {
                    multicam.seekGroup(beginning)
                } else {
                    multicam.seekAssembly(at: beginning, scrubbing: false)
                }
                let end = min(preview.duration, try requestedEnd.subtracting(origin))
                guard preview.time < end else { return }
                contextPlayback = preview.$time.dropFirst().filter { $0 >= end }.first()
                    .receive(on: DispatchQueue.main).sink { _ in stopContextPlayback() }
                preview.togglePlayback()
            } else {
                editor.seek(beginning.seconds)
                let preview = editor.preview
                let end = min(editor.duration, requestedEnd.seconds)
                guard preview.time < end else { return }
                contextPlayback = preview.$time.dropFirst().filter { $0 >= end }.first()
                    .receive(on: DispatchQueue.main).sink { _ in stopContextPlayback() }
                preview.togglePlayback()
            }
        }
    }

    private enum Expansion { case earlier, later, sentence, turn, question }

    private func expand(_ type: Expansion) {
        guard let selection, let index else { return }
        let words = index.readAll(space: space, filter: space == .source ? .init(
            trackID: selection.first.trackID, includeInferred: true
        ) : .init())
        guard let first = words.firstIndex(where: { $0.id == selection.first.id }),
              let last = words.firstIndex(where: { $0.id == selection.last.id }) else { return }
        let firstWord = words[first]
        func sameTurn(_ item: TranscriptOccurrence) -> Bool {
            item.speakerID == firstWord.speakerID && item.trackID == firstWord.trackID
                && item.clipID == firstWord.clipID && item.assemblyIndex == firstWord.assemblyIndex
        }
        func punctuation(_ item: TranscriptOccurrence) -> Bool { item.text.last.map { ".?!".contains($0) } == true }
        var from = first
        var to = last
        if type == .earlier { from = max(0, first - 1) }
        if type == .later { to = min(words.count - 1, last + 1) }
        if type == .sentence || type == .turn {
            while from > 0 && sameTurn(words[from - 1]) && (type == .turn || !punctuation(words[from - 1])) { from -= 1 }
            while to + 1 < words.count && sameTurn(words[to + 1]) && (type == .turn || !punctuation(words[to])) { to += 1 }
        }
        if type == .question, first > 0 {
            if let question = words[..<first].lastIndex(where: { $0.text.hasSuffix("?") }) {
                from = question
                while from > 0 && words[from - 1].speakerID == words[question].speakerID && !punctuation(words[from - 1]) { from -= 1 }
            }
        }
        let pair = TranscriptTimeSelection(first: words[from], last: words[to])
        if self.words.contains(where: { $0.id == pair.first.id }) {
            selectionStart = pair.first
            selectionEnd = pair.last
        } else {
            reveal(pair, in: space)
        }
    }
}

extension TranscriptSpace {
    var label: String {
        switch self {
        case .source: "Source"
        case .group: "Group"
        case .currentCut: "Current Cut"
        }
    }
}

extension TranscriptPane {
    @ViewBuilder
    private var jobStatus: some View {
        if let job = controller.job {
            let tracks = job.sessions.flatMap(\.tracks).filter(\.recognize)
            let processed = tracks.filter { [.recognized, .cached, .failed].contains($0.state) }.count
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(jobLabel(job.state), systemImage: "waveform.badge.mic")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("transcript.job.status")
                    Spacer(minLength: 0)
                    if !tracks.isEmpty {
                        iconButton("Track Progress…", symbol: "list.bullet.rectangle", action: showJobs)
                            .help("Track progress")
                    }
                    if controller.activeJobID != nil {
                        Button("Cancel") { perform { try controller.cancel(job.id) } }
                            .accessibilityIdentifier("transcript.job.cancel")
                    } else if [.failed, .partial, .cancelled, .interrupted, .stale].contains(job.state) {
                        Button("Retry…") { showRetry(job) }
                            .accessibilityIdentifier("transcript.job.retry")
                    }
                }
                if controller.activeJobID != nil {
                    if !tracks.isEmpty {
                        ProgressView(value: Double(processed), total: Double(tracks.count))
                            .labelsHidden()
                            .accessibilityLabel("Streams processed")
                        Text(tracks.count == 1 ? "\(processed) of 1 stream processed" : "\(processed) of \(tracks.count) streams processed")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    // A long recording is one stream for a long time. Show what it is doing.
                    if index != nil, let working = tracks.first(where: { [.pending, .staged].contains($0.state) && $0.message != nil }),
                       let phase = working.message {
                        Text("\(working.name): \(phase)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityIdentifier("transcript.job.track")
                    }
                }
                if let message = controller.jobError ?? job.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
        } else if let active = controller.activeJobID {
            HStack {
                ProgressView("Preparing transcript…").controlSize(.small)
                Spacer()
                Button("Cancel") { cancelPreparingJob(active) }
                    .accessibilityIdentifier("transcript.job.cancel")
            }
            .padding(8)
        } else if let error = controller.jobError {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).padding(8)
        }
    }

    private func reconcileTranscript(_ attachmentID: String) {
        perform { try controller.reconcile(attachmentID: attachmentID) }
    }

    private func cancelPreparingJob(_ id: UUID) {
        do { _ = try controller.cancel(id) }
        catch let error as CutError where error.code == "unknown_transcript_job" && controller.activeJobID == id {
            // The token has already been signalled and the durable record is still being created.
        } catch {
            alert = error.localizedDescription
        }
    }

    private func jobLabel(_ status: TranscriptJobState) -> String {
        switch status {
        case .preparing, .prepared: "Preparing Audio"
        case .running: "Transcribing"
        case .completed: "Transcription Complete"
        case .partial: "Transcription Partially Complete"
        case .failed: "Transcription Failed"
        case .cancelled: "Transcription Cancelled"
        case .interrupted: "Transcription Interrupted"
        case .stale: "Alignment Out of Date"
        }
    }

    private func showSetup() {
        sheet = TranscriptPaneSheet("Transcribe with Transcriberrr") {
            TranscriptJobSetup(controller: controller) { options, download in
                _ = try controller.start(options: options, download: download)
                sheet = nil
            }
        }
    }

    private func showRetry(_ job: TranscriptJobRecord) {
        sheet = TranscriptPaneSheet("Retry Transcription") {
            TranscriptRetryForm(message: job.message ?? controller.jobError) { download in
                try controller.retry(job.id, download: download)
                sheet = nil
            }
        }
    }

    private func showJobs() {
        perform {
            let jobs = try controller.jobs()
            sheet = TranscriptPaneSheet("Transcription Jobs") {
                TranscriptJobList(controller: controller, stored: jobs, label: jobLabel, retry: showRetry)
            }
        }
    }
}

/// The jobs sheet while it is open. A sheet's content is built once, so the list watches
/// the controller itself for the running job's track states and messages.
struct TranscriptJobList: View {
    @ObservedObject var controller: LiveTranscriptController
    let stored: [TranscriptJobRecord]
    let label: (TranscriptJobState) -> String
    let retry: (TranscriptJobRecord) -> Void

    /// The stored jobs with the running job's latest record in place of its stored one.
    static func current(_ stored: [TranscriptJobRecord], live: TranscriptJobRecord?) -> [TranscriptJobRecord] {
        guard let live else { return stored }
        var jobs = stored
        if let replacing = jobs.firstIndex(where: { $0.id == live.id }) { jobs[replacing] = live }
        else { jobs.insert(live, at: 0) }
        return jobs
    }

    var body: some View {
        let jobs = Self.current(stored, live: controller.job)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if jobs.isEmpty { Text("This project has no transcription jobs.").foregroundStyle(.secondary) }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(label(job.state), value: job.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        ForEach(job.sessions.flatMap(\.tracks)) { track in
                            LabeledContent(track.name, value: track.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            if let message = track.message {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(job.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                        }
                        if controller.activeJobID == nil, [.failed, .partial, .cancelled, .interrupted, .stale].contains(job.state) {
                            Button("Retry…") { retry(job) }
                        }
                    }
                    Divider()
                }
            }
            .padding(2)
        }
        .frame(minHeight: 100, idealHeight: 290, maxHeight: 450)
    }
}

extension TranscriptPane {
    private func projectTranscriptWork() throws -> [TranscriptIndexWork] {
        try controller.state.attachments.map { attachment in
            TranscriptIndexWork(attachmentID: attachment.id, label: attachmentLabel(attachment),
                                load: try controller.prepareIndex(attachmentID: attachment.id))
        }
    }

    private var cutPlayhead: RationalTime? {
        if isMulticam { return multicam.assemblyPreview ? multicam.preview.currentTime() : nil }
        return timelineRationalTime(editor.playhead)
    }

    private func showEditorial(_ mode: TranscriptEditorialMode) {
        perform {
            let jobs = try projectTranscriptWork()
            let labels = Dictionary(uniqueKeysWithValues: jobs.map { ($0.attachmentID, $0.label) })
            let clock = space
            let current = selection.map { address($0, in: clock) }
            let playhead = cutPlayhead
            let startingText = query.isEmpty ? selectedText() : query
            sheet = TranscriptPaneSheet(mode.title) {
                TranscriptProjectIndexes(jobs: jobs) { indexes in
                    TranscriptEditorialForm(mode: mode, indexes: indexes, attachmentLabels: labels, space: clock,
                                            startingText: startingText, playhead: playhead,
                                            hasTarget: current != nil, play: { take in
                        guard let pair = passage(take) else { return }
                        playContext(pair, in: clock)
                    }, select: { take in
                        guard let pair = passage(take) else { return }
                        reveal(pair, in: clock)
                        sheet = nil
                    }, save: { take, name in
                        guard let pair = passage(take) else { throw unresolvedSelect() }
                        let location = address(pair, in: clock)
                        _ = try controller.correct(.namedSelect(name: name), selection: location, attachmentID: location.attachmentID)
                    }, addToOrdered: { take in
                        guard let pair = passage(take),
                              let index = indexes.first(where: { $0.attachment?.id == pair.first.attachmentID }) else { return }
                        appendOrdered(pair, in: clock, index: index)
                    }, review: { action, takes, policy in
                        let selections = try takes.map { take in
                            guard let pair = passage(take) else { throw unresolvedSelect() }
                            return address(pair, in: clock)
                        }
                        let request = TranscriptEditRequest(action: action, selections: selections, target: current,
                                                            position: playhead, boundaryPolicy: policy)
                        try await review(request, name: "")
                    })
                }
            }
        }
    }

    private func passage(_ take: TranscriptTake) -> TranscriptTimeSelection? {
        guard let first = take.words.first, let last = take.words.last else { return nil }
        return .init(first: first, last: last)
    }

    private func unresolvedSelect() -> CutError {
        CutError(code: "unresolved_transcript_select", message: "One or more passages cannot be located. Review their source attachments before continuing.")
    }

    private func showAuthored() {
        perform {
            let jobs = try projectTranscriptWork()
            let labels = Dictionary(uniqueKeysWithValues: jobs.map { ($0.attachmentID, $0.label) })
            let saved = controller.state.authoring
            let target = selection.map { address($0, in: space) }
            let playhead = cutPlayhead
            sheet = TranscriptPaneSheet("Named Selects and Corrections") {
                TranscriptProjectIndexes(jobs: jobs) { indexes in
                    let reviews = indexes.flatMap(\.authoredReview)
                    let byID = Dictionary(uniqueKeysWithValues: reviews.map { ($0.id, $0) })
                    let records = saved.flatMap { record in
                        if let reviewed = byID[record.id] { return [reviewed] }
                        return TranscriptEditorial.review(records: [record], sourceWords: [], attachmentID: record.attachmentID)
                    }
                    TranscriptAuthoredForm(records: records, attachmentLabels: labels) { action, records, policy in
                        let selections = try records.flatMap { record in
                            try record.anchors.map { anchor in
                                guard anchor.status == .resolved, let first = anchor.words.first, let last = anchor.words.last else {
                                    throw unresolvedSelect()
                                }
                                return transcriptAddress(from: first, through: last, space: .source, attachment: record.attachmentID)
                            }
                        }
                        guard !selections.isEmpty else { throw unresolvedSelect() }
                        let request = TranscriptEditRequest(action: action, selections: selections, target: target,
                                                            position: playhead, boundaryPolicy: policy)
                        try await review(request, name: "")
                    }
                }
            }
        }
    }
}

extension TranscriptPane {
    private func addToOrderedSelects() {
        guard let selection, let index else { return }
        appendOrdered(selection, in: space, index: index)
    }

    private func appendOrdered(_ selection: TranscriptTimeSelection, in clock: TranscriptSpace, index: TranscriptIndex) {
        perform {
            guard let attachment = index.attachment else { throw unresolvedSelect() }
            let words = transcriptWords(from: selection.first, through: selection.last, in: index, space: clock)
            guard !words.isEmpty else { throw unresolvedSelect() }
            let first = try TranscriptBasketEndpoint(selection.first, in: index)
            let last = try TranscriptBasketEndpoint(selection.last, in: index)
            let originalTerms = words.flatMap { TranscriptEditorial.terms($0.originalText) }
            basket.items.append(.init(title: transcriptWording(words), source: attachmentLabel(attachment), attachmentID: attachment.id,
                                      space: clock, first: first, last: last, originalTerms: originalTerms))
            status = "Added to ordered selects."
        }
    }

    private func resolveOrdered(_ items: [TranscriptOrderedSelect]) async throws -> [(TranscriptOrderedSelect, TranscriptIndex, TranscriptWordSelection)] {
        let captured = revision
        let ids = Set(items.map(\.attachmentID))
        let jobs = try projectTranscriptWork().filter { ids.contains($0.attachmentID) }
        let worker = Task.detached(priority: .userInitiated) {
            var indexes: [String: TranscriptIndex] = [:]
            for job in jobs {
                try Task.checkCancellation()
                indexes[job.attachmentID] = try job.load()
            }
            return try items.map { item -> (TranscriptOrderedSelect, TranscriptIndex, TranscriptWordSelection) in
                try Task.checkCancellation()
                guard let index = indexes[item.attachmentID] else {
                    throw CutError(code: "unresolved_transcript_select", message: "The attachment for ‘\(item.title)’ is unavailable.")
                }
                do { return (item, index, try item.resolve(in: index)) }
                catch {
                    throw CutError(code: "unresolved_transcript_select", message: "‘\(item.title)’ could not be resolved. \(error.localizedDescription)")
                }
            }
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard captured == revision else {
            throw CutError(code: "stale_transcript_plan", message: "The project changed while the ordered selects were being resolved.")
        }
        return result
    }

    private func showOrderedSelects() {
        let target = selection.map { address($0, in: space) }
        let playhead = cutPlayhead
        sheet = TranscriptPaneSheet("Ordered Selects") {
            TranscriptOrderedForm(selects: $basket.items, hasTarget: target != nil, hasPlayhead: playhead != nil, copy: { items in
                let entries = try await resolveOrdered(items)
                let quotes = try entries.map { item, index, location in
                    guard let firstID = location.firstOccurrenceID, let lastID = location.lastOccurrenceID,
                          let first = index.occurrence(id: firstID, space: item.space),
                          let last = index.occurrence(id: lastID, space: item.space) else { throw unresolvedSelect() }
                    let words = transcriptWords(from: first, through: last, in: index, space: item.space)
                    return transcriptWording(words) + "\n" + [item.source, item.space.label + " " + first.range.from.description +
                        "–" + last.range.to.description, first.streamIndex.map { "stream \($0)" },
                        first.assemblyIndex.map { "occurrence \($0 + 1)" }].compactMap { $0 }.joined(separator: " · ")
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(quotes.joined(separator: "\n\n"), forType: .string)
                status = "Copied \(quotes.count) ordered quotes and references."
            }) { action, items, policy, name in
                let resolved = try await resolveOrdered(items)
                let request = TranscriptEditRequest(action: action, selections: resolved.map { $0.2 }, target: target,
                                                    position: playhead, name: name, boundaryPolicy: policy)
                try await review(request, name: name ?? "")
            }
        }
    }
}
