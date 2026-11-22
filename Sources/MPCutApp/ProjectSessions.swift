import AppKit
import Combine
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectSession: ObservableObject {
    static let windowID = "project"
    let id: UUID
    let editor: EditorModel
    let multicam: MulticamEditorModel
    let presentation = EditorPresentation()
    private(set) var mcpModeGeneration = UUID()
    @Published var isMulticam = false {
        didSet { if oldValue != isMulticam { mcpModeGeneration = UUID() } }
    }
    @Published var isHistoryPresented = false
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
        editor = EditorModel(preferences: preferences)
        multicam = MulticamEditorModel(preferences: preferences)
        Publishers.CombineLatest4($isMulticam, multicam.$isBusy, editor.$isExporting, editor.$isSavingSidecars)
            .map { isMulticam, busy, exporting, saving in isMulticam ? busy : exporting || saving }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyCloseState() }
            .store(in: &closeStateObservers)
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
        window?.attachedSheet != nil || isHistoryPresented || (isMulticam
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
        return .sequence(editor.projectURL ?? editor.draft.url, editor.stillProject, editor.historyEntryIDs,
                         editor.historyCursor)
    }

    var hasUnsavedDocument: Bool { isMulticam ? multicam.isChanged : editor.isProjectChanged }

    func preserveAfterUnconfirmedClose() {
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
        let editorScreen = window?.screen ?? NSScreen.main
        let screen = NSScreen.screens.first { $0 != editorScreen } ?? editorScreen
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
            ordinary: editor.preview, multicam: multicam.preview,
            mode: $isMulticam, isMulticam: isMulticam
        ))
        if let screen {
            let available = screen.visibleFrame
            let scale = min(1, available.width / monitor.frame.width, available.height / monitor.frame.height)
            let size = NSSize(width: monitor.frame.width * scale, height: monitor.frame.height * scale)
            monitor.setFrame(NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                    width: size.width, height: size.height), display: false)
        } else { monitor.center() }
        monitor.onClose = { [weak self] in self?.monitor = nil }
        self.monitor = monitor
        monitor.orderFront(nil)
    }

    func pausePreview() {
        editor.preview.pause()
        multicam.preview.pause()
    }

    func end() {
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
    override func close() {
        super.close()
        contentView = nil
        onClose?()
        onClose = nil
    }
}

private struct ProjectMonitor: View {
    let ordinary: SequencePreview
    let multicam: MulticamPreview
    let mode: Published<Bool>.Publisher
    @State var isMulticam: Bool

    var body: some View {
        Group {
            if isMulticam { MulticamPreviewView(preview: multicam, isVideoMonitor: true) }
            else { PreviewView(preview: ordinary, isVideoMonitor: true) }
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
    private var pendingFiles: [URL] = []
    private var addClipsOnOpen: Set<UUID> = []
    private weak var reopeningSession: ProjectSession?
    private var approvedQuitStates: [UUID: ProjectSession.DocumentState] = [:]
    private enum LaunchState { case launching, awaitingWindow, ready }
    private var launchState: LaunchState

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
            .sink { [weak self] _ in
                Task { [weak self] in self?.setCommandWindow(NSApp?.keyWindow) }
            }
            .store(in: &focusObservers)
        notifications.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.setCommandWindow(NSApp?.keyWindow) }
            .store(in: &focusObservers)
        notifications.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.setCommandWindow(nil) }
            .store(in: &focusObservers)
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
            let files = self.pendingFiles
            self.pendingFiles = []
            self.route(files, in: attached ?? self.frontSession)
            if chooseClips { attached?.editor.chooseFiles() }
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

