import Foundation
import MPCutCore
import SwiftUI

/// What the Export Queue offers for its ranges. Every list and name comes from the export rules.
struct ExportQueueChoices {
    let hasVideo: Bool
    let hasAudio: Bool
    let placements: ExportPlacementScope
    /// The codec of the first queued audio track, whose own format leads the conversions.
    let audioCodec: String?

    init(media: [MediaInfo], audioCodec: String? = nil, placements: ExportPlacementScope = .none) {
        self.placements = placements
        hasVideo = placements != .none || media.contains(where: \.hasVideo)
        hasAudio = media.contains { $0.streams.contains { $0.kind == "audio" } }
        self.audioCodec = audioCodec
    }

    var source: ExportSourceKind { hasVideo ? .movie : .audio }

    /// The selection the queue requests. A movie without sound keeps both track types, as the Export sheet does.
    func tracks(_ selected: ExportTracks) -> ExportTracks {
        guard hasVideo else { return .audio }
        return hasAudio ? selected : .all
    }

    func cell(tracks: ExportTracks, mode: ExportMode) -> ExportCell {
        ExportEntryPoint.queue.answer(source: source, tracks: tracks, mode: mode, placements: placements)
    }
    func modes(tracks: ExportTracks) -> [ExportMode] { ExportEntryPoint.queue.selectableModes(source: source, tracks: tracks, placements: placements) }
    func title(_ mode: ExportMode, tracks: ExportTracks) -> String { cell(tracks: tracks, mode: mode).displayName }
    /// The named formats of Convert Audio, the source's own first.
    var conversions: [ReencodeAudio] {
        let formats = ExportRules.namedConversions(sourceCodec: audioCodec)
        return placements == .insertion ? formats.filter(ExportRules.stillSoundConversions.contains) : formats
    }
    /// The audio actions of a movie re-encode.
    func movieAudio(mode: ExportMode) -> [ReencodeAudio] { cell(tracks: .all, mode: mode).audioActions }

    /// Plans every range as the export will, without writing. Nil when all of them can be written.
    static func check(_ groups: [[ClipRequest]], media: [URL: MediaInfo], options: ExportSheetOptions,
                      cancelled: @escaping @Sendable () -> Bool = { false }) -> CutError? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-queue-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: scratch) }
            _ = try BulkExport(groups: groups, directory: scratch, organization: options.organization, mode: options.effectiveMode, tracks: options.tracks,
                               audioTrackOrdinal: options.audioTrackOrdinal,
                               container: options.container.isEmpty ? nil : options.container,
                               settings: options.batchSettings, media: media, cancelled: cancelled)
            return nil
        } catch let issue as CutError {
            return issue
        } catch {
            return CutError(code: "export_failed", message: error.localizedDescription)
        }
    }

    /// The alternatives a queue can apply. Its settings are shared by every range, so cuts are not moved.
    static func offers(for issue: CutError) -> [ExportAlternative] {
        (issue.alternatives ?? []).filter { $0.rung != .copySampleAligned }
    }
}

extension EditorModel {
    /// Checks the queued ranges with these settings: nil, or the failure with the alternatives of the export rules.
    func checkQueuedRanges(options: ExportSheetOptions) async -> CutError? {
        if case .failure(let issue) = await reviewQueuedRanges(options: options) { return issue }
        return nil
    }

