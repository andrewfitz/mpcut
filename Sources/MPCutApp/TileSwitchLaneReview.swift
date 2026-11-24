import MPCutCore
import SwiftUI

@MainActor
struct TileSwitchLaneReview: View {
    @ObservedObject var model: MulticamEditorModel
    @Environment(\.transcriptSession) private var session
    @Binding var proposals: [TileSwitchProposal]
    @Binding var proposalIndexes: [TranscriptIndex]
    @State private var showingVoices = false
    @State private var indexes: [TranscriptIndex] = []
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Menu {
            Button("Link Transcript Voices…") { showingVoices = true }
            Button("Propose Switches") { propose() }
                .disabled(working)
            if !proposals.isEmpty {
                Button("Clear Proposals") { proposals = [] }
            }
            if let message { Text(message) }
        } label: {
            Label("Dialogue Switches", systemImage: "bubble.left.and.bubble.right")
                .labelStyle(.iconOnly)
        }
        .help("Link transcript voices and propose camera switches")
        .accessibilityIdentifier("timeline.dialogue-switches")
        .disabled(session == nil || model.transcriptState.attachments.isEmpty || model.isBusy)
        .popover(isPresented: $showingVoices) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Link Transcript Voices").font(.headline)
                if working {
                    ProgressView()
                } else if let message {
                    Text(message).foregroundStyle(.secondary)
                } else if indexes.allSatisfy({ $0.speakers.isEmpty }) {
                    Text("This transcript has no identified voices.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(indexes.indices, id: \.self) { index in
                                if let attachmentID = indexes[index].attachment?.id {
                                    ForEach(indexes[index].speakers, id: \.id) { speaker in
                                        let voice = ParticipantSpeakerBinding(attachmentID: attachmentID, speakerID: speaker.id)
                                        Picker(speaker.name, selection: angleBinding(for: voice)) {
                                            Text(automaticLabel(for: voice)).tag(String?.none)
                                            ForEach(model.project?.angles ?? [], id: \.id) { angle in
                                                Text(angle.displayName).tag(Optional(angle.id))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
                Button("Done") { showingVoices = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .frame(width: 340)
            .task { await loadVoices() }
        }
    }

    private func angleBinding(for voice: ParticipantSpeakerBinding) -> Binding<String?> {
        Binding {
            model.project?.speakerAngles.first(where: { $0.voice == voice })?.angleID
        } set: { angle in
            model.byHand {
                model.edit("Link Transcript Voice") { project in
                    project.speakerAngles.removeAll { $0.voice == voice }
                    if let angle { project.speakerAngles.append(.init(voice: voice, angleID: angle)) }
                }
            }
        }
    }

    private func automaticLabel(for voice: ParticipantSpeakerBinding) -> String {
        guard var project = model.project else { return "Automatic" }
        project.speakerAngles.removeAll { $0.voice == voice }
        guard let link = TileSwitches.links(in: project, indexes: indexes).first(where: { $0.voice == voice }),
              let angle = project.angles.first(where: { $0.id == link.angleID }) else { return "Automatic · No match" }
        return "Automatic · \(angle.displayName)"
    }

    private func readIndexes() async throws -> [TranscriptIndex] {
        guard let session else { return [] }
        var result: [TranscriptIndex] = []
        for attachment in model.transcriptState.attachments {
            try Task.checkCancellation()
            result.append(try await session.transcript.indexedTranscript(attachmentID: attachment.id, clocks: [.source, .group]))
        }
        return result
    }

    private func loadVoices() async {
        working = true
        message = nil
        defer { working = false }
        do {
            indexes = try await readIndexes()
        } catch where !Task.isCancelled {
            message = error.localizedDescription
        } catch {}
    }

    private func propose() {
        guard let project = model.project else { return }
        let generation = model.mcpGeneration
        let revision = model.mcpRevision
        let mediaRevision = model.transcriptMediaRevision
        let document = model.projectURL ?? model.draft.url ?? LiveProjectMediaArchive.untitledURL
        let useSidecar = model.useAnalysisSidecars
        let sidecarWork = model.sidecarWork
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                let currentIndexes = try await readIndexes()
                let proposed = try await sidecarWork.detached(priority: .userInitiated) {
                    try TileSwitches.propose(in: project, document: document, indexes: currentIndexes,
                                             useSidecar: useSidecar, cancelled: { Task.isCancelled })
                }.value
                guard model.mcpGeneration == generation, model.mcpRevision == revision,
                      model.transcriptMediaRevision == mediaRevision, model.project == project else { return }
                proposalIndexes = currentIndexes
                proposals = proposed
                if proposed.isEmpty { message = "No dialogue switches found." }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
