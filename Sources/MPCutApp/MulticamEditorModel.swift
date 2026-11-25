import AppKit
import Combine
import MPCutCore
import UniformTypeIdentifiers

@MainActor
final class MulticamEditorModel: ObservableObject {
    @Published var projectMediaRequest: ProjectMediaRequest?
    let projectMediaJobs = ProjectMediaJobs()
    let projectMediaSummaryPaths = ProjectMediaSummaryPaths()
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

    var participantSourceReset: (() -> Void)?
    private(set) var mcpGeneration = UUID() {
        didSet { participantSourceReset?() }
    }
    private(set) var mcpRevision = 0
    private(set) var lastEditAction: String?
    @Published private(set) var project: MulticamProject? {
        didSet {
            projectMediaSummaryPaths.invalidate()
            let currentLayouts = project?.assemblyItems?.filter { !$0.tileLayouts.isEmpty }
            let previousLayouts = oldValue?.assemblyItems?.filter { !$0.tileLayouts.isEmpty }
            if project?.participants != oldValue?.participants || project?.groupTileLayouts != oldValue?.groupTileLayouts
                || currentLayouts != previousLayouts {
                invalidatedQueueIDs.formUnion(queuedRanges.map(\.id))
            }
            var previous = oldValue
            var current = project
            previous?.transcripts = .init()
            current?.transcripts = .init()
            if previous != current {
                mcpRevision += 1
                refreshTier()
            }
            if oldValue?.assemblyItems != project?.assemblyItems || oldValue?.range != project?.range {
                assemblyRangeEnds = Self.assemblyEnds(for: assemblyItems)
                rangeSelectionEdits = nil
                if assemblySelection != nil { assemblySelection = nil }
            }
        }
    }
    private(set) var transcriptMediaRevision: UInt64 = 0
    var timelineOutputRevision: TimelineOutputRevision? {
        guard groupPreviewProject?.requiresPictureProcessing == true else { return nil }
        return TimelineOutputRevision(generation: mcpGeneration, edit: mcpRevision, document: projectURL,
                                      media: transcriptMediaRevision)
    }
    private var timelineOutputRenderer: (TimelineOutputRevision, TimelineOutputThumbnailRenderer)?

    func outputThumbnail(group: RationalTime, recording: String, size: CGSize, revision: TimelineOutputRevision) async -> CGImage? {
        guard timelineOutputRevision == revision else { return nil }
        if timelineOutputRenderer?.0 != revision {
            guard let groupProject = groupPreviewProject else { return nil }
            timelineOutputRenderer = (revision, TimelineOutputThumbnailRenderer(project: groupProject, document: projectURL))
        }
        let image = try? await timelineOutputRenderer?.1.image(group: group, recording: recording, size: size)
        return timelineOutputRevision == revision && !Task.isCancelled ? image : nil
    }

    @Published private(set) var media: [String: MediaInfo] = [:] {
        didSet {
            transcriptMediaRevision &+= 1
            refreshTier()
        }
    }
    @Published private(set) var sourceIssues: [String: String] = [:]
    @Published private(set) var sourceIndexProgress: [String: Double] = [:]
    @Published private(set) var sourceIndexIssues: [String: String] = [:]
    @Published private(set) var projectURL: URL? {
        didSet {
            filmstrip.sidecarPreference.projectURL = projectURL
            sidecarReferences = []
            if let projectURL { preferences.recentFiles.record([projectURL]) }
        }
    }
    var sidecarWork: ProjectSidecarWork {
        ProjectSidecarWork(project: filmstrip.sidecarPreference.projectURL)
    }
    private var projectDiskRevision: ProjectDiskRevision?
    var feedAngleDiskRevision: ProjectDiskRevision? { projectDiskRevision }
    func invalidateFeedAngleDiskRevision() { projectDiskRevision = nil }

    func restoreFeedAngleConversion(url: URL?, diskRevision: ProjectDiskRevision?, revision: Int,
                                    assets: [String: TranscriptAsset]) {
        if projectDiskRevision != diskRevision || projectURL != url { savedProject = nil }
        projectURL = url
        projectDiskRevision = diskRevision
        if var project {
            for index in project.transcripts.attachments.indices {
                if let asset = assets[project.transcripts.attachments[index].asset.sha256] {
                    project.transcripts.attachments[index].asset = asset
                }
            }
            self.project = project
        }
        mcpRevision = revision + 1
        updateDraft()
    }
    private(set) var mediaSnapshot = ProjectMediaSnapshot() {
        didSet { ignoredMediaPaths = mediaSnapshot.ignoredPaths }
    }
    private var ignoredMediaPaths: Set<String> = []
    @Published private(set) var savedProject: MulticamProject?
    struct HistoryEntry: Equatable, Sendable {
        let action: String
        var origin = HistoryOrigin.current
        var project: MulticamProject
        var selection: Selection?
        var bindingChanges: [TranscriptBindingChange] = []
    }
    @Published private(set) var undoStack: [HistoryEntry] = []
    @Published private(set) var redoStack: [HistoryEntry] = []
    var conversionUndoArchive: () -> [CutHistoryState] = { [] }
    private var unopenedConversionUndo: [CutHistoryState] = []
    func didOpenFeedAngleHistory() { unopenedConversionUndo.removeAll() }
    var nativeConversionRedoArchive: [CutHistoryState] {
        redoStack.map { .init(action: $0.action, origin: $0.origin, project: .multicam($0.project),
                              bindingChanges: $0.bindingChanges) }
    }

