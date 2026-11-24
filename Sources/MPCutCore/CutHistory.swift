import Darwin
import Foundation

public enum HistoryOrigin: String, Codable, Sendable {
    case user, agent, unknown

    @TaskLocal public static var current: HistoryOrigin = .user
}

/// The destination state and the name of the action traversed to reach it.
public struct CutHistoryState: Equatable, Sendable {
    public let action: String
    public let origin: HistoryOrigin
    public let project: CutProject

    package let bindingChanges: [TranscriptBindingChange]?

    public init(action: String, origin: HistoryOrigin = HistoryOrigin.current, project: CutProject) {
        self.init(action: action, origin: origin, project: project, bindingChanges: nil)
    }

    package init(action: String, origin: HistoryOrigin = HistoryOrigin.current, project: CutProject,
                 bindingChanges: [TranscriptBindingChange]?) {
        self.bindingChanges = bindingChanges
        self.action = action
        self.origin = origin
        self.project = project
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.action == rhs.action && lhs.origin == rhs.origin && lhs.project == rhs.project
            && (lhs.bindingChanges ?? []) == (rhs.bindingChanges ?? [])
    }

    package func rebased(from source: URL, to destination: URL, paths: inout [String: String],
                         makeRelative: Bool = false) throws -> Self {
        let project = try project.rebased(from: source, to: destination, paths: &paths, makeRelative: makeRelative)
        let directory = ProjectFile.directory(of: source)
        guard makeRelative || directory != ProjectFile.directory(of: destination) else { return self }
        let changes = bindingChanges?.map { change in
            change.mappingPaths { path in
                if let existing = paths[path] { return existing }
                let file = ProjectFile.sourceURL(file: path, in: directory)
                let rebased = CutProject.relativeMediaPath(file.path, to: destination)
                paths[path] = rebased
                return rebased
            }
        }
        return Self(action: action, origin: origin, project: project, bindingChanges: changes)
    }
}

