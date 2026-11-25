import Foundation
import MPCutCore

enum QueueEdit: LocalizedError {
    case noSelection, busy, invalidTarget, invalidName, invalidExtension, incompatibleCoordinateSpace, replanBounds, replanExcerpt

    var code: String {
        switch self {
        case .noSelection: "no_selection"
        case .busy: "busy"
        case .invalidTarget: "invalid_target"
        case .invalidName: "invalid_name"
        case .invalidExtension, .incompatibleCoordinateSpace: "invalid_extension"
        case .replanBounds: "invalid_range"
        case .replanExcerpt: "no_selection"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noSelection: "Mark a range in the editor."
        case .busy: "Wait for the editor to finish its current operation."
        case .invalidTarget: "Choose an existing queue entry."
        case .invalidName: "Enter a single filename stem without path separators or control characters."
        case .invalidExtension: "The marked range must contain the original bounds and extend at least one edge."
        case .incompatibleCoordinateSpace: "Mark the extension in the same timeline as the original range."
        case .replanBounds: "The original bounds are outside the current timeline. Mark a new range to revise this entry."
        case .replanExcerpt: "Mark a range in the editor to recapture this transcript excerpt."
        }
    }

    static func name(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (try? ExportOrganization(baseName: trimmed).validate()) != nil else { throw Self.invalidName }
        return trimmed
    }

    static func checkExtension(from: RationalTime, to: RationalTime, into start: RationalTime, through end: RationalTime) throws {
        guard start <= from, end >= to, start < from || end > to else { throw Self.invalidExtension }
    }
}

struct QueueSnapshotItem {
    let kind: String
    let file: String
    var from: RationalTime?
    var to: RationalTime?
    var output: MulticamRange?
    var stream: Int?
    var laneID: String?
    var laneLabel: String?
    var laneColorSlot: Int?

    var json: [String: Any] {
        var result: [String: Any] = ["kind": kind, "file": file]
        result["from"] = from?.description
        result["to"] = to?.description
        result["output_from"] = output?.from.description
        result["output_to"] = output?.to.description
        result["stream"] = stream
        result["lane_id"] = laneID
        result["lane_label"] = laneLabel
        result["lane_color_slot"] = laneColorSlot
        return result
    }

    var trim: String {
        guard let from, let to else { return "" }
        func timestamp(_ time: RationalTime) -> String {
            (time < .zero ? "−" : "") + timelineTime(abs(time.seconds), milliseconds: true)
        }
        return "\(timestamp(from)) – \(timestamp(to))"
    }

    static func still(_ insert: StillInsert, assets: [StillAsset], output: MulticamRange? = nil) -> Self {
        let asset = assets.first { $0.id == insert.assetID }
        return Self(kind: "still", file: asset?.isGap == true ? "Gap" : asset?.file ?? insert.assetID,
                    from: .zero, to: insert.duration, output: output)
    }
}

private extension CutProject {
    func queueReplacementItems(assets: [StillAsset]) throws -> [QueueSnapshotItem] {
        guard !stillReplacements.isEmpty else { return [] }
        let plan = try resolveStills()
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let replacements = Dictionary(uniqueKeysWithValues: stillReplacements.map { ($0.id, $0.assetID) })
        return try plan.spans.compactMap { span in
            guard let id = span.placementID, let assetID = replacements[id], let asset = assetByID[assetID] else { return nil }
            return QueueSnapshotItem(kind: "replacement", file: asset.isGap ? "Gap" : asset.file,
                                     from: .zero, to: try span.output.to.subtracting(span.output.from), output: span.output)
        }
    }
}

extension QueuedRange {
    func snapshotItems() throws -> [QueueSnapshotItem] {
        if case .stillSequence(let project) = stillProject {
            var items = project.items.map { item -> QueueSnapshotItem in
                switch item {
                case .source(let clip):
                    return .init(kind: "clip", file: clip.file, from: clip.from, to: clip.to)
                case .still(let insert):
                    return .still(insert, assets: project.stillAssets)
                }
            }
            items.append(contentsOf: try CutProject.stillSequence(project).queueReplacementItems(assets: project.stillAssets))
            let snapshot = CutProject.stillSequence(project)
            if project.stillSoundtrack != nil,
               let mapping = try snapshot.stillSoundtrackMapping(in: .init(from: .zero, to: try snapshot.resolveStills().duration)) {
                let streams = media[URL(fileURLWithPath: mapping.clip.file)]?.streams.filter { $0.kind == "audio" } ?? []
                let ordinal = mapping.clip.audioTrack ?? 0
                items.append(.init(kind: "audio", file: mapping.clip.file, from: mapping.source.from,
                                   to: mapping.source.to, output: mapping.output,
                                   stream: streams.indices.contains(ordinal) ? streams[ordinal].index : nil))
            }
            return items
        }
        return clips.map { .init(kind: "clip", file: $0.file.path, from: $0.from, to: $0.to) }
    }
}

