import AppKit
import Combine
import MPCutCore
import UniformTypeIdentifiers

@MainActor
final class MulticamEditorModel: ObservableObject {
    enum EditSelection {
        case group
        case assembly
    }
    struct SourceDraft: Identifiable {
        var source: MulticamSource
        let media: MediaInfo
        var ordinaryMedia: MediaInfo? = nil
        var id: String { source.id }
    }

    struct Notice: Identifiable {
        var id: String { title + message }
        let title: String
        let message: String
    }

    @Published private(set) var project: MulticamProject?
    @Published private(set) var media: [String: MediaInfo] = [:]
    @Published private(set) var sourceIssues: [String: String] = [:]
    @Published private(set) var sourceIndexProgress: [String: Double] = [:]
    @Published private(set) var sourceIndexIssues: [String: String] = [:]
    @Published private(set) var projectURL: URL?
    @Published private(set) var savedProject: MulticamProject?
    @Published private(set) var undoStack: [MulticamProject] = []
    @Published private(set) var redoStack: [MulticamProject] = []
    @Published var setup: [SourceDraft] = []
    @Published var notice: Notice?
    @Published var status = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double?
    @Published var report: String?
    @Published var exportRequested = false
    @Published var queuedRanges: [MulticamQueuedRange] = []
    @Published var isBulkQueuePresented = false
    @Published var isReplacementAudioPresented = false
    var bulkExportDirectory: URL?
    @Published private(set) var suggestions: [RationalTime] = []
    @Published private(set) var suggestionAnchor: RationalTime?
    @Published private(set) var assemblyPreview = false
    @Published var selectedSwitch: RationalTime?
    @Published var selectedOccurrence = 0
    @Published private(set) var editSelection: EditSelection = .group
    @Published private(set) var splitRevision = 0
    @Published var markIn: RationalTime?
    @Published var markOut: RationalTime?
    let preferences: EditorPreferences
    let preview: MulticamPreview
    let filmstrip = MulticamThumbnailService()
    let analysis = MulticamAnalysisStore()
    let pauseEdits = MulticamPauseEdits()
    @Published var timelineZoom: Double = 0
    @Published var timeEntryRequest = 0
    private(set) var openingProjectURL: URL?
    var chooseProjectRequest: (() -> Void)?
    var canSaveProjectTo: ((URL) -> Bool)?
    weak var window: NSWindow?
    private var preferenceObservation: AnyCancellable?
    var useAnalysisSidecars: Bool {
        get { preferences.useAnalysisSidecars }
        set { preferences.useAnalysisSidecars = newValue }
    }
    private var operation: EditCancellation?
    private var worker: Task<Void, Never>?
    /// Callers waiting for one operation's worker to stop. The worker owns the
    /// list, so closing the window during the wait cannot strand them.
    @MainActor
    private final class OperationWaiters {
        var done: [() -> Void] = []

        func finish() {
            let pending = done
            done = []
            for done in pending { done() }
        }
    }
    private var waiters: OperationWaiters?
    private struct Selection {
        let marker: RationalTime?
        let occurrence: Int
        let scope: EditSelection
    }
    private var undoSelections: [Selection] = []
    private var redoSelections: [Selection] = []
    private(set) var mapping: MulticamPlan?
    private var indexedByURL: [URL: MediaInfo] = [:]
    private var issuesByPath: [String: String] = [:]
    private var indexIssuesByURL: [URL: String] = [:]
    private var ordinaryByURL: [URL: MediaInfo] = [:]
    private struct SourceLoad {
        let id: UUID
        var progress = 0.0
        let cancel: () -> Void
    }
    private var sourceLoads: [URL: SourceLoad] = [:]
    private var importLoads: [() -> Void] = []
    private var provisionalGroupRange: MulticamRange?

    convenience init() {
        self.init(preferences: EditorPreferences())
    }

    init(preferences: EditorPreferences) {
        self.preferences = preferences
        preview = MulticamPreview(preferences: preferences)
        analysis.setSnap(preferences.snapTarget)
        analysis.configureSilence(minimum: preferences.minimumPause, threshold: nil)
        analysis.changed = { [weak self] in self?.objectWillChange.send() }
        preferenceObservation = preferences.observeChanges { [weak self] change in
            switch change {
            case .useAnalysisSidecars:
                guard let self else { return }
                for load in self.sourceLoads.values { load.cancel() }
                self.sourceLoads.removeAll()
                self.reconcileSourceLoads()
                self.refreshAnalysis()
                self.objectWillChange.send()
            case .snapTarget:
                if let self { self.analysis.setSnap(self.preferences.snapTarget) }
            case .minimumPause:
                if let self {
                    self.analysis.configureSilence(minimum: self.preferences.minimumPause, threshold: self.analysis.pauseThreshold)
                }
            case .largeThumbnails, .defaultExportMode, .jpegPreset, .leavePause:
                self?.objectWillChange.send()
            default:
                break
            }
        }
    }

    var isChanged: Bool { project != savedProject }

    /// The document name without `.json` or the conventional `.multicam.json` suffix.
    var projectName: String? {
        guard let name = projectURL?.deletingPathExtension().lastPathComponent else { return nil }
        let suffix = ".multicam"
        return name.count > suffix.count && name.lowercased().hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
    }
    var hasSession: Bool { project != nil || isBusy || !setup.isEmpty }
    var canChooseSources: Bool { !isBusy && setup.isEmpty }
    var ranges: [MulticamRange] { project.map { $0.assembly ?? [$0.range] } ?? [] }
    var canSaveSidecars: Bool { media.values.contains(where: \.hasFullEditIndex) && !isBusy }

    func chooseSources() {
        guard canChooseSources else { return }
        let panel = NSOpenPanel()
        panel.title = project == nil ? "Add as Multicam" : "Add Multicam Sources"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        ProjectPanels.present(panel, in: window) { [weak self] accepted in
            if accepted { self?.importSources(panel.urls) }
        }
    }