    private var conversionUndo: [CutHistoryState] { unopenedConversionUndo + conversionUndoArchive() }
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
    @Published var exportDeliverySummary: String?
    @Published var exportRequested = false
    @Published var queuedRanges: [MulticamQueuedRange] = [] {
        didSet {
            var targets = QueueMediaTargets()
            for entry in queuedRanges { entry.addMediaTargets(to: &targets) }
            queuedMediaTargets = targets
            if mediaWatcher != nil { updateMediaWatcher() }
        }
    }
    private var queuedMediaTargets = QueueMediaTargets()
    @Published var isBulkQueuePresented = false
    @Published var isReplacementAudioPresented = false
    @Published var trackReplacementTarget: MulticamAudioSelection?
    var bulkExportDirectory: URL?
    /// The folder this window's last export panel chose. With a Settings starting folder other than Automatic it
    /// starts every later export panel of the session.
    var exportSessionFolder: URL?
    /// The file or folder the last finished export wrote, for Show in Finder.
    @Published var lastExportedURL: URL?
    /// The Settings completion actions. Nil is the shared service; tests replace it.
    var exportCompletion: ExportCompletion?
    /// Keeps the Mac awake during an export. Tests replace it.
    var sleepActivities: ActivityProviding = ProcessInfo.processInfo
    @Published private(set) var suggestions: [RationalTime] = []
    @Published private(set) var suggestionAnchor: RationalTime?
    /// Verified times for an unsafe edge of the assembly range the last export stopped at.
    @Published var edgeSuggestion: MulticamEdgeSuggestion?
    /// True while the running export writes the saved assembly, whose ranges an edge suggestion numbers.
    var exportsSavedAssembly = false
    /// The tier of the saved program, as the badge shows it. Nil without a project.
    @Published var tierState: TierState?
    /// False while a newer program is still being checked.
    var tierIsCurrent = true
    var tierGeneration = 0
    var tierToken: EditCancellation?
    let tierGate = MulticamTierGate()
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
    /// The alternatives the export rules reported for the last unavailable export, least destructive first.
    @Published var exportAlternatives: [ExportAlternative] = []
    @Published var stillExportBoundaryChoices: [StillBoundaryAdjustment] = []
    private var stillExportBoundaryBaseline: CutProject?
    /// The mode of the last export asked for. `unavailableExportMode` is that mode while its alternatives are on offer.
    private(set) var requestedExportMode: ExportMode?
    var unavailableExportMode: ExportMode? { exportAlternatives.isEmpty ? nil : requestedExportMode }
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
    private(set) var openingProjectURL: URL? {
        didSet { filmstrip.sidecarPreference.projectURL = openingProjectURL.flatMap {
            ProjectDraft.isManaged($0) || draft.managesDestination($0) ? nil : $0
        } ?? projectURL }
    }
    var chooseProjectRequest: (() -> Void)?
    var canSaveProjectTo: ((URL) -> Bool)?
    weak var window: NSWindow?
    private var storageObservers: Set<AnyCancellable> = []
    private var preferenceObservation: AnyCancellable?
    var useAnalysisSidecars: Bool {
        get { preferences.useAnalysisSidecars }
        set { preferences.useAnalysisSidecars = newValue }
    }
    var mcpSidecarReceipt: MCPAnalysisReceipt?
    private let mediaRefresh = ProjectMediaRefresh()
    var mcpRefreshReceipt: MCPAnalysisReceipt? { mediaRefresh.activeReceipt }
    @Published private(set) var mediaRefreshProgress: Double?
    @Published private var mediaRefreshWarnings: [String: String] = [:]
    var mediaRefreshIssues: [String: String] {
        guard let project, !refreshBaselines.isEmpty || !refreshReviewReasons.isEmpty else { return [:] }
        let plans = [try? project.plan(ranges: [project.range]), try? project.plan()].compactMap { $0 }
        let spanIssues = Dictionary(plans.flatMap { plan in
            let pictureIssues = plan.picture.compactMap { span in
                refreshIssue(for: span).map { (span.source, $0) }
            }
            let audioLanes = !project.audioReplacements.isEmpty
                ? (try? project.resolveAudioLanes(plan: plan, indexedSources: media)) ?? plan.audioLanes
                : plan.audioLanes
            return pictureIssues + audioLanes.flatMap { lane in
                lane.spans.enumerated().compactMap { index, span in
                    refreshIssue(for: span, mayStartWithSilence: index == 0).map { (span.source, "\(lane.label) — \($0)") }
                }
            }
        }, uniquingKeysWith: { first, _ in first })
        return Dictionary(uniqueKeysWithValues: project.sources.compactMap { source in
            let stale = analysis.refreshStaleScenes.contains(source.id) || analysis.hasStaleSilence(source.id)
            let issue = refreshPictureIssue(sourceID: source.id) ?? spanIssues[source.id] ??
                (stale ? "\(source.displayName) — analysis is out of date." : mediaRefreshWarnings[source.id])
            return issue.map { (source.id, $0) }
        })
    }
    private var refreshReviewStreams: [URL: Set<Int>] = [:]
    private var refreshReviewPicture = Set<URL>()
    private var refreshReviewReasons: [String: String] = [:]
    private var refreshBaselines: [URL: MediaInfo] = [:]
    @Published private(set) var invalidatedQueueIDs = Set<UUID>()
    private var mediaWatcher: ProjectMediaWatcher?
    var interchangeCheckingVolumes: Set<String> { mediaWatcher?.checkingVolumes ?? ProjectMediaWatcher.knownCheckingVolumes }
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
    private var sourceProgressUpdate: Task<Void, Never>?
    private var importLoads: [() -> Void] = []
    private var importID: UUID?
    var activeNativeOperation: MCPNativeOperation? {
        guard isBusy, let id = operation?.id ?? importID else { return nil }
        let kind = isExporting ? "export" : (importID != nil || openingProjectURL != nil ? "import" : nativeWorkerKind)
        return MCPNativeOperation(id: id, kind: kind, label: status, progress: progress,
                                  cancelling: operation?.isCancelled ?? false)
    }
    private var nativeWorkerKind = "multicam"
    private var isFlushingDraftSidecars = false
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
        analysis.maxBlip = preferences.maxBlip
        analysis.configureSilence(minimum: preferences.minimumPause, threshold: nil)
        analysis.saveAnnotations = { [weak self] next, action in
            self?.edit(action) { $0.analysisAnnotations = next } ?? false
        }
        analysis.changed = { [weak self] in
            self?.analysisNavigationAvailability.removeAll()
            self?.objectWillChange.send()
        }
        NotificationCenter.default.publisher(for: .sidecarStorageDidChange).sink { [weak self] _ in
            guard let self else { return }
            self.sidecarReferences = []
            self.refreshSidecarProtection()
        }.store(in: &storageObservers)
        NotificationCenter.default.publisher(for: .sidecarCachesDidClear).sink { [weak self] notification in
            guard let self, let cleared = notification.object as? Set<URL> else { return }
            let urls = Set(cleared.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
            let affected = self.media.filter { urls.contains($0.value.url.standardizedFileURL.resolvingSymlinksInPath()) }
            guard !affected.isEmpty else { return }
            if self.nativeWorkerKind == "sidecars" { self.operation?.cancel() }
            self.mediaRefresh.cancel()
            for source in affected.values {
                self.filmstrip.invalidate(source.url)
            }
            self.analysis.discardClearedAnalysis(for: Set(affected.keys), whole: notification.userInfo?["wholeSidecars"] as? Bool == true)
        }.store(in: &storageObservers)
        preferenceObservation = preferences.observeChanges { [weak self] change in
            switch change {
            case .automaticallyRefreshMedia:
                self?.updateMediaWatcher()
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
            case .maxBlip:
                if let self { self.analysis.maxBlip = self.preferences.maxBlip }
            case .minimumPause:
                if let self {
                    self.analysis.configureSilence(minimum: self.preferences.minimumPause, threshold: self.analysis.pauseThreshold)
                }
            case .largeThumbnails, .sourceTimeTicks, .defaultExportMode, .jpegPreset, .padding, .trackLabelWidth:
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

    func retainedTimeline(at index: Int) -> CutProject? {
        guard (0...(undoStack.count + redoStack.count)).contains(index), let project else { return nil }
        if index == historyCursor { return .multicam(project) }
        if index < historyCursor { return .multicam(undoStack[index].project) }
        return .multicam(redoStack[redoStack.count - (index - historyCursor)].project)
    }
    var projectHistory: [ProjectHistoryAction] {
        func action(_ entry: HistoryEntry) -> ProjectHistoryAction {
            ProjectHistoryAction(name: entry.action, origin: entry.origin)
        }
        return undoStack.map(action) + redoStack.reversed().map(action)
    }
    var historyActions: [String] { projectHistory.map(\.name) }

    var projectName: String? { projectURL?.deletingPathExtension().lastPathComponent }
    var hasSession: Bool { project != nil || isBusy || !setup.isEmpty }
    var canChooseSources: Bool { !isBusy && setup.isEmpty }
    var ranges: [MulticamRange] { project.map { $0.assembly ?? [$0.range] } ?? [] }

    var assemblyItems: [StillAssemblyItem] {
        project.map { $0.assemblyItems ?? [.group($0.range)] } ?? []
    }

    var stillPreviewProject: CutProject? {
        if assemblyPreview { return project.map(CutProject.multicam) }
        return groupPreviewProject
    }

    private var groupPreviewProject: CutProject? {
        guard var project else { return nil }
        if project.participants.render != nil,
           let group = try? project.pictureExportSnapshot(ranges: [project.range]) {
            return .multicam(group)
        }
        project.assemblyItems = nil
        return .multicam(project)
    }

    var assemblyGroupIndices: [Int] { assemblyItems.indices.filter { assemblyRange(at: $0) != nil } }

    func assemblyRange(at index: Int) -> MulticamRange? {
        guard assemblyItems.indices.contains(index), let range = assemblyItems[index].group else { return nil }
        return range
    }

    func assemblyStill(at index: Int) -> StillInsert? {
        guard assemblyItems.indices.contains(index), case .still(let still) = assemblyItems[index] else { return nil }
        return still
    }

    func assemblyStart(at index: Int) -> RationalTime { index == 0 ? .zero : assemblyRangeEnds[index - 1] }
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

    func importSources(_ urls: [URL], startAutomatically: Bool = false) {
        importSources(urls, allowCommit: nil, startAutomatically: startAutomatically)
    }

    func importSources(_ urls: [URL], allowCommit: (() -> Bool)?, startAutomatically: Bool = false) {
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
            importLoads.append(SourceIndexLoader.shared.admit(.init(url: file, sidecars: usesSidecar(for: file), preview: true, project: sidecarWork.project)) { [weak self] result in
                guard let self, self.importID == workerID else { return }
                switch result {
                case .success(let index):
                    let info = index.multicam
                    if info.hasFullEditIndex, info.multicamClockOffset != .zero {
                        ordinaryResults[info.url] = index.ordinary
                    }
                    let source = MulticamSource(id: ProjectIdentifier.make(), file: file.path,
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
                    for draft in drafts { self.indexedByURL[draft.media.url] = draft.media }
                    self.prepareImportedSources(startAutomatically: startAutomatically)
                } else if errors.isEmpty {
                    errors.append("Select at least one camera recording.")
                }
                if !errors.isEmpty { self.fail(errors.joined(separator: "\n")) }
            })
        }
    }

    /// Source setup can stay on screen while the user chooses an opening camera.
    /// A crash here should still recover the recordings they already added.
    private func prepareImportedSources(startAutomatically: Bool) {
        guard project == nil, let first = setup.first(where: { $0.media.hasVideo }) else { return }
        let choice = first.media.audio.isEmpty ? setup.first(where: { !$0.media.audio.isEmpty }) : first
        let audio: MulticamAudioPolicy
        if let choice, let track = choice.media.audio.first {
            audio = .fixed(.init(source: choice.id, stream: track.stream.index))
        } else { audio = .none }
        if startAutomatically {
            confirmSetup(drafts: setup, opening: first.id, audio: audio)
        } else {
            updatePendingSetup(setup, opening: first.id, audio: audio)
        }
    }

    func updatePendingSetup(_ drafts: [SourceDraft], opening: String, audio: MulticamAudioPolicy,
                            fixedAudio: MulticamAudioSelection? = nil) {
        guard !setup.isEmpty, Set(drafts.map(\.id)) == Set(setup.map(\.id)) else { return }
        if setup.map(\.source) != drafts.map(\.source) { setup = drafts }
        guard project == nil else { return }
        let drafts = Self.normalizedNames(in: drafts)
        guard let reference = drafts.first(where: { $0.id == opening && $0.media.hasVideo }) else { return }
        let duration = indexedByURL[reference.media.url]?.duration ?? reference.media.duration
        writePendingSetup(Self.initialProject(drafts: drafts, opening: reference, duration: duration, audio: audio,
                                              fixedAudio: fixedAudio))
    }

    private func writePendingSetup(_ pending: MulticamProject) {
        guard pending != pendingSetupProject else { return }
        pendingSetupProject = pending
        do { try draft.write { _ = try Self.writeDocument(pending, undo: [], redo: [], mediaSnapshot: .init(), to: $0) } }
        catch { draftFailed(error) }
    }

    private static func initialProject(drafts: [SourceDraft], opening: SourceDraft, duration: RationalTime,
                                       audio: MulticamAudioPolicy, fixedAudio: MulticamAudioSelection?) -> MulticamProject {
        var project = MulticamProject(referenceAngle: opening.id, range: .init(from: .zero, to: duration),
                                      angles: drafts.filter { $0.media.hasVideo }.map(\.source),
                                      audioSources: drafts.filter { !$0.media.hasVideo }.map(\.source), audio: audio,
                                      switches: [.init(at: .zero, angle: opening.id)])
        if audio == .mix { project.mixLanes = project.defaultMixLanes }
        if let fixedAudio, project.sources.contains(where: { $0.id == fixedAudio.source }),
           project.fixedAudio == nil {
            project.fixedAudio = fixedAudio
        }
        return project
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

    func confirmSetup(drafts: [SourceDraft], opening: String, audio: MulticamAudioPolicy,
                      fixedAudio: MulticamAudioSelection? = nil, ifCurrent id: UUID? = nil) {
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
                                                audio: audio, fixedAudio: fixedAudio)
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
        preferences.recentFiles.record(drafts.map { $0.media.url })
        dismissSetup()
        requestAutomaticScans(for: Set(drafts.map(\.id)))
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
                     allowCommit: (() -> Bool)? = nil, openingConversionHistory: Bool = false,
                     onConversionHistory: (([CutHistoryState]) -> Void)? = nil) {
        guard !isBusy, confirmClose() else { return }
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let claim: ProjectDraft.Reservation?
        do { claim = openingConversionHistory ? nil : try reservation ?? draft.reserveIfRecoverable(url) }
        catch { fail(error.localizedDescription); return }
        openingProjectURL = url
        let limit = preferences.historyLimit
        run("Opening multicam project…") { _, _ in
            let project: MulticamProject
            let states: (undo: [CutHistoryState], redo: [CutHistoryState])
            let savedMedia: CutProjectMedia?
            if let document, let history, archiveMedia != nil || openingConversionHistory {
                project = document
                states = history
                savedMedia = archiveMedia
            } else {
                let file = try CutProject.loadEditorDocument(from: url, limit: limit)
                guard case .multicam(let multicam) = file.project else {
                    throw CutError(code: "invalid_multicam_project", message: "Expected a multicam project.")
                }
                project = multicam
                states = (file.undo, file.redo)
                savedMedia = file.media
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
                return HistoryEntry(action: state.action, origin: state.origin, project: absolute(prior),
                                    bindingChanges: state.bindingChanges?.map { change in change.mappingPaths { CutProject.mediaURL($0, relativeTo: url).path } } ?? [])
            }
            let localUndo = states.undo.reversed().prefix { $0.project.timelineOutputClock == .assembly }.reversed()
            let conversion = states.undo.dropLast(localUndo.count).map { state in
                func path(_ file: String) -> String { CutProject.mediaURL(file, relativeTo: url).path }
                return CutHistoryState(action: state.action, origin: state.origin, project: state.project.mapMediaPaths(path),
                                       bindingChanges: state.bindingChanges?.map { $0.mappingPaths(path) })
            }
            return try (absolute(project), localUndo.map(entry), states.redo.map(entry),
                        savedMedia?.absoluteSources(relativeTo: url) ?? [:], savedMedia?.diskRevision,
                        savedMedia?.mediaSnapshot.mappingPaths { CutProject.mediaURL($0, relativeTo: url).path } ?? .empty,
                        conversion)
        } onSuccess: { result in
            guard allowCommit?() != false else { return }
            let recovered = self.draft.adopt(claim)
            if !recovered { self.draft.discard() }
            self.stopSourceLoads()
            self.savedMediaPaths = result.3
            self.install(project: result.0, media: [:], issues: [:], url: recovered ? nil : url)
            self.projectDiskRevision = recovered ? nil : result.4
            self.mediaSnapshot = result.5
            self.undoStack = result.1
            self.redoStack = result.2
            self.savedHistoryCursor = self.historyCursor
            self.unopenedConversionUndo = result.6
            onConversionHistory?(result.6)
            self.trimHistoryAndUpdateDraft()
            self.reconcileSourceLoads()
        }
    }

    func chooseAdditionalRecording(for angle: String) {
        let panel = NSOpenPanel()
        panel.title = "Add Recording to Camera"
        ProjectPanels.present(panel, in: window) { [weak self] accepted in
            guard let self, accepted, let url = panel.url, let project = self.project else { return }
            let start = project.recordings(for: angle).compactMap { source in
                source.coverage?.to ?? self.media[source.id].flatMap { try? source.offset.adding($0.duration) }
            }.max()
            guard let start, let window = self.window else { self.fail("Load the camera before adding another recording."); return }
            let alert = NSAlert()
            alert.messageText = "Place Camera Recording"
            alert.informativeText = "Enter the group time of the first picture in seconds."
            let field = NSTextField(string: start.description)
            field.frame = NSRect(x: 0, y: 0, width: 210, height: 24)
            field.setAccessibilityLabel("Group start")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Add Recording")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task { @MainActor in
                    do {
                        let groupStart = try RationalTime(parsing: field.stringValue)
                        _ = try await self.addRecording(to: angle, from: url, at: groupStart)
                    } catch is CancellationError { }
                    catch { self.fail(error.localizedDescription) }
                }
            }
        }
    }

    func addRecording(to angle: String, from url: URL, at start: RationalTime,
                      validateCommit: () throws -> Void = {}) async throws -> String {
        guard !isBusy, let project, let primary = project.angles.first(where: { $0.id == angle }) else {
            throw CutError(code: "invalid_multicam_project", message: "Choose an available camera angle.")
        }
        let revision = mcpRevision
        let generation = mcpGeneration
        let firstURL = Self.availableURL(primary)
        let useSidecar = usesSidecar(for: url)
        let cancellation = EditCancellation()
        let work = sidecarWork.detached(priority: .userInitiated) {
            let engine = CutEngine(cancelled: { cancellation.isCancelled }, useSidecar: useSidecar)
            let primaryMedia = try primary.coverage == nil ? firstURL.map(engine.inspectMulticamSource) : nil
            let ordinary = try engine.inspect(url, keyframes: true)
            return (try engine.multicamClock(ordinary), ordinary, primaryMedia)
        }
        let (info, ordinary, first) = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        try validateCommit()
        guard !isBusy, mcpRevision == revision, mcpGeneration == generation else {
            throw MCPCommandError("stale_revision", "The multicam project changed while the recording was read.")
        }
        var candidate = project
        let id = ProjectIdentifier.make(avoiding: candidate.sources.map(\.id))
        try candidate.addRecording(id: id, media: info, to: angle, at: start, primaryMedia: first)
        cacheIndexedSource(info, ordinary: ordinary)
        guard edit("Add Camera Recording", { $0 = candidate }) else {
            throw CutError(code: "invalid_multicam_project", message: "The camera recording could not be added.")
        }
        preferences.recentFiles.record([url])
        requestAutomaticScans(for: [id])
        return id
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
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await relink(id, to: url, validateCommit: {}) }
            catch is CancellationError {}
            catch { fail(error.localizedDescription) }
        }
    }

    func relink(_ id: String, to url: URL,
                validateCommit: @escaping @MainActor () throws -> Void) async throws
        -> (revision: Int, changed: Bool, historyRetained: Bool, warning: String?) {
        guard let source = project?.sources.first(where: { $0.id == id }) else {
            throw CutError(code: "missing_source", message: "The multicam source is no longer available.")
        }
        let changed = try await relinkProjectMedia(from: source.file, to: url, validateCommit: validateCommit)
        return (mcpRevision, changed, false, nil)
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
    func saveProject(to destination: URL, flushDraftAnalysis: Bool = true) -> Bool {
        guard project != nil, !isBusy else { return false }
        do {
            try writeProject(to: destination, flushDraftAnalysis: flushDraftAnalysis)
            return true
        } catch let error as CutError where error.code == "project_draft_destination" {
            fail(error.localizedDescription)
            return false
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    private var transcriptPauseCache = TranscriptPauseProtectionCache()

    func transcriptProtectedGroupPauses() -> [AudioSpan] {
        guard let project else { return [] }
        let context = projectURL ?? draft.url
        let protections = transcriptPauseCache.resolve(project.transcripts, relativeTo: context)
        guard !protections.isEmpty else { return [] }
        return (try? protections.group(project: project,
                                       sourceFingerprints: media.mapValues { $0.identity.transcriptFingerprint })) ?? []
    }

    var transcriptState: ProjectTranscripts { project?.transcripts ?? .init() }

    func transcriptAssetContext() throws -> URL {
        if let url = projectURL ?? draft.url { return url }
        guard let project else { throw CutError(code: "missing_project", message: "The project is unavailable.") }
        let snapshot = projectMediaSnapshotForWriting
        try draft.write { _ = try Self.writeDocument(project, undo: undoStack, redo: redoStack, mediaSnapshot: snapshot, to: $0,
                                                 checkingVolumes: interchangeCheckingVolumes, conversionUndo: conversionUndo) }
        guard let url = draft.url else { throw CutError(code: "missing_project", message: "The project is unavailable.") }
        return url
    }

    func setTranscriptState(_ proposed: ProjectTranscripts, action: String? = nil) throws {
        guard var project else { throw CutError(code: "missing_project", message: "The project is unavailable.") }
        let previous = project
        var next = proposed
        next.revision = project.transcripts.revision
        guard next != project.transcripts else { return }
        try next.advanceRevision()
        try next.validate()
        if let action {
            undoStack.append(HistoryEntry(action: action, project: previous, selection: selection))
            redoStack.removeAll()
            _ = trimHistory()
            historyRevision += 1
        }
        project.transcripts = next
        self.project = project
        reconcileSourceLoads()
        updateDraft()
    }

    func writeProject(to destination: URL, replacingExisting: Bool = true, flushDraftAnalysis: Bool = true) throws {
        if interchangeCheckingVolumes.contains(ProjectMediaVolume.key(for: destination)) {
            throw CutError(code: "media_volume_checking", message: "The destination volume is still checking: \(destination.path)")
        }
        guard var project, !isBusy else {
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
        let expected = projectDiskRevision.flatMap { $0.matchesDestination(url) ? $0 : nil }
        let saved = try Self.writeDocument(project, undo: undoStack, redo: redoStack, mediaSnapshot: projectMediaSnapshotForWriting,
                                   to: url, checkingVolumes: interchangeCheckingVolumes, replacingExisting: replacingExisting,
                                   coordinate: true, expected: expected,
                                   conversionUndo: conversionUndo)
        projectDiskRevision = saved.revision
        project.transcripts.attachments = saved.attachments
        let flush = flushDraftAnalysis && projectURL == nil && useAnalysisSidecars && SidecarLocations.mode == .project
        projectURL = url
        self.project = project
        savedProject = project
        savedMediaPaths = documentMediaPaths
        reconcileSourceLoads()
        savedHistoryRevision = historyRevision
        savedHistoryCursor = historyCursor
        draft.discard()
        status = "Saved \(url.lastPathComponent)"
        if flush { saveAnalysisSidecars(afterFirstProjectSave: true) }
    }

    private var documentMediaPaths: [String: String] {
        var paths: [String: String] = [:]
        func include(_ document: MulticamProject) {
            for (id, path) in document.analysisAnnotations.protectedPaths { paths[path] = id }
            for source in document.pictureSources { paths[source.file] = source.id }
            for source in document.audioSources { paths[source.file] = source.id }
            for asset in document.stillAssets where !asset.isGap { paths[asset.file] = asset.id }
            for record in document.transcripts.authoring {
                for anchor in record.anchors + [record.speakerReference].compactMap({ $0 }) {
                    if let file = anchor.binding.file { paths[file] = record.id }
                }
            }
            for attachment in document.transcripts.attachments {
                for binding in attachment.bindings {
                    if let file = binding.file { paths[file] = attachment.id }
                }
            }
        }
        if let project { include(project) }
        for entry in undoStack { include(entry.project) }
        for entry in redoStack { include(entry.project) }
        for state in conversionUndo {
            for (id, path) in state.project.mediaPaths { paths[path] = id }
        }
        return paths
    }

    var protectedMediaPaths: [String: String] {
        var paths = savedMediaPaths.merging(documentMediaPaths) { _, current in current }
        for entry in queuedRanges {
            for source in entry.project.sources { paths[source.file] = source.id }
            for asset in CutProject.multicam(entry.project).stillAssets { paths[asset.file] = asset.id }
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
        let excluded = ProjectMediaVolume.$checking.withValue(interchangeCheckingVolumes) {
            CutProject.sidecarExclusions(absoluteSources: paths,
                candidates: references.map { URL(fileURLWithPath: $0, isDirectory: false) }, projectURL: sidecarWork.project)
        }
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
        try ProjectMediaVolume.$checking.withValue(interchangeCheckingVolumes) {
            try CutProject.validateMediaDestination(output, absoluteSources: protectedMediaPaths, includesContents: includesContents)
        }
    }

    @discardableResult
    nonisolated private static func writeDocument(_ project: MulticamProject, undo: [HistoryEntry],
                                                  redo: [HistoryEntry], mediaSnapshot: ProjectMediaSnapshot, to url: URL,
                                                  checkingVolumes: Set<String> = [], replacingExisting: Bool = true,
                                                  coordinate: Bool = false,
                                                  expected: ProjectDiskRevision? = nil,
                                                  conversionUndo: [CutHistoryState] = []) throws
        -> (revision: ProjectDiskRevision?, attachments: [TranscriptAttachment]) {
        try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
            var paths: [String: String] = [:]
            func document(_ value: MulticamProject) -> CutProject {
                .multicam(Self.mapSourcePaths(in: value, cache: &paths) { CutProject.relativeMediaPath($0, to: url) })
            }
            func state(_ entry: HistoryEntry) -> CutHistoryState {
                CutHistoryState(action: entry.action, origin: entry.origin, project: document(entry.project),
                                bindingChanges: entry.bindingChanges.map { change in
                                    change.mappingPaths { CutProject.relativeMediaPath($0, to: url) }
                                })
            }
            let current = document(project)
            func relative(_ file: String) -> String { CutProject.relativeMediaPath(file, to: url) }
            let converted = conversionUndo.map { state in
                CutHistoryState(action: state.action, origin: state.origin, project: state.project.mapMediaPaths(relative),
                                bindingChanges: state.bindingChanges?.map { $0.mappingPaths(relative) })
            }
            let undo = converted + undo.map(state), redo = redo.map(state)
            let snapshot = mediaSnapshot.mappingPaths { CutProject.relativeMediaPath($0, to: url) }
            if coordinate {
                let revision = try current.saveRevision(to: url, undo: undo, redo: redo, mediaSnapshot: snapshot,
                                                        replacingExisting: replacingExisting, expected: expected)
                return (revision, project.transcripts.attachments)
            }
            try current.saveStaged(to: url, undo: undo, redo: redo, mediaSnapshot: snapshot, replacingExisting: replacingExisting)
            return (nil, project.transcripts.attachments)
        }
    }

    /// All states use the document's directory. Resolve each distinct media path once per read or write.
    nonisolated private static func mapSourcePaths(in project: MulticamProject, cache: inout [String: String],
                                                  transform: (String) -> String) -> MulticamProject {
        func path(_ file: String) -> String {
            if let mapped = cache[file] { return mapped }
            let mapped = transform(file)
            cache[file] = mapped
            return mapped
        }
        var copy = project
        copy.analysisAnnotations = project.analysisAnnotations.mappingPaths(path)
        copy.transcripts = project.transcripts.mapSourcePaths(path)
        for index in project.participants.pendingReviews.indices {
            copy.participants.pendingReviews[index].file = path(project.participants.pendingReviews[index].file)
        }
        copy.angles = project.angles.map { $0.mappingFiles(path) }
        copy.audioSources = project.audioSources.map { $0.mappingFiles(path) }
        copy.stillAssets = project.stillAssets.map { asset in
            guard !asset.isGap else { return asset }
            var copy = asset
            copy.file = path(asset.file)
            return copy
        }
        return copy
    }

    private func updateDraft() {
        guard projectURL == nil, let project else { return }
        let undo = undoStack
        let redo = redoStack
        let snapshot = projectMediaSnapshotForWriting
        let checkingVolumes = interchangeCheckingVolumes
        let conversionUndo = self.conversionUndo
        let save: @Sendable (URL) throws -> Void = { url in
            _ = try Self.writeDocument(project, undo: undo, redo: redo, mediaSnapshot: snapshot, to: url,
                                       checkingVolumes: checkingVolumes, conversionUndo: conversionUndo)
        }
        func records(in value: MulticamProject) -> Int {
            value.angles.count + value.audioSources.count + value.switches.count + (value.assemblyItems?.count ?? 0)
                + value.stillAssets.count + value.stillReplacements.count
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
            alert.informativeText = "Choose the opening camera in the next step, then save the project."
            alert.addButton(withTitle: "Continue Setup").toolTip = "Keep setup open"
            let discard = alert.addButton(withTitle: "Discard")
            discard.hasDestructiveAction = true
            discard.toolTip = "Discard multicam setup"
            return alert.runModal() == .alertSecondButtonReturn
        }
        alert.messageText = "Save changes to \(projectURL?.lastPathComponent ?? "Untitled Multicam")?"
        alert.addButton(withTitle: "Save").toolTip = "Save project changes"
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        discard.toolTip = "Close without saving"
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        cancel.toolTip = "Keep project open"
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
        let snapshot = projectMediaSnapshotForWriting
        let checkingVolumes = interchangeCheckingVolumes
        let conversionUndo = self.conversionUndo
        let save: @Sendable (URL) throws -> Void = { url in
            _ = try Self.writeDocument(project, undo: undo, redo: redo, mediaSnapshot: snapshot, to: url,
                                       checkingVolumes: checkingVolumes, conversionUndo: conversionUndo)
        }
        do {
            try draft.write(save)
        } catch { draftFailed(error) }
    }

    func reset() {
        projectMediaJobs.reset()
        projectMediaRequest = nil
        mediaRefresh.reset()
        mediaRefreshProgress = nil
        mediaRefreshWarnings = [:]
        refreshReviewStreams = [:]
        refreshReviewPicture = []
        refreshReviewReasons = [:]
        refreshBaselines = [:]
        invalidatedQueueIDs = []
        mediaWatcher?.stop()
        mediaWatcher = nil
        mcpSidecarReceipt?.finish("cancelled")
        mcpSidecarReceipt = nil
        mcpGeneration = UUID()
        lastEditAction = nil
        openingProjectURL = nil
        timelineZoom = 0
        timeEntryRequest = 0
        resetExportQueue()
        isReplacementAudioPresented = false
        trackReplacementTarget = nil
        if !isFlushingDraftSidecars { cancel() }
        isFlushingDraftSidecars = false
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
        mediaSnapshot = .init()
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
        projectDiskRevision = nil
        undoStack = []
        redoStack = []
        unopenedConversionUndo = []
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

    func installFeedAngleConversion(_ converted: MulticamProject, from editor: EditorModel,
                                    archive: LiveProjectMediaArchive, action: String) throws {
        _ = try converted.plan()
        _ = try converted.groupIntervals()
        reset()
        // The multicam loader aligns delayed movies off the main thread before they enter this cache.
        let media = Dictionary(editor.interchangeIndexedMedia.filter { $0.multicamSourceOffset == .zero }
            .map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        install(project: converted, media: converted.sources.reduce(into: [:]) { indexed, source in
            indexed[source.id] = media[source.file]
        }, issues: [:], url: editor.projectURL)
        projectDiskRevision = editor.feedAngleDiskRevision
        mediaSnapshot = archive.snapshot
        savedProject = nil
        lastEditAction = action
        mcpRevision = editor.mcpRevision + 1
        editor.draft.move(to: draft)
        reconcileSourceLoads()
        setAssemblyPreview(true)
    }

    func saveFeedAngleDraft() { updateDraft() }

    private func install(project: MulticamProject, media: [String: MediaInfo], issues: [String: String], url: URL?) {
        mcpGeneration = UUID()
        lastEditAction = nil
        resetExportQueue()
        analysis.reset()
        pauseEdits.reset()
        preview.pause()
        provisionalGroupRange = nil
        self.project = project
        mediaSnapshot = .init()
        self.media = media.mapValues(filmstrip.sidecarPreference.attachingDocument)
        sourceIssues = issues
        indexedByURL = Dictionary(grouping: media.values, by: \.url).compactMapValues(\.first)
        issuesByPath = Dictionary(grouping: project.sources, by: \.file)
            .compactMapValues { entries in entries.compactMap { issues[$0.id] }.first }
        projectURL = url
        projectDiskRevision = nil
        savedProject = url == nil ? nil : project
        setup = []
        pendingSetupProject = nil
        undoStack = []
        redoStack = []
        unopenedConversionUndo = []
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
    func edit(_ action: String? = nil, _ change: (inout MulticamProject) throws -> Void) -> Bool {
        guard !isBusy, let project else { return false }
        var next = project
        do {
            try change(&next)
            next.syncFeedAngleRecordings()
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
        tierGate.edited(self, from: project)
        updateDraft()
        return true
    }

    private static func editName(from previous: MulticamProject, to next: MulticamProject) -> String {
        if previous.range != next.range { return "Change Group Range" }
        if previous.audio != next.audio { return "Change Program Audio" }
        if previous.assemblyItems != next.assemblyItems { return "Edit Assembly" }
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
        var bindingChanges: [[TranscriptBindingChange]] = []
        while index != undo.count {
            let entry = backwards ? undo.removeLast() : redo.removeLast()
            bindingChanges.append(entry.bindingChanges)
            let inverse = HistoryEntry(action: entry.action, origin: entry.origin, project: target, selection: restored,
                                       bindingChanges: entry.bindingChanges.map(\.reversed))
            if backwards { redo.append(inverse) } else { undo.append(inverse) }
            target = entry.project
            restored = entry.selection
        }
        var transcripts = project.transcripts
        let changesBindings = bindingChanges.reduce(false) { changed, transitions in
            TranscriptBindingChange.apply(transitions, to: &transcripts) || changed
        }
        if transcripts.authoring != target.transcripts.authoring || changesBindings {
            transcripts.authoring = target.transcripts.authoring
            transcripts.revision = project.transcripts.revision
            do { try transcripts.advanceRevision() } catch { fail(error.localizedDescription); return }
        }
        target.transcripts = transcripts
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
        let occurrence = min(max(0, selection.occurrence), max(0, assemblyItems.count - 1))
        if selectedSwitch != marker { selectedSwitch = marker }
        if selectedOccurrence != occurrence { selectedOccurrence = occurrence }
        if editSelection != selection.scope { editSelection = selection.scope }
        if markIn != selection.markIn { markIn = selection.markIn }
        if markOut != selection.markOut { markOut = selection.markOut }
        if assemblySelection != selection.assemblyRange { assemblySelection = selection.assemblyRange }
    }

    private func apply(_ next: MulticamProject) {
        let sourcesChanged = project?.sources.map(\.file) != next.sources.map(\.file)
        if sourcesChanged {
            let previous = Dictionary(uniqueKeysWithValues: (project?.sources ?? []).map { ($0.id, $0.file) })
            for source in next.sources where previous[source.id] != source.file {
                refreshReviewReasons[source.id] = nil
                mediaRefreshWarnings[source.id] = nil
            }
        }
        project = next
        if sourcesChanged { pruneMediaCache() }
        reconcileSourceLoads()
        suggestions = []
        suggestionAnchor = nil
        selectedOccurrence = min(selectedOccurrence, max(0, assemblyItems.count - 1))
        if let selectedSwitch, !next.switches.contains(where: { $0.at == selectedSwitch }) {
            self.selectedSwitch = nil
        }
    }

    private func updateMedia(for project: MulticamProject, force: Bool = false) {
        let cameras = Set(project.pictureSources.map(\.id))
        let updated = Dictionary(uniqueKeysWithValues: project.sources.compactMap { source -> (String, MediaInfo)? in
            guard let url = Self.availableURL(source),
                  mediaWatcher?.status(for: url) != .offline, mediaWatcher?.status(for: url) != .checking,
                  let info = indexedByURL[url],
                  (cameras.contains(source.id) ? info.hasVideo : !info.audio.isEmpty) else { return nil }
            return (source.id, filmstrip.sidecarPreference.attachingDocument(to: info))
        })
        if media.mapValues(\.url) != updated.mapValues(\.url) ||
            media.mapValues(\.identity) != updated.mapValues(\.identity) ||
            media.mapValues(\.hasFullEditIndex) != updated.mapValues(\.hasFullEditIndex) || force { media = updated }
        let issues = Dictionary(uniqueKeysWithValues: project.sources.compactMap { source -> (String, String)? in
            guard let url = Self.availableURL(source) else {
                return (source.id, "A parent folder in the recording path is unavailable.")
            }
            switch mediaWatcher?.status(for: url) {
            case .offline: return (source.id, "Recording is offline.")
            case .checking: return (source.id, "Checking volume…")
            default: break
            }
            if updated[source.id] != nil { return nil }
            if indexedByURL[url] != nil {
                return (source.id, "The recording does not match the source type.")
            }
            return issuesByPath[source.file].map { (source.id, $0) }
        })
        if issues != sourceIssues { sourceIssues = issues }
        refreshPreview()
    }

    nonisolated static func availableURL(_ source: MulticamSource) -> URL? {
        guard !source.file.split(separator: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: source.file).standardizedFileURL
    }

    private func stopSourceLoads() {
        sourceProgressUpdate?.cancel()
        sourceProgressUpdate = nil
        for load in sourceLoads.values { load.cancel() }
        sourceLoads.removeAll()
        sourceIndexProgress = [:]
        sourceIndexIssues = [:]
        indexIssuesByURL = [:]
        ordinaryByURL = [:]
    }

    func reconcileSourceLoads() {
        updateMediaWatcher()
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
            guard header?.hasFullEditIndex != true,
                  mediaWatcher?.status(for: url) != .offline, mediaWatcher?.status(for: url) != .checking else { continue }
            let id = UUID()
            let proofs = project?.analysisAnnotations.evidence(for: url.path) ?? []
            let key = SourceIndexLoader.Key(url: url, sidecars: usesSidecar(for: url), preview: header == nil && proofs.isEmpty,
                                            identity: header?.identity, project: sidecarWork.project)
            let cancel = SourceIndexLoader.shared.admit(key, progress: { [weak self] fraction in
                guard let self, let load = self.sourceLoads[url], load.id == id, fraction > load.progress else { return }
                self.sourceLoads[url]?.progress = fraction
                self.scheduleSourceProgressUpdate()
            }) { [weak self] result in
                guard let self, self.sourceLoads[url]?.id == id else { return }
                if case .success(let index) = result, !proofs.isEmpty {
                    Task {
                        await Task.detached(priority: .utility) {
                            for proof in proofs { _ = proof.matches(index.ordinary) }
                        }.value
                        guard self.sourceLoads[url]?.id == id else { return }
                        self.finishSourceLoad(result, url: url, preview: key.preview)
                    }
                } else {
                    self.finishSourceLoad(result, url: url, preview: key.preview)
                }
            }
            sourceLoads[url] = SourceLoad(id: id, cancel: cancel)
        }
        if let project { updateMedia(for: project) }
        publishSourceProgress()
    }

    private func finishSourceLoad(_ result: Result<SourceIndexLoader.MulticamIndex, Error>, url: URL, preview: Bool) {
        sourceLoads[url] = nil
        switch result {
        case .success(let index):
            indexedByURL[url] = index.multicam
            if index.ordinary.hasFullEditIndex {
                if index.multicam.multicamClockOffset != .zero { ordinaryByURL[url] = index.ordinary }
                updateProvisionalGroupRange(using: index.multicam)
            }
        case .failure(let error):
            if preview { issuesByPath[url.path] = error.localizedDescription }
            else { indexIssuesByURL[url] = error.localizedDescription }
        }
        reconcileSourceLoads()
    }

    func latestSourceIndexProgress(_ source: MulticamSource) -> Double? {
        guard let url = Self.availableURL(source) else { return nil }
        return sourceLoads[url]?.progress
    }

    private func scheduleSourceProgressUpdate() {
        guard sourceProgressUpdate == nil else { return }
        // Multiple sources can advance between UI updates. Keep their latest fractions.
        sourceProgressUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.sourceProgressUpdate = nil
            self.publishSourceProgress()
        }
    }

    private func publishSourceProgress() {
        sourceProgressUpdate?.cancel()
        sourceProgressUpdate = nil
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
        return ordinaryByURL[info.url].map(filmstrip.sidecarPreference.attachingDocument) ?? (info.multicamClockOffset == .zero ? info : nil)
    }

    @discardableResult
    func updateSource(_ id: String, _ change: (inout MulticamSource) -> Void) -> Bool {
        edit { try $0.updateSource(id, change) }
    }

    func renameSource(_ id: String, to text: String) {
        let action = project?.angles.first(where: { $0.id == id })?.feedAngle == nil ? nil : "Rename Feed"
        edit(action) { try $0.renameSource(id, to: text) }
    }

    var lastCameraGroupEnd: RationalTime? {
        project?.pictureSources.compactMap { source in
            if let coverage = source.coverage { return coverage.to }
            return media[source.id].flatMap { try? $0.duration.adding(source.offset) }
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
        guard let project, let source = project.sources.first(where: { $0.id == id && $0.feedAngle == nil }),
              let info = media[id] else { return nil }
        let clock = clock ?? currentGroupTime()
        guard let sampleTime = try? clock.subtracting(source.offset) else { return nil }
        let isAngle = project.pictureSources.contains(where: { $0.id == id })
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
            if project.audio == .mix {
                selection = project.mixLanes.lazy.compactMap { lane -> MulticamAudioSelection? in
                    guard case .recording(let route) = lane.target, route.source == id else { return nil }
                    return route
                }.first
            } else if let override = project.selection(at: clock)?.audio { selection = override }
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
        if let mapping {
            let resolved = (try? project.resolveAudioLanes(plan: mapping, indexedSources: media, unavailableAsGap: true)) ?? []
            let playableAudio = resolved.map { lane in
                var playable = lane
                playable.spans = lane.spans.filter { refreshIssue(for: $0) == nil }
                return playable
            }
            let playable = MulticamPlan(intervals: mapping.intervals,
                                        picture: mapping.picture.filter { refreshIssue(for: $0) == nil },
                                        audioLanes: playableAudio, duration: mapping.duration)
            preview.configure(plan: playable, media: media, project: stillPreviewProject, document: projectURL,
                              audioIsResolved: true)
        }
        refreshAnalysis()
    }

    private func refreshAnalysis() {
        guard let project else { return }
        let ordinary = Dictionary(uniqueKeysWithValues: media.keys.compactMap { id in
            ordinaryAnalysisMedia(id).map { (id, $0) }
        })
        analysis.update(project: project, media: media, ordinary: ordinary, useSidecars: useAnalysisSidecars,
                        excludedSources: sidecarExclusions, reviewStreams: refreshReviewStreams,
                        reviewPicture: refreshReviewPicture)
    }

    func interval(at output: RationalTime) -> MulticamInterval? {
        guard let mapping else { return nil }
        let index = mapping.intervals.lowerBound { $0.output.to > output }
        if mapping.intervals.indices.contains(index) {
            let interval = mapping.intervals[index]
            return interval.output.from <= output ? interval : nil
        }
        guard output == mapping.duration, mapping.intervals.last?.output.to == output else { return nil }
        return mapping.intervals.last
    }

    func groupTime(at output: RationalTime) -> RationalTime {
        guard let interval = interval(at: output) else {
            let prior = mapping?.intervals.last(where: { $0.output.to <= output })
            return prior?.group.to ?? mapping?.intervals.first?.group.from ?? project?.range.from ?? .zero
        }
        guard let delta = try? output.subtracting(interval.output.from),
              let group = try? interval.group.from.adding(delta) else { return .zero }
        return min(group, interval.group.to)
    }

    func currentGroupTime() -> RationalTime { groupTime(at: preview.currentTime()) }

    var activeOccurrenceIndex: Int { occurrenceIndex(at: preview.currentTime()) }

    func occurrenceIndex(at output: RationalTime) -> Int {
        guard assemblyPreview else { return selectedOccurrence }
        let index = assemblyRangeEnds.lowerBound { $0 > output }
        return min(index, max(0, assemblyItems.count - 1))
    }

    func skipMulticamPause(_ pauses: [MulticamPauseEdit]) {
        guard pauseEdits.skip, !isBusy, preview.playbackRate > 0, let mapping else { return }
        let position = preview.currentTime()
        let currentIndex = mapping.intervals.lowerBound { $0.output.to > position }
        guard mapping.intervals.indices.contains(currentIndex) else { return }
        let current = mapping.intervals[currentIndex]
        guard current.output.from <= position, let elapsed = try? position.subtracting(current.output.from),
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
        return mapping.intervals.last.flatMap { $0.group.to == group ? $0.output.to : nil }
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
        guard assemblyItems.indices.contains(index) else { return }
        focusAssemblyEdit()
        selectedOccurrence = index
        preview.pause()
        if assemblyPreview {
            preview.seek(to: assemblyStart(at: index))
        } else if let range = assemblyRange(at: index) {
            seekGroup(range.from)
        } else {
            setAssemblyPreview(true)
            selectedOccurrence = index
            preview.seek(to: assemblyStart(at: index))
        }
    }

    func audition(_ id: String) {
        let group = currentGroupTime()
        guard let source = project?.pictureSource(for: id, at: group), let info = media[source.id],
              let time = try? group.subtracting(source.offset) else { return }
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
        if assemblyPreview { selectedOccurrence = end ? assemblyItems.count - 1 : 0 }
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
        guard assemblyPreview, let mapping else {
            if let target = snappedFrame(time, delta: delta) { seekGroup(target) }
            return
        }

        let output = preview.time
        let index = occurrenceIndex(at: output)
        let angle = assemblyItems.indices.contains(index) ? assemblyItems[index].angleOverride : nil
        let target = snappedFrame(time, delta: delta, preferredAngle: angle)
        if let still = assemblyStill(at: index) {
            let start = assemblyStart(at: index)
            let end = assemblyRangeEnds[index]
            if output == end, delta < 0,
               let last = try? end.subtracting(still.cadence) {
                selectedOccurrence = index
                preview.seek(to: last)
                return
            }
            if let offset = try? output.subtracting(start),
               let frame = stillFrameBoundary(offset, cadence: still.cadence),
               let step = try? still.cadence.multiplied(by: RationalTime(numerator: Int64(delta), denominator: 1)),
               let next = try? start.adding(frame).adding(step), start <= next, next < end {
                selectedOccurrence = index
                preview.seek(to: next)
                return
            }
        } else if let range = assemblyRange(at: index), let target, target != time, range.contains(target) {
            seekOccurrence(index, group: target, mapping: mapping)
            return
        }
        let next = index + delta
        if delta > 0, assemblyItems.indices.contains(next) {
            selectedOccurrence = next
            preview.seek(to: assemblyStart(at: next))
        } else if let still = assemblyStill(at: next),
                  let last = try? assemblyRangeEnds[next].subtracting(still.cadence) {
            selectedOccurrence = next
            preview.seek(to: last)
        } else if let range = assemblyRange(at: next) {
            let angle = assemblyItems[next].angleOverride
            let last = snappedFrame(range.to, delta: -1, preferredAngle: angle) ?? range.from
            seekOccurrence(next, group: max(range.from, last), mapping: mapping)
        } else {
            preview.seek(to: delta > 0 ? mapping.duration : .zero)
        }
    }

    /// An assembly edit ahead of the playhead shifts output time. This puts the
    /// playhead back on the group time it showed inside the edited occurrence.
    func seekAssemblyOccurrence(_ index: Int, group: RationalTime) {
        guard assemblyPreview, let mapping, assemblyRange(at: index)?.contains(group) == true else { return }
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

    func snappedFrame(_ time: RationalTime, delta: Int, preferredAngle: String? = nil) -> RationalTime? {
        guard let project else { return nil }
        let active = project.selection(at: time)?.angle ?? project.switches.last?.angle
        var candidates: [RationalTime] = []
        let angles = preferredAngle.map { [$0] } ?? [project.referenceAngle, active].compactMap { $0 }
        for source in angles.flatMap({ project.recordings(for: $0) }) {
            if delta == 0, source.coverage?.contains(time) == false { continue }
            guard let frames = media[source.id]?.frames, let first = frames.first, let last = frames.last,
                  let sourceTime = try? time.subtracting(source.offset),
                  let physicalEnd = try? last.time.adding(last.duration) else { continue }
            var start = first.time, end = physicalEnd
            if let coverage = source.coverage {
                guard let lower = try? coverage.from.subtracting(source.offset),
                      let upper = try? coverage.to.subtracting(source.offset) else { continue }
                start = max(start, lower)
                end = min(end, upper)
            }
            guard start < end else { continue }
            let lastIndex = frames.lowerBound { $0.time >= end } - 1
            guard lastIndex >= 0 else { continue }
            if sourceTime < start || sourceTime > end || (sourceTime == end && delta >= 0) {
                let edge: RationalTime?
                if delta > 0, sourceTime < start { edge = start }
                else if delta < 0, sourceTime >= end { edge = max(start, frames[lastIndex].time) }
                else { edge = nil }
                if let edge, let group = try? edge.adding(source.offset), project.range.contains(group) {
                    candidates.append(group)
                }
                continue
            }
            let firstIndex = frameIndex(at: start, frames: frames)
            let index = min(lastIndex, frameIndex(at: sourceTime, frames: frames))
            let frameStart = max(start, frames[index].time)
            let adjustment = delta < 0 && frameStart < sourceTime ? 0 : delta
            let next = index + adjustment
            if source.coverage != nil, next < firstIndex || next > lastIndex { continue }
            let frame = next > lastIndex ? end : max(start, frames[max(firstIndex, next)].time)
            if let group = try? frame.adding(source.offset) {
                return min(project.range.to, max(project.range.from, group))
            }
        }
        return delta < 0 ? candidates.max() : candidates.min()
    }

    @discardableResult
    func takeCamera(number: Int) -> Bool {
        guard number > 0, let project, project.angles.indices.contains(number - 1),
              let group = editableGroupPlayhead else { return false }
        return take(project.angles[number - 1].id, at: group) != nil
    }

    private var editableGroupPlayhead: RationalTime? {
        let output = preview.currentTime()
        if assemblyPreview && assemblyStill(at: occurrenceIndex(at: output)) != nil { return nil }
        return groupTime(at: output)
    }

    func take(_ id: String) {
        guard let group = editableGroupPlayhead else { return }
        _ = take(id, at: group)
    }

    /// Both live camera buttons and explicit-time commands use native snapping and history.
    @discardableResult
    func take(_ id: String, at clock: RationalTime, snap: Bool = true) -> RationalTime? {
        guard let project, !isBusy, let at = snap ? proposedCameraTime(id, at: clock) : clock else { return nil }
        guard let updated = try? project.settingSwitch(at: at, angle: id) else { return nil }
        if edit("Take Camera", { $0 = updated }) {
            editSelection = .group
            selectedSwitch = at
            return at
        }
        return nil
    }

    private func proposedCameraTime(_ id: String, at clock: RationalTime) -> RationalTime? {
        guard let project, project.range.contains(clock), project.angles.contains(where: { $0.id == id }) else { return nil }
        let exact = project.switches.first { $0.at == clock }
        let at = exact?.at ?? snappedAnalysisTime(clock, excludingGroupEdges: true) ?? snappedFrame(clock, delta: 0) ?? clock
        return project.range.contains(at) ? at : nil
    }

    func cameraCoverage(_ id: String, at clock: RationalTime) throws -> MulticamSwitchCoverage {
        guard let project, let at = proposedCameraTime(id, at: clock) else {
            throw CutError(code: "invalid_target", message: "Choose a camera and a time inside the group.")
        }
        return try project.switchCoverage(at: at, angle: id, media: media) { span in
            refreshIssue(for: span, mayStartWithSilence: span.output.from == .zero) == nil
        }
    }

    func cameraCoverageAtPlayhead(_ id: String) throws -> MulticamSwitchCoverage {
        guard let group = editableGroupPlayhead else {
            throw CutError(code: "invalid_target", message: "Move the playhead to a camera recording.")
        }
        return try cameraCoverage(id, at: group)
    }

    @discardableResult
    func setOccurrenceAngle(_ index: Int, angle: String?) -> Bool {
        guard let project, let range = assemblyRange(at: index),
              angle.map({ id in project.angles.contains { $0.id == id } }) ?? true else { return false }
        guard assemblyItems[index].angleOverride != angle else { return true }
        if edit(angle == nil ? "Restore Group Picture" : "Override Occurrence Picture", { candidate in
            var items = candidate.assemblyItems ?? [.group(candidate.range)]
            items[index] = .group(range, angle: angle, id: items[index].occurrenceID, layouts: items[index].tileLayouts)
            if candidate.assemblyItems == nil {
                candidate.replaceAssembly(items, carryingPauseReviewsFrom: [0])
            } else {
                candidate.assemblyItems = items
            }
        }) {
            selectedOccurrence = index
            focusAssemblyEdit()
            return true
        }
        return false
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
            if project.assemblyItems == nil {
                project.materializeAssembly()
                project.assemblyItems = project.assemblyItems?.map { $0.trimmingGroup(to: range) }
            } else {
                project.assemblyItems?.append(.group(range))
            }
        }) {
            focusAssemblyEdit()
            selectedOccurrence = assemblyItems.count - 1
        }
    }

    func changeOccurrence(_ index: Int? = nil, from: RationalTime? = nil, to: RationalTime? = nil) {
        let index = index ?? selectedOccurrence
        if edit("Trim Assembly Range", { project in
            var items = project.assemblyItems ?? [.group(project.range)]
            guard items.indices.contains(index), let current = items[index].group else { return }
            let revised = MulticamRange(from: from ?? current.from, to: to ?? current.to)
            guard revised != current else { return }
            if project.assemblyItems == nil {
                project.replaceAssembly(items, carryingPauseReviewsFrom: [0])
                items = project.assemblyItems ?? items
            }
            items[index] = items[index].trimmingGroup(to: revised)
            project.assemblyItems = items
        }) {
            selectedOccurrence = index
            focusAssemblyEdit()
        }
    }

    func splitOccurrence() {
        if let (still, offset) = assemblyStillCut(at: preview.currentTime()) {
            if performStillEdit("Split Still", { try $0.splittingStill(id: still.id, at: offset) }) { splitRevision += 1 }
            return
        }
        guard let (index, at) = occurrenceCut else { return }
        commitOccurrenceSplit(index: index, at: at)
    }

    @discardableResult
    func commitOccurrenceSplit(index: Int, at: RationalTime) -> Bool {
        var splitItems = assemblyItems
        guard !isBusy, let current = assemblyRange(at: index) else { return false }
        guard current.from < at, at < current.to else { return false }
        let item = splitItems[index]
        splitItems.replaceSubrange(index...index, with: [
            item.groupPiece(.init(from: current.from, to: at), to: at),
            item.groupPiece(.init(from: at, to: current.to), from: at, keepingID: false)
        ])
        preview.pause()
        var origin = Array(assemblyItems.indices)
        origin.insert(index, at: index + 1)
        if edit("Split Assembly Range", { $0.replaceAssembly(splitItems, carryingPauseReviewsFrom: origin) }) {
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
        guard assemblyItems.indices.contains(index), !isBusy else { return }
        if !assemblyPreview { setAssemblyPreview(true) }
        selectOccurrence(index)
    }

    func assemblyKeyframePointerTarget(_ seconds: Double, tolerance: Double) -> Double {
        guard analysis.snapTarget == .keyframes, let output = timelineRationalTime(seconds) else { return seconds }
        let index = assemblyRangeEnds.lowerBound { $0.seconds > seconds }
        guard let range = assemblyRange(at: index) else { return seconds }
        let start = assemblyStart(at: index)
        guard start.seconds < seconds, let elapsed = try? output.subtracting(start),
              let group = try? range.from.adding(elapsed),
              let keyframe = snappedAnalysisTime(group, within: range, pictureAngle: assemblyItems[index].angleOverride),
              abs(keyframe.seconds - group.seconds) <= tolerance,
              let snapped = try? start.adding(keyframe.subtracting(range.from)) else { return seconds }
        return snapped.seconds
    }

    func seekAssemblyTimeline(_ seconds: Double, scrubbing: Bool) {
        if !assemblyPreview { setAssemblyPreview(true) }
        guard let mapping, assemblyPreview, let requested = timelineRationalTime(seconds) else { return }
        let index = assemblyRangeEnds.lowerBound { $0.seconds > seconds }
        let exactStart = assemblyStart(at: index)
        if seconds == exactStart.seconds {
            seekAssembly(at: exactStart, scrubbing: scrubbing)
            return
        }
        let first = mapping.intervals.lowerBound { $0.output.to.seconds > seconds }
        let cameraStart = mapping.intervals.indices.contains(first) ? mapping.intervals[first].output.from : nil
        let output = cameraStart.flatMap { $0.seconds == seconds ? $0 : nil }
            ?? min(mapping.duration, max(.zero, requested))
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
        guard let requested = timelineRationalTime(seconds) else { return nil }
        guard let range = assemblyRange(at: index) else {
            return trimAssemblyStill(index, edge: edge, localTime: requested, commit: commit)?.seconds
        }
        let original = edge == .start ? range.from : range.to
        let time = seconds == original.seconds ? original : requested
        return trimAssemblyOccurrence(index, edge: edge, time: time, commit: commit)?.seconds
    }

    func trimAssemblyOccurrence(_ index: Int, edge: TimelineEdge, time: RationalTime, commit: Bool) -> RationalTime? {
        guard let project, !isBusy, let range = assemblyRange(at: index) else { return nil }
        let original = edge == .start ? range.from : range.to
        let target = min(project.range.to, max(project.range.from, time))
        let result: RationalTime?
        if time == original {
            result = original
        } else if analysis.snapTarget == .keyframes {
            result = nearestAssemblyCopyEdge(target, edge: edge, range: range, project: project,
                                             angle: assemblyItems[index].angleOverride)
        } else {
            let angle = assemblyItems[index].angleOverride
            result = snappedAnalysisTime(target, pictureAngle: angle)
                ?? snappedFrame(target, delta: 0, preferredAngle: angle) ?? target
        }
        guard let result,
              project.range.from <= result, result <= project.range.to,
              edge == .start ? result < range.to : result > range.from else { return nil }
        guard commit, result != original else { return result }

        var updated = range
        if edge == .start { updated.from = result }
        else { updated.to = result }
        preview.pause()
        changeOccurrence(index, from: updated.from, to: updated.to)
        guard assemblyRange(at: index) == updated else { return nil }
        selectAssemblyOccurrence(index)
        return result
    }

    private func nearestAssemblyCopyEdge(_ target: RationalTime, edge: TimelineEdge, range: MulticamRange,
                                         project: MulticamProject, angle: String?) -> RationalTime? {
        var snapshot = project
        snapshot.assemblyItems = [.group(project.range, angle: angle)]
        guard let intervals = try? snapshot.plan().intervals else { return nil }
        var nearest: RationalTime?
        for interval in intervals {
            guard let id = interval.pictureSourceID,
                  let offset = project.pictureSources.first(where: { $0.id == id })?.offset,
                  let info = media[id], !info.frames.isEmpty,
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
        let current = assemblyItems
        guard !isBusy, current.indices.contains(index), (0...current.count).contains(slot) else { return }
        let destination = slot > index ? slot - 1 : slot
        guard destination != index else { return }
        var reordered = current
        let occurrence = reordered.remove(at: index)
        reordered.insert(occurrence, at: destination)
        preview.pause()
        if reordered != current {
            let action = occurrence.still == nil ? "Move Assembly Range" : "Move Still"
            guard edit(action, { $0.assemblyItems = reordered }) else { return }
        }
        selectAssemblyOccurrence(destination)
    }

    func moveOccurrence(_ delta: Int) {
        let index = selectedOccurrence
        let next = index + delta
        guard assemblyItems.indices.contains(index), assemblyItems.indices.contains(next), index != next else { return }
        let position = preview.currentTime()
        let offset = assemblyPreview && occurrenceIndex(at: position) == index
            ? (try? position.subtracting(assemblyStart(at: index))) : nil
        reorderAssemblyOccurrence(index, before: next > index ? next + 1 : next)
        if selectedOccurrence == next, let offset, let target = try? assemblyStart(at: next).adding(offset) {
            seekAssembly(at: target, scrubbing: false)
        }
    }

    func removeOccurrence() { removeOccurrence(selectedOccurrence) }

    func removeOccurrence(_ index: Int) {
        guard !isBusy, var assembly = project?.assemblyItems, assembly.indices.contains(index) else { return }
        if let still = assemblyStill(at: index) {
            performStillEdit("Delete Still") { try $0.removingStill(id: still.id) }
            return
        }
        assembly.remove(at: index)
        preview.pause()
        if edit("Delete Assembly Range", { $0.assemblyItems = assembly.isEmpty ? nil : assembly }) {
            selectOccurrence(min(index, assemblyItems.count - 1))
        }
    }

    func saveAnalysisSidecars() { saveAnalysisSidecars(afterFirstProjectSave: false) }

    private func saveAnalysisSidecars(afterFirstProjectSave: Bool) {
        guard canSaveSidecars else { return }
        if SidecarLocations.mode == .project, projectURL == nil {
            if let receipt = mcpSidecarReceipt {
                receipt.finish("failed", detail: ["error": "Save the project before saving analysis in its folder."])
                mcpSidecarReceipt = nil
            } else {
                let panel = makeSavePanel()
                ProjectPanels.present(panel, in: window) { [weak self] accepted in
                    guard let self, accepted, let url = panel.url, self.saveProject(to: url, flushDraftAnalysis: false) else { return }
                    self.saveAnalysisSidecars()
                }
            }
            return
        }
        let receipt = mcpSidecarReceipt
        let outputs = receipt.map { _ in MCPLiveOutputProgress() }
        let endWork = receipt?.cleanup.begin()
        var seen: Set<URL> = []
        let sources = media.keys.sorted().compactMap { id -> (MediaInfo, MediaInfo?, [FilmstripTile], MulticamAnalysisSnapshot)? in
            guard let info = media[id] else { return nil }
            if afterFirstProjectSave, !filmstrip.sidecarPreference.permits(info.url) { return nil }
            guard info.hasFullEditIndex, seen.insert(info.url).inserted else { return nil }
            let ordinary = ordinaryAnalysisMedia(id)
            let snapshot = ordinary.map { analysis.snapshot(for: $0) } ?? MulticamAnalysisSnapshot()
            return (info.pinningSidecarWrites(), ordinary, filmstrip.snapshot(for: info), snapshot)
        }
        guard !sources.isEmpty else { endWork?(); return }
        isFlushingDraftSidecars = afterFirstProjectSave
        let protected = protectedMediaPaths
        let checkpointRequests = Dictionary(grouping: analysis.sceneCheckpointRequests, by: { $0.media.identity })
        let sceneCache = analysis.sceneCache
        run("Saving analysis sidecars…", kind: "sidecars") { token, _ in
            let excluded = CutProject.sidecarExclusions(absoluteSources: protected, candidates: sources.map { $0.0.url })
            if let conflict = sources.first(where: { AnalysisSidecar.isExcluded($0.0.url, in: excluded) }) {
                throw CutError(code: "output_conflict", message: "The analysis file for ‘\(conflict.0.url.lastPathComponent)’ would overwrite media referenced by this project.")
            }
            let cancelled = { @Sendable in token.isCancelled }
            let engine = CutEngine(cancelled: cancelled)
            var checkpoints: [(String, SceneScanProgress)] = []
            for (index, source) in sources.enumerated() {
                let (info, ordinary, tiles, snapshot) = source
                if token.isCancelled { throw CancellationError() }
                // Share the ordinary source index with the single-source editor.
                // Multicam adds the authored MOV offset after reading that index.
                let indexed = try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                    try ordinary ?? engine.inspect(info.url, keyframes: true)
                }.inheritingSidecarContext(from: info)
                guard indexed.identity.matchesSnapshot(info.identity) else {
                    throw CutError(code: "source_changed", message: "Source \(info.url.lastPathComponent) changed. Relink it before saving its analysis.")
                }
                var sections = try AnalysisSidecar.indexSections(for: indexed, cancelled: cancelled)
                let analyzed = try snapshot.sections(for: indexed, cancelled: cancelled)
                sections.merge(analyzed) { _, analysis in analysis }
                if let video = info.videoStream {
                    for tile in tiles {
                        if token.isCancelled { throw CancellationError() }
                        sections[tile.key.section] = autoreleasepool {
                            tile.key.encoded(tile.image, preserveAlpha: video.hasAlpha || video.hasAdditionalVideoLayers)
                        }
                    }
                }
                let store = AnalysisSidecar(media: info)
                try store.save(sections, updating: [:],
                    retainingLatest: tiles.isEmpty ? [:] : [FilmstripTileKey.sectionPrefix: FilmstripTileBuffer.countLimit],
                    cancelled: cancelled)
                NotificationCenter.default.post(name: .analysisCutcacheDidSave, object: store.url)
                for item in checkpointRequests[indexed.identity] ?? [] {
                    if token.isCancelled { throw CancellationError() }
                    if let progress = try SceneAnalysis.saveCheckpoint(for: indexed, scope: item.scope, session: sceneCache) {
                        checkpoints.append((item.id, progress))
                    }
                }
                outputs?.published(store.url)
                outputs?.update(Double(index + 1) / Double(sources.count))
            }
            return (sources.count, checkpoints)
        } onFailure: { message in
            var detail = outputs?.snapshot ?? [:]
            detail["error"] = message
            receipt?.finish("failed", detail: detail)
            self.mcpSidecarReceipt = nil
            self.fail(message)
        } onSuccess: { result in
            let (count, checkpoints) = result
            for (id, progress) in checkpoints { self.analysis.didSaveSceneCheckpoint(id, progress: progress) }
            receipt?.finish("succeeded", detail: outputs?.snapshot ?? [:])
            self.mcpSidecarReceipt = nil
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

    func stillExportDocument(wholeGroup: Bool, selection: [MulticamRange]?) -> CutProject? {
        guard var snapshot = project else { return nil }
        if selection != nil, let span = assemblySelection {
            return (try? snapshot.assemblySelection(.init(from: span.from, to: span.to))).map(CutProject.multicam)
        }
        if let ranges = selection ?? (wholeGroup ? [snapshot.range] : nil) {
            if CutProject.multicam(snapshot).requiresPictureProcessing {
                return (try? snapshot.pictureExportSnapshot(ranges: ranges)).map(CutProject.multicam)
            }
            snapshot.assemblyItems = ranges.map { .group($0) }
        }
        return .multicam(snapshot)
    }

    func exportSourceIssue(tracks: ExportTracks, wholeGroup: Bool, mode: ExportMode = .copy,
                           settings: ReencodeSettings = .init(), selection: [MulticamRange]? = nil,
                           audioAction: ReencodeAudio? = nil) -> String? {
        guard let project else { return "Open a multicam project first." }
        if CutProject.multicam(project).requiresPictureProcessing {
            if mode != .encode, tracks != .audio || project.participants.render != nil {
                return ParticipantProjectExport.requiresEncoding.message
            }
            if stillExportDocument(wholeGroup: wholeGroup, selection: selection) == nil {
                return "Select a valid range to export."
            }
            return nil
        }
        if selection != nil, let span = assemblySelection {
            do { _ = try project.assemblySelection(.init(from: span.from, to: span.to)) }
            catch { return error.localizedDescription }
        } else if selection?.isEmpty == true { return "Select a range on the timeline to export." }
        do {
            guard case .multicam(let snapshot)? = stillExportDocument(wholeGroup: wholeGroup, selection: selection) else {
                return "Select a valid range to export."
            }
            let plan = try snapshot.plan()
            let needsAudio = tracks != .video && (audioAction ?? (mode == .encode ? settings.audio : .copyOriginal)) != .removeAudio
            let routedAudio = needsAudio
                ? try snapshot.resolveAudioLanes(plan: plan, indexedSources: [:], assumeUnindexedCoverage: true) : []
            if try CutProject.multicam(snapshot).exportPlacementScope() != .none {
                return refreshExportIssue(in: plan, tracks: tracks, mode: mode, settings: settings,
                                          audioAction: audioAction, routedAudio: routedAudio)
            }
            func issue(for span: MulticamSpan, mayStartWithSilence: Bool = false) -> String? {
                if let issue = refreshIssue(for: span, mayStartWithSilence: mayStartWithSilence) { return issue }
                guard media[span.source]?.hasFullEditIndex != true else { return nil }
                let name = project.sources.first(where: { $0.id == span.source })?.displayName ?? span.source
                let detail = sourceIssues[span.source] ?? sourceIndexIssues[span.source] ?? "The editing index is still loading."
                return "\(name) — \(detail)"
            }
            if tracks != .audio {
                for span in plan.picture {
                    if let issue = issue(for: span) { return issue }
                }
            }
            for lane in routedAudio {
                for (index, span) in lane.spans.enumerated() {
                    if let issue = issue(for: span, mayStartWithSilence: index == 0) {
                        return snapshot.audio == .mix ? "\(lane.label) — \(issue)" : issue
                    }
                }
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func applyStillExportBoundary(_ choice: StillBoundaryAdjustment) {
        guard let project, stillExportBoundaryChoices.contains(choice),
              stillExportBoundaryBaseline == .multicam(project) else { return }
        do {
            guard case .multicam(let changed) = try CutProject.multicam(project).applyingStillBoundary(choice) else { return }
            if edit("Adjust Still Boundary", { $0 = changed }) {
                stillExportBoundaryChoices = []
                stillExportBoundaryBaseline = nil
            }
        } catch { fail(error.localizedDescription) }
    }

    func export(output: URL, mode: ExportMode, tracks: ExportTracks, dryRun: Bool, wholeGroup: Bool,
                settings: ReencodeSettings = .init(), selection: [MulticamRange]? = nil,
                requireCameraCopy: Bool = false, saveResult: Bool = false,
                audioOutput: MulticamAudioOutput = .separateTracks, audioAction: ReencodeAudio? = nil,
                pictureTiming: StillPictureTiming? = nil,
                reviewed: ((String) -> Void)? = nil, checked: (() -> Void)? = nil) {
        guard let project, !isBusy else { return }
        preview.pause()
        report = nil
        exportDeliverySummary = nil
        suggestions = []
        suggestionAnchor = nil
        edgeSuggestion = nil
        exportAlternatives = []
        stillExportBoundaryChoices = []
        stillExportBoundaryBaseline = nil
        requestedExportMode = mode
        let ranges = selection ?? (wholeGroup ? [project.range] : nil)
        let stillDocument = stillExportDocument(wholeGroup: wholeGroup, selection: selection)
        if stillDocument == .multicam(project) { stillExportBoundaryBaseline = stillDocument }
        // The engine numbers a range edge within what it was given: the saved assembly when no ranges are passed.
        defer { exportsSavedAssembly = ranges == nil && isBusy }
        let indexedSources = media.filter { $0.value.hasFullEditIndex }
        if let issue = exportSourceIssue(tracks: tracks, wholeGroup: wholeGroup, mode: mode, settings: settings,
                                         selection: selection, audioAction: audioAction) {
            fail(issue)
            return
        }
        let update: @Sendable (EditCancellation, Double) -> Void = { [weak self] token, fraction in
            Task { @MainActor [weak self] in
                self?.updateExportProgress(token, fraction: fraction)
            }
        }
        let protected = protectedMediaPaths
        let documentURL = projectURL
        run(dryRun ? "Checking multicam export…" : "Exporting multicam program…", exporting: !dryRun) { token, useSidecar in
            try CutProject.validateMediaDestination(output, absoluteSources: protected)
            if saveResult && !dryRun {
                try CutProject.validateMediaDestination(ExportResultFile.destination(beside: output), absoluteSources: protected)
            }
            return try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                if let stillDocument, !stillDocument.requiresPictureProcessing, try stillDocument.exportPlacementScope() != .none {
                    let planner = StillExportPlanner(useSidecar: useSidecar, cancelled: { token.isCancelled })
                    let plan = try planner.resolve(stillDocument, tracks: tracks, mode: mode,
                                                   requireCameraCopy: tracks != .audio && requireCameraCopy,
                                                   output: output, settings: settings,
                                                   audioOutput: audioOutput, audioAction: audioAction,
                                                   pictureTiming: pictureTiming)
                    // The review beside the save panel, and the completion message, state what the plan gives up,
                    // as the program path's delivery review does.
                    if dryRun { return (plan.inspectorSummary, ExportNotices.appending(plan.report.warnings, to: plan.audioDeliverySummary)) }
                    let result = saveResult ? try ExportResultFile(output: output, plan: plan.report, cutMap: plan.report.cutMap) : nil
                    // What writing changed that the plan could not show joins the completion message.
                    let written = try ExportWriteNotices.collecting {
                        try planner.write(plan, to: output) {
                            update(token, $0)
                            return !token.isCancelled
                        }
                        return ExportResultFile.stillCompletionMessage(for: output, result: result)
                    }
                    let message = [written.value] + plan.report.warnings.filter { !written.value.contains($0) } + written.notices
                    return (message.joined(separator: " "), "")
                }
                let engine = MulticamEngine(cancelled: { token.isCancelled })
                // The plan, or the failure with the alternatives of the export rules, as every export reports them.
                guard case .multicam(let snapshot)? = stillDocument else {
                    throw CutError(code: "invalid_range", message: "Select a valid range to export.")
                }
                let plan = try engine.resolution(snapshot, relativeTo: documentURL, output: output, mode: mode, tracks: tracks,
                                                 settings: settings, indexedSources: indexedSources,
                                                 audioOutput: audioOutput, audioAction: audioAction).get()
                if requireCameraCopy, plan.participantRender != nil {
                    throw CutError(code: "camera_copy_required", message: "The participant export would encode picture.")
                }
                if dryRun {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return (String(decoding: try encoder.encode(plan.resultPlan), as: UTF8.self), plan.deliveryReview)
                }
                let result = saveResult ? try ExportResultFile(output: output, plan: plan.resultPlan,
                                                               cutMap: ExportCutMap(multicam: plan.mapping)) : nil
                let written = try ExportWriteNotices.collecting {
                    try engine.write(plan, to: output) { update(token, $0) }
                    return result?.completionMessage(for: output) ?? "Exported \(output.lastPathComponent)."
                }
                let message = ([written.value] + plan.reportedWarnings + written.notices).joined(separator: " ")
                return (message, "")
            }
        } onSuccess: { result in
            if dryRun {
                if let reviewed { reviewed(result.1) }
                else {
                    self.exportDeliverySummary = result.1
                    self.report = result.0
                }
                checked?()
            } else {
                self.status = result.0
                self.exportFinished(output, title: "Multicam export finished")
            }
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
        mediaRefresh.cancel()
        operation?.cancel()
        if !importLoads.isEmpty {
            for cancel in importLoads { cancel() }
            finishImport()
            reconcileSourceLoads()
            status = "Cancelled."
        }
    }

    func cancelAndWait(_ done: @escaping () -> Void) -> Bool {
        let operationWorker = worker ?? mediaRefresh.worker
        guard !importLoads.isEmpty || operationWorker != nil else { return false }
        if !isFlushingDraftSidecars { cancel() }
        Task { @MainActor in
            await operationWorker?.value
            done()
        }
        return true
    }

    func run<T: Sendable>(_ label: String, exporting: Bool = false, additionalSources: [URL] = [], kind: String = "multicam",
                                  work: @escaping @Sendable (EditCancellation, Bool) throws -> T,
                                  onFailure: ((String) -> Void)? = nil,
                                  onSuccess: @escaping (T) -> Void) {
        guard !isBusy else { return }
        exportsSavedAssembly = false
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
        // An export keeps the Mac awake until its work returns: finished, failed or cancelled.
        let awake = exporting ? SleepPrevention(reason: label, provider: sleepActivities) : nil
        if exporting { lastExportedURL = nil }
        let task = sidecarWork.detached(priority: .userInitiated) {
            try AnalysisSidecar.$excludedSources.withValue(protected) { try work(token, useSidecar) }
        }
        worker = Task { [weak self] in
            let result = await task.result
            awake?.end()
            guard let self, self.operation === token else { return }
            if !additionalSources.isEmpty { self.importingURLs = [] }
            defer { if !additionalSources.isEmpty { self.reconcileSourceLoads() } }
            self.operation = nil
            self.isFlushingDraftSidecars = false
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
                    // An unsafe edge of an assembly range has verified times too. They move that edge, never a switch.
                    if self.exportsSavedAssembly, let issue = error as? CutError, let edge = issue.multicam?.edge,
                       let nearest = issue.nearest, !nearest.isEmpty {
                        self.edgeSuggestion = MulticamEdgeSuggestion(edge: edge, times: nearest)
                    }
                    // One wording for an export failure, and the alternatives that work, on every front end.
                    let issue = error as? CutError
                    self.exportAlternatives = issue?.alternatives ?? []
                    if self.stillExportBoundaryBaseline == self.project.map(CutProject.multicam) {
                        self.stillExportBoundaryChoices = issue?.stillBoundaryAdjustments ?? []
                    }
                    let described = issue.map { $0.alternatives == nil ? ExportRules.displayMessage($0.localizedDescription) : ExportRules.describe($0, clips: []) }
                    let message = self.project?.sources.reduce(described ?? error.localizedDescription) { message, source in
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

extension MulticamEditorModel {
    var canRefreshProjectMedia: Bool {
        !isBusy && !isBulkQueuePresented && !(project?.sources.isEmpty ?? true)
    }

    func refreshProjectMedia(deep: Bool = false, receipt: MCPAnalysisReceipt? = nil) {
        updateMediaWatcher()
        _ = refreshProjectMedia(deep: deep, verify: [], receipt: receipt)
    }

    private func currentMediaTargets() -> [URL: Bool] {
        guard let project else { return queuedMediaTargets.presenceOnlyByURL }
        let location = projectURL ?? draft.url ?? URL(fileURLWithPath: "/Untitled.cut", isDirectory: false)
        return CutProject.multicam(project).mediaRefreshTargets(relativeTo: location)
            .merging(queuedMediaTargets.presenceOnlyByURL) { $0 && $1 }
    }

    func mediaStatus(for url: URL) -> ProjectMediaStatus {
        let url = ProjectMediaVolume.watchURL(url)
        if let status = mediaWatcher?.status(for: url), status == .checking || status == .offline || status == .changed {
            return status == .offline && ignoredMediaPaths.contains(url.path)
                ? .ignored : status
        }
        if refreshReviewPicture.contains(url) || !(refreshReviewStreams[url] ?? []).isEmpty { return .needsReview }
        if !refreshReviewReasons.isEmpty, let project, project.sources.contains(where: {
            refreshReviewReasons[$0.id] != nil && Self.availableURL($0) == url
        }) { return .needsReview }
        if sourceLoads[url] != nil { return .indexing }
        return mediaWatcher?.status(for: url) ?? .online
    }

    private func updateMediaWatcher() {
        if mediaWatcher == nil {
            mediaWatcher = ProjectMediaWatcher(publish: { [weak self] urls in
                guard let self, let project = self.project else { return }
                self.objectWillChange.send()
                self.invalidateQueuedMedia(at: Set(urls.filter {
                    let status = self.mediaStatus(for: $0)
                    return status == .offline || status == .changed || status == .ignored
                }))
                guard project.sources.contains(where: { Self.availableURL($0).map(urls.contains) == true }) else { return }
                self.preview.invalidateMedia(urls)
                self.updateMedia(for: project, force: true)
                self.publishSourceProgress()
            }, refresh: { [weak self] urls, verify in
                guard let self, let project = self.project else { return true }
                let recordings = urls.intersection(project.sources.compactMap(Self.availableURL))
                guard !recordings.isEmpty else { return true }
                return self.refreshProjectMedia(deep: false, verify: verify, receipt: nil, only: recordings)
            })
        }
        let expected = queuedMediaTargets.indexed.mapValues(\.identity)
            .merging(ordinaryByURL.mapValues(\.identity)) { _, current in current }
        mediaWatcher?.update(Set(currentMediaTargets().keys), expected: expected, perFile: preferences.automaticallyRefreshMedia)
    }

    private func refreshProjectMedia(deep: Bool, verify: Set<URL>, receipt: MCPAnalysisReceipt?, only: Set<URL>? = nil) -> Bool {
        guard canRefreshProjectMedia, project != nil else {
            receipt?.finish("failed", detail: ["error": "Finish the current project operation before refreshing media."])
            return false
        }
        let targets = currentMediaTargets().filter { only?.contains($0.key) != false && mediaWatcher?.status(for: $0.key) != .checking }
        var verify = verify
        let inputs = targets.map { url, presenceOnly in
            if issuesByPath[url.path] != nil { verify.insert(url) }
            let previous = ordinaryByURL[url] ?? refreshBaselines[url] ??
                indexedByURL[url].flatMap { $0.multicamClockOffset == .zero ? $0 : nil } ??
                queuedMediaTargets.indexed[url]
            return ProjectMediaRefreshInput(url: url, previous: previous, presenceOnly: presenceOnly)
        }
        guard !inputs.isEmpty else {
            receipt?.finish("failed", detail: ["error": "No recordings are referenced by this project."])
            return false
        }
        isBusy = true
        progress = 0
        mediaRefreshProgress = 0
        status = "Refreshing project media…"
        mediaRefresh.start(inputs: inputs, deep: deep, verify: verify, persist: useAnalysisSidecars, alignForMulticam: true,
                           project: projectURL, exclusions: sidecarExclusions, receipt: receipt, progress: { [weak self] fraction in
            self?.progress = fraction
            self?.mediaRefreshProgress = fraction
        }, publish: { [weak self] result, aliases, aligned, identity in
            self?.mediaWatcher?.noteVerified(aliases, identity: identity)
            self?.installMediaRefresh(result, aliases: aliases, aligned: aligned)
            self?.objectWillChange.send()
        }, finished: { [weak self] message in
            guard let self else { return }
            self.mediaRefreshProgress = nil
            if only == nil { self.mediaWatcher?.checkNow() }
            self.progress = nil
            self.isBusy = false
            self.status = message
            self.reconcileSourceLoads()
        })
        return true
    }

    func clearQueueInvalidation(_ id: UUID) {
        invalidatedQueueIDs.remove(id)
    }

    var readyQueuedRanges: [MulticamQueuedRange] {
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

    func refreshIssue(for span: MulticamSpan, mayStartWithSilence: Bool = false) -> String? {
        guard let source = project?.sources.first(where: { $0.id == span.source }),
              let url = Self.availableURL(source) else { return nil }
        switch mediaWatcher?.status(for: url) {
        case .offline: return "\(source.displayName) — recording is offline. Open Project Media to relink it."
        case .checking: return "\(source.displayName) — checking the recording’s volume."
        case .changed: return "\(source.displayName) — the recording changed. Open Project Media to review it."
        default: break
        }
        if let unavailable = refreshReviewReasons[span.source] { return unavailable }
        guard let info = media[span.source], refreshBaselines[url] != nil else { return nil }
        if let stream = span.stream {
            guard refreshReviewStreams[url]?.contains(stream) != true,
                  let track = info.audio.first(where: { $0.stream.index == stream }) else {
                return "\(source.displayName) — the selected audio track changed or is missing."
            }
            let startsWithSilence = mayStartWithSilence && track.hasDeclaredPCMStart && span.input.from >= .zero
            if (!startsWithSilence && span.input.from < max(.zero, track.start)) ||
                span.input.from >= track.end || span.input.to > track.end {
                return "\(source.displayName) — a saved range extends past the refreshed audio track."
            }
        } else {
            if let issue = refreshPictureIssue(sourceID: span.source) { return issue }
            if span.input.from < .zero || span.input.to > info.duration {
                return "\(source.displayName) — a saved range extends past the refreshed recording."
            }
        }
        return nil
    }

    func refreshExportIssue(in plan: MulticamPlan, tracks: ExportTracks, mode: ExportMode,
                            settings: ReencodeSettings, audioAction: ReencodeAudio? = nil,
                            routedAudio: [MulticamPlannedAudioLane]? = nil) -> String? {
        let needsAudio = tracks != .video && (audioAction ?? (mode == .encode ? settings.audio : .copyOriginal)) != .removeAudio
        if tracks != .audio, let issue = plan.picture.lazy.compactMap({ self.refreshIssue(for: $0) }).first { return issue }
        guard needsAudio else { return nil }
        let lanes = routedAudio ?? (try? plan.resolveAudioLanes(indexedSources: [:], assumeUnindexedCoverage: true)) ?? plan.audioLanes
        for lane in lanes {
            if let issue = lane.spans.enumerated().lazy.compactMap({
                self.refreshIssue(for: $0.element, mayStartWithSilence: $0.offset == 0)
            }).first {
                return lane.colorSlot == nil ? issue : "\(lane.label) — \(issue)"
            }
        }
        return nil
    }

    func refreshPictureIssue(sourceID: String) -> String? {
        if let issue = refreshReviewReasons[sourceID] { return issue }
        guard let source = project?.pictureSources.first(where: { $0.id == sourceID }),
              let url = Self.availableURL(source), refreshReviewPicture.contains(url) else { return nil }
        return "\(source.displayName) — the picture track could not be verified."
    }

    private func installMediaRefresh(_ result: MediaRefreshResult, aliases: Set<URL>, aligned: MediaInfo?) {
        let url = result.source.standardizedFileURL
        func matches(_ candidate: URL) -> Bool { aliases.contains(candidate.standardizedFileURL) }
        guard let project else { return }
        let sources = project.sources.filter { Self.availableURL($0).map(matches) == true }
        let affectedURLs = Set(sources.compactMap(Self.availableURL))
        let recovering = sources.contains { refreshReviewReasons[$0.id] != nil }
        guard result.state != .unchanged || recovering else { return }
        let refreshed = result.media ?? (recovering ? refreshBaselines[url] : nil)
        if let media = refreshed {
            for alias in aliases {
                let item = media.forRefreshAlias(alias)
                refreshBaselines[alias] = item
                SourceIndexLoader.shared.acceptRefreshedIndex(item, sidecars: usesSidecar(for: alias), project: projectURL)
            }
        }
        invalidateQueuedMedia(at: aliases.union([url]))
        var refreshedIndexes: [URL: MediaInfo] = [:]
        for source in sources {
            guard let alias = Self.availableURL(source) else { continue }
            sourceLoads.removeValue(forKey: alias)?.cancel()
            indexIssuesByURL[alias] = nil
            if result.state == .offline {
                refreshBaselines[alias] = ordinaryByURL[alias] ?? refreshBaselines[alias] ?? indexedByURL[alias]
            }
            refreshReviewStreams[alias, default: []].formUnion(result.reviewStreams)
            if result.pictureNeedsReview { refreshReviewPicture.insert(alias) }
            let expectedVideo = project.pictureSources.contains { $0.id == source.id }
            if let ordinary = refreshed?.forRefreshAlias(alias),
               let index = aligned?.forRefreshAlias(alias)
                    ?? (result.state == .unchanged ? try? CutEngine().multicamClock(ordinary) : nil) {
                refreshBaselines[alias] = ordinary
                refreshedIndexes[alias] = index
                indexedByURL[alias] = index
                ordinaryByURL[alias] = ordinary
                issuesByPath[alias.path] = nil
                if expectedVideo != index.hasVideo, expectedVideo || index.audio.isEmpty {
                    refreshReviewReasons[source.id] = "\(source.displayName) — the recording type changed."
                } else { refreshReviewReasons[source.id] = nil }
            } else {
                indexedByURL[alias] = nil
                ordinaryByURL[alias] = nil
                let reason = result.state == .offline ? "Recording is offline." : "The recording clock could not be verified."
                issuesByPath[alias.path] = reason
                refreshReviewReasons[source.id] = "\(source.displayName) — \(reason)"
            }
            analysis.stageMediaRefresh(source.id, result: result)
        }
        guard !sources.isEmpty else { return }
        let position = preview.currentTime()
        preview.invalidateMedia(affectedURLs)
        for alias in affectedURLs {
            if let index = refreshedIndexes[alias] { filmstrip.accept(index, displayChanged: result.displayChanged) }
            else { filmstrip.invalidate(alias) }
        }
        updateMedia(for: project, force: true)
        publishSourceProgress()
        preview.seek(to: position)
        mcpRevision += 1
        for source in sources { mediaRefreshWarnings[source.id] = result.persistenceError }
    }
}

extension MulticamEditorModel {
    func replaceParticipantProject(_ next: ParticipantProject, action: String) throws {
        guard edit(action, { project in
            var document = CutProject.multicam(project)
            document.participants = next
            try document.validate()
            if case .multicam(let updated) = document { project = updated }
        }) else {
            throw CutError(code: "invalid_participant_edit", message: "The participant edit could not be applied.")
        }
    }

    func seekParticipantAppearance(sourceID: String, range: MulticamRange, mark: Bool) -> Bool {
        let clockOffset = media[sourceID]?.multicamClockOffset ?? .zero
        guard let from = try? range.from.adding(clockOffset), let to = try? range.to.adding(clockOffset) else { return false }
        let occurrences = mapping?.picture.compactMap { span -> (output: RationalTime, source: MulticamRange)? in
            let start = max(from, span.input.from)
            let end = min(to, span.input.to)
            guard span.source == sourceID, start < end,
                  let output = try? span.output.from.adding(start.subtracting(span.input.from)) else { return nil }
            return (output, .init(from: start, to: end))
        } ?? []
        guard let selection = occurrences.min(by: {
            abs($0.output.seconds - preview.time.seconds) < abs($1.output.seconds - preview.time.seconds)
        }) else { return false }
        preview.pause()
        preview.seek(to: selection.output)
        if mark, let recording = project?.sources.first(where: { $0.id == sourceID }) {
            markIn = try? selection.source.from.adding(recording.offset)
            markOut = try? selection.source.to.adding(recording.offset)
        }
        return true
    }
}

extension MulticamEditorModel {
    private var canChangeProjectMedia: Bool {
        !isBusy && !isBulkQueuePresented && notice == nil
    }

    var projectMediaSnapshotForWriting: ProjectMediaSnapshot {
        // Refresh removes unavailable sources from the live index but keeps the
        // last inspected generation available for verification and the next save.
        let indices = refreshBaselines
            .merging(indexedByURL) { _, indexed in indexed }
            .merging(ordinaryByURL) { _, ordinary in ordinary }
            .values.map { ($0.url.path, $0) }
        let assets = ([project].compactMap { $0 } + undoStack.map(\.project) + redoStack.map(\.project)).flatMap(\.stillAssets)
        var seen = Set(indices.map(\.0))
        let entries = assets.compactMap { ProjectMediaSnapshot.Entry(path: $0.file, asset: $0) }
            .filter { seen.insert($0.path).inserted }
        return mediaSnapshot.merging(media: indices, stills: entries)
    }

    var projectMediaArchive: LiveProjectMediaArchive? {
        guard let project else { return nil }
        func state(_ entry: HistoryEntry) -> CutHistoryState {
            .init(action: entry.action, origin: entry.origin, project: .multicam(entry.project), bindingChanges: entry.bindingChanges)
        }
        return .init(project: .multicam(project), undo: undoStack.map(state), redo: redoStack.map(state),
                     snapshot: projectMediaSnapshotForWriting, documentURL: projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL,
                     checkingVolumes: interchangeCheckingVolumes)
    }

    func relinkProjectMedia(from: String, to: URL, validateCommit: @escaping @MainActor () throws -> Void = {}) async throws -> Bool {
        guard canChangeProjectMedia, let archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        let generation = mcpGeneration, revision = mcpRevision
        let result = try await archive.relink(from, to: to)
        return try installProjectMedia(result.project, archive: archive, snapshot: result.snapshot,
                                       relinkHistory: (result.undo, result.redo), affected: [archive.url(from)],
                                       verified: result.candidate.outcome == .verified ? [archive.url(from): result.candidate] : [:],
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
            let verified = Dictionary(rows.filter { $0.candidate.outcome == .verified }
                .map { (archive.url($0.from), $0.candidate) }, uniquingKeysWith: { first, _ in first })
            return try installProjectMedia(result.project, archive: archive, snapshot: result.snapshot,
                                     relinkHistory: (result.undo, result.redo), affected: Set(rows.map { archive.url($0.from) }),
                                     verified: verified, generation: generation, revision: revision) {
                try validateCommit()
                try validateRows()
            }
        }
    }

    func revertProjectMedia(_ path: String, validateCommit: @escaping @MainActor () throws -> Void = {}) async throws -> Bool {
        guard canChangeProjectMedia, let archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        let generation = mcpGeneration, revision = mcpRevision
        let result = try await archive.revert(path)
        return try installProjectMedia(result.project, archive: archive, snapshot: result.snapshot,
                                       relinkHistory: (result.undo, result.redo), affected: [archive.url(path)],
                                       verified: result.candidate.outcome == .verified ? [archive.url(path): result.candidate] : [:],
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
        historyRevision += 1
        mcpRevision += 1
        objectWillChange.send()
        updateMediaWatcher()
        updateDraft()
    }

    func applyProjectMediaReplacement(_ preview: MediaReplacePreview,
                                      validateCommit: @escaping @MainActor () throws -> Void = {}) async throws -> Bool {
        guard canChangeProjectMedia, let archive = projectMediaArchive else { throw unavailableLiveProjectMedia() }
        try checkLiveMediaVolume(preview.candidateURL, volumes: self.interchangeCheckingVolumes)
        let project = try preview.applying(to: archive.project)
        return try installProjectMedia(project, archive: archive, snapshot: preview.snapshot,
                                       relinkHistory: nil, affected: [preview.sourceURL],
                                       generation: mcpGeneration, revision: mcpRevision,
                                       replacingAt: preview.replacesAtSameLocation ? preview.sourceURL : nil) {
            try validateCommit()
            try checkLiveMediaVolume(preview.candidateURL, volumes: self.interchangeCheckingVolumes)
            try preview.checkGeneration()
        }
    }

    private func installProjectMedia(_ document: CutProject, archive: LiveProjectMediaArchive, snapshot snapshotMedia: ProjectMediaSnapshot,
                                     relinkHistory states: (undo: [CutHistoryState], redo: [CutHistoryState])?, affected: Set<URL>,
                                     verified: [URL: ProjectMediaCandidate] = [:], generation: UUID, revision: Int,
                                     replacingAt: URL? = nil,
                                     validateCommit: () throws -> Void) throws -> Bool {
        try Task.checkCancellation()
        try validateCommit()
        let nextDocument = document.mapMediaPaths(archive.absolutePath)
        let snapshot = snapshotMedia.mappingPaths(archive.absolutePath)
        let relinkHistory = states.map { (undo: archive.absoluteHistory($0.undo), redo: archive.absoluteHistory($0.redo)) }
        guard canChangeProjectMedia, generation == mcpGeneration, revision == mcpRevision, let project,
              (projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL) == archive.documentURL,
              CutProject.multicam(project) == archive.project, undoStack.count == archive.undo.count, redoStack.count == archive.redo.count,
              case .multicam(var next) = nextDocument else { throw staleLiveProjectMedia() }
        let historyChanged = relinkHistory.map { $0.undo != archive.undo || $0.redo != archive.redo } ?? false
        guard nextDocument != archive.project || snapshot != archive.snapshot || historyChanged else { return false }
        if next.transcripts != project.transcripts, next.transcripts.revision == project.transcripts.revision {
            try next.transcripts.advanceRevision()
        }
        if let relinkHistory {
            func map(_ existing: [HistoryEntry], _ states: [CutHistoryState]) throws -> [HistoryEntry] {
                try zip(existing, states).map { entry, state in
                    guard case .multicam(let project) = state.project else { throw staleLiveProjectMedia() }
                    var entry = entry
                    entry.project = project
                    entry.bindingChanges = state.bindingChanges ?? []
                    return entry
                }
            }
            let undo = try map(undoStack, relinkHistory.undo)
            let redo = try map(redoStack, relinkHistory.redo)
            undoStack = undo
            redoStack = redo
        } else {
            if preferences.historyLimit > 0 {
                undoStack.append(.init(action: "Replace Source File", project: project, selection: selection,
                                       bindingChanges: TranscriptBindingChange.changes(from: next.transcripts, to: project.transcripts)))
            }
            redoStack.removeAll()
            _ = trimHistory()
            lastEditAction = "Replace Source File"
            if let replacingAt {
                indexedByURL[replacingAt] = nil
                ordinaryByURL[replacingAt] = nil
                issuesByPath[replacingAt.path] = nil
                indexIssuesByURL[replacingAt] = nil
                refreshReviewPicture.remove(replacingAt)
                refreshReviewStreams[replacingAt] = nil
                refreshBaselines[replacingAt] = nil
                sourceLoads.removeValue(forKey: replacingAt)?.cancel()
                for source in next.sources where Self.availableURL(source) == replacingAt {
                    refreshReviewReasons[source.id] = nil
                    mediaRefreshWarnings[source.id] = nil
                }
            }
        }
        if !verified.isEmpty {
            let snapshots = Dictionary(archive.snapshot.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for source in project.sources {
                let path = archive.url(source.file)
                guard let candidate = verified[path],
                      let original = media[source.id] ?? refreshBaselines[path],
                      snapshots[path.path]?.sourceFingerprint == original.identity.transcriptFingerprint else { continue }
                analysis.carryVerifiedRelink(source.id, to: candidate, original: original)
            }
        }
        historyRevision += 1
        mediaSnapshot = snapshot
        apply(next)
        if mcpRevision == revision { mcpRevision += 1 }
        invalidateQueuedMedia(at: affected)
        updateDraft()
        return true
    }
}
