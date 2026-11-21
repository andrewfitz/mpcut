import Darwin
import Foundation

/// The start or end of one assembly range. `range` is one-based and equals the error's `segment`.
public struct MulticamEdge: Codable, Equatable, Sendable {
    public let range: Int
    public let boundary: String
    public let at: RationalTime
}

public struct MulticamDiagnostic: Codable, Sendable {
    public let source: String
    public let group: MulticamRange
    public let sourceTime: MulticamRange
    public let output: MulticamRange
    /// The switch that the error's `nearest` times can replace. Absent unless the boundary is a switch.
    public let at: RationalTime?
    /// The assembly range edge that the error's `nearest` times can replace. Absent at a switch.
    public let edge: MulticamEdge?
}

/// The plan that results from moving one edge of a one-based assembly range to a group time.
public typealias MulticamEdgePlanner = (_ range: Int, _ boundary: String, _ time: RationalTime) throws -> MulticamPlan

public struct MulticamInspectedSource: Encodable, Sendable {
    public let source: MulticamSource
    public let media: MediaInfo
    public let coverage: MulticamRange
    public let audioCoverage: [Int: MulticamRange]

    private enum CodingKeys: String, CodingKey { case source, media, coverage, audioCoverage }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(media.omittingFrames(), forKey: .media)
        try values.encode(coverage, forKey: .coverage)
        try values.encode(audioCoverage, forKey: .audioCoverage)
    }
}

public struct MulticamInspection: Encodable, Sendable {
    public let mapping: MulticamPlan
    public let sources: [MulticamInspectedSource]
    public let issues: [CutError]
}

public struct MulticamExportPlan: Encodable, Sendable {
    public let mapping: MulticamPlan
    public let picture: [ResolvedSegment]
    public let audio: [ResolvedSegment]
    public let container: String
    public let duration: RationalTime
    public let mode: ExportMode
    public let tracks: ExportTracks
    public let warnings: [String]
    public let audioAction: ReencodeAudio?
    public let encodedVideoDuration: RationalTime
    public let copiedVideoDuration: RationalTime

    let pictureCopy: ResolvedEdit?
    let pictureEncode: ReencodePlan?
    let soundCopy: ResolvedEdit?
    let soundEncode: MulticamAudioConversionPlan?

    enum CodingKeys: String, CodingKey {
        case mapping, picture, audio, container, duration, mode, tracks, warnings
        case encodedVideoDuration, copiedVideoDuration, audioAction
    }
}

public struct MulticamEngine: Sendable {
    let cancelled: (@Sendable () -> Bool)?

    public init(cancelled: (@Sendable () -> Bool)? = nil) {
        self.cancelled = cancelled
    }

    package func checkCombinedDestination(_ output: URL) throws -> String {
        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        try engine.checkDestination(output)
        let container = try destinationContainer(output)
        try MulticamMux(cancelled: cancelled).check(container: container)
        return container
    }

    private func destinationContainer(_ output: URL) throws -> String {
        let ext = output.pathExtension.lowercased()
        guard !ext.isEmpty, ext.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else {
            throw CutError(code: "unsupported_container", message: "Choose a destination with a media container extension.")
        }
        // FFmpeg identifies M4V as raw video. Multicam uses an MP4 movie.
        return ext == "m4v" ? "mp4" : ext
    }

