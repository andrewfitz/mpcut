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

    private enum CodingKeys: String, CodingKey {
        case id, file, from, to
        case audioTrack = "track_ordinal"
        case originalFile = "original_file"
        case replacementNames = "replacement_names"
    }

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

    func validateFields() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CutError(code: "invalid_cut_project", message: "Clip IDs must be nonempty and unique")
        }
        guard ProjectFile.validMediaPath(file), originalFile.map(ProjectFile.validMediaPath) ?? true,
              from >= .zero, to > from,
              audioTrack.map({ (0...Int(Int32.max)).contains($0) }) ?? true,
              replacementNames.keys.allSatisfy({ (0...Int(Int32.max)).contains($0) }) else {
            throw CutError(code: "invalid_cut_project", message: "Invalid media path, source range or audio track for clip ‘\(id)’")
        }
    }
}

/// Invariants that depend on the other clips or their order, including the exact duration sum.
struct SequenceClipOrderValidation {
    private var ids = Set<String>()
    private var duration = RationalTime.zero

    mutating func append(_ clip: CutSequenceClip) throws {
        guard ids.insert(clip.id).inserted else {
            throw CutError(code: "invalid_cut_project", message: "Clip IDs must be nonempty and unique")
        }
        duration = try duration.adding(clip.to.subtracting(clip.from))
    }
}

public enum CutProject: Equatable, Codable, Sendable {
    public static let format = "mpcut"
    public static let schemaVersion = 6
    package static let readableSchemaVersions: Set<Int> = [3, 4, schemaVersion]

    case sequence([CutSequenceClip])
    case multicam(MulticamProject)
    case stillSequence(StillSequenceProject)

