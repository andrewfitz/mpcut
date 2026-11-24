import AppKit
import MPCutCore
import SwiftUI

extension Notification.Name {
    static let sidecarStorageDidChange = Notification.Name("MPCutSidecarStorageDidChange")
    static let sidecarCachesDidClear = Notification.Name("MPCutSidecarCachesDidClear")
}

struct SidecarClearContext: Sendable {
    var sources = Set<URL>()
    var protected = Set<URL>()
    var projects = Set<URL>()

    init() {}

    @MainActor init(sessions: ProjectSessions) {
        for session in sessions.sessions.values {
            for path in session.editor.mcpOutputProtectedMedia.keys {
                sources.insert(URL(fileURLWithPath: path))
            }
            for path in session.multicam.protectedMediaPaths.keys {
                sources.insert(URL(fileURLWithPath: path))
            }
            projects.formUnion([session.editor.projectURL, session.editor.openingProjectURL,
                                session.multicam.projectURL, session.multicam.openingProjectURL]
                .compactMap { $0 }.filter { !ProjectDraft.isManaged($0) })
            protected.formUnion([session.editor.draft.url, session.multicam.draft.url].compactMap { $0 })
        }
        protected.formUnion(sources)
        protected.formUnion(projects)
    }
}

private extension SidecarStorageMode {
    var settingsTitle: String {
        switch self {
        case .media: "Next to media"
        case .project: "In project folder"
        case .disk: "On cache disk"
        }
    }
}

@MainActor
private func chooseSidecarFolder(title: String, initial: URL? = nil, allowCreation: Bool,
                                 selected: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = allowCreation
    panel.directoryURL = initial
    ProjectPanels.present(panel, in: NSApp.keyWindow, fromSheet: true) { accepted in
        if accepted, let url = panel.url { selected(url) }
    }
}

@MainActor
struct SidecarStorageSettings: View {
    @ObservedObject var preferences: EditorPreferences
    let cacheContext: @MainActor () -> SidecarClearContext