/// Media that must remain available to an edit, including only-in-history recordings.
package struct CutProjectMedia {
    package let project: CutProject
    package let diskRevision: ProjectDiskRevision?
    package let mediaSnapshot: ProjectMediaSnapshot
    private let paths: [String: String]

    fileprivate init(_ document: Document, diskRevision: ProjectDiskRevision? = nil,
                     migratedProject: CutProject? = nil) throws {
        project = try migratedProject ?? document.project.migratingLegacyTiles()
        mediaSnapshot = document.mediaSnapshot
        self.diskRevision = diskRevision
        var paths = Dictionary(project.mediaPaths.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        // Every history reference originates in the current timeline or a literal.
        // Copy runs never introduce a path, even beyond the editor's retention budget.
        for branch in [document.history?.undo ?? [], document.history?.redo ?? []] {
            var sequence = project.sequenceItems != nil
            for step in branch {
                if let timeline = step.timeline {
                    sequence = timeline.sequenceItems != nil
                    for (id, path) in timeline.mediaPaths { paths[path] = id }
                }
                for case .insert(.source(let clip)) in step.sequenceItems?.pieces ?? [] {
                    paths[clip.file] = clip.id
                    if let original = clip.originalFile { paths[original] = clip.id }
                }
                if sequence, let participants = step.participants {
                    for (id, path) in participants.protectedMediaPaths { paths[path] = id }
                }
                if let delta = step.sourceSelects {
                    for case .insert(let select) in delta.pieces { paths[select.range.file] = select.id }
                }
                for case .insert(let asset) in step.stillAssets?.pieces ?? [] { paths[asset.file] = asset.id }
                for case .insert(let record) in step.transcriptAuthoring?.pieces ?? [] {
                    for path in record.protectedPaths { paths[path] = record.id }
                }
                for change in step.transcriptBindings ?? [] {
                    if let file = change.before.file { paths[file] = change.trackID }
                    if let file = change.after.file { paths[file] = change.trackID }
                }
                for delta in [step.angles, step.audioSources] {
                    for case .insert(let source) in delta?.pieces ?? [] where source.feedAngle == nil {
                        paths[source.file] = source.id
                        for recording in source.additionalRecordings { paths[recording.file] = recording.id }
                    }
                }
            }
        }
        self.paths = paths
    }

    package func absoluteSources(relativeTo url: URL) -> [String: String] {
        let directory = ProjectFile.directory(of: url)
        var result: [String: String] = [:]
        for (path, id) in paths { result[ProjectFile.sourceURL(file: path, in: directory).path] = id }
        for attachment in project.transcripts.attachments {
            if let location = TranscriptStore.assetLocation(attachment.asset, relativeTo: url) {
                result[location.path] = attachment.id
            }
        }
        return result
    }

    package func sidecarExclusions(relativeTo url: URL) -> Set<URL> {
        let directory = ProjectFile.directory(of: url)
        let candidates = Set(project.mediaPaths.map(\.1)).map { ProjectFile.sourceURL(file: $0, in: directory) }
        return CutProject.sidecarExclusions(absoluteSources: absoluteSources(relativeTo: url), candidates: candidates, projectURL: url)
    }

    package static func load(from url: URL, multicam: Bool = false) throws -> Self {
        if multicam {
            let (snapshot, revision) = try ProjectFile.readSnapshot(MulticamDocument.self, from: url, multicam: true)
            return try Self(snapshot.document, diskRevision: revision)
        }
        let (document, revision) = try ProjectFile.readSnapshot(Document.self, from: url)
        return try Self(document, diskRevision: revision)
    }

    package static func decode(_ data: Data) throws -> Self {
        try Self(ProjectFile.decode(Document.self, data: data))
    }

    package func validateDestination(_ output: URL, relativeTo projectURL: URL, includesContents: Bool = false) throws {
        try CutProject.validateMediaDestination(output, absoluteSources: absoluteSources(relativeTo: projectURL),
                                                 includesContents: includesContents)
    }

    package func validateDestination(_ output: URL, sourceDirectory: URL, includesContents: Bool = false) throws {
        try CutProject.validateMediaDestination(output, sources: paths, sourceDirectory: sourceDirectory,
                                               includesContents: includesContents)
    }
}

private func historyError(_ message: String) -> CutError {
    CutError(code: "invalid_cut_history", message: message)
}

extension CutProject {
    /// Checks unique recording paths (keys) and their clip or source IDs (values).
    package static func validateMediaDestination(_ output: URL, sources: [String: String], sourceDirectory: URL,
                                                 includesContents: Bool = false) throws {
        try ProjectFile.validateDestination(output, sourceDirectory: sourceDirectory,
                                            sources: sources.map { ($0.value, $0.key) }, prefix: "cut",
                                            includesContents: includesContents)
    }

    package static func validateMediaDestination(_ output: URL, absoluteSources: [String: String],
                                                 includesContents: Bool = false) throws {
        try validateMediaDestination(output, sources: absoluteSources, sourceDirectory: output.deletingLastPathComponent(),
                                     includesContents: includesContents)
    }

    public static let maximumHistorySteps = 500
    fileprivate static let maximumMaterializedHistoryRecords = 1_000_000

    fileprivate var historyRecordCount: Int {
        let authoredRecords = transcripts.authoring.count
        let stillRecords = authoredRecords + stillAssets.count + stillReplacements.count + stillFragmentCount
            + (programColorPolicy == nil ? 0 : 1) + (stillFormat == nil ? 0 : 1)
            + (stillSoundtrack == nil ? 0 : 1) + participants.historyRecordCount
        switch self {
        case .sequence(let clips): return clips.count + authoredRecords
        case .stillSequence(let project): return project.items.count + stillRecords + project.sourceSelects.count
        case .multicam(let p):
            let recordings = p.angles.reduce(p.angles.count) { $0 + $1.additionalRecordings.count }
            let pictureRecords = recordings + p.switches.count + (p.assemblyItems?.count ?? 0)
                + p.groupTileLayouts.count + p.speakerAngles.count
            let audioRecords = p.audioSources.count + p.mixLanes.count + p.audioReplacements.count
                + (p.fixedAudio == nil ? 0 : 1)
            return pictureRecords + audioRecords + stillRecords
        }
    }

    fileprivate var stillFragmentCount: Int {
        stillReplacements.reduce(0) { count, placement in
            if case .sequence(let fragments) = placement.coverage { return count + fragments.count }
            return count
        }
    }

    /// Keep states nearest the current edit on both sides. Undo wins a tie.
    public static func historyCounts(undo: Int, redo: Int, limit: Int) -> (undo: Int, redo: Int) {
        let total = min(max(0, limit), maximumHistorySteps)
        let availableUndo = max(0, undo)
        let availableRedo = max(0, redo)
        let recentUndo = min(availableUndo, (total + 1) / 2)
        let keptRedo = min(availableRedo, total - recentUndo)
        return (min(availableUndo, total - keptRedo), keptRedo)
    }

    /// Paths in every state use the same base directory as the current edit.
    /// The next undo or redo is the last entry in its respective input stack.
    public func save(to url: URL, undo: [CutHistoryState], redo: [CutHistoryState],
                     mediaSnapshot: ProjectMediaSnapshot = .empty, replacingExisting: Bool = true) throws {
        if !transcripts.isEmpty || TranscriptStore.hasStore(relativeTo: url) {
            _ = try saveRevision(to: url, undo: undo, redo: redo, mediaSnapshot: mediaSnapshot,
                                 replacingExisting: replacingExisting, expected: nil)
        } else {
            try save(to: url, undo: undo, redo: redo, mediaSnapshot: mediaSnapshot, byteLimit: MulticamProject.maximumFileSize,
                     replacingExisting: replacingExisting)
        }
    }

    /// The draft lease already owns the directory lock. Write only the private stage.
    package func saveStaged(to url: URL, undo: [CutHistoryState], redo: [CutHistoryState],
                            mediaSnapshot: ProjectMediaSnapshot,
                            replacingExisting: Bool = true) throws {
        let (bytes, sources) = try encodedArchive(undo: undo, redo: redo, mediaSnapshot: mediaSnapshot,
                                                  byteLimit: MulticamProject.maximumFileSize)
        try ProjectFile.writeStaged(bytes, to: url, sources: sources, replacingExisting: replacingExisting)
    }

    package func saveRevision(to url: URL, undo: [CutHistoryState], redo: [CutHistoryState],
                              mediaSnapshot: ProjectMediaSnapshot,
                              replacingExisting: Bool = true, expected: ProjectDiskRevision?,
                              beforePublish: () throws -> Void = {}) throws -> ProjectDiskRevision {
        let (bytes, sources) = try encodedArchive(undo: undo, redo: redo, mediaSnapshot: mediaSnapshot,
                                                  byteLimit: MulticamProject.maximumFileSize)
        return try ProjectFile.writeRevision(bytes, to: url, sources: sources, prefix: "cut",
                                             replacingExisting: replacingExisting, expected: expected,
                                             transcriptAssets: transcripts.attachments.map(\.asset),
                                             hasTranscriptMetadata: !transcripts.isEmpty, beforePublish: beforePublish)
    }

    @discardableResult
    package func saveNewCopy(to url: URL, copyingTranscriptsFrom source: URL,
                             undo: [CutHistoryState], redo: [CutHistoryState],
                             mediaSnapshot: ProjectMediaSnapshot,
                             beforePublish: () throws -> Void = {},
                             check: () throws -> Void) throws -> CutProject {
        try saveCopy(to: url, copyingTranscriptsFrom: source, undo: undo, redo: redo, mediaSnapshot: mediaSnapshot,
                     replacingExisting: false, expected: nil, beforePublish: beforePublish, check: check)
    }

    @discardableResult
    package func saveCopy(to url: URL, copyingTranscriptsFrom source: URL,
                          undo: [CutHistoryState], redo: [CutHistoryState],
                          mediaSnapshot: ProjectMediaSnapshot,
                          replacingExisting: Bool, expected: ProjectDiskRevision?,
                          assetData: [TranscriptAsset: Data] = [:], beforePublish: () throws -> Void = {},
                          check: () throws -> Void) throws -> CutProject {
        try saveCopyRevision(to: url, copyingTranscriptsFrom: source, undo: undo, redo: redo, mediaSnapshot: mediaSnapshot,
                             replacingExisting: replacingExisting, expected: expected, assetData: assetData,
                             beforePublish: beforePublish, check: check).project
    }

    package func saveCopyRevision(to url: URL, copyingTranscriptsFrom source: URL,
                                  undo: [CutHistoryState], redo: [CutHistoryState],
                                  mediaSnapshot: ProjectMediaSnapshot,
                                  replacingExisting: Bool, expected: ProjectDiskRevision?,
                                  assetData: [TranscriptAsset: Data] = [:], beforePublish: () throws -> Void = {},
                                  check: () throws -> Void = {}) throws
        -> (project: CutProject, revision: ProjectDiskRevision) {
        func requireNewDestination() throws {
            var entry = stat()
            guard lstat(url.path, &entry) != 0 else {
                throw CutError(code: "destination_exists", message: "The destination already exists at " + url.path)
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        if !replacingExisting { try requireNewDestination() }
        var project = self
        let revision = try ProjectFile.coordinatedWrite(to: url, prefix: "cut", expected: expected) { destination, verifyDestination in
            try check()
            if !replacingExisting { try requireNewDestination() }
            let target = replacingExisting ? destination : url
            return try TranscriptStore.withCopy(in: transcripts, from: source, to: target, assetData: assetData,
                                                check: check) { copied in
                project.transcripts = copied
                let (bytes, sources) = try project.encodedArchive(undo: undo, redo: redo, mediaSnapshot: mediaSnapshot,
                                                                  byteLimit: MulticamProject.maximumFileSize)
                let data = try ProjectFile.diskBytes(bytes, prefix: "cut")
                try ProjectFile.validateDestination(target, sourceDirectory: ProjectFile.directory(of: target),
                                                    sources: sources, prefix: "cut")
                try TranscriptStore.publish(relativeTo: target, keeping: copied.attachments.map(\.asset),
                                            hasTranscriptMetadata: !copied.isEmpty) {
                    try check()
                    try ProjectFile.publishProject(data, to: target, prefix: "cut", replacingExisting: replacingExisting) {
                        try check()
                        try beforePublish()
                        try verifyDestination()
                    }
                }
                return data
            }
        }
        return (project, revision)
    }

    func save(to url: URL, undo: [CutHistoryState], redo: [CutHistoryState],
              mediaSnapshot: ProjectMediaSnapshot = .empty, byteLimit: Int,
              replacingExisting: Bool = true) throws {
        let (bytes, sources) = try encodedArchive(undo: undo, redo: redo, mediaSnapshot: mediaSnapshot, byteLimit: byteLimit)
        try ProjectFile.write(bytes, to: url, sources: sources, prefix: "cut", replacingExisting: replacingExisting,
                              byteLimit: byteLimit)
    }

    func encodedArchive(undo: [CutHistoryState], redo: [CutHistoryState],
                        mediaSnapshot: ProjectMediaSnapshot, byteLimit: Int) throws -> (Data, [(String, String)]) {
        let currentSources = mediaPaths
        let current = Set(currentSources.map(\.1))
        guard !undo.isEmpty || !redo.isEmpty else {
            let base = try ProjectFile.encoded(self, compact: false)
            return (try mediaSnapshot.appending(to: base, current: current, retained: [], byteLimit: byteLimit), currentSources)
        }
        // Measure individual deltas before creating the complete archive, so an
        // edit that pastes a large timeline repeatedly cannot allocate many
        // times the file-size cap in a speculative JSONEncoder buffer.
        let base = try ProjectFile.encoded(self, compact: true)
        var byteBudget = byteLimit - base.count - 32 // both empty branch headers
        var recordBudget = Self.maximumMaterializedHistoryRecords
        var sources = Dictionary(currentSources.map { ($0.1, $0.0) }, uniquingKeysWith: { id, _ in id })
        // Even a state pruned from the file can still be reached in the editor.
        // Saving must never replace a recording that only that state references.
        for stack in [undo, redo] {
            for state in stack {
                for change in state.bindingChanges ?? [] {
                    if let file = change.before.file { sources[file] = change.trackID }
                    if let file = change.after.file { sources[file] = change.trackID }
                }
                var timelineAndAuthored = state.project
                timelineAndAuthored.transcripts.attachments = []
                for (id, file) in timelineAndAuthored.mediaPaths { sources[file] = id }
                for attachment in state.project.transcripts.attachments {
                    for binding in attachment.bindings {
                        if let file = binding.file { sources[file] = binding.trackID }
                    }
                }
            }
        }
        var previousUndo = self
        var previousRedo = self
        var undoSteps: [Step] = []
        var redoSteps: [Step] = []
        var retained = Set<String>()
        try walkHistory(undo: undo.count, redo: redo.count, limit: Self.maximumHistorySteps) { backwards, distance in
            let state = backwards ? undo[undo.count - 1 - distance] : redo[redo.count - 1 - distance]
            let previous = backwards ? previousUndo : previousRedo
            let records = state.project.historyRecordCount
            guard records <= recordBudget else { return false }
            try state.project.validate()
            let step = try Step(action: state.action, origin: state.origin, from: previous, to: state.project,
                                bindingChanges: state.bindingChanges)
            // Materialized branches keep the current attachment list even when
            // a historical editor snapshot predates a later transcript import.
            let bindingRecords = step.bindingRecordCount(in: transcripts)
            guard bindingRecords <= recordBudget - records else { return false }
            let size = try ProjectFile.encoded(step, compact: true).count + 1 // element separator
            guard size <= byteBudget else { return false }
            byteBudget -= size
            recordBudget -= records + bindingRecords
            if !mediaSnapshot.entries.isEmpty {
                retained.formUnion(state.project.mediaPaths.map(\.1))
                for change in step.transcriptBindings ?? [] {
                    if let file = change.before.file { retained.insert(file) }
                    if let file = change.after.file { retained.insert(file) }
                }
            }
            if backwards {
                previousUndo = state.project
                undoSteps.append(step)
            } else {
                previousRedo = state.project
                redoSteps.append(step)
            }
            return true
        }
        let bytes: Data
        if undoSteps.isEmpty && redoSteps.isEmpty {
            bytes = base
        } else {
            let document = Document(project: self, history: Archive(undo: undoSteps, redo: redoSteps))
            bytes = try ProjectFile.encoded(document, compact: true)
        }
        return (try mediaSnapshot.appending(to: bytes, current: current, retained: retained, byteLimit: byteLimit),
                sources.map { ($0.value, $0.key) })
    }

    static func decodeMulticamDocument(_ data: Data) throws -> (project: MulticamProject, mediaSnapshot: ProjectMediaSnapshot) {
        let document = try ProjectFile.decode(MulticamDocument.self, data: data, multicam: true)
        guard case .multicam(let project) = try document.document.project.migratingLegacyTiles() else {
            throw historyError("Expected a multicam timeline")
        }
        return (project, document.document.mediaSnapshot)
    }

    public static func decodeDocument(_ data: Data, limit: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], mediaSnapshot: ProjectMediaSnapshot) {
        try ProjectFile.decode(Document.self, data: data)
            .materialize(limit: limit, recordBudget: maximumMaterializedHistoryRecords)
    }

    public static func loadHistory(from url: URL, limit: Int) throws -> (undo: [CutHistoryState], redo: [CutHistoryState]) {
        let document = try loadDocument(from: url, limit: limit)
        return (document.undo, document.redo)
    }

    /// The timeline and its two history branches come from the same atomic file revision.
    public static func loadDocument(from url: URL, limit: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], mediaSnapshot: ProjectMediaSnapshot) {
        try loadDocument(from: url, limit: limit, recordBudget: maximumMaterializedHistoryRecords)
    }

    static func loadDocument(from url: URL, limit: Int, recordBudget: Int = maximumMaterializedHistoryRecords,
                             validatingDestination output: URL? = nil) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], mediaSnapshot: ProjectMediaSnapshot) {
        let document = try ProjectFile.read(Document.self, from: url)
        if let output { try CutProjectMedia(document).validateDestination(output, relativeTo: url) }
        return try document.materialize(limit: limit, recordBudget: recordBudget)
    }

    package static func loadEditorDocument(from url: URL, limit: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], media: CutProjectMedia) {
        let (document, revision) = try ProjectFile.readSnapshot(Document.self, from: url)
        return try document.editorSnapshot(limit: limit, diskRevision: revision)
    }

    package static func decodeEditorDocument(_ data: Data, limit: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], media: CutProjectMedia) {
        try ProjectFile.decode(Document.self, data: data).editorSnapshot(limit: limit, diskRevision: nil)
    }
}