    private enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case kind, clips, history
        case mediaSnapshot = "media_snapshot"
        case stillAssets = "still_assets"
        case stillReplacements = "still_replacements"
        case programColorPolicy = "program_color_policy"
        case stillFormat = "still_format"
        case stillSoundtrack = "still_soundtrack"
        case transcripts, participants
        case sourceSelects = "source_selects"
    }

    public var transcripts: ProjectTranscripts {
        get {
            switch self {
            case .sequence: .init()
            case .stillSequence(let project): project.transcripts
            case .multicam(let project): project.transcripts
            }
        }
        set {
            switch self {
            case .sequence(let clips):
                if !newValue.isEmpty {
                    self = .stillSequence(StillSequenceProject(items: clips.map(StillSequenceItem.source), transcripts: newValue))
                }
            case .stillSequence(var project):
                project.transcripts = newValue
                self = newValue.isEmpty && !project.hasStillContent && project.sourceSelects.isEmpty && project.stillAudioReference == nil && project.participants.isEmpty
                    ? .sequence(project.items.compactMap(\.source)) : .stillSequence(project)
            case .multicam(var project):
                project.transcripts = newValue
                self = .multicam(project)
            }
        }
    }

    public var participants: ParticipantProject {
        get {
            switch self {
            case .sequence: .init()
            case .stillSequence(let project): project.participants
            case .multicam(let project): project.participants
            }
        }
        set {
            switch self {
            case .sequence(let clips):
                guard !newValue.isEmpty else { return }
                self = .stillSequence(.init(items: clips.map(StillSequenceItem.source), participants: newValue))
            case .stillSequence(var project):
                project.participants = newValue
                self = newValue.isEmpty && !project.hasStillContent && project.transcripts.isEmpty
                    && project.sourceSelects.isEmpty && project.stillAudioReference == nil
                    ? .sequence(project.items.compactMap(\.source)) : .stillSequence(project)
            case .multicam(var project):
                project.participants = newValue
                self = .multicam(project)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == Self.format else {
            throw CutError(code: "invalid_cut_project", message: "Expected an MPCut project document")
        }
        guard let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion),
              Self.readableSchemaVersions.contains(version) else {
            throw CutError(code: "unsupported_cut_version", message: "Expected MPCut project schema_version 3, 4 or \(Self.schemaVersion)")
        }
        switch try values.decode(String.self, forKey: .kind) {
        case "sequence":
            try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_project")
            let stillFields: [CodingKeys] = [.stillAssets, .stillReplacements, .programColorPolicy, .stillFormat, .stillSoundtrack]
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
                stillFormat: values.decodeIfPresent(StillTimelineFormat.self, forKey: .stillFormat),
                sourceSelects: values.contains(.sourceSelects) ? values.decode([NamedSourceSelect].self, forKey: .sourceSelects) : [],
                stillSoundtrack: values.decodeIfPresent(CutSequenceClip.self, forKey: .stillSoundtrack)
            )
            self = project.hasStillContent || !project.sourceSelects.isEmpty ? .stillSequence(project) : .sequence(project.items.compactMap(\.source))
            if version < Self.schemaVersion, requiresExtendedStillSchema {
                throw stillError("These still sequence settings require project schema version \(Self.schemaVersion)")
            }
            if values.contains(.transcripts) {
                transcripts = try values.decode(ProjectTranscripts.self, forKey: .transcripts)
            }
            if values.contains(.participants) {
                guard version >= 4 else { throw invalidParticipantProject("Participant metadata requires project schema version 4.") }
                participants = try values.decode(ParticipantProject.self, forKey: .participants)
            }
            try validate()
        case "multicam": self = .multicam(try MulticamProject(from: decoder))
        default: throw CutError(code: "invalid_cut_project", message: "Unknown MPCut project kind")
        }
    }

    var requiresExtendedStillSchema: Bool {
        stillSoundtrack != nil || stillFormat?.requiresExtendedStillSchema == true || stillInserts.contains(where: \.usesExactDuration)
    }

    public func encode(to encoder: Encoder) throws {
        try encode(to: encoder, requiresExtendedStillSchema: requiresExtendedStillSchema)
    }

    func encode(to encoder: Encoder, requiresExtendedStillSchema: Bool) throws {
        try validate()
        guard stillAudioReference == nil else {
            throw CutError(code: "transient_selection", message: "A still selection with inherited audio is an export snapshot.")
        }
        if case .multicam(let project) = self {
            try project.encode(to: encoder)
            return
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.format, forKey: .format)
        try values.encode(requiresExtendedStillSchema ? Self.schemaVersion : 4, forKey: .schemaVersion)
        try values.encode("sequence", forKey: .kind)
        if !transcripts.isEmpty { try values.encode(transcripts, forKey: .transcripts) }
        if !participants.isEmpty { try values.encode(participants, forKey: .participants) }
        let project = stillSequenceValue!
        try values.encode(project.items, forKey: .clips)
        if !project.sourceSelects.isEmpty { try values.encode(project.sourceSelects, forKey: .sourceSelects) }
        if !project.stillAssets.isEmpty { try values.encode(project.stillAssets, forKey: .stillAssets) }
        if !project.stillReplacements.isEmpty { try values.encode(project.stillReplacements, forKey: .stillReplacements) }
        try values.encodeIfPresent(project.programColorPolicy, forKey: .programColorPolicy)
        try values.encodeIfPresent(project.stillFormat, forKey: .stillFormat)
        try values.encodeIfPresent(project.stillSoundtrack, forKey: .stillSoundtrack)
    }

    public func validate() throws {
        switch self {
        case .multicam(let project): try project.validate()
        case .stillSequence(let project):
            try project.transcripts.validate()
            try project.participants.validate()
            guard project.participants.protectedMediaPaths.allSatisfy({ ProjectFile.validMediaPath($0.1) }) else {
                throw invalidParticipantProject("Invalid participant media path.")
            }
            guard Set(project.sourceSelects.map(\.id)).count == project.sourceSelects.count else {
                throw CutError(code: "invalid_source_select", message: "Source select IDs must be unique.")
            }
            for select in project.sourceSelects { try select.validate() }
            let clips = project.items.compactMap(\.source)
            try Self.sequence(clips).validate()
            if let reference = project.stillAudioReference {
                try Self.sequence([reference]).validate()
                guard clips.isEmpty, project.stillFormat != nil else {
                    throw stillError("An inherited soundtrack layout requires an insert-only export selection")
                }
            }
            if let soundtrack = project.stillSoundtrack {
                try soundtrack.validateFields()
                guard validStillID(soundtrack.id), clips.isEmpty, project.stillFormat != nil,
                      project.stillAudioReference == nil, soundtrack.audioTrack != nil else {
                    throw stillError("A still soundtrack requires an explicit still-only sequence and a selected audio track")
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
                    if !insert.usesExactDuration { _ = try format.frameCount(for: insert.duration) }
                }
            } else if clips.isEmpty && !inserts.isEmpty {
                throw stillError("A still-only sequence requires an explicit program format")
            }
            let duration = try stillTimelineDuration()
            if let format = project.stillFormat, !inserts.isEmpty, !inserts.contains(where: \.usesExactDuration) {
                _ = try format.frameCount(for: duration)
            }
        case .sequence(let clips):
            var order = SequenceClipOrderValidation()
            for clip in clips {
                try clip.validateFields()
                try order.append(clip)
            }
        }
    }

    public static func load(from url: URL) throws -> Self {
        try Self.loadDocument(from: url, limit: 0).project
    }

    public static func decode(_ data: Data) throws -> Self {
        try Self.decodeDocument(data, limit: 0).project
    }

    package var mediaPaths: [(String, String)] {
        switch self {
        case .sequence(let clips):
            return clips.flatMap { clip in
                [clip.file, clip.originalFile].compactMap { $0 }.map { (clip.id, $0) }
            }
        case .multicam(let project):
            return project.sources.map { ($0.id, $0.file) } + project.stillAssets.map { ($0.id, $0.file) }
                + project.transcripts.protectedPaths
        case .stillSequence(let project):
            let references = [project.stillAudioReference, project.stillSoundtrack].compactMap { $0 }
            return Self.sequence(project.items.compactMap(\.source) + references).mediaPaths + project.stillAssets.map { ($0.id, $0.file) }
                + project.transcripts.protectedPaths + project.sourceSelects.map { ($0.id, $0.range.file) }
                + project.participants.protectedMediaPaths
        }
    }

    public func validateDestination(_ output: URL, relativeTo projectURL: URL, includesContents: Bool = false) throws {
        try validateDestination(output, sourceDirectory: ProjectFile.directory(of: projectURL), includesContents: includesContents)
        let assets = transcripts.attachments.compactMap { attachment in
            TranscriptStore.assetLocation(attachment.asset, relativeTo: projectURL).map { (attachment.id, $0.path) }
        }
        if !assets.isEmpty {
            try ProjectFile.validateDestination(output, sourceDirectory: ProjectFile.directory(of: projectURL), sources: assets,
                                                prefix: "cut", includesContents: includesContents)
        }
    }

    package func validateDestination(_ output: URL, sourceDirectory: URL, includesContents: Bool = false) throws {
        try validate()
        try ProjectFile.validateDestination(output, sourceDirectory: sourceDirectory, sources: mediaPaths, prefix: "cut",
                                            includesContents: includesContents)
    }

    /// Protect media referenced by this document from SQLite cache or journal I/O.
    package static func sidecarExclusions(absoluteSources: [String: String], candidates: [URL],
                                          projectURL: URL? = SidecarLocations.projectURL) -> Set<URL> {
        guard !absoluteSources.isEmpty, !candidates.isEmpty else { return [] }
        return ProjectFile.sidecarExclusions(sources: absoluteSources.keys, candidates: Set(candidates), projectURL: projectURL)
    }

    public func save(to url: URL, mediaSnapshot: ProjectMediaSnapshot = .empty) throws {
        try save(to: url, undo: [], redo: [], mediaSnapshot: mediaSnapshot)
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

    package func rebased(from sourceURL: URL, to destinationURL: URL, paths: inout [String: String],
                 makeRelative: Bool = false) throws -> Self {
        try validate()
        let sourceDirectory = ProjectFile.directory(of: sourceURL)
        if !makeRelative && sourceDirectory == ProjectFile.directory(of: destinationURL) { return self }
        return mapMediaPaths { path in
            if let cached = paths[path] { return cached }
            let file = ProjectFile.sourceURL(file: path, in: sourceDirectory)
            let relative = Self.relativeMediaPath(file.path, to: destinationURL)
            paths[path] = relative
            return relative
        }
    }

    package func withAbsoluteMediaPaths(relativeTo projectURL: URL) -> Self {
        let directory = ProjectFile.directory(of: projectURL)
        var paths: [String: String] = [:]
        return mapMediaPaths { path in
            if let cached = paths[path] { return cached }
            let absolute = ProjectFile.sourceURL(file: path, in: directory).path
            paths[path] = absolute
            return absolute
        }
    }

    package func mapMediaPaths(_ rebase: (String) -> String) -> Self {
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
            func rebaseReference(_ clip: CutSequenceClip) -> CutSequenceClip {
                var clip = clip
                clip.file = rebase(clip.file)
                clip.originalFile = clip.originalFile.map(rebase)
                return clip
            }
            project.stillAudioReference = project.stillAudioReference.map(rebaseReference)
            project.stillSoundtrack = project.stillSoundtrack.map(rebaseReference)
            project.sourceSelects = project.sourceSelects.map { $0.mapPath(rebase) }
            project.participants = project.participants.mapSourcePaths(rebase)
            project.transcripts = project.transcripts.mapSourcePaths(rebase)
            return .stillSequence(project)
        case .multicam(var project):
            project.angles = project.angles.map { $0.mappingFiles(rebase) }
            project.audioSources = project.audioSources.map { $0.mappingFiles(rebase) }
            for index in project.stillAssets.indices { project.stillAssets[index].file = rebase(project.stillAssets[index].file) }
            project.transcripts = project.transcripts.mapSourcePaths(rebase)
            return .multicam(project)
        }
    }

    public static func relativeMediaPath(_ path: String, to url: URL) -> String {
        guard !path.split(separator: "/").contains(".."),
              !ProjectMediaVolume.isChecking(URL(fileURLWithPath: path, isDirectory: false)),
              !ProjectMediaVolume.isChecking(url) else { return path }
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
        if case .stillSequence(let project) = self, project.hasStillContent || project.stillAudioReference != nil {
            throw stillError("A still sequence requires the still timeline planner", code: "still_timeline_required")
        }
        guard let clips = sequenceClips else {
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
        guard !ProjectMediaVolume.isChecking(url) else { return url }
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
        // A project on disk is compressed. One written as plain JSON reads as it always did.
        let text = try ProjectSavedBytes.unpacked(data, code: code) ?? data
        guard !text.contains(0), String(data: text, encoding: .utf8) != nil else {
            throw CutError(code: code, message: "Project must contain a UTF-8 JSON object")
        }
        // A project saved in the shared layout is read as the document it stands for.
        let data = try ProjectSavedLayout.expanded(text, code: code) ?? text
        do {
            let project = try JSONDecoder().decode(type, from: data)
            if let issue = jsonInputIssue(data, integerNumbersOnly: true, allowsFraction: allowsProjectFraction) {
                throw CutError(code: code, message: "Project \(issue)")
            }
            return project
        } catch let error as DecodingError {
            throw CutError(code: code, message: "Invalid project JSON: \(error)")
        }
    }

    private static func allowsProjectFraction(_ locations: [JSONInputLocation]) -> Bool {
        let keys = locations.compactMap { location -> String? in
            guard case .key(let key) = location else { return nil }
            return key
        }
        if keys.first == "media_snapshot" { return true }
        let fields: ArraySlice<String>
        if keys.first == "participants" {
            fields = keys.dropFirst()
        } else if keys.starts(with: ["history", "undo", "participants"]) || keys.starts(with: ["history", "redo", "participants"]) {
            fields = keys.dropFirst(3)
        } else {
            return false
        }
        guard let last = fields.last else { return false }
        let parent = fields.dropLast()
        if parent.elementsEqual(["sources", "appearances", "bounds"])
            || parent.elementsEqual(["sources", "appearances", "label_bounds"]) {
            return ["x", "y", "width", "height"].contains(last)
        }
        return parent.elementsEqual(["render", "shots", "slots"]) && ["anchor_x", "anchor_y"].contains(last)
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
        _ = try writeRevision(bytes, to: url, sources: sources, prefix: prefix,
                              replacingExisting: replacingExisting, expected: nil)
    }

    /// The caller holds the draft lease and publishes this private stage.
    static func writeStaged(_ bytes: Data, to url: URL, sources: [(String, String)], replacingExisting: Bool) throws {
        let data = try diskBytes(bytes, prefix: "cut")
        try validateDestination(url, sourceDirectory: directory(of: url), sources: sources, prefix: "cut")
        try publishProject(data, to: url, prefix: "cut", replacingExisting: replacingExisting)
    }

    static func writeRevision(_ bytes: Data, to url: URL, sources: [(String, String)], prefix: String,
                              replacingExisting: Bool, expected: ProjectDiskRevision?,
                              transcriptAssets: [TranscriptAsset]? = nil, hasTranscriptMetadata: Bool = false,
                              beforePublish: () throws -> Void = {}) throws -> ProjectDiskRevision {
        let data = try diskBytes(bytes, prefix: prefix)
        return try coordinatedWrite(to: url, prefix: prefix, expected: expected) { destination, verifyDestination in
            let target = replacingExisting ? destination : url
            try validateDestination(target, sourceDirectory: directory(of: target), sources: sources, prefix: prefix)
            func publish() throws {
                try publishProject(data, to: target, prefix: prefix, replacingExisting: replacingExisting) {
                    try beforePublish()
                    try verifyDestination()
                }
            }
            if let transcriptAssets {
                try TranscriptStore.publish(relativeTo: target, keeping: transcriptAssets,
                                            hasTranscriptMetadata: hasTranscriptMetadata, publish)
            } else {
                try publish()
            }
            return data
        }
    }

    static func diskBytes(_ bytes: Data, prefix: String) throws -> Data {
        // Every project is written the same way: what the document repeats is written once,
        // and the result is compressed. MPCUT_PROJECT_VERSION=4 keeps the plain document for a
        // build that predates this.
        // The limit is on the document itself, whatever form it is written in.
        guard bytes.count <= MulticamProject.maximumFileSize else {
            throw CutError(code: "invalid_\(prefix)_project", message: "Project exceeds the 64 MB limit")
        }
        let text = ProjectSavedLayout.prefersExpanded ? bytes : ProjectSavedLayout.compacted(bytes) ?? bytes
        if !ProjectSavedLayout.prefersExpanded, let packed = ProjectSavedBytes.packed(text) { return packed }
        guard text.count < MulticamProject.maximumFileSize else { return text }
        var data = text
        data.append(0x0A)
        return data
    }

    static func publishProject(_ data: Data, to url: URL, prefix: String, replacingExisting: Bool,
                               beforePublish: () throws -> Void = {}) throws {
        if !replacingExisting {
            let stage = url.deletingLastPathComponent().appendingPathComponent(".mpcut-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            try data.write(to: stage, options: .withoutOverwriting)
            try beforePublish()
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
        try beforePublish()
        do { try data.write(to: url, options: .atomic) }
        catch {
            throw CutError(code: "\(prefix)_project_write_failed", message: "Could not save \(url.path): \(error.localizedDescription)")
        }
    }

    static func validateDestination(_ output: URL, sourceDirectory: URL,
                                    sources: [(String, String)], prefix: String, includesContents: Bool = false) throws {
        guard !ProjectMediaVolume.isChecking(output) else {
            throw CutError(code: "media_volume_checking", message: "The destination volume is still checking: \(output.path)")
        }
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
            let path = file.hasPrefix("/") ? file : sourceDirectory.path + "/" + file
            let lexical = URL(fileURLWithPath: path, isDirectory: false)
            let checking = ProjectMediaVolume.isChecking(lexical)
            let location = checking ? ProjectMediaVolume.watchURL(lexical) : sourceURL(file: file, in: sourceDirectory)
            guard !location.path.split(separator: "/").contains("..") else { continue }
            let media = checking ? location : canonicalFileURL(location)
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
                  checking || (destinationIdentity.map({ $0 != fileIdentity(media) }) ?? true) else {
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
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let components = path.split(separator: "/")
        guard let parent = components.lastIndex(of: "..") else { return url.standardizedFileURL }
        // Preserve unresolved parent traversal even while a mount is checking.
        // Lexically collapsing it could select a different recording.
        guard !ProjectMediaVolume.isChecking(url) else { return url }
        let prefix = "/" + components[...parent].joined(separator: "/")
        guard let resolved = realpath(prefix, nil) else { return url }
        defer { free(resolved) }
        let result = String(cString: resolved) + "/" + components[(parent + 1)...].joined(separator: "/")
        return URL(fileURLWithPath: result, isDirectory: false).standardizedFileURL
    }

    static func canonicalFileURL(_ url: URL, remainingLinks: Int = 32) -> URL {
        let path = url.path
        let location = path.split(separator: "/").contains("..")
            ? sourceURL(file: path, in: url.deletingLastPathComponent()) : url
        // An unavailable parent does not identify the file that a lexical
        // normalization would produce.
        guard !location.path.split(separator: "/").contains("..") else { return location }
        var resolved = location.standardizedFileURL.resolvingSymlinksInPath()
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

    static func sidecarExclusions(sources: Dictionary<String, String>.Keys, candidates: Set<URL>,
                                  projectURL: URL?) -> Set<URL> {
        var names = Set<String>()
        var foldedNames = Set<String>()
        var basenames = Set<String>()
        var linkedFiles = Set<FileIdentity>()
        for path in sources where !path.split(separator: "/").contains("..") {
            let source = URL(fileURLWithPath: path, isDirectory: false)
            let checking = ProjectMediaVolume.isChecking(source)
            let physical = checking ? source : canonicalFileURL(source)
            names.insert(physical.path)
            foldedNames.insert(physical.path.folding(options: .caseInsensitive, locale: nil))
            basenames.insert(physical.lastPathComponent.folding(options: .caseInsensitive, locale: nil))
            guard !checking else { continue }
            var info = stat()
            if stat(physical.path, &info) == 0 && info.st_nlink > 1 {
                linkedFiles.insert(FileIdentity(device: NSNumber(value: info.st_dev), inode: NSNumber(value: info.st_ino)))
            }
        }
        var exclusions = Set<URL>()
        var caseInsensitiveFolders: [URL: Bool] = [:]
        func overlaps(_ destination: URL) -> Bool {
            if ProjectMediaVolume.isChecking(destination) { return true }
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
            if ProjectMediaVolume.isChecking(source) {
                exclusions.insert(ProjectMediaVolume.watchURL(source))
                continue
            }
            let canonical = AnalysisSidecar.canonicalSource(source)
            let locations = SidecarLocations(source: source, project: projectURL)
            var paths = Set(locations.candidates)
            if let destination = locations.destination { paths.insert(destination) }
            if paths.contains(where: { cache in
                ["", "-journal", "-wal", "-shm"].contains { overlaps(URL(fileURLWithPath: cache.path + $0)) }
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
