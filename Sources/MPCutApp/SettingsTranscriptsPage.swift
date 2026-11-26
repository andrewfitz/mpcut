import AppKit
import MPCutCore
import SwiftUI

extension SettingsRow {
    /// Transcriberrr's status, its engines and Open Transcriberrr.
    static let transcriberrrStatus = SettingsRow("settings.transcripts.transcriberrr", .transcripts, "Transcriberrr",
        keywords: ["status", "engines", "helper", "open", "installed"])
}

struct SettingsTranscriptsPage: View {
    @ObservedObject var preferences: EditorPreferences
    /// Owned by the Settings window when it passes one, so a finished check outlives the page.
    @StateObject private var status: TranscriberrrStatus
    /// The Transcriberrr app Open Transcriberrr opens, looked up when the helper or its check changes, not on every update.
    @State private var application: URL?

    @MainActor init(preferences: EditorPreferences, status: TranscriberrrStatus? = nil) {
        self.preferences = preferences
        _status = StateObject(wrappedValue: status ?? TranscriberrrStatus())
    }

    var body: some View {
        SettingsForm(page: .transcripts, preferences: preferences) {
            Section {
                transcriberrr
                LabeledContent(SettingsRow.helperLocation.title) {
                    VStack(alignment: .trailing, spacing: 4) {
                        if preferences.transcriptHelperPath.isEmpty {
                            Text("Automatic").foregroundStyle(.secondary)
                                .help("MPCut finds the helper inside Transcriberrr.app.")
                                .accessibilityIdentifier("settings.transcripts.helper.path")
                        } else {
                            SettingsPathText(path: preferences.transcriptHelperPath)
                                .accessibilityIdentifier("settings.transcripts.helper.path")
                        }
                        HStack {
                            if !preferences.transcriptHelperPath.isEmpty {
                                Button("Automatic") { preferences.transcriptHelperPath = "" }
                                    .accessibilityIdentifier("settings.transcripts.helper.automatic")
                                    .help("Find Transcriberrr’s helper automatically, inside Transcriberrr.app.")
                            }
                            Button(preferences.transcriptHelperPath.isEmpty ? "Choose Helper…" : "Change Helper…", action: chooseHelper)
                                .settingsRow(.helperLocation)
                                .help("Choose Transcriberrr’s helper program, the file named transcriberrr inside Transcriberrr.app.")
                        }
                    }
                }
                let engines = Self.engineChoices(preferred: preferences.transcriptEngine, catalog: status.catalog)
                // Each control's own title is its one accessibility label.
                SettingsLabeledControl(SettingsRow.engine.title) {
                    Picker(SettingsRow.engine.title, selection: $preferences.transcriptEngine) {
                        ForEach(engines, id: \.name) { choice in
                            Text(choice.label).tag(choice.name).disabled(!choice.selectable)
                        }
                    }
                    .settingsRow(.engine)
                    // Until Transcriberrr is checked there is only Automatic, and a pop-up with one item seems broken.
                    .disabled(engines.count < 2)
                    .help(engines.count < 2
                          ? "Press Check to list the engines Transcriberrr offers. Until then, new jobs use Automatic: Qwen3, then the first available engine."
                          : "Choose the engine new transcription jobs start with. Automatic uses Qwen3, then the first available engine.")
                }
                if let reason = status.catalog?.unavailableReason(forPreferred: preferences.transcriptEngine) {
                    Text(reason + " New jobs use Automatic until it is available; the preference is kept.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.transcripts.engine.issue")
                }
                Toggle(SettingsRow.speakers.title, isOn: $preferences.identifiesSpeakers)
                    .settingsRow(.speakers)
                    .help("Start new jobs with speaker identification where the engine supports it.")
                Toggle(SettingsRow.downloads.title, isOn: $preferences.downloadsModels)
                    .settingsRow(.downloads)
                    .help("Let new jobs and retries download the models they are missing.")
            } header: {
                Text("Transcription")
            } footer: {
                SettingsFootnote("Job setup starts from these values and can change them for one job. The helper location and engine reach desktop jobs and agents working in an open project; the CLI and file jobs keep their environment variable and Qwen3.")
            }
            Section("Reader") {
                Toggle(SettingsRow.followPlayback.title, isOn: $preferences.followsPlayback)
                    .settingsRow(.followPlayback)
                    .help("Start new windows with the reader following playback.")
                SettingsNumericField(.readerTextSize, value: $preferences.readerTextSize, in: EditorPreferences.readerTextSizeRange,
                                     step: 1, unit: "pt", digits: 1, help: "Type the text size transcript panes start with when they open")
            }
            // Named for transcripts, so they do not read as the Editing and Export pages.
            Section("Transcript editing") {
                Picker(SettingsRow.boundary.title, selection: $preferences.boundaryPolicy) {
                    Text("Nearest media frame").tag(TranscriptEditRequest.BoundaryPolicy.nearestFrame)
                    Text("Copy-safe boundary").tag(TranscriptEditRequest.BoundaryPolicy.copySafe)
                    Text("Exact requested time").tag(TranscriptEditRequest.BoundaryPolicy.exact)
                }
                .settingsRow(.boundary)
                .help("Choose where transcript edits place their cuts.")
                SettingsNumericField(.retainedPause, value: $preferences.retainedPause, in: EditorPreferences.retainedPauseRange,
                                     step: 0.05, unit: "s", help: "Type how much of each pause Tighten keeps")
                SettingsFillerTermsField(preferences: preferences)
            }
            Section("Transcript export") {
                Picker(SettingsRow.exportFormat.title, selection: $preferences.transcriptExportFormat) {
                    Text("Native JSON").tag(TranscriptFormat.json)
                    Text("Readable text").tag(TranscriptFormat.text)
                    Text("SubRip (.srt)").tag(TranscriptFormat.srt)
                    Text("WebVTT (.vtt)").tag(TranscriptFormat.vtt)
                }
                .settingsRow(.exportFormat)
                .help("Choose the format Export Transcript offers first.")
            }
            Section {
                SettingsNumericField(.captionCharacters, value: $preferences.captionLineCharacters,
                                     in: EditorPreferences.captionLineCharacterRange, step: 1,
                                     help: "Type the most characters a caption line holds")
                SettingsNumericField(.captionLines, value: $preferences.captionLines, in: EditorPreferences.captionLineRange, step: 1,
                                     help: "Type the most lines a caption shows at once")
                SettingsNumericField(.captionCue, value: $preferences.captionCueSeconds, in: EditorPreferences.captionCueRange,
                                     step: 0.5, unit: "s", help: "Type the longest time one caption stays on screen")
                Toggle(SettingsRow.captionLabels.title, isOn: $preferences.captionSpeakerLabels)
                    .settingsRow(.captionLabels)
                    .help("Name the speaker in each caption.")
            } header: {
                Text("Captions")
            } footer: {
                SettingsFootnote("Export Captions writes SubRip. These limits apply to desktop exports; the CLI and MCP keep 42 characters, 2 lines, 6 seconds and speaker labels.")
            }
        }
    }

