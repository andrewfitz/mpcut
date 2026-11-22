import AppKit
import Combine
import Foundation
import MPCutCore
import UniformTypeIdentifiers

private struct IndexedSource: Sendable {
    let id: UUID
    let media: MediaInfo
    let originalURL: URL
    let replacementNames: [Int: String]
    let replacementTrack: Int?
    let frames: [RationalTime]
    let keyframes: [RationalTime]
    let frameBoundaries: [RationalTime]
    let keyframeSeconds: [Double]
    let thumbnailSyncTimes: [Double]

    init(media: MediaInfo, id: UUID = UUID(), originalURL: URL? = nil,
         replacementNames: [Int: String] = [:], replacementTrack: Int? = nil) {
        self.originalURL = originalURL ?? media.url
        self.replacementNames = replacementNames
        self.replacementTrack = replacementTrack
        self.id = id
        self.media = media
        frames = media.frames.map(\.time)
        frameBoundaries = frames.filter { $0 >= .zero && $0 < media.duration } + [media.duration]
        keyframes = media.frames.lazy.filter(\.keyframe).map(\.time)
        keyframeSeconds = keyframes.map(\.seconds)
        thumbnailSyncTimes = media.frames.compactMap { frame in
            if frame.canStart || (frame.time == .zero && media.sourceStartSafe) { return frame.time.seconds }
            return nil
        }
    }

    func audioOrdinal(preferred: Int) -> Int? {
        let audio = media.streams.filter { $0.kind == "audio" }
        return audio.indices.contains(preferred) ? preferred : audio.indices.first
    }

    var isAudioReplacement: Bool { replacementTrack != nil && originalURL != url }
    var isIndexed: Bool { media.hasVideo ? !frames.isEmpty : !media.audio.isEmpty }
    var url: URL { media.url }
    var name: String { originalURL.lastPathComponent }
    var duration: RationalTime { media.duration }
    var replacementLabel: String? {
        if replacementNames.count == 1 { return replacementNames.values.first }
        if replacementNames.isEmpty { return nil }
        return replacementNames.sorted { $0.key < $1.key }
            .map { "Track \($0.key + 1): \($0.value)" }.joined(separator: " · ")
    }
}

/// Occurrences can link to the same working movie with different replacement provenance.
private struct DocumentSourceKey: Hashable {
    let file: URL
    let original: URL
    let track: Int?
    let names: [Int: String]
}

private struct EditorSegment: Sendable {
    let id: UUID
    let documentID: String
    var source: IndexedSource
    var start: RationalTime
    var end: RationalTime
    var displayRange: AudioSpan?
    // Retained pieces share protection choices belonging to this occurrence of a source.
    let occurrence: UUID

    init(id: UUID = UUID(), documentID: String? = nil, source: IndexedSource, start: RationalTime = .zero, end: RationalTime? = nil,
         displayRange: AudioSpan? = nil, occurrence: UUID? = nil) {
        self.id = id
        self.documentID = documentID ?? id.uuidString
        self.source = source
        self.start = start
        self.displayRange = displayRange
        self.occurrence = occurrence ?? id
        self.end = end ?? source.duration
    }

    func split(at boundary: RationalTime, rightID: UUID) -> (left: Self, right: Self) {
        var left = self
        left.end = boundary
        left.displayRange = AudioSpan(from: min(start, displayRange?.from ?? .zero), to: boundary)
        let right = Self(id: rightID, source: source, start: boundary, end: end,
                         displayRange: AudioSpan(from: boundary, to: max(end, displayRange?.to ?? source.duration)),
                         occurrence: occurrence)
        return (left, right)
    }

    var duration: RationalTime { end - start }
    func sequenceSeconds(at sourceTime: RationalTime, offset: RationalTime) -> Double {
        if let exact = try? offset.adding(sourceTime.subtracting(start)) { return exact.seconds }
        return offset.seconds + (sourceTime.seconds - start.seconds)
    }

    var preview: PreviewRange {
        var range = PreviewRange(media: source.media, from: start, to: end)
        range.audioTrack = source.replacementTrack
        return range
    }
    var request: ClipRequest { ClipRequest(file: source.url, from: start, to: end) }
    func timeline(sequenceRange: Range<Double>) -> TimelineClip {
        TimelineClip(id: id, sourceID: source.id, name: source.name, sourceStart: start.seconds, sourceEnd: end.seconds,
                     sourceDuration: source.duration.seconds, keyframes: source.keyframeSeconds,
                     thumbnailSyncTimes: source.thumbnailSyncTimes, frames: source.frames,
                     displaySize: CGSize(width: source.media.videoStream?.displayWidth ?? 0, height: source.media.videoStream?.displayHeight ?? 0),
                     sourceOrigin: source.media.origin,
                     sequenceRange: sequenceRange, isIndexed: source.isIndexed, displayRange: displayRange,
                     isAudioOnly: !source.media.hasVideo, audioSampleRate: source.media.hasVideo ? 0 : source.media.primaryStream.sampleRate,
                     replacementAudio: source.replacementLabel)
    }
}

private struct BoundaryIndex: Sendable {
    let wholeStarts: [RationalTime]
    let firstStarts: [RationalTime]
    let interiorStarts: [RationalTime]
    let wholeEnds: [RationalTime]
    let finalEnds: [RationalTime]
    let interiorEnds: [RationalTime]
    let splitPoints: [RationalTime]

    func starts(first: Bool, last: Bool) -> [RationalTime] {
        guard first else { return interiorStarts }
        return last ? wholeStarts : firstStarts
    }

    func ends(first: Bool, last: Bool) -> [RationalTime] {
        guard last else { return interiorEnds }
        return first ? wholeEnds : finalEnds
    }

    init(media: MediaInfo, container: String, engine: CutEngine) throws {
        func boundaries(start: Bool, first: Bool = true, last: Bool = true) throws -> [RationalTime] {
            try Task.checkCancellation()
            return engine.validBoundaries(in: media, start: start, first: first, last: last, container: container)
        }
        wholeStarts = try boundaries(start: true)
        wholeEnds = try boundaries(start: false)
        if media.audio.isEmpty {
            firstStarts = wholeStarts
            interiorStarts = wholeStarts
            finalEnds = wholeEnds
            interiorEnds = wholeEnds
        } else {
            firstStarts = try boundaries(start: true, last: false)
            interiorStarts = try boundaries(start: true, first: false, last: false)
            finalEnds = try boundaries(start: false, first: false)
            interiorEnds = try boundaries(start: false, first: false, last: false)
        }
        try Task.checkCancellation()
        if engine.coalescesAdjacentRanges(in: media, container: container) {
            // Splitting a continuous source adds a timeline seam only. There is
            // no audio decoder restart at that point until the pieces move apart.
            splitPoints = media.frames.compactMap { frame in
                frame.canStart && frame.canEnd ? frame.time : nil
            }
        } else {
            let starts = interiorStarts
            var index = 0
            splitPoints = interiorEnds.filter { end in
                while index < starts.count && starts[index] < end { index += 1 }
                return index < starts.count && starts[index] == end
            }
        }
    }
}

private struct PreparedEdit: Sendable {
    var container: String?
    static let backgroundCopyCheckBytes = 512 * 1024
    var firstSourceID: UUID?
    var requiresBackgroundCopyChecks = false
    var sourceMedia: [UUID: MediaInfo] = [:]
    var audioTracks: [StreamInfo] = []
    /// True when the movies differ in format, so no packet copy joins them and only Re-encode writes the timeline.
    var isMixed = false

    init() {}

    init(segments: [EditorSegment], previous: Self, engine: CutEngine) {
        sourceMedia = Dictionary(segments.map { ($0.source.id, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        if sourceMedia.count > 1, let first = segments.first?.source, first.media.hasVideo {
            // Measured against the first clip, as the import and the planners do. A replacement working copy changes
            // its sound by design, so it is held to the first clip's picture and track count only.
            var seen: Set<UUID> = [first.id]
            isMixed = segments.contains { segment in
                let source = segment.source
                guard seen.insert(source.id).inserted, source.media.hasVideo else { return false }
                if source.isAudioReplacement || first.isAudioReplacement {
                    return (try? engine.checkPictureCompatibility(source.media, with: first.media)) == nil
                        || source.media.audio.count != first.media.audio.count
                }
                return (try? engine.checkCompatibility(source.media, with: first.media)) == nil
            }
        }
        audioTracks = sourceMedia.values.sorted { $0.url.path < $1.url.path }
            .map { $0.streams.filter { $0.kind == "audio" } }.max { $0.count < $1.count } ?? []
        requiresBackgroundCopyChecks = sourceMedia.values.reduce(0) { $0 + $1.indexStorageBytes } >= PreparedEdit.backgroundCopyCheckBytes
        guard let first = segments.first?.source, first.isIndexed else { return }
        firstSourceID = first.id
        container = first.id == previous.firstSourceID
            ? previous.container : engine.suggestedContainers(for: first.media).first
    }
}

private struct EditSnapshot {
    // Value-semantic clip records share storage with every retained history snapshot.
    var documentClips: [CutSequenceClip] = []
    var stillSequence: StillSequenceProject?
    var segments: [EditorSegment] = []
    var timelineClips: [TimelineClip] = []
    var timelineThumbnailHeight = TimelineClip.minimumThumbnailHeight
    var largeThumbnailHeight = TimelineClip.minimumLargeThumbnailHeight
    var preparation = PreparedEdit()
    var selectedID: UUID?
    var markIn: RationalTime?
    var markOut: RationalTime?
    var pointerMarkIn = false
    var pointerMarkOut = false
    var playhead: Double = 0
    var offsets: [RationalTime] = []
    var duration: RationalTime = .zero
}

/// The answer to a tier question asked from a writer's thread, which waits for it.
private final class TierAnswer: @unchecked Sendable {
    var choice: TierPrompt.Choice?
}

final class EditCancellation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var reportedProgress = 0.0
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    func cancel() {
        let handlers = lock.withLock {
            cancelled = true
            let handlers = cancellationHandlers
            cancellationHandlers.removeAll()
            return handlers
        }
        for handler in handlers.values { handler() }
    }

    func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyCancelled = lock.withLock {
            if cancelled { return true }
            cancellationHandlers[id] = handler
            return false
        }
        if alreadyCancelled { handler() }
        return id
    }

    func removeCancellationHandler(_ id: UUID) {
        lock.withLock { _ = cancellationHandlers.removeValue(forKey: id) }
    }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func shouldReport(_ fraction: Double) -> Bool {
        lock.withLock {
            guard fraction > reportedProgress, fraction == 1 || fraction >= reportedProgress + 0.005 else { return false }
            reportedProgress = fraction
            return true
        }
    }

    func resetReportedProgress(to fraction: Double) {
        lock.withLock { reportedProgress = fraction }
    }
}

// Index and thumbnail workers consult the current preference before publishing a sidecar.
final class SidecarPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    private var change = EditCancellation()
    private var exclusions: Set<URL> = []
    private var cachedPermissions: [URL: Bool] = [:]

    func setExclusions(_ urls: Set<URL>) {
        let previous: EditCancellation? = lock.withLock {
            guard urls != exclusions else { return nil }
            exclusions = urls
            cachedPermissions.removeAll()
            let previous = change
            change = EditCancellation()
            return previous
        }
        previous?.cancel()
    }

    func permits(_ url: URL) -> Bool {
        indexSettings(for: url).enabled
    }

    var enabled: Bool {
        get { lock.withLock { value } }
        set {
            let previous: EditCancellation? = lock.withLock {
                guard value != newValue else { return nil }
                value = newValue
                let previous = change
                change = EditCancellation()
                return previous
            }
            previous?.cancel()
        }
    }

    func indexSettings(for url: URL) -> (enabled: Bool, change: EditCancellation) {
        lock.withLock {
            guard value, !exclusions.isEmpty else { return (value, change) }
            if let allowed = cachedPermissions[url] { return (allowed, change) }
            let allowed = !AnalysisSidecar.isExcluded(url, in: exclusions)
            cachedPermissions[url] = allowed
            return (allowed, change)
        }
    }
}

struct QueuedRange: Identifiable, Sendable {
    let id = UUID()
    let start: RationalTime
    let end: RationalTime
    let clips: [ClipRequest]
    let media: [URL: MediaInfo]
    var stillProject: CutProject? = nil
    var placements: ExportPlacementScope = .none
}

struct EditorNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class EditorModel: ObservableObject {
    let preferences: EditorPreferences
    let preview: SequencePreview

    @Published private var edit = EditSnapshot()
    @Published private(set) var projectURL: URL?
    private var projectDiskRevision: ProjectDiskRevision?
    private(set) var openingProjectURL: URL?
    let draft: ProjectDraft
    private var committedBeforeImport: CutProject?
    private var savedSequence: [CutSequenceClip] = []
    private var savedStillSequence: StillSequenceProject?
    private var stillTimelineIDs: [String: UUID] = [:]
    // A named file can still reference older history beyond this window’s retention limit.
    private var savedMediaPaths: [String: String] = [:]
    private var lastSidecarPaths: Set<String> = []
    private var lastSidecarCandidates: Set<URL> = []
    private(set) var sidecarExclusions: Set<URL> = []
    private var savedUndoIDs: [UUID] = []
    private var savedRedoIDs: [UUID] = []
    private var recoveredDraft = false
    private var deferredDraftSave = false
    var canSaveProjectTo: ((URL) -> Bool)?

    private(set) var mcpGeneration = UUID()
    private(set) var mcpRevision = 0
    var mcpSequenceOffsets: [RationalTime] { edit.offsets }
    var mcpClipIDs: [UUID] { edit.segments.map(\.id) }
    var mcpTrimBoundary: RationalTime? { trimAudition?.2 }
    private(set) var mcpTrimPreview: UUID?
    func mcpTrimMatches(_ id: UUID, edge: TimelineEdge) -> Bool {
        trimAudition?.0 == id && trimAudition?.1 == edge
    }
    func cancelMCPTrimPreview() {
        if mcpTrimPreview != nil { cancelTrim() }
    }

    var mcpHasActiveTrim: Bool { trimOrigin != nil || trimValidation != nil }
    var mcpHistoryLimit: Int { preferences.historyLimit }
    var mcpDuration: RationalTime { edit.duration }

    func mcpOccurrence(_ id: UUID) -> (start: RationalTime, end: RationalTime, offset: RationalTime, sourceDuration: RationalTime)? {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        return (segments[index].start, segments[index].end, edit.offsets[index], segments[index].source.duration)
    }

    func mcpSceneSource(for clip: UUID) -> String? {
        segments.first { $0.id == clip }?.source.id.uuidString
    }

    var mcpCopyContainers: [String] {
        // No container carries a packet copy of clips in different formats.
        guard let source = segments.first?.source.media, !isMixedTimeline else { return [] }
        let choices = CutEngine(tracks: source.hasVideo ? .all : .audio)
            .suggestedContainers(for: source, clips: segments.map(\.request))
        return source.hasVideo && choices.isEmpty ? [preferredCopyContainer ?? "mp4"] : choices
    }

    var sequenceClips: [CutSequenceClip] { edit.documentClips }
    var stillProject: CutProject { edit.stillSequence.map(CutProject.stillSequence) ?? .sequence(sequenceClips) }

    private func sequenceClips(for segments: [EditorSegment]) -> [CutSequenceClip] {
        segments.map { clip in
            CutSequenceClip(id: clip.documentID, file: clip.source.url.path,
                            from: clip.start, to: clip.end, audioTrack: clip.source.replacementTrack,
                            originalFile: clip.source.originalURL == clip.source.url ? nil : clip.source.originalURL.path,
                            replacementNames: clip.source.replacementNames)
        }
    }

    @Published private(set) var isProjectChanged = false

    var canOpenProject: Bool {
        projectURL == nil && draft.url == nil && isEmpty && !hasHistory && queuedRanges.isEmpty && !isBusy && alert == nil
    }

    func openProject(_ clips: [CutSequenceClip], at url: URL,
                     history: (undo: [CutHistoryState], redo: [CutHistoryState])? = nil,
                     reservation: ProjectDraft.Reservation? = nil, archiveMedia: CutProjectMedia? = nil,
                     allowCommit: (() -> Bool)? = nil, stillProject: CutProject? = nil) throws {
        guard canOpenProject else {
            throw CutError(code: "editor_in_use", message: "Open the project in an empty editor window.")
        }
        let reservation = try reservation ?? draft.reserveIfRecoverable(url)
        try CutProject.sequence(clips).validate()
        let disk = history == nil && FileManager.default.fileExists(atPath: url.path)
            ? try CutProject.loadEditorDocument(from: url, limit: preferences.historyLimit) : nil
        let archive = history ?? (undo: disk?.undo ?? [], redo: disk?.redo ?? [])
        let media = archiveMedia ?? disk?.media
        let diskPaths = media?.absoluteSources(relativeTo: url)
        var resolvedPaths: [String: String] = [:]
        func resolve(_ file: String) -> String {
            if let cached = resolvedPaths[file] { return cached }
            let path = CutProject.mediaURL(file, relativeTo: url).path
            resolvedPaths[file] = path
            return path
        }
        func absolute(_ clip: CutSequenceClip) -> CutSequenceClip {
            var copy = clip
            copy.file = resolve(clip.file)
            copy.originalFile = clip.originalFile.map(resolve)
            return copy
        }
        func absoluteProject(_ project: CutProject) throws -> CutProject {
            switch project {
            case .sequence(let clips): return .sequence(clips.map(absolute))
            case .stillSequence(var sequence):
                sequence.items = sequence.items.map { item in
                    if case .source(let clip) = item { return .source(absolute(clip)) }
                    return item
                }
                sequence.stillAssets = sequence.stillAssets.map { asset in
                    var asset = asset
                    asset.file = resolve(asset.file)
                    return asset
                }
                return .stillSequence(sequence)
            default:
                throw CutError(code: "invalid_cut_project", message: "A sequence history state must contain a sequence.")
            }
        }
        func entries(_ states: [CutHistoryState]) throws -> [HistoryEntry] {
            try states.map { state in
                HistoryEntry(action: state.action, contents: .document(try absoluteProject(state.project)))
            }
        }
        let loadedProject: CutProject
        if let stillProject { loadedProject = stillProject }
        else if let project = disk?.project, case .stillSequence = project { loadedProject = project }
        else { loadedProject = .sequence(clips) }
        let fullDocument = try absoluteProject(loadedProject)
        try fullDocument.validate()
        let undo = try entries(archive.undo), redo = try entries(archive.redo)
        let document = fullDocument.sequenceClips ?? []
        var paths = diskPaths ?? [:]
        if diskPaths == nil {
            for (relative, path) in resolvedPaths { paths[path] = relative }
        }
        let opened = {
            self.mcpGeneration = UUID()
            self.mcpRevision = 0
            self.savedMediaPaths = paths
            self.recoveredDraft = self.draft.adopt(reservation)
            self.projectURL = self.recoveredDraft ? nil : url
            self.projectDiskRevision = self.recoveredDraft ? nil : media?.diskRevision
            self.undoStack = undo
            self.redoStack = redo
            self.enforceHistoryLimit()
            self.markSaved()
            self.updateStatus()
        }
        if document.isEmpty {
            if allowCommit?() != false {
                installStillPresentation(fullDocument)
                opened()
            }
        } else {
            let files = try checkedFiles(document)
            openingProjectURL = url
            importFiles(files, projectClips: document, openingMedia: paths, allowCommit: allowCommit, installed: opened,
                        sequenceProject: fullDocument)
        }
    }

    private func checkedFiles(_ clips: [CutSequenceClip]) throws -> [URL] {
        // Archive references are absolute here. A once-offline traversal may now
        // resolve through a mounted directory or a restored symlink.
        var files: [String: URL] = [:]
        return try clips.map { clip in
            if let file = files[clip.file] { return file }
            let file = URL(fileURLWithPath: clip.file)
            let resolved = clip.file.split(separator: "/").contains("..")
                ? try CutProject.checkedMediaURL(clip.file, relativeTo: file) : file
            files[clip.file] = resolved
            return resolved
        }
    }

    private func markSaved() {
        savedSequence = sequenceClips
        savedStillSequence = edit.stillSequence
        savedUndoIDs = undoStack.map(\.id)
        savedRedoIDs = redoStack.map(\.id)
        isProjectChanged = recoveredDraft
    }

    func requestSaveProject(asNew: Bool = false) {
        guard !isBusy else { return }
        if let projectURL, !asNew { _ = saveProject(to: projectURL); return }
        let panel = ProjectPanels.cutSavePanel(name: projectURL?.lastPathComponent ?? "Untitled.cut")
        ProjectPanels.present(panel, in: editorWindow) { accepted in
            if accepted, let url = panel.url { _ = self.saveProject(to: url) }
        }
    }

    @discardableResult
    func saveProject(to url: URL) -> Bool {
        do {
            try writeProject(to: url)
            return true
        } catch {
            ProjectPanels.present(NSAlert(error: error), in: editorWindow)
            return false
        }
    }

    func writeProject(to url: URL, replacingExisting: Bool = true) throws {
        guard !isBusy else {
            throw CutError(code: "editor_busy", message: "Wait for the current operation to finish.")
        }
        guard canSaveProjectTo?(url) != false else {
            throw CutError(code: "project_open", message: "Another window already has this project open.")
        }
        guard !ProjectDraft.isManaged(url), !draft.managesDestination(url) else {
            throw CutError(code: "project_draft_destination", message: "Choose a location outside MPCut’s recovery folder.")
        }
        try validateHistoryDestination(url)
        let expected = projectDiskRevision.flatMap { $0.matchesDestination(url) ? $0 : nil }
        projectDiskRevision = try documentWriter(replacingExisting: replacingExisting, coordinate: true, expected: expected)(url)
        // Keep every recording referenced by the saved file until the next explicit save.
        savedMediaPaths = documentMedia()
        refreshSidecarExclusions()
        projectURL = url
        recoveredDraft = false
        markSaved()
        draft.discard()
    }

    private func documentMedia(including saved: [String: String] = [:]) -> [String: String] {
        var paths = saved
        func collect(_ clips: [CutSequenceClip]) {
            for clip in clips {
                paths[clip.file] = clip.id
                if let original = clip.originalFile { paths[original] = clip.id }
            }
        }
        func collectProject(_ project: CutProject) {
            for asset in project.stillAssets { paths[asset.file] = asset.id }
        }
        collect(sequenceClips)
        collectProject(stillProject)
        for entry in undoStack { collect(entry.clips); collectProject(entry.project) }
        for entry in redoStack { collect(entry.clips); collectProject(entry.project) }
        return paths
    }

    private var protectedMedia: [String: String] {
        var files = documentMedia(including: savedMediaPaths)
        for range in queuedRanges {
            for clip in range.clips { files[clip.file.path] = clip.file.lastPathComponent }
            for asset in range.stillProject?.stillAssets ?? [] { files[asset.file] = asset.id }
            if let reference = range.stillProject?.stillAudioReference {
                files[reference.file] = reference.id
                if let original = reference.originalFile { files[original] = reference.id }
            }
        }
        return files
    }

    func validateHistoryDestination(_ output: URL, includesContents: Bool = false) throws {
        try CutProject.validateMediaDestination(output, absoluteSources: protectedMedia, includesContents: includesContents)
    }

    private func refreshSidecarExclusions(adding urls: [URL] = [], openingMedia: [String: String] = [:]) {
        var paths = protectedMedia
        paths.merge(openingMedia) { current, _ in current }
        for url in urls { paths[url.path] = url.lastPathComponent }
        let candidates = Set(segments.map { $0.source.url }).union(urls)
        let sourcePaths = Set(paths.keys)
        guard sourcePaths != lastSidecarPaths || candidates != lastSidecarCandidates else { return }
        lastSidecarPaths = sourcePaths
        lastSidecarCandidates = candidates
        let excluded = CutProject.sidecarExclusions(absoluteSources: paths, candidates: Array(candidates))
        guard excluded != sidecarExclusions else { return }
        sidecarExclusions = excluded
        sidecarPreference.setExclusions(excluded)
        if !isEmpty { syncWaveforms(invalidatingPauses: true) }
    }

    private func canExport(to output: URL, includesContents: Bool = false) -> Bool {
        do {
            try validateHistoryDestination(output, includesContents: includesContents)
            return true
        } catch {
            alert = EditorNotice(title: "Couldn’t Export", message: error.localizedDescription)
            return false
        }
    }

    private func documentWriter(project snapshot: CutProject? = nil, replacingExisting: Bool = true,
                                coordinate: Bool = false, expected: ProjectDiskRevision? = nil)
        -> @Sendable (URL) throws -> ProjectDiskRevision? {
        func state(_ entry: HistoryEntry) -> CutHistoryState {
            CutHistoryState(action: entry.action, project: entry.project)
        }
        let project = snapshot ?? stillProject
        let undo = undoStack.map(state), redo = redoStack.map(state)
        return { url in
            var paths: [String: String] = [:]
            func relative(_ file: String) -> String {
                if let cached = paths[file] { return cached }
                let path = CutProject.relativeMediaPath(file, to: url)
                paths[file] = path
                return path
            }
            func rebasedClip(_ clip: CutSequenceClip) -> CutSequenceClip {
                var copy = clip
                copy.file = relative(clip.file)
                copy.originalFile = clip.originalFile.map(relative)
                return copy
            }
            func rebasedProject(_ project: CutProject) -> CutProject {
                switch project {
                case .sequence(let clips): return .sequence(clips.map(rebasedClip))
                case .stillSequence(var sequence):
                    sequence.items = sequence.items.map { item in
                        guard case .source(let clip) = item else { return item }
                        return .source(rebasedClip(clip))
                    }
                    sequence.stillAssets = sequence.stillAssets.map { asset in
                        var asset = asset
                        asset.file = relative(asset.file)
                        return asset
                    }
                    return .stillSequence(sequence)
                default: return project
                }
            }
            func rebased(_ state: CutHistoryState) -> CutHistoryState {
                CutHistoryState(action: state.action, project: rebasedProject(state.project))
            }
            let current = rebasedProject(project)
            let undo = undo.map(rebased), redo = redo.map(rebased)
            if coordinate {
                return try current.saveRevision(to: url, undo: undo, redo: redo,
                                                replacingExisting: replacingExisting, expected: expected)
            }
            try current.save(to: url, undo: undo, redo: redo, replacingExisting: replacingExisting)
            return nil
        }
    }

    private func saveUntitledDraft() {
        guard projectURL == nil, openingProjectURL == nil,
              draft.url != nil || !segments.isEmpty || hasHistory else { return }
        // An import can temporarily display a provisional first frame or a partial batch.
        // Only committed edits may become the recovery document.
        guard !isImporting else { deferredDraftSave = true; return }
        deferredDraftSave = false
        let writeDocument = documentWriter()
        let writer: @Sendable (URL) throws -> Void = { _ = try writeDocument($0) }
        do {
            let records = undoStack.reduce(segments.count) { $0 + $1.clipCount }
            let total = redoStack.reduce(records) { $0 + $1.clipCount }
            if draft.url != nil, total >= 1_000 || draft.hasScheduledWrites {
                try draft.schedule(writer) { [weak self] error in self?.reportDraftError(error) }
            } else {
                try draft.write(writer)
            }
        } catch { reportDraftError(error) }
    }

    private func reportDraftError(_ error: Error) {
        alert = EditorNotice(title: "Couldn’t Save Recovery Project", message: error.localizedDescription)
    }

