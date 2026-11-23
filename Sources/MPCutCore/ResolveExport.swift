import Darwin
import Foundation
import MediaProbe

private extension XMLElement {
    @discardableResult
    func child(_ name: String, _ attributes: [String: String] = [:]) -> XMLElement {
        let element = XMLElement(name: name)
        element.setAttributesWith(attributes)
        addChild(element)
        return element
    }
}

private extension RationalTime {
    var fcpxTime: String { description + "s" }

    func onFrameGrid(_ rate: RationalTime) throws -> RationalTime {
        guard rate > .zero else { throw CutError(code: "invalid_frame_rate", message: "Missing source frame rate.") }
        let frame = try multiplied(by: rate).roundedToSamples(1)
        return try RationalTime(numerator: frame, denominator: rate.numerator)
            .multiplied(by: RationalTime(numerator: rate.denominator))
    }
}

/// Writes a linked FCPXML timeline. Resolve recognizes mc-clip references as editable multicam clips.
public final class ResolveExport {
    private let engine: CutEngine
    private let cancelled: (@Sendable () -> Bool)?
    private let resources = XMLElement(name: "resources")
    private let spine = XMLElement(name: "spine")
    private var identities: [URL: SourceIdentity] = [:]
    private var timecodes: [URL: RationalTime] = [:]
    private var formats: [String: String] = [:]
    private var assets: [URL: String] = [:]
    private var stillResourceCount = 0
    private var stillMedia: [URL: (info: StillImageInfo, fingerprint: String)] = [:]
    private var soundFiles: [URL: [Int: MediaInfo]] = [:]
    private var audioDirectory: URL?
    private var committed = false
    private var clipMetadata = [FCPClipMetadata]()
    private var fcpDocument = false
    private var preserveMulticamEditing = true
    private var isolateSequenceAudio = true
    private var allowLoss = true
    private var warnings = [String]()
    private var warned = Set<String>()
    private var unsupportedStills = [String]()
    private var bundleDestination: URL?
    private let output: URL
    private var name: String { (bundleDestination ?? output).deletingPathExtension().lastPathComponent }

    private init(_ output: URL, useSidecar: Bool, cancelled: (@Sendable () -> Bool)?) throws {
        guard output.pathExtension.lowercased() == "fcpxml" else {
            throw CutError(code: "invalid_output", message: "Choose a new .fcpxml file for the Resolve timeline.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CutError(code: "output_exists", message: "The destination already exists at \(output.path).")
        }
        self.output = output
        self.cancelled = cancelled
        engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
    }

    deinit {
        if !committed, let audioDirectory { try? FileManager.default.removeItem(at: audioDirectory) }
    }

    public static func validateTimelineHandoff(_ project: CutProject) throws {
        _ = try ProjectConverter.prepareForInterchange(project, for: "DaVinci Resolve timeline handoff", allowLoss: false)
    }

    public static func write(_ project: MulticamProject, relativeTo location: URL, to output: URL,
                             useSidecar: Bool = true, matching imported: [String: MediaInfo] = [:],
                             auxiliaryOutput: ((URL) -> Void)? = nil,
                             cancelled: (@Sendable () -> Bool)? = nil) throws {
        try validateTimelineHandoff(.multicam(project))
        let writer = try ResolveExport(output, useSidecar: useSidecar, cancelled: cancelled)
        try writer.multicam(project, location: location, imported: imported)
        if let audio = writer.audioDirectory { auxiliaryOutput?(audio) }
    }

    public static func write(_ clips: [ClipRequest], to output: URL, useSidecar: Bool = true, matching imported: [MediaInfo] = [],
                             auxiliaryOutput: ((URL) -> Void)? = nil,
                             cancelled: (@Sendable () -> Bool)? = nil) throws {
        let writer = try ResolveExport(output, useSidecar: useSidecar, cancelled: cancelled)
        try writer.remember(imported)
        try writer.sequence(clips)
        if let audio = writer.audioDirectory { auxiliaryOutput?(audio) }
    }

    static func writeFCP(_ project: CutProject, relativeTo location: URL, to xml: URL,
                         package: URL?, allowLoss: Bool, isolateSequenceAudio: Bool = false,
                         preserveMulticamEditing: Bool = true,
                         auxiliaryOutput: ((URL) -> Void)? = nil,
                         cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try ProjectConverter.checkCancellation(cancelled)
        try project.validate()
        let writer = try ResolveExport(xml, useSidecar: false, cancelled: cancelled)
        writer.fcpDocument = true
        writer.preserveMulticamEditing = preserveMulticamEditing
        writer.isolateSequenceAudio = isolateSequenceAudio
        writer.allowLoss = allowLoss
        writer.bundleDestination = package
        writer.clipMetadata = try (project.sequenceClips ?? []).map { clip in
            try FCPClipMetadata(id: clip.id, audioTrack: clip.audioTrack,
                                originalFile: clip.originalFile.map { try CutProject.checkedMediaURL($0, relativeTo: location).path },
                                replacementNames: clip.replacementNames)
        }
        switch project {
        case .sequence:
            try writer.sequence(project.requests(relativeTo: location))
        case .stillSequence(let sequence):
            let inserts = sequence.items.enumerated().compactMap { index, item -> (Int, StillInsert)? in
                item.still.map { (index, $0) }
            }
            try writer.sequence(CutProject.sequence(sequence.items.compactMap(\.source)).requests(relativeTo: location),
                                inserts: Dictionary(uniqueKeysWithValues: inserts),
                                stillAssets: Dictionary(uniqueKeysWithValues: sequence.stillAssets.map { ($0.id, $0) }),
                                colorPolicy: sequence.programColorPolicy, standalone: sequence.stillFormat, location: location)
        case .multicam(let group):
            try writer.multicam(group, location: location, imported: [:])
        }
        if package == nil, let audio = writer.audioDirectory { auxiliaryOutput?(audio) }
        return writer.warnings
    }

    private func warnLoss(_ message: String) throws {
        guard allowLoss else { throw CutError(code: "conversion_loss", message: message) }
        if warned.insert(message).inserted { warnings.append(message) }
    }

    private func recordStillLoss(_ message: String) {
        if allowLoss {
            if warned.insert(message).inserted { warnings.append(message) }
        } else {
            unsupportedStills.append(message)
        }
    }

    private func checkStillLoss() throws {
        if !unsupportedStills.isEmpty {
            throw CutError(code: "conversion_loss", message: unsupportedStills.joined(separator: "\n"))
        }
    }

    private func displayName(_ value: String) throws -> String {
        func valid(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 9, 10, 13, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
            default: return false
            }
        }
        guard !value.unicodeScalars.allSatisfy(valid) else { return value }
        try warnLoss("A display name contains characters FCPXML cannot represent. Replaced them with U+FFFD.")
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars { result.append(valid(scalar) ? scalar : "\u{FFFD}") }
        return String(result)
    }