    public func inspect(_ project: MulticamProject, relativeTo location: URL? = nil) throws -> MulticamInspection {
        let mapping = try project.plan()
        let engine = CutEngine(cancelled: cancelled)
        var indexed: [URL: MediaInfo] = [:]
        let sources = try (project.angles + project.audioSources).map { source in
            let file = sourceURL(source, project: project, location: location)
            let media = try index(source.id, file: file, using: engine, cached: &indexed)
            let coverage = try groupCoverage(of: media, source: source.id, offset: source.offset)
            return MulticamInspectedSource(source: source, media: media, coverage: coverage.picture,
                                           audioCoverage: coverage.audio)
        }
        let bySource = Dictionary(uniqueKeysWithValues: sources.map { ($0.source.id, $0) })
        let requiresSoundtrack = project.audio != .none || !mapping.audio.isEmpty
        var issues: [CutError] = []
        for interval in mapping.intervals {
            let picture = bySource[interval.angle]
            // An issue names its assembly range, as an export error does, and locates the interval.
            let number = interval.assemblyIndex + 1
            func context(_ source: String) -> MulticamDiagnostic? {
                guard let offset = bySource[source]?.source.offset,
                      let from = try? interval.group.from.subtracting(offset),
                      let to = try? interval.group.to.subtracting(offset) else { return nil }
                return MulticamDiagnostic(source: source, group: interval.group, sourceTime: .init(from: from, to: to),
                                          output: interval.output, at: nil, edge: nil)
            }
            if picture?.media.hasVideo != true || picture.map({ interval.group.from < $0.coverage.from || interval.group.to > $0.coverage.to }) == true {
                issues.append(CutError(code: "uncovered_picture",
                                       message: "Angle \(interval.angle) has incomplete picture coverage at group \(interval.group.from)–\(interval.group.to).",
                                       segment: number, track: picture?.media.videoStream?.index,
                                       multicam: context(interval.angle)))
            }
            if let audio = interval.audio {
                if let coverage = bySource[audio.source]?.audioCoverage[audio.stream] {
                    if interval.group.from < coverage.from || interval.group.to > coverage.to {
                        issues.append(CutError(code: "uncovered_audio",
                                               message: "Source \(audio.source) stream \(audio.stream) has incomplete sound coverage at group \(interval.group.from)–\(interval.group.to).",
                                               segment: number, track: audio.stream, multicam: context(audio.source)))
                    }
                } else {
                    issues.append(CutError(code: "missing_audio",
                                           message: "Source \(audio.source) has no audio stream \(audio.stream).",
                                           segment: number, track: audio.stream, multicam: context(audio.source)))
                }
            } else if requiresSoundtrack {
                issues.append(CutError(code: "missing_audio",
                                       message: "Angle \(interval.angle) has no selected soundtrack at group \(interval.group.from)–\(interval.group.to).",
                                       segment: number, multicam: context(interval.angle)))
            }
        }
        return MulticamInspection(mapping: mapping, sources: sources, issues: issues)
    }

    public func resolve(_ project: MulticamProject, relativeTo location: URL? = nil, output: URL,
                        mode: ExportMode = .smart, tracks: ExportTracks = .all,
                        assembly: [MulticamRange]? = nil,
                        settings: ReencodeSettings = .init()) throws -> MulticamExportPlan {
        try resolve(project, relativeTo: location, output: output, mode: mode, tracks: tracks,
                    assembly: assembly, settings: settings, indexedSources: [:])
    }

    /// The desktop can supply indexes from inspectMulticamSource to export the
    /// same recordings and source clocks used in its preview.
    package func resolve(_ project: MulticamProject, relativeTo location: URL? = nil, output: URL,
                         mode: ExportMode = .smart, tracks: ExportTracks = .all,
                         assembly: [MulticamRange]? = nil, settings: ReencodeSettings = .init(),
                         indexedSources: [String: MediaInfo]) throws -> MulticamExportPlan {
        let mapping = try project.plan(ranges: assembly)
        let sources = Dictionary(uniqueKeysWithValues: (project.angles + project.audioSources).map {
            ($0.id, sourceURL($0, project: project, location: location))
        })
        let ranges = assembly ?? project.assembly ?? [project.range]
        return try resolve(mapping, sources: sources, output: output, mode: mode, tracks: tracks,
                           settings: settings, requireAudio: project.audio != .none || !mapping.audio.isEmpty,
                           indexedSources: indexedSources) { number, boundary, time in
            var moved = ranges
            guard moved.indices.contains(number - 1) else {
                throw CutError(code: "invalid_range", message: "The project has no assembly range \(number).")
            }
            if boundary == "from" { moved[number - 1].from = time } else { moved[number - 1].to = time }
            return try project.plan(ranges: moved)
        }
    }

