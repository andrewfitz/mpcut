extension MulticamProject {
    /// Feed angles share the physical recording's clock and availability.
    public mutating func syncFeedAngleRecordings() {
        guard angles.contains(where: { $0.feedAngle != nil }) else { return }
        let parents = Dictionary(pictureSources.filter { $0.feedAngle == nil }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let names = Dictionary(participants.people.map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        for index in angles.indices {
            guard let reference = angles[index].feedAngle, let parent = parents[reference.sourceID] else { continue }
            angles[index].file = parent.file
            angles[index].offset = parent.offset
            angles[index].coverage = parent.coverage
            if let name = names[reference.feedID] { angles[index].name = name }
        }
    }

    mutating func mergeFeedAngleReferences(_ removed: String, into surviving: String) {
        var replacementAngles: [String: String] = [:]
        let survivingByParent = Dictionary(uniqueKeysWithValues: angles.compactMap { angle in
            angle.feedAngle.flatMap { $0.feedID == surviving ? ($0.sourceID, angle.id) : nil }
        })
        angles = angles.compactMap { angle in
            guard var feed = angle.feedAngle, feed.feedID == removed else { return angle }
            if let replacement = survivingByParent[feed.sourceID] {
                replacementAngles[angle.id] = replacement
                return nil
            }
            var renamed = angle
            feed.feedID = surviving
            renamed.feedAngle = feed
            return renamed
        }
        syncFeedAngleRecordings()
        guard !replacementAngles.isEmpty else { return }

        func replacement(_ angle: String) -> String { replacementAngles[angle] ?? angle }
        func remap(_ layouts: [TileLayoutSpan]) -> [TileLayoutSpan] {
            layouts.map { layout in
                var updated = layout
                for index in updated.slots.indices where updated.slots[index].target == .camera {
                    updated.slots[index].id = replacement(updated.slots[index].id)
                }
                return updated
            }
        }
        referenceAngle = replacement(referenceAngle)
        for index in switches.indices { switches[index].angle = replacement(switches[index].angle) }
        for index in speakerAngles.indices { speakerAngles[index].angleID = replacement(speakerAngles[index].angleID) }
        if participants.tileOutput?.audio.mode == .follow, let id = participants.tileOutput?.audio.ids.first {
            participants.tileOutput?.audio.ids = [replacement(id)]
        }
        if var render = participants.render {
            if render.audio.mode == .follow { render.audio.ids = render.audio.ids.map(replacement) }
            for shot in render.shots.indices {
                for slot in render.shots[shot].slots.indices where render.shots[shot].slots[slot].target == .camera {
                    render.shots[shot].slots[slot].id = replacement(render.shots[shot].slots[slot].id)
                }
            }
            participants.render = render
        }
        groupTileLayouts = remap(groupTileLayouts)
        assemblyItems = assemblyItems?.map { item in
            guard let range = item.group else { return item }
            return .group(range, angle: item.angleOverride.map(replacement), id: item.occurrenceID,
                          layouts: remap(item.tileLayouts))
        }
    }
}