private extension Document {
    func editorSnapshot(limit: Int, diskRevision: ProjectDiskRevision?) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], media: CutProjectMedia) {
        let states = try materialize(limit: limit, recordBudget: CutProject.maximumMaterializedHistoryRecords)
        return (states.project, states.undo, states.redo,
                try CutProjectMedia(self, diskRevision: diskRevision, migratedProject: states.project))
    }

    func materialize(limit: Int, recordBudget: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], mediaSnapshot: ProjectMediaSnapshot) {
        let migratedProject = try project.migratingLegacyTiles()
        guard let archive = history else { return (migratedProject, [], [], mediaSnapshot) }
        var budget = recordBudget
        var undo: [CutHistoryState] = []
        var redo: [CutHistoryState] = []
        try walkHistory(undo: archive.undo.count, redo: archive.redo.count, limit: limit) { backwards, distance in
            let step = backwards ? archive.undo[distance] : archive.redo[distance]
            let prior = (backwards ? undo.last : redo.last)?.project ?? project
            guard let next = try step.apply(to: prior, budget: &budget) else { return false }
            let state = CutHistoryState(action: step.action, origin: step.origin, project: next,
                                        bindingChanges: step.transcriptBindings ?? [])
            if backwards { undo.append(state) } else { redo.append(state) }
            return true
        }
        func migrated(_ entries: [CutHistoryState]) throws -> [CutHistoryState] {
            try entries.reversed().map { state in
                CutHistoryState(action: state.action, origin: state.origin, project: try state.project.migratingLegacyTiles(),
                                bindingChanges: state.bindingChanges)
            }
        }
        return try (migratedProject, migrated(undo), migrated(redo), mediaSnapshot)
    }
}

