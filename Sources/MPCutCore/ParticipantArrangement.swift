import Foundation

func unavailableArrangedTile(_ id: String, sourceID: String, at time: RationalTime) -> CutError {
    .init(code: "unmappable_tile_layout",
          message: "Arranged destination ‘\(id)’ has no unique tile on source ‘\(sourceID)’ at \(time). Split the layout at this change and choose a visible destination.")
}

extension ParticipantGeometryIndex {
    /// Check every active geometry interval and store the arrangement separately for each layout epoch.
    func arrangementRanges(_ range: MulticamRange, destinations: [String], sourceID: String,
                           layoutChanges: [RationalTime]) throws -> [MulticamRange] {
        let events = Set(layoutChanges.filter { range.from < $0 && $0 < range.to })
        let points = arrangementCheckpoints(in: range, extra: events)
        var boundaries = [range.from]
        var previous: [String]?
        for time in points {
            let active = at(time).appearances
            var resolved = Set<String>()
            for id in destinations {
                guard let tile = destination(id, in: active) else {
                    throw unavailableArrangedTile(id, sourceID: sourceID, at: time)
                }
                guard resolved.insert(tile.id).inserted else {
                    throw CutError(code: "unmappable_tile_layout",
                        message: "Arranged destination ‘\(id)’ overlaps another destination on source ‘\(sourceID)’ at \(time).")
                }
            }
            let topology = arrangementTopology(active)
            if time != range.from, previous != topology || events.contains(time) { boundaries.append(time) }
            previous = topology
        }
        boundaries.append(range.to)
        return zip(boundaries, boundaries.dropFirst()).map { .init(from: $0, to: $1) }
    }
}

extension ParticipantProject {
    package func arrangedLayoutEpoch(sourceID: String, at time: RationalTime, within range: MulticamRange) throws -> MulticamRange? {
        guard range.contains(time), let source = sources.first(where: { $0.sourceID == sourceID }) else { return nil }
        let index = try ParticipantGeometryIndex(self, sourceID: sourceID, slots: [], checkCancellation: {})
        let epochs = try index.arrangementRanges(range, destinations: [], sourceID: sourceID, layoutChanges: source.layoutChangeTimes)
        return epochs.first { $0.contains(time) }
    }
}

extension ParticipantProject {
    func arrangedSpans(_ layout: TileLayoutSpan, sourceID: String, sourceOffset: RationalTime) throws -> [TileLayoutSpan] {
        guard layout.layout == .arranged else { return [layout] }
        let index = try ParticipantGeometryIndex(self, sourceID: sourceID, slots: [], checkCancellation: {})
        let range = try MulticamRange(from: layout.range.from.subtracting(sourceOffset),
                                     to: layout.range.to.subtracting(sourceOffset))
        let destinations = layout.slots.compactMap(\.arrangedDestination)
        let changes = sources.first { $0.sourceID == sourceID }?.layoutChangeTimes ?? []
        return try index.arrangementRanges(range, destinations: destinations, sourceID: sourceID, layoutChanges: changes).map {
            var span = layout
            span.range = try .init(from: $0.from.adding(sourceOffset), to: $0.to.adding(sourceOffset))
            return span
        }
    }
}

extension MulticamProject {
    func epochSpans(_ layout: TileLayoutSpan?, angle: String?, document: URL?) throws -> [TileLayoutSpan] {
        guard let layout else { return [] }
        guard layout.layout == .arranged else { return [layout] }
        var scoped = self
        scoped.assemblyItems = [.group(layout.range, angle: angle)]
        let sources = Dictionary(uniqueKeysWithValues: pictureSources.map { ($0.id, $0) })
        var mediaOffsets: [String: RationalTime] = [:]
        var spans: [TileLayoutSpan] = []
        for interval in try scoped.plan().intervals {
            guard let id = interval.pictureSourceID, let recording = sources[id] else {
                throw CutError(code: "unmappable_tile_layout",
                    message: "There is no picture source for the arranged layout at group time \(interval.group.from).")
            }
            let source = recording.feedAngle.flatMap { sources[$0.sourceID] } ?? recording
            if mediaOffsets[source.id] == nil, let document {
                let file = try CutProject.checkedMediaURL(source.file, relativeTo: document)
                mediaOffsets[source.id] = try CutEngine(tracks: .video).inspectSummary(file).multicamSourceOffset
            }
            let offset = try source.offset.adding(mediaOffsets[source.id] ?? .zero)
            var piece = layout
            piece.range = interval.group
            spans += try participants.arrangedSpans(piece, sourceID: source.id, sourceOffset: offset)
        }
        return spans
    }
}