    func confirmCloseProject() -> Bool {
        guard isProjectChanged else { return true }
        let confirmation = NSAlert()
        confirmation.messageText = "Save changes to " + (projectURL?.lastPathComponent ?? "Untitled Project") + "?"
        confirmation.addButton(withTitle: "Save").toolTip = "Save project changes"
        confirmation.addButton(withTitle: "Discard Changes").toolTip = "Close without saving"
        confirmation.addButton(withTitle: "Cancel").toolTip = "Keep project open"
        switch confirmation.runModal() {
        case .alertFirstButtonReturn:
            if let projectURL { return saveProject(to: projectURL) }
            let panel = ProjectPanels.cutSavePanel(name: "Untitled.cut")
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            return saveProject(to: url)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    @Published var rangeTool = false
    @Published private(set) var playhead = 0.0
    @Published private(set) var importProgress = 0.0
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var isCancelling = false
    @Published private(set) var exportProgress = 0.0
    @Published private(set) var statusMessage = "Add local video or audio files to start."
    @Published private(set) var lastExportedURL: URL?
    @Published private(set) var isCheckingEdit = false
    @Published private var isPresentingPanel = false
    @Published private(set) var queuedRanges: [QueuedRange] = []
    @Published var isBulkQueuePresented = false
    @Published var alert: EditorNotice?

    // The timeline tier: the best mode that writes the current timeline. TimelineTierGate.swift holds the wording.
    /// Nil for an empty timeline.
    @Published private(set) var tierState: TierState?
    /// False while a newer timeline is still being checked.
    private(set) var tierIsCurrent = true
    private let tierEvaluator = TimelineTierEvaluator()
    private var tierGeneration = 0
    private var tierToken: EditCancellation?
    /// Set while an edit made by hand is being applied. Remote edits, undo, redo and opening a project never ask.
    private var asksBeforeLoweringTier = false
    /// Presents the question. Tests replace it. Nil shows a sheet on the editor window.
    var tierPrompt: ((TierPrompt, @escaping (TierPrompt.Choice) -> Void) -> Void)?

    private var preferenceObservation: AnyCancellable?
    private let sidecarPreference = SidecarPreference()

    var useAnalysisSidecars: Bool {
        get { preferences.useAnalysisSidecars }
        set { preferences.useAnalysisSidecars = newValue }
    }
    var defaultExportMode: ExportMode {
        get { preferences.defaultExportMode }
        set { preferences.defaultExportMode = newValue }
    }
    var snapTarget: TimelineSnapTarget {
        get { preferences.snapTarget }
        set {
            guard newValue != snapTarget else { return }
            usesPointerPosition = false
            cancelTrim()
            preferences.snapTarget = newValue
        }
    }
    var largeThumbnails: Bool {
        get { preferences.largeThumbnails }
        set { preferences.largeThumbnails = newValue }
    }
    private(set) var previousTimelineZoom = 1.0
    @Published var timelineZoom = 0.0 {
        didSet { if timelineZoom == 0, oldValue > 0 { previousTimelineZoom = oldValue } }
    }
    @Published private(set) var timeEntryRequest = 0
    private var explicitCopyContainer: String?
    private var copyBoundaryIndices: [UUID: BoundaryIndex] = [:]
    private var boundaryPreparation: Task<Void, Never>?
    private var boundaryPreparationID: UUID?
    @Published private(set) var isPreparingCopyBoundaries = false
    private var trimValidation: Task<Void, Never>?
    private var trimValidationID: UUID?
    private var isCommittingHandle = false
    private struct TrimCheck: Sendable {
        let error: CutError?
    }
    private var checkingTrim: (UUID, TimelineEdge)?
    private var trimChecks: [RationalTime: TrimCheck] = [:]
    private var fixedTrimIssue: CutError?

    private enum HistoryContents {
        case live(EditSnapshot)
        // Offline recordings in earlier states must not prevent opening the current edit.
        case document(CutProject)
    }

    private enum AudioMonitoring: Equatable {
        case followSource
        case track(Int)
    }

    private struct HistoryEntry {
        var id = UUID()
        var action: String
        var contents: HistoryContents
        var project: CutProject {
            switch contents {
            case .live(let edit):
                return edit.stillSequence.map(CutProject.stillSequence) ?? .sequence(edit.documentClips)
            case .document(let project): return project
            }
        }
        var clips: [CutSequenceClip] {
            switch project {
            case .sequence(let clips): return clips
            case .stillSequence(let sequence):
                return sequence.items.compactMap { if case .source(let clip) = $0 { return clip }; return nil }
            default: return []
            }
        }
        var clipCount: Int {
            switch project {
            case .sequence(let clips): return clips.count
            case .stillSequence(let sequence): return sequence.items.count
            default: return 0
            }
        }
        var copyContainer: String?
        var audioMonitoring: AudioMonitoring?
    }
    /// Save and open panels attach to the editor, not to whichever window is main.
    weak var editorWindow: NSWindow?
    private var sheetWindow: NSWindow? { editorWindow.flatMap { $0.isVisible ? $0 : nil } }
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private var previewTimeObservation: AnyCancellable?
    private var trimOrigin: Double?
    private var trimAudition: (UUID, TimelineEdge, RationalTime)? {
        willSet {
            if isAudioOnly && (trimAudition != nil || newValue != nil) { objectWillChange.send() }
        }
    }
    private var cancellation: EditCancellation?
    var activeNativeOperation: MCPNativeOperation? {
        guard let cancellation, isImporting || isExporting else { return nil }
        return MCPNativeOperation(id: cancellation.id, kind: isImporting ? "import" : "export",
                                  label: statusMessage, progress: isImporting ? importProgress : exportProgress,
                                  cancelling: cancellation.isCancelled)
    }
    private var exportOptions = ExportSheetOptions()
    private var exportDirectory: URL?
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    private var waitingForExportCleanup = false
    private var pendingOpenFiles: [URL] = []
    private var session = UUID()
    var mcpSceneReceipt: MCPAnalysisReceipt?
    var mcpSilenceReceipt: MCPAnalysisReceipt?
    var mcpSidecarReceipt: MCPAnalysisReceipt?
    let mediaRefresh = ProjectMediaRefresh()
    var mcpRefreshReceipt: MCPAnalysisReceipt? { mediaRefresh.activeReceipt }
    @Published private(set) var mediaRefreshProgress: Double?
    @Published private var mediaRefreshWarnings: [UUID: String] = [:]
    var mediaRefreshIssues: [String: String] {
        Dictionary(segments.compactMap { segment -> (String, String)? in
            let source = segment.source
            let message = mediaReviewIssue(segment)
                ?? ((refreshStaleScenes.contains(source.id) || refreshStaleSilence.contains(source.id))
                    ? "\(source.name) — analysis is out of date." : mediaRefreshWarnings[source.id])
            return message.map { (source.id.uuidString, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
    @Published private(set) var mediaClipReview: [UUID: String] = [:]
    var refreshStaleScenes = Set<UUID>()
    private(set) var staleSceneReports: [UUID: SceneReport] = [:]
    private var refreshStaleSilence = Set<UUID>()
    private var invalidatedQueueIDs = Set<UUID>()
    private var refreshReviewStreams: [URL: Set<Int>] = [:]
    private var refreshReviewPicture = Set<URL>()
    private var offlineMedia = Set<URL>()
    private var incompatibleMedia = Set<URL>()
    private var refreshBaselines: [URL: MediaInfo] = [:]
    private var refreshSourceRevisions: [UUID: Int] = [:]
    private var refreshDisplayRevisions: [UUID: Int] = [:]
    private var nextRefreshDisplayRevision = 0

    private struct RefreshFilmstrip {
        let media: MediaInfo
        let displayRevision: Int
        let decoderID = UUID()
    }
    @Published private var refreshFilmstrips: [UUID: RefreshFilmstrip] = [:]
    private var mediaWatcher: ProjectMediaWatcher?
    private let sceneScan = EditorSceneScan()
    private var previousSceneClip: ClipSceneRange?
    private var sceneRangeReports: [ClipSceneRange: SceneReport] = [:]
    private var staleSceneRangeReports: [ClipSceneRange: SceneReport] = [:]
    private var sceneOverlays: [ClipSceneRange: TimelineSceneOverlay] = [:]
    private var sourceSceneOverlays: [UUID: TimelineSceneOverlay] = [:]

    private struct ClipSceneRange: Hashable {
        let clip: UUID
        let source: UUID
        let start: RationalTime
        let end: RationalTime

        init(_ segment: EditorSegment) {
            clip = segment.id
            source = segment.source.id
            start = segment.start
            end = segment.end
        }
    }

    private(set) var sceneReports: [UUID: SceneReport] = [:]
    var analysisSourceMedia: [UUID: MediaInfo] { edit.preparation.sourceMedia }
    private var snapScanRequests = Set<UUID>()
    private var sidecarSaveToken: EditCancellation?
    var nativeSidecarSave: MCPNativeOperation? {
        guard let token = sidecarSaveToken, mcpSidecarReceipt == nil else { return nil }
        return MCPNativeOperation(id: token.id, kind: "sidecars", label: "Saving analysis sidecars…",
                                  progress: nil, cancelling: token.isCancelled)
    }

    func cancelNativeSidecarSave(id: UUID) {
        if sidecarSaveToken?.id == id { sidecarSaveToken?.cancel() }
    }

    private var lastSidecarWrite: (id: UUID, task: Task<Void, Never>)?
    private var pendingMetadata: [UUID: EditorMetadataEdits] = [:]
    private var filmstripTiles = FilmstripTileBuffer()
    @Published private(set) var isSavingSidecars = false
    private(set) var scenesBySource: [UUID: [TimelineScene]] = [:]
    private(set) var viewNamesBySource: [UUID: [Int: String]] = [:]
    var sceneProgress: Double? { sceneScan.progress }
    var sceneStatus: String? { sceneScan.status }
    var scenePaused: Bool { sceneScan.paused }
    var sceneCoverage: [String: SceneScanProgress] { sceneScan.coverage }
    var sceneClipID: UUID? { selectedID }
    var sceneInspectionKey: SceneInspectionKey {
        SceneInspectionKey(sceneChoiceRequests, readingSidecars: useAnalysisSidecars, revision: sceneScan.inspectionRevision)
    }
    private var sceneChoiceRequests: [EditorSceneRequest] {
        sceneRequests(clipID: nil) + (sceneClipID.map { sceneRequests(clipID: $0) } ?? [])
    }
    var sceneCheckpointSaveFailed: Bool { sceneCoverage.values.contains { $0.persistenceError != nil } }

    func inspectSceneChoices() async {
        await sceneScan.inspect(sceneChoiceRequests, preference: sidecarPreference)
        if !Task.isCancelled { objectWillChange.send() }
    }

    func sceneDisposition(clipID: UUID?) -> SceneScanDisposition? {
        let disposition = sceneScan.disposition(sceneRequests(clipID: clipID))
        if let clipID {
            guard let clip = segments.first(where: { $0.id == clipID }) else { return nil }
            if case .partial = disposition { return disposition }
            if sceneReport(for: clip) != nil { return .current }
            return refreshStaleScenes.contains(clip.source.id) ? .stale : disposition
        }
        return refreshStaleScenes.isEmpty ? disposition : .stale
    }

    var canScanSelectedScenes: Bool { sceneClipID.map { canScanScenes(clipID: $0) } ?? false }
    var sceneOverlaysByClip: [UUID: TimelineSceneOverlay] {
        guard !sceneOverlays.isEmpty || !sourceSceneOverlays.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: segments.compactMap { clip -> (UUID, TimelineSceneOverlay)? in
            let local = sceneOverlays[ClipSceneRange(clip)]
            let source = sceneReports[clip.source.id] == nil ? sourceSceneOverlays[clip.source.id] : nil
            return (local ?? source).map { (clip.id, $0) }
        })
    }
    @Published private(set) var sceneRevision = 0


    let audioStore = WaveformStore()
    @Published private(set) var waveformRevision = 0
    private struct AudioTrackKey: Hashable {
        let source: UUID
        let track: Int
    }
    private struct SilenceProfile: Hashable {
        let stream: Int
        let threshold: Double?
        let minimum: Double
    }
    private var silenceMedia: [UUID: MediaInfo] = [:]
    // Undo can restore a source whose last occurrence was deleted.
    // Keep its complete reports until the session ends.
    private var silenceResults: [UUID: [SilenceProfile: SilenceAnalysisResult]] = [:]
    private var checkedSilenceSidecars = Set<UUID>()
    private var silenceIssues: [UUID: String] = [:]
    private var pendingSilenceRescans = Set<UUID>()
    @Published private(set) var silenceScanRequested = false
    private var automaticThresholds: [UUID: Double] = [:]
    private var thresholdOverrides: [AudioTrackKey: Double] = [:]
    var minimumPause: Double {
        get { preferences.minimumPause }
        set { preferences.minimumPause = newValue }
    }
    var leavePause: Double {
        get { preferences.leavePause }
        set { preferences.leavePause = newValue }
    }
    @Published private var audioMonitoring: AudioMonitoring = .followSource
    var useSavedMonitoringTracks: Bool { audioMonitoring == .followSource }
    var audioMonitoringTrack: Int? {
        if case .track(let track) = audioMonitoring { return track }
        return nil
    }
    private(set) var sourceAnalysisTracks: [UUID: Int] = [:]

    /// One chosen track number applies to every clip, and a clip without that track is heard and analyzed on its
    /// first one. This says so where the track is chosen. Nil when every clip has the track, or follows its source.
    var audioTrackFallbackNote: String? {
        guard case .track(let track) = audioMonitoring else { return nil }
        var seen = Set<UUID>()
        let lacking = segments.map(\.source).filter { source in
            seen.insert(source.id).inserted && source.audioOrdinal(preferred: track).map { $0 != track } == true
        }
        guard let first = lacking.first else { return nil }
        let who = lacking.count == 1 ? "\(first.name) has" : "\(lacking.count) sources have"
        return "\(who) no track \(track + 1) and \(lacking.count == 1 ? "uses its" : "use their") first track."
    }

    func chooseAnalysisTrack(_ track: Int) {
        guard audioTracks.indices.contains(track) else { return }
        changeAudioMonitoring(to: .track(track))
    }

    func chooseAnalysisTrack(_ track: Int, forClip id: UUID) {
        guard canEdit, let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].source.audioOrdinal(preferred: track) == track else { return }
        select(id)
        if locatedSegment(at: playhead)?.0 != index { seek(edit.offsets[index].seconds) }
        chooseAnalysisTrack(track)
    }

    func monitorSourceAudio() { changeAudioMonitoring(to: .followSource) }

    private func changeAudioMonitoring(to monitoring: AudioMonitoring) {
        guard audioMonitoring != monitoring else { return }
        audioMonitoring = monitoring
        syncWaveforms()
        restorePreview(at: playhead)
        requestSnapAnalysis()
    }

    var analysisTrack: Int {
        get { audioMonitoringTrack ?? playheadAnalysisTrack }
        set { chooseAnalysisTrack(newValue) }
    }
    @Published var skipPauses = false
    private(set) var sourcePauses: [UUID: [AudioSpan]] = [:]
    private(set) var pausePlan: [TimelinePause] = []
    private var protectedPauses: [TimelinePause.Source: [AudioSpan]] = [:]
    private var pauseDetections: [UUID: Task<Void, Never>] = [:]
    private var mcpSilenceWorkers = Set<UUID>()
    private var activeAudioSources = Set<UUID>()
    private(set) var shortenedPauseCount = 0
    private(set) var removedPauseSeconds = 0.0
    @Published var cutPreview: CutPreview? {
        didSet {
            if oldValue != nil && cutPreview == nil { Task { resumePendingWork() } }
        }
    }
    var audioTracks: [StreamInfo] { edit.preparation.audioTracks }
    var playheadAudioTracks: [StreamInfo] { playheadAudioSource?.media.streams.filter { $0.kind == "audio" } ?? [] }
    private var hasSilenceResults: Bool {
        !activeAudioSources.isEmpty && activeAudioSources.allSatisfy { sourcePauses[$0] != nil }
    }
    private var pendingSilenceSources: Set<UUID> {
        activeAudioSources.subtracting(sourcePauses.keys).union(pendingSilenceRescans)
    }
    var pauseAnalysisReady: Bool { canEdit && hasSilenceResults }
    var silenceIssue: String? {
        for id in pendingSilenceSources {
            if let issue = silenceIssues[id] ?? audioStore.issues[id] { return issue }
        }
        return nil
    }
    var silenceProgress: Double? {
        let pending = pendingSilenceSources
        guard silenceScanRequested, !pending.isEmpty, silenceIssue == nil else { return nil }
        var total = 0.0, done = 0.0
        for (id, media) in silenceMedia {
            let seconds = media.duration.seconds
            total += seconds
            if !pending.contains(id) {
                done += seconds
            } else if let wave = audioStore.waves[id] {
                done += 0.95 * min(seconds, Double(wave.count) / Double(AudioWaveform.rate))
            }
        }
        return total > 0 ? done / total : 0
    }
    var canScanSilence: Bool { canEdit && !activeAudioSources.isEmpty && silenceProgress == nil }

    convenience init(defaults: UserDefaults? = nil) {
        self.init(preferences: EditorPreferences(defaults: defaults))
    }

    init(preferences: EditorPreferences, draft: ProjectDraft = ProjectDraft()) {
        self.preferences = preferences
        self.draft = draft
        preview = SequencePreview(preferences: preferences)
        sidecarPreference.enabled = useAnalysisSidecars
        exportOptions.mode = defaultExportMode
        preferenceObservation = preferences.observeChanges { [weak self] change in
            self?.applyPreference(change)
        }
        audioStore.changed = { [weak self] complete in
            guard let self else { return }
            if complete { self.refreshDetectedPauses() }
            else { self.waveformRevision += 1 }
        }
        previewTimeObservation = preview.$time.sink { [weak self] time in
            guard let self, self.trimOrigin == nil else { return }
            let clamped = min(max(0, time), self.duration)
            if clamped != self.playhead {
                self.usesPointerPosition = false
                self.playhead = clamped
            }
            if self.skipPauses, self.preview.playbackRate > 0 {
                self.skipPauseIfNeeded(at: clamped)
            }
        }
    }

    private func applyPreference(_ change: EditorPreferences.Change) {
        switch change {
        case .volume, .isMuted, .scrubSoundEnabled, .jpegPreset, .localMCPEnabled:
            return
        case .automaticallyRefreshMedia:
            updateMediaWatcher()
        case .useAnalysisSidecars:
            sceneScan.invalidateInspection()
            sidecarPreference.enabled = useAnalysisSidecars
            for task in pauseDetections.values { task.cancel() }
            checkedSilenceSidecars.subtract(pauseDetections.keys)
            pauseDetections.removeAll()
            mcpSilenceWorkers.removeAll()
            syncWaveforms()
        case .defaultExportMode:
            exportOptions.mode = defaultExportMode
        case .snapTarget:
            updateSnapTarget()
        case .historyLimit:
            if enforceHistoryLimit() {
                if !isImporting && !sidecarExclusions.isEmpty { refreshSidecarExclusions() }
                mcpRevision += 1
                updateStatus()
                saveUntitledDraft()
            }
        case .largeThumbnails:
            break
        case .minimumPause:
            refreshDetectedPauses(invalidating: activeAudioSources)
        case .leavePause:
            rebuildPausePlan()
        }
        objectWillChange.send()
    }

    private var segments: [EditorSegment] { edit.segments }
    var timelineClips: [TimelineClip] {
        guard !refreshFilmstrips.isEmpty else { return edit.timelineClips }
        return edit.timelineClips.map { clip in
            guard let preview = refreshFilmstrips[clip.sourceID], clip.mediaIssue == nil else { return clip }
            var projected = clip
            projected.hasProvisionalFilmstrip = true
            projected.mediaRevision = preview.displayRevision
            return projected
        }
    }
    var timelineThumbnailHeight: CGFloat {
        largeThumbnails ? edit.largeThumbnailHeight : edit.timelineThumbnailHeight
    }
    var canCloseVideo: Bool {
        (!isEmpty || isImporting) && !isExporting && !isSavingSidecars && !isPresentingPanel &&
            !isBulkQueuePresented && cutPreview == nil && alert == nil && !waitingForExportCleanup
    }
    private var hasInlineStills: Bool { edit.stillSequence?.items.contains { $0.still != nil } == true }
    var isEmpty: Bool { segments.isEmpty && !hasInlineStills }
    var hasPicture: Bool { hasInlineStills || segments.first?.source.media.hasVideo == true }
    var isAudioOnly: Bool { !isEmpty && !hasPicture }
    /// True when the clips differ in format (`ExportRules` “Mixed timelines”): only Re-encode writes the timeline.
    var isMixedTimeline: Bool { edit.preparation.isMixed }
    var effectiveSnapTarget: TimelineSnapTarget {
        // Keyframe snapping keeps cuts where a packet copy can join them. A mixed timeline has no packet copy,
        // so its cuts fall on any frame and are not held to copy boundaries of the first clip's container.
        if isMixedTimeline && snapTarget == .keyframes { return .off }
        return isAudioOnly && (snapTarget == .scenes || snapTarget == .keyframes) ? .off : snapTarget
    }

    /// The picker's choice. An audio-only window shows Off in place of a stored
    /// picture target, and choosing what it already shows must not replace the
    /// preference that video windows share.
    func chooseSnapTarget(_ target: TimelineSnapTarget) {
        guard target != effectiveSnapTarget else { return }
        if isMixedTimeline && target == .keyframes {
            // The shared preference is left alone, as for an audio-only window. Say why the picker stays on Off.
            alert = EditorNotice(title: "Keyframe Snapping Is Unavailable", message: ExportRules.mixedUnavailable("Snapping cuts to keyframes"))
            return
        }
        snapTarget = target
    }

    var audioPreviewClip: (clip: TimelineClip, offset: Double)? {
        guard isAudioOnly else { return nil }
        let index = trimAudition.flatMap { audition in segments.firstIndex { $0.id == audition.0 } }
            ?? locatedSegment(at: playhead)?.0 ?? segments.count - 1
        return (edit.timelineClips[index], edit.offsets[index].seconds)
    }

    func sourceID(for url: URL) -> UUID? {
        edit.preparation.sourceMedia.first { $0.value.url == url }?.key
    }

    var audioPreviewSourceTime: Double? {
        guard let (clip, offset) = audioPreviewClip else { return nil }
        return trimAudition?.2.seconds ?? min(clip.sourceEnd, max(clip.sourceStart, clip.sourceStart + playhead - offset))
    }
    var selectedID: UUID? { edit.selectedID }
    var preferredCopyContainer: String? { explicitCopyContainer ?? edit.preparation.container }
    var markIn: Double? { edit.markIn?.seconds }
    var markOut: Double? { edit.markOut?.seconds }
    var duration: Double { edit.duration.seconds }
    var isBusy: Bool { mediaRefreshProgress != nil || isImporting || isExporting || isCheckingEdit || isPreparingCopyBoundaries || isPresentingPanel || isBulkQueuePresented || cutPreview != nil || waitingForExportCleanup }
    /// Window-modal alerts leave the menu bar active, so plain-key edits stay off until the alert closes.
    var canEdit: Bool { !isEmpty && !isBusy && alert == nil }
    var canNavigate: Bool { canEdit || (isImporting && !isEmpty && !isCancelling && alert == nil) }
    var canUndo: Bool { !isBusy && alert == nil && !undoStack.isEmpty }
    var canRedo: Bool { !isBusy && alert == nil && !redoStack.isEmpty }
    var hasHistory: Bool { !undoStack.isEmpty || !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { "Undo \($0.action)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.action)" } ?? "Redo" }
    var deleteTitle: String { rangeTool || markIn != nil || markOut != nil ? "Delete Marked Range" : "Delete Clip" }
    var canActOnRange: Bool { canEdit && selectedSpan != nil }
    var canSplitSelectedRange: Bool {
        guard canEdit, let span = selectedSpan else { return false }
        return isInsideClip(span.from) || isInsideClip(span.to)
    }
    var canDelete: Bool { canActOnRange || (canEdit && !rangeTool && selectedID != nil) }
    var canClearMarks: Bool { !isBusy && (markIn != nil || markOut != nil) }
    var canMoveEarlier: Bool { canEdit && selectedTimelineItem.map { $0 > 0 } == true }
    var canMoveLater: Bool { canEdit && selectedTimelineItem.map { $0 < timelineClips.count - 1 } == true }

    private var selectedTimelineItem: Int? { timelineClips.firstIndex { $0.id == selectedID } }

    private var selectedClipIndex: Int? { segments.firstIndex { $0.id == selectedID } }

    func seekUsingTimeField() {
        guard canNavigate else { return }
        timeEntryRequest += 1
    }

    func moveSelectedClip(by direction: Int) {
        guard direction < 0 ? canMoveEarlier : canMoveLater, let index = selectedTimelineItem else { return }
        asking(true) { moveTimelineItem(timelineClips[index].id, to: index + (direction < 0 ? -1 : 2)) }
    }

    func canTrimSelected(_ edge: TimelineEdge, restore: Bool) -> Bool {
        guard canEdit, let index = selectedClipIndex else { return false }
        let clip = segments[index]
        if restore { return edge == .start ? clip.start > .zero : clip.end < clip.source.duration }
        let offset = edit.offsets[index].seconds
        return playhead > offset && playhead < offset + clip.duration.seconds
    }

    func trimSelected(_ edge: TimelineEdge, restore: Bool = false) {
        guard canTrimSelected(edge, restore: restore), let index = selectedClipIndex else { return }
        let clip = segments[index]
        let sourceTime = restore ? (edge == .start ? 0 : clip.source.duration.seconds)
            : clip.start.seconds + playhead - edit.offsets[index].seconds
        let snap = !restore && usesPointerPosition ? TimelineSnapTarget.off : effectiveSnapTarget
        if snap == .keyframes && usesBackgroundTrimValidation {
            validateHandle(clip.id, edge: edge, target: sourceTime, commit: true) { _ in }
        } else {
            _ = asking(true) { trim(clip.id, edge: edge, sourceTime: sourceTime, commit: true, snap: snap) }
        }
    }

    func showExportInFinder() {
        guard let url = lastExportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var markedRange: ClosedRange<Double>? {
        selectedSpan.map { $0.from.seconds...$0.to.seconds }
    }

    var formatSummary: String? {
        if let format = stillProject.stillFormat { return "\(format.width) × \(format.height) · \(format.codec.rawValue.uppercased())" }
        guard let media = segments.first?.source.media else { return nil }
        guard let video = media.videoStream else {
            let audio = media.primaryStream
            return "\(audio.codec.uppercased()) · \(audio.sampleRate) Hz · \(audio.channels) ch"
        }
        let hasDisplaySize = video.displayWidth > 0 && video.displayHeight > 0
        let width = hasDisplaySize ? video.displayWidth : video.width
        let height = hasDisplaySize ? video.displayHeight : video.height
        // On a mixed timeline the first clip's size is the canvas every clip is fitted into, and its codec is only its own.
        return isMixedTimeline ? "\(width) × \(height) · Mixed formats" : "\(width) × \(height) · \(video.codec.uppercased())"
    }

    func chooseFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Clips"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        isPresentingPanel = true
        let currentSession = session
        present(panel) { [weak self] accepted in
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            if accepted { self.importFiles(panel.urls) }
            self.resumePendingWork()
        }
    }

    func openFiles(_ urls: [URL]) {
        pendingOpenFiles.append(contentsOf: urls.filter(\.isFileURL))
        resumePendingWork()
    }

    private func resumePendingWork() {
        guard !isBusy, alert == nil else { return }
        guard !pendingOpenFiles.isEmpty else {
            requestSnapAnalysis()
            return
        }
        let files = pendingOpenFiles
        pendingOpenFiles.removeAll()
        importFiles(files)
    }

    func cancelImport() {
        guard isImporting else { return }
        isCancelling = true
        cancellation?.cancel()
    }

    func dismissNotice() {
        alert = nil
        resumePendingWork()
    }

    func importFiles(_ urls: [URL], at index: Int? = nil, allowCommit: (() -> Bool)? = nil) {
        if allowCommit == nil {
            let images = urls.filter(StillPanels.isSupportedImage)
            if !images.isEmpty {
                let media = urls.filter { !StillPanels.isSupportedImage($0) }
                if media.isEmpty {
                    addDroppedStills(images, at: playhead)
                } else {
                    pendingOpenFiles.insert(contentsOf: images, at: 0)
                    importFiles(media, at: index, projectClips: nil, asksBeforeLoweringTier: true)
                }
                return
            }
        }
        // Clips added in the editor ask before lowering the tier. A remote import, which supplies `allowCommit`, does not.
        importFiles(urls, at: index, projectClips: nil, allowCommit: allowCommit, asksBeforeLoweringTier: allowCommit == nil)
    }

    private func importFiles(_ urls: [URL], at index: Int? = nil, projectClips: [CutSequenceClip]?,
                             historyAction: String? = nil, openingMedia: [String: String] = [:],
                             beforeInstall: (() throws -> Bool)? = nil, allowCommit: (() -> Bool)? = nil,
                             requestCancellation: EditCancellation? = nil, installed: (() -> Void)? = nil,
                             restoringAudioMonitoring: AudioMonitoring? = nil,
                             sequenceProject: CutProject? = nil,
                             asksBeforeLoweringTier asks: Bool = false,
                             completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard !isBusy, !urls.isEmpty else {
            completion?(.failure(CutError(code: "editor_busy", message: "The editor could not start loading the media.")))
            return
        }
        refreshSidecarExclusions(adding: urls, openingMedia: openingMedia)
        cancelTrim()
        preview.pause()
        let token = requestCancellation ?? EditCancellation()
        cancellation = token
        let preference = sidecarPreference
        let engine = CutEngine(cancelled: { token.isCancelled })
        let existing = projectClips == nil ? segments : []
        let priorPreparation = edit.preparation
        let publishPartial = allowCommit == nil && requestCancellation == nil
        let beforeImport = snapshot()
        committedBeforeImport = beforeImport.stillSequence.map(CutProject.stillSequence) ?? .sequence(beforeImport.documentClips)
        let insertion = min(max(0, index ?? existing.count), existing.count)
        let currentSession = session
        let pendingWrite = lastSidecarWrite?.task
        importProgress = 0
        isImporting = true
        Task {
            // A quick Close Video and reopen must see the last accepted edits.
            await pendingWrite?.value
            let result = await Task.detached(priority: .utility) {
                var additions: [EditorSegment] = []
                var rejected: [String] = []
                var savedAnalysis: [UUID: SavedEditorAnalysis] = [:]
                var indexed = Dictionary(existing.map { ($0.source.url, $0.source) }, uniquingKeysWith: { first, _ in first })
                for clip in existing where indexed[clip.source.originalURL] == nil {
                    indexed[clip.source.originalURL] = clip.source
                }
                var documentSources: [DocumentSourceKey: IndexedSource] = [:]
                var pictureReference = existing.first?.source.media
                var ordinaryReference = existing.first(where: { !$0.source.isAudioReplacement })?.source.media
                var lastPublication: ContinuousClock.Instant?
                var prior = priorPreparation
                for (offset, file) in urls.enumerated() {
                    if token.isCancelled { break }
                    let report: @Sendable (Double) -> Void = { fraction in
                        let total = (Double(offset) + fraction) / Double(urls.count)
                        guard token.shouldReport(total) else { return }
                        DispatchQueue.main.async {
                            guard self.cancellation === token, self.isImporting, !token.isCancelled else { return }
                            self.importProgress = total
                        }
                    }
                    defer { if !token.isCancelled { report(1) } }
                    let canonical = file.standardizedFileURL
                    let document = projectClips?[offset]
                    let original = document?.originalFile.map { URL(fileURLWithPath: $0).standardizedFileURL }
                    var provisional: EditorSegment?
                    do {
                        let source: IndexedSource
                        let cached = indexed[canonical]
                        if let cached {
                            try AnalysisSidecar(media: cached.media).checkSource()
                            source = cached
                        } else {
                            func read(_ preview: Bool, identity: SourceIdentity? = nil) async throws -> MediaInfo {
                                while !token.isCancelled {
                                    let settings = preference.indexSettings(for: canonical)
                                    do {
                                        let key = SourceIndexLoader.Key(url: canonical, sidecars: settings.enabled,
                                                                        preview: preview, identity: identity,
                                                                        preferCompleted: preview)
                                        let index = try await SourceIndexLoader.shared.read(key, token: token,
                                            preference: settings.change, progress: report)
                                        return index.ordinary
                                    } catch is CancellationError where settings.change.isCancelled && !token.isCancelled {
                                        continue
                                    }
                                }
                                throw CancellationError()
                            }

                            let canPublishPreview = publishPartial && projectClips == nil && existing.isEmpty && additions.isEmpty
                            let header = canPublishPreview ? try? await read(true) : nil
                            if let preview = header, !preview.hasFullEditIndex, preview.timelineIssue == nil {
                                let clip = EditorSegment(source: IndexedSource(media: preview))
                                provisional = clip
                                let prepared = PreparedEdit(segments: [clip], previous: prior, engine: engine)
                                await MainActor.run {
                                    guard self.session == currentSession, !token.isCancelled else { return }
                                    self.apply([clip], prepared: prepared, selecting: clip.id, at: 0,
                                               action: "Add Clip", recordHistory: false)
                                }
                            }
                            let media: MediaInfo
                            if let header, header.hasFullEditIndex {
                                media = header
                            } else {
                                media = try await read(false, identity: header?.identity)
                            }
                            try Self.checkEditable(media)
                            source = IndexedSource(media: media, id: provisional?.source.id ?? UUID())
                            if preference.permits(canonical) {
                                savedAnalysis[source.id] = SavedEditorAnalysis(media: media, cancelled: { token.isCancelled || !preference.permits(canonical) })
                            }
                        }
                        let isReplacement = document == nil ? source.isAudioReplacement
                            : original.map { $0 != canonical } == true && document?.audioTrack != nil
                        if let pictureReference, pictureReference.hasVideo != source.media.hasVideo {
                            throw CutError(code: "incompatible_clip", message:
                                "Add sound-only recordings to an audio timeline. To change a video's soundtrack, choose File → Replace Source Audio.")
                        }
                        if cached == nil || document != nil {
                            // A movie in another format may join the timeline: Re-encode writes a mixed timeline, and the
                            // tier question below asks before it becomes one. Clips that copy together pass as before.
                            if let ordinaryReference, !isReplacement {
                                try engine.checkEncodeCombinable(source.media, with: ordinaryReference)
                            } else if let pictureReference {
                                // Replacement can change a soundtrack's format, while preserving the picture and track count.
                                // On a mixed timeline its picture may differ from the first clip's like any other clip's.
                                let matches = (try? engine.checkPictureCompatibility(source.media, with: pictureReference)) != nil
                                    && source.media.audio.count == pictureReference.audio.count
                                if !matches { try engine.checkEncodeCombinable(source.media, with: pictureReference) }
                            }
                        }
                        if pictureReference == nil { pictureReference = source.media }
                        if ordinaryReference == nil && !isReplacement { ordinaryReference = source.media }
                        indexed[canonical] = source
                        if let document {
                            guard document.from >= .zero, document.from < document.to, document.to <= source.duration else {
                                throw CutError(code: "project_clip_range", message: "The saved trim exceeds the recording duration.")
                            }
                            let original = original ?? source.url
                            let key = DocumentSourceKey(file: source.url, original: original, track: document.audioTrack,
                                                        names: document.replacementNames)
                            let restored: IndexedSource
                            if let cached = documentSources[key] {
                                restored = cached
                            } else if source.originalURL == original, source.replacementTrack == document.audioTrack,
                               source.replacementNames == document.replacementNames {
                                restored = source
                            } else {
                                let trackCount = source.media.streams.filter { $0.kind == "audio" }.count
                                guard document.audioTrack.map({ $0 < trackCount }) ?? true,
                                      document.replacementNames.keys.allSatisfy({ $0 < trackCount }) else {
                                    throw CutError(code: "project_audio_track", message: "A saved audio track is missing from the recording.")
                                }
                                restored = IndexedSource(media: source.media, originalURL: original,
                                                         replacementNames: document.replacementNames, replacementTrack: document.audioTrack)
                                savedAnalysis[restored.id] = savedAnalysis[source.id]
                            }
                            documentSources[key] = restored
                            additions.append(EditorSegment(documentID: document.id, source: restored, start: document.from, end: document.to))
                        } else {
                            additions.append(EditorSegment(id: provisional?.id ?? UUID(), source: source))
                        }
                        if publishPartial, projectClips == nil, offset + 1 < urls.count, lastPublication.map({ $0.duration(to: .now) >= .milliseconds(250) }) ?? true {
                            var partial = existing
                            partial.insert(contentsOf: additions, at: insertion)
                            let clips = partial
                            let prepared = PreparedEdit(segments: clips, previous: prior, engine: engine)
                            prior = prepared
                            await MainActor.run {
                                guard self.session == currentSession, !token.isCancelled else { return }
                                self.apply(clips, prepared: prepared, selecting: clips[insertion].id,
                                           at: self.playhead, action: "Add Clips", recordHistory: false,
                                           preservePreview: true)
                            }
                            lastPublication = .now
                        }
                    } catch {
                        if provisional != nil {
                            await MainActor.run {
                                guard self.session == currentSession, !token.isCancelled else { return }
                                self.mcpRevision += 1
                                self.edit = beforeImport
                                self.refreshTier()
                                self.syncWaveforms()
                                self.restorePreview(at: beforeImport.playhead)
                                self.updateStatus()
                            }
                        }
                        rejected.append("\(file.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                var candidate = existing
                candidate.insert(contentsOf: additions, at: insertion)
                let prepared = PreparedEdit(segments: candidate, previous: prior, engine: engine)
                return (candidate, additions.count, rejected, prepared, savedAnalysis)
            }.value

            var outcome: Result<Void, Error> = .failure(CutError(code: "cancelled", message: "Media loading was cancelled."))
            defer { completion?(outcome) }
            guard session == currentSession else {
                outcome = .failure(CutError(code: "project_closed", message: "The project closed or changed while loading media."))
                return
            }
            // Joining more clips can lower the tier. Ask once for all of them while the import is still in progress,
            // so that declining restores the timeline exactly as cancelling does.
            var declined = false
            // Clips in different formats dropped into an empty editor make a mixed timeline at once. They are measured
            // against the first of them, so the question is asked there too.
            let startsMixed = existing.isEmpty && result.1 > 1 && result.3.isMixed
            if asks, projectClips == nil, !existing.isEmpty || startsMixed, result.1 > 0, !token.isCancelled, allowCommit?() != false {
                let candidate = result.0, action = result.1 == 1 ? "Add Clip" : "Add Clips"
                let baseline = existing.isEmpty ? Array(candidate.prefix(1)) : existing
                declined = await withCheckedContinuation { continuation in
                    self.asking(true) {
                        self.confirmTier(from: baseline, to: candidate, action: action, offersNearest: false,
                                         abandoned: { continuation.resume(returning: true) }) {
                            continuation.resume(returning: $0 == nil)
                        }
                    }
                }
                guard session == currentSession else {
                    outcome = .failure(CutError(code: "project_closed", message: "The project closed or changed while loading media."))
                    return
                }
            }
            committedBeforeImport = nil
            isImporting = false
            isCancelling = false
            cancellation = nil
            defer {
                refreshSidecarExclusions()
                openingProjectURL = nil
                if deferredDraftSave {
                    updateStatus()
                    saveUntitledDraft()
                }
                resumePendingWork()
            }
            if declined || token.isCancelled || allowCommit?() == false {
                if publishPartial && projectClips == nil {
                    mcpRevision += 1
                    edit = beforeImport
                    refreshTier()
                    prepareCopyBoundaries()
                    syncWaveforms()
                    restorePreview(at: beforeImport.playhead)
                }
                updateStatus()
                return
            }
            if projectClips != nil, !result.2.isEmpty {
                let title = historyAction.map { "Couldn’t Restore “\($0)”" } ?? "Couldn’t Open Project"
                let message = result.2.joined(separator: "\n\n")
                outcome = .failure(CutError(code: "import_incomplete", message: message))
                if completion == nil { alert = EditorNotice(title: title, message: message) }
                return
            }
            if result.1 > 0 {
                do { guard try beforeInstall?() ?? true else { return } }
                catch {
                    outcome = .failure(error)
                    if completion == nil {
                        alert = EditorNotice(title: "Couldn’t Open Project", message: error.localizedDescription)
                    }
                    return
                }
                if useAnalysisSidecars && !result.4.isEmpty {
                    for (id, saved) in result.4 {
                        if let report = saved.report {
                            sceneReports[id] = report
                            scenesBySource[id] = saved.markers
                            viewNamesBySource[id] = saved.names
                        }
                        for (track, value) in saved.thresholdsByTrack {
                            thresholdOverrides[AudioTrackKey(source: id, track: track)] = value
                        }
                    }
                    sceneRevision += 1
                }
                let applied = apply(result.0, prepared: result.3, selecting: result.0[insertion].id, at: projectClips == nil ? playhead : 0,
                      action: result.1 == 1 ? "Add Clip" : "Add Clips", recordHistory: projectClips == nil, historySnapshot: beforeImport,
                      preservePreview: true, restoringAudioMonitoring: restoringAudioMonitoring,
                      sequenceProject: sequenceProject)
                if applied {
                    outcome = .success(())
                    if projectClips != nil { installed?() }
                } else {
                    outcome = .failure(CutError(code: "import_incomplete", message: alert?.message ?? "The editor could not install the media."))
                    if completion != nil { alert = nil }
                }
                if useAnalysisSidecars {
                    let restored = Set(result.4.compactMap { $0.value.thresholdsByTrack.isEmpty ? nil : $0.key })
                    if !restored.isEmpty { refreshDetectedPauses(invalidating: restored) }
                }
            }
            if !result.2.isEmpty {
                alert = EditorNotice(title: result.2.count == 1 ? "Couldn’t Add Clip" : "Couldn’t Add Some Clips",
                                     message: result.2.joined(separator: "\n\n"))
            }
        }
    }

    func select(_ id: UUID) {
        guard !isBusy, timelineClips.contains(where: { $0.id == id }) else { return }
        if edit.selectedID != id { edit.selectedID = id }
    }

    func seek(_ time: Double) {
        guard time.isFinite, canNavigate else { return }
        usesPointerPosition = false
        cancelTrim()
        preview.pause()
        playhead = min(max(0, time), duration)
        preview.seek(to: playhead)
    }

    func seekFromPointer(_ time: Double) {
        guard time.isFinite, canNavigate else { return }
        seek(time)
        usesPointerPosition = true
    }

    func scrub(_ position: Double) {
        guard position.isFinite, canNavigate else { return }
        let target = min(max(position, 0), duration)
        guard let index = locatedSegment(at: target)?.0 ?? (target == duration ? segments.indices.last : nil) else {
            preview.seek(to: target)
            usesPointerPosition = true
            return
        }
        let segment = segments[index]
        let local = segment.start.seconds + (target - edit.offsets[index].seconds)
        let picture = heldPicture(in: segment, at: local)
        preview.scrub(to: target, rangeIndex: index, sourceFrame: picture?.seconds ?? local)
        usesPointerPosition = true
    }

    private func heldPicture(in segment: EditorSegment, at local: Double) -> RationalTime? {
        let frames = segment.source.frames
        guard !frames.isEmpty else { return nil }
        let next = frames.lowerBound { $0.seconds > local + 1e-9 || $0 >= segment.end }
        return max(segment.start, next > 0 ? frames[next - 1] : segment.start)
    }

    private var currentScene: (source: UUID, report: SceneReport, index: Int, canRename: Bool)? {
        guard let (_, clip, offset) = locatedSegment(at: playhead),
              let report = sceneReport(for: clip), !report.scenes.isEmpty else { return nil }
        let local = clip.start.seconds + playhead - offset.seconds
        let i = max(0, report.scenes.lowerBound { $0.startSeconds > local + 1e-9 } - 1)
        return (clip.source.id, report, i, sceneRangeReports[ClipSceneRange(clip)] == nil)
    }

    var currentSceneLabel: String? {
        guard let current = currentScene else { return nil }
        let view = current.report.scenes[current.index].view
        let name = current.report.views.first(where: { $0.view == view })?.name ?? "View \(SceneView.label(for: view))"
        let count = current.report.viewCount == 1 ? "1 view" : "\(current.report.viewCount) views"
        return "Scene \(current.index + 1)/\(current.report.scenes.count) · \(name) · \(count)"
    }

    var canRenameCurrentView: Bool { canEdit && currentScene?.canRename == true }

    func renameCurrentView() {
        guard canRenameCurrentView, let current = currentScene, let window = sheetWindow else { return }
        preview.pause()
        let view = current.report.scenes[current.index].view
        let defaultName = "View \(SceneView.label(for: view))"
        let prompt = NSAlert()
        prompt.messageText = "Rename \(defaultName)"
        prompt.informativeText = "All scenes with this view will use the new name. Clear the field to restore the default."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
        field.toolTip = "Enter view name"
        field.placeholderString = defaultName
        field.stringValue = viewNamesBySource[current.source]?[view] ?? ""
        field.setAccessibilityLabel("View name")
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Save").toolTip = "Save view name"
        prompt.addButton(withTitle: "Cancel").toolTip = "Cancel rename"
        prompt.window.initialFirstResponder = field
        isPresentingPanel = true
        let currentSession = session
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            if response == .alertFirstButtonReturn {
                self.setViewName(field.stringValue, source: current.source, view: view)
            }
            self.resumePendingWork()
        }
    }

    func setViewName(_ text: String, source: UUID, view: Int) {
        guard let report = sceneReports[source], view > 0, view <= report.viewCount else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = name.isEmpty ? nil : name
        sceneReports[source]?.setViewName(edit, for: view)
        viewNamesBySource[source, default: [:]][view] = edit
        if let media = self.edit.preparation.sourceMedia[source] {
            sceneScan.cache.setViewName(edit, view: view, for: media)
            persistMetadata(edit, key: view, section: AnalysisSidecar.viewNameSectionKey, media: media,
                            seed: viewNamesBySource[source] ?? [:], source: source,
                            edits: EditorMetadataEdits(names: [view: edit]))
        }
        sceneRevision += 1
    }

    // Manual saves and individual metadata edits publish in the order the editor accepted them.
    private func enqueueSidecarWrite(_ operation: @escaping @MainActor () async -> Void) {
        let previous = lastSidecarWrite?.task
        let id = UUID()
        let task = Task {
            await previous?.value
            await operation()
            if lastSidecarWrite?.id == id { lastSidecarWrite = nil }
        }
        lastSidecarWrite = (id, task)
    }

    private func persistMetadata<Value: Codable & Sendable>(_ value: Value?, key: Int, section: String, media: MediaInfo,
                                                           seed: [Int: Value], source: UUID, edits: EditorMetadataEdits) {
        let preference = sidecarPreference
        let automatic = preference.permits(media.url)
        let currentSession = session
        enqueueSidecarWrite {
            var saved = false
            if automatic && preference.permits(media.url) {
                saved = await Task.detached(priority: .utility) {
                    do {
                        try AnalysisSidecar(media: media).save([:], updating: [section: { old in
                            let values = EditorMetadataEdits.merged(old, seed: seed, edits: [key: value])
                            return try JSONEncoder().encode(values)
                        }], cancelled: { !preference.permits(media.url) })
                        return true
                    } catch {
                        return false
                    }
                }.value
            }
            if self.session == currentSession {
                self.pendingMetadata[source, default: EditorMetadataEdits()].update(edits, saved: saved)
            }
        }
    }

    private func updateSnapTarget() {
        // A shared setting invalidates pending keyframe checks. Another window's
        // picker must leave the currently auditioned trim in place until release.
        if isCommittingHandle {
            cancelTrim()
        } else {
            cancelHandleValidation()
        }
        usesPointerPosition = false
        checkingTrim = nil
        trimChecks.removeAll()
        snapScanRequests.removeAll()
        prepareCopyBoundaries()
        rebuildPausePlan()
        resumePendingWork()
    }

    /// Selecting a target requests its missing analysis once. Cancelling a scan
    /// leaves it cancelled across ordinary edits on the same sources.
    private func requestSnapAnalysis() {
        if !snapScanRequests.isEmpty { snapScanRequests.formIntersection(edit.preparation.sourceMedia.keys) }
        guard canEdit else { return }
        switch effectiveSnapTarget {
        case .silence where refreshStaleSilence.isEmpty && canScanSilence && !hasSilenceResults:
            let missing = activeAudioSources.subtracting(sourcePauses.keys)
            guard !missing.isSubset(of: snapScanRequests) else { return }
            snapScanRequests.formUnion(missing)
            scanForSilence()
        default:
            break
        }
    }

    func cancelSceneAnalysisFromEditor() {
        mcpSceneReceipt?.cancelFromEditor()
    }

    func cancelSceneAnalysis() {
        sceneScan.cancel()
        sceneRevision += 1
    }

    func invalidateSceneScan(for source: UUID) {
        sceneScan.invalidateInspection()
        sceneRangeReports = sceneRangeReports.filter { $0.key.source != source }
        sceneOverlays = sceneOverlays.filter { $0.key.source != source }
        sourceSceneOverlays[source] = nil
        if sceneScan.requests.contains(where: { request in
            request.id == source.uuidString || previousSceneClip?.source == source
        }) {
            mcpSceneReceipt?.finish("cancelled")
            mcpSceneReceipt = nil
            sceneScan.reset(preservingCheckpoints: true)
            previousSceneClip = nil
        }
        sceneRevision += 1
    }

    var canScanScenes: Bool {
        canScanScenes(clipID: nil) && segments.contains { $0.source.media.hasVideo && sceneReports[$0.source.id] == nil }
    }

    func canScanScenes(clipID: UUID?) -> Bool {
        canEdit && sceneProgress == nil && !sceneRequests(clipID: clipID).isEmpty
    }

    private func sceneRequests(clipID: UUID?) -> [EditorSceneRequest] {
        if let clipID {
            guard let clip = segments.first(where: { $0.id == clipID && $0.source.isIndexed && $0.source.media.hasVideo }),
                  mediaReviewIssue(clip) == nil, clip.start < clip.end else { return [] }
            return [EditorSceneRequest(id: clip.id.uuidString, media: clip.source.media,
                                       scope: .range(start: clip.start, end: clip.end))]
        }
        var seen = Set<UUID>()
        return segments.compactMap { clip in
            let source = clip.source
            guard source.isIndexed, source.media.hasVideo, !offlineMedia.contains(source.url),
                  !incompatibleMedia.contains(source.url), seen.insert(source.id).inserted else { return nil }
            return EditorSceneRequest(id: source.id.uuidString, media: source.media)
        }
    }

    func staleSceneReport(clipID: UUID) -> (UUID, SceneReport)? {
        guard let clip = segments.first(where: { $0.id == clipID }) else { return nil }
        let source = clip.source.id
        guard let stale = staleSceneRangeReports[ClipSceneRange(clip)] ?? staleSceneReports[source] else { return nil }
        return (source, stale)
    }

    func sceneReport(clipID: UUID) -> (UUID, SceneReport)? {
        guard let clip = segments.first(where: { $0.id == clipID }), let report = sceneReport(for: clip) else { return nil }
        return (clip.source.id, report)
    }

    private func sceneReport(for clip: EditorSegment) -> SceneReport? {
        sceneRangeReports[ClipSceneRange(clip)] ?? sceneReports[clip.source.id]
    }

    var canSaveAnalysisSidecars: Bool { canEdit && !isSavingSidecars }

    func saveAnalysisSidecars() {
        guard canSaveAnalysisSidecars else { return }
        var seen = Set<URL>()
        let snapshots = segments.compactMap { clip -> DesktopAnalysisSnapshot? in
            let source = clip.source
            guard seen.insert(source.url).inserted else { return nil }
            let audio = source.media.streams.filter { $0.kind == "audio" }
            let overrides = Dictionary(uniqueKeysWithValues: audio.enumerated().compactMap { (track, stream) -> (Int, Double)? in
                thresholdOverrides[AudioTrackKey(source: source.id, track: track)].map { (stream.index, $0) }
            })
            return DesktopAnalysisSnapshot(sourceID: source.id, media: source.media, scenes: sceneReports[source.id],
                                          viewNames: viewNamesBySource[source.id] ?? [:],
                                          thresholdOverrides: overrides,
                                          edits: EditorMetadataEdits(),
                                          waveforms: audioStore.completedWaveforms(for: source.id, media: source.media),
                                          envelopeOverviews: audioStore.completedEnvelope(for: source.id, media: source.media),
                                          silence: completedSilences(for: source.id),
                                          filmstrip: filmstripTiles.snapshot(for: source.id))
        }
        let excluded = CutProject.sidecarExclusions(absoluteSources: protectedMedia, candidates: snapshots.map { $0.media.url })
        if let conflict = snapshots.first(where: { AnalysisSidecar.isExcluded($0.media.url, in: excluded) }) {
            alert = EditorNotice(title: "Couldn’t Save Analysis",
                                 message: "The analysis file for ‘\(conflict.media.url.lastPathComponent)’ would overwrite media referenced by this project.")
            return
        }
        let token = EditCancellation()
        sidecarSaveToken = token
        let receipt = mcpSidecarReceipt
        let outputs = receipt.map { _ in MCPLiveOutputProgress() }
        let endWork = receipt?.cleanup.begin()
        receipt?.cancelNative = { token.cancel() }
        receipt?.cancelledDetail = { outputs?.snapshot ?? [:] }
        receipt?.nativeProgress = { outputs?.snapshot["progress"] as? Double }
        isSavingSidecars = true
        statusMessage = "Saving analysis sidecars…"
        let checkpointRequests = Dictionary(grouping: sceneScan.checkpointRequests, by: { $0.media.identity })
        let sceneCache = sceneScan.cache
        enqueueSidecarWrite { [self] in
            defer { endWork?() }
            guard sidecarSaveToken === token else { return }
            // An earlier autosave may have committed since these snapshots were captured.
            let snapshots = snapshots.map { original in
                var snapshot = original
                snapshot.edits = pendingMetadata[snapshot.sourceID] ?? EditorMetadataEdits()
                return snapshot
            }
            let (saved, failures, checkpoints) = await Task.detached(priority: .utility) {
                var saved: [UUID] = []
                var checkpoints: [(String, SceneScanProgress)] = []
                var failures: [String] = []
                for snapshot in snapshots {
                    if token.isCancelled { break }
                    do {
                        try snapshot.save(cancelled: { token.isCancelled })
                        for item in checkpointRequests[snapshot.media.identity] ?? [] {
                            if token.isCancelled { break }
                            if let progress = try SceneAnalysis.saveCheckpoint(for: snapshot.media, scope: item.scope, session: sceneCache) {
                                checkpoints.append((item.id, progress))
                            }
                        }
                        saved.append(snapshot.sourceID)
                        outputs?.published(AnalysisSidecar.url(for: snapshot.media.url))
                        outputs?.update(Double(saved.count) / Double(snapshots.count))
                    } catch {
                        if token.isCancelled { break }
                        failures.append("\(snapshot.media.url.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                return (Set(saved), failures, checkpoints)
            }.value
            guard sidecarSaveToken === token else { return }
            for (id, progress) in checkpoints { sceneScan.didSaveCheckpoint(id, progress: progress) }
            if !checkpoints.isEmpty { sceneRevision += 1 }
            for snapshot in snapshots where saved.contains(snapshot.sourceID) {
                pendingMetadata[snapshot.sourceID]?.discardSaved(snapshot.edits)
            }
            isSavingSidecars = false
            sidecarSaveToken = nil
            let paths = snapshots.filter { saved.contains($0.sourceID) }.map { AnalysisSidecar.url(for: $0.media.url).path }
            receipt?.finish(token.isCancelled ? "cancelled" : (failures.isEmpty ? "succeeded" : "failed"),
                            detail: ["outputs": paths, "errors": failures])
            mcpSidecarReceipt = nil
            let count = saved.count
            statusMessage = count == 1 ? "Saved 1 analysis sidecar" : "Saved \(count) analysis sidecars"
            if !failures.isEmpty {
                alert = EditorNotice(title: "Couldn’t Save Analysis", message: failures.joined(separator: "\n\n"))
            }
        }
    }

    var canStepScenes: Bool {
        guard canEdit, hasPicture, sceneProgress == nil else { return false }
        if segments.count > 1, segments.allSatisfy({ sceneReport(for: $0) != nil }) { return true }
        return segments.contains { clip in
            guard let scenes = sceneReport(for: clip)?.scenes else { return false }
            let cut = scenes.lowerBound { $0.start > clip.start }
            return cut < scenes.count && scenes[cut].start < clip.end
        }
    }

    func scanForScenes(clipID: UUID? = nil, policy: SceneScanPolicy = .reuse) {
        guard canScanScenes(clipID: clipID) else { return }
        let clip = clipID.flatMap { id in segments.first { $0.id == id } }.map(ClipSceneRange.init)
        runSceneRequests(sceneRequests(clipID: clipID), clip: clip, policy: policy)
    }

    func repeatSceneScan(policy: SceneScanPolicy) {
        guard canEdit, sceneProgress == nil else { return }
        if sceneScan.requests.isEmpty {
            scanForScenes(policy: policy)
        } else {
            runSceneRequests(sceneScan.requests, clip: previousSceneClip, policy: policy)
        }
    }

    func confirmSceneRestart(clipID: UUID? = nil, paused: Bool, repeatPrevious: Bool = false) {
        guard let window = sheetWindow else { return }
        let requests = repeatPrevious ? sceneScan.requests : sceneRequests(clipID: clipID)
        let clip = repeatPrevious ? previousSceneClip
            : clipID.flatMap { id in segments.first { $0.id == id } }.map(ClipSceneRange.init)
        let prompt = NSAlert()
        prompt.messageText = paused ? "Restart scene analysis?" : "Scan for scenes again?"
        prompt.informativeText = "MPCut will start a new analysis for this footage."
        prompt.addButton(withTitle: paused ? "Restart" : "Scan Again").toolTip = "Restart scene scan"
        prompt.addButton(withTitle: "Cancel").toolTip = "Keep existing scene analysis"
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canEdit, self.sceneProgress == nil else { return }
            self.runSceneRequests(requests, clip: clip, policy: .restart(operationID: UUID().uuidString))
        }
    }

    private func runSceneRequests(_ requests: [EditorSceneRequest], clip: ClipSceneRange?, policy: SceneScanPolicy) {
        guard !requests.isEmpty else { return }
        previousSceneClip = clip
        let receipt = mcpSceneReceipt ?? MCPAnalysisReceipt(owner: "", revision: 0, kind: "scenes")
        mcpSceneReceipt = receipt
        receipt.sceneRequest = MCPSceneRequest(target: clip?.clip.uuidString, policy: policy,
                                               interval: clip.map { .range(start: $0.start, end: $0.end) })
        receipt.nativeProgress = { [weak self] in self?.sceneProgress }
        receipt.sceneCoverage = { [weak self] in self?.sceneCoverage ?? [:] }
        receipt.cancelNative = { [weak self] in self?.cancelSceneAnalysis() }
        sceneScan.start(requests, policy: policy, preference: sidecarPreference,
                        receipt: receipt, update: { [weak self] in
            guard let self else { return }
            self.sceneRevision += 1
            if self.sceneScan.progress == nil {
                if self.mcpSceneReceipt === receipt { self.mcpSceneReceipt = nil }
                self.requestSnapAnalysis()
            }
        }, markers: { [weak self] request, batch, reset, progress in
            guard let self, let id = UUID(uuidString: request.id), let progress else { return }
            let current = clip.flatMap { self.sceneOverlays[$0] } ?? self.sourceSceneOverlays[id]
            let previous = reset ? [] : (current?.scenes ?? [])
            let added = batch.map { TimelineScene(start: $0.time.seconds, view: $0.view) }
            let next = TimelineSceneOverlay(scenes: previous + added, from: request.start.seconds,
                                            to: progress.confirmed?.seconds ?? request.start.seconds)
            if let clip {
                if self.sceneRangeReports[clip] == nil, self.sceneReports[clip.source] == nil {
                    self.sceneOverlays[clip] = next
                }
            } else if self.sceneReports[id] == nil {
                self.sourceSceneOverlays[id] = next
            }
        }, report: { [weak self] request, report, state in
            guard let self, let id = UUID(uuidString: request.id) else { return }
            if let clip {
                if state == .upToDate, self.sceneRangeReports[clip] != nil || self.sceneReports[clip.source] != nil {
                    if self.sceneRangeReports[clip] == nil { self.sceneOverlays[clip] = nil }
                    return
                }
                self.sceneRangeReports[clip] = report
                self.sceneOverlays[clip] = Self.sceneOverlay(report, for: clip)
            } else {
                self.installSceneReport(report, for: id, replacing: state != .upToDate)
            }
        })
    }

    private static func sceneOverlay(_ report: SceneReport, for clip: ClipSceneRange) -> TimelineSceneOverlay {
        TimelineSceneOverlay(
            scenes: report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) },
            from: clip.start.seconds, to: report.scenes.last?.end.seconds ?? clip.end.seconds,
            leadingIsCut: !report.syntheticLeading,
            names: Dictionary(uniqueKeysWithValues: report.views.compactMap { view in
                view.name.map { (view.view, $0) }
            }))
    }

    private func installSceneReport(_ report: SceneReport, for id: UUID, replacing: Bool = false) {
        guard replacing || sceneReports[id] == nil else { return }
        sourceSceneOverlays[id] = nil
        refreshStaleScenes.remove(id)
        sceneReports[id] = report
        viewNamesBySource[id] = Dictionary(uniqueKeysWithValues: report.views.compactMap { view in
            view.name.map { (view.view, $0) }
        })
        scenesBySource[id] = report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) }
        sceneRevision += 1
    }

    func stepScene(_ direction: Int) {
        guard direction != 0, canStepScenes else { return }
        let indices = direction > 0 ? Array(segments.indices) : Array(segments.indices.reversed())
        let coversSequence = segments.allSatisfy { sceneReport(for: $0) != nil }
        for i in indices {
            let clip = segments[i], offset = edit.offsets[i].seconds
            guard let report = sceneReport(for: clip) else { continue }
            let end = offset + clip.duration.seconds
            if direction > 0 && end <= playhead + 1e-9 { continue }
            if direction < 0 && offset >= playhead - 1e-9 { continue }
            let local = clip.start.seconds + playhead - offset
            if direction > 0, coversSequence, offset > playhead + 1e-9 { seek(offset); return }
            let scenes = report.scenes.dropFirst(report.syntheticLeading ? 1 : 0)
            if direction > 0 {
                let index = scenes.lowerBound { $0.startSeconds > local + 1e-9 && $0.start >= clip.start }
                if index < scenes.endIndex, scenes[index].start < clip.end {
                    seek(offset + scenes[index].startSeconds - clip.start.seconds)
                    return
                }
            } else {
                let index = scenes.lowerBound { $0.startSeconds >= min(local - 1e-9, clip.end.seconds) } - 1
                if index >= scenes.startIndex, scenes[index].start >= clip.start {
                    seek(offset + scenes[index].startSeconds - clip.start.seconds)
                    return
                }
                if coversSequence { seek(offset); return }
            }
        }
    }

    func step(_ direction: Int, keyframes: Bool = false) {
        guard canEdit, direction != 0 else { return }
        cancelTrim()
        preview.pause()
        if !keyframes, stepStill(direction) { return }
        guard !segments.isEmpty else { return }
        let cards = keyframes ? [] : inlineStills(in: stillProject)
        let futureCard = direction > 0
            ? cards.first { $0.start.seconds > playhead }
            : cards.last { $0.end.seconds < playhead }
        let cardTime = futureCard.map { card -> Double in
            if direction > 0 { return card.start.seconds }
            let frames = (try? card.insert.frameCount()) ?? 1
            return card.start.seconds + Double(max(0, frames - 1)) * card.insert.cadence.seconds
        }
        func advance(to time: Double) {
            guard let cardTime else { seek(time); return }
            seek(direction > 0 ? min(time, cardTime) : max(time, cardTime))
        }
        let current = max(0, edit.offsets.lowerBound { $0.seconds > playhead } - 1)
        let limit = direction > 0 ? segments.count : -1
        let tolerance = max(playhead.ulp * 4, 0.000000001)
        for i in stride(from: current, to: limit, by: direction > 0 ? 1 : -1) {
            let segment = segments[i]
            let offset = edit.offsets[i]
            let local = playhead - offset.seconds + segment.start.seconds
            if !segment.source.media.hasVideo {
                guard !keyframes else { return }
                let cut: RationalTime
                if direction > 0 && local < segment.start.seconds { cut = segment.start }
                else { cut = segment.source.media.steppingAudioBoundary(from: min(local, segment.end.seconds), direction: direction) }
                guard cut >= segment.start, cut <= segment.end else { continue }
                let time = segment.sequenceSeconds(at: cut, offset: offset)
                if direction > 0 ? time <= playhead : time >= playhead { continue }
                advance(to: time)
                return
            }
            let times = keyframes ? segment.source.keyframes : segment.source.frames
            let index: Int
            if direction > 0 {
                let endIndex = times.lowerBound { $0 >= segment.end }
                index = times.lowerBound { $0.seconds > local + tolerance && $0 >= segment.start }
                guard index < endIndex else { continue }
            } else {
                let endIndex = times.lowerBound { $0 >= segment.end }
                if keyframes || local >= segment.end.seconds - tolerance {
                    index = min(endIndex, times.lowerBound { $0.seconds >= local - tolerance }) - 1
                } else {
                    let current = times.lowerBound { $0.seconds > local + tolerance } - 1
                    index = current - 1
                }
                guard index >= 0, times[index] >= segment.start else { continue }
            }
            advance(to: segment.sequenceSeconds(at: times[index], offset: offset))
            return
        }
        if let cardTime { seek(cardTime) }
    }

    private var selectedSpan: AudioSpan? {
        guard let a = edit.markIn, let b = edit.markOut, a != b else { return nil }
        return AudioSpan(from: min(a, b), to: max(a, b))
    }

    func selectRange(_ anchor: Double, _ end: Double) {
        guard canEdit, anchor.isFinite, end.isFinite else { return }
        guard let a = markBoundary(at: max(0, min(duration, anchor)), pointer: true),
              let b = markBoundary(at: max(0, min(duration, end)), pointer: true) else { return }
        let lower = min(a, b), upper = max(a, b)
        guard edit.markIn != lower || edit.markOut != upper
                || !edit.pointerMarkIn || !edit.pointerMarkOut else { return }
        preview.pause()
        var selection = edit
        selection.markIn = lower
        selection.markOut = upper
        selection.pointerMarkIn = true
        selection.pointerMarkOut = true
        edit = selection
        rebuildPausePlan()
    }

    private func isInsideClip(_ time: RationalTime) -> Bool {
        guard time > .zero, time < edit.duration else { return false }
        let index = edit.offsets.lowerBound { $0 >= time }
        return index == edit.offsets.count || edit.offsets[index] != time
    }

    func splitSelectedRange() {
        guard canSplitSelectedRange, let span = selectedSpan else { return }
        var proposed: [EditorSegment] = []
        proposed.reserveCapacity(segments.count + 2)
        var selected: UUID?
        for (clip, offset) in zip(segments, edit.offsets) {
            var piece = clip
            for edge in [span.from, span.to] where edge > offset && edge < offset + clip.duration {
                guard let boundary = try? clip.start.adding(edge.subtracting(offset)) else {
                    alert = EditorNotice(title: "Can’t Split Selected Range", message: "The selection exceeds the supported time precision.")
                    return
                }
                let halves = piece.split(at: boundary, rightID: UUID())
                proposed.append(halves.left)
                piece = halves.right
                if edge == span.from { selected = piece.id }
            }
            if offset == span.from { selected = clip.id }
            proposed.append(piece)
        }
        validate(proposed, selecting: selected, at: span.from.seconds, action: "Split Selected Range", preserveMarks: true)
    }

    func setIn() {
        guard canEdit else { return }
        preview.pause()
        guard let boundary = markBoundary(at: playhead) else { return }
        edit.markIn = boundary
        edit.pointerMarkIn = usesPointerPosition
        rebuildPausePlan()
    }

    func setOut() {
        guard canEdit else { return }
        preview.pause()
        guard let boundary = markBoundary(at: playhead) else { return }
        edit.markOut = boundary
        edit.pointerMarkOut = usesPointerPosition
        rebuildPausePlan()
    }

    func clearMarks() {
        guard canClearMarks else { return }
        edit.markIn = nil
        edit.markOut = nil
        rebuildPausePlan()
    }

    private var usesPointerPosition = false

    func pointerTarget(_ time: Double, tolerance: Double) -> Double {
        guard let (_, clip, offset) = locatedSegment(at: time) else { return time }
        let local = time - offset.seconds + clip.start.seconds
        let boundary: RationalTime?
        switch effectiveSnapTarget {
        case .off: return time
        case .keyframes:
            boundary = nearest(in: clip.source.keyframes, to: local, after: clip.start,
                               before: clip.end, includingLimits: true)
        case .scenes:
            // A cut in the edited sequence starts a new visible scene even if
            // neither occurrence was cut on a detected source marker.
            let marker = analysisBoundary(in: clip, to: local, after: clip.start,
                                          before: clip.end, includingLimits: true)
            boundary = [clip.start, marker, clip.end].compactMap { $0 }.min {
                abs($0.seconds - local) < abs($1.seconds - local)
            }
        case .silence:
            boundary = analysisBoundary(in: clip, to: local, after: clip.start,
                                        before: clip.end, includingLimits: true)
        }
        if let boundary, abs(boundary.seconds - local) <= tolerance {
            return clip.sequenceSeconds(at: boundary, offset: offset)
        }
        return time
    }

    func split() {
        guard canEdit else { return }
        let mode = usesPointerPosition ? TimelineSnapTarget.off : effectiveSnapTarget
        cancelTrim()
        preview.pause()
        let position = playhead
        if let (still, start) = stillInsert(at: position) {
            editStill(action: "Split Still") {
                let offset = try self.stillBoundary(at: position).subtracting(start)
                return try self.stillProject.splittingStill(id: still.id, at: offset)
            }
            return
        }
        guard let (index, segment, offset) = locatedSegment(at: position),
              position - offset.seconds > max(position.ulp * 4, 0.000000001) else {
            alert = EditorNotice(title: "Can’t Split Clip", message: "The playhead is already at a cut. Move it inside a clip to split it.")
            return
        }
        split(index: index, atSourceTime: position - offset.seconds + segment.start.seconds,
              mode: mode, check: {}, completion: nil)
    }

    struct SplitOutcome {
        let left: UUID
        let right: UUID
        let sourceTime: RationalTime
        let sequenceTime: RationalTime
        let revision: Int
        let historyRetained: Bool
    }

    func split(_ occurrence: UUID, atSourceTime target: RationalTime, cancellation: EditCancellation,
               check: @escaping @MainActor () throws -> Void, completion: @escaping (Result<SplitOutcome, Error>) -> Void) {
        guard canEdit, let index = segments.firstIndex(where: { $0.id == occurrence }) else {
            completion(.failure(CutError(code: "editor_busy", message: "The clip is unavailable for editing.")))
            return
        }
        let segment = segments[index]
        guard target > segment.start, target < segment.end else {
            completion(.failure(CutError(code: "invalid_boundary", message: "Choose a time inside the requested clip.")))
            return
        }
        split(index: index, atSourceTime: target.seconds, mode: effectiveSnapTarget,
              cancellation: cancellation, check: check, completion: completion)
    }

    /// Both the GUI shortcut and an explicit remote edit use the same snap search and history commit.
    private func split(index: Int, atSourceTime target: Double, mode targetMode: TimelineSnapTarget, cancellation requestToken: EditCancellation? = nil,
               check: @escaping @MainActor () throws -> Void,
               completion: ((Result<SplitOutcome, Error>) -> Void)?) {
        let title = "Can’t Split Clip"
        func fail(_ message: String) {
            if let completion { completion(.failure(CutError(code: "invalid_boundary", message: message))) }
            else { alert = EditorNotice(title: title, message: message) }
        }
        let segment = segments[index], offset = edit.offsets[index]
        let candidates: [RationalTime]
        switch targetMode {
        case .off: candidates = segment.source.media.hasVideo ? segment.source.frames :
            [segment.source.media.audioEditBoundary(near: target)]
        case .keyframes: candidates = copyBoundaries(for: segment.source)?.splitPoints ?? []
        case .scenes, .silence:
            guard let boundary = analysisBoundary(in: segment, to: target, after: segment.start, before: segment.end) else {
                showAnalysisBoundaryError(segment, title: title)
                if let completion, let issue = alert { alert = nil; completion(.failure(CutError(code: "unavailable_analysis", message: issue.message))) }
                return
            }
            candidates = [boundary]
        }
        let original = segments, rightID = UUID(), revision = mcpRevision
        let container = preferredCopyContainer
        let perform: @Sendable (CutEngine) -> SplitSearch = { engine in
            var result = SplitSearch()
            for boundary in Self.nearestBoundaries(in: candidates, to: target, after: segment.start, before: segment.end) {
                var proposed = original
                let halves = segment.split(at: boundary, rightID: rightID)
                proposed[index] = halves.left
                proposed.insert(halves.right, at: index + 1)
                if targetMode == .keyframes, let error = Self.copyIssue(proposed, container: container, engine: engine) {
                    if error.code == "cancelled" { break }
                    if result.issue == nil {
                        result.issue = error
                        result.proposed = proposed
                    }
                    if Self.blocksAllSnapCandidates(error, in: proposed, container: container) { break }
                    continue
                }
                result.cut = boundary
                result.proposed = proposed
                break
            }
            return result
        }
        let finish: (SplitSearch) -> Void = { [self] result in
            do { try check() } catch { completion?(.failure(error)); return }
            if let cut = result.cut {
                let snapped: RationalTime
                do {
                    snapped = try offset.adding(cut.subtracting(segment.start))
                } catch {
                    if let completion { completion(.failure(error)) }
                    else { alert = EditorNotice(title: title, message: error.localizedDescription) }
                    return
                }
                // A split made in the editor asks before lowering the tier. A remote one, which has a completion, does not.
                guard asking(completion == nil, { validate(result.proposed, selecting: rightID, at: snapped.seconds, action: "Split Clip") }) else {
                    if let completion {
                        let message = alert?.message ?? "Split validation failed."
                        alert = nil
                        completion(.failure(CutError(code: "invalid_edit", message: message)))
                    }
                    return
                }
                completion?(.success(SplitOutcome(left: segment.id, right: rightID, sourceTime: cut,
                                                  sequenceTime: snapped, revision: mcpRevision,
                                                  historyRetained: mcpHistoryLimit > 0)))
            } else if let issue = result.issue {
                fail(copyMessage(issue, in: result.proposed))
            } else if targetMode == .keyframes {
                showCopyBoundaryError(segment, at: target, edge: .start, title: title, first: false, last: false)
                if let completion, let issue = alert { alert = nil; completion(.failure(CutError(code: "invalid_boundary", message: issue.message))) }
            } else {
                let unit = isAudioOnly ? "audio cut point" : "frame boundary"
                fail("There is no \(unit) inside this range.")
            }
        }
        if targetMode == .keyframes && edit.preparation.requiresBackgroundCopyChecks {
            let token = requestToken ?? EditCancellation()
            cancellation = token
            isCheckingEdit = true
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    perform(CutEngine(cancelled: { token.isCancelled }))
                }.value
                guard cancellation === token else {
                    completion?(.failure(CutError(code: "cancelled", message: "The split was cancelled.")))
                    return
                }
                cancellation = nil
                isCheckingEdit = false
                defer { resumePendingWork() }
                // Prefer the bridge's revocation or stale-revision error when access was lost.
                if effectiveSnapTarget != targetMode || preferredCopyContainer != container ||
                    (requestToken != nil && revision != mcpRevision) || token.isCancelled {
                    do { try check() } catch { completion?(.failure(error)); return }
                    if token.isCancelled {
                        completion?(.failure(CutError(code: "cancelled", message: "The split was cancelled.")))
                    } else {
                        completion?(.failure(CutError(code: "edit_context_changed", message: "The split context changed.")))
                    }
                    return
                }
                finish(result)
            }
        } else {
            finish(perform(CutEngine()))
        }
    }

    private struct SplitSearch: Sendable {
        var cut: RationalTime?
        var proposed: [EditorSegment] = []
        var issue: CutError?
    }

    func trim(_ id: UUID, edge: TimelineEdge, sourceTime: Double, commit: Bool) -> Double? {
        asking(true) { trim(id, edge: edge, sourceTime: sourceTime, commit: commit, snap: effectiveSnapTarget) }
    }

    /// Large native copy-boundary searches can finish after a setting changes or a window closes.
    func mcpTrim(_ id: UUID, edge: TimelineEdge, time: Double, preview: UUID?, cancellation token: EditCancellation,
                 check: @escaping @MainActor () throws -> Void) async throws -> Double? {
        func applyTrim(verified: TrimSearch? = nil) -> Double? {
            let result = trim(id, edge: edge, sourceTime: time, commit: preview == nil,
                              snap: effectiveSnapTarget, verified: verified)
            if result != nil { mcpTrimPreview = preview }
            return result
        }
        guard usesBackgroundTrimValidation,
              let index = segments.firstIndex(where: { $0.id == id }),
              let boundaries = copyBoundaries(for: segments[index].source) else {
            try check()
            return applyTrim()
        }
        let original = segments, revision = mcpRevision, generation = mcpGeneration
        let container = preferredCopyContainer
        let previewID = mcpTrimPreview
        let candidates = trimCandidates(at: index, edge: edge, boundaries: boundaries)
        let cached = checkingTrim?.0 == id && checkingTrim?.1 == edge ? trimChecks : [:]
        cancellation = token
        isCheckingEdit = true
        let worker = Task.detached(priority: .userInitiated) {
            Self.searchCopyTrim(segments: original, index: index, edge: edge, target: time,
                                options: candidates, container: container, cached: cached)
        }
        let cancelID = token.onCancel { worker.cancel() }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        token.removeCancellationHandler(cancelID)
        guard cancellation === token else {
            try check()
            throw CutError(code: "cancelled", message: "The trim was cancelled.")
        }
        cancellation = nil
        isCheckingEdit = false
        defer { resumePendingWork() }
        try check()
        guard canEdit, generation == mcpGeneration, revision == mcpRevision, mcpTrimPreview == previewID, !token.isCancelled,
              effectiveSnapTarget == .keyframes, preferredCopyContainer == container else {
            throw CutError(code: "edit_context_changed", message: "The trim context changed. Read the current editor state.")
        }
        return applyTrim(verified: result)
    }

    private func trim(_ id: UUID, edge: TimelineEdge, sourceTime: Double, commit: Bool, snap: TimelineSnapTarget,
                      verified: TrimSearch? = nil) -> Double? {
        guard canEdit, sourceTime.isFinite,
              let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        mcpTrimPreview = nil
        let segment = segments[index]
        let offset = edit.offsets[index]
        let minimum = edge == .end ? segment.start : nil
        let maximum = edge == .start ? segment.end : nil
        let originalBoundary = edge == .start ? segment.start : segment.end
        func replacingBoundary(_ time: RationalTime) -> [EditorSegment] {
            var proposed = segments
            if edge == .start { proposed[index].start = time } else { proposed[index].end = time }
            if let range = segment.displayRange {
                proposed[index].displayRange = AudioSpan(from: min(range.from, segment.start, proposed[index].start),
                                                         to: max(range.to, segment.end, proposed[index].end))
            }
            return proposed
        }
        let cut: RationalTime
        if snap == .keyframes {
            guard let boundaries = copyBoundaries(for: segment.source) else {
                if commit { showCopyBoundaryError(segment, at: sourceTime, edge: edge, title: "Can’t Trim Clip") }
                return nil
            }
            if checkingTrim?.0 != id || checkingTrim?.1 != edge {
                checkingTrim = (id, edge)
                trimChecks.removeAll()
                fixedTrimIssue = nil
            }
            if let fixedTrimIssue {
                if commit { alert = EditorNotice(title: "Can’t Trim Clip", message: copyMessage(fixedTrimIssue, in: segments)) }
                return nil
            }
            let result = verified ?? Self.searchCopyTrim(
                segments: segments, index: index, edge: edge, target: sourceTime,
                options: trimCandidates(at: index, edge: edge, boundaries: boundaries),
                container: preferredCopyContainer, cached: trimChecks
            )
            trimChecks.merge(result.newChecks) { _, new in new }
            fixedTrimIssue = result.fixedIssue
            let tried = result.firstIssue, chosen = result.cut
            guard let chosen else {
                if commit {
                    if let tried {
                        alert = EditorNotice(title: "Can’t Trim Clip", message: copyMessage(tried, in: segments))
                    } else {
                        showCopyBoundaryError(segment, at: sourceTime, edge: edge, title: "Can’t Trim Clip")
                    }
                }
                return nil
            }
            cut = chosen
        } else if snap == .scenes || snap == .silence {
            // Even a source with no detected markers can be restored to its original extent.
            if edge == .start && sourceTime <= 0 { cut = .zero }
            else if edge == .end && sourceTime >= segment.source.duration.seconds { cut = segment.source.duration }
            else if let boundary = analysisBoundary(in: segment, to: sourceTime, after: minimum, before: maximum) {
                cut = boundary
            } else {
                if commit { cancelTrim(); showAnalysisBoundaryError(segment, title: "Can’t Trim Clip") }
                return nil
            }
        } else {
            guard let frame = editBoundary(in: segment.source, to: sourceTime, after: minimum, before: maximum) else {
                return nil
            }
            cut = frame
        }
        if !commit {
            if trimOrigin == nil {
                preview.pause()
                trimOrigin = playhead
            }
            if trimAudition?.0 != id || trimAudition?.1 != edge || trimAudition?.2 != cut {
                let backwards = trimAudition.map { cut < $0.2 } ?? (edge == .end)
                trimAudition = (id, edge, cut)
                let auditionTime = edge == .end ? precedingFrame(in: segment, before: cut) : cut
                preview.audition(monitoredPreview(segment), at: auditionTime.seconds,
                                 sourceDuration: segment.source.duration.seconds, reverse: backwards)
            }
            return cut.seconds
        }

        let original = trimOrigin ?? playhead
        if cut == originalBoundary {
            if snap == .keyframes,
               let pictureBoundary = nearestCopyPictureBoundary(in: segment, to: sourceTime, edge: edge),
               let issue = linkedAudioIssue(for: segment, at: pictureBoundary, edge: edge,
                                            first: index == 0, last: index == segments.count - 1) {
                alert = EditorNotice(title: "Can’t Trim Clip", message: "\(segment.source.name) — \(issue.message)")
            }
            cancelTrim()
            return cut.seconds
        }
        let landing: Double
        switch edge {
        case .start:
            landing = offset.seconds
        case .end:
            landing = segment.sequenceSeconds(at: precedingFrame(in: segment, before: cut), offset: offset)
        }
        trimOrigin = nil
        trimAudition = nil
        validate(replacingBoundary(cut), selecting: id, at: landing, action: "Trim Clip", originalPlayhead: original)
        return cut.seconds
    }

    private struct TrimSearch: Sendable {
        var cut: RationalTime?
        var firstIssue: CutError?
        var fixedIssue: CutError?
        var newChecks: [RationalTime: TrimCheck] = [:]
    }

    private nonisolated static func searchCopyTrim(segments: [EditorSegment], index: Int, edge: TimelineEdge,
                                                   target: Double, options: [RationalTime], container: String?,
                                                   cached: [RationalTime: TrimCheck]) -> TrimSearch {
        let segment = segments[index]
        let candidates = nearestBoundaries(in: options, to: target, after: edge == .end ? segment.start : nil,
                                           before: edge == .start ? segment.end : nil)
        var result = TrimSearch()
        let engine = CutEngine(cancelled: { Task.isCancelled })
        for candidate in candidates {
            if Task.isCancelled { break }
            if let check = cached[candidate], check.error == nil { result.cut = candidate; break }
            var proposed = segments
            if edge == .start { proposed[index].start = candidate } else { proposed[index].end = candidate }
            let check = cached[candidate] ?? TrimCheck(error: copyIssue(proposed, container: container, engine: engine))
            if cached[candidate] == nil { result.newChecks[candidate] = check }
            guard let error = check.error else { result.cut = candidate; break }
            if result.firstIssue == nil { result.firstIssue = error }
            if blocksAllSnapCandidates(error, in: proposed, container: container, moving: segment.id, edge: edge) {
                result.fixedIssue = error
                break
            }
        }
        return result
    }

    var usesBackgroundTrimValidation: Bool {
        effectiveSnapTarget == .keyframes && edit.preparation.requiresBackgroundCopyChecks
    }

    /// Newer mouse events supersede older candidate searches. A committed handle changes
    /// history once, after the same copy planner used by a synchronous edit accepts it.
    func validateHandle(_ id: UUID, edge: TimelineEdge, target: Double, commit: Bool,
                        completion: @escaping (Double?) -> Void) {
        guard canEdit, effectiveSnapTarget == .keyframes, let index = segments.firstIndex(where: { $0.id == id }),
              let bounds = copyBoundaries(for: segments[index].source) else {
            completion(trim(id, edge: edge, sourceTime: target, commit: commit))
            return
        }
        let previous = trimValidation
        previous?.cancel()
        let request = UUID()
        trimValidationID = request
        let original = segments, container = preferredCopyContainer
        let options = trimCandidates(at: index, edge: edge, boundaries: bounds)
        let cached = checkingTrim?.0 == id && checkingTrim?.1 == edge ? trimChecks : [:]
        isCommittingHandle = commit
        if commit { isCheckingEdit = true }
        trimValidation = Task { [weak self] in
            // Coalesce rapid drag events while an older native planner call winds down.
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                Self.searchCopyTrim(segments: original, index: index, edge: edge, target: target,
                                    options: options, container: container, cached: cached)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, self.trimValidationID == request else { return }
            self.trimValidation = nil
            self.trimValidationID = nil
            self.isCommittingHandle = false
            if commit { self.isCheckingEdit = false }
            guard self.canEdit, self.effectiveSnapTarget == .keyframes, self.preferredCopyContainer == container else {
                completion(nil)
                return
            }
            self.checkingTrim = (id, edge)
            self.trimChecks = cached.merging(result.newChecks) { _, new in new }
            self.fixedTrimIssue = nil
            completion(self.asking(true) { self.trim(id, edge: edge, sourceTime: target, commit: commit, snap: .keyframes, verified: result) })
            if commit { self.resumePendingWork() }
        }
    }

    private func cancelHandleValidation() {
        trimValidation?.cancel()
        trimValidation = nil
        trimValidationID = nil
        if isCommittingHandle {
            isCheckingEdit = false
            isCommittingHandle = false
        }
    }

    func cancelTrim() {
        mcpTrimPreview = nil
        cancelHandleValidation()
        checkingTrim = nil
        trimChecks.removeAll()
        guard let original = trimOrigin else { return }
        trimOrigin = nil
        trimAudition = nil
        restorePreview(at: original)
    }

    func dropOnViewer(_ urls: [URL]) {
        if !urls.isEmpty, urls.allSatisfy(StillPanels.isSupportedImage) {
            addDroppedStills(urls, at: playhead, replacingMarkedRange: NSEvent.modifierFlags.contains(.option))
            return
        }
        guard let csv = urls.first(where: { $0.pathExtension.lowercased() == "csv" }) else {
            importFiles(urls)
            return
        }
        guard canEdit, urls.count == 1, let clip = locatedSegment(at: playhead)?.1 ?? segments.last else {
            alert = EditorNotice(title: "Couldn’t Apply CSV", message: "Open a clip, then drop one CSV file onto it.")
            return
        }
        applyClipCSV(csv, to: clip.id)
    }

    func chooseClipCSV() {
        guard canEdit, let id = selectedID else { return }
        let panel = NSOpenPanel()
        panel.title = "Apply CSV to Selected Clip"
        panel.allowedContentTypes = [.commaSeparatedText]
        let currentSession = session
        isPresentingPanel = true
        present(panel) { [weak self] accepted in
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            if accepted, let url = panel.url { self.applyClipCSV(url, to: id) }
            self.resumePendingWork()
        }
    }

    func applyClipCSV(_ url: URL, to id: UUID, requestCancellation: EditCancellation? = nil,
                      beforeCommit: (() throws -> Void)? = nil,
                      completion: ((Result<Int, Error>) -> Void)? = nil) {
        guard canEdit, let index = segments.firstIndex(where: { $0.id == id }) else {
            completion?(.failure(CutError(code: "editor_busy", message: "The clip is unavailable for editing.")))
            return
        }
        let clip = segments[index]
        let scope = AudioSpan(from: clip.start, to: clip.end)
        let currentSession = session
        let token = requestCancellation ?? EditCancellation()
        cancellation = token
        isCheckingEdit = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ClipEditCSV.ranges(in: url, clip: scope, cancelled: { token.isCancelled }) }
            }.value
            guard session == currentSession, cancellation === token else {
                completion?(.failure(CutError(code: "project_closed", message: "The project closed during the CSV import.")))
                return
            }
            cancellation = nil
            isCheckingEdit = false
            defer { resumePendingWork() }
            do {
                let ranges = try result.get()
                guard ranges != [scope] else {
                    try beforeCommit?()
                    completion?(.success(mcpRevision))
                    return
                }
                guard let index = segments.firstIndex(where: { $0.id == id }) else {
                    throw CutError(code: "invalid_target", message: "The clip is no longer in the timeline.")
                }
                var occurrence = clip.occurrence
                var newOccurrences: [UUID] = []
                let pieces = ranges.enumerated().map { offset, range in
                    if offset > 0, range.from < ranges[offset - 1].to {
                        occurrence = UUID()
                        newOccurrences.append(occurrence)
                    }
                    let displayFrom = range.from == scope.from ? clip.displayRange?.from ?? .zero : range.from
                    let displayTo = range.to == scope.to ? clip.displayRange?.to ?? clip.source.duration : range.to
                    return EditorSegment(id: offset == 0 ? clip.id : UUID(), documentID: offset == 0 ? clip.documentID : nil,
                                         source: clip.source, start: range.from, end: range.to,
                                         displayRange: AudioSpan(from: displayFrom, to: displayTo), occurrence: occurrence)
                }
                var proposed = segments
                proposed.replaceSubrange(index...index, with: pieces)
                try beforeCommit?()
                guard asking(completion == nil && requestCancellation == nil, {
                    validate(proposed, selecting: pieces.first?.id, at: edit.offsets[index].seconds, action: "Apply CSV")
                }) else {
                    if let completion {
                        let message = alert?.message ?? "Invalid CSV edit."
                        alert = nil
                        completion(.failure(CutError(code: "invalid_edit", message: message)))
                    }
                    return
                }
                defer { completion?(.success(mcpRevision)) }
                guard !newOccurrences.isEmpty else { return }
                let inherited = protectedPauses.filter { $0.key.occurrence == clip.occurrence }
                if !inherited.isEmpty {
                    for occurrence in newOccurrences {
                        for (key, spans) in inherited {
                            protectedPauses[TimelinePause.Source(occurrence: occurrence, track: key.track)] = spans
                        }
                    }
                    rebuildPausePlan()
                }
            } catch {
                if let completion { completion(.failure(error)) }
                else { alert = EditorNotice(title: "Couldn’t Apply CSV", message: error.localizedDescription) }
            }
        }
    }

