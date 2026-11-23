import AppKit
import Combine
import MPCutCore
import SwiftUI

@MainActor
struct ParticipantInspector: View {
    let session: ProjectSession
    @Environment(\.openDroppedProjects) private var openProjects
    @ObservedObject private var presentation: EditorPresentation
    @State private var time = RationalTime.zero
    @State private var displayedPicture: MulticamPicturePosition?
    @State private var error: String?
    @State private var operation: EditCancellation?
    @State private var status: String?
    @State private var review: ParticipantScanResult?
    @State private var reviewSourceID: String?
    @State private var speakerOptions: [(ParticipantSpeakerBinding, String)] = []
    @State private var rangeStart = ""
    @State private var rangeEnd = ""
    @State private var personName = ""
    @State private var showingComposition = false
    @State private var reviewedBoundary: RationalTime?
    @State private var boundarySourceID: String?
    @State private var markerThreshold = "any"
    @State private var markerCount = 2
    @State private var markerUnit = ParticipantMarkerRule.Unit.participants
    @State private var markerKinds = Set(ParticipantChangeEvent.Kind.allCases)
    @State private var markerWindow = 200
    @State private var markers: [ParticipantSceneMarker] = []

    init(session: ProjectSession) {
        self.session = session
        _presentation = ObservedObject(wrappedValue: session.presentation)
    }

    private var project: ParticipantProject { session.transcript.project.participants }
    private var position: ParticipantMonitorPosition? { session.participantPosition }
    private var staleGeometry: Bool { position?.needsReconciliation(in: project) == true }
    private var source: ParticipantSourceGeometry? { position.flatMap { current in project.sources.first { $0.sourceID == current.sourceID } } }
    private var selectedPerson: ParticipantPerson? { project.people.first { $0.id == presentation.pinnedParticipant } }
    private var selectedRegion: ParticipantAppearance? {
        guard !staleGeometry, let position, let picked = presentation.pickedParticipantAppearance,
              picked.sourceID == position.sourceID else { return nil }
        return project.appearances(sourceID: picked.sourceID, at: position.time).first { $0.id == picked.appearanceID }
    }

    private var busy: Bool { operation != nil || (session.isMulticam ? session.multicam.isBusy : session.editor.isBusy) }

