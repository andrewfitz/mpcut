import CryptoKit
import Darwin
import Foundation

public enum TranscriptJobPolicy: String, Codable, Sendable {
    case reuse, resume, restart
}

public enum TranscriptJobState: String, Codable, Sendable {
    case preparing, prepared, running, completed, partial, failed, cancelled, interrupted, stale

    fileprivate var permitsOutputVerification: Bool {
        [.prepared, .completed, .partial].contains(self)
    }
}

public enum TranscriptJobTrackState: String, Codable, Sendable {
    case pending, staged, cached, recognized, skipped, failed
    case coverageOnly = "coverage_only"
}

public struct TranscriptJobTrackOptions: Codable, Equatable, Sendable {
    public var channel: Int?
    public var role: String
    public var speaker: String?

    public init(channel: Int? = nil, role: String = "unknown", speaker: String? = nil) {
        self.channel = channel
        self.role = role
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey { case channel, role, speaker }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_track")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(channel: try values.decodeIfPresent(Int.self, forKey: .channel),
                  role: try values.decodeIfPresent(String.self, forKey: .role) ?? "unknown",
                  speaker: try values.decodeIfPresent(String.self, forKey: .speaker))
    }
}

public struct TranscriptJobOptions: Codable, Equatable, Sendable {
    public var engine: String?
    public var model: String?
    public var language: String?
    public var expectedSpeakers: Int?
    public var diarization: Bool?
    public var zoomParticipants: [String: [TranscriptZoomParticipant]]?
    public var selectedTracks: [String]?
    public var trackOptions: [String: TranscriptJobTrackOptions]

    public init(engine: String? = nil, model: String? = nil, language: String? = nil,
                expectedSpeakers: Int? = nil, diarization: Bool? = nil, selectedTracks: [String]? = nil,
                trackOptions: [String: TranscriptJobTrackOptions] = [:]) {
        self.engine = engine
        self.model = model
        self.language = language
        self.expectedSpeakers = expectedSpeakers
        self.diarization = diarization
        self.selectedTracks = selectedTracks
        self.trackOptions = trackOptions
    }

    private enum CodingKeys: String, CodingKey {
        case engine
        case model
        case language
        case expectedSpeakers = "expected_speakers"
        case diarization
        case zoomParticipants = "zoom_participants"
        case selectedTracks = "selected_tracks"
        case trackOptions = "track_options"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_options")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(engine: try values.decodeIfPresent(String.self, forKey: .engine),
                  model: try values.decodeIfPresent(String.self, forKey: .model),
                  language: try values.decodeIfPresent(String.self, forKey: .language),
                  expectedSpeakers: try values.decodeIfPresent(Int.self, forKey: .expectedSpeakers),
                  diarization: try values.decodeIfPresent(Bool.self, forKey: .diarization),
                  selectedTracks: try values.decodeIfPresent([String].self, forKey: .selectedTracks),
                  trackOptions: try values.decodeIfPresent([String: TranscriptJobTrackOptions].self, forKey: .trackOptions) ?? [:])
        zoomParticipants = try values.decodeIfPresent([String: [TranscriptZoomParticipant]].self, forKey: .zoomParticipants)
    }
}

public struct TranscriptJobTrack: Codable, Equatable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case file
        case streamIndex = "audio_stream_index"
        case zoomMixTrackID = "zoom_mix_track_id"
        case zoomMixStream = "zoom_mix_stream"
        case sequenceStreamOrdinal = "sequence_stream_ordinal"
        case sequenceClockOrigin = "sequence_clock_origin"
        case projectSourceID = "project_source_id"
        case name
        case origin
        case sessionStart = "session_start"
        case duration
        case channel
        case role
        case speaker
        case recognize
        case evidence
        case hasReusableEvidence = "has_reusable_evidence"
        case sourceStamp = "source_stamp"
        case sourceChangeTime = "source_change_time"
        case state
        case audio
        case stagedAudioSnapshot = "staged_audio_snapshot"
        case result
        case activity
        case recognitionKey = "recognition_key"
        case recognitionSettingsKey = "recognition_settings_key"
        case message
        case unavailable
        case downmixChannel = "downmix_channel"
    }
    public var id: String
    public var sourceID: String
    public var file: URL
    public var streamIndex: Int?
    var zoomMixTrackID: String? = nil
    var zoomMixStream: Int? = nil
    public var sequenceStreamOrdinal: Int?
    public var sequenceClockOrigin: RationalTime
    public var projectSourceID: String?
    public var name: String
    public var origin: RationalTime
    public var sessionStart: RationalTime
    public var duration: RationalTime
    public var channel: Int?
    public var role: String
    public var speaker: String?
    public var recognize: Bool
    public var evidence: String
    public var hasReusableEvidence: Bool
    package var sourceStamp: SourceIdentity?
    package var sourceChangeTime: String?
    public var state: TranscriptJobTrackState
    public var audio: URL?
    var stagedAudioSnapshot: TranscriptExternalCacheDescriptor.Snapshot?
    public var result: URL?
    public var activity: URL?
    public var recognitionKey: String?
    public var recognitionSettingsKey: String?
    public var message: String?
    public var unavailable: String?
    /// The channel staged alone because the stream's channels cancel in a mono mix.
    public var downmixChannel: Int? = nil

    /// The channel the staged audio holds: the chosen one, or the one a cancelling mix fell back to.
    /// Cached recognition and levels are kept under it, as if that channel had been chosen.
    var stagedChannel: Int? { channel ?? downmixChannel }

    func acceptsCoverage(_ coverage: TranscriptCoverage, blocked: Bool = false) -> Bool {
        if unavailable != nil || blocked { return coverage == .failed }
        guard streamIndex != nil else { return coverage == .coverageOnly }
        return coverage == .failed || coverage == (recognize ? .recognized : .skipped)
    }

    public var sourceIsCurrent: Bool {
        guard let live = try? SourceIdentity(file) else {
            return unavailable != nil && sourceStamp == nil
        }
        guard sourceStamp?.matchesSnapshot(live) == true else { return false }
        return sourceChangeTime.map { live.transcriptJobChangeTime == $0 } ?? true
    }

    public var binding: TranscriptBinding? {
        guard let streamIndex else { return nil }
        return TranscriptBinding(trackID: id, sourceID: projectSourceID,
                                 file: projectSourceID == nil ? file.path : nil, streamIndex: streamIndex,
                                 channel: channel,
                                 sequenceClockOrigin: projectSourceID == nil ? sequenceClockOrigin : nil,
                                 sequenceStreamOrdinal: sequenceStreamOrdinal,
                                 sourceFingerprint: unavailable == nil ? sourceStamp?.transcriptFingerprint : nil,
                                 sourceConfirmed: unavailable == nil && sourceStamp != nil)
    }
}

public struct TranscriptJobSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var fingerprint: String
    public var manifest: URL
    public var output: URL
    public var tracks: [TranscriptJobTrack]

    public var bindings: [TranscriptBinding] {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return tracks.compactMap { track in
            guard let mix = track.zoomMixTrackID else { return track.binding }
            var binding = byID[mix]?.binding
            binding?.trackID = track.id
            return binding
        }
    }

    public var recognitionDurationSeconds: Double {
        tracks.reduce(0) { $0 + ($1.recognize ? $1.duration.seconds : 0) }
    }

    /// Whether a run or an import has taken this session's result, so that each track holds its
    /// outcome. A recognition track still waiting for its provider is pending or staged.
    var isResolved: Bool {
        !tracks.contains { [.pending, .staged].contains($0.state) }
    }
}

public struct TranscriptJobOutput: Sendable {
    public let url: URL
    public let document: TranscriptDocument
    public let preparationID: UUID?
}

public struct TranscriptJobRecord: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 2

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case documentID = "document_id"
        case documentIdentity = "document_identity"
        case documentDiskFingerprint = "document_disk_fingerprint"
        case sidecarProjectURL = "sidecar_project_url"
        case options
        case policy
        case requestedPolicy = "requested_policy"
        case requestedDownload = "requested_download"
        case state
        case sessions
        case workingDirectory = "working_directory"
        case ownerPID = "owner_pid"
        case helperPID = "helper_pid"
        case ownerToken = "owner_token"
        case preparationID = "preparation_id"
        case message
        case warnings
        case attached
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case inputs
    }
    public var schemaVersion = Self.currentSchemaVersion
    public var id: UUID
    public var documentID: String
    public var documentIdentity: UUID?
    public var documentDiskFingerprint: String?
    var sidecarProjectURL: URL?
    public var options: TranscriptJobOptions
    public var policy: TranscriptJobPolicy
    public var requestedPolicy: TranscriptJobPolicy?
    public var requestedDownload: Bool?
    public var state: TranscriptJobState
    public var sessions: [TranscriptJobSession]
    public var workingDirectory: URL
    public var ownerPID: Int32?
    public var helperPID: Int32?
    public var ownerToken: UUID?
    public var preparationID: UUID?
    public var message: String?
    public var warnings: [String] = []
    public var attached = false
    public var createdAt: Date? = Date()
    public var updatedAt = Date()
    var inputs: [[TranscriptJobInput]]?
}

struct TranscriptJobInput: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case file
        case name
        case offset
        case onlyStream = "only_stream"
        case omittedStreams = "omitted_streams"
    }
    var id: String
    var sourceID: String?
    var file: URL
    var name: String?
    var offset: RationalTime
    var onlyStream: Int? = nil
    var omittedStreams: [Int]? = nil
}

