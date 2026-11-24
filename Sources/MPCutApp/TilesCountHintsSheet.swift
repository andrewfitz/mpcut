import MPCutCore
import SwiftUI

struct TilesCountHintsSheet: View {
    let apply: (TilesCountHints?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feeds: String
    @State private var tiles: String

    init(hints: TilesCountHints?, apply: @escaping (TilesCountHints?) -> Void) {
        self.apply = apply
        _feeds = State(initialValue: hints?.expectedFeeds.map(String.init) ?? "")
        _tiles = State(initialValue: hints?.maxVisibleTiles.map(String.init) ?? "")
    }

    private var valid: Bool {
        [feeds, tiles].allSatisfy { $0.isEmpty || Int($0).map { $0 > 0 } == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tile Count Hints").font(.headline)
            Text("These hints flag recordings that need review. Leave either field blank to clear that hint.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading) {
                GridRow {
                    Text("Expected feeds")
                    TextField("Expected feeds", text: $feeds)
                        .labelsHidden()
                        .accessibilityIdentifier("tiles.hints.feeds")
                }
                GridRow {
                    Text("Maximum visible tiles")
                    TextField("Maximum visible tiles", text: $tiles)
                        .labelsHidden()
                        .accessibilityIdentifier("tiles.hints.maxVisible")
                }
            }
            HStack {
                Button("Clear Hints") { save(nil) }
                    .accessibilityIdentifier("tiles.hints.clear")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { save(.init(expectedFeeds: Int(feeds), maxVisibleTiles: Int(tiles))) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tiles.hints.apply")
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 395)
    }

    private func save(_ hints: TilesCountHints?) {
        apply(hints)
        dismiss()
    }
}
