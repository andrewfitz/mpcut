import Darwin
import Foundation

/// Final Cut's published XML timeline interchange. A package contains Info.fcpxml.
public enum FCPInterchange {
    public static func read(_ url: URL, allowLoss: Bool = false) throws -> (CutProject, [String]) {
        let imported = try readDocument(url, allowLoss: allowLoss)
        return (imported.project, imported.warnings)
    }

    package static func readDocument(_ url: URL, allowLoss: Bool = false) throws
        -> (project: CutProject, warnings: [String], mediaSnapshot: ProjectMediaSnapshot) {
        let xml = url.pathExtension.lowercased() == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
        let reader = FCPReader(location: xml, allowLoss: allowLoss)
        let project = try reader.read()
        try project.validate()
        let usedPaths = Set(project.mediaPaths.map(\.1))
        let entries = reader.media.compactMap { url, media in
            usedPaths.contains(url.path) ? ProjectMediaSnapshot.Entry(path: url.path, media: media) : nil
        }
        let stills = project.stillAssets.compactMap { asset -> ProjectMediaSnapshot.Entry? in
            guard let generation = reader.fingerprintedStills[asset.file],
                  var entry = ProjectMediaSnapshot.Entry(path: asset.file, asset: asset) else { return nil }
            entry.size = generation.size
            entry.modifiedSeconds = generation.modifiedSeconds
            entry.modifiedNanoseconds = generation.modifiedNanoseconds
            return entry
        }
        let snapshot = ProjectMediaSnapshot.empty.merging(.init(entries: entries + stills))
        return (project, reader.warnings, snapshot)
    }

