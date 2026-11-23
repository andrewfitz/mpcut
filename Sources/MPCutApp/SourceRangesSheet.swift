import SwiftUI
import UniformTypeIdentifiers
import MPCutCore

struct SourceRangesSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable, Sendable {
        let id = UUID()
        var file: String
        var from: String
        var to: String
        var name = ""
        var savedID: String?

        init(_ range: SequenceSourceRange, name: String = "", savedID: String? = nil) {
            file = range.file
            from = range.from.description
            to = range.to.description
            self.name = name
            self.savedID = savedID
        }
        init(file: URL) {
            self.file = file.path
            from = "0"
            to = ""
        }

    }

    @State private var generation: UUID
    @State private var revision: Int
    @State private var playhead: RationalTime?
    @State private var selection: MulticamRange?
    @State private var rows: [Row]
    @State private var replace = false
    @State private var choosingFiles = false
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    private var working: Bool { operation != nil }

    init(editor: EditorModel) {
        self.editor = editor
        _generation = State(initialValue: editor.mcpGeneration)
        _revision = State(initialValue: editor.mcpRevision)
        _playhead = State(initialValue: editor.sourceRangePlayhead)
        _selection = State(initialValue: editor.sourceRangeSelection)
        _rows = State(initialValue: editor.sourceRangeForSelection.map { [Row($0)] } ?? [])
    }

    var body: some View {
        EditorSheet(title: "Source Ranges",
                    message: "Build an ordered plan of source ranges, then place it in the sequence.") {
            HStack(spacing: 8) {
                Button("Add Files…") { choosingFiles = true }
                    .help("Add whole files to the plan")
                Menu("Named Selects") {
                    ForEach(editor.stillProject.sourceSelects) { select in
                        Menu(select.name) {
                            Button("Add to Plan") { rows.append(Row(select.range, name: select.name, savedID: select.id)) }
                            Button("Remove Saved Select", role: .destructive) {
                                run {
                                    try editor.removeSourceSelect(select.id, expectedRevision: revision)
                                    for index in rows.indices where rows[index].savedID == select.id {
                                        rows[index].savedID = nil
                                    }
                                }
                            }
                        }
                        .help(select.range.file)
                    }
                }
                .fixedSize()
                .disabled(editor.stillProject.sourceSelects.isEmpty)
                .help(editor.stillProject.sourceSelects.isEmpty ? "No named selects saved in this project" : "Add a saved select to the plan")
                Spacer(minLength: 0)
                if !rows.isEmpty {
                    Text(rows.count == 1 ? "1 range" : "\(rows.count) ranges")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Group {
                if rows.isEmpty {
                    ContentUnavailableView("No source ranges", systemImage: "list.bullet.rectangle",
                                           description: Text("Add files or named selects to build a plan."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach($rows) { $row in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 2) {
                                    Text(URL(fileURLWithPath: row.file).lastPathComponent)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(row.file)
                                    Spacer(minLength: 8)
                                    rowButton("Move range up", symbol: "arrow.up") { move(row.id, by: -1) }
                                        .disabled(rows.first?.id == row.id)
                                    rowButton("Move range down", symbol: "arrow.down") { move(row.id, by: 1) }
                                        .disabled(rows.last?.id == row.id)
                                    rowButton("Remove range from plan", symbol: "minus.circle") { rows.removeAll { $0.id == row.id } }
                                }
                                HStack(spacing: 8) {
                                    field("From", width: 84) { TextField("Source start", text: $row.from, prompt: Text("Start")) }
                                    field("To", width: 84) {
                                        TextField("Source end", text: $row.to, prompt: Text("File end"))
                                            .help("Leave blank to use the end of the file")
                                    }
                                    field("Name", width: nil) { TextField("Select name", text: $row.name, prompt: Text("Optional")) }
                                    Button(row.savedID == nil ? "Save Select" : "Update Select") { save(row) }
                                        .controlSize(.small)
                                        .disabled(row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        .help("Save this range as a named select in the project")
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(height: 236)
            .modifier(InsetPanel())
            if let error { IssueLabel(error).textSelection(.enabled) }
        } actions: {
            Picker("Place at", selection: $replace) {
                Text("Playhead").tag(false)
                if selection != nil { Text("Selected Range").tag(true) }
            }
            .fixedSize()
            .help("Choose where the plan goes")
            if let destination {
                Text(destination.from == destination.to ? timelineTime(destination.from.seconds, milliseconds: true) :
                     "\(timelineTime(destination.from.seconds, milliseconds: true)) – \(timelineTime(destination.to.seconds, milliseconds: true))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Destination time")
            }
            if working { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(replace ? "Replace Selection" : "Insert at Playhead") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.isEmpty || (replace ? selection == nil : playhead == nil))
        }
        .frame(width: 620)
        .disabled(working)
        .interactiveDismissDisabled(working)
        .onDisappear { operation?.cancel() }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): rows.append(contentsOf: files.map(Row.init(file:)))
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func rowButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(ToolButtonStyle())
        .accessibilityLabel(title)
        .help(title)
    }

    /// A captioned text field. The caption stays once the field has a value, unlike a prompt.
    private func field<Content: View>(_ caption: String, width: CGFloat?, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .frame(width: width)
        }
    }

    private func move(_ id: UUID, by direction: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + direction) else { return }
        rows.swapAt(index, index + direction)
    }

    private func save(_ row: Row) {
        run {
            let ranges = try await resolve([row])
            let select = try NamedSourceSelect(id: row.savedID ?? UUID().uuidString, name: row.name, range: ranges[0])
            try checkGeneration()
            try await editor.saveSourceSelect(select, expectedRevision: revision)
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index].savedID = select.id
            }
        }
    }

    private var destination: MulticamRange? {
        replace ? selection : playhead.map { MulticamRange(from: $0, to: $0) }
    }

    private func apply() {
        guard let destination else { return }
        run {
            let ranges = try await resolve(rows)
            try checkGeneration()
            try await editor.applySourceRanges(ranges, destination: destination, expectedRevision: revision)
            dismiss()
        }
    }

    private func resolve(_ rows: [Row]) async throws -> [SequenceSourceRange] {
        let lookup = Task.detached(priority: .userInitiated) {
            let engine = CutEngine(cancelled: { Task.isCancelled }, useSidecar: false)
            var durations: [URL: RationalTime] = [:]
            return try rows.map { row in
                let from = try RationalTime(parsing: row.from.trimmingCharacters(in: .whitespacesAndNewlines))
                let end = row.to.trimmingCharacters(in: .whitespacesAndNewlines)
                let to: RationalTime
                if end.isEmpty {
                    let url = try CutProject.checkedMediaURL(row.file, relativeTo: URL(fileURLWithPath: "/"))
                    to = try durations[url] ?? engine.inspectSummary(url).duration
                    durations[url] = to
                } else {
                    to = try RationalTime(parsing: end)
                }
                return try SequenceSourceRange(file: row.file, from: from, to: to)
            }
        }
        return try await withTaskCancellationHandler {
            try await lookup.value
        } onCancel: {
            lookup.cancel()
        }
    }

    private func checkGeneration() throws {
        try Task.checkCancellation()
        guard editor.mcpGeneration == generation, editor.mcpRevision == revision else {
            throw CutError(code: "stale_revision", message: "The sequence changed. Reopen Source Ranges to review the current sequence.")
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        error = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do {
                try checkGeneration()
                try await action()
                revision = editor.mcpRevision
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