    private func sourceFrame(_ time: RationalTime, rate: RationalTime) throws -> RationalTime {
        guard fcpDocument else { return time }
        let aligned = try time.onFrameGrid(rate)
        if aligned != time {
            try warnLoss("Video source edit at \(time)s rounds to \(aligned)s at \(rate) fps.")
        }
        return aligned
    }

    private func framePosition(_ time: RationalTime, rate: RationalTime) throws -> RationalTime {
        let aligned = try time.onFrameGrid(rate)
        if aligned != time && fcpDocument {
            let message = "Timeline cut at \(time)s rounds to \(aligned)s at \(rate) fps."
            try warnLoss(message)
        }
        return aligned
    }

    private func remember(_ media: [MediaInfo]) throws {
        for info in media {
            try engine.verifyIdentity(info.url, identity: info.identity)
            identities[info.url] = info.identity
        }
    }

    private func inspect(_ url: URL) throws -> MediaInfo {
        var status = stat()
        guard !url.path.contains("\0"), stat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw CutError(code: "missing_source", message: "Expected a regular source media file at \(url.path).")
        }
        let info = try engine.inspectSummary(url)
        if let expected = identities[info.url], info.identity != expected {
            throw CutError(code: "source_changed", message: "The source changed since inspection: \(url.lastPathComponent)")
        }
        identities[info.url] = info.identity
        return info
    }

    private func assetDuration(_ media: MediaInfo) throws -> RationalTime {
        try media.streams.filter { $0.kind == "audio" && $0.duration > .zero }
            .reduce(media.duration) { try max($0, $1.start.adding($1.duration)) }
    }

    private func format(_ video: StreamInfo?) throws -> String {
        let rate = video?.frameRate ?? RationalTime(numerator: 24)
        let width = video?.displayWidth ?? 1920, height = video?.displayHeight ?? 1080
        return try format(width: width, height: height, rate: rate)
    }

    private func format(width: Int, height: Int, rate: RationalTime) throws -> String {
        guard rate > .zero else { throw CutError(code: "invalid_frame_rate", message: "Missing source frame rate.") }
        let key = "\(width)x\(height)@\(rate)"
        if let id = formats[key] { return id }
        let id = "f\(formats.count + 1)"
        formats[key] = id
        let frame = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        resources.child("format", ["id": id, "name": "FFVideoFormatRateUndefined", "width": String(width),
                                   "height": String(height), "frameDuration": frame.fcpxTime])
        return id
    }

    private func sourceTime(_ media: MediaInfo, _ local: RationalTime = .zero) throws -> RationalTime {
        if let start = timecodes[media.url] { return try start.adding(local) }
        var units: Int64 = 0, numerator: Int32 = 1, denominator: Int32 = 1
        let track = media.primaryStream
        guard let rate = Int32(exactly: track.frameRate.numerator), let scale = Int32(exactly: track.frameRate.denominator),
              mp_source_timecode(media.url.path, Int32(track.index), rate, scale, &units, &numerator, &denominator) >= 0 else {
            throw CutError(code: "invalid_timecode", message: "Could not read source timecode from " + media.url.path)
        }
        let start = try RationalTime(numerator: units, denominator: Int64(denominator))
            .multiplied(by: RationalTime(numerator: Int64(numerator)))
        timecodes[media.url] = start
        return try start.adding(local)
    }

    private func asset(_ media: MediaInfo) throws -> String {
        if let id = assets[media.url] { return id }
        let id = "r\(assets.count + 1)"
        assets[media.url] = id
        var fields = ["id": id, "name": try displayName(media.url.lastPathComponent), "start": try sourceTime(media).fcpxTime, "duration": try assetDuration(media).fcpxTime]
        if let video = media.videoStream {
            fields["hasVideo"] = "1"
            fields["format"] = try format(video)
        }
        let audio = media.streams.filter { $0.kind == "audio" }
        if !audio.isEmpty {
            fields["hasAudio"] = "1"
            fields["audioSources"] = String(audio.count)
            fields["audioChannels"] = String(audio.reduce(0) { $0 + $1.channels })
        }
        resources.child("asset", fields).child("media-rep", ["kind": "original-media", "src": assetLink(media.url)])
        return id
    }

    private func assetLink(_ url: URL) -> String {
        if bundleDestination != nil, let audioDirectory,
           url.deletingLastPathComponent().standardizedFileURL.path == audioDirectory.standardizedFileURL.path {
            let relative = URL(fileURLWithPath: "/" + audioDirectory.lastPathComponent + "/" + url.lastPathComponent)
            return String(relative.path(percentEncoded: true).dropFirst())
        }
        return url.absoluteString
    }

    // Resolve may mix embedded streams when importing FCPXML channel selections.
    // Isolate each requested stream once, retaining its channels and recording offset.
    private func soundFile(_ media: MediaInfo, stream: StreamInfo) throws -> MediaInfo {
        if let file = soundFiles[media.url]?[stream.index] { return file }
        if audioDirectory == nil {
            let directory = output.deletingLastPathComponent().appendingPathComponent("\(name) Audio \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            audioDirectory = directory
        }
        let directory = audioDirectory!
        let stem = media.url.deletingPathExtension().lastPathComponent
        let file = directory.appendingPathComponent("\(assets.count + 1) \(stem) - stream \(stream.index).wav")
        let helper = try ReencodeEngine.findHelper(override: nil)
        try ReencodeEngine(cancelled: cancelled).runHelper(helper, arguments: [
            "-n", "-i", media.url.path, "-map", "0:\(stream.index)", "-c:a", "pcm_f32le", "-rf64", "auto", file.path
        ], in: directory)
        let result = try AnalysisSidecar.$automaticWritesEnabled.withValue(false) { try engine.inspectSummary(file) }
        soundFiles[media.url, default: [:]][stream.index] = result
        return result
    }

    private func multicam(_ project: MulticamProject, location: URL, imported: [String: MediaInfo]) throws {
        let plan = try project.plan()
        let preservesEditing = project.angles.contains { $0.coverage != nil || !$0.additionalRecordings.isEmpty }
            || project.assemblyItems?.contains { $0.angleOverride != nil } == true
            || project.assembly?.isEmpty == true
        let writesEditing = fcpDocument && preserveMulticamEditing && preservesEditing
        if fcpDocument, !writesEditing, let ranges = project.assembly {
            var end = RationalTime.zero, incomplete = false
            for range in ranges.sorted(by: { $0.from < $1.from }) {
                if range.from > end { incomplete = true }
                end = max(end, range.to)
            }
            if incomplete || end < project.range.to {
                try warnLoss("The multicam assembly omits part of the group. Switches and group boundaries outside the assembled program cannot round-trip.")
            }
        }
        var media: [String: MediaInfo] = [:]
        var offsets: [String: RationalTime] = [:]
        for source in project.sources {
            let url = project.sourceURL(for: source, relativeTo: location)
            guard !url.path.split(separator: "/").contains("..") else {
                throw CutError(code: "missing_source", message: "An ancestor of \(url.path) is unavailable.")
            }
            if let previous = imported[source.id] {
                try engine.verifyIdentity(url, identity: previous.identity)
                identities[url] = previous.identity
            }
            let info = try inspect(url)
            media[source.id] = info
            offsets[source.id] = try source.offset.adding(info.multicamSourceOffset)
        }
        for span in plan.picture + plan.audio {
            let info = media[span.source]!
            let stream = span.stream.flatMap { id in info.streams.first { $0.index == id && $0.kind == "audio" } }
            let lower = try info.multicamSourceOffset.adding(stream?.start ?? .zero)
            let upper = try (stream?.duration).flatMap { $0 > .zero ? $0 : nil }
                .map { try lower.adding($0) } ?? info.multicamSourceOffset.adding(info.duration)
            guard span.input.from >= lower, span.input.to <= upper else {
                throw CutError(code: span.stream == nil ? "uncovered_picture" : "uncovered_audio",
                               message: "Source \(span.source) does not cover \(span.input.from)–\(span.input.to).")
            }
        }
        let base = min(.zero, offsets.values.min() ?? .zero)
        guard let reference = media[project.referenceAngle]?.videoStream else {
            throw CutError(code: "no_video", message: "The reference camera has no video.")
        }
        let rate = reference.frameRate
        let formatID = try format(reference)
        let groupName = try displayName(name) + " Multicam"
        let group = resources.child("media", ["id": "group", "name": groupName, "uid": UUID().uuidString])
            .child("multicam", ["format": formatID, "tcStart": "0s", "tcFormat": "NDF"])
        var coverage = [String: [MulticamRange]]()
        var recordedIDs = [String: [String]]()
        var extractedAudio = [String: MulticamAudioSelection]()
        var audioLinks = [String: FCPMulticamEditing.AudioLink]()
        let sourceIDs = Set(project.sources.map(\.id))
        var allocated = Set<String>()
        var nextID = 1

        func newAngle(_ label: String, sourceID: String? = nil) throws -> (String, XMLElement) {
            var id: String
            if preservesEditing, let sourceID {
                id = try displayName(sourceID)
                guard id == sourceID else { throw CutError(code: "invalid_angle_id", message: "Camera ID cannot be represented in FCPXML.") }
            } else {
                repeat {
                    id = "angle\(nextID)"
                    nextID += 1
                } while allocated.contains(id) || (preservesEditing && sourceIDs.contains(id))
            }
            allocated.insert(id)
            return (id, group.child("mc-angle", ["angleID": id, "name": try displayName(label)]))
        }

        func appendRecording(_ info: MediaInfo, offset: RationalTime, visible: MulticamRange?,
                             angle: XMLElement, id: String) throws {
            let duration = try assetDuration(info)
            let origin = try offset.subtracting(base)
            let rawFrom = try visible.map { try $0.from.subtracting(base) } ?? max(.zero, origin)
            let rawTo = try visible.map { try $0.to.subtracting(base) } ?? origin.adding(duration)
            let at = try info.hasVideo ? sourceFrame(rawFrom, rate: rate) : rawFrom
            let end = try visible != nil && info.hasVideo ? sourceFrame(rawTo, rate: rate) : at.adding(rawTo.subtracting(rawFrom))
            let start = try rawFrom.subtracting(origin)
            let length = try end.subtracting(at)
            let previous = coverage[id]?.last?.to ?? .zero
            guard at >= previous, length > .zero, start >= .zero, try start.adding(length) <= duration else {
                throw CutError(code: "uncovered_source", message: "Invalid visible extent for \(info.url.lastPathComponent) on angle \(id).")
            }
            if at > previous {
                angle.child("gap", ["offset": previous.fcpxTime, "start": "0s", "duration": try at.subtracting(previous).fcpxTime])
            }
            angle.child("asset-clip", ["ref": try asset(info), "name": try displayName(info.url.lastPathComponent),
                                       "offset": at.fcpxTime, "start": try sourceTime(info, start).fcpxTime,
                                       "duration": length.fcpxTime])
            coverage[id, default: []].append(.init(from: at, to: end))
        }

        var settings: [String: FCPAngleMetadata] = [:]
        var pictures: [String: String] = [:]
        var microphones: [MulticamAudioSelection: String] = [:]
        var selected = Set(try project.groupIntervals().compactMap(\.audio))
        selected.formUnion(plan.intervals.compactMap(\.audio))
        if case .fixed(let master) = project.audio { selected.insert(master) }
        for camera in project.angles {
            let recordings = camera.recordings.sorted { ($0.coverage?.from ?? .zero) < ($1.coverage?.from ?? .zero) }
            let (id, angle) = try newAngle(camera.name ?? media[camera.id]!.url.lastPathComponent, sourceID: camera.id)
            recordedIDs[id] = recordings.map(\.id)
            pictures[camera.id] = id
            settings[id] = .init(audioOnly: false, audioStream: camera.audioStream)
            for recording in recordings {
                let info = media[recording.id]!
                guard info.hasVideo else { throw CutError(code: "no_video", message: "Camera recording \(recording.id) has no video.") }
                try appendRecording(info, offset: offsets[recording.id]!, visible: recording.coverage, angle: angle, id: id)
                let streams = info.streams.filter { $0.kind == "audio" }
                if recording.coverage == nil, streams.count == 1 {
                    microphones[.init(source: recording.id, stream: streams[0].index)] = id
                }
            }
        }
        let external = Set(project.audioSources.map(\.id))
        for source in project.sources {
            let info = media[source.id]!, offset = offsets[source.id]!
            let label = source.name ?? info.url.lastPathComponent
            let streams = info.streams.filter { $0.kind == "audio" }
            if external.contains(source.id), preservesEditing || streams.count == 1 {
                let (id, angle) = try newAngle(label, sourceID: source.id)
                try appendRecording(info, offset: offset, visible: nil, angle: angle, id: id)
                settings[id] = .init(audioOnly: true, audioStream: source.audioStream)
                recordedIDs[id] = [source.id]
                if streams.count == 1 { microphones[.init(source: source.id, stream: streams[0].index)] = id }
            }
            for stream in streams {
                let selection = MulticamAudioSelection(source: source.id, stream: stream.index)
                guard microphones[selection] == nil, selected.contains(selection) || external.contains(source.id) else { continue }
                let isolate = streams.count > 1 || info.hasVideo
                let sound = try isolate ? soundFile(info, stream: stream) : info
                let (id, angle) = try newAngle("\(label) · stream \(stream.index)")
                let soundOffset = try isolate ? offset.adding(stream.start) : offset
                try appendRecording(sound, offset: soundOffset, visible: nil, angle: angle, id: id)
                settings[id] = .init(audioOnly: true, audioStream: sound.streams.first { $0.kind == "audio" }?.index)
                microphones[selection] = id
                extractedAudio[id] = selection
                audioLinks[id] = .init(path: assetLink(sound.url), offset: try soundOffset.subtracting(sound.multicamSourceOffset),
                                       originalPath: assetLink(info.url), originalOffset: source.offset)
            }
        }
        if fcpDocument {
            let metadata = group.child("metadata")
            if writesEditing {
                let sourceCoverage = Dictionary(uniqueKeysWithValues: project.sources.compactMap { source in
                    source.coverage.map { (source.id, $0) }
                })
                let sourceSettings = Dictionary(uniqueKeysWithValues: project.sources.map {
                    ($0.id, FCPAngleMetadata(audioOnly: external.contains($0.id), audioStream: $0.audioStream, name: $0.name))
                })
                let editing = FCPMulticamEditing(range: project.range, switches: project.switches, audio: project.audio,
                                                 assemblyItems: project.assemblyItems, recordings: recordedIDs,
                                                 extractedAudio: extractedAudio, sourceCoverage: sourceCoverage, sourceSettings: sourceSettings,
                                                 audioLinks: audioLinks)
                metadata.child("md", ["key": FCPGroupMetadata.editing, "value": String(decoding: try JSONEncoder().encode(editing), as: UTF8.self)])
            }
            if base != .zero {
                metadata.child("md", ["key": FCPGroupMetadata.base, "value": base.description])
            }
            metadata.child("md", ["key": FCPGroupMetadata.sources,
                                  "value": String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)])
            metadata.child("md", ["key": FCPGroupMetadata.reference, "value": pictures[project.referenceAngle]!])
            let mode: String?
            switch project.audio {
            case .none: mode = "none"
            case .follow: mode = "follow"
            case .fixed(let selection): mode = microphones[selection].map { "fixed:" + $0 }
            case .mix:
                throw CutError(code: "unsupported_multicam_audio", message: "This timeline cannot represent simultaneous Mix lanes.")
            }
            if let mode { metadata.child("md", ["key": FCPGroupMetadata.audio, "value": mode]) }
        }
        let stillAssets = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0) })
        var pending = [(index: Int, position: RationalTime, insert: StillInsert)]()
        if let items = project.assemblyItems {
            var position = RationalTime.zero
            for (index, item) in items.enumerated() {
                if let range = item.group {
                    position = try position.adding(range.to.subtracting(range.from))
                } else if let insert = item.still {
                    pending.append((index, position, insert))
                    position = try position.adding(insert.duration)
                }
            }
        }
        var nextInsert = 0
        var omittedDuration = RationalTime.zero
        func writeStills(before nextAssemblyIndex: Int) throws {
            while nextInsert < pending.count, pending[nextInsert].index < nextAssemblyIndex {
                let point = pending[nextInsert]
                let position = try point.position.subtracting(omittedDuration)
                guard let image = stillAssets[point.insert.assetID] else {
                    throw CutError(code: "invalid_cut_project", message: "Missing still asset for \(point.insert.id).")
                }
                if try !alignedStill(point.insert, at: position, rate: rate) {
                    recordStillLoss("Final Cut Pro cannot represent Insert Still placement \(point.insert.id) at the assembly's \(rate) fps cadence and exact boundaries. The insert and its silence will be removed.")
                    omittedDuration = try omittedDuration.adding(point.insert.duration)
                } else if try !stillVideo(point.insert, image: image, relativeTo: location, at: position,
                                          colorPolicy: project.programColorPolicy, standalone: nil,
                                          cameraTransfer: reference.colorTransfer) {
                    omittedDuration = try omittedDuration.adding(point.insert.duration)
                }
                nextInsert += 1
            }
        }
        for interval in plan.intervals {
            try engine.checkCancellation()
            try writeStills(before: interval.assemblyIndex)
            let angle = pictures[interval.angle]!
            let at = try framePosition(interval.output.from.subtracting(omittedDuration), rate: rate)
            let length = try framePosition(interval.output.to.subtracting(omittedDuration), rate: rate).subtracting(at)
            try requireFrame(length)
            let sourceStart = try sourceFrame(interval.group.from.subtracting(base), rate: rate)
            let mic = interval.audio.flatMap { microphones[$0] }
            let sourceEnd = try sourceStart.adding(length)
            if interval.pictureSourceID == nil,
               coverage[angle]?.contains(where: { $0.from < sourceEnd && sourceStart < $0.to }) == true {
                throw CutError(code: "uncovered_source", message: "Rounding this camera gap would expose a recorded frame.")
            }
            if fcpDocument {
                for id in [interval.pictureSourceID == nil ? nil : angle, mic].compactMap({ $0 }) {
                    guard coverage[id]?.contains(where: { $0.from <= sourceStart && sourceEnd <= $0.to }) == true else {
                        throw CutError(code: "uncovered_source", message: "The rounded timeline cut exceeds its selected angle. Shorten the range by a frame.")
                    }
                }
            }
            let clip = spine.child("mc-clip", ["ref": "group", "name": groupName,
                "offset": at.fcpxTime, "start": sourceStart.fcpxTime,
                "duration": length.fcpxTime])
            if interval.audio != nil && mic == nil {
                throw CutError(code: "missing_audio", message: "The audio selected at \(interval.group.from) is unavailable.")
            }
            clip.child("mc-source", ["angleID": angle, "srcEnable": mic == angle ? "all" : "video"])
            if let mic, mic != angle { clip.child("mc-source", ["angleID": mic, "srcEnable": "audio"]) }
        }
        try writeStills(before: Int.max)
        try checkStillLoss()
        try finish(format: formatID, duration: framePosition(plan.duration.subtracting(omittedDuration), rate: rate))
    }

    private func requireFrame(_ length: RationalTime) throws {
        guard length > .zero else {
            throw CutError(code: "subframe_edit", message: "A cut is shorter than one frame at its position on the Resolve timeline.")
        }
    }

    private func alignedStill(_ insert: StillInsert, at position: RationalTime, rate: RationalTime) throws -> Bool {
        let end = try position.adding(insert.duration)
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        return try insert.cadence == cadence && position.onFrameGrid(rate) == position && end.onFrameGrid(rate) == end
    }

    private func sequence(_ clips: [ClipRequest], inserts: [Int: StillInsert] = [:], stillAssets: [String: StillAsset] = [:],
                          colorPolicy: StillProgramColorPolicy? = nil, standalone: StillTimelineFormat? = nil,
                          location: URL? = nil) throws {
        var cache: [URL: MediaInfo] = [:]
        var video: StreamInfo?
        var position = RationalTime.zero
        for clip in clips where cache[clip.file] == nil {
            let info = try inspect(clip.file)
            cache[clip.file] = info
            if video == nil { video = info.videoStream }
        }
        let standaloneRate = standalone.map { RationalTime(numerator: $0.cadence.denominator, denominator: $0.cadence.numerator) }
        let rate = video?.frameRate ?? standaloneRate ?? RationalTime(numerator: 24)
        var ordinal = 0
        for index in 0..<(clips.count + inserts.count) {
            try engine.checkCancellation()
            if let insert = inserts[index] {
                guard let location, let image = stillAssets[insert.assetID] else {
                    throw CutError(code: "invalid_cut_project", message: "Missing still asset for \(insert.id).")
                }
                let end = try position.adding(insert.duration)
                let aligned = try alignedStill(insert, at: position, rate: rate)
                if (video == nil && standalone == nil) || !aligned {
                    recordStillLoss("Final Cut Pro cannot represent Insert Still placement \(insert.id) at the sequence's \(rate) fps cadence and exact boundaries. The insert and its silence will be removed.")
                    continue
                }
                if try stillVideo(insert, image: image, relativeTo: location, at: position, colorPolicy: colorPolicy, standalone: standalone,
                                  cameraTransfer: video?.colorTransfer) {
                    position = end
                }
                continue
            }
            let clip = clips[ordinal]
            let info = cache[clip.file]!
            let rawStart = clip.from ?? .zero, end = clip.to ?? info.duration
            let start = try info.videoStream.map { try sourceFrame(rawStart, rate: $0.frameRate) } ?? rawStart
            if let video = info.videoStream { _ = try sourceFrame(end, rate: video.frameRate) }
            guard rawStart >= .zero, end <= info.duration, end > start else {
                throw CutError(code: "invalid_range", message: "Invalid source range for \(info.url.lastPathComponent).")
            }
            let at = try framePosition(position, rate: rate)
            position = try position.adding(end.subtracting(rawStart))
            let length = try framePosition(position, rate: rate).subtracting(at)
            try requireFrame(length)
            if fcpDocument, try start.adding(length) > assetDuration(info) {
                throw CutError(code: "uncovered_source", message: "The rounded timeline cut extends beyond \(info.url.lastPathComponent). Shorten the source range by a frame.")
            }
            let streams = info.streams.filter { $0.kind == "audio" }
            var fields = ["offset": at.fcpxTime, "start": start.fcpxTime, "duration": length.fcpxTime,
                          "name": try displayName(info.url.lastPathComponent)]
            let node: XMLElement
            if streams.count <= 1 || !isolateSequenceAudio {
                fields["start"] = try sourceTime(info, start).fcpxTime
                fields["ref"] = try asset(info)
                node = spine.child("asset-clip", fields)
            } else {
                node = spine.child("clip", fields)
                if info.hasVideo {
                    node.child("video", ["ref": try asset(info), "offset": start.fcpxTime, "start": try sourceTime(info, start).fcpxTime,
                                           "duration": length.fcpxTime])
                }
                for (index, stream) in streams.enumerated() {
                    let sound = try soundFile(info, stream: stream)
                    let from = max(start, stream.start), to = try min(start.adding(length), stream.start.adding(sound.duration))
                    guard from < to else { continue }
                    node.child("audio", ["ref": try asset(sound), "lane": String(index - streams.count),
                        "offset": from.fcpxTime, "start": try from.subtracting(stream.start).fcpxTime,
                        "duration": try to.subtracting(from).fcpxTime])
                }
            }
            if !clipMetadata.isEmpty {
                let value = String(decoding: try JSONEncoder().encode(clipMetadata[ordinal]), as: UTF8.self)
                    .replacingOccurrences(of: "\u{FFFE}", with: "\\uFFFE")
                    .replacingOccurrences(of: "\u{FFFF}", with: "\\uFFFF")
                node.child("metadata").child("md", ["key": FCPClipMetadata.key, "value": value])
            }
            ordinal += 1
        }
        try checkStillLoss()
        guard position > .zero else {
            let message = warnings.isEmpty ? "Add clips to the timeline first." :
                (["The conversion leaves no timeline material."] + warnings).joined(separator: "\n")
            throw CutError(code: "empty_sequence", message: message)
        }
        let formatID = try standalone.map { try format(width: $0.width, height: $0.height, rate: rate) } ?? format(video)
        try finish(format: formatID, duration: framePosition(position, rate: rate))
    }

    private func stillVideo(_ insert: StillInsert, image: StillAsset, relativeTo location: URL,
                            at position: RationalTime, colorPolicy: StillProgramColorPolicy?, standalone: StillTimelineFormat?,
                            cameraTransfer: String?) throws -> Bool {
        let url = try CutProject.checkedMediaURL(image.file, relativeTo: location)
        let media: (info: StillImageInfo, fingerprint: String)
        if let cached = stillMedia[url] {
            media = cached
        } else {
            guard let identity = try? SourceIdentity(url) else {
                throw CutError(code: "still_offline", message: "Relink \(image.displayName) for Insert Still placement \(insert.id).")
            }
            media = try StillImage.inspectAndFingerprint(url, expectedIdentity: identity, cancelled: cancelled)
            identities[url] = identity
            stillMedia[url] = media
        }
        guard media.fingerprint == image.fingerprint else {
            throw CutError(code: "still_source_changed", message: "Relink the edited image for Insert Still placement \(insert.id).")
        }
        let hdr = ["smpte2084", "arib-std-b67", "pq", "hlg"]
        let info = media.info
        guard [.jpeg, .png, .tiff].contains(info.codec), info.rendition == .sdr, !info.hasAlpha,
              !hdr.contains(colorPolicy?.transfer.lowercased() ?? ""), !hdr.contains(cameraTransfer?.lowercased() ?? "") else {
            recordStillLoss("Final Cut Pro cannot preserve the linked format, color or alpha for Insert Still placement \(insert.id). The insert and its silence will be removed.")
            return false
        }
        let key = "still-\(info.displayWidth)x\(info.displayHeight)"
        let formatID: String
        if let existing = formats[key] {
            formatID = existing
        } else {
            formatID = "f\(formats.count + 1)"
            formats[key] = formatID
            resources.child("format", ["id": formatID, "name": "FFVideoFormatRateUndefined",
                                       "width": String(info.displayWidth), "height": String(info.displayHeight)])
        }
        // A still is timeless in the resources. Its video item carries the exact hold.
        stillResourceCount += 1
        let ref = "still\(stillResourceCount)"
        let name = try displayName(image.displayName)
        let asset = resources.child("asset", ["id": ref, "name": name, "start": "0s", "duration": "0s",
                                              "format": formatID, "hasVideo": "1", "videoSources": "1"])
        asset.child("media-rep", ["kind": "original-media", "src": url.absoluteString])
        let metadata = FCPStillMetadata(placementID: insert.id, assetID: image.id, fingerprint: image.fingerprint,
                                       colorPolicy: colorPolicy, standalone: standalone)
        let value = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
            .replacingOccurrences(of: "\u{FFFE}", with: "\\uFFFE")
            .replacingOccurrences(of: "\u{FFFF}", with: "\\uFFFF")
        asset.child("metadata").child("md", ["key": FCPStillMetadata.key, "value": value])
        spine.child("video", ["ref": ref, "offset": position.fcpxTime, "start": "0s",
                              "duration": insert.duration.fcpxTime, "name": name])
            .child("adjust-conform", ["type": insert.framing == .fill ? "fill" : "fit"])
        return true
    }

    private func finish(format: String, duration: RationalTime) throws {
        let root = XMLElement(name: "fcpxml")
        root.setAttributesWith(["version": bundleDestination == nil ? "1.9" : "1.10"])
        root.addChild(resources)
        let title = try displayName(name)
        root.child("library").child("event", ["name": title]).child("project", ["name": title])
            .child("sequence", ["format": format, "duration": duration.fcpxTime, "tcStart": "0s", "tcFormat": "NDF"])
            .addChild(spine)
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        try engine.checkCancellation()
        let stage = output.deletingLastPathComponent().appendingPathComponent(".mpcut-\(UUID().uuidString).fcpxml")
        try document.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement]).write(to: stage, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: stage) }
        try engine.checkCancellation()
        for (url, identity) in identities { try engine.verifyIdentity(url, identity: identity) }
        try engine.checkCancellation()
        let error = publishExclusively(from: stage, to: output)
        guard error == 0 else {
            throw CutError(code: error == EEXIST ? "output_exists" : "write_failed",
                           message: "Could not save \(output.path): \(String(cString: strerror(error)))")
        }
        committed = true
    }
}
