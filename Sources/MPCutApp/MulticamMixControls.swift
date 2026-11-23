import MPCutCore
import SwiftUI

struct MulticamLaneChip: View {
    let slot: Int
    static let palette: [Color] = [.teal, .indigo, .orange, .purple, .mint, .pink, .blue, .yellow]

    static func color(for slot: Int) -> Color {
        palette.indices.contains(slot) ? palette[slot] : .secondary
    }

    var body: some View {
        Circle().fill(Self.color(for: slot)).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

extension MulticamEditorModel {
    @discardableResult
    func setProgramAudio(_ policy: MulticamAudioPolicy) -> Bool {
        edit("Change Program Audio") { project in
            if policy == .mix, project.mixLanes.isEmpty {
                project.mixLanes = project.defaultMixLanes
            }
            project.audio = policy
        }
    }

    func addMixLane(target: MulticamAudioLaneTarget, label: String) {
        edit("Add Mix Track") { project in
            if project.mixLanes.isEmpty { project.mixLanes = project.defaultMixLanes }
            guard !project.mixLanes.contains(where: { $0.target == target }) else {
                project.audio = .mix
                return
            }
            let usedSlots = Set(project.mixLanes.map(\.colorSlot))
            let slot = (0..<MulticamAudioLane.colorSlotCount).first { !usedSlots.contains($0) }
                ?? project.mixLanes.count % MulticamAudioLane.colorSlotCount
            project.mixLanes.append(.init(id: UUID().uuidString, target: target, label: label, colorSlot: slot))
            project.audio = .mix
        }
    }

    func renameMixLane(_ id: String, label: String) {
        edit("Rename Mix Track") { project in
            guard let index = project.mixLanes.firstIndex(where: { $0.id == id }) else { return }
            project.mixLanes[index].label = label
        }
    }

    func moveMixLane(_ id: String, by delta: Int) {
        edit("Reorder Mix Tracks") { project in
            guard let index = project.mixLanes.firstIndex(where: { $0.id == id }),
                  project.mixLanes.indices.contains(index + delta) else { return }
            project.mixLanes.swapAt(index, index + delta)
        }
    }

    func removeMixLane(_ id: String) {
        edit("Remove Mix Track") { project in
            project.mixLanes.removeAll { $0.id == id }
        }
    }
}

struct MulticamMixControls: View {
    @ObservedObject var model: MulticamEditorModel
    let project: MulticamProject

    private var choices: [MixTrackChoice] {
        let boundSources = Set(project.audioReplacements.map(\.replacement.source))
        let cameras = project.angles.compactMap { angle -> MixTrackChoice? in
            let tracks = angle.recordings.compactMap { recording -> String? in
                guard let stream = recording.audioStream else { return nil }
                return model.media[recording.id]?.audio.first { $0.stream.index == stream }?.stream.exportLabel
                    ?? "Stream \(stream)"
            }
            guard !tracks.isEmpty else { return nil }
            let layouts = Set(tracks).sorted().joined(separator: " / ")
            return .init(target: .camera(angle.id), label: angle.displayName,
                         detail: "\(angle.displayName) · Camera track · \(layouts)")
        }
        let recordings = project.sources.filter { !boundSources.contains($0.id) }.flatMap { source in
            (model.media[source.id]?.audio ?? []).map { track in
                MixTrackChoice(target: .recording(.init(source: source.id, stream: track.stream.index)),
                               label: "\(source.displayName) · Stream \(track.stream.index)",
                               detail: "\(source.displayName) · \(track.stream.exportLabel)")
            }
        }
        return cameras + recordings
    }

    var body: some View {
        let choices = choices
        if project.audio == .mix {
            let details = Dictionary(uniqueKeysWithValues: choices.map { ($0.target, $0.detail) })
            SectionHeading("Mix Tracks")
            ForEach(Array(project.mixLanes.enumerated()), id: \.element.id) { index, lane in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        MulticamLaneChip(slot: lane.colorSlot)
                        MulticamNameField(name: lane.label, fieldLabel: "Track name", help: "Rename Mix track") { label in
                            if !label.isEmpty { model.byHand { model.renameMixLane(lane.id, label: label) } }
                        }
                        Menu {
                            Button("Move Earlier") { model.byHand { model.moveMixLane(lane.id, by: -1) } }
                                .disabled(index == 0)
                            Button("Move Later") { model.byHand { model.moveMixLane(lane.id, by: 1) } }
                                .disabled(index == project.mixLanes.count - 1)
                            if case .recording(let selection) = lane.target,
                               project.pictureSources.contains(where: { $0.id == selection.source }) {
                                Button("Replace Track Audio…") { model.chooseTrackReplacementAudio(selection) }
                            } else if case .camera(let camera) = lane.target {
                                let recordings = project.recordings(for: camera).filter { $0.audioStream != nil }
                                if !recordings.isEmpty {
                                    Menu("Replace Track Audio…") {
                                        ForEach(recordings, id: \.id) { recording in
                                            if let stream = recording.audioStream {
                                                Button("\(recording.displayName) · Stream \(stream)") {
                                                    model.chooseTrackReplacementAudio(.init(source: recording.id, stream: stream))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Button("Remove Track", role: .destructive) { model.byHand { model.removeMixLane(lane.id) } }
                                .disabled(project.mixLanes.count == 1)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .fixedSize()
                        .accessibilityLabel("Commands for \(lane.label)")
                    }
                    Text(details[lane.target] ?? "Track index unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            choiceMenu("Add Mix Track", choices: choices)
        } else if project.mixLanes.isEmpty && project.defaultMixLanes.isEmpty && !choices.isEmpty {
            choiceMenu("Start Mix With", choices: choices)
        }
    }

    private func choiceMenu(_ title: String, choices: [MixTrackChoice]) -> some View {
        Menu(title) {
            let targets = project.mixLanes.map(\.target)
            ForEach(choices, id: \.target) { choice in
                Button(choice.detail) {
                    model.byHand { model.addMixLane(target: choice.target, label: choice.label) }
                }
                .disabled(targets.contains(choice.target))
            }
        }
    }

    private struct MixTrackChoice {
        let target: MulticamAudioLaneTarget
        let label: String
        let detail: String
    }
}
