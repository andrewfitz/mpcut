import Foundation

public struct MulticamRange: Codable, Hashable, Sendable {
    public var from: RationalTime
    public var to: RationalTime

    public init(from: RationalTime, to: RationalTime) {
        self.from = from
        self.to = to
    }

    public func contains(_ time: RationalTime) -> Bool {
        from <= time && time < to
    }

    private enum CodingKeys: String, CodingKey { case from, to }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(from: try ProjectField.time(values, .from), to: try ProjectField.time(values, .to))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(from.description, forKey: .from)
        try values.encode(to.description, forKey: .to)
    }
}

public struct MulticamSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var file: String
    public var offset: RationalTime
    public var name: String?
    public var audioStream: Int?
    public var coverage: MulticamRange?
    public var additionalRecordings: [MulticamSource]

    public init(id: String, file: String, offset: RationalTime = .zero,
                name: String? = nil, audioStream: Int? = nil, coverage: MulticamRange? = nil,
                additionalRecordings: [MulticamSource] = []) {
        self.id = id
        self.file = file
        self.offset = offset
        self.name = name
        self.audioStream = audioStream
        self.coverage = coverage
        self.additionalRecordings = additionalRecordings
    }

    private enum CodingKeys: String, CodingKey {
        case id, file, offset, name, coverage = "group_coverage", additionalRecordings = "additional_recordings"
        case audioStream = "audio_stream_index"
    }

    /// Physical files are independent sources for indexing, audio selection and export.
    public var recordings: [MulticamSource] {
        var primary = self
        primary.additionalRecordings = []
        return [primary] + additionalRecordings
    }

    package func mappingFiles(_ map: (String) -> String) -> Self {
        var result = self
        result.file = map(file)
        result.additionalRecordings = additionalRecordings.map { $0.mappingFiles(map) }
        return result
    }

    private struct Recording: Decodable {
        let value: MulticamSource

        init(from decoder: Decoder) throws {
            value = try MulticamSource(from: decoder, allowAdditional: false)
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, allowAdditional: true)
    }

    private init(from decoder: Decoder, allowAdditional: Bool) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let coverage = try values.contains(.coverage) ? values.decode(MulticamRange.self, forKey: .coverage) : nil
        let recordings: [Recording]
        if values.contains(.additionalRecordings) {
            guard allowAdditional else {
                throw CutError(code: "invalid_multicam_project", message: "A recording cannot contain other recordings.")
            }
            recordings = try values.decode([Recording].self, forKey: .additionalRecordings)
            guard !recordings.isEmpty else {
                throw CutError(code: "invalid_multicam_project", message: "Additional recordings must contain at least one item.")
            }
        } else { recordings = [] }
        if (!allowAdditional || !recordings.isEmpty) && coverage == nil {
            throw CutError(code: "invalid_multicam_project", message: "Each recording on a multi-file camera needs group coverage.")
        }
        self.init(id: try values.decode(String.self, forKey: .id),
                  file: try values.decode(String.self, forKey: .file),
                  offset: try ProjectField.time(values, .offset, default: "0"),
                  name: try values.decodeIfPresent(String.self, forKey: .name),
                  audioStream: try values.decodeIfPresent(Int.self, forKey: .audioStream),
                  coverage: coverage, additionalRecordings: recordings.map(\.value))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(file, forKey: .file)
        try values.encode(offset.description, forKey: .offset)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encodeIfPresent(audioStream, forKey: .audioStream)
        try values.encodeIfPresent(coverage, forKey: .coverage)
        if !additionalRecordings.isEmpty { try values.encode(additionalRecordings, forKey: .additionalRecordings) }
    }
}

public struct MulticamAudioSelection: Codable, Hashable, Sendable {
    public var source: String
    public var stream: Int

    public init(source: String, stream: Int) {
        self.source = source
        self.stream = stream
    }

    private enum CodingKeys: String, CodingKey { case source = "source_id", stream = "audio_stream_index" }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try values.decode(String.self, forKey: .source),
                  stream: try values.decode(Int.self, forKey: .stream))
    }
}

public enum MulticamAudioPolicy: Codable, Hashable, Sendable {
    case fixed(MulticamAudioSelection)
    case follow
    case mix
    case none

    private enum CodingKeys: String, CodingKey { case mode, source = "source_id", stream = "audio_stream_index" }
    private enum Mode: String, Codable { case fixed, follow, mix, none }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try values.decode(Mode.self, forKey: .mode)
        if mode == .fixed {
            self = .fixed(.init(source: try values.decode(String.self, forKey: .source),
                                stream: try values.decode(Int.self, forKey: .stream)))
        } else {
            guard !values.contains(.source), !values.contains(.stream) else {
                throw CutError(code: "invalid_multicam_project",
                               message: "Only fixed audio accepts a project-wide source and stream")
            }
            switch mode {
            case .follow: self = .follow
            case .mix: self = .mix
            case .none: self = .none
            case .fixed: preconditionFailure("Handled fixed audio")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fixed(let selection):
            try values.encode(Mode.fixed, forKey: .mode)
            try values.encode(selection.source, forKey: .source)
            try values.encode(selection.stream, forKey: .stream)
        case .follow: try values.encode(Mode.follow, forKey: .mode)
        case .mix: try values.encode(Mode.mix, forKey: .mode)
        case .none: try values.encode(Mode.none, forKey: .mode)
        }
    }
}

