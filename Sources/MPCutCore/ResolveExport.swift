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
    private var soundFiles: [URL: [Int: MediaInfo]] = [:]
    private var audioDirectory: URL?
    private var committed = false
    private var clipMetadata = [FCPClipMetadata]()
    private var fcpDocument = false
    private var isolateSequenceAudio = true
    private var allowLoss = true
    private var warnings = [String]()
    private var warned = Set<String>()
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

    public static func write(_ project: MulticamProject, relativeTo location: URL, to output: URL,
                             useSidecar: Bool = true, matching imported: [String: MediaInfo] = [:],
                             auxiliaryOutput: ((URL) -> Void)? = nil,
                             cancelled: (@Sendable () -> Bool)? = nil) throws {
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
                         auxiliaryOutput: ((URL) -> Void)? = nil,
                         cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try ProjectConverter.checkCancellation(cancelled)
        let writer = try ResolveExport(xml, useSidecar: false, cancelled: cancelled)
        writer.fcpDocument = true
        writer.isolateSequenceAudio = isolateSequenceAudio
        writer.allowLoss = allowLoss
        writer.bundleDestination = package
        switch project {
        case .sequence(let clips):
            writer.clipMetadata = try clips.map { clip in
                try FCPClipMetadata(id: clip.id, audioTrack: clip.audioTrack,
                                originalFile: clip.originalFile.map { try CutProject.checkedMediaURL($0, relativeTo: location).path },
                                replacementNames: clip.replacementNames)
            }
            try writer.sequence(project.requests(relativeTo: location))
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
        guard rate > .zero else { throw CutError(code: "invalid_frame_rate", message: "Missing source frame rate.") }
        let width = video?.displayWidth ?? 1920, height = video?.displayHeight ?? 1080
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
        var source = media.url.absoluteString
        if bundleDestination != nil, let audioDirectory,
           media.url.deletingLastPathComponent().standardizedFileURL.path == audioDirectory.standardizedFileURL.path {
            source = URL(fileURLWithPath: "/" + audioDirectory.lastPathComponent + "/" + media.url.lastPathComponent).path(percentEncoded: true)
            source.removeFirst()
        }
        resources.child("asset", fields).child("media-rep", ["kind": "original-media", "src": source])
        return id
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
        if fcpDocument, let ranges = project.assembly {
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
        var coverage = [String: MulticamRange]()
        func addAngle(_ label: String, _ info: MediaInfo, _ offset: RationalTime) throws -> String {
            let id = "angle\(group.childCount + 1)"
            let angle = group.child("mc-angle", ["angleID": id, "name": try displayName(label)])
            let raw = try offset.subtracting(base)
            let at = try info.hasVideo ? sourceFrame(raw, rate: rate) : raw
            let start = try max(.zero, RationalTime.zero.subtracting(at))
            let duration = try assetDuration(info)
            guard start < duration else { throw CutError(code: "uncovered_source", message: "Empty angle \(label).") }
            if at > .zero { angle.child("gap", ["offset": "0s", "start": "0s", "duration": at.fcpxTime]) }
            angle.child("asset-clip", ["ref": try asset(info), "name": try displayName(info.url.lastPathComponent),
                                       "offset": max(.zero, at).fcpxTime, "start": try sourceTime(info, start).fcpxTime,
                                       "duration": try duration.subtracting(start).fcpxTime])
            coverage[id] = try .init(from: max(.zero, at), to: at.adding(duration))
            return id
        }
        var settings: [String: FCPAngleMetadata] = [:]
        var pictures: [String: String] = [:]
        var microphones: [MulticamAudioSelection: String] = [:]
        var selected = Set(try project.groupIntervals().compactMap(\.audio))
        if case .fixed(let master) = project.audio { selected.insert(master) }
        let cameraIDs = Set(project.angles.map(\.id))
        for source in project.sources {
            let info = media[source.id]!, offset = offsets[source.id]!
            let label = source.name ?? info.url.lastPathComponent
            let isCamera = cameraIDs.contains(source.id)
            guard !isCamera || info.hasVideo else {
                throw CutError(code: "no_video", message: "Camera \(label) has no video.")
            }
            let streams = info.streams.filter { $0.kind == "audio" }
            if isCamera || streams.count == 1 {
                let id = try addAngle(label, info, offset)
                settings[id] = .init(audioOnly: !isCamera, audioStream: source.audioStream)
                if isCamera { pictures[source.id] = id }
                if streams.count == 1 { microphones[.init(source: source.id, stream: streams[0].index)] = id }
            }
            for stream in streams where streams.count > 1 {
                let selection = MulticamAudioSelection(source: source.id, stream: stream.index)
                if !isCamera || selected.contains(selection) {
                    let sound = try soundFile(info, stream: stream)
                    microphones[selection] = try addAngle("\(label) · stream \(stream.index)", sound, offset.adding(stream.start))
                }
            }
        }
        if fcpDocument {
            let metadata = group.child("metadata")
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
            }
            if let mode { metadata.child("md", ["key": FCPGroupMetadata.audio, "value": mode]) }
        }
        for interval in plan.intervals {
            try engine.checkCancellation()
            let angle = pictures[interval.angle]!
            let at = try framePosition(interval.output.from, rate: rate)
            let length = try framePosition(interval.output.to, rate: rate).subtracting(at)
            try requireFrame(length)
            let sourceStart = try sourceFrame(interval.group.from.subtracting(base), rate: rate)
            let mic = interval.audio.flatMap { microphones[$0] }
            if fcpDocument {
                let sourceEnd = try sourceStart.adding(length)
                for id in [angle, mic].compactMap({ $0 }) {
                    guard let range = coverage[id], range.from <= sourceStart, sourceEnd <= range.to else {
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
        try finish(format: formatID, duration: framePosition(plan.duration, rate: rate))
    }

    private func requireFrame(_ length: RationalTime) throws {
        guard length > .zero else {
            throw CutError(code: "subframe_edit", message: "A cut is shorter than one frame at its position on the Resolve timeline.")
        }
    }

    private func sequence(_ clips: [ClipRequest]) throws {
        var cache: [URL: MediaInfo] = [:]
        var video: StreamInfo?
        var position = RationalTime.zero
        for clip in clips where cache[clip.file] == nil {
            let info = try inspect(clip.file)
            cache[clip.file] = info
            if video == nil { video = info.videoStream }
        }
        let rate = video?.frameRate ?? RationalTime(numerator: 24)
        for (ordinal, clip) in clips.enumerated() {
            try engine.checkCancellation()
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
        }
        guard position > .zero else { throw CutError(code: "empty_sequence", message: "Add clips to the timeline first.") }
        try finish(format: format(video), duration: framePosition(position, rate: rate))
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
