import Foundation

public struct TileFeedAngle: Codable, Hashable, Sendable {
    public var sourceID: String
    public var feedID: String

    public init(sourceID: String, feedID: String) {
        self.sourceID = sourceID
        self.feedID = feedID
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case feedID = "feed_id"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_tile_feed_angle")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourceID: try values.decode(String.self, forKey: .sourceID),
                  feedID: try values.decode(String.self, forKey: .feedID))
    }
}

public enum TileFeedAngles {
    public static func usingFeeds(in project: CutProject, document: URL, sourceID: String,
                                  feedIDs: [String] = [], clipID: String? = nil, useSidecar: Bool = true,
                                  cancelled: (@Sendable () -> Bool)? = nil) throws -> MulticamProject {
        try project.validate()
        guard let geometry = project.participants.sources.first(where: { $0.sourceID == sourceID }) else {
            throw invalid("Choose a recording with accepted tiles.")
        }
        let visible = Set(geometry.appearances.compactMap(\.participantID))
        let unavailable = Set(project.participants.effectiveRedactions.filter {
            $0.treatment == .opaque || $0.treatment == .omit
        }.map(\.participantID))
        let eligible = project.participants.people.filter { visible.contains($0.id) && !unavailable.contains($0.id) }
        let requested = Set(feedIDs)
        let selected = requested.isEmpty ? eligible : eligible.filter { requested.contains($0.id) }
        guard !selected.isEmpty, requested.count == feedIDs.count,
              requested.isEmpty || requested.count == selected.count else {
            throw invalid("Select unique feeds with tiles in this recording that are available as angles.")
        }
        var group: MulticamProject
        let parentID: String
        switch project {
        case .multicam(let current):
            guard clipID == nil else { throw invalid("Choose the recording by source ID in a multicam project.") }
            group = current
            parentID = sourceID
        case .sequence, .stillSequence:
            if let clipID, project.sequenceClips?.contains(where: { $0.id == clipID && $0.file == sourceID }) != true {
                throw invalid("The selected clip does not use this recording.")
            }
            let conversion = try sequenceGroup(project, document: document, useSidecar: useSidecar, cancelled: cancelled)
            group = conversion.group
            guard let id = conversion.recordingIDs[sourceID] else {
                throw invalid("The recording is not in the sequence.")
            }
            parentID = id
        }
        guard let parent = group.pictureSources.first(where: { $0.id == parentID && $0.feedAngle == nil }) else {
            throw invalid("Choose a physical camera recording.")
        }

        var used = Set(group.sources.map(\.id))
        for feed in selected {
            let reference = TileFeedAngle(sourceID: parent.id, feedID: feed.id)
            guard !group.angles.contains(where: { $0.feedAngle == reference }) else { continue }
            let base = "feed-\(feed.id)"
            var id = base
            var suffix = 1
            while !used.insert(id).inserted {
                suffix += 1
                id = "\(base)-\(suffix)"
            }
            group.angles.append(.init(id: id, file: parent.file, offset: parent.offset, name: feed.name,
                                      coverage: parent.coverage, feedAngle: reference))
        }
        try convertSoloLayouts(in: &group, parent: parent)
        try group.validate()
        return group
    }

    private struct SequenceRecording {
        let source: MulticamSource
        let media: MediaInfo
        let start: RationalTime
        let selectedStreams: [Int]
    }

