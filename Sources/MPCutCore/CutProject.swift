import Darwin
import Foundation

/// One occurrence of a media range. Array order determines its position on the timeline.
public struct CutSequenceClip: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var file: String
    public var from: RationalTime
    public var to: RationalTime

    public var audioTrack: Int?
    public var originalFile: String?
    public var replacementNames: [Int: String]

    public init(id: String, file: String, from: RationalTime, to: RationalTime,
                audioTrack: Int? = nil, originalFile: String? = nil, replacementNames: [Int: String] = [:]) {
        self.audioTrack = audioTrack
        self.originalFile = originalFile
        self.replacementNames = replacementNames
        self.id = id
        self.file = file
        self.from = from
        self.to = to
    }

    private enum CodingKeys: String, CodingKey { case id, file, from, to, audioTrack, originalFile, replacementNames }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_project")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audioTrack = try values.decodeIfPresent(Int.self, forKey: .audioTrack)
        originalFile = try values.decodeIfPresent(String.self, forKey: .originalFile)
        let names = try values.decodeIfPresent([String: String].self, forKey: .replacementNames) ?? [:]
        replacementNames = [:]
        for (key, name) in names {
            guard let track = Int(key), track >= 0, String(track) == key else {
                throw CutError(code: "invalid_cut_project", message: "Invalid replacement track ordinal ‘\(key)’")
            }
            replacementNames[track] = name
        }
        id = try values.decode(String.self, forKey: .id)
        file = try values.decode(String.self, forKey: .file)
        from = try ProjectField.time(values, .from)
        to = try ProjectField.time(values, .to)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(audioTrack, forKey: .audioTrack)
        try values.encodeIfPresent(originalFile, forKey: .originalFile)
        if !replacementNames.isEmpty { try values.encode(replacementNames, forKey: .replacementNames) }
        try values.encode(id, forKey: .id)
        try values.encode(file, forKey: .file)
        try values.encode(from.description, forKey: .from)
        try values.encode(to.description, forKey: .to)
    }
}

public enum CutProject: Equatable, Codable, Sendable {
    public static let format = "mpcut"
    public static let schemaVersion = 1
    public static let stillSchemaVersion = 2

