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

    @MainActor init(preferences: EditorPreferences, status: TranscriberrrStatus? = nil) {
        self.preferences = preferences
        _status = StateObject(wrappedValue: status ?? TranscriberrrStatus())
    }

    var body: some View {
        SettingsForm(page: .transcripts, preferences: preferences) {
            Section {
                transcriberrr
                LabeledContent(SettingsRow.helperLocation.title) {
                    HStack {
                        Text(preferences.transcriptHelperPath.isEmpty ? "Automatic"
                                : (preferences.transcriptHelperPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(preferences.transcriptHelperPath.isEmpty ? .secondary : .primary)
                            .help(preferences.transcriptHelperPath.isEmpty ? "MPCut finds the helper inside Transcriberrr.app"
                                                                          : preferences.transcriptHelperPath)
                        if !preferences.transcriptHelperPath.isEmpty {
                            Button("Automatic") { preferences.transcriptHelperPath = "" }
                                .help("Find Transcriberrr automatically")
                        }
                        Button("Choose…", action: chooseHelper)
                            .settingsRow(.helperLocation)
                            .help("Choose the Transcriberrr helper")
                    }
                }
                Picker(SettingsRow.engine.title, selection: $preferences.transcriptEngine) {
                    ForEach(Self.engineChoices(preferred: preferences.transcriptEngine, catalog: status.catalog), id: \.name) { choice in
                        Text(choice.label).tag(choice.name).disabled(!choice.selectable)
                    }
                }
                .settingsRow(.engine)
                .accessibilityLabel(SettingsRow.engine.title)
                .help("Choose the engine new transcription jobs start with. Automatic uses Qwen3, then the first available engine.")
                if let reason = status.catalog?.unavailableReason(forPreferred: preferences.transcriptEngine) {
                    Text(reason + " New jobs use Automatic until it is available; the preference is kept.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.transcripts.engine.issue")
                }
                Toggle(SettingsRow.speakers.title, isOn: $preferences.identifiesSpeakers)
                    .settingsRow(.speakers)
                    .help("Start new jobs with speaker identification where the engine supports it")
                Toggle(SettingsRow.downloads.title, isOn: $preferences.downloadsModels)
                    .settingsRow(.downloads)
                    .help("Start new jobs and retries with model downloads allowed")
            } header: {
                Text("Transcription")
            } footer: {
                SettingsFootnote("Job setup starts from these values and can change them for one job. The helper location and engine reach desktop jobs and agents working in an open project; the CLI and file jobs keep their environment variable and Qwen3.")
            }
            Section("Reader") {
                Toggle(SettingsRow.followPlayback.title, isOn: $preferences.followsPlayback)
                    .settingsRow(.followPlayback)
                    .help("Start new windows with the reader following playback")
                SettingsNumericField(.readerTextSize, value: $preferences.readerTextSize, in: EditorPreferences.readerTextSizeRange,
                                     step: 1, unit: "pt", digits: 1, help: "Type the text size transcript readers start with in new windows")
            }
            Section("Editing") {
                Picker(SettingsRow.boundary.title, selection: $preferences.boundaryPolicy) {
                    Text("Nearest media frame").tag(TranscriptEditRequest.BoundaryPolicy.nearestFrame)
                    Text("Copy-safe boundary").tag(TranscriptEditRequest.BoundaryPolicy.copySafe)
                    Text("Exact requested time").tag(TranscriptEditRequest.BoundaryPolicy.exact)
                }
                .settingsRow(.boundary)
                .help("Choose where transcript edits place their cuts")
                SettingsNumericField(.retainedPause, value: $preferences.retainedPause, in: EditorPreferences.retainedPauseRange,
                                     step: 0.05, unit: "s", help: "Type how much of each pause Tighten keeps")
                TextField(SettingsRow.fillerTerms.title, text: $preferences.fillerTerms, prompt: Text("um, uh, you know"))
                    .settingsRow(.fillerTerms)
                    .help("Type the filler terms transcript review starts with, separated by commas")
            }
            Section("Export") {
                Picker(SettingsRow.exportFormat.title, selection: $preferences.transcriptExportFormat) {
                    Text("Native JSON").tag(TranscriptFormat.json)
                    Text("Readable text").tag(TranscriptFormat.text)
                    Text("SubRip (.srt)").tag(TranscriptFormat.srt)
                    Text("WebVTT (.vtt)").tag(TranscriptFormat.vtt)
                }
                .settingsRow(.exportFormat)
                .help("Choose the first format Export Transcript offers")
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
                    .help("Name the speaker in each caption")
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
                    .help("Ask the Transcriberrr helper which engines it offers")
                    Button("Open Transcriberrr", action: openTranscriberrr)
                        .disabled(TranscriberrrStatus.application(helper: helper) == nil)
                        .help("Open the Transcriberrr app")
                }
            }
        }
        .task(id: preferences.transcriptHelperPath) {
            // The window keeps the last result: coming back to the page checks only if the helper location changed.
            status.follow(helperPath: preferences.transcriptHelperPath)
        }
    }

    private var helper: URL? {
        if case .ready(let helper, _) = status.state { return helper }
        return try? TranscriptJobStore.helperURL(chosen: preferences.transcriptHelperPath)
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

    /// Automatic, the helper's engines, and a saved engine it does not offer, which stays selected and is kept.
    static func engineChoices(preferred: String, catalog: TranscriptEngineCatalog?) -> [EngineChoice] {
        var choices = [EngineChoice(name: "", label: "Automatic", selectable: true)]
        for engine in catalog?.engines ?? [] {
            choices.append(.init(name: engine.name, label: engine.title + (engine.available ? "" : " (unavailable)"),
                                 selectable: engine.available || engine.answers(to: preferred)))
        }
        if !preferred.isEmpty, !choices.contains(where: { $0.name == preferred }) {
            let canonical = catalog?.engine(named: preferred)
            if canonical == nil {
                choices.append(.init(name: preferred, label: TranscriptEngineCatalog.title(preferred)
                                     + (catalog == nil ? "" : " (not offered)"), selectable: true))
            } else {
                // An alias of an offered engine keeps its own tag so the picker shows it.
                choices.append(.init(name: preferred, label: TranscriptEngineCatalog.title(preferred), selectable: true))
            }
        }
        return choices
    }

    private func openTranscriberrr() {
        guard let app = TranscriberrrStatus.application(helper: helper) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    private func chooseHelper() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Transcriberrr helper"
        panel.message = "Choose Transcriberrr’s helper program, the file named transcriberrr inside Transcriberrr.app, in Contents/Helpers."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // The helper lives inside the app bundle, so bundles open like folders here.
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = Self.helperPanelFolder(chosen: preferences.transcriptHelperPath)
        // A standalone panel: as a sheet it is wider than the Settings window and hangs off its edge.
        ProjectPanels.present(panel, in: nil) { accepted in
            if accepted, let url = panel.url { preferences.transcriptHelperPath = url.path }
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
