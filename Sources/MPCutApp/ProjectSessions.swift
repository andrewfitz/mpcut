import AppKit
import Combine
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectSession: ObservableObject {
    var sidecarWork: ProjectSidecarWork { isMulticam ? multicam.sidecarWork : editor.sidecarWork }

    static let windowID = "project"
    let id: UUID
    let editor: EditorModel
    let multicam: MulticamEditorModel
    let presentation: EditorPresentation
    // Protecting a listed pause saves an undo step, but its scan ID remains
    // usable for a subsequent review action. Any intervening edit expires it.
    var mcpPauseReviewRevision: (handle: String, project: Int, listing: Int)?
    var mcpPauseListingRevision: Int {
        guard let anchor = mcpPauseReviewRevision, anchor.handle == mcpHandle,
              anchor.project == mcpRevision else { return mcpRevision }
        return anchor.listing
    }

    let transcriptBasket = TranscriptPaneBasket()
    let transcriptPaneMemory = TranscriptPaneMemory()
    private var participantGeometryRevision: ParticipantSpeakerIndexKey?
    private var participantGeometryIndexes: [String: ParticipantMonitorGeometry] = [:]
    private var participantFeedIDsBySource: [String: Set<String>] = [:]
    private var participantLinkedFeedIDs: Set<String> = []

    private func refreshParticipantInspection() {
        let revision = ParticipantSpeakerIndexKey(session: self)
        guard revision != participantGeometryRevision else { return }
        participantGeometryIndexes.removeAll()
        participantFeedIDsBySource = Dictionary(uniqueKeysWithValues: participantProject.sources.map { source in
            (source.sourceID, Set(source.appearances.compactMap(\.participantID)).union(source.unresolvedParticipantIDs))
        })
        participantLinkedFeedIDs = participantFeedIDsBySource.values.reduce(into: []) { $0.formUnion($1) }
        participantGeometryRevision = revision
    }

    func participantFeedIDs(sourceID: String? = nil) -> Set<String> {
        refreshParticipantInspection()
        if let sourceID { return participantFeedIDsBySource[sourceID] ?? [] }
        return participantLinkedFeedIDs
    }

    func participantGeometry(for sourceID: String) -> ParticipantMonitorGeometry? {
        refreshParticipantInspection()
        if let index = participantGeometryIndexes[sourceID] { return index }
        guard let source = participantProject.sources.first(where: { $0.sourceID == sourceID }) else { return nil }
        let index = ParticipantMonitorGeometry(source)
        participantGeometryIndexes[sourceID] = index
        return index
    }

    lazy var transcript = LiveTranscriptController(session: self)
    private var feedAngleConversion: (sequence: DocumentState, action: String, origin: HistoryOrigin, handle: String,
                                      editorGeneration: UUID, multicamGeneration: UUID)?
    var feedAngleProjectHandle: String? {
        guard let conversion = feedAngleConversion,
              conversion.editorGeneration == editor.mcpGeneration,
              conversion.multicamGeneration == multicam.mcpGeneration else { return nil }
        return conversion.handle
    }
    var canUndoFeedAngleConversion: Bool {
        isMulticam && feedAngleHistoryAction != nil && !multicam.isBusy && multicam.notice == nil &&
            !editor.isBusy && multicam.historyCursor == 0
    }
    var canRedoFeedAngleConversion: Bool {
        !isMulticam && feedAngleHistoryAction != nil && !editor.isBusy && editor.alert == nil &&
            !editor.mcpHasActiveTrim && feedAngleSequenceBoundary == editor.historyCursor
    }
    var feedAngleSequenceBoundary: Int? {
        guard let conversion = feedAngleConversion,
              case .sequence(_, let project, let entries, let cursor) = conversion.sequence,
              editor.historyCursor <= cursor, editor.historyEntryIDs == entries else { return nil }
        if editor.historyCursor == cursor {
            var current = editor.transcriptProject
            current.transcripts.revision = project.transcripts.revision
            if current != project { return nil }
        }
        return cursor
    }
    private var feedAngleUndoArchive: [CutHistoryState] {
        guard isMulticam, feedAngleHistoryAction != nil,
              let conversion = feedAngleConversion,
              case .sequence(_, let project, _, _) = conversion.sequence else { return [] }
        let steps = max(0, editor.mcpHistoryLimit - multicam.projectHistory.count)
        return Array((editor.nativeConversionUndoArchive + [.init(action: conversion.action, origin: conversion.origin,
                                                                  project: project)]).suffix(steps))
    }
    private var feedAngleRedoArchive: [CutHistoryState] {
        guard !isMulticam, feedAngleHistoryAction != nil, feedAngleSequenceBoundary != nil,
              let conversion = feedAngleConversion, let project = multicam.project else { return [] }
        let steps = max(0, editor.mcpHistoryLimit - editor.projectHistory.count)
        return Array((multicam.nativeConversionRedoArchive + [.init(action: conversion.action, origin: conversion.origin,
                                                                       project: .multicam(project))]).suffix(steps))
    }
    var feedAngleConversionAction: String? { feedAngleConversion?.action }
    private var feedAngleHistoryAction: ProjectHistoryAction? {
        guard editor.mcpHistoryLimit > 0, let conversion = feedAngleConversion, feedAngleProjectHandle != nil else { return nil }
        return .init(name: conversion.action, origin: conversion.origin)
    }

    var hasFeedAngleConversionHistory: Bool {
        feedAngleHistoryAction != nil && (isMulticam || feedAngleSequenceBoundary != nil)
    }

    var conversionHistoryCursor: Int {
        if isMulticam {
            return multicam.historyCursor + (feedAngleHistoryAction == nil ? 0 : editor.historyCursor + 1)
        }
        return editor.historyCursor
    }

    var conversionHistoryActions: [ProjectHistoryAction] {
        guard hasFeedAngleConversionHistory, let action = feedAngleHistoryAction else {
            return isMulticam ? multicam.projectHistory : editor.projectHistory
        }
        return Array(editor.projectHistory.prefix(feedAngleSequenceBoundary ?? editor.historyCursor)) + [action] + multicam.projectHistory
    }

    var conversionHistoryToken: String {
        "\(isMulticam ? multicam.historyToken : editor.historyToken)/\(mcpRevision)/\(conversionHistoryActions.count)"
    }

    func conversionHistoryTimeline(at index: Int) -> CutProject? {
        if isMulticam {
            guard feedAngleHistoryAction != nil else { return multicam.retainedTimeline(at: index) }
            if index > editor.historyCursor { return multicam.retainedTimeline(at: index - editor.historyCursor - 1) }
            return editor.retainedTimeline(at: index)
        }
        if let boundary = feedAngleSequenceBoundary, index > boundary {
            return multicam.retainedTimeline(at: index - boundary - 1)
        }
        return editor.retainedTimeline(at: index)
    }

    func restoreConversionHistory(_ index: Int) {
        let boundary = feedAngleSequenceBoundary ?? editor.historyCursor
        if isMulticam {
            guard feedAngleHistoryAction != nil else { multicam.moveToHistoryState(index); return }
            if index > boundary {
                multicam.moveToHistoryState(index - boundary - 1)
            } else {
                multicam.moveToHistoryState(0)
                guard canUndoFeedAngleConversion else { return }
                undoFeedAngleConversion()
                if index < boundary { editor.moveToHistoryState(index) }
            }
        } else if index > boundary, hasFeedAngleConversionHistory {
            editor.moveToHistoryState(boundary, beforeRestore: nil) { result in
                guard case .success = result else {
                    if case .failure(let error) = result {
                        self.editor.alert = EditorNotice(title: "Couldn’t Restore History State", message: error.localizedDescription)
                    }
                    return
                }
                self.redoFeedAngleConversion()
                if self.isMulticam { self.multicam.moveToHistoryState(index - boundary - 1) }
            }
        } else {
            editor.moveToHistoryState(index)
        }
    }
    @Published private(set) var isConvertingFeedAngles = false
    private var feedAngleConversionWork: Task<MulticamProject, Error>?

    func useFeedsAsMulticamAngles(sourceID: String, feedIDs: [String] = []) {
        guard !isConvertingFeedAngles else { return }
        let project = transcript.project
        let document = isMulticam ? multicam.projectURL ?? multicam.draft.url : editor.projectURL ?? editor.draft.url
        let context = document ?? LiveProjectMediaArchive.untitledURL
        let revision = mcpRevision
        let handle = mcpHandle
        isConvertingFeedAngles = true
        let work = sidecarWork.detached(priority: .userInitiated) {
            try TileFeedAngles.usingFeeds(in: project, document: context, sourceID: sourceID, feedIDs: feedIDs,
                                          cancelled: { Task.isCancelled })
        }
        feedAngleConversionWork = work
        Task { [weak self] in
            guard let self else { work.cancel(); return }
            defer {
                self.feedAngleConversionWork = nil
                self.isConvertingFeedAngles = false
            }
            do {
                let converted = try await work.value
                guard self.mcpHandle == handle else { return }
                try self.commitFeedAngles(converted, action: "Use Feeds as Multicam Angles", expectedRevision: revision)
            } catch is CancellationError {
            } catch {
                guard self.mcpHandle == handle else { return }
                if self.isMulticam { self.multicam.fail(error.localizedDescription) }
                else { self.editor.alert = EditorNotice(title: "Use Feeds as Multicam Angles", message: error.localizedDescription) }
            }
        }
    }

    func commitFeedAngles(_ project: MulticamProject, action: String, expectedRevision: Int) throws {
        guard mcpRevision == expectedRevision else {
            throw MCPCommandError("stale_revision", "Current revision is \(mcpRevision). Read the project state again.")
        }
        if isMulticam {
            guard multicam.edit(action, { $0 = project }) else {
                throw MCPCommandError("editor_busy", "The multicam timeline is unavailable for editing.")
            }
            return
        }
        guard !editor.isBusy, !editor.mcpHasActiveTrim, editor.alert == nil,
              let archive = editor.projectMediaArchive else {
            throw MCPCommandError("editor_busy", "The sequence is unavailable for editing.")
        }
        let outputTime = editor.playhead
        let handle = mcpHandle
        editor.preview.pause()
        try multicam.installFeedAngleConversion(project, from: editor, archive: archive, action: action)
        editor.discardRedoBeforeFeedAngleConversion()
        feedAngleConversion = (documentState, action, HistoryOrigin.current, handle, editor.mcpGeneration, multicam.mcpGeneration)
        isMulticam = true
        multicam.saveFeedAngleDraft()
        multicam.seekAssemblyTimeline(outputTime, scrubbing: false)
    }

    func loadFeedAngleHistory(_ states: [CutHistoryState], at url: URL, archiveMedia: CutProjectMedia) {
        guard let boundary = states.last else { return }
        let isCurrentMulticam = isMulticam
        let handle = mcpHandle
        let didLoad: ([CutHistoryState]) -> Void = { [weak self] _ in
            guard let self, self.isMulticam == isCurrentMulticam, self.mcpHandle == handle else { return }
            if isCurrentMulticam { self.editor.invalidateFeedAngleDiskRevision() }
            else { self.multicam.invalidateFeedAngleDiskRevision() }
            let sequenceCursor = isCurrentMulticam ? self.editor.historyCursor : self.editor.projectHistory.count
            guard let sequenceProject = self.editor.retainedTimeline(at: sequenceCursor) else { return }
            let sequence = DocumentState.sequence(self.editor.projectURL ?? self.editor.draft.url,
                                                   sequenceProject, self.editor.historyEntryIDs, sequenceCursor)
            self.feedAngleConversion = (sequence, boundary.action, boundary.origin, handle,
                                        self.editor.mcpGeneration, self.multicam.mcpGeneration)
            if isCurrentMulticam { self.multicam.didOpenFeedAngleHistory() }
            else { self.editor.didOpenFeedAngleHistory() }
            self.objectWillChange.send()
            self.editor.objectWillChange.send()
            self.multicam.objectWillChange.send()
        }
        let history = Array(states.dropLast())
        if isCurrentMulticam, let clips = boundary.project.sequenceClips {
            do {
                try editor.openProject(clips, at: url, history: (history, []), archiveMedia: archiveMedia,
                                       stillProject: boundary.project, openingConversionHistory: true, onConversionHistory: didLoad)
            } catch { multicam.fail(error.localizedDescription) }
        } else if !isCurrentMulticam, case .multicam(let project) = boundary.project {
            multicam.openProject(url, document: project, history: ([], history), archiveMedia: archiveMedia,
                                 openingConversionHistory: true, onConversionHistory: didLoad)
        }
    }

    func undoFeedAngleConversion() {
        guard canUndoFeedAngleConversion else { return }
        let assets = currentFeedAngleTranscriptAssets()
        multicam.preview.pause()
        multicam.draft.move(to: editor.draft)
        isMulticam = false
        editor.restoreAfterFeedAngleConversion(url: multicam.projectURL, diskRevision: multicam.feedAngleDiskRevision,
                                               revision: multicam.mcpRevision, assets: assets)
        feedAngleConversion?.sequence = documentState
    }

    func redoFeedAngleConversion() {
        guard canRedoFeedAngleConversion else { return }
        let assets = currentFeedAngleTranscriptAssets()
        editor.preview.pause()
        editor.draft.move(to: multicam.draft)
        isMulticam = true
        multicam.restoreFeedAngleConversion(url: editor.projectURL, diskRevision: editor.feedAngleDiskRevision,
                                            revision: editor.mcpRevision, assets: assets)
    }

    private func currentFeedAngleTranscriptAssets() -> [String: TranscriptAsset] {
        Dictionary(transcript.project.transcripts.attachments.map { ($0.asset.sha256, $0.asset) },
                   uniquingKeysWith: { first, _ in first })
    }
    var mcpMediaPreview: MCPProjectMediaPreview?
    private(set) var mcpModeGeneration = UUID()
    @Published var isMulticam = false {
        didSet {
            guard oldValue != isMulticam else { return }
            mcpModeGeneration = UUID()
            presentation.participantMonitorSource = false
        }
    }
    @Published var isHistoryPresented = false
    weak var historyDismissingSheet: NSWindow?
    @Published var isTimelineMapPresented = false
    @Published var isOutputSettingsPresented = false
    @Published var isISOVerificationPresented = false
    var afterOutputSettingsDismiss: (() -> Void)?
    weak var window: NSWindow? {
        didSet { applyCloseState() }
    }
    private var closeStateObservers = Set<AnyCancellable>()
    private var windowDelegate: ProjectWindowDelegate?

    fileprivate func bindWindowDelegate(to window: NSWindow, sessions: ProjectSessions) {
        guard self.window === window else { return }
        if let windowDelegate, window.delegate === windowDelegate { return }
        windowDelegate?.detach()
        let delegate = ProjectWindowDelegate(window: window, session: self, sessions: sessions)
        windowDelegate = delegate
        window.delegate = delegate
    }

    init(id: UUID, preferences: EditorPreferences) {
        self.id = id
        presentation = EditorPresentation(startingFrom: preferences)
        editor = EditorModel(preferences: preferences)
        multicam = MulticamEditorModel(preferences: preferences)
        editor.conversionRedoArchive = { [weak self] in self?.feedAngleRedoArchive ?? [] }
        multicam.conversionUndoArchive = { [weak self] in self?.feedAngleUndoArchive ?? [] }
        presentation.participantMonitorSourceChanged = { [weak self] source in
            self?.editor.preview.setParticipantSource(source)
            self?.multicam.preview.setParticipantSource(source)
        }
        editor.participantSourceReset = { [weak self] in
            guard let self, !self.isMulticam else { return }
            self.presentation.participantMonitorSource = false
        }
        multicam.participantSourceReset = { [weak self] in
            guard let self, self.isMulticam else { return }
            self.presentation.participantMonitorSource = false
        }
        Publishers.CombineLatest4($isMulticam, multicam.$isBusy, editor.$isExporting, editor.$isSavingSidecars)
            .map { isMulticam, busy, exporting, saving in isMulticam ? busy : exporting || saving }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyCloseState() }
            .store(in: &closeStateObservers)
        _ = transcript
    }

    func canStartMulticam(accepting panel: NSWindow? = nil) -> Bool {
        // AppKit may still report the accepted picker as attached in its completion.
        if let sheet = window?.attachedSheet, sheet !== panel { return false }
        if isMulticam { return !multicam.hasSession }
        return editor.canOpenProject
    }

    /// An editor that is importing or exporting queues the files and adds them when it is idle.
    var canReceiveMedia: Bool {
        !isMulticam && editor.alert == nil && window?.attachedSheet == nil
    }

    /// Whether Add Clips can show its picker in this window now.
    var canChooseMedia: Bool { canReceiveMedia && !editor.isBusy }

    var isExporting: Bool { editor.isExporting || multicam.isExporting }

    var hasLifecycleModal: Bool {
        window?.attachedSheet != nil || isHistoryPresented || isTimelineMapPresented || isOutputSettingsPresented
            || isISOVerificationPresented || (isMulticam
            ? !multicam.setup.isEmpty || multicam.isBulkQueuePresented || multicam.isReplacementAudioPresented || multicam.report != nil
            : editor.isBulkQueuePresented || editor.cutPreview != nil)
    }

    /// A discard decision applies to the document the user actually saw.
    enum DocumentState: Equatable {
        case sequence(URL?, CutProject, [UUID], Int)
        case multicam(URL?, MulticamProject?, [MulticamSource], Int, Int)
    }

    var documentState: DocumentState {
        if isMulticam {
            return .multicam(multicam.projectURL ?? multicam.draft.url, multicam.project ?? multicam.pendingSetupProject,
                             multicam.setup.map(\.source), multicam.historyRevision, multicam.historyCursor)
        }
        return .sequence(editor.projectURL ?? editor.draft.url, editor.transcriptProject, editor.historyEntryIDs,
                         editor.historyCursor)
    }

    var hasUnsavedDocument: Bool { isMulticam ? multicam.isChanged : editor.isProjectChanged }

    func preserveAfterUnconfirmedClose() {
        transcript.prepareForWindowEnd(preservingDraft: true)
        if isMulticam { multicam.preserveAfterUnconfirmedClose() }
        else { editor.preserveAfterUnconfirmedClose() }
    }

    /// Uses the native delegate chain and scopes an explicit discard to the reviewed document state.
    func requestWindowClose(discardingChanges: Bool) {
        guard let window else { return }
        if discardingChanges { windowDelegate?.requestedDiscard = documentState }
        defer { windowDelegate?.requestedDiscard = nil }
        window.performClose(nil)
    }

    func confirmClose() -> Bool {
        guard window?.attachedSheet == nil else { return false }
        if isMulticam { return multicam.confirmClose() }
        return !editor.isExporting && !editor.isSavingSidecars && editor.confirmCloseProject()
    }

    /// Closing ends the session, so the close button and ⌘W are unavailable while
    /// an export or sidecar save the user started is running. A multicam window
    /// also waits for an import or project load, which its status bar can cancel.
    func applyCloseState() {
        guard let window else { return }
        let closable = isMulticam ? !multicam.isBusy : !(editor.isExporting || editor.isSavingSidecars)
        guard window.styleMask.contains(.closable) != closable else { return }
        if closable { window.styleMask.insert(.closable) } else { window.styleMask.remove(.closable) }
    }

    private(set) var monitor: NSWindow?

    func showMonitor() {
        if let monitor {
            if monitor.isMiniaturized { monitor.deminiaturize(nil) }
            monitor.orderFront(nil)
            return
        }
        let preferences = editor.preferences
        let editorScreen = window?.screen ?? NSScreen.main
        let lastFrame = Self.lastMonitorFrame(preferences.monitorLastFrame, placement: preferences.monitorPlacement,
                                              screens: NSScreen.screens.map(\.frame))
        let screen = lastFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.screens.first { $0 != editorScreen } ?? editorScreen
        let monitor = VideoMonitorPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
                              backing: .buffered, defer: false, screen: screen)
        monitor.title = "Video Monitor"
        monitor.isReleasedWhenClosed = false
        monitor.hidesOnDeactivate = false
        monitor.isFloatingPanel = false
        monitor.becomesKeyOnlyIfNeeded = true
        monitor.isExcludedFromWindowsMenu = true
        monitor.collectionBehavior.insert(.fullScreenPrimary)
        monitor.contentView = NSHostingView(rootView: ProjectMonitor(
            ordinary: editor.preview, multicam: multicam.preview, preferences: editor.preferences,
            mode: $isMulticam, isMulticam: isMulticam
        ))
        if let lastFrame {
            monitor.setFrame(lastFrame, display: false)
        } else if let screen {
            let available = screen.visibleFrame
            let scale = min(1, available.width / monitor.frame.width, available.height / monitor.frame.height)
            let size = NSSize(width: monitor.frame.width * scale, height: monitor.frame.height * scale)
            monitor.setFrame(NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                    width: size.width, height: size.height), display: false)
        } else { monitor.center() }
        // Remembered for the Last position placement whichever placement is chosen now.
        monitor.observeFrame { [weak preferences] frame in preferences?.monitorLastFrame = frame }
        monitor.onClose = { [weak self] in self?.monitor = nil }
        self.monitor = monitor
        monitor.orderFront(nil)
    }

    /// The saved Video Monitor frame for the Last position placement, or nil to use the other-display rule:
    /// Other display is chosen, nothing is saved, or the saved frame is on no attached screen.
    nonisolated static func lastMonitorFrame(_ saved: CGRect?, placement: VideoMonitorPlacement, screens: [CGRect]) -> CGRect? {
        guard placement == .lastPosition, let saved, saved.width >= 1, saved.height >= 1 else { return nil }
        return screens.contains { !$0.intersection(saved).isNull && !$0.intersection(saved).isEmpty } ? saved : nil
    }

    func pausePreview() {
        editor.preview.pause()
        multicam.preview.pause()
    }

    func end() {
        feedAngleConversionWork?.cancel()
        transcript.prepareForWindowEnd()
        windowDelegate?.detach()
        windowDelegate = nil
        monitor?.close()
        editor.endSession()
        multicam.reset()
    }
}

