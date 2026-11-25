import MPCutCore
import SwiftUI

/// Verified times for one unsafe edge of an exported range. `edge.range` is the one-based number of the range in
/// what the engine was given: the saved assembly, or the single range of a queued entry.
struct MulticamEdgeSuggestion: Equatable {
    let edge: MulticamEdge
    let times: [RationalTime]

    /// The range with its named edge moved to `time`, when the edge is still where the engine found it.
    func moving(_ range: MulticamRange, to time: RationalTime) -> MulticamRange? {
        guard times.contains(time) else { return nil }
        switch edge.boundary {
        case "from" where range.from == edge.at && time < range.to: return MulticamRange(from: time, to: range.to)
        case "to" where range.to == edge.at && time > range.from: return MulticamRange(from: range.from, to: time)
        default: return nil
        }
    }

    var title: String { "Choose a new \(edge.boundary == "from" ? "start" : "end") time for range \(edge.range)." }
}

extension MulticamEditorModel {
    /// The edge suggestion of the last export, while the assembly still has that edge.
    var currentEdgeSuggestion: MulticamEdgeSuggestion? {
        guard let suggestion = edgeSuggestion, suggestion.edge.range > 0,
              let range = assemblyRange(at: suggestion.edge.range - 1),
              suggestion.times.contains(where: { suggestion.moving(range, to: $0) != nil }) else { return nil }
        return suggestion
    }

    @discardableResult
    func applyEdgeSuggestion(_ time: RationalTime) -> Bool {
        guard !isBusy, let suggestion = currentEdgeSuggestion else { return false }
        let index = suggestion.edge.range - 1
        guard let range = assemblyRange(at: index), let moved = suggestion.moving(range, to: time) else { return false }
        preview.pause()
        guard edit("Move Range Edge", { project in
            project.materializeAssembly()
            if let item = project.assemblyItems?[index] {
                project.assemblyItems?[index] = item.trimmingGroup(to: moved)
            }
        }) else { return false }
        edgeSuggestion = nil
        exportAlternatives = []
        return true
    }

    /// Moves the unsafe edge of a queued range to a verified time. `issue` is the failure of the queue check, whose
    /// `segment` numbers the queued entry and whose edge numbers that entry's own single range.
    @discardableResult
    func applyQueuedEdgeSuggestion(_ time: RationalTime, for issue: CutError, contentID: UUID? = nil) -> Bool {
        guard !isBusy, let edge = issue.multicam?.edge, edge.range == 1, let number = issue.segment, number > 0,
              let target = readyQueuedRanges.dropFirst(number - 1).first,
              let index = queuedRanges.firstIndex(where: { $0.id == target.id }) else { return false }
        var entry = queuedRanges[index]
        guard contentID == nil || entry.contentID == contentID,
              !entry.usesAssembly,
              let moved = MulticamEdgeSuggestion(edge: edge, times: issue.nearest ?? []).moving(entry.range, to: time),
              (try? entry.project.plan(ranges: [moved])) != nil else { return false }
        entry.range = moved
        entry.contentID = UUID()
        queuedRanges[index] = entry
        return true
    }
}

/// The verified times of an unsafe range edge, each with Preview and Apply.
struct MulticamEdgeSuggestionsView: View {
    let suggestion: MulticamEdgeSuggestion
    let preview: ((RationalTime) -> Void)?
    let apply: (RationalTime) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(suggestion.title)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestion.times, id: \.self) { time in
                HStack {
                    Text(timelineTime(time.seconds, milliseconds: true))
                        .font(.system(size: 12, design: .monospaced))
                        .help("\(time.description) s")
                    Spacer()
                    if let preview {
                        Button("Preview") { preview(time) }
                            .help("Preview suggested boundary")
                    }
                    Button("Apply") { apply(time) }
                        .help("Apply suggested boundary")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