    static func loadDocument(_ location: URL) throws -> XMLDocument {
        let limit = (64 << 20)
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
        try project.validateDestination(output, relativeTo: location, includesContents: output.pathExtension.lowercased() == "fcpxmld")
        let conversion = try ProjectConverter.prepareForInterchange(project, for: "Final Cut Pro .\(output.pathExtension)",
                                                            allowLoss: allowLoss, supportsStillInserts: true)
        let project = conversion.project
        guard output.pathExtension.lowercased() == "fcpxmld" else {
            return try conversion.warnings + ResolveExport.writeFCP(project, relativeTo: location, to: output, package: nil, allowLoss: allowLoss,
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
        return conversion.warnings + warnings
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
    var fingerprintedStills = [String: SourceIdentity]()

    init(location: URL, allowLoss: Bool) {
        self.location = location
        self.allowLoss = allowLoss
    }

    func loss(_ message: String) throws {
        guard allowLoss else { throw CutError(code: "conversion_loss", message: message) }
        note(message)
    }

    /// A warning for what the import rebuilt another way without losing the timeline, such as a group whose saved
    /// MPCut editing no longer matches the edited storyline.
    func note(_ message: String) {
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
        let stillIndices = try Set(clips.indices.filter { try isStillClip(clips[$0]) })
        try checkSequenceAttributes(sequence)
        if let first = clips.indices.first(where: { !stillIndices.contains($0) }) {
            try checkFormat(sequence, first: clips[first])
        }
        let isMulticam = clips.contains { $0.name == "mc-clip" }
        let recordingIndices = clips.indices.filter { !stillIndices.contains($0) }
        if isMulticam, !recordingIndices.allSatisfy({ clips[$0].name == "mc-clip" }) {
            throw invalidFCP("Mixed multicam and ordinary storylines cannot be represented in a single MPCut project.")
        }
        var suppliedIDs = Set<String>()
        var imported: [CutSequenceClip] = isMulticam ? [] : try recordingIndices.map { index in
            let node = clips[index]
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
        if stillIndices.isEmpty {
            if isMulticam { return .multicam(try multicam(clips)) }
            return .sequence(imported)
        }
        guard let formatID = sequence.attr("format"), let format = resources[formatID], format.name == "format",
              let cadence = try? format.time("frameDuration"), cadence > .zero else {
            throw invalidFCP("Still inserts need a sequence format with a positive frame duration.")
        }
        var assetKeys = [String: StillAsset]()
        var assets = [StillAsset]()
        var placements = Set<String>()
        var policy: StillProgramColorPolicy?
        var standalone: StillTimelineFormat?
        var inserts = [Int: StillInsert]()
        for index in stillIndices.sorted() {
            let node = clips[index]
            let ref = try node.required("ref")
            let resource = resources[ref]!
            let url = try assetURL(ref, asset: resource)
            let metadata = try resource.elements(forName: "metadata").flatMap { $0.elements(forName: "md") }
                .first(where: { $0.attr("key") == FCPStillMetadata.key })?.attr("value").map {
                    try JSONDecoder().decode(FCPStillMetadata.self, from: Data($0.utf8))
                }
            try checkTiming(node)
            try checkChildren(node, keeping: ["adjust-conform"])
            let conform = node.elements(forName: "adjust-conform")
            let fit: StillImageFraming
            if conform.isEmpty || (conform.count == 1 && conform[0].attr("type") == "fit" && conform[0].elements.isEmpty) {
                fit = .fit
            } else if conform.count == 1 && conform[0].attr("type") == "fill" && conform[0].elements.isEmpty {
                fit = .fill
            } else {
                try loss("Used centered Fit for still \(node.attr("name") ?? url.lastPathComponent) with unsupported spatial conform.")
                fit = .fit
            }
            let assetID = metadata?.assetID ?? "still-asset-\(ref)"
            if let previous = assetKeys[assetID] {
                guard previous.file == url.path, metadata.map({ $0.fingerprint == previous.fingerprint }) ?? true else {
                    throw invalidFCP("Still asset \(assetID) has conflicting original media references.")
                }
            }
            if assetKeys[assetID] == nil {
                let fingerprint: String
                if let stored = metadata?.fingerprint {
                    fingerprint = stored
                } else if let generation = try? SourceIdentity(url) {
                    fingerprint = try StillImage.fingerprint(url, expectedIdentity: generation)
                    fingerprintedStills[url.path] = generation
                } else {
                    fingerprint = "unverified-fcpxml-\(ref)"
                }
                let asset = StillAsset(id: assetID, file: url.path, displayName: resource.attr("name") ?? url.lastPathComponent,
                                       fingerprint: fingerprint)
                assetKeys[assetID] = asset
                assets.append(asset)
            }
            if let value = metadata?.colorPolicy {
                guard policy == nil || policy == value else { throw invalidFCP("Conflicting still program color policies.") }
                policy = value
            }
            if let value = metadata?.standalone {
                guard standalone == nil || standalone == value else { throw invalidFCP("Conflicting standalone still formats.") }
                standalone = value
            }
            let requestedID = metadata?.placementID ?? "still-\(index + 1)"
            var id = requestedID
            var suffix = 2
            while !placements.insert(id).inserted {
                id = "\(requestedID)-\(suffix)"
                suffix += 1
            }
            inserts[index] = StillInsert(id: id, assetID: assetID, duration: try node.time("duration"),
                                         cadence: cadence, framing: fit)
        }
        if isMulticam {
            return .multicam(try multicam(clips, inserts: inserts, assets: assets, color: policy))
        }
        if imported.isEmpty {
            let stillItems = inserts.sorted { $0.key < $1.key }.map { StillAssemblyItem.still($0.value) }
            // A wholly still assembly has no mc-clip to link its authored group.
            // Require an exact match in MPCut's editing metadata before adopting one.
            let matchingGroups = resources.compactMap { id, media -> String? in
                guard let group = media.elements(forName: "multicam").first,
                      editingMetadata(group)?.assemblyItems == stillItems else { return nil }
                return id
            }
            if matchingGroups.count == 1 {
                return .multicam(try multicam(clips, inserts: inserts, assets: assets, color: policy,
                                              orphanGroupID: matchingGroups[0]))
            }
            guard let width = format.attr("width").flatMap(Int.init),
                  let height = format.attr("height").flatMap(Int.init) else {
                throw invalidFCP("A standalone still timeline needs a canvas size.")
            }
            standalone = StillTimelineFormat(width: width, height: height, cadence: cadence,
                                             codec: standalone?.codec ?? .h264, container: standalone?.container ?? "mov")
        } else if standalone != nil {
            try loss("Removed the MPCut still-only export format because the timeline now contains recordings.")
            standalone = nil
        }
        var iterator = imported.makeIterator()
        let items: [StillSequenceItem] = clips.indices.map { index in
            if let insert = inserts[index] { return .still(insert) }
            return .source(iterator.next()!)
        }
        return .stillSequence(StillSequenceProject(items: items, stillAssets: assets, programColorPolicy: policy,
                                                   stillFormat: standalone))
    }

    private func isStillClip(_ node: XMLElement) throws -> Bool {
        guard node.name == "video" || node.name == "asset-clip",
              let ref = node.attr("ref"), let asset = resources[ref], asset.name == "asset",
              asset.attr("hasAudio") != "1", try asset.time("duration", default: .zero) == .zero else { return false }
        let url = try assetURL(ref, asset: asset)
        return StillImage.filenameExtensions.contains(url.pathExtension.lowercased())
    }

    private func checkSequenceAttributes(_ sequence: XMLElement) throws {
        for key in ["audioLayout", "audioRate", "renderFormat", "keywords"] where sequence.attr(key) != nil {
            try loss("The sequence's \(key) setting is not stored in a .cut project.")
        }
    }

    func checkFormat(_ sequence: XMLElement, first: XMLElement) throws {
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
                let recognized = node.name == "multicam" ? [FCPGroupMetadata.reference, FCPGroupMetadata.audio, FCPGroupMetadata.base, FCPGroupMetadata.sources, FCPGroupMetadata.editing] : [FCPClipMetadata.key]
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

    private func inspect(_ source: Linked) throws -> MediaInfo {
        if let existing = media[source.url] { return existing }
        var fileInfo = stat()
        guard stat(source.url.path, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG else {
            throw invalidFCP("Relink the angle to a regular media file at \(source.url.path).")
        }
        do {
            let info = try engine.inspectSummary(source.url)
            media[source.url] = info
            return info
        } catch {
            throw invalidFCP("Relink \(source.url.path) before importing multicam. Its source clock and audio stream indices are required (\(error.localizedDescription)).")
        }
    }

    struct Edit {
        let range: MulticamRange
        let angle: String
        let recording: String?
        let audio: MulticamAudioSelection?
        let timelineIndex: Int
    }

    /// Restore authored state only when it describes the program that is still in the XML storyline.
    private func restore(_ editing: FCPMulticamEditing, edits: [Edit], inserts: [Int: StillInsert],
                         reference: String, cameras: [MulticamSource], microphones: [MulticamSource],
                         assets: [StillAsset], color: StillProgramColorPolicy?,
                         audioStreams: [String: [StreamInfo]]) throws -> MulticamProject? {
        let originalAudio = editing.extractedAudio ?? [:]
        let sources = Dictionary(uniqueKeysWithValues: (cameras.flatMap(\.recordings) + microphones).map { ($0.id, $0) })
        let helperIDs = Set(originalAudio.keys)
        let microphoneIDs = Set(microphones.map(\.id))
        func path(_ link: String) -> String? {
            guard let decoded = URLComponents(string: link)?.percentEncodedPath.removingPercentEncoding else { return nil }
            return try? CutProject.checkedMediaURL(decoded, relativeTo: location).standardizedFileURL.path
        }
        guard helperIDs.isSubset(of: microphoneIDs),
              originalAudio.allSatisfy({ id, selection in
                  guard let source = sources[id], let original = sources[selection.source] else { return false }
                  if let authored = editing.audioLinks?[id] {
                      return source.file == path(authored.path) && source.offset == authored.offset
                          && original.file == path(authored.originalPath) && original.offset == authored.originalOffset
                  }
                  return source.file == original.file && source.offset == original.offset
              }),
              originalAudio.values.allSatisfy({ selection in
                  !helperIDs.contains(selection.source)
                      && audioStreams[selection.source]?.contains(where: { $0.index == selection.stream }) == true
              }),
              Set(editing.recordings.values.flatMap { $0 }) == Set(sources.keys).subtracting(helperIDs)
        else { return nil }

        func applySettings(_ source: MulticamSource, isPrimary: Bool) -> MulticamSource? {
            guard source.coverage == editing.sourceCoverage?[source.id] else { return nil }
            var result = source
            if let setting = editing.sourceSettings?[source.id] {
                if let stream = setting.audioStream,
                   audioStreams[source.id]?.contains(where: { $0.index == stream }) != true {
                    return nil
                }
                result.audioStream = setting.audioStream
                // An explicit rename in FCP remains authoritative.
                let fileName = URL(fileURLWithPath: source.file).lastPathComponent
                let writtenName = isPrimary ? setting.name ?? fileName : fileName
                if source.name == writtenName { result.name = setting.name }
            }
            return result
        }

        var restoredCameras = [MulticamSource](), restoredMicrophones = [MulticamSource]()
        for camera in cameras {
            guard var primary = applySettings(camera, isPrimary: true) else { return nil }
            var additional = [MulticamSource]()
            for recording in camera.additionalRecordings {
                guard let restored = applySettings(recording, isPrimary: false) else { return nil }
                additional.append(restored)
            }
            primary.additionalRecordings = additional
            restoredCameras.append(primary)
        }
        for microphone in microphones where !helperIDs.contains(microphone.id) {
            guard let restored = applySettings(microphone, isPrimary: true) else { return nil }
            restoredMicrophones.append(restored)
        }
        let result = MulticamProject(referenceAngle: reference, range: editing.range, angles: restoredCameras,
                                    audioSources: restoredMicrophones, audio: editing.audio, switches: editing.switches,
                                    assemblyItems: editing.assemblyItems, stillAssets: assets, programColorPolicy: color)
        let plan = try result.plan()
        guard plan.intervals.count == edits.count else { return nil }

        let items = editing.assemblyItems ?? [.group(editing.range)]
        var expectedStills = [(RationalTime, StillInsert)]()
        var cursor = RationalTime.zero
        for item in items {
            if let range = item.group {
                cursor = try cursor.adding(range.to.subtracting(range.from))
            } else if let insert = item.still {
                expectedStills.append((cursor, insert))
                cursor = try cursor.adding(insert.duration)
            }
        }
        guard expectedStills.count == inserts.count else { return nil }
        let timelineIndices = Set(edits.map(\.timelineIndex)).union(inserts.keys).sorted()
        let grouped = Dictionary(grouping: edits, by: \.timelineIndex)
        var output = RationalTime.zero
        var stillIndex = 0
        for index in timelineIndices {
            if let insert = inserts[index] {
                let (expectedPosition, expectedInsert) = expectedStills[stillIndex]
                guard insert == expectedInsert, output == expectedPosition else { return nil }
                stillIndex += 1
                output = try output.adding(insert.duration)
            } else {
                for edit in grouped[index] ?? [] { output = try output.adding(edit.range.to.subtracting(edit.range.from)) }
            }
        }
        guard zip(plan.intervals, edits).allSatisfy({ planned, visible in
            let audio = visible.audio.map { originalAudio[$0.source] ?? $0 }
            return planned.group == visible.range && planned.angle == visible.angle && planned.pictureSourceID == visible.recording
                && planned.audio == audio
        }) else { return nil }
        return result
    }

    /// MPCut's saved editing of a group. Nil without it, and nil with a note when it is present but unreadable.
    private func editingMetadata(_ multicam: XMLElement, noting: Bool = false) -> FCPMulticamEditing? {
        let fields = multicam.elements(forName: "metadata").flatMap { $0.elements(forName: "md") }
        guard let value = fields.first(where: { $0.attr("key") == FCPGroupMetadata.editing })?.attr("value") else { return nil }
        guard let editing = try? JSONDecoder().decode(FCPMulticamEditing.self, from: Data(value.utf8)) else {
            if noting { note(Self.rebuiltGroup) }
            return nil
        }
        return editing
    }

    static let rebuiltGroup = "The saved MPCut editing of the multicam group no longer matches the timeline, so the group was "
        + "rebuilt from its visible clips. Audio switches, coverage and the audio policy kept only in MPCut are not restored."

    func multicam(_ timeline: [XMLElement], inserts: [Int: StillInsert] = [:], assets: [StillAsset] = [],
                  color: StillProgramColorPolicy? = nil, orphanGroupID: String? = nil) throws -> MulticamProject {
        let clips = timeline.indices.filter { inserts[$0] == nil }.map { timeline[$0] }
        guard let groupID = try orphanGroupID ?? clips.first?.required("ref") else {
            throw invalidFCP("The timeline does not link a multicam group.")
        }
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
        let earliest = try clips.map { try $0.time("start", default: tc).subtracting(tc) }.min()
        let base = try earliest.map { try max(storedBase, RationalTime.zero.subtracting($0)) } ?? storedBase
        if base != storedBase {
            try loss("Shifted the MPCut group origin to include edits before its original start.")
        }
        var cameras = [MulticamSource](), microphones = [MulticamSource]()
        var audioStreams = [String: [StreamInfo]]()
        var coverage = [String: [(id: String, range: MulticamRange)]]()
        let nodes = group.elements(forName: "mc-angle")
        let angleIDs = try nodes.map { try $0.required("angleID") }
        let ids = Set(angleIDs)
        guard ids.count == nodes.count else { throw invalidFCP("Duplicate multicam angle ID.") }
        var recordingIDs = ids
        let editing = editingMetadata(group, noting: true)
        try checkChildren(group, keeping: ["mc-angle"])
        for (angle, id) in zip(nodes, angleIDs) {
            var cursor = tc
            var entries = [MulticamSource]()
            let sourceCount = angle.elements.filter { $0.name != "gap" }.count
            let mapped = editing?.recordings[id]
            let additionalIDs = Set(mapped?.filter { $0 != id } ?? [])
            let validMapping = mapped?.count == sourceCount && additionalIDs.count == sourceCount - 1
                && mapped?.contains(id) == true && recordingIDs.isDisjoint(with: additionalIDs)
            if validMapping { recordingIDs.formUnion(additionalIDs) }
            var hasPicture: Bool?
            var trimmed = false
            for node in angle.elements {
                let position = try node.time("offset", default: cursor)
                let duration = try node.time("duration")
                guard duration > .zero, position >= cursor else {
                    throw invalidFCP("Angle \(id) has an empty or overlapping segment.")
                }
                cursor = try position.adding(duration)
                if node.name == "gap" {
                    try checkChildren(node, keeping: [])
                    continue
                }
                guard ["clip", "asset-clip", "video", "audio"].contains(node.name), node.attr("enabled") != "0" else {
                    throw invalidFCP("Angle \(id) must contain enabled linked recordings.")
                }
                let recordingID: String
                if validMapping, let mapped {
                    recordingID = mapped[entries.count]
                } else if entries.isEmpty {
                    recordingID = id
                } else {
                    var suffix = entries.count + 1
                    while !recordingIDs.insert("\(id)-recording-\(suffix)").inserted { suffix += 1 }
                    recordingID = "\(id)-recording-\(suffix)"
                }
                let source = try linked(node)
                let info = try inspect(source)
                let assetDuration = try source.asset.time("duration", default: info.duration)
                trimmed = trimmed || source.start != .zero || duration != assetDuration
                let at = try position.subtracting(tc).adding(base)
                let range = try MulticamRange(from: at, to: at.adding(duration))
                let offset = try at.subtracting(source.start).subtracting(info.multicamSourceOffset)
                let streams = info.streams.filter { $0.kind == "audio" }
                audioStreams[recordingID] = streams
                var defaultStream = streams.count == 1 ? streams[0].index : nil
                if recordingID == id, let setting = settings[id] {
                    defaultStream = setting.audioStream
                    if let selected = defaultStream, !streams.contains(where: { $0.index == selected }) {
                        if editing?.extractedAudio?[recordingID] == nil {
                            try loss("Removed the unavailable default audio stream \(selected) on recording \(recordingID).")
                            defaultStream = nil
                        } else {
                            // The helper's old stream index is specific to its original media.
                            defaultStream = streams.count == 1 ? streams[0].index : nil
                        }
                    }
                }
                let picture = settings[id]?.audioOnly != true
                    && (source.asset.attr("hasVideo") == "1" || (source.asset.attr("hasVideo") == nil && info.hasVideo))
                guard hasPicture == nil || hasPicture == picture else {
                    throw invalidFCP("Angle \(id) mixes video and audio-only recordings.")
                }
                hasPicture = picture
                coverage[id, default: []].append((recordingID, range))
                entries.append(.init(id: recordingID, file: source.url.path, offset: offset,
                                     name: recordingID == id ? angle.attr("name") : node.attr("name"),
                                     audioStream: defaultStream, coverage: range))
            }
            guard let primaryIndex = entries.firstIndex(where: { $0.id == id }) else {
                throw invalidFCP("Angle \(id) has no linked recording.")
            }
            var primary = entries.remove(at: primaryIndex)
            if hasPicture == true {
                if entries.isEmpty, !trimmed, editing?.sourceCoverage?[primary.id] == nil { primary.coverage = nil }
                primary.additionalRecordings = entries
                cameras.append(primary)
            } else {
                guard entries.isEmpty else { throw invalidFCP("Audio-only angle \(id) contains multiple recordings.") }
                primary.coverage = nil
                microphones.append(primary)
            }
        }
        let preferred = field(FCPGroupMetadata.reference)
        guard let reference = cameras.first(where: { $0.id == preferred })?.id ?? cameras.first?.id else { throw invalidFCP("The multicam group has no video angle.") }
        let cameraIDs = Set(cameras.map(\.id))
        var segmented = Set(cameras.filter { $0.coverage != nil }.map(\.id))
        var visible = [Edit]()
        for (index, item) in timeline.enumerated() {
            if inserts[index] != nil { continue }
            guard item.attr("ref") == groupID else { throw invalidFCP("Multiple multicam groups in one timeline cannot be represented.") }
            try checkTiming(item)
            let component = item.attr("srcEnable") ?? "all"
            if component != "all" && component != "video" {
                try loss("Removed the multicam clip's \(component)-only override.")
            }
            try checkChildren(item, keeping: ["mc-source"])
            var picture: String?, soundAngles = [String]()
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
                if component != "video", enabled == "audio" || enabled == "all" { soundAngles.append(id) }
            }
            guard let picture else { throw invalidFCP("The multicam clip needs an explicit enabled video angle.") }
            var start = try item.time("start", default: tc).subtracting(tc).adding(base)
            guard start >= .zero else { throw invalidFCP("Multicam clip starts before the group timecode.") }
            let end = try start.adding(item.time("duration"))
            let selectedAngles = soundAngles.contains(picture) ? soundAngles : [picture] + soundAngles
            while start < end {
                var boundary = end
                var sound: MulticamAudioSelection?
                var pictureRecording: String?
                for id in selectedAngles {
                    let ranges = coverage[id] ?? []
                    guard let available = ranges.first(where: { $0.range.contains(start) }) else {
                        guard id == picture else {
                            throw invalidFCP("The edit at \(start)s selects empty space on angle \(id).")
                        }
                        segmented.insert(id)
                        if let next = ranges.first(where: { start < $0.range.from }) {
                            boundary = min(boundary, next.range.from)
                        }
                        continue
                    }
                    boundary = min(boundary, available.range.to)
                    if id == picture { pictureRecording = available.id }
                    guard soundAngles.contains(id), let streams = audioStreams[available.id], !streams.isEmpty else { continue }
                    if let sound {
                        try loss("Kept multicam audio angle \(sound.source) and removed simultaneous angle \(id).")
                        continue
                    }
                    if streams.count != 1 {
                        try loss("Angle \(id) contains multiple embedded audio streams. Selected its first stream \(streams[0].index).")
                    }
                    sound = .init(source: available.id, stream: streams[0].index)
                }
                visible.append(.init(range: .init(from: start, to: boundary), angle: picture, recording: pictureRecording,
                                     audio: sound, timelineIndex: index))
                start = boundary
            }
        }
        for index in cameras.indices where cameras[index].coverage == nil && segmented.contains(cameras[index].id) {
            cameras[index].coverage = coverage[cameras[index].id]?.first?.range
        }
        if let editing {
            if let restored = try? restore(editing, edits: visible, inserts: inserts, reference: reference,
                                           cameras: cameras, microphones: microphones, assets: assets,
                                           color: color, audioStreams: audioStreams) {
                return restored
            }
            note(Self.rebuiltGroup)
        }
        guard !visible.isEmpty else { throw invalidFCP("The still assembly's multicam metadata no longer matches its resources.") }
        let edits = visible
        let ordered = edits.indices.sorted { (edits[$0].range.from, $0) < (edits[$1].range.from, $1) }
        var switches = [MulticamSwitch](), end = RationalTime.zero
        var overrides = [Int: String]()
        for index in ordered {
            let edit = edits[index]
            if let previous = switches.last, previous.angle != edit.angle || previous.audio != edit.audio {
                if end <= edit.range.from {
                    switches.append(.init(at: edit.range.from, angle: edit.angle, audio: edit.audio))
                } else {
                    guard previous.audio == edit.audio else {
                        throw invalidFCP("Repeated group time uses different audio. MPCut audio switches apply to every occurrence.")
                    }
                    overrides[index] = edit.angle
                }
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
        if mode == "follow" && segmented.isEmpty {
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
            case .none, .mix: expected = nil
            case .fixed(let mic): expected = mic
            case .follow:
                let id = switches[index].angle
                expected = cameraStreams[id].map { .init(source: id, stream: $0) }
            }
            if switches[index].audio == expected { switches[index].audio = nil }
        }
        let grouped = Dictionary(grouping: edits.indices, by: { edits[$0].timelineIndex })
        let items = timeline.indices.flatMap { index -> [StillAssemblyItem] in
            if let insert = inserts[index] { return [.still(insert)] }
            return (grouped[index] ?? []).map { .group(edits[$0].range, angle: overrides[$0]) }
        }
        return .init(referenceAngle: reference, range: .init(from: .zero, to: end), angles: cameras,
                     audioSources: microphones, audio: policy, switches: switches, assemblyItems: items,
                     stillAssets: assets, programColorPolicy: color)
    }
}

/// MPCut-specific editor fields carried in Apple's extensible clip metadata.
struct FCPClipMetadata: Codable {
    static let key = "com.mpcut.sequence_clip.v2"
    enum CodingKeys: String, CodingKey {
        case id = "clip_id"
        case audioTrack = "track_ordinal"
        case originalFile = "original_file"
        case replacementNames = "replacement_names"
    }
    let id: String
    let audioTrack: Int?
    let originalFile: String?
    let replacementNames: [Int: String]
}

struct FCPStillMetadata: Codable {
    static let key = "com.mpcut.still_placement.v2"
    enum CodingKeys: String, CodingKey {
        case placementID = "placement_id"
        case assetID = "asset_id"
        case fingerprint
        case colorPolicy = "program_color_policy"
        case standalone = "still_format"
    }
    let placementID: String
    let assetID: String
    let fingerprint: String
    let colorPolicy: StillProgramColorPolicy?
    let standalone: StillTimelineFormat?
}


struct FCPAngleMetadata: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case audioOnly = "audio_only"
        case audioStream = "audio_stream_index"
    }
    let audioOnly: Bool
    let audioStream: Int?
    var name: String? = nil
}

enum FCPGroupMetadata {
    static let base = "com.mpcut.multicam.group_start_time"
    static let sources = "com.mpcut.multicam.source_settings"
    static let reference = "com.mpcut.multicam.reference_angle_id"
    static let audio = "com.mpcut.multicam.program_audio_mode"
}
