import Foundation

/// The destination state and the name of the action traversed to reach it.
public struct CutHistoryState: Equatable, Sendable {
    public let action: String
    public let project: CutProject

    public init(action: String, project: CutProject) {
        self.action = action
        self.project = project
    }
}

/// Media that must remain available to an edit, including only-in-history recordings.
package struct CutProjectMedia {
    package let project: CutProject
    private let paths: [String: String]

    fileprivate init(_ document: Document) {
        project = document.project
        var paths = Dictionary(project.mediaPaths.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        // Every history reference originates in the current timeline or a literal.
        // Copy runs never introduce a path, even beyond the editor's retention budget.
        for branch in [document.history?.undo ?? [], document.history?.redo ?? []] {
            for step in branch {
                for case .insert(let clip) in step.clips?.pieces ?? [] {
                    paths[clip.file] = clip.id
                    if let original = clip.originalFile { paths[original] = clip.id }
                }
                for delta in [step.angles, step.audioSources] {
                    for case .insert(let source) in delta?.pieces ?? [] { paths[source.file] = source.id }
                }
            }
        }
        self.paths = paths
    }

    package func absoluteSources(relativeTo url: URL) -> [String: String] {
        let directory = ProjectFile.directory(of: url)
        var result: [String: String] = [:]
        for (path, id) in paths { result[ProjectFile.sourceURL(file: path, in: directory).path] = id }
        return result
    }

    package func sidecarExclusions(relativeTo url: URL) -> Set<URL> {
        let directory = ProjectFile.directory(of: url)
        let candidates = Set(project.mediaPaths.map(\.1)).map { ProjectFile.sourceURL(file: $0, in: directory) }
        return CutProject.sidecarExclusions(absoluteSources: absoluteSources(relativeTo: url), candidates: candidates)
    }

    package static func load(from url: URL, multicam: Bool = false) throws -> Self {
        if multicam {
            return try Self(ProjectFile.read(MulticamDocument.self, from: url, multicam: true).document)
        }
        return try Self(ProjectFile.read(Document.self, from: url))
    }

    package static func decode(_ data: Data) throws -> Self {
        try Self(ProjectFile.decode(Document.self, data: data))
    }

    package func validateDestination(_ output: URL, relativeTo projectURL: URL, includesContents: Bool = false) throws {
        try validateDestination(output, sourceDirectory: ProjectFile.directory(of: projectURL), includesContents: includesContents)
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

    private var historyRecordCount: Int {
        switch self {
        case .sequence(let clips): return clips.count
        case .multicam(let p):
            return p.angles.count + p.audioSources.count + p.switches.count + (p.assembly?.count ?? 0)
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
    public func save(to url: URL, undo: [CutHistoryState], redo: [CutHistoryState], replacingExisting: Bool = true) throws {
        try save(to: url, undo: undo, redo: redo, byteLimit: MulticamProject.maximumFileSize, replacingExisting: replacingExisting)
    }

    func save(to url: URL, undo: [CutHistoryState], redo: [CutHistoryState], byteLimit: Int, replacingExisting: Bool = true) throws {
        guard !undo.isEmpty || !redo.isEmpty else {
            return try ProjectFile.write(self, to: url, sources: mediaPaths, replacingExisting: replacingExisting)
        }
        // Measure individual deltas before creating the complete archive, so an
        // edit that pastes a large timeline repeatedly cannot allocate many
        // times the file-size cap in a speculative JSONEncoder buffer.
        let base = try ProjectFile.encoded(self, compact: true)
        var byteBudget = byteLimit - base.count - 32 // both empty branch headers
        var recordBudget = Self.maximumMaterializedHistoryRecords
        var sources = Dictionary(mediaPaths.map { ($0.1, $0.0) }, uniquingKeysWith: { id, _ in id })
        // Even a state pruned from the file can still be reached in the editor.
        // Saving must never replace a recording that only that state references.
        for stack in [undo, redo] {
            for state in stack {
                for (id, file) in state.project.mediaPaths { sources[file] = id }
            }
        }
        var previousUndo = self
        var previousRedo = self
        var undoSteps: [Step] = []
        var redoSteps: [Step] = []
        try walkHistory(undo: undo.count, redo: redo.count, limit: Self.maximumHistorySteps) { backwards, distance in
            let state = backwards ? undo[undo.count - 1 - distance] : redo[redo.count - 1 - distance]
            let records = state.project.historyRecordCount
            guard records <= recordBudget else { return false }
            try state.project.validate()
            let step = try Step(action: state.action, from: backwards ? previousUndo : previousRedo, to: state.project)
            let size = try ProjectFile.encoded(step, compact: true).count + 1 // element separator
            guard size <= byteBudget else { return false }
            byteBudget -= size
            recordBudget -= records
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
        try ProjectFile.write(bytes, to: url, sources: sources.map { ($0.value, $0.key) }, prefix: "cut", replacingExisting: replacingExisting)
    }

    public static func loadHistory(from url: URL, limit: Int) throws -> (undo: [CutHistoryState], redo: [CutHistoryState]) {
        let document = try loadDocument(from: url, limit: limit)
        return (document.undo, document.redo)
    }

    /// The timeline and its two history branches come from the same atomic file revision.
    public static func loadDocument(from url: URL, limit: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState]) {
        try loadDocument(from: url, limit: limit, recordBudget: maximumMaterializedHistoryRecords)
    }

    static func loadDocument(from url: URL, limit: Int, recordBudget: Int = maximumMaterializedHistoryRecords,
                             validatingDestination output: URL? = nil) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState]) {
        let document = try ProjectFile.read(Document.self, from: url)
        if let output { try CutProjectMedia(document).validateDestination(output, relativeTo: url) }
        return try document.materialize(limit: limit, recordBudget: recordBudget)
    }

    package static func loadEditorDocument(from url: URL, limit: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState], media: CutProjectMedia) {
        let document = try ProjectFile.read(Document.self, from: url)
        let states = try document.materialize(limit: limit, recordBudget: maximumMaterializedHistoryRecords)
        return (states.project, states.undo, states.redo, CutProjectMedia(document))
    }
}

private extension Document {
    func materialize(limit: Int, recordBudget: Int) throws
        -> (project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState]) {
        guard let archive = history else { return (project, [], []) }
        var budget = recordBudget
        var undo: [CutHistoryState] = []
        var redo: [CutHistoryState] = []
        try walkHistory(undo: archive.undo.count, redo: archive.redo.count, limit: limit) { backwards, distance in
            let step = backwards ? archive.undo[distance] : archive.redo[distance]
            let prior = (backwards ? undo.last : redo.last)?.project ?? project
            guard let next = try step.apply(to: prior, budget: &budget) else { return false }
            let state = CutHistoryState(action: step.action, project: next)
            if backwards { undo.append(state) } else { redo.append(state) }
            return true
        }
        return (project, undo.reversed(), redo.reversed())
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

    enum CodingKeys: String, CodingKey { case history }

    init(project: CutProject, history: Archive?) {
        self.project = project
        self.history = history
    }

    init(from decoder: Decoder) throws {
        try self.init(project: CutProject(from: decoder), decoder: decoder)
    }

    init(project: CutProject, decoder: Decoder) throws {
        self.project = project
        let values = try decoder.container(keyedBy: CodingKeys.self)
        history = values.contains(.history) ? try values.decode(Archive.self, forKey: .history) : nil
    }

    func encode(to encoder: Encoder) throws {
        try project.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(history, forKey: .history)
    }
}

private struct MulticamDocument: Decodable {
    let document: Document

    init(from decoder: Decoder) throws {
        document = try Document(project: .multicam(MulticamProject(from: decoder)), decoder: decoder)
    }
}

private struct Archive: Codable {
    let undo: [Step]
    let redo: [Step]
    enum CodingKeys: String, CodingKey { case undo, redo }

    init(undo: [Step], redo: [Step]) {
        self.undo = undo
        self.redo = redo
    }

    init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_history")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A copy pair is only a few bytes of JSON but its decoded enum can be
        // as large as a clip. Inspect the array sizes before allocating deltas.
        // Each piece contributes at least one record to a reconstructed state.
        var remainingSteps = CutProject.maximumHistorySteps
        var remainingPieces = CutProject.maximumMaterializedHistoryRecords
        let listFields: [Step.CodingKeys] = [.clips, .angles, .audioSources, .switches, .assembly]
        for key: CodingKeys in [.undo, .redo] where values.contains(key) {
            var steps = try values.nestedUnkeyedContainer(forKey: key)
            guard let count = steps.count, count <= remainingSteps else {
                throw historyError("Project history exceeds the \(CutProject.maximumHistorySteps)-step limit")
            }
            remainingSteps -= count
            while !steps.isAtEnd {
                let fields = try steps.nestedContainer(keyedBy: Step.CodingKeys.self)
                for field in listFields where fields.contains(field) {
                    let pieces = try fields.nestedUnkeyedContainer(forKey: field)
                    guard let count = pieces.count, count <= remainingPieces else {
                        throw historyError("Project history exceeds the stored-record limit")
                    }
                    remainingPieces -= count
                }
            }
        }
        undo = try values.decodeIfPresent([Step].self, forKey: .undo) ?? []
        redo = try values.decodeIfPresent([Step].self, forKey: .redo) ?? []
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

private struct Step: Codable {
    var action: String
    var clips: ListDelta<CutSequenceClip>?
    var referenceAngle: String?
    var range: MulticamRange?
    var audio: MulticamAudioPolicy?
    var angles: ListDelta<MulticamSource>?
    var audioSources: ListDelta<MulticamSource>?
    var switches: ListDelta<MulticamSwitch>?
    var assembly: ListDelta<MulticamRange>?

    enum CodingKeys: String, CodingKey {
        case action, clips, referenceAngle, range, audio, angles, audioSources, switches, assembly
    }

    init(action: String, from: CutProject, to: CutProject) throws {
        self.action = action
        try validateAction()
        switch (from, to) {
        case (.sequence(let old), .sequence(let new)): clips = ListDelta(from: old, to: new)
        case (.multicam(let old), .multicam(let new)):
            if old.referenceAngle != new.referenceAngle { referenceAngle = new.referenceAngle }
            if old.range != new.range { range = new.range }
            if old.audio != new.audio { audio = new.audio }
            angles = ListDelta(from: old.angles, to: new.angles)
            audioSources = ListDelta(from: old.audioSources, to: new.audioSources)
            switches = ListDelta(from: old.switches, to: new.switches)
            assembly = ListDelta(from: old.assembly ?? [], to: new.assembly ?? [])
        default: throw historyError("History states must have the same timeline kind")
        }
    }

    init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_history")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decode(String.self, forKey: .action)
        for key in values.allKeys where try values.decodeNil(forKey: key) {
            throw historyError("Null value in history field ‘\(key.stringValue)’")
        }
        clips = try values.decodeIfPresent(ListDelta<CutSequenceClip>.self, forKey: .clips)
        referenceAngle = try values.decodeIfPresent(String.self, forKey: .referenceAngle)
        range = try values.decodeIfPresent(MulticamRange.self, forKey: .range)
        audio = try values.decodeIfPresent(MulticamAudioPolicy.self, forKey: .audio)
        angles = try values.decodeIfPresent(ListDelta<MulticamSource>.self, forKey: .angles)
        audioSources = try values.decodeIfPresent(ListDelta<MulticamSource>.self, forKey: .audioSources)
        switches = try values.decodeIfPresent(ListDelta<MulticamSwitch>.self, forKey: .switches)
        assembly = try values.decodeIfPresent(ListDelta<MulticamRange>.self, forKey: .assembly)
        try validateAction()
    }

    private func validateAction() throws {
        guard action.unicodeScalars.count <= 1024, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw historyError("History actions must have a nonblank name of at most 1024 Unicode code points")
        }
    }

    /// Charge even unchanged records: a consumer can rebase paths in each snapshot
    /// (e.g. while opening it or saving in another folder) and allocate new arrays.
    private func recordCount(appliedTo source: CutProject) throws -> Int {
        switch source {
        case .sequence(let old):
            guard referenceAngle == nil, range == nil, audio == nil, angles == nil,
                  audioSources == nil, switches == nil, assembly == nil else {
                throw historyError("Multicam field in sequence history")
            }
            return try clips?.count(appliedTo: old.count) ?? old.count
        case .multicam(let old):
            guard clips == nil else { throw historyError("Sequence clips in multicam history") }
            let angles = try angles?.count(appliedTo: old.angles.count) ?? old.angles.count
            let audio = try audioSources?.count(appliedTo: old.audioSources.count) ?? old.audioSources.count
            let switches = try switches?.count(appliedTo: old.switches.count) ?? old.switches.count
            let ranges = old.assembly?.count ?? 0
            let assembly = try assembly?.count(appliedTo: ranges) ?? ranges
            return angles + audio + switches + assembly
        }
    }

    func apply(to source: CutProject, budget: inout Int) throws -> CutProject? {
        let records = try recordCount(appliedTo: source)
        guard records <= budget else { return nil }
        budget -= records
        if clips == nil && referenceAngle == nil && range == nil && audio == nil && angles == nil
            && audioSources == nil && switches == nil && assembly == nil { return source }
        let result: CutProject
        switch source {
        case .sequence(let old):
            result = .sequence(clips?.apply(to: old) ?? old)
        case .multicam(var project):
            if let referenceAngle { project.referenceAngle = referenceAngle }
            if let range { project.range = range }
            if let audio { project.audio = audio }
            if let angles { project.angles = angles.apply(to: project.angles) }
            if let audioSources { project.audioSources = audioSources.apply(to: project.audioSources) }
            if let switches { project.switches = switches.apply(to: project.switches) }
            if let assembly {
                let ranges = assembly.apply(to: project.assembly ?? [])
                project.assembly = ranges.isEmpty ? nil : ranges
            }
            result = .multicam(project)
        }
        try result.validate()
        return result
    }
}
