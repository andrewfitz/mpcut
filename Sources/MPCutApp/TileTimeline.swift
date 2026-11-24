import AppKit
import MPCutCore
import SwiftUI

struct TileTimelineContent: Equatable {
    struct FeedSpan: Equatable {
        let sourceID: String
        let appearanceID: String
        let range: MulticamRange
        let coverage: [ParticipantCoverage]
        let hasStart: Bool
        let hasEnd: Bool
        let sourceOffset: RationalTime
        let bounds: MulticamRange
        let sourceRange: MulticamRange
    }

    struct Feed: Equatable, Identifiable {
        let id: String
        let name: String
        var spans: [FeedSpan]
    }

    var layouts: [TileLayoutSpan] = []
    var overrides: [TileLayoutSpan] = []
    var feeds: [Feed] = []
    var ticks: [RationalTime] = []
    var feedNames: [String: String] = [:]
    var cameraNames: [String: String] = [:]
    var edited = false

    var hasLayouts: Bool { !layouts.isEmpty || !overrides.isEmpty }

    static func feedRows(in tileContent: [UUID: Self]) -> [Feed] {
        var rows: [String: TileTimelineContent.Feed] = [:]
        for content in tileContent.values {
            for feed in content.feeds { rows[feed.id] = feed }
        }
        return rows.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func fillingGaps(_ layouts: [TileLayoutSpan], in range: MulticamRange) -> [TileLayoutSpan] {
        var cursor = range.from
        var result: [TileLayoutSpan] = []
        for layout in layouts {
            guard let clipped = layout.range.tileIntersection(range) else { continue }
            if cursor < clipped.from {
                result.append(.init(range: .init(from: cursor, to: clipped.from), layout: .original))
            }
            var span = layout
            span.range = clipped
            result.append(span)
            cursor = clipped.to
        }
        if cursor < range.to { result.append(.init(range: .init(from: cursor, to: range.to), layout: .original)) }
        return result
    }

    func layoutName(_ layout: TileLayoutSpan) -> String {
        let name = switch layout.layout {
        case .pair: "Side by Side"
        default: layout.layout.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let names = layout.slots.compactMap { slot -> String? in
            switch slot.target {
            case .participant: feedNames[slot.id]
            case .camera: cameraNames[slot.id]
            case .presentation: "Screen Share"
            case .empty: nil
            }
        }
        guard !names.isEmpty else { return name }
        let suffix = names.count > 3 ? " +\(names.count - 3)" : ""
        return "\(name) · \(names.prefix(3).joined(separator: ", "))\(suffix)"
    }

    mutating func addFeeds(_ project: ParticipantProject, sourceID: String, input: MulticamRange,
                           offset: RationalTime, feedID: String? = nil) {
        guard let source = project.sources.first(where: { $0.sourceID == sourceID }),
              let bounds = input.tileTranslated(by: offset) else { return }
        if feedNames.isEmpty {
            feedNames = Dictionary(project.people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        ticks += source.layoutChangeTimes.filter { input.contains($0) }.compactMap { try? $0.adding(offset) }
        let coverage = source.coverage.compactMap { coverage -> ParticipantCoverage? in
            guard coverage.state == .verified,
                  let retained = input.tileIntersection(coverage.range),
                  let projected = retained.tileTranslated(by: offset) else { return nil }
            return ParticipantCoverage(range: projected, state: .verified)
        }
        let appearances = source.appearances.filter { appearance in
            (feedID == nil || appearance.participantID == feedID) && appearance.range.tileIntersection(input) != nil
        }
        let next = Dictionary(grouping: appearances, by: \.participantID)
        for (feedID, appearances) in next {
            let id = feedID ?? ""
            let spans = appearances.compactMap { appearance -> FeedSpan? in
                guard let retained = appearance.range.tileIntersection(input),
                      let projected = retained.tileTranslated(by: offset) else { return nil }
                return FeedSpan(sourceID: sourceID, appearanceID: appearance.id, range: projected,
                                coverage: coverage, hasStart: retained.from == appearance.range.from,
                                hasEnd: retained.to == appearance.range.to, sourceOffset: offset, bounds: bounds,
                                sourceRange: appearance.range)
            }
            if let index = feeds.firstIndex(where: { $0.id == id }) {
                feeds[index].spans += spans
            } else {
                feeds.append(Feed(id: id, name: feedNames[id] ?? "Unassigned Tiles", spans: spans))
            }
        }
        feeds.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func layoutDisplayProject(_ project: MulticamProject) -> MulticamProject {
        guard project.participants.render != nil, project.participants.tileOutput == nil,
              case .multicam(let converted)? = try? CutProject.multicam(project).migratingLegacyTiles() else { return project }
        return converted
    }

    static func group(_ project: MulticamProject, media: [String: MediaInfo],
                      intervals: [MulticamInterval]) -> Self {
        var content = Self(layouts: project.groupTileLayouts.isEmpty ? []
            : fillingGaps(project.groupTileLayouts, in: project.range))
        content.feedNames = Dictionary(project.participants.people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        content.cameraNames = Dictionary(project.angles.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let sources = Dictionary(project.pictureSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for interval in intervals {
            guard let id = interval.pictureSourceID, let source = sources[id],
                  let offset = try? source.offset.adding(media[id]?.multicamClockOffset
                    ?? source.feedAngle.flatMap { media[$0.sourceID]?.multicamClockOffset } ?? .zero),
                  let inverse = try? RationalTime.zero.subtracting(offset),
                  let input = interval.group.tileTranslated(by: inverse) else { continue }
            content.addFeeds(project.participants, sourceID: source.feedAngle?.sourceID ?? id, input: input, offset: offset,
                             feedID: source.feedAngle?.feedID)
        }
        content.ticks = Array(Set(content.ticks)).sorted()
        if content.layouts.isEmpty && !content.feeds.isEmpty {
            content.layouts = fillingGaps([], in: project.range)
        }
        return content
    }
}

func tileTimelineTime(_ seconds: Double) -> RationalTime? {
    guard let micros = Int64(exactly: (seconds * 1_000_000).rounded()) else { return nil }
    return RationalTime(numerator: micros, denominator: 1_000_000)
}

extension MulticamRange {
    func tileIntersection(_ other: Self) -> Self? {
        let from = max(from, other.from)
        let to = min(to, other.to)
        return from < to ? .init(from: from, to: to) : nil
    }

    func tileTranslated(by offset: RationalTime) -> Self? {
        guard let from = try? from.adding(offset), let to = try? to.adding(offset) else { return nil }
        return .init(from: from, to: to)
    }
}

enum TileTimelineEdit {
    static func resize(_ project: ParticipantProject, span: TileTimelineContent.FeedSpan,
                       edge: TimelineEdge, to target: RationalTime) throws -> ParticipantProject {
        var project = project
        let bounded = min(span.bounds.to, max(span.bounds.from, target))
        guard let local = try? bounded.subtracting(span.sourceOffset), local >= .zero,
              let source = project.sources.firstIndex(where: { $0.sourceID == span.sourceID }) else {
            throw CutError(code: "invalid_tile_range", message: "Choose an edge within the recording.")
        }
        let track = project.sources[source].appearances.indices.filter {
            project.sources[source].appearances[$0].id == span.appearanceID
        }
        guard let index = track.first(where: { project.sources[source].appearances[$0].range == span.sourceRange }),
              edge == .start ? span.hasStart : span.hasEnd else {
            throw CutError(code: "stale_tile_range", message: "This tile span changed. Choose its edge again.")
        }
        let appearance = project.sources[source].appearances[index]
        let ranges = track.map { project.sources[source].appearances[$0].range }
        let previousEnd = ranges.lazy.filter { $0.to <= appearance.range.from }.map(\.to).max()
        let nextStart = ranges.lazy.filter { $0.from >= appearance.range.to }.map(\.from).min()
        let range = edge == .start
            ? MulticamRange(from: max(local, previousEnd ?? local), to: appearance.range.to)
            : MulticamRange(from: appearance.range.from, to: min(local, nextStart ?? local))
        guard range.from < range.to else {
            throw CutError(code: "invalid_tile_range", message: "A tile span must have a start before its end.")
        }
        project.sources[source].appearances[index].range = range
        return project
    }
}

extension MulticamEditorModel {
    func setTileLayout(_ layout: ParticipantShotLayout?, slots: [ParticipantSlot] = [], compact: Bool = false,
                       at monitorTime: RationalTime? = nil,
                       position: ParticipantMonitorPosition? = nil) throws {
        guard let project else {
            throw CutError(code: "invalid_tile_layout", message: "Open a multicam project to set a layout.")
        }
        let scope: TileLayoutScope
        var range: MulticamRange
        if assemblyPreview || (monitorTime == nil && editSelection == .assembly) {
            let index = monitorTime.map { occurrenceIndex(at: $0) } ?? selectedOccurrence
            guard let occurrence = project.tileOccurrenceID(at: index), let group = assemblyRange(at: index) else {
                throw CutError(code: "invalid_tile_layout", message: "Select a video occurrence to set a layout.")
            }
            scope = .occurrence(occurrence)
            if let marks = assemblySelection {
                let base = index > 0 ? assemblyRangeEnds[index - 1] : .zero
                let end = assemblyRangeEnds[index]
                guard let marked = MulticamRange(from: marks.from, to: marks.to)
                    .tileIntersection(.init(from: base, to: end)) else {
                    throw CutError(code: "invalid_tile_layout", message: "Set marks within the selected occurrence.")
                }
                range = try MulticamRange(from: group.from.adding(marked.from.subtracting(base)),
                                          to: group.from.adding(marked.to.subtracting(base)))
            } else if monitorTime != nil, let markIn, let markOut {
                guard group.from <= markIn, markIn < markOut, markOut <= group.to else {
                    throw CutError(code: "invalid_tile_layout", message: "Set marks within the displayed occurrence.")
                }
                range = .init(from: markIn, to: markOut)
            } else {
                range = group
            }
        } else {
            scope = .group
            range = MulticamRange(from: markIn ?? project.range.from, to: markOut ?? project.range.to)
        }
        if layout == .arranged, let monitorTime, let position,
           assemblySelection == nil, markIn == nil, markOut == nil,
           let group = interval(at: monitorTime)?.group,
           let source = project.pictureSources.first(where: { $0.id == position.sourceID }),
           let clipped = range.tileIntersection(group) {
            let offset = try source.offset.adding(position.media.multicamClockOffset)
            let local = try MulticamRange(from: clipped.from.subtracting(offset), to: clipped.to.subtracting(offset))
            if let epoch = try project.participants.arrangedLayoutEpoch(sourceID: source.id, at: position.time, within: local) {
                range = try .init(from: epoch.from.adding(offset), to: epoch.to.adding(offset))
            }
        }
        try setTileLayout(scope: scope, range: range, layout: layout, slots: slots, compact: compact)
    }

    func setTileLayout(scope: TileLayoutScope, range: MulticamRange, layout: ParticipantShotLayout?,
                       slots: [ParticipantSlot] = [], compact: Bool = false) throws {
        guard !isBusy, let project else {
            throw CutError(code: "editor_busy", message: "The multicam editor is unavailable for editing.")
        }
        let span = layout.map { TileLayoutSpan(range: range, layout: $0, slots: slots, compact: compact) }
        let updated = try CutProject.multicam(project).settingTileLayout(scope: scope, range: range, layout: span, relativeTo: projectURL)
        try replaceTileLayoutProject(updated)
    }

    func replaceTileLayoutProject(_ document: CutProject, action: String = "Set Tile Layout") throws {
        guard case .multicam(let next) = document else {
            throw CutError(code: "invalid_tile_layout", message: "The layout needs a multicam project.")
        }
        try document.validate()
        guard byHand({ edit(action) { $0 = next } }) else {
            throw CutError(code: "invalid_tile_layout", message: "The layout could not be applied.")
        }
    }

    func clearMarkedTileLayout() {
        do {
            try setTileLayout(nil)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func clearMarkedGroupTileLayout() {
        guard let markIn, let markOut else { return }
        do {
            try setTileLayout(scope: .group, range: .init(from: markIn, to: markOut), layout: nil)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func resizeTimelineTile(_ span: TileTimelineContent.FeedSpan, edge: TimelineEdge, at seconds: Double) {
        do {
            guard let target = tileTimelineTime(seconds) else { return }
            let next = try TileTimelineEdit.resize(project?.participants ?? .init(), span: span, edge: edge, to: target)
            try byHand { try replaceParticipantProject(next, action: "Move Tile Span Edge") }
        } catch {
            fail(error.localizedDescription)
        }
    }
}
