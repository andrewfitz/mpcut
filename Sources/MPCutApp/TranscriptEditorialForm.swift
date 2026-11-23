import SwiftUI
import UniformTypeIdentifiers
import MPCutCore

enum TranscriptEditorialMode {
    case takes, script, suggestions

    var title: String {
        switch self {
        case .takes: "Compare Takes"
        case .script: "Align Script"
        case .suggestions: "Review Restarts and Fillers"
        }
    }

    var field: String {
        switch self {
        case .takes: "Dialogue to compare"
        case .script: "Paste script, one beat per line"
        case .suggestions: "Filler terms separated by commas"
        }
    }
}

struct TranscriptEditorialForm: View {
    let mode: TranscriptEditorialMode
    let indexes: [TranscriptIndex]
    let attachmentLabels: [String: String]
    let space: TranscriptSpace
    let playhead: RationalTime?
    let hasTarget: Bool
    let play: (TranscriptTake) -> Void
    let select: (TranscriptTake) -> Void
    let save: (TranscriptTake, String) throws -> Void
    let addToOrdered: (TranscriptTake) -> Void
    let review: (TranscriptEditRequest.Action, [TranscriptTake], TranscriptEditRequest.BoundaryPolicy) async throws -> Void

    @State private var text: String
    @State private var groups: [CandidateGroup] = []
    @State private var ordered: [Candidate] = []
    @State private var dismissed: Set<String> = []
    @State private var error: String?
    @State private var boundary = TranscriptEditRequest.BoundaryPolicy.nearestFrame
    @State private var isWorking = false
    @State private var hasSearched = false
    @State private var visibleLimit = 80
    @State private var searchTask: Task<Void, Never>?
    @State private var reviewTask: Task<Void, Never>?
    @State private var namedTake: Candidate?
    @State private var isImporting = false

    private struct Candidate: Identifiable, Sendable {
        let id: String
        let title: String
        let take: TranscriptTake
        let continuation: TranscriptTake?
    }

    private struct CandidateGroup: Identifiable, Sendable {
        let id: Int
        let title: String?
        let details: String?
        let takes: [Candidate]
    }