    /// `adjusting` replans the request with one range edge moved. With it, an unsafe range
    /// edge reports nearby valid times in `nearest`, as an unsafe switch does.
    public func resolve(_ mapping: MulticamPlan, sources: [String: URL], output: URL,
                        mode: ExportMode = .smart, tracks: ExportTracks = .all,
                        settings: ReencodeSettings = .init(),
                        requireAudio: Bool = true,
                        adjusting: MulticamEdgePlanner? = nil) throws -> MulticamExportPlan {
        try resolve(mapping, sources: sources, output: output, mode: mode, tracks: tracks,
                    settings: settings, requireAudio: requireAudio, indexedSources: [:], adjusting: adjusting)
    }

    /// Reports each located fault against its one-based assembly range, which for an edit
    /// request is the caller's clip number, and offers alternatives for an unsafe range edge.
    private func resolve(_ mapping: MulticamPlan, sources: [String: URL], output: URL,
                         mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings,
                         requireAudio: Bool, indexedSources: [String: MediaInfo],
                         adjusting: MulticamEdgePlanner?) throws -> MulticamExportPlan {
        var media: [String: MediaInfo] = [:]
        do {
            return try resolveLanes(mapping, sources: sources, output: output, mode: mode, tracks: tracks,
                                    settings: settings, requireAudio: requireAudio,
                                    indexedSources: indexedSources, media: &media)
        } catch let issue as CutError {
            guard let context = issue.multicam else { throw issue }
            var nearest = issue.nearest
            if let edge = context.edge, let adjusting,
               issue.code == "unsafe_boundary" || issue.code == "invalid_frame_boundary" {
                let indexed = media
                nearest = try edgeAlternatives(edge, mapping: mapping, media: indexed, mode: mode,
                                               container: destinationContainer(output),
                                               picture: tracks != .audio,
                                               sound: tracks != .video && !mapping.audio.isEmpty
                                                   && !(mode == .encode && [.aac, .pcm, .removeAudio].contains(settings.audio)),
                                               adjusting: adjusting) { candidate in
                    var unused: [String: MediaInfo] = [:]
                    do {
                        _ = try resolveLanes(candidate, sources: sources, output: output, mode: mode, tracks: tracks,
                                             settings: settings, requireAudio: requireAudio,
                                             indexedSources: indexed, media: &unused)
                        return nil
                    } catch let failure as CutError {
                        return failure
                    }
                }
            }
            throw CutError(code: issue.code, message: issue.message,
                           segment: rangeNumber(context, boundary: issue.boundary, in: mapping) ?? issue.segment,
                           boundary: issue.boundary, nearest: nearest, track: issue.track, multicam: context)
        }
    }

    private func rangeNumber(_ context: MulticamDiagnostic, boundary: String?, in mapping: MulticamPlan) -> Int? {
        if let edge = context.edge { return edge.range }
        let interval = boundary == "to"
            ? mapping.intervals.last { $0.output.from < context.output.to }
            : mapping.intervals.first { $0.output.to > context.output.from }
        return interval.map { $0.assemblyIndex + 1 }
    }

