import AppKit
import Combine
import Foundation
import MPCutCore

private struct IndexedSource: Sendable {
    let media: MediaInfo
    let frames: [RationalTime]
    let keyframes: [RationalTime]
    let keyframeSeconds: [Double]

    init(media: MediaInfo) {
        self.media = media
        frames = media.frames.map(\.time)
        keyframes = media.frames.lazy.filter(\.keyframe).map(\.time)
        keyframeSeconds = keyframes.map(\.seconds)
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
    var timeline: TimelineClip {
        TimelineClip(id: id, name: source.name, sourceStart: start.seconds, sourceEnd: end.seconds,
                     sourceDuration: source.duration.seconds, keyframes: source.keyframeSeconds)
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
        firstStarts = engine.validBoundaries(in: media, start: true, last: false, container: container)
        interiorStarts = engine.validBoundaries(in: media, start: true, first: false, last: false, container: container)
        wholeEnds = engine.validBoundaries(in: media, start: false, container: container)
        finalEnds = engine.validBoundaries(in: media, start: false, first: false, container: container)
        interiorEnds = engine.validBoundaries(in: media, start: false, first: false, last: false, container: container)
        let starts = Set(interiorStarts)
        splitPoints = interiorEnds.filter { starts.contains($0) }
    }
}

private struct PreparedEdit: Sendable {
    var container: String?
    var bySource: [URL: BoundaryIndex] = [:]

    init() {}

    init(segments: [EditorSegment], container: String, previous: Self, engine: CutEngine) {
        self.container = container
        for segment in segments where bySource[segment.source.url] == nil {
            let source = segment.source
            if previous.container == container, let cached = previous.bySource[source.url] {
                bySource[source.url] = cached
            } else {
                bySource[source.url] = BoundaryIndex(media: source.media, container: container, engine: engine)
            }
        }
    }
}

private struct EditSnapshot {
    var segments: [EditorSegment] = []
    var preparation = PreparedEdit()
    var selectedID: UUID?
    var markIn: Double?
    var markOut: Double?
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
    @Published var alert: EditorNotice?

    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var previewTimeObservation: AnyCancellable?
    private var trimOrigin: Double?
    private var trimAudition: (UUID, TimelineEdge, RationalTime)?
    private var cancellation: EditCancellation?
    private var exportTask: Task<Void, Never>?
    private var pendingOpenFiles: [URL] = []
    private var session = UUID()

    init() {
        previewTimeObservation = preview.$time.sink { [weak self] time in
            guard let self, self.trimOrigin == nil else { return }
            let clamped = min(max(0, time), self.duration)
            if clamped != self.playhead { self.playhead = clamped }
        }
    }

    private var segments: [EditorSegment] { edit.segments }
    var timelineClips: [TimelineClip] { segments.map(\.timeline) }
    var isEmpty: Bool { segments.isEmpty }
    var selectedID: UUID? { edit.selectedID }
    var markIn: Double? { edit.markIn }
    var markOut: Double? { edit.markOut }
    var duration: Double { edit.duration.seconds }
    var isBusy: Bool { isImporting || isExporting || isCheckingEdit || isPresentingPanel }
    var canEdit: Bool { !isEmpty && !isBusy }
    var canUndo: Bool { !isBusy && !undoStack.isEmpty }
    var canRedo: Bool { !isBusy && !redoStack.isEmpty }
    var canDelete: Bool { canEdit && (markedRange != nil || selectedID != nil) }
    var canClearMarks: Bool { !isBusy && (markIn != nil || markOut != nil) }

    var markedRange: ClosedRange<Double>? {
        guard let markIn, let markOut, markIn != markOut else { return nil }
        return min(markIn, markOut)...max(markIn, markOut)
    }