public enum TranscriptJobPlan {
    /// The provider refuses a session whose track has a blank name, so a source named
    /// with only spaces is listed by its file name.
    static func displayName(_ name: String?, file: URL) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? file.lastPathComponent : (name ?? trimmed)
    }

    static let replacementTrackPrefix = "tb-"

    static func replacementTrackID(_ binding: MulticamAudioReplacement) -> String {
        let source = binding.replacement.source
        return replacementTrackPrefix + digest(Data("\(source.count):\(source):\(binding.replacement.stream):\(binding.id)".utf8))
    }

    /// A multi-attachment transcript export prefixes track IDs with the attachment ordinal.
    static func replacementTrackIdentity(_ trackID: String) -> String? {
        let parts = trackID.split(separator: ":", maxSplits: 1)
        let raw = parts.count == 2 && Int(parts[0]) != nil ? String(parts[1]) : trackID
        let ids = raw.components(separatedBy: ".iso.")
        guard ids.count == 1 || (ids.count == 2 && TranscriptStore.validDigest(ids[1])) else { return nil }
        let identity = ids[0]
        guard identity.hasPrefix(replacementTrackPrefix),
              TranscriptStore.validDigest(String(identity.dropFirst(replacementTrackPrefix.count))) else { return nil }
        return identity
    }

    public static func inventory(project: CutProject, relativeTo location: URL? = nil,
                                 options: TranscriptJobOptions = .init()) throws -> [TranscriptJobSession] {
        try build(sources: inputs(project: project, relativeTo: location), options: options, directory: nil).sessions
    }

    public static func inventory(media: URL, options: TranscriptJobOptions = .init()) throws -> [TranscriptJobSession] {
        try build(sources: inputs(media: media), options: options, directory: nil).sessions
    }

    fileprivate static func inputs(project: CutProject, relativeTo location: URL?) throws -> [[TranscriptJobInput]] {
        func resolveFile(_ path: String) -> URL {
            (location.map { CutProject.mediaURL(path, relativeTo: $0) } ?? URL(fileURLWithPath: path))
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        func sequence(_ clips: [CutSequenceClip]) -> [[TranscriptJobInput]] {
            let paths = Set(clips.flatMap { clip in [clip.file, clip.originalFile].compactMap { $0 }.map(resolveFile) })
            return paths.sorted { $0.path < $1.path }.map { [input(for: $0)] }
        }
        let sources: [[TranscriptJobInput]]
        switch project {
        case .sequence(let clips):
            sources = sequence(clips)
        case .stillSequence(let project):
            sources = sequence(project.items.compactMap(\.source))
        case .multicam(let project):
            let placements = try project.transcriptReplacementPlacements()
            let sourcesByID = Dictionary(project.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let independent = Set(project.mixLanes.compactMap { lane -> MulticamAudioSelection? in
                if case .recording(let selection) = lane.target { return selection }
                return nil
            } + project.switches.compactMap(\.audio) + [project.fixedAudio].compactMap { $0 })
            let bound = Dictionary(grouping: placements.map(\.selection).filter { !independent.contains($0) }, by: \.source)
            let originals = project.sources.map { source in
                TranscriptJobInput(id: source.id, sourceID: source.id, file: resolveFile(source.file), name: source.name,
                                   offset: source.offset, omittedStreams: bound[source.id].map { Set($0.map(\.stream)).sorted() })
            }
            let replacements = placements.compactMap { placement -> TranscriptJobInput? in
                guard let source = sourcesByID[placement.selection.source],
                      let target = sourcesByID[placement.original.source] else { return nil }
                let media = resolveFile(source.file)
                let originalName = displayName(target.name, file: resolveFile(target.file))
                let name = "\(displayName(source.name, file: media)) · \(originalName) (stream \(placement.original.stream))"
                return .init(id: placement.trackID, sourceID: source.id, file: media, name: name,
                             offset: placement.offset, onlyStream: placement.selection.stream)
            }
            sources = [originals + replacements]
        }
        return sources
    }

    fileprivate static func inputs(media: URL) -> [[TranscriptJobInput]] {
        [[input(for: media.standardizedFileURL.resolvingSymlinksInPath())]]
    }

    private static func input(for media: URL) -> TranscriptJobInput {
        TranscriptJobInput(id: digest(Data(media.path.utf8)), sourceID: nil, file: media, offset: .zero)
    }

    fileprivate struct Plan {
        var sessions: [TranscriptJobSession]
        var media: [URL: MediaInfo]
        var warnings: [String] = []
    }

    private struct Fingerprint: Encodable {
        private enum CodingKeys: String, CodingKey {
            case version
            case engine
            case model
            case language
            case expectedSpeakers = "expected_speakers"
            case diarization
            case tracks
        }
        struct Track: Encodable {
            var id: String
            var evidence: String
            var stream: Int?
            var offset: RationalTime
            var channel: Int?
            var role: String
            var speaker: String?
            var recognize: Bool
            var unavailable: Bool?
        }
        var version = 1
        let engine: String?
        let model: String?
        let language: String?
        let expectedSpeakers: Int?
        let diarization: Bool?
        let tracks: [Track]
    }

    fileprivate static func build(sources: [[TranscriptJobInput]], options: TranscriptJobOptions, directory: URL?,
                                  recheckAfter: [URL: String] = [:], previous: [TranscriptJobTrack] = [],
                                  allowMissingSelections: Bool = false, cancelled: (@Sendable () -> Bool)? = nil) throws -> Plan {
        let engine = CutEngine(cancelled: cancelled)
        var result = Plan(sessions: [], media: [:])
        var ids = Set<String>()
        let selected = options.selectedTracks.map(Set.init)
        for inputs in sources where !inputs.isEmpty {
            var tracks: [TranscriptJobTrack] = []
            let sessionID = digest(Data(inputs.map(\.id).sorted().joined(separator: "\n").utf8))
            let working = (directory ?? FileManager.default.temporaryDirectory).appendingPathComponent(sessionID, isDirectory: true)
            var pending = inputs.sorted { $0.id > $1.id }.map { (input: $0, mix: nil as TranscriptJobTrack?) }
            while let (input, mix) = pending.popLast() {
                let mixID = mix?.id
                // The participant file has one audio stream. Its ID also has to exist
                // before an offline file can tell us its absolute stream index.
                let isoID = mixID.map { parent in
                    replacementTrackIdentity(parent) == nil
                        ? "t-" + digest(Data("\(input.id)\n0".utf8))
                        : parent + ".iso." + input.id
                }
                if Task.isCancelled || cancelled?() == true { throw CancellationError() }
                let media: MediaInfo
                do {
                    if let existing = result.media[input.file] {
                        media = existing
                    } else {
                        media = try inspect(input, engine: engine, previousChangeTime: recheckAfter[input.file],
                                            cancelled: cancelled)
                        result.media[input.file] = media
                    }
                    if mix != nil && media.streams.filter({ $0.kind == "audio" }).count != 1 {
                        throw jobError("invalid_transcript_track", "Expected one participant audio stream in \(input.file.lastPathComponent).")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let failure = error.localizedDescription
                    let prior = previous.filter { track in
                        guard track.file == input.file else { return false }
                        if let mixID { return track.zoomMixTrackID == mixID }
                        if input.onlyStream != nil { return track.id == input.id }
                        return track.sourceID == input.id && !track.id.hasPrefix(replacementTrackPrefix)
                    }
                    var unavailable = try unavailableTracks(input, prior: prior, message: failure)
                    if let mix, let isoID, prior.isEmpty {
                        unavailable[0].id = isoID
                        unavailable[0].zoomMixTrackID = mix.id
                        unavailable[0].zoomMixStream = mix.streamIndex
                        unavailable[0].speaker = input.name
                        unavailable[0].role = TranscriptRole.isolatedMic.rawValue
                        unavailable[0].recognize = selected?.contains(mix.id) ?? true
                    }
                    tracks.append(contentsOf: unavailable)
                    if !result.warnings.contains(failure) { result.warnings.append(failure) }
                    continue
                }
                let streams = media.streams.filter { $0.kind == "audio" }
                let name = Self.displayName(input.name, file: input.file)
                if let only = input.onlyStream, !streams.contains(where: { $0.index == only }) {
                    let unavailable = try unavailableTracks(input, prior: previous.filter { $0.id == input.id },
                                                            message: "Audio stream \(only) is no longer available for \(name).")
                    tracks.append(contentsOf: unavailable)
                    continue
                }
                for (ordinal, stream) in (streams.isEmpty ? [nil] : streams.map(Optional.some)).enumerated() {
                    if let stream, input.omittedStreams?.contains(stream.index) == true { continue }
                    if let only = input.onlyStream, stream?.index != only { continue }
                    let id: String
                    if let isoID {
                        id = isoID
                    } else {
                        id = input.onlyStream == nil ? "t-" + digest(Data("\(input.id)\n\(stream?.index ?? -1)".utf8)) : input.id
                    }
                    let participants = options.zoomParticipants?[id]
                    let chosen = mixID != nil ? TranscriptJobTrackOptions(role: "isolated_mic", speaker: input.name)
                        : options.trackOptions[id] ?? .init()
                    let channelValid = chosen.channel.map { $0 >= 0 && $0 < (stream?.channels ?? 0) } ?? true
                    guard ["isolated_mic", "mixed_audio", "unknown"].contains(chosen.role),
                          channelValid || allowMissingSelections else {
                        throw jobError("invalid_transcript_track", "Invalid role or channel for \(name).")
                    }
                    let channelLoss = channelValid ? nil : "The configured audio channel for \(name) is no longer available."
                    if let channelLoss { result.warnings.append(channelLoss) }
                    let recognize = stream != nil && participants == nil && (selected?.contains(mixID ?? id) ?? true)
                    let duration = max(media.duration, media.audio.first { $0.stream.index == stream?.index }?.end ?? .zero)
                    let prefix = working.appendingPathComponent(id).path
                    let streamEvidence = try evidence(media: media, stream: stream, duration: duration)
                    let track = TranscriptJobTrack(
                        id: id, sourceID: input.sourceID ?? input.id, file: input.file, streamIndex: stream?.index,
                        zoomMixTrackID: mixID, zoomMixStream: mix?.streamIndex, sequenceStreamOrdinal: input.sourceID == nil && stream != nil ? ordinal : nil,
                        sequenceClockOrigin: media.multicamClockOffset, projectSourceID: input.sourceID,
                        name: streams.count > 1 ? "\(name) (stream \(stream!.index))" : name, origin: .zero,
                        sessionStart: input.offset, duration: duration, channel: chosen.channel, role: chosen.role,
                        speaker: chosen.speaker, recognize: recognize, evidence: streamEvidence.digest,
                        hasReusableEvidence: streamEvidence.reusable, sourceStamp: media.identity,
                        sourceChangeTime: media.identity.transcriptJobChangeTime,
                        state: channelLoss != nil ? .failed : (stream == nil ? .coverageOnly : (recognize ? .pending : .skipped)),
                        audio: stream == nil || channelLoss != nil ? nil : URL(fileURLWithPath: prefix + ".wav"),
                        result: stream == nil || channelLoss != nil ? nil : URL(fileURLWithPath: prefix + ".json"),
                        activity: stream == nil || channelLoss != nil ? nil : URL(fileURLWithPath: prefix + ".activity.json"),
                        message: channelLoss, unavailable: channelLoss
                    )
                    tracks.append(track)
                    if let participants {
                        guard mixID == nil, stream != nil, !participants.isEmpty,
                              Set(participants.map(\.path)).count == participants.count else {
                            throw jobError("invalid_transcript_track", "Invalid Zoom participant mapping for \(name).")
                        }
                        for participant in participants.reversed() {
                            guard ProjectFile.validMediaPath(participant.path), participant.path.hasPrefix("/"),
                                  URL(fileURLWithPath: participant.path).resolvingSymlinksInPath().standardizedFileURL != input.file.resolvingSymlinksInPath().standardizedFileURL,
                                  !participant.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                throw jobError("invalid_transcript_track", "Invalid Zoom participant in \(name).")
                            }
                            let file = URL(fileURLWithPath: participant.path)
                            let participantID = digest(Data("\(id)\n\(file.path)".utf8))
                            pending.append((.init(id: participantID, sourceID: input.sourceID,
                                                  file: file, name: participant.speaker, offset: input.offset), track))
                        }
                    }
                }
            }
            for track in tracks where !ids.insert(track.id).inserted {
                throw jobError("invalid_transcript_track", "More than one track has ID \(track.id).")
            }
            let fingerprint = Fingerprint(engine: options.engine, model: options.model, language: options.language,
                                          expectedSpeakers: options.expectedSpeakers, diarization: options.diarization,
                                          tracks: tracks.sorted { $0.id < $1.id }.map {
                .init(id: $0.id, evidence: $0.evidence, stream: $0.streamIndex, offset: $0.sessionStart,
                      channel: $0.channel, role: $0.role, speaker: $0.speaker, recognize: $0.recognize,
                      unavailable: $0.unavailable == nil ? nil : true)
            })
            result.sessions.append(.init(id: sessionID, fingerprint: digest(try encodeJob(fingerprint)),
                                         manifest: working.appendingPathComponent("manifest.json"),
                                         output: working.appendingPathComponent("session.json"), tracks: tracks))
        }
        let lostSelection = (selected ?? []).subtracting(ids)
        let lostSettings = Set(options.trackOptions.keys).union(options.zoomParticipants?.keys.map { $0 } ?? []).subtracting(ids)
        if !lostSelection.isEmpty || !lostSettings.isEmpty {
            guard allowMissingSelections || result.sessions.flatMap(\.tracks).contains(where: { $0.unavailable != nil }) else {
                throw jobError("invalid_transcript_track", "Recognition selection or settings refer to an unknown track.")
            }
            let known = Dictionary(previous.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let names = lostSelection.union(lostSettings).sorted().map { known[$0] ?? $0 }
            result.warnings.append("Previously selected or configured tracks are no longer available: \(names.joined(separator: ", ")).")
        }
        return result
    }

    private static func unavailableTracks(_ input: TranscriptJobInput, prior: [TranscriptJobTrack], message: String) throws -> [TranscriptJobTrack] {
        let stamp = try? SourceIdentity(input.file)
        let stampID = try stamp.map { digest(try encodeJob($0)) } ?? "offline"
        if prior.isEmpty {
            return [TranscriptJobTrack(
                id: input.onlyStream == nil ? "t-" + digest(Data("\(input.id)\n-1".utf8)) : input.id,
                sourceID: input.sourceID ?? input.id, file: input.file,
                streamIndex: input.onlyStream, sequenceStreamOrdinal: nil, sequenceClockOrigin: .zero, projectSourceID: input.sourceID,
                name: Self.displayName(input.name, file: input.file), origin: .zero, sessionStart: input.offset,
                duration: .zero, channel: nil, role: "unknown", speaker: nil, recognize: false,
                evidence: "unavailable:" + stampID, hasReusableEvidence: false, sourceStamp: stamp,
                sourceChangeTime: stamp?.transcriptJobChangeTime, state: .failed, message: message, unavailable: message
            )]
        }
        return prior.map { old in
            var track = old
            track.sessionStart = input.offset
            track.state = .failed
            track.message = message
            track.unavailable = message
            track.evidence = "unavailable:" + stampID
            track.sourceStamp = stamp
            track.sourceChangeTime = stamp?.transcriptJobChangeTime
            track.hasReusableEvidence = false
            track.recognitionKey = nil
            track.recognitionSettingsKey = nil
            track.audio = nil
            track.stagedAudioSnapshot = nil
            track.result = nil
            track.activity = nil
            return track
        }
    }

    private static func inspect(_ input: TranscriptJobInput, engine: CutEngine, previousChangeTime: String?,
                                cancelled: (@Sendable () -> Bool)?) throws -> MediaInfo {
        do {
            let indexed = try engine.inspect(input.file, keyframes: true)
            let needsPayload = indexed.streams.contains { stream in
                guard stream.kind == "audio" else { return false }
                guard let evidence = indexed.refreshEvidence, evidence.streams.indices.contains(stream.index) else {
                    return true
                }
                let entry = evidence.streams[stream.index]
                return entry.payload == nil || entry.timing == nil
            }
            let changedSincePreparation = previousChangeTime.map {
                indexed.identity.transcriptJobChangeTime != $0
            } ?? false
            guard needsPayload || changedSincePreparation else { return try engine.multicamClock(indexed) }
            let fresh = try MediaRefresh.check(input.file, previous: indexed, verification: .deep,
                                               cancelled: cancelled ?? { Task.isCancelled })
            if fresh.state == .offline {
                throw jobError("transcript_source_offline", "The recording is unavailable.")
            }
            return try engine.multicamClock(fresh.media ?? indexed)
        } catch {
            if cancelled?() == true || Task.isCancelled { throw CancellationError() }
            let source = input.file.lastPathComponent
            let unavailable = !FileManager.default.fileExists(atPath: input.file.path)
            let code = unavailable ? "transcript_source_offline" : ((error as? CutError)?.code ?? "transcript_source_failed")
            throw jobError(code, "Could not index \(source). \(error.localizedDescription)")
        }
    }

    private struct StreamClockEvidence: Encodable {
        var extractionVersion = 1
        let payload: Data
        let timing: Data
        let configuration: Data
        let duration: RationalTime
        let origin: RationalTime
        let start: RationalTime
        let initialPadding: Int
        let trailingPadding: Int
        let seekPreroll: Int
        let channelLayout: String
        let sampleRate: Int
        let channels: Int
        let presentationEdits: Bool
    }

    /// Compare this value against a completed session's stream evidence.
    /// Supply the full index on MPCut's presentation clock.
    public static func streamEvidence(media: MediaInfo, streamIndex: Int) throws -> String? {
        guard let stream = media.streams.first(where: { $0.kind == "audio" && $0.index == streamIndex }) else {
            return nil
        }
        let duration = max(media.duration, media.audio.first { $0.stream.index == stream.index }?.end ?? .zero)
        let result = try evidence(media: media, stream: stream, duration: duration)
        return result.reusable ? result.digest : nil
    }

    /// Refresh evidence stores the ordinary editing clock. Recognition runs on the
    /// presentation clock, including any leading empty movie edit.
    static func streamEvidence(_ evidence: MediaRefreshEvidence, streamIndex: Int) throws -> String? {
        guard evidence.streams.indices.contains(streamIndex) else { return nil }
        let record = evidence.streams[streamIndex]
        guard record.kind == "audio" else { return nil }
        let offset = MediaInfo.multicamSourceOffset(origin: evidence.origin, format: evidence.format)
        let duration = try max(evidence.duration, record.audioEnd ?? .zero).adding(offset)
        return try streamDigest(record, duration: duration, origin: offset > .zero ? .zero : evidence.origin)
    }

    private static func streamDigest(_ record: MediaRefreshEvidence.Stream, duration: RationalTime,
                                     origin: RationalTime) throws -> String? {
        guard let payload = record.payload, let timing = record.timing else { return nil }
        return digest(try encodeJob(StreamClockEvidence(
            payload: payload, timing: timing, configuration: record.configuration, duration: duration,
            origin: origin, start: record.start, initialPadding: record.initialPadding,
            trailingPadding: record.trailingPadding, seekPreroll: record.seekPreroll, channelLayout: record.channelLayout,
            sampleRate: record.sampleRate, channels: record.channels, presentationEdits: record.insertedPresentationEdits
        )))
    }

    private static func evidence(media: MediaInfo, stream: StreamInfo?, duration: RationalTime) throws -> (digest: String, reusable: Bool) {
        if let stream, let evidence = media.refreshEvidence, evidence.streams.indices.contains(stream.index),
           let proof = try streamDigest(evidence.streams[stream.index], duration: duration, origin: media.origin) {
            return (proof, true)
        }
        return (digest(try encodeJob(media.identity) + Data(":v1:\(stream?.index ?? -1):\(media.origin):\(duration)".utf8)), false)
    }
}

private struct TranscriptHandoff: Encodable {
    struct Track: Encodable {
        struct Binding: Encodable {
            var stream_index: Int?
            var origin: RationalTime
            var session_start: RationalTime
        }
        var track_id: String
        var source_id: String
        var stream_evidence: String
        var binding: Binding
        var channel: Int?
        var name: String
        var role: String
        var speaker: String?
        var recognize: Bool
        var start_frame: Int64
        var audio: String?
        var result: String?
        var activity: String?
        var recognition_key: String?
        var reuse: Bool?
        var unavailable: String?
        var shared_cache: TranscriptExternalCacheDescriptor?
    }
    var schema_version = 1
    var job_id: String
    var fingerprint: String
    var engine: String?
    var model: String?
    var language: String?
    var expected_speakers: Int?
    var diarization: Bool?
    var output: String
    var tracks: [Track]
}

/// Asks whether a job's record still names this owner, at most every 50 ms. Every writer
/// replaces the record file, so an unchanged file answers as it did before and is not
/// decoded again. Extraction asks before each packet and a provider run ten times a second.
/// A volume with coarse timestamps and reused file numbers can show a replaced record
/// unchanged, so the record is decoded once a second regardless.
final class TranscriptJobPoll: @unchecked Sendable {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private let lock = NSLock()
    private let record: URL
    private var seen: Stamp?
    private var nextCheck: UInt64 = 0
    private var nextDecode: UInt64 = 0
    private var stopped = false

    init(record: URL) {
        self.record = record
    }

    func isStopped(check: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if !stopped, now >= nextCheck {
            let current = Stamp(record)
            if current == nil || current != seen || now >= nextDecode {
                stopped = check()
                seen = current
                nextDecode = now + 1_000_000_000
            }
            nextCheck = now + 50_000_000
        }
        return stopped
    }
}

public struct TranscriptJobStore: Sendable {
    public let directory: URL
    /// A standalone provider reads every staged recording, so preparation writes them all.
    /// An owner that also runs the provider clears this: `run` stages a recording only when
    /// its track needs recognition or levels, and a retry or reconcile over finished tracks
    /// then decodes no audio at all.
    public var stagesAudioForStandaloneProvider = true
    /// `run` stops a session or model download that for this many seconds has written nothing
    /// and used no processor time, and fails the job so it can be retried. Recognition that is
    /// merely slow keeps the processor busy and is never stopped. The default leaves half an
    /// hour for a wait on something outside the helper's own processes, such as a system
    /// service installing speech assets. `nil` waits for ever.
    public var providerStallLimit: TimeInterval? = 1_800

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MPCut/TranscriptJobs", isDirectory: true)
    }

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory.standardizedFileURL
    }

    func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func workURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func lockURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".lock") }

    /// Locks a job and returns the descriptor to close, or nil when `wait` is false and another
    /// process holds it. A discarded or pruned job takes its lock file with it, so the lock counts
    /// only while the path still names the locked file. A process that opened the file before
    /// its removal would otherwise hold a lock no later process can see.
    private func lock(_ id: UUID, wait: Bool) throws -> Int32? {
        let path = lockURL(id).path
        while true {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw jobError("transcript_job_storage", String(cString: strerror(errno))) }
            while flock(fd, wait ? LOCK_EX : LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                let reason = errno
                close(fd)
                if !wait, reason == EWOULDBLOCK { return nil }
                throw jobError("transcript_job_storage", String(cString: strerror(reason)))
            }
            var held = stat(), named = stat()
            if fstat(fd, &held) == 0, stat(path, &named) == 0,
               held.st_ino == named.st_ino, held.st_dev == named.st_dev { return fd }
            close(fd)
        }
    }

    private func withLock<T>(_ id: UUID, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let fd = try lock(id, wait: true) else {
            throw jobError("transcript_job_storage", "Could not lock the transcript job.")
        }
        defer { close(fd) }
        return try body()
    }

    func read(_ id: UUID) throws -> TranscriptJobRecord {
        let file = recordURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw jobError("unknown_transcript_job", "No transcript job has ID \(id.uuidString).")
        }
        struct StoredJob: Decodable {
            enum Keys: String, CodingKey { case schemaVersion = "schema_version" }
            let record: TranscriptJobRecord
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: Keys.self)
                guard try fields.decodeIfPresent(Int.self, forKey: .schemaVersion) == TranscriptJobRecord.currentSchemaVersion else {
                    throw jobError("unsupported_transcript_job_version", "This transcript job requires schema version \(TranscriptJobRecord.currentSchemaVersion).")
                }
                record = try TranscriptJobRecord(from: decoder)
            }
        }
        let record = try JSONDecoder().decode(StoredJob.self, from: Data(contentsOf: file)).record
        let trackIDs = record.sessions.flatMap(\.tracks).map(\.id)
        guard record.id == id, record.workingDirectory.isFileURL,
              record.workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path
                == workURL(id).resolvingSymlinksInPath().standardizedFileURL.path else {
            throw jobError("transcript_job_storage", "The job record does not match its working directory.")
        }
        guard Set(trackIDs).count == trackIDs.count else {
            throw jobError("transcript_job_storage", "The job record contains duplicate track IDs.")
        }
        return record
    }

    @discardableResult
    func update(_ id: UUID, _ modify: (inout TranscriptJobRecord) throws -> Void) throws -> TranscriptJobRecord {
        try withLock(id) {
            var record = try read(id)
            try modify(&record)
            try write(record: &record)
            return record
        }
    }

    private func write(record: inout TranscriptJobRecord) throws {
        record.updatedAt = Date()
        try encodeJob(record).write(to: recordURL(record.id), options: .atomic)
    }

    func claimRun(_ id: UUID, token: UUID) throws -> TranscriptJobRecord {
        let current = try status(id)
        guard current.state == .prepared, current.ownerToken == nil else { return current }
        return try withLock(id) {
            var record = try read(id)
            guard record.state == .prepared, record.ownerToken == nil,
                  record.preparationID == current.preparationID else { return record }
            record.state = .running
            record.ownerToken = token
            record.ownerPID = getpid()
            record.helperPID = nil
            record.message = nil
            try write(record: &record)
            return record
        }
    }

    /// The owner writes the record while it works, so a process that started after the last
    /// write has only inherited the number. A process this user may not signal belongs to
    /// someone else. Either would otherwise hold the job, and its staged audio, for ever.
    static func ownerIsGone(_ pid: pid_t, lastSeen: Date) -> Bool {
        if kill(pid, 0) == -1 { return errno == ESRCH || errno == EPERM }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let started = info.kp_proc.p_starttime
        let start = Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
        return start > lastSeen.addingTimeInterval(1)
    }

    private func recoverOwner(_ record: TranscriptJobRecord) throws -> TranscriptJobRecord {
        if record.ownerToken != nil, let pid = record.ownerPID, Self.ownerIsGone(pid, lastSeen: record.updatedAt) {
            return try update(record.id) {
                if $0.ownerToken == record.ownerToken {
                    if [.running, .preparing].contains($0.state) { $0.state = .interrupted }
                    if $0.state == .cancelled { removeStagedAudio($0) }
                    $0.ownerPID = nil
                    $0.helperPID = nil
                    $0.ownerToken = nil
                }
            }
        }
        return record
    }

    public func status(_ id: UUID) throws -> TranscriptJobRecord {
        let record = try recoverOwner(read(id))
        if record.state == .prepared, !record.sessions.isEmpty,
           record.sessions.allSatisfy({ FileManager.default.fileExists(atPath: $0.output.path) }) {
            // An explicitly launched standalone provider can finish without any
            // MPCut process receiving events. Import still checks current media.
            return (try? verify(record, current: record.sessions).record) ?? record
        }
        return record
    }

    public func list(documentID: String) throws -> [TranscriptJobRecord] {
        try list { $0.documentID == documentID }
    }

    public func list(documentIdentity: UUID) throws -> [TranscriptJobRecord] {
        try list { $0.documentIdentity == documentIdentity }
    }

    private func list(where match: (TranscriptJobRecord) -> Bool) throws -> [TranscriptJobRecord] {
        try matchingRecords(where: match)
            .compactMap { try? status($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Read candidates without recovering owners or verifying provider output.
    /// The editor can discard these results if the document closes during discovery.
    package func matchingRecords(documentID: String, documentIdentity: UUID?) throws -> [TranscriptJobRecord] {
        try matchingRecords(checkCancellation: true) { record in
            record.documentID == documentID || (documentIdentity != nil && record.documentIdentity == documentIdentity)
        }
    }

    private func matchingRecords(checkCancellation: Bool = false,
                                 where match: (TranscriptJobRecord) -> Bool) throws -> [TranscriptJobRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .compactMap {
                if checkCancellation { try Task.checkCancellation() }
                return (try? read($0)).flatMap { match($0) ? $0 : nil }
            }
    }

    public func discard(documentID: String) throws {
        for record in try list(documentID: documentID) {
            try withLock(record.id) {
                let current = try read(record.id)
                guard current.documentID == documentID else { return }
                guard current.ownerToken == nil else {
                    throw jobError("transcript_job_running", "Stop this transcript job before discarding its data.")
                }
                if FileManager.default.fileExists(atPath: current.workingDirectory.path) {
                    try FileManager.default.removeItem(at: current.workingDirectory)
                }
                try FileManager.default.removeItem(at: recordURL(record.id))
                try? FileManager.default.removeItem(at: lockURL(record.id))
            }
        }
    }

    /// Removes jobs nothing has touched for `age` seconds, with their staged audio, artifacts
    /// and lock files, and returns their IDs. A saved project's jobs are otherwise kept for ever:
    /// only a discarded draft removes its own.
    ///
    /// A job stays while a process owns it or holds its lock, while any of its files is newer
    /// than the cutoff, and while it holds a finished result whose document still exists: an
    /// unattached result is not stored anywhere else, and an attached one is reconciled from
    /// this record. An attached result goes once the document has attached others in place of
    /// all of it. Everything a pruned job held can be staged or recognized again from the
    /// media and its sidecar.
    ///
    /// A job that stays gives up the attached session outputs that only repeat its track
    /// results, whatever its age, and keeps each finished track's result and levels packed.
    @discardableResult
    public func prune(olderThan age: TimeInterval, now: Date = Date()) throws -> [UUID] {
        let manager = FileManager.default
        guard age > 0, manager.fileExists(atPath: directory.path) else { return [] }
        let cutoff = now.addingTimeInterval(-age)
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        /// The job folder, its session folders and their files. A standalone provider writes there.
        /// Taking the lock creates a missing lock file, so its age counts only before that.
        func isIdle(_ id: UUID, locked: Bool = false) -> Bool {
            var files = [recordURL(id), workURL(id)] + (locked ? [] : [lockURL(id)])
            for session in (try? manager.contentsOfDirectory(at: workURL(id), includingPropertiesForKeys: nil)) ?? [] {
                files.append(session)
                files += (try? manager.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            }
            return files.allSatisfy { modified($0).map { $0 < cutoff } ?? true }
        }
        let names = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let ids = Set(names.compactMap { entry -> UUID? in
            let name = entry.lastPathComponent
            guard ["", "json", "lock"].contains(entry.pathExtension) else { return nil }
            return UUID(uuidString: entry.pathExtension.isEmpty ? name : entry.deletingPathExtension().lastPathComponent)
        })
        /// The transcripts each document holds on disk, read once however many jobs it has.
        /// Nil for a path that is not a project this version can read.
        var documents: [String: ProjectTranscripts?] = [:]
        func transcripts(of document: String) -> ProjectTranscripts? {
            if let known = documents[document] { return known }
            let saved = try? CutProject.load(from: URL(fileURLWithPath: document)).transcripts
            documents.updateValue(saved, forKey: document)
            return saved
        }
        var removed: [UUID] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where isIdle(id) {
            guard let fd = try? lock(id, wait: false) else { continue }
            defer { close(fd) }
            guard isIdle(id, locked: true) else { continue }
            if manager.fileExists(atPath: recordURL(id).path) {
                // A record this store cannot read may belong to a newer version or a moved folder.
                guard let record = try? read(id), record.updatedAt < cutoff else { continue }
                if record.ownerToken != nil {
                    guard let owner = record.ownerPID, Self.ownerIsGone(owner, lastSeen: record.updatedAt) else { continue }
                }
                // An attached result is what Reconcile reads after a sync change, however old.
                if [.completed, .partial].contains(record.state), manager.fileExists(atPath: record.documentID) {
                    guard record.attached, let current = transcripts(of: record.documentID),
                          isSuperseded(record, by: current) else { continue }
                }
            }
            do {
                // A lock file can outlive its job. Removing one alone is not a pruned job.
                let held = manager.fileExists(atPath: workURL(id).path) || manager.fileExists(atPath: recordURL(id).path)
                if manager.fileExists(atPath: workURL(id).path) { try manager.removeItem(at: workURL(id)) }
                if manager.fileExists(atPath: recordURL(id).path) { try manager.removeItem(at: recordURL(id)) }
                try manager.removeItem(at: lockURL(id))
                if held { removed.append(id) }
            } catch {
                // A file that cannot be removed leaves the job in place for the next pass.
            }
        }
        // Removing an output changes its folder, which would make a job look recently used
        // to the pass above.
        for id in ids.subtracting(removed) {
            // Taking the lock creates its file, so look for something to remove first.
            func outputs() -> [URL] {
                guard let record = try? read(id) else { return [] }
                return attachedOutputs(record).filter { output in
                    // An output written after the record has not been imported yet.
                    modified(output).map { $0 < record.updatedAt } ?? false
                }
            }
            guard !outputs().isEmpty, let fd = try? lock(id, wait: false) else { continue }
            defer { close(fd) }
            for output in outputs() { try? manager.removeItem(at: output) }
        }
        // A job finished by a version that kept each track's files as written, or one whose
        // result was never read.
        for id in ids.subtracting(removed) { packArtifacts(id, wait: false) }
        return removed
    }

    /// The session outputs an attached job can give up. The project that attached a result
    /// stores it, and a retry discards the output before its provider writes a new one, so
    /// only a second import of the same job reads these files.
    private func attachedOutputs(_ record: TranscriptJobRecord) -> [URL] {
        guard record.attached, record.ownerToken == nil, [.completed, .partial].contains(record.state) else { return [] }
        // Look for the output first: the other question reads each track's result.
        return record.sessions.filter { FileManager.default.fileExists(atPath: $0.output.path) && holdsOutputAsCopy($0) }
            .map(\.output)
    }

    /// Whether a session's output repeats what the job holds elsewhere: the session has been
    /// read, and every track it recognized has its own result, plain or packed, that can be
    /// read. That is what a provider builds the output from again without recognizing.
    /// A provider run on its own may write the output and no track results. That output is
    /// the job's only copy of the recognition, which a second import could otherwise get
    /// back only by recognizing again, so it stays.
    /// A track that failed has nothing in either place. A session still to be recognized
    /// keeps the place where its provider writes.
    private func holdsOutputAsCopy(_ session: TranscriptJobSession) -> Bool {
        session.isResolved && session.tracks.allSatisfy { track in
            guard [.recognized, .cached].contains(track.state) else { return true }
            return track.result.flatMap(TranscriptJobArtifact.read) != nil
        }
    }

    /// Whether the document of an attached job has since attached other results in place of
    /// every session of this one. Reconcile starts from the job an attached transcript names,
    /// and none of the document's transcripts came from this job, so nothing reads it again.
    /// A job whose result was never attached holds the only copy and is not superseded.
    /// A transcript that cannot be read, or a document that belongs to another project,
    /// leaves the job in place.
    private func isSuperseded(_ record: TranscriptJobRecord, by transcripts: ProjectTranscripts) -> Bool {
        guard record.attached, record.ownerToken == nil else { return false }
        if let owner = record.documentIdentity, transcripts.documentID != owner { return false }
        let fingerprints = Set(record.sessions.map(\.fingerprint))
        if transcripts.attachments.contains(where: { $0.fingerprint.map(fingerprints.contains) ?? false }) { return false }
        // A stored transcript names its job. That outlives a retry, which gives the job's
        // sessions new fingerprints, and it is all an older transcript carries.
        let document = URL(fileURLWithPath: record.documentID)
        for attachment in transcripts.attachments {
            guard let bytes = try? TranscriptStore.read(attachment.asset, relativeTo: document),
                  let transcript = try? TranscriptCodec.decode(bytes, format: .json) else { return false }
            if transcript.jobID.flatMap(UUID.init(uuidString:)) == record.id { return false }
        }
        return true
    }

    /// The folder where MPCut and a standalone Transcriberrr exchange recognition results.
    public static func sharedRecognitionDirectory() throws -> URL { try TranscriptRecognitionClaims.directory() }

    /// Removes shared recognition results, and the claim files beside them, that were last
    /// written more than `age` seconds before `now` and that no process has claimed. Returns
    /// the number of results removed. A removed result is recognized again when next needed,
    /// unless the media's own sidecar already holds a copy.
    @discardableResult
    public static func pruneSharedRecognition(in directory: URL, olderThan age: TimeInterval,
                                              now: Date = Date()) -> Int {
        TranscriptRecognitionClaims.prune(in: directory, olderThan: age, now: now)
    }

    /// The same for the results that every MPCut process on this account shares.
    @discardableResult
    public static func pruneSharedRecognition(olderThan age: TimeInterval, now: Date = Date()) -> Int {
        guard let directory = try? TranscriptRecognitionClaims.directory() else { return 0 }
        return pruneSharedRecognition(in: directory, olderThan: age, now: now)
    }

    /// Records that the project has stored this job's result, and removes the session outputs
    /// that only repeat its track results. The record is written first, so a job that still
    /// has to attach never finds its output gone.
    @discardableResult
    public func markAttached(_ id: UUID, expectedPreparationID: UUID? = nil) throws -> TranscriptJobRecord {
        try withLock(id) {
            var record = try read(id)
            if let expectedPreparationID, record.preparationID != expectedPreparationID {
                throw jobError("stale_transcript_job", "The job was retried before the attachment was written.")
            }
            guard [.completed, .partial].contains(record.state) else {
                throw jobError("transcript_job_unavailable", "Only a finished transcript job can be acknowledged.")
            }
            record.attached = true
            try write(record: &record)
            for output in attachedOutputs(record) { try? FileManager.default.removeItem(at: output) }
            return record
        }
    }

    public func rebindDocument(from: String, to: String, documentIdentity: UUID? = nil) throws {
        guard from != to else { return }
        let matches: (TranscriptJobRecord) -> Bool = {
            $0.documentID == from && (documentIdentity == nil || $0.documentIdentity == documentIdentity)
        }
        for record in try list(where: matches) {
            try update(record.id) { record in
                guard matches(record) else { return }
                if record.sidecarProjectURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: from).resolvingSymlinksInPath().path {
                    record.sidecarProjectURL = URL(fileURLWithPath: to)
                }
                record.documentID = to
            }
        }
    }

    public func prepare(project: CutProject, documentID: String, relativeTo location: URL? = nil,
                        documentIdentity: UUID? = nil, documentDiskFingerprint: String? = nil, options: TranscriptJobOptions = .init(), operationID: UUID = UUID(),
                        policy: TranscriptJobPolicy = .reuse, download: Bool? = nil,
                        cancelled: @escaping @Sendable () -> Bool = { false },
                        progress: (TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
        try prepare(inputs: TranscriptJobPlan.inputs(project: project, relativeTo: location), documentID: documentID,
                    documentIdentity: documentIdentity, documentDiskFingerprint: documentDiskFingerprint, options: options, operationID: operationID, policy: policy, download: download, cancelled: cancelled, progress: progress)
    }

    public func prepare(media: URL, documentID: String, options: TranscriptJobOptions = .init(),
                        operationID: UUID = UUID(), policy: TranscriptJobPolicy = .reuse, download: Bool? = nil,
                        cancelled: @escaping @Sendable () -> Bool = { false },
                        progress: (TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
        try prepare(inputs: TranscriptJobPlan.inputs(media: media), documentID: documentID, options: options,
                    operationID: operationID, policy: policy, download: download, cancelled: cancelled, progress: progress)
    }

    private func prepare(inputs: [[TranscriptJobInput]], documentID: String,
                         documentIdentity: UUID? = nil, documentDiskFingerprint: String? = nil, options: TranscriptJobOptions,
                         operationID id: UUID, policy: TranscriptJobPolicy, allowReconfiguration: Bool = false,
                         download: Bool? = nil, cancelled stopRequested: @escaping @Sendable () -> Bool,
                         progress: (TranscriptJobRecord) -> Void) throws -> TranscriptJobRecord {
        _ = try? status(id)
        let token = UUID()
        let initial = try withLock(id) {
            var record: TranscriptJobRecord
            if FileManager.default.fileExists(atPath: recordURL(id).path) {
                record = try read(id)
                guard record.documentID == documentID, record.options == options,
                      documentIdentity == nil || record.documentIdentity == documentIdentity,
                      allowReconfiguration || record.inputs == inputs else {
                    throw jobError("transcript_operation_conflict", "This operation ID already belongs to another transcript request.")
                }
                if record.ownerToken != nil || [.running, .preparing].contains(record.state)
                    || (policy == .reuse && [.prepared, .completed, .partial].contains(record.state)) {
                    return record
                }
            } else {
                record = TranscriptJobRecord(id: id, documentID: documentID, documentIdentity: documentIdentity,
                                             documentDiskFingerprint: documentDiskFingerprint, options: options, policy: policy,
                                             requestedPolicy: policy, requestedDownload: download, state: .preparing, sessions: [], workingDirectory: workURL(id))
            }
            if let project = SidecarLocations.projectURL { record.sidecarProjectURL = project }
            record.policy = policy
            record.inputs = inputs
            record.preparationID = token
            record.state = .preparing
            record.attached = false
            record.message = nil
            record.ownerToken = token
            record.ownerPID = getpid()
            record.helperPID = nil
            try write(record: &record)
            return record
        }
        guard initial.ownerToken == token else { return initial }
        progress(initial)
        let poll = TranscriptJobPoll(record: recordURL(id))
        let cancelled: @Sendable () -> Bool = {
            if Task.isCancelled || stopRequested() { return true }
            return poll.isStopped {
                guard let record = try? read(id) else { return true }
                return record.ownerToken != token || record.state != .preparing
            }
        }
        do {
            let plan = try TranscriptJobPlan.build(sources: inputs, options: options,
                                                   directory: workURL(id), recheckAfter: sourceChangeTimes(initial),
                                                   previous: initial.sessions.flatMap(\.tracks),
                                                   allowMissingSelections: initial.policy == .resume,
                                                   cancelled: cancelled)
            return try stage(plan, initial: initial, token: token, cancelled: cancelled, progress: progress)
        } catch {
            _ = try? update(id) {
                if $0.ownerToken == token {
                    if $0.state == .preparing {
                        $0.state = error is CancellationError || Task.isCancelled || stopRequested() ? .interrupted : .failed
                        $0.message = error.localizedDescription
                    }
                    if $0.state == .cancelled { removeStagedAudio($0) }
                    $0.ownerToken = nil
                    $0.ownerPID = nil
                }
            }
            throw error
        }
    }

    private func stage(_ plan: TranscriptJobPlan.Plan, initial: TranscriptJobRecord, token: UUID,
                       cancelled: @escaping @Sendable () -> Bool,
                       progress: (TranscriptJobRecord) -> Void) throws -> TranscriptJobRecord {
        if cancelled() { throw CancellationError() }
        guard plan.sessions.contains(where: { !$0.tracks.isEmpty }) else {
            throw jobError("no_transcript_tracks", "This project contains no media sources.")
        }
        if initial.policy == .restart, FileManager.default.fileExists(atPath: initial.workingDirectory.path) {
            try FileManager.default.removeItem(at: initial.workingDirectory)
        }
        let id = initial.id
        // A provider reads each artifact at its own path, and the steps below link and compare
        // the files themselves.
        try restoreArtifacts(initial)
        // Reuse staged audio only when its complete extraction inputs match.
        let old = Dictionary(uniqueKeysWithValues: initial.sessions.flatMap(\.tracks).map { ($0.id, $0) })
        var prepared = plan.sessions
        var warnings = plan.warnings
        if initial.policy != .restart {
            for sessionIndex in prepared.indices {
                for index in prepared[sessionIndex].tracks.indices {
                    if cancelled() { throw CancellationError() }
                    var track = prepared[sessionIndex].tracks[index]
                    guard let prior = old[track.id], prior.evidence == track.evidence,
                          prior.channel == track.channel, track.unavailable == nil else { continue }
                    track.recognitionKey = prior.recognitionKey
                    track.recognitionSettingsKey = prior.recognitionSettingsKey
                    track.downmixChannel = prior.downmixChannel
                    // Establish the new durable artifact paths before the record stops
                    // pointing to the old membership. A crash during this step can retry.
                    let trustedAudio = prior.stagedAudioSnapshot?.isCurrent == true ? prior.audio : nil
                    for (previous, destination) in [(trustedAudio, track.audio), (prior.result, track.result),
                                                    (prior.activity, track.activity),
                                                    (prior.result?.appendingPathExtension("provenance"),
                                                     track.result?.appendingPathExtension("provenance"))] {
                        guard let previous, let destination, previous.path != destination.path,
                              !FileManager.default.fileExists(atPath: destination.path),
                              FileManager.default.fileExists(atPath: previous.path) else { continue }
                        do {
                            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                                    withIntermediateDirectories: true,
                                                                    attributes: [.posixPermissions: 0o700])
                            if destination == track.audio {
                                // The source WAV is removed after staging. A hard link
                                // would change the destination identity at that point.
                                try FileManager.default.copyItem(at: previous, to: destination)
                                track.stagedAudioSnapshot = .init(destination)
                            } else {
                                try FileManager.default.linkItem(at: previous, to: destination)
                            }
                        } catch {
                            warnings.append("Could not carry forward staged artifacts for \(track.name).")
                        }
                    }
                    if let trustedAudio, let audio = track.audio, trustedAudio.path == audio.path {
                        track.stagedAudioSnapshot = prior.stagedAudioSnapshot
                    }
                    prepared[sessionIndex].tracks[index] = track
                }
            }
        }
        var record = try update(id) {
            guard $0.ownerToken == token, $0.state == .preparing else { throw CancellationError() }
            $0.sessions = prepared
            for warning in warnings where !$0.warnings.contains(warning) { $0.warnings.append(warning) }
        }
        progress(record)
        let retainedAudio = Set(record.sessions.flatMap(\.tracks).compactMap(\.audio))
        typealias Staged = (extraction: TranscriptAudioExtraction, snapshot: TranscriptExternalCacheDescriptor.Snapshot)
        let pool = TranscriptExtractionPool<Staged>(cancelled: cancelled)
        defer { pool.finish() }
        var tickets: [String: Int] = [:]
        // Clear every session folder before a worker writes its scratch file into one.
        for session in record.sessions {
            let folder = session.manifest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            removeAbandonedScratch(in: folder)
            if FileManager.default.fileExists(atPath: session.output.path) {
                try FileManager.default.removeItem(at: session.output)
            }
            for track in session.tracks {
                if cancelled() { throw CancellationError() }
                guard let stream = track.streamIndex, let audio = track.audio,
                      let media = plan.media[track.file] else { continue }
                let prior = old[track.id]
                if initial.policy == .restart || prior?.evidence != track.evidence || prior?.channel != track.channel {
                    for artifact in [track.audio, track.result?.appendingPathExtension("provenance")].compactMap({ $0 }) {
                        try? FileManager.default.removeItem(at: artifact)
                    }
                    for artifact in [track.result, track.activity].compactMap({ $0 }) {
                        TranscriptJobArtifact.remove(artifact)
                    }
                }
                let finished = !stagesAudioForStandaloneProvider && initial.policy != .restart
                    && prior?.evidence == track.evidence && prior?.channel == track.channel
                    && hasFinishedArtifacts(track, recognitionKey: prior?.recognitionKey)
                guard track.stagedAudioSnapshot?.isCurrent != true, !finished else { continue }
                let name = track.name
                let channel = track.channel
                tickets[track.id] = pool.add { stop in
                    if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
                    let extraction = try CutEngine(cancelled: stop).extractTranscriptAudio(
                        media, stream: stream, channel: channel, to: audio, cancelled: stop)
                    guard let snapshot = TranscriptExternalCacheDescriptor.Snapshot(audio) else {
                        throw jobError("transcript_extraction_failed", "Could not verify the staged PCM for \(name).")
                    }
                    return (extraction, snapshot)
                }
            }
        }
        pool.start()
        // Collect in track order, so the record, its progress reports and each source's
        // sidecar change in the same sequence whichever extraction finishes first.
        for index in record.sessions.indices {
            var session = record.sessions[index]
            for trackIndex in session.tracks.indices {
                if cancelled() { throw CancellationError() }
                var track = session.tracks[trackIndex]
                guard track.streamIndex != nil, let audio = track.audio,
                      let media = plan.media[track.file] else { continue }
                var notes: [String] = []
                do {
                    var measured: [Float]?
                    if let ticket = tickets[track.id] {
                        let staged = try pool.result(ticket, cancelled: cancelled)
                        track.stagedAudioSnapshot = staged.snapshot
                        measured = staged.extraction.levels
                        track.downmixChannel = staged.extraction.downmixFallbackChannel
                        if let channel = staged.extraction.downmixFallbackChannel {
                            let note = "The channels of \(track.name) cancel each other in a mono mix. "
                                + "Channel \(channel) is transcribed alone. Choose a channel for this track to change it."
                            track.message = note
                            notes.append(note)
                        }
                    }
                    track.state = track.recognize ? .staged : .skipped
                    do {
                        if let warning = try prepareActivity(track, media: media, audio: audio, measured: measured,
                                                             cancelled: cancelled) { notes.append(warning) }
                        // A track that is not recognized is staged only to be measured, and its
                        // levels are now saved: the run hands the provider those and no audio.
                        // A standalone provider is handed every recording, and a restart
                        // measures again from the audio.
                        if measured != nil, !track.recognize, !stagesAudioForStandaloneProvider, initial.policy != .restart {
                            try? FileManager.default.removeItem(at: audio)
                            track.stagedAudioSnapshot = nil
                        }
                    } catch {
                        if cancelled() { throw CancellationError() }
                        notes.append("Could not save audio levels for \(track.name). \(error.localizedDescription)")
                    }
                } catch {
                    if cancelled() { throw CancellationError() }
                    track.state = .failed
                    track.message = error.localizedDescription
                }
                session.tracks[trackIndex] = track
                record = try update(id) {
                    guard $0.ownerToken == token, $0.state == .preparing else { throw CancellationError() }
                    $0.sessions[index] = session
                    for note in notes where !$0.warnings.contains(note) { $0.warnings.append(note) }
                }
                progress(record)
            }
            try writeManifest(session, job: record, externalCache: true)
        }
        for audio in initial.sessions.flatMap(\.tracks).compactMap(\.audio) where !retainedAudio.contains(audio) {
            try? FileManager.default.removeItem(at: audio)
        }
        if cancelled() { throw CancellationError() }
        record = try update(id) {
            guard $0.ownerToken == token, $0.state == .preparing else { throw CancellationError() }
            $0.state = .prepared
            $0.ownerPID = nil
            $0.ownerToken = nil
        }
        progress(record)
        return record
    }

    /// Whether the files a finished track left behind still answer for this recording, so that
    /// neither recognition nor level measurement would read its audio again.
    private func hasFinishedArtifacts(_ track: TranscriptJobTrack, recognitionKey: String?) -> Bool {
        guard let levels = track.activity, let duration = try? track.duration.roundedToSamples(16_000),
              let data = TranscriptJobArtifact.read(levels),
              TranscriptRecognitionCache.Artifacts.matchesActivity(data, evidence: track.evidence, duration: duration) else {
            return false
        }
        guard track.recognize else { return true }
        guard let recognitionKey, let result = track.result.flatMap(TranscriptJobArtifact.read) else { return false }
        return TranscriptRecognitionCache.Artifacts(result: result, activity: data)
            .matches(key: recognitionKey, evidence: track.evidence, needsActivity: true)
    }

    /// Writes every artifact a track holds packed back at the path its manifest names.
    func restoreArtifacts(_ record: TranscriptJobRecord) throws {
        for track in record.sessions.flatMap(\.tracks) {
            for artifact in [track.result, track.activity].compactMap({ $0 }) { try TranscriptJobArtifact.restore(artifact) }
        }
    }

    /// The artifacts of a finished job that are still plain files. A track that was recognized,
    /// answered from the cache or only measured has what a retry reads, and nothing reads it
    /// until then. A session still waiting for a provider run on its own keeps its files as
    /// that provider expects them, and a failed track is the one a retry works on.
    private func packableArtifacts(_ record: TranscriptJobRecord) -> [(url: URL, kind: TranscriptJobArtifact.Kind)] {
        guard record.ownerToken == nil, [.completed, .partial].contains(record.state) else { return [] }
        return record.sessions.filter(\.isResolved).flatMap(\.tracks)
            .filter { [.recognized, .cached, .skipped].contains($0.state) }
            .flatMap { [($0.result, TranscriptJobArtifact.Kind.result), ($0.activity, .levels)] }
            .compactMap { artifact in artifact.0.map { (url: $0, kind: artifact.1) } }
            .filter { TranscriptJobArtifact.isPackable($0.url) }
    }

    /// Packs what a finished job keeps for each track. The job's lock is held for it, so no
    /// retry or run starts on files that are changing form. Without `wait`, a job that
    /// another process holds is left for a later pass.
    func packArtifacts(_ id: UUID, wait: Bool) {
        // Taking the lock creates its file, so look for something to pack first.
        guard let record = try? read(id), !packableArtifacts(record).isEmpty,
              let fd = try? lock(id, wait: wait) else { return }
        defer { close(fd) }
        guard let current = try? read(id) else { return }
        for artifact in packableArtifacts(current) { TranscriptJobArtifact.pack(artifact.url, as: artifact.kind) }
    }

    /// `measured` holds the levels of PCM this preparation extracted. They describe the staged
    /// file exactly, so they take the place of any saved copy, including one measured from an
    /// earlier extraction of the same stream.
    private func prepareActivity(_ track: TranscriptJobTrack, media: MediaInfo, audio: URL, measured: [Float]?,
                                 cancelled: () -> Bool) throws -> String? {
        guard let stream = track.streamIndex, let levels = track.activity else { return nil }
        let duration = try track.duration.roundedToSamples(16_000)
        func matches(_ data: Data) -> Bool {
            TranscriptRecognitionCache.Artifacts.matchesActivity(data, evidence: track.evidence, duration: duration)
        }
        let key = TranscriptActivityKey(stream: stream, channel: track.stagedChannel)
        let sidecar = AnalysisSidecar(media: media)
        let canShare = track.hasReusableEvidence && AnalysisSidecar.readsEnabled
            && !AnalysisSidecar.isExcluded(media.url, in: AnalysisSidecar.excludedSources)
        let data: Data
        let replacing: Bool
        if let measured, let fresh = try? transcriptActivityDocument(levels: measured, duration: duration,
                                                                     evidence: track.evidence, cancelled: cancelled) {
            data = fresh
            if TranscriptJobArtifact.read(levels) != data {
                try data.write(to: levels, options: .atomic)
            }
            guard canShare && AnalysisSidecar.automaticWritesEnabled,
                  sidecar.readTranscriptActivity(key, cancelled: cancelled) != data else { return nil }
            replacing = true
        } else {
            if cancelled() { throw CancellationError() }
            if let data = TranscriptJobArtifact.read(levels), matches(data) { return nil }
            if canShare, let data = sidecar.readTranscriptActivity(key, cancelled: cancelled), matches(data) {
                try data.write(to: levels, options: .atomic)
                return nil
            }
            data = try measureTranscriptActivity(audio: audio, duration: duration,
                                                 evidence: track.evidence, cancelled: cancelled)
            try data.write(to: levels, options: .atomic)
            guard canShare && AnalysisSidecar.automaticWritesEnabled else { return nil }
            replacing = false
        }
        do {
            try sidecar.saveTranscriptActivity(data, key: key, media: media, replacing: replacing, cancelled: cancelled)
            return nil
        } catch {
            if cancelled() { throw CancellationError() }
            return "Could not share audio activity for \(track.name). The job will retain its audio levels."
        }
    }

    func writeManifest(_ session: TranscriptJobSession, job: TranscriptJobRecord,
                       reuseActivity: Set<String> = [], blockedErrors: [String: String] = [:],
                       externalCache: Bool = false, diarizationOverride: Bool? = nil) throws {
        let manifest = TranscriptHandoff(job_id: job.id.uuidString, fingerprint: session.fingerprint,
                                         engine: job.options.engine, model: job.options.model, language: job.options.language,
                                         expected_speakers: job.options.expectedSpeakers,
                                         diarization: diarizationOverride ?? job.options.diarization,
                                         output: session.output.path, tracks: try session.tracks.map { track in
            // A failed extraction has no valid WAV. Supplying the missing path leaves the failure
            // visible to the provider and preserves the track's place in the session.
            .init(track_id: track.id, source_id: track.sourceID, stream_evidence: track.evidence,
                  binding: .init(stream_index: track.streamIndex, origin: track.origin, session_start: track.sessionStart),
                  channel: track.channel, name: track.name, role: track.role, speaker: track.speaker, recognize: track.recognize,
                  start_frame: try track.sessionStart.roundedToSamples(16_000),
                  audio: !track.recognize && reuseActivity.contains(track.id) ? nil : track.audio?.path,
                  result: track.result?.path, activity: track.activity?.path,
                  recognition_key: externalCache ? nil : track.recognitionKey,
                  reuse: !externalCache && (track.state == .cached || track.state == .recognized) ? true : nil,
                  unavailable: track.unavailable ?? blockedErrors[track.id],
                  shared_cache: externalCache ? TranscriptExternalCacheDescriptor(track: track, restart: job.policy == .restart) : nil)
        })
        try encodeJob(manifest).write(to: session.manifest, options: .atomic)
    }

    public func cancel(_ id: UUID) throws -> TranscriptJobRecord {
        try stop(id, state: .cancelled)
    }

    @discardableResult
    public func cancelPendingAttachment(_ id: UUID, expectedPreparationID: UUID?) throws -> TranscriptJobRecord {
        try update(id) {
            guard $0.ownerToken == nil, $0.preparationID == expectedPreparationID, !$0.attached,
                  [.completed, .partial].contains($0.state) else { return }
            $0.state = .cancelled
            removeStagedAudio($0)
        }
    }

    public func interrupt(_ id: UUID) throws -> TranscriptJobRecord { try stop(id, state: .interrupted) }

    private func stop(_ id: UUID, state: TranscriptJobState) throws -> TranscriptJobRecord {
        _ = try recoverOwner(read(id))
        return try update(id) {
            if [.preparing, .prepared, .running].contains($0.state)
                || (state == .cancelled && $0.state == .interrupted) {
                $0.state = state
                if state == .cancelled, $0.ownerToken == nil { removeStagedAudio($0) }
            }
        }
    }

    func removeStagedAudio(_ record: TranscriptJobRecord) {
        for session in record.sessions {
            removeAbandonedScratch(in: session.manifest.deletingLastPathComponent())
            for track in session.tracks {
                if let audio = track.audio { try? FileManager.default.removeItem(at: audio) }
            }
        }
    }

    /// Removes the staged audio of each track whose result and levels are in place. A job that
    /// did not complete can be retried, and its retry reads neither again for such a track.
    /// A track that failed, or that was never reached, keeps its audio for that retry, which
    /// would otherwise decode the recording a second time. `sessions` limits this to the
    /// sessions whose provider has finished.
    func removeFinishedAudio(_ record: TranscriptJobRecord, sessions: Set<String>? = nil) {
        for session in record.sessions where sessions?.contains(session.id) ?? true {
            for track in session.tracks where [.recognized, .cached, .skipped].contains(track.state) {
                guard let audio = track.audio, FileManager.default.fileExists(atPath: audio.path),
                      hasFinishedArtifacts(track, recognitionKey: track.recognitionKey) else { continue }
                try? FileManager.default.removeItem(at: audio)
            }
        }
    }

    private func removeAbandonedScratch(in folder: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files where ["wav", "artifact"].contains(file.pathExtension) && file.lastPathComponent.hasPrefix(".") {
            let filename = file.deletingPathExtension().lastPathComponent.dropFirst()
            if UUID(uuidString: String(filename)) != nil { try? FileManager.default.removeItem(at: file) }
        }
    }

    public func retry(_ id: UUID, cancelled: @escaping @Sendable () -> Bool = { false },
                      progress: (TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
        let record = try status(id)
        guard let inputs = record.inputs else {
            throw jobError("transcript_inputs_required", "Prepare this job again from its original media or project.")
        }
        return try SidecarLocations.$projectURL.withValue(SidecarLocations.projectURL ?? record.sidecarProjectURL) {
            try prepare(inputs: inputs, documentID: record.documentID, options: record.options,
                        operationID: id, policy: .resume, cancelled: cancelled, progress: progress)
        }
    }

    public func retry(_ id: UUID, project: CutProject, relativeTo location: URL? = nil,
                      cancelled: @escaping @Sendable () -> Bool = { false }, progress: (TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
        let record = try status(id)
        return try prepare(inputs: TranscriptJobPlan.inputs(project: project, relativeTo: location),
                           documentID: record.documentID, options: record.options, operationID: id, policy: .resume,
                           allowReconfiguration: true, cancelled: cancelled, progress: progress)
    }

    public func verifiedOutputs(_ id: UUID, project: CutProject, relativeTo location: URL? = nil) throws -> [URL] {
        try verifiedDocuments(id, project: project, relativeTo: location).map(\.url)
    }

    public func verifiedDocuments(_ id: UUID, project: CutProject,
                                  relativeTo location: URL? = nil) throws -> [TranscriptJobOutput] {
        let record = try recordForVerification(id)
        let current = try TranscriptJobPlan.build(sources: TranscriptJobPlan.inputs(project: project, relativeTo: location),
                                                 options: record.options, directory: nil,
                                                 recheckAfter: sourceChangeTimes(record),
                                                 previous: record.sessions.flatMap(\.tracks), allowMissingSelections: true).sessions
        let currentFingerprints = Set(current.map(\.fingerprint))
        let recordedFingerprints = Set(record.sessions.map(\.fingerprint))
        if currentFingerprints != recordedFingerprints {
            let valid = current.filter { recordedFingerprints.contains($0.fingerprint) }
            let published = record.sessions.contains {
                currentFingerprints.contains($0.fingerprint) && FileManager.default.fileExists(atPath: $0.output.path)
            }
            switch project {
            case .sequence, .stillSequence:
                // Each ordinary recording owns an independent conversation.
                if (record.sessions.count > 1 || current.count > 1), published {
                    return try verify(record, current: valid, allowMissing: true).outputs
                }
            case .multicam: break
            }
            try update(id) {
                if $0.ownerToken == nil, $0.state != .cancelled, $0.preparationID == record.preparationID { $0.state = .stale }
            }
            throw jobError("stale_transcript_job", "Transcript tracks, synchronization or media changed. Retry with the current project.")
        }
        return try verify(record, current: current).outputs
    }

    public func verifiedOutputs(_ id: UUID, media: URL) throws -> [URL] {
        try verifiedDocuments(id, media: media).map(\.url)
    }

    public func verifiedDocuments(_ id: UUID, media: URL) throws -> [TranscriptJobOutput] {
        let record = try recordForVerification(id)
        let current = try TranscriptJobPlan.build(sources: TranscriptJobPlan.inputs(media: media), options: record.options,
                                                 directory: nil, recheckAfter: sourceChangeTimes(record),
                                                 previous: record.sessions.flatMap(\.tracks), allowMissingSelections: true).sessions
        guard current.map(\.fingerprint) == record.sessions.map(\.fingerprint) else {
            try update(id) {
                if $0.ownerToken == nil, $0.state != .cancelled, $0.preparationID == record.preparationID { $0.state = .stale }
            }
            throw jobError("stale_transcript_job", "Transcript media changed. Prepare a new request.")
        }
        return try verify(record, current: current).outputs
    }

    private func recordForVerification(_ id: UUID) throws -> TranscriptJobRecord {
        let record = try status(id)
        guard record.ownerToken == nil else {
            throw jobError("transcript_job_running", "Wait for the transcript job to finish before attaching it.")
        }
        guard record.state.permitsOutputVerification, !record.sessions.isEmpty else {
            throw jobError("transcript_job_unavailable", "This job has no current output to attach.")
        }
        return record
    }

    private func sourceChangeTimes(_ record: TranscriptJobRecord) -> [URL: String] {
        Dictionary(record.sessions.flatMap(\.tracks).compactMap { track in
            track.sourceChangeTime.map { (track.file, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func verify(_ record: TranscriptJobRecord, current: [TranscriptJobSession], allowMissing: Bool = false) throws
        -> (record: TranscriptJobRecord, outputs: [TranscriptJobOutput]) {
        var records: [String: TranscriptTrack] = [:]
        var outputs: [TranscriptJobOutput] = []
        // Sessions whose result the project already holds, and whose output was removed as a
        // copy of their track results. Their tracks keep the outcome read then.
        var attached: [TranscriptJobSession] = []
        var resolved = Set<String>()
        let requested = record.sessions.flatMap(\.tracks).contains(where: \.recognize)
        let currentFingerprints = Set(current.map(\.fingerprint))
        for session in record.sessions where currentFingerprints.contains(session.fingerprint) {
            guard let data = try? Data(contentsOf: session.output) else {
                if !FileManager.default.fileExists(atPath: session.output.path) {
                    if record.attached, holdsOutputAsCopy(session) {
                        attached.append(session)
                        resolved.insert(session.id)
                        continue
                    }
                    if allowMissing || [.prepared, .partial].contains(record.state) { continue }
                }
                throw jobError("transcript_job_unavailable", "Session output is missing. Run the prepared manifest with Transcriberrr.")
            }
            let result = try TranscriptCodec.decode(data, format: .json)
            let expected = Dictionary(uniqueKeysWithValues: session.tracks.map { ($0.id, $0) })
            guard result.clock == .session, result.jobID.flatMap(UUID.init(uuidString:)) == record.id,
                  result.fingerprint == session.fingerprint,
                  Set(result.tracks.map(\.id)) == Set(expected.keys) else {
                throw jobError("invalid_transcript_result", "The transcript output is for a different prepared session.")
            }
            for track in result.tracks {
                guard let input = expected[track.id], track.streamIndex == input.streamIndex,
                      track.sourceID == input.sourceID, track.channel == input.channel, track.origin == input.origin,
                      track.sessionStart == input.sessionStart, track.role.rawValue == input.role,
                      track.streamEvidence == .string(input.evidence), input.acceptsCoverage(track.coverage) else {
                    throw jobError("invalid_transcript_result", "The transcript returned different track bindings.")
                }
                records[track.id] = track
            }
            outputs.append(.init(url: session.output, document: result, preparationID: record.preparationID))
            resolved.insert(session.id)
        }
        if outputs.isEmpty, !attached.isEmpty {
            throw jobError("transcript_output_removed", "The transcript from this job is already attached, and the session "
                           + "output it was read from has been removed. Retry the job to produce the output again.")
        }
        let earlier = attached.flatMap(\.tracks)
        guard !outputs.isEmpty,
              records.values.contains(where: { $0.coverage != .failed }) || earlier.contains(where: { $0.state != .failed }),
              !requested || records.values.contains(where: { $0.coverage == .recognized })
                || earlier.contains(where: { [.recognized, .cached].contains($0.state) }) else {
            throw jobError("transcript_job_unavailable", "No transcript session completed successfully.")
        }
        let currentStamps = Dictionary(uniqueKeysWithValues: current.flatMap(\.tracks).compactMap { track in track.sourceStamp.map { (track.id, $0) } })
        let finished = try update(record.id) {
            guard $0.state.permitsOutputVerification,
                  $0.preparationID == record.preparationID,
                  $0.sessions.map(\.fingerprint) == record.sessions.map(\.fingerprint),
                  current.flatMap(\.tracks).allSatisfy(\.sourceIsCurrent) else {
                throw jobError("stale_transcript_job", "The transcript job changed during verification.")
            }
            guard $0.ownerToken == nil else {
                throw jobError("transcript_job_running", "Wait for the transcript job to finish before attaching it.")
            }
            $0.state = outputs.count + attached.count < record.sessions.count
                || records.values.contains { $0.coverage == .failed } || earlier.contains { $0.state == .failed }
                ? .partial : .completed
            if allowMissing {
                let warning = "Some independent sessions could not be attached because their recordings changed or became unavailable."
                if !$0.warnings.contains(warning) { $0.warnings.append(warning) }
            }
            for session in $0.sessions.indices {
                for index in $0.sessions[session].tracks.indices {
                    var track = $0.sessions[session].tracks[index]
                    guard let output = records[track.id] else {
                        if allowMissing, !currentFingerprints.contains($0.sessions[session].fingerprint) {
                            track.state = .failed
                            track.message = "The recording changed or became unavailable."
                            $0.sessions[session].tracks[index] = track
                        }
                        continue
                    }
                    if track.state != .cached || output.coverage != .recognized {
                        track.state = TranscriptJobTrackState(rawValue: output.coverage.rawValue) ?? .failed
                    }
                    track.message = output.error ?? output.warning
                    if let stamp = currentStamps[track.id] {
                        track.sourceStamp = stamp
                        track.sourceChangeTime = stamp.transcriptJobChangeTime
                    }
                    $0.sessions[session].tracks[index] = track
                }
            }
            // A session not yet recognized keeps every recording its manifest names.
            if $0.state == .completed { removeStagedAudio($0) } else { removeFinishedAudio($0, sessions: resolved) }
        }
        let recognizedIDs = Set(records.values.filter { $0.coverage == .recognized }.map(\.id))
        TranscriptRecognitionCache.promoteExternal(in: finished, stamps: currentStamps, recognizedIDs: recognizedIDs)
        // Nothing reads a finished track's files again before a retry, which restores them.
        packArtifacts(record.id, wait: true)
        return (finished, outputs)
    }
}

extension SourceIdentity {
    var transcriptJobChangeTime: String? {
        changeTime.map { "\($0.seconds):\($0.nanoseconds)" }
    }
}

func encodeJob<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func jobError(_ code: String, _ message: String) -> CutError { CutError(code: code, message: message) }

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