    func move(_ id: UUID, to insertionIndex: Int) {
        guard canEdit, let from = segments.firstIndex(where: { $0.id == id }) else { return }
        let slot = min(max(0, insertionIndex), segments.count)
        let destination = slot > from ? slot - 1 : slot
        guard destination != from else { return }
        var proposed = segments
        let segment = proposed.remove(at: from)
        proposed.insert(segment, at: destination)
        let time = sequenceDuration(proposed.prefix(destination))
        validate(proposed, selecting: id, at: time, action: "Move Clip")
    }

    func deleteSelection() {
        guard canDelete else { return }
        if let inTime = edit.markIn, let outTime = edit.markOut, inTime != outTime {
            deleteMarkedRange(min(inTime, outTime)...max(inTime, outTime))
        } else if markIn != nil, markOut != nil {
            alert = EditorNotice(title: "Can’t Delete Marked Range", message: "Move one mark to create a range to delete.")
        } else if markIn != nil || markOut != nil {
            let missing = markIn == nil ? "Mark In" : "Mark Out"
            alert = EditorNotice(title: "Finish the Marked Range", message: "Set \(missing) to finish the range, or press Esc to clear the mark and delete a whole clip.")
        } else if let selectedID {
            deleteClip(selectedID)
        }
    }

    func deleteClip(_ id: UUID) {
        if let placementID = stillTimelineIDs.first(where: { $0.value == id })?.key {
            editStill(action: "Delete Still") { try stillProject.removingStill(id: placementID) }
            return
        }
        guard canEdit, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        var proposed = segments
        proposed.remove(at: index)
        validate(proposed, selecting: proposed.indices.contains(index) ? proposed[index].id : proposed.last?.id,
                 at: edit.offsets[index].seconds, action: "Delete Clip")
    }