    var formatSummary: String? {
        guard let media = segments.first?.source.media else { return nil }
        return "\(media.video.width) × \(media.video.height) · \(media.video.codec.uppercased())"
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
        let insertion = min(max(0, index ?? existing.count), existing.count)
        let currentSession = session
        isImporting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var candidate = existing
                var rejected: [String] = []
                var resolvedContainer: String?
                var accepted = 0
                var indexed = Dictionary(existing.map { ($0.source.url, $0.source) }, uniquingKeysWith: { first, _ in first })
                for file in urls {
                    if token.isCancelled { break }
                    let canonical = file.standardizedFileURL
                    do {
                        let source: IndexedSource
                        if let cached = indexed[canonical] {
                            source = cached
                        } else {
                            let media = try engine.inspect(canonical, keyframes: true)
                            if let reason = media.copyIssue {
                                throw CutError(code: "unsupported_copy", message: reason)
                            }
                            if let reference = candidate.first?.source.media {
                                try engine.checkCompatibility(media, with: reference)
                            }
                            source = IndexedSource(media: media)
                            indexed[canonical] = source
                        }
                        var proposed = candidate
                        proposed.insert(EditorSegment(source: source), at: insertion + accepted)
                        resolvedContainer = try Self.resolve(proposed, engine: engine).container
                        candidate = proposed
                        accepted += 1
                    } catch {
                        rejected.append("\(file.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                let prepared = resolvedContainer.map {
                    PreparedEdit(segments: candidate, container: $0, previous: priorPreparation, engine: engine)
                } ?? priorPreparation
                return (candidate, accepted, rejected, prepared)
            }.value

            guard session == currentSession else { return }
            isImporting = false
            cancellation = nil
            defer { importPendingFiles() }
            if result.1 > 0 {
                let startingTime = existing.isEmpty ? 0 : playhead
                apply(result.0, prepared: result.3, selecting: result.0[insertion].id, at: startingTime)
            }
            if !result.2.isEmpty {
                alert = EditorNotice(title: result.2.count == 1 ? "Couldn’t Add Clip" : "Couldn’t Add Some Clips",
                                     message: result.2.joined(separator: "\n\n"))
            }
        }
    }

    func select(_ id: UUID) {
        guard !isBusy, segments.contains(where: { $0.id == id }) else { return }
        edit.selectedID = id
    }

    func seek(_ time: Double) {
        guard time.isFinite, canEdit else { return }
        cancelTrim()
        preview.pause()
        playhead = min(max(0, time), duration)
        preview.seek(to: playhead)
    }

    func step(_ direction: Int, keyframes: Bool = false) {
        guard canEdit, direction != 0 else { return }
        cancelTrim()
        preview.pause()
        let candidates = positionedSegments()
        let tolerance = max(playhead.ulp * 4, 0.000000001)
        for (segment, offset) in direction > 0 ? candidates : Array(candidates.reversed()) {
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
        edit.markIn = playhead
    }

    func setOut() {
        guard canEdit else { return }
        preview.pause()
        edit.markOut = playhead
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
        guard playhead - offset.seconds > max(playhead.ulp * 4, 0.000000001) else { return }
        guard let boundaries = edit.preparation.bySource[segment.source.url],
              let cut = nearest(in: boundaries.splitPoints, to: target, after: segment.start, before: segment.end) else {
            alert = EditorNotice(title: "Can’t Split Clip", message: "There’s no verified split point inside this range.")
            return
        }
        var proposed = segments
        proposed[index].end = cut
        let right = EditorSegment(source: segment.source, start: cut, end: segment.end)
        proposed.insert(right, at: index + 1)
        let original = playhead
        let snapped = (offset + (cut - segment.start)).seconds
        preview.audition(segment.preview, at: cut.seconds)
        playhead = snapped
        validate(proposed, selecting: right.id, at: snapped, action: "Split Clip", originalPlayhead: original)
    }

    func trim(_ id: UUID, edge: TimelineEdge, sourceTime: Double, commit: Bool) -> Double? {
        guard canEdit, sourceTime.isFinite,
              let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        let segment = segments[index]
        guard let boundaries = edit.preparation.bySource[segment.source.url] else { return nil }
        let offset = positionedSegments()[index].1
        let first = index == 0
        let last = index == segments.count - 1
        let cut: RationalTime?
        switch edge {
        case .start:
            cut = nearest(in: boundaries.starts(first: first, last: last), to: sourceTime, before: segment.end)
        case .end:
            cut = nearest(in: boundaries.ends(first: first, last: last), to: sourceTime, after: segment.start)
        }
        guard let cut else { return nil }
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
        if cut == (edge == .start ? segment.start : segment.end) {
            cancelTrim()
            return cut.seconds
        }
        var proposed = segments
        let landing: Double
        switch edge {
        case .start:
            proposed[index].start = cut
            landing = offset.seconds
        case .end:
            proposed[index].end = cut
            landing = (offset + (precedingFrame(in: segment, before: cut) - segment.start)).seconds
        }
        trimOrigin = nil
        trimAudition = nil
        validate(proposed, selecting: id, at: landing, action: "Trim Clip", originalPlayhead: original)
        return cut.seconds
    }

    func cancelTrim() {
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
        if let markedRange {
            deleteMarkedRange(markedRange, reversed: markIn == markedRange.upperBound)
        } else if markIn != nil, markOut != nil {
            alert = EditorNotice(title: "Can’t Delete Marked Range", message: "Move one mark to create a range to delete.")
        } else if let selectedID, let index = segments.firstIndex(where: { $0.id == selectedID }) {
            var proposed = segments
            proposed.remove(at: index)
            validate(proposed, selecting: proposed.indices.contains(index) ? proposed[index].id : proposed.last?.id,
                     at: positionedSegments()[index].1.seconds, action: "Delete Clip")
        }
    }

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        cancelTrim()
        redoStack.append(snapshot())
        edit = previous
        restorePreview(at: previous.playhead)
        updateStatus()
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        cancelTrim()
        undoStack.append(snapshot())
        edit = next
        restorePreview(at: next.playhead)
        updateStatus()
    }

