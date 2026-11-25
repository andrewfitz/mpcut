import AppKit
import MPCutCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, editing, playback, media, transcripts, export, storage, automation

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .editing: "Editing"
        case .playback: "Playback & Monitors"
        case .media: "Media & Analysis"
        case .transcripts: "Transcripts"
        case .export: "Export"
        case .storage: "Storage"
        case .automation: "Automation"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editing: "scissors"
        case .playback: "play.rectangle"
        case .media: "waveform"
        case .transcripts: "text.quote"
        case .export: "square.and.arrow.up"
        case .storage: "internaldrive"
        case .automation: "terminal"
        }
    }

    /// What Restore Defaults changes beyond Settings, named before it asks.
    var restoreMessage: String {
        switch self {
        case .general: "The undo limit keeps its value. Warnings that were turned off ask again."
        case .editing: "Snapping, source time ticks, enlarged previews, the panel position and the track label width change in every open window."
        case .playback: "Scrub audio, mute, volume and the Force SDR and clean feed choices change in every open window."
        case .media: "Watching recordings changes in open projects, and new silence values recalculate pauses in open projects."
        case .transcripts: "Open sheets keep their values. New transcription jobs and reviews start from the factory values."
        case .export: "The movie export mode changes in every open sequence editor. Open export panels keep their choices."
        case .storage: "Reusing analysis turns on again for open projects. The cutcache location keeps its value."
        case .automation: "Local MCP control and the agent permissions keep their values."
        }
    }
}

struct SettingsWindow: View {
    static let sidebarWidth: CGFloat = 210
    @ObservedObject var preferences: EditorPreferences
    let cacheContext: @MainActor () -> SidecarClearContext
    @State private var query = ""
    @State private var highlight: String?
    @State private var highlightReset: Task<Void, Never>?

    private var results: [SettingsRow] { SettingsRow.search(query) }

    var body: some View {
        // A plain stack, not NavigationSplitView: its toolbar and collapse behavior in a Settings scene vary by release.
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                SettingsSearchField(query: $query) { if let first = results.first { reveal(first) } }
                    .padding([.horizontal, .top], 10)
                sidebar
            }
            .frame(width: Self.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            ScrollViewReader { proxy in
                page(preferences.settingsPage)
                    .id(preferences.settingsPage)
                    .environment(\.settingsHighlight, highlight)
                    .onChange(of: highlight) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
    }

    @ViewBuilder private var sidebar: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            List(selection: Binding(get: { preferences.settingsPage }, set: { if let page = $0 { preferences.settingsPage = page } })) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol)
                        .tag(page)
                        .accessibilityIdentifier("settings.page." + page.rawValue)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Settings pages")
            .accessibilityIdentifier("settings.pages")
        } else if results.isEmpty {
            Text("No Results").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: Binding(get: { nil as SettingsRow? }, set: { if let row = $0 { reveal(row) } })) {
                ForEach(results) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).lineLimit(2)
                        Text(row.page.title).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(row)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens \(row.page.title) settings")
                    .accessibilityIdentifier("settings.result." + row.id)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Search results")
            .accessibilityIdentifier("settings.results")
        }
    }

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .general: SettingsGeneralPage(preferences: preferences)
        case .editing: SettingsEditingPage(preferences: preferences)
        case .playback: SettingsPlaybackPage(preferences: preferences)
        case .media: SettingsMediaPage(preferences: preferences)
        case .transcripts: SettingsTranscriptsPage(preferences: preferences)
        case .export: SettingsExportPage(preferences: preferences)
        case .storage: SettingsStoragePage(preferences: preferences, cacheContext: cacheContext)
        case .automation: SettingsAutomationPage(preferences: preferences)
        }
    }

    /// Opens a search result's page and focuses its control.
    private func reveal(_ row: SettingsRow) {
        preferences.settingsPage = row.page
        highlight = nil
        highlightReset?.cancel()
        highlightReset = Task { @MainActor in
            // The page's controls need one pass to exist before they can take focus.
            await Task.yield()
            highlight = row.id
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            highlight = nil
        }
    }
}

extension SettingsWindow {
    /// Commits a typed number before the app quits.
    @MainActor static func commitPendingEdits() { SettingsEdits.commitPending() }

    /// The scene's open action, captured by the first window that has one. AppKit code has no environment to read it from.
    @MainActor private static var opener: OpenSettingsAction?

    @MainActor static func register(_ action: OpenSettingsAction) { opener = action }

    /// The one deep link into Settings: menus, help, error text and tests open a named page through it.
    @MainActor static func open(_ page: SettingsPage, preferences: EditorPreferences, using action: OpenSettingsAction? = nil) {
        preferences.settingsPage = page
        if let action = action ?? opener {
            action()
        } else {
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

/// Every page ends with this. It asks first, names what changes in open projects and writes factory values through the setters.
struct SettingsRestoreDefaults: View {
    let page: SettingsPage
    @ObservedObject var preferences: EditorPreferences
    @State private var confirming = false

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button("Restore Defaults…") { confirming = true }
                    .disabled(preferences.hasFactoryValues(on: page))
                    .accessibilityIdentifier("settings.restore." + page.rawValue)
                    .help("Restore this page's factory values")
            }
        }
        .confirmationDialog("Restore \(page.title) settings to their defaults?", isPresented: $confirming) {
            Button("Restore Defaults", role: .destructive) { preferences.restoreDefaults(on: page) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(page.restoreMessage + " A value supplied as a launch argument applies again at the next launch.")
        }
    }
}

/// The grouped form every page uses.
struct SettingsForm<Content: View>: View {
    let page: SettingsPage
    let preferences: EditorPreferences
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
            SettingsRestoreDefaults(page: page, preferences: preferences)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.form." + page.rawValue)
    }
}
