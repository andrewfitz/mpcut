import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import MPCutCore

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
}

private struct UnresolvedSource: Sendable {
    let id: UUID
    let url: URL
    let originalURL: URL
    let replacementNames: [Int: String]
    let replacementTrack: Int?
    let status: ProjectMediaStatus
    let detail: String
    let snapshot: ProjectMediaSnapshot.Entry?

    var hasPicture: Bool? {
        guard let streams = snapshot?.streams, !streams.isEmpty else { return nil }
        return streams.contains { $0.kind == "video" }
    }

    var isAudioOnly: Bool {
        if let streams = snapshot?.streams {
            return streams.contains { $0.kind == "audio" } && !streams.contains { $0.kind == "video" }
        }
        return replacementTrack != nil
    }
}

private enum EditorSource: Sendable {
    case resolved(IndexedSource)
    case unresolved(UnresolvedSource)

    var indexed: IndexedSource? {
        if case .resolved(let source) = self { return source }
        return nil
    }
    var unresolved: UnresolvedSource? {
        if case .unresolved(let source) = self { return source }
        return nil
    }
    var media: MediaInfo? { indexed?.media }
    var id: UUID {
        switch self {
        case .resolved(let source): return source.id
        case .unresolved(let source): return source.id
        }
    }
    var url: URL {
        switch self {
        case .resolved(let source): return source.url
        case .unresolved(let source): return source.url
        }
    }
    var originalURL: URL {
        switch self {
        case .resolved(let source): return source.originalURL
        case .unresolved(let source): return source.originalURL
        }
    }
    var replacementTrack: Int? { indexed?.replacementTrack ?? unresolved?.replacementTrack }
    var replacementNames: [Int: String] { indexed?.replacementNames ?? unresolved?.replacementNames ?? [:] }
    var name: String { originalURL.lastPathComponent }
    var replacementLabel: String? {
        if replacementNames.count == 1 { return replacementNames.values.first }
        if replacementNames.isEmpty { return nil }
        return replacementNames.sorted { $0.key < $1.key }
            .map { "Track \($0.key + 1): \($0.value)" }.joined(separator: " · ")
    }
    var isAudioReplacement: Bool { replacementTrack != nil && url != originalURL }
    var isIndexed: Bool { indexed?.isIndexed == true }
    var frames: [RationalTime] { indexed?.frames ?? [] }
    var frameBoundaries: [RationalTime] { indexed?.frameBoundaries ?? [] }
    var keyframes: [RationalTime] { indexed?.keyframes ?? [] }
    var keyframeSeconds: [Double] { indexed?.keyframeSeconds ?? [] }
    var thumbnailSyncTimes: [Double] { indexed?.thumbnailSyncTimes ?? [] }

    func audioOrdinal(preferred: Int) -> Int? { indexed?.audioOrdinal(preferred: preferred) }
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
    var copiedReviewFrom: String?
    var source: EditorSource
    var start: RationalTime
    var end: RationalTime
    var displayRange: AudioSpan?
    var tileLayouts: [TileLayoutSpan]
    // Retained pieces share protection choices belonging to this occurrence of a source.
    let occurrence: UUID

    init(id: UUID = UUID(), documentID: String? = nil, source: IndexedSource, start: RationalTime = .zero, end: RationalTime? = nil,
         displayRange: AudioSpan? = nil, occurrence: UUID? = nil, tileLayouts: [TileLayoutSpan] = []) {
        self.init(id: id, documentID: documentID, source: .resolved(source), start: start, end: end ?? source.duration,
                  displayRange: displayRange, occurrence: occurrence, tileLayouts: tileLayouts)
    }

    init(id: UUID = UUID(), documentID: String? = nil, source: EditorSource, start: RationalTime, end: RationalTime,
         displayRange: AudioSpan? = nil, occurrence: UUID? = nil, tileLayouts: [TileLayoutSpan] = []) {
        self.id = id
        self.documentID = documentID ?? ProjectIdentifier.make(from: id)
        self.source = source
        self.start = start
        self.displayRange = displayRange
        self.occurrence = occurrence ?? id
        self.end = end
        self.tileLayouts = tileLayouts
    }

    func split(at boundary: RationalTime, rightID: UUID) -> (left: Self, right: Self) {
        var left = self
        left.end = boundary
        left.tileLayouts = tileLayouts.compactMap { $0.limited(from: nil, to: boundary) }
        left.displayRange = AudioSpan(from: min(start, displayRange?.from ?? .zero), to: boundary)
        let right = Self(id: rightID, source: source, start: boundary, end: end,
                         displayRange: AudioSpan(from: boundary, to: max(end, displayRange?.to ?? sourceExtent)),
                         occurrence: occurrence, tileLayouts: tileLayouts.compactMap { $0.limited(from: boundary, to: nil) })
        return (left, right)
    }

    var duration: RationalTime { end - start }
    var sourceExtent: RationalTime { source.indexed?.duration ?? max(end, source.unresolved?.snapshot?.duration ?? .zero) }
    func sequenceSeconds(at sourceTime: RationalTime, offset: RationalTime) -> Double {
        if let exact = try? offset.adding(sourceTime.subtracting(start)) { return exact.seconds }
        return offset.seconds + (sourceTime.seconds - start.seconds)
    }

    var preview: PreviewRange {
        guard let media = source.media else {
            return PreviewRange(url: source.url, exactStart: start, exactEnd: end, isAudioOnly: true, isSilentInsert: true)
        }
        var range = PreviewRange(media: media, from: start, to: end)
        range.audioTrack = source.replacementTrack
        return range
    }
    var request: ClipRequest { ClipRequest(file: source.url, from: start, to: end) }
    func timeline(sequenceRange: Range<Double>) -> TimelineClip {
        TimelineClip(id: id, sourceID: source.id, name: source.name, sourceStart: start.seconds, sourceEnd: end.seconds,
                     sourceDuration: sourceExtent.seconds, keyframes: source.keyframeSeconds,
                     thumbnailSyncTimes: source.thumbnailSyncTimes, frames: source.frames,
                     displaySize: CGSize(width: source.media?.videoStream?.displayWidth ?? 0, height: source.media?.videoStream?.displayHeight ?? 0),
                     sourceOrigin: source.media?.origin ?? source.unresolved?.snapshot?.origin ?? .zero,
                     sequenceRange: sequenceRange, isIndexed: source.isIndexed, displayRange: displayRange,
                     isAudioOnly: source.media.map { !$0.hasVideo } ?? (source.unresolved?.isAudioOnly == true),
                     audioSampleRate: source.media.flatMap { $0.hasVideo ? nil : $0.primaryStream.sampleRate } ?? 0,
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
    var unresolvedStatusByURL: [URL: ProjectMediaStatus] = [:]
    var unavailableSourceIDs: Set<UUID> = []
    var firstMedia: MediaInfo?
    var audioTracks: [StreamInfo] = []
    /// True when the movies differ in format, so no packet copy joins them and only Re-encode writes the timeline.
    var isMixed = false

    init() {}

    init(segments: [EditorSegment], previous: Self, engine: CutEngine, excluding unavailable: Set<UUID> = []) {
        unavailableSourceIDs = unavailable
        let indexed = segments.compactMap { $0.source.indexed }
        // Keep indexes for history and recovery. Timeline format and track choices use available recordings.
        sourceMedia = Dictionary(indexed.map { ($0.id, $0.media) }, uniquingKeysWith: { first, _ in first })
        unresolvedStatusByURL = Dictionary(segments.lazy.compactMap { segment in
            segment.source.unresolved.map { (ProjectMediaVolume.watchURL($0.url), $0.status) }
        }, uniquingKeysWith: { first, _ in first })
        let sources = unavailable.isEmpty ? indexed : indexed.filter { !unavailable.contains($0.id) }
        firstMedia = sources.first?.media
        let activeMedia = unavailable.isEmpty ? sourceMedia : sourceMedia.filter { !unavailable.contains($0.key) }
        if activeMedia.count > 1, let first = sources.first, first.media.hasVideo {
            // Measured against the first clip, as the import and the planners do. A replacement working copy changes
            // its sound by design, so it is held to the first clip's picture and track count only.
            var seen: Set<UUID> = [first.id]
            isMixed = sources.contains { source in
                guard seen.insert(source.id).inserted, source.media.hasVideo else { return false }
                if source.isAudioReplacement || first.isAudioReplacement {
                    return (try? engine.checkPictureCompatibility(source.media, with: first.media)) == nil
                        || source.media.audio.count != first.media.audio.count
                }
                return (try? engine.checkCompatibility(source.media, with: first.media)) == nil
            }
        }
        audioTracks = activeMedia.values.sorted { $0.url.path < $1.url.path }
            .map { $0.streams.filter { $0.kind == "audio" } }.max { $0.count < $1.count } ?? []
        requiresBackgroundCopyChecks = activeMedia.values.reduce(0) { $0 + $1.indexStorageBytes } >= PreparedEdit.backgroundCopyCheckBytes
        guard let first = sources.first, first.isIndexed else { return }
        firstSourceID = first.id
        container = first.id == previous.firstSourceID
            ? previous.container : engine.suggestedContainers(for: first.media).first
    }
}

private struct InlineStill {
    var insert: StillInsert
    var start: RationalTime
    var end: RationalTime
}

private struct EditSnapshot {
    // Value-semantic clip records share storage with every retained history snapshot.
    var documentClips: [CutSequenceClip] = []
    var analysisAnnotations = ProjectAnalysisAnnotations()
    var participants = ParticipantProject()
    var stillSequence: StillSequenceProject?
    var segments: [EditorSegment] = []
    var timelineClips: [TimelineClip] = []
    var inlineStillsByID: [UUID: InlineStill] = [:]
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
    private var document: URL?
    var projectURL: URL? {
        get { lock.withLock { document } }
        set { lock.withLock { document = newValue } }
    }

    func attachingDocument(to media: MediaInfo) -> MediaInfo {
        media.withSidecarDocument { [self] in projectURL }
    }

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
    var id = UUID()
    var contentID = UUID()
    let start: RationalTime
    let end: RationalTime
    let clips: [ClipRequest]
    let media: [URL: MediaInfo]
    var stillProject: CutProject? = nil
    var pictureProject: CutProject? = nil
    var pictureDocument: URL? = nil
    var placements: ExportPlacementScope = .none
    var pictureTiming: StillPictureTiming? = nil
    var excerpt: TranscriptQueueExcerpt? = nil
    var customName: String? = nil
    var name: String? { customName ?? excerpt?.name }
}

struct EditorNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var projectMediaRequest: ProjectMediaRequest?
    let projectMediaJobs = ProjectMediaJobs()
    private var projectMediaPicture: [(interval: MulticamRange, url: URL?)] = []
    let projectMediaSummaryPaths = ProjectMediaSummaryPaths()
    let preferences: EditorPreferences
    let preview: SequencePreview

    @Published private var edit = EditSnapshot() {
        didSet {
            guard !queuedRanges.isEmpty else { return }
            let layoutChanged = edit.documentClips != oldValue.documentClips
                && edit.documentClips.filter { !$0.tileLayouts.isEmpty } != oldValue.documentClips.filter { !$0.tileLayouts.isEmpty }
            if edit.participants != oldValue.participants || layoutChanged {
                invalidatedQueueIDs.formUnion(queuedRanges.map(\.id))
            }
        }
    }
    @Published private(set) var projectURL: URL? {
        didSet {
            sidecarPreference.projectURL = projectURL
            lastSidecarCandidates = []
            if let projectURL { preferences.recentFiles.record([projectURL]) }
        }
    }
    var sidecarWork: ProjectSidecarWork {
        ProjectSidecarWork(project: sidecarPreference.projectURL)
    }
    private var projectDiskRevision: ProjectDiskRevision?
    var feedAngleDiskRevision: ProjectDiskRevision? { projectDiskRevision }
    func invalidateFeedAngleDiskRevision() { projectDiskRevision = nil }
    func discardRedoBeforeFeedAngleConversion() { redoStack.removeAll() }
    func restoreAfterFeedAngleConversion(url: URL?, diskRevision: ProjectDiskRevision?, revision: Int,
                                         assets: [String: TranscriptAsset]) {
        if projectDiskRevision != diskRevision || projectURL != url {
            recoveredDraft = true
        }
        projectURL = url
        projectDiskRevision = diskRevision
        for index in transcriptState.attachments.indices {
            if let asset = assets[transcriptState.attachments[index].asset.sha256] {
                transcriptState.attachments[index].asset = asset
            }
        }
        mcpRevision = revision + 1
        updateStatus()
        saveUntitledDraft()
    }
    private(set) var mediaSnapshot = ProjectMediaSnapshot() {
        didSet { ignoredMediaPaths = mediaSnapshot.ignoredPaths }
    }
    private var ignoredMediaPaths: Set<String> = []
    private var mediaSnapshotChanged = false
    private var mediaRelinkIndexing = Set<URL>()
    private var mediaRelinkCancellation: EditCancellation?
    @Published private(set) var mediaRelinkProgress: Double?
    private(set) var openingProjectURL: URL? {
        didSet { sidecarPreference.projectURL = openingProjectURL.flatMap {
            ProjectDraft.isManaged($0) || draft.managesDestination($0) ? nil : $0
        } ?? projectURL }
    }
    let draft: ProjectDraft
    private var committedBeforeImport: CutProject?
    private var savedSequence: [CutSequenceClip] = []
    private var savedStillSequence: StillSequenceProject?
    private var soundtrackMediaByURL: [URL: MediaInfo] = [:]
    private var soundtrackIndexes: [URL: UUID] = [:]
    private var savedAnalysisAnnotations = ProjectAnalysisAnnotations()
    private var savedParticipants = ParticipantProject()
    private var stillTimelineIDs: [String: UUID] = [:]
    private let stillSoundtrackWaveformID = UUID()
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

    var participantSourceReset: (() -> Void)?
    private(set) var mcpGeneration = UUID() {
        didSet { participantSourceReset?() }
    }
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
        return (segments[index].start, segments[index].end, edit.offsets[index], segments[index].sourceExtent)
    }

    func mcpSceneSource(for clip: UUID) -> String? {
        segments.first { $0.id == clip }?.source.id.uuidString
    }

    func mcpClipMediaIssue(_ id: UUID) -> String? {
        segments.first { $0.id == id }.flatMap(mediaReviewIssue)
    }

    var mcpCopyContainers: [String] {
        // No container carries a packet copy of clips in different formats.
        guard let source = edit.preparation.firstMedia, !isMixedTimeline,
              segments.allSatisfy({ mediaReviewIssue($0) == nil }) else { return [] }
        let choices = CutEngine(tracks: source.hasVideo ? .all : .audio)
            .suggestedContainers(for: source, clips: segments.map(\.request))
        return source.hasVideo && choices.isEmpty ? [preferredCopyContainer ?? "mp4"] : choices
    }

    var sequenceClips: [CutSequenceClip] { edit.documentClips }
    var interchangeIndexedMedia: [MediaInfo] {
        let reviewedSoundtracks = soundtrackMediaByURL.values.filter {
            let url = ProjectMediaVolume.watchURL($0.url)
            return !incompatibleMedia.contains(url) && (refreshReviewStreams[url] ?? []).isEmpty
        }
        return Array(edit.preparation.sourceMedia.values) + reviewedSoundtracks
    }
    var interchangeCheckingVolumes: Set<String> { mediaWatcher?.checkingVolumes ?? ProjectMediaWatcher.knownCheckingVolumes }
    var transcriptProject: CutProject {
        var project = stillProject
        project.transcripts = transcriptState
        return project
    }

    var stillProject: CutProject {
        var project = edit.stillSequence.map(CutProject.stillSequence) ?? .sequence(sequenceClips)
        project.analysisAnnotations = edit.analysisAnnotations
        project.participants = edit.participants
        return project
    }

    var participantProject: ParticipantProject { edit.participants }

    func replaceTileLayoutProject(_ next: CutProject, action: String = "Set Tile Layout") throws {
        try applyStillProjectByHand(next, action: action, installsParticipants: true)
    }

    func replaceParticipantProject(_ next: ParticipantProject, action: String) throws {
        guard !isBusy, alert == nil else {
            throw CutError(code: "editor_busy", message: "The sequence is unavailable for editing.")
        }
        guard next != edit.participants else { return }
        var candidate = stillProject
        candidate.participants = next
        try candidate.validate()
        undoStack.append(HistoryEntry(action: action, contents: .live(snapshot()),
                                      copyContainer: explicitCopyContainer, transcriptState: transcriptState))
        redoStack.removeAll()
        unopenedConversionRedo.removeAll()
        enforceHistoryLimit()
        edit.participants = next
        mcpRevision += 1
        restorePreview(at: playhead)
        refreshTier()
        updateStatus()
        saveUntitledDraft()
    }

    @Published private(set) var transcriptState = ProjectTranscripts() {
        didSet { projectMediaSummaryPaths.invalidate() }
    }
    private var savedTranscriptState = ProjectTranscripts()

    func transcriptAssetContext() throws -> URL {
        if let url = projectURL ?? draft.url { return url }
        let writer = documentWriter()
        try draft.write { _ = try writer($0) }
        guard let url = draft.url else { throw CutError(code: "missing_project", message: "The project is unavailable.") }
        return url
    }

    func setTranscriptState(_ proposed: ProjectTranscripts, action: String? = nil) throws {
        var next = proposed
        next.revision = transcriptState.revision
        guard next != transcriptState else { return }
        try next.advanceRevision()
        try next.validate()
        if let action {
            undoStack.append(HistoryEntry(action: action, contents: .live(snapshot()),
                                              copyContainer: explicitCopyContainer, transcriptState: transcriptState))
            redoStack.removeAll()
            unopenedConversionRedo.removeAll()
            enforceHistoryLimit()
        }
        transcriptState = next
        rebuildPausePlan()
        refreshSidecarExclusions()
        updateStatus()
        saveUntitledDraft()
    }

    private func sequenceClips(for segments: [EditorSegment]) -> [CutSequenceClip] {
        segments.map { clip in
            CutSequenceClip(id: clip.documentID, file: clip.source.url.path,
                            from: clip.start, to: clip.end, audioTrack: clip.source.replacementTrack,
                            originalFile: clip.source.originalURL == clip.source.url ? nil : clip.source.originalURL.path,
                            replacementNames: clip.source.replacementNames, tileLayouts: clip.tileLayouts)
        }
    }

    @Published private(set) var isProjectChanged = false

    var canOpenProject: Bool {
        projectURL == nil && draft.url == nil && isEmpty && !hasHistory && queuedRanges.isEmpty && !isBusy && alert == nil
    }

