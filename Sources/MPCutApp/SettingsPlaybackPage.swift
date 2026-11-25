import SwiftUI

struct SettingsPlaybackPage: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        SettingsForm(page: .playback, preferences: preferences) {
            Section("Audio") {
                Toggle(SettingsRow.scrubAudio.title, isOn: $preferences.scrubSoundEnabled)
                    .settingsRow(.scrubAudio)
                    .help("Hear audio while scrubbing")
                Toggle(SettingsRow.muted.title, isOn: $preferences.isMuted)
                    .settingsRow(.muted)
                    .help("Mute preview audio")
                Slider(value: $preferences.volume, in: 0...1) { Text(SettingsRow.volume.title) }
                    .settingsRow(.volume)
                    .accessibilityValue("\(Int((preferences.volume * 100).rounded())) percent")
                    .help("Adjust preview volume")
            }
            Section {
                Picker(SettingsRow.playbackSpeed.title, selection: $preferences.playbackSpeed) {
                    ForEach(PlaybackSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .settingsRow(.playbackSpeed)
                .help("Choose the speed new windows start at")
                SettingsNumericField(.preroll, value: $preferences.cutPreviewPreroll, in: EditorPreferences.cutPreviewRange,
                                     step: 0.25, unit: "s")
                SettingsNumericField(.postroll, value: $preferences.cutPreviewPostroll, in: EditorPreferences.cutPreviewRange,
                                     step: 0.25, unit: "s")
            } header: {
                Text("Playback")
            } footer: {
                SettingsFootnote("Preview Join and pause previews play this much on each side of a cut, in both editors.")
            }
            Section {
                Picker(SettingsRow.viewerSDR.title, selection: $preferences.viewerForceSDR) {
                    Text("Automatic").tag(false)
                    Text("Force SDR").tag(true)
                }
                .settingsRow(.viewerSDR)
                .help("Show HDR pictures as SDR in the editor viewer")
                Picker(SettingsRow.monitorSDR.title, selection: $preferences.monitorForceSDR) {
                    Text("Automatic").tag(false)
                    Text("Force SDR").tag(true)
                }
                .settingsRow(.monitorSDR)
                .help("Show HDR pictures as SDR on the Video Monitor")
                Toggle(SettingsRow.cleanFeed.title, isOn: $preferences.monitorCleanFeed)
                    .settingsRow(.cleanFeed)
                    .help("Hide the status badge and title bar on the Video Monitor")
                Picker(SettingsRow.monitorPlacement.title, selection: $preferences.monitorPlacement) {
                    Text("Other display").tag(VideoMonitorPlacement.otherDisplay)
                    Text("Last position").tag(VideoMonitorPlacement.lastPosition)
                }
                .settingsRow(.monitorPlacement)
                .help("Choose where the Video Monitor opens")
            } header: {
                Text("Display")
            } footer: {
                SettingsFootnote("Automatic shows HDR on an HDR display. The editor viewer setting applies to every picture except the Video Monitor, including sheet previews. Right-click a picture to change it there.")
            }
        }
    }
}