    var historyActions: [String] { undoStack.map(\.action) + redoStack.reversed().map(\.action) }
    var historyEntryIDs: [UUID] { undoStack.map(\.id) + redoStack.reversed().map(\.id) }
    var historyCursor: Int { undoStack.count }

    @discardableResult
    private func enforceHistoryLimit() -> Bool {
        let counts = CutProject.historyCounts(undo: undoStack.count, redo: redoStack.count, limit: preferences.historyLimit)
        guard counts.undo != undoStack.count || counts.redo != redoStack.count else { return false }
        undoStack.removeFirst(undoStack.count - counts.undo)
        redoStack.removeFirst(redoStack.count - counts.redo)
        return true
    }

    func undo() { moveToHistoryState(historyCursor - 1) }
    func redo() { moveToHistoryState(historyCursor + 1) }

    func moveToHistoryState(_ index: Int) { moveToHistoryState(index, beforeRestore: nil, completion: nil) }

    func moveToHistoryState(_ index: Int, requestCancellation: EditCancellation? = nil,
                            beforeRestore: (() throws -> Void)?, completion: ((Result<Void, Error>) -> Void)?) {
        let title = "Couldn’t Restore History State"
        func fail(_ error: Error) {
            if let completion { completion(.failure(error)) }
            else { alert = EditorNotice(title: title, message: error.localizedDescription) }
        }
        guard !isBusy, alert == nil, index >= 0, index <= undoStack.count + redoStack.count else {
            completion?(.failure(CutError(code: "editor_busy", message: "The history state is unavailable.")))
            return
        }
        guard index != historyCursor else { completion?(.success(())); return }
        cancelTrim()
        let backwards = index < historyCursor
        var from = backwards ? undoStack : redoStack
        var to = backwards ? redoStack : undoStack
        var target = HistoryEntry(action: "", contents: .live(snapshot()),
                                  copyContainer: explicitCopyContainer, audioMonitoring: audioMonitoring)
        for _ in 0..<abs(historyCursor - index) {
            let step = from.removeLast()
            to.append(HistoryEntry(id: step.id, action: step.action, contents: target.contents,
                                   copyContainer: target.copyContainer,
                                   audioMonitoring: step.audioMonitoring == nil ? nil : target.audioMonitoring))
            let monitoring = step.audioMonitoring ?? target.audioMonitoring
            let container = step.clipCount == 0 ? nil : target.copyContainer ?? step.copyContainer
            target = step
            target.audioMonitoring = monitoring
            target.copyContainer = container
        }
        let finish = {
            if self.explicitCopyContainer != target.copyContainer {
                self.explicitCopyContainer = target.copyContainer
                self.copyBoundaryIndices.removeAll()
                self.prepareCopyBoundaries()
                self.rebuildPausePlan()
            }
            self.undoStack = backwards ? from : to
            self.redoStack = backwards ? to : from
            self.enforceHistoryLimit()
            self.updateStatus()
            self.saveUntitledDraft()
        }
        if case .live(let state) = target.contents,
           state.preparation.sourceMedia.values.allSatisfy(Self.currentSource) {
            do { try beforeRestore?() } catch { fail(error); return }
            let sources = Set(state.preparation.sourceMedia.values.map(\.url))
            if !sources.isSubset(of: lastSidecarCandidates) { refreshSidecarExclusions(adding: Array(sources)) }
            copyBoundaryIndices.removeAll()
            explicitCopyContainer = target.copyContainer
            mcpRevision += 1
            edit = state
            mediaClipReview = Dictionary(uniqueKeysWithValues: edit.timelineClips.compactMap { clip in
                clip.mediaIssue.map { (clip.id, $0) }
            })
            refreshTier()
            prepareCopyBoundaries()
            if let monitoring = target.audioMonitoring { audioMonitoring = monitoring }
            syncWaveforms()
            requestSnapAnalysis()
            restorePreview(at: edit.playhead)
            finish()
            completion?(.success(()))
        } else {
            let clips = target.clips
            if let restored = cachedSegments(for: clips) {
                let prepared = PreparedEdit(segments: restored, previous: edit.preparation, engine: CutEngine())
                do { try beforeRestore?() } catch { fail(error); return }
                if apply(restored, prepared: prepared, selecting: restored.first?.id, at: 0,
                         action: target.action, recordHistory: false, restoringAudioMonitoring: target.audioMonitoring, sequenceProject: target.project) {
                    finish()
                    completion?(.success(()))
                } else if let completion {
                    let message = alert?.message ?? "The history state could not be restored."
                    alert = nil
                    completion(.failure(CutError(code: "invalid_edit", message: message)))
                }
            } else {
                // Prepare all sources before committing either the timeline or its cursor.
                // A retention change while indexing may have removed this transition.
                let originalHistory = historyEntryIDs
                let originalCursor = historyCursor
                do {
                    try importFiles(checkedFiles(clips), projectClips: clips, historyAction: target.action, beforeInstall: {
                        try beforeRestore?()
                        guard self.historyEntryIDs == originalHistory, self.historyCursor == originalCursor else {
                            if completion == nil { return false }
                            throw CutError(code: "stale_history", message: "The history changed while preparing this state.")
                        }
                        return true
                    }, requestCancellation: requestCancellation, installed: finish,
                    restoringAudioMonitoring: target.audioMonitoring, sequenceProject: target.project, completion: completion)
                } catch { fail(error) }
            }
        }
    }

    private static func currentSource(_ media: MediaInfo) -> Bool {
        media.identity.isCurrentSnapshot(at: media.url)
    }

    /// Reuse the indexed media already on the timeline when walking through saved trims or rearrangements.
    private func cachedSegments(for clips: [CutSequenceClip]) -> [EditorSegment]? {
        var sources: [DocumentSourceKey: IndexedSource] = [:]
        for segment in segments {
            let source = segment.source
            sources[DocumentSourceKey(file: source.url, original: source.originalURL, track: source.replacementTrack,
                                      names: source.replacementNames)] = source
        }
        var checked: Set<UUID> = []
        var restored: [EditorSegment] = []
        for clip in clips {
            let file = URL(fileURLWithPath: clip.file)
            let key = DocumentSourceKey(file: file, original: clip.originalFile.map(URL.init(fileURLWithPath:)) ?? file,
                                        track: clip.audioTrack, names: clip.replacementNames)
            guard let source = sources[key], clip.to <= source.duration else { return nil }
            if checked.insert(source.id).inserted, !Self.currentSource(source.media) { return nil }
            restored.append(EditorSegment(documentID: clip.id, source: source, start: clip.from, end: clip.to))
        }
        return restored
    }

    func preferCopyContainer(_ container: String) {
        cancelTrim()
        explicitCopyContainer = container
        copyBoundaryIndices.removeAll()
        prepareCopyBoundaries()
        rebuildPausePlan()
        checkingTrim = nil
        trimChecks.removeAll()
        refreshTier()
    }

    var canAddMarkedRange: Bool { canActOnRange }
    var canShowBulkQueue: Bool { !isBusy && alert == nil && (!isEmpty || !queuedRanges.isEmpty) }

    func addMarkedRange() {
        guard canAddMarkedRange, let span = selectedSpan else { return }
        if case .stillSequence = stillProject {
            do {
                let project = try stillProjectForSelection()
                let scope = try project.exportPlacementScope()
                if scope != .none {
                    let clips = (project.sequenceClips ?? []).map {
                        ClipRequest(file: URL(fileURLWithPath: $0.file), from: $0.from, to: $0.to)
                    }
                    var files = Set(clips.map(\.file))
                    if let reference = project.stillAudioReference {
                        files.insert(URL(fileURLWithPath: reference.file).standardizedFileURL)
                    }
                    let media = Self.tierInput(segments).media.filter { files.contains($0.key) }
                    queuedRanges.append(QueuedRange(start: span.from, end: span.to, clips: clips,
                                                   media: media, stillProject: project, placements: scope))
                    clearMarks()
                    statusMessage = "Added range \(queuedRanges.count) to the export queue."
                    return
                }
            } catch { showStillError(error); return }
        }
        let selection = pieces(in: span)
        guard !selection.isEmpty else { return }
        let media = Dictionary(selection.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        queuedRanges.append(QueuedRange(start: span.from, end: span.to, clips: selection.map(\.request), media: media))
        clearMarks()
        statusMessage = "Added range \(queuedRanges.count) to the export queue."
    }

    func removeQueuedRange(_ id: UUID) {
        guard !isExporting else { return }
        queuedRanges.removeAll { $0.id == id }
    }

    func showBulkQueue() {
        guard canShowBulkQueue else { return }
        preview.pause()
        isBulkQueuePresented = true
    }

    func bulkQueueDismissed() { resumePendingWork() }

    func chooseBulkDestination(options: ExportSheetOptions) {
        guard isBulkQueuePresented, !queuedRanges.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Queued Ranges"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportDirectory
        let currentSession = session
        ProjectPanels.present(panel, in: sheetWindow, fromSheet: true) { [weak self] accepted in
            guard let self, self.session == currentSession, accepted, let directory = panel.url else { return }
            self.exportQueuedRanges(to: directory, options: options)
        }
    }

    func exportQueuedRanges(to directory: URL, options: ExportSheetOptions) {
        guard isBulkQueuePresented, !queuedRanges.isEmpty else { return }
        exportDirectory = directory
        isBulkQueuePresented = false
        let ranges = queuedRanges
        if let error = queuedMediaRefreshIssue() {
            alert = EditorNotice(title: "Queued Media Changed", message: error.message)
            return
        }
        let protected = protectedMedia
        let useSidecar = useAnalysisSidecars
        runExport { token, progress in
            if ranges.contains(where: { $0.stillProject != nil }) {
                try options.organization.validateSubfolder(in: directory, protectedMedia: protected)
                let batch = try SequenceQueuePlan(ranges, directory: directory, options: options,
                                                  useSidecar: useSidecar, cancelled: { token.isCancelled })
                for item in batch.items { try CutProject.validateMediaDestination(item.output, absoluteSources: protected) }
                for (index, item) in batch.items.enumerated() {
                    do {
                        try batch.write(item) { progress((Double(index) + $0) / Double(batch.items.count)) }
                    } catch {
                        throw CutError(code: "bulk_interrupted", message: "Wrote \(index) of \(ranges.count) files. "
                                       + "Range \(index + 1): \(error.localizedDescription)")
                    }
                }
                return (batch.folder, "Exported \(ranges.count) \(ranges.count == 1 ? "file" : "files") to \(batch.folder.lastPathComponent)")
            }
            var media: [URL: MediaInfo] = [:]
            for range in ranges { media.merge(range.media) { first, _ in first } }
            try options.organization.validateSubfolder(in: directory, protectedMedia: protected)
            let batch = try BulkExport(groups: ranges.map(\.clips), directory: directory, organization: options.organization, mode: options.effectiveMode,
                                       tracks: options.tracks, audioTrackOrdinal: options.audioTrackOrdinal,
                                       container: options.container.isEmpty ? nil : options.container,
                                       settings: options.batchSettings, media: media, cancelled: { token.isCancelled })
            for item in batch.items {
                try CutProject.validateMediaDestination(item.output, absoluteSources: protected)
            }
            for (index, item) in batch.items.enumerated() {
                do {
                    try batch.write(item) { _ = progress((Double(index) + $0) / Double(batch.items.count)) }
                } catch {
                    throw CutError(code: "bulk_interrupted", message: "Wrote \(index) of \(ranges.count) files. "
                                   + "Range \(index + 1): \(error.localizedDescription)")
                }
            }
            let count = ranges.count == 1 ? "1 file" : "\(ranges.count) files"
            let folder = batch.items.first?.output.deletingLastPathComponent() ?? directory
            return (folder, "Exported \(count) to \(folder.lastPathComponent)")
        }
    }

    func stillReviewOccurrence(_ documentID: String) throws -> (id: UUID, source: UUID, media: MediaInfo) {
        guard let clip = segments.first(where: { $0.documentID == documentID }) else {
            throw MCPCommandError("invalid_target", "Choose an existing clip occurrence.")
        }
        if let issue = mediaReviewIssue(clip) { throw MCPCommandError("source_needs_review", issue) }
        return (clip.id, clip.source.id, clip.source.media)
    }

    func refreshedSourceIssue(for clips: [CutSequenceClip]) -> String? {
        let occurrences = Dictionary(segments.map { ($0.documentID, $0) }, uniquingKeysWith: { first, _ in first })
        return clips.lazy.compactMap { clip -> String? in
            guard var segment = occurrences[clip.id] else { return nil }
            segment.start = clip.from
            segment.end = clip.to
            return self.mediaReviewIssue(segment)
        }.first
    }

    var stillReviewCanvas: MediaInfo? {
        segments.lazy.map { $0.source.media }.first(where: \.hasVideo)
    }

    var jpegSourceAtPlayhead: EditorJPEGSource? {
        guard !segments.isEmpty else { return nil }
        let clip: EditorSegment
        let picture: RationalTime?
        if let (id, edge, cut) = trimAudition, let auditioned = segments.first(where: { $0.id == id }) {
            clip = auditioned
            guard clip.source.media.hasVideo, mediaReviewIssue(clip) == nil else { return nil }
            picture = try? JPEGExport.stillFrameTime(in: clip.source.media, at: cut, exclusiveEnd: edge == .end)
        } else if let (_, active, offset) = locatedSegment(at: playhead) {
            clip = active
            let frames = clip.source.media.frames
            // Translate timestamps before comparing them to the display playhead. Rounding
            // a source-time Double after subtraction can move it across a frame boundary.
            func sequenceTime(_ sourceTime: RationalTime) -> Double {
                if let delta = try? sourceTime.subtracting(clip.start),
                   let exact = try? offset.adding(delta) { return exact.seconds }
                return offset.seconds + (sourceTime.seconds - clip.start.seconds)
            }
            let index = frames.lowerBound { $0.time >= clip.end || sequenceTime($0.time) > playhead } - 1
            guard clip.source.media.hasVideo, mediaReviewIssue(clip) == nil else { return nil }
            if frames.indices.contains(index), let frameEnd = try? frames[index].time.adding(frames[index].duration),
               playhead < sequenceTime(frameEnd) {
                picture = max(.zero, frames[index].time)
            } else {
                picture = nil
            }
        } else {
            guard playhead == duration, let last = segments.last, last.source.media.hasVideo else { return nil }
            clip = last
            picture = try? JPEGExport.stillFrameTime(in: last.source.media, at: last.end, exclusiveEnd: true)
        }
        let media = clip.source.media
        let tracks = media.streams.filter { $0.kind == "audio" }
        return EditorJPEGSource(id: clip.source.id, media: media, frame: picture, scenes: sceneReports[clip.source.id],
                                audioStream: sourceAnalysisTracks[clip.source.id].map { tracks[$0].index },
                                pauses: sourcePauses[clip.source.id], manualThreshold: manualThresholdDB,
                                effectiveThreshold: effectiveThresholdDB, minimumPause: minimumPause)
    }

    func chooseStillFrame() {
        guard canEdit else { return }
        preview.pause()
        let still: StillReviewFrame?
        do { still = trimAudition == nil ? try stillFrameAtPlayhead() : nil }
        catch {
            alert = EditorNotice(title: "Export Current Frame", message: error.localizedDescription)
            return
        }
        let camera = jpegSourceAtPlayhead
        guard let sourceURL = still?.url ?? camera?.media.url, still != nil || camera?.frame != nil else { return }
        let options = StillFrameSaveOptions()
        let panel = options.panel(source: sourceURL, directory: exportDirectory)
        let currentSession = session
        isPresentingPanel = true
        present(panel) { [weak self, options] accepted in
            guard let self, session == currentSession else { return }
            isPresentingPanel = false
            guard accepted, let output = panel.url else { resumePendingWork(); return }
            exportDirectory = output.deletingLastPathComponent()
            guard canExport(to: output) else { return }
            let confirmed = options.confirmedDestination(at: output)
            runExport { token, _ in
                if let still {
                    try still.write(to: output, replacing: confirmed, cancelled: { token.isCancelled })
                } else if let camera, let frame = camera.frame {
                    try JPEGExport.writeStill(camera.media, at: frame, to: output, replacing: confirmed,
                                              cancelled: { token.isCancelled })
                }
                return (output, "Exported " + output.lastPathComponent)
            }
        }
    }

    func chooseJPEGExport() {
        guard canEdit else { return }
        cancelTrim()
        preview.pause()
        let source = jpegSourceAtPlayhead
        let still: StillReviewFrame?
        let hasPicture: Bool
        do {
            still = try stillFrameAtPlayhead()
            hasPicture = still != nil || source?.frame != nil
        } catch {
            guard source != nil else {
                alert = EditorNotice(title: "Export JPEG Frames", message: error.localizedDescription)
                return
            }
            still = nil
            hasPicture = false
        }
        guard let sourceURL = still?.url ?? source?.media.url else { return }
        let options = JPEGExportOptions(preset: preferences.jpegPreset)
        let panel = options.panel(source: sourceURL, directory: exportDirectory, hasAudio: source?.audioStream != nil,
                                  hasPictureAtPlayhead: hasPicture, hasAnalysisSource: source != nil)
        let currentSession = session
        isPresentingPanel = true
        present(panel) { [weak self, options] accepted in
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            guard accepted, let directory = panel.url else {
                self.resumePendingWork()
                return
            }
            if options.mode == .playhead, let still {
                self.exportStillJPEGFrames(still, to: directory, preset: options.preset)
            } else if let source {
                self.exportJPEGFrames(source, to: directory, options: options)
            }
        }
    }

    private func exportStillJPEGFrames(_ frame: StillReviewFrame, to directory: URL, preset: JPEGPreset) {
        do { try validateHistoryDestination(directory, includesContents: true) }
        catch {
            alert = EditorNotice(title: "Export JPEG Frames", message: error.localizedDescription)
            return
        }
        exportDirectory = directory.deletingLastPathComponent()
        runExport { token, _ in
            try frame.writeDirectory(to: directory, preset: preset, cancelled: { token.isCancelled })
            return (directory, "Exported one JPEG frame to " + directory.lastPathComponent)
        }
    }

    func exportJPEGFrames(_ source: EditorJPEGSource, to directory: URL, options: JPEGExportOptions) {
        // A notice raised while the panel was open does not withdraw the accepted export.
        guard !isEmpty, !isBusy else { return }
        do {
            let limit = try options.frameLimit()
            try validateHistoryDestination(directory, includesContents: true)
            let preset = options.preset, sample = options.sample, mode = options.mode
            let useSidecar = sidecarPreference.permits(source.media.url)
            let currentSidecarPreference = sidecarPreference
            let wave = audioStore.finished.contains(source.id) ? audioStore.waves[source.id] : nil
            let sceneReport = sceneReports[source.id]
            let savedSilence = source.audioStream.flatMap { stream in
                silenceResults[source.id]?[SilenceProfile(stream: stream, threshold: source.manualThreshold,
                                                          minimum: source.minimumPause)]
            }
            let calibration = source.manualThreshold == nil ? source.effectiveThreshold : nil
            let currentSession = session
            exportDirectory = directory.deletingLastPathComponent()
            runExport { [self] token, progress in
                let selection = try source.selection(for: mode) {
                    if let sceneReport { return sceneReport }
                    let report = try SceneAnalysis.scan(source.media, useSidecar: useSidecar && currentSidecarPreference.permits(source.media.url),
                                                        allowAutomaticSave: { currentSidecarPreference.permits(source.media.url) },
                                                        cancelled: { token.isCancelled })
                    DispatchQueue.main.async {
                        guard self.session == currentSession else { return }
                        self.installSceneReport(report, for: source.id)
                    }
                    return report
                } analyzeSilence: { stream in
                    if let savedSilence { return savedSilence }
                    let result = try AudioAnalysis.silence(source.media, stream: stream,
                                                           thresholdDB: source.manualThreshold, minimum: source.minimumPause,
                                                           waveform: wave, automaticThresholdDB: calibration,
                                                           useSidecar: useSidecar, cancelled: { token.isCancelled })
                    DispatchQueue.main.async {
                        guard self.session == currentSession else { return }
                        let profile = SilenceProfile(stream: stream, threshold: result.requestedThresholdDB, minimum: result.minimum)
                        self.silenceResults[source.id, default: [:]][profile] = result
                        self.refreshDetectedPauses()
                    }
                    return result
                }
                let manifest = try JPEGExport.write(source.media, to: directory, selection: selection,
                                                    sample: sample, preset: preset, limit: limit,
                                                    useSidecar: useSidecar, cancelled: { token.isCancelled }) { done, total in
                    if total > 0 { _ = progress(Double(done) / Double(total)) }
                }
                let count = manifest.frames.count
                return (directory, "Exported \(count) JPEG\(count == 1 ? "" : "s") to \(directory.lastPathComponent).")
            }
        } catch {
            alert = EditorNotice(title: "Couldn’t Export JPEG Frames", message: error.localizedDescription)
        }
    }

    private var replacementSource: IndexedSource? {
        guard let index = selectedClipIndex else { return nil }
        let source = segments[index].source
        return source.media.streams.contains { $0.kind == "audio" } ? source : nil
    }

    var canReplaceSourceAudio: Bool { canEdit && replacementSource != nil }

    func chooseReplacementAudio() {
        guard let source = replacementSource else { return }
        chooseReplacementAudio(for: source)
    }

    func chooseReplacementAudio(forClip id: UUID) {
        guard canEdit, let source = segments.first(where: { $0.id == id })?.source else { return }
        select(id)
        chooseReplacementAudio(for: source)
    }

    private func chooseReplacementAudio(for source: IndexedSource) {
        guard canEdit, source.audioOrdinal(preferred: 0) != nil else { return }
        cancelTrim()
        preview.pause()
        let choose = NSOpenPanel()
        choose.title = "Replace Source Audio"
        choose.message = "Choose a replacement soundtrack for the full length of “\(source.name)”."
        choose.prompt = "Choose Audio"
        choose.canChooseDirectories = false
        choose.allowsMultipleSelection = false
        let currentSession = session
        isPresentingPanel = true
        present(choose) { [weak self] accepted in
            guard let self, self.session == currentSession else { return }
            guard accepted, let url = choose.url else {
                self.isPresentingPanel = false
                self.resumePendingWork()
                return
            }
            self.prepareReplacement(source: source, replacement: url)
        }
    }

    private func prepareReplacement(source: IndexedSource, replacement: URL) {
        refreshSidecarExclusions(adding: [source.url, replacement])
        let excluded = sidecarExclusions
        let currentSession = session
        let token = EditCancellation()
        let useSidecar = useAnalysisSidecars
        isPresentingPanel = false
        cancellation = token
        isCheckingEdit = true
        Task { [self] in
            let inspection = await Task.detached(priority: .userInitiated) {
                Result { try CutEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar && !AnalysisSidecar.isExcluded(replacement, in: excluded)).inspectSummary(replacement) }
            }.value
            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            do {
                let control = try ReplacementExportPanel(source: source.media, replacement: inspection.get(),
                                                         sourceName: source.name, preferredTrack: monitoredAudioOrdinal(for: source) ?? 0, useSidecar: useSidecar, excludedSources: excluded)
                let panel = NSSavePanel()
                panel.title = "Apply Replacement Audio"
                panel.message = "Save a lossless copy with the new audio. Every cut of this source will use it."
                panel.prompt = "Save and Apply"
                panel.directoryURL = exportDirectory
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                control.attach(to: panel)
                isPresentingPanel = true
                present(panel) { [weak self, control] accepted in
                    control.stopChecking()
                    guard let self, self.session == currentSession else { return }
                    self.isPresentingPanel = false
                    guard accepted, let output = panel.url, let plan = control.plan else {
                        self.resumePendingWork()
                        return
                    }
                    self.exportDirectory = output.deletingLastPathComponent()
                    // Chosen by hand, so it asks before a soundtrack that lowers the tier is saved and applied.
                    self.byHand { _ = self.applyReplacement(plan, output: output, useSidecar: useSidecar, sourceID: source.id) }
                }
            } catch {
                alert = EditorNotice(title: "Couldn’t Replace Audio", message: error.localizedDescription)
                resumePendingWork()
            }
        }
    }

