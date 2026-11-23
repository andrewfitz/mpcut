import MPCutCore
import SwiftUI

struct TimelineRangeMapView: View {
    let timeline: CutProject
    @Environment(\.dismiss) private var dismiss
    @State private var clock: TimelineClock
    @State private var start = ""
    @State private var end = ""
    @State private var result: TimelineMapping?
    @State private var error: String?
    @State private var request: Task<Void, Never>?

    init(timeline: CutProject) {
        self.timeline = timeline
        _clock = State(initialValue: timeline.timelineOutputClock)
    }

    var body: some View {
        EditorSheet(title: "Map Timeline Range",
                    message: "Enter a range on one clock to see the source and output times it covers.") {
            HStack(spacing: 8) {
                Picker("Clock", selection: $clock) {
                    Text(timeline.timelineInputClock.rawValue.capitalized).tag(timeline.timelineInputClock)
                    Text(timeline.timelineOutputClock.rawValue.capitalized).tag(timeline.timelineOutputClock)
                }
                .fixedSize()
                .help("Choose the clock the range is measured on")
                TextField("From", text: $start, prompt: Text("From (seconds)")).accessibilityLabel("Inclusive start time")
                    .onSubmit(query)
                TextField("To", text: $end, prompt: Text("To (seconds)")).accessibilityLabel("Exclusive end time")
                    .onSubmit(query)
                Button("Map Range", action: query)
                    .disabled(start.isEmpty || end.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if let error { IssueLabel(error) }
            results
                .frame(height: 220)
                .modifier(InsetPanel())
        } actions: {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        // A nested sheet sizes from its first layout. Without a height it can open at zero size.
        .frame(width: 550, height: 400)
        .onDisappear { reset() }
        .onChange(of: clock) { _, _ in reset() }
        .onChange(of: start) { _, _ in reset() }
        .onChange(of: end) { _, _ in reset() }
    }

    @ViewBuilder private var results: some View {
            if let result {
                if result.pieces.isEmpty {
                    ContentUnavailableView("No matching occurrences", systemImage: "timeline.selection",
                                           description: Text("Nothing on the timeline falls inside that range."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(result.pieces, id: \.index) { piece in
                        let input = piece.input.map { "\(result.inputClock.rawValue.capitalized) \($0.displayBounds)" }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(piece.file.map { URL(fileURLWithPath: $0).lastPathComponent } ??
                                 (piece.assetID == nil ? "Group Range" : "Inserted Still"))
                            Text([input, "\(result.outputClock.rawValue.capitalized) \(piece.output.displayBounds)"]
                                .compactMap { $0 }.joined(separator: "  ·  "))
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .padding(.vertical, 2)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            } else if request != nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No range mapped", systemImage: "arrow.left.and.right",
                                       description: Text("Results appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private func reset() {
        request?.cancel()
        request = nil
        result = nil
        error = nil
    }

    private func query() {
        reset()
        do {
            let range = try MulticamRange(from: RationalTime(parsing: start), to: RationalTime(parsing: end))
            let project = timeline
            let space = clock
            request = Task {
                let worker = Task.detached(priority: .userInitiated) {
                    Result { try project.mapTimelineRange(range, clock: space) }
                }
                let mapped = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                request = nil
                switch mapped {
                case .success(let mapping): result = mapping
                case .failure(let issue): error = issue.localizedDescription
                }
            }
        } catch let issue {
            error = issue.localizedDescription
        }
    }
}

extension MulticamRange {
    var displayBounds: String { "\(from)–\(to)" }
}
