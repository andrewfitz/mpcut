import MPCutCore
import SwiftUI

struct TileBoxEntry: Identifiable {
    let id = UUID()
    let sourceID: String
    let time: RationalTime
    let bounds: ParticipantBounds?
}

struct TilesBoxEntrySheet: View {
    let entry: TileBoxEntry
    let apply: (ParticipantDrawnBounds) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var left: String
    @State private var top: String
    @State private var width: String
    @State private var height: String

    init(entry: TileBoxEntry, apply: @escaping (ParticipantDrawnBounds) -> Void) {
        self.entry = entry
        self.apply = apply
        let bounds = entry.bounds ?? .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        _left = State(initialValue: String(bounds.x))
        _top = State(initialValue: String(bounds.y))
        _width = State(initialValue: String(bounds.width))
        _height = State(initialValue: String(bounds.height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tile Box").font(.headline)
            Text("Enter coordinates from 0 to 1, measured from the upper-left corner of the picture.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading) {
                GridRow {
                    Text("Left")
                    TextField("Left", text: $left).labelsHidden()
                    Text("Top")
                    TextField("Top", text: $top).labelsHidden()
                }
                GridRow {
                    Text("Width")
                    TextField("Width", text: $width).labelsHidden()
                    Text("Height")
                    TextField("Height", text: $height).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Box") {
                    guard let bounds else { return }
                    apply(.init(sourceID: entry.sourceID, time: entry.time, bounds: bounds))
                    dismiss()
                }
                .disabled(bounds == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 365)
    }

    private var bounds: ParticipantBounds? {
        guard let x = Double(left), let y = Double(top), let w = Double(width), let h = Double(height),
              x >= 0, y >= 0, w > 0, h > 0, x + w <= 1, y + h <= 1 else { return nil }
        return .init(x: x, y: y, width: w, height: h)
    }
}