    func openFiles(_ urls: [URL], in session: ProjectSession? = nil) {
        let files = urls.filter(\.isFileURL)
        guard launchState == .ready, openWindow != nil, pendingFiles.isEmpty else {
            pendingFiles.append(contentsOf: files)
            return
        }
        let pendingReopen = reopeningSession.flatMap { $0.window == nil && sessions[$0.id] === $0 ? $0 : nil }
        route(files, in: session ?? focusedSession ?? frontSession ?? pendingReopen)
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

    /// Opens the multicam projects among files dropped on `session`, as File → Open
    /// would, and returns the remaining files for the editor to import.
    func openDroppedProjects(_ urls: [URL], in session: ProjectSession?) -> [URL] {
        var media: [URL] = []
        var projects: [URL] = []
        for url in urls where url.isFileURL {
            let resolved = Self.resolveAlias(url)
            if Self.isProject(resolved) { projects.append(resolved) } else { media.append(url) }
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

    private func route(_ files: [URL], in source: ProjectSession?) {
        guard let openWindow else { return }
        var media: [URL] = []
        var projects: [URL] = []
        for file in files {
            let resolved = Self.resolveAlias(file)
            if Self.isProject(resolved) {
                projects.append(resolved)
            } else { media.append(resolved) }
        }
        if !media.isEmpty {
            if let source, source.isMulticam, source.multicam.project != nil,
               !source.multicam.isBusy, source.window?.attachedSheet == nil,
               media.allSatisfy(StillImage.isImageInput) {
                source.multicam.insertMulticamStills(media)
                source.window?.makeKeyAndOrderFront(nil)
            } else {
                let target = source.flatMap { $0.canReceiveMedia ? $0 : nil } ?? newWindow(openWindow)
                target.editor.openFiles(media)
                target.window?.makeKeyAndOrderFront(nil)
            }
        }
        for file in projects { openProject(file, in: source) }
    }

    func project(at url: URL, excluding excluded: ProjectSession? = nil) -> ProjectSession? {
        sessions.values.first { session in
            guard session !== excluded else { return false }
            let urls = [session.multicam.openingProjectURL, session.multicam.projectURL, session.multicam.draft.url,
                        session.editor.openingProjectURL, session.editor.projectURL, session.editor.draft.url].compactMap { $0 }
            return urls.contains { Self.sameFile($0, url) }
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
        do { _ = try openProjectAtURL(url, in: source, accepting: panel) }
        catch { ProjectPanels.present(NSAlert(error: error), in: source?.window) }
    }

    func openProjectAtURL(_ url: URL, in source: ProjectSession?, accepting panel: NSWindow? = nil,
                          commitCheck: ((ProjectSession) -> (() -> Bool))? = nil) throws -> ProjectSession {
        let url = Self.resolvedProjectURL(url)
        if let existing = project(at: url) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let reservation = try ProjectDraft.reserveIfRecoverable(url)
        let document = try CutProject.loadEditorDocument(from: url, limit: preferences.historyLimit)
        guard let target = projectTarget(in: source, accepting: panel) else {
            throw CutError(code: "app_starting", message: "The application is still preparing its project windows.")
        }
        let history = (document.undo, document.redo)
        switch document.project {
        case .sequence(let clips):
            target.isMulticam = false
            try target.editor.openProject(clips, at: url, history: history, reservation: reservation,
                                          archiveMedia: document.media, allowCommit: commitCheck?(target))
            target.window?.makeKeyAndOrderFront(nil)
        case .stillSequence(let sequence):
            target.isMulticam = false
            let clips = sequence.items.compactMap { item -> CutSequenceClip? in
                guard case .source(let clip) = item else { return nil }
                return clip
            }
            try target.editor.openProject(clips, at: url, history: history, reservation: reservation,
                                          archiveMedia: document.media, allowCommit: commitCheck?(target),
                                          stillProject: document.project)
            target.window?.makeKeyAndOrderFront(nil)
        case .multicam(let project):
            target.isMulticam = true
            target.multicam.openProject(url, document: project, history: history, reservation: reservation,
                                        archiveMedia: document.media, allowCommit: commitCheck?(target))
        }
        return target
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
                        (editor.isAudioOnly || editor.audioTracks.isEmpty ? 0 : (editor.largeThumbnails ? 64 : 32))))
            }
        }
        .onAppear {
            session.presentation.showAbout = { [openWindow] in openWindow(id: "about") }
            session.presentation.showSettings = { [openSettings] in openSettings() }
        }
        .sheet(isPresented: $session.isHistoryPresented) {
            if session.isMulticam {
                ProjectHistoryView(actions: multicam.historyActions, cursor: multicam.historyCursor,
                                   disabled: multicam.isBusy, restore: multicam.moveToHistoryState)
            } else {
                ProjectHistoryView(actions: editor.historyActions, cursor: editor.historyCursor,
                                   disabled: editor.isBusy, restore: editor.moveToHistoryState)
            }
        }
        .background(ProjectWindowBinding(session: session, sessions: sessions, openWindow: openWindow,
                                         documentURL: session.isMulticam ? multicam.projectURL : editor.projectURL,
                                         isEdited: session.isMulticam ? multicam.isChanged : editor.isProjectChanged))
        .environment(\.openDroppedProjects) { [weak sessions, weak session] urls in
            sessions?.openDroppedProjects(urls, in: session) ?? urls
        }
    }
}

/// Opens dropped multicam projects and returns the files that are media.
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
    let sessions = ProjectSessions(preferences: EditorPreferences(defaults: .standard), launching: true)
    private var isQuitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sessions.finishLaunching()
        sessions.mcpBridge.observeSetting()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        sessions.openFiles(urls)
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
        EditorSettings.commitPendingEdits()
        let decision = sessions.prepareToQuit(stopExports: {
            let alert = NSAlert()
            alert.messageText = "Stop ongoing work and quit?"
            alert.informativeText = "MPCut will cancel active exports, conversions, and MCP jobs before it quits."
            alert.addButton(withTitle: "Continue Working").toolTip = "Keep MPCut open"
            let quit = alert.addButton(withTitle: "Stop and Quit")
            quit.hasDestructiveAction = true
            quit.toolTip = "Stop work and quit"
            return alert.runModal() != .alertFirstButtonReturn
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
