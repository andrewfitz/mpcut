import MPCutCore
import SwiftUI

/// The capsule that names a timeline tier, shared by the editor and the multicam editor. Clicking it shows `details`.
struct TierBadge<Details: View>: View {
    let state: TierState
    let help: String
    var tintOverride: Color?
    @ViewBuilder let details: (_ dismiss: @escaping () -> Void) -> Details
    @State private var showsDetails = false

    var body: some View {
        let tint = tintOverride ?? TimelineTierBadge.tint(state)
        Button { showsDetails = true } label: {
            HStack(spacing: 4) {
                Image(systemName: TimelineTierBadge.symbol(state)).imageScale(.small)
                Text(state.name).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show export tier details")
        .accessibilityLabel("Export quality tier: \(state.name)")
        .accessibilityHint(help)
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            details { showsDetails = false }
        }
    }
}

/// What lowers a tier, grouped by the clip or range each factor belongs to, with a button that goes to its cut.
struct TierDetails<Footer: View>: View {
    let state: TierState
    let summary: String
    /// The heading for the factors of one segment. Zero stands for the whole timeline.
    let title: (Int) -> String
    /// What a segment is called in a factor's caption: "clip" or "range".
    let segmentName: String
    let canGo: Bool
    let go: (TierFactor) -> Void
    /// Names what a factor's message identifies by id.
    var describe: (String) -> String = { $0 }
    @ViewBuilder let footer: () -> Footer

    private struct Group: Identifiable {
        let id: Int
        let factors: [TierFactor]
    }

    private var groups: [Group] {
        var order: [Int] = [], bySegment: [Int: [TierFactor]] = [:]
        for factor in state.factors {
            let key = factor.segment ?? 0
            if bySegment[key] == nil { order.append(key) }
            bySegment[key, default: []].append(factor)
        }
        return order.map { Group(id: $0, factors: bySegment[$0] ?? []) }
    }

    private var warnings: [String] {
        if case .known(_, _, _, let warnings) = state { return warnings }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(state.name, systemImage: TimelineTierBadge.symbol(state))
                .font(.headline)
                .foregroundStyle(TimelineTierBadge.tint(state))
            Text(summary)
                .fixedSize(horizontal: false, vertical: true)
            if !groups.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title(group.id)).font(.subheadline.weight(.semibold))
                                ForEach(Array(group.factors.enumerated()), id: \.offset) { _, factor in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(describe(ExportRules.displayMessage(factor.message))).fixedSize(horizontal: false, vertical: true)
                                            Text(caption(factor)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        if factor.segment != nil {
                                            Button("Go to Cut") { go(factor) }
                                                .disabled(!canGo)
                                                .help("Jump to affected cut")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            footer()
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 420, alignment: .leading)
    }

    private func caption(_ factor: TierFactor) -> String {
        let edge = factor.boundary == "from" ? "Start of the \(segmentName) · " : factor.boundary == "to" ? "End of the \(segmentName) · " : ""
        let leaves = factor.forces.map { "Best export quality: \(ExportRules.displayName(tier: $0))" } ?? "Blocks export"
        return edge + leaves
    }
}
