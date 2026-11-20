import AppKit
import Combine
import Foundation
import MPCutCore

private struct IndexedSource: Sendable {
    let id: UUID
    let media: MediaInfo
    let frames: [RationalTime]
    let keyframes: [RationalTime]
    let frameBoundaries: [RationalTime]
    let keyframeSeconds: [Double]
    let thumbnailSyncTimes: [Double]

    init(media: MediaInfo, id: UUID = UUID()) {
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

    var url: URL { media.url }
    var name: String { url.lastPathComponent }
    var duration: RationalTime { media.duration }
}

private struct EditorSegment: Sendable {
    let id: UUID
    let source: IndexedSource
    var start: RationalTime
    var end: RationalTime

    init(id: UUID = UUID(), source: IndexedSource, start: RationalTime = .zero, end: RationalTime? = nil) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end ?? source.duration
    }

    var duration: RationalTime { end - start }
    var preview: PreviewRange { PreviewRange(url: source.url, exactStart: start, exactEnd: end) }
    var request: ClipRequest { ClipRequest(file: source.url, from: start, to: end) }
    func timeline(sequenceRange: Range<Double>) -> TimelineClip {
        TimelineClip(id: id, sourceID: source.id, name: source.name, sourceStart: start.seconds, sourceEnd: end.seconds,
                     sourceDuration: source.duration.seconds, keyframes: source.keyframeSeconds,
                     thumbnailSyncTimes: source.thumbnailSyncTimes, frames: source.frames,
                     displaySize: CGSize(width: source.media.video.displayWidth, height: source.media.video.displayHeight),
                     sequenceRange: sequenceRange, isIndexed: !source.frames.isEmpty)
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
    var sourceURLs: [UUID: URL] = [:]

    init() {}

    init(segments: [EditorSegment], previous: Self, engine: CutEngine) {
        sourceURLs = Dictionary(segments.map { ($0.source.id, $0.source.url) }, uniquingKeysWith: { first, _ in first })
        guard let first = segments.first?.source, !first.frames.isEmpty else { return }
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
    var playhead: Double = 0
    var offsets: [RationalTime] = []
    var duration: RationalTime = .zero
}

private final class EditCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reportedProgress = 0.0

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func shouldReport(_ fraction: Double) -> Bool {
        lock.withLock {
            guard fraction > reportedProgress, fraction == 1 || fraction >= reportedProgress + 0.005 else { return false }
            reportedProgress = fraction
            return true
        }
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
    let preview = SequencePreview()

    @Published private var edit = EditSnapshot()
    @Published private(set) var playhead = 0.0
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var isCancelling = false
    @Published private(set) var exportProgress = 0.0
    @Published private(set) var statusMessage = "Add local video files to start."
    @Published private(set) var lastExportedURL: URL?
    @Published private(set) var isCheckingEdit = false
    @Published private var isPresentingPanel = false
    @Published private(set) var queuedRanges: [QueuedRange] = []
    @Published var isBulkQueuePresented = false
    @Published var alert: EditorNotice?
    @Published var snapToKeyframes = false
    @Published var largeThumbnails = UserDefaults.standard.bool(forKey: "largeTimelineThumbnails") {
        didSet { UserDefaults.standard.set(largeThumbnails, forKey: "largeTimelineThumbnails") }
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
    }
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private var previewTimeObservation: AnyCancellable?
    private var trimOrigin: Double?
    private var trimAudition: (UUID, TimelineEdge, RationalTime)?
    private var cancellation: EditCancellation?
    private var exportOptions = ExportSheetOptions()
    private var exportDirectory: URL?
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    private var waitingForExportCleanup = false
    private var pendingOpenFiles: [URL] = []
    private var session = UUID()
    private var sceneToken: EditCancellation?
    private var sceneReports: [UUID: SceneReport] = [:]
    private(set) var scenesBySource: [UUID: [TimelineScene]] = [:]
    private(set) var viewNamesBySource: [UUID: [Int: String]] = [:]
    @Published private(set) var sceneProgress: Double?
    @Published private(set) var sceneRevision = 0


    init() {
        previewTimeObservation = preview.$time.sink { [weak self] time in
            guard let self, self.trimOrigin == nil else { return }
            let clamped = min(max(0, time), self.duration)
            if clamped != self.playhead { self.playhead = clamped }
        }
    }

    private var segments: [EditorSegment] { edit.segments }
    var timelineClips: [TimelineClip] { edit.timelineClips }
    var timelineThumbnailHeight: CGFloat {
        largeThumbnails ? edit.largeThumbnailHeight : edit.timelineThumbnailHeight
    }
    var isEmpty: Bool { segments.isEmpty }
    var selectedID: UUID? { edit.selectedID }
    var preferredCopyContainer: String? { explicitCopyContainer ?? edit.preparation.container }
    var markIn: Double? { edit.markIn?.seconds }
    var markOut: Double? { edit.markOut?.seconds }
    var duration: Double { edit.duration.seconds }
    var isBusy: Bool { isImporting || isExporting || isCheckingEdit || isPresentingPanel || isBulkQueuePresented || waitingForExportCleanup }
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
        _ = trim(clip.id, edge: edge, sourceTime: sourceTime, commit: true)
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
        let video = media.video
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
            self.importPendingFiles()
        }
    }