/// Visit candidates nearest first. A rejected step also excludes all farther
/// states on its branch, since they depend on it.
@discardableResult
private func walkHistory(undo: Int, redo: Int, limit: Int, keep: (Bool, Int) throws -> Bool) rethrows
    -> (undo: Int, redo: Int) {
    var u = 0
    var r = 0
    var uEnd = undo
    var rEnd = redo
    let limit = min(max(0, limit), CutProject.maximumHistorySteps)
    while u + r < limit && (u < uEnd || r < rEnd) {
        if u < uEnd && (r == rEnd || u <= r) {
            if try keep(true, u) { u += 1 } else { uEnd = u }
        } else {
            if try keep(false, r) { r += 1 } else { rEnd = r }
        }
    }
    return (u, r)
}

private struct Document: Codable {
    let project: CutProject
    let history: Archive?
    let mediaSnapshot: ProjectMediaSnapshot

    enum CodingKeys: String, CodingKey {
        case history
        case schemaVersion = "schema_version"
        case mediaSnapshot = "media_snapshot"
    }

    init(project: CutProject, history: Archive?) {
        self.project = project
        self.history = history
        mediaSnapshot = .empty
    }

    init(from decoder: Decoder) throws {
        try self.init(project: CutProject(from: decoder), decoder: decoder)
    }

    init(project: CutProject, decoder: Decoder) throws {
        self.project = project
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        history = values.contains(.history)
            ? try Archive(from: values.superDecoder(forKey: .history), version: version) : nil
        if values.contains(.mediaSnapshot) {
            guard version != 3 else {
                throw CutError(code: "invalid_cut_project", message: "Media snapshots require project schema version 4.")
            }
            mediaSnapshot = try values.decode(ProjectMediaSnapshot.self, forKey: .mediaSnapshot)
        } else {
            mediaSnapshot = .empty
        }
    }

    func encode(to encoder: Encoder) throws {
        // The writer appends the media snapshot after selecting the history budget.
        try project.encode(to: encoder, requiresExtendedStillSchema: project.requiresExtendedStillSchema
                           || history?.requiresExtendedStillSchema == true,
                           requiresTilesSchema: history?.requiresTilesSchema == true)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(history, forKey: .history)
    }
}

private struct MulticamDocument: Decodable {
    let project: MulticamProject
    let document: Document

    init(from decoder: Decoder) throws {
        project = try MulticamProject(from: decoder)
        document = try Document(project: .multicam(project), decoder: decoder)
    }
}

private struct Archive: Encodable {
    let undo: [Step]
    let redo: [Step]

    enum CodingKeys: String, CodingKey { case undo, redo }

    init(undo: [Step], redo: [Step]) {
        self.undo = undo
        self.redo = redo
    }

    var requiresExtendedStillSchema: Bool {
        undo.contains(where: \.requiresExtendedStillSchema) || redo.contains(where: \.requiresExtendedStillSchema)
    }

    var requiresTilesSchema: Bool {
        undo.contains(where: \.requiresTilesSchema) || redo.contains(where: \.requiresTilesSchema)
    }

