import AppKit
import Combine
import MPCutCore
import SwiftUI

@MainActor
struct ParticipantInspector: View {
    private enum ScanLayout: Hashable {
        case meeting, automatic, fixed
    }

    private struct ScanSource: Equatable {
        let id: String
        let url: URL
        let identity: SourceIdentity

        init(_ position: ParticipantMonitorPosition) {
            id = position.sourceID
            url = position.media.url
            identity = position.media.identity
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.url == rhs.url && lhs.identity == rhs.identity
                && lhs.identity.changeTime == rhs.identity.changeTime
        }
    }

    private struct ReconciliationReview: Identifiable {
        let id = UUID()
        let sourceID: String
        let scan: ParticipantScanResult
        let report: ParticipantReconciliation
        let revision: ParticipantSpeakerIndexKey
    }
    private struct CoverageConfirmation {
        let sourceID: String
        let participant: ParticipantPerson
        let revision: ParticipantSpeakerIndexKey
    }

    let session: ProjectSession
    @Environment(\.openDroppedProjects) private var openProjects
    @ObservedObject private var presentation: EditorPresentation
    @State private var time = RationalTime.zero
    @State private var displayedPicture: MulticamPicturePosition?
    @State private var sequencePicture: SequenceSourcePicture?
    @State private var error: String?
    @State private var operation: EditCancellation?
    @State private var scanProgress: ParticipantScanProgress?
    @State private var status: String?
    @State private var review: ParticipantScanResult?
    @State private var resumeCheckpoint: ParticipantScanResult?
    @State private var scannedSource: ScanSource?
    @State private var scannedLayout: ParticipantFeedLayout?
    @State private var inspectorSource: ScanSource?
    @State private var scanLayout = ScanLayout.meeting
    @State private var scanColumns = "2"
    @State private var scanRows = "2"
    @State private var speakerCatalog: (revision: ParticipantSpeakerIndexKey, options: [SpeakerOption])?
    @State private var suggestedBindings: SuggestedBindings?
    @State private var rangeStart = ""
    @State private var rangeEnd = ""
    @State private var personName = ""
    @State private var showingComposition = false
    @State private var reconciliation: ReconciliationReview?
    @State private var coverageConfirmation: CoverageConfirmation?
    @State private var reviewedBoundary: RationalTime?
    @State private var boundarySourceID: String?

    private struct SuggestionsKey: Equatable {
        let revision: ParticipantSpeakerIndexKey
        let mediaRevision: UInt64
        let participantID: String
        let speakersReady: Bool
    }

    private struct SuggestedBindings {
        let key: SuggestionsKey
        let audio: [AudioMatch]
        let speakers: [SpeakerOption]
        let duplicateParticipantName: Bool
    }

    private struct SpeakerOption {
        let binding: ParticipantSpeakerBinding
        let name: String
        var label: String { "\(name) · \(binding.attachmentID)" }
    }

    private struct AudioMatch {
        let label: String
        let binding: ParticipantAudioBinding
    }

    private var speakerOptions: [SpeakerOption] {
        guard let speakerCatalog, speakerCatalog.revision == ParticipantSpeakerIndexKey(session: session) else { return [] }
        return speakerCatalog.options
    }

    private func suggestionsKey(for person: ParticipantPerson) -> SuggestionsKey {
        let revision = ParticipantSpeakerIndexKey(session: session)
        return .init(revision: revision, mediaRevision: session.isMulticam ? session.multicam.transcriptMediaRevision : 0,
                     participantID: person.id, speakersReady: speakerCatalog?.revision == revision)
    }
    init(session: ProjectSession) {
        self.session = session
        _presentation = ObservedObject(wrappedValue: session.presentation)
    }

    private var project: ParticipantProject { session.participantProject }
    private var position: ParticipantMonitorPosition? {
        session.participantPosition(displaying: displayedPicture, sequence: sequencePicture)
    }
    private var displayedSource: ScanSource? { position.map(ScanSource.init) }
    private var showsScan: Bool {
        scannedSource != nil && scannedSource == displayedSource && scannedLayout == feedLayout
    }
    private var staleGeometry: Bool { position?.needsReconciliation(in: project) == true }
    private var source: ParticipantSourceGeometry? { position.flatMap { current in project.sources.first { $0.sourceID == current.sourceID } } }
    private var selectedPerson: ParticipantPerson? { project.people.first { $0.id == presentation.pinnedParticipant } }
    private var selectedRegion: ParticipantAppearance? {
        guard !staleGeometry, let position, let picked = presentation.pickedParticipantAppearance,
              picked.sourceID == position.sourceID else { return nil }
        return session.participantGeometry(for: picked.sourceID)?.appearances(at: position.time).first { $0.id == picked.appearanceID }
    }