    /// The question a soundtrack replacement made by hand asks when it would lower the timeline tier. Nil when the
    /// edit does not ask. It runs on the finished working copy while that copy is still in its staging folder, so the
    /// tier is the planners' answer for the real file and declining leaves nothing at the destination.
    private func replacementTierGate(source: IndexedSource, token: EditCancellation) -> (@Sendable (URL) throws -> Void)? {
        guard asksBeforeLoweringTier, preferences.warnBeforeLoweringExportTier else { return nil }
        let before = Self.tierInput(segments)
        let replaced = segments.map { $0.source.id == source.id }
        let preferred = hasPicture ? preferredCopyContainer : nil
        let useSidecar = useAnalysisSidecars
        let asking = session
        return { [weak self] staged in
            let cancelled: @Sendable () -> Bool = { token.isCancelled }
            let evaluator = TimelineTierEvaluator(useSidecar: useSidecar)
            evaluator.preferredContainer = preferred
            let current = evaluator.evaluate(before.clips, media: before.media, cancelled: cancelled)
            guard case .known(let was, _, _, _) = current else { return }
            let copy = try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                try CutEngine(cancelled: cancelled, useSidecar: false).inspect(staged, keyframes: true)
            }
            let clips = zip(before.clips, replaced).map { clip, isReplaced in
                isReplaced ? ClipRequest(file: copy.url, from: clip.from, to: clip.to) : clip
            }
            var media = before.media
            media[copy.url] = copy
            let becomes = evaluator.evaluate(clips, media: media, cancelled: cancelled)
            switch becomes {
            case .checking: return
            case .known(let tier, _, _, _) where tier >= was: return
            default: break
            }
            let known = Set(current.factors.map(\.message))
            let added = becomes.factors.filter { !known.contains($0.message) }
            let prompt = TierPrompt(action: "Replace Source Audio", from: was, to: becomes,
                                    factors: added.isEmpty ? becomes.factors : added, nearest: nil, soundOnly: !copy.hasVideo)
            let answered = DispatchSemaphore(value: 0)
            let answer = TierAnswer()
            Task { @MainActor in
                guard let self, self.session == asking else { answered.signal(); return }
                let decide: (TierPrompt.Choice) -> Void = { choice in
                    if choice.dontAskAgain { self.preferences.warnBeforeLoweringExportTier = false }
                    answer.choice = choice
                    answered.signal()
                }
                if let ask = self.tierPrompt { ask(prompt, decide) } else { TierPrompt.present(prompt, in: self.sheetWindow, answer: decide) }
            }
            answered.wait()
            guard let choice = answer.choice, choice.answer != .cancel else {
                token.cancel()
                throw CutError(code: "cancelled", message: "Audio replacement cancelled.")
            }
        }
    }

    @discardableResult
    func applyReplacement(_ plan: AudioReplacementPlan, output: URL, useSidecar: Bool, sourceID: UUID? = nil,
                          validateCommit: @escaping @MainActor () throws -> Void = {},
                          completed: ((Result<Int, MCPCommandError>) -> Void)? = nil) -> EditCancellation? {
        // An analysis notice can arrive while the save panel is open.
        guard !isEmpty, !isBusy else { return nil }
        guard let source = segments.lazy.map(\.source).first(where: {
            $0.url.standardizedFileURL == plan.source.standardizedFileURL && (sourceID == nil || $0.id == sourceID)
        }), source.media.identity == plan.sourceIdentity else {
            alert = EditorNotice(title: "Couldn’t Apply Replacement Audio",
                                 message: "The planned source no longer matches the recording on the timeline.")
            resumePendingWork()
            return nil
        }
        guard canExport(to: output) else { return nil }
        refreshSidecarExclusions(adding: [source.url, plan.replacement, output])
        let excluded = sidecarExclusions
        let lastCut = segments.lazy.filter { $0.source.id == source.id }.map(\.end).max() ?? source.duration
        preview.pause()
        lastExportedURL = nil
        let currentSession = session
        let token = EditCancellation()
        cancellation = token
        isExporting = true
        isCancelling = false
        exportProgress = 0
        let report: @Sendable (Double) -> Bool = { [weak self] progress in
            if token.shouldReport(progress) {
                Task { @MainActor in
                    guard let self, self.cancellation === token else { return }
                    self.exportProgress = max(self.exportProgress, progress)
                }
            }
            return !token.isCancelled
        }
        let gate = replacementTierGate(source: source, token: token)
        exportTasks[currentSession] = Task {
            defer { exportTasks.removeValue(forKey: currentSession) }
            let exported = await Task.detached(priority: .userInitiated) {
                Result {
                    try AnalysisSidecar.$excludedSources.withValue(excluded) {
                        try AudioReplacementEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar)
                            .exportWorkingCopy(plan, to: output, progress: { report($0 * 0.75) }, beforePublishing: gate)
                    }
                }
            }.value
            let published = "The working copy was saved to \(output.path)."
            guard session == currentSession else {
                let message = (try? exported.get()) == nil ? "The project changed." : published + " The project changed."
                completed?(.failure(MCPCommandError("project_closed", message)))
                return
            }
            let saved: Bool
            let result: Result<IndexedSource, Error>
            switch exported {
            case .failure(let error):
                saved = false
                result = .failure(error)
            case .success(let identity):
                saved = true
                exportProgress = 0.8
                result = await Task.detached(priority: .userInitiated) {
                    Result {
                        let media = try CutEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar && !AnalysisSidecar.isExcluded(output, in: excluded))
                            .inspect(output, keyframes: true, expectedIdentity: identity) { _ = report(0.8 + $0 * 0.2) }
                        try Self.checkEditable(media)
                        guard media.duration >= lastCut else {
                            throw CutError(code: "working_copy_timing",
                                           message: "The working copy cannot preserve all cuts of this source.")
                        }
                        var names = source.replacementNames
                        names[plan.targetAudioOrdinal] = plan.replacement.lastPathComponent
                        return IndexedSource(media: media, originalURL: source.originalURL,
                                             replacementNames: names, replacementTrack: plan.targetAudioOrdinal)
                    }
                }.value
            }
            guard session == currentSession else {
                completed?(.failure(MCPCommandError("project_closed", saved ? published + " The project changed." : "The project changed.")))
                return
            }
            cancellation = nil
            isExporting = false
            isCancelling = false
            defer { resumePendingWork() }
            guard !token.isCancelled else {
                statusMessage = saved
                    ? "Audio replacement cancelled. The working copy was saved to \(output.lastPathComponent)."
                    : "Audio replacement cancelled."
                completed?(.failure(MCPCommandError("cancelled", saved ? "Audio replacement cancelled. " + published : statusMessage)))
                return
            }
            do {
                let updated = try result.get()
                try validateCommit()
                guard Self.currentSource(updated.media), Self.currentSource(source.media),
                      segments.contains(where: { $0.source.id == source.id }) else {
                    throw CutError(code: "source_changed", message: "The working copy or its timeline source changed before the replacement could be applied.")
                }
                let proposed = segments.map { clip in
                    guard clip.source.id == source.id else { return clip }
                    return EditorSegment(id: clip.id, documentID: clip.documentID, source: updated, start: clip.start, end: clip.end,
                                         displayRange: clip.displayRange, occurrence: clip.occurrence)
                }
                guard validate(proposed, selecting: selectedID, at: playhead, action: "Replace Source Audio",
                               replacementTrack: plan.targetAudioOrdinal) else {
                    throw MCPCommandError("replacement_failed", alert?.message ?? "The new soundtrack could not be applied.")
                }
                completed?(.success(mcpRevision))
            } catch {
                let message = saved
                    ? published + " " + error.localizedDescription
                    : error.localizedDescription
                alert = EditorNotice(title: "Couldn’t Apply Replacement Audio", message: message)
                let code = (error as? MCPCommandError)?.code ?? (error as? CutError)?.code ?? "replacement_failed"
                completed?(.failure(MCPCommandError(code, message)))
            }
        }
        return token
    }

    func chooseResolveExport() {
        guard canEdit else { return }
        let project = stillProject
        let clips = segments.map(\.request)
        let imported = Array(edit.preparation.sourceMedia.values)
        let name = clips.first?.file.deletingPathExtension().lastPathComponent ?? "Untitled"
        ResolveExportPanel.choose(name: name, in: editorWindow) { output, open in
            guard self.canExport(to: output) else { return }
            self.runExport { token, _ in
                try ResolveExport.rejectUnsupportedStills(project)
                try ResolveExport.write(clips, to: output, matching: imported, cancelled: { token.isCancelled })
                if open { try ResolveExport.openInResolve(output, cancelled: { token.isCancelled }) }
                return (output, "Exported \(output.lastPathComponent).")
            }
        }
    }

    func chooseExport() {
        chooseExport(mode: nil)
    }

    func chooseSelectionExport() {
        guard canActOnRange, let span = selectedSpan else { return }
        chooseExport(mode: nil, candidate: pieces(in: span), selectionOnly: true)
    }

    func chooseExport(mode: ExportMode?) {
        chooseExport(mode: mode, candidate: segments, selectionOnly: false)
    }

    private func chooseExport(mode: ExportMode?, candidate: [EditorSegment], selectionOnly: Bool) {
        guard canEdit else { return }
        if let issue = candidate.compactMap(mediaReviewIssue).first {
            alert = EditorNotice(title: "Media Needs Review", message: issue)
            return
        }
        if case .stillSequence = stillProject {
            do {
                let project = selectionOnly ? try stillProjectForSelection() : stillProject
                let scope = try project.exportPlacementScope()
                if scope != .none {
                    cancelTrim()
                    preview.pause()
                    let source = candidate.first?.source.media ?? segments.first?.source.media
                    var options = exportOptions
                    options.placements = scope
                    options.tracks = .all
                    options.mode = mode ?? ExportRules.defaultStillMode(tracks: options.tracks, placements: scope, otherwise: defaultExportMode)
                    if !ExportRules.stillMovieAudioActions.contains(options.audio) { options.audio = .copyOriginal }
                    options.audioMode = .copy
                    options.audioTrackOrdinal = nil
                    let preferred = project.stillFormat?.container ?? preferredCopyContainer
                    options.copyContainer = preferred.flatMap { ExportRules.stillMovieContainers.contains($0) ? $0 : nil } ?? "mov"
                    let encode = ExportRules.stillContainers(mode: .encode, tracks: .all, codec: options.codec, audio: options.audio)
                    if !encode.contains(options.encodeContainer) { options.encodeContainer = encode.first ?? "mov" }
                    if !encode.contains(options.proResContainer) { options.proResContainer = encode.first ?? "mov" }
                    let containers = ExportContainerChoices(stillSource: source, cancelled: { false })
                    presentExport(options: options, copyContainers: containers, candidate: candidate,
                                  useSidecar: useAnalysisSidecars, selectionOnly: selectionOnly, stillProject: project)
                    return
                }
            } catch { showStillError(error); return }
        }
        guard let first = candidate.first else { return }
        cancelTrim()
        preview.pause()
        let currentSession = session
        let token = EditCancellation()
        cancellation = token
        isCheckingEdit = true
        let source = first.source.media
        let preferred = preferredCopyContainer
        let excluded = sidecarExclusions
        let useSidecar = useAnalysisSidecars
        // The whole timeline opens on the preferred mode unless its tier is lower, then on the tier's mode.
        // A selection is not the timeline, and a tier that is still being checked decides nothing.
        let opening = openingExportMode(mode, selectionOnly: selectionOnly)
        let media = Dictionary(candidate.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        Task {
            let (choices, verified) = await Task.detached(priority: .userInitiated) {
                AnalysisSidecar.$excludedSources.withValue(excluded) {
                    let clips = candidate.map(\.request)
                    let choices = ExportContainerChoices(source: source, clips: clips, preferred: preferred, cancelled: { token.isCancelled })
                    // The container this export plans in, by the rule the tier badge names its container with.
                    let request = ExportRequest(clips: clips, mode: opening, tracks: source.hasVideo ? .all : .audio)
                    let verified = ExportPlanner(cancelled: { token.isCancelled }, useSidecar: useSidecar)
                        .openingContainer(for: request, preferred: source.hasVideo ? preferred : nil, media: media)
                    return (choices, verified)
                }
            }.value
            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            let options = Self.openingExportOptions(exportOptions, mode: opening, convertingByName: mode == .encode, source: source,
                                                    choices: choices, preferred: preferred, verified: verified)
            presentExport(options: options, copyContainers: choices, candidate: candidate, useSidecar: useSidecar, selectionOnly: selectionOnly)
        }
    }

    /// The state the export sheet opens in. `verified` is the container the opening mode plans in
    /// (`ExportPlanner.openingContainer`), so the sheet never opens on a container that fails while another verifies.
    nonisolated static func openingExportOptions(_ current: ExportSheetOptions, mode: ExportMode, convertingByName: Bool,
                                                 source: MediaInfo, choices: ExportContainerChoices, preferred: String?,
                                                 verified: String?) -> ExportSheetOptions {
        var options = current
        options.placements = .none
        options.requireCameraCopy = false
        options.mode = mode
        options.tracks = source.hasVideo ? .all : .audio
        // Sound opens on Lossless Copy, whose alternatives are listed best first when the copy cannot be exact,
        // unless Convert Audio was asked for by name.
        options.audioMode = .copy
        options.audioTrackOrdinal = nil
        if !source.hasVideo, convertingByName,
           let format = ExportRules.namedConversions(sourceCodec: source.streams.first { $0.kind == "audio" }?.codec).first {
            options.convertAudio(to: format)
        }
        let available = choices.choices(for: options)
        if let verified, available.isEmpty || available.contains(verified) {
            options.copyContainer = verified
        } else if let preferred, options.tracks == .all, available.contains(preferred) {
            options.copyContainer = preferred
        } else {
            options.copyContainer = available.first ?? source.url.pathExtension.lowercased()
        }
        return options
    }

    private func presentExport(options: ExportSheetOptions, copyContainers: ExportContainerChoices,
                               candidate: [EditorSegment], useSidecar: Bool, selectionOnly: Bool, stillProject: CutProject? = nil) {
        let stem = candidate.first?.source.url.deletingPathExtension().lastPathComponent ?? "Stills"
        let panel = NSSavePanel()
        panel.title = selectionOnly ? "Export Selection" : "Export Media"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = exportDirectory
        panel.nameFieldStringValue = "\(stem) \(selectionOnly ? "Selection" : "Edit").\(options.container)"
        var media = Dictionary(candidate.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        if let reference = stillProject?.stillAudioReference,
           let source = segments.first(where: { $0.source.url.path == reference.file })?.source {
            media[source.url] = source.media
        }
        let currentSession = session
        let formatControl = ExportFormatControl(panel: panel, options: options, copyContainers: copyContainers,
                                               clips: candidate.map(\.request), media: media, useSidecar: useSidecar, excludedSources: sidecarExclusions,
                                               allowsApplyingReviewToTimeline: !selectionOnly, stillProject: stillProject,
                                               changed: { [weak self] options, explicitCopyContainer in
            guard let self, self.session == currentSession else { return }
            if stillProject == nil {
                self.exportOptions = options
                if explicitCopyContainer && !selectionOnly { self.preferCopyContainer(options.copyContainer) }
            }
        }, directoryChanged: { [weak self] directory in
            guard let self, self.session == currentSession else { return }
            self.exportDirectory = directory
        })
        isPresentingPanel = true
        present(panel) { [weak self, formatControl] accepted in
            formatControl.stopChecking()
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            if let adjusted = formatControl.appliedStillReview, self.stillProject == stillProject {
                do {
                    try self.applyStillProject(adjusted, action: "Adjust Still Boundary")
                } catch { self.showStillError(error) }
                self.resumePendingWork()
            } else if !selectionOnly, let review = formatControl.appliedReview {
                self.byHand { self.applyExportReview(review) }
                self.resumePendingWork()
            } else if accepted, let output = panel.url, let plan = formatControl.selectedStill {
                guard self.canExport(to: output) else { return }
                self.exportDirectory = output.deletingLastPathComponent()
                self.runExport { token, progress in
                    try StillExportPlanner(useSidecar: useSidecar, cancelled: { token.isCancelled })
                        .write(plan, to: output, progress: progress)
                    return (output, "Exported \(output.lastPathComponent).")
                }
            } else if accepted, let output = panel.url, let plan = formatControl.selected {
                self.exportDirectory = output.deletingLastPathComponent()
                self.export(plan, to: output)
            } else {
                self.resumePendingWork()
            }
        }
    }

    func applyExportReview(_ review: ExportCutReview) {
        guard !isEmpty, !isBusy, segments.count == review.original.count,
              zip(segments, review.original).allSatisfy({ segment, range in
                  segment.source.url == range.file && segment.start == range.from && segment.end == range.to
              }) else { return }
        let proposed = zip(segments, review.revised).map { segment, range in
            EditorSegment(id: segment.id, documentID: segment.documentID, source: segment.source, start: range.from ?? segment.start, end: range.to, displayRange: segment.displayRange, occurrence: segment.occurrence)
        }
        validate(proposed, selecting: selectedID, at: playhead, action: "Apply Reviewed Cuts")
    }

    func cancelExport() {
        guard isExporting else { return }
        isCancelling = true
        cancellation?.cancel()
    }

    func cancelAndWaitForExport(_ completion: @escaping () -> Void) -> Bool {
        let saving = lastSidecarWrite?.task
        guard !exportTasks.isEmpty || saving != nil else { return false }
        waitingForExportCleanup = true
        cancelExport()
        // A closed session may still be removing its staged file. Each closed
        // session already cancelled its own export when the window closed.
        let pending = Array(exportTasks.values)
        Task {
            for task in pending { await task.value }
            await saving?.value
            waitingForExportCleanup = false
            completion()
        }
        return true
    }

    func preserveAfterUnconfirmedClose() {
        let committed = committedBeforeImport ?? stillProject
        defer { draft.relinquish() }
        guard draft.hasScheduledWrites || hasUnsavedDocumentChanges else { return }
        // Closing can bypass the document prompt while an import is showing a partial
        // batch. Only edits accepted before that batch belong to the recovery project.
        let writer = documentWriter(project: committed)
        do { try draft.write { _ = try writer($0) } }
        catch { reportDraftError(error) }
    }

    func endSession() {
        mediaRefresh.reset()
        mediaRefreshProgress = nil
        mediaRefreshWarnings = [:]
        mediaClipReview = [:]
        refreshStaleScenes = []
        staleSceneReports = [:]
        refreshStaleSilence = []
        invalidatedQueueIDs = []
        refreshReviewStreams = [:]
        refreshReviewPicture = []
        offlineMedia = []
        incompatibleMedia = []
        refreshBaselines = [:]
        refreshSourceRevisions = [:]
        refreshDisplayRevisions = [:]
        refreshFilmstrips = [:]
        mediaWatcher?.stop()
        mediaWatcher = nil
        mcpSidecarReceipt?.finish("cancelled")
        mcpSilenceReceipt?.finish("cancelled")
        mcpSidecarReceipt = nil
        mcpSilenceReceipt = nil
        mcpGeneration = UUID()
        mcpRevision = 0
        committedBeforeImport = nil
        savedMediaPaths = [:]
        lastSidecarPaths = []
        lastSidecarCandidates = []
        sidecarExclusions = []
        sidecarPreference.setExclusions([])
        rangeTool = false
        projectURL = nil
        projectDiskRevision = nil
        openingProjectURL = nil
        savedSequence = []
        savedStillSequence = nil
        stillTimelineIDs.removeAll()
        savedUndoIDs = []
        savedRedoIDs = []
        recoveredDraft = false
        deferredDraftSave = false
        draft.discard()
        cancelTrim()
        usesPointerPosition = false
        filmstripTiles = FilmstripTileBuffer()
        sidecarSaveToken?.cancel()
        sidecarSaveToken = nil
        pendingMetadata.removeAll()
        isSavingSidecars = false
        for task in pauseDetections.values { task.cancel() }
        pauseDetections.removeAll()
        mcpSilenceWorkers.removeAll()
        silenceMedia.removeAll()
        silenceResults.removeAll()
        silenceIssues.removeAll()
        checkedSilenceSidecars.removeAll()
        pendingSilenceRescans.removeAll()
        silenceScanRequested = false
        audioStore.clear()
        sourcePauses.removeAll()
        automaticThresholds.removeAll()
        thresholdOverrides.removeAll()
        protectedPauses.removeAll()
        pausePlan.removeAll()
        shortenedPauseCount = 0
        removedPauseSeconds = 0
        cutPreview = nil
        skipPauses = false
        mcpSceneReceipt?.finish("cancelled")
        mcpSceneReceipt = nil
        sceneScan.reset()
        previousSceneClip = nil
        sceneRangeReports.removeAll()
        staleSceneRangeReports.removeAll()
        sceneOverlays.removeAll()
        sourceSceneOverlays.removeAll()
        snapScanRequests.removeAll()
        sceneReports.removeAll()
        scenesBySource.removeAll()
        viewNamesBySource.removeAll()
        cancellation?.cancel()
        cancellation = nil
        session = UUID()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingOpenFiles.removeAll()
        queuedRanges.removeAll()
        isBulkQueuePresented = false
        exportOptions = ExportSheetOptions()
        exportOptions.mode = defaultExportMode
        exportDirectory = nil
        timelineZoom = 0
        explicitCopyContainer = nil
        copyBoundaryIndices.removeAll()
        checkingTrim = nil
        trimChecks.removeAll()
        edit = EditSnapshot()
        refreshTier()
        prepareCopyBoundaries()
        audioMonitoring = .followSource
        trimOrigin = nil
        trimAudition = nil
        isImporting = false
        isCheckingEdit = false
        isPresentingPanel = false
        isExporting = false
        isCancelling = false
        alert = nil
        restorePreview(at: 0)
        updateStatus()
    }

    func thumbnail(for sourceID: UUID, at sourceTime: Double, size: CGSize) async -> CGImage? {
        if let placementID = stillTimelineIDs.first(where: { $0.value == sourceID })?.key,
           let card = inlineStills(in: stillProject).first(where: { $0.insert.id == placementID }),
           let frame = try? stillProject.stillReviewFrame(placementID: placementID,
                                                          interval: MulticamRange(from: card.start, to: card.end),
                                                          document: projectURL, canvas: stillReviewCanvas) {
            let maximum = max(1, Int(min(max(size.width, size.height), 1_024)))
            return await MulticamThumbnailWork.shared.run(url: frame.url) {
                let work = Task.detached(priority: .utility) {
                    try frame.image(maximumDimension: maximum, cancelled: { Task.isCancelled })
                }
                return await withTaskCancellationHandler {
                    try? await work.value
                } onCancel: { work.cancel() }
            }
        }
        if let draft = refreshFilmstrips[sourceID] {
            guard draft.media.identity.isCurrentSnapshot(at: draft.media.url),
                  sourceTime >= 0, sourceTime < draft.media.duration.seconds else { return nil }
            let image = await preview.thumbnail(source: draft.decoderID, url: draft.media.url, at: sourceTime,
                                                size: size, nearbyKeyframe: true,
                                                useNativeDecoder: !draft.media.format.split(separator: ",").contains("matroska"))
            guard refreshFilmstrips[sourceID]?.decoderID == draft.decoderID,
                  draft.media.identity.isCurrentSnapshot(at: draft.media.url) else { return nil }
            return image
        }
        guard let media = edit.preparation.sourceMedia[sourceID], media.hasVideo,
              !offlineMedia.contains(media.url) else { return nil }
        let revision = refreshDisplayRevisions[sourceID]
        // The header used during provisional import can have a different presentation clock.
        let key = media.frames.isEmpty ? nil : FilmstripTileKey(time: sourceTime, size: size)
        let saved = sidecarPreference.permits(media.url) ? key.map { (AnalysisSidecar(media: media), $0) } : nil
        let image = await preview.thumbnail(source: sourceID, url: media.url, at: sourceTime, size: size, saved: saved,
                                       nearbyKeyframe: media.frames.isEmpty,
                                       useNativeDecoder: !media.frames.isEmpty || !media.format.split(separator: ",").contains("matroska"),
                                       cacheEnabled: { [sidecarPreference] in sidecarPreference.permits(media.url) },
                                       preserveAlpha: media.video.hasAlpha || media.video.hasAdditionalVideoLayers) { image in
            if let key, self.refreshFilmstrips[sourceID] == nil, self.refreshDisplayRevisions[sourceID] == revision,
               self.edit.preparation.sourceMedia[sourceID] != nil {
                self.filmstripTiles.remember(FilmstripTile(key: key, image: image), source: sourceID)
            }
        }
        return refreshFilmstrips[sourceID] == nil && refreshDisplayRevisions[sourceID] == revision ? image : nil
    }

    private func deleteMarkedRange(_ marked: ClosedRange<RationalTime>) {
        let pointerLower = marked.lowerBound == edit.markIn ? edit.pointerMarkIn : edit.pointerMarkOut
        let pointerUpper = marked.upperBound == edit.markOut ? edit.pointerMarkOut : edit.pointerMarkIn
        let keepsLeading = marked.lowerBound > .zero
        let keepsTrailing = marked.upperBound < edit.duration
        func boundary(at index: Int, target: RationalTime, edge: TimelineEdge) -> RationalTime? {
            if edge == .end ? pointerLower : pointerUpper { return target }
            let segment = segments[index]
            switch effectiveSnapTarget {
            case .off: return target
            case .scenes, .silence:
                if let cut = analysisBoundary(in: segment, to: target.seconds, after: segment.start, before: segment.end) {
                    return cut
                }
                showAnalysisBoundaryError(segment, title: "Can’t Delete Marked Range")
            case .keyframes:
                let first = edge == .start ? !keepsLeading : isContinuousCopyRange(segments.prefix(index + 1))
                let last = edge == .end ? !keepsTrailing : isContinuousCopyRange(segments.suffix(from: index))
                let bounds = copyBoundaries(for: segment.source)
                let choices = edge == .start ? bounds?.starts(first: first, last: last) : bounds?.ends(first: first, last: last)
                if let cut = nearest(in: choices ?? [], to: target.seconds, after: segment.start, before: segment.end) {
                    return cut
                }
                showCopyBoundaryError(segment, at: target.seconds, edge: edge, title: "Can’t Delete Marked Range",
                                      first: first, last: last)
            }
            return nil
        }

        var before: [EditorSegment] = []
        var after: [EditorSegment] = []
        for (index, pair) in zip(segments, edit.offsets).enumerated() {
            let (segment, offset) = pair
            let end = offset + segment.duration
            if end <= marked.lowerBound {
                before.append(segment)
            } else if offset < marked.lowerBound {
                guard let wanted = try? segment.start.adding(marked.lowerBound.subtracting(offset)) else {
                    alert = EditorNotice(title: "Can’t Delete Marked Range", message: "The selection exceeds the supported time precision.")
                    return
                }
                guard let cut = boundary(at: index, target: wanted, edge: .end) else { return }
                var left = segment
                left.end = cut
                before.append(left)
            }
            if offset >= marked.upperBound {
                after.append(segment)
            } else if end > marked.upperBound {
                guard let wanted = try? segment.start.adding(marked.upperBound.subtracting(offset)) else {
                    alert = EditorNotice(title: "Can’t Delete Marked Range", message: "The selection exceeds the supported time precision.")
                    return
                }
                guard let cut = boundary(at: index, target: wanted, edge: .start) else { return }
                if let left = before.last, left.id == segment.id, left.end >= cut {
                    alert = EditorNotice(title: "Can’t Delete Marked Range", message: "Both marks fall on the same cut point. Move them farther apart.")
                    return
                }
                if let left = before.last, left.id == segment.id {
                    // Preserve handles at the outside ends of a clip cut in two.
                    before[before.count - 1].displayRange = AudioSpan(from: min(left.start, segment.displayRange?.from ?? .zero),
                                                                      to: left.end)
                    let rightDisplay = AudioSpan(from: cut, to: max(segment.end, segment.displayRange?.to ?? segment.source.duration))
                    after.append(EditorSegment(source: segment.source, start: cut, end: segment.end,
                                               displayRange: rightDisplay, occurrence: segment.occurrence))
                } else {
                    var right = segment
                    right.start = cut
                    after.append(right)
                }
            }
        }
        let proposed = before + after
        if effectiveSnapTarget == .keyframes, !pointerLower, !pointerUpper, !proposed.isEmpty, let error = copyIssue(proposed) {
            alert = EditorNotice(title: "Can’t Delete Marked Range", message: copyMessage(error, in: proposed))
            return
        }
        validate(proposed, selecting: after.first?.id ?? before.last?.id, at: sequenceDuration(before),
                 action: "Delete Marked Range")
    }

    private func isContinuousCopyRange(_ pieces: ArraySlice<EditorSegment>) -> Bool {
        if pieces.count == 1 { return true }
        guard let first = pieces.first, let container = preferredCopyContainer,
              CutEngine().coalescesAdjacentRanges(in: first.source.media, container: container) else { return false }
        return zip(pieces, pieces.dropFirst()).allSatisfy {
            $0.source.id == $1.source.id && $0.end == $1.start
        }
    }

    private func trimCandidates(at index: Int, edge: TimelineEdge, boundaries: BoundaryIndex) -> [RationalTime] {
        let segment = segments[index]
        let first = index == 0
        let last = index == segments.count - 1
        guard let container = preferredCopyContainer,
              CutEngine().coalescesAdjacentRanges(in: segment.source.media, container: container) else {
            return edge == .start ? boundaries.starts(first: first, last: last) : boundaries.ends(first: first, last: last)
        }
        var beginning = index
        var ending = index
        while beginning > 0, segments[beginning - 1].source.id == segment.source.id,
              segments[beginning - 1].end == segments[beginning].start { beginning -= 1 }
        while ending < segments.count - 1, segments[ending + 1].source.id == segment.source.id,
              segments[ending].end == segments[ending + 1].start { ending += 1 }

        var choices = edge == .start
            ? boundaries.starts(first: first, last: ending == segments.count - 1)
            : boundaries.ends(first: beginning == 0, last: last)
        let neighborIndex = edge == .start ? index - 1 : index + 1
        if segments.indices.contains(neighborIndex), segments[neighborIndex].source.id == segment.source.id {
            let neighbor = segments[neighborIndex]
            let seam = edge == .start ? neighbor.end : neighbor.start
            let insertion = choices.lowerBound { $0 >= seam }
            if insertion == choices.count || choices[insertion] != seam { choices.insert(seam, at: insertion) }
        }
        return choices
    }

    /// Full packet scans for large recordings run before keyframe edits are admitted.
    /// Small indexes stay lazy, as building those only when a handle is used avoids
    /// preparing every short clip when opening a project or changing the snap target.
    private func prepareCopyBoundaries() {
        boundaryPreparation?.cancel()
        boundaryPreparation = nil
        boundaryPreparationID = nil
        guard !isImporting, effectiveSnapTarget == .keyframes, let container = preferredCopyContainer else {
            isPreparingCopyBoundaries = false
            return
        }
        let sources = edit.preparation.sourceMedia.filter { id, media in
            copyBoundaryIndices[id] == nil && media.hasFullEditIndex && media.indexStorageBytes >= PreparedEdit.backgroundCopyCheckBytes
        }
        guard !sources.isEmpty else {
            isPreparingCopyBoundaries = false
            return
        }
        let id = UUID()
        boundaryPreparationID = id
        isPreparingCopyBoundaries = true
        boundaryPreparation = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                var indices: [UUID: BoundaryIndex] = [:]
                for (id, media) in sources {
                    guard !Task.isCancelled else { break }
                    indices[id] = try? BoundaryIndex(media: media, container: container, engine: CutEngine(cancelled: { Task.isCancelled }))
                }
                return indices
            }
            let indices = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, self.boundaryPreparationID == id else { return }
            self.copyBoundaryIndices.merge(indices) { _, new in new }
            self.boundaryPreparation = nil
            self.boundaryPreparationID = nil
            self.isPreparingCopyBoundaries = false
            self.rebuildPausePlan()
            self.resumePendingWork()
        }
    }

    private func copyBoundaries(for source: IndexedSource) -> BoundaryIndex? {
        guard let container = preferredCopyContainer else { return nil }
        if let cached = copyBoundaryIndices[source.id] { return cached }
        if isPreparingCopyBoundaries || (isImporting && source.media.indexStorageBytes >= PreparedEdit.backgroundCopyCheckBytes) { return nil }
        let index = try? BoundaryIndex(media: source.media, container: container, engine: CutEngine())
        copyBoundaryIndices[source.id] = index
        return index
    }

    private func copyIssue(_ proposed: [EditorSegment]) -> CutError? {
        Self.copyIssue(proposed, container: preferredCopyContainer, engine: CutEngine())
    }

    private nonisolated static func copyIssue(_ proposed: [EditorSegment], container: String?, engine: CutEngine) -> CutError? {
        guard let container else {
            return CutError(code: "unsupported_container", message: "No copy container is available for this source.")
        }
        do {
            _ = try Self.resolve(proposed, engine: engine, container: container)
            return nil
        } catch let issue as CutError {
            return issue
        } catch {
            return CutError(code: "unsafe_boundary", message: error.localizedDescription)
        }
    }

    // Trying another candidate cannot repair a fixed, non-random-access picture
    // elsewhere. A moved edge can still remove a neighbor's unsafe seam by
    // rejoining continuous source ranges, so keep looking in that case.
    private nonisolated static func blocksAllSnapCandidates(_ issue: CutError, in proposed: [EditorSegment], container: String?,
                                         moving id: UUID? = nil, edge: TimelineEdge? = nil) -> Bool {
        if issue.code == "source_changed" || issue.code == "unsupported_tracks" { return true }
        guard issue.code == "unsafe_boundary", let number = issue.segment, proposed.indices.contains(number - 1),
              let field = issue.boundary, field == "from" || field == "to" else { return false }
        let index = number - 1
        let segment = proposed[index]
        let failedEdge: TimelineEdge = field == "from" ? .start : .end
        if segment.id == id && failedEdge == edge { return false }
        let neighbor = failedEdge == .start ? index - 1 : index + 1
        if proposed.indices.contains(neighbor), proposed[neighbor].id == id, edge != failedEdge,
           proposed[neighbor].source.id == segment.source.id, let container,
           CutEngine().coalescesAdjacentRanges(in: segment.source.media, container: container) { return false }
        let media = segment.source.media
        let time = failedEdge == .start ? segment.start : segment.end
        if time == .zero { return failedEdge == .start && !media.sourceStartSafe }
        if time == media.duration { return false }
        let frame = media.frames.lowerBound { $0.time >= time }
        guard frame < media.frames.count, media.frames[frame].time == time else { return true }
        return failedEdge == .start ? !media.frames[frame].canStart : !media.frames[frame].canEnd
    }

    private func copyMessage(_ issue: CutError, in proposed: [EditorSegment]) -> String {
        var message = issue.message
        if let index = issue.segment, proposed.indices.contains(index - 1) {
            message = "Clip \(index) · \(proposed[index - 1].source.name)\n\(message)"
        }
        if issue.code == "unsafe_boundary", copyIssue(segments)?.code == "unsafe_boundary" {
            message += "\n\nChoose Lossless Copy in Export, then Review Cuts to see which cut points would move."
        }
        return message
    }

    private func showCopyBoundaryError(_ segment: EditorSegment, at target: Double, edge: TimelineEdge,
                                       title: String, first: Bool? = nil, last: Bool? = nil) {
        let time = nearestCopyPictureBoundary(in: segment, to: target, edge: edge)
        let audioIssue = time.flatMap { boundary in
            linkedAudioIssue(for: segment, at: boundary, edge: edge,
                             first: first ?? (segment.id == segments.first?.id),
                             last: last ?? (segment.id == segments.last?.id))
        }
        var attempted = segment
        if let time {
            if edge == .start { attempted.start = time } else { attempted.end = time }
        }
        let proposed = segments.map { $0.id == segment.id ? attempted : $0 }
        let message = audioIssue.map { "\(segment.source.name) — \($0.message)" }
            ?? copyIssue(proposed).map { copyMessage($0, in: proposed) }
            ?? "There is no verified cut point inside the range in \(segment.source.name)."
        alert = EditorNotice(title: title, message: message)
    }

    private func nearestCopyPictureBoundary(in segment: EditorSegment, to target: Double,
                                            edge: TimelineEdge) -> RationalTime? {
        let media = segment.source.media
        var candidates: [RationalTime] = edge == .start && media.sourceStartSafe ? [.zero] : []
        candidates += media.frames.compactMap { frame in
            guard frame.time > .zero, frame.time < media.duration else { return nil }
            return (edge == .start ? frame.canStart : frame.canEnd) ? frame.time : nil
        }
        if edge == .end { candidates.append(media.duration) }
        return edge == .start
            ? nearest(in: candidates, to: target, before: segment.end)
            : nearest(in: candidates, to: target, after: segment.start)
    }

    private func linkedAudioIssue(for segment: EditorSegment, at boundary: RationalTime, edge: TimelineEdge,
                                  first: Bool, last: Bool) -> CutError? {
        guard let container = preferredCopyContainer,
              boundary != (edge == .start ? segment.start : segment.end) else { return nil }
        return CutEngine().linkedAudioBoundaryIssue(in: segment.source.media, at: boundary,
                                                    start: edge == .start, first: first, last: last, container: container)
    }

    private nonisolated static func checkEditable(_ media: MediaInfo) throws {
        if let reason = media.timelineIssue {
            throw CutError(code: "unsupported_timeline", message: reason)
        }
        guard media.duration > .zero, media.hasVideo ? !media.frames.isEmpty : !media.audio.isEmpty else {
            throw CutError(code: "invalid_input", message: "The source has no indexed pictures or audio samples.")
        }
    }

    private func export(_ plan: EditorExportPlan, to output: URL) {
        guard !isEmpty, !isBusy, canExport(to: output) else { return }
        runExport { token, progress in
            try plan.writeOutput(to: output, cancelled: { token.isCancelled }) { _ = progress($0) }
            return (output, "Exported \(output.lastPathComponent)")
        }
    }

    private func runExport(_ work: @escaping @Sendable (EditCancellation, @escaping @Sendable (Double) -> Bool)
                           throws -> (URL, String)) {
        preview.pause()
        lastExportedURL = nil
        isExporting = true
        isCancelling = false
        exportProgress = 0
        let currentSession = session
        let useSidecar = useAnalysisSidecars
        let excluded = sidecarExclusions
        let token = EditCancellation()
        cancellation = token
        let reportProgress: @Sendable (Double) -> Bool = { [weak self] progress in
            guard !token.isCancelled else { return false }
            if token.shouldReport(progress) {
                Task { @MainActor in
                    guard let self, self.cancellation === token, self.isExporting else { return }
                    self.exportProgress = max(self.exportProgress, progress)
                }
            }
            return true
        }
        exportTasks[currentSession] = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try AnalysisSidecar.$excludedSources.withValue(excluded) {
                        try AnalysisSidecar.$readsEnabled.withValue(useSidecar) { try work(token, reportProgress) }
                    }
                }
            }.value

            exportTasks.removeValue(forKey: currentSession)
            guard session == currentSession else { return }
            isExporting = false
            isCancelling = false
            cancellation = nil
            defer { resumePendingWork() }
            switch result {
            case .failure(let error):
                if token.isCancelled {
                    statusMessage = (error as? CutError)?.code == "bulk_interrupted"
                        ? error.localizedDescription : "Export cancelled."
                } else {
                    statusMessage = "Export failed."
                    alert = EditorNotice(title: "Export Failed", message: error.localizedDescription)
                }
            case .success(let (output, message)):
                lastExportedURL = output
                statusMessage = message
            }
        }
    }

    @discardableResult
    private func validate(_ proposed: [EditorSegment], selecting id: UUID?, at destination: Double,
                          action: String, originalPlayhead: Double? = nil, replacementTrack: Int? = nil, preserveMarks: Bool = false) -> Bool {
        cancelTrim()
        preview.pause()
        let original = originalPlayhead ?? playhead
        guard proposed.allSatisfy({ $0.start >= .zero && $0.start < $0.end && $0.end <= $0.source.duration }) else {
            restorePreview(at: original)
            alert = EditorNotice(title: "Couldn’t \(action)", message: "Keep a nonempty range within each source.")
            return false
        }
        // An edit made by hand that would lower the timeline tier is asked about first. Every other edit is applied
        // at once, as is one whose answer is known at once. A pending question counts as accepted here: the timeline
        // changes when it is answered, or stays as it is when declined.
        var applied = true
        confirmTier(from: segments, to: proposed, action: action) { [self] accepted in
            guard let accepted else {
                restorePreview(at: original)
                applied = false
                return
            }
            let prepared = PreparedEdit(segments: accepted, previous: edit.preparation, engine: CutEngine())
            // Only cuts moved to their nearest exact point can leave the playhead beyond the new end.
            let moved = zip(accepted, proposed).contains { $0.start != $1.start || $0.end != $1.end }
            let landing = moved ? min(destination, accepted.reduce(0) { $0 + $1.duration.seconds }) : destination
            applied = apply(accepted, prepared: prepared, selecting: id, at: landing, action: action,
                            originalPlayhead: original, replacementTrack: replacementTrack, preserveMarks: preserveMarks)
        }
        return applied
    }

    private nonisolated static func resolve(_ segments: [EditorSegment], engine: CutEngine,
                                           container: String? = nil) throws -> ResolvedEdit {
        let media = Dictionary(segments.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        return try engine.resolve(segments.map(\.request), media: media, container: container)
    }

    @discardableResult
    private func apply(_ proposed: [EditorSegment], prepared: PreparedEdit, selecting id: UUID?, at destination: Double,
                       action: String, originalPlayhead: Double? = nil, recordHistory: Bool = true,
                       historySnapshot: EditSnapshot? = nil, preservePreview: Bool = false, replacementTrack: Int? = nil,
                       preserveMarks: Bool = false, restoringAudioMonitoring: AudioMonitoring? = nil,
                       sequenceProject: CutProject? = nil) -> Bool {
        var duration = RationalTime.zero
        var offsets: [RationalTime] = []
        offsets.reserveCapacity(proposed.count)
        do {
            for segment in proposed {
                offsets.append(duration)
                duration = try duration.adding(segment.end.subtracting(segment.start))
            }
        } catch {
            restorePreview(at: originalPlayhead ?? playhead)
            alert = EditorNotice(title: "Couldn’t Apply Edit", message: error.localizedDescription)
            return false
        }
        let stillPresentation = sequenceProject ?? reconciledStillProject(proposed)
        do {
            try stillPresentation?.validate()
            if let stillPresentation, !stillPresentation.stillReplacements.isEmpty {
                let extents = Dictionary(uniqueKeysWithValues: proposed.map { ($0.documentID, $0.source.duration) })
                for placement in stillPresentation.stillReplacements {
                    guard case .sequence(let fragments) = placement.coverage else { continue }
                    for fragment in fragments {
                        guard let extent = extents[fragment.clipID], fragment.range.to <= extent else {
                            throw CutError(code: "invalid_still_target",
                                           message: "Placement \(placement.id) extends beyond source clip \(fragment.clipID).")
                        }
                    }
                }
            }
        } catch {
            restorePreview(at: originalPlayhead ?? playhead)
            alert = EditorNotice(title: "Couldn’t Apply Edit", message: error.localizedDescription)
            return false
        }
        if recordHistory {
            var original = historySnapshot ?? snapshot()
            if let originalPlayhead { original.playhead = originalPlayhead }
            undoStack.append(HistoryEntry(action: action, contents: .live(original), copyContainer: explicitCopyContainer,
                                          audioMonitoring: replacementTrack.map { _ in audioMonitoring }))
            redoStack.removeAll()
            enforceHistoryLimit()
        }
        if proposed.isEmpty, explicitCopyContainer != nil {
            // The next import may use a format that this container cannot carry.
            explicitCopyContainer = nil
            copyBoundaryIndices.removeAll()
        }
        trimOrigin = nil
        trimAudition = nil
        checkingTrim = nil
        trimChecks.removeAll()
        if prepared.container != edit.preparation.container {
            copyBoundaryIndices.removeAll()
        } else {
            copyBoundaryIndices = copyBoundaryIndices.filter { prepared.sourceMedia[$0.key] != nil }
        }
        filmstripTiles.keepSources(Set(prepared.sourceMedia.keys))
        let clips = proposed.indices.map { index in
            let end = index + 1 < offsets.count ? offsets[index + 1] : duration
            let segment = proposed[index]
            var clip = segment.timeline(sequenceRange: offsets[index].seconds..<end.seconds)
            clip.mediaRevision = refreshDisplayRevisions[segment.source.id] ?? 0
            clip.mediaIssue = mediaReviewIssue(segment)
            return clip
        }
        mediaClipReview = Dictionary(uniqueKeysWithValues: clips.compactMap { clip in
            clip.mediaIssue.map { (clip.id, $0) }
        })
        let previousPreview = preservePreview ? segments.map(monitoredPreview) : []
        let keepMarks = preserveMarks || (recordHistory && replacementTrack != nil)
        mcpRevision += 1
        edit = EditSnapshot(documentClips: sequenceClips(for: proposed), segments: proposed, timelineClips: clips,
                            timelineThumbnailHeight: clips.lazy.map(\.thumbnailHeight).max() ?? TimelineClip.minimumThumbnailHeight,
                            largeThumbnailHeight: clips.lazy.map { $0.thumbnailHeight(large: true) }.max() ?? TimelineClip.minimumLargeThumbnailHeight,
                            preparation: prepared, selectedID: id,
                            markIn: keepMarks ? edit.markIn : nil, markOut: keepMarks ? edit.markOut : nil,
                            pointerMarkIn: keepMarks && edit.pointerMarkIn, pointerMarkOut: keepMarks && edit.pointerMarkOut,
                            playhead: destination,
                            offsets: offsets, duration: duration)
        if let stillPresentation { installStillPresentation(stillPresentation, updatesPreview: false) }
        prepareCopyBoundaries()
        if let restoringAudioMonitoring {
            audioMonitoring = restoringAudioMonitoring
        } else if replacementTrack != nil {
            audioMonitoring = .followSource
        }
        syncWaveforms()
        requestSnapAnalysis()
        if stillPresentation != nil || !preservePreview || previousPreview != proposed.map(monitoredPreview) { restorePreview(at: destination) }
        updateStatus()
        if recordHistory { saveUntitledDraft() }
        refreshTier()
        return true
    }

    // MARK: Timeline tier

    private nonisolated static func tierInput(_ segments: [EditorSegment]) -> (clips: [ClipRequest], media: [URL: MediaInfo]) {
        (segments.map(\.request), Dictionary(segments.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first }))
    }

    /// The source ranges of a timeline with joined ranges of one source written as one, for comparing two timelines.
    private nonisolated static func joinedRanges(_ clips: [ClipRequest]) -> [[String]] {
        var ranges: [(file: URL, from: RationalTime, to: RationalTime?)] = []
        for clip in clips {
            let from = clip.from ?? .zero
            if let last = ranges.last, last.file == clip.file, let seam = last.to, seam == from {
                ranges[ranges.count - 1].to = clip.to
            } else {
                ranges.append((clip.file, from, clip.to))
            }
        }
        return ranges.map { [$0.file.path, $0.from.description, $0.to?.description ?? ""] }
    }

    /// Checks the tier of the timeline as it is now. A small timeline is checked at once, a large one off the main
    /// actor. A result for a timeline that has since changed is dropped.
    func refreshTier() {
        tierGeneration += 1
        tierToken?.cancel()
        tierToken = nil
        let project = stillProject
        let placements = (try? project.exportPlacementScope()) ?? .none
        guard !segments.isEmpty || placements != .none else {
            tierIsCurrent = true
            if tierState != nil { tierState = nil }
            return
        }
        let input = Self.tierInput(segments)
        let evaluator = tierEvaluator
        // The badge names the container the export sheet opens on: the preferred one when the timeline verifies in it.
        evaluator.preferredContainer = hasPicture ? preferredCopyContainer : nil
        guard placements != .none || edit.preparation.requiresBackgroundCopyChecks else {
            tierIsCurrent = true
            tierState = evaluator.evaluate(input.clips, media: input.media)
            return
        }
        let generation = tierGeneration, token = EditCancellation()
        tierToken = token
        tierIsCurrent = false
        if tierState == nil { tierState = .checking }
        let preferred = preferredCopyContainer
        let useSidecar = useAnalysisSidecars
        let excluded = sidecarExclusions
        Task {
            let state = await Task.detached(priority: .utility) {
                if placements != .none {
                    return AnalysisSidecar.$excludedSources.withValue(excluded) {
                        StillExportPlanner(useSidecar: useSidecar, cancelled: { token.isCancelled })
                            .tier(project, preferredContainer: preferred)
                    }
                }
                return evaluator.evaluate(input.clips, media: input.media, cancelled: { token.isCancelled })
            }.value
            guard tierGeneration == generation, !token.isCancelled else { return }
            tierToken = nil
            tierIsCurrent = true
            tierState = state
        }
    }

    /// The tier an export may rely on: nil while it is being checked.
    var settledTier: FidelityTier? { tierIsCurrent ? tierState?.tier : nil }

    /// The mode the export sheet opens on: the one asked for, or the preferred one unless the timeline's tier is lower.
    func openingExportMode(_ requested: ExportMode? = nil, selectionOnly: Bool = false) -> ExportMode {
        if let requested { return requested }
        if case .stillSequence = stillProject {
            let snapshot = selectionOnly ? try? stillProjectForSelection() : stillProject
            if let snapshot, let scope = try? snapshot.exportPlacementScope(), scope != .none {
                return ExportRules.defaultStillMode(tracks: .all, placements: scope, otherwise: defaultExportMode)
            }
        }
        // A mixed timeline's tier is Re-encode whatever its cuts are, so the sheet need not wait for the check to settle.
        let tier = selectionOnly ? nil : settledTier ?? (isMixedTimeline ? .reencode : nil)
        return ExportRules.openingMode(preferred: defaultExportMode, tier: tier, source: hasPicture ? .movie : .audio)
    }

    /// Runs an edit made by hand, so that it asks before lowering the tier.
    func byHand(_ edit: () -> Void) {
        asking(true, edit)
    }

    private func asking<Result>(_ asks: Bool, _ body: () -> Result) -> Result {
        let previous = asksBeforeLoweringTier
        asksBeforeLoweringTier = asks
        defer { asksBeforeLoweringTier = previous }
        return body()
    }

    /// Selects the clip of a factor and moves the playhead to its cut.
    func goToTierFactor(_ factor: TierFactor) {
        guard canNavigate, let number = factor.segment, segments.indices.contains(number - 1) else { return }
        let index = number - 1
        select(segments[index].id)
        let segment = segments[index], offset = edit.offsets[index]
        seek(factor.boundary == "to"
            ? segment.sequenceSeconds(at: precedingFrame(in: segment, before: segment.end), offset: offset) : offset.seconds)
    }

    /// Decides an edit that would change the timeline from `current` to `proposed`. `decide` receives the segments to
    /// apply, or nil when the edit was declined. It is called before this returns unless a question had to be asked
    /// or the timeline is large enough to be checked off the main actor.
    private func confirmTier(from current: [EditorSegment], to proposed: [EditorSegment], action: String,
                             offersNearest: Bool = true, abandoned: (() -> Void)? = nil,
                             decide: @escaping ([EditorSegment]?) -> Void) {
        // A timeline that already has no tier cannot go lower.
        let hasNoTier = tierIsCurrent && tierState != nil && tierState?.tier == nil && current.map(\.id) == segments.map(\.id)
        guard asksBeforeLoweringTier, preferences.warnBeforeLoweringExportTier, !current.isEmpty, !proposed.isEmpty, !hasNoTier else {
            decide(proposed)
            return
        }
        let before = Self.tierInput(current), after = Self.tierInput(proposed)
        let evaluator = tierEvaluator
        let work: @Sendable (@escaping @Sendable () -> Bool) -> TierPrompt? = { cancelled in
            guard case .known(let was, _, _, _) = evaluator.evaluate(before.clips, media: before.media, cancelled: cancelled) else { return nil }
            let becomes = evaluator.evaluate(after.clips, media: after.media, cancelled: cancelled)
            switch becomes {
            case .checking: return nil
            case .known(let tier, _, _, _) where tier >= was: return nil
            default: break
            }
            let known = Set(evaluator.evaluate(before.clips, media: before.media, cancelled: cancelled).factors.map(\.message))
            let added = becomes.factors.filter { !known.contains($0.message) }
            var moved = offersNearest ? evaluator.snapped(after.clips, media: after.media, to: was, cancelled: cancelled) : nil
            // Moving the cuts must still be this edit. An edit that changes what plays, such as removing a range,
            // is not offered a version that plays what the timeline played before.
            let played = Self.joinedRanges(before.clips)
            if let candidate = moved, Self.joinedRanges(candidate) == played, Self.joinedRanges(after.clips) != played { moved = nil }
            return TierPrompt(action: action, from: was, to: becomes, factors: added.isEmpty ? becomes.factors : added,
                              nearest: moved, soundOnly: after.media[after.clips[0].file.standardizedFileURL]?.hasVideo == false)
        }
        let ask: (TierPrompt?) -> Void = { [self] prompt in
            guard let prompt else { return decide(proposed) }
            let currentSession = session
            let wasPresenting = isPresentingPanel
            isPresentingPanel = true
            let answer: (TierPrompt.Choice) -> Void = { [self] choice in
                guard session == currentSession else { abandoned?(); return }
                isPresentingPanel = wasPresenting
                if choice.dontAskAgain { preferences.warnBeforeLoweringExportTier = false }
                switch choice.answer {
                case .cancel: decide(nil)
                case .proceed: decide(proposed)
                case .nearest:
                    guard let moved = prompt.nearest, moved.count == proposed.count else { return decide(proposed) }
                    decide(zip(proposed, moved).enumerated().map { index, pair in
                        let (segment, clip) = pair
                        var snapped = segment
                        snapped.start = clip.from ?? segment.start
                        snapped.end = clip.to ?? segment.end
                        // A split ends what each piece shows at the cut. That edge moves with the cut, or the
                        // timeline would draw the other piece's pictures as a handle of this one.
                        if let shown = segment.displayRange {
                            let joinsBefore = index > 0 && proposed[index - 1].occurrence == segment.occurrence
                                && proposed[index - 1].end == segment.start && shown.from == segment.start
                            let joinsAfter = index + 1 < proposed.count && proposed[index + 1].occurrence == segment.occurrence
                                && proposed[index + 1].start == segment.end && shown.to == segment.end
                            snapped.displayRange = AudioSpan(from: joinsBefore ? snapped.start : min(shown.from, snapped.start),
                                                             to: joinsAfter ? snapped.end : max(shown.to, snapped.end))
                        }
                        return snapped
                    })
                }
                if !wasPresenting { resumePendingWork() }
            }
            if let tierPrompt { tierPrompt(prompt, answer) } else { TierPrompt.present(prompt, in: sheetWindow, answer: answer) }
        }
        let large = edit.preparation.requiresBackgroundCopyChecks
            || after.media.values.reduce(0) { $0 + $1.indexStorageBytes } >= PreparedEdit.backgroundCopyCheckBytes
        guard large else { return ask(work({ false })) }
        let currentSession = session, token = EditCancellation()
        let wasChecking = isCheckingEdit, previous = cancellation
        cancellation = token
        isCheckingEdit = true
        Task {
            let prompt = await Task.detached(priority: .userInitiated) { work({ token.isCancelled }) }.value
            guard session == currentSession else { abandoned?(); return }
            if cancellation === token { cancellation = previous }
            isCheckingEdit = wasChecking
            guard !token.isCancelled else { return decide(nil) }
            ask(prompt)
            if !isPresentingPanel { resumePendingWork() }
        }
    }

    private var hasUnsavedDocumentChanges: Bool {
        recoveredDraft || (committedBeforeImport ?? stillProject) != (savedStillSequence.map(CutProject.stillSequence) ?? .sequence(savedSequence)) ||
            undoStack.map(\.id) != savedUndoIDs || redoStack.map(\.id) != savedRedoIDs
    }

    private func updateStatus() {
        let changed = hasUnsavedDocumentChanges
        if isProjectChanged != changed { isProjectChanged = changed }
        lastExportedURL = nil
        if segments.isEmpty {
            statusMessage = isEmpty ? "Add local video, audio, or still images to start." : "\(stillProject.stillInserts.count) stills"
        } else {
            statusMessage = segments.count == 1 ? "1 clip" : "\(segments.count) clips"
        }
    }

    private func snapshot() -> EditSnapshot {
        var snapshot = edit
        snapshot.playhead = playhead
        return snapshot
    }

    private func restorePreview(at time: Double) {
        usesPointerPosition = false
        preview.pause()
        playhead = min(max(0, time), duration)
        preview.update(segments.map(monitoredPreview), at: playhead, project: stillProject,
                       reference: segments.first(where: { $0.source.media.hasVideo })?.source.media)
    }

    private func monitoredPreview(_ segment: EditorSegment) -> PreviewRange {
        var range = segment.preview
        range.readerRevision = refreshSourceRevisions[segment.source.id] ?? 0
        if let issue = mediaReviewIssue(segment) {
            range.isAudioOnly = true
            range.isSilentInsert = true
            range.unavailablePicture = issue
            range.usesMP3GaplessClock = false
            return range
        }
        if !useSavedMonitoringTracks || range.isAudioOnly || range.audioTrack != nil {
            range.audioTrack = monitoredAudioOrdinal(for: segment.source)
        }
        return range
    }

    private func sequenceDuration(_ segments: some Sequence<EditorSegment>) -> Double {
        if let exact = try? segments.reduce(RationalTime.zero, { try $0.adding($1.duration) }) {
            return exact.seconds
        }
        return segments.reduce(0.0) { $0 + $1.duration.seconds }
    }

    private func locatedSegment(at time: Double) -> (Int, EditorSegment, RationalTime)? {
        guard time >= 0, time < duration else { return nil }
        let index = edit.offsets.lowerBound { $0.seconds > time } - 1
        guard index >= 0, time < edit.offsets[index].seconds + segments[index].duration.seconds else { return nil }
        return (index, segments[index], edit.offsets[index])
    }

    private func markBoundary(at time: Double, pointer: Bool? = nil) -> RationalTime? {
        if let (insert, start) = stillInsert(at: time) {
            let step = max(0, ((time - start.seconds) / insert.cadence.seconds).rounded())
            guard step < Double(Int64.max), let elapsed = try? insert.cadence.multiplied(by: RationalTime(numerator: Int64(step))) else { return nil }
            return try? start.adding(min(insert.duration, elapsed))
        }
        guard let (_, segment, offset) = locatedSegment(at: time) else { return edit.duration }
        if time == offset.seconds { return offset }
        let target = time - offset.seconds + segment.start.seconds
        let boundary: RationalTime
        switch (pointer ?? usesPointerPosition) ? .off : effectiveSnapTarget {
        case .off:
            boundary = editBoundary(in: segment.source, to: target) ?? segment.start
        case .keyframes:
            let keys = segment.source.keyframes
            let points = (0..<(keys.count + 1)).lazy.map { $0 == keys.count ? segment.source.duration : keys[$0] }
            guard let point = nearest(in: points, to: target, after: segment.start, before: segment.end,
                                      includingLimits: true) else {
                alert = EditorNotice(title: "Can’t Set Mark", message: "There is no keyframe within this clip’s kept range.")
                return nil
            }
            boundary = point
        case .scenes, .silence:
            guard let point = analysisBoundary(in: segment, to: target, after: segment.start,
                                               before: segment.end, includingLimits: true) else {
                showAnalysisBoundaryError(segment, title: "Can’t Set Mark")
                return nil
            }
            boundary = point
        }
        do {
            return try offset.adding(min(max(boundary, segment.start), segment.end).subtracting(segment.start))
        } catch {
            alert = EditorNotice(title: "Can’t Set Mark", message: error.localizedDescription)
            return nil
        }
    }

    private func showAnalysisBoundaryError(_ clip: EditorSegment, title: String) {
        let message: String
        if snapTarget == .scenes {
            message = sceneReport(for: clip) == nil ? "Finish Find Scenes to snap to scene boundaries." :
                "There is no scene boundary inside this range."
        } else if !activeAudioSources.contains(clip.source.id) {
            message = "This clip has no audio on the selected track."
        } else {
            message = sourcePauses[clip.source.id] == nil ? "Finish Scan for Silence to snap to pause edges." :
                "There is no detected pause edge inside this range."
        }
        alert = EditorNotice(title: title, message: message)
    }

    /// Binary-search the ordered report directly, including during handle drags on long recordings.
    private func analysisBoundary(in clip: EditorSegment, to target: Double, after minimum: RationalTime? = nil,
                                  before maximum: RationalTime? = nil, includingLimits: Bool = false) -> RationalTime? {
        let source = clip.source
        if snapTarget == .scenes {
            if let report = sceneRangeReports[ClipSceneRange(clip)] {
                let boundaries = report.scenes.dropFirst(report.syntheticLeading ? 1 : 0).lazy.map(\.start)
                return nearest(in: boundaries, to: target, after: minimum, before: maximum, includingLimits: includingLimits)
            }
            guard let report = sceneReports[source.id] else { return nil }
            let boundaries = (0..<(report.scenes.count + 1)).lazy.map { index in
                index == report.scenes.count ? source.duration : report.scenes[index].start
            }
            return nearest(in: boundaries, to: target, after: minimum, before: maximum, includingLimits: includingLimits)
        }
        guard let pauses = sourcePauses[source.id] else { return nil }
        let boundaries = (0..<(2 * pauses.count)).lazy.map { index in
            let pause = pauses[index / 2]
            let edge = index.isMultiple(of: 2) ? pause.from : pause.to
            return self.editBoundary(in: source, to: edge.seconds) ?? .zero
        }
        return nearest(in: boundaries, to: target, after: minimum, before: maximum, includingLimits: includingLimits)
    }

    private func editBoundary(in source: IndexedSource, to target: Double, after minimum: RationalTime? = nil,
                              before maximum: RationalTime? = nil) -> RationalTime? {
        if source.media.hasVideo {
            return nearest(in: source.frameBoundaries, to: target, after: minimum, before: maximum)
        }
        var cut = source.media.audioEditBoundary(near: target)
        if let minimum, cut <= minimum { cut = source.media.steppingAudioBoundary(from: minimum.seconds, direction: 1) }
        if let maximum, cut >= maximum { cut = source.media.steppingAudioBoundary(from: maximum.seconds, direction: -1) }
        guard minimum.map({ cut > $0 }) ?? true, maximum.map({ cut < $0 }) ?? true else { return nil }
        return cut
    }

    private func nearest<T: RandomAccessCollection>(in times: T, to target: Double, after minimum: RationalTime? = nil,
                                                    before maximum: RationalTime? = nil, includingLimits: Bool = false) -> RationalTime?
        where T.Index == Int, T.Element == RationalTime {
        Self.nearestBoundaries(in: times, to: target, after: minimum, before: maximum, includingLimits: includingLimits).first { _ in true }
    }

    private nonisolated static func nearestBoundaries<T: RandomAccessCollection>(in times: T, to target: Double, after minimum: RationalTime?,
                                                              before maximum: RationalTime?, includingLimits: Bool = false) -> AnySequence<RationalTime>
        where T.Index == Int, T.Element == RationalTime {
        let start = minimum.map { min in times.lowerBound { includingLimits ? $0 >= min : $0 > min } } ?? times.startIndex
        let end = maximum.map { max in times.lowerBound { includingLimits ? $0 > max : $0 >= max } } ?? times.endIndex
        let partition = min(max(times.lowerBound { $0.seconds >= target }, start), end)
        let tolerance = max(target.ulp * 4, Double.ulpOfOne)
        return AnySequence {
            var previous = partition - 1
            var next = partition
            return AnyIterator<RationalTime> {
                if previous >= start,
                   next >= end || abs(target - times[previous].seconds) <= abs(target - times[next].seconds) + tolerance {
                    defer { previous -= 1 }
                    return times[previous]
                }
                guard next < end else { return nil }
                defer { next += 1 }
                return times[next]
            }
        }
    }

    private func precedingFrame(in segment: EditorSegment, before time: RationalTime) -> RationalTime {
        if !segment.source.media.hasVideo {
            return max(segment.start, segment.source.media.steppingAudioBoundary(from: time.seconds, direction: -1))
        }
        let frames = segment.source.frames
        let index = frames.lowerBound { $0 >= time } - 1
        return index >= 0 ? frames[index] : segment.start
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (Bool) -> Void) {
        // Preflight can finish after the editor has lost keyboard focus, and About or Settings may be main.
        ProjectPanels.present(panel, in: sheetWindow, completion: completion)
    }
}