    init(from decoder: Decoder, version: Int) throws {
        let legacy = version == 3
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_history")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A copy pair is only a few bytes of JSON but its decoded enum can be
        // as large as a clip. Inspect the array sizes before allocating deltas.
        // Each piece contributes at least one record to a reconstructed state.
        var remainingSteps = CutProject.maximumHistorySteps
        var remainingPieces = CutProject.maximumMaterializedHistoryRecords
        let listFields: [Step.CodingKeys] = [.angles, .audioSources, .switches, .mixLanes, .audioReplacements, .fixedAudio,
                                                .sequenceItems, .assemblyItems, .stillAssets, .stillReplacements,
                                                .programColorPolicy, .stillFormat, .stillSoundtrack, .transcriptAuthoring,
                                                .transcriptBindings, .sourceSelects, .groupTileLayouts, .speakerAngles]
        for key: CodingKeys in [.undo, .redo] where values.contains(key) {
            var steps = try values.nestedUnkeyedContainer(forKey: key)
            guard let count = steps.count, count <= remainingSteps else {
                throw historyError("Project history exceeds the \(CutProject.maximumHistorySteps)-step limit")
            }
            remainingSteps -= count
            while !steps.isAtEnd {
                let fields = try steps.nestedContainer(keyedBy: Step.CodingKeys.self)
                if legacy, fields.contains(.origin) {
                    throw historyError("History origin requires project schema version 4")
                }
                if legacy, fields.contains(.transcriptBindings) {
                    throw historyError("Transcript binding changes require project schema version 4")
                }
                if legacy, fields.contains(.participants) {
                    throw historyError("Participant history requires project schema version 4")
                }
                for field in listFields where fields.contains(field) {
                    var pieces = try fields.nestedUnkeyedContainer(forKey: field)
                    guard let count = pieces.count, count <= remainingPieces else {
                        throw historyError("Project history exceeds the stored-record limit")
                    }
                    remainingPieces -= count
                    if field == .stillReplacements || field == .angles {
                        let nestedKey = ProjectField(stringValue: field == .angles ? "additional_recordings" : "fragments")
                        while !pieces.isAtEnd {
                            let piece = try pieces.superDecoder()
                            if let fields = try? piece.container(keyedBy: ProjectField.self) {
                                if fields.contains(nestedKey) {
                                    let container = try fields.nestedUnkeyedContainer(forKey: nestedKey)
                                    guard let count = container.count, count <= remainingPieces else {
                                        throw historyError("Project history exceeds the stored-record limit")
                                    }
                                    remainingPieces -= count
                                }
                            }
                        }
                    }
                }
            }
        }
        func steps(_ key: CodingKeys) throws -> [Step] {
            var result = try values.decodeIfPresent([Step].self, forKey: key) ?? []
            if version < CutProject.schemaVersion, result.contains(where: \.requiresExtendedStillSchema) {
                throw historyError("These still history changes require project schema version \(CutProject.schemaVersion)")
            }
            if version < CutProject.tilesSchemaVersion, result.contains(where: \.requiresTilesSchema) {
                throw historyError("Tile changes require project schema version \(CutProject.tilesSchemaVersion)")
            }
            for step in result {
                if let timeline = step.timeline {
                    let count = timeline.historyRecordCount
                    guard count <= remainingPieces else {
                        throw historyError("Project history exceeds the stored-record limit")
                    }
                    remainingPieces -= count
                }
            }
            if legacy {
                for index in result.indices {
                    guard result[index].audio != .mix, result[index].mixLanes == nil,
                          result[index].audioReplacements == nil, result[index].fixedAudio == nil else {
                        throw historyError("Mix audio fields require project schema version 4")
                    }
                    result[index].legacy = true
                }
            }
            return result
        }
        undo = try steps(.undo)
        redo = try steps(.redo)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if !undo.isEmpty { try values.encode(undo, forKey: .undo) }
        if !redo.isEmpty { try values.encode(redo, forKey: .redo) }
    }
}

/// A literal record or a run borrowed from the previous state's array.
/// A long-distance reorder therefore only needs a handful of pairs of integers.
private enum Piece<Element: Codable>: Codable {
    case copy(Int, Int)
    case insert(Element)

