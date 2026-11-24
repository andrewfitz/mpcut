import AppKit
import ImageIO
import MPCutCore
import SwiftUI

enum ProjectMediaAction: Int {
    case locate, replace, reveal, show

    var title: String {
        switch self {
        case .locate: "Locate Media…"
        case .replace: "Replace Source File…"
        case .reveal: "Reveal in Finder"
        case .show: "Show in Project Media"
        }
    }
}

struct ProjectMediaViewRevision: Equatable {
    let generation: UUID
    let edit: Int
}

struct ProjectMediaRequest: Identifiable {
    let id = UUID()
    var path: String?
    var action: ProjectMediaAction = .show
    var useID: String?
    var offlineOnly = false
}

enum ProjectMediaFilter: String, CaseIterable {
    case offline = "Offline"
    case review = "Needs review"
    case all = "All"

    func includes(_ status: ProjectMediaStatus) -> Bool {
        switch self {
        case .offline: status == .offline || status == .checking || status == .ignored
        case .review: status == .changed || status == .needsReview
        case .all: true
        }
    }
}

extension ProjectMediaStatus {
    var editorLabel: String {
        switch self {
        case .online: "Online"
        case .indexing: "Indexing…"
        case .offline: "Media Offline"
        case .checking: "Checking…"
        case .changed: "Changed"
        case .needsReview: "Needs Review"
        case .ignored: "Left Offline"
        }
    }

    var editorIcon: String {
        switch self {
        case .online: "checkmark.circle"
        case .indexing: "hourglass"
        case .offline: "exclamationmark.triangle.fill"
        case .checking: "ellipsis.circle"
        case .changed, .needsReview: "exclamationmark.circle.fill"
        case .ignored: "nosign"
        }
    }

    var editorColor: NSColor {
        switch self {
        case .offline: .systemRed
        case .changed, .needsReview: .systemOrange
        default: .secondaryLabelColor
        }
    }

    var hidesMedia: Bool {
        switch self {
        case .offline, .ignored, .checking, .indexing: true
        default: false
        }
    }
}

struct ProjectMediaAlertSummary {
    let offline: Int
    let review: Int

    init(_ statuses: [ProjectMediaStatus]) {
        offline = statuses.filter { $0 == .offline }.count
        review = statuses.filter { $0 == .changed || $0 == .needsReview }.count
    }

    var title: String? {
        if offline == 1 { return "1 file offline" }
        if offline > 1 { return "\(offline) files offline" }
        if review > 0 { return "Media needs review" }
        return nil
    }
}

struct ProjectMediaSlate: View {
    let url: URL
    let status: ProjectMediaStatus
    let locate: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Color(nsColor: status.editorColor)).frame(height: 4)
            Spacer()
            if status == .indexing || status == .checking {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            Label(status.editorLabel, systemImage: status.editorIcon)
                .font(.headline)
                .foregroundStyle(Color(nsColor: status.editorColor))
            Text(url.lastPathComponent).bold()
            Text(url.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
            if status == .offline || status == .ignored {
                Button("Locate…", action: locate)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.editorLabel): \(url.lastPathComponent)")
    }
}

struct ProjectMediaBanner: View {
    let count: Int
    let open: () -> Void
    @State private var dismissed = false

    var body: some View {
        if count > 0 && !dismissed {
            HStack {
                Label(count == 1 ? "1 file is offline" : "\(count) files are offline",
                      systemImage: ProjectMediaStatus.offline.editorIcon)
                Spacer()
                Button("Relink…", action: open)
                Button("Not now") { dismissed = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .foregroundStyle(Color(nsColor: ProjectMediaStatus.offline.editorColor))
        }
    }
}

@MainActor
final class ProjectMediaJobs: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var issue: String?
    @Published private(set) var located: Located?
    @Published private(set) var transcriptSetup: TranscriptSetupRequest?
    private var task: Task<Void, Never>?
    private var activeID: UUID?

    struct Located {
        let rows: [ProjectMediaSearchRow]
        let revision: ProjectMediaViewRevision
    }

    func start(_ title: String, work: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        let id = UUID()
        activeID = id
        self.title = title
        issue = nil
        task = Task { [weak self] in
            defer { self?.finish(id) }
            do { try await work() }
            catch is CancellationError {}
            catch {
                if self?.activeID == id { self?.issue = error.localizedDescription }
            }
        }
    }

    func publishMatches(_ rows: [ProjectMediaSearchRow], at revision: ProjectMediaViewRevision) {
        located = .init(rows: rows, revision: revision)
    }

    func takeMatches(at revision: ProjectMediaViewRevision) -> [ProjectMediaSearchRow] {
        defer { located = nil }
        return located?.revision == revision ? located?.rows ?? [] : []
    }

    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        title = nil
        task = nil
    }

