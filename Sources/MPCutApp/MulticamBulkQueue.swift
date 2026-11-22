import AppKit
import MPCutCore
import SwiftUI

struct MulticamQueuedRange: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let range: MulticamRange
    let project: MulticamProject
    let media: [String: MediaInfo]
}

struct MulticamBulkExport: Sendable {
    struct Item: Sendable {
        let output: URL
        let plan: MulticamExportPlan
    }

    let items: [Item]
    private let directory: URL
    private let organization: ExportOrganization
    private let engine: MulticamEngine

    func write(_ item: Item, progress: @escaping @Sendable (Double) -> Void) throws {
        _ = try organization.directory(in: directory, create: true)
        try engine.write(item.plan, to: item.output, progress: progress)
    }

    init(ranges: [MulticamQueuedRange], directory: URL, container: String,
         mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings,
         organization: ExportOrganization = .init(), engine: MulticamEngine) throws {
        self.directory = directory
        self.organization = organization
        self.engine = engine
        let folder = try organization.directory(in: directory, create: false)
        let planner = engine.planning(in: organization.subfolder.isEmpty ? nil : folder)
        items = try ranges.enumerated().map { index, entry in
            let suffix = String(format: "%03ld", index + 1)
            let filename = organization.filename(stem: entry.name, suffix: suffix, container: container)
            let output = folder.appendingPathComponent(filename, isDirectory: false)
            do {
                // Each range resolves through the export rules, which report the alternatives that work.
                let plan = try planner.resolution(entry.project, output: output, mode: mode, tracks: tracks,
                                                 assembly: [entry.range], settings: settings,
                                                 indexedSources: entry.media).get()
                return Item(output: output, plan: plan)
            } catch let issue as CutError {
                var failure = CutError(code: issue.code, message: "Range \(index + 1): \(issue.message)", segment: index + 1,
                                       boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
                failure.alternatives = issue.alternatives
                throw failure
            }
        }
    }
}

extension MulticamBulkExport {
    /// Plans every range as the export will, in a scratch directory. Nil when all of them can be written.
    static func check(_ ranges: [MulticamQueuedRange], choices: MulticamExportChoices, organization: ExportOrganization = .init(),
                      cancelled: @escaping @Sendable () -> Bool = { false }) -> CutError? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-queue-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: scratch) }
            _ = try MulticamBulkExport(ranges: ranges, directory: scratch, container: choices.container, mode: choices.effectiveMode,
                                       tracks: choices.tracks, settings: choices.settings, organization: organization, engine: MulticamEngine(cancelled: cancelled))
            return nil
        } catch let issue as CutError {
            return issue
        } catch {
            return CutError(code: "export_failed", message: error.localizedDescription)
        }
    }
}

extension MulticamEditorModel {
    private var markedExportRange: MulticamRange? {
        guard let project, let marks = markedGroupSpan,
              marks.from >= project.range.from, marks.to <= project.range.to else { return nil }
        return MulticamRange(from: marks.from, to: marks.to)
    }

    var canEnqueueMarkedRange: Bool { !isBusy && markedExportRange != nil }
    var canShowBulkQueue: Bool { !isBusy && project != nil }

    func enqueueMarkedRange() {
        guard let range = markedExportRange, enqueueRanges([range]) else { return }
        markIn = nil
        markOut = nil
    }

    @discardableResult
    func enqueueRanges(_ ranges: [MulticamRange]) -> Bool {
        guard !isBusy, let project, !ranges.isEmpty else { return false }
        do {
            let name = projectName ?? "Multicam"
            _ = try project.plan(ranges: ranges)
            let entries = ranges.map { range in
                MulticamQueuedRange(name: name, range: range, project: project, media: media)
            }
            queuedRanges.append(contentsOf: entries)
            status = "Added \(entries.count) \(entries.count == 1 ? "range" : "ranges") to the export queue."
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func removeQueuedRange(_ id: UUID) {
        guard !isExporting else { return }
        queuedRanges.removeAll { $0.id == id }
        reconcileSourceLoads()
    }

    func showBulkQueue() {
        guard canShowBulkQueue else { return }
        preview.pause()
        isBulkQueuePresented = true
    }

    func resetExportQueue() {
        queuedRanges.removeAll()
        isBulkQueuePresented = false
        isReplacementAudioPresented = false
        bulkExportDirectory = nil
    }

    /// Plans every queued range with these settings, without writing: nil, or the failure with the alternatives
    /// of the export rules.
    func checkQueuedRanges(_ choices: MulticamExportChoices, organization: ExportOrganization = .init()) async -> CutError? {
        let ranges = queuedRanges
        let useSidecar = useAnalysisSidecars
        return await Task.detached(priority: .userInitiated) {
            AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                MulticamBulkExport.check(ranges, choices: choices, organization: organization)
            }
        }.value
    }

    func chooseBulkDestination(container: String, mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings, organization: ExportOrganization = .init()) {
        guard isBulkQueuePresented, !queuedRanges.isEmpty, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Queued Ranges"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = bulkExportDirectory
        ProjectPanels.present(panel, in: window, fromSheet: true) { [weak self] accepted in
            guard let self, self.isBulkQueuePresented, accepted, let directory = panel.url else { return }
            self.exportQueuedRanges(to: directory, container: container, mode: mode, tracks: tracks, settings: settings, organization: organization)
        }
    }

    func exportQueuedRanges(to directory: URL, container: String, mode: ExportMode,
                            tracks: ExportTracks, settings: ReencodeSettings = .init(), organization: ExportOrganization = .init()) {
        guard !queuedRanges.isEmpty, !isBusy else { return }
        bulkExportDirectory = directory
        isBulkQueuePresented = false
        let ranges = queuedRanges
        let protected = protectedMediaPaths
        run("Exporting queued multicam ranges…", exporting: true) { [weak self] token, useSidecar in
            try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                let engine = MulticamEngine(cancelled: { token.isCancelled })
                try organization.validateSubfolder(in: directory, protectedMedia: protected)
                let batch = try MulticamBulkExport(ranges: ranges, directory: directory, container: container,
                                                  mode: mode, tracks: tracks, settings: settings, organization: organization, engine: engine)
                for item in batch.items {
                    try CutProject.validateMediaDestination(item.output, absoluteSources: protected)
                }
                for (index, item) in batch.items.enumerated() {
                    do {
                        try batch.write(item) { [weak self] fraction in
                            let progress = (Double(index) + fraction) / Double(batch.items.count)
                            Task { @MainActor [weak self] in self?.updateExportProgress(token, fraction: progress) }
                        }
                    } catch {
                        throw CutError(code: "bulk_interrupted", message: "Wrote \(index) of \(ranges.count) files. "
                                       + "Range \(index + 1): \(error.localizedDescription)")
                    }
                }
                return batch.items.count
            }
        } onSuccess: { count in
            let folder = organization.subfolder.isEmpty ? directory.lastPathComponent : organization.subfolder
            self.status = "Exported \(count) \(count == 1 ? "file" : "files") to \(folder)."
        }
    }
}