    init(from decoder: Decoder) throws {
        if var indices = try? decoder.unkeyedContainer() {
            let start = try indices.decode(Int.self)
            let count = try indices.decode(Int.self)
            guard indices.isAtEnd, start >= 0, count > 0, count <= Int.max - start else { throw historyError("Invalid history copy range") }
            self = .copy(start, count)
        } else {
            self = .insert(try Element(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .copy(let start, let count):
            var values = encoder.unkeyedContainer()
            try values.encode(start)
            try values.encode(count)
        case .insert(let element): try element.encode(to: encoder)
        }
    }
}

private struct ListDelta<Element: Codable & Hashable>: Codable {
    let pieces: [Piece<Element>]

    init?(from source: [Element], to target: [Element]) {
        guard source != target else { return nil }
        // Prefer continuing an existing run, including when assembly ranges repeat.
        var positions: [Element: [Int]] = [:]
        for i in source.indices.reversed() { positions[source[i], default: []].append(i) }
        var used = IndexSet()
        var result: [Piece<Element>] = []
        var nextIndex = 0
        for item in target {
            var match: Int?
            if nextIndex < source.count && source[nextIndex] == item && !used.contains(nextIndex) {
                match = nextIndex
            } else {
                while let i = positions[item]?.popLast() {
                    if !used.contains(i) { match = i; break }
                }
            }
            if let i = match {
                if case let .copy(start, count)? = result.last, start + count == i {
                    result[result.count - 1] = .copy(start, count + 1)
                } else { result.append(.copy(i, 1)) }
                used.insert(i)
                nextIndex = i + 1
            } else { result.append(.insert(item)) }
        }
        pieces = result
    }

    init(from decoder: Decoder) throws { pieces = try [Piece<Element>](from: decoder) }
    func encode(to encoder: Encoder) throws { try pieces.encode(to: encoder) }

    func count(appliedTo sourceCount: Int) throws -> Int {
        var total = 0
        var used = IndexSet()
        for piece in pieces {
            let add: Int
            switch piece {
            case .copy(let start, let length):
                guard start <= sourceCount, length <= sourceCount - start else {
                    throw historyError("History copy range extends beyond its source")
                }
                let range = start..<(start + length)
                guard !used.intersects(integersIn: range) else { throw historyError("Overlapping history copy ranges") }
                used.insert(integersIn: range)
                add = length
            case .insert: add = 1
            }
            guard add <= Int.max - total else { throw historyError("History array size overflow") }
            total += add
        }
        return total
    }

    func apply(to source: [Element]) -> [Element] {
        // The reader validated all copy ranges before charging this array against its budget.
        var result: [Element] = []
        for piece in pieces {
            switch piece {
            case .insert(let item): result.append(item)
            case .copy(let start, let count):
                let range = start..<(start + count)
                result.append(contentsOf: source[range])
            }
        }
        return result
    }
}

extension ListDelta where Element == StillSequenceItem {
    fileprivate func applyToClips(_ source: [CutSequenceClip], count: Int) throws -> [CutSequenceClip]? {
        // Copied clips came from a validated document. Their fields are unchanged,
        // but an insertion or reorder can still duplicate an ID or overflow the total duration.
        var result: [CutSequenceClip] = []
        var order = SequenceClipOrderValidation()
        result.reserveCapacity(count)
        for piece in pieces {
            switch piece {
            case .copy(let start, let length):
                let clips = source[start..<(start + length)]
                for clip in clips { try order.append(clip) }
                result.append(contentsOf: clips)
            case .insert(.source(let clip)):
                try clip.validateFields()
                try order.append(clip)
                result.append(clip)
            case .insert(.still):
                return nil
            }
        }
        return result
    }
}

private struct Step: Codable {
    var action: String
    var origin: HistoryOrigin
    var timeline: CutProject?
    var referenceAngle: String?
    var range: MulticamRange?
    var audio: MulticamAudioPolicy?
    var angles: ListDelta<MulticamSource>?
    var audioSources: ListDelta<MulticamSource>?
    var mixLanes: ListDelta<MulticamAudioLane>?
    var audioReplacements: ListDelta<MulticamAudioReplacement>?
    var fixedAudio: ListDelta<MulticamAudioSelection>?
    var legacy = false
    var switches: ListDelta<MulticamSwitch>?
    var sequenceItems: ListDelta<StillSequenceItem>?
    var assemblyItems: ListDelta<StillAssemblyItem>?
    var groupTileLayouts: ListDelta<TileLayoutSpan>?
    var speakerAngles: ListDelta<TileSpeakerAngle>?
    var stillAssets: ListDelta<StillAsset>?
    var stillReplacements: ListDelta<StillReplacement>?
    var programColorPolicy: ListDelta<StillProgramColorPolicy>?
    var stillFormat: ListDelta<StillTimelineFormat>?
    var stillSoundtrack: ListDelta<CutSequenceClip>?
    var requiresExtendedStillSchema: Bool {
        stillSoundtrack != nil || sequenceItems?.pieces.contains { piece in
            if case .insert(let item) = piece { return item.still?.usesExactDuration == true }
            return false
        } == true || stillFormat?.pieces.contains { piece in
            if case .insert(let format) = piece { return format.requiresExtendedStillSchema }
            return false
        } == true
    }
    var requiresTilesSchema: Bool {
        if timeline != nil || groupTileLayouts != nil || speakerAngles != nil { return true }
        if let participants, CutProject.stillSequence(.init(items: [], participants: participants)).usesTilesFormat { return true }
        if angles?.pieces.contains(where: {
            if case .insert(let angle) = $0 { return angle.feedAngle != nil }
            return false
        }) == true { return true }
        if assemblyItems?.pieces.contains(where: {
            if case .insert(let item) = $0 { return item.occurrenceID != nil || !item.tileLayouts.isEmpty }
            return false
        }) == true { return true }
        if stillSoundtrack?.pieces.contains(where: {
            if case .insert(let clip) = $0 { return !clip.tileLayouts.isEmpty }
            return false
        }) == true { return true }
        return sequenceItems?.pieces.contains {
            if case .insert(.source(let clip)) = $0 { return !clip.tileLayouts.isEmpty }
            return false
        } == true
    }

    var transcriptAuthoring: ListDelta<TranscriptAuthoredRecord>?
    var transcriptBindings: [TranscriptBindingChange]?
    var sourceSelects: ListDelta<NamedSourceSelect>?
    var participants: ParticipantProject?

    var changesTimelineItems: Bool {
        sequenceItems != nil || assemblyItems != nil || stillAssets != nil || stillReplacements != nil
            || programColorPolicy != nil || stillFormat != nil || stillSoundtrack != nil
            || groupTileLayouts != nil
    }

    enum CodingKeys: String, CodingKey {
        case action, origin, timeline
        case referenceAngle = "reference_angle_id"
        case range = "group_range"
        case audio, angles
        case audioSources = "audio_sources"
        case mixLanes = "mix_lanes"
        case audioReplacements = "audio_replacements"
        case fixedAudio = "fixed_audio"
        case switches
        case sequenceItems = "clips"
        case assemblyItems = "assembly"
        case groupTileLayouts = "group_tile_layouts"
        case speakerAngles = "speaker_angles"
        case stillAssets = "still_assets"
        case stillReplacements = "still_replacements"
        case programColorPolicy = "program_color_policy"
        case stillFormat = "still_format"
        case stillSoundtrack = "still_soundtrack"
        case transcriptAuthoring = "transcript_authoring"
        case transcriptBindings = "transcript_bindings"
        case sourceSelects = "source_selects"
        case participants
    }

    init(action: String, origin: HistoryOrigin, from: CutProject, to: CutProject,
         bindingChanges: [TranscriptBindingChange]? = nil) throws {
        self.action = action
        self.origin = origin
        try validateAction()
        let changes = bindingChanges ?? TranscriptBindingChange.changes(from: from.transcripts, to: to.transcripts)
        let effectiveChanges = changes.filter { $0.before != $0.after }
        guard Set(effectiveChanges.map(\.key)).count == effectiveChanges.count else {
            throw historyError("Repeated transcript binding change")
        }
        for change in effectiveChanges { try change.validate() }
        transcriptBindings = effectiveChanges.isEmpty ? nil : effectiveChanges
        switch (from, to) {
        case (.sequence, .sequence), (.sequence, .stillSequence), (.stillSequence, .sequence), (.stillSequence, .stillSequence):
            sourceSelects = ListDelta(from: from.sourceSelects, to: to.sourceSelects)
            sequenceItems = ListDelta(from: from.sequenceItems ?? [], to: to.sequenceItems ?? [])
            stillFormat = ListDelta(from: [from.stillFormat].compactMap { $0 }, to: [to.stillFormat].compactMap { $0 })
            stillSoundtrack = ListDelta(from: [from.stillSoundtrack].compactMap { $0 },
                                        to: [to.stillSoundtrack].compactMap { $0 })
        case (.multicam(let old), .multicam(let new)):
            if old.referenceAngle != new.referenceAngle { referenceAngle = new.referenceAngle }
            if old.range != new.range { range = new.range }
            if old.audio != new.audio { audio = new.audio }
            angles = ListDelta(from: old.angles, to: new.angles)
            audioSources = ListDelta(from: old.audioSources, to: new.audioSources)
            mixLanes = ListDelta(from: old.mixLanes, to: new.mixLanes)
            audioReplacements = ListDelta(from: old.audioReplacements, to: new.audioReplacements)
            fixedAudio = ListDelta(from: [old.fixedAudio].compactMap { $0 }, to: [new.fixedAudio].compactMap { $0 })
            switches = ListDelta(from: old.switches, to: new.switches)
            assemblyItems = ListDelta(from: old.assemblyItems ?? [], to: new.assemblyItems ?? [])
            groupTileLayouts = ListDelta(from: old.groupTileLayouts, to: new.groupTileLayouts)
            speakerAngles = ListDelta(from: old.speakerAngles, to: new.speakerAngles)
        default:
            // A conversion replaces the timeline. Keep transcript assets in
            // the current document and store only the historical authorship.
            var timeline = to
            timeline.transcripts = ProjectTranscripts(authoring: to.transcripts.authoring)
            self.timeline = timeline
            return
        }
        if from.participants != to.participants { participants = to.participants }
        transcriptAuthoring = ListDelta(from: from.transcripts.authoring, to: to.transcripts.authoring)
        stillAssets = ListDelta(from: from.stillAssets, to: to.stillAssets)
        stillReplacements = ListDelta(from: from.stillReplacements, to: to.stillReplacements)
        programColorPolicy = ListDelta(from: [from.programColorPolicy].compactMap { $0 },
                                       to: [to.programColorPolicy].compactMap { $0 })
    }

    init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_history")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decode(String.self, forKey: .action)
        origin = try values.decodeIfPresent(HistoryOrigin.self, forKey: .origin) ?? .unknown
        for key in values.allKeys where try values.decodeNil(forKey: key) {
            throw historyError("Null value in history field ‘\(key.stringValue)’")
        }
        timeline = try values.decodeIfPresent(CutProject.self, forKey: .timeline)
        if let timeline {
            guard values.allKeys.allSatisfy({ [.action, .origin, .timeline, .transcriptBindings].contains($0) }),
                  timeline.transcripts == ProjectTranscripts(authoring: timeline.transcripts.authoring) else {
                throw historyError("Timeline conversion cannot include project deltas or transcript assets")
            }
        }
        referenceAngle = try values.decodeIfPresent(String.self, forKey: .referenceAngle)
        range = try values.decodeIfPresent(MulticamRange.self, forKey: .range)
        audio = try values.decodeIfPresent(MulticamAudioPolicy.self, forKey: .audio)
        angles = try values.decodeIfPresent(ListDelta<MulticamSource>.self, forKey: .angles)
        audioSources = try values.decodeIfPresent(ListDelta<MulticamSource>.self, forKey: .audioSources)
        mixLanes = try values.decodeIfPresent(ListDelta<MulticamAudioLane>.self, forKey: .mixLanes)
        audioReplacements = try values.decodeIfPresent(ListDelta<MulticamAudioReplacement>.self, forKey: .audioReplacements)
        fixedAudio = try values.decodeIfPresent(ListDelta<MulticamAudioSelection>.self, forKey: .fixedAudio)
        switches = try values.decodeIfPresent(ListDelta<MulticamSwitch>.self, forKey: .switches)
        sequenceItems = try values.decodeIfPresent(ListDelta<StillSequenceItem>.self, forKey: .sequenceItems)
        assemblyItems = try values.decodeIfPresent(ListDelta<StillAssemblyItem>.self, forKey: .assemblyItems)
        groupTileLayouts = try values.decodeIfPresent(ListDelta<TileLayoutSpan>.self, forKey: .groupTileLayouts)
        speakerAngles = try values.decodeIfPresent(ListDelta<TileSpeakerAngle>.self, forKey: .speakerAngles)
        stillAssets = try values.decodeIfPresent(ListDelta<StillAsset>.self, forKey: .stillAssets)
        stillReplacements = try values.decodeIfPresent(ListDelta<StillReplacement>.self, forKey: .stillReplacements)
        programColorPolicy = try values.decodeIfPresent(ListDelta<StillProgramColorPolicy>.self, forKey: .programColorPolicy)
        stillFormat = try values.decodeIfPresent(ListDelta<StillTimelineFormat>.self, forKey: .stillFormat)
        stillSoundtrack = try values.decodeIfPresent(ListDelta<CutSequenceClip>.self, forKey: .stillSoundtrack)
        transcriptAuthoring = try values.decodeIfPresent(ListDelta<TranscriptAuthoredRecord>.self, forKey: .transcriptAuthoring)
        transcriptBindings = try values.decodeIfPresent([TranscriptBindingChange].self, forKey: .transcriptBindings)
        if let transcriptBindings, Set(transcriptBindings.map(\.key)).count != transcriptBindings.count {
            throw historyError("Repeated transcript binding change")
        }
        sourceSelects = try values.decodeIfPresent(ListDelta<NamedSourceSelect>.self, forKey: .sourceSelects)
        participants = try values.decodeIfPresent(ParticipantProject.self, forKey: .participants)
        try validateAction()
    }

    private func validateAction() throws {
        guard action.unicodeScalars.count <= 1024, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw historyError("History actions must have a nonblank name of at most 1024 Unicode code points")
        }
    }

