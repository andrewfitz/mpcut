import Foundation

public struct TileSpeakerAngle: Codable, Hashable, Sendable {
    public var voice: ParticipantSpeakerBinding
    public var angleID: String

    public init(voice: ParticipantSpeakerBinding, angleID: String) {
        self.voice = voice
        self.angleID = angleID
    }

    private enum CodingKeys: String, CodingKey {
        case voice
        case angleID = "angle_id"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_tile_switch")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(voice: try values.decode(ParticipantSpeakerBinding.self, forKey: .voice),
                  angleID: try values.decode(String.self, forKey: .angleID))
    }
}

public struct TileSwitchProposal: Codable, Equatable, Identifiable, Sendable {
    public let at: RationalTime
    public let angleID: String
    public let voice: ParticipantSpeakerBinding
    public let projectRevision: String
    public var id: String { "\(at):\(angleID)" }

    private enum CodingKeys: String, CodingKey {
        case at, voice
        case angleID = "angle_id"
        case projectRevision = "project_revision"
    }
}

public enum TileSwitches {
    private static func overlap(_ a: MulticamRange, _ b: MulticamRange) -> MulticamRange? {
        let from = max(a.from, b.from)
        let to = min(a.to, b.to)
        return from < to ? .init(from: from, to: to) : nil
    }

    public static func revision(of project: MulticamProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return TranscriptStore.digest(try encoder.encode(project))
    }

    public static func links(in project: MulticamProject, indexes: [TranscriptIndex]) -> [TileSpeakerAngle] {
        let hidden = Set(project.participants.effectiveRedactions.filter {
            $0.treatment == .opaque || $0.treatment == .omit
        }.map(\.participantID))
        let angles = project.angles.filter { angle in
            angle.feedAngle.map { !hidden.contains($0.feedID) } ?? true
        }
        let angleIDs = Set(angles.map(\.id))
        let explicitlyLinked = Dictionary(project.speakerAngles.map { ($0.voice, $0.angleID) },
                                          uniquingKeysWith: { first, _ in first })
        let anglesByFeed = Dictionary(grouping: angles.compactMap { angle in
            angle.feedAngle.map { (feed: $0.feedID, id: angle.id) }
        }, by: \.feed)
        let physicalAnglesByName = Dictionary(grouping: angles.filter { $0.feedAngle == nil }) {
            TileFeedAttachments.nameKey($0.name ?? $0.id)
        }
        let hasFeedAngles = project.angles.contains { $0.feedAngle != nil }
        let assignments = TileFeedAttachments.voiceMatches(in: project, indexes: indexes)
        var seen = Set<ParticipantSpeakerBinding>()
        var links: [TileSpeakerAngle] = []
        for index in indexes {
            guard let attachmentID = index.attachment?.id else { continue }
            for speaker in index.speakers {
                let voice = ParticipantSpeakerBinding(attachmentID: attachmentID, speakerID: speaker.id)
                guard seen.insert(voice).inserted else { continue }
                if let angle = explicitlyLinked[voice] {
                    if angleIDs.contains(angle) { links.append(.init(voice: voice, angleID: angle)) }
                } else if hasFeedAngles, let feed = assignments.feeds[voice] {
                    if let matches = anglesByFeed[feed], matches.count == 1 {
                        links.append(.init(voice: voice, angleID: matches[0].id))
                    }
                } else if !assignments.ambiguous.contains(voice) {
                    let key = TileFeedAttachments.nameKey(speaker.name)
                    if !key.isEmpty, let matches = physicalAnglesByName[key], matches.count == 1 {
                        links.append(.init(voice: voice, angleID: matches[0].id))
                    }
                }
            }
        }
        return links
    }

    public static func applyingVoiceOverrides(_ mappings: [String], in project: MulticamProject,
                                              indexes: [TranscriptIndex]) throws -> MulticamProject {
        guard !mappings.isEmpty else { return project }
        guard indexes.count == 1, let index = indexes.first, let attachment = index.attachment?.id else {
            throw CutError(code: "invalid_arguments", message: "Choose one transcript when supplying voice-to-angle overrides.")
        }
        let voices = Set(index.speakers.map(\.id))
        let angles = Set(project.angles.map(\.id))
        var assigned = Set<String>()
        var linked = project
        for mapping in mappings {
            let fields = mapping.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2, voices.contains(fields[0]), angles.contains(fields[1]),
                  assigned.insert(fields[0]).inserted else {
                throw CutError(code: "invalid_arguments", message: "Supply one SPEAKER_ID=ANGLE_ID per voice using existing IDs.")
            }
            let voice = ParticipantSpeakerBinding(attachmentID: attachment, speakerID: fields[0])
            linked.speakerAngles.removeAll { $0.voice == voice }
            linked.speakerAngles.append(.init(voice: voice, angleID: fields[1]))
        }
        return linked
    }