extension RandomAccessCollection where Index == Int {
    func lowerBound(where predicate: (Element) -> Bool) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(self[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

struct TimelinePause {
    struct Source: Hashable {
        let occurrence: UUID
        let track: Int
    }

    struct Key {
        let source: Source
        let span: AudioSpan
    }
    let key: Key
    let sequence: AudioSpan
    let removal: AudioSpan?
    let isProtected: Bool
}

struct CutPreview: Identifiable {
    let id: UUID
    let position: RationalTime
    let pauseKey: TimelinePause.Key
    let ranges: [PreviewRange]
}

extension EditorModel {
    private func monitoredAudioOrdinal(for source: IndexedSource) -> Int? {
        switch audioMonitoring {
        case .followSource: return source.audioOrdinal(preferred: source.replacementTrack ?? 0)
        case .track(let ordinal): return source.audioOrdinal(preferred: ordinal)
        }
    }

    private func syncWaveforms(invalidatingPauses: Bool = false) {
        sceneScan.pruneCheckpoints(keeping: Array(analysisSourceMedia.values))
        updateMediaWatcher()
        var sources: [UUID: MediaInfo] = [:]
        var ordinals: [UUID: Int] = [:]
        for clip in segments where clip.source.isIndexed && mediaReviewIssue(clip) == nil && sources[clip.source.id] == nil {
            let source = clip.source
            sources[source.id] = source.media
            ordinals[source.id] = monitoredAudioOrdinal(for: source)
        }
        let changed = Set(ordinals.keys.filter { ordinals[$0] != sourceAnalysisTracks[$0] })
        sourceAnalysisTracks = ordinals
        for id in changed { automaticThresholds[id] = nil }
        if snapTarget == .silence { snapScanRequests.subtract(changed) }
        silenceMedia = sources.filter { ordinals[$0.key] != nil }
        let nextSources = Set(silenceMedia.keys)
        if nextSources != activeAudioSources { invalidateMCPSilenceReceipt() }
        activeAudioSources = nextSources
        let opening = segments.first.flatMap { clip -> (UUID, MediaInfo, Int)? in
            guard !clip.source.isIndexed, clip.source.media.hasVideo,
                  let ordinal = monitoredAudioOrdinal(for: clip.source) else { return nil }
            return (clip.source.id, clip.source.media, ordinal)
        }
        audioStore.update(sources: silenceMedia, track: 0, sourceTracks: ordinals, useSidecar: useAnalysisSidecars,
                          excludedSources: sidecarExclusions, opening: opening)
        refreshDetectedPauses(invalidating: invalidatingPauses ? nextSources : changed)
    }

    private var playheadAudioSource: IndexedSource? {
        locatedSegment(at: playhead)?.1.source ?? segments.last?.source
    }

    var playheadAnalysisTrack: Int { playheadAudioSource.flatMap(monitoredAudioOrdinal) ?? 0 }

    var analysisPlayheadSourceID: UUID? { playheadAudioSource?.id }

    func hasAnalysisTrack(_ track: Int, in source: UUID) -> Bool {
        guard let media = analysisSourceMedia[source], media.hasFullEditIndex else { return false }
        return media.streams.filter { $0.kind == "audio" }.indices.contains(track)
    }

    func analysisThreshold(for source: UUID, track: Int) -> Double? {
        thresholdOverrides[AudioTrackKey(source: source, track: track)]
    }

    var pauseSourceLabel: String? { activeAudioSources.count > 1 ? playheadAudioSource?.name : nil }

    var manualThresholdDB: Double? {
        get {
            guard let id = playheadAudioSource?.id else { return nil }
            return analysisThreshold(for: id, track: sourceAnalysisTracks[id] ?? analysisTrack)
        }
        set {
            guard let id = playheadAudioSource?.id else { return }
            setAnalysisThreshold(newValue, for: id)
        }
    }

    func setAnalysisThreshold(_ threshold: Double?, for id: UUID) {
        guard analysisThreshold(for: id, track: sourceAnalysisTracks[id] ?? analysisTrack) != threshold else { return }
        setThresholdOverride(threshold, source: id)
        refreshDetectedPauses(invalidating: [id])
    }

    var effectiveThresholdDB: Double? {
        manualThresholdDB ?? playheadAudioSource.flatMap { automaticThresholds[$0.id] }
    }

    private func setThresholdOverride(_ threshold: Double?, source id: UUID) {
        guard let media = silenceMedia[id] else { return }
        let audio = media.streams.filter { $0.kind == "audio" }
        guard let analysisTrack = sourceAnalysisTracks[id], audio.indices.contains(analysisTrack) else { return }
        thresholdOverrides[AudioTrackKey(source: id, track: analysisTrack)] = threshold
        let stream = audio[analysisTrack].index
        persistMetadata(threshold, key: stream, section: "thresholdOverrides.v1", media: media, seed: [:],
                        source: id, edits: EditorMetadataEdits(thresholds: [stream: threshold]))
    }

    func completedSilences(for id: UUID) -> [SilenceAnalysisResult] {
        silenceResults[id].map { Array($0.values) } ?? []
    }

    func scanForSilence() {
        guard canScanSilence else { return }
        let stale = refreshStaleSilence.intersection(activeAudioSources)
        audioStore.allowOverviews(activeAudioSources)
        if !stale.isEmpty {
            pendingSilenceRescans.formUnion(stale)
        } else if hasSilenceResults {
            // Keep the previous complete report until the rescan succeeds.
            pendingSilenceRescans = activeAudioSources
        }
        silenceScanRequested = true
        mcpSilenceReceipt?.cancelledDetail = { [weak self] in
            guard let self else { return [:] }
            return ["sources": self.activeAudioSources.subtracting(self.pendingSilenceSources).map(\.uuidString).sorted()]
        }
        silenceIssues.removeAll()
        audioStore.retryFailures()
        syncWaveforms()
    }

    func cancelSilenceScan() {
        invalidateMCPSilenceReceipt()
        if snapTarget == .silence { snapScanRequests.formUnion(activeAudioSources) }
        silenceScanRequested = false
        pendingSilenceRescans.removeAll()
        for task in pauseDetections.values { task.cancel() }
        pauseDetections.removeAll()
        skipPauses = false
        // The waveform has its own consumers and continues to fill the filmstrip.
        refreshDetectedPauses()
    }

    private func invalidateMCPSilenceReceipt() {
        guard let receipt = mcpSilenceReceipt else { return }
        receipt.finish("cancelled")
        mcpSilenceReceipt = nil
        silenceScanRequested = false
        pendingSilenceRescans.removeAll()
        for id in mcpSilenceWorkers { pauseDetections.removeValue(forKey: id)?.cancel() }
        mcpSilenceWorkers.removeAll()
    }

    private func refreshDetectedPauses(invalidating changed: Set<UUID> = []) {
        if !changed.isEmpty { invalidateMCPSilenceReceipt() }
        // Once a saved report is visible its controls work just like a fresh scan.
        if !changed.isDisjoint(with: sourcePauses.keys) { silenceScanRequested = true }
        automaticThresholds = automaticThresholds.filter { activeAudioSources.contains($0.key) }
        pendingSilenceRescans.formIntersection(activeAudioSources)
        checkedSilenceSidecars.formIntersection(activeAudioSources.subtracting(changed))
        silenceIssues = silenceIssues.filter { activeAudioSources.contains($0.key) && !changed.contains($0.key) }
        sourcePauses = sourcePauses.filter { !changed.contains($0.key) && activeAudioSources.contains($0.key) }
        for id in Array(pauseDetections.keys) where changed.contains(id) || !activeAudioSources.contains(id) {
            pauseDetections.removeValue(forKey: id)?.cancel()
            mcpSilenceWorkers.remove(id)
        }
        let pending = pendingSilenceSources
        for (id, media) in silenceMedia where pending.contains(id) && pauseDetections[id] == nil && silenceIssues[id] == nil && (!refreshStaleSilence.contains(id) || pendingSilenceRescans.contains(id)) {
            guard let analysisTrack = sourceAnalysisTracks[id] else { continue }
            let stream = media.streams.filter { $0.kind == "audio" }[analysisTrack].index
            let manual = thresholdOverrides[AudioTrackKey(source: id, track: analysisTrack)]
            let profile = SilenceProfile(stream: stream, threshold: manual, minimum: minimumPause)
            let rescan = pendingSilenceRescans.contains(id)
            if !rescan, let result = silenceResults[id]?[profile] {
                automaticThresholds[id] = result.automaticThresholdDB
                sourcePauses[id] = result.pauses
                continue
            }
            let persist = sidecarPreference.permits(media.url)
            let readSaved = !rescan && persist && checkedSilenceSidecars.insert(id).inserted
            let wave = audioStore.finished.contains(id) ? audioStore.waves[id] : nil
            let calibrated = automaticThresholds[id]
            let requested = silenceScanRequested
            guard readSaved || (wave != nil && (requested || calibrated == nil)) else { continue }
            // This job restores saved results even before the waveform has arrived.
            // Fresh detection shares the waveform decoder and runs only on request.
            let worker = Task.detached(priority: .utility) { () throws -> (Double?, SilenceAnalysisResult?) in
                var level = calibrated
                if readSaved {
                    let sidecar = AnalysisSidecar(media: media)
                    if let result = sidecar.silence(for: media, stream: stream, thresholdDB: manual, minimum: profile.minimum) {
                        return (result.automaticThresholdDB, result)
                    }
                    if level == nil { level = sidecar.automaticThresholdDB(for: media, stream: stream) }
                }
                try Task.checkCancellation()
                guard let wave else { return (level, nil) }
                if requested {
                    let result = try AudioAnalysis.silence(media, stream: stream, thresholdDB: manual, minimum: profile.minimum,
                                                           waveform: wave, automaticThresholdDB: level, useSidecar: false,
                                                           cancelled: { Task.isCancelled })
                    if persist {
                        AnalysisSidecar(media: media).saveAutomatically(try AnalysisSidecar.sections(media: media, silence: [result],
                                                                                                      cancelled: { Task.isCancelled }),
                                                                      cancelled: { Task.isCancelled })
                    }
                    return (result.automaticThresholdDB, result)
                }
                return (try level ?? wave.automaticThresholdDB(checkingCancellation: Task.checkCancellation), nil)
            }
            let endWork = mcpSilenceReceipt?.cleanup.begin()
            if endWork != nil { mcpSilenceWorkers.insert(id) }
            pauseDetections[id] = Task {
                defer { endWork?() }
                do {
                    let (level, result) = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                                onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }
                    automaticThresholds[id] = level
                    if let result {
                        refreshStaleSilence.remove(id)
                        silenceResults[id, default: [:]][profile] = result
                        sourcePauses[id] = result.pauses
                        pendingSilenceRescans.remove(id)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    silenceIssues[id] = error.localizedDescription
                }
                pauseDetections[id] = nil
                mcpSilenceWorkers.remove(id)
                refreshDetectedPauses()
            }
        }
        if let issue = silenceIssue, let receipt = mcpSilenceReceipt {
            receipt.finish("failed", detail: ["error": issue])
            mcpSilenceReceipt = nil
            silenceScanRequested = false
            pendingSilenceRescans.removeAll()
            for task in pauseDetections.values { task.cancel() }
            pauseDetections.removeAll()
            mcpSilenceWorkers.removeAll()
        } else if silenceScanRequested && pendingSilenceSources.isEmpty {
            silenceScanRequested = false
            mcpSilenceReceipt?.finish("succeeded", detail: ["sources": activeAudioSources.map(\.uuidString).sorted()])
            mcpSilenceReceipt = nil
        }
        rebuildPausePlan()
    }

    var hasPauseMarks: Bool { edit.markIn != nil && edit.markOut != nil }

    private var pauseScope: AudioSpan {
        if let a = edit.markIn, let b = edit.markOut { return AudioSpan(from: min(a,b), to: max(a,b)) }
        return AudioSpan(from: .zero, to: edit.duration)
    }

    private func rebuildPausePlan() {
        let scope = pauseScope
        var plan: [TimelinePause] = []
        var count = 0, seconds = 0.0
        var index = max(0, edit.offsets.lowerBound { $0 > scope.from } - 1)
        // Include earlier pieces of this continuous occurrence when the scope starts after a split.
        while index > 0, segments[index - 1].occurrence == segments[index].occurrence,
              segments[index - 1].end == segments[index].start,
              (try? edit.offsets[index - 1].adding(segments[index - 1].duration)) == edit.offsets[index] {
            index -= 1
        }
        while !sourcePauses.isEmpty, index < segments.count, edit.offsets[index] < scope.to {
            var clip = segments[index]
            let offset = edit.offsets[index]
            index += 1
            // A straight split leaves the source audio continuous. Measure and
            // pad its pauses once, even if they cross several timeline pieces.
            while index < segments.count, segments[index].occurrence == clip.occurrence,
                  segments[index].start == clip.end,
                  (try? offset.adding(clip.duration)) == edit.offsets[index] {
                clip.end = segments[index].end
                index += 1
            }
            guard let end = try? offset.adding(clip.duration) else { continue }
            guard let lower = try? clip.start.adding(max(scope.from, offset).subtracting(offset)),
                  let upper = try? clip.end.subtracting(end.subtracting(min(scope.to, end))) else { continue }
            guard lower < upper, clip.source.isIndexed, let pauses = sourcePauses[clip.source.id] else { continue }
            let bounds = effectiveSnapTarget == .keyframes ? copyBoundaries(for: clip.source) : nil
            let fullClip = AudioSpan(from: clip.start, to: clip.end)
            var local: [(key: TimelinePause.Key, span: AudioSpan, cut: AudioSpan?, keep: Bool)] = []
            let source = TimelinePause.Source(occurrence: clip.occurrence, track: sourceAnalysisTracks[clip.source.id] ?? analysisTrack)
            let protected = protectedPauses[source] ?? []
            let first = pauses.lowerBound { $0.to > lower }
            for pause in pauses[first...] {
                if pause.from >= upper { break }
                let span = AudioSpan(from: max(lower, pause.from), to: min(upper, pause.to))
                let length = (try? span.to.subtracting(span.from))?.seconds ?? (span.to.seconds - span.from.seconds)
                guard length >= minimumPause else { continue }
                let key = TimelinePause.Key(source: source, span: pause)
                let match = protected.lowerBound { $0.to > pause.from }
                let keep = match < protected.count && protected[match].from < pause.to
                let isExterior = leavePause == 0 && (span.from == clip.start || span.to == clip.end)
                var cut: AudioSpan?
                if !keep && !(effectiveSnapTarget == .keyframes && isExterior) {
                    if !clip.source.media.hasVideo {
                        cut = AudioAnalysis.audioRemoval(in: span, leave: leavePause, media: clip.source.media, clip: fullClip)
                    } else {
                        let ends = effectiveSnapTarget == .keyframes ? bounds?.interiorEnds ?? [] : clip.source.frameBoundaries
                        let starts = effectiveSnapTarget == .keyframes ? bounds?.interiorStarts ?? [] : clip.source.frameBoundaries
                        cut = AudioAnalysis.removal(in: span, leave: leavePause, ends: ends, starts: starts, clip: fullClip)
                    }
                }
                local.append((key, span, cut, keep))
            }
            // A head or tail trim can copy one continuous audio range even
            // on streams whose decoder cannot restart at an interior join.
            if let bounds, leavePause == 0 {
                let onlyPiece = !local.contains { $0.cut != nil }
                for i in local.indices where !local[i].keep {
                    let span = local[i].span
                    guard span.from == clip.start || span.to == clip.end else { continue }
                    let starts = bounds.starts(first: offset == .zero, last: onlyPiece && end == edit.duration)
                    let ends = bounds.ends(first: onlyPiece && offset == .zero, last: end == edit.duration)
                    local[i].cut = AudioAnalysis.removal(in: span, leave: 0, ends: ends, starts: starts, clip: fullClip)
                }
            }
            func sequence(_ range: AudioSpan) -> AudioSpan? {
                guard let from = try? offset.adding(range.from.subtracting(clip.start)),
                      let to = try? offset.adding(range.to.subtracting(clip.start)) else { return nil }
                return AudioSpan(from: from, to: to)
            }
            for pause in local {
                guard let visible = sequence(pause.span) else { continue }
                let removal = pause.cut.flatMap(sequence)
                if let cut = removal {
                    count += 1
                    seconds += cut.to.seconds - cut.from.seconds
                }
                plan.append(TimelinePause(key: pause.key, sequence: visible, removal: removal,
                                          isProtected: pause.keep))
            }
        }
        pausePlan = plan
        shortenedPauseCount = count
        removedPauseSeconds = seconds
        waveformRevision += 1
    }

    var currentPause: TimelinePause? {
        let i = pausePlan.lowerBound { $0.sequence.to.seconds > playhead }
        return i < pausePlan.count && pausePlan[i].sequence.from.seconds <= playhead + 1e-8 ? pausePlan[i] : nil
    }

    func stepPause(_ direction: Int) {
        guard pauseAnalysisReady, !pausePlan.isEmpty else { return }
        let i = direction > 0 ? pausePlan.lowerBound { $0.sequence.from.seconds > playhead + 1e-8 }
            : pausePlan.lowerBound { $0.sequence.from.seconds >= playhead - 1e-8 } - 1
        let index = (i + pausePlan.count) % pausePlan.count
        seek(pausePlan[index].sequence.from.seconds)
    }

    func protectCurrentPause() {
        guard canEdit, let currentPause else { return }
        setPauseProtection(!currentPause.isProtected, for: currentPause.key)
    }

    private func setPauseProtection(_ protect: Bool, for key: TimelinePause.Key) {
        var spans = protectedPauses[key.source] ?? []
        if !protect {
            // A new sensitivity setting can split a previously protected pause.
            // Restore shortening only for the occurrence currently under review.
            spans = spans.flatMap { prior -> [AudioSpan] in
                let overlap = AudioSpan(from: max(prior.from, key.span.from), to: min(prior.to, key.span.to))
                return overlap.from < overlap.to ? AudioAnalysis.retained(in: prior, removing: [overlap]) : [prior]
            }
        } else {
            spans.insert(key.span, at: spans.lowerBound { $0.from >= key.span.from })
        }
        protectedPauses[key.source] = spans.isEmpty ? nil : spans
        rebuildPausePlan()
    }

    var canUseRoomTone: Bool { roomTonePeaks() != nil }

    private func roomTonePeaks() -> [UUID: Float]? {
        guard pauseAnalysisReady, hasPauseMarks else { return nil }
        let scope = pauseScope
        guard scope.from < scope.to else { return nil }
        var peaks: [UUID: Float] = [:]
        for (index, clip) in segments.enumerated() {
            let offset = edit.offsets[index]
            guard let next = try? offset.adding(clip.duration) else { return nil }
            let from = max(scope.from, offset)
            let to = min(scope.to, next)
            guard from < to else { continue }
            guard audioStore.finished.contains(clip.source.id),
                  let value = audioStore.waves[clip.source.id]?.peak(
                      from: clip.start.seconds + (from.seconds - offset.seconds),
                      to: clip.start.seconds + (to.seconds - offset.seconds)) else { return nil }
            peaks[clip.source.id] = max(peaks[clip.source.id] ?? 0, value)
        }
        return peaks.isEmpty ? nil : peaks
    }

    @discardableResult
    func useRoomTone() -> Bool {
        guard let peaks = roomTonePeaks() else { return false }
        for (id, peak) in peaks {
            setThresholdOverride(AudioAnalysis.roomToneThresholdDB(forPeak: peak), source: id)
        }
        refreshDetectedPauses(invalidating: Set(peaks.keys))
        clearMarks()
        return true
    }

    private func skipPauseIfNeeded(at position: Double) {
        guard let cut = pauseRemoval(at: position) else { return }
        // The publisher fires before the new playhead value is installed.
        Task { @MainActor in
            guard skipPauses, preview.playbackRate > 0, pauseRemoval(at: preview.time) == cut else { return }
            preview.seek(to: cut.to.seconds)
        }
    }

    private func pauseRemoval(at position: Double) -> AudioSpan? {
        guard hasSilenceResults else { return nil }
        let i = pausePlan.lowerBound { $0.sequence.to.seconds > position }
        guard i < pausePlan.count, let cut = pausePlan[i].removal,
              position >= cut.from.seconds, position < cut.to.seconds else { return nil }
        return cut
    }

    private func pieces(in span: AudioSpan) -> [EditorSegment] {
        guard span.from < span.to else { return [] }
        let first = max(0, edit.offsets.lowerBound { $0 > span.from } - 1)
        var result: [EditorSegment] = []
        for index in first..<segments.count {
            let clip = segments[index], offset = edit.offsets[index]
            if offset >= span.to { break }
            guard let next = try? offset.adding(clip.duration) else { return [] }
            guard let start = try? clip.start.adding(max(span.from, offset).subtracting(offset)),
                  let end = try? clip.end.subtracting(next.subtracting(min(span.to, next))) else { return [] }
            if start < end {
                result.append(start == clip.start && end == clip.end ? clip : EditorSegment(source: clip.source, start: start, end: end,
                    displayRange: AudioSpan(from: start, to: end), occurrence: clip.occurrence))
            }
        }
        return result
    }

    var canPreviewCurrentCut: Bool {
        currentPause?.removal != nil && duration - removedPauseSeconds > 1e-9
    }

    func previewCurrentCut() {
        guard canEdit, canPreviewCurrentCut, let pause = currentPause else { return }
        preview.pause()
        showCutPreview(pause, id: UUID())
    }

    func advanceCutPreview(keepingCurrent: Bool) {
        guard let review = cutPreview else { return }
        if keepingCurrent { setPauseProtection(true, for: review.pauseKey) }
        let next = pausePlan.first { $0.removal != nil && $0.sequence.from > review.position }
            ?? pausePlan.first { $0.removal != nil && $0.sequence.from < review.position }
        guard let next else { cutPreview = nil; return }
        preview.seek(to: next.sequence.from.seconds)
        showCutPreview(next, id: review.id)
    }

    private func showCutPreview(_ pause: TimelinePause, id: UUID) {
        guard let cut = pause.removal else { return }
        let all = AudioSpan(from: .zero, to: edit.duration)
        let kept = AudioAnalysis.retained(in: all, removing: pausePlan.compactMap(\.removal))
        let after = kept.lowerBound { $0.from >= cut.to }
        let second = RationalTime(numerator: 1)
        var beforeRanges: [AudioSpan] = [], afterRanges: [AudioSpan] = []
        var remaining = second
        for span in kept[..<after].reversed() {
            guard let start = try? span.to.subtracting(remaining) else { cutPreview = nil; return }
            let from = max(span.from, start)
            beforeRanges.append(AudioSpan(from: from, to: span.to))
            guard let left = try? remaining.subtracting(span.to.subtracting(from)) else { cutPreview = nil; return }
            remaining = left
            if remaining == .zero { break }
        }
        remaining = second
        for span in kept[after...] {
            guard let end = try? span.from.adding(remaining) else { cutPreview = nil; return }
            let to = min(span.to, end)
            afterRanges.append(AudioSpan(from: span.from, to: to))
            guard let left = try? remaining.subtracting(to.subtracting(span.from)) else { cutPreview = nil; return }
            remaining = left
            if remaining == .zero { break }
        }
        let ranges = (beforeRanges.reversed() + afterRanges).flatMap(pieces).map(monitoredPreview)
        cutPreview = ranges.isEmpty ? nil : CutPreview(id: id, position: pause.sequence.from, pauseKey: pause.key, ranges: ranges)
    }

    @discardableResult
    func applyPauses(queueTakes: Bool) -> Bool {
        guard pauseAnalysisReady else { return false }
        let cuts = pausePlan.compactMap(\.removal)
        guard !cuts.isEmpty else { return false }
        let scope = queueTakes ? pauseScope : AudioSpan(from: .zero, to: edit.duration)
        let ranges = AudioAnalysis.retained(in: scope, removing: cuts)
        guard !ranges.isEmpty else {
            alert = EditorNotice(title: "No media to keep", message: "Increase the time left in each pause or keep a pause.")
            return false
        }
        let clips = ranges.map(pieces)
        guard edit.stillSequence != nil || clips.allSatisfy({ !$0.isEmpty }) else {
            alert = EditorNotice(title: "Can’t Shorten These Pauses", message: "A retained range exceeds the exact timeline clock.")
            return false
        }
        if queueTakes {
            do {
                let takes = try zip(ranges, clips).map { range, clips in
                    var media = Dictionary(clips.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
                    var project: CutProject?
                    var placements: ExportPlacementScope = .none
                    if edit.stillSequence != nil {
                        let snapshot = try stillProjectForRange(range)
                        placements = try snapshot.exportPlacementScope()
                        if placements != .none {
                            project = snapshot
                            if let reference = snapshot.stillAudioReference,
                               let source = segments.first(where: { $0.documentID == reference.id })?.source {
                                media[source.url] = source.media
                            }
                        }
                    }
                    return QueuedRange(start: range.from, end: range.to, clips: clips.map(\.request), media: media,
                                       stillProject: project, placements: placements)
                }
                queuedRanges.append(contentsOf: takes)
                statusMessage = "Added \(takes.count) takes to the export queue."
                return true
            } catch {
                alert = EditorNotice(title: "Can’t Queue Takes", message: error.localizedDescription)
                return false
            }
        }
        var retainedOccurrences: Set<String> = []
        let originals = Dictionary(grouping: segments, by: \.occurrence)
        let proposed = clips.flatMap { $0 }.map { piece -> EditorSegment in
            guard edit.stillSequence != nil,
                  let original = originals[piece.occurrence]?.first(where: { $0.start <= piece.start && piece.end <= $0.end }),
                  retainedOccurrences.insert(original.documentID).inserted else { return piece }
            var retained = original
            retained.start = piece.start
            retained.end = piece.end
            return retained
        }
        if effectiveSnapTarget == .keyframes, let issue = copyIssue(proposed) {
            alert = EditorNotice(title: "Cannot Copy These Joins", message: issue.message)
            return false
        }
        let removedBefore = cuts.reduce(0.0) { $0 + max(0, min(playhead, $1.to.seconds) - $1.from.seconds) }
        return validate(proposed, selecting: proposed.first?.id, at: playhead - removedBefore, action: "Shorten Pauses")
    }
}

extension EditorModel {
    /// Capture the very same occurrence pieces and indexed sources as the native export sheet.
    func mcpExportInput(selection: Bool) throws -> (clips: [ClipRequest], media: [URL: MediaInfo]) {
        guard canEdit, !mcpHasActiveTrim else { throw MCPCommandError("busy", "Finish the pending edit or import first.") }
        let items: [EditorSegment]
        if selection {
            guard let selectedSpan else { throw MCPCommandError("no_selection", "Select a timeline range first.") }
            items = pieces(in: selectedSpan)
        } else { items = segments }
        guard !items.isEmpty else { throw MCPCommandError("empty_edit", "Add media before exporting.") }
        if let issue = items.compactMap(mediaReviewIssue).first { throw MCPCommandError("source_needs_review", issue) }
        return (items.map(\.request), Dictionary(items.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { a, _ in a }))
    }

    var mcpOutputProtectedMedia: [String: String] { protectedMedia }

    func mcpApplyReplacement(_ plan: AudioReplacementPlan, output: URL, sourceID: UUID,
                             validateCommit: @escaping @MainActor () throws -> Void) async throws -> Int {
        var result: Result<Int, MCPCommandError>?
        guard let token = applyReplacement(plan, output: output, useSidecar: useAnalysisSidecars, sourceID: sourceID,
                                           validateCommit: validateCommit, completed: { result = $0 }),
              let job = exportTasks[session] else {
            throw MCPCommandError("unavailable", alert?.message ?? "Replacement could not start.")
        }
        await withTaskCancellationHandler {
            await job.value
        } onCancel: { token.cancel() }
        guard let result else { throw MCPCommandError("replacement_failed", "Replacement did not return an outcome.") }
        return try result.get()
    }

    func mcpReplacementSource(_ clipID: UUID) throws -> (UUID, MediaInfo) {
        guard let source = segments.first(where: { $0.id == clipID })?.source else {
            throw MCPCommandError("invalid_target", "Choose an existing clip occurrence.")
        }
        return (source.id, source.media)
    }
}

extension EditorModel {
    private struct InlineStill {
        var insert: StillInsert
        var start: RationalTime
        var end: RationalTime
    }

    private func inlineStills(in project: CutProject) -> [InlineStill] {
        guard case .stillSequence(let sequence) = project else { return [] }
        var cursor = RationalTime.zero
        var result: [InlineStill] = []
        for item in sequence.items {
            switch item {
            case .source(let clip):
                guard let next = try? cursor.adding(clip.to.subtracting(clip.from)) else { return [] }
                cursor = next
            case .still(let insert):
                guard let end = try? cursor.adding(insert.duration) else { return [] }
                result.append(InlineStill(insert: insert, start: cursor, end: end))
                cursor = end
            }
        }
        return result
    }

    private func stillInsert(at time: Double) -> (StillInsert, RationalTime)? {
        inlineStills(in: stillProject).first { time >= $0.start.seconds && time < $0.end.seconds }
            .map { ($0.insert, $0.start) }
    }

    private func stepStill(_ direction: Int) -> Bool {
        let tolerance = max(playhead.ulp * 4, 1e-9)
        for card in inlineStills(in: stillProject) {
            if direction > 0, playhead >= card.start.seconds - tolerance, playhead < card.end.seconds - tolerance {
                let index = floor((playhead - card.start.seconds + tolerance) / card.insert.cadence.seconds) + 1
                let next = min(card.end.seconds, card.start.seconds + index * card.insert.cadence.seconds)
                if next < duration { seek(next) }
                return true
            }
            if direction < 0, playhead > card.start.seconds + tolerance, playhead <= card.end.seconds + tolerance {
                let index = max(0, ceil((playhead - card.start.seconds - tolerance) / card.insert.cadence.seconds) - 1)
                seek(card.start.seconds + index * card.insert.cadence.seconds)
                return true
            }
        }
        return false
    }

    var stillCadence: RationalTime? {
        if let cadence = stillProject.stillFormat?.cadence { return cadence }
        guard let reference = segments.first(where: { $0.source.media.hasVideo })?.source.media,
              let rate = reference.videoStream?.frameRate, rate > .zero else { return nil }
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        // A nominal rate also exists on variable-rate material. Require equal
        // presentation intervals before choosing a cadence without asking.
        let frames = reference.frames
        guard frames.count > 1,
              zip(frames, frames.dropFirst()).allSatisfy({ (try? $1.time.subtracting($0.time)) == cadence }) else { return nil }
        return cadence
    }

    func stillBoundary(at time: Double) throws -> RationalTime {
        guard time.isFinite, time >= 0, time <= duration, let boundary = markBoundary(at: time) else {
            throw CutError(code: "invalid_still_time", message: "Choose a presentation boundary within the sequence.")
        }
        return boundary
    }

    private func installStillPresentation(_ project: CutProject, updatesPreview: Bool = true) {
        guard case .stillSequence(let sequence) = project else {
            edit.stillSequence = nil
            return
        }
        edit.stillSequence = sequence
        var clips: [TimelineClip] = []
        var offsets: [RationalTime] = []
        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0) })
        let assets = Dictionary(uniqueKeysWithValues: sequence.stillAssets.map { ($0.id, $0) })
        var cursor = RationalTime.zero
        for item in sequence.items {
            switch item {
            case .source(let clip):
                guard let source = segmentsByID[clip.id], let end = try? cursor.adding(source.duration) else { continue }
                offsets.append(cursor)
                clips.append(source.timeline(sequenceRange: cursor.seconds..<end.seconds))
                cursor = end
            case .still(let card):
                guard let end = try? cursor.adding(card.duration) else { continue }
                let id = stillTimelineIDs[card.id] ?? UUID()
                stillTimelineIDs[card.id] = id
                let asset = assets[card.assetID]
                var thumbnailRevision = Hasher()
                thumbnailRevision.combine(asset)
                thumbnailRevision.combine(card.framing)
                thumbnailRevision.combine(sequence.stillFormat)
                thumbnailRevision.combine(stillReviewCanvas?.videoStream?.displayWidth)
                thumbnailRevision.combine(stillReviewCanvas?.videoStream?.displayHeight)
                let name = asset?.displayName ?? "Still"
                clips.append(TimelineClip(id: id, sourceID: id, name: name, sourceStart: 0, sourceEnd: card.duration.seconds,
                                          sourceDuration: card.duration.seconds, keyframes: [], thumbnailSyncTimes: [],
                                          frames: [], sequenceRange: cursor.seconds..<end.seconds, isStill: true,
                                          mediaRevision: thumbnailRevision.finalize()))
                cursor = end
            }
        }
        edit.offsets = offsets
        edit.duration = cursor
        edit.timelineClips = clips
        if let id = edit.selectedID, !clips.contains(where: { $0.id == id }) {
            edit.selectedID = clips.first?.id
        }
        if let mark = edit.markIn, mark > cursor { edit.markIn = cursor }
        if let mark = edit.markOut, mark > cursor { edit.markOut = cursor }
        if updatesPreview {
            restorePreview(at: playhead)
            refreshTier()
        }
    }

    private func reconciledStillProject(_ proposed: [EditorSegment]) -> CutProject? {
        guard case .stillSequence(var sequence) = stillProject else { return nil }
        let newClips = sequenceClips(for: proposed)
        if !newClips.isEmpty, sequence.stillFormat != nil {
            sequence.stillFormat = nil
            sequence.programColorPolicy = nil
        }
        let proposedIDs = Set(newClips.map(\.id))
        let originals = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0) })
        let newPieces = Dictionary(grouping: proposed.filter { originals[$0.documentID] == nil }, by: \.occurrence)
        var runningCards: [StillInsert] = []
        var beforeSource: [String: [StillInsert]] = [:]
        for item in sequence.items {
            switch item {
            case .still(let card): runningCards.append(card)
            case .source(let source) where proposedIDs.contains(source.id):
                beforeSource[source.id] = runningCards
                runningCards.removeAll()
            default: break
            }
        }
        sequence.items = newClips.flatMap { clip in
            (beforeSource[clip.id] ?? []).map(StillSequenceItem.still) + [.source(clip)]
        } + runningCards.map(StillSequenceItem.still)
        sequence.stillReplacements = sequence.stillReplacements.compactMap { replacement in
            var replacement = replacement
            guard case .sequence(let fragments) = replacement.coverage else { return nil }
            let surviving = fragments.flatMap { fragment -> [StillReplacementFragment] in
                guard let original = originals[fragment.clipID] else { return [] }
                let right = (newPieces[original.occurrence] ?? []).filter {
                    $0.start > original.start && $0.start < original.end
                }.sorted { $0.start < $1.start }
                if right.isEmpty { return proposedIDs.contains(fragment.clipID) ? [fragment] : [] }
                var lower = fragment.range.from
                var result: [StillReplacementFragment] = []
                var id = fragment.clipID
                for piece in right {
                    let upper = min(fragment.range.to, piece.start)
                    if upper > lower, proposedIDs.contains(id) {
                        result.append(StillReplacementFragment(clipID: id, range: MulticamRange(from: lower, to: upper)))
                    }
                    lower = max(lower, piece.start)
                    id = piece.documentID
                }
                if fragment.range.to > lower {
                    result.append(StillReplacementFragment(clipID: id, range: MulticamRange(from: lower, to: fragment.range.to)))
                }
                return result
            }
            guard !surviving.isEmpty else { return nil }
            replacement.coverage = .sequence(surviving)
            return replacement
        }
        return .stillSequence(sequence)
    }

    func applyStillProjectByHand(_ candidate: CutProject, action: String) throws {
        let baseline = stillProject
        guard preferences.warnBeforeLoweringExportTier, !isEmpty, candidate != baseline,
              try candidate.exportPlacementScope() != .none, sheetWindow != nil || tierPrompt != nil else {
            try applyStillProject(candidate, action: action)
            return
        }
        try candidate.validate()
        let input = Self.tierInput(segments)
        let previously = tierIsCurrent ? tierState : nil
        let evaluator = tierEvaluator, preferred = preferredCopyContainer, useSidecar = useAnalysisSidecars
        let originalSession = session, originalRevision = mcpRevision
        let token = EditCancellation()
        let excluded = sidecarExclusions
        cancellation = token
        isCheckingEdit = true
        Task {
            let prompt = await Task.detached(priority: .userInitiated) {
                AnalysisSidecar.$excludedSources.withValue(excluded) {
                    let planner = StillExportPlanner(useSidecar: useSidecar, cancelled: { token.isCancelled })
                    let oldState = previously ?? (((try? baseline.exportPlacementScope()) ?? .none) != .none
                        ? planner.tier(baseline, preferredContainer: preferred)
                        : evaluator.evaluate(input.clips, media: input.media, cancelled: { token.isCancelled }))
                    guard let old = oldState.tier else { return nil as TierPrompt? }
                    let newState = planner.tier(candidate, preferredContainer: preferred)
                    if case .checking = newState { return nil }
                    if let tier = newState.tier, tier >= old { return nil }
                    return TierPrompt(action: action, from: old, to: newState, factors: newState.factors,
                                      nearest: nil, soundOnly: false)
                }
            }.value
            guard session == originalSession else { return }
            if cancellation === token { cancellation = nil; isCheckingEdit = false }
            guard !token.isCancelled, originalRevision == mcpRevision else { resumePendingWork(); return }
            let commit = { [self] in
                guard session == originalSession, mcpRevision == originalRevision else { return }
                do { try applyStillProject(candidate, action: action) }
                catch { showStillError(error) }
            }
            guard let prompt else { commit(); resumePendingWork(); return }
            isPresentingPanel = true
            let answer = { [self] (choice: TierPrompt.Choice) in
                guard session == originalSession else { return }
                isPresentingPanel = false
                if choice.dontAskAgain { preferences.warnBeforeLoweringExportTier = false }
                if case .proceed = choice.answer { commit() }
                resumePendingWork()
            }
            if let tierPrompt { tierPrompt(prompt, answer) } else { TierPrompt.present(prompt, in: sheetWindow, answer: answer) }
        }
    }

    func applyStillProject(_ candidate: CutProject, action: String) throws {
        guard !isBusy, alert == nil else {
            throw CutError(code: "editor_busy", message: "The editor is busy.")
        }
        guard let clips = candidate.sequenceClips, candidate.stillAudioReference == nil else {
            throw CutError(code: "invalid_still_target", message: "The sequence editor requires an editable sequence project.")
        }
        let project: CutProject
        if candidate.programColorPolicy == nil, !candidate.stillAssets.isEmpty,
           let stream = segments.first(where: { $0.source.media.hasVideo })?.source.media.videoStream,
           let color = try? StillProgramColorPolicy.resolving(source: stream) {
            project = try candidate.settingStillColorPolicy(color)
        } else {
            project = candidate
        }
        try project.validate()
        guard project != stillProject else { return }
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0) })
        let proposed = try clips.map { clip -> EditorSegment in
            if var segment = byID[clip.id], segment.source.url.path == clip.file, clip.to <= segment.source.duration {
                segment.start = clip.from
                segment.end = clip.to
                return segment
            }
            guard let original = segments.first(where: { $0.source.url.path == clip.file && $0.start <= clip.from && $0.end >= clip.to }) else {
                throw CutError(code: "invalid_still_target", message: "The edit refers to an unknown sequence occurrence.")
            }
            return EditorSegment(documentID: clip.id, source: original.source, start: clip.from, end: clip.to,
                                 displayRange: AudioSpan(from: clip.from, to: max(original.end, original.displayRange?.to ?? original.source.duration)),
                                 occurrence: original.occurrence)
        }
        cancelTrim()
        let prepared = PreparedEdit(segments: proposed, previous: edit.preparation, engine: CutEngine())
        guard apply(proposed, prepared: prepared, selecting: selectedID, at: playhead, action: action,
                    preserveMarks: true, sequenceProject: project) else {
            throw CutError(code: "invalid_still_edit", message: "The still edit could not be applied.")
        }
        refreshSidecarExclusions()
    }

    func stillProjectForSelection() throws -> CutProject {
        guard let selection = selectedSpan else { return stillProject }
        return try stillProjectForRange(selection)
    }

    private func stillProjectForRange(_ selection: AudioSpan) throws -> CutProject {
        guard case .stillSequence(var sequence) = stillProject else { return stillProject }
        var cursor = RationalTime.zero
        sequence.items = try sequence.items.compactMap { item in
            let length: RationalTime
            switch item {
            case .source(let clip): length = try clip.to.subtracting(clip.from)
            case .still(let insert): length = insert.duration
            }
            let end = try cursor.adding(length)
            let lower = max(cursor, selection.from)
            let upper = min(end, selection.to)
            defer { cursor = end }
            guard lower < upper else { return nil }
            switch item {
            case .source(var clip):
                clip.to = try clip.from.adding(upper.subtracting(cursor))
                clip.from = try clip.from.adding(lower.subtracting(cursor))
                return .source(clip)
            case .still(var insert):
                insert.duration = try upper.subtracting(lower)
                return .still(insert)
            }
        }
        let ids = Set(sequence.items.compactMap { if case .source(let clip) = $0 { return clip.id }; return nil })
        sequence.stillReplacements = sequence.stillReplacements.compactMap { replacement in
            var replacement = replacement
            guard case .sequence(let fragments) = replacement.coverage else { return nil }
            let retained = fragments.filter { ids.contains($0.clipID) }
            guard !retained.isEmpty else { return nil }
            replacement.coverage = .sequence(retained)
            return replacement
        }
        if ids.isEmpty, sequence.stillFormat == nil, let insert = sequence.items.first?.still,
           let video = stillReviewCanvas?.videoStream {
            let policy = try sequence.programColorPolicy ?? StillProgramColorPolicy.resolving(source: video)
            let hdr = ["smpte2084", "arib-std-b67"].contains(policy.transfer)
            let codec = ReencodeCodec(rawValue: video.codec) ?? (hdr ? .hevc : .h264)
            if let container = StillTimelineFormat.containers(for: codec).first {
                let width = max(2, video.displayWidth > 0 ? video.displayWidth : video.width)
                let height = max(2, video.displayHeight > 0 ? video.displayHeight : video.height)
                sequence.stillFormat = StillTimelineFormat(width: width + (width % 2), height: height + (height % 2),
                                                            cadence: insert.cadence, codec: codec, container: container)
                sequence.programColorPolicy = policy
            }
            if sequence.stillFormat != nil {
                let references = zip(zip(sequenceClips, segments), edit.offsets).compactMap { entry, offset
                    -> (clip: CutSequenceClip, offset: RationalTime)? in
                    let (clip, segment) = entry
                    guard segment.source.media.streams.contains(where: { $0.kind == "audio" }) else { return nil }
                    return (clip, offset)
                }
                sequence.stillAudioReference = (references.last { $0.offset <= selection.from } ?? references.first)?.clip
            }
        }
        let result = CutProject.stillSequence(sequence)
        try result.validate()
        return result
    }
}