public struct MulticamSwitch: Codable, Hashable, Sendable {
    public var at: RationalTime
    public var angle: String
    public var audio: MulticamAudioSelection?

    public init(at: RationalTime, angle: String, audio: MulticamAudioSelection? = nil) {
        self.at = at
        self.angle = angle
        self.audio = audio
    }

    private enum CodingKeys: String, CodingKey { case at = "group_time", angle = "angle_id", audio }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(at: try ProjectField.time(values, .at),
                  angle: try values.decode(String.self, forKey: .angle),
                  audio: try values.decodeIfPresent(MulticamAudioSelection.self, forKey: .audio))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(at.description, forKey: .at)
        try values.encode(angle, forKey: .angle)
        try values.encodeIfPresent(audio, forKey: .audio)
    }
}

public struct MulticamProject: Codable, Equatable, Sendable {
    public static let schemaVersion = CutProject.schemaVersion
    public var referenceAngle: String
    public var range: MulticamRange
    public var angles: [MulticamSource]
    public var audioSources: [MulticamSource]
    public var audio: MulticamAudioPolicy {
        didSet { if case .fixed(let selection) = audio { fixedAudio = selection } }
    }
    public var fixedAudio: MulticamAudioSelection?
    public var mixLanes: [MulticamAudioLane]
    public var audioReplacements: [MulticamAudioReplacement]
    public var switches: [MulticamSwitch]
    public var assemblyItems: [StillAssemblyItem]?
    public var stillAssets: [StillAsset]
    public var stillReplacements: [StillReplacement]
    public var programColorPolicy: StillProgramColorPolicy?
    public var transcripts: ProjectTranscripts
    public var participants: ParticipantProject

    /// Group ranges for clients that only work in group coordinates.
    public var assembly: [MulticamRange]? {
        get { assemblyItems?.compactMap(\.group) }
        set { assemblyItems = newValue?.map { .group($0) } }
    }

    var hasStillContent: Bool {
        !stillAssets.isEmpty || !stillReplacements.isEmpty || programColorPolicy != nil
            || (assemblyItems?.contains { $0.still != nil } ?? false)
    }

    public var pictureSources: [MulticamSource] { angles.flatMap(\.recordings) }
    public var sources: [MulticamSource] { pictureSources + audioSources }

    public func recordings(for angle: String) -> [MulticamSource] {
        angles.first { $0.id == angle }?.recordings ?? []
    }

    public func pictureSource(for angle: String, at time: RationalTime, exclusiveEnd: Bool = false) -> MulticamSource? {
        guard var primary = angles.first(where: { $0.id == angle }) else { return nil }
        func contains(_ source: MulticamSource) -> Bool {
            guard let coverage = source.coverage else { return true }
            return exclusiveEnd ? coverage.from < time && time <= coverage.to : coverage.contains(time)
        }
        if contains(primary) {
            primary.additionalRecordings = []
            return primary
        }
        return primary.additionalRecordings.first(where: contains)
    }

    /// Place the visible picture start of a new recording at an exact group time.
    package mutating func addRecording(id: String, media: MediaInfo, to angle: String, at start: RationalTime,
                                       primaryMedia: MediaInfo?) throws {
        guard let index = angles.firstIndex(where: { $0.id == angle }) else {
            throw Self.invalid("Unknown angle ‘\(angle)’")
        }
        func bounds(_ media: MediaInfo) throws -> MulticamRange {
            guard let video = media.videoStream else { throw Self.invalid("Camera recordings need a video track") }
            let from = media.frames.first?.time ?? video.start
            let to = try media.frames.last.map { try $0.time.adding($0.duration) } ?? media.duration
            guard from < to else { throw Self.invalid("Camera recording has no picture coverage") }
            return .init(from: from, to: to)
        }
        var camera = angles[index]
        if camera.coverage == nil {
            guard let primaryMedia else { throw Self.invalid("Load the first recording before adding another") }
            let extent = try bounds(primaryMedia)
            camera.coverage = try .init(from: camera.offset.adding(extent.from), to: camera.offset.adding(extent.to))
        }
        let extent = try bounds(media)
        let end = try start.adding(extent.to.subtracting(extent.from))
        camera.additionalRecordings.append(try .init(id: id, file: media.url.path, offset: start.subtracting(extent.from),
            audioStream: media.audio.first?.stream.index, coverage: .init(from: start, to: end)))
        camera.additionalRecordings.sort { $0.coverage!.from < $1.coverage!.from }
        var updated = self
        updated.angles[index] = camera
        updated.range.to = max(range.to, end)
        try updated.validate()
        self = updated
    }

