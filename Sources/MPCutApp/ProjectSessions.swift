import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectSession: ObservableObject {
    static let windowID = "project"
    let id: UUID
    let editor: EditorModel
    let multicam: MulticamEditorModel
    @Published var isMulticam = false
    weak var window: NSWindow?

    init(id: UUID, preferences: EditorPreferences) {
        self.id = id
        editor = EditorModel(preferences: preferences)
        multicam = MulticamEditorModel(preferences: preferences)
    }

    func canStartMulticam(accepting panel: NSWindow? = nil) -> Bool {
        // AppKit may still report the accepted picker as attached in its completion.
        if let sheet = window?.attachedSheet, sheet !== panel { return false }
        if isMulticam { return !multicam.hasSession }
        return editor.isEmpty && !editor.isBusy && editor.alert == nil
    }

    /// An editor that is importing or exporting queues the files and adds them when it is idle.
    var canReceiveMedia: Bool {
        !isMulticam && editor.alert == nil && window?.attachedSheet == nil
    }

    /// Whether Add Clips can show its picker in this window now.
    var canChooseMedia: Bool { canReceiveMedia && !editor.isBusy }

    var isExporting: Bool { editor.isExporting || multicam.isExporting }

    func confirmClose() -> Bool {
        guard window?.attachedSheet == nil else { return false }
        if isMulticam { return multicam.confirmClose() }
        return !editor.isExporting && !editor.isSavingSidecars
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
            if isMulticam { MulticamPreviewView(preview: multicam) }
            else { PreviewView(preview: ordinary) }
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
    private weak var commandWindow: NSWindow?
    private var commandModeObserver: AnyCancellable?
    private var focusObservers = Set<AnyCancellable>()
    let preferences: EditorPreferences
    private(set) var sessions: [UUID: ProjectSession] = [:]
    private(set) var closingEditors: [UUID: EditorModel] = [:]
    private var closedMulticamOperations: [UUID: [() -> Void]] = [:]
    private var openWindow: ((UUID) -> Void)?
    /// Front to back. Finder can deliver an open event before any window is key.
    var orderedWindows: () -> [NSWindow] = { NSApp?.orderedWindows ?? [] }
    private var pendingFiles: [URL] = []
    private var addClipsOnOpen: Set<UUID> = []

    init(preferences: EditorPreferences, openWindow: ((UUID) -> Void)? = nil) {
        self.preferences = preferences
        self.openWindow = openWindow
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
        sessions[session.id] = session
        session.window = window
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
        setWindowOpener(openWindow)
        let shouldChooseClips = addClipsOnOpen.remove(session.id) != nil
        guard shouldChooseClips || !pendingFiles.isEmpty else { return }
        // Let the SwiftUI window finish attaching before showing sheets or activating other windows.
        Task { [weak self, weak session] in
            guard let self else { return }
            let files = self.pendingFiles
            self.pendingFiles = []
            let attached = session.flatMap { $0.window != nil ? $0 : nil }
            self.route(files, in: attached)
            if shouldChooseClips { attached?.editor.chooseFiles() }
        }
    }

    func windowClosed(_ session: ProjectSession) {
        let id = session.id
        guard sessions[id] === session else { return }
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
        guard sessions.isEmpty, let openWindow else { return false }
        _ = newWindow(openWindow)
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
        panel.title = "Open Multicam Project"
        panel.allowedContentTypes = [.json]
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

    private func setWindowOpener(_ action: OpenWindowAction) {
        openWindow = { action(id: ProjectSession.windowID, value: $0) }
    }

    private func present(_ panel: NSOpenPanel, in session: ProjectSession?, onAccept: @escaping (NSOpenPanel) -> Void) {
        ProjectPanels.present(panel, in: session?.window) { accepted in
            if accepted { onAccept(panel) }
        }
    }

    func openFiles(_ urls: [URL], in session: ProjectSession? = nil) {
        let files = urls.filter(\.isFileURL)
        guard openWindow != nil else {
            pendingFiles.append(contentsOf: files)
            return
        }
        route(files, in: session ?? focusedSession ?? frontSession)
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
        let source = session.flatMap { sessions[$0.id] === $0 ? $0 : nil }
        for file in projects { openProject(file, in: source) }
        return media
    }

    private static func isProject(_ resolved: URL) -> Bool {
        isMulticamDocument(resolved) || isMulticamDocument(resolved.resolvingSymlinksInPath())
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
            let target = source.flatMap { $0.canReceiveMedia ? $0 : nil } ?? newWindow(openWindow)
            target.editor.openFiles(media)
            target.window?.makeKeyAndOrderFront(nil)
        }
        for file in projects { openProject(file, in: source) }
    }

    func project(at url: URL, excluding excluded: ProjectSession? = nil) -> ProjectSession? {
        sessions.values.first { session in
            guard session !== excluded else { return false }
            let urls = [session.multicam.openingProjectURL, session.multicam.projectURL].compactMap { $0 }
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

    private func openProject(_ url: URL, in source: ProjectSession?, accepting panel: NSWindow? = nil) {
        let url = Self.resolveAlias(url).resolvingSymlinksInPath()
        if let existing = project(at: url) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        multicamTarget(in: source, accepting: panel)?.multicam.openProject(url)
    }

    private func multicamTarget(in source: ProjectSession?, accepting panel: NSWindow?) -> ProjectSession? {
        guard let openWindow else { return nil }
        let target: ProjectSession
        if let source, sessions[source.id] === source, source.canStartMulticam(accepting: panel) {
            target = source
        } else {
            target = newWindow(openWindow)
        }
        target.isMulticam = true
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

    var body: some View {
        Group {
            if session.isMulticam {
                MulticamEditorView(model: multicam)
                    .frame(minWidth: 810, minHeight: 565)
                    .onChange(of: !multicam.hasSession && multicam.notice == nil, initial: true) { _, isEmpty in
                        if isEmpty { session.isMulticam = false }
                    }
            } else {
                EditorView(editor: editor, multicam: multicam, addMulticam: { sessions.chooseMulticamSources(in: session) })
                    .frame(minWidth: 730, minHeight: max(510, 385 + editor.timelineThumbnailHeight +
                        (editor.isAudioOnly || editor.audioTracks.isEmpty ? 0 : (editor.largeThumbnails ? 64 : 32))))
            }
        }
        .background(ProjectWindowBinding(session: session, sessions: sessions, openWindow: openWindow))
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

private struct ProjectWindowBinding: NSViewRepresentable {
    let session: ProjectSession
    let sessions: ProjectSessions
    let openWindow: OpenWindowAction

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.session = session
        view.sessions = sessions
        view.openWindow = openWindow
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.applyDocumentState()
    }

    final class WindowView: NSView, NSWindowDelegate {
        weak var session: ProjectSession?
        weak var sessions: ProjectSessions?
        var openWindow: OpenWindowAction?
        private weak var upstream: NSWindowDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let session, let openWindow else { return }
            sessions?.register(session, window: window, openWindow: openWindow)
            applyDocumentState()
        }

        func applyDocumentState() {
            guard let window, let session else { return }
            if window.delegate !== self {
                upstream = window.delegate
                window.delegate = self
            }
            let documentURL = session.multicam.projectURL
            if window.representedURL != documentURL { window.representedURL = documentURL }
            let edited = session.multicam.isChanged
            if window.isDocumentEdited != edited { window.isDocumentEdited = edited }
            session.applyCloseState()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard session?.confirmClose() != false else { return false }
            return upstream?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            if let session { sessions?.windowClosed(session) }
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
            if upstream?.responds(to: selector) == true { return upstream }
            return super.forwardingTarget(for: selector)
        }
    }
}

@MainActor
final class EditorApplication: NSObject, NSApplicationDelegate {
    let sessions = ProjectSessions(preferences: EditorPreferences(defaults: .standard))
    private var isQuitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        sessions.openFiles(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !sessions.reopen()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        let decision = sessions.prepareToQuit(stopExports: {
            let alert = NSAlert()
            alert.messageText = "Stop exporting and quit?"
            alert.informativeText = "Quitting cancels exports in progress."
            alert.addButton(withTitle: "Continue Exporting")
            alert.addButton(withTitle: "Stop Exporting and Quit").hasDestructiveAction = true
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
        let confirmClose = ask ?? { $0.multicam.confirmClose() }
        let projects = Array(sessions.values)
        if let sheet = projects.compactMap({ $0.window?.attachedSheet }).first {
            sheet.makeKeyAndOrderFront(nil)
            return .cancel
        }
        if projects.contains(where: \.isExporting), !stopExports() { return .cancel }
        var confirmed = Set<UUID>()
        let confirm = { (idleOnly: Bool) -> Bool in
            for session in projects where session.isMulticam && !confirmed.contains(session.id) {
                if idleOnly && session.multicam.isBusy { continue }
                if session.multicam.isChanged { session.window?.makeKeyAndOrderFront(nil) }
                if !confirmClose(session) { return false }
                confirmed.insert(session.id)
            }
            return true
        }
        // Ask about unsaved projects before stopping anything, so Cancel leaves every other window working.
        guard confirm(true) else { return .cancel }
        var pending = 0
        let cleaned = {
            pending -= 1
            guard pending == 0 else { return }
            reply(confirm(false))
        }
        for project in projects {
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
        return confirm(false) ? .now : .cancel
    }
}

// Save As and the CLI both allow a plain .json filename. Peek only at the
// opening token so a movie stored under that extension still reaches the probe.
func isMulticamDocument(_ url: URL) -> Bool {
    if url.lastPathComponent.lowercased().hasSuffix(".multicam.json") { return true }
    guard url.pathExtension.lowercased() == "json",
          let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let prefix = try? handle.read(upToCount: 256), !prefix.isEmpty else { return false }
    let bytes = prefix.starts(with: [0xEF, 0xBB, 0xBF]) ? prefix.dropFirst(3) : prefix[...]
    return bytes.first(where: { ![9, 10, 13, 32].contains($0) }).map { $0 == 0x7B } ?? true
}