    @ViewBuilder private var transcriberrr: some View {
        LabeledContent(SettingsRow.transcriberrrStatus.title) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.statusText(status.state))
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.transcripts.transcriberrr.status")
                HStack {
                    Button(status.state == .unchecked ? "Check" : "Check Again") {
                        status.check(helperPath: preferences.transcriptHelperPath)
                    }
                    .disabled(status.state == .checking)
                    .settingsRow(.transcriberrrStatus)
                    .help(status.state == .checking ? "Transcriberrr is being checked."
                                                    : "Ask Transcriberrr’s helper which engines it offers.")
                    Button("Open Transcriberrr", action: openTranscriberrr)
                        .disabled(application == nil)
                        .accessibilityIdentifier("settings.transcripts.transcriberrr.open")
                        .help(application == nil ? "Transcriberrr is not installed." : "Open the Transcriberrr app.")
                }
            }
        }
        .task(id: preferences.transcriptHelperPath) {
            // The window keeps the last result: coming back to the page checks only if the helper location changed.
            status.follow(helperPath: preferences.transcriptHelperPath)
        }
        .task(id: TranscriberrrLookup(path: preferences.transcriptHelperPath, state: status.state)) {
            application = TranscriberrrStatus.application(helper: helper)
        }
    }

    private var helper: URL? {
        if case .ready(let helper, _) = status.state { return helper }
        return try? TranscriptJobStore.helperURL(chosen: preferences.transcriptHelperPath)
    }

    /// What Open Transcriberrr's app depends on.
    private struct TranscriberrrLookup: Equatable {
        let path: String
        let state: TranscriberrrStatus.State
    }

    static func statusText(_ state: TranscriberrrStatus.State) -> String {
        switch state {
        case .unchecked: "Not checked"
        case .checking: "Checking…"
        case .failed(let message): message
        case .ready(_, let catalog):
            (catalog.version.map { "Version \($0). " } ?? "")
                + (catalog.engines.isEmpty ? "No engines." : "Engines: " + catalog.engines.map { engine in
                    engine.title + (engine.available ? "" : " (unavailable)")
                }.joined(separator: ", ") + ".")
        }
    }

    struct EngineChoice: Equatable {
        let name: String
        let label: String
        let selectable: Bool
    }

    /// Automatic, the helper's engines, and a saved engine it does not offer, which stays selected and is kept. A saved
    /// alias of an offered engine selects that engine's own entry, which takes the alias as its tag, so the engine is
    /// listed once and the saved name is kept.
    static func engineChoices(preferred: String, catalog: TranscriptEngineCatalog?) -> [EngineChoice] {
        var choices = [EngineChoice(name: "", label: "Automatic", selectable: true)]
        for engine in catalog?.engines ?? [] {
            let answers = !preferred.isEmpty && engine.answers(to: preferred)
            choices.append(.init(name: answers ? preferred : engine.name, label: engine.title + (engine.available ? "" : " (unavailable)"),
                                 selectable: engine.available || answers))
        }
        if !preferred.isEmpty, !choices.contains(where: { $0.name == preferred }) {
            choices.append(.init(name: preferred, label: TranscriptEngineCatalog.title(preferred)
                                 + (catalog == nil ? "" : " (not offered)"), selectable: true))
        }
        return choices
    }

    private func openTranscriberrr() {
        guard let app = TranscriberrrStatus.application(helper: helper) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    private func chooseHelper() {
        // The helper lives inside the app bundle, so bundles open like folders here.
        SettingsPath.choose(title: "Choose Transcriberrr’s helper",
                            message: "Choose Transcriberrr’s helper program, the file named transcriberrr inside Transcriberrr.app, in Contents/Helpers.",
                            files: true, packagesAsFolders: true,
                            startingIn: Self.helperPanelFolder(chosen: preferences.transcriptHelperPath)) { url in
            preferences.transcriptHelperPath = url.path
        }
    }

    /// Where the helper panel opens: the chosen helper's folder, else the installed app's helper folder, else Applications.
    static func helperPanelFolder(chosen: String, installedApp: URL? = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.transcriberrr.app")) -> URL {
        if !chosen.isEmpty { return URL(fileURLWithPath: chosen).deletingLastPathComponent() }
        if let installedApp { return installedApp.appendingPathComponent("Contents/Helpers", isDirectory: true) }
        return URL(fileURLWithPath: "/Applications", isDirectory: true)
    }
}