    public init(referenceAngle: String, range: MulticamRange, angles: [MulticamSource],
                audioSources: [MulticamSource] = [], audio: MulticamAudioPolicy,
                switches: [MulticamSwitch], assembly: [MulticamRange]? = nil,
                assemblyItems: [StillAssemblyItem]? = nil, stillAssets: [StillAsset] = [],
                stillReplacements: [StillReplacement] = [], programColorPolicy: StillProgramColorPolicy? = nil,
                transcripts: ProjectTranscripts = .init(), fixedAudio: MulticamAudioSelection? = nil,
                mixLanes: [MulticamAudioLane] = [], audioReplacements: [MulticamAudioReplacement] = [],
                participants: ParticipantProject = .init()) {
        self.referenceAngle = referenceAngle
        self.range = range
        self.angles = angles
        self.audioSources = audioSources
        self.audio = audio
        if case .fixed(let selection) = audio { self.fixedAudio = fixedAudio ?? selection }
        else { self.fixedAudio = fixedAudio }
        self.mixLanes = mixLanes
        self.audioReplacements = audioReplacements
        self.switches = switches
        self.assemblyItems = assemblyItems ?? assembly?.map { .group($0) }
        self.stillAssets = stillAssets
        self.stillReplacements = stillReplacements
        self.programColorPolicy = programColorPolicy
        self.transcripts = transcripts
        self.participants = participants
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case kind
        case referenceAngle = "reference_angle_id"
        case range = "group_range"
        case angles
        case audioSources = "audio_sources"
        case audio, switches, assembly, history
        case fixedAudio = "fixed_audio"
        case mixLanes = "mix_lanes"
        case audioReplacements = "audio_replacements"
        case stillAssets = "still_assets"
        case stillReplacements = "still_replacements"
        case programColorPolicy = "program_color_policy"
        case transcripts, participants
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == CutProject.format else {
            throw Self.invalid("Expected an MPCut project document")
        }
        guard let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion),
              CutProject.readableSchemaVersions.contains(version) else {
            throw CutError(code: "unsupported_multicam_version", message: "Expected MPCut project schema_version 3 or \(Self.schemaVersion)")
        }
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let mixFields: [CodingKeys] = [.fixedAudio, .mixLanes, .audioReplacements]
        let policy = try values.decode(MulticamAudioPolicy.self, forKey: .audio)
        if version == 3, policy == .mix || mixFields.contains(where: values.contains) {
            throw Self.invalid("Mix audio fields require project schema version 4")
        }
        let optionalFields: [CodingKeys] = [.stillAssets, .stillReplacements, .programColorPolicy, .assembly] + mixFields
        for key in optionalFields where values.contains(key) {
            guard try !values.decodeNil(forKey: key) else {
                throw Self.invalid("Null value in multicam field ‘\(key.stringValue)’")
            }
        }
        guard try values.decode(String.self, forKey: .kind) == "multicam" else {
            throw Self.invalid("Expected a multicam project")
        }
        self.init(referenceAngle: try values.decode(String.self, forKey: .referenceAngle),
                  range: try values.decode(MulticamRange.self, forKey: .range),
                  angles: try values.decode([MulticamSource].self, forKey: .angles),
                  audioSources: try values.decodeIfPresent([MulticamSource].self, forKey: .audioSources) ?? [],
                  audio: policy,
                  switches: try values.decode([MulticamSwitch].self, forKey: .switches),
                  assemblyItems: try values.decodeIfPresent([StillAssemblyItem].self, forKey: .assembly),
                  stillAssets: try values.decodeIfPresent([StillAsset].self, forKey: .stillAssets) ?? [],
                  stillReplacements: try values.decodeIfPresent([StillReplacement].self, forKey: .stillReplacements) ?? [],
                  programColorPolicy: try values.decodeIfPresent(StillProgramColorPolicy.self, forKey: .programColorPolicy),
                  fixedAudio: try values.decodeIfPresent(MulticamAudioSelection.self, forKey: .fixedAudio),
                  mixLanes: try values.decodeIfPresent([MulticamAudioLane].self, forKey: .mixLanes) ?? [],
                  audioReplacements: try values.decodeIfPresent([MulticamAudioReplacement].self, forKey: .audioReplacements) ?? [])
        if values.contains(.transcripts) {
            transcripts = try values.decode(ProjectTranscripts.self, forKey: .transcripts)
        }
        if values.contains(.participants) {
            guard version >= 4 else { throw invalidParticipantProject("Participant metadata requires project schema version 4.") }
            participants = try values.decode(ParticipantProject.self, forKey: .participants)
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(CutProject.format, forKey: .format)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode("multicam", forKey: .kind)
        if !transcripts.isEmpty { try values.encode(transcripts, forKey: .transcripts) }
        if !participants.isEmpty { try values.encode(participants, forKey: .participants) }
        try values.encode(referenceAngle, forKey: .referenceAngle)
        try values.encode(range, forKey: .range)
        try values.encode(angles, forKey: .angles)
        if !audioSources.isEmpty { try values.encode(audioSources, forKey: .audioSources) }
        try values.encode(audio, forKey: .audio)
        try values.encodeIfPresent(fixedAudio, forKey: .fixedAudio)
        if !mixLanes.isEmpty { try values.encode(mixLanes, forKey: .mixLanes) }
        if !audioReplacements.isEmpty { try values.encode(audioReplacements, forKey: .audioReplacements) }
        try values.encode(switches, forKey: .switches)
        try values.encodeIfPresent(assemblyItems, forKey: .assembly)
        if !stillAssets.isEmpty { try values.encode(stillAssets, forKey: .stillAssets) }
        if !stillReplacements.isEmpty { try values.encode(stillReplacements, forKey: .stillReplacements) }
        try values.encodeIfPresent(programColorPolicy, forKey: .programColorPolicy)
    }