private final class VideoMonitorPanel: NSPanel {
    override var canBecomeMain: Bool { false }
    var onClose: (() -> Void)?
    private var frameChanged: ((NSRect) -> Void)?
    private var frameObservers: [NSObjectProtocol] = []

    /// Reports the frame when the monitor moves, finishes a resize or closes. A full-screen frame is not reported.
    func observeFrame(_ report: @escaping (NSRect) -> Void) {
        frameChanged = report
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            frameObservers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportFrame() }
            })
        }
    }

    private func reportFrame() {
        guard !styleMask.contains(.fullScreen) else { return }
        frameChanged?(frame)
    }

    override func close() {
        reportFrame()
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        frameChanged = nil
        super.close()
        contentView = nil
        onClose?()
        onClose = nil
    }
}

private struct ProjectMonitor: View {
    let ordinary: SequencePreview
    let multicam: MulticamPreview
    let preferences: EditorPreferences
    let mode: Published<Bool>.Publisher
    @State var isMulticam: Bool

    var body: some View {
        Group {
            if isMulticam { MulticamPreviewView(preview: multicam, preferences: preferences, isVideoMonitor: true) }
            else { PreviewView(preview: ordinary, preferences: preferences, isVideoMonitor: true) }
        }
        .onReceive(mode) { isMulticam = $0 }
    }
}