    func bindingRecordCount(in transcripts: ProjectTranscripts) -> Int {
        guard let transcriptBindings else { return 0 }
        return transcripts.attachmentRecordCount + transcriptBindings.count
    }

    /// Charge even unchanged records: a consumer can rebase paths in each snapshot
    /// (e.g. while opening it or saving in another folder) and allocate new arrays.
    private func recordCount(appliedTo source: CutProject) throws -> Int {
        let assets = try stillAssets?.count(appliedTo: source.stillAssets.count) ?? source.stillAssets.count
        let placements = try stillReplacements?.count(appliedTo: source.stillReplacements.count) ?? source.stillReplacements.count
        let oldColor = source.programColorPolicy == nil ? 0 : 1
        let oldFormat = source.stillFormat == nil ? 0 : 1
        let color = try programColorPolicy?.count(appliedTo: oldColor) ?? oldColor
        let format = try stillFormat?.count(appliedTo: oldFormat) ?? oldFormat
        let oldSoundtrack = source.stillSoundtrack == nil ? 0 : 1
        let soundtrack = try stillSoundtrack?.count(appliedTo: oldSoundtrack) ?? oldSoundtrack
        guard color <= 1, format <= 1, soundtrack <= 1 else { throw historyError("Repeated still project policy") }
        let authored = source.transcripts.authoring.count
        let records = try transcriptAuthoring?.count(appliedTo: authored) ?? authored
        let bindingRecords = bindingRecordCount(in: source.transcripts)
        let stillRecords = assets + placements + color + format + soundtrack + records + bindingRecords
            + (participants ?? source.participants).historyRecordCount
        switch source {
        case .sequence, .stillSequence:
            guard referenceAngle == nil, range == nil, audio == nil, angles == nil,
                  audioSources == nil, switches == nil, assemblyItems == nil,
                  mixLanes == nil, audioReplacements == nil, fixedAudio == nil,
                  groupTileLayouts == nil, speakerAngles == nil else {
                throw historyError("Multicam field in sequence history")
            }
            let count: Int
            if case .sequence(let clips) = source {
                count = clips.count
            } else if case .stillSequence(let sequence) = source {
                count = sequence.items.count
            } else {
                preconditionFailure("Unhandled sequence project kind")
            }
            let selects = try sourceSelects?.count(appliedTo: source.sourceSelects.count) ?? source.sourceSelects.count
            return (try sequenceItems?.count(appliedTo: count) ?? count) + stillRecords + selects
        case .multicam(let old):
            guard sequenceItems == nil, stillFormat == nil, stillSoundtrack == nil, sourceSelects == nil else { throw historyError("Sequence field in multicam history") }
            let angles = try angles?.count(appliedTo: old.angles.count) ?? old.angles.count
            let audioSourceCount = try audioSources?.count(appliedTo: old.audioSources.count) ?? old.audioSources.count
            let switches = try switches?.count(appliedTo: old.switches.count) ?? old.switches.count
            let ranges = old.assemblyItems?.count ?? 0
            let assembly = try assemblyItems?.count(appliedTo: ranges) ?? ranges
            let lanes = try mixLanes?.count(appliedTo: old.mixLanes.count) ?? old.mixLanes.count
            let bindings = try audioReplacements?.count(appliedTo: old.audioReplacements.count) ?? old.audioReplacements.count
            let layouts = try groupTileLayouts?.count(appliedTo: old.groupTileLayouts.count) ?? old.groupTileLayouts.count
            let links = try speakerAngles?.count(appliedTo: old.speakerAngles.count) ?? old.speakerAngles.count
            let oldFixed = old.fixedAudio == nil ? 0 : 1
            let fixed: Int
            if let fixedAudio { fixed = try fixedAudio.count(appliedTo: oldFixed) }
            else if case .fixed = audio { fixed = 1 }
            else if legacy, audio != nil { fixed = 0 }
            else { fixed = oldFixed }
            guard fixed <= 1 else { throw historyError("Repeated Fixed audio selection") }
            return angles + audioSourceCount + switches + assembly + lanes + bindings + fixed + layouts + links + stillRecords
        }
    }