    /// Media stream indices are 32-bit.
    private static let streamIndices = 0...Int(Int32.max)

    /// The largest project document `load` reads, matching the CLI's request limit.
    public static let maximumFileSize = 64 * 1024 * 1024

    public static func load(from url: URL) throws -> Self {
        try Self.decode(ProjectFile.readBytes(from: url, multicam: true))
    }

    public static func decode(_ data: Data) throws -> Self {
        try CutProject.decodeMulticamDocument(data)
    }

    public func save(to url: URL) throws {
        if transcripts.isEmpty, !TranscriptStore.hasStore(relativeTo: url) {
            try ProjectFile.write(self, to: url, sources: CutProject.multicam(self).mediaPaths, multicam: true)
        } else {
            let data = try ProjectFile.encoded(self, compact: false)
            _ = try ProjectFile.writeRevision(data, to: url, sources: CutProject.multicam(self).mediaPaths, prefix: "multicam",
                                              replacingExisting: true, expected: nil,
                                              transcriptAssets: transcripts.attachments.map(\.asset),
                                              hasTranscriptMetadata: !transcripts.isEmpty)
        }
    }

    public func sourceURL(for source: MulticamSource, relativeTo projectURL: URL) -> URL {
        sourceURL(for: source, in: ProjectFile.directory(of: projectURL))
    }

    func sourceURL(for source: MulticamSource, in directory: URL) -> URL {
        ProjectFile.sourceURL(file: source.file, in: directory)
    }

