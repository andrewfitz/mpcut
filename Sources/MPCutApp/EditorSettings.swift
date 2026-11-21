import MPCutCore
import SwiftUI

struct EditorSettings: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        TabView {
            Form {
                Section("Timeline") {
                    SnapTargetPicker(selection: $preferences.snapTarget)
                    Toggle("Large timeline thumbnails and waveforms", isOn: $preferences.largeThumbnails)
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
        .frame(width: 480, height: 390)
    }
}