    func openProject(_ clips: [CutSequenceClip], at url: URL,
                     history: (undo: [CutHistoryState], redo: [CutHistoryState])? = nil,
                     reservation: ProjectDraft.Reservation? = nil, archiveMedia: CutProjectMedia? = nil,
                     allowCommit: (() -> Bool)? = nil, stillProject: CutProject? = nil,
                     openingConversionHistory: Bool = false,
                     onConversionHistory: (([CutHistoryState]) -> Void)? = nil) throws {
        guard canOpenProject else {
            throw CutError(code: "editor_in_use", message: "Open the project in an empty editor window.")
        }
        let reservation = openingConversionHistory ? nil : try reservation ?? draft.reserveIfRecoverable(url)
        try CutProject.sequence(clips).validate()
        let disk = history == nil && FileManager.default.fileExists(atPath: url.path)
            ? try CutProject.loadEditorDocument(from: url, limit: preferences.historyLimit) : nil
        let archive = history ?? (undo: disk?.undo ?? [], redo: disk?.redo ?? [])
        let media = archiveMedia ?? disk?.media
        let checkingVolumes = interchangeCheckingVolumes
        let diskPaths = ProjectMediaVolume.$checking.withValue(checkingVolumes) { media?.absoluteSources(relativeTo: url) }
        var resolvedPaths: [String: String] = [:]
        func resolve(_ file: String) -> String {
            if let cached = resolvedPaths[file] { return cached }
            let path = ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                CutProject.mediaURL(file, relativeTo: url).path
            }
            resolvedPaths[file] = path
            return path
        }
        func absoluteProject(_ project: CutProject) throws -> CutProject {
            guard project.timelineOutputClock == .sequence else {
                throw CutError(code: "invalid_cut_project", message: "A sequence history state must contain a sequence.")
            }
            return project.mapMediaPaths(resolve)
        }
        func entries(_ states: [CutHistoryState]) throws -> [HistoryEntry] {
            try states.map { state in
                HistoryEntry(action: state.action, origin: state.origin, contents: .document(try absoluteProject(state.project)),
                             bindingChanges: state.bindingChanges?.map { $0.mappingPaths(resolve) } ?? [])
            }
        }
        let loadedProject: CutProject
        if let stillProject { loadedProject = stillProject }
        else if let project = disk?.project { loadedProject = project }
        else { loadedProject = .sequence(clips) }
        let fullDocument = try absoluteProject(loadedProject)
        try fullDocument.validate()
        let localRedo = archive.redo.reversed().prefix { $0.project.timelineOutputClock == .sequence }.reversed()
        let conversion = archive.redo.dropLast(localRedo.count).map { state in
            CutHistoryState(action: state.action, origin: state.origin, project: state.project.mapMediaPaths(resolve),
                            bindingChanges: state.bindingChanges?.map { $0.mappingPaths(resolve) })
        }
        let undo = try entries(archive.undo), redo = try entries(Array(localRedo))
        let document = fullDocument.sequenceClips ?? []
        var paths = diskPaths ?? [:]
        if diskPaths == nil {
            for (relative, path) in resolvedPaths { paths[path] = relative }
        }
        let openedMediaSnapshot = media?.mediaSnapshot.mappingPaths(resolve) ?? .empty
        let opened = {
            self.mcpGeneration = UUID()
            self.mcpRevision = 0
            self.transcriptState = fullDocument.transcripts
            self.edit.participants = fullDocument.participants
            self.edit.analysisAnnotations = fullDocument.analysisAnnotations
            self.restoreAnalysisAnnotations()
            self.savedMediaPaths = paths
            self.mediaSnapshot = openedMediaSnapshot
            self.mediaSnapshotChanged = false
            self.recoveredDraft = self.draft.adopt(reservation)
            self.projectURL = self.recoveredDraft ? nil : url
            self.projectDiskRevision = self.recoveredDraft ? nil : media?.diskRevision
            self.undoStack = undo
            self.redoStack = redo
            self.enforceHistoryLimit()
            self.markSaved()
            self.updateStatus()
            self.unopenedConversionRedo = conversion
            onConversionHistory?(conversion)
        }
        if document.isEmpty {
            if allowCommit?() != false {
                installStillPresentation(fullDocument)
                opened()
            }
        } else {
            let files = document.map { URL(fileURLWithPath: $0.file, isDirectory: false) }
            openingProjectURL = url
            importFiles(files, projectClips: document, openingMedia: paths, allowCommit: allowCommit, installed: opened,
                        sequenceProject: fullDocument, sourceSnapshot: openedMediaSnapshot)
        }
    }

    private func markSaved() {
        mediaSnapshotChanged = false
        savedSequence = sequenceClips
        savedStillSequence = edit.stillSequence
        savedAnalysisAnnotations = edit.analysisAnnotations
        savedParticipants = edit.participants
        savedTranscriptState = transcriptState
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
    func saveProject(to url: URL, flushDraftAnalysis: Bool = true) -> Bool {
        do {
            try writeProject(to: url, flushDraftAnalysis: flushDraftAnalysis)
            return true
        } catch {
            ProjectPanels.present(NSAlert(error: error), in: editorWindow)
            return false
        }
    }

    func writeProject(to url: URL, replacingExisting: Bool = true, flushDraftAnalysis: Bool = true) throws {
        if interchangeCheckingVolumes.contains(ProjectMediaVolume.key(for: url)) {
            throw CutError(code: "media_volume_checking", message: "The destination volume is still checking: \(url.path)")
        }
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
        let write = documentWriter(replacingExisting: replacingExisting, coordinate: true, expected: expected)
        let saved = try write(url)
        if let save = saved {
            projectDiskRevision = save.revision
            var updated = transcriptState
            for (index, attachment) in save.transcripts.attachments.enumerated() {
                updated.attachments[index].asset = attachment.asset
            }
            transcriptState = updated
        }
        let flush = flushDraftAnalysis && projectURL == nil && useAnalysisSidecars && SidecarLocations.mode == .project
        projectURL = url
        // Keep every recording referenced by the saved file until the next explicit save.
        savedMediaPaths = documentMedia()
        refreshSidecarExclusions()
        recoveredDraft = false
        markSaved()
        draft.discard()
        if flush { saveAnalysisSidecars(afterFirstProjectSave: true) }
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
            for asset in project.stillAssets where !asset.isGap { paths[asset.file] = asset.id }
            collect([project.stillAudioReference, project.stillSoundtrack].compactMap { $0 })
            for select in project.sourceSelects { paths[select.range.file] = select.id }
            for (id, path) in project.analysisAnnotations.protectedPaths { paths[path] = id }
            for (id, path) in project.participants.protectedMediaPaths { paths[path] = id }
            for record in project.transcripts.authoring {
                for anchor in record.anchors + [record.speakerReference].compactMap({ $0 }) {
                    if let file = anchor.binding.file { paths[file] = record.id }
                }
            }
            for attachment in project.transcripts.attachments {
                for binding in attachment.bindings {
                    if let file = binding.file { paths[file] = attachment.id }
                }
            }
        }
        collect(sequenceClips)
        collectProject(transcriptProject)
        for entry in undoStack { collect(entry.clips); collectProject(entry.project) }
        for entry in redoStack { collect(entry.clips); collectProject(entry.project) }
        for state in conversionRedo {
            for (id, path) in state.project.mediaPaths { paths[path] = id }
        }
        return paths
    }

    private var protectedMedia: [String: String] {
        var files = documentMedia(including: savedMediaPaths)
        for range in queuedRanges {
            for dependency in range.mediaDependencies { files[dependency.path] = dependency.lastPathComponent }
            for clip in range.clips { files[clip.file.path] = clip.file.lastPathComponent }
            for asset in range.stillProject?.stillAssets ?? [] { files[asset.file] = asset.id }
            for reference in [range.stillProject?.stillAudioReference, range.stillProject?.stillSoundtrack].compactMap({ $0 }) {
                files[reference.file] = reference.id
                if let original = reference.originalFile { files[original] = reference.id }
            }
        }
        return files
    }

    func validateHistoryDestination(_ output: URL, includesContents: Bool = false) throws {
        try ProjectMediaVolume.$checking.withValue(interchangeCheckingVolumes) {
            try CutProject.validateMediaDestination(output, absoluteSources: protectedMedia, includesContents: includesContents)
        }
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
        let excluded = ProjectMediaVolume.$checking.withValue(interchangeCheckingVolumes) {
            CutProject.sidecarExclusions(absoluteSources: paths, candidates: Array(candidates), projectURL: sidecarWork.project)
        }
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
        -> @Sendable (URL) throws -> (revision: ProjectDiskRevision, transcripts: ProjectTranscripts)? {
        func state(_ entry: HistoryEntry) -> CutHistoryState {
            CutHistoryState(action: entry.action, origin: entry.origin, project: entry.project, bindingChanges: entry.bindingChanges)
        }
        let project = snapshot ?? transcriptProject
        let undo = undoStack.map(state), redo = conversionRedo + redoStack.map(state)
        let snapshotMedia = projectMediaSnapshotForWriting
        let checkingVolumes = interchangeCheckingVolumes
        return { url in
            try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                var paths: [String: String] = [:]
                func relative(_ file: String) -> String {
                    if let cached = paths[file] { return cached }
                    let path = CutProject.relativeMediaPath(file, to: url)
                    paths[file] = path
                    return path
                }
                func rebased(_ state: CutHistoryState) -> CutHistoryState {
                    CutHistoryState(action: state.action, origin: state.origin, project: state.project.mapMediaPaths(relative),
                                    bindingChanges: state.bindingChanges?.map { $0.mappingPaths(relative) })
                }
                let current = project.mapMediaPaths(relative)
                let undo = undo.map(rebased), redo = redo.map(rebased)
                let mediaSnapshot = snapshotMedia.mappingPaths(relative)
                if coordinate {
                    let revision = try current.saveRevision(to: url, undo: undo, redo: redo, mediaSnapshot: mediaSnapshot,
                                                            replacingExisting: replacingExisting, expected: expected)
                    return (revision, current.transcripts)
                }
                try current.saveStaged(to: url, undo: undo, redo: redo, mediaSnapshot: mediaSnapshot, replacingExisting: replacingExisting)
                return nil
            }
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
    @Published private(set) var queuedRanges: [QueuedRange] = [] {
        didSet {
            var targets = QueueMediaTargets()
            for entry in queuedRanges { entry.addMediaTargets(to: &targets) }
            queuedMediaTargets = targets
            if mediaWatcher != nil { updateMediaWatcher() }
        }
    }
    private var queuedMediaTargets = QueueMediaTargets()
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

    private var storageObservers: Set<AnyCancellable> = []
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
        var origin = HistoryOrigin.current
        var contents: HistoryContents
        var project: CutProject {
            switch contents {
            case .live(let edit):
                var project = edit.stillSequence.map(CutProject.stillSequence) ?? .sequence(edit.documentClips)
                project.transcripts = transcriptState
                project.analysisAnnotations = edit.analysisAnnotations
                project.participants = edit.participants
                return project
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
        var transcriptState: ProjectTranscripts = .init()
        var audioMonitoring: AudioMonitoring?
        var bindingChanges: [TranscriptBindingChange] = []
    }
    /// Save and open panels attach to the editor, not to whichever window is main.
    weak var editorWindow: NSWindow?
    private var sheetWindow: NSWindow? { editorWindow.flatMap { $0.isVisible ? $0 : nil } }
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    var conversionRedoArchive: () -> [CutHistoryState] = { [] }
    private var unopenedConversionRedo: [CutHistoryState] = []
    func didOpenFeedAngleHistory() { unopenedConversionRedo.removeAll() }
    private var conversionRedo: [CutHistoryState] { unopenedConversionRedo + conversionRedoArchive() }
    var nativeConversionUndoArchive: [CutHistoryState] {
        undoStack.map { .init(action: $0.action, origin: $0.origin, project: $0.project, bindingChanges: $0.bindingChanges) }
    }
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
    /// The folder this window's session chose in an export panel. It wins over Settings → Export → Start export panels in.
    private var exportDirectory: URL?
    /// The re-encode fields the editor changed in an export sheet. The rest start from Settings each time a sheet opens.
    private var exportEncodingKept: ExportEncodingFields = []
    /// Tests observe completion actions here instead of reaching `ExportCompletion.shared`.
    var exportCompletionHandler: ((URL) -> Void)?
    /// Keeps the Mac awake while an export runs. Tests replace it.
    var exportActivityProvider: any ActivityProviding = ProcessInfo.processInfo
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
    @Published private(set) var invalidatedQueueIDs = Set<UUID>()
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
    private var tileTimelineCache: (participants: ParticipantProject, clips: [CutSequenceClip], ids: [UUID],
                                    document: URL?, content: [UUID: TileTimelineContent])?
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
    var analysisSourceMedia: [UUID: MediaInfo] {
        edit.preparation.sourceMedia.filter { !edit.preparation.unavailableSourceIDs.contains($0.key) }
    }
    private var snapScanRequests = Set<UUID>()
    /// Recordings added while Settings → Media → Scan for scenes / pauses when a recording is added was on, whose
    /// automatic scan has not started yet. A source leaves when its scan starts, so a scan the editor cancels stays cancelled.
    private var automaticSceneScanSources = Set<UUID>()
    private var automaticSilenceScanSources = Set<UUID>()
    private var sidecarSaveToken: EditCancellation?
    private var isFlushingDraftSidecars = false
    var nativeSidecarSave: MCPNativeOperation? {
        guard let token = sidecarSaveToken, mcpSidecarReceipt == nil else { return nil }
        return MCPNativeOperation(id: token.id, kind: "sidecars", label: "Saving analysis sidecars…",
                                  progress: nil, cancelling: token.isCancelled)
    }

    func cancelNativeSidecarSave(id: UUID) {
        if sidecarSaveToken?.id == id { sidecarSaveToken?.cancel() }
    }

    private var lastSidecarWrite: (id: UUID, task: Task<Void, Never>)?
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
        if case .partial = disposition { return disposition }
        if let clipID {
            guard let clip = segments.first(where: { $0.id == clipID }) else { return nil }
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
    var padding: Double {
        get { preferences.padding }
        set { preferences.padding = newValue }
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
    private(set) var timelinePadding: [AudioSpan] = []
    private(set) var pausePlan: [TimelinePause] = []
    private var pauseReviewSourceChanged = false
    private(set) var pauseReviewMismatch = false
    private var protectedPauses: [TimelinePause.Source: [AudioSpan]] = [:]
    private var pauseRetainedSeconds: [TimelinePause.Key: Double] = [:]
    private var takeBoundaries: [UUID: Set<RationalTime>] = [:]
    private var transcriptPauseCache = TranscriptPauseProtectionCache()
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
    var playheadAudioTracks: [StreamInfo] { playheadAudioSource?.media?.streams.filter { $0.kind == "audio" } ?? [] }
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
        NotificationCenter.default.publisher(for: .sidecarStorageDidChange).sink { [weak self] _ in
            guard let self else { return }
            self.lastSidecarCandidates = []
            self.refreshSidecarExclusions()
        }.store(in: &storageObservers)
        NotificationCenter.default.publisher(for: .sidecarCachesDidClear).sink { [weak self] notification in
            guard let self, let sources = notification.object as? Set<URL> else { return }
            self.discardClearedAnalysis(sources, whole: notification.userInfo?["wholeSidecars"] as? Bool == true)
        }.store(in: &storageObservers)
        audioStore.changed = { [weak self] complete in
            guard let self else { return }
            if complete { self.refreshDetectedPauses() }
            if !complete || self.stillProject.stillSoundtrack != nil { self.waveformRevision += 1 }
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

    private func discardClearedAnalysis(_ sources: Set<URL>, whole: Bool) {
        let urls = Set(sources.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        let affected = edit.preparation.sourceMedia.filter { urls.contains($0.value.url.standardizedFileURL.resolvingSymlinksInPath()) }
        guard !affected.isEmpty else { return }
        sidecarSaveToken?.cancel()
        mediaRefresh.cancel()
        for (id, media) in affected {
            filmstripTiles.removeSource(id)
            pauseDetections.removeValue(forKey: id)?.cancel()
            checkedSilenceSidecars.remove(id)
            silenceResults[id] = nil
            sourcePauses[id] = nil
            audioStore.refresh(id, media: media, preserving: [])
            invalidateSceneScan(for: id)
            staleSceneReports[id] = nil
            staleSceneRangeReports = staleSceneRangeReports.filter { $0.key.source != id }
            automaticThresholds[id] = nil
            let report = edit.analysisAnnotations.scene(for: media)
            sceneReports[id] = report
            scenesBySource[id] = report?.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) }
            viewNamesBySource[id] = report.map { Dictionary(uniqueKeysWithValues: $0.views.compactMap { view in
                view.name.map { (view.view, $0) }
            }) }
            if whole {
                for (track, stream) in media.streams.filter({ $0.kind == "audio" }).enumerated() {
                    thresholdOverrides[AudioTrackKey(source: id, track: track)] = edit.analysisAnnotations.threshold(for: media, stream: stream.index)
                }
            }
        }
        preview.invalidateMedia(alsoFilmstrip: true)
        waveformRevision += 1
        sceneRevision += 1
        rebuildPausePlan()
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
        case .largeThumbnails, .sourceTimeTicks:
            break
        case .minimumPause, .maxBlip:
            refreshDetectedPauses(invalidating: activeAudioSources)
        case .padding:
            rebuildPausePlan()
        default:
            // New work reads its starting values when it is created.
            return
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
    private var inlineStillCount: Int { edit.timelineClips.count - segments.count }
    private var hasInlineStills: Bool { inlineStillCount > 0 }
    var windowTitle: String {
        if let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        guard let first = edit.timelineClips.first else { return "Untitled" }
        let additional = Set(segments.map { $0.source.id }).count + inlineStillCount - 1
        return additional > 0 ? "\(first.name) + \(additional)" : first.name
    }
    var isEmpty: Bool { segments.isEmpty && !hasInlineStills }
    var hasPicture: Bool { hasInlineStills || edit.preparation.firstMedia?.hasVideo == true }
    var isAudioOnly: Bool {
        guard !isEmpty, !hasInlineStills else { return false }
        if let media = edit.preparation.firstMedia { return !media.hasVideo }
        return segments.allSatisfy { $0.source.unresolved?.isAudioOnly == true || $0.source.media?.hasVideo == false }
    }
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
    var isBusy: Bool { isBusyOutsideQueue || isBulkQueuePresented }
    private var isBusyOutsideQueue: Bool {
        mediaRefreshProgress != nil || isImporting || isExporting || isCheckingEdit || isPreparingCopyBoundaries ||
            isPresentingPanel || cutPreview != nil || waitingForExportCleanup
    }
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
        let cuts = [span.from, span.to].filter(isInsideClip)
        return !cuts.isEmpty && cuts.allSatisfy { cut in
            if stillInsert(at: cut.seconds) != nil { return true }
            return locatedSegment(at: cut.seconds).map { mediaReviewIssue($0.1) == nil } ?? false
        }
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
        guard canEdit else { return false }
        if let selectedID, let card = edit.inlineStillsByID[selectedID] {
            return edge == .end && !restore && playhead > card.start.seconds && playhead < card.end.seconds
        }
        guard let index = selectedClipIndex else { return false }
        let clip = segments[index]
        guard mediaReviewIssue(clip) == nil else { return false }
        if restore { return edge == .start ? clip.start > .zero : clip.end < clip.sourceExtent }
        let offset = edit.offsets[index].seconds
        return playhead > offset && playhead < offset + clip.duration.seconds
    }

    func trimSelected(_ edge: TimelineEdge, restore: Bool = false) {
        guard canTrimSelected(edge, restore: restore) else { return }
        if let selectedID, let card = edit.inlineStillsByID[selectedID] {
            _ = resizeStillEnd(card, duration: playhead - card.start.seconds, commit: true)
            return
        }
        guard let index = selectedClipIndex else { return }
        let clip = segments[index]
        let sourceTime = restore ? (edge == .start ? 0 : clip.sourceExtent.seconds)
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
        guard let media = edit.preparation.firstMedia else { return nil }
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
        // Finder and drop requests can resume inside a remote operation's completion.
        HistoryOrigin.$current.withValue(.user) { importFiles(files) }
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

    func importFiles(_ urls: [URL], at index: Int? = nil, timelineSlot: Int? = nil, allowCommit: (() -> Bool)? = nil) {
        if allowCommit == nil {
            let images = urls.filter(StillPanels.isSupportedImage)
            if !images.isEmpty {
                let media = urls.filter { !StillPanels.isSupportedImage($0) }
                if media.isEmpty {
                    addDroppedStills(images, at: playhead)
                } else {
                    pendingOpenFiles.insert(contentsOf: images, at: 0)
                    importFiles(media, at: index, timelineSlot: timelineSlot, projectClips: nil, asksBeforeLoweringTier: true)
                }
                return
            }
        }
        // Clips added in the editor ask before lowering the tier. A remote import, which supplies `allowCommit`, does not.
        let mayAttachSoundtrack = allowCommit == nil && urls.count == 1 && urls[0].isFileURL &&
            stillSoundtrackControls.map { $0.name == nil } == true
        importFiles(urls, at: index, timelineSlot: timelineSlot, projectClips: nil, allowCommit: allowCommit,
                    asksBeforeLoweringTier: allowCommit == nil, mayAttachSoundtrack: mayAttachSoundtrack)
    }

    private static func requiredStillFragmentEnds(_ placements: [StillReplacement]) -> [String: RationalTime] {
        var ends: [String: RationalTime] = [:]
        for placement in placements {
            guard case .sequence(let fragments) = placement.coverage else { continue }
            for fragment in fragments {
                ends[fragment.clipID] = max(ends[fragment.clipID] ?? .zero, fragment.range.to)
            }
        }
        return ends
    }

    private func importFiles(_ urls: [URL], at index: Int? = nil, timelineSlot: Int? = nil, projectClips: [CutSequenceClip]?,
                             openingMedia: [String: String] = [:],
                             beforeInstall: (() throws -> Bool)? = nil, allowCommit: (() -> Bool)? = nil,
                             requestCancellation: EditCancellation? = nil, installed: (() -> Void)? = nil,
                             restoringAudioMonitoring: AudioMonitoring? = nil,
                             sequenceProject: CutProject? = nil, sourceSnapshot: ProjectMediaSnapshot? = nil,
                             asksBeforeLoweringTier asks: Bool = false, mayAttachSoundtrack: Bool = false,
                             preserveProjectPosition: Bool = false, preindexedMedia: [URL: MediaInfo] = [:],
                             keepUnavailableRangesAt: Set<URL> = [],
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
        let stillFragmentEnds = Self.requiredStillFragmentEnds(sequenceProject?.stillReplacements ?? [])
        let existing = projectClips == nil ? segments : []
        let priorPreparation = edit.preparation
        let entries = Dictionary((sourceSnapshot ?? mediaSnapshot).entries.map { ($0.path, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var stillExtents: [String: RationalTime] = [:]
        for replacement in sequenceProject?.stillReplacements ?? [] {
            guard case .sequence(let fragments) = replacement.coverage else { continue }
            for fragment in fragments {
                stillExtents[fragment.clipID] = max(stillExtents[fragment.clipID] ?? .zero, fragment.range.to)
            }
        }
        let requiredStillExtents = stillExtents
        let checkingPaths = Set(projectClips?.compactMap { clip -> String? in
            mediaWatcher?.status(for: URL(fileURLWithPath: clip.file, isDirectory: false)) == .checking ? clip.file : nil
        } ?? [])
        let publishPartial = allowCommit == nil && requestCancellation == nil
        let beforeImport = snapshot()
        committedBeforeImport = transcriptProject
        let openingAnnotations = sequenceProject?.analysisAnnotations ?? beforeImport.analysisAnnotations
        let insertion = min(max(0, index ?? existing.count), existing.count)
        // Stills occupy timeline slots but have no entry in the indexed source array.
        // Build partial and final presentations from the same pre-import ordering.
        @MainActor @Sendable func projectAfterImport(_ proposed: [EditorSegment]) -> CutProject? {
            guard projectClips == nil, var sequence = beforeImport.stillSequence,
                  let slot = timelineSlot ?? (index == nil ? sequence.items.count : nil) else { return sequenceProject }
            let count = proposed.count - existing.count
            let added = sequenceClips(for: Array(proposed[insertion..<(insertion + count)]))
            sequence.items.insert(contentsOf: added.map(StillSequenceItem.source),
                                  at: min(max(0, slot), sequence.items.count))
            if sequence.stillFormat != nil {
                sequence.stillFormat = nil
                sequence.programColorPolicy = nil
            }
            sequence.analysisAnnotations = beforeImport.analysisAnnotations
            sequence.participants = beforeImport.participants
            return .stillSequence(sequence)
        }
        let currentSession = session
        let importRevision = mcpRevision
        let pendingWrite = lastSidecarWrite?.task
        importProgress = 0
        isImporting = true
        Task {
            // A quick Close Video and reopen must see the last accepted edits.
            await pendingWrite?.value
            let result = await sidecarWork.detached(priority: .utility) {
                var additions: [EditorSegment] = []
                var soundtrack: MediaInfo?
                var rejected: [String] = []
                var savedAnalysis: [UUID: SavedEditorAnalysis] = [:]
                var indexed = Dictionary(existing.compactMap { $0.source.indexed }.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
                for (url, media) in preindexedMedia {
                    let source = IndexedSource(media: preference.attachingDocument(to: media))
                    indexed[url] = source
                    if preference.permits(url) {
                        savedAnalysis[source.id] = SavedEditorAnalysis(media: media, cancelled: { token.isCancelled || !preference.permits(url) })
                    }
                }
                for source in existing.compactMap({ $0.source.indexed }) where indexed[source.originalURL] == nil {
                    indexed[source.originalURL] = source
                }
                var unresolvedIDs: [DocumentSourceKey: UUID] = [:]
                var documentSources: [DocumentSourceKey: IndexedSource] = [:]
                var pictureReference = existing.compactMap { $0.source.media }.first
                var ordinaryReference = existing.lazy.filter { !$0.source.isAudioReplacement }.compactMap { $0.source.media }.first
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
                    let document = projectClips?[offset]
                    let canonical: URL
                    let original = document?.originalFile.map { URL(fileURLWithPath: $0, isDirectory: false) }
                    var provisional: EditorSegment?
                    do {
                        if let document, checkingPaths.contains(document.file) {
                            throw CutError(code: "source_checking", message: "Waiting for the recording’s volume to respond.")
                        }
                        if let document, document.file.split(separator: "/").contains("..") {
                            canonical = try CutProject.checkedMediaURL(document.file, relativeTo: file)
                        } else {
                            canonical = file.standardizedFileURL
                        }
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
                                        return preference.attachingDocument(to: index.ordinary)
                                    } catch is CancellationError where settings.change.isCancelled && !token.isCancelled {
                                        continue
                                    }
                                }
                                throw CancellationError()
                            }

                            let canPublishPreview = publishPartial && projectClips == nil && existing.isEmpty && additions.isEmpty
                            let header = canPublishPreview ? try? await read(true) : nil
                            if let preview = header, !preview.hasFullEditIndex, preview.timelineIssue == nil,
                               !mayAttachSoundtrack || preview.hasVideo {
                                let clip = EditorSegment(source: IndexedSource(media: preview))
                                provisional = clip
                                let prepared = PreparedEdit(segments: [clip], previous: prior, engine: engine)
                                await MainActor.run {
                                    guard self.session == currentSession, !token.isCancelled else { return }
                                    self.apply([clip], prepared: prepared, selecting: clip.id, at: 0,
                                               action: "Add Clip", recordHistory: false, sequenceProject: projectAfterImport([clip]))
                                }
                            }
                            let media: MediaInfo
                            if let header, header.hasFullEditIndex {
                                media = header
                            } else {
                                media = try await read(false, identity: header?.identity)
                            }
                            if mayAttachSoundtrack, !media.hasVideo, !media.audio.isEmpty {
                                soundtrack = media.forRefreshAlias(media.url.resolvingSymlinksInPath())
                                break
                            }
                            try Self.checkEditable(media)
                            source = IndexedSource(media: media, id: provisional?.source.id ?? UUID())
                            if preference.permits(canonical) {
                                savedAnalysis[source.id] = SavedEditorAnalysis(media: media, cancelled: { token.isCancelled || !preference.permits(canonical) })
                            }
                        }
                        openingAnnotations.prepareEvidence(for: source.media)
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
                        indexed[canonical] = source
                        if let document {
                            guard document.from >= .zero, document.from < document.to, document.to <= source.duration else {
                                throw CutError(code: "project_clip_range", message: "The saved trim exceeds the recording duration.")
                            }
                            if let required = requiredStillExtents[document.id], required > source.duration {
                                throw CutError(code: "project_clip_range", message: "A saved still replacement extends past the recording.")
                            }
                            if let fragmentEnd = stillFragmentEnds[document.id], fragmentEnd > source.duration {
                                throw CutError(code: "project_clip_range", message: "A still replacement exceeds the recording duration.")
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
                            additions.append(EditorSegment(documentID: document.id, source: restored, start: document.from, end: document.to, tileLayouts: document.tileLayouts))
                        } else {
                            additions.append(EditorSegment(id: provisional?.id ?? UUID(), source: source))
                        }
                        if pictureReference == nil { pictureReference = source.media }
                        if ordinaryReference == nil && !isReplacement { ordinaryReference = source.media }
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
                                           preservePreview: true, sequenceProject: projectAfterImport(clips))
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
                        if let document {
                            let original = original ?? file
                            let key = DocumentSourceKey(file: file, original: original, track: document.audioTrack,
                                                        names: document.replacementNames)
                            let id = unresolvedIDs[key] ?? UUID()
                            unresolvedIDs[key] = id
                            let checking = checkingPaths.contains(document.file)
                            let present = !checking && (error as? CutError)?.code != "missing_source"
                                && FileManager.default.fileExists(atPath: file.path)
                            let snapshot = entries[document.file]
                            let keptOffline = (error as? CutError)?.code == "project_clip_range"
                                && keepUnavailableRangesAt.contains(ProjectMediaVolume.watchURL(file))
                            let status: ProjectMediaStatus = checking ? .checking
                                : present && !keptOffline ? .needsReview : snapshot?.ignored == true ? .ignored : .offline
                            let source = UnresolvedSource(id: id, url: file, originalURL: original,
                                                          replacementNames: document.replacementNames,
                                                          replacementTrack: document.audioTrack, status: status,
                                                          detail: checking || present ? error.localizedDescription : "Recording is offline.",
                                                          snapshot: snapshot)
                            additions.append(EditorSegment(documentID: document.id, source: .unresolved(source),
                                                           start: document.from, end: document.to, tileLayouts: document.tileLayouts))
                        } else {
                            rejected.append("\(file.lastPathComponent) — \(error.localizedDescription)")
                        }
                    }
                }
                var candidate = existing
                candidate.insert(contentsOf: additions, at: insertion)
                let prepared = PreparedEdit(segments: candidate, previous: prior, engine: engine)
                return (candidate, additions.count, rejected, prepared, savedAnalysis, soundtrack)
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
            if let soundtrack = result.5 {
                guard mcpRevision == importRevision else { return }
                selectStillSoundtrackTrack(soundtrack, generation: mcpGeneration, revision: importRevision)
                outcome = .success(())
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
                            viewNamesBySource[id] = [:]
                        }
                    }
                    sceneRevision += 1
                }
                let selectedDocumentID = preserveProjectPosition
                    ? beforeImport.segments.first(where: { $0.id == beforeImport.selectedID })?.documentID : nil
                let selected = result.0.first(where: { $0.documentID == selectedDocumentID })?.id ?? result.0[insertion].id
                let applied = apply(result.0, prepared: result.3, selecting: selected,
                      at: preserveProjectPosition ? beforeImport.playhead : (projectClips == nil ? playhead : 0),
                      action: result.1 == 1 ? "Add Clip" : "Add Clips", recordHistory: projectClips == nil, historySnapshot: beforeImport,
                      preservePreview: true, preserveMarks: preserveProjectPosition, restoringAudioMonitoring: restoringAudioMonitoring,
                      sequenceProject: projectAfterImport(result.0))
                if applied {
                    outcome = .success(())
                    if projectClips != nil { installed?() }
                    else {
                        let additions = result.0[insertion..<(insertion + result.1)]
                        preferences.recentFiles.record(additions.map { $0.source.url })
                        // Read when the recording is added. Turning the setting on later never scans what is already open.
                        if preferences.autoScanScenes { automaticSceneScanSources.formUnion(additions.map { $0.source.id }) }
                        if preferences.autoScanSilence { automaticSilenceScanSources.formUnion(additions.map { $0.source.id }) }
                    }
                } else {
                    outcome = .failure(CutError(code: "import_incomplete", message: alert?.message ?? "The editor could not install the media."))
                    if completion != nil { alert = nil }
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
        if preview.hasSoundtrack {
            preview.scrubSoundtrack(to: target)
            usesPointerPosition = true
            return
        }
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

    @discardableResult
    func setViewName(_ text: String, source: UUID, view: Int) -> Bool {
        guard var report = sceneReports[source], let original = report.views.first(where: { $0.view == view }) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nil : trimmed
        guard original.name != name else { return true }
        report.setViewName(name, for: view)
        var annotations = edit.analysisAnnotations
        guard let media = self.edit.preparation.sourceMedia[source], annotations.setScene(report, for: media) else { return false }
        commitAnalysisAnnotations(annotations, action: "Rename Scene View")
        return true
    }

    func commitAnalysisAnnotations(_ next: ProjectAnalysisAnnotations, action: String) {
        guard next != edit.analysisAnnotations else { return }
        undoStack.append(HistoryEntry(action: action, contents: .live(snapshot()),
                                      copyContainer: explicitCopyContainer, transcriptState: transcriptState))
        redoStack.removeAll()
        unopenedConversionRedo.removeAll()
        enforceHistoryLimit()
        edit.analysisAnnotations = next
        restoreAnalysisAnnotations()
        mcpRevision += 1
        updateStatus()
        saveUntitledDraft()
    }

    private func restoreAnalysisAnnotations() {
        refreshPauseReviews()
        let annotations = edit.analysisAnnotations
        var changedThresholds = Set<UUID>()
        for (id, media) in edit.preparation.sourceMedia {
            for (ordinal, stream) in media.streams.filter({ $0.kind == "audio" }).enumerated() {
                let key = AudioTrackKey(source: id, track: ordinal)
                let value = annotations.threshold(for: media, stream: stream.index)
                if value == nil && annotations.silence.contains(where: { $0.file == media.url.path && $0.stream == stream.index }) { refreshStaleSilence.insert(id) }
                if thresholdOverrides[key] != value {
                    thresholdOverrides[key] = value
                    changedThresholds.insert(id)
                }
            }
            if let reviewed = annotations.scene(for: media) {
                if sceneReports[id] != reviewed { installSceneReport(reviewed, for: id, replacing: true) }
            } else if var report = sceneReports[id], report.views.contains(where: { $0.name != nil }) {
                for view in report.views { report.setViewName(nil, for: view.view) }
                installSceneReport(report, for: id, replacing: true)
            }
            if annotations.needsSceneReview(for: media) {
                refreshStaleScenes.insert(id)
            }
        }
        if !changedThresholds.isEmpty { refreshDetectedPauses(invalidating: changedThresholds) }
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
        if !automaticSceneScanSources.isEmpty { automaticSceneScanSources.formIntersection(edit.preparation.sourceMedia.keys) }
        if !automaticSilenceScanSources.isEmpty { automaticSilenceScanSources.formIntersection(edit.preparation.sourceMedia.keys) }
        guard canEdit else { return }
        startAutomaticSceneScan()
        switch effectiveSnapTarget {
        case .silence where refreshStaleSilence.isEmpty && canScanSilence && !hasSilenceResults:
            let missing = activeAudioSources.subtracting(sourcePauses.keys)
            automaticSilenceScanSources.subtract(missing)
            guard !missing.isSubset(of: snapScanRequests) else { return }
            snapScanRequests.formUnion(missing)
            scanForSilence()
        default:
            startAutomaticSilenceScan()
        }
    }

    /// Scans the scenes of recordings added with Settings' automatic scene scan on, through the menu command's path.
    private func startAutomaticSceneScan() {
        guard !automaticSceneScanSources.isEmpty else { return }
        // A recording with saved scenes or without picture needs no scan.
        automaticSceneScanSources = automaticSceneScanSources.filter {
            sceneReports[$0] == nil && edit.preparation.sourceMedia[$0]?.hasVideo != false
        }
        guard sceneProgress == nil, canScanScenes(clipID: nil) else { return }
        let requests = sceneRequests(clipID: nil).filter { request in
            UUID(uuidString: request.id).map(automaticSceneScanSources.contains) == true
        }
        guard !requests.isEmpty else { return }
        // Leave before starting: the scan's finish asks for snap analysis again.
        automaticSceneScanSources.subtract(requests.compactMap { UUID(uuidString: $0.id) })
        runSceneRequests(requests, clip: nil, policy: .reuse)
    }

    /// Scans the pauses of recordings added with Settings' automatic pause scan on. It shares the snap scan's
    /// bookkeeping, so a cancelled scan is not started again by a later edit.
    private func startAutomaticSilenceScan() {
        guard !automaticSilenceScanSources.isEmpty else { return }
        automaticSilenceScanSources.subtract(sourcePauses.keys)
        guard refreshStaleSilence.isEmpty, canScanSilence, !hasSilenceResults else { return }
        let missing = activeAudioSources.subtracting(sourcePauses.keys)
        let added = automaticSilenceScanSources.intersection(missing)
        guard !added.isEmpty else { return }
        automaticSilenceScanSources.subtract(added)
        guard !missing.isSubset(of: snapScanRequests) else { return }
        snapScanRequests.formUnion(missing)
        scanForSilence()
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
        canScanScenes(clipID: nil) && segments.contains { $0.source.media?.hasVideo == true && mediaReviewIssue($0) == nil && sceneReports[$0.source.id] == nil }
    }

    func canScanScenes(clipID: UUID?) -> Bool {
        canEdit && sceneProgress == nil && !sceneRequests(clipID: clipID).isEmpty
    }

    private func sceneRequests(clipID: UUID?) -> [EditorSceneRequest] {
        if let clipID {
            guard let clip = segments.first(where: { $0.id == clipID && $0.source.isIndexed }),
                  let media = clip.source.media, media.hasVideo, mediaReviewIssue(clip) == nil,
                  clip.start < clip.end else { return [] }
            return [EditorSceneRequest(id: clip.id.uuidString, media: media,
                                       scope: .range(start: clip.start, end: clip.end))]
        }
        var seen = Set<UUID>()
        return segments.compactMap { clip in
            let source = clip.source
            guard source.isIndexed, let media = source.media, media.hasVideo, mediaReviewIssue(clip) == nil,
                  seen.insert(source.id).inserted else { return nil }
            return EditorSceneRequest(id: source.id.uuidString, media: media)
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

    func saveAnalysisSidecars() { saveAnalysisSidecars(afterFirstProjectSave: false) }

    private func saveAnalysisSidecars(afterFirstProjectSave: Bool) {
        guard canSaveAnalysisSidecars else { return }
        if SidecarLocations.mode == .project, projectURL == nil {
            if let receipt = mcpSidecarReceipt {
                receipt.finish("failed", detail: ["error": "Save the project before saving analysis in its folder."])
                mcpSidecarReceipt = nil
            } else {
                let panel = ProjectPanels.cutSavePanel(name: "Untitled.cut")
                ProjectPanels.present(panel, in: editorWindow) { [weak self] accepted in
                    guard let self, accepted, let url = panel.url, self.saveProject(to: url, flushDraftAnalysis: false) else { return }
                    self.saveAnalysisSidecars()
                }
            }
            return
        }
        var seen = Set<URL>()
        let snapshots = segments.compactMap { clip -> DesktopAnalysisSnapshot? in
            let source = clip.source
            guard let media = source.media, mediaReviewIssue(clip) == nil else { return nil }
            if afterFirstProjectSave, !media.hasFullEditIndex || !sidecarPreference.permits(source.url) { return nil }
            guard seen.insert(source.url).inserted else { return nil }
            return DesktopAnalysisSnapshot(sourceID: source.id, media: media.pinningSidecarWrites(), scenes: sceneReports[source.id],
                                          waveforms: audioStore.completedWaveforms(for: source.id, media: media),
                                          envelopeOverviews: audioStore.completedEnvelope(for: source.id, media: media),
                                          silence: completedSilences(for: source.id),
                                          filmstrip: filmstripTiles.snapshot(for: source.id))
        }
        guard !snapshots.isEmpty else { return }
        let excluded = CutProject.sidecarExclusions(absoluteSources: protectedMedia, candidates: snapshots.map { $0.media.url }, projectURL: projectURL)
        if let conflict = snapshots.first(where: { AnalysisSidecar.isExcluded($0.media.url, in: excluded) }) {
            alert = EditorNotice(title: "Couldn’t Save Analysis",
                                 message: "The analysis file for ‘\(conflict.media.url.lastPathComponent)’ would overwrite media referenced by this project.")
            return
        }
        let token = EditCancellation()
        sidecarSaveToken = token
        isFlushingDraftSidecars = afterFirstProjectSave
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
        let work = sidecarWork
        enqueueSidecarWrite { [self] in
            defer { endWork?() }
            // A close immediately after saving the draft can release the document before this queue drains.
            guard afterFirstProjectSave || sidecarSaveToken === token else { return }
            let (saved, failures, checkpoints) = await work.detached(priority: .utility) {
                var saved: [UUID: URL] = [:]
                var checkpoints: [(String, SceneScanProgress)] = []
                var failures: [String] = []
                for snapshot in snapshots {
                    if token.isCancelled { break }
                    do {
                        let location = try snapshot.save(cancelled: { token.isCancelled })
                        for item in checkpointRequests[snapshot.media.identity] ?? [] {
                            if token.isCancelled { break }
                            if let progress = try SceneAnalysis.saveCheckpoint(for: snapshot.media, scope: item.scope, session: sceneCache) {
                                checkpoints.append((item.id, progress))
                            }
                        }
                        saved[snapshot.sourceID] = location
                        outputs?.published(location)
                        outputs?.update(Double(saved.count) / Double(snapshots.count))
                    } catch {
                        if token.isCancelled { break }
                        failures.append("\(snapshot.media.url.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                return (saved, failures, checkpoints)
            }.value
            guard sidecarSaveToken === token else { return }
            for (id, progress) in checkpoints { sceneScan.didSaveCheckpoint(id, progress: progress) }
            if !checkpoints.isEmpty { sceneRevision += 1 }
            isSavingSidecars = false
            isFlushingDraftSidecars = false
            sidecarSaveToken = nil
            let paths = snapshots.compactMap { saved[$0.sourceID]?.path }
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
        if segments.contains(where: { clip in layoutSceneTimes(for: clip).contains { $0 >= clip.start && $0 < clip.end } }) {
            return true
        }
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
        let requests = repeatPrevious ? sceneScan.requests : sceneRequests(clipID: clipID)
        let clip = repeatPrevious ? previousSceneClip
            : clipID.flatMap { id in segments.first { $0.id == id } }.map(ClipSceneRange.init)
        // Restarting a paused scan discards its progress, so that question is always asked.
        guard paused || preferences.asks(.sceneRescan) else {
            guard canEdit, sceneProgress == nil else { return }
            runSceneRequests(requests, clip: clip, policy: .restart(operationID: UUID().uuidString))
            return
        }
        guard let window = sheetWindow else { return }
        let prompt = NSAlert()
        prompt.messageText = paused ? "Restart scene analysis?" : "Scan for scenes again?"
        prompt.informativeText = "MPCut will start a new analysis for this footage."
        prompt.addButton(withTitle: paused ? "Restart" : "Scan Again").toolTip = "Restart scene scan"
        prompt.addButton(withTitle: "Cancel").toolTip = "Keep existing scene analysis"
        if !paused {
            prompt.showsSuppressionButton = true
            prompt.suppressionButton?.title = "Don’t ask again"
            prompt.suppressionButton?.toolTip = "Scan again without asking"
        }
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if !paused, prompt.suppressionButton?.state == .on { self.preferences.suppress(.sceneRescan) }
            guard self.canEdit, self.sceneProgress == nil else { return }
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
        if let media = edit.preparation.sourceMedia[id], let reviewed = edit.analysisAnnotations.scene(for: media),
           reviewed != report {
            if reviewed.scenes != report.scenes {
                refreshStaleScenes.insert(id)
                sceneRevision += 1
            }
            return
        }
        sourceSceneOverlays[id] = nil
        if let media = edit.preparation.sourceMedia[id], edit.analysisAnnotations.needsSceneReview(for: media) {
            refreshStaleScenes.insert(id)
        } else { refreshStaleScenes.remove(id) }
        sceneReports[id] = report
        viewNamesBySource[id] = Dictionary(uniqueKeysWithValues: report.views.compactMap { view in
            view.name.map { (view.view, $0) }
        })
        scenesBySource[id] = report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) }
        sceneRevision += 1
    }

    func stepScene(_ direction: Int) {
        guard direction != 0, canStepScenes else { return }
        let layoutTimes = segments.indices.flatMap { index in
            let clip = segments[index]
            return layoutSceneTimes(for: clip).filter { $0 >= clip.start && $0 < clip.end }.map {
                clip.sequenceSeconds(at: $0, offset: edit.offsets[index])
            }
        }
        let possible = layoutTimes.filter { direction > 0 ? $0 > playhead + 1e-9 : $0 < playhead - 1e-9 }
        let layout = direction > 0 ? possible.min() : possible.max()
        let visual = steppedVisualSceneTime(direction)
        if let layout, let visual {
            seek(direction > 0 ? min(layout, visual) : max(layout, visual))
        } else if let at = layout ?? visual {
            seek(at)
        }
    }

    private func steppedVisualSceneTime(_ direction: Int) -> Double? {
        let indices = direction > 0 ? Array(segments.indices) : Array(segments.indices.reversed())
        let coversSequence = segments.allSatisfy { sceneReport(for: $0) != nil }
        for i in indices {
            let clip = segments[i], offset = edit.offsets[i].seconds
            guard let report = sceneReport(for: clip) else { continue }
            let end = offset + clip.duration.seconds
            if direction > 0 && end <= playhead + 1e-9 { continue }
            if direction < 0 && offset >= playhead - 1e-9 { continue }
            let local = clip.start.seconds + playhead - offset
            if direction > 0, coversSequence, offset > playhead + 1e-9 { return offset }
            let scenes = report.scenes.dropFirst(report.syntheticLeading ? 1 : 0)
            if direction > 0 {
                let index = scenes.lowerBound { $0.startSeconds > local + 1e-9 && $0.start >= clip.start }
                if index < scenes.endIndex, scenes[index].start < clip.end {
                    return offset + scenes[index].startSeconds - clip.start.seconds
                }
            } else {
                let index = scenes.lowerBound { $0.startSeconds >= min(local - 1e-9, clip.end.seconds) } - 1
                if index >= scenes.startIndex, scenes[index].start >= clip.start {
                    return offset + scenes[index].startSeconds - clip.start.seconds
                }
                if coversSequence { return offset }
            }
        }
        return nil
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
            guard let media = segment.source.media, mediaReviewIssue(segment) == nil else { continue }
            if !media.hasVideo {
                guard !keyframes else { return }
                let cut: RationalTime
                if direction > 0 && local < segment.start.seconds { cut = segment.start }
                else { cut = media.steppingAudioBoundary(from: min(local, segment.end.seconds), direction: direction) }
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
        if let (_, start) = stillInsert(at: time.seconds) { return time > start }
        let index = edit.offsets.lowerBound { $0 >= time }
        return index == edit.offsets.count || edit.offsets[index] != time
    }

    func splitSelectedRange() {
        guard canSplitSelectedRange, let span = selectedSpan else { return }
        if hasInlineStills {
            editStill(action: "Split Selected Range") {
                var project = stillProject
                // Cutting the later edge first keeps the original ID on the left for the earlier edge.
                for edge in [span.to, span.from] where isInsideClip(edge) {
                    if let (card, start) = stillInsert(at: edge.seconds) {
                        project = try project.splittingStill(id: card.id, at: edge.subtracting(start))
                    } else if let (_, clip, start) = locatedSegment(at: edge.seconds) {
                        project = try project.splittingSequenceClip(id: clip.documentID, at: clip.start.adding(edge.subtracting(start)))
                    }
                }
                return project
            }
            return
        }
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
        clearRangeMarks()
    }

    private func clearRangeMarks() {
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
            if time == offset.seconds { return time }
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
        if let issue = mediaReviewIssue(segment) {
            if let completion { completion(.failure(CutError(code: "source_needs_review", message: issue))) }
            else { fail(issue) }
            return
        }
        guard let media = segment.source.media else { return }
        let candidates: [RationalTime]
        switch targetMode {
        case .off: candidates = media.hasVideo ? segment.source.frames :
            [media.audioEditBoundary(near: target)]
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
        let validateJoins = edit.preparation.unavailableSourceIDs.isEmpty
        let perform: @Sendable (CutEngine) -> SplitSearch = { engine in
            var result = SplitSearch()
            for boundary in Self.nearestBoundaries(in: candidates, to: target, after: segment.start, before: segment.end) {
                var proposed = original
                let halves = segment.split(at: boundary, rightID: rightID)
                proposed[index] = halves.left
                proposed.insert(halves.right, at: index + 1)
                if targetMode == .keyframes, validateJoins, let error = Self.copyIssue(proposed, container: container, engine: engine) {
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
            if let issue = mediaReviewIssue(segment) {
                if let completion { completion(.failure(CutError(code: "source_needs_review", message: issue))) }
                else { fail(issue) }
                return
            }
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
                let result = await sidecarWork.detached(priority: .userInitiated) {
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
        if let card = edit.inlineStillsByID[id] {
            guard edge == .end else { return nil }
            return resizeStillEnd(card, duration: sourceTime, commit: commit)
        }
        return asking(true) { trim(id, edge: edge, sourceTime: sourceTime, commit: commit, snap: effectiveSnapTarget) }
    }

    private func resizeStillEnd(_ card: InlineStill, duration: Double, commit: Bool) -> Double? {
        guard canEdit, duration.isFinite else { return nil }
        let cadence = card.insert.cadence
        let exact: RationalTime
        if let soundtrack = edit.stillSequence?.stillSoundtrack,
           let remaining = try? soundtrack.to.subtracting(soundtrack.from).subtracting(card.start),
           remaining > .zero, abs(duration - remaining.seconds) <= cadence.seconds / 2 {
            exact = remaining
        } else {
            let frames = max(1, (duration / cadence.seconds).rounded())
            guard frames <= Double(Int32.max),
                  let rounded = try? cadence.multiplied(by: RationalTime(numerator: Int64(frames))) else { return nil }
            exact = rounded
        }
        guard commit, exact != card.insert.duration else { return exact.seconds }
        do {
            let project = try stillProject.resizingStill(id: card.insert.id, duration: exact)
            try applyStillProjectByHand(project, action: "Change Still Duration")
            return exact.seconds
        } catch {
            showStillError(error)
            return nil
        }
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
        if let clip = segments.first(where: { $0.id == id }), let issue = mediaReviewIssue(clip) {
            throw CutError(code: "source_needs_review", message: issue)
        }
        guard usesBackgroundTrimValidation,
              let index = segments.firstIndex(where: { $0.id == id }),
              let boundaries = copyBoundaries(for: segments[index].source) else {
            try check()
            return applyTrim()
        }
        let original = segments, revision = mcpRevision, generation = mcpGeneration
        let container = preferredCopyContainer
        let validateJoins = edit.preparation.unavailableSourceIDs.isEmpty
        let previewID = mcpTrimPreview
        let candidates = trimCandidates(at: index, edge: edge, boundaries: boundaries)
        let cached = checkingTrim?.0 == id && checkingTrim?.1 == edge ? trimChecks : [:]
        cancellation = token
        isCheckingEdit = true
        let worker = sidecarWork.detached(priority: .userInitiated) {
            Self.searchCopyTrim(segments: original, index: index, edge: edge, target: time,
                                options: candidates, container: container, validateJoins: validateJoins, cached: cached)
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
        if let issue = mediaReviewIssue(segment) {
            if commit { alert = EditorNotice(title: "Can’t Trim Clip", message: issue) }
            return nil
        }
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
                container: preferredCopyContainer, validateJoins: edit.preparation.unavailableSourceIDs.isEmpty, cached: trimChecks
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
            else if edge == .end && sourceTime >= segment.sourceExtent.seconds { cut = segment.sourceExtent }
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
                                 sourceDuration: segment.sourceExtent.seconds, reverse: backwards)
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
                                                   validateJoins: Bool, cached: [RationalTime: TrimCheck]) -> TrimSearch {
        let segment = segments[index]
        let candidates = nearestBoundaries(in: options, to: target, after: edge == .end ? segment.start : nil,
                                           before: edge == .start ? segment.end : nil)
        var result = TrimSearch()
        let engine = CutEngine(cancelled: { Task.isCancelled })
        for candidate in candidates {
            if Task.isCancelled { break }
            if !validateJoins { result.cut = candidate; break }
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
              mediaReviewIssue(segments[index]) == nil, let bounds = copyBoundaries(for: segments[index].source) else {
            completion(trim(id, edge: edge, sourceTime: target, commit: commit))
            return
        }
        let previous = trimValidation
        previous?.cancel()
        let request = UUID()
        trimValidationID = request
        let original = segments, container = preferredCopyContainer
        let validateJoins = edit.preparation.unavailableSourceIDs.isEmpty
        let options = trimCandidates(at: index, edge: edge, boundaries: bounds)
        let cached = checkingTrim?.0 == id && checkingTrim?.1 == edge ? trimChecks : [:]
        isCommittingHandle = commit
        if commit { isCheckingEdit = true }
        let work = sidecarWork
        trimValidation = Task { [weak self] in
            // Coalesce rapid drag events while an older native planner call winds down.
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = work.detached(priority: .userInitiated) {
                Self.searchCopyTrim(segments: original, index: index, edge: edge, target: target,
                                    options: options, container: container, validateJoins: validateJoins, cached: cached)
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
            let result = await sidecarWork.detached(priority: .userInitiated) {
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
                let pieces = ranges.enumerated().map { offset, range in
                    if offset > 0, range.from < ranges[offset - 1].to {
                        occurrence = UUID()
                    }
                    let displayFrom = range.from == scope.from ? clip.displayRange?.from ?? .zero : range.from
                    let displayTo = range.to == scope.to ? clip.displayRange?.to ?? clip.sourceExtent : range.to
                    var piece = EditorSegment(id: offset == 0 ? clip.id : UUID(), documentID: offset == 0 ? clip.documentID : nil,
                                         source: clip.source, start: range.from, end: range.to,
                                         displayRange: AudioSpan(from: displayFrom, to: displayTo), occurrence: occurrence,
                                         tileLayouts: clip.tileLayouts.compactMap {
                                             $0.limited(from: range.from == clip.start ? nil : range.from,
                                                        to: range.to == clip.end ? nil : range.to)
                                         })
                    piece.copiedReviewFrom = clip.documentID
                    return piece
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
                completion?(.success(mcpRevision))
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
        if let placementID = edit.inlineStillsByID[id]?.insert.id {
            editStill(action: "Delete Still") { try stillProject.removingStill(id: placementID) }
            return
        }
        guard canEdit, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        var proposed = segments
        proposed.remove(at: index)
        validate(proposed, selecting: proposed.indices.contains(index) ? proposed[index].id : proposed.last?.id,
                 at: edit.offsets[index].seconds, action: "Delete Clip")
    }

    var projectHistory: [ProjectHistoryAction] {
        func action(_ entry: HistoryEntry) -> ProjectHistoryAction {
            ProjectHistoryAction(name: entry.action, origin: entry.origin)
        }
        return undoStack.map(action) + redoStack.reversed().map(action)
    }
    var historyActions: [String] { projectHistory.map(\.name) }
    var historyEntryIDs: [UUID] { undoStack.map(\.id) + redoStack.reversed().map(\.id) }
    var historyCursor: Int { undoStack.count }

    func retainedTimeline(at index: Int) -> CutProject? {
        guard (0...(undoStack.count + redoStack.count)).contains(index) else { return nil }
        if index == historyCursor { return transcriptProject }
        if index < historyCursor { return undoStack[index].project }
        return redoStack[redoStack.count - (index - historyCursor)].project
    }

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
                                  copyContainer: explicitCopyContainer, transcriptState: transcriptState, audioMonitoring: audioMonitoring)
        var bindingChanges: [[TranscriptBindingChange]] = []
        for _ in 0..<abs(historyCursor - index) {
            let step = from.removeLast()
            bindingChanges.append(step.bindingChanges)
            to.append(HistoryEntry(id: step.id, action: step.action, origin: step.origin, contents: target.contents,
                                   copyContainer: target.copyContainer, transcriptState: target.project.transcripts,
                                   audioMonitoring: step.audioMonitoring == nil ? nil : target.audioMonitoring,
                                   bindingChanges: step.bindingChanges.map(\.reversed)))
            let monitoring = step.audioMonitoring ?? target.audioMonitoring
            let container = step.clipCount == 0 ? nil : target.copyContainer ?? step.copyContainer
            target = step
            target.audioMonitoring = monitoring
            target.copyContainer = container
        }
        let authoring = target.project.transcripts.authoring
        let changesAuthoring = transcriptState.authoring != authoring
        var checkedTranscripts = transcriptState
        func applyBindings(to transcripts: inout ProjectTranscripts) -> Bool {
            bindingChanges.reduce(false) { changed, transitions in
                TranscriptBindingChange.apply(transitions, to: &transcripts) || changed
            }
        }
        let changesBindings = applyBindings(to: &checkedTranscripts)
        func restoreTranscripts() throws {
            // An attachment may finish while an older timeline snapshot indexes.
            var restored = transcriptState
            let changesBindings = applyBindings(to: &restored)
            guard restored.authoring != authoring || changesBindings else { return }
            restored.revision = transcriptState.revision
            try restored.advanceRevision()
            restored.authoring = authoring
            transcriptState = restored
            rebuildPausePlan()
        }
        if changesAuthoring || changesBindings, transcriptState.revision == .max {
            fail(CutError(code: "invalid_transcript_state", message: "The transcript revision counter is exhausted."))
            return
        }
        let finish = {
            do { try restoreTranscripts() } catch { fail(error) }
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
        var targetTimeline = target.project
        targetTimeline.transcripts = .init()
        if changesAuthoring || changesBindings, targetTimeline == stillProject, explicitCopyContainer == target.copyContainer,
           target.audioMonitoring == nil || audioMonitoring == target.audioMonitoring {
            do { try beforeRestore?() } catch { fail(error); return }
            finish()
            completion?(.success(()))
            return
        }
        if case .live(let state) = target.contents,
           state.segments.allSatisfy({ canReuseUnresolved($0.source) }),
           state.preparation.sourceMedia.values.allSatisfy({ media in
               let status = mediaStatus(for: media.url)
               return status == .checking || status == .offline || status == .ignored || Self.currentSource(media)
           }) {
            do { try beforeRestore?() } catch { fail(error); return }
            let sources = Set(state.preparation.sourceMedia.values.map(\.url))
            if !sources.isSubset(of: lastSidecarCandidates) { refreshSidecarExclusions(adding: Array(sources)) }
            copyBoundaryIndices.removeAll()
            explicitCopyContainer = target.copyContainer
            mcpRevision += 1
            edit = state
            edit.preparation = preparedForMediaAvailability(state.segments, using: state.preparation)
            restoreAnalysisAnnotations()
            let segmentsByID = Dictionary(uniqueKeysWithValues: state.segments.map { ($0.id, $0) })
            var clips = state.timelineClips
            for index in clips.indices {
                if let segment = segmentsByID[clips[index].id] {
                    applyMediaPresentation(segment, to: &clips[index])
                }
            }
            edit.timelineClips = clips
            mediaClipReview = Dictionary(uniqueKeysWithValues: clips.compactMap { clip in
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
                importFiles(clips.map { URL(fileURLWithPath: $0.file, isDirectory: false) }, projectClips: clips, beforeInstall: {
                    try beforeRestore?()
                    guard self.historyEntryIDs == originalHistory, self.historyCursor == originalCursor else {
                        if completion == nil { return false }
                        throw CutError(code: "stale_history", message: "The history changed while preparing this state.")
                    }
                    return true
                }, requestCancellation: requestCancellation, installed: finish,
                            restoringAudioMonitoring: target.audioMonitoring, sequenceProject: target.project, completion: completion)
            }
        }
    }

    private static func currentSource(_ media: MediaInfo) -> Bool {
        media.identity.isCurrentSnapshot(at: media.url)
    }

    private func canReuseUnresolved(_ source: EditorSource) -> Bool {
        guard source.unresolved != nil else { return true }
        let status = mediaWatcher?.status(for: source.url)
        return status == .offline || status == .checking
    }

    /// Reuse the indexed media already on the timeline when walking through saved trims or rearrangements.
    private func cachedSegments(for clips: [CutSequenceClip]) -> [EditorSegment]? {
        var sources: [DocumentSourceKey: EditorSource] = [:]
        for segment in segments {
            let source = segment.source
            sources[DocumentSourceKey(file: source.url, original: source.originalURL, track: source.replacementTrack,
                                      names: source.replacementNames)] = source
        }
        var checked: Set<UUID> = []
        var restored: [EditorSegment] = []
        for clip in clips {
            let file = URL(fileURLWithPath: clip.file, isDirectory: false)
            let original = clip.originalFile.map { URL(fileURLWithPath: $0, isDirectory: false) } ?? file
            let key = DocumentSourceKey(file: file, original: original,
                                        track: clip.audioTrack, names: clip.replacementNames)
            guard let source = sources[key], canReuseUnresolved(source) else { return nil }
            if let indexed = source.indexed {
                guard clip.to <= indexed.duration else { return nil }
                let status = mediaStatus(for: source.url)
                if status != .offline, status != .checking, status != .ignored,
                   checked.insert(source.id).inserted, !Self.currentSource(indexed.media) { return nil }
            }
            restored.append(EditorSegment(documentID: clip.id, source: source, start: clip.from, end: clip.to, tileLayouts: clip.tileLayouts))
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
    var canReviseQueuedRange: Bool { !isBusyOutsideQueue && !isEmpty && alert == nil && selectedSpan != nil }
    var canShowBulkQueue: Bool { !isBusy && alert == nil && (!isEmpty || !queuedRanges.isEmpty) }

    func addMarkedRange() {
        guard canAddMarkedRange else { return }
        do {
            let entry = try captureMarkedQueueRange()
            queuedRanges.append(entry)
            clearMarks()
            statusMessage = "Added range \(queuedRanges.count) to the export queue."
        } catch {
            alert = EditorNotice(title: "Can’t Queue Range", message: error.localizedDescription)
        }
    }

    private func captureMarkedQueueRange() throws -> QueuedRange {
        guard canReviseQueuedRange, let span = selectedSpan else { throw QueueEdit.noSelection }
        return try captureQueueRange(span)
    }

    private func captureQueueRange(_ span: AudioSpan) throws -> QueuedRange {
        let selection = pieces(in: span)
        if let issue = selection.lazy.compactMap({ self.mediaReviewIssue($0) }).first {
            throw CutError(code: "source_needs_review", message: issue)
        }
        if stillProject.requiresPictureProcessing {
            let project = stillProject
            var media = Self.mediaByURL(selection)
            let soundtrack = project.stillSoundtrack
            if let soundtrack {
                let info = try indexedSoundtrack(for: soundtrack)
                media[info.url] = info
            }
            if let reference = project.stillAudioReference,
               let info = Self.tierInput(segments).media[URL(fileURLWithPath: reference.file).standardizedFileURL] {
                media[info.url] = info
            }
            return QueuedRange(start: span.from, end: span.to, clips: selection.map(\.request),
                               media: media, pictureProject: project, pictureDocument: projectURL)
        }
        if case .stillSequence = stillProject {
            let project = try stillProjectForRange(span)
            let scope = try project.exportPlacementScope()
            if scope != .none {
                let clips = (project.sequenceClips ?? []).map {
                    ClipRequest(file: URL(fileURLWithPath: $0.file), from: $0.from, to: $0.to)
                }
                var files = Set(clips.map(\.file))
                if let reference = project.stillAudioReference {
                    files.insert(URL(fileURLWithPath: reference.file).standardizedFileURL)
                }
                var media = Self.tierInput(segments).media.filter { files.contains($0.key) }
                if let soundtrack = stillProject.stillSoundtrack,
                   (project.stillSoundtrack ?? project.stillAudioReference)?.file == soundtrack.file {
                    let info = try indexedSoundtrack(for: soundtrack)
                    media[info.url] = info
                }
                return QueuedRange(start: span.from, end: span.to, clips: clips,
                                   media: media, stillProject: project, placements: scope,
                                   pictureTiming: stillProject.stillSoundtrack == nil ? nil : .held)
            }
        }
        guard !selection.isEmpty else { throw QueueEdit.noSelection }
        let media = Self.mediaByURL(selection)
        return QueuedRange(start: span.from, end: span.to, clips: selection.map(\.request), media: media)
    }

    func renameQueuedRange(_ id: UUID, to name: String) throws {
        guard !isBusyOutsideQueue else { throw QueueEdit.busy }
        guard let index = queuedRanges.firstIndex(where: { $0.id == id }) else { throw QueueEdit.invalidTarget }
        let name = try QueueEdit.name(name)
        var entry = queuedRanges[index]
        entry.customName = name
        entry.excerpt?.name = name
        entry.contentID = UUID()
        queuedRanges[index] = entry
    }

    func reviseQueuedRange(_ id: UUID, extending: Bool) throws {
        guard !isBusyOutsideQueue else { throw QueueEdit.busy }
        guard let index = queuedRanges.firstIndex(where: { $0.id == id }) else { throw QueueEdit.invalidTarget }
        let original = queuedRanges[index]
        var entry = try captureMarkedQueueRange()
        try checkQueueDependencies(entry.mediaDependencies, status: mediaStatus)
        if extending {
            try QueueEdit.checkExtension(from: original.start, to: original.end, into: entry.start, through: entry.end)
        }
        entry.id = original.id
        entry.customName = original.name
        if let excerpt = original.excerpt {
            let selection = AudioSpan(from: entry.start, to: entry.end)
            var snapshot: CutProject
            if case .stillSequence = stillProject {
                snapshot = try stillProjectForRange(selection)
            } else {
                snapshot = .sequence(sequenceClips(for: pieces(in: selection)))
            }
            var participants = snapshot.participants
            if var render = participants.render {
                render.shots = try render.shots.compactMap { authored in
                    guard authored.clock == .output, let range = authored.range else { return authored }
                    let from = max(range.from, entry.start)
                    let to = min(range.to, entry.end)
                    guard from < to else { return nil }
                    var shot = authored
                    shot.range = try .init(from: from.subtracting(entry.start), to: to.subtracting(entry.start))
                    return shot
                }
                participants.render = render
                snapshot.participants = participants
            }
            snapshot.transcripts = transcriptState
            entry.excerpt = try TranscriptQueueExcerpt(name: excerpt.name, project: snapshot, location: transcriptAssetContext(),
                                                       mediaSnapshot: projectMediaSnapshotForWriting)
        }
        queuedRanges[index] = entry
        invalidatedQueueIDs.remove(id)
        clearRangeMarks()
        statusMessage = "Updated the queued range."
    }

    func replanQueuedRange(_ id: UUID) throws {
        guard !isBusyOutsideQueue else { throw QueueEdit.busy }
        guard invalidatedQueueIDs.contains(id),
              let index = queuedRanges.firstIndex(where: { $0.id == id }) else { throw QueueEdit.invalidTarget }
        let original = queuedRanges[index]
        if original.excerpt != nil {
            guard self.canReviseQueuedRange else { throw QueueEdit.replanExcerpt }
            try reviseQueuedRange(id, extending: false)
            return
        }
        guard original.start >= .zero, original.start < original.end, original.end <= edit.duration else {
            throw QueueEdit.replanBounds
        }
        var entry = try captureQueueRange(AudioSpan(from: original.start, to: original.end))
        try checkQueueDependencies(entry.mediaDependencies, status: mediaStatus)
        entry.id = id
        entry.customName = original.name
        queuedRanges[index] = entry
        invalidatedQueueIDs.remove(id)
        statusMessage = "Replanned the queued range."
    }

    func removeQueuedRange(_ id: UUID) {
        guard !isExporting else { return }
        queuedRanges.removeAll { $0.id == id }
        invalidatedQueueIDs.remove(id)
    }

    func showBulkQueue() {
        guard canShowBulkQueue else { return }
        preview.pause()
        isBulkQueuePresented = true
    }

    func bulkQueueDismissed() { resumePendingWork() }

    func chooseBulkDestination(options: ExportSheetOptions, summary: String? = nil) {
        guard isBulkQueuePresented, !readyQueuedRanges.isEmpty else { return }
        let contentIDs = readyQueuedRanges.map(\.contentID)
        let panel = NSOpenPanel()
        panel.title = "Export Queued Ranges"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportPanelDirectory(source: readyQueuedRanges.first?.clips.first?.file)
        if let summary {
            panel.accessoryView = multicamDeliveryAccessory(summary)
            panel.isAccessoryViewDisclosed = true
        }
        let currentSession = session
        ProjectPanels.present(panel, in: sheetWindow, fromSheet: true) { [weak self] accepted in
            guard let self, self.session == currentSession, accepted, let directory = panel.url,
                  self.readyQueuedRanges.map(\.contentID) == contentIDs else { return }
            self.exportQueuedRanges(to: directory, options: options)
        }
    }

    func exportQueuedRanges(to directory: URL, options: ExportSheetOptions) {
        let ranges = readyQueuedRanges
        guard isBulkQueuePresented, !ranges.isEmpty else { return }
        exportDirectory = directory
        isBulkQueuePresented = false
        let protected = protectedMedia
        let useSidecar = useAnalysisSidecars
        runExport { token, progress in
            try options.organization.validateSubfolder(in: directory, protectedMedia: protected)
            let batch = try SequenceQueuePlan(ranges, directory: directory, options: options,
                                              useSidecar: useSidecar, cancelled: { token.isCancelled })
            for item in batch.items { try CutProject.validateMediaDestination(item.output, absoluteSources: protected) }
            // What each range's Smart Trim edges cost, taken right after that range's write.
            var written: [(output: URL, edges: [EncodedEdgeResult])] = []
            // What writing each range changed that its plan could not show, under its file name.
            var writtenNotices: [String] = []
            for (index, item) in batch.items.enumerated() {
                do {
                    let (edges, notices) = try ExportWriteNotices.collecting {
                        try batch.writeReportingEdges(item) { progress((Double(index) + $0) / Double(batch.items.count)) }
                    }
                    written.append((item.output, edges))
                    writtenNotices += notices.map { "\(item.output.lastPathComponent) — \($0)" }
                } catch {
                    throw CutError(code: "bulk_interrupted", message: "Wrote \(index) of \(ranges.count) files. "
                                   + "Range \(index + 1): \(error.localizedDescription)")
                }
            }
            let count = ranges.count == 1 ? "1 file" : "\(ranges.count) files"
            let notices = batch.items.flatMap { item -> [String] in
                guard case .picture(let plan) = item.payload else { return [] }
                return ([plan.report.picturePrivacyNotice].compactMap { $0 } + (plan.report.warnings ?? []))
                    .map { "\(item.output.lastPathComponent) — \($0)" }
            }
            let edges = ExportNotices.queueEncodedEdges(written)
            let message = (["Exported \(count) to \(batch.folder.lastPathComponent)."] + notices + edges + writtenNotices)
                .joined(separator: " ")
            return (batch.folder, message)
        }
    }

    private func stillReviewSegment(_ documentID: String) throws -> EditorSegment {
        guard let clip = segments.first(where: { $0.documentID == documentID }) else {
            throw MCPCommandError("invalid_target", "Choose an existing clip occurrence.")
        }
        return clip
    }

    func stillReviewOccurrenceID(_ documentID: String) throws -> UUID {
        try stillReviewSegment(documentID).id
    }

    func stillReviewOccurrence(_ documentID: String) throws -> (id: UUID, source: UUID, media: MediaInfo) {
        let clip = try stillReviewSegment(documentID)
        if let issue = mediaReviewIssue(clip) { throw MCPCommandError("source_needs_review", issue) }
        guard let media = clip.source.media else { throw MCPCommandError("source_needs_review", "Recording is offline.") }
        return (clip.id, clip.source.id, media)
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
        segments.lazy.compactMap({ $0.source.media }).first(where: \.hasVideo)
    }

    func participantMedia(displaying picture: SequenceSourcePicture) -> MediaInfo? {
        let clip: EditorSegment
        if let (id, _, _) = trimAudition, let auditioned = segments.first(where: { $0.id == id }) {
            clip = auditioned
        } else if let (_, active, _) = locatedSegment(at: playhead) {
            clip = active
        } else if playhead == duration, let last = segments.last {
            clip = last
        } else {
            return nil
        }
        guard let media = clip.source.media, media.url == picture.url, media.hasVideo,
              picture.identity?.matchesSnapshot(media.identity) != false, mediaReviewIssue(clip) == nil else { return nil }
        return media
    }

    var jpegSourceAtPlayhead: EditorJPEGSource? {
        guard !segments.isEmpty else { return nil }
        let clip: EditorSegment
        let picture: RationalTime?
        if let (id, edge, cut) = trimAudition, let auditioned = segments.first(where: { $0.id == id }) {
            clip = auditioned
            guard let media = clip.source.media, media.hasVideo, mediaReviewIssue(clip) == nil else { return nil }
            picture = try? JPEGExport.stillFrameTime(in: media, at: cut, exclusiveEnd: edge == .end)
        } else if let (_, active, offset) = locatedSegment(at: playhead) {
            clip = active
            guard let media = clip.source.media, media.hasVideo, mediaReviewIssue(clip) == nil else { return nil }
            let frames = media.frames
            // Translate timestamps before comparing them to the display playhead. Rounding
            // a source-time Double after subtraction can move it across a frame boundary.
            func sequenceTime(_ sourceTime: RationalTime) -> Double {
                if let delta = try? sourceTime.subtracting(clip.start),
                   let exact = try? offset.adding(delta) { return exact.seconds }
                return offset.seconds + (sourceTime.seconds - clip.start.seconds)
            }
            let index = frames.lowerBound { $0.time >= clip.end || sequenceTime($0.time) > playhead } - 1
            if frames.indices.contains(index), let frameEnd = try? frames[index].time.adding(frames[index].duration),
               playhead < sequenceTime(frameEnd) {
                picture = max(.zero, frames[index].time)
            } else {
                picture = nil
            }
        } else {
            guard playhead == duration, let last = segments.last, let media = last.source.media,
                  media.hasVideo, mediaReviewIssue(last) == nil else { return nil }
            clip = last
            picture = try? JPEGExport.stillFrameTime(in: media, at: last.end, exclusiveEnd: true)
        }
        guard let media = clip.source.media else { return nil }
        let tracks = media.streams.filter { $0.kind == "audio" }
        return EditorJPEGSource(id: clip.source.id, media: media, frame: picture, scenes: sceneReports[clip.source.id],
                                audioStream: sourceAnalysisTracks[clip.source.id].map { tracks[$0].index },
                                pauses: sourcePauses[clip.source.id], manualThreshold: manualThresholdDB,
                                effectiveThreshold: effectiveThresholdDB, minimumPause: minimumPause, maxBlip: preferences.maxBlip)
    }

    func chooseStillFrame() {
        guard canEdit else { return }
        if stillProject.requiresPictureProcessing {
            chooseOutputFrame(directory: false)
            return
        }
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
        let panel = options.panel(source: sourceURL, directory: exportPanelDirectory(source: camera?.media.url ?? sourceURL))
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
        if stillProject.requiresPictureProcessing {
            chooseOutputFrame(directory: true)
            return
        }
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
        let panel = options.panel(source: sourceURL, directory: exportPanelDirectory(source: source?.media.url ?? sourceURL),
                                  hasAudio: source?.audioStream != nil,
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

    private func chooseOutputFrame(directory: Bool) {
        let project = stillProject, document = projectURL
        let revision = mcpRevision, currentSession = session
        preview.pause()
        do {
            let time = stillReviewTime(in: try project.resolveStills())
            let source = document ?? segments.first?.source.url ?? URL(fileURLWithPath: "Output")
            let stillOptions = StillFrameSaveOptions()
            let jpegOptions = JPEGExportOptions(preset: preferences.jpegPreset)
            let start = exportPanelDirectory(source: segments.first?.source.url)
            let panel: NSSavePanel = directory
                ? jpegOptions.panel(source: source, directory: start, hasAudio: false, hasAnalysisSource: false)
                : stillOptions.panel(source: source, directory: start)
            isPresentingPanel = true
            present(panel) { [weak self] accepted in
                guard let self, self.session == currentSession else { return }
                self.isPresentingPanel = false
                guard accepted, let output = panel.url, self.mcpRevision == revision else { self.resumePendingWork(); return }
                do {
                    try self.validateHistoryDestination(output, includesContents: directory)
                    self.exportDirectory = output.deletingLastPathComponent()
                    let replacing = directory ? nil : stillOptions.confirmedDestination(at: output)
                    let preset = directory ? jpegOptions.preset : .full
                    self.runExport { token, _ in
                        let cancelled: @Sendable () -> Bool = { token.isCancelled }
                        let renderer = try ProjectOutputJPEG(project, document: document, cancelled: cancelled)
                        let issues = try directory
                            ? renderer.writeDirectory(at: [time], to: output, preset: preset)
                            : renderer.writeStill(at: time, to: output, replacing: replacing, preset: preset).privacyIssues
                        let summary = issues.isEmpty ? "" : " Privacy coverage applied at \(time)."
                        return (output, "Exported \(output.lastPathComponent)." + summary)
                    }
                } catch { self.showStillError(error) }
            }
        } catch { showStillError(error) }
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
        guard let index = selectedClipIndex, mediaReviewIssue(segments[index]) == nil,
              let source = segments[index].source.indexed else { return nil }
        return source.media.streams.contains { $0.kind == "audio" } ? source : nil
    }

    var canReplaceSourceAudio: Bool { canEdit && replacementSource != nil }

    func chooseReplacementAudio() {
        guard let source = replacementSource else { return }
        chooseReplacementAudio(for: source)
    }

    func chooseReplacementAudio(forClip id: UUID) {
        guard canEdit, let clip = segments.first(where: { $0.id == id }), mediaReviewIssue(clip) == nil,
              let source = clip.source.indexed else { return }
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
            let inspection = await sidecarWork.detached(priority: .userInitiated) {
                Result { try CutEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar && !AnalysisSidecar.isExcluded(replacement, in: excluded)).inspectSummary(replacement) }
            }.value
            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            do {
                let control = try ReplacementExportPanel(source: source.media, replacement: inspection.get(),
                                                         sourceName: source.name, preferredTrack: monitoredAudioOrdinal(for: .resolved(source)) ?? 0, useSidecar: useSidecar, excludedSources: excluded)
                let panel = NSSavePanel()
                panel.title = "Apply Replacement Audio"
                panel.message = "Save a lossless copy with the new audio. Every cut of this source will use it."
                panel.prompt = "Save and Apply"
                panel.directoryURL = exportPanelDirectory(source: source.url)
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
                    if choice.dontAskAgain { self.preferences.suppress(.exportTierDowngrade) }
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
        guard let source = segments.lazy.compactMap({ $0.source.indexed }).first(where: {
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
        let awake = SleepPrevention(reason: "Saving a working copy in MPCut", provider: exportActivityProvider)
        exportTasks[currentSession] = Task {
            defer {
                awake.end()
                exportTasks.removeValue(forKey: currentSession)
            }
            let exported = await sidecarWork.detached(priority: .userInitiated) {
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
                result = await sidecarWork.detached(priority: .userInitiated) { [sidecarPreference] in
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
                        return IndexedSource(media: sidecarPreference.attachingDocument(to: media), originalURL: source.originalURL,
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
                                         displayRange: clip.displayRange, occurrence: clip.occurrence, tileLayouts: clip.tileLayouts)
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
        let project = transcriptProject
        let clips = segments.map(\.request)
        let imported = interchangeIndexedMedia
        let location = projectURL
        let name = clips.first?.file.deletingPathExtension().lastPathComponent ?? "Untitled"
        let start = exportPanelDirectory(source: clips.first?.file, hasAutomaticRule: false)
        ResolveExportPanel.choose(name: name, directory: start, opensTimeline: preferences.opensResolveTimeline,
                                  in: editorWindow) { output, open in
            guard self.canExport(to: output) else { return }
            self.noteExportFolder(output.deletingLastPathComponent(), hasAutomaticRule: false)
            let checkingVolumes = self.interchangeCheckingVolumes
            self.runExport { token, _ in
                // What the timeline gives up in FCPXML: rounded cuts, replaced name characters, narrowed sound.
                let warnings = try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                    try ResolveExport.write(project, relativeTo: location ?? output, to: output,
                                            matching: imported, cancelled: { token.isCancelled })
                }
                if open { try ResolveExport.openInResolve(output, cancelled: { token.isCancelled }) }
                return (output, (["Exported \(output.lastPathComponent)."] + warnings).joined(separator: " "))
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
        if stillProject.requiresPictureProcessing {
            if mode != nil && mode != .encode {
                alert = EditorNotice(title: "Export Tiles", message: ParticipantProjectExport.requiresEncoding.message)
            } else {
                let range = selectionOnly ? selectedSpan.map { MulticamRange(from: $0.from, to: $0.to) } : nil
                presentParticipantExport(stillProject, range: range)
            }
            return
        }
        if case .stillSequence = stillProject {
            do {
                let project = selectionOnly ? try stillProjectForSelection() : stillProject
                let scope = try project.exportPlacementScope()
                if scope != .none {
                    cancelTrim()
                    preview.pause()
                    let source = currentSoundtrackMedia ?? candidate.first?.source.media ?? segments.lazy.compactMap({ $0.source.media }).first
                    var options = sheetExportOptions
                    options.placements = scope
                    options.tracks = .all
                    options.mode = mode ?? ExportRules.defaultStillMode(tracks: options.tracks, placements: scope, otherwise: defaultExportMode)
                    if stillProject.stillSoundtrack != nil || project.stillInserts.contains(where: \.usesExactDuration) {
                        options.pictureTiming = options.pictureTiming ?? .held
                    }
                    if project.stillSoundtrack != nil || project.stillAudioReference?.audioTrack != nil {
                        options.audio = .auto
                    } else if !ExportRules.stillMovieAudioActions.contains(options.audio) {
                        options.audio = .copyOriginal
                    }
                    options.audioMode = .copy
                    if project.stillSoundtrack != nil || project.stillAudioReference?.audioTrack != nil {
                        options.convertAudio(to: .alac, preferred: "m4a")
                    }
                    options.audioTrackOrdinal = nil
                    let preferred = project.stillFormat?.container ?? preferredCopyContainer
                    options.codec = project.stillFormat?.codec ?? options.codec
                    options.copyContainer = preferred.flatMap { ExportRules.stillMovieContainers.contains($0) ? $0 : nil } ?? "mov"
                    let encode = ExportRules.stillContainers(mode: .encode, tracks: .all, codec: options.codec, audio: options.audio)
                    if let format = project.stillFormat {
                        options.encodeContainer = format.container
                        options.proResContainer = format.container
                    }
                    if !encode.contains(options.encodeContainer) { options.encodeContainer = encode.first ?? "mov" }
                    if !encode.contains(options.proResContainer) { options.proResContainer = encode.first ?? "mov" }
                    let containers = ExportContainerChoices(stillSource: source, cancelled: { false })
                    presentExport(options: options, copyContainers: containers, candidate: candidate,
                                  useSidecar: useAnalysisSidecars, selectionOnly: selectionOnly, stillProject: project)
                    return
                }
            } catch { showStillError(error); return }
        }
        guard let source = candidate.first?.source.media else { return }
        cancelTrim()
        preview.pause()
        let currentSession = session
        let token = EditCancellation()
        cancellation = token
        isCheckingEdit = true
        let preferred = selectionOnly
            ? explicitCopyContainer ?? CutEngine().suggestedContainers(for: source).first
            : preferredCopyContainer
        let excluded = sidecarExclusions
        let useSidecar = useAnalysisSidecars
        // The whole timeline opens on the preferred mode unless its tier is lower, then on the tier's mode.
        // A selection is not the timeline, and a tier that is still being checked decides nothing.
        let opening = selectionOnly
            ? mode ?? ExportRules.openingMode(preferred: defaultExportMode, tier: nil, source: source.hasVideo ? .movie : .audio)
            : openingExportMode(mode)
        let media = Self.mediaByURL(candidate)
        Task {
            let (choices, verified) = await sidecarWork.detached(priority: .userInitiated) {
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
            let options = Self.openingExportOptions(self.sheetExportOptions, mode: opening, convertingByName: mode == .encode, source: source,
                                                    choices: choices, preferred: preferred, verified: verified)
            presentExport(options: options, copyContainers: choices, candidate: candidate, useSidecar: useSidecar, selectionOnly: selectionOnly)
        }
    }

    private func presentParticipantExport(_ project: CutProject, range: MulticamRange?) {
        let document = projectURL
        let panel = NSSavePanel()
        panel.title = "Export Program"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = exportPanelDirectory(source: segments.first?.source.url)
        let stem = segments.first?.source.url.deletingPathExtension().lastPathComponent ?? "Participants"
        panel.nameFieldStringValue = "\(stem) Edit.mov"
        let tracksControl = ParticipantExportTracksControl(panel: panel, allowsAudioOnly: project.participants.render == nil)
        let currentSession = session
        isPresentingPanel = true
        present(panel) { [weak self] accepted in
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            guard accepted, let output = panel.url, self.canExport(to: output) else {
                self.resumePendingWork()
                return
            }
            self.exportDirectory = output.deletingLastPathComponent()
            let tracks = tracksControl.tracks
            self.runExport { token, progress in
                let cancelled: @Sendable () -> Bool = { token.isCancelled }
                let export = try Self.planParticipantExport(project, document: document, output: output,
                                                            tracks: tracks, range: range, cancelled: cancelled)
                try export.write(to: output, cancelled: cancelled, progress: progress)
                let message = (["Exported \(output.lastPathComponent)."] + export.notices).joined(separator: " ")
                return (output, message)
            }
        }
    }

    nonisolated static func planParticipantExport(_ project: CutProject, document: URL?, output: URL,
                                                   tracks: ExportTracks, range: MulticamRange?,
                                                   cancelled: @escaping @Sendable () -> Bool) throws -> ParticipantProjectExport {
        let codec = project.stillFormat?.codec ?? .h264
        func plan(_ codec: ReencodeCodec) throws -> ParticipantProjectExport {
            try ParticipantProjectExport(project, relativeTo: document, output: output, mode: .encode,
                tracks: tracks, settings: .init(codec: codec, audio: tracks == .audio ? .pcm : .auto),
                audioOutput: tracks == .audio ? .downmixStereo : .separateTracks, range: range, cancelled: cancelled)
        }
        var export: ParticipantProjectExport
        do { export = try plan(codec) }
        catch let issue as CutError where issue.code == "unsupported_format" && codec == .h264 && tracks != .audio {
            // H.264 cannot hold the composition's HDR picture. The export says so rather than switching quietly.
            export = try plan(.hevc)
            export.substitutions.append("H.264 cannot hold this HDR composition, so the picture is encoded in HEVC.")
        }
        if tracks == .audio, export.report.audioActions.contains(where: { ($0.sourceLaneIDs?.count ?? 0) > 1 }) {
            export.substitutions.append("Audio Only mixes the program's sound lanes to one stereo PCM track.")
        }
        return export
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
        panel.directoryURL = exportPanelDirectory(source: candidate.first?.source.url)
        panel.nameFieldStringValue = "\(stem) \(selectionOnly ? "Selection" : "Edit").\(options.container)"
        var media = Self.mediaByURL(candidate)
        if let reference = stillProject?.stillAudioReference,
           let source = segments.lazy.compactMap({ $0.source.indexed }).first(where: { $0.url.path == reference.file }) {
            media[source.url] = source.media
        }
        if let info = currentSoundtrackMedia,
           (stillProject?.stillSoundtrack ?? stillProject?.stillAudioReference)?.file == info.url.path {
            media[info.url] = info
        }
        let expectedSoundtrackIdentity = (stillProject?.stillSoundtrack).flatMap { try? self.expectedSoundtrackIdentity($0) }
        let currentSession = session
        var shownOptions = options
        let formatControl = ExportFormatControl(panel: panel, options: options, copyContainers: copyContainers,
                                               clips: candidate.map(\.request), media: media, useSidecar: useSidecar, excludedSources: sidecarExclusions,
                                               allowsApplyingReviewToTimeline: !selectionOnly, stillProject: stillProject,
                                               expectedSoundtrackIdentity: expectedSoundtrackIdentity,
                                               stillAudioIssue: { [weak self] tracks, audio in
            guard let stillProject else { return nil }
            return self?.stillSoundtrackExportIssue(in: stillProject, tracks: tracks, audio: audio)
        },
                                               savesExportResult: preferences.savesExportResult,
                                               changed: { [weak self] options, explicitCopyContainer in
            guard let self, self.session == currentSession else { return }
            if stillProject == nil {
                self.exportSheetChanged(options, from: shownOptions)
                if explicitCopyContainer && !selectionOnly { self.preferCopyContainer(options.copyContainer) }
            }
            shownOptions = options
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
                let saveResult = formatControl.savesExportResult
                guard self.canExport(to: output),
                      !saveResult || self.canExport(to: ExportResultFile.destination(beside: output)) else { return }
                self.exportDirectory = output.deletingLastPathComponent()
                self.runExport { token, progress in
                    let result = saveResult ? try ExportResultFile(output: output, plan: plan.report, cutMap: plan.report.cutMap) : nil
                    try StillExportPlanner(useSidecar: useSidecar, cancelled: { token.isCancelled })
                        .write(plan, to: output, progress: progress)
                    return (output, ExportResultFile.stillCompletionMessage(for: output, result: result))
                }
            } else if accepted, let output = panel.url, let plan = formatControl.selected {
                self.exportDirectory = output.deletingLastPathComponent()
                self.export(plan, to: output, clips: candidate, saveResult: formatControl.savesExportResult)
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
            EditorSegment(id: segment.id, documentID: segment.documentID, source: segment.source, start: range.from ?? segment.start, end: range.to ?? segment.sourceExtent, displayRange: segment.displayRange, occurrence: segment.occurrence, tileLayouts: segment.tileLayouts)
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
        var committed = committedBeforeImport ?? transcriptProject
        committed.transcripts = transcriptState
        defer { draft.relinquish() }
        guard draft.hasScheduledWrites || hasUnsavedDocumentChanges else { return }
        // Closing can bypass the document prompt while an import is showing a partial
        // batch. Only edits accepted before that batch belong to the recovery project.
        let writer = documentWriter(project: committed)
        do { try draft.write { _ = try writer($0) } }
        catch { reportDraftError(error) }
    }

    func endSession() {
        projectMediaJobs.reset()
        projectMediaRequest = nil
        projectMediaPicture = []
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
        mediaSnapshot = .init()
        mediaSnapshotChanged = false
        mediaRelinkCancellation?.cancel()
        mediaRelinkCancellation = nil
        mediaRelinkProgress = nil
        mediaRelinkIndexing.removeAll()
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
        soundtrackMediaByURL.removeAll()
        soundtrackIndexes.removeAll()
        savedAnalysisAnnotations = .init()
        savedParticipants = .init()
        stillTimelineIDs.removeAll()
        savedUndoIDs = []
        savedRedoIDs = []
        recoveredDraft = false
        deferredDraftSave = false
        draft.discard()
        cancelTrim()
        usesPointerPosition = false
        filmstripTiles = FilmstripTileBuffer()
        if !isFlushingDraftSidecars { sidecarSaveToken?.cancel() }
        isFlushingDraftSidecars = false
        sidecarSaveToken = nil
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
        pauseRetainedSeconds.removeAll()
        takeBoundaries.removeAll()
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
        automaticSceneScanSources.removeAll()
        automaticSilenceScanSources.removeAll()
        sceneReports.removeAll()
        scenesBySource.removeAll()
        viewNamesBySource.removeAll()
        cancellation?.cancel()
        cancellation = nil
        session = UUID()
        transcriptState = .init()
        savedTranscriptState = .init()
        undoStack.removeAll()
        redoStack.removeAll()
        unopenedConversionRedo.removeAll()
        pendingOpenFiles.removeAll()
        queuedRanges.removeAll()
        isBulkQueuePresented = false
        exportOptions = ExportSheetOptions()
        exportOptions.mode = defaultExportMode
        exportEncodingKept = []
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

    var timelineOutputRevision: TimelineOutputRevision? {
        guard stillProject.requiresPictureProcessing else { return nil }
        return TimelineOutputRevision(generation: mcpGeneration, edit: mcpRevision, document: projectURL)
    }

    private var timelineOutputRenderer: (TimelineOutputRevision, TimelineOutputThumbnailRenderer)?

    func outputThumbnail(at time: RationalTime, size: CGSize, revision: TimelineOutputRevision) async -> CGImage? {
        guard timelineOutputRevision == revision else { return nil }
        if timelineOutputRenderer?.0 != revision {
            timelineOutputRenderer = (revision, TimelineOutputThumbnailRenderer(project: stillProject, document: projectURL))
        }
        let image = try? await timelineOutputRenderer?.1.image(at: time, size: size)
        return timelineOutputRevision == revision && !Task.isCancelled ? image : nil
    }

    func thumbnail(for sourceID: UUID, at sourceTime: Double, size: CGSize) async -> CGImage? {
        guard timelineOutputRevision == nil else { return nil }
        let image = await sourceThumbnail(for: sourceID, at: sourceTime, size: size)
        return timelineOutputRevision == nil && !Task.isCancelled ? image : nil
    }

    private func sourceThumbnail(for sourceID: UUID, at sourceTime: Double, size: CGSize) async -> CGImage? {
        if let card = edit.inlineStillsByID[sourceID],
           let frame = try? stillProject.stillReviewFrame(placementID: card.insert.id,
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
        guard segments.contains(where: { $0.source.id == sourceID && !mediaStatus(for: $0.source.url).hidesMedia }) else { return nil }
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
        guard let media = edit.preparation.sourceMedia[sourceID], media.hasVideo else { return nil }
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
            let segment = segments[index]
            if let issue = mediaReviewIssue(segment) {
                alert = EditorNotice(title: "Can’t Delete Marked Range", message: issue)
                return nil
            }
            if edge == .end ? pointerLower : pointerUpper { return target }
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
                    let rightDisplay = AudioSpan(from: cut, to: max(segment.end, segment.displayRange?.to ?? segment.sourceExtent))
                    after.append(EditorSegment(source: segment.source, start: cut, end: segment.end,
                                               displayRange: rightDisplay, occurrence: segment.occurrence,
                                               tileLayouts: segment.tileLayouts.compactMap { $0.limited(from: cut, to: nil) }))
                    before[before.count - 1].tileLayouts = segment.tileLayouts.compactMap { $0.limited(from: nil, to: left.end) }
                } else {
                    var right = segment
                    right.start = cut
                    after.append(right)
                }
            }
        }
        let proposed = before + after
        if effectiveSnapTarget == .keyframes, !pointerLower, !pointerUpper, !proposed.isEmpty, proposed.allSatisfy({ mediaReviewIssue($0) == nil }), let error = copyIssue(proposed) {
            alert = EditorNotice(title: "Can’t Delete Marked Range", message: copyMessage(error, in: proposed))
            return
        }
        if hasInlineStills, let reconciled = reconciledStillProject(proposed) {
            do {
                let cards = inlineStills(in: stillProject)
                let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.insert.id, $0) })
                let destination = sequenceDuration(before) + cards.reduce(0.0) { sum, card in
                    sum + max(0, min(card.end, marked.lowerBound).seconds - card.start.seconds)
                }
                let candidate = try reconciled.editingStills(sequence: { sequence in
                    sequence.items = try sequence.items.compactMap { item in
                        guard var insert = item.still, let card = byID[insert.id] else { return item }
                        let lower = max(marked.lowerBound, card.start)
                        let upper = min(marked.upperBound, card.end)
                        guard lower < upper else { return item }
                        insert.duration = try insert.duration.subtracting(upper.subtracting(lower))
                        return insert.duration == .zero ? nil : .still(insert)
                    }
                    if proposed.isEmpty, sequence.stillFormat == nil,
                       let surviving = sequence.items.first?.still, let card = byID[surviving.id] {
                        let reference = try stillProjectForRange(.init(from: card.start, to: card.end))
                        sequence.stillFormat = reference.stillFormat
                        sequence.programColorPolicy = reference.programColorPolicy
                    }
                }, multicam: { _ in })
                try applyStillProjectByHand(candidate, action: "Delete Marked Range", landingAfterDeletion: destination)
            } catch { showStillError(error) }
            return
        }
        validate(proposed, selecting: after.first?.id ?? before.last?.id, at: sequenceDuration(before),
                 action: "Delete Marked Range")
    }

    private func isContinuousCopyRange(_ pieces: ArraySlice<EditorSegment>) -> Bool {
        if pieces.count == 1 { return true }
        guard let media = pieces.first?.source.media, let container = preferredCopyContainer,
              CutEngine().coalescesAdjacentRanges(in: media, container: container) else { return false }
        return zip(pieces, pieces.dropFirst()).allSatisfy {
            $0.source.id == $1.source.id && $0.end == $1.start
        }
    }

    private func trimCandidates(at index: Int, edge: TimelineEdge, boundaries: BoundaryIndex) -> [RationalTime] {
        let segment = segments[index]
        let first = index == 0
        let last = index == segments.count - 1
        guard let media = segment.source.media, let container = preferredCopyContainer,
              CutEngine().coalescesAdjacentRanges(in: media, container: container) else {
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
            !edit.preparation.unavailableSourceIDs.contains(id) && copyBoundaryIndices[id] == nil
                && media.hasFullEditIndex && media.indexStorageBytes >= PreparedEdit.backgroundCopyCheckBytes
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

    private func copyBoundaries(for source: EditorSource) -> BoundaryIndex? {
        guard let media = source.media else { return nil }
        guard let container = preferredCopyContainer else { return nil }
        if let cached = copyBoundaryIndices[source.id] { return cached }
        if isPreparingCopyBoundaries || (isImporting && media.indexStorageBytes >= PreparedEdit.backgroundCopyCheckBytes) { return nil }
        let index = try? BoundaryIndex(media: media, container: container, engine: CutEngine())
        copyBoundaryIndices[source.id] = index
        return index
    }

    private func copyIssue(_ proposed: [EditorSegment]) -> CutError? {
        guard !proposed.contains(where: { edit.preparation.unavailableSourceIDs.contains($0.source.id) }) else { return nil }
        return Self.copyIssue(proposed, container: preferredCopyContainer, engine: CutEngine())
    }

    private nonisolated static func copyIssue(_ proposed: [EditorSegment], container: String?, engine: CutEngine) -> CutError? {
        if proposed.contains(where: { $0.source.unresolved != nil }) { return nil }
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
        guard let media = segment.source.media else { return true }
        let failedEdge: TimelineEdge = field == "from" ? .start : .end
        if segment.id == id && failedEdge == edge { return false }
        let neighbor = failedEdge == .start ? index - 1 : index + 1
        if proposed.indices.contains(neighbor), proposed[neighbor].id == id, edge != failedEdge,
           proposed[neighbor].source.id == segment.source.id, let container,
           CutEngine().coalescesAdjacentRanges(in: media, container: container) { return false }
        let time = failedEdge == .start ? segment.start : segment.end
        if time == .zero { return failedEdge == .start && !media.sourceStartSafe }
        if time == media.duration { return false }
        let frame = media.frames.lowerBound { $0.time >= time }
        guard frame < media.frames.count, media.frames[frame].time == time else { return true }
        return failedEdge == .start ? !media.frames[frame].canStart : !media.frames[frame].canEnd
    }

    private func copyMessage(_ issue: CutError, in proposed: [EditorSegment]) -> String {
        var message = ExportRules.displayMessage(issue.message)
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
        let message = audioIssue.map { "\(segment.source.name) — \(ExportRules.displayMessage($0.message))" }
            ?? copyIssue(proposed).map { copyMessage($0, in: proposed) }
            ?? "There is no verified cut point inside the range in \(segment.source.name)."
        alert = EditorNotice(title: title, message: message)
    }

    private func nearestCopyPictureBoundary(in segment: EditorSegment, to target: Double,
                                            edge: TimelineEdge) -> RationalTime? {
        guard let media = segment.source.media else { return nil }
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
        guard let media = segment.source.media, let container = preferredCopyContainer,
              boundary != (edge == .start ? segment.start : segment.end) else { return nil }
        return CutEngine().linkedAudioBoundaryIssue(in: media, at: boundary,
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

    private func export(_ plan: EditorExportPlan, to output: URL, clips: [EditorSegment], saveResult: Bool) {
        guard !isEmpty, !isBusy, canExport(to: output),
              !saveResult || canExport(to: ExportResultFile.destination(beside: output)) else { return }
        runExport { token, progress in
            let result: ExportResultFile?
            if saveResult {
                let map = try ExportCutMap(edit: plan.edit, clips: clips.map(\.request), ids: clips.map(\.documentID))
                result = try plan.resultFile(for: output, cutMap: map)
            } else {
                result = nil
            }
            let edges = try plan.writingEncodedEdges {
                try plan.writeOutput(to: output, cancelled: { token.isCancelled }) { _ = progress($0) }
            }
            // The cost of the Smart Trim edges follows, as a sentence of the status line and in the saved result.
            let message = result?.completionMessage(for: output, encodedEdges: edges) ?? "Exported \(output.lastPathComponent)"
            return (output, ExportNotices.sentence(message, then: ExportNotices.encodedEdges(edges)))
        }
    }

    /// The recording Settings' Source folder starts from when an export has no source of its own.
    var firstSourceURL: URL? { segments.first?.source.url }

    /// The project file Settings' Project folder starts from. Nil for an untitled project's draft.
    private var savedProjectFile: URL? {
        projectURL.flatMap { ProjectDraft.isManaged($0) || draft.managesDestination($0) ? nil : $0 }
    }

    /// The folder an export panel opens in. The sequence entry points' own rule is this window's last export folder.
    /// Resolve and project interchange have no rule of their own (`hasAutomaticRule: false`): in Automatic they leave
    /// the folder to AppKit, and they share the session's folder only when Settings names a starting folder.
    func exportPanelDirectory(source: URL?, hasAutomaticRule: Bool = true) -> URL? {
        let shares = hasAutomaticRule || preferences.exportStartFolder != .automatic
        return ExportStartFolder.resolve(preferences, projectFile: savedProjectFile, sourceRecording: source,
                                         sessionFolder: shares ? exportDirectory : nil, automatic: nil).directory
    }

    /// Records the folder chosen in an export panel for the rest of this window's session.
    func noteExportFolder(_ folder: URL, hasAutomaticRule: Bool = true) {
        if hasAutomaticRule || preferences.exportStartFolder != .automatic { exportDirectory = folder }
    }

    /// The options a fresh export sheet opens with: this window's choices, with every re-encode field the editor has not
    /// changed in a sheet taken from Settings → Export.
    var sheetExportOptions: ExportSheetOptions {
        var options = exportOptions
        options.seedEncoding(from: preferences, keeping: exportEncodingKept)
        return options
    }

    /// Keeps a sheet's choices for this window's session. A codec, quality or container the editor changed from what the
    /// sheet showed stays; Settings never changes because of it.
    func exportSheetChanged(_ options: ExportSheetOptions, from shown: ExportSheetOptions) {
        exportEncodingKept.formUnion(options.encodingFields(changedFrom: shown))
        exportOptions = options
    }

    private func exportDidFinish(_ output: URL) {
        if let exportCompletionHandler {
            exportCompletionHandler(output)
        } else {
            ExportCompletion.runActions(for: output, preferences: preferences)
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
        let awake = SleepPrevention(reason: "Exporting from MPCut", provider: exportActivityProvider)
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
            defer { awake.end() }
            let result = await sidecarWork.detached(priority: .userInitiated) {
                Result { () throws -> (URL, String) in
                    // What writing changed that the plan could not show joins the completion message.
                    let written = try ExportWriteNotices.collecting {
                        try AnalysisSidecar.$excludedSources.withValue(excluded) {
                            try AnalysisSidecar.$readsEnabled.withValue(useSidecar) { try work(token, reportProgress) }
                        }
                    }
                    let (output, message) = written.value
                    return (output, ([message] + written.notices.filter { !message.contains($0) }).joined(separator: " "))
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
                exportDidFinish(output)
            }
        }
    }

    @discardableResult
    private func validate(_ proposed: [EditorSegment], selecting id: UUID?, at destination: Double,
                          action: String, originalPlayhead: Double? = nil, replacementTrack: Int? = nil, preserveMarks: Bool = false) -> Bool {
        cancelTrim()
        preview.pause()
        let original = originalPlayhead ?? playhead
        guard proposed.allSatisfy({ $0.start >= .zero && $0.start < $0.end && $0.end <= $0.sourceExtent }) else {
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
        let media = Self.mediaByURL(segments)
        if let clip = segments.first(where: { $0.source.media == nil }) {
            throw CutError(code: "source_needs_review", message: "\(clip.source.name) — open Project Media to review this recording.")
        }
        return try engine.resolve(segments.map(\.request), media: media, container: container)
    }

    @discardableResult
    private func apply(_ proposed: [EditorSegment], prepared: PreparedEdit, selecting id: UUID?, at destination: Double,
                       action: String, originalPlayhead: Double? = nil, recordHistory: Bool = true,
                       historySnapshot: EditSnapshot? = nil, preservePreview: Bool = false, replacementTrack: Int? = nil,
                       preserveMarks: Bool = false, restoringAudioMonitoring: AudioMonitoring? = nil,
                       sequenceProject: CutProject? = nil, installsParticipants: Bool = false) -> Bool {
        let prepared = preparedForMediaAvailability(proposed, using: prepared)
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
                let sources = Dictionary(uniqueKeysWithValues: proposed.map { ($0.documentID, $0) })
                for placement in stillPresentation.stillReplacements {
                    guard case .sequence(let fragments) = placement.coverage else { continue }
                    for fragment in fragments {
                        guard let source = sources[fragment.clipID],
                              source.source.unresolved != nil || fragment.range.to <= source.sourceExtent else {
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
            undoStack.append(HistoryEntry(action: action, contents: .live(original), copyContainer: explicitCopyContainer, transcriptState: transcriptState,
                                          audioMonitoring: replacementTrack.map { _ in audioMonitoring }))
            redoStack.removeAll()
            unopenedConversionRedo.removeAll()
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
            applyMediaPresentation(segment, to: &clip)
            return clip
        }
        mediaClipReview = Dictionary(uniqueKeysWithValues: clips.compactMap { clip in
            clip.mediaIssue.map { (clip.id, $0) }
        })
        let previousPreview = preservePreview ? segments.map(monitoredPreview) : []
        let keepMarks = preserveMarks || (recordHistory && replacementTrack != nil)
        mcpRevision += 1
        let participants = installsParticipants || !recordHistory ? sequenceProject?.participants ?? edit.participants : edit.participants
        var annotations = sequenceProject?.analysisAnnotations ?? edit.analysisAnnotations
        if recordHistory { annotations = carryingPauseReviews(annotations, to: proposed) }
        edit = EditSnapshot(documentClips: sequenceClips(for: proposed), analysisAnnotations: annotations, participants: participants,
                            segments: proposed, timelineClips: clips,
                            timelineThumbnailHeight: clips.lazy.map(\.thumbnailHeight).max() ?? TimelineClip.minimumThumbnailHeight,
                            largeThumbnailHeight: clips.lazy.map { $0.thumbnailHeight(large: true) }.max() ?? TimelineClip.minimumLargeThumbnailHeight,
                            preparation: prepared, selectedID: id,
                            markIn: keepMarks ? edit.markIn : nil, markOut: keepMarks ? edit.markOut : nil,
                            pointerMarkIn: keepMarks && edit.pointerMarkIn, pointerMarkOut: keepMarks && edit.pointerMarkOut,
                            playhead: destination,
                            offsets: offsets, duration: duration)
        if let stillPresentation { installStillPresentation(stillPresentation, updatesPreview: false) }
        restoreAnalysisAnnotations()
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

    private nonisolated static func mediaByURL(_ segments: [EditorSegment]) -> [URL: MediaInfo] {
        Dictionary(segments.compactMap { clip in clip.source.media.map { (clip.source.url, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func tierInput(_ segments: [EditorSegment]) -> (clips: [ClipRequest], media: [URL: MediaInfo]) {
        (segments.filter { $0.source.media != nil }.map(\.request), Self.mediaByURL(segments))
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
        if let issue = segments.compactMap(mediaReviewIssue).first {
            tierIsCurrent = true
            tierState = .unavailable(CutError(code: "source_needs_review", message: issue))
            return
        }
        let input = Self.tierInput(segments)
        let evaluator = tierEvaluator
        // The badge names the container the export sheet opens on: the preferred one when the timeline verifies in it.
        evaluator.preferredContainer = hasPicture ? preferredCopyContainer : nil
        guard project.requiresPictureProcessing || placements != .none || edit.preparation.requiresBackgroundCopyChecks else {
            tierIsCurrent = true
            tierState = evaluator.evaluate(input.clips, media: input.media)
            return
        }
        let generation = tierGeneration, token = EditCancellation()
        tierToken = token
        tierIsCurrent = false
        if tierState == nil { tierState = .checking }
        let preferred = preferredCopyContainer
        let document = projectURL
        let useSidecar = useAnalysisSidecars
        let excluded = sidecarExclusions
        Task {
            let state = await sidecarWork.detached(priority: .utility) {
                if project.requiresPictureProcessing {
                    return ParticipantProjectExport.tier(project, relativeTo: document, preferredContainer: preferred, cancelled: { token.isCancelled })
                }
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
        guard asksBeforeLoweringTier, preferences.warnBeforeLoweringExportTier, !current.isEmpty, !proposed.isEmpty, !hasNoTier,
              current.allSatisfy({ mediaReviewIssue($0) == nil }), proposed.allSatisfy({ mediaReviewIssue($0) == nil }) else {
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
            var prompt = TierPrompt(action: action, from: was, to: becomes, factors: added.isEmpty ? becomes.factors : added,
                                    nearest: moved, soundOnly: after.media[after.clips[0].file.standardizedFileURL]?.hasVideo == false)
            if let moved {
                var movements: [TierPrompt.CutMovement] = []
                for (index, pair) in zip(after.clips, moved).enumerated() {
                    let media = after.media[pair.0.file.standardizedFileURL]
                    let edges: [(TierPrompt.CutMovement.Edge, RationalTime?, RationalTime?)] =
                        [(.start, pair.0.from, pair.1.from), (.end, pair.0.to, pair.1.to)]
                    for (edge, cut, target) in edges {
                        if let cut, let target, cut != target {
                            let frames = TierPrompt.CutMovement.indexedFrameCount(from: cut, to: target, in: media)
                            movements.append(.init(label: "Clip \(index + 1) \(edge == .start ? "In" : "Out")",
                                                   requested: cut, resolved: target, frameCount: frames,
                                                   edge: edge, exactTime: media?.hasVideo == false))
                        }
                    }
                }
                prompt.movements = movements
            }
            return prompt
        }
        let ask: (TierPrompt?) -> Void = { [self] prompt in
            guard let prompt else { return decide(proposed) }
            let currentSession = session
            let wasPresenting = isPresentingPanel
            isPresentingPanel = true
            let answer: (TierPrompt.Choice) -> Void = { [self] choice in
                guard session == currentSession else { abandoned?(); return }
                isPresentingPanel = wasPresenting
                if choice.dontAskAgain { preferences.suppress(.exportTierDowngrade) }
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
            let prompt = await sidecarWork.detached(priority: .userInitiated) { work({ token.isCancelled }) }.value
            guard session == currentSession else { abandoned?(); return }
            if cancellation === token { cancellation = previous }
            isCheckingEdit = wasChecking
            guard !token.isCancelled else { return decide(nil) }
            ask(prompt)
            if !isPresentingPanel { resumePendingWork() }
        }
    }

    private var hasUnsavedDocumentChanges: Bool {
        recoveredDraft || mediaSnapshotChanged || transcriptState != savedTranscriptState || edit.participants != savedParticipants || edit.analysisAnnotations != savedAnalysisAnnotations ||
            (committedBeforeImport.map { project in
                var timeline = project
                timeline.transcripts = .init()
                timeline.analysisAnnotations = .init()
                timeline.participants = .init()
                return timeline
            } ?? {
                var timeline = stillProject
                timeline.analysisAnnotations = .init()
                timeline.participants = .init()
                return timeline
            }()) != (savedStillSequence.map(CutProject.stillSequence) ?? .sequence(savedSequence)) ||
            undoStack.map(\.id) != savedUndoIDs || redoStack.map(\.id) != savedRedoIDs
    }

    private func updateStatus() {
        updateMediaWatcher()
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
                       reference: edit.preparation.firstMedia.flatMap { $0.hasVideo ? $0 : nil },
                       soundtrack: stillSoundtrackPreview, document: projectURL ?? draft.url)
    }

    private var stillSoundtrackMapping: StillSoundtrackMapping? {
        try? stillProject.stillSoundtrackMapping(in: MulticamRange(from: .zero, to: edit.duration))
    }

    private var stillSoundtrackPreview: PreviewRange? {
        guard let mapping = stillSoundtrackMapping, let media = currentSoundtrackMedia else { return nil }
        var range = PreviewRange(media: media, from: mapping.source.from, to: mapping.source.to)
        range.audioTrack = mapping.clip.audioTrack
        range.audioOrigin = media.origin
        range.readerRevision = media.identity.hashValue
        return range
    }

    var stillSoundtrackWaveform: TimelineSoundtrack? {
        guard let mapping = stillSoundtrackMapping else { return nil }
        let fullEnd = (try? mapping.clip.to.subtracting(mapping.clip.from)) ?? mapping.output.to
        return TimelineSoundtrack(id: stillSoundtrackWaveformID, source: mapping.source, output: mapping.output, fullProgramEnd: fullEnd)
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

    func monitorTileLayout(at output: RationalTime) -> ParticipantMonitorLayout? {
        guard let (_, clip, offset) = locatedSegment(at: output.seconds),
              let sourceTime = try? clip.start.adding(output.subtracting(offset)),
              let layout = sequenceClips.first(where: { $0.id == clip.documentID })?.tileLayouts
                  .first(where: { $0.range.contains(sourceTime) }) else { return nil }
        return .init(scope: .clip(clip.documentID), layout: layout)
    }

    func setMonitorTileLayout(_ layout: ParticipantShotLayout?, slots: [ParticipantSlot],
                              position: ParticipantMonitorPosition? = nil) throws {
        guard let (_, clip, _) = locatedSegment(at: playhead), clip.source.media?.hasVideo == true else {
            throw CutError(code: "invalid_tile_layout", message: "Park the playhead on a video clip.")
        }
        let scope: TileLayoutScope = .clip(clip.documentID)
        let range: MulticamRange
        if edit.markIn != nil && edit.markOut != nil {
            guard let marked = participantMarkedSourceRange(sourceID: clip.source.url.path) else {
                throw CutError(code: "invalid_tile_range", message: "Set both marks within this occurrence of the recording.")
            }
            range = marked
        } else {
            let whole = MulticamRange(from: clip.start, to: clip.end)
            if layout == .arranged, let position,
               let epoch = try participantProject.arrangedLayoutEpoch(sourceID: position.sourceID, at: position.time, within: whole) {
                range = epoch
            } else {
                range = whole
            }
        }
        let span = layout.map { TileLayoutSpan(range: range, layout: $0, slots: slots) }
        try replaceTileLayoutProject(stillProject.settingTileLayout(scope: scope, range: range, layout: span))
    }

    func participantMarkedSourceRange(sourceID: String) -> MulticamRange? {
        guard let from = edit.markIn, let to = edit.markOut,
              let (_, clip, offset) = locatedSegment(at: playhead), clip.source.url.path == sourceID,
              let end = try? offset.adding(clip.duration), offset <= from, from < to, to <= end,
              let start = try? clip.start.adding(from.subtracting(offset)),
              let finish = try? clip.start.adding(to.subtracting(offset)) else { return nil }
        return .init(from: start, to: finish)
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
        if mediaReviewIssue(segment) != nil {
            let end = offset + segment.duration
            return time - offset.seconds < end.seconds - time ? offset : end
        }
        let target = time - offset.seconds + segment.start.seconds
        let boundary: RationalTime
        switch (pointer ?? usesPointerPosition) ? .off : effectiveSnapTarget {
        case .off:
            boundary = editBoundary(in: segment.source, to: target) ?? segment.start
        case .keyframes:
            let keys = segment.source.keyframes
            let points = (0..<(keys.count + 1)).lazy.map { $0 == keys.count ? segment.sourceExtent : keys[$0] }
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
            message = sceneReport(for: clip) == nil && layoutSceneTimes(for: clip).isEmpty
                ? "Finish the scene scan to snap to scene boundaries."
                : "There is no scene boundary inside this range."
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
        guard mediaReviewIssue(clip) == nil else { return nil }
        let source = clip.source
        if snapTarget == .scenes {
            let tiles = nearest(in: layoutSceneTimes(for: clip), to: target, after: minimum, before: maximum,
                                includingLimits: includingLimits)
            func closest<T: RandomAccessCollection>(_ times: T) -> RationalTime?
            where T.Element == RationalTime, T.Index == Int {
                let visual = nearest(in: times, to: target, after: minimum, before: maximum, includingLimits: includingLimits)
                guard let tiles, let visual else { return tiles ?? visual }
                let tileDistance = abs(tiles.seconds - target)
                let visualDistance = abs(visual.seconds - target)
                return tileDistance == visualDistance ? min(tiles, visual) : tileDistance < visualDistance ? tiles : visual
            }
            if let report = sceneRangeReports[ClipSceneRange(clip)] {
                let boundaries = report.scenes.dropFirst(report.syntheticLeading ? 1 : 0).lazy.map(\.start)
                return closest(boundaries)
            }
            guard let report = sceneReports[source.id] else { return tiles }
            let boundaries = (0..<(report.scenes.count + 1)).lazy.map { index in
                index == report.scenes.count ? clip.sourceExtent : report.scenes[index].start
            }
            return closest(boundaries)
        }
        guard let pauses = sourcePauses[source.id] else { return nil }
        let boundaries = (0..<(2 * pauses.count)).lazy.map { index in
            let pause = pauses[index / 2]
            let edge = index.isMultiple(of: 2) ? pause.from : pause.to
            return self.editBoundary(in: source, to: edge.seconds) ?? .zero
        }
        return nearest(in: boundaries, to: target, after: minimum, before: maximum, includingLimits: includingLimits)
    }

    private func editBoundary(in source: EditorSource, to target: Double, after minimum: RationalTime? = nil,
                              before maximum: RationalTime? = nil) -> RationalTime? {
        guard let media = source.media else { return nil }
        if media.hasVideo {
            return nearest(in: source.frameBoundaries, to: target, after: minimum, before: maximum)
        }
        var cut = media.audioEditBoundary(near: target)
        if let minimum, cut <= minimum { cut = media.steppingAudioBoundary(from: minimum.seconds, direction: 1) }
        if let maximum, cut >= maximum { cut = media.steppingAudioBoundary(from: maximum.seconds, direction: -1) }
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
        guard let media = segment.source.media, mediaReviewIssue(segment) == nil else { return segment.start }
        if !media.hasVideo {
            return max(segment.start, media.steppingAudioBoundary(from: time.seconds, direction: -1))
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

    struct Key: Hashable {
        let source: Source
        let span: AudioSpan
    }
    let key: Key
    let sequence: AudioSpan
    let removal: AudioSpan?
    let isProtected: Bool
    var requestedRetainedSeconds: Double? = nil

    var retainedSeconds: Double {
        (sequence.to.seconds - sequence.from.seconds) -
            (removal.map { $0.to.seconds - $0.from.seconds } ?? 0)
    }
}

struct TakeCandidate: Identifiable {
    var id: RationalTime { range.from }
    let range: AudioSpan
    let hasManualStart: Bool
}

struct CutPreview: Identifiable {
    let id: UUID
    let position: RationalTime
    let pauseKey: TimelinePause.Key?
    let ranges: [PreviewRange]
    var project: CutProject? = nil
    var reference: MediaInfo? = nil
    /// The seconds played before and after the cut, from Settings → Playback when the preview was made.
    var preroll = 1.0
    var postroll = 1.0

    /// Settings seconds as an exact time, in whole milliseconds, so 1 s is exactly one second.
    static func time(seconds: Double) -> RationalTime {
        let bounded = min(max(seconds.isFinite ? seconds : 1, 0), 3_600)
        return RationalTime(numerator: Int64((bounded * 1_000).rounded()), denominator: 1_000)
    }

    /// The Preview Join sheet's sentence for the seconds it plays on each side of the join.
    static func joinMessage(preroll: Double, postroll: Double) -> String {
        func seconds(_ value: Double) -> String {
            if value == 1 { return "one second" }
            let text = value.formatted(.number.precision(.fractionLength(0...2)))
            return "\(text) seconds"
        }
        if preroll == postroll { return "Review up to \(seconds(preroll)) on each side of the join." }
        return "Review up to \(seconds(preroll)) before and \(seconds(postroll)) after the join."
    }

    var joinMessage: String { Self.joinMessage(preroll: preroll, postroll: postroll) }
}

extension EditorModel {
    private func monitoredAudioOrdinal(for source: EditorSource) -> Int? {
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
            guard let media = source.media else { continue }
            sources[source.id] = media
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
            guard !clip.source.isIndexed, let media = clip.source.media, media.hasVideo,
                  let ordinal = monitoredAudioOrdinal(for: clip.source) else { return nil }
            return (clip.source.id, media, ordinal)
        }
        var waveformSources = silenceMedia
        if let media = currentSoundtrackMedia, let soundtrack = stillProject.stillSoundtrack {
            waveformSources[stillSoundtrackWaveformID] = media
            ordinals[stillSoundtrackWaveformID] = soundtrack.audioTrack ?? 0
        }
        audioStore.update(sources: waveformSources, track: 0, sourceTracks: ordinals, useSidecar: useAnalysisSidecars,
                          excludedSources: sidecarExclusions, opening: opening)
        refreshDetectedPauses(invalidating: invalidatingPauses ? nextSources : changed)
    }

    private var playheadAudioSource: EditorSource? {
        guard let clip = locatedSegment(at: playhead)?.1 ?? segments.last, mediaReviewIssue(clip) == nil else { return nil }
        return clip.source
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
        guard let next = thresholdAnnotations(threshold, source: id, in: edit.analysisAnnotations) else { return }
        commitAnalysisAnnotations(next, action: "Set Silence Threshold")
    }

    var effectiveThresholdDB: Double? {
        manualThresholdDB ?? playheadAudioSource.flatMap { automaticThresholds[$0.id] }
    }

    private func thresholdAnnotations(_ threshold: Double?, source id: UUID,
                                      in annotations: ProjectAnalysisAnnotations) -> ProjectAnalysisAnnotations? {
        guard let media = silenceMedia[id], threshold.map({ (-120...0).contains($0) }) ?? true else { return nil }
        let audio = media.streams.filter { $0.kind == "audio" }
        guard let track = sourceAnalysisTracks[id], audio.indices.contains(track) else { return nil }
        var next = annotations
        guard next.setThreshold(threshold, for: media, stream: audio[track].index) else { return nil }
        return next
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
                sourcePauses[id] = result.pauses(maxBlip: preferences.maxBlip)
                continue
            }
            let persist = sidecarPreference.permits(media.url)
            let media = persist ? media.pinningSidecarWrites() : media
            let readSaved = !rescan && persist && checkedSilenceSidecars.insert(id).inserted
            let wave = audioStore.finished.contains(id) ? audioStore.waves[id] : nil
            let calibrated = automaticThresholds[id]
            let requested = silenceScanRequested
            guard readSaved || (wave != nil && (requested || calibrated == nil)) else { continue }
            // This job restores saved results even before the waveform has arrived.
            // Fresh detection shares the waveform decoder and runs only on request.
            let worker = sidecarWork.detached(priority: .utility) { [sidecarPreference] () throws -> (Double?, SilenceAnalysisResult?) in
                let skipSidecar = { @Sendable in Task.isCancelled || !sidecarPreference.permits(media.url) }
                var level = calibrated
                if readSaved {
                    let sidecar = AnalysisSidecar(media: media)
                    if let result = sidecar.silence(for: media, stream: stream, thresholdDB: manual, minimum: profile.minimum,
                                                   cancelled: skipSidecar) {
                        return (result.automaticThresholdDB, result)
                    }
                    if level == nil { level = sidecar.automaticThresholdDB(for: media, stream: stream, cancelled: skipSidecar) }
                }
                try Task.checkCancellation()
                guard let wave else { return (level, nil) }
                if requested {
                    let result = try AudioAnalysis.silence(media, stream: stream, thresholdDB: manual, minimum: profile.minimum,
                                                           waveform: wave, automaticThresholdDB: level, useSidecar: false,
                                                           cancelled: { Task.isCancelled })
                    if persist {
                        AnalysisSidecar(media: media).saveAutomatically(try AnalysisSidecar.sections(media: media, silence: [result],
                                                                                                      cancelled: skipSidecar),
                                                                      cancelled: skipSidecar)
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
                    guard media.identity.isCurrentSnapshot(at: media.url) else {
                        throw CutError(code: "source_changed", message: "The audio source changed during analysis.")
                    }
                    automaticThresholds[id] = level
                    if let result {
                        if !edit.analysisAnnotations.needsThresholdReview(for: media, stream: stream) {
                            refreshStaleSilence.remove(id)
                        }
                        silenceResults[id, default: [:]][profile] = result
                        sourcePauses[id] = result.pauses(maxBlip: preferences.maxBlip)
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
        pauseReviewMismatch = pauseReviewSourceChanged
        var plan: [TimelinePause] = []
        var count = 0, seconds = 0.0
        var authoredProtections: [UUID: [AudioSpan]] = [:]
        let transcriptProtections = transcriptPauseCache.resolve(transcriptState, relativeTo: projectURL ?? draft.url)
        var index = max(0, edit.offsets.lowerBound { $0 > scope.from } - 1)
        // Include earlier pieces of this continuous occurrence when the scope starts after a split.
        while index > 0, index < segments.count, segments[index - 1].occurrence == segments[index].occurrence,
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
            guard lower < upper, let media = clip.source.media, mediaReviewIssue(clip) == nil,
                  clip.source.isIndexed, let detected = sourcePauses[clip.source.id] else { continue }
            let bounds = effectiveSnapTarget == .keyframes ? copyBoundaries(for: clip.source) : nil
            let fullClip = AudioSpan(from: clip.start, to: clip.end)
            var local: [(key: TimelinePause.Key, span: AudioSpan, cut: AudioSpan?, keep: Bool, padding: Double)] = []
            let source = TimelinePause.Source(occurrence: clip.occurrence, track: sourceAnalysisTracks[clip.source.id] ?? analysisTrack)
            let protected = protectedPauses[source] ?? []
            var reviewed = Set(protected)
            reviewed.formUnion(pauseRetainedSeconds.keys.lazy.filter { $0.source == source }.map(\.span))
            if !reviewed.isEmpty, !reviewed.isSubset(of: Set(detected)) { pauseReviewMismatch = true }
            let pauses = ProjectPauseReview.preserving(reviewed, in: detected)
            if authoredProtections[clip.source.id] == nil {
                let audio = media.audio
                authoredProtections[clip.source.id] = !transcriptProtections.isEmpty && audio.indices.contains(source.track)
                    ? transcriptProtections.sequence(file: media.url.path, origin: media.multicamSourceOffset,
                                                     stream: audio[source.track].stream.index,
                                                     sourceFingerprint: media.identity.transcriptFingerprint)
                    : []
            }
            let authored = authoredProtections[clip.source.id] ?? []
            let first = pauses.lowerBound { $0.to > lower }
            for pause in pauses[first...] {
                if pause.from >= upper { break }
                let span = AudioSpan(from: max(lower, pause.from), to: min(upper, pause.to))
                let length = (try? span.to.subtracting(span.from))?.seconds ?? (span.to.seconds - span.from.seconds)
                guard length >= minimumPause else { continue }
                let key = TimelinePause.Key(source: source, span: pause)
                let match = protected.lowerBound { $0.to > pause.from }
                let keep = (match < protected.count && protected[match].from < pause.to)
                    || authored.contains { $0.from < pause.to && pause.from < $0.to }
                let padding = padding(for: key)
                let isExterior = padding == 0 && (span.from == clip.start || span.to == clip.end)
                var cut: AudioSpan?
                if !keep && !(effectiveSnapTarget == .keyframes && isExterior) {
                    if !media.hasVideo {
                        cut = AudioAnalysis.audioRemoval(in: span, padding: padding, media: media, clip: fullClip)
                    } else {
                        let ends = effectiveSnapTarget == .keyframes ? bounds?.interiorEnds ?? [] : clip.source.frameBoundaries
                        let starts = effectiveSnapTarget == .keyframes ? bounds?.interiorStarts ?? [] : clip.source.frameBoundaries
                        cut = AudioAnalysis.removal(in: span, padding: padding, ends: ends, starts: starts, clip: fullClip)
                    }
                }
                local.append((key, span, cut, keep, padding))
            }
            // A head or tail trim can copy one continuous audio range even
            // on streams whose decoder cannot restart at an interior join.
            if let bounds {
                let onlyPiece = !local.contains { $0.cut != nil }
                for i in local.indices where !local[i].keep && local[i].padding == 0 {
                    let span = local[i].span
                    guard span.from == clip.start || span.to == clip.end else { continue }
                    let starts = bounds.starts(first: offset == .zero, last: onlyPiece && end == edit.duration)
                    let ends = bounds.ends(first: onlyPiece && offset == .zero, last: end == edit.duration)
                    local[i].cut = AudioAnalysis.removal(in: span, padding: 0, ends: ends, starts: starts, clip: fullClip)
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
                                          isProtected: pause.keep, requestedRetainedSeconds: pauseRetainedSeconds[pause.key]))
            }
        }
        timelinePadding = plan.flatMap { pause -> [AudioSpan] in
            guard !pause.isProtected else { return [] }
            return AudioAnalysis.paddingSpans(in: pause.sequence, removal: pause.removal, padding: padding(for: pause.key))
        }
        pausePlan = plan
        shortenedPauseCount = count
        removedPauseSeconds = seconds
        waveformRevision += 1
    }

    private func padding(for key: TimelinePause.Key) -> Double {
        pauseRetainedSeconds[key].map { $0 / 2 } ?? padding
    }

    @discardableResult
    func setPauseRetainedDuration(_ seconds: Double?, for key: TimelinePause.Key) -> Bool {
        guard pauseAnalysisReady, pausePlan.contains(where: { $0.key == key }),
              seconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { return false }
        return changePauseReview(key, action: "Set Retained Pause Duration") { id, source, media, reviews in
            reviews.removeAll { $0.kind == .retain && $0.occurrenceID == id && $0.sources.first?.stream == source.stream && $0.sources.first?.matches(media) == true && $0.span == key.span }
            if let seconds {
                reviews.append(.init(occurrenceID: id, kind: .retain, from: key.span.from, to: key.span.to,
                                     retainedSeconds: seconds, sources: [source]))
            }
        }
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

    @discardableResult
    func protectCurrentPause() -> Bool {
        guard canEdit, let currentPause else { return false }
        return setPauseProtection(!currentPause.isProtected, for: currentPause.key)
    }

    private func setPauseProtection(_ protect: Bool, for key: TimelinePause.Key) -> Bool {
        changePauseReview(key, action: protect ? "Protect Pause" : "Unprotect Pause") { id, source, media, reviews in
            if protect {
                let row = ProjectPauseReview(occurrenceID: id, kind: .protect, from: key.span.from, to: key.span.to,
                                             sources: [source])
                if !reviews.contains(row) { reviews.append(row) }
            } else {
                reviews = reviews.flatMap { row -> [ProjectPauseReview] in
                    guard row.kind == .protect, row.occurrenceID == id, row.sources.first?.stream == source.stream, row.sources.first?.matches(media) == true, let span = row.span,
                          let overlap = MulticamSilencePlanner.intersection(span, key.span) else { return [row] }
                    return AudioAnalysis.retained(in: span, removing: [overlap]).map {
                        .init(occurrenceID: id, kind: .protect, from: $0.from, to: $0.to, sources: [source])
                    }
                }
            }
        }
    }

    private func changePauseReview(_ key: TimelinePause.Key, action: String,
                                   update: (String, ProjectPauseReview.Source, MediaInfo, inout [ProjectPauseReview]) -> Void) -> Bool {
        var next = edit.analysisAnnotations
        let clips = segments.filter { $0.occurrence == key.source.occurrence }
        guard let media = clips.first?.source.media, media.audio.indices.contains(key.source.track) else { return false }
        guard let source = ProjectPauseReview.Source(media: media, stream: media.audio[key.source.track].stream.index) else { return false }
        var rows = next.pauseReviews
        for clip in clips where key.span.to > clip.start && key.span.from < clip.end {
            update(clip.documentID, source, media, &rows)
        }
        next.pauseReviews = rows
        commitAnalysisAnnotations(next, action: action)
        return true
    }

    /// The timeline's transient UUIDs change on reopening. Rebuild playback indexes
    /// from persistent clip IDs, stream indices and the generation that was reviewed.
    private func refreshPauseReviews() {
        let needsRebuild = !edit.analysisAnnotations.pauseReviews.isEmpty || !protectedPauses.isEmpty
            || !pauseRetainedSeconds.isEmpty || !takeBoundaries.isEmpty
        defer { if needsRebuild { rebuildPausePlan() } }
        pauseReviewSourceChanged = false
        protectedPauses.removeAll()
        pauseRetainedSeconds.removeAll()
        takeBoundaries.removeAll()
        guard !edit.analysisAnnotations.pauseReviews.isEmpty else { return }
        let clips = Dictionary(segments.map { ($0.documentID, $0) }, uniquingKeysWith: { first, _ in first })
        for row in edit.analysisAnnotations.pauseReviews {
            guard let id = row.occurrenceID else { continue }
            if row.kind == .marker, row.sources.isEmpty, let still = stillTimelineIDs[id] {
                takeBoundaries[still, default: []].insert(row.from)
                continue
            }
            guard let clip = clips[id], let source = row.sources.first else { continue }
            guard let media = clip.source.media, source.matches(media) else {
                pauseReviewSourceChanged = true
                continue
            }
            if row.kind == .marker {
                takeBoundaries[clip.occurrence, default: []].insert(row.from)
                continue
            }
            guard let span = row.span, let track = media.audio.firstIndex(where: { $0.stream.index == source.stream })
            else { continue }
            let key = TimelinePause.Source(occurrence: clip.occurrence, track: track)
            if row.kind == .protect {
                protectedPauses[key, default: []].append(span)
            } else {
                pauseRetainedSeconds[.init(source: key, span: span)] = row.retainedSeconds
            }
        }
        protectedPauses = protectedPauses.mapValues { Array(Set($0)).sorted { $0.from < $1.from } }
    }

    private func carryingPauseReviews(_ original: ProjectAnalysisAnnotations, to proposed: [EditorSegment]) -> ProjectAnalysisAnnotations {
        guard !original.pauseReviews.isEmpty else { return original }
        var next = original
        let prior = Dictionary(grouping: segments, by: \.occurrence)
        let ids = Set(segments.map(\.documentID))
        let owners = Dictionary(grouping: original.pauseReviews, by: \.occurrenceID)
        let surviving = Set(proposed.map(\.documentID))
        var rows = original.pauseReviews.filter { !ids.contains($0.occurrenceID ?? "") || surviving.contains($0.occurrenceID ?? "") }
        for clip in proposed where !ids.contains(clip.documentID) {
            let parents = clip.copiedReviewFrom.map { [$0] } ?? prior[clip.occurrence]?.map(\.documentID) ?? []
            var inherited = Set(owners[clip.documentID] ?? [])
            for id in parents {
                for var row in owners[id] ?? [] where row.from < clip.end && (row.to.map { $0 > clip.start } ?? (row.from >= clip.start)) {
                    row.occurrenceID = clip.documentID
                    if inherited.insert(row).inserted { rows.append(row) }
                }
            }
        }
        next.pauseReviews = rows
        return next
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
        var next = edit.analysisAnnotations
        for (id, peak) in peaks {
            next = thresholdAnnotations(AudioAnalysis.roomToneThresholdDB(forPeak: peak), source: id, in: next) ?? next
        }
        commitAnalysisAnnotations(next, action: "Set Room Tone")
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
                result.append(start == clip.start && end == clip.end ? clip : EditorSegment(documentID: clip.documentID, source: clip.source, start: start, end: end,
                    displayRange: AudioSpan(from: start, to: end), occurrence: clip.occurrence,
                    tileLayouts: clip.tileLayouts.compactMap {
                        $0.limited(from: start == clip.start ? nil : start, to: end == clip.end ? nil : end)
                    }))
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
        guard let review = cutPreview, let key = review.pauseKey else { return }
        if keepingCurrent, !setPauseProtection(true, for: key) { return }
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
        let (preroll, postroll) = (preferences.cutPreviewPreroll, preferences.cutPreviewPostroll)
        var beforeRanges: [AudioSpan] = [], afterRanges: [AudioSpan] = []
        var remaining = CutPreview.time(seconds: preroll)
        for span in kept[..<after].reversed() {
            guard let start = try? span.to.subtracting(remaining) else { cutPreview = nil; return }
            let from = max(span.from, start)
            beforeRanges.append(AudioSpan(from: from, to: span.to))
            guard let left = try? remaining.subtracting(span.to.subtracting(from)) else { cutPreview = nil; return }
            remaining = left
            if remaining == .zero { break }
        }
        remaining = CutPreview.time(seconds: postroll)
        for span in kept[after...] {
            guard let end = try? span.from.adding(remaining) else { cutPreview = nil; return }
            let to = min(span.to, end)
            afterRanges.append(AudioSpan(from: span.from, to: to))
            guard let left = try? remaining.subtracting(to.subtracting(span.from)) else { cutPreview = nil; return }
            remaining = left
            if remaining == .zero { break }
        }
        let ranges = (beforeRanges.reversed() + afterRanges).flatMap(pieces).map(monitoredPreview)
        cutPreview = ranges.isEmpty ? nil : CutPreview(id: id, position: pause.sequence.from, pauseKey: pause.key, ranges: ranges,
                                                       preroll: preroll, postroll: postroll)
    }

    var canPreviewSelectedJoin: Bool {
        canEdit && cutPreview == nil && selectedTimelineItem.map { $0 > 0 } == true
    }

    func previewSelectedJoin() {
        guard canPreviewSelectedJoin, let selectedID else { return }
        _ = previewExistingJoin(before: selectedID)
    }

    func previewExistingJoin(beforeTimelineItem id: String) -> Bool {
        guard let timelineID = stillTimelineIDs[id] ?? segments.first(where: { $0.documentID == id })?.id
                ?? UUID(uuidString: id) else { return false }
        return previewExistingJoin(before: timelineID)
    }

    @discardableResult
    func previewExistingJoin(before id: UUID) -> Bool {
        guard canEdit, cutPreview == nil,
              let index = edit.timelineClips.firstIndex(where: { $0.id == id }), index > 0 else { return false }
        let (preroll, postroll) = (preferences.cutPreviewPreroll, preferences.cutPreviewPostroll)
        let before = CutPreview.time(seconds: preroll), after = CutPreview.time(seconds: postroll)
        func aligned(_ time: RationalTime) -> RationalTime {
            guard let (card, start) = stillInsert(at: time.seconds),
                  let offset = try? time.subtracting(start),
                  let frame = stillTakeOffset(offset.seconds, card: card),
                  let boundary = try? start.adding(frame) else { return time }
            return boundary
        }
        do {
            var join = RationalTime.zero
            for item in (stillProject.sequenceItems ?? []).prefix(index) {
                if let clip = item.source { join = try join.adding(clip.to.subtracting(clip.from)) }
                else if let card = item.still { join = try join.adding(card.duration) }
            }
            guard join > .zero, join < edit.duration else { return false }
            let from = aligned(try join.subtracting(min(before, join)))
            let to = aligned(try join.adding(min(after, edit.duration.subtracting(join))))
            let span = AudioSpan(from: from, to: to)
            let ranges = pieces(in: span).map(monitoredPreview)
            let project = edit.stillSequence != nil ? try stillProjectForRange(span) : nil
            guard !ranges.isEmpty || project != nil else { return false }
            preview.pause()
            cutPreview = CutPreview(id: UUID(), position: join, pauseKey: nil, ranges: ranges, project: project,
                                    reference: stillReviewCanvas, preroll: preroll, postroll: postroll)
            return true
        } catch {
            return false
        }
    }

    private func stillTakeOffset(_ offset: Double, card: StillInsert) -> RationalTime? {
        let step = (offset / card.cadence.seconds).rounded()
        guard step >= 0, step < Double(Int64.max),
              let frame = try? card.cadence.multiplied(by: RationalTime(numerator: Int64(step))) else { return nil }
        return min(card.duration, frame)
    }

    private func takeBoundaryLocations() -> [(position: RationalTime, occurrence: UUID, sourcePosition: RationalTime)] {
        typealias Location = (position: RationalTime, occurrence: UUID, sourcePosition: RationalTime)
        guard !takeBoundaries.isEmpty else { return [] }
        let media = zip(segments, edit.offsets).flatMap { clip, offset -> [Location] in
            (takeBoundaries[clip.occurrence] ?? []).compactMap { point in
                guard clip.start <= point, point < clip.end,
                      let position = try? offset.adding(point.subtracting(clip.start)) else { return nil }
                return (position, clip.occurrence, point)
            }
        }
        guard edit.stillSequence != nil else { return media }
        let cards = inlineStills(in: stillProject).flatMap { card -> [Location] in
            guard let id = stillTimelineIDs[card.insert.id] else { return [] }
            return (takeBoundaries[id] ?? []).compactMap { point in
                guard point < card.insert.duration, let position = try? card.start.adding(point) else { return nil }
                return (position, id, point)
            }
        }
        return media + cards
    }

    var takeCandidates: [TakeCandidate] {
        let manual = Set(takeBoundaryLocations().map(\.position))
        let cuts = pausePlan.compactMap(\.removal)
        return AudioAnalysis.retained(in: pauseScope, removing: cuts).flatMap { range in
            let points = [range.from] + manual.filter { range.from < $0 && $0 < range.to }.sorted() + [range.to]
            return zip(points, points.dropFirst()).map { from, to in
                TakeCandidate(range: AudioSpan(from: from, to: to), hasManualStart: from != range.from)
            }
        }
    }

    @discardableResult
    func addTakeBoundary(at position: Double) -> Bool {
        guard pauseAnalysisReady, position.isFinite,
              let candidate = takeCandidates.first(where: { $0.range.from.seconds < position && position < $0.range.to.seconds }) else { return false }
        if let (card, start) = stillInsert(at: position),
           let id = stillTimelineIDs[card.id],
           let boundary = stillTakeOffset(position - start.seconds, card: card),
           boundary < card.duration,
           let exact = try? start.adding(boundary),
           candidate.range.from < exact, exact < candidate.range.to {
            return insertTakeBoundary(boundary, for: id)
        }
        guard let (_, clip, offset) = locatedSegment(at: position), clip.source.isIndexed, mediaReviewIssue(clip) == nil else { return false }
        let target = position - offset.seconds + clip.start.seconds
        let lower = max(offset, candidate.range.from)
        guard let minimum = try? clip.start.adding(lower.subtracting(offset)),
              let upper = try? clip.start.adding(candidate.range.to.subtracting(offset)) else { return false }
        let boundary: RationalTime?
        if position == offset.seconds {
            boundary = clip.start
        } else if effectiveSnapTarget == .keyframes && clip.source.media?.hasVideo == true {
            boundary = nearest(in: clip.source.keyframes, to: target, after: minimum, before: min(upper, clip.end))
        } else {
            boundary = editBoundary(in: clip.source, to: target, after: minimum, before: min(upper, clip.end))
        }
        guard let boundary, let exact = try? offset.adding(boundary.subtracting(clip.start)),
              candidate.range.from < exact, exact < candidate.range.to else { return false }
        return insertTakeBoundary(boundary, for: clip.occurrence)
    }

    private func insertTakeBoundary(_ boundary: RationalTime, for occurrence: UUID) -> Bool {
        let row: ProjectPauseReview
        if let clip = segments.first(where: { $0.occurrence == occurrence && $0.start <= boundary && boundary < $0.end }),
           let media = clip.source.media, let source = ProjectPauseReview.Source(media: media) {
            row = .init(occurrenceID: clip.documentID, kind: .marker, from: boundary, sources: [source])
        } else if let id = stillTimelineIDs.first(where: { $0.value == occurrence })?.key {
            row = .init(occurrenceID: id, kind: .marker, from: boundary, sources: [])
        } else { return false }
        var next = edit.analysisAnnotations
        guard !next.pauseReviews.contains(row) else { return false }
        next.pauseReviews.append(row)
        commitAnalysisAnnotations(next, action: "Add Take Boundary")
        return true
    }

    @discardableResult
    func removeTakeBoundary(at position: RationalTime) -> Bool {
        guard pauseAnalysisReady, let bound = takeBoundaryLocations().first(where: { $0.position == position }) else { return false }
        var ids = Set(segments.filter { $0.occurrence == bound.occurrence }.map(\.documentID))
        if let id = stillTimelineIDs.first(where: { $0.value == bound.occurrence })?.key { ids.insert(id) }
        var next = edit.analysisAnnotations
        next.pauseReviews.removeAll { row in
            row.kind == .marker && row.from == bound.sourcePosition && row.occurrenceID.map(ids.contains) == true
        }
        guard next != edit.analysisAnnotations else { return false }
        commitAnalysisAnnotations(next, action: "Remove Take Boundary")
        return true
    }

    @discardableResult
    func applyPauses(queueTakes: Bool) -> Bool {
        guard pauseAnalysisReady else { return false }
        let cuts = pausePlan.compactMap(\.removal)
        let candidates = queueTakes ? takeCandidates : []
        guard !cuts.isEmpty || candidates.contains(where: \.hasManualStart) else { return false }
        let ranges = queueTakes ? candidates.map(\.range)
            : AudioAnalysis.retained(in: AudioSpan(from: .zero, to: edit.duration), removing: cuts)
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
                    if stillProject.requiresPictureProcessing { return try captureQueueRange(range) }
                    var media = Self.mediaByURL(clips)
                    var project: CutProject?
                    var placements: ExportPlacementScope = .none
                    if edit.stillSequence != nil {
                        let snapshot = try stillProjectForRange(range)
                        placements = try snapshot.exportPlacementScope()
                        if placements != .none {
                            project = snapshot
                            if let reference = snapshot.stillAudioReference,
                               let source = segments.first(where: { $0.documentID == reference.id })?.source.indexed {
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
        var retainedIDs = Set<String>()
        let originals = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0) })
        let proposed = clips.flatMap { $0 }.map { piece -> EditorSegment in
            if retainedIDs.insert(piece.documentID).inserted, let original = originals[piece.documentID] {
                var retained = original
                retained.start = piece.start
                retained.end = piece.end
                retained.displayRange = piece.displayRange
                retained.tileLayouts = piece.tileLayouts
                return retained
            }
            return EditorSegment(source: piece.source, start: piece.start, end: piece.end,
                                 displayRange: piece.displayRange, occurrence: piece.occurrence, tileLayouts: piece.tileLayouts)
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
    func validateMCPInterchange() throws {
        guard !mcpHasActiveTrim else { throw MCPCommandError("busy", "Finish the pending edit before exporting.") }
        for segment in segments where segment.source.unresolved == nil {
            let status = mediaStatus(for: segment.source.url)
            guard status != .checking, status != .offline, status != .ignored else { continue }
            if let issue = mediaReviewIssue(segment) {
                throw MCPCommandError("source_needs_review", issue)
            }
        }
    }

    /// Capture the very same occurrence pieces and indexed sources as the native export sheet.
    func mcpExportInput(selection: Bool) throws -> (clips: [ClipRequest], media: [URL: MediaInfo], occurrenceIDs: [String?]) {
        guard canEdit, !mcpHasActiveTrim else { throw MCPCommandError("busy", "Finish the pending edit or import first.") }
        let items: [EditorSegment]
        if selection {
            guard let selectedSpan else { throw MCPCommandError("no_selection", "Select a timeline range first.") }
            items = pieces(in: selectedSpan)
        } else { items = segments }
        guard !items.isEmpty else { throw MCPCommandError("empty_edit", "Add media before exporting.") }
        if let issue = items.compactMap(mediaReviewIssue).first { throw MCPCommandError("source_needs_review", issue) }
        return (items.map(\.request), Self.mediaByURL(items),
                items.map(\.documentID))
    }

    func mcpPictureExportRange() throws -> MulticamRange {
        guard let selectedSpan else { throw MCPCommandError("no_selection", "Select a timeline range first.") }
        return .init(from: selectedSpan.from, to: selectedSpan.to)
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
        guard let clip = segments.first(where: { $0.id == clipID }) else {
            throw MCPCommandError("invalid_target", "Choose an existing clip occurrence.")
        }
        if let issue = mediaReviewIssue(clip) { throw MCPCommandError("source_needs_review", issue) }
        guard let media = clip.source.media else { throw MCPCommandError("source_needs_review", "Recording is offline.") }
        return (clip.source.id, media)
    }
}

extension EditorModel {
    func projectMediaUseID(for id: UUID) -> String? {
        segments.first(where: { $0.id == id })?.documentID ?? edit.inlineStillsByID[id]?.insert.id
    }

    var projectMediaPreviewURL: URL? {
        let time = playhead >= duration ? max(0, playhead.nextDown) : playhead
        let index = projectMediaPicture.lowerBound { $0.interval.to.seconds > time }
        if projectMediaPicture.indices.contains(index), projectMediaPicture[index].interval.from.seconds <= time {
            return projectMediaPicture[index].url
        }
        return locatedSegment(at: time)?.1.source.url
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
        guard let reference = segments.lazy.compactMap({ $0.source.media }).first(where: \.hasVideo),
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
        var timeline = project
        timeline.transcripts = .init()
        timeline.analysisAnnotations = .init()
        timeline.participants = .init()
        projectMediaPicture = []
        guard case .stillSequence(let sequence) = timeline else {
            edit.inlineStillsByID.removeAll()
            edit.stillSequence = nil
            return
        }
        edit.stillSequence = sequence
        loadSoundtrackIfNeeded()
        var cards: [UUID: InlineStill] = [:]
        var clips: [TimelineClip] = []
        var offsets: [RationalTime] = []
        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0) })
        let assets = Dictionary(uniqueKeysWithValues: sequence.stillAssets.map { ($0.id, $0) })
        if !assets.isEmpty, let plan = try? timeline.resolveStills() {
            let ids = Dictionary(uniqueKeysWithValues:
                sequence.stillReplacements.map { ($0.id, $0.assetID) } +
                timeline.stillInserts.map { ($0.id, $0.assetID) })
            projectMediaPicture = plan.spans.compactMap { span in
                guard let placement = span.placementID, let id = ids[placement], let asset = assets[id] else { return nil }
                return (span.output, asset.isGap ? nil : URL(fileURLWithPath: asset.file))
            }
        }
        var cursor = RationalTime.zero
        for item in sequence.items {
            switch item {
            case .source(let clip):
                guard let source = segmentsByID[clip.id], let end = try? cursor.adding(source.duration) else { continue }
                offsets.append(cursor)
                var timelineClip = source.timeline(sequenceRange: cursor.seconds..<end.seconds)
                timelineClip.mediaRevision = refreshDisplayRevisions[source.source.id] ?? 0
                applyMediaPresentation(source, to: &timelineClip)
                clips.append(timelineClip)
                cursor = end
            case .still(let card):
                guard let end = try? cursor.adding(card.duration) else { continue }
                let id = stillTimelineIDs[card.id] ?? UUID()
                stillTimelineIDs[card.id] = id
                cards[id] = InlineStill(insert: card, start: cursor, end: end)
                let asset = assets[card.assetID]
                var thumbnailRevision = Hasher()
                thumbnailRevision.combine(asset)
                thumbnailRevision.combine(card.framing)
                thumbnailRevision.combine(sequence.stillFormat)
                thumbnailRevision.combine(stillReviewCanvas?.videoStream?.displayWidth)
                thumbnailRevision.combine(stillReviewCanvas?.videoStream?.displayHeight)
                let name = asset?.displayName ?? "Still"
                let mediaURL = asset.flatMap { $0.isGap ? nil : URL(fileURLWithPath: $0.file) }
                clips.append(TimelineClip(id: id, sourceID: id, name: name, sourceStart: 0, sourceEnd: card.duration.seconds,
                                          sourceDuration: card.duration.seconds, keyframes: [], thumbnailSyncTimes: [],
                                          frames: [], sequenceRange: cursor.seconds..<end.seconds, isStill: true, isGap: asset?.isGap == true,
                                          mediaRevision: thumbnailRevision.finalize(),
                                          mediaStatus: mediaURL.map { mediaStatus(for: $0) }, mediaURL: mediaURL))
                cursor = end
            }
        }
        edit.inlineStillsByID = cards
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

    func applyStillProjectByHand(_ candidate: CutProject, action: String, landingAfterDeletion: Double? = nil,
                                 installsParticipants: Bool = false) throws {
        let baseline = stillProject
        guard preferences.warnBeforeLoweringExportTier, !isEmpty, candidate != baseline,
              try candidate.exportPlacementScope() != .none, sheetWindow != nil || tierPrompt != nil else {
            try applyStillProject(candidate, action: action, landingAfterDeletion: landingAfterDeletion, installsParticipants: installsParticipants)
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
            let prompt = await sidecarWork.detached(priority: .userInitiated) {
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
                do { try applyStillProject(candidate, action: action, landingAfterDeletion: landingAfterDeletion, installsParticipants: installsParticipants) }
                catch { showStillError(error) }
            }
            guard let prompt else { commit(); resumePendingWork(); return }
            isPresentingPanel = true
            let answer = { [self] (choice: TierPrompt.Choice) in
                guard session == originalSession else { return }
                isPresentingPanel = false
                if choice.dontAskAgain { preferences.suppress(.exportTierDowngrade) }
                if case .proceed = choice.answer { commit() }
                resumePendingWork()
            }
            if let tierPrompt { tierPrompt(prompt, answer) } else { TierPrompt.present(prompt, in: sheetWindow, answer: answer) }
        }
    }

    func applyStillProject(_ candidate: CutProject, action: String, landingAfterDeletion: Double? = nil,
                           installsParticipants: Bool = false) throws {
        guard !isBusy, alert == nil else {
            throw CutError(code: "editor_busy", message: "The editor is busy.")
        }
        guard let clips = candidate.sequenceClips, candidate.stillAudioReference == nil else {
            throw CutError(code: "invalid_still_target", message: "The sequence editor requires an editable sequence project.")
        }
        let project: CutProject
        if candidate.programColorPolicy == nil, !candidate.stillAssets.isEmpty,
           let stream = segments.lazy.compactMap({ $0.source.media }).first(where: \.hasVideo)?.videoStream,
           let color = try? StillProgramColorPolicy.resolving(source: stream) {
            project = try candidate.settingStillColorPolicy(color)
        } else {
            project = candidate
        }
        try project.validate()
        guard project != stillProject else { return }
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0) })
        let proposed = try clips.map { clip -> EditorSegment in
            if var segment = byID[clip.id], segment.source.url.path == clip.file, clip.to <= segment.sourceExtent {
                segment.start = clip.from
                segment.end = clip.to
                segment.tileLayouts = clip.tileLayouts
                return segment
            }
            guard let original = segments.first(where: { $0.source.url.path == clip.file && $0.start <= clip.from && $0.end >= clip.to }) else {
                throw CutError(code: "invalid_still_target", message: "The edit refers to an unknown sequence occurrence.")
            }
            return EditorSegment(documentID: clip.id, source: original.source, start: clip.from, end: clip.to,
                                 displayRange: AudioSpan(from: clip.from, to: max(original.end, original.displayRange?.to ?? original.sourceExtent)),
                                 occurrence: original.occurrence, tileLayouts: clip.tileLayouts)
        }
        cancelTrim()
        let prepared = PreparedEdit(segments: proposed, previous: edit.preparation, engine: CutEngine())
        guard apply(proposed, prepared: prepared, selecting: selectedID, at: landingAfterDeletion ?? playhead, action: action,
                    preserveMarks: landingAfterDeletion == nil, sequenceProject: project, installsParticipants: installsParticipants) else {
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
        let format = sequence.stillFormat
        let reviews = Dictionary(grouping: sequence.analysisAnnotations.pauseReviews, by: \.occurrenceID)
        var excerptReviews: [ProjectPauseReview] = []
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
                excerptReviews += try (reviews[clip.id] ?? []).compactMap {
                    try $0.retained(by: clip.id, within: .init(from: clip.from, to: clip.to))
                }
                return .source(clip)
            case .still(var insert):
                let local = try MulticamRange(from: lower.subtracting(cursor), to: upper.subtracting(cursor))
                excerptReviews += try (reviews[insert.id] ?? []).compactMap { try $0.retained(by: insert.id, within: local, onCard: true) }
                insert.duration = try upper.subtracting(lower)
                if let format, (try? format.frameCount(for: insert.duration)) == nil {
                    insert.usesExactDuration = true
                }
                return .still(insert)
            }
        }
        sequence.analysisAnnotations.pauseReviews = excerptReviews
        if let mapping = try stillProject.stillSoundtrackMapping(in: .init(from: selection.from, to: selection.to)) {
            var clip = mapping.clip
            clip.from = mapping.source.from
            clip.to = mapping.source.to
            sequence.stillSoundtrack = clip
        } else {
            if let soundtrack = sequence.stillSoundtrack, sequence.stillFormat != nil,
               sequence.items.allSatisfy({ $0.still != nil }) {
                sequence.stillAudioReference = soundtrack
            }
            sequence.stillSoundtrack = nil
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
                    guard segment.source.media?.streams.contains(where: { $0.kind == "audio" }) == true else { return nil }
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
    func cacheStillSoundtrackMedia(_ media: MediaInfo) {
        let previous = soundtrackMediaByURL[media.url]
        soundtrackMediaByURL[media.url] = media
        guard stillProject.stillSoundtrack?.file == media.url.path,
              previous?.identity != media.identity else { return }
        objectWillChange.send()
        syncWaveforms()
        restorePreview(at: playhead)
    }

    var currentSoundtrackMedia: MediaInfo? {
        guard let soundtrack = stillProject.stillSoundtrack else { return nil }
        let url = URL(fileURLWithPath: soundtrack.file)
        guard mediaStatus(for: url) == .online else { return nil }
        return soundtrackMediaByURL[url]
    }

    func stillSoundtrackExportIssue(in project: CutProject, tracks: ExportTracks,
                                    audio: ReencodeAudio? = nil) -> CutError? {
        guard tracks != .video, audio != .removeAudio,
              let source = project.stillSoundtrack ?? project.stillAudioReference,
              source.file == stillProject.stillSoundtrack?.file else { return nil }
        let url = URL(fileURLWithPath: source.file)
        let status = mediaStatus(for: url)
        if status != .online {
            return CutError(code: "source_needs_review", message: "Review the soundtrack in Project Media before exporting audio.")
        }
        do { _ = try expectedSoundtrackIdentity(source) }
        catch let issue as CutError { return issue }
        catch {
            return CutError(code: "source_needs_review", message: "Review the soundtrack in Project Media before exporting audio.")
        }
        return nil
    }

    private func expectedSoundtrackIdentity(_ clip: CutSequenceClip) throws -> SourceIdentity? {
        let url = URL(fileURLWithPath: clip.file)
        if let identity = soundtrackMediaByURL[url]?.identity {
            guard identity.isCurrentSnapshot(at: url) else {
                throw CutError(code: "source_changed", message: "The attached soundtrack changed. Review it in Project Media before exporting.")
            }
            return identity
        }
        return try mediaSnapshot.expectedStillSoundtrack(clip,
            relativeTo: projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL)
    }

    var stillSoundtrackControls: StillSoundtrackControls? {
        let project = stillProject
        guard !isBusy, alert == nil, project.stillFormat != nil,
              !project.stillInserts.isEmpty || project.stillSoundtrack != nil,
              project.sequenceClips?.isEmpty == true else { return nil }
        return StillSoundtrackControls(name: project.stillSoundtrack.map { URL(fileURLWithPath: $0.file).lastPathComponent },
            canFit: currentSoundtrackMedia != nil && project.stillInserts.count == 1 &&
                project.stillAssets.contains { $0.id == project.stillInserts[0].assetID && !$0.isGap },
            attach: chooseStillSoundtrack, fit: {
                self.editStill(action: "Fit Image to Soundtrack") { try self.stillProject.fittingStillToSoundtrack() }
            }, remove: {
                self.editStill(action: "Remove Soundtrack") { try self.stillProject.attachingStillSoundtrack(nil) }
            })
    }

    private func chooseStillSoundtrack() {
        let panel = NSOpenPanel()
        panel.title = "Choose Soundtrack"
        panel.allowedContentTypes = [.audio, .movie]
        panel.canChooseDirectories = false
        let generation = mcpGeneration
        let revision = mcpRevision
        isPresentingPanel = true
        ProjectPanels.present(panel, in: editorWindow) { [weak self] accepted in
            guard let self, self.mcpGeneration == generation else { return }
            self.isPresentingPanel = false
            guard accepted, self.mcpRevision == revision, let url = panel.url else {
                self.resumePendingWork()
                return
            }
            self.inspectStillSoundtrack(url, generation: generation, revision: revision)
        }
    }

    private func inspectStillSoundtrack(_ url: URL, generation: UUID, revision: Int) {
        isCheckingEdit = true
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let useSidecar = sidecarPreference.permits(file)
        let helper = sidecarWork.detached(priority: .userInitiated) {
            Result { try CutEngine(useSidecar: useSidecar).inspect(file, keyframes: true) }
        }
        Task {
            let result = await helper.value
            guard self.mcpGeneration == generation else { return }
            self.isCheckingEdit = false
            defer { self.resumePendingWork() }
            guard self.mcpRevision == revision else { return }
            do { try selectStillSoundtrackTrack(result.get(), generation: generation, revision: revision) }
            catch { showStillError(error) }
        }
    }

    private func selectStillSoundtrackTrack(_ media: MediaInfo, generation: UUID, revision: Int) {
        let tracks = media.streams.filter { $0.kind == "audio" }
        let attach: (Int?) -> Void = { [weak self = self] stream in
            guard let self, self.mcpGeneration == generation, self.mcpRevision == revision else { return }
            do {
                guard media.identity.isCurrentSnapshot(at: media.url) else {
                    throw CutError(code: "source_changed", message: "The soundtrack changed while it was being selected. Choose the file again.")
                }
                let reference = try StillSoundtrack.reference(media: media, stream: stream)
                let project = try self.stillProject.attachingStillSoundtrack(reference)
                self.cacheStillSoundtrackMedia(media)
                try self.applyStillProjectByHand(project, action: "Attach Soundtrack")
            } catch { self.showStillError(error) }
        }
        if tracks.count > 1 {
            let picker = NSPopUpButton()
            picker.addItems(withTitles: tracks.map(\.exportLabel))
            self.isPresentingPanel = true
            StillPanels.present(title: "Choose Soundtrack Track", fields: [("Audio track", picker)], in: self.editorWindow,
                                dismissed: { [weak self = self] in
                guard let self, self.mcpGeneration == generation else { return }
                self.isPresentingPanel = false
                Task { self.resumePendingWork() }
            }) {
                guard tracks.indices.contains(picker.indexOfSelectedItem) else { return }
                attach(tracks[picker.indexOfSelectedItem].index)
            }
        } else { attach(tracks.first?.index) }
    }

    private func indexedSoundtrack(for clip: CutSequenceClip) throws -> MediaInfo {
        let url = URL(fileURLWithPath: clip.file)
        let status = mediaStatus(for: url)
        guard status != .changed, status != .needsReview, status != .offline, status != .ignored else {
            throw CutError(code: "source_needs_review", message: "Review the soundtrack in Project Media before queueing this range.")
        }
        if let media = soundtrackMediaByURL[url] {
            guard media.identity.isCurrentSnapshot(at: url) else {
                throw CutError(code: "source_changed", message: "\(url.lastPathComponent) changed after the soundtrack was opened.")
            }
            return media
        }
        try checkLiveMediaVolume(url, volumes: interchangeCheckingVolumes)
        let expected = try expectedSoundtrackIdentity(clip)
        let media = try CutEngine(useSidecar: useAnalysisSidecars).inspect(url, keyframes: true)
        guard expected.map({ $0.matchesSnapshot(media.identity) }) ?? true else {
            throw CutError(code: "source_changed", message: "The attached soundtrack changed during queue capture.")
        }
        return media
    }

    private func loadSoundtrackIfNeeded() {
        guard let clip = stillProject.stillSoundtrack else { return }
        let url = URL(fileURLWithPath: clip.file)
        guard soundtrackMediaByURL[url] == nil, soundtrackIndexes[url] == nil,
              mediaStatus(for: url) == .online else { return }
        let token = UUID()
        soundtrackIndexes[url] = token
        let useSidecar = useAnalysisSidecars
        let task = sidecarWork.detached(priority: .utility) {
            try? CutEngine(useSidecar: useSidecar).inspect(url, keyframes: true)
        }
        Task { [weak self] in
            let result = await task.value
            guard let self, self.soundtrackIndexes[url] == token else { return }
            self.soundtrackIndexes[url] = nil
            if self.soundtrackMediaByURL[url] == nil, let result {
                do { _ = try self.expectedSoundtrackIdentity(clip) }
                catch {
                    self.incompatibleMedia.insert(ProjectMediaVolume.watchURL(url))
                }
                self.cacheStillSoundtrackMedia(result.forRefreshAlias(url))
            }
        }
    }

    var canReplacePicture: Bool { canEdit && selectedSpan != nil && segments.contains { $0.source.media?.hasVideo == true && mediaReviewIssue($0) == nil } }
    var canInsertStill: Bool { !isBusy && alert == nil && (isEmpty || hasPicture) }

    var stillAssetSpans: [MulticamAssetSpan] {
        let project = stillProject
        guard !project.stillAssets.isEmpty, let plan = try? project.resolveStills() else { return [] }
        let assets = Dictionary(uniqueKeysWithValues: project.stillAssets.filter { !$0.isGap }.map { ($0.id, $0) })
        let assetIDs = Dictionary(uniqueKeysWithValues:
            project.stillReplacements.map { ($0.id, $0.assetID) } + project.stillInserts.map { ($0.id, $0.assetID) })
        return plan.spans.enumerated().compactMap { index, span in
            guard let id = span.placementID, let assetID = assetIDs[id], let asset = assets[assetID] else { return nil }
            let url = URL(fileURLWithPath: asset.file)
            return MulticamAssetSpan(id: "\(id)-\(index)", title: asset.displayName, interval: span.output,
                                     mediaURL: url, mediaStatus: mediaStatus(for: url))
        }
    }

    var stillPlacementRows: [StillPlacementRow] {
        guard !stillProject.stillInserts.isEmpty || !stillProject.stillReplacements.isEmpty else { return [] }
        let assets = Dictionary(uniqueKeysWithValues: stillProject.stillAssets.map { ($0.id, $0) })
        func name(_ id: String) -> String {
            guard let asset = assets[id] else { return "Missing image" }
            return asset.displayName
        }
        func status(_ id: String) -> ProjectMediaStatus {
            guard let asset = assets[id], !asset.isGap else { return .online }
            return mediaStatus(for: URL(fileURLWithPath: asset.file))
        }
        func framing(_ frame: StillImageFraming) -> String { frame.mode == .fit ? "Fit" : "Fill" }
        var result = inlineStills(in: stillProject).map { card in
            StillPlacementRow(id: card.insert.id, title: "Insert · \(name(card.insert.assetID))",
                              details: "Sequence \(card.start)–\(card.end) s · \(card.insert.duration) s · \(framing(card.insert.framing))",
                              isInsert: true, isGap: assets[card.insert.assetID]?.isGap == true,
                              mediaStatus: status(card.insert.assetID))
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
                                     fragmentCount: fragmentCount, mediaStatus: status(replacement.assetID))
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

    var canSpaceClips: Bool { canInsertStill && stillProject.hasSpacingBoundaries }

    func chooseSpaceClips() {
        guard canSpaceClips else { return }
        preview.pause()
        let revision = mcpRevision
        StillPanels.spaceClips(cadence: stillCadence, seconds: preferences.gapDuration, color: preferences.gapColor,
                               in: editorWindow) { [weak self] timing, cadence, background in
            guard let self, self.mcpRevision == revision, self.canSpaceClips else { return }
            do {
                let result = try timing.applying(to: self.stillProject, cadence: cadence, background: background,
                                                 relativeTo: self.projectURL ?? self.draft.url)
                try self.applyStillProjectByHand(result, action: "Space Clips")
            } catch { self.showStillError(error) }
        }
    }

    func chooseInsertGap() {
        guard canInsertStill else { return }
        preview.pause()
        do {
            let position = try stillBoundary(at: playhead)
            let revision = mcpRevision
            func choose(_ format: StillTimelineFormat?, _ policy: StillProgramColorPolicy?) {
                let cadence = format?.cadence ?? stillCadence
                StillPanels.gap(cadence: cadence, seconds: self.preferences.gapDuration, color: self.preferences.gapColor,
                                in: editorWindow) { [weak self] duration, interval, framing in
                    guard let self, self.mcpRevision == revision, self.canInsertStill else { return }
                    do {
                        if let cadence, interval != cadence {
                            throw CutError(code: "invalid_still_cadence", message: "Use the sequence’s frame rate for this gap.")
                        }
                        let asset = self.stillProject.stillAssets.first(where: \.isGap) ?? StillAsset(gapID: ProjectIdentifier.make(avoiding: self.stillProject.stillAssets.map(\.id)))
                        let id = ProjectIdentifier.make()
                        let result: CutProject
                        if let format {
                            result = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: id,
                                duration: duration, framing: framing, colorPolicy: policy ?? StillTimelineFormat.sdrColorPolicy)
                        } else {
                            let gap = StillInsert(id: id, assetID: asset.id, duration: duration, cadence: interval, framing: framing)
                            result = try self.stillProject.addingStillAsset(asset).insertingStill(gap, at: position)
                        }
                        try self.applyStillProjectByHand(result, action: "Insert Color Gap")
                    } catch { self.showStillError(error) }
                }
            }
            if isEmpty, stillProject.stillFormat == nil {
                StillPanels.format(defaults: StillTimelineFormatDefaults(preferences: preferences), in: editorWindow) { format, policy in
                    guard self.mcpRevision == revision else { return }
                    choose(format, policy)
                }
            } else { choose(nil, nil) }
        } catch { showStillError(error) }
    }

    func chooseInsertStill() {
        guard canInsertStill else { return }
        preview.pause()
        let position = playhead
        chooseStillImage { [weak self] url in self?.addDroppedStills([url], at: position) }
    }

    private func chooseStillImage(_ completion: @escaping (URL) -> Void) {
        guard !isBusy else { return }
        let generation = mcpGeneration
        let revision = mcpRevision
        isPresentingPanel = true
        // Clear the busy flag on cancellation as well as selection.
        StillPanels.chooseImage(in: editorWindow, dismissed: { [weak self] in
            guard let self, self.mcpGeneration == generation else { return }
            self.isPresentingPanel = false
            DispatchQueue.main.async { self.resumePendingWork() }
        }) { [weak self] url in
            guard let self, self.mcpGeneration == generation, self.mcpRevision == revision else { return }
            completion(url)
        }
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
                Result { try StillPanels.assets(for: urls, existing: existing) }
            }.value
            guard mcpGeneration == generation else { return }
            isCheckingEdit = false
            guard mcpRevision == revision else {
                showStillError(CutError(code: "stale_revision", message: "The timeline changed while reading the images."))
                return
            }
            do {
                let assets = try result.get()
                try completion(assets)
                preferences.recentFiles.record(urls)
            }
            catch { showStillError(error) }
            resumePendingWork()
        }
    }

    private func replacePicture(with url: URL, in range: AudioSpan) {
        inspectImages([url]) { assets in
            let asset = assets[0]
            let project = try self.project(with: asset).replacingPicture(
                id: ProjectIdentifier.make(), assetID: asset.id, from: range.from, to: range.to
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
                StillPanels.format(defaults: StillTimelineFormatDefaults(preferences: preferences), in: editorWindow) { [weak self] format, colorPolicy in
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
        let (initial, interval) = StillPanels.startingDuration(seconds: preferences.stillDuration, cadence: cadence)
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
                    let id = ProjectIdentifier.make()
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
        let mediaByClip = Dictionary(uniqueKeysWithValues: segments.compactMap { clip in
            clip.source.media.map { (clip.documentID, $0) }
        })
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
                              let media = clip.source.media, self.mediaReviewIssue(clip) == nil,
                              time >= .zero, time <= media.duration, time != media.duration else { return time }
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
            StillPanels.frame(title: "Still Framing", framing: framing, gap: row.isGap, in: editorWindow) { [weak self] framing in
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
            copy.id = ProjectIdentifier.make()
            editStill(action: "Duplicate Still") { try stillProject.insertingStill(copy, at: card.end) }
        case .detach: return
        case .remove:
            editStill(action: "Delete Still") { try stillProject.removingStill(id: row.id) }
        case .relink:
            guard let asset = stillProject.stillAssets.first(where: { $0.id == assetID && !$0.isGap }) else { return }
            presentProjectMedia(.locate, path: asset.file)
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
        let slot = max(0, slot)
        let sourceSlot = (stillProject.sequenceItems ?? []).prefix(slot).compactMap(\.source).count
        importFiles(urls, at: sourceSlot, timelineSlot: slot)
    }
}

extension EditorModel {
    var canRefreshProjectMedia: Bool {
        guard !isBusy, !isSavingSidecars, !mcpHasActiveTrim, alert == nil, mediaRelinkIndexing.isEmpty else { return false }
        return !segments.isEmpty || !transcriptProject.mediaPaths.isEmpty || !queuedMediaTargets.presenceOnlyByURL.isEmpty
    }

    func refreshProjectMedia(deep: Bool = false, receipt: MCPAnalysisReceipt? = nil) {
        updateMediaWatcher()
        _ = refreshProjectMedia(deep: deep, verify: [], receipt: receipt)
    }

    private func currentMediaTargets() -> [URL: Bool] {
        let location = projectURL ?? openingProjectURL ?? draft.url ?? URL(fileURLWithPath: "/Untitled.cut", isDirectory: false)
        return transcriptProject.mediaRefreshTargets(relativeTo: location)
            .merging(queuedMediaTargets.presenceOnlyByURL) { $0 && $1 }
    }

    func mediaStatus(for url: URL) -> ProjectMediaStatus {
        mediaStatus(for: url, includingUnresolved: true)
    }

    private func mediaStatus(for url: URL, includingUnresolved: Bool) -> ProjectMediaStatus {
        let url = ProjectMediaVolume.watchURL(url)
        if mediaRelinkIndexing.contains(url) { return .indexing }
        if let status = mediaWatcher?.status(for: url), status == .checking || status == .offline || status == .changed {
            return status == .offline && ignoredMediaPaths.contains(url.path)
                ? .ignored : status
        }
        if includingUnresolved, let status = edit.preparation.unresolvedStatusByURL[url] {
            return status == .offline && ignoredMediaPaths.contains(url.path)
                ? .ignored : status
        }
        if offlineMedia.contains(url) {
            return ignoredMediaPaths.contains(url.path) ? .ignored : .offline
        }
        if incompatibleMedia.contains(url) || refreshReviewPicture.contains(url) || !(refreshReviewStreams[url] ?? []).isEmpty {
            return .needsReview
        }
        return mediaWatcher?.status(for: url) ?? .online
    }

    private func preparedForMediaAvailability(_ segments: [EditorSegment], using previous: PreparedEdit) -> PreparedEdit {
        let unavailable = Set(previous.sourceMedia.compactMap { id, media in
            let status = mediaStatus(for: media.url, includingUnresolved: false)
            return status == .offline || status == .ignored || status == .checking ? id : nil
        })
        guard unavailable != previous.unavailableSourceIDs else { return previous }
        return PreparedEdit(segments: segments, previous: previous, engine: CutEngine(), excluding: unavailable)
    }

    private func updateMediaWatcher() {
        if mediaWatcher == nil {
            mediaWatcher = ProjectMediaWatcher(publish: { [weak self] urls in
                guard let self else { return }
                self.objectWillChange.send()
                self.invalidateQueuedMedia(at: Set(urls.filter {
                    let status = self.mediaStatus(for: $0)
                    return status == .offline || status == .changed || status == .ignored
                }))
                var touchedStills = self.refreshStillMediaPresentation(for: urls)
                if let soundtrack = self.stillProject.stillSoundtrack,
                   urls.contains(ProjectMediaVolume.watchURL(URL(fileURLWithPath: soundtrack.file))) {
                    self.loadSoundtrackIfNeeded()
                    self.syncWaveforms()
                    touchedStills = true
                }
                guard self.segments.contains(where: { urls.contains(ProjectMediaVolume.watchURL($0.source.url)) }) else {
                    if touchedStills { self.restorePreview(at: self.playhead) }
                    return
                }
                let previous = self.edit.preparation
                let prepared = self.preparedForMediaAvailability(self.segments, using: previous)
                let availabilityChanged = previous.unavailableSourceIDs != prepared.unavailableSourceIDs
                if availabilityChanged {
                    self.edit.preparation = prepared
                    if previous.container != prepared.container { self.copyBoundaryIndices.removeAll() }
                    self.trimChecks.removeAll()
                    self.fixedTrimIssue = nil
                    self.prepareCopyBoundaries()
                }
                var clips = self.edit.timelineClips
                var presentationChanged = false
                var reviewChanged = false
                let segments = Dictionary(uniqueKeysWithValues: self.segments.map { ($0.id, $0) })
                for index in clips.indices {
                    guard let segment = segments[clips[index].id], urls.contains(ProjectMediaVolume.watchURL(segment.source.url)) else { continue }
                    let previousStatus = clips[index].mediaStatus
                    let previousIssue = clips[index].mediaIssue
                    self.applyMediaPresentation(segment, to: &clips[index])
                    if clips[index].mediaStatus != previousStatus { presentationChanged = true }
                    if clips[index].mediaIssue != previousIssue { reviewChanged = true }
                }
                if presentationChanged || reviewChanged { self.edit.timelineClips = clips }
                if reviewChanged {
                    self.mediaClipReview = Dictionary(uniqueKeysWithValues: clips.compactMap { clip in
                        clip.mediaIssue.map { (clip.id, $0) }
                    })
                    self.syncWaveforms()
                }
                if reviewChanged || touchedStills { self.restorePreview(at: self.playhead) }
                if reviewChanged || availabilityChanged { self.refreshTier() }
            }, refresh: { [weak self] urls, verify in
                guard let self else { return true }
                var sources = self.segments.map { ProjectMediaVolume.watchURL($0.source.url) }
                if let soundtrack = self.stillProject.stillSoundtrack {
                    sources.append(ProjectMediaVolume.watchURL(URL(fileURLWithPath: soundtrack.file)))
                }
                let recordings = urls.intersection(sources)
                guard !recordings.isEmpty else { return true }
                return self.refreshProjectMedia(deep: false, verify: verify, receipt: nil, only: recordings)
            })
        }
        var expected = queuedMediaTargets.indexed.mapValues(\.identity)
        if let clip = stillProject.stillSoundtrack,
           let media = soundtrackMediaByURL[URL(fileURLWithPath: clip.file)] {
            expected[ProjectMediaVolume.watchURL(media.url)] = media.identity
        }
        for clip in segments {
            if let media = clip.source.media { expected[ProjectMediaVolume.watchURL(media.url)] = media.identity }
        }
        let unresolved = Set(segments.compactMap { segment in
            segment.source.unresolved?.status == .offline ? ProjectMediaVolume.watchURL(segment.source.url) : nil
        })
        mediaWatcher?.update(Set(currentMediaTargets().keys), expected: expected, assumedOffline: unresolved,
                             perFile: preferences.automaticallyRefreshMedia)
    }

    private func refreshProjectMedia(deep: Bool, verify: Set<URL>, receipt: MCPAnalysisReceipt?, only: Set<URL>? = nil) -> Bool {
        guard canRefreshProjectMedia else {
            receipt?.finish("failed", detail: ["error": "Finish the current project operation before refreshing media."])
            return false
        }
        var inputs = [URL: ProjectMediaRefreshInput]()
        func add(_ url: URL, media: MediaInfo? = nil, requiresIndex: Bool = false, presenceOnly: Bool = false) {
            let url = ProjectMediaVolume.watchURL(url)
            guard only?.contains(url) != false, mediaWatcher?.status(for: url) != .checking else { return }
            inputs[url] = ProjectMediaRefreshInput(url: url, previous: inputs[url]?.previous ?? media ?? refreshBaselines[url] ?? queuedMediaTargets.indexed[url],
                                                   requiresIndex: requiresIndex || inputs[url]?.requiresIndex == true,
                                                   presenceOnly: (inputs[url]?.presenceOnly ?? true) && presenceOnly)
        }
        for clip in segments { add(clip.source.url, media: clip.source.media, requiresIndex: clip.source.unresolved != nil) }
        if let soundtrack = stillProject.stillSoundtrack {
            let url = URL(fileURLWithPath: soundtrack.file)
            add(url, media: soundtrackMediaByURL[url], requiresIndex: true)
        }
        for (url, presenceOnly) in currentMediaTargets() { add(url, presenceOnly: presenceOnly) }
        guard !inputs.isEmpty else {
            receipt?.finish("failed", detail: ["error": "No recordings are referenced by this project."])
            return false
        }
        mediaRefreshProgress = 0
        statusMessage = "Refreshing project media…"
        let previewSources = Set(segments.lazy.filter { $0.source.media?.hasVideo == true }.map { $0.source.url.standardizedFileURL })
        mediaRefresh.start(inputs: Array(inputs.values), deep: deep, verify: verify.union(offlineMedia), persist: useAnalysisSidecars,
                           project: projectURL, exclusions: sidecarExclusions, receipt: receipt, previewSources: previewSources,
                           preview: { [weak self] media, aliases in
            self?.previewRefreshedFilmstrip(media, aliases: aliases)
        }, progress: { [weak self] in
            self?.mediaRefreshProgress = $0
        }, publish: { [weak self] result, aliases, _, identity in
            self?.mediaWatcher?.noteVerified(aliases, identity: identity)
            if self?.refreshStillMediaPresentation(for: aliases) == true, let self { self.restorePreview(at: self.playhead) }
            self?.installMediaRefresh(result, aliases: aliases)
            self?.objectWillChange.send()
        }, finished: { [weak self] message in
            guard let self else { return }
            if !self.refreshFilmstrips.isEmpty { self.refreshFilmstrips.removeAll() }
            self.mediaRefreshProgress = nil
            if only == nil { self.mediaWatcher?.checkNow() }
            self.statusMessage = message
            self.resumePendingWork()
        })
        return true
    }

    var readyQueuedRanges: [QueuedRange] {
        queuedRanges.filter { !invalidatedQueueIDs.contains($0.id) }
    }

    func invalidateQueuedMedia(at paths: Set<URL>) {
        guard !paths.isEmpty, !queuedRanges.isEmpty else { return }
        let keys = Set(paths.map(ProjectMediaVolume.watchURL))
        let affected = readyQueuedRanges.filter { entry in
            entry.mediaDependencies.contains { keys.contains(ProjectMediaVolume.watchURL($0)) }
        }.map(\.id)
        if !affected.isEmpty { invalidatedQueueIDs.formUnion(affected) }
    }

    @discardableResult
    private func refreshStillMediaPresentation(for urls: Set<URL>) -> Bool {
        let keys = Set(urls.map(ProjectMediaVolume.watchURL))
        let changed = edit.timelineClips.indices.filter { index in
            let clip = edit.timelineClips[index]
            return clip.isStill && clip.mediaURL.map { keys.contains(ProjectMediaVolume.watchURL($0)) } == true
        }
        for index in changed {
            guard let url = edit.timelineClips[index].mediaURL else { continue }
            let status = mediaStatus(for: url)
            if edit.timelineClips[index].mediaStatus != status {
                edit.timelineClips[index].mediaStatus = status
                edit.timelineClips[index].mediaRevision &+= 1
            }
        }
        return !changed.isEmpty || stillAssetSpans.contains {
            $0.mediaURL.map { keys.contains(ProjectMediaVolume.watchURL($0)) } == true
        }
    }

    private func applyMediaPresentation(_ segment: EditorSegment, to clip: inout TimelineClip) {
        let issue = mediaReviewIssue(segment)
        let observed = mediaStatus(for: segment.source.url, includingUnresolved: segment.source.unresolved != nil)
        let status: ProjectMediaStatus
        switch observed {
        case .checking, .offline, .ignored, .indexing: status = observed
        default: status = segment.source.unresolved?.status ?? (observed == .needsReview && issue == nil ? .online : observed)
        }
        clip.mediaIssue = issue
        clip.mediaStatus = status == .online && issue != nil ? .needsReview : status
        clip.mediaURL = segment.source.url
    }

    func unresolvedMediaStatus(for url: URL) -> ProjectMediaStatus? {
        edit.preparation.unresolvedStatusByURL[ProjectMediaVolume.watchURL(url)]
    }

    private func mediaReviewIssue(_ clip: EditorSegment) -> String? {
        let source = clip.source
        let status = mediaStatus(for: source.url, includingUnresolved: source.unresolved != nil)
        let reviewPrompt = " Open Project Media to review this recording."
        if status == .checking { return "\(source.name) — checking the recording’s volume.\(reviewPrompt)" }
        if let unresolved = source.unresolved { return "\(source.name) — \(unresolved.detail)\(reviewPrompt)" }
        if status == .offline || status == .ignored { return "\(source.name) — recording is offline.\(reviewPrompt)" }
        guard let media = source.media else { return nil }
        guard let revision = refreshSourceRevisions[source.id], revision > 0 else { return nil }
        if clip.end > media.duration || clip.start < .zero {
            return "\(source.name) — a saved trim extends past the refreshed recording.\(reviewPrompt)"
        }
        if stillProject.stillReplacements.contains(where: { replacement in
            guard case .sequence(let fragments) = replacement.coverage else { return false }
            return fragments.contains { $0.clipID == clip.documentID && $0.range.to > media.duration }
        }) {
            return "\(source.name) — a saved still replacement extends past the refreshed recording.\(reviewPrompt)"
        }
        if incompatibleMedia.contains(source.url) { return "\(source.name) — the recording type changed.\(reviewPrompt)" }
        if refreshReviewPicture.contains(source.url) {
            return "\(source.name) — the picture track could not be verified.\(reviewPrompt)"
        }
        let audio = media.streams.filter { $0.kind == "audio" }
        if source.replacementNames.keys.contains(where: { !audio.indices.contains($0) }) {
            return "\(source.name) — a named audio track is missing.\(reviewPrompt)"
        }
        let explicitSelection = audioMonitoringTrack ?? source.replacementTrack
        let review = refreshReviewStreams[source.url] ?? []
        let selected = explicitSelection ?? (media.hasVideo && audio.isEmpty && review.isEmpty ? nil : 0)
        if let selected {
            guard audio.indices.contains(selected), !review.contains(audio[selected].index) else {
                return "\(source.name) — the selected audio track changed or is missing.\(reviewPrompt)"
            }
            if (explicitSelection != nil || !media.hasVideo),
               let track = media.audio.first(where: { $0.stream.index == audio[selected].index }),
               clip.start < track.start || clip.end > track.end {
                return "\(source.name) — a saved trim extends past the refreshed audio track.\(reviewPrompt)"
            }
        }
        return nil
    }

    private func previewRefreshedFilmstrip(_ media: MediaInfo, aliases: Set<URL>) {
        guard media.timelineIssue == nil, let replacement = media.videoStream else { return }
        var drafts = refreshFilmstrips
        for source in edit.preparation.sourceMedia where aliases.contains(ProjectMediaVolume.watchURL(source.value.url)) {
            let id = source.key
            let before = source.value
            let clips = edit.timelineClips.filter { $0.sourceID == id }
            guard !clips.isEmpty, let picture = before.videoStream,
                  media.origin == before.origin,
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
        let url = ProjectMediaVolume.watchURL(result.source)
        func matches(_ candidate: URL) -> Bool { aliases.contains(ProjectMediaVolume.watchURL(candidate)) }
        let history = (undoStack + redoStack).flatMap { state -> [EditorSegment] in
            if case .live(let snapshot) = state.contents { return snapshot.segments }
            return []
        }
        let sources = (segments + history).map(\.source).filter { matches($0.url) }
        if let clip = stillProject.stillSoundtrack {
            let soundtrack = URL(fileURLWithPath: clip.file)
            if matches(soundtrack) {
                if let media = result.media {
                    soundtrackMediaByURL[soundtrack] = media.forRefreshAlias(soundtrack)
                    incompatibleMedia.remove(ProjectMediaVolume.watchURL(soundtrack))
                    let tracks = media.streams.filter { $0.kind == "audio" }
                    let ordinal = clip.audioTrack ?? 0
                    if tracks.indices.contains(ordinal) {
                        let stream = tracks[ordinal].index
                        let valid = (try? StillSoundtrack.reference(media: media, stream: stream, from: clip.from, to: clip.to)) != nil
                        refreshReviewStreams[ProjectMediaVolume.watchURL(soundtrack)] =
                            valid && !result.reviewStreams.contains(stream) ? nil : [stream]
                    } else {
                        incompatibleMedia.insert(ProjectMediaVolume.watchURL(soundtrack))
                    }
                } else if result.state == .offline {
                    soundtrackMediaByURL[soundtrack] = nil
                }
                syncWaveforms()
                restorePreview(at: playhead)
                refreshTier()
            }
        }
        let sourceIDs = Set(sources.map(\.id))
        let drafts = refreshFilmstrips.filter { sourceIDs.contains($0.key) }
        if !drafts.isEmpty { refreshFilmstrips = refreshFilmstrips.filter { !sourceIDs.contains($0.key) } }
        if let media = result.media {
            for alias in aliases {
                let item = media.forRefreshAlias(alias)
                refreshBaselines[alias] = item
                if alias == alias.standardizedFileURL {
                    SourceIndexLoader.shared.acceptRefreshedIndex(item, sidecars: sidecarPreference.permits(alias), project: projectURL)
                }
            }
        }
        if result.state == .unchanged, edit.preparation.unavailableSourceIDs.isDisjoint(with: sourceIDs),
           sources.allSatisfy({ $0.unresolved == nil && !offlineMedia.contains($0.url) }) { return }
        if result.state == .offline {
            for source in sources { offlineMedia.insert(source.url) }
        } else {
            offlineMedia.remove(url)
            for source in sources { offlineMedia.remove(source.url) }
        }
        invalidateQueuedMedia(at: aliases.union([url]))
        let recoveredUnresolvedSource = result.media != nil && sources.contains { $0.unresolved != nil }
        let replacePicture = result.displayChanged || result.state == .offline || recoveredUnresolvedSource
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
            if result.scenesPreserved, let source, let media = result.media?.forRefreshAlias(source.url) ?? source.media {
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
                let oldAudio = source.media?.streams.filter { $0.kind == "audio" } ?? []
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
        var mismatchedSources: [UUID: UnresolvedSource] = [:]
        if let media = result.media {
            let newAudio = media.streams.filter { $0.kind == "audio" }
            let unique = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let currentIDs = Set(segments.map { $0.source.id })
            let referenceHasPicture = segments.lazy.compactMap { clip in
                sourceIDs.contains(clip.source.id) ? nil : clip.source.media?.hasVideo
            }.first
            for (id, source) in unique {
                refreshReviewStreams[source.url, default: []].formUnion(result.reviewStreams)
                if result.pictureNeedsReview { refreshReviewPicture.insert(source.url) }
                let expectedPicture = source.media?.hasVideo ?? source.unresolved?.hasPicture
                    ?? (currentIDs.contains(id) ? referenceHasPicture : nil)
                if let expectedPicture, media.hasVideo != expectedPicture {
                    incompatibleMedia.insert(source.url)
                    if let unresolved = source.unresolved {
                        mismatchedSources[id] = UnresolvedSource(
                            id: id, url: source.url, originalURL: source.originalURL, replacementNames: source.replacementNames,
                            replacementTrack: source.replacementTrack, status: .needsReview,
                            detail: "The recording type changed.", snapshot: unresolved.snapshot
                        )
                    }
                    continue
                }
                incompatibleMedia.remove(source.url)
                let oldAudio = source.media?.streams.filter { $0.kind == "audio" } ?? []
                for ordinal in oldAudio.indices {
                    guard newAudio.indices.contains(ordinal), newAudio[ordinal].index != oldAudio[ordinal].index else { continue }
                    refreshReviewStreams[source.url, default: []].insert(newAudio[ordinal].index)
                }
                replacements[id] = IndexedSource(media: sidecarPreference.attachingDocument(to: media.forRefreshAlias(source.url)), id: id,
                                                 originalURL: source.originalURL, replacementNames: source.replacementNames,
                                                 replacementTrack: source.replacementTrack)
            }
        }
        func refresh(_ snapshot: EditSnapshot) -> EditSnapshot {
            guard snapshot.segments.contains(where: { sourceIDs.contains($0.source.id) }) else { return snapshot }
            var updated = snapshot
            let timelineIndices = Dictionary(uniqueKeysWithValues: snapshot.timelineClips.enumerated().map { ($0.element.id, $0.offset) })
            let stillFragmentEnds = Self.requiredStillFragmentEnds(snapshot.stillSequence?.stillReplacements ?? [])
            for index in updated.segments.indices where sourceIDs.contains(updated.segments[index].source.id) {
                let previous = updated.segments[index]
                let sourceID = previous.source.id
                let requiredEnd = max(previous.end, stillFragmentEnds[previous.documentID] ?? .zero)
                if let source = replacements[sourceID], previous.source.unresolved == nil || requiredEnd <= source.duration {
                    updated.segments[index].source = .resolved(source)
                } else if let source = mismatchedSources[sourceID] {
                    updated.segments[index].source = .unresolved(source)
                }
                let segment = updated.segments[index]
                guard let timelineIndex = timelineIndices[segment.id] else { continue }
                var clip = updated.timelineClips[timelineIndex]
                if replacePicture { clip = segment.timeline(sequenceRange: clip.sequenceRange ?? 0..<0) }
                clip.mediaRevision = refreshDisplayRevisions[segment.source.id] ?? 0
                applyMediaPresentation(segment, to: &clip)
                updated.timelineClips[timelineIndex] = clip
            }
            if replacePicture {
                updated.timelineThumbnailHeight = updated.timelineClips.lazy.map(\.thumbnailHeight).max() ?? TimelineClip.minimumThumbnailHeight
                updated.largeThumbnailHeight = updated.timelineClips.lazy.map { $0.thumbnailHeight(large: true) }.max() ?? TimelineClip.minimumLargeThumbnailHeight
            }
            if result.media != nil {
                updated.preparation = PreparedEdit(segments: updated.segments, previous: PreparedEdit(), engine: CutEngine())
            }
            updated.preparation = preparedForMediaAvailability(updated.segments, using: updated.preparation)
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
        guard edit.segments.contains(where: { sourceIDs.contains($0.source.id) }) else { return }
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

extension EditorModel {
    private var transcriptSourceSegments: [EditorSegment] {
        var result = segments
        for entry in (undoStack + redoStack).reversed() {
            if case .live(let snapshot) = entry.contents {
                result.append(contentsOf: snapshot.segments)
            }
        }
        return result
    }

    var transcriptMedia: [String: MediaInfo] {
        Dictionary(segments.compactMap { clip in clip.source.media.map { ($0.url.path, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    func transcriptMediaInfo(for file: String) throws -> MediaInfo {
        let url = URL(fileURLWithPath: file).standardizedFileURL
        return try transcriptMedia[url.path] ?? SidecarLocations.$projectURL.withValue(projectURL) {
            try CutEngine(useSidecar: useAnalysisSidecars).inspectForPreview(url)
        }
    }

    func setTranscriptMarks(_ range: MulticamRange) throws {
        guard canEdit, range.from >= .zero, range.from < range.to, range.to <= edit.duration else {
            throw CutError(code: "invalid_transcript_selection", message: "The range is outside the editable sequence.")
        }
        preview.pause()
        var selection = edit
        selection.markIn = range.from
        selection.markOut = range.to
        selection.pointerMarkIn = true
        selection.pointerMarkOut = true
        edit = selection
        rebuildPausePlan()
    }

    func applyTranscriptProject(_ candidate: CutProject, action: String) throws {
        guard !isBusy, alert == nil, let clips = candidate.sequenceClips else {
            throw CutError(code: "editor_busy", message: "The sequence is unavailable for an edit.")
        }
        try candidate.validate()
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.documentID, $0) })
        func sourceKey(_ segment: EditorSegment) -> DocumentSourceKey {
            DocumentSourceKey(file: segment.source.url, original: segment.source.originalURL,
                              track: segment.source.replacementTrack, names: segment.source.replacementNames)
        }
        var media = Dictionary(transcriptSourceSegments.map { (sourceKey($0), $0) },
                               uniquingKeysWith: { first, _ in first })
        let proposed = try clips.map { clip -> EditorSegment in
            let file = URL(fileURLWithPath: clip.file).standardizedFileURL
            let original = URL(fileURLWithPath: clip.originalFile ?? clip.file).standardizedFileURL
            let key = DocumentSourceKey(file: file, original: original, track: clip.audioTrack, names: clip.replacementNames)
            let backing: EditorSegment
            let sameOccurrence = byID[clip.id].flatMap { sourceKey($0) == key ? $0 : nil }
            if let existing = sameOccurrence ?? media[key] {
                guard existing.source.media?.identity.isCurrentSnapshot(at: file) == true else {
                    throw CutError(code: "source_changed", message: "\(file.lastPathComponent) changed after the transcript edit was reviewed.")
                }
                backing = existing
            } else {
                let index = try SidecarLocations.$projectURL.withValue(projectURL) {
                    try CutEngine(useSidecar: useAnalysisSidecars).inspect(file, keyframes: true)
                }
                let source = IndexedSource(media: sidecarPreference.attachingDocument(to: index), originalURL: original,
                                           replacementNames: clip.replacementNames, replacementTrack: clip.audioTrack)
                backing = EditorSegment(source: source)
                media[key] = backing
            }
            guard clip.to <= backing.sourceExtent else {
                throw CutError(code: "source_unavailable", message: "The selected passage extends past \(file.lastPathComponent).")
            }
            if var existing = byID[clip.id], existing.source.id == backing.source.id {
                existing.start = clip.from
                existing.end = clip.to
                existing.tileLayouts = clip.tileLayouts
                return existing
            }
            return EditorSegment(documentID: clip.id, source: backing.source, start: clip.from, end: clip.to,
                                 displayRange: AudioSpan(from: .zero, to: backing.sourceExtent),
                                 occurrence: backing.occurrence, tileLayouts: clip.tileLayouts)
        }
        cancelTrim()
        let prepared = PreparedEdit(segments: proposed, previous: edit.preparation, engine: CutEngine())
        let selected = proposed.first(where: { $0.id == selectedID })?.id ?? proposed.first?.id
        guard apply(proposed, prepared: prepared, selecting: selected, at: playhead, action: action,
                    preserveMarks: true, sequenceProject: candidate) else {
            throw CutError(code: "invalid_transcript_edit", message: "The transcript edit could not be applied.")
        }
        refreshSidecarExclusions()
    }

    func enqueueTranscriptSnapshot(_ snapshot: CutProject, excerpt: TranscriptQueueExcerpt, range: MulticamRange) throws -> UUID {
        guard !isBusy, alert == nil, let sequence = snapshot.sequenceClips, !sequence.isEmpty else {
            throw CutError(code: "queue_failed", message: "The sequence excerpt is unavailable.")
        }
        let clips = sequence.map { ClipRequest(file: URL(fileURLWithPath: $0.file), from: $0.from, to: $0.to) }
        let files = Set(clips.map(\.file))
        let indexed = transcriptMedia
        let media = try Dictionary(uniqueKeysWithValues: files.map { file in
            let info = try indexed[file.path] ?? CutEngine(useSidecar: useAnalysisSidecars).inspect(file, keyframes: true)
            return (file, info)
        })
        let item = QueuedRange(start: range.from, end: range.to, clips: clips, media: media,
                               stillProject: snapshot, pictureDocument: projectURL, placements: try snapshot.exportPlacementScope(), excerpt: excerpt)
        queuedRanges.append(item)
        statusMessage = "Added \(excerpt.name) to the export queue."
        return item.id
    }
}

extension EditorModel {
    var sourceRangeSelection: MulticamRange? {
        selectedSpan.map { .init(from: $0.from, to: $0.to) }
    }

    var sourceRangePlayhead: RationalTime? {
        mcpDuration == .zero ? .zero : markBoundary(at: playhead)
    }

    var sourceRangeForSelection: SequenceSourceRange? {
        guard let span = selectedSpan, let duration = try? span.to.subtracting(span.from) else { return nil }
        let clips = pieces(in: span)
        guard clips.count == 1, let clip = clips.first, clip.duration == duration else { return nil }
        return try? .init(file: clip.source.url.path, from: clip.start, to: clip.end)
    }

    func saveSourceSelect(_ select: NamedSourceSelect, expectedRevision: Int,
                          checkAccess: @escaping @MainActor () throws -> Void = {}) async throws {
        try checkSourceRangeEdit(expectedRevision)
        let generation = mcpGeneration
        let exclusions = sourceRangeSidecarExclusions([select.range])
        let useSidecars = useAnalysisSidecars
        let work = sidecarWork.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try select.range.resolve(relativeTo: nil) { file in
                let engine = CutEngine(cancelled: { Task.isCancelled },
                                       useSidecar: useSidecars && !AnalysisSidecar.isExcluded(file, in: exclusions))
                return try engine.inspectSummary(file)
            }
        }
        let media = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        try checkAccess()
        try checkSourceRangeEdit(expectedRevision, generation: generation)
        guard Self.currentSource(media) else { throw sourceRangeChanged(media.url) }
        let normalized = select.mapPath { _ in media.url.path }
        try updateSourceSelects(stillProject.settingSourceSelect(normalized), action: "Save Source Select")
    }

    func removeSourceSelect(_ id: String, expectedRevision: Int) throws {
        try checkSourceRangeEdit(expectedRevision)
        try updateSourceSelects(stillProject.removingSourceSelect(id: id), action: "Remove Source Select")
    }

    private func updateSourceSelects(_ candidate: CutProject, action: String) throws {
        guard candidate != stillProject else { return }
        undoStack.append(HistoryEntry(action: action, contents: .live(snapshot()),
                                      copyContainer: explicitCopyContainer, transcriptState: transcriptState))
        redoStack.removeAll()
        unopenedConversionRedo.removeAll()
        enforceHistoryLimit()
        if case .stillSequence(let sequence) = candidate { edit.stillSequence = sequence }
        else { edit.stillSequence = nil }
        mcpRevision += 1
        refreshSidecarExclusions()
        updateStatus()
        saveUntitledDraft()
    }

    private func checkSourceRangeEdit(_ revision: Int, generation: UUID? = nil) throws {
        try Task.checkCancellation()
        guard mcpRevision == revision, generation == nil || mcpGeneration == generation else {
            throw CutError(code: "stale_revision", message: "The sequence changed. Review the source ranges again.")
        }
        guard !isBusy, alert == nil, !mcpHasActiveTrim else {
            throw CutError(code: "editor_busy", message: "Finish the current editor operation before editing source ranges.")
        }
    }

    private func sourceRangeSidecarExclusions(_ ranges: [SequenceSourceRange]) -> Set<URL> {
        let urls = ranges.compactMap { try? $0.fileURL(relativeTo: nil) }
        var paths = protectedMedia
        for url in urls { paths[url.path] = url.lastPathComponent }
        return CutProject.sidecarExclusions(absoluteSources: paths, candidates: urls, projectURL: projectURL)
    }

    func applySourceRanges(_ ranges: [SequenceSourceRange], destination: MulticamRange,
                           expectedRevision: Int, checkAccess: @escaping @MainActor () throws -> Void = {}) async throws {
        try checkSourceRangeEdit(expectedRevision)
        let generation = mcpGeneration
        let project = stillProject
        let existing = segments
        let previous = edit.preparation
        let token = EditCancellation()
        let useSidecars = useAnalysisSidecars
        let exclusions = sourceRangeSidecarExclusions(ranges)
        let engine = CutEngine(cancelled: { token.isCancelled }, useSidecar: useSidecars)
        let work = sidecarWork.detached(priority: .userInitiated) { [sidecarPreference] in
            var media = Self.mediaByURL(existing)
            var retainedOrigins: [String: String] = [:]
            let candidate = try project.applyingSourceRanges(ranges, from: destination.from, to: destination.to,
                                                              onRetainedClip: { retainedOrigins[$0] = $1 }) { url in
                try Task.checkCancellation()
                if let current = media[url] { return current }
                let indexed = try AnalysisSidecar.$excludedSources.withValue(exclusions) {
                    try engine.inspect(url, keyframes: true)
                }
                try Self.checkEditable(indexed)
                media[url] = indexed
                return indexed
            }
            var sources: [DocumentSourceKey: EditorSource] = [:]
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.documentID, $0) })
            for segment in existing {
                let source = segment.source
                let key = DocumentSourceKey(file: source.url, original: source.originalURL,
                                            track: source.replacementTrack, names: source.replacementNames)
                sources[key] = source
            }
            let proposed = try (candidate.sequenceClips ?? []).map { clip in
                let url = URL(fileURLWithPath: clip.file).standardizedFileURL
                let original = URL(fileURLWithPath: clip.originalFile ?? clip.file).standardizedFileURL
                let key = DocumentSourceKey(file: url, original: original, track: clip.audioTrack, names: clip.replacementNames)
                if let originalID = retainedOrigins[clip.id], var previous = byID[originalID] {
                    if originalID != clip.id {
                        return EditorSegment(documentID: clip.id, source: previous.source, start: clip.from, end: clip.to,
                                             displayRange: previous.displayRange, occurrence: previous.occurrence, tileLayouts: clip.tileLayouts)
                    }
                    previous.start = clip.from
                    previous.end = clip.to
                    previous.tileLayouts = clip.tileLayouts
                    return previous
                }
                let source: EditorSource
                if let cached = sources[key] { source = cached }
                else {
                    guard let index = media[url] else { throw sourceRangeChanged(url) }
                    source = .resolved(IndexedSource(media: sidecarPreference.attachingDocument(to: index)))
                    sources[key] = source
                }
                return EditorSegment(documentID: clip.id, source: source, start: clip.from, end: clip.to, tileLayouts: clip.tileLayouts)
            }
            if let first = proposed.compactMap({ $0.source.media }).first {
                let ordinary = proposed.filter { !$0.source.isAudioReplacement }.compactMap { $0.source.media }.first
                var checked = Set<UUID>()
                for source in proposed.compactMap({ $0.source.indexed }) where checked.insert(source.id).inserted {
                    if source.isAudioReplacement,
                       (try? engine.checkPictureCompatibility(source.media, with: first)) != nil,
                       source.media.audio.count == first.audio.count { continue }
                    try engine.checkEncodeCombinable(source.media, with: source.isAudioReplacement ? first : ordinary ?? first)
                }
            }
            return (candidate, proposed, PreparedEdit(segments: proposed, previous: previous, engine: engine))
        }
        let (candidate, proposed, prepared) = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            token.cancel()
            work.cancel()
        }
        try Task.checkCancellation()
        try checkAccess()
        try checkSourceRangeEdit(expectedRevision, generation: generation)
        for media in prepared.sourceMedia.values where !Self.currentSource(media) { throw sourceRangeChanged(media.url) }
        let action = destination.from == destination.to ? "Insert Source Ranges" : "Replace With Source Ranges"
        // Applying the edit starts waveform work for newly introduced sources.
        refreshSidecarExclusions(adding: Array(Set(proposed.map { $0.source.url })))
        defer { refreshSidecarExclusions() }
        guard apply(proposed, prepared: prepared, selecting: proposed.first(where: { $0.id == selectedID })?.id,
                    at: destination.from.seconds, action: action, sequenceProject: candidate) else {
            let message = alert?.message ?? "The source range plan could not be applied."
            alert = nil
            throw CutError(code: "invalid_source_range", message: message)
        }
    }
}

private func sourceRangeChanged(_ url: URL) -> CutError {
    CutError(code: "source_changed", message: "\(url.lastPathComponent) changed while preparing the source range.")
}

extension EditorModel {
    func seekParticipantAppearance(sourceID: String, range: MulticamRange, mark: Bool) -> Bool {
        let occurrences = segments.indices.compactMap { index -> MulticamRange? in
            let segment = segments[index]
            guard segment.source.url.path == sourceID,
                  edit.offsets.indices.contains(index) else { return nil }
            let offset = edit.offsets[index]
            let first = max(range.from, segment.start)
            let last = min(range.to, segment.end)
            guard first < last,
                  let from = try? offset.adding(first.subtracting(segment.start)),
                  let to = try? offset.adding(last.subtracting(segment.start)) else { return nil }
            return .init(from: from, to: to)
        }
        guard let occurrence = occurrences.min(by: {
            abs($0.from.seconds - playhead) < abs($1.from.seconds - playhead)
        }) else { return false }
        preview.pause()
        seek(occurrence.from.seconds)
        if mark { selectRange(occurrence.from.seconds, occurrence.to.seconds) }
        return true
    }
}

extension EditorModel {
    private var canChangeProjectMedia: Bool {
        !isBusy && !isSavingSidecars && !mcpHasActiveTrim && alert == nil
    }

    private func updateMediaRelinkIndexing(_ paths: Set<URL>) {
        let updated = mediaRelinkIndexing.symmetricDifference(paths)
        guard !updated.isEmpty else { return }
        mediaRelinkIndexing = paths
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var clips = edit.timelineClips
        for index in clips.indices {
            guard let segment = byID[clips[index].id], updated.contains(ProjectMediaVolume.watchURL(segment.source.url)) else { continue }
            applyMediaPresentation(segment, to: &clips[index])
        }
        edit.timelineClips = clips
    }

    func cancelProjectMediaIndexing() {
        mediaRelinkCancellation?.cancel()
    }

    private func preindexProjectMedia(_ urls: Set<URL>, cancellation: EditCancellation) async throws -> [URL: MediaInfo] {
        var media: [URL: MediaInfo] = [:]
        for (index, url) in urls.sorted(by: { $0.path < $1.path }).enumerated() {
            try Task.checkCancellation()
            guard !url.path.split(separator: "/").contains(".."),
                  !interchangeCheckingVolumes.contains(ProjectMediaVolume.key(for: url)) else { continue }
            let settings = sidecarPreference.indexSettings(for: url)
            let key = SourceIndexLoader.Key(url: url, sidecars: settings.enabled, preview: false, project: sidecarWork.project)
            do {
                let index = try await SourceIndexLoader.shared.read(key, token: cancellation, preference: settings.change) { [weak self] fraction in
                    let progress = (Double(index) + fraction) / Double(urls.count)
                    guard cancellation.shouldReport(progress) else { return }
                    Task { @MainActor in
                        guard let self, self.mediaRelinkCancellation === cancellation,
                              let previous = self.mediaRelinkProgress else { return }
                        self.mediaRelinkProgress = max(previous, progress)
                    }
                }
                try Self.checkEditable(index.ordinary)
                media[url] = index.ordinary
            } catch {
                try Task.checkCancellation()
                if cancellation.isCancelled { throw CancellationError() }
                // Revert and replacement may intentionally retain an offline source.
                // The import path decides how the current document represents this failure.
            }
        }
        return media
    }

    var projectMediaSnapshotForWriting: ProjectMediaSnapshot {
        var indexed = interchangeIndexedMedia
        var assets = stillProject.stillAssets
        for entry in undoStack + redoStack {
            if case .live(let state) = entry.contents {
                indexed.append(contentsOf: state.preparation.sourceMedia.values)
            }
            assets.append(contentsOf: entry.project.stillAssets)
        }
        var seen = Set<String>()
        let indexedMedia = indexed.filter { seen.insert($0.url.path).inserted }.map { ($0.url.path, $0) }
        let stills = assets.compactMap { ProjectMediaSnapshot.Entry(path: $0.file, asset: $0) }
            .filter { seen.insert($0.path).inserted }
        return mediaSnapshot.merging(media: indexedMedia, stills: stills)
    }

    var projectMediaArchive: LiveProjectMediaArchive? {
        guard !isEmpty || !stillProject.stillAssets.isEmpty || hasHistory || projectURL != nil else { return nil }
        func state(_ entry: HistoryEntry) -> CutHistoryState {
            .init(action: entry.action, origin: entry.origin, project: entry.project, bindingChanges: entry.bindingChanges)
        }
        return .init(project: transcriptProject, undo: undoStack.map(state), redo: redoStack.map(state),
                     snapshot: projectMediaSnapshotForWriting, documentURL: projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL,
                     checkingVolumes: interchangeCheckingVolumes)
    }

    func relinkProjectMedia(from: String, to: URL, validateCommit: @escaping @MainActor () throws -> Void = {}) async throws -> Bool {
        guard canChangeProjectMedia, let archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        let generation = mcpGeneration, revision = mcpRevision
        let result = try await archive.relink(from, to: to)
        return try await installProjectMedia(result.project, archive: archive, snapshot: result.snapshot,
                                             relinkHistory: (result.undo, result.redo), affected: [archive.url(from)],
                                             verified: result.candidate.outcome == .verified ? [archive.url(from)] : [],
                                             generation: generation, revision: revision) {
            try validateCommit()
            if result.candidate.outcome.canRelink {
                try checkLiveMediaVolume(result.candidate.url, volumes: self.interchangeCheckingVolumes)
            }
            try result.candidate.checkGeneration()
        }
    }

    func relinkProjectMedia(_ mappings: [ProjectMediaMapping], validateCommit: @escaping @MainActor () throws -> Void = {}) async throws
        -> LiveProjectMediaRelinkBatch {
        guard canChangeProjectMedia, let archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        let generation = mcpGeneration, revision = mcpRevision
        return try await archive.applyRelinks(mappings, checkingVolumes: { self.interchangeCheckingVolumes }) { result, rows, validateRows in
            try await installProjectMedia(result.project, archive: archive, snapshot: result.snapshot,
                                     relinkHistory: (result.undo, result.redo), affected: Set(rows.map { archive.url($0.from) }),
                                     verified: Set(rows.filter { $0.candidate.outcome == .verified }.map { archive.url($0.from) }),
                                     generation: generation, revision: revision) {
                try validateCommit()
                try validateRows()
            }
        }
    }

    func revertProjectMedia(_ path: String, validateCommit: @escaping @MainActor () throws -> Void = {}) async throws -> Bool {
        guard canChangeProjectMedia, let archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        let generation = mcpGeneration, revision = mcpRevision
        let result = try await archive.revert(path)
        return try await installProjectMedia(result.project, archive: archive, snapshot: result.snapshot,
                                             relinkHistory: (result.undo, result.redo), affected: [archive.url(path)],
                                             verified: result.candidate.outcome == .verified ? [archive.url(path)] : [],
                                             generation: generation, revision: revision) {
            try validateCommit()
            if result.candidate.outcome.canRelink {
                try checkLiveMediaVolume(result.candidate.url, volumes: self.interchangeCheckingVolumes)
            }
            try result.candidate.checkGeneration()
        }
    }

    func ignoreProjectMedia(_ path: String) throws {
        guard canChangeProjectMedia, var archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        let previous = archive.snapshot
        try archive.ignore(path)
        guard archive.snapshot != previous else { return }
        mediaSnapshot = archive.snapshot
        let matches = Set(segments.filter { $0.source.url == archive.url(path) }.map(\.id))
        for index in edit.timelineClips.indices where matches.contains(edit.timelineClips[index].id) {
            if let segment = segments.first(where: { $0.id == edit.timelineClips[index].id }) {
                var clip = edit.timelineClips[index]
                applyMediaPresentation(segment, to: &clip)
                edit.timelineClips[index] = clip
            }
        }
        refreshStillMediaPresentation(for: [archive.url(path)])
        mediaSnapshotChanged = true
        mcpRevision += 1
        updateStatus()
        updateMediaWatcher()
        saveUntitledDraft()
    }

    func applyProjectMediaReplacement(_ preview: MediaReplacePreview, validateCommit: @escaping @MainActor () throws -> Void = {}) async throws -> Bool {
        guard canChangeProjectMedia, let archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        try checkLiveMediaVolume(preview.candidateURL, volumes: self.interchangeCheckingVolumes)
        let project = try preview.applying(to: archive.project)
        return try await installProjectMedia(project, archive: archive, snapshot: preview.snapshot,
                                             relinkHistory: nil, affected: [preview.sourceURL],
                                             generation: mcpGeneration, revision: mcpRevision,
                                             replacementURL: preview.candidateURL,
                                             replacementAtSamePath: preview.replacesAtSameLocation) {
            try validateCommit()
            try checkLiveMediaVolume(preview.candidateURL, volumes: self.interchangeCheckingVolumes)
            try preview.checkGeneration()
        }
    }

    private func carryMediaAnalysis(from previous: [EditorSegment], archive: LiveProjectMediaArchive,
                                    verified: Set<URL>, replacing: Set<URL>) {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.documentID, $0) })
        let fingerprints = Dictionary(archive.snapshot.entries.compactMap { entry in
            entry.sourceFingerprint.map { (entry.path, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let thresholds = Dictionary(grouping: thresholdOverrides, by: { $0.key.source })
        var carried = Set<UUID>()
        for clip in segments {
            guard let original = previousByID[clip.documentID], let previousMedia = original.source.media,
                  let nextMedia = clip.source.media, clip.source.id != original.source.id,
                  !replacing.contains(archive.url(original.source.url.path)) else { continue }
            let sameGeneration = previousMedia.url == nextMedia.url && previousMedia.identity.matchesSnapshot(nextMedia.identity)
            let oldPath = archive.url(original.source.url.path)
            let provenMove = verified.contains(oldPath)
                && fingerprints[oldPath.path] == previousMedia.identity.transcriptFingerprint
            guard sameGeneration || provenMove else { continue }
            let old = original.source.id, new = clip.source.id
            if carried.insert(new).inserted {
                let previousStamp = SceneSourceStamp(media: previousMedia)
                let cachedScene = [sceneReports[old], staleSceneReports[old]].compactMap { $0 }.first {
                    $0.sourceStamp == previousStamp
                }
                if let report = cachedScene {
                    installSceneReport(report.forRefreshedMedia(nextMedia), for: new, replacing: true)
                }
                if let overlay = sourceSceneOverlays[old] { sourceSceneOverlays[new] = overlay }
                if let results = silenceResults[old] {
                    silenceResults[new] = results.mapValues { $0.forRefreshedMedia(nextMedia) }
                    sourcePauses[new] = sourcePauses[old]
                }
                if let threshold = automaticThresholds[old] { automaticThresholds[new] = threshold }
                if let track = sourceAnalysisTracks[old] { sourceAnalysisTracks[new] = track }
                for (key, threshold) in thresholds[old] ?? [] {
                    thresholdOverrides[.init(source: new, track: key.track)] = threshold
                }
            }
            if clip.start == original.start, clip.end == original.end {
                let oldRange = ClipSceneRange(original), newRange = ClipSceneRange(clip)
                if let report = sceneRangeReports[oldRange] {
                    sceneRangeReports[newRange] = report.forRefreshedMedia(nextMedia)
                }
                sceneOverlays[newRange] = sceneOverlays[oldRange]
            }
        }
        if !carried.isEmpty { sceneRevision += 1 }
    }

    private func installProjectMedia(_ document: CutProject, archive: LiveProjectMediaArchive, snapshot snapshotMedia: ProjectMediaSnapshot,
                                     relinkHistory states: (undo: [CutHistoryState], redo: [CutHistoryState])?, affected: Set<URL>,
                                     verified: Set<URL> = [], generation: UUID, revision: Int, replacementURL: URL? = nil, replacementAtSamePath: Bool = false,
                                     validateCommit: @escaping @MainActor () throws -> Void) async throws -> Bool {
        func validate() throws {
            try Task.checkCancellation()
            try validateCommit()
            guard canChangeProjectMedia, generation == mcpGeneration, revision == mcpRevision,
                  (projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL) == archive.documentURL,
                  transcriptProject == archive.project, undoStack.count == archive.undo.count,
                  redoStack.count == archive.redo.count else { throw staleLiveProjectMedia() }
        }
        guard canChangeProjectMedia, mediaRelinkIndexing.isEmpty else { throw staleLiveProjectMedia() }
        try validate()
        let project = document.mapMediaPaths(archive.absolutePath)
        let media = snapshotMedia.mappingPaths(archive.absolutePath)
        let relinkHistory = states.map { (undo: archive.absoluteHistory($0.undo), redo: archive.absoluteHistory($0.redo)) }
        let historyChanged = relinkHistory.map { $0.undo != archive.undo || $0.redo != archive.redo } ?? false
        guard project != archive.project || media != archive.snapshot || historyChanged else { return false }
        let previous = snapshot()
        let previousTranscripts = transcriptState
        let previousContainer = explicitCopyContainer
        var nextTranscripts = project.transcripts
        if nextTranscripts != previousTranscripts, nextTranscripts.revision == previousTranscripts.revision {
            try nextTranscripts.advanceRevision()
        }
        func installMetadata() {
            if let relinkHistory {
                func map(_ existing: [HistoryEntry], _ before: [CutHistoryState], _ after: [CutHistoryState]) -> [HistoryEntry] {
                    zip(existing, zip(before, after)).map { entry, states in
                        guard states.0 != states.1 else { return entry }
                        var entry = entry
                        entry.contents = .document(states.1.project)
                        entry.bindingChanges = states.1.bindingChanges ?? []
                        return entry
                    }
                }
                undoStack = map(undoStack, archive.undo, relinkHistory.undo)
                redoStack = map(redoStack, archive.redo, relinkHistory.redo)
            } else {
                undoStack.append(.init(action: "Replace Source File", contents: .live(previous),
                                       copyContainer: previousContainer, transcriptState: previousTranscripts,
                                       bindingChanges: TranscriptBindingChange.changes(from: nextTranscripts, to: previousTranscripts)))
                redoStack.removeAll()
                unopenedConversionRedo.removeAll()
                enforceHistoryLimit()
            }
            mediaSnapshot = media
            mediaSnapshotChanged = true
            carryMediaAnalysis(from: previous.segments, archive: archive, verified: verified,
                               replacing: relinkHistory == nil ? affected : [])
            transcriptState = nextTranscripts
            rebuildPausePlan()
            invalidateQueuedMedia(at: affected)
            updateStatus()
            updateMediaWatcher()
            saveUntitledDraft()
        }
        let clips = project.sequenceClips ?? []
        let timelineChanged = project.sequenceClips != archive.project.sequenceClips
        let mustReindex = replacementAtSamePath && clips.contains { affected.contains(archive.url($0.file)) }
        if (timelineChanged || mustReindex), !clips.isEmpty {
            let files = clips.map { URL(fileURLWithPath: $0.file) }
            let cancellation = EditCancellation()
            let originalClips = Dictionary(uniqueKeysWithValues: (archive.project.sequenceClips ?? []).map { ($0.id, $0) })
            let candidates = Set(clips.compactMap { clip -> URL? in
                guard let original = originalClips[clip.id] else { return URL(fileURLWithPath: clip.file) }
                return clip.file != original.file || (mustReindex && affected.contains(archive.url(clip.file)))
                    ? URL(fileURLWithPath: clip.file) : nil
            })
            if !candidates.isEmpty {
                mediaRelinkCancellation = cancellation
                mediaRelinkProgress = 0
                updateMediaRelinkIndexing(Set(affected.map { ProjectMediaVolume.watchURL($0) }))
            }
            defer {
                if mediaRelinkCancellation === cancellation {
                    mediaRelinkCancellation = nil
                    mediaRelinkProgress = nil
                    updateMediaRelinkIndexing([])
                }
            }
            try await withTaskCancellationHandler {
                let preindexed = try await preindexProjectMedia(candidates, cancellation: cancellation)
                try validate()
                mediaRelinkProgress = nil
                updateMediaRelinkIndexing([])

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    importFiles(files, projectClips: clips, beforeInstall: {
                        try validate()
                        return true
                    }, requestCancellation: cancellation, installed: installMetadata,
                                sequenceProject: project, sourceSnapshot: media, preserveProjectPosition: true,
                                preindexedMedia: preindexed,
                                keepUnavailableRangesAt: Set([replacementURL].compactMap { $0 }.map { ProjectMediaVolume.watchURL($0) })) {
                        continuation.resume(with: $0)
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
        } else {
            if replacementAtSamePath, let clip = project.stillSoundtrack {
                let url = URL(fileURLWithPath: clip.file)
                soundtrackMediaByURL[url] = nil
                incompatibleMedia.remove(ProjectMediaVolume.watchURL(url))
                refreshReviewStreams[ProjectMediaVolume.watchURL(url)] = nil
            }
            if project != archive.project {
                let restored = timelineChanged ? [] : segments
                let prepared = timelineChanged ? PreparedEdit() : edit.preparation
                guard apply(restored, prepared: prepared, selecting: selectedID, at: playhead, action: "Replace Source File",
                            recordHistory: false, preserveMarks: true, sequenceProject: project) else {
                    throw CutError(code: "invalid_edit", message: "The media edit could not be installed.")
                }
            } else {
                loadSoundtrackIfNeeded()
                mcpRevision += 1
            }
            installMetadata()
        }
        return true
    }
}

extension EditorModel {
    private func tileRecordingID(for clip: EditorSegment) -> String? {
        let urls = [clip.source.url.standardizedFileURL, clip.source.originalURL.standardizedFileURL]
        return participantProject.sources.first { source in
            let path = CutProject.mediaURL(source.sourceID, relativeTo: projectURL ?? draft.url ?? urls[0])
            return urls.contains(path.standardizedFileURL)
        }?.sourceID
    }

    private func layoutSceneTimes(for clip: EditorSegment) -> [RationalTime] {
        guard let recording = tileRecordingID(for: clip) else { return [] }
        return participantProject.sources.first { $0.sourceID == recording }?.layoutChangeTimes ?? []
    }

    var tileTimeline: [UUID: TileTimelineContent] {
        let participants = participantProject
        let clips = sequenceClips
        guard !participants.isEmpty || clips.contains(where: { !$0.tileLayouts.isEmpty }) else {
            tileTimelineCache = nil
            return [:]
        }
        let ids = segments.map(\.id)
        let document = projectURL ?? draft.url
        if let cache = tileTimelineCache, cache.participants == participants, cache.clips == clips,
           cache.ids == ids, cache.document == document { return cache.content }
        let displayClips = participants.render != nil && participants.tileOutput == nil
            ? (try? stillProject.migratingLegacyTiles().sequenceClips) ?? clips : clips
        let names = Dictionary(participants.people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let content: [UUID: TileTimelineContent] = Dictionary(uniqueKeysWithValues: zip(segments, displayClips).compactMap { clip, document in
            let kept = MulticamRange(from: clip.start, to: clip.end)
            let recording = tileRecordingID(for: clip)
            let edited = recording != nil || document.tileLayouts.contains { $0.range.tileIntersection(kept) != nil }
            guard edited else { return nil }
            var content = TileTimelineContent(layouts: TileTimelineContent.fillingGaps(document.tileLayouts, in: kept),
                                              feedNames: names, edited: true)
            if let recording { content.addFeeds(participants, sourceID: recording, input: kept, offset: .zero) }
            return (clip.id, content)
        })
        tileTimelineCache = (participants, clips, ids, document, content)
        return content
    }

    func setTileLayout(_ layout: ParticipantShotLayout?, slots: [ParticipantSlot] = [], compact: Bool = false) throws {
        guard let index = segments.firstIndex(where: { $0.id == selectedID }) ?? locatedSegment(at: playhead)?.0 else {
            throw CutError(code: "invalid_tile_layout", message: "Select a video clip to set a layout.")
        }
        let base = edit.offsets[index]
        let end = try base.adding(segments[index].duration)
        let lower = edit.markIn ?? base
        let upper = edit.markOut ?? end
        guard lower < upper else {
            throw CutError(code: "invalid_tile_layout", message: "The layout needs a range with a start before its end.")
        }
        var next = stillProject
        let indices = edit.markIn != nil && edit.markOut != nil ? Array(segments.indices) : [index]
        var applied = false
        for index in indices {
            let clip = segments[index]
            guard clip.source.media?.hasVideo == true else { continue }
            let base = edit.offsets[index]
            let end = try base.adding(clip.duration)
            guard let marked = MulticamRange(from: lower, to: upper).tileIntersection(.init(from: base, to: end)) else { continue }
            let range = try MulticamRange(from: clip.start.adding(marked.from.subtracting(base)),
                                          to: clip.start.adding(marked.to.subtracting(base)))
            let span = layout.map { TileLayoutSpan(range: range, layout: $0, slots: slots, compact: compact) }
            next = try next.settingTileLayout(scope: .clip(clip.documentID), range: range, layout: span)
            applied = true
        }
        guard applied else {
            throw CutError(code: "invalid_tile_layout", message: "Set marks over a video clip.")
        }
        try replaceTileLayoutProject(next)
    }

    func clearMarkedTileLayout() {
        do {
            try setTileLayout(nil)
        } catch {
            alert = EditorNotice(title: "Can’t Clear Layout", message: error.localizedDescription)
        }
    }

    func resizeTimelineTile(_ span: TileTimelineContent.FeedSpan, edge: TimelineEdge, at time: Double) {
        do {
            guard let target = tileTimelineTime(time) else { return }
            let next = try TileTimelineEdit.resize(participantProject, span: span, edge: edge, to: target)
            try replaceParticipantProject(next, action: "Move Tile Span Edge")
        } catch {
            alert = EditorNotice(title: "Can’t Move Tile Edge", message: error.localizedDescription)
        }
    }
}