    func openFiles(_ urls: [URL]) {
        pendingOpenFiles.append(contentsOf: urls.filter(\.isFileURL))
        importPendingFiles()
    }

    private func importPendingFiles() {
        guard !isBusy, alert == nil, !pendingOpenFiles.isEmpty else { return }
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
        importPendingFiles()
    }

    func importFiles(_ urls: [URL], at index: Int? = nil) {
        guard !isBusy, !urls.isEmpty else { return }
        cancelTrim()
        preview.pause()
        let token = EditCancellation()
        cancellation = token
        let engine = CutEngine(cancelled: { token.isCancelled })
        let existing = segments
        let priorPreparation = edit.preparation
        let beforeImport = snapshot()
        let insertion = min(max(0, index ?? existing.count), existing.count)
        let currentSession = session
        isImporting = true
        Task {
            let result = await Task.detached(priority: .utility) {
                var additions: [EditorSegment] = []
                var rejected: [String] = []
                var indexed = Dictionary(existing.map { ($0.source.url, $0.source) }, uniquingKeysWith: { first, _ in first })
                var reference = existing.first?.source.media
                var lastPublication: ContinuousClock.Instant?
                var prior = priorPreparation
                for (offset, file) in urls.enumerated() {
                    if token.isCancelled { break }
                    let canonical = file.standardizedFileURL
                    var provisional: EditorSegment?
                    do {
                        let source: IndexedSource
                        if let cached = indexed[canonical] {
                            source = cached
                        } else {
                            let header: MediaInfo?
                            if existing.isEmpty, additions.isEmpty,
                               let preview = try? engine.inspectForPreview(canonical), preview.timelineIssue == nil {
                                header = preview
                                let clip = EditorSegment(source: IndexedSource(media: preview))
                                provisional = clip
                                let prepared = PreparedEdit(segments: [clip], previous: prior, engine: engine)
                                await MainActor.run {
                                    guard self.session == currentSession, !token.isCancelled else { return }
                                    self.apply([clip], prepared: prepared, selecting: clip.id, at: 0,
                                               action: "Add Clip", recordHistory: false)
                                }
                            } else {
                                header = nil
                            }
                            let media = try engine.inspect(canonical, keyframes: true, matchingPreview: header)
                            try Self.checkEditable(media)
                            if let reference { try engine.checkCompatibility(media, with: reference) }
                            source = IndexedSource(media: media, id: provisional?.source.id ?? UUID())
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
                return (candidate, additions.count, rejected, prepared)
            }.value

            guard session == currentSession else { return }
            isImporting = false
            isCancelling = false
            cancellation = nil
            defer { importPendingFiles() }
            if token.isCancelled {
                edit = beforeImport
                restorePreview(at: beforeImport.playhead)
                updateStatus()
                return
            }
            if result.1 > 0 {
                apply(result.0, prepared: result.3, selecting: result.0[insertion].id, at: playhead,
                      action: result.1 == 1 ? "Add Clip" : "Add Clips", historySnapshot: beforeImport,
                      preservePreview: true)
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
        cancelTrim()
        preview.pause()
        playhead = min(max(0, time), duration)
        preview.seek(to: playhead)
    }

    func scrub(_ position: Double) {
        guard position.isFinite, canNavigate else { return }
        let target = min(max(position, 0), duration)
        let index = locatedSegment(at: target)?.0 ?? segments.count - 1
        let segment = segments[index]
        let local = segment.start.seconds + (target - edit.offsets[index].seconds)
        let frames = segment.source.frames
        let next = frames.lowerBound { $0.seconds > local + 1e-9 || $0 >= segment.end }
        let frame = max(segment.start, next > 0 ? frames[next - 1] : segment.start)
        preview.scrub(to: target, rangeIndex: index, sourceFrame: frames.isEmpty ? local : frame.seconds)
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
        guard canRenameCurrentView, let current = currentScene, let window = NSApp.keyWindow else { return }
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
            self.importPendingFiles()
        }
    }

    func setViewName(_ text: String, source: UUID, view: Int) {
        guard let report = sceneReports[source], view > 0, view <= report.viewCount else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        viewNamesBySource[source, default: [:]][view] = name.isEmpty ? nil : name
        sceneRevision += 1
    }

    func cancelSceneAnalysis() {
        sceneToken?.cancel()
        sceneToken = nil
        sceneProgress = nil
        scenesBySource = scenesBySource.filter { sceneReports[$0.key] != nil }
        sceneRevision += 1
    }

    var canScanScenes: Bool {
        canEdit && sceneProgress == nil && segments.contains { sceneReports[$0.source.id] == nil }
    }

    var canStepScenes: Bool {
        guard canEdit, sceneProgress == nil, let first = segments.first,
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
        sceneProgress = 0
        Task {
            do {
                for (i, source) in sources.enumerated() {
                    let report = try await Task.detached(priority: .utility) { [self] in
                        try SceneAnalysis.scan(source.media, cancelled: { token.isCancelled }, progress: { fraction in
                            let total = (Double(i) + fraction) / Double(sources.count)
                            guard token.shouldReport(total) else { return }
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sceneToken === token else { return }
                                self.sceneProgress = total
                            }
                        }, onScene: { time, view in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sceneToken === token, self.sceneReports[source.id] == nil else { return }
                                self.scenesBySource[source.id, default: []].append(TimelineScene(start: time.seconds, view: view))
                                self.sceneRevision += 1
                            }
                        })
                    }.value
                    guard sceneToken === token else { return }
                    sceneReports[source.id] = report
                    scenesBySource[source.id] = report.scenes.map { TimelineScene(start: $0.startSeconds, view: $0.view) }
                    sceneRevision += 1
                }
                sceneToken = nil
                sceneProgress = nil
            } catch {
                guard sceneToken === token else { return }
                cancelSceneAnalysis()
                alert = EditorNotice(title: "Scene Analysis", message: error.localizedDescription)
            }
        }
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
            let times = keyframes ? segment.source.keyframes : segment.source.frames
            let local = playhead - offset.seconds + segment.start.seconds
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
        edit.markIn = frameBoundary(at: playhead)
    }

    func setOut() {
        guard canEdit else { return }
        preview.pause()
        edit.markOut = frameBoundary(at: playhead)
    }

    func clearMarks() {
        guard canClearMarks else { return }
        edit.markIn = nil
        edit.markOut = nil
    }

    func split() {
        guard canEdit else { return }
        cancelTrim()
        preview.pause()
        guard let (index, segment, offset) = locatedSegment(at: playhead) else { return }
        let target = playhead - offset.seconds + segment.start.seconds
        guard playhead - offset.seconds > max(playhead.ulp * 4, 0.000000001) else {
            alert = EditorNotice(title: "Can’t Split Clip", message: "The playhead is already at a cut. Move it inside a clip to split it.")
            return
        }
        let candidates = snapToKeyframes ? copyBoundaries(for: segment.source)?.splitPoints ?? [] : segment.source.frames
        let rightID = UUID()
        var firstIssue: EditorNotice?
        for cut in nearestBoundaries(in: candidates, to: target, after: segment.start, before: segment.end) {
            var proposed = segments
            proposed[index].end = cut
            proposed.insert(EditorSegment(id: rightID, source: segment.source, start: cut, end: segment.end), at: index + 1)
            if snapToKeyframes, let error = copyIssue(proposed) {
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
        } else if snapToKeyframes {
            showCopyBoundaryError(segment, at: target, edge: .start, title: "Can’t Split Clip", first: false, last: false)
        } else {
            alert = EditorNotice(title: "Can’t Split Clip", message: "There is no frame boundary inside this range.")
        }
    }

    func trim(_ id: UUID, edge: TimelineEdge, sourceTime: Double, commit: Bool) -> Double? {
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
        if snapToKeyframes {
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
        } else {
            guard let frame = nearest(in: segment.source.frameBoundaries, to: sourceTime, after: minimum, before: maximum) else {
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
                trimAudition = (id, edge, cut)
                let auditionTime = edge == .end ? precedingFrame(in: segment, before: cut) : cut
                preview.audition(segment.preview, at: auditionTime.seconds)
            }
            return cut.seconds
        }

        let original = trimOrigin ?? playhead
        if cut == originalBoundary {
            if snapToKeyframes,
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
        redoStack.append(HistoryEntry(edit: snapshot(), action: previous.action))
        copyBoundaryIndices.removeAll()
        edit = previous.edit
        restorePreview(at: edit.playhead)
        updateStatus()
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        cancelTrim()
        undoStack.append(HistoryEntry(edit: snapshot(), action: next.action))
        copyBoundaryIndices.removeAll()
        edit = next.edit
        restorePreview(at: edit.playhead)
        updateStatus()
    }

    func preferCopyContainer(_ container: String) {
        explicitCopyContainer = container
        copyBoundaryIndices.removeAll()
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

    func bulkQueueDismissed() { importPendingFiles() }

    func chooseBulkDestination(options: ExportSheetOptions) {
        guard isBulkQueuePresented, !queuedRanges.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Queued Ranges"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportDirectory
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        exportQueuedRanges(to: directory, options: options)
    }

    func exportQueuedRanges(to directory: URL, options: ExportSheetOptions) {
        guard isBulkQueuePresented, !queuedRanges.isEmpty else { return }
        exportDirectory = directory
        isBulkQueuePresented = false
        let ranges = queuedRanges
        runExport { token, progress in
            var media: [URL: MediaInfo] = [:]
            for range in ranges { media.merge(range.media) { first, _ in first } }
            let batch = try BulkExport(groups: ranges.map(\.clips), directory: directory, mode: options.mode,
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
        Task {
            let containers = await Task.detached(priority: .userInitiated) {
                CutEngine(cancelled: { token.isCancelled }).suggestedContainers(for: source)
            }.value
            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            let choices = containers.isEmpty ? [preferred ?? exportOptions.copyContainer] : containers
            var options = exportOptions
            if let mode { options.mode = mode }
            if let preferred, choices.contains(preferred) {
                options.copyContainer = preferred
            } else {
                options.copyContainer = choices[0]
            }
            presentExport(options: options, copyContainers: choices, candidate: candidate)
        }
    }

    private func presentExport(options: ExportSheetOptions, copyContainers: [String], candidate: [EditorSegment]) {
        guard let first = candidate.first else { return }
        let panel = NSSavePanel()
        panel.title = "Export Movie"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = exportDirectory
        panel.nameFieldStringValue = "\(first.source.url.deletingPathExtension().lastPathComponent) Edit.\(options.container)"
        let media = Dictionary(candidate.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        let currentSession = session
        let formatControl = ExportFormatControl(panel: panel, options: options, copyContainers: copyContainers,
                                               clips: candidate.map(\.request), media: media,
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
                self.importPendingFiles()
            } else if accepted, let output = panel.url, let plan = formatControl.selected {
                self.exportDirectory = output.deletingLastPathComponent()
                self.export(plan, to: output)
            } else {
                self.importPendingFiles()
            }
        }
    }

    func applyExportReview(_ review: ExportCutReview) {
        guard canEdit, segments.count == review.original.count,
              zip(segments, review.original).allSatisfy({ segment, range in
                  segment.source.url == range.file && segment.start == range.from && segment.end == range.to
              }) else { return }
        let proposed = zip(segments, review.revised).map { segment, range in
            EditorSegment(id: segment.id, source: segment.source, start: range.from ?? segment.start, end: range.to)
        }
        validate(proposed, selecting: selectedID, at: playhead, action: "Apply Reviewed Cuts")
    }

    func cancelExport() {
        guard isExporting else { return }
        isCancelling = true
        cancellation?.cancel()
    }

    func cancelAndWaitForExport(_ completion: @escaping () -> Void) -> Bool {
        guard !exportTasks.isEmpty else { return false }
        waitingForExportCleanup = true
        cancelExport()
        // A closed session may still be removing its staged file. Each closed
        // session already cancelled its own export when the window closed.
        let pending = Array(exportTasks.values)
        Task {
            for task in pending { await task.value }
            waitingForExportCleanup = false
            completion()
        }
        return true
    }

    func endSession() {
        cancelSceneAnalysis()
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
        exportDirectory = nil
        snapToKeyframes = false
        timelineZoom = 0
        explicitCopyContainer = nil
        copyBoundaryIndices.removeAll()
        checkingTrim = nil
        trimChecks.removeAll()
        edit = EditSnapshot()
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
        guard let url = edit.preparation.sourceURLs[sourceID] else { return nil }
        return await preview.thumbnail(source: sourceID, url: url, at: sourceTime, size: size)
    }

    private func deleteMarkedRange(_ marked: ClosedRange<RationalTime>) {
        let keepsLeading = marked.lowerBound > .zero
        let keepsTrailing = marked.upperBound < edit.duration
        var before: [EditorSegment] = []
        var after: [EditorSegment] = []
        for (index, pair) in zip(segments, edit.offsets).enumerated() {
            let (segment, offset) = pair
            let end = offset + segment.duration
            if end <= marked.lowerBound {
                before.append(segment)
            } else if offset < marked.lowerBound {
                let wanted = marked.lowerBound - offset + segment.start
                var left = segment
                if snapToKeyframes {
                    let first = isContinuousCopyRange(segments.prefix(index + 1))
                    let choices = copyBoundaries(for: segment.source)?.ends(first: first, last: !keepsTrailing) ?? []
                    guard let cut = nearest(in: choices, to: wanted.seconds, after: segment.start, before: segment.end) else {
                        showCopyBoundaryError(segment, at: wanted.seconds, edge: .end, title: "Can’t Delete Marked Range",
                                              first: first, last: !keepsTrailing)
                        return
                    }
                    left.end = cut
                } else {
                    left.end = wanted
                }
                before.append(left)
            }
            if offset >= marked.upperBound {
                after.append(segment)
            } else if end > marked.upperBound {
                let wanted = marked.upperBound - offset + segment.start
                let cut: RationalTime
                if snapToKeyframes {
                    let last = isContinuousCopyRange(segments.suffix(from: index))
                    let choices = copyBoundaries(for: segment.source)?.starts(first: !keepsLeading, last: last) ?? []
                    guard let snapped = nearest(in: choices, to: wanted.seconds, after: segment.start, before: segment.end) else {
                        showCopyBoundaryError(segment, at: wanted.seconds, edge: .start, title: "Can’t Delete Marked Range",
                                              first: !keepsLeading, last: last)
                        return
                    }
                    cut = snapped
                } else {
                    cut = wanted
                }
                if let left = before.last, left.id == segment.id, left.end >= cut {
                    alert = EditorNotice(title: "Can’t Delete Marked Range", message: "The marks resolve to the same cut point. Move the marks farther apart.")
                    return
                }
                let id = before.last?.id == segment.id ? UUID() : segment.id
                after.append(EditorSegment(id: id, source: segment.source, start: cut, end: segment.end))
            }
        }
        let proposed = before + after
        if snapToKeyframes, !proposed.isEmpty, let error = copyIssue(proposed) {
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
        guard media.duration > .zero, !media.frames.isEmpty else {
            throw CutError(code: "invalid_input", message: "The video has no indexed presentation frames.")
        }
    }

    private func export(_ plan: EditorExportPlan, to output: URL) {
        guard canEdit else { return }
        runExport { token, progress in
            switch plan {
            case .packets(let edit, let mode):
                let engine = CutEngine(cancelled: { token.isCancelled }, smartTrim: mode == .smart)
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
                Result { try work(token, reportProgress) }
            }.value

            exportTasks.removeValue(forKey: currentSession)
            guard session == currentSession else { return }
            isExporting = false
            isCancelling = false
            cancellation = nil
            defer { importPendingFiles() }
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
                          action: String, originalPlayhead: Double? = nil) {
        cancelTrim()
        preview.pause()
        let original = originalPlayhead ?? playhead
        guard proposed.allSatisfy({ $0.start >= .zero && $0.start < $0.end && $0.end <= $0.source.duration }) else {
            restorePreview(at: original)
            alert = EditorNotice(title: "Couldn’t \(action)", message: "The range must contain at least one source frame.")
            return
        }
        let prepared = PreparedEdit(segments: proposed, previous: edit.preparation, engine: CutEngine())
        apply(proposed, prepared: prepared, selecting: id, at: destination, action: action, originalPlayhead: original)
    }

    private nonisolated static func resolve(_ segments: [EditorSegment], engine: CutEngine,
                                           container: String? = nil) throws -> ResolvedEdit {
        let media = Dictionary(segments.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        return try engine.resolve(segments.map(\.request), media: media, container: container)
    }

    private func apply(_ proposed: [EditorSegment], prepared: PreparedEdit, selecting id: UUID?, at destination: Double,
                       action: String, originalPlayhead: Double? = nil, recordHistory: Bool = true,
                       historySnapshot: EditSnapshot? = nil, preservePreview: Bool = false) {
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
            undoStack.append(HistoryEntry(edit: original, action: action))
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
            copyBoundaryIndices = copyBoundaryIndices.filter { prepared.sourceURLs[$0.key] != nil }
        }
        let clips = proposed.indices.map { index in
            let end = index + 1 < offsets.count ? offsets[index + 1] : duration
            return proposed[index].timeline(sequenceRange: offsets[index].seconds..<end.seconds)
        }
        let keepPreview = preservePreview && segments.map(\.preview) == proposed.map(\.preview)
        edit = EditSnapshot(segments: proposed, timelineClips: clips,
                            timelineThumbnailHeight: clips.lazy.map(\.thumbnailHeight).max() ?? TimelineClip.minimumThumbnailHeight,
                            largeThumbnailHeight: clips.lazy.map { $0.thumbnailHeight(large: true) }.max() ?? TimelineClip.minimumLargeThumbnailHeight,
                            preparation: prepared, selectedID: id, playhead: destination,
                            offsets: offsets, duration: duration)
        if !keepPreview { restorePreview(at: destination) }
        updateStatus()
    }

    private func updateStatus() {
        lastExportedURL = nil
        if segments.isEmpty {
            statusMessage = "Add local video files to start."
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
        preview.pause()
        playhead = min(max(0, time), duration)
        preview.update(segments.map(\.preview), at: playhead)
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

    private func frameBoundary(at time: Double) -> RationalTime {
        guard let (_, segment, offset) = locatedSegment(at: time) else { return edit.duration }
        let target = time - offset.seconds + segment.start.seconds
        let boundary = nearest(in: segment.source.frameBoundaries, to: target) ?? segment.start
        return offset + (min(max(boundary, segment.start), segment.end) - segment.start)
    }

    private func nearest(in times: [RationalTime], to target: Double, after minimum: RationalTime? = nil,
                         before maximum: RationalTime? = nil) -> RationalTime? {
        nearestBoundaries(in: times, to: target, after: minimum, before: maximum).first { _ in true }
    }

    private func nearestBoundaries(in times: [RationalTime], to target: Double, after minimum: RationalTime?,
                                   before maximum: RationalTime?) -> AnySequence<RationalTime> {
        let start = minimum.map { min in times.lowerBound { $0 > min } } ?? 0
        let end = maximum.map { max in times.lowerBound { $0 >= max } } ?? times.count
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
        let frames = segment.source.frames
        let index = frames.lowerBound { $0 >= time } - 1
        return index >= 0 ? frames[index] : segment.start
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (Bool) -> Void) {
        // Preflight can finish after the editor has lost keyboard focus.
        let editorWindow = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        if let window = editorWindow {
            panel.beginSheetModal(for: window) { response in completion(response == .OK) }
        } else {
            panel.begin { response in completion(response == .OK) }
        }
    }
}

extension Array {
    func lowerBound(where predicate: (Element) -> Bool) -> Int {
        var lower = 0
        var upper = count
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