    public static func propose(in project: MulticamProject, document: URL, indexes: [TranscriptIndex],
                               minimumHold: RationalTime = .init(numerator: 1), revision: String? = nil,
                               useSidecar: Bool = true,
                               cancelled: (@Sendable () -> Bool)? = nil) throws -> [TileSwitchProposal] {
        guard minimumHold > .zero else {
            throw CutError(code: "invalid_tile_switch", message: "Enter a positive minimum hold.")
        }
        let currentRevision = try revision ?? Self.revision(of: project)
        let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
        let check = engine.checkCancellation
        let bindings = Dictionary(uniqueKeysWithValues: links(in: project, indexes: indexes).map { ($0.voice, $0.angleID) })
        let assembly = merged(project.assemblyItems?.compactMap { item in
            item.angleOverride == nil ? item.group : nil
        } ?? [project.range])
        let sources = Dictionary(uniqueKeysWithValues: project.pictureSources.map { ($0.id, $0) })
        var origins: [String: RationalTime] = [:]
        var unavailable = Set<String>()
        func origin(of parent: MulticamSource, geometry: ParticipantSourceGeometry) throws -> RationalTime? {
            if unavailable.contains(parent.id) { return nil }
            if let cached = origins[parent.id] { return cached }
            guard let file = try? CutProject.checkedMediaURL(parent.file, relativeTo: document),
                  geometry.sourceStamp == nil || !project.participants.needsReconciliation(sourceID: parent.id, mediaURL: file) else {
                unavailable.insert(parent.id)
                return nil
            }
            if let indexed = indexes.lazy.compactMap({ $0.multicamClockOffsets[parent.id] }).first {
                origins[parent.id] = indexed
                return indexed
            }
            guard let media = try? engine.inspectSummary(file), media.hasVideo else {
                try check()
                unavailable.insert(parent.id)
                return nil
            }
            origins[parent.id] = media.multicamSourceOffset
            return media.multicamSourceOffset
        }
        var angleCoverage: [String: [MulticamRange]] = [:]
        let requestedAngles = Set(bindings.values)
        for angle in project.angles where requestedAngles.contains(angle.id) {
            try check()
            let picture: [MulticamRange]
            if let feed = angle.feedAngle, let parent = sources[feed.sourceID],
               let geometry = project.participants.sources.first(where: { $0.sourceID == parent.id }),
               let sourceOrigin = try origin(of: parent, geometry: geometry) {
                let parentRange = parent.coverage ?? project.range
                let offset = try parent.offset.adding(sourceOrigin)
                let preferences = project.participants.appearanceOverrides.filter {
                    $0.sourceID == parent.id && $0.participantID == feed.feedID
                }.sorted { $0.range.from < $1.range.from }
                picture = try geometry.appearances.flatMap { appearance -> [MulticamRange] in
                    guard appearance.participantID == feed.feedID, appearance.state == .video else { return [] }
                    return try visibleRanges(of: appearance, preferences: preferences).compactMap { range in
                        let visible = try MulticamRange(from: range.from.adding(offset), to: range.to.adding(offset))
                        return overlap(visible, parentRange)
                    }
                }
            } else if angle.feedAngle == nil {
                picture = angle.recordings.map { $0.coverage ?? project.range }
            } else {
                picture = []
            }
            angleCoverage[angle.id] = intersections(merged(picture), assembly)
        }
        var words: [String: [SpokenRange]] = [:]
        for index in indexes {
            try check()
            for word in index.readAll(space: .group) {
                guard let attachmentID = word.attachmentID ?? index.attachment?.id, let speakerID = word.speakerID else { continue }
                let voice = ParticipantSpeakerBinding(attachmentID: attachmentID, speakerID: speakerID)
                guard let angle = bindings[voice], word.range.from < word.range.to else { continue }
                words[angle, default: []].append(.init(range: word.range, voice: voice))
            }
        }
        return try proposals(words: words, coverage: angleCoverage, in: project, minimumHold: minimumHold,
                             revision: currentRevision, check: check)
    }

    private static func visibleRanges(of appearance: ParticipantAppearance,
                                      preferences: [ParticipantAppearanceOverride]) -> [MulticamRange] {
        let range = appearance.range
        let first = preferences.lowerBound { $0.range.to > range.from }
        var start = range.from
        var visible: [MulticamRange] = []
        for preference in preferences[first...] {
            if preference.range.from >= range.to { break }
            guard preference.appearanceID != appearance.id else { continue }
            if start < preference.range.from { visible.append(.init(from: start, to: preference.range.from)) }
            start = max(start, preference.range.to)
        }
        if start < range.to { visible.append(.init(from: start, to: range.to)) }
        return visible
    }