    @State private var mode: SidecarStorageMode = .media
    @State private var disk: URL?
    @State private var available = false
    @State private var refreshID = UUID()
    @State private var loaded = false
    @State private var saving = false
    @State private var showClear = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Save and reuse analysis", isOn: $preferences.useAnalysisSidecars)
                .accessibilityLabel("Save and reuse analysis")
                .help("Reuse saved media analysis")
            Picker("Save new sidecars", selection: Binding(get: { mode }, set: { selectMode($0) })) {
                ForEach(SidecarStorageMode.allCases, id: \.self) { location in
                    Text(location.settingsTitle).tag(location)
                }
            }
            .disabled(!loaded || saving)
            .accessibilityLabel("Save new sidecars")
            .accessibilityIdentifier("sidecars.storage-location")
            if mode == .disk {
                LabeledContent("Shared cache folder") {
                    VStack(alignment: .trailing, spacing: 3) {
                        if let disk {
                            Text(disk.path).lineLimit(1).truncationMode(.middle).help(disk.path)
                            Label(available ? "Available" : "Unavailable",
                                  systemImage: available ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No folder selected").foregroundStyle(.secondary)
                        }
                        Button(disk == nil ? "Choose Folder…" : "Change Folder…", action: chooseDisk).disabled(saving)
                    }
                }
            }
            Button("Clear Caches…") { showClear = true }
        } header: {
            Text("Analysis sidecars")
        } footer: {
            SettingsFootnote(locationFootnote)
        }
        .task(id: refreshID) {
            let state = await Self.readLocation()
            guard !Task.isCancelled else { return }
            apply(state)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshID = UUID() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshID = UUID() }
        .sheet(isPresented: $showClear) { SidecarClearSheet(context: cacheContext) }
        .alert("Couldn’t Save Sidecar Location", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var locationFootnote: String {
        let reads = "MPCut reads the latest compatible analysis from any location."
        switch mode {
        case .media: return reads
        case .project: return "Save the project to write new analysis to its folder. " + reads
        case .disk where !available: return "Reconnect the disk or change the shared folder to save new analysis. " + reads
        case .disk: return "All projects save new analysis to this folder. " + reads
        }
    }

    private nonisolated static func readLocation() async -> (mode: SidecarStorageMode, disk: URL?, available: Bool) {
        SidecarLocations.settingsSnapshot()
    }

    private func apply(_ state: (mode: SidecarStorageMode, disk: URL?, available: Bool)) {
        let changed = mode != state.mode || disk != state.disk || available != state.available
        mode = state.mode
        disk = state.disk
        available = state.available
        loaded = true
        if changed {
            NotificationCenter.default.post(name: .sidecarStorageDidChange, object: nil)
        }
    }

    private func selectMode(_ mode: SidecarStorageMode) {
        if mode == .disk && disk == nil {
            chooseDisk()
        } else {
            saveLocation { try SidecarLocations.setMode(mode) }
        }
    }

    private func chooseDisk() {
        chooseSidecarFolder(title: "Choose a cache folder for all projects", initial: disk, allowCreation: true) { folder in
            saveLocation { try SidecarLocations.chooseDisk(folder, selecting: true) }
        }
    }

    private func saveLocation(_ save: @escaping @Sendable () throws -> Void) {
        guard !saving else { return }
        saving = true
        Task {
            do {
                let state = try await Self.writeLocation(save)
                apply(state)
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
            refreshID = UUID()
        }
    }

    private nonisolated static func writeLocation(_ save: @Sendable () throws -> Void) async throws
        -> (mode: SidecarStorageMode, disk: URL?, available: Bool) {
        try save()
        return SidecarLocations.settingsSnapshot()
    }
}

@MainActor
private struct SidecarClearSheet: View {
    let context: @MainActor () -> SidecarClearContext
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []
    @State private var entries: [SidecarCacheEntry] = []
    @State private var scope: SidecarStorageMode?
    @State private var root: String?
    @State private var revision = UUID()
    @State private var wholeSidecars = false
    @State private var loading = true
    @State private var clearing = false
    @State private var confirmRemoval = false
    @State private var result: SidecarClearResult?

    private var locationEntries: [SidecarCacheEntry] { entries.filter { scope == nil || $0.location == scope } }
    private var rootEntries: [SidecarCacheEntry] {
        var seen: Set<String> = []
        return locationEntries.filter { seen.insert($0.rootIdentity).inserted }
    }
    private var selected: [SidecarCacheEntry] { locationEntries.filter { root == nil || $0.rootIdentity == root } }
    private var eligible: [SidecarCacheEntry] {
        selected.filter { $0.issue == nil && (wholeSidecars || $0.rebuildableBytes > 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clear Caches").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let result {
                let count = result.cleared.count
                let summary = wholeSidecars ? "Removed \(sidecarCount(count))" : "Cleared analysis from \(sidecarCount(count))"
                Text("\(summary). Reclaimed \(size(result.reclaimedBytes)).")
                if !result.skippedEntries.isEmpty {
                    Text("Skipped locations may still supply cached results when available.")
                }
                let skippedIDs = Set(result.skippedEntries.map(\.id))
                let clearedEntries = Dictionary(grouping: selected.filter { !skippedIDs.contains($0.id) }, by: \.url)
                let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
                let duplicates = duplicateSourceNames
                List {
                    if !result.cleared.isEmpty {
                        Section(wholeSidecars ? "Removed" : "Analysis cleared") {
                            ForEach(result.cleared.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                                if let entry = clearedEntries[url]?.first {
                                    cacheIdentity(entry, duplicates: duplicates)
                                } else {
                                    pathLabel(url)
                                }
                            }
                        }
                    }
                    if !result.skippedEntries.isEmpty {
                        Section("Skipped (\(result.skippedEntries.count))") {
                            let paths = Dictionary(grouping: result.skippedEntries, by: \.url)
                            let cleared = Set(result.cleared)
                            ForEach(result.skippedEntries, id: \.id) { skipped in
                                VStack(alignment: .leading) {
                                    if let entry = byID[skipped.id] {
                                        cacheIdentity(entry, duplicates: duplicates)
                                    } else {
                                        pathLabel(skipped.url)
                                    }
                                    if (paths[skipped.url]?.count ?? 0) > 1 || cleared.contains(skipped.url) {
                                        Text(skipped.rootIdentity).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(skipped.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                preview.disabled(clearing)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 420)
        .interactiveDismissDisabled(clearing)
        .task(id: revision) {
            loading = true
            let current = context()
            let found = await Self.discover(folders, context: current)
            guard !Task.isCancelled else { return }
            entries = found
            if let root, !rootEntries.contains(where: { $0.rootIdentity == root }) { self.root = nil }
            loading = false
        }
        .alert("Remove \(sidecarCount(eligible.count))?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Sidecars", role: .destructive, action: clear)
        } message: {
            Text("This permanently deletes the files, including any saved edits, recognition results and resumable scans they contain.")
        }
    }

    @ViewBuilder private var preview: some View {
        HStack {
            Picker("Location", selection: $scope) {
                Text("All known locations").tag(nil as SidecarStorageMode?)
                ForEach(SidecarStorageMode.allCases, id: \.self) { mode in
                    Text(mode.settingsTitle).tag(Optional(mode))
                }
            }
            .accessibilityLabel("Location")
            .accessibilityIdentifier("sidecars.clear-location")
            .onChange(of: scope) { _, _ in root = nil }
            Spacer()
            Button("Scan Folder…") {
                chooseSidecarFolder(title: "Find sidecars in a folder", allowCreation: false) { url in
                    folders.removeAll { $0 == url }
                    folders.append(url)
                    loading = true
                    revision = UUID()
                }
            }
            .help("Search this folder and its subfolders for additional sidecars")
        }
        let roots = rootEntries
        if scope != nil && roots.count > 1 {
            let paths = Dictionary(grouping: roots, by: \.rootURL)
            Picker("Folder", selection: $root) {
                Text("All folders").tag(nil as String?)
                ForEach(roots, id: \.rootIdentity) { entry in
                    let sharedPath = (paths[entry.rootURL]?.count ?? 0) > 1
                    Text(sharedPath ? "\(entry.rootURL.path) (\(entry.rootIdentity))" : entry.rootURL.path)
                        .lineLimit(1).truncationMode(.middle)
                        .tag(Optional(entry.rootIdentity))
                }
            }
            .help(roots.first { $0.rootIdentity == root }?.rootURL.path ?? "Include every folder in this location")
        }
        Toggle("Remove entire sidecars", isOn: $wholeSidecars)
            .accessibilityLabel("Remove entire sidecars")
            .accessibilityIdentifier("sidecars.remove-whole")
        if wholeSidecars {
            Text("Includes saved edits, recognition results and resumable scans in the listed sidecars.")
                .font(.callout)
        } else {
            Text("Clears rebuildable analysis and keeps saved edits, recognition results and resumable scans.")
                .font(.callout)
        }
        if loading {
            ProgressView("Finding sidecars…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selected.isEmpty {
            Text("No known sidecars in this location. Use Scan Folder to find older caches.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let duplicates = duplicateSourceNames
            List {
                ForEach(SidecarStorageMode.allCases, id: \.self) { mode in
                    let group = selected.filter { $0.location == mode }
                    if !group.isEmpty {
                        Section(mode.settingsTitle) {
                            ForEach(group) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline) {
                                        cacheIdentity(entry, duplicates: duplicates, showLocation: false)
                                        Spacer()
                                        if entry.issue == nil {
                                            Text(size(wholeSidecars ? entry.bytes : entry.rebuildableBytes))
                                                .monospacedDigit().fixedSize()
                                        }
                                    }
                                    if let issue = entry.issue {
                                        Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                                    } else if !entry.retained.isEmpty {
                                        Text((wholeSidecars ? "Also removes " : "Keeps ") + entry.retained.joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
        Divider()
        HStack {
            if clearing {
                ProgressView("Clearing…").controlSize(.small)
            } else if !loading {
                let skipped = selected.filter { $0.issue != nil }.count
                let bytes = eligible.reduce(Int64.zero) { $0 + (wholeSidecars ? $1.bytes : $1.rebuildableBytes) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sidecarCount(eligible.count)) to \(wholeSidecars ? "remove" : "clear")")
                    Text(skipped > 0 ? "Estimated \(size(bytes)) · \(skipped) skipped" : "Estimated \(size(bytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(wholeSidecars ? "Remove Sidecars…" : "Clear Analysis", role: .destructive) {
                if wholeSidecars { confirmRemoval = true } else { clear() }
            }
            .disabled(loading || eligible.isEmpty)
        }
    }

    private func clear() {
        guard !clearing else { return }
        let current = context(), whole = wholeSidecars
        let chosen = selected.filter { whole || $0.issue != nil || $0.rebuildableBytes > 0 }
        clearing = true
        Task {
            let outcome = await Self.remove(chosen, whole: whole, protected: current.protected)
            let cleared = Set(outcome.cleared)
            let sources = Set(chosen.filter { $0.issue == nil && cleared.contains($0.url) }.map(\.source))
            if !sources.isEmpty {
                NotificationCenter.default.post(name: .sidecarCachesDidClear, object: sources, userInfo: ["wholeSidecars": whole])
            }
            result = outcome
            clearing = false
        }
    }

    private nonisolated static func discover(_ folders: [URL], context: SidecarClearContext) async -> [SidecarCacheEntry] {
        SidecarCacheCleaner.preview(scanning: folders, protected: context.protected, sources: Array(context.sources),
                                   projects: Array(context.projects))
    }

    private nonisolated static func remove(_ entries: [SidecarCacheEntry], whole: Bool,
                                           protected: Set<URL>) async -> SidecarClearResult {
        SidecarCacheCleaner.clear(entries, wholeSidecars: whole, protected: protected)
    }

    private var duplicateSourceNames: Set<String> {
        let sources = Set(selected.map(\.source))
        let grouped = Dictionary(grouping: sources, by: \.lastPathComponent)
        return Set(grouped.compactMap { $0.value.count > 1 ? $0.key : nil })
    }

    private func cacheIdentity(_ entry: SidecarCacheEntry, duplicates: Set<String>, showLocation: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.source.lastPathComponent)
                .lineLimit(1).truncationMode(.middle).help(entry.source.path)
            if duplicates.contains(entry.source.lastPathComponent), entry.location != .media {
                Text("Source: \(entry.source.deletingLastPathComponent().path)")
                    .lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
                    .help(entry.source.path)
            }
            let folder = entry.location == .media ? entry.source.deletingLastPathComponent() : entry.rootURL
            Text(showLocation ? "\(entry.location.settingsTitle) · \(folder.path)" : folder.path)
                .lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
                .help(entry.url.path)
                .accessibilityValue(entry.url.path)
        }
    }

    private func pathLabel(_ url: URL) -> some View {
        Text(url.path).lineLimit(2).truncationMode(.middle).help(url.path)
            .textSelection(.enabled)
    }

    private func sidecarCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "sidecar" : "sidecars")"
    }

    private func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
