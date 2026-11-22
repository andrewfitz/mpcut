import AppKit
import MPCutCore
import SwiftUI

struct MulticamQueuedRange: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let range: MulticamRange
    let project: MulticamProject
    let media: [String: MediaInfo]
    var usesAssembly = false

    var snapshot: MulticamProject {
        var value = project
        if !usesAssembly { value.assemblyItems = [.group(range)] }
        return value
    }

    var placements: ExportPlacementScope {
        (try? CutProject.multicam(snapshot).exportPlacementScope()) ?? .none
    }
}

struct MulticamBulkExport: Sendable {
    struct Item: Sendable {
        let output: URL
        enum Payload: Sendable {
            case multicam(MulticamExportPlan)
            case still(StillExportPlan)
        }

        let payload: Payload

        var duration: RationalTime {
            switch payload {
            case .multicam(let plan): plan.duration
            case .still(let plan): plan.duration
            }
        }

        var stillReport: StillExportReport? {
            if case .still(let plan) = payload { return plan.report }
            return nil
        }
    }

    let items: [Item]
    private let directory: URL
    private let organization: ExportOrganization
    private let engine: MulticamEngine
    private let stillPlanner: StillExportPlanner
    private let cancelled: @Sendable () -> Bool

    func write(_ item: Item, progress: @escaping @Sendable (Double) -> Void) throws {
        _ = try organization.directory(in: directory, create: true)
        switch item.payload {
        case .multicam(let plan): try engine.write(plan, to: item.output, progress: progress)
        case .still(let plan):
            try stillPlanner.write(plan, to: item.output) { fraction in
                progress(fraction)
                return !cancelled()
            }
        }
    }