    private var busy: Bool { operation != nil || (session.isMulticam ? session.multicam.isBusy : session.editor.isBusy) }

    var body: some View {
        VStack(spacing: 0) {
            if !session.isMulticam {
                HStack {
                    Text("Feeds & Participants").font(.headline)
                    Spacer()
                    PanelDockToggle()
                }
                .padding(10)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    analysis
                    Divider()
                    roster
                    if let selectedPerson { bindings(selectedPerson).id(selectedPerson.id) }
                    Divider()
                    geometry
                    Divider()
                    Button("Composition and Export…", systemImage: "rectangle.split.2x1") { showingComposition = true }
                        .disabled(busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .onReceive(session.participantPlayback.receive(on: DispatchQueue.main)) { time = $0 }
        .onReceive(session.multicam.preview.$picture.receive(on: DispatchQueue.main)) { picture in
            if session.isMulticam, displayedPicture != picture { displayedPicture = picture }
        }
        .onReceive(session.editor.preview.sourcePicture) { picture in
            if !session.isMulticam, sequencePicture != picture { sequencePicture = picture }
        }
        .onChange(of: time) { _, _ in discardOutdatedDrawing() }
        .onChange(of: displayedPicture) { _, _ in discardOutdatedDrawing() }
        .onChange(of: sequencePicture) { _, _ in discardOutdatedDrawing() }
        .onChange(of: displayedSource, initial: true) { _, selection in
            if let selection, inspectorSource != selection {
                inspectorSource = selection
                let savedLayout = scannedSource == selection ? scannedLayout : nil
                restoreScanLayout(savedLayout ?? source?.feedLayout ?? .meeting)
            }
            updateScanPreview()
        }
        .onChange(of: feedLayout) { _, _ in updateScanPreview() }
        .onChange(of: presentation.pinnedParticipant) { _, _ in personName = selectedPerson?.name ?? "" }
        .onChange(of: presentation.pickedParticipantAppearance) { _, _ in resetScope() }
        .onChange(of: presentation.participantDrawnBounds) { _, drawn in
            if drawn != nil, selectedRegion == nil { resetScope() }
        }
        .onAppear { personName = selectedPerson?.name ?? ""; resetScope() }
        .onDisappear {
            if let pending = operation {
                pending.cancel()
                operation = nil
                if let resumeCheckpoint {
                    review = resumeCheckpoint
                    self.resumeCheckpoint = nil
                }
                scanProgress = nil
                status = nil
            }
            presentation.participantScanPreview = nil
            presentation.participantDrawMode = false
            presentation.participantDrawnBounds = nil
        }
        .task(id: ParticipantSpeakerIndexKey(session: session)) {
            let revision = ParticipantSpeakerIndexKey(session: session)
            var values: [SpeakerOption] = []
            for attachment in session.transcript.state.attachments {
                guard let index = try? await session.transcript.indexedTranscript(attachmentID: attachment.id) else { continue }
                values += index.speakers.map { speaker in
                    .init(binding: .init(attachmentID: attachment.id, speakerID: speaker.id), name: speaker.name)
                }
            }
            if !Task.isCancelled, revision == ParticipantSpeakerIndexKey(session: session) {
                speakerCatalog = (revision, values)
            }
        }
        .sheet(isPresented: $showingComposition) {
            ParticipantCompositionSheet(session: session, openProject: { _ = openProjects([$0]) })
        }
        .sheet(item: $reconciliation) { review in
            reconciliationSheet(review)
        }
        .confirmationDialog("Confirm Reviewed Coverage", isPresented: Binding(
            get: { coverageConfirmation != nil }, set: { if !$0 { coverageConfirmation = nil } }
        ), presenting: coverageConfirmation) { confirmation in
            Button("Confirm Coverage") { confirmCoverage(confirmation) }
        } message: { confirmation in
            Text("Confirm every appearance, nameplate, and absence of \(confirmation.participant.name) across this source.")
        }
        .alert("Participants", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var feedLayout: ParticipantFeedLayout? {
        switch scanLayout {
        case .meeting: .meeting
        case .automatic: .automatic
        case .fixed: ParticipantFeedLayout(feedLayout: "\(scanColumns)x\(scanRows)")
        }
    }

    private func restoreScanLayout(_ layout: ParticipantFeedLayout) {
        switch ParticipantAnalysis.supportsFeedLayouts ? layout : .meeting {
        case .meeting:
            scanLayout = .meeting
        case .automatic:
            scanLayout = .automatic
        case .fixed(let columns, let rows):
            scanColumns = String(columns)
            scanRows = String(rows)
            scanLayout = .fixed
        }
    }

    private var currentReview: ParticipantScanResult? {
        guard showsScan, let review, let position, review.source.matches(position.media) else { return nil }
        return review
    }

    private var resumableScan: ParticipantScanResult? {
        guard let review = currentReview, review.state == .paused || review.state == .incomplete else { return nil }
        return review
    }

    private func updateScanPreview() {
        guard let position, let review = currentReview, review.source.matches(position.media),
              let analysis = review.analysis else {
            presentation.participantScanPreview = nil
            return
        }
        presentation.participantScanPreview = (position.sourceID, review.source.stamp, analysis)
    }

    private var analysis: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Source Analysis")
            if let position {
                Text(position.media.url.lastPathComponent).font(.callout).lineLimit(1)
                if staleGeometry {
                    Label("The recording has changed since participant geometry was accepted. Saved geometry needs reconciliation.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Source \(position.time.description) s · \((session.participantGeometry(for: position.sourceID)?.coverage(at: position.time) ?? .unknown).rawValue.capitalized) coverage")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Park the playhead on a source picture to inspect its feeds.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if ParticipantAnalysis.supportsFeedLayouts {
                Picker("Scan Layout", selection: $scanLayout) {
                    Text("Meeting").tag(ScanLayout.meeting)
                    Text("Automatic Feeds").tag(ScanLayout.automatic)
                    Text("Fixed Feed Grid").tag(ScanLayout.fixed)
                }
                .disabled(busy)
                if scanLayout == .fixed {
                    HStack {
                        Text("Columns")
                        TextField("Feed columns", text: $scanColumns, prompt: Text("2"))
                            .labelsHidden()
                        Text("Rows")
                        TextField("Feed rows", text: $scanRows, prompt: Text("2"))
                            .labelsHidden()
                    }
                    .disabled(busy)
                    if feedLayout == nil {
                        Text("Enter positive columns and rows for a grid of up to 64 feeds.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(resumableScan != nil ? "Resume Scan" : scanLayout == .meeting ? "Scan Participants" : "Scan Feeds",
                       systemImage: "viewfinder", action: scan)
                    .disabled(busy || position == nil || !ParticipantAnalysis.isAvailable || feedLayout == nil)
                if let operation {
                    Button("Cancel", role: .cancel) { operation.cancel() }
                }
            }
            if !ParticipantAnalysis.isAvailable {
                Text("This build can edit participant geometry manually. TileTrail is required to scan recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let scanProgress, let scannedSource, showsScan || operation != nil {
                let stage = scanStatusLabel(scanProgress.phase)
                let label = showsScan ? stage : "\(stage) · \(scannedSource.url.lastPathComponent)"
                HStack {
                    Text(label)
                    Spacer()
                    Text("\(scanProgress.percent)%").monospacedDigit()
                }
                .font(.caption)
                ProgressView(value: Double(scanProgress.percent), total: 100)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(label)
                    .accessibilityValue("\(scanProgress.percent)%")
            } else if let status, operation != nil { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let review = currentReview {
                let count = review.analysis?.appearances.count ?? 0
                Text("\(count) detected appearances").font(.callout)
                if source == nil {
                    Button("Accept Geometry") { accept(review) }
                        .disabled(busy || review.analysis == nil || review.state == .paused)
                }
                if let source, staleGeometry || source.analysisIdentity != review.analysisIdentity {
                    Text("This analysis differs from the accepted geometry. Review the saved corrections before reconciling the source.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Review Reconciliation…") { reviewReconciliation(review) }
                        .disabled(busy || review.analysis == nil || review.state == .paused)
                }
                if let position, review.analysis != nil, review.source.matches(position.media) {
                    ParticipantMarkerInspector(result: review, busy: busy) { range in
                        session.seekParticipant(sourceID: position.sourceID, range: range)
                    }
                    .id(review.analysisIdentity)
                }
            }
        }
    }

    private var roster: some View {
        let appearances = staleGeometry ? [] : position.flatMap { session.participantGeometry(for: $0.sourceID)?.appearances(at: $0.time) } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeading("Roster")
                Spacer()
                Button("Add Participant", systemImage: "person.badge.plus", action: addPerson)
                    .labelStyle(.iconOnly)
                    .disabled(busy)
            }
            if project.people.isEmpty {
                Text("Add a participant or accept detected appearances.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(project.people) { person in
                let visible = appearances.contains { $0.participantID == person.id }
                let speaking = presentation.speakingParticipants.contains(person.id)
                Button {
                    presentation.pinnedParticipant = person.id
                    presentation.pickedParticipantAppearance = staleGeometry ? nil : position.flatMap { current in
                        project.resolveAppearance(participantID: person.id, sourceID: current.sourceID, at: current.time)
                            .map { .init(sourceID: current.sourceID, appearanceID: $0.id) }
                    }
                } label: {
                    HStack {
                        Image(systemName: speaking ? "waveform" : visible ? "person.crop.rectangle" : "person")
                            .foregroundStyle(speaking ? Color.orange : Color.secondary)
                            .accessibilityHidden(true)
                        Text(person.name).lineLimit(1)
                        Spacer()
                        if speaking { Text("Speaking").foregroundStyle(.secondary).font(.caption) }
                        if !visible { Text("Offscreen").foregroundStyle(.secondary).font(.caption) }
                    }
                    .padding(5)
                    .background(presentation.pinnedParticipant == person.id ? Color.accentColor.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            if let person = selectedPerson {
                TextField("Participant name", text: $personName)
                    .onSubmit { rename(person) }
                    .disabled(busy)
                if let source, source.unresolvedParticipantIDs.contains(person.id) {
                    Button("Confirm Reviewed Coverage…") {
                        coverageConfirmation = .init(sourceID: source.sourceID, participant: person,
                                                     revision: ParticipantSpeakerIndexKey(session: session))
                    }
                    .disabled(busy || staleGeometry)
                }
                HStack {
                    Button("Previous Appearance") { navigate(direction: -1) }
                    Button("Next Appearance") { navigate(direction: 1) }
                }
                .disabled(position == nil || staleGeometry)
                if person.speakers.count == 1, let binding = person.speakers.first {
                    Button("Filter Transcript", systemImage: "text.alignleft") { session.showParticipantTranscript(binding) }
                } else if !person.speakers.isEmpty {
                    Menu("Filter Transcript") {
                        ForEach(person.speakers, id: \.self) { binding in
                            Button(speakerOptions.first { $0.binding == binding }?.label ?? binding.speakerID) {
                                session.showParticipantTranscript(binding)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bindings(_ person: ParticipantPerson) -> some View {
        let key = suggestionsKey(for: person)
        let suggestions = suggestedBindings?.key == key ? suggestedBindings : nil
        let audioMatches = suggestions?.audio ?? []
        let speakerMatches = suggestions?.speakers ?? []
        let ambiguousName = suggestions?.duplicateParticipantName == true
        return VStack(alignment: .leading, spacing: 7) {
            Menu {
                if !audioMatches.isEmpty {
                    Section(matchHeading(audioMatches.count, ambiguousName: ambiguousName)) {
                        ForEach(audioMatches.indices, id: \.self) { index in
                            let choice = audioMatches[index]
                            let label = audioMatches.filter { $0.label == choice.label }.count > 1
                                ? "\(choice.label) · \(choice.binding.selection?.source ?? choice.binding.laneID ?? "")"
                                : choice.label
                            Button(label) {
                                setAudio(choice.binding, for: person, reviewed: key)
                            }
                        }
                    }
                }
                Button("Unbound") { setAudio(nil, for: person, reviewed: key) }
                if let multicam = session.multicam.project, session.isMulticam {
                    ForEach(multicam.mixLanes) { lane in
                        if !audioMatches.contains(where: { $0.binding.laneID == lane.id }) {
                            Button(lane.label) {
                                setAudio(.init(laneID: lane.id), for: person, reviewed: key)
                            }
                        }
                    }
                    ForEach(multicam.sources) { source in
                        ForEach(session.multicam.media[source.id]?.audio.map(\.stream.index) ?? [], id: \.self) { stream in
                            if !audioMatches.contains(where: { $0.binding.selection == .init(source: source.id, stream: stream) }) {
                                audioBindingButton(person, sourceID: source.id, name: source.displayName, stream: stream, reviewed: key)
                            }
                        }
                    }
                } else if let position {
                    ForEach(position.media.audio.map(\.stream.index), id: \.self) { stream in
                        if !audioMatches.contains(where: { $0.binding.selection == .init(source: position.sourceID, stream: stream) }) {
                            audioBindingButton(person, sourceID: position.sourceID, name: position.media.url.lastPathComponent,
                                               stream: stream, reviewed: key)
                        }
                    }
                }
            } label: {
                Text(audioBindingLabel(person))
            }
            Menu("Bind Transcript Speakers") {
                if !speakerMatches.isEmpty {
                    Section(matchHeading(speakerMatches.count, ambiguousName: ambiguousName)) {
                        ForEach(speakerMatches, id: \.binding) { option in
                            speakerBindingButton(person, option: option, revision: key.revision)
                        }
                    }
                }
                ForEach(speakerOptions, id: \.binding) { option in
                    if !speakerMatches.contains(where: { $0.binding == option.binding }) {
                        speakerBindingButton(person, option: option, revision: key.revision)
                    }
                }
            }
            .disabled(speakerOptions.isEmpty)
        }
        .disabled(busy)
        .task(id: key) {
            guard !Task.isCancelled, key == suggestionsKey(for: person) else { return }
            let speakers = speakerOptions.filter {
                ParticipantBindingMetadata.matches(person.name, label: $0.name, kind: .speaker)
            }
            let duplicateName = project.people.contains {
                $0.id != person.id && ParticipantBindingMetadata.matches(person.name, label: $0.name, kind: .speaker)
            }
            suggestedBindings = .init(key: key, audio: suggestedAudio(for: person),
                                      speakers: speakers, duplicateParticipantName: duplicateName)
        }
    }

    private func matchHeading(_ count: Int, ambiguousName: Bool) -> String {
        if ambiguousName { return "Shared Participant Name · Confirm Match" }
        return count == 1 ? "Suggested Name Match" : "Multiple Name Matches"
    }

    private func suggestedAudio(for person: ParticipantPerson) -> [AudioMatch] {
        func matches(_ label: String) -> Bool {
            ParticipantBindingMetadata.matches(person.name, label: label, kind: .audio)
        }
        func streams(sourceID: String, name: String, media: MediaInfo) -> [AudioMatch] {
            guard matches(name) || matches(media.url.deletingPathExtension().lastPathComponent) else { return [] }
            return media.audio.map { track in
                let stream = track.stream.index
                return .init(label: "\(name) · Stream \(stream)",
                             binding: .init(selection: .init(source: sourceID, stream: stream)))
            }
        }
        if let multicam = session.multicam.project, session.isMulticam {
            let lanes = multicam.mixLanes.filter { matches($0.label) }.map {
                AudioMatch(label: $0.label, binding: .init(laneID: $0.id))
            }
            return lanes + multicam.sources.flatMap { source in
                session.multicam.media[source.id].map {
                    streams(sourceID: source.id, name: source.displayName, media: $0)
                } ?? []
            }
        }
        let mediaByPath = Dictionary(session.editor.analysisSourceMedia.values.map { ($0.url.path, $0) },
                                     uniquingKeysWith: { first, _ in first })
        return mediaByPath.keys.sorted().flatMap { path in
            mediaByPath[path].map {
                streams(sourceID: path, name: $0.url.lastPathComponent, media: $0)
            } ?? []
        }
    }

    private func speakerBindingButton(_ person: ParticipantPerson, option: SpeakerOption,
                                      revision: ParticipantSpeakerIndexKey) -> some View {
        let binding = option.binding
        let alreadyLinked = person.speakers.contains(binding)
        let other = project.people.first { $0.id != person.id && $0.speakers.contains(binding) }
        let matchingNameCount = speakerOptions.filter { $0.label == option.label }.count
        let name = matchingNameCount > 1 ? "\(option.label) · \(binding.speakerID)" : option.label
        let label = other.map { "\(name) · Linked to \($0.name)" } ?? name
        return Button {
            guard revision == ParticipantSpeakerIndexKey(session: session),
                  speakerCatalog?.revision == revision, presentation.pinnedParticipant == person.id else { return }
            update(person, action: "Bind Participant Speaker") {
                if alreadyLinked { $0.speakers.removeAll { $0 == binding } }
                else { $0.speakers.append(binding) }
            }
        } label: {
            if alreadyLinked { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
        .disabled(other != nil)
    }

    private func audioBindingLabel(_ person: ParticipantPerson) -> String {
        if let laneID = person.audio?.laneID {
            let name = session.multicam.project?.mixLanes.first { $0.id == laneID }?.label ?? laneID
            return "Audio · \(name)"
        }
        if let selection = person.audio?.selection {
            let name = session.multicam.project?.sources.first { $0.id == selection.source }?.displayName
                ?? URL(fileURLWithPath: selection.source).lastPathComponent
            return "Audio · \(name), stream \(selection.stream)"
        }
        return "Bind Audio"
    }

    private func audioBindingButton(_ person: ParticipantPerson, sourceID: String, name: String,
                                    stream: Int, reviewed: SuggestionsKey) -> some View {
        Button("\(name) · Stream \(stream)") {
            setAudio(.init(selection: .init(source: sourceID, stream: stream)), for: person, reviewed: reviewed)
        }
    }

    private func setAudio(_ binding: ParticipantAudioBinding?, for person: ParticipantPerson, reviewed: SuggestionsKey) {
        guard presentation.pinnedParticipant == person.id, suggestionsKey(for: person) == reviewed else { return }
        update(person, action: "Bind Participant Audio") { $0.audio = binding }
    }

    private var geometry: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Source Geometry")
            HStack {
                Button(presentation.participantDrawMode ? "Cancel Drawing" : selectedRegion == nil ? "Draw Box" : "Redraw Box") {
                    session.pauseParticipantPlayback()
                    presentation.participantDrawMode.toggle()
                }
                if selectedRegion != nil && !presentation.participantDrawMode {
                    Button("New Box") {
                        session.pauseParticipantPlayback()
                        presentation.pickedParticipantAppearance = nil
                        presentation.participantDrawMode = true
                    }
                }
                Button("Next Uncertain") { navigate(direction: 1, uncertain: true) }
                    .disabled(position.flatMap { session.participantGeometry(for: $0.sourceID) }?.hasUncertainAppearance != true)
            }
            .disabled(busy || position == nil)
            HStack {
                Button("Before Reflow") { navigateBoundary(before: true) }
                Button("After Reflow") { navigateBoundary(before: false) }
                if reviewedBoundary != nil {
                    Button("Next Reflow", systemImage: "forward.end") {
                        navigateBoundary(before: false, advance: true)
                    }.labelStyle(.iconOnly)
                }
            }
            .disabled(busy || source == nil)
            if let reviewedBoundary, boundarySourceID == source?.sourceID {
                Text("Reviewing source reflow at \(reviewedBoundary.description) s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if selectedRegion != nil || presentation.participantDrawnBounds != nil {
                Text("Source time range in seconds").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("From", text: $rangeStart).accessibilityLabel("Source start time")
                    TextField("To", text: $rangeEnd).accessibilityLabel("Source end time")
                }
                if let drawn = presentation.participantDrawnBounds {
                    HStack {
                        Button(selectedRegion == nil ? "Add Appearance" : "Apply Bounds") { commitBounds(drawn) }
                            .buttonStyle(.borderedProminent)
                        Button("Discard Box") { presentation.participantDrawnBounds = nil }
                    }
                }
                if let appearance = selectedRegion, let position {
                    Menu("Link Appearance") {
                        ForEach(project.people) { person in
                            Button(person.name) {
                                change("Link Participant Appearance") {
                                    try $0.linkAppearance(sourceID: position.sourceID, appearanceID: appearance.id,
                                                          participantID: person.id, range: editRange())
                                }
                                presentation.pinnedParticipant = person.id
                            }
                        }
                    }
                    .disabled(appearance.state == .presentation || project.people.isEmpty)
                    HStack {
                        Button("Split Here") {
                            let id = UUID().uuidString
                            change("Split Participant Appearance") {
                                try $0.splitAppearance(sourceID: position.sourceID, appearanceID: appearance.id,
                                                       at: position.time, newAppearanceID: id)
                            }
                            presentation.pickedParticipantAppearance = .init(sourceID: position.sourceID, appearanceID: id)
                        }
                        Button("Mark Presentation") {
                            change("Mark Participant Presentation") {
                                try $0.markPresentation(sourceID: position.sourceID, appearanceID: appearance.id, range: editRange())
                            }
                        }
                    }
                    if let id = appearance.participantID {
                        Button("Use This Appearance") {
                            change("Override Participant Appearance") { next in
                                let range = try editRange()
                                next.setAppearanceOverride(.init(participantID: id, sourceID: position.sourceID,
                                                                 appearanceID: appearance.id, range: range))
                            }
                        }
                    }
                }
            }
        }
        .disabled(busy || staleGeometry)
    }

    private func scanStatusLabel(_ phase: ParticipantScanProgress.Phase) -> String {
        switch phase {
        case .preparing: "Opening recording"
        case .checkingCache: "Checking saved scan"
        case .scanning: scannedLayout == .meeting ? "Scanning participants" : "Scanning feeds"
        case .finalizing: "Finalizing scan"
        case .upToDate: "Saved scan verified"
        case .completed: "Scan complete"
        case .paused: "Scan paused"
        case .incomplete: "Scan incomplete"
        case .failed: "Scan failed"
        }
    }

    private func scan() {
        guard let position, let feedLayout, operation == nil else { return }
        let token = EditCancellation()
        let url = position.media.url
        let useSidecar = session.isMulticam ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let target = ScanSource(position)
        let partial = resumableScan
        let options = partial?.configuration.options(useSidecar: useSidecar)
            ?? .init(useSidecar: useSidecar, feedLayout: feedLayout)
        operation = token
        resumeCheckpoint = partial
        scannedSource = target
        scannedLayout = feedLayout
        scanProgress = nil
        status = "Scanning \(url.lastPathComponent)…"
        review = nil
        presentation.participantScanPreview = nil
        _ = session.sidecarWork.detached(priority: .userInitiated) {
            let result = Result {
                try ParticipantAnalysis.scanWithStatus(url, options: options, resuming: partial,
                                                      cancelled: { token.isCancelled }) { update in
                    DispatchQueue.main.async {
                        guard operation === token else { return }
                        scanProgress = update
                    }
                }
            }
            // Submit completion through the same serial queue as the status events.
            // A fast cache hit must publish its final percentage before releasing the token.
            DispatchQueue.main.async {
                guard operation === token else { return }
                operation = nil
                resumeCheckpoint = nil
                status = nil
                switch result {
                case .success(let scan):
                    guard scan.source.matches(position.media) else {
                        scanProgress = nil
                        error = "The source for \(url.lastPathComponent) changed. Refresh the recording and scan again."
                        return
                    }
                    review = scan
                    updateScanPreview()
                case .failure(let failure):
                    if token.isCancelled {
                        review = partial
                        updateScanPreview()
                    } else {
                        error = "\(url.lastPathComponent): \(failure.localizedDescription)"
                    }
                }
            }
        }
    }

    private func accept(_ review: ParticipantScanResult) {
        guard showsScan, let position, review.source.matches(position.media) else { return }
        let sourceID = position.sourceID
        applyScan(review, sourceID: sourceID)
    }

    private func reviewReconciliation(_ scan: ParticipantScanResult) {
        guard showsScan, let sourceID = scannedSource?.id, operation == nil else { return }
        let revision = ParticipantSpeakerIndexKey(session: session)
        let saved = project
        let token = EditCancellation()
        operation = token
        scanProgress = nil
        status = "Preparing reconciliation…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try saved.reconciliation(for: scan, sourceID: sourceID) }
            }.value
            guard operation === token else { return }
            operation = nil
            status = nil
            guard !token.isCancelled, revision == ParticipantSpeakerIndexKey(session: session),
                  showsScan else { return }
            switch outcome {
            case .success(let report):
                reconciliation = .init(sourceID: sourceID, scan: scan, report: report, revision: revision)
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    private func reconciliationSheet(_ review: ReconciliationReview) -> some View {
        let current = showsScan && ParticipantSpeakerIndexKey(session: session) == review.revision
        let report = review.report
        return VStack(alignment: .leading, spacing: 12) {
            Text("Reconcile Participant Geometry").font(.headline)
            Text(URL(fileURLWithPath: review.scan.source.file).lastPathComponent).font(.callout)
            if report.retainedCopiedGeometry {
                Text("This copy matches the original recording. Saved geometry, assignments, and masks will be kept.")
            }
            if report.sourceChanged { Text("The source recording changed.") }
            if !report.retainedCopiedGeometry {
                Text("\(report.removedAppearanceIDs.count) saved appearances and \(report.removedOverrideCount) overrides will be removed.")
            }
            if !report.affectedParticipantIDs.isEmpty {
                let names = project.people.filter { report.affectedParticipantIDs.contains($0.id) }.map(\.name)
                Text("Review assignments for \(names.joined(separator: ", ")).")
            }
            if !report.affectedBindingIDs.isEmpty {
                Text("\(report.affectedBindingIDs.count) participants have existing audio or transcript bindings.")
            }
            if !report.affectedRedactionIDs.isEmpty {
                Text("Recheck \(report.affectedRedactionIDs.count) participant masks before publishing.")
            }
            if !report.affectedPresentationIDs.isEmpty {
                Text("Review slots referencing \(report.affectedPresentationIDs.count) replaced presentation appearances.")
            }
            if !current { Text("The project changed. Close this review and open it again.") }
            HStack {
                Spacer()
                Button("Cancel") { reconciliation = nil }.keyboardShortcut(.cancelAction)
                Button(report.retainedCopiedGeometry ? "Confirm Copied Recording" : "Replace Geometry") {
                    applyReconciliation(review)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!current || busy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func applyReconciliation(_ review: ReconciliationReview) {
        guard showsScan, ParticipantSpeakerIndexKey(session: session) == review.revision else { return }
        reconciliation = nil
        applyScan(review.scan, sourceID: review.sourceID, reviewed: review.report)
    }

    private func applyScan(_ scan: ParticipantScanResult, sourceID: String, reviewed: ParticipantReconciliation? = nil) {
        guard operation == nil else { return }
        let revision = ParticipantSpeakerIndexKey(session: session)
        let original = session.transcript.project
        let recording = URL(fileURLWithPath: scan.source.file)
        let url = (session.isMulticam ? session.multicam.projectURL : session.editor.projectURL) ?? recording
        let action = reviewed == nil ? "Accept Participant Geometry" : "Reconcile Participant Geometry"
        let token = EditCancellation()
        operation = token
        scanProgress = nil
        status = "Verifying participant geometry…"
        Task {
            let result = await session.sidecarWork.detached(priority: .userInitiated) {
                Result { () -> (ParticipantProject, SourceIdentity) in
                    let identity = try SourceIdentity(recording)
                    var document = original
                    if let reviewed {
                        try document.reconcileParticipantAnalysis(scan, sourceID: sourceID, relativeTo: url,
                                                                  reviewed: reviewed, cancelled: { token.isCancelled })
                    } else {
                        try document.acceptParticipantAnalysis(scan, sourceID: sourceID, relativeTo: url,
                                                               cancelled: { token.isCancelled })
                    }
                    return (document.participants, identity)
                }
            }.value
            guard operation === token else { return }
            operation = nil
            status = nil
            guard !token.isCancelled else { return }
            do {
                let (next, identity) = try result.get()
                guard revision == ParticipantSpeakerIndexKey(session: session), identity.isCurrentSnapshot(at: recording) else {
                    throw CutError(code: "stale_participant_review", message: "The project or recording changed. Review the scan again.")
                }
                try session.commitParticipants(next, action: action)
                presentation.participantScanPreview = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func confirmCoverage(_ confirmation: CoverageConfirmation) {
        guard ParticipantSpeakerIndexKey(session: session) == confirmation.revision else { return }
        change("Confirm Participant Coverage") {
            try $0.confirmReconciledParticipant(sourceID: confirmation.sourceID, participantID: confirmation.participant.id)
        }
    }

    private func change(_ action: String, _ update: (inout ParticipantProject) throws -> Void) {
        var next = project
        do {
            try update(&next)
            try session.commitParticipants(next, action: action)
        } catch { self.error = error.localizedDescription }
    }

    private func update(_ person: ParticipantPerson, action: String, _ mutation: (inout ParticipantPerson) -> Void) {
        change(action) { next in
            guard let index = next.people.firstIndex(where: { $0.id == person.id }) else { return }
            mutation(&next.people[index])
        }
    }

    private func addPerson() {
        let id = UUID().uuidString
        change("Add Participant") { $0.people.append(.init(id: id, name: "Participant \($0.people.count + 1)")) }
        presentation.pinnedParticipant = id
    }

    private func rename(_ person: ParticipantPerson) {
        update(person, action: "Rename Participant") { $0.name = personName.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func resetScope() {
        rangeStart = selectedRegion?.range.from.description ?? position?.time.description ?? ""
        rangeEnd = selectedRegion?.range.to.description ?? position?.duration.description ?? ""
    }

    private func editRange() throws -> MulticamRange {
        let from = try RationalTime(parsing: rangeStart)
        let to = try RationalTime(parsing: rangeEnd)
        guard from >= .zero, from < to, let position, to <= position.duration else {
            throw CutError(code: "invalid_participant_range", message: "Choose a nonempty range within the source recording.")
        }
        return .init(from: from, to: to)
    }

    private func commitBounds(_ drawn: ParticipantDrawnBounds) {
        guard let position, position.sourceID == drawn.sourceID, position.time == drawn.time,
              !position.needsReconciliation(in: project) else { return }
        change(selectedRegion == nil ? "Add Participant Appearance" : "Correct Participant Bounds") { next in
            let range = try editRange()
            if let selectedRegion {
                try next.correctBounds(sourceID: drawn.sourceID, appearanceID: selectedRegion.id, bounds: drawn.bounds, range: range)
            } else {
                let appearance = ParticipantAppearance(id: UUID().uuidString,
                                                       participantID: selectedPerson?.id, range: range, bounds: drawn.bounds)
                if let index = next.sources.firstIndex(where: { $0.sourceID == drawn.sourceID }) {
                    next.sources[index].appearances.append(appearance)
                } else {
                    next.sources.append(.init(sourceID: drawn.sourceID, media: position.media, appearances: [appearance]))
                }
            }
        }
        if error == nil { presentation.participantDrawnBounds = nil }
    }

    private func discardOutdatedDrawing() {
        if let drawn = presentation.participantDrawnBounds,
           drawn.sourceID != position?.sourceID || drawn.time != position?.time || staleGeometry {
            presentation.participantDrawnBounds = nil
        }
    }

    private func navigate(direction: Int, uncertain: Bool = false) {
        guard let source, let position else { return }
        let candidates = source.appearances.filter {
            let match = uncertain ? $0.participantID == nil && $0.state != .presentation : $0.participantID == selectedPerson?.id
            return match && (direction > 0 ? $0.range.from > position.time : $0.range.to <= position.time)
        }
        let sorted = candidates.sorted { direction > 0 ? $0.range.from < $1.range.from : $0.range.from > $1.range.from }
        guard let next = sorted.first else { return }
        session.seekParticipant(sourceID: source.sourceID, range: next.range)
        presentation.pickedParticipantAppearance = .init(sourceID: source.sourceID, appearanceID: next.id)
    }

    private func navigateBoundary(before: Bool, advance: Bool = false) {
        guard let source, let position else { return }
        let boundaries = Set(source.appearances.flatMap { [$0.range.from, $0.range.to] }).sorted()
        let selected = boundarySourceID == source.sourceID ? reviewedBoundary : nil
        let start = advance ? (selected ?? position.time) : position.time
        let held = advance ? nil : selected
        guard let boundary = held ?? boundaries.first(where: { $0 > start && $0 < position.duration }) else { return }
        reviewedBoundary = boundary
        boundarySourceID = source.sourceID
        guard let range = position.frameRange(atReflow: boundary, before: before) else { return }
        session.seekParticipant(sourceID: source.sourceID, range: range)
    }
}
