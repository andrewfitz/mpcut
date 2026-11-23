import SwiftUI

struct TranscriptLaneChip: View {
    let label: String
    let colorSlot: Int

    var body: some View {
        HStack(spacing: 5) {
            MulticamLaneChip(slot: colorSlot)
            Text(label).lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