    func chooseExport() {
        guard canEdit, let first = segments.first, let defaultContainer = edit.preparation.container else { return }
        cancelTrim()
        preview.pause()
        let token = EditCancellation()
        cancellation = token
        isCheckingEdit = true
        let candidate = segments
        let currentSession = session
        Task {
            let containerExtensions = await Task.detached(priority: .userInitiated) {
                let engine = CutEngine(cancelled: { token.isCancelled })
                let alternatives = engine.suggestedContainers(for: first.source.media)
                    .filter { $0 != defaultContainer }
                    .filter { !token.isCancelled && (try? Self.resolve(candidate, engine: engine, container: $0)) != nil }
                return [defaultContainer] + alternatives
            }.value
            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            presentExport(formats: containerExtensions, stem: first.source.url.deletingPathExtension().lastPathComponent)
        }
    }

    private func presentExport(formats: [String], stem: String) {
        guard !formats.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Movie"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(stem) Edit"
        let formatControl = ExportFormatControl(panel: panel, containers: formats)
        isPresentingPanel = true
        let currentSession = session
        present(panel) { [weak self, formatControl] accepted in
            guard let self, self.session == currentSession else { return }
            self.isPresentingPanel = false
            withExtendedLifetime(formatControl) {
                if accepted, let output = panel.url {
                    self.export(to: output)
                } else {
                    self.importPendingFiles()
                }
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        isCancelling = true
        cancellation?.cancel()
    }

    func cancelAndWaitForExport(_ completion: @escaping () -> Void) -> Bool {
        guard let exportTask else { return false }
        cancellation?.cancel()
        Task {
            await exportTask.value
            completion()
        }
        return true
    }

    func endSession() {
        cancellation?.cancel()
        cancellation = nil
        session = UUID()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingOpenFiles.removeAll()
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

    func thumbnail(for id: UUID, at sourceTime: Double, size: CGSize) async -> CGImage? {
        guard let source = segments.first(where: { $0.id == id })?.source else { return nil }
        return await preview.thumbnail(url: source.url, at: sourceTime, size: size)
    }

    private func deleteMarkedRange(_ marked: ClosedRange<Double>, reversed: Bool) {
        let positioned = positionedSegments()
        let tolerance = max(duration.ulp * 4, 0.000000001)
        let keepsLeading = marked.lowerBound > tolerance
        let keepsTrailing = marked.upperBound < duration - tolerance
        var before: [EditorSegment] = []
        var after: [EditorSegment] = []
        var dividedSegment: UUID?
        for (segment, position) in positioned {
            let offset = position.seconds
            let end = (position + segment.duration).seconds
            if end <= marked.lowerBound + tolerance {
                before.append(segment)
            } else if offset < marked.lowerBound - tolerance {
                let wanted = marked.lowerBound - offset + segment.start.seconds
                guard let boundaries = edit.preparation.bySource[segment.source.url] else { return }
                let choices = boundaries.ends(first: before.isEmpty, last: !keepsTrailing)
                guard let cut = nearest(in: choices, to: wanted, after: segment.start, before: segment.end) else {
                    showMarkBoundaryError(segment, mark: reversed ? "Out" : "In")
                    return
                }
                var left = segment
                left.end = cut
                before.append(left)
            }
            if offset >= marked.upperBound - tolerance {
                after.append(segment)
            } else if end > marked.upperBound + tolerance {
                let wanted = marked.upperBound - offset + segment.start.seconds
                guard let boundaries = edit.preparation.bySource[segment.source.url] else { return }
                let choices = boundaries.starts(first: !keepsLeading, last: segment.id == segments.last?.id)
                guard let cut = nearest(in: choices, to: wanted, after: segment.start, before: segment.end) else {
                    showMarkBoundaryError(segment, mark: reversed ? "In" : "Out")
                    return
                }
                let isDivided = before.last?.id == segment.id
                if isDivided { dividedSegment = segment.id }
                let id = isDivided ? UUID() : segment.id
                after.append(EditorSegment(id: id, source: segment.source, start: cut, end: segment.end))
            }
        }
        if let left = before.last, let right = after.first, left.id == dividedSegment, left.end >= right.start {
            alert = EditorNotice(title: "Can’t Delete Marked Range", message: "The marks resolve to the same cut point. Move the marks farther apart.")
            return
        }
        let landing = sequenceDuration(before)
        validate(before + after, selecting: after.first?.id ?? before.last?.id, at: landing,
                 action: "Delete Marked Range")
    }

    private func showMarkBoundaryError(_ segment: EditorSegment, mark: String) {
        alert = EditorNotice(title: "Can’t Delete Marked Range",
                             message: "No verified cut point is available for the \(mark) mark in \(segment.source.name).")
    }

    private func export(to output: URL) {
        guard canEdit else { return }
        preview.pause()
        lastExportedURL = nil
        isExporting = true
        isCancelling = false
        exportProgress = 0
        let candidate = segments
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
        exportTask = Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let engine = CutEngine(cancelled: { token.isCancelled })
                    let resolved = try Self.resolve(candidate, engine: engine, output: output)
                    try engine.export(resolved, to: output, progress: reportProgress)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            exportTask = nil
            guard session == currentSession else { return }
            isExporting = false
            isCancelling = false
            cancellation = nil
            defer { importPendingFiles() }
            if let failure {
                if token.isCancelled {
                    statusMessage = "Export cancelled."
                } else {
                    statusMessage = "Export failed."
                    alert = EditorNotice(title: "Export Failed", message: failure)
                }
            } else {
                lastExportedURL = output
                statusMessage = "Exported \(output.lastPathComponent)"
            }
        }
    }

    private func validate(_ proposed: [EditorSegment], selecting id: UUID?, at destination: Double,
                          action: String, originalPlayhead: Double? = nil) {
        cancelTrim()
        preview.pause()
        let original = originalPlayhead ?? playhead
        guard !proposed.isEmpty else {
            apply(proposed, prepared: PreparedEdit(), selecting: id, at: destination, originalPlayhead: original)
            return
        }
        let currentSession = session
        let priorPreparation = edit.preparation
        let token = EditCancellation()
        cancellation = token
        isCheckingEdit = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PreparedEdit, Error> in
                Result {
                    let engine = CutEngine(cancelled: { token.isCancelled })
                    let resolved = try Self.resolve(proposed, engine: engine)
                    return PreparedEdit(segments: proposed, container: resolved.container, previous: priorPreparation, engine: engine)
                }
            }.value

            guard session == currentSession else { return }
            cancellation = nil
            isCheckingEdit = false
            defer { importPendingFiles() }
            switch result {
            case .failure(let failure):
                restorePreview(at: original)
                alert = EditorNotice(title: "Couldn’t \(action)", message: failure.localizedDescription)
            case .success(let prepared):
                apply(proposed, prepared: prepared, selecting: id, at: destination, originalPlayhead: original)
            }
        }
    }