extension EditorModel {
    var canReplacePicture: Bool { canEdit && selectedSpan != nil && segments.contains { $0.source.media.hasVideo } }
    var canInsertStill: Bool { !isBusy && alert == nil && (isEmpty || hasPicture) }

    var stillAssetSpans: [MulticamAssetSpan] {
        let project = stillProject
        guard !project.stillAssets.isEmpty, let plan = try? project.resolveStills() else { return [] }
        let names = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0.displayName) })
        let assetIDs = Dictionary(uniqueKeysWithValues:
            project.stillReplacements.map { ($0.id, $0.assetID) } + project.stillInserts.map { ($0.id, $0.assetID) })
        return plan.spans.enumerated().compactMap { index, span in
            guard let id = span.placementID, let asset = assetIDs[id] else { return nil }
            return MulticamAssetSpan(id: "\(id)-\(index)", title: names[asset] ?? asset, interval: span.output)
        }
    }

    var stillPlacementRows: [StillPlacementRow] {
        guard !stillProject.stillInserts.isEmpty || !stillProject.stillReplacements.isEmpty else { return [] }
        let assets = Dictionary(uniqueKeysWithValues: stillProject.stillAssets.map { ($0.id, $0) })
        func name(_ id: String) -> String {
            guard let asset = assets[id] else { return "Missing image" }
            return FileManager.default.fileExists(atPath: asset.file) ? asset.displayName : "\(asset.displayName) (offline)"
        }
        func framing(_ frame: StillImageFraming) -> String { frame.mode == .fit ? "Fit" : "Fill" }
        var result = inlineStills(in: stillProject).map { card in
            StillPlacementRow(id: card.insert.id, title: "Insert · \(name(card.insert.assetID))",
                              details: "Sequence \(card.start)–\(card.end) s · \(card.insert.duration) s · \(framing(card.insert.framing))",
                              isInsert: true)
        }
        let namesByClip = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0.source.name) })
        let visible = Dictionary(grouping: (try? stillProject.resolveStills().spans) ?? []) { $0.placementID }
        result += stillProject.stillReplacements.map { replacement in
            var ranges: [String] = []
            var fragmentCount = 0
            if case .sequence(let fragments) = replacement.coverage {
                fragmentCount = fragments.count
                let byClip = Dictionary(grouping: visible[replacement.id] ?? []) { span -> String? in
                    if case .source(let id, _) = span.origin { return id }
                    return nil
                }
                for fragment in fragments {
                    let name = namesByClip[fragment.clipID] ?? fragment.clipID
                    let authored = "Source \(fragment.range.from)–\(fragment.range.to) s"
                    let span = byClip[fragment.clipID]?.first { span in
                        guard case .source(_, let range) = span.origin else { return false }
                        return fragment.range.from <= range.from && range.to <= fragment.range.to
                    }
                    let timing = span.map { "Sequence \($0.output.from)–\($0.output.to) s" } ?? "Hidden (0 s)"
                    ranges.append("\(name) · \(authored) · \(timing)")
                }
            }
            return StillPlacementRow(id: replacement.id, title: "Replace · \(name(replacement.assetID))",
                                     details: (ranges + [framing(replacement.framing)]).joined(separator: " · "), isInsert: false,
                                     fragmentCount: fragmentCount)
        }
        return result
    }

    func chooseReplacePicture() {
        guard canReplacePicture, let range = selectedSpan else { return }
        if let card = inlineStills(in: stillProject).first(where: { $0.start < range.to && range.from < $0.end }) {
            showStillError(CutError(code: "invalid_still_target", message: "The marked range contains insert \(card.insert.id). Edit that still directly."))
            return
        }
        chooseStillImage { [weak self] url in self?.replacePicture(with: url, in: range) }
    }

    func chooseInsertStill() {
        guard canInsertStill else { return }
        chooseStillImage { [weak self] url in
            guard let self else { return }
            self.addDroppedStills([url], at: self.playhead)
        }
    }

    private func chooseStillImage(_ completion: @escaping (URL) -> Void) {
        guard !isBusy else { return }
        isPresentingPanel = true
        // Clear the busy flag on cancellation as well as selection.
        StillPanels.chooseImage(in: editorWindow, dismissed: { [weak self] in
            self?.isPresentingPanel = false
            DispatchQueue.main.async { self?.resumePendingWork() }
        }, completion: completion)
    }

    private func showStillError(_ error: Error) {
        alert = EditorNotice(title: "Couldn’t Edit Still Images", message: error.localizedDescription)
    }

    private func editStill(action: String, _ mutation: () throws -> CutProject) {
        do { try applyStillProjectByHand(mutation(), action: action) }
        catch { showStillError(error) }
    }

    private func inspectImages(_ urls: [URL], completion: @escaping ([StillAsset]) throws -> Void) {
        let generation = mcpGeneration
        let revision = mcpRevision
        let existing = stillProject.stillAssets
        isCheckingEdit = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    var known = existing
                    return try urls.map { url in
                        let asset = try StillPanels.asset(for: url, existing: known)
                        if !known.contains(where: { $0.id == asset.id }) { known.append(asset) }
                        return asset
                    }
                }
            }.value
            guard mcpGeneration == generation else { return }
            isCheckingEdit = false
            guard mcpRevision == revision else {
                showStillError(CutError(code: "stale_revision", message: "The timeline changed while reading the images."))
                return
            }
            do { try completion(result.get()) }
            catch { showStillError(error) }
            resumePendingWork()
        }
    }

    private func replacePicture(with url: URL, in range: AudioSpan) {
        inspectImages([url]) { assets in
            let asset = assets[0]
            let project = try self.project(with: asset).replacingPicture(
                id: UUID().uuidString, assetID: asset.id, from: range.from, to: range.to
            )
            try self.applyStillProjectByHand(project, action: "Replace Picture")
        }
    }

    private func project(with asset: StillAsset, in project: CutProject? = nil) throws -> CutProject {
        let base = project ?? stillProject
        return base.stillAssets.contains(where: { $0.id == asset.id }) ? base : try base.addingStillAsset(asset)
    }

    func addDroppedStills(_ urls: [URL], at time: Double, replacingMarkedRange: Bool = false) {
        if replacingMarkedRange {
            guard urls.count == 1, let url = urls.first, canReplacePicture, let selection = selectedSpan else {
                showStillError(CutError(code: "invalid_still_target", message: "Mark a picture range and drop one image to replace it."))
                return
            }
            replacePicture(with: url, in: selection)
            return
        }
        guard !urls.isEmpty, !isBusy else { return }
        guard canInsertStill else {
            showStillError(CutError(code: "missing_still_format", message: "Open a video sequence or start a new still-only sequence."))
            return
        }
        do {
            let at = try stillBoundary(at: time)
            if isEmpty, stillProject.stillFormat == nil {
                let revision = mcpRevision
                StillPanels.format(in: editorWindow) { [weak self] format, colorPolicy in
                    guard let self, self.mcpRevision == revision else { return }
                    self.chooseStillDuration(urls, at: at, cadence: format.cadence, format: format, colorPolicy: colorPolicy)
                }
            } else {
                chooseStillDuration(urls, at: at, cadence: stillCadence)
            }
        } catch { showStillError(error) }
    }

    private func chooseStillDuration(_ urls: [URL], at time: RationalTime, cadence: RationalTime?,
                                     format: StillTimelineFormat? = nil, colorPolicy: StillProgramColorPolicy? = nil) {
        let fallback = RationalTime(numerator: 1, denominator: 30)
        let interval = cadence ?? fallback
        let frames = Int64(max(1, min(1_000, (2 / interval.seconds).rounded())))
        let initial = (try? interval.multiplied(by: RationalTime(numerator: frames))) ?? RationalTime(numerator: 2)
        let revision = mcpRevision
        StillPanels.duration(title: "Insert Still", duration: initial, cadence: interval, in: editorWindow) { [weak self] duration, interval in
            guard let self, self.mcpRevision == revision, self.canInsertStill else { return }
            if let cadence, interval != cadence {
                self.showStillError(CutError(code: "invalid_still_cadence", message: "Use the sequence’s frame rate (\(RationalTime(numerator: cadence.denominator, denominator: cadence.numerator)) fps)."))
                return
            }
            self.inspectImages(urls) { assets in
                var project = self.stillProject
                var cursor = time
                for (index, asset) in assets.enumerated() {
                    let id = UUID().uuidString
                    if let format, index == 0 {
                        project = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: id,
                                                                  duration: duration, colorPolicy: colorPolicy ?? StillTimelineFormat.sdrColorPolicy)
                    } else {
                        let card = StillInsert(id: id, assetID: asset.id, duration: duration, cadence: interval)
                        project = try self.project(with: asset, in: project).insertingStill(card, at: cursor)
                    }
                    cursor = try cursor.adding(duration)
                }
                try self.applyStillProjectByHand(project, action: assets.count == 1 ? "Insert Still" : "Insert Stills")
            }
        }
    }

    func validateStillReplacementExtents(_ candidate: CutProject, original: StillReplacement) throws {
        let mediaByClip = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0.source.media) })
        let priorFragments: Set<StillReplacementFragment>
        if case .sequence(let fragments) = original.coverage { priorFragments = Set(fragments) }
        else { priorFragments = [] }
        let previousIDs = Set(stillProject.stillReplacements.map(\.id))
        for placement in candidate.stillReplacements
        where placement.id == original.id || !previousIDs.contains(placement.id) {
            guard case .sequence(let fragments) = placement.coverage else { continue }
            for fragment in fragments where !priorFragments.contains(fragment) {
                guard let media = mediaByClip[fragment.clipID] else { continue }
                guard fragment.range.to <= media.duration else {
                    throw CutError(code: "invalid_still_time", message: "The replacement extends beyond the source media.")
                }
            }
        }
    }

    func manageStill(_ row: StillPlacementRow, action: StillPlacementAction) {
        guard !isBusy else { return }
        let card = inlineStills(in: stillProject).first { $0.insert.id == row.id }
        let replacement = stillProject.stillReplacements.first { $0.id == row.id }
        guard let assetID = card?.insert.assetID ?? replacement?.assetID,
              let framing = card?.insert.framing ?? replacement?.framing else { return }
        let revision = mcpRevision
        if let replacement, [.move, .resize, .duplicate, .detach].contains(action) {
            StillPanels.editReplacement(replacement, action: action, in: editorWindow,
                                        plan: try? stillProject.resolveStills()) { [weak self] request in
                guard let self, self.mcpRevision == revision else { return }
                self.editStill(action: request.title) {
                    let candidate = try request.apply(to: self.stillProject) { time, clock, fragment in
                        if clock == "sequence" { return try self.stillBoundary(at: time.seconds) }
                        guard let fragment,
                              let clip = self.segments.first(where: { $0.documentID == fragment.clipID }),
                              time >= .zero, time <= clip.source.media.duration,
                              time != clip.source.media.duration else { return time }
                        let target = time.seconds
                        let snapped: RationalTime?
                        switch self.effectiveSnapTarget {
                        case .off: snapped = self.editBoundary(in: clip.source, to: target)
                        case .keyframes: snapped = self.nearest(in: clip.source.keyframes, to: target)
                        case .scenes, .silence: snapped = self.analysisBoundary(in: clip, to: target)
                        }
                        return snapped ?? self.editBoundary(in: clip.source, to: target) ?? time
                    }
                    try self.validateStillReplacementExtents(candidate, original: replacement)
                    return candidate
                }
            }
            return
        }
        switch action {
        case .frame:
            StillPanels.frame(title: "Still Framing", framing: framing, in: editorWindow) { [weak self] framing in
                guard let self, self.mcpRevision == revision else { return }
                self.editStill(action: "Change Still Framing") {
                    try self.stillProject.updatingStill(id: row.id, assetID: assetID, framing: framing)
                }
            }
        case .move:
            guard let card else { return }
            StillPanels.text(title: "Move Still", label: "Sequence Time (seconds)", value: card.start.description,
                             in: editorWindow) { [weak self] text in
                guard let self, self.mcpRevision == revision else { return }
                self.editStill(action: "Move Still") {
                    let time = try self.stillBoundary(at: RationalTime(parsing: text).seconds)
                    return try self.stillProject.movingStill(id: row.id, to: time)
                }
            }
        case .resize:
            guard let card else { return }
            StillPanels.duration(title: "Change Still Duration", duration: card.insert.duration, cadence: card.insert.cadence,
                                 in: editorWindow) { [weak self] duration, cadence in
                guard let self, self.mcpRevision == revision else { return }
                self.editStill(action: "Change Still Duration") {
                    try self.stillProject.resizingStill(id: row.id, duration: duration, cadence: cadence)
                }
            }
        case .duplicate:
            guard let card else { return }
            var copy = card.insert
            copy.id = UUID().uuidString
            editStill(action: "Duplicate Still") { try stillProject.insertingStill(copy, at: card.end) }
        case .detach: return
        case .remove:
            editStill(action: "Delete Still") { try stillProject.removingStill(id: row.id) }
        case .relink:
            chooseStillImage { [weak self] url in
                self?.inspectImages([url]) { [weak self] assets in
                    guard let self else { return }
                    let image = assets[0]
                    let project = try self.stillProject.relinkingStillAsset(assetID, file: image.file, fingerprint: image.fingerprint)
                    try self.applyStillProjectByHand(project, action: "Relink Image")
                }
            }
        }
    }

    func moveTimelineItem(_ id: UUID, to slot: Int) {
        guard case .stillSequence(var sequence) = stillProject,
              let from = timelineClips.firstIndex(where: { $0.id == id }) else {
            move(id, to: slot)
            return
        }
        let destination = min(max(0, slot), sequence.items.count)
        guard from != destination, from + 1 != destination else { return }
        if case .still(let card) = sequence.items[from] {
            editStill(action: "Move Still") {
                let time = try self.timelineSlotTime(destination)
                return try self.stillProject.movingStill(id: card.id, to: time)
            }
        } else {
            let item = sequence.items.remove(at: from)
            sequence.items.insert(item, at: destination > from ? destination - 1 : destination)
            editStill(action: "Move Clip") { .stillSequence(sequence) }
        }
    }

    private func timelineSlotTime(_ slot: Int) throws -> RationalTime {
        try (stillProject.sequenceItems ?? []).prefix(slot).reduce(.zero) { time, item in
            switch item {
            case .source(let source): return try time.adding(source.to.subtracting(source.from))
            case .still(let card): return try time.adding(card.duration)
            }
        }
    }

    func dropOnTimeline(_ urls: [URL], slot: Int) {
        let sourceSlot = (stillProject.sequenceItems ?? []).prefix(slot).compactMap(\.source).count
        importFiles(urls, at: sourceSlot)
    }
}

