import AppKit
import MPCutCore
import SwiftUI

struct MulticamQueuedRange: Identifiable, Sendable {
    var id = UUID()
    var contentID = UUID()
    var name: String
    var range: MulticamRange
    let project: MulticamProject
    let media: [String: MediaInfo]
    var document: URL? = nil
    var usesAssembly = false
    var excerpt: TranscriptQueueExcerpt? = nil

    var snapshot: MulticamProject {
        var value = project
        if !usesAssembly { value.assemblyItems = [.group(range)] }
        return value
    }

    var placements: ExportPlacementScope {
        let project = snapshot
        let authored = (try? CutProject.multicam(project).exportPlacementScope()) ?? .none
        guard authored == .none, project.angles.contains(where: { $0.coverage != nil }),
              (try? project.plan().recordingGaps.isEmpty) == false else { return authored }
        return .replacement
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

        var audioDeliverySummary: String {
            switch payload {
            case .multicam(let plan): ([plan.audioDeliverySummary] + plan.warnings).joined(separator: "\n")
            case .still(let plan): plan.inspectorSummary
            }
        }

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
         requireCameraCopy: Bool = false, cancelled: @escaping @Sendable () -> Bool = { false },
         audioOutput: MulticamAudioOutput = .separateTracks, audioAction: ReencodeAudio? = nil,
         pictureTiming: StillPictureTiming? = nil, videoCodec: ReencodeCodec? = nil) throws {
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
            (audioAction == nil && tracks == .all && mode == .smart && [.aac, .pcm, .removeAudio].contains(settings.audio))
        )
        items = try ranges.enumerated().map { index, entry in
            let suffix = String(format: "%03ld", index + 1)
            do {
                if cancelled() { throw CutError(code: "cancelled", message: "Operation cancelled.") }
                let output = try organization.destination(in: folder, stem: entry.name, suffix: suffix, container: container)
                let usesTiles = CutProject.multicam(entry.project).requiresPictureProcessing
                let snapshot = try usesTiles && !entry.usesAssembly
                    ? entry.project.pictureExportSnapshot(ranges: [entry.range]) : entry.snapshot
                let document = CutProject.multicam(snapshot)
                if !usesTiles, try document.exportPlacementScope() != .none || typedSettings {
                    let recordingIndexes = entry.recordingDependencies.compactMap { entry.media[$0.id] }
                    try verifyQueuedStillSources(recordingIndexes)
                    try CutEngine(cancelled: cancelled).checkDestination(output,
                                                                         plannedSubfolder: organization.subfolder.isEmpty ? nil : folder)
                    let plan = try stillPlanner.resolve(document, tracks: tracks, mode: mode,
                                                        requireCameraCopy: requireCameraCopy, container: container,
                                                        settings: settings, audioOutput: audioOutput, audioAction: audioAction,
                                                        pictureTiming: pictureTiming, videoCodec: videoCodec)
                    try verifyQueuedStillSources(recordingIndexes)
                    return Item(output: output, payload: .still(plan))
                }
                let standardMode = mode ?? (usesTiles ? .encode : ExportRules.defaultMode(for: .multicam, tracks: tracks))
                let plan = try planner.resolution(snapshot, relativeTo: entry.document, output: output, mode: standardMode, tracks: tracks,
                                                  settings: settings, indexedSources: entry.media,
                                                  audioOutput: audioOutput, audioAction: audioAction).get()
                if requireCameraCopy && tracks != .audio && plan.encodedVideoDuration > .zero {
                    throw CutError(code: "camera_copy_required", message: "This range needs camera video encoding.")
                }
                return Item(output: output, payload: .multicam(plan))
            } catch let issue as CutError {
                // `multicam.edge.range` numbers the entry's own ranges, so it is 1 here. `segment` numbers the entry.
                var failure = CutError(code: issue.code, message: "Range \(index + 1): \(issue.message)", segment: index + 1,
                                       boundary: issue.boundary, nearest: issue.nearest, track: issue.track,
                                       multicam: entry.usesAssembly ? nil : issue.multicam, placementIDs: issue.placementIDs,
                                       laneID: issue.laneID)
                failure.alternatives = issue.alternatives
                failure.stillBoundaryAdjustments = issue.stillBoundaryAdjustments
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
        if case .failure(let issue) = review(ranges, choices: choices, organization: organization, cancelled: cancelled) {
            return issue
        }
        return nil
    }

    static func review(_ ranges: [MulticamQueuedRange], choices: MulticamExportChoices,
                       organization: ExportOrganization, cancelled: @escaping @Sendable () -> Bool = { false })
        -> Result<String, CutError> {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-queue-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let batch = try MulticamBulkExport(ranges: ranges, directory: scratch, container: choices.container, mode: choices.effectiveMode,
                                       tracks: choices.tracks, settings: choices.settings, organization: organization,
                                       engine: MulticamEngine(cancelled: cancelled), requireCameraCopy: choices.requireCameraCopy,
                                       cancelled: cancelled, audioOutput: choices.audioOutput, audioAction: choices.requestedAudioAction,
                                       pictureTiming: choices.pictureTiming)
            return .success(batch.items.map {
                "\($0.output.lastPathComponent)\n\($0.review)"
            }.joined(separator: "\n\n"))
        } catch let issue as CutError {
            return .failure(issue)
        } catch {
            return .failure(CutError(code: "export_failed", message: error.localizedDescription))
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
        guard canEnqueueMarkedRange else { return }
        do {
            queuedRanges.append(try captureMarkedQueueRange())
            clearQueueMarks()
            status = "Added 1 range to the export queue."
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func captureMarkedQueueRange() throws -> MulticamQueuedRange {
        guard canEnqueueMarkedRange, let project else { throw QueueEdit.noSelection }
        let name = projectName ?? "Multicam"
        if let selected = assemblySelection {
            let range = MulticamSilencePlanner.range(selected)
            let snapshot = try project.assemblySelection(range)
            return MulticamQueuedRange(name: name, range: range, project: snapshot, media: media, document: projectURL, usesAssembly: true)
        }
        guard let range = markedExportRange else { throw QueueEdit.noSelection }
        _ = try project.plan(ranges: [range])
        return MulticamQueuedRange(name: name, range: range, project: project, media: media, document: projectURL)
    }

    private func clearQueueMarks() {
        if assemblySelection != nil { assemblySelection = nil }
        markIn = nil
        markOut = nil
    }

    func renameQueuedRange(_ id: UUID, to name: String) throws {
        guard !isBusy else { throw QueueEdit.busy }
        guard let index = queuedRanges.firstIndex(where: { $0.id == id }) else { throw QueueEdit.invalidTarget }
        let name = try QueueEdit.name(name)
        var entry = queuedRanges[index]
        entry.name = name
        entry.excerpt?.name = name
        entry.contentID = UUID()
        queuedRanges[index] = entry
    }

    func reviseQueuedRange(_ id: UUID, extending: Bool) throws {
        guard !isBusy else { throw QueueEdit.busy }
        guard let index = queuedRanges.firstIndex(where: { $0.id == id }) else { throw QueueEdit.invalidTarget }
        let original = queuedRanges[index]
        var entry = try captureMarkedQueueRange()
        try checkQueueDependencies(entry.mediaDependencies, status: mediaStatus)
        if extending {
            guard original.usesAssembly == entry.usesAssembly else { throw QueueEdit.incompatibleCoordinateSpace }
            try QueueEdit.checkExtension(from: original.range.from, to: original.range.to,
                                         into: entry.range.from, through: entry.range.to)
        }
        entry.id = original.id
        entry.name = original.name
        queuedRanges[index] = entry
        clearQueueInvalidation(id)
        clearQueueMarks()
        status = "Updated the queued range."
    }

    @discardableResult
    func enqueueRanges(_ ranges: [MulticamRange]) -> Bool {
        guard !isBusy, let project, !ranges.isEmpty else { return false }
        do {
            let name = projectName ?? "Multicam"
            _ = try project.plan(ranges: ranges)
            let entries = ranges.map { range in
                MulticamQueuedRange(name: name, range: range, project: project, media: media, document: projectURL)
            }
            queuedRanges.append(contentsOf: entries)
            status = "Added \(entries.count) \(entries.count == 1 ? "range" : "ranges") to the export queue."
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func enqueuePauseTakes(_ retained: [AudioSpan]) -> Bool {
        guard !isBusy, let project else { return false }
        let name = projectName ?? "Multicam"
        do {
            let entries = try retained.map { span in
                let range = MulticamSilencePlanner.range(span)
                let snapshot = try project.assemblySelection(range)
                if !CutProject.multicam(project).requiresPictureProcessing,
                   let items = snapshot.assemblyItems, items.count == 1, let item = items.first,
                   let group = item.group, item.angleOverride == nil {
                    return MulticamQueuedRange(name: name, range: group, project: project, media: media, document: projectURL)
                }
                return MulticamQueuedRange(name: name, range: range, project: snapshot, media: media, document: projectURL, usesAssembly: true)
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

    func replanQueuedRange(_ id: UUID) throws {
        guard !isBusy else { throw QueueEdit.busy }
        guard let project, invalidatedQueueIDs.contains(id),
              let index = queuedRanges.firstIndex(where: { $0.id == id }) else { throw QueueEdit.invalidTarget }
        let original = queuedRanges[index]
        if original.excerpt != nil {
            guard self.canEnqueueMarkedRange else { throw QueueEdit.replanExcerpt }
            try reviseQueuedRange(id, extending: false)
            return
        }
        let snapshot: MulticamProject
        if original.usesAssembly {
            snapshot = try project.assemblySelection(original.range)
        } else {
            _ = try project.plan(ranges: [original.range])
            snapshot = project
        }
        let entry = MulticamQueuedRange(id: id, name: original.name, range: original.range, project: snapshot,
                                        media: media, document: projectURL, usesAssembly: original.usesAssembly)
        if let issue = entry.recordingDependencies.lazy.compactMap({ self.sourceIssues[$0.id] }).first {
            throw CutError(code: "source_needs_review", message: issue)
        }
        try checkQueueDependencies(entry.mediaDependencies, status: mediaStatus)
        queuedRanges[index] = entry
        clearQueueInvalidation(id)
        reconcileSourceLoads()
        status = "Replanned the queued range."
    }

    func removeQueuedRange(_ id: UUID) {
        guard !isExporting else { return }
        queuedRanges.removeAll { $0.id == id }
        clearQueueInvalidation(id)
        reconcileSourceLoads()
    }

    func showBulkQueue() {
        guard canShowBulkQueue else { return }
        preview.pause()
        isBulkQueuePresented = true
    }

    func resetExportQueue() {
        for entry in queuedRanges { clearQueueInvalidation(entry.id) }
        queuedRanges.removeAll()
        isBulkQueuePresented = false
        isReplacementAudioPresented = false
        bulkExportDirectory = nil
    }

    /// Plans every queued range with these settings, without writing: nil, or the failure with the alternatives
    /// of the export rules.
    func checkQueuedRanges(_ choices: MulticamExportChoices, organization: ExportOrganization = .init()) async -> CutError? {
        if case .failure(let issue) = await reviewQueuedRanges(choices, organization: organization) { return issue }
        return nil
    }

    func reviewQueuedRanges(_ choices: MulticamExportChoices, organization: ExportOrganization) async -> Result<String, CutError> {
        let ranges = readyQueuedRanges
        guard !ranges.isEmpty else { return .failure(noReadyQueueEntries) }
        let useSidecar = useAnalysisSidecars
        let excluded = AnalysisSidecar.excludedSources.union(sidecarExclusions)
        return await sidecarWork.detached(priority: .userInitiated) {
            AnalysisSidecar.$excludedSources.withValue(excluded) {
                AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                    MulticamBulkExport.review(ranges, choices: choices, organization: organization)
                }
            }
        }.value
    }

    func chooseBulkDestination(_ choices: MulticamExportChoices, organization: ExportOrganization, summary: String) {
        guard isBulkQueuePresented, !readyQueuedRanges.isEmpty, !isBusy else { return }
        let contentIDs = readyQueuedRanges.map(\.contentID)
        let panel = NSOpenPanel()
        panel.title = "Export Queued Ranges"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = bulkExportDirectory
        panel.accessoryView = multicamDeliveryAccessory(summary)
        panel.isAccessoryViewDisclosed = true
        ProjectPanels.present(panel, in: window, fromSheet: true) { [weak self] accepted in
            guard let self, self.isBulkQueuePresented, accepted, let directory = panel.url,
                  self.readyQueuedRanges.map(\.contentID) == contentIDs else { return }
            self.exportQueuedRanges(to: directory, container: choices.container, mode: choices.effectiveMode,
                                    tracks: choices.tracks, settings: choices.settings, organization: organization,
                                    requireCameraCopy: choices.requireCameraCopy, audioOutput: choices.audioOutput,
                                    audioAction: choices.requestedAudioAction, pictureTiming: choices.pictureTiming)
        }
    }

    func exportQueuedRanges(to directory: URL, container: String, mode: ExportMode,
                            tracks: ExportTracks, settings: ReencodeSettings = .init(), organization: ExportOrganization = .init(),
                            requireCameraCopy: Bool = false, audioOutput: MulticamAudioOutput = .separateTracks,
                            audioAction: ReencodeAudio? = nil, pictureTiming: StillPictureTiming? = nil) {
        let ranges = readyQueuedRanges
        guard !ranges.isEmpty, !isBusy else { return }
        bulkExportDirectory = directory
        isBulkQueuePresented = false
        let protected = protectedMediaPaths
        run("Exporting queued multicam ranges…", exporting: true) { [weak self] token, useSidecar in
            try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                let engine = MulticamEngine(cancelled: { token.isCancelled })
                try organization.validateSubfolder(in: directory, protectedMedia: protected)
                let batch: MulticamBulkExport
                do {
                    batch = try MulticamBulkExport(ranges: ranges, directory: directory, container: container,
                                                   mode: mode, tracks: tracks, settings: settings, organization: organization, engine: engine,
                                                   requireCameraCopy: requireCameraCopy, cancelled: { token.isCancelled },
                                                   audioOutput: audioOutput, audioAction: audioAction, pictureTiming: pictureTiming)
                } catch let issue as CutError {
                    // The times of a queued entry belong to its snapshot. The editor's switch suggestions are for the
                    // open project, so this failure is reported without the switch or edge it names.
                    var plain = CutError(code: issue.code, message: issue.message, segment: issue.segment, boundary: issue.boundary,
                                         nearest: issue.nearest, track: issue.track, laneID: issue.laneID)
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
    @State private var issueContentID: UUID?
    @State private var isChecking = false

    init(model: MulticamEditorModel) {
        self.model = model
        var options = MulticamExportChoices(entry: .multicamQueue, preferred: model.preferences.defaultExportMode)
        let placements = model.readyQueuedRanges.map(\.placements)
        options.placements = placements.contains(.insertion) ? .insertion : placements.contains(.replacement) ? .replacement : .none
        options.usePictureProject(model.readyQueuedRanges.map { CutProject.multicam($0.project) }.first(where: \.requiresPictureProcessing))
        options.mode = options.participantAudio == nil
            ? ExportRules.defaultStillMode(tracks: options.tracks, placements: options.placements, otherwise: options.mode) : .encode
        options.settle()
        _choices = State(initialValue: options)
    }

    private func export() {
        let requested = choices
        let layout = organization
        let ranges = model.readyQueuedRanges.map(\.contentID)
        isChecking = true
        Task {
            // Plan every range first, so that one that cannot be written shows the offers of the export rules.
            let review = await model.reviewQueuedRanges(requested, organization: layout)
            guard isChecking else { return }
            isChecking = false
            guard requested == choices, layout == organization, ranges == model.readyQueuedRanges.map(\.contentID) else { return }
            switch review {
            case .failure(let failure):
                issue = failure
                issueContentID = failure.segment.flatMap { number in
                    number > 0 && ranges.indices.contains(number - 1) ? ranges[number - 1] : nil
                }
            case .success(let summary):
                issue = nil
                model.chooseBulkDestination(requested, organization: layout, summary: summary)
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
                        ExportQueueRangeRow(index: index, title: entry.name, start: entry.range.from, end: entry.range.to,
                                            details: {
                                                QueueSnapshotDetails(title: entry.name, contentID: entry.contentID,
                                                                     canRevise: model.canEnqueueMarkedRange, hasExcerpt: entry.excerpt != nil,
                                                                     items: entry.snapshotItems,
                                                                     rename: { try model.renameQueuedRange(entry.id, to: $0) },
                                                                     revise: { try model.reviseQueuedRange(entry.id, extending: $0) })
                                            },
                                            saveExcerpt: entry.excerpt.map { excerpt in
                                                { excerpt.presentSave(in: model.window, canSave: model.canSaveProjectTo) }
                                            },
                                            replan: model.invalidatedQueueIDs.contains(entry.id)
                                                ? { try model.replanQueuedRange(entry.id) } : nil) {
                            model.removeQueuedRange(entry.id)
                        }
                    }
                }
                options
                ExportOrganizationFields(organization: $organization, stem: model.readyQueuedRanges.first?.name ?? "Multicam", container: choices.container)
                if let issue {
                    ExportOffersView(message: ExportRules.describe(issue, clips: []), alternatives: issue.alternatives ?? []) {
                        choices.apply($0)
                    }
                    // An unsafe edge of a queued range offers its verified times. Applying one moves that entry's edge.
                    if let edge = issue.multicam?.edge, edge.range == 1, let times = issue.nearest, !times.isEmpty,
                       let number = issue.segment, number > 0, model.readyQueuedRanges.indices.contains(number - 1),
                       let contentID = issueContentID, model.readyQueuedRanges[number - 1].contentID == contentID,
                       !model.readyQueuedRanges[number - 1].usesAssembly {
                        MulticamEdgeSuggestionsView(suggestion: MulticamEdgeSuggestion(edge: MulticamEdge(range: number, boundary: edge.boundary, at: edge.at),
                                                                                         times: times), preview: nil) {
                            model.applyQueuedEdgeSuggestion($0, for: issue, contentID: contentID)
                        }
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Close") { model.isBulkQueuePresented = false }.keyboardShortcut(.cancelAction)
                .help("Close export queue")
            Button(model.readyQueuedRanges.count == 1 ? "Export File…" : "Export \(model.readyQueuedRanges.count) Files…", action: export)
                .keyboardShortcut(.defaultAction).disabled(model.readyQueuedRanges.isEmpty || isChecking)
                .help("Export queued ranges")
        }
        .onChange(of: organization) { _, _ in issue = nil }
        .onChange(of: choices) { _, _ in
            issue = nil
            choices.settle()
        }
        .onChange(of: model.readyQueuedRanges.map(\.contentID)) { _, _ in
            issue = nil
            let placements = model.readyQueuedRanges.map(\.placements)
            choices.placements = placements.contains(.insertion) ? .insertion : placements.contains(.replacement) ? .replacement : .none
            choices.usePictureProject(model.readyQueuedRanges.map { CutProject.multicam($0.project) }.first(where: \.requiresPictureProcessing))
            choices.settle()
        }
        .onDisappear { isChecking = false }
        .frame(width: 500)
    }

    private var options: some View {
        Form {
            Picker("Tracks", selection: $choices.tracks) {
                ForEach(choices.trackChoices, id: \.self) {
                    Text(choices.participantAudio == nil
                         ? MulticamExportChoices.title(of: $0, placements: choices.placements)
                         : ($0 == .all ? "Program tracks" : ExportRules.displayName(tracks: $0))).tag($0)
                }
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
                Toggle("Require Camera Video Copy", isOn: $choices.requireCameraCopy)
                    .help("Require stream copy for retained camera video")
                Toggle("One frame per still", isOn: $choices.heldStills)
            }
            if choices.effectiveMode == .encode && choices.tracks != .audio {
                Picker("Video", selection: $choices.codec) {
                    ForEach(ReencodeCodec.allCases.filter { $0 != .jpeg }, id: \.self) { Text($0.displayName) }
                }
                .help("Choose video codec")
                Picker("Quality", selection: choices.codec == .prores ? $choices.proResQuality : $choices.standardQuality) {
                    ForEach(choices.qualities, id: \.self) { Text($0.displayName) }
                }
                .help("Set video quality")
            }
            if choices.tracks != .video {
                Picker("Audio output", selection: $choices.audioOutput) {
                    ForEach(MulticamAudioOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help(MulticamAudioOutput.playbackHelp)
                .disabled(choices.audio == .removeAudio)
                Picker("Audio action", selection: $choices.audio) {
                    ForEach(choices.deliveryActions, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Choose audio treatment independently of picture")
            }
        }
    }
}

extension MulticamEditorModel {
    func enqueueTranscriptSnapshot(_ snapshot: MulticamProject, excerpt: TranscriptQueueExcerpt, range: MulticamRange) throws -> UUID {
        guard !isBusy, project != nil else {
            throw CutError(code: "queue_failed", message: "The multicam excerpt is unavailable.")
        }
        let item = MulticamQueuedRange(name: excerpt.name, range: range, project: snapshot, media: media, document: projectURL,
                                       usesAssembly: true, excerpt: excerpt)
        queuedRanges.append(item)
        status = "Added \(excerpt.name) to the export queue."
        return item.id
    }
}
