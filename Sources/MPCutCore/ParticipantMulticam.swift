import Darwin
import Foundation

public struct ParticipantVirtualAngle: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case participant, original, presentation }

    public var id: String
    public var name: String
    public var sourceID: String
    /// The accepted geometry and this range use the recording's source clock.
    public var range: MulticamRange
    public var kind: Kind
    public var targetID: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, range
        case sourceID = "source_id"
        case targetID = "target_id"
    }

    public init(id: String, name: String, sourceID: String, range: MulticamRange,
                kind: Kind = .participant, targetID: String? = nil) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.range = range
        self.kind = kind
        self.targetID = targetID
    }

    public func slot(framing: ParticipantSlotFraming = .fit) -> ParticipantSlot? {
        switch kind {
        case .participant: .init(id: targetID ?? id, framing: framing)
        case .presentation: .init(target: .presentation, id: targetID ?? id, framing: framing)
        case .original: nil
        }
    }
}

public struct ParticipantMulticamAudioRouting: Codable, Equatable, Sendable {
    public var meetingMix: Bool
    public var meetingAudio: ParticipantAudioBinding?
    public var includeISOs: Bool

    private enum CodingKeys: String, CodingKey {
        case meetingMix = "meeting_mix"
        case meetingAudio = "meeting_audio"
        case includeISOs = "include_isos"
    }

    public init(meetingMix: Bool = true, meetingAudio: ParticipantAudioBinding? = nil, includeISOs: Bool = false) {
        self.meetingMix = meetingMix
        self.meetingAudio = meetingAudio
        self.includeISOs = includeISOs
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_multicam")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(meetingMix: try values.decodeIfPresent(Bool.self, forKey: .meetingMix) ?? true,
                  meetingAudio: try values.decodeIfPresent(ParticipantAudioBinding.self, forKey: .meetingAudio),
                  includeISOs: try values.decodeIfPresent(Bool.self, forKey: .includeISOs) ?? false)
    }
}

public struct ParticipantMulticamReport: Encodable, Sendable {
    public struct Angle: Encodable, Sendable {
        public let angle: ParticipantVirtualAngle
        public let render: ParticipantRenderReport
    }

    public let angles: [Angle]
    public let meetingMix: [StillSoundAction]

    private enum CodingKeys: String, CodingKey {
        case angles
        case meetingMix = "meeting_mix"
    }
}

public enum ParticipantMulticam {
    public static func virtualAngles(_ project: CutProject, sourceID: String, participantIDs: [String],
                                     range: MulticamRange, includeOriginal: Bool = false,
                                     presentationIDs: [String] = []) throws -> [ParticipantVirtualAngle] {
        let known: Bool
        switch project {
        case .multicam(let multicam): known = multicam.pictureSources.contains { $0.id == sourceID }
        case .sequence, .stillSequence: known = project.sequenceClips?.contains { $0.file == sourceID } == true
        }
        guard known else { throw invalid("The virtual angle's source recording is unavailable.") }
        return try virtualAngles(project.participants, sourceID: sourceID, participantIDs: participantIDs,
                                 range: range, includeOriginal: includeOriginal, presentationIDs: presentationIDs)
    }

    public static func virtualAngles(_ participants: ParticipantProject, sourceID: String, participantIDs: [String],
                                     range: MulticamRange, includeOriginal: Bool = false,
                                     presentationIDs: [String] = []) throws -> [ParticipantVirtualAngle] {
        try participants.validate()
        let geometry = participants.sources.first { $0.sourceID == sourceID }
        guard validStillID(sourceID), range.from >= .zero, range.to > range.from,
              geometry != nil || (includeOriginal && participantIDs.isEmpty && presentationIDs.isEmpty),
              includeOriginal || !participantIDs.isEmpty || !presentationIDs.isEmpty,
              Set(participantIDs).count == participantIDs.count,
              Set(presentationIDs).count == presentationIDs.count else {
            throw invalid("Choose a recording, a positive source range and unique angle selections.")
        }
        let people = Dictionary(uniqueKeysWithValues: participants.people.map { ($0.id, $0) })
        var angles: [ParticipantVirtualAngle] = try participantIDs.map { id in
            guard let person = people[id] else { throw invalid("Unknown participant ‘\(id)’.") }
            return .init(id: id, name: person.name, sourceID: sourceID, range: range)
        }
        var ids = Set(angles.map(\.id))
        func availableID(_ preferred: String) -> String {
            var id = preferred
            while !ids.insert(id).inserted { id += "-" }
            return id
        }
        if includeOriginal {
            angles.append(.init(id: availableID("original"), name: "Original gallery", sourceID: sourceID,
                                range: range, kind: .original))
        }
        let presentations = Set(geometry?.appearances.filter { $0.role == .presentation }.map(\.id) ?? [])
        for id in presentationIDs {
            guard presentations.contains(id) else { throw invalid("Unknown presentation ‘\(id)’ on the selected recording.") }
            angles.append(.init(id: availableID("presentation-\(id)"), name: "Presentation \(id)", sourceID: sourceID,
                                range: range, kind: .presentation, targetID: id))
        }
        return angles
    }