    case sequence([CutSequenceClip])
    case multicam(MulticamProject)
    case stillSequence(StillSequenceProject)

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, kind, clips, history, stillAssets, stillReplacements, programColorPolicy, stillFormat
    }

    var requiresV2: Bool {
        switch self {
        case .sequence: false
        case .stillSequence(let project): project.requiresV2
        case .multicam(let project): project.requiresV2
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == Self.format else {
            throw CutError(code: "invalid_cut_project", message: "Expected an MPCut project document")
        }
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion || version == Self.stillSchemaVersion else {
            throw CutError(code: "unsupported_cut_version", message: "Unsupported MPCut schema version \(version)")
        }
        switch try values.decode(String.self, forKey: .kind) {
        case "sequence":
            try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_project")
            let stillFields: [CodingKeys] = [.stillAssets, .stillReplacements, .programColorPolicy, .stillFormat]
            if version == Self.schemaVersion {
                guard !stillFields.contains(where: values.contains) else {
                    throw stillError("Still fields require schema v2")
                }
                self = .sequence(try values.decode([CutSequenceClip].self, forKey: .clips))
            } else {
                for key in stillFields where values.contains(key) {
                    guard try !values.decodeNil(forKey: key) else {
                        throw stillError("Null value in still project field ‘\(key.stringValue)’")
                    }
                }
                let project = try StillSequenceProject(
                    items: values.decode([StillSequenceItem].self, forKey: .clips),
                    stillAssets: values.decodeIfPresent([StillAsset].self, forKey: .stillAssets) ?? [],
                    stillReplacements: values.decodeIfPresent([StillReplacement].self, forKey: .stillReplacements) ?? [],
                    programColorPolicy: values.decodeIfPresent(StillProgramColorPolicy.self, forKey: .programColorPolicy),
                    stillFormat: values.decodeIfPresent(StillTimelineFormat.self, forKey: .stillFormat)
                )
                self = project.requiresV2 ? .stillSequence(project) : .sequence(project.items.compactMap(\.source))
            }
            try validate()
        case "multicam": self = .multicam(try MulticamProject(from: decoder))
        default: throw CutError(code: "invalid_cut_project", message: "Unknown MPCut project kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try encode(to: encoder, forceV2: false)
    }

    func encode(to encoder: Encoder, forceV2: Bool) throws {
        try validate()
        guard stillAudioReference == nil else {
            throw CutError(code: "transient_selection", message: "A still selection with inherited audio is an export snapshot.")
        }
        if case .multicam(let project) = self {
            try project.encode(to: encoder, forceV2: forceV2)
            return
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        let v2 = requiresV2 || forceV2
        try values.encode(Self.format, forKey: .format)
        try values.encode(v2 ? Self.stillSchemaVersion : Self.schemaVersion, forKey: .schemaVersion)
        try values.encode("sequence", forKey: .kind)
        if v2 {
            let project = stillSequenceValue!
            try values.encode(project.items, forKey: .clips)
            if !project.stillAssets.isEmpty { try values.encode(project.stillAssets, forKey: .stillAssets) }
            if !project.stillReplacements.isEmpty { try values.encode(project.stillReplacements, forKey: .stillReplacements) }
            try values.encodeIfPresent(project.programColorPolicy, forKey: .programColorPolicy)
            try values.encodeIfPresent(project.stillFormat, forKey: .stillFormat)
        } else {
            try values.encode(sequenceClips!, forKey: .clips)
        }
    }

    public func validate() throws {
        switch self {
        case .multicam(let project): try project.validate()
        case .stillSequence(let project):
            let clips = project.items.compactMap(\.source)
            try Self.sequence(clips).validate()
            if let reference = project.stillAudioReference {
                try Self.sequence([reference]).validate()
                guard clips.isEmpty, project.stillFormat != nil else {
                    throw stillError("An inherited soundtrack layout requires an insert-only export selection")
                }
            }
            try validateStillCollections(assets: project.stillAssets, inserts: project.items.compactMap(\.still),
                                         replacements: project.stillReplacements, color: project.programColorPolicy,
                                         clipIDs: Set(clips.map(\.id)))
            let inserts = project.items.compactMap(\.still)
            if let format = project.stillFormat {
                try format.validate(color: project.programColorPolicy ?? StillTimelineFormat.sdrColorPolicy)
                guard clips.isEmpty else { throw stillError("An explicit still format requires a still-only sequence") }
                for insert in inserts {
                    guard insert.cadence == format.cadence else {
                        throw stillError("Still ‘\(insert.id)’ cadence differs from the project format")
                    }
                    _ = try format.frameCount(for: insert.duration)
                }
            } else if clips.isEmpty && !inserts.isEmpty {
                throw stillError("A still-only sequence requires an explicit program format")
            }
            try validateStillTimelineDuration()
        case .sequence(let clips):
            var ids = Set<String>()
            var duration = RationalTime.zero
            for clip in clips {
                guard !clip.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ids.insert(clip.id).inserted else {
                    throw CutError(code: "invalid_cut_project", message: "Clip IDs must be nonempty and unique")
                }
                let paths = [clip.file, clip.originalFile].compactMap { $0 }
                guard paths.allSatisfy(ProjectFile.validMediaPath), clip.from >= .zero, clip.to > clip.from,
                      clip.audioTrack.map({ (0...Int(Int32.max)).contains($0) }) ?? true,
                      clip.replacementNames.keys.allSatisfy({ (0...Int(Int32.max)).contains($0) }) else {
                    throw CutError(code: "invalid_cut_project", message: "Invalid media path, source range or audio track for clip ‘\(clip.id)’")
                }
                duration = try duration.adding(clip.to.subtracting(clip.from))
            }
        }
    }

    public static func load(from url: URL) throws -> Self {
        try ProjectFile.read(Self.self, from: url)
    }

    public static func decode(_ data: Data) throws -> Self {
        try ProjectFile.decode(Self.self, data: data)
    }

    var mediaPaths: [(String, String)] {
        switch self {
        case .sequence(let clips):
            return clips.flatMap { clip in
                [clip.file, clip.originalFile].compactMap { $0 }.map { (clip.id, $0) }
            }
        case .multicam(let project):
            return project.sources.map { ($0.id, $0.file) } + project.stillAssets.map { ($0.id, $0.file) }
        case .stillSequence(let project):
            let references = project.stillAudioReference.map { [$0] } ?? []
            return Self.sequence(project.items.compactMap(\.source) + references).mediaPaths + project.stillAssets.map { ($0.id, $0.file) }
        }
    }

    public func validateDestination(_ output: URL, relativeTo projectURL: URL, includesContents: Bool = false) throws {
        try validateDestination(output, sourceDirectory: ProjectFile.directory(of: projectURL), includesContents: includesContents)
    }

    package func validateDestination(_ output: URL, sourceDirectory: URL, includesContents: Bool = false) throws {
        try validate()
        try ProjectFile.validateDestination(output, sourceDirectory: sourceDirectory, sources: mediaPaths, prefix: "cut",
                                            includesContents: includesContents)
    }

    /// Protect media referenced by this document from SQLite cache or journal I/O.
    package static func sidecarExclusions(absoluteSources: [String: String], candidates: [URL]) -> Set<URL> {
        guard !absoluteSources.isEmpty, !candidates.isEmpty else { return [] }
        return ProjectFile.sidecarExclusions(sources: absoluteSources.keys, candidates: Set(candidates))
    }

    public func save(to url: URL) throws {
        try ProjectFile.write(self, to: url, sources: mediaPaths)
    }

    public static func mediaURL(_ path: String, relativeTo projectURL: URL) -> URL {
        ProjectFile.sourceURL(file: path, in: ProjectFile.directory(of: projectURL))
    }

    /// Resolve a path for media access without simplifying an unavailable parent traversal.
    public static func checkedMediaURL(_ path: String, relativeTo document: URL) throws -> URL {
        try ProjectFile.checkedSourceURL(file: path, in: ProjectFile.directory(of: document))
    }

    /// Preserve file references when saving a project in a different directory.
    public func rebased(from sourceURL: URL, to destinationURL: URL) throws -> Self {
        var paths: [String: String] = [:]
        return try rebased(from: sourceURL, to: destinationURL, paths: &paths)
    }

    func rebased(from sourceURL: URL, to destinationURL: URL, paths: inout [String: String]) throws -> Self {
        try validate()
        let sourceDirectory = ProjectFile.directory(of: sourceURL)
        if sourceDirectory == ProjectFile.directory(of: destinationURL) { return self }
        func rebase(_ path: String) -> String {
            if let cached = paths[path] { return cached }
            let file = ProjectFile.sourceURL(file: path, in: sourceDirectory)
            let relative = Self.relativeMediaPath(file.path, to: destinationURL)
            paths[path] = relative
            return relative
        }
        switch self {
        case .sequence(let clips):
            return .sequence(clips.map {
                var clip = $0
                clip.file = rebase(clip.file)
                clip.originalFile = clip.originalFile.map(rebase)
                return clip
            })
        case .stillSequence(var project):
            project.items = project.items.map { item in
                guard var clip = item.source else { return item }
                clip.file = rebase(clip.file)
                clip.originalFile = clip.originalFile.map(rebase)
                return .source(clip)
            }
            for index in project.stillAssets.indices { project.stillAssets[index].file = rebase(project.stillAssets[index].file) }
            if var reference = project.stillAudioReference {
                reference.file = rebase(reference.file)
                reference.originalFile = reference.originalFile.map(rebase)
                project.stillAudioReference = reference
            }
            return .stillSequence(project)
        case .multicam(var project):
            func rebasedSource(_ source: MulticamSource) -> MulticamSource {
                var copy = source
                copy.file = rebase(source.file)
                return copy
            }
            project.angles = project.angles.map(rebasedSource)
            project.audioSources = project.audioSources.map(rebasedSource)
            for index in project.stillAssets.indices { project.stillAssets[index].file = rebase(project.stillAssets[index].file) }
            return .multicam(project)
        }
    }

    public static func relativeMediaPath(_ path: String, to url: URL) -> String {
        guard !path.split(separator: "/").contains("..") else { return path }
        let directory = physicalParent(of: ProjectFile.documentURL(url))
        let recording = URL(fileURLWithPath: path)
        let target = physicalParent(of: recording) + [recording.lastPathComponent]
        let shared = zip(directory, target).prefix { $0.0 == $0.1 }.count
        return (Array(repeating: "..", count: directory.count - shared) + target.dropFirst(shared)).joined(separator: "/")
    }

    private static func physicalParent(of url: URL) -> [String] {
        let directory = url.deletingLastPathComponent()
        var ancestor = directory
        var missing: [String] = []
        // Resolve the existing part of an offline path too. Foundation may elide
        // /private on macOS, so both sides of a relative path need the same base.
        while !ancestor.path.isEmpty {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                let physical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                return physical.pathComponents + missing.reversed()
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        return directory.pathComponents
    }

    /// Resolve media relative to the containing project document's URL.
    public func requests(relativeTo projectURL: URL) throws -> [ClipRequest] {
        if case .stillSequence = self {
            throw stillError("A still sequence requires the still timeline planner", code: "still_timeline_required")
        }
        guard case .sequence(let clips) = self else {
            throw CutError(code: "expected_sequence", message: "A multicam project uses the multicam timeline planner")
        }
        try validate()
        let directory = ProjectFile.directory(of: projectURL)
        var sources: [String: URL] = [:]
        return try clips.map { clip in
            let file: URL
            if let cached = sources[clip.file] {
                file = cached
            } else {
                file = try ProjectFile.checkedSourceURL(file: clip.file, in: directory)
                sources[clip.file] = file
            }
            return ClipRequest(file: file, from: clip.from, to: clip.to)
        }
    }
}

struct ProjectField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static func rejectUnknown<K: CodingKey>(_ keys: K.Type, in decoder: Decoder, code: String = "invalid_multicam_project") throws {
        let container = try decoder.container(keyedBy: Self.self)
        if let field = container.allKeys.map(\.stringValue).sorted().first(where: { K(stringValue: $0) == nil }) {
            throw CutError(code: code,
                           message: "Unknown field ‘\(field)’ in \(location(decoder.codingPath))")
        }
    }

    /// A JSON path such as `switches[1].at`.
    static func location(_ path: [CodingKey]) -> String {
        let text = path.reduce(into: "") { text, key in
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += (text.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return text.isEmpty ? "the project root" : text
    }

    /// A malformed time is reported with its JSON location. It is `invalid_time`, the code of a malformed time in
    /// every other request, so a command exits with the status of a request the caller must correct.
    static func time<K: CodingKey>(_ values: KeyedDecodingContainer<K>, _ key: K,
                                   default fallback: String? = nil) throws -> RationalTime {
        let text = try values.decodeIfPresent(String.self, forKey: key) ?? fallback
            ?? values.decode(String.self, forKey: key)
        do {
            return try RationalTime(parsing: text)
        } catch {
            throw CutError(code: "invalid_time",
                           message: "Invalid timestamp ‘\(text)’ in \(location(values.codingPath + [key]))")
        }
    }
}

enum ProjectFile {
    // An opened project can be a shortcut in a different folder from its media.
    // Keep the original spelling of ordinary paths, including /var on macOS.
    static func documentURL(_ url: URL) -> URL {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return url }
        return url.resolvingSymlinksInPath()
    }

    static func directory(of document: URL) -> URL {
        documentURL(document).deletingLastPathComponent()
    }

    static func validMediaPath(_ path: String) -> Bool {
        guard let end = path.split(separator: "/").last else { return false }
        return !path.hasSuffix("/") && end != "." && end != ".." && !path.contains("\0")
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL, multicam: Bool = false) throws -> T {
        try decode(type, data: readBytes(from: url, multicam: multicam), multicam: multicam)
    }

    static func readBytes(from url: URL, multicam: Bool = false) throws -> Data {
        let prefix = multicam ? "multicam" : "cut"
        var data = Data()
        do {
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? reader.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw CutError(code: "\(prefix)_project_read_failed", message: "Expected a regular project file at \(url.path)")
            }
            let limit = MulticamProject.maximumFileSize
            guard info.st_size <= limit else {
                throw CutError(code: "invalid_\(prefix)_project", message: "Project exceeds the 64 MB limit")
            }
            while data.count <= limit {
                let count = min(1 << 20, limit + 1 - data.count)
                guard let block = try reader.read(upToCount: count), !block.isEmpty else { break }
                data.append(block)
            }
        } catch let error as CutError { throw error }
        catch {
            throw CutError(code: "\(prefix)_project_read_failed", message: "Could not read \(url.path): \(error.localizedDescription)")
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, data: Data, multicam: Bool = false) throws -> T {
        let code = multicam ? "invalid_multicam_project" : "invalid_cut_project"
        guard data.count <= MulticamProject.maximumFileSize else {
            throw CutError(code: code, message: "Project exceeds the 64 MB limit")
        }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw CutError(code: code, message: "Project must contain a UTF-8 JSON object")
        }
        do {
            let project = try JSONDecoder().decode(type, from: data)
            if let issue = jsonInputIssue(data, integerNumbersOnly: true) { throw CutError(code: code, message: "Project \(issue)") }
            return project
        } catch let error as DecodingError {
            throw CutError(code: code, message: "Invalid project JSON: \(error)")
        }
    }

    static func write<T: Encodable>(_ project: T, to url: URL, sources: [(String, String)],
                                    multicam: Bool = false, compact: Bool = false, replacingExisting: Bool = true) throws {
        let data = try encoded(project, compact: compact)
        try write(data, to: url, sources: sources, prefix: multicam ? "multicam" : "cut", replacingExisting: replacingExisting)
    }

    static func encoded<T: Encodable>(_ project: T, compact: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if !compact { encoder.outputFormatting.insert(.prettyPrinted) }
        var data = try encoder.encode(project)
        if !compact, data.count >= MulticamProject.maximumFileSize {
            encoder.outputFormatting.remove(.prettyPrinted)
            data = try encoder.encode(project)
        }
        return data
    }

    static func write(_ bytes: Data, to url: URL, sources: [(String, String)], prefix: String,
                      replacingExisting: Bool = true) throws {
        let data = try diskBytes(bytes, prefix: prefix)
        try validateDestination(url, sourceDirectory: directory(of: url), sources: sources, prefix: prefix)
        try publishProject(data, to: replacingExisting ? documentURL(url) : url, prefix: prefix, replacingExisting: replacingExisting)
    }

    static func writeRevision(_ bytes: Data, to url: URL, sources: [(String, String)], prefix: String,
                              replacingExisting: Bool, expected: ProjectDiskRevision?) throws -> ProjectDiskRevision {
        let data = try diskBytes(bytes, prefix: prefix)
        return try coordinatedWrite(to: url, prefix: prefix, expected: expected, data: data) { destination in
            let target = replacingExisting ? destination : url
            try validateDestination(target, sourceDirectory: directory(of: target), sources: sources, prefix: prefix)
            try publishProject(data, to: target, prefix: prefix, replacingExisting: replacingExisting)
        }
    }

    private static func diskBytes(_ bytes: Data, prefix: String) throws -> Data {
        guard bytes.count <= MulticamProject.maximumFileSize else {
            throw CutError(code: "invalid_\(prefix)_project", message: "Project exceeds the 64 MB limit")
        }
        guard bytes.count < MulticamProject.maximumFileSize else { return bytes }
        var data = bytes
        data.append(0x0A)
        return data
    }

    private static func publishProject(_ data: Data, to url: URL, prefix: String, replacingExisting: Bool) throws {
        if !replacingExisting {
            let stage = url.deletingLastPathComponent().appendingPathComponent(".mpcut-" + UUID().uuidString)
            try data.write(to: stage, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: stage) }
            let error = publishExclusively(from: stage, to: url)
            guard error == 0 else {
                if error == EEXIST { throw CutError(code: "destination_exists", message: "The destination already exists at " + url.path) }
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            return
        }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw CutError(code: "\(prefix)_project_write_failed", message: "Choose a regular project file at \(url.path)")
        }
        do { try data.write(to: url, options: .atomic) }
        catch {
            throw CutError(code: "\(prefix)_project_write_failed", message: "Could not save \(url.path): \(error.localizedDescription)")
        }
    }

    static func validateDestination(_ output: URL, sourceDirectory: URL,
                                    sources: [(String, String)], prefix: String, includesContents: Bool = false) throws {
        let destination = canonicalFileURL(output)
        let destinationIdentity = fileIdentity(destination)
        var volumeDirectory = destination.deletingLastPathComponent()
        while !volumeDirectory.path.isEmpty, volumeDirectory.path != "/",
              !FileManager.default.fileExists(atPath: volumeDirectory.path) {
            volumeDirectory.deleteLastPathComponent()
        }
        let caseInsensitive = (try? volumeDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
        var checked = Set<String>()
        for (id, file) in sources where checked.insert(file).inserted {
            let location = sourceURL(file: file, in: sourceDirectory)
            guard !location.path.split(separator: "/").contains("..") else { continue }
            let media = canonicalFileURL(location)
            let matchesMissingDestination = destinationIdentity == nil && caseInsensitive
                && media.path.caseInsensitiveCompare(destination.path) == .orderedSame
            if includesContents {
                let prefixPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
                let options: String.CompareOptions = caseInsensitive ? [.anchored, .caseInsensitive] : [.anchored]
                if media.path.range(of: prefixPath, options: options) != nil {
                    throw CutError(code: "\(prefix)_project_source_collision",
                                   message: "Project destination contains source ‘\(id)’ at \(media.path)")
                }
            }
            guard media.path != destination.path, !matchesMissingDestination,
                  destinationIdentity.map({ $0 != fileIdentity(media) }) ?? true else {
                throw CutError(code: "\(prefix)_project_source_collision",
                               message: "Project destination overlaps source ‘\(id)’ at \(media.path)")
            }
        }
    }

    static func checkedSourceURL(file: String, in directory: URL) throws -> URL {
        let location = sourceURL(file: file, in: directory)
        guard !location.path.split(separator: "/").contains("..") else {
            throw CutError(code: "missing_source", message: "Source has an unavailable parent directory: \(location.path)")
        }
        return location
    }

    static func sourceURL(file: String, in directory: URL) -> URL {
        let path = file.hasPrefix("/") ? file :
            directory.path + "/" + file
        let components = path.split(separator: "/")
        guard let parent = components.lastIndex(of: "..") else {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let prefix = "/" + components[...parent].joined(separator: "/")
        if let resolved = realpath(prefix, nil) {
            defer { free(resolved) }
            let path = String(cString: resolved) + "/" + components[(parent + 1)...].joined(separator: "/")
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        // Preserve the unresolved traversal for diagnostics and missing-source
        // checks. Standardizing here could select another recording.
        var url = URLComponents()
        url.scheme = "file"
        url.host = ""
        url.path = path
        return url.url!
    }

    private static func canonicalFileURL(_ url: URL, remainingLinks: Int = 32) -> URL {
        var resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if (try? resolved.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
           let target = try? URL(resolvingAliasFileAt: resolved, options: [.withoutUI, .withoutMounting]) {
            resolved = target.standardizedFileURL.resolvingSymlinksInPath()
        }
        // Paths to offline media can still alias a new destination through an existing parent.
        var parent = resolved
        var missing: [String] = []
        while !parent.path.isEmpty && parent.path != "/" {
            if let physical = realpath(parent.path, nil) {
                defer { free(physical) }
                let base = URL(fileURLWithPath: String(cString: physical))
                return missing.reversed().reduce(base) { $0.appendingPathComponent($1) }
            }
            // realpath fails on a dangling media symlink, including a link to the
            // very name this save would create. Follow its stored target as well.
            if remainingLinks > 0,
               let target = try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path) {
                let location = sourceURL(file: target, in: parent.deletingLastPathComponent())
                let base = canonicalFileURL(location, remainingLinks: remainingLinks - 1)
                return missing.reversed().reduce(base) { $0.appendingPathComponent($1) }
            }
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        return resolved
    }

    static func sidecarExclusions(sources: Dictionary<String, String>.Keys, candidates: Set<URL>) -> Set<URL> {
        var names = Set<String>()
        var foldedNames = Set<String>()
        var basenames = Set<String>()
        var linkedFiles = Set<FileIdentity>()
        for path in sources where !path.split(separator: "/").contains("..") {
            let physical = canonicalFileURL(URL(fileURLWithPath: path))
            names.insert(physical.path)
            foldedNames.insert(physical.path.folding(options: .caseInsensitive, locale: nil))
            basenames.insert(physical.lastPathComponent.folding(options: .caseInsensitive, locale: nil))
            var info = stat()
            if stat(physical.path, &info) == 0 && info.st_nlink > 1 {
                linkedFiles.insert(FileIdentity(device: NSNumber(value: info.st_dev), inode: NSNumber(value: info.st_ino)))
            }
        }
        var exclusions = Set<URL>()
        var caseInsensitiveFolders: [URL: Bool] = [:]
        func overlaps(_ destination: URL) -> Bool {
            // A new cache with a different basename cannot resolve to an existing
            // recording or hard link. Avoid resolving each missing SQLite sibling.
            if !basenames.contains(destination.lastPathComponent.folding(options: .caseInsensitive, locale: nil)) {
                var info = stat()
                if lstat(destination.path, &info) != 0 { return false }
            }
            let physical = canonicalFileURL(destination)
            if names.contains(physical.path) { return true }
            if !linkedFiles.isEmpty, let id = fileIdentity(physical), linkedFiles.contains(id) { return true }
            guard foldedNames.contains(physical.path.folding(options: .caseInsensitive, locale: nil)) else { return false }
            let folder = physical.deletingLastPathComponent()
            if let cached = caseInsensitiveFolders[folder] { return cached }
            let insensitive = (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames) == false
            caseInsensitiveFolders[folder] = insensitive
            return insensitive
        }
        for source in candidates {
            let canonical = AnalysisSidecar.canonicalSource(source)
            // Some probes use the selected path, others open the resolved source.
            let siblings = Set([source.standardizedFileURL, canonical])
            if siblings.contains(where: { sibling in
                let base = AnalysisSidecar.url(for: sibling).path
                return ["", "-journal", "-wal", "-shm"].contains { overlaps(URL(fileURLWithPath: base + $0)) }
            }) {
                exclusions.insert(source.standardizedFileURL)
                exclusions.insert(canonical)
            }
        }
        return exclusions
    }

    private struct FileIdentity: Hashable {
        let device: NSNumber
        let inode: NSNumber
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return .init(device: device, inode: inode)
    }

}
