import Foundation

/// A project feed owns its manual microphone and voice attachments. Names are only
/// used to find unique matches for attachments that the editor has not supplied.
public enum TileFeedAttachments {
    static func nameKey(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func microphone(for feed: ParticipantPerson, in project: MulticamProject) -> MulticamAudioSelection? {
        microphones(in: project)[feed.id]
    }

    /// Program audio follows a synced replacement through its original recording.
    /// Its standalone source offset describes a different placement.
    static func followAudioRoutes(in project: MulticamProject) -> [TileFeedAngle: Result<MulticamAudioSelection, CutError>] {
        let microphones = microphones(in: project)
        let placements = Dictionary(grouping: project.audioReplacements, by: \.replacement)
        var routes: [TileFeedAngle: Result<MulticamAudioSelection, CutError>] = [:]
        for angle in project.angles {
            guard let feed = angle.feedAngle, let mic = microphones[feed.feedID] else { continue }
            guard let candidates = placements[mic] else {
                routes[feed] = .success(mic)
                continue
            }
            let matches = candidates.count == 1 ? candidates : candidates.filter { $0.original.source == feed.sourceID }
            if matches.count == 1 {
                routes[feed] = .success(matches[0].original)
            } else {
                routes[feed] = .failure(.init(code: "ambiguous_feed_microphone",
                    message: "The microphone on feed ‘\(feed.feedID)’ has multiple sync placements. Choose its recording lane."))
            }
        }
        return routes
    }

    public static func voices(in project: MulticamProject, indexes: [TranscriptIndex]) -> [ParticipantSpeakerBinding: String] {
        voiceMatches(in: project, indexes: indexes).feeds
    }

    static func voiceMatches(in project: MulticamProject, indexes: [TranscriptIndex])
        -> (feeds: [ParticipantSpeakerBinding: String], ambiguous: Set<ParticipantSpeakerBinding>) {
        let people = project.participants.people
        let byName = Dictionary(grouping: people) { nameKey($0.name) }
        let microphones = microphones(in: project)
        var matches = Dictionary(uniqueKeysWithValues: people.flatMap { feed in
            feed.speakers.map { ($0, feed.id) }
        })
        var ambiguous = Set<ParticipantSpeakerBinding>()
        for index in indexes {
            guard let attachmentID = index.attachment?.id else { continue }
            let evidence = voiceEvidence(in: index, microphones: microphones)
            let speakersByName = Dictionary(grouping: index.speakers) { nameKey($0.name) }
            for speaker in index.speakers {
                let voice = ParticipantSpeakerBinding(attachmentID: attachmentID, speakerID: speaker.id)
                guard matches[voice] == nil else { continue }
                if let feeds = evidence[speaker.id] {
                    if feeds.count == 1 { matches[voice] = feeds.first }
                    else { ambiguous.insert(voice) }
                    continue
                }
                let key = nameKey(speaker.name)
                guard !key.isEmpty else { continue }
                if speakersByName[key]?.count != 1 {
                    ambiguous.insert(voice)
                } else if let feeds = byName[key] {
                    if feeds.count == 1 { matches[voice] = feeds[0].id }
                    else { ambiguous.insert(voice) }
                }
            }
        }
        return (matches, ambiguous)
    }

    static func microphones(in project: MulticamProject) -> [String: MulticamAudioSelection] {
        func selection(for target: MulticamAudioLaneTarget) -> MulticamAudioSelection? {
            switch target {
            case .recording(let recording): return recording
            case .camera(let id):
                let cameras = project.recordings(for: id)
                guard cameras.count == 1, let camera = cameras.first, camera.feedAngle == nil,
                      let stream = camera.audioStream else { return nil }
                return .init(source: camera.id, stream: stream)
            }
        }
        let people = project.participants.people
        let byName = Dictionary(grouping: people) { nameKey($0.name) }
        let explicit = people.compactMap { feed -> (String, MulticamAudioSelection)? in
            guard let binding = feed.audio else { return nil }
            if let direct = binding.selection { return (feed.id, direct) }
            guard let lane = project.mixLanes.first(where: { $0.id == binding.laneID }),
                  let microphone = selection(for: lane.target) else { return nil }
            return (feed.id, microphone)
        }
        var result = Dictionary(uniqueKeysWithValues: explicit)
        let claimed = Set(result.values)
        var named: [String: Set<MulticamAudioSelection>] = [:]
        for lane in project.mixLanes {
            if case .recording(let stream) = lane.target {
                named[nameKey(lane.label), default: []].insert(stream)
            }
        }
        for source in project.audioSources {
            guard let name = source.name, let stream = source.audioStream else { continue }
            named[nameKey(name), default: []].insert(.init(source: source.id, stream: stream))
        }
        var inferred: [MulticamAudioSelection: [String]] = [:]
        for feed in people where feed.audio == nil {
            let key = nameKey(feed.name)
            guard !key.isEmpty, byName[key]?.count == 1, let choices = named[key],
                  choices.count == 1, let stream = choices.first, !claimed.contains(stream) else { continue }
            inferred[stream, default: []].append(feed.id)
        }
        for (stream, feeds) in inferred where feeds.count == 1 {
            result[feeds[0]] = stream
        }
        return result
    }

    /// Resolve attachment-scoped voices against the physical tracks that carry
    /// their recognized speech. A mixed or ambiguous track cannot identify a feed.
    private static func voiceEvidence(in index: TranscriptIndex, microphones: [String: MulticamAudioSelection])
        -> [String: Set<String>] {
        guard let attachment = index.attachment, !microphones.isEmpty else { return [:] }
        let feedsByMicrophone = Dictionary(grouping: microphones, by: \.value).mapValues { $0.map(\.key) }
        let tracks = Dictionary(uniqueKeysWithValues: index.document.tracks.map { ($0.id, $0) })
        var feedsByTrack: [String: [String]] = [:]
        for binding in attachment.bindings {
            guard let source = binding.sourceID, let track = tracks[binding.trackID], track.role != .mixedAudio,
                  let feeds = feedsByMicrophone[.init(source: source, stream: binding.streamIndex)] else { continue }
            feedsByTrack[binding.trackID] = feeds
        }
        guard !feedsByTrack.isEmpty else { return [:] }
        var evidence: [String: Set<String>] = [:]
        for word in index.document.words {
            for observation in word.observations where observation.evidence == .recognized {
                guard let speaker = word.speakerID ?? observation.speakerID,
                      let feeds = feedsByTrack[observation.trackID] else { continue }
                evidence[speaker, default: []].formUnion(feeds)
            }
        }
        if feedsByTrack.keys.contains(where: { tracks[$0]?.words?.isEmpty == false }) {
            // The source index also knows scoped speaker IDs for track-local words.
            for word in index.readAll(space: .source) {
                guard let speaker = word.speakerID, let trackID = word.trackID,
                      word.audibility != .inferred, let feeds = feedsByTrack[trackID] else { continue }
                evidence[speaker, default: []].formUnion(feeds)
            }
        }
        return evidence
    }
}
