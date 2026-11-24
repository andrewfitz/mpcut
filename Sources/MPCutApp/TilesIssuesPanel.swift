import AppKit
import MPCutCore
import SwiftUI

@MainActor
struct TilesIssuesPanel: View {
    let session: ProjectSession
    let sourceID: String
    let media: MediaInfo?
    let onChangedSource: () -> Void
    let onEditCountHints: () -> Void
    let onConfirmCoverage: (String, MulticamRange) -> Void

    @ObservedObject private var editor: EditorModel
    @ObservedObject private var multicam: MulticamEditorModel
    @State private var issues: [TilesIssue] = []
    @State private var review: TilesIssueSelection?
    @State private var pendingConfirmation: (feedID: String, range: MulticamRange)?

    private struct Revision: Equatable {
        let sourceID: String
        let timeline: Int
        let generation: UUID
        let mediaIdentity: SourceIdentity?
        let mediaChange: SourceIdentity.ChangeTime?
    }

    init(session: ProjectSession, sourceID: String, media: MediaInfo?, onChangedSource: @escaping () -> Void,
         onEditCountHints: @escaping () -> Void = {},
         onConfirmCoverage: @escaping (String, MulticamRange) -> Void) {
        self.session = session
        self.sourceID = sourceID
        self.media = media
        self.onChangedSource = onChangedSource
        self.onEditCountHints = onEditCountHints
        self.onConfirmCoverage = onConfirmCoverage
        _editor = ObservedObject(wrappedValue: session.editor)
        _multicam = ObservedObject(wrappedValue: session.multicam)
    }

    private var revision: Revision {
        .init(sourceID: sourceID, timeline: session.mcpRevision,
              generation: session.isMulticam ? multicam.mcpGeneration : editor.mcpGeneration,
              mediaIdentity: media?.identity, mediaChange: media?.identity.changeTime)
    }

