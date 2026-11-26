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
}

struct SettingsWindow: View {
    static let sidebarWidth: CGFloat = 210
    @ObservedObject var preferences: EditorPreferences
    let cacheContext: @MainActor () -> SidecarClearContext
    /// The stores the Storage page measures and clears. Tests pass temporary folders.
    var storageLocations: StorageLocations = .standard
    @State private var query = ""
    /// The page the sidebar shows as selected. The stored page follows it on the next turn of the run loop, so the
    /// sidebar's table never sees a model change from inside its own selection callback.
    @State private var sidebarSelection: SettingsPage?
    /// The search result chosen last, shown highlighted in the results.
    @State private var chosen: String?
    @State private var highlight: String?
    @State private var highlightReset: Task<Void, Never>?
    /// Transcriberrr's last check, kept for the life of the window: the Transcripts page is rebuilt on every visit.
    @StateObject private var transcriberrr = TranscriberrrStatus()

    private var results: [SettingsRow] { SettingsRow.search(query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        // A plain stack, not NavigationSplitView: its toolbar and collapse behavior in a Settings scene vary by release.
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                SettingsSearchField(query: $query) { if let first = results.first { choose(first) } }
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
        .frame(minWidth: SettingsWindowHooks.minimumSize.width, idealWidth: SettingsWindowHooks.initialSize.width, maxWidth: .infinity,
               minHeight: SettingsWindowHooks.minimumSize.height, idealHeight: SettingsWindowHooks.initialSize.height,
               maxHeight: .infinity)
        .background(SettingsWindowHooks())
        .onChange(of: query) { _, _ in chosen = nil }
        .onChange(of: preferences.settingsPage) { _, page in
            // A deep link, a search result or Restore Defaults moved the page: the sidebar follows.
            if sidebarSelection != nil, sidebarSelection != page { sidebarSelection = page }
        }
    }

    @ViewBuilder private var sidebar: some View {
        if !searching {
            List(selection: Binding(
                get: { sidebarSelection ?? preferences.settingsPage },
                set: { page in
                    // Clicking empty space deselects; the page stays.
                    guard let page, page != (sidebarSelection ?? preferences.settingsPage) else { return }
                    sidebarSelection = page
                    DispatchQueue.main.async { if preferences.settingsPage != page { preferences.settingsPage = page } }
                }
            )) {
                ForEach(SettingsPage.allCases) { page in
                    SettingsSidebarLabel(page: page)
                        .tag(page)
                        .accessibilityIdentifier("settings.page." + page.rawValue)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Settings pages")
            .accessibilityIdentifier("settings.pages")
        } else if results.isEmpty {
            Text("No Results").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("settings.results.none")
        } else {
            // Buttons in a scroll view, not a second List: nothing here is a table whose selection a choice could write.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { row in
                        SettingsResultButton(row: row, isChosen: chosen == row.id) { choose(row) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .accessibilityElement(children: .contain)
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
        case .transcripts: SettingsTranscriptsPage(preferences: preferences, status: transcriberrr)
        case .export: SettingsExportPage(preferences: preferences)
        case .storage: SettingsStoragePage(preferences: preferences, cacheContext: cacheContext, locations: storageLocations)
        case .automation: SettingsAutomationPage(preferences: preferences)
        }
    }

    /// Marks a search result chosen and opens it on the next turn of the run loop, outside any view update.
    private func choose(_ row: SettingsRow) {
        chosen = row.id
        DispatchQueue.main.async { reveal(row) }
    }

    /// Opens a search result's page, scrolls to its control, highlights it briefly and focuses it where it can take focus.
    private func reveal(_ row: SettingsRow) {
        if preferences.settingsPage != row.page { preferences.settingsPage = row.page }
        if sidebarSelection != nil { sidebarSelection = row.page }
        highlight = nil
        highlightReset?.cancel()
        highlightReset = Task { @MainActor in
            // The page's controls need one pass to exist before they can scroll into view and take focus.
            await Task.yield()
            highlight = row.id
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            highlight = nil
        }
    }
}

/// A sidebar row: a fixed-width icon column, so every label starts at the same place, and the same height for every row.
/// Its look comes from the List's selection alone.
private struct SettingsSidebarLabel: View {
    let page: SettingsPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.symbol)
                .symbolRenderingMode(.monochrome)
                .frame(width: 20, height: 16)
        }
        .frame(height: 22)
    }
}

/// One search result. The chosen one stays highlighted.
private struct SettingsResultButton: View {
    let row: SettingsRow
    let isChosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(2)
                Text(row.page.title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isChosen ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens \(row.page.title) settings.")
        .accessibilityIdentifier("settings.result." + row.id)
        .help("Open “\(row.title)” in \(row.page.title).")
    }
}

extension SettingsWindow {
    /// Commits a typed number before the app quits.
    @MainActor static func commitPendingEdits() { SettingsEdits.commitPending() }