    private nonisolated static func resolve(_ segments: [EditorSegment], engine: CutEngine,
                                           output: URL? = nil, container: String? = nil) throws -> ResolvedEdit {
        let media = Dictionary(segments.map { ($0.source.url, $0.source.media) }, uniquingKeysWith: { first, _ in first })
        return try engine.resolve(segments.map(\.request), output: output, media: media, container: container)
    }

    private func apply(_ proposed: [EditorSegment], prepared: PreparedEdit, selecting id: UUID?, at destination: Double,
                       originalPlayhead: Double? = nil) {
        var original = snapshot()
        if let originalPlayhead { original.playhead = originalPlayhead }
        undoStack.append(original)
        redoStack.removeAll()
        trimOrigin = nil
        trimAudition = nil
        var duration = RationalTime.zero
        let offsets = proposed.map { segment in
            defer { duration = duration + segment.duration }
            return duration
        }
        edit = EditSnapshot(segments: proposed, preparation: prepared, selectedID: id, playhead: destination,
                            offsets: offsets, duration: duration)
        restorePreview(at: destination)
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

    private func positionedSegments() -> [(EditorSegment, RationalTime)] {
        Array(zip(segments, edit.offsets))
    }

    private func sequenceDuration(_ segments: some Sequence<EditorSegment>) -> Double {
        if let exact = try? segments.reduce(RationalTime.zero, { try $0.adding($1.duration) }) {
            return exact.seconds
        }
        return segments.reduce(0.0) { $0 + $1.duration.seconds }
    }

    private func locatedSegment(at time: Double) -> (Int, EditorSegment, RationalTime)? {
        guard time >= 0, time < duration,
              let index = edit.offsets.lastIndex(where: { $0.seconds <= time }) else { return nil }
        return (index, segments[index], edit.offsets[index])
    }

    private func nearest(in times: [RationalTime], to target: Double, after minimum: RationalTime? = nil,
                         before maximum: RationalTime? = nil) -> RationalTime? {
        let start = minimum.map { min in times.lowerBound { $0 > min } } ?? 0
        let end = maximum.map { max in times.lowerBound { $0 >= max } } ?? times.count
        guard start < end else { return nil }
        let next = min(max(times.lowerBound { $0.seconds >= target }, start), end - 1)
        let previous = max(next - 1, start)
        let earlier = times[previous]
        let later = times[next]
        let tolerance = max(target.ulp * 4, Double.ulpOfOne)
        return abs(target - earlier.seconds) <= abs(target - later.seconds) + tolerance ? earlier : later
    }

    private func precedingFrame(in segment: EditorSegment, before time: RationalTime) -> RationalTime {
        let frames = segment.source.frames
        let index = frames.lowerBound { $0 >= time } - 1
        return index >= 0 ? frames[index] : segment.start
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (Bool) -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in completion(response == .OK) }
        } else {
            completion(panel.runModal() == .OK)
        }
    }
}

