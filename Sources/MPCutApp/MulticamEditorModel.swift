import AppKit
import Combine
import MPCutCore
import UniformTypeIdentifiers

@MainActor
final class MulticamEditorModel: ObservableObject {
    enum EditSelection: Equatable, Sendable {
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

    private(set) var mcpGeneration = UUID()
    private(set) var mcpRevision = 0
    private(set) var lastEditAction: String?
    @Published private(set) var project: MulticamProject? {
        didSet {
            mcpRevision += 1
            if oldValue?.assembly != project?.assembly || oldValue?.range != project?.range {
                let currentRanges = ranges
                let previousRanges = oldValue.map { $0.assembly ?? [$0.range] } ?? []
                if currentRanges != previousRanges {
                    assemblyRangeEnds = Self.assemblyEnds(for: currentRanges)
                    rangeSelectionEdits = nil
                    if assemblySelection != nil { assemblySelection = nil }
                }
            }
        }
    }
    @Published private(set) var media: [String: MediaInfo] = [:]
    @Published private(set) var sourceIssues: [String: String] = [:]
    @Published private(set) var sourceIndexProgress: [String: Double] = [:]
    @Published private(set) var sourceIndexIssues: [String: String] = [:]
    @Published private(set) var projectURL: URL?
    @Published private(set) var savedProject: MulticamProject?
    struct HistoryEntry: Equatable, Sendable {
        let action: String
        var project: MulticamProject
        var selection: Selection?
    }
    @Published private(set) var undoStack: [HistoryEntry] = []
    @Published private(set) var redoStack: [HistoryEntry] = []
    let draft: ProjectDraft
    // Undo/redo moves within one branch. Adding an edit or trimming history changes the saved document.
    private(set) var historyRevision = 0
    private var savedHistoryRevision = 0
    private var savedHistoryCursor = 0
    @Published var setup: [SourceDraft] = [] {
        didSet {
            if oldValue.isEmpty != setup.isEmpty {
                setupPresentationID = setup.isEmpty ? nil : UUID()
                setupWindow = nil
            }
            if oldValue.map(\.source) != setup.map(\.source) { mcpRevision += 1 }
        }
    }
    private(set) var setupPresentationID: UUID?
    weak var setupWindow: NSWindow?
    private(set) var pendingSetupProject: MulticamProject? {
        didSet { if oldValue != pendingSetupProject { mcpRevision += 1 } }
    }
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
    @Published var rangeTool = false
    @Published var assemblySelection: AudioSpan? {
        didSet { if assemblySelection != oldValue { rangeSelectionEdits = nil } }
    }
    private(set) var assemblyRangeEnds: [RationalTime] = []
    var rangeSelectionEdits: MulticamRangeSelectionEdits?
    @Published var exportProgram = MulticamExportProgram.assembly
    @Published var markIn: RationalTime? {
        didSet {
            if markIn != oldValue { rangeSelectionEdits = nil }
            if assemblySelection != nil { assemblySelection = nil }
        }
    }
    @Published var markOut: RationalTime? {
        didSet {
            if markOut != oldValue { rangeSelectionEdits = nil }
            if assemblySelection != nil { assemblySelection = nil }
        }
    }
    let preferences: EditorPreferences
    let preview: MulticamPreview
    let filmstrip = MulticamThumbnailService()
    let analysis = MulticamAnalysisStore()
    let pauseEdits = MulticamPauseEdits()
    private(set) var previousTimelineZoom = 1.0
    @Published var timelineZoom = 0.0 {
        didSet { if timelineZoom == 0, oldValue > 0 { previousTimelineZoom = oldValue } }
    }
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
    var mcpSidecarReceipt: MCPAnalysisReceipt?
    private var operation: EditCancellation?
    private var worker: Task<Void, Never>?
    struct Selection: Equatable, Sendable {
        let marker: RationalTime?
        let occurrence: Int
        let scope: EditSelection
        let markIn: RationalTime?
        let markOut: RationalTime?
        let assemblyRange: AudioSpan?
    }
    var analysisNavigationAvailability: [TimelineSnapTarget: Bool] = [:]
    private(set) var mapping: MulticamPlan? {
        didSet { analysisNavigationAvailability.removeAll() }
    }
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
    private var importID: UUID?
    private var cancelRelinkRequest: (() -> Void)?
    var activeNativeOperation: MCPNativeOperation? {
        guard isBusy, let id = operation?.id ?? importID else { return nil }
        let kind = isExporting ? "export" : (importID != nil || openingProjectURL != nil ? "import" : nativeWorkerKind)
        return MCPNativeOperation(id: id, kind: kind, label: status, progress: progress,
                                  cancelling: operation?.isCancelled ?? false)
    }
    private var nativeWorkerKind = "multicam"
    private var provisionalGroupRange: MulticamRange?
    private var savedMediaPaths: [String: String] = [:]
    private var importingURLs: [URL] = []
    private var sidecarReferences = Set<String>()
    private(set) var sidecarExclusions = Set<URL>()

    convenience init() {
        self.init(preferences: EditorPreferences())
    }