    private static func merged(_ ranges: [MulticamRange]) -> [MulticamRange] {
        var result: [MulticamRange] = []
        for range in ranges.sorted(by: { $0.from < $1.from }) {
            if let last = result.indices.last, range.from <= result[last].to {
                result[last].to = max(result[last].to, range.to)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func intersections(_ first: [MulticamRange], _ second: [MulticamRange]) -> [MulticamRange] {
        var a = first.startIndex
        var b = second.startIndex
        var result: [MulticamRange] = []
        while a < first.endIndex, b < second.endIndex {
            if let range = overlap(first[a], second[b]) { result.append(range) }
            if first[a].to < second[b].to { a += 1 }
            else { b += 1 }
        }
        return result
    }

    private struct SpokenRange {
        var range: MulticamRange
        let voice: ParticipantSpeakerBinding
    }

    private struct Event {
        let time: RationalTime
        let angle: String
        let voice: ParticipantSpeakerBinding
        let starts: Bool
    }

    private static func proposals(words: [String: [SpokenRange]], coverage: [String: [MulticamRange]], in project: MulticamProject,
                                  minimumHold: RationalTime, revision: String,
                                  check: () throws -> Void) throws -> [TileSwitchProposal] {
        let pause = RationalTime(numerator: 1, denominator: 4)
        var events: [Event] = []
        for (angle, ranges) in words {
            try check()
            guard let windows = coverage[angle], !windows.isEmpty else { continue }
            var turns: [SpokenRange] = []
            for speech in ranges.sorted(by: {
                if $0.range.from != $1.range.from { return $0.range.from < $1.range.from }
                return ($0.voice.attachmentID, $0.voice.speakerID) < ($1.voice.attachmentID, $1.voice.speakerID)
            }) {
                if let last = turns.indices.last, speech.range.from <= (try turns[last].range.to.adding(pause)) {
                    turns[last].range.to = max(turns[last].range.to, speech.range.to)
                } else {
                    turns.append(speech)
                }
            }
            var window = windows.startIndex
            for turn in turns {
                while window < windows.endIndex, windows[window].to <= turn.range.from { window += 1 }
                while window < windows.endIndex, let range = overlap(turn.range, windows[window]) {
                    events.append(.init(time: range.from, angle: angle, voice: turn.voice, starts: true))
                    events.append(.init(time: range.to, angle: angle, voice: turn.voice, starts: false))
                    if windows[window].to > turn.range.to { break }
                    window += 1
                }
            }
        }
        events.sort { $0.time < $1.time }
        var active: [String: ParticipantSpeakerBinding] = [:]
        var result: [TileSwitchProposal] = []
        var cursor = events.startIndex
        while cursor < events.endIndex {
            try check()
            let start = events[cursor].time
            repeat {
                let event = events[cursor]
                active[event.angle] = event.starts ? event.voice : nil
                cursor += 1
            } while cursor < events.endIndex && events[cursor].time == start
            guard cursor < events.endIndex, active.count == 1, let (angle, voice) = active.first,
                  try events[cursor].time.subtracting(start) >= minimumHold else { continue }
            let existing = project.selection(at: start)
            let current = result.last.flatMap { last in
                existing.map { $0.at <= last.at } == true ? last.angleID : nil
            } ?? existing?.angle
            guard current != angle, project.pictureSource(for: angle, at: start) != nil else { continue }
            result.append(.init(at: start, angleID: angle, voice: voice, projectRevision: revision))
        }
        return result
    }

    public static func accepting(_ proposal: TileSwitchProposal, in project: MulticamProject,
                                 revision: String? = nil) throws -> MulticamProject {
        if let revision {
            guard revision == proposal.projectRevision else { throw stale() }
        } else {
            try verifyRevision(proposal.projectRevision, in: project)
        }
        return try project.settingSwitch(at: proposal.at, angle: proposal.angleID)
    }

    public static func verifyRevision(_ expected: String?, in project: MulticamProject) throws {
        if let expected, expected != (try revision(of: project)) { throw stale() }
    }

    package static func stale() -> CutError {
        .init(code: "stale_tile_switch", message: "The project changed. Propose switches again.")
    }
}

extension MulticamProject {
    public func settingSwitch(at time: RationalTime, angle: String) throws -> Self {
        let proposal = try proposedSwitch(at: time, angle: angle)
        var updated = self
        let index = switches.lowerBound { $0.at >= time }
        if switches.indices.contains(index), switches[index].at == time {
            updated.switches[index] = proposal.marker
        } else {
            updated.switches.insert(proposal.marker, at: index)
        }
        try updated.validate()
        return updated
    }
}