    func apply(to source: CutProject, budget: inout Int) throws -> CutProject? {
        if var timeline {
            guard timeline.timelineOutputClock != source.timelineOutputClock else {
                throw historyError("A history conversion must change the timeline kind")
            }
            let records = timeline.historyRecordCount + bindingRecordCount(in: source.transcripts)
            guard records <= budget else { return nil }
            budget -= records
            var transcripts = source.transcripts
            transcripts.authoring = timeline.transcripts.authoring
            applyBindings(to: &transcripts)
            timeline.transcripts = transcripts
            try timeline.validate()
            return timeline
        }
        let records = try recordCount(appliedTo: source)
        guard records <= budget else { return nil }
        let assets = stillAssets?.apply(to: source.stillAssets) ?? source.stillAssets
        let replacements = stillReplacements?.apply(to: source.stillReplacements) ?? source.stillReplacements
        let fragments = replacements.reduce(0) { count, placement in
            if case .sequence(let fragments) = placement.coverage { return count + fragments.count }
            return count
        }
        var extraRecords = fragments
        var resultingAngles: [MulticamSource]?
        if case .multicam(let project) = source {
            let cameras = angles?.apply(to: project.angles) ?? project.angles
            extraRecords += cameras.reduce(0) { $0 + $1.additionalRecordings.count }
            resultingAngles = cameras
        }
        guard extraRecords <= budget - records else { return nil }
        budget -= records + extraRecords
        if !changesTimelineItems && referenceAngle == nil && range == nil && audio == nil && angles == nil
            && audioSources == nil && switches == nil && transcriptAuthoring == nil && transcriptBindings == nil && sourceSelects == nil
            && mixLanes == nil && audioReplacements == nil && fixedAudio == nil && participants == nil
            && speakerAngles == nil { return source }
        if case .sequence(let clips) = source, let sequenceItems,
           stillAssets == nil, stillReplacements == nil, programColorPolicy == nil, stillFormat == nil, stillSoundtrack == nil,
           transcriptAuthoring == nil, transcriptBindings == nil, sourceSelects == nil, participants == nil,
           let updatedClips = try sequenceItems.applyToClips(clips, count: records) {
            return .sequence(updatedClips)
        }
        let oldColor = [source.programColorPolicy].compactMap { $0 }
        let color = (programColorPolicy?.apply(to: oldColor) ?? oldColor).first
        var result: CutProject
        switch source {
        case .sequence, .stillSequence:
            var project = source.stillSequenceValue!
            if let sequenceItems { project.items = sequenceItems.apply(to: project.items) }
            project.stillAssets = assets
            project.stillReplacements = replacements
            project.programColorPolicy = color
            if let stillFormat { project.stillFormat = stillFormat.apply(to: [project.stillFormat].compactMap { $0 }).first }
            if let stillSoundtrack { project.stillSoundtrack = stillSoundtrack.apply(to: [project.stillSoundtrack].compactMap { $0 }).first }
            if let sourceSelects { project.sourceSelects = sourceSelects.apply(to: project.sourceSelects) }
            result = project.hasStillContent || !project.sourceSelects.isEmpty || !project.participants.isEmpty ? .stillSequence(project) : .sequence(project.items.compactMap(\.source))
        case .multicam(var project):
            if let referenceAngle { project.referenceAngle = referenceAngle }
            if let range { project.range = range }
            let previousFixed = [project.fixedAudio].compactMap { $0 }
            if let audio {
                project.audio = audio
                // A v3 project only stored the selection in states where Fixed was active.
                if legacy {
                    switch audio {
                    case .fixed: break
                    case .follow, .none, .mix: project.fixedAudio = nil
                    }
                }
            }
            if let fixedAudio { project.fixedAudio = fixedAudio.apply(to: previousFixed).first }
            if let mixLanes { project.mixLanes = mixLanes.apply(to: project.mixLanes) }
            if let audioReplacements { project.audioReplacements = audioReplacements.apply(to: project.audioReplacements) }
            if let resultingAngles { project.angles = resultingAngles }
            if let audioSources { project.audioSources = audioSources.apply(to: project.audioSources) }
            if let switches { project.switches = switches.apply(to: project.switches) }
            if let groupTileLayouts { project.groupTileLayouts = groupTileLayouts.apply(to: project.groupTileLayouts) }
            if let speakerAngles { project.speakerAngles = speakerAngles.apply(to: project.speakerAngles) }
            if let assemblyItems {
                let items = assemblyItems.apply(to: project.assemblyItems ?? [])
                project.assemblyItems = items.isEmpty ? nil : items
            }
            project.stillAssets = assets
            project.stillReplacements = replacements
            project.programColorPolicy = color
            project.syncFeedAngleRecordings()
            result = .multicam(project)
        }
        var transcripts = source.transcripts
        if let transcriptAuthoring { transcripts.authoring = transcriptAuthoring.apply(to: transcripts.authoring) }
        applyBindings(to: &transcripts)
        result.transcripts = transcripts
        if let participants { result.participants = participants }
        try result.validate()
        return result
    }

    private func applyBindings(to transcripts: inout ProjectTranscripts) {
        if let transcriptBindings, TranscriptBindingChange.apply(transcriptBindings, to: &transcripts),
           transcripts.revision < UInt64.max {
            transcripts.revision += 1
        }
    }
}