    /// Faults thrown here carry `segment` as a one-based index into the picture or sound lane.
    private func resolveLanes(_ mapping: MulticamPlan, sources: [String: URL], output: URL,
                              mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings,
                              requireAudio: Bool, indexedSources: [String: MediaInfo],
                              media indexedMedia: inout [String: MediaInfo]) throws -> MulticamExportPlan {
        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        try engine.checkDestination(output)
        let destinationContainer = output.pathExtension.lowercased()
        let container = try self.destinationContainer(output)
        guard mode == .copy || tracks == .all else {
            throw CutError(code: "invalid_arguments", message: "Explicit track selection requires Lossless Copy.")
        }
        let wantPicture = tracks != .audio
        let wantAudio = tracks != .video && (mode != .encode || settings.audio != .removeAudio)
        if wantAudio && (requireAudio || !mapping.audio.isEmpty || tracks == .audio),
           let missing = mapping.intervals.first(where: { $0.audio == nil }) {
            // Inspection lists the same interval in its issues.
            let picture = mapping.picture.first { $0.output.from <= missing.output.from && missing.output.from < $0.output.to }
            let context = try picture.map { span -> MulticamDiagnostic in
                let from = try span.input.from.adding(missing.output.from.subtracting(span.output.from))
                let to = try from.adding(missing.output.to.subtracting(missing.output.from))
                return MulticamDiagnostic(source: missing.angle, group: missing.group, sourceTime: .init(from: from, to: to),
                                          output: missing.output, at: nil, edge: nil)
            }
            throw CutError(code: "missing_audio", message: "Angle \(missing.angle) has no selected soundtrack at group \(missing.group.from)–\(missing.group.to), output \(missing.output.from)–\(missing.output.to).",
                           segment: missing.assemblyIndex + 1, multicam: context)
        }
        let useAudio = wantAudio && !mapping.audio.isEmpty
        guard wantPicture || useAudio else {
            throw CutError(code: "missing_audio", message: "There is no soundtrack selected for export.")
        }
        if wantPicture { try validateLane(mapping.picture, duration: mapping.duration, kind: "picture") }
        if useAudio { try validateLane(mapping.audio, duration: mapping.duration, kind: "soundtrack") }
        if wantPicture && useAudio { try MulticamMux(cancelled: cancelled).check(container: container) }
        if MulticamMux.movieContainers.contains(container), 705_600_000 % mapping.duration.denominator != 0 {
            throw CutError(code: "unsupported_container", message: "The MOV movie clock cannot represent the exact program duration.")
        }

        var indexed: [URL: MediaInfo] = [:]
        var bySource: [String: MediaInfo] = [:]
        let selected = (wantPicture ? mapping.picture : []) + (useAudio ? mapping.audio : [])
        for span in selected where bySource[span.source] == nil {
            let file = sources[span.source]
            let previous = indexedSources[span.source].flatMap { $0.url == file?.standardizedFileURL ? $0 : nil }
            if let previous, previous.hasFullEditIndex, let file, !file.path.split(separator: "/").contains("..") {
                try engine.checkCancellation()
                try engine.verifyIdentity(file, identity: previous.identity)
                indexed[previous.url] = previous
                bySource[span.source] = previous
            } else {
                // Queues can snapshot a camera while its editing index is still loading.
                bySource[span.source] = try index(span.source, file: file, using: engine, cached: &indexed,
                                                  expectedIdentity: previous?.identity)
            }
        }

        indexedMedia = bySource
        // Inspection places each recording on the group clock. Do the same here, so an
        // offset beyond the rational range is one fault in both commands.
        var checkedOffsets: [String: Set<RationalTime>] = [:]
        for span in selected {
            try engine.checkCancellation()
            let offset = try groupStart(for: span, in: mapping).subtracting(span.input.from)
            guard checkedOffsets[span.source, default: []].insert(offset).inserted else { continue }
            _ = try groupCoverage(of: bySource[span.source]!, source: span.source, offset: offset)
        }

        let convertAudio = useAudio && mode == .encode && [.aac, .pcm].contains(settings.audio)
        var sound: ResolvedEdit?
        if useAudio && !convertAudio {
            do {
                sound = try resolveSound(mapping, sources: bySource, container: container)
            } catch let issue as CutError where issue.code == "unsafe_boundary" {
                guard let segment = issue.segment, mapping.audio.indices.contains(segment - 1),
                      let boundary = issue.boundary else { throw issue }
                let audio = mapping.audio[segment - 1]
                let output = boundary == "from" ? audio.output.from : audio.output.to
                let pictureSwitch = wantPicture && mapping.picture.dropLast().contains { $0.output.to == output }
                let offered = try pictureSwitch
                    ? pictureAlternatives(at: output, mapping: mapping, media: bySource, mode: mode,
                                          container: container, validateAudio: true, convertedAudio: nil, settings: settings)
                    : soundOnlyAlternatives(at: output, mapping: mapping, media: bySource, container: container)
                throw CutError(code: issue.code, message: issue.message, segment: issue.segment,
                               boundary: issue.boundary, nearest: offered, track: issue.track, multicam: issue.multicam)
            }
        }
        let soundEncode = convertAudio
            ? try resolveConvertedSound(mapping, sources: bySource, container: container, action: settings.audio) : nil
        var pictureCopy: ResolvedEdit?
        var pictureEncode: ReencodePlan?
        if wantPicture {
            let pictureEngine = CutEngine(multicamSmartPicture: mode == .smart, cancelled: cancelled)
            var media: [URL: MediaInfo] = [:]
            var requests: [ClipRequest] = []
            for (index, span) in mapping.picture.enumerated() {
                let source = bySource[span.source]!
                let info: MediaInfo
                do {
                    info = try isolatedPicture(source, using: pictureEngine)
                    try checkPictureCoverage(info, span: span, mapping: mapping, container: container)
                } catch let issue as CutError {
                    throw try contextual(issue, span: span, mapping: mapping, index: index + 1,
                                         track: source.videoStream?.index)
                }
                media[info.url] = info
                requests.append(ClipRequest(file: info.url, from: span.input.from, to: span.input.to))
            }

            do {
                if mode == .encode {
                    let pictureSettings = ReencodeSettings(codec: settings.codec, quality: settings.quality, audio: .removeAudio)
                    var encoded = try ReencodeEngine(cancelled: cancelled).resolve(requests, media: media,
                                                                                    container: container, settings: pictureSettings)
                    encoded.movieTimeScale = 705_600_000
                    pictureEncode = encoded
                } else {
                    pictureCopy = try pictureEngine.resolve(requests, media: media, container: container)
                }
            } catch let issue as CutError where issue.code != "cancelled" {
                guard let segment = issue.segment, mapping.picture.indices.contains(segment - 1) else { throw issue }
                let span = mapping.picture[segment - 1]
                var offered: [RationalTime] = []
                if issue.code == "unsafe_boundary" || issue.code == "invalid_frame_boundary",
                   let boundary = issue.boundary {
                    offered = try pictureAlternatives(at: boundary == "from" ? span.output.from : span.output.to,
                                                     mapping: mapping, media: bySource, mode: mode, container: container,
                                                     validateAudio: useAudio, convertedAudio: soundEncode?.action,
                                                     settings: settings)
                }
                throw try contextual(issue, span: span, mapping: mapping, index: segment, nearest: offered,
                                     track: bySource[span.source]?.videoStream?.index)
            }
        }
        let picture = pictureCopy?.segments ?? pictureEncode?.edit.segments ?? []
        let encoded = try pictureCopy?.encodedVideoDuration(for: mode) ?? pictureEncode?.edit.duration ?? .zero
        return MulticamExportPlan(mapping: mapping, picture: picture, audio: sound?.segments ?? soundEncode?.edit.segments ?? [],
                                  container: destinationContainer, duration: mapping.duration, mode: mode, tracks: tracks,
                                  warnings: (pictureEncode?.warnings ?? []) + (soundEncode?.warnings ?? []),
                                  audioAction: soundEncode?.action ?? (sound == nil ? nil : .copyOriginal),
                                  encodedVideoDuration: encoded,
                                  copiedVideoDuration: wantPicture ? try mapping.duration.subtracting(encoded) : .zero,
                                  pictureCopy: pictureCopy, pictureEncode: pictureEncode, soundCopy: sound, soundEncode: soundEncode)
    }