    func queueTranscription(_ targets: Set<TranscriptSetupTarget>) {
        transcriptSetup = .init(targets: targets)
    }

    func takeTranscription() -> TranscriptSetupRequest? {
        defer { transcriptSetup = nil }
        return transcriptSetup
    }

    func cancel() { task?.cancel() }

    func reset() {
        task?.cancel()
        if let id = activeID { finish(id) }
        issue = nil
        located = nil
        transcriptSetup = nil
    }

    func clearIssue() { issue = nil }
}

struct ProjectMediaJobStatus: View {
    @ObservedObject var jobs: ProjectMediaJobs
    let open: () -> Void

    var body: some View {
        if let title = jobs.title {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(title).lineLimit(1).help(title)
            Button("Cancel", action: jobs.cancel).help("Cancel the Project Media job")
            StatusBarDivider()
        } else if let located = jobs.located {
            BarButton("Review located media", symbol: "magnifyingglass", action: open)
                .help("\(located.rows.count) candidate matches")
            StatusBarDivider()
        } else if let issue = jobs.issue {
            BarButton("Project Media", symbol: ProjectMediaStatus.needsReview.editorIcon, action: open)
                .help(issue)
            StatusBarDivider()
        }
    }
}

@MainActor
struct ProjectMediaSheet: View {
    @ObservedObject var jobs: ProjectMediaJobs
    let request: ProjectMediaRequest
    let archive: () -> LiveProjectMediaArchive?
    let revision: () -> ProjectMediaViewRevision
    let isMulticam: Bool
    let status: (URL) -> ProjectMediaStatus
    let relinkBatch: ([ProjectMediaMapping]) async throws -> LiveProjectMediaRelinkBatch
    let revert: (String) async throws -> Bool
    let ignore: (String) throws -> Void
    let replace: (MediaReplacePreview) async throws -> Bool
    let showUse: (ProjectMediaUse) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("project_media_last_locate_folder") private var lastFolder = ""
    @State private var inventory: [ProjectMediaRow] = []
    @State private var filter = ProjectMediaFilter.all
    @State private var selected: String?
    @State private var searching = false
    @State private var matchRevision: ProjectMediaViewRevision?
    @State private var task: Task<Void, Never>?
    @State private var issue: String?
    @State private var searchRows: [ProjectMediaSearchRow] = []
    @State private var candidateChoices: [String: URL] = [:]
    @State private var included: Set<String> = []
    @State private var replacement: Replacement?
    @State private var pickerWindow: NSWindow?
    @State private var isVisible = false

    private var working: Bool { searching || jobs.title != nil }