    /// Resolve an editable angle to a picture plan. The document and the selected physical recording
    /// supply the source identity, accepted geometry, group offset and any explicit privacy treatment.
    public static func picturePlan(for angle: ParticipantVirtualAngle, in project: CutProject, document: URL,
                                   canvas: ParticipantCanvas, audio: ParticipantRenderAudio = .init()) throws
        -> (project: CutProject, plan: ParticipantRenderPlan) {
        let (source, gallery, identity) = try excerpt(project, document: document, sourceID: angle.sourceID, range: angle.range)
        let plan = try anglePlan(angle, participants: project.participants, canvas: canvas, audio: audio)
        try CutEngine().verifyIdentity(gallery, identity: identity)
        return (source, plan)
    }

    private static func anglePlan(_ angle: ParticipantVirtualAngle, participants: ParticipantProject,
                                  canvas: ParticipantCanvas, audio: ParticipantRenderAudio) throws -> ParticipantRenderPlan {
        let slot = angle.slot()
        let plan = ParticipantRenderPlan(canvas: canvas,
                                         shots: [.init(layout: slot == nil ? .original : .solo, slots: slot.map { [$0] } ?? [])],
                                         audio: audio, redactions: participants.render?.redactions ?? [],
                                         unresolvedPrivacy: participants.render?.unresolvedPrivacy ?? .stop)
        try plan.validate()
        return plan
    }

    public static func report(_ angles: [ParticipantVirtualAngle], project: CutProject, document: URL,
                              canvas: ParticipantCanvas, audio: ParticipantMulticamAudioRouting = .init(),
                              cancelled: (@Sendable () -> Bool)? = nil) throws -> ParticipantMulticamReport {
        let first = try validateGroup(angles)
        let (source, gallery, identity) = try excerpt(project, document: document, sourceID: first.sourceID,
                                                      range: first.range, cancelled: cancelled)
        let isoSnapshots = audio.includeISOs ? snapshots(in: source, document: document) : [:]
        let renderer = ParticipantRenderer(cancelled: cancelled, legacyWholeFramePrivacy: true)
        let reports: [ParticipantMulticamReport.Angle] = try angles.map { angle in
            let sound = iso(for: angle, in: source, routing: audio)
            let plan = try anglePlan(angle, participants: project.participants, canvas: canvas, audio: sound)
            return .init(angle: angle, render: try renderer.report(source, document: document, plan: plan))
        }
        let timeline = try source.resolveStills()
        let mix = audio.meetingMix ? try meetingMix(in: source, galleryID: first.sourceID, document: document,
                                                   timeline: timeline, binding: audio.meetingAudio, cancelled: cancelled) : nil
        try CutEngine(cancelled: cancelled).verifyIdentity(gallery, identity: identity)
        try verifyISOs(Set(reports.flatMap { usedSoundFiles($0.render) }), against: isoSnapshots)
        try mix?.verifySources()
        return .init(angles: reports, meetingMix: mix?.actions ?? [])
    }