    public func write(_ plan: MulticamExportPlan, to output: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        try engine.checkDestination(output)
        guard output.pathExtension.lowercased() == plan.container else {
            throw CutError(code: "invalid_output", message: "The destination must match the resolved multicam container.")
        }
        let destination = output.standardizedFileURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-multicam-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let picture = staging.appendingPathComponent("picture")
            .appendingPathExtension(plan.pictureCopy?.container ?? plan.pictureEncode?.edit.container ?? plan.container)
        let sound = staging.appendingPathComponent("sound")
            .appendingPathExtension(plan.soundCopy?.container ?? plan.soundEncode?.edit.container ?? plan.container)
        let hasPicture = plan.pictureCopy != nil || plan.pictureEncode != nil
        let hasSound = plan.soundCopy != nil || plan.soundEncode != nil
        let both = hasPicture && hasSound
        let pictureFraction = both ? 0.45 : 0.98
        func verifySources() throws {
            for edit in [plan.pictureCopy, plan.pictureEncode?.edit, plan.soundCopy, plan.soundEncode?.edit].compactMap({ $0 }) {
                for (file, identity) in edit.identities {
                    try engine.verifyIdentity(file, identity: identity)
                }
            }
            try engine.checkCancellation()
        }
        try verifySources()
        if let copy = plan.pictureCopy {
            try engine.export(copy, to: picture) { fraction in progress?(fraction * pictureFraction); return true }
        } else if let encoded = plan.pictureEncode {
            try ReencodeEngine(cancelled: cancelled).write(encoded, to: picture) { fraction in
                progress?(fraction * pictureFraction)
            }
        }
        if let audio = plan.soundCopy {
            try engine.export(audio, to: sound, audioOnly: true, programAudio: plan.container != "flac") { fraction in
                progress?(both ? pictureFraction + fraction * 0.35 : fraction * 0.98)
                return true
            }
        }
        if let encoded = plan.soundEncode {
            try writeConvertedSound(encoded, to: sound) { fraction in
                progress?(both ? pictureFraction + fraction * 0.35 : fraction * 0.98)
            }
        }
        if both {
            try MulticamMux(cancelled: cancelled).export(picture: picture, sound: sound, to: destination,
                                                         container: plan.container, duration: plan.duration,
                                                         progress: { fraction in progress?(0.8 + fraction * 0.19); return true },
                                                         verifySources: verifySources)
        } else {
            try verifySources()
            let failure = publishExclusively(from: hasPicture ? picture : sound, to: destination)
            if failure == EEXIST { throw CutError(code: "output_exists", message: "A file already exists at the destination.") }
            if failure != 0 { throw CutError(code: "write_failed", message: String(cString: strerror(failure))) }
        }
        progress?(1)
    }