@MainActor
final class ProjectSessions: ObservableObject {
    struct CommandContext {
        let session: ProjectSession
        let isMulticam: Bool
    }

    @Published private(set) var commandContext: CommandContext?
    var conversionOwner: String?
    @Published var projectConversion: EditCancellation?
    var isConvertingProject: Bool { projectConversion != nil }
    @Published private(set) var isCancellingProject = false
    func cancelProjectConversion() {
        guard let projectConversion, !isCancellingProject else { return }
        isCancellingProject = true
        projectConversion.cancel()
    }

    func finishProjectConversion() {
        projectConversion = nil
        conversionOwner = nil
        isCancellingProject = false
        let finished = conversionDidFinish
        conversionDidFinish = nil
        finished?()
    }
    var conversionDidFinish: (() -> Void)?
    private weak var commandWindow: NSWindow?
    private var commandModeObserver: AnyCancellable?
    private var focusObservers = Set<AnyCancellable>()
    let preferences: EditorPreferences
    lazy var mcpBridge = MCPLocalControl(sessions: self)
    lazy var mcpFileJobs = MCPFileJobs()
    let mcpAnalysisJobs = MCPAnalysisJobs()
    let mcpTranscriptPlans = MCPTranscriptPlans()
    let mcpOutputJobs = MCPLiveOutputJobs()
    private(set) var isDrainingMCPForQuit = false
    private var hasActiveMCPJobs: Bool {
        mcpFileJobs.hasRunningJobs || mcpOutputJobs.hasRunningJobs || mcpAnalysisJobs.hasRunningJobs
    }
    private(set) var sessions: [UUID: ProjectSession] = [:]
    private(set) var closingEditors: [UUID: EditorModel] = [:]
    private var closedMulticamOperations: [UUID: [() -> Void]] = [:]
    private var openWindow: ((UUID) -> Void)?
    /// Front to back. Finder can deliver an open event before any window is key.
    var orderedWindows: () -> [NSWindow] = { NSApp?.orderedWindows ?? [] }
    private struct OpenRequest {
        let files: [URL]
        let fromFinder: Bool
        let sessionID: UUID?
    }
    private var pendingFiles: [OpenRequest] = []
    private var isPresentingFinderChoice = false
    /// The Finder alert while it is showing, so tests can answer its “Don't ask again” box.
    private(set) var finderChoiceAlert: NSAlert?
    private var addClipsOnOpen: Set<UUID> = []
    private weak var reopeningSession: ProjectSession?
    private var approvedQuitStates: [UUID: ProjectSession.DocumentState] = [:]
    private enum LaunchState { case launching, awaitingWindow, ready }
    private var launchState: LaunchState
    /// Settings → General → Offer to recover untitled projects at launch, waiting for the launch window.
    private var launchDraftOffer: [URL]?
    /// Shows the launch recovery offer. Tests replace it; the app uses File → Recover Untitled Project…'s alert.
    var presentLaunchDraftRecovery: (([URL], ProjectSession) -> Void)?
    /// Enforces Settings → Storage → Limit the shared cache folder in the running app only.
    var sharedCacheLimit: SharedCacheLimitEnforcer?