    func reviewQueuedRanges(options: ExportSheetOptions) async -> Result<String?, CutError> {
        let ranges = readyQueuedRanges
        guard !ranges.isEmpty else { return .failure(noReadyQueueEntries) }
        let useSidecar = useAnalysisSidecars
        let excludedSources = sidecarExclusions
        let task = sidecarWork.detached(priority: .userInitiated) { () -> Result<String?, CutError> in
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mpcut-queue-check-\(UUID())", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: scratch) }
                let batch = try AnalysisSidecar.$excludedSources.withValue(excludedSources) {
                    try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                        try SequenceQueuePlan(ranges, directory: scratch, options: options, useSidecar: useSidecar,
                                              cancelled: { Task.isCancelled })
                    }
                }
                let summaries = batch.items.compactMap { item -> String? in
                    switch item.payload {
                    case .ordinary: return nil
                    case .still(let plan): return "\(item.output.lastPathComponent)\n\(plan.inspectorSummary)"
                    case .picture(let plan):
                        let mode = ExportRules.displayName(mode: options.mode, soundOnly: options.tracks == .audio)
                        return ([item.output.lastPathComponent, mode] + plan.notices).joined(separator: "\n")
                    }
                }
                return .success(batch.review(interleaving: summaries))
            } catch let issue as CutError {
                return .failure(issue)
            } catch {
                return .failure(CutError(code: "export_failed", message: error.localizedDescription))
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// An unavailable export with the alternatives the export rules report for it, least destructive first:
/// the first as the button, the rest in the menu beside it.
struct ExportOffersView: View {
    let message: String
    let alternatives: [ExportAlternative]
    let apply: (ExportAlternative) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IssueLabel(message)
            if let first = alternatives.first {
                // Side by side where the whole label fits, as in the queue. In a narrow inspector the menu goes
                // below, so the label of the first alternative is not cut short.
                // Where even that is too narrow, as in the multicam inspector at its minimum width, the button shows
                // the label without its remark and the whole label stays in the tooltip.
                ViewThatFits(in: .horizontal) {
                    HStack { choices(first) }
                    VStack(alignment: .leading, spacing: 6) { choices(first) }
                    VStack(alignment: .leading, spacing: 6) { choices(first, compact: true) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The label without its remark in parentheses: "Use Smart Trim (encodes only the cut edges) in MOV" is "Use Smart Trim in MOV".
    static func compactLabel(_ label: String) -> String {
        let withoutRemark = label.replacingOccurrences(of: #" \([^()]*\)"#, with: "", options: .regularExpression)
        return withoutRemark.replacingOccurrences(of: "Copy with cuts on the nearest audio sample", with: "Copy at nearest audio samples")
    }

    @ViewBuilder private func choices(_ first: ExportAlternative, compact: Bool = false) -> some View {
        Button(compact ? Self.compactLabel(first.label) : first.label) { apply(first) }
            .help(first.label)
            .accessibilityLabel(first.label)
        if alternatives.count > 1 {
            Menu("More Alternatives") {
                ForEach(alternatives.dropFirst(), id: \.id) { alternative in
                    Button(alternative.label) { apply(alternative) }
                        .help("Use this export alternative")
                }
            }
            .fixedSize()
            .accessibilityLabel("More export alternatives")
            .help("Show more export alternatives")
        }
    }
}

/// A queue can mix retained-range exports and exports of versioned snapshots with visible stills.
struct SequenceQueuePlan: Sendable {
    enum Payload: Sendable {
        case ordinary(BulkExport.Item)
        case still(StillExportPlan)
        case picture(ParticipantProjectExport)
    }

    struct Item: Sendable {
        let output: URL
        let payload: Payload
    }

    let items: [Item]
    let folder: URL
    private let directory: URL
    private let organization: ExportOrganization
    private let useSidecar: Bool
    private let cancelled: @Sendable () -> Bool

    init(_ ranges: [QueuedRange], directory: URL, options: ExportSheetOptions, useSidecar: Bool = true,
         ordinaryModeWhenUnspecified: ExportMode? = nil, audioAction: ReencodeAudio? = nil,
         cancelled: @escaping @Sendable () -> Bool) throws {
        self.directory = directory
        organization = options.organization
        self.useSidecar = useSidecar
        self.cancelled = cancelled
        let folder = try organization.directory(in: directory, create: false)
        self.folder = folder
        let stem = ranges.first?.clips.first?.file.deletingPathExtension().lastPathComponent ?? "Stills"
        let destinationCheck = CutEngine(cancelled: cancelled)
        let plannedSubfolder = organization.subfolder.isEmpty ? nil : folder
        let mode = ordinaryModeWhenUnspecified ?? options.effectiveMode
        let container = options.container.isEmpty ? nil : options.container
        var indexed: [URL: MediaInfo] = [:]
        for range in ranges {
            if cancelled() { throw CutError(code: "cancelled", message: "Operation cancelled.") }
            for (url, media) in range.media {
                if let previous = indexed[url], !previous.identity.matchesSnapshot(media.identity) {
                    throw CutError(code: "source_changed", message: "Queued ranges refer to different versions of \(url.lastPathComponent).")
                }
                indexed[url] = media
            }
        }
        if !ranges.contains(where: { $0.stillProject != nil || $0.pictureProject != nil }) {
            let batch = try BulkExport(groups: ranges.map(\.clips), directory: directory,
                                       outputStems: ranges.map { $0.name ?? stem }, organization: organization, mode: mode,
                                       tracks: options.tracks, audioTrackOrdinal: options.audioTrackOrdinal,
                                       container: container, settings: options.batchSettings, media: indexed,
                                       useSidecar: useSidecar, cancelled: cancelled)
            items = try batch.items.enumerated().map { index, planned in
                do {
                    if options.requireCameraCopy { try planned.plan.checkCameraCopy() }
                    return Item(output: planned.output, payload: .ordinary(planned))
                } catch let issue as CutError {
                    throw Self.rangeError(issue, index: index)
                }
            }
            return
        }
        var result: [Item] = []
        for (index, range) in ranges.enumerated() {
            let suffix = String(format: "%03ld", index + 1)
            let entryStem = range.name ?? stem
            do {
                if let project = range.pictureProject ?? range.stillProject, project.requiresPictureProcessing {
                    try verifyQueuedStillSources(range.media.values)
                    guard !options.requireCameraCopy || options.tracks == .audio else {
                        throw CutError(code: "camera_copy_required", message: "This range needs picture encoding for its tile edits.")
                    }
                    var pictureOptions = options
                    pictureOptions.requiresPictureProcessing = true
                    let output = try organization.destination(in: folder, stem: entryStem, suffix: suffix,
                                                              container: pictureOptions.container.isEmpty ? "mov" : pictureOptions.container)
                    let selection = range.pictureProject == nil ? nil : MulticamRange(from: range.start, to: range.end)
                    let plan = try ParticipantProjectExport(project, relativeTo: range.pictureDocument, output: output,
                        mode: ordinaryModeWhenUnspecified ?? options.mode, tracks: options.tracks, settings: options.batchSettings,
                        audioAction: audioAction,
                        plannedSubfolder: plannedSubfolder, range: selection,
                        audioTrackOrdinal: options.audioTrackOrdinal, cancelled: cancelled)
                    try verifyQueuedStillSources(range.media.values)
                    result.append(.init(output: output, payload: .picture(plan)))
                } else if let project = range.stillProject {
                    try verifyQueuedStillSources(range.media.values)
                    var requested = options
                    requested.placements = range.placements
                    requested.pictureTiming = requested.pictureTiming ?? range.pictureTiming
                    let expectedSoundtrackIdentity = project.stillSoundtrack.flatMap {
                        range.media[URL(fileURLWithPath: $0.file)]?.identity
                    }
                    let plan = try requested.planStills(project, useSidecar: useSidecar, audioAction: audioAction,
                                                         expectedSoundtrackIdentity: expectedSoundtrackIdentity, cancelled: cancelled)
                    try verifyQueuedStillSources(range.media.values)
                    let output = try organization.destination(in: folder, stem: entryStem, suffix: suffix, container: plan.container)
                    try destinationCheck.checkDestination(output, plannedSubfolder: plannedSubfolder)
                    result.append(.init(output: output, payload: .still(plan)))
                } else {
                    let batch = try BulkExport(groups: [range.clips], directory: directory, outputSuffixes: [suffix],
                                               outputStems: [entryStem], organization: organization, mode: mode,
                                               tracks: options.tracks, audioTrackOrdinal: options.audioTrackOrdinal,
                                               container: container, settings: options.batchSettings, media: range.media,
                                               useSidecar: useSidecar, cancelled: cancelled)
                    let planned = batch.items[0]
                    if options.requireCameraCopy { try planned.plan.checkCameraCopy() }
                    result.append(.init(output: planned.output, payload: .ordinary(planned)))
                }
            } catch let issue as CutError {
                throw Self.rangeError(issue, index: index)
            }
        }
        items = result
    }

    private static func rangeError(_ issue: CutError, index: Int) -> CutError {
        let message = issue.message.hasPrefix("Range 1: ") ? String(issue.message.dropFirst(9)) : issue.message
        var failure = CutError(code: issue.code, message: "Range \(index + 1): \(message)",
                               segment: index + 1, boundary: issue.boundary, nearest: issue.nearest,
                               track: issue.track, placementIDs: issue.placementIDs)
        failure.alternatives = issue.alternatives
        failure.stillBoundaryAdjustments = issue.stillBoundaryAdjustments
        failure.reason = issue.factor
        return failure
    }

    func write(_ item: Item, progress: @escaping @Sendable (Double) -> Bool) throws {
        _ = try organization.directory(in: directory, create: true)
        switch item.payload {
        case .ordinary(let planned):
            try ExportPlanner(cancelled: cancelled, useSidecar: useSidecar).write(planned.plan, to: item.output, progress: progress)
        case .picture(let plan):
            try plan.write(to: item.output, cancelled: cancelled, progress: progress)
        case .still(let plan):
            try StillExportPlanner(useSidecar: useSidecar, cancelled: cancelled).write(plan, to: item.output, progress: progress)
        }
    }
}

func verifyQueuedStillSources(_ sources: some Sequence<MediaInfo>) throws {
    for source in sources where !source.identity.isCurrentSnapshot(at: source.url) {
        throw CutError(code: "source_changed", message: "\(source.url.lastPathComponent) changed after the range was queued.")
    }
}