struct MulticamBulkQueueView: View {
    @ObservedObject var model: MulticamEditorModel
    /// The settings on offer. Their lists, defaults and names come from the export rules.
    @State private var organization = ExportOrganization()
    @State private var choices: MulticamExportChoices
    /// The failure of the last check, with the alternatives the export rules report for it.
    @State private var issue: CutError?
    @State private var isChecking = false

    init(model: MulticamEditorModel) {
        self.model = model
        _choices = State(initialValue: MulticamExportChoices(entry: .multicamQueue, preferred: model.preferences.defaultExportMode))
    }

    private func export() {
        let requested = choices
        let layout = organization
        let ranges = model.queuedRanges.map(\.id)
        isChecking = true
        Task {
            // Plan every range first, so that one that cannot be written shows the offers of the export rules.
            let failure = await model.checkQueuedRanges(requested, organization: layout)
            guard isChecking else { return }
            isChecking = false
            guard requested == choices, layout == organization, ranges == model.queuedRanges.map(\.id) else { return }
            issue = failure
            if failure == nil {
                model.chooseBulkDestination(container: requested.container, mode: requested.effectiveMode, tracks: requested.tracks,
                                            settings: requested.settings, organization: layout)
            }
        }
    }

    var body: some View {
        EditorSheet(title: "Export Queue", message: queueSummary(model.queuedRanges.map { ($0.range.from, $0.range.to) })) {
            if model.queuedRanges.isEmpty {
                ExportQueueEmptyState()
            } else {
                ExportQueueList(count: model.queuedRanges.count) {
                    ForEach(Array(model.queuedRanges.enumerated()), id: \.element.id) { index, entry in
                        ExportQueueRangeRow(index: index, title: entry.name, start: entry.range.from, end: entry.range.to) {
                            model.removeQueuedRange(entry.id)
                        }
                    }
                }
                options
                ExportOrganizationFields(organization: $organization, stem: model.queuedRanges.first?.name ?? "Multicam", container: choices.container)
                if let issue {
                    ExportOffersView(message: ExportRules.describe(issue, clips: []), alternatives: issue.alternatives ?? []) {
                        choices.apply($0)
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Close") { model.isBulkQueuePresented = false }.keyboardShortcut(.cancelAction)
            Button(model.queuedRanges.count == 1 ? "Export File…" : "Export \(model.queuedRanges.count) Files…", action: export)
                .keyboardShortcut(.defaultAction).disabled(model.queuedRanges.isEmpty || isChecking)
        }
        .onChange(of: organization) { _, _ in issue = nil }
        .onChange(of: choices) { _, _ in
            issue = nil
            choices.settle()
        }
        .onChange(of: model.queuedRanges.map(\.id)) { _, _ in issue = nil }
        .onDisappear { isChecking = false }
        .frame(width: 500)
    }

    private var options: some View {
        Form {
            Picker("Tracks", selection: $choices.tracks) {
                ForEach(ExportTracks.allCases, id: \.self) { Text(MulticamExportChoices.title(of: $0)).tag($0) }
            }
            // Exactly the modes the export rules write as themselves for this selection.
            Picker("Mode", selection: Binding(get: { choices.effectiveMode }, set: { choices.mode = $0 })) {
                ForEach(choices.modes, id: \.self) { Text(choices.title(of: $0)) }
            }
            .disabled(choices.modes.count < 2)
            Picker("Container", selection: $choices.container) {
                ForEach(choices.containers(), id: \.self) { Text(containerDisplayName($0)).tag($0) }
            }
            if choices.effectiveMode == .encode {
                Picker("Video", selection: $choices.codec) {
                    ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName) }
                }
                Picker("Quality", selection: choices.codec == .prores ? $choices.proResQuality : $choices.standardQuality) {
                    ForEach(choices.qualities, id: \.self) { Text($0.displayName) }
                }
                // Every audio action of the cell. One the container cannot carry is refused with its alternatives.
                Picker("Audio", selection: $choices.audio) {
                    ForEach(choices.audioActions, id: \.self) { Text($0.displayName) }
                }
            }
        }
    }
}