    private struct Replacement: Sendable {
        let path: String
        let candidate: URL
        let uses: [ProjectMediaUse]
        let stillFraming: StillImageFraming?
        var scopeUses: [ProjectMediaUse] {
            var seen = Set<String>()
            return uses.filter { seen.insert($0.id).inserted }
        }
        var options: MediaReplaceOptions
        var preview: MediaReplacePreview?
        var spans: [MediaReplacementDisplaySpan] = []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(replacement == nil ? "Project Media" : "Replace Source File").font(.title2.bold())
            if let replacement {
                replacementForm(replacement)
            } else if !searchRows.isEmpty {
                matches
            } else {
                browser
            }
            if let issue = issue ?? jobs.issue { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if let title = jobs.title {
                    ProgressView(title).controlSize(.small)
                    Button("Cancel Job", action: jobs.cancel)
                } else if searching {
                    ProgressView().controlSize(.small)
                    Button("Cancel Job") { task?.cancel() }
                }
                Spacer()
                if replacement != nil || !searchRows.isEmpty {
                    Button("Back") { replacement = nil; searchRows = []; issue = nil; jobs.clearIssue() }
                        .disabled(working)
                }
                Button(jobs.title == nil ? "Done" : "Continue in Background") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 510)
        .background(ProjectMediaWindowReader { pickerWindow = $0 })
        .task {
            isVisible = true
            filter = request.offlineOnly ? .offline : .all
            selected = request.path
            searching = true
            await reload()
            searching = false
            let located = jobs.takeMatches(at: revision())
            if !located.isEmpty { prepareMatches(located) }
            guard !Task.isCancelled, jobs.title == nil,
                  let row = inventory.first(where: { $0.path == request.path || $0.url.path == request.path }) else { return }
            selected = row.path
            switch request.action {
            case .locate: locate(row)
            case .replace: chooseReplacement(row, useID: request.useID)
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([row.url])
            case .show: break
            }
        }
        .onChange(of: jobs.title) { old, new in
            if old != nil && new == nil {
                Task {
                    await reload()
                    let located = jobs.takeMatches(at: revision())
                    if !located.isEmpty { prepareMatches(located) }
                }
            }
        }
        .onDisappear {
            isVisible = false
            task?.cancel()
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(ProjectMediaFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Spacer()
                Button("Locate Folder…") { locate(nil) }
            }
            List(selection: $selected) {
                ForEach(inventory.filter { filter.includes(rowStatus($0)) }, id: \.path) { row in
                    mediaRow(row).tag(row.path)
                }
            }
            .overlay {
                if inventory.filter({ filter.includes(rowStatus($0)) }).isEmpty {
                    Text(searching ? "Checking project media…" : "No files in this view").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(working)
    }

    private func mediaRow(_ row: ProjectMediaRow) -> some View {
        let state = rowStatus(row)
        let timelineUses = row.uses.filter(projectMediaNavigableUse)
        let informational = state == .offline && !row.uses.isEmpty && row.uses.allSatisfy { $0.kind == .original }
        let statusTitle = informational ? "Original unavailable" : state.editorLabel
        return HStack(spacing: 12) {
            Image(systemName: mediaKindIcon(row)).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.url.lastPathComponent).fontWeight(.medium)
                Text(row.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary).help(row.path)
                Text(useSummary(row.uses)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let duration = row.duration { Text(timelineTime(duration.seconds)).monospacedDigit().font(.caption) }
            Label(statusTitle, systemImage: informational ? "info.circle" : state.editorIcon).font(.caption)
                .foregroundStyle(Color(nsColor: informational ? .secondaryLabelColor : state.editorColor))
            Menu {
                Button(locateTitle(row)) { locate(row) }
                Button("Replace Source File…") { chooseReplacement(row, useID: nil) }
                if state == .offline || state == .checking {
                    Button("Leave Offline") { run { try ignore(row.path); await reload() } }
                }
                if row.canRevert {
                    Button("Revert to Previous Location") {
                        runInBackground("Restoring media location…") { _ = try await revert(row.path); await reload() }
                    }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                    .disabled(state.hidesMedia)
                if !timelineUses.isEmpty {
                    Menu("Show Uses") {
                        ForEach(Array(timelineUses.enumerated()), id: \.offset) { index, use in
                            Button(useLabel(use, index: index)) { dismiss(); showUse(use) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("Actions for \(row.url.lastPathComponent)")
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(statusTitle): \(row.url.lastPathComponent)")
    }

    private func rowStatus(_ row: ProjectMediaRow) -> ProjectMediaStatus {
        status(row.url)
    }

    private func reload() async {
        guard let archive = archive() else { inventory = []; return }
        let urls = Set(ProjectMedia.references(in: archive.project, includePlannedSpans: false).map {
            ProjectMediaVolume.watchURL($0.path, relativeTo: archive.documentURL)
        })
        let statuses = Dictionary(uniqueKeysWithValues: urls.map { ($0, status($0)) })
        inventory = await Task.detached(priority: .utility) {
            ProjectMedia.inventory(project: archive.project, undo: archive.undo, redo: archive.redo,
                                   relativeTo: archive.documentURL, snapshot: archive.snapshot, statuses: statuses, checkFile: false)
        }.value
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !searching else { return }
        searching = true
        issue = nil
        jobs.clearIssue()
        task = Task {
            defer { searching = false }
            do { try await body() }
            catch is CancellationError {}
            catch { issue = error.localizedDescription }
        }
    }

    private func chooseCandidate(directories: Bool, files: Bool, title: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = title
        if !lastFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: lastFolder, isDirectory: true) }
        if let window = pickerWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    private func locate(_ row: ProjectMediaRow?) {
        chooseCandidate(directories: true, files: row != nil, title: row.map(locateTitle) ?? "Locate Media Folder") { url in
            guard let input = archive() else { return }
            let checkedRevision = revision()
            let statuses = Dictionary(uniqueKeysWithValues: inventory.map { ($0.url, rowStatus($0)) })
            let checking = Set(statuses.filter { $0.value == .checking }.keys.map(ProjectMediaVolume.key))
            if url.hasDirectoryPath {
                run {
                    let rows = try await mediaWork {
                        try ProjectMediaVolume.$checking.withValue(checking) {
                            try ProjectMedia.locate(project: input.project, undo: input.undo, redo: input.redo,
                                                    snapshot: input.snapshot, relativeTo: input.documentURL,
                                                    folder: url, statuses: statuses)
                        }
                    }
                    try Task.checkCancellation()
                    guard !rows.isEmpty else { issue = "No matching files were found in this folder."; return }
                    guard revision() == checkedRevision else { throw staleLiveProjectMedia() }
                    prepareMatches(rows)
                }
            } else if let row {
                runInBackground("Checking and relinking media…") {
                    let candidate = try await mediaWork {
                        try ProjectMediaVolume.$checking.withValue(checking) {
                            try ProjectMedia.assess(project: input.project, undo: input.undo, redo: input.redo,
                                                    snapshot: input.snapshot, relativeTo: input.documentURL, from: row.path, to: url)
                        }
                    }
                    try Task.checkCancellation()
                    guard revision() == checkedRevision else { throw staleLiveProjectMedia() }
                    switch candidate.outcome {
                    case .verified, .match:
                        let result = try await relinkBatch([.init(from: row.path, candidate: candidate)])
                        guard result.changed else {
                            throw CutError(code: "media_relink_failed",
                                           message: result.failures.values.first ?? "The file could not be relinked.")
                        }
                        lastFolder = url.deletingLastPathComponent().path
                        await reload()
                        if let current = archive() { try await findPrefixMatches(current, path: row.path, candidate: url) }
                    case .different:
                        if isVisible {
                            issue = candidate.reason
                            openReplacement(row, url: url, useID: nil)
                        } else {
                            throw CutError(code: "media_different", message: candidate.reason ?? "Choose Replace Source File in Project Media.")
                        }
                    case .pending, .ambiguous:
                        throw CutError(code: "media_relink_pending", message: candidate.reason ?? "The recording could not be verified.")
                    }
                }
            }
        }
    }

    private func runInBackground(_ title: String, work: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        issue = nil
        jobs.start(title, work: work)
    }

    private func findPrefixMatches(_ input: LiveProjectMediaArchive, path: String, candidate: URL) async throws {
        let old = ProjectMediaVolume.watchURL(path, relativeTo: input.documentURL)
        let (oldRoot, newRoot) = projectMediaPrefixRoots(from: old, to: candidate)
        let offline = Set(inventory.filter { rowStatus($0) == .offline }.map { $0.url.path })
        let checkedRevision = revision()
        let rows = try await mediaWork {
            let mappings = ProjectMedia.prefixMappings(project: input.project, undo: input.undo, redo: input.redo,
                                                       relativeTo: input.documentURL, from: oldRoot, to: newRoot)
            return mappings.compactMap { mapping -> ProjectMediaSearchRow? in
                guard offline.contains(mapping.from), mapping.from != old.path,
                      let match = try? ProjectMedia.assess(project: input.project, undo: input.undo, redo: input.redo,
                                                           snapshot: input.snapshot, relativeTo: input.documentURL,
                                                           from: mapping.from, to: mapping.to),
                      match.outcome == .verified || match.outcome == .match else { return nil }
                return ProjectMediaSearchRow(path: mapping.from, outcome: match.outcome, candidates: [match])
            }
        }
        try Task.checkCancellation()
        guard revision() == checkedRevision else { throw staleLiveProjectMedia() }
        if !rows.isEmpty {
            if isVisible { prepareMatches(rows) }
            else { jobs.publishMatches(rows, at: checkedRevision) }
        }
    }

    private func prepareMatches(_ rows: [ProjectMediaSearchRow]) {
        searchRows = rows
        matchRevision = revision()
        candidateChoices = [:]
        included = []
        for row in rows where row.outcome == .verified || row.outcome == .match {
            if let candidate = row.candidates.first {
                candidateChoices[row.path] = candidate.url
                included.insert(row.path)
            }
        }
    }

    private var matches: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review \(searchRows.count) located \(searchRows.count == 1 ? "file" : "files")").font(.headline)
            List(searchRows, id: \.path) { row in
                let choice = row.candidates.first { $0.url == candidateChoices[row.path] }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(URL(fileURLWithPath: row.path).lastPathComponent, isOn: Binding {
                        included.contains(row.path)
                    } set: { include in
                        if include { included.insert(row.path) } else { included.remove(row.path) }
                    })
                    .disabled(choice?.outcome != .verified && choice?.outcome != .match)
                    .help(row.path)
                    if row.candidates.count > 1 {
                        Picker("Candidate", selection: Binding(get: { candidateChoices[row.path] }, set: { value in
                            candidateChoices[row.path] = value
                            included.remove(row.path)
                        })) {
                            Text("Choose a candidate").tag(nil as URL?)
                            ForEach(row.candidates, id: \.url) { Text($0.url.path).tag(Optional($0.url)) }
                        }
                    }
                    if let candidate = choice ?? row.candidates.first {
                        Text(candidate.url.path).font(.caption).textSelection(.enabled)
                        let duration = candidate.duration.map { " · \(timelineTime($0.seconds))" } ?? ""
                        Text("\(candidate.outcome.rawValue.capitalized)\(duration)").font(.caption)
                        if let clock = candidate.sourceClock {
                            Text("\(clock.kind.rawValue) at source start: \(clock.start.description)").font(.caption).monospacedDigit()
                        }
                        if let reason = candidate.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        if candidate.outcome == .different,
                           let original = inventory.first(where: { $0.path == row.path || $0.url.path == row.path }) {
                            Button("Replace Source File…") { openReplacement(original, url: candidate.url, useID: nil) }
                        }
                    }
                }
            }
            Button("Relink \(included.count) \(included.count == 1 ? "File" : "Files")") {
                let paths = searchRows.map(\.path).filter { included.contains($0) }
                runInBackground("Relinking project media…") {
                    guard matchRevision == revision() else { throw staleLiveProjectMedia() }
                    let mappings = paths.compactMap { path in
                        searchRows.first { $0.path == path }?.candidates.first {
                            $0.url == candidateChoices[path]
                        }.map { ProjectMediaMapping(from: path, candidate: $0) }
                    }
                    let result = try await relinkBatch(mappings)
                    if result.changed {
                        let applied = Set(result.applied)
                        if let url = mappings.first(where: { applied.contains($0.from) })?.to {
                            lastFolder = url.deletingLastPathComponent().path
                        }
                        searchRows.removeAll { applied.contains($0.path) }
                        included.subtract(applied)
                        matchRevision = revision()
                    }
                    await reload()
                    if !result.failures.isEmpty {
                        let details = result.failures.keys.sorted().map { path in
                            "\(path): \(result.failures[path] ?? "")"
                        }.joined(separator: "\n")
                        throw CutError(code: "media_relink_failed", message: details)
                    }
                }
            }
            .disabled(included.isEmpty || searching)
        }
        .disabled(working)
    }

    private func chooseReplacement(_ row: ProjectMediaRow, useID: String?) {
        chooseCandidate(directories: false, files: true, title: "Replace Source File") { url in
            openReplacement(row, url: url, useID: useID)
        }
    }

    private func openReplacement(_ row: ProjectMediaRow, url: URL, useID: String?) {
        let project = row.uses.contains { $0.kind == .still } ? archive()?.project : nil
        let asset = project?.stillAssets.first { $0.file == row.path }?.id
        let framing = project?.stillInserts.first(where: { $0.assetID == asset })?.framing ??
                      project?.stillReplacements.first(where: { $0.assetID == asset })?.framing
        let initial = Replacement(path: row.path, candidate: url, uses: row.uses, stillFraming: framing,
                                  options: MediaReplaceOptions(useID: useID))
        replacement = initial
        reviewReplacement(initial)
    }

    private func reviewReplacement(_ input: Replacement) {
        guard let archive = archive() else { return }
        run {
            let (result, spans) = try await mediaWork {
                let result = try ProjectMediaReplace.preview(archive.project, snapshot: archive.snapshot,
                                                             relativeTo: archive.documentURL, source: input.path,
                                                             candidate: input.candidate, options: input.options)
                return (result, mediaReplacementTimeline(archive.project))
            }
            try Task.checkCancellation()
            replacement?.preview = result
            replacement?.spans = spans
        }
    }

    private func replacementForm(_ draft: Replacement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.candidate.path).font(.caption).textSelection(.enabled)
            Picker("Scope", selection: choice(\.useID, default: draft.options.useID)) {
                Text("All uses").tag(nil as String?)
                ForEach(Array(draft.scopeUses.enumerated()), id: \.offset) { index, use in
                    Text(useLabel(use, index: index)).tag(Optional(use.id))
                }
            }
            HStack {
                Picker("Ranges past the end", selection: choice(\.conform, default: draft.options.conform)) {
                    Text("Trim to new end").tag(MediaReplaceConform.trim)
                    Text("Keep offline").tag(MediaReplaceConform.keep)
                }
                Picker("Uses beyond the end", selection: choice(\.loss, default: draft.options.loss)) {
                    Text("Choose when required").tag(nil as MediaReplaceLoss?)
                    Text("Remove").tag(Optional(MediaReplaceLoss.remove))
                    Text("Keep offline").tag(Optional(MediaReplaceLoss.keepOffline))
                }
            }
            if let report = draft.preview?.report {
                if report.canKeepTimecode {
                    Picker("Clock", selection: choice(\.clock, default: draft.options.clock)) {
                        Text("Keep source-relative times").tag(MediaReplaceClock.sourceRelative)
                        Text("Keep source timecode").tag(MediaReplaceClock.sourceTimecode)
                    }
                }
                if report.needsSharedTimeOfDay &&
                    (draft.options.clock == .sourceTimecode || draft.options.resync == .timecode) {
                    Toggle("Confirm a shared time-of-day clock", isOn: choice(\.sharedTimeOfDay, default: draft.options.sharedTimeOfDay))
                }
                if isMulticam {
                    Picker("Re-sync", selection: choice(\.resync, default: draft.options.resync)) {
                        Text("Keep current offset").tag(nil as MediaReplaceSync?)
                        Text("Timecode").tag(Optional(MediaReplaceSync.timecode))
                        Text("Waveform").tag(Optional(MediaReplaceSync.waveform))
                    }
                }
                if !report.affectedTranscriptIDs.isEmpty {
                    Picker("Transcript", selection: choice(\.transcript, default: draft.options.transcript)) {
                        Text("Keep (unverified)").tag(MediaReplaceTranscript.keepUnverified)
                        Text("Re-transcribe").tag(MediaReplaceTranscript.retranscribe)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        replacementAudioControls(draft, report: report)
                        if report.newStill != nil { stillComparison(draft) }
                        affectedUses(draft, report: report)
                        ForEach(Array(report.blockers.enumerated()), id: \.offset) { _, blocker in
                            Label(blocker, systemImage: "xmark.octagon").foregroundStyle(.red)
                        }
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if !report.participantIDs.isEmpty || !report.affectedRedactionIDs.isEmpty ||
                            !report.affectedParticipantBindingIDs.isEmpty || !report.affectedParticipantSlotIDs.isEmpty {
                            DisclosureGroup("Affected participant decisions") {
                                let affected = [
                                    ("Participants", report.participantIDs),
                                    ("Redactions", report.affectedRedactionIDs),
                                    ("Audio bindings", report.affectedParticipantBindingIDs),
                                    ("Camera slots", report.affectedParticipantSlotIDs),
                                    ("Appearance overrides", report.removedAppearanceIDs),
                                ].filter { !$0.1.isEmpty }
                                ForEach(Array(affected.enumerated()), id: \.offset) { _, decisions in
                                    Text("\(decisions.0): \(decisions.1.joined(separator: ", "))").font(.caption)
                                }
                            }
                        }
                        if !report.lostUseIDs.isEmpty {
                            Text("Uses beyond the new end: \(report.lostUseIDs.joined(separator: ", "))").font(.caption)
                        }
                        if report.beforeDuration != report.afterDuration {
                            Text("Timeline duration: \(timelineTime(report.beforeDuration.seconds)) → \(timelineTime(report.afterDuration.seconds))").monospacedDigit()
                        }
                        ForEach(report.offsets, id: \.useID) { offset in
                            Text("\(offset.useID) offset: \(offset.before.description) → \(offset.after.description) s").font(.caption)
                        }
                        ForEach(Array(report.boundaries.filter { !$0.frameAligned || !$0.copySafe }.enumerated()), id: \.offset) { _, edge in
                            Text("\(edge.useID) · \(edge.at.description) s · \(edge.frameAligned ? "Requires re-encode" : "Off frame grid")").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
            }
            HStack {
                if draft.preview?.report.newStill != nil {
                    Toggle("Reset crop", isOn: choice(\.resetCrop, default: draft.options.resetCrop))
                }
                Spacer()
                Button("Apply Replacement") {
                    guard let preview = draft.preview else { return }
                    runInBackground("Indexing replacement media…") {
                        let previous = draft.options.transcript == .retranscribe ? archive()?.project.transcripts : nil
                        if try await replace(preview) {
                            lastFolder = draft.candidate.deletingLastPathComponent().path
                            replacement = nil
                            searchRows = []
                            if let previous, let current = archive(), !preview.report.affectedTranscriptIDs.isEmpty {
                                let targets = replacementTranscriptTargets(previous: previous, current: current,
                                                                           affected: Set(preview.report.affectedTranscriptIDs))
                                if !targets.isEmpty {
                                    jobs.queueTranscription(targets)
                                    if isVisible { dismiss() }
                                }
                            }
                            await reload()
                        }
                    }
                }
                .disabled(draft.preview?.report.canApply != true)
            }
        }
        .disabled(working)
    }

    private func replacementAudioControls(_ draft: Replacement, report: MediaReplaceReport) -> some View {
        ForEach(Set(report.audioMapping.keys).union(report.unresolvedAudioStreams).sorted(), id: \.self) { old in
            Picker("Audio stream \(old)", selection: Binding<Int?> {
                draft.options.streamMapping[old] ?? report.audioMapping[old]
            } set: { newStream in
                var mapping = draft.options.streamMapping
                mapping[old] = newStream
                choice(\.streamMapping, default: draft.options.streamMapping).wrappedValue = mapping
            }) {
                Text("Choose a stream").tag(nil as Int?)
                ForEach(report.candidateAudioStreams, id: \.index) { stream in
                    let title = stream.name.map { "\($0) · " } ?? ""
                    Text("\(stream.index) · \(title)\(stream.layout) · \(stream.channels) ch \(stream.language)").tag(Optional(stream.index))
                }
            }
        }
    }

    private func stillComparison(_ draft: Replacement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if draft.preview?.report.oldStill != nil, let row = inventory.first(where: { $0.path == draft.path }) {
                ProjectMediaImage(url: row.url, title: "Previous framing", crop: draft.stillFraming?.crop)
            }
            ProjectMediaImage(url: draft.candidate, title: "Replacement framing",
                              crop: draft.options.resetCrop ? nil : draft.stillFraming?.crop)
        }
    }

    private func choice<Value>(_ key: WritableKeyPath<MediaReplaceOptions, Value>, default value: Value) -> Binding<Value> {
        Binding(get: { replacement?.options[keyPath: key] ?? value }, set: { newValue in
            guard var edited = replacement else { return }
            edited.options[keyPath: key] = newValue
            edited.preview = nil
            replacement = edited
            reviewReplacement(edited)
        })
    }

    private func affectedUses(_ draft: Replacement, report: MediaReplaceReport) -> some View {
        let affected = Set(report.affectedUseIDs)
        let lost = Set(report.lostUseIDs)
        let end = draft.spans.last?.end ?? 0
        return GeometryReader { proxy in
            ForEach(Array(draft.spans.enumerated()), id: \.offset) { _, span in
                let factor = proxy.size.width / max(end, 0.001)
                let color: Color = span.ids.isDisjoint(with: affected)
                    ? .secondary.opacity(0.27) : (span.ids.isDisjoint(with: lost) ? .orange : .red)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(1, (span.end - span.start) * factor - 1), height: 12)
                    .offset(x: span.start * factor)
            }
        }
        .frame(height: draft.spans.isEmpty ? 0 : 12)
        .accessibilityLabel("\(affected.count) affected media uses on the timeline")
    }

}

private func mediaKindIcon(_ row: ProjectMediaRow) -> String {
    if row.uses.contains(where: { $0.kind == .still }) { return "photo" }
    if row.uses.contains(where: { $0.kind == .camera || $0.kind == .stillFragment }) { return "film" }
    if row.uses.contains(where: { $0.kind == .microphone || $0.kind == .stillAudioReference || $0.kind == .stillSoundtrack }) { return "waveform" }
    return "film"
}

private func locateTitle(_ row: ProjectMediaRow) -> String {
    row.uses.contains(where: { $0.kind == .clip && $0.ordinal != nil && $0.range == nil })
        ? "Locate Working Copy…" : "Locate…"
}

private func useLabel(_ use: ProjectMediaUse, index: Int) -> String {
    let timing = use.range.map { " · \(timelineTime($0.from.seconds, milliseconds: true))–\(timelineTime($0.to.seconds, milliseconds: true))" } ?? ""
    return "\(use.kind.editorLabel.capitalized) \(index + 1)\(timing)"
}

private func useSummary(_ uses: [ProjectMediaUse]) -> String {
    Dictionary(grouping: uses, by: \.kind).map { kind, values in
        let count = Set(values.map(\.id)).count
        return "\(count) \(kind.editorLabel)\(count == 1 ? "" : "s")"
    }
    .sorted().joined(separator: ", ")
}

private extension ProjectMediaUse.Kind {
    var editorLabel: String {
        switch self {
        case .clip: "clip"
        case .original: "working copy original"
        case .still: "still"
        case .stillAudioReference: "inherited audio layout"
        case .stillSoundtrack: "soundtrack"
        case .stillFragment: "still replacement"
        case .select: "source select"
        case .camera: "camera recording"
        case .microphone: "audio recording"
        case .multicamSpan: "multicam span"
        case .multicamSelection: "audio selection"
        case .transcript: "transcript"
        case .transcriptAnchor: "transcript anchor"
        case .participant: "participant use"
        case .participantAudio: "participant audio selection"
        }
    }
}

private struct ProjectMediaImage: View {
    let url: URL
    let title: String
    let crop: StillImageFraming.Crop?
    @State private var thumbnail: CGImage?

    private struct Identity: Equatable {
        let url: URL
        let crop: StillImageFraming.Crop?
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "photo"))
            }
        }
        .frame(width: 160, height: 94)
        .task(id: Identity(url: url, crop: crop)) {
            thumbnail = await Task.detached(priority: .utility) {
                createProjectMediaThumbnail(url, crop: crop)
            }.value
        }
    }
}

private func createProjectMediaThumbnail(_ url: URL, crop: StillImageFraming.Crop?) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 320
          ] as CFDictionary) else { return nil }
    guard let crop else { return image }
    let width = Double(image.width)
    let height = Double(image.height)
    let frame = CGRect(x: width * crop.x.seconds, y: height * crop.y.seconds,
                       width: width * crop.width.seconds, height: height * crop.height.seconds)
    return image.cropping(to: frame.integral)
}