    init(preferences: EditorPreferences, launching: Bool = false, openWindow: ((UUID) -> Void)? = nil) {
        self.preferences = preferences
        self.openWindow = openWindow
        launchState = launching ? .launching : .ready
        observeWindowFocus()
    }

    private func observeWindowFocus() {
        let notifications = NotificationCenter.default
        notifications.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] event in self?.setCommandWindow(event.object as? NSWindow) }
            .store(in: &focusObservers)
        notifications.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] event in
                guard let self, let window = event.object as? NSWindow, self.commandWindow === window else { return }
                self.setCommandWindow(nil)
            }
            .store(in: &focusObservers)
        notifications.publisher(for: NSWindow.willBeginSheetNotification)
            .sink { [weak self] event in
                guard let self, self.commandContext?.session.window === event.object as? NSWindow else { return }
                self.setCommandWindow(nil)
            }
            .store(in: &focusObservers)
        notifications.publisher(for: NSWindow.didEndSheetNotification)
            .sink { [weak self] event in
                guard let parent = event.object as? NSWindow else { return }
                Task { [weak self, weak parent] in
                    guard let self, let app = NSApp, app.isActive else { return }
                    self.restoreCommandsAfterSheet(on: parent, keyWindow: app.keyWindow, mainWindow: app.mainWindow)
                }
            }
            .store(in: &focusObservers)
        notifications.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.setCommandWindow(NSApp?.keyWindow) }
            .store(in: &focusObservers)
        notifications.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.setCommandWindow(nil) }
            .store(in: &focusObservers)
    }

    func restoreCommandsAfterSheet(on parent: NSWindow?, keyWindow: NSWindow?, mainWindow: NSWindow?) {
        // The sheet can end before AppKit returns key status to its parent. While
        // that parent is still main, it owns the commands during the transition.
        setCommandWindow(keyWindow ?? (parent === mainWindow ? parent : nil))
    }

    func focusProjectWindow(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Making an already-key window frontmost emits no key-window notification.
        if window.isKeyWindow { setCommandWindow(window) }
    }

    /// A popover takes key status from its editor and still belongs to that editor's commands.
    private func commandSession(for window: NSWindow?) -> ProjectSession? {
        var candidate = window
        while let current = candidate {
            if let session = sessions.values.first(where: { $0.window === current }) {
                return current.attachedSheet == nil ? session : nil
            }
            candidate = current.parent
        }
        return nil
    }

    private func setCommandWindow(_ window: NSWindow?) {
        let session = commandSession(for: window)
        commandWindow = session == nil ? nil : window
        guard session !== commandContext?.session else { return }
        commandModeObserver?.cancel()
        commandModeObserver = nil
        guard let session else {
            commandContext = nil
            return
        }
        commandModeObserver = session.$isMulticam.sink { [weak self, weak session] isMulticam in
            guard let session else { return }
            self?.commandContext = CommandContext(session: session, isMulticam: isMulticam)
        }
    }

    func session(for id: UUID?) -> ProjectSession {
        let id = id ?? UUID()
        return sessions[id] ?? ProjectSession(id: id, preferences: preferences)
    }

    func register(_ session: ProjectSession, window: NSWindow, openWindow: OpenWindowAction) {
        setWindowOpener(openWindow)
        register(session, window: window)
    }

    func register(_ session: ProjectSession, window: NSWindow) {
        sessions[session.id] = session
        session.window = window
        session.bindWindowDelegate(to: window, sessions: self)
        if window.isKeyWindow {
            Task { [weak self] in self?.setCommandWindow(NSApp?.keyWindow) }
        }
        session.editor.editorWindow = window
        session.multicam.window = window
        session.multicam.chooseProjectRequest = { [weak self, weak session] in
            self?.chooseProject(in: session)
        }
        session.multicam.canSaveProjectTo = { [weak self, weak session] url in
            self?.project(at: url, excluding: session) == nil
        }
        session.editor.canSaveProjectTo = session.multicam.canSaveProjectTo
        if launchState == .awaitingWindow { launchState = .ready }
        let shouldChooseClips = addClipsOnOpen.remove(session.id) != nil
        schedulePendingFiles(in: session, chooseClips: shouldChooseClips)
        if launchDraftOffer != nil { scheduleLaunchDraftOffer() }
    }

    // MARK: Launch

    /// Draft retention, then the recovery offer, then the shared cache limit. Called once by the app delegate
    /// after launch; every routine does nothing at its factory value.
    func runLaunchMaintenance(drafts directory: URL = ProjectDraft.autosaveDirectory,
                              trash: @escaping @Sendable (URL) throws -> Void = {
                                  try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                              }) async {
        let days = preferences.draftRetentionDays
        if days > 0 {
            let open = openDraftURLs
            // Retention and recovery lock the same draft folders, so the offer waits for retention.
            _ = await Task.detached(priority: .utility) {
                DraftRetention.run(days: days, open: open, directory: directory, trash: trash)
            }.value
        }
        offerDraftRecoveryAtLaunch(drafts: directory)
    }

    /// Files are still waiting to open: launch has not finished, a Finder open is queued or its choice is showing.
    var hasPendingOpens: Bool { launchState != .ready || !pendingFiles.isEmpty || isPresentingFinderChoice }

    /// Every open window's untitled draft, sequence and multicam.
    var openDraftURLs: Set<URL> {
        Set(sessions.values.flatMap { [$0.editor.draft.url, $0.multicam.draft.url].compactMap { $0 } })
    }

    /// Offers the recoverable drafts once the launch window is ready, only when Settings asks for it and drafts exist.
    func offerDraftRecoveryAtLaunch(drafts directory: URL = ProjectDraft.autosaveDirectory) {
        guard preferences.offersDraftRecovery,
              let files = try? ProjectDraft.recoverable(in: directory), !files.isEmpty else { return }
        launchDraftOffer = files
        scheduleLaunchDraftOffer()
    }

    private func scheduleLaunchDraftOffer() {
        guard launchState == .ready, sessions.values.contains(where: { $0.window != nil }) else { return }
        Task { [weak self] in self?.presentLaunchDraftOffer() }
    }

    private func presentLaunchDraftOffer() {
        guard let files = launchDraftOffer else { return }
        launchDraftOffer = nil
        // A Finder open at launch takes the window; File → Recover Untitled Project… still lists the drafts.
        guard pendingFiles.isEmpty, !isPresentingFinderChoice, let target = frontSession ?? sessions.values.first(where: { $0.window != nil }),
              target.window?.attachedSheet == nil, target.isMulticam ? !target.multicam.hasSession : target.editor.canOpenProject,
              target.isMulticam || target.editor.isEmpty else { return }
        if let present = presentLaunchDraftRecovery { present(files, target) }
        else { presentDraftRecovery(files, in: target, atLaunch: true) }
    }

    func finishLaunching() {
        // SwiftUI can register and close a provisional window before the Finder open event.
        // The WindowGroup supplies its actual launch window on either side of didFinishLaunching.
        guard launchState == .launching else { return }
        if let session = frontSession ?? sessions.values.first(where: { $0.window != nil }) {
            launchState = .ready
            schedulePendingFiles(in: session)
        } else {
            launchState = .awaitingWindow
        }
    }

    private func schedulePendingFiles(in session: ProjectSession, chooseClips: Bool = false) {
        guard launchState == .ready, chooseClips || !pendingFiles.isEmpty else { return }
        // Let the SwiftUI window finish attaching before showing sheets or activating other windows.
        Task { [weak self, weak session] in
            guard let self else { return }
            let attached = session.flatMap { self.sessions[$0.id] === $0 && $0.window != nil ? $0 : nil }
            self.openPendingFiles(in: attached)
            if chooseClips { attached?.editor.chooseFiles() }
        }
    }

    private func openPendingFiles(in session: ProjectSession?) {
        guard openWindow != nil else { return }
        while !isPresentingFinderChoice && !pendingFiles.isEmpty {
            let request = pendingFiles.removeFirst()
            let target = request.sessionID.flatMap { sessions[$0] } ?? session ?? focusedSession ?? frontSession
            route(request, in: target)
        }
    }

    func windowClosedWithoutConfirmation(_ session: ProjectSession) {
        guard sessions[session.id] === session else { return }
        if approvedQuitStates[session.id] != session.documentState {
            // The last window can close immediately before termination. Finish this
            // emergency save while its model and recording references still exist.
            session.preserveAfterUnconfirmedClose()
        }
        windowClosed(session)
    }

    func windowClosed(_ session: ProjectSession) {
        let id = session.id
        guard sessions[id] === session else { return }
        mcpOutputJobs.close(owner: session.mcpHandle)
        mcpAnalysisJobs.close(owner: session.mcpHandle)
        mcpTranscriptPlans.remove(owner: session.mcpHandle)
        if commandContext?.session === session { setCommandWindow(nil) }
        // Reset abandons the operation's result. Subscribe while the model can
        // still cancel it so a subsequent Quit can await its file cleanup.
        if session.multicam.cancelAndWait({ [weak self] in
            let completions = self?.closedMulticamOperations.removeValue(forKey: id) ?? []
            for completion in completions { completion() }
        }) {
            closedMulticamOperations[id] = []
        }
        session.end()
        session.window = nil
        sessions[id] = nil
        if session.editor.cancelAndWaitForExport({ [weak self] in self?.closingEditors[id] = nil }) {
            closingEditors[id] = session.editor
        }
    }

    func createWindow() throws -> ProjectSession {
        guard let openWindow else {
            throw CutError(code: "app_starting", message: "The application is still preparing its project windows.")
        }
        return newWindow(openWindow)
    }

    @discardableResult
    func newWindow(using action: OpenWindowAction, addClips: Bool = false) -> ProjectSession {
        newWindow({ action(id: ProjectSession.windowID, value: $0) }, addClips: addClips)
    }

    private func newWindow(_ open: (UUID) -> Void, addClips: Bool = false) -> ProjectSession {
        let session = self.session(for: nil)
        sessions[session.id] = session
        if addClips { addClipsOnOpen.insert(session.id) }
        open(session.id)
        return session
    }

    @discardableResult
    func reopen() -> Bool {
        if launchState != .ready || (!sessions.isEmpty && sessions.values.allSatisfy({ $0.window == nil })) {
            return true // An editor window is already being created.
        }
        guard sessions.isEmpty, let openWindow else { return false }
        reopeningSession = newWindow(openWindow)
        return true
    }

    private func session(owning window: NSWindow) -> ProjectSession? {
        var window = window
        while let parent = window.sheetParent ?? window.parent { window = parent }
        return sessions.values.first { $0.window === window }
    }

    private var focusedSession: ProjectSession? {
        NSApp?.keyWindow.flatMap(session(owning:))
    }

    /// The editor in front receives files when MPCut is in the background or a utility window is key.
    private var frontSession: ProjectSession? {
        orderedWindows().lazy.compactMap(self.session(owning:)).first
    }

    /// The front editor stands in for the menu commands while Settings or About is key.
    private var utilitySession: ProjectSession? {
        guard focusedSession == nil else { return nil }
        return frontSession.flatMap { $0.window?.attachedSheet == nil ? $0 : nil }
    }

    func chooseProject(in session: ProjectSession? = nil, using action: OpenWindowAction? = nil) {
        if let action { setWindowOpener(action) }
        let panel = NSOpenPanel()
        panel.title = "Open MPCut Project"
        panel.allowedContentTypes = [.mpcutProject]
        let source = session ?? focusedSession ?? utilitySession
        present(panel, in: source) { [weak self, weak source] panel in
            if let url = panel.url { self?.openProject(url, in: source, accepting: panel) }
        }
    }

    func chooseMulticamSources(in session: ProjectSession? = nil, using action: OpenWindowAction? = nil) {
        if let action { setWindowOpener(action) }
        let session = session ?? utilitySession
        if let session, session.isMulticam {
            session.multicam.chooseSources()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Add as Multicam"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        present(panel, in: session) { [weak self, weak session] panel in
            guard let target = self?.multicamTarget(in: session, accepting: panel) else { return }
            target.multicam.importSources(panel.urls)
        }
    }

    func setWindowOpener(_ action: OpenWindowAction) {
        openWindow = { action(id: ProjectSession.windowID, value: $0) }
    }

    private func present(_ panel: NSOpenPanel, in session: ProjectSession?, onAccept: @escaping (NSOpenPanel) -> Void) {
        ProjectPanels.present(panel, in: session?.window) { accepted in
            if accepted { onAccept(panel) }
        }
    }

    func openFiles(_ urls: [URL], in session: ProjectSession? = nil, fromFinder: Bool = false) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        let request = OpenRequest(files: files, fromFinder: fromFinder, sessionID: session?.id)
        guard launchState == .ready, openWindow != nil, pendingFiles.isEmpty, !isPresentingFinderChoice else {
            pendingFiles.append(request)
            return
        }
        let pendingReopen = reopeningSession.flatMap { $0.window == nil && sessions[$0.id] === $0 ? $0 : nil }
        route(request, in: session ?? focusedSession ?? frontSession ?? pendingReopen)
    }

    /// The editor that Add Clips uses when no editor has the menu commands, such
    /// as while Settings or About is the key window. Nil asks for a new window.
    var clipCommandTarget: ProjectSession? {
        (focusedSession ?? frontSession).flatMap { $0.canChooseMedia ? $0 : nil }
    }

    func chooseClips(using action: OpenWindowAction) {
        setWindowOpener(action)
        guard let target = clipCommandTarget else {
            _ = newWindow(using: action, addClips: true)
            return
        }
        target.window?.makeKeyAndOrderFront(nil)
        target.editor.chooseFiles()
    }

    /// Opens the projects among files dropped on `session`, as File → Open
    /// would, and returns the remaining files for the editor to import.
    func openDroppedProjects(_ urls: [URL], in session: ProjectSession?) -> [URL] {
        var media: [URL] = []
        var projects: [URL] = []
        for url in urls where url.isFileURL {
            let resolved = Self.resolveAlias(url)
            if Self.isProject(resolved) { projects.append(resolved) } else { media.append(resolved) }
        }
        guard !projects.isEmpty else { return media }
        // SwiftUI does not open a window from inside the drop callback, so a project
        // that needs its own window opens once the drag session has ended.
        Task { @MainActor [weak self, weak session] in
            guard let self else { return }
            let source = session.flatMap { self.sessions[$0.id] === $0 ? $0 : nil }
            for file in projects { self.openProject(file, in: source) }
        }
        return media
    }

    /// True when a dropped file is a project, which `openDroppedProjects` opens instead of importing.
    static func isDroppedProject(_ url: URL) -> Bool { url.isFileURL && isProject(resolveAlias(url)) }

    private static func isProject(_ resolved: URL) -> Bool {
        isCutDocument(resolved) || isCutDocument(resolved.resolvingSymlinksInPath())
    }

    private func route(_ request: OpenRequest, in source: ProjectSession?) {
        guard let openWindow else { return }
        var media: [URL] = []
        var projects: [URL] = []
        for file in request.files {
            let resolved = Self.resolveAlias(file)
            if Self.isProject(resolved) {
                projects.append(resolved)
            } else { media.append(resolved) }
        }
        if request.fromFinder, media.count > 1, !media.contains(where: StillImage.isImageInput),
           media.contains(where: Self.isVideo) {
            chooseFinderImport(media, in: source)
        } else if !media.isEmpty {
            openMedia(media, in: source, using: openWindow)
        }
        for file in projects { openProject(file, in: source) }
    }

    private static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.resolvingSymlinksInPath().pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private func openMedia(_ media: [URL], in source: ProjectSession?, using openWindow: (UUID) -> Void) {
        if let source, source.isMulticam, source.multicam.project != nil,
           !source.multicam.isBusy, source.window?.attachedSheet == nil, media.allSatisfy(StillImage.isImageInput) {
            source.multicam.insertMulticamStills(media)
            source.window?.makeKeyAndOrderFront(nil)
        } else {
            let target = source.flatMap { $0.canReceiveMedia ? $0 : nil } ?? newWindow(openWindow)
            target.editor.openFiles(media)
            target.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Several recordings from Finder follow Settings → General: ask, join them or open them as multicam.
    private func chooseFinderImport(_ media: [URL], in source: ProjectSession?) {
        switch preferences.multipleRecordingsAction {
        case .join:
            if let openWindow { openMedia(media, in: source, using: openWindow) }
            return
        case .multicam:
            openFinderMulticam(media, in: source)
            return
        case .ask:
            break
        }
        isPresentingFinderChoice = true
        let alert = NSAlert()
        alert.messageText = "Open \(media.count) files in MPCut"
        alert.informativeText = "Join Clips adds the files to one timeline in order. Open as Multicam loads the videos as camera angles and any audio files as separate recordings."
        alert.addButton(withTitle: "Join Clips")
        alert.addButton(withTitle: "Open as Multicam")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.suppressionButton?.toolTip = "Use this choice from now on. Reset All Warnings in Settings → General asks again."
        finderChoiceAlert = alert
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak source, weak alert] response in
            let remember = alert?.suppressionButton?.state == .on
            Task { @MainActor in
                guard let self else { return }
                self.finderChoiceAlert = nil
                guard let openWindow = self.openWindow else { return }
                let source = source.flatMap { self.sessions[$0.id] === $0 ? $0 : nil }
                if response == .alertFirstButtonReturn {
                    if remember { self.preferences.suppress(.openMultipleRecordings, choosing: .join) }
                    self.openMedia(media, in: source, using: openWindow)
                } else if response == .alertSecondButtonReturn {
                    if remember { self.preferences.suppress(.openMultipleRecordings, choosing: .multicam) }
                    self.openFinderMulticam(media, in: source)
                }
                self.isPresentingFinderChoice = false
                self.openPendingFiles(in: source)
            }
        }
        if let window = source?.window, window.attachedSheet == nil {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func openFinderMulticam(_ media: [URL], in source: ProjectSession?) {
        guard let target = multicamTarget(in: source, accepting: nil) else { return }
        target.multicam.importSources(media, startAutomatically: true)
        target.window?.makeKeyAndOrderFront(nil)
    }

    func project(at url: URL, excluding excluded: ProjectSession? = nil) -> ProjectSession? {
        func project(matching matches: (URL) -> Bool) -> ProjectSession? {
            sessions.values.first { session in
                guard session !== excluded else { return false }
                let multicam = [session.multicam.openingProjectURL, session.multicam.projectURL, session.multicam.draft.url]
                let sequence = [session.editor.openingProjectURL, session.editor.projectURL, session.editor.draft.url]
                let urls = session.feedAngleProjectHandle == nil ? multicam + sequence
                    : (session.isMulticam ? multicam : sequence)
                return urls.compactMap { $0 }.contains(where: matches)
            }
        }
        // Check every open project for an exact URL before consulting the filesystem.
        if let existing = project(matching: { $0 == url }) { return existing }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        lazy var identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        return project { candidate in
            if candidate.standardizedFileURL.resolvingSymlinksInPath() == resolved { return true }
            guard let identifier,
                  let candidateIdentifier = try? candidate.resourceValues(forKeys: [.fileResourceIdentifierKey])
                    .fileResourceIdentifier else { return false }
            return candidateIdentifier.isEqual(identifier)
        }
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let a = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let b = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return a.isEqual(b)
    }

    private static func resolveAlias(_ url: URL) -> URL {
        guard (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true else { return url }
        return (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url
    }

    static func resolvedProjectURL(_ url: URL) -> URL {
        resolveAlias(url).resolvingSymlinksInPath().standardizedFileURL
    }

    func openProject(_ url: URL, in source: ProjectSession?, accepting panel: NSWindow? = nil) {
        do { _ = try openResolvedProject(Self.resolvedProjectURL(url), in: source, accepting: panel) }
        catch { ProjectPanels.present(NSAlert(error: error), in: source?.window) }
    }

    func openResolvedProject(_ url: URL, in source: ProjectSession?, accepting panel: NSWindow? = nil,
                             commitCheck: ((ProjectSession) -> (() -> Bool))? = nil)
        throws -> (session: ProjectSession, reused: Bool) {
        if let existing = project(at: url) {
            if let named = [existing.editor.projectURL, existing.multicam.projectURL].compactMap({ $0 })
                .first(where: { Self.sameFile($0, url) }) {
                preferences.recentFiles.record([named])
            }
            if let window = existing.window { focusProjectWindow(window) }
            return (existing, true)
        }
        let reservation = try ProjectDraft.reserveIfRecoverable(url)
        let document = try CutProject.loadEditorDocument(from: url, limit: preferences.historyLimit)
        guard let target = projectTarget(in: source, accepting: panel) else {
            throw CutError(code: "app_starting", message: "The application is still preparing its project windows.")
        }
        let history = (document.undo, document.redo)
        let onConversionHistory: ([CutHistoryState]) -> Void = { [weak target] states in
            target?.loadFeedAngleHistory(states, at: url, archiveMedia: document.media)
        }
        switch document.project {
        case .sequence(let clips):
            target.isMulticam = false
            try target.editor.openProject(clips, at: url, history: history, reservation: reservation,
                                          archiveMedia: document.media, allowCommit: commitCheck?(target),
                                          onConversionHistory: onConversionHistory)
            target.window?.makeKeyAndOrderFront(nil)
        case .stillSequence(let sequence):
            target.isMulticam = false
            let clips = sequence.items.compactMap { item -> CutSequenceClip? in
                guard case .source(let clip) = item else { return nil }
                return clip
            }
            try target.editor.openProject(clips, at: url, history: history, reservation: reservation,
                                          archiveMedia: document.media, allowCommit: commitCheck?(target),
                                          stillProject: document.project, onConversionHistory: onConversionHistory)
            target.window?.makeKeyAndOrderFront(nil)
        case .multicam(let project):
            target.isMulticam = true
            target.multicam.openProject(url, document: project, history: history, reservation: reservation,
                                        archiveMedia: document.media, allowCommit: commitCheck?(target),
                                        onConversionHistory: onConversionHistory)
        }
        return (target, false)
    }

    private func multicamTarget(in source: ProjectSession?, accepting panel: NSWindow?) -> ProjectSession? {
        guard let target = projectTarget(in: source, accepting: panel) else { return nil }
        target.isMulticam = true
        return target
    }

    private func projectTarget(in source: ProjectSession?, accepting panel: NSWindow?) -> ProjectSession? {
        guard let openWindow else { return nil }
        let target: ProjectSession
        if let source, sessions[source.id] === source, source.canStartMulticam(accepting: panel) {
            target = source
        } else {
            target = newWindow(openWindow)
        }
        return target
    }
}

struct ProjectSessionHost: View {
    @StateObject private var session: ProjectSession
    let sessions: ProjectSessions

    init(identifier: UUID?, sessions: ProjectSessions) {
        self.sessions = sessions
        _session = StateObject(wrappedValue: sessions.session(for: identifier))
    }

    var body: some View {
        ProjectWorkspace(session: session, editor: session.editor, multicam: session.multicam, sessions: sessions)
    }
}

private struct ProjectWorkspace: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var editor: EditorModel
    @ObservedObject var multicam: MulticamEditorModel
    let sessions: ProjectSessions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if session.isMulticam {
                MulticamEditorView(model: multicam, presentation: session.presentation)
                    .frame(minWidth: 810, minHeight: 565)
                    .onChange(of: !multicam.hasSession && multicam.notice == nil, initial: true) { _, isEmpty in
                        if isEmpty { session.isMulticam = false }
                    }
            } else {
                EditorView(editor: editor, multicam: multicam, presentation: session.presentation, addMulticam: { sessions.chooseMulticamSources(in: session) })
                    .frame(minWidth: 730, minHeight: max(510, 385 + editor.timelineThumbnailHeight +
                        (editor.preferences.sourceTimeTicks ? TimelineSourceRuler.height : 0) +
                        (editor.isAudioOnly || editor.audioTracks.isEmpty ? 0 : (editor.largeThumbnails ? 64 : 32))))
            }
        }
        .onAppear {
            session.presentation.showAbout = { [openWindow] in openWindow(id: "about") }
            SettingsWindow.register(openSettings)
            session.presentation.showSettings = { [openSettings] in openSettings() }
        }
        .sheet(isPresented: $session.isHistoryPresented) {
            ProjectHistoryView(actions: session.conversionHistoryActions, cursor: session.conversionHistoryCursor,
                               disabled: session.isMulticam ? multicam.isBusy : editor.isBusy,
                               timeline: session.conversionHistoryTimeline, restore: session.restoreConversionHistory)
        }
        .sheet(isPresented: $session.isTimelineMapPresented) {
            if let timeline = session.currentTimeline {
                TimelineRangeMapView(timeline: timeline)
            }
        }
        .sheet(isPresented: $session.isOutputSettingsPresented, onDismiss: {
            let action = session.afterOutputSettingsDismiss
            session.afterOutputSettingsDismiss = nil
            action?()
        }) {
            ProjectOutputSettingsView(session: session)
        }
        .sheet(isPresented: $session.isISOVerificationPresented) {
            TilesISOExportSheet(session: session)
        }
        .background(ProjectWindowBinding(session: session, sessions: sessions, openWindow: openWindow,
                                         documentURL: session.isMulticam ? multicam.projectURL : editor.projectURL,
                                         isEdited: session.isMulticam ? multicam.isChanged : editor.isProjectChanged))
        .environment(\.transcriptSession, session)
        .environment(\.openDroppedProjects) { [weak sessions, weak session] urls in
            sessions?.openDroppedProjects(urls, in: session) ?? urls
        }
    }
}