    /// The scene's open action, captured by the first window that has one. AppKit code has no environment to read it from.
    @MainActor private static var opener: OpenSettingsAction?

    @MainActor static func register(_ action: OpenSettingsAction) { opener = action }

    /// The one deep link into Settings, opening it on a named page. The MCP `show_settings` action uses it.
    @MainActor static func open(_ page: SettingsPage, preferences: EditorPreferences, using action: OpenSettingsAction? = nil) {
        preferences.settingsPage = page
        if let action = action ?? opener {
            action()
        } else {
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

/// Every page with something to restore ends with this. It asks first, names what changes, also in open projects, from
/// the factory table that performs the restore, and writes factory values through the setters.
struct SettingsRestoreDefaults: View {
    let page: SettingsPage
    @ObservedObject var preferences: EditorPreferences
    @State private var confirming = false

    var body: some View {
        let unchanged = preferences.hasFactoryValues(on: page)
        // A section with no rows and the button as its footer: the button sits below the last group, not alone in a box.
        Section {} footer: {
            HStack {
                Spacer()
                // A click here leaves a typed number alone (see `SettingsWindowHooks.handle`): Restore drops it.
                Button("Restore Defaults…") { confirming = true }
                    .background(SettingsDropsTypedText())
                    .disabled(unchanged)
                    .accessibilityIdentifier("settings.restore." + page.rawValue)
                    .help(unchanged ? "Every setting on this page already has its factory value."
                                    : "Restore this page’s settings to their factory values. MPCut asks first.")
            }
        }
        .confirmationDialog(SettingsRestoreSummary.title(for: page), isPresented: $confirming) {
            // The restore runs on the next turn of the run loop, after the dialog has closed, outside the button's
            // action. (The reentrant-layout fault a reset switch logged came from the switch's animation, not from
            // here: see `settingsRow`.)
            Button("Restore Defaults", role: .destructive) {
                DispatchQueue.main.async { Self.restore(page, preferences: preferences) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsRestoreSummary.message(for: page, preferences: preferences))
        }
    }

    /// Restoring wins over a number typed on the page and not yet committed: that text is dropped first, so
    /// closing the window afterwards cannot write it back.
    static func restore(_ page: SettingsPage, preferences: EditorPreferences) {
        SettingsEdits.discardPending(on: page)
        preferences.restoreDefaults(on: page)
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
            if SettingsRestoreSummary.isRestorable(page) {
                SettingsRestoreDefaults(page: page, preferences: preferences)
            }
        }
        .formStyle(.grouped)
        // Every toggle is a switch, also one inside a `SettingsLabeledControl`, where a form would draw a checkbox.
        .toggleStyle(.switch)
        .accessibilityIdentifier("settings.form." + page.rawValue)
        // Range notices float above the sections, which clip what a row draws outside them. The layer comes after the
        // form's identifier, so a notice keeps its own.
        .overlayPreferenceValue(SettingsNoticeKey.self) { SettingsNoticeLayer(notices: $0) }
    }
}
