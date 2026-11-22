import SwiftUI

struct ProjectHistoryView: View {
    let actions: [String]
    let cursor: Int
    let disabled: Bool
    let restore: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project History").font(.title2.weight(.semibold))
            ScrollViewReader { scroll in
                List(selection: $selection) {
                    ForEach(0...actions.count, id: \.self) { state in
                        HStack {
                            Text(state == 0 ? "Earliest Retained State" : actions[state - 1])
                            Spacer()
                            if state == cursor {
                                Label("Current", systemImage: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .tag(state)
                        .id(state)
                    }
                }
                .accessibilityLabel("Project history states")
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onChange(of: cursor, initial: true) { _, index in
                    selection = index
                    scroll.scrollTo(index, anchor: .center)
                }
                .onChange(of: actions) { _, _ in selection = cursor }
                .help("Select a project state")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Close project history")
                Button("Restore State") {
                    guard let selection, (0...actions.count).contains(selection), selection != cursor else { return }
                    restore(selection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || selection == nil || selection == cursor)
                .help("Restore selected state")
            }
        }
        .padding(20)
        .frame(width: 430, height: 390)
    }
}