private func mediaWork<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    let work = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler {
        try await work.value
    } onCancel: {
        work.cancel()
    }
}

func projectMediaPrefixRoots(from old: URL, to new: URL) -> (URL, URL) {
    var oldRoot = old.deletingLastPathComponent()
    var newRoot = new.deletingLastPathComponent()
    if old.lastPathComponent.localizedCaseInsensitiveCompare(new.lastPathComponent) == .orderedSame {
        while oldRoot.lastPathComponent.localizedCaseInsensitiveCompare(newRoot.lastPathComponent) == .orderedSame,
              oldRoot.pathComponents.count > 2, newRoot.pathComponents.count > 2 {
            oldRoot.deleteLastPathComponent()
            newRoot.deleteLastPathComponent()
        }
    }
    return (oldRoot, newRoot)
}


private struct ProjectMediaWindowReader: NSViewRepresentable {
    let attached: (NSWindow?) -> Void

    func makeNSView(context: Context) -> AttachmentView {
        AttachmentView(attached: attached)
    }

    func updateNSView(_ view: AttachmentView, context: Context) {}

    final class AttachmentView: NSView {
        let attached: (NSWindow?) -> Void

        init(attached: @escaping (NSWindow?) -> Void) {
            self.attached = attached
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attached(self.window)
            }
        }
    }
}