    private static func sequenceGroup(_ project: CutProject, document: URL, useSidecar: Bool,
                                      cancelled: (@Sendable () -> Bool)?) throws
        -> (group: MulticamProject, recordingIDs: [String: String]) {
        guard let items = project.sequenceItems else { throw invalid("Choose a sequence.") }
        if let sequence = project.stillSequenceValue,
           sequence.stillSoundtrack != nil || sequence.stillAudioReference != nil || !sequence.sourceSelects.isEmpty {
            throw invalid("Converting a sequence with a still soundtrack or saved source selections is unavailable.")
        }
        let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
        var recordings: [String: SequenceRecording] = [:]
        var angles: [MulticamSource] = []
        var switches: [MulticamSwitch] = []
        var assembly: [StillAssemblyItem] = []
        var clipRanges: [String: (offset: RationalTime, range: MulticamRange)] = [:]
        var end = RationalTime.zero
        func streams(in media: MediaInfo, for clip: CutSequenceClip) throws -> [Int] {
            let tracks = media.streams.lazy.filter { $0.kind == "audio" }.map(\.index)
            let available = Array(tracks)
            guard let ordinal = clip.audioTrack else { return available }
            guard available.indices.contains(ordinal) else { throw invalid("A clip names a missing audio track.") }
            return [available[ordinal]]
        }

        for item in items {
            try engine.checkCancellation()
            guard let clip = item.source else {
                if let still = item.still { assembly.append(.still(still)) }
                continue
            }
            let recording: SequenceRecording
            if let previous = recordings[clip.file] {
                recording = previous
            } else {
                let file = try CutProject.checkedMediaURL(clip.file, relativeTo: document)
                let media = try engine.inspect(file, keyframes: true)
                guard let last = media.frames.last else { throw invalid("Each sequence recording must have editable picture.") }
                let start = end
                end = try start.adding(last.time.adding(last.duration))
                let id = "recording-\(angles.count + 1)"
                let selectedStreams = try streams(in: media, for: clip)
                let source = MulticamSource(id: id, file: clip.file, offset: try start.subtracting(media.multicamSourceOffset),
                                            name: file.deletingPathExtension().lastPathComponent, audioStream: selectedStreams.first,
                                            coverage: .init(from: start, to: end))
                recording = .init(source: source, media: media, start: start, selectedStreams: selectedStreams)
                recordings[clip.file] = recording
                angles.append(source)
                switches.append(.init(at: start, angle: id))
            }
            guard try streams(in: recording.media, for: clip) == recording.selectedStreams,
                  clip.originalFile == nil, clip.replacementNames.isEmpty else {
                throw invalid("Converting a clip with a different audio track, replacement recording or custom replacement track names is unavailable.")
            }
            let range = try shifted(.init(from: clip.from, to: clip.to), by: recording.start)
            guard let coverage = recording.source.coverage, range.to <= coverage.to else {
                throw invalid("A clip extends past its recording.")
            }
            clipRanges[clip.id] = (recording.start, range)
            let layouts = try clip.tileLayouts.map { span in
                var moved = span
                moved.range = try shifted(span.range, by: recording.start)
                return moved
            }
            assembly.append(.group(range, id: clip.id, layouts: layouts))
        }
        guard let first = angles.first else { throw invalid("The sequence has no picture recordings.") }

        let byMediaURL = Dictionary(grouping: recordings.values) { $0.media.url.resolvingSymlinksInPath() }
        func recording(for file: String) -> SequenceRecording? {
            if let authored = recordings[file] { return authored }
            guard let url = try? CutProject.checkedMediaURL(file, relativeTo: document).resolvingSymlinksInPath(),
                  let candidates = byMediaURL[url], candidates.count == 1 else { return nil }
            return candidates.first
        }

        let participants = project.participants.mapSourcePaths { recording(for: $0)?.source.id ?? $0 }
        func mapBinding(_ original: TranscriptBinding) throws -> TranscriptBinding {
            guard let file = original.file else { return original }
            guard let recording = recording(for: file) else {
                throw invalid("A transcript attachment must identify one recording in the sequence.")
            }
            var binding = original
            binding.sourceID = recording.source.id
            binding.file = nil
            return binding
        }
        func mapAnchor(_ original: TranscriptAnchor) throws -> TranscriptAnchor {
            var anchor = original
            anchor.binding = try mapBinding(original.binding)
            return anchor
        }

        var transcripts = project.transcripts
        for index in transcripts.attachments.indices {
            transcripts.attachments[index].bindings = try transcripts.attachments[index].bindings.map(mapBinding)
        }
        transcripts.authoring = try transcripts.authoring.map { record in
            try .init(id: record.id, attachmentID: record.attachmentID, change: record.change,
                      anchors: record.anchors.map(mapAnchor), speakerReference: record.speakerReference.map(mapAnchor))
        }
        let replacements = try project.stillReplacements.flatMap { replacement -> [StillReplacement] in
            guard case .sequence(let fragments) = replacement.coverage else { return [] }
            return try fragments.enumerated().map { index, fragment in
                guard let clip = clipRanges[fragment.clipID] else { throw invalid("A still refers to a missing clip.") }
                let range = try shifted(fragment.range, by: clip.offset)
                guard !clipRanges.contains(where: { id, other in
                    id != fragment.clipID && other.range.from < range.to && range.from < other.range.to
                }) else { throw invalid("Converting repeated footage with an occurrence-specific still replacement is unavailable.") }
                return .init(id: index == 0 ? replacement.id : ProjectIdentifier.make(), assetID: replacement.assetID,
                             framing: replacement.framing, coverage: .group(range))
            }
        }

        for index in assembly.indices {
            guard let range = assembly[index].group else { continue }
            let layouts = assembly[index].tileLayouts.map { original in
                var span = original
                for i in span.slots.indices where span.slots[i].target == .camera {
                    let path = span.slots[i].id
                    span.slots[i].id = recording(for: path)?.source.id ?? path
                }
                return span
            }
            assembly[index] = .group(range, id: assembly[index].occurrenceID, layouts: layouts)
        }

        let recordedAudio = angles.flatMap { angle in
            (recordings[angle.file]?.selectedStreams ?? []).map { stream in
                (angle, stream)
            }
        }
        let audibleRecordings = recordings.values.filter { !$0.selectedStreams.isEmpty }
        let multipleTracks = audibleRecordings.contains { $0.selectedStreams.count > 1 }
        guard !multipleTracks || audibleRecordings.count == 1 else {
            // Sequence tracks continue by ordinal across clip boundaries. A
            // recording-targeted Mix lane would put later clips on new tracks.
            throw invalid("This sequence continues multiple audio tracks across recordings. Converting it to feed angles would change those tracks.")
        }
        let needsMix = audibleRecordings.count == 1 && (multipleTracks || recordings.count > 1)
        let lanes: [MulticamAudioLane] = needsMix ? recordedAudio.enumerated().map { index, entry in
            let (angle, stream) = entry
            return .init(id: "\(angle.id)-audio-\(stream)", target: .recording(.init(source: angle.id, stream: stream)),
                         label: "\(angle.name ?? angle.id) · Stream \(stream)",
                         colorSlot: index % MulticamAudioLane.colorSlotCount)
        } : []
        for recording in recordings.values {
            try engine.verifyIdentity(recording.media.url, identity: recording.media.identity)
        }
        let group = MulticamProject(referenceAngle: first.id, range: .init(from: .zero, to: end), angles: angles,
                                    audio: lanes.isEmpty ? (recordedAudio.isEmpty ? .none : .follow) : .mix,
                                    switches: switches, assemblyItems: assembly, stillAssets: project.stillAssets,
                                    stillReplacements: replacements, programColorPolicy: project.programColorPolicy,
                                    transcripts: transcripts, mixLanes: lanes, participants: participants)
        return (group, recordings.mapValues { $0.source.id })
    }