    private func groupCoverage(of media: MediaInfo, source: String,
                               offset: RationalTime) throws -> (picture: MulticamRange, audio: [Int: MulticamRange]) {
        do {
            let picture = try MulticamRange(from: offset.adding(media.frames.first?.time ?? .zero),
                                            to: offset.adding(media.duration))
            let audio = try media.audio.map { sound in
                (sound.stream.index, try MulticamRange(from: offset.adding(sound.start), to: offset.adding(sound.end)))
            }
            return (picture, Dictionary(uniqueKeysWithValues: audio))
        } catch let issue as CutError where issue.code == "time_overflow" {
            throw CutError(code: issue.code,
                           message: "Source \(source) (\(media.url.path)): offset \(offset) places the recording outside the supported time range.")
        }
    }

    private func validateLane(_ spans: [MulticamSpan], duration: RationalTime, kind: String) throws {
        var end = RationalTime.zero
        for span in spans {
            guard span.output.from == end, span.output.from < span.output.to,
                  try span.output.to.subtracting(span.output.from) == span.input.to.subtracting(span.input.from) else {
                throw CutError(code: "invalid_range", message: "The selected \(kind) does not continuously cover the program at output \(end).")
            }
            end = span.output.to
        }
        guard end == duration, duration > .zero else {
            throw CutError(code: "invalid_range", message: "The selected \(kind) does not cover output \(end)–\(duration).")
        }
    }

