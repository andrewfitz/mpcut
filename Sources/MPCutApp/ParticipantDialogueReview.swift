import MPCutCore
import SwiftUI

@MainActor
struct ParticipantDialogueReview: View {
    let session: ProjectSession
    let project: CutProject
    let document: URL
    let angles: [ParticipantVirtualAngle]
    let preview: (ParticipantDialogueProposal) -> Void
    let commit: (CutProject, CutProject, ParticipantDialogueProposal) throws -> Void

    @State private var minimum = "1"
    @State private var overlap = ParticipantDialogueOptions.Overlap.hold
    @State private var offscreen = ParticipantDialogueOptions.Offscreen.hold
    @State private var proposals: [ParticipantDialogueProposal] = []
    @State private var task: Task<Void, Never>?
    @State private var status: String?

    var body: some View {
        DisclosureGroup("Dialogue Switch Suggestions") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Minimum Hold in Seconds", text: $minimum)
                Picker("Overlapping Speech", selection: $overlap) {
                    Text("Hold the Shot").tag(ParticipantDialogueOptions.Overlap.hold)
                    Text("Favor a Visible Speaker").tag(ParticipantDialogueOptions.Overlap.visibleSpeaker)
                }
                Picker("Offscreen Speaker", selection: $offscreen) {
                    Text("Hold the Shot").tag(ParticipantDialogueOptions.Offscreen.hold)
                    Text("Show Original Gallery").tag(ParticipantDialogueOptions.Offscreen.original)
                    Text("Show a Visible Reaction").tag(ParticipantDialogueOptions.Offscreen.reaction)
                }
                Button("Suggest Dialogue Switches", action: suggest)
                    .disabled(!angles.contains { $0.kind == .participant } || task != nil || speakerAttachments.isEmpty)
                if speakerAttachments.isEmpty {
                    Text("Bind transcript speakers to participants to suggest switches.").font(.caption)
                }
                if task != nil { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.caption) }
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(proposals) { proposal in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(proposal.angle.name)
                                Text("\(proposal.at.description) s · Occurrence \(proposal.occurrence + 1) · \(label(proposal.reason))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Preview") { preview(proposal) }
                                .accessibilityLabel("Preview \(proposal.angle.name) at \(proposal.at.description) seconds")
                            Button("Accept") { accept(proposal) }
                                .accessibilityLabel("Accept \(proposal.angle.name) at \(proposal.at.description) seconds")
                            Button("Dismiss") { proposals.removeAll { $0.id == proposal.id } }
                        }
                        .disabled(task != nil)
                    }
                }
            }
            .disabled(task != nil)
        }
        .onChange(of: angles) { _, _ in reset() }
        .onChange(of: project) { old, new in
            var lhs = old
            var rhs = new
            lhs.participants.render = nil
            rhs.participants.render = nil
            if lhs != rhs || old.participants.effectiveRedactions != new.participants.effectiveRedactions { reset() }
        }
        .onChange(of: minimum) { _, _ in reset() }
        .onChange(of: overlap) { _, _ in reset() }
        .onChange(of: offscreen) { _, _ in reset() }
        .onDisappear { task?.cancel() }
    }

    private var speakerAttachments: [String] {
        let bound = Set(project.participants.people.flatMap(\.speakers).map(\.attachmentID))
        return session.transcript.state.attachments.map(\.id).filter(bound.contains)
    }

    private func label(_ reason: ParticipantDialogueProposal.Reason) -> String {
        switch reason {
        case .speaker: "Speaking"
        case .overlap: "Overlapping speech"
        case .offscreen: "Offscreen speaker"
        case .reaction: "Reaction"
        }
    }

    private func reset() {
        task?.cancel()
        task = nil
        proposals = []
        status = nil
    }

    private func suggest() {
        do {
            let hold = try RationalTime(parsing: minimum)
            let options = ParticipantDialogueOptions(minimumHold: hold, overlap: overlap, offscreen: offscreen)
            let attachmentIDs = speakerAttachments
            let angles = angles
            let project = project
            let document = document
            status = nil
            task = Task {
                do {
                    var indexes: [TranscriptIndex] = []
                    for id in attachmentIDs {
                        try Task.checkCancellation()
                        indexes.append(try await session.transcript.indexedTranscript(attachmentID: id))
                    }
                    let loaded = indexes
                    let suggestions = try await background { token in
                        let lines = loaded.flatMap(ParticipantDialogue.lines(from:))
                        return try ParticipantDialogue.suggest(lines, angles: angles, in: project, document: document,
                                                               options: options, cancelled: { token.isCancelled })
                    }
                    try Task.checkCancellation()
                    proposals = suggestions
                    if suggestions.isEmpty { status = "No switches match these settings." }
                } catch {
                    guard !Task.isCancelled else { return }
                    status = error.localizedDescription
                }
                task = nil
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func accept(_ proposal: ParticipantDialogueProposal) {
        let project = project
        let document = document
        status = nil
        task = Task {
            defer { task = nil }
            do {
                let updated = try await background { _ in
                    try ParticipantDialogue.accepting(proposal, in: project, document: document)
                }
                try Task.checkCancellation()
                try commit(project, updated, proposal)
                proposals.removeAll { $0.id == proposal.id }
                status = "Saved \(proposal.angle.name) at \(proposal.at.description) s."
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
        }
    }

    private func background<Value: Sendable>(_ work: @escaping @Sendable (EditCancellation) throws -> Value) async throws -> Value {
        let token = EditCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try work(token) }.value
        } onCancel: {
            token.cancel()
        }
    }
}