    init(mode: TranscriptEditorialMode, indexes: [TranscriptIndex], attachmentLabels: [String: String], space: TranscriptSpace,
         startingText: String, playhead: RationalTime?, hasTarget: Bool, play: @escaping (TranscriptTake) -> Void,
         select: @escaping (TranscriptTake) -> Void, save: @escaping (TranscriptTake, String) throws -> Void,
         addToOrdered: @escaping (TranscriptTake) -> Void, review: @escaping (TranscriptEditRequest.Action, [TranscriptTake], TranscriptEditRequest.BoundaryPolicy) async throws -> Void) {
        self.mode = mode
        self.indexes = indexes
        self.attachmentLabels = attachmentLabels
        self.space = space
        self.playhead = playhead
        self.hasTarget = hasTarget
        self.play = play
        self.select = select
        self.save = save
        self.addToOrdered = addToOrdered
        self.review = review
        _text = State(initialValue: mode == .takes ? startingText : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(mode.field, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .accessibilityIdentifier("transcript.editorial.text")
            HStack {
                if mode == .script {
                    Button("Import Script…") { isImporting = true }
                        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText]) { result in
                            do { text = try String(contentsOf: result.get(), encoding: .utf8) }
                            catch { self.error = error.localizedDescription }
                        }
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(mode.title) { find() }
                    .disabled(mode != .suggestions && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            results
            if !ordered.isEmpty { orderedActions }
            if let error { IssueLabel(error) }
        }
        .onDisappear { searchTask?.cancel(); reviewTask?.cancel() }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if hasSearched && groups.isEmpty && !isWorking {
                    Text("No candidates match these terms.").foregroundStyle(.secondary)
                }
                ForEach(groups.prefix(visibleLimit)) { group in
                    if let title = group.title {
                        Text(title).font(.headline)
                        if let details = group.details { Text(details).font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(group.takes.lazy.filter { !dismissed.contains($0.id) }.prefix(visibleLimit)) { candidate in
                        candidateRow(candidate)
                    }
                }
                if groups.count > visibleLimit || groups.contains(where: { $0.takes.count > visibleLimit }) {
                    Button("Show More") { visibleLimit += 80 }
                }
            }
            .padding(2)
        }
        .frame(minHeight: 80, idealHeight: 235, maxHeight: 300)
    }

    private func candidateRow(_ candidate: Candidate) -> some View {
        let take = candidate.take
        return VStack(alignment: .leading, spacing: 5) {
            if let first = take.words.first {
                Text(candidate.title + " · " + timelineTime(first.range.from.seconds, milliseconds: true))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                let source = first.attachmentID.flatMap { attachmentLabels[$0] }
                    ?? first.sourceID ?? first.file.map { URL(fileURLWithPath: $0).lastPathComponent }
                if let source {
                    Text(source + (first.assemblyIndex.map { " · Occurrence \($0 + 1)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(take.words.map(\.text).joined(separator: " "))
                .font(.callout).textSelection(.enabled)
            let context = (take.before + take.words + take.after).map(\.text).joined(separator: " ")
            Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if !take.missingTerms.isEmpty {
                Text("Missing " + take.missingTerms.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
            }
            if !take.additionalTerms.isEmpty {
                Text("Adds " + take.additionalTerms.joined(separator: ", ")).font(.caption)
            }
            if let continuation = candidate.continuation {
                LabeledContent("Continues with", value: continuation.words.map(\.text).joined(separator: " ")).font(.caption)
            }
            HStack {
                Button("Play Context", systemImage: "play.fill") { play(take) }
                if mode == .suggestions {
                    Button("Accept") { append(candidate) }.disabled(ordered.contains { $0.id == candidate.id })
                    Button("Dismiss") {
                        dismissed.insert(candidate.id)
                        ordered.removeAll { $0.id == candidate.id }
                    }
                } else {
                    Button("Select") { select(take) }
                    Button("Add") { append(candidate) }.disabled(ordered.contains { $0.id == candidate.id })
                    Menu("Select Options") {
                        Button("Add to Ordered Selects") { addToOrdered(take) }
                        Button("Save Named Select…") { namedTake = candidate }
                    }
                        .popover(isPresented: Binding(
                            get: { namedTake?.id == candidate.id },
                            set: { if !$0 && namedTake?.id == candidate.id { namedTake = nil } }
                        )) {
                            TranscriptTextForm(label: "Select name", initial: "") { name in
                                try save(take, name)
                                namedTake = nil
                            }
                            .padding(12).frame(width: 230)
                        }
                }
            }
            Divider()
        }
    }

    private var orderedActions: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeading(mode == .suggestions ? "Accepted for Review" : "Edit Order")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { item in
                        HStack {
                            Text(item.element.take.words.map(\.text).joined(separator: " ")).lineLimit(1)
                            Spacer(minLength: 0)
                            Button("Earlier", systemImage: "chevron.up") { ordered.swapAt(item.offset, item.offset - 1) }
                                .disabled(item.offset == 0).labelStyle(.iconOnly)
                            Button("Later", systemImage: "chevron.down") { ordered.swapAt(item.offset, item.offset + 1) }
                                .disabled(item.offset == ordered.count - 1).labelStyle(.iconOnly)
                            Button("Remove", systemImage: "xmark") { ordered.remove(at: item.offset) }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
            .frame(minHeight: 32, idealHeight: min(95, CGFloat(ordered.count) * 24), maxHeight: 95)
            TranscriptBoundaryMenu(policy: $boundary)
            HStack {
                Spacer()
                if mode == .suggestions {
                    Button("Review Accepted Cuts") { submit(.delete) }
                } else {
                    Menu("Review Edit") {
                        Button("Assemble in This Order") { submit(.assemble) }
                        Button("Insert at Playhead") { submit(.insert) }.disabled(playhead == nil)
                        Button("Replace Current Selection") { submit(.replace) }.disabled(!hasTarget)
                    }
                }
            }
        }
    }

    private func append(_ candidate: Candidate) {
        if !ordered.contains(where: { $0.id == candidate.id }) { ordered.append(candidate) }
    }

    private func submit(_ action: TranscriptEditRequest.Action) {
        guard reviewTask == nil else { return }
        reviewTask = Task {
            defer { reviewTask = nil }
            do { try await review(action, ordered.map(\.take), boundary) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }

    private func find() {
        searchTask?.cancel()
        let mode = mode
        let query = text
        let indexes = indexes
        let space = space
        isWorking = true
        error = nil
        visibleLimit = 80
        searchTask = Task { @MainActor in
            let task = Task.detached(priority: .userInitiated) {
                Self.candidates(mode, query: query, indexes: indexes, space: space)
            }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            groups = result
            dismissed = []
            hasSearched = true
            isWorking = false
        }
    }

    private nonisolated static func candidates(_ mode: TranscriptEditorialMode, query: String, indexes: [TranscriptIndex],
                                                space: TranscriptSpace) -> [CandidateGroup] {
        let words = indexes.flatMap { $0.readAll(space: space) }
        guard !Task.isCancelled else { return [] }
        func candidate(_ take: TranscriptTake, index: Int, group: Int) -> Candidate {
            .init(id: "\(group):\(index):\(take.words.first?.id ?? "")", title: take.kind.rawValue.capitalized,
                  take: take, continuation: nil)
        }
        switch mode {
        case .takes:
            let takes = TranscriptEditorial.compare(query, words: words)
            return takes.isEmpty ? [] : [.init(id: 0, title: nil, details: nil, takes: takes.enumerated().map {
                candidate($0.element, index: $0.offset, group: 0)
            })]
        case .script:
            return TranscriptEditorial.alignScript(query, words: words).enumerated().map { index, beat in
                let qualifiers = beat.qualifiers.map(\.text).joined(separator: ", ")
                let details = beat.status.rawValue.capitalized + (qualifiers.isEmpty ? "" : " · Qualifiers: " + qualifiers)
                    + (!beat.approximateSearch ? " · Exact phrase matching" : "")
                return .init(id: index, title: beat.text, details: details, takes: beat.candidates.enumerated().map {
                    candidate($0.element, index: $0.offset, group: index)
                })
            }
        case .suggestions:
            let terms = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let suggestions = TranscriptEditorial.suggest(words: words, fillerTerms: terms)
            return suggestions.isEmpty ? [] : [.init(id: 0, title: nil, details: nil, takes: suggestions.map {
                .init(id: $0.id, title: $0.kind.rawValue.capitalized, take: $0.candidate, continuation: $0.continuation)
            })]
        }
    }
}

struct TranscriptAuthoredForm: View {
    let records: [TranscriptAuthoredReview]
    let attachmentLabels: [String: String]
    let apply: (TranscriptEditRequest.Action, [TranscriptAuthoredReview], TranscriptEditRequest.BoundaryPolicy) async throws -> Void
    @State private var order: [String] = []
    @State private var reviewTask: Task<Void, Never>?
    @State private var policy = TranscriptEditRequest.BoundaryPolicy.nearestFrame
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if records.isEmpty {
                        Text("There are no saved selects or corrections.").foregroundStyle(.secondary)
                    }
                    ForEach(records, id: \.id) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title(record.change)).font(.headline)
                                Text(attachmentLabels[record.attachmentID] ?? "Unavailable transcript")
                                    .font(.caption).foregroundStyle(.secondary)
                                if record.anchors.isEmpty && attachmentLabels[record.attachmentID] == nil {
                                    Label("Transcript attachment unavailable", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                                if let matchStatus = record.matchStatus, matchStatus != .resolved {
                                    Label(matchStatus == .missing ? "Observation no longer matches" : "Observation match is ambiguous",
                                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                }
                                ForEach(Array(record.anchors.enumerated()), id: \.offset) { item in
                                    if item.element.status == .resolved {
                                        Text(item.element.words.map(\.text).joined(separator: " ")).lineLimit(3)
                                    } else {
                                        Label(item.element.status == .missing ? "Anchor no longer matches" : "Anchor is ambiguous",
                                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                    }
                                }
                            }
                            Spacer()
                            if case .namedSelect = record.change, record.anchors.allSatisfy({ $0.status == .resolved }) {
                                Button(order.contains(record.id) ? "Remove from Edit" : "Add to Edit") {
                                    if order.contains(record.id) { order.removeAll { $0 == record.id } }
                                    else { order.append(record.id) }
                                }
                            }
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 90, idealHeight: 225, maxHeight: 320)
            if !order.isEmpty {
                SectionHeading("Edit Order")
                ForEach(Array(order.enumerated()), id: \.element) { item in
                    if let record = records.first(where: { $0.id == item.element }) {
                        HStack {
                            Text(title(record.change))
                            Spacer()
                            Button("Earlier", systemImage: "chevron.up") { order.swapAt(item.offset, item.offset - 1) }
                                .labelStyle(.iconOnly).disabled(item.offset == 0)
                            Button("Later", systemImage: "chevron.down") { order.swapAt(item.offset, item.offset + 1) }
                                .labelStyle(.iconOnly).disabled(item.offset == order.count - 1)
                        }
                    }
                }
                TranscriptBoundaryMenu(policy: $policy)
                Menu("Review Edit") {
                    Button("Assemble in This Order") { review(.assemble) }
                    Button("Insert at Playhead") { review(.insert) }
                    Button("Replace Current Selection") { review(.replace) }
                }
            }
            if let error { IssueLabel(error) }
        }
    }

    private func review(_ action: TranscriptEditRequest.Action) {
        guard reviewTask == nil else { return }
        reviewTask = Task {
            defer { reviewTask = nil }
            do { try await apply(action, order.compactMap { id in records.first { $0.id == id } }, policy) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }

    private func title(_ change: TranscriptAuthoredChange) -> String {
        switch change {
        case .replaceText(let text): "Correction · \(text)"
        case .assignSpeaker: "Speaker Assignment"
        case .renameSpeaker(_, let name): "Speaker · \(name)"
        case .mergeSpeakers: "Merged Speakers"
        case .splitSpeaker(_, let name): "New Speaker · \(name)"
        case .matchOverride(_, let accepted, _): accepted ? "Confirmed Match" : "Rejected Match"
        case .namedSelect(let name): name
        case .pauseProtection(let name): "Protected Pause · \(name)"
        }
    }
}

struct TranscriptOrderedForm: View {
    @Binding var selects: [TranscriptOrderedSelect]
    let hasTarget: Bool
    let hasPlayhead: Bool
    let copy: ([TranscriptOrderedSelect]) async throws -> Void
    let review: (TranscriptEditRequest.Action, [TranscriptOrderedSelect], TranscriptEditRequest.BoundaryPolicy, String?) async throws -> Void
    @State private var boundary = TranscriptEditRequest.BoundaryPolicy.nearestFrame
    @State private var action = TranscriptEditRequest.Action.assemble
    @State private var name = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(selects.enumerated()), id: \.element.id) { item in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading) {
                                Text(item.element.title).lineLimit(2)
                                Text(item.element.source).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Move Earlier", systemImage: "chevron.up") { selects.swapAt(item.offset, item.offset - 1) }
                                .labelStyle(.iconOnly).disabled(item.offset == 0)
                            Button("Move Later", systemImage: "chevron.down") { selects.swapAt(item.offset, item.offset + 1) }
                                .labelStyle(.iconOnly).disabled(item.offset + 1 == selects.count)
                            Button("Remove", systemImage: "xmark") { selects.remove(at: item.offset) }
                                .labelStyle(.iconOnly)
                        }
                        Divider()
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 90, idealHeight: 200, maxHeight: 320)
            Picker("Action", selection: $action) {
                Text("Assemble in This Order").tag(TranscriptEditRequest.Action.assemble)
                Text("Insert at Playhead").tag(TranscriptEditRequest.Action.insert).disabled(!hasPlayhead)
                Text("Replace Current Selection").tag(TranscriptEditRequest.Action.replace).disabled(!hasTarget)
                Text("Queue as One Excerpt").tag(TranscriptEditRequest.Action.queue)
            }
            if action == .queue {
                TextField("Excerpt Name", text: $name).accessibilityIdentifier("transcript.queue.name")
            }
            TranscriptBoundaryMenu(policy: $boundary)
            if let error { IssueLabel(error) }
            HStack {
                Button("Copy Quotes with References") { submit(copyOnly: true) }
                    .disabled(task != nil || selects.isEmpty)
                Spacer()
                if task != nil { ProgressView().controlSize(.small) }
                Button("Review Edit") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("transcript.reviewEdit")
                    .disabled(task != nil || selects.isEmpty || (action == .queue && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func submit(copyOnly: Bool = false) {
        let chosen = selects
        task = Task {
            defer { task = nil }
            do {
                if copyOnly { try await copy(chosen) }
                else { try await review(action, chosen, boundary, action == .queue ? name : nil) }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct TranscriptIndexWork: Sendable {
    let attachmentID: String
    let label: String
    let load: @Sendable () throws -> TranscriptIndex
}

struct TranscriptProjectIndexes<Content: View>: View {
    let jobs: [TranscriptIndexWork]
    @ViewBuilder let content: ([TranscriptIndex]) -> Content
    @State private var results: [TranscriptIndex]?
    @State private var failures: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let results {
                if !failures.isEmpty {
                    ForEach(failures, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                content(results)
            } else {
                ProgressView("Opening project transcripts…").controlSize(.small)
                    .frame(minHeight: 70)
            }
        }
        .task {
            let load = Task.detached(priority: .userInitiated) {
                var indexes: [TranscriptIndex] = []
                var failures: [String] = []
                for job in jobs {
                    guard !Task.isCancelled else { break }
                    do { indexes.append(try job.load()) }
                    catch { failures.append(job.label + " · " + error.localizedDescription) }
                }
                return (indexes, failures)
            }
            let loaded = await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
            guard !Task.isCancelled else { return }
            results = loaded.0
            failures = loaded.1
        }
    }
}