    public func validate() throws {
        try transcripts.validate()
        try participants.validate()
        guard range.from == .zero, range.to > range.from else {
            throw Self.invalid("The group must start at zero and have a positive duration")
        }
        for angle in angles where !angle.additionalRecordings.isEmpty {
            guard angle.recordings.allSatisfy({ $0.coverage != nil && $0.additionalRecordings.isEmpty }) else {
                throw Self.invalid("Each recording on angle ‘\(angle.id)’ needs coverage and cannot contain other recordings")
            }
            let ordered = angle.recordings.compactMap(\.coverage).sorted { $0.from < $1.from }
            guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.to <= $1.from }) else {
                throw Self.invalid("Recordings on angle ‘\(angle.id)’ overlap")
            }
        }
        guard audioSources.allSatisfy({ $0.additionalRecordings.isEmpty && $0.coverage == nil }) else {
            throw Self.invalid("Additional recordings and group coverage apply only to cameras")
        }
        var sourceIDs = Set<String>()
        for source in sources {
            guard !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !source.file.isEmpty, !source.file.contains("\0") else {
                throw Self.invalid("Each source needs a nonempty ID and file path")
            }
            guard ProjectFile.validMediaPath(source.file) else {
                throw Self.invalid("Source ‘\(source.id)’ must name a recording file")
            }
            guard sourceIDs.insert(source.id).inserted else {
                throw Self.invalid("Repeated source ID ‘\(source.id)’")
            }
            if let coverage = source.coverage, !(source.offset <= coverage.from && coverage.from < coverage.to) {
                throw Self.invalid("Source ‘\(source.id)’ must have positive coverage at or after its offset")
            }
            if let stream = source.audioStream, !Self.streamIndices.contains(stream) {
                throw Self.invalid("Source ‘\(source.id)’ has an audio stream index outside 0 to \(Int32.max)")
            }
        }
        let angleIDs = Set(angles.map(\.id))
        guard angleIDs.contains(referenceAngle) else {
            throw Self.invalid("Unknown reference angle ‘\(referenceAngle)’")
        }
        func validateAudio(_ selection: MulticamAudioSelection) throws {
            guard sourceIDs.contains(selection.source), Self.streamIndices.contains(selection.stream) else {
                throw Self.invalid("Invalid audio selection ‘\(selection.source)’ stream \(selection.stream)")
            }
        }
        if let fixedAudio { try validateAudio(fixedAudio) }
        if case .fixed(let master) = audio {
            try validateAudio(master)
            guard fixedAudio == master else { throw Self.invalid("Fixed audio must match the saved Fixed selection") }
        }
        if audio == .mix, mixLanes.isEmpty { throw Self.invalid("Mix needs at least one selected audio lane") }
        let recordings = Dictionary(uniqueKeysWithValues: pictureSources.map { ($0.id, $0) })
        let external = Set(audioSources.map(\.id))
        var bindings = [MulticamAudioSelection: MulticamAudioReplacement]()
        var bindingIDs = Set<String>()
        let directSources = directAudioSourceIDs
        for binding in audioReplacements {
            try validateAudio(binding.original)
            try validateAudio(binding.replacement)
            guard !directSources.contains(binding.replacement.source) else {
                throw Self.invalid("Audio source ‘\(binding.replacement.source)’ is bound to replacement ‘\(binding.id)’ and cannot be routed directly. Use a separate source ID for a direct route.")
            }
            guard !binding.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bindingIDs.insert(binding.id).inserted,
                  recordings[binding.original.source] != nil,
                  external.contains(binding.replacement.source),
                  bindings.updateValue(binding, forKey: binding.original) == nil else {
                throw Self.invalid("Invalid or duplicate audio replacement binding ‘\(binding.id)’")
            }
        }
        var laneIDs = Set<String>()
        var targets = Set<MulticamAudioLaneTarget>()
        var selectedPlacements = Set<AudioPlacement>()
        let sourceOffsets = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.offset) })
        for lane in mixLanes {
            guard !lane.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !lane.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (0..<MulticamAudioLane.colorSlotCount).contains(lane.colorSlot),
                  laneIDs.insert(lane.id).inserted, targets.insert(lane.target).inserted else {
                throw Self.invalid("Invalid or duplicate Mix lane ‘\(lane.id)’")
            }
            let selections: [MulticamAudioSelection]
            switch lane.target {
            case .camera(let angle):
                guard angleIDs.contains(angle) else { throw Self.invalid("Unknown Mix lane angle ‘\(angle)’") }
                selections = self.recordings(for: angle).compactMap { recording in
                    recording.audioStream.map { .init(source: recording.id, stream: $0) }
                }
            case .recording(let selection):
                try validateAudio(selection)
                selections = [selection]
            }
            var placements = Set<AudioPlacement>()
            for selection in selections {
                let offset = sourceOffsets[selection.source]!
                placements.insert(AudioPlacement(selection: selection, offset: offset))
                if let binding = bindings[selection] {
                    placements.insert(try AudioPlacement(selection: binding.replacement,
                                                         offset: offset.adding(binding.relativeOffset)))
                }
            }
            guard selectedPlacements.isDisjoint(with: placements) else {
                throw Self.invalid("Mix lane ‘\(lane.label)’ duplicates a source, stream and placement")
            }
            selectedPlacements.formUnion(placements)
        }
        guard switches.first?.at == range.from else {
            throw Self.invalid("A switch is required at the start of the group")
        }
        var previous: RationalTime?
        for marker in switches {
            guard angleIDs.contains(marker.angle) else {
                throw Self.invalid("Unknown angle ‘\(marker.angle)’ at \(marker.at)")
            }
            guard range.contains(marker.at), previous.map({ $0 < marker.at }) ?? true else {
                throw Self.invalid("Switch time \(marker.at) is out of range or not strictly increasing")
            }
            previous = marker.at
            if let override = marker.audio { try validateAudio(override) }
        }
        if let assemblyItems {
            guard !assemblyItems.isEmpty else { throw Self.invalid("Assembly must contain at least one item") }
            for item in assemblyItems {
                if let angle = item.angleOverride, !angleIDs.contains(angle) {
                    throw Self.invalid("Unknown assembly picture angle ‘\(angle)’")
                }
            }
            let ranges = assemblyItems.compactMap(\.group)
            if !ranges.isEmpty { try validateRanges(ranges) }
        }
        try validateStillCollections(assets: stillAssets, inserts: assemblyItems?.compactMap(\.still) ?? [],
                                     replacements: stillReplacements, color: programColorPolicy, group: range)
        if hasStillContent { _ = try CutProject.multicam(self).stillTimelineDuration() }
    }

    private struct AudioPlacement: Hashable {
        let selection: MulticamAudioSelection
        let offset: RationalTime
    }

    private func validateRanges(_ ranges: [MulticamRange]) throws {
        guard !ranges.isEmpty else { throw Self.invalid("Assembly must contain at least one range") }
        var duration = RationalTime.zero
        for (index, requested) in ranges.enumerated() {
            guard range.contains(requested.from), requested.from < requested.to,
                  requested.to <= range.to else {
                throw Self.invalid("Assembly range \(index + 1) (\(requested.from)–\(requested.to)) lies outside the group or is empty")
            }
            duration = try duration.adding(requested.to.subtracting(requested.from))
        }
    }

    private static func invalid(_ message: String) -> CutError {
        CutError(code: "invalid_multicam_project", message: message)
    }

    public func selection(at time: RationalTime) -> MulticamSwitch? {
        guard range.contains(time), let index = switchIndex(at: time) else { return nil }
        return switches[index]
    }

    private func switchIndex(at time: RationalTime) -> Int? {
        var low = 0
        var high = switches.count
        while low < high {
            let middle = low + (high - low) / 2
            if switches[middle].at <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    public func groupIntervals() throws -> [MulticamInterval] {
        try plan(ranges: [range]).intervals
    }

    /// Explicit ranges address group time and take precedence over the saved assembly.
    public func plan(ranges: [MulticamRange]? = nil) throws -> MulticamPlan {
        try validate()
        if let ranges { try validateRanges(ranges) }
        let items = ranges.map { $0.map { .group($0) } } ?? assemblyItems ?? [.group(range)]
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let recordingsByAngle = Dictionary(uniqueKeysWithValues: angles.map { angle in
            (angle.id, angle.recordings.sorted { ($0.coverage?.from ?? .zero) < ($1.coverage?.from ?? .zero) })
        })
        func route(_ angle: String, at time: RationalTime) -> (source: MulticamSource?, nextBoundary: RationalTime?) {
            let files = recordingsByAngle[angle]!
            if files.count == 1, files[0].coverage == nil { return (files[0], nil) }
            let next = files.lowerBound { $0.coverage!.to > time }
            guard files.indices.contains(next), let coverage = files[next].coverage else { return (nil, nil) }
            return time < coverage.from ? (nil, coverage.from) : (files[next], coverage.to)
        }
        var intervals: [MulticamInterval] = []
        var picture: [MulticamSpan] = []
        var sound: [MulticamSpan] = []
        var mixRanges: [(group: MulticamRange, outputStart: RationalTime)] = []
        var outputStart = RationalTime.zero

        for (assemblyIndex, item) in items.enumerated() {
            guard let requested = item.group else {
                if let insert = item.still { outputStart = try outputStart.adding(insert.duration) }
                continue
            }
            guard var markerIndex = switchIndex(at: requested.from) else {
                throw Self.invalid("No active switch at \(requested.from)")
            }
            // Picture switches subdivide the group, but only assembly edits and
            // the lane's own recording boundaries affect Mix audio.
            if audio == .mix { mixRanges.append((requested, outputStart)) }
            var start = requested.from
            while start < requested.to {
                let marker = switches[markerIndex]
                let markerEnd = markerIndex + 1 < switches.count
                    ? min(requested.to, switches[markerIndex + 1].at) : requested.to
                let pictureAngle = item.angleOverride ?? marker.angle
                let video = route(pictureAngle, at: start)
                let follow = marker.audio == nil && audio == .follow
                    ? (pictureAngle == marker.angle ? video : route(marker.angle, at: start)) : (nil, nil)
                let end = min(markerEnd, video.nextBoundary ?? markerEnd, follow.1 ?? markerEnd)
                let chosenPicture = video.source
                let followSource = follow.0
                let selectedAudio: MulticamAudioSelection?
                if audio == .mix { selectedAudio = nil }
                else if let override = marker.audio { selectedAudio = override }
                else if case .fixed(let master) = audio { selectedAudio = master }
                else { selectedAudio = followSource.flatMap { source in source.audioStream.map { .init(source: source.id, stream: $0) } } }
                let outputEnd = try outputStart.adding(end.subtracting(start))
                let group = MulticamRange(from: start, to: end)
                let output = MulticamRange(from: outputStart, to: outputEnd)
                let continuesGroup = intervals.last?.group.to == start
                intervals.append(.init(group: group, output: output, angle: pictureAngle, pictureSourceID: chosenPicture?.id,
                                       audio: selectedAudio, assemblyIndex: assemblyIndex, startsAtSwitch: start == marker.at))
                if let chosenPicture {
                    try Self.appendSpan(source: chosenPicture, stream: nil, group: group, output: output,
                                        continuesGroup: continuesGroup, to: &picture)
                }
                if let selectedAudio {
                    try Self.appendSpan(source: sourcesByID[selectedAudio.source]!, stream: selectedAudio.stream,
                                        group: group, output: output, continuesGroup: continuesGroup, to: &sound)
                }
                if end == markerEnd { markerIndex += 1 }
                start = end
                outputStart = outputEnd
            }
        }
        guard audio == .mix else {
            var gaps: [MulticamRange] = []
            if audio != .none || !sound.isEmpty {
                for interval in intervals where interval.audio == nil {
                    Self.appendGap(interval.output, to: &gaps)
                }
            }
            let lanes: [MulticamPlannedAudioLane] = audio == .none && sound.isEmpty ? [] :
                [.init(id: MulticamPlan.programAudioLaneID, label: "Program audio", spans: sound, gaps: gaps)]
            return .init(intervals: intervals, picture: picture, audioLanes: lanes, duration: outputStart)
        }
        let lanes = try mixLanes.map { lane in
            var planned = MulticamPlannedAudioLane(id: lane.id, label: lane.label, colorSlot: lane.colorSlot, spans: [])
            for (group, outputStart) in mixRanges {
                var start = group.from
                var from = outputStart
                while start < group.to {
                    let source: MulticamSource?
                    let stream: Int?
                    let boundary: RationalTime?
                    switch lane.target {
                    case .camera(let angle):
                        (source, boundary) = route(angle, at: start)
                        stream = source?.audioStream
                    case .recording(let selection):
                        let pinned = sourcesByID[selection.source]!
                        if let coverage = pinned.coverage, !coverage.contains(start) {
                            source = nil
                            boundary = start < coverage.from ? coverage.from : nil
                        } else {
                            source = pinned
                            boundary = pinned.coverage?.to
                        }
                        stream = selection.stream
                    }
                    let end = min(group.to, boundary ?? group.to)
                    let to = try from.adding(end.subtracting(start))
                    let output = MulticamRange(from: from, to: to)
                    if let source, let stream {
                        let input = try MulticamRange(from: start.subtracting(source.offset), to: end.subtracting(source.offset))
                        MulticamSpan(source: source.id, stream: stream, input: input, output: output)
                            .appendCoalescing(to: &planned.spans)
                    } else {
                        Self.appendGap(output, to: &planned.gaps)
                    }
                    start = end
                    from = to
                }
            }
            return planned
        }
        return .init(intervals: intervals, picture: picture, audioLanes: lanes, duration: outputStart)
    }

    private static func appendGap(_ range: MulticamRange, to gaps: inout [MulticamRange]) {
        if let index = gaps.indices.last, gaps[index].to == range.from {
            gaps[index].to = range.to
        } else {
            gaps.append(range)
        }
    }

    private static func appendSpan(source: MulticamSource, stream: Int?, group: MulticamRange,
                                   output: MulticamRange, continuesGroup: Bool, to spans: inout [MulticamSpan]) throws {
        do {
            if continuesGroup, let index = spans.indices.last, spans[index].source == source.id,
               spans[index].stream == stream, spans[index].output.to == output.from {
                // A source has one offset, so the previous input end already represents this start.
                spans[index].input.to = try group.to.subtracting(source.offset)
                spans[index].output.to = output.to
                return
            }
            let input = try MulticamRange(from: group.from.subtracting(source.offset),
                                          to: group.to.subtracting(source.offset))
            spans.append(MulticamSpan(source: source.id, stream: stream, input: input, output: output))
        } catch let issue as CutError where issue.code == "time_overflow" {
            throw CutError(code: issue.code,
                           message: "Source \(source.id): offset \(source.offset) places the recording outside the supported time range.")
        }
    }
}

public struct MulticamInterval: Codable, Equatable, Sendable {
    public let group: MulticamRange
    public let output: MulticamRange
    public let angle: String
    public let pictureSourceID: String?
    package let startsAtSwitch: Bool?
    public let audio: MulticamAudioSelection?
    public let assemblyIndex: Int

    public init(group: MulticamRange, output: MulticamRange, angle: String,
                audio: MulticamAudioSelection?, assemblyIndex: Int) {
        self.init(group: group, output: output, angle: angle, pictureSourceID: angle, audio: audio, assemblyIndex: assemblyIndex)
    }

    public init(group: MulticamRange, output: MulticamRange, angle: String, pictureSourceID: String?,
                audio: MulticamAudioSelection?, assemblyIndex: Int, startsAtSwitch: Bool? = nil) {
        self.group = group
        self.startsAtSwitch = startsAtSwitch
        self.pictureSourceID = pictureSourceID
        self.output = output
        self.angle = angle
        self.audio = audio
        self.assemblyIndex = assemblyIndex
    }
}

public struct MulticamSpan: Codable, Equatable, Sendable {
    public let source: String
    public let stream: Int?
    public var input: MulticamRange
    public var output: MulticamRange
    public let replacementBindingID: String?

    public init(source: String, stream: Int?, input: MulticamRange, output: MulticamRange,
                replacementBindingID: String? = nil) {
        self.source = source
        self.stream = stream
        self.replacementBindingID = replacementBindingID
        self.input = input
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case source, stream, input, output, replacementBindingID = "replacement_binding_id"
    }

    public func appendCoalescing(to spans: inout [Self]) {
        if let index = spans.indices.last, spans[index].source == source,
           spans[index].stream == stream, spans[index].replacementBindingID == replacementBindingID,
           spans[index].input.to == input.from,
           spans[index].output.to == output.from {
            spans[index].input.to = input.to
            spans[index].output.to = output.to
        } else {
            spans.append(self)
        }
    }
}

public struct MulticamPlan: Codable, Equatable, Sendable {
    public static let programAudioLaneID = "program"
    public let intervals: [MulticamInterval]
    public let picture: [MulticamSpan]
    public let audioLanes: [MulticamPlannedAudioLane]
    public let duration: RationalTime
    // Input routing for an assembled CLI request. Saved projects retain their
    // bindings and selections on the project; playback plan JSON is unchanged.
    package var joinedAudioReplacements: [MulticamAudioReplacement] = []
    package var joinedAudioSelections: [String: MulticamAudioSelection] = [:]
    public var isMix: Bool { audioLanes.contains { $0.colorSlot != nil } }

    /// Single-program route for legacy consumers. Mix consumers must use audioLanes.
    public var audio: [MulticamSpan] { isMix ? [] : audioLanes.first?.spans ?? [] }

    private enum CodingKeys: String, CodingKey { case intervals, picture, audioLanes = "audio_lanes", duration }

    public init(intervals: [MulticamInterval], picture: [MulticamSpan],
                audioLanes: [MulticamPlannedAudioLane], duration: RationalTime) {
        self.intervals = intervals
        self.picture = picture
        self.audioLanes = audioLanes
        self.duration = duration
    }

    public init(intervals: [MulticamInterval], picture: [MulticamSpan],
                audio: [MulticamSpan], duration: RationalTime) {
        self.init(intervals: intervals, picture: picture,
                  audioLanes: audio.isEmpty ? [] : [.init(id: Self.programAudioLaneID, label: "Program audio", spans: audio)],
                  duration: duration)
    }
}

package enum JSONInputLocation: Hashable, Sendable {
    case key(String)
    case index(Int)
}

private struct JSONInputContainer {
    var keys: Set<String>?
    var expectsKey: Bool
    var location: JSONInputLocation?

    init(object: Bool) {
        keys = object ? [] : nil
        expectsKey = object
        location = object ? nil : .index(0)
    }
}

/// Check syntax that JSONDecoder accepts silently. Call after decoding syntactically valid UTF-8.
/// The observer receives fractional and exponent spellings, which Foundation may round when decoding.
package func jsonInputIssue(_ data: Data, integerNumbersOnly: Bool = false,
                            allowsFraction: (([JSONInputLocation]) -> Bool)? = nil,
                            inspectDecimal: (([JSONInputLocation], ArraySlice<UInt8>) -> Void)? = nil) -> String? {
    let bytes = [UInt8](data)
    var containers = [JSONInputContainer]()
    var index = 0
    var previous: UInt8?
    while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            if integerNumbersOnly || inspectDecimal != nil {
                let start = index
                while index + 1 < bytes.count,
                      ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index + 1]) { index += 1 }
                let token = bytes[start...index]
                if token.contains(UInt8(ascii: ".")) || token.contains(UInt8(ascii: "e")) || token.contains(UInt8(ascii: "E")) {
                    let locations = containers.compactMap(\.location)
                    if integerNumbersOnly, allowsFraction?(locations) != true, integralJSONParts(token) == nil {
                        return "contains a non-integer JSON number"
                    }
                    inspectDecimal?(locations, token)
                }
            }
        case UInt8(ascii: "{"): containers.append(JSONInputContainer(object: true))
        case UInt8(ascii: "["): containers.append(JSONInputContainer(object: false))
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            if previous == UInt8(ascii: ",") {
                return "contains a trailing comma"
            }
            _ = containers.popLast()
        case UInt8(ascii: ","):
            if let last = containers.indices.last {
                if containers[last].keys != nil { containers[last].expectsKey = true }
                else if case let .index(item) = containers[last].location { containers[last].location = .index(item + 1) }
            }
        case UInt8(ascii: "\""):
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { return nil }
            if let last = containers.indices.last, containers[last].expectsKey {
                let key = (try? JSONDecoder().decode(String.self, from: Data(bytes[start...index]))) ?? ""
                if containers[last].keys?.insert(key).inserted == false {
                    return "repeats the field '\(key)'"
                }
                containers[last].expectsKey = false
                containers[last].location = .key(key)
            }
        default: break
        }
        if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { previous = byte }
        index += 1
    }
    return nil
}