extension EditorModel {
    var canRefreshProjectMedia: Bool {
        guard !isBusy, !isSavingSidecars, !mcpHasActiveTrim, alert == nil else { return false }
        return !segments.isEmpty || queuedRanges.contains { !$0.media.isEmpty }
            || undoStack.contains { !$0.clips.isEmpty } || redoStack.contains { !$0.clips.isEmpty }
    }

    func refreshProjectMedia(deep: Bool = false, receipt: MCPAnalysisReceipt? = nil) {
        _ = refreshProjectMedia(deep: deep, verify: [], receipt: receipt)
    }

    private func updateMediaWatcher() {
        guard preferences.automaticallyRefreshMedia else {
            mediaWatcher?.stop()
            mediaWatcher = nil
            return
        }
        if mediaWatcher == nil {
            mediaWatcher = ProjectMediaWatcher { [weak self] verify in
                self?.refreshProjectMedia(deep: false, verify: verify, receipt: nil) ?? false
            }
        }
        mediaWatcher?.update(Set(segments.map { $0.source.url }))
    }

    private func refreshProjectMedia(deep: Bool, verify: Set<URL>, receipt: MCPAnalysisReceipt?) -> Bool {
        guard canRefreshProjectMedia else {
            receipt?.finish("failed", detail: ["error": "Finish the current project operation before refreshing media."])
            return false
        }
        let history = undoStack + redoStack
        var inputs = [URL: ProjectMediaRefreshInput]()
        func add(_ url: URL, media: MediaInfo? = nil) {
            let url = url.standardizedFileURL
            inputs[url] = ProjectMediaRefreshInput(url: url, previous: inputs[url]?.previous ?? media ?? refreshBaselines[url])
        }
        for clip in segments {
            add(clip.source.url, media: clip.source.media)
            if clip.source.originalURL != clip.source.url { add(clip.source.originalURL) }
        }
        for state in history {
            if case .live(let snapshot) = state.contents {
                for media in snapshot.preparation.sourceMedia.values { add(media.url, media: media) }
            }
            for clip in state.clips {
                add(URL(fileURLWithPath: clip.file))
                if let original = clip.originalFile { add(URL(fileURLWithPath: original)) }
            }
        }
        for queued in queuedRanges {
            for media in queued.media.values { add(media.url, media: media) }
        }
        guard !inputs.isEmpty else {
            receipt?.finish("failed", detail: ["error": "No recordings are referenced by this project."])
            return false
        }
        mediaRefreshProgress = 0
        statusMessage = "Refreshing project media…"
        let previewSources = Set(segments.lazy.filter { $0.source.media.hasVideo }.map { $0.source.url.standardizedFileURL })
        mediaRefresh.start(inputs: Array(inputs.values), deep: deep, verify: verify.union(offlineMedia), persist: useAnalysisSidecars,
                           exclusions: sidecarExclusions, receipt: receipt, previewSources: previewSources,
                           preview: { [weak self] media, aliases in
            self?.previewRefreshedFilmstrip(media, aliases: aliases)
        }, progress: { [weak self] in
            self?.mediaRefreshProgress = $0
        }, publish: { [weak self] result, aliases, _ in
            self?.installMediaRefresh(result, aliases: aliases)
        }, finished: { [weak self] message in
            guard let self else { return }
            if !self.refreshFilmstrips.isEmpty { self.refreshFilmstrips.removeAll() }
            self.mediaRefreshProgress = nil
            self.statusMessage = message
            self.resumePendingWork()
        })
        return true
    }

    func queuedMediaRefreshIssue() -> CutError? {
        guard queuedRanges.contains(where: { invalidatedQueueIDs.contains($0.id) }) else { return nil }
        return CutError(code: "source_changed", message: "Remove and re-add affected queued ranges to export the refreshed media.")
    }

    private func mediaReviewIssue(_ clip: EditorSegment) -> String? {
        let source = clip.source
        if offlineMedia.contains(source.url) { return "\(source.name) — recording is offline." }
        guard let revision = refreshSourceRevisions[source.id], revision > 0 else { return nil }
        if clip.end > source.duration || clip.start < .zero {
            return "\(source.name) — a saved trim extends past the refreshed recording."
        }
        if incompatibleMedia.contains(source.url) { return "\(source.name) — the recording type changed." }
        if refreshReviewPicture.contains(source.url) {
            return "\(source.name) — the picture track could not be verified."
        }
        let audio = source.media.streams.filter { $0.kind == "audio" }
        let explicitSelection = audioMonitoringTrack ?? source.replacementTrack
        let review = refreshReviewStreams[source.url] ?? []
        let selected = explicitSelection ?? (source.media.hasVideo && audio.isEmpty && review.isEmpty ? nil : 0)
        if let selected {
            guard audio.indices.contains(selected), !review.contains(audio[selected].index) else {
                return "\(source.name) — the selected audio track changed or is missing."
            }
            if (explicitSelection != nil || !source.media.hasVideo),
               let track = source.media.audio.first(where: { $0.stream.index == audio[selected].index }),
               clip.start < track.start || clip.end > track.end {
                return "\(source.name) — a saved trim extends past the refreshed audio track."
            }
        }
        return nil
    }

    private func previewRefreshedFilmstrip(_ media: MediaInfo, aliases: Set<URL>) {
        guard media.timelineIssue == nil, let replacement = media.videoStream else { return }
        var drafts = refreshFilmstrips
        for source in edit.preparation.sourceMedia where aliases.contains(source.value.url.standardizedFileURL) {
            let id = source.key
            let before = source.value
            let clips = edit.timelineClips.filter { $0.sourceID == id }
            guard !clips.isEmpty, let picture = before.videoStream,
                  media.origin == before.origin, media.identity.isCurrentSnapshot(at: before.url),
                  replacement.index == picture.index, replacement.trackID == picture.trackID,
                  replacement.displayWidth == picture.displayWidth, replacement.displayHeight == picture.displayHeight,
                  clips.allSatisfy({ $0.mediaIssue == nil && max($0.sourceDuration, $0.displayRange?.to.seconds ?? 0) <= media.duration.seconds }) else {
                continue
            }
            nextRefreshDisplayRevision += 1
            drafts[id] = RefreshFilmstrip(media: media.forRefreshAlias(before.url), displayRevision: nextRefreshDisplayRevision)
        }
        if drafts.count > refreshFilmstrips.count { refreshFilmstrips = drafts }
    }

    private func installMediaRefresh(_ result: MediaRefreshResult, aliases: Set<URL>) {
        let url = result.source.standardizedFileURL
        func matches(_ candidate: URL) -> Bool { aliases.contains(candidate.standardizedFileURL) }
        let history = (undoStack + redoStack).flatMap { state -> [EditorSegment] in
            if case .live(let snapshot) = state.contents { return snapshot.segments }
            return []
        }
        let sources = (segments + history).map(\.source).filter { matches($0.url) }
        let sourceIDs = Set(sources.map(\.id))
        let drafts = refreshFilmstrips.filter { sourceIDs.contains($0.key) }
        if !drafts.isEmpty { refreshFilmstrips = refreshFilmstrips.filter { !sourceIDs.contains($0.key) } }
        if let media = result.media {
            for alias in aliases {
                let item = media.forRefreshAlias(alias)
                refreshBaselines[alias] = item
                SourceIndexLoader.shared.acceptRefreshedIndex(item, sidecars: sidecarPreference.permits(alias))
            }
        }
        if result.state == .unchanged, sources.allSatisfy({ !offlineMedia.contains($0.url) }) { return }
        if result.state == .offline {
            offlineMedia.insert(url)
            for source in sources { offlineMedia.insert(source.url) }
        } else {
            offlineMedia.remove(url)
            for source in sources { offlineMedia.remove(source.url) }
        }
        for range in queuedRanges where range.media.keys.contains(where: matches) {
            invalidatedQueueIDs.insert(range.id)
        }
        let replacePicture = result.displayChanged || result.state == .offline
        for id in sourceIDs {
            refreshSourceRevisions[id, default: 0] += 1
            if replacePicture {
                if let draft = drafts[id], result.media?.identity.matchesSnapshot(draft.media.identity) == true {
                    refreshDisplayRevisions[id] = draft.displayRevision
                } else {
                    nextRefreshDisplayRevision += 1
                    refreshDisplayRevisions[id] = nextRefreshDisplayRevision
                }
                filmstripTiles.removeSource(id)
            }
            let rangeReports = sceneRangeReports.filter { $0.key.source == id }
            let hadPartialScenes = sourceSceneOverlays[id] != nil || sceneOverlays.keys.contains { $0.source == id }
            invalidateSceneScan(for: id)
            let source = sources.first { $0.id == id }
            if result.scenesPreserved, let source {
                let media = result.media?.forRefreshAlias(source.url) ?? source.media
                if let old = sceneReports[id] {
                    let report = old.forRefreshedMedia(media)
                    sceneReports[id] = report
                    refreshStaleScenes.remove(id)
                    scenesBySource[id] = report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) }
                    viewNamesBySource[id] = Dictionary(uniqueKeysWithValues: report.views.compactMap { view in
                        view.name.map { (view.view, $0) }
                    })
                }
                for (range, old) in rangeReports {
                    let report = old.forRefreshedMedia(media)
                    sceneRangeReports[range] = report
                    sceneOverlays[range] = Self.sceneOverlay(report, for: range)
                }
            } else {
                if let previous = sceneReports.removeValue(forKey: id) {
                    staleSceneReports[id] = previous
                    refreshStaleScenes.insert(id)
                }
                if hadPartialScenes || !rangeReports.isEmpty { refreshStaleScenes.insert(id) }
                staleSceneRangeReports.merge(rangeReports) { _, current in current }
                scenesBySource[id] = nil
                viewNamesBySource[id] = nil
            }
            let savedAudio = result.preservedAudioStreams
            if let previous = silenceResults[id], previous.keys.contains(where: { !savedAudio.contains($0.stream) }) {
                refreshStaleSilence.insert(id)
            }
            let preserved = silenceResults[id]?.filter { savedAudio.contains($0.key.stream) }
            if let media = result.media {
                silenceResults[id] = preserved?.mapValues { $0.forRefreshedMedia(media) }
            } else { silenceResults[id] = preserved }
            pauseDetections.removeValue(forKey: id)?.cancel()
            mcpSilenceWorkers.remove(id)
            if let source = sources.first(where: { $0.id == id }),
               let ordinal = sourceAnalysisTracks[id] {
                let oldAudio = source.media.streams.filter { $0.kind == "audio" }
                if oldAudio.indices.contains(ordinal), !savedAudio.contains(oldAudio[ordinal].index) {
                    automaticThresholds[id] = nil
                    sourcePauses[id] = nil
                    checkedSilenceSidecars.insert(id)
                    refreshStaleSilence.insert(id)
                }
            }
            if let source = sources.first(where: { $0.id == id }) {
                audioStore.refresh(id, media: result.media?.forRefreshAlias(source.url), preserving: result.preservedAudioStreams)
            }
        }
        var replacements: [UUID: IndexedSource] = [:]
        if let media = result.media {
            let newAudio = media.streams.filter { $0.kind == "audio" }
            let unique = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, source) in unique {
                refreshReviewStreams[source.url, default: []].formUnion(result.reviewStreams)
                if result.pictureNeedsReview { refreshReviewPicture.insert(source.url) }
                guard media.hasVideo == source.media.hasVideo else {
                    incompatibleMedia.insert(source.url)
                    continue
                }
                incompatibleMedia.remove(source.url)
                let oldAudio = source.media.streams.filter { $0.kind == "audio" }
                for ordinal in oldAudio.indices {
                    guard newAudio.indices.contains(ordinal), newAudio[ordinal].index != oldAudio[ordinal].index else { continue }
                    refreshReviewStreams[source.url, default: []].insert(newAudio[ordinal].index)
                }
                replacements[id] = IndexedSource(media: media.forRefreshAlias(source.url), id: id,
                                                 originalURL: source.originalURL, replacementNames: source.replacementNames,
                                                 replacementTrack: source.replacementTrack)
            }
        }
        func refresh(_ snapshot: EditSnapshot) -> EditSnapshot {
            guard !sourceIDs.isDisjoint(with: snapshot.preparation.sourceMedia.keys) else { return snapshot }
            var updated = snapshot
            for index in updated.segments.indices where sourceIDs.contains(updated.segments[index].source.id) {
                if let source = replacements[updated.segments[index].source.id] {
                    updated.segments[index].source = source
                }
                let segment = updated.segments[index]
                var clip = updated.timelineClips[index]
                if replacePicture { clip = segment.timeline(sequenceRange: clip.sequenceRange ?? 0..<0) }
                clip.mediaRevision = refreshDisplayRevisions[segment.source.id] ?? 0
                clip.mediaIssue = mediaReviewIssue(segment)
                updated.timelineClips[index] = clip
            }
            if replacePicture {
                updated.timelineThumbnailHeight = updated.timelineClips.lazy.map(\.thumbnailHeight).max() ?? TimelineClip.minimumThumbnailHeight
                updated.largeThumbnailHeight = updated.timelineClips.lazy.map { $0.thumbnailHeight(large: true) }.max() ?? TimelineClip.minimumLargeThumbnailHeight
            }
            if result.media != nil {
                updated.preparation = PreparedEdit(segments: updated.segments, previous: PreparedEdit(), engine: CutEngine())
            }
            return updated
        }
        guard !sourceIDs.isEmpty else { return }
        for id in sourceIDs { mediaRefreshWarnings[id] = result.persistenceError }
        undoStack = undoStack.map { state in
            var state = state
            if case .live(let snapshot) = state.contents { state.contents = .live(refresh(snapshot)) }
            return state
        }
        redoStack = redoStack.map { state in
            var state = state
            if case .live(let snapshot) = state.contents { state.contents = .live(refresh(snapshot)) }
            return state
        }
        guard !sourceIDs.isDisjoint(with: edit.preparation.sourceMedia.keys) else { return }
        let landing = playhead
        edit = refresh(edit)
        mediaClipReview = Dictionary(uniqueKeysWithValues: edit.timelineClips.compactMap { clip in
            clip.mediaIssue.map { (clip.id, $0) }
        })
        mcpRevision += 1
        sceneRevision += 1
        copyBoundaryIndices = copyBoundaryIndices.filter { !sourceIDs.contains($0.key) }
        trimChecks.removeAll()
        preview.invalidateMedia(alsoFilmstrip: replacePicture)
        syncWaveforms()
        restorePreview(at: landing)
        prepareCopyBoundaries()
        refreshTier()
    }
}