    func importSources(_ urls: [URL]) {
        guard canChooseSources else { return }
        // A reopened project stores physical paths, and the same recording can
        // arrive through a symlinked folder or another spelling of its name.
        var seen = (project?.sources ?? []).compactMap(Self.availableURL)
        let unique = urls.map(\.standardizedFileURL).filter { file in
            guard file.isFileURL, !seen.contains(where: { ProjectSessions.sameFile($0, file) }) else { return false }
            seen.append(file)
            return true
        }
        guard !unique.isEmpty else { return }
        isBusy = true
        status = "Reading multicam sources…"
        var results: [URL: SourceDraft] = [:]
        var errors: [String] = []
        var remaining = unique.count
        for file in unique {
            importLoads.append(SourceIndexLoader.shared.admit(.init(url: file, sidecars: useAnalysisSidecars, preview: true)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let index):
                    let info = index.multicam
                    if info.hasFullEditIndex, info.multicamClockOffset != .zero {
                        self.ordinaryByURL[info.url] = index.ordinary
                    }
                    let source = MulticamSource(id: UUID().uuidString, file: file.path,
                                               audioStream: info.audio.first?.stream.index)
                    results[file] = SourceDraft(source: source, media: info)
                case .failure(let error):
                    errors.append("\(file.lastPathComponent) — \(error.localizedDescription)")
                }
                remaining -= 1
                guard remaining == 0 else { return }
                self.finishImport()
                let drafts = unique.compactMap { results[$0] }
                if self.project != nil || drafts.contains(where: { $0.media.hasVideo }) {
                    self.setup = drafts
                    for draft in drafts { self.indexedByURL[draft.media.url] = draft.media }
                    self.reconcileSourceLoads()
                } else if errors.isEmpty {
                    errors.append("Select at least one camera recording.")
                }
                if !errors.isEmpty { self.fail(errors.joined(separator: "\n")) }
            })
        }
    }

    func dismissSetup() {
        setup = []
        let active = (project?.sources ?? []) + (undoStack + redoStack).flatMap(\.sources)
        let retained = Set(active.compactMap(Self.availableURL))
        indexedByURL = indexedByURL.filter { retained.contains($0.key) }
        ordinaryByURL = ordinaryByURL.filter { retained.contains($0.key) }
        indexIssuesByURL = indexIssuesByURL.filter { retained.contains($0.key) }
        reconcileSourceLoads()
    }

    private func finishImport() {
        importLoads.removeAll()
        isBusy = false
        status = ""
    }

    func confirmSetup(drafts: [SourceDraft], opening: String, audio: MulticamAudioPolicy) {
        guard !isBusy else { return }
        let drafts = drafts.map { draft -> SourceDraft in
            // The setup field can be cleared. A blank name means the file name.
            var draft = draft
            let name = draft.source.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.source.name = name?.isEmpty == false ? name : nil
            return draft
        }
        let video = drafts.filter { $0.media.hasVideo }
        let recordings = drafts.filter { !$0.media.hasVideo }
        let newMedia = Dictionary(uniqueKeysWithValues: drafts.map {
            ($0.id, indexedByURL[$0.media.url] ?? $0.media)
        })
        if project != nil {
            for info in newMedia.values { indexedByURL[info.url] = info }
            edit { candidate in
                candidate.angles.append(contentsOf: video.map(\.source))
                candidate.audioSources.append(contentsOf: recordings.map(\.source))
            }
        } else if let reference = video.first(where: { $0.id == opening }) {
            let candidate = MulticamProject(referenceAngle: opening,
                                            range: MulticamRange(from: .zero, to: newMedia[reference.id]?.duration ?? reference.media.duration),
                                            angles: video.map(\.source), audioSources: recordings.map(\.source),
                                            audio: audio, switches: [MulticamSwitch(at: .zero, angle: opening)])
            do {
                try candidate.validate()
                install(project: candidate, media: newMedia, issues: [:], url: nil)
                if newMedia[opening]?.hasFullEditIndex == false { provisionalGroupRange = candidate.range }
            } catch { fail(error.localizedDescription) }
        }
        dismissSetup()
    }

    func chooseProject() {
        if let chooseProjectRequest {
            chooseProjectRequest()
            return
        }
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Multicam Project"
        panel.allowedContentTypes = [.json]
        ProjectPanels.present(panel, in: window) { [weak self] accepted in
            if accepted, let url = panel.url { self?.openProject(url) }
        }
    }

    func openProject(_ url: URL) {
        guard !isBusy, confirmClose() else { return }
        let url = url.standardizedFileURL
        openingProjectURL = url
        run("Opening multicam project…") { _, _ in
            var project = try MulticamProject.load(from: url)
            _ = try project.plan()
            _ = try project.groupIntervals()
            project.angles = project.angles.map { Self.absoluteSource($0, in: project, relativeTo: url) }
            project.audioSources = project.audioSources.map { Self.absoluteSource($0, in: project, relativeTo: url) }
            return project
        } onSuccess: { project in
            self.stopSourceLoads()
            self.install(project: project, media: [:], issues: [:], url: url)
            self.reconcileSourceLoads()
        }
    }

    nonisolated private static func absoluteSource(_ source: MulticamSource, in project: MulticamProject, relativeTo url: URL) -> MulticamSource {
        var copy = source
        copy.file = project.sourceURL(for: source, relativeTo: url).path
        return copy
    }

    func relink(_ id: String) {
        guard let project, !isBusy, let source = project.sources.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Relink \(source.displayName)"
        ProjectPanels.present(panel, in: window) { [weak self] accepted in
            if accepted, let url = panel.url { self?.relink(id, to: url) }
        }
    }

    func relink(_ id: String, to url: URL) {
        guard let project, !isBusy, let source = project.sources.first(where: { $0.id == id }) else { return }
        let angle = project.angles.contains { $0.id == id }
        let url = url.standardizedFileURL
        isBusy = true
        status = "Reading replacement source…"
        var selectedStreams = Set(project.switches.compactMap(\.audio)
            .filter { $0.source == id }.map(\.stream))
        if case .fixed(let selection) = project.audio, selection.source == id {
            selectedStreams.insert(selection.stream)
        }
        if project.audio == .follow, angle, let stream = source.audioStream {
            selectedStreams.insert(stream)
        }
        let preview = selectedStreams.isEmpty
        importLoads.append(SourceIndexLoader.shared.admit(.init(url: url, sidecars: useAnalysisSidecars, preview: preview)) { [weak self] result in
            guard let self else { return }
            self.finishImport()
            switch result {
            case .success(let index) where angle ? index.multicam.hasVideo : !index.multicam.audio.isEmpty:
                let missing = selectedStreams.subtracting(index.multicam.audio.map(\.stream.index)).sorted()
                guard missing.isEmpty else {
                    self.fail("The replacement recording is missing selected audio stream(s) \(missing.map(String.init).joined(separator: ", ")).")
                    return
                }
                self.cacheIndexedSource(index.multicam, ordinary: index.ordinary)
                if source.file != url.path { self.updateSource(id) { $0.file = url.path } }
                else { self.reconcileSourceLoads() }
            case .success:
                self.fail("The replacement recording must match the source type.")
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        })
    }

    func requestSaveProject(asNew: Bool = false) {
        guard project != nil, !isBusy else { return }
        if let projectURL, !asNew {
            _ = saveProject(to: projectURL)
            return
        }
        let panel = makeSavePanel()
        ProjectPanels.present(panel, in: window) { [weak self] accepted in
            if accepted, let url = panel.url { _ = self?.saveProject(to: url) }
        }
    }

    func saveProject() -> Bool {
        guard project != nil, !isBusy else { return false }
        if let projectURL { return saveProject(to: projectURL) }

        // The AppKit close delegate needs an immediate answer before it can close the window.
        let panel = makeSavePanel()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return saveProject(to: url)
    }

    private func makeSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Save Multicam Project"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "Untitled.multicam.json"
        return panel
    }

    @discardableResult
    func saveProject(to destination: URL) -> Bool {
        guard let project, !isBusy else { return false }
        let url = destination.standardizedFileURL
        guard canSaveProjectTo?(url) != false else {
            let alert = NSAlert()
            alert.messageText = "This project is already open in another window."
            alert.informativeText = "Choose a different file to save this project."
            ProjectPanels.present(alert, in: window)
            return false
        }
        do {
            var document = project
            document.angles = project.angles.map { Self.relativeSource($0, to: url) }
            document.audioSources = project.audioSources.map { Self.relativeSource($0, to: url) }
            try document.save(to: url)
            projectURL = url
            savedProject = project
            status = "Saved \(url.lastPathComponent)"
            return true
        } catch {
            let alert = NSAlert(error: error)
            ProjectPanels.present(alert, in: window)
            return false
        }
    }

    nonisolated private static func relativeSource(_ source: MulticamSource, to url: URL) -> MulticamSource {
        guard !source.file.split(separator: "/").contains("..") else { return source }
        let directory = physicalParent(of: url)
        let recording = URL(fileURLWithPath: source.file)
        let target = physicalParent(of: recording) + [recording.lastPathComponent]
        let shared = zip(directory, target).prefix { $0.0 == $0.1 }.count
        var copy = source
        copy.file = (Array(repeating: "..", count: directory.count - shared) + target.dropFirst(shared)).joined(separator: "/")
        return copy
    }

    nonisolated private static func physicalParent(of url: URL) -> [String] {
        let directory = url.deletingLastPathComponent()
        // Foundation may elide /private on macOS. Relative paths must use the
        // same physical directory components as the project's source resolver.
        guard let resolved = realpath(directory.path, nil) else { return directory.pathComponents }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).pathComponents
    }

    func confirmClose() -> Bool {
        guard !isBusy else { return false }
        guard isChanged else { return true }
        preview.pause()
        let alert = NSAlert()
        alert.messageText = "Save changes to \(projectURL?.lastPathComponent ?? "Untitled Multicam")?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func reset() {
        openingProjectURL = nil
        timelineZoom = 0
        timeEntryRequest = 0
        resetExportQueue()
        isReplacementAudioPresented = false
        cancel()
        operation = nil
        waiters = nil
        worker = nil
        isBusy = false
        isExporting = false
        progress = nil
        stopSourceLoads()
        provisionalGroupRange = nil
        preview.reset()
        filmstrip.reset()
        analysis.reset()
        pauseEdits.reset()
        project = nil
        media = [:]
        sourceIssues = [:]
        indexedByURL = [:]
        issuesByPath = [:]
        mapping = nil
        savedProject = nil
        projectURL = nil
        undoStack = []
        redoStack = []
        undoSelections = []
        redoSelections = []
        setup = []
        selectedSwitch = nil
        selectedOccurrence = 0
        editSelection = .group
        markIn = nil
        markOut = nil
        assemblyPreview = false
        report = nil
        notice = nil
        suggestions = []
        suggestionAnchor = nil
        status = ""
    }

    private func install(project: MulticamProject, media: [String: MediaInfo], issues: [String: String], url: URL?) {
        resetExportQueue()
        analysis.reset()
        pauseEdits.reset()
        preview.pause()
        provisionalGroupRange = nil
        self.project = project
        self.media = media
        sourceIssues = issues
        indexedByURL = Dictionary(grouping: media.values, by: \.url).compactMapValues(\.first)
        issuesByPath = Dictionary(grouping: project.sources, by: \.file)
            .compactMapValues { entries in entries.compactMap { issues[$0.id] }.first }
        projectURL = url
        savedProject = url == nil ? nil : project
        setup = []
        undoStack = []
        redoStack = []
        undoSelections = []
        redoSelections = []
        selectedSwitch = project.switches.first?.at
        selectedOccurrence = 0
        editSelection = .group
        markIn = nil
        markOut = nil
        assemblyPreview = false
        report = nil
        suggestions = []
        suggestionAnchor = nil
        refreshPreview()
        preview.seek(to: .zero)
        window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func edit(_ change: (inout MulticamProject) -> Void) -> Bool {
        guard !isBusy, let project else { return false }
        var next = project
        change(&next)
        do {
            _ = try next.plan()
            _ = try next.groupIntervals()
        }
        catch { fail(error.localizedDescription); return false }
        guard next != project else { return true }
        undoStack.append(project)
        undoSelections.append(selection)
        redoStack = []
        redoSelections = []
        apply(next)
        return true
    }

    func undo() {
        guard !isBusy, let project, let previous = undoStack.popLast() else { return }
        let restored = undoSelections.popLast()
        redoStack.append(project)
        redoSelections.append(selection)
        apply(previous)
        if let restored { select(restored) }
    }

    func redo() {
        guard !isBusy, let project, let next = redoStack.popLast() else { return }
        let restored = redoSelections.popLast()
        undoStack.append(project)
        undoSelections.append(selection)
        apply(next)
        if let restored { select(restored) }
    }

    private var selection: Selection {
        Selection(marker: selectedSwitch, occurrence: selectedOccurrence, scope: editSelection)
    }

    /// History entries carry the selection that was current when they were replaced.
    private func select(_ selection: Selection) {
        let marker = selection.marker.flatMap { at in project?.switches.contains(where: { $0.at == at }) == true ? at : nil }
        let occurrence = min(max(0, selection.occurrence), max(0, ranges.count - 1))
        if selectedSwitch != marker { selectedSwitch = marker }
        if selectedOccurrence != occurrence { selectedOccurrence = occurrence }
        if editSelection != selection.scope { editSelection = selection.scope }
    }

    private func apply(_ next: MulticamProject) {
        project = next
        reconcileSourceLoads()
        suggestions = []
        suggestionAnchor = nil
        selectedOccurrence = min(selectedOccurrence, max(0, ranges.count - 1))
        if let selectedSwitch, !next.switches.contains(where: { $0.at == selectedSwitch }) {
            self.selectedSwitch = nil
        }
    }

    private func updateMedia(for project: MulticamProject) {
        let cameras = Set(project.angles.map(\.id))
        let updated = Dictionary(uniqueKeysWithValues: project.sources.compactMap { source -> (String, MediaInfo)? in
            guard let url = Self.availableURL(source),
                  let info = indexedByURL[url],
                  (cameras.contains(source.id) ? info.hasVideo : !info.audio.isEmpty) else { return nil }
            return (source.id, info)
        })
        if media.mapValues(\.url) != updated.mapValues(\.url) ||
            media.mapValues(\.identity) != updated.mapValues(\.identity) ||
            media.mapValues(\.hasFullEditIndex) != updated.mapValues(\.hasFullEditIndex) { media = updated }
        let issues = Dictionary(uniqueKeysWithValues: project.sources.compactMap { source -> (String, String)? in
            if updated[source.id] != nil { return nil }
            guard let url = Self.availableURL(source) else {
                return (source.id, "A parent folder in the recording path is unavailable.")
            }
            if indexedByURL[url] != nil {
                return (source.id, "The recording does not match the source type.")
            }
            return issuesByPath[source.file].map { (source.id, $0) }
        })
        if issues != sourceIssues { sourceIssues = issues }
        refreshPreview()
    }

    nonisolated private static func availableURL(_ source: MulticamSource) -> URL? {
        guard !source.file.split(separator: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: source.file).standardizedFileURL
    }

    private func stopSourceLoads() {
        for load in sourceLoads.values { load.cancel() }
        sourceLoads.removeAll()
        sourceIndexProgress = [:]
        sourceIndexIssues = [:]
        indexIssuesByURL = [:]
        ordinaryByURL = [:]
    }

    private func reconcileSourceLoads() {
        let sources = (project?.sources ?? []) + setup.map(\.source)
        let firstAngle = project.flatMap { current in
            let onAir = current.selection(at: current.range.from)?.angle ?? current.referenceAngle
            return current.angles.first { $0.id == onAir }
        }
        let orderedSources = firstAngle.map { [$0] + sources } ?? sources
        var seen: Set<URL> = []
        let urls = orderedSources.compactMap(Self.availableURL).filter { seen.insert($0).inserted }
        for url in Array(sourceLoads.keys) where !seen.contains(url) {
            sourceLoads.removeValue(forKey: url)?.cancel()
        }
        for url in urls where sourceLoads[url] == nil && indexIssuesByURL[url] == nil && issuesByPath[url.path] == nil {
            let header = indexedByURL[url]
            guard header?.hasFullEditIndex != true else { continue }
            let id = UUID()
            let key = SourceIndexLoader.Key(url: url, sidecars: useAnalysisSidecars, preview: header == nil,
                                            identity: header?.identity)
            let cancel = SourceIndexLoader.shared.admit(key, progress: { [weak self] fraction in
                guard let self, let load = self.sourceLoads[url], load.id == id, fraction > load.progress else { return }
                self.sourceLoads[url]?.progress = fraction
                self.publishSourceProgress()
            }) { [weak self] result in
                guard let self, self.sourceLoads[url]?.id == id else { return }
                self.sourceLoads[url] = nil
                switch result {
                case .success(let index):
                    self.indexedByURL[url] = index.multicam
                    if index.ordinary.hasFullEditIndex {
                        if index.multicam.multicamClockOffset != .zero { self.ordinaryByURL[url] = index.ordinary }
                        self.updateProvisionalGroupRange(using: index.multicam)
                    }
                case .failure(let error):
                    if key.preview { self.issuesByPath[url.path] = error.localizedDescription }
                    else { self.indexIssuesByURL[url] = error.localizedDescription }
                }
                self.reconcileSourceLoads()
            }
            sourceLoads[url] = SourceLoad(id: id, cancel: cancel)
        }
        if let project { updateMedia(for: project) }
        publishSourceProgress()
    }

    private func publishSourceProgress() {
        let sources = (project?.sources ?? []) + setup.map(\.source)
        var progress: [String: Double] = [:]
        var issues: [String: String] = [:]
        for source in sources {
            guard let url = Self.availableURL(source) else { continue }
            progress[source.id] = sourceLoads[url]?.progress
            issues[source.id] = indexIssuesByURL[url]
        }
        if sourceIndexProgress != progress { sourceIndexProgress = progress }
        if sourceIndexIssues != issues { sourceIndexIssues = issues }
    }

    private func updateProvisionalGroupRange(using info: MediaInfo) {
        guard let provisionalGroupRange, let project,
              let reference = project.angles.first(where: { $0.id == project.referenceAngle }),
              Self.availableURL(reference) == info.url else { return }
        self.provisionalGroupRange = nil
        guard provisionalGroupRange.to != info.duration else { return }

        func resolvedRange(in document: MulticamProject) -> MulticamProject {
            guard document.referenceAngle == reference.id, document.range == provisionalGroupRange,
                  document.angles.contains(where: { $0.id == reference.id && Self.availableURL($0) == info.url })
            else { return document }
            var adjusted = document
            adjusted.range = MulticamRange(from: provisionalGroupRange.from, to: info.duration)
            guard (try? adjusted.plan()) != nil, (try? adjusted.groupIntervals()) != nil else { return document }
            return adjusted
        }

        let adjusted = resolvedRange(in: project)
        if project != adjusted { self.project = adjusted }
        undoStack = undoStack.map(resolvedRange(in:))
        redoStack = redoStack.map(resolvedRange(in:))
    }

    func ordinaryAnalysisMedia(_ id: String) -> MediaInfo? {
        guard let info = media[id], info.hasFullEditIndex else { return nil }
        return ordinaryByURL[info.url] ?? (info.multicamClockOffset == .zero ? info : nil)
    }

    func updateSource(_ id: String, _ change: (inout MulticamSource) -> Void) {
        edit { project in
            if let row = project.angles.firstIndex(where: { $0.id == id }) {
                change(&project.angles[row])
            }
            if let row = project.audioSources.firstIndex(where: { $0.id == id }) {
                change(&project.audioSources[row])
            }
        }
    }

    func moveSource(_ id: String, by delta: Int) {
        edit { project in
            guard let index = project.angles.firstIndex(where: { $0.id == id }),
                  project.angles.indices.contains(index + delta) else { return }
            project.angles.swapAt(index, index + delta)
        }
    }

    func moveOffset(_ id: String, by delta: Int) {
        guard let project, let source = project.sources.first(where: { $0.id == id }), let info = media[id] else { return }
        let clock = currentGroupTime()
        guard let sampleTime = try? clock.subtracting(source.offset) else { return }
        let isAngle = project.angles.contains(where: { $0.id == id })
        let frames = isAngle ? info.frames : []
        let duration: RationalTime?
        if !frames.isEmpty {
            let index = frameIndex(at: sampleTime, frames: frames)
            let neighbor = min(max(index + delta, 0), frames.count - 1)
            if neighbor != index {
                duration = try? frames[neighbor].time.subtracting(frames[index].time)
            } else {
                let step = frames[index].duration
                duration = delta > 0 ? step : try? RationalTime.zero.subtracting(step)
            }
        } else if !isAngle {
            let selection: MulticamAudioSelection?
            if let override = project.selection(at: clock)?.audio { selection = override }
            else if case .fixed(let fixed) = project.audio { selection = fixed }
            else { selection = nil }
            let stream = selection?.source == id ? selection?.stream : source.audioStream
            let track = info.audio.first(where: { $0.stream.index == stream }) ?? info.audio.first
            guard let rate = track?.stream.sampleRate, rate > 0 else { return }
            duration = RationalTime(numerator: Int64(delta), denominator: Int64(rate))
        } else { duration = nil }
        guard let duration, let offset = try? source.offset.adding(duration) else { return }
        updateSource(id) { $0.offset = offset }
    }

    func setAssemblyPreview(_ enabled: Bool) {
        guard project != nil, !isBusy, assemblyPreview != enabled else { return }
        let group = currentGroupTime()
        preview.pause()
        assemblyPreview = enabled
        editSelection = enabled ? .assembly : .group
        if enabled { selectedSwitch = nil }
        refreshPreview()
        if let output = outputTime(forGroup: group) {
            if enabled { selectedOccurrence = occurrenceIndex(at: output) }
            preview.seek(to: output)
        } else {
            selectOccurrence(selectedOccurrence)
        }
    }

    private func refreshPreview() {
        guard let project else { return }
        mapping = try? project.plan(ranges: assemblyPreview ? nil : [project.range])
        if let mapping { preview.configure(plan: mapping, media: media) }
        refreshAnalysis()
    }

    private func refreshAnalysis() {
        guard let project else { return }
        let ordinary = Dictionary(uniqueKeysWithValues: media.keys.compactMap { id in
            ordinaryAnalysisMedia(id).map { (id, $0) }
        })
        analysis.update(project: project, media: media, ordinary: ordinary, useSidecars: useAnalysisSidecars)
    }

    func groupTime(at output: RationalTime) -> RationalTime {
        guard let mapping, let interval = mapping.intervals.first(where: { output < $0.output.to }) ?? mapping.intervals.last,
              let delta = try? output.subtracting(interval.output.from),
              let group = try? interval.group.from.adding(delta) else { return .zero }
        return min(group, interval.group.to)
    }

    func currentGroupTime() -> RationalTime { groupTime(at: preview.currentTime()) }

    var activeOccurrenceIndex: Int { occurrenceIndex(at: preview.currentTime()) }

    func occurrenceIndex(at output: RationalTime) -> Int {
        guard assemblyPreview, let mapping else { return selectedOccurrence }
        let index = mapping.intervals.lowerBound { $0.output.to > output }
        return mapping.intervals.indices.contains(index) ? mapping.intervals[index].assemblyIndex
            : mapping.intervals.last?.assemblyIndex ?? selectedOccurrence
    }

    func skipMulticamPause(_ pauses: [MulticamPauseEdit]) {
        guard pauseEdits.skip, !isBusy, preview.playbackRate > 0, let mapping else { return }
        let position = preview.currentTime()
        let currentIndex = mapping.intervals.lowerBound { $0.output.to > position }
        guard mapping.intervals.indices.contains(currentIndex) else { return }
        let current = mapping.intervals[currentIndex]
        guard let elapsed = try? position.subtracting(current.output.from),
              let group = try? current.group.from.adding(elapsed) else { return }
        let candidate = pauses.lowerBound {
            $0.id.occurrence > current.assemblyIndex ||
                ($0.id.occurrence == current.assemblyIndex && $0.visible.to > group)
        }
        guard pauses.indices.contains(candidate), pauses[candidate].id.occurrence == current.assemblyIndex,
              let cut = pauses[candidate].removal, cut.from <= group, group < cut.to,
              let interval = mapping.intervals[currentIndex...].first(where: { $0.group.to >= cut.to }),
              let delta = try? cut.to.subtracting(interval.group.from),
              let output = try? interval.output.from.adding(delta),
              output > position else { return }
        preview.seek(to: output)
    }

    private func outputTime(forGroup group: RationalTime, currentOutput: RationalTime? = nil) -> RationalTime? {
        guard let mapping else { return nil }
        // A camera switch divides an occurrence into intervals on the same output clock.
        let currentOccurrence = currentOutput.map { occurrenceIndex(at: $0) }
        let eligible = mapping.intervals.filter { $0.group.from <= group && group < $0.group.to }
        let interval = eligible.first(where: { $0.assemblyIndex == currentOccurrence })
            ?? eligible.first(where: { $0.assemblyIndex == selectedOccurrence })
            ?? eligible.first
        if let interval, let delta = try? group.subtracting(interval.group.from) {
            return try? interval.output.from.adding(delta)
        }
        // An internal output boundary belongs to the following interval.
        return mapping.intervals.last?.group.to == group ? mapping.duration : nil
    }

    func seekGroup(_ target: RationalTime, scrubbing: Bool = false) {
        guard let mapping, let range = project?.range else { return }
        let group = min(range.to, max(range.from, target))
        if let output = outputTime(forGroup: group, currentOutput: preview.currentTime()) {
            if scrubbing { preview.scrub(to: output) }
            else { preview.seek(to: output) }
        } else if assemblyPreview, !isBusy {
            setAssemblyPreview(false)
            seekGroup(group, scrubbing: scrubbing)
        } else if !assemblyPreview { preview.seek(to: max(.zero, min(group, mapping.duration))) }
    }

    func selectOccurrence(_ index: Int) {
        guard ranges.indices.contains(index) else { return }
        focusAssemblyEdit()
        selectedOccurrence = index
        preview.pause()
        if assemblyPreview, let interval = mapping?.intervals.first(where: { $0.assemblyIndex == index }) {
            preview.seek(to: interval.output.from)
        } else {
            seekGroup(ranges[index].from)
        }
    }

    func audition(_ id: String) {
        guard let source = project?.angles.first(where: { $0.id == id }), let info = media[id],
              let time = try? currentGroupTime().subtracting(source.offset) else { return }
        preview.audition(url: info.url, sourceTime: time, media: info)
    }

    func seekTimeline(_ at: RationalTime) {
        editSelection = .group
        if selectedSwitch != nil { selectedSwitch = nil }
        if let end = project?.range.to, at >= end {
            seekGroup(end, scrubbing: true)
            return
        }
        let scope = activeAnalysisOccurrence(containing: at)
        let snapped = snappedAnalysisTime(at, within: scope) ?? snappedFrame(at, delta: 0) ?? at
        seekGroup(scope?.contains(snapped) == false ? at : snapped, scrubbing: true)
    }

    func seekPlaybackBoundary(end: Bool) {
        guard let mapping else { return }
        preview.pause()
        if assemblyPreview { selectedOccurrence = end ? ranges.count - 1 : 0 }
        preview.seek(to: end ? mapping.duration : .zero)
    }

    func selectMarker(_ at: RationalTime) {
        editSelection = .group
        selectedSwitch = at
        preview.pause()
        seekGroup(at)
    }

    func step(_ delta: Int) {
        preview.pause()
        let time = currentGroupTime()
        let target = snappedFrame(time, delta: delta)
        guard assemblyPreview, let mapping,
              let interval = mapping.intervals.first(where: { preview.time < $0.output.to }) ?? mapping.intervals.last else {
            if let target { seekGroup(target) }
            return
        }

        let occurrences = ranges
        let index = interval.assemblyIndex
        guard occurrences.indices.contains(index) else { return }
        if let target, target != time, occurrences[index].contains(target) {
            seekOccurrence(index, group: target, mapping: mapping)
            return
        }
        let next = index + delta
        if occurrences.indices.contains(next) {
            let range = occurrences[next]
            let target = delta > 0 ? range.from : max(range.from, snappedFrame(range.to, delta: -1) ?? range.from)
            seekOccurrence(next, group: target, mapping: mapping)
        } else if delta > 0 {
            preview.seek(to: mapping.duration)
        } else {
            preview.seek(to: .zero)
        }
    }

    /// An assembly edit ahead of the playhead shifts output time. This puts the
    /// playhead back on the group time it showed inside the edited occurrence.
    func seekAssemblyOccurrence(_ index: Int, group: RationalTime) {
        guard assemblyPreview, let mapping, ranges.indices.contains(index), ranges[index].contains(group) else { return }
        seekOccurrence(index, group: group, mapping: mapping)
    }

    private func seekOccurrence(_ index: Int, group: RationalTime, mapping: MulticamPlan) {
        guard let start = mapping.intervals.first(where: { $0.assemblyIndex == index }),
              let elapsed = try? group.subtracting(start.group.from),
              let output = try? start.output.from.adding(elapsed) else { return }
        selectedOccurrence = index
        preview.seek(to: output)
    }

    private func frameIndex(at time: RationalTime, frames: [FrameInfo]) -> Int {
        var start = 0
        var end = frames.count
        while start < end {
            let middle = (start + end) / 2
            if frames[middle].time <= time { start = middle + 1 } else { end = middle }
        }
        return max(0, start - 1)
    }

    func snappedFrame(_ time: RationalTime, delta: Int) -> RationalTime? {
        guard let project else { return nil }
        let active = project.selection(at: time)?.angle ?? project.switches.last?.angle
        var candidates: [RationalTime] = []
        for id in [project.referenceAngle, active].compactMap({ $0 }) {
            guard let source = project.angles.first(where: { $0.id == id }),
                  let frames = media[id]?.frames, let first = frames.first, let last = frames.last,
                  let sourceTime = try? time.subtracting(source.offset),
                  let end = try? last.time.adding(last.duration) else { continue }
            if sourceTime < first.time || sourceTime > end || (sourceTime == end && delta >= 0) {
                let edge: RationalTime?
                if delta > 0, sourceTime < first.time { edge = first.time }
                else if delta < 0, sourceTime >= end { edge = last.time }
                else { edge = nil }
                if let edge, let group = try? edge.adding(source.offset), project.range.contains(group) {
                    candidates.append(group)
                }
                continue
            }
            let index = frameIndex(at: sourceTime, frames: frames)
            let adjustment = delta < 0 && frames[index].time < sourceTime ? 0 : delta
            let next = index + adjustment
            let frame = next >= frames.count ? end : frames[max(0, next)].time
            if let group = try? frame.adding(source.offset) {
                return min(project.range.to, max(project.range.from, group))
            }
        }
        return delta < 0 ? candidates.max() : candidates.min()
    }

    @discardableResult
    func takeCamera(number: Int) -> Bool {
        guard number > 0, let project, project.angles.indices.contains(number - 1) else { return false }
        take(project.angles[number - 1].id)
        return true
    }

    func take(_ id: String) {
        let clock = currentGroupTime()
        guard let project, !isBusy, project.range.contains(clock),
              project.angles.contains(where: { $0.id == id }) else { return }
        let exact = project.switches.first { $0.at == clock }
        let at = exact?.at ?? snappedAnalysisTime(clock, excludingGroupEdges: true) ?? snappedFrame(clock, delta: 0) ?? clock
        guard project.range.from <= at, at < project.range.to else { return }
        if edit({ candidate in
            if let index = candidate.switches.firstIndex(where: { $0.at == at }) {
                candidate.switches[index].angle = id
            } else {
                candidate.switches.append(MulticamSwitch(at: at, angle: id))
                candidate.switches.sort { $0.at < $1.at }
            }
        }) {
            editSelection = .group
            selectedSwitch = at
        }
    }

    func moveSwitch(_ original: RationalTime, to at: RationalTime, snap: Bool = false) {
        guard let project, original != project.range.from,
              project.switches.contains(where: { $0.at == original }) else { return }
        let at = snap ? (snappedAnalysisTime(at, excludingGroupEdges: true) ?? snappedFrame(at, delta: 0) ?? at) : at
        guard at != original else { return }
        guard at > project.range.from, at < project.range.to else {
            if !snap { fail("Enter a switch time after group zero and before the group end.") }
            return
        }
        guard !project.switches.contains(where: { $0.at == at }) else {
            if !snap { fail("There is already a switch at \(at) seconds.") }
            return
        }
        if edit({ candidate in
            guard let index = candidate.switches.firstIndex(where: { $0.at == original }) else { return }
            candidate.switches[index].at = at
            candidate.switches.sort { $0.at < $1.at }
        }) { selectMarker(at) }
    }

    func deleteSwitch(_ at: RationalTime) {
        guard at != project?.range.from else { return }
        edit { $0.switches.removeAll { $0.at == at } }
    }

    func changeSwitch(_ at: RationalTime, angle: String? = nil, audio: MulticamAudioSelection? = nil) {
        edit { candidate in
            guard let index = candidate.switches.firstIndex(where: { $0.at == at }) else { return }
            if let angle { candidate.switches[index].angle = angle }
            else { candidate.switches[index].audio = audio }
        }
    }

    func parseTime(_ input: String, change: (RationalTime) -> Void) {
        do { try change(RationalTime(parsing: input.trimmingCharacters(in: .whitespacesAndNewlines))) }
        catch { fail(error.localizedDescription) }
    }

    func addMarkedRange() {
        guard let marks = markedGroupSpan else { return }
        if edit({ project in
            project.assembly = (project.assembly ?? []) + [MulticamRange(from: marks.from, to: marks.to)]
        }) {
            focusAssemblyEdit()
            selectedOccurrence = ranges.count - 1
        }
    }

    func changeOccurrence(from: RationalTime? = nil, to: RationalTime? = nil) {
        if edit({ project in
            var ranges = project.assembly ?? [project.range]
            guard ranges.indices.contains(selectedOccurrence) else { return }
            let current = ranges[selectedOccurrence]
            ranges[selectedOccurrence] = MulticamRange(from: from ?? current.from, to: to ?? current.to)
            project.assembly = ranges
        }) { focusAssemblyEdit() }
    }

    func splitOccurrence() {
        guard let (index, at) = occurrenceCut else { return }
        var splitRanges = ranges
        let current = splitRanges[index]
        splitRanges.replaceSubrange(index...index, with: [
            MulticamRange(from: current.from, to: at), MulticamRange(from: at, to: current.to)
        ])
        preview.pause()
        if edit({ $0.assembly = splitRanges }) {
            focusAssemblyEdit()
            selectedOccurrence = index + 1
            if assemblyPreview {
                seekAssemblyOccurrence(index + 1, group: at)
            } else {
                seekGroup(at)
            }
            splitRevision += 1
        }
    }

    func focusAssemblyEdit() {
        editSelection = .assembly
        if selectedSwitch != nil { selectedSwitch = nil }
    }

    func selectAssemblyOccurrence(_ index: Int) {
        guard ranges.indices.contains(index), !isBusy else { return }
        if !assemblyPreview { setAssemblyPreview(true) }
        selectOccurrence(index)
    }

    func seekAssemblyTimeline(_ seconds: Double, scrubbing: Bool) {
        if !assemblyPreview { setAssemblyPreview(true) }
        guard let mapping, assemblyPreview, let requested = timelineRationalTime(seconds) else { return }
        focusAssemblyEdit()
        let first = mapping.intervals.lowerBound { $0.output.to.seconds > seconds }
        let output: RationalTime
        if mapping.intervals.indices.contains(first) {
            let interval = mapping.intervals[first]
            // Preserve an exact join when its rational time rounds up to a nanosecond.
            output = seconds == interval.output.from.seconds ? interval.output.from
                : min(interval.output.to, max(interval.output.from, requested))
        } else {
            output = mapping.duration
        }
        selectedOccurrence = occurrenceIndex(at: output)
        if scrubbing { preview.scrub(to: output) }
        else { preview.seek(to: output) }
    }

    func trimAssemblyOccurrence(_ index: Int, edge: TimelineEdge, seconds: Double, commit: Bool) -> Double? {
        guard let project, !isBusy, ranges.indices.contains(index),
              let requested = timelineRationalTime(seconds) else { return nil }
        let range = ranges[index]
        let original = edge == .start ? range.from : range.to
        let target = min(project.range.to, max(project.range.from, requested))
        let result: RationalTime?
        if seconds == original.seconds {
            result = original
        } else if analysis.snapTarget == .keyframes {
            result = nearestAssemblyCopyEdge(target, edge: edge, range: range, project: project)
        } else {
            result = snappedAnalysisTime(target) ?? snappedFrame(target, delta: 0) ?? target
        }
        guard let result,
              project.range.from <= result, result <= project.range.to,
              edge == .start ? result < range.to : result > range.from else { return nil }
        guard commit, result != original else { return result.seconds }

        var updated = ranges
        if edge == .start { updated[index].from = result }
        else { updated[index].to = result }
        preview.pause()
        guard edit({ $0.assembly = updated }) else { return nil }
        selectAssemblyOccurrence(index)
        return result.seconds
    }

    private func nearestAssemblyCopyEdge(_ target: RationalTime, edge: TimelineEdge, range: MulticamRange,
                                         project: MulticamProject) -> RationalTime? {
        guard let intervals = try? project.groupIntervals() else { return nil }
        var nearest: RationalTime?
        for interval in intervals {
            guard let offset = project.angles.first(where: { $0.id == interval.angle })?.offset,
                  let info = media[interval.angle], !info.frames.isEmpty,
                  let local = try? target.subtracting(offset),
                  let from = try? max(project.range.from, interval.group.from).subtracting(offset),
                  let to = try? min(project.range.to, interval.group.to).subtracting(offset) else { continue }
            let frames = info.frames
            if edge == .end, info.duration > from, info.duration <= to,
               let terminal = try? info.duration.adding(offset), terminal > range.from,
               nearest.map({ abs(target.seconds - terminal.seconds) < abs(target.seconds - $0.seconds) }) ?? true {
                nearest = terminal
            }
            let bound = frames.lowerBound { $0.time >= max(from, min(local, to)) }
            for forwards in [false, true] {
                var index = forwards ? bound : min(frames.count - 1, bound - 1)
                while frames.indices.contains(index) {
                    let frame = frames[index]
                    if frame.time < from || frame.time > to { break }
                    index += forwards ? 1 : -1
                    let valid = edge == .start ? frame.canStart && frame.time < to : frame.canEnd && frame.time > from
                    guard valid, let time = try? frame.time.adding(offset),
                          edge == .start ? time < range.to : time > range.from else { continue }
                    if nearest.map({ abs(target.seconds - time.seconds) < abs(target.seconds - $0.seconds) }) ?? true {
                        nearest = time
                    }
                    break
                }
            }
        }
        return nearest
    }

    func reorderAssemblyOccurrence(_ index: Int, before slot: Int) {
        let current = ranges
        guard !isBusy, current.indices.contains(index), (0...current.count).contains(slot) else { return }
        let destination = slot > index ? slot - 1 : slot
        guard destination != index else { return }
        var reordered = current
        let occurrence = reordered.remove(at: index)
        reordered.insert(occurrence, at: destination)
        preview.pause()
        if reordered != current {
            guard edit({ $0.assembly = reordered }) else { return }
        }
        selectAssemblyOccurrence(destination)
    }

    func moveOccurrence(_ delta: Int) {
        let index = selectedOccurrence
        let next = index + delta
        guard !isBusy, let assembly = project?.assembly, assembly.indices.contains(index),
              assembly.indices.contains(next), index != next else { return }
        let output = preview.currentTime()
        let group = occurrenceIndex(at: output) == index ? groupTime(at: output) : assembly[index].from
        let target = assembly[index].contains(group) ? group : assembly[index].from
        if assemblyPreview { preview.pause() }
        if edit({ project in
            var moved = assembly
            moved.swapAt(index, next)
            project.assembly = moved
        }) {
            focusAssemblyEdit()
            selectedOccurrence = next
            seekAssemblyOccurrence(next, group: target)
        }
    }

    func removeOccurrence() {
        guard !isBusy, var assembly = project?.assembly, assembly.indices.contains(selectedOccurrence) else { return }
        let index = selectedOccurrence
        assembly.remove(at: index)
        preview.pause()
        if edit({ $0.assembly = assembly.isEmpty ? nil : assembly }) {
            selectOccurrence(min(index, ranges.count - 1))
        }
    }

    func saveAnalysisSidecars() {
        guard canSaveSidecars else { return }
        var seen: Set<URL> = []
        let sources = media.compactMap { id, info -> (MediaInfo, MediaInfo?, [FilmstripTile], MulticamAnalysisSnapshot)? in
            guard info.hasFullEditIndex, seen.insert(info.url).inserted else { return nil }
            let ordinary = ordinaryAnalysisMedia(id)
            let snapshot = ordinary.map { analysis.snapshot(for: $0) } ?? MulticamAnalysisSnapshot()
            return (info, ordinary, filmstrip.snapshot(for: info), snapshot)
        }
        run("Saving analysis sidecars…") { token, _ in
            let cancelled = { @Sendable in token.isCancelled }
            let engine = CutEngine(cancelled: cancelled)
            for (info, ordinary, tiles, snapshot) in sources {
                // Share the ordinary source index with the single-source editor.
                // Multicam adds the authored MOV offset after reading that index.
                let indexed = try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                    try ordinary ?? engine.inspect(info.url, keyframes: true)
                }
                guard indexed.identity == info.identity else {
                    throw CutError(code: "source_changed", message: "Source \(info.url.lastPathComponent) changed. Relink it before saving its analysis.")
                }
                var sections = try AnalysisSidecar.indexSections(for: indexed, cancelled: cancelled)
                let analyzed = try snapshot.sections(for: indexed, cancelled: cancelled)
                sections.merge(analyzed) { _, analysis in analysis }
                if let video = info.videoStream {
                    for tile in tiles {
                        if token.isCancelled { throw CancellationError() }
                        sections[tile.key.section] = tile.key.encoded(tile.image,
                            preserveAlpha: video.hasAlpha || video.hasAdditionalVideoLayers)
                    }
                }
                try AnalysisSidecar(media: info).save(sections, updating: snapshot.metadataUpdates,
                    retainingLatest: [FilmstripTileKey.sectionPrefix: FilmstripTileBuffer.countLimit], cancelled: cancelled)
            }
            return sources.count
        } onSuccess: { count in
            for (_, ordinary, _, snapshot) in sources {
                if let ordinary { self.analysis.didSave(snapshot, for: ordinary) }
            }
            self.status = "Saved analysis sidecars for \(count) recording\(count == 1 ? "" : "s")."
        }
    }

    func exportSourceIssue(tracks: ExportTracks, wholeGroup: Bool) -> String? {
        guard let project else { return "Open a multicam project first." }
        do {
            let plan = try project.plan(ranges: wholeGroup ? [project.range] : nil)
            let selected = (tracks == .audio ? [] : plan.picture) + (tracks == .video ? [] : plan.audio)
            for span in selected where media[span.source]?.hasFullEditIndex != true {
                let name = project.sources.first(where: { $0.id == span.source })?.displayName ?? span.source
                let detail = sourceIssues[span.source] ?? sourceIndexIssues[span.source] ?? "The editing index is still loading."
                return "\(name) — \(detail)"
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func export(output: URL, mode: ExportMode, tracks: ExportTracks, dryRun: Bool, wholeGroup: Bool,
                settings: ReencodeSettings = .init(), checked: (() -> Void)? = nil) {
        guard let project, !isBusy else { return }
        preview.pause()
        report = nil
        suggestions = []
        suggestionAnchor = nil
        let ranges = wholeGroup ? [project.range] : nil
        let indexedSources = media.filter { $0.value.hasFullEditIndex }
        if let issue = exportSourceIssue(tracks: tracks, wholeGroup: wholeGroup) {
            fail(issue)
            return
        }
        let update: @Sendable (EditCancellation, Double) -> Void = { [weak self] token, fraction in
            Task { @MainActor [weak self] in
                self?.updateExportProgress(token, fraction: fraction)
            }
        }
        run(dryRun ? "Checking multicam export…" : "Exporting multicam program…", exporting: !dryRun) { token, useSidecar in
            try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                let engine = MulticamEngine(cancelled: { token.isCancelled })
                let plan = try engine.resolve(project, output: output, mode: mode, tracks: tracks, assembly: ranges,
                                              settings: settings, indexedSources: indexedSources)
                if dryRun {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return String(decoding: try encoder.encode(plan), as: UTF8.self)
                }
                try engine.write(plan, to: output) { update(token, $0) }
                return "Exported \(output.lastPathComponent)"
            }
        } onSuccess: { result in
            if dryRun { self.report = result; checked?() }
            else { self.status = result }
        }
    }

    func updateExportProgress(_ token: EditCancellation, fraction: Double) {
        guard operation === token else { return }
        progress = fraction
    }

    func cacheIndexedSource(_ info: MediaInfo, ordinary: MediaInfo? = nil) {
        let url = info.url
        sourceLoads.removeValue(forKey: url)?.cancel()
        indexedByURL[url] = info
        indexIssuesByURL[url] = nil
        issuesByPath[url.path] = nil
        ordinaryByURL[url] = info.multicamClockOffset == .zero ? nil : ordinary
    }

    func cancel() {
        operation?.cancel()
        if !importLoads.isEmpty {
            for cancel in importLoads { cancel() }
            finishImport()
            status = "Cancelled."
        }
    }

    func cancelAndWait(_ done: @escaping () -> Void) -> Bool {
        if !importLoads.isEmpty {
            cancel()
            Task { @MainActor in done() }
            return true
        }
        guard let operation, let waiters else { return false }
        operation.cancel()
        waiters.done.append(done)
        return true
    }

    func run<T: Sendable>(_ label: String, exporting: Bool = false,
                                  work: @escaping @Sendable (EditCancellation, Bool) throws -> T,
                                  onFailure: ((String) -> Void)? = nil,
                                  onSuccess: @escaping (T) -> Void) {
        guard !isBusy else { return }
        let token = EditCancellation()
        let useSidecar = useAnalysisSidecars
        let waiters = OperationWaiters()
        operation = token
        self.waiters = waiters
        isBusy = true
        isExporting = exporting
        progress = exporting ? 0 : nil
        status = label
        let task = Task.detached(priority: .userInitiated) { try work(token, useSidecar) }
        worker = Task { [weak self] in
            let result = await task.result
            // A reset abandons the result. Its waiters still learn that the work stopped.
            defer { waiters.finish() }
            guard let self, self.operation === token else { return }
            self.operation = nil
            self.waiters = nil
            self.openingProjectURL = nil
            self.isBusy = false
            self.isExporting = false
            self.progress = nil
            self.worker = nil
            self.status = ""
            if token.isCancelled { self.status = "Cancelled." }
            else {
                switch result {
                case .success(let value): onSuccess(value)
                case .failure(let error):
                    if let issue = error as? CutError, let at = issue.multicamAt, let nearest = issue.nearest,
                       !nearest.isEmpty, self.project?.switches.contains(where: { $0.at == at }) == true {
                        // Delete must act on the switch the inspector now shows.
                        self.editSelection = .group
                        self.selectedSwitch = at
                        self.suggestionAnchor = at
                        self.suggestions = nearest
                    }
                    let message = self.project?.sources.reduce(error.localizedDescription) { message, source in
                        message.replacingOccurrences(of: "Source \(source.id) ", with: "Source \(source.displayName) ")
                            .replacingOccurrences(of: "Angle \(source.id) ", with: "Angle \(source.displayName) ")
                    }
                    let detail = message ?? error.localizedDescription
                    if let onFailure { onFailure(detail) }
                    else { self.fail(detail) }
                }
            }
        }
    }

    func fail(_ message: String) { notice = Notice(title: "Multicam", message: message) }
}

extension MulticamSource {
    var displayName: String {
        name.flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: file).lastPathComponent
    }
}