    var body: some View {
        VStack(spacing: 0) {
            if !session.isMulticam {
                HStack {
                    Text("Participants").font(.headline)
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
                    if let selectedPerson { bindings(selectedPerson) }
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
        .onChange(of: time) { _, _ in
            if let drawn = presentation.participantDrawnBounds,
               drawn.sourceID != position?.sourceID || drawn.time != position?.time {
                presentation.participantDrawnBounds = nil
            }
        }
        .onChange(of: presentation.pinnedParticipant) { _, _ in personName = selectedPerson?.name ?? "" }
        .onChange(of: presentation.pickedParticipantAppearance) { _, _ in resetScope() }
        .onChange(of: presentation.participantDrawnBounds) { _, drawn in
            if drawn != nil, selectedRegion == nil { resetScope() }
        }
        .onAppear { personName = selectedPerson?.name ?? ""; resetScope() }
        .onDisappear {
            operation?.cancel()
            presentation.participantDrawMode = false
            presentation.participantDrawnBounds = nil
        }
        .task(id: ParticipantSpeakerIndexKey(session: session)) {
            var values: [(ParticipantSpeakerBinding, String)] = []
            for attachment in session.transcript.state.attachments {
                guard let index = try? await session.transcript.indexedTranscript(attachmentID: attachment.id) else { continue }
                let name = attachment.id
                values += index.speakers.map { speaker in
                    (.init(attachmentID: attachment.id, speakerID: speaker.id), "\(speaker.name) · \(name)")
                }
            }
            if !Task.isCancelled { speakerOptions = values }
        }
        .sheet(isPresented: $showingComposition) {
            ParticipantCompositionSheet(session: session, openProject: { _ = openProjects([$0]) })
        }
        .alert("Participants", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
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
                    Text("Source \(position.time.description) s · \(project.coverage(sourceID: position.sourceID, at: position.time).rawValue.capitalized) coverage")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Park the playhead on a source picture to inspect its participants.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(review?.state == .paused ? "Resume Scan" : "Scan Participants", systemImage: "viewfinder", action: scan)
                    .disabled(busy || position == nil || !ParticipantAnalysis.isAvailable)
                if let operation {
                    Button("Cancel Scan", role: .cancel) { operation.cancel() }
                }
            }
            if !ParticipantAnalysis.isAvailable {
                Text("This build can edit participant geometry manually. TileTrail is required to scan recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let review, reviewSourceID == position?.sourceID {
                let count = review.analysis?.appearances.count ?? 0
                Text("\(count) detected appearances").font(.callout)
                Button("Accept Geometry") { accept(review) }
                    .disabled(busy || review.analysis == nil || source != nil || review.state == .paused)
                if let source, source.analysisIdentity != review.analysisIdentity {
                    Text("This analysis differs from the accepted geometry. Review the saved corrections before reconciling the source.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                markerReview(review)
            }
        }
    }

    private func markerReview(_ result: ParticipantScanResult) -> some View {
        DisclosureGroup("Layout Change Markers") {
            Picker("Count", selection: $markerUnit) {
                Text("Participants").tag(ParticipantMarkerRule.Unit.participants)
                Text("Comparable Slots").tag(ParticipantMarkerRule.Unit.slots)
            }
            Picker("Threshold", selection: $markerThreshold) {
                Text("Any").tag("any")
                Text("At least").tag("some")
                Text("All").tag("all")
            }
            if markerThreshold == "some" { Stepper("Minimum \(markerCount)", value: $markerCount, in: 1...64) }
            Stepper("Settling \(markerWindow) ms", value: $markerWindow, in: 0...2000, step: 25)
            Menu("Event Types") {
                ForEach(ParticipantChangeEvent.Kind.allCases, id: \.self) { kind in
                    Toggle(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                           isOn: Binding(get: { markerKinds.contains(kind) }, set: {
                        if $0 { markerKinds.insert(kind) } else { markerKinds.remove(kind) }
                    }))
                }
            }
            Button("Review Marker Candidates") { resolveMarkers(result) }
                .disabled(busy || markerKinds.isEmpty)
            ForEach(markers.indices.prefix(100), id: \.self) { index in
                let marker = markers[index]
                Button("\(marker.time.description) s · \(marker.changedCount) changed"
                       + (marker.uncertain ? " · Uncertain" : "")) {
                    guard let sourceID = reviewSourceID,
                          let end = try? marker.time.adding(.init(numerator: 1, denominator: 1_000_000)) else { return }
                    session.seekParticipant(sourceID: sourceID, range: .init(from: marker.time, to: end))
                }
                .buttonStyle(.plain)
            }
            if markers.count > 100 { Text("Showing 100 of \(markers.count) markers").font(.caption) }
        }
    }

    private func resolveMarkers(_ result: ParticipantScanResult) {
        let threshold: ParticipantMarkerRule.Threshold = switch markerThreshold {
        case "some": .atLeast(markerCount)
        case "all": .all
        default: .any
        }
        do {
            markers = try ParticipantAnalysis.markers(result, rule: .init(unit: markerUnit, threshold: threshold,
                                                                            kinds: markerKinds, settlingWindowMS: UInt64(markerWindow)))
        } catch { self.error = error.localizedDescription }
    }

    private var roster: some View {
        let appearances = staleGeometry ? [] : position.map { project.appearances(sourceID: $0.sourceID, at: $0.time) } ?? []
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
                            Button(speakerOptions.first { $0.0 == binding }?.1 ?? binding.speakerID) {
                                session.showParticipantTranscript(binding)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bindings(_ person: ParticipantPerson) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Menu {
                Button("Unbound") { update(person, action: "Bind Participant Audio") { $0.audio = nil } }
                if let multicam = session.multicam.project, session.isMulticam {
                    ForEach(multicam.mixLanes) { lane in
                        Button(lane.label) {
                            update(person, action: "Bind Participant Audio") { $0.audio = .init(laneID: lane.id) }
                        }
                    }
                    ForEach(multicam.sources) { source in
                        ForEach(session.multicam.media[source.id]?.audio.map(\.stream.index) ?? [], id: \.self) { stream in
                            audioBindingButton(person, sourceID: source.id, name: source.displayName, stream: stream)
                        }
                    }
                } else if let position {
                    ForEach(position.media.audio.map(\.stream.index), id: \.self) { stream in
                        audioBindingButton(person, sourceID: position.sourceID, name: position.media.url.lastPathComponent, stream: stream)
                    }
                }
            } label: {
                Text(audioBindingLabel(person))
            }
            Menu("Bind Transcript Speakers") {
                ForEach(speakerOptions.indices, id: \.self) { index in
                    let (binding, name) = speakerOptions[index]
                    let alreadyLinked = person.speakers.contains(binding)
                    Button {
                        update(person, action: "Bind Participant Speaker") {
                            if alreadyLinked { $0.speakers.removeAll { $0 == binding } }
                            else { $0.speakers.append(binding) }
                        }
                    } label: {
                        if alreadyLinked { Label(name, systemImage: "checkmark") }
                        else { Text(name) }
                    }
                }
            }
            .disabled(speakerOptions.isEmpty)
        }
        .disabled(busy)
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

    private func audioBindingButton(_ person: ParticipantPerson, sourceID: String, name: String, stream: Int) -> some View {
        Button("\(name) · Stream \(stream)") {
            update(person, action: "Bind Participant Audio") { $0.audio = .init(selection: .init(source: sourceID, stream: stream)) }
        }
    }

    private var geometry: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Source Geometry")
            HStack {
                Button(presentation.participantDrawMode ? "Cancel Drawing" : selectedRegion == nil ? "Draw Box" : "Redraw Box") {
                    session.pauseParticipantPlayback()
                    presentation.participantDrawMode.toggle()
                }
                Button("Next Uncertain") { navigate(direction: 1, uncertain: true) }
                .disabled(source?.appearances.contains { $0.participantID == nil && $0.state != .presentation } != true)
            }
            .disabled(busy || position == nil)
            HStack {
                Button("Before Reflow") { navigateBoundary(before: true) }
                Button("After Reflow") { navigateBoundary(before: false) }
                if reviewedBoundary != nil {
                    Button("Next Reflow", systemImage: "forward.end") {
                        reviewedBoundary = nil
                        navigateBoundary(before: false)
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
                                next.appearanceOverrides.removeAll {
                                    $0.participantID == id && $0.sourceID == position.sourceID &&
                                    $0.range.from < range.to && range.from < $0.range.to
                                }
                                next.appearanceOverrides.append(.init(participantID: id, sourceID: position.sourceID,
                                                                       appearanceID: appearance.id, range: range))
                            }
                        }
                    }
                }
            }
        }
        .disabled(busy || staleGeometry)
    }

    private func scan() {
        guard let position, operation == nil else { return }
        let token = EditCancellation()
        let url = position.media.url
        let useSidecar = session.isMulticam ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        operation = token
        status = "Scanning \(url.lastPathComponent)…"
        let partial = reviewSourceID == position.sourceID && review?.state == .paused ? review : nil
        review = nil
        markers = []
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ParticipantAnalysis.scan(url, options: .init(useSidecar: useSidecar),
                                                       resuming: partial, cancelled: { token.isCancelled }) }
            }.value
            guard operation === token else { return }
            operation = nil
            switch result {
            case .success(let scan):
                reviewSourceID = position.sourceID
                review = scan
                status = scan.state == .paused ? "Scan paused. Scan again to resume." : "Scan \(scan.state.rawValue.replacingOccurrences(of: "_", with: " "))."
            case .failure(let failure):
                status = nil
                if !token.isCancelled { error = failure.localizedDescription }
            }
        }
    }

    private func accept(_ review: ParticipantScanResult) {
        guard let sourceID = reviewSourceID, let position, position.sourceID == sourceID else { return }
        change("Accept Participant Geometry") { next in
            var document = session.transcript.project
            let url = (session.isMulticam ? session.multicam.projectURL : session.editor.projectURL) ?? position.media.url
            try document.acceptParticipantAnalysis(review, sourceID: sourceID, relativeTo: url)
            next = document.participants
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
        rangeEnd = selectedRegion?.range.to.description ?? position?.media.duration.description ?? ""
    }

    private func editRange() throws -> MulticamRange {
        let from = try RationalTime(parsing: rangeStart)
        let to = try RationalTime(parsing: rangeEnd)
        guard from >= .zero, from < to, let position, to <= position.media.duration else {
            throw CutError(code: "invalid_participant_range", message: "Choose a nonempty range within the source recording.")
        }
        return .init(from: from, to: to)
    }

    private func commitBounds(_ drawn: ParticipantDrawnBounds) {
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
                    next.sources.append(.init(sourceID: drawn.sourceID, appearances: [appearance]))
                }
            }
        }
        if error == nil { presentation.participantDrawnBounds = nil }
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

    private func navigateBoundary(before: Bool) {
        guard let source, let position else { return }
        let boundaries = Set(source.appearances.flatMap { [$0.range.from, $0.range.to] }).sorted()
        let selected = boundarySourceID == source.sourceID ? reviewedBoundary : nil
        guard let boundary = selected ?? boundaries.first(where: { $0 > position.time && $0 < position.media.duration }) else { return }
        reviewedBoundary = boundary
        boundarySourceID = source.sourceID
        let epsilon = RationalTime(numerator: 1, denominator: 1_000_000_000)
        guard let from = before ? try? boundary.subtracting(epsilon) : boundary,
              let to = try? from.adding(epsilon) else { return }
        session.seekParticipant(sourceID: source.sourceID, range: .init(from: from, to: to))
    }
}