/// Opens dropped projects and returns the files that are media.
private struct OpenDroppedProjectsKey: EnvironmentKey {
    static let defaultValue: @MainActor ([URL]) -> [URL] = { $0 }
}

extension EnvironmentValues {
    var openDroppedProjects: @MainActor ([URL]) -> [URL] {
        get { self[OpenDroppedProjectsKey.self] }
        set { self[OpenDroppedProjectsKey.self] = newValue }
    }
}

struct ProjectWindowBinding: NSViewRepresentable {
    let session: ProjectSession
    let sessions: ProjectSessions
    let openWindow: OpenWindowAction
    let documentURL: URL?
    let isEdited: Bool

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.session = session
        view.sessions = sessions
        view.openWindow = openWindow
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.documentURL = documentURL
        view.isEdited = isEdited
        view.applyDocumentState()
    }

    final class WindowView: NSView {
        weak var session: ProjectSession?
        weak var sessions: ProjectSessions?
        var openWindow: OpenWindowAction?
        var documentURL: URL?
        var isEdited = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let session, let openWindow else { return }
            sessions?.register(session, window: window, openWindow: openWindow)
            applyDocumentState()
        }

        func applyDocumentState() {
            guard let window, let session, let sessions, session.window === window else { return }
            session.bindWindowDelegate(to: window, sessions: sessions)
            if window.representedURL != documentURL { window.representedURL = documentURL }
            if window.isDocumentEdited != isEdited { window.isDocumentEdited = isEdited }
        }
    }
}

