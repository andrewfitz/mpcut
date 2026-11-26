import SwiftUI

struct SettingsPlaybackPage: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        SettingsForm(page: .playback, preferences: preferences) {
            Section("Audio") {
                Toggle(SettingsRow.scrubAudio.title, isOn: $preferences.scrubSoundEnabled)
                    .settingsRow(.scrubAudio)
                    .help("Play audio while you drag the playhead.")
                Toggle(SettingsRow.muted.title, isOn: $preferences.isMuted)
                    .settingsRow(.muted)
                    .help("Mute the audio of previews in every window. Exports keep their sound.")
                LabeledContent {
                    // The percentage sits in the number column, where the pages' fields end, with the unit and stepper
                    // columns after it left empty, so it lines up with the numbers on other pages.
                    HStack(spacing: 4) {
                        // The slider's own label is its one accessibility label.
                        Slider(value: $preferences.volume, in: 0...1) { Text(SettingsRow.volume.title) }
                            .labelsHidden()
                            .settingsRow(.volume)
                            .accessibilityValue("\(Self.percent(preferences.volume)) percent")
                            .disabled(preferences.isMuted)
                            .help(preferences.isMuted ? "Turn off “\(SettingsRow.muted.title)” to change the volume."
                                                      : "Set the volume of preview audio.")
                        Text("\(Self.percent(preferences.volume))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                            .accessibilityHidden(true)
                        Color.clear.frame(width: SettingsNumericField<Int>.unitWidth, height: 1)
                        // An invisible stepper keeps the stepper column's exact width.
                        Stepper("", value: .constant(0)).labelsHidden().hidden().accessibilityHidden(true)
                    }
                    .frame(maxWidth: 360)
                } label: {
                    Text(SettingsRow.volume.title).accessibilityHidden(true)
                }
            }
            Section("Playback") {
                Picker(SettingsRow.playbackSpeed.title, selection: $preferences.playbackSpeed) {
                    ForEach(PlaybackSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .settingsRow(.playbackSpeed)
                .help("Choose the speed new windows start playing at.")
            }
            Section {
                SettingsNumericField(.preroll, value: $preferences.cutPreviewPreroll, in: EditorPreferences.cutPreviewRange,
                                     step: 0.25, unit: "s", help: "Type how much to play before a cut")
                SettingsNumericField(.postroll, value: $preferences.cutPreviewPostroll, in: EditorPreferences.cutPreviewRange,
                                     step: 0.25, unit: "s", help: "Type how much to play after a cut")
            } header: {
                Text("Play around a cut")
            } footer: {
                SettingsFootnote("Preview Join and pause previews play this much on each side of a cut, in both editors.")
            }
            Section {
                Picker(SettingsRow.viewerSDR.title, selection: $preferences.viewerForceSDR) {
                    Text("Automatic").tag(false)
                    Text("Force SDR").tag(true)
                }
                .settingsRow(.viewerSDR)
                .help("Choose whether the editor viewer shows HDR automatically or always as SDR.")
                Picker(SettingsRow.monitorSDR.title, selection: $preferences.monitorForceSDR) {
                    Text("Automatic").tag(false)
                    Text("Force SDR").tag(true)
                }
                .settingsRow(.monitorSDR)
                .help("Choose whether the Video Monitor shows HDR automatically or always as SDR.")
                Toggle(SettingsRow.cleanFeed.title, isOn: $preferences.monitorCleanFeed)
                    .settingsRow(.cleanFeed)
                    .help("Hide the status badge and title bar on the Video Monitor.")
                Picker(SettingsRow.monitorPlacement.title, selection: $preferences.monitorPlacement) {
                    Text("Other display").tag(VideoMonitorPlacement.otherDisplay)
                    Text("Last position").tag(VideoMonitorPlacement.lastPosition)
                }
                .settingsRow(.monitorPlacement)
                .help("Choose where the Video Monitor opens: on another display or where it was last.")
            } header: {
                Text("Display")
            } footer: {
                SettingsFootnote("Automatic shows HDR on an HDR display. “Editor viewer” applies to every picture except the Video Monitor, previews in sheets included. You can also change it by right-clicking a picture and choosing Force SDR Preview.")
            }
        }
    }

    static func percent(_ volume: Float) -> Int { Int((volume * 100).rounded()) }
}
