import Darwin
import Foundation

/// Final Cut's published XML timeline interchange. A package contains Info.fcpxml.
public enum FCPInterchange {
    public static func read(_ url: URL, allowLoss: Bool = false) throws -> (CutProject, [String]) {
        let xml = url.pathExtension.lowercased() == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
        let reader = FCPReader(location: xml, allowLoss: allowLoss)
        let project = try reader.read()
        try project.validate()
        return (project, reader.warnings)
    }

    static func loadDocument(_ location: URL) throws -> XMLDocument {
        let limit = MulticamProject.maximumFileSize
        let fd = open(location.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw invalidFCP("Cannot read \(location.path): \(String(cString: strerror(errno))).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0, statInfo.st_mode & S_IFMT == S_IFREG, statInfo.st_size <= limit else {
            throw invalidFCP("Expected a regular FCPXML file of at most 64 MiB.")
        }
        var data = Data()
        while data.count <= limit {
            guard let block = try file.read(upToCount: min(limit + 1 - data.count, 1 << 20)), !block.isEmpty else { break }
            data.append(block)
        }
        guard data.count <= limit,
              let xml = String(data: data, encoding: .utf8), !xml.contains("\0"),
              !xml.contains("<!ENTITY"),
              !xml.contains("<!DOCTYPE") || xml.range(of: #"<!DOCTYPE(?!\s+fcpxml\s*>)"#, options: .regularExpression) == nil
        else { throw invalidFCP("Expected UTF-8 FCPXML up to 64 MiB without entity declarations or external DTDs.") }
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    public static func write(_ project: CutProject, relativeTo location: URL, to output: URL,
                             allowLoss: Bool = false, auxiliaryOutput: ((URL) -> Void)? = nil,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try ProjectConverter.checkCancellation(cancelled)
        try project.validate()
        guard output.pathExtension.lowercased() == "fcpxmld" else {
            return try ResolveExport.writeFCP(project, relativeTo: location, to: output, package: nil, allowLoss: allowLoss,
                                              auxiliaryOutput: auxiliaryOutput, cancelled: cancelled)
        }
        let stage = output.deletingLastPathComponent().appendingPathComponent(".mpcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let warnings = try ResolveExport.writeFCP(project, relativeTo: location, to: stage.appendingPathComponent("Info.fcpxml"),
                                                  package: output, allowLoss: allowLoss, cancelled: cancelled)
        try ProjectConverter.checkCancellation(cancelled)
        let error = publishExclusively(from: stage, to: output, isDirectory: true)
        guard error == 0 else {
            throw CutError(code: error == EEXIST ? "output_exists" : "write_failed",
                           message: "Could not save \(output.path): \(String(cString: strerror(error)))")
        }
        return warnings
    }
}

private func invalidFCP(_ message: String) -> CutError {
    CutError(code: "invalid_fcpxml", message: message)
}

private extension XMLElement {
    var elements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func attr(_ key: String) -> String? { attribute(forName: key)?.stringValue }
    func required(_ key: String) throws -> String {
        guard let value = attr(key), !value.isEmpty else { throw invalidFCP("Missing \(key) on <\(name ?? "?")>.") }
        return value
    }
    func time(_ key: String, default fallback: RationalTime? = nil) throws -> RationalTime {
        if attr(key) == nil, let fallback { return fallback }
        let raw = try required(key)
        guard raw.hasSuffix("s") else { throw invalidFCP("Expected seconds in \(key)=\(raw).") }
        return try RationalTime(parsing: String(raw.dropLast()))
    }
}

private final class FCPReader {
    let location: URL
    let allowLoss: Bool
    var warnings = [String]()
    private var warned = Set<String>()
    var resources = [String: XMLElement]()
    private var assetURLs = [String: URL]()
    let engine = CutEngine(useSidecar: false)
    var media = [URL: MediaInfo]()

    init(location: URL, allowLoss: Bool) {
        self.location = location
        self.allowLoss = allowLoss
    }

    func loss(_ message: String) throws {
        guard allowLoss else { throw CutError(code: "conversion_loss", message: message) }
        if warned.insert(message).inserted { warnings.append(message) }
    }

    func read() throws -> CutProject {
        let document = try FCPInterchange.loadDocument(location)
        guard let root = document.rootElement(), root.name == "fcpxml",
              let version = root.attr("version"), version.hasPrefix("1."),
              let revision = Int(version.dropFirst(2)), revision > 0 else {
            throw invalidFCP("Expected an FCPXML 1.x document.")
        }
        if revision > 14 { try loss("FCPXML version \(version) exceeds the supported 1.14 vocabulary.") }
        for node in root.elements(forName: "resources").flatMap(\.elements) {
            let id = try node.required("id")
            guard resources.updateValue(node, forKey: id) == nil else { throw invalidFCP("Duplicate resource ID \(id).") }
        }
        let browserItems = try root.nodes(forXPath: "./library/event/*[not(self::project)] | ./event/*[not(self::project)]")
        if !browserItems.isEmpty {
            try loss("Removed \(browserItems.count) browser items outside the project timeline.")
        }
        let sequences = try root.nodes(forXPath: "./project/sequence | ./event/project/sequence | ./library/event/project/sequence")
        guard sequences.count == 1, let sequence = sequences.first as? XMLElement,
              sequence.elements(forName: "spine").count == 1, let spine = sequence.elements(forName: "spine").first
        else { throw invalidFCP("Select one project with exactly one timeline and primary storyline for conversion.") }
        try checkChildren(sequence, keeping: ["spine"])
        let origin = try sequence.time("tcStart", default: .zero)
        if origin != .zero || sequence.attr("tcFormat") == "DF" {
            try loss("MPCut displays elapsed time from zero. The sequence timecode origin or drop-frame display will be removed.")
        }
        var cursor = origin, clips = [XMLElement]()
        for item in spine.elements {
            let kind = item.name ?? "unknown"
            guard ["mc-clip", "asset-clip", "clip", "video", "audio", "gap"].contains(kind) else {
                try loss("Skipped unsupported storyline element <\(kind)>.")
                continue
            }
            let offset = try item.time("offset", default: cursor)
            let duration = try item.time("duration")
            guard duration > .zero else { throw invalidFCP("Empty or negative \(kind) duration.") }
            if offset != cursor { try loss("Closed a timeline gap or overlap before \(item.attr("name") ?? kind) at \(offset)s.") }
            cursor = try offset.adding(duration)
            if item.attr("enabled") == "0" {
                try loss("Removed \(duration)s of disabled material and its connected clips.")
            } else if kind == "gap" {
                clips += try attachedClips(in: item, duration: duration)
            } else { clips.append(item) }
        }
        if sequence.attr("duration") != nil, try sequence.time("duration") != cursor.subtracting(origin) {
            try loss("The declared sequence duration differs from its storyline. Imported the storyline duration.")
        }
        guard !clips.isEmpty else { throw invalidFCP("The timeline contains no supported clips.") }
        try checkFormat(sequence, first: clips[0])
        if clips.contains(where: { $0.name == "mc-clip" }) {
            guard clips.allSatisfy({ $0.name == "mc-clip" }) else {
                throw invalidFCP("Mixed multicam and ordinary storylines cannot be represented in a single MPCut project.")
            }
            return .multicam(try multicam(clips))
        }
        var suppliedIDs = Set<String>()
        var imported = try clips.map { node in
            let source = try linked(node)
            var clip = try CutSequenceClip(id: "", file: source.url.path, from: source.start,
                                           to: source.start.adding(node.time("duration")))
            if let value = node.elements(forName: "metadata").flatMap({ $0.elements(forName: "md") })
                .first(where: { $0.attr("key") == FCPClipMetadata.key })?.attr("value") {
                let fields = try JSONDecoder().decode(FCPClipMetadata.self, from: Data(value.utf8))
                if suppliedIDs.insert(fields.id).inserted { clip.id = fields.id }
                clip.audioTrack = fields.audioTrack
                clip.originalFile = fields.originalFile
                clip.replacementNames = fields.replacementNames
            }
            return clip
        }
        var next = 1
        for index in imported.indices where imported[index].id.isEmpty {
            while !suppliedIDs.insert("clip-\(next)").inserted { next += 1 }
            imported[index].id = "clip-\(next)"
            next += 1
        }
        return .sequence(imported)
    }

    func checkFormat(_ sequence: XMLElement, first: XMLElement) throws {
        for key in ["audioLayout", "audioRate", "renderFormat", "keywords"] where sequence.attr(key) != nil {
            try loss("The sequence's \(key) setting is not stored in a .cut project.")
        }
        guard let formatID = sequence.attr("format") else { return }
        guard let format = resources[formatID], format.name == "format" else {
            throw invalidFCP("Missing sequence format \(formatID).")
        }
        let ref = first.attr("ref") ?? first.elements(forName: "video").first?.attr("ref")
        guard let ref, let media = resources[ref] else { return }
        let sourceFormatID = media.attr("format") ?? media.elements(forName: "multicam").first?.attr("format")
        if let sourceFormatID, let sourceFormat = resources[sourceFormatID] {
            let different = ["frameDuration", "width", "height", "paspH", "paspV", "colorSpace", "fieldOrder"].filter { key in
                if key == "frameDuration", let left = try? format.time(key), let right = try? sourceFormat.time(key) { return left != right }
                return format.attr(key) != sourceFormat.attr(key)
            }
            if !different.isEmpty {
                try loss("Sequence and source formats differ in \(different.joined(separator: ", ")). MPCut derives output format from source media.")
            }
        }
    }

    /// Resolve exports an audio-only timeline as connected recordings on a gap.
    func attachedClips(in gap: XMLElement, duration: RationalTime) throws -> [XMLElement] {
        let kinds: Set<String> = ["asset-clip", "clip", "video", "audio", "mc-clip"]
        let attached = gap.elements.filter { kinds.contains($0.name ?? "") }
        try checkChildren(gap, keeping: kinds)
        guard !attached.isEmpty else {
            try loss("Removed \(duration)s of empty timeline gap.")
            return []
        }
        let start = try gap.time("start", default: .zero)
        let limit = try start.adding(duration)
        var points = [(offset: RationalTime, lane: Int, index: Int, node: XMLElement)]()
        for (index, item) in attached.enumerated() {
            if item.attr("enabled") == "0" {
                try loss("Removed a disabled connected recording.")
                continue
            }
            guard let lane = Int(item.attr("lane") ?? "0") else { throw invalidFCP("Invalid connected lane.") }
            points.append((try item.time("offset", default: start), lane, index, item))
        }
        points.sort { ($0.offset, $0.lane, $0.index) < ($1.offset, $1.lane, $1.index) }
        var at = start, result = [XMLElement]()
        for point in points {
            let length = try point.node.time("duration")
            let end = try point.offset.adding(length)
            guard length > .zero, point.offset >= start, end <= limit else {
                throw invalidFCP("A connected source has an invalid range inside its enclosing gap.")
            }
            if point.offset < at {
                try loss("Simultaneous connected clips cannot share one MPCut sequence clip. Dropped the overlapping clip on lane \(point.lane).")
                continue
            }
            if point.offset > at { try loss("Closed a gap before a connected clip on lane \(point.lane).") }
            result.append(point.node)
            at = end
        }
        if at != limit { try loss("Removed trailing silence from the connected storyline.") }
        return result
    }

    func checkChildren(_ node: XMLElement, keeping names: Set<String>) throws {
        for child in node.elements where !names.contains(child.name ?? "") {
            let kind = child.name ?? "unknown"
            if kind == "metadata" {
                let recognized = node.name == "multicam" ? [FCPGroupMetadata.reference, FCPGroupMetadata.audio, FCPGroupMetadata.base, FCPGroupMetadata.sources] : [FCPClipMetadata.key]
                if child.elements.allSatisfy({ $0.name == "md" && recognized.contains($0.attr("key") ?? "") }) { continue }
            }
            if kind == "adjust-conform" && child.attr("type") == "fit" && child.elements.isEmpty { continue }
            if kind == "adjust-transform", child.elements.isEmpty,
               (child.attributes ?? []).allSatisfy({ attr in
                   let defaults = ["position": "0 0", "anchor": "0 0", "scale": "1 1", "rotation": "0"]
                   return defaults[attr.name ?? ""] == attr.stringValue
               }) { continue }
            try loss("Removed <\(kind)> from \(node.attr("name") ?? node.name ?? "timeline").")
        }
    }

    func checkTiming(_ node: XMLElement) throws {
        if let raw = node.attr("srcCh") {
            let channels = raw.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            let expected = node.attr("ref").flatMap { resources[$0]?.attr("audioChannels") }.flatMap(Int.init)
            // Resolve may list 1, 2 on mono media; the second channel does not exist.
            if channels.isEmpty || !channels.enumerated().allSatisfy({ $0.element == $0.offset + 1 })
                || expected.map({ channels.count < $0 }) != false {
                try loss("Removed source channel routing \(raw) from \(node.attr("name") ?? node.name ?? "clip").")
            }
        }
        for key in ["audioStart", "audioDuration", "srcID", "videoRole", "audioRole", "role"] where node.attr(key) != nil {
            try loss("Removed \(key) on \(node.attr("name") ?? node.name ?? "clip").")
        }
    }

    /// A source point measured from the beginning of the original recording.
    struct Linked {
        let asset: XMLElement
        let url: URL
        let start: RationalTime
    }

    func linked(_ node: XMLElement) throws -> Linked {
        try checkTiming(node)
        var source = node
        var start = try node.time("start", default: .zero)
        if node.name == "clip" {
            let components = node.elements.filter { ["video", "audio"].contains($0.name) }
            guard let primary = components.first(where: { $0.name == "video" }) ?? components.first else {
                throw invalidFCP("The clip has no direct video or audio asset.")
            }
            try checkChildren(node, keeping: ["video", "audio"])
            source = primary
            try checkTiming(primary)
            if primary.attr("enabled") == "0" || primary.attr("srcEnable").map({ $0 != "all" }) == true {
                try loss("Restored disabled components on the primary recording.")
            }
            let offset = try primary.time("offset", default: .zero)
            if primary.attr("duration") != nil,
               try offset > start || offset.adding(primary.time("duration")) < start.adding(node.time("duration")) {
                try loss("Extended a partial primary component to cover the enclosing clip.")
            }
            start = try primary.time("start", default: .zero).adding(start.subtracting(offset))
            let others = components.filter { $0 !== primary } + primary.elements(forName: "audio")
            try checkChildren(primary, keeping: ["audio"])
            for audio in others {
                if audio.name != "audio" || audio.attr("ref") != primary.attr("ref")
                    || audio.attr("enabled") == "0" {
                    try loss("Dropped separate or disabled component in \(node.attr("name") ?? "clip") and used the primary asset's embedded audio.")
                } else {
                    // An audio child is anchored to the video clock. A sibling is anchored to the clip clock.
                    let parentPoint = audio.parent === primary ? start : try node.time("start", default: .zero)
                    let sound = try audio.time("start", default: .zero).adding(parentPoint.subtracting(audio.time("offset", default: .zero)))
                    if sound != start { try loss("Removed an independent audio slip in \(node.attr("name") ?? "clip").") }
                }
                try checkTiming(audio)
                if let enabled = audio.attr("srcEnable"), enabled != "all" && enabled != "audio" {
                    try loss("Restored disabled audio from a restricted component.")
                }
                if audio.attr("duration") != nil {
                    let parentPoint = audio.parent === primary ? start : try node.time("start", default: .zero)
                    let offset = try audio.time("offset", default: .zero)
                    if try offset > parentPoint || offset.adding(audio.time("duration")) < parentPoint.adding(node.time("duration")) {
                        try loss("Extended a partial audio component to match its picture clip.")
                    }
                }
                try checkChildren(audio, keeping: [])
            }
            if others.isEmpty && primary.name == "video", let ref = primary.attr("ref"), resources[ref]?.attr("hasAudio") == "1" {
                try loss("Restored the primary asset's embedded sound on a video-only clip.")
            }
        } else {
            try checkChildren(node, keeping: [])
        }
        if let enabled = node.attr("srcEnable"), enabled != "all" {
            try loss("Removed source component restriction \(enabled) on \(node.attr("name") ?? "clip").")
        }
        let ref = try source.required("ref")
        guard let asset = resources[ref], asset.name == "asset" else { throw invalidFCP("Missing original asset \(ref).") }
        let url = try assetURL(ref, asset: asset)
        if node.name == "video" && asset.attr("hasAudio") == "1" || source.name == "audio" && asset.attr("hasVideo") == "1" {
            try loss("Restored the omitted components of \(node.name ?? "clip") from its linked asset.")
        }
        let local = try start.subtracting(asset.time("start", default: .zero))
        guard local >= .zero else { throw invalidFCP("Clip begins before the original asset \(ref).") }
        if asset.attr("duration") != nil, try local.adding(node.time("duration")) > asset.time("duration") {
            throw invalidFCP("Clip exceeds the duration of original asset \(ref).")
        }
        return Linked(asset: asset, url: url, start: local)
    }

    private func assetURL(_ ref: String, asset: XMLElement) throws -> URL {
        if let url = assetURLs[ref] { return url }
        let original = asset.elements(forName: "media-rep").first { ($0.attr("kind") ?? "original-media") == "original-media" }
        guard let path = original?.attr("src") ?? asset.attr("src"),
              let refURL = URLComponents(string: path),
              refURL.scheme == nil || refURL.scheme?.lowercased() == "file",
              [nil, "", "localhost"].contains(refURL.host?.lowercased()), refURL.user == nil,
              refURL.password == nil, refURL.port == nil, refURL.query == nil, refURL.fragment == nil,
              let decodedPath = refURL.percentEncodedPath.removingPercentEncoding,
              ProjectFile.validMediaPath(decodedPath), refURL.scheme == nil || decodedPath.hasPrefix("/")
        else { throw invalidFCP("Asset \(ref) needs a local original-media URL.") }
        let url = try CutProject.checkedMediaURL(decodedPath, relativeTo: location).standardizedFileURL
        assetURLs[ref] = url
        return url
    }

    struct Edit {
        let range: MulticamRange
        let angle: String
        let audio: MulticamAudioSelection?
    }

    func multicam(_ clips: [XMLElement]) throws -> MulticamProject {
        let groupID = try clips[0].required("ref")
        guard let group = resources[groupID]?.elements(forName: "multicam").first else {
            throw invalidFCP("Multicam resource \(groupID) is missing.")
        }
        let tc = try group.time("tcStart", default: .zero)
        let metadata = group.elements(forName: "metadata").flatMap { $0.elements(forName: "md") }
        func field(_ key: String) -> String? {
            metadata.first { $0.attr("key") == key }?.attr("value")
        }
        let settings = try field(FCPGroupMetadata.sources).map {
            try JSONDecoder().decode([String: FCPAngleMetadata].self, from: Data($0.utf8))
        } ?? [:]
        // Give early-starting cameras nonnegative FCP angle times, then restore MPCut's clock.
        let storedBase = try field(FCPGroupMetadata.base).map { try RationalTime(parsing: $0) } ?? .zero
        guard storedBase <= .zero else { throw invalidFCP("Invalid multicam group clock metadata.") }
        let earliest = try clips.map { try $0.time("start", default: tc).subtracting(tc) }.min() ?? .zero
        let base = try max(storedBase, RationalTime.zero.subtracting(earliest))
        if base != storedBase {
            try loss("Shifted the MPCut group origin to include edits before its original start.")
        }
        var cameras = [MulticamSource](), microphones = [MulticamSource]()
        var audioStreams = [String: [StreamInfo]]()
        var coverage = [String: MulticamRange]()
        var ids = Set<String>()
        try checkChildren(group, keeping: ["mc-angle"])
        for angle in group.elements(forName: "mc-angle") {
            let id = try angle.required("angleID")
            guard ids.insert(id).inserted else { throw invalidFCP("Duplicate multicam angle \(id).") }
            let sources = angle.elements.filter { $0.name != "gap" }
            guard sources.count == 1, let node = sources.first, ["clip", "asset-clip", "video", "audio"].contains(node.name),
                  node.attr("enabled") != "0" else {
                throw invalidFCP("Angle \(id) must contain one enabled linked recording. Edited or compound angles cannot be reconstructed.")
            }
            var cursor = tc
            for item in angle.elements.prefix(while: { $0 !== node }) {
                try checkChildren(item, keeping: [])
                cursor = try item.time("offset", default: cursor).adding(item.time("duration"))
            }
            for gap in angle.elements.filter({ $0.name == "gap" }) { try checkChildren(gap, keeping: []) }
            let source = try linked(node)
            var fileInfo = stat()
            guard stat(source.url.path, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG else {
                throw invalidFCP("Relink the angle to a regular media file at \(source.url.path).")
            }
            let info: MediaInfo
            if let existing = media[source.url] { info = existing }
            else {
                do { info = try engine.inspectSummary(source.url) }
                catch { throw invalidFCP("Relink \(source.url.path) before importing multicam. Its source clock and audio stream indices are required (\(error.localizedDescription)).") }
                media[source.url] = info
            }
            let at = try node.time("offset", default: cursor).subtracting(tc).adding(base)
            let visible = try node.time("duration")
            guard visible > .zero else { throw invalidFCP("Angle \(id) has an empty recording.") }
            coverage[id] = try .init(from: at, to: at.adding(visible))
            let offset = try at.subtracting(source.start).subtracting(info.multicamSourceOffset)
            let streams = info.streams.filter { $0.kind == "audio" }
            audioStreams[id] = streams
            var defaultStream = streams.count == 1 ? streams[0].index : nil
            if let setting = settings[id] {
                defaultStream = setting.audioStream
                if let selected = defaultStream, !streams.contains(where: { $0.index == selected }) {
                    try loss("Removed the unavailable default audio stream \(selected) on angle \(id).")
                    defaultStream = nil
                }
            }
            let entry = MulticamSource(id: id, file: source.url.path, offset: offset, name: angle.attr("name"),
                                       audioStream: defaultStream)
            let hasPicture = source.asset.attr("hasVideo") == "1" || (source.asset.attr("hasVideo") == nil && info.hasVideo)
            if hasPicture && settings[id]?.audioOnly != true {
                cameras.append(entry)
            } else { microphones.append(entry) }
        }
        let preferred = field(FCPGroupMetadata.reference)
        guard let reference = cameras.first(where: { $0.id == preferred })?.id ?? cameras.first?.id else { throw invalidFCP("The multicam group has no video angle.") }
        let cameraIDs = Set(cameras.map(\.id))
        let edits = try clips.map { item -> Edit in
            guard item.attr("ref") == groupID else { throw invalidFCP("Multiple multicam groups in one timeline cannot be represented.") }
            try checkTiming(item)
            let component = item.attr("srcEnable") ?? "all"
            if component != "all" && component != "video" {
                try loss("Removed the multicam clip's \(component)-only override.")
            }
            try checkChildren(item, keeping: ["mc-source"])
            var picture: String?, sound: MulticamAudioSelection?
            for selection in item.elements(forName: "mc-source") {
                try checkChildren(selection, keeping: [])
                let id = try selection.required("angleID")
                guard ids.contains(id) else { throw invalidFCP("Unknown angle \(id).") }
                let enabled = selection.attr("srcEnable") ?? "all"
                guard ["video", "audio", "all", "none"].contains(enabled) else { throw invalidFCP("Unknown selection \(enabled).") }
                if enabled == "video" || enabled == "all" {
                    guard picture == nil, cameraIDs.contains(id) else { throw invalidFCP("Expected a single video angle.") }
                    picture = id
                }
                if component != "video", enabled == "audio" || enabled == "all", let streams = audioStreams[id], !streams.isEmpty {
                    if let sound {
                        try loss("Kept multicam audio angle \(sound.source) and removed simultaneous angle \(id).")
                        continue
                    }
                    if streams.count != 1 {
                        try loss("Angle \(id) contains multiple embedded audio streams. Selected its first stream \(streams[0].index).")
                    }
                    sound = .init(source: id, stream: streams[0].index)
                }
            }
            guard let picture else { throw invalidFCP("The multicam clip needs an explicit enabled video angle.") }
            let start = try item.time("start", default: tc).subtracting(tc).adding(base)
            guard start >= .zero else { throw invalidFCP("Multicam clip starts before the group timecode.") }
            let end = try start.adding(item.time("duration"))
            for id in [picture, sound?.source].compactMap({ $0 }) {
                guard let available = coverage[id], available.from <= start, end <= available.to else {
                    throw invalidFCP("The edit at \(start)s selects empty space on angle \(id).")
                }
            }
            return Edit(range: .init(from: start, to: end), angle: picture, audio: sound)
        }
        let ordered = edits.sorted { $0.range.from < $1.range.from }
        var switches = [MulticamSwitch](), end = RationalTime.zero
        for edit in ordered {
            if let previous = switches.last, previous.angle != edit.angle || previous.audio != edit.audio {
                guard end <= edit.range.from else {
                    throw invalidFCP("Repeated group time uses different angle selections. MPCut switches apply to every occurrence.")
                }
                switches.append(.init(at: edit.range.from, angle: edit.angle, audio: edit.audio))
            } else if switches.isEmpty {
                switches.append(.init(at: .zero, angle: edit.angle, audio: edit.audio))
            }
            end = max(end, edit.range.to)
        }
        let cameraStreams = Dictionary(uniqueKeysWithValues: cameras.compactMap { camera in
            camera.audioStream.map { (camera.id, $0) }
        })
        var policy = MulticamAudioPolicy.none
        let mode = field(FCPGroupMetadata.audio)
        if mode == "follow" {
            // A switch with nil audio falls back to the default. Keep silence explicit
            // by retaining the none policy when follow would enable an unwanted mic.
            if switches.allSatisfy({ $0.audio != nil || cameraStreams[$0.angle] == nil }) { policy = .follow }
        } else if let mode, mode.hasPrefix("fixed:") {
            let id = String(mode.dropFirst(6))
            if let streams = audioStreams[id], streams.count == 1, switches.allSatisfy({ $0.audio != nil }) {
                policy = .fixed(.init(source: id, stream: streams[0].index))
            }
        } else if mode == nil, let first = switches.first?.audio,
                  switches.allSatisfy({ $0.audio == first }) { policy = .fixed(first) }
        for index in switches.indices {
            let expected: MulticamAudioSelection?
            switch policy {
            case .none: expected = nil
            case .fixed(let mic): expected = mic
            case .follow:
                let id = switches[index].angle
                expected = cameraStreams[id].map { .init(source: id, stream: $0) }
            }
            if switches[index].audio == expected { switches[index].audio = nil }
        }
        return .init(referenceAngle: reference, range: .init(from: .zero, to: end), angles: cameras,
                     audioSources: microphones, audio: policy, switches: switches, assembly: edits.map(\.range))
    }
}

/// MPCut-specific editor fields carried in Apple's extensible clip metadata.
struct FCPClipMetadata: Codable {
    static let key = "com.mpcut.clip.v1"
    let id: String
    let audioTrack: Int?
    let originalFile: String?
    let replacementNames: [Int: String]
}


struct FCPAngleMetadata: Codable {
    let audioOnly: Bool
    let audioStream: Int?
}

enum FCPGroupMetadata {
    static let base = "com.mpcut.multicam.base"
    static let sources = "com.mpcut.multicam.sources"
    static let reference = "com.mpcut.multicam.reference"
    static let audio = "com.mpcut.multicam.audio"
}