    init(preferences: EditorPreferences, draft: ProjectDraft = ProjectDraft()) {
        self.draft = draft
        self.preferences = preferences
        preview = MulticamPreview(preferences: preferences)
        filmstrip.sidecarPreference.enabled = preferences.useAnalysisSidecars
        analysis.setSnap(preferences.snapTarget)
        analysis.configureSilence(minimum: preferences.minimumPause, threshold: nil)
        analysis.changed = { [weak self] in
            self?.analysisNavigationAvailability.removeAll()
            self?.objectWillChange.send()
        }
        preferenceObservation = preferences.observeChanges { [weak self] change in
            switch change {
            case .useAnalysisSidecars:
                guard let self else { return }
                self.filmstrip.sidecarPreference.enabled = self.useAnalysisSidecars
                for load in self.sourceLoads.values { load.cancel() }
                self.sourceLoads.removeAll()
                self.reconcileSourceLoads()
                self.refreshAnalysis()
                self.objectWillChange.send()
            case .historyLimit:
                self?.trimHistoryAndUpdateDraft()
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

    private var hasPendingInitialDraft: Bool { project == nil && pendingSetupProject != nil }

    var isChanged: Bool {
        hasPendingInitialDraft || project != savedProject || historyRevision != savedHistoryRevision || historyCursor != savedHistoryCursor
    }
    var undoTitle: String { undoStack.last.map { "Undo " + $0.action } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo " + $0.action } ?? "Redo" }
    var historyCursor: Int { undoStack.count }
    var historyActions: [String] { undoStack.map(\.action) + redoStack.reversed().map(\.action) }

    var projectName: String? { projectURL?.deletingPathExtension().lastPathComponent }
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

    func importSources(_ urls: [URL]) { importSources(urls, allowCommit: nil) }

    func importSources(_ urls: [URL], allowCommit: (() -> Bool)?) {
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
        let workerID = UUID()
        importID = workerID
        importingURLs = unique
        reconcileSourceLoads()
        isBusy = true
        status = "Reading multicam sources…"
        var results: [URL: SourceDraft] = [:]
        var ordinaryResults: [URL: MediaInfo] = [:]
        var errors: [String] = []
        var remaining = unique.count
        for file in unique {
            importLoads.append(SourceIndexLoader.shared.admit(.init(url: file, sidecars: usesSidecar(for: file), preview: true)) { [weak self] result in
                guard let self, self.importID == workerID else { return }
                switch result {
                case .success(let index):
                    let info = index.multicam
                    if info.hasFullEditIndex, info.multicamClockOffset != .zero {
                        ordinaryResults[info.url] = index.ordinary
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
                defer { self.reconcileSourceLoads() }
                guard allowCommit?() != false else { return }
                let drafts = unique.compactMap { results[$0] }
                if self.project != nil || drafts.contains(where: { $0.media.hasVideo }) {
                    for (url, info) in ordinaryResults { self.ordinaryByURL[url] = info }
                    self.setup = drafts
                    self.savePendingSetup()
                    for draft in drafts { self.indexedByURL[draft.media.url] = draft.media }
                } else if errors.isEmpty {
                    errors.append("Select at least one camera recording.")
                }
                if !errors.isEmpty { self.fail(errors.joined(separator: "\n")) }
            })
        }
    }

    /// Source setup can stay on screen while the user chooses an opening camera.
    /// A crash here should still recover the recordings they already added.
    private func savePendingSetup() {
        guard project == nil, let first = setup.first(where: { $0.media.hasVideo }) else { return }
        let choice = first.media.audio.isEmpty ? setup.first(where: { !$0.media.audio.isEmpty }) : first
        let audio: MulticamAudioPolicy
        if let choice, let track = choice.media.audio.first {
            audio = .fixed(.init(source: choice.id, stream: track.stream.index))
        } else { audio = .none }
        updatePendingSetup(setup, opening: first.id, audio: audio)
    }

    func updatePendingSetup(_ drafts: [SourceDraft], opening: String, audio: MulticamAudioPolicy) {
        guard !setup.isEmpty, Set(drafts.map(\.id)) == Set(setup.map(\.id)) else { return }
        if setup.map(\.source) != drafts.map(\.source) { setup = drafts }
        guard project == nil else { return }
        let drafts = Self.normalizedNames(in: drafts)
        guard let reference = drafts.first(where: { $0.id == opening && $0.media.hasVideo }) else { return }
        let duration = indexedByURL[reference.media.url]?.duration ?? reference.media.duration
        writePendingSetup(Self.initialProject(drafts: drafts, opening: reference, duration: duration, audio: audio))
    }

    private func writePendingSetup(_ pending: MulticamProject) {
        guard pending != pendingSetupProject else { return }
        pendingSetupProject = pending
        do { try draft.write { try Self.writeDocument(pending, undo: [], redo: [], to: $0) } }
        catch { draftFailed(error) }
    }

    private static func initialProject(drafts: [SourceDraft], opening: SourceDraft, duration: RationalTime,
                                       audio: MulticamAudioPolicy) -> MulticamProject {
        MulticamProject(referenceAngle: opening.id, range: .init(from: .zero, to: duration),
                        angles: drafts.filter { $0.media.hasVideo }.map(\.source),
                        audioSources: drafts.filter { !$0.media.hasVideo }.map(\.source), audio: audio,
                        switches: [.init(at: .zero, angle: opening.id)])
    }

    func dismissSetup() {
        setup = []
        pendingSetupProject = nil
        if project == nil { draft.discard() }
        pruneMediaCache()
        reconcileSourceLoads()
    }

    func dismissSetup(ifCurrent id: UUID) {
        if setupPresentationID == id { dismissSetup() }
    }

    private func pruneMediaCache() {
        // History stores references. Re-entering an old state's recordings goes through
        // SourceIndexLoader, which checks whether a file was replaced or went offline.
        let active = (project?.sources ?? []) + setup.map(\.source)
        let retained = Set(active.compactMap(Self.availableURL))
        indexedByURL = indexedByURL.filter { retained.contains($0.key) }
        ordinaryByURL = ordinaryByURL.filter { retained.contains($0.key) }
        indexIssuesByURL = indexIssuesByURL.filter { retained.contains($0.key) }
        issuesByPath = issuesByPath.filter { retained.contains(URL(fileURLWithPath: $0.key)) }
    }

    private func finishImport() {
        importID = nil
        cancelRelinkRequest = nil
        importLoads.removeAll()
        importingURLs = []
        isBusy = false
        status = ""
    }

    private static func normalizedNames(in drafts: [SourceDraft]) -> [SourceDraft] {
        drafts.map { draft in
            // The setup field can be cleared. A blank name means the file name.
            var draft = draft
            let name = draft.source.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.source.name = name?.isEmpty == false ? name : nil
            return draft
        }
    }

    func confirmSetup(drafts: [SourceDraft], opening: String, audio: MulticamAudioPolicy, ifCurrent id: UUID? = nil) {
        guard !isBusy, id == nil || id == setupPresentationID else { return }
        let drafts = Self.normalizedNames(in: drafts)
        let video = drafts.filter { $0.media.hasVideo }
        let recordings = drafts.filter { !$0.media.hasVideo }
        let newMedia = Dictionary(uniqueKeysWithValues: drafts.map {
            ($0.id, indexedByURL[$0.media.url] ?? $0.media)
        })
        if project != nil {
            for info in newMedia.values { indexedByURL[info.url] = info }
            guard edit("Add Multicam Sources", { candidate in
                candidate.angles.append(contentsOf: video.map(\.source))
                candidate.audioSources.append(contentsOf: recordings.map(\.source))
            }) else { return }
        } else if let reference = video.first(where: { $0.id == opening }) {
            let candidate = Self.initialProject(drafts: drafts, opening: reference,
                                                duration: newMedia[reference.id]?.duration ?? reference.media.duration,
                                                audio: audio)
            do {
                try candidate.validate()
                install(project: candidate, media: newMedia, issues: [:], url: nil)
                updateDraft()
                if newMedia[opening]?.hasFullEditIndex == false { provisionalGroupRange = candidate.range }
            } catch { fail(error.localizedDescription); return }
        } else {
            fail("Choose an opening camera to create the project.")
            return
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
        panel.allowedContentTypes = [.mpcutProject]
        ProjectPanels.present(panel, in: window) { [weak self] accepted in
            if accepted, let url = panel.url { self?.openProject(url) }
        }
    }

    func openProject(_ url: URL, document: MulticamProject? = nil,
                     history: (undo: [CutHistoryState], redo: [CutHistoryState])? = nil,
                     reservation: ProjectDraft.Reservation? = nil, archiveMedia: CutProjectMedia? = nil,
                     allowCommit: (() -> Bool)? = nil) {
        guard !isBusy, confirmClose() else { return }
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let claim: ProjectDraft.Reservation?
        do { claim = try reservation ?? draft.reserveIfRecoverable(url) }
        catch { fail(error.localizedDescription); return }
        openingProjectURL = url
        let limit = preferences.historyLimit
        run("Opening multicam project…") { _, _ in
            let project: MulticamProject
            let states: (undo: [CutHistoryState], redo: [CutHistoryState])
            let savedPaths: [String: String]
            if let document, let history, let archiveMedia {
                project = document
                states = history
                savedPaths = archiveMedia.absoluteSources(relativeTo: url)
            } else {
                let file = try CutProject.loadEditorDocument(from: url, limit: limit)
                guard case .multicam(let multicam) = file.project else {
                    throw CutError(code: "invalid_multicam_project", message: "Expected a multicam project.")
                }
                project = multicam
                states = (file.undo, file.redo)
                savedPaths = file.media.absoluteSources(relativeTo: url)
            }
            _ = try project.plan()
            _ = try project.groupIntervals()
            var paths: [String: String] = [:]
            func absolute(_ value: MulticamProject) -> MulticamProject {
                Self.mapSourcePaths(in: value, cache: &paths) { CutProject.mediaURL($0, relativeTo: url).path }
            }
            func entry(_ state: CutHistoryState) throws -> HistoryEntry {
                guard case .multicam(let prior) = state.project else {
                    throw CutError(code: "invalid_multicam_project", message: "Expected a multicam history state.")
                }
                return HistoryEntry(action: state.action, project: absolute(prior))
            }
            return try (absolute(project), states.undo.map(entry), states.redo.map(entry), savedPaths)
        } onSuccess: { result in
            guard allowCommit?() != false else { return }
            let recovered = self.draft.adopt(claim)
            if !recovered { self.draft.discard() }
            self.stopSourceLoads()
            self.savedMediaPaths = result.3
            self.install(project: result.0, media: [:], issues: [:], url: recovered ? nil : url)
            self.undoStack = result.1
            self.redoStack = result.2
            self.savedHistoryCursor = self.historyCursor
            self.trimHistoryAndUpdateDraft()
            self.reconcileSourceLoads()
        }
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
        startRelink(id, to: url, validateCommit: {}) { [weak self] result in
            if case .failure(let error) = result, !(error is CancellationError) {
                self?.fail(error.localizedDescription)
            }
        }
    }

    func relink(_ id: String, to url: URL,
                validateCommit: @escaping @MainActor () throws -> Void) async throws
        -> (revision: Int, changed: Bool, historyRetained: Bool, warning: String?) {
        let cancellation = EditCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var observer: UUID?
                let request = startRelink(id, to: url, validateCommit: {
                    if cancellation.isCancelled { throw CancellationError() }
                    try validateCommit()
                }) { result in
                    if let observer { cancellation.removeCancellationHandler(observer) }
                    continuation.resume(with: result.map { changed in
                        (self.mcpRevision, changed, changed && self.preferences.historyLimit > 0, self.notice?.message)
                    })
                }
                guard let request else {
                    continuation.resume(throwing: MCPCommandError("editor_busy", "The multicam source is unavailable for relink."))
                    return
                }
                observer = cancellation.onCancel { [weak self] in
                    Task { @MainActor in
                        guard let self, self.importID == request else { return }
                        self.cancel()
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    @discardableResult
    private func startRelink(_ id: String, to url: URL, validateCommit: @escaping @MainActor () throws -> Void,
                             completed: @escaping (Result<Bool, Error>) -> Void) -> UUID? {
        guard let project, !isBusy, let source = project.sources.first(where: { $0.id == id }) else { return nil }
        let angle = project.angles.contains { $0.id == id }
        let url = url.standardizedFileURL
        importingURLs = [url]
        reconcileSourceLoads()
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
        let request = UUID()
        importID = request
        cancelRelinkRequest = { completed(.failure(CancellationError())) }
        importLoads.append(SourceIndexLoader.shared.admit(.init(url: url, sidecars: usesSidecar(for: url), preview: preview)) { [weak self] result in
            guard let self, self.importID == request else { return }
            self.finishImport()
            let outcome = Result {
                try validateCommit()
                let index = try result.get()
                guard angle ? index.multicam.hasVideo : !index.multicam.audio.isEmpty else {
                    throw CutError(code: "source_type_mismatch", message: "The replacement recording must match the source type.")
                }
                let missing = selectedStreams.subtracting(index.multicam.audio.map(\.stream.index)).sorted()
                guard missing.isEmpty else {
                    throw CutError(code: "missing_audio_stream",
                                   message: "The replacement recording is missing selected audio stream(s) \(missing.map(String.init).joined(separator: ", ")).")
                }
                self.cacheIndexedSource(index.multicam, ordinary: index.ordinary)
                guard source.file != url.path else { return false }
                guard self.updateSource(id, { $0.file = url.path }) else {
                    let message = self.notice?.message ?? "The multicam editor could not relink this recording."
                    self.notice = nil
                    throw CutError(code: "edit_failed", message: message)
                }
                return true
            }
            self.reconcileSourceLoads()
            completed(outcome)
        })
        return request
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
        panel.allowedContentTypes = [.mpcutProject]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "Untitled.cut"
        return panel
    }

    @discardableResult
    func saveProject(to destination: URL) -> Bool {
        guard project != nil, !isBusy else { return false }
        do {
            try writeProject(to: destination)
            return true
        } catch let error as CutError where error.code == "project_draft_destination" {
            fail(error.localizedDescription)
            return false
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func writeProject(to destination: URL, replacingExisting: Bool = true) throws {
        guard let project, !isBusy else {
            throw CutError(code: "editor_busy", message: "Finish multicam setup and wait for the current operation.")
        }
        let url = destination.standardizedFileURL
        guard !ProjectDraft.isManaged(url), !draft.managesDestination(url) else {
            throw CutError(code: "project_draft_destination", message: "Choose a destination outside the automatic recovery folder.")
        }
        guard canSaveProjectTo?(url) != false else {
            throw CutError(code: "project_open", message: "Another window already has this project open.")
        }
        try validateHistoryDestination(url)
        try Self.writeDocument(project, undo: undoStack, redo: redoStack, to: url, replacingExisting: replacingExisting)
        projectURL = url
        savedProject = project
        savedMediaPaths = documentMediaPaths
        reconcileSourceLoads()
        savedHistoryRevision = historyRevision
        savedHistoryCursor = historyCursor
        draft.discard()
        status = "Saved \(url.lastPathComponent)"
    }

    private var documentMediaPaths: [String: String] {
        var paths: [String: String] = [:]
        func include(_ document: MulticamProject) {
            for source in document.angles { paths[source.file] = source.id }
            for source in document.audioSources { paths[source.file] = source.id }
        }
        if let project { include(project) }
        for entry in undoStack { include(entry.project) }
        for entry in redoStack { include(entry.project) }
        return paths
    }

    var protectedMediaPaths: [String: String] {
        var paths = savedMediaPaths.merging(documentMediaPaths) { _, current in current }
        for entry in queuedRanges {
            for source in entry.project.sources { paths[source.file] = source.id }
        }
        for draft in setup { paths[draft.source.file] = draft.id }
        for url in importingURLs { paths[url.path] = url.lastPathComponent }
        return paths
    }

    private func refreshSidecarProtection() {
        let paths = protectedMediaPaths
        let references = Set(paths.keys)
        guard sidecarReferences != references else { return }
        sidecarReferences = references
        let excluded = CutProject.sidecarExclusions(absoluteSources: paths,
                                                   candidates: references.map { URL(fileURLWithPath: $0) })
        let changed = sidecarExclusions.symmetricDifference(excluded)
        sidecarExclusions = excluded
        filmstrip.sidecarPreference.setExclusions(excluded)
        if !changed.isEmpty {
            for url in Array(sourceLoads.keys) where AnalysisSidecar.isExcluded(url, in: changed) {
                sourceLoads.removeValue(forKey: url)?.cancel()
            }
        }
    }

    private func usesSidecar(for url: URL) -> Bool {
        useAnalysisSidecars && !AnalysisSidecar.isExcluded(url, in: sidecarExclusions)
    }

    func validateHistoryDestination(_ output: URL, includesContents: Bool = false) throws {
        try CutProject.validateMediaDestination(output, absoluteSources: protectedMediaPaths, includesContents: includesContents)
    }

    nonisolated private static func writeDocument(_ project: MulticamProject, undo: [HistoryEntry],
                                                 redo: [HistoryEntry], to url: URL, replacingExisting: Bool = true) throws {
        var paths: [String: String] = [:]
        func document(_ value: MulticamProject) -> CutProject {
            .multicam(Self.mapSourcePaths(in: value, cache: &paths) { CutProject.relativeMediaPath($0, to: url) })
        }
        func state(_ entry: HistoryEntry) -> CutHistoryState {
            CutHistoryState(action: entry.action, project: document(entry.project))
        }
        try document(project).save(to: url, undo: undo.map(state), redo: redo.map(state), replacingExisting: replacingExisting)
    }

    /// All states use the document's directory. Resolve each distinct recording once per read or write.
    nonisolated private static func mapSourcePaths(in project: MulticamProject, cache: inout [String: String],
                                                  transform: (String) -> String) -> MulticamProject {
        func map(_ source: MulticamSource) -> MulticamSource {
            var copy = source
            if let path = cache[source.file] { copy.file = path }
            else {
                copy.file = transform(source.file)
                cache[source.file] = copy.file
            }
            return copy
        }
        var copy = project
        copy.angles = project.angles.map(map)
        copy.audioSources = project.audioSources.map(map)
        return copy
    }

    private func updateDraft() {
        guard projectURL == nil, let project else { return }
        let undo = undoStack
        let redo = redoStack
        let save: @Sendable (URL) throws -> Void = { url in
            try Self.writeDocument(project, undo: undo, redo: redo, to: url)
        }
        func records(in value: MulticamProject) -> Int {
            value.angles.count + value.audioSources.count + value.switches.count + (value.assembly?.count ?? 0)
        }
        let total = records(in: project) + undo.reduce(0) { $0 + records(in: $1.project) }
            + redo.reduce(0) { $0 + records(in: $1.project) }
        do {
            if draft.url != nil && (draft.hasScheduledWrites || total >= 1_000) {
                try draft.schedule(save) { [weak self] error in self?.draftFailed(error) }
            } else { try draft.write(save) }
        } catch { draftFailed(error) }
    }

    private func draftFailed(_ error: Error) {
        fail("Could not save the untitled multicam project: " + error.localizedDescription)
    }

    func confirmClose() -> Bool {
        guard !isBusy else { return false }
        guard isChanged else { return true }
        preview.pause()
        let alert = NSAlert()
        if hasPendingInitialDraft {
            alert.messageText = "Discard the untitled multicam setup?"
            alert.informativeText = "Continue setup to choose the opening camera and save this project."
            alert.addButton(withTitle: "Continue Setup")
            alert.addButton(withTitle: "Discard").hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn
        }
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

    func preserveAfterUnconfirmedClose() {
        defer { draft.relinquish() }
        guard let project = project ?? pendingSetupProject, isChanged else { return }
        let undo = undoStack, redo = redoStack
        let save: @Sendable (URL) throws -> Void = { url in
            try Self.writeDocument(project, undo: undo, redo: redo, to: url)
        }
        do {
            try draft.write(save)
        } catch { draftFailed(error) }
    }

    func reset() {
        mcpSidecarReceipt?.finish("cancelled")
        mcpSidecarReceipt = nil
        mcpGeneration = UUID()
        lastEditAction = nil
        openingProjectURL = nil
        timelineZoom = 0
        timeEntryRequest = 0
        resetExportQueue()
        isReplacementAudioPresented = false
        cancel()
        operation = nil
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
        savedMediaPaths = [:]
        importingURLs = []
        sidecarReferences = []
        sidecarExclusions = []
        filmstrip.sidecarPreference.setExclusions([])
        media = [:]
        sourceIssues = [:]
        indexedByURL = [:]
        issuesByPath = [:]
        mapping = nil
        savedProject = nil
        projectURL = nil
        undoStack = []
        redoStack = []
        historyRevision = 0
        savedHistoryRevision = 0
        savedHistoryCursor = 0
        draft.discard()
        setup = []
        pendingSetupProject = nil
        selectedSwitch = nil
        selectedOccurrence = 0
        editSelection = .group
        rangeTool = false
        exportProgram = .assembly
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
        mcpGeneration = UUID()
        lastEditAction = nil
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
        pendingSetupProject = nil
        undoStack = []
        redoStack = []
        historyRevision = 0
        savedHistoryRevision = 0
        savedHistoryCursor = 0
        selectedSwitch = project.switches.first?.at
        selectedOccurrence = 0
        editSelection = .group
        rangeTool = false
        exportProgram = .assembly
        markIn = nil
        markOut = nil
        assemblyPreview = false
        report = nil
        suggestions = []
        suggestionAnchor = nil
        refreshSidecarProtection()
        refreshPreview()
        preview.seek(to: .zero)
        window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func edit(_ action: String? = nil, _ change: (inout MulticamProject) -> Void) -> Bool {
        guard !isBusy, let project else { return false }
        var next = project
        change(&next)
        do {
            _ = try next.plan()
            _ = try next.groupIntervals()
        }
        catch { fail(error.localizedDescription); return false }
        guard next != project else { return true }
        let name = action ?? Self.editName(from: project, to: next)
        if preferences.historyLimit > 0 {
            undoStack.append(HistoryEntry(action: name, project: project, selection: selection))
            redoStack = []
            historyRevision += 1
            _ = trimHistory()
        }
        apply(next)
        lastEditAction = name
        updateDraft()
        return true
    }

    private static func editName(from previous: MulticamProject, to next: MulticamProject) -> String {
        if previous.range != next.range { return "Change Group Range" }
        if previous.audio != next.audio { return "Change Program Audio" }
        if previous.assembly != next.assembly { return "Edit Assembly" }
        for (old, new) in zip(previous.sources, next.sources) where old.id == new.id {
            if old.name != new.name { return "Rename Source" }
            if old.file != new.file { return "Relink Source" }
            if old.offset != new.offset { return "Adjust Sync Offset" }
            if old.audioStream != new.audioStream { return "Change Source Audio Stream" }
        }
        return "Edit Multicam Project"
    }

    private func trimHistory() -> Bool {
        let keep = CutProject.historyCounts(undo: undoStack.count, redo: redoStack.count, limit: preferences.historyLimit)
        guard keep.undo < undoStack.count || keep.redo < redoStack.count else { return false }
        undoStack.removeFirst(undoStack.count - keep.undo)
        redoStack.removeFirst(redoStack.count - keep.redo)
        return true
    }

    private func trimHistoryAndUpdateDraft() {
        guard trimHistory() else { return }
        mcpRevision += 1
        reconcileSourceLoads()
        historyRevision += 1
        updateDraft()
    }

    func undo() { moveToHistoryState(historyCursor - 1) }
    func redo() { moveToHistoryState(historyCursor + 1) }

    func moveToHistoryState(_ index: Int) {
        guard !isBusy, let project, (0...(undoStack.count + redoStack.count)).contains(index),
              index != historyCursor else { return }
        let backwards = index < historyCursor
        var undo = undoStack, redo = redoStack
        var target = project
        var restored: Selection? = selection
        while index != undo.count {
            let entry = backwards ? undo.removeLast() : redo.removeLast()
            let inverse = HistoryEntry(action: entry.action, project: target, selection: restored)
            if backwards { redo.append(inverse) } else { undo.append(inverse) }
            target = entry.project
            restored = entry.selection
        }
        undoStack = undo
        redoStack = redo
        apply(target)
        if let restored { select(restored) }
        updateDraft()
    }

    private var selection: Selection {
        Selection(marker: selectedSwitch, occurrence: selectedOccurrence, scope: editSelection,
                  markIn: markIn, markOut: markOut, assemblyRange: assemblySelection)
    }

    /// History entries carry the selection that was current when they were replaced.
    private func select(_ selection: Selection) {
        let marker = selection.marker.flatMap { at in project?.switches.contains(where: { $0.at == at }) == true ? at : nil }
        let occurrence = min(max(0, selection.occurrence), max(0, ranges.count - 1))
        if selectedSwitch != marker { selectedSwitch = marker }
        if selectedOccurrence != occurrence { selectedOccurrence = occurrence }
        if editSelection != selection.scope { editSelection = selection.scope }
        if markIn != selection.markIn { markIn = selection.markIn }
        if markOut != selection.markOut { markOut = selection.markOut }
        if assemblySelection != selection.assemblyRange { assemblySelection = selection.assemblyRange }
    }

    private func apply(_ next: MulticamProject) {
        let sourcesChanged = project?.sources.map(\.file) != next.sources.map(\.file)
        project = next
        if sourcesChanged { pruneMediaCache() }
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

    func reconcileSourceLoads() {
        refreshSidecarProtection()
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
            let key = SourceIndexLoader.Key(url: url, sidecars: usesSidecar(for: url), preview: header == nil,
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
        if var pending = pendingSetupProject,
           let reference = pending.angles.first(where: { $0.id == pending.referenceAngle }),
           Self.availableURL(reference) == info.url, pending.range.to != info.duration {
            pending.range = MulticamRange(from: .zero, to: info.duration)
            writePendingSetup(pending)
        }
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
        for index in undoStack.indices { undoStack[index].project = resolvedRange(in: undoStack[index].project) }
        for index in redoStack.indices { redoStack[index].project = resolvedRange(in: redoStack[index].project) }
        updateDraft()
    }

    func ordinaryAnalysisMedia(_ id: String) -> MediaInfo? {
        guard let info = media[id], info.hasFullEditIndex else { return nil }
        return ordinaryByURL[info.url] ?? (info.multicamClockOffset == .zero ? info : nil)
    }

    @discardableResult
    func updateSource(_ id: String, _ change: (inout MulticamSource) -> Void) -> Bool {
        edit { project in
            if let row = project.angles.firstIndex(where: { $0.id == id }) {
                change(&project.angles[row])
            }
            if let row = project.audioSources.firstIndex(where: { $0.id == id }) {
                change(&project.audioSources[row])
            }
        }
    }

    func renameSource(_ id: String, to text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSource(id) { $0.name = name.isEmpty ? nil : name }
    }

    var lastCameraGroupEnd: RationalTime? {
        project?.angles.compactMap { source in
            media[source.id].flatMap { try? $0.duration.adding(source.offset) }
        }.max()
    }

    func moveSource(_ id: String, by delta: Int) {
        edit("Reorder Cameras") { project in
            guard let index = project.angles.firstIndex(where: { $0.id == id }),
                  project.angles.indices.contains(index + delta) else { return }
            project.angles.swapAt(index, index + delta)
        }
    }

    @discardableResult
    func moveOffset(_ id: String, by delta: Int, at clock: RationalTime? = nil) -> RationalTime? {
        guard let project, let source = project.sources.first(where: { $0.id == id }), let info = media[id] else { return nil }
        let clock = clock ?? currentGroupTime()
        guard let sampleTime = try? clock.subtracting(source.offset) else { return nil }
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
            guard let rate = track?.stream.sampleRate, rate > 0 else { return nil }
            duration = RationalTime(numerator: Int64(delta), denominator: Int64(rate))
        } else { duration = nil }
        guard let duration, let offset = try? source.offset.adding(duration) else { return nil }
        guard updateSource(id, { $0.offset = offset }) else { return nil }
        return offset
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
        analysis.update(project: project, media: media, ordinary: ordinary, useSidecars: useAnalysisSidecars,
                        excludedSources: sidecarExclusions)
    }

    func interval(at output: RationalTime) -> MulticamInterval? {
        guard let mapping else { return nil }
        let index = mapping.intervals.lowerBound { $0.output.to > output }
        return mapping.intervals.indices.contains(index) ? mapping.intervals[index] : mapping.intervals.last
    }

    func groupTime(at output: RationalTime) -> RationalTime {
        guard let interval = interval(at: output),
              let delta = try? output.subtracting(interval.output.from),
              let group = try? interval.group.from.adding(delta) else { return .zero }
        return min(group, interval.group.to)
    }

    func currentGroupTime() -> RationalTime { groupTime(at: preview.currentTime()) }

    var activeOccurrenceIndex: Int { occurrenceIndex(at: preview.currentTime()) }

    func occurrenceIndex(at output: RationalTime) -> Int {
        guard assemblyPreview else { return selectedOccurrence }
        return interval(at: output)?.assemblyIndex ?? selectedOccurrence
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
        _ = take(id, at: currentGroupTime())
    }

    /// Both live camera buttons and explicit-time commands use native snapping and history.
    @discardableResult
    func take(_ id: String, at clock: RationalTime) -> RationalTime? {
        guard let project, !isBusy, project.range.contains(clock),
              project.angles.contains(where: { $0.id == id }) else { return nil }
        let exact = project.switches.first { $0.at == clock }
        let at = exact?.at ?? snappedAnalysisTime(clock, excludingGroupEdges: true) ?? snappedFrame(clock, delta: 0) ?? clock
        guard project.range.from <= at, at < project.range.to else { return nil }
        if edit("Switch Camera", { candidate in
            if let index = candidate.switches.firstIndex(where: { $0.at == at }) {
                candidate.switches[index].angle = id
            } else {
                candidate.switches.append(MulticamSwitch(at: at, angle: id))
                candidate.switches.sort { $0.at < $1.at }
            }
        }) {
            editSelection = .group
            selectedSwitch = at
            return at
        }
        return nil
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
        if edit("Move Switch", { candidate in
            guard let index = candidate.switches.firstIndex(where: { $0.at == original }) else { return }
            candidate.switches[index].at = at
            candidate.switches.sort { $0.at < $1.at }
        }) { selectMarker(at) }
    }

    func deleteSwitch(_ at: RationalTime) {
        guard at != project?.range.from else { return }
        edit("Delete Switch") { $0.switches.removeAll { $0.at == at } }
    }

    func changeSwitch(_ at: RationalTime, angle: String? = nil, audio: MulticamAudioSelection? = nil) {
        edit(angle == nil ? "Change Switch Audio" : "Change Switch Camera") { candidate in
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
        addAssemblyRange(.init(from: marks.from, to: marks.to))
    }

    func addAssemblyRange(_ range: MulticamRange) {
        if edit("Add Marked Range", { project in
            project.assembly = (project.assembly ?? []) + [range]
        }) {
            focusAssemblyEdit()
            selectedOccurrence = ranges.count - 1
        }
    }

    func changeOccurrence(_ index: Int? = nil, from: RationalTime? = nil, to: RationalTime? = nil) {
        let index = index ?? selectedOccurrence
        if edit("Trim Assembly Range", { project in
            var ranges = project.assembly ?? [project.range]
            guard ranges.indices.contains(index) else { return }
            let current = ranges[index]
            let revised = MulticamRange(from: from ?? current.from, to: to ?? current.to)
            guard revised != current else { return }
            ranges[index] = revised
            project.assembly = ranges
        }) {
            selectedOccurrence = index
            focusAssemblyEdit()
        }
    }

    func splitOccurrence() {
        guard let (index, at) = occurrenceCut else { return }
        commitOccurrenceSplit(index: index, at: at)
    }

    @discardableResult
    func commitOccurrenceSplit(index: Int, at: RationalTime) -> Bool {
        var splitRanges = ranges
        guard splitRanges.indices.contains(index), !isBusy else { return false }
        let current = splitRanges[index]
        guard current.from < at, at < current.to else { return false }
        splitRanges.replaceSubrange(index...index, with: [
            MulticamRange(from: current.from, to: at), MulticamRange(from: at, to: current.to)
        ])
        preview.pause()
        if edit("Split Assembly Range", { $0.assembly = splitRanges }) {
            focusAssemblyEdit()
            selectedOccurrence = index + 1
            if assemblyPreview {
                seekAssemblyOccurrence(index + 1, group: at)
            } else {
                seekGroup(at)
            }
            splitRevision += 1
            return true
        }
        return false
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
        seekAssembly(at: output, scrubbing: scrubbing)
    }

    func seekAssembly(at output: RationalTime, scrubbing: Bool) {
        if !assemblyPreview { setAssemblyPreview(true) }
        guard let mapping, .zero <= output, output <= mapping.duration else { return }
        focusAssemblyEdit()
        selectedOccurrence = occurrenceIndex(at: output)
        if scrubbing { preview.scrub(to: output) }
        else { preview.seek(to: output) }
    }

    func trimAssemblyOccurrence(_ index: Int, edge: TimelineEdge, seconds: Double, commit: Bool) -> Double? {
        guard ranges.indices.contains(index), let requested = timelineRationalTime(seconds) else { return nil }
        let range = ranges[index]
        let original = edge == .start ? range.from : range.to
        let time = seconds == original.seconds ? original : requested
        return trimAssemblyOccurrence(index, edge: edge, time: time, commit: commit)?.seconds
    }

    func trimAssemblyOccurrence(_ index: Int, edge: TimelineEdge, time: RationalTime, commit: Bool) -> RationalTime? {
        guard let project, !isBusy, ranges.indices.contains(index) else { return nil }
        let range = ranges[index]
        let original = edge == .start ? range.from : range.to
        let target = min(project.range.to, max(project.range.from, time))
        let result: RationalTime?
        if time == original {
            result = original
        } else if analysis.snapTarget == .keyframes {
            result = nearestAssemblyCopyEdge(target, edge: edge, range: range, project: project)
        } else {
            result = snappedAnalysisTime(target) ?? snappedFrame(target, delta: 0) ?? target
        }
        guard let result,
              project.range.from <= result, result <= project.range.to,
              edge == .start ? result < range.to : result > range.from else { return nil }
        guard commit, result != original else { return result }

        var updated = ranges
        if edge == .start { updated[index].from = result }
        else { updated[index].to = result }
        preview.pause()
        guard edit("Trim Assembly Range", { $0.assembly = updated }) else { return nil }
        selectAssemblyOccurrence(index)
        return result
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
            guard edit("Move Assembly Range", { $0.assembly = reordered }) else { return }
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
        if edit("Move Assembly Range", { project in
            var moved = assembly
            moved.swapAt(index, next)
            project.assembly = moved
        }) {
            focusAssemblyEdit()
            selectedOccurrence = next
            seekAssemblyOccurrence(next, group: target)
        }
    }

    func removeOccurrence() { removeOccurrence(selectedOccurrence) }

    func removeOccurrence(_ index: Int) {
        guard !isBusy, var assembly = project?.assembly, assembly.indices.contains(index) else { return }
        assembly.remove(at: index)
        preview.pause()
        if edit("Delete Assembly Range", { $0.assembly = assembly.isEmpty ? nil : assembly }) {
            selectOccurrence(min(index, ranges.count - 1))
        }
    }

    func saveAnalysisSidecars() {
        guard canSaveSidecars else { return }
        let receipt = mcpSidecarReceipt
        let outputs = receipt.map { _ in MCPLiveOutputProgress() }
        let endWork = receipt?.cleanup.begin()
        var seen: Set<URL> = []
        let sources = media.keys.sorted().compactMap { id -> (MediaInfo, MediaInfo?, [FilmstripTile], MulticamAnalysisSnapshot)? in
            guard let info = media[id] else { return nil }
            guard info.hasFullEditIndex, seen.insert(info.url).inserted else { return nil }
            let ordinary = ordinaryAnalysisMedia(id)
            let snapshot = ordinary.map { analysis.snapshot(for: $0) } ?? MulticamAnalysisSnapshot()
            return (info, ordinary, filmstrip.snapshot(for: info), snapshot)
        }
        let protected = protectedMediaPaths
        run("Saving analysis sidecars…", kind: "sidecars") { token, _ in
            let excluded = CutProject.sidecarExclusions(absoluteSources: protected, candidates: sources.map { $0.0.url })
            if let conflict = sources.first(where: { AnalysisSidecar.isExcluded($0.0.url, in: excluded) }) {
                throw CutError(code: "output_conflict", message: "The analysis file for ‘\(conflict.0.url.lastPathComponent)’ would overwrite media referenced by this project.")
            }
            let cancelled = { @Sendable in token.isCancelled }
            let engine = CutEngine(cancelled: cancelled)
            for (index, source) in sources.enumerated() {
                let (info, ordinary, tiles, snapshot) = source
                if token.isCancelled { throw CancellationError() }
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
                outputs?.published(AnalysisSidecar.url(for: info.url))
                outputs?.update(Double(index + 1) / Double(sources.count))
            }
            return sources.count
        } onFailure: { message in
            var detail = outputs?.snapshot ?? [:]
            detail["error"] = message
            receipt?.finish("failed", detail: detail)
            self.mcpSidecarReceipt = nil
            self.fail(message)
        } onSuccess: { count in
            receipt?.finish("succeeded", detail: ["outputs": sources.map { AnalysisSidecar.url(for: $0.0.url).path }])
            self.mcpSidecarReceipt = nil
            for (_, ordinary, _, snapshot) in sources {
                if let ordinary { self.analysis.didSave(snapshot, for: ordinary) }
            }
            self.status = "Saved analysis sidecars for \(count) recording\(count == 1 ? "" : "s")."
        }
        if let token = operation {
            receipt?.cancelNative = { token.cancel() }
            receipt?.cancelledDetail = { outputs?.snapshot ?? [:] }
            receipt?.nativeProgress = { outputs?.snapshot["progress"] as? Double }
            if let endWork, let worker {
                Task {
                    await worker.value
                    endWork()
                }
            }
        } else {
            endWork?()
        }
    }

    func exportSourceIssue(tracks: ExportTracks, wholeGroup: Bool, mode: ExportMode = .copy,
                           settings: ReencodeSettings = .init(), selection: [MulticamRange]? = nil) -> String? {
        guard let project else { return "Open a multicam project first." }
        if selection?.isEmpty == true { return "Select a range on the timeline to export." }
        do {
            let plan = try project.plan(ranges: selection ?? (wholeGroup ? [project.range] : nil))
            let needsAudio = tracks != .video && (mode != .encode || settings.audio != .removeAudio)
            let selected = (tracks == .audio ? [] : plan.picture) + (needsAudio ? plan.audio : [])
            for span in selected where media[span.source]?.hasFullEditIndex != true {
                let name = project.sources.first(where: { $0.id == span.source })?.displayName ?? span.source
                let detail = sourceIssues[span.source] ?? sourceIndexIssues[span.source] ?? "The editing index is still loading."
                return "\(name) — \(detail)"
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func export(output: URL, mode: ExportMode, tracks: ExportTracks, dryRun: Bool, wholeGroup: Bool,
                settings: ReencodeSettings = .init(), selection: [MulticamRange]? = nil, checked: (() -> Void)? = nil) {
        guard let project, !isBusy else { return }
        preview.pause()
        report = nil
        suggestions = []
        suggestionAnchor = nil
        let ranges = selection ?? (wholeGroup ? [project.range] : nil)
        let indexedSources = media.filter { $0.value.hasFullEditIndex }
        if let issue = exportSourceIssue(tracks: tracks, wholeGroup: wholeGroup, mode: mode, settings: settings, selection: selection) {
            fail(issue)
            return
        }
        let update: @Sendable (EditCancellation, Double) -> Void = { [weak self] token, fraction in
            Task { @MainActor [weak self] in
                self?.updateExportProgress(token, fraction: fraction)
            }
        }
        let protected = protectedMediaPaths
        run(dryRun ? "Checking multicam export…" : "Exporting multicam program…", exporting: !dryRun) { token, useSidecar in
            try CutProject.validateMediaDestination(output, absoluteSources: protected)
            return try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
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
            let onCancel = cancelRelinkRequest
            for cancel in importLoads { cancel() }
            finishImport()
            reconcileSourceLoads()
            status = "Cancelled."
            onCancel?()
        }
    }

    func cancelAndWait(_ done: @escaping () -> Void) -> Bool {
        let operationWorker = worker
        let metadataWrite = analysis.metadataWrite
        guard !importLoads.isEmpty || operationWorker != nil || metadataWrite != nil else { return false }
        cancel()
        Task { @MainActor in
            await operationWorker?.value
            await metadataWrite?.value
            done()
        }
        return true
    }

    func run<T: Sendable>(_ label: String, exporting: Bool = false, additionalSources: [URL] = [], kind: String = "multicam",
                                  work: @escaping @Sendable (EditCancellation, Bool) throws -> T,
                                  onFailure: ((String) -> Void)? = nil,
                                  onSuccess: @escaping (T) -> Void) {
        guard !isBusy else { return }
        let token = EditCancellation()
        let useSidecar = useAnalysisSidecars
        if !additionalSources.isEmpty {
            importingURLs = additionalSources
            reconcileSourceLoads()
        }
        let protected = AnalysisSidecar.excludedSources.union(sidecarExclusions)
        operation = token
        nativeWorkerKind = kind
        isBusy = true
        isExporting = exporting
        progress = exporting ? 0 : nil
        status = label
        let task = Task.detached(priority: .userInitiated) {
            try AnalysisSidecar.$excludedSources.withValue(protected) { try work(token, useSidecar) }
        }
        worker = Task { [weak self] in
            let result = await task.result
            guard let self, self.operation === token else { return }
            if !additionalSources.isEmpty { self.importingURLs = [] }
            defer { if !additionalSources.isEmpty { self.reconcileSourceLoads() } }
            self.operation = nil
            self.openingProjectURL = nil
            self.isBusy = false
            self.isExporting = false
            self.progress = nil
            self.worker = nil
            self.status = ""
            if token.isCancelled {
                self.mcpSidecarReceipt?.finish("cancelled")
                self.mcpSidecarReceipt = nil
                self.status = "Cancelled."
            }
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
