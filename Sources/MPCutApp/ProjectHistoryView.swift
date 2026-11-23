import MPCutCore
import SwiftUI

struct ProjectHistoryAction: Equatable {
    let name: String
    let origin: HistoryOrigin

    var symbol: String {
        switch origin {
        case .user: "person"
        case .agent: "cpu"
        case .unknown: "questionmark.circle"
        }
    }
}

struct ProjectHistoryView: View {
    let actions: [ProjectHistoryAction]
    let cursor: Int
    let disabled: Bool
    let restore: (Int) -> Void
    let timeline: (Int) -> CutProject?
    @State private var comparison: TimelineComparison?
    /// The state to map. Presenting by item builds the sheet from the value set with it.
    @State private var mappingTimeline: MappedTimeline?
    @State private var isComparisonPresented = false
    @State private var comparisonError: String?
    @State private var comparisonTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int?
    @FocusState private var listFocused: Bool

    init(actions: [ProjectHistoryAction], cursor: Int, disabled: Bool, timeline: @escaping (Int) -> CutProject? = { _ in nil },
         restore: @escaping (Int) -> Void) {
        self.actions = actions
        self.cursor = cursor
        self.disabled = disabled
        self.timeline = timeline
        self.restore = restore
    }

    var body: some View {
        EditorSheet(title: "Project History",
                    message: "Select a state to restore it, compare it with the current timeline, or map a range through it.") {
            ScrollViewReader { scroll in
                List(selection: $selection) {
                    ForEach(0...actions.count, id: \.self) { state in
                        HStack(spacing: 8) {
                            Text(state == 0 ? "–" : "\(state)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 26, alignment: .trailing)
                                .accessibilityHidden(true)
                            Text(state == 0 ? "Earliest Retained State" : actions[state - 1].name)
                                .lineLimit(1)
                            Spacer()
                            if state > 0 {
                                let action = actions[state - 1]
                                Label(action.origin.rawValue.capitalized, systemImage: action.symbol)
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if state == cursor {
                                Label("Current", systemImage: "checkmark")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
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
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: 248)
                .modifier(InsetPanel())
            }
            if let comparisonError { IssueLabel(comparisonError) }
        } actions: {
                Button("Compare with Current", action: compare)
                    .disabled(disabled || selection == nil || selection == cursor || comparisonTask != nil)
                if comparisonTask != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Comparing timeline states")
                }
                Button("Map Range…", action: mapRange)
                    .disabled(disabled || selection == nil)
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
        .frame(width: 600)
        .sheet(isPresented: $isComparisonPresented) {
            if let comparison { TimelineComparisonView(comparison: comparison) }
        }
        .sheet(item: $mappingTimeline) { mapped in
            TimelineRangeMapView(timeline: mapped.project)
        }
        .onDisappear { cancelComparison() }
        .onChange(of: selection) { _, _ in cancelComparison() }
        .onChange(of: cursor) { _, _ in cancelComparison() }
        .onChange(of: actions) { _, _ in cancelComparison() }
    }

    private func compare() {
        guard let selection, let before = timeline(selection), let after = timeline(cursor) else {
            comparisonError = "A selected history state is unavailable."
            return
        }
        comparisonError = nil
        comparisonTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                Result { try TimelineComparison.compare(from: before, to: after) }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            comparisonTask = nil
            switch outcome {
            case .success(let diff):
                comparison = diff
                isComparisonPresented = true
            case .failure(let error):
                comparisonError = error.localizedDescription
            }
        }
    }

    private func mapRange() {
        guard let selection, let project = timeline(selection) else {
            comparisonError = "The selected history state is unavailable."
            return
        }
        comparisonError = nil
        mappingTimeline = MappedTimeline(project: project)
    }

    private func cancelComparison() {
        comparisonTask?.cancel()
        comparisonTask = nil
        comparisonError = nil
    }
}

private struct MappedTimeline: Identifiable {
    let id = UUID()
    let project: CutProject
}

private struct TimelineComparisonView: View {
    let comparison: TimelineComparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EditorSheet(title: "Compare with Current",
                    message: "Duration \(timelineTime(comparison.beforeDuration.seconds, milliseconds: true)) in the selected state, "
                        + "\(timelineTime(comparison.afterDuration.seconds, milliseconds: true)) now."
                        + (comparison.projectFields.isEmpty ? "" : " Changed: " + comparison.projectFields.map(label).joined(separator: ", ") + ".")) {
            Group {
                if comparison.changes.isEmpty {
                    ContentUnavailableView("No occurrence changes", systemImage: "timeline.selection",
                                           description: Text("Both states place the same clips at the same times."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(comparison.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(change.kind.rawValue)).font(.callout.weight(.semibold))
                            if let before = change.before { occurrence(before, name: "Selected") }
                            if let after = change.after { occurrence(after, name: "Current") }
                            if !change.fields.isEmpty {
                                Text(change.fields.map(label).joined(separator: ", "))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(height: 320)
            .modifier(InsetPanel())
        } actions: {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .frame(width: 580)
    }

    private func label(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func occurrence(_ occurrence: TimelineOccurrence, name: String) -> some View {
        let source = occurrence.file.map { URL(fileURLWithPath: $0).lastPathComponent }
        let input = occurrence.input.map(\.displayBounds)
        let detail = [source, input].compactMap { $0 }.joined(separator: " ")
        return Text("\(name) #\(occurrence.index + 1)  \(occurrence.output.displayBounds)   \(detail)")
            .font(.system(size: 12, design: .monospaced))
    }
}
