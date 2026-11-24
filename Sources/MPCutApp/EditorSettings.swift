import MPCutCore
import SwiftUI

struct EditorSettings: View {
    @ObservedObject var preferences: EditorPreferences
    let cacheContext: @MainActor () -> SidecarClearContext

    fileprivate static let finishEditing = Notification.Name("MPCutFinishEditingSettings")
    @MainActor static func commitPendingEdits() {
        NotificationCenter.default.post(name: finishEditing, object: nil)
    }

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Enable local MCP control", isOn: $preferences.localMCPEnabled)
                        .accessibilityLabel("Enable local MCP control")
                        .help("Allow local MCP control")
                    LabeledContent("Status", value: preferences.localMCPStatus)
                } header: { Text("Automation") } footer: {
                    SettingsFootnote("Programs running under your Mac account can read and edit projects and process media files.")
                }
                Section("Media") {
                    Toggle("Watch recordings for changes while editing", isOn: $preferences.automaticallyRefreshMedia)
                        .help("Refresh project media when a recording changes")
                }
                Section("Timeline") {
                    SnapTargetPicker(selection: $preferences.snapTarget)
                    Toggle("Show source time ticks inside clips", isOn: $preferences.sourceTimeTicks)
                        .help("Show the original recording time inside each clip.")
                    Toggle("Enlarge thumbnails and waveforms", isOn: $preferences.largeThumbnails)
                        .help("Enlarge timeline previews")
                }
                Section {
                    HistoryLimitField(limit: $preferences.historyLimit)
                } header: {
                    Text("History")
                } footer: {
                    SettingsFootnote("Undo and redo share this limit. Lowering it immediately removes older history from open projects. Set it to 0 to turn off history.")
                }
                Section("Playback") {
                    Toggle("Play audio while scrubbing", isOn: $preferences.scrubSoundEnabled)
                        .help("Hear audio while scrubbing")
                    Toggle("Mute preview audio", isOn: $preferences.isMuted)
                        .help("Mute preview audio")
                    Slider(value: $preferences.volume, in: 0...1) { Text("Preview volume") }
                        .help("Adjust preview volume")
                }
                Section("Export defaults") {
                    Picker("Default movie export mode", selection: $preferences.defaultExportMode) {
                        ForEach(ExportMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .help("Set default movie mode")
                    Picker("Default JPEG preset", selection: $preferences.jpegPreset) {
                        Text("Small review images").tag(JPEGPreset.review)
                        Text("Full resolution, high quality").tag(JPEGPreset.full)
                    }
                    .help("Set default JPEG quality")
                    Toggle(TierPrompt.settingTitle, isOn: $preferences.warnBeforeLoweringExportTier)
                        .help("Warn about export limits")
                }
            }
            .tabItem { Label("General", systemImage: "gearshape").help("Show general settings") }

            Form {
                SidecarStorageSettings(preferences: preferences, cacheContext: cacheContext)
                Section("Silence") {
                    PauseSetting(label: "Minimum pause", unit: "s", value: $preferences.minimumPause,
                                 minimum: 1.0 / Double(AudioWaveform.rate), step: 0.1)
                    BlipSetting(preferences: preferences)
                    PausePaddingSetting(preferences: preferences)
                }
            }
            .tabItem { Label("Analysis", systemImage: "waveform").help("Show analysis settings") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 495)
    }
}

struct HistoryLimitField: View {
    @Binding var limit: Int
    @State private var entry = ""
    @FocusState private var editing: Bool

    var body: some View {
        LabeledContent("Maximum undo and redo steps") {
            TextField("Maximum undo and redo steps", text: $entry)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
                .focused($editing)
                .onSubmit(commit)
                .help("Enter history limit")
            Stepper("Maximum undo and redo steps", value: Binding(
                get: { enteredLimit ?? limit },
                set: { value in
                    limit = value
                    entry = String(value)
                }
            ), in: EditorPreferences.historyStepRange)
            .labelsHidden()
            .help("Adjust history limit")
        }
        .onChange(of: limit, initial: true) { _, value in entry = String(value) }
        .onChange(of: editing) { _, focused in if !focused { commit() } }
        .onDisappear(perform: commit)
        .background(SettingsWindowCommit(commit: commit))
    }

    // Stepping starts from the visible value. Typing alone must not evict timeline history.
    private var enteredLimit: Int? {
        guard let number = Int(entry.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let range = EditorPreferences.historyStepRange
        return min(range.upperBound, max(range.lowerBound, number))
    }

    private func commit() {
        if let enteredLimit { limit = enteredLimit }
        entry = String(limit)
    }
}

// AppKit can retain a Settings window and its field editor after the window closes.
private struct SettingsWindowCommit: NSViewRepresentable {
    let commit: () -> Void

    func makeNSView(context: Context) -> WindowObserver { WindowObserver() }
    func updateNSView(_ view: WindowObserver, context: Context) { view.commit = commit }

    final class WindowObserver: NSView {
        var commit: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            center.addObserver(self, selector: #selector(finishEditing), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(finishEditing), name: EditorSettings.finishEditing, object: nil)
        }

        @objc private func finishEditing() { commit?() }
    }
}
