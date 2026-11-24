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
        let range: MulticamRange?
        let revision: ParticipantSpeakerIndexKey
    }

    let session: ProjectSession
    @Environment(\.openDroppedProjects) private var openProjects
    @ObservedObject private var presentation: EditorPresentation
    @State private var displayedPicture: MulticamPicturePosition?
    @State private var sequencePicture: SequenceSourcePicture?
    @State private var error: String?
    @State private var operation: EditCancellation?
    @State private var scanProgress: ParticipantScanProgress?
    @State private var status: String?
    @State private var review: ParticipantScanResult?
    @State private var choices = TilesReviewChoices()
    @State private var reviewCards: [TilesReviewCard] = []
    @State private var displayedReviewCards: [TilesReviewCard] = []
    @State private var acceptedReview: ParticipantScanResult?
    @State private var reviewStoreRevision = UUID()
    @State private var peakTiles = 0
    @State private var selectedRecordingID: String?
    @State private var showingISOExport = false
    @State private var showFind = false
    @State private var showGridCorrection = false
    @State private var showCountHints = false
    @State private var coordinateEntry: TileBoxEntry?
    @State private var galleryHint = false
    @State private var scanDetail: ParticipantSampling = .adaptive
    @State private var layoutSlots: [ParticipantSlot]?
    @State private var scannedSource: ScanSource?
    @State private var inspectorSource: ScanSource?
    @State private var scanLayout = ScanLayout.meeting
    @State private var scanColumns = "2"
    @State private var scanRows = "2"
    @State private var speakerCatalog: SpeakerCatalog?
    private enum TileExtent: String, CaseIterable {
        case tile = "This tile"
        case forward = "From here on"
        case layout = "Until next layout change"
        case recording = "Whole recording"
        case marks = "Marked range"
    }

    @State private var extent: TileExtent = .tile
    @State private var personName = ""
    @State private var reconciliation: ReconciliationReview?
    @State private var coverageConfirmation: CoverageConfirmation?

    private struct SuggestionsKey: Equatable {
        let revision: ParticipantSpeakerIndexKey
        let mediaRevision: UInt64
        let participantID: String
        let speakersReady: Bool
    }

    private struct SpeakerCatalog {
        let revision: ParticipantSpeakerIndexKey
        let options: [SpeakerOption]
        let matchedFeeds: [ParticipantSpeakerBinding: String]
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
    private var recordings: [String: MediaInfo] {
        let values = session.isMulticam
            ? session.multicam.media.filter { id, _ in session.multicam.project?.pictureSources.contains { $0.id == id && $0.feedAngle == nil } == true }
            : Dictionary(session.editor.analysisSourceMedia.values.map { ($0.url.path, $0) },
                         uniquingKeysWith: { first, _ in first })
        return values.filter { $0.value.hasVideo }
    }

    private var recording: ScanSource? {
        guard let id = selectedRecordingID ?? position?.sourceID ?? recordings.keys.sorted().first,
              let media = recordings[id] else { return nil }
        return .init(.init(sourceID: id, media: media, time: .zero))
    }

    private var displayedSource: ScanSource? { position.map(ScanSource.init) }

    private var reviewProjectURL: URL? {
        if session.isMulticam { session.multicam.projectURL ?? session.multicam.draft.url }
        else { session.editor.projectURL ?? session.editor.draft.url }
    }

    private var reviewStore: TilesPendingReviewStore? {
        guard let recording, let reviewProjectURL else { return nil }
        return .init(project: reviewProjectURL, recordingID: recording.id)
    }

    private struct ReviewLocation: Equatable {
        let project: URL?
        let recording: ScanSource?
        let acceptedAnalysis: String?
        let storeRevision: UUID
    }

    private var reviewLoadKey: ReviewLocation {
        .init(project: reviewProjectURL, recording: recording, acceptedAnalysis: source?.analysisIdentity,
              storeRevision: reviewStoreRevision)
    }

    private var currentPosition: ParticipantMonitorPosition? {
        guard position?.sourceID == recording?.id else { return nil }
        return position
    }
    private var showsScan: Bool {
        scannedSource != nil && scannedSource == recording
    }
    private var staleGeometry: Bool {
        guard let recording else { return false }
        return project.needsReconciliation(sourceID: recording.id, identity: recording.identity)
    }
    private var source: ParticipantSourceGeometry? { project.sources.first { $0.sourceID == recording?.id } }
    private var availableFeeds: [ParticipantPerson] {
        guard let source else { return [] }
        let feedIDs = session.participantFeedIDs(sourceID: source.sourceID)
        return project.people.filter { feedIDs.contains($0.id) }
    }

    private var selectedPerson: ParticipantPerson? { project.people.first { $0.id == presentation.pinnedParticipant } }
    private var selectedRegion: ParticipantAppearance? {
        guard !staleGeometry, let position = currentPosition, let picked = presentation.pickedParticipantAppearance,
              picked.sourceID == position.sourceID else { return nil }
        return session.participantGeometry(for: picked.sourceID)?.appearances(at: position.time).first { $0.id == picked.appearanceID }
    }

    private var busy: Bool { operation != nil || (session.isMulticam ? session.multicam.isBusy : session.editor.isBusy) }

    var body: some View {
        VStack(spacing: 0) {
            if !session.isMulticam {
                HStack {
                    Text("Tiles").font(.headline)
                    Spacer()
                    PanelDockToggle()
                }
                .padding(10)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    recordingPicker
                    privacyScope
                    if let review = currentReview {
                        checkPanel(review)
                    } else if source == nil || showFind {
                        if source == nil, layoutCameras.count >= 2 { layoutControls }
                        findPanel
                    } else {
                        editControls
                        if presentation.participantDrawMode || presentation.participantDrawnBounds != nil { geometry }
                        roster
                        if let recording {
                            TilesIssuesPanel(session: session, sourceID: recording.id, media: recordings[recording.id],
                                             onChangedSource: { showFind = true },
                                             onEditCountHints: { showCountHints = true },
                                             onConfirmCoverage: { feedID, range in
                                guard let feed = project.people.first(where: { $0.id == feedID }) else { return }
                                coverageConfirmation = .init(sourceID: recording.id, participant: feed, range: range,
                                                             revision: ParticipantSpeakerIndexKey(session: session))
                            })
                        }
                        if !presentation.participantDrawMode && presentation.participantDrawnBounds == nil { geometry }
                    }
                    scanStatus
                    if source != nil, currentReview == nil {
                        Divider()
                        Button("Export ISOs…", systemImage: "square.and.arrow.up") { showingISOExport = true }
                            .accessibilityIdentifier("tiles.exportISOs")
                            .disabled(busy || staleGeometry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .onReceive(session.participantPlayback.receive(on: DispatchQueue.main)) { _ in
            discardOutdatedDrawing()
        }
        .onReceive(session.multicam.preview.$picture.receive(on: DispatchQueue.main)) { picture in
            if session.isMulticam, displayedPicture != picture { displayedPicture = picture }
        }
        .onReceive(session.editor.preview.sourcePicture) { picture in
            if !session.isMulticam, sequencePicture != picture { sequencePicture = picture }
        }
        .onChange(of: displayedPicture) { _, _ in discardOutdatedDrawing() }
        .onChange(of: sequencePicture) { _, _ in discardOutdatedDrawing() }
        .onChange(of: recording, initial: true) { _, selection in
            if let selection, inspectorSource != selection {
                inspectorSource = selection
                showFind = false
                restoreScanLayout(source?.feedLayout ?? (ParticipantAnalysis.isAvailable ? .meeting : .fixed(columns: 2, rows: 2)))
            }
            updateScanPreview()
        }
        .onChange(of: recording?.id) { _, _ in layoutSlots = nil }
        .task(id: reviewLoadKey) { await loadPendingReview() }
        .onReceive(NotificationCenter.default.publisher(for: .didSaveTileReview).receive(on: DispatchQueue.main)) { event in
            guard event.object as? URL == reviewStore?.scanURL, operation == nil else { return }
            reviewStoreRevision = UUID()
        }
        .onChange(of: displayedSource) { _, _ in updateScanPreview() }
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
            var indexes: [TranscriptIndex] = []
            for attachment in session.transcript.state.attachments {
                guard let index = try? await session.transcript.indexedTranscript(attachmentID: attachment.id) else { continue }
                indexes.append(index)
                values += index.speakers.map { speaker in
                    .init(binding: .init(attachmentID: attachment.id, speakerID: speaker.id), name: speaker.name)
                }
            }
            if !Task.isCancelled, revision == ParticipantSpeakerIndexKey(session: session) {
                let matches = session.isMulticam ? session.multicam.project.map {
                    TileFeedAttachments.voices(in: $0, indexes: indexes)
                } ?? [:] : [:]
                speakerCatalog = .init(revision: revision, options: values, matchedFeeds: matches)
            }
        }
        .sheet(item: $coordinateEntry) { entry in
            TilesBoxEntrySheet(entry: entry) { proposed in
                extent = .tile
                presentation.participantDrawMode = false
                presentation.participantDrawnBounds = proposed
                if selectedRegion == nil { resetScope() }
            }
        }
        .sheet(isPresented: $showGridCorrection) { gridCorrection }
        .sheet(isPresented: $showCountHints) {
            if let source {
                TilesCountHintsSheet(hints: source.countHints) { hints in
                    change("Set Tile Count Hints") { try $0.setTileCountHints(sourceID: source.sourceID, hints: hints) }
                }
            }
        }
        .sheet(isPresented: $showingISOExport) {
            if let recording {
                TilesISOExportSheet(session: session, recordingID: recording.id, recordingName: recording.url.lastPathComponent,
                                    openProject: { _ = openProjects([$0]) })
            }
        }
        .sheet(item: $reconciliation) { review in
            reconciliationSheet(review)
        }
        .confirmationDialog("Confirm Reviewed Footage", isPresented: Binding(
            get: { coverageConfirmation != nil }, set: { if !$0 { coverageConfirmation = nil } }
        ), presenting: coverageConfirmation) { confirmation in
            Button("Confirm Footage") { confirmCoverage(confirmation) }
        } message: { confirmation in
            let scope = confirmation.range.map { "from \(formattedSeconds($0.from.seconds)) to \(formattedSeconds($0.to.seconds))" }
                ?? "in the whole recording"
            Text("Confirm that you reviewed every tile and name label for \(confirmation.participant.name) \(scope).")
        }
        .alert("Tiles", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var feedLayout: ParticipantFeedLayout? {
        switch scanLayout {
        case .meeting:
            if galleryHint, let columns = UInt32(scanColumns), let rows = UInt32(scanRows) {
                let hint = ParticipantFeedLayout.gallery(columns: columns, rows: rows)
                return hint.isValid ? hint : nil
            }
            return galleryHint ? nil : .meeting
        case .automatic: return .automatic
        case .fixed: return ParticipantFeedLayout(feedLayout: "\(scanColumns)x\(scanRows)")
        }
    }

    private func restoreScanLayout(_ layout: ParticipantFeedLayout) {
        galleryHint = false
        switch layout {
        case .meeting:
            scanLayout = ParticipantAnalysis.isAvailable ? .meeting : .fixed
        case .gallery(let columns, let rows):
            scanColumns = String(columns)
            scanRows = String(rows)
            scanLayout = ParticipantAnalysis.isAvailable ? .meeting : .fixed
            galleryHint = ParticipantAnalysis.supportsGalleryHint
        case .automatic:
            if ParticipantAnalysis.supportsFeedLayouts { scanLayout = .automatic }
            else { scanLayout = ParticipantAnalysis.isAvailable ? .meeting : .fixed }
        case .fixed(let columns, let rows):
            scanColumns = String(columns)
            scanRows = String(rows)
            scanLayout = .fixed
        }
    }

    private func canFind(using layout: ParticipantFeedLayout) -> Bool {
        switch layout {
        case .meeting: ParticipantAnalysis.isAvailable
        case .automatic: ParticipantAnalysis.supportsFeedLayouts
        case .gallery: ParticipantAnalysis.supportsGalleryHint
        case .fixed: true
        }
    }

    private var currentReview: ParticipantScanResult? {
        guard showsScan, let review, let recording, let media = recordings[recording.id], review.source.matches(media) else { return nil }
        return review
    }

    private var resumableScan: ParticipantScanResult? {
        guard let review = currentReview, review.state == .paused || review.state == .incomplete else { return nil }
        return review
    }

    private func updateScanPreview() {
        guard let position = currentPosition, let review = currentReview, review.source.matches(position.media),
              let analysis = review.analysis else {
            presentation.participantScanPreview = nil
            return
        }
        presentation.participantScanPreview = .init(sourceID: position.sourceID, stamp: review.source.stamp,
                                                    analysis: analysis, grids: choices.grids)
    }

    @ViewBuilder
    private var recordingPicker: some View {
        if recordings.count > 1 {
            Picker("Recording", selection: $selectedRecordingID) {
                Text("Follow Playhead").tag(nil as String?)
                    .accessibilityIdentifier("tiles.recording.follow")
                ForEach(recordings.keys.sorted(), id: \.self) { id in
                    if let media = recordings[id] { Text(media.url.lastPathComponent).tag(Optional(id))
                        .accessibilityIdentifier("tiles.recording.\(id)") }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("tiles.recording")
        }
        if let recording {
            Text(recording.url.lastPathComponent).font(.headline).lineLimit(1)
                .accessibilityIdentifier("participant.scan.source")
        }
    }

    @ViewBuilder
    private var privacyScope: some View {
        let media = recordings
        let unscanned = project.unscannedTileRecordingIDs(in: media)
        if !unscanned.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Feed treatments follow the tiles assigned to those feeds. These recordings have no saved scan.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(unscanned, id: \.self) { id in
                        if let file = media[id]?.url {
                            Button(file.lastPathComponent) { selectedRecordingID = id }
                                .buttonStyle(.plain)
                                .help(file.path)
                        }
                    }
                }
            } label: {
                Label("Unscanned Recordings (\(unscanned.count))", systemImage: "exclamationmark.triangle")
            }
            .accessibilityIdentifier("tiles.privacy.unscanned")
            .disabled(busy)
        }
    }

    private var findPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Find Tiles")
            Text("What is in this recording?")
            if recording != nil {
                Picker("Recording layout", selection: $scanLayout) {
                    if ParticipantAnalysis.isAvailable {
                        Text("Video Call").tag(ScanLayout.meeting)
                            .accessibilityIdentifier("participant.scan.layout.meeting")
                    }
                    if ParticipantAnalysis.supportsFeedLayouts {
                        Text("Camera Multiview").tag(ScanLayout.automatic)
                            .accessibilityIdentifier("participant.scan.layout.automatic")
                    }
                    Text("Even Grid").tag(ScanLayout.fixed)
                        .accessibilityIdentifier("participant.scan.layout.fixed")
                }
                .accessibilityIdentifier("participant.scan.layout")
                if scanLayout == .meeting && ParticipantAnalysis.supportsGalleryHint {
                    Toggle("Use a Gallery Hint", isOn: $galleryHint)
                }
                if scanLayout == .fixed || scanLayout == .meeting && galleryHint { gridDimensions }
                if scanLayout != .fixed {
                    DisclosureGroup("Scan Options") {
                        Picker("Scan Detail", selection: $scanDetail) {
                            Text("Adaptive").tag(ParticipantSampling.adaptive)
                            Text("Every Frame").tag(ParticipantSampling.everyFrame)
                            Text("Sampled").tag(ParticipantSampling.sparse)
                        }
                        .accessibilityIdentifier("tiles.scan.detail")
                    }
                }
                Button("Find Tiles", systemImage: "viewfinder", action: scan)
                    .accessibilityIdentifier("participant.scan.start")
                    .disabled(busy || feedLayout == nil)
                if !presentation.participantDrawMode && presentation.participantDrawnBounds == nil {
                    Menu("Draw Tiles by Hand") {
                        Button("Draw on the Picture") {
                            presentation.participantMonitorSource = true
                            session.pauseParticipantPlayback()
                            presentation.participantDrawMode = true
                        }
                        Button("Enter Box Coordinates…", action: enterBoxCoordinates)
                    }
                    .disabled(busy || currentPosition == nil || staleGeometry)
                }
                if currentPosition == nil {
                    Text("Park the playhead on this recording to draw tiles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if presentation.participantDrawMode || presentation.participantDrawnBounds != nil { geometry }
            } else {
                Text("Add a recording to find or draw tiles.").font(.caption).foregroundStyle(.secondary)
            }
            if showFind && source != nil {
                Button("Back to Feeds") { showFind = false }.disabled(busy)
            }
        }
        .disabled(busy)
    }

    private var gridDimensions: some View {
        HStack {
            TextField("Columns", text: $scanColumns).frame(maxWidth: 105)
                .accessibilityIdentifier("participant.scan.columns")
            TextField("Rows", text: $scanRows).frame(maxWidth: 105)
                .accessibilityIdentifier("participant.scan.rows")
        }
    }

    @ViewBuilder
    private var scanStatus: some View {
        if let scanProgress, let scannedSource, showsScan || operation != nil {
            let stage = scanStatusLabel(scanProgress.phase)
            let label = showsScan ? stage : "\(stage) · \(scannedSource.url.lastPathComponent)"
            HStack {
                Text(label)
                Spacer()
                Text("\(scanProgress.percent)%").monospacedDigit()
                    .accessibilityIdentifier("participant.scan.percent")
            }.font(.caption)
            ProgressView(value: Double(scanProgress.percent), total: 100)
                .accessibilityLabel(label)
                .accessibilityValue("\(scanProgress.percent)%")
                .accessibilityIdentifier("participant.scan.progress")
        } else if let status, operation != nil {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        if let operation { Button("Cancel", role: .cancel) { operation.cancel() } }
    }

    private func checkPanel(_ scan: ParticipantScanResult) -> some View {
        let cards = displayedReviewCards
        let media = recording.flatMap { recordings[$0.id] }
        let usedFeedCount = cards.count { !choices.unchecked.contains($0.id) }
        let feedMismatch = Int(choices.expectedFeeds).map { $0 != usedFeedCount } ?? false
        let tileMismatch = Int(choices.expectedTiles).map { $0 < peakTiles } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Check Tiles")
            Text("\(cards.count) feeds in this recording · at most \(peakTiles) tiles visible at once")
                .font(.callout)
                .accessibilityIdentifier("participant.scan.appearances")
            if usedFeedCount != cards.count {
                Text("\(usedFeedCount) feeds selected").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Expected feeds", text: reviewField(\.expectedFeeds))
                    .accessibilityIdentifier("tiles.check.expectedFeeds")
                TextField("Maximum visible tiles", text: reviewField(\.expectedTiles))
                    .accessibilityIdentifier("tiles.check.maxVisible")
            }
            if feedMismatch || tileMismatch {
                Label("The detected counts differ from your hints.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(cards) { card in
                    HStack {
                        if let media { TilesReviewThumbnail(card: card, media: media) }
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Feed name", text: Binding(get: { choices.names[card.id] ?? card.name },
                                set: { value in updateChoices { $0.names[card.id] = value } }))
                            Text("On screen \(formattedSeconds(card.duration))").font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Use \(card.name)", isOn: Binding(get: { !choices.unchecked.contains(card.id) },
                            set: { checked in
                                updateChoices { if checked { $0.unchecked.remove(card.id) } else { $0.unchecked.insert(card.id) } }
                            }))
                            .labelsHidden()
                        Menu {
                            ForEach(cards.filter { $0.id != card.id }) { target in
                                Button(choices.names[target.id] ?? target.name) { mergeReview(card.id, into: target.id) }
                            }
                        } label: {
                            Label("Merge Into", systemImage: "arrow.triangle.merge")
                        }
                        .menuIndicator(.hidden)
                        .disabled(cards.count < 2)
                    }
                    .draggable(card.id)
                    .dropDestination(for: String.self) { items, _ in
                        guard let item = items.first, item != card.id, cards.contains(where: { $0.id == item }) else { return false }
                        mergeReview(item, into: card.id)
                        return true
                    }
                }
            }
            Button("Correct Grid…") { showGridCorrection = true }
                .disabled(scan.analysis == nil)
            if !choices.grids.isEmpty { Text("\(choices.grids.count) grid corrections").font(.caption) }
            if let resumableScan {
                if canFind(using: resumableScan.configuration.feedLayout) {
                    Button("Resume Find Tiles", action: self.scan).accessibilityIdentifier("participant.scan.start")
                } else {
                    Text("Discard this interrupted scan to find tiles with an available layout.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if source == nil {
                Button("Use These Tiles") { accept(scan) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("participant.scan.accept")
                    .disabled(scan.analysis == nil)
            } else {
                Button("Review Changed Recording…") { reviewReconciliation(scan) }
                    .accessibilityIdentifier("participant.reconcile.open")
                    .disabled(scan.analysis == nil)
            }
            markerFilters(scan)
            Button("Discard Scan", role: .destructive) { clearPendingReview(); showFind = source != nil }
                .accessibilityIdentifier("participant.scan.discard")
        }
        .disabled(busy)
    }

    private func reviewField(_ key: WritableKeyPath<TilesReviewChoices, String>) -> Binding<String> {
        Binding(get: { choices[keyPath: key] }, set: { value in
            updateChoices {
                $0[keyPath: key] = value
                $0.editedHints = true
            }
        })
    }

    private func updateChoices(_ edit: (inout TilesReviewChoices) -> Void) {
        edit(&choices)
        do { try reviewStore?.save(choices) }
        catch { self.error = error.localizedDescription }
    }

    private func mergeReview(_ from: String, into to: String) {
        updateChoices { $0.merge(from, into: to) }
        displayedReviewCards = TilesReviewCard.applyingMerges(choices.merged, to: reviewCards)
    }

    private func formattedSeconds(_ value: Double) -> String {
        Duration.seconds(value).formatted(.time(pattern: .minuteSecond))
    }

    private func loadPendingReview() async {
        guard let store = reviewStore, let recording, operation == nil else { return }
        let location = reviewLoadKey
        let load = Task.detached(priority: .utility) {
            Result {
                try Task.checkCancellation()
                return try store.load(recording: recording.url).map { scan, choices in
                    try Task.checkCancellation()
                    let raw = TilesReviewCard.list(scan)
                    let visible = choices.maximumVisibleTiles(in: scan, rawMaximum: raw.visible)
                    let displayed = TilesReviewCard.applyingMerges(choices.merged, to: raw.cards)
                    return (scan, choices, raw.cards, displayed, visible)
                }
            }
        }
        let result = await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
        guard !Task.isCancelled, operation == nil, reviewLoadKey == location else { return }
        do {
            guard let (scan, choices, raw, displayed, visible) = try result.get(),
                  let media = recordings[recording.id], scan.source.matches(media) else { return }
            if scan.analysisIdentity == source?.analysisIdentity, !staleGeometry {
                acceptedReview = scan
                review = nil
                updateScanPreview()
                return
            }
            restoreScanLayout(scan.configuration.feedLayout)
            scanDetail = scan.configuration.sampling
            scannedSource = recording
            review = scan
            self.choices = choices
            reviewCards = raw
            displayedReviewCards = displayed
            peakTiles = visible
            updateScanPreview()
        } catch { self.error = error.localizedDescription }
    }

    private func clearPendingReview() {
        do {
            try reviewStore?.remove()
            review = nil
            acceptedReview = nil
            reviewCards = []
            displayedReviewCards = []
            choices = .init()
            scanProgress = nil
            updateScanPreview()
        } catch { self.error = error.localizedDescription }
    }

    private var roster: some View {
        let reviewMedia = recording.flatMap { recordings[$0.id] }
        let geometry = recording.flatMap { session.participantGeometry(for: $0.id) }
        let relatedFeeds = source.map { session.participantFeedIDs(sourceID: $0.sourceID)
            .union($0.historicalParticipantIDs ?? []) } ?? []
        let treatments = project.effectiveRedactions
        let privacyApplies = !treatments.isEmpty && (project.render != nil || geometry?.hasUncertainAppearance == true
            || treatments.contains { relatedFeeds.contains($0.participantID) })
        let mayShowUntreated = !staleGeometry && (presentation.participantMonitorSource || !privacyApplies)
        let appearances = staleGeometry ? [] : currentPosition.flatMap { session.participantGeometry(for: $0.sourceID)?.appearances(at: $0.time) } ?? []
        let visibleFeedIDs = Set(appearances.lazy.compactMap(\.participantID))
        let linkedIDs = session.participantFeedIDs()
        let feeds = availableFeeds + project.people.filter { !linkedIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeading("Feeds")
                Spacer()
                Text("\(appearances.count) tiles visible · \(availableFeeds.count) feeds")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add Feed", systemImage: "person.badge.plus", action: addPerson)
                    .labelStyle(.iconOnly)
                    .disabled(busy)
            }
            if feeds.isEmpty {
                Text("Assign a tile to a feed or add a feed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(feeds) { person in
                    let visible = visibleFeedIDs.contains(person.id)
                    let speaking = presentation.speakingParticipants.contains(person.id)
                    let accessibilityStatus = [speaking ? "Speaking" : nil, visible ? nil : "Offscreen"]
                        .compactMap { $0 }.joined(separator: ", ")
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            presentation.participantMonitorSource = true
                            presentation.pinnedParticipant = person.id
                            presentation.pickedParticipantAppearance = staleGeometry ? nil : currentPosition.flatMap { current in
                                project.resolveAppearance(participantID: person.id, sourceID: current.sourceID, at: current.time)
                                    .map { .init(sourceID: current.sourceID, appearanceID: $0.id) }
                            }
                        } label: {
                            HStack {
                                if let media = reviewMedia, mayShowUntreated,
                                   let tile = geometry?.representativeTile(for: person.id) {
                                    TilesReviewThumbnail(tile: tile, media: media)
                                } else {
                                    Image(systemName: speaking ? "waveform" : visible ? "person.crop.rectangle" : "person")
                                        .foregroundStyle(speaking ? Color.orange : Color.secondary)
                                        .accessibilityHidden(true)
                                }
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
                        .accessibilityLabel(person.name)
                        .accessibilityValue(accessibilityStatus)
                        .accessibilityIdentifier("participant.roster.\(person.id)")
                        if presentation.pinnedParticipant == person.id {
                            HStack {
                                TextField("Feed name", text: $personName)
                                    .accessibilityIdentifier("participant.roster.name")
                                    .onSubmit { rename(person) }
                                Button("Rename") { rename(person) }
                            }
                            .disabled(busy)
                        }
                        HStack {
                            bindings(person)
                            treatmentMenu(person)
                            if availableFeeds.count > 1 {
                                Menu {
                                    ForEach(availableFeeds.filter { $0.id != person.id }) { target in
                                        Button(target.name) {
                                            mergeFeeds(person.id, into: target.id)
                                        }
                                    }
                                } label: {
                                    Label("Merge Feed Into", systemImage: "arrow.triangle.merge")
                                }
                                .menuIndicator(.hidden)
                                .disabled(busy)
                            }
                        }
                    }
                }
            }
            if let person = selectedPerson, feeds.contains(where: { $0.id == person.id }) {
                if let source, person.treatment != nil || source.unresolvedParticipantIDs.contains(person.id) {
                    Button("Confirm Reviewed Footage…") {
                        let hasMarks = session.isMulticam
                            ? session.multicam.displayedMarkIn != nil || session.multicam.displayedMarkOut != nil
                            : session.editor.markIn != nil || session.editor.markOut != nil
                        let range = hasMarks ? session.participantMarkedSourceRange(sourceID: source.sourceID) : nil
                        guard !hasMarks || range != nil else { error = tileRangeError.localizedDescription; return }
                        coverageConfirmation = .init(sourceID: source.sourceID, participant: person, range: range,
                                                     revision: ParticipantSpeakerIndexKey(session: session))
                    }
                    .disabled(busy || staleGeometry)
                }
                let voices = voiceBindings(for: person)
                if voices.count == 1, let binding = voices.first {
                    Button("Filter Transcript", systemImage: "text.alignleft") { session.showParticipantTranscript(binding) }
                        .accessibilityIdentifier("participant.transcript.filter")
                } else if !voices.isEmpty {
                    Menu("Filter Transcript") {
                        ForEach(voices, id: \.self) { binding in
                            Button(speakerOptions.first { $0.binding == binding }?.label ?? binding.speakerID) {
                                session.showParticipantTranscript(binding)
                            }
                        }
                    }
                }
            }
        }
    }

    private var editControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                layoutControls
                if let selectedPerson, availableFeeds.contains(where: { $0.id == selectedPerson.id }) {
                    Button("Solo") { setLayout(.solo, slots: [.init(id: selectedPerson.id)]) }
                        .accessibilityIdentifier("tiles.feed.solo")
                        .disabled(busy || currentPosition == nil || staleGeometry)
                }
                Spacer()
                Menu {
                    Button("Find Tiles Again…") { showFind = true }
                        .accessibilityIdentifier("participant.scan.find")
                    Button("Correct Grid…") { showGridCorrection = true }
                        .disabled(staleGeometry)
                    Button("Edit Tile Count Hints…") { showCountHints = true }
                        .accessibilityIdentifier("tiles.hints.edit")
                } label: {
                    Label("Tile Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("tiles.actions")
                .disabled(busy)
            }
            if let recording, !availableFeeds.isEmpty {
                Button("Use Feeds as Multicam Angles") { session.useFeedsAsMulticamAngles(sourceID: recording.id) }
                    .accessibilityIdentifier("tiles.convert")
                    .disabled(busy || staleGeometry || session.isConvertingFeedAngles)
            }
            if let acceptedReview, acceptedReview.analysisIdentity == source?.analysisIdentity {
                markerFilters(acceptedReview)
            }
        }
    }

    private var layoutControls: some View {
        Menu("Layout") {
            Button("Original") { setLayout(nil) }
                .accessibilityIdentifier("tiles.layout.original")
            if !availableFeeds.isEmpty {
                Menu("Solo") {
                    ForEach(availableFeeds) { feed in
                        Button(feed.name) { setLayout(.solo, slots: [.init(id: feed.id)]) }
                            .accessibilityIdentifier("tiles.layout.solo.\(feed.id)")
                    }
                }
            }
            Menu(layoutCameras.isEmpty ? "Choose Feeds" : "Choose Feeds and Cameras") {
                Button("Clear Selection") { layoutSlots = [] }
                    .disabled(chosenLayoutSlots.isEmpty)
                if !availableFeeds.isEmpty {
                    Section("Feeds") {
                        ForEach(availableFeeds) { feed in
                            Toggle(feed.name, isOn: layoutSelection(.init(id: feed.id)))
                                .accessibilityIdentifier("tiles.layout.choose-feed.\(feed.id)")
                        }
                    }
                }
                if !layoutCameras.isEmpty {
                    Section("Cameras") {
                        ForEach(layoutCameras) { camera in
                            Toggle(camera.displayName, isOn: layoutSelection(.init(target: .camera, id: camera.id)))
                                .accessibilityIdentifier("tiles.layout.choose-camera.\(camera.id)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("tiles.layout.choose")
            Button("Side by Side") { setLayout(.pair, slots: chosenLayoutSlots) }
                .disabled(chosenLayoutSlots.count != 2)
            Button("Grid") { setLayout(.grid, slots: chosenLayoutSlots) }
                .disabled(!(2...64).contains(chosenLayoutSlots.count))
        }
        .accessibilityIdentifier("tiles.layout")
        .disabled(busy || currentPosition == nil || staleGeometry)
    }

    private var layoutCameras: [MulticamSource] { session.isMulticam ? session.multicam.project?.angles ?? [] : [] }

    private var chosenLayoutSlots: [ParticipantSlot] {
        let feeds = availableFeeds.map { ParticipantSlot(id: $0.id) }
        let cameras = layoutCameras.map { ParticipantSlot(target: .camera, id: $0.id) }
        let available = Set(feeds + cameras)
        return layoutSlots?.filter(available.contains) ?? (feeds.isEmpty ? cameras : feeds)
    }

    private func layoutSelection(_ slot: ParticipantSlot) -> Binding<Bool> {
        Binding(get: { chosenLayoutSlots.contains(slot) }, set: { included in
            var slots = chosenLayoutSlots.filter { $0 != slot }
            if included { slots.append(slot) }
            layoutSlots = slots
        })
    }

    private func markerFilters(_ scan: ParticipantScanResult) -> some View {
        ParticipantMarkerInspector(result: scan, busy: busy) { range in
            guard let recording else { return }
            presentation.participantMonitorSource = true
            session.seekParticipant(sourceID: recording.id, range: range)
        }
        .id(scan.analysisIdentity)
    }

    private func setLayout(_ layout: ParticipantShotLayout?, slots: [ParticipantSlot] = []) {
        do {
            if session.isMulticam {
                let intended = layout ?? (session.multicam.assemblyPreview ? .original : nil)
                try session.multicam.setTileLayout(intended, slots: slots, at: session.participantTimelineTime)
            } else {
                try session.editor.setMonitorTileLayout(layout, slots: slots)
            }
            presentation.participantMonitorSource = false
        } catch { self.error = error.localizedDescription }
    }

    private func treatmentMenu(_ person: ParticipantPerson) -> some View {
        Menu {
            Button("None") { setTreatment(nil, person: person) }
            Button("Blur") { setTreatment(.blur, person: person) }
            Button("Cover") { setTreatment(.cover, person: person) }
            Button("Remove") { setTreatment(.remove, person: person) }
        } label: {
            Text(person.treatment?.mode.rawValue.capitalized ?? "Hide")
        }
        .disabled(busy)
        .accessibilityIdentifier("tiles.feed.treatment.\(person.id)")
    }

    private func mergeFeeds(_ removed: String, into surviving: String) {
        do {
            var document = session.transcript.project
            let conflicts = try document.mergeTileFeeds(removed, into: surviving)
            try session.commitTileDocument(document, action: "Merge Feeds")
            if presentation.pinnedParticipant == removed { presentation.pinnedParticipant = surviving }
            if !conflicts.isEmpty { error = conflicts.joined(separator: "\n") }
        } catch { self.error = error.localizedDescription }
    }

    private func setTreatment(_ mode: ParticipantFeedTreatment.Mode?, person: ParticipantPerson) {
        do {
            let document = try session.transcript.project.settingFeedTreatment(feedID: person.id,
                treatment: mode.map { .init(mode: $0, color: person.treatment?.color ?? 0) })
            try session.commitTileDocument(document, action: "Set Feed Treatment")
            presentation.participantMonitorSource = false
        } catch { self.error = error.localizedDescription }
    }

    private var gridCorrection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Correct Grid").font(.headline)
            Text("Mark the affected stretch in the timeline. With no marks, the correction covers the whole recording.")
                .font(.callout).foregroundStyle(.secondary)
            gridDimensions
            HStack {
                Spacer()
                Button("Cancel") { showGridCorrection = false }.keyboardShortcut(.cancelAction)
                Button("Apply Grid") { correctGrid() }.keyboardShortcut(.defaultAction)
                    .disabled(gridSize == nil)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private var gridSize: (Int, Int)? {
        guard let columns = Int(scanColumns), let rows = Int(scanRows),
              (1...64).contains(columns), (1...64).contains(rows), columns * rows <= 64 else { return nil }
        return (columns, rows)
    }

    private func correctGrid() {
        guard let recording, let media = recordings[recording.id], let (columns, rows) = gridSize else { return }
        let hasMarks = session.isMulticam
            ? session.multicam.displayedMarkIn != nil || session.multicam.displayedMarkOut != nil
            : session.editor.markIn != nil || session.editor.markOut != nil
        let duration = ParticipantMonitorPosition(sourceID: recording.id, media: media, time: .zero).duration
        let range = hasMarks ? session.participantMarkedSourceRange(sourceID: recording.id) : .init(from: .zero, to: duration)
        guard let range else { error = tileRangeError.localizedDescription; return }
        if let scan = currentReview {
            updateChoices { $0.grids.append(.init(range: range, columns: columns, rows: rows)) }
            updateScanPreview()
            let choices = self.choices
            let originalMaximum = peakTiles
            Task {
                let maximum = await Task.detached(priority: .utility) {
                    choices.maximumVisibleTiles(in: scan, rawMaximum: originalMaximum)
                }.value
                if currentReview?.analysisIdentity == scan.analysisIdentity && self.choices.grids == choices.grids {
                    peakTiles = maximum
                }
            }
        } else {
            correctAcceptedGrid(recording, range: range, columns: columns, rows: rows)
        }
        showGridCorrection = false
        presentation.participantMonitorSource = true
    }

    private func correctAcceptedGrid(_ recording: ScanSource, range: MulticamRange, columns: Int, rows: Int) {
        guard operation == nil else { return }
        do {
            let url = try session.transcript.assetContext()
            let original = session.transcript.project
            let revision = ParticipantSpeakerIndexKey(session: session)
            let token = EditCancellation()
            operation = token
            status = "Correcting grid…"
            scanProgress = nil
            error = nil
            Task {
                let result = await session.sidecarWork.detached(priority: .userInitiated) {
                    Result {
                        var document = original
                        let report = try document.correctTileGrid(sourceID: recording.id, document: url, range: range,
                            columns: columns, rows: rows, cancelled: { token.isCancelled })
                        return (document.participants, report)
                    }
                }.value
                guard operation === token else { return }
                operation = nil
                status = nil
                guard !token.isCancelled else { return }
                do {
                    let (participants, report) = try result.get()
                    guard revision == ParticipantSpeakerIndexKey(session: session),
                          recording.identity.isCurrentSnapshot(at: recording.url) else {
                        throw CutError(code: "stale_grid", message: "The project or recording changed. Review the grid again.")
                    }
                    try session.commitParticipants(participants, action: "Correct Grid")
                    if !report.unmatchedAppearanceIDs.isEmpty || report.droppedPreferenceCount > 0 {
                        error = "Review the corrected grid (\(report.unmatchedAppearanceIDs.count) unmatched tiles, \(report.droppedPreferenceCount) removed preferences)."
                    }
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func bindings(_ person: ParticipantPerson) -> some View {
        let key = suggestionsKey(for: person)
        let audioMatches = suggestedAudio(for: person)
        let speakerMatches = speakerOptions.filter { ParticipantBindingMetadata.matches(person.name, label: $0.name, kind: .speaker) }
        let ambiguousName = project.people.contains {
            $0.id != person.id && ParticipantBindingMetadata.matches(person.name, label: $0.name, kind: .speaker)
        }
        let hasAudioChoices = session.isMulticam
            ? (session.multicam.project?.mixLanes.isEmpty == false || session.multicam.media.values.contains { !$0.hasVideo && !$0.audio.isEmpty || $0.audio.count > 1 })
            : (currentPosition?.media.audio.count ?? 0) > 1
        return HStack {
            if hasAudioChoices {
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
                        ForEach(multicam.sources.filter { $0.feedAngle == nil }) { source in
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
                .accessibilityIdentifier("participant.bind.audio.\(person.id)")
            }
            if !session.transcript.state.attachments.isEmpty {
                Menu {
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
                } label: {
                    let voices = voiceBindings(for: person)
                    let name = voices.count == 1 ? speakerOptions.first { $0.binding == voices[0] }?.name : nil
                    Text(name.map { "Voice · \($0)" } ?? "Voice")
                }
                .disabled(speakerOptions.isEmpty)
                .accessibilityIdentifier("participant.bind.speakers.\(person.id)")
            }
        }
        .disabled(busy)
    }

    private func matchHeading(_ count: Int, ambiguousName: Bool) -> String {
        if ambiguousName { return "Shared Feed Name · Confirm Match" }
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

    private func voiceBindings(for person: ParticipantPerson) -> [ParticipantSpeakerBinding] {
        guard person.speakers.isEmpty, let catalog = speakerCatalog,
              catalog.revision == ParticipantSpeakerIndexKey(session: session) else { return person.speakers }
        return catalog.options.compactMap { catalog.matchedFeeds[$0.binding] == person.id ? $0.binding : nil }
    }

    private func speakerBindingButton(_ person: ParticipantPerson, option: SpeakerOption,
                                      revision: ParticipantSpeakerIndexKey) -> some View {
        let binding = option.binding
        let alreadyLinked = person.speakers.contains(binding)
        let automaticallyLinked = !alreadyLinked && voiceBindings(for: person).contains(binding)
        let other = project.people.first { $0.id != person.id && $0.speakers.contains(binding) }
        let matchingNameCount = speakerOptions.filter { $0.label == option.label }.count
        let name = matchingNameCount > 1 ? "\(option.label) · \(binding.speakerID)" : option.label
        let label = other.map { "\(name) · Linked to \($0.name)" } ?? name
        return Button {
            guard revision == ParticipantSpeakerIndexKey(session: session),
                  speakerCatalog?.revision == revision else { return }
            update(person, action: "Link Transcript Voice") {
                if alreadyLinked { $0.speakers.removeAll { $0 == binding } }
                else { $0.speakers.append(binding) }
            }
        } label: {
            if alreadyLinked { Label(label, systemImage: "checkmark") }
            else if automaticallyLinked { Label(label, systemImage: "bolt") }
            else { Text(label) }
        }
        .disabled(other != nil)
        .accessibilityIdentifier("participant.bind.speaker.\(binding.attachmentID).\(binding.speakerID)")
    }

    private func audioBindingLabel(_ person: ParticipantPerson) -> String {
        if let laneID = person.audio?.laneID {
            let name = session.multicam.project?.mixLanes.first { $0.id == laneID }?.label ?? laneID
            return "Mic · \(name)"
        }
        let inferred = session.isMulticam ? session.multicam.project.flatMap {
            TileFeedAttachments.microphone(for: person, in: $0)
        } : nil
        if let selection = person.audio?.selection ?? inferred {
            let name = session.multicam.project?.sources.first { $0.id == selection.source }?.displayName
                ?? URL(fileURLWithPath: selection.source).lastPathComponent
            return "Mic · \(name), stream \(selection.stream)"
        }
        return "Mic"
    }

    private func audioBindingButton(_ person: ParticipantPerson, sourceID: String, name: String,
                                    stream: Int, reviewed: SuggestionsKey) -> some View {
        Button("\(name) · Stream \(stream)") {
            setAudio(.init(selection: .init(source: sourceID, stream: stream)), for: person, reviewed: reviewed)
        }
        .accessibilityIdentifier("participant.bind.audio.\(sourceID).\(stream)")
    }

    private func setAudio(_ binding: ParticipantAudioBinding?, for person: ParticipantPerson, reviewed: SuggestionsKey) {
        guard suggestionsKey(for: person) == reviewed else { return }
        update(person, action: "Link Microphone") { $0.audio = binding }
    }

    private var geometry: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Tile Box")
            HStack {
                Button(presentation.participantDrawMode ? "Cancel Drawing" : selectedRegion == nil ? "Draw Tile" : "Redraw Tile") {
                    presentation.participantMonitorSource = true
                    session.pauseParticipantPlayback()
                    presentation.participantDrawMode.toggle()
                }
                if selectedRegion != nil && !presentation.participantDrawMode {
                    Button("New Box") {
                        presentation.participantMonitorSource = true
                        session.pauseParticipantPlayback()
                        presentation.pickedParticipantAppearance = nil
                        presentation.participantDrawMode = true
                    }
                }
            }
            .disabled(busy || currentPosition == nil)
            if !presentation.participantDrawMode && presentation.participantDrawnBounds == nil {
                Button("Enter Box Coordinates…", action: enterBoxCoordinates)
            }
            if selectedRegion != nil || presentation.participantDrawnBounds != nil {
                Picker("Apply to", selection: $extent) {
                    ForEach(TileExtent.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .accessibilityIdentifier("tiles.extent")
                if let drawn = presentation.participantDrawnBounds {
                    HStack {
                        Button(selectedRegion == nil ? "Add Tile" : "Apply Box") { commitBounds(drawn) }
                            .buttonStyle(.borderedProminent)
                        Button("Discard Box") { presentation.participantDrawnBounds = nil }
                    }
                }
                if let appearance = selectedRegion, let position = currentPosition {
                    Menu("Assign Feed") {
                        Button("Unassigned") {
                            change("Unassign Tile") {
                                try $0.linkAppearance(sourceID: position.sourceID, appearanceID: appearance.id,
                                                      participantID: nil, range: editRange())
                            }
                        }
                        ForEach(project.people) { person in
                            Button(person.name) {
                                change("Assign Tile") {
                                    try $0.linkAppearance(sourceID: position.sourceID, appearanceID: appearance.id,
                                                          participantID: person.id, range: editRange())
                                }
                                presentation.pinnedParticipant = person.id
                            }
                        }
                    }

                    HStack {
                        Button("Split Here") {
                            let id = UUID().uuidString
                            change("Split Tile") {
                                try $0.splitAppearance(sourceID: position.sourceID, appearanceID: appearance.id,
                                                       at: position.time, newAppearanceID: id)
                            }
                            presentation.pickedParticipantAppearance = .init(sourceID: position.sourceID, appearanceID: id)
                        }
                        Button("Screen Share") {
                            change("Mark Screen Share") {
                                let id = try $0.setScreenShare(sourceID: position.sourceID, appearanceID: appearance.id, range: editRange())
                                presentation.pinnedParticipant = id
                            }
                        }
                    }
                    if let id = appearance.participantID {
                        Button("Different Feed") { splitFeed(id, tile: appearance, position: position) }
                        Button("Prefer This Tile") {
                            change("Prefer Tile") { next in
                                try next.preferTile(sourceID: position.sourceID, feedID: id, tileID: appearance.id, range: editRange())
                            }
                        }
                        .accessibilityIdentifier("participant.appearance.use")
                    }
                }
            }
        }
        .disabled(busy || staleGeometry || currentPosition == nil)
    }

    private func splitFeed(_ feedID: String, tile: ParticipantAppearance, position: ParticipantMonitorPosition) {
        let id = ProjectIdentifier.make(avoiding: project.people.map(\.id))
        let name = "Feed \(project.people.count + 1)"
        change("Split Feed") {
            try $0.splitFeed(feedID, sourceID: position.sourceID, tileID: tile.id,
                             range: editRange(), newFeedID: id, name: name)
        }
        if error == nil { presentation.pinnedParticipant = id }
    }

    private func enterBoxCoordinates() {
        guard let position = currentPosition, !staleGeometry else { return }
        session.pauseParticipantPlayback()
        presentation.participantMonitorSource = true
        coordinateEntry = .init(sourceID: position.sourceID, time: position.time, bounds: selectedRegion?.bounds)
    }

    private func scanStatusLabel(_ phase: ParticipantScanProgress.Phase) -> String {
        switch phase {
        case .preparing: "Opening recording"
        case .checkingCache: "Checking saved scan"
        case .scanning: "Finding tiles"
        case .finalizing: "Finalizing scan"
        case .upToDate: "Saved scan verified"
        case .completed: "Scan complete"
        case .paused: "Scan paused"
        case .incomplete: "Scan incomplete"
        case .failed: "Scan failed"
        }
    }

    private func scan() {
        guard let target = recording, let feedLayout, operation == nil else { return }
        let store: TilesPendingReviewStore
        do { store = try .init(project: session.transcript.assetContext(), recordingID: target.id) }
        catch { self.error = error.localizedDescription; return }
        let token = EditCancellation()
        let url = target.url
        let useSidecar = session.isMulticam ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let partial = resumableScan
        let priorChoices = choices
        selectedRecordingID = target.id
        if !showsScan { review = nil }
        let options = partial?.configuration.options(useSidecar: useSidecar)
            ?? .init(sampling: scanLayout == .fixed ? .everyFrame : scanDetail, useSidecar: useSidecar, feedLayout: feedLayout)
        operation = token
        scannedSource = target
        scanProgress = nil
        status = "Scanning \(url.lastPathComponent)…"
        presentation.participantScanPreview = nil
        _ = session.sidecarWork.detached(priority: .userInitiated) {
            let result = Result {
                let scan = try ParticipantAnalysis.scanWithStatus(url, options: options, resuming: partial,
                                                      cancelled: { token.isCancelled }) { update in
                    DispatchQueue.main.async {
                        guard operation === token else { return }
                        scanProgress = update
                    }
                }
                guard target.identity.isCurrentSnapshot(at: url) else {
                    throw CutError(code: "stale_scan", message: "The recording changed during the scan. Find tiles again.")
                }
                try store.save(scan)
                let raw = TilesReviewCard.list(scan)
                let choices = priorChoices.analysisIdentity == scan.analysisIdentity ? priorChoices : .init(scan: scan)
                let displayed = TilesReviewCard.applyingMerges(choices.merged, to: raw.cards)
                let visible = choices.maximumVisibleTiles(in: scan, rawMaximum: raw.visible)
                return (scan, choices, raw.cards, displayed, visible)
            }
            // Submit completion through the same serial queue as the status events.
            // A fast cache hit must publish its final percentage before releasing the token.
            DispatchQueue.main.async {
                guard operation === token else { return }
                operation = nil
                status = nil
                switch result {
                case .success(let (scan, choices, raw, displayed, visible)):
                    guard let media = recordings[target.id], scan.source.matches(media) else {
                        scanProgress = nil
                        error = "The source for \(url.lastPathComponent) changed. Refresh the recording and scan again."
                        return
                    }
                    review = scan
                    self.choices = choices
                    reviewCards = raw
                    displayedReviewCards = displayed
                    peakTiles = visible
                    showFind = false
                    if recording == target { presentation.participantMonitorSource = true }
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
        guard showsScan, let recording, let media = recordings[recording.id], review.source.matches(media) else { return }
        let sourceID = recording.id
        applyScan(review, sourceID: sourceID)
    }

    private func reviewReconciliation(_ scan: ParticipantScanResult) {
        guard showsScan, let sourceID = scannedSource?.id, operation == nil else { return }
        let revision = ParticipantSpeakerIndexKey(session: session)
        let saved = project
        let token = EditCancellation()
        operation = token
        scanProgress = nil
        status = "Checking changed recording…"
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
            Text("Review Changed Recording").font(.headline)
                .accessibilityIdentifier("participant.reconcile.title")
            Text(URL(fileURLWithPath: review.scan.source.file).lastPathComponent).font(.callout)
            if report.retainedCopiedGeometry {
                Text("This copy matches the original recording. Saved boxes, assignments, and treatments will be kept.")
            }
            if report.sourceChanged { Text("The source recording changed.") }
            if !report.retainedCopiedGeometry {
                Text("\(report.removedAppearanceIDs.count) saved tiles and \(report.removedOverrideCount) preferences will be removed.")
            }
            if !report.affectedParticipantIDs.isEmpty {
                let names = project.people.filter { report.affectedParticipantIDs.contains($0.id) }.map(\.name)
                Text("Review assignments for \(names.joined(separator: ", ")).")
            }
            if !report.affectedBindingIDs.isEmpty {
                Text("\(report.affectedBindingIDs.count) feeds have a microphone or transcript voice.")
            }
            if !report.affectedRedactionIDs.isEmpty {
                Text("Recheck \(report.affectedRedactionIDs.count) feed treatments before publishing.")
            }
            if !report.affectedPresentationIDs.isEmpty {
                Text("Review cells referencing \(report.affectedPresentationIDs.count) replaced screen shares.")
            }
            if !current { Text("The project changed. Close this review and open it again.") }
            HStack {
                Spacer()
                Button("Cancel") { reconciliation = nil }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("participant.reconcile.cancel")
                Button(report.retainedCopiedGeometry ? "Confirm Copied Recording" : "Replace Tiles") {
                    applyReconciliation(review)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!current || busy)
                    .accessibilityIdentifier("participant.reconcile.apply")
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
        let url = reviewProjectURL ?? recording
        let action = reviewed == nil ? "Use These Tiles" : "Reconcile Tiles"
        let choices = self.choices
        let token = EditCancellation()
        operation = token
        scanProgress = nil
        status = "Verifying tiles…"
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
                    var participants = document.participants
                    if reviewed?.retainedCopiedGeometry != true {
                        try choices.apply(to: &participants, sourceID: sourceID, analysisIdentity: scan.analysisIdentity)
                    }
                    return (participants, identity)
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
                acceptedReview = scan
                review = nil
                scanProgress = nil
                self.choices = .init()
                updateScanPreview()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func confirmCoverage(_ confirmation: CoverageConfirmation) {
        guard ParticipantSpeakerIndexKey(session: session) == confirmation.revision, operation == nil else { return }
        do {
            let context = try session.transcript.assetContext()
            let snapshot = session.transcript.project
            let sourceID = confirmation.sourceID
            let feedID = confirmation.participant.id
            let range = confirmation.range
            let token = EditCancellation()
            operation = token
            status = "Checking recording…"
            scanProgress = nil
            Task {
                let result = await session.sidecarWork.detached(priority: .userInitiated) {
                    Result {
                        var document = snapshot
                        try document.confirmParticipantPrivacy(sourceID: sourceID, participantID: feedID, range: range,
                                                               relativeTo: context, cancelled: { token.isCancelled })
                        return document.participants
                    }
                }.value
                guard operation === token else { return }
                operation = nil
                status = nil
                guard !token.isCancelled, confirmation.revision == ParticipantSpeakerIndexKey(session: session) else { return }
                do {
                    try session.commitParticipants(result.get(), action: "Confirm Reviewed Footage")
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
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
        change("Add Feed") { presentation.pinnedParticipant = try $0.addFeed() }
    }

    private func rename(_ person: ParticipantPerson) {
        let name = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var renamed = person
        renamed.name = name
        let duplicate = project.people.contains {
            $0.id != person.id && ParticipantBindingMetadata.matches(name, label: $0.name, kind: .speaker)
        }
        if !duplicate {
            let audio = suggestedAudio(for: renamed)
            if renamed.audio == nil, audio.count == 1 { renamed.audio = audio.first?.binding }
            let voices = speakerOptions.filter { option in
                ParticipantBindingMetadata.matches(name, label: option.name, kind: .speaker)
                    && !project.people.contains { $0.speakers.contains(option.binding) }
            }
            if renamed.speakers.isEmpty, voices.count == 1, let voice = voices.first { renamed.speakers = [voice.binding] }
        }
        update(person, action: "Rename Feed") { $0 = renamed }
    }

    private func resetScope() {
        extent = .tile
    }

    private func editRange() throws -> MulticamRange {
        guard let position = currentPosition else { throw tileRangeError }
        let track = source?.appearances.filter { $0.id == selectedRegion?.id } ?? []
        let range: MulticamRange?
        switch extent {
        case .tile:
            let from = track.map(\.range.from).min()
            let to = track.map(\.range.to).max()
            range = from.flatMap { first in to.map { .init(from: first, to: $0) } }
                ?? .init(from: position.time, to: position.duration)
        case .forward:
            range = .init(from: position.time, to: position.duration)
        case .layout:
            let next = source?.layoutChangeTimes.first { $0 > position.time }
            range = .init(from: position.time, to: next ?? position.duration)
        case .recording:
            range = .init(from: .zero, to: position.duration)
        case .marks:
            range = session.participantMarkedSourceRange(sourceID: position.sourceID)
        }
        guard let range, .zero <= range.from, range.from < range.to, range.to <= position.duration else { throw tileRangeError }
        return range
    }

    private var tileRangeError: CutError {
        .init(code: "invalid_tile_range", message: "Choose a nonempty range within this recording. For a marked range, set Mark In and Mark Out within the same occurrence.")
    }

    private func commitBounds(_ drawn: ParticipantDrawnBounds) {
        guard let position = currentPosition, position.sourceID == drawn.sourceID, position.time == drawn.time,
              !position.needsReconciliation(in: project) else { return }
        do {
            let range = try editRange()
            var document = session.transcript.project
            if let selectedRegion {
                var participants = document.participants
                try participants.correctBounds(sourceID: drawn.sourceID, appearanceID: selectedRegion.id,
                                                bounds: drawn.bounds, range: range)
                try session.commitParticipants(participants, action: "Correct Tile Box")
            } else {
                let url = try session.transcript.assetContext()
                let appearance = ParticipantAppearance(id: ProjectIdentifier.make(), participantID: selectedPerson?.id,
                                                       range: range, bounds: drawn.bounds)
                try document.addTileBox(sourceID: drawn.sourceID, document: url, appearance: appearance)
                try session.commitParticipants(document.participants, action: "Add Tile")
            }
            presentation.participantDrawnBounds = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func discardOutdatedDrawing() {
        if let drawn = presentation.participantDrawnBounds,
           drawn.sourceID != currentPosition?.sourceID || drawn.time != currentPosition?.time || staleGeometry {
            presentation.participantDrawnBounds = nil
        }
    }
}