    init(ranges: [MulticamQueuedRange], directory: URL, container: String,
         mode: ExportMode? = nil, tracks: ExportTracks, settings: ReencodeSettings,
         organization: ExportOrganization = .init(), engine: MulticamEngine,
         requireCameraCopy: Bool = false, cancelled: @escaping @Sendable () -> Bool = { false }) throws {
        self.directory = directory
        self.organization = organization
        self.engine = engine
        self.cancelled = cancelled
        let stillPlanner = StillExportPlanner(useSidecar: AnalysisSidecar.readsEnabled, cancelled: cancelled)
        self.stillPlanner = stillPlanner
        let folder = try organization.directory(in: directory, create: false)
        let planner = engine.planning(in: organization.subfolder.isEmpty ? nil : folder)
        let hasStills = ranges.contains { $0.placements != .none }
        let typedSettings = hasStills && (
            (tracks != .all && (mode == .encode || (tracks == .video && mode == .smart))) ||
            (tracks == .all && mode == .smart && [.aac, .pcm, .removeAudio].contains(settings.audio))
        )
        items = try ranges.enumerated().map { index, entry in
            let suffix = String(format: "%03ld", index + 1)
            let filename = organization.filename(stem: entry.name, suffix: suffix, container: container)
            let output = folder.appendingPathComponent(filename, isDirectory: false)
            do {
                if cancelled() { throw CutError(code: "cancelled", message: "Operation cancelled.") }
                let snapshot = entry.snapshot
                let document = CutProject.multicam(snapshot)
                if try document.exportPlacementScope() != .none || typedSettings {
                    for source in entry.media.values where !source.identity.isCurrentSnapshot(at: source.url) {
                        throw CutError(code: "source_changed", message: "\(source.url.lastPathComponent) changed after the range was queued.")
                    }
                    try CutEngine(cancelled: cancelled).checkDestination(output,
                                                                         plannedSubfolder: organization.subfolder.isEmpty ? nil : folder)
                    let plan = try stillPlanner.resolve(document, tracks: tracks, mode: mode,
                                                        requireCameraCopy: requireCameraCopy, container: container,
                                                        settings: settings)
                    return Item(output: output, payload: .still(plan))
                }
                let standardMode = mode ?? ExportRules.defaultMode(for: .multicam, tracks: tracks)
                let plan = try planner.resolution(snapshot, output: output, mode: standardMode, tracks: tracks,
                                                  settings: settings, indexedSources: entry.media).get()
                if requireCameraCopy && tracks != .audio && plan.encodedVideoDuration > .zero {
                    throw CutError(code: "camera_copy_required", message: "This range needs camera video encoding.")
                }
                return Item(output: output, payload: .multicam(plan))
            } catch let issue as CutError {
                // `multicam.edge.range` numbers the entry's own ranges, so it is 1 here. `segment` numbers the entry.
                var failure = CutError(code: issue.code, message: "Range \(index + 1): \(issue.message)", segment: index + 1,
                                       boundary: issue.boundary, nearest: issue.nearest, track: issue.track, multicam: entry.usesAssembly ? nil : issue.multicam)
                failure.alternatives = issue.alternatives
                failure.reason = issue.factor
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
                                       tracks: choices.tracks, settings: choices.settings, organization: organization,
                                       engine: MulticamEngine(cancelled: cancelled), requireCameraCopy: choices.requireCameraCopy,
                                       cancelled: cancelled)
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

    var canEnqueueMarkedRange: Bool { !isBusy && (assemblySelection != nil || markedExportRange != nil) }
    var canShowBulkQueue: Bool { !isBusy && project != nil }

    func enqueueMarkedRange() {
        guard canEnqueueMarkedRange, let project else { return }
        if let selected = assemblySelection {
            do {
                let range = MulticamSilencePlanner.range(selected)
                let snapshot = try project.assemblySelection(range)
                queuedRanges.append(MulticamQueuedRange(name: projectName ?? "Multicam", range: range,
                                                        project: snapshot, media: media, usesAssembly: true))
                assemblySelection = nil
                status = "Added 1 range to the export queue."
            } catch {
                fail(error.localizedDescription)
                return
            }
        } else {
            guard let range = markedExportRange, enqueueRanges([range]) else { return }
        }
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

    func enqueuePauseTakes(_ retained: [(occurrence: Int, span: AudioSpan)]) -> Bool {
        guard !isBusy, let project else { return false }
        let name = projectName ?? "Multicam"
        let groups = Dictionary(grouping: retained, by: \.occurrence)
        do {
            var entries: [MulticamQueuedRange] = []
            for (index, item) in assemblyItems.enumerated() {
                if let still = item.still, markedGroupSpan == nil {
                    let start = assemblyStart(at: index)
                    let end = try start.adding(still.duration)
                    let original = AudioSpan(from: start, to: end)
                    guard let selected = MulticamSilencePlanner.intersection(original, assemblySelection ?? original) else { continue }
                    let range = MulticamSilencePlanner.range(selected)
                    let snapshot = try project.assemblySelection(range)
                    entries.append(.init(name: name, range: range, project: snapshot, media: media, usesAssembly: true))
                }
                for take in groups[index] ?? [] {
                    let range = MulticamSilencePlanner.range(take.span)
                    entries.append(.init(name: name, range: range, project: project, media: media))
                }
            }
            guard !entries.isEmpty else {
                notice = Notice(title: "No media to keep", message: "Increase the time left in each pause or keep a pause.")
                return false
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
        if let issue = queuedMediaRefreshIssue() { return issue }
        let ranges = queuedRanges
        let useSidecar = useAnalysisSidecars
        return await Task.detached(priority: .userInitiated) {
            AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                MulticamBulkExport.check(ranges, choices: choices, organization: organization)
            }
        }.value
    }

    func chooseBulkDestination(container: String, mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings, organization: ExportOrganization = .init(), requireCameraCopy: Bool = false) {
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
            self.exportQueuedRanges(to: directory, container: container, mode: mode, tracks: tracks, settings: settings, organization: organization, requireCameraCopy: requireCameraCopy)
        }
    }

    func exportQueuedRanges(to directory: URL, container: String, mode: ExportMode,
                            tracks: ExportTracks, settings: ReencodeSettings = .init(), organization: ExportOrganization = .init(), requireCameraCopy: Bool = false) {
        guard !queuedRanges.isEmpty, !isBusy else { return }
        if let issue = queuedMediaRefreshIssue() { fail(issue.message); return }
        bulkExportDirectory = directory
        isBulkQueuePresented = false
        let ranges = queuedRanges
        let protected = protectedMediaPaths
        run("Exporting queued multicam ranges…", exporting: true) { [weak self] token, useSidecar in
            try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                let engine = MulticamEngine(cancelled: { token.isCancelled })
                try organization.validateSubfolder(in: directory, protectedMedia: protected)
                let batch: MulticamBulkExport
                do {
                    batch = try MulticamBulkExport(ranges: ranges, directory: directory, container: container,
                                                   mode: mode, tracks: tracks, settings: settings, organization: organization, engine: engine,
                                                   requireCameraCopy: requireCameraCopy, cancelled: { token.isCancelled })
                } catch let issue as CutError {
                    // The times of a queued entry belong to its snapshot. The editor's switch suggestions are for the
                    // open project, so this failure is reported without the switch or edge it names.
                    var plain = CutError(code: issue.code, message: issue.message, segment: issue.segment, boundary: issue.boundary,
                                         nearest: issue.nearest, track: issue.track)
                    plain.alternatives = issue.alternatives
                    plain.reason = issue.factor
                    throw plain
                }
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
        var options = MulticamExportChoices(entry: .multicamQueue, preferred: model.preferences.defaultExportMode)
        let placements = model.queuedRanges.map(\.placements)
        options.placements = placements.contains(.insertion) ? .insertion : placements.contains(.replacement) ? .replacement : .none
        options.mode = ExportRules.defaultStillMode(tracks: options.tracks, placements: options.placements, otherwise: options.mode)
        options.settle()
        _choices = State(initialValue: options)
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
                                            settings: requested.settings, organization: layout, requireCameraCopy: requested.requireCameraCopy)
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
                    // An unsafe edge of a queued range offers its verified times. Applying one moves that entry's edge.
                    if let edge = issue.multicam?.edge, let times = issue.nearest, !times.isEmpty, let number = issue.segment {
                        MulticamEdgeSuggestionsView(suggestion: MulticamEdgeSuggestion(edge: MulticamEdge(range: number, boundary: edge.boundary, at: edge.at),
                                                                                         times: times), preview: nil) {
                            model.applyQueuedEdgeSuggestion($0, for: issue)
                        }
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Close") { model.isBulkQueuePresented = false }.keyboardShortcut(.cancelAction)
                .help("Close export queue")
            Button(model.queuedRanges.count == 1 ? "Export File…" : "Export \(model.queuedRanges.count) Files…", action: export)
                .keyboardShortcut(.defaultAction).disabled(model.queuedRanges.isEmpty || isChecking)
                .help("Export queued ranges")
        }
        .onChange(of: organization) { _, _ in issue = nil }
        .onChange(of: choices) { _, _ in
            issue = nil
            if choices.tracks == .audio && choices.placements == .insertion && choices.effectiveMode == .encode,
               !ExportRules.stillSoundConversions.contains(choices.audio) {
                choices.audio = .pcm
            }
            choices.settle()
        }
        .onChange(of: model.queuedRanges.map(\.id)) { _, _ in
            issue = nil
            let placements = model.queuedRanges.map(\.placements)
            choices.placements = placements.contains(.insertion) ? .insertion : placements.contains(.replacement) ? .replacement : .none
            choices.settle()
        }
        .onDisappear { isChecking = false }
        .frame(width: 500)
    }

    private var options: some View {
        Form {
            Picker("Tracks", selection: $choices.tracks) {
                ForEach(ExportTracks.allCases, id: \.self) { Text(MulticamExportChoices.title(of: $0, placements: choices.placements)).tag($0) }
            }
            .help("Choose output tracks")
            // Exactly the modes the export rules write as themselves for this selection.
            Picker("Mode", selection: Binding(get: { choices.effectiveMode }, set: { choices.mode = $0 })) {
                ForEach(choices.modes, id: \.self) { Text(choices.title(of: $0)) }
            }
            .disabled(choices.modes.count < 2)
            .help("Choose export mode")
            Picker("Container", selection: $choices.container) {
                ForEach(choices.containers(), id: \.self) { Text(containerDisplayName($0)).tag($0) }
            }
            .help("Choose file format")
            if choices.placements != .none && choices.tracks != .audio {
                Toggle("Preserve Camera Samples", isOn: $choices.requireCameraCopy)
                    .help("Copy camera footage")
            }
            if choices.effectiveMode == .encode && choices.tracks != .audio {
                Picker("Video", selection: $choices.codec) {
                    ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName) }
                }
                .help("Choose video codec")
                Picker("Quality", selection: choices.codec == .prores ? $choices.proResQuality : $choices.standardQuality) {
                    ForEach(choices.qualities, id: \.self) { Text($0.displayName) }
                }
                .help("Set video quality")
                // Every audio action of the cell. One the container cannot carry is refused with its alternatives.
                Picker("Audio", selection: $choices.audio) {
                    ForEach(choices.audioActions, id: \.self) { Text($0.displayName) }
                }
                .help("Choose audio encoding")
            }
        }
    }
}