extension MulticamQueuedRange {
    func snapshotItems() throws -> [QueueSnapshotItem] {
        let snapshot = snapshot
        let plan = try snapshot.plan()
        let sources = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
        let intervals = Dictionary(grouping: plan.intervals, by: \.assemblyIndex)
        var items: [QueueSnapshotItem] = []
        var time = RationalTime.zero
        for (index, item) in (snapshot.assemblyItems ?? [.group(snapshot.range)]).enumerated() {
            if let still = item.still {
                let end = try time.adding(still.duration)
                items.append(.still(still, assets: snapshot.stillAssets, output: .init(from: time, to: end)))
                time = end
            } else {
                for interval in intervals[index] ?? [] {
                    if let angle = interval.pictureSourceID.flatMap({ sources[$0] }) {
                        items.append(.init(kind: "angle", file: angle.file,
                                           from: try interval.group.from.subtracting(angle.offset),
                                           to: try interval.group.to.subtracting(angle.offset), output: interval.output))
                    } else {
                        items.append(.init(kind: "gap", file: "Gap", output: interval.output))
                    }
                    time = interval.output.to
                }
            }
        }
        items.append(contentsOf: try CutProject.multicam(snapshot).queueReplacementItems(assets: snapshot.stillAssets))
        let mix = snapshot.audio == .mix
        let lanes = try snapshot.resolveAudioLanes(plan: plan, indexedSources: media, assumeUnindexedCoverage: true)
        for lane in lanes {
            var laneItems = lane.spans.map {
                QueueSnapshotItem(kind: "audio", file: sources[$0.source]?.file ?? $0.source,
                                  from: $0.input.from, to: $0.input.to, output: $0.output, stream: $0.stream,
                                  laneID: mix ? lane.id : nil, laneLabel: mix ? lane.label : nil,
                                  laneColorSlot: mix ? lane.colorSlot : nil)
            }
            if mix {
                laneItems.append(contentsOf: lane.gaps.map {
                    .init(kind: "audio_gap", file: "Silence", output: $0,
                          laneID: lane.id, laneLabel: lane.label, laneColorSlot: lane.colorSlot)
                })
                laneItems.sort { ($0.output?.from ?? .zero) < ($1.output?.from ?? .zero) }
            }
            items.append(contentsOf: laneItems)
        }
        return items
    }
}

private extension CutProject {
    func queuedStillImages(in selection: MulticamRange? = nil, document: URL? = nil) -> Set<URL> {
        guard !stillAssets.isEmpty else { return [] }
        let placements = stillInserts.map { ($0.id, $0.assetID) } + stillReplacements.map { ($0.id, $0.assetID) }
        let byPlacement = Dictionary(placements, uniquingKeysWith: { first, _ in first })
        let used = (try? resolveStills()).map { plan in
            Set<String>(plan.spans.compactMap { span in
                guard selection.map({ span.output.from < $0.to && $0.from < span.output.to }) ?? true else { return nil }
                return span.placementID.flatMap { byPlacement[$0] }
            })
        } ?? Set(byPlacement.values)
        return Set(stillAssets.compactMap { asset in
            guard !asset.isGap, used.contains(asset.id) else { return nil }
            return queueMediaURL(asset.file, document: document)
        })
    }
}

private func queueMediaURL(_ path: String, document: URL?) -> URL {
    ProjectMediaVolume.watchURL(document.map { CutProject.mediaURL(path, relativeTo: $0) }
                                ?? URL(fileURLWithPath: path))
}

struct QueueMediaTargets {
    private(set) var presenceOnlyByURL: [URL: Bool] = [:]
    private(set) var indexed: [URL: MediaInfo] = [:]