private func projectMediaNavigableUse(_ use: ProjectMediaUse) -> Bool {
    switch use.kind {
    case .clip, .original, .still, .stillFragment, .camera, .microphone, .multicamSpan:
        true
    default:
        false
    }
}


func replacementTranscriptTargets(previous: ProjectTranscripts, current: LiveProjectMediaArchive,
                                  affected: Set<String>) -> Set<TranscriptSetupTarget> {
    let before = Dictionary(uniqueKeysWithValues: previous.attachments.filter { affected.contains($0.id) }.map {
        ($0.id, Set($0.bindings))
    })
    let state = current.project.transcripts
    var bindings = state.attachments.filter { affected.contains($0.id) }.flatMap { attachment in
        attachment.bindings.filter { before[attachment.id]?.contains($0) != true }
    }
    let priorAnchors = Set(previous.authoring.filter { affected.contains($0.attachmentID) }.flatMap { record in
        record.anchors.map(\.binding) + [record.speakerReference?.binding].compactMap { $0 }
    })
    bindings += state.authoring.filter { affected.contains($0.attachmentID) }.flatMap { record in
        (record.anchors.map(\.binding) + [record.speakerReference?.binding].compactMap { $0 })
            .filter { !priorAnchors.contains($0) }
    }
    let sources: [String: String]
    if case .multicam(let project) = current.project {
        sources = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0.file) })
    } else {
        sources = [:]
    }
    return Set(bindings.compactMap { binding in
        guard let path = binding.file ?? binding.sourceID.flatMap({ sources[$0] }) else { return nil }
        let url = ProjectMediaVolume.watchURL(path, relativeTo: current.documentURL)
        return .init(file: url, sourceID: binding.sourceID, stream: binding.streamIndex, channel: binding.channel)
    })
}


private struct MediaReplacementDisplaySpan: Sendable {
    let start: Double
    let end: Double
    let ids: Set<String>
}

private func mediaReplacementTimeline(_ project: CutProject) -> [MediaReplacementDisplaySpan] {
    if case .multicam(let multicam) = project {
        return ((try? multicam.plan())?.intervals ?? []).map { interval in
            let ids = Set([interval.pictureSourceID, interval.audio?.source].compactMap { $0 })
            return .init(start: interval.output.from.seconds, end: interval.output.to.seconds, ids: ids)
        }
    }
    var position = 0.0
    return (project.sequenceItems ?? []).map { item in
        let start = position
        let ids: Set<String>
        switch item {
        case .source(let clip):
            position += clip.to.seconds - clip.from.seconds
            ids = [clip.id]
        case .still(let still):
            position += still.duration.seconds
            ids = [still.id, still.assetID]
        }
        return .init(start: start, end: position, ids: ids)
    }
}
