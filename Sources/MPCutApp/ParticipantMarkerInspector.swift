import MPCutCore
import SwiftUI

struct ParticipantMarkerPages {
    private static let size = 25
    private(set) var offset = 0

    func indices(count: Int) -> Range<Int> {
        let start = min(offset, count)
        return start..<min(start + Self.size, count)
    }

    mutating func move(by direction: Int, count: Int) {
        let last = max(0, count - 1) / Self.size * Self.size
        offset = min(last, max(0, offset + direction * Self.size))
    }
}

@MainActor
struct ParticipantMarkerInspector: View {
    private enum Threshold: String {
        case any, atLeast, all
    }

    private struct Query: Equatable, Sendable {
        let id = UUID()
        let rule: ParticipantMarkerRule
    }

    let result: ParticipantScanResult
    let busy: Bool
    let seek: (MulticamRange) -> Void
    @State private var unit = ParticipantMarkerRule.Unit.participants
    @State private var threshold = Threshold.any
    @State private var minimum = 2
    @State private var kinds = Set(ParticipantChangeEvent.Kind.allCases)
    @State private var settlingWindow = 200
    @State private var scopeToRoster = false
    @State private var roster = Set<UInt64>()
    @State private var request: Query?
    @State private var markers: [ParticipantSceneMarker]?
    @State private var pages = ParticipantMarkerPages()
    @State private var selectedTime: RationalTime?
    @State private var failure: String?

    private var trackIDs: [UInt64] {
        result.analysis?.tracks.map(\.id).sorted() ?? []
    }

    private var rule: ParticipantMarkerRule {
        let markerThreshold: ParticipantMarkerRule.Threshold = switch threshold {
        case .any: .any
        case .atLeast: .atLeast(minimum)
        case .all: .all
        }
        return .init(unit: unit, threshold: markerThreshold, kinds: kinds,
                     roster: scopeToRoster ? roster : nil, settlingWindowMS: UInt64(settlingWindow))
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading) {
                Picker("Count", selection: $unit) {
                    Text("Feeds").tag(ParticipantMarkerRule.Unit.participants)
                    Text("Tile Positions").tag(ParticipantMarkerRule.Unit.slots)
                }
                Picker("Threshold", selection: $threshold) {
                    Text("Any").tag(Threshold.any)
                    Text("At least").tag(Threshold.atLeast)
                    Text("All").tag(Threshold.all)
                }
                if threshold == .atLeast { Stepper("Minimum \(minimum)", value: $minimum, in: 1...64) }
                Stepper("Settling \(settlingWindow) ms", value: $settlingWindow, in: 0...2000, step: 25)
                Menu("Event Types") {
                    ForEach(ParticipantChangeEvent.Kind.allCases, id: \.self) { kind in
                        Toggle(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                               isOn: membership(kind, in: $kinds))
                    }
                }
                Picker("Feeds", selection: $scopeToRoster) {
                    Text("Everyone").tag(false)
                    Text("Selected Feeds").tag(true)
                }
                if scopeToRoster {
                    Menu("Detected Feeds (\(roster.count) selected)") {
                        ForEach(trackIDs, id: \.self) { id in
                            Toggle("Detected Feed \(id)", isOn: membership(id, in: $roster))
                        }
                    }
                    .disabled(trackIDs.isEmpty)
                    if roster.isEmpty {
                        Text("Select detected feeds to include in this rule.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Review Marker Candidates") {
                    clearResults()
                    request = Query(rule: rule)
                }
                .disabled(busy || kinds.isEmpty || (scopeToRoster && roster.isEmpty)
                          || (request?.rule == rule && markers == nil && failure == nil))
                .accessibilityIdentifier("participant.markers.review")
                if request?.rule == rule {
                    if let markers {
                        candidates(markers)
                    } else if let failure {
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView("Finding marker candidates…")
                            .controlSize(.small)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        } label: {
            Text("Layout Change Filters").accessibilityIdentifier("participant.markers")
        }
        .onChange(of: rule) { _, _ in
            request = nil
            clearResults()
        }
        .task(id: request) {
            guard let request else { return }
            let scan = result
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ParticipantAnalysis.markers(scan, rule: request.rule) }
            }.value
            guard !Task.isCancelled, self.request == request else { return }
            switch result {
            case .success(let candidates): markers = candidates
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private func membership<Value: Hashable>(_ value: Value, in selection: Binding<Set<Value>>) -> Binding<Bool> {
        .init(get: { selection.wrappedValue.contains(value) }, set: {
            if $0 { selection.wrappedValue.insert(value) } else { selection.wrappedValue.remove(value) }
        })
    }

    @ViewBuilder
    private func candidates(_ candidates: [ParticipantSceneMarker]) -> some View {
        if candidates.isEmpty {
            Text("No markers match this rule.").font(.caption).foregroundStyle(.secondary)
        } else {
            let visible = pages.indices(count: candidates.count)
            if visible.count < candidates.count {
                HStack {
                    Button("Previous Page", systemImage: "chevron.left") {
                        pages.move(by: -1, count: candidates.count)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(visible.lowerBound == 0)
                    Text("\(visible.lowerBound + 1)–\(visible.upperBound) of \(candidates.count)")
                        .font(.caption).monospacedDigit()
                        .accessibilityLabel("Markers \(visible.lowerBound + 1) through \(visible.upperBound) of \(candidates.count)")
                    Button("Next Page", systemImage: "chevron.right") {
                        pages.move(by: 1, count: candidates.count)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(visible.upperBound == candidates.count)
                }
            }
            ForEach(visible, id: \.self) { index in
                let marker = candidates[index]
                let selected = selectedTime == marker.time
                Button {
                    guard let end = try? marker.time.adding(.init(numerator: 1, denominator: 1_000_000)) else { return }
                    selectedTime = marker.time
                    seek(.init(from: marker.time, to: end))
                } label: {
                    HStack {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                        Text(candidateLabel(marker))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("participant.markers.candidate.\(marker.time.description)")
                .disabled(busy)
            }
        }
    }

    private func candidateLabel(_ marker: ParticipantSceneMarker) -> String {
        let changed = marker.changedCount
        let label = switch unit {
        case .participants: changed == 1 ? "participant" : "participants"
        case .slots: changed == 1 ? "slot" : "slots"
        }
        return "\(marker.time.description) s · \(changed) \(label) changed" + (marker.uncertain ? " · Uncertain" : "")
    }

    private func clearResults() {
        markers = nil
        failure = nil
        pages = ParticipantMarkerPages()
        selectedTime = nil
    }
}