    private static func convertSoloLayouts(in project: inout MulticamProject, parent: MulticamSource) throws {
        let feedIDs = Dictionary(uniqueKeysWithValues: project.angles.compactMap { angle in
            angle.feedAngle.flatMap { $0.sourceID == parent.id ? ($0.feedID, angle.id) : nil }
        })
        func soloAngle(_ span: TileLayoutSpan) -> String? {
            guard span.layout == .solo, span.slots.count == 1, let slot = span.slots.first,
                  slot == ParticipantSlot(id: slot.id), !span.compact else { return nil }
            return feedIDs[slot.id]
        }
        let original = project
        let microphones = original.audio == .follow ? TileFeedAttachments.followAudioRoutes(in: original) : [:]
        func previousFollowAudio(at time: RationalTime) throws -> MulticamAudioSelection? {
            guard original.audio == .follow, let marker = original.selection(at: time),
                  let recording = original.pictureSource(for: marker.angle, at: time) else { return nil }
            if let feed = recording.feedAngle, let mic = microphones[feed] { return try mic.get() }
            return parent.audioStream.map { .init(source: parent.id, stream: $0) }
        }
        func preservesSilence(at time: RationalTime, switchingTo feedID: String) throws -> Bool {
            guard original.audio == .follow, original.selection(at: time)?.audio == nil,
                  microphones[.init(sourceID: parent.id, feedID: feedID)] != nil else { return true }
            return try previousFollowAudio(at: time) != nil
        }
        func selectedParent(at time: RationalTime, override: String? = nil) -> Bool {
            guard let angle = override ?? original.selection(at: time)?.angle,
                  let recording = original.pictureSource(for: angle, at: time) else { return false }
            return (recording.feedAngle?.sourceID ?? recording.id) == parent.id
        }
        func boundaries(in range: MulticamRange, override: String? = nil) -> Set<RationalTime> {
            var points: Set<RationalTime> = [range.from, range.to]
            if override == nil {
                points.formUnion(original.switches.lazy.map(\.at).filter { range.from < $0 && $0 < range.to })
            }
            if let coverage = parent.coverage {
                points.formUnion([coverage.from, coverage.to].filter { range.from < $0 && $0 < range.to })
            }
            return points
        }

        var overlays: [(range: MulticamRange, angle: String)] = []
        var groupLayouts: [TileLayoutSpan] = []
        for layout in original.groupTileLayouts {
            let conflictingOccurrence = original.assemblyItems?.contains { item in
                guard let overlap = item.group?.participantIntersection(layout.range) else { return false }
                return item.angleOverride != nil || item.tileLayouts.contains { $0.range.participantIntersection(overlap) != nil }
            } ?? false
            guard !conflictingOccurrence, let angle = soloAngle(layout) else {
                groupLayouts.append(layout)
                continue
            }
            let points = boundaries(in: layout.range).sorted()
            for (from, to) in zip(points, points.dropFirst()) {
                let range = MulticamRange(from: from, to: to)
                if selectedParent(at: from), try preservesSilence(at: from, switchingTo: layout.slots[0].id) {
                    overlays.append((range, angle))
                } else {
                    var residual = layout
                    residual.range = range
                    groupLayouts.append(residual)
                }
            }
        }

        if let items = original.assemblyItems {
            var usedIDs = Set(items.compactMap(\.occurrenceID))
            project.assemblyItems = try items.enumerated().flatMap { index, item -> [StillAssemblyItem] in
                guard let range = item.group, item.tileLayouts.contains(where: { soloAngle($0) != nil }) else { return [item] }
                var points = boundaries(in: range, override: item.angleOverride)
                for layout in item.tileLayouts where soloAngle(layout) != nil {
                    points.formUnion([layout.range.from, layout.range.to].filter { range.from < $0 && $0 < range.to })
                }
                let ordered = points.sorted()
                var pieces: [(range: MulticamRange, angle: String?)] = []
                var layouts = item.tileLayouts
                for (from, to) in zip(ordered, ordered.dropFirst()) {
                    let segment = MulticamRange(from: from, to: to)
                    var override = item.angleOverride
                    if selectedParent(at: from, override: override),
                       let indexOfLayout = layouts.firstIndex(where: { $0.range.contains(from) }),
                       let angle = soloAngle(layouts[indexOfLayout]) {
                        let layout = layouts[indexOfLayout]
                        let repeats = items.enumerated().contains { otherIndex, other in
                            otherIndex != index && other.group.map { $0.from < to && from < $0.to } == true
                        }
                        let conflictsWithGroupLayout = original.groupTileLayouts.contains { $0.range.from < to && from < $0.range.to }
                        let suppressGroup: TileLayoutSpan? = conflictsWithGroupLayout ? .init(range: segment, layout: .original) : nil
                        layouts.replaceSubrange(indexOfLayout...indexOfLayout, with: [
                            layout.limited(from: nil, to: from), suppressGroup, layout.limited(from: to, to: nil)
                        ].compactMap { $0 })
                        if try repeats || override != nil || conflictsWithGroupLayout
                            || !preservesSilence(at: from, switchingTo: layout.slots[0].id) {
                            override = angle
                        } else {
                            overlays.append((segment, angle))
                        }
                    }
                    if let last = pieces.indices.last, pieces[last].angle == override {
                        pieces[last].range.to = to
                    } else {
                        pieces.append((segment, override))
                    }
                }
                // A group switch needs no assembly cut. Only split the occurrence
                // when its local override changes, partitioning its trim handles.
                return pieces.enumerated().map { part, piece in
                    var id = item.occurrenceID
                    if part > 0 {
                        var generated = "\(item.occurrenceID ?? "occurrence-\(index + 1)")-part-\(part + 1)"
                        while !usedIDs.insert(generated).inserted { generated += "-" }
                        id = generated
                    }
                    let local = layouts.compactMap {
                        $0.limited(from: part == 0 ? nil : piece.range.from,
                                   to: part + 1 == pieces.count ? nil : piece.range.to)
                    }
                    return .group(piece.range, angle: piece.angle, id: id, layouts: local)
                }
            }
        }

        var markers = Dictionary(uniqueKeysWithValues: original.switches.map { ($0.at, $0) })
        for overlay in overlays {
            if let restore = original.selection(at: overlay.range.to), markers[overlay.range.to] == nil {
                markers[overlay.range.to] = .init(at: overlay.range.to, angle: restore.angle, audio: restore.audio)
            }
        }
        for overlay in overlays {
            let start = overlay.range.from
            let previous = original.selection(at: start)
            markers[start] = try .init(at: start, angle: overlay.angle, audio: previous?.audio ?? previousFollowAudio(at: start))
        }
        project.switches = markers.values.sorted { $0.at < $1.at }
        project.groupTileLayouts = groupLayouts
    }

    private static func shifted(_ range: MulticamRange, by offset: RationalTime) throws -> MulticamRange {
        try .init(from: range.from.adding(offset), to: range.to.adding(offset))
    }

    private static func invalid(_ message: String) -> CutError {
        .init(code: "invalid_tile_feed_angle", message: message)
    }
}
