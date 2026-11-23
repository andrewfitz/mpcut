import Foundation
import MPCutCore

enum QueueEdit: LocalizedError {
    case noSelection, busy, invalidTarget, invalidName, invalidExtension, incompatibleCoordinateSpace

    var code: String {
        switch self {
        case .noSelection: "no_selection"
        case .busy: "busy"
        case .invalidTarget: "invalid_target"
        case .invalidName: "invalid_name"
        case .invalidExtension, .incompatibleCoordinateSpace: "invalid_extension"
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