    /// Publish the aligned angle movies, optional audio-only meeting mix and a standard multicam project
    /// as a single directory. Existing destinations are left to the caller.
    public static func materialize(_ angles: [ParticipantVirtualAngle], project: CutProject, document: URL,
                                   canvas: ParticipantCanvas, audio: ParticipantMulticamAudioRouting = .init(),
                                   to directory: URL, cancelled: (@Sendable () -> Bool)? = nil) throws -> MulticamProject {
        let first = try validateGroup(angles)
        guard directory.isFileURL else { throw invalid("Choose a local output directory.") }
        let destination = directory.standardizedFileURL
        try project.validateDestination(destination, relativeTo: document, includesContents: true)
        let parent = destination.deletingLastPathComponent()
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            throw CutError(code: "output_exists", message: "The multicam angle directory already exists.")
        }
        guard errno == ENOENT, stat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CutError(code: "invalid_output", message: "Choose a new folder in an existing output directory.")
        }
        let engine = CutEngine(cancelled: cancelled, useSidecar: false)
        let renderer = ParticipantRenderer(cancelled: cancelled, legacyWholeFramePrivacy: true)
        try engine.checkCancellation()
        let (source, gallery, identity) = try excerpt(project, document: document, sourceID: first.sourceID,
                                                      range: first.range, cancelled: cancelled)
        let isoSnapshots = audio.includeISOs ? snapshots(in: source, document: document) : [:]
        var usedISOs = Set<URL>()
        let timeline = try source.resolveStills()
        let mix = audio.meetingMix ? try meetingMix(in: source, galleryID: first.sourceID, document: document,
                                                   timeline: timeline, binding: audio.meetingAudio, cancelled: cancelled) : nil
        let staging = parent.appendingPathComponent(".mpcut-angles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var movies: [MulticamSource] = []
        var snapshotEntries: [ProjectMediaSnapshot.Entry] = []
        for (index, angle) in angles.enumerated() {
            try engine.checkCancellation()
            let sound = iso(for: angle, in: source, routing: audio)
            let plan = try anglePlan(angle, participants: project.participants, canvas: canvas, audio: sound)
            let name = "angle-\(index + 1).mov"
            let movie = staging.appendingPathComponent(name)
            let report = try renderer.render(source, document: document, plan: plan, to: movie)
            // What this angle's picture gave up, for the caller that collects `written_warnings`.
            ExportWriteNotices.record(report.allWarnings.map { "\(angle.name): \($0)" })
            usedISOs.formUnion(usedSoundFiles(report))
            let media = try engine.inspect(movie, keyframes: true)
            guard let firstFrame = media.frames.first, firstFrame.time == .zero,
                  let lastFrame = media.frames.last else {
                throw invalid("Rendered angle ‘\(angle.name)’ does not begin at the shared picture origin.")
            }
            let pictureEnd = try lastFrame.time.adding(lastFrame.duration)
            guard pictureEnd == report.duration, pictureEnd == timeline.duration else {
                throw invalid("Rendered angles have different picture durations.")
            }
            let stream = sound.mode == .iso ? media.audio.first?.stream.index : nil
            if sound.mode == .iso && stream == nil { throw invalid("Rendered angle ‘\(angle.name)’ is missing its requested ISO.") }
            movies.append(.init(id: angle.id, file: name, name: angle.name, audioStream: stream))
            snapshotEntries.append(.init(path: name, media: media))
        }
        var audioSources: [MulticamSource] = []
        var policy = MulticamAudioPolicy.none
        if let mix, !mix.actions.isEmpty {
            let urls = try StillSoundPlanner(cancelled: cancelled).write(mix, in: staging)
            guard urls.count == 1, let sound = urls.first else {
                throw invalid("The meeting mix must contain exactly one audio track.")
            }
            let filename = "meeting-mix.mov"
            let media = try engine.inspect(sound)
            guard let stream = media.audio.first?.stream.index else { throw invalid("The meeting mix has no audio stream.") }
            try FileManager.default.moveItem(at: sound, to: staging.appendingPathComponent(filename))
            try FileManager.default.removeItem(at: sound.deletingLastPathComponent())
            let ids = Set(angles.map(\.id))
            var mixID = "meeting-mix"
            while ids.contains(mixID) { mixID += "-" }
            audioSources = [.init(id: mixID, file: filename, name: "Meeting mix", audioStream: stream)]
            snapshotEntries.append(.init(path: filename, media: media))
            policy = .fixed(.init(source: mixID, stream: stream))
        }
        let lanes = movies.enumerated().compactMap { index, movie -> MulticamAudioLane? in
            guard let stream = movie.audioStream else { return nil }
            return .init(id: "iso-\(index + 1)", target: .recording(.init(source: movie.id, stream: stream)),
                         label: "\(movie.name ?? movie.id) ISO", colorSlot: index % MulticamAudioLane.colorSlotCount)
        }
        let result = MulticamProject(referenceAngle: first.id, range: .init(from: .zero, to: timeline.duration), angles: movies,
                                     audioSources: audioSources, audio: policy, switches: [.init(at: .zero, angle: first.id)],
                                     mixLanes: lanes)
        try result.validate()
        try result.save(to: staging.appendingPathComponent("multicam.cut"),
                        mediaSnapshot: ProjectMediaSnapshot(entries: snapshotEntries))
        try engine.verifyIdentity(gallery, identity: identity)
        try mix?.verifySources()
        try verifyISOs(usedISOs, against: isoSnapshots)
        try engine.checkCancellation()
        guard chmod(staging.path, try publicationPermissions(0o777)) == 0 else {
            throw CutError(code: "write_failed", message: "Could not publish the multicam angle directory.")
        }
        let failure = publishExclusively(from: staging, to: destination, isDirectory: true)
        guard failure == 0 else {
            throw CutError(code: failure == EEXIST || failure == ENOTEMPTY ? "output_exists" : "write_failed",
                           message: String(cString: strerror(failure)))
        }
        return result
    }

    static func iso(for angle: ParticipantVirtualAngle, in project: CutProject,
                            routing: ParticipantMulticamAudioRouting) -> ParticipantRenderAudio {
        let id = angle.targetID ?? angle.id
        guard routing.includeISOs, angle.kind == .participant, project.participants.audioBinding(for: id) != nil else {
            return .init()
        }
        return .init(mode: .iso, ids: [id])
    }

    private static func validateGroup(_ angles: [ParticipantVirtualAngle]) throws -> ParticipantVirtualAngle {
        guard let first = angles.first, Set(angles.map(\.id)).count == angles.count,
              angles.allSatisfy({ validStillID($0.id) && validStillID($0.name)
                  && $0.sourceID == first.sourceID && $0.range == first.range }) else {
            throw invalid("Choose unique angles with one recording and source range.")
        }
        return first
    }

    static func snapshots(in project: CutProject, document: URL) -> [URL: SourceIdentity] {
        // An ISO can use a recording, a lane or a lane's replacement.
        var snapshots: [URL: SourceIdentity] = [:]
        for (_, path) in project.mediaPaths {
            guard let file = try? CutProject.checkedMediaURL(path, relativeTo: document).standardizedFileURL,
                  snapshots[file] == nil, let identity = try? SourceIdentity(file) else { continue }
            snapshots[file] = identity
            snapshots[AnalysisSidecar.canonicalSource(file)] = identity
        }
        return snapshots
    }

    static func usedSoundFiles(_ report: ParticipantRenderReport) -> [URL] {
        report.audioActions.flatMap { $0.sources.map { $0.file.standardizedFileURL } }
    }

    static func verifyISOs(_ files: Set<URL>, against snapshots: [URL: SourceIdentity]) throws {
        for file in files {
            guard let identity = snapshots[file], identity.isCurrentSnapshot(at: file) else {
                throw CutError(code: "source_changed", message: "The ISO source changed while preparing the angle group: \(file.path)")
            }
        }
    }

    static func excerpt(_ project: CutProject, document: URL, sourceID: String, range: MulticamRange,
                                cancelled: (@Sendable () -> Bool)? = nil) throws
        -> (project: CutProject, file: URL, identity: SourceIdentity) {
        try project.validate()
        guard range.from >= .zero, range.from < range.to else { throw invalid("Choose a positive source range.") }
        var selected = project
        let gallery: URL
        let media: MediaInfo
        switch project {
        case .multicam(var multicam):
            guard let angle = multicam.angles.first(where: { $0.recordings.contains(where: { $0.id == sourceID }) }),
                  let recording = angle.recordings.first(where: { $0.id == sourceID }) else {
                throw invalid("The virtual angle's source recording is unavailable.")
            }
            gallery = try CutProject.checkedMediaURL(recording.file, relativeTo: document)
            media = try CutEngine(cancelled: cancelled, tracks: .video).inspectSummary(gallery)
            let offset = try recording.offset.adding(media.multicamSourceOffset)
            let group = try MulticamRange(from: range.from.adding(offset), to: range.to.adding(offset))
            guard media.hasVideo, range.to <= media.duration,
                  group.from >= multicam.range.from, group.to <= multicam.range.to,
                  recording.coverage.map({ group.from >= $0.from && group.to <= $0.to }) ?? true else {
                throw invalid("The virtual angle's range is outside the recording's group coverage.")
            }
            multicam.assemblyItems = [.group(group, angle: angle.id)]
            multicam.stillReplacements = []
            selected = .multicam(multicam)
        case .sequence, .stillSequence:
            guard project.sequenceClips?.contains(where: { $0.file == sourceID }) == true else {
                throw invalid("The virtual angle's source recording is unavailable.")
            }
            gallery = try CutProject.checkedMediaURL(sourceID, relativeTo: document)
            media = try CutEngine(cancelled: cancelled, tracks: .video).inspectSummary(gallery)
            guard media.hasVideo, range.to <= media.duration else {
                throw invalid("The virtual angle's range is outside the recording's picture.")
            }
            let clip = CutSequenceClip(id: "gallery-excerpt", file: sourceID, from: range.from, to: range.to)
            selected = .stillSequence(.init(items: [.source(clip)], programColorPolicy: project.programColorPolicy))
        }
        var participants = project.participants
        participants.render = nil
        selected.participants = participants
        try selected.validate()
        return (selected, gallery, media.identity)
    }

    static func meetingMix(in source: CutProject, galleryID: String, document: URL,
                                   timeline: StillTimelinePlan, binding: ParticipantAudioBinding?,
                                   cancelled: (@Sendable () -> Bool)?) throws -> StillSoundPlan {
        var soundtrack = source
        let engine = CutEngine(cancelled: cancelled)
        switch source {
        case .multicam(var multicam):
            if let binding {
                try ParticipantRenderSound.apply(binding, to: &multicam)
            } else if let recording = multicam.pictureSources.first(where: { $0.id == galleryID }) {
                let file = try CutProject.checkedMediaURL(recording.file, relativeTo: document)
                let media = try engine.inspect(file)
                if let stream = recording.audioStream ?? media.audio.first?.stream.index {
                    try ParticipantRenderSound.apply(.init(selection: .init(source: galleryID, stream: stream)), to: &multicam)
                }
            }
            soundtrack = .multicam(multicam)
            return try ParticipantRenderSound.resolve(soundtrack, document: document, timeline: timeline,
                                                      audio: .init(mode: .program), cancelled: cancelled, action: .auto)
        case .sequence, .stillSequence:
            guard binding == nil || (binding?.selection != nil && binding?.laneID == nil) else {
                throw invalid("A sequence mix needs a source and stream binding.")
            }
            let selection: MulticamAudioSelection?
            if let explicit = binding?.selection {
                selection = explicit
            } else {
                let file = try CutProject.checkedMediaURL(galleryID, relativeTo: document)
                let media = try engine.inspect(file)
                selection = media.audio.first.map { .init(source: galleryID, stream: $0.stream.index) }
            }
            guard let selection else { return .init(actions: [], treatments: [], container: "mov") }
            let gallery = try CutProject.checkedMediaURL(galleryID, relativeTo: document)
            let selected = try CutProject.checkedMediaURL(selection.source, relativeTo: document)
            guard try SourceIdentity(gallery) == SourceIdentity(selected) else {
                throw invalid("The sequence meeting mix must reference the gallery recording.")
            }
            var participants = soundtrack.participants
            let existing = Set(participants.people.map(\.id))
            var id = "meeting-mix"
            while existing.contains(id) { id += "-" }
            participants.people.append(.init(id: id, name: "Meeting mix", audio: .init(selection: selection)))
            soundtrack.participants = participants
            return try ParticipantRenderSound.resolve(soundtrack, document: document, timeline: timeline,
                                                      audio: .init(mode: .iso, ids: [id]), cancelled: cancelled, action: .auto)
        }
    }

    private static func invalid(_ message: String) -> CutError { .init(code: "invalid_participant_multicam", message: message) }
}
