import AppKit
import Combine
import Foundation
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

private struct EditorSegment: Sendable {
    let id: UUID
    let source: IndexedSource
    var start: RationalTime
    var end: RationalTime
    var displayRange: AudioSpan?
    // Retained pieces share protection choices belonging to this occurrence of a source.
    let occurrence: UUID

    init(id: UUID = UUID(), source: IndexedSource, start: RationalTime = .zero, end: RationalTime? = nil,
         displayRange: AudioSpan? = nil, occurrence: UUID? = nil) {
        self.id = id
        self.source = source
        self.start = start
        self.displayRange = displayRange
        self.occurrence = occurrence ?? id
        self.end = end ?? source.duration
    }

    var duration: RationalTime { end - start }
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

    init(media: MediaInfo, container: String, engine: CutEngine) {
        wholeStarts = engine.validBoundaries(in: media, start: true, container: container)
        wholeEnds = engine.validBoundaries(in: media, start: false, container: container)
        if media.audio.isEmpty {
            firstStarts = wholeStarts
            interiorStarts = wholeStarts
            finalEnds = wholeEnds
            interiorEnds = wholeEnds
        } else {
            firstStarts = engine.validBoundaries(in: media, start: true, last: false, container: container)
            interiorStarts = engine.validBoundaries(in: media, start: true, first: false, last: false, container: container)
            finalEnds = engine.validBoundaries(in: media, start: false, first: false, container: container)
            interiorEnds = engine.validBoundaries(in: media, start: false, first: false, last: false, container: container)
        }
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
    var firstSourceID: UUID?
    var sourceMedia: [UUID: MediaInfo] = [:]

    init() {}

    init(segments: [EditorSegment], previous: Self, engine: CutEngine) {
        sourceMedia = Dictionary(segments.map { ($0.source.id, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        guard let first = segments.first?.source, first.isIndexed else { return }
        firstSourceID = first.id
        container = first.id == previous.firstSourceID
            ? previous.container : engine.suggestedContainers(for: first.media).first
    }
}

private struct EditSnapshot {
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

final class EditCancellation: @unchecked Sendable {
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
private final class SidecarPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    private var change = EditCancellation()

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

    func indexSettings() -> (enabled: Bool, change: EditCancellation) {
        lock.withLock { (value, change) }
    }
}

struct QueuedRange: Identifiable, Sendable {
    let id = UUID()
    let start: RationalTime
    let end: RationalTime
    let clips: [ClipRequest]
    let media: [URL: MediaInfo]
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
    @Published var timelineZoom = 0.0
    @Published private(set) var timeEntryRequest = 0
    private var explicitCopyContainer: String?
    private var copyBoundaryIndices: [UUID: BoundaryIndex] = [:]
    private struct TrimCheck {
        let error: CutError?
    }
    private var checkingTrim: (UUID, TimelineEdge)?
    private var trimChecks: [RationalTime: TrimCheck] = [:]
    private var fixedTrimIssue: CutError?

    private struct HistoryEntry {
        let edit: EditSnapshot
        let action: String
        let copyContainer: String?
        let analysisTrack: Int?
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
    private var exportOptions = ExportSheetOptions()
    private var exportDirectory: URL?
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    private var waitingForExportCleanup = false
    private var pendingOpenFiles: [URL] = []
    private var session = UUID()
    private var sceneToken: EditCancellation?
    private var sceneReports: [UUID: SceneReport] = [:]
    private var snapScanRequests = Set<UUID>()
    private var sidecarSaveToken: EditCancellation?
    private var lastSidecarWrite: (id: UUID, task: Task<Void, Never>)?
    private var pendingMetadata: [UUID: EditorMetadataEdits] = [:]
    private var filmstripTiles = FilmstripTileBuffer()
    @Published private(set) var isSavingSidecars = false
    private(set) var scenesBySource: [UUID: [TimelineScene]] = [:]
    private(set) var viewNamesBySource: [UUID: [Int: String]] = [:]
    @Published private(set) var sceneProgress: Double?
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
    @Published var analysisTrack = 0 {
        didSet {
            if oldValue != analysisTrack {
                automaticThresholds.removeAll()
                if snapTarget == .silence { snapScanRequests.removeAll() }
            }
            syncWaveforms(invalidatingPauses: oldValue != analysisTrack)
            if oldValue != analysisTrack {
                if isAudioOnly { restorePreview(at: playhead) }
                requestSnapAnalysis()
            }
        }
    }
    @Published var skipPauses = false
    private(set) var sourcePauses: [UUID: [AudioSpan]] = [:]
    private(set) var pausePlan: [TimelinePause] = []
    private var protectedPauses: [TimelinePause.Source: [AudioSpan]] = [:]
    private var pauseDetections: [UUID: Task<Void, Never>] = [:]
    private var activeAudioSources = Set<UUID>()
    private(set) var shortenedPauseCount = 0
    private(set) var removedPauseSeconds = 0.0
    @Published var cutPreview: CutPreview? {
        didSet {
            if oldValue != nil && cutPreview == nil { Task { resumePendingWork() } }
        }
    }
    var audioTracks: [StreamInfo] { segments.first?.source.media.streams.filter { $0.kind == "audio" } ?? [] }
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

    init(preferences: EditorPreferences) {
        self.preferences = preferences
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
        case .volume, .isMuted, .scrubSoundEnabled, .jpegPreset:
            return
        case .useAnalysisSidecars:
            sidecarPreference.enabled = useAnalysisSidecars
            for task in pauseDetections.values { task.cancel() }
            checkedSilenceSidecars.subtract(pauseDetections.keys)
            pauseDetections.removeAll()
            syncWaveforms()
        case .defaultExportMode:
            exportOptions.mode = defaultExportMode
        case .snapTarget:
            updateSnapTarget()
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
    var timelineClips: [TimelineClip] { edit.timelineClips }
    var timelineThumbnailHeight: CGFloat {
        largeThumbnails ? edit.largeThumbnailHeight : edit.timelineThumbnailHeight
    }
    var canCloseVideo: Bool {
        (!isEmpty || isImporting) && !isExporting && !isSavingSidecars && !isPresentingPanel &&
            !isBulkQueuePresented && cutPreview == nil && alert == nil && !waitingForExportCleanup
    }
    var isEmpty: Bool { segments.isEmpty }
    var hasPicture: Bool { segments.first?.source.media.hasVideo == true }
    var isAudioOnly: Bool { !isEmpty && !hasPicture }
    var effectiveSnapTarget: TimelineSnapTarget {
        isAudioOnly && (snapTarget == .scenes || snapTarget == .keyframes) ? .off : snapTarget
    }

    /// The picker's choice. An audio-only window shows Off in place of a stored
    /// picture target, and choosing what it already shows must not replace the
    /// preference that video windows share.
    func chooseSnapTarget(_ target: TimelineSnapTarget) {
        guard target != effectiveSnapTarget else { return }
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
    var isBusy: Bool { isImporting || isExporting || isCheckingEdit || isPresentingPanel || isBulkQueuePresented || cutPreview != nil || waitingForExportCleanup }
    /// Window-modal alerts leave the menu bar active, so plain-key edits stay off until the alert closes.
    var canEdit: Bool { !isEmpty && !isBusy && alert == nil }
    var canNavigate: Bool { canEdit || (isImporting && !isEmpty && !isCancelling && alert == nil) }
    var canUndo: Bool { !isBusy && alert == nil && !undoStack.isEmpty }
    var canRedo: Bool { !isBusy && alert == nil && !redoStack.isEmpty }
    var hasHistory: Bool { !undoStack.isEmpty || !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { "Undo \($0.action)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.action)" } ?? "Redo" }
    var deleteTitle: String { markIn != nil || markOut != nil ? "Delete Marked Range" : "Delete Clip" }
    var canDelete: Bool { canEdit && (markedRange != nil || selectedID != nil) }
    var canClearMarks: Bool { !isBusy && (markIn != nil || markOut != nil) }
    var canMoveEarlier: Bool { canEdit && selectedClipIndex.map { $0 > 0 } == true }
    var canMoveLater: Bool { canEdit && selectedClipIndex.map { $0 < segments.count - 1 } == true }

    private var selectedClipIndex: Int? { segments.firstIndex { $0.id == selectedID } }

    func seekUsingTimeField() {
        guard canNavigate else { return }
        timeEntryRequest += 1
    }

    func moveSelectedClip(by direction: Int) {
        guard direction < 0 ? canMoveEarlier : canMoveLater, let index = selectedClipIndex else { return }
        move(segments[index].id, to: index + (direction < 0 ? -1 : 2))
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
        _ = trim(clip.id, edge: edge, sourceTime: sourceTime, commit: true,
                 snap: !restore && usesPointerPosition ? .off : effectiveSnapTarget)
    }

    func showExportInFinder() {
        guard let url = lastExportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var markedRange: ClosedRange<Double>? {
        guard let markIn, let markOut, markIn != markOut else { return nil }
        return min(markIn, markOut)...max(markIn, markOut)
    }

    var formatSummary: String? {
        guard let media = segments.first?.source.media else { return nil }
        guard let video = media.videoStream else {
            let audio = media.primaryStream
            return "\(audio.codec.uppercased()) · \(audio.sampleRate) Hz · \(audio.channels) ch"
        }
        let hasDisplaySize = video.displayWidth > 0 && video.displayHeight > 0
        let width = hasDisplaySize ? video.displayWidth : video.width
        let height = hasDisplaySize ? video.displayHeight : video.height
        return "\(width) × \(height) · \(video.codec.uppercased())"
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

    func importFiles(_ urls: [URL], at index: Int? = nil) {
        guard !isBusy, !urls.isEmpty else { return }
        cancelTrim()
        preview.pause()
        let token = EditCancellation()
        cancellation = token
        let preference = sidecarPreference
        let engine = CutEngine(cancelled: { token.isCancelled })
        let existing = segments
        let priorPreparation = edit.preparation
        let beforeImport = snapshot()
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
                for clip in existing { indexed[clip.source.originalURL] = clip.source }
                var reference = existing.first?.source.media
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
                    var provisional: EditorSegment?
                    do {
                        let source: IndexedSource
                        if let cached = indexed[canonical] {
                            try AnalysisSidecar(media: cached.media).checkSource()
                            source = cached
                        } else {
                            func read(_ preview: Bool, identity: SourceIdentity? = nil) async throws -> MediaInfo {
                                while !token.isCancelled {
                                    let settings = preference.indexSettings()
                                    do {
                                        let key = SourceIndexLoader.Key(url: canonical, sidecars: settings.enabled,
                                                                        preview: preview, identity: identity)
                                        let index = try await SourceIndexLoader.shared.read(key, token: token,
                                            preference: settings.change, progress: report)
                                        return index.ordinary
                                    } catch is CancellationError where settings.change.isCancelled && !token.isCancelled {
                                        continue
                                    }
                                }
                                throw CancellationError()
                            }

                            let header = try? await read(true)
                            if existing.isEmpty, additions.isEmpty, let preview = header, preview.timelineIssue == nil {
                                let clip = EditorSegment(source: IndexedSource(media: preview))
                                provisional = clip
                                let prepared = PreparedEdit(segments: [clip], previous: prior, engine: engine)
                                await MainActor.run {
                                    guard self.session == currentSession, !token.isCancelled else { return }
                                    self.apply([clip], prepared: prepared, selecting: clip.id, at: 0,
                                               action: "Add Clip", recordHistory: false)
                                }
                            }
                            let media = try await read(false, identity: header?.identity)
                            try Self.checkEditable(media)
                            if let reference {
                                guard reference.hasVideo == media.hasVideo else {
                                    throw CutError(code: "incompatible_clip", message:
                                        "Add sound-only recordings to an audio timeline. To change a video's soundtrack, choose File → Replace Source Audio.")
                                }
                                try engine.checkCompatibility(media, with: reference)
                            }
                            source = IndexedSource(media: media, id: provisional?.source.id ?? UUID())
                            if preference.enabled {
                                savedAnalysis[source.id] = SavedEditorAnalysis(media: media, cancelled: { token.isCancelled || !preference.enabled })
                            }
                            indexed[canonical] = source
                        }
                        if reference == nil { reference = source.media }
                        additions.append(EditorSegment(id: provisional?.id ?? UUID(), source: source))
                        if offset + 1 < urls.count, lastPublication.map({ $0.duration(to: .now) >= .milliseconds(250) }) ?? true {
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
                                self.edit = beforeImport
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

            guard session == currentSession else { return }
            isImporting = false
            isCancelling = false
            cancellation = nil
            defer { resumePendingWork() }
            if token.isCancelled {
                edit = beforeImport
                syncWaveforms()
                restorePreview(at: beforeImport.playhead)
                updateStatus()
                return
            }
            if result.1 > 0 {
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
                apply(result.0, prepared: result.3, selecting: result.0[insertion].id, at: playhead,
                      action: result.1 == 1 ? "Add Clip" : "Add Clips", historySnapshot: beforeImport,
                      preservePreview: true)
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
        guard !isBusy, segments.contains(where: { $0.id == id }) else { return }
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
        let index = locatedSegment(at: target)?.0 ?? segments.count - 1
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

    private var currentScene: (source: UUID, report: SceneReport, index: Int)? {
        guard let (_, clip, offset) = locatedSegment(at: playhead),
              let report = sceneReports[clip.source.id] else { return nil }
        let local = clip.start.seconds + playhead - offset.seconds
        let i = max(0, report.scenes.lowerBound { $0.startSeconds > local + 1e-9 } - 1)
        return (clip.source.id, report, i)
    }

    var currentSceneLabel: String? {
        guard let current = currentScene else { return nil }
        let view = current.report.scenes[current.index].view
        let name = viewNamesBySource[current.source]?[view] ?? "View \(SceneView.label(for: view))"
        let count = current.report.viewCount == 1 ? "1 view" : "\(current.report.viewCount) views"
        return "Scene \(current.index + 1)/\(current.report.scenes.count) · \(name) · \(count)"
    }

    var canRenameCurrentView: Bool { canEdit && currentScene != nil }

    func renameCurrentView() {
        guard canRenameCurrentView, let current = currentScene, let window = sheetWindow else { return }
        preview.pause()
        let view = current.report.scenes[current.index].view
        let defaultName = "View \(SceneView.label(for: view))"
        let prompt = NSAlert()
        prompt.messageText = "Rename \(defaultName)"
        prompt.informativeText = "This name applies to every scene in this view. Leave it blank to restore the default."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
        field.placeholderString = defaultName
        field.stringValue = viewNamesBySource[current.source]?[view] ?? ""
        field.setAccessibilityLabel("View name")
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Save")
        prompt.addButton(withTitle: "Cancel")
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
        let automatic = useAnalysisSidecars
        let currentSession = session
        enqueueSidecarWrite {
            var saved = false
            if automatic {
                saved = await Task.detached(priority: .utility) {
                    do {
                        try AnalysisSidecar(media: media).save([:], updating: [section: { old in
                            let values = EditorMetadataEdits.merged(old, seed: seed, edits: [key: value])
                            return try JSONEncoder().encode(values)
                        }])
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
        // Settings and other windows change the shared target without passing through this editor's picker.
        usesPointerPosition = false
        checkingTrim = nil
        trimChecks.removeAll()
        snapScanRequests.removeAll()
        rebuildPausePlan()
        requestSnapAnalysis()
    }

    /// Selecting a target requests its missing analysis once. Cancelling a scan
    /// leaves it cancelled across ordinary edits on the same sources.
    private func requestSnapAnalysis() {
        if !snapScanRequests.isEmpty { snapScanRequests.formIntersection(edit.preparation.sourceMedia.keys) }
        guard canEdit else { return }
        switch effectiveSnapTarget {
        case .silence where canScanSilence && !hasSilenceResults:
            let missing = activeAudioSources.subtracting(sourcePauses.keys)
            guard !missing.isSubset(of: snapScanRequests) else { return }
            snapScanRequests.formUnion(missing)
            scanForSilence()
        default:
            break
        }
    }

    func cancelSceneAnalysis() {
        if snapTarget == .scenes, sceneToken != nil {
            snapScanRequests.formUnion(edit.preparation.sourceMedia.keys)
        }
        sceneToken?.cancel()
        sceneToken = nil
        sceneProgress = nil
        scenesBySource = scenesBySource.filter { sceneReports[$0.key] != nil }
        sceneRevision += 1
    }

    var canScanScenes: Bool {
        canEdit && hasPicture && sceneProgress == nil && segments.contains { sceneReports[$0.source.id] == nil }
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
        let token = EditCancellation()
        sidecarSaveToken = token
        isSavingSidecars = true
        statusMessage = "Saving analysis sidecars…"
        enqueueSidecarWrite { [self] in
            guard sidecarSaveToken === token else { return }
            // An earlier autosave may have committed since these snapshots were captured.
            let snapshots = snapshots.map { original in
                var snapshot = original
                snapshot.edits = pendingMetadata[snapshot.sourceID] ?? EditorMetadataEdits()
                return snapshot
            }
            let (saved, failures) = await Task.detached(priority: .utility) {
                var saved: [UUID] = []
                var failures: [String] = []
                for snapshot in snapshots {
                    if token.isCancelled { break }
                    do {
                        try snapshot.save(cancelled: { token.isCancelled })
                        saved.append(snapshot.sourceID)
                    } catch {
                        failures.append("\(snapshot.media.url.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                return (Set(saved), failures)
            }.value
            guard sidecarSaveToken === token else { return }
            for snapshot in snapshots where saved.contains(snapshot.sourceID) {
                pendingMetadata[snapshot.sourceID]?.discardSaved(snapshot.edits)
            }
            isSavingSidecars = false
            sidecarSaveToken = nil
            let count = saved.count
            statusMessage = count == 1 ? "Saved 1 analysis sidecar" : "Saved \(count) analysis sidecars"
            if !failures.isEmpty {
                alert = EditorNotice(title: "Couldn’t Save Analysis", message: failures.joined(separator: "\n\n"))
            }
        }
    }

    var canStepScenes: Bool {
        guard canEdit, hasPicture, sceneProgress == nil, let first = segments.first,
              segments.allSatisfy({ sceneReports[$0.source.id] != nil }) else { return false }
        if segments.count > 1 { return true }
        let scenes = scenesBySource[first.source.id] ?? []
        let cut = scenes.lowerBound { $0.start > first.start.seconds }
        return cut < scenes.count && scenes[cut].start < first.end.seconds
    }

    func scanForScenes() {
        guard canScanScenes else { return }
        var seen = Set<UUID>()
        let sources = segments.map(\.source).filter {
            sceneReports[$0.id] == nil && seen.insert($0.id).inserted
        }
        let token = EditCancellation()
        sceneToken = token
        let readSidecars = useAnalysisSidecars
        sceneProgress = 0
        Task {
            do {
                for (i, source) in sources.enumerated() {
                    let report = try await EditorAnalysisQueues.scan { [self] in
                        var pending: [TimelineScene] = []
                        var lastUpdate: TimeInterval = 0
                        func publishMarkers() {
                            guard !pending.isEmpty else { return }
                            let now = ProcessInfo.processInfo.systemUptime
                            guard now - lastUpdate >= 0.1 else { return }
                            lastUpdate = now
                            let markers = pending
                            pending.removeAll()
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sceneToken === token, self.sceneReports[source.id] == nil else { return }
                                self.scenesBySource[source.id, default: []].append(contentsOf: markers)
                                self.sceneRevision += 1
                            }
                        }
                        return try SceneAnalysis.scan(source.media, useSidecar: readSidecars, cancelled: { token.isCancelled }, progress: { fraction in
                            publishMarkers()
                            let total = (Double(i) + fraction) / Double(sources.count)
                            guard token.shouldReport(total) else { return }
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sceneToken === token else { return }
                                self.sceneProgress = total
                            }
                        }, onScene: { time, view in
                            pending.append(TimelineScene(start: time.seconds, view: view))
                            publishMarkers()
                        }, onReset: {
                            pending.removeAll()
                            lastUpdate = 0
                            let completed = Double(i) / Double(sources.count)
                            token.resetReportedProgress(to: completed)
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sceneToken === token, self.sceneReports[source.id] == nil else { return }
                                self.scenesBySource[source.id] = []
                                self.sceneProgress = completed
                                self.sceneRevision += 1
                            }
                        })
                    }
                    guard sceneToken === token else { return }
                    installSceneReport(report, for: source.id)
                }
                sceneToken = nil
                sceneProgress = nil
                requestSnapAnalysis()
            } catch {
                guard sceneToken === token else { return }
                cancelSceneAnalysis()
                alert = EditorNotice(title: "Scene Analysis", message: error.localizedDescription)
            }
        }
    }

    private func installSceneReport(_ report: SceneReport, for id: UUID) {
        guard sceneReports[id] == nil else { return }
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
        for i in indices {
            let clip = segments[i], offset = edit.offsets[i].seconds
            let end = offset + clip.duration.seconds
            if direction > 0 && end <= playhead + 1e-9 { continue }
            if direction < 0 && offset >= playhead - 1e-9 { continue }
            let local = clip.start.seconds + playhead - offset
            if direction > 0 && offset > playhead + 1e-9 { seek(offset); return }
            let scenes = scenesBySource[clip.source.id] ?? []
            if direction > 0 {
                let index = scenes.lowerBound { $0.start > local + 1e-9 && $0.start >= clip.start.seconds }
                if index < scenes.count, scenes[index].start < clip.end.seconds {
                    seek(offset + scenes[index].start - clip.start.seconds)
                    return
                }
            } else {
                let index = scenes.lowerBound { $0.start >= min(local - 1e-9, clip.end.seconds) } - 1
                let start = index >= 0 ? max(clip.start.seconds, scenes[index].start) : clip.start.seconds
                seek(offset + start - clip.start.seconds)
                return
            }
        }
    }

    func step(_ direction: Int, keyframes: Bool = false) {
        guard canEdit, direction != 0 else { return }
        cancelTrim()
        preview.pause()
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
                let time = (offset + (cut - segment.start)).seconds
                if direction > 0 ? time <= playhead : time >= playhead { continue }
                seek(time)
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
            seek((offset + (times[index] - segment.start)).seconds)
            return
        }
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
        case .scenes, .silence:
            boundary = analysisBoundary(in: clip.source, to: local, after: clip.start,
                                        before: clip.end, includingLimits: true)
        }
        if let boundary, abs(boundary.seconds - local) <= tolerance {
            return (offset + (boundary - clip.start)).seconds
        }
        return time
    }

    func split() {
        guard canEdit else { return }
        cancelTrim()
        preview.pause()
        guard let (index, segment, offset) = locatedSegment(at: playhead),
              playhead - offset.seconds > max(playhead.ulp * 4, 0.000000001) else {
            alert = EditorNotice(title: "Can’t Split Clip", message: "The playhead is already at a cut. Move it inside a clip to split it.")
            return
        }
        let target = playhead - offset.seconds + segment.start.seconds
        let candidates: [RationalTime]
        let targetMode: TimelineSnapTarget = usesPointerPosition ? .off : effectiveSnapTarget
        switch targetMode {
        case .off: candidates = segment.source.media.hasVideo ? segment.source.frames :
            [segment.source.media.audioEditBoundary(near: target)]
        case .keyframes: candidates = copyBoundaries(for: segment.source)?.splitPoints ?? []
        case .scenes, .silence:
            guard let boundary = analysisBoundary(in: segment.source, to: target, after: segment.start, before: segment.end) else {
                showAnalysisBoundaryError(segment, title: "Can’t Split Clip")
                return
            }
            candidates = [boundary]
        }
        let rightID = UUID()
        var firstIssue: EditorNotice?
        for cut in nearestBoundaries(in: candidates, to: target, after: segment.start, before: segment.end) {
            var proposed = segments
            proposed[index].end = cut
            let left = min(segment.start, segment.displayRange?.from ?? .zero)
            let right = max(segment.end, segment.displayRange?.to ?? segment.source.duration)
            proposed[index].displayRange = AudioSpan(from: left, to: cut)
            proposed.insert(EditorSegment(id: rightID, source: segment.source, start: cut, end: segment.end,
                                          displayRange: AudioSpan(from: cut, to: right), occurrence: segment.occurrence), at: index + 1)
            if targetMode == .keyframes, let error = copyIssue(proposed) {
                if firstIssue == nil {
                    firstIssue = EditorNotice(title: "Can’t Split Clip", message: copyMessage(error, in: proposed))
                }
                if blocksAllSnapCandidates(error, in: proposed) { break }
                continue
            }
            let snapped = (offset + (cut - segment.start)).seconds
            validate(proposed, selecting: rightID, at: snapped, action: "Split Clip")
            return
        }
        if let firstIssue {
            alert = firstIssue
        } else if targetMode == .keyframes {
            showCopyBoundaryError(segment, at: target, edge: .start, title: "Can’t Split Clip", first: false, last: false)
        } else {
            let unit = isAudioOnly ? "audio cut point" : "frame boundary"
            alert = EditorNotice(title: "Can’t Split Clip", message: "There is no \(unit) inside this range.")
        }
    }

    func trim(_ id: UUID, edge: TimelineEdge, sourceTime: Double, commit: Bool) -> Double? {
        trim(id, edge: edge, sourceTime: sourceTime, commit: commit, snap: effectiveSnapTarget)
    }

    private func trim(_ id: UUID, edge: TimelineEdge, sourceTime: Double, commit: Bool, snap: TimelineSnapTarget) -> Double? {
        guard canEdit, sourceTime.isFinite,
              let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        let segment = segments[index]
        let offset = edit.offsets[index]
        let minimum = edge == .end ? segment.start : nil
        let maximum = edge == .start ? segment.end : nil
        let originalBoundary = edge == .start ? segment.start : segment.end
        func replacingBoundary(_ time: RationalTime) -> [EditorSegment] {
            var proposed = segments
            if edge == .start { proposed[index].start = time } else { proposed[index].end = time }
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
            let options = trimCandidates(at: index, edge: edge, boundaries: boundaries)
            var tried: CutError?
            var chosen: RationalTime?
            for candidate in nearestBoundaries(in: options, to: sourceTime, after: minimum, before: maximum) {
                let check = trimChecks[candidate] ?? TrimCheck(error: copyIssue(replacingBoundary(candidate)))
                trimChecks[candidate] = check
                if let error = check.error {
                    if tried == nil { tried = error }
                    if blocksAllSnapCandidates(error, in: replacingBoundary(candidate), moving: id, edge: edge) {
                        fixedTrimIssue = error
                        break
                    }
                } else {
                    chosen = candidate
                    break
                }
            }
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
            else if let boundary = analysisBoundary(in: segment.source, to: sourceTime, after: minimum, before: maximum) {
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
            landing = (offset + (precedingFrame(in: segment, before: cut) - segment.start)).seconds
        }
        trimOrigin = nil
        trimAudition = nil
        validate(replacingBoundary(cut), selecting: id, at: landing, action: "Trim Clip", originalPlayhead: original)
        return cut.seconds
    }

    func cancelTrim() {
        checkingTrim = nil
        trimChecks.removeAll()
        guard let original = trimOrigin else { return }
        trimOrigin = nil
        trimAudition = nil
        restorePreview(at: original)
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
        } else if let selectedID, let index = segments.firstIndex(where: { $0.id == selectedID }) {
            var proposed = segments
            proposed.remove(at: index)
            validate(proposed, selecting: proposed.indices.contains(index) ? proposed[index].id : proposed.last?.id,
                     at: edit.offsets[index].seconds, action: "Delete Clip")
        }
    }

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        cancelTrim()
        redoStack.append(HistoryEntry(edit: snapshot(), action: previous.action, copyContainer: explicitCopyContainer,
                                      analysisTrack: previous.analysisTrack.map { _ in analysisTrack }))
        copyBoundaryIndices.removeAll()
        // The next import may use a format that this container cannot carry.
        explicitCopyContainer = previous.edit.segments.isEmpty ? nil : explicitCopyContainer ?? previous.copyContainer
        edit = previous.edit
        if let track = previous.analysisTrack, track != analysisTrack { analysisTrack = track }
        syncWaveforms()
        requestSnapAnalysis()
        restorePreview(at: edit.playhead)
        updateStatus()
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        cancelTrim()
        undoStack.append(HistoryEntry(edit: snapshot(), action: next.action, copyContainer: explicitCopyContainer,
                                      analysisTrack: next.analysisTrack.map { _ in analysisTrack }))
        copyBoundaryIndices.removeAll()
        // The next import may use a format that this container cannot carry.
        explicitCopyContainer = next.edit.segments.isEmpty ? nil : explicitCopyContainer ?? next.copyContainer
        edit = next.edit
        if let track = next.analysisTrack, track != analysisTrack { analysisTrack = track }
        syncWaveforms()
        requestSnapAnalysis()
        restorePreview(at: edit.playhead)
        updateStatus()
    }

    func preferCopyContainer(_ container: String) {
        explicitCopyContainer = container
        copyBoundaryIndices.removeAll()
        rebuildPausePlan()
        checkingTrim = nil
        trimChecks.removeAll()
    }

    var canAddMarkedRange: Bool { canEdit && markedRange != nil }
    var canShowBulkQueue: Bool { !isBusy && alert == nil && (!isEmpty || !queuedRanges.isEmpty) }

    func addMarkedRange() {
        guard canAddMarkedRange, let markIn = edit.markIn, let markOut = edit.markOut else { return }
        let start = min(markIn, markOut), end = max(markIn, markOut)
        var requests: [ClipRequest] = []
        var media: [URL: MediaInfo] = [:]
        for (segment, offset) in zip(segments, edit.offsets) {
            let lower = max(offset, start), upper = min(offset + segment.duration, end)
            guard lower < upper else { continue }
            let source = segment.source
            requests.append(ClipRequest(file: source.url, from: segment.start + (lower - offset),
                                        to: segment.start + (upper - offset)))
            media[source.url] = source.media
        }
        guard !requests.isEmpty else { return }
        queuedRanges.append(QueuedRange(start: start, end: end, clips: requests, media: media))
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
        runExport { token, progress in
            var media: [URL: MediaInfo] = [:]
            for range in ranges { media.merge(range.media) { first, _ in first } }
            let batch = try BulkExport(groups: ranges.map(\.clips), directory: directory, mode: options.effectiveMode,
                                       tracks: options.tracks, audioTrackOrdinal: options.audioTrackOrdinal,
                                       container: options.container.isEmpty ? nil : options.container,
                                       settings: options.settings, media: media, cancelled: { token.isCancelled })
            for (index, item) in batch.items.enumerated() {
                do {
                    try batch.write(item) { _ = progress((Double(index) + $0) / Double(batch.items.count)) }
                } catch {
                    throw CutError(code: "bulk_interrupted", message: "Wrote \(index) of \(ranges.count) files. "
                                   + "Range \(index + 1): \(error.localizedDescription)")
                }
            }
            let count = ranges.count == 1 ? "1 file" : "\(ranges.count) files"
            return (directory, "Exported \(count) to \(directory.lastPathComponent)")
        }
    }

    var jpegSourceAtPlayhead: EditorJPEGSource? {
        guard !segments.isEmpty else { return nil }
        let clip: EditorSegment
        let picture: RationalTime
        if let (id, edge, cut) = trimAudition, let auditioned = segments.first(where: { $0.id == id }) {
            clip = auditioned
            guard let frame = try? JPEGExport.stillFrameTime(in: clip.source.media, at: cut,
                                                            exclusiveEnd: edge == .end) else { return nil }
            picture = frame
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
            guard frames.indices.contains(index), let frameEnd = try? frames[index].time.adding(frames[index].duration),
                  playhead < sequenceTime(frameEnd) else { return nil }
            picture = max(.zero, frames[index].time)
        } else {
            guard playhead == duration, let last = segments.last,
                  let frame = try? JPEGExport.stillFrameTime(in: last.source.media, at: last.end,
                                                            exclusiveEnd: true) else { return nil }
            clip = last
            picture = frame
        }
        let media = clip.source.media
        let tracks = media.streams.filter { $0.kind == "audio" }
        return EditorJPEGSource(id: clip.source.id, media: media, frame: picture, scenes: sceneReports[clip.source.id],
                                audioStream: tracks.indices.contains(analysisTrack) ? tracks[analysisTrack].index : nil,
                                pauses: sourcePauses[clip.source.id], manualThreshold: manualThresholdDB,
                                effectiveThreshold: effectiveThresholdDB, minimumPause: minimumPause)
    }

    func chooseStillFrame() {
        guard canEdit else { return }
        preview.pause()
        guard let source = jpegSourceAtPlayhead else { return }
        let options = StillFrameSaveOptions()
        let panel = options.panel(source: source.media.url, directory: exportDirectory)
        let currentSession = session
        isPresentingPanel = true
        present(panel) { [weak self, options] accepted in
            guard let self, session == currentSession else { return }
            isPresentingPanel = false
            guard accepted, let output = panel.url else { resumePendingWork(); return }
            exportDirectory = output.deletingLastPathComponent()
            let confirmed = options.confirmedDestination(at: output)
            runExport { token, _ in
                try JPEGExport.writeStill(source.media, at: source.frame, to: output, replacing: confirmed,
                                          cancelled: { token.isCancelled })
                return (output, "Exported " + output.lastPathComponent)
            }
        }
    }

    func chooseJPEGExport() {
        guard canEdit else { return }
        cancelTrim()
        preview.pause()
        guard let source = jpegSourceAtPlayhead else { return }
        let options = JPEGExportOptions(preset: preferences.jpegPreset)
        let panel = options.panel(source: source.media.url, directory: exportDirectory, hasAudio: source.audioStream != nil)
        let currentSession = session
        isPresentingPanel = true
        present(panel) { [weak self, options] accepted in
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            guard accepted, let directory = panel.url else {
                self.resumePendingWork()
                return
            }
            self.exportJPEGFrames(source, to: directory, options: options)
        }
    }

    func exportJPEGFrames(_ source: EditorJPEGSource, to directory: URL, options: JPEGExportOptions) {
        // A notice raised while the panel was open does not withdraw the accepted export.
        guard !isEmpty, !isBusy else { return }
        do {
            let limit = try options.frameLimit()
            let preset = options.preset, sample = options.sample, mode = options.mode
            let useSidecar = useAnalysisSidecars
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
                    let report = try SceneAnalysis.scan(source.media, useSidecar: useSidecar, cancelled: { token.isCancelled })
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
        return source.media.hasVideo && source.media.streams.contains { $0.kind == "audio" } ? source : nil
    }

    var canReplaceSourceAudio: Bool { canEdit && replacementSource != nil }

    func chooseReplacementAudio() {
        guard canEdit, let source = replacementSource else { return }
        cancelTrim()
        preview.pause()
        let choose = NSOpenPanel()
        choose.title = "Replace Source Audio"
        choose.message = "Choose processed audio for the full source file “\(source.name)”."
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
        let currentSession = session
        let token = EditCancellation()
        let useSidecar = useAnalysisSidecars
        isPresentingPanel = false
        cancellation = token
        isCheckingEdit = true
        Task { [self] in
            let inspection = await Task.detached(priority: .userInitiated) {
                Result { try CutEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar).inspectSummary(replacement) }
            }.value
            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            do {
                let control = try ReplacementExportPanel(source: source.media, replacement: inspection.get(),
                                                         sourceName: source.name, useSidecar: useSidecar)
                let panel = NSSavePanel()
                panel.title = "Apply Replacement Audio"
                panel.message = "Save a lossless working copy to use for every cut of this source in the timeline."
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
                    self.applyReplacement(plan, output: output, useSidecar: useSidecar, sourceID: source.id)
                }
            } catch {
                alert = EditorNotice(title: "Couldn’t Replace Audio", message: error.localizedDescription)
                resumePendingWork()
            }
        }
    }

    func applyReplacement(_ plan: AudioReplacementPlan, output: URL, useSidecar: Bool, sourceID: UUID? = nil) {
        // An analysis notice can arrive while the save panel is open.
        guard !isEmpty, !isBusy else { return }
        guard let source = segments.lazy.map(\.source).first(where: {
            $0.url.standardizedFileURL == plan.source.standardizedFileURL && (sourceID == nil || $0.id == sourceID)
        }), source.media.identity == plan.sourceIdentity else {
            alert = EditorNotice(title: "Couldn’t Apply Replacement Audio",
                                 message: "The planned source no longer matches the recording on the timeline.")
            resumePendingWork()
            return
        }
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
        exportTasks[currentSession] = Task {
            defer { exportTasks.removeValue(forKey: currentSession) }
            let exported = await Task.detached(priority: .userInitiated) {
                Result {
                    try AudioReplacementEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar)
                        .exportWorkingCopy(plan, to: output) { report($0 * 0.75) }
                }
            }.value
            guard session == currentSession else { return }
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
                        let media = try CutEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar)
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
            guard session == currentSession else { return }
            cancellation = nil
            isExporting = false
            isCancelling = false
            defer { resumePendingWork() }
            guard !token.isCancelled else {
                statusMessage = saved
                    ? "Audio replacement cancelled. The working copy was saved to \(output.lastPathComponent)."
                    : "Audio replacement cancelled."
                return
            }
            do {
                let updated = try result.get()
                let proposed = segments.map { clip in
                    guard clip.source.id == source.id else { return clip }
                    return EditorSegment(id: clip.id, source: updated, start: clip.start, end: clip.end,
                                         displayRange: clip.displayRange, occurrence: clip.occurrence)
                }
                validate(proposed, selecting: selectedID, at: playhead, action: "Replace Source Audio",
                         replacementTrack: plan.targetAudioOrdinal)
            } catch {
                let message = saved
                    ? "The working copy was saved to \(output.lastPathComponent). \(error.localizedDescription)"
                    : error.localizedDescription
                alert = EditorNotice(title: "Couldn’t Apply Replacement Audio", message: message)
            }
        }
    }

    func chooseExport() {
        chooseExport(mode: nil)
    }

    func chooseExport(mode: ExportMode?) {
        guard canEdit, let first = segments.first else { return }
        cancelTrim()
        preview.pause()
        let currentSession = session
        let token = EditCancellation()
        cancellation = token
        isCheckingEdit = true
        let source = first.source.media
        let preferred = preferredCopyContainer
        let candidate = segments
        let useSidecar = useAnalysisSidecars
        Task {
            let choices = await Task.detached(priority: .userInitiated) {
                ExportContainerChoices(source: source, clips: candidate.map(\.request), preferred: preferred, cancelled: { token.isCancelled })
            }.value
            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            var options = exportOptions
            options.mode = mode ?? defaultExportMode
            options.tracks = source.hasVideo ? .all : .audio
            options.audioTrackOrdinal = nil
            let available = choices.choices(for: options)
            if let preferred, options.tracks == .all, available.contains(preferred) {
                options.copyContainer = preferred
            } else {
                options.copyContainer = available.first ?? source.url.pathExtension.lowercased()
            }
            presentExport(options: options, copyContainers: choices, candidate: candidate, useSidecar: useSidecar)
        }
    }

    private func presentExport(options: ExportSheetOptions, copyContainers: ExportContainerChoices,
                               candidate: [EditorSegment], useSidecar: Bool) {
        guard let first = candidate.first else { return }
        let panel = NSSavePanel()
        panel.title = "Export Media"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = exportDirectory
        panel.nameFieldStringValue = "\(first.source.url.deletingPathExtension().lastPathComponent) Edit.\(options.container)"
        let media = Dictionary(candidate.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        let currentSession = session
        let formatControl = ExportFormatControl(panel: panel, options: options, copyContainers: copyContainers,
                                               clips: candidate.map(\.request), media: media, useSidecar: useSidecar,
                                               changed: { [weak self] options, explicitCopyContainer in
            guard let self, self.session == currentSession else { return }
            self.exportOptions = options
            if explicitCopyContainer { self.preferCopyContainer(options.copyContainer) }
        }, directoryChanged: { [weak self] directory in
            guard let self, self.session == currentSession else { return }
            self.exportDirectory = directory
        })
        isPresentingPanel = true
        present(panel) { [weak self, formatControl] accepted in
            formatControl.stopChecking()
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            if let review = formatControl.appliedReview {
                self.applyExportReview(review)
                self.resumePendingWork()
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
            EditorSegment(id: segment.id, source: segment.source, start: range.from ?? segment.start, end: range.to, displayRange: segment.displayRange, occurrence: segment.occurrence)
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

    func endSession() {
        usesPointerPosition = false
        filmstripTiles = FilmstripTileBuffer()
        sidecarSaveToken?.cancel()
        sidecarSaveToken = nil
        pendingMetadata.removeAll()
        isSavingSidecars = false
        for task in pauseDetections.values { task.cancel() }
        pauseDetections.removeAll()
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
        cancelSceneAnalysis()
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
        analysisTrack = 0
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
        guard let media = edit.preparation.sourceMedia[sourceID], media.hasVideo else { return nil }
        // The header used during provisional import can have a different presentation clock.
        let key = media.frames.isEmpty ? nil : FilmstripTileKey(time: sourceTime, size: size)
        let saved = useAnalysisSidecars ? key.map { (AnalysisSidecar(media: media), $0) } : nil
        return await preview.thumbnail(source: sourceID, url: media.url, at: sourceTime, size: size, saved: saved,
                                       cacheEnabled: { [sidecarPreference] in sidecarPreference.enabled },
                                       preserveAlpha: media.video.hasAlpha || media.video.hasAdditionalVideoLayers) { image in
            if let key, self.edit.preparation.sourceMedia[sourceID] != nil {
                self.filmstripTiles.remember(FilmstripTile(key: key, image: image), source: sourceID)
            }
        }
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
                if let cut = analysisBoundary(in: segment.source, to: target.seconds, after: segment.start, before: segment.end) {
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
                let wanted = marked.lowerBound - offset + segment.start
                guard let cut = boundary(at: index, target: wanted, edge: .end) else { return }
                var left = segment
                left.end = cut
                before.append(left)
            }
            if offset >= marked.upperBound {
                after.append(segment)
            } else if end > marked.upperBound {
                let wanted = marked.upperBound - offset + segment.start
                guard let cut = boundary(at: index, target: wanted, edge: .start) else { return }
                if let left = before.last, left.id == segment.id, left.end >= cut {
                    alert = EditorNotice(title: "Can’t Delete Marked Range", message: "The marks resolve to the same cut point. Move the marks farther apart.")
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

    private func copyBoundaries(for source: IndexedSource) -> BoundaryIndex? {
        guard let container = preferredCopyContainer else { return nil }
        if let cached = copyBoundaryIndices[source.id] { return cached }
        let index = BoundaryIndex(media: source.media, container: container, engine: CutEngine())
        copyBoundaryIndices[source.id] = index
        return index
    }

    private func copyIssue(_ proposed: [EditorSegment]) -> CutError? {
        guard let container = preferredCopyContainer else {
            return CutError(code: "unsupported_container", message: "No copy container is available for this source.")
        }
        do {
            _ = try Self.resolve(proposed, engine: CutEngine(), container: container)
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
    private func blocksAllSnapCandidates(_ issue: CutError, in proposed: [EditorSegment],
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
           proposed[neighbor].source.id == segment.source.id, let container = preferredCopyContainer,
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
            message += "\n\nTo check the existing cuts together, open Export and choose Lossless Copy. Review Cuts shows any proposed changes before you apply them."
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
        guard !isEmpty, !isBusy else { return }
        runExport { token, progress in
            switch plan {
            case .packets(let edit, let mode, let tracks):
                let engine = CutEngine(cancelled: { token.isCancelled }, smartTrim: mode == .smart, tracks: tracks)
                try engine.export(edit, to: output, progress: progress)
            case .conversion(let conversion):
                try ReencodeEngine(cancelled: { token.isCancelled }).write(conversion, to: output) {
                    _ = progress($0)
                }
            }
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
                    try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                        try work(token, reportProgress)
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

    private func validate(_ proposed: [EditorSegment], selecting id: UUID?, at destination: Double,
                          action: String, originalPlayhead: Double? = nil, replacementTrack: Int? = nil) {
        cancelTrim()
        preview.pause()
        let original = originalPlayhead ?? playhead
        guard proposed.allSatisfy({ $0.start >= .zero && $0.start < $0.end && $0.end <= $0.source.duration }) else {
            restorePreview(at: original)
            alert = EditorNotice(title: "Couldn’t \(action)", message: "Keep a nonempty range within each source.")
            return
        }
        let prepared = PreparedEdit(segments: proposed, previous: edit.preparation, engine: CutEngine())
        apply(proposed, prepared: prepared, selecting: id, at: destination, action: action, originalPlayhead: original,
              replacementTrack: replacementTrack)
    }

    private nonisolated static func resolve(_ segments: [EditorSegment], engine: CutEngine,
                                           container: String? = nil) throws -> ResolvedEdit {
        let media = Dictionary(segments.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        return try engine.resolve(segments.map(\.request), media: media, container: container)
    }

    private func apply(_ proposed: [EditorSegment], prepared: PreparedEdit, selecting id: UUID?, at destination: Double,
                       action: String, originalPlayhead: Double? = nil, recordHistory: Bool = true,
                       historySnapshot: EditSnapshot? = nil, preservePreview: Bool = false, replacementTrack: Int? = nil) {
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
            return
        }
        if recordHistory {
            var original = historySnapshot ?? snapshot()
            if let originalPlayhead { original.playhead = originalPlayhead }
            undoStack.append(HistoryEntry(edit: original, action: action, copyContainer: explicitCopyContainer,
                                          analysisTrack: replacementTrack.map { _ in analysisTrack }))
            redoStack.removeAll()
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
            return proposed[index].timeline(sequenceRange: offsets[index].seconds..<end.seconds)
        }
        let keepPreview = preservePreview && segments.map(\.preview) == proposed.map(\.preview)
        let keepMarks = replacementTrack != nil
        edit = EditSnapshot(segments: proposed, timelineClips: clips,
                            timelineThumbnailHeight: clips.lazy.map(\.thumbnailHeight).max() ?? TimelineClip.minimumThumbnailHeight,
                            largeThumbnailHeight: clips.lazy.map { $0.thumbnailHeight(large: true) }.max() ?? TimelineClip.minimumLargeThumbnailHeight,
                            preparation: prepared, selectedID: id,
                            markIn: keepMarks ? edit.markIn : nil, markOut: keepMarks ? edit.markOut : nil,
                            pointerMarkIn: keepMarks && edit.pointerMarkIn, pointerMarkOut: keepMarks && edit.pointerMarkOut,
                            playhead: destination,
                            offsets: offsets, duration: duration)
        if let track = replacementTrack, audioTracks.indices.contains(track), track != analysisTrack { analysisTrack = track }
        syncWaveforms()
        requestSnapAnalysis()
        if !keepPreview { restorePreview(at: destination) }
        updateStatus()
    }

    private func updateStatus() {
        lastExportedURL = nil
        if segments.isEmpty {
            statusMessage = "Add local video or audio files to start."
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
        preview.update(segments.map(monitoredPreview), at: playhead)
    }

    private func monitoredPreview(_ segment: EditorSegment) -> PreviewRange {
        var range = segment.preview
        if range.isAudioOnly { range.audioTrack = analysisTrack }
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
        guard index >= 0 else { return nil }
        return (index, segments[index], edit.offsets[index])
    }

    private func markBoundary(at time: Double) -> RationalTime? {
        guard let (_, segment, offset) = locatedSegment(at: time) else { return edit.duration }
        if time == offset.seconds { return offset }
        let target = time - offset.seconds + segment.start.seconds
        let boundary: RationalTime
        switch usesPointerPosition ? .off : effectiveSnapTarget {
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
            guard let point = analysisBoundary(in: segment.source, to: target, after: segment.start,
                                               before: segment.end, includingLimits: true) else {
                showAnalysisBoundaryError(segment, title: "Can’t Set Mark")
                return nil
            }
            boundary = point
        }
        return offset + (min(max(boundary, segment.start), segment.end) - segment.start)
    }

    private func showAnalysisBoundaryError(_ clip: EditorSegment, title: String) {
        let message: String
        if snapTarget == .scenes {
            message = sceneReports[clip.source.id] == nil ? "Finish Scan for Scenes to snap to scene boundaries." :
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
    private func analysisBoundary(in source: IndexedSource, to target: Double, after minimum: RationalTime? = nil,
                                  before maximum: RationalTime? = nil, includingLimits: Bool = false) -> RationalTime? {
        if snapTarget == .scenes {
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
        nearestBoundaries(in: times, to: target, after: minimum, before: maximum, includingLimits: includingLimits).first { _ in true }
    }

    private func nearestBoundaries<T: RandomAccessCollection>(in times: T, to target: Double, after minimum: RationalTime?,
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
    private func syncWaveforms(invalidatingPauses: Bool = false) {
        if analysisTrack != 0 && !audioTracks.indices.contains(analysisTrack) {
            analysisTrack = 0
            return
        }
        var sources: [UUID: MediaInfo] = [:]
        for clip in segments where clip.source.isIndexed { sources[clip.source.id] = clip.source.media }
        silenceMedia = sources.filter { _, media in
            (media.hasVideo ? !media.frames.isEmpty : !media.audio.isEmpty) && media.streams.filter { $0.kind == "audio" }.indices.contains(analysisTrack)
        }
        activeAudioSources = Set(silenceMedia.keys)
        audioStore.update(sources: sources, track: analysisTrack, useSidecar: useAnalysisSidecars)
        refreshDetectedPauses(invalidating: invalidatingPauses ? activeAudioSources : [])
    }

    private var playheadAudioSource: IndexedSource? {
        locatedSegment(at: playhead)?.1.source ?? segments.last?.source
    }

    var pauseSourceLabel: String? { activeAudioSources.count > 1 ? playheadAudioSource?.name : nil }

    var manualThresholdDB: Double? {
        get {
            guard let id = playheadAudioSource?.id else { return nil }
            return thresholdOverrides[AudioTrackKey(source: id, track: analysisTrack)]
        }
        set {
            guard let id = playheadAudioSource?.id else { return }
            let key = AudioTrackKey(source: id, track: analysisTrack)
            guard thresholdOverrides[key] != newValue else { return }
            setThresholdOverride(newValue, source: id)
            refreshDetectedPauses(invalidating: [id])
        }
    }

    var effectiveThresholdDB: Double? {
        manualThresholdDB ?? playheadAudioSource.flatMap { automaticThresholds[$0.id] }
    }

    private func setThresholdOverride(_ threshold: Double?, source id: UUID) {
        guard let media = silenceMedia[id] else { return }
        let audio = media.streams.filter { $0.kind == "audio" }
        guard audio.indices.contains(analysisTrack) else { return }
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
        if hasSilenceResults {
            // Keep the previous complete report until the rescan succeeds.
            pendingSilenceRescans = activeAudioSources
        }
        silenceScanRequested = true
        silenceIssues.removeAll()
        audioStore.retryFailures()
        syncWaveforms()
    }

    func cancelSilenceScan() {
        if snapTarget == .silence { snapScanRequests.formUnion(activeAudioSources) }
        silenceScanRequested = false
        pendingSilenceRescans.removeAll()
        for task in pauseDetections.values { task.cancel() }
        pauseDetections.removeAll()
        skipPauses = false
        // The waveform has its own consumers and continues to fill the filmstrip.
        refreshDetectedPauses()
    }

    private func refreshDetectedPauses(invalidating changed: Set<UUID> = []) {
        // Once a saved report is visible its controls work just like a fresh scan.
        if !changed.isDisjoint(with: sourcePauses.keys) { silenceScanRequested = true }
        automaticThresholds = automaticThresholds.filter { activeAudioSources.contains($0.key) }
        pendingSilenceRescans.formIntersection(activeAudioSources)
        checkedSilenceSidecars.formIntersection(activeAudioSources.subtracting(changed))
        silenceIssues = silenceIssues.filter { activeAudioSources.contains($0.key) && !changed.contains($0.key) }
        sourcePauses = sourcePauses.filter { !changed.contains($0.key) && activeAudioSources.contains($0.key) }
        for id in Array(pauseDetections.keys) where changed.contains(id) || !activeAudioSources.contains(id) {
            pauseDetections.removeValue(forKey: id)?.cancel()
        }
        let pending = pendingSilenceSources
        for (id, media) in silenceMedia where pending.contains(id) && pauseDetections[id] == nil && silenceIssues[id] == nil {
            let stream = media.streams.filter { $0.kind == "audio" }[analysisTrack].index
            let manual = thresholdOverrides[AudioTrackKey(source: id, track: analysisTrack)]
            let profile = SilenceProfile(stream: stream, threshold: manual, minimum: minimumPause)
            let rescan = pendingSilenceRescans.contains(id)
            if !rescan, let result = silenceResults[id]?[profile] {
                automaticThresholds[id] = result.automaticThresholdDB
                sourcePauses[id] = result.pauses
                continue
            }
            let readSaved = !rescan && useAnalysisSidecars && checkedSilenceSidecars.insert(id).inserted
            let wave = audioStore.finished.contains(id) ? audioStore.waves[id] : nil
            let calibrated = automaticThresholds[id]
            let requested = silenceScanRequested
            let persist = useAnalysisSidecars
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
            pauseDetections[id] = Task {
                do {
                    let (level, result) = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                                onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }
                    automaticThresholds[id] = level
                    if let result {
                        silenceResults[id, default: [:]][profile] = result
                        sourcePauses[id] = result.pauses
                        pendingSilenceRescans.remove(id)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    silenceIssues[id] = error.localizedDescription
                }
                pauseDetections[id] = nil
                refreshDetectedPauses()
            }
        }
        if silenceScanRequested && pendingSilenceSources.isEmpty {
            silenceScanRequested = false
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
        var index = 0
        while index < segments.count {
            var clip = segments[index]
            let offset = edit.offsets[index]
            index += 1
            // A straight split leaves the source audio continuous. Measure and
            // pad its pauses once, even if they cross several timeline pieces.
            while index < segments.count, segments[index].occurrence == clip.occurrence,
                  segments[index].start == clip.end {
                clip.end = segments[index].end
                index += 1
            }
            let lower = max(.zero, scope.from - offset) + clip.start
            let upper = min(clip.end, clip.start + (scope.to - offset))
            guard lower < upper, clip.source.isIndexed, let pauses = sourcePauses[clip.source.id] else { continue }
            let bounds = effectiveSnapTarget == .keyframes ? copyBoundaries(for: clip.source) : nil
            let fullClip = AudioSpan(from: clip.start, to: clip.end)
            var local: [(key: TimelinePause.Key, span: AudioSpan, cut: AudioSpan?, keep: Bool)] = []
            let source = TimelinePause.Source(occurrence: clip.occurrence, track: analysisTrack)
            let protected = protectedPauses[source] ?? []
            let first = pauses.lowerBound { $0.to > lower }
            for pause in pauses[first...] {
                if pause.from >= upper { break }
                let span = AudioSpan(from: max(lower, pause.from), to: min(upper, pause.to))
                guard (span.to - span.from).seconds >= minimumPause else { continue }
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
                    let starts = bounds.starts(first: offset == .zero, last: onlyPiece && offset + clip.duration == edit.duration)
                    let ends = bounds.ends(first: onlyPiece && offset == .zero, last: offset + clip.duration == edit.duration)
                    local[i].cut = AudioAnalysis.removal(in: span, leave: 0, ends: ends, starts: starts, clip: fullClip)
                }
            }
            func sequence(_ range: AudioSpan) -> AudioSpan {
                AudioSpan(from: offset + (range.from - clip.start), to: offset + (range.to - clip.start))
            }
            for pause in local {
                if let cut = pause.cut {
                    count += 1
                    seconds += (cut.to - cut.from).seconds
                }
                plan.append(TimelinePause(key: pause.key, sequence: sequence(pause.span), removal: pause.cut.map(sequence),
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

    var canUseRoomTone: Bool {
        guard pauseAnalysisReady, hasPauseMarks else { return false }
        let scope = pauseScope
        guard scope.from < scope.to else { return false }
        return zip(segments, edit.offsets).allSatisfy { clip, offset in
            offset >= scope.to || offset + clip.duration <= scope.from ||
                audioStore.finished.contains(clip.source.id)
        }
    }

    func useRoomTone() {
        guard canUseRoomTone else { return }
        let scope = pauseScope
        var peaks: [UUID: Float] = [:]
        for (clip, offset) in zip(segments, edit.offsets) {
            let from = max(scope.from, offset)
            let to = min(scope.to, offset + clip.duration)
            guard from < to else { continue }
            let start = clip.start + (from - offset)
            let end = clip.start + (to - offset)
            if let value = audioStore.waves[clip.source.id]?.peak(from: start.seconds, to: end.seconds) {
                peaks[clip.source.id] = max(peaks[clip.source.id] ?? 0, value)
            }
        }
        guard !peaks.isEmpty else { return }
        for (id, peak) in peaks {
            setThresholdOverride(AudioAnalysis.roomToneThresholdDB(forPeak: peak), source: id)
        }
        refreshDetectedPauses(invalidating: Set(peaks.keys))
        clearMarks()
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
            let start = clip.start + (max(span.from, offset) - offset)
            let end = clip.start + (min(span.to, offset + clip.duration) - offset)
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
            let from = max(span.from, span.to - remaining)
            beforeRanges.append(AudioSpan(from: from, to: span.to))
            remaining = remaining - (span.to - from)
            if remaining == .zero { break }
        }
        remaining = second
        for span in kept[after...] {
            let to = min(span.to, span.from + remaining)
            afterRanges.append(AudioSpan(from: span.from, to: to))
            remaining = remaining - (to - span.from)
            if remaining == .zero { break }
        }
        let ranges = (beforeRanges.reversed() + afterRanges).flatMap(pieces).map(monitoredPreview)
        cutPreview = ranges.isEmpty ? nil : CutPreview(id: id, position: pause.sequence.from, pauseKey: pause.key, ranges: ranges)
    }

    func applyPauses(queueTakes: Bool) {
        guard pauseAnalysisReady else { return }
        let cuts = pausePlan.compactMap(\.removal)
        guard !cuts.isEmpty else { return }
        let scope = queueTakes ? pauseScope : AudioSpan(from: .zero, to: edit.duration)
        let ranges = AudioAnalysis.retained(in: scope, removing: cuts)
        guard !ranges.isEmpty else {
            alert = EditorNotice(title: "No media to keep", message: "Increase the time left in each pause or keep a pause.")
            return
        }
        if queueTakes {
            let takes = ranges.map { range in
                let clips = pieces(in: range)
                let media = Dictionary(clips.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
                return QueuedRange(start: range.from, end: range.to, clips: clips.map(\.request), media: media)
            }
            queuedRanges.append(contentsOf: takes)
            statusMessage = "Added \(ranges.count) takes to the export queue."
            return
        }
        let proposed = ranges.flatMap(pieces)
        if effectiveSnapTarget == .keyframes, let issue = copyIssue(proposed) {
            alert = EditorNotice(title: "Cannot Copy These Joins", message: issue.message)
            return
        }
        let removedBefore = cuts.reduce(0.0) { $0 + max(0, min(playhead, $1.to.seconds) - $1.from.seconds) }
        validate(proposed, selecting: proposed.first?.id, at: playhead - removedBefore, action: "Shorten Pauses")
    }
}