// AppKit registers delegate notification selectors when the delegate is installed.
// SwiftUI can replace the binding view during a mode switch, so keep the delegate
// and the target for those selectors alive together for the entire attachment.
@MainActor
private final class ProjectWindowDelegate: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var session: ProjectSession?
    private weak var sessions: ProjectSessions?
    private let upstream: NSWindowDelegate?
    var requestedDiscard: ProjectSession.DocumentState?
    private var approvedClose: ProjectSession.DocumentState?

    init(window: NSWindow, session: ProjectSession, sessions: ProjectSessions) {
        self.window = window
        self.session = session
        self.sessions = sessions
        if let previous = window.delegate as? ProjectWindowDelegate {
            upstream = previous.upstream
        } else {
            upstream = window.delegate
        }
    }

    func detach() {
        if let window, window.delegate === self { window.delegate = upstream }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        approvedClose = nil
        let before = session?.documentState
        let discarding = requestedDiscard != nil && requestedDiscard == before
        guard discarding || session?.confirmClose() != false,
              upstream?.windowShouldClose?(sender) != false else { return false }
        guard session?.hasUnsavedDocument != true || session?.documentState == before else { return false }
        approvedClose = session?.documentState
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let session, let closing = notification.object as? NSWindow, session.window === closing {
            if approvedClose == session.documentState { sessions?.windowClosed(session) }
            else { sessions?.windowClosedWithoutConfirmation(session) }
        }
        upstream?.windowWillClose?(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        session?.pausePreview()
        upstream?.windowDidResignKey?(notification)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || upstream?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let upstream, upstream.responds(to: selector) { return upstream }
        return super.forwardingTarget(for: selector)
    }
}

