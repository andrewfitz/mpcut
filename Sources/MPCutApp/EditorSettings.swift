import MPCutCore
import SwiftUI

struct EditorSettings: View {
    @ObservedObject var preferences: EditorPreferences

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
                    LabeledContent("Status", value: preferences.localMCPStatus)
                } header: { Text("Automation") } footer: {
                    Text("Allow local programs running as your user to inspect and edit projects and process media files.")
                }
                Section("Timeline") {
                    SnapTargetPicker(selection: $preferences.snapTarget)
                    Toggle("Large timeline thumbnails and waveforms", isOn: $preferences.largeThumbnails)
                }
                Section {
                    HistoryLimitField(limit: $preferences.historyLimit)
                } header: {
                    Text("Project history")
                } footer: {
                    Text("Projects keep this many undo and redo steps in total. Lowering the limit trims open projects immediately. Set it to 0 to turn off history.")
                }
                Section("Preview audio") {
                    Toggle("Play audio while scrubbing", isOn: $preferences.scrubSoundEnabled)
                    Toggle("Mute preview", isOn: $preferences.isMuted)
                    Slider(value: $preferences.volume, in: 0...1) { Text("Volume") }
                }
                Section("Export defaults") {
                    Picker("Movie", selection: $preferences.defaultExportMode) {
                        ForEach(ExportMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("JPEG frames", selection: $preferences.jpegPreset) {
                        Text("Small review images").tag(JPEGPreset.review)
                        Text("Full resolution, high quality").tag(JPEGPreset.full)
                    }
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Toggle("Automatically save and load analysis beside each recording", isOn: $preferences.useAnalysisSidecars)
                } header: {
                    Text("Analysis sidecars")
                } footer: {
                    Text("Completed scans are shared with the CLI. The app and the CLI can both reuse them.")
                }
                Section("Silence detection") {
                    PauseSetting(label: "Minimum pause", unit: "s", value: $preferences.minimumPause,
                                 minimum: 1.0 / Double(AudioWaveform.rate), step: 0.1)
                    PauseSetting(label: "Leave per pause", unit: "s", value: $preferences.leavePause, minimum: 0, step: 0.1)
                }
            }
            .tabItem { Label("Analysis", systemImage: "waveform") }
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
        LabeledContent("Maximum steps") {
            TextField("Maximum history steps", text: $entry)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
                .focused($editing)
                .onSubmit(commit)
            Stepper("Maximum history steps", value: Binding(
                get: { enteredLimit ?? limit },
                set: { value in
                    limit = value
                    entry = String(value)
                }
            ), in: EditorPreferences.historyStepRange)
            .labelsHidden()
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