/// Return the exact integer represented by a previously validated JSON number token.
package func exactJSONInteger(_ number: ArraySlice<UInt8>) -> Int? {
    guard let (coefficient, last, zeros) = integralJSONParts(number) else { return nil }
    guard let last, let first = coefficient.firstIndex(where: { (49...57).contains($0) }) else { return 0 }
    // An Int on the supported 64-bit platforms has at most 19 decimal digits.
    guard zeros <= 19, last - first + zeros <= 19 else { return nil }
    var digits = String(decoding: coefficient[first...last].filter { $0 != UInt8(ascii: ".") }, as: UTF8.self)
    digits += String(repeating: "0", count: zeros)
    if number.first == UInt8(ascii: "-") { digits.insert("-", at: digits.startIndex) }
    return Int(digits)
}

/// Use the original significand and exponent even when floating-point decoding loses precision.
private func integralJSONParts(_ number: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, Int?, Int)? {
    let exponentIndex = number.firstIndex { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
    let coefficient = number[..<(exponentIndex ?? number.endIndex)]
    guard let lastNonzero = coefficient.lastIndex(where: { (49...57).contains($0) }) else { return (coefficient, nil, 0) }
    let decimal = coefficient.firstIndex(of: UInt8(ascii: "."))
    let fractionalDigits = decimal.map { coefficient.endIndex - $0 - 1 } ?? 0
    let trailingZeros = coefficient.endIndex - lastNonzero - 1 - (decimal.map { $0 > lastNonzero ? 1 : 0 } ?? 0)
    var exponent = 0
    if let exponentIndex {
        let text = String(decoding: number[(exponentIndex + 1)...], as: UTF8.self)
        exponent = Int(text) ?? (text.hasPrefix("-") ? Int.min : Int.max)
    }
    let integralShift = fractionalDigits - trailingZeros
    guard exponent >= integralShift else { return nil }
    let padding = exponent.subtractingReportingOverflow(integralShift)
    return (coefficient, lastNonzero, padding.overflow ? Int.max : padding.partialValue)
}