@MainActor
final class EditorApplication: NSObject, NSApplicationDelegate {
    let sessions = ProjectSessions(preferences: EditorPreferences(defaults: EditorPreferences.applicationDefaults), launching: true)
    private var isQuitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MutedLaunch.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sessions.finishLaunching()
        sessions.mcpBridge.observeSetting()
        LiveTranscriptController.pruneAbandonedWork()
        // Settings → Storage. Both do nothing at their factory values.
        let cacheLimit = SharedCacheLimitEnforcer(preferences: sessions.preferences) { [weak sessions] in
            sessions.map { SidecarClearContext(sessions: $0) } ?? SidecarClearContext()
        }
        sessions.sharedCacheLimit = cacheLimit
        cacheLimit.start()
        Task { [sessions] in await sessions.runLaunchMaintenance() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        sessions.openFiles(urls, fromFinder: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        sessions.mcpBridge.stop()
        sessions.finishTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !sessions.reopen()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        SettingsWindow.commitPendingEdits()
        let decision = sessions.prepareToQuit(stopExports: {
            let alert = NSAlert()
            alert.messageText = "Stop ongoing work and quit?"
            alert.informativeText = "MPCut will stop active exports, conversions, and jobs before it quits. Transcript jobs can be resumed when you reopen the project."
            alert.addButton(withTitle: "Continue Working").toolTip = "Keep MPCut open"
            let quit = alert.addButton(withTitle: "Stop and Quit")
            quit.hasDestructiveAction = true
            quit.toolTip = "Stop work and quit"
            return alert.runModal() == .alertSecondButtonReturn
        }, reply: { [weak self] allowed in
            self?.isQuitting = false
            sender.reply(toApplicationShouldTerminate: allowed)
        })
        switch decision {
        case .now: return .terminateNow
        case .cancel: return .terminateCancel
        case .later:
            isQuitting = true
            return .terminateLater
        }
    }
}

extension ProjectSessions {
    enum QuitDecision { case now, cancel, later }