    mutating func include(recordings: Set<URL>, stills: Set<URL>, media: some Sequence<MediaInfo>) {
        for url in stills where presenceOnlyByURL[url] == nil { presenceOnlyByURL[url] = true }
        for url in recordings { presenceOnlyByURL[url] = false }
        for info in media {
            let url = ProjectMediaVolume.watchURL(info.url)
            if recordings.contains(url) { indexed[url] = info }
        }
    }
}

extension QueuedRange {
    private var recordingURLs: Set<URL> {
        var urls = Set(clips.map { ProjectMediaVolume.watchURL($0.file) })
        let project = pictureProject ?? stillProject
        for reference in [project?.stillAudioReference, project?.stillSoundtrack].compactMap({ $0 }) {
            urls.insert(queueMediaURL(reference.file, document: pictureDocument))
        }
        if let project, project.requiresPictureProcessing {
            let audio = project.projectOutputSettings.audio
            if audio.mode == .iso, let id = audio.ids.first,
               let source = project.participants.audioBinding(for: id)?.selection?.source {
                urls.insert(queueMediaURL(source, document: pictureDocument))
            }
        }
        return urls
    }

    private var stillURLs: Set<URL> {
        let selection = pictureProject.map { _ in MulticamRange(from: start, to: end) }
        return (pictureProject ?? stillProject)?.queuedStillImages(in: selection, document: pictureDocument) ?? []
    }

    var mediaDependencies: Set<URL> {
        recordingURLs.union(stillURLs)
    }

    func addMediaTargets(to targets: inout QueueMediaTargets) {
        targets.include(recordings: recordingURLs, stills: stillURLs, media: media.values)
    }
}

extension MulticamQueuedRange {
    var recordingDependencies: [MulticamSource] {
        let snapshot = snapshot
        guard let plan = try? snapshot.plan() else { return snapshot.sources }
        var used = Set(plan.picture.map(\.source))
        if plan.picture.isEmpty {
            if let reference = plan.intervals.first?.angle { used.insert(reference) }
            // A still-only assembly uses the reference angle to choose its output format.
            if snapshot.assemblyItems?.contains(where: { $0.still != nil }) == true {
                used.insert(snapshot.referenceAngle)
            }
        }
        if !snapshot.stillReplacements.isEmpty, let stillPlan = try? CutProject.multicam(snapshot).resolveStills() {
            for span in stillPlan.spans where span.placementID != nil {
                guard case .group(_, let group) = span.origin,
                      let source = snapshot.pictureSource(for: snapshot.referenceAngle, at: group.from),
                      source.coverage.map({ group.to <= $0.to }) ?? true else { continue }
                used.insert(source.id)
            }
        }
        let bindings = Dictionary(uniqueKeysWithValues: snapshot.audioReplacements.map { ($0.original, $0) })
        for lane in plan.audioLanes {
            if lane.spans.isEmpty, let selection = snapshot.configuredSelection(for: lane) {
                used.insert(selection.source)
            }
            for span in lane.spans {
                let selection = span.stream.map { MulticamAudioSelection(source: span.source, stream: $0) }
                if let binding = selection.flatMap({ bindings[$0] }) {
                    used.insert(binding.replacement.source)
                    // Replacement coverage may require scratch audio as a fallback.
                    if binding.uncovered == .keepOriginal { used.insert(span.source) }
                } else {
                    used.insert(span.source)
                }
            }
        }
        return snapshot.sources.filter { used.contains($0.id) }
    }

    private var recordingURLs: Set<URL> {
        Set(recordingDependencies.map { queueMediaURL($0.file, document: document) })
    }

    var mediaDependencies: Set<URL> {
        recordingURLs.union(CutProject.multicam(snapshot).queuedStillImages(document: document))
    }

    func addMediaTargets(to targets: inout QueueMediaTargets) {
        targets.include(recordings: recordingURLs, stills: CutProject.multicam(snapshot).queuedStillImages(document: document),
                        media: media.values)
    }
}

let noReadyQueueEntries = CutError(code: "no_ready_queue_entries", message: "Replan an affected range or add a new range to export.")

@MainActor
func checkQueueDependencies(_ urls: Set<URL>, status: (URL) -> ProjectMediaStatus) throws {
    if let blocked = urls.sorted(by: { $0.path < $1.path }).first(where: {
        [.offline, .ignored, .changed, .needsReview, .checking].contains(status($0))
    }) {
        throw CutError(code: "source_needs_review",
                       message: "Review \(blocked.lastPathComponent) in Project Media before replanning this entry.")
    }
}