    /// One row per decision: the issues of a tile's group collapse into its
    /// earliest returning-tile review, which settles them all.
    private var rows: [TilesIssue] {
        var representative: [String: String] = [:]
        for issue in issues {
            guard let group = issue.groupID else { continue }
            if representative[group] == nil || issue.kind == .ambiguousMatch
                && issues.first(where: { $0.id == representative[group] })?.kind != .ambiguousMatch {
                representative[group] = issue.id
            }
        }
        return issues.filter { issue in issue.groupID.map { representative[$0] == issue.id } ?? true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !issues.isEmpty {
                Divider()
                Text("Needs a Look (\(rows.count))")
                    .font(.headline)
                    .accessibilityIdentifier("tiles.issues")
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.id) { issue in
                        if issue.kind == .countMismatch {
                            Button(action: onEditCountHints) {
                                Label(issue.message, systemImage: "number")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tiles.issue.\(issue.id)")
                            .accessibilityHint("Edit the count hints for this recording.")
                        } else if issue.sourceTime == nil && issue.kind != .changedSource {
                            Text(issue.message).foregroundStyle(.secondary)
                                .accessibilityIdentifier("tiles.issue.\(issue.id)")
                        } else {
                            Button { open(issue) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    if let time = issue.sourceTime {
                                        Text(Self.timestamp(time)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Text(issue.message)
                                    if let count = issue.groupCount, count > 1 {
                                        Text("\(count) places").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tiles.issue.\(issue.id)")
                        }
                    }
                }
                .font(.callout)
            }
        }
        .sheet(item: $review, onDismiss: {
            if let pendingConfirmation {
                self.pendingConfirmation = nil
                onConfirmCoverage(pendingConfirmation.feedID, pendingConfirmation.range)
            }
        }) { selection in
            if let media {
                TilesIssueReview(session: session, selection: selection, sourceID: sourceID, media: media) {
                    pendingConfirmation = ($0, $1)
                }
            }
        }
        .task(id: revision) {
            let requested = revision
            guard let project = session.currentTimeline else { issues = []; return }
            let document = (session.isMulticam ? session.multicam.projectURL : session.editor.projectURL)
                ?? LiveProjectMediaArchive.untitledURL
            let currentSourceID = sourceID
            let origin = multicam.media[sourceID]?.multicamClockOffset
            let useSidecar = session.isMulticam ? multicam.useAnalysisSidecars : editor.useAnalysisSidecars
            let scan = session.sidecarWork.detached(priority: .utility) {
                TilesReview(project: project, sourceID: currentSourceID, document: document,
                            sourceClockOrigin: origin, useSidecar: useSidecar, cancelled: { Task.isCancelled }).issues
            }
            let next = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled, requested == revision else { return }
            issues = next
        }
        .onChange(of: sourceID) { _, _ in
            issues = []
            review = nil
            pendingConfirmation = nil
        }
    }

    private func open(_ issue: TilesIssue) {
        if issue.kind == .changedSource {
            onChangedSource()
            return
        }
        guard let time = issue.sourceTime,
              let end = try? time.adding(.init(numerator: 1, denominator: 1_000_000)) else { return }
        session.presentation.participantMonitorSource = true
        session.presentation.participantDrawMode = false
        session.presentation.pickedParticipantAppearance = issue.tileID.map {
            .init(sourceID: sourceID, appearanceID: $0)
        }
        let mark = issue.kind == .uncheckedRange
        let sought = session.seekParticipant(sourceID: sourceID, range: mark ? issue.range ?? .init(from: time, to: end)
                                                                            : .init(from: time, to: end), mark: mark)
        if sought, issue.kind == .unassignedTile || issue.kind == .layoutChange {
            session.presentation.requestedParticipantTileEditor = session.presentation.pickedParticipantAppearance
        } else {
            session.presentation.requestedParticipantTileEditor = nil
        }
        if let media, !sought || issue.kind == .ambiguousMatch {
            guard media.identity.isCurrentSnapshot(at: media.url) else { return }
            session.pauseParticipantPlayback()
            review = .init(issue: issue, revision: session.mcpRevision)
        }
    }

    static func timestamp(_ time: RationalTime) -> String {
        let total = (max(0, time.seconds) * 100).rounded() / 100
        let hours = Int(total / 3600)
        let minutes = Int(total / 60) % 60
        let seconds = total.truncatingRemainder(dividingBy: 60)
        return hours > 0 ? String(format: "%d:%02d:%05.2f", hours, minutes, seconds)
                         : String(format: "%d:%05.2f", minutes, seconds)
    }
}

private struct TilesIssueSelection: Identifiable {
    let issue: TilesIssue
    let revision: Int
    var id: String { issue.id }
}

@MainActor
private struct TilesIssueReview: View {
    let session: ProjectSession
    let selection: TilesIssueSelection
    let sourceID: String
    let media: MediaInfo
    let onConfirmCoverage: (String, MulticamRange) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidateID: String?
    @State private var error: String?

    private var issue: TilesIssue { selection.issue }
    private var source: ParticipantSourceGeometry? { session.participantProject.sources.first { $0.sourceID == sourceID } }
    private var time: RationalTime { issue.sourceTime ?? .zero }
    private var returningTile: ParticipantAppearance? {
        source?.appearances.first { $0.id == issue.tileID && $0.range.contains(time) }
    }
    /// Feeds this tile may belong to instead of the scan's own feed for it.
    /// The own feed is what **Different Feed** keeps, so it is not offered
    /// for comparison while there is any other candidate.
    private var feedCandidates: [String] {
        var seen = Set<String>()
        let known = issue.candidateFeedIDs.filter { id in
            seen.insert(id).inserted && session.participantProject.people.contains { $0.id == id }
        }
        let others = known.filter { $0 != issue.feedID }
        return others.isEmpty ? known : others
    }
    private var chosenCandidate: String? { candidateID ?? feedCandidates.first }
    private var evidence: ParticipantTileScanEvent.Candidate? {
        source?.scanEvents.first { $0.tileID == issue.tileID && $0.time == time }?.candidates?
            .first { $0.feedID == chosenCandidate }
    }
    private var precedingTile: ParticipantAppearance? {
        source?.appearances.filter { tile in
            guard tile.participantID == chosenCandidate, tile.range.from < time else { return false }
            if let precedingTime = evidence?.precedingTime {
                return (evidence?.precedingTileID == nil || evidence?.precedingTileID == tile.id) &&
                    tile.range.contains(precedingTime)
            }
            return tile.range.to <= time
        }.max { $0.range.to < $1.range.to }
    }
    private var tilePosition: ParticipantMonitorPosition {
        .init(sourceID: sourceID, media: media, time: time)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(issue.kind == .ambiguousMatch && returningTile != nil ? "Review Returning Tile" : issue.message)
                .font(.headline)
            if issue.kind == .ambiguousMatch, returningTile != nil, let count = issue.groupCount, count > 1 {
                Text("Your choice applies to all \(count) places this tile needs a feed.")
                    .foregroundStyle(.secondary)
            }
            if feedCandidates.count > 1 {
                Picker("Compare with", selection: Binding(get: { chosenCandidate ?? "" }, set: { candidateID = $0 })) {
                    ForEach(feedCandidates, id: \.self) { id in
                        Text(session.participantProject.people.first { $0.id == id }?.name ?? "Feed").tag(id)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                if issue.kind == .ambiguousMatch, returningTile != nil {
                    if let before = evidence?.precedingTime ?? precedingTile?.range.to ?? issue.precedingTime {
                        TilesIssuePicture(media: media, time: before, exclusiveEnd: evidence?.precedingTime == nil
                                          && precedingTile?.range.to == before,
                                          bounds: precedingTile?.bounds, label: "Before departure")
                    } else {
                        ContentUnavailableView("Earlier Frame Unavailable", systemImage: "film")
                            .frame(maxWidth: .infinity, minHeight: 165)
                    }
                }
                TilesIssuePicture(media: media, time: time, exclusiveEnd: false,
                                  bounds: returningTile?.bounds,
                                  label: issue.kind == .ambiguousMatch && returningTile != nil ? "After return" : "Source")
            }
            HStack {
                Spacer()
                if issue.kind == .ambiguousMatch, returningTile != nil {
                    Button("Leave Unresolved") { dismiss() }
                        .accessibilityIdentifier("tiles.return.unresolved")
                    Button("Different Feed") { resolve(same: false) }
                        .accessibilityIdentifier("tiles.return.different")
                    Button("Same Feed") { resolve(same: true) }
                        .disabled(chosenCandidate == nil)
                        .accessibilityIdentifier("tiles.return.same")
                } else {
                    if let returningTile {
                        TileIssueEditButton(session: session, source: tilePosition, tile: returningTile)
                    }
                    if issue.kind == .ambiguousMatch, let feedID = issue.feedID, let range = issue.range {
                        Button("Confirm Reviewed Footage…") {
                            guard validateSnapshot() else { return }
                            onConfirmCoverage(feedID, range)
                            dismiss()
                        }
                    }
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 660)
        .alert("Tile Review", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func validateSnapshot() -> Bool {
        guard selection.revision == session.mcpRevision, media.identity.isCurrentSnapshot(at: media.url) else {
            error = "The recording or edit changed. Reopen this issue to review it again."
            return false
        }
        return true
    }

    /// A decision about a grouped tile covers the whole tile, so every place
    /// it waits for a feed is settled at once.
    private var decisionRange: MulticamRange? {
        guard issue.groupID != nil, let tileID = issue.tileID,
              let spans = source?.appearances.lazy.filter({ $0.id == tileID }).map(\.range),
              let from = spans.map(\.from).min(), let to = spans.map(\.to).max(), from < to else { return issue.range }
        return .init(from: from, to: to)
    }

    private func resolve(same: Bool) {
        guard let tile = returningTile, let range = decisionRange, validateSnapshot() else { return }
        do {
            var updated = session.participantProject
            let selectedFeed: String
            let ownFeed = issue.feedID.flatMap { id in updated.people.contains { $0.id == id } ? id : nil }
            if same, let chosenCandidate, let ownFeed, ownFeed != chosenCandidate {
                // The scan's own feed for this tile is the same person: fold it,
                // and every other tile on it, into the earlier feed, then link the
                // whole tile. One undo step covers both.
                var document = session.transcript.project
                let conflicts = try document.mergeTileFeeds(ownFeed, into: chosenCandidate)
                var model = document.participants
                try model.linkAppearance(sourceID: sourceID, appearanceID: tile.id, participantID: chosenCandidate,
                                         range: range)
                document.participants = model
                try session.commitTileDocument(document, action: "Link Returning Tile")
                session.presentation.pinnedParticipant = chosenCandidate
                if conflicts.isEmpty { dismiss() } else { error = conflicts.joined(separator: "\n") }
                return
            }
            if same {
                guard let chosenCandidate else { return }
                selectedFeed = chosenCandidate
            } else if let ownFeed, ownFeed != chosenCandidate {
                // The scan's own track for this tile, so its clean stretches stay one feed.
                selectedFeed = ownFeed
            } else {
                selectedFeed = UUID().uuidString.lowercased()
                let names = Set(updated.people.map(\.name))
                let number = (1...(names.count + 1)).first { !names.contains("Feed \($0)") } ?? names.count + 1
                updated.people.append(.init(id: selectedFeed, name: "Feed \(number)"))
            }
            try updated.linkAppearance(sourceID: sourceID, appearanceID: tile.id, participantID: selectedFeed, range: range)
            try session.commitParticipants(updated, action: same ? "Link Returning Tile" : "Create Feed for Returning Tile")
            session.presentation.pinnedParticipant = selectedFeed
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct TileIssueEditButton: View {
    let session: ProjectSession
    let source: ParticipantMonitorPosition
    let tile: ParticipantAppearance
    @State private var showingEditor = false

    var body: some View {
        Button("Edit Tile…") { showingEditor = true }
            .popover(isPresented: $showingEditor) {
                ParticipantTileEditor(session: session, source: source, appearance: tile, allowsLayoutEdits: false)
            }
    }
}

private struct TilesIssuePicture: View {
    let media: MediaInfo
    let time: RationalTime
    let exclusiveEnd: Bool
    let bounds: ParticipantBounds?
    let label: String
    @State private var jpeg: Data?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let jpeg, let image = NSImage(data: jpeg) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .overlay {
                            if let bounds {
                                GeometryReader { proxy in
                                    let size = proxy.size
                                    let scale = min(size.width / image.size.width, size.height / image.size.height)
                                    let width = image.size.width * scale
                                    let height = image.size.height * scale
                                    Rectangle().strokeBorder(.yellow, lineWidth: 2)
                                        .frame(width: width * bounds.width, height: height * bounds.height)
                                        .position(x: (size.width - width) / 2 + width * (bounds.x + bounds.width / 2),
                                                  y: (size.height - height) / 2 + height * (bounds.y + bounds.height / 2))
                                }
                                .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(label)
                } else if failed {
                    Label("Frame unavailable", systemImage: "film")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 165)
            .clipShape(.rect(cornerRadius: 6))
            Text(TilesIssuesPanel.timestamp(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .task(id: "\(media.url.path)|\(time)|\(exclusiveEnd)") {
            jpeg = nil
            failed = false
            let task = Task.detached(priority: .utility) {
                let index = media.hasFullEditIndex ? media : try CutEngine(cancelled: { Task.isCancelled }).inspect(media.url, keyframes: true)
                let clock = try time.adding(index.multicamClockOffset)
                return try JPEGExport.reviewFrame(index, at: clock, exclusiveEnd: exclusiveEnd, cancelled: { Task.isCancelled }).0
            }
            let result = await withTaskCancellationHandler(operation: { await task.result }, onCancel: { task.cancel() })
            guard !Task.isCancelled else { return }
            jpeg = try? result.get()
            failed = jpeg == nil
        }
    }
}