    /// `reply` is called once the stopped work has been cleaned up, only after `.later`.
    func prepareToQuit(stopExports: () -> Bool,
                       confirmClose ask: ((ProjectSession) -> Bool)? = nil,
                       reply: @escaping (Bool) -> Void) -> QuitDecision {
        approvedQuitStates.removeAll()
        let confirmClose = ask ?? { $0.isMulticam ? $0.multicam.confirmClose() : $0.editor.confirmCloseProject() }
        if let sheet = sessions.values.compactMap({ $0.window?.attachedSheet }).first {
            sheet.makeKeyAndOrderFront(nil)
            return .cancel
        }
        func hasWorkToStop() -> Bool {
            isConvertingProject || sessions.values.contains(where: \.isExporting) || hasActiveMCPJobs
                || LiveTranscriptController.hasActiveJobs
        }
        let askedToStop = hasWorkToStop()
        if askedToStop, !stopExports() { return .cancel }
        var confirmed: [UUID: ProjectSession.DocumentState] = [:]
        let confirm = { (idleOnly: Bool) -> Bool in
            // Modal prompts and asynchronous cleanup can deliver Finder events or
            // finish other edits. Recheck live windows after every user decision.
            while true {
                if let sheet = self.sessions.values.compactMap({ $0.window?.attachedSheet }).first {
                    sheet.makeKeyAndOrderFront(nil)
                    return false
                }
                guard let session = self.sessions.values.first(where: { session in
                    if idleOnly && (session.isMulticam ? session.multicam.isBusy : session.editor.isBusy) { return false }
                    return confirmed[session.id] != session.documentState
                }) else { return true }
                let before = session.documentState
                if session.isMulticam || session.hasUnsavedDocument {
                    if session.hasUnsavedDocument { session.window?.makeKeyAndOrderFront(nil) }
                    if !confirmClose(session) { return false }
                }
                confirmed[session.id] = session.hasUnsavedDocument ? before : session.documentState
            }
        }

        func finishConfirmation() -> Bool {
            defer { self.isDrainingMCPForQuit = false }
            guard !hasWorkToStop(), confirm(false), !hasWorkToStop() else { return false }
            self.approvedQuitStates = confirmed
            return true
        }
        // Ask about unsaved projects before stopping anything, so Cancel leaves every other window working.
        guard confirm(true) else { return .cancel }
        // A modal save prompt can run the event loop and accept another job.
        if !askedToStop, hasWorkToStop(), !stopExports() { return .cancel }
        isDrainingMCPForQuit = true
        var pending = 0
        let cleaned = {
            pending -= 1
            guard pending == 0 else { return }
            reply(finishConfirmation())
        }
        if hasActiveMCPJobs {
            pending += 1
            Task { @MainActor in
                async let files: Void = mcpFileJobs.cancelAndWaitForJobs()
                async let outputs: Void = mcpOutputJobs.cancelAndWaitForJobs()
                async let analysis: Void = mcpAnalysisJobs.cancelAndWaitForJobs()
                _ = await (files, outputs, analysis)
                cleaned()
            }
        }
        if LiveTranscriptController.hasActiveJobs {
            pending += 1
            Task { @MainActor in
                await LiveTranscriptController.interruptActiveJobs()
                cleaned()
            }
        }
        if isConvertingProject {
            pending += 1
            conversionDidFinish = cleaned
            cancelProjectConversion()
        }
        for project in Array(sessions.values) {
            if project.multicam.cancelAndWait(cleaned) { pending += 1 }
            if project.editor.cancelAndWaitForExport(cleaned) { pending += 1 }
        }
        for editor in closingEditors.values {
            if editor.cancelAndWaitForExport(cleaned) { pending += 1 }
        }
        for id in Array(closedMulticamOperations.keys) {
            closedMulticamOperations[id]?.append(cleaned)
            pending += 1
        }
        if pending > 0 { return .later }
        return finishConfirmation() ? .now : .cancel
    }

    func finishTermination() {
        for session in sessions.values {
            if approvedQuitStates[session.id] == session.documentState {
                session.transcript.prepareForWindowEnd()
                session.editor.draft.discard()
                session.multicam.draft.discard()
            } else {
                // There is no subsequent run loop in which to finish a queued draft.
                session.preserveAfterUnconfirmedClose()
            }
        }
    }
}

func isCutDocument(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "cut"
}