    private func sourceURL(_ source: MulticamSource, project: MulticamProject, location: URL?) -> URL {
        if let location { return project.sourceURL(for: source, relativeTo: location) }
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return project.sourceURL(for: source, in: workingDirectory)
    }

    private func index(_ source: String, file: URL?, using engine: CutEngine,
                       cached: inout [URL: MediaInfo], expectedIdentity: SourceIdentity? = nil) throws -> MediaInfo {
        guard let file else { throw CutError(code: "missing_source", message: "Source \(source) has no file.") }
        guard !file.path.split(separator: "/").contains("..") else {
            throw CutError(code: "missing_source", message: "Source \(source) has an unavailable parent directory: \(file.path).")
        }
        let fileURL = file.standardizedFileURL
        if let current = cached[fileURL] {
            if let expectedIdentity, current.identity != expectedIdentity {
                throw CutError(code: "source_changed", message: "Source \(source) changed after it was added to the project.")
            }
            return current
        }
        do {
            let media = try engine.multicamClock(engine.inspect(fileURL, keyframes: true, expectedIdentity: expectedIdentity))
            cached[fileURL] = media
            return media
        } catch let issue as CutError where issue.code != "cancelled" {
            throw CutError(code: issue.code, message: "Source \(source) (\(fileURL.path)): \(issue.message)")
        }
    }

    func groupRange(_ span: MulticamSpan, in mapping: MulticamPlan) throws -> MulticamRange {
        let from = try groupStart(for: span, in: mapping)
        return try MulticamRange(from: from, to: from.adding(span.input.to.subtracting(span.input.from)))
    }

    private func groupStart(for span: MulticamSpan, in mapping: MulticamPlan) throws -> RationalTime {
        let time = span.output.from
        let intervals = mapping.intervals
        let index = intervals.lowerBound { $0.output.to > time }
        guard index < intervals.count, intervals[index].output.contains(time) else {
            throw CutError(code: "invalid_range", message: "A media span has no group-time mapping.")
        }
        let interval = intervals[index]
        return try interval.group.from.adding(time.subtracting(interval.output.from))
    }

    func contextual(_ issue: CutError, span: MulticamSpan, mapping: MulticamPlan,
                    index: Int, nearest: [RationalTime]? = nil, track: Int? = nil) throws -> CutError {
        guard issue.code != "cancelled" && issue.code != "source_changed" else { return issue }
        let group = try groupRange(span, in: mapping)
        let stream = span.stream ?? issue.track ?? track
        let description = stream.map { "stream \($0)" } ?? "picture"
        let alternatives = try nearest ?? issue.nearest?.map { try group.from.adding($0.subtracting(span.input.from)) }
        // A boundary is a switch when one assembly range continues across it. Any other
        // boundary is a range edge, where a suggested time moves the range and no switch.
        var anchor: RationalTime?
        var edge: MulticamEdge?
        if let boundary = issue.boundary, boundary == "from" || boundary == "to" {
            let starting = boundary == "from"
            let time = starting ? group.from : group.to
            let seam = starting ? span.output.from : span.output.to
            let before = mapping.intervals.last { $0.output.to == seam }
            let after = mapping.intervals.first { $0.output.from == seam }
            if let before, let after, before.assemblyIndex == after.assemblyIndex, before.group.to == after.group.from {
                anchor = time
            } else if let interval = starting ? after : before {
                edge = MulticamEdge(range: interval.assemblyIndex + 1, boundary: boundary, at: time)
            }
        }
        let context = MulticamDiagnostic(source: span.source, group: group, sourceTime: span.input,
                                         output: span.output, at: anchor, edge: edge)
        return CutError(code: issue.code,
                        message: "Source \(span.source) \(description), group \(group.from)–\(group.to), source \(span.input.from)–\(span.input.to), output \(span.output.from)–\(span.output.to): \(issue.message)",
                        segment: index, boundary: issue.boundary, nearest: alternatives, track: stream, multicam: context)
    }
}