private final class ExportFormatControl: NSObject, NSOpenSavePanelDelegate {
    private weak var panel: NSSavePanel?
    private let containers: [String]
    private var selectedContainer: String

    init(panel: NSSavePanel, containers: [String]) {
        self.panel = panel
        self.containers = containers
        selectedContainer = containers[0]
        super.init()
        panel.delegate = self

        let selector = NSPopUpButton()
        for container in containers {
            selector.addItem(withTitle: container.uppercased())
        }
        selector.target = self
        selector.action = #selector(selectContainer)
        selector.setAccessibilityLabel("File format")
        selector.isEnabled = containers.count > 1
        let label = NSTextField(labelWithString: "File format")
        let row = NSStackView(views: [label, selector])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 8, right: 16)
        row.frame.size = row.fittingSize
        panel.accessoryView = row
    }

    @objc private func selectContainer(_ sender: NSPopUpButton) {
        updateType(at: sender.indexOfSelectedItem)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard selectedContainer == url.pathExtension.lowercased() else {
            throw CutError(code: "unsupported_container", message: "The filename must use the selected movie format.")
        }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            throw CutError(code: "output_exists", message: "Choose a new filename. MPCut preserves existing files.")
        }
        if errno != ENOENT {
            throw CutError(code: "invalid_output", message: "MPCut couldn’t check the selected destination.")
        }
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag else { return filename }
        let name = filename as NSString
        return name.pathExtension.lowercased() == selectedContainer ? filename : "\(filename).\(selectedContainer)"
    }

    private func updateType(at index: Int) {
        guard let panel, containers.indices.contains(index) else { return }
        let previousContainer = selectedContainer
        selectedContainer = containers[index]
        let currentName = panel.nameFieldStringValue as NSString
        if currentName.pathExtension.lowercased() == previousContainer {
            panel.nameFieldStringValue = currentName.deletingPathExtension
        }
    }
}

private extension Array where Element == RationalTime {
    func lowerBound(where predicate: (RationalTime) -> Bool) -> Int {
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
